-- PocketFarm RmlUi window ("Harvest Grove"): status ribbon, stat cards, bottom navigation dock.
-- Cost rules: fixed element pools baked into main.rml (never rebuilt), every DOM write diffed through a cache,
-- only the visible page is refreshed (4 Hz live values, lists only when their data changed, timers 1 Hz),
-- display:none for hidden parts (pages with inputs move off-screen instead), no looping animation, no blur.
-- Header drags the window (drag="1", no action on it or any ancestor); the position is saved per character
-- from the plugin's 'windowmoved' event (rml_get_window as backup) and applied ONCE when the window opens.
local mq = require('mq')
local rmlui = require('rmlui')
local M = {}
local E                      -- engine api (see init.lua)
local W, WB                  -- main window, launcher button
local WW, WH, BW, BH = 608, 680, 60, 74
local QROWS, SROWS, TROWS, WROWS, LROWS = 5, 10, 6, 7, 19
local opt = { x = nil, y = nil, bx = nil, by = nil, clear = false, btn = true, tab = 'farm' }
local tab = 'farm'
local shown = true
local cache, bcache = {}, {}
local CFG
local save_due
local inp = { iwatch = '', ir = '', iz = '', iig = '', ipl = '' }
local spage, spages, wzi, logoff = 1, 1, 1, 0
local qmap, smap, tmap, wmap = {}, {}, {}, {}
local seen = {}              -- last data identities per list, to skip unchanged rebuilds
local next_live, next_slow = 0, 0
local brect, bopened

