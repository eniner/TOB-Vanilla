-- combatfx native proc effects (t464-procwrap): your procs (and, with 'Also on crits', your crits) play one of EQ's own
-- spell-hit records ON A BODY instead of a burst drawn over the screen. MQ2RmlUi calls the client's own
-- ActivateStateFlavorSpellParticleEffect (the OP_AddNimbusEffect handler, rml_nimbus_burst; rml_features() & 65536) for the
-- spawn, so EQ attaches the record's stage-2 emitters to that spawn's bones in the 3D world: they wrap the body, keep their
-- world size when the camera moves and are hidden by walls like any spell. Client-side only: nobody else sees them.
-- Where: your target (where the old burst was drawn) or you. Off / unavailable -> the old screen-drawn look is used.
local ffi = require('ffi')
local C = require('combatfx.core')
local D = require('combatfx.proc_data')
-- t465: the 1.1 s bursts (2200 ms x 50% Duration) were cut before they could be seen: native effects now last at least
-- MIN_MS (Duration can only lengthen them), the Preview at least PREVIEW_MIN_MS, and the Preview falls back to you
-- (rml_nimbus_burst_ex flag 1) when the target cannot take it, with the reason on the status line.
-- t468: NEW effects (D.custom, ids D.CUSTOM_BASE + n) that are not in EQ's files: MQ2RmlUi adds their emitters (built on EQ's
-- own textures) to the client in memory and plays them like EQ's own (feature 131072). Auto prefers them; the EQ records stay
-- under 'Stock EQ' and are what Auto uses when this MQ2RmlUi has no custom effects.
-- t469: Size and Brightness (Proc FX look options) now also drive the native effects: rml_nimbus_custom_tune (feature 262144)
-- writes them into the custom emitter records (opacity, colour, particle count, quad size); Brightness >= 150% also plays
-- EQ's own records twice (layered). Stock EQ lists every usable EQ record (D.stock, sub-groups D.stock_cats); s0 records
-- (no on-body stage) play their caster stage and need the custom feature too.
local M = { REV = 't469-procwrap', D = D, MS = 3000, MIN_MS = 2500, PREVIEW_MS = 4500, PREVIEW_MIN_MS = 4000, MAX_MS = 8000,
    GAP_MS = 700, TFAIL_RETRY_MS = 10000 }
local FEAT_NIMBUS, FEAT_BURST, FEAT_CUSTOM, FEAT_TUNE = 2048, 65536, 131072, 262144

local lib, probed = nil, false
local avail, avail_why, next_avail = false, 'not checked', 0
local cavail, cavail_why = false, 'not checked'   -- t468 custom effects (feature 131072)
local last_t, last_id, last_err, last_where = -1e9, 0, nil, ''
local status, status_t = {}, 0
local preview_id, preview_until = 0, 0

local function now()
    local ok, t = pcall(function() return require('mq').gettime() end)
    if ok and tonumber(t) then return tonumber(t) end
    return math.floor(os.clock() * 1000)
end

local function load_lib()
    if probed then return lib end
    probed = true
    for _, d in ipairs({ 'int rml_api_version();', 'int rml_features();', 'int rml_nimbus_burst(int, int, int);', 'int rml_nimbus_burst_ex(int, int, int, int);',
        'int rml_nimbus_burst_stop();', 'const char* rml_nimbus_burst_status();', 'const char* rml_nimbus_custom_info();', 'int rml_nimbus_custom_tune(int, int);' }) do
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
function M._set_lib(l) lib, probed, next_avail, last_t = l, true, 0, -1e9 end   -- headless tests only

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
    elseif not bit(feat, FEAT_BURST) or not (has('rml_nimbus_burst') and has('rml_nimbus_burst_status')) then
        avail, avail_why = false, 'this MQ2RmlUi has no native proc effects (feature 65536); install the t464 build'
    else
        avail, avail_why = true, 'ready'
    end
    if not avail then cavail, cavail_why = false, avail_why
    elseif not bit(feat, FEAT_CUSTOM) then
        cavail, cavail_why = false, 'this MQ2RmlUi has no custom proc effects (feature 131072): install the t468 build; the Stock EQ records are used'
    else cavail, cavail_why = true, 'ready' end
    M._tune_ok = avail and bit(feat, FEAT_TUNE) and has('rml_nimbus_custom_tune')
    return avail, avail_why
