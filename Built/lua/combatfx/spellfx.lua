-- t470: Spell assignments for the native proc effects (Proc FX tab).
--   * every effect has a stable number: NEW effects #1..#100 (record id - 31744), Stock EQ records E<record id>
--   * a spell (or a proc / pet spell / DoT) can be given its own effect: when it lands, that effect plays on the
--     target (or on you); spells nobody assigned keep the Auto / picked look
--   * spells, procs, pet spells and DoTs seen in the log are listed so they can be assigned with one click
-- Saved per character in <config>/combatfx_spellfx_<server>_<char>.ini (the main ini is flat key=value only).
local C = require('combatfx.core')
local D = require('combatfx.proc_data')
local PF = require('combatfx.procfx')
local M = {}

M.MAX_SEEN = 80          -- remembered spells / procs (oldest dropped)
M.MAX_ASSIGN = 200
M.DEDUPE_MS = 1500       -- one landing = one effect (damage line + cast-end of the same spell)
M.WHERE = { 'auto', 'target', 'self' }

local function now() return C.now() end
local function trim(s) return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '')) end
function M.key(name) return trim(name):gsub('%.$', ''):lower() end
local function clean(name) return (trim(name):gsub('%.$', ''):gsub('[|\r\n]', '/')) end

-- ------------------------------------------------------------------ numbers
function M.num(id)
    id = tonumber(id) or 0
    local r = D.by_id[id]
    if r and r.custom then return '#' .. (id - D.CUSTOM_BASE) end
    if r then return 'E' .. id end
    return '?'
