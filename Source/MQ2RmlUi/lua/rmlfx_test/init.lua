-- rmlfx_test: smoke test for MQ2RmlUi Stage 1 GPU particles (API v5, rml_fx_*).
--   /lua run rmlfx_test            GPU path (auto)
--   /lua run rmlfx_test cpu        force the C++ CPU fallback (same formula)
--   /lua run rmlfx_test noexcl     no body exclusion capsule
--   /lua run rmlfx_test n=20000    particle count of the nimbus (default 10000)
--   /lua stop rmlfx_test           window closes, emitters are freed with the canvas
-- Full-screen click-through overlay, a 10k nimbus-like cylinder emitter anchored on you via
-- rml_spawn_to_overlay, a spark burst every 10 s, body capsule exclusion (CombatFX shape), and fx stats
-- every 5 s to chat and Logs\rmlfx_test.log. Does not touch any other script.
local mq = require('mq')
local ffi = require('ffi')
local rmlui = require('rmlui')

local TAG = '\at[rmlfx_test]\ax '
local WIN, CID = 'RmlFxTest', 'fx'

for _, d in ipairs({
    'int rml_api_version();',
    'int rml_fx_create(const char* win, const char* id, const float* desc, int n);',
    'int rml_fx_update(int h, const float* desc, int n);',
    'int rml_fx_anchor(int h, float x, float y, float px_per_unit, float depth01);',
    'int rml_fx_exclude(const char* win, const char* id, const float* p, int n);',
    'int rml_fx_burst(int h, int count);',
    'int rml_fx_stop(int h, int fade_out);',
    'int rml_fx_destroy(int h);',
    'int rml_fx_stats(int h, char* out, int cap);',
    'int rml_fx_mode(int mode);',
    'int rml_spawn_to_overlay(int spawnId, float heightFrac, float ovW, float ovH, float* sx, float* sy);',
    'int rml_canvas_perf(char* out, int cap);',
}) do pcall(ffi.cdef, d) end

local ok, lib = pcall(ffi.load, 'MQ2RmlUi')
if not ok or not lib then print(TAG .. 'MQ2RmlUi not loaded'); return end
local api = tonumber(lib.rml_api_version()) or 0
local has = pcall(function() return lib.rml_fx_create end)
if api < 5 or not has then print(TAG .. 'needs MQ2RmlUi API 5 (rml_fx_*); this DLL reports ' .. api); return end

local args = { ... }
local opt = { cpu = false, excl = true, n = 10000 }
for _, a in ipairs(args) do
    a = tostring(a):lower()
    if a == 'cpu' then opt.cpu = true
    elseif a == 'noexcl' then opt.excl = false
    elseif a:match('^n=%d+$') then opt.n = math.max(100, math.min(60000, tonumber(a:sub(3)))) end
end
lib.rml_fx_mode(opt.cpu and 1 or 0)

local function screen()
    local okk, sz = pcall(function() return ImGui.GetIO().DisplaySize end)
    if okk and sz and sz.x and sz.x > 0 then return math.floor(sz.x), math.floor(sz.y) end
    return 1920, 1080
end
local SW, SH = screen()

local logpath
pcall(function() logpath = mq.TLO.MacroQuest.Path() .. '\\Logs\\rmlfx_test.log' end)
local function log(s)
    print(TAG .. s)
    if logpath then
        local f = io.open(logpath, 'a')
        if f then f:write(os.date('%H:%M:%S ') .. s .. '\n'); f:close() end
    end
end

local win, err = rmlui.open(WIN, 'rmlfx_test/fx.rml', { width = SW, height = SH, x = 0, y = 0, clickthrough = true, theme = false })
if not win then print(TAG .. 'could not open overlay: ' .. tostring(err)); return end
pcall(function() win:reload() end)
pcall(function() win:place(0, 0, SW, SH) end)

-- descriptor (float[64], FX_API.md)
local function desc(t)
    local d = ffi.new('float[64]')
    d[12] = 1; d[19] = 4; d[20] = 4; d[24] = 1; d[25] = 1; d[26] = 1; d[27] = 1; d[28] = 1; d[29] = 1; d[30] = 1
    d[32] = 1; d[54] = 1; d[58] = 1; d[60] = 0.35; d[62] = 1
    for k, v in pairs(t) do d[k] = v end
    return d
