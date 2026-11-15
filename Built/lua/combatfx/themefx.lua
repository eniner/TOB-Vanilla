-- combatfx themefx: DX11 "full look" themes for the floating numbers (MQ2RmlUi TextFX, rml_features() & 16384).
-- A look = shader style (SDF fill/outline/glow/gradient/shine) + motion + number particles + crit impact + combo.
-- Numbers are drawn by the DLL into the overlay canvas scene (effects layer) before its bloom, so bloom only
-- touches effects/numbers. Every pixel is masked by the player body capsule (rml_tfx_exclude), and spawn points
-- are pushed out of it, so nothing is ever drawn over the character. Without the DLL feature (old DLL, atlas not
-- ready, DX11 off, Lite) fx.lua keeps the old RmlUi text path.
local C = require('combatfx.core')
local ok_ffi, ffi = pcall(require, 'ffi')
local T = { REV = 'tfx1' }

-- ---------------------------------------------------------------- enums (== src/TextFxCore.h)
local D = { X = 0, Y = 1, SIZE = 2, LIFE = 3, MOTION = 4, DIR = 5, TRAVEL = 6, STYLE = 7, FILL_T = 8, FILL_B = 11, OUT_C = 14, OUT_W = 17,
    GLOW_C = 18, GLOW_R = 21, GLOW_S = 22, HDR = 23, SHINE = 24, SHINE_SPD = 25, CRIT = 26, PUNCH = 27, FLASH = 28, SPARKS = 29, SPARK_SPD = 30,
    PTYPE = 31, PRATE = 32, PSIZE = 33, PCOL = 34, SHATTER = 37, SHAKE = 38, SHAKE_T = 39, TRAIL = 40, LOOP = 41, LOOP_GAP = 42, SEED = 43,
    ALPHA = 44, DELAY = 45, COMBO = 46, SHADOW = 47, N = 48 }
T.D = D
T.MOTIONS = { 'static', 'rise', 'arc', 'fountain', 'scroll', 'heal', 'pop' }
T.MOTION_LABEL = { static = 'Static', rise = 'Rise', arc = 'Arc pop-out', fountain = 'Fountain', scroll = 'Scroll', heal = 'Float + sway', pop = 'Punch pop' }
local MOT = { static = 0, rise = 1, arc = 2, fountain = 3, scroll = 4, heal = 5, pop = 6 }
T.STYLES = { 'flat', 'neon', 'metal', 'fire', 'frost', 'holy', 'void', 'storm', 'toxic', 'blood' }
T.STYLE_LABEL = { flat = 'Clean', neon = 'Neon tube', metal = 'Polished metal', fire = 'Living fire', frost = 'Cut ice', holy = 'Radiant', void = 'Void', storm = 'Lightning', toxic = 'Toxic', blood = 'Blood gloss' }
local STY = { flat = 0, neon = 1, metal = 2, fire = 3, frost = 4, holy = 5, void = 6, storm = 7, toxic = 8, blood = 9 }
T.PARTS = { 'none', 'ember', 'shard', 'sparkle', 'mote', 'spark', 'drop', 'bubble', 'rune' }
T.PART_LABEL = { none = 'None', ember = 'Fire embers', shard = 'Frost shards', sparkle = 'Holy sparkles', mote = 'Void motes', spark = 'Electric sparks', drop = 'Blood drops', bubble = 'Toxic bubbles', rune = 'Arcane runes' }
local PT = { none = 0, ember = 1, shard = 2, sparkle = 3, mote = 4, spark = 5, drop = 6, bubble = 7, rune = 8 }

-- ---------------------------------------------------------------- look keys (theme ini: 'x' .. key, alphanumeric)
-- type: s = string, n = number. Ranges are enforced again by the DLL (LoadDesc clamps everything).
T.KEYS = {
    { 'style', 's' }, { 'grad', 's' }, { 'gradmix', 'n', 0, 100 }, { 'outc', 's' }, { 'outw', 'n', 0, 6 },
    { 'glowc', 's' }, { 'glowr', 'n', 0, 11 }, { 'glows', 'n', 0, 4 }, { 'hdr', 'n', 0.6, 3 }, { 'shine', 'n', 0, 3 }, { 'shinespd', 'n', 0, 6 },
    { 'mot', 's' }, { 'healmot', 's' }, { 'travel', 'n', 0, 300 }, { 'trail', 'n', 0, 1 },
    { 'part', 's' }, { 'healpart', 's' }, { 'prate', 'n', 0, 40 }, { 'psize', 'n', 1, 20 }, { 'pcol', 's' },
    { 'punch', 'n', 1, 3 }, { 'flash', 'n', 0, 3 }, { 'sparks', 'n', 0, 24 }, { 'sparkspd', 'n', 0, 900 }, { 'shatter', 'n', 0, 16 },
    { 'shake', 'n', 0, 14 }, { 'combo', 'n', 0, 1 }, { 'mag', 'n', 0, 100 }, { 'bloom', 'n', 0, 2 }, { 'shadow', 'n', 0, 1 },
}
local KEYDEF = {}; for _, k in ipairs(T.KEYS) do KEYDEF[k[1]] = k end

