-- combatfx/loadout.lua (f8b): one-click profiles. A loadout is the whole setup of this character (every CombatFX
-- setting: theme + look, auras, ornament set + per-slot swaps + materials, Body FX, alerts, filters, markers ...)
-- saved under a name and a role. Window positions, records, the simulator and the parse history are not part of it.
--   file  config\combatfx_loadouts_<server>_<char>.ini   [Name]  _role=Tank  _t=<os.time>  <section.key>=<value>
local C = require('combatfx.core')
local M = { REV = 'f8b' }
local mq = package.loaded['mq'] or {}

M.ROLES = { 'Any', 'Tank', 'Healer', 'Melee DPS', 'Caster', 'Support' }
-- never part of a loadout: placement, records, simulator knobs, the loadout pointer itself
local SKIP_TOP = { pos = true, rec = true, launcher_x = true, launcher_y = true, sim_eps = true, sim_power = true, sim_loop = true }
local SKIP_KEY = { ['parses.lo'] = true, ['naura.prev'] = true, ['tfx.ver'] = true }

function M.path()
    if M._path then return M._path end
    local sv = C.str(function() return mq.TLO.EverQuest.Server() end, 'server'):gsub('[^%w]', '')
    return string.format('%s/combatfx_loadouts_%s_%s.ini', mq.configDir or '.', sv, tostring(C.CHAR or 'char'):gsub('[^%w]', ''))
end
function M.clean_name(n)
    n = tostring(n or ''):gsub('[%[%]=\r\n%c]', ''):gsub('^%s+', ''):gsub('%s+$', '')
    return n:sub(1, 32)
end
function M.snapshot()
    local o = {}
    for _, l in ipairs(C.ser_cfg(C.cfg)) do
        local k, v = l:match('^([^=]+)=(.*)$')
        if k then
            local top = k:match('^([%w_]+)')
            if not SKIP_TOP[top] and not SKIP_KEY[k] then o[k] = v end
        end
    end
    return o
