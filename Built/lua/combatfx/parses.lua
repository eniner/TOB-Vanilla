-- combatfx/parses.lua (f8b): parse history + compare, group / raid meter, spell timeline strip, death recap, mob
-- ability warnings and parse export. Everything is built from combatfx.parse events (real chat lines) and real TLOs:
--   history  config\combatfx_parses_<server>_<char>.txt   one JSON object per fight, newest last, rotated at cfg.keep
--   mobs     config\combatfx_mobs_<server>_<char>.txt      what each mob did to you (learned from real lines only)
-- Files are read with a small JSON reader (data only; nothing in them is ever run).
local C = require('combatfx.core')
local FT = require('combatfx.features')
local M = { REV = 'f8b' }
local mq = package.loaded['mq'] or {}

C.cfg.parses = { on = true, keep = 500, label = '', group = true, gmode = 'dmg', death = true, mobwarn = true, warn_pct = 25,
    gap = 3, burns = '', tl = true, lo = '', dkeep = 60 }
C.cfg.alerts = C.cfg.alerts or {}
if C.cfg.alerts.mob == nil then C.cfg.alerts.mob = true end
function M.cfg() return C.cfg.parses end

-- ---------------------------------------------------------------- JSON (data only)
local function jstr(s)
    return '"' .. tostring(s):gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' elseif c == '\\' then return '\\\\' elseif c == '\n' then return '\\n' elseif c == '\t' then return '\\t' end
        return string.format('\\u%04x', c:byte())
    end) .. '"'
end
local function is_array(t)
    local n = 0; for _ in pairs(t) do n = n + 1 end
    for i = 1, n do if t[i] == nil then return false end end
    return n > 0 or next(t) == nil