end
-- t468: the NEW effects can be played (custom ids); false -> Auto uses the Stock EQ records
function M.custom_available() M.available(); return cavail, cavail_why end
function M.is_custom(id) local n = D.by_id[id]; return n ~= nil and n.custom == true end
-- t469: needs the custom feature (a NEW effect, or an EQ record played from its caster stage)
function M.needs_custom(id) local n = D.by_id[id]; return n ~= nil and (n.custom == true or n.s0 == true) end
-- t469: caster-stage plays came with feature 262144 (a t468 MQ2RmlUi has 131072 but would refuse them)
function M.s0_available() M.available(); return (M.custom_available()) and M._tune_ok == true end
-- t469: Size / Brightness -> the DLL (only when they change; applied to the records on the next play)
function M.tune()
    if not M._tune_ok then return false end
    local fs = C.cfg.fxstyle or {}
    local b, z = tonumber(fs.intensity) or 100, tonumber(fs.size) or 100
    if M._tuned_b == b and M._tuned_s == z then return true end
    local okc = pcall(function() lib.rml_nimbus_custom_tune(b, z) end)
    if okc then M._tuned_b, M._tuned_s = b, z end
    return okc
end
function M.custom_info()
    if not (M.available()) or not has('rml_nimbus_custom_info') then return '' end
    local s = ''
    pcall(function() local p = lib.rml_nimbus_custom_info(); if p ~= nil then s = ffi.string(p) end end)
    return s
end

function M.cfg()
    local c = C.cfg.nproc
    if type(c) ~= 'table' then c = { mode = 'auto', id = 0, where = 'target' }; C.cfg.nproc = c end
    if c.mode ~= 'auto' and c.mode ~= 'pick' and c.mode ~= 'off' then c.mode = 'auto' end
    if c.where ~= 'target' and c.where ~= 'self' then c.where = 'target' end
    c.id = math.floor(tonumber(c.id) or 0)
    return c
end
function M.on() return M.cfg().mode ~= 'off' end
-- the record for one event: the picked one, or Auto by the proc's element (crits: Auto uses the physical record)
local RT = { fire = 'Fire', cold = 'Cold', poison = 'Poison', disease = 'Disease', magic = 'Magic', chromatic = 'Chromatic',
    prismatic = 'Prismatic', corruption = 'Corruption', unresistable = 'Unresistable', lifetap = 'Lifetap', physical = 'Physical' }
function M.norm_rt(rt) return RT[string.lower(tostring(rt or 'magic'))] or 'Magic' end
function M.pick_id(kind, rt)
    local c = M.cfg()
    local cok = (M.custom_available())
    if c.mode == 'pick' and D.by_id[c.id] and (cok or not M.needs_custom(c.id)) and (not D.by_id[c.id].s0 or M.s0_available()) then return c.id end
    local A = cok and D.auto or D.auto_stock           -- a picked NEW effect without custom support: Auto from the EQ records
    if kind == 'crit' then return A.crit end
    return A[M.norm_rt(rt)] or A.Magic
end
-- true when this kind goes to the native path (crits only with Proc FX > 'Also on crits')
function M.wants(kind)
    if not M.on() then return false end
    if kind == 'crit' then
        local fs = C.cfg.fxstyle
        if not (fs and fs.scope == 'both') then return false end
    elseif kind ~= 'proc' then return false end
    return (M.available())
end

local function target_spawn(where)
    if where == 'self' then return 0, 'you' end
    local id, nm = 0, nil
    pcall(function() local mq = require('mq'); id = tonumber(mq.TLO.Target.ID()) or 0; nm = mq.TLO.Target.CleanName() end)
    if id > 0 and id <= 0xFFFF then return id, (nm and nm ~= '' and nm ~= 'NULL') and tostring(nm) or ('target #' .. id) end
    return 0, 'you (no target)'
end
M._target_spawn = target_spawn
function M.dur_ms(base, lo)
    local fs = C.cfg.fxstyle or {}
    local ms = math.floor(base * (tonumber(fs.duration) or 100) / 100)
    return math.max(lo, math.min(M.MAX_MS, ms))
end

local WHY = { [-1] = 'disabled after a fault this session', [-2] = 'client build not verified', [-3] = 'bad id',
    [-5] = 'that effect is already worn on you (Body FX / aura)', [-6] = 'bad spawn id',
    [-7] = 'custom effects are off in this session (see Logs\\rmlui_canvas.log)' }
local function burst(id, ms, where, flags)
    local spawn, wtxt = target_spawn(where)
    M.tune()
    local rc = -99
    if flags and flags ~= 0 and has('rml_nimbus_burst_ex') then
        pcall(function() rc = tonumber(lib.rml_nimbus_burst_ex(spawn, id, ms, flags)) or -99 end)
    else
        pcall(function() rc = tonumber(lib.rml_nimbus_burst(spawn, id, ms)) or -99 end)
    end
    if rc <= 0 then last_err = WHY[rc] or ('error ' .. rc); return false, last_err, rc, spawn end
    last_id, last_err, last_where = id, nil, wtxt
    return true, wtxt, rc, spawn
