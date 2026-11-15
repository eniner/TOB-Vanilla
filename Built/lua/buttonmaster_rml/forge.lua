-- Button Master window ("Obsidian Forge"): Bars / Sets / Buttons / Share / Effects / Simulator. Everything the
-- ImGui right-click menus did is a page here. Lists are fixed pools with pagers; writes are diffed.
local mq = require('mq')
local rmlui = require('rmlui')
local C = require('buttonmaster_rml.core')
local P = require('buttonmaster_rml.paint')
local S = require('buttonmaster_rml.sim')
local F = { hooks = {} }
local WW, WH = 760, 580
local W, D
local shown = false
local tab = 'bars'
local bar_id = 1
local sel_set, slpage, sspage, blpage, srpage = nil, 1, 1, 1, 1
local lsearch = ''
local inp = {}
local maps = {}
local msg_until = 0
local confirm = nil
local sim_bar = nil

local function msg(t, bad) msg_until = mq.gettime() + 4500; D:text('msg', P.esc(t)); D:class('msg', 'bad', bad) end
F.msg = function(t, bad) if D then msg(t, bad) end end
local function set_input(id, v) inp[id] = v or ''; D:forget(id, 'value'); D:attr(id, 'value', v or '') end
local function win() return C.win(bar_id) end
local function icon_of(b) if not b then return '../img/ui/none.png' end; local id, ty = C.icon(b); return P.icon_src(id, ty) or '../img/ui/none.png' end

local function apply_tab() for _, k in ipairs({ 'bars', 'sets', 'lib', 'share', 'fx', 'sim' }) do D:class('pg-' .. k, 'on', k == tab); D:class('tab-' .. k, 'on', k == tab) end end