end
local LIFE = 2.0
local nimbus = desc({
    [0] = 2,                -- cylinder
    [1] = 2.4, [2] = 6.2, [3] = 0.15,       -- radius, height, fill
    [9] = opt.n / LIFE, [12] = LIFE, [13] = 0.30,
    [15] = 0.25, [16] = 0.70, [17] = 0.15, [18] = 0.35,
    [19] = 0.22, [20] = 0.06, [23] = 0.35,
    [24] = 1.00, [25] = 0.84, [26] = 0.38, [27] = 0.85,
    [28] = 1.00, [29] = 0.42, [30] = 0.10, [31] = 0.00,
    [33] = 0.40, [34] = 1.20, [35] = 0.15,  -- axial (up)
    [42] = 0.00, [43] = 0.12,               -- radial
    [45] = 50, [46] = 110, [47] = -6,       -- orbital deg/s
    [51] = 90, [52] = 60, [53] = 1,
    [57] = 1,                               -- additive
    [60] = 0.35, [61] = 0.20, [62] = 1.40,
})
local sparks = desc({
    [0] = 0, [9] = 0, [12] = 1.1, [13] = 0.4,
    [16] = 0.5, [19] = 0.14, [20] = 0.03, [23] = 0.4,
    [24] = 0.70, [25] = 0.90, [26] = 1.00, [27] = 1.0, [28] = 0.30, [29] = 0.50, [30] = 1.00, [31] = 0.0,
    [33] = 2.0, [34] = 5.0, [42] = 1.5, [43] = 5.0, [48] = 6.0,
    [57] = 1, [60] = 0.35, [62] = 1.6, [6] = 3.5,
})
local hN = lib.rml_fx_create(WIN, CID, nimbus, 64)
local hS = lib.rml_fx_create(WIN, CID, sparks, 64)
if hN == 0 then print(TAG .. 'rml_fx_create failed (canvas not found?)'); win:close(); return end
log(string.format('start api=%d n=%d cpu=%s excl=%s screen=%dx%d nimbus=%d sparks=%d', api, opt.n, tostring(opt.cpu), tostring(opt.excl), SW, SH, hN, hS))

local sx, sy = ffi.new('float[1]'), ffi.new('float[1]')
local caps = ffi.new('float[13]')
local function proj(id, frac)
    local rc = lib.rml_spawn_to_overlay(id, frac, SW, SH, sx, sy)
    if rc and rc >= 0 then return sx[0], sy[0] end
end

local placed = false
local function frame()
    for _ in win:events() do end                       -- heartbeat (autoclose) + drain
    local id = mq.TLO.Me.ID() or 0
    if id <= 0 then return end
    local h = tonumber(mq.TLO.Me.Height()) or 6
    if h < 2 then h = 6 end
    local f5x, f5y = proj(id, 0.05)
    local hx, hy = proj(id, 1.0)
    if not (f5x and hx) then return end
    local fx_, fy_ = f5x + (f5x - hx) * (0.05 / 0.95), f5y + (f5y - hy) * (0.05 / 0.95)   -- true feet
    local dx, dy = hx - fx_, hy - fy_
    local span = math.sqrt(dx * dx + dy * dy)
    if span < 12 then return end
    local ppu = span / h
    lib.rml_fx_anchor(hN, fx_, fy_, ppu, 0)
    if hS > 0 then lib.rml_fx_anchor(hS, fx_, fy_, ppu, 0) end
    if opt.excl then
        caps[0], caps[1], caps[2], caps[3], caps[4] = fx_, fy_, dx / span, dy / span, span
        lib.rml_fx_exclude(WIN, CID, caps, 5)          -- default CombatFX knots, 6 px feather
    end
    if not placed then placed = true; pcall(function() win:place(0, 0, SW, SH) end) end
end
mq.imgui.init('rmlfx_test', function() local okf, e = pcall(frame); if not okf then print(TAG .. tostring(e)) end end)

local buf = ffi.new('char[768]')
local nextStats, nextBurst = os.time() + 5, os.time() + 3
while true do
    mq.delay(250)
    if not win:is_open() then log('overlay closed, exiting'); break end
    local now = os.time()
    if hS > 0 and now >= nextBurst then
        nextBurst = now + 10
        local got = lib.rml_fx_burst(hS, 1500)
        log('burst sparks +' .. tostring(got))
    end
    if now >= nextStats then
        nextStats = now + 5
        lib.rml_fx_stats(hN, buf, 768); log('nimbus ' .. ffi.string(buf))
        if hS > 0 then lib.rml_fx_stats(hS, buf, 768); log('sparks ' .. ffi.string(buf)) end
        lib.rml_fx_stats(0, buf, 768); log('total  ' .. ffi.string(buf))
        lib.rml_canvas_perf(buf, 768); log('perf   ' .. ffi.string(buf))
    end
end
