-- combatfx paths: where things live on THIS machine. Nothing here is hard coded to one PC.
-- Order for every folder: auto-detect from MacroQuest itself (TLOs), then config\combatfx_paths.ini, then a safe default.
--   EQ folder   : mq.TLO.EverQuest.Path()          (MQ sets it to eqgame's working directory)
--   logs folder : mq.TLO.MacroQuest.Path('logs')() (MQ's own Logs setting), else <MQ root>\Logs
--   sounds      : %WINDIR%\Media (Windows' built-in chimes/ding/notify/tada)
-- Features that need a missing folder or file switch themselves off and say why (M.need()).
local M = {}

local INI_NAME = 'combatfx_paths.ini'
M.TEMPLATE = [[
; CombatFX paths. Leave a value empty to auto-detect it (recommended).
; CombatFX first asks MacroQuest where things are; a value here is used only when auto-detect fails.
; Use full Windows paths, no quotes, e.g.  eq_folder=D:\Games\EverQuest
; After editing: /lua stop combatfx  then  /lua run combatfx  (or press "Re-check" on the Effects tab).
[paths]
; EverQuest client folder (the one with eqgame.exe). Used to check that ornament set archives (*.eqg)
; and client data files (Resources\NewArmorTagData.txt, spellsnew.eff/.edd, actoremittersnew.edd) exist.
eq_folder=
; Where CombatFX writes its optional debug logs (default: MacroQuest's Logs folder).
logs_folder=
; Folder with the alert sounds chimes.wav, ding.wav, notify.wav, tada.wav (default: C:\Windows\Media or your %WINDIR%\Media).
sounds=
; 1 = write debug logs (combatfx_fx.log, combatfx_lines.log) to logs_folder; 0 = off (default, no files grow).
debug_logs=0
]]

-- client data files: rel path inside the EQ folder -> what uses it
M.EQ_FILES = {
    { 'eqgame.exe', 'the EverQuest client itself (confirms the folder)' },
    { 'Resources/NewArmorTagData.txt', 'ornament armor catalog (only needed to rebuild it for another race)' },
    { 'spellsnew.eff', 'native Body FX / auras (the client loads it; the plugin reads it from memory)' },
    { 'spellsnew.edd', 'native Body FX / auras emitter definitions' },
    { 'actoremittersnew.edd', 'actor emitters (native class aura research)' },
}

local function mq_()
    local ok, mq = pcall(require, 'mq'); return ok and mq or nil
end
local function s_(f)
    local ok, v = pcall(f)
    if ok and v ~= nil and tostring(v) ~= '' and tostring(v) ~= 'NULL' then return tostring(v) end
    return nil
end
local function trim(p) return (tostring(p or ''):gsub('^%s+', ''):gsub('%s+$', ''):gsub('^"(.*)"$', '%1'):gsub('[/\\]+$', '')) end
M._trim = trim
function M.join(a, b) return trim(a) .. '\\' .. tostring(b):gsub('/', '\\') end
function M.exists(p)
    if M._exists then return M._exists(p) end                 -- headless tests
    local f = p and io.open(p, 'rb'); if f then f:close(); return true end; return false
end
-- a folder exists if we can create+remove a probe file in it or if a known file is inside; Lua has no stat, so callers
-- pass a file that must be there (eqgame.exe, chimes.wav) instead.

function M.config_dir()
    local mq = mq_()
    local d = mq and mq.configDir
    if d and d ~= '' then return trim(d) end
    d = mq and s_(function() return mq.TLO.MacroQuest.Path('config')() end)
    return d and trim(d) or '.'
end
function M.ini_path() return M.config_dir() .. '/' .. INI_NAME end   -- '/' like every other combatfx config file

-- ---------------------------------------------------------------- ini (created once with comments; never overwritten)
local ini = nil
function M.read_ini()
    local path = M.ini_path()
    M.created = false
    local f = io.open(path, 'r')
    if not f then
        local w = io.open(path, 'w')
        if w then w:write(M.TEMPLATE); w:close(); M.created = true end
        f = io.open(path, 'r')
    end
    local t = { eq_folder = '', logs_folder = '', sounds = '', debug_logs = '0' }
    if f then
        for line in f:lines() do
            local k, v = line:match('^%s*([%w_]+)%s*=%s*(.-)%s*$')
            if k and t[k] ~= nil and not line:match('^%s*;') then t[k] = trim(v) end
        end
        f:close()
        M.ini_ok = true
    else
        M.ini_ok = false
    end
    ini = t
    return t
end
function M.ini() return ini or M.read_ini() end

-- ---------------------------------------------------------------- detection
M.info = nil
local function pick(auto, auto_src, ini_v, probe)
    -- auto first; the ini value only when auto-detect found nothing usable
    if auto and (not probe or M.exists(M.join(auto, probe))) then return trim(auto), auto_src, nil end
    if ini_v and ini_v ~= '' then
        if not probe or M.exists(M.join(ini_v, probe)) then return trim(ini_v), 'ini', nil end
        return nil, nil, string.format('the ini path "%s" has no %s', ini_v, probe)
    end
    return nil, nil, auto and string.format('auto-detected "%s" has no %s', auto, probe or '?') or 'auto-detect failed'
end

function M.detect()
    local mq = mq_()
    local t = M.read_ini()
    local i = {}
    i.mq_root = mq and s_(function() return mq.TLO.MacroQuest.Path('root')() end) or nil
    i.lua_dir = mq and mq.luaDir and mq.luaDir ~= '' and trim(mq.luaDir) or (i.mq_root and (trim(i.mq_root) .. '\\lua')) or nil
    i.config = M.config_dir()
    -- EQ folder (eqgame.exe must be inside)
    local eq_auto = mq and s_(function() return mq.TLO.EverQuest.Path() end) or nil
    i.eq, i.eq_src, i.eq_why = pick(eq_auto, 'auto', t.eq_folder, 'eqgame.exe')
    i.eq_files = {}
    for _, e in ipairs(M.EQ_FILES) do
        i.eq_files[#i.eq_files + 1] = { rel = e[1], use = e[2], ok = i.eq and M.exists(M.join(i.eq, e[1])) or false }
    end
    -- logs folder (no probe file: MQ always has one; the ini wins only if auto is empty)
    local lg = mq and s_(function() return mq.TLO.MacroQuest.Path('logs')() end) or nil
    if not lg and i.mq_root then lg = trim(i.mq_root) .. '\\Logs' end
    if not lg and i.config ~= '.' then lg = i.config:gsub('[/\\][Cc]onfig$', '') .. '\\Logs' end
    i.logs, i.logs_src = (lg and trim(lg)) or (t.logs_folder ~= '' and t.logs_folder) or nil, lg and 'auto' or (t.logs_folder ~= '' and 'ini' or nil)
    -- sounds (chimes.wav must be inside)
    local win = os.getenv and os.getenv('WINDIR') or nil
    if win and (win == '' or win:find('"')) then win = nil end
    i.snd, i.snd_src, i.snd_why = pick(win and (trim(win) .. '\\Media') or nil, 'auto', t.sounds, 'chimes.wav')
    i.debug = tostring(t.debug_logs) == '1'
    M.info = i
    return i
end
function M.get() return M.info or M.detect() end

-- ---------------------------------------------------------------- helpers the other modules use
function M.eq_dir() return M.get().eq end
function M.eq_file(rel)
    local d = M.get().eq; if not d then return nil end
    local p = M.join(d, rel)
    return M.exists(p) and p or nil
end
-- nil when debug logs are off (the default) or no logs folder is known
function M.log_path(name)
    local i = M.get()
    if not i.debug or not i.logs then return nil end
    return M.join(i.logs, name)
end
-- full path of a .wav or nil, why
function M.sound_file(name)
    local i = M.get()
    if not i.snd then return nil, 'sound folder not found (' .. tostring(i.snd_why) .. '); set sounds= in ' .. INI_NAME end
    local p = M.join(i.snd, name .. '.wav')
    if not M.exists(p) then return nil, name .. '.wav is not in ' .. i.snd end
    return p
end
-- ornament set archive check: true when the EQ folder is known and the .eqg is there; nil = cannot tell (EQ folder unknown)
local arch_cache = {}
function M.archive_ok(name)
    if not name or name == '' then return nil end
    local d = M.get().eq; if not d then return nil end
    local k = name:lower()
    if arch_cache[k] == nil then arch_cache[k] = M.exists(M.join(d, name)) end
    return arch_cache[k]
end
function M.reset() M.info = nil; ini = nil; arch_cache = {} end

-- ---------------------------------------------------------------- client compatibility (native hooks byte-checked by MQ2RmlUi)
M.BUILD = 'eqgame "Sep 11 2025 11:54:10" (TOB) + its EQGraphics.dll'
local NATIVE = {
    { 2048, 'rml_nimbus_status', 'Body FX nimbus / native auras' },
    { 4096, 'rml_mat_status', 'material tints' },
    { 8192, 'rml_orn_status', 'ornament swaps' },
}
function M.client_compat()
    if M._compat then return M._compat() end                    -- headless tests
    local ok, ffi = pcall(require, 'ffi')
    if not ok then return { plugin = false, text = 'LuaJIT FFI not available', cls = 'wn' } end
    pcall(ffi.cdef, 'int rml_features(void);')
    for _, n in ipairs(NATIVE) do pcall(ffi.cdef, 'const char* ' .. n[2] .. '(void);') end
    local ok2, lib = pcall(ffi.load, 'MQ2RmlUi')
    if not (ok2 and lib) then return { plugin = false, cls = 'wn', text = 'MQ2RmlUi plugin not loaded: CombatFX needs it for every window (/plugin MQ2RmlUi)' } end
    local feat = 0; pcall(function() feat = tonumber(lib.rml_features()) or 0 end)
    local on, off = {}, {}
    for _, n in ipairs(NATIVE) do
        if math.floor(feat / n[1]) % 2 == 1 then on[#on + 1] = n[3]
        else
            local why
            pcall(function() local p = lib[n[2]](); if p ~= nil then why = ffi.string(p):match('verified=%-?%d+%(([^)]*)%)') end end)
            off[#off + 1] = n[3] .. (why and why ~= '' and (' (' .. why .. ')') or '')
        end
    end
    local r = { plugin = true, feat = feat, on = on, off = off }
    if #off == 0 then
        r.cls, r.text = 'ok', 'native hooks verified for this client (' .. M.BUILD .. ')'
    elseif #on == 0 then
        r.cls, r.text = 'wn', 'native hooks NOT verified for this eqgame build: ' .. table.concat(off, ', ') .. ' are off. Everything else works'
    else
        r.cls, r.text = 'wn', 'partly verified: on = ' .. table.concat(on, ', ') .. '; off = ' .. table.concat(off, ', ')
    end
    return r
end
return M