-- ---------------------------------------------------------------- presets (full looks; colours per number kind)
local function look(t) return t end
T.LOOKS = {
    ['Inferno'] = look { style = 'fire', grad = '#ff2400', gradmix = 72, outc = '#2a0600', outw = 2, glowc = '#ff5a00', glowr = 8, glows = 1.1, hdr = 1.35,
        shine = 1.1, shinespd = 1.4, mot = 'arc', healmot = 'heal', travel = 100, trail = 0.6, part = 'ember', healpart = 'ember', prate = 14, psize = 4, pcol = '#ff7a1a',
        punch = 1.65, flash = 1.3, sparks = 14, sparkspd = 320, shatter = 0, shake = 6, combo = 1, mag = 70, bloom = 0.35, shadow = 0.5 },
    ['Glacier'] = look { style = 'frost', grad = '#2a6aff', gradmix = 62, outc = '#001a33', outw = 2, glowc = '#2a8cff', glowr = 7, glows = 0.9, hdr = 1.25,
        shine = 1.0, shinespd = 0.8, mot = 'pop', healmot = 'heal', travel = 70, trail = 0.55, part = 'shard', healpart = 'sparkle', prate = 6, psize = 5, pcol = '#bfe8ff',
        punch = 1.55, flash = 1.1, sparks = 8, sparkspd = 240, shatter = 10, shake = 4, combo = 1, mag = 60, bloom = 0.22, shadow = 0.4 },
    ['Holy Radiance'] = look { style = 'holy', grad = '#ffb000', gradmix = 55, outc = '#3a2400', outw = 1.5, glowc = '#ffc030', glowr = 10, glows = 1.0, hdr = 1.3,
        shine = 1.3, shinespd = 1.0, mot = 'rise', healmot = 'heal', travel = 95, trail = 0.7, part = 'sparkle', healpart = 'sparkle', prate = 12, psize = 4, pcol = '#fff3b0',
        punch = 1.5, flash = 1.6, sparks = 16, sparkspd = 260, shatter = 0, shake = 3, combo = 1, mag = 55, bloom = 0.26, shadow = 0.3 },
    ['Void'] = look { style = 'void', grad = '#2a0050', gradmix = 70, outc = '#000000', outw = 3, glowc = '#7a18ff', glowr = 9, glows = 1.3, hdr = 1.3,
        shine = 0.8, shinespd = 0.7, mot = 'fountain', healmot = 'heal', travel = 95, trail = 0.6, part = 'mote', healpart = 'mote', prate = 10, psize = 5, pcol = '#a050ff',
        punch = 1.6, flash = 1.0, sparks = 10, sparkspd = 220, shatter = 6, shake = 5, combo = 1, mag = 65, bloom = 0.32, shadow = 0.6 },
    ['Storm'] = look { style = 'storm', grad = '#2050ff', gradmix = 50, outc = '#000a20', outw = 2, glowc = '#2a90ff', glowr = 8, glows = 1.1, hdr = 1.3,
        shine = 1.2, shinespd = 2.6, mot = 'pop', healmot = 'heal', travel = 80, trail = 0.5, part = 'spark', healpart = 'spark', prate = 16, psize = 3, pcol = '#a8e0ff',
        punch = 1.7, flash = 1.5, sparks = 20, sparkspd = 420, shatter = 0, shake = 8, combo = 1, mag = 70, bloom = 0.28, shadow = 0.4 },
    ['Classic EQ Enhanced'] = look { style = 'metal', grad = '#806040', gradmix = 30, outc = '#000000', outw = 2, glowc = '', glowr = 4, glows = 0.6, hdr = 1.35,
        shine = 1.0, shinespd = 1.0, mot = 'rise', healmot = 'heal', travel = 95, trail = 0.45, part = 'none', healpart = 'sparkle', prate = 6, psize = 4, pcol = '',
        punch = 1.4, flash = 1.0, sparks = 10, sparkspd = 260, shatter = 0, shake = 3, combo = 1, mag = 50, bloom = 0.2, shadow = 0.6 },
    ['Minimal Clean'] = look { style = 'flat', grad = '#ffffff', gradmix = 0, outc = '#000000', outw = 1.5, glowc = '', glowr = 2, glows = 0.3, hdr = 1.4,
        shine = 0, shinespd = 1.0, mot = 'pop', healmot = 'rise', travel = 55, trail = 0, part = 'none', healpart = 'none', prate = 0, psize = 3, pcol = '',
        punch = 1.25, flash = 0.4, sparks = 0, sparkspd = 200, shatter = 0, shake = 0, combo = 1, mag = 35, bloom = 0, shadow = 0.5 },
    ['Blood Moon'] = look { style = 'blood', grad = '#400000', gradmix = 70, outc = '#120000', outw = 2.5, glowc = '#ff1010', glowr = 7, glows = 1.2, hdr = 1.3,
        shine = 0.9, shinespd = 0.9, mot = 'fountain', healmot = 'heal', travel = 100, trail = 0.5, part = 'drop', healpart = 'mote', prate = 8, psize = 5, pcol = '#c00010',
        punch = 1.6, flash = 1.2, sparks = 12, sparkspd = 300, shatter = 0, shake = 6, combo = 1, mag = 65, bloom = 0.3, shadow = 0.6 },
    ['Venom'] = look { style = 'toxic', grad = '#106000', gradmix = 65, outc = '#001200', outw = 2, glowc = '#70ff30', glowr = 8, glows = 1.2, hdr = 1.3,
        shine = 0.7, shinespd = 1.2, mot = 'arc', healmot = 'heal', travel = 90, trail = 0.5, part = 'bubble', healpart = 'bubble', prate = 9, psize = 5, pcol = '#90ff50',
        punch = 1.5, flash = 1.0, sparks = 10, sparkspd = 240, shatter = 0, shake = 4, combo = 1, mag = 60, bloom = 0.3, shadow = 0.5 },
    -- f8 accessibility presets: colour-blind-safe palettes (Okabe-Ito based) with strong outlines, crisp shaders and
    -- the same motion / particles / crit impact as every other theme (heals '+', damage taken '-' as a second cue)
    ['Deuteranopia Safe'] = look { style = 'metal', grad = '#203040', gradmix = 22, outc = '#000000', outw = 3, glowc = '', glowr = 4, glows = 0.5, hdr = 1.3,
        shine = 0.9, shinespd = 1.0, mot = 'rise', healmot = 'heal', travel = 90, trail = 0.4, part = 'sparkle', healpart = 'sparkle', prate = 5, psize = 4, pcol = '#f0e442',
        punch = 1.6, flash = 1.1, sparks = 10, sparkspd = 260, shatter = 0, shake = 3, combo = 1, mag = 55, bloom = 0.12, shadow = 0.8 },
    ['Protanopia Safe'] = look { style = 'metal', grad = '#203040', gradmix = 22, outc = '#000000', outw = 3, glowc = '', glowr = 4, glows = 0.5, hdr = 1.3,
        shine = 0.9, shinespd = 1.0, mot = 'arc', healmot = 'heal', travel = 90, trail = 0.4, part = 'spark', healpart = 'sparkle', prate = 5, psize = 3, pcol = '#56b4e9',
        punch = 1.6, flash = 1.1, sparks = 10, sparkspd = 280, shatter = 0, shake = 3, combo = 1, mag = 55, bloom = 0.12, shadow = 0.8 },
    ['Tritanopia Safe'] = look { style = 'metal', grad = '#301020', gradmix = 22, outc = '#000000', outw = 3, glowc = '', glowr = 4, glows = 0.5, hdr = 1.3,
        shine = 0.9, shinespd = 1.0, mot = 'pop', healmot = 'heal', travel = 80, trail = 0.4, part = 'shard', healpart = 'sparkle', prate = 4, psize = 4, pcol = '#ffffff',
        punch = 1.6, flash = 1.1, sparks = 10, sparkspd = 260, shatter = 6, shake = 3, combo = 1, mag = 55, bloom = 0.12, shadow = 0.8 },
    ['High Contrast'] = look { style = 'flat', grad = '#000000', gradmix = 0, outc = '#000000', outw = 4, glowc = '', glowr = 2, glows = 0.2, hdr = 1.25,
        shine = 0.4, shinespd = 1.0, mot = 'pop', healmot = 'rise', travel = 70, trail = 0.2, part = 'spark', healpart = 'sparkle', prate = 3, psize = 3, pcol = '#ffffff',
        punch = 1.75, flash = 0.8, sparks = 8, sparkspd = 300, shatter = 0, shake = 2, combo = 1, mag = 60, bloom = 0, shadow = 1 },
    -- f8 spell-school look for Disease (not a theme card; used only by the school override): spores drift up
    ['Plague'] = look { style = 'toxic', grad = '#4a3a00', gradmix = 60, outc = '#140e00', outw = 2, glowc = '#c8a020', glowr = 7, glows = 1.0, hdr = 1.25,
        shine = 0.6, shinespd = 0.8, mot = 'fountain', healmot = 'heal', travel = 85, trail = 0.5, part = 'mote', healpart = 'mote', prate = 9, psize = 4, pcol = '#d8c060',
        punch = 1.45, flash = 0.9, sparks = 8, sparkspd = 200, shatter = 0, shake = 3, combo = 1, mag = 55, bloom = 0.24, shadow = 0.5 },
}
-- the older colour-only presets get a matching look so they are not plain recolours either
T.LOOK_FOR = { ['Classic EQ'] = 'Classic EQ Enhanced', ['Neon'] = 'Storm', ['Minimal'] = 'Minimal Clean', ['Blood'] = 'Blood Moon', ['Holy'] = 'Holy Radiance' }
T.OLD_OVERRIDE = { ['Neon'] = { style = 'neon', part = 'spark', grad = '#ff40ff', gradmix = 35, glowc = '' } }
T.COLORS = {
    ['Inferno'] = { melee = '#ffd36a', spell = '#ff9a3a', dot = '#ff7040', crit = '#fff0a0', incoming = '#ff3a2a', healin = '#ffe070', healout = '#ffc060', miss = '#b09080', resist = '#ff8060', kill = '#ffe08a', proc = '#ff9a40', pet = '#e0b080' },
    ['Glacier'] = { melee = '#e8f6ff', spell = '#8ad0ff', dot = '#a0b8ff', crit = '#ffffff', incoming = '#ff6a7a', healin = '#80ffe0', healout = '#60e8ff', miss = '#90a8c0', resist = '#b0a0ff', kill = '#d0f0ff', proc = '#a0e0ff', pet = '#b0d0e0' },
    ['Holy Radiance'] = { melee = '#fff8e0', spell = '#ffe890', dot = '#f0d8a0', crit = '#ffffff', incoming = '#ff9a70', healin = '#fff070', healout = '#ffffa0', miss = '#c8c0a0', resist = '#e8c8ff', kill = '#ffd700', proc = '#ffd070', pet = '#f0e8c0' },
    ['Void'] = { melee = '#e0c8ff', spell = '#c070ff', dot = '#9a50ff', crit = '#ffffff', incoming = '#ff3a8a', healin = '#a0ffd0', healout = '#80e0ff', miss = '#8070a0', resist = '#d090ff', kill = '#e0a0ff', proc = '#c080ff', pet = '#b0a0d0' },
    ['Storm'] = { melee = '#e8f4ff', spell = '#60d0ff', dot = '#80a0ff', crit = '#fffbe0', incoming = '#ff5a6a', healin = '#80ffb0', healout = '#60ffe0', miss = '#90a0b8', resist = '#c0a0ff', kill = '#fff280', proc = '#80e8ff', pet = '#a0c8e0' },
    ['Classic EQ Enhanced'] = { melee = '#ffffff', spell = '#8ac8ff', dot = '#c8a0ff', crit = '#ffd040', incoming = '#ff5a4a', healin = '#6aff8a', healout = '#40e0a0', miss = '#a0a8b8', resist = '#d090ff', kill = '#ffe08a', proc = '#ff9a40', pet = '#c0c8a0' },
    ['Minimal Clean'] = { melee = '#e8e8e8', spell = '#b8d4ff', dot = '#b8b8d8', crit = '#ffffff', incoming = '#ff8a8a', healin = '#a8ffb8', healout = '#a8e8c8', miss = '#888888', resist = '#c8a8e8', kill = '#ffffff', proc = '#e8c888', pet = '#c8c8c8' },
    ['Blood Moon'] = { melee = '#ffd8d0', spell = '#ff6a3a', dot = '#e03030', crit = '#ff3030', incoming = '#c01010', healin = '#ff9a9a', healout = '#ffb8b8', miss = '#806060', resist = '#ff6080', kill = '#ff3030', proc = '#ff7040', pet = '#d08080' },
    ['Venom'] = { melee = '#e0ffd0', spell = '#90ff50', dot = '#60e040', crit = '#f8ff80', incoming = '#ff5a4a', healin = '#60ffb0', healout = '#40e0a0', miss = '#90a080', resist = '#c0ff60', kill = '#e8ff60', proc = '#b0ff40', pet = '#a8c890' },
    ['Deuteranopia Safe'] = { melee = '#ffffff', spell = '#56b4e9', dot = '#c8d8f0', crit = '#f0e442', incoming = '#d55e00', healin = '#33c4a0', healout = '#7a8cff', miss = '#9a9a9a', resist = '#cc79a7', kill = '#f0e442', proc = '#e69f00', pet = '#c8c8c8', group = '#b8c8e0' },
    ['Protanopia Safe'] = { melee = '#ffffff', spell = '#56b4e9', dot = '#c8d8f0', crit = '#f0e442', incoming = '#e07000', healin = '#33c4a0', healout = '#7a8cff', miss = '#9a9a9a', resist = '#cc79a7', kill = '#f0e442', proc = '#ffd27a', pet = '#c8c8c8', group = '#b8c8e0' },
    ['Tritanopia Safe'] = { melee = '#ffffff', spell = '#ff8ac8', dot = '#e0c0d0', crit = '#ff5a5a', incoming = '#a00030', healin = '#30d8b8', healout = '#c0fff0', miss = '#9a9a9a', resist = '#c080ff', kill = '#ff5a5a', proc = '#ffb0b0', pet = '#c8c8c8', group = '#a8d8d8' },
    ['High Contrast'] = { melee = '#ffffff', spell = '#00e5ff', dot = '#c8c8ff', crit = '#ffe000', incoming = '#ff3c3c', healin = '#00ff66', healout = '#c0ffc0', miss = '#c0c0c0', resist = '#ff66ff', kill = '#ffe000', proc = '#ff9900', pet = '#e0e0e0', group = '#a0e0ff' },
    ['Plague'] = { melee = '#f0e8c0', spell = '#d8c060', dot = '#c0a040', crit = '#fff0a0', incoming = '#ff5a4a', healin = '#c8e080', healout = '#b0d070', miss = '#a09870', resist = '#d8c060', kill = '#f0d860', proc = '#d8c060', pet = '#c8c0a0' },
}
for _, t in pairs(T.COLORS) do if not t.group then t.group = C.derive_group and C.derive_group(t.melee) or '#b8c4d8' end end
T.A11Y = { ['Deuteranopia Safe'] = true, ['Protanopia Safe'] = true, ['Tritanopia Safe'] = true, ['High Contrast'] = true }
T.ORDER = { 'Inferno', 'Glacier', 'Holy Radiance', 'Void', 'Storm', 'Classic EQ Enhanced', 'Minimal Clean', 'Blood Moon', 'Venom',
    'Deuteranopia Safe', 'Protanopia Safe', 'Tritanopia Safe', 'High Contrast' }
