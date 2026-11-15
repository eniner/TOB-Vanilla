--[[
  rmlui - Lua binding for the MQ2RmlUi plugin (RmlUi HTML/CSS-style windows).

  Use the same MQ / RedGuides split every Lua UI already uses:

    mq.imgui.init('MyScript', function()          -- ImGui thread, every frame
      for ev in win:events() do handle(ev) end    -- clicks (also autoclose heartbeat)
      win:text('hp', tostring(mq.TLO.Me.PctHPs()))
    end)
    while running do
      mq.doevents()                               -- script thread: binds, events, macros
      mq.delay(50)
    end

  Do not poll/update Rml from the delay loop. That is a different thread/timing than
  OnUpdateImGui, which is why buttons feel dead or fire a frame late.

    local rml = require('rmlui')
    local win = rml.open('mywin', 'myscript/ui/main.rml', { width = 320, height = 240 })
    win:text('title', 'Hello')
    for ev in win:events() do print(ev.type, ev.id, ev.action, ev.value) end

  Ownership / lifetime:
    - Each script's Lua state tracks windows it opened.
    - On /lua stop the state is destroyed and a GC finalizer closes those windows
      immediately. Explicit win:close() / rml.close_all() also work.
    - autoclose=true (default) is a plugin-side backup if events() stops without
      state teardown. Call events() from the imgui callback so the heartbeat is
      the same cadence as mq.imgui.init.

  Item / spell icons (API v2+):
    <img src="eq://item/1234"/>     -- Item.Icon() → A_DragItem cell (id-500)
    <img src="eq://spell/42"/>      -- SpellIcon cell
    rml.icon_src('item', iconId)    -- eq:// when atlas works, else exported PNG
    rml.icon_src('spell', cell)     -- SpellIcon() cell
    rml.export_icon('item', iconId) -- PNG under lua/rmlui/icons/cache/
    rml.item_icon_img(iconId)       -- ready-made <img> with PNG fallback
    rml.spell_icon_img(cell)        -- ready-made <img> (cell 0 is valid)

  RML attributes understood by the plugin:
    action="name"   click → ev.action (also blocks window drag on that element)
    drag="1"        drag moves the window
    resize="1"      drag resizes the window
]]

local mq = require('mq')
local ffi = require('ffi')

ffi.cdef [[
int rml_api_version();
int rml_ready();
int rml_open(const char* name, const char* path, int width, int height, int flags);
int rml_close(const char* name);
int rml_reload(const char* name);
int rml_show(const char* name, int show);
int rml_is_open(const char* name);
int rml_set_window(const char* name, float x, float y, float width, float height);
int rml_set_default_pos(const char* name, float x, float y);
int rml_set_rml(const char* window, const char* id, const char* rml);
int rml_set_text(const char* window, const char* id, const char* text);
int rml_set_attr(const char* window, const char* id, const char* attr, const char* value);
int rml_set_class(const char* window, const char* id, const char* cls, int on);
int rml_set_style(const char* window, const char* id, const char* property, const char* value);
int rml_set_value(const char* window, const char* id, const char* value);
const char* rml_get_value(const char* window, const char* id);
const char* rml_poll(const char* name);
int rml_load_font(const char* path, int fallback);
int rml_debugger(const char* name, int show);
int rml_set_uifiles_path(const char* path);
const char* rml_icon_src(const char* kind, int id, int prefer_file);
const char* rml_export_icon(const char* kind, int id, const char* out_path);
int rml_icon_ready(const char* kind, int id);
]]

local PLUGIN = 'MQ2RmlUi'
local API_VERSION_MIN = 2

local M = {
    FLAG_AUTOCLOSE = 1,
    FLAG_CLICKTHROUGH = 2,
    EQ_ICON_OFFSET = 500,
}

local lib
local owned = {}
local fonts_loaded = false

