-- combatfx/track.lua (f10): the Tracking tab and its on-screen pieces.
--   1 buffs fading + your DoTs / debuffs on the target (timers, warning before they drop)
--   2 mob cast / action warnings from your list, drawn ABOVE THE MOB (world-anchored, never over you)
--   3 necro / pet view: pet damage split, DoT ticks per spell, "DoTs still running" countdown, feign death flash
--   4 group share (damage + healing per member, pets folded into their owner)   5 damage taken breakdown
--   6 resist rates per spell / per mob   7 damage per mana per spell   8 session rates   9 named spawn alerts
--  10 death recap breakdown (by source + ability)  + a hint when EQ's own log file is not growing (/log on)
-- Everything is fed by combatfx.parse events (real chat lines, see parse.lua P.f10) and TLOs polled at 1-4 Hz.
-- Spell data (mana, cast time, duration formula, feign-death effect) comes from the client's spells_us.txt (read in
-- small chunks, never in one go), with MQ's Spell TLO as the fallback.
local C = require('combatfx.core')
local FT = require('combatfx.features')
local M = { REV = 'f10' }
local function mq_() return package.loaded['mq'] or {} end
local function lower(s) return tostring(s or ''):lower() end
local function trim(s) return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '')) end

C.cfg.track = { on = true, panel = 'combat', pbuffs = 5, dots = true, dot_warn = 4, castwarn = true,
    cast_list = 'Gate; AE; Rampage; Enrage; Flurry; Complete Heal', cast_world = true, pet = true, fd = true,
    spawn = true, spawn_named = true, spawn_list = '', spawn_ignore = '', spawn_sound = 'ding', spawn_world = true,
    loghint = true, gpets = true }
C.cfg.alerts = C.cfg.alerts or {}
for _, k in ipairs({ 'spawn', 'fd', 'dot', 'cast' }) do if C.cfg.alerts[k] == nil then C.cfg.alerts[k] = true end end
function M.cfg() return C.cfg.track end

-- ================================================================ spell data (client spells_us.txt, else Spell TLO)
-- spells_us.txt (TOB client, '^' separated): 0 id, 1 name, 8 cast ms, 11 duration formula, 12 duration ticks, 14 mana,
-- last field = effect slots "slot|SPA|base|..." joined by '$' (SPA 74 = feign death). Checked on the real file:
-- Minor Healing 10 mana, Lifetap 8, Disease Cloud 10; Feign Death 366 = "1|74|87|0|100|0".
local DB = { state = 'idle', by = {}, n = 0 }
M.DB = DB
local PAT = '^(%d+)%^([^^]*)' .. string.rep('%^[^^]*', 6) .. '%^([^^]*)%^[^^]*%^[^^]*%^([^^]*)%^([^^]*)%^[^^]*%^([^^]*)%^'
function M.db_line(l)
    local id, name, ct, form, dur, mana = l:match(PAT)
    if not id or name == '' then return nil end
    local last = l:match('([^^]*)$') or ''
    local fd = ('$' .. last):find('%$%d+|74|') ~= nil
    local key = name:lower()
    if DB.by[key] then return nil end                              -- first id wins (player spells come first)
    -- packed in one short string per spell (41k spells: a table each would cost several MB of Lua memory)
    local packed = string.format('%d %d %d %d %d %d', tonumber(id) or 0, tonumber(mana) or 0, tonumber(ct) or 0, tonumber(form) or 0, tonumber(dur) or 0, fd and 1 or 0)
    DB.by[key] = packed; DB.n = DB.n + 1
    return M.db_get(key)
end
function M.db_get(key)
    local p = DB.by[key]; if not p then return nil end
    local id, mana, ct, form, dur, fd = p:match('^(%-?%d+) (%-?%d+) (%-?%d+) (%-?%d+) (%-?%d+) (%d)$')
    return { id = tonumber(id), mana = tonumber(mana), ct = tonumber(ct), form = tonumber(form), dur = tonumber(dur), fd = fd == '1' }
end
function M.db_open(path)
    if DB.state ~= 'idle' then return DB.state end
    path = path or (function() local ok, PT = pcall(require, 'combatfx.paths'); return ok and PT.eq_file and PT.eq_file('spells_us.txt') or nil end)()
    if not path then DB.state, DB.why = 'none', 'spells_us.txt not found in the EQ folder (set eq_folder in combatfx_paths.ini)'; return DB.state end
    local f = io.open(path, 'r')
    if not f then DB.state, DB.why = 'none', 'cannot open ' .. path; return DB.state end
    DB.f, DB.path, DB.state = f, path, 'loading'
    return DB.state
end
-- reads at most `lines` lines (default 600 ~ a few ms); call from the slow loop until it says 'ready'
function M.db_step(lines)
    if DB.state ~= 'loading' then return DB.state end
    for _ = 1, lines or 600 do
        local l = DB.f:read('*l')
        if not l then DB.f:close(); DB.f = nil; DB.state = 'ready'; return DB.state end
        M.db_line(l)
    end
    return DB.state
end
-- EQ duration formula (ticks of 6 s) for your level; checked against real logs (Mychar, level 80): Chaos Venom (form 1,
-- 7 ticks) first tick 16:39:38 -> worn off 16:40:20 = 42 s; Dread Pyre (form 7, 5 ticks) 16:57:58 -> 16:58:28 = 30 s
function M.calc_ticks(level, form, dur)
    level = tonumber(level) or 1; form = tonumber(form) or 0; dur = tonumber(dur) or 0
    local t
    if form == 0 then return dur end
    if form == 1 then t = level > 3 and math.floor(level / 2) or 1
    elseif form == 2 then t = level > 3 and math.floor(level / 2) + 5 or 6
    elseif form == 3 then t = 30 * level
    elseif form == 4 then t = 50
    elseif form == 5 then t = 2
    elseif form == 6 then t = math.floor(level / 2) + 2
    elseif form == 7 then t = level
    elseif form == 8 then t = level + 10
    elseif form == 9 then t = 2 * level + 10
    elseif form == 10 then t = 3 * level + 10
    elseif form == 11 then t = 30 * (level + 3)
    elseif form == 12 then t = level > 7 and math.floor(level / 4) or 1
    elseif form == 13 then t = 4 * level + 10
    elseif form == 14 then t = 5 * (level + 2)
    elseif form == 15 then t = 10 * (level + 10)
    elseif form == 50 or form == 51 then return -1
    elseif form < 200 then return 0
    else t = form end
    if dur > 0 and dur < t then t = dur end
    return t
end
local tlo_cache = {}
-- { mana, ct, ticks, fd, src } for a spell name; nil when nothing knows it
function M.spell(name)
    local key = lower(name):gsub('%.$', '')
    if key == '' then return nil end
    local lvl = M._level or C.num(function() return mq_().TLO.Me.Level() end, 1)
    local e = M.db_get(key)
    if e then return { mana = e.mana, ct = e.ct, ticks = M.calc_ticks(lvl, e.form, e.dur), fd = e.fd == true, src = 'spells_us.txt', id = e.id } end
    local c = tlo_cache[key]
    if c == nil then
        local mq = mq_()
        local S = function(f) return C.safe(f) end
        local mana = tonumber(S(function() return mq.TLO.Spell(name).Mana() end))
        if mana then
            local secs = tonumber(S(function() return mq.TLO.Spell(name).Duration.TotalSeconds() end))
            c = { mana = mana, ct = tonumber(S(function() return mq.TLO.Spell(name).MyCastTime() end)) or 0,
                ticks = secs and math.floor(secs / 6 + 0.5) or nil, fd = S(function() return mq.TLO.Spell(name).HasSPA(74)() end) == true,
                endur = tonumber(S(function() return mq.TLO.Spell(name).EnduranceCost() end)), src = 'Spell TLO' }
        else c = false end
        tlo_cache[key] = c
    end
    return c or nil