end

-- One proc / crit event. Returns true when the native path owns it (played, rate-limited or particles off), so the caller
-- draws nothing on the screen; false = not native (off / unavailable / refused): the caller keeps the old look.
function M.fire(kind, rt)
    if not M.wants(kind) then return false end
    if not C.particles_on() then return true end
    local t = now()
    if t - last_t < M.GAP_MS then return true end
    -- the client made no emitters on your targets lately (see the status line): screen look for target procs, retry every 10 s
    if M.cfg().where == 'target' then
        local s = M.poll_status()
        if (s.tfail or 0) > 0 and t - (M._tfail_try or -1e9) < M.TFAIL_RETRY_MS then return false end
        if (s.tfail or 0) > 0 then M._tfail_try = t end
    end
    local ms = M.dur_ms(M.MS, M.MIN_MS)
    local id = M.pick_id(kind, rt)
    local ok, _, rc = burst(id, ms, M.cfg().where)
    if not ok and rc == -7 and M.is_custom(id) then   -- custom effects went off this session: the Stock EQ record for the element
        cavail, cavail_why = false, WHY[-7]
        id = M.pick_id(kind, rt); ok, _, rc = burst(id, ms, M.cfg().where)
    end
    if ok then last_t = t; return true end
    return rc == -5                                       -- worn on you already: EQ is showing it; nothing on screen
end

-- Preview button only (cards just select): play it once on your target (or on you), not saved
function M.preview(id, where)
    id = math.floor(tonumber(id) or 0)
    if id == 0 then id = M.pick_id('proc', 'Fire') end
    if not D.by_id[id] then return false, 'unknown effect' end
    local ok, why = M.available()
    if not ok then return false, why end
    if M.needs_custom(id) then local cok, cwhy = M.custom_available(); if not cok then return false, cwhy end end
    if D.by_id[id].s0 and not M.s0_available() then return false, 'this EQ record has no on-body stage: its cast stage needs the t469 MQ2RmlUi (feature 262144)' end
    local ms = M.dur_ms(M.PREVIEW_MS, M.PREVIEW_MIN_MS)
    local okb, w = burst(id, ms, (where == 'self' or where == 'target') and where or M.cfg().where, 1)
    if okb then preview_id, preview_until, last_t = id, now() + ms, now(); M._pv_ms = ms end
    return okb, w, ms
end
-- t470: one spell assignment (Spell assignments): play this record on the target or on you. Same gates as M.fire:
-- Proc FX off, particles off (owned, nothing drawn), the shared rate limit; a NEW effect without custom support or a
-- cast-stage record without the t469 DLL falls back to the Auto record. true = owned (played / rate-limited / particles off)
function M.play(id, where, rt)
    if not M.on() then return false end
    if not (M.available()) then return false end
    if not C.particles_on() then return true end
    local t = now()
    if t - last_t < M.GAP_MS then return true end
    id = math.floor(tonumber(id) or 0)
    local r = D.by_id[id]
    if not r or (M.needs_custom(id) and not (M.custom_available())) or (r.s0 and not M.s0_available()) then
        id = M.pick_id('proc', rt)
    end
    if where ~= 'self' then where = 'target' end
    local ms = M.dur_ms(M.MS, M.MIN_MS)
    local ok, _, rc = burst(id, ms, where)
    if not ok and rc == -7 and M.is_custom(id) then
        cavail, cavail_why = false, WHY[-7]
        id = D.auto_stock[M.norm_rt(rt)] or D.auto_stock.Magic
        ok, _, rc = burst(id, ms, where)
    end
    if ok then last_t = t; return true end
    return rc == -5
end
function M.previewing() return preview_id > 0 and now() < preview_until end
-- Use: save the picked record for every proc
function M.use(id)
    id = math.floor(tonumber(id) or 0)
    if not D.by_id[id] then return false, 'unknown effect' end
    local c = M.cfg(); c.id, c.mode = id, 'pick'
    if C.save_cfg then pcall(C.save_cfg) end
    return true
end
function M.set_mode(m)
    local c = M.cfg(); c.mode = (m == 'pick' or m == 'off') and m or 'auto'
    if c.mode == 'pick' and not D.by_id[c.id] then c.mode = 'auto' end
    if C.save_cfg then pcall(C.save_cfg) end
end
function M.set_where(w) M.cfg().where = (w == 'self') and 'self' or 'target'; if C.save_cfg then pcall(C.save_cfg) end end