T.DESC_TXT = { ['Inferno'] = 'Fire shader, embers, arcs', ['Glacier'] = 'Ice facets, shards shatter', ['Holy Radiance'] = 'Radiant rays, sparkles',
    ['Void'] = 'Dark core, violet motes', ['Storm'] = 'Lightning veins, sparks', ['Classic EQ Enhanced'] = 'Metal shine, classic colours',
    ['Minimal Clean'] = 'Crisp, quiet, no particles', ['Blood Moon'] = 'Blood gloss, drops', ['Venom'] = 'Toxic bubbles, arcs',
    ['Deuteranopia Safe'] = 'Colour-blind safe: red-green (deutan)', ['Protanopia Safe'] = 'Colour-blind safe: red-green (protan)',
    ['Tritanopia Safe'] = 'Colour-blind safe: blue-yellow (tritan)', ['High Contrast'] = 'Max contrast, thick outlines' }

function T.copy(l) local o = {}; for k, v in pairs(l) do o[k] = v end; return o end
function T.default_look() return T.copy(T.LOOKS['Classic EQ Enhanced']) end

-- register the new presets as themes (colours + look) next to the old ones
function T.install_presets()
    for _, n in ipairs(T.ORDER) do
        local t = T.copy(T.COLORS[n])
        t.style = (n == 'Minimal Clean') and 'normal' or (T.A11Y[n] and 'heavy') or 'bold'
        t.motion = ({ arc = 'arc', fountain = 'fountain', static = 'static', scroll = 'scroll' })[T.LOOKS[n].mot] or 'rise'
        t.size = (n == 'Minimal Clean') and 20 or 24
        for k, v in pairs(T.LOOKS[n]) do t['x' .. k] = v end
        C.THEMES[n] = t
    end
    for old, base in pairs(T.LOOK_FOR) do
        local t = C.THEMES[old]
        if t and not t.xstyle then
            for k, v in pairs(T.LOOKS[base]) do t['x' .. k] = v end
            for k, v in pairs(T.OLD_OVERRIDE[old] or {}) do t['x' .. k] = v end
            t.xmot = ({ arc = 'arc', fountain = 'fountain', static = 'static', scroll = 'scroll', rise = 'rise' })[t.motion] or t.xmot
        end
    end
    local order = {}
    for _, n in ipairs(T.ORDER) do order[#order + 1] = n end
    for _, n in ipairs(C.THEME_ORDER) do local dup = false; for _, m in ipairs(order) do if m == n then dup = true end end; if not dup then order[#order + 1] = n end end
    C.THEME_ORDER = order
end

-- ---------------------------------------------------------------- theme <-> cfg.tfx (ini keys 'x' .. key)
local function norm(k, v)
    local def = KEYDEF[k]; if not def then return nil end
    if def[2] == 'n' then
        local n = tonumber(v); if not n then return nil end
        if def[3] then n = math.max(def[3], math.min(def[4], n)) end
        return n
    end
    v = tostring(v or '')
    if k == 'style' and not STY[v] then return nil end
    if (k == 'mot' or k == 'healmot') and not MOT[v] then return nil end
    if (k == 'part' or k == 'healpart') and not PT[v] then return nil end
    if (k == 'grad' or k == 'outc' or k == 'glowc' or k == 'pcol') and v ~= '' and not v:match('^#%x%x%x%x%x%x$') then return nil end
    return v
end
T.norm = norm
function T.snapshot(into)
    into = into or {}
    local L = C.cfg.tfx or {}
    for _, k in ipairs(T.KEYS) do if L[k[1]] ~= nil then into['x' .. k[1]] = L[k[1]] end end
    into.xon = (L.on ~= false) and 1 or 0
    return into
end
-- t = theme section (strings from the ini or preset table). Old ini sections without x-keys keep working:
-- they get the matching built-in look (by name) or Classic EQ Enhanced with their old motion.
function T.apply(t, name)
    local L = C.cfg.tfx
    local has = false
    for _, k in ipairs(T.KEYS) do if t['x' .. k[1]] ~= nil then has = true; break end end
    if not has then
        local base = T.LOOKS[name or ''] or T.LOOKS[T.LOOK_FOR[name or ''] or ''] or T.LOOKS['Classic EQ Enhanced']
        for k, v in pairs(base) do L[k] = v end
        local m = ({ arc = 'arc', fountain = 'fountain', static = 'static', scroll = 'scroll', rise = 'rise' })[t.motion or '']
        if m then L.mot = m end
        return false
    end
    for _, k in ipairs(T.KEYS) do
        local v = t['x' .. k[1]]
        if v ~= nil then local nv = norm(k[1], v); if nv ~= nil then L[k[1]] = nv end end
    end
    if t.xon ~= nil then L.on = tostring(t.xon) ~= '0' and tostring(t.xon) ~= 'false' end
    return true
end
-- per-character defaults (C.cfg.tfx; ser/apply_kv store it as tfx.key=value in the character ini)
function T.init_cfg()
    local L = T.default_look(); L.on = true; L.ver = 0; L.log = false
    C.cfg.tfx = L
end
-- first run with this version: the character ini has no tfx.* keys yet -> give the current theme its look
function T.after_load()
    local L = C.cfg.tfx
    if (tonumber(L.ver) or 0) >= 1 then return false end
    local name = C.cfg.theme or 'Classic EQ'
    local t = C.THEMES[name]
    if not t then local ok, saved = pcall(C.saved_themes); if ok and saved then t = saved[name] end end
    T.apply(t or { motion = C.cfg.motion }, name)
    L.ver = 1
    C.save_cfg()
    return true
end

-- ---------------------------------------------------------------- colour helpers
local function rgb(hex, fr, fg, fb)
    hex = tostring(hex or '')
    local r, g, b = hex:match('^#(%x%x)(%x%x)(%x%x)')
    if not r then return fr or 1, fg or 1, fb or 1 end
    return tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255
end
T.rgb = rgb
local function mix(a, b, t) return a + (b - a) * t end

-- ---------------------------------------------------------------- descriptor
local HEAL = { healin = true, healout = true }
local SMALL = { miss = true, dot = true, pet = true }
local PRATE_KIND = { melee = 0.7, spell = 1.0, dot = 0.35, crit = 1.0, incoming = 0.6, healin = 0.8, healout = 0.6, miss = 0, resist = 0.4, kill = 1.2, proc = 0.9, pet = 0.35, missout = 0 }
-- o: kind, x, y, size, life, dir, crit, huge, combo, color, travel_scale, loop, gap, delay, seed, alpha, heal
function T.fill(buf, L, o)
    for i = 0, D.N - 1 do buf[i] = 0 end
    local kind = o.kind or 'melee'
    local heal = o.heal or HEAL[kind]
    local cr, cg, cb = rgb(o.color or C.cfg.color[kind] or '#ffffff')
    local gr, gg, gb = rgb(L.grad, cr, cg, cb)
    local gm = (tonumber(L.gradmix) or 0) / 100
    buf[D.X], buf[D.Y], buf[D.SIZE], buf[D.LIFE] = o.x or 0, o.y or 0, o.size or 24, o.life or 1.3
    local mot = heal and (L.healmot or 'heal') or (L.mot or 'rise')
    buf[D.MOTION] = MOT[mot] or 1
    buf[D.DIR] = (o.dir or 1) < 0 and -1 or 1
    buf[D.TRAVEL] = (tonumber(L.travel) or 95) * (o.travel_scale or 1) * (heal and 1.0 or 1)
    buf[D.STYLE] = STY[L.style] or 0
    -- gradient: lighter top, theme-tinted bottom
    buf[D.FILL_T], buf[D.FILL_T + 1], buf[D.FILL_T + 2] = mix(cr, 1, 0.18), mix(cg, 1, 0.18), mix(cb, 1, 0.18)
    buf[D.FILL_B], buf[D.FILL_B + 1], buf[D.FILL_B + 2] = mix(cr, gr, gm), mix(cg, gg, gm), mix(cb, gb, gm)
    local orr, og, ob = rgb(L.outc, 0, 0, 0)
    buf[D.OUT_C], buf[D.OUT_C + 1], buf[D.OUT_C + 2], buf[D.OUT_W] = orr, og, ob, tonumber(L.outw) or 2
    local wr, wg, wb = rgb((L.glowc ~= '' and L.glowc) or nil, cr, cg, cb)
    local crit, huge = o.crit and true or false, o.huge and true or false
    buf[D.GLOW_C], buf[D.GLOW_C + 1], buf[D.GLOW_C + 2] = wr, wg, wb
    buf[D.GLOW_R] = (tonumber(L.glowr) or 6) * (crit and 1.2 or 1)
    buf[D.GLOW_S] = (tonumber(L.glows) or 1) * (crit and 1.15 or 1)
    buf[D.HDR] = tonumber(L.hdr) or 1.4
    buf[D.SHINE] = (tonumber(L.shine) or 0) * ((crit or huge) and 1 or 0.18)
    buf[D.SHINE_SPD] = tonumber(L.shinespd) or 1
    local punch = tonumber(L.punch) or 1.3
    if crit then
        buf[D.CRIT] = 1; buf[D.PUNCH] = punch; buf[D.FLASH] = tonumber(L.flash) or 1
        buf[D.SPARKS] = math.floor((tonumber(L.sparks) or 0) * (huge and 1.3 or 1))
        buf[D.SHATTER] = tonumber(L.shatter) or 0
    else
        buf[D.PUNCH] = 1 + (punch - 1) * (huge and 0.8 or 0.35)
        buf[D.FLASH] = huge and (tonumber(L.flash) or 0) * 0.5 or 0
        buf[D.SPARKS] = huge and math.floor((tonumber(L.sparks) or 0) * 0.5) or 0
    end
    buf[D.SPARK_SPD] = tonumber(L.sparkspd) or 260
    local part = heal and (L.healpart or L.part) or L.part
    local pk = PRATE_KIND[o.lane or kind] or 0.6
    buf[D.PTYPE] = PT[part] or 0
    buf[D.PRATE] = (tonumber(L.prate) or 0) * pk * (crit and 1.5 or 1) * (o.prate_scale or 1)
    buf[D.PSIZE] = (tonumber(L.psize) or 4) * math.max(0.6, math.min(1.6, (o.size or 24) / 24))
    local pr, pg, pb = rgb((L.pcol ~= '' and L.pcol) or nil, cr, cg, cb)
    buf[D.PCOL], buf[D.PCOL + 1], buf[D.PCOL + 2] = pr, pg, pb
    if not o.loop and not C.particles_on() then
        buf[D.PTYPE], buf[D.PRATE], buf[D.SPARKS], buf[D.SHATTER] = 0, 0, 0, 0
    end
    buf[D.SHAKE] = (huge and crit) and (tonumber(L.shake) or 0) * (o.shake_scale or 1) or 0
    buf[D.SHAKE_T] = 0.28
    buf[D.TRAIL] = heal and (tonumber(L.trail) or 0) or ((crit and (tonumber(L.trail) or 0) * 0.4) or 0)
    buf[D.LOOP] = o.loop and 1 or 0
    buf[D.LOOP_GAP] = o.gap or 0.35
    buf[D.SEED] = o.seed or 0
    buf[D.ALPHA] = o.alpha or 1
    buf[D.DELAY] = o.delay or 0
    buf[D.COMBO] = o.combo or 0
    buf[D.SHADOW] = tonumber(L.shadow) or 0
    return buf
end

-- ---------------------------------------------------------------- DLL binding
local CDEF = {
    'int rml_tfx_ready();', 'int rml_tfx_font(const char* path);',
    'int rml_tfx_spawn(const char* win, const char* id, const char* text, const float* desc, int n);',
    'int rml_tfx_set(int h, const char* text, int combo, int pulse);', 'int rml_tfx_kill(int h, int fade);',
    'int rml_tfx_clear(const char* win, const char* id);',
    'int rml_tfx_exclude(const char* win, const char* id, const float* p, int n);',
    'int rml_tfx_shake(const char* win, const char* id, float px, float seconds);',
    'int rml_tfx_bloom(const char* win, const char* id, float strength);',
    'int rml_tfx_stats(char* out, int cap);',
    'int rml_api_version();', 'int rml_features();',
    'int rml_canvas_size(const char* win, const char* id, float* out_w, float* out_h);',
}
local st = { avail = nil, next_check = 0, ready = 0, why = 'not checked', lib = nil }
T.st = st
local WIN, ID = 'CombatFxOverlay', 'cfx'
local desc, capbuf, statbuf
local function lib_of()
    local CV = package.loaded['combatfx.canvas']
    if CV and CV._api then return CV._api end
    if not ok_ffi then return nil end
    local ok, l = pcall(ffi.load, 'MQ2RmlUi'); if ok then return l end
    return nil
end
function T.check(force)
    local now = C.now()
    if not force and st.avail ~= nil and now < st.next_check then return st.avail end
    st.next_check = now + (st.avail and 5000 or 2000)
    st.avail = false
    if not ok_ffi then st.why = 'no ffi'; return false end
    for _, d in ipairs(CDEF) do pcall(ffi.cdef, d) end
    local lib = lib_of(); if not lib then st.why = 'MQ2RmlUi not loaded'; return false end
    local feat, ready = 0, -9
    local okc = pcall(function()
        feat = tonumber(lib.rml_features()) or 0
        if math.floor(feat / 16384) % 2 ~= 1 then return end
        ready = tonumber(lib.rml_tfx_ready()) or -9
    end)
    if not okc then st.why = 'old MQ2RmlUi (no TextFX)'; return false end
    if math.floor(feat / 16384) % 2 ~= 1 then st.why = 'old MQ2RmlUi (feature 16384 missing)'; return false end
    st.ready = ready
    if ready == 0 then st.why = 'building glyph atlas'; st.next_check = now + 250; return false end
    if ready == -1 then st.why = 'no usable font'; return false end
    if ready == -2 then st.why = 'no D3D11 FL11 GPU path'; return false end
    if ready ~= 1 then st.why = 'not ready (' .. tostring(ready) .. ')'; return false end
    st.lib = lib
    if not desc then desc = ffi.new('float[48]'); capbuf = ffi.new('float[13]'); statbuf = ffi.new('char[1024]') end
    st.avail = true; st.why = 'ready'
    return true
end
-- the overlay path is on only when the user wants DX11, the look is on, and the DLL is ready
function T.enabled()
    local cfg = C.cfg
    if not cfg.master or cfg.lite or not cfg.fx.dx11 then return false end
    if cfg.tfx and cfg.tfx.on == false then return false end
    return T.check()
end

-- ---------------------------------------------------------------- body capsule (never draw over the character)
local cap_t, cap_src, cap_ok, G = -1e9, 'none', false, nil
local function push_capsule(force)
    local now = C.now()
    if not force and now - cap_t < 33 then return cap_ok end
    local CV = package.loaded['combatfx.canvas']
    local fx, fy, ux, uy, span, src, wmul
    if CV and CV.player_capsule then
        local ok, a, b, c, d, e, f, g = pcall(CV.player_capsule)
        if ok then fx, fy, ux, uy, span, src, wmul = a, b, c, d, e, f, g end
    end
    if not fx then
        local sw, sh = C.screen()
        fx, fy, ux, uy, span, src = sw * 0.5, sh * 0.86, 0, -1, sh * 0.40, 'default'
    end
    if G == nil then local ok, g = pcall(require, 'combatfx.bodyfx_gpu'); G = ok and g or false end
    local cp
    if G and G.capsule then cp = G.capsule(fx, fy, ux, uy, span, {}, wmul)
    else cp = { [0] = fx, fy, ux, uy, span, 0.36, 0.30, 0.25, 0.25, 0.22, 0.18, 0.14, math.max(6, span * 0.06) } end
    for i = 0, 12 do capbuf[i] = tonumber(cp[i]) or 0 end
    local rc = 0
    pcall(function() rc = tonumber(st.lib.rml_tfx_exclude(WIN, ID, capbuf, 13)) or 0 end)
    cap_t, cap_src, cap_ok = now, src or '?', rc == 1
    T.cap_src = cap_src
    return cap_ok
end
T.push_capsule = push_capsule

-- ---------------------------------------------------------------- overlay numbers
local coal, live_until, ema, bloom_set, lives = {}, 0, {}, nil, {}
local spawned, spawn_ms, set_calls = 0, 0, 0
-- per number kind (melee vs spell vs heal ... each has its own scale); every hit is a sample (coalesced ones too).
-- 'crit' (melee crit line) is measured against normal melee. 'huge' needs >= 4 samples first.
local function ema_note(g, value)
    if type(value) ~= 'number' or value <= 0 then return end
    local e = ema[g]
    if not e then ema[g] = { v = value, n = 1 } else e.v = e.v + (value - e.v) * 0.08; e.n = e.n + 1 end
end
local function mag_scale(kind, value, L)
    if type(value) ~= 'number' or value <= 0 then return 1, false end
    local g = (kind == 'crit' and ema.melee) and 'melee' or kind
    local e = ema[g]
    if not e or e.n < 4 then ema_note(kind, value); return 1, false end
    local r = value / math.max(1, e.v)
    ema_note(kind, value)
    local amt = (tonumber(L.mag) or 0) / 100
    local s = 1 + amt * 0.30 * (math.log(r) / math.log(2))
    s = math.max(1 - amt * 0.25, math.min(1 + amt * 0.65, s))
    return s, r >= 2.2
end
-- returns true when the number was drawn by TextFX (fx.lua then skips the old text element)
function T.number(kind, lk, value, opts, x, y, dir)
    if not T.enabled() then return false end
    local L = C.cfg.tfx
    -- f8: role look (yours / group / on you / pet), optional spell-school look, performance tier
    local FT = package.loaded['combatfx.features']
    local scol, rmod
    if FT then L, scol, rmod = FT.look_for(L, kind, lk, opts) end
    local now = C.now()
    local t0 = os.clock()
    local crit = opts.crit or kind == 'crit'
    local c = coal[lk]
    -- sliding 250 ms window (each hit re-arms it) while the number still has >= 0.35 s to live: real combo stacks
    if type(value) == 'number' and c and now - c.t < 250 and now < c.until_ - 350 and not crit then
        c.n = c.n + value; c.cnt = c.cnt + 1; c.prefix = opts.prefix or ''; c.dirty = true; c.t = now
        ema_note(kind, value)
        return true
    end
    if crit and now - (T._last_crit or 0) < 120 then
        local cc = coal.crit_merge
        if cc and now < cc.until_ and type(value) == 'number' then cc.n = cc.n + value; cc.cnt = cc.cnt + 1; cc.dirty = true; cc.crit = true; return true end
    end
    -- same 'Most at once' cap as the text path (Lite is never here); at the cap only crits / kills replace
    local cap = math.max(1, math.min(64, tonumber(C.cfg.max) or 24))
    if FT then cap = FT.cap(cap) end
    local n_live = 0
    for i = #lives, 1, -1 do if lives[i] <= now then table.remove(lives, i) else n_live = n_live + 1 end end
    if n_live >= cap and not crit and kind ~= 'kill' then return true end
    if not push_capsule(false) then return false end          -- no body mask -> never draw (old path instead)
    local size = C.cfg.size
    if crit then size = size * 1.45 elseif SMALL[kind] then size = size * 0.78 elseif kind == 'kill' then size = size * 1.2 end
    local ms, huge = mag_scale(kind, value, L)
    if opts.big then huge = true end
    size = size * ms * (rmod and rmod.size or 1)
    if FT then size = FT.min_size(size) end
    local life = C.cfg.dur * (crit and 1.25 or 1)
    local text = type(value) == 'number' and ((opts.prefix or '') .. C.fmt(value)) or tostring(value)
    if crit and type(value) == 'number' then text = text .. '!' end
    local bw, bh
    x, y, bw, bh = T.place(now, x, y, size, #text)
    local _, sh = C.screen()
    T.fill(desc, L, { kind = kind, lane = lk, x = x, y = y, size = size, life = life, dir = dir, crit = crit, huge = huge,
        color = opts.color or scol, travel_scale = sh / 1080, shake_scale = 1, alpha = rmod and rmod.alpha or 1 })
    local h = 0
    pcall(function() h = tonumber(st.lib.rml_tfx_spawn(WIN, ID, text, desc, D.N)) or 0 end)
    spawn_ms = spawn_ms + (os.clock() - t0) * 1000; spawned = spawned + 1
    if h <= 0 then return false end
    local until_ = now + math.floor(life * 1000)
    lives[#lives + 1] = until_
    if until_ + 700 > live_until then live_until = until_ + 700 end
    coal[lk] = { t = now, h = h, n = type(value) == 'number' and value or 0, cnt = 1, wt = now, until_ = until_, crit = crit and type(value) == 'number', prefix = opts.prefix or '' }
    if crit then T._last_crit = now; coal.crit_merge = coal[lk] end
    T.note(now, x, y, bw, bh, desc, coal[lk])
    T._dur = life
    return true, life
end
-- keep numbers from landing on one that is still flying: positions follow the same motion maths as the DLL
-- (TextFxCore MotionAt, offsets only); up to 4 nudges upward; <= 24 live boxes checked
local function ease_cubic(u) u = 1 - math.max(0, math.min(1, u)); return 1 - u * u * u end
local function ease_quad(u) u = math.max(0, math.min(1, u)); return 1 - (1 - u) * (1 - u) end
function T.motion_at(m, t, L, tr, dir)
    local u = math.max(0, math.min(1, t / L))
    if m == 1 then return 0, -tr * ease_cubic(u)
    elseif m == 2 then return dir * tr * 0.85 * ease_quad(u), -tr * 0.62 * (4 * u * (1 - u)) - tr * 0.18 * u
    elseif m == 3 then local tt = math.max(0, math.min(L, t)); return dir * tr * 0.55 / L * tt, -tr * 2.4 / L * tt + 0.5 * tr * 4.2 / (L * L) * tt * tt
    elseif m == 4 then return dir * tr * 1.45 * ease_quad(u), -tr * 0.08 * u
    elseif m == 5 then return math.sin(u * 6.2831853 * 1.15) * 0.07 * tr, -tr * 1.15 * ease_quad(u)
    elseif m == 6 then return 0, -tr * 0.38 * ease_cubic(math.max(0, math.min(1, (u - 0.12) / 0.88))) end
    return 0, 0
end
local recent = {}
function T.place(now, x, y, size, nch)
    local w, h = size * 0.6 * nch + 6, size * 0.95
    for _ = 1, 4 do
        local hit = false
        for i = #recent, 1, -1 do
            local r = recent[i]
            local age = (now - r.t) / 1000
            if age > r.life then table.remove(recent, i)
            else
                local ox, oy = T.motion_at(r.m, age, r.life, r.tr, r.dir)
                local rx, ry = r.x + ox, r.y + oy
                local rw = r.w + (r.combo and r.combo() or 0)
                if math.abs(rx - x) < (rw + w) * 0.5 and math.abs(ry - y) < (r.h + h) * 0.5 then hit = true; y = ry - (r.h + h) * 0.5 - 3 end
            end
        end
        if not hit then break end
    end
    return x, y, w, h
end
function T.note(now, x, y, w, h, d, c)
    recent[#recent + 1] = { t = now, x = x, y = y, w = w, h = h, m = d[D.MOTION], life = d[D.LIFE], tr = d[D.TRAVEL], dir = d[D.DIR],
        combo = c and function() return (c.cnt > 1) and h * 1.6 or 0 end or nil }
    if #recent > 24 then table.remove(recent, 1) end
end
function T.flush(now)
    local L = C.cfg.tfx
    for _, c in pairs(coal) do
        if c.dirty and now - (c.wt or 0) >= 60 then
            c.dirty = false; c.wt = now
            local base = (c.prefix or '') .. C.fmt(c.n) .. (c.crit and '!' or '')
            local combo_on = (tonumber(L.combo) or 1) >= 1
            local text = combo_on and base or (base .. ' x' .. c.cnt)
            pcall(function() st.lib.rml_tfx_set(c.h, text, combo_on and c.cnt or 0, 1) end)
            set_calls = set_calls + 1
        end
    end
end
function T.live() return C.now() < live_until end
function T.live_count()
    local now, n = C.now(), 0
    for i = 1, #lives do if lives[i] > now then n = n + 1 end end
    return n
end
local next_perf = 0
function T.frame()
    if not st.avail then return end
    local now = C.now()
    T.flush(now)
    if now < live_until then
        push_capsule(false)
        local b = (C.cfg.fx.dx11_glow and (tonumber(C.cfg.tfx.bloom) or 0)) or 0
        local FT = package.loaded['combatfx.features']
        if FT then b = FT.bloom(b) end                       -- f8: performance tier scales bloom (runtime only)
        if b ~= bloom_set then bloom_set = b; pcall(function() st.lib.rml_tfx_bloom(WIN, ID, b) end) end
    end
    if now >= next_perf and spawned > 0 then
        next_perf = now + 5000
        pcall(function() st.lib.rml_tfx_stats(statbuf, 1024) end)
        T.last_stats = ffi.string(statbuf)
        T.lua_ms = spawn_ms / math.max(1, spawned)
        T.last_line = string.format('tfx lua: %d spawns/5s, %.3f ms per spawn, %d combo updates; capsule=%s; dll: %s', spawned, T.lua_ms, set_calls, cap_src, T.last_stats or '')
        spawned, spawn_ms, set_calls = 0, 0, 0
        if C.cfg.tfx.log then print(C.TAG .. T.last_line) end
    end
end
function T.clear()
    coal, live_until, lives = {}, 0, {}
    if st.avail then pcall(function() st.lib.rml_tfx_clear(WIN, ID) end) end
end
function T.bind(win, id) WIN, ID = win or WIN, id or ID end

-- ---------------------------------------------------------------- live previews on the theme cards
-- One canvas per card (settings window). Each card loops: a hit in the theme's motion, a crit with punch,
-- flash and sparks, a heal floating up with its trail, and a stacked combo counter.
T.PWIN = 'CombatFxSettings'
local pv_sig = {}
local sz_w, sz_h
function T.preview_card(id, L, colors, custom)
    if not T.check() then return false end
    local lib = st.lib
    local w, h = 200, 74
    pcall(function()
        if not sz_w then sz_w = ffi.new('float[1]'); sz_h = ffi.new('float[1]') end
        if lib.rml_canvas_size(T.PWIN, id, sz_w, sz_h) == 1 and sz_w[0] >= 16 then w, h = sz_w[0], sz_h[0] end
    end)
    local rc = 0
    pcall(function() rc = tonumber(lib.rml_tfx_clear(T.PWIN, id)) or 0 end)
    if rc ~= 1 then return false end
    pcall(function() lib.rml_tfx_bloom(T.PWIN, id, math.min(0.6, tonumber(L.bloom) or 0)) end)
    local k = math.max(0.6, math.min(1.4, h / 74))
    local items = custom and T.preview_items(custom, w, h, k) or {
        { kind = 'melee', text = '1,234', x = w * 0.20, y = h * 0.72, size = 15 * k, delay = 0.00, dir = 1 },
        { kind = 'crit', text = '5,210!', x = w * 0.50, y = h * 0.62, size = 21 * k, delay = 0.45, crit = true, huge = true, dir = -1 },
        { kind = 'healin', text = '+820', x = w * 0.80, y = h * 0.80, size = 14 * k, delay = 0.95, dir = 1 },
        { kind = 'melee', text = '2,048', x = w * 0.24, y = h * 0.36, size = 13 * k, delay = 1.35, combo = 5, dir = -1 },
    }
    local period = 2.6
    for i, it in ipairs(items) do
        local life = 1.25
        local LL = it.look or L
        T.fill(desc, LL, { kind = it.kind, x = it.x, y = it.y, size = it.size, life = life, dir = it.dir, crit = it.crit, huge = it.huge,
            color = it.color or (colors and colors[it.kind]), travel_scale = 0.24 * k * (it.travel or 1), loop = true, gap = period - life, delay = it.delay, seed = 1000 + i * 77,
            combo = it.combo, prate_scale = 0.6, shake_scale = 0, alpha = it.alpha })
        desc[D.SHAKE] = 0
        pcall(function() lib.rml_tfx_spawn(T.PWIN, id, it.text, desc, D.N) end)
    end
    return true
end
-- f8: card samples for role / school cards. custom = { role = 'group', mod = ROLE_MOD } or { school = 'Fire' }
function T.preview_items(cu, w, h, k)
    local FT = package.loaded['combatfx.features']
    local mod = cu.mod or { size = 1, alpha = 1, travel = 1 }
    if cu.role then
        local kinds = ({ self = { 'melee', 'crit', 'spell' }, group = { 'group', 'group', 'group' }, incoming = { 'incoming', 'incoming', 'miss' }, pet = { 'pet', 'pet', 'pet' } })[cu.role]
        local texts = ({ self = { '1,234', '5,210!', '2,048' }, group = { '812', '1,460!', '644' }, incoming = { '-1,234', '-3,050', 'dodge' }, pet = { '412', '388', '506' } })[cu.role]
        local crit2 = cu.role == 'self' or cu.role == 'group'
        local out = {
            { kind = kinds[1], text = texts[1], x = w * 0.22, y = h * 0.72, size = 15 * k * mod.size, delay = 0.0, dir = 1 },
            { kind = kinds[2], text = texts[2], x = w * 0.52, y = h * 0.64, size = (crit2 and 20 or 16) * k * mod.size, delay = 0.45, crit = crit2, huge = crit2, dir = -1 },
            { kind = kinds[3], text = texts[3], x = w * 0.80, y = h * 0.78, size = 14 * k * mod.size, delay = 0.95, dir = 1 },
        }
        for _, it in ipairs(out) do it.alpha = mod.alpha; it.travel = mod.travel; it.look = cu.look end
        return out
    end
    local col = cu.colors or {}
    return {
        { kind = 'spell', text = '2,480', x = w * 0.24, y = h * 0.72, size = 16 * k, delay = 0.0, dir = 1, color = col.spell, look = cu.look },
        { kind = 'crit', text = '6,120!', x = w * 0.54, y = h * 0.62, size = 20 * k, delay = 0.45, crit = true, huge = true, dir = -1, color = col.crit, look = cu.look },
        { kind = 'dot', text = '310', x = w * 0.82, y = h * 0.78, size = 13 * k, delay = 0.95, dir = 1, color = col.dot, look = cu.look },
    }
end
function T.preview_cards(cards)
    if not T.check() then return 0 end
    local n = 0
    for _, c in ipairs(cards) do if T.preview_card(c.id, c.look, c.colors, c.custom) then n = n + 1 end end
    return n
end
function T.preview_clear(ids)
    if not st.avail then return end
    for _, id in ipairs(ids) do pcall(function() st.lib.rml_tfx_clear(T.PWIN, id) end) end
end
-- look of a theme table (preset or saved ini section)
function T.look_of(t, name)
    local L = T.copy(T.LOOKS[name or ''] or T.LOOKS[T.LOOK_FOR[name or ''] or ''] or T.LOOKS['Classic EQ Enhanced'])
    for _, k in ipairs(T.KEYS) do
        local v = t and t['x' .. k[1]]
        if v ~= nil then local nv = norm(k[1], v); if nv ~= nil then L[k[1]] = nv end end
    end
    return L
end
function T.status() return st.avail and 'ready' or st.why end

if not C.cfg.tfx then T.init_cfg() end
if not C._tfx_presets then C._tfx_presets = true; T.install_presets() end
return T