end
-- '#12' / '12' / 'n12' = NEW effect 12;  'e317' / '317' = Stock EQ record 317; anything else = name / tag / element search
function M.search(q, ok_custom)
    q = trim(q):lower()
    local out = {}
    if q == '' then return out end
    local nn = tonumber(q:match('^[#n]?(%d+)$') or '')
    local en = tonumber(q:match('^e(%d+)$') or q:match('^(%d+)$') or '')
    for _, r in ipairs(D.list) do
        local hit
        if nn and r.custom and r.id - D.CUSTOM_BASE == nn then hit = true
        elseif en and r.stock and r.id == en then hit = true
        elseif not nn and not en then
            local hay = (r.name .. ' ' .. (r.cat or '') .. ' ' .. (r.raw or '') .. ' ' .. (r.tex or '')):lower()
            hit = hay:find(q, 1, true) ~= nil
        end
        if hit and (ok_custom or not r.custom) then out[#out + 1] = r end
    end
    return out
end

-- ------------------------------------------------------------------ state + persistence
M.on = true
M.assign = {}            -- key -> { name, id (0 = Auto), where, on, land, crit, dot }
M.seen = {}              -- list of { name, kinds = {cast=n, proc=n, dot=n, pet=n}, c, t }
local loaded, dirty_at, path = false, nil, nil
local last_play = {}

function M.path()
    if path then return path end
    local p = tostring(C.CFG_PATH or 'combatfx.ini')
    local d, f = p:match('^(.*[/\\])([^/\\]+)$')
    if not f then d, f = '', p end
    path = d .. (f:gsub('^combatfx_', 'combatfx_spellfx_'))
    if path == p then path = p .. '.spellfx' end
    return path
end
function M._reset(p) M.on, M.assign, M.seen, loaded, dirty_at, path, last_play = true, {}, {}, false, nil, p, {} end

local function b(v) return v == '1' or v == 'true' end
function M.load()
    loaded = true
    local f = io.open(M.path(), 'r'); if not f then return false end
    for l in f:lines() do
        local t = {}
        for x in (l .. '|'):gmatch('([^|]*)|') do t[#t + 1] = x end
        if t[1] == 'on' then M.on = b(t[2])
        elseif t[1] == 'a' and t[2] and t[2] ~= '' then
            local w = t[4]; if w ~= 'target' and w ~= 'self' then w = 'auto' end
            M.assign[M.key(t[2])] = { name = t[2], id = math.floor(tonumber(t[3]) or 0), where = w,
                on = b(t[5]), land = b(t[6]), crit = b(t[7]), dot = b(t[8]) }
        elseif t[1] == 's' and t[2] and t[2] ~= '' then
            local e = { name = t[2], kinds = {}, c = tonumber(t[4]) or 1, t = tonumber(t[5]) or 0 }
            for k in tostring(t[3] or ''):gmatch('[^,]+') do e.kinds[k] = 1 end
            M.seen[#M.seen + 1] = e
        end
    end
    f:close(); return true
end
local function ensure() if not loaded then pcall(M.load) end end
function M.save_now()
    dirty_at = nil
    local f = io.open(M.path(), 'w'); if not f then return false end
    local function n(v) return v and '1' or '0' end
    f:write('on|', n(M.on), '\n')
    local ks = {}
    for k in pairs(M.assign) do ks[#ks + 1] = k end
    table.sort(ks)
    for _, k in ipairs(ks) do
        local a = M.assign[k]
        f:write(table.concat({ 'a', a.name, tostring(a.id or 0), a.where or 'auto', n(a.on), n(a.land), n(a.crit), n(a.dot) }, '|'), '\n')
    end
    for _, e in ipairs(M.seen) do
        local kk = {}
        for k in pairs(e.kinds) do kk[#kk + 1] = k end
        table.sort(kk)
        f:write(table.concat({ 's', e.name, table.concat(kk, ','), tostring(e.c or 1), tostring(e.t or 0) }, '|'), '\n')
    end
    f:close(); return true
end
function M.save() dirty_at = now() + 2000 end
function M.tick() if dirty_at and now() >= dirty_at then pcall(M.save_now) end end

-- ------------------------------------------------------------------ seen spells / procs
M.rev = 0                -- bumps when the seen list or the assignments change (UI redraws on change)
local function bump() M.rev = M.rev + 1 end
function M.note(name, kind)
    ensure()
    name = clean(name); if name == '' then return end
    local k = M.key(name)
    for i, e in ipairs(M.seen) do
        if M.key(e.name) == k then
            local new = not e.kinds[kind]
            e.kinds[kind] = 1; e.c = (e.c or 0) + 1; e.t = os.time()
            if i ~= 1 then table.remove(M.seen, i); table.insert(M.seen, 1, e); new = true end
            if new then bump(); M.save() end
            return e
        end
    end
    local e = { name = name, kinds = { [kind] = 1 }, c = 1, t = os.time() }
    table.insert(M.seen, 1, e)
    while #M.seen > M.MAX_SEEN do table.remove(M.seen) end
    bump(); M.save()
    return e
end
function M.seen_list(kind)
    ensure()
    if not kind or kind == 'all' then return M.seen end
    local o = {}
    for _, e in ipairs(M.seen) do if e.kinds[kind] then o[#o + 1] = e end end
    return o
end

-- ------------------------------------------------------------------ assignments
function M.get(name) ensure(); return M.assign[M.key(name)] end
function M.list()
    ensure()
    local o = {}
    for _, a in pairs(M.assign) do o[#o + 1] = a end
    table.sort(o, function(x, y) return x.name:lower() < y.name:lower() end)
    return o
end
function M.count() local n = 0; ensure(); for _ in pairs(M.assign) do n = n + 1 end; return n end
-- a new entry: id 0 = Auto until an effect is set; procs/pets default to the target, DoT ticks off
function M.add(name, id)
    ensure()
    name = clean(name); if name == '' then return nil, 'type a spell name' end
    local k = M.key(name)
    if M.assign[k] then
        if id then M.assign[k].id = math.floor(tonumber(id) or 0) end
        bump(); M.save(); return M.assign[k]
    end
    if M.count() >= M.MAX_ASSIGN then return nil, 'too many assignments (' .. M.MAX_ASSIGN .. ')' end
    local a = { name = name, id = math.floor(tonumber(id) or 0), where = 'auto', on = true, land = true, crit = true, dot = false }
    M.assign[k] = a
    bump(); M.save(); return a
end
function M.remove(name) ensure(); M.assign[M.key(name)] = nil; bump(); M.save() end
function M.set(name, field, v)
    local a = M.get(name); if not a then return false end
    if field == 'id' then a.id = math.floor(tonumber(v) or 0)
    elseif field == 'where' then a.where = (v == 'target' or v == 'self') and v or 'auto'
    elseif field == 'on' or field == 'land' or field == 'crit' or field == 'dot' then a[field] = v and true or false
    else return false end
    bump(); M.save(); return true
end
function M.set_on(v) ensure(); M.on = v and true or false; bump(); M.save() end
-- every proc seen so far as an entry (Auto until you give it an effect)
function M.add_seen(kind)
    local n = 0
    for _, e in ipairs(M.seen_list(kind)) do
        if not M.get(e.name) and M.add(e.name) then n = n + 1 end
    end
    return n
end

-- beneficial spells (heals, buffs) land on you when the entry says Auto
local ben = {}
function M.beneficial(name)
    local k = M.key(name)
    if ben[k] == nil then
        local v = false
        pcall(function() local mq = require('mq'); v = mq.TLO.Spell(name).Beneficial() == true end)
        ben[k] = v
    end
    return ben[k]
end
function M.where_for(a, spell)
    if a.where == 'target' or a.where == 'self' then return a.where end
    local nm = spell or a.name
    if nm:sub(1, 1) == '@' then return 'target' end
    return M.beneficial(nm) and 'self' or 'target'
end

-- One spell event. kind: 'cast' (your cast landed), 'proc' (a spell you did not cast: weapon / item / AA proc),
-- 'pet' (your pet's spell), 'dot' (a DoT tick). true = an assignment owned it (played / rate-limited / particles off),
-- so the caller skips the Auto burst; false = no assignment (or it is off): the caller keeps the Auto look.
function M.on_spell(name, kind, crit, rt)
    if not name or name == '' then return false end
    ensure()
    M.note(name, kind)
    if not M.on then return false end
    local a = M.resolve(name, kind)
    if not a or not a.on or (a.id or 0) == 0 then return false end
    if kind == 'dot' then if not a.dot then return false end
    elseif not (a.land or (crit and a.crit)) then return false end
    if C.cfg and C.cfg.master == false then return true end
    local k, t = M.key(name), now()
    if t - (last_play[k] or -1e9) < M.DEDUPE_MS and kind ~= 'dot' then return true end
    local ok = PF.play(a.id, M.where_for(a, name), rt)
    if ok then last_play[k] = t end
    return ok
end
function M.preview(a, spell) return PF.preview(a.id ~= 0 and a.id or 0, M.where_for(a, spell)) end

-- your spellbook (autocomplete); read once, on demand
local book
function M.book()
    if book then return book end
    book = {}
    pcall(function()
        local mq = require('mq')
        local seen = {}
        for i = 1, 1120 do
            local s = mq.TLO.Me.Book(i)
            local nm = s and s.Name and s.Name()
            if nm and nm ~= '' and nm ~= 'NULL' and not seen[nm] then seen[nm] = true; book[#book + 1] = nm end
        end
    end)
    table.sort(book)
    return book
end
function M._set_book(b2) book = b2 end
-- up to n names that start with (then contain) what was typed: seen spells first, then the spellbook
function M.suggest(q, n)
    q = trim(q):lower(); n = n or 8
    if #q < 2 then return {} end
    local out, have = {}, {}
    local function try(nm, pass)
        if #out >= n or have[nm:lower()] then return end
        local l = nm:lower()
        local p = l:find(q, 1, true)
        if p and ((pass == 1) == (p == 1)) then out[#out + 1] = nm; have[l] = true end
    end
    local gems, ng = M.gems()
    for pass = 1, 2 do
        for i = 1, ng do if gems[i] then try(gems[i], pass) end end
        for _, e in ipairs(M.seen_list()) do try(e.name, pass) end
        for _, nm in ipairs(M.book()) do try(nm, pass) end
    end
    return out
end
-- t471: a typed effect number -> record id. '#12' / 'n12' / '12' (1..100) = NEW effect 12; 'E317' / '317' (> 100) = Stock EQ 317
function M.parse_num(v)
    v = trim(v):lower():gsub('%s', '')
    if v == '' then return nil end
    local n = tonumber(v:match('^[#n](%d+)$') or '')
    if n then local id = D.CUSTOM_BASE + n; return (D.by_id[id] and D.by_id[id].custom) and id or nil end
    n = tonumber(v:match('^e(%d+)$') or '')
    if n then return (D.by_id[n] and D.by_id[n].stock) and n or nil end
    n = tonumber(v:match('^(%d+)$') or '')
    if not n then return nil end
    if n >= 1 and n <= 100 and D.by_id[D.CUSTOM_BASE + n] then return D.CUSTOM_BASE + n end
    if D.by_id[n] and D.by_id[n].stock then return n end
    return nil
end
-- t472: your spell gems, read live. t471 showed "0 gems" in game: every read was wrapped in one pcall per gem and any
-- miss was silent, so this tries each MQ form in turn and remembers which one worked (logged with debug_logs=1):
--   1 Me.Gem(i).Name()   2 Me.Gem(i)()   3 Spell(Me.Gem(i).ID()).Name()   4 the spell bar button tooltip (CastSpellWnd/CSPW_Spell<i-1>)
M.GEM_DEFAULT = 12
M.gem_src, M.gem_err, M.gem_n = '-', '', 0
local function sname(v)
    if v == nil then return nil end
    v = tostring(v)
    if v == '' or v == 'NULL' or v == 'nil' or v == 'FALSE' or v == 'TRUE' then return nil end
    return v
end
local function try(fn) local ok, v = pcall(fn); if ok then return v end; M.gem_err = tostring(v); return nil end   -- t489: always one value (tonumber(try()) threw)
function M.num_gems()
    local mq = require('mq')
    local n = tonumber(try(function() return mq.TLO.Me.NumGems() end))
    if not n or n < 1 or n > 20 then n = M.GEM_DEFAULT end
    return math.max(n, M.GEM_DEFAULT)              -- MQ's NumGems counts visible spell bar windows (8 + extras): always list 12
end
local GEM_READ = {
    function(mq, i) return sname(mq.TLO.Me.Gem(i).Name()) end,
    function(mq, i) return sname(mq.TLO.Me.Gem(i)()) end,
    function(mq, i) local id = tonumber(mq.TLO.Me.Gem(i).ID()); return id and id > 0 and sname(mq.TLO.Spell(id).Name()) or nil end,
    function(mq, i) local t = sname(mq.TLO.Window('CastSpellWnd').Child('CSPW_Spell' .. (i - 1)).Tooltip()); return t and t:gsub('%s*%(.-%)%s*$', '') or nil end,
}
function M.read_gems()
    local mq = require('mq')
    local n = M.num_gems()
    local names, src = {}, '-'
    for si, rd in ipairs(GEM_READ) do
        local got = 0
        for i = 1, n do
            local v = try(function() return rd(mq, i) end)
            names[i] = v
            if v then got = got + 1 end
        end
        if got > 0 then src = tostring(si); break end
    end
    M.gem_src, M.gem_n = src, n
    return names, n
end
local gem_cache, gem_t, gem_cnt = {}, -1e9, 0
function M.gems(force)
    local t = now()
    if force or t - gem_t > 1000 then gem_t = t; gem_cache, gem_cnt = M.read_gems() end
    return gem_cache, gem_cnt
end
function M._gems_reset() gem_t = -1e9 end
function M.gem_of(name)
    local k = M.key(name)
    local g, n = M.gems()
    for i = 1, n do if g[i] and M.key(g[i]) == k then return i end end
end
-- t472: weapon / range procs: the proc spell of the item in that slot (Item.Proc.Spell; MQ2ItemType 'Proc' = ItemSpellType)
M.SLOTS = { { key = '@primary', label = 'Primary proc', inv = 'mainhand' }, { key = '@secondary', label = 'Secondary proc', inv = 'offhand' },
    { key = '@range', label = 'Range proc', inv = 'range' } }
local slot_cache, slot_t = {}, -1e9
function M.slot_proc(inv)
    local mq = require('mq')
    local nm = try(function() return sname(mq.TLO.Me.Inventory(inv).Proc.Spell.Name()) end)
    if not nm then
        local id = tonumber(try(function() return mq.TLO.Me.Inventory(inv).Proc.SpellID() end))
        if id and id > 0 then nm = try(function() return sname(mq.TLO.Spell(id).Name()) end) end
    end
    return nm
end
function M.slot_procs(force)
    local t = now()
    if force or t - slot_t > 3000 then
        slot_t = t
        for _, s in ipairs(M.SLOTS) do slot_cache[s.key] = M.slot_proc(s.inv) end
    end
    return slot_cache
end
function M._slots_reset() slot_t = -1e9 end
-- which entry a landed spell uses: its own (by name) > the gem it sits in (your cast) > the weapon slot whose proc it is
-- t489: the Spell Gems & Procs rows win: the gem it sits in (your cast) > the weapon slot whose proc it is > an old by-name entry
function M.resolve(name, kind)
    if kind == 'cast' or kind == 'dot' then
        local gi = M.gem_of(name)
        local g = gi and M.assign['@gem' .. gi]
        if g and (g.id or 0) ~= 0 then return g end
    end
    if kind == 'proc' or kind == 'dot' then
        local k = M.key(name)
        for sk, pn in pairs(M.slot_procs()) do
            if pn and M.key(pn) == k then local s = M.assign[sk]; if s and (s.id or 0) ~= 0 then return s end end
        end
    end
    return M.assign[M.key(name)]
end
function M.diag()
    local g, n = M.gems()
    local t = {}
    for i = 1, n do t[#t + 1] = i .. '=' .. tostring(g[i] or '-') end
    local sp = M.slot_procs()
    return string.format('GEMS n=%d src=%s err=%s %s | procs primary=%s secondary=%s range=%s', n, M.gem_src, M.gem_err, table.concat(t, ' '),
        tostring(sp['@primary']), tostring(sp['@secondary']), tostring(sp['@range']))
end
function M.log_diag()
    pcall(function()
        local p = require('combatfx.paths').log_path('combatfx_spellfx.log')
        if not p then return end
        local f = io.open(p, 'a'); if not f then return end
        f:write(os.date('%Y-%m-%d %H:%M:%S '), M.diag(), '\n'); f:close()
    end)
end
-- add or update in one step (typed number next to a spell)
function M.assign_num(name, v)
    local id = M.parse_num(v)
    if not id then return nil, 'not an effect number: type #1-#100 (or 1-100) for NEW effects, E<record> for EQ ones' end
    local a, why = M.add(name, id)
    if not a then return nil, why end
    return a
end
return M