end
-- read: { order = { names }, by = { [name] = { role, t, kv = { key = value } } } }
function M.list()
    local by, order, cur = {}, {}, nil
    local f = io.open(M.path(), 'r')
    if f then
        for l in f:lines() do
            l = l:gsub('\r$', '')
            local s = l:match('^%[(.+)%]%s*$')
            if s then cur = { name = s, role = 'Any', t = 0, kv = {} }; if not by[s] then order[#order + 1] = s end; by[s] = cur
            elseif cur then
                local k, v = l:match('^([%w%._]+)=(.*)$')
                if k == '_role' then cur.role = v elseif k == '_t' then cur.t = tonumber(v) or 0 elseif k then cur.kv[k] = v end
            end
        end
        f:close()
    end
    return { order = order, by = by }
end
local function write(L)
    local f = io.open(M.path(), 'w'); if not f then return false end
    for _, n in ipairs(L.order) do
        local e = L.by[n]
        f:write('[', n, ']\n_role=', e.role or 'Any', '\n_t=', tostring(e.t or 0), '\n')
        local ks = {}; for k in pairs(e.kv) do ks[#ks + 1] = k end; table.sort(ks)
        for _, k in ipairs(ks) do f:write(k, '=', tostring(e.kv[k]), '\n') end
    end
    f:close(); return true
end
function M.save(name, role)
    name = M.clean_name(name)
    if name == '' then return false, 'name it first' end
    local L = M.list()
    if not L.by[name] then L.order[#L.order + 1] = name end
    L.by[name] = { name = name, role = role or (L.by[name] and L.by[name].role) or 'Any', t = os.time(), kv = M.snapshot() }
    local ok = write(L)
    if ok then C.cfg.parses = C.cfg.parses or {}; C.cfg.parses.lo = name; C.save_cfg() end
    return ok, ok and ('Saved loadout ' .. name) or ('cannot write ' .. M.path())
end
function M.delete(name)
    local L = M.list()
    if not L.by[name] then return false end
    L.by[name] = nil
    for i, n in ipairs(L.order) do if n == name then table.remove(L.order, i); break end end
    return write(L)
end
function M.set_role(name, role)
    local L = M.list(); if not L.by[name] then return false end
    L.by[name].role = role; return write(L)
end
local function conv(s)
    if s == 'true' then return true elseif s == 'false' then return false end
    local n = tonumber(s); if n and tostring(n) == s then return n end
    return s
end
-- settings that differ between the live setup and a loadout: { { key, now, loadout } }
function M.diff(e)
    local cur = M.snapshot()
    local d = {}
    for k, v in pairs(e.kv) do if cur[k] ~= v then d[#d + 1] = { k, cur[k], v } end end
    table.sort(d, function(a, b) return a[1] < b[1] end)
    return d
end
-- apply: every key back into C.cfg (sub-tables created when a module made them lazily), then each native module syncs
function M.apply(name)
    local L = M.list()
    local e = L.by[name]
    if not e then return false, 'no loadout ' .. tostring(name) end
    local old_set, old_mat = C.cfg.orn and C.cfg.orn.set, C.cfg.orn and C.cfg.orn.mat
    for k, v in pairs(e.kv) do
        local a, b = k:match('^([%w_]+)%.([%w_]+)$')
        if a and C.cfg[a] == nil then C.cfg[a] = {} end
        if a and type(C.cfg[a]) == 'table' and C.cfg[a][b] == nil then C.cfg[a][b] = conv(v)
        elseif not a and C.cfg[k] == nil then C.cfg[k] = conv(v)
        else C.apply_kv(C.cfg, k, v) end
    end
    C.cfg.parses = C.cfg.parses or {}; C.cfg.parses.lo = name
    C.save_cfg()
    local function try(mod, fn, ...) local m = package.loaded[mod]; if m and m[fn] then pcall(m[fn], ...) end end
    try('combatfx.fx', 'apply_settings')
    if type(C.cfg.tfx) == 'table' then C.cfg.tfx.ver = 1 end          -- the loadout's own look: no first-run theme look on top
    try('combatfx.features', 'refresh_lists')
    try('combatfx.features', 'set_burns', C.cfg.parses.burns or '')
    try('combatfx.nimbus', 'sync')
    try('combatfx.aura', 'sync')
    if C.cfg.orn and (C.cfg.orn.set ~= old_set or C.cfg.orn.mat ~= old_mat) then try('combatfx.ornament', 'reapply') end
    return true, 'Loadout ' .. name .. ' on'
end
function M.current() return (C.cfg.parses and C.cfg.parses.lo) or '' end

-- thumbnail summary (the picker preview): colour swatches of the theme lanes + what the loadout wears
local SW_KINDS = { 'melee', 'spell', 'crit', 'incoming', 'healin', 'kill' }
function M.summary(e)
    local kv = e.kv
    local s = { theme = kv.theme or '?', colors = {}, lines = {} }
    for _, k in ipairs(SW_KINDS) do s.colors[#s.colors + 1] = kv['color.' .. k] or '#888888' end
    local function name_of(mod, id)
        id = tonumber(id) or 0; if id <= 0 then return nil end
        local ok, m = pcall(require, mod); local d = ok and m and (m.D or m) or nil
        local by = d and d.by_id
        local n = by and by[id]
        return n and n.name or ('#' .. id)
    end
    local aura = name_of('combatfx.aura_data', kv['naura.id'])
    local nim = (kv['bodyfx.on'] ~= 'false') and name_of('combatfx.nimbus_data', kv['bodyfx.native']) or nil
    local pts = 0; for _ in tostring(kv['orn.set'] or ''):gmatch('%d+:IT%d+') do pts = pts + 1 end
    local mats = 0; for _ in tostring(kv['orn.mat'] or ''):gmatch('%d+:%d+') do mats = mats + 1 end
    local al, aln = 0, 0
    for k, v in pairs(kv) do if k:match('^alerts%.') then aln = aln + 1; if v == 'true' then al = al + 1 end end end
    local fon, fn = 0, 0
    for k, v in pairs(kv) do if k:match('^on%.') then fn = fn + 1; if v == 'true' then fon = fon + 1 end end end
    s.lines[#s.lines + 1] = 'Look: ' .. (kv.theme or '?') .. ((kv['tfx.on'] == 'false') and ' (classic text)' or '')
    s.lines[#s.lines + 1] = 'Aura: ' .. (aura or 'none') .. ' · Body FX: ' .. (kv['bodyfx.on'] == 'false' and 'off' or (nim or (kv['bodyfx.style'] or 'none')))
    s.lines[#s.lines + 1] = string.format('Ornaments: %s · materials %d', pts > 0 and (pts .. ' slots') or 'real gear', mats)
    s.lines[#s.lines + 1] = string.format('Alerts %d/%d on · numbers %d/%d lanes', al, aln, fon, fn)
    return s
end
return M