local function page_bars()
    local wins = C.char().Windows
    if not wins[bar_id] then bar_id = 1 end
    for i = 1, 8 do D:class('bar' .. i, 'hide', wins[i] == nil); D:class('bar' .. i, 'on', i == bar_id) end
    D:class('bnew', 'dis', #wins >= 8)
    local w = win(); local r = w.Rml or {}; w.Rml = r
    D:class('o-vis', 'on', w.Visible ~= false); D:class('o-lock', 'on', w.Locked); D:class('o-title', 'on', not w.HideTitleBar)
    D:class('o-compact', 'on', w.CompactMode); D:class('o-adv', 'on', w.AdvTooltips ~= false)
    local bar = F.hooks.bar(bar_id); local g = bar and bar:geometry()
    D:text('vcols', g and g.cols or (r.Cols or 0)); D:text('vrows', g and g.rows or (r.Rows or 0)); D:text('vsize', g and g.sz or 0); D:text('vgap', tonumber(r.Gap) or 4)
    for _, t in ipairs({ 'forge', 'arcane', 'steel', 'ember', 'none' }) do D:class('th-' .. t, 'on', (r.Theme or 'forge') == t) end
    local fps = tonumber(w.FPS) or 0
    for i, v in ipairs({ 0, 1, 2.5, 10 }) do D:class('fps' .. i, 'on', fps == v) end
    local sets = w.Sets
    maps.bs = {}
    for i = 1, 3 do
        local s = sets[i]; maps.bs[i] = i
        D:class('bs' .. i, 'off', s == nil); if s then D:text('bsn' .. i, P.esc(string.format('%d.  %s', i, P.clip(s, 26)))) end
    end
    D:text('bsmore', #sets > 3 and string.format('%d more sets (use Up to reorder them into view)', #sets - 3) or (#sets == 0 and 'No sets yet. Add one from the right.' or ''))
    local on = {}; for _, s in ipairs(sets) do on[s] = true end
    maps.as = {}
    for _, s in ipairs(C.sets_sorted()) do if not on[s] then maps.as[#maps.as + 1] = s end end
    for i = 1, 10 do local s = maps.as[i]; D:class('as' .. i, 'hide', s == nil); if s then D:text('as' .. i, '+ ' .. P.esc(P.clip(s, 16))) end end
    D:class('bdel', 'dis', #wins <= 1)
    D:text('bdel', confirm == 'delbar' and ('Yes, delete bar ' .. bar_id) or 'Delete this bar')
end
local function page_sets()
    local all = C.sets_sorted()
    if sel_set and not C.settings.Sets[sel_set] then sel_set = nil end
    sel_set = sel_set or all[1]
    local pages = math.max(1, math.ceil(#all / 9)); slpage = math.min(slpage, pages)
    maps.sl = {}
    for i = 1, 9 do
        local s = all[(slpage - 1) * 9 + i]; maps.sl[i] = s
        D:class('sl' .. i, 'off', s == nil)
        if s then
            local n = 0; for _ in pairs(C.settings.Sets[s]) do n = n + 1 end
            D:text('sln' .. i, P.esc(P.clip(s, 22))); D:text('slm' .. i, n .. (n == 1 and ' button' or ' buttons')); D:class('sl' .. i, 'sel', s == sel_set)
        end
    end
    D:text('slpg', string.format('%d / %d', slpage, pages))
    D:text('selset', sel_set and ('BUTTONS IN ' .. P.esc(P.clip(sel_set, 24):upper())) or 'BUTTONS IN SET')
    local size = sel_set and C.set_size(sel_set) or 0
    local spages = math.max(1, math.ceil(size / 9)); sspage = math.min(sspage, spages)
    maps.ss = {}
    for i = 1, 9 do
        local idx = (sspage - 1) * 9 + i
        local b = sel_set and C.button_at(sel_set, idx)
        maps.ss[i] = idx <= size and idx or nil
        D:class('ss' .. i, 'off', idx > size)
        if idx <= size then D:text('ssn' .. i, P.esc(string.format('%d.  %s', idx, b and P.clip(C.label(b, false), 26) or '(empty slot)'))); D:attr('ssi' .. i, 'src', icon_of(b)) end
    end
    D:text('sspg', string.format('%d / %d', sspage, spages))
    D:class('bdset', 'dis', sel_set == nil)
end
local function lib_list()
    local t = {}
    local q = lsearch:lower()
    for _, k in ipairs(C.buttons_sorted()) do
        local b = C.settings.Buttons[k]
        if q == '' or tostring(b.Label or ''):lower():find(q, 1, true) or tostring(b.Cmd or ''):lower():find(q, 1, true) then t[#t + 1] = k end
    end
    return t
end
local function page_lib()
    local t = lib_list()
    local pages = math.max(1, math.ceil(#t / 11)); blpage = math.min(blpage, pages)
    maps.bl = {}
    for i = 1, 11 do
        local k = t[(blpage - 1) * 11 + i]; maps.bl[i] = k
        D:class('bl' .. i, 'off', k == nil)
        if k then
            local b = C.settings.Buttons[k]
            D:text('bln' .. i, P.esc(P.clip(C.label(b, false), 24))); D:text('blm' .. i, P.esc(P.clip(tostring(b.Cmd or ''):gsub('\n', ' | '), 34))); D:attr('bli' .. i, 'src', icon_of(b))
        end
    end
    D:text('lcount', string.format('%d button%s', #t, #t == 1 and '' or 's'))
    D:text('blpg', string.format('%d / %d', blpage, pages))
    D:text('blto', sel_set and ('"Add to set" puts the button in the next empty slot of ' .. P.esc(P.clip(sel_set, 20))) or 'Pick a set on the Sets page first.')
end
local function page_share()
    maps.xs = C.sets_sorted()
    for i = 1, 12 do local s = maps.xs[i]; D:class('xs' .. i, 'hide', s == nil); if s then D:text('xs' .. i, P.esc(P.clip(s, 16))) end end
    local pv = (inp.imp or '') ~= '' and C.preview_import(inp.imp) or nil
    D:text('impv', (inp.imp or '') == '' and 'Paste the text someone shared with you.' or (pv and ('Ready to import ' .. P.esc(pv) .. ' into bar ' .. bar_id) or 'That is not ButtonMaster share text.'))
    D:class('bimp', 'dis', pv == nil)
    maps.cl = C.other_chars()
    for i = 1, 5 do
        local k = maps.cl[i]; D:class('cl' .. i, 'off', k == nil)
        if k then D:text('cln' .. i, P.esc(k:gsub('_', '  -  ', 1))); D:text('clb' .. i, confirm == 'cl' .. i and 'Click again to replace mine' or 'Copy to me'); D:class('clb' .. i, 'red', confirm == 'cl' .. i) end
    end
    D:class('clnone', 'hide', #maps.cl > 0)
end
local function page_fx()
    D:class('o-rfx', 'on', C.settings.Rml.Reduced)
    for _, q in ipairs({ 'low', 'balanced', 'high' }) do D:class('q-' .. q, 'on', C.settings.Rml.Quality == q) end

    local nb, nv = F.hooks.count_anim()
    D:text('fxstat', string.format('%d animated button%s on %d visible bar%s.  Lua last frame %.2f ms.', nb, nb == 1 and '' or 's', nv, nv == 1 and '' or 's', F.hooks.last_ms() or 0))
end
local function page_sim()
    local wins = C.char().Windows
    sim_bar = sim_bar or S.target or bar_id
    for i = 1, 8 do D:class('sb' .. i, 'hide', wins[i] == nil); D:class('sb' .. i, 'on', sim_bar == i) end
    D:class('sb-demo', 'on', sim_bar == 'demo')
    D:text('splay', S.playing and 'Pause' or 'Play'); D:class('splay', 'go', not S.playing)
    for _, k in ipairs({ '05', '1', '2' }) do D:class('spd-' .. k, 'on', S.speed == ({ ['05'] = 0.5, ['1'] = 1, ['2'] = 2 })[k]) end
    D:class('sm-rot', 'on', S.mode == 'rot'); D:class('sm-rand', 'on', S.mode == 'rand')
    local bar = F.hooks.bar(sim_bar)
    local active = S.active(sim_bar)
    D:text('sstat', active and string.format('Simulating %s  -  %s  -  %d presses  -  clicks on that bar are simulated, commands are NOT sent.', sim_bar == 'demo' and 'the demo bar' or ('bar ' .. sim_bar), S.playing and ('playing at ' .. S.speed .. 'x') or 'paused', S.presses)
        or 'Pick a bar, then press Play. Nothing is sent to the game while a bar is simulated.')
    local n = bar and bar:geometry().n or 0
    local used = {}
    for idx = 1, n do if bar:button(idx) then used[#used + 1] = idx end end
    local pages = math.max(1, math.ceil(#used / 8)); srpage = math.min(srpage, pages)
    maps.sr = {}
    for i = 1, 8 do
        local idx = used[(srpage - 1) * 8 + i]
        local b = idx and bar:button(idx) or nil
        maps.sr[i] = b and idx or nil
        D:class('sr' .. i, 'off', b == nil)
        if b then
            D:text('srn' .. i, P.esc(string.format('%d.  %s', idx, P.clip(C.label(b, false), 18)))); D:attr('sri' .. i, 'src', icon_of(b))
            local s = active and S.slot(idx) or { st = 'ready' }
            D:text('srs' .. i, active and P.esc(S.describe(idx)) or '')
            D:class('srr' .. i, 'on', active and s.st == 'ready'); D:class('src' .. i, 'on', active and s.st == 'cd'); D:class('srd' .. i, 'on', active and s.st == 'dis'); D:class('srk' .. i, 'on', active and s.cond)
            D:class('srp' .. i, 'dis', not active)
        end
    end
    D:text('srpg', string.format('%d / %d', srpage, pages))
end
local function paint()
    D:class('body', 'clear', C.settings.Rml.Clear)
    D:text('hsub', P.esc(('OBSIDIAN FORGE  -  ' .. tostring(C.CharConfig):gsub('_', ' ', 1)):upper()))
    apply_tab()
    if tab == 'bars' then page_bars() elseif tab == 'sets' then page_sets() elseif tab == 'lib' then page_lib()
    elseif tab == 'share' then page_share() elseif tab == 'fx' then page_fx() elseif tab == 'sim' then page_sim() end
end
F.paint = function() if shown then paint() end end

-- keep the whole window on screen (saved positions from another resolution or a dragged-off window)
local function clamp_pos(x, y)
    local sw, sh = F.hooks.screen()
    x = math.max(0, math.min(math.max(0, sw - WW), tonumber(x) or 300))
    y = math.max(0, math.min(math.max(0, sh - WH), tonumber(y) or 120))
    return math.floor(x), math.floor(y)
end
function F.open(which, bar)
    if not W then F.create() end
    if not W then C.out('\arThe settings window could not be opened (%s). Check that lua\\buttonmaster_rml\\ui\\forge.rml exists.', tostring(F.open_err or 'rmlui.open failed')); return end
    if bar then bar_id = bar; if which == 'sim' then sim_bar = bar end end
    tab = which or tab
    local p = C.settings.Rml.ForgePos or {}; local x, y = clamp_pos(p.x, p.y)
    pcall(function() W:place(x, y, WW, WH) end)
    shown = true; pcall(function() W:show(true) end)
    C.settings.Rml.ForgeOpen = true; C.save_soon()
    local w = win(); set_input('btitle', w and w.Rml and w.Rml.Title or '')
    local ok, e = pcall(paint); if not ok then C.out('\arSettings window paint error: %s', tostring(e)) end
end
function F.hide() shown = false; C.settings.Rml.ForgeOpen = false; C.save_soon(); if W then pcall(function() W:show(false) end) end end
function F.visible() return shown end
function F.toggle() if shown then F.hide() else F.open() end end

local function start_sim(id)
    local bar = F.hooks.bar(id)
    if id == 'demo' then F.hooks.demo(true); bar = F.hooks.bar('demo') end
    if not bar then return end
    S.start(id, bar:geometry().n); sim_bar = id
end
F.start_sim = start_sim
local function stop_sim() if S.target == 'demo' then F.hooks.demo(false) end; S.stop() end
F.stop_sim = stop_sim

local function step(id, d)
    local w = win(); local r = w.Rml or {}; w.Rml = r
    local bar = F.hooks.bar(bar_id); local g = bar and bar:geometry()
    if id == 'cols' then r.Cols = math.max(1, math.min(12, (g and g.cols or 6) + d))
    elseif id == 'rows' then r.Rows = math.max(1, math.min(8, (g and g.rows or 1) + d))
    elseif id == 'size' then r.Size = math.max(24, math.min(96, (g and g.sz or 48) + d * 4))
    elseif id == 'gap' then r.Gap = math.max(0, math.min(16, (tonumber(r.Gap) or 4) + d)) end
    if (r.Cols or 1) * (r.Rows or 1) > 48 then r.Rows = math.floor(48 / r.Cols) end
    C.save_soon()
end
local function on_event(ev)
    if ev.type == 'windowmoved' then local x, y = F.hooks.parse(ev.value); if x then C.settings.Rml.ForgePos = { x = x, y = y }; C.save_soon() end; return end
    if ev.type == 'change' or ev.type == 'submit' then
        local v = tostring(ev.value or ''); inp[ev.id] = v; D.c['a' .. (ev.id or '') .. ' value'] = v
        if ev.id == 'btitle' then local w = win(); w.Rml = w.Rml or {}; w.Rml.Title = v ~= '' and v or nil; C.save_soon()
        elseif ev.id == 'lsearch' then lsearch = v; blpage = 1 end
        if ev.type == 'submit' then
            local map = { nset = 'newset', rset = 'renset', imp = 'import' }
            if map[ev.id] then ev = { type = 'click', action = map[ev.id], button = 0 } else paint(); return end
        else paint(); return end
    end
    if ev.type ~= 'click' then return end
    local a = ev.action or ''
    local k, v = a:match('^(%w+):(.+)$'); local n = tonumber(v)
    local w = win()
    local keep_confirm = false
    if k == 'tab' then tab = v; if v == 'bars' then set_input('btitle', w.Rml and w.Rml.Title or '') end
    elseif a == 'close' then F.hide(); return
    elseif a == 'clear' then C.settings.Rml.Clear = not C.settings.Rml.Clear; F.hooks.clear(C.settings.Rml.Clear); C.save_soon()
    elseif k == 'bar' then bar_id = n; set_input('btitle', win().Rml and win().Rml.Title or '')
    elseif a == 'newbar' then
        local wins = C.char().Windows
        if #wins < 8 then
            wins[#wins + 1] = { Visible = true, Sets = {}, Locked = false, HideTitleBar = false, CompactMode = false, AdvTooltips = true, Pos = { x = 500, y = 500 }, Rml = { Cols = 6, Rows = 1 } }
            bar_id = #wins; C.save(true); F.hooks.sync(); msg('Created bar ' .. bar_id .. '. Add a set to it below.')
        end
    elseif a == 'delbar' then
        local wins = C.char().Windows
        if #wins > 1 then
            if confirm ~= 'delbar' then confirm = 'delbar'; keep_confirm = true; msg('Click Delete again to remove bar ' .. bar_id .. ' (its sets and buttons are kept).', true)
            else table.remove(wins, bar_id); bar_id = 1; C.save(true); F.hooks.reopen() end
        end
    elseif a == 'showall' then for _, x in ipairs(C.char().Windows) do x.Visible = true end; C.save(true)
    elseif a == 'resetpos' then w.Pos = { x = 200, y = 200 }; C.save(true); F.hooks.reopen_one(bar_id)
    elseif k == 'o' then
        if v == 'vis' then w.Visible = w.Visible == false
        elseif v == 'lock' then w.Locked = not w.Locked
        elseif v == 'title' then w.HideTitleBar = not w.HideTitleBar
        elseif v == 'compact' then w.CompactMode = not w.CompactMode
        elseif v == 'adv' then w.AdvTooltips = w.AdvTooltips == false
        elseif v == 'rfx' then C.settings.Rml.Reduced = not C.settings.Rml.Reduced end
        C.save(true); F.hooks.invalidate()
    elseif k == 'inc' or k == 'dec' then step(v, k == 'inc' and 1 or -1)
    elseif k == 'theme' then w.Rml = w.Rml or {}; w.Rml.Theme = v; C.save_soon()
    elseif k == 'fps' then w.FPS = ({ 0, 1, 2.5, 10 })[n]; C.save_soon()
    elseif k == 'bsu' and n then if n > 1 then w.Sets[n], w.Sets[n - 1] = w.Sets[n - 1], w.Sets[n] end; C.save(true)
    elseif k == 'bsd' and n then if w.Sets[n + 1] then w.Sets[n], w.Sets[n + 1] = w.Sets[n + 1], w.Sets[n] end; C.save(true)
    elseif k == 'bsx' and n then table.remove(w.Sets, n); C.save(true)
    elseif k == 'as' and n and maps.as[n] then table.insert(w.Sets, maps.as[n]); C.save(true)
    -- sets page
    elseif k == 'sl' and n and maps.sl[n] then sel_set = maps.sl[n]; sspage = 1; set_input('rset', '')
    elseif a == 'slp:prev' then slpage = math.max(1, slpage - 1)
    elseif a == 'slp:next' then slpage = slpage + 1
    elseif a == 'ssp:prev' then sspage = math.max(1, sspage - 1)
    elseif a == 'ssp:next' then sspage = sspage + 1
    elseif a == 'newset' then
        local ok, e = C.create_set(inp.nset)
        if ok then sel_set = inp.nset:gsub('^%s+', ''):gsub('%s+$', ''); set_input('nset', ''); msg('Created set "' .. sel_set .. '". Add it to a bar on the Bars page.') else msg(e, true) end
    elseif a == 'renset' then if sel_set then local ok, e = C.rename_set(sel_set, inp.rset); if ok then sel_set = inp.rset; set_input('rset', ''); F.hooks.invalidate() else msg(e, true) end end
    elseif a == 'delset' then
        if sel_set then
            if confirm ~= 'delset' then confirm = 'delset'; keep_confirm = true; msg('Click Delete set again to delete "' .. sel_set .. '" (its buttons stay in the library).', true)
            else C.delete_set(sel_set); sel_set = nil; F.hooks.invalidate() end
        end
    elseif k == 'sse' and n and maps.ss[n] then F.hooks.edit(bar_id, sel_set, maps.ss[n])
    elseif k == 'ssu' and n and maps.ss[n] then local i = maps.ss[n]; local t = C.settings.Sets[sel_set]; if i > 1 then t[i], t[i - 1] = t[i - 1], t[i]; C.save(true); F.hooks.invalidate() end
    elseif k == 'ssd' and n and maps.ss[n] then local i = maps.ss[n]; local t = C.settings.Sets[sel_set]; t[i], t[i + 1] = t[i + 1], t[i]; C.save(true); F.hooks.invalidate()
    elseif k == 'ssx' and n and maps.ss[n] then C.settings.Sets[sel_set][maps.ss[n]] = nil; C.save(true); F.hooks.invalidate()
    elseif a == 'ssnew' then if sel_set then local i = 1; while C.settings.Sets[sel_set][i] do i = i + 1 end; F.hooks.edit(bar_id, sel_set, i, true) else msg('Create or pick a set first.', true) end
    -- library
    elseif a == 'blp:prev' then blpage = math.max(1, blpage - 1)
    elseif a == 'blp:next' then blpage = blpage + 1
    elseif k == 'ble' and n and maps.bl[n] then F.hooks.edit(nil, nil, nil, false, maps.bl[n])
    elseif k == 'bla' and n and maps.bl[n] then
        if not sel_set then msg('Pick a set on the Sets page first.', true)
        else local i = 1; while C.settings.Sets[sel_set][i] do i = i + 1 end; C.settings.Sets[sel_set][i] = maps.bl[n]; C.save(true); F.hooks.invalidate(); msg(string.format('Added to %s, slot %d.', sel_set, i)) end
    elseif k == 'blx' and n and maps.bl[n] then
        if confirm ~= 'blx' .. n then confirm = 'blx' .. n; keep_confirm = true; msg('Click Delete again to delete "' .. C.label(C.settings.Buttons[maps.bl[n]], true) .. '" everywhere.', true)
        else C.delete_button(maps.bl[n]); F.hooks.invalidate() end
    elseif a == 'dedupe' then local c = C.dedupe(); F.hooks.invalidate(); msg(string.format('Removed %d duplicate button%s.', c, c == 1 and '' or 's'))
    -- share
    elseif k == 'xs' and n and maps.xs[n] then pcall(function() ImGui.SetClipboardText(C.export_set(maps.xs[n])) end); msg('Share text for set "' .. maps.xs[n] .. '" is on your clipboard.')
    elseif a == 'paste' then local ok, t = pcall(function() return ImGui.GetClipboardText() end); if ok and t then set_input('imp', t) end
    elseif a == 'import' then
        local ok, e = C.import(inp.imp, bar_id)
        msg(e, not ok); if ok then set_input('imp', ''); F.hooks.invalidate() end
    elseif k == 'cl' and n and maps.cl[n] then
        if confirm ~= 'cl' .. n then confirm = 'cl' .. n; keep_confirm = true
        else C.copy_local(maps.cl[n]); F.hooks.reopen(); msg('Copied the bars of ' .. maps.cl[n] .. '.') end
    -- effects
    elseif k == 'q' then C.settings.Rml.Quality = v; C.save_soon()

    -- simulator
    elseif k == 'sbar' then local id = tonumber(v) or v; if S.target and S.target ~= id then stop_sim() end; sim_bar = id; start_sim(id); srpage = 1
    elseif a == 'splay' then if not S.active(sim_bar) then start_sim(sim_bar) end; S.playing = not S.playing
    elseif a == 'sreset' then S.reset()
    elseif a == 'sstop' then stop_sim()
    elseif k == 'spd' then S.speed = ({ ['05'] = 0.5, ['1'] = 1, ['2'] = 2 })[v]
    elseif k == 'smode' then S.mode = v
    elseif a == 'srpg:prev' then srpage = math.max(1, srpage - 1)
    elseif a == 'srpg:next' then srpage = srpage + 1
    elseif (k == 'srp' or k == 'srr' or k == 'src' or k == 'srd' or k == 'srk') and n and maps.sr[n] then
        if not S.active(sim_bar) then start_sim(sim_bar) end
        local idx = maps.sr[n]; local bar = F.hooks.bar(sim_bar)
        if k == 'srp' then S.press(idx, bar and bar:button(idx)) else S.set(idx, ({ srr = 'ready', src = 'cd', srd = 'dis', srk = 'cond' })[k]) end
    else return end
    if not keep_confirm then confirm = nil end
    paint()
end
function F.create()
    local p = C.settings.Rml.ForgePos or {}
    local x, y = clamp_pos(p.x, p.y)
    local ok, w = pcall(rmlui.open, 'ButtonMasterRml_Forge', 'buttonmaster_rml/ui/forge.rml', { width = WW, height = WH, x = x, y = y, theme = false })
    if not ok or not w then F.open_err = ok and 'rmlui.open returned nothing' or tostring(w); W = nil; return end
    W = w
    D = P.dom(W)
    pcall(function() W:reload() end); pcall(function() W:place(x, y, WW, WH) end); pcall(function() W:show(false) end)
end
local next_live = 0
function F.frame(t)
    if not W then return end
    for ev in W:events() do on_event(ev) end
    if not shown then return end
    if msg_until > 0 and t > msg_until then msg_until = 0; D:text('msg', '') end
    if (tab == 'sim' or tab == 'fx') and t >= next_live then next_live = t + 250; paint() end
end
function F.shutdown() if W then pcall(function() W:close() end) end end
function F.state() return { tab = tab, bar = bar_id, sel_set = sel_set, sim_bar = sim_bar } end
return F
