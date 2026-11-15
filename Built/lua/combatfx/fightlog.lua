-- combatfx/fightlog.lua (fd1): per-fight detail for the Parses > fight view, built from the same combatfx.parse events
-- as the summary (features.st_add feeds it). Bounded: per-second sums per source / ability / heals / damage taken
-- (all events count), a chronological event log (first FL.EV_MAX events; the rest are counted, not kept), and
-- breakdown rows per (source, ability), per (attacker, ability) and per (healer / target, spell).
-- No UI, no TLO reads except the pet's name once per fight (Me.Pet.CleanName through the parser's cached function).
local FL = { REV = 'fd1' }
FL.EV_MAX = 4000            -- events kept per fight in the log (about 30 bytes each in the file)
FL.SEC_MAX = 3600           -- per-second sums stop growing past an hour (later seconds add to the last one)
FL.SER_PTS = 600            -- saved series are folded to at most this many points (2 s buckets past 10 minutes, ...)
FL.AB_MAX = 80              -- breakdown rows kept per table
FL.SRC_MAX = 12             -- damage sources with their own graph line (the rest add to 'Others')
FL.DOT_TICK = 6000          -- uptime: a DoT tick covers the 6 s before it (EQ ticks every 6 s)
local D
local function lower(s) return tostring(s or ''):lower() end
local function clean(s) return (tostring(s or ''):gsub('[%c]', ''):gsub('%.$', '')) end
local AVOID = { miss = true, dodge = true, parry = true, block = true, riposte = true, rune = true, invuln = true, other = true }

function FL.reset(now, engage)
    D = { t0 = engage or now or 0, first = nil, last = nil, names = {}, nidx = {}, ev = {}, cut = 0,
        ser = {}, smax = -1, ab = {}, aorder = {}, inc = {}, iorder = {}, heal = {}, horder = {}, av_in = {}, av_by = {},
        src = {}, sorder = {}, pet = nil, casts = 0 }
