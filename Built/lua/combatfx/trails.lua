-- combatfx foot trails (t485-foottrail): every Trail-tab look is played by EQ itself the way its own nimbus foot trails
-- work (Nimbus of Lava #566 and friends): persistent stage-2 emitters on LFOOT / RFOOT with follow_attachment 0, so each
-- particle stays where it was born and walking leaves a trail on the ground. EQ draws it in the world (never over you).
--   * EQ trails (#473 Burning Steps, #566 Lava, ...): the stock records, native slot 2 (rml_nimbus_add_slot(2, id, 0))
--   * the 12 CombatFX looks (Fire, Frost, ...): custom records cloned from stock emitters with 566's trail settings,
--     ids 31845..31856, same slot (MQ2RmlUi feature 1048576)
-- The DLL forces EQ's particle density/opacity to 100% while it creates them (t472), so they show with EQ's own spell
-- particles turned down or off. Without the t485 DLL the old screen-drawn marks (canvas.lua) stay as the fallback.
local ffi = require('ffi')
local C = require('combatfx.core')
local M = { REV = 't488-solid', SLOT = 2, PREVIEW_MS = 12000, BASE = 31744 }
local FEAT_NIMBUS, FEAT_SLOT2, FEAT_TRAIL = 2048, 32768, 1048576

-- the CombatFX looks, in C.FX_STYLES order -> custom record ids (procwrap/custom/trail_catalog.py, same order)
local STYLES = { 'inferno', 'frost', 'toxic', 'disease', 'arcane', 'storm', 'shadow', 'holy', 'blood', 'wind', 'water', 'earth' }
local LABEL = { inferno = 'Fire', frost = 'Frost', toxic = 'Poison', disease = 'Disease', arcane = 'Arcane', storm = 'Lightning',
    shadow = 'Shadow', holy = 'Holy', blood = 'Blood', wind = 'Wind', water = 'Water', earth = 'Earth' }
local D = { list = {}, by_id = {}, by_style = {} }
M.D = D
for i, st in ipairs(STYLES) do
    local n = { id = M.BASE + 100 + i, name = LABEL[st], style = st, kind = 'new' }
    D.list[#D.list + 1] = n; D.by_id[n.id] = n; D.by_style[st] = n
end
-- EQ's own foot-trail nimbus records (spellsnew.eff stage 2: feet emitters, follow 0, duration -5000)
for _, n in ipairs({
    { id = 566, name = 'Lava', spell = 'Nimbus of Lava' },
    { id = 473, name = 'Burning Steps', spell = 'Nimbus of Burning Steps' },
    { id = 641, name = 'Path of Fire', spell = 'Path of Fire Nimbus' },
    { id = 545, name = 'Path of Skulls', spell = 'Path of Skulls Nimbus' },
    { id = 609, name = 'Path of Decay', spell = 'Path of Decay' },
    { id = 578, name = 'Path of Tunare', spell = 'Path of Tunare' },
    { id = 475, name = 'Lucky Clover', spell = 'Lucky Feet' },
    { id = 568, name = 'Mountain Walker', spell = 'Tread of the Mountain Walker' },
    { id = 517, name = 'Crystal Growth', spell = 'Nimbus of Crystal Growth' },
    { id = 546, name = 'Blood Mist', spell = 'Nimbus of Blood' },
}) do
    n.kind = 'eq'; D.list[#D.list + 1] = n; D.by_id[n.id] = n
end
function M.thumb(id) return string.format('../img/thumbtr_%d.png', id) end

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
function M._reset() started, applied_id, applied_t, rejected, last_err, preview_id, preview_until, status, status_t = false, 0, 0, nil, nil, 0, 0, {}, 0 end

local function has(fn) local ok, f = pcall(function() return lib[fn] end); return ok and f ~= nil end
local function bit(v, b) return math.floor(v / b) % 2 == 1 end

-- available(): native trails can be played (the t485 DLL: slot 2 with custom trail records)
function M.available()
    local t = now()
    if t < next_avail then return avail, avail_why end
    next_avail = t + 5000
    load_lib()
    if not lib then avail, avail_why = false, 'MQ2RmlUi not loaded'; return avail, avail_why end
    local feat = 0
    if has('rml_features') then pcall(function() feat = tonumber(lib.rml_features()) or 0 end) end
    if not bit(feat, FEAT_NIMBUS) or not bit(feat, FEAT_SLOT2) or not (has('rml_nimbus_add_slot') and has('rml_nimbus_remove_slot') and has('rml_nimbus_status_slot')) then
        avail, avail_why = false, 'this MQ2RmlUi has no native effect slots'
    elseif not bit(feat, FEAT_TRAIL) then
        avail, avail_why = false, 'this MQ2RmlUi has no foot-trail slot yet (install the t485 build)'
    else
        avail, avail_why = true, 'ready'
    end
    return avail, avail_why
end

-- cfg: C.cfg.runtrail = { on, style, id }; id = the native trail record (old configs: picked from the saved style)
function M.cfg()
    C.cfg.runtrail = C.cfg.runtrail or { on = true, style = 'inferno' }
    local rt = C.cfg.runtrail
    if not D.by_id[tonumber(rt.id) or 0] then
        local n = D.by_style[rt.style or 'inferno'] or D.by_style.inferno
        rt.id = n.id
    end
    return rt
end
function M.saved_id() local rt = M.cfg(); return math.floor(tonumber(rt.id) or 0) end
function M.paused() return not C.particles_on() end
function M.previewing() return preview_id > 0 and now() < preview_until end
function M.wanted_id()
    if M.previewing() then return preview_id end
    local rt = M.cfg()
    if C.cfg.master == false or M.paused() or not rt.on then return 0 end
    return M.saved_id()
end
-- native(): the native path owns the trail (canvas.lua's screen marks stay off); false = screen fallback
function M.native()
    local ok = M.available()
    return ok == true
end

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
    [-4] = 'this MQ2RmlUi has no trail slot', [-5] = 'that effect is already worn as your Body FX or Aura',
    [-7] = 'custom effects are off this session' }
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

function M.sync()
    if not M.native() then return false end
    local id = M.wanted_id()
    if id > 0 then
        if id ~= applied_id and rejected ~= id then return add(id) end
        return true
    end
    if applied_id ~= 0 or (status.want or 0) ~= 0 or (status.active or 0) ~= 0 then remove() end
    return true
end

-- UI actions ------------------------------------------------------------------------------------------
function M.select(id)                     -- click on a picture: just remember it (Preview / Wear act on it)
    id = math.floor(tonumber(id) or 0)
    if not D.by_id[id] then return false, 'unknown trail' end
    M.sel = id
    return true
end
function M.preview(id)                    -- wear it for PREVIEW_MS without saving, then back to the saved one
    id = math.floor(tonumber(id or M.sel) or 0)
    local n = D.by_id[id]
    if not n then return false, 'pick a trail first' end
    if not M.native() then                -- old DLL: the screen-drawn marks show the look
        local CV = package.loaded['combatfx.canvas']
        if CV and CV.preview_trail then pcall(CV.preview_trail, n.style or 'inferno') end
        return n.style ~= nil, n.style and 'screen preview (native trails need the t485 DLL)' or avail_why
    end
    preview_id, preview_until, rejected = id, now() + M.PREVIEW_MS, nil
    return M.sync()
end
function M.wear(id)                        -- save it (comes back on every start) and switch the trail on
    id = math.floor(tonumber(id or M.sel) or 0)
    local n = D.by_id[id]
    if not n then return false, 'pick a trail first' end
    local rt = M.cfg()
    rt.id, rt.on = id, true
    if n.style then rt.style = n.style end  -- the screen fallback uses the same look
    preview_id, rejected = 0, nil
    M.save_now()
    M.sync()
    return true
end
function M.off()
    local rt = M.cfg()
    rt.on, preview_id, rejected = false, 0, nil
    M.save_now()
    remove()
    return true
end

-- t488: Wear / Off hit the disk at once (not the 0.8 s debounce), so a /lua stop, reload or zone right after keeps it
function M.save_now()
    if C.save_cfg_now then pcall(C.save_cfg_now) elseif C.save_cfg then pcall(C.save_cfg) end
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
    if applied_id > 0 and not rejected and t - applied_t > 4000 and status_t > applied_t
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

local function nm(id) local n = D.by_id[id]; return n and n.name or ('#' .. tostring(id)) end
function M.status_text()
    local ok, why = M.available()
    if not ok then return 'Old screen trail in use: ' .. why, '' end
    local s, rt = status, M.cfg()
    if not s.raw then return 'Waiting for the first status read...', '' end
    local f
    if s.disabled then f = 'Disabled for this session after a fault (see Logs\\rmlui_canvas.log)'
    elseif s.verified ~= 1 then f = 'Client build not verified: native trails off'
    elseif last_err then f = 'Could not apply: ' .. last_err
    elseif rejected then f = 'The client refused ' .. nm(rejected)
    elseif not rt.on and not M.previewing() then f = 'Off: nothing worn. Pick a trail and press Wear to keep it on'
    elseif M.paused() and not M.previewing() then f = 'Paused: Particle effects are off or the performance tier is Low'
    elseif s.active > 0 then
        if M.previewing() then
            local back = (rt.on and C.cfg.master ~= false) and ('then back to ' .. nm(M.saved_id())) or 'then off, press Wear to keep it'
            f = string.format('Preview %ds: %s (%s)', math.max(0, math.ceil((preview_until - now()) / 1000)), nm(s.active), back)
        else f = 'On: ' .. nm(s.active) end
    elseif s.want > 0 then f = 'Starting ' .. nm(s.want) .. ' (waits for zone-in / a stable character)'
    else f = 'Selected ' .. nm(M.saved_id()) .. ', not applied yet' end
    return f, s.raw
end

return M
