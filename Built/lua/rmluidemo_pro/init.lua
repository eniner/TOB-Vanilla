--[[
  RmlUi Pro showcase for MQ2RmlUi.

  Run:  /lua run rmluidemo_pro
  Stop: close the window  or  /lua stop rmluidemo_pro

  Loads exactly like rmluidemo: require('rmlui') + require('rmlui.host'),
  host.open(<name>, 'rmluidemo_pro/demo.rml', ...), host.tick in host.bind_loop.
  Window API used: text / rml / style / class / attr / theme, plus rmlui.icon_src.

  Performance rules followed here:
  - every element write goes through a cache, so unchanged values never reach the plugin;
  - win:rml only when a structure changes (buff list), never per frame;
  - Lua logic runs at 20 Hz and only for the visible page; motion is CSS transitions/keyframes;
  - floating combat text uses a pool of 12 elements (3 writes per number).
]]

local mq = require('mq')
local rmlui = require('rmlui')
local host = require('rmlui.host')
-- Optional v3 module (lua/rmlui/ext.lua from the v3 DLL tree): key events + data models.
-- Missing module or an older DLL: ext stays nil / features() reports no key/model bits and the demo falls back.
local ext do local ok, m = pcall(require, 'rmlui.ext'); ext = ok and m or nil end

pcall(function() rmlui.load_font([[C:\Windows\Fonts\segoeui.ttf]], false) end)
pcall(function() rmlui.load_font([[C:\Windows\Fonts\segoeuib.ttf]], false) end)
-- serif + monospace faces for the layout themes (Classic / Tome use Georgia, Sci-fi uses Consolas)
for _, f in ipairs({ 'georgia.ttf', 'georgiab.ttf', 'consola.ttf', 'consolab.ttf' }) do
    pcall(function() rmlui.load_font([[C:\Windows\Fonts\]] .. f, false) end)
end

-- Shader gradients follow rml_render_caps() (effects build). Override: true = always, false = never, nil = auto.
local GRADIENTS_BUILD = nil

local NAME = 'RmlUiDemoPro'
local running = true
local win
local opened_at = 0
local page = 1
local NPAGES = 12
local skin = 'midnight'
local chrome = 'redguides'
local SKINS = { 'midnight', 'ember', 'forest', 'paper' }
local frames, last_fps_t = 0, 0
local caps = 0
local caps_probe_t, caps_probes = 0, 0
local show_grad = GRADIENTS_BUILD == true
local last_tick = 0
local HUD = 1

local function now()
    return mq.gettime and mq.gettime() or (os.time() * 1000)
end
local function esc(s) return host.esc(s) end

-- ---------------------------------------------------------------------------------------------
-- Capabilities. The effects build exports int rml_render_caps(void):
-- 1 gradients, 2 filters, 4 layers, 8 box-shadow, 16 backdrop-filter, 32 mask-image.
-- Older DLLs don't: the lookup fails inside pcall and caps stay 0.
local CAP = { gradients = 1, filters = 2, layers = 4, boxshadow = 8, backdrop = 16, mask = 32 }
local caps_lib
local function detect_effects()
    local ok, v = pcall(function()
        local ffi = require('ffi')
        if not caps_lib then
            pcall(ffi.cdef, 'int rml_render_caps(void);')
            caps_lib = ffi.load('MQ2RmlUi')
        end
        return caps_lib.rml_render_caps()
    end)
    if ok and tonumber(v) then return tonumber(v) end
    return 0
end
local function has(bit) return math.floor(caps / bit) % 2 == 1 end
local feats = 0
local function detect_features()
    if not ext then return 0 end
    local ok, v = pcall(ext.features)
    return ok and tonumber(v) or 0
end
local function has_keys() return math.floor(feats / 64) % 2 == 1 end
local function has_models() return math.floor(feats / 128) % 2 == 1 end

-- ---------------------------------------------------------------------------------------------
-- Cached writes: unchanged values never reach the plugin.
local cache = {}
local calls = 0
local function set_style(id, prop, v)
    local k = id .. '|' .. prop
    if cache[k] == v then return end
    cache[k] = v; calls = calls + 1
    win:style(id, prop, v)
end
local function set_text(id, v)
    local k = id .. '|#'
    if cache[k] == v then return end
    cache[k] = v; calls = calls + 1
    win:text(id, v)
end
local function set_class(id, cls, on)
    local k = id .. '|.' .. cls
    if cache[k] == on then return end
    cache[k] = on; calls = calls + 1
    win:class(id, cls, on)
end
local function set_attr(id, a, v)
    local k = id .. '|@' .. a
    if cache[k] == v then return end
    cache[k] = v; calls = calls + 1
    win:attr(id, a, v)
end
local function set_rml(id, v)
    local k = id .. '|<>'
    if cache[k] == v then return end
    cache[k] = v; calls = calls + 1
    win:rml(id, v)
end
-- Restart a one-shot keyframe animation: swap between twin classes (A/B keyframes with identical content).
local twin = {}
local function retrigger(id, a, b)
    local on = not twin[id]
    twin[id] = on
    set_class(id, on and b or a, false)
    set_class(id, on and a or b, true)
end

local function tlo(f)
    local ok, v = pcall(f)
    if ok and v ~= nil then return v end
    return nil
end
local function ingame()
    return tlo(function() return mq.TLO.MacroQuest.GameState() end) == 'INGAME'
end
local function clamp(v, a, b) return math.max(a, math.min(b, v)) end
local function rnd(a, b) return a + math.random() * (b - a) end

-- ---------------------------------------------------------------------------------------------
-- Combat HUD
local CONS = { 'grey', 'green', 'lightblue', 'blue', 'white', 'yellow', 'red' }
local CON_MAP = { GREY = 'grey', GRAY = 'grey', GREEN = 'green', LIGHTBLUE = 'lightblue', BLUE = 'blue', WHITE = 'white', YELLOW = 'yellow', RED = 'red' }
local function con_class(v)
    local k = tostring(v or ''):upper():gsub('[%s_%-]', '')
    return CON_MAP[k] or 'white'
end
local MOBS = { { 'a frost giant', 'blue', 66 }, { 'Lord Bob the Undying', 'red', 72 }, { 'a gnoll pup', 'green', 58 },
    { 'an ancient wurm', 'yellow', 70 }, { 'a decaying skeleton', 'grey', 40 }, { 'a shadow drake', 'lightblue', 64 } }
-- Spell icons: in game the real icon via eq://spell/<SpellIcon cell> (the plugin's EqIconAtlas scheme),
-- looked up once per name; otherwise a drawn school gem (never iconsheet item art).
local spell_src_cache = {}
local spell_live = false -- set once at setup; the HUD frame loop never queries TLOs for icons
local function spell_src(name, cached_only)
    if not name then return nil end
    local c = spell_src_cache[name]
    if c ~= nil then return c or nil end
    if cached_only or not spell_live then return nil end
    local icon = tonumber(tlo(function() return mq.TLO.Spell(name).SpellIcon() end))
    local src = false
    if icon and icon >= 0 then
        local ok, v = pcall(rmlui.icon_src, 'spell', icon)
        if ok and type(v) == 'string' and v ~= '' then src = v end
    end
    spell_src_cache[name] = src
    return src or nil
