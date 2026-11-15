--[[ AutoPort v5 · live — run an unmodified ImGui tool and mirror it into RmlUi.

  ports/<pack>/init.lua calls live.run{ pack=, entry=, title= }.
  1. ImGui (global + require) is swapped for the capture proxy; mq.imgui.init
     is wrapped so the tool's draw callbacks are collected, not drawn.
  2. One real mq.imgui.init callback drives everything each frame:
       drain RmlUi events -> capture input state   (no doc close/open here)
       run tool callbacks under capture            (records the call tree)
       per window: rebuild DOM on structure change (throttled), else diff values
  3. The tool's own file is loaded with loadfile from lua/<entry> — never edited.
  4. If the tool can't load, or draws nothing for ~6 s, the static v4 port
     (static_init.lua) is run instead when it exists.
]]
local mq = require('mq')
local capture = require('rmlui.autoport.capture')
local replay = require('rmlui.autoport.replay')

local M = { version = '5.0' }
local fmt = string.format

local BUDGET_MS = 3.0
local REBUILD_MIN_MS = 250
local HIDE_AFTER_FRAMES = 3

local function now_ms() return os.clock() * 1000 end           -- budget timing
local function wall_ms()                                          -- throttles / typing guard
    if mq.gettime then local ok, t = pcall(mq.gettime); if ok and tonumber(t) then return tonumber(t) end end
    return os.time() * 1000
end

local function rel_up(dir) -- '../' count from lua/<dir>/file to lua/
    local n = 0
    for _ in tostring(dir):gsub('\\', '/'):gmatch('[^/]+') do n = n + 1 end
    return string.rep('../', n)
end

function M.doc_source(ui_dir_rel)
    local up = rel_up(ui_dir_rel)
    return table.concat({
        '<rml>\n<head>\n\t<title>AutoPort live</title>\n',
        '\t<link type="text/template" href="', up, 'rmlui/theme/window.rml"/>\n',
        '\t<link type="text/rcss" href="', up, 'rmlui/autoport/ap5.rcss"/>\n',
        '</head>\n<body template="window">\n',
        '\t<div id="ap-root" class="ap-root"></div>\n',
        '</body>\n</rml>\n',
    })
end

local function write_once(path, src)
    local f = io.open(path, 'r')
    if f then local cur = f:read('*a'); f:close(); if cur == src then return true end end
    f = io.open(path, 'w')
    if not f then return false end
    f:write(src); f:close()
    return true
end