end
FL.reset(0, 0)
function FL.data() return D end
local function nid(s)
    s = tostring(s or '')
    local i = D.nidx[s]
    if not i then D.names[#D.names + 1] = s; i = #D.names; D.nidx[s] = i end
    return i
end
local function sec_of(now) local s = math.floor(((now or 0) - D.t0) / 1000); if s < 0 then s = 0 end; if s > FL.SEC_MAX then s = FL.SEC_MAX end; return s end
local function sadd(key, now, n)
    local t = D.ser[key]; if not t then t = {}; D.ser[key] = t end
    local s = sec_of(now)
    t[s] = (t[s] or 0) + n
    if s > D.smax then D.smax = s end
end
local function log(now, k, s, a, n, f, g)
    if #D.ev >= FL.EV_MAX then D.cut = D.cut + 1; return end
    local t = math.floor(((now or 0) - D.t0) / 100 + 0.5); if t < 0 then t = 0 end
    D.ev[#D.ev + 1] = { t, k, nid(s), a and nid(a) or 0, math.floor(tonumber(n) or 0), f or '', g and g ~= '' and nid(g) or 0 }
end
local function row(map, order, key, init)
    local r = map[key]
    if not r then
        if #order >= FL.AB_MAX then key = init.src .. '\1(other)'; r = map[key]; init.name = '(other)' end
        if not r then r = init; r.dmg, r.hits, r.crits, r.cdmg, r.max, r.min = 0, 0, 0, 0, 0, nil; map[key] = r; order[#order + 1] = key end
    end
    return r
end
local function bump(r, n, crit, now)
    r.dmg, r.hits = r.dmg + n, r.hits + 1
    if crit then r.crits, r.cdmg = r.crits + 1, r.cdmg + n end
    if n > r.max then r.max = n end
    if not r.min or n < r.min then r.min = n end
    if not r.first then r.first = now end
    r.last = now
end
local function pet_label()
    if D.pet == nil then
        local E = package.loaded['combatfx.events']
        local nm = E and E.parser and E.parser.pet_fn and E.parser.pet_fn() or ''
        D.pet = (nm and nm ~= '' and nm ~= 'NULL') and tostring(nm) or ''
    end
    return 'Pet'
end
local function src_of(ev)
    if ev.who == 'me' then return 'You' end
    if ev.who == 'pet' then return pet_label() end
    return tostring(ev.who or '?')
end
local function F() return package.loaded['combatfx.features'] end
local function melee_ab(verb) local f = F(); return f and f.melee_ability(verb) or 'Melee' end
-- the ability a damage event belongs to (pets get their own names: Melee, Kick, a proc spell, Damage shield)
function FL.ab_name(ev)
    if ev.cat == 'ds' then return 'Damage shield' end
    if ev.cat == 'melee' or (ev.verb and not ev.sp and not ev.spell) then return melee_ab(ev.verb) end
    if ev.sp and ev.sp ~= '' then return clean(ev.sp) end
    if ev.cat == 'dot' then return 'DoT (unnamed)' end
    return (ev.k == 'odmg' and not ev.spell) and 'Melee' or 'Spell (unnamed)'   -- TOB: "Mychar hit X for N points of non-melee damage." names no spell
end
local function srcrow(name)
    local s = D.src[name]
    if not s then s = { name = name, dmg = 0, hits = 0, crits = 0, max = 0 }; D.src[name] = s; D.sorder[#D.sorder + 1] = name end
    return s
end
local function flags(ev)
    local f = ''
    if ev.crit then f = f .. 'c' end
    if ev.cripple then f = f .. 'C' end
    if ev.special then f = f .. 'S' end
    if ev.hot then f = f .. 'o' end
    return f
end
function FL.add(ev, now)
    if not ev or not D then return end
    local k = ev.k
    local n = tonumber(ev.n) or 0
    if k == 'dmg' or k == 'odmg' or k == 'inc' or k == 'swing_in' or k == 'swing_out' or k == 'swing_pet' then
        if not D.first then D.first = now end
        if not D.last or now > D.last then D.last = now end
    end
    if k == 'dmg' or k == 'odmg' then
        local src = src_of(ev)
        local ab = FL.ab_name(ev)
        local cat = k == 'odmg' and (ev.spell and 'spell' or 'melee') or ev.cat
        local r = row(D.ab, D.aorder, src .. '\1' .. ab, { src = src, name = ab, cat = cat })
        bump(r, n, ev.crit, now)
        if cat == 'dot' then
            r.upt = (r.upt or 0) + math.min(FL.DOT_TICK, r.lt and (now - r.lt) or FL.DOT_TICK); r.lt = now
        end
        local s = srcrow(src); s.dmg, s.hits = s.dmg + n, s.hits + 1; if ev.crit then s.crits = s.crits + 1 end; if n > s.max then s.max = n end
        sadd('o\1' .. src, now, n)
        sadd('a\1' .. src .. '\1' .. ab, now, n)
        log(now, 'd', src, ab, n, flags(ev), ev.tgt)
    elseif k == 'swing_out' or k == 'swing_pet' then
        local src = k == 'swing_pet' and pet_label() or 'You'
        local ab = melee_ab(ev.verb)
        local r = row(D.ab, D.aorder, src .. '\1' .. ab, { src = src, name = ab, cat = 'melee' })
        local how = AVOID[ev.how] and ev.how or 'other'
        r[how] = (r[how] or 0) + 1
        log(now, 'm', src, ab, 0, how, ev.tgt)
    elseif k == 'resist_out' then
        local ab = clean(ev.sp)
        local r = row(D.ab, D.aorder, 'You\1' .. ab, { src = 'You', name = ab, cat = 'spell' })
        r.res = (r.res or 0) + 1
        log(now, 'r', 'You', ab, 0, '', ev.tgt)
    elseif k == 'inc' then
        local who = (ev.who and ev.who ~= '') and tostring(ev.who) or (ev.cat == 'env' and 'Environment' or 'Unknown')
        local ab = (ev.sp and ev.sp ~= '') and clean(ev.sp) or (ev.cat == 'melee' and melee_ab(ev.verb) or (ev.cat == 'ds' and 'Damage shield' or (ev.cat == 'dot' and 'DoT' or (ev.cat == 'env' and 'Environment' or 'Spell'))))
        local r = row(D.inc, D.iorder, who .. '\1' .. ab, { src = who, name = ab, cat = ev.cat })
        bump(r, n, ev.crit, now)
        sadd('i', now, n); sadd('i\1' .. who, now, n)
        log(now, 'i', who, ab, n, flags(ev))
    elseif k == 'swing_in' then
        local who = tostring(ev.who or 'Unknown')
        local how = AVOID[ev.how] and ev.how or 'other'
        D.av_in[how] = (D.av_in[how] or 0) + 1
        local m = D.av_by[who]; if not m then m = {}; D.av_by[who] = m end
        m[how] = (m[how] or 0) + 1
        log(now, 'a', who, 'Melee', 0, how)
    elseif k == 'heal_out' or k == 'heal_in' then
        if k == 'heal_in' and ev.self then return end           -- your self heal is already in heal_out (logged once)
        local out = k == 'heal_out'
        local who = out and 'You' or ((ev.who and ev.who ~= '') and tostring(ev.who) or 'Unknown')
        local tgt = out and tostring(ev.tgt or '?') or 'You'
        local sp = (ev.sp and ev.sp ~= '') and clean(ev.sp) or (ev.hot and 'Heal over time' or 'Heal')
        local r = row(D.heal, D.horder, (out and 'o' or 'i') .. '\1' .. who .. '\1' .. tgt .. '\1' .. sp, { src = who, name = sp, cat = out and 'out' or 'in', tgt = tgt })
        bump(r, n, ev.crit, now)
        r.over = (r.over or 0) + (tonumber(ev.over) or 0)
        if out then sadd('h', now, n) end
        if (not out) or ev.self then sadd('hi', now, n) end
        log(now, out and 'h' or 'H', who, sp, n, flags(ev), tgt)
    elseif k == 'cast' or k == 'activate' then
        D.casts = D.casts + 1
        log(now, 'c', 'You', clean(ev.sp), 0, k == 'activate' and 'aa' or '')
    elseif k == 'died' then
        log(now, 'x', 'You', 'Died', 0, '', ev.by)
    end
end
-- ---------------------------------------------------------------- export (plain data for the parse file)
local function fold(t, len, b)
    local o = {}
    for i = 1, len do o[i] = 0 end
    for s, v in pairs(t or {}) do local i = math.floor(s / b) + 1; if i > len then i = len end; o[i] = o[i] + v end
    return o
end
local function round(x) return math.floor((x or 0) + 0.5) end
-- secs = the summary's fight length (first to last swing); the graph runs over every second that had an event
function FL.export(secs)
    if not D then return nil end
    local S = math.max(1, D.smax + 1, math.ceil(tonumber(secs) or 1))
    S = math.min(S, FL.SEC_MAX + 1)
    local b = math.max(1, math.ceil(S / FL.SER_PTS))
    local len = math.ceil(S / b)
    local fight_ms = math.max(1000, (tonumber(secs) or 1) * 1000)
    local d = { v = 1, len = S, bs = b, pet = D.pet or '', names = D.names, ev = D.ev, cut = D.cut, src = {}, ab = {}, inc = {}, heal = {}, ser = {} }
    -- damage sources, biggest first; graph lines for the first SRC_MAX, the rest folded into 'Others'
    local so = {}
    for _, nm in ipairs(D.sorder) do so[#so + 1] = D.src[nm] end
    table.sort(so, function(x, y) return x.dmg > y.dmg end)
    local others
    for i, s in ipairs(so) do
        d.src[#d.src + 1] = { s.name, s.dmg, s.hits, s.crits, s.max }
        local key = 'o\1' .. s.name
        if i <= FL.SRC_MAX then d.ser[#d.ser + 1] = { 'o', s.name, '', fold(D.ser[key], len, b) }
        else
            others = others or {}
            for sec, v in pairs(D.ser[key] or {}) do others[sec] = (others[sec] or 0) + v end
        end
    end
    if others then d.ser[#d.ser + 1] = { 'o', 'Others', '', fold(others, len, b) } end
    local function rows(map, order, dst, extra)
        local t = {}
        for _, key in ipairs(order) do t[#t + 1] = map[key] end
        table.sort(t, function(x, y) if x.dmg ~= y.dmg then return x.dmg > y.dmg end; return tostring(x.name) < tostring(y.name) end)
        for _, r in ipairs(t) do
            local o = { s = r.src, n = r.name, c = r.cat, d = r.dmg, h = r.hits, k = r.crits, kd = r.cdmg, mx = r.max, mn = r.min or 0,
                f = r.first and round((r.first - D.t0) / 100) or 0, l = r.last and round((r.last - D.t0) / 100) or 0 }
            if extra then extra(r, o) end
            dst[#dst + 1] = o
        end
        return t
    end
    local abs = rows(D.ab, D.aorder, d.ab, function(r, o)
        for _, kk in ipairs({ 'miss', 'dodge', 'parry', 'block', 'riposte', 'rune', 'invuln', 'other', 'res' }) do if r[kk] then o[kk] = r[kk] end end
        if r.upt then o.up = math.min(100, round(r.upt / fight_ms * 100)) end
    end)
    -- per ability lines for the biggest 8 abilities (any source)
    local nab = 0
    for _, r in ipairs(abs) do
        if r.dmg > 0 and nab < 8 then nab = nab + 1; d.ser[#d.ser + 1] = { 'a', r.src, r.name, fold(D.ser['a\1' .. r.src .. '\1' .. r.name], len, b) } end
    end
    rows(D.inc, D.iorder, d.inc)
    rows(D.heal, D.horder, d.heal, function(r, o) o.t = r.tgt; o.o = r.over or 0 end)
    for _, kk in ipairs({ 'h', 'hi', 'i' }) do if D.ser[kk] then d.ser[#d.ser + 1] = { kk, '', '', fold(D.ser[kk], len, b) } end end
    -- the four biggest attackers get their own damage-taken line
    local at = {}
    for key, t in pairs(D.ser) do local who = key:match('^i\1(.+)$'); if who then local s = 0; for _, v in pairs(t) do s = s + v end; at[#at + 1] = { who, s, t } end end
    table.sort(at, function(x, y) if x[2] ~= y[2] then return x[2] > y[2] end; return x[1] < y[1] end)
    for i = 1, math.min(4, #at) do d.ser[#d.ser + 1] = { 'ia', at[i][1], '', fold(at[i][3], len, b) } end
    d.av = {}; for kk, v in pairs(D.av_in) do d.av[kk] = v end
    d.avby = {}; for who, m in pairs(D.av_by) do local c = {}; for kk, v in pairs(m) do c[kk] = v end; d.avby[who] = c end
    return d
end
return FL
