-- ButtonMaster RML core: settings (ButtonMaster v7 data model, own file), command execution, timers/cooldowns,
-- label/icon/condition evaluation (sliced across frames), share/import, and the effect style model.
-- Nothing here touches the original ButtonMaster files except a one-time READ of config/ButtonMaster.lua.
local mq = require('mq')
local base64 = require('buttonmaster_rml.base64')
local C = {}
C.VERSION = 7                        -- ButtonMaster data version we read/write
C.settings = nil
C.path = mq.configDir .. '/ButtonMaster_RML.lua'
C.orig_path = mq.configDir .. '/ButtonMaster.lua'
C.TimerTypes = { 'Seconds Timer', 'Item', 'Spell Gem', 'AA', 'Ability', 'Disc', 'Custom Lua' }
C.UpdateRates = { { 'Every frame', 0 }, { '1 per second', 1 }, { '2 per second', 0.5 }, { '4 per second', 0.25 }, { '10 per second', 0.1 }, { '20 per second', 0.05 } }

local function tlo(fn, d) local ok, v = pcall(fn); if ok and v ~= nil then return v end; return d end
C.tlo = tlo
function C.now() return mq.gettime() / 1000 end          -- seconds (ms clock)
function C.out(fmt, ...) local ok, s = pcall(string.format, fmt, ...); print('\aw[\aoButton Master RML\aw] \a-t' .. (ok and s or fmt)) end
function C.charkey() return string.format('%s_%s', tostring(tlo(function() return mq.TLO.EverQuest.Server() end, 'server')), tostring(tlo(function() return mq.TLO.Me.DisplayName() end, 'char'))) end

function C.deepcopy(o, seen)
    if type(o) ~= 'table' then return o end
    seen = seen or {}; if seen[o] then return seen[o] end
    local r = {}; seen[o] = r
    for k, v in pairs(o) do r[C.deepcopy(k, seen)] = C.deepcopy(v, seen) end
    return r