end
function M.endurance(name)
    local key = lower(name)
    local c = tlo_cache[key]
    if c and c.endur then return c.endur end
    local mq = mq_()
    return tonumber(C.safe(function() return mq.TLO.Spell(name).EnduranceCost() end))
end

-- ================================================================ state
local S, F, LAST                                            -- session, current fight, last finished fight
local function fight_new(now) return { t0 = now, taken = {}, tk = { n = 0, hits = 0 }, avoid = {}, rune = 0, absorbed = 0, pet = { melee = { 0, 0, 0, 0 }, spell = { 0, 0, 0, 0 }, ds = { 0, 0, 0, 0 }, miss = 0, swings = 0 }, dots = {} } end
function M.reset_session(now)
    now = now or C.now()
    S = { t0 = now, kills = 0, xp_pct = 0, xp_n = 0, xp_lines = 0, aa = 0, coin = { corpse = 0, split = 0, reward = 0 }, items = 0, deaths = 0,
        taken = fight_new(now), res = { sp = {}, mob = {} }, eff = {}, casts = {}, lvl = nil, pct = nil, aapct = nil, aapts = nil, tlo_xp = 0, tlo_aa = 0 }
end
M.reset_session(0)
function M.session() return S end
function M.fight() return F end
function M.last_fight() return LAST end
M.dots = {}                                                  -- active DoTs: [tgt|sp] = { tgt, sp, first, last, ticks, dmg, ends, src }
M.pend = {}                                                  -- your casts waiting for an outcome
M.labels = {}                                                -- world labels: [slot] = { id, h, until, title }
local tgt = { name = '', id = 0, t = -1e9 }
M._tgt = tgt
local function target_name()
    local now = C.now()
    if M._debug_target then return M._debug_target end
    if now - tgt.t > 250 then
        tgt.t = now
        local mq = mq_()
        tgt.name = C.str(function() return mq.TLO.Target.CleanName() end, '') or ''
        tgt.id = C.num(function() return mq.TLO.Target.ID() end, 0) or 0
    end
    return tgt.name
end
M.target_name = target_name

local function bump(t, k, n) t[k] = (t[k] or 0) + (n or 1) end
local function sim() local E = package.loaded['combatfx.events']; return E ~= nil and E.sim_state ~= nil end

-- ---------------------------------------------------------------- 5 damage taken (fight + session)
local NOT_AB = { Critical = true, ['Lucky Critical'] = true, ['Crippling Blow'] = true, ['Deadly Strike'] = true, Twincast = true, Lucky = true }
function M.inc_ability(ev)
    if ev.sp and ev.sp ~= '' then return (tostring(ev.sp):gsub('%.$', '')) end
    for _, fl in ipairs(ev.flags or {}) do if not NOT_AB[fl] then return fl end end
    if ev.cat == 'melee' then return 'melee (' .. tostring(ev.verb or 'hit'):gsub(' on$', '') .. ')' end
    if ev.cat == 'ds' then return 'damage shield' end
    if ev.cat == 'dot' then return 'DoT' end
    if ev.cat == 'env' then return 'environment' end
    return 'spell'
end
local function taken_add(T, ev)
    local who = (ev.who and ev.who ~= '') and ev.who or (ev.cat == 'env' and 'Environment' or 'Unknown')
    local s = T.taken[who]; if not s then s = { n = 0, hits = 0, max = 0, ab = {}, av = {} }; T.taken[who] = s end
    s.n, s.hits = s.n + ev.n, s.hits + 1; if ev.n > s.max then s.max = ev.n end
    local an = M.inc_ability(ev)
    local a = s.ab[an]; if not a then a = { n = 0, hits = 0, max = 0 }; s.ab[an] = a end
    a.n, a.hits = a.n + ev.n, a.hits + 1; if ev.n > a.max then a.max = ev.n end
    T.tk.n, T.tk.hits = T.tk.n + ev.n, T.tk.hits + 1
end
local function avoid_add(T, ev)
    local who = (ev.who and ev.who ~= '') and ev.who or 'Unknown'
    local s = T.taken[who]; if not s then s = { n = 0, hits = 0, max = 0, ab = {}, av = {} }; T.taken[who] = s end
    bump(s.av, ev.how); bump(T.avoid, ev.how)
    if ev.how == 'rune' then T.rune = T.rune + 1 end