end
local function enc(v, depth)
    depth = depth or 0
    if depth > 12 then return 'null' end
    local tv = type(v)
    if tv == 'nil' then return 'null' end
    if tv == 'boolean' then return v and 'true' or 'false' end
    if tv == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then return '0' end
        if v == math.floor(v) and math.abs(v) < 1e15 then return string.format('%d', v) end
        return string.format('%.4g', v)
    end
    if tv == 'string' then return jstr(v) end
    if tv == 'table' then
        local o = {}
        if next(v) == nil then return '{}' end
        if is_array(v) then for i = 1, #v do o[i] = enc(v[i], depth + 1) end; return '[' .. table.concat(o, ',') .. ']' end
        local ks = {}; for k in pairs(v) do ks[#ks + 1] = tostring(k) end; table.sort(ks)
        for _, k in ipairs(ks) do
            if k:sub(1, 1) ~= '_' then                             -- fd1: _keys are memory only (a practice fight's detail)
                local x = v[k]; if x == nil then x = v[tonumber(k)] end; o[#o + 1] = jstr(k) .. ':' .. enc(x, depth + 1)
            end
        end
        return '{' .. table.concat(o, ',') .. '}'
    end
    return 'null'
end
M.json_encode = function(v) return enc(v, 0) end
local function dec(s)
    local i = 1
    local function ws() i = s:find('[^ \t\r\n]', i) or #s + 1 end
    local val
    local function str()
        local o, j = {}, i + 1
        while true do
            local c = s:sub(j, j)
            if c == '' then error('eof in string') end
            if c == '"' then i = j + 1; return table.concat(o) end
            if c == '\\' then
                local e = s:sub(j + 1, j + 1)
                if e == 'u' then o[#o + 1] = string.char(math.min(255, tonumber(s:sub(j + 2, j + 5), 16) or 63)); j = j + 6
                else o[#o + 1] = ({ n = '\n', t = '\t', r = '\r', b = '\b', f = '\f' })[e] or e; j = j + 2 end
            else o[#o + 1] = c; j = j + 1 end
        end
    end
    val = function(depth)
        if depth > 20 then error('too deep') end
        ws()
        local c = s:sub(i, i)
        if c == '{' then
            local t = {}; i = i + 1; ws()
            if s:sub(i, i) == '}' then i = i + 1; return t end
            while true do
                ws(); if s:sub(i, i) ~= '"' then error('key') end
                local k = str(); ws(); if s:sub(i, i) ~= ':' then error(':') end; i = i + 1
                t[k] = val(depth + 1); ws()
                local d = s:sub(i, i); i = i + 1
                if d == '}' then return t elseif d ~= ',' then error(',') end
            end
        elseif c == '[' then
            local t = {}; i = i + 1; ws()
            if s:sub(i, i) == ']' then i = i + 1; return t end
            while true do
                t[#t + 1] = val(depth + 1); ws()
                local d = s:sub(i, i); i = i + 1
                if d == ']' then return t elseif d ~= ',' then error(',]') end
            end
        elseif c == '"' then return str()
        elseif s:sub(i, i + 3) == 'true' then i = i + 4; return true
        elseif s:sub(i, i + 4) == 'false' then i = i + 5; return false
        elseif s:sub(i, i + 3) == 'null' then i = i + 4; return nil
        else
            local n = s:match('^-?%d+%.?%d*[eE]?[-+]?%d*', i)
            if not n or n == '' then error('value') end
            i = i + #n; return tonumber(n)
        end
    end
    local ok, r = pcall(val, 0)
    if ok then return r end
    return nil, r
end
M.json_decode = dec

function M.simulating() local E = package.loaded['combatfx.events']; return E ~= nil and E.sim_state ~= nil end

-- ---------------------------------------------------------------- files
local function server_char()
    local sv = C.str(function() return mq.TLO.EverQuest.Server() end, 'server'):gsub('[^%w]', '')
    return sv, tostring(C.CHAR or 'char'):gsub('[^%w]', '')
end
function M.path(kind)
    if M._path_override and M._path_override[kind] then return M._path_override[kind] end
    local sv, ch = server_char()
    return string.format('%s/combatfx_%s_%s_%s.txt', mq.configDir or '.', kind, sv, ch)
end

-- ---------------------------------------------------------------- history
local H, H_loaded = {}, false
function M.history()
    if H_loaded then return H end
    H_loaded, H = true, {}
    local f = io.open(M.path('parses'), 'r')
    if f then
        for l in f:lines() do
            if #l > 2 and #l < 200000 then local r = dec(l); if type(r) == 'table' and r.t then H[#H + 1] = r end end
        end
        f:close()
    end
    local keep = math.max(20, tonumber(M.cfg().keep) or 500)
    while #H > keep do table.remove(H, 1) end
    for i, r in ipairs(H) do r.id = r.id or i end
    return H
end
function M.reset_cache() H_loaded, H = false, {}; M._mobs = nil; if M._reset_detail then M._reset_detail() end end
local function rewrite()
    local f = io.open(M.path('parses'), 'w'); if not f then return false end
    for _, r in ipairs(H) do f:write(enc(r, 0), '\n') end
    f:close(); return true
end
M.rewrite = rewrite
local next_id = 0
local function new_id()
    local m = 0; for _, r in ipairs(H) do if (tonumber(r.id) or 0) > m then m = r.id end end
    next_id = math.max(next_id, m) + 1; return next_id
end
-- one fight -> a compact record (numbers + names only)
function M.build_record(st, secs, extra)
    extra = extra or {}
    local o = st.out or {}
    local function g(k, i) return (o[k] or {})[i] or 0 end
    local mob = extra.mob
    if not mob or mob == '' then mob = (st.tgts and st.tgts[1] and st.tgts[1][1]) or (st.attackers and st.attackers[1] and st.attackers[1][1]) or '' end
    local ab = {}
    for i = 1, math.min(10, #(st.abil or {})) do local a = st.abil[i]; ab[i] = { a.name, a.dmg, a.hits, a.crits, a.max } end
    local secs1 = math.max(1, tonumber(secs) or tonumber(st.secs) or 1)
    local you = st.you or 0
    local rec = { v = 1, t = extra.t or os.time(), zone = extra.zone or '', mob = mob, secs = secs1, label = extra.label or M.cfg().label or '',
        you = you, pet = g('pet', 1), dps = (you + g('pet', 1)) / secs1,
        out = { melee = { g('melee', 1), g('melee', 2), g('melee', 3), g('melee', 4) }, spell = { g('spell', 1), g('spell', 2), g('spell', 3), g('spell', 4) },
            dot = { g('dot', 1), g('dot', 2), g('dot', 3), g('dot', 4) }, ds = { g('ds', 1), g('ds', 2), g('ds', 3), g('ds', 4) }, pet = { g('pet', 1), g('pet', 2), g('pet', 3), g('pet', 4) } },
        inc = st.inc_total or 0, sw_in = st.sw_in or {}, sw_out = st.sw_out or {},
        hin = (st.heal_in or {})[1] or 0, hinc = (st.heal_in or {})[3] or 0, hinn = (st.heal_in or {})[2] or 0, hover = (st.heal_in or {})[4] or 0,
        hout = (st.heal_out or {})[1] or 0, houtn = (st.heal_out or {})[2] or 0, houtc = (st.heal_out or {})[3] or 0,
        healers = st.healers or {}, hspells = st.hspells or {}, attackers = st.attackers or {}, abil = ab,
        res_out = st.res_out or 0, res_in = st.res_in or 0, cripple = st.cripple or 0, special = st.special or {},
        group = M.group_rank(st, 6), tl = st.tl or {}, killed = extra.killed and true or false, died = extra.died }
    if extra.petname and extra.petname ~= '' then rec.petname = extra.petname end
    return rec
end
-- ---------------------------------------------------------------- fd1: fight detail (graphs, tables, event log)
-- config\combatfx_fights_<server>_<char>.txt: one line per fight, "<key><TAB><json>", newest last. Only the newest
-- cfg.dkeep fights keep their detail (the summary history keeps cfg.keep). A detail line is decoded only when that
-- fight is opened, so a long history costs nothing at load.
M.DETAIL_MAX_LINE = 600000
local DC, DC_order = {}, {}                                       -- decoded details, last 6 opened
local dlines = nil                                                -- lines in the detail file (counted once)
function M._reset_detail() DC, DC_order, dlines = {}, {}, nil end
local function dcache(k, d)
    if DC[k] == nil then DC_order[#DC_order + 1] = k end
    DC[k] = d
    while #DC_order > 6 do DC[table.remove(DC_order, 1)] = nil end
end
function M.dkeep() return math.max(5, math.min(500, tonumber(M.cfg().dkeep) or 60)) end
function M.save_detail(key, d)
    if not key or not d then return false end
    local line = enc(d, 0)
    if #line > M.DETAIL_MAX_LINE then                              -- never write a line the reader would skip: drop log rows first
        local keep = math.max(200, math.floor(#d.ev * (M.DETAIL_MAX_LINE * 0.8) / #line))
        for i = #d.ev, keep + 1, -1 do d.ev[i] = nil end
        d.cut = (d.cut or 0) + 1; d.trim = true
        line = enc(d, 0)
        if #line > M.DETAIL_MAX_LINE then return false end
    end
    dcache(key, d)
    local path = M.path('fights')
    if dlines == nil then
        dlines = 0
        local f = io.open(path, 'r'); if f then for _ in f:lines() do dlines = dlines + 1 end; f:close() end
    end
    local f = io.open(path, 'a'); if not f then return false end
    f:write(key, '\t', line, '\n'); f:close()
    dlines = dlines + 1
    if dlines > M.dkeep() + 10 then                                -- rotate in batches: raw line copy, nothing re-encoded
        local all = {}
        local r = io.open(path, 'r'); if r then for l in r:lines() do all[#all + 1] = l end; r:close() end
        local w = io.open(path, 'w')
        if w then for i = math.max(1, #all - M.dkeep() + 1), #all do w:write(all[i], '\n') end; w:close() end
        dlines = math.min(#all, M.dkeep())
    end
    return true
end
-- the detail of one history record: d, nil  or  nil, reason ('old' = saved before fight detail existed,
-- 'trimmed' = older than the newest dkeep fights, 'missing' = the line is gone or unreadable)
function M.detail(rec)
    if not rec then return nil, 'missing' end
    if rec._d then return rec._d end                               -- practice / current fight (memory only)
    local key = rec.dk
    if not key then return nil, 'old' end
    if DC[key] then return DC[key] end
    local f = io.open(M.path('fights'), 'r')
    if not f then return nil, 'trimmed' end
    local pre = key .. '\t'
    local found
    for l in f:lines() do if l:sub(1, #pre) == pre then found = l end end
    f:close()
    if not found then return nil, 'trimmed' end
    if #found > M.DETAIL_MAX_LINE then return nil, 'missing' end
    local d = dec(found:sub(#pre + 1))
    if type(d) ~= 'table' or type(d.ev) ~= 'table' then return nil, 'missing' end
    dcache(key, d)
    return d
end
M.DETAIL_WHY = {
    old = 'This fight was saved before CombatFX kept fight detail (graphs, tables and the event log start with fights from 2026-11-15). Only the summary above is stored for it.',
    trimmed = 'Detail for this fight was trimmed: only the newest fights keep graphs and the event log (set how many under Parses &gt; Export &gt; Fights with detail).',
    missing = 'The detail line for this fight is missing or unreadable in config\\combatfx_fights_&lt;server&gt;_&lt;char&gt;.txt.',
}
-- the fight in progress (or the one that just ended, before the next starts), never saved
function M.live_record()
    local FL = package.loaded['combatfx.fightlog']
    if not FL then return nil end
    local st = FT.stats_export()
    if (st.events or 0) == 0 then return nil end
    local secs = FT.st_secs()
    local r = M.build_record(st, secs, { mob = FT.enc_target and FT.enc_target() or nil, label = '' })
    r.id = -1; r.live = true
    r._d = FL.export(secs)
    if r._d and r._d.pet ~= '' then r.petname = r._d.pet end
    return r
end
function M.add_record(rec)
    M.history()
    rec.id = new_id()
    H[#H + 1] = rec
    local keep = math.max(20, tonumber(M.cfg().keep) or 500)
    if #H > keep then
        while #H > keep do table.remove(H, 1) end
        rewrite()
    else
        local f = io.open(M.path('parses'), 'a')
        if f then f:write(enc(rec, 0), '\n'); f:close() end
    end
    return rec
end
function M.by_id(id) for _, r in ipairs(M.history()) do if r.id == id then return r end end end
function M.set_label(id, label)
    local r = M.by_id(id); if not r then return false end
    r.label = tostring(label or ''):gsub('[%c]', ''):sub(1, 40); rewrite(); return true
end
function M.delete(id)
    M.history()
    for i, r in ipairs(H) do if r.id == id then table.remove(H, i); rewrite(); return true end end
    return false
end
-- filters: q = part of a mob or zone name (case-insensitive), days = 0 (all) / 1 / 7 / 30, label = exact tag or ''
function M.query(q, days, label, now_s)
    now_s = now_s or os.time()
    q = tostring(q or ''):lower()
    local out = {}
    local hist = M.history()
    for i = #hist, 1, -1 do
        local r = hist[i]
        local ok = true
        if q ~= '' and not (tostring(r.mob):lower():find(q, 1, true) or tostring(r.zone):lower():find(q, 1, true) or tostring(r.label):lower():find(q, 1, true)) then ok = false end
        if ok and (tonumber(days) or 0) > 0 and now_s - (r.t or 0) > days * 86400 then ok = false end
        if ok and label and label ~= '' and r.label ~= label then ok = false end
        if ok then out[#out + 1] = r end
    end
    return out
end
-- best DPS per mob (fights of at least min_secs)
function M.best(min_secs)
    min_secs = min_secs or 5
    local by = {}
    for _, r in ipairs(M.history()) do
        local k = tostring(r.mob or ''):lower()
        if k ~= '' then
            local b = by[k]; if not b then b = { mob = r.mob, n = 0, best = nil, last = 0 }; by[k] = b end
            b.n = b.n + 1; if (r.t or 0) > b.last then b.last = r.t end
            if (r.secs or 0) >= min_secs and (not b.best or r.dps > b.best.dps) then b.best = r end
        end
    end
    local o = {}
    for _, b in pairs(by) do if b.best then o[#o + 1] = b end end
    table.sort(o, function(a, b) if a.best.dps ~= b.best.dps then return a.best.dps > b.best.dps end; return a.mob < b.mob end)
    return o
end
-- side by side: rows { label, a, b, delta % (b vs a), fmt }
local function rate(n, d) return d > 0 and (n / d * 100) or 0 end
function M.compare(a, b)
    local function sw(r, k) local t = 0; for _, v in pairs(r.sw_in or {}) do t = t + v end; return rate((r.sw_in or {})[k] or 0, t) end
    local function crit(r, k) local o = (r.out or {})[k] or {}; return rate(o[3] or 0, o[2] or 0) end
    local function dmgk(r, k) return ((r.out or {})[k] or {})[1] or 0 end
    local rows = {
        { 'DPS (you + pet)', a.dps, b.dps, 'n' }, { 'Damage', (a.you or 0) + (a.pet or 0), (b.you or 0) + (b.pet or 0), 'n' }, { 'Seconds', a.secs, b.secs, 's' },
        { 'Melee', dmgk(a, 'melee'), dmgk(b, 'melee'), 'n' }, { 'Spells', dmgk(a, 'spell'), dmgk(b, 'spell'), 'n' }, { 'DoTs', dmgk(a, 'dot'), dmgk(b, 'dot'), 'n' },
        { 'Damage shield', dmgk(a, 'ds'), dmgk(b, 'ds'), 'n' }, { 'Pet', dmgk(a, 'pet'), dmgk(b, 'pet'), 'n' },
        { 'Melee crit %', crit(a, 'melee'), crit(b, 'melee'), 'p' }, { 'Spell crit %', crit(a, 'spell'), crit(b, 'spell'), 'p' },
        { 'Taken (DTPS)', (a.inc or 0) / math.max(1, a.secs), (b.inc or 0) / math.max(1, b.secs), 'n', nil, true },
        { 'Healed in (HPS)', (a.hin or 0) / math.max(1, a.secs), (b.hin or 0) / math.max(1, b.secs), 'n' },
        { 'Healing done (HPS)', (a.hout or 0) / math.max(1, a.secs), (b.hout or 0) / math.max(1, b.secs), 'n' },
        { 'Dodge %', sw(a, 'dodge'), sw(b, 'dodge'), 'p' }, { 'Parry %', sw(a, 'parry'), sw(b, 'parry'), 'p' }, { 'Block %', sw(a, 'block'), sw(b, 'block'), 'p' },
        { 'Riposte %', sw(a, 'riposte'), sw(b, 'riposte'), 'p' },
    }
    for _, r in ipairs(rows) do r[5] = (r[2] or 0) ~= 0 and ((r[3] - r[2]) / math.abs(r[2]) * 100) or nil end
    return rows
end

-- ---------------------------------------------------------------- group / raid meter
-- friends = group + raid member names (Group.Member(i).CleanName / Raid.Member(i).CleanName, refreshed 1 Hz)
local fr_c, fr_t = {}, -1e9
function M.friends()
    if M._friends then return M._friends end
    local now = C.now()
    if now - fr_t < 1000 then return fr_c end
    fr_t, fr_c = now, {}
    local A = package.loaded['combatfx.addons']
    if A and A.sim then for k, v in pairs(A.SIM_GROUP or {}) do fr_c[k] = v end; return fr_c end
    local n = C.num(function() return mq.TLO.Group.Members() end, 0)
    for i = 1, n do local nm = C.str(function() return mq.TLO.Group.Member(i).CleanName() end, nil); if nm then fr_c[nm:lower()] = nm end end
    local r = C.num(function() return mq.TLO.Raid.Members() end, 0)
    for i = 1, math.min(r, 72) do local nm = C.str(function() return mq.TLO.Raid.Member(i).CleanName() end, nil); if nm then fr_c[nm:lower()] = nm end end
    return fr_c
end
function M.friend_count() local n = 0; for _ in pairs(M.friends()) do n = n + 1 end; return n end
-- ranked lists for damage / healing / tanking. You (+ your pet) always included; others only when they are group or
-- raid members (no group: anyone who is not one of the mobs you fought).
function M.group_rank(st, nmax)
    nmax = nmax or 6
    local fr = M.friends()
    local have_fr = next(fr) ~= nil
    local en = st.enemies or {}
    local function ok(name)
        local l = tostring(name or ''):lower()
        if l == '' or l == 'you' then return false end
        return have_fr and fr[l] ~= nil                            -- solo: only you (+ pet); others need a group / raid
    end
    local function rank(map, mine)
        local t = {}
        if mine and mine > 0 then t[#t + 1] = { 'You', mine } end
        -- f10: a group member's pet ("Owner`s warder", or Group.Member(i).Pet) is credited to its owner (Tracking: pets fold)
        local TK = package.loaded['combatfx.track']
        local fold = TK and TK.cfg().gpets
        local acc, pets = {}, {}
        for k, v in pairs(map or {}) do
            local name = k
            if not ok(k) and fold then local o = TK.owner_of(k); if o and ok(o) then name = o; pets[(fr[o:lower()]) or o] = true end end
            if ok(name) then local n = (fr[tostring(name):lower()]) or name; acc[n] = (acc[n] or 0) + v end
        end
        for k, v in pairs(acc) do t[#t + 1] = { k, v, pets[k] } end
        table.sort(t, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end; return a[1] < b[1] end)
        local tot = 0; for _, r in ipairs(t) do tot = tot + r[2] end
        local o = {}; for i = 1, math.min(nmax, #t) do o[i] = t[i]; o[i].share = tot > 0 and t[i][2] / tot * 100 or 0; o[i].pet = t[i][3] end
        return o
    end
    local o = st.out or {}
    local mine = (st.you or 0) + ((o.pet or {})[1] or 0)
    return { dmg = rank(st.gdmg, mine), heal = rank(st.gheal and (function() local m = {}; for k, v in pairs(st.gheal) do if k ~= 'You' then m[k] = v end end; return m end)() or {}, (st.gheal or {}).You or ((st.heal_out or {})[1] or 0)),
        tank = rank(st.gtaken and (function() local m = {}; for k, v in pairs(st.gtaken) do if k ~= 'You' then m[k] = v end end; return m end)() or {}, st.inc_total or 0),
        others = (st.ghits or 0) > 0, friends = have_fr }
end
-- 'Others Hits' chat filter: EQ only prints other players' hits when that filter is on. Heuristic (no file holds the
-- filter state for us to read): grouped / raided, a fight of 20 s or more, and not one line of anybody else's damage.
function M.others_hint(st, secs)
    if (st.ghits or 0) > 0 then return false end
    if M.friend_count() == 0 then return false end
    return (tonumber(secs) or 0) >= 20
end
M.OTHERS_HINT = 'Turn on the chat filter "Others Hits" (Options > Chat > Filters) to see group and raid damage'

-- recap section: ranked damage bars + healing / tanking lines + the Others Hits hint
local GCOL = { '#ffb347', '#8ac8ff', '#c8a0ff', '#6aff8a', '#ff8a8a', '#ffe08a' }
function M.group_html(st, secs)
    if not M.cfg().group then return '' end
    local g = M.group_rank(st, 5)
    local h = {}
    local e, f = C.esc, C.fmt
    secs = math.max(1, secs or 1)
    if #g.dmg > 1 or g.others then
        local tot = 0; for _, r in ipairs(g.dmg) do tot = tot + r[2] end
        h[#h + 1] = string.format('<div class="rsec">%s DAMAGE <span class="dim">&#183; ranked by this parser</span></div>', M.friend_count() > 6 and 'RAID' or 'GROUP')
        local top = g.dmg[1] and g.dmg[1][2] or 1
        for i, r in ipairs(g.dmg) do
            h[#h + 1] = string.format('<div class="ab"><span class="abn">%d. %s</span><div class="abb"><div class="abf" style="width: %d%%; background-color: %s;"></div></div><span class="abv">%s &#183; %s dps &#183; %d%%</span></div>',
                i, e(r[1]), math.max(2, math.floor(r[2] / math.max(1, top) * 100 + 0.5)), r[1] == 'You' and '#ffd040' or GCOL[(i - 1) % #GCOL + 1], f(r[2]), f(r[2] / secs), math.floor(r[2] / math.max(1, tot) * 100 + 0.5))
        end
        local function line(lbl, list)
            if #list == 0 then return end
            local p = {}; for i = 1, math.min(3, #list) do p[#p + 1] = e(list[i][1]) .. ' ' .. f(list[i][2]) .. string.format(' (%d%%)', math.floor((list[i].share or 0) + 0.5)) end
            h[#h + 1] = '<div class="rl">' .. lbl .. ': ' .. table.concat(p, ' &#183; ') .. '</div>'
        end
        line('Healing', g.heal); line('Tanking (taken)', g.tank)
    end
    if M.others_hint(st, secs) then h[#h + 1] = '<div class="hint">No group hits seen: turn on chat filter "Others Hits"</div>' end
    return table.concat(h)
end
-- live panel: one ranked list (cfg.gmode = dmg | heal | tank), at most 6 rows
M.GM_MODES = { dmg = 'DAMAGE', heal = 'HEALING', tank = 'TANKING' }
function M.gm_html(st, secs, mode)
    mode = M.GM_MODES[mode] and mode or 'dmg'
    local g = M.group_rank(st, 6)
    local list = g[mode] or {}
    local e, f = C.esc, C.fmt
    secs = math.max(1, secs or 1)
    local h = { string.format('<span class="gmh">%s %s &#183; %ds</span>', M.friend_count() > 6 and 'RAID' or 'GROUP', M.GM_MODES[mode], math.floor(secs)) }
    local top = list[1] and list[1][2] or 1
    for i, r in ipairs(list) do
        h[#h + 1] = string.format('<div class="gmr"><span class="gmn">%d. %s</span><div class="gmb"><div class="gmf" style="width: %d%%; background-color: %s;"></div></div><span class="gmv">%s/s %d%%</span></div>',
            i, e(r[1]) .. (r.pet and '+pet' or ''), math.max(2, math.floor(r[2] / math.max(1, top) * 100 + 0.5)), r[1] == 'You' and '#ffd040' or GCOL[(i - 1) % #GCOL + 1], f(r[2] / secs), math.floor((r.share or 0) + 0.5))
    end
    local rows = #list
    if M.others_hint(st, secs) then h[#h + 1] = '<span class="gmx">Chat filter "Others Hits" looks off</span>'; rows = rows + 0.9 end
    return table.concat(h), math.floor(12 + 16 + rows * 16 + 0.5)
end
local gm_next = 0
function M.gm_tick(now)
    local FX = package.loaded['combatfx.fx']
    if not FX or not FX.group_meter then return end
    if now < gm_next then return end
    gm_next = now + 500
    local E = package.loaded['combatfx.events']
    local live = E and E.stats and E.stats.fight_t0
    local st = FT.stats()
    if not (M.cfg().group and live and st and (st.events or 0) > 0 and M.friend_count() > 0) or C.cfg.lite then FX.group_meter(nil); return end
    local x = FT.stats_export()
    local html, hh = M.gm_html(x, x.secs, M.cfg().gmode)
    FX.group_meter(html, hh)
end

-- ---------------------------------------------------------------- death recap: rings of HP samples + incoming / heals
local hp_ring, ev_ring = {}, {}
local hp_last = -1e9
function M.reset_hp() hp_ring, ev_ring, hp_last = {}, {}, -1e9 end
M.RING_MS = 15000
function M.sample_hp(now, pct, cur, max)
    if now - hp_last < 50 then return end                         -- every frame, at most 20 samples a second
    hp_last = now
    hp_ring[#hp_ring + 1] = { now, pct, cur, max }
    while hp_ring[1] and now - hp_ring[1][1] > M.RING_MS do table.remove(hp_ring, 1) end
end
function M.note(ev, now)
    local k = ev.k
    if k == 'inc' or k == 'heal_in' or k == 'swing_in' or k == 'absorb' then
        ev_ring[#ev_ring + 1] = { now, ev }
        while ev_ring[1] and now - ev_ring[1][1] > M.RING_MS do table.remove(ev_ring, 1) end
    end
    M.learn(ev, now)
end
function M.frame(now)
    now = now or C.now()
    M.tick(now)
    C.guard('group meter', M.gm_tick, now)
    if not (M.cfg().death or M.cfg().on) then return end
    local E = package.loaded['combatfx.events']
    local s = E and E.sim_state
    if s then M.sample_hp(now, s.hp, s.curhp or ((s.maxhp or 0) * (s.hp or 0) / 100), s.maxhp); return end
    if now - hp_last < 50 then return end                         -- throttle before touching TLOs
    local pct = C.num(function() return mq.TLO.Me.PctHPs() end, nil)
    if pct then M.sample_hp(now, pct, C.num(function() return mq.TLO.Me.CurrentHPs() end, 0), C.num(function() return mq.TLO.Me.MaxHPs() end, 0)) end
end
-- the last `win` ms before `now`: hits (newest first), heals, HP columns, killer
function M.death_data(by, now, win)
    win = win or 10000
    local hits, heals, taken, healed, avoid = {}, {}, 0, 0, 0
    local av, absorbed = {}, 0                                   -- f10: avoid kinds (miss / dodge / rune ...) + spellshield absorbed
    for i = #ev_ring, 1, -1 do
        local t, ev = ev_ring[i][1], ev_ring[i][2]
        if now - t <= win then
            local ago = (now - t) / 1000
            if ev.k == 'inc' then taken = taken + (ev.n or 0); hits[#hits + 1] = { ago, ev.who or '', ev.sp or (ev.flags and ev.flags[1] and (ev.verb or '') .. ' (' .. ev.flags[1] .. ')') or ev.verb or ev.cat or '', ev.n or 0, ev.cat }
            elseif ev.k == 'heal_in' then healed = healed + (ev.n or 0); heals[#heals + 1] = { ago, ev.who or '', ev.sp or '', ev.n or 0 }
            elseif ev.k == 'swing_in' then avoid = avoid + 1; av[ev.how or 'miss'] = (av[ev.how or 'miss'] or 0) + 1
            elseif ev.k == 'absorb' then absorbed = absorbed + (ev.n or 0) end
        end
    end
    local cols, N = {}, 40
    for c = 1, N do
        local tc = now - win + (c - 0.5) * win / N
        local best
        for _, s in ipairs(hp_ring) do if s[1] <= tc then best = s else break end end
        cols[c] = best and best[2] or nil
    end
    local kb = hits[1]
    local by_who = {}
    for _, h in ipairs(hits) do by_who[h[2]] = (by_who[h[2]] or 0) + h[4] end
    local top = FT.top_of(by_who, 3)
    return { by = by or (kb and kb[2]) or '', hits = hits, heals = heals, taken = taken, healed = healed, avoided = avoid, hp = cols, hpn = N,
        killing = kb, top = top, win = win, t = os.time(), av = av, absorbed = absorbed }
end
function M.death_html(d)
    local e, f = C.esc, C.fmt
    local h = {}
    h[#h + 1] = string.format('<span class="rh">DEATH RECAP &#183; last %ds</span>', math.floor(d.win / 1000))
    h[#h + 1] = string.format('<div class="rsum">Slain by <span class="rv">%s</span></div>', e(d.by ~= '' and d.by or 'unknown'))
    if d.killing then h[#h + 1] = string.format('<div class="rl">Killing blow: %s &#183; %s &#183; <span class="rv">%s</span></div>', e(d.killing[2]), e(d.killing[3]), f(d.killing[4])) end
    h[#h + 1] = string.format('<div class="rl">Taken <span class="rv">%s</span> &#183; healed %s &#183; avoided %d swings</div>', f(d.taken), f(d.healed), d.avoided)
    if #d.top > 0 then local p = {}; for _, t in ipairs(d.top) do p[#p + 1] = e(t[1]) .. ' ' .. f(t[2]) end; h[#h + 1] = '<div class="rl">From: ' .. table.concat(p, ' &#183; ') .. '</div>' end
    -- HP timeline (columns, % of max)
    local b = {}
    for i = 1, d.hpn or 40 do                                       -- holes = no sample yet (ipairs would stop there)
        local v = d.hp[i]
        local hh = v and math.max(1, math.floor(v * 0.44 + 0.5)) or 0
        local col = (v or 0) < 30 and '#ff5040' or ((v or 0) < 60 and '#ffb040' or '#6aff8a')
        b[#b + 1] = string.format('<div class="gb" style="left: %dpx; height: %dpx; background-color: %s;"></div>', (i - 1) * 8, hh, col)
    end
    h[#h + 1] = '<div class="rsec">YOUR HP <span class="dim">&#183; 100% top, -' .. math.floor(d.win / 1000) .. 's to death</span></div><div class="gr" style="height: 46px;">' .. table.concat(b) .. '</div>'
    -- f10: what you avoided (by kind) + rune / spellshield, then damage by source with its abilities
    local avs = {}
    for _, kk in ipairs({ 'miss', 'dodge', 'parry', 'block', 'riposte', 'rune', 'invuln' }) do if (d.av or {})[kk] then avs[#avs + 1] = d.av[kk] .. ' ' .. kk end end
    if #avs > 0 or (d.absorbed or 0) > 0 then
        h[#h + 1] = '<div class="rl dim">Avoided: ' .. (#avs > 0 and table.concat(avs, ', ') or 'none') .. ((d.absorbed or 0) > 0 and (' &#183; spellshield absorbed ' .. f(d.absorbed)) or '') .. '</div>'
    end
    local TK = package.loaded['combatfx.track']
    if TK and TK.death_breakdown and #d.hits > 0 then
        h[#h + 1] = '<div class="rsec">BY SOURCE</div>'
        for i, s in ipairs(TK.death_breakdown(d)) do
            if i > 3 then break end
            local ab = {}
            for j = 1, math.min(3, #s.ablist) do local a = s.ablist[j]; ab[#ab + 1] = e(a[1]) .. ' ' .. f(a[2]) .. (a[3] > 1 and (' (' .. a[3] .. ')') or '') end
            h[#h + 1] = string.format('<div class="rl">%s &#183; <span class="rv">%s</span> %d%% &#183; <span class="dim">%s</span></div>', e(s.who), f(s.n), math.floor(s.share + 0.5), table.concat(ab, ', '))
        end
    end
    h[#h + 1] = '<div class="rsec">LAST HITS</div>'
    for i = 1, math.min(7, #d.hits) do local x = d.hits[i]; h[#h + 1] = string.format('<div class="rl">-%.1fs &#183; %s &#183; %s &#183; <span class="rv">%s</span></div>', x[1], e(x[2]), e(x[3]), f(x[4])) end
    if #d.heals > 0 then
        h[#h + 1] = '<div class="rsec">HEALS</div>'
        for i = 1, math.min(3, #d.heals) do local x = d.heals[i]; h[#h + 1] = string.format('<div class="rl">-%.1fs &#183; %s%s &#183; +%s</div>', x[1], e(x[2]), x[3] ~= '' and (' &#183; ' .. e(x[3])) or '', f(x[4])) end
    end
    return table.concat(h)
end
M.last_death = nil
function M.on_died(by, now, preview)
    now = now or C.now()
    local d = M.death_data(by, now, 10000)
    if not preview and not M.simulating() then M.last_death = d; M.learn_death(d) else M.preview_death = d end
    if M.cfg().death then
        local FX = package.loaded['combatfx.fx']
        if FX and FX.death_recap then FX.death_recap(M.death_html(d), 15) end
    end
    return d
end

-- ---------------------------------------------------------------- mob ability warnings (learned from real lines)
-- mobs[name] = { n = fights, max = biggest single hit on you, maxpct = as % of your max HP, ab = { [ability] = { n, max, maxpct, aoe } } }
function M.mobs()
    if M._mobs then return M._mobs end
    M._mobs = {}
    local f = io.open(M.path('mobs'), 'r')
    if f then local s = f:read('*a') or ''; f:close(); local t = dec(s); if type(t) == 'table' then M._mobs = t end end
    return M._mobs
end
local mobs_dirty_at
function M.save_mobs() local f = io.open(M.path('mobs'), 'w'); if f then f:write(enc(M.mobs(), 0)); f:close() end; mobs_dirty_at = nil end
local mh_c, mh_t = 0, -1e9
local function maxhp()
    local E = package.loaded['combatfx.events']
    if E and E.sim_state then return tonumber(E.sim_state.maxhp) or 0 end
    if M._maxhp then return M._maxhp end
    local now = C.now()
    if now - mh_t > 2000 then mh_t = now; mh_c = C.num(function() return mq.TLO.Me.MaxHPs() end, mh_c) end   -- one TLO read per 2 s
    return mh_c
end
M.SUB_MAX = 36
local NOT_ABILITY = { Critical = true, ['Lucky Critical'] = true, ['Crippling Blow'] = true, ['Deadly Strike'] = true, Twincast = true, Lucky = true }
local recent_cast = {}
local function trunc(x, n) if #x <= n then return x end; x = x:sub(1, n - 3):gsub('[\128-\191]*$', ''):gsub('[\192-\255]$', ''); return x .. '…' end
M.trunc = trunc
local recent_spell = {}                                            -- [mob|spell] = { t, targets }
function M.learn(ev, now)
    if M.simulating() then return end                             -- practice lines never teach the mob book
    if ev.k == 'inc' and ev.who and ev.who ~= '' and (ev.cat == 'melee' or ev.cat == 'spell' or ev.cat == 'dot') then
        local db = M.mobs()
        local key = tostring(ev.who):lower()
        local m = db[key]; if not m then m = { name = ev.who, n = 0, max = 0, maxpct = 0, ab = {} }; db[key] = m end
        local mh = maxhp()
        local pct = mh > 0 and (ev.n / mh * 100) or 0
        if ev.n > (m.max or 0) then m.max = ev.n end
        if pct > (m.maxpct or 0) then m.maxpct = math.floor(pct * 10 + 0.5) / 10 end
        local ab = (ev.cat ~= 'melee' and ev.sp and ev.sp ~= '') and ev.sp or nil
        -- RoF2 names melee specials in a suffix: "A shadow beast hits YOU for 34947 points of damage. (Wild Rampage)"
        if not ab and ev.cat == 'melee' then for _, fl in ipairs(ev.flags or {}) do if not NOT_ABILITY[fl] then ab = fl; break end end end
        -- a spell hit without a name, within 5 s of that mob's "begins to cast a spell. (X)": X
        if not ab and ev.cat ~= 'melee' then local rc = recent_cast[key]; if rc and now - rc.t < 5000 and rc.sp ~= '' then ab = rc.sp end end
        if ab then
            local a = m.ab[ab]; if not a then a = { n = 0, max = 0, maxpct = 0 }; m.ab[ab] = a end
            a.n = a.n + 1; if ev.n > a.max then a.max = ev.n end
            if pct > a.maxpct then a.maxpct = math.floor(pct * 10 + 0.5) / 10 end
            local rk = key .. '|' .. ab:lower()
            local r = recent_spell[rk]
            if r and now - r.t < 1500 and r.others then a.aoe = true end
            recent_spell[rk] = { t = now, you = true, others = r and now - r.t < 1500 and r.others or false }
        end
        mobs_dirty_at = mobs_dirty_at or (now + 5000)
    elseif ev.k == 'ocast' and ev.who and ev.sp and ev.sp ~= '' then
        recent_cast[tostring(ev.who):lower()] = { sp = ev.sp, t = now }
    elseif ev.k == 'odmg' and ev.spell and ev.sp and ev.who then
        -- the same mob's same spell landing on someone else within 1.5 s of hitting you = an AE
        local rk = tostring(ev.who):lower() .. '|' .. tostring(ev.sp):lower()
        local r = recent_spell[rk]
        if r and now - r.t < 1500 and r.you then
            local m = M.mobs()[tostring(ev.who):lower()]
            local a = m and m.ab[ev.sp]; if a then a.aoe = true; mobs_dirty_at = mobs_dirty_at or (now + 5000) end
        end
        recent_spell[rk] = { t = now, you = r and r.you or false, others = true }
    end
end
function M.learn_death(d)
    local key = tostring(d.by or ''):lower()
    if key == '' then return end
    local m = M.mobs()[key]; if not m then m = { name = d.by, n = 0, max = 0, maxpct = 0, ab = {} }; M.mobs()[key] = m end
    m.kills = (m.kills or 0) + 1
    mobs_dirty_at = mobs_dirty_at or (C.now() + 2000)
end
function M.tick(now)
    now = now or C.now()
    if mobs_dirty_at and now >= mobs_dirty_at then M.save_mobs() end
end
-- the warning text for a mob, or nil when nothing it did reached the threshold
function M.mob_warning(name, thr)
    thr = thr or tonumber(M.cfg().warn_pct) or 25
    local m = M.mobs()[tostring(name or ''):lower()]
    if not m then return nil end
    local bits, worst = {}, m.maxpct or 0
    local abl = {}
    for an, a in pairs(m.ab or {}) do if (a.maxpct or 0) >= thr or a.aoe then abl[#abl + 1] = { an, a } end end
    table.sort(abl, function(x, y) return (x[2].maxpct or 0) > (y[2].maxpct or 0) end)
    if worst < thr and #abl == 0 and not (m.kills and m.kills > 0) then return nil end
    local sub = string.format('up to %d%% HP', math.floor(worst))
    if abl[1] then sub = sub .. ' · ' .. abl[1][1] .. (abl[1][2].aoe and ' AE' or '') end
    if m.kills and m.kills > 0 then sub = sub .. string.format(' · killed you %dx', m.kills) end
    sub = trunc(sub, M.SUB_MAX)
    return m.name or name, sub
end
function M.cast_warning(who, sp, thr)
    thr = thr or tonumber(M.cfg().warn_pct) or 25
    local m = M.mobs()[tostring(who or ''):lower()]
    local a = m and sp and m.ab[sp]
    if not a then return nil end
    if (a.maxpct or 0) < thr and not a.aoe then return nil end
    local sub = string.format('%s · up to %d%% HP', m.name or who, math.floor(a.maxpct or 0))
    sub = trunc(sub, M.SUB_MAX)
    return sp .. (a.aoe and ' (AE)' or ''), sub
end
local warned = {}
function M.on_engage(name, now)
    if not (M.cfg().mobwarn and C.cfg.alerts.mob) then return false end
    now = now or C.now()
    local t, sub = M.mob_warning(name)
    if not t then return false end
    local k = tostring(name):lower()
    if warned[k] and now - warned[k] < 30000 then return false end
    warned[k] = now
    local FX = package.loaded['combatfx.fx']
    return FX and FX.alert('mob', t, sub, '#ff7040') or false
end
-- settings preview: the strongest mob in your book (real learned data); a labelled sample when the book is empty
function M.preview_warning()
    local FX = package.loaded['combatfx.fx']
    if not FX then return false end
    local best, bk
    for k, m in pairs(M.mobs()) do if not best or (m.maxpct or 0) > (best.maxpct or 0) then best, bk = m, k end end
    if best then
        local t, sub = M.mob_warning(best.name or bk, 0)
        return FX.alert('mob', t or best.name, sub or 'learned', '#ff7040')
    end
    return FX.alert('mob', 'a raging minotaur', 'preview · up to 25% HP · Fire Breath AE', '#ff7040')
end
function M.on_ocast(who, sp, now)
    if not (M.cfg().mobwarn and C.cfg.alerts.mob) then return false end
    local t, sub = M.cast_warning(who, sp)
    if not t then return false end
    local FX = package.loaded['combatfx.fx']
    return FX and FX.alert('mob', t, sub, '#ff4030') or false
end

-- ---------------------------------------------------------------- fight end: history record (+ the recap's extra rows)
M.last = nil
function M.on_fight_end(secs, st, extra)
    if not M.cfg().on then return nil end
    st = st or FT.stats_export()
    if (st.events or 0) == 0 then return nil end
    local o = st.out or {}
    if (st.you or 0) + ((o.pet or {})[1] or 0) + (st.inc_total or 0) + ((st.heal_out or {})[1] or 0) <= 0 then return nil end   -- only others' hits / misses
    extra = extra or {}
    local FL = package.loaded['combatfx.fightlog']
    local d = FL and FL.export(secs) or nil                       -- fd1
    if d and d.pet ~= '' then extra.petname = d.pet end
    if M.simulating() then M.last_sim = M.build_record(st, secs, extra); M.last_sim.id = -2; M.last_sim._d = d; return nil end    -- practice fights stay out of the history
    extra.zone = extra.zone or C.str(function() return mq.TLO.Zone.ShortName() end, '')
    if M.last_death and os.time() - (M.last_death.t or 0) < 30 then extra.died = { by = M.last_death.by, taken = M.last_death.taken } end
    local rec = M.build_record(st, secs, extra)
    if d then rec.dk = string.format('%d-%04d', rec.t or os.time(), math.random(0, 9999)) end
    M.last = M.add_record(rec)
    if d then C.guard('fight detail', M.save_detail, rec.dk, d) end
    -- the mob counts as seen once per fight
    local m = M.mobs()[tostring(rec.mob):lower()]; if m then m.n = (m.n or 0) + 1 end
    return M.last
end

-- ---------------------------------------------------------------- export
-- EQ's chat input (CW_ChatInput) takes 512 characters, or 170 when the client limits it (eqgame sets the edit box
-- max to 0x200 or 0xAA); the EQ line is kept within 170 and plain ASCII.
M.EQ_MAX = 170
local function k(n) n = tonumber(n) or 0; if n >= 1e9 then return string.format('%.2fb', n / 1e9) elseif n >= 1e6 then return string.format('%.2fm', n / 1e6) elseif n >= 1e4 then return string.format('%.1fk', n / 1e3) end; return tostring(math.floor(n + 0.5)) end
local function ascii(s) return (tostring(s or ''):gsub('[^\32-\126]', '')) end
function M.export_eq(r)
    local crit = 0
    local o = r.out or {}
    local hits = ((o.melee or {})[2] or 0) + ((o.spell or {})[2] or 0) + ((o.dot or {})[2] or 0)
    local crits = ((o.melee or {})[3] or 0) + ((o.spell or {})[3] or 0) + ((o.dot or {})[3] or 0)
    if hits > 0 then crit = crits / hits * 100 end
    local top = r.abil and r.abil[1]
    local parts = {
        string.format('%s %ds: %s dmg %s dps', ascii(r.mob ~= '' and r.mob or 'fight'), math.floor(r.secs or 0), k((r.you or 0) + (r.pet or 0)), k(r.dps)),
        string.format('crit %d%%', math.floor(crit + 0.5)),
        (r.pet or 0) > 0 and ('pet ' .. k(r.pet)) or nil,
        top and string.format('top %s %d%%', ascii(top[1]), math.floor((top[2] or 0) / math.max(1, (r.you or 0) + (r.pet or 0)) * 100 + 0.5)) or nil,
        (r.inc or 0) > 0 and ('taken ' .. k(r.inc)) or nil,
        (r.hout or 0) > 0 and ('healed ' .. k(r.hout)) or nil,
        r.label and r.label ~= '' and ('[' .. ascii(r.label) .. ']') or nil,
    }
    local s = 'CFX ' .. parts[1]
    for i = 2, 7 do                                                -- parts has holes (nil = not in this fight)
        local p = parts[i]
        if p and #s + 3 + #p <= M.EQ_MAX then s = s .. ' | ' .. p end
    end
    if #s > M.EQ_MAX then s = s:sub(1, M.EQ_MAX) end
    return s
end
function M.export_detail(r)
    local f = C.fmt
    local L = {}
    local function add(x) L[#L + 1] = x end
    add(string.format('CombatFX parse - %s - %s - %s', r.mob ~= '' and r.mob or 'fight', r.zone ~= '' and r.zone or '?', os.date('%Y-%m-%d %H:%M', r.t or os.time())))
    if r.label and r.label ~= '' then add('Setup: ' .. r.label) end
    add(string.format('Duration %ds | Damage %s | DPS %s | Pet %s', math.floor(r.secs or 0), f((r.you or 0) + (r.pet or 0)), f(r.dps or 0), f(r.pet or 0)))
    local o = r.out or {}
    for _, kk in ipairs({ { 'melee', 'Melee' }, { 'spell', 'Spells' }, { 'dot', 'DoTs' }, { 'ds', 'Dmg shield' }, { 'pet', 'Pet' } }) do
        local v = o[kk[1]] or {}
        if (v[1] or 0) > 0 then add(string.format('  %-10s %12s  hits %4d  crit %3d%%  max %s', kk[2], f(v[1]), v[2] or 0, (v[2] or 0) > 0 and math.floor((v[3] or 0) / v[2] * 100 + 0.5) or 0, f(v[4] or 0))) end
    end
    if r.abil and #r.abil > 0 then
        add('Top abilities:')
        for i = 1, math.min(5, #r.abil) do local a = r.abil[i]; add(string.format('  %-24s %12s  %3d%%', a[1], f(a[2]), math.floor(a[2] / math.max(1, (r.you or 0) + (r.pet or 0)) * 100 + 0.5))) end
    end
    local tot = 0; for _, v in pairs(r.sw_in or {}) do tot = tot + v end
    add(string.format('Taken %s (%s dtps) | swings at you %d', f(r.inc or 0), f((r.inc or 0) / math.max(1, r.secs)), tot))
    if tot > 0 then
        local p = {}
        for _, kk in ipairs({ 'miss', 'dodge', 'parry', 'block', 'riposte', 'rune' }) do local v = (r.sw_in or {})[kk] or 0; if v > 0 then p[#p + 1] = string.format('%s %d%%', kk, math.floor(v / tot * 100 + 0.5)) end end
        if #p > 0 then add('  ' .. table.concat(p, ' | ')) end
    end
    add(string.format('Healing in %s (%s hps) | out %s (%s hps)', f(r.hin or 0), f((r.hin or 0) / math.max(1, r.secs)), f(r.hout or 0), f((r.hout or 0) / math.max(1, r.secs))))
    if r.group and r.group.dmg and #r.group.dmg > 1 then
        local p = {}; for _, g in ipairs(r.group.dmg) do p[#p + 1] = string.format('%s %s', g[1], f(g[2])) end
        add('Group damage: ' .. table.concat(p, ' | '))
    end
    if r.died then add('Died: slain by ' .. tostring(r.died.by or '?')) end
    return '```\n' .. table.concat(L, '\n') .. '\n```'
end
function M.copy(text)
    local ok = pcall(function() ImGui.SetClipboardText(text) end)
    return ok
end
M._enc, M._dec = enc, dec
return M
