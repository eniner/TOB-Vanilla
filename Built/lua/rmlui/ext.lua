--[[
  rmlui.ext - optional v3 extras for MQ2RmlUi: key forwarding and data models.
  A separate module: it does not modify rmlui/init.lua or rmlui/host.lua, and every call is
  pcall-guarded, so on an older DLL features() returns the render caps only (or 0) and the
  helpers return false/nil instead of erroring.

    local rmlui = require('rmlui')
    local ext   = require('rmlui.ext')

    -- data model: create + set keys BEFORE the document loads (or call win:reload() after)
    local m = ext.model('mywin', 'party')        -- nil when the DLL has no models
    if m then
      m:set('title', 'Raid')                      -- string / number / boolean
      m:list('members', { { 'Tester', 'WAR', 88 }, { 'Firiona', 'CLR', 35 } })
    end
    local win = rmlui.open('mywin', 'myscript/ui.rml', { width = 320, height = 240 })
    --   <div data-model="party">{{title}}
    --     <div data-for="p : members" data-class-low="p[2] < 50">{{p[0]}} {{p[2]}}%</div>
    --     <input type="text" data-value="title"/>   (edits arrive as ev.type == 'modelchange')
    --   </div>

    -- keys: 1 = observe (EQ still gets them), 2 = capture (EQ doesn't while the window is focused)
    ext.key_mode(win, 1)
    ext.capture(win, function(chord) print('bound to ' .. chord) end)   -- one key, then restores

    -- in your imgui callback, instead of host.tick(win, handlers):
    ext.tick(win, { key = function(k) ... end, model = function(ev) ... end, ...host handlers... })

  Events (from rml_poll, same 5 tab-separated fields as clicks):
    keydown / keyup : ev.id = focused element id ('' = window), ev.value = ImGui key name
                      ('A', 'F5', '1', 'Keypad3', 'LeftCtrl'...), ev.button = mods (1 ctrl, 2 shift, 4 alt)
    modelchange     : ev.id = model, ev.action = key, ev.value = new value (two-way data-value/data-checked)
]]

local ffi = require('ffi')
local mq = require('mq')

local M = { KEYS = 64, MODELS = 128 }

local lib, tried = nil, false
local function api()
    if lib or tried then return lib end
    local ok = pcall(function()
        if mq.TLO.Plugin('MQ2RmlUi').IsLoaded() ~= true then error('not loaded') end
    end)
    if not ok then return nil end
    tried = true
    -- one cdef per function: init.lua may already have declared some (redefinition errors)
    for _, d in ipairs({
        'int rml_render_caps(void);',
        'int rml_features(void);',
        'int rml_key_mode(const char* name, int mode);',
        'int rml_model_create(const char* window, const char* model);',
        'int rml_model_set(const char* window, const char* model, const char* key, const char* value, int type);',
        'const char* rml_model_get(const char* window, const char* model, const char* key);',
        'int rml_model_list_size(const char* window, const char* model, const char* key, int rows, int cols);',
        'int rml_model_list_set(const char* window, const char* model, const char* key, int row, int col, const char* value);',
        'int rml_model_dirty(const char* window, const char* model, const char* key);',
    }) do pcall(ffi.cdef, d) end
    pcall(function() lib = ffi.load('MQ2RmlUi') end)
    return lib
end

local function call(fn, ...)
    local l = api()
    if not l then return nil end
    local args = { ... }
    local ok, v = pcall(function() return l[fn](unpack(args)) end)
    if ok then return v end
    return nil
end

local function wname(w) return type(w) == 'table' and w.name or w end

-- Render caps | 64 keys | 128 models. Falls back to rml_render_caps() on an effects DLL, 0 on older.
local feat_cache, feat_t = nil, -1
function M.features()
    local now = os.clock()
    if feat_cache and feat_cache ~= 0 and now - feat_t < 5 then return feat_cache end
    local v = call('rml_features')
    if v == nil then v = call('rml_render_caps') end
    feat_cache, feat_t = tonumber(v) or 0, now
    return feat_cache
end
local function bit(v, b) return math.floor(v / b) % 2 == 1 end
function M.has(b) return bit(M.features(), b) end
function M.has_keys() return M.has(M.KEYS) end
function M.has_models() return M.has(M.MODELS) end

-- 0 off, 1 observe, 2 capture.
function M.key_mode(win, mode)
    return (tonumber(call('rml_key_mode', wname(win), mode or 1)) or 0) == 1
end

-- ---------------------------------------------------------------------------------------------
-- Keys
local MODKEYS = { LeftCtrl = true, RightCtrl = true, LeftShift = true, RightShift = true,
    LeftAlt = true, RightAlt = true, LeftSuper = true, RightSuper = true }

-- { key = 'F5', mods = 3, ctrl = true, shift = true, alt = false, modifier = false, chord = 'Ctrl+Shift+F5' }
function M.parse_key(ev)
    local mods = tonumber(ev.button) or 0
    local k = { key = ev.value or '', mods = mods, ctrl = bit(mods, 1), shift = bit(mods, 2), alt = bit(mods, 4),
        down = ev.type == 'keydown', id = ev.id }
    k.modifier = MODKEYS[k.key] == true
    local parts = {}
    if k.ctrl then parts[#parts + 1] = 'Ctrl' end
    if k.shift then parts[#parts + 1] = 'Shift' end
    if k.alt then parts[#parts + 1] = 'Alt' end
    if not k.modifier then parts[#parts + 1] = k.key end
    k.chord = table.concat(parts, '+')
    return k
end

local captures = {}
-- Arms a one-shot capture: the next non-modifier keydown on this window calls fn(chord, key).
-- Escape cancels (fn(nil)). Uses mode 2 so the key doesn't also reach EQ; restores the previous mode.
function M.capture(win, fn, restore_mode)
    if not M.has_keys() then return false end
    local n = wname(win)
    if not M.key_mode(n, 2) then return false end
    captures[n] = { fn = fn, restore = restore_mode or 0 }
    return true
end
function M.cancel_capture(win)
    local n = wname(win)
    local c = captures[n]
    if c then captures[n] = nil; M.key_mode(n, c.restore) end
end
function M.capturing(win) return captures[wname(win)] ~= nil end

-- Handles key/modelchange events. Returns true when consumed.
function M.dispatch(win, ev, handlers)
    local t = ev.type
    if t == 'keydown' or t == 'keyup' then
        local k = M.parse_key(ev)
        local n = wname(win)
        local c = captures[n]
        if c and k.down and not k.modifier then
            captures[n] = nil
            M.key_mode(n, c.restore)
            pcall(c.fn, k.key ~= 'Escape' and k.chord or nil, k)
        elseif handlers and handlers.key then
            local ok, err = pcall(handlers.key, k, ev)
            if not ok then print('[Rml] key: ' .. tostring(err)) end
        end
        return true
    elseif t == 'modelchange' then
        if handlers and handlers.model then
            local ok, err = pcall(handlers.model, { model = ev.id, key = ev.action, value = ev.value }, ev)
            if not ok then print('[Rml] model: ' .. tostring(err)) end
        end
        return true
    end
    return false
end

-- Drop-in for host.tick(win, handlers): key/modelchange events go to handlers.key / handlers.model,
-- everything else goes through rmlui.host unchanged.
function M.tick(win, handlers)
    local host = require('rmlui.host')
    if not win then return host.tick(win, handlers) end
    local mt_events = getmetatable(win) and getmetatable(win).__index and getmetatable(win).__index.events
    if not mt_events then return host.tick(win, handlers) end
    rawset(win, 'events', function(self)
        local it = mt_events(self)
        return function()
            while true do
                local ev = it()
                if not ev then return nil end
                if not M.dispatch(self, ev, handlers) then return ev end
            end
        end
    end)
    local ok, r = pcall(host.tick, win, handlers)
    rawset(win, 'events', nil)
    if not ok then error(r, 0) end
    return r
end

-- ---------------------------------------------------------------------------------------------
-- Data models
local Model = {}
Model.__index = Model

-- Returns a model object, or nil when the DLL has no models. Create it before the document loads.
function M.model(win, name)
    if not M.has_models() then return nil end
    local n = wname(win)
    if (tonumber(call('rml_model_create', n, name)) or 0) ~= 1 then return nil end
    return setmetatable({ win = n, name = name, cache = {}, lists = {} }, Model)
end

function Model:set(key, v)
    if self.cache[key] == v and v ~= nil then return true end
    local typ, s = 0, tostring(v == nil and '' or v)
    if type(v) == 'number' then typ = 1 elseif type(v) == 'boolean' then typ, s = 2, (v and '1' or '0') end
    local r = (tonumber(call('rml_model_set', self.win, self.name, key, s, typ)) or 0) == 1
    if r then self.cache[key] = v end
    return r
end

function Model:get(key)
    local p = call('rml_model_get', self.win, self.name, key)
    if p == nil or p == ffi.NULL then return nil end
    return ffi.string(p)
end

-- rows = { {a, b, c}, ... } (cells tostring'd). Only changed cells are sent.
function Model:list(key, rows, cols)
    cols = cols or 0
    for i = 1, #rows do if #rows[i] > cols then cols = #rows[i] end end
    local prev = self.lists[key]
    if not prev or prev.n ~= #rows or prev.cols ~= cols then
        if (tonumber(call('rml_model_list_size', self.win, self.name, key, #rows, cols)) or 0) ~= 1 then return false end
        prev = { n = #rows, cols = cols, cells = {} }
        self.lists[key] = prev
    end
    for r = 1, #rows do
        for c = 1, cols do
            local v = tostring(rows[r][c] == nil and '' or rows[r][c])
            local idx = (r - 1) * cols + c
            if prev.cells[idx] ~= v then
                call('rml_model_list_set', self.win, self.name, key, r - 1, c - 1, v)
                prev.cells[idx] = v
            end
        end
    end
    return true
end

function Model:dirty(key) return (tonumber(call('rml_model_dirty', self.win, self.name, key or '')) or 0) == 1 end

return M