local function ensure_fonts(api)
    if fonts_loaded or not api then return end
    fonts_loaded = true
    -- Family names in RCSS must match a loaded face. Plugin ships Segoe UI + Icons;
    -- Consolas is referenced by tool CSS and was never loaded (MQ2RmlUi spam + click crash).
    local faces = {
        'C:\\Windows\\Fonts\\segoeui.ttf',
        'C:\\Windows\\Fonts\\segoeuib.ttf',
        'C:\\Windows\\Fonts\\consola.ttf',
        'C:\\Windows\\Fonts\\consolab.ttf',
    }
    for i = 1, #faces do
        pcall(function() api.rml_load_font(faces[i], 0) end)
    end
end

local function plugin_loaded()
    return mq.TLO.Plugin(PLUGIN).IsLoaded() == true
end

local function ensure()
    if not plugin_loaded() then
        mq.cmd('/squelch /plugin ' .. PLUGIN .. ' noauto')
        -- mq.delay is illegal from mq.imgui.init. Ignore failure and let the caller retry.
        pcall(function() mq.delay(3000, plugin_loaded) end)
        if not plugin_loaded() then
            return nil
        end
    end
    if not lib then
        lib = ffi.load(PLUGIN)
        pcall(ffi.cdef, 'int rml_canvas_probe(void);')
        pcall(function()
            mq.bind('/rmlui', function(...)
                local parts = {}
                for i = 1, select('#', ...) do parts[#parts + 1] = tostring(select(i, ...)) end
                local a = table.concat(parts, ' '):lower()
                if a:find('canvasprobe', 1, true) then
                    local ok, err = pcall(function() return lib.rml_canvas_probe() end)
                    if ok then print('[rmlui] canvas probe armed (dumps on next canvas draw)')
                    else print('[rmlui] canvas probe failed: ' .. tostring(err)) end
                end
            end)
        end)
        local v = lib.rml_api_version()
        if v < API_VERSION_MIN then
            lib = nil
            error(string.format('%s API version %d, this script expects >= %d (unload plugin and replace MQ2RmlUi.dll)', PLUGIN, v, API_VERSION_MIN), 3)
        end
    end
    if not lib or lib.rml_ready() == 0 then
        return nil
    end
    ensure_fonts(lib)
    return lib
end

-- Renderer capability bitmask (1 gradients, 2 filters, 4 layers, 8 box-shadow, 16 backdrop-filter,
-- 32 mask-image), or 0 if the plugin isn't ready or the DLL predates rml_render_caps.
local caps_cdef = false
function M.render_caps()
    local api = ensure()
    if not api then return 0 end
    if not caps_cdef then
        caps_cdef = true
        pcall(ffi.cdef, 'int rml_render_caps(void);')    end
    local ok, v = pcall(function() return api.rml_render_caps() end)
    return (ok and tonumber(v)) or 0
end

function M.ready()
    return ensure() ~= nil
end

local function resolve(path)
    if path:match('^%a:[\\/]') or path:match('^[\\/]') then return path end
    return mq.luaDir .. '/' .. path
end

local function track(name)
    if name and name ~= '' then owned[name] = true end
end

local function untrack(name)
    if name then owned[name] = nil end
end

local function close_owned()
    local api = lib
    if not api then return end
    local okReady, ready = pcall(function() return api.rml_ready() end)
    if not okReady or ready ~= 1 then return end
    local names = {}
    for name in pairs(owned) do names[#names + 1] = name end
    for _, name in ipairs(names) do
        pcall(function() api.rml_close(name) end)
        owned[name] = nil
    end
end

do
    local guard = ffi.new('char[1]')
    ffi.gc(guard, function()
        close_owned()
    end)
    M._unload_guard = guard
end

local Window = {}
Window.__index = Window

---@return table|nil window, string|nil err
function M.open(name, path, opts)
    opts = opts or {}
    local api = ensure()
    if not api then return nil, PLUGIN .. ' is not ready' end
    local flags = 0
    if opts.autoclose ~= false then flags = flags + M.FLAG_AUTOCLOSE end
    if opts.clickthrough then flags = flags + M.FLAG_CLICKTHROUGH end

    local full = resolve(path)
    if api.rml_open(name, full, opts.width or 0, opts.height or 0, flags) == 0 then
        return nil, 'could not open ' .. full
    end
    if opts.x and opts.y then api.rml_set_default_pos(name, opts.x, opts.y) end
    track(name)
    local win = setmetatable({ name = name, path = full, cache = {} }, Window)
    -- Brand every window with RedGuides lettering; callers may override accent via :theme().
    if opts.theme ~= false then
        pcall(function() win:theme(opts.theme or 'redguides') end)
    end
    return win
end

function M.load_font(path, fallback)
    local api = ensure()
    if not api then return false end
    return api.rml_load_font(resolve(path), fallback and 1 or 0) == 1
end

local function cached(self, key, value, fn)
    if self.cache[key] == value then return true end
    if fn() == 1 then
        self.cache[key] = value
        return true
    end
    return false
end

function Window:text(id, value)
    value = tostring(value == nil and '' or value)
    return cached(self, 't\0' .. id, value, function() return lib.rml_set_text(self.name, id, value) end)
end

function Window:rml(id, value)
    value = tostring(value or '')
    return cached(self, 'r\0' .. id, value, function() return lib.rml_set_rml(self.name, id, value) end)
end

function Window:style(id, property, value)
    value = value ~= nil and tostring(value) or ''
    return cached(self, 's\0' .. id .. '\0' .. property, value, function() return lib.rml_set_style(self.name, id, property, value) end)
end

function Window:class(id, cls, on)
    on = on and true or false
    return cached(self, 'c\0' .. id .. '\0' .. cls, on, function() return lib.rml_set_class(self.name, id, cls, on and 1 or 0) end)
end

function Window:attr(id, name, value)
    local key = 'a\0' .. id .. '\0' .. name
    if value == nil then
        self.cache[key] = nil
        return lib.rml_set_attr(self.name, id, name, nil) == 1
    end
    value = tostring(value)
    return cached(self, key, value, function() return lib.rml_set_attr(self.name, id, name, value) end)
end

local THEMES = { 'redguides', 'azure', 'violet', 'ember', 'jade', 'rose' }

local function brand_logo(self)
    -- Absolute path so lettering resolves no matter which tool folder opened the doc.
    local logo = resolve('rmlui/theme/redguides-mark.png'):gsub('\\', '/')
    pcall(function()
        self:rml('window-logo', string.format(
            '<img src="%s" drag="1" style="width:108dp;height:20dp;max-height:20dp;pointer-events:none;"/>', logo))
    end)
end

function Window:theme(name)
    name = name or 'redguides'
    for _, t in ipairs(THEMES) do
        self:class('body', 'theme-' .. t, t == name)
    end
    brand_logo(self)
end

function Window:brand()
    brand_logo(self)
end

function Window:set_value(id, value)
    return lib.rml_set_value(self.name, id, tostring(value or '')) == 1
end

function Window:value(id)
    local p = lib.rml_get_value(self.name, id)
    if p == nil then return nil end
    return ffi.string(p)
end

function Window:events()
    return function()
        local p = lib.rml_poll(self.name)
        if p == nil then return nil end
        local t, id, action, value, button = ffi.string(p):match('^(.-)\t(.-)\t(.-)\t(.-)\t(.-)$')
        return { type = t, id = id, action = action, value = value, button = tonumber(button) }
    end
end

--- Drain the event queue (safe from an mq.imgui.init callback).
function Window:poll()
    local evs = {}
    for ev in self:events() do evs[#evs + 1] = ev end
    return evs
end

--- Same hook RedGuides scripts use for ImGui. Pass your per-frame Rml tick here.
function M.init(name, fn)
    mq.imgui.init(name, fn)
end

function M.destroy(name)
    pcall(function() mq.imgui.destroy(name) end)
end

function Window:show(visible)
    return lib.rml_show(self.name, visible == false and 0 or 1) == 1
end

function Window:place(x, y, width, height)
    return lib.rml_set_window(self.name, x or -1, y or -1, width or 0, height or 0) == 1
end

function Window:reload()
    self.cache = {}
    return lib.rml_reload(self.name) == 1
end

function Window:is_open()
    return lib ~= nil and lib.rml_ready() == 1 and lib.rml_is_open(self.name) == 1
end

function Window:debugger(show)
    return lib.rml_debugger(self.name, show == false and 0 or 1) == 1
end

function Window:close()
    untrack(self.name)
    if lib and lib.rml_ready() == 1 then lib.rml_close(self.name) end
    self.cache = {}
end

function M.close(name)
    name = tostring(name or '')
    if name == '' then return false end
    untrack(name)
    local api = ensure()
    if not api then return false end
    return api.rml_close(name) == 1
end

function M.close_all()
    ensure()
    close_owned()
end

function M.set_uifiles_path(path)
    local api = ensure()
    if not api then return false end
    return api.rml_set_uifiles_path(path and tostring(path) or nil) == 1
end

function M.icon_src(kind, id, opts)
    opts = opts or {}
    kind = tostring(kind or 'item')
    id = tonumber(id) or 0
    if id < 0 then return '' end
    local api = ensure()
    if not api then return '' end
    local p = api.rml_icon_src(kind, id, opts.file and 1 or 0)
    if p ~= nil then
        local s = ffi.string(p)
        if s ~= '' then return s end
    end
    return string.format('eq://%s/%d', kind, id)
end

function M.export_icon(kind, id, out_path)
    kind = tostring(kind or 'item')
    id = tonumber(id) or 0
    local api = ensure()
    if not api then return nil end
    local p = api.rml_export_icon(kind, id, out_path)
    if p == nil then return nil end
    local s = ffi.string(p)
    return s ~= '' and s or nil
end

function M.icon_ready(kind, id)
    local api = ensure()
    if not api then return false end
    return api.rml_icon_ready(tostring(kind or 'item'), tonumber(id) or 0) == 1
end

local icon_img_cache = {}

function M.item_icon_img(icon_id, class_name)
    icon_id = tonumber(icon_id) or 0
    class_name = class_name or 'eq-icon'
    local key = class_name .. ':' .. icon_id
    local hit = icon_img_cache[key]
    if hit then return hit end
    local html
    if icon_id <= 0 then
        html = string.format('<div class="%s missing"></div>', class_name)
    else
        local src = M.icon_src('item', icon_id)
        if not src or src == '' then
            html = string.format('<div class="%s missing"></div>', class_name)
        else
            html = string.format('<img class="%s" src="%s"/>', class_name, src)
        end
    end
    icon_img_cache[key] = html
    return html
end

--- SpellIcon() cell. 0 is a real atlas cell; nil / negative = empty plate.
function M.spell_icon_img(icon_id, class_name)
    class_name = class_name or 'spell-icon'
    if icon_id == nil then
        return string.format('<div class="%s missing"></div>', class_name)
    end
    icon_id = tonumber(icon_id)
    if icon_id == nil or icon_id < 0 then
        return string.format('<div class="%s missing"></div>', class_name)
    end
    local key = 's:' .. class_name .. ':' .. icon_id
    local hit = icon_img_cache[key]
    if hit then return hit end
    local src = M.icon_src('spell', icon_id)
    if not src or src == '' then
        src = M.icon_src('spell', icon_id, { file = true })
    end
    local html
    if not src or src == '' then
        html = string.format('<div class="%s missing"></div>', class_name)
    else
        html = string.format('<img class="%s" src="%s"/>', class_name, src)
    end
    icon_img_cache[key] = html
    return html
end

return M
