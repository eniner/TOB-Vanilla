-- combatfx core: diffed window proxy (0 idle writes), windows, settings (per character), shared themes file.
local mq = require('mq')
local rmlui = require('rmlui')
local C = { wins = {}, order = {}, writes = 0 }
C.TAG = '\a-o[combatfx]\ax '

function C.safe(fn) local ok, v = pcall(fn); if ok then return v end; return nil end
function C.num(fn, d) local v = tonumber(C.safe(fn)); if v == nil then return d end; return v end
function C.str(fn, d) local v = C.safe(fn); if v == nil or v == 'NULL' then return d end; return tostring(v) end
function C.now() return mq.gettime() end
-- run fn safely; an error is logged to MQ chat once per name (never spammed, never stops the caller)
C.errs = {}
function C.guard(name, fn, ...)
    local ok, e = pcall(fn, ...)
    if not ok and not C.errs[name] then C.errs[name] = true; print(C.TAG .. '\arerror in ' .. name .. ':\ax ' .. tostring(e)) end
    return ok
end
function C.esc(s) return (tostring(s == nil and '' or s):gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'):gsub('"', '&quot;')) end
function C.clamp(v, a, b) return math.max(a, math.min(b, v)) end
function C.screen()
    local ok, sz = pcall(function() return ImGui.GetIO().DisplaySize end)
    if ok and sz and sz.x and sz.x > 0 then return math.floor(sz.x), math.floor(sz.y) end
    return 1920, 1080
end
-- MQ's ImGui binding returns two numbers (x, y); some builds return an ImVec2. Accept both.
function C.mouse()
    local ok, x, y = pcall(function()
        local a, b = ImGui.GetMousePos()
        if type(a) == 'number' then return a, b end
        if a ~= nil then return a.x, a.y end
    end)
    if ok and type(x) == 'number' and type(y) == 'number' then return math.floor(x), math.floor(y) end
end

-- ---------------------------------------------------------------- diffed proxy
local W = {}; W.__index = W
local function put(self, k, v, fn) if self.cache[k] == v then return false end; self.cache[k] = v; C.writes = C.writes + 1; pcall(fn); return true end
function W:text(id, v) v = tostring(v == nil and '' or v); return put(self, 't' .. id, v, function() self.win:text(id, v) end) end
function W:rml(id, v) v = tostring(v or ''); return put(self, 'r' .. id, v, function() self.win:rml(id, v) end) end
function W:style(id, p, v) v = tostring(v); return put(self, 's' .. id .. '|' .. p, v, function() self.win:style(id, p, v) end) end
function W:class(id, c, on) on = on and true or false; return put(self, 'c' .. id .. '|' .. c, on, function() self.win:class(id, c, on) end) end
function W:attr(id, n, v) return put(self, 'a' .. id .. '|' .. n, v == nil and '\0' or tostring(v), function() self.win:attr(id, n, v) end) end
-- restart a one-shot animation: alternate the _a/_b twin keyframes (identical content), one style write
function W:anim(id, name, dur, ease)
    local k = 'an' .. id
    local s = (self.cache[k] == 'a') and 'b' or 'a'; self.cache[k] = s
    self:style(id, 'animation', string.format('%.2fs %s 1 %s_%s', dur, ease or 'cubic-out', name, s))
end
function W:show(on) on = on ~= false; if self.visible == on then return end; self.visible = on; C.writes = C.writes + 1; pcall(function() self.win:show(on) end) end
function W:place(x, y, w, h) C.writes = C.writes + 1; pcall(function() self.win:place(x, y, w, h) end) end
function W:value(id) return C.str(function() return self.win:value(id) end, '') end

function C.open(spec)
    local win, err = rmlui.open('CombatFx' .. spec.key, 'combatfx/ui/' .. spec.doc, {
        width = spec.w, height = spec.h, x = spec.x, y = spec.y, clickthrough = spec.clickthrough, theme = false })
    if not win then print(C.TAG .. 'could not open ' .. spec.doc .. ': ' .. tostring(err)); return nil end
    pcall(function() win:reload() end)                       -- plugin caches docs across restarts
    -- x/y in open() is the first-run default; afterwards the plugin-remembered position is kept (place -1,-1)
    local sx, sy = C.saved_pos(spec.key)
    if sx and not spec.force_pos then pcall(function() win:place(sx, sy, spec.w, spec.h) end)     -- per-character spot (patched DLL saved it)
    elseif spec.force_pos then pcall(function() win:place(spec.x, spec.y, spec.w, spec.h) end)
    else pcall(function() win:place(-1, -1, spec.w, spec.h) end) end
    local p = setmetatable({ win = win, cache = {}, spec = spec, visible = true, opened = C.now(),
        rect = (spec.force_pos and { spec.x, spec.y }) or (sx and { sx, sy }) or nil }, W)
    C.wins[spec.key] = p; C.order[#C.order + 1] = p
    if spec.hidden then p:show(false) end
    return p
end
-- ---------------------------------------------------------------- window positions (drag="1" title bars)
-- The plugin drags windows natively. An optional patched DLL (feature bit 256) also reports the result:
-- 'windowmoved' events (value "x,y,w,h") and rml_get_window(name) -> "x,y,w,h". With it, spots are saved
-- per character (cfg pos.<Key>); without it the plugin's own ImGui memory keeps them (all characters).
local wl, wl_tried
local function wlib()
    if wl_tried then return wl end
    wl_tried = true
    pcall(function()
        local ffi = require('ffi')
        pcall(ffi.cdef, 'int rml_features(void);')
        local l = ffi.load('MQ2RmlUi')
        local f = tonumber(l.rml_features()) or 0
        if math.floor(f / 256) % 2 == 1 then pcall(ffi.cdef, 'const char* rml_get_window(const char* name);'); wl = { l = l, ffi = ffi } end
    end)
    return wl
end
function C.parse_rect(v)
    local x, y, w, h = tostring(v or ''):match('^%s*(%-?[%d%.]+),(%-?[%d%.]+),?(%-?[%d%.]*),?(%-?[%d%.]*)')
    if x then return math.floor(tonumber(x)), math.floor(tonumber(y)), tonumber(w), tonumber(h) end
end
function C.saved_pos(key)
    local x, y = C.parse_rect(C.cfg.pos and C.cfg.pos[key])
    if not x then return nil end
    local sw, sh = C.screen()
    return C.clamp(x, 0, math.max(0, sw - 40)), C.clamp(y, 0, math.max(0, sh - 30))
end
function C.store_pos(key, x, y)
    if not key or not x then return end
    local v = string.format('%d,%d', x, y)
    if C.cfg.pos[key] ~= v then C.cfg.pos[key] = v; C.save_cfg() end
end
function C.get_rect(p)
    if C.get_rect_hook then return C.get_rect_hook(p) end   -- test seam
    local w = wlib(); if not w or not p then return nil end
    local ok, s = pcall(function() local r = w.l.rml_get_window('CombatFx' .. p.spec.key); if r ~= nil then return w.ffi.string(r) end end)
    if ok and s then return C.parse_rect(s) end
end
-- called on shutdown: read final spots once (patched DLL only), never per frame
function C.capture_positions()
    for _, p in ipairs(C.order) do
        if not p.spec.force_pos then local x, y = C.get_rect(p); if x then C.store_pos(p.spec.key, x, y) end end
    end
end
-- Floating buttons (spec.dragclick): the plugin only starts a drag on a drag="1" element without an action,
-- and it still reports a left click on release. A press that moved the window is a drag, not a click.
function C.dragclick(p, list)
    local moved = false
    for _, ev in ipairs(list) do
        if ev.type == 'windowmoved' then
            local x, y = C.parse_rect(ev.value)
            if x then
                local r = p.rect
                if r and (math.abs(x - r[1]) > 3 or math.abs(y - r[2]) > 3) then moved = true end
                p.rect = { x, y }
            end
        end
    end
    if not moved then return list end
    local out = {}
    for _, ev in ipairs(list) do
        if not (ev.type == 'click' and (tonumber(ev.button) or 0) == 0) then out[#out + 1] = ev end
    end
    return out
end
function C.poll()
    for _, p in ipairs(C.order) do
        if p.spec.dragclick and not p.rect_try and C.now() - (p.opened or 0) > 500 then
            -- one-shot (not per frame): where the button sits before any drag, so the first drag is recognised
            p.rect_try = true
            if not p.rect then local x, y = C.get_rect(p); if x then p.rect = { x, y } end end
        end
        local ok, it = pcall(function() return p.win:events() end)
        if ok and it then
            local list = {}
            for ev in it do list[#list + 1] = ev end
            if p.spec.dragclick then list = C.dragclick(p, list) end
            for _, ev in ipairs(list) do
              if ev.type == 'windowmoved' then
                local x, y = C.parse_rect(ev.value)
                if x and not p.spec.force_pos then C.store_pos(p.spec.key, x, y) end
              else
                if (ev.action == nil or ev.action == '') and type(ev.id) == 'string' and ev.id:sub(1, 2) == 'a-' then ev.action = ev.id:sub(3) end
                if p.spec.on_event then local ok2, e = pcall(p.spec.on_event, ev, p); if not ok2 then print(C.TAG .. 'event: ' .. tostring(e)) end end
              end
            end
        end
    end
end
function C.close_all() for _, p in ipairs(C.order) do pcall(function() p.win:close() end) end; C.order, C.wins = {}, {} end

-- ---------------------------------------------------------------- settings
C.KINDS = { 'melee', 'spell', 'dot', 'crit', 'incoming', 'healin', 'healout', 'miss', 'resist', 'kill', 'proc', 'pet', 'group' }
C.KIND_LABEL = { melee = 'Melee (out)', spell = 'Spell (out)', dot = 'DoT ticks', crit = 'Crits', incoming = 'Damage taken', healin = 'Heals received', healout = 'Heals cast', miss = 'Miss / parry / dodge', resist = 'Resists', kill = 'Kill text', proc = 'Skill callouts', pet = 'Pet damage', group = 'Group hits' }
C.FX = { 'numbers', 'healfx', 'dmgfx', 'vignette', 'critflash', 'burst', 'killbanner', 'combatbanner', 'shake', 'streak',
    'bighit', 'procs', 'pet', 'buffwarn', 'ready', 'ccbreak', 'group', 'recap', 'livemeter', 'stamps', 'resisttype', 'death', 'castbar', 'dx11', 'dx11_glow', 'dx11_particles', 'dx11_shockwave', 'dx11_trails', 'dx11_heartbeat' }
C.FX_LABEL = { numbers = 'Floating numbers', healfx = 'Heal glow + particles', dmgfx = 'Damage edge flash', vignette = 'Low-HP vignette', critflash = 'Crit screen flash', burst = 'Cast-landing burst', killbanner = 'Slain banner', combatbanner = 'Combat start/end banner', shake = 'Target plate + hit shake', streak = 'Streak / combo counter',
    bighit = 'Big-hit stamps + record', procs = 'Skill / proc callouts', pet = 'Pet damage numbers', buffwarn = 'Buff fading warnings', ready = 'Spell ready pings', ccbreak = 'Mez break + aggro alerts',
    group = 'Group danger alerts', recap = 'Fight recap card', livemeter = 'In-combat DPS meter', stamps = 'Named / level / AA stamps', resisttype = 'Resist type on resists', death = 'Death screen', castbar = 'Cast bar', dx11 = 'DX11 effects', dx11_glow = 'DX11 bloom glow', dx11_particles = 'DX11 particle bursts', dx11_shockwave = 'DX11 shockwave rings', dx11_trails = 'DX11 particle trails', dx11_heartbeat = 'DX11 heartbeat vignette' }
C.THEMES = {
    ['Classic EQ'] = { melee = '#ffffff', spell = '#8ac8ff', dot = '#c8a0ff', crit = '#ffd040', incoming = '#ff5a4a', healin = '#6aff8a', healout = '#40e0a0', miss = '#a0a8b8', resist = '#d090ff', kill = '#ffe08a', style = 'bold', motion = 'rise', size = 22 , proc = '#ff9a40', pet = '#c0c8a0' },
    ['Neon'] = { melee = '#00f0ff', spell = '#ff40ff', dot = '#b060ff', crit = '#fff200', incoming = '#ff2060', healin = '#40ff80', healout = '#00ffb0', miss = '#80a0c0', resist = '#ff80ff', kill = '#fff200', style = 'heavy', motion = 'arc', size = 24 , proc = '#ff8000', pet = '#80ff40' },
    ['Minimal'] = { melee = '#e0e0e0', spell = '#b0d0ff', dot = '#b0b0d0', crit = '#ffffff', incoming = '#ff8080', healin = '#a0ffb0', healout = '#a0e0c0', miss = '#808080', resist = '#c0a0e0', kill = '#ffffff', style = 'normal', motion = 'static', size = 18 , proc = '#e0c080', pet = '#c0c0c0' },
    ['Blood'] = { melee = '#ffd0d0', spell = '#ff6a3a', dot = '#c03030', crit = '#ff2020', incoming = '#a00000', healin = '#ff9090', healout = '#ffb0b0', miss = '#806060', resist = '#ff6080', kill = '#ff3030', style = 'heavy', motion = 'fountain', size = 24 , proc = '#ff7040', pet = '#d08080' },
    ['Holy'] = { melee = '#fff8e0', spell = '#ffe890', dot = '#e0d0a0', crit = '#ffffff', incoming = '#ffa070', healin = '#fff070', healout = '#ffffa0', miss = '#c0b8a0', resist = '#e0c0ff', kill = '#ffd700', style = 'shadow', motion = 'rise', size = 22 , proc = '#ffc860', pet = '#e8e0b0' },
}
C.THEME_ORDER = { 'Classic EQ', 'Neon', 'Minimal', 'Blood', 'Holy' }
-- f8: group members' hits get a quieter version of the theme's melee colour (themes saved before f8 have no 'group')
function C.derive_group(melee)
    local r, g, b = tostring(melee or ''):match('^#(%x%x)(%x%x)(%x%x)')
    if not r then return '#b8c4d8' end
    local function m(a, t) return math.floor(tonumber(a, 16) * 0.62 + t * 0.38 + 0.5) end
    return string.format('#%02x%02x%02x', m(r, 0x90), m(g, 0xa4), m(b, 0xc8))
end
for _, t in pairs(C.THEMES) do if not t.group then t.group = C.derive_group(t.melee) end end
C.cfg = {
    master = true, size = 22, style = 'bold', motion = 'rise', dur = 1.3, max = 24, fmt = 'short', intensity = 80, edge = 70,
    lite = false, particles = true, theme = 'Classic EQ', meter = true, launcher_x = '', launcher_y = '', sim_eps = 6, sim_power = 1.0, sim_loop = false,
    xp = false, loot = false,
    rec = { best = 0 },                                            -- per-character records (best single hit)
    on = {}, fx = {}, color = {}, pos = {},
    tt = {}, tc = {}, ts = {},                                     -- per-lane text effect: type, colour, size
}
for _, k in ipairs(C.KINDS) do C.cfg.on[k] = true; C.cfg.color[k] = C.THEMES['Classic EQ'][k] end
for _, k in ipairs(C.FX) do C.cfg.fx[k] = true end
-- 'Particle effects' master: false = no element/screen particles (proc/crit bursts, kill/heal/flare/death sparks,
-- the DOM heal motes and resist burst, DX11 number particles/sparks/shatter). Numbers, glow, outline and punch stay.
function C.particles_on()
    if C.cfg.particles == false then return false end
    local F = package.loaded['combatfx.features']          -- f8: performance tier 'Low' pauses particles (runtime only)
    if F and F.tier and F.tier() >= 2 then return false end
    return true
end
C.FX_STYLES = {
    { id = 'auto',    label = 'Auto',      desc = 'Follows the proc element' },
    { id = 'inferno', label = 'Fire',      desc = 'Flames and rising embers' },
    { id = 'frost',   label = 'Frost',     desc = 'Ice shards and frost' },
    { id = 'toxic',   label = 'Poison',    desc = 'Bubbles, drips and gas' },
    { id = 'disease', label = 'Disease',   desc = 'Spores and swarming specks' },
    { id = 'arcane',  label = 'Arcane',    desc = 'Rune circle and motes' },
    { id = 'storm',   label = 'Lightning', desc = 'Branching bolts' },
    { id = 'shadow',  label = 'Shadow',    desc = 'Void and inward tendrils' },
    { id = 'holy',    label = 'Holy',      desc = 'Light rays and a halo' },
    { id = 'blood',   label = 'Blood',     desc = 'Directional splatter' },
    { id = 'wind',    label = 'Wind',      desc = 'Spiral gusts and leaves' },
    { id = 'water',   label = 'Water',     desc = 'Splash crown and droplets' },
    { id = 'earth',   label = 'Earth',     desc = 'Rocks, dust and a ground crack' },
}
C.cfg.fxstyle = {
    proc = 'auto', crit = 'auto', size = 100, intensity = 100, duration = 100,
    color_mode = 'element', color = '#ffd040', scope = 'procs',
}
C.cfg.feetaura = { on = true, style = 'inferno' }
C.cfg.naura = { id = 0, prev = 0 }                 -- t436: native EQ ground aura id (0 = none; old feet disc is used)
C.AURA_SHOWPIECES = {
    { id = 'sigil',    label = 'Sigil',    desc = 'Rotating rune rings and rising motes' },
    { id = 'magma',    label = 'Magma',    desc = 'Lava fissures and ember columns' },
    { id = 'tempest',  label = 'Tempest',  desc = 'Crawling lightning on a storm disc' },
    { id = 'nebula',   label = 'Nebula',   desc = 'Void swirl with a violet rim' },
    { id = 'radiance', label = 'Radiance', desc = 'Holy disc and light pillars' },
    { id = 'hexfrost', label = 'Hexfrost', desc = 'Frozen lattice and rim shards' },
    { id = 'miasma',   label = 'Miasma',   desc = 'Toxic pool, bubbles and spores' },
    { id = 'ritual',   label = 'Ritual',   desc = 'Blood sigil with a dripping pulse' },
}
C.cfg.runtrail = { on = true, style = 'inferno' }
C.BODY_STYLES = {
    { id = 'inferno', label = 'Inferno', desc = 'Flames rising beside you, not over you' },
    { id = 'frost',   label = 'Frost',   desc = 'Mist and ice glints along your outline' },
    { id = 'storm',   label = 'Storm',   desc = 'Lightning arcs wrapping the silhouette' },
    { id = 'holy',    label = 'Holy',    desc = 'Golden rim, side motes, halo above the head' },
    { id = 'void',    label = 'Void',    desc = 'Violet smoke curling around the edges' },
    { id = 'toxic',   label = 'Toxic',   desc = 'Vapor and bubbles rising beside you' },
    { id = 'arcane',  label = 'Arcane',  desc = 'Runes orbiting the silhouette' },
    { id = 'blood',   label = 'Blood',   desc = 'Crimson rim mist and drips down the outline' },
}
C.cfg.bodyfx = { on = true, style = 'inferno', size = 100, intensity = 80,
    native = 0, nfav = '', overlay = false }      -- t362: native EQ nimbus id (0 = none), favourites, old overlay glow opt-in
C.MARKER_ICONS = {
    { id = 'skull',        label = 'Skull' },
    { id = 'star',         label = 'Star' },
    { id = 'crosshair',    label = 'Crosshair' },
    { id = 'diamond',      label = 'Diamond' },
    { id = 'exclamation',  label = 'Alert' },
    { id = 'crown',        label = 'Crown' },
    { id = 'shield',       label = 'Shield' },
    { id = 'flame',        label = 'Flame' },
}
C.MARKER_STYLE = {
    { id = 'icon', label = 'Head icon' },
    { id = 'beam', label = 'Light beam' },
    { id = 'both', label = 'Both' },
}
C.MARKER_COLORS = { '#ffd040', '#ff5a4a', '#ff9a40', '#8ac8ff', '#6aff8a', '#d090ff', '#00f0ff', '#ffffff' }
C.cfg.markers = { on = true, import_pf = false, pack = '' }

local function mk_sanitize(s)
    s = tostring(s or ''):gsub('[|;]', ' '):gsub('\r', ' '):gsub('\n', ' ')
    s = s:match('^%s*(.-)%s*$') or ''
    return s
end
function C.marker_pack(rules)
    local enc = {}
    for _, r in ipairs(rules or {}) do
        local match = (r.match == 'pattern') and 'pattern' or 'exact'
        local style = r.style
        if style ~= 'icon' and style ~= 'beam' then style = 'both' end
        local color = tostring(r.color or '#ffd040')
        if not color:match('^#%x%x%x%x%x%x$') then color = '#ffd040' end
        local icon = mk_sanitize(r.icon or 'skull')
        if icon == '' then icon = 'skull' end
        enc[#enc + 1] = table.concat({ match, mk_sanitize(r.name), style, color, icon }, '|')
    end
    return table.concat(enc, ';')
end
function C.marker_unpack(pack)
    local out = {}
    for part in tostring(pack or ''):gmatch('[^;]+') do
        local match, name, style, color, icon = part:match('^([^|]+)|([^|]*)|([^|]+)|([^|]+)|([^|]+)$')
        if name and name ~= '' then
            if match ~= 'pattern' then match = 'exact' end
            if style ~= 'icon' and style ~= 'beam' then style = 'both' end
            if not tostring(color):match('^#%x%x%x%x%x%x$') then color = '#ffd040' end
            out[#out + 1] = { match = match, name = name, style = style, color = color, icon = icon }
        end
    end
    return out
end
function C.marker_rules()
    return C.marker_unpack(C.cfg.markers and C.cfg.markers.pack or '')
end
function C.set_marker_rules(list)
    if not C.cfg.markers then C.cfg.markers = { on = true, import_pf = false, pack = '' } end
    C.cfg.markers.pack = C.marker_pack(list)
end
function C.marker_name_matches(rule, name)
    if not rule then return false end
    local needle = mk_sanitize(rule.name):lower()
    local hay = tostring(name or ''):lower()
    if needle == '' or hay == '' then return false end
    if (rule.match or 'exact') == 'exact' then return hay == needle end
    return hay:find(needle, 1, true) ~= nil
end
function C.marker_rule_for(name, rules)
    for _, r in ipairs(rules or {}) do
        if C.marker_name_matches(r, name) then return r end
    end
end
function C.hex_rgb(c)
    local r, g, b = tostring(c or ''):match('#?(%x%x)(%x%x)(%x%x)')
    if not r then return 1.00, 0.82, 0.25 end
    return tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255
end
function C.pf_query_to_name(q)
    q = mk_sanitize(q)
    if q == '' then return nil end
    local quoted = q:match('"([^"]+)"')
    if quoted and quoted:match('%S') then return quoted end
    local low = q:lower()
    if low == 'npc' or low == 'npc targetable' or low == 'targetable'
        or low == 'npc named' or low == 'named' or low == 'npc los' then
        return nil
    end
    local rest = q:gsub('^[Nn][Pp][Cc]%s+', '')
    rest = rest:gsub('^[Tt]argetable%s+', '')
    rest = rest:gsub('^[Nn]amed%s+', '')
    rest = mk_sanitize(rest)
    local rl = rest:lower()
    if rest == '' or rl == 'targetable' or rl == 'named' then return nil end
    if rl:match('^radius') or rl:match('^id%s') or rl:match('^loc%s') or rl:match('zradius') or rl:match('alert') then
        return nil
    end
    if rest:match('%a') then return rest end
    return nil
end
function C.parse_pf_watch(json, zone)
    local names, seen = {}, {}
    for z, inner in tostring(json or ''):gmatch('"([^"]+)":%s*%[(.-)%]') do
        if (not zone) or z == zone then
            for q in inner:gmatch('"([^"]+)"') do
                local n = C.pf_query_to_name(q)
                if n and not seen[n:lower()] then
                    seen[n:lower()] = true
                    names[#names + 1] = n
                end
            end
        end
    end
    return names
end
function C.parse_pf_pull(s)
    s = tostring(s or ''):gsub('\r', ''):gsub('\n', '')
    local trimmed = s:match('^%s*(.-)%s*$') or ''
    local low = trimmed:lower()
    if trimmed == '' or low == 'all' or low == 'none' or low == 'null' then return {} end
    local out, seen = {}, {}
    for entry in trimmed:gmatch('[^|]+') do
        entry = mk_sanitize(entry)
        local k = entry:lower()
        if entry ~= '' and k ~= 'all' and k ~= 'none' and not seen[k] then
            seen[k] = true
            out[#out + 1] = entry
        end
    end
    return out
end
function C.marker_pf_watch_queries(zone)
    if C._debug_pf_watch_json then return C.parse_pf_watch(C._debug_pf_watch_json, zone) end
    zone = zone or C.str(function() return mq.TLO.Zone.ShortName() end, '')
    local path = (mq.luaDir or '.') .. '/PocketFarm_watchlist.json'
    local f = io.open(path, 'r'); if not f then return {} end
    local content = f:read('*a'); f:close()
    return C.parse_pf_watch(content, zone)
end
function C.marker_pf_pull_names(zone)
    if C._debug_pf_pull ~= nil then return C.parse_pf_pull(C._debug_pf_pull) end
    zone = zone or C.str(function() return mq.TLO.Zone.ShortName() end, '')
    local val = C.str(function() return mq.TLO.Ini('PocketFarm.ini', zone, 'Pull')() end, '')
    if val == '' then
        local path = (mq.configDir or '.') .. '/PocketFarm.ini'
        local f = io.open(path, 'r')
        if f then
            local cur
            for line in f:lines() do
                local sec = line:match('^%[(.+)%]%s*$')
                if sec then cur = sec
                elseif cur == zone then
                    local v = line:match('^[Pp]ull=(.*)$')
                    if v then val = v; break end
                end
            end
            f:close()
        end
    end
    return C.parse_pf_pull(val)
end
function C.marker_imported_rules(zone)
    if not (C.cfg.markers and C.cfg.markers.import_pf) then return {} end
    local out, seen = {}, {}
    local function add(name, match)
        name = mk_sanitize(name)
        if name == '' then return end
        local k = name:lower()
        if seen[k] then return end
        seen[k] = true
        out[#out + 1] = { match = match, name = name, style = 'both', color = '#ffd040', icon = 'star', imported = true }
    end
    for _, n in ipairs(C.marker_pf_watch_queries(zone)) do add(n, 'pattern') end
    for _, n in ipairs(C.marker_pf_pull_names(zone)) do add(n, 'exact') end
    return out
end
function C.marker_all_rules(zone)
    local all = {}
    for _, r in ipairs(C.marker_rules()) do all[#all + 1] = r end
    for _, r in ipairs(C.marker_imported_rules(zone)) do all[#all + 1] = r end
    return all
end
function C.marker_custom_list()
    if C._debug_custom_icons then
        local t = {}
        for i, n in ipairs(C._debug_custom_icons) do t[i] = n end
        return t
    end
    local dir
    if mq.luaDir and mq.luaDir ~= '' then dir = mq.luaDir .. '/combatfx/img/markers_custom'
    else dir = (mq.configDir or '.') .. '/../lua/combatfx/img/markers_custom' end
    local out = {}
    local ok, lfs = pcall(require, 'lfs')
    if ok and lfs then
        pcall(function()
            for f in lfs.dir(dir) do
                local stem = f:match('^(.+)%.[Pp][Nn][Gg]$')
                if stem then out[#out + 1] = stem end
            end
        end)
    end
    table.sort(out)
    return out
end
-- ---------------------------------------------------------------- per-lane text effects (RmlUi font-effect, static: set once per pop)
C.TFX_TYPES = { { 'style', 'Default' }, { 'outline', 'Outline' }, { 'glow', 'Glow' }, { 'shadow', 'Shadow' }, { 'outline+glow', 'Outline + glow' }, { 'outline+shadow', 'Outline + shadow' } }
C.TFX_DEFAULT = { crit = { 'outline+glow', '#ffd040', 4 }, incoming = { 'outline+shadow', '#a00000', 3 }, kill = { 'outline+glow', '#ffe08a', 3 } }
for _, k in ipairs(C.KINDS) do
    local d = C.TFX_DEFAULT[k] or { 'outline', '#000000', 2 }
    C.cfg.tt[k], C.cfg.tc[k], C.cfg.ts[k] = d[1], d[2], d[3]
end
C.STYLE_FE = { bold = 'outline(2px #000000)', normal = 'outline(1px #000000)', heavy = 'outline(3px #000000)', shadow = 'shadow(2px 2px #000000)' }
function C.font_effect(kind)
    local cfg = C.cfg
    local base = C.STYLE_FE[cfg.style] or C.STYLE_FE.bold
    local t = cfg.tt[kind] or 'style'
    if cfg.lite or t == 'style' then return base end
    local col, n = cfg.tc[kind] or '#000000', math.floor(C.clamp(tonumber(cfg.ts[kind]) or 2, 1, 6))
    local function glow() return string.format('glow(1px %dpx 0px 0px %s)', n * 2, col) end
    local function shadow() return string.format('shadow(%dpx %dpx %s)', n, n, col) end
    if t == 'outline' then return string.format('outline(%dpx %s)', n, col) end
    if t == 'glow' then return glow() end
    if t == 'shadow' then return shadow() end
    if t == 'outline+glow' then return 'outline(2px #000000), ' .. glow() end
    if t == 'outline+shadow' then return 'outline(2px #000000), ' .. shadow() end
    return base
end

local server = C.str(function() return mq.TLO.EverQuest.Server() end, 'server'):gsub('[^%w]', '')
local me = C.str(function() return mq.TLO.Me.CleanName() end, 'char')
C.CHAR = me
C.CFG_PATH = string.format('%s/combatfx_%s_%s.ini', mq.configDir or '.', server, me)
C.THEMES_PATH = (mq.configDir or '.') .. '/combatfx_themes.ini'

local function ser(t)
    local o = {}
    for k, v in pairs(t) do
        if type(v) == 'table' then for k2, v2 in pairs(v) do o[#o + 1] = k .. '.' .. k2 .. '=' .. tostring(v2) end
        else o[#o + 1] = k .. '=' .. tostring(v) end
    end
    table.sort(o); return o
end
local function apply_kv(t, k, v)
    local a, b = k:match('^([%w_]+)%.([%w_]+)$')
    local function conv(old, s) if type(old) == 'boolean' then return s == 'true' elseif type(old) == 'number' then return tonumber(s) or old end; return s end
    if a then if type(t[a]) == 'table' then t[a][b] = conv(t[a][b], v) end
    elseif t[k] ~= nil and type(t[k]) ~= 'table' then t[k] = conv(t[k], v) end
end
C.ser_cfg, C.apply_kv = ser, apply_kv                         -- f8b: loadouts snapshot / restore whole setups
function C.load_cfg()
    local f = io.open(C.CFG_PATH, 'r'); if not f then return false end
    for l in f:lines() do local k, v = l:match('^([%w%._]+)=(.*)$'); if k then apply_kv(C.cfg, k, v) end end
    f:close(); return true
end
local dirty_at
function C.save_cfg_now()
    local f = io.open(C.CFG_PATH, 'w'); if not f then return end
    f:write('[combatfx]\n'); for _, l in ipairs(ser(C.cfg)) do f:write(l, '\n') end; f:close(); dirty_at = nil
end
function C.save_cfg() dirty_at = C.now() + 800 end            -- debounced: steppers don't hammer the disk
function C.save_tick() if dirty_at and C.now() >= dirty_at then C.save_cfg_now() end end

-- ---------------------------------------------------------------- themes (shareable ini: [Theme Name] key=value)
local THEME_KEYS = { 'size', 'style', 'motion', 'dur', 'intensity', 'edge' }
function C.theme_snapshot()
    local t = {}
    for _, k in ipairs(C.KINDS) do t[k] = C.cfg.color[k]; t['tt' .. k] = C.cfg.tt[k]; t['tc' .. k] = C.cfg.tc[k]; t['ts' .. k] = C.cfg.ts[k] end
    for _, k in ipairs(THEME_KEYS) do t[k] = C.cfg[k] end
    -- DX11 look (TextFX): shader style, motion, particles, crit impact, combo, bloom as x<key>=value
    local ok, T = pcall(require, 'combatfx.themefx'); if ok and T and T.snapshot then T.snapshot(t) end
    return t
end
function C.apply_theme(t, name)
    for _, k in ipairs(C.KINDS) do
        if t[k] then C.cfg.color[k] = t[k] end
        if t['tt' .. k] then C.cfg.tt[k] = t['tt' .. k] end
        if t['tc' .. k] then C.cfg.tc[k] = t['tc' .. k] end
        if t['ts' .. k] then C.cfg.ts[k] = tonumber(t['ts' .. k]) or C.cfg.ts[k] end
    end
    for _, k in ipairs(THEME_KEYS) do if t[k] ~= nil then C.cfg[k] = tonumber(t[k]) or t[k] end end
    -- old sections (no x-keys) still load: they get the matching built-in look
    local ok, T = pcall(require, 'combatfx.themefx'); if ok and T and T.apply then pcall(T.apply, t, name) end
    C.cfg.theme = name or 'Custom'; C.save_cfg()
end
local function read_ini(path)
    local out, order, cur = {}, {}, nil
    local f = io.open(path, 'r'); if not f then return out, order end
    for l in f:lines() do
        local s = l:match('^%[(.+)%]%s*$')
        if s then cur = s; if not out[s] then out[s] = {}; order[#order + 1] = s end
        elseif cur then local k, v = l:match('^(%w+)=(.*)$'); if k then out[cur][k] = v end end
    end
    f:close(); return out, order
end
function C.saved_themes()
    local t, order = read_ini(C.THEMES_PATH)
    -- single-theme share files dropped into config: combatfx_theme_<name>.ini
    local ok, lfs = pcall(require, 'lfs')
    if ok and lfs then
        pcall(function()
            for f in lfs.dir(mq.configDir) do
                if f:match('^combatfx_theme_.+%.ini$') then
                    local one, o2 = read_ini(mq.configDir .. '/' .. f)
                    -- f8: files from other people are whitelisted key by key (same validator as share strings)
                    local okF, F = pcall(require, 'combatfx.features')
                    for _, n in ipairs(o2) do
                        if not t[n] then t[n] = (okF and F.clean_section) and (F.clean_section(one[n])) or one[n]; order[#order + 1] = n end
                    end
                end
            end
        end)
    end
    return t, order
end
local function write_section(f, name, snap)
    f:write('[', name, ']\n')
    local ks = {}; for k in pairs(snap) do ks[#ks + 1] = k end; table.sort(ks)
    for _, k in ipairs(ks) do f:write(k, '=', tostring(snap[k]), '\n') end
end
function C.save_theme(name)
    name = tostring(name or ''):gsub('[%[%]\r\n]', ''):gsub('^%s+', ''):gsub('%s+$', '')
    if name == '' then return false, 'enter a name' end
    local t, order = read_ini(C.THEMES_PATH)
    if not t[name] then order[#order + 1] = name end
    t[name] = C.theme_snapshot()
    local f = io.open(C.THEMES_PATH, 'w'); if not f then return false, 'cannot write ' .. C.THEMES_PATH end
    for _, n in ipairs(order) do write_section(f, n, t[n]) end
    f:close(); C.cfg.theme = name; C.save_cfg()
    return true, name
end
function C.export_theme(name)
    local safe = tostring(name or 'Custom'):gsub('[^%w%-_]', '_')
    local path = string.format('%s/combatfx_theme_%s.ini', mq.configDir or '.', safe)
    local f = io.open(path, 'w'); if not f then return false, path end
    write_section(f, name, C.theme_snapshot()); f:close()
    return true, path
end

-- f8: one copyable string (CFX1:...) with the theme + full look; also written as config\combatfx_share_NAME.txt
function C.share_string(name)
    local F = require('combatfx.features')
    return F.share_encode(name or C.cfg.theme or 'Custom', C.theme_snapshot())
end
function C.export_share(name)
    local s = C.share_string(name)
    local safe = tostring(name or 'Custom'):gsub('[^%w%-_]', '_')
    local path = string.format('%s/combatfx_share_%s.txt', mq.configDir or '.', safe)
    local f = io.open(path, 'w'); if not f then return false, path, s end
    f:write(s, '\n'); f:close()
    return true, path, s
end
-- import: validate (never runs code), save as a theme section, apply. Returns ok, message
function C.import_share(s)
    local F = require('combatfx.features')
    local ok, name, t, rej = F.share_decode(s)
    if not ok then return false, 'Import failed: ' .. tostring(name) end
    local snap_before = C.theme_snapshot()
    C.apply_theme(t, name)
    local okS = C.save_theme(name)
    local note = (#rej > 0) and string.format(' (%d unknown/invalid keys ignored)', #rej) or ''
    return true, string.format('Imported "%s"%s%s', name, note, okS and '' or ' (could not write combatfx_themes.ini)'), snap_before
end
function C.share_files()
    local out = {}
    local ok, lfs = pcall(require, 'lfs')
    if ok and lfs then pcall(function() for f in lfs.dir(mq.configDir) do if f:match('^combatfx_share_.+%.txt$') then out[#out + 1] = f end end end) end
    table.sort(out); return out
end
function C.read_share_file(f)
    if not tostring(f):match('^combatfx_share_[%w%-_]+%.txt$') then return nil end
    local h = io.open((mq.configDir or '.') .. '/' .. f, 'r'); if not h then return nil end
    local s = h:read(20000) or ''; h:close(); return s
end
function C.fmt(n)
    n = math.floor(n + 0.5)
    if C.cfg.fmt == 'short' then
        local a = math.abs(n)
        if a >= 1e6 then return (string.format('%.1fm', n / 1e6):gsub('%.0m', 'm')) end
        if a >= 1e4 then return (string.format('%.1fk', n / 1e3):gsub('%.0k', 'k')) end
    end
    local s = tostring(n)
    while true do local r, k = s:gsub('^(-?%d+)(%d%d%d)', '%1,%2'); s = r; if k == 0 then break end end
    return s
end
return C
