-- combatfx features (f8): per-target filtering + role looks, encounter stats (live meter + recap), spell-school looks,
-- proc / buff / big-heal alerts beside the character, named-kill and loot moments, share strings, performance
-- auto-scaling and accessibility (minimum text size; the colour-blind presets live in themefx).
-- Pure Lua; signals are chat lines (events.lua) and MQ TLOs. Nothing here draws over the character: every DOM
-- element placed near the body is tested against the same capsule the DLL masks with (bodyfx_gpu knots + feather).
local C = require('combatfx.core')
local F = { REV = 'f8' }

-- ---------------------------------------------------------------- defaults (character ini: group.key=value)
C.cfg.show = { self = true, group = false, incoming = true, pet = true }
C.cfg.rolelook = { self = 'full', group = 'subtle', incoming = 'full', pet = 'compact' }
C.cfg.school = { on = false }
C.cfg.alerts = { proc = true, buff = true, heal = true, procs = '', buffs = '', buff_s = 15, heal_pct = 30 }
C.cfg.moments = { named = true, loot = true, sound = 'off', loots = '', value_pp = 0 }
-- ps1: Parses > Settings masters + the per-item sound switches that had no key of their own (every card switch there
-- is the item's existing key; see combatfx/notify.lua). cards / sounds = 'All cards off' / 'All sounds off' (inverted).
C.cfg.notify = { cards = true, sounds = true, snd_named = true, snd_loot = true, moment_last = 'chimes', spawn_last = 'ding', panel_last = 'combat' }
C.cfg.perf = { auto = true, fps = 40, nums = 28 }
C.cfg.minsize = 0

pcall(require, 'combatfx.fightlog')                                 -- fd1: loaded before the first st_reset
local function mq_() return package.loaded['mq'] end
local function lower(s) return tostring(s or ''):lower() end
local function trim(s) return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '')) end
function F.list(s)                                    -- 'A; b ;c' -> { 'a', 'b', 'c' } (lower case, no empties)
    local out = {}
    for p in tostring(s or ''):gmatch('[^;,\n]+') do p = lower(trim(p)); if p ~= '' then out[#out + 1] = p end end
    return out
end

-- ================================================================ 1 per-target filtering + role looks
F.ROLES = { { 'self', 'Your hits', 'Melee, spells, DoTs, crits, procs you land' }, { 'group', "Group members' hits", "Others' hits from chat (EQ filter 'Others hits' must be on)" },
    { 'incoming', 'Hits on you', 'Damage you take, misses and dodges' }, { 'pet', 'Pet damage', "Your pet's hits (still counted in DPS when hidden)" } }
F.ROLE_OF = { melee = 'self', spell = 'self', dot = 'self', crit = 'self', resist = 'self', proc = 'self', kill = 'self', missout = 'self',
    incoming = 'incoming', miss = 'incoming', pet = 'pet', group = 'group' }
F.ROLE_LOOKS = { { 'full', 'Full' }, { 'bold', 'Bold' }, { 'subtle', 'Subtle' }, { 'compact', 'Compact' } }
F.ROLE_DESC = { full = 'The theme as designed', bold = 'Bigger, more glow and sparks', subtle = 'Smaller, see-through, few particles', compact = 'Small rise, no particles' }
F.ROLE_MOD = {
    full = { size = 1, alpha = 1, prate = 1, glow = 1, sparks = 1, travel = 1 },
    bold = { size = 1.18, alpha = 1, prate = 1.25, glow = 1.25, sparks = 1.25, travel = 1.1 },
    subtle = { size = 0.82, alpha = 0.72, prate = 0.35, glow = 0.6, sparks = 0.4, travel = 0.85 },
    compact = { size = 0.68, alpha = 0.9, prate = 0, glow = 0.5, sparks = 0, travel = 0.55, mot = 'rise' },
}
-- previews (Simulator / settings buttons) may show a feature that is switched off, for ~2 s only
F._force = {}
function F.force(key, ms) F._force[key] = C.now() + (ms or 2500) end
function F.forced(key) local t = F._force[key]; return t ~= nil and C.now() < t end
function F.role(kind, lk) return F.ROLE_OF[lk or ''] or F.ROLE_OF[kind or ''] end
function F.shown(kind, lk)
    local r = F.role(kind, lk); if not r then return true end
    return (C.cfg.show or {})[r] ~= false or F.forced('show.' .. r)
end
function F.role_mod(kind, lk)
    local r = F.role(kind, lk)
    local m = r and (C.cfg.rolelook or {})[r] or 'full'
    return F.ROLE_MOD[m] or F.ROLE_MOD.full, r
end

-- ================================================================ 7 performance auto-scaling (runtime only, never saved)
F.TIERS = {
    [0] = { name = 'Full', prate = 1, sparks = 1, bloom = 1, cap = 1 },
    [1] = { name = 'Reduced', prate = 0.5, sparks = 0.5, bloom = 0.6, cap = 0.75 },
    [2] = { name = 'Low', prate = 0, sparks = 0, bloom = 0, cap = 0.5 },
}
F.perf = { tier = 0, fps = 0, nums = 0, bad_since = nil, good_since = nil, src = '-', changed_t = 0 }
F.PERF_DOWN_MS, F.PERF_UP_MS, F.PERF_UP_MARGIN = 3000, 10000, 8
function F.tier() if C.cfg.perf and C.cfg.perf.auto == false then return 0 end; return F.perf.tier end
function F.tier_info() return F.TIERS[F.tier()] end
-- pure step (unit-tested): fps/nums sample at `now` -> tier (0..2) with hysteresis
function F.perf_step(P, fps, nums, now, cfg)
    local thr = tonumber(cfg.fps) or 40
    local ncap = tonumber(cfg.nums) or 28
    local bad = (fps and fps > 0 and fps < thr) or nums > ncap
    local good = (not fps or fps <= 0 or fps >= thr + F.PERF_UP_MARGIN) and nums <= ncap * 0.6
    if bad then
        P.good_since = nil
        P.bad_since = P.bad_since or now
        if P.tier < 2 and now - P.bad_since >= F.PERF_DOWN_MS then P.tier = P.tier + 1; P.bad_since = now; P.changed_t = now end
    elseif good then
        P.bad_since = nil
        P.good_since = P.good_since or now
        if P.tier > 0 and now - P.good_since >= F.PERF_UP_MS then P.tier = P.tier - 1; P.good_since = now; P.changed_t = now end
    else
        P.bad_since, P.good_since = nil, nil
    end
    return P.tier
end
local fc_n, fc_t0 = 0, nil
function F.perf_frame(now, nums)
    -- frame counter (this callback runs once per rendered frame) as the fallback; ImGui's own rolling Framerate first
    fc_n = fc_n + 1
    fc_t0 = fc_t0 or now
    if now - (F.perf._next or 0) < 500 then return end
    F.perf._next = now + 500
    local fps = C.safe(function() return ImGui.GetIO().Framerate end)
    local src = 'imgui'
    if type(fps) ~= 'number' or fps <= 0 then
        local dt = now - fc_t0
        fps = dt > 0 and fc_n * 1000 / dt or 0; src = 'frames'
    end
    fc_n, fc_t0 = 0, now
    F.perf.fps, F.perf.nums, F.perf.src = fps, nums or 0, src
    if not (C.cfg.perf and C.cfg.perf.auto) then F.perf.tier = 0; F.perf.bad_since, F.perf.good_since = nil, nil; return end
    -- a background client runs at EQ's MaxBGFPS on purpose: do not treat that as a slowdown
    local mq = mq_()
    local fg = mq and C.safe(function() return mq.TLO.EverQuest.Foreground() end)
    if fg == false then fps = nil end
    F.perf_step(F.perf, fps, nums or 0, now, C.cfg.perf)
end

-- ================================================================ 8 accessibility: minimum text size
function F.min_size(px)
    local m = tonumber(C.cfg.minsize) or 0
    if m > 0 and px < m then return m end
    return px
end

-- ================================================================ look pipeline used by themefx (role + school + perf)
F.SCHOOL_LOOK = { Fire = 'Inferno', Cold = 'Glacier', Poison = 'Venom', Disease = 'Plague', Magic = 'Void', Chromatic = 'Storm', Prismatic = 'Storm', Corruption = 'Blood Moon' }
F.SCHOOLS = { 'Fire', 'Cold', 'Poison', 'Disease', 'Magic', 'Chromatic', 'Corruption' }
F.SCHOOL_DESC = { Fire = 'Inferno: fire shader, embers', Cold = 'Glacier: ice facets, shards', Poison = 'Venom: toxic bubbles', Disease = 'Plague: spores drifting up',
    Magic = 'Void: violet motes', Chromatic = 'Storm: lightning sparks (also Prismatic)', Corruption = 'Blood Moon: blood gloss, drops' }
-- 'fire' / 'Fire' / 'FIRE' -> 'Fire'; unknown / Unresistable / non-melee -> nil (skip, keep the main theme)
function F.school_of(s)
    s = trim(s); if s == '' then return nil end
    local k = s:sub(1, 1):upper() .. s:sub(2):lower()
    if F.SCHOOL_LOOK[k] then return k end
    return nil
end
local look_cache = {}
-- returns look table, colour override (or nil) for one number
function F.look_for(L, kind, lk, opts)
    local T = package.loaded['combatfx.themefx']
    local base, col = L, nil
    if opts and opts.school and ((C.cfg.school and C.cfg.school.on) or F.forced('school')) and T then
        local sc = F.school_of(opts.school)
        local preset = sc and F.SCHOOL_LOOK[sc]
        if preset and T.LOOKS[preset] then
            base = T.LOOKS[preset]
            local pc = T.COLORS[preset]
            col = pc and (pc[kind] or pc.spell) or nil
        end
    end
    local mod = F.role_mod(kind, lk)
    local pt = F.tier_info()
    if base == L and mod == F.ROLE_MOD.full and pt.prate == 1 then return L, col, mod end
    local key = tostring(base) .. '|' .. tostring(mod) .. '|' .. F.tier()
    local o = (base ~= L) and look_cache[key] or nil
    if not o then
        o = F.apply_mod(base, mod, pt)
        if base ~= L then o.on = L.on; look_cache[key] = o end
    end
    return o, col, mod
end
-- copy of a look with a role modifier and a performance tier applied (also used by the role preview cards)
function F.apply_mod(base, mod, pt)
    pt = pt or F.TIERS[0]
    local o = {}
    for k, v in pairs(base) do o[k] = v end
    o.prate = (tonumber(o.prate) or 0) * mod.prate * pt.prate
    o.glows = (tonumber(o.glows) or 1) * mod.glow
    o.sparks = math.floor((tonumber(o.sparks) or 0) * mod.sparks * pt.sparks + 0.5)
    if mod.sparks == 0 or pt.sparks == 0 then o.shatter = 0 end
    o.travel = (tonumber(o.travel) or 95) * mod.travel
    if mod.mot then o.mot = mod.mot end
    return o
end
function F.cap(max) local pt = F.tier_info(); local c = math.floor((tonumber(max) or 24) * pt.cap); if F.tier() == 2 then c = math.min(c, 12) end; return math.max(4, c) end
function F.bloom(b) return (tonumber(b) or 0) * F.tier_info().bloom end

-- ================================================================ 2 encounter stats: per ability, 1 s buckets, crits, biggest hit
local WEAPON = { hit = true, hits = true, slash = true, slashes = true, crush = true, crushes = true, pierce = true, pierces = true, punch = true, punches = true,
    claw = true, bite = true, maul = true, gore = true, sting = true, slice = true, smash = true, rend = true, hack = true, backhand = true }
function F.melee_ability(verb)
    verb = lower(verb)
    if verb == '' or WEAPON[verb] then return 'Melee' end
    return verb:sub(1, 1):upper() .. verb:sub(2)
end
local ENC
function F.enc_reset(now, target)
    ENC = { t0 = now or 0, target = target or '', abil = {}, order = {}, buckets = {}, total = 0, hits = 0, crits = 0, big = 0, bigab = '', group = 0, pet = 0 }
end
F.enc_reset(0, '')
function F.enc() return ENC end
local function ab(name)
    local a = ENC.abil[name]
    if not a then a = { name = name, dmg = 0, hits = 0, crits = 0, max = 0 }; ENC.abil[name] = a; ENC.order[#ENC.order + 1] = name end
    return a
end
function F.enc_hit(name, n, crit, now)
    if not n or n <= 0 then return end
    name = (name and name ~= '') and name or 'Melee'
    local a = ab(name)
    a.dmg, a.hits = a.dmg + n, a.hits + 1
    if crit then a.crits = a.crits + 1; ENC.crits = ENC.crits + 1 end
    if n > a.max then a.max = n end
    ENC.total, ENC.hits = ENC.total + n, ENC.hits + 1
    if n > ENC.big then ENC.big, ENC.bigab = n, name end
    local i = math.floor(math.max(0, (now or 0) - ENC.t0) / 1000) + 1
    if i <= 900 then ENC.buckets[i] = (ENC.buckets[i] or 0) + n; if i > (ENC.nb or 0) then ENC.nb = i end end
end
-- a crit announcement ("You score a critical hit! (N)") is counted first under a fallback name; the damage line
-- right after it names the real ability (verb / spell) -> move it there
function F.enc_rename(from, to, n)
    if not to or to == '' or to == from then return end
    local a = ENC.abil[from]; if not a or a.dmg < n then return end
    a.dmg, a.hits, a.crits = a.dmg - n, a.hits - 1, math.max(0, a.crits - 1)
    if a.hits <= 0 then ENC.abil[from] = nil; for i, k in ipairs(ENC.order) do if k == from then table.remove(ENC.order, i); break end end end
    local b = ab(to); b.dmg, b.hits, b.crits = b.dmg + n, b.hits + 1, b.crits + 1
    if n > b.max then b.max = n end
    if ENC.bigab == from and ENC.big == n then ENC.bigab = to end
end
function F.enc_target() return ENC.target end                   -- f8b
function F.enc_other(kind, n) if n and n > 0 then ENC[kind] = (ENC[kind] or 0) + n end end

-- ================================================================ pa1: full fight stats (parse.lua events), GamParse-style
-- out[cat] = { dmg, hits, crits, max } for melee / spell / dot / ds / pet; inc[cat] = { dmg, hits, max };
-- sw_in / sw_out / sw_pet = swing outcomes (hit, miss, dodge, parry, block, riposte, rune, invuln);
-- heal_in / heal_out = { amount, count, crits, overheal, hot amount }. Durations from the first to the last
-- damage or swing (min 1 s; a one-hit fight uses the time since the engage, 1-6 s).
local ST
local function z3() return { 0, 0, 0, 0 } end
function F.st_reset(now, engage)
    ST = { t0 = now or 0, engage = engage or now or 0, first = nil, last = nil, events = 0,
        out = { melee = z3(), spell = z3(), dot = z3(), ds = z3(), pet = z3() }, abil = {}, aorder = {},
        inc = { melee = z3(), spell = z3(), dot = z3(), ds = z3(), env = z3() }, attackers = {},
        sw_in = {}, sw_out = {}, sw_pet = {}, heal_in = { 0, 0, 0, 0, 0 }, heal_out = { 0, 0, 0, 0, 0 },
        healers = {}, htargets = {}, hspells = {}, res_out = 0, res_in = 0, cripple = 0, special = {}, absorbed = 0, other_ds = 0, group = 0,
        -- f8b: spell timeline (your casts / spells / procs / AAs, absolute ms), per-actor group numbers, targets you hit
        tl = {}, casts = {}, gdmg = {}, gheal = {}, gtaken = {}, ghits = 0, tgts = {}, enemies = {} }
    local FL = package.loaded['combatfx.fightlog']; if FL then FL.reset(now or 0, engage or now or 0) end   -- fd1: fight detail
end
F.st_reset(0, 0)
function F.stats() return ST end
local ACTIVE = { dmg = true, inc = true, swing_in = true, swing_out = true, swing_pet = true }
F.ST_ACTIVE = ACTIVE
local function bump(map, key, n) if key and key ~= '' then map[key] = (map[key] or 0) + n end end
-- f8b: timeline entries (lane, name, ms). lanes: cast (you began casting), spell (your spell / DoT / heal landed),
-- proc (a spell you did not cast in the last 20 s, Crippling / Finishing / special blows), aa (You activate X),
-- burn (a cast or activation whose name is on your burn list). Bounded: 240 per fight, repeats within 0.8 s merged.
F.TL_MAX = 240
F._burns = {}
function F.set_burns(list) F._burns = {}; for n in tostring(list or ''):gmatch('[^;]+') do local x = n:gsub('^%s+', ''):gsub('%s+$', ''):lower(); if x ~= '' then F._burns[#F._burns + 1] = x end end end
local function is_burn(name)
    local l = tostring(name or ''):lower()
    for _, b in ipairs(F._burns) do if l:find(b, 1, true) then return true end end
    return false
end
F.is_burn = is_burn
local function tl_add(lane, name, now, n)
    local tl = ST.tl
    local last = tl[#tl]
    if last and last[1] == lane and last[2] == name and now - last[3] < 800 then last[4] = (last[4] or 0) + (n or 0); return end
    if #tl >= F.TL_MAX then return end
    tl[#tl + 1] = { lane, name, now, n or 0 }
end
F._tl_add = function(lane, name, now, n) tl_add(lane, name, now, n) end
local function abil(name, n, crit)
    local a = ST.abil[name]
    if not a then a = { name = name, dmg = 0, hits = 0, crits = 0, max = 0 }; ST.abil[name] = a; ST.aorder[#ST.aorder + 1] = name end
    a.dmg, a.hits = a.dmg + n, a.hits + 1; if crit then a.crits = a.crits + 1 end; if n > a.max then a.max = n end
end
F.ABIL_NAME = function(ev)
    if ev.who == 'pet' then return 'Pet' end                     -- fd1: the pet's shield / procs are the pet's (were 'Damage shield', read as yours)
    if ev.cat == 'ds' then return 'Damage shield' end
    if ev.cat == 'melee' then return F.melee_ability(ev.verb) end
    if ev.sp and ev.sp ~= '' then return (tostring(ev.sp):gsub('%.$', '')) end
    if ev.cat == 'dot' then return 'DoTs' end
    return 'Spells'
end
function F.st_add(ev, now)
    if not ev then return end
    local FL = package.loaded['combatfx.fightlog']; if FL then FL.add(ev, now) end   -- fd1: fight detail (graph, tables, event log)
    local k = ev.k
    if ACTIVE[k] then
        ST.events = ST.events + 1
        if not ST.first then ST.first = now end
        if not ST.last or now > ST.last then ST.last = now end
    end
    local n = tonumber(ev.n) or 0
    if k == 'dmg' then
        local cat = ev.who == 'pet' and 'pet' or ev.cat
        local o = ST.out[cat] or z3(); ST.out[cat] = o
        o[1], o[2] = o[1] + n, o[2] + 1; if ev.crit then o[3] = o[3] + 1 end; if n > o[4] then o[4] = n end
        abil(F.ABIL_NAME(ev), n, ev.crit)
        if ev.who == 'me' and ev.cat == 'melee' then bump(ST.sw_out, 'hit', 1) end
        if ev.who == 'pet' and ev.cat == 'melee' then bump(ST.sw_pet, 'hit', 1) end
        if ev.cripple then ST.cripple = ST.cripple + 1 end
        if ev.special then bump(ST.special, ev.special, 1) end
        if ev.tgt and ev.tgt ~= '' then bump(ST.tgts, ev.tgt, n); ST.enemies[tostring(ev.tgt):lower()] = true end
        if ev.who == 'me' then
            if (ev.cat == 'spell' or ev.cat == 'dot') and ev.sp and ev.sp ~= '' then
                local cast = ST.casts[tostring(ev.sp):lower()]
                tl_add((cast and now - cast < 20000) and 'spell' or 'proc', tostring(ev.sp), now, n)
            elseif ev.cat == 'spell' then tl_add('proc', 'Spell', now, n) end
            if ev.cripple then tl_add('proc', 'Crippling Blow', now, n) end
            if ev.special then tl_add('proc', ev.special, now, n) end
        end
    elseif k == 'inc' then
        local o = ST.inc[ev.cat] or z3(); ST.inc[ev.cat] = o
        o[1], o[2] = o[1] + n, o[2] + 1; if n > o[3] then o[3] = n end
        bump(ST.attackers, ev.who ~= '' and ev.who or nil, n)
        if ev.who and ev.who ~= '' then ST.enemies[tostring(ev.who):lower()] = true end
        bump(ST.gtaken, 'You', n)
        if ev.cat == 'melee' then bump(ST.sw_in, 'hit', 1) end
    elseif k == 'swing_in' then bump(ST.sw_in, ev.how, 1)
    elseif k == 'swing_out' then bump(ST.sw_out, ev.how, 1)
    elseif k == 'swing_pet' then bump(ST.sw_pet, ev.how, 1)
    elseif k == 'heal_in' or k == 'heal_out' then
        local h = (k == 'heal_in') and ST.heal_in or ST.heal_out
        h[1], h[2] = h[1] + n, h[2] + 1; if ev.crit then h[3] = h[3] + 1 end; h[4] = h[4] + (tonumber(ev.over) or 0); if ev.hot then h[5] = h[5] + n end
        if k == 'heal_in' then bump(ST.healers, ev.who ~= '' and ev.who or 'Unknown', n)
        else
            bump(ST.htargets, ev.tgt, n); bump(ST.hspells, ev.sp or 'Heal', n); bump(ST.gheal, 'You', n)
            if ev.sp and ev.sp ~= '' then tl_add('spell', tostring(ev.sp), now, n) end
        end
    elseif k == 'resist_out' then ST.res_out = ST.res_out + 1
    elseif k == 'resist_in' then ST.res_in = ST.res_in + 1
    elseif k == 'absorb' then ST.absorbed = ST.absorbed + n
    elseif k == 'finish' then bump(ST.special, 'Finishing Blow', 1)
    elseif k == 'ods' then ST.other_ds = ST.other_ds + n
    elseif k == 'odmg' then
        ST.group = ST.group + n; ST.ghits = ST.ghits + 1
        bump(ST.gdmg, ev.who, n)
        if ev.tgt and ev.tgt ~= '' then bump(ST.gtaken, ev.tgt, n) end
    elseif k == 'oheal' then bump(ST.gheal, ev.who, n)
    elseif k == 'cast' or k == 'activate' then
        local nm = tostring(ev.sp or '')
        if k == 'cast' then ST.casts[nm:lower()] = now end
        tl_add(is_burn(nm) and 'burn' or (k == 'cast' and 'cast' or 'aa'), nm, now, 0)
    end
end
function F.st_secs(now)
    if not ST.first then return 0 end
    local last = ST.last or ST.first
    local span = (last - ST.first) / 1000
    if span < 1 and ST.engage and ST.engage < ST.first then span = math.min(6, (last - ST.engage) / 1000) end
    return math.max(1, span)
end
local function top(map, nmax)
    local t = {}
    for k, v in pairs(map) do t[#t + 1] = { k, v } end
    table.sort(t, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end; return a[1] < b[1] end)
    local o = {}
    for i = 1, math.min(nmax or 3, #t) do o[i] = t[i] end
    return o
end
F.top_of = top
-- plain numbers for the recap, the meter and the headless accuracy harness
function F.stats_export()
    local o = {}
    for k, v in pairs(ST.out) do o[k] = { v[1], v[2], v[3], v[4] } end
    local inc = {}
    for k, v in pairs(ST.inc) do inc[k] = { v[1], v[2], v[3] } end
    local function cp(m) local t = {}; for k, v in pairs(m) do t[k] = v end; return t end
    local you = ST.out.melee[1] + ST.out.spell[1] + ST.out.dot[1] + ST.out.ds[1]
    local intot = 0; for _, v in pairs(ST.inc) do intot = intot + v[1] end
    local ab = {}
    for _, k in ipairs(ST.aorder) do local a = ST.abil[k]; ab[#ab + 1] = { name = a.name, dmg = a.dmg, hits = a.hits, crits = a.crits, max = a.max } end
    table.sort(ab, function(a, b) return a.dmg > b.dmg end)
    return { secs = F.st_secs(), events = ST.events, out = o, you = you, inc = inc, inc_total = intot, sw_in = cp(ST.sw_in), sw_out = cp(ST.sw_out), sw_pet = cp(ST.sw_pet),
        heal_in = { ST.heal_in[1], ST.heal_in[2], ST.heal_in[3], ST.heal_in[4], ST.heal_in[5] }, heal_out = { ST.heal_out[1], ST.heal_out[2], ST.heal_out[3], ST.heal_out[4], ST.heal_out[5] },
        healers = top(ST.healers, 3), htargets = top(ST.htargets, 3), hspells = top(ST.hspells, 3), attackers = top(ST.attackers, 3), abil = ab,
        res_out = ST.res_out, res_in = ST.res_in, cripple = ST.cripple, special = cp(ST.special), absorbed = ST.absorbed, other_ds = ST.other_ds, group = ST.group,
        tl = F.tl_export(), gdmg = cp(ST.gdmg), gheal = cp(ST.gheal), gtaken = cp(ST.gtaken), ghits = ST.ghits, tgts = top(ST.tgts, 3),
        enemies = cp(ST.enemies), first = ST.first, last = ST.last, engage = ST.engage }
end
-- f8b: timeline relative to the fight start (first event or the engage, whichever is earlier), seconds with 0.1 s
function F.tl_export()
    local t0 = ST.first or ST.engage or 0
    if ST.engage and ST.engage > 0 and ST.engage < t0 then t0 = ST.engage end
    local o = {}
    for _, e in ipairs(ST.tl) do o[#o + 1] = { e[1], e[2], math.floor((e[3] - t0) / 100 + 0.5) / 10, e[4] } end
    return o
end
-- rates: swings at you = landed hits + every miss / avoid outcome; a rate is n / swings (0 when nobody swung)
function F.swing_rates(sw)
    local tot = 0; for _, v in pairs(sw or {}) do tot = tot + v end
    local r = { total = tot }
    for _, k in ipairs({ 'hit', 'miss', 'dodge', 'parry', 'block', 'riposte', 'rune', 'invuln', 'other' }) do r[k] = tot > 0 and ((sw[k] or 0) / tot * 100) or 0 end
    r.avoided = tot > 0 and ((tot - (sw.hit or 0)) / tot * 100) or 0
    return r
end
-- recap data: top abilities, crit rate, biggest hit, damage-over-time columns (cols wide)
function F.recap_data(secs, cols)
    cols = cols or 36
    local list = {}
    for _, k in ipairs(ENC.order) do local a = ENC.abil[k]; if a and a.dmg > 0 then list[#list + 1] = a end end
    table.sort(list, function(a, b) return a.dmg > b.dmg end)
    local nb = math.max(1, math.min(900, ENC.nb or math.ceil(secs or 1)))
    local per = math.max(1, math.ceil(nb / cols))
    local g, gmax = {}, 0
    for c = 1, math.ceil(nb / per) do
        local s = 0
        for i = (c - 1) * per + 1, math.min(nb, c * per) do s = s + (ENC.buckets[i] or 0) end
        g[c] = s / per; if g[c] > gmax then gmax = g[c] end
    end
    return { total = ENC.total, hits = ENC.hits, crits = ENC.crits, crit = ENC.hits > 0 and ENC.crits / ENC.hits * 100 or 0,
        big = ENC.big, bigab = ENC.bigab, top = list, graph = g, gmax = gmax, per = per, secs = secs or nb, target = ENC.target, group = ENC.group, pet = ENC.pet }
end
local BAR_COL = { '#ffb347', '#8ac8ff', '#c8a0ff', '#6aff8a', '#ff8a8a' }
function F.recap_html(d, extra, colors)
    local e = C.esc
    local secs = math.max(1, d.secs or 1)
    local h = {}
    h[#h + 1] = string.format('<span class="rh">FIGHT RECAP &#183; %ds%s</span>', math.floor(secs), d.target ~= '' and (' &#183; ' .. e(d.target)) or '')
    h[#h + 1] = string.format('<div class="rsum"><span class="rbig">%s</span> damage &#183; <span class="rv">%s</span> dps</div>', C.fmt(d.total), C.fmt(d.total / secs))
    h[#h + 1] = string.format('<div class="rsum2">Crit rate <span class="rv">%.0f%%</span> (%d of %d) &#183; Biggest <span class="rv">%s</span>%s</div>',
        d.crit, d.crits, d.hits, C.fmt(d.big), d.bigab ~= '' and (' <span class="dim">' .. e(d.bigab) .. '</span>') or '')
    if #d.top > 0 then
        h[#h + 1] = '<div class="rsec">TOP ABILITIES</div>'
        local top = d.top[1].dmg
        for i = 1, math.min(5, #d.top) do
            local a = d.top[i]
            h[#h + 1] = string.format('<div class="ab"><span class="abn">%s</span><div class="abb"><div class="abf" style="width: %d%%; background-color: %s;"></div></div><span class="abv">%s &#183; %d%%%s</span></div>',
                e(a.name), math.max(2, math.floor(a.dmg / top * 100 + 0.5)), (colors and colors[i]) or BAR_COL[i], C.fmt(a.dmg), math.floor(a.dmg / math.max(1, d.total) * 100 + 0.5),
                a.crits > 0 and string.format(' &#183; %d crit', a.crits) or '')
        end
    end
    if #d.graph >= 2 and d.gmax > 0 then
        h[#h + 1] = string.format('<div class="rsec">DAMAGE OVER TIME <span class="dim">&#183; peak %s/s</span></div><div class="gr">', C.fmt(d.gmax))
        local n = #d.graph
        local W, H = 316, 46
        local cw = W / n
        for i, v in ipairs(d.graph) do
            local hh = math.max(1, math.floor(v / d.gmax * H + 0.5))
            h[#h + 1] = string.format('<div class="gc" style="left: %dpx; top: %dpx; width: %dpx; height: %dpx;"></div>', math.floor((i - 1) * cw), H - hh, math.max(2, math.floor(cw) - 1), hh)
        end
        h[#h + 1] = string.format('</div><div class="gax"><span class="gl">0s</span><span class="gr2">%ds</span></div>', math.floor(secs))
    end
    if d.st then for _, x in ipairs(F.recap_more(d.st, secs)) do h[#h + 1] = x end end
    if d.more and d.more ~= '' then h[#h + 1] = d.more end                -- f8b: timeline + group sections
    if extra and #extra > 0 then
        h[#h + 1] = '<div class="rsec">MORE</div>'
        for _, kv in ipairs(extra) do h[#h + 1] = string.format('<span class="rr"><span class="rk">%s</span><span class="rv">%s</span></span>', kv[1], kv[2]) end
    end
    return table.concat(h)
end
-- pa1: the parser sections of the recap (damage by type with crit rates, defense with avoidance rates per swing at
-- you, healing in / out with top healers and spells, your swings, procs and resists). Pure: returns html rows.
local TYPE_ROWS = { { 'melee', 'Melee', '#ffb347' }, { 'spell', 'Spells', '#8ac8ff' }, { 'dot', 'DoTs', '#c8a0ff' }, { 'ds', 'Dmg shield', '#6aff8a' }, { 'pet', 'Pet', '#ff8a8a' } }
local function pct(a, b) return b > 0 and (a / b * 100) or 0 end
local function p0(v) return string.format('%.0f%%', v) end
function F.recap_more(st, secs)
    local e, f = C.esc, C.fmt
    secs = math.max(1, secs or st.secs or 1)
    local h = {}
    local function line(txt) h[#h + 1] = '<div class="rl">' .. txt .. '</div>' end
    -- damage by type
    local tot, rows = 0, {}
    for _, r in ipairs(TYPE_ROWS) do local o = st.out[r[1]]; if o and o[1] > 0 then tot = tot + o[1]; rows[#rows + 1] = { r, o } end end
    if #rows > 0 then
        h[#h + 1] = string.format('<div class="rsec">DAMAGE BY TYPE <span class="dim">&#183; %s total%s</span></div>', f(tot), (st.out.pet and st.out.pet[1] > 0) and ' incl. pet' or '')
        local top = 0; for _, x in ipairs(rows) do if x[2][1] > top then top = x[2][1] end end
        for _, x in ipairs(rows) do
            local r, o = x[1], x[2]
            local crit = (r[1] ~= 'ds') and string.format(' &#183; crit %s', p0(pct(o[3], o[2]))) or ''
            h[#h + 1] = string.format('<div class="ab"><span class="abn">%s</span><div class="abb"><div class="abf" style="width: %d%%; background-color: %s;"></div></div><span class="abv">%s &#183; %d%%%s</span></div>',
                r[2], math.max(2, math.floor(o[1] / top * 100 + 0.5)), r[3], f(o[1]), math.floor(o[1] / math.max(1, tot) * 100 + 0.5), crit)
        end
    end
    -- defense
    local intot = st.inc_total or 0
    local sw = F.swing_rates(st.sw_in)
    if intot > 0 or sw.total > 0 then
        h[#h + 1] = string.format('<div class="rsec">DEFENSE <span class="dim">&#183; %s taken &#183; %s dtps</span></div>', f(intot), f(intot / secs))
        if sw.total > 0 then
            local parts = { string.format('%d swings at you: avoided <span class="rv">%s</span>', sw.total, p0(sw.avoided)) }
            for _, k in ipairs({ 'miss', 'dodge', 'parry', 'block', 'riposte', 'rune', 'invuln' }) do
                if (st.sw_in[k] or 0) > 0 then parts[#parts + 1] = string.format('%s %s', ({ rune = 'rune', invuln = 'invul' })[k] or k, p0(sw[k])) end
            end
            line(table.concat(parts, ' &#183; '))
        end
        local by = {}
        for _, a in ipairs(st.attackers or {}) do by[#by + 1] = string.format('%s %s', e(a[1]), f(a[2])) end
        local kinds = {}
        for _, k in ipairs({ { 'melee', 'melee' }, { 'spell', 'spells' }, { 'dot', 'DoTs' }, { 'ds', 'shields' }, { 'env', 'other' } }) do
            local o = st.inc[k[1]]; if o and o[1] > 0 then kinds[#kinds + 1] = string.format('%s %s', k[2], p0(pct(o[1], intot))) end
        end
        if #kinds > 0 then line(table.concat(kinds, ' &#183; ') .. ((st.absorbed or 0) > 0 and (' &#183; runes absorbed ' .. f(st.absorbed)) or '')) end
        if #by > 0 then line('Top: ' .. table.concat(by, ' &#183; ')) end
    end
    -- healing
    local hi, ho = st.heal_in, st.heal_out
    if hi[1] > 0 or ho[1] > 0 then
        h[#h + 1] = string.format('<div class="rsec">HEALING <span class="dim">&#183; in %s (%s hps) &#183; out %s (%s hps)</span></div>', f(hi[1]), f(hi[1] / secs), f(ho[1]), f(ho[1] / secs))
        if hi[1] > 0 then
            local by = {}
            for _, a in ipairs(st.healers or {}) do by[#by + 1] = string.format('%s %s', e(a[1]), p0(pct(a[2], hi[1]))) end
            line(string.format('Received %d heals &#183; crit %s%s &#183; %s', hi[2], p0(pct(hi[3], hi[2])), hi[4] > 0 and (' &#183; over ' .. f(hi[4])) or '', table.concat(by, ', ')))
        end
        if ho[1] > 0 then
            local by = {}
            for _, a in ipairs(st.hspells or {}) do by[#by + 1] = string.format('%s %s', e(a[1]), f(a[2])) end
            line(string.format('Done %d heals &#183; crit %s%s &#183; %s', ho[2], p0(pct(ho[3], ho[2])), ho[4] > 0 and (' &#183; over ' .. f(ho[4])) or '', table.concat(by, ', ')))
        end
    end
    -- your swings / specials / resists
    local so = F.swing_rates(st.sw_out)
    local bits = {}
    if so.total > 0 then
        local p = { string.format('%d swings: landed %s', so.total, p0(so.hit)) }
        for _, k in ipairs({ 'miss', 'dodge', 'parry', 'block', 'riposte', 'rune', 'invuln' }) do
            if (st.sw_out[k] or 0) > 0 then p[#p + 1] = string.format('%s %s', ({ miss = 'missed', dodge = 'dodged', parry = 'parried', block = 'blocked', riposte = 'riposted', rune = 'rune', invuln = 'invul' })[k], p0(so[k])) end
        end
        bits[#bits + 1] = table.concat(p, ' &#183; ')
    end
    local sp = {}
    if (st.cripple or 0) > 0 then sp[#sp + 1] = 'Crippling ' .. st.cripple end
    for k, v in pairs(st.special or {}) do sp[#sp + 1] = string.format('%s %d', e(k), v) end
    if (st.res_out or 0) > 0 then sp[#sp + 1] = 'Your spells resisted ' .. st.res_out end
    if (st.res_in or 0) > 0 then sp[#sp + 1] = 'You resisted ' .. st.res_in end
    if #bits + #sp > 0 then
        h[#h + 1] = '<div class="rsec">OFFENSE</div>'
        for _, b in ipairs(bits) do line(b) end
        if #sp > 0 then table.sort(sp); line(table.concat(sp, ' &#183; ')) end
    end
    return h
end
-- f8b: spell timeline strip. Lanes = burns, casts (You begin casting), AAs / clickies (You activate), spell damage
-- that followed your cast, procs (spell damage you did not cast, crippling / special blows). Gaps = stretches of at
-- least `gap` seconds with no cast, AA or burn of yours inside the fight, shaded red. Pure: tl = F.tl_export() rows.
F.TL_LANES = { { 'burn', 'BURN', '#ff5a4a' }, { 'cast', 'CAST', '#8ac8ff' }, { 'aa', 'AA', '#d090ff' }, { 'spell', 'SPELL', '#ffb347' }, { 'proc', 'PROC', '#6aff8a' } }
function F.tl_gaps(tl, secs, gap)
    gap = gap or 3
    local ts = {}
    for _, e in ipairs(tl or {}) do if e[1] == 'cast' or e[1] == 'aa' or e[1] == 'burn' then ts[#ts + 1] = e[3] end end
    table.sort(ts)
    local g = {}
    if #ts == 0 then return g end
    local prev = 0
    for _, t in ipairs(ts) do if t - prev >= gap then g[#g + 1] = { prev, t } end; prev = t end
    if secs - prev >= gap then g[#g + 1] = { prev, secs } end
    return g
end
function F.timeline_html(tl, secs, gap)
    if not tl or #tl == 0 then return '' end
    local W = 276
    local maxt = secs or 1
    for _, e in ipairs(tl) do if e[3] > maxt then maxt = e[3] end end
    maxt = math.max(1, maxt)
    local used = {}
    for _, e in ipairs(tl) do used[e[1]] = (used[e[1]] or 0) + 1 end
    local gaps = F.tl_gaps(tl, maxt, gap)
    local h = { string.format('<div class="rsec">TIMELINE <span class="dim">&#183; %d uses%s</span></div><div class="tl">', #tl,
        #gaps > 0 and string.format(' &#183; %d gap%s &#8805; %ds', #gaps, #gaps > 1 and 's' or '', gap or 3) or '') }
    local function px(t) return 40 + math.floor(C.clamp(t / maxt, 0, 1) * (W - 3) + 0.5) end
    for _, ln in ipairs(F.TL_LANES) do
        if used[ln[1]] then
            local row = { string.format('<div class="tll"><span class="tlk" style="color: %s;">%s</span><div class="tlt"></div>', ln[3], ln[2]) }
            for _, g in ipairs(gaps) do row[#row + 1] = string.format('<div class="tlg" style="left: %dpx; width: %dpx;"></div>', px(g[1]), math.max(2, px(g[2]) - px(g[1]))) end
            for _, e in ipairs(tl) do if e[1] == ln[1] then row[#row + 1] = string.format('<div class="tlm" style="left: %dpx; background-color: %s;"></div>', px(e[3]), ln[3]) end end
            h[#h + 1] = table.concat(row) .. '</div>'
        end
    end
    h[#h + 1] = string.format('</div><div class="gax"><span class="gl">0s</span><span class="gr2">%ds</span></div>', math.floor(maxt + 0.5))
    if #gaps > 0 then
        table.sort(gaps, function(a, b) return (a[2] - a[1]) > (b[2] - b[1]) end)
        local p = {}
        for i = 1, math.min(3, #gaps) do p[#p + 1] = string.format('%.1fs at %ds', gaps[i][2] - gaps[i][1], math.floor(gaps[i][1])) end
        h[#h + 1] = '<div class="rl">Longest gaps: ' .. table.concat(p, ' &#183; ') .. '</div>'
    end
    -- what landed most (names, counts)
    local cnt, order = {}, {}
    for _, e in ipairs(tl) do if e[1] ~= 'proc' then local k = e[2]; if not cnt[k] then cnt[k] = 0; order[#order + 1] = k end; cnt[k] = cnt[k] + 1 end end
    table.sort(order, function(a, b) if cnt[a] ~= cnt[b] then return cnt[a] > cnt[b] end; return a < b end)
    if #order > 0 then
        local p = {}
        for i = 1, math.min(4, #order) do p[#p + 1] = string.format('%s x%d', C.esc(order[i]), cnt[order[i]]) end
        h[#h + 1] = '<div class="rl">' .. table.concat(p, ' &#183; ') .. '</div>'
    end
    return table.concat(h)
end
-- height of a recap card (px) from its html: headings, bars, lines, graph (keeps placement beside the body honest)
function F.recap_height(html)
    local n = function(p) local c = 0; for _ in html:gmatch(p) do c = c + 1 end; return c end
    return 26 + 22 + 18 + n('class="rsec"') * 22 + n('class="ab"') * 17 + n('class="rl"') * 16 + n('class="rr"') * 18 + (html:find('class="gr"', 1, true) and 61 or 0) + n('class="tll"') * 11 + n('class="tl"') * 15 + n('class="gmr"') * 16 + n('class="hint"') * 16 + 20
end
-- live meter: whole-fight DPS (big) plus the rolling last-10 s DPS and a 20-column sparkline of the last 20 s
function F.meter_data(now, dps)
    local i_now = math.floor(math.max(0, now - ENC.t0) / 1000) + 1
    local s, smax = {}, 0
    for c = 1, 20 do local i = i_now - 20 + c; local v = i >= 1 and (ENC.buckets[i] or 0) or 0; s[c] = v; if v > smax then smax = v end end
    local list = {}
    for _, k in ipairs(ENC.order) do local a = ENC.abil[k]; if a and a.dmg > 0 then list[#list + 1] = a end end
    table.sort(list, function(a, b) return a.dmg > b.dmg end)
    local top = list[1]
    local o = ST.out
    local you = o.melee[1] + o.spell[1] + o.dot[1] + o.ds[1] + o.pet[1]
    local hits = o.melee[2] + o.spell[2] + o.dot[2] + o.pet[2]
    local crits = o.melee[3] + o.spell[3] + o.dot[3] + o.pet[3]
    local secs = ST.first and math.max(1, (math.max(now, ST.last or now) - ST.first) / 1000) or math.max(0, (now - ENC.t0) / 1000)
    return { dps = (ST.first and you > 0) and (you / secs) or (dps or 0), rdps = dps or 0, total = ST.first and you or ENC.total, secs = secs, spark = s, smax = smax,
        crit = hits > 0 and (crits / hits * 100) or (ENC.hits > 0 and ENC.crits / ENC.hits * 100 or 0),
        top = top and top.name or '', topp = top and math.floor(top.dmg / math.max(1, ENC.total) * 100 + 0.5) or 0 }
end

-- ================================================================ 4 alerts + 5 moments: placement beside / above the body
-- capsule as the DLL masks it (bodyfx_gpu.capsule): axis feet->head, half-width <= 0.25*span, feather 0.26*span,
-- round cap. Conservative screen box = axis segment box grown by MARGIN*span + PAD px on every side.
F.MARGIN, F.PAD = 0.52, 16
function F.capsule()
    local CV = package.loaded['combatfx.canvas']
    local fx, fy, ux, uy, span, src, wmul
    if CV and CV.player_capsule then
        local ok, a, b, c, d, e, f, g = pcall(CV.player_capsule)
        if ok and a then fx, fy, ux, uy, span, src, wmul = a, b, c, d, e, f, g end
    end
    if not fx then
        local sw, sh = C.screen()
        fx, fy, ux, uy, span, src = sw * 0.5, sh * 0.86, 0, -1, sh * 0.40, 'default'
    end
    return fx, fy, ux, uy, span, src, wmul or 1
end
-- wmul (aura rework): body width scale from canvas.player_capsule (>= 1 when the camera looks down)
function F.body_box(fx, fy, ux, uy, span, wmul)
    local hx, hy = fx + ux * span, fy + uy * span
    local m = F.MARGIN * span * math.max(1, tonumber(wmul) or 1) + F.PAD
    return math.min(fx, hx) - m, math.min(fy, hy) - m, math.max(fx, hx) + m, math.max(fy, hy) + m
end
local function overlap(a, b) return a[1] < b[3] and b[1] < a[3] and a[2] < b[4] and b[2] < a[4] end
F.overlap = overlap
-- slot 1..3 callout of w x h: left of the body (outgoing numbers live on the right), flip right at the screen edge,
-- above the head as the last resort. Returns x, y, side ('l' | 'r' | 'u') or nil when nothing fits.
-- avoid: optional list of {x1, y1, x2, y2} panels currently on screen (recap, live meter) that a callout must not cover
local function clear_of(r, avoid)
    for _, a in ipairs(avoid or {}) do if overlap(r, a) then return false end end
    return true
end
F.clear_of = clear_of
function F.place_beside(w, h, slot, sw, sh, cap, avoid)
    sw, sh = sw or select(1, C.screen()), sh or select(2, C.screen())
    local fx, fy, ux, uy, span, _, wmul = (table.unpack or unpack)(cap or {})
    if not fx then fx, fy, ux, uy, span, _, wmul = F.capsule() end
    local b = { F.body_box(fx, fy, ux, uy, span, wmul) }
    local hx, hy = fx + ux * span, fy + uy * span
    local top = math.min(fy, hy)
    local y = math.max(8, top + span * 0.10) + (slot - 1) * (h + 8)
    local cands = { { b[1] - 10 - w, y, 'l' }, { b[3] + 10, y, 'r' }, { (fx + hx) * 0.5 - w * 0.5, b[2] - 10 - h - (slot - 1) * (h + 8), 'u' } }
    for _, c in ipairs(cands) do
        local r = { c[1], c[2], c[1] + w, c[2] + h }
        if r[1] >= 4 and r[3] <= sw - 4 and r[2] >= 4 and r[4] <= sh - 4 and not overlap(r, b) and clear_of(r, avoid) then return math.floor(c[1]), math.floor(c[2]), c[3], b end
    end
    return nil, nil, nil, b
end
-- the moment flourish prefers above the head, then beside
function F.place_above(w, h, sw, sh, cap, avoid)
    sw, sh = sw or select(1, C.screen()), sh or select(2, C.screen())
    local fx, fy, ux, uy, span, _, wmul = (table.unpack or unpack)(cap or {})
    if not fx then fx, fy, ux, uy, span, _, wmul = F.capsule() end
    local b = { F.body_box(fx, fy, ux, uy, span, wmul) }
    local cx = fx + ux * span * 0.5
    local x, y = cx - w * 0.5, b[2] - 12 - h
    x = math.max(4, math.min(sw - 4 - w, x))
    local r = { x, y, x + w, y + h }
    if y >= 4 and not overlap(r, b) and clear_of(r, avoid) then return math.floor(x), math.floor(y), 'u', b end
    return F.place_beside(w, h, 1, sw, sh, { fx, fy, ux, uy, span, 'x', wmul }, avoid)
end

-- alert decisions (pure, unit-tested)
F.ALERTS = { { 'proc', 'Key procs', 'Crippling / Finishing Blow and any name in your list' }, { 'buff', 'Buff about to drop', 'Buffs in your list (or any 60 s+ buff) under the threshold' },
    { 'heal', 'Big heal', 'A heal on you bigger than a share of your max HP' } }
function F.proc_match(line)
    local list = F._procs
    if not list or #list == 0 then return nil end
    local low = lower(line)
    if low:find('^you begin casting') then return nil end
    for _, p in ipairs(list) do if low:find(p, 1, true) then return p end end
end
function F.refresh_lists()
    F._procs = F.list(C.cfg.alerts.procs)
    F._buffs = F.list(C.cfg.alerts.buffs)
    F._loots = F.list(C.cfg.moments.loots)
end
F.refresh_lists()
function F.buff_watched(name)
    local list = F._buffs or {}
    if #list == 0 then return true end
    local low = lower(name)
    for _, p in ipairs(list) do if low == p or low:find(p, 1, true) then return true end end
    return false
end
function F.buff_threshold() return C.clamp(tonumber(C.cfg.alerts.buff_s) or 15, 3, 120) end
function F.big_heal(n, maxhp)
    if not n or not maxhp or maxhp <= 0 then return false end
    return n >= maxhp * C.clamp(tonumber(C.cfg.alerts.heal_pct) or 30, 5, 100) / 100
end
function F.loot_interesting(name, lore, value_cp)
    local low = lower(name)
    for _, p in ipairs(F._loots or {}) do if low == p or low:find(p, 1, true) then return 'WATCHED' end end
    if lore then return 'LORE' end
    local pp = tonumber(C.cfg.moments.value_pp) or 0
    if pp > 0 and value_cp and value_cp >= pp * 1000 then return 'VALUABLE' end
    return nil
end
F.SOUNDS = { { 'off', 'Off' }, { 'chimes', 'Chimes' }, { 'ding', 'Ding' }, { 'notify', 'Notify' }, { 'tada', 'Tada' } }
function F.sound_cmd(name)
    name = name or C.cfg.moments.sound
    if not name or name == 'off' then return nil end
    local ok = false; for _, s in ipairs(F.SOUNDS) do if s[1] == name then ok = true end end
    if not ok then return nil end
    local ok2, PT = pcall(require, 'combatfx.paths')
    local file, why = nil, 'paths module missing'
    if ok2 then file, why = PT.sound_file(name) end
    F.sound_why = why
    if not file then return nil end
    if file:find('[%s"]') then F.sound_why = 'the sound path has a space or quote (MQ /beep cannot take it): ' .. file; return nil end
    return '/beep ' .. file                                         -- MQ /beep <file> = PlaySound(file, SND_ASYNC): never blocks
end
-- ps1: preview = a Preview button press (plays even with 'All sounds off'); every other caller obeys the master
function F.sounds_on() return not (C.cfg.notify and C.cfg.notify.sounds == false) end
-- ps1: a kill / loot moment's own sound switch (Parses > Settings): the shared moments.sound pick, the item's switch, the master
function F.moment_snd(id)
    local n = C.cfg.notify or {}
    return F.sounds_on() and C.cfg.moments.sound ~= nil and C.cfg.moments.sound ~= 'off' and n['snd_' .. id] ~= false
end
function F.play(name, preview)
    if not preview and not F.sounds_on() then F.sound_why = 'All sounds off (Parses > Settings)'; return false end
    local cmd = F.sound_cmd(name); if not cmd then return false end
    local mq = mq_()
    if mq and mq.cmd then pcall(mq.cmd, cmd); F.last_sound = cmd; return true end
    return false
end

-- ================================================================ 6 profile sharing: CFX1:<base64>.<adler32 hex>
local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local B64I = {}; for i = 1, 64 do B64I[B64:sub(i, i)] = i - 1 end
function F.b64e(s)
    local o = {}
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1, c2, c3, c4 = math.floor(n / 262144) % 64, math.floor(n / 4096) % 64, math.floor(n / 64) % 64, n % 64
        o[#o + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1) .. (b and B64:sub(c3 + 1, c3 + 1) or '=') .. (c and B64:sub(c4 + 1, c4 + 1) or '=')
    end
    return table.concat(o)
end
function F.b64d(s)
    if #s % 4 ~= 0 or s:find('[^%w%+/=]') then return nil end
    local o = {}
    for i = 1, #s, 4 do
        local q = s:sub(i, i + 3)
        local pad = select(2, q:gsub('=', ''))
        if pad > 2 or (pad > 0 and i + 3 < #s) or q:find('=[^=]') then return nil end
        local n = 0
        for j = 1, 4 do local ch = q:sub(j, j); n = n * 64 + (ch == '=' and 0 or B64I[ch]) end
        local a, b, c = math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256
        o[#o + 1] = string.char(a); if pad < 2 then o[#o + 1] = string.char(b) end; if pad < 1 then o[#o + 1] = string.char(c) end
    end
    return table.concat(o)
end
function F.adler(s)
    local a, b = 1, 0
    for i = 1, #s do a = (a + s:byte(i)) % 65521; b = (b + a) % 65521 end
    return string.format('%08x', b * 65536 + a)
end
F.SHARE_MAX = 16000
local STYLES_OK = { bold = true, normal = true, heavy = true, shadow = true }
local MOTIONS_OK = { rise = true, arc = true, fountain = true, static = true, scroll = true }
local TT_OK = {}; for _, t in ipairs(C.TFX_TYPES) do TT_OK[t[1]] = true end
local KIND_OK = {}; for _, k in ipairs(C.KINDS) do KIND_OK[k] = true end
local function hex(v) v = tostring(v or ''); if v:match('^#%x%x%x%x%x%x$') or v:match('^#%x%x%x%x%x%x%x%x$') then return v:lower() end end
local function rng(lo, hi) return function(v) local n = tonumber(v); if n and n == n and n >= lo and n <= hi then return n end end end
local THEME_V = { size = rng(12, 44), dur = rng(0.6, 3), intensity = rng(10, 100), edge = rng(20, 200),
    style = function(v) if STYLES_OK[v] then return v end end, motion = function(v) if MOTIONS_OK[v] then return v end end }
-- validate one key=value from a share string / share file. Returns the clean value or nil. Never evaluates anything.
function F.valid_kv(k, v)
    if type(k) ~= 'string' or type(v) ~= 'string' or #v > 64 or v:find('[%c]') then return nil end
    if KIND_OK[k] then return hex(v) end
    local p, kind = k:match('^(t[tcs])(%a+)$')
    if p and KIND_OK[kind] then
        if p == 'tt' then return TT_OK[v] and v or nil end
        if p == 'tc' then return hex(v) end
        local n = tonumber(v); if n and n >= 1 and n <= 6 then return math.floor(n) end
        return nil
    end
    if THEME_V[k] then return THEME_V[k](v) end
    if k == 'xon' then if v == '0' or v == '1' or v == 'true' or v == 'false' then return v end; return nil end
    local lk = k:match('^x(%w+)$')
    if lk then
        local T = package.loaded['combatfx.themefx'] or (pcall(require, 'combatfx.themefx') and package.loaded['combatfx.themefx'])
        if T and T.norm then return T.norm(lk, v) end
    end
    return nil
end
function F.clean_name(s)
    s = trim(tostring(s or ''):gsub('[%c%[%]=]', ''))
    if #s > 40 then s = s:sub(1, 40) end
    return s
end
function F.share_encode(name, snap)
    local ks = {}
    for k in pairs(snap) do ks[#ks + 1] = k end
    table.sort(ks)
    local lines = { 'name=' .. F.clean_name(name ~= '' and name or 'Shared') }
    for _, k in ipairs(ks) do local v = snap[k]; if v ~= nil and type(v) ~= 'table' then lines[#lines + 1] = k .. '=' .. tostring(v) end end
    local payload = table.concat(lines, '\n')
    return 'CFX1:' .. F.b64e(payload) .. '.' .. F.adler(payload)
end
-- returns ok, name_or_error, clean_table, rejected_keys
function F.share_decode(s)
    s = tostring(s or ''):gsub('%s', '')
    if #s == 0 then return false, 'empty' end
    if #s > F.SHARE_MAX then return false, 'too long' end
    local body, sum = s:match('^CFX1:([%w%+/=]+)%.(%x+)$')
    if not body then return false, 'not a CombatFX share string (starts with CFX1:)' end
    local payload = F.b64d(body)
    if not payload then return false, 'damaged (base64)' end
    if F.adler(payload) ~= sum:lower() then return false, 'damaged (checksum)' end
    local t, rejected, name, n = {}, {}, nil, 0
    for line in (payload .. '\n'):gmatch('([^\n]*)\n') do
        if line ~= '' then
            n = n + 1
            if n > 400 then return false, 'too many lines' end
            local k, v = line:match('^(%w+)=(.*)$')
            if not k then rejected[#rejected + 1] = '?'
            elseif k == 'name' then name = F.clean_name(v)
            else
                local cv = F.valid_kv(k, v)
                if cv ~= nil then t[k] = cv else rejected[#rejected + 1] = k end
            end
        end
    end
    if not next(t) then return false, 'no usable settings' end
    if not name or name == '' then name = 'Shared' end
    return true, name, t, rejected
end
-- whitelist a whole ini section (share files dropped into config\)
function F.clean_section(sec)
    local t, rej = {}, {}
    for k, v in pairs(sec or {}) do local cv = F.valid_kv(k, tostring(v)); if cv ~= nil then t[k] = cv else rej[#rej + 1] = k end end
    return t, rej
end

return F
