-- combatfx native aura (t436-nativeaura): EQ's own persistent ground/feet particle records on your character.
-- Same native call as the Body FX nimbus (eqgame ActivateStateFlavorSpellParticleEffect, OP_AddNimbusEffect
-- handler) but in MQ2RmlUi's second slot (rml_nimbus_add_slot(1, id, 0); rml_features() & 32768), so a
-- body nimbus and a ground aura can be worn together. EQ draws them in world space attached to your
-- model, so they keep their size whatever the camera does. Client-side only: nobody else sees them.
-- Pauses (removed, re-added later) while 'Particle effects' is off or the performance tier is Low.
local ffi = require('ffi')
local C = require('combatfx.core')
local D = require('combatfx.aura_data')
local M = { REV = 't436-nativeaura', D = D, SLOT = 1, PREVIEW_MS = 12000 }
local FEAT_NIMBUS, FEAT_SLOT2 = 2048, 32768

local lib, probed = nil, false
local avail, avail_why, next_avail = false, 'not checked', 0
local status_t, status = 0, {}
local started, applied_id, applied_t, rejected, last_err = false, 0, 0, nil, nil
local preview_id, preview_until = 0, 0

local function now()
    local ok, t = pcall(function() return require('mq').gettime() end)
    if ok and tonumber(t) then return tonumber(t) end
    return math.floor(os.clock() * 1000)
end

local function load_lib()
    if probed then return lib end
    probed = true
    for _, d in ipairs({ 'int rml_api_version();', 'int rml_features();', 'int rml_nimbus_add_slot(int, int, int);',
        'int rml_nimbus_remove_slot(int);', 'const char* rml_nimbus_status_slot(int);' }) do
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
function M._set_lib(l) lib, probed, next_avail = l, true, 0 end   -- headless tests only

local function has(fn) local ok, f = pcall(function() return lib[fn] end); return ok and f ~= nil end
local function bit(v, b) return math.floor(v / b) % 2 == 1 end

function M.available()
    local t = now()
    if t < next_avail then return avail, avail_why end
    next_avail = t + 5000
    load_lib()
    if not lib then avail, avail_why = false, 'MQ2RmlUi not loaded'; return avail, avail_why end
    local feat = 0
    if has('rml_features') then pcall(function() feat = tonumber(lib.rml_features()) or 0 end) end
    if not bit(feat, FEAT_NIMBUS) then
        avail, avail_why = false, 'this MQ2RmlUi has no native effects (feature 2048 missing)'
    elseif not bit(feat, FEAT_SLOT2) or not (has('rml_nimbus_add_slot') and has('rml_nimbus_remove_slot') and has('rml_nimbus_status_slot')) then
        avail, avail_why = false, 'this MQ2RmlUi has no second native slot (feature 32768); install the t436 build'
    else
        avail, avail_why = true, 'ready'
    end
    return avail, avail_why
end

function M.cfg()
    C.cfg.naura = C.cfg.naura or { id = 0 }
    return C.cfg.naura
end
function M.saved_id() return math.floor(tonumber(M.cfg().id) or 0) end
-- paused: the particle master is off or the perf tier is Low (C.particles_on covers both)
function M.paused() return not C.particles_on() end
function M.previewing() return preview_id > 0 and now() < preview_until end
function M.wanted_id()
    if M.previewing() then return preview_id end
    if C.cfg.master == false or M.paused() then return 0 end
    return M.saved_id()
end
-- true while a native aura is saved: the old screen-drawn feet disc stays off (canvas.lua aura_wanted)
function M.active() return M.saved_id() > 0 or M.previewing() end

local function parse(s)
    local t = { raw = s }
    for k, v in s:gmatch('(%a+)=([^%s]+)') do t[k] = v end
    t.verified = tonumber((t.verified or ''):match('^(%-?%d+)') or '') or 0
    t.want, t.active, t.alive = tonumber(t.want) or 0, tonumber(t.active) or 0, tonumber(t.alive) or -1
    t.disabled = t.disabled == '1'
    return t
end
function M.poll_status()
    if not M.available() then return status end
    local s
    pcall(function() local p = lib.rml_nimbus_status_slot(M.SLOT); if p ~= nil then s = ffi.string(p) end end)
    if s then status, status_t = parse(s), now() end
    return status
end

local WHY = { [-1] = 'disabled after a fault this session', [-2] = 'client build not verified', [-3] = 'bad id',
    [-4] = 'bad slot', [-5] = 'that effect is already worn as your Body FX nimbus' }
local function add(id)
    if not M.available() then return false, avail_why end
    local rc = -99
    pcall(function() rc = tonumber(lib.rml_nimbus_add_slot(M.SLOT, id, 0)) or -99 end)
    if rc <= 0 then last_err = WHY[rc] or ('error ' .. rc); return false, last_err end
    applied_id, applied_t, rejected, last_err = id, now(), nil, nil
    return true, rc