end
-- rows for the breakdown: sources by damage, each with its top abilities and what you avoided
function M.taken_rows(T, nmax)
    T = T or (F or S.taken)
    local rows = {}
    for who, s in pairs(T.taken) do
        local ab = {}
        for an, a in pairs(s.ab) do ab[#ab + 1] = { an, a.n, a.hits, a.max } end
        table.sort(ab, function(x, y) return x[2] > y[2] end)
        local av = 0; for _, v in pairs(s.av) do av = av + v end
        rows[#rows + 1] = { who = who, n = s.n, hits = s.hits, max = s.max, ab = ab, av = s.av, avn = av, share = T.tk.n > 0 and s.n / T.tk.n * 100 or 0 }
    end
    table.sort(rows, function(a, b) if a.n ~= b.n then return a.n > b.n end; return a.who < b.who end)
    local o = {}; for i = 1, math.min(nmax or 8, #rows) do o[i] = rows[i] end
    return o, T
end

-- ---------------------------------------------------------------- 6 resists + 7 efficiency (your casts and what came of them)
local function res_add(sp, mob, landed)
    if not sp or sp == '' then return end
    local key = (tostring(sp):gsub('%.$', ''))
    local r = S.res.sp[key]; if not r then r = { land = 0, res = 0 }; S.res.sp[key] = r end
    if landed then r.land = r.land + 1 else r.res = r.res + 1 end
    if mob and mob ~= '' then
        local m = S.res.mob[mob]; if not m then m = { land = 0, res = 0, sp = {} }; S.res.mob[mob] = m end
        if landed then m.land = m.land + 1 else m.res = m.res + 1 end
        local ms = m.sp[key]; if not ms then ms = { land = 0, res = 0 }; m.sp[key] = ms end
        if landed then ms.land = ms.land + 1 else ms.res = ms.res + 1 end
    end
    M._res_dirty = M._res_dirty or (C.now() + 5000)
end
M.res_add = res_add
local function eff_of(sp)
    local key = (tostring(sp):gsub('%.$', ''))
    local e = S.eff[key]; if not e then e = { casts = 0, dmg = 0, hits = 0, mana = nil, endur = nil, src = nil }; S.eff[key] = e end
    return e
end
local function cast_start(sp, now)
    if not sp or sp == '' then return end
    sp = (tostring(sp):gsub('%.$', ''))
    local info = M.spell(sp)
    local ct = (info and info.ct and info.ct > 0) and info.ct or 0
    -- the previous cast with no outcome yet: it finished (EQ prints a resist / interrupt / "did not take hold" otherwise)
    for _, p in ipairs(M.pend) do if not p.done and not p.fail then p.done = 'complete' end end
    M.pend[#M.pend + 1] = { sp = sp, t0 = now, ct = ct, tgt = target_name(), info = info }
    while #M.pend > 6 do table.remove(M.pend, 1) end
    local e = eff_of(sp); e.casts = e.casts + 1
    if info then e.mana = info.mana; e.src = info.src end
    if info and info.fd then M.fd_attempt(sp, now + ct) end
end
local function latest_pending(sp)
    for i = #M.pend, 1, -1 do
        local p = M.pend[i]
        if not p.fail and (not sp or lower(p.sp) == lower(sp)) then return p end
    end
end
local function cast_fail(now)
    local p = M.pend[#M.pend]
    if p and not p.done and not p.fail and now - p.t0 < (p.ct or 0) + 1500 then
        p.fail = true
        local e = S.eff[p.sp]; if e and e.casts > 0 then e.casts = e.casts - 1 end   -- interrupted / fizzled: not a finished cast
    end
end
-- 7: damage of yours by spell name; unnamed spell hits (RoF2 "You hit X for N points of non-melee damage.") belong to the
-- cast that just finished
function M.spell_of(ev, now)
    if ev.sp and ev.sp ~= '' then return (tostring(ev.sp):gsub('%.$', '')) end
    if ev.cat ~= 'spell' then return nil end
    for i = #M.pend, 1, -1 do
        local p = M.pend[i]
        if not p.fail and now >= p.t0 + (p.ct or 0) - 1500 and now <= p.t0 + (p.ct or 0) + 3000 then return p.sp end
    end
    return nil
end
function M.eff_rows()
    local rows = {}
    for sp, e in pairs(S.eff) do
        if e.casts > 0 and (e.dmg > 0 or (e.mana or 0) > 0) then
            local spent = (e.mana or 0) * e.casts
            rows[#rows + 1] = { sp = sp, casts = e.casts, dmg = e.dmg, mana = e.mana, spent = spent, dpm = spent > 0 and e.dmg / spent or nil,
                per = e.dmg / e.casts, src = e.src, endur = e.endur }
        end
    end
    table.sort(rows, function(a, b)
        if (a.dpm ~= nil) ~= (b.dpm ~= nil) then return a.dpm ~= nil end
        if a.dpm and b.dpm and a.dpm ~= b.dpm then return a.dpm > b.dpm end
        return a.dmg > b.dmg
    end)
    return rows
end
function M.res_rows(kind, nmax)
    local src = kind == 'mob' and S.res.mob or S.res.sp
    local rows = {}
    for k, r in pairs(src) do local n = r.land + r.res; if n > 0 then rows[#rows + 1] = { k, r.land, r.res, r.res / n * 100, n, r.sp } end end
    table.sort(rows, function(a, b) if a[5] ~= b[5] then return a[5] > b[5] end; return a[1] < b[1] end)
    local o = {}; for i = 1, math.min(nmax or 10, #rows) do o[i] = rows[i] end
    return o
end
-- resist book file: config\combatfx_resists_<server>_<char>.txt  "S<TAB>spell<TAB>landed<TAB>resisted" / "M<TAB>mob<TAB>..."
function M.res_path()
    local mq = mq_()
    local server = C.str(function() return mq.TLO.EverQuest.Server() end, 'server'):gsub('[^%w]', '')
    return string.format('%s/combatfx_resists_%s_%s.txt', mq.configDir or '.', server, C.CHAR or 'char')
end
function M.res_save()
    local f = io.open(M.res_path(), 'w'); if not f then return false end
    for k, r in pairs(S.res.sp) do f:write('S\t', k, '\t', r.land, '\t', r.res, '\n') end
    for k, r in pairs(S.res.mob) do
        f:write('M\t', k, '\t', r.land, '\t', r.res, '\n')
        for s2, r2 in pairs(r.sp or {}) do f:write('X\t', k, '\t', s2, '\t', r2.land, '\t', r2.res, '\n') end
    end
    f:close(); M._res_dirty = nil; return true
end
function M.res_load()
    local f = io.open(M.res_path(), 'r'); if not f then return false end
    for l in f:lines() do
        local t, k, a, b, c = l:match('^(%u)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t?([^\t]*)$')
        if t == 'S' then S.res.sp[k] = { land = tonumber(a) or 0, res = tonumber(b) or 0 }
        elseif t == 'M' then local m = S.res.mob[k] or { sp = {} }; m.land, m.res = tonumber(a) or 0, tonumber(b) or 0; S.res.mob[k] = m
        elseif t == 'X' then local m = S.res.mob[k] or { land = 0, res = 0, sp = {} }; S.res.mob[k] = m; m.sp[a] = { land = tonumber(b) or 0, res = tonumber(c) or 0 } end
    end
    f:close(); return true
end

-- ---------------------------------------------------------------- 1 / 3 DoTs on targets (from the tick lines + TLOs)
local function dot_key(t, sp) return lower(t) .. '|' .. lower(sp) end
function M.dot_tick(ev, now)
    local sp = (tostring(ev.sp or 'DoT'):gsub('%.$', ''))
    local k = dot_key(ev.tgt, sp)
    local d = M.dots[k]
    if not d or now > (d.ends or 0) + 7000 then
        d = { tgt = ev.tgt, sp = sp, first = now, ticks = 0, dmg = 0, src = 'est' }
        local info = M.spell(sp)
        if info and info.ticks and info.ticks > 0 then d.ends = now + info.ticks * 6000; d.total = info.ticks; d.src = 'est'
        else d.ends = now + 18000; d.src = '?' end
        M.dots[k] = d
        -- 6: a DoT that ticks landed
        local p = latest_pending(sp); if p and not p.done then p.done = 'landed'; res_add(sp, ev.tgt, true) end
    end
    d.last, d.ticks, d.dmg = now, d.ticks + 1, d.dmg + (ev.n or 0)
    if d.ends < now then d.ends = now + 3000 end
    local fd = F and F.dots
    if fd then
        local x = fd[sp]; if not x then x = { n = 0, ticks = 0, crits = 0, max = 0, owner = ev.who }; fd[sp] = x end
        x.n, x.ticks = x.n + (ev.n or 0), x.ticks + 1; if ev.crit then x.crits = x.crits + 1 end; if (ev.n or 0) > x.max then x.max = ev.n end
    end
end
-- "Your Chaos Venom spell has worn off of Test Dummy Two."
function M.worn_off(sp, rest, now)
    local t = tostring(rest or ''):match('^ of (.-)%.?$')
    if not t then return false end
    local d = M.dots[dot_key(t, sp)]
    if d then M.dots[dot_key(t, sp)] = nil; return true end
    return false
end
function M.mob_died(name)
    local l = lower(name)
    for k, d in pairs(M.dots) do if lower(d.tgt) == l then M.dots[k] = nil end end
end
-- live: the target's buff window (Target.MyBuff / MyBuffDuration, only your own casts) corrects the estimates
function M.poll_target(now)
    local mq = mq_()
    local tn = target_name()
    if tn == '' then return end
    local n = C.num(function() return mq.TLO.Target.MyBuffCount() end, 0) or 0
    for i = 1, math.min(n, 30) do
        local sp = C.str(function() return mq.TLO.Target.MyBuff(i).Spell.Name() end, nil)
        local secs = C.num(function() return mq.TLO.Target.MyBuffDuration(i).TotalSeconds() end, nil)
        if sp and secs then
            local k = dot_key(tn, sp)
            local d = M.dots[k]
            if not d then d = { tgt = tn, sp = sp, first = now, ticks = 0, dmg = 0, debuff = true }; M.dots[k] = d end
            d.ends, d.src, d.seen = now + secs * 1000, 'target buffs', now
        end
    end
end
-- rows: DoTs / debuffs still running (soonest first), seconds left
function M.dot_rows(now, only_tgt)
    now = now or C.now()
    local rows = {}
    for k, d in pairs(M.dots) do
        if now > (d.ends or 0) + 6500 then M.dots[k] = nil
        elseif not only_tgt or lower(d.tgt) == lower(only_tgt) then
            rows[#rows + 1] = { sp = d.sp, tgt = d.tgt, left = math.max(0, ((d.ends or now) - now) / 1000), ticks = d.ticks, dmg = d.dmg, src = d.src, total = d.total }
        end
    end
    table.sort(rows, function(a, b) return a.left < b.left end)
    return rows
end
-- 1: DoT about to drop (once per application)
function M.dot_warn(now)
    if not (M.cfg().dots and C.cfg.alerts.dot) then return end
    local thr = C.clamp(tonumber(M.cfg().dot_warn) or 4, 1, 20)
    for _, d in pairs(M.dots) do
        local left = ((d.ends or 0) - now) / 1000
        if not d.warned and left > 0 and left <= thr and d.ticks > 0 and d.src ~= '?' then
            d.warned = true
            local FX = package.loaded['combatfx.fx']
            if FX then FX.alert('dot', d.sp, string.format('%ds left on %s', math.ceil(left), M.trunc(d.tgt, 16)), '#c8a0ff') end
        end
    end
end
function M.trunc(s, n) s = tostring(s or ''); if #s <= n then return s end; return s:sub(1, n - 1) .. '…' end

-- ---------------------------------------------------------------- 1 buffs (TLO, 1 Hz while something shows them)
M.buffs = {}
function M.poll_buffs(now)
    local mq = mq_()
    local out = {}
    local slots = C.num(function() return mq.TLO.Me.MaxBuffSlots() end, 30) or 30
    for i = 1, math.min(slots, 42) do
        local nm = C.str(function() return mq.TLO.Me.Buff(i).Name() end, nil)
        if nm then
            local s = C.num(function() return mq.TLO.Me.Buff(i).Duration.TotalSeconds() end, nil)
            if s and s > 0 then out[#out + 1] = { nm, s } end
        end
    end
    for i = 1, 20 do
        local nm = C.str(function() return mq.TLO.Me.Song(i).Name() end, nil)
        if nm then local s = C.num(function() return mq.TLO.Me.Song(i).Duration.TotalSeconds() end, nil); if s and s > 0 then out[#out + 1] = { nm, s, true } end end
    end
    M.set_buffs(out, now)
end
-- pure: list of { name, secs, song } -> M.buffs soonest first, with the longest duration seen (for the bar)
local bmax = {}
function M.set_buffs(list, now)
    local b = {}
    for _, x in ipairs(list) do
        local m = x[4]                                           -- explicit max (previews) never touches the real table
        if not m then m = bmax[x[1]]; if not m or x[2] > m then bmax[x[1]] = x[2]; m = x[2] end end
        b[#b + 1] = { name = x[1], left = x[2], max = m, song = x[3] }
    end
    table.sort(b, function(a, c) return a.left < c.left end)
    M.buffs, M.buffs_t = b, now
    return b
end

-- ---------------------------------------------------------------- 3 feign death (attempt -> Me.Feigning; 1456 = failed)
M.fd = { pend = nil, feigning = false, last = nil }
function M.fd_attempt(sp, ready) M.fd.pend = { sp = sp, ready = ready } end
local function fd_flash(ok, sub)
    M.fd.last = { ok = ok, sub = sub, t = C.now() }
    if not (M.cfg().fd and C.cfg.alerts.fd) then return end
    local FX = package.loaded['combatfx.fx']
    if FX then FX.alert('fd', ok and 'FEIGN DEATH' or 'FEIGN FAILED', sub or '', ok and '#6aff8a' or '#ff5040') end
end
M.fd_flash = fd_flash
function M.fd_state(feigning, now)
    local f = M.fd
    if feigning and not f.feigning then fd_flash(true, f.pend and f.pend.sp or 'you are feigned'); f.pend = nil
    elseif f.pend and now > f.pend.ready + 2500 and not feigning then fd_flash(false, (f.pend.sp or '') .. ' · still standing'); f.pend = nil end
    f.feigning = feigning
end

-- ---------------------------------------------------------------- 2 mob cast / action warnings (world-anchored)
local cast_list, cast_list_src = {}, nil
function M.cast_list()
    local src = M.cfg().cast_list or ''
    if src ~= cast_list_src then cast_list_src = src; cast_list = FT.list(src) end
    return cast_list
end
local ACT_WORD = { gate = 'GATING', enrage = 'ENRAGED', ['wild rampage'] = 'WILD RAMPAGE', rampage = 'RAMPAGE', flurry = 'FLURRY', frenzy = 'FRENZY' }
-- returns the matching list entry or nil. Entries match spell names / actions by part of the name; 'AE' matches a spell
-- the mob book learned as an AE (same mob's spell hitting you and someone else within 1.5 s)
function M.dangerous(who, sp, act)
    local L = M.cast_list()
    local s, a = lower(sp), lower(act)
    for _, e in ipairs(L) do
        if e == 'ae' then
            local PS = package.loaded['combatfx.parses']
            local m = PS and PS.mobs()[lower(who)]
            local ab = m and sp and m.ab[sp]
            -- learned AEs already warn from Parses > Warnings when that is on: no second callout for the same cast
            local ps_on = PS and PS.cfg().mobwarn and C.cfg.alerts.mob
            if ab and ab.aoe and not ps_on then return 'AE' end
        elseif (s ~= '' and s:find(e, 1, true)) or (a ~= '' and a:find(e, 1, true)) then return e end
    end
    return nil
end
local function is_friend(name)
    local l = lower(name)
    if l == '' then return false end
    local PS = package.loaded['combatfx.parses']
    local fr = PS and PS.friends() or {}
    if fr[l] then return true end
    local A = package.loaded['combatfx.addons']
    return A and A.is_group and A.is_group(name) or false
end
local recent_warn = {}
local function is_pc(name)
    if M._debug_pc then return M._debug_pc(name) end
    local mq = mq_()
    return (C.num(function() return mq.TLO.SpawnCount('pc =' .. name)() end, 0) or 0) > 0
end
-- melee actions (rampage / flurry / frenzy) come every few seconds on a fight: one warning per mob per 15 s;
-- casts / gate / enrage: per 4 s. A flurry only counts when it lands on you or your group.
M.ACT_REPEAT, M.CAST_REPEAT = 15000, 4000
local MELEE_ACT = { rampage = true, ['wild rampage'] = true, flurry = true, frenzy = true }
function M.on_warn(who, sp, act, now, tgt_name)
    if not (M.cfg().castwarn and C.cfg.alerts.cast) and not FT.forced('alert.cast') then return false end
    if is_friend(who) or lower(who) == lower(C.CHAR) then return false end
    if act == 'flurry' and tgt_name and not (lower(tgt_name) == lower(C.CHAR) or tgt_name == 'YOU' or is_friend(tgt_name)) then return false end
    local hit = M.dangerous(who, sp, act)
    if not hit then return false end
    local key = lower(who) .. '|' .. lower(sp or act)
    if recent_warn[key] and now - recent_warn[key] < (MELEE_ACT[act] and M.ACT_REPEAT or M.CAST_REPEAT) then return false end
    if is_pc(who) then return false end                           -- players gate / frenzy too
    recent_warn[key] = now
    local title = (act and ACT_WORD[act]) or tostring(sp or ''):upper()
    M._last_warn = { who = who, sp = sp, act = act, t = now, title = title }
    local sub = sp and (who .. ' casting') or who
    return M.show_label('cast', title, sub, act == 'gate' and '#80e0ff' or '#ff4030', who, 3.2)
end
function M.reset_warn() recent_warn = {} end

-- events.lua: skip the learned-book warning (parses.lua) for a cast this module just showed
function M.warned_now(who, sp)
    local w = M._last_warn
    return w ~= nil and w.sp ~= nil and lower(w.who) == lower(who) and lower(w.sp) == lower(sp) and C.now() - w.t < 1500
end
-- world label above a spawn: placed every frame while it lasts; when the mob is off screen, behind the camera or the
-- label would touch the no-draw box round you, the warning goes into the alert slots beside you instead.
M.WL_W, M.WL_H = 230, 44
local function spawn_of(name)
    if M._debug_spawn then return M._debug_spawn(name) end
    local mq = mq_()
    if lower(name) == lower(target_name()) and tgt.id ~= 0 then
        return tgt.id, C.num(function() return mq.TLO.Target.Height() end, 6)
    end
    local id = C.num(function() return mq.TLO.Spawn('npc =' .. name).ID() end, 0)
    if not id or id == 0 then return nil end
    return id, C.num(function() return mq.TLO.Spawn('id ' .. id).Height() end, 6)
end
M.spawn_of = spawn_of
function M.head_xy(id, h)
    local CV = package.loaded['combatfx.canvas']
    if M._debug_head then return M._debug_head(id, h) end
    if not (CV and CV.spawn_head_xy) then return nil end
    local ok, x, y = pcall(CV.spawn_head_xy, id, h)
    if ok then return x, y end
end
-- rectangle of the label for a head point, or nil when it would be over you / off screen. Tries: centred over the
-- head; slid sideways (up to 100 px, the stem stays on the mob) to clear the no-draw box round you; lifted up to 140 px.
-- r[5] = stem x inside the label (points at the mob)
function M.label_rect(x, y, sw, sh)
    local w, hh = M.WL_W, M.WL_H
    local fx, fy, ux, uy, span, _, wmul = FT.capsule()
    local b = { FT.body_box(fx, fy, ux, uy, span, wmul) }
    local function fits(r) return r[1] >= 4 and r[3] <= sw - 4 and r[2] >= 4 and r[4] <= sh - 4 and not FT.overlap(r, b) end
    local function mk(dx, dy)
        local x1, y1 = math.floor(x - w / 2 + dx), math.floor(y - hh - 10 - dy)
        return { x1, y1, x1 + w, y1 + hh, math.floor(C.clamp(x - x1 - 1, 10, w - 12)) }
    end
    local r = mk(0, 0)
    if fits(r) then return r end
    local cands = {}
    if x >= (b[1] + b[3]) / 2 then cands[#cands + 1] = b[3] + 2 - (x - w / 2) else cands[#cands + 1] = b[1] - 2 - (x + w / 2) end
    for _, dx in ipairs(cands) do
        if math.abs(dx) <= 100 then local r2 = mk(dx, 0); if fits(r2) then return r2 end end
    end
    local up = r[4] - b[2] + 6
    if up > 0 and up <= 140 then local r3 = mk(0, up); if fits(r3) then return r3 end end
    return nil
end
local wl_next = 1
function M.show_label(k, title, sub, color, who, dur)
    local FX = package.loaded['combatfx.fx']
    if not FX then return false end
    local world = (k == 'cast' and M.cfg().cast_world) or (k == 'spawn' and M.cfg().spawn_world)
    local id, h
    if world then id, h = spawn_of(who) end
    local x, y = nil, nil
    if id then x, y = M.head_xy(id, h) end
    local sw, sh = C.screen()
    local r = x and M.label_rect(x, y, sw, sh)
    if r and FX.wlabel then
        local slot = wl_next; wl_next = wl_next % 3 + 1
        M.labels[slot] = { id = id, h = h, t_end = C.now() + dur * 1000, title = title, rect = r, k = k }
        FX.wlabel(slot, title, sub, color, r[1], r[2], dur, r[5])
        return 'world'
    end
    return FX.alert(k, title, sub, color) and 'beside' or false
end
-- follow the mob while the label shows (20 Hz, diffed writes)
local lab_next = 0
function M.labels_frame(now)
    if now < lab_next then return end
    lab_next = now + 50
    local FX = package.loaded['combatfx.fx']
    local sw, sh = C.screen()
    for slot, L in pairs(M.labels) do
        if now > L.t_end then M.labels[slot] = nil; if FX and FX.wlabel_hide then FX.wlabel_hide(slot) end
        else
            local x, y = M.head_xy(L.id, L.h)
            local r = x and M.label_rect(x, y, sw, sh)
            if r then L.rect = r; if FX and FX.wlabel_move then FX.wlabel_move(slot, r[1], r[2], r[5]) end
            elseif FX and FX.wlabel_hide then FX.wlabel_hide(slot); M.labels[slot] = nil end
        end
    end
end

-- ---------------------------------------------------------------- 9 named / listed spawns (1 Hz scan)
M.seen = {}
local zone_id, first_scan = nil, true
local function list_hit(name, list)
    local l = lower(name)
    for _, e in ipairs(list) do if e ~= '' and l:find(e, 1, true) then return e end end
end
-- pure step: spawns = { { id, name, lvl, dist, named } }; returns the new ones worth an alert
function M.spawn_step(spawns, now, zid)
    local c = M.cfg()
    if zid ~= zone_id then zone_id = zid; M.seen = {}; first_scan = true end
    local want, ign = FT.list(c.spawn_list), FT.list(c.spawn_ignore)
    local new, cur = {}, {}
    for _, s in ipairs(spawns) do
        local listed = list_hit(s.name, want)
        if (listed or (c.spawn_named and s.named)) and not list_hit(s.name, ign) then
            cur[s.id] = true
            if not M.seen[s.id] then
                M.seen[s.id] = { name = s.name, t = now }
                new[#new + 1] = { id = s.id, name = s.name, lvl = s.lvl, dist = s.dist, listed = listed ~= nil }
            else M.seen[s.id].t = now end
        end
    end
    for id, e in pairs(M.seen) do if not cur[id] and now - e.t > 30000 then M.seen[id] = nil end end
    local was_first = first_scan; first_scan = false
    return new, was_first
end
function M.scan_spawns(now)
    local mq = mq_()
    local out, ids = {}, {}
    local function add(s)
        local id = C.num(function() return s.ID() end, 0)
        if id and id > 0 and not ids[id] then
            ids[id] = true
            local seen = M.seen[id]
            if seen then out[#out + 1] = { id = id, name = seen.name, named = true }; return end   -- known: one TLO call, not five
            out[#out + 1] = { id = id, name = C.str(function() return s.CleanName() end, '?'), lvl = C.num(function() return s.Level() end, 0),
                dist = C.num(function() return s.Distance() end, 0), named = C.safe(function() return s.Named() end) == true }
        end
    end
    if M.cfg().spawn_named then
        local n = C.num(function() return mq.TLO.SpawnCount('npc named')() end, 0) or 0
        for i = 1, math.min(n, 24) do local s = mq.TLO.NearestSpawn(i, 'npc named'); if s then add(s) end end
    end
    if #FT.list(M.cfg().spawn_list) > 0 then
        for i = 1, 40 do
            local s = mq.TLO.NearestSpawn(i, 'npc')
            local id = s and C.num(function() return s.ID() end, 0) or 0
            if id == 0 then break end
            if list_hit(C.str(function() return s.CleanName() end, ''), FT.list(M.cfg().spawn_list)) then add(s) end
        end
    end
    return out, C.num(function() return mq.TLO.Zone.ID() end, 0)
end
function M.on_spawns(new, first)
    if #new == 0 then return end
    local c = M.cfg()
    -- ps1: card (alerts.spawn) and sound (spawn_sound) are separate switches in Parses > Settings
    local card, snd = c.spawn and C.cfg.alerts.spawn, c.spawn and c.spawn_sound and c.spawn_sound ~= 'off'
    if not (card or snd) then return end
    local FX = package.loaded['combatfx.fx']
    if not card then FX = nil end
    if first then
        -- zoning in: one summary, not a wall of alerts
        local names = {}; for i = 1, math.min(3, #new) do names[i] = new[i].name end
        if FX then FX.alert('spawn', #new == 1 and new[1].name or (#new .. ' named up'), M.trunc(table.concat(names, ', '), 34), '#ffd040') end
    else
        for i = 1, math.min(2, #new) do
            local s = new[i]
            if card then
                M.show_label('spawn', s.name, string.format('%s · lvl %d · %d ft', s.listed and 'LISTED' or 'NAMED', s.lvl or 0, math.floor(s.dist or 0)), '#ffd040', s.name, 4.5)
                M.spawn_glow(s)
            end
        end
    end
    if snd then FT.play(c.spawn_sound) end
    M.last_spawn = { new = new, t = C.now() }
end
-- the DX11 part: a gold glow + ring at the mob (only on screen, outside the no-draw box, particles on)
function M.spawn_glow(s)
    local CV = package.loaded['combatfx.canvas']
    local FXm = package.loaded['combatfx.fx']; if FXm and FXm.cards_on and not FXm.cards_on() then return false end   -- ps1: All cards off
    if not (CV and C.particles_on() and not C.cfg.lite and C.cfg.fx.dx11) then return false end
    local id, h = spawn_of(s.name)
    local x, y = nil, nil
    if id then x, y = M.head_xy(id, h) end
    if not x then return false end
    local sw, sh = C.screen()
    if not M.label_rect(x, y + M.WL_H, sw, sh) then return false end
    pcall(function() CV.glow_at(x, y, 1.0, 0.80, 0.30, 34, 800) end)
    pcall(function() CV.shockwave(x, y, 1.0, 0.80, 0.30) end)
    return true
end

-- ---------------------------------------------------------------- 4 group share (pets folded into their owners)
M._petmap = {}                                           -- [pet lower] = owner name (Group.Member(i).Pet, 1 Hz)
function M.owner_of(name)
    local l = lower(name)
    if M._petmap[l] then return M._petmap[l] end
    local o = tostring(name or ''):match('^(.-)`s %a+$')
    return o
end
-- ---------------------------------------------------------------- 8 session rates
function M.sample_xp(lvl, pct, aapts, aapct)
    local TR = package.loaded['combatfx.tracker']
    local delta = TR and TR.delta or function() return 0 end
    if S.lvl then
        local d = delta(S.lvl, S.pct, lvl, pct); S.tlo_xp = S.tlo_xp + d
        local a = delta(S.aapts, S.aapct, aapts, aapct); S.tlo_aa = S.tlo_aa + a
    end
    S.lvl, S.pct, S.aapts, S.aapct = lvl, pct, aapts, aapct
end
function M.session_rates(now)
    now = now or C.now()
    local h = math.max((now - S.t0) / 3600000, 1 / 3600)
    local xp = S.xp_pct > 0 and S.xp_pct or S.tlo_xp                -- the server's own "(7.076%)" lines first
    local r = { hours = h, mins = (now - S.t0) / 60000, kills = S.kills, kph = S.kills / h, xp = xp, xph = xp / h, xp_src = S.xp_pct > 0 and 'chat' or 'Me.PctExp',
        aa = S.tlo_aa, aah = S.tlo_aa / h, aapts = S.aa, coin = S.coin.corpse + S.coin.split, cph = (S.coin.corpse + S.coin.split) / h, reward = S.coin.reward,
        items = S.items, iph = S.items / h, deaths = S.deaths, lvl = S.lvl, pct = S.pct }
    if r.xph > 0 and S.pct then r.ttl = (100 - S.pct) / r.xph * 60 end   -- minutes
    local TR = package.loaded['combatfx.tracker']
    if TR and TR.loot_totals then local tv, ti, t0 = TR.loot_totals(); if tv and tv > 0 and t0 then r.lval = tv; r.lvph = tv / math.max((now - t0) / 3600000, 1 / 3600) end end
    return r
end

-- ---------------------------------------------------------------- 10 death recap breakdown (PS.death_data rows)
-- d.hits = { ago, who, ability, n, cat } newest first -> sources by damage with their abilities
function M.death_breakdown(d)
    local by = {}
    for _, h in ipairs(d.hits or {}) do
        local who = h[2] ~= '' and h[2] or 'Unknown'
        local s = by[who]; if not s then s = { who = who, n = 0, hits = 0, ab = {} }; by[who] = s end
        s.n, s.hits = s.n + (h[4] or 0), s.hits + 1
        local an = h[3] ~= '' and h[3] or (h[5] or 'hit')
        local a = s.ab[an]; if not a then a = { an, 0, 0, 0 }; s.ab[an] = a end
        a[2], a[3] = a[2] + (h[4] or 0), a[3] + 1; if (h[4] or 0) > a[4] then a[4] = h[4] end
    end
    local rows = {}
    for _, s in pairs(by) do
        local ab = {}; for _, a in pairs(s.ab) do ab[#ab + 1] = a end
        table.sort(ab, function(x, y) return x[2] > y[2] end)
        s.ablist = ab; s.share = (d.taken or 0) > 0 and s.n / d.taken * 100 or 0
        rows[#rows + 1] = s
    end
    table.sort(rows, function(a, b) return a.n > b.n end)
    return rows
end

-- ---------------------------------------------------------------- EQ log file hint
-- <EQ folder>\Logs\eqlog_<Char>_<Server>.txt must grow while chat lines arrive; else EQ logging is off (/log on)
M.logst = { state = 'unknown', size = nil, t = -1e9, lines = 0 }
function M.log_path()
    local ok, PT = pcall(require, 'combatfx.paths')
    local eq = ok and PT.eq_dir and PT.eq_dir() or nil
    if not eq then return nil end
    local mq = mq_()
    local server = C.str(function() return mq.TLO.EverQuest.Server() end, nil)
    if not server or not C.CHAR then return nil end
    return PT.join(eq, 'Logs\\eqlog_' .. C.CHAR .. '_' .. server .. '.txt')
end
function M.file_size(p)
    if M._debug_size then return M._debug_size(p) end
    local f = p and io.open(p, 'rb'); if not f then return nil end
    local n = f:seek('end'); f:close(); return n
end
-- pure-ish step: lines = chat lines CombatFX has seen so far (events.lua M.lines)
function M.log_step(now, lines)
    local L = M.logst
    if now - L.t < 15000 then return L.state end
    local p = M.log_path()
    local sz = p and M.file_size(p) or nil
    local new_lines = (lines or 0) - (L.lines or 0)
    if not p then L.state = 'noeq'
    elseif not sz then L.state = (new_lines > 0) and 'missing' or L.state
    elseif L.size and sz > L.size then L.state = 'growing'
    elseif L.size and sz == L.size and new_lines >= 5 then L.state = 'still' end
    L.size, L.t, L.lines, L.path = sz, now, lines or 0, p
    return L.state
end
M.LOG_HINT = 'EQ is not writing its log file (eqlog_<char>_<server>.txt). CombatFX reads chat directly and works without it; type /log on if you also want the file (for other parsers or checking these numbers).'
function M.log_hint()
    local s = M.logst.state
    if s == 'still' or s == 'missing' then return M.LOG_HINT end
    return nil
end

-- ================================================================ event feed (events.lua M.one)
function M.fight_start(now) F = fight_new(now) end
function M.fight_end(now)
    if F then F.t1 = now; LAST = F end
    F = nil
end
function M.on_ev(ev, now)
    if not M.cfg().on or not ev then return end
    if sim() and not M._allow_sim then return end
    local k = ev.k
    if k == 'dmg' then
        if ev.who == 'pet' and F then
            local slot = ev.cat == 'melee' and F.pet.melee or (ev.cat == 'ds' and F.pet.ds or F.pet.spell)
            slot[1], slot[2] = slot[1] + (ev.n or 0), slot[2] + 1; if ev.crit then slot[3] = slot[3] + 1 end; if (ev.n or 0) > slot[4] then slot[4] = ev.n end
            if ev.cat == 'melee' then F.pet.swings = F.pet.swings + 1 end
        end
        if ev.cat == 'dot' and (ev.who == 'me' or ev.who == 'pet') and ev.tgt then M.dot_tick(ev, now) end
        if ev.who == 'me' and (ev.cat == 'spell' or ev.cat == 'dot') then
            local sp = M.spell_of(ev, now)
            if sp then
                local e = eff_of(sp); e.dmg, e.hits = e.dmg + (ev.n or 0), e.hits + 1
                if ev.cat == 'spell' then
                    local p = latest_pending(sp)
                    if p and not p.done then p.done = 'landed'; res_add(sp, ev.tgt or p.tgt, true) end
                end
            end
        end
    elseif k == 'inc' then
        if F then taken_add(F, ev) end
        taken_add(S.taken, ev)
    elseif k == 'swing_in' then
        if F then avoid_add(F, ev) end
        avoid_add(S.taken, ev)
    elseif k == 'swing_pet' then
        if F then F.pet.swings = F.pet.swings + 1; F.pet.miss = F.pet.miss + 1 end
    elseif k == 'absorb' then
        if F then F.absorbed = F.absorbed + (ev.n or 0) end
        S.taken.absorbed = S.taken.absorbed + (ev.n or 0)
    elseif k == 'cast' then cast_start(ev.sp, now)
    elseif k == 'activate' then
        local info = M.spell(ev.sp)
        if info and info.fd then M.fd_attempt(ev.sp, now + 300) end
        local en = M.endurance(ev.sp); if en and en > 0 then local e = eff_of(ev.sp); e.casts = e.casts + 1; e.endur = en end
    elseif k == 'resist_out' then
        local p = latest_pending(ev.sp)
        if p then p.done = 'resisted' end
        res_add(ev.sp or (p and p.sp), ev.tgt or (p and p.tgt) or target_name(), false)
    elseif k == 'nohold' then
        local p = M.pend[#M.pend]; if p and not p.done then p.done = 'nohold' end
    elseif k == 'ocast' then
        if ev.sp and ev.sp ~= '' then M.on_warn(ev.who, ev.sp, nil, now) end
    elseif k == 'mobact' then
        if ev.act ~= 'enrage_end' then M.on_warn(ev.who, nil, ev.act, now, ev.tgt) end
    elseif k == 'fd_fail' then M.fd.pend = nil; fd_flash(false, 'you fell to the ground')
    elseif k == 'fd_break' then M.fd.last = { ok = false, sub = 'broken: ' .. tostring(ev.why), t = now }
        if M.cfg().fd and C.cfg.alerts.fd then local FX = package.loaded['combatfx.fx']; if FX then FX.alert('fd', 'FEIGN BROKEN', M.trunc('because ' .. tostring(ev.why), 30), '#ffb040') end end
    elseif k == 'coin' then bump(S.coin, ev.src, ev.cp or 0)
    elseif k == 'xp' then S.xp_lines = S.xp_lines + 1; if ev.pct then S.xp_pct = S.xp_pct + ev.pct; S.xp_n = S.xp_n + (ev.n or 0) end
    elseif k == 'aapt' then S.aa = S.aa + (ev.n or 1)
    elseif k == 'died' then S.deaths = S.deaths + 1
    end
end
-- records that are not parse events (events.lua handlers): kills, loot, worn off, interrupts
function M.on_rec(r, now)
    if not M.cfg().on or not r then return end
    if sim() and not M._allow_sim then return end
    local k = r.k
    if k == 'cast' then cast_start(r.sp, now)                    -- handler path (parser did not take the line)
    elseif k == 'died' then S.deaths = S.deaths + 1
    elseif k == 'aa' then S.aa = S.aa + 1
    elseif k == 'kill' then S.kills = S.kills + 1; M.mob_died(r.who)
    elseif k == 'killby' then M.mob_died(r.who)
    elseif k == 'loot' then S.items = S.items + 1
    elseif k == 'wornoff' then M.worn_off(r.sp, r.rest, now)
    elseif k == 'castfail' then cast_fail(now)
    end
end

-- ================================================================ frame (ImGui) + slow loop
local nxt_fast, nxt_1, nxt_buff, nxt_scan = 0, 0, 0, 0
function M.panel_wanted(now)
    local c = M.cfg()
    if not c.on or c.panel == 'off' then return false end
    if c.panel == 'always' then return true end
    local E = package.loaded['combatfx.events']
    if E and E.stats and E.stats.fight_t0 then return true end
    for _, d in pairs(M.dots) do if (d.ends or 0) > now then return true end end
    local thr = FT.buff_threshold and FT.buff_threshold() or 15
    for _, b in ipairs(M.buffs) do if b.left <= thr and b.max >= 60 then return true end end
    return false
end
function M.frame(now)
    now = now or C.now()
    if not M.cfg().on or not C.cfg.master then return end
    M.labels_frame(now)
    if now < nxt_fast then return end
    nxt_fast = now + 250
    local mq = mq_()
    local E = package.loaded['combatfx.events']
    if not sim() then
        -- feign death: Me.Feigning (MQ spawn member) at 4 Hz
        local fe = C.safe(function() return mq.TLO.Me.Feigning() end) == true
        if fe ~= M.fd.feigning or M.fd.pend then M.fd_state(fe, now) end
    end
    M.dot_warn(now)
    -- finished casts with no damage / resist line: completed (mana spent, nothing to rate)
    for _, p in ipairs(M.pend) do if not p.done and not p.fail and now > p.t0 + (p.ct or 0) + 6000 then p.done = 'complete' end end
    if now >= nxt_1 then
        nxt_1 = now + 1000
        if not sim() then
            if M.cfg().dots or M.cfg().panel ~= 'off' then C.guard('track target', M.poll_target, now) end
            local lvl = C.num(function() return mq.TLO.Me.Level() end, nil)
            if lvl then M._level = lvl end
            local pct = C.num(function() return mq.TLO.Me.PctExp() end, nil)
            if lvl and pct then M.sample_xp(lvl, pct, C.num(function() return mq.TLO.Me.AAPointsTotal() end, nil), C.num(function() return mq.TLO.Me.PctAAExp() end, nil)) end
            -- group pets for the share view
            local n = C.num(function() return mq.TLO.Group.Members() end, 0) or 0
            local pm = {}
            for i = 1, n do
                local o = C.str(function() return mq.TLO.Group.Member(i).CleanName() end, nil)
                local p = o and C.str(function() return mq.TLO.Group.Member(i).Pet.CleanName() end, nil)
                if p and p ~= 'NO PET' then pm[lower(p)] = o end
            end
            M._petmap = pm
        end
        if M._res_dirty and now >= M._res_dirty then C.guard('resist save', M.res_save) end
        M.log_step(now, E and E.lines or 0)
    end
    local UIm = package.loaded['combatfx.ui']
    local want = M.panel_wanted(now) or (UIm and UIm._tracking_open and UIm._tracking_open())
    if now >= nxt_buff and (want or M.cfg().panel ~= 'off') then
        nxt_buff = now + (want and 1000 or 5000)                  -- 0.2 Hz idle check finds buffs about to fade
        if not sim() then C.guard('track buffs', M.poll_buffs, now) end
    end
    if M.cfg().spawn and now >= nxt_scan and not sim() then
        nxt_scan = now + (#FT.list(M.cfg().spawn_list) > 0 and 2000 or 1000)
        local list, zid = M.scan_spawns(now)
        local new, first = M.spawn_step(list, now, zid)
        M.on_spawns(new, first)
    end
    M.panel_frame(now)
end
-- on-screen panel (2 Hz, diffed): buffs fading, DoTs on the target, pet share
local pn_next = 0
function M.panel_frame(now)
    if now < pn_next then return end
    pn_next = now + 500
    if (M._preview_panel or 0) > now then return end            -- a Preview owns the panel for a few seconds
    local FX = package.loaded['combatfx.fx']
    if not (FX and FX.track_panel) then return end
    if not M.panel_wanted(now) or C.cfg.lite then FX.track_panel(nil); return end
    local TU = require('combatfx.trackui')
    local html, h = TU.panel_html(M, now)
    FX.track_panel(html, h)
end
-- main-loop step (outside the ImGui frame): reads the spell file a few hundred lines at a time
local slow_next = 0
function M.slow(now)
    now = now or C.now()
    if DB.state == 'idle' and now > 8000 + (M._t_load or 0) then M.db_open() end
    if DB.state == 'loading' and now >= slow_next then slow_next = now; M.db_step(600) end
end
function M.init()
    M._t_load = C.now()
    M.reset_session(C.now())
    pcall(M.res_load)
end

-- ================================================================ sandbox (previews + tests never touch your real numbers)
function M._swap(st)
    local old = { S = S, F = F, LAST = LAST, dots = M.dots, pend = M.pend, fd = M.fd, buffs = M.buffs, seen = M.seen, labels = M.labels }
    S, F, LAST = st.S, st.F, st.LAST
    M.dots, M.pend, M.fd, M.buffs, M.seen, M.labels = st.dots, st.pend, st.fd, st.buffs, st.seen, st.labels
    return old
end
function M.sandbox(fn)
    local fresh = { dots = {}, pend = {}, fd = { pend = nil, feigning = false }, buffs = {}, seen = {}, labels = {} }
    local old = M._swap(fresh)
    M.reset_session(C.now())
    local was = M._allow_sim; M._allow_sim = true
    local ok, a, b = pcall(fn)
    M._allow_sim = was
    M._swap(old)
    if not ok then return nil, a end
    return a, b
end
-- real-format lines (Mychar's log, TOB client): a necro fight with pet hits and two DoTs, run through the real parser
M.PREVIEW_LINES = {
    'You begin casting Chaos Venom.',
    'a training dummy has taken 312 damage from your Chaos Venom.',
    'You begin casting Dread Pyre.',
    'a training dummy has taken 845 damage from your Dread Pyre.',
    'Mychar`s pet hits a training dummy for 154 points of damage.',
    'Mychar`s pet kicks a training dummy for 98 points of damage.',
    'a training dummy has taken 312 damage from your Chaos Venom.',
}
function M.preview_panel_html(now)
    return M.sandbox(function()
        local P = require('combatfx.parse')
        local par = P.new(function() return 'Mychar' end, function() return 'Mychar`s pet' end)
        local saved_t = M._debug_target; M._debug_target = 'a training dummy'
        M.fight_start(now - 12000)
        for i, l in ipairs(M.PREVIEW_LINES) do
            for _, ev in ipairs(par:classify(l, now - 12000 + i * 1500) or {}) do M.on_ev(ev, now - 12000 + i * 1500) end
        end
        M.set_buffs({ { 'Spirit of Wolf', 11, nil, 2160 }, { 'Shadow Armor', 48, nil, 1800 }, { 'Major Shielding', 96, nil, 2700 } }, now)
        local TU = require('combatfx.trackui')
        local d = TU.collect(M, now)
        d.title = 'PREVIEW &#183; practice lines'
        d.dots = M.dot_rows(now)
        local html, h = TU.panel_from(d)
        M._debug_target = saved_t
        return html, h
    end)
end

-- ================================================================ previews (Preview buttons only; real-format lines)
-- each one runs the real parser on chat lines in the formats seen in real logs and draws what the live path draws
M.PREVIEW = {
    cast = { 'a raging minotaur begins to cast a spell. (Complete Heal)', 'a raging minotaur goes on a WILD RAMPAGE!' },
    fd_ok = true, fd_fail = true, spawn = true, dot = true,
}
function M.preview(kind)
    local FX = package.loaded['combatfx.fx']
    local E = package.loaded['combatfx.events']
    local now = C.now()
    if kind == 'cast' then
        FT.force('alert.cast', 3000)
        M.reset_warn()
        local who = target_name() ~= '' and target_name() or 'a raging minotaur'
        local line = who .. ' begins to cast a spell. (Complete Heal)'
        local P = require('combatfx.parse')
        local evs = P.new(function() return C.CHAR end):classify(line, now) or {}     -- lc1: own parser, never the live one (held lines)
        for _, ev in ipairs(evs) do if ev.k == 'ocast' then
            local saved = M.cfg().cast_list; if not M.dangerous(ev.who, ev.sp) then M.cfg().cast_list = saved .. '; Complete Heal' end
            local r = M.on_warn(ev.who, ev.sp, nil, now); M.cfg().cast_list = saved; return r end end
        return false
    elseif kind == 'fd_ok' then FT.force('alert.fd', 3000); fd_flash(true, 'preview · you are feigned'); return true
    elseif kind == 'fd_fail' then FT.force('alert.fd', 3000); fd_flash(false, 'preview · you fell to the ground'); return true
    elseif kind == 'spawn' then
        FT.force('alert.spawn', 3000)
        local who = target_name() ~= '' and target_name() or 'Lord Bob the Unending'
        local r = M.show_label('spawn', who, 'preview · NAMED · lvl 70 · 120 ft', '#ffd040', who, 4.5)
        if M.cfg().spawn_sound ~= 'off' then FT.play(M.cfg().spawn_sound) end
        M.spawn_glow({ name = who })
        return r
    elseif kind == 'dot' then
        FT.force('alert.dot', 3000)
        return FX and FX.alert('dot', 'Chaos Venom', 'preview · 3s left on ' .. (target_name() ~= '' and M.trunc(target_name(), 14) or 'a training dummy'), '#c8a0ff')
    elseif kind == 'panel' then
        local html, h = M.preview_panel_html(now)
        if not (FX and FX.track_panel and html) then return false end
        M._preview_panel = now + 6000
        FX.track_panel(html, h)
        return true
    end
end
return M