end
local function gem_glyph(name) return esc((tostring(name or '?'):match('%a') or '?'):upper()) end
-- markup for a spell icon element with base classes cls (sizing comes from the context, e.g. 'spr', 'bi spr')
local function spell_icon_rml(name, school, cls, id, cached_only)
    local src = spell_src(name, cached_only)
    local idattr = id and (' id="' .. id .. '"') or ''
    if src then return string.format('<div%s class="%s sgem has-img"><img src="%s"/></div>', idattr, cls, src) end
    return string.format('<div%s class="%s sgem g-%s"><span>%s</span></div>', idattr, cls, school or 'none', gem_glyph(name))
end
-- static gems in demo.rml (ability bar, spell tooltips, deck): swapped for real icons in game
local SPELL_ICON_IDS = {
    { 'tsa1', 'Ice Comet', 'evocation', 'spr' },
    { 'tsb1', 'Ice Comet', 'evocation', 'spr' },
    { 'tsa2', 'Complete Heal', 'alteration', 'spr' },
    { 'tsb2', 'Complete Heal', 'alteration', 'spr' },
    { 'tsa3', 'Shield of Words', 'abjuration', 'spr' },
    { 'tsb3', 'Shield of Words', 'abjuration', 'spr' },
    { 'tsa4', 'Stun', 'evocation', 'spr' },
    { 'tsb4', 'Stun', 'evocation', 'spr' },
    { 'dkico1', 'Inferno Lance', 'evocation', 'spr dk-ico' },
    { 'dkico2', 'Glacial Ward', 'abjuration', 'spr dk-ico' },
    { 'dkico3', 'Spirit Bloom', 'alteration', 'spr dk-ico' },
    { 'dkico4', 'Soul Siphon', 'necromancy', 'spr dk-ico' },
    { 'dkico5', 'Divine Aegis', 'divination', 'spr dk-ico' },
    { 'abi1', 'Ice Comet', 'evocation', 'abi spr' },
    { 'abi2', 'Complete Heal', 'alteration', 'abi spr' },
    { 'abi3', 'Shield of Words', 'abjuration', 'abi spr' },
    { 'abi4', 'Flame Lick', 'evocation', 'abi spr' },
    { 'abi5', 'Ward of Vie', 'abjuration', 'abi spr' },
    { 'abi6', 'Stun', 'evocation', 'abi spr' },
    { 'abi7', 'Gate', 'alteration', 'abi spr' },
    { 'abi8', 'Root', 'alteration', 'abi spr' },
}
-- one-time lookups at setup (pcall-guarded per name); everything later reads the cache only
local function apply_spell_icons(extra_names)
    spell_live = ingame()
    if not spell_live then return end
    for _, n in ipairs(extra_names or {}) do pcall(spell_src, n) end
    for _, e in ipairs(SPELL_ICON_IDS) do
        local ok, src = pcall(spell_src, e[2])
        if ok and src then
            pcall(function()
                win:attr(e[1], 'class', e[4] .. ' sgem has-img')
                win:rml(e[1], string.format('<img src="%s"/>', src))
            end)
        end
    end
end
local live_icon_cache = {} -- SpellIcon cell -> src, so live buffs don't re-sample the atlas every scan
local function live_icon_src(icon)
    local c = live_icon_cache[icon]
    if c == nil then
        local ok, v = pcall(rmlui.icon_src, 'spell', icon)
        c = (ok and type(v) == 'string' and v ~= '') and v or false
        live_icon_cache[icon] = c
    end
    return c or nil
end
local SPELLS = { 'Ice Comet', 'Complete Heal', 'Shield of Words', 'Flame Lick', 'Ward of Vie', 'Stun', 'Gate', 'Root' }
local ABIL_CD = { 6, 12, 20, 4, 30, 9, 45, 15 }

local sim_on = true
local sim_forced = false -- set by clicking the button: run the sim even with a target / in combat
local S = {
    hp = 100, mn = 80, en = 90, shield = 0, tidx = 1, thp = 100, xp = 37,
    next_out = 0, next_in = 0, next_tcast = 0, next_buff = 0, next_auto = 0,
    cast = nil, tcast = nil, combo = 0, combo_t = 0,
    dmg = {}, dps_hist = {}, buffs = {}, cd = {},
}
for i = 1, 8 do S.cd[i] = 0 end
local SIM_BUFFS = { { sch = 'abjuration', d = 40, n = 'Aegolism' }, { sch = 'alteration', d = 25, n = 'Haste' }, { sch = 'abjuration', d = 18, n = 'Rune', stacks = 3 },
    { sch = 'alteration', d = 30, n = 'Regen' }, { sch = 'necromancy', d = 12, n = 'Poison', debuff = true, stacks = 2 }, { sch = 'conjuration', d = 50, n = 'Shield' } }

local fct_next = 0
local function fct(kind, txt, side)
    fct_next = fct_next % 12 + 1
    local id = 'fct' .. fct_next
    -- incoming numbers spawn over the player frame, outgoing over the target frame
    local x = side == 'tgt' and rnd(62, 84) or rnd(14, 38)
    local y = rnd(60, 110)
    set_text(id, txt)
    set_attr(id, 'style', string.format('left: %d%%; top: %ddp;', math.floor(x), math.floor(y)))
    twin[id] = not twin[id]
    set_attr(id, 'class', 'fct ' .. kind .. (twin[id] and ' a' or ' b'))
end

local function big_hit()
    retrigger('hudin', 'shA', 'shB')
    retrigger('flash', 'fA', 'fB')
end

local function bar(id, v, max_ok)
    v = clamp(math.floor((tonumber(v) or 0) + 0.5), 0, 100)
    set_style(id .. '_f', 'width', v .. '%')
    set_style(id .. '_tr', 'width', v .. '%')
    set_text(id .. '_t', v .. '%')
    return v
end

local prev = {}
local function vital(id, v)
    local old = prev[id]
    v = bar(id, v)
    if old and v > old + 2 then retrigger(id .. '_hx', 'hA', 'hB') end
    prev[id] = v
    return v, old
end

local function start_cast(name, len, who)
    local c = { name = name, start = now(), len = len }
    if who == 'tgt' then S.tcast = c else S.cast = c end
end

local buff_key
local function build_buffs(list)
    local key = {}
    for i, b in ipairs(list) do key[i] = (b.src or b.sch or '') .. ':' .. b.n end
    key = table.concat(key, '|')
    if key == buff_key then return end
    buff_key = key
    local parts = {}
    for i, b in ipairs(list) do
        local icon = b.src and string.format('<img class="bi" src="%s"/>', b.src) or spell_icon_rml(b.n, b.sch, 'bi spr', nil, true)
        parts[#parts + 1] = string.format(
            '<div id="bs%d" class="bslot%s">%s<div class="bclip"><div id="bsw%d" class="bsw"></div></div><div id="bst%d" class="bst"></div><div id="btm%d" class="btm"></div></div>',
            i, b.debuff and ' debuff' or '', icon, i, i, i)
    end
    for k in pairs(cache) do
        if k:match('^bs') or k:match('^btm') then cache[k] = nil end
    end
    set_rml('buffs', table.concat(parts))
