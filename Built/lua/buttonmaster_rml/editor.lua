-- Button Forge (editor window): Action / Icon / Look / Effects / Timer / Styles, with a live preview of the button.
-- Edits a copy; Save writes it back (new buttons get a fresh Button_N key in the slot). Inputs live on pages that are
-- parked off-screen instead of display:none (text inputs keep their state that way).
local mq = require('mq')
local rmlui = require('rmlui')
local C = require('buttonmaster_rml.core')
local P = require('buttonmaster_rml.paint')
local LIB = require('buttonmaster_rml.iconlib')
local E = { hooks = {} }
local WW, WH = 900, 600
local W, D
local shown = false
local tab = 'act'
local ctx = {}                -- { bar=, set=, idx=, key=, b= (working copy) }
local isrc, icat, isearch, ipage = 'gi', 'all', '', 1
local GLIB          -- game-icons index, loaded the first time the picker needs it
local function glib() if not GLIB then GLIB = require('buttonmaster_rml.gamelib') end; return GLIB end
E.GI_CATS = { 'all', 'Weapons', 'Magic', 'Creatures', 'Armor', 'Potions', 'Items', 'Classes', 'Buffs', 'Body', 'Nature', 'Utility', 'Tech', 'Symbols', 'Other' }
E.FG_CATS = { 'all', 'Elements', 'Weapons', 'Buffs', 'Utility', 'Classes' }
local filtered, gridmap = {}, {}
local fxsel = 'fire'
local pvst = { rdy = true }
local psim = nil
local nlines = 1
local MAXSPELL, MAXITEM = 2243, 12599
local PAL = { 'ff8a2a', 'ffd27a', 'fff2c0', 'ff4a3a', 'c22a2a', 'c28bff', '7a4ae0', '9fdcff', '3a8ae0', '7ae08a', '2a9a4a', 'ffffff', 'b8a69c', '4a3a34', '2a1a14', '000000' }
local msg_t, msg_until = '', 0
local cfg_pos = {}

local function msg(t, bad) msg_t = t; msg_until = mq.gettime() + 4000; D:text('msg', P.esc(t)); D:class('msg', 'bad', bad) end
local function tlo(f, d) return C.tlo(f, d) end

function E.visible() return shown end
local function look() return C.look(ctx.b) end
local function bump() local r = look(); r._v = (r._v or 0) + 1 end

