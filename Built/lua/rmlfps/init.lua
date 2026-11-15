--[[
  rmlfps v4 - RmlUi FPS / frame-time meter for MQ2RmlUi (v3 glass + CPU/GPU/VRAM stats, CSV recording, visualizer graphs).
  Run: /lua run rmlfps     Stop: the x button, Settings > Stop meter, or /lua stop rmlfps
  Right-click the meter (or click Settings) for every option. No commands needed.

  Cost rules (it is an FPS meter, it must not cost FPS):
   * per frame: integer bookkeeping only (no allocation, no DOM), timed with the performance counter
   * 4 Hz: diffed DOM writes (unchanged values are never re-sent); the graph writes ONE bar per tick from a fixed pool
   * 1 Hz / every 2 s: memory, zone, scripts probes. Hidden pages are not written at all.
   * nothing animates in a loop except the two visualizer canvases (stats page visible only, capped at 30 Hz,
     one vertex buffer + one native submit per canvas). The meter measures and shows its own cost in the header.
   * CPU: GetProcessTimes/GetSystemTimes via ffi, 1 Hz, on the script loop (microseconds).
   * GPU/VRAM: PDH counters need wildcard queries that can take milliseconds, so they run in a separate hidden,
     idle-priority PowerShell (rmlfps/gpu_sampler.ps1) that writes one line per second into a 256-byte shared
     memory block; the script reads it 1x/s (no files). The sampler exits when eqgame exits, when this script
     stops (stop flag / heartbeat stops for 20 s) or is restarted. Nothing in the frame path waits on a process.
]]
local REV = 'v4-t361'
local mq = require('mq')
local rmlui = require('rmlui')

local TAG = '\a-t[rmlfps]\ax '
local running = true
local writes = 0