end

local function sweep(id, frac, step)
    frac = clamp(frac, 0, 1)
    if show_grad then
        local deg = math.floor(frac * 360 / step) * step
        set_style(id, 'decorator', deg <= 0 and 'none'
            or string.format('conic-gradient(#000000b8 0deg, #000000b8 %ddeg, #00000000 %ddeg)', deg, deg))
    else
        set_style(id, 'height', math.floor(math.floor(frac * 360 / step) * step / 3.6) .. '%')
    end
end

local function press(i, t)
    if S.cd[i] > t then return end
    S.cd[i] = t + ABIL_CD[i] * 1000
    retrigger('ab' .. i, 'pA', 'pB')
    set_class('ab' .. i, 'ready', false)
    if i == 2 then start_cast('Complete Heal', 2000)
    elseif i == 1 then start_cast('Ice Comet', 1600)
    elseif i == 6 and S.tcast then S.tcast.intr = true end
end

-- one simulated fight step
local function sim_step(t, dt)
    local m = MOBS[S.tidx]
    -- outgoing
    if t >= S.next_out then
        S.next_out = t + rnd(450, 1100)
        local r = math.random()
        if r < 0.08 then fct('miss', 'MISS', 'tgt')
        else
            local crit = r > 0.84
            local d = math.floor(rnd(280, 920) * (crit and 2.4 or 1))
            S.thp = S.thp - d / 260
            S.dmg[#S.dmg + 1] = { t = t, d = d }
            S.combo = S.combo + 1; S.combo_t = t
            fct(crit and 'crit' or 'out', crit and (d .. '!') or tostring(d), 'tgt')
            if crit then retrigger('combo', 'pA', 'pB') end
        end
        if S.thp <= 0 then
            S.tidx = S.tidx % #MOBS + 1; S.thp = 100
            S.xp = (S.xp + rnd(3, 8)) % 100
            set_text('banner', 'VICTORY'); retrigger('banner', 'bA', 'bB')
        end
    end
    -- incoming
    if t >= S.next_in then
        S.next_in = t + rnd(700, 1800)
        local r = math.random()
        if r < 0.12 then fct('miss', 'MISS', 'me')
        else
            local d = rnd(2, 8) * (r > 0.92 and 2.2 or 1)
            if S.shield > 0 then
                local a = math.min(S.shield, d); S.shield = S.shield - a; d = d - a
            end
            S.hp = S.hp - d
            if d <= 0 then fct('miss', 'ABSORBED', 'me') else fct('inc', '-' .. math.floor(d * 120), 'me') end
            if d > 9 then
                big_hit()
                if S.cast and math.random() < 0.6 then S.cast.intr = true end
            end
        end
    end
    -- target casts
    if not S.tcast and t >= S.next_tcast then
        S.next_tcast = t + rnd(5000, 9000)
        start_cast(SPELLS[math.random(1, #SPELLS)], 2600, 'tgt')
    end
    -- auto-play the hotbar and the healer
    if t >= S.next_auto then
        S.next_auto = t + rnd(900, 1800)
        local order = { 1, 4, 3, 6, 8, 5, 7 }
        if S.tcast and S.cd[6] <= t and math.random() < 0.5 then press(6, t)
        else
            local i = order[math.random(1, #order)]
            if not S.cast or i ~= 1 then press(i, t) end
        end
    end
    if S.hp < 45 and not S.cast and S.cd[2] <= t then press(2, t) end
    -- regen / drain
    S.mn = clamp(S.mn + dt * 0.002 - (S.cast and dt * 0.006 or 0), 0, 100)
    S.en = clamp(S.en + dt * 0.003 - 0.02, 5, 100)
    S.shield = math.max(0, S.shield - dt * 0.0015)
    if S.hp <= 2 then S.hp = 100; set_text('banner', 'REVIVED'); retrigger('banner', 'bA', 'bB') end
    -- buffs: one expires and is re-gained every few seconds
    if #S.buffs == 0 then
        for i, b in ipairs(SIM_BUFFS) do
            S.buffs[i] = { sch = b.sch, n = b.n, debuff = b.debuff, stacks = b.stacks, max = b.d * 1000, ends = t + b.d * 1000 * rnd(0.3, 1) }
        end
    end
    for i = #S.buffs, 1, -1 do
        local b = S.buffs[i]
        if t >= b.ends then
            b.ends = t + b.max; b.gained = t
            if b.n == 'Rune' then S.shield = 18; b.stacks = 3 end
            if b.n == 'Poison' then b.stacks = (b.stacks or 1) % 5 + 1 end
        end
    end
end

local function update_cast(c, t, base, is_tgt)
    if not c then return nil end
    local frac = clamp((t - c.start) / c.len, 0, 1)
    if c.intr then
        if is_tgt then
            set_class('tc', 'intr', true)
            set_text('tc_n', 'Interrupted')
        else
            S.cb_end_t = t
            retrigger('cb', 'inA', 'inB')
            set_text('cb_n', 'Interrupted'); set_text('cb_t', '')
            fct('miss', 'INTERRUPTED', 'me')
        end
        return 'intr'
    end
    if frac >= 1 then
        if not is_tgt then
            S.cb_end_t = t
            retrigger('cb', 'okA', 'okB')
            if c.name == 'Complete Heal' then
                S.hp = math.min(100, S.hp + 38); fct('heal', '+' .. math.floor(38 * 120), 'me')
            elseif c.name == 'Ice Comet' then
                local d = math.floor(rnd(1800, 2600))
                S.thp = S.thp - d / 260; fct('crit', d .. '!', 'tgt')
            end
        end
        return 'done'
    end
    return frac
end

local live_prev_hp
local function tick_hud(t, dt)
    local live = ingame()
    local idle = true
    if live then
        local combat = tlo(function() return mq.TLO.Me.Combat() end)
        local tid = tonumber(tlo(function() return mq.TLO.Target.ID() end)) or 0
        local myid = tonumber(tlo(function() return mq.TLO.Me.ID() end)) or -1
        idle = not combat and (tid == 0 or tid == myid)
    end
    local use_sim = sim_on and (not live or idle or sim_forced)
    if use_sim then sim_step(t, dt) end

    -- player
    local name, lvl, hp, mn, en, maxmana
    if live then
        name = tlo(function() return mq.TLO.Me.CleanName() end)
        lvl = tlo(function() return mq.TLO.Me.Level() end)
        maxmana = tonumber(tlo(function() return mq.TLO.Me.MaxMana() end)) or 0
    end
    if use_sim or not live then
        hp, mn, en = S.hp, S.mn, S.en
        maxmana = 1
    else
        hp = tlo(function() return mq.TLO.Me.PctHPs() end)
        mn = tlo(function() return mq.TLO.Me.PctMana() end)
        en = tlo(function() return mq.TLO.Me.PctEndurance() end)
        -- real HP drops become floating numbers
        local cur = tonumber(tlo(function() return mq.TLO.Me.CurrentHPs() end))
        if cur and live_prev_hp and cur ~= live_prev_hp then
            local d = cur - live_prev_hp
            fct(d < 0 and 'inc' or 'heal', (d < 0 and '' or '+') .. d, 'me')
            if d < 0 and -d > (tonumber(tlo(function() return mq.TLO.Me.MaxHPs() end)) or 1e9) * 0.08 then big_hit() end
        end
        live_prev_hp = cur
    end
    set_text('pf_name', tostring(name or 'Tester'))
    set_text('pf_lvl', tostring(lvl or 70))
    local hpv = vital('hp', hp)
    set_class('hp_f', 'low', hpv < 30)
    set_class('vig', 'low', hpv < 30)
    if maxmana and maxmana > 0 then vital('mn', mn) else set_text('mn_t', '--'); bar('mn', 0) end
    set_class('mn', 'nores', not (maxmana and maxmana > 0))
    vital('en', en)
    -- absorb shield sits after the HP fill
    local sh = use_sim and S.shield or 0
    set_style('hp_sh', 'left', hpv .. '%')
    set_style('hp_sh', 'width', math.floor(math.min(sh, 100 - hpv)) .. '%')

    -- target
    local tname, thp, tlvl, tcon
    if use_sim then
        local m = MOBS[S.tidx]
        tname, tcon, tlvl, thp = m[1], m[2], m[3], S.thp
    elseif live and (tonumber(tlo(function() return mq.TLO.Target.ID() end)) or 0) > 0 then
        tname = tlo(function() return mq.TLO.Target.CleanName() end)
        thp = tlo(function() return mq.TLO.Target.PctHPs() end)
        tlvl = tlo(function() return mq.TLO.Target.Level() end)
        tcon = con_class(tlo(function() return mq.TLO.Target.ConColor() end))
    end
    set_text('tf_name', tname and tostring(tname) or 'No target')
    set_text('tf_lvl', tlvl and tostring(tlvl) or '')
    set_class('tf', 'tf-none', not tname)
    bar('thp', tname and thp or 0)
    for _, c in ipairs(CONS) do set_class('tf_ring', 'con-' .. c, c == (tcon or 'grey')) end

    -- player cast bar
    local cname, cfrac
    if not use_sim and live then
        cname = tlo(function() return mq.TLO.Me.Casting.Name() end)
        if cname == 'NULL' or cname == '' then cname = nil end
        if cname then
            local left = tonumber(tlo(function() return mq.TLO.Me.CastTimeLeft() end))
            local total = tonumber(tlo(function() return mq.TLO.Me.Casting.MyCastTime() end))
            cfrac = (left and total and total > 0) and clamp(1 - left / total, 0, 1) or 0.5
        end
    else
        local r = update_cast(S.cast, t, 'cb', false)
        if r == 'done' or r == 'intr' then S.cast = nil
        elseif r then cname, cfrac = S.cast.name, r end
    end
    if cname then
        set_class('cb', 'idle', false)
        set_class('cb', 'okA', false); set_class('cb', 'okB', false); set_class('cb', 'inA', false); set_class('cb', 'inB', false)
        set_text('cb_n', cname)
        local p = math.floor(cfrac * 100)
        set_style('cb_f', 'width', p .. '%')
        set_style('cb_sp', 'left', p .. '%')
        set_text('cb_t', S.cast and string.format('%.1fs', math.max(0, (S.cast.len - (t - S.cast.start)) / 1000)) or (p .. '%'))
    else
        set_class('cb', 'idle', t - (S.cb_end_t or -1e9) > 600)
    end

    -- target cast bar (sim only)
    local tr = update_cast(S.tcast, t, 'tc', true)
    if use_sim and type(tr) == 'number' then
        set_class('tc', 'on', true); set_class('tc', 'intr', false)
        set_text('tc_n', S.tcast.name)
        set_style('tc_f', 'width', math.floor(tr * 100) .. '%')
    elseif tr == 'intr' then
        S.tcast.hold = S.tcast.hold or t
        if t - S.tcast.hold > 700 then S.tcast = nil; set_class('tc', 'on', false) end
    else
        if tr == 'done' then S.tcast = nil end
        set_class('tc', 'on', false)
    end

    -- buffs + hotbar at 10 Hz (TLO buff scan at 4 Hz in game)
    local slow = t - (S.slow_t or 0) >= 100
    if slow then S.slow_t = t end
    local scan = (use_sim or not live) or t - (S.scan_t or 0) >= 250
    if slow and scan then
    S.scan_t = t
    local list = {}
    if use_sim or not live then
        for _, b in ipairs(S.buffs) do
            list[#list + 1] = { sch = b.sch, n = b.n, debuff = b.debuff, stacks = b.stacks, left = (b.ends - t) / 1000, max = b.max / 1000, gained = b.gained }
        end
    else
        for i = 1, 8 do
            local icon = tonumber(tlo(function() return mq.TLO.Me.Buff(i).Spell.SpellIcon() end))
            local bn = tlo(function() return mq.TLO.Me.Buff(i).Name() end)
            if icon and bn then
                local secs = tonumber(tlo(function() return mq.TLO.Me.Buff(i).Duration.TotalSeconds() end)) or 0
                local src = live_icon_src(icon)
                S.maxseen = S.maxseen or {}
                S.maxseen[bn] = math.max(S.maxseen[bn] or 0, secs)
                list[#list + 1] = { src = src, n = bn, left = secs, max = S.maxseen[bn] }
            end
        end
    end
    build_buffs(list)
    for i, b in ipairs(list) do
        sweep('bsw' .. i, b.max > 0 and (1 - b.left / b.max) or 0, 12)
        set_text('btm' .. i, b.left >= 60 and (math.floor(b.left / 60) .. 'm') or tostring(math.max(0, math.floor(b.left))))
        set_text('bst' .. i, (b.stacks and b.stacks > 1) and tostring(b.stacks) or '')
        set_class('bs' .. i, 'exp', b.left > 0 and b.left < 5)
        set_class('bs' .. i, 'new', b.gained ~= nil and t - b.gained < 900)
    end

    end
    -- ability bar
    for i = 1, (slow and 8 or 0) do
        local left = (S.cd[i] - t) / 1000
        if left > 0 then
            sweep('abcd' .. i, left / ABIL_CD[i], 12)
            set_text('abt' .. i, left >= 1 and tostring(math.ceil(left)) or '')
            set_class('ab' .. i, 'ready', false)
        else
            if cache['ab' .. i .. '|.ready'] == false then retrigger('abs' .. i, 'sA', 'sB') end
            sweep('abcd' .. i, 0, 6)
            set_text('abt' .. i, '')
            set_class('ab' .. i, 'ready', true)
        end
    end

    -- dps meter: 5 s window, sparkline sampled every second
    local sum = 0
    for i = #S.dmg, 1, -1 do
        if t - S.dmg[i].t > 5000 then table.remove(S.dmg, i) else sum = sum + S.dmg[i].d end
    end
    local dps = math.floor(sum / 5)
    set_text('dps_n', tostring(dps))
    if t - (S.spark_t or 0) >= 1000 then
        S.spark_t = t
        table.insert(S.dps_hist, dps)
        while #S.dps_hist > 20 do table.remove(S.dps_hist, 1) end
        local mx = 1
        for _, v in ipairs(S.dps_hist) do mx = math.max(mx, v) end
        for i = 1, 20 do
            local v = S.dps_hist[#S.dps_hist - 20 + i] or 0
            set_style('sp' .. i, 'height', math.max(6, math.floor(v / mx * 10) * 10) .. '%')
        end
    end
    if t - S.combo_t > 2500 then S.combo = 0 end
    set_class('combo', 'on', S.combo >= 3)
    set_text('combo', 'x' .. S.combo)

    -- xp strip
    local xp = (not use_sim and live) and tlo(function() return mq.TLO.Me.PctExp() end) or S.xp
    set_style('xp_f', 'width', string.format('%.1f%%', tonumber(xp) or 0))
end

-- ---------------------------------------------------------------------------------------------
-- Other pages
-- Controls page: Lua runs only on input events (plus two short timers for the loading button and keybind demo).
local ACC = { blue = '#4c8dff', gold = '#e0a826', green = '#2fcf95', pink = '#e040b8', red = '#e0303e' }
local C = { acc = 'blue', knob = 60, step = 35, seg = 2, vol = 70, muted = false, tg = { true, false, true, false },
    ck = { true, false, true }, rc = 1, chip = { true, false, true, false, false }, load_t = nil, kb_t = nil, kb_i = 0 }
local DETAIL = { 'Off', 'Low', 'Medium', 'High', 'Ultra' }
local KEYS = { 'Ctrl + 1', 'Alt + Q', 'F5', 'Shift + Tab', 'Mouse 4' }

local function arc(v, from, span)
    if not show_grad then return 'none' end
    local d = math.floor(v * span / 100)
    local c = ACC[C.acc]
    return string.format('conic-gradient(from %ddeg, %s 0deg, %s %ddeg, #ffffff10 %ddeg, #ffffff10 %ddeg, #00000000 %ddeg)',
        from, c, c, d, d, span, span)
end
local function ctl_refresh()
    set_style('dial_rot', 'transform', string.format('rotate(%ddeg)', math.floor(-135 + C.knob * 2.7)))
    set_text('dial_v', tostring(C.knob))
    set_style('dial_arc', 'decorator', arc(C.knob, 225, 270))
    set_text('step_v', tostring(C.step))
    set_text('ring_v', C.step .. '%')
    set_style('ring_arc', 'decorator', arc(C.step, 0, 360))
    for i = 1, 10 do set_class('sb' .. i, 'on', i <= math.floor(C.step / 10 + 0.5)) end
end
local function set_progress(v)
    v = clamp(math.floor(tonumber(v) or 0), 0, 100)
    set_text('sl_val', tostring(v))
    -- the bubble follows the thumb: track spans the input minus the 16dp thumb
    set_style('sl_bub', 'left', v .. '%')
    set_style('sl_bub', 'margin-left', math.floor(-10 - v * 0.16) .. 'dp')
end
local function ctl_change(id, val)
    if id == 'sl' then set_progress(val); return true end
    if id == 'sl_st' then set_text('st_val', DETAIL[clamp(math.floor(tonumber(val) or 0), 0, 4) + 1]); return true end
    if id == 'sl_vol' then
        C.vol = clamp(math.floor(tonumber(val) or 0), 0, 100)
        set_text('vol_val', C.muted and 'Muted' or tostring(C.vol))
        set_class('spk_w1', 'off', C.muted or C.vol == 0)
        set_class('spk_w2', 'off', C.muted or C.vol < 50)
        return true
    end
    return false
end
local function ctl_action(a)
    local k, n = a:match('^(%a+):(.+)$')
    if not k then return false end
    local i = tonumber(n)
    if k == 'tg' and i then C.tg[i] = not C.tg[i]; set_class('tg' .. i, 'on', C.tg[i])
    elseif k == 'ck' and i then C.ck[i] = not C.ck[i]; set_class('ck' .. i, 'on', C.ck[i])
    elseif k == 'chip' and i then C.chip[i] = not C.chip[i]; set_class('ch' .. i, 'on', C.chip[i])
    elseif k == 'seg' and i then
        C.seg = i
        for j = 1, 3 do set_class('seg', 'sel' .. j, j == i); set_class('seg' .. j, 'on', j == i) end
    elseif k == 'rc' and i then C.rc = i; for j = 1, 3 do set_class('rc' .. j, 'on', j == i) end
    elseif k == 'acc' and ACC[n] then
        for name in pairs(ACC) do set_class('page9', 'acc-' .. name, name == n); set_class('sw_' .. name, 'on', name == n) end
        C.acc = n; ctl_refresh()
    elseif k == 'knob' then C.knob = clamp(C.knob + (n == '+' and 10 or -10), 0, 100); ctl_refresh()
    elseif k == 'step' then
        C.step = clamp(C.step + (n == '+' and 5 or -5), 0, 100); ctl_refresh()
        retrigger('step_v', 'bA', 'bB')
    elseif k == 'vol' and n == 'mute' then C.muted = not C.muted; set_class('spk', 'muted', C.muted); ctl_change('sl_vol', C.vol)
    elseif k == 'tx' and n == 'clear' then calls = calls + 1; win:set_value('tx', '')
    elseif k == 'btn' and n == 'load' then
        if not C.load_t then C.load_t = now(); set_class('ldbtn', 'loading', true); set_text('ld_t', 'Saving') end
    elseif k == 'btn' and n == 'press' then -- press feedback is pure CSS (:active)
    elseif k == 'kb' and n == 'capture' then
        C.kb_t = now(); set_class('kbf', 'listen', true); set_text('kbf_t', 'Press a key...')
        -- v3 DLL: capture the real key (Escape cancels); otherwise the timer below demos the look
        C.kb_real = has_keys() and ext.capture(win, function(chord)
            C.kb_t = nil; set_class('kbf', 'listen', false)
            if chord then C.kb_bind = chord:gsub('%+', ' + ') end
            set_text('kbf_t', C.kb_bind or KEYS[math.max(1, C.kb_i)])
        end, page == HUD and 2 or 0) or false
    else return false end
    return true
end
-- Real key capture would need key events from the plugin (only click/change/submit/mouseover/mouseout are
-- forwarded), so the keybind field demos the look: it listens for 1.8 s and then shows the next sample bind.
local function ctl_timers(t)
    if C.load_t and t - C.load_t > 1600 then
        C.load_t = nil; set_class('ldbtn', 'loading', false); set_text('ld_t', 'Saved')
    end
    if C.kb_t and C.kb_real then
        if t - C.kb_t > 6000 then -- nobody pressed anything: stop listening
            ext.cancel_capture(win); C.kb_t = nil; C.kb_real = false
            set_class('kbf', 'listen', false); set_text('kbf_t', C.kb_bind or KEYS[math.max(1, C.kb_i)])
        end
    elseif C.kb_t and t - C.kb_t > 1800 then
        C.kb_t = nil; C.kb_i = C.kb_i % #KEYS + 1
        set_class('kbf', 'listen', false); set_text('kbf_t', KEYS[C.kb_i])
    end
end

-- Glow and text: typewriter (20 Hz, one character per tick, only while page 6 is visible)
local TW_LINES = { 'You have slain Lord Nagafen!', 'Firiona tells you, "Meet me at the Plane of Fear."',
    'Your faction standing with Freeport Militia got better.', 'You have gained an ability point!' }
local tw = { line = 1, n = 0, hold = 0 }
local function tick_typer(t)
    local L = TW_LINES[tw.line]
    if tw.n < #L then
        tw.n = tw.n + 1
        set_text('tw_txt', L:sub(1, tw.n))
        tw.hold = t
    elseif t - tw.hold > 1800 then
        tw.line = tw.line % #TW_LINES + 1; tw.n = 0
        set_text('tw_txt', '')
    end
end
-- Sprites: frame cycling through the iconsheet cells at 10 Hz (only while page 8 is visible)
local frame_i, frame_t = 0, 0
local function tick_frames(t)
    if t - frame_t < 100 then return end
    frame_t = t
    frame_i = (frame_i + 1) % 8
    set_style('anim_frame', 'decorator', 'image(i' .. frame_i .. ')')
end
local LOOT = { { 5, 'Shield of the Ancients', 'legendary' }, { 3, 'Wurmscale Greaves', 'epic' }, { 2, 'Ring of Embers', 'rare' },
    { 6, "Traveler's Boots", 'uncommon' }, { 0, 'Silver Orb', 'rare' }, { 4, 'Gauntlets of Flame', 'epic' } }
local loot_i = 0
local function loot_drop()
    loot_i = loot_i % #LOOT + 1
    local it = LOOT[loot_i]
    set_attr('drop_i', 'class', 'drop-i spr s' .. it[1])
    set_text('drop_n', it[2])
    twin['drop_n'] = not twin['drop_n']
    set_attr('drop_n', 'class', 'drop-n c-' .. it[3] .. (twin['drop_n'] and ' nA' or ' nB'))
    retrigger('drop', 'dA', 'dB')
end

-- Motion: spell-cast sequence (charge 0.9 s, projectile 0.55 s, impact 0.9 s). Lua only flips one class per phase.
local MO = { t0 = nil, auto = true, school = 'frost', phase = '' }
local MO_SPELL = { frost = 'Ice Comet', fire = 'Inferno Bolt', shadow = 'Soul Rend' }
local MO_SCH = { 'frost', 'fire', 'shadow' }
local function mo_school(sc)
    MO.school = sc
    set_attr('mo_stage', 'class', 'mo-stage sc-' .. sc .. (MO.phase ~= '' and (' ' .. MO.phase) or ''))
    for i, k in ipairs(MO_SCH) do set_class('mo_s' .. i, 'on', k == sc) end
    set_text('mo_spell', MO_SPELL[sc])
end
local function mo_phase(ph)
    if MO.phase == ph then return end
    MO.phase = ph
    set_attr('mo_stage', 'class', 'mo-stage sc-' .. MO.school .. (ph ~= '' and (' ' .. ph) or ''))
end
local function tick_motion(t)
    if not MO.t0 then
        if MO.auto then MO.t0 = t else return end
    end
    local e = t - MO.t0
    if e < 900 then mo_phase('ph-charge')
    elseif e < 1450 then mo_phase('ph-fire')
    elseif e < 2350 then
        if MO.phase ~= 'ph-impact' then
            local crit = math.random() < 0.3
            set_text('mo_dmg', tostring(math.random(1800, 2600) * (crit and 2 or 1)) .. (crit and '!' or ''))
        end
        mo_phase('ph-impact')
    else
        mo_phase('')
        if not MO.auto then MO.t0 = nil elseif e > 3300 then MO.t0 = t end
    end
end

-- 3D: card deck. Each card gets one position class relative to the selected card.
local DK = { sel = 1, mode = 'carousel', flip = false }
local DK_POS = { [-2] = 'pm2', [-1] = 'pm1', [0] = 'p0', [1] = 'pp1', [2] = 'pp2' }
local function dk_layout()
    for i = 1, 5 do
        local rel = (i - DK.sel + 2) % 5 - 2
        set_attr('dkc' .. i, 'class', 'dkc ' .. DK_POS[rel])
        set_class('dki' .. i, 'flip', i == DK.sel and DK.flip)
    end
    set_attr('dk', 'class', 'dk-stage ' .. DK.mode)
    set_class('dk_m1', 'on', DK.mode == 'carousel')
    set_class('dk_m2', 'on', DK.mode == 'fan')
end
local function dk_action(a)
    local n = a:match('^dk:(%w+)$')
    if not n then return false end
    local i = tonumber(n)
    if i then
        if i == DK.sel then DK.flip = not DK.flip else DK.sel, DK.flip = i, false end
    elseif n == 'next' then DK.sel, DK.flip = DK.sel % 5 + 1, false
    elseif n == 'prev' then DK.sel, DK.flip = (DK.sel + 3) % 5 + 1, false
    elseif n == 'flip' then DK.flip = not DK.flip
    elseif n == 'fan' or n == 'carousel' then DK.mode = n
    else return false end
    dk_layout()
    return true
end

-- Gradients: loading screen (progress loops every 9 s, a new tip every 4.5 s)
local LS_TIPS = { 'Bind your soul before venturing into the Plane of Fear.', 'Camping a named? Check /who for competition first.',
    'Shrouds of Velious: bring cold resist.', 'A good puller is worth two good tanks.' }
local function tick_grad_lua(t)
    local e = (t % 9000) / 9000
    local pct = math.floor(100 * (1 - (1 - e) ^ 2.2))
    set_style('ls_fill', 'width', pct .. '%')
    set_text('ls_pct', pct .. '%')
    set_text('ls_tip', LS_TIPS[math.floor(t / 4500) % #LS_TIPS + 1])
end

-- Effects page: party panel bound to a v3 data model (fallback card otherwise)
local PARTY_RML = [[<div data-model="party">
<div class="pt-h"><span>{{gname}}</span><span class="pt-n">{{count}} / 6</span></div>
<div class="pt-row" data-for="p : members" data-class-low="p[2] < 35" data-class-dead="p[2] == 0">
<div class="pt-cls">{{p[1]}}</div>
<div class="pt-mid"><div class="pt-name">{{p[0]}}</div><div class="pt-bar"><div class="pt-fill" data-style-width="p[2] + '%'"></div></div>
<div class="pt-mbar" data-if="showmana"><div class="pt-mfill" data-style-width="p[3] + '%'"></div></div></div>
<div class="pt-hp">{{p[2]}}%</div></div>
<div class="pt-f"><input type="text" class="pt-in" data-value="gname" maxlength="18"/><div class="pt-ck"><input type="checkbox" data-checked="showmana"/><span>Mana</span></div></div>
</div>]]
local PARTY_OFF = [[<div class="pt-off"><div class="pt-off-h">Party</div><div>Live data binding needs the v3 DLL.</div>
<div class="pt-off-r"></div><div class="pt-off-r"></div><div class="pt-off-r"></div></div>]]
local party = { model = nil, sim = { { 'Tester', 'WAR', 92, 0 }, { 'Firiona', 'CLR', 71, 64 }, { 'Gazok', 'WIZ', 48, 30 },
    { 'Tunare', 'DRU', 88, 80 }, { 'Vex', 'ROG', 33, 0 } }, t = 0 }
local function party_rows()
    if ingame() then
        local n = tonumber(tlo(function() return mq.TLO.Group.Members() end)) or 0
        if n > 0 then
            local rows = {}
            for i = 0, math.min(n, 5) do
                local m = i == 0 and mq.TLO.Me or mq.TLO.Group.Member(i)
                local name = tlo(function() return m.CleanName() end)
                if name then
                    rows[#rows + 1] = { name, tlo(function() return m.Class.ShortName() end) or '',
                        tonumber(tlo(function() return m.PctHPs() end)) or 0, tonumber(tlo(function() return m.PctMana() end)) or 0 }
                end
            end
            if #rows > 0 then return rows end
        end
    end
    for _, r in ipairs(party.sim) do -- simulated fight: damage and heals drift the bars
        r[3] = clamp(r[3] + math.random(-9, 7), r[2] == 'WAR' and 20 or 5, 100)
        if r[4] > 0 or r[2] == 'CLR' or r[2] == 'WIZ' or r[2] == 'DRU' then r[4] = clamp(r[4] + math.random(-4, 3), 5, 100) end
    end
    return party.sim
end
local function setup_party()
    if has_models() and not party.model then
        party.model = ext.model(win, 'party')
        if party.model then
            party.model:set('gname', 'Raid Alpha')
            party.model:set('showmana', true)
            local rows = party_rows()
            party.model:set('count', #rows)
            party.model:list('members', rows, 4)
        end
    end
    set_rml('party_host', ((party.model and PARTY_RML or PARTY_OFF):gsub('\n', '')))
end
local function tick_party(t)
    if not party.model or t - party.t < 250 then return end
    party.t = t
    local rows = party_rows()
    party.model:set('count', #rows)
    party.model:list('members', rows, 4)
end

local function apply_grad()
    win:class('shell', 'shader-on', show_grad)
    -- the manual toggle is only offered when the DLL doesn't report gradient support
    win:class('sg_row', 'sg-hide', has(CAP.gradients))
    for k in pairs(cache) do if k:match('^dial_arc') or k:match('^ring_arc') then cache[k] = nil end end
    if win and C then ctl_refresh() end
    win:text('sg_btn', show_grad and 'Hide shader gradients' or 'Show shader gradients')
end

local function apply_caps()
    win:class('shell', 'cap-filters', has(CAP.filters))
    win:class('shell', 'cap-boxshadow', has(CAP.boxshadow))
    win:class('shell', 'cap-backdrop', has(CAP.backdrop))
    win:class('shell', 'cap-mask', has(CAP.mask))
    if GRADIENTS_BUILD == nil and has(CAP.gradients) then show_grad = true end
    apply_grad()
end

local function set_page(n)
    page = n
    -- Combat HUD hotkeys 1-8: capture keys only on that page while the window is focused (EQ doesn't get
    -- them then; click the game world to give EQ the keyboard back). Off on every other page.
    if has_keys() and not ext.capturing(win) then ext.key_mode(win, n == HUD and 2 or 0) end
    for i = 1, NPAGES do
        win:class('nav' .. i, 'on', i == n)
        win:class('page' .. i, 'on', i == n)
    end
end

local function set_skin(s)
    skin = s
    for _, k in ipairs(SKINS) do
        win:class('shell', 'skin-' .. k, k == s)
        win:class('sk_' .. k, 'on', k == s)
    end
end


-- Tabs, lists, layout themes: built once at setup; Lua runs only on clicks.
local BAG = { { 5, 'legendary' }, { 3, 'epic', 1 }, { 2, 'rare' }, { 6, 'uncommon', 1 }, { 7, 'common' }, { 0, 'rare', 20 },
    { 1, 'uncommon', 5 }, { 4, 'epic' }, { 2, 'common', 12 }, { 6, 'common', 3 }, { 3, 'uncommon' }, { 5, 'rare' },
    { 0, 'common', 40 }, { 7, 'legendary' }, { 1, 'common', 8 }, { 4, 'uncommon' } }
local NBAG = 24
local bag_sel = 0
local SPELL_DATA = {
    { 'Ice Comet', 66, 255, 'evocation', 0 }, { 'Complete Heal', 39, 400, 'alteration', 1 }, { 'Shield of Words', 61, 575, 'abjuration', 4 },
    { 'Flame Lick', 1, 10, 'evocation', 2 }, { 'Ward of Vie', 70, 950, 'abjuration', 5 }, { 'Stun', 2, 45, 'evocation', 6 },
    { 'Gate', 4, 70, 'alteration', 7 }, { 'Root', 8, 25, 'alteration', 3 }, { 'Summon Food', 3, 15, 'conjuration', 1 },
    { 'Locate Corpse', 12, 20, 'divination', 0 }, { 'Celestial Remedy', 44, 225, 'alteration', 2 }, { 'Symbol of Marzin', 59, 700, 'abjuration', 4 },
    { 'Blizzard', 56, 330, 'evocation', 5 }, { 'True North', 1, 5, 'divination', 6 } }
local sort_key, sort_asc = 'name', true
local SORT_COL = { name = 1, level = 2, mana = 3 }
local LTS = { 'classic', 'glass', 'raid', 'scifi', 'tome' }
local lt_cur = 'classic'
local QOPEN = { true, false, false }

local function build_bag()
    local live = ingame()
    local parts = {}
    for i = 1, NBAG do
        local it = BAG[i]
        if it then
            local icon = string.format('<div class="spr s%d"></div>', it[1])
            if live then
                local ok, src = pcall(rmlui.icon_src, 'item', 500 + i * 7)
                if ok and src and src ~= '' then icon = string.format('<img src="%s"/>', src) end
            end
            parts[#parts + 1] = string.format('<div id="bag%d" class="bslot2 r-%s" action="inv:%d">%s%s</div>', i, it[2], i, icon,
                it[3] and it[3] > 1 and ('<span class="bq">' .. it[3] .. '</span>') or '')
        else
            parts[#parts + 1] = string.format('<div id="bag%d" class="bslot2 empty"></div>', i)
        end
    end
    win:rml('bag', table.concat(parts))
end

local function build_spells()
    local col = SORT_COL[sort_key]
    local rows = {}
    for i, v in ipairs(SPELL_DATA) do rows[i] = v end
    table.sort(rows, function(x, y)
        if x[col] == y[col] then return x[1] < y[1] end
        if sort_asc then return x[col] < y[col] end
        return x[col] > y[col]
    end)
    local parts = {}
    for i, r in ipairs(rows) do
        parts[#parts + 1] = string.format('<div class="sprow%s">%s<div class="pip sc-%s"></div><span class="spn">%s</span><span class="spl">%d</span><span class="spm">%d</span></div>',
            i % 2 == 0 and ' alt' or '', spell_icon_rml(r[1], r[4], 'spr'), r[4], esc(r[1]), r[2], r[3])
    end
    win:rml('splist', table.concat(parts))
    for k in pairs(SORT_COL) do
        win:class('sh_' .. k, 'sorted', k == sort_key)
        win:text('arr_' .. k, k == sort_key and (sort_asc and ' \u{25B2}' or ' \u{25BC}') or '')
    end
end

local function fill_lists()
    build_bag()
    build_spells()
    local cl = {}
    local names = { 'Rusty Short Sword', 'Cloth Cap', 'Water Flask', 'Bread', 'Torch', 'Bone Chips', 'Fine Steel Dagger', 'Leather Tunic' }
    for i = 1, 20 do cl[#cl + 1] = '<div class="li"><div class="spr s' .. (i % 8) .. '"></div>' .. esc(names[(i - 1) % #names + 1]) .. '</div>' end
    win:rml('clip_list', table.concat(cl))
end

local function page_action(a)
    local k, n = a:match('^(%a+):(.+)$')
    local i = tonumber(n)
    if k == 'tab' and i then
        for j = 1, 3 do win:class('tabs', 't' .. j, j == i); win:class('tab' .. j, 'on', j == i); win:class('tp' .. j, 'on', j == i) end
    elseif k == 'inv' and i then
        if bag_sel > 0 then win:class('bag' .. bag_sel, 'sel', false) end
        bag_sel = (bag_sel == i) and 0 or i
        if bag_sel > 0 then win:class('bag' .. bag_sel, 'sel', true) end
    elseif k == 'sort' and SORT_COL[n] then
        if sort_key == n then sort_asc = not sort_asc else sort_key, sort_asc = n, n == 'name' end
        build_spells()
    elseif k == 'q' and i then
        QOPEN[i] = not QOPEN[i]
        win:class('q' .. i, 'open', QOPEN[i])
    elseif k == 'lt' and n == 'pulse' then
        retrigger('lt', 'swA', 'swB')
    elseif k == 'lt' then
        for _, t in ipairs(LTS) do
            win:class('lt', 'lt-' .. t, t == n); win:class('ltstage', 'st-' .. t, t == n); win:class('lt_' .. t, 'on', t == n)
        end
        lt_cur = n
        retrigger('lt', 'swA', 'swB')
    else return false end
    return true
end

local function fill_eq_icons()
    local parts = {}
    if not ingame() then win:rml('eq_icons', ''); return end -- eq:// icons need the game's atlas
    for _, c in ipairs({ { 'item', 507 }, { 'item', 836 }, { 'item', 640 }, { 'item', 1012 }, { 'spell', 1 }, { 'spell', 12 }, { 'spell', 25 }, { 'spell', 117 } }) do
        local ok, src = pcall(rmlui.icon_src, c[1], c[2])
        if ok and src and src ~= '' then parts[#parts + 1] = string.format('<img class="eqi" src="%s"/>', src) end
    end
    win:rml('eq_icons', table.concat(parts))
end

local function open()
    pcall(function() rmlui.close(NAME) end)
    local w, err = host.open(NAME, 'rmluidemo_pro/demo.rml', {
        width = 900, height = 700, title = 'RmlUi Pro Showcase', theme = chrome, autoclose = false,
    })
    if not w then
        print('[RmlUiDemoPro] open failed: ' .. tostring(err))
        running = false
        return nil
    end
    w:theme(chrome)
    w:text('window-title', 'RmlUi Pro Showcase')
    opened_at = now()
    return w
end

local function setup()
    spell_live = ingame()
    set_page(1)
    set_skin(skin)
    set_progress(35)
    ctl_refresh()
    fill_lists()
    fill_eq_icons()
    caps = detect_effects()
    caps_probes = 1
    apply_caps()
    feats = detect_features()
    set_class('page1', 'keys-on', has_keys())
    if has_keys() then ext.key_mode(win, page == HUD and 2 or 0) end
    mo_school('frost'); set_class('mo_auto', 'on', MO.auto)
    dk_layout()
    setup_party()
    local names = {}
    for _, b in ipairs(SIM_BUFFS) do names[#names + 1] = b.n end
    apply_spell_icons(names)
end

local function handle_change(ev)
    ctl_change(ev.id or '', ev.value)
end

local function handle_action(a)
    local n = tonumber(a:match('^page:(%d+)$'))
    if n then set_page(n); return end
    local s = a:match('^skin:(%w+)$')
    if s then set_skin(s); return end
    local c = a:match('^chrome:(%w+)$')
    if c then chrome = c; win:theme(c); return end
    local ab = tonumber(a:match('^ab:(%d+)$'))
    if ab then press(ab, now()); return end
    if a == 'loot:drop' then loot_drop(); return end
    local mo = a:match('^mo:(%w+)$')
    if mo then
        if MO_SPELL[mo] then mo_school(mo)
        elseif mo == 'auto' then MO.auto = not MO.auto; set_class('mo_auto', 'on', MO.auto)
        elseif mo == 'cast' and (MO.phase == '' or MO.auto) then MO.t0 = now() end
        return
    end
    if dk_action(a) then return end
    if ctl_action(a) then return end
    if page_action(a) then return end
    if a == 'sim:toggle' then
        sim_on = not sim_on; sim_forced = sim_on
        set_class('sim_btn', 'on', sim_on)
        return
    end
    if a == 'grad:toggle' then
        show_grad = not show_grad
        apply_grad()
        return
    end
end

-- v3 key events (only arrive when ext + the v3 DLL are present and a key mode is on)
local function handle_key(k)
    if not k.down or k.ctrl or k.alt then return end
    if page == HUD then
        local d = tonumber(k.key) or tonumber((k.key or ''):match('^Keypad(%d)$'))
        if d and d >= 1 and d <= 8 then press(d, now()) end
    end
end

local handlers

local function on_frame()
    if not win then
        win = open()
        if not win then return end
        setup()
    end
    if not (ext and ext.tick or host.tick)(win, handlers) then running = false end
end

handlers = {
    close = function()
        if opened_at and (now() - opened_at) < 600 then return end
        running = false
    end,
    closed = function() running = false end,
    change = handle_change,
    key = handle_key,
    model = function(ev) if ev.key == 'gname' and party.model then party.model.cache.gname = ev.value end end,
    action = handle_action,
    update = function()
        local t = now()
        frames = frames + 1
        if last_fps_t == 0 then last_fps_t = t end
        if t - last_fps_t >= 1000 then
            set_text('st_fps', tostring(math.floor(frames * 1000 / math.max(1, t - last_fps_t) + 0.5)))
            frames, last_fps_t = 0, t
        end
        if caps == 0 and caps_probes < 10 and t - caps_probe_t >= 1000 then
            caps_probe_t = t
            caps_probes = caps_probes + 1
            caps = detect_effects()
            if caps ~= 0 then apply_caps() end
        end
        -- Lua logic at 20 Hz, only for the visible page
        local dt = t - last_tick
        if dt >= 50 then
            last_tick = t
            if dt > 500 then dt = 50 end
            if C.load_t or C.kb_t then ctl_timers(t) end
            if page == HUD then tick_hud(t, dt)
            elseif page == 2 then tick_motion(t)
            elseif page == 4 then tick_grad_lua(t)
            elseif page == 5 then tick_party(t)
            elseif page == 6 then tick_typer(t)
            elseif page == 8 then tick_frames(t) end
        end
    end,
}

-- exposed for the offline mock
RMLUIDEMO_PRO_CALLS = function() return calls end

print('[RmlUiDemoPro] loaded. Close the window to stop.')
host.bind_loop(NAME, on_frame, function() return running end)
if win then win:close() end
print('[RmlUiDemoPro] stopped.')