end
local function remove()
    applied_id = 0
    if lib and avail then pcall(function() lib.rml_nimbus_remove_slot(M.SLOT) end) end
end

-- what is wanted -> DLL (cheap; called from tick and after UI actions)
function M.sync()
    local id = M.wanted_id()
    if id > 0 then
        if id ~= applied_id and rejected ~= id then return add(id) end
        return true
    end
    if applied_id ~= 0 or (status.want or 0) ~= 0 or (status.active or 0) ~= 0 then remove() end
    return true
end

-- UI actions --------------------------------------------------------------------------------------
-- Preview: wear it for PREVIEW_MS without saving, then go back to what was saved
function M.preview(id)
    id = math.floor(tonumber(id) or 0)
    if not D.by_id[id] then return false, 'unknown aura' end
    preview_id, preview_until, rejected = id, now() + M.PREVIEW_MS, nil
    return M.sync()
end
-- Wear: save it (comes back on every start)
function M.wear(id)
    id = math.floor(tonumber(id) or 0)
    if not D.by_id[id] then return false, 'unknown aura' end
    local a = M.cfg()
    if a.id ~= id then a.prev = a.id end
    a.id, preview_id, rejected = id, 0, nil
    if C.save_cfg then pcall(C.save_cfg) end
    return M.sync()
end
-- Restore: take the native aura off (and any preview) -> back to the old feet disc setting / nothing
function M.restore()
    local a = M.cfg()
    if a.id ~= 0 then a.prev = a.id end
    a.id, preview_id, rejected = 0, 0, nil
    if C.save_cfg then pcall(C.save_cfg) end
    remove()
    return true
end

local function in_game()
    local ok, v = pcall(function()
        local mq = require('mq')
        local gs = mq.TLO.EverQuest and mq.TLO.EverQuest.GameState and mq.TLO.EverQuest.GameState()
        if gs and gs ~= 'INGAME' then return false end
        local me = mq.TLO.Me
        return (tonumber(me and me.ID and me.ID()) or 0) > 0
    end)
    return ok and v == true
end

local next_tick = 0
function M.tick()
    local t = now()
    if t < next_tick then return end
    next_tick = t + 1000
    if not M.available() then return end
    if not started then
        if not in_game() then return end
        started = true
    end
    if preview_id > 0 and t >= preview_until then preview_id = 0 end
    M.sync()
    M.poll_status()
    if applied_id > 0 and not rejected and t - applied_t > 2500 and status_t > applied_t
        and status.want == 0 and status.active == 0 and not status.disabled then
        rejected = applied_id; applied_id = 0             -- the DLL refused the record
    end
end

function M.shutdown()
    if lib and avail and (applied_id ~= 0 or (status.want or 0) ~= 0 or (status.active or 0) ~= 0) then
        pcall(function() lib.rml_nimbus_remove_slot(M.SLOT) end)
    end
    applied_id, preview_id = 0, 0
end

local function nm(id) local n = D.by_id[id]; return n and string.format('%s (#%d)', n.name, id) or ('#' .. tostring(id)) end
function M.status_text()
    local ok, why = M.available()
    if not ok then return 'Unavailable: ' .. why, '' end
    local s = status
    if not s.raw then return 'Waiting for the first status read...', '' end
    local f
    if s.disabled then f = 'Disabled for this session after a fault (see Logs\\rmlui_canvas.log)'
    elseif s.verified ~= 1 then f = 'Client build not verified: native auras off'
    elseif last_err then f = 'Could not apply: ' .. last_err
    elseif rejected then f = 'The client refused ' .. nm(rejected)
    elseif M.saved_id() > 0 and M.paused() and not M.previewing() then f = 'Paused: Particle effects are off or the performance tier is Low (' .. nm(M.saved_id()) .. ' comes back)'
    elseif s.active > 0 then
        f = (M.previewing() and string.format('Preview %ds: ', math.max(0, math.ceil((preview_until - now()) / 1000))) or 'On: ') .. nm(s.active)
            .. (s.alive >= 0 and string.format(' &#183; %d emitters alive', s.alive) or '')
    elseif s.want > 0 then f = 'Starting ' .. nm(s.want) .. ' (waits for zone-in / a stable character)'
    elseif M.saved_id() > 0 then f = 'Selected ' .. nm(M.saved_id()) .. ', not applied yet'
    else f = 'Off &#183; the old feet disc below is used if it is switched on' end
    return f, s.raw
end

function M.filter(cat)
    local out = {}
    for _, n in ipairs(D.list) do
        if cat == 'all' or cat == nil or n.cat == cat then out[#out + 1] = n end
    end
    return out
end

return M