local function now() return mq.gettime() end
local function tlo(fn, d) local ok, v = pcall(fn); if ok and v ~= nil then return v end; return d end
local function put(c, k, v, fn) if c[k] == v then return end; c[k] = v; pcall(fn) end
local function text(id, v) v = tostring(v or ''); put(cache, 't' .. id, v, function() W:text(id, v) end) end
local function style(id, p, v) put(cache, 's' .. id .. p, v, function() W:style(id, p, v) end) end
local function class(id, c, on) on = on and true or false; put(cache, 'c' .. id .. c, on, function() W:class(id, c, on) end) end
local function attr(id, n, v) put(cache, 'a' .. id .. n, v, function() W:attr(id, n, v) end) end
local function esc(s) return (tostring(s or ''):gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;')) end
local function clip(s, n) s = tostring(s or ''); if #s > n then return s:sub(1, n - 3) .. '...' end; return s end

-- ------------------------------------------------------------------ per-character settings
local function cfg_path()
    local name = tostring(tlo(function() return mq.TLO.Me.CleanName() end, 'char') or 'char')
    local server = tostring(tlo(function() return mq.TLO.EverQuest.Server() end, 'server') or 'server')
    return string.format('%s/pocketfarm_rml_%s_%s.lua', mq.configDir, (server:gsub('[^%w_%-]', '')), (name:gsub('[^%w_%-]', '')))
end
local function save()
    opt.tab = tab
    opt.alerts, opt.auto, opt.zone = E.sw.alertsOn, E.sw.autoScan, E.sw.scanAllZone
    opt.sortCol, opt.sortDir = E.sw.sortCol, E.sw.sortDir
    pcall(mq.pickle, CFG, opt)
end
local function save_soon() save_due = now() + 400 end
local function load()
    CFG = cfg_path()
    local ok, t = pcall(dofile, CFG)
    if ok and type(t) == 'table' then
        for k, v in pairs(t) do opt[k] = v end
        if opt.alerts ~= nil then E.sw.alertsOn = opt.alerts == true end
        if opt.auto ~= nil then E.sw.autoScan = opt.auto == true end
        if opt.zone ~= nil then E.sw.scanAllZone = opt.zone == true end
        if opt.sortCol == 'name' or opt.sortCol == 'dist' or opt.sortCol == 'up' then E.sw.sortCol = opt.sortCol; E.sw.sortDir = (opt.sortDir == -1) and -1 or 1 end
    end
    tab = ({ farm = 1, spawns = 1, watch = 1, set = 1, log = 1 })[opt.tab] and opt.tab or 'farm'
end

-- ------------------------------------------------------------------ plugin position support (feature bit 256)
local wl, wl_tried
local function wlib()
    if wl_tried then return wl end
    wl_tried = true
    pcall(function()
        local ffi = require('ffi')
        pcall(ffi.cdef, 'int rml_features(void);')
        local l = ffi.load('MQ2RmlUi')
        if math.floor((tonumber(l.rml_features()) or 0) / 256) % 2 == 1 then
            pcall(ffi.cdef, 'const char* rml_get_window(const char* name);'); wl = { l = l, ffi = ffi }
        end
    end)
    return wl
end
local function parse_xy(v) local x, y = tostring(v or ''):match('^%s*%a*%s*(%-?[%d%.]+),(%-?[%d%.]+)'); if x then return math.floor(tonumber(x)), math.floor(tonumber(y)) end end
local function get_pos(name)
    if _G.__pf_get_rect then return _G.__pf_get_rect(name) end      -- test seam
    local w = wlib(); if not w then return nil end
    local ok, s = pcall(function() local r = w.l.rml_get_window(name); if r ~= nil then return w.ffi.string(r) end end)
    if ok and s then return parse_xy(s) end
end
local function screen()
    local ok, sz = pcall(function() return ImGui.GetIO().DisplaySize end)
    if ok and sz and sz.x and sz.x > 0 then return math.floor(sz.x), math.floor(sz.y) end
    return 1920, 1080
end
local function remember(kx, ky, x, y)
    if x and (x ~= opt[kx] or y ~= opt[ky]) then opt[kx], opt[ky] = x, y; save_soon() end
end

-- ------------------------------------------------------------------ static state
local TABS = { 'farm', 'spawns', 'watch', 'set', 'log' }
local function apply_tab()
    for _, k in ipairs(TABS) do class('pg-' .. k, 'on', k == tab); class('d-' .. k, 'on', k == tab) end
    for k in pairs(seen) do seen[k] = nil end
    next_live, next_slow = 0, 0
end
local function apply_opts()
    class('body', 'clear', opt.clear); class('bclear', 'on', opt.clear)
    class('o-debug', 'on', E.state.debugOn); class('o-alerts', 'on', E.sw.alertsOn); class('o-auto', 'on', E.sw.autoScan)
    class('o-zone', 'on', E.sw.scanAllZone); class('o-clear', 'on', opt.clear); class('o-btn', 'on', opt.btn)
end
local function set_input(id, v)       -- forced write: the user may have typed since our last write
    inp[id] = v; cache['a' .. id .. 'value'] = nil; attr(id, 'value', v)
end

-- ------------------------------------------------------------------ live values (visible page only)
local function pill(id, kind) for _, k in ipairs({ 'ok', 'bad', 'warn', 'info' }) do class(id, k, k == kind) end end
local function hpclass(hp) return hp <= 25 and 'hpr' or (hp <= 60 and 'hpy' or 'hpg') end
local function ribbon()
    local s = E.state
    text('tfarm', s.goFarming and 'Farming' or 'Paused'); pill('pfarm', s.goFarming and 'ok' or 'bad')
    text('trest', s.resting and 'Resting' or 'Ready'); pill('prest', s.resting and 'info' or nil)
    text('tcamp', s.campOn and 'Camp' or 'Roaming'); pill('pcamp', s.campOn and 'warn' or nil)
    text('hzone', E.zone())
    text('rstat', clip(E.sw.actionStatus or '', 42))
    class('bgo', 'on', s.goFarming); class('bgo', 'dim', s.goFarming); class('bpause', 'dim', not s.goFarming)
end
local function farm_live()
    local hp, mp, en = E.me()
    for k, v in pairs({ hp = hp, mp = mp, en = en }) do
        v = math.max(0, math.min(100, math.floor(tonumber(v) or 0)))
        style('g' .. k, 'width', v .. '%'); text('v' .. k, v .. '%')
    end
    local id = E.state.myTargetID or 0
    local t = id > 0 and E.spawn_info(id) or nil
    class('ctgt', 'none', t == nil); class('ctgt', 'gone', id > 0 and t == nil)
    if t then
        text('tname', clip(t.name, 40)); text('tmeta', string.format('ID %d  \194\183  %d ft away', id, math.floor(t.dist + 0.5)))
        local p = math.max(0, math.min(100, math.floor(t.hp))); style('tfill', 'width', p .. '%'); text('thp', p .. '%')
    else
        text('tname', id > 0 and 'Target gone or dead' or 'None'); text('tmeta', E.state.goFarming and 'Looking for the next pull' or 'Waiting. Press Start farming.')
    end
end
local function tracked() return E.sw.tracked[E.zone()] or {} end
local function farm_list()
    local tr, tid = tracked(), tlo(function() return mq.TLO.Target.ID() end, 0)
    local key = tostring(tr) .. '|' .. #tr
    if seen.quick == key then return end
    seen.quick = key
    text('qtitle', string.format('SPAWNWATCH  \194\183  %d UP IN %s', #tr, E.zone():upper()))
    text('qstat', E.sw.scanAllZone and 'Whole zone' or 'Watchlist only')
    for i = 1, QROWS do
        local sp = tr[i]; qmap[i] = sp
        class('q' .. i, 'on', sp ~= nil)
        if sp then
            local hp = math.floor(tonumber(sp.pctHPs) or 100)
            text('qn' .. i, clip(sp.name, 44)); text('qd' .. i, string.format('%d ft', math.floor((sp.distance or 0) + 0.5)))
            text('qh' .. i, hp .. '%'); attr('qh' .. i, 'class', 'qh ' .. hpclass(hp))
        end
    end
    class('qempty', 'on', #tr == 0)
    text('qempty', E.sw.scanAllZone and ('Nothing up in the zone scan for ' .. E.zone() .. '.') or ('Nothing on the watchlist is up in ' .. E.zone() .. '.'))
    text('qmore', #tr > QROWS and string.format('%d more on the Spawns page', #tr - QROWS) or '')
end
local function spawns_list()
    local tr = tracked()
    local tid = tlo(function() return mq.TLO.Target.ID() end, 0) or 0
    spages = math.max(1, math.ceil(#tr / SROWS)); if spage > spages then spage = spages end
    local key = tostring(tr) .. '|' .. #tr .. '|' .. spage .. '|' .. tid .. '|' .. E.sw.sortCol .. E.sw.sortDir
    if seen.spawns == key then return end
    seen.spawns = key
    text('szone', E.zone():upper())
    for _, k in ipairs({ 'name', 'dist', 'up' }) do
        local on = E.sw.sortCol == k
        class('so-' .. k, 'on', on)
        attr('sa-' .. k, 'class', on and ('sa ' .. (E.sw.sortDir == 1 and 'up' or 'dn')) or 'sa')
    end
    text('scount', #tr == 1 and '1 spawn up' or (#tr .. ' spawns up'))
    for i = 1, SROWS do
        local sp = tr[(spage - 1) * SROWS + i]; smap[i] = sp
        if not sp then attr('s' .. i, 'class', 'srow')
        else
            local hp = math.floor(tonumber(sp.pctHPs) or 100)
            text('sn' .. i, clip(sp.name, 26)); text('sl' .. i, 'Lv ' .. (sp.level or 0))
            text('sh' .. i, hp .. '%'); attr('sh' .. i, 'class', 'sh ' .. hpclass(hp))
            text('sd' .. i, math.floor((sp.distance or 0) + 0.5)); text('sc' .. i, sp.location or '')
            attr('s' .. i, 'class', 'srow on' .. (sp.id == tid and ' tg' or ''))
        end
    end
    class('sempty', 'on', #tr == 0)
    text('spage', string.format('Page %d of %d', spage, spages))
    class('sprev', 'dis', spage <= 1); class('snext', 'dis', spage >= spages)
end
local function fmtd(s) return E.fmtDuration(s) end
local function timers_list()
    local names = {}
    for n in pairs(E.sw.timers) do names[#names + 1] = n end
    table.sort(names)
    local t = os.time()
    for i = 1, TROWS do
        local n = names[i]; tmap[i] = n
        class('t' .. i, 'on', n ~= nil)
        if n then
            local tm = E.sw.timers[n]
            text('tn' .. i, clip(n, 40))
            if tm.upAt then text('ts' .. i, 'Up again after ' .. fmtd(tm.upAt - (tm.downAt or tm.upAt))); attr('ts' .. i, 'class', 'tstate up')
            else text('ts' .. i, 'Down for ' .. fmtd(t - (tm.downAt or t))); attr('ts' .. i, 'class', 'tstate dn') end
        end
    end
    class('tempty', 'on', #names == 0)
    text('tmore', #names > TROWS and string.format('%d more timers not shown', #names - TROWS) or '')
    class('btclr', 'dis', #names == 0)
end
local wzones = {}
local function watch_list()
    for i = #wzones, 1, -1 do wzones[i] = nil end
    for z in pairs(E.sw.watchlist) do wzones[#wzones + 1] = z end
    table.sort(wzones)
    if seen.wzfirst == nil then        -- start on the current zone when it has entries
        seen.wzfirst = true
        for i, z in ipairs(wzones) do if z == E.zone() then wzi = i end end
    end
    if wzi > #wzones then wzi = math.max(1, #wzones) end
    local z = wzones[wzi]
    local qs = z and E.sw.watchlist[z] or {}
    local key = tostring(z) .. '|' .. #qs .. '|' .. table.concat(qs, '\1') .. '|' .. #wzones
    if seen.watch == key then return end
    seen.watch = key
    text('wzone', z and string.format('%s  (%d)', z, #qs) or 'No zones yet')
    class('wprev', 'dis', wzi <= 1); class('wnext', 'dis', wzi >= #wzones)
    for i = 1, WROWS do
        local q = qs[i]; wmap[i] = q and { q = q, z = z } or nil
        class('w' .. i, 'on', q ~= nil); if q then text('wq' .. i, clip(q, 64)) end
    end
    class('wempty', 'on', #qs == 0)
    text('wmore', #qs > WROWS and string.format('%d more (use /pkf watch list)', #qs - WROWS) or '')
    class('bwclr', 'dis', z == nil)
end
local function settings_live()
    local s = E.state
    text('nr', s.radius); text('nz', s.zRadius)
    text('campt', s.campOn and string.format('Camp at  Y %d   X %d   Z %d', math.floor(s.campY), math.floor(s.campX), math.floor(s.campZ)) or 'Camp is off. You roam freely.')
    text('bcampl', s.campOn and 'Disable camp' or 'Set camp here')
    attr('bcamp', 'class', s.campOn and 'btn red' or 'btn go')
    text('curig', clip(s.ignore, 30)); text('curpl', clip(s.pull, 30))
    apply_opts()
end
local KIND = { msg = 'k-msg', err = 'k-err', good = 'k-good', warn = 'k-warn', sw = 'k-sw', dbg = 'k-dbg' }
local function log_list()
    local L = E.log()
    local n = #L
    if logoff > math.max(0, n - LROWS) then logoff = math.max(0, n - LROWS) end
    local key = E.logrev() .. '|' .. logoff
    if seen.log == key then return end
    seen.log = key
    local first = math.max(1, n - LROWS + 1 - logoff)
    for i = 1, LROWS do
        local ln = L[first + i - 1]
        text('l' .. i, ln and clip(ln.text, 170) or '')
        attr('l' .. i, 'class', ln and ('ll ' .. (KIND[ln.kind] or '')) or 'll')
    end
    text('lcount', n == 1 and '1 line' or (n .. ' lines') .. (logoff > 0 and string.format('  \194\183  %d newer hidden', logoff) or ''))
    class('lold', 'dis', first <= 1); class('lnew', 'dis', logoff == 0); attr('lfol', 'class', logoff == 0 and 'btn sm go' or 'btn sm')
end

-- ------------------------------------------------------------------ events
local function show(on)
    if not W then return end
    if not on then remember('x', 'y', get_pos('PocketFarmRml')) end
    shown = on
    E.state.showUI = on
    pcall(function() W:show(on) end)
    if on then next_live, next_slow = 0, 0; for k in pairs(seen) do seen[k] = nil end end
    if WB then pcall(function() WB:show((not on) and opt.btn) end) end
end
M.show = show

local function on_main(ev)
    if ev.type == 'windowmoved' then remember('x', 'y', parse_xy(ev.value)); return end
    if ev.type == 'change' or ev.type == 'submit' then
        if inp[ev.id] ~= nil then
            inp[ev.id] = tostring(ev.value or '')
            cache['a' .. ev.id .. 'value'] = inp[ev.id]
            if ev.type == 'submit' then
                local map = { iwatch = 'wadd', ir = 'set:r', iz = 'set:z', iig = 'ladd:ig', ipl = 'ladd:pl' }
                ev = { type = 'click', action = map[ev.id] }
            else return end
        else return end
    end
    if ev.type ~= 'click' then return end
    local a = ev.action or ''
    local k, n = a:match('^(%a+):(%d+)$'); n = tonumber(n)
    if a:sub(1, 4) == 'tab:' then tab = a:sub(5); apply_tab(); save_soon(); return
    elseif a == 'go' then E.go()
    elseif a == 'pause' then E.pause()
    elseif a == 'ini' then E.request('ini')
    elseif a == 'scan' then E.request('scan')
    elseif a == 'alerts' then E.alertLists()
    elseif k == 'qt' and qmap[n] then E.target(qmap[n].id, qmap[n].name)
    elseif k == 'qv' and qmap[n] then E.nav(qmap[n].id, qmap[n].name)
    elseif k == 'st' and smap[n] then E.target(smap[n].id, smap[n].name)
    elseif k == 'sv' and smap[n] then E.nav(smap[n].id, smap[n].name)
    elseif k == 'sw' and smap[n] then E.addQuery(smap[n].name); E.sw.actionStatus = 'Watchlist + ' .. smap[n].name
    elseif k == 'si' and smap[n] then E.addIgnore(smap[n].name); E.sw.actionStatus = 'Ignore + ' .. smap[n].name
    elseif a:sub(1, 5) == 'sort:' then
        local c = a:sub(6)
        if E.sw.sortCol == c then E.sw.sortDir = -E.sw.sortDir else E.sw.sortCol = c; E.sw.sortDir = 1 end
        E.resort(); save_soon()
    elseif a == 'sp:prev' then spage = math.max(1, spage - 1)
    elseif a == 'sp:next' then spage = math.min(spages, spage + 1)
    elseif a == 'wadd' then if inp.iwatch:match('%S') then E.addQuery(inp.iwatch); set_input('iwatch', '') end
    elseif k == 'tx' and tmap[n] then E.sw.timers[tmap[n]] = nil
    elseif a == 'tclear' then E.clearTimers()
    elseif a == 'wz:prev' then wzi = math.max(1, wzi - 1)
    elseif a == 'wz:next' then wzi = math.min(#wzones, wzi + 1)
    elseif k == 'wd' and wmap[n] then E.delQuery(wmap[n].q, wmap[n].z)
    elseif a == 'wclear' then if wzones[wzi] then E.clearZoneWatch(wzones[wzi]) end
    elseif a == 'set:r' then if E.setRadius(tonumber(inp.ir)) then set_input('ir', '') end
    elseif a == 'set:z' then if E.setZRadius(tonumber(inp.iz)) then set_input('iz', '') end
    elseif a == 'camp' then E.toggleCamp()
    elseif a == 'ladd:ig' then if inp.iig:match('%S') then E.addIgnore(inp.iig, true); set_input('iig', '') end
    elseif a == 'ladd:pl' then if inp.ipl:match('%S') then E.addPull(inp.ipl, true); set_input('ipl', '') end
    elseif a == 'lclr:ig' then E.clearIgnore()
    elseif a == 'lclr:pl' then E.clearPull()
    elseif a == 'opt:debug' then E.setDebug(not E.state.debugOn)
    elseif a == 'opt:alerts' then E.sw.alertsOn = not E.sw.alertsOn; save_soon()
    elseif a == 'opt:auto' then E.sw.autoScan = not E.sw.autoScan; save_soon()
    elseif a == 'opt:zone' then E.sw.scanAllZone = not E.sw.scanAllZone; E.sw.scanDirty = true; save_soon()
    elseif a == 'opt:clear' or a == 'clear' then opt.clear = not opt.clear; save()
    elseif a == 'opt:btn' then opt.btn = not opt.btn; save()
    elseif a == 'resetpos' then opt.x, opt.y = 80, 160; pcall(function() W:place(80, 160, WW, WH) end); save()
    elseif a == 'stop' then E.stop()
    elseif a == 'logclear' then E.clearLog(); logoff = 0
    elseif a == 'log:old' then logoff = logoff + LROWS - 2
    elseif a == 'log:new' then logoff = math.max(0, logoff - (LROWS - 2))
    elseif a == 'log:follow' then logoff = 0
    elseif a == 'close' then show(false); print('[PocketFarm] window hidden - click the Farm button or type /pkf ui'); return
    else return end
    apply_opts()
    next_live, next_slow = 0, 0
    for kk in pairs(seen) do if kk ~= 'wzfirst' then seen[kk] = nil end end
end

-- a left click that arrives in the same batch as a real move (> 3 px) was a drag, not a click
local function on_button_batch(list)
    local moved = false
    for _, ev in ipairs(list) do
        if ev.type == 'windowmoved' then
            local x, y = parse_xy(ev.value)
            if x then
                if brect and (math.abs(x - brect[1]) > 3 or math.abs(y - brect[2]) > 3) then moved = true end
                brect = { x, y }; remember('bx', 'by', x, y)
            end
        end
    end
    for _, ev in ipairs(list) do
        if ev.type == 'click' and (tonumber(ev.button) or 0) == 0 and not moved then show(true) end
    end
end

-- ------------------------------------------------------------------ lifecycle
function M.init(api)
    E = api
    load()
    local sw, sh = screen()
    local x, y = opt.x or 80, opt.y or 160
    x, y = math.max(-WW + 120, math.min(sw - 120, x)), math.max(0, math.min(sh - 48, y))
    local win, err = rmlui.open('PocketFarmRml', 'pocketfarm_rml/ui/main.rml', { width = WW, height = WH, x = x, y = y, theme = false })
    if not win then print('[PocketFarm] RmlUi window failed: ' .. tostring(err) .. ' (is MQ2RmlUi loaded?)'); return false end
    W = win
    pcall(function() W:reload() end)              -- the plugin caches documents across restarts
    pcall(function() W:place(x, y, WW, WH) end)   -- applied once here; never per frame
    local bx, by = opt.bx or 40, opt.by or math.floor(sh / 3)
    bx, by = math.max(0, math.min(sw - 40, bx)), math.max(0, math.min(sh - 40, by))
    WB = rmlui.open('PocketFarmRmlButton', 'pocketfarm_rml/ui/button.rml', { width = BW, height = BH, x = bx, y = by, theme = false })
    if WB then pcall(function() WB:reload() end); pcall(function() WB:place(bx, by, BW, BH) end); pcall(function() WB:show(false) end); bopened = now() end
    apply_tab(); apply_opts()
    shown = E.state.showUI ~= false
    if not shown then show(false) end
    mq.imgui.init('PocketFarmRml', function() local ok, e = pcall(M.frame); if not ok then print('[PocketFarm] ui: ' .. tostring(e)) end end)
    return true
end

function M.shutdown()
    if W and shown then remember('x', 'y', get_pos('PocketFarmRml')) end
    save()
    pcall(function() mq.imgui.destroy('PocketFarmRml') end)
    if W then pcall(function() W:close() end) end
    if WB then pcall(function() WB:close() end) end
end
function M.visible() return W ~= nil and shown end
function M.tab() return tab end

-- per frame: drain events from both windows (polling is also the plugin's 5 s autoclose heartbeat),
-- then refresh only what the visible page shows, on a budget.
function M.frame()
    if not W then return end
    for ev in W:events() do on_main(ev) end
    if WB then
        if not brect and bopened and now() - bopened > 500 then local bx, by = get_pos('PocketFarmRmlButton'); brect = bx and { bx, by } or { opt.bx or 40, opt.by or 0 } end
        local list = {}
        for ev in WB:events() do list[#list + 1] = ev end
        if #list > 0 then on_button_batch(list) end
    end
    local t = now()
    if save_due and t >= save_due then save_due = nil; save() end
    if (E.state.showUI ~= false) ~= shown then show(E.state.showUI ~= false) end   -- /pkf ui
    if not shown then return end
    if t >= next_live then
        next_live = t + 250
        ribbon()
        if tab == 'farm' then farm_live(); farm_list()
        elseif tab == 'spawns' then spawns_list()
        elseif tab == 'watch' then watch_list()
        elseif tab == 'set' then settings_live()
        elseif tab == 'log' then log_list() end
    end
    if tab == 'watch' and t >= next_slow then next_slow = t + 1000; timers_list() end
end

return M
