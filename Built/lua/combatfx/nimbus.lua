-- combatfx native nimbus (t362-nimbuspick): EQ's own spell nimbus on your character via MQ2RmlUi
-- rml_nimbus_add / rml_nimbus_remove / rml_nimbus_status (rml_features() & 2048). Client-side only.
-- One nimbus at a time (the DLL keeps one; a new add replaces the old). The DLL removes it on zone-out
-- and re-adds it after zone-in by itself; this module only sets what is wanted and reads the status.
local ffi = require('ffi')
local C = require('combatfx.core')
local D = require('combatfx.nimbus_data')
local M = { REV = 't362-nimbuspick', D = D }
local FEAT_NIMBUS = 2048

local lib, probed = nil, false
local avail, avail_why, next_avail = false, 'not checked', 0
local status_raw, status_t, status = '', 0, {}
local started, applied_id, applied_t, rejected = false, 0, 0, nil

local function now()
    local ok, t = pcall(function() return require('mq').gettime() end)
    if ok and tonumber(t) then return tonumber(t) end
    return math.floor(os.clock() * 1000)
end

local function load_lib()
    if probed then return lib end
    probed = true
    for _, d in ipairs({ 'int rml_api_version();', 'int rml_features();', 'int rml_nimbus_add(int);',
        'int rml_nimbus_add_ex(int, int);', 'int rml_nimbus_remove(int);', 'const char* rml_nimbus_status();' }) do
        pcall(ffi.cdef, d)
    end
    local dll = os.getenv('COMBATFX_API_DLL')
    local ok, l = false, nil
    if dll and dll ~= '' then ok, l = pcall(ffi.load, dll) end
    if not (ok and l) then ok, l = pcall(ffi.load, 'MQ2RmlUi') end
    if not (ok and l) then ok, l = pcall(ffi.load, 'mq2rmlui') end
    lib = (ok and l) or nil
    return lib
end

-- headless tests only: inject a fake library table
function M._set_lib(l) lib, probed, next_avail = l, true, 0 end

local function has(fn) local ok, f = pcall(function() return lib[fn] end); return ok and f ~= nil end

function M.available()
    local t = now()
    if t < next_avail then return avail, avail_why end
    next_avail = t + 5000
    load_lib()
    if not lib then avail, avail_why = false, 'MQ2RmlUi not loaded'; return avail, avail_why end
    local feat = 0
    if has('rml_features') then pcall(function() feat = tonumber(lib.rml_features()) or 0 end) end
    if math.floor(feat / FEAT_NIMBUS) % 2 ~= 1 then
        avail, avail_why = false, 'this MQ2RmlUi has no native nimbus (feature 2048 missing)'
    elseif not (has('rml_nimbus_add') and has('rml_nimbus_remove') and has('rml_nimbus_status')) then
        avail, avail_why = false, 'MQ2RmlUi is missing the nimbus exports'
    else
        avail, avail_why = true, 'ready'
    end
    return avail, avail_why
end

local function bx() return C.cfg.bodyfx end
function M.wanted_id()
    local b = bx()
    if not b or b.on ~= true then return 0 end
    return math.floor(tonumber(b.native) or 0)
end
-- true while a native nimbus is selected and Body FX is on: the old overlay glow stays off
function M.active() return M.wanted_id() > 0 end

local function parse(s)
    local t = { raw = s }
    for k, v in s:gmatch('(%a+)=([^%s]+)') do t[k] = v end
    t.verified = tonumber((t.verified or ''):match('^(%-?%d+)') or '') or 0
    t.want, t.active, t.alive, t.live = tonumber(t.want) or 0, tonumber(t.active) or 0, tonumber(t.alive) or -1, tonumber(t.live) or -1
    t.disabled = t.disabled == '1'
    t.last = s:match('last=(.*)$') or ''
    return t
end

function M.poll_status()
    if not M.available() then return status end
    local s = nil
    pcall(function() local p = lib.rml_nimbus_status(); if p ~= nil then s = ffi.string(p) end end)
    if s then status_raw, status, status_t = s, parse(s), now() end
    return status
end

function M.apply(id)
    id = math.floor(tonumber(id) or 0)
    if id <= 0 then return M.clear() end
    if not M.available() then return false, avail_why end
    local rc = -99
    pcall(function() rc = tonumber(lib.rml_nimbus_add(id)) or -99 end)
    if rc <= 0 then
        local why = ({ [-1] = 'disabled after a fault this session', [-2] = 'client build not verified', [-3] = 'bad id' })[rc] or ('error ' .. rc)
        return false, why
    end
    applied_id, applied_t, rejected = id, now(), nil
    return true, rc
