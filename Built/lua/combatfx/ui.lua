-- combatfx UI: FX medallion launcher (click = settings, right-click = menu), settings panel (tabs),
-- combat meter (DPS / HPS / DTPS tiles). Event driven; the only periodic writes are the meter (2 Hz, diffed)
-- and the small Performance line while the Effects tab is open.
local C = require('combatfx.core')
local FX = require('combatfx.fx')
local E = require('combatfx.events')
local SIM = require('combatfx.sim')
local TR = require('combatfx.tracker')
local NB = require('combatfx.nimbus')     -- t362: native EQ nimbus picker (Body FX tab)
local NA = require('combatfx.aura')       -- t436: native EQ ground aura picker (Aura tab)
local PF = require('combatfx.procfx')     -- t464: native EQ proc effects picker (Proc FX tab)
local OR = require('combatfx.ornament')   -- orn1: client-side ornament model swaps (Ornaments tab)
local FT = require('combatfx.features')  -- f8: Combat+ and Alerts tabs, share strings, perf tier, min text size
local TFX = nil                          -- tfx1: DX11 theme looks + animated card previews (optional)
do local ok, t = pcall(require, 'combatfx.themefx'); if ok and type(t) == 'table' then TFX = t end end
local M = {}
local L, ST, MN, PN
local tab = 'events'
local sel_kind = 'melee'
local in_mode = 'hex'
local acts, nact = {}, 0
local msg = ''
M.stop_cb = nil

local SWATCH = { '#ffffff', '#ffd040', '#ffb347', '#ff5a4a', '#ff2060', '#d090ff', '#b060ff', '#8ac8ff', '#00f0ff', '#40e0a0', '#6aff8a', '#c8ff40', '#a0a8b8', '#806060' }
-- plain-English helper lines for each number type
local KIND_HINT = { melee = 'Your weapon hits', spell = 'Your direct spell damage', dot = 'Your damage-over-time ticks', crit = 'Critical hits (shown bigger)',
    incoming = 'Damage you take', healin = 'Heals that land on you', healout = 'Heals you cast on others', miss = 'Misses, parries, dodges, blocks',
    resist = 'Your spells that were resisted', kill = 'Shown when you slay something', proc = 'Backstab, Frenzy, Crippling Blow', pet = 'Your pet\'s melee hits' }
local KIND_SAMPLE = { miss = 'parry', resist = 'RESIST', kill = 'SLAIN', crit = '5,210', incoming = '-1,234', healin = '+1,234', healout = '+1,234', proc = 'BACKSTAB', pet = '412' }
local FX_HINT = { numbers = 'Damage and heal numbers that float up', healfx = 'Green glow and sparks when you are healed', dmgfx = 'Red flash at the screen edges when hit',
    vignette = 'Dark red edges while your health is low', critflash = 'A quick bright flash on critical hits', burst = 'A ring when your spell lands',
    killbanner = 'Big SLAIN text when you kill', combatbanner = 'Short banner when a fight starts and ends', shake = 'Target health plate that shakes on hits',
    streak = 'Combo counter for quick hits in a row',
    bighit = 'MASSIVE on top-5% hits, NEW RECORD on your best', procs = 'Callouts for Backstab, Frenzy, Crippling Blow', pet = 'Your pet\'s hits, counted in DPS',
    buffwarn = 'Warns 15 s before a buff ends, and when it fades', ready = 'Pings when a spell gem comes back (20 s+ recast)', ccbreak = 'Mez broke / faded, root faded, you pulled aggro',
    group = 'Group member under 30% or dead', recap = 'Card after each fight: top hit, crit %, avoid %', stamps = 'Named mob, grey con, level up, AA point',
    resisttype = 'Shows Fire / Cold / Magic... on resists', death = 'Dark screen with who killed you and where', castbar = 'Slim bar with time left on your cast',
    dx11 = 'Master switch for GPU canvas effects (needs MQ2RmlUi). Old text effects still run if this is off',
    dx11_glow = 'Bloom glow behind crits, kills, records and the death screen',
    dx11_particles = 'GPU sparks, resist-colored spell bursts, heal motes, kill shards',
    dx11_shockwave = 'Expanding ring on big hits, kills and new records',
    dx11_trails = 'Motion trails on GPU particles',
    dx11_heartbeat = 'Pulsing low-HP vignette (replaces the flat edge strips while on)' }
local TFX_SWATCH = { '#000000', '#ffd040', '#ff8a00', '#a00000', '#ff2060', '#b060ff', '#40a0ff', '#40e0a0', '#ffffff' }
local SCN_ICON = { solo = 'dps', caster = 'fx', group = 'hps', raid = 'fight', lowhp = 'dtps', streak = 'xp' }

local function A(fn) nact = nact + 1; local a = 'x' .. nact; acts[a] = fn; return string.format(' id="a-%s" action="%s"', a, a) end
local function btn(label, fn, cls) return string.format('<div class="btn %s"%s>%s</div>', cls or '', A(fn), label) end
local function sw(on, fn) return string.format('<div class="sw%s"%s><div class="kn"></div></div>', on and ' on' or '', A(fn)) end
local function icon(n, cls) return string.format('<img%s src="../img/ic_%s_32.png"/>', cls and (' class="' .. cls .. '"') or '', n) end
local render
local function changed(fx_too) C.save_cfg(); if fx_too ~= false then FX.apply_settings() end; render() end
local PART_DESC = 'Poison, disease, earth, fire, frost... bursts, sparks and number particles. Numbers stay.'
local function toggle_particles()
    C.cfg.particles = not C.particles_on()
    if not C.cfg.particles then pcall(FX.clear) end           -- wipe what is already on screen
    msg = C.cfg.particles and 'Particle effects on' or 'Particle effects off'
    changed()
end
local function stepper(val, fmt, dec, inc)
    return string.format('<div class="step"><div class="sb"%s>&#8722;</div><span class="sv">%s</span><div class="sb"%s>+</div></div>', A(dec), string.format(fmt, val), A(inc))