end
function C.split(s, sep) local t = {}; if not s then return t end; s = tostring(s)
    local i = 1
    while true do local a, b = s:find(sep, i, true); if not a then t[#t + 1] = s:sub(i); break end; t[#t + 1] = s:sub(i, a - 1); i = b + 1 end
    return t
end

-- ---------------------------------------------------------------- serialize (same text format ButtonMaster shares)
local function ser(val, name, depth)
    depth = depth or 0
    local tmp = string.rep(' ', depth)
    if name then if type(name) ~= 'number' then name = string.format('%q', name) end; tmp = tmp .. '[' .. name .. '] = ' end
    if type(val) == 'table' then
        tmp = tmp .. '{\n'
        for k, v in pairs(val) do tmp = tmp .. ser(v, k, depth + 1) .. ',\n' end
        tmp = tmp .. string.rep(' ', depth) .. '}'
    elseif type(val) == 'number' then tmp = tmp .. tostring(val)
    elseif type(val) == 'string' then tmp = tmp .. string.format('%q', val)
    elseif type(val) == 'boolean' then tmp = tmp .. (val and 'true' or 'false')
    else tmp = tmp .. '"[inserializeable datatype:' .. type(val) .. ']"' end
    return tmp
end
C.serialize = ser
-- runtime-only fields are never saved or shared
local VOLATILE = { CachedLabel = 1, CachedCountDown = 1, CachedCoolDownTimer = 1, CachedToggleLocked = 1, CachedLastRan = 1, CooldownTimer = 1, labelMidX = 1, labelMidY = 1, highestRenderTime = 1, CachedIcon = 1, CachedIconType = 1, CachedCond = 1 }
local function clean(t)
    local r = {}
    for k, v in pairs(t) do if not VOLATILE[k] then r[k] = type(v) == 'table' and C.deepcopy(v) or v end end
    return r
end
C.clean = clean
function C.encode(tbl) return base64.enc('return ' .. ser(tbl)) end
function C.decode(s)
    s = tostring(s or ''):gsub('%s', '')
    local ok, txt = pcall(base64.dec, s)
    if not ok or not txt then return false, 'not valid share text' end
    local fn = load(txt, 'import', 't', {})
    if not fn then return false, 'not valid share text' end
    local ok2, t = pcall(fn)
    if not ok2 or type(t) ~= 'table' then return false, 'not valid share text' end
    return true, t
end

-- ---------------------------------------------------------------- settings
local function fresh(ck)
    return { Version = C.VERSION,
        Sets = { Primary = { 'Button_1', 'Button_2', 'Button_3' }, Movement = { 'Button_4' } },
        Buttons = { Button_1 = { Label = 'Burn (all)', Cmd = '/bcaa //burn\n/timed 500 /bcaa //burn' },
            Button_2 = { Label = 'Pause (all)', Cmd = '/bcaa //multi ; /twist off ; /mqp on' },
            Button_3 = { Label = 'Unpause (all)', Cmd = '/bcaa //mqp off' },
            Button_4 = { Label = 'Nav Target (bca)', Cmd = '/bca //nav id ${Target.ID}' } },
        Characters = { [ck] = { Windows = { { Visible = true, Pos = { x = 10, y = 10 }, Sets = {}, Locked = false } } } } }
end
local function readfile(p) local f = io.open(p, 'r'); if not f then return nil end; local s = f:read('*a'); f:close(); return s end
local function loadlua(p)
    local s = readfile(p); if not s then return nil end
    local fn = load(s, '@' .. p, 't', {}); if not fn then return nil end
    local ok, t = pcall(fn); if ok and type(t) == 'table' then return t end
end
C.loadlua = loadlua

-- ButtonMaster <v7 upgrades (ported from bmSettings:ConvertToLatestConfigVersion, applied to OUR copy only)
local function upgrade(s)
    if not s.Version then
        local n = { Buttons = {}, Sets = {}, Characters = {}, Global = s.Global }
        for k, v in pairs(s) do
            if type(v) == 'table' and k:find('^Button_') then
                if v.Cmd1 or v.Cmd2 or v.Cmd3 or v.Cmd4 or v.Cmd5 then
                    v.Cmd = table.concat({ v.Cmd or '', v.Cmd1 or '', v.Cmd2 or '', v.Cmd3 or '', v.Cmd4 or '', v.Cmd5 or '' }, '\n'):gsub('\n+', '\n'):gsub('\n$', ''):gsub('^\n', '')
                    v.Cmd1, v.Cmd2, v.Cmd3, v.Cmd4, v.Cmd5 = nil, nil, nil, nil, nil
                end
                n.Buttons[k] = {}; for a, b in pairs(v) do n.Buttons[k][a] = tostring(b) end
            elseif k:find('^Set_') then n.Sets[k:sub(5)] = v
            else
                local ck = k:match('^Char_(.*)_Config$')
                if ck and type(v) == 'table' then
                    n.Characters[ck] = n.Characters[ck] or {}
                    for a, b in pairs(v) do
                        if type(a) == 'number' then n.Characters[ck].Sets = n.Characters[ck].Sets or {}; table.insert(n.Characters[ck].Sets, b)
                        else n.Characters[ck][a] = b end
                    end
                end
            end
        end
        s = n
    end
    if (s.Version or 0) < 5 then
        s.Version = 5
        for _, c in pairs(s.Characters or {}) do if c.Sets then c.Windows = { { Sets = c.Sets, Visible = true } }; c.Sets = nil end end
    end
    if (s.Version or 0) < 6 then
        s.Version = 6; s.Defaults = nil
        for _, c in pairs(s.Characters or {}) do
            for _, w in ipairs(c.Windows or {}) do w.Locked = c.Locked or false; w.HideTitleBar = c.HideTitleBar or false end
            c.HideTitleBar, c.Locked = nil, nil
        end
        if s.Global then s.Global.ButtonCount = nil end
    end
    if (s.Version or 0) < 7 then
        s.Version = 7
        local g = s.Global or {}
        for _, c in pairs(s.Characters or {}) do for _, w in ipairs(c.Windows or {}) do w.Font = (g.Font or 1) * 10; w.ButtonSize = g.ButtnSize or 6 end end
        s.Global = nil
    end
    return s
end

function C.load()
    local ck = C.charkey(); C.CharConfig = ck
    local s = loadlua(C.path)
    C.first_run = false
    if not s then
        local o = loadlua(C.orig_path)
        if o then s = upgrade(C.deepcopy(o)); C.out('First run: copied your ButtonMaster buttons from %s (the original file is not changed).', C.orig_path)
        else s = fresh(ck); C.out('No ButtonMaster config found, starting with the default buttons.') end
        C.first_run = true
    elseif (s.Version or 0) < C.VERSION then s = upgrade(s) end
    s.Sets = s.Sets or {}; s.Buttons = s.Buttons or {}; s.Characters = s.Characters or {}
    s.Characters[ck] = s.Characters[ck] or {}
    local cc = s.Characters[ck]
    if not cc.Windows or #cc.Windows == 0 then cc.Windows = { { Visible = true, Pos = { x = 10, y = 10 }, Sets = {}, Locked = false } } end
    for _, w in ipairs(cc.Windows) do w.Sets = w.Sets or {} end
    s.Rml = s.Rml or {}                        -- port-only globals: effects quality, styles, demo
    s.Rml.Styles = s.Rml.Styles or {}
    if s.Rml.Reduced == nil then s.Rml.Reduced = false end
    s.Rml.Quality = s.Rml.Quality or 'balanced'
    C.settings = s
    if C.first_run then C.save(false) end
    return true
end
local last_backup_check = 0
function C.save(broadcast)
    local s = C.settings; if not s then return end
    if not s.LastBackup or os.time() - s.LastBackup > 86400 then
        s.LastBackup = os.time()
        pcall(mq.pickle, mq.configDir .. '/ButtonMaster_RML-Backups/ButtonMaster_RML-backup-' .. os.date('%m-%d-%y-%H-%M-%S') .. '.lua', C.saveable())
    end
    pcall(mq.pickle, C.path, C.saveable())
    if broadcast ~= false and C.actor and tlo(function() return mq.TLO.MacroQuest.GameState() end, '') == 'INGAME' then
        pcall(function() C.actor:send({ from = mq.TLO.Me.DisplayName(), script = 'ButtonMasterRml', event = 'SaveSettings', newSettings = C.saveable() }) end)
    end
end
function C.saveable()
    local s = C.settings
    local r = {}
    for k, v in pairs(s) do if k ~= 'Buttons' then r[k] = v end end
    r.Buttons = {}
    for k, b in pairs(s.Buttons) do r.Buttons[k] = clean(b) end
    return r
end
local save_due
function C.save_soon() save_due = mq.gettime() + 600 end
function C.tick_save() if save_due and mq.gettime() >= save_due then save_due = nil; C.save(true) end end
function C.char() return C.settings.Characters[C.CharConfig] end
function C.win(id) return C.char().Windows[id] end

function C.gen_key()
    local i = 1
    while C.settings.Buttons[string.format('Button_%d', i)] do i = i + 1 end
    return string.format('Button_%d', i)
end
function C.button_at(set, idx)
    local s = C.settings.Sets[set]
    local k = s and s[idx]
    local b = k and C.settings.Buttons[k]
    return b, k
end
function C.sets_sorted() local t = {}; for k in pairs(C.settings.Sets) do t[#t + 1] = k end; table.sort(t, function(a, b) return a:lower() < b:lower() end); return t end
function C.buttons_sorted()
    local t = {}
    for k, b in pairs(C.settings.Buttons) do t[#t + 1] = k end
    table.sort(t, function(a, b) return tostring(C.settings.Buttons[a].Label or a):lower() < tostring(C.settings.Buttons[b].Label or b):lower() end)
    return t
end
function C.set_size(set) local n = 0; for k in pairs(C.settings.Sets[set] or {}) do if type(k) == 'number' and k > n then n = k end end; return n end

function C.create_set(name)
    name = tostring(name or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if name == '' then return false, 'Type a name for the set' end
    if C.settings.Sets[name] then return false, 'A set with that name already exists' end
    C.settings.Sets[name] = {}; C.save(true); return true
end
function C.rename_set(old, new)
    new = tostring(new or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if new == '' or C.settings.Sets[new] then return false, new == '' and 'Type a new name' or 'That name is taken' end
    C.settings.Sets[new], C.settings.Sets[old] = C.settings.Sets[old], nil
    for _, cd in pairs(C.settings.Characters) do for _, w in ipairs(cd.Windows or {}) do for i, sn in ipairs(w.Sets or {}) do if sn == old then w.Sets[i] = new end end end end
    C.save(true); return true
end
function C.delete_set(name)
    C.settings.Sets[name] = nil
    for _, cd in pairs(C.settings.Characters) do for _, w in ipairs(cd.Windows or {}) do
        for i = #(w.Sets or {}), 1, -1 do if w.Sets[i] == name then table.remove(w.Sets, i) end end end end
    C.save(true)
end
function C.delete_button(key)
    C.settings.Buttons[key] = nil
    for _, set in pairs(C.settings.Sets) do for i, k in pairs(set) do if k == key then set[i] = nil end end end
    C.save(true)
end
-- ported "Remove All Duped Buttons" (Dev menu): buttons with identical Label+Cmd collapse into one key
function C.dedupe()
    local seen, map, n = {}, {}, 0
    for _, k in ipairs(C.buttons_sorted()) do
        local b = C.settings.Buttons[k]
        local sig = tostring(b.Label) .. '\1' .. tostring(b.Cmd)
        if seen[sig] then map[k] = seen[sig]; C.settings.Buttons[k] = nil; n = n + 1 else seen[sig] = k end
    end
    for _, set in pairs(C.settings.Sets) do for i, k in pairs(set) do if map[k] then set[i] = map[k] end end end
    C.save(true); return n
end
function C.export_button(b) return C.encode({ Type = 'Button', Button = clean(b) }) end
function C.export_set(name)
    local sh = { Type = 'Set', Key = name, Set = {}, Buttons = {} }
    for i, k in pairs(C.settings.Sets[name] or {}) do sh.Set[i] = k; sh.Buttons[k] = C.settings.Buttons[k] and clean(C.settings.Buttons[k]) end
    return C.encode(sh)
end
function C.import(text, win_id, set, idx)
    local ok, t = C.decode(text)
    if not ok then return false, t end
    if t.Type == 'Button' and type(t.Button) == 'table' then
        local k = C.gen_key(); C.settings.Buttons[k] = t.Button
        if set and idx then C.settings.Sets[set] = C.settings.Sets[set] or {}; C.settings.Sets[set][idx] = k end
        C.save(true); return true, 'Imported button "' .. tostring(t.Button.Label or k) .. '"'
    elseif t.Type == 'Set' then
        local name = tostring(t.Key or 'Imported')
        if C.settings.Sets[name] then name = name .. '_Imported_' .. os.date('%m-%d-%y-%H-%M-%S') end
        C.settings.Sets[name] = {}
        for i, bk in pairs(t.Set or {}) do
            local b = t.Buttons and t.Buttons[bk]
            if type(b) == 'table' then local k = C.gen_key(); C.settings.Buttons[k] = b; C.settings.Sets[name][i] = k end
        end
        if win_id and C.win(win_id) then table.insert(C.win(win_id).Sets, name) end
        C.save(true); return true, 'Imported set "' .. name .. '"'
    end
    return false, 'Unknown share type'
end
function C.preview_import(text)
    local ok, t = C.decode(text); if not ok then return nil end
    if t.Type == 'Button' then return 'Button: ' .. tostring(t.Button and t.Button.Label or '?') end
    if t.Type == 'Set' then local n = 0; for _ in pairs(t.Set or {}) do n = n + 1 end; return string.format('Set: %s (%d buttons)', tostring(t.Key), n) end
end
function C.copy_local(key)
    if not C.settings.Characters[key] then return false end
    C.settings.Characters[C.CharConfig] = C.deepcopy(C.settings.Characters[key]); C.save(true); return true
end
function C.other_chars() local t = {}; for k in pairs(C.settings.Characters) do if k ~= C.CharConfig then t[#t + 1] = k end end; table.sort(t); return t end

-- ---------------------------------------------------------------- Lua evaluation (ButtonMaster's run env)
function C.eval(str)
    local fn, err = load('mq = require(\'mq\')\n' .. tostring(str))
    if not fn then return false, err end
    return pcall(fn)
end

-- ---------------------------------------------------------------- label / cooldown / condition (cached, refreshed by the slicer)
function C.label(b, refresh)
    if b.CachedLabel and not refresh then return b.CachedLabel end
    local v = b.Label
    if b.EvaluateLabel then local ok, r = C.eval(b.Label); v = ok and r or b.Label end
    b.CachedLabel = tostring(v or '')
    return b.CachedLabel
end
function C.icon(b, refresh)
    if b.IconLua and b.IconLua ~= '' then
        if refresh or b.CachedIcon == nil then
            local ok, id, ty = C.eval(b.IconLua)
            if ok and id then b.CachedIcon, b.CachedIconType = id, ty else b.CachedIcon, b.CachedIconType = b.Icon or false, b.IconType end
        end
        return b.CachedIcon or nil, b.CachedIconType
    end
    return b.Icon, b.IconType
end
-- returns countdown seconds, total cooldown seconds, toggle-locked (same semantics as BMButtonHandlers.GetButtonCooldown)
function C.cooldown(b, refresh)
    if not refresh and b.CachedCountDown then return b.CachedCountDown, b.CachedCoolDownTimer, b.CachedToggleLocked end
    local cd, tot, lock = 0, 0, false
    local tt = b.TimerType
    if tt == 'Custom Lua' then
        if b.Timer and tostring(b.Timer) ~= '' then local ok, r = C.eval(b.Timer); cd = ok and tonumber(r) or 0 end
        if b.Cooldown and tostring(b.Cooldown) ~= '' then local ok, r = C.eval(b.Cooldown); tot = ok and tonumber(r) or 0 end
        if b.ToggleCheck and tostring(b.ToggleCheck) ~= '' then local ok, r = C.eval(b.ToggleCheck); lock = ok and r == true end
    elseif tt == 'Seconds Timer' then
        if b.CooldownTimer then
            cd = b.CooldownTimer - C.now()
            if cd <= 0 or cd > (tonumber(b.Cooldown) or 0) then b.CooldownTimer = nil; cd = 0 else tot = tonumber(b.Cooldown) or 0 end
        end
    elseif tt == 'Item' then
        cd = tlo(function() return mq.TLO.FindItem(b.Cooldown).TimerReady() end, 0) or 0
        tot = tlo(function() return mq.TLO.FindItem(b.Cooldown).Clicky.TimerID() end, 0) or 0
    elseif tt == 'Spell Gem' then
        cd = (tlo(function() return mq.TLO.Me.GemTimer(tonumber(b.Cooldown) or b.Cooldown)() end, 0) or 0) / 1000
        tot = (tlo(function() return mq.TLO.Me.Gem(tonumber(b.Cooldown) or b.Cooldown).RecastTime() end, 0) or 0) / 1000
    elseif tt == 'AA' then
        cd = (tlo(function() return mq.TLO.Me.AltAbilityTimer(b.Cooldown)() end, 0) or 0) / 1000
        tot = tlo(function() return mq.TLO.Me.AltAbility(b.Cooldown).MyReuseTime() end, 0) or 0
    elseif tt == 'Disc' then
        cd = tlo(function() return mq.TLO.Me.CombatAbilityTimer(b.Cooldown).TotalSeconds() end, 0) or 0
        tot = (tlo(function() return mq.TLO.Spell(b.Cooldown).RecastTime() end, 0) or 0) / 1000
    elseif tt == 'Ability' then
        cd = (tlo(function() return mq.TLO.Me.AbilityTimer(b.Cooldown)() end, 0) or 0) / 1000
        tot = (tlo(function() return mq.TLO.Me.AbilityTimerTotal(b.Cooldown)() end, 0) or 0) / 1000
    end
    b.CachedCountDown, b.CachedCoolDownTimer, b.CachedToggleLocked = tonumber(cd) or 0, tonumber(tot) or 0, lock
    b.CachedLastRan = C.now()
    return b.CachedCountDown, b.CachedCoolDownTimer, b.CachedToggleLocked
end
function C.cond(b, refresh)
    local fx = b.Rml and b.Rml.Cond
    if not fx or fx == '' then return false end
    if refresh or b.CachedCond == nil then local ok, r = C.eval(fx); b.CachedCond = ok and (r == true) end
    return b.CachedCond
end
function C.due(b)
    local r = tonumber(b.UpdateRate) or 0
    if r <= 0 then r = 0.25 end           -- "every frame" is honoured at 4 Hz with the slicer; Lua timers are the costly part
    return not b.CachedLastRan or C.now() - b.CachedLastRan >= r or C.now() < b.CachedLastRan
end

-- ---------------------------------------------------------------- execution (ported from BMButtonHandlers.Exec)
C.blocked = false                     -- set by the simulator test seam; also guards nothing else
function C.exec(b)
    if not b or not b.Cmd then return end
    if C.blocked then return end
    if not tostring(b.Cmd):find('^%-%-[ ]?lua') then
        for i, c in ipairs(C.split(b.Cmd, '\n')) do
            if #c > 0 and not c:find('^#') and not c:find('^%-+') and not c:find('^|') then
                if c:find('^/') then mq.cmd(c) else C.out('\arInvalid command on line %d: \ax%s', i, c) end
            end
        end
    else C.eval(b.Cmd) end
    if b.TimerType == 'Seconds Timer' then b.CooldownTimer = C.now() + (tonumber(b.Cooldown) or 0) end
    b.CachedLastRan = nil
end

-- ---------------------------------------------------------------- port-only button look (stored under Button.Rml so plain ButtonMaster ignores it)
C.EFFECTS = { 'glow', 'pulse', 'fire', 'frost', 'arcane', 'bolt', 'shine', 'pack', 'flash', 'bounce' }
C.EFFECT_NAMES = { glow = 'Glow', pulse = 'Pulse', fire = 'Fire ring', frost = 'Frost shards', arcane = 'Arcane swirl', bolt = 'Lightning', shine = 'Shine sweep', pack = 'Pack effect', flash = 'Ready flash', bounce = 'Press bounce' }
C.ANIMATED = { pack = true, pulse = true, fire = true, frost = true, arcane = true, bolt = true, shine = true }
C.FX_DEFCOL = { glow = 'ffb35a', pulse = 'ff7a2a', fire = 'ff8a2a', frost = '9fdcff', arcane = 'c28bff', bolt = 'a8c8ff', shine = 'ffffff', flash = 'fff2c0' }
-- pack effects: third-party sprite art (Kenney Particle Pack CC0, OpenGameArt CC0), one layer per button, Kind picks the art
C.PACK_KINDS = { 'blaze', 'frost', 'storm', 'crackle', 'runes', 'holy', 'poison', 'smoke', 'sparkle' }
C.PACK_NAMES = { blaze = 'Blaze', frost = 'Ice glints', storm = 'Storm orb', crackle = 'Crackle', runes = 'Rune circle', holy = 'Holy light', poison = 'Poison', smoke = 'Smoke', sparkle = 'Sparkles' }
C.PACK_COL = { blaze = 'ff8a3a', frost = '9fdcff', storm = 'ffffff', crackle = 'a8d8ff', runes = 'c28bff', holy = 'ffe9a8', poison = '8aff6a', smoke = 'c8beb4', sparkle = 'fff2c0' }
C.PACK_DESC = { blaze = 'Kenney fire wisps churning round the edge', frost = 'Glinting ice stars round the edge', storm = 'Animated lightning orb behind the icon (OpenGameArt)',
    crackle = 'Electric sparks flickering on the edge', runes = 'Two counter-rotating rune circles', holy = 'Breathing light rays with twinkles', poison = 'Toxic swirl with rising bubbles',
    smoke = 'Smoke puffs drifting up', sparkle = 'Magic sparkle burst (OpenGameArt)' }
function C.look(b)
    b.Rml = b.Rml or {}
    local r = b.Rml
    r.Shape = r.Shape or 'rounded'; r.Frame = r.Frame or 'metal'
    r.Fx = r.Fx or {}
    return r
end
function C.has_fx(b) local r = b and b.Rml; if not r or not r.Fx then return false end; for _, v in pairs(r.Fx) do if v.On then return true end end; return false end
function C.fx_animated(b) local r = b and b.Rml; if not r or not r.Fx then return false end; for k, v in pairs(r.Fx) do if v.On and C.ANIMATED[k] then return true end end; return false end
C.STYLE_KEYS = { 'Shape', 'Frame', 'Border', 'Bg1', 'Bg2', 'LabelPos', 'LabelSize', 'LabelColor', 'Fx' }
function C.copy_style(from, to)
    local f = C.look(from); local t = C.look(to)
    for _, k in ipairs(C.STYLE_KEYS) do t[k] = C.deepcopy(f[k]) end
end
C.PRESETS = {
    { name = 'Inferno', look = { Shape = 'rounded', Frame = 'metal', Border = 'ff8a3a', Bg1 = '5a1a08', Bg2 = '1a0604', LabelColor = 'ffe2b8', Fx = { fire = { On = true, Trig = 'ready', Int = 100, Col = 'ff8a2a' }, flash = { On = true, Col = 'fff2c0' }, bounce = { On = true } } } },
    { name = 'Glacier', look = { Shape = 'hex', Frame = 'gem', Border = '9fdcff', Bg1 = '12345a', Bg2 = '06101e', LabelColor = 'e6f6ff', Fx = { frost = { On = true, Trig = 'always', Int = 75, Col = '9fdcff' }, shine = { On = true, Trig = 'ready', Int = 50, Col = 'ffffff' } } } },
    { name = 'Arcane sigil', look = { Shape = 'round', Frame = 'rune', Border = 'c28bff', Bg1 = '3a1460', Bg2 = '0e0618', LabelColor = 'f0e2ff', Fx = { arcane = { On = true, Trig = 'always', Int = 100, Col = 'c28bff' }, glow = { On = true, Trig = 'hover', Int = 75, Col = 'c28bff' } } } },
    { name = 'Storm caller', look = { Shape = 'square', Frame = 'metal', Border = 'a8c8ff', Bg1 = '1c2850', Bg2 = '060a18', LabelColor = 'eef3ff', Fx = { bolt = { On = true, Trig = 'cooldown', Int = 100, Col = 'a8c8ff' }, flash = { On = true, Col = 'dfe9ff' } } } },
    { name = 'Holy light', look = { Shape = 'rounded', Frame = 'gem', Border = 'ffe08a', Bg1 = '6a5014', Bg2 = '1e1404', LabelColor = 'fff6d8', Fx = { pulse = { On = true, Trig = 'ready', Int = 75, Col = 'ffe08a' }, shine = { On = true, Trig = 'always', Int = 50, Col = 'ffffff' } } } },
    { name = 'Clean', look = { Shape = 'rounded', Frame = 'plain', Border = '8a7a70', Bg1 = '2a2422', Bg2 = '121010', LabelColor = 'f2e6dc', Fx = {} } },
}
function C.apply_preset(b, p) local t = C.look(b); for k, v in pairs(p.look) do t[k] = C.deepcopy(v) end end
return C