-- ---------------------------------------------------------------- state
local R = {
    cbs = {}, cb_order = {},   -- tool imgui callbacks
    docs = {},                 -- wid -> { win, name, sig, map, last_build, miss, shown, placed }
    by_name = {},              -- doc name -> wid
    typing = {},               -- eid -> ms of last user edit (don't overwrite while typing)
    pushed = {},               -- eid -> last value pushed by us
    cursor = 1,
    ever_drew = false,
    running = true,
}
M.R = R

local rmlui -- lazy

local function ensure_doc(pack, ui_rel, w)
    local d = R.docs[w.id]
    if d and d.win then return d end
    d = d or {}
    R.docs[w.id] = d
    local e = replay.eid(w.id)
    local name = ('AP5_' .. pack:gsub('[^%w]', '_') .. '_' .. e):sub(1, 60)
    local file = ui_rel .. '/w_' .. e .. '.rml'
    write_once(mq.luaDir .. '/' .. file, M.doc_source(ui_rel))
    -- tool size when it set one, but never smaller than the window chrome (title bar + buttons + one row)
    -- ImGui sizes include a ~19px title bar and 8px padding; the RmlUi frame's chrome is larger, so add the
    -- difference (keeps the tool's content area), and never go below what the title bar buttons need.
    local W = math.floor((w.w and w.w > 0) and math.max(w.w + 30, 200) or 520)
    local H = math.floor((w.h and w.h > 0) and math.max(w.h + 64, 130) or 440)
    local ok, win = pcall(rmlui.open, name, file, { width = W, height = H, x = math.floor(w.x or 160), y = math.floor(w.y or 100) })
    if not ok or not win then d.err = tostring(win); return nil end
    pcall(function() win:text('window-title', replay.strip_pua(w.title)) end)
    pcall(function() win:class('body', 'has-glass', true) end)
    if not d.placed then pcall(function() win:place(math.floor(w.x or 160), math.floor(w.y or 100), W, H) end); d.placed = true end
    pcall(function() win:show(true) end)
    d.win, d.name, d.shown, d.miss = win, name, true, 0
    R.by_name[name] = w.id
    return d
end

-- ---------------------------------------------------------------- input
local S = capture.S
local function handle_event(d, wid, ev)
    local typ, action = ev.type or '', ev.action or ''
    if typ == 'dblclick' then return end -- the two clicks already arrived as 'click'; a 3rd would re-toggle
    if typ == 'click' then
        if action == 'window:close' then S.winopen[wid] = false; return end
        if action == 'ui:glass' then d.glass = not d.glass; pcall(function() d.win:class('body', 'see-through', d.glass) end); return end
        local e = action:match('^ap:(.+)$')
        if not e or not d.map then return end
        local m = d.map[e]
        if not m then return end
        if m.role == 'close' then S.open[m.nid] = false
        else S.click[m.nid] = true end -- toggle/click/tab: capture resolves on the next frame
    elseif typ == 'mousedown' and tonumber(ev.button) == 1 then
        local e = (ev.id or ''):match('^(a%x+)')
        local m = e and d.map and d.map[e]
        if m then S.ctxreq[m.nid] = true end
    elseif typ == 'change' or typ == 'submit' then
        local e = ev.id or ''
        local m = d.map and d.map[e]
        if not m then return end
        local v = ev.value or ''
        if m.role == 'opt' then
            -- only a real pick counts: ignore the control re-selecting its own current value
            -- (RmlUi fires change when options are rebuilt or when we set the value)
            if v == (R.pushed[e] or m.cur) or v == replay.MENU_V then return end
            local om = d.map[v]
            if om and not S.click[om.nid] then S.click[om.nid] = true end
            if m.menu then -- menu combo: snap back to the placeholder; the item's label shows state
                R.pushed[e] = replay.MENU_V
                pcall(function() if d.win.set_value then d.win:set_value(e, replay.MENU_V) else d.win:attr(e, 'value', replay.MENU_V) end end)
            else
                R.pushed[e] = v
            end
        else
            if R.pushed[e] == v then return end -- echo of our own write
            S.val[m.nid] = v
            R.typing[e] = wall_ms()
            R.pushed[e] = v
        end
    end
end

-- ---------------------------------------------------------------- writes
local function apply(d, op)
    local win, k = d.win, op[1]
    if k == 't' then win:text(op[2], replay.strip_pua(tostring(op[3] or '')))
    elseif k == 'c' then win:class(op[2], op[3], op[4])
    elseif k == 's' then win:style(op[2], op[3], op[4])
    elseif k == 'v' then
        local e, v = op[2], op[3]
        if R.pushed[e] == v then return end
        local t = R.typing[e]
        if t and wall_ms() - t < 600 then return end
        R.pushed[e] = v
        if win.set_value then win:set_value(e, v) else win:attr(e, 'value', v) end
    end
end

-- ---------------------------------------------------------------- frame
function M.frame(pack, ui_rel)
    local t0 = now_ms()
    -- 1) drain events from every doc (no close/open inside this loop)
    for wid, d in pairs(R.docs) do
        if d.win then
            local ok, err = pcall(function() for ev in d.win:events() do handle_event(d, wid, ev) end end)
        end
    end
    -- 2) run tool callbacks under capture
    local fns = {}
    for i = 1, #R.cb_order do local f = R.cbs[R.cb_order[i]]; if f then fns[#fns + 1] = f end end
    local F = capture.frame(fns)
    -- 3) mirror
    local seen = {}
    for i = 1, #F.order do
        local w = F.windows[F.order[i]]
        seen[w.id] = true
        if w.hidden then
            local d = R.docs[w.id]
            if d and d.win and d.shown then pcall(function() d.win:show(false) end); d.shown = false end
        else
            R.ever_drew = true
            local d = ensure_doc(pack, ui_rel, w)
            if d then
                d.miss = 0
                if not d.shown then pcall(function() d.win:show(true) end); d.shown = true end
                local sig = w.sig or ''
                if sig ~= d.sig and (wall_ms() - (d.last_build or -1e9) >= REBUILD_MIN_MS or not d.sig) then
                    local html, map = replay.build(w)
                    pcall(function() d.win:rml('ap-root', html) end)
                    d.sig, d.map, d.last_build = sig, map, wall_ms()
                    d.ops = nil
                end
                d.pending = replay.binds(w)
            end
        end
    end
    for wid, d in pairs(R.docs) do
        if not seen[wid] and d.win and d.shown then
            d.miss = (d.miss or 0) + 1
            if d.miss >= HIDE_AFTER_FRAMES then pcall(function() d.win:show(false) end); d.shown = false end
        end
    end
    -- 4) value writes inside the budget (doc cache drops unchanged values)
    for _, d in pairs(R.docs) do
        if d.pending and d.win then
            local ops = d.pending
            local n = #ops
            local start = ((d.cursor or 1) - 1) % math.max(1, n) + 1
            for j = 0, n - 1 do
                local op = ops[(start + j - 1) % n + 1]
                pcall(apply, d, op)
                if j % 32 == 31 and now_ms() - t0 > BUDGET_MS then d.cursor = (start + j) % n + 1; break end
            end
            d.pending = nil
        end
    end
    local dt = now_ms() - t0
    R.last_frame_ms = dt
    R.frames = (R.frames or 0) + 1
    R.total_ms = (R.total_ms or 0) + dt
    if dt > (R.max_ms or 0) then R.max_ms = dt end