-- ---------------------------------------------------------------- icon picker
local function rebuild_filter()
    filtered = {}
    local q = isearch:lower()
    local t0 = os.clock()
    if isrc == 'gi' then
        local words = {}; for w in q:gmatch('%S+') do words[#words + 1] = w end
        for _, e in ipairs(glib()) do
            if icat == 'all' or e[1] == icat then
                local okw = true; for _, w in ipairs(words) do if not e[3]:find(w, 1, true) then okw = false; break end end
                if okw then filtered[#filtered + 1] = e[2] end
            end
        end
    elseif isrc == 'custom' then
        for _, e in ipairs(LIB) do
            if (icat == 'all' or e[1] == icat) and (q == '' or e[3]:lower():find(q, 1, true) or e[1]:lower():find(q, 1, true)) then filtered[#filtered + 1] = e[2] end
        end
    end
    E.filter_ms = (os.clock() - t0) * 1000
end
local function icon_total() if isrc == 'custom' or isrc == 'gi' then return #filtered elseif isrc == 'spell' then return MAXSPELL + 1 else return MAXITEM + 1 end end
local function paint_icons()
    local total = icon_total(); local pages = math.max(1, math.ceil(total / 60))
    if ipage > pages then ipage = pages end
    for _, k in ipairs({ 'gi', 'custom', 'spell', 'item' }) do D:class('src-' .. k, 'on', isrc == k) end
    D:class('cats', 'hide', isrc ~= 'custom'); D:class('gcats', 'hide', isrc ~= 'gi')
    for _, k in ipairs(E.FG_CATS) do D:class('cat-' .. k, 'on', icat == k) end
    for _, k in ipairs(E.GI_CATS) do D:class('gc-' .. k, 'on', icat == k) end
    D:class('icgrid', 'gi', isrc == 'gi')
    local cur, curty = ctx.b.Icon, ctx.b.IconType or 'Spell'
    for i = 1, 60 do
        local n = (ipage - 1) * 60 + i
        local id, ty
        if isrc == 'custom' or isrc == 'gi' then id = filtered[n]; ty = isrc == 'gi' and 'GI' or 'Rml' else id = (n - 1 <= total - 1) and (n - 1) or nil; ty = (isrc == 'item') and 'Item' or 'Spell' end
        gridmap[i] = id ~= nil and { id = id, ty = ty } or nil
        D:class('g' .. i, 'off', id == nil)
        if id ~= nil then
            D:attr('gi' .. i, 'src', P.icon_src(id, ty) or '../img/ui/none.png')
            D:class('g' .. i, 'on', tostring(cur) == tostring(id) and curty == ty)
        end
    end
    D:text('ipage', string.format('Page %d of %d', ipage, pages))
    D:class('iprev', 'dis', ipage <= 1); D:class('inext', 'dis', ipage >= pages)
    D:text('ihint', isrc == 'gi' and string.format('%d game-icons.net icons (CC BY 3.0)', total) or isrc == 'custom' and string.format('%d Forge icons', total) or 'Type an icon number in the box to jump to it')
end

-- ---------------------------------------------------------------- pages
local function swatches(pfx, val)
    val = tostring(val or ''):lower():gsub('#', '')
    for i, c in ipairs(PAL) do D:class(pfx .. i, 'on', c == val) end
end
local TT = { [0] = nil, 'Seconds Timer', 'Item', 'Spell Gem', 'AA', 'Ability', 'Disc', 'Custom Lua' }
local TTL = { ['Seconds Timer'] = 'Seconds', Item = 'Item name', ['Spell Gem'] = 'Gem number', AA = 'AA name or ID', Ability = 'Ability name', Disc = 'Disc name' }
local TTH = { ['Seconds Timer'] = 'Starts a countdown each time you press the button.', Item = 'Reads the clicky timer of the item.', ['Spell Gem'] = 'Reads the recast timer of that spell gem.',
    AA = 'Reads the reuse timer of the alternate ability.', Ability = 'Reads the skill timer (Taunt, Kick ...).', Disc = 'Reads the combat ability timer.', ['Custom Lua'] = 'Each box is a Lua snippet that returns a number (or true for the toggle check).' }
local function set_input(id, v) D:forget(id, 'value'); D:attr(id, 'value', v or '') end
local function load_inputs()
    local b = ctx.b; local r = look()
    set_input('elabel', b.Label or ''); set_input('eiconlua', b.IconLua or '')
    local lines = C.split(b.Cmd or '', '\n'); nlines = math.max(1, math.min(8, #lines))
    for i = 1, 8 do set_input('ec' .. i, lines[i] or '') end
    set_input('hxb', r.Border or ''); set_input('hx1', r.Bg1 or ''); set_input('hx2', r.Bg2 or ''); set_input('hxl', r.LabelColor or '')
    set_input('fcond', r.Cond or ''); set_input('isearch', ''); isearch = ''
    set_input('tval', b.TimerType ~= 'Custom Lua' and tostring(b.Cooldown or '') or '')
    set_input('ttimer', b.TimerType == 'Custom Lua' and (b.Timer or '') or ''); set_input('tcool', b.TimerType == 'Custom Lua' and tostring(b.Cooldown or '') or ''); set_input('ttog', b.ToggleCheck or '')
    set_input('stname', ''); set_input('hxf', '')
end
local function paint_fx()
    local r = look(); local fx = r.Fx
    for _, k in ipairs(C.EFFECTS) do
        local e = fx[k]
        D:class('fx-' .. k, 'on', e and e.On or false); D:class('fx-' .. k, 'sel', k == fxsel)
        local tr = (k ~= 'flash' and k ~= 'bounce' and e and e.On) and ({ always = 'Always', ready = 'Ready', cooldown = 'Cooldown', hover = 'Hover', cond = 'Condition' })[e.Trig or 'always'] or ''
        D:text('fxt-' .. k, tr)
    end
    local e = fx[fxsel] or {}
    D:text('fxname', C.EFFECT_NAMES[fxsel]); D:class('o-fxon', 'on', e.On)
    local simple = fxsel == 'flash' or fxsel == 'bounce'
    D:class('fxkind', 'hide', fxsel ~= 'pack')
    for _, pk in ipairs(C.PACK_KINDS) do D:class('pkc-' .. pk, 'on', (e.Kind or 'blaze') == pk) end
    D:class('fxtrig', 'hide', simple); D:class('fxint', 'hide', simple); D:class('fxcol', 'hide', fxsel == 'bounce')
    D:text('fxdesc', ({ flash = 'One bright flash when the cooldown ends', bounce = 'The button dips when you press it', glow = 'Soft halo around the button', pulse = 'Halo that breathes in and out', fire = 'Animated flames around the edge',
        frost = 'Ice shards drifting around the edge', arcane = 'Rotating rune rings', bolt = 'Crackling lightning arcs', shine = 'A glossy sweep across the icon', pack = C.PACK_DESC[e.Kind or 'blaze'] })[fxsel] or '')
    for _, t in ipairs({ 'always', 'ready', 'cooldown', 'hover', 'cond' }) do D:class('ft-' .. t, 'on', (e.Trig or 'always') == t) end
    for _, v in ipairs({ 25, 50, 75, 100 }) do D:class('fi-' .. v, 'on', (tonumber(e.Int) or 100) == v) end
    swatches('swf', e.Col or (fxsel == 'pack' and C.PACK_COL[e.Kind or 'blaze']) or C.FX_DEFCOL[fxsel])
    local red = C.settings.Rml.Reduced
    D:text('fxglob', red and 'Reduced effects is on for every bar, so animated effects are paused (glow and flash still show). Change it in Button Master > Effects.'
        or string.format('Effects quality: %s. Animated effects step at %d frames a second.', C.settings.Rml.Quality, ({ low = 6, balanced = 10, high = 15 })[C.settings.Rml.Quality] or 10))
end
local function paint_page()
    local b, r = ctx.b, look()
    if tab == 'act' then
        D:class('o-eval', 'on', b.EvaluateLabel)
        for i = 1, 8 do D:class('cl' .. i, 'off', i > nlines) end
        D:class('eaddl', 'dis', nlines >= 8); D:class('edell', 'dis', nlines <= 1)
    elseif tab == 'icon' then paint_icons()
    elseif tab == 'look' then
        for _, s in ipairs({ 'round', 'square', 'rounded', 'hex' }) do D:class('shp-' .. s, 'on', r.Shape == s) end
        for _, s in ipairs({ 'metal', 'gem', 'rune', 'plain', 'bevel', 'filigree', 'neon', 'none' }) do D:class('frm-' .. s, 'on', r.Frame == s) end
        local lp = b.ShowLabel == false and 'none' or (r.LabelPos or 'over')
        for _, s in ipairs({ 'none', 'under', 'over' }) do D:class('lp-' .. s, 'on', lp == s) end
        for _, s in ipairs({ 9, 10, 11, 12, 13, 14, 16 }) do D:class('ls-' .. s, 'on', tonumber(r.LabelSize) == s) end
        swatches('swb', r.Border); swatches('sw1', r.Bg1); swatches('sw2', r.Bg2); swatches('swl', r.LabelColor)
    elseif tab == 'fx' then paint_fx()
    elseif tab == 'tim' then
        local k = 0; for i = 1, 7 do if TT[i] == b.TimerType then k = i end end
        for i = 0, 7 do D:class('tt' .. i, 'on', i == k) end
        D:class('trow', 'hide', k == 0 or k == 7); D:class('tcus', 'hide', k ~= 7)
        D:text('tvl', TTL[b.TimerType] or '')
        D:text('thelp', TTH[b.TimerType] or 'No cooldown is shown for this button.')
        local ur = 1; for i, v in ipairs(C.UpdateRates) do if (tonumber(b.UpdateRate) or 0) == v[2] then ur = i end end
        for i = 1, 6 do D:class('ur' .. i, 'on', i == ur) end
    elseif tab == 'sty' then
        for i, p in ipairs(C.PRESETS) do D:text('pr' .. i, P.esc(p.name)) end
        local st = C.settings.Rml.Styles
        for i = 1, 7 do D:class('st' .. i, 'off', st[i] == nil); if st[i] then D:text('stn' .. i, P.esc(P.clip(st[i].name, 30))) end end
        D:class('stempty', 'hide', #st > 0)
    end
end
local function paint_preview()
    local b = ctx.b
    local lab = C.label(b, true)
    P.look(D, 'P', 1, b, { size = 112, label = lab, tip = '' })
    P.look(D, 'Q', 1, b, { size = 40, label = lab, tip = '' })
    for _, k in ipairs({ 'rdy', 'cd', 'cnd', 'dis' }) do D:class('pv-' .. k, 'on', pvst[k]) end
    local n, a = 0, 0
    for k, e in pairs(look().Fx) do if e.On then n = n + 1; if C.ANIMATED[k] then a = a + 1 end end end
    D:text('pfxinfo', n == 0 and 'No effects on this button.' or string.format('%d effect%s on, %d animated.', n, n == 1 and '' or 's', a))
end
local function preview_state(t)
    local st = { cd = 0, tot = 0, cond = pvst.cnd, dis = pvst.dis }
    if psim then
        local el = (t - psim.t0) / 1000
        if el < 0.16 then st.prs = true
        elseif el < 0.16 + psim.tot then st.cd = psim.tot - (el - 0.16); st.tot = psim.tot
        else local f = 1 - (el - 0.16 - psim.tot) / 0.45; if f <= 0 then psim = nil; f = 0 end; st.flash = f end
    elseif pvst.cd then st.cd, st.tot = 7, 12 end
    if not (look().Fx.flash and look().Fx.flash.On) then st.flash = 0 end
    for _, p in ipairs({ 'P', 'Q' }) do P.state(D, p, 1, st) end
end
local function apply_tab()
    for _, k in ipairs({ 'act', 'icon', 'look', 'fx', 'tim', 'sty' }) do D:class('pg-' .. k, 'on', k == tab); D:class('tab-' .. k, 'on', k == tab) end
end
local function header()
    local where = ctx.set and string.format('%s  -  slot %d', ctx.set, ctx.idx or 0) or 'library button'
    D:text('hsub', P.esc(((ctx.key and 'EDITING  ' or 'NEW BUTTON  ') .. where):upper()))
    D:class('edel', 'dis', ctx.key == nil); D:class('eunas', 'dis', ctx.key == nil or ctx.set == nil); D:class('eexp', 'dis', ctx.key == nil)
    D:class('body', 'clear', C.settings.Rml.Clear)
end
local function repaint() header(); apply_tab(); paint_page(); paint_preview() end

-- ---------------------------------------------------------------- open / save
local function fill_from_cursor(b)
    local ok = false
    pcall(function()
        local ca = mq.TLO.CursorAttachment
        if not ca or not ca.Type() then return end
        local ty = ca.Type():lower(); local txt = (ca.ButtonText() or ''):gsub('\n', ' ')
        if ty == 'item' or ty == 'item_link' then
            b.Label = ca.Item(); b.Cmd = string.format('/useitem "%s"', ca.Item()); b.Icon = tostring((ca.Item.Icon() or 500) - 500); b.IconType = 'Item'; b.Cooldown = ca.Item(); b.TimerType = 'Item'; ok = true
        elseif ty == 'spell_gem' then
            local gem = ca.Index() + 1
            b.Label = ca.Spell.RankName(); b.Cmd = string.format('/cast %d', gem); b.Icon = tostring(ca.Spell.SpellIcon()); b.IconType = 'Spell'; b.Cooldown = gem; b.TimerType = 'Spell Gem'; ok = true
        elseif ty == 'skill' then b.Label = txt; b.Cmd = '/doability ' .. txt; b.Icon = nil; b.Cooldown = txt; b.TimerType = 'Ability'; ok = true
        elseif ty == 'combat_ability' then b.Label = txt; b.Cmd = '/disc ' .. txt; b.Icon = mq.TLO.Spell(txt).SpellIcon(); b.IconType = 'Spell'; b.Cooldown = txt; b.TimerType = 'Disc'; ok = true
        elseif ty == 'social' then
            b.Label = txt
            local idx = ca.Index()
            if idx >= 120 then b.Cmd = string.format('/alt act %d', idx - 120); b.Cooldown = txt; b.TimerType = 'AA'
            else
                local lines = {}
                for i = 0, 4 do local l = mq.TLO.Social(idx).Cmd(i)(); if l and #l > 0 then lines[#lines + 1] = l end end
                b.Cmd = table.concat(lines, '\n')
            end
            ok = true
        end
    end)
    return ok
end
E.fill_from_cursor = fill_from_cursor
function E.open(bar, set, idx, create_from_cursor, libkey)
    local b, key
    if libkey then key = libkey; b = C.settings.Buttons[libkey]
    elseif set and idx then b, key = C.button_at(set, idx) end
    ctx = { bar = bar, set = set, idx = idx, key = key, b = b and C.deepcopy(b) or { Label = '', Cmd = '' } }
    C.look(ctx.b)
    if not b and create_from_cursor then
        if fill_from_cursor(ctx.b) then pcall(function() mq.cmd('/autoinventory') end) end
    end
    psim = nil; pvst = { rdy = true }; fxsel = 'fire'; ipage = 1
    isrc = (ctx.b.IconType == 'Item' and 'item') or ((ctx.b.IconType == nil or ctx.b.IconType == 'Spell') and ctx.b.Icon and 'spell') or 'custom'
    rebuild_filter()
    if (isrc == 'spell' or isrc == 'item') and tonumber(ctx.b.Icon) then ipage = math.floor(tonumber(ctx.b.Icon) / 60) + 1 end
    if not W then E.create() end
    D:reset(); load_inputs()
    tab = (not b) and 'act' or tab
    shown = true; pcall(function() W:show(true) end)
    repaint()
    if not b and create_from_cursor and ctx.b.Label ~= '' then msg('Filled from the item or spell on your cursor.') end
end
local function save()
    local b = ctx.b
    local lines = {}
    for i = 1, nlines do local v = ctx.lines and ctx.lines[i]; if v == nil then v = nil end end
    if (b.Label or '') == '' and (b.Cmd or '') == '' then msg('Give the button a label or a command first.', true); return false end
    bump(); b.CachedLabel = nil; b.CachedIcon = nil; b.CachedCountDown = nil; b.CachedLastRan = nil
    local key = ctx.key or C.gen_key()
    C.settings.Buttons[key] = C.clean(b)
    if ctx.set and ctx.idx then C.settings.Sets[ctx.set] = C.settings.Sets[ctx.set] or {}; C.settings.Sets[ctx.set][ctx.idx] = key end
    ctx.key = key
    C.save(true); E.hooks.changed()
    return true
end
function E.hide() shown = false; if W then pcall(function() W:show(false) end) end end

-- ---------------------------------------------------------------- events
local INPUT = {
    elabel = function(v) ctx.b.Label = v; ctx.b.CachedLabel = nil end,
    eiconlua = function(v) ctx.b.IconLua = v ~= '' and v or nil; ctx.b.CachedIcon = nil end,
    isearch = function(v)
        if isrc == 'custom' or isrc == 'gi' then isearch = v; ipage = 1; rebuild_filter()
        else local n = tonumber(v); if n then ipage = math.floor(n / 60) + 1 end end
    end,
    hxb = function(v) if P.hex(v) then look().Border = P.hex(v):sub(2) end end,
    hx1 = function(v) if P.hex(v) then look().Bg1 = P.hex(v):sub(2) end end,
    hx2 = function(v) if P.hex(v) then look().Bg2 = P.hex(v):sub(2) end end,
    hxl = function(v) if P.hex(v) then look().LabelColor = P.hex(v):sub(2) end end,
    hxf = function(v) if P.hex(v) then local e = look().Fx[fxsel] or { On = true }; e.Col = P.hex(v):sub(2); look().Fx[fxsel] = e end end,
    fcond = function(v) look().Cond = v ~= '' and v or nil; ctx.b.CachedCond = nil end,
    tval = function(v) ctx.b.Cooldown = (ctx.b.TimerType == 'Seconds Timer' or ctx.b.TimerType == 'Spell Gem') and (tonumber(v) or v) or v end,
    ttimer = function(v) ctx.b.Timer = v end, tcool = function(v) ctx.b.Cooldown = v end, ttog = function(v) ctx.b.ToggleCheck = v end,
    stname = function(v) ctx.stname = v end,
}
local function cmd_lines_changed(i, v)
    local lines = C.split(ctx.b.Cmd or '', '\n')
    for k = #lines + 1, nlines do lines[k] = '' end
    lines[i] = v
    local out = {}
    for k = 1, nlines do out[k] = lines[k] or '' end
    ctx.b.Cmd = table.concat(out, '\n'):gsub('\n+$', '')
end
local function apply_style(dest, style)
    local targets = {}
    if dest == 'this' then targets = { ctx.b }
    else
        local bar = E.hooks.bar(ctx.bar)
        local sets = {}
        if dest == 'set' and ctx.set then sets = { ctx.set } elseif dest == 'bar' and bar then sets = bar:sets() end
        for _, s in ipairs(sets) do for _, k in pairs(C.settings.Sets[s] or {}) do local tb = C.settings.Buttons[k]; if tb then targets[#targets + 1] = tb end end end
    end
    for _, t in ipairs(targets) do C.copy_style(style, t); local r = C.look(t); r._v = (r._v or 0) + 1 end
    if dest ~= 'this' then
        C.copy_style(style, ctx.b)
        C.save(true); E.hooks.changed()
    end
    return #targets
end
local function on_event(ev)
    if ev.type == 'windowmoved' then local x, y = E.hooks.parse(ev.value); if x then cfg_pos.x, cfg_pos.y = x, y; C.settings.Rml.EditorPos = { x = x, y = y }; C.save_soon() end; return end
    if ev.type == 'change' or ev.type == 'submit' then
        local v = tostring(ev.value or '')
        D.c['a' .. (ev.id or '') .. ' value'] = v
        local li = tonumber((ev.id or ''):match('^ec(%d)$'))
        if li then cmd_lines_changed(li, v)
        elseif INPUT[ev.id] then INPUT[ev.id](v) end
        if ev.type == 'submit' and ev.id == 'stname' then ev = { type = 'click', action = 'stsave', button = 0 } else paint_page(); paint_preview(); return end
    end
    if ev.type ~= 'click' then return end
    local a = ev.action or ''
    local k, v = a:match('^([%w]+):(.+)$')
    local r = look()
    if k == 'tab' then tab = v; apply_tab()
    elseif a == 'close' or a == 'cancel' then E.hide(); return
    elseif a == 'clear' then C.settings.Rml.Clear = not C.settings.Rml.Clear; C.save_soon(); E.hooks.clear()
    elseif a == 'save' then if save() then E.hide(); E.hooks.msg('Saved "' .. C.label(C.settings.Buttons[ctx.key], true) .. '"') end; return
    elseif a == 'delete' then
        if ctx.key then
            if ctx.confirm ~= 'delete' then ctx.confirm = 'delete'; msg('Click Delete again to delete this button everywhere.', true); return end
            C.delete_button(ctx.key); E.hooks.changed(); E.hide(); return
        end
    elseif a == 'unassign' then if ctx.set and ctx.idx and ctx.key then C.settings.Sets[ctx.set][ctx.idx] = nil; C.save(true); E.hooks.changed(); E.hide(); return end
    elseif a == 'export' then if ctx.key then pcall(function() ImGui.SetClipboardText(C.export_button(ctx.b)) end); msg('Share text for this button is on your clipboard.') end
    elseif a == 'simulate' then E.hooks.simulate(ctx.bar)
    elseif a == 'eval' then ctx.b.EvaluateLabel = not ctx.b.EvaluateLabel; ctx.b.CachedLabel = nil
    elseif a == 'addline' then if nlines < 8 then nlines = nlines + 1 end
    elseif a == 'dellline' then if nlines > 1 then cmd_lines_changed(nlines, ''); set_input('ec' .. nlines, ''); nlines = nlines - 1 end
    elseif a == 'fromcursor' then if fill_from_cursor(ctx.b) then load_inputs(); msg('Filled from your cursor.') else msg('Pick up an item, spell gem, skill, disc or social first.', true) end
    elseif k == 'src' then isrc = v; icat = 'all'; ipage = 1; rebuild_filter(); set_input('isearch', ''); isearch = ''
    elseif k == 'cat' or k == 'gc' then icat = v; ipage = 1; rebuild_filter()
    elseif a == 'ip:prev' then ipage = math.max(1, ipage - 1)
    elseif a == 'ip:next' then ipage = ipage + 1
    elseif k == 'ic' then local g = gridmap[tonumber(v)]; if g then ctx.b.Icon = (g.ty == 'Rml' or g.ty == 'GI') and g.id or tostring(g.id); ctx.b.IconType = g.ty; ctx.b.CachedIcon = nil end
    elseif a == 'noicon' then ctx.b.Icon = nil; ctx.b.IconType = nil
    elseif k == 'shape' then r.Shape = v
    elseif k == 'frame' then r.Frame = v
    elseif k == 'lpos' then if v == 'none' then ctx.b.ShowLabel = false else ctx.b.ShowLabel = true; r.LabelPos = v end
    elseif k == 'lsize' then r.LabelSize = tonumber(v)
    elseif k == 'col' then
        local which, n = v:match('^(%a+):(%d+)$'); local c = PAL[tonumber(n)]
        if which == 'b' then r.Border = c elseif which == '1' then r.Bg1 = c elseif which == '2' then r.Bg2 = c elseif which == 'l' then r.LabelColor = c
        elseif which == 'f' then local e = r.Fx[fxsel] or {}; e.Col = c; r.Fx[fxsel] = e end
        if not which then local w2, n2 = v:match('^(%d):(%d+)$'); if w2 == '1' then r.Bg1 = PAL[tonumber(n2)] elseif w2 == '2' then r.Bg2 = PAL[tonumber(n2)] end end
    elseif k == 'fxsel' then fxsel = v
    elseif a == 'fxon' then local e = r.Fx[fxsel] or {}; e.On = not e.On; if e.On and not e.Trig then e.Trig = (fxsel == 'fire' or fxsel == 'pulse') and 'ready' or 'always'; e.Int = e.Int or 100 end; r.Fx[fxsel] = e
    elseif k == 'ftrig' then local e = r.Fx[fxsel] or {}; e.Trig = v; e.On = true; r.Fx[fxsel] = e; if v == 'cond' and not r.Cond then msg('Type the condition below, for example: return mq.TLO.Me.Combat()') end
    elseif k == 'fkind' then local e = r.Fx.pack or {}; e.Kind = v; e.Col = nil; e.On = true; e.Trig = e.Trig or 'always'; e.Int = e.Int or 100; r.Fx.pack = e; fxsel = 'pack'
    elseif k == 'fint' then local e = r.Fx[fxsel] or {}; e.Int = tonumber(v); e.On = true; r.Fx[fxsel] = e
    elseif k == 'pv' then pvst[v] = not pvst[v]; if v == 'cd' then psim = nil end
    elseif a == 'psim' then psim = { t0 = mq.gettime(), tot = 4 }
    elseif k == 'tt' then
        local n = tonumber(v); local old = ctx.b.TimerType; ctx.b.TimerType = TT[n]
        if old ~= ctx.b.TimerType then ctx.b.Cooldown = nil; ctx.b.Timer = nil; ctx.b.ToggleCheck = nil; set_input('tval', ''); set_input('ttimer', ''); set_input('tcool', ''); set_input('ttog', '') end
    elseif k == 'ur' then ctx.b.UpdateRate = C.UpdateRates[tonumber(v)][2]
    elseif k == 'preset' then local p = C.PRESETS[tonumber(v)]; if p then C.apply_preset(ctx.b, p); msg('Applied the ' .. p.name .. ' look. Save to keep it.') end
    elseif k == 'cpy' then local n = apply_style(v, ctx.b); msg(string.format('Copied this look to %d buttons.', n))
    elseif a == 'stsave' then
        local name = tostring(ctx.stname or ''):gsub('^%s+', ''):gsub('%s+$', '')
        if name == '' then msg('Type a name for the style first.', true)
        else
            local st = C.settings.Rml.Styles
            if #st >= 7 then table.remove(st, 1) end
            local holder = {}; C.copy_style(ctx.b, holder)
            st[#st + 1] = { name = name, look = holder.Rml }; C.save(true); set_input('stname', ''); ctx.stname = ''; msg('Saved style "' .. name .. '".')
        end
    elseif k == 'sta' or k == 'sts' or k == 'stb' then
        local st = C.settings.Rml.Styles[tonumber(v)]
        if st then local n = apply_style(({ sta = 'this', sts = 'set', stb = 'bar' })[k], { Rml = st.look }); msg(string.format('Applied "%s" to %d button%s.', st.name, n, n == 1 and '' or 's')) end
    elseif k == 'std' then table.remove(C.settings.Rml.Styles, tonumber(v)); C.save(true)
    else return end
    if a ~= 'delete' then ctx.confirm = nil end
    repaint()
end
function E.create()
    local p = C.settings.Rml.EditorPos or {}
    local sw, sh = E.hooks.screen()
    local x = math.max(0, math.min(math.max(0, sw - WW), tonumber(p.x) or 360)); local y = math.max(0, math.min(math.max(0, sh - WH), tonumber(p.y) or 140))
    W = rmlui.open('ButtonMasterRml_Editor', 'buttonmaster_rml/ui/editor.rml', { width = WW, height = WH, x = x, y = y, theme = false })
    if not W then return end
    D = P.dom(W)
    pcall(function() W:reload() end); pcall(function() W:place(x, y, WW, WH) end)
    pcall(function() W:show(false) end)
end
function E.frame(t)
    if not W then return end
    for ev in W:events() do on_event(ev) end
    if not shown then return end
    preview_state(t)
    if msg_until > 0 and t > msg_until then msg_until = 0; D:text('msg', '') end
    -- the preview animates with the same frame stepping as a bar
    if not E.next_anim or t >= E.next_anim then
        E.next_anim = t + 100; E.fr = ((E.fr or 0) + 1) % 8
        for f = 0, 7 do D:class('body', 'f' .. f, f == E.fr) end
    end
end
function E.shutdown() if W then pcall(function() W:close() end) end end
function E.state() return { tab = tab, ctx = ctx, fxsel = fxsel, isrc = isrc, ipage = ipage } end
return E