end
local function seg(opts, cur, fn)
    local o = {}
    for _, p in ipairs(opts) do o[#o + 1] = string.format('<div class="sg%s"%s>%s</div>', cur == p[1] and ' sel' or '', A(function() fn(p[1]) end), p[2]) end
    return '<div class="seg">' .. table.concat(o) .. '</div>'
end
local function row(label, desc, control)
    return string.format('<div class="row"><span class="rl">%s</span><span class="rd">%s</span><div class="rc">%s</div></div>', label, desc or '', control)
end

-- ---------------------------------------------------------------- pages
local function page_events()
    local r = {}
    r[#r + 1] = '<div class="sec">NUMBER COLOURS &#183; <span class="dim">click a card to edit its colour, the switch turns that type on or off</span></div>'
    for i, k in ipairs(C.KINDS) do
        local c, on = C.cfg.color[k], C.cfg.on[k]
        r[#r + 1] = string.format('<div class="kc%s%s%s"%s><div class="kpv"><div class="kbar" style="background-color: %s;"></div><span class="kn2" style="color: %s;">%s</span></div><span class="kl">%s</span><span class="kh">%s</span>%s</div>',
            i % 2 == 0 and ' c2' or '', k == sel_kind and ' sel' or '', on and '' or ' off',
            A(function() sel_kind = k; in_mode = 'hex'; M.set_input('Colour for ' .. C.KIND_LABEL[k], c); SIM.preview(k); render() end),
            c, c, KIND_SAMPLE[k] or '1,234', C.KIND_LABEL[k], KIND_HINT[k] or '',
            sw(on, function() C.cfg.on[k] = not C.cfg.on[k]; changed(false) end))
    end
    r[#r + 1] = '<div class="clr"></div>'
    local g = {}
    local cur = C.cfg.color[sel_kind]
    for _, c in ipairs(SWATCH) do g[#g + 1] = string.format('<div class="gem%s" style="background-color: %s;"%s><div class="gh"></div><div class="gs"></div></div>', c == cur and ' cur' or '', c, A(function() M.set_color(sel_kind, c) end)) end
    r[#r + 1] = string.format('<div class="edt"><span class="el">EDITING &#183; %s</span><span class="pal">%s</span></div>', C.esc(C.KIND_LABEL[sel_kind]), table.concat(g))
    -- text effect for this lane: type, effect colour, size, live sample (the same font-effect string the overlay uses)
    local k = sel_kind
    local function tfx_changed() C.cfg.theme = 'Custom'; changed(false); SIM.preview(k) end
    local ec = {}
    for _, c in ipairs(TFX_SWATCH) do ec[#ec + 1] = string.format('<div class="gem sm%s" style="background-color: %s;"%s><div class="gh"></div></div>', c == C.cfg.tc[k] and ' cur' or '', c, A(function() C.cfg.tc[k] = c; tfx_changed() end)) end
    r[#r + 1] = string.format('<div class="tfx"><div class="tfs"><span class="tfsv" style="color: %s; font-effect: %s;">%s</span></div>' ..
        '<div class="tfr r1"><span class="el">TEXT EFFECT</span>%s</div><div class="tfr r2"><span class="el">EFFECT COLOUR</span><span class="pal">%s</span><span class="el sz">SIZE</span>%s</div>%s</div>',
        C.cfg.color[k], C.font_effect(k), KIND_SAMPLE[k] or '1,234',
        seg(C.TFX_TYPES, C.cfg.tt[k] or 'style', function(t) C.cfg.tt[k] = t; tfx_changed() end),
        table.concat(ec), stepper(C.cfg.ts[k] or 2, '%d', function() C.cfg.ts[k] = math.max(1, (C.cfg.ts[k] or 2) - 1); tfx_changed() end, function() C.cfg.ts[k] = math.min(6, (C.cfg.ts[k] or 2) + 1); tfx_changed() end),
        C.cfg.lite and '<span class="dim tfl">Lite mode is on: effects are off until you turn it off</span>' or '')
    return r
end
local function page_text()
    local cfg, r = C.cfg, {}
    r[#r + 1] = '<div class="sec">TEXT</div>'
    r[#r + 1] = row('Text size', 'How big the floating numbers are', stepper(cfg.size, '%d px', function() cfg.size = math.max(12, cfg.size - 2); changed(); SIM.preview('melee') end, function() cfg.size = math.min(44, cfg.size + 2); changed(); SIM.preview('melee') end))
    r[#r + 1] = row('Outline style', 'How the numbers stand out from the scene', seg({ { 'bold', 'Bold' }, { 'normal', 'Thin' }, { 'heavy', 'Heavy' }, { 'shadow', 'Shadow' } }, cfg.style, function(s) cfg.style = s; changed(); SIM.preview('crit') end))
    r[#r + 1] = row('Number format', 'Full numbers or shortened thousands', seg({ { 'raw', '12,345' }, { 'short', '12.3k' } }, cfg.fmt, function(s) cfg.fmt = s; changed() end))
    r[#r + 1] = '<div class="sec">MOTION</div>'
    r[#r + 1] = row('Movement', 'How numbers travel after they appear', seg({ { 'rise', 'Rise' }, { 'arc', 'Arc' }, { 'fountain', 'Fountain' }, { 'static', 'Stay' }, { 'scroll', 'Scroll' } }, cfg.motion, function(s) cfg.motion = s; changed(); SIM.preview('melee'); SIM.preview('spell') end))
    r[#r + 1] = row('Time on screen', 'How long each number stays visible', stepper(cfg.dur, '%.1f s', function() cfg.dur = math.max(0.6, cfg.dur - 0.1); changed() end, function() cfg.dur = math.min(3.0, cfg.dur + 0.1); changed() end))
    r[#r + 1] = row('Most at once', 'Extra hits merge into one number (x3) instead of piling up', stepper(cfg.max, '%d', function() cfg.max = math.max(4, cfg.max - 2); changed() end, function() cfg.max = math.min(40, cfg.max + 2); changed() end))
    r[#r + 1] = '<div class="sec">ACCESSIBILITY &#183; <span class="dim">colour-blind safe palettes are on the Themes tab (Deuteranopia, Protanopia, Tritanopia, High Contrast)</span></div>'
    local ms = tonumber(cfg.minsize) or 0
    r[#r + 1] = row('Minimum text size', 'No number, alert or flourish is drawn smaller than this (Off = theme sizes)',
        stepper(ms > 0 and (ms .. ' px') or 'Off', '%s', function() cfg.minsize = ms <= 14 and 0 or (ms - 2); changed(); SIM.preview('dot') end,
            function() cfg.minsize = ms <= 0 and 14 or math.min(40, ms + 2); changed(); SIM.preview('dot') end))
    return r
end
local function fxcard(i, on, label, desc, fn)
    -- whole card is the button; the switch inside is just a picture of the state
    return string.format('<div class="fxc%s%s"%s><div class="sw%s"><div class="kn"></div></div><span class="fl">%s</span><span class="fd">%s</span></div>', i % 2 == 0 and ' c2' or '', on and ' on' or '', A(fn), on and ' on' or '', label, desc)
end
local function perf_line()
    local n, e, vis = FX.cost()
    return string.format('<span class="pk">PERFORMANCE</span>On screen now: <span class="pv">%d</span> numbers, <span class="pv">%d</span> effects &#183; overlay %s &#183; %s',
        n, e, vis and '<span class="wn">showing</span>' or '<span class="ok">hidden, no cost</span>', SIM.active() and '<span class="wn">simulating</span>' or (E.registered .. ' chat triggers listening'))
end
function M.tier_line()
    local P = FT.perf
    local t = FT.tier()
    local cls = t == 0 and 'ok' or 'wn'
    return string.format('<span class="pk">CURRENT TIER</span><span class="%s">%s</span> &#183; %s fps (%s) &#183; %d numbers%s', cls, FT.TIERS[t].name,
        P.fps and P.fps > 0 and string.format('%.0f', P.fps) or '-', P.src or '-', P.nums or 0,
        C.cfg.perf.auto and '' or ' &#183; <span class="dim">auto off</span>')
end
-- portable setup: where CombatFX found the EQ client, logs and sounds on THIS PC, and whether the native hooks match this eqgame
local PT = require('combatfx.paths')
local compat_c, compat_t = nil, -1e9
function M.setup_html()
    local i = PT.get()
    local now = C.now()
    if not compat_c or now - compat_t > 10000 then compat_t = now; local ok, v = pcall(PT.client_compat); compat_c = ok and v or { cls = 'wn', text = tostring(v) } end
    local function line(k, ok, txt) return string.format('<div class="pline"><span class="pk">%s</span><span class="%s">%s</span> %s</div>', k, ok and 'ok' or 'wn', ok and '&#10003;' or '&#10007;', txt) end
    local miss = {}
    for _, f in ipairs(i.eq_files or {}) do if not f.ok then miss[#miss + 1] = f.rel end end
    local o = {}
    o[#o + 1] = line('EQ folder', i.eq ~= nil, i.eq and (C.esc(i.eq) .. ' <span class="dim">(' .. (i.eq_src == 'ini' and 'from combatfx_paths.ini' or 'auto') .. ')</span>' ..
        (#miss > 0 and ('<br/><span class="dim">optional client files not found (only for rebuilding catalogs / research): ' .. C.esc(table.concat(miss, ', ')) .. '</span>') or ''))
        or ('not found, set eq_folder in combatfx_paths.ini <span class="dim">(' .. C.esc(i.eq_why or '') .. '; ornament archive checks are skipped)</span>'))
    o[#o + 1] = line('Sounds', i.snd ~= nil, i.snd and C.esc(i.snd) or ('not found, set sounds in combatfx_paths.ini: alert sounds are off'))
    o[#o + 1] = line('Logs', i.logs ~= nil, (i.logs and C.esc(i.logs) or 'unknown') .. ' <span class="dim">&#183; debug logs ' .. (i.debug and 'on' or 'off (debug_logs=0)') .. '</span>')
    o[#o + 1] = line('Client', compat_c.cls == 'ok', 'compatibility: ' .. C.esc(compat_c.text))
    o[#o + 1] = string.format('<div class="pline dim">Paths file: %s%s</div>', C.esc(PT.ini_path()), PT.ini_ok == false and ' <span class="wn">(cannot write it)</span>' or '')
    return table.concat(o)
end
local function page_fx()
    local cfg, r = C.cfg, {}
    r[#r + 1] = '<div class="sec">SETUP ON THIS PC &#183; <span class="dim">found automatically; overrides go in config\\combatfx_paths.ini</span></div>'
    r[#r + 1] = '<div class="card psetup" id="setup">' .. M.setup_html() .. '<div class="pbtns">' ..
        btn('Re-check', function() PT.reset(); PT.detect(); compat_t = -1e9; msg = 'Paths re-checked'; render() end, 'sm') .. '</div></div>'
    r[#r + 1] = '<div class="sec">GENERAL</div>'
    r[#r + 1] = fxcard(1, cfg.master, 'All effects', 'Master switch for everything below', function() cfg.master = not cfg.master; if not cfg.master then FX.clear() end; changed() end)
    r[#r + 1] = fxcard(2, cfg.lite, 'Lite mode', 'Max 8 numbers; no sparks, rings, stamps, callouts, cast bar', function() cfg.lite = not cfg.lite; changed() end)
    r[#r + 1] = fxcard(3, C.particles_on(), 'Particle effects', PART_DESC, toggle_particles)
    r[#r + 1] = '<div class="clr"></div><div class="sec">EFFECTS</div>'
    for i, k in ipairs(C.FX) do
        r[#r + 1] = fxcard(i, cfg.fx[k], C.FX_LABEL[k], FX_HINT[k] or '', function() cfg.fx[k] = not cfg.fx[k]; if k == 'shake' then FX.plate(false) end; changed() end)
    end
    r[#r + 1] = '<div class="clr"></div>'
    r[#r + 1] = row('Flash strength', 'How strong the screen-edge flashes are', stepper(cfg.intensity, '%d%%', function() cfg.intensity = math.max(10, cfg.intensity - 10); changed(); SIM.preview('incoming') end, function() cfg.intensity = math.min(100, cfg.intensity + 10); changed(); SIM.preview('incoming') end) ..
        '<span style="display: inline-block; width: 18px;"></span>' .. stepper(cfg.edge, '%d px', function() cfg.edge = math.max(20, cfg.edge - 10); changed(); SIM.preview('incoming') end, function() cfg.edge = math.min(200, cfg.edge + 10); changed(); SIM.preview('incoming') end))
    r[#r + 1] = row('Combat meter', 'Small window with your DPS, healing and damage taken', sw(cfg.meter, function() cfg.meter = not cfg.meter; changed(false); M.meter_vis() end))
    r[#r + 1] = '<div class="clr"></div><div class="sec">PERFORMANCE AUTO-SCALING &#183; <span class="dim">lowers particles, bloom and number count while FPS is low, then restores them</span></div>'
    r[#r + 1] = row('Auto performance', 'Full &#8594; Reduced (half particles, less bloom) &#8594; Low (no particles or bloom, 12 numbers)', sw(cfg.perf.auto, function() cfg.perf.auto = not cfg.perf.auto; changed() end))
    r[#r + 1] = row('FPS threshold', 'Steps down after 3 s below this; back up after 10 s above it + 8',
        stepper(cfg.perf.fps, '%d fps', function() cfg.perf.fps = math.max(15, cfg.perf.fps - 5); changed(false) end, function() cfg.perf.fps = math.min(120, cfg.perf.fps + 5); changed(false) end))
    r[#r + 1] = row('Busy screen', 'Also steps down when more numbers than this are on screen',
        stepper(cfg.perf.nums, '%d', function() cfg.perf.nums = math.max(8, cfg.perf.nums - 4); changed(false) end, function() cfg.perf.nums = math.min(80, cfg.perf.nums + 4); changed(false) end))
    r[#r + 1] = '<div class="perf" id="tier">' .. M.tier_line() .. '</div>'
    r[#r + 1] = '<div class="perf" id="perf">' .. perf_line() .. '</div>'
    return r
end
local saved_cache
-- tfx1: every card gets its own canvas; the DLL loops a hit, a crit, a heal and a combo in that look
local pv_cards, pv_pending, pv_tries, pv_ids = {}, false, 0, {}
local function tfx_on() return TFX and TFX.check and TFX.check() end
local function theme_card(i, name, t, sel, fn, sub)
    local inner
    if tfx_on() then
        local cid = 'thv' .. i
        pv_cards[#pv_cards + 1] = { id = cid, look = TFX.look_of(t, name), colors = t }
        inner = string.format('<canvas id="%s" class="thv"></canvas>', cid)
    else
        local function n(k, txt, x, y, sz) return string.format('<span class="thn" style="left: %dpx; top: %dpx; font-size: %dpx; color: %s;">%s</span>', x, y, sz, t[k] or '#ffffff', txt) end
        inner = n('melee', '1,234', 10, 4, 15) .. n('crit', '5,210', 86, 2, 20) .. n('healin', '+820', 14, 28, 14) .. n('incoming', '-412', 76, 30, 13) .. n('spell', '2,048', 136, 24, 14)
    end
    return string.format('<div class="thc%s%s"%s><div class="thp">%s</div><span class="thname">%s</span>%s%s</div>', i % 3 == 0 and ' c3' or '', sel and ' sel' or '', A(fn), inner, C.esc(name),
        sub and ('<span class="thsub">' .. sub .. '</span>') or '', sel and '<span class="thtag">IN USE</span>' or '')
end
local function look_edit(k, v)
    C.cfg.tfx[k] = v; C.cfg.theme = 'Custom'; msg = 'Custom look: ' .. k; changed()
end
local function cyc(list, cur, d) local n = #list; local at = 1; for i2, v in ipairs(list) do if v == cur then at = i2 end end; return list[(at - 1 + d + n) % n + 1] end
local function look_rows(r)
    local L = C.cfg.tfx
    local function num(label, desc, k, step, lo, hi, fmt)
        local v = tonumber(L[k]) or 0
        r[#r + 1] = row(label, desc, stepper(v, fmt or '%.1f',
            function() look_edit(k, math.max(lo, math.floor((v - step) / step + 0.5) * step)) end,
            function() look_edit(k, math.min(hi, math.floor((v + step) / step + 0.5) * step)) end))
    end
    local function pick(label, desc, k, list, labels, prev)
        local v = L[k]
        r[#r + 1] = row(label, desc, stepper(labels[v] or tostring(v), '%s', function() look_edit(k, cyc(list, v, -1)) end,
            function() look_edit(k, cyc(list, v, 1)) end))
    end
    r[#r + 1] = '<div class="sec">CUSTOM LOOK &#183; <span class="dim">DX11 shader text, motion, particles and crit impact (saved with your theme)</span></div>'
    r[#r + 1] = row('DX11 numbers', 'GPU-drawn themed numbers. Off = classic text', sw(L.on ~= false, function() L.on = not (L.on ~= false); C.cfg.theme = 'Custom'; changed() end))
    pick('Shader', 'Glow, outline, gradient and the animated surface', 'style', TFX.STYLES, TFX.STYLE_LABEL, 'crit')
    pick('Motion', 'How hits leave the target', 'mot', TFX.MOTIONS, TFX.MOTION_LABEL, 'melee')
    pick('Heal motion', 'Heals float up with a soft trail', 'healmot', TFX.MOTIONS, TFX.MOTION_LABEL, 'healin')
    pick('Particles', 'Shed by every number along its path', 'part', TFX.PARTS, TFX.PART_LABEL, 'spell')
    pick('Heal particles', 'Particles on heal numbers', 'healpart', TFX.PARTS, TFX.PART_LABEL, 'healin')
    num('Particle amount', 'Per second per number (lower = lighter)', 'prate', 2, 0, 40, '%d')
    num('Glow', 'Soft halo strength', 'glows', 0.1, 0, 4)
    num('Glow size', 'Halo radius', 'glowr', 1, 0, 11, '%d px')
    num('Outline', 'Soft outline width', 'outw', 0.5, 0, 6, '%.1f px')
    num('Gradient', 'How far the bottom fades to the theme tint', 'gradmix', 10, 0, 100, '%d%%')
    num('Shine', 'Moving metal / fire sweep on big hits', 'shine', 0.1, 0, 3)
    num('Crit punch', 'Scale punch-in on crits', 'punch', 0.05, 1, 3, 'x %.2f')
    num('Crit flash', 'White-hot flash on crits', 'flash', 0.1, 0, 3)
    num('Crit sparks', 'Sparks thrown off the number', 'sparks', 2, 0, 24, '%d')
    num('Shatter', 'Number breaks into shards at the end of a crit', 'shatter', 2, 0, 16, '%d')
    num('Screen shake', 'Huge crits shake the numbers layer (0 = off)', 'shake', 1, 0, 14, '%d px')
    num('Size by hit', 'Bigger hits draw bigger (vs your recent average)', 'mag', 10, 0, 100, '%d%%')
    num('Heal trail', 'Ghost trail behind floating heals', 'trail', 0.1, 0, 1)
    num('Bloom', 'Glow bloom on numbers and effects only, never on you', 'bloom', 0.05, 0, 2, '%.2f')
    r[#r + 1] = row('Combo counter', 'Fast repeat hits stack into one number with a x5 badge', sw((tonumber(L.combo) or 1) >= 1, function() look_edit('combo', (tonumber(L.combo) or 1) >= 1 and 0 or 1) end))
end
local function page_themes()
    local r = {}
    pv_cards = {}
    local live = tfx_on()
    r[#r + 1] = row('Particle effects', PART_DESC, sw(C.particles_on(), toggle_particles))
    -- clicking a card only selects the theme; the in-game showcase runs only from this button
    r[#r + 1] = row('Preview', 'Play every effect once in game with the selected theme (' .. C.esc(C.cfg.theme or 'Custom') .. ')',
        btn('Preview', function() SIM.showcase(); msg = 'Preview running: ' .. tostring(C.cfg.theme) .. ', about 11 seconds'; render() end, 'sm'))
    r[#r + 1] = string.format('<div class="sec">PRESETS &#183; <span class="dim">%s</span></div>', live and 'click one to use it; nothing fires in game until you press Preview' or
        ('click one to use it; press Preview to see it in game &#183; DX11 looks: ' .. C.esc(TFX and TFX.status() or 'themefx missing')))
    for i, n in ipairs(C.THEME_ORDER) do
        r[#r + 1] = theme_card(i, n, C.THEMES[n], C.cfg.theme == n, function() C.apply_theme(C.THEMES[n], n); msg = 'Theme: ' .. n; changed() end, TFX and TFX.DESC_TXT[n])
    end
    local cur = {}; for _, k in ipairs(C.KINDS) do cur[k] = C.cfg.color[k] end
    if TFX then TFX.snapshot(cur) end
    r[#r + 1] = theme_card(#C.THEME_ORDER + 1, 'Custom', cur, C.cfg.theme == 'Custom', function() C.cfg.theme = 'Custom'; changed(false) end, 'Your edits below')
    r[#r + 1] = '<div class="clr"></div>'
    if TFX and C.cfg.tfx then look_rows(r) end
    r[#r + 1] = '<div class="clr"></div><div class="sec">MY THEMES &#183; <span class="dim">saved in config\\combatfx_themes.ini (colours + full look); share files as combatfx_theme_NAME.ini</span></div>'
    if not saved_cache then saved_cache = { C.saved_themes() } end
    local t, order = saved_cache[1], saved_cache[2]
    if #order == 0 then r[#r + 1] = '<div class="empty">No saved themes yet. Type a name below and press Apply to save the current look.</div>' end
    for i, n in ipairs(order) do
        if i > 3 then r[#r + 1] = string.format('<div class="empty">+%d more in the file</div>', #order - 3); break end
        r[#r + 1] = string.format('<div class="svr"><span class="svn">%s</span><div class="svb">%s%s</div></div>', C.esc(n),
            btn('Use', function() C.apply_theme(t[n], n); msg = 'Theme: ' .. n; changed() end, 'sm'),
            btn('Share file', function() local ok, path = C.export_theme(n); msg = ok and ('Saved share file ' .. path) or ('Could not write ' .. path); render() end, 'sm'))
    end
    r[#r + 1] = '<div>' .. btn('Share current look', function() local ok, path = C.export_theme(C.cfg.theme); msg = ok and ('Saved share file ' .. path) or ('Could not write ' .. path); render() end, 'sm') ..
        btn('Refresh list', function() saved_cache = nil; render() end, 'sm') .. '</div>'
    -- f8: one copyable string (theme + full look); import validates every key and never runs anything
    r[#r + 1] = '<div class="clr"></div><div class="sec">SHARE AS TEXT &#183; <span class="dim">CFX1:... string with colours + full DX11 look; also saved as config\\combatfx_share_NAME.txt</span></div>'
    r[#r + 1] = row('Copy share string', 'Copies the current look to the clipboard and writes the .txt file',
        btn('Copy', function()
            local ok, path, str = C.export_share(C.cfg.theme or 'Custom')
            local okc = pcall(function() ImGui.SetClipboardText(str) end)
            msg = (okc and 'Copied share string (' .. #str .. ' chars)' or 'Clipboard unavailable') .. (ok and (' · saved ' .. path) or '')
            render()
        end, 'sm'))
    r[#r + 1] = row('Import share string', 'From the clipboard, or paste it in the box below and press Apply',
        btn('From clipboard', function()
            local okc, str = pcall(function() return ImGui.GetClipboardText() end)
            if not okc or not str then msg = 'Clipboard unavailable'; return render() end
            local ok, m = C.import_share(str); msg = m; saved_cache = nil; changed()
        end, 'sm') .. btn('Paste box', function() in_mode = 'import'; M.set_input('Share string', ''); msg = 'Paste the CFX1: string in the box below, then Apply'; render() end, 'sm'))
    local sf = C.share_files()
    for i, f in ipairs(sf) do
        if i > 4 then r[#r + 1] = string.format('<div class="empty">+%d more share files in config</div>', #sf - 4); break end
        r[#r + 1] = string.format('<div class="svr"><span class="svn">%s</span><div class="svb">%s</div></div>', C.esc(f),
            btn('Import', function() local str = C.read_share_file(f); local ok, m = C.import_share(str or ''); msg = m; saved_cache = nil; changed() end, 'sm'))
    end
    if TFX then
        r[#r + 1] = string.format('<div class="perf" id="tfxperf"><span class="pk">DX11 NUMBERS</span>%s</div>', C.esc(TFX.status() .. (TFX.last_line and (' &#183; ' .. TFX.last_line) or '')))
    end
    pv_pending = live and #pv_cards > 0; pv_tries = 0
    return r
end
-- spawn card previews once the page's canvases exist (retried for a few frames after the page write)
local function previews_tick()
    if not pv_pending or not TFX then return end
    if not (ST and ST.visible and (tab == 'themes' or tab == 'combat')) then pv_pending = false; return end
    pv_tries = pv_tries + 1
    local n = TFX.preview_cards(pv_cards)
    if n >= #pv_cards or pv_tries > 30 then
        pv_pending = false
        pv_ids = {}; for _, c in ipairs(pv_cards) do pv_ids[#pv_ids + 1] = c.id end
    end
end
local function previews_clear()
    pv_pending = false
    if TFX and #pv_ids > 0 then TFX.preview_clear(pv_ids) end
    pv_ids = {}
end
M.previews_clear = previews_clear
local function page_sim()
    local cfg, r = C.cfg, {}
    r[#r + 1] = '<div class="sec">PRACTICE FIGHTS &#183; <span class="dim">fake combat through the real effects; nothing is sent to the game</span></div>'
    for i, k in ipairs(SIM.ORDER) do
        r[#r + 1] = string.format('<div class="scn%s%s"%s>%s<span class="sl">%s</span></div>', i % 4 == 0 and ' c4' or '', SIM.running == k and ' on' or '',
            A(function() SIM.start(k); render() end), icon(SCN_ICON[k] or 'fx'), SIM.S[k].label)
    end
    r[#r + 1] = '<div class="clr"></div><div class="ctl">' ..
        btn(SIM.running and '&#9632;&#160; Stop' or '&#9654;&#160; Start', function() if SIM.running then SIM.stop() else SIM.start(SIM.last or 'solo') end; render() end, SIM.running and 'stop' or 'go') ..
        string.format('<div class="ctlg"><span class="flab">REPEAT</span>%s</div>', sw(cfg.sim_loop, function() cfg.sim_loop = not cfg.sim_loop; changed(false) end)) ..
        string.format('<span class="pill%s">%s</span>', SIM.running and ' run' or '', SIM.running and ('Running: ' .. SIM.S[SIM.running].label) or 'Not running') .. '</div>'
    r[#r + 1] = row('Speed', 'Events per second', stepper(cfg.sim_eps, '%d / s', function() cfg.sim_eps = math.max(1, cfg.sim_eps - 1); changed(false) end, function() cfg.sim_eps = math.min(30, cfg.sim_eps + 1); changed(false) end))
    r[#r + 1] = row('Damage size', 'Multiplies the fake numbers', stepper(cfg.sim_power, 'x %.1f', function() cfg.sim_power = math.max(0.5, cfg.sim_power - 0.5); changed(false) end, function() cfg.sim_power = math.min(5, cfg.sim_power + 0.5); changed(false) end))
    r[#r + 1] = '<div class="sec">FIRE ONE</div><div>'
    for _, it in ipairs(SIM.FIRE) do
        if it[2] then
            local c = C.cfg.color[it[1]]
            r[#r + 1] = string.format('<div class="fire"%s>%s%s</div>', A(function() SIM.fire(it[1]) end), c and string.format('<span class="fd2" style="background-color: %s;"></span>', c) or '', it[2])
        end
    end
    r[#r + 1] = '</div>'
    return r
end
local function tog_xp() C.cfg.xp = not C.cfg.xp; if C.cfg.xp then TR.reset_xp() end; C.save_cfg(); TR.vis(); render() end
local function tog_loot() C.cfg.loot = not C.cfg.loot; if C.cfg.loot then TR.reset_loot() end; C.save_cfg(); TR.vis(); render() end
M.tog_xp, M.tog_loot = tog_xp, tog_loot
local function page_track()
    local r = {}
    r[#r + 1] = '<div class="sec">TRACKER WINDOWS &#183; <span class="dim">both are off until you switch them on</span></div>'
    r[#r + 1] = string.format('<div class="tkc%s"><img src="../img/ic_xp_64.png"/><span class="tl1">Experience</span><span class="tl2">Level and AA progress, per-hour rates and time to next level</span>%s%s</div>',
        C.cfg.xp and ' on' or '', btn('Reset', function() TR.reset_xp(); TR.poll(true); msg = 'Experience session restarted'; render() end, 'sm'), sw(C.cfg.xp, tog_xp))
    r[#r + 1] = string.format('<div class="tkc%s"><img src="../img/ic_loot_64.png"/><span class="tl1">Loot value</span><span class="tl2">Adds up what you loot, value per hour and a recent list</span>%s%s</div>',
        C.cfg.loot and ' on' or '', btn('Reset', function() TR.reset_loot(); TR.poll(true); msg = 'Loot session restarted'; render() end, 'sm'), sw(C.cfg.loot, tog_loot))
    r[#r + 1] = '<div class="card"><span class="dim" style="font-size: 11px;">Level-ups and AA points count toward the rates. Experience lost on death is skipped, not subtracted.<br/>Loot uses each item\'s vendor value times the stack size, before faction and Charisma. Items not found in your bags show as "value unknown".<br/>Drag either window by its title bar.</span></div>'
    return r
end
local STYLE_SWATCH = { '#ffd040', '#ff7a3a', '#7ac8ff', '#7ad040', '#c4a030', '#b080ff', '#7ad4ff', '#6a30a0', '#ffe9a0', '#c01828', '#c8e8ff', '#6ec8ff', '#c09050' }
local function style_card(which, st, i, selected)
    return string.format('<div class="styc%s%s"%s><img class="styi" src="../img/thumbc_%s.png"/><span class="styn">%s</span>%s</div>',
        i % 4 == 0 and ' c4' or '', selected and ' sel' or '',
        A(function()
            C.cfg.fxstyle[which] = st.id
            msg = ((which == 'crit') and 'Crit look: ' or 'Proc look: ') .. st.label
            changed(false)
            FX.preview_style(st.id, which)
        end),
        st.id, C.esc(st.label), selected and '<span class="stytag">SELECTED</span>' or '')
end
-- ---- t464: native EQ proc effects (rml_nimbus_burst): EQ's own spell-hit records played on a body --------------
local NP = { cat = 'all', sub = 'all', pg = 1, PER = 60, MAXONE = 120, sel = nil, eid = {} }   -- eid: card -> its element id on the current page   -- one local (ui.lua is at Lua's 200-locals limit)
NP.SF = require('combatfx.spellfx')   -- t470: Spell assignments + effect numbers (kept in NP: no new ui.lua local)
NP.q, NP.view, NP.det, NP.sv, NP.ak = '', 'grid', false, 'all', nil   -- search, view (grid / gems), Details open, seen filter, entry being edited
-- t470: the status flickered: the debug counters (left_ms, alive ...) changed every 0.5 s and wrapped to a different
-- number of lines, so the whole page jumped. Now: one fixed-height line (no counters), raw details only when opened.
NP.STAT_STYLE = 'height: 18px; white-space: nowrap; overflow: hidden; font-size: 12px; color: #ece8fa;'
function NP.status_html()
    local f = PF.status_text()
    f = tostring(f or ''):gsub(' &#183; %d+ emitters', '')
    return f
end
-- raw debug details (Details open only): the counters that tick every frame are dropped, so it changes on events only
function NP.strip_raw(raw)
    raw = tostring(raw or '')
    raw = raw:gsub(' ?left_ms=%-?%d+', ''):gsub(' ?alive=%-?%d+', ''):gsub(' ?attached=%-?%d+', ''):gsub(' ?owner_ok=%-?%d+', '')
    return C.esc(raw)
end
function NP.det_html(raw) return '<span class="dim" style="font-size: 9px;">' .. NP.strip_raw(raw) .. '</span>' end
function NP.det_box(id, raw, open, fn)
    return '<div class="mknav" style="margin: -4px 0px 4px 0px;">' .. btn(open and '&#9662; Hide details' or '&#9656; Details', fn, 'sm') .. '</div>' ..
        (open and string.format('<div class="card" id="%s" style="height: 46px; overflow: hidden;">%s</div>', id, NP.det_html(raw)) or '')
end
-- seed the diff cache with what the page just drew (the page itself is one big write)
function NP.seed(id, html) ST.cache['r' .. id] = html end
function NP.sel_html()
    if NP.sel == 'auto' then return '<span style="color: #ece8fa; font-weight: bold;">Auto</span> <span class="dim">&#183; each proc plays the new effect for its element (fire, cold, poison, disease, magic, shadow, holy, lifetap ...); press Preview, then Use</span>' end
    local n = NP.sel and PF.D.by_id[NP.sel]
    if not n then return '<span class="dim">Click a picture to select it, then Preview to see it on your target (or you); Use keeps it for every proc</span>' end
    if n.custom then   -- t468: a NEW effect (not in EQ's files)
        return string.format('<span style="color: #ece8fa; font-weight: bold;">%s %s</span> <span class="dim">&#183; NEW &#183; %s &#183; EQ textures: %s</span>', NP.SF.num(n.id), C.esc(n.name), n.desc, C.esc(n.tex))
    end
    return string.format('<span style="color: #ece8fa; font-weight: bold;">%s %s</span> <span class="dim">&#183; Stock EQ #%d &#183; record %s &#183; %s &#183; textures: %s</span>',
        NP.SF.num(n.id), C.esc(n.name), n.id, C.esc(n.raw), n.desc, C.esc(n.tex))
end
function NP.refresh()
    if not (ST and ST.visible and tab == 'styles') then return end
    if NP.view == 'grid' then
        ST:rml('npstat', NP.status_html())          -- ST:rml is diffed: only a changed line is written
        ST:rml('npsel', NP.sel_html())
        local t = C.now()
        if NP.det and t >= (NP.det_t or 0) then NP.det_t = t + 1000; local _, raw = PF.status_text(); ST:rml('npdet', NP.det_html(raw)) end
    else NP.sa_refresh() end
    NP.poll()
end
-- t465: one Preview for both buttons (the green header Preview runs this on the Proc FX tab, not the theme showcase)
function NP.preview()
    local ok, why = PF.available()
    if not ok then msg = 'Native proc effects unavailable: ' .. tostring(why); return render() end
    local c = PF.cfg()
    local sel = NP.sel or ((c.mode == 'pick' and PF.D.by_id[c.id]) and c.id or 'auto')
    NP.sel = sel
    local okp, w, ms = PF.preview(sel == 'auto' and 0 or sel)
    local n = PF.D.by_id[sel == 'auto' and PF.pick_id('proc', 'Fire') or sel]
    msg = okp and string.format('Previewing %s on %s for %.1f s - watch the body; the status line says where it played', n and n.name or 'Auto', tostring(w), (ms or 0) / 1000)
        or ('Could not preview: ' .. tostring(w))
    render()
end
-- t467: ~110 cards: a click only moves the 'sel' class and rewrites the selection line (no page rebuild)
function NP.select(id, label)
    local prev = NP.sel
    NP.sel = id                                  -- select only: previews play from the Preview button
    msg = 'Selected ' .. label .. ' - press Preview to play it on your target (or you), Use keeps it'
    if ST and ST.visible and tab == 'styles' then
        if prev ~= nil and prev ~= id and NP.eid[prev] then ST:class(NP.eid[prev], 'sel', false) end
        if NP.eid[id] then ST:class(NP.eid[id], 'sel', true) end
        ST:rml('npsel', NP.sel_html()); ST:text('smsg', msg)
    else render() end
end
function NP.card(id, img, label, i, cur, dis)
    local tag = cur and '<span class="stytag">IN USE</span>' or ''
    local attrs = dis and ' style="opacity: 0.45;"' or A(function() NP.select(id, label) end)
    NP.eid[id] = attrs:match(' id="([^"]+)"')      -- the card's own element id (A() gives every clickable one)
    return string.format('<div class="styc%s%s"%s><img class="styi" src="../img/thumbnp_%s.png"/><span class="styn">%s</span>%s</div>',
        i % 4 == 0 and ' c4' or '', (NP.sel == id) and ' sel' or '', attrs, img, C.esc(label), tag)
end
-- t469: chips that wrap onto more rows (the one-line seg ran out of room: Stock EQ was cut off)
function NP.chips(opts, cur, fn)
    local o = {}
    for _, p in ipairs(opts) do
        o[#o + 1] = string.format('<div class="sg%s" style="margin: 0px 4px 4px 0px; border: 1px #ffffff14; background-color: #08070fd0;"%s>%s</div>',
            cur == p[1] and ' sel' or '', A(function() fn(p[1]) end), p[2])
    end
    return '<div style="white-space: normal; margin-bottom: 4px;">' .. table.concat(o) .. '</div>'
end
-- t469: hundreds of Stock EQ cards: NP.PER per page (keeps the page fast and the loaded pictures bounded)
function NP.pager(total)
    local pages = (total <= NP.MAXONE) and 1 or math.ceil(total / NP.PER)   -- up to 120 on one page, else pages of 60
    if NP.pg > pages then NP.pg = pages end
    if NP.pg < 1 then NP.pg = 1 end
    if pages <= 1 then return '' end
    local function pb(label, to, on)
        if not on then return string.format('<div class="btn sm" style="opacity: 0.35;">%s</div>', label) end
        return btn(label, function() NP.pg = to; render() end, 'sm')
    end
    return '<div class="mknav" style="margin: 2px 0px 6px 0px;">' .. pb('&#9664; Prev', NP.pg - 1, NP.pg > 1) ..
        string.format('<span class="dim" style="font-size: 11px; padding: 0px 10px;">Page %d of %d &#183; %d effects</span>', NP.pg, pages, total) ..
        pb('Next &#9654;', NP.pg + 1, NP.pg < pages) .. '</div>'
end
function NP.page(r)
    local ok, why = PF.available()
    local c = PF.cfg()
    r[#r + 1] = '<div class="sec">NATIVE PROC EFFECTS &#183; <span class="dim">new spell effects built on EQ\'s own textures (spirals, vortices, shock rings, rain, orbits), played by the client on the body in the world like its own; they wrap the body and keep their size when the camera moves; only you see them. EQ\'s own records are under Stock EQ</span></div>'
    if not ok then
        r[#r + 1] = '<div class="card"><span class="wn" style="font-size: 12px;">Native proc effects unavailable</span><br/><span class="dim" style="font-size: 11px;">' .. C.esc(why) .. '. The screen-drawn look below is used until then.</span></div>'
    end
    local sh = NP.status_html(); NP.seed('npstat', sh)
    r[#r + 1] = '<div class="card" id="npstat" style="' .. NP.STAT_STYLE .. '">' .. sh .. '</div>'
    do local _, raw = PF.status_text(); local dh = NP.det_html(raw); if NP.det then NP.seed('npdet', dh) end
        r[#r + 1] = NP.det_box('npdet', raw, NP.det, function() NP.det = not NP.det; render() end) end
    local dis = not ok
    NP.give_bar(r, dis)
    r[#r + 1] = row('Native proc effects', 'Play procs as EQ effects on the body (off = the old screen-drawn look below)',
        sw(c.mode ~= 'off', function() PF.set_mode(c.mode == 'off' and ((PF.D.by_id[c.id] and 'pick') or 'auto') or 'off'); msg = PF.on() and 'Native proc effects on' or 'Native proc effects off: screen-drawn look'; changed(false) end))
    r[#r + 1] = row('Show on', 'Whose body the effect wraps (no target: you)',
        seg({ { 'target', 'Your target' }, { 'self', 'You' } }, c.where, function(w) PF.set_where(w); changed(false) end))
    local function b(label, fn, cls) if dis then return string.format('<div class="btn %s" style="opacity: 0.4;">%s</div>', cls or '', label) end; return btn(label, fn, cls) end
    r[#r + 1] = '<div class="mknav">' ..
        b('&#9654;&#160; Preview', function() NP.preview() end, 'sm') ..
        b('&#10003;&#160; Use for procs', function()
            if not NP.sel then msg = 'Click a picture first'; return render() end
            if NP.sel == 'auto' then PF.set_mode('auto'); msg = 'Procs: Auto (record by element)'
            else local oku, w = PF.use(NP.sel); msg = oku and ('Procs: ' .. PF.D.by_id[NP.sel].name .. ' (saved)') or ('Could not use: ' .. tostring(w)) end
            render()
        end, 'sm pri') .. '</div>'
    local slh = NP.sel_html(); NP.seed('npsel', slh)
    r[#r + 1] = '<div style="height: 22px; margin-bottom: 6px; white-space: nowrap; overflow: hidden; font-size: 11px;" id="npsel">' .. slh .. '</div>'
    local segs = {}
    local catname = 'All new'
    for _, cc in ipairs(PF.D.cats) do segs[#segs + 1] = { cc[1], cc[2] }; if cc[1] == NP.cat then catname = cc[2] end end
    r[#r + 1] = NP.chips(segs, NP.cat, function(cc) NP.cat = cc; NP.pg = 1; render() end)
    if NP.cat == 'stock' then   -- t469: Stock EQ sub-groups
        local ss = {}
        for _, cc in ipairs(PF.D.stock_cats) do ss[#ss + 1] = { cc[1], cc[2] }; if cc[1] == NP.sub and cc[1] ~= 'all' then catname = 'Stock EQ &#183; ' .. cc[2] end end
        r[#r + 1] = '<div style="padding-left: 10px; border-left: 2px #b090ff50; margin-bottom: 4px;">' ..
            NP.chips(ss, NP.sub, function(cc) NP.sub = cc; NP.pg = 1; render() end) .. '</div>'
    end
    local shown = PF.filter(NP.cat, NP.sub)
    local cok, cwhy = PF.custom_available()
    if NP.q ~= '' then   -- t470: search by number (#12 = NEW 12, E317 = Stock EQ 317, 12 = both) or by name / element / texture
        local s0 = PF.s0_available()
        shown = {}
        for _, n in ipairs(NP.SF.search(NP.q, cok)) do if s0 or not n.s0 then shown[#shown + 1] = n end end
        catname = 'Search &#8220;' .. C.esc(NP.q) .. '&#8221;'
        r[#r + 1] = '<div class="mknav" style="margin-bottom: 4px;">' .. btn('&#215;&#160; Clear search', function() NP.q = ''; NP.pg = 1; NP.input(true); render() end, 'sm') .. '</div>'
    end
    r[#r + 1] = string.format('<div style="font-size: 11px; color: #ece8fa; margin-bottom: 2px;">%s &#183; <span class="dim">%s</span></div>', catname,
        (NP.q ~= '') and (#shown .. ' found &#183; type in the box below: #12 = NEW effect 12, E317 = Stock EQ record 317, or a name') or (NP.cat == 'stock') and (#shown .. ' of EQ\'s own spell effect records (the client\'s spellsnew.eff; hand-picked ones first)') or (NP.cat == 'all') and
        string.format('%d new effects + Auto in %d elements; Stock EQ has %d EQ records', #shown, #PF.D.cats - 2, PF.D.STOCK_COUNT) or (#shown .. ' new effects'))
    if not cok and NP.cat ~= 'stock' then r[#r + 1] = '<div class="wn" style="font-size: 10px; margin-bottom: 4px;">' .. C.esc(cwhy) .. '</div>' end
    r[#r + 1] = '<div class="dim" style="font-size: 10px; margin-bottom: 4px;">' .. ((NP.cat == 'stock') and 'Pictures are offline renders of each EQ record (its real textures, shapes and colours); in game EQ animates them on the body.'
        or 'Pictures are offline renders simulated from the exact emitter data MQ2RmlUi adds to the client (EQ textures, shapes, motion); in game EQ animates them on the body.') .. ' Size and Brightness below also drive the native effects (new effects: particle size, count, colour and opacity; Brightness 150% and up plays EQ records twice, layered); Duration sets how long one stays.</div>'
    r[#r + 1] = '<div class="dim" style="font-size: 10px; margin-bottom: 4px;">Every effect has a number: NEW effects #1-#100, EQ records E + record id. Search them in the box at the bottom (number or name).</div>'
    r[#r + 1] = '<div class="clr"></div>'
    local i = 1
    NP.eid = {}
    local pager = NP.pager(#shown)
    r[#r + 1] = pager
    if NP.cat == 'all' and NP.pg == 1 and NP.q == '' then r[#r + 1] = NP.card('auto', 'auto', 'Auto (by element)', i, c.mode == 'auto', dis); i = i + 1 end
    local per = (#shown <= NP.MAXONE) and #shown or NP.PER
    for k = (NP.pg - 1) * per + 1, math.min(#shown, NP.pg * per) do
        local n = shown[k]
        r[#r + 1] = NP.card(n.id, tostring(n.id), NP.SF.num(n.id) .. '  ' .. n.name, i, c.mode == 'pick' and c.id == n.id, dis); i = i + 1
    end
    r[#r + 1] = '<div class="clr"></div>'
    if pager ~= '' then r[#r + 1] = NP.pager(#shown) end
end
-- ---- t472: Spell Gems & Procs = ONE plain list: Gem 1..N, then Primary / Secondary / Range proc; type a number ----------
NP.rows = {}             -- row index -> entry key ('@gem3', '@primary' ...); inputs sfn<i>, picture+name sfl<i>, spell name sfnm<i>
function NP.viewbar()
    local function tabb(v, label)
        local on = NP.view == v
        return string.format('<div class="btn%s" style="margin: 0px 6px 0px 0px; padding: 6px 14px; font-size: 13px;%s"%s>%s</div>', on and ' pri' or '',
            on and '' or ' opacity: 0.8;', A(function() NP.view = v; NP.ak = nil; NP.input(); render() end), label)
    end
    return '<div class="mknav" style="margin: 0px 0px 8px 0px;">' .. tabb('grid', '&#10022;&#160; Effects (numbered)') ..
        tabb('gems', '&#9733;&#160; Spell Gems &amp; Procs') .. '</div>'
end
function NP.input(keep)
    if not ST then return end
    in_mode = 'npq'; M.set_input('Search effects', keep and '' or NP.q)
    ST:text('inhint', '#12 = NEW effect 12, E317 = EQ record 317, or a name (fire, helix ...); filters as you type')
end
function NP.poll()
    if in_mode == 'npq' and NP.view == 'grid' then
        local v = ST:value('inp')
        if v ~= NP.q then NP.q = v; NP.pg = 1; render() end
    end
end
function NP.apply(v)
    NP.q = tostring(v or ''); NP.pg = 1; render()
end
function NP.eff_label(id)
    local n = PF.D.by_id[id or 0]
    if not n then return '' end
    return string.format('<img src="../img/thumbnp_%d.png" style="width: 48px; height: 30px; margin: 0px 6px -9px 0px;"/>%s %s', id, NP.SF.num(id), C.esc(n.name))
end
function NP.plain(id) local n = PF.D.by_id[id or 0]; return n and (NP.SF.num(id) .. ' ' .. n.name) or 'Auto' end
-- the spell / proc name a row stands for right now (gem slot or weapon slot)
function NP.row_spell(key)
    local gi = tonumber(key:match('^@gem(%d+)$'))
    if gi then local g = NP.SF.gems(); return g[gi] end
    return NP.SF.slot_procs()[key]
end
-- t489: Set = read THIS row's box, check it, save to the spellfx ini at once, show it back in the box
function NP.box_val(id)
    id = tonumber(id) or 0
    if id == 0 then return '' end
    return (NP.SF.num(id):gsub('^#', ''))
end
function NP.num_typed(i, v)
    local key = NP.rows[i]; if not key then return end
    local SF = NP.SF
    v = tostring(v or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if v == '' then
        if SF.get(key) then SF.set(key, 'id', 0) end
        SF.save_now(); msg = NP.rowname(key) .. ': cleared (saved)'
        return render()
    end
    local a, why = SF.assign_num(key, v)
    if not a then msg = NP.rowname(key) .. ': "' .. C.esc(v) .. '" is not an effect number (1-100, or E and an EQ record)'; ST:text('smsg', msg); return end
    a.on, a.land = true, true
    if not SF.on then SF.set_on(true) end
    SF.save_now()
    msg = NP.rowname(key) .. ' = ' .. NP.box_val(a.id) .. ' (saved)'
    render()
    return a
end
function NP.rowname(key)
    local gi = key:match('^@gem(%d+)$'); if gi then return 'Gem ' .. gi end
    for _, s in ipairs(NP.SF.SLOTS) do if s.key == key then return s.label end end
    return key
end
function NP.row_html(i, key, empty_txt, dis)
    local SF = NP.SF
    NP.rows[i] = key
    local a = SF.get(key)
    local nm = NP.row_spell(key)
    -- t489: no class="text" on the box (cfxui.rcss input.text = position: absolute -> every row's box stacked at the top-left)
    return string.format('<div style="height: 32px; line-height: 28px; white-space: nowrap; border-bottom: 1px #ffffff10; padding: 2px 0px;">' ..
        '<span style="display: inline-block; width: 110px; font-size: 13px; color: #ece8fa; font-weight: bold;">%s</span>' ..
        '<span id="sfnm%d" style="display: inline-block; width: 200px; font-size: 13px; overflow: hidden;">%s</span>' ..
        '<input type="text" id="sfn%d" value="%s" style="display: inline-block; position: relative; left: 0px; top: 0px; width: 70px; height: 22px; line-height: 20px; font-size: 13px; color: #ffffff; background-color: #0b0a16; border: 1px #b090ff; padding: 1px 6px; margin: 0px 8px 0px 0px; vertical-align: middle;"/>' ..
        '%s %s</div>',
        NP.rowname(key), i, nm and C.esc(nm) or ('<span class="dim">' .. empty_txt .. '</span>'),
        i, NP.box_val(a and a.id),
        btn('Set', function() NP.num_typed(i, ST:value('sfn' .. i)) end, 'sm'),
        dis and '' or btn('&#9654;', function()
            local cur = SF.get(key)
            if not cur or (cur.id or 0) == 0 then msg = NP.rowname(key) .. ': type a number and press Set first'; ST:text('smsg', msg); return end
            local okp, w = SF.preview(cur, NP.row_spell(key)); msg = okp and ('Previewing ' .. NP.plain(cur.id)) or ('Could not preview: ' .. tostring(w)); ST:text('smsg', msg)
        end, 'sm'))
end
-- names follow the gems / weapons live (only the name spans are rewritten: no page rebuild, no flicker)
function NP.sa_refresh()
    local t = C.now()
    if t < (NP.sa_next or 0) then return end
    NP.sa_next = t + 1000
    local _, n = NP.SF.gems(true)
    if n ~= NP.sa_n then return render() end
    for i, key in pairs(NP.rows) do
        local nm = NP.row_spell(key)
        ST:rml('sfnm' .. i, nm and C.esc(nm) or ('<span class="dim">' .. (key:match('^@gem') and '(empty)' or '(no proc)') .. '</span>'))
    end
end
function NP.gems_page(r, dis)
    local SF = NP.SF
    NP.rows = {}
    local _, n = SF.gems(true)
    SF.slot_procs(true)
    SF.log_diag()
    NP.sa_n = n; NP.sa_next = C.now() + 1000
    local i = 0
    for g = 1, n do i = i + 1; r[#r + 1] = NP.row_html(i, '@gem' .. g, '(empty)', dis); NP.seed('sfnm' .. i, (NP.row_spell('@gem' .. g) and C.esc(NP.row_spell('@gem' .. g))) or '<span class="dim">(empty)</span>') end
    r[#r + 1] = '<div style="height: 10px;"></div>'
    for _, s in ipairs(SF.SLOTS) do i = i + 1; r[#r + 1] = NP.row_html(i, s.key, '(no proc)', dis); NP.seed('sfnm' .. i, (NP.row_spell(s.key) and C.esc(NP.row_spell(s.key))) or '<span class="dim">(no proc)</span>') end
end
-- the grid while picking for an entry (kept for old entries; not reachable from the simple list)
function NP.give_bar(r, dis) NP.ak = nil end
local function page_styles()
    local fs, r = C.cfg.fxstyle, {}
    r[#r + 1] = NP.viewbar()                                   -- t471: Effects | Spell Gems & Procs, first thing on the page
    if NP.view == 'gems' then NP.gems_page(r, not (PF.available())); return r end
    r[#r + 1] = row('Particle effects', C.particles_on() and PART_DESC or 'OFF: proc and crit looks below are not drawn', sw(C.particles_on(), toggle_particles))
    NP.page(r)
    local native = PF.on() and (PF.available())
    r[#r + 1] = '<div class="sec">PROC LOOK (OLD, SCREEN-DRAWN) &#183; <span class="dim">' .. (native and 'not used while native proc effects are on' or 'click a card to preview on your current target (or the center of the screen)') .. '</span></div>'
    for i, st in ipairs(C.FX_STYLES) do
        r[#r + 1] = style_card('proc', st, i, fs.proc == st.id)
    end
    r[#r + 1] = '<div class="clr"></div>'
    r[#r + 1] = '<div class="sec">CRIT LOOK &#183; <span class="dim">critical hits use this style unless you also apply the proc look to crits</span></div>'
    for i, st in ipairs(C.FX_STYLES) do
        r[#r + 1] = style_card('crit', st, i, fs.crit == st.id)
    end
    r[#r + 1] = '<div class="clr"></div><div class="sec">LOOK OPTIONS</div>'
    local function step_pct(key, lo, hi)
        return stepper(fs[key], '%d%%',
            function() fs[key] = math.max(lo, (fs[key] or 100) - 10); changed(false) end,
            function() fs[key] = math.min(hi, (fs[key] or 100) + 10); changed(false) end)
    end
    r[#r + 1] = row('Size', 'Particle size of the native new effects (and the old burst)', step_pct('size', 50, 200))
    r[#r + 1] = row('Brightness', 'Native effects: opacity, colour and particle count (150%+ layers EQ records); old burst glow', step_pct('intensity', 50, 200))
    r[#r + 1] = row('Duration', 'How long the burst lasts', step_pct('duration', 50, 200))
    r[#r + 1] = row('Color', 'Element color follows the style; override tints every burst',
        seg({ { 'element', 'Element color' }, { 'custom', 'Override' } }, fs.color_mode or 'element',
            function(s) fs.color_mode = s; changed(false) end))
    if (fs.color_mode or 'element') == 'custom' then
        local g = {}
        for _, c in ipairs(STYLE_SWATCH) do
            g[#g + 1] = string.format('<div class="gem%s" style="background-color: %s;"%s><div class="gh"></div><div class="gs"></div></div>',
                c == fs.color and ' cur' or '', c, A(function() fs.color = c; changed(false); FX.preview_style(fs.proc, 'proc') end))
        end
        r[#r + 1] = '<div class="edt"><span class="el">OVERRIDE COLOUR</span><span class="pal">' .. table.concat(g) .. '</span></div>'
    end
    r[#r + 1] = row('Also on crits', 'Use your proc look for critical hits too (otherwise crits keep their own style)',
        sw(fs.scope == 'both', function() fs.scope = (fs.scope == 'both') and 'procs' or 'both'; changed(false) end))
    return r
end
local function ground_styles()
    local t = {}
    for _, st in ipairs(C.FX_STYLES) do
        if st.id ~= 'auto' then t[#t + 1] = st end
    end
    return t
end
local function ground_card(which, prefix, preview_kind, st, i, selected)
    return string.format('<div class="styc%s%s"%s><img class="styi" src="../img/thumb%s_%s.png"/><span class="styn">%s</span>%s</div>',
        i % 4 == 0 and ' c4' or '', selected and ' sel' or '',
        A(function()
            C.cfg[which].style = st.id
            msg = ((which == 'feetaura') and 'Feet aura: ' or 'Run trail: ') .. st.label
            changed(false)
            FX.preview_style(st.id, preview_kind)
        end),
        prefix, st.id, C.esc(st.label), selected and '<span class="stytag">SELECTED</span>' or '')
end
-- ---- t436: native EQ aura picker (rml_nimbus_add_slot(1, ...)) ------------------------------------
local na_cat, na_sel = 'all', nil
local function na_status_html()                      -- t470: one fixed-height line; raw details only when opened
    local f = NA.status_text()
    return tostring(f or '')
end
local function na_sel_html()
    local n = na_sel and NA.D.by_id[na_sel]
    if not n then return '<span class="dim">Click a picture to preview it on your character for 12 s, then Wear to keep it</span>' end
    return string.format('<span style="color: #ece8fa; font-weight: bold;">%s</span> <span class="dim">&#183; #%d &#183; EQ record %s%s &#183; textures: %s</span>',
        C.esc(n.name), n.id, C.esc(n.raw), n.spell ~= '' and (' &#183; spell ' .. C.esc(n.spell)) or '', C.esc(n.tex))
end
local function na_refresh()
    if not (ST and ST.visible and tab == 'aura') then return end
    ST:rml('nastat', na_status_html())
    ST:rml('nasel', na_sel_html())
    local t = C.now()
    if NP.na_det and t >= (NP.na_det_t or 0) then NP.na_det_t = t + 1000; local _, raw = NA.status_text(); ST:rml('nadet', NP.det_html(raw)) end
end
local function na_card(n, i, cur, dis)
    local tag = (cur == n.id) and '<span class="stytag">WORN</span>' or ''
    return string.format('<div class="styc%s%s"%s><img class="styi" src="../img/thumbna_%d.png"/><span class="styn">%s</span>%s</div>',
        i % 4 == 0 and ' c4' or '', (na_sel == n.id) and ' sel' or '',
        dis and ' style="opacity: 0.45;"' or A(function()
            na_sel = n.id
            local ok, why = NA.preview(n.id)
            msg = ok and ('Previewing ' .. n.name .. ' for 12 s (Wear keeps it)') or ('Could not preview: ' .. tostring(why))
            render()                                -- same as the old disc cards (A() owns the element id)
        end), n.id, C.esc(n.name), tag)
end
local function page_aura_native(r)
    local ok, why = NA.available()
    local cur = NA.saved_id()
    r[#r + 1] = '<div class="sec">NATIVE EQ AURAS &#183; <span class="dim">EQ\'s own ground / feet particle effects, drawn by the client in the world; they keep their size when you move the camera; only you see them</span></div>'
    if not ok then
        r[#r + 1] = '<div class="card"><span class="wn" style="font-size: 12px;">Native auras unavailable</span><br/><span class="dim" style="font-size: 11px;">' .. C.esc(why) .. '. The screen-drawn feet disc below still works.</span></div>'
    end
    do local sh = na_status_html(); NP.seed('nastat', sh)
        r[#r + 1] = '<div class="card" id="nastat" style="' .. NP.STAT_STYLE .. '">' .. sh .. '</div>'
        local _, raw = NA.status_text(); if NP.na_det then NP.seed('nadet', NP.det_html(raw)) end
        r[#r + 1] = NP.det_box('nadet', raw, NP.na_det, function() NP.na_det = not NP.na_det; render() end) end
    local dis = not ok
    local function b(label, fn, cls) if dis then return string.format('<div class="btn %s" style="opacity: 0.4;">%s</div>', cls or '', label) end; return btn(label, fn, cls) end
    r[#r + 1] = '<div class="mknav">' ..
        b('&#9654;&#160; Preview', function()
            if not na_sel then msg = 'Click an aura picture first'; return render() end
            local okp, w = NA.preview(na_sel); msg = okp and 'Previewing for 12 s' or ('Could not preview: ' .. tostring(w)); render()
        end, 'sm') ..
        b('&#10003;&#160; Wear', function()
            local id = na_sel or cur
            if not id or id <= 0 then msg = 'Click an aura picture first'; return render() end
            local okw, w = NA.wear(id)
            msg = okw and ('Native aura: ' .. NA.D.by_id[id].name .. ' (saved, comes back on every start)') or ('Could not apply: ' .. tostring(w))
            render()
        end, 'sm pri') ..
        b('&#8634;&#160; Restore', function()
            NA.restore(); na_sel = nil
            msg = 'Native aura removed' .. (C.cfg.feetaura.on and ' - back to the feet disc below' or '')
            render()
        end, 'sm') .. '</div>'
    r[#r + 1] = '<div style="height: 22px; margin-bottom: 6px; white-space: nowrap; overflow: hidden; font-size: 11px;" id="nasel">' .. na_sel_html() .. '</div>'
    local segs = {}
    for _, c in ipairs(NA.D.cats) do segs[#segs + 1] = { c[1], c[2] } end
    r[#r + 1] = '<div style="margin-bottom: 6px;">' .. seg(segs, na_cat, function(c) na_cat = c; render() end) .. '</div>'
    r[#r + 1] = '<div class="dim" style="font-size: 10px; margin-bottom: 4px;">Pictures are offline renders of each EQ record (its real textures, shapes and colours); in game EQ animates them.</div>'
    r[#r + 1] = '<div class="clr"></div>'
    for i, n in ipairs(NA.filter(na_cat)) do r[#r + 1] = na_card(n, i, cur, dis) end
    r[#r + 1] = '<div class="clr"></div>'
end
local function page_aura()
    local fa, r = C.cfg.feetaura, {}
    page_aura_native(r)
    local nat = NA.saved_id() > 0
    r[#r + 1] = '<div class="sec">FEET AURA (OLD, SCREEN-DRAWN) &#183; <span class="dim">' .. (nat and 'off while a native aura is worn (Restore to use it)' or 'a glowing disc drawn over the game under your feet') .. '</span></div>'
    r[#r + 1] = row('Feet aura', 'Show the disc while you are in the world',
        sw(fa.on, function() fa.on = not fa.on; changed(false); if fa.on then FX.preview_style(fa.style, 'aura') end end))
    r[#r + 1] = '<div class="clr"></div>'
    for i, st in ipairs(ground_styles()) do
        r[#r + 1] = ground_card('feetaura', 'ad', 'aura', st, i, fa.style == st.id)
    end
    if C.AURA_SHOWPIECES then
        r[#r + 1] = '<div class="clr"></div>'
        r[#r + 1] = '<div class="sec">SHOWPIECES &#183; <span class="dim">DX11 discs: layered textures, bloom, rotating rings, rising motes</span></div>'
        for i, st in ipairs(C.AURA_SHOWPIECES) do
            r[#r + 1] = ground_card('feetaura', 'sp', 'aura', st, i, fa.style == st.id)
        end
    end
    return r
end
local function page_trail()                      -- t485: foot trails played by EQ like its own nimbus trails (native slot 2)
    local NT, r = require('combatfx.trails'), {}
    local rt = NT.cfg()
    local ok = NT.available()
    if not NT.sel then NT.sel = rt.id end
    r[#r + 1] = '<div class="sec">FOOT TRAIL &#183; <span class="dim">' .. (ok and 'EQ draws it on the ground behind you, like Nimbus of Lava' or 'old screen-drawn marks (install the t485 MQ2RmlUi for EQ trails)') .. '</span></div>'
    do local sh = tostring((NT.status_text())); NP.seed('trstat', sh)
        r[#r + 1] = '<div class="card" id="trstat" style="' .. NP.STAT_STYLE .. '">' .. sh .. '</div>' end
    local sel = NT.D.by_id[NT.sel]
    r[#r + 1] = '<div class="mknav">' ..
        btn('&#9654;&#160; Preview', function()
            local okp, w = NT.preview(NT.sel); msg = okp and ('Previewing ' .. (sel and sel.name or '') .. (NT.native() and ' for 12 s' or '')) or ('Could not preview: ' .. tostring(w)); render()
        end, 'sm') ..
        btn('&#10003;&#160; Wear', function()
            NT.wear(NT.sel); msg = 'Foot trail: ' .. (sel and sel.name or '') .. ' (saved)'; changed(false); render()
        end, 'sm pri') ..
        btn('&#10005;&#160; Off', function() NT.off(); msg = 'Foot trail off'; changed(false); render() end, 'sm') ..
        string.format('<span class="dim" style="font-size: 11px; margin-left: 8px;">%s%s</span>', C.esc(sel and sel.name or ''), (rt.on and rt.id == NT.sel) and ' &#183; worn' or '') .. '</div>'
    r[#r + 1] = '<div class="clr"></div>'
    local i = 0
    for _, n in ipairs(NT.D.list) do
        if ok or n.style then                          -- without the native slot only the 12 looks (screen fallback) are offered
            i = i + 1
            local worn = rt.on and rt.id == n.id
            r[#r + 1] = string.format('<div class="styc%s%s"%s><img class="styi" src="%s"/><span class="styn">%s</span>%s</div>',
                i % 4 == 0 and ' c4' or '', (NT.sel == n.id) and ' sel' or '',
                A(function() NT.select(n.id); msg = n.name .. ' selected (Preview plays it, Wear keeps it)'; render() end),
                NT.thumb(n.id), C.esc(n.name), worn and '<span class="stytag">WORN</span>' or (n.kind == 'eq' and '<span class="stytag" style="background-color: #2a3550;">EQ</span>' or ''))
        end
    end
    r[#r + 1] = '<div class="clr"></div>'
    return r
end
NP.tr_refresh = function()
    if not (ST and ST.visible and tab == 'trail') then return end
    ST:rml('trstat', tostring((require('combatfx.trails').status_text())))
end
local function body_card(st, i, selected)
    return string.format('<div class="styc%s%s"%s><img class="styi" src="../img/thumbnb_%s.png"/><span class="styn">%s</span>%s</div>',
        i % 4 == 0 and ' c4' or '', selected and ' sel' or '',
        A(function()
            C.cfg.bodyfx.style = st.id
            msg = 'Body FX: ' .. st.label
            changed(false)
            FX.preview_style(st.id, 'body')
        end),
        st.id, C.esc(st.label), selected and '<span class="stytag">SELECTED</span>' or '')
end
-- ---- t362: native EQ nimbus picker ---------------------------------------------------------------
local nim_cat, nim_q, nim_sel = 'all', '', nil
local NIM_SEG = { { 'all', 'All' }, { 'body', 'Body' }, { 'god', 'God powerup' }, { 'status', 'Status' }, { 'fun', 'Fun' }, { 'vet', 'Veteran' }, { 'fav', '&#9733; Favs' } }
local NIM_CATLBL = {}
for _, c in ipairs(NB.D.CATS) do NIM_CATLBL[c.id] = c.label end
local ROW_SEL = ' style="border-color: #c8a8ff; background-color: #221A40;"'
local function nim_status_html()
    local f, raw = NB.status_text()
    return string.format('<span style="font-size: 12px; color: #ece8fa;">%s</span><br/><span class="dim" style="font-size: 9px;">%s</span>', f, C.esc(raw or ''))
end
local function nim_sel_html()
    local n = nim_sel and NB.D.by_id[nim_sel]
    if not n then return '<span class="dim">Click a nimbus in the list, then Preview</span>' end
    local _, fav = NB.favs()
    return string.format('<span style="color: #ece8fa; font-weight: bold;">%s%s</span> <span class="dim">&#183; #%d &#183; %s &#183; %s%s</span>',
        fav[n.id] and '&#9733; ' or '', C.esc(n.name), n.id, NIM_CATLBL[n.cat] or n.cat, C.esc(n.note), n.spell and (' &#183; ' .. C.esc(n.spell)) or '')
end
-- partial updates: selecting a row / applying must not rebuild the list (keeps the scroll position)
local function nim_refresh()
    if not (ST and ST.visible and tab == 'body') then return end
    ST:rml('nimstat', nim_status_html())
    ST:rml('nimsel', nim_sel_html())
end
local function nim_pick(id)
    local old = nim_sel
    nim_sel = id
    if old and old ~= id then ST:attr('nr' .. old, 'style', '') end
    ST:attr('nr' .. id, 'style', 'border-color: #c8a8ff; background-color: #221A40;')
    nim_refresh()
end
local function nim_preview()
    local bx = C.cfg.bodyfx
    local id = nim_sel or (tonumber(bx.native) or 0)
    if not id or id <= 0 then msg = 'Pick a nimbus in the list first'; return render() end
    local n = NB.D.by_id[id]
    bx.native, bx.on = id, true
    C.save_cfg()
    local ok, why = NB.apply(id)
    msg = ok and ('Native nimbus: ' .. (n and n.name or id) .. ' (saved, comes back on every start)') or ('Could not apply: ' .. tostring(why))
    render()
end
local function nim_clear()
    C.cfg.bodyfx.native = 0
    C.save_cfg()
    NB.clear()
    msg = 'Native nimbus cleared'
    render()
end
local function page_body()
    local bx, r = C.cfg.bodyfx, {}
    local ok, why = NB.available()
    r[#r + 1] = '<div class="sec">NATIVE NIMBUS &#183; <span class="dim">EQ\'s own nimbus, drawn by the client on your character; only you see it</span></div>'
    r[#r + 1] = row('Body FX', 'Show the selected nimbus (off removes it)',
        sw(bx.on, function() bx.on = not bx.on; msg = bx.on and 'Body FX on' or 'Body FX off: nimbus removed'; NB.sync(); changed(false) end))
    if not ok then
        r[#r + 1] = '<div class="card"><span class="wn" style="font-size: 12px;">Native nimbus unavailable</span><br/><span class="dim" style="font-size: 11px;">' .. C.esc(why) .. '. Load the MQ2RmlUi build with native nimbus support, then reopen this tab.</span></div>'
    end
    r[#r + 1] = '<div class="card" id="nimstat">' .. nim_status_html() .. '</div>'
    local dis = not ok
    local function b(label, fn, cls) if dis then return string.format('<div class="btn %s" style="opacity: 0.4;">%s</div>', cls or '', label) end; return btn(label, fn, cls) end
    local _, fav = NB.favs()
    r[#r + 1] = '<div class="mknav">' .. b('&#9654;&#160; Preview', nim_preview, 'sm pri') .. b('Clear', nim_clear, 'sm') ..
        b((nim_sel and fav[nim_sel]) and '&#9733; Unfavourite' or '&#9734; Favourite', function()
            if not nim_sel then msg = 'Pick a nimbus first'; return render() end
            local on = NB.toggle_fav(nim_sel); C.save_cfg()
            msg = (on and 'Favourite: ' or 'Removed favourite: ') .. (NB.D.by_id[nim_sel] and NB.D.by_id[nim_sel].name or '')
            render()
        end, 'sm') .. '</div>'
    r[#r + 1] = '<div style="height: 22px; margin-bottom: 6px; white-space: nowrap; overflow: hidden; font-size: 11px;" id="nimsel">' .. nim_sel_html() .. '</div>'
    r[#r + 1] = '<div style="margin-bottom: 6px;">' .. seg(NIM_SEG, nim_cat, function(c) nim_cat = c; render() end) .. '</div>'
    local list = NB.filter(nim_cat, nim_q)
    r[#r + 1] = string.format('<div class="dim" style="font-size: 10px; margin-bottom: 4px;">%d of %d shown%s &#183; search with the box at the bottom</div>',
        #list, NB.D.COUNT, nim_q ~= '' and (' &#183; search "' .. C.esc(nim_q) .. '"') or '')
    local cur = tonumber(bx.native) or 0
    local rows = {}
    for _, n in ipairs(list) do
        local tag = (cur == n.id and bx.on) and '<span class="ok">ON &#183; </span>' or ''
        rows[#rows + 1] = string.format('<div class="npcrow" id="nr%d"%s%s><span class="nn">%s%s%s</span><span class="nd">%s &#183; %s &#183; #%d</span></div>',
            n.id, (nim_sel == n.id and not dis) and ROW_SEL or '', dis and ' style="opacity: 0.45;"' or A(function() nim_pick(n.id) end),
            tag, fav[n.id] and '&#9733; ' or '', C.esc(n.name), NIM_CATLBL[n.cat] or n.cat, C.esc(n.note), n.id)
    end
    if #rows == 0 then rows[1] = '<div class="lempty">Nothing matches. Clear the search or pick another group.</div>' end
    r[#r + 1] = '<div class="nlist">' .. table.concat(rows) .. '</div>'  -- t363: list height lives in cfxui.rcss so the last rows clear the search bar

    r[#r + 1] = '<div class="sec">OLD OVERLAY GLOW &#183; <span class="dim">the earlier screen-space glow; off by default, never drawn while a native nimbus is selected</span></div>'
    r[#r + 1] = row('Overlay glow', (cur > 0) and 'Off while a native nimbus is selected (Clear it to use these)' or 'Draw the old glow styles below behind you',
        sw(bx.overlay == true, function() bx.overlay = not bx.overlay; changed(false); if bx.overlay and cur <= 0 then FX.preview_style(bx.style, 'body') end end))
    local function step_pct(key, lo, hi)
        return stepper(bx[key], '%d%%',
            function() bx[key] = math.max(lo, (bx[key] or 100) - 10); changed(false) end,
            function() bx[key] = math.min(hi, (bx[key] or 100) + 10); changed(false) end)
    end
    r[#r + 1] = row('Size', 'How far the overlay glow reaches past you', step_pct('size', 50, 200))
    r[#r + 1] = row('Intensity', 'How bright the overlay glow and motes are', step_pct('intensity', 50, 200))
    do
        local CV = package.loaded['combatfx.canvas']
        local mode, alive, masked, avail = 'lua', 0, false, false
        if CV and CV.body_mode then pcall(function() mode, alive, masked, avail = CV.body_mode() end) end
        local st = (mode == 'gpu') and ('GPU particles' .. (masked and ' &#183; bloom masked' or ' &#183; bloom off (update MQ2RmlUi for bloom)'))
            or (avail and 'GPU ready (starts when the overlay glow shows)' or 'Lua sprites (MQ2RmlUi GPU particles not available)')
        r[#r + 1] = row('GPU particles', 'Renderer: ' .. st .. ' &#183; /cfxprobe captures a frame',
            sw(bx.gpu ~= false, function() bx.gpu = (bx.gpu == false); changed(false) end))
    end
    r[#r + 1] = '<div class="clr"></div>'
    for i, st in ipairs(C.BODY_STYLES or {}) do
        r[#r + 1] = body_card(st, i, bx.style == st.id)
    end
    return r
end
local add_match = 'exact'
local function add_marker_rule(name, match)
    name = tostring(name or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if name == '' then msg = 'Type an NPC name first'; render(); return end
    local list = C.marker_rules()
    for _, r in ipairs(list) do
        if r.match == (match or add_match) and r.name:lower() == name:lower() then
            msg = 'Already have a rule for ' .. name
            render(); return
        end
    end
    list[#list + 1] = { match = match or add_match, name = name, style = 'both', color = '#ffd040', icon = 'skull' }
    C.set_marker_rules(list)
    msg = 'Marked: ' .. name
    local CV = package.loaded['combatfx.canvas']
    if CV and CV.marker_force_scan then CV.marker_force_scan() end
    changed(false)
end
-- t495: the nearby list fills when the page opens / Refresh (a full read now), then keeps itself current every 3 s
function NP.mk_scan()
    local CV = package.loaded['combatfx.canvas']
    if not CV then return 0 end
    if CV.marker_want_list then CV.marker_want_list(60000) end
    local n = 0
    if CV.marker_scan_now then local ok, v = pcall(CV.marker_scan_now); n = ok and tonumber(v) or 0 end
    NP.mk_sig = NP.mk_sig_of()   -- what the page is about to show
    return n
end
function NP.mk_sig_of()
    local CV = package.loaded['combatfx.canvas']
    local nb = (CV and CV.marker_nearby and CV.marker_nearby()) or {}
    local t = { #nb }
    for i = 1, math.min(12, #nb) do t[#t + 1] = tostring(nb[i].id) end
    return table.concat(t, ',')
end
function NP.mk_refresh()
    local t = C.now()
    if t < (NP.mk_next or 0) then return end
    NP.mk_next = t + 3000
    local CV = package.loaded['combatfx.canvas']
    if CV and CV.marker_want_list then CV.marker_want_list(60000) end
    if CV and CV.marker_scan_now then pcall(CV.marker_scan_now) end   -- does not wait for the overlay frame (it may be idle / off)
    local sig = NP.mk_sig_of()
    if sig ~= NP.mk_sig then NP.mk_sig = sig; return render() end
end
local function page_mark()
    local mk = C.cfg.markers or { on = true, import_pf = false, pack = '' }
    local r = {}
    r[#r + 1] = '<div class="sec">NPC MARKERS &#183; <span class="dim">icons and light beams on live NPCs; never saved ghost locations</span></div>'
    r[#r + 1] = row('Markers', 'Draw head icons and/or beams on matching NPCs',
        sw(mk.on, function() mk.on = not mk.on; C.cfg.markers = mk; changed(false) end))
    r[#r + 1] = row('Import PocketFarm', 'Read-only: this zone watch queries and Pull list. CombatFX never writes those files',
        sw(mk.import_pf, function()
            mk.import_pf = not mk.import_pf; C.cfg.markers = mk
            local CV = package.loaded['combatfx.canvas']
            if CV and CV.marker_force_scan then CV.marker_force_scan() end
            changed(false)
        end))
    r[#r + 1] = '<div class="card"><span class="dim" style="font-size: 11px;">Type a name below and press Apply, or click a nearby NPC. Match can be an exact name or a case-insensitive substring. Custom icons: drop PNG files in lua/combatfx/img/markers_custom/.</span></div>'
    r[#r + 1] = row('New rule match', 'Exact name, or any NPC whose name contains the text',
        seg({ { 'exact', 'Exact name' }, { 'pattern', 'Contains' } }, add_match, function(s) add_match = s; render() end))

    r[#r + 1] = '<div class="sec">NEARBY NPCS &#183; <span class="dim">click a row to add an exact-name rule</span></div>'
    local CV = package.loaded['combatfx.canvas']
    local nearby = (CV and CV.marker_nearby and CV.marker_nearby()) or {}
    r[#r + 1] = '<div class="mknav">' .. btn('Refresh list', function()
        if CV and CV.marker_force_scan then CV.marker_force_scan() end
        local n = NP.mk_scan()
        msg = n .. ' nearby NPCs'
        render()
    end, 'sm') .. string.format('<span class="dim"> %d nearby</span></div>', #nearby)
    if #nearby == 0 then
        r[#r + 1] = '<div class="lempty">No nearby list yet. Press Refresh (or wait a few seconds in-game).</div>'
    else
        local nshow = math.min(12, #nearby)
        for i = 1, nshow do
            local sp = nearby[i]
            r[#r + 1] = string.format(
                '<div class="npcrow"%s><span class="nn">%s</span><span class="nd">%d ft</span></div>',
                A(function() add_marker_rule(sp.name, 'exact') end),
                C.esc(sp.name or '?'), math.floor((sp.dist or 0) + 0.5))
        end
        if #nearby > nshow then
            r[#r + 1] = string.format('<div class="dim" style="font-size: 11px; margin-bottom: 8px;">+%d more not shown</div>', #nearby - nshow)
        end
    end

    local rules = C.marker_rules()
    r[#r + 1] = string.format('<div class="sec">YOUR RULES &#183; <span class="dim">%d saved for this character</span></div>', #rules)
    if #rules == 0 then
        r[#r + 1] = '<div class="lempty">No rules yet. Add a name or click a nearby NPC.</div>'
    end
    local colors = C.MARKER_COLORS or { '#ffd040', '#ff5a4a', '#8ac8ff' }
    local icons = C.MARKER_ICONS or {}
    local custom = (C.marker_custom_list and C.marker_custom_list()) or {}
    for i, rule in ipairs(rules) do
        local gems = {}
        for _, c in ipairs(colors) do
            gems[#gems + 1] = string.format(
                '<div class="gem sm%s" style="background-color: %s;"%s><div class="gh"></div><div class="gs"></div></div>',
                c == rule.color and ' cur' or '', c,
                A(function()
                    local list = C.marker_rules(); if list[i] then list[i].color = c; C.set_marker_rules(list); changed(false) end
                end))
        end
        local ichtml = {}
        for _, ic in ipairs(icons) do
            ichtml[#ichtml + 1] = string.format(
                '<div class="mki%s"%s><img src="../img/fx_mk_%s.png"/></div>',
                rule.icon == ic.id and ' sel' or '',
                A(function()
                    local list = C.marker_rules(); if list[i] then list[i].icon = ic.id; C.set_marker_rules(list); changed(false) end
                end), ic.id)
        end
        for _, stem in ipairs(custom) do
            local id = 'custom:' .. stem
            ichtml[#ichtml + 1] = string.format(
                '<div class="mki%s"%s><img src="../img/markers_custom/%s.png"/></div>',
                rule.icon == id and ' sel' or '',
                A(function()
                    local list = C.marker_rules(); if list[i] then list[i].icon = id; C.set_marker_rules(list); changed(false) end
                end), C.esc(stem))
        end
        r[#r + 1] = string.format(
            '<div class="mkcard"><div class="mkhd"><span class="mkn">%s</span><span class="mkmeta">%s</span>%s</div><div class="mkrow">%s</div><div class="mkrow"><span class="dim" style="font-size: 10px; margin-right: 8px;">Color</span>%s</div><div class="mkrow">%s</div></div>',
            C.esc(rule.name),
            (rule.match == 'pattern') and 'contains' or 'exact name',
            btn('Remove', function()
                local list = C.marker_rules(); table.remove(list, i); C.set_marker_rules(list)
                local cv = package.loaded['combatfx.canvas']
                if cv and cv.marker_force_scan then cv.marker_force_scan() end
                msg = 'Removed ' .. (rule.name or '')
                changed(false)
            end, 'sm'),
            seg({ { 'icon', 'Head icon' }, { 'beam', 'Light beam' }, { 'both', 'Both' } }, rule.style or 'both',
                function(s)
                    local list = C.marker_rules(); if list[i] then list[i].style = s; C.set_marker_rules(list); changed(false) end
                end),
            table.concat(gems),
            table.concat(ichtml))
    end
    return r
end


-- ---------------------------------------------------------------- orn1: Ornaments (client-side model swaps, previews rendered from the client's own models)
local orn_slot, orn_kind, orn_q, orn_page, orn_sel = 'primary', 'all', '', 1, nil
local ORN_PER = 12
local ORN_KINDS_HELD = { { 'all', 'All' }, { 'w', 'Weapons' }, { 'sh', 'Shields' }, { 'o', 'Other' }, { 'prt', 'Particles' }, { 'fav', '&#9733;' } }
local ORN_KINDS_MAIN = { { 'all', 'All' }, { 'w', 'Weapons' }, { 'o', 'Other' }, { 'prt', 'Particles' }, { 'fav', '&#9733;' } }   -- shieldfix: no shields in the main hand
local ORN_KINDS_SHIELD = { { 'all', 'All' }, { 'prt', 'Particles' }, { 'fav', '&#9733;' } }
local ORN_KINDS_ARM = { { 'all', 'All' }, { 'fav', '&#9733; Favourites' } }
local function orn_img(it, big) return string.format('../img/orn/%sIT%d.jpg', big and '' or 't/', it) end
-- orn-sets: whole armor set in one click (Sets button in the Ornaments slot row)
local set_kind, set_page, set_sel = 'all', 1, nil
local SET_PER = 12
local SET_KINDS = { { 'all', 'All sets' }, { 'full', 'Complete (7 slots)' }, { 'fav', '&#9733; Favourites' } }
local SET_SLOTN = { helm = 'Helm', chest = 'Chest', arms = 'Shoulders', wrist = 'Wrists', hands = 'Hands', legs = 'Legs', feet = 'Feet' }
-- set composites are per race tag (allraces): img/orn/r/<TAG>/[t/]SET<id>.jpg; a greyed set shows another race's (s.pv)
local function set_img(s, big, race)
    local tag = s.missing and s.pv or race or 'DWM'
    return string.format('../img/orn/r/%s/%sSET%d.jpg', tag, big and '' or 't/', s.id)
end
local function race_line(race, what)
    return string.format('<div class="dim" style="font-size: 11px; margin-bottom: 4px;">%s for <span style="color: #ece8fa;">%s</span> (%s), read from your character. Models and previews are this race\'s own.</div>',
        what, C.esc(OR.race_name(race)), C.esc(race))
end
local function sets_point_line()
    local st = OR.status()
    local parts = {}
    for _, sl in ipairs(OR.SLOTS) do
        if not sl.held then
            local tags, col = {}, 'dim'
            for _, pt in ipairs(sl.pts) do
                local state = OR.point_state(pt)
                local w = OR.wanted()[pt]
                tags[#tags + 1] = w and C.esc(w) or 'real'
                if state == 'failed' or state == 'nopoint' then col = 'wn' elseif state == 'on' and col ~= 'wn' then col = 'ok' end
            end
            parts[#parts + 1] = string.format('%s <span class="%s">%s</span>', sl.label, col, table.concat(tags, '/'))
        end
    end
    local extra = ''
    if OR.set_busy() then extra = '<br/><span class="dim">Sending the rest of the set...</span>' end
    if OR.available() and st and st.raw then
        if st.disabled then extra = extra .. '<br/><span class="wn">Disabled for this session after a fault (see Logs\\rmlui_canvas.log)</span>'
        elseif st.verified ~= 1 then extra = extra .. '<br/><span class="wn">Client build not verified: ornaments off</span>'
        elseif st.live ~= 0 then extra = extra .. '<br/><span class="dim">Waiting for your character (zoning / char select)</span>' end
    end
    return string.format('<span style="font-size: 11px;">%s</span>%s', table.concat(parts, ' &#183; '), extra)
end
local function set_detail_html(s, race)
    if not s then return '<div class="opbig oset opempty"><span class="dim">Click a set on the left to see it large</span></div>' end
    if s.missing then
        return string.format('<div class="opbig oset"><img src="%s"/></div><div class="opname">%s</div><div class="opmeta"><span class="wn">Not available for %s</span></div><div class="opmeta dim">Generic preview: %s model</div>',
            set_img(s, true, race), C.esc(s.name), C.esc(OR.race_name(race)), C.esc(OR.race_name(s.pv)))
    end
    local _, fav = OR.set_favs()
    local D = OR.data()
    local strip, names = {}, {}
    for _, p in ipairs(s.pieces) do
        strip[#strip + 1] = string.format('<img src="../img/orn/t/IT%d.jpg"/>', p.it)
        names[#names + 1] = (SET_SLOTN[p.slot] or p.slot)
    end
    local st = OR.set_state(s)
    return string.format('<div class="opbig oset"><img src="%s"/></div><div class="opname">%s%s</div><div class="opmeta">%d/7 slots: %s%s</div><div class="opcs">%s</div>',
        set_img(s, true, race), fav[s.id] and '&#9733; ' or '', C.esc(s.name), #s.pieces, table.concat(names, ', '),
        st == 'on' and ' &#183; <span class="ok">wearing</span>' or (st == 'saved' and ' &#183; <span class="dim">saved</span>' or ''), table.concat(strip))
end
local function page_sets(r, D)
    local SDd, serr = OR.sets()
    if not SDd then r[#r + 1] = '<div class="card"><span class="wn">' .. C.esc(serr) .. '</span></div>'; return r end
    local race = SDd.race
    r[#r + 1] = race_line(race, string.format('%d sets', SDd.n or #SDd.list) .. ((SDd.nmiss or 0) > 0 and string.format(' (%d more greyed: other races only)', SDd.nmiss) or ''))
    r[#r + 1] = '<div style="margin-bottom: 5px;">' .. seg(SET_KINDS, set_kind, function(k) set_kind = k; set_page = 1; render() end) .. '</div>'
    local list = OR.filter_sets(set_kind, orn_q)
    local pages = math.max(1, math.ceil(#list / SET_PER))
    if set_page > pages then set_page = pages end
    local _, fav = OR.set_favs()
    local tiles = {}
    for i = (set_page - 1) * SET_PER + 1, math.min(#list, set_page * SET_PER) do
        local s = list[i]
        tiles[#tiles + 1] = string.format('<div class="otile%s%s"%s><img src="%s"/><span class="ol">%s%s</span></div>',
            set_sel == s and ' sel' or '', OR.set_state(s) == 'on' and ' on' or ((s.missing or OR.set_missing(s)) and ' miss' or ''), A(function() set_sel = s; render() end), set_img(s, false, race),
            fav[s.id] and '&#9733;' or '', C.esc(s.name))
    end
    if #tiles == 0 then tiles[1] = '<div class="lempty">Nothing matches. Clear the search or pick another filter.</div>' end
    local nav = string.format('<div class="onav">%s<span class="dim">page %d / %d &#183; %d sets%s</span>%s</div>',
        btn('&#9664;', function() set_page = math.max(1, set_page - 1); render() end, 'sm'), set_page, pages, #list,
        orn_q ~= '' and (' &#183; "' .. C.esc(orn_q) .. '"') or '',
        btn('&#9654;', function() set_page = math.min(pages, set_page + 1); render() end, 'sm'))
    local s = set_sel
    local btns = {}
    if s and s.missing then
        btns[#btns + 1] = '<span class="wn" style="font-size: 11px;">Not for your race: ' .. C.esc(s.missing) .. '</span> '
    elseif s and OR.set_missing(s) then
        btns[#btns + 1] = '<span class="wn" style="font-size: 11px;">' .. C.esc(s.arch) .. ' is not in your EQ folder: this client does not have that set</span> '
    elseif s then
        btns[#btns + 1] = btn('&#10003;&#160; Apply set', function()
            local okk, info = OR.apply_set(s)
            msg = okk and string.format('%s: %s (saved; comes back after zoning)', s.name, tostring(info)) or ('Could not apply set: ' .. tostring(info))
            render()
        end, 'sm pri')
        btns[#btns + 1] = btn(fav[s.id] and '&#9733; Unfavourite' or '&#9734; Favourite', function() OR.toggle_set_fav(s.id); render() end, 'sm')
    end
    btns[#btns + 1] = btn('Restore all', function() OR.restore_all(); msg = 'All ornaments removed: real gear back'; render() end, 'sm')
    r[#r + 1] = '<div class="owrap"><div class="ogrid">' .. table.concat(tiles) .. '</div><div class="opanel" id="ornsel">' .. set_detail_html(s, race) ..
        '<div class="obtns">' .. table.concat(btns) .. '</div></div></div>'
    r[#r + 1] = '<div class="clr"></div>' .. nav
    r[#r + 1] = row('Auto re-apply', 'Put your saved ornaments back after zoning or a gear change',
        sw(C.cfg.orn.auto ~= false, function() C.cfg.orn.auto = not (C.cfg.orn.auto ~= false); changed(false) end))
    r[#r + 1] = '<div class="dim" style="font-size: 10px; margin: 4px 0px 8px 0px;">Sets come from this client\'s armor tag data for your race and gender (pieces that share one set block and archive). Greyed sets exist only for other races; their preview is another race\'s model. The preview is built from each piece\'s own rendered model. Apply set puts on every slot it has, both sides for pairs; slots it does not have keep what you wear.</div>'
    return r
end
local function orn_point_line()
    if orn_slot == 'sets' then return sets_point_line() end
    local s = OR.SLOT[orn_slot]
    local st = OR.status()
    local parts = {}
    local pts = s.pts
    if orn_slot == 'secondary' then pts = { s.pts[1], OR.SHIELD_PT } end   -- shieldfix: off hand = hand point or shield point
    if OR.previewing() then parts[#parts + 1] = string.format('<span class="ok">Previewing on your character: %d s left</span>', OR.preview_left()) end
    for i, pt in ipairs(pts) do
        local state, p = OR.point_state(pt)
        local w = OR.wanted()[pt]
        local now_tag = p and (p.tag or (p.empty and 'empty') or '?') or 'no point'
        local col = ({ on = 'ok', pending = 'dim', failed = 'wn', nopoint = 'wn', off = 'dim' })[state] or 'dim'
        local txt = ({ on = 'ornament on', pending = 'putting it on...', failed = 'could not load it (gave up until next zone)', nopoint = 'no attach point on this model', off = 'your real gear' })[state] or state
        parts[#parts + 1] = string.format('point %d%s: <span style="color: #ece8fa;">%s</span>%s &#183; <span class="%s">%s</span>',
            pt, p and (' ' .. C.esc(p.name)) or '', C.esc(now_tag), w and (' (saved ' .. C.esc(w) .. ')') or '', col, txt)
    end
    local ok = OR.available()
    local extra = ''
    if ok and st and st.raw then
        if st.disabled then extra = '<br/><span class="wn">Disabled for this session after a fault (see Logs\\rmlui_canvas.log)</span>'
        elseif st.verified ~= 1 then extra = '<br/><span class="wn">Client build not verified: ornaments off</span>'
        elseif st.live ~= 0 then extra = '<br/><span class="dim">Waiting for your character (zoning / char select)</span>' end
    end
    return string.format('<span style="font-size: 11px;">%s</span>%s', table.concat(parts, '<br/>'), extra)
end
local orn_race_seen = false
local function orn_refresh()
    if not (ST and ST.visible and tab == 'orn') then return end
    -- racefix: race re-read every refresh (2 Hz); a change (log in, another character, race readable now) redraws the page
    local rt = tostring(OR.my_race()) .. '|' .. tostring(OR.race_why and OR.race_why() or '')
    if orn_race_seen ~= false and rt ~= orn_race_seen then orn_race_seen = rt; render(); return end
    orn_race_seen = rt
    if OR.available() then OR.poll() end
    ST:rml('ornstat', orn_point_line())
end
local function orn_detail_html(e)
    if not e then return '<div class="opbig opempty"><span class="dim">Click a model on the left to see it large</span></div>' end
    local _, fav = OR.favs()
    local held = OR.SLOT[orn_slot] and OR.SLOT[orn_slot].held
    return string.format('<div class="opbig"><img src="%s"/></div><div class="opname">%s%s</div><div class="opmeta">IT%d%s &#183; %s%s%s</div>',
        orn_img(e.it, true), fav[e.it] and '&#9733; ' or '', C.esc(e.label), e.it, e.pair and (' + IT' .. e.pair) or '', C.esc(e.group),
        held and (OR.is_shield(e) and ' &#183; shield, worn on the arm' or ' &#183; held in the hand') or '',
        e.prt and ' &#183; <span class="ok">has its own particles</span>' or '')
end
local function page_orn()
    local r = {}
    r[#r + 1] = '<div class="sec">ORNAMENTS &#183; <span class="dim">swap the model of your weapons and armor; only you see it, nothing is sent to the server</span></div>'
    local ok, why = OR.available()
    if not ok then
        r[#r + 1] = '<div class="card"><span class="wn" style="font-size: 12px;">Ornaments unavailable</span><br/><span class="dim" style="font-size: 11px;">' .. C.esc(why) .. '. Load the MQ2RmlUi build with ornament support (rml_features 8192), then reopen this tab.</span></div>'
        return r
    end
    local D, derr = OR.data()
    if not D then r[#r + 1] = '<div class="card"><span class="wn">' .. C.esc(derr) .. '</span></div>'; return r end
    OR.poll()
    local s = OR.SLOT[orn_slot]
    local held, arm = {}, {}
    for _, x in ipairs(OR.SLOTS) do (x.held and held or arm)[#(x.held and held or arm) + 1] = { x.id, x.label } end
    local function pick_slot(id) orn_slot = id; orn_page = 1; orn_sel = nil; if OR.SLOT[id] and not OR.SLOT[id].held and orn_kind ~= 'fav' then orn_kind = 'all' end; render() end
    r[#r + 1] = '<div style="margin-bottom: 5px;">' .. seg(held, orn_slot, pick_slot) .. ' ' .. seg(arm, orn_slot, pick_slot) .. ' ' .. seg({ { 'sets', '&#9670; Sets' } }, orn_slot, pick_slot) .. '</div>'
    r[#r + 1] = '<div class="card" id="ornstat">' .. orn_point_line() .. '</div>'
    if orn_slot == 'sets' then return page_sets(r, D) end
    if not s.held then
        if D.race_err then
            r[#r + 1] = '<div class="card"><span class="dim">Armor models are race and gender specific: ' .. C.esc(D.race_err) .. '. Weapons work for everyone.</span></div>'
        else
            r[#r + 1] = race_line(D.race, string.format('%d armor models', D.armor or 0))
        end
    end
    local kinds = (orn_slot == 'primary' and ORN_KINDS_MAIN) or (orn_slot == 'shield' and ORN_KINDS_SHIELD) or (s.held and ORN_KINDS_HELD) or ORN_KINDS_ARM
    local kind_ok = false; for _, k in ipairs(kinds) do if k[1] == orn_kind then kind_ok = true end end
    if not kind_ok then orn_kind = 'all' end
    r[#r + 1] = '<div style="margin-bottom: 5px;">' .. seg(kinds, orn_kind, function(k) orn_kind = k; orn_page = 1; render() end) .. '</div>'
    local list = OR.filter(orn_slot, orn_kind, orn_q)
    local pages = math.max(1, math.ceil(#list / ORN_PER))
    if orn_page > pages then orn_page = pages end
    local _, fav = OR.favs()
    local w = OR.wanted()
    local tiles = {}
    for i = (orn_page - 1) * ORN_PER + 1, math.min(#list, orn_page * ORN_PER) do
        local e = list[i]
        local on = w[OR.SLOT[OR.slot_for(e, orn_slot)].pts[1]] == ('IT' .. e.it)
        tiles[#tiles + 1] = string.format('<div class="otile%s%s"%s><img src="%s"/><span class="ol">%s%s%s</span></div>',
            orn_sel == e and ' sel' or '', on and ' on' or '', A(function() orn_sel = e; render() end), orn_img(e.it),
            fav[e.it] and '&#9733;' or '', e.prt and '&#10022;' or '', C.esc(e.label))
    end
    if #tiles == 0 then tiles[1] = '<div class="lempty">Nothing matches. Clear the search or pick another filter.</div>' end
    local nav = string.format('<div class="onav">%s<span class="dim">page %d / %d &#183; %d models%s</span>%s</div>',
        btn('&#9664;', function() orn_page = math.max(1, orn_page - 1); render() end, 'sm'), orn_page, pages, #list,
        orn_q ~= '' and (' &#183; "' .. C.esc(orn_q) .. '"') or '',
        btn('&#9654;', function() orn_page = math.min(pages, orn_page + 1); render() end, 'sm'))
    local e = orn_sel
    local btns = {}
    if e then
        local to = OR.SLOT[OR.slot_for(e, orn_slot)] or s
        btns[#btns + 1] = btn('&#9654;&#160; Preview', function()       -- live: on your character for 12 s, not saved
            local okp, info = OR.preview(e, orn_slot)
            msg = okp and string.format('Previewing %s on your %s for %d s (Apply keeps it)', e.label, to.label:lower(), math.floor(OR.PREVIEW_MS / 1000)) or ('Could not preview: ' .. tostring(info))
            render()
        end, 'sm')
        btns[#btns + 1] = btn('&#10003;&#160; Apply to ' .. to.label, function()
            local okk, info = OR.apply(e, orn_slot)
            msg = okk and string.format('%s on %s (saved; comes back after zoning)', e.label, to.label) or ('Could not apply: ' .. tostring(info))
            render()
        end, 'sm pri')
        btns[#btns + 1] = btn(fav[e.it] and '&#9733; Unfavourite' or '&#9734; Favourite', function() OR.toggle_fav(e.it); render() end, 'sm')
    end
    btns[#btns + 1] = btn('Restore ' .. s.label, function() OR.restore_slot(orn_slot); msg = s.label .. ': real gear back'; render() end, 'sm')
    btns[#btns + 1] = btn('Restore all', function() OR.restore_all(); msg = 'All ornaments removed: real gear back'; render() end, 'sm')
    btns[#btns + 1] = btn('&#10022; Add particles...', function() tab = 'body'; in_mode = 'nimbus'; M.set_input('Search nimbus', nim_q); msg = 'Pick a nimbus to wear with your ornament'; render() end, 'sm')
    r[#r + 1] = '<div class="owrap"><div class="ogrid">' .. table.concat(tiles) .. '</div><div class="opanel" id="ornsel">' .. orn_detail_html(e) ..
        '<div class="obtns">' .. table.concat(btns) .. '</div></div></div>'
    r[#r + 1] = '<div class="clr"></div>' .. nav
    r[#r + 1] = row('Auto re-apply', 'Put your saved ornaments back after zoning or a gear change',
        sw(C.cfg.orn.auto ~= false, function() C.cfg.orn.auto = not (C.cfg.orn.auto ~= false); changed(false) end))
    r[#r + 1] = row('Keep on stop', 'Leave ornaments on when CombatFX stops (until you zone)',
        sw(C.cfg.orn.keep == true, function() C.cfg.orn.keep = not (C.cfg.orn.keep == true); changed(false) end))
    r[#r + 1] = '<div class="dim" style="font-size: 10px; margin: 4px 0px 8px 0px;">Click a picture to select it. Preview puts it on your character for 12 s; Apply keeps it. Shields always go on your arm. &#10022; = has its own particles.</div>'
    return r
end

-- ---------------------------------------------------------------- f8: Combat+ (who to show, role looks, spell schools, meter + recap)
local ROLE_FIRE = { self = 'crit', group = 'grouphit', incoming = 'incoming', pet = 'pet' }
local function role_card(i, rl)
    local id, label, desc = rl[1], rl[2], rl[3]
    local on = C.cfg.show[id] ~= false
    local mode = C.cfg.rolelook[id] or 'full'
    local mod = FT.ROLE_MOD[mode] or FT.ROLE_MOD.full
    local inner
    if tfx_on() then
        local cid = 'rlv' .. i
        local look = FT.apply_mod(C.cfg.tfx, mod)
        pv_cards[#pv_cards + 1] = { id = cid, look = look, colors = C.cfg.color, custom = { role = id, mod = mod, look = look } }
        inner = string.format('<canvas id="%s" class="thv"></canvas>', cid)
    else
        local k = ({ self = 'melee', group = 'group', incoming = 'incoming', pet = 'pet' })[id]
        local txt = ({ self = '1,234', group = '812', incoming = '-1,234', pet = '412' })[id]
        inner = string.format('<span class="thn" style="left: 20px; top: 14px; font-size: %dpx; color: %s;">%s</span>', math.floor(18 * mod.size), C.cfg.color[k] or '#ffffff', txt)
    end
    local segs = seg(FT.ROLE_LOOKS, mode, function(m) C.cfg.rolelook[id] = m; msg = label .. ': ' .. m .. ' look'; changed(false); FT.force('show.' .. id); SIM.fire(ROLE_FIRE[id]) end)
    return string.format('<div class="rlc%s%s"><div class="thp"%s>%s</div><span class="rln">%s</span><span class="rld">%s</span><div class="rlsw">%s</div><div class="rlseg">%s</div></div>',
        i % 2 == 0 and ' c2' or '', on and '' or ' off', A(function() FT.force('show.' .. id); SIM.fire(ROLE_FIRE[id]); msg = 'Preview: ' .. label end), inner, label,
        C.esc(FT.ROLE_DESC[mode] .. ' · ' .. desc), sw(on, function() C.cfg.show[id] = not on; msg = label .. (on and ' hidden' or ' shown'); changed(false) end), segs)
end
local function school_card(i, sc)
    local preset = FT.SCHOOL_LOOK[sc]
    local inner
    if tfx_on() and TFX.LOOKS[preset] then
        local cid = 'scv' .. i
        pv_cards[#pv_cards + 1] = { id = cid, look = TFX.LOOKS[preset], colors = TFX.COLORS[preset], custom = { school = sc, look = TFX.LOOKS[preset], colors = TFX.COLORS[preset] } }
        inner = string.format('<canvas id="%s" class="thv"></canvas>', cid)
    else
        local c = TFX and TFX.COLORS[preset] or {}
        inner = string.format('<span class="thn" style="left: 16px; top: 12px; font-size: 18px; color: %s;">2,480</span>', c.spell or '#ffffff')
    end
    return string.format('<div class="thc%s"%s><div class="thp">%s</div><span class="thname">%s</span><span class="thsub">%s</span></div>', i % 3 == 0 and ' c3' or '',
        A(function() FT.force('school'); SIM._sc = nil; for j, s2 in ipairs(FT.SCHOOLS) do if s2 == sc then SIM.school_index(j) end end; SIM.fire('school'); msg = 'Preview: ' .. sc .. ' spell look' end),
        inner, sc, C.esc(FT.SCHOOL_DESC[sc] or ''))
end
local function page_combat()
    local cfg, r = C.cfg, {}
    pv_cards = {}
    r[#r + 1] = '<div class="sec">WHO TO SHOW &#183; <span class="dim">switch a source on or off and give it its own look inside the current theme; click a card to preview</span></div>'
    for i, rl in ipairs(FT.ROLES) do r[#r + 1] = role_card(i, rl) end
    r[#r + 1] = '<div class="clr"></div>'
    r[#r + 1] = '<div class="sec">SPELL SCHOOL LOOKS &#183; <span class="dim">uses the damage type in the chat line, or the spell\'s ResistType; melee and unknown types keep the theme</span></div>'
    r[#r + 1] = row('Spell-school looks', 'Fire, cold, poison, disease, magic, chromatic and corruption hits use their own look',
        sw(cfg.school.on, function() cfg.school.on = not cfg.school.on; msg = cfg.school.on and 'Spell-school looks on' or 'Spell-school looks off'; changed(false) end))
    for i, sc in ipairs(FT.SCHOOLS) do r[#r + 1] = school_card(i, sc) end
    r[#r + 1] = '<div class="clr"></div>'
    r[#r + 1] = '<div class="sec">METER &amp; RECAP &#183; <span class="dim">built from your own damage lines: per ability, per second, crits and the biggest hit</span></div>'
    r[#r + 1] = row('In-combat DPS meter', 'Small panel on the left while you fight: DPS, total, crit %, 20 s graph, top ability',
        btn('Preview', function() if not SIM.running then SIM.start('solo') end; msg = 'Practice fight running: watch the meter on the left'; render() end, 'sm') ..
        sw(cfg.fx.livemeter, function() cfg.fx.livemeter = not cfg.fx.livemeter; changed(false) end))
    r[#r + 1] = row('Encounter recap', 'After COMBAT ENDED: top abilities, crit rate, biggest hit, damage-over-time graph',
        btn('Preview', function() SIM.fire('recap'); msg = 'Recap preview on the left'; render() end, 'sm') ..
        sw(cfg.fx.recap, function() cfg.fx.recap = not cfg.fx.recap; changed(false) end))
    pv_pending = tfx_on() and #pv_cards > 0; pv_tries = 0
    return r
end
-- ---------------------------------------------------------------- f8: Alerts (procs, buffs, big heals) + kill / loot moments
local function list_text(v) v = tostring(v or ''); if v == '' then return '<span class="dim">none</span>' end; return C.esc(#v > 38 and (v:sub(1, 36) .. '...') or v) end
local function edit_list(mode, label, cur) in_mode = mode; M.set_input(label, cur or ''); msg = 'Type names separated by ; then press Apply'; render() end
local function page_alerts()
    local cfg, r = C.cfg, {}
    local al = cfg.alerts
    r[#r + 1] = '<div class="sec">ALERTS &#183; <span class="dim">short animated callouts drawn beside your character (never over it)</span></div>'
    local fire = { proc = 'alertproc', buff = 'alertbuff', heal = 'alertheal' }
    for _, a in ipairs(FT.ALERTS) do
        local k = a[1]
        r[#r + 1] = row(a[2], a[3], btn('Preview', function() SIM.fire(fire[k]); msg = 'Preview: ' .. a[2] end, 'sm') .. sw(al[k], function() al[k] = not al[k]; changed(false) end))
    end
    r[#r + 1] = row('Key proc names', 'Shown when one of these appears in a chat line: ' .. list_text(al.procs), btn('Edit', function() edit_list('procs', 'Proc names', al.procs) end, 'sm'))
    r[#r + 1] = row('Buffs to watch', 'Empty = every buff that lasts 60 s or more: ' .. list_text(al.buffs), btn('Edit', function() edit_list('buffs', 'Buff names', al.buffs) end, 'sm'))
    r[#r + 1] = row('Buff warning', 'Alert when a watched buff has this long left',
        stepper(al.buff_s, '%d s', function() al.buff_s = math.max(5, al.buff_s - 5); changed(false) end, function() al.buff_s = math.min(120, al.buff_s + 5); changed(false) end))
    r[#r + 1] = row('Big heal size', 'A heal on you of at least this share of your max HP',
        stepper(al.heal_pct, '%d%%', function() al.heal_pct = math.max(5, al.heal_pct - 5); changed(false) end, function() al.heal_pct = math.min(100, al.heal_pct + 5); changed(false) end))
    local mo = cfg.moments
    r[#r + 1] = '<div class="clr"></div><div class="sec">KILL &amp; LOOT MOMENTS &#183; <span class="dim">a gold flourish above your character with sparks; optional sound</span></div>'
    r[#r + 1] = row('Named kill', 'You slay a mob MQ flags as named (Target.Named when you engaged it)',
        btn('Preview', function() SIM.fire('namedkill') end, 'sm') .. sw(mo.named, function() mo.named = not mo.named; changed(false) end))
    r[#r + 1] = row('Rare / lore drop', 'You loot a LORE item, an item on your list, or one worth the value below',
        btn('Preview', function() SIM.fire('lootrare') end, 'sm') .. sw(mo.loot, function() mo.loot = not mo.loot; changed(false) end))
    r[#r + 1] = row('Items to watch', 'Part of a name; ; between names: ' .. list_text(mo.loots), btn('Edit', function() edit_list('loots', 'Item names', mo.loots) end, 'sm'))
    local VP = { 0, 10, 50, 100, 250, 500, 1000, 5000 }
    local vi = 1; for i2, v in ipairs(VP) do if v == mo.value_pp then vi = i2 end end
    r[#r + 1] = row('Valuable drop', 'Merchant value (FindItem Value) at or above this; Off = only lore and listed items',
        stepper(mo.value_pp > 0 and (mo.value_pp .. ' pp') or 'Off', '%s', function() mo.value_pp = VP[math.max(1, vi - 1)]; changed(false) end, function() mo.value_pp = VP[math.min(#VP, vi + 1)]; changed(false) end))
    local snd_ok, snd_why = PT.sound_file('chimes')
    r[#r + 1] = row('Sound', snd_ok and 'Windows sound via MQ /beep (plays without pausing the game); Preview plays it'
        or ('<span class="wn">Off: ' .. C.esc(snd_why or '') .. '</span>'),
        btn('Preview', function() local ok2 = mo.sound ~= 'off' and FT.play(mo.sound, true); msg = ok2 and ('Sound: ' .. mo.sound) or ('No sound: ' .. tostring(mo.sound == 'off' and 'set to Off' or FT.sound_why)); render() end, 'sm') ..
        seg(FT.SOUNDS, mo.sound, function(v) mo.sound = v; if v ~= 'off' then C.cfg.notify.moment_last = v end; changed(false) end))
    return r
end

-- ---------------------------------------------------------------- f8b: Parses (history, best, compare, group, death, warnings, export) + Loadouts
local PS = require('combatfx.parses')
local LO = require('combatfx.loadout')
local pview, ph_days, ph_q, ph_page, ph_sel, cmp_a, cmp_b = 'hist', 0, '', 1, nil, nil, nil
local lo_sel, lo_role = nil, 'Any'
local FU = require('combatfx.fightui')                                -- fd1: fight detail view
local fd_ref, fd_back = nil, 'hist'                                   -- id of the open fight, or 'live' / 'sim'
FU.bind({ A = function(fn) return A(fn) end, btn = function(...) return btn(...) end, seg = function(...) return seg(...) end, render = function() render() end })
local function open_fight(ref) fd_back = (pview ~= 'fight') and pview or fd_back; fd_ref = ref; FU.reset(); pview = 'fight'; render() end
local function fd_record()
    if fd_ref == 'live' then return PS.live_record() end
    if fd_ref == 'sim' then return PS.last_sim end
    return fd_ref and PS.by_id(fd_ref) or nil
end
local PVIEWS = { { 'hist', 'History' }, { 'best', 'Best' }, { 'cmp', 'Compare' }, { 'group', 'Group' }, { 'death', 'Death' }, { 'warn', 'Warnings' }, { 'export', 'Export' }, { 'set', 'Settings' } }
local function when(t) return os.date('%m-%d %H:%M', t or 0) end
local TLC = { burn = '#ff5a4a', cast = '#8ac8ff', aa = '#d090ff', spell = '#ffb347', proc = '#6aff8a' }
-- the picker preview of one fight: damage mix bar + a one-line timeline strip + the key numbers
local function fight_preview(r, title, open)
    if not r then return '<div class="empty">Pick a fight in the list to see it here</div>' end
    local o, f = r.out or {}, C.fmt
    local tot = 0; for _, k in ipairs({ 'melee', 'spell', 'dot', 'ds', 'pet' }) do tot = tot + ((o[k] or {})[1] or 0) end
    local bar = {}
    for _, kk in ipairs({ { 'melee', '#ffb347' }, { 'spell', '#8ac8ff' }, { 'dot', '#c8a0ff' }, { 'ds', '#6aff8a' }, { 'pet', '#ff8a8a' } }) do
        local v = (o[kk[1]] or {})[1] or 0
        if v > 0 then bar[#bar + 1] = string.format('<div class="fmx" style="width: %.1f%%; background-color: %s;"></div>', v / math.max(1, tot) * 100, kk[2]) end
    end
    local strip = {}
    local maxt = math.max(1, r.secs or 1); for _, e in ipairs(r.tl or {}) do if (e[3] or 0) > maxt then maxt = e[3] end end
    for _, g in ipairs(FT.tl_gaps(r.tl or {}, maxt, tonumber(PS.cfg().gap) or 3)) do
        strip[#strip + 1] = string.format('<div class="ftg" style="left: %.1f%%; width: %.1f%%;"></div>', g[1] / maxt * 100, math.max(0.6, (g[2] - g[1]) / maxt * 100))
    end
    for _, e in ipairs(r.tl or {}) do strip[#strip + 1] = string.format('<div class="ftm" style="left: %.1f%%; background-color: %s;"></div>', math.min(99.4, (e[3] or 0) / maxt * 100), TLC[e[1]] or '#ffffff') end
    local hits = ((o.melee or {})[2] or 0) + ((o.spell or {})[2] or 0) + ((o.dot or {})[2] or 0)
    local crits = ((o.melee or {})[3] or 0) + ((o.spell or {})[3] or 0) + ((o.dot or {})[3] or 0)
    local top = r.abil and r.abil[1]
    local topname = top and ((top[1] == 'Pet' and r.petname and r.petname ~= '') and ('Pet (' .. r.petname .. ')') or top[1])
    return string.format('<div class="fpv%s"%s><span class="fpt">%s</span><span class="fpd">%s</span><span class="fpn">%s dps</span><span class="fps">%s dmg in %ds &#183; your crit %d%% &#183; taken %s &#183; healed %s%s</span><div class="fmix">%s</div><div class="ftl">%s</div><span class="fpk">%s</span></div>',
        open and ' open' or '', open and A(function() open_fight(r.id) end) or '',
        C.esc(title or r.mob or 'fight'), string.format('%s &#183; %s%s', when(r.t), C.esc(r.zone ~= '' and r.zone or '?'), r.label ~= '' and (' &#183; [' .. C.esc(r.label) .. ']') or ''),
        f(r.dps), f((r.you or 0) + (r.pet or 0)), math.floor(r.secs or 0), hits > 0 and math.floor(crits / hits * 100 + 0.5) or 0, f(r.inc or 0), f(r.hout or 0),
        r.died and (' &#183; <span class="wn">died</span>') or '', table.concat(bar), table.concat(strip),
        (top and C.esc(string.format('Top: %s %s · %d uses on the timeline', topname, f(top[2]), #(r.tl or {}))) or ('Timeline: ' .. #(r.tl or {}) .. ' uses')) ..
            (open and ' &#183; <span class="ok">click to open the fight</span>' or ''))
end
local function frow(r, sel)
    return string.format('<div class="prow%s%s"%s><span class="pd">%s</span><span class="pm">%s</span><span class="pz">%s</span><span class="ps">%ds</span><span class="pv2">%s</span>%s</div>',
        sel and ' sel' or '', (r.id == cmp_a or r.id == cmp_b) and ' cmp' or '', A(function() ph_sel = r.id; render() end),
        when(r.t), C.esc(r.mob ~= '' and r.mob or 'fight'), C.esc(r.zone or ''), math.floor(r.secs or 0), C.fmt(r.dps),
        r.label ~= '' and ('<span class="pl">' .. C.esc(r.label) .. '</span>') or '')
end
local function sel_rec() return ph_sel and PS.by_id(ph_sel) or nil end
local function copy(text, what) if PS.copy(text) then msg = what .. ' copied to the clipboard (' .. #text .. ' chars)' else msg = 'Clipboard not available here' end; render() end
local function fight_buttons(r)
    if not r then return '' end
    return '<div class="fbt">' ..
        btn('Open fight', function() open_fight(r.id) end, 'sm pri') ..
        btn('Compare as A', function() cmp_a = r.id; msg = 'Fight A set'; render() end, 'sm') ..
        btn('Compare as B', function() cmp_b = r.id; msg = 'Fight B set'; if cmp_a then pview = 'cmp' end; render() end, 'sm') ..
        btn('Tag setup...', function() in_mode = 'plabel'; M.set_input('Gear / setup tag for this fight', r.label or ''); msg = 'Type a tag (e.g. new bow, burn set) and press Apply'; render() end, 'sm') ..
        btn('Copy EQ line', function() copy(PS.export_eq(r), 'EQ line') end, 'sm') ..
        btn('Copy Discord', function() copy(PS.export_detail(r), 'Discord block') end, 'sm') ..
        btn('Delete', function() PS.delete(r.id); if cmp_a == r.id then cmp_a = nil end; if cmp_b == r.id then cmp_b = nil end; ph_sel = nil; msg = 'Fight removed from the history'; render() end, 'sm') .. '</div>'
end
local function pview_hist(r)
    local DAYS = { { 0, 'All' }, { 1, 'Today' }, { 7, '7 days' }, { 30, '30 days' } }
    r[#r + 1] = row('Filter', 'Type part of a mob, zone or tag below; dates on the right', seg(DAYS, ph_days, function(v) ph_days = v; ph_page = 1; render() end))
    local list = PS.query(ph_q, ph_days)
    if not ph_sel and list[1] then ph_sel = list[1].id end       -- the newest fight previews until you pick one
    local s = sel_rec()
    r[#r + 1] = fight_preview(s, nil, true); r[#r + 1] = fight_buttons(s)
    local q = {}
    local last = PS.last or PS.history()[#PS.history()]
    if last then q[#q + 1] = btn('Open last fight', function() open_fight(last.id) end, 'sm') end
    if E.in_fight and E.in_fight() then q[#q + 1] = btn('Current fight', function() open_fight('live') end, 'sm') end
    if PS.last_sim and PS.last_sim._d then q[#q + 1] = btn('Practice fight', function() open_fight('sim') end, 'sm') end
    if #q > 0 then r[#r + 1] = '<div class="fbt">' .. table.concat(q) .. '</div>' end
    local per = 6
    local pages = math.max(1, math.ceil(#list / per)); ph_page = C.clamp(ph_page, 1, pages)
    r[#r + 1] = string.format('<div class="sec">%d FIGHTS%s &#183; <span class="dim">newest first; click one for its preview</span></div>', #list, ph_q ~= '' and (' MATCHING "' .. C.esc(ph_q) .. '"') or '')
    if #list == 0 then r[#r + 1] = '<div class="empty">No fights yet' .. (ph_q ~= '' and ' for this filter' or ': every fight you finish is saved here (practice fights are not)') .. '</div>' end
    for i = (ph_page - 1) * per + 1, math.min(#list, ph_page * per) do r[#r + 1] = frow(list[i], list[i].id == ph_sel) end
    if pages > 1 then
        r[#r + 1] = string.format('<div class="pgr"><div class="arr%s"%s>&#9664;</div><span id="pg">%d / %d</span><div class="arr%s"%s>&#9654;</div></div>',
            ph_page <= 1 and ' dis' or '', A(function() ph_page = math.max(1, ph_page - 1); render() end), ph_page, pages, ph_page >= pages and ' dis' or '', A(function() ph_page = math.min(pages, ph_page + 1); render() end))
    end
end
local function pview_best(r)
    local b = PS.best(5)
    if not ph_sel and b[1] then ph_sel = b[1].best.id end
    local s = sel_rec()
    r[#r + 1] = fight_preview(s, nil, true); r[#r + 1] = fight_buttons(s)
    r[#r + 1] = '<div class="sec">BEST DPS PER MOB &#183; <span class="dim">fights of 5 s or more; click one to preview it</span></div>'
    if #b == 0 then r[#r + 1] = '<div class="empty">No fights of 5 s or more saved yet</div>' end
    for i = 1, math.min(14, #b) do
        local x = b[i]
        r[#r + 1] = string.format('<div class="prow%s"%s><span class="pd">#%d</span><span class="pm">%s</span><span class="pz">%d fights &#183; best %s</span><span class="ps">%ds</span><span class="pv2">%s</span></div>',
            x.best.id == ph_sel and ' sel' or '', A(function() ph_sel = x.best.id; render() end), i, C.esc(x.mob), x.n, when(x.best.t), math.floor(x.best.secs), C.fmt(x.best.dps))
    end
end
local function pview_cmp(r)
    local a, b = cmp_a and PS.by_id(cmp_a), cmp_b and PS.by_id(cmp_b)
    r[#r + 1] = '<div class="sec">COMPARE TWO FIGHTS &#183; <span class="dim">pick A and B in History or Best; tag each with its gear / setup</span></div>'
    r[#r + 1] = '<div class="cmpw">' .. fight_preview(a, a and ('A: ' .. (a.label ~= '' and ('[' .. a.label .. '] ') or '') .. a.mob) or nil) .. fight_preview(b, b and ('B: ' .. (b.label ~= '' and ('[' .. b.label .. '] ') or '') .. b.mob) or nil) .. '</div>'
    if not (a and b) then r[#r + 1] = '<div class="empty">Set fight A and fight B with the buttons under a fight preview</div>'; return end
    r[#r + 1] = '<div class="crow ch"><span class="c1">Stat</span><span class="c2">A</span><span class="c3">B</span><span class="c4">B vs A</span></div>'
    for _, x in ipairs(PS.compare(a, b)) do
        local fa = x[4] == 'p' and string.format('%.1f%%', x[2]) or (x[4] == 's' and string.format('%ds', math.floor(x[2])) or C.fmt(x[2]))
        local fb = x[4] == 'p' and string.format('%.1f%%', x[3]) or (x[4] == 's' and string.format('%ds', math.floor(x[3])) or C.fmt(x[3]))
        local d = x[5]
        local good = d and (x[6] and -d or d)
        local dd = d and string.format('<span class="%s">%+.0f%%</span>', good > 0.5 and 'ok' or (good < -0.5 and 'wn' or 'dim'), d) or '<span class="dim">-</span>'
        r[#r + 1] = string.format('<div class="crow"><span class="c1">%s</span><span class="c2">%s</span><span class="c3">%s</span><span class="c4">%s</span></div>', x[1], fa, fb, dd)
    end
    r[#r + 1] = '<div class="fbt">' .. btn('Swap A / B', function() cmp_a, cmp_b = cmp_b, cmp_a; render() end, 'sm') .. btn('Clear', function() cmp_a, cmp_b = nil, nil; render() end, 'sm') ..
        btn('Open A', function() open_fight(a.id) end, 'sm') .. btn('Open B', function() open_fight(b.id) end, 'sm') .. '</div>'
    r[#r + 1] = FU.compare_graph(a, b)                                -- fd1: both fights' DPS over time, one graph
end
local function pview_fight(r)
    local rec = fd_record()
    local function back() pview = fd_back or 'hist'; if pview == 'fight' then pview = 'hist' end; render() end
    if not rec then
        r[#r + 1] = '<div class="fbt">' .. btn('&#9664; Back', back, 'sm') .. '</div>'
        r[#r + 1] = '<div class="empty">' .. (fd_ref == 'live' and 'No fight in progress' or (fd_ref == 'sim' and 'No practice fight yet (press a Preview button that plays a fight)' or 'That fight is no longer in the history')) .. '</div>'
        return
    end
    local extra = {}
    if rec.id and rec.id > 0 then
        extra[#extra + 1] = btn('Compare as A', function() cmp_a = rec.id; msg = 'Fight A set'; render() end, 'sm')
        extra[#extra + 1] = btn('Compare as B', function() cmp_b = rec.id; msg = 'Fight B set'; if cmp_a then pview = 'cmp' end; render() end, 'sm')
        extra[#extra + 1] = btn('Copy Discord', function() copy(PS.export_detail(rec), 'Discord block') end, 'sm')
    end
    if fd_ref == 'live' then extra[#extra + 1] = btn('Refresh', function() render() end, 'sm') end
    FU.page(r, rec, back, table.concat(extra))
end
local function pview_group(r)
    local c = PS.cfg()
    r[#r + 1] = '<div class="sec">GROUP &amp; RAID METER &#183; <span class="dim">ranked from the same chat lines; others only show when EQ prints their hits</span></div>'
    r[#r + 1] = row('Group / raid meter', 'Live ranked panel in a fight (left column, beside you) and a section in the recap',
        btn('Preview', function() SIM.fire('groupmeter'); msg = 'Practice group fight: the meter shows on the left'; render() end, 'sm') ..
        sw(c.group, function() c.group = not c.group; if not c.group then FX.group_meter(nil) end; changed(false) end))
    r[#r + 1] = row('Live panel shows', 'One ranking at a time; the recap shows all three', seg({ { 'dmg', 'Damage' }, { 'heal', 'Healing' }, { 'tank', 'Tanking' } }, c.gmode, function(v) c.gmode = v; changed(false) end))
    local last = PS.last
    local st = last and last.group
    local seen = last and (st and st.others) and 'yes: other players\' hits were in the last fight' or 'no other players\' hits in the last fight'
    r[#r + 1] = row('"Others Hits" chat filter', 'Seen: ' .. seen .. '. In a group with none after 20 s you get a hint', '<span class="pill' .. ((st and st.others) and ' run' or '') .. '">' .. ((st and st.others) and 'ON' or 'not seen') .. '</span>')
    r[#r + 1] = '<div class="note2">EQ only prints other players\' damage when Options &gt; Chat &gt; Filters &gt; "Others Hits" (and "Others Spells" for their nukes) is on. Heals by others need "Others Heals". The filter state is not readable by scripts, so CombatFX checks the lines it actually sees.</div>'
    if last and st and #st.dmg > 0 then
        r[#r + 1] = '<div class="sec">LAST FIGHT &#183; <span class="dim">' .. C.esc(last.mob) .. '</span></div>'
        for i, x in ipairs(st.dmg) do r[#r + 1] = string.format('<div class="lrow"><span class="ln"><span class="lc">%d.</span>%s</span><span class="lv">%s</span></div>', i, C.esc(x[1]), C.fmt(x[2])) end
    end
end
local function pview_death(r)
    local c = PS.cfg()
    r[#r + 1] = '<div class="sec">DEATH RECAP &#183; <span class="dim">on "You have been slain by": the last 10 s of hits, heals and your HP</span></div>'
    r[#r + 1] = row('Death recap card', 'Beside you (left or right column), 15 s; HP sampled every frame (Me.PctHPs)',
        btn('Preview', function() SIM.fire('deathrecap'); msg = 'Death recap preview (practice lines)'; render() end, 'sm') ..
        sw(c.death, function() c.death = not c.death; changed(false) end))
    local d = PS.last_death
    if d then
        r[#r + 1] = '<div class="sec">LAST DEATH &#183; <span class="dim">' .. os.date('%m-%d %H:%M', d.t) .. '</span></div>'
        r[#r + 1] = string.format('<div class="lrow"><span class="ln"><span class="lc">Slain by</span>%s</span><span class="lv">%s taken</span></div>', C.esc(d.by), C.fmt(d.taken))
        for i = 1, math.min(6, #d.hits) do local x = d.hits[i]; r[#r + 1] = string.format('<div class="lrow"><span class="ln"><span class="lc">-%.1fs</span>%s &#183; %s</span><span class="lv">%s</span></div>', x[1], C.esc(x[2]), C.esc(x[3]), C.fmt(x[4])) end
        -- f10: the same 10 s by source and ability, plus what you avoided
        local TKm = package.loaded['combatfx.track']
        if TKm and #d.hits > 0 then
            r[#r + 1] = '<div class="sec">BY SOURCE &#183; <span class="dim">last 10 s</span></div>'
            for _, s2 in ipairs(TKm.death_breakdown(d)) do
                local ab = {}; for j = 1, math.min(3, #s2.ablist) do local a = s2.ablist[j]; ab[#ab + 1] = C.esc(a[1]) .. ' ' .. C.fmt(a[2]) .. ' (' .. a[3] .. ')' end
                r[#r + 1] = string.format('<div class="lrow"><span class="ln"><span class="lc">%d%%</span>%s &#183; <span class="dim">%s</span></span><span class="lv">%s</span></div>', math.floor(s2.share + 0.5), C.esc(s2.who), table.concat(ab, ', '), C.fmt(s2.n))
            end
            local avs = {}; for k2, v2 in pairs(d.av or {}) do avs[#avs + 1] = v2 .. ' ' .. k2 end; table.sort(avs)
            if #avs > 0 or (d.absorbed or 0) > 0 then r[#r + 1] = '<div class="lrow"><span class="ln"><span class="lc">Avoided</span>' .. (#avs > 0 and table.concat(avs, ', ') or 'none') .. '</span><span class="lv">' .. ((d.absorbed or 0) > 0 and ('spellshield ' .. C.fmt(d.absorbed)) or '') .. '</span></div>' end
        end
    else r[#r + 1] = '<div class="empty">No death recorded this session</div>' end
end
local function pview_warn(r)
    local c = PS.cfg()
    r[#r + 1] = '<div class="sec">MOB ABILITY WARNINGS &#183; <span class="dim">learned only from real lines: big hits on you, named abilities, AEs</span></div>'
    r[#r + 1] = row('Warnings', 'Callout beside you when a known mob is engaged or "begins casting" a known ability',
        btn('Preview', function() SIM.fire('mobwarn'); msg = 'Warning preview beside your character'; render() end, 'sm') ..
        sw(c.mobwarn and C.cfg.alerts.mob, function() local on = not (c.mobwarn and C.cfg.alerts.mob); c.mobwarn = on; C.cfg.alerts.mob = on; changed(false) end))
    r[#r + 1] = row('Big hit threshold', 'A single hit of at least this share of your max HP is worth a warning',
        stepper(c.warn_pct, '%d%%', function() c.warn_pct = math.max(5, c.warn_pct - 5); changed(false) end, function() c.warn_pct = math.min(90, c.warn_pct + 5); changed(false) end))
    local list = {}
    for k, m in pairs(PS.mobs()) do list[#list + 1] = m end
    table.sort(list, function(a, b) return (a.maxpct or 0) > (b.maxpct or 0) end)
    r[#r + 1] = string.format('<div class="sec">MOB BOOK &#183; <span class="dim">%d mobs learned; strongest first</span></div>', #list)
    if #list == 0 then r[#r + 1] = '<div class="empty">Nothing learned yet: it fills in as mobs hit you</div>' end
    for i = 1, math.min(12, #list) do
        local m = list[i]
        local ab = {}
        for n, a in pairs(m.ab or {}) do ab[#ab + 1] = { n, a } end
        table.sort(ab, function(x, y) return (x[2].maxpct or 0) > (y[2].maxpct or 0) end)
        local p = {}
        for j = 1, math.min(2, #ab) do p[#p + 1] = string.format('%s %d%%%s', C.esc(ab[j][1]), math.floor(ab[j][2].maxpct or 0), ab[j][2].aoe and ' AE' or '') end
        r[#r + 1] = string.format('<div class="lrow"><span class="ln"><span class="lc">%s</span>%s%s</span><span class="lv">%d%% HP</span></div>', C.esc(m.name or '?'), table.concat(p, ' &#183; '),
            (m.kills or 0) > 0 and string.format(' &#183; <span class="wn">killed you %dx</span>', m.kills) or '', math.floor(m.maxpct or 0))
    end
end
-- ps1: Parses > Settings: every card / popup and every sound with its own switch (combatfx/notify.lua holds the list;
-- each switch is the item's existing key, so the other tabs show the same state). Switches never play a sound.
local NT = require('combatfx.notify')
local function nt_show(it)
    if it.sim then SIM.fire(it.sim); msg = 'Preview: ' .. it.label
    elseif it.tk then local ok = TK.preview(it.tk); msg = ok and ('Preview: ' .. it.label) or ('Preview had no room clear of your character: ' .. it.label) end
    if not NT.cards_master() then msg = msg .. ' (All cards off: nothing shows)' end
    render()
end
local function pview_set(r)
    local cm, sm = NT.cards_master(), NT.sounds_master()
    local c, cn, s, sn = NT.counts()
    r[#r + 1] = string.format('<div class="sec">CARDS &amp; SOUNDS &#183; <span class="dim">%d of %d cards on, %d of %d sounds on &#183; the same switches as on each tab; a switch never plays a sound, Preview does</span></div>', c, cn, s, sn)
    r[#r + 1] = row('All cards off', cm and 'Every card, popup, banner, alert and panel below (numbers and screen effects stay)' or '<span class="wn">On: no cards or popups show; your switches below are kept</span>',
        sw(not cm, function() NT.set_cards_master(not NT.cards_master()); msg = NT.cards_master() and 'Cards back on' or 'All cards off'; changed(false) end))
    r[#r + 1] = row('All sounds off', sm and 'Every alert sound below (Preview still plays)' or '<span class="wn">On: no alert sounds play; Preview still does</span>',
        sw(not sm, function() NT.set_sounds_master(not NT.sounds_master()); msg = NT.sounds_master() and 'Sounds back on' or 'All sounds off'; changed(false) end))
    r[#r + 1] = row('Restore defaults', 'Every card on, kill / loot sounds off (as shipped), named spawn sound Ding, both masters on',
        btn('Restore defaults', function() NT.restore_defaults(); msg = 'Cards and sounds restored to defaults'; changed(false) end, 'sm'))
    for _, sc in ipairs(NT.SECTIONS) do
        r[#r + 1] = string.format('<div class="sec">%s &#183; <span class="dim">%s</span></div>', sc[2], sc[3])
        for _, it in ipairs(NT.ITEMS) do if it.sec == sc[1] then
            local on = it.card.get()
            local ctl = {}
            if it.sim or it.tk then ctl[#ctl + 1] = btn('Show', function() nt_show(it) end, 'sm') end
            ctl[#ctl + 1] = '<span class="nsl">CARD</span>' .. sw(on, function() NT.set_card(it.id, not it.card.get()); changed(false) end)
            if it.sound then
                ctl[#ctl + 1] = '<span class="nsl">SOUND</span>' .. btn('Preview', function()
                    local ok, why = NT.preview_sound(it.id); msg = ok and ('Sound: ' .. why) or ('No sound: ' .. tostring(why)); render() end, 'sm') ..
                    sw(it.sound.get(), function() NT.set_sound(it.id, not it.sound.get()); changed(false) end)
            else ctl[#ctl + 1] = '<span class="nsl nsx">no sound</span>' end
            local d = C.esc(it.desc)
            if it.sound then d = d .. ' &#183; ' .. C.esc(it.sound.name()) end
            if not cm then d = '<span class="wn">All cards off</span> &#183; ' .. d end
            r[#r + 1] = string.format('<div class="nrow%s">%s</div>', on and '' or ' off', row(C.esc(it.label), d, table.concat(ctl)))
        end end
    end
    r[#r + 1] = '<div class="note2">Saved per character in combatfx_&lt;server&gt;_&lt;char&gt;.ini. Turning a card off only hides it: the fight is still parsed, saved and shown in History. Sound picks: Alerts &gt; Kill &amp; loot moments (one sound for both moments) and Tracking &gt; Spawns.</div>'
end
local function pview_export(r)
    local c = PS.cfg()
    local last = sel_rec() or PS.last
    r[#r + 1] = '<div class="sec">EXPORT &#183; <span class="dim">' .. (last and ('fight: ' .. C.esc(last.mob) .. ' &#183; ' .. when(last.t)) or 'no fight yet') .. ' (pick another in History)</span></div>'
    if last then
        local eq, dt = PS.export_eq(last), PS.export_detail(last)
        r[#r + 1] = row('EQ chat line', string.format('%d / %d characters, plain ASCII (EQ\'s chat box limit)', #eq, PS.EQ_MAX), btn('Copy', function() copy(eq, 'EQ line') end, 'sm pri'))
        r[#r + 1] = '<div class="xpv">' .. C.esc(eq) .. '</div>'
        r[#r + 1] = row('Discord / forum block', 'Multi-line summary in a code block', btn('Copy', function() copy(dt, 'Discord block') end, 'sm pri'))
        local lines = {}; for l in dt:gmatch('[^\n]+') do lines[#lines + 1] = C.esc(l) end
        r[#r + 1] = '<div class="xpv big">' .. table.concat(lines, '<br/>') .. '</div>'
    end
    r[#r + 1] = '<div class="sec">TIMELINE &amp; HISTORY</div>'
    r[#r + 1] = row('Spell timeline in the recap', 'Casts, AAs, burns, spell damage and procs over the fight, gaps shaded',
        btn('Preview', function() SIM.fire('tlrecap'); msg = 'Recap with timeline (practice lines)'; render() end, 'sm') .. sw(c.tl ~= false, function() c.tl = not (c.tl ~= false); changed(false) end))
    r[#r + 1] = row('Gap length', 'Stretches with no cast / AA / burn this long are marked',
        stepper(c.gap, '%d s', function() c.gap = math.max(1, c.gap - 1); changed(false) end, function() c.gap = math.min(15, c.gap + 1); changed(false) end))
    r[#r + 1] = row('Burn names', 'Part of a name; ; between names: ' .. list_text(c.burns), btn('Edit', function() edit_list('burns', 'Burn names (AAs, discs, clickies)', c.burns) end, 'sm'))
    r[#r + 1] = row('Fights kept', 'Oldest drop off first (file: config\\combatfx_parses_&lt;server&gt;_&lt;char&gt;.txt)',
        stepper(c.keep, '%d', function() c.keep = math.max(50, c.keep - 50); changed(false) end, function() c.keep = math.min(2000, c.keep + 50); changed(false) end))
    r[#r + 1] = row('Fights with detail', 'Newest fights keep graphs, tables and the event log (file: config\\combatfx_fights_&lt;server&gt;_&lt;char&gt;.txt, up to about 100 KB a fight)',
        stepper(PS.dkeep(), '%d', function() c.dkeep = math.max(10, PS.dkeep() - 10); changed(false) end, function() c.dkeep = math.min(300, PS.dkeep() + 10); changed(false) end))
    r[#r + 1] = row('Save fights', 'Every finished fight goes into the history', sw(c.on, function() c.on = not c.on; changed(false) end))
end
local function page_parses()
    local r = {}
    r[#r + 1] = '<div class="pseg">' .. seg(PVIEWS, pview, function(v) pview = v; if v == 'hist' then in_mode = 'pq'; M.set_input('Search fights (mob, zone or tag)', ph_q) end; render() end) .. '</div>'
    if pview == 'hist' then pview_hist(r) elseif pview == 'best' then pview_best(r) elseif pview == 'cmp' then pview_cmp(r) elseif pview == 'group' then pview_group(r)
    elseif pview == 'death' then pview_death(r) elseif pview == 'warn' then pview_warn(r) elseif pview == 'fight' then pview_fight(r)
    elseif pview == 'set' then pview_set(r) else pview_export(r) end
    return r
end

-- ---------------------------------------------------------------- f10: Tracking (buffs / DoTs, pet, cast warnings, taken, resists, mana, session, named)
local TK = require('combatfx.track')
local TU = require('combatfx.trackui')
local tview = 'dots'
local TVIEWS = { { 'dots', 'Buffs &amp; DoTs' }, { 'pet', 'Pet / Feign' }, { 'cast', 'Cast warnings' }, { 'taken', 'Taken' }, { 'res', 'Resists' }, { 'eff', 'Mana' }, { 'sess', 'Session' }, { 'spawn', 'Named' } }
local function F_sound_why() return FT.sound_why or 'sound file not found' end
local function tk_prev(kind, label) return btn('Preview', function() local ok = TK.preview(kind); msg = ok and ('Preview: ' .. label) or ('Preview had no room clear of your character: ' .. label); render() end, 'sm') end
local function tk_sw(tbl, key, after) return sw(tbl[key], function() tbl[key] = not tbl[key]; if after then after() end; changed(false) end) end
local function tview_dots(r, c)
    r[#r + 1] = '<div class="sec">BUFFS &amp; DOTS &#183; <span class="dim">your buffs fading and your DoTs / debuffs on the target, with a warning before they drop</span></div>'
    r[#r + 1] = row('Tracking panel', 'Small card beside you (right column, else left under the group meter; never over you)',
        tk_prev('panel', 'Tracking panel') .. seg({ { 'combat', 'In combat' }, { 'always', 'Always' }, { 'off', 'Off' } }, c.panel, function(v) c.panel = v; if v == 'off' then FX.track_panel(nil) end; changed(false) end))
    r[#r + 1] = row('Buffs shown', 'Soonest to fade first; buffs of 60 s or more that are inside 4x the buff warning time',
        stepper(c.pbuffs, '%d', function() c.pbuffs = math.max(0, c.pbuffs - 1); changed(false) end, function() c.pbuffs = math.min(8, c.pbuffs + 1); changed(false) end))
    r[#r + 1] = row('Your DoTs', 'Timers from the target\'s buff window (Target.MyBuffDuration); ~ = estimated from the spell\'s duration', tk_sw(c, 'dots'))
    r[#r + 1] = row('DoT about to drop', 'Alert beside you this many seconds before one of your DoTs ends',
        tk_prev('dot', 'DoT warning') .. stepper(c.dot_warn, '%d s', function() c.dot_warn = math.max(1, c.dot_warn - 1); changed(false) end, function() c.dot_warn = math.min(20, c.dot_warn + 1); changed(false) end) .. sw(C.cfg.alerts.dot, function() C.cfg.alerts.dot = not C.cfg.alerts.dot; changed(false) end))
    local now = C.now()
    r[#r + 1] = '<div class="sec">RUNNING NOW</div>' .. TU.dots_html(TK.dot_rows(now))
    if #TK.buffs > 0 then
        r[#r + 1] = '<div class="sec">YOUR BUFFS &#183; <span class="dim">soonest first</span></div>'
        for i = 1, math.min(8, #TK.buffs) do local b = TK.buffs[i]; r[#r + 1] = TU.lrow('<span class="lc">' .. TU.secs_txt(b.left) .. '</span>' .. C.esc(b.name), b.song and 'song' or '') end
    end
    r[#r + 1] = '<div class="note2">Buff timers are read only while the panel or this page shows them (Me.Buff, once a second). Spell durations: ' .. C.esc(TK.DB.state == 'ready' and ('spells_us.txt, ' .. TK.DB.n .. ' spells') or (TK.DB.state == 'loading' and 'reading spells_us.txt...' or ('MQ Spell TLO' .. (TK.DB.why and (' (' .. TK.DB.why .. ')') or '')))) .. '</div>'
end
local function tview_pet(r, c)
    r[#r + 1] = '<div class="sec">PET &amp; NECRO &#183; <span class="dim">pet damage split, DoT ticks per spell, DoTs still running, feign death</span></div>'
    r[#r + 1] = row('Pet split in the panel', 'Pet melee vs spells / procs this fight and its share of your damage', tk_sw(c, 'pet'))
    r[#r + 1] = row('Feign death flash', 'Green when Me.Feigning turns on after your feign; red on "has fallen to the ground" or still standing 2.5 s after the cast',
        tk_prev('fd_ok', 'Feign death') .. tk_prev('fd_fail', 'Feign failed') .. sw(c.fd and C.cfg.alerts.fd, function() local on = not (c.fd and C.cfg.alerts.fd); c.fd = on; C.cfg.alerts.fd = on; changed(false) end))
    local F = TK.fight() or TK.last_fight()
    r[#r + 1] = '<div class="sec">' .. (TK.fight() and 'THIS FIGHT' or 'LAST FIGHT') .. ' &#183; <span class="dim">DoT ticks by spell</span></div>' .. TU.dotsplit_html(F and F.dots)
    if F then
        local p = F.pet
        local tot = p.melee[1] + p.spell[1] + p.ds[1]
        r[#r + 1] = TU.lrow('<span class="lc">Pet</span>melee ' .. C.fmt(p.melee[1]) .. ' (' .. p.melee[2] .. ' hits, max ' .. C.fmt(p.melee[4]) .. ') &#183; spells ' .. C.fmt(p.spell[1]) .. ' &#183; DS ' .. C.fmt(p.ds[1]), C.fmt(tot) .. ' &#183; ' .. p.miss .. ' misses')
    end
    r[#r + 1] = '<div class="sec">DOTS STILL RUNNING</div>' .. TU.dots_html(TK.dot_rows(C.now()))
    local fl = TK.fd.last
    if fl then r[#r + 1] = TU.lrow('<span class="lc ' .. (fl.ok and 'ok' or 'wn') .. '">' .. (fl.ok and 'Feigned' or 'Failed') .. '</span>' .. C.esc(fl.sub or ''), os.date('%H:%M:%S', os.time() - math.floor((C.now() - fl.t) / 1000))) end
end
local function tview_cast(r, c)
    r[#r + 1] = '<div class="sec">MOB CAST WARNINGS &#183; <span class="dim">a flashing label above the mob (never over you) when it casts or does something on your list</span></div>'
    r[#r + 1] = row('Cast / action warnings', 'From "&lt;mob&gt; begins to cast a spell. (X)", Gates, ENRAGED, RAMPAGE, FLURRY on you or your group, berserker frenzy',
        tk_prev('cast', 'Cast warning above the mob') .. sw(c.castwarn and C.cfg.alerts.cast, function() local on = not (c.castwarn and C.cfg.alerts.cast); c.castwarn = on; C.cfg.alerts.cast = on; changed(false) end))
    r[#r + 1] = row('Danger list', 'Part of a spell name or action; AE = an ability the mob book saw hit two people: ' .. list_text(c.cast_list), btn('Edit', function() edit_list('castl', 'Danger list (spells / actions)', c.cast_list) end, 'sm'))
    r[#r + 1] = row('Above the mob', 'Off = always in the alert slots beside you. On screen only; falls back beside you when the mob is off screen or behind you', tk_sw(c, 'cast_world'))
    local w = TK._last_warn
    if w then r[#r + 1] = TU.lrow('<span class="lc">Last</span>' .. C.esc(w.title) .. ' &#183; ' .. C.esc(w.who), os.date('%H:%M:%S', os.time() - math.floor((C.now() - w.t) / 1000))) end
    r[#r + 1] = '<div class="note2">Rampage / flurry / frenzy repeat every few seconds in a fight, so each mob warns once per 15 s for those; casts once per 4 s. Learned big-hit warnings stay in Parses &gt; Warnings.</div>'
end
local function tview_taken(r, c)
    local T = TK.fight() or TK.last_fight()
    local rows = TK.taken_rows(T, 8)
    r[#r + 1] = '<div class="sec">DAMAGE TAKEN &#183; <span class="dim">' .. (TK.fight() and 'this fight' or (T and 'last fight' or 'no fight yet')) .. ' &#183; by source, top abilities, what you avoided</span></div>'
    if T then r[#r + 1] = TU.taken_html(rows, T) else r[#r + 1] = '<div class="empty">No fight yet</div>' end
    local S2 = TK.session()
    r[#r + 1] = '<div class="sec">THIS SESSION</div>' .. TU.taken_html((TK.taken_rows(S2.taken, 6)), S2.taken)
    r[#r + 1] = '<div class="note2">EQ\'s chat lines carry the damage that landed, misses / dodges / parries / blocks / ripostes, "magical skin absorbs the blow" (rune) and the spellshield amount. The amount your AC mitigated is not printed anywhere, so it is not shown.</div>'
end
local function tview_res(r, c)
    r[#r + 1] = '<div class="sec">RESISTS BY SPELL &#183; <span class="dim">a resist line vs a landed hit / DoT tick from the same cast</span></div>' .. TU.resist_html(TK.res_rows('sp', 10), 'sp')
    r[#r + 1] = '<div class="sec">RESISTS BY MOB</div>' .. TU.resist_html(TK.res_rows('mob', 8), 'mob')
    r[#r + 1] = row('Reset resist book', 'Kept across sessions in config\\combatfx_resists_&lt;server&gt;_&lt;char&gt;.txt', btn('Reset', function() local S2 = TK.session(); S2.res = { sp = {}, mob = {} }; pcall(TK.res_save); msg = 'Resist book cleared'; render() end, 'sm'))
end
local function tview_eff(r, c)
    r[#r + 1] = '<div class="sec">DAMAGE PER MANA &#183; <span class="dim">this session; finished casts only (interrupts / fizzles not counted)</span></div>' .. TU.eff_html(TK.eff_rows())
    r[#r + 1] = '<div class="note2">Mana cost: ' .. C.esc(TK.DB.state == 'ready' and 'client spells_us.txt' or 'MQ Spell TLO (spells_us.txt not read yet)') .. '. Spell hits with no name (TOB "You hit X for N points of non-melee damage") count for the cast that just finished. Endurance abilities show damage per endurance from the Spell TLO.</div>'
    r[#r + 1] = row('Reset', 'Start the mana numbers over', btn('Reset', function() TK.session().eff = {}; msg = 'Efficiency cleared'; render() end, 'sm'))
end
local function tview_sess(r, c)
    r[#r + 1] = '<div class="sec">SESSION &#183; <span class="dim">since CombatFX started or Reset</span></div>' .. TU.session_html(TK.session_rates(C.now()))
    r[#r + 1] = row('Reset session', 'Kills, XP, AA, coin and loot rates start over (the resist book is kept)', btn('Reset', function() local res = TK.session().res; TK.reset_session(C.now()); TK.session().res = res; msg = 'Session reset'; render() end, 'sm'))
    r[#r + 1] = '<div class="note2">XP from the server\'s own "You have gained (N) experience! (x%)" lines, else Me.PctExp; AA from Me.PctAAExp; coin from "You receive ... from the corpse" and "as your split"; loot value from the XP &amp; Loot window.</div>'
end
local function tview_spawn(r, c)
    r[#r + 1] = '<div class="sec">NAMED / RARE SPAWNS &#183; <span class="dim">a ping and a gold glow above the mob when one pops nearby</span></div>'
    r[#r + 1] = row('Spawn alerts', 'Checked once a second; zoning in gives one summary instead of a wall of alerts',
        tk_prev('spawn', 'Named spawn') .. sw(c.spawn and C.cfg.alerts.spawn, function() local on = not (c.spawn and C.cfg.alerts.spawn); c.spawn = on; C.cfg.alerts.spawn = on; changed(false) end))
    r[#r + 1] = row('Any named', 'MQ\'s own named test (NearestSpawn "npc named": targetable, not a merchant / banker / GM)', tk_sw(c, 'spawn_named'))
    r[#r + 1] = row('Watch list', 'Part of a name; ; between names: ' .. list_text(c.spawn_list), btn('Edit', function() edit_list('spawnl', 'Spawn names to watch', c.spawn_list) end, 'sm'))
    r[#r + 1] = row('Ignore list', 'Never alert for these: ' .. list_text(c.spawn_ignore), btn('Edit', function() edit_list('spawni', 'Spawn names to ignore', c.spawn_ignore) end, 'sm'))
    r[#r + 1] = row('Above the mob', 'Label + DX11 glow at the mob when it is on screen; else beside you', tk_sw(c, 'spawn_world'))
    r[#r + 1] = row('Sound', 'Played with the alert (Windows sound via MQ /beep); Preview plays it',
        btn('Preview', function() local ok2 = c.spawn_sound ~= 'off' and FT.play(c.spawn_sound, true); msg = ok2 and ('Sound: ' .. c.spawn_sound) or ('No sound: ' .. tostring(c.spawn_sound == 'off' and 'set to Off' or F_sound_why())); render() end, 'sm') ..
        seg(FT.SOUNDS, c.spawn_sound, function(v) c.spawn_sound = v; if v ~= 'off' then C.cfg.notify.spawn_last = v end; changed(false) end))
    local ls = TK.last_spawn
    if ls then for i = 1, math.min(4, #ls.new) do local s2 = ls.new[i]; r[#r + 1] = TU.lrow('<span class="lc">' .. (s2.listed and 'Listed' or 'Named') .. '</span>' .. C.esc(s2.name), 'lvl ' .. (s2.lvl or 0) .. ' &#183; ' .. math.floor(s2.dist or 0) .. ' ft') end end
end
local function page_tracking()
    local c, r = TK.cfg(), {}
    r[#r + 1] = '<div class="pseg">' .. seg(TVIEWS, tview, function(v) tview = v
        if v == 'cast' then in_mode = 'castl'; M.set_input('Danger list (spells / actions)', TK.cfg().cast_list) elseif v == 'spawn' then in_mode = 'spawnl'; M.set_input('Spawn names to watch', TK.cfg().spawn_list) end
        render() end) .. '</div>'
    local hint = TK.log_hint()
    if hint and c.loghint then r[#r + 1] = '<div class="note2 wn">' .. C.esc(hint) .. '</div>' end
    if tview == 'dots' then tview_dots(r, c) elseif tview == 'pet' then tview_pet(r, c) elseif tview == 'cast' then tview_cast(r, c) elseif tview == 'taken' then tview_taken(r, c)
    elseif tview == 'res' then tview_res(r, c) elseif tview == 'eff' then tview_eff(r, c) elseif tview == 'sess' then tview_sess(r, c) else tview_spawn(r, c) end
    r[#r + 1] = row('Tracking', 'Everything on this tab (per character)', sw(c.on, function() c.on = not c.on; if not c.on then FX.track_panel(nil) end; changed(false) end))
    return r
end
M._tracking_open = function() return tab == 'tracking' end
-- loadouts: cards with a generated thumbnail (theme lane colours + what is worn), a preview panel with the differences
local function lo_thumb(e)
    local s = LO.summary(e)
    local sw2 = {}
    for i, c in ipairs(s.colors) do sw2[#sw2 + 1] = string.format('<div class="los" style="left: %dpx; background-color: %s;"></div>', 6 + (i - 1) * 15, C.esc(c)) end
    return string.format('<div class="lot">%s<span class="lotn">%s</span><span class="lotl">%s</span><span class="lotl l2">%s</span></div>', table.concat(sw2), C.esc(s.theme),
        C.esc(s.lines[2]), C.esc(s.lines[3]))
end
local function page_lo()
    local r = {}
    local L = LO.list()
    local cur = LO.current()
    r[#r + 1] = '<div class="sec">LOADOUTS &#183; <span class="dim">the whole setup in one click: look, auras, ornaments + materials, Body FX, alerts, filters</span></div>'
    r[#r + 1] = row('Save current setup', 'Type a name below and press Apply; role:', seg({ { 'Any', 'Any' }, { 'Tank', 'Tank' }, { 'Healer', 'Healer' }, { 'Melee DPS', 'Melee' }, { 'Caster', 'Caster' }, { 'Support', 'Support' } }, lo_role, function(v) lo_role = v; render() end))
    if #L.order == 0 then r[#r + 1] = '<div class="empty">No loadouts yet: name the current setup below and press Apply</div>' end
    for i, n in ipairs(L.order) do
        local e = L.by[n]
        r[#r + 1] = string.format('<div class="thc lo%s%s"%s><div class="thp">%s</div><span class="thname">%s</span>%s<span class="thsub">%s</span></div>', i % 3 == 0 and ' c3' or '', lo_sel == n and ' sel' or '',
            A(function() lo_sel = n; render() end), lo_thumb(e), C.esc(n), (n == cur) and '<span class="thtag">ON</span>' or string.format('<span class="thtag rl2">%s</span>', C.esc(e.role)), C.esc(e.role .. ' · ' .. os.date('%m-%d %H:%M', e.t)))
    end
    r[#r + 1] = '<div class="clr"></div>'
    local e = lo_sel and L.by[lo_sel]
    if e then
        local s = LO.summary(e)
        local d = LO.diff(e)
        local dl = {}
        for i = 1, math.min(6, #d) do dl[#dl + 1] = string.format('%s: %s &#8594; %s', C.esc(d[i][1]), C.esc(tostring(d[i][2] or '-')):sub(1, 18), C.esc(tostring(d[i][3])):sub(1, 18)) end
        r[#r + 1] = string.format('<div class="card"><div class="sec">%s &#183; <span class="dim">%s</span></div><div class="lol">%s</div><div class="lol dim">%s</div>%s</div>',
            C.esc(lo_sel), C.esc(e.role), table.concat({ C.esc(s.lines[1]), C.esc(s.lines[2]), C.esc(s.lines[3]), C.esc(s.lines[4]) }, '<br/>'),
            #d == 0 and 'Same as what you have on now' or (string.format('%d settings change: ', #d) .. table.concat(dl, ' &#183; ') .. (#d > 6 and ' ...' or '')),
            '<div class="fbt">' .. btn('Wear it', function() local ok, m = LO.apply(lo_sel); msg = m; changed(); end, 'sm go') ..
            btn('Update from current', function() local ok, m = LO.save(lo_sel, e.role); msg = ok and ('Updated ' .. lo_sel) or m; render() end, 'sm') ..
            btn('Role: ' .. e.role, function() local i2 = 1; for j, x in ipairs(LO.ROLES) do if x == e.role then i2 = j end end; LO.set_role(lo_sel, LO.ROLES[i2 % #LO.ROLES + 1]); render() end, 'sm') ..
            btn('Delete', function() LO.delete(lo_sel); msg = 'Deleted loadout ' .. lo_sel; lo_sel = nil; render() end, 'sm') .. '</div>')
    end
    r[#r + 1] = '<div class="note2">File: config\\combatfx_loadouts_&lt;server&gt;_&lt;char&gt;.ini. Window positions, records and the parse history are not part of a loadout. Quick switch: right-click the FX medallion.</div>'
    return r
end

-- t494: two-level nav. Top row = 3 groups; second row = only that group's pages (the others are in the markup, hidden,
-- so every page keeps its id / handler). Last group + last page per group remembered in C.cfg.nav.
local PAGES = { { 'styles', 'Proc FX', page_styles }, { 'aura', 'Aura', page_aura }, { 'trail', 'Trail', page_trail }, { 'body', 'Body FX', page_body }, { 'orn', 'Ornaments', page_orn },
    { 'events', 'Colours', page_events }, { 'combat', 'Combat+', page_combat }, { 'text', 'Text &amp; Motion', page_text }, { 'fx', 'Effects', page_fx }, { 'themes', 'Themes', page_themes }, { 'alerts', 'Alerts', page_alerts }, { 'sim', 'Simulator', page_sim }, { 'track', 'XP &amp; Loot', page_track }, { 'tracking', 'Tracking', page_tracking }, { 'lo', 'Loadouts', page_lo },
    { 'mark', 'Markers', page_mark }, { 'parses', 'Parses', page_parses } }
NP.GROUPS = { { 'vis', 'Visuals', { 'styles', 'aura', 'trail', 'body', 'orn' } },
    { 'set', 'Settings/UI', { 'events', 'combat', 'text', 'fx', 'themes', 'alerts', 'sim', 'track', 'tracking', 'lo' } },
    { 'zm', 'Markers &amp; Parses', { 'mark', 'parses' } } }
function NP.group_of(id)
    for _, g in ipairs(NP.GROUPS) do for _, x in ipairs(g[3]) do if x == id then return g end end end
    return NP.GROUPS[1]
end
function NP.nav()
    C.cfg.nav = type(C.cfg.nav) == 'table' and C.cfg.nav or {}
    return C.cfg.nav
end
-- open a page (same side effects the old tab buttons had); remembers it as the group's page
function NP.open_tab(id, init)
    tab = id
    if id == 'themes' then saved_cache = nil; in_mode = 'theme'; M.set_input('Save current as', C.cfg.theme ~= 'Custom' and C.cfg.theme or '') elseif id == 'events' then in_mode = 'hex'; M.set_input('Colour for ' .. C.KIND_LABEL[sel_kind], C.cfg.color[sel_kind]) elseif id == 'mark' then in_mode = 'marker'; M.set_input('NPC name to mark', ''); NP.mk_scan(); NP.mk_next = C.now() + 3000 elseif id == 'body' then in_mode = 'nimbus'; M.set_input('Search nimbus', nim_q) elseif id == 'orn' then in_mode = 'orn'; M.set_input('Search ornaments', orn_q) elseif id == 'alerts' then in_mode = 'procs'; M.set_input('Proc names', C.cfg.alerts.procs) elseif id == 'parses' then in_mode = 'pq'; M.set_input('Search fights (mob, zone or tag)', ph_q) elseif id == 'tracking' then in_mode = 'castl'; M.set_input('Danger list (spells / actions)', TK.cfg().cast_list) elseif id == 'styles' then NP.input() elseif id == 'lo' then in_mode = 'loname'; M.set_input('Save current setup as', lo_sel or '') end
    local g, n = NP.group_of(id), NP.nav()
    if n.top ~= g[1] or n[g[1]] ~= id then n.top, n[g[1]] = g[1], id; if not init then C.save_cfg() end end
    if not init then render() end
end
function NP.nav_init()
    if NP.nav_done then return end
    NP.nav_done = true
    local n, g = NP.nav(), nil
    for _, x in ipairs(NP.GROUPS) do if x[1] == n.top then g = x end end
    g = g or NP.GROUPS[1]
    local id = n[g[1]]
    if NP.group_of(id or '')[1] ~= g[1] or not id then id = g[3][1] end
    NP.open_tab(id, true)
end
function NP.tabs_html()
    local cur, n, t = NP.group_of(tab), NP.nav(), {}
    for _, g in ipairs(NP.GROUPS) do
        t[#t + 1] = string.format('<div class="tab top%s"%s>%s</div>', g == cur and ' sel' or '', A(function()
            local id = n[g[1]]; if not id or NP.group_of(id) ~= g then id = g[3][1] end
            NP.open_tab(id)
        end), g[2])
    end
    for _, p in ipairs(PAGES) do
        t[#t + 1] = string.format('<div class="tab sub%s%s"%s>%s</div>', tab == p[1] and ' sel' or '', NP.group_of(p[1]) ~= cur and ' hid' or '', A(function() NP.open_tab(p[1]) end), p[2])
    end
    local rows = math.ceil(#cur[3] / 5)                       -- 5 per row: Settings/UI (10) = 2 rows, never overlapping
    local h = 32 + rows * 28
    ST:style('tabs', 'height', h .. 'px'); ST:style('spage', 'top', (78 + h) .. 'px')
    return table.concat(t)
end

render = function()
    if not ST or not ST.visible then return end
    acts, nact = {}, 0
    NP.nav_init()
    ST:rml('tabs', NP.tabs_html())
    local inp = tab == 'events' or tab == 'themes' or tab == 'mark' or tab == 'body' or tab == 'orn' or tab == 'alerts' or tab == 'lo' or (tab == 'parses' and (pview == 'hist' or in_mode == 'plabel' or in_mode == 'burns')) or (tab == 'tracking' and (tview == 'cast' or tview == 'spawn'))
        or (tab == 'styles' and NP.view ~= 'gems')                                   -- Proc FX effect search
    ST:class('body', 'inp', inp)
    local body
    for _, p in ipairs(PAGES) do if p[1] == tab then body = p[3]() end end
    ST:rml('spage', table.concat(body or {}))
    ST:style('inrow', 'display', inp and 'block' or 'none')   -- t492: only the tab that owns it (t472 forced 'block' on every tab: Proc names everywhere)
    ST:text('smsg', msg ~= '' and msg or 'Changes save automatically for this character')
    ST:rml('who', C.esc(C.CHAR) .. ' &#183; ' .. C.esc(C.cfg.theme))
    ST:text('status', SIM.active() and 'Simulating' or (C.cfg.master and 'Effects on' or 'Effects off'))
    ST:class('fdot', 'live', C.cfg.master and not SIM.active()); ST:class('fdot', 'sim', SIM.active())
end
M.render = function() render() end

function M.set_input(label, value)
    ST:text('inlab', label)
    ST.cache['ainp|value'] = nil
    ST:attr('inp', 'value', value or '')
    ST:text('inhint', in_mode == 'hex' and 'Format #rrggbb, e.g. #ffd040' or (in_mode == 'nimbus' and 'Part of a name or id, e.g. lava; filters as you type' or (in_mode == 'orn' and 'Name, set or IT number, e.g. epic or 60003' or (in_mode == 'import' and 'Starts with CFX1: (checked, never run)' or ((in_mode == 'procs' or in_mode == 'buffs' or in_mode == 'loots' or in_mode == 'burns' or in_mode == 'castl' or in_mode == 'spawnl' or in_mode == 'spawni') and 'Names separated by ;  e.g. Spirit of Wolf; Clarity' or (in_mode == 'pq' and 'Filters as you type, e.g. warlord or ssra' or (in_mode == 'plabel' and 'Up to 40 characters, e.g. new bow' or 'Letters and numbers')))))))
end
function M.set_color(kind, c)
    c = tostring(c or ''):gsub('%s', '')
    if not c:match('^#%x%x%x%x%x%x$') and not c:match('^#%x%x%x%x%x%x%x%x$') then
        if c:match('^%x%x%x%x%x%x$') then c = '#' .. c else msg = 'That is not a colour code: ' .. c .. ' (use #rrggbb)'; render(); return end
    end
    C.cfg.color[kind] = c:lower(); C.cfg.theme = 'Custom'
    msg = string.format('%s is now %s', C.KIND_LABEL[kind], c)
    changed()
    M.set_input('Colour for ' .. C.KIND_LABEL[kind], c)
    SIM.preview(kind)                                             -- live preview of the edited colour
end
local function apply_input()
    local v = ST:value('inp')
    if in_mode == 'npq' then return NP.apply(v) end      -- t470: Proc FX search / add a spell
    if in_mode == 'theme' then
        local ok, r = C.save_theme(v); msg = ok and ('Saved theme "' .. r .. '"') or ('Could not save: ' .. r)
        saved_cache = nil; M.set_input('Save current as', ''); render()
    elseif in_mode == 'nimbus' then
        nim_q = tostring(v or ''); render()
    elseif in_mode == 'orn' then
        orn_q = tostring(v or ''); orn_page = 1; set_page = 1; render()
    elseif in_mode == 'marker' then
        add_marker_rule(v, add_match)
        M.set_input('NPC name to mark', '')
    elseif in_mode == 'import' then
        local ok, m = C.import_share(v); msg = m; saved_cache = nil
        if ok then in_mode = 'theme'; M.set_input('Save current as', C.cfg.theme or '') end
        changed()
    elseif in_mode == 'pq' then
        ph_q = tostring(v or ''); ph_page = 1; render()
    elseif in_mode == 'plabel' then
        if ph_sel and PS.set_label(ph_sel, v) then msg = 'Fight tagged: ' .. tostring(v) else msg = 'Pick a fight first' end
        in_mode = 'pq'; M.set_input('Search fights (mob, zone or tag)', ph_q); render()
    elseif in_mode == 'burns' then
        local clean = tostring(v or ''):gsub('[%c=%[%]]', ''):sub(1, 300)
        PS.cfg().burns = clean; FT.set_burns(clean); msg = 'Burn names: ' .. (clean ~= '' and clean or 'none'); in_mode = 'pq'; M.set_input('Search fights (mob, zone or tag)', ph_q); changed(false)
    elseif in_mode == 'loname' then
        local ok, m = LO.save(v, lo_role); msg = m; if ok then lo_sel = LO.clean_name(v) end; render()
    elseif in_mode == 'castl' or in_mode == 'spawnl' or in_mode == 'spawni' then            -- f10 Tracking lists
        local clean = tostring(v or ''):gsub('[%c=%[%]]', ''):sub(1, 300)
        local key = in_mode == 'castl' and 'cast_list' or (in_mode == 'spawnl' and 'spawn_list' or 'spawn_ignore')
        TK.cfg()[key] = clean; msg = 'Saved list: ' .. (clean ~= '' and clean or 'none'); changed(false)
    elseif in_mode == 'procs' or in_mode == 'buffs' or in_mode == 'loots' then
        local clean = tostring(v or ''):gsub('[%c=%[%]]', ''):sub(1, 300)
        if in_mode == 'loots' then C.cfg.moments.loots = clean else C.cfg.alerts[in_mode] = clean end
        FT.refresh_lists(); msg = 'Saved list: ' .. (clean ~= '' and clean or 'none'); changed(false)
    else M.set_color(sel_kind, v) end
end

-- ---------------------------------------------------------------- menu (launcher right-click)
local MENU_W = 220
local mitems, mopen, mt, mrect = {}, false, 0, { 0, 0, 0, 0 }
local function mclose() if mopen then mopen = false; MN:show(false) end end
local function mshow()
    local cfg = C.cfg
    mitems = {
        { 'Open settings', function() M.toggle_settings(true) end },
        { 'Preview every effect', function() SIM.showcase() end },
        { SIM.running and 'Stop practice fight' or 'Practice fight (solo)', function() if SIM.running then SIM.stop() else SIM.start('solo') end; render() end },
        { sep = true },
        { 'All effects', function() cfg.master = not cfg.master; if not cfg.master then FX.clear() end; changed() end, cfg.master },
        { 'Lite mode', function() cfg.lite = not cfg.lite; changed() end, cfg.lite },
        { 'Particle effects', function() toggle_particles() end, C.particles_on() },
        { 'Combat meter', function() cfg.meter = not cfg.meter; changed(false); M.meter_vis() end, cfg.meter },
        { 'Experience window', function() tog_xp() end, cfg.xp },
        { 'Loot value window', function() tog_loot() end, cfg.loot },
        { sep = true },
    }
    for _, n in ipairs(C.THEME_ORDER) do mitems[#mitems + 1] = { 'Theme: ' .. n, function() C.apply_theme(C.THEMES[n], n); changed() end, cfg.theme == n } end
    -- f8b: loadouts switch instantly from here
    local LL = LO.list()
    if #LL.order > 0 then
        mitems[#mitems + 1] = { sep = true }
        local cur = LO.current()
        for i = 1, math.min(8, #LL.order) do local n = LL.order[i]; mitems[#mitems + 1] = { 'Loadout: ' .. n, function() local ok, m = LO.apply(n); msg = m; changed() end, cur == n } end
    end
    mitems[#mitems + 1] = { sep = true }
    mitems[#mitems + 1] = { 'Copy last fight (EQ line)', function() if PS.last then PS.copy(PS.export_eq(PS.last)) end end }
    mitems[#mitems + 1] = { sep = true }
    mitems[#mitems + 1] = { 'Stop combatfx', function() if M.stop_cb then M.stop_cb() end end, nil, 'stop' }
    local h, html = 48, { '<div class="mhd"><img src="../img/ic_fx_32.png"/>COMBATFX</div>' }
    for i, it in ipairs(mitems) do
        if it.sep then html[#html + 1] = '<div class="msep"></div>'; h = h + 9
        else html[#html + 1] = string.format('<div class="mi%s%s" id="a-mi:%d" action="mi:%d"><span class="mck"></span>%s</div>', it[3] and ' on' or '', it[4] and (' ' .. it[4]) or '', i, i, C.esc(it[1])); h = h + 24 end
    end
    MN:rml('mlist', table.concat(html))
    local sw_, sh = C.screen()
    local x, y = C.mouse(); x = C.clamp(x or 300, 0, sw_ - MENU_W); y = C.clamp(y or 300, 0, sh - h)
    mrect = { x, y, MENU_W, h }
    MN:place(x, y, MENU_W, h); MN:show(true); mopen, mt = true, C.now()
end
local function on_menu(ev)
    if ev.type ~= 'click' then return end
    local i = tonumber((ev.action or ''):match('^mi:(%d+)$') or '')
    local it = i and mitems[i]
    if it and it[2] then mclose(); it[2]() end
end

-- ---------------------------------------------------------------- windows
local SW_, SH_ = 700, 600
function M.toggle_settings(force)
    local on = force; if on == nil then on = not ST.visible end
    if not on then previews_clear() end
    ST:show(on)
    if on then
        local sw_, sh = C.screen()
        if not M._placed and not C.saved_pos('Settings') then M._placed = true; ST:place(math.floor(sw_ / 2 - SW_ / 2), math.floor(sh / 2 - SH_ / 2), SW_, SH_) end
        if tab == 'themes' then M.set_input('Save current as', '') elseif tab == 'mark' then in_mode = 'marker'; M.set_input('NPC name to mark', '') elseif tab == 'body' then in_mode = 'nimbus'; M.set_input('Search nimbus', nim_q) elseif tab == 'orn' then in_mode = 'orn'; M.set_input('Search ornaments', orn_q) elseif tab == 'alerts' then in_mode = 'procs'; M.set_input('Proc names', C.cfg.alerts.procs) elseif tab == 'styles' then NP.input() else M.set_input('Colour for ' .. C.KIND_LABEL[sel_kind], C.cfg.color[sel_kind]) end
        render()
    end
end
function M.meter_vis() if PN then PN:show(C.cfg.meter) end end
local function on_launcher(ev)
    if ev.type == 'mousedown' and ev.button == 1 then return mshow() end
    -- whole medallion is the drag handle (no action); a press that moved it was filtered out in C.poll
    if ev.type == 'click' and (tonumber(ev.button) or 0) == 0 then M.toggle_settings() end
end
local function on_settings(ev)
    local a = ev.action or ''
    if (ev.type == 'change' or ev.type == 'submit') and tab == 'styles' then        -- t489: typing does nothing; Enter = that row's Set
        local ri = tostring(ev.id or ''):match('^sfn(%d+)$')
        if ri then if ev.type == 'submit' then return NP.num_typed(tonumber(ri), ST:value(ev.id)) end; return end
    end
    if ev.type == 'submit' or (ev.type == 'click' and a == 'in:ok') then return apply_input() end
    if ev.type ~= 'click' then return end
    if a == 'close' then return M.toggle_settings(false) end
    if a == 'test' and tab == 'styles' then return NP.preview() end   -- t465: Proc FX tab: play the picked native proc effect
    if a == 'test' then SIM.showcase(); msg = 'Preview running: every effect over about 6 seconds'; return render() end
    local fn = acts[a]; if fn then fn() end
end
function M.open()
    local sw_, sh = C.screen()
    local lx, ly = tonumber(C.cfg.launcher_x), tonumber(C.cfg.launcher_y)
    L = C.open({ key = 'Launcher', doc = 'launcher.rml', w = 52, h = 52, x = lx or (sw_ - 120), y = ly or math.floor(sh * 0.45), on_event = on_launcher, dragclick = true })
    ST = C.open({ key = 'Settings', doc = 'settings.rml', w = SW_, h = SH_, on_event = on_settings, hidden = true })
    MN = C.open({ key = 'Menu', doc = 'menu.rml', w = MENU_W, h = 100, x = 0, y = 0, on_event = on_menu, hidden = true, force_pos = true })
    PN = C.open({ key = 'Meter', doc = 'panel.rml', w = 300, h = 124, x = sw_ - 380, y = math.floor(sh * 0.62) })
    M.meter_vis()
end

-- ---------------------------------------------------------------- periodic (cheap): meter 2 Hz, performance line 2 Hz while visible
local nxt = 0
local function tile(img, val, key, cls)
    return string.format('<div class="tl w3%s"><img src="../img/ic_%s_32.png"/><span class="tv">%s</span><span class="tk">%s</span></div>', cls or '', img, val, key)
end
function M.frame()
    if pv_pending then C.guard('tfxpv', previews_tick) end
    if mopen and C.now() - mt > 200 then
        if C.safe(function() return ImGui.IsKeyPressed(ImGuiKey.Escape) end) then mclose()
        elseif C.safe(function() return ImGui.IsMouseClicked(0) or ImGui.IsMouseClicked(1) end) then
            local x, y = C.mouse()
            if x and (x < mrect[1] or y < mrect[2] or x > mrect[1] + mrect[3] or y > mrect[2] + mrect[4]) then mclose() end
        end
    end
    local now = C.now()
    if now < nxt then return end
    nxt = now + 500
    if PN and PN.visible then
        local dps, hps, dtps = E.rates()
        local S = E.stats
        PN:rml('pn', tile('dps', string.format('<span style="color: %s;">%s</span>', C.cfg.color.melee, C.fmt(dps)), 'Damage') ..
            tile('hps', string.format('<span style="color: %s;">%s</span>', C.cfg.color.healout, C.fmt(hps)), 'Healing') ..
            tile('dtps', string.format('<span style="color: %s;">%s</span>', C.cfg.color.incoming, C.fmt(dtps)), 'Taken', ' c3'))
        local fight = S.fight_t0 and string.format('Fighting: %s in %ds', C.fmt(S.fight_dmg), math.floor((now - S.fight_t0) / 1000))
            or (S.last_fight and string.format('Last fight: %s in %ds', C.fmt(S.last_fight.dmg), math.floor(S.last_fight.secs)) or 'Waiting for a fight')
        PN:text('pfight', fight)
        PN:text('pmode', SIM.active() and 'PRACTICE' or 'LAST 10 S')
        PN:class('pmode', 'sim', SIM.active())
    end
    if L then L:class('launch', 'off', not C.cfg.master); L:class('launch', 'sim', SIM.active()) end
    if ST and ST.visible then
        if tab == 'fx' then ST:rml('perf', perf_line()); ST:rml('tier', M.tier_line()) end
        if tab == 'body' then                      -- t362: live search + nimbus status line (2 Hz, diffed writes)
            if in_mode == 'nimbus' then
                local v = ST:value('inp')
                if v ~= nim_q then nim_q = v; render() end
            end
            nim_refresh()
        end
        if tab == 'orn' then                       -- orn1: live search + point status (2 Hz)
            if in_mode == 'orn' then
                local v = ST:value('inp')
                if v ~= orn_q then orn_q = v; orn_page = 1; set_page = 1; render() end
            end
            orn_refresh()
        end
        if tab == 'mark' then NP.mk_refresh() end   -- t495: nearby list stays current
        if tab == 'aura' then na_refresh() end      -- t436: native aura status line (2 Hz)
        if tab == 'trail' then NP.tr_refresh() end   -- t485: native foot trail status line
        if tab == 'styles' then NP.refresh() end    -- t464: native proc effect status line (2 Hz)
        if tab == 'parses' and in_mode == 'pq' then   -- f8b: history search filters as you type
            local v = ST:value('inp')
            if v ~= ph_q then ph_q = v; ph_page = 1; render() end
        end
        ST:text('status', SIM.active() and 'Simulating' or (C.cfg.master and 'Effects on' or 'Effects off'))
        ST:class('fdot', 'live', C.cfg.master and not SIM.active()); ST:class('fdot', 'sim', SIM.active())
        if tab == 'sim' and M._simsig ~= tostring(SIM.running) then M._simsig = tostring(SIM.running); render() end
    end
end
return M