end

-- ---------------------------------------------------------------- install
function M.install()
    if M.installed then return end
    M.installed = true
    capture.real = _G.ImGui
    _G.ImGui = capture.proxy
    package.loaded['ImGui'] = capture.proxy
    local real_init, real_destroy = mq.imgui.init, mq.imgui.destroy
    M.real_init, M.real_destroy = real_init, real_destroy
    mq.imgui.init = function(name, fn)
        name = tostring(name)
        if not R.cbs[name] then R.cb_order[#R.cb_order + 1] = name end
        R.cbs[name] = fn
    end
    mq.imgui.destroy = function(name) R.cbs[tostring(name)] = nil end
    capture.on_register = mq.imgui.init
    capture.on_unregister = mq.imgui.destroy
end

--- opts: pack (port folder under ports/), entry (tool file rel to lua/), title, static (static_init rel)
function M.run(opts)
    local pack = opts.pack
    local port_dir = 'ports/' .. pack
    local ui_rel = port_dir .. '/ui'
    rmlui = require('rmlui')
    pcall(function() rmlui.ready() end) -- may load the plugin; legal here (not in a frame)

    M.install()
    local drv = 'AP5_' .. pack:gsub('[^%w]', '_')
    M.real_init(drv, function()
        if not R.running then return end
        local ok, err = pcall(M.frame, pack, ui_rel)
        if not ok then print('[autoport] frame: ' .. tostring(err)) end
    end)

    local function fallback(why)
        print('[autoport] ' .. pack .. ': live capture not possible (' .. tostring(why) .. ')')
        if opts.static then
            local f = io.open(mq.luaDir .. '/' .. opts.static, 'r')
            if f then
                f:close()
                R.running = false
                pcall(M.real_destroy, drv)
                _G.ImGui = capture.real; package.loaded['ImGui'] = capture.real
                mq.imgui.init, mq.imgui.destroy = M.real_init, M.real_destroy
                print('[autoport] running static port ' .. opts.static)
                dofile(mq.luaDir .. '/' .. opts.static)
                return
            end
        end
        print('[autoport] no static port; stopping.')
    end

    -- MQ adds a folder script's own directory to package.path; the port runs as
    -- ports/<pack>, so add the ORIGINAL tool's folder the same way.
    local tool_dir = tostring(opts.entry):gsub('\\', '/'):match('^(.+)/[^/]+$')
    if tool_dir then
        local base = mq.luaDir .. '/' .. tool_dir
        package.path = base .. '/?.lua;' .. base .. '/?/init.lua;' .. package.path
    end
    local chunk, lerr = loadfile(mq.luaDir .. '/' .. opts.entry)
    if not chunk then return fallback('load: ' .. tostring(lerr)) end
    print(fmt('[autoport] %s live -> /lua stop %s   (original untouched: %s)', opts.title or pack, port_dir, opts.entry))

    -- watchdog: no window drawn within ~6 s -> static fallback
    local t_start = mq.gettime and mq.gettime() or os.time() * 1000
    local watchdog_done = false
    local function watchdog()
        if watchdog_done or R.ever_drew then watchdog_done = true; return false end
        local t = mq.gettime and mq.gettime() or os.time() * 1000
        if t - t_start > 6000 then watchdog_done = true; return true end
        return false
    end

    -- tool main: runs in this script's coroutine; mq.delay inside it keeps frames flowing
    local real_delay = mq.delay
    mq.delay = function(...)
        if watchdog() then error('__ap5_no_window__', 0) end
        return real_delay(...)
    end
    local ok, err = pcall(chunk, table.unpack and table.unpack(opts.args or {}) or unpack(opts.args or {}))
    mq.delay = real_delay
    if not ok then
        if tostring(err) == '__ap5_no_window__' then return fallback('no ImGui window within 6 s') end
        if not R.ever_drew then return fallback(err) end
        print('[autoport] tool error: ' .. tostring(err))
    end
    -- tool returned but its callbacks are still registered: keep pumping
    while R.running and next(R.cbs) ~= nil do
        if watchdog() then return fallback('no ImGui window within 6 s') end
        mq.doevents()
        real_delay(50)
    end
    R.running = false
    for _, d in pairs(R.docs) do if d.win then pcall(function() d.win:show(false) end) end end
end

return M