-- ------------------------------------------------------------------ helpers
local function now() return mq.gettime() end
local function safe(fn) local ok, v = pcall(fn); if ok then return v end; return nil end
local function esc(s) return (tostring(s or ''):gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;')) end
local function clamp(v, a, b) return math.max(a, math.min(b, v)) end
local function screen()      -- ImGui is only asked for the screen size (no ImGui window is drawn)
    local ok, sz = pcall(function() return ImGui.GetIO().DisplaySize end)
    if ok and sz and sz.x and sz.x > 0 then return math.floor(sz.x), math.floor(sz.y) end
    return 1920, 1080
end
-- microsecond timer for the self-cost readout (QueryPerformanceCounter via LuaJIT ffi; os.clock fallback)
local usec
do
    pcall(function()
        local ffi = require('ffi')
        pcall(ffi.cdef, 'int QueryPerformanceCounter(int64_t *c); int QueryPerformanceFrequency(int64_t *f);')
        local b = ffi.new('int64_t[1]')
        if ffi.C.QueryPerformanceFrequency(b) ~= 0 then
            local per = 1e6 / tonumber(b[0])
            local QPC = ffi.C.QueryPerformanceCounter
            usec = function() QPC(b); return tonumber(b[0]) * per end
        end
    end)
    if not usec then usec = function() return os.clock() * 1e6 end end
end

-- ------------------------------------------------------------------ settings: config/rmlfps.ini (same keys as v2; 'tab' is new)
local CFG_PATH = (mq.configDir or '.') .. '/rmlfps.ini'
local KEYS = { 'compact', 'mode', 'thr', 'corner', 'locked', 'x', 'y', 'tab', 'viz', 'gpu', 'rec' }
local cfg = { compact = false, mode = 'full', thr = '60/30', corner = '', locked = false, x = '', y = '', tab = 'stats', viz = true, gpu = true, rec = false }
do
    local f = io.open(CFG_PATH, 'r')
    if f then for l in f:lines() do local k, v = l:gsub('\r$', ''):match('^(%w+)=(.*)$'); if k and cfg[k] ~= nil then
        if type(cfg[k]) == 'boolean' then cfg[k] = (v == 'true' or v == '1') else cfg[k] = v end end end; f:close() end
end
if cfg.mode ~= 'full' and cfg.mode ~= 'clear' and cfg.mode ~= 'hover' then cfg.mode = 'full' end
if cfg.tab ~= 'set' then cfg.tab = 'stats' end
local function save_cfg()
    local f = io.open(CFG_PATH, 'w'); if not f then return end
    for _, k in ipairs(KEYS) do f:write(k, '=', tostring(cfg[k]), '\n') end
    f:close()
end
local THRS = { '30/20', '60/30', '90/45', '120/60', '144/90' }
local GOOD, OKV = 60, 30
local function apply_thr() local g, o = cfg.thr:match('^(%d+)/(%d+)$'); GOOD, OKV = tonumber(g) or 60, tonumber(o) or 30 end
apply_thr()
local function thr_index() for i, v in ipairs(THRS) do if v == cfg.thr then return i end end end
local function grade(f) if f >= GOOD then return 'good' elseif f >= OKV then return 'ok' end; return 'bad' end
local GRADE_WORD = { good = 'Smooth', ok = 'Playable', bad = 'Choppy' }

-- ------------------------------------------------------------------ diffed window proxy
local W = {}; W.__index = W
local function put(self, k, v, fn) if self.cache[k] == v then return end; self.cache[k] = v; writes = writes + 1; pcall(fn) end
function W:text(id, v) v = tostring(v); put(self, 't' .. id, v, function() self.win:text(id, v) end) end
function W:rml(id, v) put(self, 'r' .. id, v, function() self.win:rml(id, v) end) end
function W:style(id, p, v) put(self, 's' .. id .. p, v, function() self.win:style(id, p, v) end) end
function W:class(id, c, on) on = on and true or false; put(self, 'c' .. id .. c, on, function() self.win:class(id, c, on) end) end
function W:grade(id, g) for _, c in ipairs({ 'good', 'ok', 'bad' }) do self:class(id, c, g == c) end end
function W:place(x, y, w, h) writes = writes + 1; pcall(function() self.win:place(x, y, w, h) end) end
local function open(name, doc, w, h)
    local win, err = rmlui.open(name, 'rmlfps/' .. doc, { width = w, height = h, theme = false })
    if not win then print(TAG .. 'open failed: ' .. tostring(err)); return nil end
    pcall(function() win:reload() end)                    -- plugin caches docs across restarts
    return setmetatable({ win = win, cache = {} }, W)
end

-- ------------------------------------------------------------------ positions
-- Native drag always works (drag="1" grips). A patched MQ2RmlUi (feature bit 256) also reports where the window
-- ends up: 'windowmoved' events and rml_get_window(name). With it the free position is saved to x=/y= like v2 wanted.
local wl, wl_tried
local function wlib()
    if wl_tried then return wl end
    wl_tried = true
    pcall(function()
        local ffi = require('ffi')
        pcall(ffi.cdef, 'int rml_features(void);')
        local l = ffi.load('MQ2RmlUi')
        if math.floor((tonumber(l.rml_features()) or 0) / 256) % 2 == 1 then
            pcall(ffi.cdef, 'const char* rml_get_window(const char* name);'); wl = { l = l, ffi = ffi } end
    end)
    return wl
end
local function parse_xy(v) local x, y = tostring(v or ''):match('^%s*(%-?[%d%.]+),(%-?[%d%.]+)'); if x then return math.floor(tonumber(x)), math.floor(tonumber(y)) end end
local function get_pos()
    if _G.__rmlfps_get_rect then return _G.__rmlfps_get_rect() end   -- test seam
    local w = wlib(); if not w then return nil end
    local ok, s = pcall(function() local r = w.l.rml_get_window('RmlFps'); if r ~= nil then return w.ffi.string(r) end end)
    if ok and s then return parse_xy(s) end
end

local M
local EXP_W, EXP_H, CMP_W, CMP_H = 360, 712, 170, 40
local function size() if cfg.compact then return CMP_W, CMP_H end; return EXP_W, EXP_H end
local placed                                               -- where we last put it (to tell our moves from user drags)
local function place_main()
    local w, h = size()
    local sw, sh = screen()
    local c = cfg.corner
    if c ~= '' then
        local x = (c:find('r') and sw - w - 12) or 12
        local y = (c:find('b') and sh - h - 60) or 40
        placed = { x, y }; M:place(x, y, w, h)
    elseif tonumber(cfg.x) and tonumber(cfg.y) then
        local x, y = clamp(tonumber(cfg.x), 0, sw - 40), clamp(tonumber(cfg.y), 0, sh - 20)
        placed = { x, y }; M:place(x, y, w, h)
    else
        placed = nil; M:place(-1, -1, w, h)                -- keep the plugin-remembered position
    end
end
local function on_moved(x, y)
    if not x then return end
    if placed and math.abs(placed[1] - x) <= 2 and math.abs(placed[2] - y) <= 2 then return end   -- our own place()
    placed = { x, y }
    local changed = cfg.corner ~= '' or cfg.x ~= tostring(x) or cfg.y ~= tostring(y)
    cfg.corner, cfg.x, cfg.y = '', tostring(x), tostring(y)                                        -- dragged = free
    if changed then save_cfg() end
    return changed
end

-- ------------------------------------------------------------------ frame bookkeeping (hot path, no allocation)
local RING = 4096                                           -- last N frame times (ms ints) for percentile lows
local ring, ri, rn = {}, 0, 0
local HB = 251                                              -- histogram buckets 0..250 ms (250 = >=250)
local hist = {}
for i = 0, HB - 1 do hist[i] = 0 end
local last_t, tick_frames, tick_max, tick_t0 = 0, 0, 0, 0
local function on_frame_time()
    local t = now()
    if last_t > 0 then
        local dt = t - last_t
        if dt < 0 then dt = 0 end
        local b = dt < 250 and dt or 250
        ri = ri % RING + 1
        local old = ring[ri]
        if old then hist[old] = hist[old] - 1 else rn = rn + 1 end
        ring[ri] = b; hist[b] = hist[b] + 1
        if dt > tick_max then tick_max = dt end
    end
    last_t = t
    tick_frames = tick_frames + 1
end
local function pct_ms(p)
    if rn < 20 then return nil end
    local target, acc = rn * p, 0
    for b = 0, HB - 1 do acc = acc + hist[b]; if acc >= target then return math.max(b, 1) end end
    return 250
end

-- ------------------------------------------------------------------ 4 Hz statistics
local TICK = 250
local tk = { fr = {}, ms = {}, mx = {}, n = 0 }             -- per-tick frames, duration, max dt (ring of 120 = 30 s)
local TK_N = 120
local cur_fps, avg_fps, low1, low01, max5 = 0, 0, nil, nil, 0
local function tk_push(frames, dur, mx) tk.n = tk.n % TK_N + 1; tk.fr[tk.n], tk.ms[tk.n], tk.mx[tk.n] = frames, dur, mx end
local function fps_over(k)
    local f, d, i = 0, 0, tk.n
    for _ = 1, k do local fr = tk.fr[i]; if not fr then break end; f = f + fr; d = d + tk.ms[i]; i = (i - 2) % TK_N + 1 end
    if d <= 0 then return 0 end
    return f * 1000 / d
end
local function max_over(k)
    local m, i = 0, tk.n
    for _ = 1, k do local v = tk.mx[i]; if not v then break end; if v > m then m = v end; i = (i - 2) % TK_N + 1 end
    return m
end
local function minmax_fps()            -- lowest / highest quarter-second over 30 s
    local lo, hi = nil, nil
    for i = 1, TK_N do local fr, d = tk.fr[i], tk.ms[i]
        if fr and d and d > 0 then local v = fr * 1000 / d; if not lo or v < lo then lo = v end; if not hi or v > hi then hi = v end end end
    return lo, hi
end

-- ------------------------------------------------------------------ slow probes (same as v2)
local mem = { kb = 0, ring = {}, n = 0, trend = 0 }
local function probe_mem()
    local kb = collectgarbage('count')
    mem.kb = kb; mem.n = mem.n % 10 + 1; mem.ring[mem.n] = kb
    local oldest = mem.ring[mem.n % 10 + 1] or mem.ring[1]
    local cnt = 0; for _ in pairs(mem.ring) do cnt = cnt + 1 end
    mem.trend = cnt > 1 and (kb - oldest) / (cnt - 1) or 0   -- KB per second
end
local env = { zone = nil, spawns = nil, ping = nil, docs = nil, scripts = {} }
local PING_PROBES = {
    function() return mq.TLO.EverQuest.Ping() end,
    function() return mq.TLO.EverQuest.Latency() end,
    function() return mq.TLO.Me.Ping() end,
}
local ping_fn
local function probe_env()
    env.zone = safe(function() return mq.TLO.Zone.ShortName() end)
    env.spawns = tonumber(safe(function() return mq.TLO.SpawnCount() end))
    if ping_fn == nil then
        ping_fn = false
        for _, f in ipairs(PING_PROBES) do local v = tonumber(safe(f)); if v then ping_fn = f; break end end
    end
    env.ping = ping_fn and tonumber(safe(ping_fn)) or nil
    env.docs = nil
    for _, n in ipairs({ 'stats', 'doc_count', 'documents', 'count' }) do
        local f = rmlui[n]
        if type(f) == 'function' then
            local ok, v = pcall(f)
            if ok and type(v) == 'number' then env.docs = { n = v }; break end
            if ok and type(v) == 'table' then
                local d = v.documents or v.docs or v.count or (#v > 0 and #v) or nil
                if d then env.docs = { n = d, cap = v.max or v.cap or v.limit }; break end
            end
        end
    end
    local list = {}
    local pids = safe(function() return mq.TLO.Lua.PIDs() end)
    if type(pids) == 'string' and pids ~= '' then
        for pid in pids:gmatch('%d+') do
            local p = tonumber(pid)
            local s = mq.TLO.Lua.Script(p)
            local name = safe(function() return s.Name() end)
            if name then list[#list + 1] = { pid = p, name = name, status = safe(function() return s.Status() end) or '?' } end
        end
        table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    end
    env.scripts = list
end


-- ------------------------------------------------------------------ hardware: CPU (in-process ffi) + GPU/VRAM (background sampler)
local hw = { cpu_p = nil, cpu_s = nil, gp = nil, gt = nil, vp = nil, vu = nil, vt = nil }
local K32
pcall(function()
    local ffi = require('ffi')
    pcall(ffi.cdef, 'typedef struct { uint32_t lo, hi; } rmlfps_ft;')
    pcall(ffi.cdef, 'int GetSystemTimes(rmlfps_ft* idle, rmlfps_ft* kernel, rmlfps_ft* user);')
    pcall(ffi.cdef, 'void* GetCurrentProcess(void);')
    pcall(ffi.cdef, 'int GetProcessTimes(void* h, rmlfps_ft* c, rmlfps_ft* e, rmlfps_ft* k, rmlfps_ft* u);')
    pcall(ffi.cdef, 'uint32_t GetCurrentProcessId(void);')
    local C = _G.__rmlfps_k32 or ffi.C                      -- test seam
    K32 = { ffi = ffi, C = C, ft = ffi.new('rmlfps_ft[7]'), hp = C.GetCurrentProcess(), pid = tonumber(C.GetCurrentProcessId()) }
end)
local cpu_prev
local function u64(f) return f.hi * 4294967296 + f.lo end
local function probe_cpu()
    if not K32 then return end
    local C, ft = K32.C, K32.ft
    if C.GetSystemTimes(ft + 0, ft + 1, ft + 2) == 0 then return end
    if C.GetProcessTimes(K32.hp, ft + 3, ft + 4, ft + 5, ft + 6) == 0 then return end
    local cur = { idle = u64(ft[0]), sys = u64(ft[1]) + u64(ft[2]), proc = u64(ft[5]) + u64(ft[6]) }   -- 100 ns units
    local p = cpu_prev
    if p then
        -- system kernel+user (idle included) = wall time x every logical core, so both are shares of the WHOLE CPU
        local dsys = cur.sys - p.sys
        if dsys > 0 then
            hw.cpu_s = clamp(100 * (1 - (cur.idle - p.idle) / dsys), 0, 100)
            hw.cpu_p = clamp(100 * (cur.proc - p.proc) / dsys, 0, 100)
        end
    end
    cpu_prev = cur
end

local LUADIR = tostring(mq.luaDir or '.'):gsub('/', '\\'):gsub('\\+$', '')
local SAMPLER = LUADIR .. '\\rmlfps\\gpu_sampler.ps1'
local gpu = { state = 'off', pi = nil, n = nil, seen = 0, started = 0, restarts = 0, next_try = 0 }
local function gpu_cdefs()
    if gpu.cdef then return gpu.cdef == 1 end
    gpu.cdef = 0
    local ffi = K32 and K32.ffi; if not ffi then return false end
    pcall(ffi.cdef, [[typedef struct { uint32_t cb; void* r1; void* desk; void* title; uint32_t x, y, xs, ys, xc, yc, fill, flags;
        uint16_t show, cbr2; void* r2; void* hin; void* hout; void* herr; } rmlfps_si;]])
    pcall(ffi.cdef, 'typedef struct { void* hp; void* ht; uint32_t pid, tid; } rmlfps_pi;')
    pcall(ffi.cdef, 'int CreateProcessA(const char* app, char* cmd, void* pa, void* ta, int inherit, uint32_t flags, void* env, const char* cwd, rmlfps_si* si, rmlfps_pi* pi);')
    pcall(ffi.cdef, 'int TerminateProcess(void* h, uint32_t code);')
    pcall(ffi.cdef, 'int CloseHandle(void* h);')
    pcall(ffi.cdef, 'uint32_t WaitForSingleObject(void* h, uint32_t ms);')
    pcall(ffi.cdef, 'void* CreateFileMappingA(void* f, void* sa, uint32_t prot, uint32_t hi, uint32_t lo, const char* name);')
    pcall(ffi.cdef, 'void* MapViewOfFile(void* h, uint32_t access, uint32_t hi, uint32_t lo, size_t n);')
    pcall(ffi.cdef, 'int UnmapViewOfFile(const void* p);')
    local ok = pcall(function() return K32.C.CreateProcessA and K32.C.TerminateProcess and K32.C.WaitForSingleObject and K32.C.CreateFileMappingA and K32.C.MapViewOfFile and K32.C.UnmapViewOfFile end)
    gpu.cdef = ok and 1 or 0
    return ok
end
-- Transport = a 256-byte shared-memory block (no files: v4-t360's per-second %TEMP% file I/O showed up as ms of
-- 'scan' on the game thread). Layout, uint32 words: [0] heartbeat (rmlfps bumps it each second),
-- [1] stop flag, [2] seq (odd while the sampler writes), [3] line length, bytes 16.. = the sample line.
local function gpu_map()
    local ffi, C = K32.ffi, K32.C
    local name = string.format('Local\\rmlfps_%d_%s', K32.pid, gpu.token)
    local h = C.CreateFileMappingA(ffi.cast('void*', ffi.cast('intptr_t', -1)), nil, 4, 0, 256, name)   -- PAGE_READWRITE, pagefile-backed
    if h == nil then return nil end
    local p = C.MapViewOfFile(h, 6, 0, 0, 256)                -- FILE_MAP_READ | FILE_MAP_WRITE
    if p == nil then C.CloseHandle(h); return nil end
    ffi.fill(p, 256)
    gpu.mh, gpu.mp, gpu.mu, gpu.mb = h, p, ffi.cast('volatile uint32_t*', p), ffi.cast('const uint8_t*', p)
    return name
end
local function gpu_unmap()
    if gpu.mu then gpu.mu[1] = 1 end                         -- stop flag: the sampler exits on its next tick
    if gpu.mp then pcall(function() K32.C.UnmapViewOfFile(gpu.mp); K32.C.CloseHandle(gpu.mh) end) end
    gpu.mh, gpu.mp, gpu.mu, gpu.mb = nil, nil, nil, nil
end
local function gpu_stop()
    gpu_unmap()
    if gpu.pi then
        pcall(function() K32.C.TerminateProcess(gpu.pi.hp, 0); K32.C.CloseHandle(gpu.pi.hp) end)
        gpu.pi = nil
    end
    hw.gp, hw.gt, hw.vp, hw.vu = nil, nil, nil, nil
    gpu.state = 'off'
end
local function gpu_start()
    if gpu.pi or not cfg.gpu then return end
    if not (K32 and gpu_cdefs()) then gpu.state = 'unavailable'; return end
    local chk = io.open(SAMPLER, 'r'); if not chk then gpu.state = 'sampler missing'; return end; chk:close()
    local ffi, C, pid = K32.ffi, K32.C, K32.pid
    gpu_unmap()
    gpu.token = string.format('%d%06d', os.time(), math.floor(usec() % 1000000))
    local name = gpu_map(); if not name then gpu.state = 'unavailable'; return end
    local ps = (os.getenv('SystemRoot') or 'C:\\Windows') .. '\\System32\\WindowsPowerShell\\v1.0\\powershell.exe'
    local cmd = string.format('"%s" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "%s" -ParentPid %d -Map "%s"',
        ps, SAMPLER, pid, name)
    local si = ffi.new('rmlfps_si'); si.cb = ffi.sizeof('rmlfps_si')
    local pi = ffi.new('rmlfps_pi')
    local buf = ffi.new('char[?]', #cmd + 1); ffi.copy(buf, cmd)
    -- CREATE_NO_WINDOW | IDLE_PRIORITY_CLASS: no console flash, never competes with the game for a core
    if C.CreateProcessA(nil, buf, nil, nil, 0, 0x08000040, nil, nil, si, pi) == 0 then gpu_unmap(); gpu.state = 'start failed'; return end
    C.CloseHandle(pi.ht)
    gpu.pi, gpu.state, gpu.started, gpu.n = pi, 'starting', now(), nil
end
local function gpu_read()
    if not gpu.pi then
        if cfg.gpu and gpu.restarts < 3 and now() >= gpu.next_try and gpu.state ~= 'sampler missing' and gpu.state ~= 'unavailable' then
            gpu.restarts = gpu.restarts + 1; gpu.next_try = now() + 10000; gpu_start()
        end
        return
    end
    if K32.C.WaitForSingleObject(gpu.pi.hp, 0) == 0 then        -- sampler exited: drop it, retry later (max 3)
        pcall(function() K32.C.CloseHandle(gpu.pi.hp) end); gpu.pi = nil; gpu.state = 'stopped'; gpu_unmap()
        hw.gp, hw.gt, hw.vp, hw.vu = nil, nil, nil, nil
        return
    end
    local u = gpu.mu; if not u then return end
    u[0] = (u[0] + 1) % 4294967296                           -- heartbeat
    local s1, len = u[2], u[3]
    local line
    if s1 % 2 == 0 and len > 0 and len < 240 then
        line = K32.ffi.string(gpu.mb + 16, len)
        if u[2] ~= s1 then line = nil end                    -- torn read: skip this second
    end
    local n, gp, gt, vp, vu, vt
    if line then n, gp, gt, vp, vu, vt = line:match('^rmlfps1 n=(%d+) gp=([%d%.]+) gt=([%d%.]+) vp=([%d%.]+) vu=([%d%.]+) vt=([%d%.]+) end') end
    if n and tonumber(n) ~= gpu.n then
        gpu.n, gpu.seen, gpu.state, gpu.restarts = tonumber(n), now(), 'live', 0   -- a working sampler earns its retries back
        hw.gp, hw.gt, hw.vp, hw.vu, hw.vt = tonumber(gp), tonumber(gt), tonumber(vp), tonumber(vu), tonumber(vt)
        if hw.vt and hw.vt <= 0 then hw.vt = nil end
    elseif now() - math.max(gpu.seen, gpu.started) > 6000 then
        gpu.state = gpu.n and 'stale' or 'starting'; hw.gp, hw.gt, hw.vp, hw.vu = nil, nil, nil, nil
    end
end

-- 1 Hz history: 60 s of cpu/gpu for averages, baseline and the CPU/GPU visualizer
local HWN = 60
local hwr = { cp = {}, cs = {}, gp = {}, gt = {}, n = 0 }
local function hw_push()
    hwr.n = hwr.n % HWN + 1
    hwr.cp[hwr.n], hwr.cs[hwr.n], hwr.gp[hwr.n], hwr.gt[hwr.n] = hw.cpu_p or false, hw.cpu_s or false, hw.gp or false, hw.gt or false
end
local function hw_avg(key, k)
    local r, i, sum, c = hwr[key], hwr.n, 0, 0
    if i == 0 then return nil end
    for _ = 1, k do local v = r[i]; if v == nil then break end; if v then sum = sum + v; c = c + 1 end; i = (i - 2) % HWN + 1 end
    return c > 0 and sum / c or nil
end

-- CSV recording to <MQ>\Logs, one row per second
local LOGDIR = LUADIR:gsub('\\[Ll][Uu][Aa]$', '') .. '\\Logs'
local rec = { f = nil, name = nil, rows = 0, t0 = 0, err = nil }
local function rec_close() if rec.f then pcall(function() rec.f:close() end) end; rec.f = nil end
local function rec_open()
    rec_close()
    local name = os.date('rmlfps_%Y%m%d_%H%M%S.csv')
    local f, e = io.open(LOGDIR .. '\\' .. name, 'w')
    if not f then rec.err = tostring(e); return false end
    f:write('timestamp,fps,frame_ms,low1_fps,worst_ms_5s,cpu_eqgame_pct,cpu_total_pct,gpu_eqgame_pct,gpu_total_pct,vram_eqgame_mb,vram_used_mb,vram_total_mb,zone\n')
    rec.f, rec.name, rec.rows, rec.t0, rec.err = f, name, 0, now(), nil
    return true
end
local function n1(v) return v and string.format('%.1f', v) or '' end
local function n0(v) return v and string.format('%d', math.floor(v + 0.5)) or '' end

-- ------------------------------------------------------------------ "what's costing me" (same as v2)
local cost = { base = nil, pending = nil, last = nil, prev_set = nil }
local function script_set() local t = {}; for _, s in ipairs(env.scripts) do if s.status == 'RUNNING' then t[s.name] = true end end; return t end
local function detect_change()
    local set = script_set()
    if cost.prev_set then
        local started, stopped = {}, {}
        for n in pairs(set) do if not cost.prev_set[n] and n ~= 'rmlfps' then started[#started + 1] = n end end
        for n in pairs(cost.prev_set) do if not set[n] and n ~= 'rmlfps' then stopped[#stopped + 1] = n end end
        if #started + #stopped > 0 then
            table.sort(started); table.sort(stopped)
            local what = (#started > 0 and ('started ' .. table.concat(started, ', ')) or '') .. ((#started > 0 and #stopped > 0) and '; ' or '') .. (#stopped > 0 and ('stopped ' .. table.concat(stopped, ', ')) or '')
            cost.pending = { what = what, before = fps_over(20), at = now() + 7000 }
        end
    end
    cost.prev_set = set
end
local function check_pending()
    local p = cost.pending
    if p and now() >= p.at then
        local after = fps_over(20)
        local d = after - p.before
        local dms = (after > 0 and p.before > 0) and (1000 / after - 1000 / p.before) or 0
        cost.last = string.format('After %s: %+.1f fps (%+.2f ms per frame)', p.what, d, dms)
        cost.last_g = d < -1 and 'bad' or (d > 1 and 'good' or nil)
        cost.pending = nil
    end
end

local VZ = { ok = false, last = 0, ms = 0 }                 -- visualizer state (filled by viz_init below)
-- ------------------------------------------------------------------ self cost
local me = { us = 0, frames = 0, peak = 0, t0 = 0, probe_us = 0, w0 = 0, line1 = 'meter cost --', line2 = '' }
local function self_cost_tick(t)
    if me.t0 == 0 then me.t0, me.w0 = t, writes; return end
    local dur = t - me.t0
    if dur < 1000 then return end
    local per = me.frames > 0 and me.us / me.frames or 0
    local frame_ms = cur_fps > 0 and 1000 / cur_fps or 0
    me.line1 = string.format('meter cost <b>%.3f ms</b>%s', per / 1000, frame_ms > 0 and string.format(' (%.2f%%)', per / 10 / frame_ms) or '')
    local vms = 0
    if VZ.ok and cfg.viz then pcall(function() vms = (tonumber(VZ.l.rml_canvas_draw_ms('RmlFps', 'vfps')) or 0) + (tonumber(VZ.l.rml_canvas_draw_ms('RmlFps', 'vhw')) or 0) end) end
    VZ.ms = vms
    me.line2 = string.format('%d upd/s &#183; scan %.2f+%.2f', math.floor((writes - me.w0) * 1000 / dur + 0.5), me.probe_us / 1000, (me.hw_us or 0) / 1000)
        .. (VZ.ok and cfg.viz and string.format(' &#183; viz %.2f ms', vms) or ' ms')
    me.us, me.frames, me.t0, me.w0 = 0, 0, t, writes
end

-- ------------------------------------------------------------------ rendering
local NB, GH, SC = 80, 64, 6
local gval, gpos, gsynced = {}, 0, false                    -- graph history (fps per tick) + write cursor
local GMAX = 90
local tab = cfg.tab
local function f0(v) return v and string.format('%d', math.floor(v + 0.5)) or '--' end
-- ------------------------------------------------------------------ visualizer graphs (MQ2RmlUi <canvas>, API 4)
-- Real history only: FPS = one bar per 0.5 s (fps over that half second), CPU/GPU = one bar per second.
-- Motion is interpolation between real samples: the strip scrolls one bar per sample and the newest bar eases
-- up from its neighbour. Peak caps are a peak-hold envelope over the real values that falls 2.5 px per sample.
local VCAP = 6 * 4 * 420                                    -- float capacity of the vertex buffer (420 quads)
local VW, VH = 320, 66                                      -- canvas content size (graph box minus its 1px border)
local FN, FP, FBW = 40, 8, 6                                -- bars, pitch, bar width
local FBASE, FGH = 54, 51                                   -- fps: baseline y and max bar height (reflection below)
local HMID, HGH = 33, 30                                    -- cpu up / gpu down from the middle line
local vf = { v = {}, cap = {}, tp = 0, prevh = 0, k = 0 }   -- fps strip (oldest first)
local vh = { cp = {}, cs = {}, gp = {}, gt = {}, ccap = {}, gcap = {}, tp = 0, pc = 0, pg = 0, sc = 50, sg = 50 }
local function viz_init()
    pcall(function()
        local ffi = require('ffi')
        pcall(ffi.cdef, 'int rml_api_version(void);')
        pcall(ffi.cdef, 'int rml_canvas_clear(const char* win, const char* id);')
        pcall(ffi.cdef, 'int rml_canvas_submit(const char* win, const char* id, const float* verts, int count, int mode);')
        pcall(ffi.cdef, 'int rml_canvas_bloom(const char* win, const char* id, float strength);')
        pcall(ffi.cdef, 'float rml_canvas_draw_ms(const char* win, const char* id);')
        local l = ffi.load('MQ2RmlUi')
        if (tonumber(l.rml_api_version()) or 0) >= 4 and l.rml_canvas_submit and l.rml_canvas_draw_ms then
            VZ.l, VZ.ffi, VZ.buf, VZ.abuf, VZ.ok = l, ffi, ffi.new('float[?]', VCAP), ffi.new('float[?]', VCAP), true
        end
    end)
    if _G.__rmlfps_viz_lib then VZ.l, VZ.ffi, VZ.ok = _G.__rmlfps_viz_lib, require('ffi'), true; VZ.buf = VZ.ffi.new('float[?]', VCAP); VZ.abuf = VZ.ffi.new('float[?]', VCAP) end  -- test seam
end
-- How the canvas really draws (MQ2RmlUi ElementCanvas.cpp / CanvasRenderer.cpp / shaders/canvas.hlsl):
--   vertex colours are clamped to 0..1, premultiplied and packed to 8 bits; batches blend ONE/INV_SRC_ALPHA
--   (or ONE/ONE with 0x0100) into a float scene; bloom (if > 0.01) blurs the WHOLE scene (no threshold, 3 levels,
--   x1.4 boost per level) and adds it back; the composite then applies an ACES tonemap. Dense bars + bloom = a
--   white-mint wash, and ACES caps a plain 0..1 colour at ~0.80. So: bloom off, every colour below is a display
--   colour run through the inverse ACES curve, and the few HDR bits (caps, top rows) get an additive second pass.
local function inv_aces(y)
    y = clamp(y, 0, 0.91)
    local A, B = 2.51 - 2.43 * y, 0.03 - 0.59 * y
    return (-B + math.sqrt(B * B + 4 * A * 0.14 * y)) / (2 * A)
end
-- display colour c = {r,g,b} at alpha a -> vertex colour for the normal pass (+ the extra for the additive pass)
local function dc(c, a)
    local x1, x2, x3 = inv_aces(c[1] * a) / a, inv_aces(c[2] * a) / a, inv_aces(c[3] * a) / a
    local e = { clamp(x1 - 1, 0, 1), clamp(x2 - 1, 0, 1), clamp(x3 - 1, 0, 1), a }
    return { math.min(x1, 1), math.min(x2, 1), math.min(x3, 1), a }, (e[1] + e[2] + e[3] > 0.004) and e or nil
end
local function mixw(c, k) return { c[1] + (1 - c[1]) * k, c[2] + (1 - c[2]) * k, c[3] + (1 - c[3]) * k } end
local function sc3(c, k) return { c[1] * k, c[2] * k, c[3] * k } end
local function lim(c, m) local hi = math.max(c[1], c[2], c[3]); return hi > m and sc3(c, m / hi) or c end
local TILE = { { 1.00, 0.416, 0.353 }, { 1.00, 0.765, 0.353 }, { 0.435, 0.89, 0.604 } }   -- red, amber, green = the tiles' #ff6a5a #ffc35a #6fe39a
local PAL = {}
for i, c in ipairs(TILE) do
    local p = {}
    p.top = dc(lim(sc3(c, 0.86), 0.79), 1)                   -- <= 0.79 needs no HDR pass
    p.bot = dc(sc3(c, 0.16), 1)
    p.hi, p.hix = dc(lim(c, 0.88), 1)
    p.cap, p.capx = dc(lim(mixw(c, 0.45), 0.91), 1)
    p.glow = dc(sc3(c, 0.55), 0.30)                          -- soft halo (additive, low alpha)
    p.rt = dc(sc3(c, 0.55), 0.30)                            -- reflection top
    PAL[i] = p
end
local GHOST_T, GHOST_B = dc({ 0.60, 0.64, 0.78 }, 0.26), dc({ 0.60, 0.64, 0.78 }, 0.10)
local LINE = dc({ 0.90, 0.75, 0.50 }, 0.35)
local Z4 = { 0, 0, 0, 0 }

local vb, vn, ab, an = nil, 0, nil, 0                       -- normal pass / additive pass buffers
local function put(b, i, x0, y0, x1, y1, t, u)               -- one axis-aligned quad, colour t at the top, u at the bottom
    if i + 24 > VCAP then return i end                       -- never write past the ffi buffer
    b[i] = x0; b[i + 1] = y0; b[i + 2] = t[1]; b[i + 3] = t[2]; b[i + 4] = t[3]; b[i + 5] = t[4]
    b[i + 6] = x1; b[i + 7] = y0; b[i + 8] = t[1]; b[i + 9] = t[2]; b[i + 10] = t[3]; b[i + 11] = t[4]
    b[i + 12] = x1; b[i + 13] = y1; b[i + 14] = u[1]; b[i + 15] = u[2]; b[i + 16] = u[3]; b[i + 17] = u[4]
    b[i + 18] = x0; b[i + 19] = y1; b[i + 20] = u[1]; b[i + 21] = u[2]; b[i + 22] = u[3]; b[i + 23] = u[4]
    return i + 24
end
local function quad(x0, y0, x1, y1, t, u) vn = put(vb, vn, x0, y0, x1, y1, t, u or t) end
local function qadd(x0, y0, x1, y1, t, u) an = put(ab, an, x0, y0, x1, y1, t, u or t) end
local function fps_cls(v) if v >= GOOD then return 3 elseif v >= OKV then return 2 end; return 1 end
local function load_cls(p) if p < 60 then return 3 elseif p < 85 then return 2 end; return 1 end
-- a rounded bar: 1px inset bright top row, body gradient (bright end -> dark foot)
local function vbar(x, top, bot, p, up_)
    if bot - top < 1 then return end
    if up_ then
        quad(x + 1, top, x + FBW - 1, top + 1, p.hi); if p.hix then qadd(x + 1, top, x + FBW - 1, top + 1, p.hix) end
        if bot - top >= 2 then quad(x, top + 1, x + FBW, bot, p.top, p.bot) end
    else
        if bot - top >= 2 then quad(x, top, x + FBW, bot - 1, p.bot, p.top) end
        quad(x + 1, bot - 1, x + FBW - 1, bot, p.hi); if p.hix then qadd(x + 1, bot - 1, x + FBW - 1, bot, p.hix) end
    end
end
-- peak cap: solid bright 2px bar + a small soft halo (additive) instead of the scene-wide bloom
local function vcap(x, y, p)
    quad(x, y, x + FBW, y + 2, p.cap); if p.capx then qadd(x, y, x + FBW, y + 2, p.capx) end
    qadd(x - 1, y - 3, x + FBW + 1, y, Z4, p.glow); qadd(x - 1, y + 2, x + FBW + 1, y + 4, p.glow, Z4)
end
local function viz_submit(id)
    local l = VZ.l
    l.rml_canvas_clear('RmlFps', id)
    l.rml_canvas_bloom('RmlFps', id, 0)                      -- clear() resets bloom to 1.45; 0 = no bloom pass at all
    if vn >= 24 then l.rml_canvas_submit('RmlFps', id, vb, vn / 6, 1) end           -- 1 = QUADS
    if an >= 24 then l.rml_canvas_submit('RmlFps', id, ab, an / 6, 0x0101) end      -- QUADS | ADDITIVE
end
local function slide(t, tp, period)                         -- 0..1 progress of the newest sample sliding in (ease-out)
    local s = clamp((t - tp) / period, 0, 1); local u = 1 - s; return 1 - u * u * u
end
-- data: called by tick() / the 1 Hz loop with REAL values
local function vf_push(v, t)
    local n = #vf.v
    vf.prevh = n > 0 and clamp(vf.v[n] / GMAX * FGH, 1, FGH) or 0
    local fall = 2.5 / FGH * GMAX
    local c = n > 0 and math.max(v, vf.cap[n] - fall) or v
    vf.v[n + 1], vf.cap[n + 1] = v, c
    if n + 1 > FN + 1 then table.remove(vf.v, 1); table.remove(vf.cap, 1) end
    vf.tp = t
    -- visualizer auto-range: never clip a real 100+ fps history into a flat wall; threshold lines follow
    local hi = 0; for i = 1, #vf.v do if vf.v[i] > hi then hi = vf.v[i] end end
    local want = math.max(GOOD * 1.5, 30, math.ceil(hi * 1.12 / 20) * 20)
    if VZ.ok and cfg.viz and want ~= GMAX then vf.rescale = want end
end
local function vh_push(t)
    local n = #vh.cp
    local cp, cs, gp, gt = hw.cpu_p or 0, hw.cpu_s or 0, hw.gp or 0, hw.gt or 0
    vh.pc = n > 0 and vh.cp[n] or 0; vh.pg = n > 0 and vh.gp[n] or 0
    vh.cp[n + 1], vh.cs[n + 1], vh.gp[n + 1], vh.gt[n + 1] = cp, cs, gp, gt
    local fall = 2.5 / HGH
    vh.ccap[n + 1] = n > 0 and math.max(cp, vh.ccap[n] - fall * vh.sc) or cp
    vh.gcap[n + 1] = n > 0 and math.max(gp, vh.gcap[n] - fall * vh.sg) or gp
    if n + 1 > FN + 1 then for _, k in ipairs({ 'cp', 'cs', 'gp', 'gt', 'ccap', 'gcap' }) do table.remove(vh[k], 1) end end
    local mc, mg = 0, 0
    for i = 1, #vh.cp do mc = math.max(mc, vh.cp[i], vh.cs[i]); mg = math.max(mg, vh.gp[i], vh.gt[i]) end
    vh.sc = mc <= 50 and 50 or 100                          -- 0-50% unless something in the window went past 50; labelled in the header
    vh.sg = mg <= 50 and 50 or 100
    vh.tp = t
    vh.has_gpu = hw.gp ~= nil
end
local function viz_fps(t)
    vb, vn, ab, an = VZ.buf, 0, VZ.abuf, 0
    local es = slide(t, vf.tp, 500)
    local n = #vf.v
    quad(0, FBASE, VW, FBASE + 1, LINE)                       -- floor line
    for k = 1, n do
        local x = VW - (n - k + 1) * FP + (1 - es) * FP + 1
        if x > -FP and x < VW then
            local v = vf.v[k]
            local h = clamp(v / GMAX * FGH, 1, FGH)
            if k == n then h = vf.prevh + (h - vf.prevh) * es end
            local p = PAL[fps_cls(v)]
            vbar(x, FBASE - h, FBASE, p, true)
            local rh = math.min(h * 0.30, VH - FBASE - 2)                              -- reflection
            if rh >= 1 then quad(x, FBASE + 2, x + FBW, FBASE + 2 + rh, p.rt, Z4) end
            local ch = clamp(vf.cap[k] / GMAX * FGH, 1, FGH)
            if ch < h then ch = h end
            vcap(x, FBASE - ch - 3, p)
        end
    end
    viz_submit('vfps')
end
local function viz_hw(t)
    vb, vn, ab, an = VZ.buf, 0, VZ.abuf, 0
    local es = slide(t, vh.tp, 1000)
    local n = #vh.cp
    quad(0, HMID, VW, HMID + 1, LINE)                         -- centre line
    for k = 1, n do
        local x = VW - (n - k + 1) * FP + (1 - es) * FP + 1
        if x > -FP and x < VW then
            local cp, gp = vh.cp[k], vh.gp[k]
            if k == n then cp = vh.pc + (cp - vh.pc) * es; gp = vh.pg + (gp - vh.pg) * es end
            -- ghost = whole system (all processes / busiest adapter), solid = eqgame
            local hs = clamp(vh.cs[k] / vh.sc * HGH, 0, HGH)
            if hs >= 1 then quad(x, HMID - hs, x + FBW, HMID, GHOST_T, GHOST_B) end
            local hc = clamp(cp / vh.sc * HGH, 0, HGH)
            local p = PAL[load_cls(vh.cp[k])]
            vbar(x, HMID - hc, HMID, p, true)
            local cc = math.max(clamp(vh.ccap[k] / vh.sc * HGH, 0, HGH), hc)
            if cc >= 1 then vcap(x, HMID - cc - 3, p) end
            if vh.has_gpu then
                local hg = clamp(vh.gt[k] / vh.sg * HGH, 0, HGH)
                if hg >= 1 then quad(x, HMID + 1, x + FBW, HMID + 1 + hg, GHOST_B, GHOST_T) end
                local hp = clamp(gp / vh.sg * HGH, 0, HGH)
                local p2 = PAL[load_cls(vh.gp[k])]
                vbar(x, HMID + 1, HMID + 1 + hp, p2, false)
                local gc = math.max(clamp(vh.gcap[k] / vh.sg * HGH, 0, HGH), hp)
                if gc >= 1 then vcap(x, HMID + 2 + gc, p2) end
            end
        end
    end
    viz_submit('vhw')
end
local function viz_frame(t)
    if t - VZ.last < 33 then return end                     -- 30 Hz is plenty for interpolation
    VZ.last = t
    viz_fps(t); viz_hw(t)
end

local function bar(i)
    local v = gval[i]
    local h = v and clamp(math.floor(v / GMAX * GH + 0.5), 1, GH) or 1
    M:style('b' .. i, 'height', h .. 'px')
    M:grade('b' .. i, v and grade(v))
end
local function graph_scale(gmax)
    GMAX = gmax or math.max(GOOD * 1.5, 30)
    local g, o = math.floor(GOOD / GMAX * GH), math.floor(OKV / GMAX * GH)
    if VZ.ok and cfg.viz then local base = VH - FBASE; g, o = base + math.floor(GOOD / GMAX * FGH), base + math.floor(OKV / GMAX * FGH) end
    M:style('gl_good', 'bottom', g .. 'px'); M:style('gl_ok', 'bottom', o .. 'px')
    M:style('glab_good', 'bottom', (g + 1) .. 'px'); M:style('glab_ok', 'bottom', (o + 1) .. 'px')
    M:text('glab_good', GOOD); M:text('glab_ok', OKV)
    gsynced = false
end

local function stats_visible() return not cfg.compact and tab == 'stats' end
local function viz_on() return VZ.ok and cfg.viz end

local function render_fast()
    local g = cur_fps > 0 and grade(cur_fps) or nil
    if cfg.compact then
        M:text('cfps', f0(cur_fps)); M:grade('cfps', g)
        M:text('cms', cur_fps > 0 and string.format('%.1f ms', 1000 / cur_fps) or '-- ms')
        M:text('cl1', low1 and ('1% low ' .. f0(low1)) or '')
        return
    end
    if tab ~= 'stats' then return end
    M:text('fps', f0(cur_fps)); M:grade('fps', g); M:grade('hero', g); M:grade('grade', g)
    M:text('grade', g and GRADE_WORD[g] or 'measuring')
    M:text('ms', cur_fps > 0 and string.format('%.1f ms per frame', 1000 / cur_fps) or '-- ms per frame')
    M:text('l1', f0(low1)); M:grade('l1', low1 and grade(low1))
    M:text('l01', f0(low01)); M:grade('l01', low01 and grade(low01))
    M:text('avg', f0(avg_fps)); M:grade('avg', avg_fps > 0 and grade(avg_fps))
    M:text('avgd', avg_fps > 0 and string.format('%.1f ms, 30 s', 1000 / avg_fps) or 'last 30 s')
    M:text('wst', max5 > 0 and (max5 .. ' ms') or '--')
    M:grade('wst', max5 > 0 and (max5 > 1000 / OKV and 'bad' or (max5 > 2000 / GOOD and 'ok' or 'good')))
    -- graph: one new bar per tick (or a one-off full resync after being hidden / rescaled)
    if viz_on() then gsynced = false; return end           -- the canvas draws the graph; DOM bars stay untouched
    if not gsynced then for i = 1, NB do bar(i) end; gsynced = true elseif gpos > 0 then bar(gpos) end
    M:style('gcur', 'left', ((gpos % NB) * 4) .. 'px')
end
local function render_slow()
    M:rml('cost1', me.line1); M:rml('cost2', me.line2)
    local sub = {}
    if env.zone then sub[#sub + 1] = esc(env.zone) end
    if env.ping then sub[#sub + 1] = string.format('ping %d ms', env.ping) end
    local nrun = 0; for _, s in ipairs(env.scripts) do if s.status == 'RUNNING' then nrun = nrun + 1 end end
    sub[#sub + 1] = nrun .. ' Lua running'
    M:rml('subt', table.concat(sub, ' &#183; '))
    if not stats_visible() then return end
    local lo, hi = minmax_fps()
    M:text('gmm', lo and string.format('low %s  \194\183  high %s fps (30 s)', f0(lo), f0(hi)) or '')
    local function lg(p) return p and (p >= 85 and 'bad' or (p >= 60 and 'ok' or 'good')) end
    local ca = hw_avg('cp', 30)
    M:text('cpu', hw.cpu_p and string.format('%.0f%%', hw.cpu_p) or '--'); M:grade('cpu', lg(hw.cpu_p))
    M:text('cpud', hw.cpu_s and string.format('avg %s%% \194\183 sys %.0f%%', n0(ca), hw.cpu_s) or (K32 and 'measuring' or 'unavailable'))
    local live = gpu.state == 'live'
    local ga = hw_avg('gp', 30)
    M:text('gpu', live and hw.gp and string.format('%.0f%%', hw.gp) or '--'); M:grade('gpu', live and lg(hw.gp))
    M:text('gpud', live and string.format('avg %s%% \194\183 all %.0f%%', n0(ga), hw.gt or 0) or (cfg.gpu and gpu.state or 'off in Settings'))
    local function mb(v) if not v then return '--' end; if v >= 1024 then return string.format('%.1f GB', v / 1024) end; return string.format('%d MB', math.floor(v + 0.5)) end
    M:text('vram', live and mb(hw.vp) or '--')
    M:text('vramd', live and hw.vu and string.format('%.1f / %s GB used', hw.vu / 1024, hw.vt and string.format('%.1f', hw.vt / 1024) or '?') or (cfg.gpu and gpu.state or 'off in Settings'))
    M:text('hmm', string.format('cpu 0-%d%%  \194\183  gpu 0-%d%%', vh.sc, vh.sg))
    M:text('hlab_c', string.format('CPU %s%%', ca and n0(ca) or '--'))
    M:text('hlab_g', live and string.format('GPU %s%%', ga and n0(ga) or '--') or 'GPU --')
    M:class('htile', 'novz', not viz_on())
    M:text('mem', string.format('%d KB', math.floor(mem.kb / 10 + 0.5) * 10))
    local tr = mem.trend
    M:rml('memd', math.abs(tr) < 0.5 and 'steady, this script' or string.format('<span class="%s">%s%.1f KB/s</span>', tr > 0 and 'ok' or 'good', tr > 0 and '&#8593; +' or '&#8595; ', math.abs(tr)))
    M:text('zone', env.zone or '--')
    local zd = {}
    if env.spawns then zd[#zd + 1] = env.spawns .. ' spawns' end
    M:text('zoned', #zd > 0 and table.concat(zd, ' \194\183 ') or 'not in game')
    if env.docs then
        M:text('uik', 'RMLUI'); M:text('ui', tostring(env.docs.n) .. ' docs'); M:text('uid', env.docs.cap and ('limit ' .. tostring(env.docs.cap)) or 'open documents')
    else
        M:text('uik', 'LUA SCRIPTS'); M:text('ui', nrun .. ' running'); M:text('uid', #env.scripts .. ' loaded in total')
    end
    M:text('sch', string.format('LUA SCRIPTS (%d)', #env.scripts))
    for i = 1, SC do
        local s = env.scripts[i]
        M:class('s' .. i, 'empty', s == nil)
        if s then
            M:text('s' .. i .. 'n', s.name); M:text('s' .. i .. 'p', s.status == 'RUNNING' and ('#' .. s.pid) or (s.status:lower() .. ' #' .. s.pid))
            M:class('s' .. i, 'run', s.status == 'RUNNING'); M:class('s' .. i, 'pause', s.status == 'PAUSED')
        end
    end
    M:text('scmore', #env.scripts > SC and ('+' .. (#env.scripts - SC) .. ' more') or '')
    local hint, hc
    if cost.pending then hint = 'Measuring the cost of: ' .. esc(cost.pending.what) .. '...'
    elseif cost.base then
        local d = fps_over(8) - cost.base
        local ex = ''
        local c5, g5 = hw_avg('cp', 5), hw_avg('gp', 5)
        if cost.base_cp and c5 then ex = ex .. string.format(' \194\183 CPU %+.0f%%', c5 - cost.base_cp) end
        if cost.base_gp and g5 then ex = ex .. string.format(' \194\183 GPU %+.0f%%', g5 - cost.base_gp) end
        hint = string.format('A/B vs %.0f fps: <span class="%s">%+.1f fps</span>%s now.', cost.base, d >= 0 and 'good' or 'bad', d, esc(ex))
    elseif cost.last then hint = cost.last_g and string.format('<span class="%s">%s</span>', cost.last_g, esc(cost.last)) or esc(cost.last)
    else hint, hc = 'Start or stop a script, or mark a baseline, to see its cost.', true end
    M:rml('hint', hint); M:class('hint', 'idle', hc)
    M:text('a-ab', cost.base and 'Clear baseline' or 'Mark baseline'); M:class('a-ab', 'on', cost.base ~= nil)
    local rs = rec.f and math.floor((now() - rec.t0) / 1000) or 0
    M:rml('a-rec', rec.f and string.format('&#9632; %d:%02d', math.floor(rs / 60), rs % 60) or '&#9679; Rec'); M:class('a-rec', 'rec', rec.f ~= nil)
end
local function render_set()
    M:class('sw_compact', 'on', cfg.compact); M:class('sw_locked', 'on', cfg.locked)
    M:class('sw_viz', 'on', cfg.viz and VZ.ok); M:class('sw_gpu', 'on', cfg.gpu); M:class('sw_rec', 'on', rec.f ~= nil)
    M:text('vizd', VZ.ok and 'Animated bars, peak caps and glow (off = classic bars)' or 'Needs MQ2RmlUi canvas API 4 (classic bars in use)')
    M:text('gpud2', 'Hidden idle-priority sampler: GPU %, VRAM. State: ' .. gpu.state)
    M:text('recd', rec.err and ('Cannot write: ' .. rec.err) or (rec.f and string.format('Logs\\%s \194\183 %d rows', rec.name, rec.rows) or 'One row per second to Logs\\rmlfps_<date>.csv'))
    for _, m in ipairs({ 'full', 'clear', 'hover' }) do M:class('a-mode:' .. m, 'sel', cfg.mode == m) end
    for _, c in ipairs({ 'free', 'tl', 'tr', 'bl', 'br' }) do M:class('a-corner:' .. c, 'sel', (cfg.corner == '' and 'free' or cfg.corner) == c) end
    M:rml('thrv', string.format('<span class="good">%d</span> / <span class="ok">%d</span>', GOOD, OKV))
    M:text('thrd', string.format('Green %d+ fps, yellow %d+', GOOD, OKV))
    local k = thr_index()
    M:class('a-thr:-', 'dis', k == 1); M:class('a-thr:+', 'dis', k == #THRS)
    M:text('a-ab2', cost.base and 'Clear A/B' or 'A/B baseline')
end
local function apply_modes()
    for _, m in ipairs({ 'full', 'clear', 'hover' }) do M:class('body', 'mode-' .. m, cfg.mode == m) end
    M:class('body', 'compact', cfg.compact); M:class('body', 'locked', cfg.locked)
    M:class('body', 'set', tab == 'set'); M:class('body', 'viz', viz_on())
    M:class('a-tab:stats', 'sel', tab == 'stats'); M:class('a-tab:set', 'sel', tab == 'set')
end
local function refresh_all() if M then apply_modes(); render_set(); render_fast(); render_slow() end end

-- ------------------------------------------------------------------ actions
local function set_tab(t) if tab ~= t then tab = t; cfg.tab = t; save_cfg() end; gsynced = false; refresh_all() end
local function set_compact(on) cfg.compact = on; save_cfg(); gsynced = false; apply_modes(); place_main(); refresh_all() end
local function reset_stats() vf.v, vf.cap = {}, {}; for i = 0, HB - 1 do hist[i] = 0 end; ring, ri, rn = {}, 0, 0; tk.fr, tk.ms, tk.mx, tk.n = {}, {}, {}, 0; max5, low1, low01 = 0, nil, nil end
local ACT = {
    stop = function() running = false end,
    compact = function() set_compact(true) end,
    expand = function() set_compact(false) end,
    ['tab:stats'] = function() set_tab('stats') end,
    ['tab:set'] = function() set_tab('set') end,
    ['opt:compact'] = function() set_compact(not cfg.compact) end,
    ['opt:locked'] = function() cfg.locked = not cfg.locked; save_cfg(); refresh_all() end,
    ab = function()
        if cost.base then cost.base, cost.base_cp, cost.base_gp = nil, nil, nil
        else cost.base, cost.base_cp, cost.base_gp = fps_over(20), hw_avg('cp', 5), hw_avg('gp', 5) end
        refresh_all() end,
    rec = function() cfg.rec = not rec.f; save_cfg(); if cfg.rec then rec_open() else rec_close() end; refresh_all() end,
    ['opt:rec'] = function() cfg.rec = not rec.f; save_cfg(); if cfg.rec then rec_open() else rec_close() end; refresh_all() end,
    ['opt:viz'] = function() cfg.viz = not cfg.viz; save_cfg(); graph_scale(); gsynced = false; refresh_all() end,   -- classic bars keep the 1.5x-threshold scale
    ['opt:gpu'] = function() cfg.gpu = not cfg.gpu; save_cfg(); if cfg.gpu then gpu.restarts = 0; gpu.next_try = 0; gpu_start() else gpu_stop() end; refresh_all() end,
    reset = function() reset_stats(); refresh_all() end,
    ['thr:-'] = function() local k = thr_index() or 2; if k > 1 then cfg.thr = THRS[k - 1]; save_cfg(); apply_thr(); graph_scale(); refresh_all() end end,
    ['thr:+'] = function() local k = thr_index() or 2; if k < #THRS then cfg.thr = THRS[k + 1]; save_cfg(); apply_thr(); graph_scale(); refresh_all() end end,
}
for _, m in ipairs({ 'full', 'clear', 'hover' }) do ACT['mode:' .. m] = function() cfg.mode = m; save_cfg(); refresh_all() end end
for _, c in ipairs({ 'free', 'tl', 'tr', 'bl', 'br' }) do ACT['corner:' .. c] = function()
    if c == 'free' then local x, y = get_pos(); if x then cfg.x, cfg.y = tostring(x), tostring(y) end; cfg.corner = '' else cfg.corner = c end
    save_cfg(); place_main(); refresh_all() end end

local function on_event(ev)
    if ev.type == 'windowmoved' then if on_moved(parse_xy(ev.value)) then render_set() end; return end
    local a = ev.action or ''
    if a == '' and type(ev.id) == 'string' and ev.id:sub(1, 2) == 'a-' then a = ev.id:sub(3) end
    local right = tonumber(ev.button) == 1
    if right and (ev.type == 'mousedown' or ev.type == 'click') then   -- right-click anywhere: settings
        if cfg.compact then cfg.compact = false; save_cfg(); place_main() end
        return set_tab('set')
    end
    if ev.type ~= 'click' then return end
    local f = ACT[a]
    if f then local ok, e = pcall(f); if not ok then print(TAG .. tostring(e)) end end
end

-- ------------------------------------------------------------------ main
local next_slow = 0
local function tick()
    local t = now()
    on_frame_time()
    if tick_t0 == 0 then tick_t0 = t end
    if t - tick_t0 >= TICK then
        tk_push(tick_frames, t - tick_t0, tick_max)
        cur_fps = fps_over(4)                               -- 1 s rolling
        avg_fps = fps_over(TK_N)
        max5 = max_over(20)
        local p99, p999 = pct_ms(0.99), pct_ms(0.999)
        low1 = p99 and 1000 / p99 or nil; low01 = p999 and 1000 / p999 or nil
        if low1 and low1 > avg_fps then low1 = avg_fps end; if low01 and low1 and low01 > low1 then low01 = low1 end
        gpos = gpos % NB + 1; gval[gpos] = tick_frames * 1000 / (t - tick_t0)
        vf.k = vf.k + 1; if vf.k % 2 == 0 then vf_push(fps_over(2), t); if vf.rescale then graph_scale(vf.rescale); vf.rescale = nil end end
        render_fast()
        tick_frames, tick_max, tick_t0 = 0, 0, t
        if t >= next_slow then next_slow = t + 1000; probe_mem(); check_pending(); self_cost_tick(t); render_slow(); if tab == 'set' and not cfg.compact then render_set() end end
    end
end
local function frame()
    if not M then return end
    local u0 = usec()
    for ev in M.win:events() do on_event(ev) end
    tick()
    if viz_on() and stats_visible() then viz_frame(now()) end
    local d = usec() - u0
    me.us = me.us + d; me.frames = me.frames + 1
end

viz_init()
M = open('RmlFps', 'fps.rml', size())
if not M then return end
pcall(function() mq.imgui.destroy('rmlfps') end)
apply_modes(); graph_scale(); place_main()
refresh_all()

local cleaned = false
local function cleanup()
    if cleaned then return end; cleaned = true
    pcall(function() mq.imgui.destroy('rmlfps') end)
    if M and cfg.corner == '' then local x, y = get_pos(); if x then cfg.x, cfg.y = tostring(x), tostring(y); save_cfg() end end
    pcall(gpu_stop); pcall(rec_close)
    if M then pcall(function() M.win:close() end) end
    M = nil
end
-- plain "/lua stop rmlfps" ends the state without running code after the loop: close the window from __gc
local sentinel = newproxy and newproxy(true)
if sentinel then getmetatable(sentinel).__gc = function() pcall(cleanup) end end
_G.__rmlfps_sentinel = sentinel

-- per-frame hook only (no ImGui window is drawn; MQ's Lua frame callback is registered through mq.imgui)
mq.imgui.init('rmlfps', function() local ok, e = pcall(frame); if not ok then print(TAG .. tostring(e)) end end)
print(TAG .. REV .. ' loaded. Right-click the meter or open Settings for options.')
local function rec_row()
    local f = rec.f; if not f then return end
    local zone = tostring(env.zone or ''):gsub('[,"\r\n]', ' ')
    f:write(os.date('%Y-%m-%d %H:%M:%S'), ',', n1(cur_fps > 0 and cur_fps or nil), ',', cur_fps > 0 and string.format('%.2f', 1000 / cur_fps) or '', ',',
        n1(low1), ',', max5 > 0 and tostring(max5) or '', ',', n1(hw.cpu_p), ',', n1(hw.cpu_s), ',', n1(hw.gp), ',', n1(hw.gt), ',',
        n0(hw.vp), ',', n0(hw.vu), ',', n0(hw.vt), ',', zone, '\n')
    rec.rows = rec.rows + 1
    if rec.rows % 5 == 0 then f:flush() end
end
if cfg.rec then rec_open() end
if cfg.gpu then gpu_start() end
local next_env, next_hw = 0, 0
while running do
    local t = now()
    if t >= next_hw then                                   -- 1 Hz: cpu (ffi), gpu file, history, csv row
        next_hw = t + 1000
        local u0 = usec()
        pcall(probe_cpu); pcall(gpu_read); hw_push(); vh_push(t)
        local okr, er = pcall(rec_row); if not okr then rec.err = tostring(er); rec_close() end
        me.hw_us = usec() - u0
    end
    if t >= next_env then
        next_env = t + 2000
        local u0 = usec()
        local ok1, e1 = pcall(probe_env); if not ok1 then print(TAG .. 'probe: ' .. tostring(e1)) end; pcall(detect_change)
        me.probe_us = usec() - u0
    end
    mq.delay(100)
end
cleanup()
print(TAG .. 'stopped.')
