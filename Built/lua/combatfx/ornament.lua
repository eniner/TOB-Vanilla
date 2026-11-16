-- combatfx ornaments (orn1): client-side model swaps on your own character via MQ2RmlUi
-- rml_orn_set / rml_orn_restore / rml_orn_status (rml_features() & 8192). Only you see them; nothing is sent
-- to the server. The DLL forgets swaps on zone (EQ re-attaches your real gear); this module puts the saved
-- ones back (1 Hz check, rate limited, gives up on a point after 3 failed tries until the next zone).
local ffi = require('ffi')
local C = require('combatfx.core')
local M = { REV = 'orn1', PREVIEW_MS = 12000 }
local FEAT_ORN = 8192

-- saved per character in the CombatFX ini (core's flat serializer: one level of scalars)
C.cfg.orn = C.cfg.orn or { auto = true, set = '', fav = '', keep = false }

-- attach points per slot, from eqgame+0x96D80 (wear slot, side -> point); side 0 = first IT, side 1 = pair
M.SLOTS = {
    { id = 'primary',   label = 'Primary',   pts = { 3 },      held = true },
    { id = 'secondary', label = 'Secondary', pts = { 4 },      held = true },
    { id = 'shield',    label = 'Shield',    pts = { 5 },      held = true },
    { id = 'helm',      label = 'Helm',      pts = { 1 } },
    { id = 'chest',     label = 'Chest',     pts = { 11 } },
    { id = 'arms',      label = 'Shoulders', pts = { 27, 26 } },
    { id = 'wrist',     label = 'Wrists',    pts = { 13, 12 } },
    { id = 'hands',     label = 'Hands',     pts = { 19, 18 } },
    { id = 'legs',      label = 'Legs',      pts = { 14 } },
    { id = 'feet',      label = 'Feet',      pts = { 21, 22 } },
}
M.SLOT = {}
for _, s in ipairs(M.SLOTS) do M.SLOT[s.id] = s end

-- shieldfix: a shield model must go on point 5 (on the arm), never a hand point (3 / 4 = held like a weapon).
-- eqgame's own wear code (+0x306BB0) does this for the secondary slot: it asks +0x199A50 whether the model's
-- Resources\ActorTagInfo.txt record (table at +0x140, loaded at +0x18BE34) has type 10; yes -> point 5 and point 4
-- cleared, no -> point 4 (via +0x96D80) and point 5 cleared. ornament_shields.lua is that type-10 list for this client.
local SHIELDS = nil
local function shields()
    if SHIELDS == nil then
        local ok, t = pcall(require, 'combatfx.ornament_shields')
        SHIELDS = (ok and type(t) == 'table' and type(t.set) == 'table') and t.set or false
    end
    return SHIELDS or {}
end
function M.is_shield(x)
    local it = type(x) == 'table' and x.it or tonumber(tostring(x or ''):match('(%d+)'))
    return it ~= nil and shields()[tonumber(it)] == true
end
M.HAND_PT, M.SHIELD_PT, M.MAIN_PT = 4, 5, 3
-- where a held pick really goes: shields -> 'shield' (point 5); a weapon picked on the Shield tab -> 'secondary'
function M.slot_for(e, slot_id)
    local s = M.SLOT[slot_id]
    if not (s and s.held and e) then return slot_id end
    if M.is_shield(e) then return 'shield' end
    if slot_id == 'shield' then return 'secondary' end
    return slot_id
end

-- EQ race name -> NewArmorTagData race tag (male / female)
local RACE = { Human = { 'HUM', 'HUF' }, Barbarian = { 'BAM', 'BAF' }, Erudite = { 'ERM', 'ERF' }, ['Wood Elf'] = { 'ELM', 'ELF' },
    ['High Elf'] = { 'HIM', 'HIF' }, ['Dark Elf'] = { 'DAM', 'DAF' }, ['Half Elf'] = { 'HAM', 'HAF' }, Dwarf = { 'DWM', 'DWF' },
    Troll = { 'TRM', 'TRF' }, Ogre = { 'OGM', 'OGF' }, Halfling = { 'HOM', 'HOF' }, Gnome = { 'GNM', 'GNF' }, Iksar = { 'IKM', 'IKF' },
    ['Vah Shir'] = { 'KEM', 'KEF' }, Froglok = { 'FRM', 'FRF' }, Drakkin = { 'DKM', 'DKF' } }

local lib, probed = nil, false
local avail, avail_why, next_avail = false, 'not checked', 0
local st, st_raw, st_t = { pts = {} }, '', 0
local D, D_err = nil, nil
local tries = {}          -- [pt] = { n = fails, next = ms, sent = ms, tag = 'IT..' }
local zone_sig = nil

local function now()
    local ok, t = pcall(function() return require('mq').gettime() end)
    if ok and tonumber(t) then return tonumber(t) end
    return math.floor(os.clock() * 1000)
end

local function load_lib()
    if probed then return lib end
    probed = true
    for _, d in ipairs({ 'int rml_features();', 'int rml_orn_set(int, const char*);', 'int rml_orn_restore(int);',
        'int rml_orn_loaded(const char*);', 'const char* rml_orn_status();', 'int rml_orn_mat(int, int);' }) do pcall(ffi.cdef, d) end
    local dll = os.getenv('COMBATFX_API_DLL')
    local ok, l = false, nil
    if dll and dll ~= '' then ok, l = pcall(ffi.load, dll) end
    if not (ok and l) then ok, l = pcall(ffi.load, 'MQ2RmlUi') end
    if not (ok and l) then ok, l = pcall(ffi.load, 'mq2rmlui') end
    lib = (ok and l) or nil
    return lib
end
function M._set_lib(l) lib, probed, next_avail = l, true, 0 end      -- headless tests
local function has(fn) local ok, f = pcall(function() return lib[fn] end); return ok and f ~= nil end

function M.available()
    local t = now()
    if t < next_avail then return avail, avail_why end
    next_avail = t + 5000
    load_lib()
    if not lib then avail, avail_why = false, 'MQ2RmlUi not loaded'; return avail, avail_why end
    local feat = 0
    if has('rml_features') then pcall(function() feat = tonumber(lib.rml_features()) or 0 end) end
    if math.floor(feat / FEAT_ORN) % 2 ~= 1 then
        avail, avail_why = false, 'this MQ2RmlUi has no ornament swap (feature 8192 missing)'
    elseif not (has('rml_orn_set') and has('rml_orn_restore') and has('rml_orn_status')) then
        avail, avail_why = false, 'MQ2RmlUi is missing the rml_orn exports'
    else
        avail, avail_why = true, 'ready'
    end
    return avail, avail_why
end

-- allraces: armor models are race + gender specific. ornament_data.lua holds the held / weapon models (the same for
-- everyone); ornament_race/<TAG>.lua holds the armor + sets of one race tag, generated from this client's own
-- NewArmorTagData with eqgame's loader rules and racedata.txt (ornament_races.lua: race id -> male / female tag).
local RACES = nil
local function races()
    if RACES == nil then
        local ok, t = pcall(require, 'combatfx.ornament_races')
        RACES = (ok and type(t) == 'table') and t or false
    end
    return RACES or nil
end
M.RACE_NAME = {}
for n, t in pairs(RACE) do M.RACE_NAME[t[1]] = n .. ' male'; M.RACE_NAME[t[2]] = n .. ' female' end
function M.race_name(tag)
    if not tag then return 'unknown race' end
    if M.RACE_NAME[tag] then return M.RACE_NAME[tag] end
    local R = races()
    if R then for id, t in pairs(R) do
        if type(id) == 'number' and (t[1] == tag or t[2] == tag) then return string.format('%s %s', t[3] or ('race ' .. id), t[2] == tag and 'female' or 'male') end
    end end
    return tag
end

-- body material m has textures / model pieces for your race on this client (ornament_races.lua mats, scanned from the
-- client's files). Unknown race or no table -> true (same as before).
function M.mat_ok(m, tag)
    tag = tag or M.my_race()
    local R = races()
    local l = tag and R and type(R.mats) == 'table' and R.mats[tag]
    if type(l) ~= 'table' then return true end
    for _, v in ipairs(l) do if v == m then return true end end
    return false
end

-- race tag from the game (racefix). Proven from MQ source (Desktop\RMLUI\macroquest\src\main\datatypes):
--   Me.Race      -> MQ2RaceType (MQ2SpawnType.cpp: Dest.DWord = pSpawn->GetRace(); Dest.Type = pRaceType)
--   Me.Race.ID   -> int race id (MQ2RaceType.cpp RaceMembers::ID); Me.Race() / Me.Race.Name -> GetRaceDesc(id) text
--   Me.Gender    -> string from szGender[] = "male", "female", "neuter", "unknown" (MQ2Globals.cpp)
-- Old code returned nil for ANY race outside the 17 ornament races and race_data(nil) then said "not known yet (log
-- in a character)", so a logged-in character of an unmapped race (or an illusion, or a TLO read that failed) got the
-- log-in message. Now: every source is tried each call (no cached nil), each form is accepted (number, numeric
-- string, name in any case / spacing), the DLL's own attach-point names (e.g. DWMCHEST_POINT_TRACK) are a last,
-- TLO-free fallback, the raw values are logged once per change, and an unmapped race gets a message naming it.
local function norm(s) return (tostring(s or ''):lower():gsub('[^%a]', '')) end
local NAME_ALIAS = { frogloks = 'froglok', frog = 'froglok', vahshirs = 'vahshir', kerran = 'vahshir', halfelven = 'halfelf',
    highelven = 'highelf', darkelven = 'darkelf', woodelven = 'woodelf', drakkins = 'drakkin', iksars = 'iksar' }
local NAME_IDX = nil
local function name_index()
    if NAME_IDX then return NAME_IDX end
    NAME_IDX = {}
    for n, t in pairs(RACE) do NAME_IDX[norm(n)] = t end
    local R = races()
    if R then for id, t in pairs(R) do
        if type(id) == 'number' and type(t) == 'table' and t[3] and not NAME_IDX[norm(t[3])] then NAME_IDX[norm(t[3])] = { t[1], t[2] } end
    end end
    for a, n in pairs(NAME_ALIAS) do NAME_IDX[a] = NAME_IDX[a] or NAME_IDX[n] end
    return NAME_IDX
end
-- gender in any form -> 'female' | 'male' | nil (neuter / unknown use the male tag, the same as eqgame's default)
function M._gender(v)
    if v == nil then return nil end
    local n = tonumber(v)
    if n then return n == 1 and 'female' or 'male' end
    local g = norm(v)
    if g == 'female' or g == 'f' or g == 'woman' then return 'female' end
    if g == 'male' or g == 'm' or g == 'man' or g == 'neuter' or g == 'n' or g == 'unknown' then return 'male' end
    return nil
end
local function tag_set()
    local R, set = races(), {}
    if R then for id, t in pairs(R) do if type(id) == 'number' and type(t) == 'table' then
        if t[1] then set[t[1]] = 'male' end; if t[2] then set[t[2]] = 'female' end
    end end end
    for _, t in pairs(RACE) do set[t[1]] = set[t[1]] or 'male'; set[t[2]] = set[t[2]] or 'female' end
    return set
end
-- pure mapping (headless tested): raw TLO values -> tag, source, reason
function M._map_race(id, name, rname, gender)
    local fem = M._gender(gender) == 'female'
    local R = races()
    local nid = tonumber(id) or tonumber(name) or tonumber(rname)
    if nid and R and type(R[nid]) == 'table' then
        local t = R[nid]; local tag = fem and t[2] or t[1]
        if tag and tag ~= '' then return tag, 'Race.ID' end
    end
    local idx = name_index()
    for i = 1, 2 do                                                  -- not ipairs: name may be nil while Race.Name is set
        local n = i == 1 and name or rname
        if n ~= nil and not tonumber(n) then
            local k = norm(n)
            local t = idx[k] or idx[k:gsub('s$', '')]
            if t then return fem and t[2] or t[1], 'Race name' end
        end
    end
    return nil, nil
end
-- DLL fallback: the race tag your own body's attach points are named with (status "points{idx:name:model}")
function M._tag_from_points(pts)
    if type(pts) ~= 'table' then return nil end
    local set, votes, best, bn = tag_set(), {}, nil, 0
    for _, p in pairs(pts) do
        local pre = type(p) == 'table' and type(p.name) == 'string' and p.name:sub(1, 3):upper() or nil
        if pre and set[pre] then votes[pre] = (votes[pre] or 0) + 1 end
    end
    for t, n in pairs(votes) do if n > bn then best, bn = t, n end end
    return best
end
local RI = { sig = nil, tag = nil, src = nil, why = nil }
local pts_next = 0
local function race_log(line)
    local mq = package.loaded['mq']
    local root
    pcall(function() root = mq.TLO.MacroQuest.Path('root')() end)
    if not root or root == '' then pcall(function() local PT = require('combatfx.paths'); root = PT.get().logs and (PT.get().logs .. '\\..') end) end
    if M._race_log_path or (root and root ~= '') then
        pcall(function()
            local path = M._race_log_path or (tostring(root):gsub('[/\\]+$', '') .. '\\Logs\\rmlui_canvas.log')
            local chk = io.open(path, 'r')                       -- only append to the existing DLL log, never create a file
            if chk then chk:close(); local f = io.open(path, 'a'); if f then f:write(os.date('%H:%M:%S') .. '.000 ', line, '\n'); f:close() end end
        end)
    end
    M._last_log = line
end
local function raw_tlo(mq)
    local r = {}
    pcall(function() r.char = mq.TLO.Me.CleanName() end)
    pcall(function() r.server = mq.TLO.EverQuest.Server() end)
    pcall(function() r.gs = mq.TLO.EverQuest.GameState() end)
    pcall(function() r.id = mq.TLO.Me.Race.ID() end)
    pcall(function() r.name = mq.TLO.Me.Race() end)
    pcall(function() r.rname = mq.TLO.Me.Race.Name() end)
    pcall(function() r.gender = mq.TLO.Me.Gender() end)
    return r
end
function M.race_info()
    if M._race_override then return { tag = M._race_override, src = 'override' } end
    local okm, mq = pcall(require, 'mq')
    if not okm or mq == nil then
        RI = { sig = 'nomq', why = 'MacroQuest Lua module not available' }
        return RI
    end
    local r = raw_tlo(mq)
    local tag, src = M._map_race(r.id, r.name, r.rname, r.gender)
    local ptag
    if not tag then
        -- DLL fallback (read-only status string), at most once a second
        local t = now()
        if t >= pts_next then
            pts_next = t + 1000
            pcall(function() if M.available() then M.poll() end end)
        end
        ptag = M._tag_from_points(st and st.pts)
        if ptag then tag, src = ptag, 'body attach points' end
    end
    local why = nil
    if not tag then
        local ingame = (r.gs == nil or r.gs == 'INGAME') and (r.id ~= nil or r.name ~= nil or r.char ~= nil)
        if not ingame then
            why = 'waiting for your character (log in a character)'
        elseif r.id == nil and r.name == nil and r.rname == nil then
            why = string.format('could not read your race from MacroQuest (Me.Race returned nothing for %s)', tostring(r.char or '?'))
        else
            why = string.format('no ornament armor for your race: %s (race id %s, %s). This client has ornament armor tags only for the 16 player races',
                tostring(r.name or r.rname or '?'), tostring(r.id or '?'), tostring(r.gender or 'gender ?'))
        end
    end
    local sig = table.concat({ tostring(r.char), tostring(r.server), tostring(r.gs), tostring(r.id), tostring(r.name), tostring(r.rname), tostring(r.gender), tostring(tag), tostring(src) }, '|')
    if sig ~= RI.sig then
        local line = string.format('combatfx race: char=%s server=%s state=%s Me.Race.ID=%s(%s) Me.Race=%s(%s) Me.Race.Name=%s Me.Gender=%s(%s) -> tag=%s via %s%s',
            tostring(r.char), tostring(r.server), tostring(r.gs), tostring(r.id), type(r.id), tostring(r.name), type(r.name), tostring(r.rname),
            tostring(r.gender), type(r.gender), tostring(tag), tostring(src), why and (' (' .. why .. ')') or '')
        race_log(line)
        if not tag and why and not why:find('waiting for', 1, true) then pcall(print, (C.TAG or '') .. line) end
    end
    RI = { sig = sig, tag = tag, src = src, why = why, raw = r }
    return RI
end
function M.my_race()
    if M._race_override then return M._race_override end              -- headless tests
    return M.race_info().tag
end
function M.race_why() return RI.why end

-- one race catalog (cached per tag): rows + sets + sets other races have (greyed, with a reason)
local RC = {}
function M.race_data(tag)
    if not tag or not tostring(tag):match('^%u%u%u$') then return nil, (not M._race_override and RI.why) or 'your race is not known yet (log in a character)' end
    local c = RC[tag]
    if c then return c.d, c.err end
    local ok, d = pcall(require, 'combatfx.ornament_race.' .. tag)
    if not ok or type(d) ~= 'table' or type(d.rows) ~= 'table' then
        RC[tag] = { err = string.format('no armor catalog for %s (ornament_race/%s.lua missing)', M.race_name(tag), tag) }
        return nil, RC[tag].err
    end
    RC[tag] = { d = d }
    return d
end

local function entry(r, groups)
    local e = { it = r[1], pair = r[2] ~= 0 and r[2] or nil, slot = r[3], group = groups[r[4]] or '?', label = r[5], prt = r[6] == 1, shape = r[7] }
    e.key = string.lower(string.format('it%d %d %s %s %s', e.it, e.it, e.label, e.group, e.pair and ('it' .. e.pair) or ''))
    return e
end
-- catalog (lazy: only parsed when the tab opens or a saved swap needs a label). Rebuilt when the race tag changes
-- (another character). d.race = tag or nil; d.race_err = why there is no armor list (weapons still listed).
local BASE, D_race = nil, false
function M.data()
    local race = M.my_race()
    if D and D_race == race and (race ~= nil or D._why == RI.why) then return D end   -- racefix: no stale reason
    if D_err then return nil, D_err end
    if not BASE then
        local ok, d = pcall(require, 'combatfx.ornament_data')
        if not ok or type(d) ~= 'table' then D_err = 'ornament_data.lua missing or broken: ' .. tostring(d); return nil, D_err end
        BASE = { list = {} }
        for _, r in ipairs(d.rows) do
            if r[7] ~= 'a' then BASE.list[#BASE.list + 1] = entry(r, d.groups) end   -- armor rows come from the race file
        end
        d.rows = nil
    end
    local out = { list = {}, by_it = {}, race = race, armor = 0 }
    for _, e in ipairs(BASE.list) do out.list[#out.list + 1] = e; out.by_it[e.it] = out.by_it[e.it] or e end
    local rd, rerr = M.race_data(race)
    if rd then
        for _, r in ipairs(rd.rows) do
            local e = entry(r, rd.groups)
            out.list[#out.list + 1] = e; out.by_it[e.it] = out.by_it[e.it] or e; out.armor = out.armor + 1
        end
    else
        out.race_err = rerr
    end
    out._why = RI.why
    D, D_race = out, race
    return D
end

-- ---------------------------------------------------------------- status from the DLL
local function parse(s)
    local t = { raw = s, pts = {} }
    t.verified = tonumber((s:match('verified=(%-?%d+)') or '')) or 0
    t.disabled = s:match('disabled=(%d)') == '1'
    t.live = tonumber(s:match('live=(%-?%d+)') or '') or -1
    t.queued = tonumber(s:match('queued=(%d+)') or '') or 0
    t.last = s:match('last=(.*)$') or ''
    t.mats = {}                                                      -- matfix: [region] = { mat =, ours = }
    for r, m, star in (s:match('mats{[^}]*}=%[(.-)%]') or ''):gmatch('(%d+):(%d+)(%*?)') do t.mats[tonumber(r)] = { mat = tonumber(m), ours = star == '*' } end
    local list = s:match('points{[^}]*}=%[(.-)%]') or ''
    for idx, name, rest in list:gmatch('(%d+):([^:%s]+):(%S+)') do
        local tag = rest:match('^(IT%d+)')
        t.pts[tonumber(idx)] = { name = name, tag = tag, empty = rest:find('^%(empty%)') ~= nil, ours = rest:find('%*') ~= nil,
            orig = rest:match('%(orig ([%w_]+)%)') }
    end
    return t
end
M._parse = parse
function M.poll()
    if not M.available() then return st end
    local s
    pcall(function() local p = lib.rml_orn_status(); if p ~= nil then s = ffi.string(p) end end)
    if s then st_raw, st, st_t = s, parse(s), now() end
    return st
end
function M.status() return st, st_raw end

-- ---------------------------------------------------------------- saved swaps: "pt:IT####,pt:IT####"
M._moved = {}           -- shieldfix: hand points that held a saved shield (put back by the next tick)
function M.wanted()
    local w = {}
    for pt, tag in tostring(C.cfg.orn.set or ''):gmatch('(%d+):(IT%d+)') do w[tonumber(pt)] = tag end
    -- shieldfix: a shield saved on a hand point (older builds sent it wherever the tab was) moves to point 5
    local moved = false
    for _, pt in ipairs({ M.MAIN_PT, M.HAND_PT }) do
        if w[pt] and M.is_shield(w[pt]) then
            if not w[M.SHIELD_PT] then w[M.SHIELD_PT] = w[pt] end
            w[pt] = nil; M._moved[pt] = true; moved = true
        end
    end
    if moved then
        local o = {}
        for pt, tag in pairs(w) do o[#o + 1] = string.format('%d:%s', pt, tag) end
        table.sort(o)
        C.cfg.orn.set = table.concat(o, ','); C.save_cfg()
    end
    return w
end
local function save_wanted(w)
    local o = {}
    for pt, tag in pairs(w) do o[#o + 1] = string.format('%d:%s', pt, tag) end
    table.sort(o)
    C.cfg.orn.set = table.concat(o, ',')
    C.save_cfg()
end

local function send(pt, tag)
    local rc = -99
    pcall(function() rc = tonumber(lib.rml_orn_set(pt, tag)) or -99 end)
    local t = tries[pt] or { n = 0 }
    t.sent, t.tag, t.next = now(), tag, now() + 4000
    tries[pt] = t
    return rc
end

-- matfix: body region material for a slot pick / set piece, via rml_orn_mat (eqgame's own SetArmorTexture).
-- No set archive carries body textures (scan of all 152 set .eqg: 0 region textures), so the material comes from the
-- armor class in the set / catalog group name: NAME-BASED (plate 3, chain/ring/scale 2, leather 1, cloth 0).
M.REGION = { chest = 1, arms = 2, wrist = 3, hands = 4, legs = 5 }
function M.mat_for(text)
    local t = tostring(text or ''):lower()
    for _, kv in ipairs({ { 'plate', 3 }, { 'chain', 2 }, { 'ring', 2 }, { 'scale', 2 }, { 'leather', 1 }, { 'cloth', 0 }, { 'silk', 0 } }) do
        if t:find(kv[1], 1, true) then return kv[2] end
    end
    return nil
end
function M.wanted_mats()
    local w = {}
    for r, m in tostring(C.cfg.orn.mat or ''):gmatch('(%d+):(%d+)') do w[tonumber(r)] = tonumber(m) end
    return w
end
local function save_mats(w)
    local o = {}
    for r, m in pairs(w) do o[#o + 1] = string.format('%d:%d', r, m) end
    table.sort(o)
    C.cfg.orn.mat = table.concat(o, ','); C.save_cfg()
end
local mtries = {}        -- [region] = { n =, next = ms }
local function send_mat(r, m)
    if not has('rml_orn_mat') then return -98 end
    local rc = -99
    pcall(function() rc = tonumber(lib.rml_orn_mat(r, m)) or -99 end)
    local t = mtries[r] or { n = 0 }
    t.next = now() + 4000; t.n = (t.n or 0) + 1
    mtries[r] = t
    return rc
end

-- apply catalog entry e to slot s: side 0 point gets e.it, side 1 point gets e.pair (held items: one point)
function M.apply(e, slot_id)
    local ok, why = M.available()
    if not ok then return false, why end
    slot_id = M.slot_for(e, slot_id)                                  -- shieldfix: shields on point 5
    local s = M.SLOT[slot_id]; if not s or not e then return false, 'bad slot' end
    if M._pv and M._pv.slot == slot_id then M._pv = nil else M.preview_end(true) end   -- Apply keeps a preview on the same slot
    local w = M.wanted()
    local sent = {}
    -- like eqgame: shield on 5 clears our left-hand piece on 4, a left-hand piece on 4 clears our shield on 5
    local other = (slot_id == 'shield' and M.HAND_PT) or (slot_id == 'secondary' and M.SHIELD_PT) or nil
    if other and w[other] then
        w[other] = nil; tries[other] = nil
        pcall(function() lib.rml_orn_restore(other) end)
        sent[#sent + 1] = string.format('%d=real', other)
    end
    for i, pt in ipairs(s.pts) do
        local it = (i == 1) and e.it or e.pair
        if it then
            local tag = 'IT' .. it
            w[pt] = tag; tries[pt] = { n = 0 }
            local rc = send(pt, tag)
            if rc <= 0 then
                return false, ({ [-1] = 'disabled after a fault this session', [-2] = 'client build not verified', [-3] = 'bad point or tag', [-4] = 'queue full, try again' })[rc] or ('error ' .. rc)
            end
            sent[#sent + 1] = string.format('%d=%s', pt, tag)
        end
    end
    save_wanted(w)
    M.last_slot = slot_id
    local r, m = M.REGION[slot_id], e.mat or M.mat_for(e.group)
    if m and not M.mat_ok(m) then m = nil end                        -- allraces: no texture for this race -> leave the body as is
    if r and m then                                                  -- matfix
        local wm = M.wanted_mats(); wm[r] = m; save_mats(wm); mtries[r] = nil
        if send_mat(r, m) > 0 then sent[#sent + 1] = string.format('mat%d=%d', r, m) end
    end
    return true, table.concat(sent, ' '), slot_id
end

-- live preview (same idea as the native aura picker): put the model on your character for PREVIEW_MS without saving
-- it, then put back what was there (your saved ornament or your real gear). Apply during a preview keeps it.
M._pv = nil              -- { pts = { [pt] = true }, slot =, it =, until_ms = }
function M.preview(e, slot_id, ms)
    local ok, why = M.available()
    if not ok then return false, why end
    slot_id = M.slot_for(e, slot_id)
    local s = M.SLOT[slot_id]; if not s or not e then return false, 'bad slot' end
    M.preview_end(true)
    local pv = { pts = {}, slot = slot_id, it = e.it, until_ms = now() + (ms or M.PREVIEW_MS) }
    for i, pt in ipairs(s.pts) do
        local it = (i == 1) and e.it or e.pair
        if it then
            local rc = -99
            pcall(function() rc = tonumber(lib.rml_orn_set(pt, 'IT' .. it)) or -99 end)
            if rc <= 0 then
                M._pv = pv; M.preview_end(true)
                return false, ({ [-1] = 'disabled after a fault this session', [-2] = 'client build not verified', [-3] = 'bad point or tag', [-4] = 'queue full, try again' })[rc] or ('error ' .. rc)
            end
            pv.pts[pt] = true
        end
    end
    M._pv = pv
    return true, slot_id
end
-- end the preview: each point goes back to its saved ornament, or the real gear (restore)
function M.preview_end(quiet)
    local pv = M._pv; if not pv then return false end
    M._pv = nil
    local w = M.wanted()
    for pt in pairs(pv.pts) do
        if w[pt] then tries[pt] = { n = 0 }; send(pt, w[pt])
        elseif lib then pcall(function() lib.rml_orn_restore(pt) end) end
    end
    return true
end
function M.preview_left()
    if not M._pv then return 0 end
    return math.max(0, math.ceil((M._pv.until_ms - now()) / 1000))
end
function M.previewing(it) return M._pv ~= nil and (it == nil or M._pv.it == it) end

function M.restore_slot(slot_id)
    local s = M.SLOT[slot_id]; if not s then return false end
    M.preview_end(true)
    local w = M.wanted()
    for _, pt in ipairs(s.pts) do
        w[pt] = nil; tries[pt] = nil
        if lib and avail then pcall(function() lib.rml_orn_restore(pt) end) end
    end
    save_wanted(w)
    local r = M.REGION[slot_id]                                      -- matfix
    if r then
        local wm = M.wanted_mats()
        if wm[r] then wm[r] = nil; save_mats(wm); mtries[r] = nil; if lib and avail then send_mat(r, -1) end end
    end
    return true
end
function M.restore_all()
    M._pv = nil
    tries = {}; mtries = {}
    C.cfg.orn.set = ''; C.cfg.orn.mat = ''; C.save_cfg()
    if lib and avail then pcall(function() lib.rml_orn_restore(-1) end) end
    return true
end

-- f8b (loadouts): the saved set / materials changed under us: real gear back once, then the 1 Hz tick sends what
-- cfg.orn.set / cfg.orn.mat now want (same path as zoning). Keeps the cfg values (restore_all would clear them).
function M.reapply()
    M._setq = nil; tries = {}; mtries = {}
    if lib and avail then pcall(function() lib.rml_orn_restore(-1) end) end
    return true
end
-- per-point state for the UI: 'on' (shows the saved model), 'pending', 'failed', 'nopoint', 'off'
function M.point_state(pt)
    local w = M.wanted()[pt]
    local p = st.pts[pt]
    if not w then return 'off', p end
    if not p then return 'nopoint', p end
    if p.tag == w then return 'on', p end
    local t = tries[pt]
    if t and t.n >= 3 then return 'failed', p end
    return 'pending', p
end

function M.favs()
    local t, set = {}, {}
    for v in tostring(C.cfg.orn.fav or ''):gmatch('%d+') do
        local it = tonumber(v); if it and not set[it] then set[it] = true; t[#t + 1] = it end
    end
    return t, set
end
function M.toggle_fav(it)
    local list, set = M.favs()
    local out = {}
    for _, v in ipairs(list) do if v ~= it then out[#out + 1] = tostring(v) end end
    if not set[it] then out[#out + 1] = tostring(it) end
    C.cfg.orn.fav = table.concat(out, ' ')
    C.save_cfg()
    return not set[it]
end

-- filter: slot id, kind ('all'|'w'|'s'|'o'|'fav'|'prt'), search text
function M.filter(slot_id, kind, q)
    local d = M.data(); if not d then return {} end
    local s = M.SLOT[slot_id]
    q = tostring(q or ''):lower():gsub('^%s+', ''):gsub('%s+$', '')
    local _, fav = M.favs()
    local out = {}
    for _, e in ipairs(d.list) do
        local okslot = s and ((s.held and e.slot == 'held') or (not s.held and e.slot == s.id))
        if okslot and s.held then                                     -- shieldfix: Primary = no shields, Shield = only shields
            local sh = M.is_shield(e)
            if (slot_id == 'primary' and sh) or (slot_id == 'shield' and not sh) then okslot = false end
        end
        if okslot then
            local sh = s.held and M.is_shield(e)
            local okk = kind == 'all' or (kind == 'fav' and fav[e.it]) or (kind == 'prt' and e.prt)
                or (kind == 'sh' and sh) or (kind == 'w' and not sh and e.shape ~= 'o') or (kind == 'o' and not sh and e.shape == 'o')
            if okk and (q == '' or e.key:find(q, 1, true)) then out[#out + 1] = e end
        end
    end
    return out
end

local function in_game()
    local ok, v = pcall(function()
        local mq = require('mq')
        local gs = mq.TLO.EverQuest and mq.TLO.EverQuest.GameState and mq.TLO.EverQuest.GameState()
        if gs and gs ~= 'INGAME' then return false end
        return (tonumber(mq.TLO.Me.ID()) or 0) > 0
    end)
    return ok and v == true
end
local function zone_id()
    local ok, z = pcall(function() return require('mq').TLO.Zone.ID() end)
    return ok and z or nil
end

-- about once a second from the main loop: read status, put saved swaps back after zoning / a real gear change
local next_tick = 0
function M.tick()
    local t = now()
    if t < next_tick then return end
    next_tick = t + 1000
    if M._pv and t >= M._pv.until_ms then M.preview_end(true) end
    local w = M.wanted()
    if next(M._moved) ~= nil and lib and M.available() then                -- shieldfix: hand point that held a shield
        for pt in pairs(M._moved) do if not w[pt] then pcall(function() lib.rml_orn_restore(pt) end) end end
        M._moved = {}
    end
    if next(w) == nil and not M.watching then return end
    if not M.available() then return end
    if not in_game() then return end
    local z = zone_id()
    if z ~= zone_sig then zone_sig = z; tries = {}; mtries = {} end   -- new zone: fresh tries
    M.poll()
    if st.verified ~= 1 or st.disabled or st.live ~= 0 or st.queued > 0 then return end
    for pt, tag in pairs(w) do
        local p = st.pts[pt]
        local tr = tries[pt]
        if M._pv and M._pv.pts[pt] then p = nil end                   -- being previewed: leave it alone
        if p and p.tag ~= tag then
            if tr and tr.sent and tr.tag == tag and t - tr.sent > 2500 and not tr.counted then
                tr.n = (tr.n or 0) + 1; tr.counted = true            -- the last try did not stick
            end
            if C.cfg.orn.auto ~= false and (not tr or ((tr.n or 0) < 3 and t >= (tr.next or 0))) then
                send(pt, tag)
                tries[pt].counted = false
            end
        elseif p and tr then
            tr.n, tr.counted = 0, true
        end
    end
    if C.cfg.orn.auto ~= false and st.mats then                     -- matfix: put saved region materials back
        for r, m in pairs(M.wanted_mats()) do
            local cur, tr = st.mats[r], mtries[r]
            if cur and cur.mat ~= m and (not tr or ((tr.n or 0) < 3 and t >= (tr.next or 0))) then send_mat(r, m) end
        end
    end
end

-- CombatFX stopping: put the real gear back unless the user chose to keep swaps until zoning
function M.shutdown()
    if M._pv then M.preview_end(true) end
    if C.cfg.orn.keep == true then return end
    if lib and avail and next(M.wanted()) ~= nil then pcall(function() lib.rml_orn_restore(-1) end) end
end

-- ---------------------------------------------------------------- sets (orn-sets): whole armor set in one click
-- ornament_sets.lua is generated from this client's NewArmorTagData (ID = block*10 + slot; one header and one archive
-- per block). Apply goes through M.apply per slot, so pairs (shoulders, wrists, hands, feet) send both points.
local SD, SD_race = nil, false
function M.sets()
    local race = M.my_race()
    if SD and SD_race == race then return SD end
    local d, derr = M.race_data(race)
    if not d or type(d.sets) ~= 'table' then return nil, derr or 'no sets for your race' end
    local list = {}
    for _, r in ipairs(d.sets) do
        local s = { id = r[1], name = r[2], arch = r[3], pieces = {} }
        local k = { 'set' .. r[1], r[2], r[3] }
        for _, p in ipairs(r[4]) do
            s.pieces[#s.pieces + 1] = { slot = p[1], it = p[2], pair = (p[3] or 0) ~= 0 and p[3] or nil }
            k[#k + 1] = 'it' .. p[2]; k[#k + 1] = tostring(p[2])
            if (p[3] or 0) ~= 0 then k[#k + 1] = 'it' .. p[3] end
        end
        s.key = string.lower(table.concat(k, ' '))
        list[#list + 1] = s
    end
    -- sets other races have but this one does not: listed greyed with the reason and another race's preview
    for _, r in ipairs(d.missing or {}) do
        list[#list + 1] = { id = r[1], name = r[2], arch = r[3], pieces = {}, missing = r[4], pv = r[5],
            key = string.lower(table.concat({ 'set' .. r[1], r[2], r[3] }, ' ')) }
    end
    SD, SD_race = { race = d.race, list = list, n = #d.sets, nmiss = #(d.missing or {}) }, race
    return SD
end

function M.set_favs()
    local t, set = {}, {}
    for v in tostring(C.cfg.orn.sfav or ''):gmatch('%d+') do
        local id = tonumber(v); if id and not set[id] then set[id] = true; t[#t + 1] = id end
    end
    return t, set
end
function M.toggle_set_fav(id)
    local list, set = M.set_favs()
    local out = {}
    for _, v in ipairs(list) do if v ~= id then out[#out + 1] = tostring(v) end end
    if not set[id] then out[#out + 1] = tostring(id) end
    C.cfg.orn.sfav = table.concat(out, ' ')
    C.save_cfg()
    return not set[id]
end

-- kind: 'all' | 'full' (all 7 slots) | 'fav'
function M.filter_sets(kind, q)
    local d = M.sets(); if not d then return {} end
    q = tostring(q or ''):lower():gsub('^%s+', ''):gsub('%s+$', '')
    local _, fav = M.set_favs()
    local out = {}
    for _, s in ipairs(d.list) do
        local okk = kind == 'all' or (kind == 'fav' and fav[s.id] and not s.missing) or (kind == 'full' and #s.pieces >= 7)
        if okk and (q == '' or s.key:find(q, 1, true)) then out[#out + 1] = s end
    end
    return out
end

-- catalog entry for a set piece (same object the slot grid uses, so M.apply sees the same it/pair)
local function piece_entry(p)
    local d = M.data()
    local e = d and d.by_it[p.it]
    if e and e.slot == p.slot and e.pair == p.pair then return e end
    return { it = p.it, pair = p.pair, slot = p.slot, label = 'IT' .. p.it }
end

-- every point a set covers: { [pt] = 'IT####' } (side 0 = it, side 1 = pair)
function M.set_points(s)
    local w = {}
    for _, p in ipairs(s.pieces) do
        local sl = M.SLOT[p.slot]
        if sl then
            for i, pt in ipairs(sl.pts) do
                local it = (i == 1) and p.it or p.pair
                if it then w[pt] = 'IT' .. it end
            end
        end
    end
    return w
end
-- 'on' when every point of the set is saved and showing, 'saved' when saved, nil otherwise
function M.set_state(s)
    if s.missing then return nil end
    local want, cur = M.wanted(), M.status()
    local all_on = true
    for pt, tag in pairs(M.set_points(s)) do
        if want[pt] ~= tag then return nil end
        local p = cur and cur.pts and cur.pts[pt]
        if not (p and p.tag == tag) then all_on = false end
    end
    return all_on and 'on' or 'saved'
end

M._setq = nil        -- { items = { {slot, entry}... }, next = ms, deadline = ms, done = {}, fail = {} }
local function save_points(add)
    local w = M.wanted()
    for pt, tag in pairs(add) do w[pt] = tag end
    local o = {}
    for pt, tag in pairs(w) do o[#o + 1] = string.format('%d:%s', pt, tag) end
    table.sort(o)
    C.cfg.orn.set = table.concat(o, ',')
    C.save_cfg()
end
local function is_qfull(why) return tostring(why or ''):find('queue full', 1, true) ~= nil end

-- one step of the set queue: send slots until the DLL says the queue is full, then wait a little
local function pump()
    local q = M._setq; if not q then return end
    local t = now()
    if t < q.next then return end
    while #q.items > 0 do
        local it = q.items[1]
        local ok, why = M.apply(it[2], it[1])
        if ok then
            table.remove(q.items, 1); q.done[#q.done + 1] = it[1]
        elseif is_qfull(why) and t < q.deadline then
            q.next = t + 350; return                                   -- DLL queue full: space the rest out
        else
            table.remove(q.items, 1); q.fail[#q.fail + 1] = it[1] .. ' (' .. tostring(why) .. ')'
        end
    end
    M._setq = nil
    M.last_set = q
end

-- apply a whole set: all points are saved first (auto re-apply keeps them even if a send has to wait),
-- then each slot goes through M.apply (pairs included); a -4 queue-full defers the rest by ~350 ms
-- portable: false when the EQ folder is known and the set's archive is not in it (another client / trimmed install);
-- nil = cannot tell (EQ folder not found) -> allowed, the client loads it or the DLL reports the failure
function M.set_missing(s)
    local okp, PT = pcall(require, 'combatfx.paths')
    if not okp or not s or not s.arch then return false end
    return PT.archive_ok(s.arch) == false
end
function M.apply_set(s)
    local ok, why = M.available()
    if not ok then return false, why end
    if s and s.missing then return false, s.missing end
    if not s or not s.pieces or #s.pieces == 0 then return false, 'empty set' end
    if M.set_missing(s) then return false, s.arch .. ' is not in your EQ folder (this client does not have that set)' end
    save_points(M.set_points(s))
    local items = {}
    for _, p in ipairs(s.pieces) do
        if M.SLOT[p.slot] then
            local e = piece_entry(p)
            local sm = M.mat_for(tostring(s.arch) .. ' ' .. tostring(s.name))                  -- matfix
            if sm then e = setmetatable({ mat = sm }, { __index = e }) end
            items[#items + 1] = { p.slot, e }
        end
    end
    local t = now()
    M._setq = { set = s, items = items, next = t, deadline = t + 20000, done = {}, fail = {} }
    pump()
    local q = M._setq or M.last_set
    if M._setq then
        return true, string.format('%d of %d slots sent, the rest follow in a moment', #q.done, #s.pieces)
    end
    if #q.fail > 0 then return false, 'some slots failed: ' .. table.concat(q.fail, ', ') end
    return true, string.format('%d slots sent', #q.done)
end
function M.set_busy() return M._setq ~= nil end

-- the set queue is pumped from the main loop (every call); the 1 Hz auto re-apply waits while it drains
local base_tick = M.tick
function M.tick()
    if M._setq then pump(); return end
    return base_tick()
end
local base_restore_all = M.restore_all
function M.restore_all() M._setq = nil; return base_restore_all() end

return M