local function parse(s)
    local t = { raw = s }
    for k, v in s:gmatch('(%a+)=([^%s]+)') do t[k] = v end
    t.verified = tonumber((t.verified or ''):match('^(%-?%d+)') or '') or 0
    t.active, t.played, t.refused = tonumber(t.active) or 0, tonumber(t.played) or 0, tonumber(t.refused) or 0
    t.disabled = t.disabled == '1'
    t.alive, t.attached, t.owner_ok = tonumber(t.alive) or -1, tonumber(t.attached) or -1, tonumber(t.owner_ok) or -1
    t.fell, t.tfail = tonumber(t.fell) or 0, tonumber(t.tfail) or 0
    t.cfx, t.cfxbase = tonumber(t.cfx) or 0, tonumber(t.cfxbase) or -1
    t.last = s:match('last=(.*)$') or ''
    return t
end
function M.poll_status()
    if not M.available() then return status end
    local s
    pcall(function() local p = lib.rml_nimbus_burst_status(); if p ~= nil then s = ffi.string(p) end end)
    if s then status, status_t = parse(s), now() end
    return status
end
local function nm(id) local n = D.by_id[id]; return n and string.format('%s (#%d)', n.name, id) or ('#' .. tostring(id)) end
function M.status_text()
    local ok, why = M.available()
    if not ok then return 'Unavailable: ' .. why .. ' &#183; the screen-drawn look below is used', '' end
    local s = M.poll_status()
    local c = M.cfg()
    local f
    if s.disabled then f = 'Disabled for this session after a fault (see Logs\\rmlui_canvas.log); the screen-drawn look is used'
    elseif s.raw and s.verified ~= 1 then f = 'Client build not verified: native proc effects off'
    elseif c.mode == 'off' then f = 'Off &#183; procs use the screen-drawn look below'
    elseif not C.particles_on() then f = 'Paused: Particle effects are off or the performance tier is Low'
    elseif last_err then f = '<span class="wn">Last try failed: ' .. C.esc(last_err) .. '</span>'
    elseif (s.active or 0) > 0 and s.fell == 1 then
        f = '<span class="wn">Playing ' .. nm(s.active) .. ' on YOU: your target (' .. C.esc(last_where) .. ') could not take it</span>'
    elseif (s.active or 0) > 0 then
        f = 'Playing ' .. nm(s.active) .. ' on ' .. C.esc(last_where) ..
            string.format(' &#183; %d emitters', s.alive or 0)
    elseif (s.tfail or 0) > 0 and c.where == 'target' then
        f = '<span class="wn">The client made no effect on your target last time: procs on targets use the screen look (retried every 10 s); try Show on: You</span>'
    elseif s.last and s.last:match('^refuse') then f = '<span class="wn">Last try refused: ' .. C.esc(s.last) .. '</span>'
    else
        f = (c.mode == 'pick') and ('On: every proc plays ' .. nm(c.id)) or
            ((M.custom_available()) and 'On: Auto, each proc plays the new effect for its element' or 'On: Auto (Stock EQ records: this MQ2RmlUi has no new effects)')
    end
    f = f .. string.format(' &#183; played %d', s.played or 0)
    if c.mode == 'pick' and M.needs_custom(c.id) and not (M.custom_available()) then
        f = f .. ' &#183; <span class="wn">' .. C.esc(nm(c.id)) .. ' needs a newer MQ2RmlUi (custom effects): Auto (Stock EQ) is used</span>'
    end
    local ci = M.custom_info()
    return f, (s.raw or '') .. (ci ~= '' and (' | ' .. ci) or '')
end

-- t468: 'all' / an element = the NEW effects (of that element); 'stock' = the EQ records
-- t469: sub = a D.stock_cats key under 'stock' (nil / 'all' = every record); caster-stage records only with the custom feature
function M.filter(cat, sub)
    if cat == 'stock' then
        local cok = M.s0_available()
        if (sub == nil or sub == 'all') and cok then return D.stock end
        local out = {}
        for _, n in ipairs(D.stock) do
            if (sub == nil or sub == 'all' or n.cat == sub) and (cok or not n.s0) then out[#out + 1] = n end
        end
        return out
    end
    local out = {}
    for _, n in ipairs(D.custom) do
        if cat == 'all' or cat == nil or n.cat == cat then out[#out + 1] = n end
    end
    return out
end

function M.shutdown()
    if lib and avail and has('rml_nimbus_burst_stop') then pcall(function() lib.rml_nimbus_burst_stop() end) end
    preview_id = 0
end

return M