end

function M.clear()
    applied_id, rejected = 0, nil
    if not (lib and avail) then return false end
    pcall(function() lib.rml_nimbus_remove(0) end)
    return true
end

-- what Body FX settings say -> DLL (called after any change in the UI and on Body FX on/off)
function M.sync()
    local id = M.wanted_id()
    if id > 0 then
        if id ~= applied_id then return M.apply(id) end
        return true
    end
    if applied_id ~= 0 or (status.want or 0) ~= 0 or (status.active or 0) ~= 0 then M.clear() end
    return true
end

local function in_game()
    local ok, v = pcall(function()
        local mq = require('mq')
        local gs = mq.TLO.EverQuest and mq.TLO.EverQuest.GameState and mq.TLO.EverQuest.GameState()
        if gs and gs ~= 'INGAME' then return false end
        local me = mq.TLO.Me
        local id = me and me.ID and me.ID()
        return (tonumber(id) or 0) > 0
    end)
    return ok and v == true
end

-- main loop, about once a second: re-apply the saved pick once on script start, read the status
local next_tick = 0
function M.tick()
    local t = now()
    if t < next_tick then return end
    next_tick = t + 1000
    if not M.available() then return end
    if not started and in_game() then
        started = true
        if M.wanted_id() > 0 and applied_id ~= M.wanted_id() then M.apply(M.wanted_id()) end
    end
    M.poll_status()
    if applied_id > 0 and not rejected and t - applied_t > 2500 and status.want == 0 and status.active == 0
        and not status.disabled and status_t > applied_t then
        rejected = applied_id                  -- the DLL refused the record (not a stage-2 nimbus)
    end
end

function M.shutdown()
    if lib and avail and (applied_id ~= 0 or M.wanted_id() > 0 or (status.want or 0) ~= 0) then
        pcall(function() lib.rml_nimbus_remove(0) end)
    end
    applied_id = 0
end

local function nm(id)
    local n = D.by_id[id]
    return n and string.format('%d %s', id, n.name) or tostring(id)
end
-- one friendly line + the raw DLL line, for the Body FX tab
function M.status_text()
    local ok, why = M.available()
    if not ok then return 'Unavailable: ' .. why, '' end
    local s = status
    if not s.raw then return 'Waiting for the first status read...', '' end
    local f
    if s.disabled then f = 'Disabled for this session after a fault (see Logs\\rmlui_canvas.log)'
    elseif s.verified ~= 1 then f = 'Client build not verified: native nimbus off'
    elseif rejected then f = 'The client refused ' .. nm(rejected) .. ' (not a body nimbus record)'
    elseif s.active > 0 then f = 'On: ' .. nm(s.active) .. (s.alive >= 0 and string.format(' &#183; %d emitters alive', s.alive) or '')
    elseif s.want > 0 then f = 'Starting ' .. nm(s.want) .. ' (waits for zone-in / a stable character)'
    elseif M.wanted_id() > 0 then f = 'Selected ' .. nm(M.wanted_id()) .. ', not applied yet'
    else f = 'Off' end
    return f, s.raw
end

function M.favs()
    local t, set = {}, {}
    for v in tostring(bx().nfav or ''):gmatch('%d+') do
        local id = tonumber(v); if id and D.by_id[id] and not set[id] then set[id] = true; t[#t + 1] = id end
    end
    return t, set
end
function M.toggle_fav(id)
    local list, set = M.favs()
    local out = {}
    for _, v in ipairs(list) do if v ~= id then out[#out + 1] = v end end
    if not set[id] then out[#out + 1] = id end
    for i, v in ipairs(out) do out[i] = tostring(v) end
    bx().nfav = table.concat(out, ' ')
    return not set[id]
end

-- filter: cat = 'all' | 'fav' | category id; q = search text
function M.filter(cat, q)
    q = tostring(q or ''):lower():gsub('^%s+', ''):gsub('%s+$', '')
    local _, fav = M.favs()
    local out = {}
    for _, n in ipairs(D.list) do
        local okc = cat == 'all' or (cat == 'fav' and fav[n.id]) or n.cat == cat
        if okc and (q == '' or n.key:find(q, 1, true)) then out[#out + 1] = n end
    end
    return out
end

return M
