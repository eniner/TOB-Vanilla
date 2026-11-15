-- combatfx DX11 canvas effects (MQ2RmlUi v4). No-ops if the canvas API is missing.
-- Idle: clear once then stop submitting so OnRender skips Draw.
local ffi = require('ffi')

local M = { _ready = false, _api = nil, REV = 't362-nimbuspick' }
local WIN, ID = 'CombatFxOverlay', 'cfx'
local W, H = 1920, 1080
-- number lane (damage text). Body/torso effects use body_xy(), not this.
local TX, TY = 0.585, 0.40
local BODY_TX, BODY_TY = 0.50, 0.48
local ADD, GLOW, SQUARE = 0x0100, 0x0200, 0x1000
-- SQUARE avoids the DLL's default 4-point spark sprite; ADD+GLOW keeps HDR bloom
local SPRITE_FX = ADD + GLOW + SQUARE

local parts, nparts = {}, 0
local rings, nrings = {}, 0
local CUR_R, RING_CAP, CUR_STYLE = 160, nil, nil
local emitter = nil
local EMIT_MS = 1500
local heartbeat, death_t, was_draw = false, 0, false
local sprbuf, sprcap = nil, 0
local sprExBuf, sprExCap = nil, 0
local HAS_EX, HAS_OV, TEX_OK = false, false, false
local TEX = { core = 0, streak = 0, flare = 0, ember = 0, shard = 0, droplet = 0, ring = 0, ribbon = 0, shell = 0, flame = 0 }
local statbuf = nil
local last_stat, t0 = 0, 0

local RT = {
    Fire = { 1.00, 0.48, 0.23 }, Cold = { 0.48, 0.78, 1.00 }, Poison = { 0.48, 0.82, 0.25 },
    Magic = { 0.69, 0.50, 1.00 }, Disease = { 0.78, 0.69, 0.38 }, Chromatic = { 1, 1, 1 },
    Prismatic = { 1, 1, 1 }, Corruption = { 0.63, 0.19, 0.31 }, Unresistable = { 1, 1, 1 },
}

local function core()
    local ok, C = pcall(require, 'combatfx.core')
    if ok then return C end
    return nil
end

local function now()
    local C = core()
    if C and C.now then return C.now() end
    return math.floor(os.clock() * 1000)
end

local function fx_on(key)
    local C = core()
    if not C or not C.cfg or not C.cfg.master then return false end
    local f = C.cfg.fx or {}
    if not f.dx11 then return false end
    if key and f[key] == false then return false end
    if (key == 'dx11_particles' or key == 'dx11_trails') and C.cfg.particles == false then return false end
    return true
end

local function parts_on()
    local C = core()
    return not (C and C.cfg and C.cfg.particles == false)
end

local function lite()
    local C = core()
    return C and C.cfg and C.cfg.lite
end

local function intensity()
    local C = core()
    local v = C and C.cfg and tonumber(C.cfg.intensity) or 80
    local fs = C and C.cfg and C.cfg.fxstyle
    local s = fs and tonumber(fs.intensity) or 100
    return ((v or 80) / 100) * math.max(0.50, math.min(2.00, (s or 100) / 100))
end
local TINT = nil
local function style_cfg()
    local C = core()
    return (C and C.cfg and C.cfg.fxstyle) or {}
end
local function style_scale()
    return math.max(0.50, math.min(2.00, (tonumber(style_cfg().size) or 100) / 100))
end
local function style_life()
    return math.max(0.50, math.min(2.00, (tonumber(style_cfg().duration) or 100) / 100))
end
local function custom_rgb()
    local fs = style_cfg()
    if (fs.color_mode or 'element') ~= 'custom' then return nil end
    local hex = tostring(fs.color or ''):lower()
    local r, g, b = hex:match('^#(%x%x)(%x%x)(%x%x)$')
    if not r then return nil end
    return tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255
end

local function pcap()
    return lite() and 220 or 900
end

local function load_api()
    pcall(ffi.cdef, [[
int rml_canvas_clear(const char* win, const char* id);
int rml_canvas_submit(const char* win, const char* id, const float* verts, int count, int mode);
int rml_canvas_line_width(const char* win, const char* id, float width);
int rml_canvas_circle(const char* win, const char* id, float x, float y, float radius, float r, float g, float b, float a, int segments, int mode);
int rml_canvas_size(const char* win, const char* id, float* out_w, float* out_h);
int rml_canvas_trail(const char* win, const char* id, float decay);
int rml_canvas_bloom(const char* win, const char* id, float strength);
int rml_canvas_sprites(const char* win, const char* id, const float* data, int count, int mode);
int rml_canvas_sprite(const char* win, const char* id, float x, float y, float rx, float ry, float r, float g, float b, float a, int mode);
]])
    pcall(ffi.cdef, [[int rml_canvas_stats(const char* win, const char* id, char* out, int cap);]])
    pcall(ffi.cdef, [[
int rml_canvas_texture_load(const char* win, const char* id, const char* path);
int rml_canvas_sprite_ex(const char* win, const char* id, float x, float y, float sx, float sy, float angle, float r, float g, float b, float a, int tex_id, int mode);
int rml_canvas_sprites_ex(const char* win, const char* id, const float* data, int count);
int rml_spawn_to_screen(int spawnId, float headOffset, float* sx, float* sy);
int rml_spawn_to_overlay(int spawnId, float heightFrac, float ovW, float ovH, float* sx, float* sy);
int rml_world_to_overlay(float x, float y, float z, float ovW, float ovH, float* sx, float* sy);
int rml_world_to_screen(float x, float y, float z, float* sx, float* sy);
]])
    -- Stage 3 Body FX on GPU particles (MQ2RmlUi API v5, rml_features() & 512); each optional
    for _, d in ipairs({
        'int rml_api_version();', 'int rml_features();',
        'int rml_fx_create(const char* win, const char* id, const float* desc, int n);',
        'int rml_fx_update(int h, const float* desc, int n);',
        'int rml_fx_anchor(int h, float x, float y, float px_per_unit, float depth01);',
        'int rml_fx_exclude(const char* win, const char* id, const float* p, int n);',
        'int rml_fx_destroy(int h);', 'int rml_fx_stats(int h, char* out, int cap);',
        'int rml_fx_mode(int mode);', 'int rml_canvas_probe();',
    }) do pcall(ffi.cdef, d) end
    local dll = os.getenv('MUSICVIZ_API_DLL') or os.getenv('COMBATFX_API_DLL')
    if dll and dll ~= '' then
        local ok, lib = pcall(ffi.load, dll)
        if ok and lib then return lib end
    end
    local ok, lib = pcall(ffi.load, 'MQ2RmlUi')
    if ok and lib then return lib end
    ok, lib = pcall(ffi.load, 'mq2rmlui')
    if ok and lib then return lib end
    return nil
end

function M.bind(win, id)
    if win and win ~= '' then WIN = win end
    if id and id ~= '' then ID = id end
end

function M.set_size(w, h)
    if w and w >= 8 then W = w end
    if h and h >= 8 then H = h end
end

function M.ok()
    return M._ready and M._api ~= nil
end

local function img_dir()
    local env = os.getenv('COMBATFX_IMG_DIR')
    if env and env ~= '' then
        return env
    end
    local ok, mq = pcall(require, 'mq')
    if ok and mq and mq.luaDir and mq.luaDir ~= '' then
        return mq.luaDir .. '/combatfx/img'
    end
    local p = os.getenv('COMBATFX_CANVAS_LUA')
    if p and p ~= '' then
        return (p:gsub('[/\\][^/\\]+$', '') .. '/img')
    end
    return 'lua/combatfx/img'
end

local function detect_ex(lib)
    if not lib then return false end
    local ok = pcall(function()
        return lib.rml_canvas_texture_load(nil, nil, '')
    end)
    return ok
end

local function load_textures()
    if TEX_OK or not HAS_EX or not M._api then return TEX_OK end
    local dir = img_dir()
    local last = dir:sub(-1)
    local sep = (last == '/' or last == '\\') and '' or '/'
    local required = {
        core = 'fx_core.png', streak = 'fx_streak.png', flare = 'fx_flare.png',
        ember = 'fx_ember.png', shard = 'fx_shard.png', droplet = 'fx_droplet.png',
        ring = 'fx_ring.png',
    }
    local extra = {
        ribbon = 'fx_ribbon.png', shell = 'fx_shell.png', flame = 'fx_flame.png',
        flame0 = 'fx_flame0.png', flame1 = 'fx_flame1.png', flame2 = 'fx_flame2.png', flame3 = 'fx_flame3.png',
        smoke = 'fx_smoke.png', ice0 = 'fx_ice0.png', ice1 = 'fx_ice1.png', ice2 = 'fx_ice2.png',
        crackle = 'fx_crackle.png', mist = 'fx_mist.png', snow = 'fx_snow.png',
        gust = 'fx_gust.png', leaf0 = 'fx_leaf0.png', leaf1 = 'fx_leaf1.png', dust = 'fx_dust.png',
        splash = 'fx_splash.png', puddle = 'fx_puddle.png', wdrop = 'fx_wdrop.png',
        bubble = 'fx_bubble.png', drip = 'fx_drip.png', gas = 'fx_gas.png',
        spore = 'fx_spore.png', speck = 'fx_speck.png',
        rock0 = 'fx_rock0.png', rock1 = 'fx_rock1.png', rock2 = 'fx_rock2.png', pebble = 'fx_pebble.png',
        crack = 'fx_crack.png', bolt = 'fx_bolt.png',
        splat0 = 'fx_splat0.png', splat1 = 'fx_splat1.png', splat2 = 'fx_splat2.png', bdrop = 'fx_bdrop.png',
        rune = 'fx_rune.png', glyph = 'fx_glyph.png', void = 'fx_void.png', tendril = 'fx_tendril.png',
        ray = 'fx_ray.png', halo = 'fx_halo.png', foam = 'fx_foam.png',
        auradisc = 'fx_auradisc.png', auracaust0 = 'fx_auracaust0.png',
        auracaust1 = 'fx_auracaust1.png', auracaust2 = 'fx_auracaust2.png',
        aurarim = 'fx_aurarim.png', auraripple = 'fx_auraripple.png',
        sprunering = 'fx_sp_runering.png', spsigil = 'fx_sp_sigil.png',
        splava = 'fx_sp_lava.png', spcracks = 'fx_sp_cracks.png',
        spbolt0 = 'fx_sp_bolt0.png', spbolt1 = 'fx_sp_bolt1.png', spbolt2 = 'fx_sp_bolt2.png',
        spnebula0 = 'fx_sp_nebula0.png', spnebula1 = 'fx_sp_nebula1.png',
        spdarkcore = 'fx_sp_darkcore.png', sphex = 'fx_sp_hex.png',
        sppool = 'fx_sp_pool.png', spritual = 'fx_sp_ritual.png',
        sppillar = 'fx_sp_pillar.png',
        mkskull = 'fx_mk_skull.png', mkstar = 'fx_mk_star.png',
        mkcross = 'fx_mk_crosshair.png', mkdiamond = 'fx_mk_diamond.png',
        mkexcl = 'fx_mk_exclamation.png', mkcrown = 'fx_mk_crown.png',
        mkshield = 'fx_mk_shield.png', mkflame = 'fx_mk_flame.png',
        mkglow = 'fx_mk_glow.png', mkbeam = 'fx_mk_beam.png',
        bxshell = 'fx_bxshell.png', bxhalo = 'fx_bxhalo.png',
        bxray = 'fx_bxray.png', bxcore = 'fx_bxcore.png',
        bxpool = 'fx_bxpool.png', bxspark = 'fx_bxspark.png',
        bxsoft = 'fx_bxsoft.png', bxglow = 'fx_bxglow.png',
        bxbeam = 'fx_bxbeam.png', bxrim = 'fx_bxrim.png',
        bxarc = 'fx_bxarc.png', bxdisc = 'fx_bxdisc.png',
        bxnimb = 'fx_bxnimb.png',
        mkcyl = 'fx_mk_cyl.png', mkfloor = 'fx_mk_floor.png',
    }
    local all = true
    for k, fn in pairs(required) do
        local id = 0
        pcall(function()
            id = tonumber(M._api.rml_canvas_texture_load(WIN, ID, dir .. sep .. fn)) or 0
        end)
        TEX[k] = id
        if id <= 0 then all = false end
    end
    for k, fn in pairs(extra) do
        local id = 0
        pcall(function()
            id = tonumber(M._api.rml_canvas_texture_load(WIN, ID, dir .. sep .. fn)) or 0
        end)
        TEX[k] = id
    end
    TEX_OK = all
    return TEX_OK
end

local function ensure()
    if M._ready then return true end
    local t = now()
    if M._next_try and t < M._next_try then return false end
    M._next_try = t + 1000
    local lib = load_api()
    if not lib or not lib.rml_canvas_clear or not lib.rml_canvas_sprites then
        M._ready = false
        return false
    end
    M._api = lib
    M._ready = true
    sprcap = 256
    sprbuf = ffi.new('float[?]', sprcap * 8)
    HAS_EX = detect_ex(lib)
    HAS_OV = pcall(function() return lib.rml_spawn_to_overlay(0, 0.58, 1920, 1080, nil, nil) end)
    if HAS_EX then
        sprExCap = 1024
        sprExBuf = ffi.new('float[?]', sprExCap * 11)
        load_textures()
    end
    return true
end

local function use_ex()
    if M._proof_ex then return true end
    return HAS_EX and TEX_OK and (TEX.streak or 0) > 0 and (TEX.core or 0) > 0
end
function M.using_ex()
    return use_ex()
end
function M.using_ov()
    return HAS_OV
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

-- depth +1 is in front of the mob (larger, brighter); -1 is behind.
local function depth_fac(p)
    local d = tonumber(p and p.depth) or 0
    if d > 1 then d = 1 elseif d < -1 then d = -1 end
    local front = 0.5 + 0.5 * d
    return 0.64 + 0.52 * front, 0.42 + 0.58 * front
end

-- Cap HDR so overlapping additive frost/ice cannot clip to a solid white blob.
local function clip_tone(p, cr, cg, cb)
    local cap = p and p.tone_cap
    local tex = p and p.tex
    if not cap then
        if (p and p.palette == 'cold') or tex == 'crackle' or tex == 'mist' or tex == 'snow'
            or (type(tex) == 'string' and tex:sub(1, 3) == 'ice') then
            cap = 1.05
        end
    end
    if cap then
        if cr > cap then cr = cap end
        if cg > cap then cg = cap end
        if cb > cap then cb = cap end
    end
    return cr, cg, cb
end

-- spark colors stay near 1.2 at birth and cool; cores are hotter and shorter-lived
local function palette_colors(name, u)
    if name == 'cold' then
        if u > 0.65 then
            local t = (u - 0.65) / 0.35
            return lerp(1.10, 1.22, t), lerp(1.20, 1.28, t), lerp(1.30, 1.35, t)
        elseif u > 0.30 then
            local t = (u - 0.30) / 0.35
            return lerp(0.30, 1.10, t), lerp(0.72, 1.20, t), lerp(1.18, 1.30, t)
        else
            local t = u / 0.30
            return lerp(0.16, 0.30, t), lerp(0.38, 0.72, t), lerp(0.95, 1.18, t)
        end
    elseif name == 'poison' then
        if u > 0.65 then
            local t = (u - 0.65) / 0.35
            return lerp(1.05, 1.20, t), lerp(1.22, 1.30, t), lerp(0.85, 1.15, t)
        elseif u > 0.30 then
            local t = (u - 0.30) / 0.35
            return lerp(0.40, 1.05, t), lerp(0.95, 1.22, t), lerp(0.22, 0.85, t)
        else
            local t = u / 0.30
            return lerp(0.14, 0.40, t), lerp(0.42, 0.95, t), lerp(0.06, 0.22, t)
        end
    elseif name == 'magic' then
        if u > 0.60 then
            local t = (u - 0.60) / 0.40
            return lerp(1.12, 1.22, t), lerp(1.00, 1.18, t), lerp(1.28, 1.35, t)
        else
            local t = u / 0.60
            return lerp(0.42, 1.12, t), lerp(0.22, 1.00, t), lerp(0.95, 1.28, t)
        end
    elseif name == 'crit' then
        if u > 0.62 then
            local t = (u - 0.62) / 0.38
            return lerp(1.28, 1.38, t), lerp(1.18, 1.34, t), lerp(0.72, 1.22, t)
        elseif u > 0.30 then
            local t = (u - 0.30) / 0.32
            return lerp(1.22, 1.28, t), lerp(0.78, 1.18, t), lerp(0.22, 0.72, t)
        else
            local t = u / 0.30
            return lerp(0.95, 1.22, t), lerp(0.38, 0.78, t), lerp(0.08, 0.22, t)
        end
    elseif name == 'storm' then
        if u > 0.55 then
            local t = (u - 0.55) / 0.45
            return lerp(1.25, 1.45, t), lerp(1.35, 1.55, t), lerp(1.70, 2.10, t)
        else
            local t = u / 0.55
            return lerp(0.35, 1.25, t), lerp(0.55, 1.35, t), lerp(1.15, 1.70, t)
        end
    elseif name == 'shadow' then
        if u > 0.55 then
            local t = (u - 0.55) / 0.45
            return lerp(0.85, 1.20, t), lerp(0.28, 0.55, t), lerp(1.15, 1.55, t)
        else
            local t = u / 0.55
            return lerp(0.18, 0.85, t), lerp(0.04, 0.28, t), lerp(0.32, 1.15, t)
        end
    elseif name == 'holy' then
        if u > 0.55 then
            local t = (u - 0.55) / 0.45
            return lerp(1.35, 1.55, t), lerp(1.25, 1.48, t), lerp(0.85, 1.25, t)
        else
            local t = u / 0.55
            return lerp(1.05, 1.35, t), lerp(0.78, 1.25, t), lerp(0.32, 0.85, t)
        end
    elseif name == 'blood' then
        if u > 0.55 then
            local t = (u - 0.55) / 0.45
            return lerp(1.35, 1.55, t), lerp(0.22, 0.55, t), lerp(0.16, 0.35, t)
        else
            local t = u / 0.55
            return lerp(0.55, 1.35, t), lerp(0.04, 0.22, t), lerp(0.04, 0.16, t)
        end
    elseif name == 'disease' then
        if u > 0.55 then
            local t = (u - 0.55) / 0.45
            return lerp(0.85, 1.10, t), lerp(0.70, 0.88, t), lerp(0.22, 0.40, t)
        else
            local t = u / 0.55
            return lerp(0.35, 0.85, t), lerp(0.28, 0.70, t), lerp(0.08, 0.22, t)
        end
    else
        -- fire: white -> gold -> orange -> red
        if u > 0.70 then
            local t = (u - 0.70) / 0.30
            return lerp(1.22, 1.34, t), lerp(1.05, 1.26, t), lerp(0.58, 1.12, t)
        elseif u > 0.38 then
            local t = (u - 0.38) / 0.32
            return lerp(1.18, 1.18, t), lerp(0.52, 1.02, t), lerp(0.12, 0.62, t)
        else
            local t = u / 0.38
            return lerp(0.78, 1.18, t), lerp(0.12, 0.52, t), lerp(0.03, 0.12, t)
        end
    end
end

local function core_colors(name, u)
    if name == 'cold' then
        if u > 0.48 then
            local t = (u - 0.48) / 0.52
            return lerp(1.25, 1.85, t), lerp(1.55, 2.10, t), lerp(1.95, 2.25, t)
        else
            local t = u / 0.48
            return lerp(0.22, 1.35, t), lerp(0.50, 1.65, t), lerp(1.05, 2.10, t)
        end
    elseif name == 'poison' then
        if u > 0.48 then
            local t = (u - 0.48) / 0.52
            return lerp(1.20, 1.90, t), lerp(1.70, 2.35, t), lerp(1.05, 1.70, t)
        else
            local t = u / 0.48
            return lerp(0.18, 1.20, t), lerp(0.45, 1.70, t), lerp(0.10, 1.05, t)
        end
    elseif name == 'magic' then
        if u > 0.48 then
            local t = (u - 0.48) / 0.52
            return lerp(1.40, 2.05, t), lerp(1.15, 1.80, t), lerp(2.05, 2.45, t)
        else
            local t = u / 0.48
            return lerp(0.40, 1.40, t), lerp(0.18, 1.15, t), lerp(0.90, 2.05, t)
        end
    elseif name == 'crit' then
        if u > 0.48 then
            local t = (u - 0.48) / 0.52
            return lerp(1.70, 2.55, t), lerp(1.50, 2.30, t), lerp(0.95, 1.85, t)
        else
            local t = u / 0.48
            return lerp(1.15, 1.70, t), lerp(0.55, 1.50, t), lerp(0.12, 0.95, t)
        end
    elseif name == 'storm' then
        if u > 0.48 then
            local t = (u - 0.48) / 0.52
            return lerp(1.70, 2.35, t), lerp(1.85, 2.45, t), lerp(2.15, 2.70, t)
        else
            local t = u / 0.48
            return lerp(0.55, 1.70, t), lerp(0.80, 1.85, t), lerp(1.35, 2.15, t)
        end
    elseif name == 'shadow' then
        if u > 0.48 then
            local t = (u - 0.48) / 0.52
            return lerp(1.15, 1.70, t), lerp(0.35, 0.70, t), lerp(1.55, 2.15, t)
        else
            local t = u / 0.48
            return lerp(0.25, 1.15, t), lerp(0.06, 0.35, t), lerp(0.55, 1.55, t)
        end
    elseif name == 'holy' then
        if u > 0.48 then
            local t = (u - 0.48) / 0.52
            return lerp(1.85, 2.55, t), lerp(1.70, 2.35, t), lerp(1.15, 1.85, t)
        else
            local t = u / 0.48
            return lerp(1.15, 1.85, t), lerp(0.95, 1.70, t), lerp(0.45, 1.15, t)
        end
    elseif name == 'blood' then
        if u > 0.48 then
            local t = (u - 0.48) / 0.52
            return lerp(1.85, 2.45, t), lerp(0.35, 0.75, t), lerp(0.22, 0.48, t)
        else
            local t = u / 0.48
            return lerp(0.85, 1.85, t), lerp(0.08, 0.35, t), lerp(0.06, 0.22, t)
        end
    else
        if u > 0.48 then
            local t = (u - 0.48) / 0.52
            return lerp(1.55, 2.45, t), lerp(1.25, 2.05, t), lerp(0.65, 1.45, t)
        else
            local t = u / 0.48
            return lerp(0.95, 1.55, t), lerp(0.22, 1.25, t), lerp(0.04, 0.65, t)
        end
    end
end

local function spawn(x, y, vx, vy, life, r, g, b, a, rx, ry)
    local capn = pcap()
    local i
    if nparts >= capn then
        local oldest, oi = 1e9, 1
        for k = 1, nparts do
            if parts[k] and parts[k].life and parts[k].life < oldest then oldest, oi = parts[k].life, k end
        end
        i = oi
    else
        nparts = nparts + 1
        i = nparts
        if not parts[i] then parts[i] = {} end
    end
    local p = parts[i]
    p.x, p.y, p.vx, p.vy = x, y, vx, vy
    local lm = style_life()
    p.life, p.max = life * lm, life * lm
    p.r, p.g, p.b, p.a = r, g, b, a
    p.tint = TINT and { TINT[1], TINT[2], TINT[3] } or nil
    p.rx, p.ry = rx, ry
    p.spin, p.kind = 0, nil
    p.streak, p.thick, p.drag, p.grav = nil, nil, nil, nil
    p.tip, p.drip, p.fade_to, p.flicker, p.hdr = nil, nil, nil, nil, nil
    p.tex, p.orient, p.palette, p.core = nil, nil, nil, nil
    p.follow, p.orbit, p.orb_r0, p.orb_r1, p.orb_a0, p.orb_spin, p.orb_squash = nil, nil, nil, nil, nil, nil, nil
    p.orb_y0, p.orb_rise, p.depth = nil, nil, nil
    p.rot, p.spin_r, p.blend, p.frames, p.fps = nil, nil, nil, nil, nil
    p.delay, p.grow0, p.grow1, p.bounce, p.ground, p.turb, p.shatter, p.fade_late = nil, nil, nil, nil, nil, nil, nil, nil
    p.blink_on, p.blink_off, p.blink_phase = nil, nil, nil
    p.fixed_ang, p.max_r = nil, (CUR_R and CUR_R > 1) and (CUR_R * 1.60) or nil
    p.style = CUR_STYLE
    return p
end

local function emit_tex_burst(x, y, n, speed, life, kind, palette, tex, opts)
    opts = opts or {}
    n = math.min(n, 24)
    local grav = opts.grav or 28
    local drag = opts.drag or 1.8
    local off0 = opts.off or 13
    for i = 1, n do
        local a = (i / n) * 6.28318 + math.random() * 0.26
        local s = speed * (0.52 + math.random() * 0.62)
        local vx, vy = math.cos(a) * s, math.sin(a) * s
        if opts.rise then vy = vy - math.abs(s) * 0.26 end
        local slen = (opts.len or 60) * (0.78 + math.random() * 0.44)
        local thick = (opts.thick or 18) * (0.82 + math.random() * 0.32)
        local ux, uy = math.cos(a), math.sin(a)
        local off = off0 * (0.80 + math.random() * 0.45)
        local p = spawn(x + ux * off, y + uy * off, vx, vy, life * (0.72 + math.random() * 0.40),
            1.2, 1.1, 0.9, 0.90, thick * 0.5, slen * 0.5)
        p.kind = kind
        p.tex = tex
        p.streak = slen
        p.thick = thick
        p.drag = drag
        p.grav = grav
        p.orient = true
        p.palette = palette
        p.flicker = math.random() * 6.28318
        if opts.drip then p.drip = true end
    end
end


local function emit_burst(x, y, n, speed, life, r, g, b, rx, rise, kind)
    n = math.min(n, 48)
    -- hot white-gold start, cool toward a deeper ember of the given color
    local hr, hg, hb = 1.85, 1.62, 1.08
    local cool = { math.max(0.28, r * 0.75), math.max(0.06, g * 0.28), math.max(0.03, b * 0.10) }
    if kind == 'death' then
        hr, hg, hb = 1.4, 0.35, 0.22
        cool = { 0.45, 0.04, 0.06 }
    end
    for i = 1, n do
        local a = (i / n) * 6.28318 + math.random() * 0.4
        local s = speed * (0.45 + math.random() * 0.75)
        local vx, vy = math.cos(a) * s, math.sin(a) * s
        if rise then vy = vy - math.abs(s) * 0.35 end
        local slen = (rx * 5.6) * (0.75 + math.random() * 0.55)
        local thick = math.max(1.4, rx * 0.38) * (0.80 + math.random() * 0.40)
        local p = spawn(x, y, vx, vy, life * (0.65 + math.random() * 0.55), hr, hg, hb, 0.95, thick, slen)
        p.kind = kind
        p.streak = slen
        p.thick = thick
        p.drag = 1.7
        p.grav = rise and 55 or 22
        p.tip = true
        p.hdr = true
        p.flicker = math.random() * 6.28318
        p.fade_to = cool
    end
end

local function clear_kind(kind)
    local i = 1
    while i <= nparts do
        local p = parts[i]
        if not p then
            nparts = i - 1
            break
        end
        if p.kind == kind then
            parts[i], parts[nparts] = parts[nparts], parts[i]
            nparts = nparts - 1
        else
            i = i + 1
        end
    end
    i = 1
    while i <= nrings do
        local r = rings[i]
        if not r then
            nrings = i - 1
            break
        end
        if r.kind == kind then
            rings[i], rings[nrings] = rings[nrings], rings[i]
            nrings = nrings - 1
        else
            i = i + 1
        end
    end
end

-- proc/crit/preview share this set so a new burst cannot leave the previous
-- style (or the other channel) animating. heal/kill/flare/death are left alone.
local COMBAT_FX_KIND = {
    proc = true, proc_core = true, proc_ember = true,
    crit = true, crit_ember = true,
}

local function clear_combat_fx()
    emitter = nil
    local i = 1
    while i <= nparts do
        local p = parts[i]
        if not p then
            nparts = i - 1
            break
        end
        if COMBAT_FX_KIND[p.kind] then
            parts[i], parts[nparts] = parts[nparts], parts[i]
            nparts = nparts - 1
        else
            i = i + 1
        end
    end
    i = 1
    while i <= nrings do
        local r = rings[i]
        if not r then
            nrings = i - 1
            break
        end
        if COMBAT_FX_KIND[r.kind] then
            rings[i], rings[nrings] = rings[nrings], rings[i]
            nrings = nrings - 1
        else
            i = i + 1
        end
    end
end

local function norm_rt(rt)
    if rt == nil then return 'Magic' end
    rt = tostring(rt):gsub('^%s+', ''):gsub('%s+$', '')
    if rt == '' then return 'Magic' end
    local lower = rt:lower()
    local alias = {
        fire = 'Fire', flame = 'Fire', burning = 'Fire',
        cold = 'Cold', ice = 'Cold', frost = 'Cold',
        poison = 'Poison',
        magic = 'Magic', magical = 'Magic',
        disease = 'Disease',
        chromatic = 'Chromatic', prismatic = 'Prismatic',
        corruption = 'Corruption',
        unresistable = 'Unresistable', unresistible = 'Unresistable',
        ['non-melee'] = 'Magic', nonmelee = 'Magic',
    }
    if alias[lower] then return alias[lower] end
    if RT[rt] then return rt end
    for k, _ in pairs(RT) do
        if k:lower() == lower then return k end
    end
    return 'Magic'
end

local function add_ring(x, y, r0, r1, life, r, g, b, kind)
    if nrings >= 24 then
        table.remove(rings, 1); nrings = nrings - 1
    end
    -- style shells are spawned at the origin; cap growth to ~1.2x the burst radius
    if RING_CAP and RING_CAP > 0 and x == 0 and y == 0 then
        local big = math.max(math.abs(r0 or 0), math.abs(r1 or 0))
        if big > RING_CAP and big > 0 then
            local s = RING_CAP / big
            r0, r1 = (r0 or 0) * s, (r1 or 0) * s
        end
    end
    nrings = nrings + 1
    local lm = style_life()
    rings[nrings] = { x = x, y = y, r0 = r0, r1 = r1, life = life * lm, max = life * lm, r = r, g = g, b = b, kind = kind,
        follow = false, sx = 1, sy = 1, spin = 0, tex = 'ring', tint = TINT and { TINT[1], TINT[2], TINT[3] } or nil, style = CUR_STYLE }
end


local AX, AY = W * BODY_TX, H * BODY_TY
local ANCHOR_OK, ANCHOR_SRC = false, 'fallback'
local last_good_ax, last_good_ay, last_good_t = nil, nil, 0
local BODY_H, last_good_bh = nil, nil
local _sx, _sy

function M.body_xy()
    return AX, AY
end

function M.anchor_info()
    return AX, AY, ANCHOR_SRC, ANCHOR_OK
end

local function target_id()
    local ok, mq = pcall(require, 'mq')
    if not ok or not mq then return 0 end
    local id = 0
    pcall(function()
        if mq.TLO and mq.TLO.Target then id = tonumber(mq.TLO.Target.ID()) or 0 end
    end)
    return id
end

local function overlay_ok(x, y)
    if not x or not y then return false end
    if x ~= x or y ~= y then return false end
    if math.abs(x) > 1e6 or math.abs(y) > 1e6 then return false end
    return x > -48 and y > -48 and x < W + 48 and y < H + 48
end

local function viewport_wh()
    local sw, sh = 1920, 1009
    pcall(function()
        local mq = require('mq')
        local vw = tonumber(mq.TLO.EverQuest.ViewportXMax()) or 0
        local vh = tonumber(mq.TLO.EverQuest.ViewportYMax()) or 0
        if vw > 100 and vh > 100 then sw, sh = vw, vh end
    end)
    return sw, sh
end

local function target_spawn_height()
    local h, ah = 0, 0
    pcall(function()
        local mq = require('mq')
        if not (mq and mq.TLO and mq.TLO.Target) then return end
        local T = mq.TLO.Target
        if T.Height then h = tonumber(T.Height()) or 0 end
        if T.AvatarHeight then ah = tonumber(T.AvatarHeight()) or 0 end
    end)
    -- Same rule as the DLL: prefer AvatarHeight so an ogre dummy is not
    -- sized to a human collision capsule (~6.9) while the mesh is taller.
    local use = (ah and ah > 0.5 and ah < 40) and ah or h
    if use and use > 0.5 and use < 40 then return use end
    return 6.87
end

-- rml_spawn_to_screen(id, worldZ offset) -> top-left screen pixels, then
-- scaled into the overlay canvas (W x H) using the 3D viewport.
local function project_screen(id, hoff)
    if not (M._api and M._api.rml_spawn_to_screen and id and id > 0) then
        return nil, nil, -1
    end
    if not _sx then _sx = ffi.new('float[1]'); _sy = ffi.new('float[1]') end
    local rc = -1
    pcall(function()
        rc = tonumber(M._api.rml_spawn_to_screen(id, hoff, _sx, _sy)) or -1
    end)
    if rc < 0 then return nil, nil, rc end
    local sw, sh = viewport_wh()
    local x = _sx[0] * W / sw
    local y = _sy[0] * H / sh
    if not x or not y or x ~= x or y ~= y then return nil, nil, -1 end
    if math.abs(x) > 1e6 or math.abs(y) > 1e6 then return nil, nil, -1 end
    -- feet of a close-up often clip the bottom; still usable for height
    if x < -W * 0.35 or x > W * 1.35 or y < -H * 0.35 or y > H * 1.35 then
        return x, y, 0
    end
    return x, y, 1
end

local function update_anchor()
    ANCHOR_OK, ANCHOR_SRC = false, 'none'
    if (M._debug_body_h and M._debug_body_h > 0) or (M._debug_half_h and M._debug_half_h > 0) then
        BODY_H = M._debug_body_h or M._debug_half_h
        if M._debug_ax and M._debug_ay then
            AX, AY = M._debug_ax, M._debug_ay
        end
        ANCHOR_OK, ANCHOR_SRC = true, 'debug'
        M.anchor_x, M.anchor_y, M.anchor_src = AX, AY, ANCHOR_SRC
        return true
    end
    local id = target_id()
    local have_w2s = M._api and (HAS_OV or (M._api.rml_spawn_to_screen ~= nil))
    -- Headless proofs have no w2s export, so they keep a dummy origin.
    if not have_w2s then
        AX, AY = W * BODY_TX, H * BODY_TY
        ANCHOR_OK, ANCHOR_SRC = true, 'headless'
        M.anchor_x, M.anchor_y, M.anchor_src = AX, AY, ANCHOR_SRC
        return true
    end
    if id > 0 and M._api.rml_spawn_to_screen then
        local head_h = target_spawn_height()
        local fx, fy, frc = project_screen(id, 0)
        local hx, hy, hrc = project_screen(id, head_h)
        if frc >= 0 and hrc >= 0 and fx and hx and fy and hy then
            local mx, my = (fx + hx) * 0.5, (fy + hy) * 0.5
            local bh = math.sqrt((hx - fx) * (hx - fx) + (hy - fy) * (hy - fy))
            if bh >= 16 and bh <= (H * 1.35) then
                AX, AY = mx, my
                BODY_H = bh
                last_good_bh = bh
                ANCHOR_OK, ANCHOR_SRC = true, 'w2s-body'
                last_good_ax, last_good_ay, last_good_t = AX, AY, now()
                M.anchor_x, M.anchor_y, M.anchor_src = AX, AY, ANCHOR_SRC
                return true
            end
        end
    end
    if last_good_ax and (now() - last_good_t) < 450 then
        AX, AY = last_good_ax, last_good_ay
        if last_good_bh then BODY_H = last_good_bh end
        ANCHOR_OK, ANCHOR_SRC = true, 'w2s-hold'
    else
        ANCHOR_SRC = (id > 0) and 'no-proj' or 'no-target'
        ANCHOR_OK = false
    end
    M.anchor_x, M.anchor_y, M.anchor_src = AX, AY, ANCHOR_SRC
    return ANCHOR_OK
end

-- ----------------------------------------------------------------
-- Feet aura + run trail (t345-show). Separate from proc kinds so
-- clear_combat_fx never wipes them. Drawn under combat bursts.
-- World points use rml_world_to_screen (same ProjectWorldSeh YXZ
-- remap as spawn_to_screen); no DLL change.
-- ----------------------------------------------------------------
local FEET = { x = 0, y = 0, rx = 52, ry = 18, ok = false, src = 'none' }
local TRAIL, TRAIL_N = {}, 0
local TRAIL_CAP, TRAIL_LIFE, TRAIL_DT = 40, 1600, 80
local last_trail_sample, last_wx, last_wy, last_wz = 0, nil, nil, nil
local AURA_SPIN = 0
-- Disc radius is 0.56 * avatar height: diameter ~1.12*height
-- ~= 3x shoulder width (shoulders ~0.38 of height).
local AURA_HEIGHT_R = 0.56
local preview_aura_t, preview_aura_style = 0, nil
local preview_trail_t, preview_trail_style = 0, nil

local STYLE_LOOK = {
    inferno = { 1.22, 0.42, 0.10, 'ring', 'ember', 14, 'flame0' },
    frost   = { 0.52, 0.88, 1.18, 'ring', 'ice0', 12, 'mist' },
    toxic   = { 0.38, 1.05, 0.22, 'ring', 'bubble', 12, 'gas' },
    disease = { 0.88, 0.70, 0.22, 'ring', 'spore', 12, 'speck' },
    arcane  = { 0.82, 0.42, 1.32, 'rune', 'glyph', 12, 'ember' },
    storm   = { 0.55, 0.86, 1.42, 'ring', 'ember', 10, 'bolt' },
    shadow  = { 0.48, 0.16, 0.82, 'void', 'ember', 12, 'tendril' },
    holy    = { 1.30, 1.14, 0.52, 'halo', 'flare', 10, 'ember' },
    blood   = { 1.12, 0.12, 0.10, 'ring', 'splat0', 10, 'bdrop' },
    wind    = { 0.72, 0.92, 0.68, 'ring', 'leaf0', 10, 'dust' },
    water   = { 0.42, 0.80, 1.22, 'ring', 'wdrop', 10, 'foam' },
    earth   = { 0.78, 0.52, 0.28, 'ring', 'pebble', 10, 'dust' },
}

local function look_of(style)
    return STYLE_LOOK[style] or STYLE_LOOK.inferno
end

local function ground_cfg()
    local C = core()
    local cfg = C and C.cfg
    return cfg and cfg.feetaura, cfg and cfg.runtrail
end

local function aura_wanted()
    if preview_aura_t > 0 and now() < preview_aura_t then return true, preview_aura_style or 'inferno' end
    local NA = package.loaded['combatfx.aura']          -- t436: a native EQ aura replaces the screen-drawn disc
    if NA and NA.active and NA.active() then return false, 'inferno' end
    local fa = ground_cfg()
    if fa and fa.on then return true, fa.style or 'inferno' end
    return false, 'inferno'
end

local function trail_wanted()
    if preview_trail_t > 0 and now() < preview_trail_t then return true, preview_trail_style or 'inferno' end
    local _, rt = ground_cfg()
    if rt and rt.on then return true, rt.style or 'inferno' end
    return false, 'inferno'
end

local function me_id()
    if M._debug_me_id then return M._debug_me_id end
    local id = 0
    pcall(function()
        local mq = require('mq')
        if mq and mq.TLO and mq.TLO.Me then id = tonumber(mq.TLO.Me.ID()) or 0 end
    end)
    return id
end

local function me_xyz()
    if M._debug_xyz then return M._debug_xyz[1], M._debug_xyz[2], M._debug_xyz[3] end
    local x, y, z = 0, 0, 0
    pcall(function()
        local mq = require('mq')
        if not (mq and mq.TLO and mq.TLO.Me) then return end
        x = tonumber(mq.TLO.Me.X()) or 0
        y = tonumber(mq.TLO.Me.Y()) or 0
        z = tonumber(mq.TLO.Me.Z()) or 0
    end)
    return x, y, z
end

local function me_heading()
    if M._debug_heading then return M._debug_heading end
    local deg = 0
    pcall(function()
        local mq = require('mq')
        if mq and mq.TLO and mq.TLO.Me and mq.TLO.Me.Heading then
            if mq.TLO.Me.Heading.Degrees then
                deg = tonumber(mq.TLO.Me.Heading.Degrees()) or 0
            else
                deg = tonumber(mq.TLO.Me.Heading()) or 0
                if deg > 6.3 then deg = deg * (360 / 512) end
            end
        end
    end)
    return deg * 0.017453292519943
end

local function me_height()
    if M._debug_me_height and M._debug_me_height > 0.5 then
        return M._debug_me_height
    end
    local ah, hz = 0, 0
    pcall(function()
        local mq = require('mq')
        local Me = mq and mq.TLO and mq.TLO.Me
        if not Me then return end
        if Me.AvatarHeight then ah = tonumber(Me.AvatarHeight()) or 0 end
        if Me.Height then hz = tonumber(Me.Height()) or 0 end
    end)
    if ah and ah > 0.5 and ah < 40 then return ah end
    if hz and hz > 0.5 and hz < 40 then return hz end
    return 5.6
end

-- EQ spawn Z is often mid-body (t343 used spawn_to_screen(id,0) / Me.Z()
-- and the ring sat at the knees). Prefer Me.FloorZ; otherwise drop
-- half a body from spawn Z. Trails keep using me_xyz() unchanged.
local function me_floor_z(wz)
    if M._debug_floor_z ~= nil then
        return M._debug_floor_z, 'debug-floor'
    end
    local height = me_height()
    local floor_z = nil
    pcall(function()
        local mq = require('mq')
        local Me = mq and mq.TLO and mq.TLO.Me
        if Me and Me.FloorZ then floor_z = tonumber(Me.FloorZ()) end
    end)
    if floor_z and floor_z == floor_z then
        local dz = (wz or 0) - floor_z
        if dz >= -0.15 and dz <= height * 1.35 then
            if dz >= 0.25 then
                return floor_z, 'FloorZ'
            end
            return floor_z, 'FloorZ~Z'
        end
    end
    return (wz or 0) - height * 0.52, 'Z-halfH'
end

-- Named world (X, Y, Z) — same order ReadSpawnXYZ feeds ProjectWorldSeh.
local function project_world(wx, wy, wz)
    if M._debug_w2s then
        local x, y, rc = M._debug_w2s(wx, wy, wz)
        return x, y, rc or 1
    end
    if not _sx then _sx = ffi.new('float[1]'); _sy = ffi.new('float[1]') end
    if M._api and M._api.rml_world_to_screen then
        local rc = -1
        pcall(function()
            rc = tonumber(M._api.rml_world_to_screen(wx, wy, wz, _sx, _sy)) or -1
        end)
        if rc >= 0 then
            local sw, sh = viewport_wh()
            local x = _sx[0] * W / sw
            local y = _sy[0] * H / sh
            if x and y and x == x and y == y then return x, y, rc end
        end
    end
    if M._api and M._api.rml_world_to_overlay then
        local rc = -1
        pcall(function()
            rc = tonumber(M._api.rml_world_to_overlay(wx, wy, wz, W, H, _sx, _sy)) or -1
        end)
        if rc >= 0 then return _sx[0], _sy[0], rc end
    end
    return nil, nil, -1
end

-- aura rework: on-screen ellipse of a WORLD circle (radius R on the plane z) from 16 projected points.
-- Returns centre x, y, half extents rx, ry and the number of points that projected (camera-stable: the
-- size follows the world radius and the distance only, not the camera yaw or pitch).
local function world_ellipse(wx, wy, z, R)
    local x0, x1, y0, y1, n = 1e9, -1e9, 1e9, -1e9, 0
    for k = 0, 15 do
        local a = k * 0.39269908
        local px, py, rc = project_world(wx + R * math.cos(a), wy + R * math.sin(a), z)
        if rc and rc >= 0 and px and py then
            n = n + 1
            if px < x0 then x0 = px end; if px > x1 then x1 = px end
            if py < y0 then y0 = py end; if py > y1 then y1 = py end
        end
    end
    if n < 12 then return nil end
    return (x0 + x1) * 0.5, (y0 + y1) * 0.5, (x1 - x0) * 0.5, (y1 - y0) * 0.5, n
end
M._world_ellipse = world_ellipse
-- horizontal screen scale of the body: px for `height` world units measured across the view at chest height.
-- The feet->crown span shrinks when the camera looks down (pitch) while the body's on-screen WIDTH does not;
-- widths (glow, pool, capsule half-widths) use max(span, this) so they stop shrinking with the pitch.
local function body_wspan(wx, wy, floor_z, height)
    local _, _, rx = world_ellipse(wx, wy, floor_z + height * 0.55, height * 0.5)
    return rx and rx * 2 or nil
end
M._body_wspan = body_wspan

local function reset_ground()
    TRAIL, TRAIL_N = {}, 0
    last_trail_sample, last_wx, last_wy, last_wz = 0, nil, nil, nil
    preview_aura_t, preview_trail_t = 0, 0
    FEET.ok, FEET.src = false, 'none'
end

local function update_feet()
    FEET.ok, FEET.src = false, 'none'
    if M._debug_feet_x and M._debug_feet_y then
        FEET.x, FEET.y = M._debug_feet_x, M._debug_feet_y
        FEET.rx = M._debug_feet_rx or 56
        FEET.ry = M._debug_feet_ry or 20
        FEET.ok, FEET.src = true, 'debug'
        return
    end
    local wx, wy, wz = me_xyz()
    local height = me_height()
    local floor_z, zsrc = me_floor_z(wz)
    FEET.floor_z, FEET.z_src, FEET.height = floor_z, zsrc, height
    local R = height * AURA_HEIGHT_R
    if R < 2.2 then R = 2.2 end
    if R > 8.0 then R = 8.0 end
    -- Four points on the FLOOR plane (not spawn Z) give the on-screen
    -- ellipse. Center is the projected floor point — never spawn_to_screen(id, 0),
    -- which is the mid-body / chest attachment that put t343 at the knees.
    -- aura rework: 16 points round the circle, not the 4 world-axis points. With 4 points the box came out up
    -- to 30-45% too small whenever the camera yaw was not a multiple of 90 deg (the points sit inside the
    -- rotated ellipse), so the ring shrank and grew as you panned. 16 points keep it within ~2%.
    local offs = {}
    for k = 0, 15 do local a = k * 0.39269908; offs[k + 1] = { R * math.cos(a), R * math.sin(a) } end
    local xs, ys, n = {}, {}, 0
    for i = 1, 16 do
        local px, py, rc = project_world(wx + offs[i][1], wy + offs[i][2], floor_z)
        if rc and rc >= 0 and px and py then
            n = n + 1
            xs[n], ys[n] = px, py
        end
    end
    local fpx, fpy, frc = project_world(wx, wy, floor_z)
    local cx, cy, rx, ry = fpx, fpy, 90, 32
    if n >= 12 then
        local x0, x1, y0, y1 = 1e9, -1e9, 1e9, -1e9
        for i = 1, n do
            if xs[i] < x0 then x0 = xs[i] end; if xs[i] > x1 then x1 = xs[i] end
            if ys[i] < y0 then y0 = ys[i] end; if ys[i] > y1 then y1 = ys[i] end
        end
        rx, ry = math.max(8, (x1 - x0) * 0.5), math.max(6, (y1 - y0) * 0.5)
        -- centre of the projected circle (perspective puts it a little below the projected feet point)
        cx, cy = (x0 + x1) * 0.5, (y0 + y1) * 0.5
        FEET.src = 'w2s-floor'
    elseif fpx and frc and frc >= 0 then
        cx, cy = fpx, fpy
        FEET.src = 'w2s-floor-pt'
    else
        -- Last resort: spawn projector with a downward world-Z offset.
        local id = me_id()
        local dz = floor_z - wz
        local fx, fy, rc = nil, nil, -1
        if id and id > 0 then fx, fy, rc = project_screen(id, dz) end
        if fx and rc and rc >= 0 then
            cx, cy = fx, fy
            FEET.src = 'spawn-floor-off'
        else
            FEET.src = 'no-self'
            return
        end
    end
    if not cx then return end
    if rx < 36 then rx = 36 end
    if ry < 14 then ry = 14 end
    if rx > W * 0.40 then rx = W * 0.40 end
    if ry > H * 0.28 then ry = H * 0.28 end
    -- the old ry <= 0.72*rx clamp squashed the ring at steep camera pitch; only keep a sanity band
    if ry > rx * 1.0 then ry = rx * 1.0 end
    if ry < rx * 0.12 then ry = rx * 0.12 end
    FEET.x, FEET.y, FEET.rx, FEET.ry, FEET.ok = cx, cy, rx, ry, true
end

local function push_trail_mark(wx, wy, wz, style, life, age)
    if TRAIL_N >= TRAIL_CAP then
        for i = 1, TRAIL_N - 1 do TRAIL[i] = TRAIL[i + 1] end
        TRAIL_N = TRAIL_N - 1
    end
    TRAIL_N = TRAIL_N + 1
    TRAIL[TRAIL_N] = {
        wx = wx, wy = wy, wz = wz,
        t0 = now() - (age or 0),
        life = life or (TRAIL_LIFE + math.random() * 300),
        style = style or 'inferno',
        seed = math.random(1, 9999),
    }
end

local function update_trail()
    local on, style = trail_wanted()
    local tnow = now()
    -- expire
    local w = 1
    while w <= TRAIL_N do
        local m = TRAIL[w]
        if (not m) or (tnow - (m.t0 or 0) >= (m.life or TRAIL_LIFE)) then
            TRAIL[w] = TRAIL[TRAIL_N]
            TRAIL[TRAIL_N] = nil
            TRAIL_N = TRAIL_N - 1
        else
            w = w + 1
        end
    end
    if not on then return end
    local wx, wy, wz = me_xyz()
    if last_wx then
        local dx, dy = wx - last_wx, wy - last_wy
        local dist = math.sqrt(dx * dx + dy * dy)
        if dist >= 0.12 and (tnow - last_trail_sample) >= TRAIL_DT then
            push_trail_mark(wx, wy, wz, style)
            last_trail_sample = tnow
        end
    else
        last_trail_sample = tnow
    end
    last_wx, last_wy, last_wz = wx, wy, wz
end

local function update_ground(dt)
    if M._debug_aura_spin then AURA_SPIN = M._debug_aura_spin else AURA_SPIN = AURA_SPIN + (dt or 0.016) * 0.70 end
    local want_a = aura_wanted()
    local want_t = trail_wanted()
    if want_a or want_t or TRAIL_N > 0 then update_feet() end
    update_trail()
end

local function ground_wants_draw()
    if TRAIL_N > 0 then return true end
    local a = aura_wanted()
    return a and FEET.ok
end

local function emit_g(items, x, y, sx, sy, ang, r, g, b, a, tex, blend)
    if a and a > 0.02 and sx and sy and sx > 0.4 and sy > 0.4 then
        items[#items + 1] = {
            x = x, y = y, sx = sx, sy = sy, ang = ang or 0,
            r = r, g = g, b = b, a = a, tex = tex or 'core',
            depth = -0.95, blend = blend or '',
        }
    end
end

local SHOWPIECE = {
    sigil = true, magma = true, tempest = true, nebula = true,
    radiance = true, hexfrost = true, miasma = true, ritual = true,
}

local function is_showpiece(style)
    return style ~= nil and SHOWPIECE[style] == true
end

local function cap3(r, g, b, m)
    m = m or 1.18
    local x = r
    if g > x then x = g end
    if b > x then x = b end
    if x > m then
        local s = m / x
        return r * s, g * s, b * s
    end
    return r, g, b
end

local function nshow(n)
    if lite() then return math.max(3, math.floor(n * 0.62 + 0.5)) end
    return n
end

local function disc_occ(px, py, cx, cy, rx, ry)
    local nx = (px - cx) / math.max(8, rx)
    local ny = (py - cy) / math.max(6, ry)
    if ny > 0.14 then return 1 end
    local along = (0.14 - ny) / 0.85
    if along < 0 then along = 0 elseif along > 1 then along = 1 end
    local hw = 0.16 + 0.10 * along
    local ax = math.abs(nx) / hw
    if ax >= 1.65 then return 1 end
    local inside = 1 - math.max(0, math.min(1, (ax - 0.25) / 1.40))
    local far = 0
    if ny < -0.55 then far = math.min(1, (-0.55 - ny) / 0.35) end
    return 1 - inside * (1 - far) * 0.70
end

local function emit_rise(items, n, cx, cy, rx, ry, spin, speed, rise, rad0, rad1, cr, cg, cb, tex, fadeI, sz0, sz1)
    n = nshow(n)
    for i = 1, n do
        local u = (spin * speed + i * 0.618033) % 1
        local a = i * 2.39996 + 0.35
        local rad = rad0 + (rad1 - rad0) * ((i * 0.37) % 1)
        local px = cx + math.cos(a) * rx * rad
        local py = cy + math.sin(a) * ry * rad - u * rise
        local fade = math.sin(u * 3.14159)
        local sz = sz0 + (sz1 - sz0) * u
        local o = disc_occ(px, py, cx, cy, rx, ry)
        emit_g(items, px, py, sz, sz * math.max(0.35, ry / rx) * 0.95, 0,
            cr, cg, cb, 0.52 * fade * o * fadeI, tex, '')
    end
end

local function emit_orbit(items, n, cx, cy, rx, ry, spin, speed, rad, cr, cg, cb, tex, fadeI, sz)
    n = nshow(n)
    for i = 1, n do
        local a = spin * speed + (i / n) * 6.28318
        local px = cx + math.cos(a) * rx * rad
        local py = cy + math.sin(a) * ry * rad
        local tw = 0.62 + 0.38 * math.sin(spin * 2.15 + i * 1.27)
        local o = disc_occ(px, py, cx, cy, rx, ry)
        emit_g(items, px, py, sz, sz * math.max(0.35, ry / rx), a,
            cr, cg, cb, 0.48 * tw * o * fadeI, tex, '')
    end
end

-- Returns true if this style is a showpiece and sprites were emitted.
local function emit_showpiece(items, style, fadeI)
    if not is_showpiece(style) then return false end
    local cx, cy, rx, ry = FEET.x, FEET.y, FEET.rx, FEET.ry
    local spin = AURA_SPIN
    local pulse = 0.5 + 0.5 * math.sin(spin * 1.55)

    if style == 'sigil' then
        local cr, cg, cb = cap3(0.62, 0.36, 1.14)
        emit_g(items, cx, cy, rx * 1.14, ry * 1.14, 0, cr * 0.70, cg * 0.70, cb * 0.70, 0.16 * fadeI, 'auradisc', 'alpha')
        emit_g(items, cx, cy, rx, ry, 0, cr * 0.85, cg * 0.55, cb, 0.30 * fadeI, 'auradisc', 'alpha')
        emit_g(items, cx, cy, rx * (0.58 + 0.04 * pulse), ry * (0.58 + 0.04 * pulse), spin * 0.12,
            cr, cg, cb, (0.40 + 0.14 * pulse) * fadeI, 'spsigil', '')
        emit_g(items, cx, cy, rx, ry, spin * 0.34, cr, cg, cb, 0.50 * fadeI, 'sprunering', '')
        emit_g(items, cx, cy, rx * 0.64, ry * 0.64, -spin * 0.52, cr, cg, cb, 0.42 * fadeI, 'sprunering', '')
        do local rr, rg, rb = cap3(cr * 1.06, cg * 1.06, cb * 1.06, 1.20)
            emit_g(items, cx, cy, rx, ry, 0, rr, rg, rb, 0.42 * fadeI, 'aurarim', '') end
        emit_rise(items, 6, cx, cy, rx, ry, spin, 0.42, ry * 2.4, 0.28, 0.72, cr, cg, cb, 'glyph', fadeI, 5, 9)
        emit_orbit(items, 6, cx, cy, rx, ry, spin, 0.70, 0.86, cr, cg, cb, 'ember', fadeI, 5.5)

    elseif style == 'magma' then
        local cr, cg, cb = cap3(1.16, 0.38, 0.08)
        emit_g(items, cx, cy, rx * 1.12, ry * 1.12, 0, 0.22, 0.06, 0.02, 0.34 * fadeI, 'auradisc', 'alpha')
        emit_g(items, cx, cy, rx, ry, 0, cr, cg, cb, 0.46 * fadeI, 'splava', '')
        do local rr, rg, rb = cap3(1.20, 0.55, 0.10)
            emit_g(items, cx, cy, rx * 0.98, ry * 0.98, 0.15, rr, rg, rb, (0.22 + 0.16 * pulse) * fadeI, 'spcracks', '') end
        do local rr, rg, rb = cap3(1.15, 0.42, 0.06)
            emit_g(items, cx, cy, rx * 0.86, ry * 0.86, -0.4, rr, rg, rb, (0.14 + 0.12 * (1 - pulse)) * fadeI, 'spcracks', '') end
        do local rr, rg, rb = cap3(1.18, 0.48, 0.08, 1.20)
            emit_g(items, cx, cy, rx, ry, 0, rr, rg, rb, 0.40 * fadeI, 'aurarim', '') end
        emit_rise(items, 8, cx, cy, rx, ry, spin, 0.55, ry * 2.6, 0.18, 0.70, cr, cg, cb, 'ember', fadeI, 4, 8)
        do local rr, rg, rb = cap3(1.10, 0.55, 0.12)
            emit_rise(items, 4, cx, cy, rx, ry, spin, 0.38, ry * 1.8, 0.22, 0.50, rr, rg, rb, 'flame0', fadeI, 6, 11) end

    elseif style == 'tempest' then
        local cr, cg, cb = cap3(0.50, 0.82, 1.16)
        emit_g(items, cx, cy, rx * 1.14, ry * 1.14, 0, 0.12, 0.16, 0.28, 0.28 * fadeI, 'auradisc', 'alpha')
        emit_g(items, cx, cy, rx, ry, 0, cr * 0.70, cg * 0.80, cb, 0.26 * fadeI, 'auracaust1', '')
        emit_g(items, cx, cy, rx, ry, 0, cr, cg, cb, 0.44 * fadeI, 'aurarim', '')
        emit_g(items, cx, cy, rx * (0.40 + 0.28 * pulse), ry * (0.40 + 0.28 * pulse), 0,
            cr, cg, cb, (0.18 + 0.16 * pulse) * fadeI, 'auraripple', '')
        local flash = math.max(0, math.sin(spin * 7.2))
        local nb = nshow(5)
        for i = 1, nb do
            local a = spin * 0.62 + (i / nb) * 6.28318
            local px = cx + math.cos(a) * rx * 0.90
            local py = cy + math.sin(a) * ry * 0.90
            local fi = math.floor(spin * 2.7 + i * 1.4) % 3
            local tex = (fi == 0 and 'spbolt0') or (fi == 1 and 'spbolt1') or 'spbolt2'
            local flick = 0.30 + 0.70 * math.max(0.12, math.sin(spin * 5.8 + i * 2.05))
            local o = disc_occ(px, py, cx, cy, rx, ry)
            emit_g(items, px, py, rx * 0.40, math.max(5, ry * 0.18), a + 1.5708,
                cr, cg, cb, 0.58 * flick * o * fadeI, tex, '')
        end
        emit_orbit(items, 6, cx, cy, rx, ry, spin, 1.15, 0.78, cr, cg, cb, 'ember', fadeI, 4.5)
        if flash > 0.72 then
            emit_g(items, cx, cy, rx * 0.55, ry * 0.55, 0, cr, cg, cb, 0.16 * flash * fadeI, 'flare', '')
        end

    elseif style == 'nebula' then
        local cr, cg, cb = cap3(0.72, 0.32, 1.12)
        emit_g(items, cx, cy, rx * 1.10, ry * 1.10, 0, 0.10, 0.04, 0.16, 0.40 * fadeI, 'spdarkcore', 'alpha')
        emit_g(items, cx, cy, rx * 1.02, ry * 1.02, spin * 0.22, cr, cg, cb, 0.38 * fadeI, 'spnebula0', '')
        do local rr, rg, rb = cap3(0.55, 0.22, 0.95)
            emit_g(items, cx, cy, rx * 0.92, ry * 0.92, -spin * 0.31, rr, rg, rb, 0.28 * fadeI, 'spnebula1', '') end
        do local rr, rg, rb = cap3(0.82, 0.40, 1.16, 1.20)
            emit_g(items, cx, cy, rx, ry, 0, rr, rg, rb, 0.48 * fadeI, 'aurarim', '') end
        do local rr, rg, rb = cap3(0.85, 0.55, 1.12)
            emit_orbit(items, 8, cx, cy, rx, ry, spin, 0.38, 0.74, rr, rg, rb, 'speck', fadeI, 3.8) end
        emit_g(items, cx, cy, rx * 0.42, ry * 0.42, spin * 0.08, 0.18, 0.06, 0.28, 0.30 * fadeI, 'void', 'alpha')

    elseif style == 'radiance' then
        local cr, cg, cb = cap3(1.16, 1.02, 0.48)
        emit_g(items, cx, cy, rx * 1.16, ry * 1.16, 0, cr * 0.75, cg * 0.70, cb * 0.45, 0.18 * fadeI, 'auradisc', 'alpha')
        emit_g(items, cx, cy, rx, ry, 0, cr, cg, cb, 0.32 * fadeI, 'auradisc', 'alpha')
        emit_g(items, cx, cy, rx, ry, 0, cr, cg, cb, 0.46 * fadeI, 'aurarim', '')
        emit_g(items, cx, cy, rx * (0.38 + 0.30 * pulse), ry * (0.38 + 0.30 * pulse), 0,
            cr, cg, cb, (0.20 + 0.14 * pulse) * fadeI, 'auraripple', '')
        emit_g(items, cx, cy, rx * 0.50, ry * 0.50, spin * 0.08, cr, cg, cb, 0.20 * fadeI, 'halo', '')
        local np = nshow(5)
        for i = 1, np do
            local a = (i / np) * 6.28318 + 0.40
            local px = cx + math.cos(a) * rx * 0.50
            local py = cy + math.sin(a) * ry * 0.50
            local ph = ry * (2.5 + 0.65 * math.sin(spin * 1.05 + i))
            if ph > rx * 1.10 then ph = rx * 1.10 end
            local pw = math.max(5, rx * 0.095)
            local o = disc_occ(px, py, cx, cy, rx, ry)
            emit_g(items, px, py - ph * 0.42, pw, ph * 0.50, 0, cr, cg, cb, 0.26 * o * fadeI, 'sppillar', '')
        end
        emit_rise(items, 7, cx, cy, rx, ry, spin, 0.40, ry * 2.5, 0.22, 0.70, cr, cg, cb, 'flare', fadeI, 4, 7)

    elseif style == 'hexfrost' then
        local cr, cg, cb = cap3(0.58, 0.88, 1.14)
        emit_g(items, cx, cy, rx * 1.12, ry * 1.12, 0, cr * 0.70, cg * 0.82, cb, 0.20 * fadeI, 'auradisc', 'alpha')
        emit_g(items, cx, cy, rx, ry, spin * 0.10, cr, cg, cb, 0.40 * fadeI, 'sphex', '')
        emit_g(items, cx, cy, rx * 0.62, ry * 0.62, -spin * 0.16, cr, cg, cb, 0.28 * fadeI, 'sphex', '')
        do local rr, rg, rb = cap3(cr * 1.05, cg * 1.05, cb * 1.05, 1.20)
            emit_g(items, cx, cy, rx, ry, 0, rr, rg, rb, 0.44 * fadeI, 'aurarim', '') end
        local ns = nshow(8)
        for i = 1, ns do
            local a = (i / ns) * 6.28318 + 0.12
            local grow = 0.48 + 0.52 * math.max(0, math.sin(spin * 1.22 + i * 0.82))
            local px = cx + math.cos(a) * rx * 0.90
            local py = cy + math.sin(a) * ry * 0.90
            local sz = (6.5 + (i % 3)) * grow
            local tex = (i % 3 == 0) and 'ice0' or ((i % 3 == 1) and 'ice1' or 'shard')
            local o = disc_occ(px, py, cx, cy, rx, ry)
            emit_g(items, px, py, sz, sz * 1.15 * math.max(0.35, ry / rx), a,
                cr, cg, cb, 0.58 * grow * o * fadeI, tex, 'alpha')
        end
        emit_orbit(items, 4, cx, cy, rx, ry, spin, 0.28, 0.55, cr, cg, cb, 'mist', fadeI, 7)

    elseif style == 'miasma' then
        local cr, cg, cb = cap3(0.38, 1.05, 0.22)
        emit_g(items, cx, cy, rx * 1.14, ry * 1.14, 0, cr * 0.55, cg * 0.70, cb * 0.30, 0.22 * fadeI, 'auradisc', 'alpha')
        emit_g(items, cx, cy, rx, ry, spin * 0.07, cr, cg, cb, 0.42 * fadeI, 'sppool', 'alpha')
        emit_g(items, cx, cy, rx * 1.05, ry * 1.05, 0, cr, cg, cb, 0.20 * fadeI, 'gas', '')
        emit_g(items, cx, cy, rx, ry, 0, cr, cg, cb, 0.36 * fadeI, 'aurarim', '')
        emit_rise(items, 8, cx, cy, rx, ry, spin, 0.48, ry * 2.1, 0.20, 0.68, cr, cg, cb, 'bubble', fadeI, 4, 9)
        emit_orbit(items, 6, cx, cy, rx, ry, spin, 0.50, 0.80, cr, cg, cb, 'spore', fadeI, 5)
        emit_g(items, cx, cy - ry * 0.15, rx * 0.55, ry * 0.70, 0, cr, cg, cb, 0.12 * fadeI, 'gas', '')

    elseif style == 'ritual' then
        local cr, cg, cb = cap3(1.12, 0.10, 0.10)
        emit_g(items, cx, cy, rx * 1.12, ry * 1.12, 0, 0.22, 0.03, 0.04, 0.36 * fadeI, 'auradisc', 'alpha')
        emit_g(items, cx, cy, rx * (0.96 + 0.05 * pulse), ry * (0.96 + 0.05 * pulse), spin * 0.06,
            cr, cg, cb, (0.48 + 0.12 * pulse) * fadeI, 'spritual', '')
        do local rr, rg, rb = cap3(1.16, 0.16, 0.12, 1.20)
            emit_g(items, cx, cy, rx, ry, 0, rr, rg, rb, 0.40 * fadeI, 'aurarim', '') end
        emit_g(items, cx, cy, rx * (0.36 + 0.34 * pulse), ry * (0.36 + 0.34 * pulse), 0,
            cr, cg, cb, (0.22 + 0.16 * pulse) * fadeI, 'auraripple', '')
        local nd = nshow(5)
        for i = 1, nd do
            local u = (spin * 0.42 + i * 0.19) % 1
            local a = i * 1.256637 + 0.55
            local px = cx + math.cos(a) * rx * 0.40
            local py = cy + math.sin(a) * ry * 0.40 + u * ry * 1.20
            local fade = math.sin(u * 3.14159)
            local o = disc_occ(px, py, cx, cy, rx, ry)
            emit_g(items, px, py, 3.5 + 2.5 * u, 6 + 5 * u, 0, cr, cg * 0.4, cb * 0.4, 0.62 * fade * o * fadeI, 'drip', 'alpha')
        end
        emit_orbit(items, 5, cx, cy, rx, ry, spin, 0.44, 0.84, cr, cg, cb, 'bdrop', fadeI, 5)
    end
    return true
end


local function collect_ground_sprites()
    local items = {}
    local fadeI = intensity()
    local tnow = now()
    -- Trail first (under the live ring), then the aura.
    if TRAIL_N > 0 and FEET.ok then
        local squash = FEET.ry / math.max(8, FEET.rx)
        for i = 1, TRAIL_N do
            local m = TRAIL[i]
            local px, py, rc = project_world(m.wx, m.wy, m.wz)
            if rc and rc >= 0 and px then
                local age = tnow - (m.t0 or tnow)
                local life = m.life or TRAIL_LIFE
                local u = 1 - age / math.max(1, life)
                if u > 0.02 then
                    local L = look_of(m.style)
                    local cr, cg, cb = L[1], L[2], L[3]
                    local a = 0.82 * u * fadeI
                    local base = (18 + (m.seed % 7)) * (0.75 + 0.25 * u)
                    -- Flattened stamp on the ground plane.
                    emit_g(items, px, py, base, base * squash * 0.95, (m.seed % 360) * 0.01745,
                        cr, cg, cb, a, L[5], (m.style == 'frost' or m.style == 'toxic' or m.style == 'water' or m.style == 'blood') and 'alpha' or '')
                    if L[7] and (i % 2 == 0) then
                        emit_g(items, px, py, base * 0.55, base * 0.55 * squash, 0,
                            cr, cg, cb, a * 0.55, L[7], '')
                    end
                end
            end
        end
    end
    local want_a, style = aura_wanted()
    if want_a and FEET.ok and emit_showpiece(items, style, fadeI) then
        -- showpiece handled
    elseif want_a and FEET.ok then
        local L = look_of(style)
        local cr, cg, cb = L[1], L[2], L[3]
        local mx = cr
        if cg > mx then mx = cg end
        if cb > mx then mx = cb end
        if mx > 1.16 then
            local s = 1.16 / mx
            cr, cg, cb = cr * s, cg * s, cb * s
        end
        local cx, cy, rx, ry = FEET.x, FEET.y, FEET.rx, FEET.ry
        local spin = AURA_SPIN
        local pulse = 0.5 + 0.5 * math.sin(spin * 1.55)
        -- Filled floor disc + outer bleed (alpha, so stacked layers do not clip white).
        emit_g(items, cx, cy, rx * 1.16, ry * 1.16, 0, cr * 0.72, cg * 0.72, cb * 0.72, 0.16 * fadeI, 'auradisc', 'alpha')
        emit_g(items, cx, cy, rx, ry, 0, cr, cg, cb, 0.36 * fadeI, 'auradisc', 'alpha')
        -- 2-3 caustic layers pulsed at different speeds. Not rotated: the
        -- baked leg-fade must stay screen-aligned (up = toward the head).
        local a0 = (0.15 + 0.11 * (0.5 + 0.5 * math.sin(spin * 1.05))) * fadeI
        local a1 = (0.12 + 0.09 * (0.5 + 0.5 * math.sin(spin * 1.35 + 2.1))) * fadeI
        local a2 = (0.09 + 0.08 * (0.5 + 0.5 * math.sin(spin * 0.82 + 4.0))) * fadeI
        emit_g(items, cx, cy, rx * 1.01, ry * 1.01, 0, cr, cg, cb, a0, 'auracaust0', '')
        emit_g(items, cx, cy, rx * 0.99, ry * 0.99, 0, cr, cg, cb, a1, 'auracaust1', '')
        emit_g(items, cx, cy, rx * 0.96, ry * 0.96, 0, cr, cg, cb, a2, 'auracaust2', '')
        -- Expanding inner ripple around the feet.
        local ru = 0.42 + 0.36 * pulse
        emit_g(items, cx, cy, rx * ru, ry * ru, 0, cr, cg, cb, (0.20 + 0.16 * pulse) * fadeI, 'auraripple', '')
        local rr, rg, rb = cr * 1.08, cg * 1.08, cb * 1.08
        if rr > 1.20 then rr = 1.20 end
        if rg > 1.20 then rg = 1.20 end
        if rb > 1.20 then rb = 1.20 end
        emit_g(items, cx, cy, rx, ry, 0, rr, rg, rb, 0.50 * fadeI, 'aurarim', '')
        -- Faint matching sheen on the body, just above the feet.
        emit_g(items, cx, cy - ry * 1.05, rx * 0.38, ry * 1.45, 0, cr, cg, cb, 0.11 * fadeI, 'flare', '')
        if style == 'arcane' then
            emit_g(items, cx, cy, rx * 0.55, ry * 0.55, spin * 0.12, cr, cg, cb, 0.18 * fadeI, 'rune', '')
        end
    end
    return items
end

function M.preview_aura(style)
    preview_aura_style = style or 'inferno'
    preview_aura_t = now() + (is_showpiece(style) and 3600 or 2200)
    update_feet()
end

function M.is_showpiece(style)
    return is_showpiece(style)
end

function M.preview_trail(style)
    preview_trail_style = style or 'inferno'
    preview_trail_t = now() + 2400
    local wx, wy, wz = me_xyz()
    local h = me_heading()
    local fx, fy = math.sin(h), math.cos(h)
    TRAIL, TRAIL_N = {}, 0
    for i = 1, 10 do
        push_trail_mark(wx - fx * i * 0.38, wy - fy * i * 0.38, wz, preview_trail_style, 1800, (i - 1) * 130)
    end
    update_feet()
end

function M.ground_live()
    return ground_wants_draw()
end

function M.debug_feet()
    return { x = FEET.x, y = FEET.y, rx = FEET.rx, ry = FEET.ry, ok = FEET.ok, src = FEET.src, floor_z = FEET.floor_z, z_src = FEET.z_src, height = FEET.height }
end

function M.debug_trail()
    local t = {}
    for i = 1, TRAIL_N do t[i] = TRAIL[i] end
    return t
end

function M.debug_ground_items()
    return collect_ground_sprites(), FEET.x, FEET.y, FEET.rx, FEET.ry, FEET.src
end

function M.seed_trail_mark(wx, wy, wz, style, age, life)
    push_trail_mark(wx, wy, wz, style, life, age)
end



-- ----------------------------------------------------------------
-- NPC markers (t348-wake). Live IDs only; never ghost last-seen spots.
-- Separate from proc kinds so clear_combat_fx cannot wipe them.
-- ----------------------------------------------------------------
local MK_BLOCKED = {
    AURA=true, BANNER=true, CAMPFIRE=true, CORPSE=true,
    CHEST=true, ITEM=true, TRIGGER=true, TRAP=true,
    TIMER=true, MOUNT=true, MERCENARY=true, OBJECT=true,
}
local MK_TEX = {
    skull = 'mkskull', star = 'mkstar', crosshair = 'mkcross',
    diamond = 'mkdiamond', exclamation = 'mkexcl', crown = 'mkcrown',
    shield = 'mkshield', flame = 'mkflame',
}
local MK = {
    live = {}, nearby = {}, building = {}, nearby_build = {},
    by_id = {},
    idx = 0, total = 0, last_done = 0, scanning = false,
    log_t = 0,
}
M.MARK_SCAN_SLICE = 15
M.MARK_SCAN_MS = 3000
M.MARK_ICON_CAP = 20
M.MARK_BEAM_CAP = 8
M.MARK_NEAR_INGEST = 8

local function markers_cfg()
    local C = core()
    return C and C.cfg and C.cfg.markers
end

local function markers_wanted()
    local mc = markers_cfg()
    return mc and mc.on == true
end

local function marker_rules()
    local C = core()
    if not (C and C.marker_all_rules) then
        return (C and C.marker_rules and C.marker_rules()) or {}
    end
    local zone
    if M._debug_zone then
        zone = M._debug_zone
    else
        pcall(function()
            local mq = require('mq')
            zone = mq.TLO.Zone.ShortName()
        end)
    end
    return C.marker_all_rules(zone)
end

local function spawn_count_mk()
    if M._debug_spawn_count ~= nil then return M._debug_spawn_count end
    if M._debug_spawns then return #M._debug_spawns end
    local n = 0
    pcall(function()
        local mq = require('mq')
        n = tonumber(mq.TLO.SpawnCount('npc targetable')()) or 0
    end)
    return n
end

local function pack_spawn(sp)
    if not sp then return nil end
    return {
        id = sp.id, name = sp.name, dist = sp.dist or 0,
        height = sp.height or 6, typ = tostring(sp.typ or 'NPC'):upper(),
        z = sp.z, floorz = sp.floorz, radius = sp.radius or 0,
    }
end

local function read_tlo_spawn(sp)
    if not (sp and sp.ID and sp.ID() and sp.ID() > 0) then return nil end
    local h, ah, z, fz = 0, 0, nil, nil
    if sp.Height then h = tonumber(sp.Height()) or 0 end
    if sp.AvatarHeight then ah = tonumber(sp.AvatarHeight()) or 0 end
    pcall(function()
        if sp.Z then z = tonumber(sp.Z()) end
        if sp.FloorZ then fz = tonumber(sp.FloorZ()) end
    end)
    local height = (ah and ah > 0.5 and ah < 40) and ah or ((h > 0.5 and h < 40) and h or 6.0)
    local rad = 0
    pcall(function()
        if sp.Radius then rad = tonumber(sp.Radius()) or 0 end
        if (not rad or rad < 0.2) and sp.CollisionRadius then
            rad = tonumber(sp.CollisionRadius()) or 0
        end
    end)
    return {
        id = sp.ID(),
        name = sp.CleanName() or sp.Name() or 'Unknown',
        dist = tonumber(sp.Distance()) or tonumber(sp.Distance3D()) or 0,
        height = height,
        typ = tostring(sp.Type() or 'NPC'):upper(),
        z = z, floorz = fz, radius = rad or 0,
    }
end

local function read_spawn_mk(i)
    if M._debug_spawns then
        return pack_spawn(M._debug_spawns[i])
    end
    local out
    pcall(function()
        local mq = require('mq')
        out = read_tlo_spawn(mq.TLO.NearestSpawn(i, 'npc targetable'))
    end)
    return out
end

local function read_spawn_id_mk(id)
    if not (id and id > 0) then return nil end
    if M._debug_spawns then
        for n = 1, #M._debug_spawns do
            local s = M._debug_spawns[n]
            if s and s.id == id then return pack_spawn(s) end
        end
        return nil
    end
    local out
    pcall(function()
        local mq = require('mq')
        out = read_tlo_spawn(mq.TLO.Spawn('id ' .. tostring(id)))
    end)
    return out
end

local function read_target_mk()
    if M._debug_target then return pack_spawn(M._debug_target) end
    local out
    pcall(function()
        local mq = require('mq')
        local tgt = mq.TLO.Target
        if tgt and tgt.ID and tgt.ID() and tgt.ID() > 0 then
            out = read_tlo_spawn(tgt)
        end
    end)
    return out
end

local function project_mark(id, hoff)
    if M._debug_spawn_to_screen then
        local x, y, rc = M._debug_spawn_to_screen(id, hoff)
        return x, y, rc or -1
    end
    if not (M._api and M._api.rml_spawn_to_screen and id and id > 0) then
        return nil, nil, -1
    end
    if not _sx then _sx = ffi.new('float[1]'); _sy = ffi.new('float[1]') end
    local rc = -1
    pcall(function()
        rc = tonumber(M._api.rml_spawn_to_screen(id, hoff, _sx, _sy)) or -1
    end)
    if rc < 0 then return nil, nil, rc end
    local sw, sh = viewport_wh()
    local x = _sx[0] * W / sw
    local y = _sy[0] * H / sh
    if not x or not y or x ~= x or y ~= y then return nil, nil, -1 end
    if math.abs(x) > 1e6 or math.abs(y) > 1e6 then return nil, nil, -1 end
    return x, y, rc
end

local function icon_tex(icon)
    icon = tostring(icon or 'skull')
    local custom = icon:match('^custom:(.+)$')
    if custom then return 'mkc_' .. custom end
    return MK_TEX[icon] or 'mkskull'
end

local function load_marker_custom()
    local C = core()
    if not (C and C.marker_custom_list) then return end
    local list = C.marker_custom_list()
    if not list then return end
    local dir = img_dir()
    local last = dir:sub(-1)
    local sep = (last == '/' or last == '\\') and '' or '/'
    for _, stem in ipairs(list) do
        local key = 'mkc_' .. stem
        if not TEX[key] then
            local id = 0
            pcall(function()
                id = tonumber(M._api.rml_canvas_texture_load(WIN, ID, dir .. sep .. 'markers_custom/' .. stem .. '.png')) or 0
            end)
            TEX[key] = id
        end
    end
end

local function mark_log_path()
    local path
    pcall(function() path = require('combatfx.paths').log_path('combatfx_fx.log') end)   -- nil unless debug_logs=1
    return path
end

local function marklog(msg)
    if M._debug_spawns or M._debug_target then return end
    local path = mark_log_path()
    if not path then return end
    local f = io.open(path, 'a')
    if not f then return end
    f:write(os.date('%Y-%m-%d %H:%M:%S'), ' ', msg, '\n')
    f:flush()
    f:close()
end

local function rebuild_live()
    local t = {}
    for _, m in pairs(MK.by_id) do
        t[#t + 1] = m
    end
    table.sort(t, function(a, b)
        return (a.dist or 0) < (b.dist or 0)
    end)
    MK.live = t
end

local function touch_mark(sp, rule)
    if not (sp and sp.id and sp.id > 0 and rule) then return end
    MK.by_id[sp.id] = {
        id = sp.id, name = sp.name, dist = sp.dist or 0,
        height = sp.height or 6, rule = rule,
        z = sp.z, floorz = sp.floorz, typ = sp.typ,
        radius = sp.radius or 0,
    }
end

local function prune_and_ingest(rules)
    local C = core()
    for id, m in pairs(MK.by_id) do
        local sp = read_spawn_id_mk(id)
        if not sp or MK_BLOCKED[sp.typ] then
            MK.by_id[id] = nil
        else
            local rule = C and C.marker_rule_for and C.marker_rule_for(sp.name, rules)
            if not rule then
                MK.by_id[id] = nil
            else
                m.name, m.dist, m.height = sp.name, sp.dist, sp.height
                m.z, m.floorz, m.rule, m.typ = sp.z, sp.floorz, rule, sp.typ
                m.radius = sp.radius or m.radius or 0
            end
        end
    end
    local tgt = read_target_mk()
    if tgt and not MK_BLOCKED[tgt.typ] then
        local rule = C and C.marker_rule_for and C.marker_rule_for(tgt.name, rules)
        if rule then touch_mark(tgt, rule) end
    end
    local near_n = M.MARK_NEAR_INGEST or 8
    for i = 1, near_n do
        local sp = read_spawn_mk(i)
        if sp and not MK_BLOCKED[sp.typ] then
            local rule = C and C.marker_rule_for and C.marker_rule_for(sp.name, rules)
            if rule then touch_mark(sp, rule) end
        end
    end
    rebuild_live()
end

local function update_markers()
    if not markers_wanted() then
        MK.live, MK.scanning, MK.by_id = {}, false, {}
        return
    end
    local t = now()
    local rules = marker_rules()
    prune_and_ingest(rules)
    if not MK.scanning then
        if MK.last_done > 0 and (t - MK.last_done) < M.MARK_SCAN_MS then
            return
        end
        local total = spawn_count_mk()
        if total <= 0 then
            -- Empty SpawnCount is often a TLO hiccup; keep sticky IDs.
            MK.last_done = t
            marklog(string.format('MARKSCAN skip-empty sticky=%d', #MK.live))
            return
        end
        MK.scanning = true
        MK.idx = 0
        MK.building = {}
        MK.nearby_build = {}
        MK.total = total
        marklog(string.format('MARKSCAN start total=%d sticky=%d', total, #MK.live))
    end
    local n = 0
    local C = core()
    while n < M.MARK_SCAN_SLICE and MK.idx < MK.total do
        MK.idx = MK.idx + 1
        n = n + 1
        local sp = read_spawn_mk(MK.idx)
        if sp and not MK_BLOCKED[sp.typ] then
            MK.nearby_build[#MK.nearby_build + 1] = {
                id = sp.id, name = sp.name, dist = sp.dist, height = sp.height,
            }
            local rule = C and C.marker_rule_for and C.marker_rule_for(sp.name, rules)
            if rule then
                local entry = {
                    id = sp.id, name = sp.name, dist = sp.dist,
                    height = sp.height, rule = rule,
                    z = sp.z, floorz = sp.floorz, typ = sp.typ,
                }
                MK.building[#MK.building + 1] = entry
                MK.by_id[sp.id] = entry
            end
        end
    end
    rebuild_live()
    if MK.idx >= MK.total then
        table.sort(MK.nearby_build, function(a, b)
            return (a.dist or 0) < (b.dist or 0)
        end)
        MK.nearby = MK.nearby_build
        MK.scanning = false
        MK.last_done = t
        marklog(string.format('MARKSCAN done matched=%d sticky=%d nearby=%d',
            #MK.building, #MK.live, #MK.nearby))
    end
end

local function npc_floor_off(m)
    local h = m.height or 6
    if h < 0.5 or h > 40 then h = 6 end
    local wz, fz = tonumber(m.z), tonumber(m.floorz)
    if wz and fz and wz == wz and fz == fz then
        local off = fz - wz
        if off <= 0.2 and off >= -(h * 1.25 + 0.5) then
            return off
        end
    end
    -- Live Fusion log (t346): spawn Z sits at the feet (sy=571 at hoff=0,
    -- h=3.12). Do not subtract 0.52*h or the crown sinks into the torso.
    return 0
end

local function mark_xy_ok(x, y, rc)
    if rc and rc < 0 then return false end
    if not x or not y or x ~= x or y ~= y then return false end
    if math.abs(x) > 8000 or math.abs(y) > 8000 then return false end
    return true
end

local function mark_near_view(x, y)
    return x > -W * 0.25 and x < W * 1.25 and y > -H * 0.55 and y < H * 1.25
end

-- f10 (Tracking): overlay pixel point just above a spawn's head, for the cast / named labels; nil when the spawn is
-- behind the camera or off screen. Same projector as the markers (spawn Z = feet, see npc_floor_off).
function M.spawn_head_xy(id, height)
    id = tonumber(id)
    if not id or id <= 0 then return nil end
    if not M._debug_spawn_to_screen and not ensure() then return nil end
    local h = tonumber(height) or 6
    if h < 0.5 or h > 40 then h = 6 end
    local x, y, rc = project_mark(id, h * 1.08)
    if not mark_xy_ok(x, y, rc) then return nil end
    if x < 0 or x > W or y < 0 or y > H then return nil end
    return x, y
end

local function collect_marker_sprites()
    local items = {}
    MK._last_proj = {}
    if not markers_wanted() then return items end
    local fadeI = intensity()
    local tnow = now()
    local icons, beams, skips = 0, 0, 0
    for i = 1, #MK.live do
        local m = MK.live[i]
        local rule = m.rule or {}
        local style = rule.style or 'both'
        local want_icon = (style == 'icon' or style == 'both')
        local want_beam = (style == 'beam' or style == 'both')
        if want_icon and icons >= M.MARK_ICON_CAP then want_icon = false end
        if want_beam and beams >= M.MARK_BEAM_CAP then want_beam = false end
        if want_icon or want_beam then
            local h = m.height or 6
            if h < 0.5 or h > 40 then h = 6 end
            local floor_off = npc_floor_off(m)
            local crown_off = floor_off + h
            local fx, fy, frc = project_mark(m.id, floor_off)
            local hx, hy, hrc = project_mark(m.id, crown_off)
            local rec = {
                id = m.id, name = m.name, h = h, z = m.z, fz = m.floorz,
                foff = floor_off, fx = fx, fy = fy, frc = frc,
                hx = hx, hy = hy, hrc = hrc, reason = 'gone',
            }
            local feet_ok = mark_xy_ok(fx, fy, frc)
            local head_ok = mark_xy_ok(hx, hy, hrc)
            if not feet_ok and not head_ok then
                rec.reason = 'gone'
                skips = skips + 1
            elseif not ((feet_ok and mark_near_view(fx, fy)) or (head_ok and mark_near_view(hx, hy))) then
                rec.reason = 'offscreen'
                skips = skips + 1
            else
                rec.reason = 'draw'
                local span = 36
                if feet_ok and head_ok then
                    local dx, dy = hx - fx, hy - fy
                    span = math.sqrt(dx * dx + dy * dy)
                end
                if span < 10 then span = 10 end
                rec.span = span
                local C = core()
                local cr, cg, cb = 1.00, 0.82, 0.25
                if C and C.hex_rgb then cr, cg, cb = C.hex_rgb(rule.color) end
                if cr > 1.15 then cr = 1.15 end
                if cg > 1.15 then cg = 1.15 end
                if cb > 1.15 then cb = 1.15 end
                if want_beam then
                    -- Hollow hitbox cylinder: two bright vertical edges, a faint
                    -- sheet that is clear in the center, a floor ring, and motes
                    -- that spiral up the shell. Never a line through the NPC.
                    local bx, by = fx, fy
                    local top_off = floor_off + h * 1.38
                    local tx, ty, trc = project_mark(m.id, top_off)
                    if not mark_xy_ok(tx, ty, trc) then
                        tx, ty, trc = hx, hy, hrc
                    end
                    if mark_xy_ok(bx, by, frc) and mark_xy_ok(tx, ty, trc) then
                        local dx, dy = tx - bx, ty - by
                        local length = math.sqrt(dx * dx + dy * dy)
                        if length > 8 then
                            local ux, uy = dx / length, dy / length
                            local px, py = -uy, ux
                            local rad = tonumber(m.radius) or 0
                            local half_r
                            -- At least the projected body half-width plus a
                            -- margin so both edges sit outside the model.
                            local from_span = span * 0.37
                            local from_rad = 0
                            if rad > 0.18 and h > 0.4 then
                                from_rad = span * (rad / h) * 1.20
                            end
                            half_r = from_span
                            if from_rad > half_r then half_r = from_rad end
                            if half_r < 16 then half_r = 16 end
                            if half_r > span * 0.48 then half_r = span * 0.48 end
                            local mid_x, mid_y = (bx + tx) * 0.5, (by + ty) * 0.5
                            local ang_axis = math.atan2(dy, dx)
                            local pang = math.atan2(py, px)
                            local shimmer = 0.88 + 0.12 * math.sin(tnow * 0.005 + (m.id or 0) * 0.37)
                            local half_len = length * 0.5
                            local thick = math.max(5, math.min(11, half_r * 0.28))
                            emit_g(items, bx, by, half_r * 1.20, half_r * 1.20, 0,
                                cr, cg, cb, 0.58 * fadeI * shimmer, 'mkfloor', '')
                            -- back sheet (texture is transparent down the middle)
                            emit_g(items, mid_x, mid_y, half_r * 1.04, half_len, pang,
                                cr, cg, cb, 0.16 * fadeI * shimmer, 'mkcyl', '')
                            for side = -1, 1, 2 do
                                local ex = mid_x + px * half_r * side
                                local ey = mid_y + py * half_r * side
                                emit_g(items, ex, ey, half_len, thick * 1.20, ang_axis,
                                    cr, cg, cb, 0.36 * fadeI * shimmer, 'mkglow', '')
                                emit_g(items, ex, ey, half_len * 0.98, thick * 0.48, ang_axis,
                                    cr * 1.08, cg * 1.06, cb * 1.04, 0.58 * fadeI * shimmer, 'mkbeam', '')
                            end
                            -- faint front sheet, still hollow
                            emit_g(items, mid_x, mid_y, half_r * 0.98, half_len, pang,
                                cr, cg, cb, 0.08 * fadeI * shimmer, 'mkcyl', '')
                            for k = 1, 5 do
                                local u = (tnow * 0.00028 + k * 0.17) % 1.0
                                local angp = k * 2.199 + tnow * 0.0027 + (m.id or 0) * 0.13
                                local edge = math.abs(math.cos(angp))
                                if edge > 0.34 then
                                    local gx = bx + dx * u + px * math.cos(angp) * half_r
                                    local gy = by + dy * u + py * math.cos(angp) * half_r
                                    local gs = math.max(5, half_r * 0.20) * (1.05 - u * 0.22)
                                    local ga = 0.40 * fadeI * shimmer * ((edge - 0.34) / 0.66) * (1.0 - u * 0.32)
                                    emit_g(items, gx, gy, gs, gs, 0, cr, cg, cb, ga, 'mkglow', '')
                                end
                            end
                            beams = beams + 1
                        end
                    end
                end
                if want_icon and head_ok then
                    local bob = math.sin(tnow * 0.004 + (m.id or 0) * 0.73) * math.max(2.0, span * 0.035)
                    local sz = span * 0.52
                    if sz < 18 then sz = 18 elseif sz > 56 then sz = 56 end
                    -- Crown = floor + full height. Then lift by a nameplate-sized
                    -- margin plus half the glyph so the icon sits clearly above
                    -- the name and HP bar (t346 landed on the forehead).
                    local plate = span * 0.80
                    if plate < 64 then plate = 64 elseif plate > 140 then plate = 140 end
                    local ix, iy = hx, hy - plate - sz * 0.50 + bob
                    if iy < sz * 0.55 then iy = sz * 0.55 end
                    rec.ix, rec.iy, rec.sz, rec.plate = ix, iy, sz, plate
                    local pulse = 0.88 + 0.12 * math.sin(tnow * 0.006 + (m.id or 0))
                    emit_g(items, ix, iy, sz * 0.78, sz * 0.78, 0,
                        cr, cg, cb, 0.32 * fadeI * pulse, 'mkglow', '')
                    emit_g(items, ix, iy, sz * 0.56, sz * 0.56, 0,
                        cr, cg, cb, 0.92 * fadeI, icon_tex(rule.icon), '')
                    icons = icons + 1
                end
            end
            MK._last_proj[#MK._last_proj + 1] = rec
        end
    end
    MK._last_icons, MK._last_beams, MK._last_skips = icons, beams, skips
    if (tnow - (MK.log_t or 0)) >= 1000 then
        MK.log_t = tnow
        local p
        for i = 1, #(MK._last_proj or {}) do
            if MK._last_proj[i].reason == 'draw' then p = MK._last_proj[i]; break end
        end
        if not p then p = MK._last_proj[1] end
        local aura_on = aura_wanted() and 1 or 0
        local glive = (ground_wants_draw() or (markers_wanted() and #MK.live > 0)) and 1 or 0
        if p then
            marklog(string.format(
                'MARK live=%d drawn=%d/%d skip=%d trailN=%d aura=%d glive=%d id=%s name=%s h=%.2f z=%s fz=%s foff=%.2f feet=%.1f,%.1f,rc=%s crown=%.1f,%.1f,rc=%s icon=%.1f,%.1f span=%.1f sz=%.1f plate=%.1f reason=%s',
                #MK.live, icons, beams, skips, TRAIL_N or 0, aura_on, glive,
                tostring(p.id), tostring(p.name or '-'), p.h or 0,
                tostring(p.z or '-'), tostring(p.fz or '-'), p.foff or 0,
                p.fx or -1, p.fy or -1, tostring(p.frc),
                p.hx or -1, p.hy or -1, tostring(p.hrc),
                p.ix or -1, p.iy or -1, p.span or 0, p.sz or 0, p.plate or 0,
                p.reason or '-'))
        else
            marklog(string.format('MARK live=%d drawn=0 skip=%d trailN=%d aura=%d glive=%d',
                #MK.live, skips, TRAIL_N or 0, aura_on, glive))
        end
    end
    return items
end

local function marker_wants_draw()
    return markers_wanted() and #MK.live > 0
end

function M.ground_live()
    -- Same wake hook the aura uses so the overlay (and its DX11 canvas)
    -- stays presented while standing still. Trail-only wake was why
    -- markers disappeared the moment the player stopped walking.
    return ground_wants_draw() or marker_wants_draw()
end

function M.marker_force_scan()
    MK.last_done = 0
    MK.scanning = false
end

function M.marker_nearby()
    return MK.nearby
end

function M.debug_marker_live()
    return MK.live
end

function M.debug_marker_scan()
    local sticky = 0
    for _ in pairs(MK.by_id) do sticky = sticky + 1 end
    return {
        scanning = MK.scanning, idx = MK.idx, total = MK.total,
        last_done = MK.last_done, nlive = #MK.live, nnearby = #MK.nearby,
        nsticky = sticky,
        icons = MK._last_icons or 0, beams = MK._last_beams or 0,
        skips = MK._last_skips or 0,
    }
end

function M.debug_marker_items()
    return collect_marker_sprites()
end

function M.debug_marker_proj()
    return MK._last_proj or {}
end

-- Body FX (t357-nimbus): EQ-style nimbus (glowbody02 body glow pulses at the
-- chest, motes on hand/chest spheres, floor pool). No rays/pillars/rings.
-- one table so the main chunk stays under Lua's 200-local limit.
local BF = {
    preview_t = 0, preview_style = nil, cap = 68,
    ok = {
        inferno = true, frost = true, storm = true, holy = true,
        void = true, toxic = true, arcane = true, blood = true,
    },
    col = {
        inferno = { 1.16, 0.42, 0.10 },
        frost   = { 0.48, 0.84, 1.14 },
        storm   = { 0.52, 0.82, 1.22 },
        holy    = { 1.16, 1.04, 0.48 },
        void    = { 0.62, 0.26, 1.02 },
        toxic   = { 0.38, 1.00, 0.20 },
        arcane  = { 0.76, 0.40, 1.16 },
        blood   = { 1.10, 0.14, 0.12 },
    },
    st = { ok = false, log_t = 0, last_n = 0, last_style = 'inferno' },
    -- Nimbus colour ramps start->end (0..1) from spellsnew.edd emitters.
    -- '*' = brightness-normalized (ADD on dark ground hides dark colours).
    ramp = {
        inferno = { { 1.00, 1.00, 1.00 }, { 1.00, 0.00, 0.00 } }, -- 462 Burning Pyrilen 'flame chest'
        frost   = { { 0.88, 1.00, 1.00 }, { 0.00, 0.75, 0.95 } }, -- 644 Frost 'fog_nimbus'
        storm   = { { 1.00, 1.00, 1.00 }, { 0.00, 0.54, 1.00 } }, -- 455 Tranquil 'quellious01' (glowbody02)
        holy    = { { 0.99, 0.96, 0.44 }, { 0.99, 0.96, 0.44 } }, -- 511 Daylight 'daylight'
        void    = { { 0.07, 0.05, 0.25 }, { 0.27, 0.20, 1.00 } }, -- 512 Midnight (0,0,0)->(27,20,100) *
        toxic   = { { 0.72, 1.00, 0.00 }, { 0.75, 1.00, 0.08 } }, -- 446 Plaguebringer bertox (49,68,0)->(55,74,6) *
        arcane  = { { 1.00, 0.58, 0.35 }, { 0.80, 0.54, 1.00 } }, -- 467 Mata Muram (glowbody02) *
        blood   = { { 1.00, 0.33, 0.33 }, { 0.67, 0.00, 0.00 } }, -- 546 Blood Aura mist->aura *
    },
    mote = {
        inferno = 'ember', frost = 'snow', storm = 'bxspark', holy = 'bxspark',
        void = 'bxspark', toxic = 'bubble', arcane = 'bxspark', blood = 'bxspark',
    },
    -- glowbody02 sprite: half extent = NQ * span * scale (scale 1.45 -> 1.0,
    -- EQ quellious01 width 8.5 -> 4.0 compressed). Texture hole cut at NQ, scale>=1.
    NQ = 0.70, NLIFE = 2000, NSPAWN = 500, NFADE = 750, NPEAK = 0.25,
    -- Stage 3: GPU particle path (combatfx/bodyfx_gpu.lua); Lua sprites above stay the fallback
    gpu = { on = false, h = {}, bufs = {}, style = nil, key = nil, avail = nil, masked = false,
        next_check = 0, last_ok = 0, fail_t = nil, alive = 0, mode = 0, err = nil },
}

function BF.size()
    local C = core()
    local s = 100
    if C and C.cfg and C.cfg.bodyfx then
        s = tonumber(C.cfg.bodyfx.size) or 100
    end
    if s < 50 then s = 50 elseif s > 200 then s = 200 end
    return s / 100
end

function BF.intensity()
    local C = core()
    local g, b = 1, 0.80
    if C and C.cfg then
        g = (tonumber(C.cfg.intensity) or 100) / 100
        if C.cfg.bodyfx then
            b = (tonumber(C.cfg.bodyfx.intensity) or 80) / 100
        end
    end
    if g < 0.15 then g = 0.15 end
    if b < 0.15 then b = 0.15 end
    return g * b
end

function BF.wanted()
    local t = now()
    if BF.preview_t and BF.preview_t > t and BF.preview_style then
        return true, BF.preview_style
    end
    local C = core()
    local cfg = (C and C.cfg and C.cfg.bodyfx) or {}
    if cfg.on ~= true then return false, cfg.style or 'inferno' end
    -- t362: the old overlay glow is opt-in and never drawn while EQ's native nimbus is selected
    if cfg.overlay ~= true or (tonumber(cfg.native) or 0) > 0 then return false, cfg.style or 'inferno' end
    local st = tostring(cfg.style or 'inferno')
    if not BF.ok[st] then st = 'inferno' end
    return true, st
end

function BF.profile(t)
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    if t < 0.18 then
        return 0.72 + t / 0.18 * 0.20
    elseif t < 0.42 then
        return 0.92 + (t - 0.18) / 0.24 * 0.10
    elseif t < 0.58 then
        return 1.02 - (t - 0.42) / 0.16 * 0.16
    elseif t < 0.78 then
        return 0.86 + (t - 0.58) / 0.20 * 0.28
    end
    return 1.14 - (t - 0.78) / 0.22 * 0.52
end

function BF.okxy(x, y)
    if type(x) ~= 'number' or type(y) ~= 'number' then return false end
    if x ~= x or y ~= y then return false end
    if math.abs(x) > 8000 or math.abs(y) > 8000 then return false end
    return true
end

function BF.update()
    local S = BF.st
    S.ok = false
    if not BF.wanted() then BF.gpu_off(); return end
    local wx, wy, wz = me_xyz()
    if type(wx) ~= 'number' or type(wy) ~= 'number' or type(wz) ~= 'number' then return end
    local floor_z = me_floor_z(wz)
    local ah = me_height()
    if not ah or ah < 1.4 then ah = 5.6 end
    -- Player spawn Z is the chest/origin, not the crown. On PCs,
    -- AvatarHeight equals (Z - FloorZ), so floor+AH lands at the chest
    -- (t350: head y matched self w2s of Me.Z). t351 used 0.52 and the
    -- computed crown sat above the nameplate. Origin is ~65% up the
    -- visible mesh (chest), matching a nameplate-just-above-head crown.
    -- Tests/NPCs keep AH when it is already a full floor-to-crown value.
    local mid_off = wz - floor_z
    local inferred = 0
    if mid_off > 0.35 then
        inferred = mid_off / 0.66
    end
    local height = ah
    if mid_off > 0.35 and ah < mid_off * 1.20 then
        height = inferred
    end
    if height < 2.4 then height = 2.4 end
    if height > 14 then height = 14 end
    local fx, fy = project_world(wx, wy, floor_z)
    local hx, hy = project_world(wx, wy, floor_z + height)
    if not BF.okxy(fx, fy) or not BF.okxy(hx, hy) then
        local id = me_id()
        if id and id > 0 then
            fx, fy = project_screen(id, floor_z - wz)
            hx, hy = project_screen(id, floor_z + height - wz)
        end
    end
    if not BF.okxy(fx, fy) or not BF.okxy(hx, hy) then return end
    local dx, dy = hx - fx, hy - fy
    local span = math.sqrt(dx * dx + dy * dy)
    if span < 18 then return end
    S.ok, S.fx, S.fy, S.hx, S.hy = true, fx, fy, hx, hy
    -- Chest (0.66) and shoulders (0.70) sit on the feet→crown axis so every
    -- layer shares the same screen-x as the body, even when the camera tilts
    -- and feet.x != head.x. Live t353 holy had feet.x == head.x == 960; the
    -- detached blob was not an x-mismatch (see collect() ray notes).
    S.cx = fx + dx * 0.66
    S.cy = fy + dy * 0.66
    S.ox = fx + dx * 0.70
    S.oy = fy + dy * 0.70
    S.span = span
    S.ux, S.uy = dx / span, dy / span
    S.ppx, S.ppy = -S.uy, S.ux
    S.src = 'world'
    S.height = height
    S.ah = ah
    S.infer = inferred
    S.mid_off = mid_off
    S.floor_z = floor_z
    S.wz = wz
    S.sz = BF.size()
    S.hw = span * 0.30 * S.sz
    S.bang = math.atan2(S.ppy, S.ppx)
    -- aura rework: the pool is a WORLD disc (radius 0.32 * height) projected with 16 points; the old
    -- 4-point box + 0.8*shoulder(screen span) sizing grew and shrank with the camera yaw / pitch.
    -- Centre stays the projected floor point (fx, fy) so the pool never parks in front of the boots.
    local disc_R = height * 0.32
    if disc_R < 1.6 then disc_R = 1.6 end
    if disc_R > 5.0 then disc_R = 5.0 end
    local _, _, qrx, qry, nq = world_ellipse(wx, wy, floor_z, disc_R)
    S.qok = qrx ~= nil
    if not S.qok then qrx, qry = span * 0.40, span * 0.40 * 0.36 end
    S.qrx, S.qry = qrx, qry
    S.prx, S.pry = math.max(8, qrx), math.max(6, qry)
    -- body width scale (see body_wspan): >= 1, 1 when the camera looks level
    local wsp = body_wspan(wx, wy, floor_z, height)
    S.wmul = 1
    if wsp and wsp > span then S.wmul = math.min(4, wsp / span) end
    S.hw = span * 0.30 * S.sz * S.wmul
end

-- ---- tfx1: player body capsule for TextFX numbers (rml_tfx_exclude), independent of Body FX ----------
-- Reuses BF.st when BF.update projected this frame; otherwise projects feet/crown the same way (cached 50 ms).
-- Returns fx, fy, ux, uy, span, src ('bf' | 'world' | 'screen'); nil when the body is not projectable
-- (themefx then uses a conservative default capsule centred low on the screen).
function M.player_capsule()
    local S = BF.st
    if S.ok and S.span and S.span >= 18 then return S.fx, S.fy, S.ux, S.uy, S.span, 'bf', S.wmul or 1 end
    local t = now()
    local P = M._pcap
    if P and t - P.t < 50 then
        if P.ok then return P.fx, P.fy, P.ux, P.uy, P.span, P.src, P.wmul or 1 end
        return nil
    end
    P = P or {}; M._pcap = P; P.t = t; P.ok = false
    if not M._ready then pcall(ensure) end
    if not M._ready then return nil end
    local wx, wy, wz = me_xyz()
    if type(wx) ~= 'number' or type(wy) ~= 'number' or type(wz) ~= 'number' then return nil end
    local floor_z = me_floor_z(wz)
    local ah = me_height()
    if not ah or ah < 1.4 then ah = 5.6 end
    local mid_off = wz - floor_z
    local height = ah
    if mid_off > 0.35 and ah < mid_off * 1.20 then height = mid_off / 0.66 end
    if height < 2.4 then height = 2.4 end
    if height > 14 then height = 14 end
    local src = 'world'
    local fx, fy = project_world(wx, wy, floor_z)
    local hx, hy = project_world(wx, wy, floor_z + height)
    if not BF.okxy(fx, fy) or not BF.okxy(hx, hy) then
        local id = me_id()
        if id and id > 0 then
            fx, fy = project_screen(id, floor_z - wz)
            hx, hy = project_screen(id, floor_z + height - wz)
            src = 'screen'
        end
    end
    if not BF.okxy(fx, fy) or not BF.okxy(hx, hy) then return nil end
    local dx, dy = hx - fx, hy - fy
    local span = math.sqrt(dx * dx + dy * dy)
    if span < 18 then return nil end
    P.ok, P.fx, P.fy, P.ux, P.uy, P.span, P.src = true, fx, fy, dx / span, dy / span, span, src
    local wsp = (src == 'world') and body_wspan(wx, wy, floor_z, height) or nil
    P.wmul = (wsp and wsp > span) and math.min(4, wsp / span) or 1
    return P.fx, P.fy, P.ux, P.uy, P.span, P.src, P.wmul
end

-- ---- Stage 3: Body FX on MQ2RmlUi GPU particles --------------------------------------------------
-- Emitters (glow, haze, sparks, accent) live in the DLL, anchored at the projected feet with
-- px_per_unit = feet->crown span; the capsule (rml_fx_exclude) masks every particle pixel and, with
-- rml_features() & 1024, the bloom too. Without 1024 the canvas bloom is forced to 0 while GPU body
-- FX is on, so no light can land on the body either way. Any failure falls back to the Lua path.
function BF.gpu_avail()
    local Gs = BF.gpu
    local t = now()
    local C0 = core()
    if C0 and C0.cfg and C0.cfg.bodyfx and C0.cfg.bodyfx.gpu == false then return false end
    if Gs.avail ~= nil and t < Gs.next_check then return Gs.avail end
    Gs.next_check = t + 5000
    local ok, feat, lib = false, 0, M._api
    local Ccfg = core()
    local bcfg = Ccfg and Ccfg.cfg and Ccfg.cfg.bodyfx or {}
    if lib and bcfg.gpu ~= false then
        pcall(function()
            local v = tonumber(lib.rml_api_version()) or 0
            feat = tonumber(lib.rml_features()) or 0
            ok = v >= 5 and math.floor(feat / 512) % 2 == 1 and lib.rml_fx_create ~= nil
                and lib.rml_fx_anchor ~= nil and lib.rml_fx_exclude ~= nil and lib.rml_fx_destroy ~= nil
        end)
    end
    if ok and not Gs.G then
        local okr, G = pcall(require, 'combatfx.bodyfx_gpu')
        if okr and type(G) == 'table' and G.build then Gs.G = G else ok = false end
    end
    if ok and not Gs.capbuf then
        Gs.capbuf = ffi.new('float[13]')
        Gs.statbuf = ffi.new('char[512]')
        pcall(function() require('mq').bind('/cfxprobe', function() M.body_probe() end) end)
    end
    Gs.avail = ok
    Gs.masked = ok and math.floor(feat / 1024) % 2 == 1
    return ok
end

function BF.gpu_off()
    local Gs = BF.gpu
    if next(Gs.h) or Gs.on then
        for _, h in pairs(Gs.h) do pcall(function() M._api.rml_fx_destroy(h) end) end
        pcall(function() M._api.rml_fx_exclude(WIN, ID, nil, 0) end)
    end
    Gs.h, Gs.style, Gs.key, Gs.on = {}, nil, nil, false
end

local function bf_fill(buf, d)
    for k = 0, 63 do buf[k] = tonumber(d[k]) or 0 end
end

function BF.gpu_sync(style)
    local Gs, S, lib = BF.gpu, BF.st, M._api
    local G = Gs.G
    local sz, fi = BF.size(), BF.intensity()
    local key = string.format('%s|%.2f|%.2f', style, sz, fi)
    if Gs.style ~= style then BF.gpu_off() end
    if not next(Gs.h) then
        local layers = G.build(style, sz, fi)
        for i, ly in ipairs(layers) do
            Gs.bufs[i] = Gs.bufs[i] or ffi.new('float[64]')
            bf_fill(Gs.bufs[i], ly.d)
            local h = 0
            pcall(function() h = tonumber(lib.rml_fx_create(WIN, ID, Gs.bufs[i], 64)) or 0 end)
            if h > 0 then Gs.h[i] = h end
        end
        if not next(Gs.h) then
            Gs.on, Gs.err, Gs.fail_t = false, 'create', now()
            return false
        end
        Gs.style, Gs.key, Gs.err = style, key, nil
    elseif Gs.key ~= key then
        local layers = G.build(style, sz, fi)
        for i, ly in ipairs(layers) do
            local h, buf = Gs.h[i], Gs.bufs[i]
            if h and buf then
                bf_fill(buf, ly.d)
                pcall(function() lib.rml_fx_update(h, buf, 64) end)
            end
        end
        Gs.key = key
    end
    local lost = false
    for _, h in pairs(Gs.h) do
        local rc = 0
        pcall(function() rc = tonumber(lib.rml_fx_anchor(h, S.fx, S.fy, S.span, 0)) or 0 end)
        if rc == 0 then lost = true end
    end
    if lost then                       -- document reloaded / window reopened: emitters gone, recreate
        BF.gpu_off()
        Gs.err, Gs.fail_t = 'lost', now()
        return false
    end
    local cp = G.capsule(S.fx, S.fy, S.ux, S.uy, S.span, Gs.caps, S.wmul)
    Gs.caps = cp
    for i = 0, 12 do Gs.capbuf[i] = cp[i] end
    local rc = 0
    pcall(function() rc = tonumber(lib.rml_fx_exclude(WIN, ID, Gs.capbuf, 13)) or 0 end)
    if rc ~= 1 then                    -- never draw particles without the body mask
        BF.gpu_off()
        Gs.err, Gs.fail_t = 'exclude', now()
        return false
    end
    Gs.on = true
    return true
end

function BF.gpu_tick()
    local Gs, S = BF.gpu, BF.st
    local on, style = BF.wanted()
    if not on then BF.gpu_off(); return end
    if not BF.gpu_avail() then
        if Gs.on then BF.gpu_off() end
        return
    end
    if Gs.fail_t and (now() - Gs.fail_t) < 2000 then return end
    if S.ok then
        Gs.last_ok = now()
        BF.gpu_sync(style)
    elseif Gs.on and (now() - (Gs.last_ok or 0)) > 400 then
        BF.gpu_off()
    end
end

function BF.gpu_alive()
    local Gs, n = BF.gpu, 0
    if not (Gs.on and Gs.statbuf) then return 0 end
    for _, h in pairs(Gs.h) do
        pcall(function()
            if tonumber(M._api.rml_fx_stats(h, Gs.statbuf, 512)) == 1 then
                n = n + (tonumber(ffi.string(Gs.statbuf):match('alive=(%d+)')) or 0)
            end
        end)
    end
    pcall(function() Gs.mode = tonumber(M._api.rml_fx_mode(-1)) or 0 end)
    Gs.alive = n
    return n
end

function M.body_mode()
    local Gs = BF.gpu
    return Gs.on and 'gpu' or 'lua', Gs.alive or 0, Gs.masked, Gs.avail, Gs.err
end

-- /cfxprobe: one GPU readback of the next canvas frame (Logs\rmlui_canvas.log 'probe ...',
-- Logs\rmlui_probe_scene.png) plus the capsule used right now in combatfx_fx.log
function M.body_probe()
    local Gs, S = BF.gpu, BF.st
    pcall(function() M._api.rml_canvas_probe() end)
    local c = Gs.caps or {}
    marklog(string.format('PROBE armed rev=%s mode=%s masked=%s style=%s caps=%.1f,%.1f,%.3f,%.3f,%.1f knots=x%.2f feather=%.1fpx feet=%.1f,%.1f crown=%.1f,%.1f',
        M.REV, Gs.on and 'gpu' or 'lua', tostring(Gs.masked), tostring(Gs.style),
        c[0] or 0, c[1] or 0, c[2] or 0, c[3] or 0, c[4] or 0, (Gs.G and Gs.G.KNOT_MUL) or 0,
        c[12] or 0, S.fx or 0, S.fy or 0, S.hx or 0, S.hy or 0))
    print('\at[combatfx]\ax probe armed: Logs\\rmlui_probe_scene.png + rmlui_canvas.log; capsule in combatfx_fx.log')
end

function BF.wants_draw()
    return BF.wanted() and BF.st.ok == true
end

-- Conservative on-screen body exclusion (no depth test, so we never
-- paint over the silhouette). Capsule from feet to crown+8%, ~0.50
-- span wide at the shoulders and ~0.30 span wide at the head.
function BF.excl_hw(t)
    if t < 0 then t = 0 elseif t > 1.08 then t = 1.08 end
    local w
    if t < 0.20 then
        w = 0.18 + (0.16 - 0.18) * (t / 0.20)
    elseif t < 0.42 then
        w = 0.16 + (0.22 - 0.16) * ((t - 0.20) / 0.22)
    elseif t < 0.70 then
        w = 0.22 + (0.25 - 0.22) * ((t - 0.42) / 0.28)
    elseif t < 0.84 then
        w = 0.25 + (0.16 - 0.25) * ((t - 0.70) / 0.14)
    elseif t < 0.94 then
        w = 0.16 + (0.15 - 0.16) * ((t - 0.84) / 0.10)
    else
        w = 0.15
    end
    return (w + 0.02) * BF.st.span
end

function BF.inside_excl(x, y)
    local S = BF.st
    if not S.ok then return false end
    local vx, vy = x - S.fx, y - S.fy
    local along = vx * S.ux + vy * S.uy
    local t = along / S.span
    local perp = vx * S.ppx + vy * S.ppy
    -- Bottom edge is the feet line: t < 0 is the ground in front of the
    -- boots (where the pool lives) and must stay clear of the capsule.
    if t < 0 then return false end
    if t > 1.08 then
        local cx = S.fx + S.ux * S.span * 1.08
        local cy = S.fy + S.uy * S.span * 1.08
        local dx, dy = x - cx, y - cy
        local hw = BF.excl_hw(1.08)
        return (dx * dx + dy * dy) < (hw * hw)
    end
    return math.abs(perp) < BF.excl_hw(t)
end

function BF.excl_exit(ox, oy, dx, dy)
    local S = BF.st
    local margin = S.span * 0.050
    local maxd = S.span * 0.95
    local n, last = 56, -1
    for i = 0, n do
        local d = maxd * i / n
        if BF.inside_excl(ox + dx * d, oy + dy * d) then
            last = d
        elseif last >= 0 then
            break
        end
    end
    if last < 0 then return margin end
    return last + margin
end

function BF.quad_clear(mx, my, rw, half, ang)
    local ca, sa = math.cos(ang or 0), math.sin(ang or 0)
    -- 3x3 samples (corners, edge midpoints, center) so a long thin
    -- beam cannot chord through the capsule with all four corners out.
    for iu = -1, 1 do
        for iv = -1, 1 do
            local lx, ly = rw * iu, half * iv
            local x = mx + lx * ca - ly * sa
            local y = my + lx * sa + ly * ca
            if BF.inside_excl(x, y) then return false end
        end
    end
    return true
end

function BF.shell_mul(x, y)
    local S = BF.st
    if not S.ok then return 0 end
    local vx, vy = x - S.fx, y - S.fy
    local along = vx * S.ux + vy * S.uy
    local t = along / S.span
    if t < -0.10 or t > 1.14 then return 0 end
    local tc = t
    if tc < 0 then tc = 0 elseif tc > 1 then tc = 1 end
    local nx = vx * S.ppx + vy * S.ppy
    local half = S.hw * BF.profile(tc)
    if half < 4 then half = 4 end
    local rn = math.abs(nx) / half
    -- Keep motes off the torso and face; allow them in a tight band
    -- around the outline (within ~1 body width).
    if t > 0.82 and t < 1.06 and rn < 0.78 then return 0 end
    if rn < 0.72 then return 0 end
    if rn < 0.92 then return (rn - 0.72) / 0.20 end
    if rn < 1.65 then return 1 end
    if rn < 2.15 then return 1.0 - (rn - 1.65) / 0.50 end
    return 0
end

function BF.rim(t, side, rmul)
    local S = BF.st
    local px = S.fx + (S.hx - S.fx) * t
    local py = S.fy + (S.hy - S.fy) * t
    local half = S.hw * BF.profile(t) * (rmul or 1)
    return px + S.ppx * side * half, py + S.ppy * side * half
end

function BF.collect()
    local items = {}
    local on, style = BF.wanted()
    local S = BF.st
    if not on or not S.ok then
        S.last_n = 0
        return items
    end
    local tnow = now()
    local fadeI = BF.intensity()
    local sz = S.sz or 1
    local col = BF.col[style] or BF.col.inferno
    local cr, cg, cb = cap3(col[1], col[2], col[3], 1.12)
    local span = S.span
    local bang = S.bang or 0
    local pulse = 0.88 + 0.12 * math.sin(tnow * 0.0028)

    local function emit_p(x, y, sx, sy, ang, r, g, b, a, tex, gated)
        if #items >= BF.cap then return end
        if not a or a < 0.018 then return end
        if gated then
            if BF.inside_excl(x, y) then return end
            if not BF.quad_clear(x, y, sx, sy, ang or 0) then return end
            a = a * BF.shell_mul(x, y)
            if a < 0.018 then return end
        end
        r, g, b = cap3(r, g, b, 1.12)
        emit_g(items, x, y, sx, sy, ang, r, g, b, a, tex, 'ADD')
    end

    -- Ground disc centered on the projected feet point (same FloorZ
    -- projection as the feet aura). Texture is clear above the feet line
    -- so it cannot wash the legs; radius is 0.8x shoulder width.
    local prx = S.prx or (span * 0.40)
    local pry = S.pry or (prx * 0.36)
    emit_p(S.fx, S.fy, prx, pry, bang,
        cr, cg, cb, 0.48 * fadeI * pulse, 'bxdisc', false)

    local nglow, drawn, dropped = 0, 0, 0
    if not BF.gpu.on then
    -- Nimbus body glow (EQ quellious01 / mata_muram_chest): one glowbody
    -- copy spawned every 0.5 s, 2 s life, 0.75 s fade in/out, size
    -- 8.5 -> 4.0, peak alpha 0.25, colour ramp start->end. The texture is
    -- hollow at scale 1, and scale never drops below 1, so the hole always
    -- contains the exclusion capsule.
    local ramp = BF.ramp[style] or BF.ramp.inferno
    local c0, c1 = ramp[1], ramp[2]
    local grow = sz
    if grow < 1 then grow = 1 end
    local base = math.floor(tnow / BF.NSPAWN) * BF.NSPAWN
    nglow = 0
    for j = 0, math.floor(BF.NLIFE / BF.NSPAWN) - 1 do
        local age = tnow - (base - j * BF.NSPAWN)
        if age >= 0 and age < BF.NLIFE then
            local k = age / BF.NLIFE
            local fin = age / BF.NFADE
            local fout = (BF.NLIFE - age) / BF.NFADE
            local env = math.min(1, fin, fout)
            -- EQ 8.5 -> 4.0 (ratio 2.1) compressed onto 1.45 -> 1.0 of the
            -- body-hugging size: at the full ratio the visible mid-life copy
            -- floats a body-width away from the silhouette.
            local scl = 1.0 + 0.45 * ((8.5 - 4.5 * k) - 4.0) / 4.5
            local q = BF.NQ * span * scl * grow
            local r = c0[1] + (c1[1] - c0[1]) * k
            local g = c0[2] + (c1[2] - c0[2]) * k
            local b = c0[3] + (c1[3] - c0[3]) * k
            local n0 = #items
            -- spread copies dim with area so the big early copies read as
            -- soft haze, not nested outlines
            local wgt = 1 / scl
            emit_p(S.cx, S.cy, q, q, bang, r, g, b,
                BF.NPEAK * env * wgt * fadeI, 'bxnimb', false)
            if #items > n0 then nglow = nglow + 1 end
        end
    end

    -- Motes on small spheres around each hand and a wider sphere around
    -- the chest (EQ 'quellious hands': 0.2 sphere, size 0.2 -> 1.0,
    -- opacity 0.2). Any mote whose quad touches the capsule is dropped.
    drawn, dropped = 0, 0
    local mtex = BF.mote[style] or 'bxspark'
    local mr = c1[1] * 0.65 + 0.35
    local mg = c1[2] * 0.65 + 0.35
    local mb = c1[3] * 0.65 + 0.35
    local function mote(x, y, ss, a, tex)
        if #items >= BF.cap then return end
        if BF.inside_excl(x, y) or not BF.quad_clear(x, y, ss, ss, 0) then
            dropped = dropped + 1
            return
        end
        local n0 = #items
        emit_p(x, y, ss, ss, 0, mr, mg, mb, a, tex, false)
        if #items > n0 then drawn = drawn + 1 end
    end
    local hand_t = 0.40
    local hand_off = span * 0.31
    local hr = span * 0.075 * sz
    local P = 1600
    for side = -1, 1, 2 do
        local hx = S.fx + (S.hx - S.fx) * hand_t + S.ppx * side * hand_off
        local hy = S.fy + (S.hy - S.fy) * hand_t + S.ppy * side * hand_off
        for i = 1, 9 do
            local age = (tnow + i * (P / 9) + (side > 0 and 90 or 0)) % P
            local k = age / P
            local th = i * 2.399963 + k * 2.6 * side
            local rr = hr * (0.45 + 0.55 * ((i * 0.618034) % 1))
            local x = hx + S.ppx * math.cos(th) * rr + S.ux * math.sin(th) * rr * 0.85
            local y = hy + S.ppy * math.cos(th) * rr + S.uy * math.sin(th) * rr * 0.85
            local ss = span * 0.030 * sz * (0.35 + 0.65 * k)
            local a = (0.10 + 0.10 * ((i % 3) / 2)) * math.sin(math.pi * k) * fadeI * 1.25
            mote(x, y, ss, a, (i % 3 == 0) and mtex or 'bxspark')
        end
    end
    local cr2 = span * 0.40 * sz
    for i = 1, 14 do
        local age = (tnow + i * (2200 / 14)) % 2200
        local k = age / 2200
        local th = i * 2.399963 + k * 1.9
        local ph = ((i * 0.754877) % 1) * 2 - 1
        local rr = cr2 * (0.85 + 0.15 * math.sqrt(1 - ph * ph))
        local x = S.cx + S.ppx * math.cos(th) * rr + S.ux * ph * cr2 * 0.95
        local y = S.cy + S.ppy * math.cos(th) * rr + S.uy * ph * cr2 * 0.95
        local ss = span * 0.026 * sz * (0.35 + 0.65 * k)
        local a = (0.10 + 0.10 * ((i % 2))) * math.sin(math.pi * k) * fadeI * 1.25
        mote(x, y, ss, a, (i % 4 == 0) and mtex or 'bxspark')
    end
    end -- not BF.gpu.on
    S.nglow, S.nspark, S.ndrop = nglow, drawn, dropped

    if (tnow - (S.log_t or 0)) >= 1000 then
        S.log_t = tnow
        marklog(string.format(
            'BODY rev=%s height=%.2f glow=%d spk=%d drop=%d drawn=%d style=%s feet=%.1f,%.1f head=%.1f,%.1f cx=%.1f,%.1f pool=%.1f,%.1f pr=%.1f,%.1f span=%.1f src=%s glive=%d size=%d inten=%d floorz=%.2f z=%.2f ah=%.2f infer=%.2f h=%.2f mode=%s fxmode=%d alive=%d emitters=%d masked=%s bloom=%.2f caps=%.1f,%.1f,%.3f,%.3f,%.1f knotmul=%.2f feather=%.1fpx look=%s gpuerr=%s',
            M.REV, S.height or 0, S.nglow or 0, S.nspark or 0, S.ndrop or 0,
            #items, style, S.fx or 0, S.fy or 0, S.hx or 0, S.hy or 0,
            S.cx or 0, S.cy or 0, S.fx or 0, S.fy or 0, S.prx or 0, S.pry or 0, span,
            S.src or '?',
            (ground_wants_draw() or marker_wants_draw() or true) and 1 or 0,
            math.floor(sz * 100 + 0.5), math.floor(fadeI * 100 + 0.5),
            S.floor_z or 0, S.wz or 0, S.ah or 0, S.infer or 0, S.height or 0,
            BF.gpu.on and 'gpu' or 'lua', BF.gpu.mode or 0, BF.gpu_alive(), (function() local n = 0; for _ in pairs(BF.gpu.h) do n = n + 1 end; return n end)(),
            tostring(BF.gpu.masked), BF.gpu.bloom or 0,
            (BF.gpu.caps or {})[0] or 0, (BF.gpu.caps or {})[1] or 0, (BF.gpu.caps or {})[2] or 0, (BF.gpu.caps or {})[3] or 0, (BF.gpu.caps or {})[4] or 0,
            (BF.gpu.G and BF.gpu.G.KNOT_MUL) or 0, (BF.gpu.caps or {})[12] or 0, tostring(BF.gpu.G and BF.gpu.G.REV), tostring(BF.gpu.err)))
    end
    S.last_n = #items
    S.last_style = style
    return items
end

function M.preview_body(style)
    style = tostring(style or 'inferno')
    if not BF.ok[style] then style = 'inferno' end
    BF.preview_style = style
    BF.preview_t = now() + 2200
    BF.update()
end

function M.debug_body_items()
    return BF.collect()
end

function M.debug_body()
    return BF.st
end

function M.debug_body_inside(x, y)
    return BF.inside_excl(x, y)
end

function M.debug_body_quad_ok(x, y, sx, sy, ang)
    return BF.quad_clear(x, y, sx, sy, ang)
end

function M.debug_body_excl_hw(t)
    return BF.excl_hw(t)
end

function M.ground_live()
    return ground_wants_draw() or marker_wants_draw() or BF.wants_draw()
end



CUR_R, RING_CAP = 160, nil
M.last_R, M.last_half_h, M.last_size_src, M.last_body_h = CUR_R, nil, 'fallback', nil

local function proj_spawn(id, frac)
    if not (M._api and HAS_OV and id and id > 0) then return nil, nil, -1 end
    if not _sx then _sx = ffi.new('float[1]'); _sy = ffi.new('float[1]') end
    local rc = -1
    pcall(function()
        rc = tonumber(M._api.rml_spawn_to_overlay(id, frac, W, H, _sx, _sy)) or -1
    end)
    if rc >= 0 then return _sx[0], _sy[0], rc end
    return nil, nil, rc
end

local function proj_world(x, y, z)
    if not (M._api and M._api.rml_world_to_overlay) then return nil, nil, -1 end
    if not _sx then _sx = ffi.new('float[1]'); _sy = ffi.new('float[1]') end
    local rc = -1
    pcall(function()
        rc = tonumber(M._api.rml_world_to_overlay(x, y, z, W, H, _sx, _sy)) or -1
    end)
    if rc >= 0 then return _sx[0], _sy[0], rc end
    return nil, nil, rc
end

local function target_body_height()
    if M._debug_body_h and M._debug_body_h > 0 then
        return M._debug_body_h, 'debug'
    end
    if M._debug_half_h and M._debug_half_h > 0 then
        return M._debug_half_h, 'debug'
    end
    if BODY_H and BODY_H > 0 then
        return BODY_H, 'w2s-body'
    end
    if last_good_bh and last_good_bh > 0 then
        return last_good_bh, 'w2s-hold'
    end
    return nil, 'proj-fail'
end

-- Pure helper so tests and burst_radius share one formula.
-- body_h is the on-screen feet-to-head span. R is half that span so a burst
-- from mid-body reaches head and feet. Fallback 0.09W proc / 0.12W crit.
-- Clamp: min 60px at 1080p (distant mobs stay visible), max 0.70 H so a
-- close-up dummy can fill itself instead of the old 320px cap.
function M.compute_burst_radius(kind, w, h, body_h, size_pct)
    w = w or W
    h = h or H
    local scale = math.max(0.50, math.min(2.00, (tonumber(size_pct) or 100) / 100))
    local R
    if body_h and body_h > 0 then
        R = ((kind == 'crit') and 0.52 or 0.50) * body_h
    else
        R = (kind == 'crit') and (0.12 * w) or (0.09 * w)
    end
    local min_r = 60 * (h / 1080)
    local max_r = 0.70 * h
    R = math.max(min_r, math.min(max_r, R))
    return R * scale
end

local function burst_radius(kind)
    local body_h, src = target_body_height()
    local fs = style_cfg()
    local size_pct = fs and tonumber(fs.size) or 100
    local R = M.compute_burst_radius(kind, W, H, body_h, size_pct)
    CUR_R = R
    RING_CAP = R * 1.20
    M.last_R, M.last_half_h, M.last_size_src = R, body_h, body_h and src or 'fallback'
    M.last_body_h = body_h
    return R
end

local function body_span()
    if BODY_H and BODY_H > 0 then return BODY_H end
    if M.last_body_h and M.last_body_h > 0 then return M.last_body_h end
    if CUR_R and CUR_R > 1 then return CUR_R * 2 end
    return 320
end

-- Fraction of on-screen body height, with a floor so a ~165px dummy still
-- gets readable sprites instead of 3px embers.
local function psz(frac, minpx)
    return math.max(minpx or 8, body_span() * frac)
end

local function pal_rgb(pal)
    if pal == 'fire' then return 1.18, 0.40, 0.10
    elseif pal == 'cold' then return 0.42, 0.84, 1.28
    elseif pal == 'poison' then return 0.40, 1.08, 0.20
    elseif pal == 'magic' then return 0.78, 0.40, 1.28
    elseif pal == 'crit' then return 1.35, 1.08, 0.38
    elseif pal == 'storm' then return 0.55, 0.82, 1.45
    elseif pal == 'shadow' then return 0.48, 0.16, 0.82
    elseif pal == 'holy' then return 1.35, 1.18, 0.55
    elseif pal == 'blood' then return 1.15, 0.12, 0.10
    end
    return 1.20, 0.92, 0.32
end

local function tex_or(name, fallback)
    if TEX[name] and TEX[name] > 0 then return name end
    return fallback
end

local function pf(kind, x, y, vx, vy, life, r, g, b, a, rx, ry, tex)
    local p = spawn(x, y, vx, vy, life, r, g, b, a, rx, ry)
    p.kind, p.tex, p.follow = kind, tex, true
    return p
end

local function hit_dir()
    local ok, mq = pcall(require, 'mq')
    local id = 0
    if ok and mq and mq.TLO and mq.TLO.Me then
        pcall(function() id = tonumber(mq.TLO.Me.ID()) or 0 end)
    end
    if id > 0 then
        local px, py, rc = proj_spawn(id, 0.55)
        if rc and rc >= 0 and px and py then
            local dx, dy = AX - px, AY - py
            local len = math.sqrt(dx * dx + dy * dy)
            if len > 12 and len < (W + H) then
                return dx / len, dy / len
            end
        end
    end
    return 0.72, 0.70
end

local function bolt_segments(x0, y0, x1, y1, depth, jag, out)
    if depth <= 0 then
        out[#out + 1] = { x0, y0, x1, y1 }
        return
    end
    local dx, dy = x1 - x0, y1 - y0
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 5 then
        out[#out + 1] = { x0, y0, x1, y1 }
        return
    end
    local mx, my = (x0 + x1) * 0.5, (y0 + y1) * 0.5
    local px, py = -dy / len, dx / len
    local off = (math.random() * 2 - 1) * jag * len
    mx, my = mx + px * off, my + py * off
    bolt_segments(x0, y0, mx, my, depth - 1, jag * 0.52, out)
    bolt_segments(mx, my, x1, y1, depth - 1, jag * 0.52, out)
end

local IDENTITY_TEX = {
    core = true, rune = true, glyph = true, void = true, halo = true,
    crack = true, puddle = true, splash = true,
}

local function stamp_orbit(p, R, opts)
    opts = opts or {}
    local bh = body_span()
    local half = bh * 0.50
    local az = opts.az or (math.random() * 6.28318)
    local y = opts.y
    -- Full feet-to-head: y in [-half, +half]
    if y == nil then y = (math.random() * 2 - 1) * half * 0.98 end
    -- Cylinder width ~0.9 * body height (radius up to 0.45 bh), filled not a thin shell
    local rad = opts.rad or (bh * (0.16 + math.random() * 0.29))
    p.follow = true
    p.orbit = true
    p.orb_a0 = az
    p.orb_r0 = rad * (opts.r0mul or 0.88)
    p.orb_r1 = rad * (opts.r1mul or 1.08)
    local spin = opts.spin
    if not spin then
        spin = (math.random() < 0.5 and -1 or 1) * (1.8 + math.random() * 2.8)
    end
    p.orb_spin = spin
    p.orb_y0 = y
    p.orb_rise = opts.rise or (-bh * (0.06 + math.random() * 0.16))
    local r0 = p.orb_r0 or 8
    p.x = math.cos(az) * r0
    p.y = y
    local z = math.sin(az) * r0
    p.depth = z / math.max(10, r0)
end

local function weave_body_motion()
    local R = (CUR_R > 1) and CUR_R or 160
    local bh = body_span()
    local half = bh * 0.50
    local life_floor = EMIT_MS * style_life()
    for i = 1, nparts do
        local p = parts[i]
        if p and COMBAT_FX_KIND[p.kind] then
            local ident = p.core or IDENTITY_TEX[p.tex] or p.fixed_ang
            if ident then
                p.follow = true
                p.life = math.max(p.life or 0, life_floor)
                p.max = math.max(p.max or 0, p.life)
                p.depth = p.depth or 0
                if p.tex == 'puddle' or p.tex == 'crack' then
                    p.y = half * 0.92
                    p.orbit = nil
                end
            elseif p.bounce or p.ground then
                p.follow = true
                p.y = (p.y or 0) + half * 0.35
                p.depth = (math.random() * 2 - 1) * 0.75
                p.ground = half * 0.96
            elseif p.drip then
                p.follow = true
                p.x = (math.random() - 0.5) * bh * 0.40
                p.y = (math.random() - 0.5) * half * 0.95
                p.depth = (math.random() * 2 - 1) * 0.6
            else
                if p.orbit and p.orb_y0 == nil then
                    p.orb_y0 = (math.random() * 2 - 1) * half * 0.98
                    p.orb_rise = p.orb_rise or (-bh * (0.06 + math.random() * 0.14))
                    if not p.orb_r0 or p.orb_r0 < bh * 0.12 then
                        local rad = bh * (0.16 + math.random() * 0.29)
                        p.orb_r0, p.orb_r1 = rad * 0.88, rad * 1.08
                    end
                    local r0 = p.orb_r0 or 8
                    local az = p.orb_a0 or 0
                    p.x = math.cos(az) * r0
                    p.y = p.orb_y0
                    p.depth = math.sin(az)
                elseif not p.orbit then
                    stamp_orbit(p, R)
                end
                p.follow = true
                p.life = math.max(p.life or 0, 820 * style_life())
                p.max = math.max(p.max or 0, p.life)
            end
        end
    end
end

local STREAM_HZ = {
    inferno = 88, fire = 88, frost = 80, toxic = 76, poison = 76,
    disease = 64, arcane = 74, storm = 52, lightning = 52,
    shadow = 56, holy = 56, blood = 70, wind = 52, water = 60,
    earth = 42, critgold = 64,
}

local function start_emitter(kind, name)
    emitter = {
        kind = kind,
        name = name or 'arcane',
        elapsed = 0,
        dur = EMIT_MS * style_life(),
        acc = 0,
        tint = TINT and { TINT[1], TINT[2], TINT[3] } or nil,
        bolt_cd = 0,
    }
end

local function emit_stream_one(name, kind)
    local R = (CUR_R > 1) and CUR_R or 160
    local bh = body_span()
    if name == 'inferno' or name == 'fire' then
        if math.random() < 0.32 then
            local p = pf(kind, 0, 0, 0, 0, 620 + math.random() * 220,
                1.25, 0.62, 0.16, 0.90, psz(0.15, 16), psz(0.38, 38), 'flame0')
            p.frames = { 'flame0', 'flame1', 'flame2', 'flame3' }
            p.fps = 12 + (p.frames and 2 or 0)
            p.flicker = math.random() * 6.28318
            stamp_orbit(p, R, { rise = -bh * 0.20 })
        else
            local p = pf(kind, 0, 0, 0, 0, 740 + math.random() * 260,
                1.25, 0.72, 0.18, 0.86, psz(0.055, 8), psz(0.055, 8), 'ember')
            p.palette, p.flicker = 'fire', math.random() * 6.28318
            stamp_orbit(p, R)
        end
    elseif name == 'frost' then
        if math.random() < 0.55 then
            local texs = { 'ice0', 'ice1', 'ice2' }
            local tex = texs[1 + math.floor(math.random() * 3)]
            local sz = psz(0.14, 18) * (0.85 + math.random() * 0.35)
            local p = pf(kind, 0, 0, 0, 0, 760 + math.random() * 220,
                0.78, 0.92, 1.05, 0.82, sz, sz * (0.72 + math.random() * 0.28), tex)
            p.blend, p.rot = 'alpha', math.random() * 6.28318
            p.spin_r = (math.random() - 0.5) * 8
            p.tone_cap = 1.05
            stamp_orbit(p, R)
        else
            local p = pf(kind, 0, 0, 0, 0, 880 + math.random() * 220,
                0.62, 0.78, 0.95, 0.40, psz(0.24, 24), psz(0.20, 20), 'mist')
            p.blend, p.grow0, p.grow1 = 'alpha', 0.55, 1.25
            p.tone_cap = 1.02
            stamp_orbit(p, R)
        end
    elseif name == 'toxic' or name == 'poison' then
        if math.random() < 0.42 then
            local sz = psz(0.12, 14)
            local p = pf(kind, 0, 0, 0, 0, 700 + math.random() * 200,
                1, 1, 1, 0.88, sz, sz, 'bubble')
            p.blend, p.grow0, p.grow1 = 'alpha', 0.40, 1.15
            stamp_orbit(p, R, { rise = -bh * 0.14 })
        else
            local p = pf(kind, 0, 0, 0, 0, 860 + math.random() * 180,
                1, 1, 1, 0.58, psz(0.26, 28), psz(0.22, 24), 'gas')
            p.blend, p.grow0, p.grow1 = 'alpha', 0.50, 1.35
            stamp_orbit(p, R)
        end
    elseif name == 'disease' then
        if math.random() < 0.40 then
            local p = pf(kind, 0, 0, 0, 0, 900 + math.random() * 180,
                1, 1, 1, 0.84, psz(0.16, 16), psz(0.14, 14), 'spore')
            p.blend, p.grow0, p.grow1 = 'alpha', 0.45, 1.25
            stamp_orbit(p, R)
        else
            local p = pf(kind, 0, 0, 0, 0, 740 + math.random() * 180,
                0.78, 0.56, 0.14, 0.88, psz(0.06, 8), psz(0.06, 8), 'speck')
            p.blend = 'alpha'
            stamp_orbit(p, R)
        end
    elseif name == 'arcane' then
        if math.random() < 0.40 then
            local p = pf(kind, 0, 0, 0, 0, 960 + math.random() * 180,
                1.00, 0.52, 1.45, 0.78, psz(0.14, 15), psz(0.14, 15), 'glyph')
            p.spin_r = (math.random() < 0.5 and -1 or 1) * (1.2 + math.random() * 1.6)
            stamp_orbit(p, R, { spin = 4 + math.random() * 3 })
        else
            local p = pf(kind, 0, 0, 0, 0, 880 + math.random() * 180,
                1.18, 0.60, 1.52, 0.90, psz(0.08, 10), psz(0.08, 10), 'ember')
            p.palette = 'magic'
            stamp_orbit(p, R, { spin = 4.5 + math.random() * 3 })
        end
    elseif name == 'storm' or name == 'lightning' then
        if emitter and (emitter.bolt_cd or 0) <= 0 then
            emitter.bolt_cd = 0.10
            local a = math.random() * 6.28318
            local rad = bh * (0.16 + math.random() * 0.26)
            local y0 = (math.random() * 2 - 1) * bh * 0.46
            local y1 = (math.random() * 2 - 1) * bh * 0.46
            if math.abs(y1 - y0) < bh * 0.35 then
                y1 = y0 + ((y0 < 0) and 1 or -1) * bh * (0.40 + math.random() * 0.20)
            end
            local x0 = math.cos(a) * rad
            local x1 = math.cos(a + (math.random() - 0.5) * 1.1) * rad * (0.80 + math.random() * 0.35)
            local segs = {}
            bolt_segments(x0, y0, x1, y1, 3, 0.26, segs)
            for si = 1, #segs do
                local sg = segs[si]
                local sx, sy = (sg[1] + sg[3]) * 0.5, (sg[2] + sg[4]) * 0.5
                local dx, dy = sg[3] - sg[1], sg[4] - sg[2]
                local slen = math.sqrt(dx * dx + dy * dy)
                if slen > 2 then
                    local p = pf(kind, sx, sy, 0, 0, 170, 1.45, 1.65, 2.05, 0.88, slen * 0.5, math.max(4.5, psz(0.035, 5)), 'bolt')
                    p.orient, p.fixed_ang = true, math.atan2(dy, dx)
                    p.streak, p.thick = slen * 1.05, math.max(6, psz(0.045, 6))
                    p.follow = true
                    p.depth = math.sin(a)
                    p.tone_cap = 1.55
                end
            end
        else
            local p = pf(kind, 0, 0, 0, 0, 420, 1.25, 1.45, 1.85, 0.80, psz(0.05, 7), psz(0.05, 7), 'ember')
            p.palette = 'storm'
            stamp_orbit(p, R)
        end
    elseif name == 'shadow' then
        if math.random() < 0.35 then
            local a = math.random() * 6.28318
            local x, y = math.cos(a) * bh * 0.32, math.sin(a) * bh * 0.42
            local p = pf(kind, x, y, -x * 0.8, -y * 0.4, 700 + math.random() * 140,
                0.55, 0.16, 0.95, 0.80, 1, 1, 'tendril')
            p.blend, p.orient = 'alpha', true
            p.streak, p.thick = psz(0.22, 22), psz(0.05, 7)
            p.follow = true
            p.depth = math.sin(a)
        else
            local p = pf(kind, 0, 0, 0, 0, 620 + math.random() * 140,
                0.55, 0.18, 0.85, 0.76, psz(0.055, 8), psz(0.055, 8), 'ember')
            p.palette = 'shadow'
            stamp_orbit(p, R)
        end
    elseif name == 'holy' then
        local p = pf(kind, 0, 0, 0, 0, 820 + math.random() * 200,
            1.25, 1.10, 0.55, 0.76, psz(0.055, 8), psz(0.055, 8), 'ember')
        p.palette, p.flicker = 'holy', math.random() * 6.28318
        stamp_orbit(p, R, { rise = -bh * 0.22 })
    elseif name == 'blood' then
        if math.random() < 0.32 then
            local splats = { 'splat0', 'splat1', 'splat2' }
            local p = pf(kind, 0, 0, 0, 0, 980 + math.random() * 200,
                1, 1, 1, 0.88, psz(0.12, 14), psz(0.10, 12), splats[1 + math.floor(math.random() * 3)])
            p.blend = 'alpha'
            p.rot = math.random() * 6.28318
            stamp_orbit(p, R)
        else
            local p = pf(kind, 0, 0, 0, 0, 760 + math.random() * 220,
                1, 1, 1, 0.90, psz(0.055, 8), psz(0.085, 11), 'bdrop')
            p.blend = 'alpha'
            stamp_orbit(p, R)
        end
    elseif name == 'wind' then
        local tex = (math.random() < 0.4) and 'dust' or ((math.random() < 0.5) and 'leaf0' or 'leaf1')
        local p = pf(kind, 0, 0, 0, 0, 840 + math.random() * 180, 1, 1, 1, 0.84, psz(0.055, 8), psz(0.04, 6), tex)
        p.blend = 'alpha'
        if tex == 'dust' then p.rx, p.ry, p.a = psz(0.08, 10), psz(0.065, 8), 0.58 end
        stamp_orbit(p, R, { spin = 6 + math.random() * 5 })
    elseif name == 'water' then
        local p = pf(kind, 0, 0, 0, 0, 780 + math.random() * 180,
            0.78, 1.05, 1.30, 0.88, psz(0.05, 7), psz(0.08, 10), 'wdrop')
        p.blend, p.orient = 'alpha', true
        p.streak, p.thick = psz(0.10, 12), psz(0.055, 8)
        stamp_orbit(p, R, { rise = -bh * 0.12 })
    elseif name == 'earth' then
        local p = pf(kind, 0, 0, 0, 0, 1100 + math.random() * 160,
            1, 1, 1, 1.0, psz(0.055, 8), psz(0.045, 7), 'pebble')
        p.blend = 'alpha'
        p.rot = math.random() * 6.28318
        p.spin_r = (math.random() - 0.5) * 16
        p.follow = true
        p.x = (math.random() - 0.5) * bh * 0.40
        p.y = bh * 0.08 + (math.random() - 0.3) * bh * 0.20
        p.vx = (math.random() - 0.5) * bh * 0.40
        p.vy = -bh * (0.10 + math.random() * 0.16)
        p.grav, p.bounce, p.ground = 420, 0.32, bh * 0.48
        p.depth = (math.random() * 2 - 1) * 0.7
    else
        if math.random() < 0.35 then
            local a = math.random() * 6.28318
            local p = pf(kind, 0, 0, 0, 0, 560 + math.random() * 200,
                1.35, 1.10, 0.42, 0.88, psz(0.05, 7), psz(0.02, 4), 'streak')
            p.palette, p.orient = 'crit', true
            p.streak, p.thick = psz(0.14, 16), psz(0.04, 6)
            stamp_orbit(p, R, { az = a })
        else
            local p = pf(kind, 0, 0, 0, 0, 680 + math.random() * 220,
                1.25, 1.00, 0.38, 0.86, psz(0.05, 7), psz(0.05, 7), 'ember')
            p.palette, p.flicker = 'crit', math.random() * 6.28318
            stamp_orbit(p, R)
        end
    end
end

local function tick_emitter(dt)
    if not emitter then return end
    emitter.elapsed = (emitter.elapsed or 0) + dt * 1000
    if emitter.elapsed >= (emitter.dur or EMIT_MS) then
        emitter = nil
        return
    end
    emitter.bolt_cd = (emitter.bolt_cd or 0) - dt
    if not fx_on('dx11_particles') then return end
    local hz = STREAM_HZ[emitter.name] or 24
    if lite() then hz = hz * 0.55 end
    if hz < 4 then hz = 4 end
    emitter.acc = (emitter.acc or 0) + dt
    local interval = 1 / hz
    local saved = TINT
    TINT = emitter.tint
    local guard = 0
    while emitter.acc >= interval and guard < 16 do
        emitter.acc = emitter.acc - interval
        guard = guard + 1
        emit_stream_one(emitter.name, emitter.kind)
    end
    TINT = saved
end

local function emit_gold_crit(kind)
    local R = burst_radius(kind)
    if fx_on('dx11_glow') then
        local p = pf(kind, 0, 0, 0, 0, 180, 2.4, 2.0, 1.05, 1.0, R * 0.18, R * 0.18, 'core')
        p.core, p.palette = true, 'crit'
        local fl = pf(kind, 0, 0, 0, 0, 220, 1.8, 1.45, 0.55, 0.85, R * 0.95, math.max(10, R * 0.045), 'flare')
        fl.palette = 'crit'
    end
    if not fx_on('dx11_particles') then return end
    local ns = lite() and 10 or 18
    for i = 1, ns do
        local a = math.random() * 6.28318
        local spd = R * (1.15 + math.random() * 1.35)
        local p = pf(kind, math.cos(a) * 8, math.sin(a) * 8, math.cos(a) * spd, math.sin(a) * spd,
            520 + math.random() * 260, 1.4, 1.15, 0.45, 0.92, R * 0.055, R * 0.018, 'streak')
        p.palette, p.orient = 'crit', true
        p.streak, p.thick = R * (0.16 + math.random() * 0.12), 5.5
        p.drag, p.grav = 0.85, 40
    end
    local ng = lite() and 14 or 26
    for i = 1, ng do
        local a = math.random() * 6.28318
        local spd = R * (0.9 + math.random() * 1.4)
        local p = pf(kind, 0, 0, math.cos(a) * spd, math.sin(a) * spd, 640 + math.random() * 280,
            1.3, 1.05, 0.4, 0.9, 3.5, 3.5, 'ember')
        p.palette, p.drag, p.grav = 'crit', 0.7, 25
        p.flicker = math.random() * 6.28318
    end
end

local function emit_frost(kind)
    local R = burst_radius(kind)
    if not fx_on('dx11_particles') and not fx_on('dx11_glow') then return end
    -- No giant additive core/flare/crackle: those stacked into a white blob.
    if fx_on('dx11_glow') then
        local core = pf(kind, 0, 0, 0, 0, 240, 0.85, 1.05, 1.15, 0.40, psz(0.10, 12), psz(0.10, 12), 'core')
        core.blend, core.tone_cap, core.fade_late = 'alpha', 1.05, 120
    end
    local n = lite() and 22 or 40
    for i = 1, n do
        local sz = psz(0.14, 18) * (0.80 + math.random() * 0.40)
        local tex = (i % 3 == 0) and 'ice0' or ((i % 3 == 1) and 'ice1' or 'ice2')
        local p = pf(kind, 0, 0, 0, 0, 780 + math.random() * 240,
            0.75, 0.90, 1.02, 0.84, sz, sz * (0.72 + math.random() * 0.28), tex)
        p.blend = 'alpha'
        p.rot, p.spin_r = math.random() * 6.28318, (math.random() - 0.5) * 10
        p.tone_cap = 1.05
        p.fade_late = 280
        stamp_orbit(p, R)
    end
    local nm = lite() and 10 or 20
    for i = 1, nm do
        local p = pf(kind, 0, 0, 0, 0, 900 + math.random() * 240,
            0.60, 0.78, 0.92, 0.42, psz(0.26, 26), psz(0.22, 22), 'mist')
        p.blend = 'alpha'
        p.grow0, p.grow1 = 0.50, 1.30
        p.tone_cap = 1.02
        p.fade_late = 260
        stamp_orbit(p, R)
    end
end

local function emit_fire(kind)
    local R = burst_radius(kind)
    if fx_on('dx11_glow') then
        local p = pf(kind, 0, 0, 0, 0, 220, 2.0, 1.3, 0.40, 0.85, psz(0.12, 14), psz(0.12, 14), 'core')
        p.core, p.palette = true, 'fire'
    end
    if not fx_on('dx11_particles') then return end
    local nf = lite() and 10 or 20
    for i = 1, nf do
        local p = pf(kind, 0, 0, 0, 0, 640 + math.random() * 220,
            1.28, 0.68, 0.16, 0.92, psz(0.15, 16), psz(0.38, 38), 'flame0')
        p.frames = { 'flame0', 'flame1', 'flame2', 'flame3' }
        p.fps = 13 + i % 3
        p.flicker = math.random() * 6.28318
        stamp_orbit(p, R, { rise = -body_span() * 0.18 })
    end
    local ne = lite() and 28 or 55
    for i = 1, ne do
        local p = pf(kind, 0, 0, 0, 0, 740 + math.random() * 320,
            1.25, 0.72, 0.18, 0.88, psz(0.055, 8), psz(0.055, 8), 'ember')
        p.palette, p.flicker = 'fire', math.random() * 6.28318
        stamp_orbit(p, R)
    end
    local ns = lite() and 5 or 10
    for i = 1, ns do
        local p = pf(kind, 0, 0, 0, 0, 960 + math.random() * 200,
            0.22, 0.20, 0.18, 0.55, psz(0.18, 18), psz(0.16, 16), 'smoke')
        p.blend = 'alpha'
        p.delay = 120 + i * 30
        p.grow0, p.grow1 = 0.45, 1.55
        p.fade_late = 280
        stamp_orbit(p, R, { rise = -body_span() * 0.10 })
    end
end

local function emit_wind(kind)
    local R = burst_radius(kind)
    if not fx_on('dx11_particles') then return end
    local ng = lite() and 8 or 14
    for i = 1, ng do
        local p = spawn(0, 0, 0, 0, 820 + math.random() * 160, 0.95, 1.08, 1.22, 0.82, 1, 1)
        p.kind, p.tex, p.follow = kind, 'gust', true
        p.orbit, p.orb_r0, p.orb_r1 = true, R * 0.10, R * math.min(1.35, 0.48 + 0.06 * i)
        p.orb_a0 = (i / ng) * 6.28318
        p.orb_spin = 9.5 + i * 0.35
        p.orb_squash = 1.18
        p.orient, p.streak, p.thick = true, R * 0.62, R * 0.095
        p.flicker = math.random() * 6.28318
        p.fade_late = 220
    end
    local nl = lite() and 10 or 18
    for i = 1, nl do
        local tex = (i % 3 == 0) and 'dust' or ((i % 2 == 0) and 'leaf0' or 'leaf1')
        local p = spawn(0, 0, 0, 0, 880 + math.random() * 200, 1, 1, 1, 0.90, R * 0.048, R * 0.034)
        p.kind, p.tex, p.follow, p.blend = kind, tex, true, 'alpha'
        if tex == 'dust' then p.rx, p.ry, p.a = R * 0.07, R * 0.055, 0.62 end
        p.orbit, p.orb_r0, p.orb_r1 = true, R * 0.16, R * (0.40 + math.random() * 0.50)
        p.orb_a0 = math.random() * 6.28318
        p.orb_spin = 7 + math.random() * 6
        p.orb_squash = 1.15
        p.rot = math.random() * 6.28318
        p.spin_r = (math.random() - 0.5) * 18
        p.fade_late = 220
    end
end

local function emit_water(kind)
    local R = burst_radius(kind)
    if not fx_on('dx11_particles') then return end
    local sheet = pf(kind, 0, R * 0.04, 0, -R * 0.06, 620, 0.80, 1.05, 1.30, 0.96, R * 0.72, R * 0.48, 'splash')
    sheet.blend = 'alpha'
    sheet.grow0, sheet.grow1 = 0.42, 1.18
    sheet.fade_late = 220
    local sheet2 = pf(kind, 0, R * 0.08, 0, -R * 0.04, 540, 0.70, 0.95, 1.22, 0.72, R * 0.52, R * 0.32, 'splash')
    sheet2.blend = 'alpha'
    sheet2.grow0, sheet2.grow1 = 0.50, 1.10
    sheet2.fade_late = 200
    local n = lite() and 28 or 46
    for i = 1, n do
        local a = -2.95 + (i / n) * 2.70 + (math.random() - 0.5) * 0.10
        local spd = R * (0.58 + math.random() * 0.55)
        local p = pf(kind, 0, 0, math.cos(a) * spd, math.sin(a) * spd, 860 + math.random() * 160,
            0.78, 1.05, 1.30, 0.96, 6, 10, 'wdrop')
        p.blend = 'alpha'
        p.orient, p.streak, p.thick = true, R * (0.10 + math.random() * 0.08), 9.5
        p.grav, p.drag = 560, 0.20
    end
    local nf = lite() and 8 or 14
    for i = 1, nf do
        local a = -2.7 + (i / nf) * 2.2
        local p = pf(kind, math.cos(a) * R * 0.12, R * 0.02 + math.sin(a) * R * 0.04,
            math.cos(a) * 28, -30 - math.random() * 24, 700, 0.92, 0.97, 1.05, 0.82,
            R * 0.12, R * 0.09, 'foam')
        p.blend = 'alpha'
        p.grow0, p.grow1 = 0.45, 1.35
        p.grav, p.drag = -8, 0.6
        p.fade_late = 220
    end
    local pud = pf(kind, 0, R * 0.48, 0, 0, 1200, 0.60, 0.88, 1.15, 0.85, R * 0.56, R * 0.18, 'puddle')
    pud.blend = 'alpha'
    pud.grow0, pud.grow1 = 0.35, 1.0
    pud.fade_late = 320
    local nh = lite() and 10 or 16
    for i = 1, nh do
        local a = math.random() * 6.28318
        local p = pf(kind, math.cos(a) * R * 0.22, math.sin(a) * R * 0.12 - R * 0.08,
            math.cos(a) * 36, -50 - math.random() * 60, 520, 1.55, 1.75, 2.0, 0.88, 3.6, 3.6, 'snow')
        p.flicker = math.random() * 6.28318
    end
end

local function emit_poison(kind)
    local R = burst_radius(kind)
    if not fx_on('dx11_particles') then return end
    if fx_on('dx11_glow') then
        local gl = pf(kind, 0, 0, 0, 0, 520, 0.45, 1.25, 0.28, 0.40, psz(0.36, 32), psz(0.32, 28), 'flare')
        gl.blend, gl.fade_late = 'alpha', 180
    end
    local n = lite() and 20 or 36
    for i = 1, n do
        local sz = psz(0.12, 14)
        local p = pf(kind, 0, 0, 0, 0, 700 + math.random() * 260,
            1, 1, 1, 0.90, sz, sz, 'bubble')
        p.blend = 'alpha'
        p.grow0, p.grow1 = 0.68, 1.12
        p.fade_late = 220
        stamp_orbit(p, R)
    end
    local nd = lite() and 8 or 14
    for i = 1, nd do
        local p = pf(kind, (math.random() - 0.5) * R * 0.28, -R * 0.02,
            (math.random() - 0.5) * 18, 55 + math.random() * 85, 780 + math.random() * 200,
            1, 1, 1, 0.94, 5, 11, 'drip')
        p.blend = 'alpha'
        p.orient, p.drip, p.grav, p.drag = true, true, 220, 0.32
        p.streak = R * 0.11
    end
    local ng = lite() and 10 or 18
    for i = 1, ng do
        local p = pf(kind, 0, 0, 0, 0, 900 + math.random() * 200,
            1, 1, 1, 0.62, psz(0.26, 28), psz(0.22, 24), 'gas')
        p.blend = 'alpha'
        p.grow0, p.grow1 = 0.62, 1.35
        p.fade_late = 260
        stamp_orbit(p, R)
    end
end

local function emit_disease(kind)
    local R = burst_radius(kind)
    if not fx_on('dx11_particles') then return end
    if fx_on('dx11_glow') then
        local gl = pf(kind, 0, 0, 0, 0, 720, 1.15, 0.92, 0.28, 0.62, R * 0.58, R * 0.50, 'flare')
        gl.palette = 'disease'
        gl.fade_late = 220
        local c = pf(kind, 0, 0, 0, 0, 420, 1.20, 0.95, 0.30, 0.72, R * 0.18, R * 0.18, 'core')
        c.fade_late = 160
    end
    local n = lite() and 10 or 16
    for i = 1, n do
        local p = pf(kind, (math.random() - 0.5) * R * 0.32, (math.random() - 0.5) * R * 0.22,
            (math.random() - 0.5) * 18, (math.random() - 0.5) * 14, 960 + math.random() * 220,
            1, 1, 1, 0.92, R * 0.26, R * 0.22, 'spore')
        p.blend = 'alpha'
        p.grow0, p.grow1 = 0.42, 1.45
        p.fade_late = 280
        if i % 2 == 0 then
            p.orbit, p.orb_r0, p.orb_r1 = true, R * 0.10, R * (0.30 + math.random() * 0.22)
            p.orb_a0 = math.random() * 6.28318
            p.orb_spin = 3.2 + math.random() * 2.4
            p.orb_squash = 0.88
        else
            p.turb, p.drag = 42, 0.38
        end
    end
    local nf = lite() and 28 or 52
    for i = 1, nf do
        local a = math.random() * 6.28318
        local p = pf(kind, math.cos(a) * R * 0.16, math.sin(a) * R * 0.12,
            math.cos(a) * 70, math.sin(a) * 70, 880 + math.random() * 240,
            0.78, 0.56, 0.14, 0.98, 5.8, 5.8, 'speck')
        p.blend = 'alpha'
        p.turb, p.drag = 380, 0.10
        p.fade_late = 220
    end
end

local function emit_earth(kind)
    local R = burst_radius(kind)
    if not fx_on('dx11_particles') then return end
    local n = lite() and 8 or 12
    local rocks = { 'rock0', 'rock1', 'rock2' }
    for i = 1, n do
        local a = (i / n) * 6.28318 + math.random() * 0.35
        local spd = R * (0.48 + math.random() * 0.62)
        local sz = R * (0.18 + math.random() * 0.12)
        local p = pf(kind, 0, -R * 0.02, math.cos(a) * spd, math.sin(a) * spd * 0.42 - R * 0.22,
            1400 + math.random() * 200, 1, 1, 1, 1.0, sz, sz * (0.78 + math.random() * 0.22), rocks[((i - 1) % 3) + 1])
        p.blend = 'alpha'
        p.rot = math.random() * 6.28318
        p.spin_r = (math.random() - 0.5) * 14
        p.grav, p.bounce, p.ground = 480, 0.36, R * 0.52
        p.drag = 0.28
        p.fade_late = 340
    end
    local npb = lite() and 14 or 24
    for i = 1, npb do
        local a = math.random() * 6.28318
        local spd = R * (0.55 + math.random() * 0.85)
        local p = pf(kind, 0, 0, math.cos(a) * spd, math.sin(a) * spd * 0.45 - R * 0.18,
            1200 + math.random() * 180, 1, 1, 1, 1.0, R * 0.055, R * 0.044, 'pebble')
        p.blend = 'alpha'
        p.rot = math.random() * 6.28318
        p.spin_r = (math.random() - 0.5) * 20
        p.grav, p.bounce, p.ground = 460, 0.32, R * 0.52
        p.fade_late = 280
    end
    for i = 1, 3 do
        local dust = pf(kind, (i - 2) * R * 0.12, R * 0.32 + (i - 2) * 8, (i - 2) * 10, -10,
            980, 1, 1, 1, 0.80, R * (0.34 + i * 0.06), R * 0.22, 'dust')
        dust.blend = 'alpha'
        dust.grow0, dust.grow1 = 0.40, 1.50
        dust.fade_late = 280
    end
    local ck = pf(kind, 0, R * 0.50, 0, 0, 1400, 1, 1, 1, 0.98, R * 0.95, R * 0.38, 'crack')
    ck.blend = 'alpha'
    ck.grow0, ck.grow1 = 0.35, 1.0
    ck.fade_late = 360
end

local function emit_lightning(kind)
    local R = burst_radius(kind)
    local bh = body_span()
    local half = bh * 0.50
    if not fx_on('dx11_particles') and not fx_on('dx11_glow') then return end
    if fx_on('dx11_glow') then
        local fl = pf(kind, 0, 0, 0, 0, 280, 0.85, 1.15, 1.55, 0.38, psz(0.40, 36), psz(0.52, 50), 'flare')
        fl.palette = 'storm'
        fl.fade_late = 140
    end
    if not fx_on('dx11_particles') then return end
    -- Body-length bolts that climb the cylinder instead of bursting from the chest.
    local nbolts = lite() and 5 or 8
    for i = 1, nbolts do
        local az = (i / nbolts) * 6.28318 + (math.random() - 0.5) * 0.35
        local rad = bh * (0.16 + math.random() * 0.24)
        local y0 = half * (0.78 + math.random() * 0.18)
        local y1 = -half * (0.78 + math.random() * 0.18)
        local x0 = math.cos(az) * rad
        local x1 = math.cos(az + (math.random() - 0.5) * 0.9) * rad * (0.80 + math.random() * 0.35)
        local segs = {}
        bolt_segments(x0, y0, x1, y1, lite() and 3 or 4, 0.28, segs)
        if i % 2 == 0 and #segs > 3 then
            local mid = segs[math.max(2, math.floor(#segs * 0.45))]
            local ba = az + ((i % 4 == 0) and 0.85 or -0.85)
            bolt_segments(mid[3], mid[4], mid[3] + math.cos(ba) * bh * 0.18, mid[4] + math.sin(ba) * bh * 0.12,
                3, 0.26, segs)
        end
        local z = math.sin(az)
        for _, sg in ipairs(segs) do
            local sx, sy = (sg[1] + sg[3]) * 0.5, (sg[2] + sg[4]) * 0.5
            local dx, dy = sg[3] - sg[1], sg[4] - sg[2]
            local slen = math.sqrt(dx * dx + dy * dy)
            if slen > 2 then
                local p = pf(kind, sx, sy, 0, 0, 220, 1.55, 1.75, 2.15, 0.95, slen * 0.5, math.max(4.5, psz(0.032, 5)), 'bolt')
                p.orient, p.fixed_ang = true, math.atan2(dy, dx)
                p.streak, p.thick = slen * 1.08, math.max(6.5, psz(0.042, 6))
                p.depth, p.flicker = z, math.random() * 6.28318
            end
        end
    end
    local ns = lite() and 16 or 30
    for i = 1, ns do
        local p = pf(kind, 0, 0, 0, 0, 480 + math.random() * 160,
            1.30, 1.50, 1.90, 0.86, psz(0.05, 7), psz(0.05, 7), 'ember')
        p.palette, p.flicker = 'storm', math.random() * 6.28318
        stamp_orbit(p, R)
    end
end

local function emit_blood(kind)
    local R = burst_radius(kind)
    if not fx_on('dx11_particles') then return end
    local dx, dy = hit_dir()
    local base = math.atan2(dy, dx)
    -- Body-wrapping gore (the engulf layer), then a smaller flying spray.
    local splats = { 'splat0', 'splat1', 'splat2' }
    local ns = lite() and 16 or 28
    for i = 1, ns do
        local p = pf(kind, 0, 0, 0, 0, 1200 + math.random() * 220,
            1, 1, 1, 0.90, psz(0.12, 14), psz(0.10, 12), splats[((i - 1) % 3) + 1])
        p.blend = 'alpha'
        p.rot = math.random() * 6.28318
        p.grow0, p.grow1 = 0.70, 1.05
        p.fade_late = 300
        stamp_orbit(p, R)
    end
    local ndrop = lite() and 20 or 36
    for i = 1, ndrop do
        local p = pf(kind, 0, 0, 0, 0, 860 + math.random() * 220,
            1, 1, 1, 0.90, psz(0.055, 8), psz(0.085, 11), 'bdrop')
        p.blend = 'alpha'
        stamp_orbit(p, R)
    end
    local n = lite() and 10 or 18
    for i = 1, n do
        local a = base + (math.random() - 0.5) * 1.20
        local spd = R * (0.70 + math.random() * 0.70)
        local p = pf(kind, 0, 0, math.cos(a) * spd, math.sin(a) * spd, 640 + math.random() * 240,
            1, 1, 1, 0.92, psz(0.04, 6), psz(0.07, 9), 'bdrop')
        p.blend = 'alpha'
        p.orient, p.streak, p.thick = true, psz(0.12, 14), psz(0.06, 8)
        p.grav, p.drag, p.drip = 240, 0.36, true
    end
end

local function emit_arcane(kind)
    local R = burst_radius(kind)
    if not fx_on('dx11_particles') and not fx_on('dx11_glow') then return end
    -- Tall oval rune + halo so the sigil covers feet-to-head, not just the chest.
    local rune = pf(kind, 0, 0, 0, 0, 1500, 1.10, 0.58, 1.60, 0.88, psz(0.42, 40), psz(0.56, 54), 'rune')
    rune.spin_r = 0.55
    rune.grow0, rune.grow1 = 0.88, 1.06
    local aura = pf(kind, 0, 0, 0, 0, 1500, 0.78, 0.40, 1.28, 0.40, psz(0.44, 42), psz(0.56, 54), 'halo')
    aura.grow0, aura.grow1 = 0.86, 1.08
    local g = pf(kind, 0, 0, 0, 0, 1300, 1.10, 0.55, 1.55, 0.82, psz(0.20, 18), psz(0.20, 18), 'glyph')
    g.spin_r = -1.15
    local ng = lite() and 12 or 22
    for i = 1, ng do
        local p = pf(kind, 0, 0, 0, 0, 1100 + math.random() * 200,
            1.05, 0.52, 1.48, 0.78, psz(0.13, 14), psz(0.13, 14), 'glyph')
        p.spin_r = (math.random() < 0.5 and -1 or 1) * (1.1 + math.random() * 1.8)
        stamp_orbit(p, R, { spin = 3.6 + (i % 3) * 1.2 })
    end
    local nm = lite() and 30 or 56
    for i = 1, nm do
        local p = pf(kind, 0, 0, 0, 0, 1000 + math.random() * 180,
            1.20, 0.62, 1.55, 0.92, psz(0.08, 10), psz(0.08, 10), 'ember')
        p.palette, p.flicker = 'magic', math.random() * 6.28318
        stamp_orbit(p, R, { spin = 4.8 + (i % 3) * 1.5 })
    end
end

local function emit_shadow(kind)
    local R = burst_radius(kind)
    if not fx_on('dx11_particles') and not fx_on('dx11_glow') then return end
    local hole = pf(kind, 0, 0, 0, 0, 880, 1, 1, 1, 0.94, R * 0.36, R * 0.36, 'void')
    hole.blend = 'alpha'
    hole.grow0, hole.grow1 = 0.45, 1.15
    hole.fade_late = 260
    local rim = pf(kind, 0, 0, 0, 0, 820, 0.70, 0.22, 1.15, 0.55, R * 0.42, R * 0.42, 'halo')
    rim.grow0, rim.grow1 = 0.55, 1.12
    rim.fade_late = 240
    local n = lite() and 7 or 12
    for i = 1, n do
        local a = (i / n) * 6.28318
        local x, y = math.cos(a) * R * 0.62, math.sin(a) * R * 0.48
        local p = pf(kind, x, y, -x * 1.55, -y * 1.55, 720 + math.random() * 120,
            0.55, 0.16, 0.95, 0.88, 1, 1, 'tendril')
        p.blend = 'alpha'
        p.orient, p.streak, p.thick = true, R * 0.38, R * 0.070
        p.drag = 0.40
        p.fade_late = 200
    end
    local nm = lite() and 10 or 18
    for i = 1, nm do
        local a = math.random() * 6.28318
        local r0 = R * (0.45 + math.random() * 0.40)
        local x, y = math.cos(a) * r0, math.sin(a) * r0 * 0.75
        local p = pf(kind, x, y, -x * 2.4, -y * 2.4, 580 + math.random() * 160,
            0.55, 0.18, 0.85, 0.80, 3.2, 3.2, 'ember')
        p.palette, p.drag = 'shadow', 0.35
    end
end

local function emit_holy(kind)
    local R = burst_radius(kind)
    if not fx_on('dx11_particles') and not fx_on('dx11_glow') then return end
    local nr = lite() and 8 or 12
    for i = 1, nr do
        local a = (i / nr) * 6.28318 + (math.random() - 0.5) * 0.06
        local p = pf(kind, math.cos(a) * 10, math.sin(a) * 10, 0, 0, 920,
            1.35, 1.18, 0.62, 0.78, 1, 1, 'ray')
        p.orient, p.fixed_ang = true, a
        p.streak, p.thick = R * 0.95, R * 0.048
        p.flicker = math.random() * 6.28318
    end
    local h = pf(kind, 0, 0, 0, 0, 1000, 1.25, 1.08, 0.50, 0.55, R * 0.46, R * 0.46, 'halo')
    h.grow0, h.grow1 = 0.78, 1.06
    local nm = lite() and 10 or 16
    for i = 1, nm do
        local p = pf(kind, (math.random() - 0.5) * R * 0.25, (math.random() - 0.5) * R * 0.15,
            (math.random() - 0.5) * 18, -30 - math.random() * 50, 800 + math.random() * 260,
            1.3, 1.15, 0.6, 0.80, 3.4, 3.4, 'ember')
        p.palette, p.grav, p.drag = 'holy', 12, 0.55
        p.flicker = math.random() * 6.28318
    end
end

local RT_STYLE = {
    Fire = 'inferno', Cold = 'frost', Poison = 'toxic', Disease = 'disease',
    Magic = 'arcane', Corruption = 'shadow', Chromatic = 'storm', Prismatic = 'storm',
    Unresistable = 'holy',
}

local STYLE_PAL = {
    inferno = 'fire', frost = 'cold', toxic = 'poison', disease = 'disease',
    arcane = 'magic', storm = 'storm', shadow = 'shadow', holy = 'holy', blood = 'blood',
    wind = 'magic', water = 'cold', earth = 'fire',
}

local function style_pal(style, rt)
    if not style or style == 'auto' then
        if rt == 'Fire' then return 'fire'
        elseif rt == 'Cold' then return 'cold'
        elseif rt == 'Poison' then return 'poison'
        elseif rt == 'Disease' then return 'disease'
        elseif rt == 'Corruption' then return 'shadow'
        elseif rt == 'Chromatic' or rt == 'Prismatic' then return 'storm'
        elseif rt == 'Unresistable' then return 'holy'
        else return 'magic' end
    end
    return STYLE_PAL[style] or 'magic'
end

local function chosen_style(kind)
    local fs = style_cfg()
    if kind == 'crit' and (fs.scope or 'procs') == 'both' then return fs.proc or 'auto' end
    if kind == 'crit' then return fs.crit or 'auto' end
    return fs.proc or 'auto'
end

local function begin_tint()
    local r, g, b = custom_rgb()
    if r then TINT = { r, g, b } else TINT = nil end
end

local function emit_named(name, kind)
    if name == 'inferno' or name == 'fire' then emit_fire(kind)
    elseif name == 'frost' then emit_frost(kind)
    elseif name == 'toxic' or name == 'poison' then emit_poison(kind)
    elseif name == 'disease' then emit_disease(kind)
    elseif name == 'arcane' then emit_arcane(kind)
    elseif name == 'storm' or name == 'lightning' then emit_lightning(kind)
    elseif name == 'shadow' then emit_shadow(kind)
    elseif name == 'holy' then emit_holy(kind)
    elseif name == 'blood' then emit_blood(kind)
    elseif name == 'wind' then emit_wind(kind)
    elseif name == 'water' then emit_water(kind)
    elseif name == 'earth' then emit_earth(kind)
    else emit_arcane(kind) end
end

local function emit_style(kind, style, rt)
    if not parts_on() then emitter = nil; return end     -- 'Particle effects' off: no element burst at all
    begin_tint()
    CUR_STYLE = style or 'auto'
    local name
    if not style or style == 'auto' then
        if kind == 'crit' then
            name = 'critgold'
            emit_gold_crit(kind)
        else
            name = RT_STYLE[norm_rt(rt)] or 'arcane'
            emit_named(name, kind)
        end
    else
        name = style
        emit_named(style, kind)
    end
    weave_body_motion()
    start_emitter(kind, name)
    TINT = nil
    RING_CAP = nil
end

local function do_shatter(kind, typ, x, y)
    if not kind or not fx_on('dx11_particles') then return end
    local R = (CUR_R > 1) and CUR_R or 160
    if typ == 'pop' then
        for i = 1, 4 do
            local a = math.random() * 6.28318
            local p = spawn(x, y, math.cos(a) * 90, math.sin(a) * 90, 240, 1, 1, 1, 0.75, 3.2, 3.2)
            p.kind, p.tex, p.follow, p.blend = kind, 'drip', true, 'alpha'
            p.grav, p.drag = 140, 0.8
        end
    else
        for i = 1, 4 do
            local a = math.random() * 6.28318
            local spd = R * (0.35 + math.random() * 0.45)
            local p = spawn(x, y, math.cos(a) * spd, math.sin(a) * spd, 280, 1.2, 1.4, 1.6, 0.9, 2.4, 2.4)
            p.kind, p.tex, p.follow = kind, 'snow', true
            p.drag, p.flicker = 1.4, math.random() * 6.28318
        end
    end
end

function M.glow_at(x, y, r, g, b, size, life, kind)
    if not ensure() or not fx_on('dx11_glow') then return end
    size = size or 28
    life = life or 420
    if use_ex() then
        local rad = math.min(11, math.max(5.5, size * 0.22))
        local p = spawn(x, y, 0, -6, math.min(life, 240), r * 1.35, g * 1.15, b * 0.90, 0.88, rad, rad)
        p.kind = kind
        p.tex = 'core'
        p.core = true
        p.palette = 'fire'
        p.fade_to = { r * 0.80, g * 0.32, b * 0.08 }
        return
    end
    local p = spawn(x, y, 0, -6, life, r * 1.55, g * 1.35, b * 1.15, 0.92, size * 0.42, size * 0.42)
    p.kind = kind
    p.fade_to = { r * 0.85, g * 0.40, b * 0.12 }
    p = spawn(x, y, 0, -3, life * 0.55, r * 1.15, g, b, 0.55, size * 0.70, size * 0.70)
    p.kind = kind
    p.fade_to = { r * 0.70, g * 0.30, b * 0.08 }
end

function M.crit(x, y)
    if not ensure() then return end
    update_anchor()
    clear_combat_fx()
    M.last_draw = use_ex() and 'sprite_ex' or 'fallback'
    emit_style('crit', chosen_style('crit'), 'Magic')
    if not use_ex() and parts_on() then
        emit_burst(AX, AY, lite() and 18 or 36, 280, 560, 1.0, 0.78, 0.22, 6.5, true, 'crit')
    end
end

function M.kill(x, y)
    if not ensure() then return end
    x = x or W * 0.50; y = y or H * 0.25
    clear_kind('kill')
    if use_ex() then
        if fx_on('dx11_glow') then
            local p = spawn(x, y, 0, -4, 180, 2.20, 1.90, 1.15, 1.0, 8.2, 8.2)
            p.kind = 'kill'
            p.tex = 'core'
            p.core = true
            p.palette = 'fire'
            p = spawn(x, y, 0, 0, 240, 1.25, 1.08, 0.70, 0.75, 88, 5.2)
            p.kind = 'kill'
            p.tex = 'flare'
            p.palette = 'fire'
            p.a = 0.70
        end
        if fx_on('dx11_particles') then
            emit_tex_burst(x, y, lite() and 8 or 13, 310, 540, 'kill', 'fire', 'streak', {
                grav = 30, drag = 1.6, len = 70, thick = 20, off = 20,
            })
        end
        if fx_on('dx11_shockwave') then M.shockwave(x, y, 1.0, 0.88, 0.40) end
        return
    end
    if fx_on('dx11_glow') then
        M.glow_at(x, y, 1.0, 0.92, 0.55, 28, 640, 'kill')
        local p = spawn(x, y, 0, 0, 240, 1, 1, 0.85, 0.95, 12, 12)
        p.kind = 'kill'
    end
    if fx_on('dx11_particles') then
        emit_burst(x, y, lite() and 14 or 28, 280, 620, 1.0, 0.95, 0.70, 6.5, false, 'kill')
        emit_burst(x, y, lite() and 6 or 12, 140, 400, 1.0, 1.0, 0.85, 10, false, 'kill')
    end
    if fx_on('dx11_shockwave') then M.shockwave(x, y, 1.0, 0.88, 0.40) end
end

function M.heal()
    if not ensure() or not fx_on('dx11_particles') then return end
    local t = now()
    if M._heal_t and t - M._heal_t < 450 then return end
    M._heal_t = t
    clear_kind('heal')
    -- lower on the player so incoming heals do not paint a green fog over the target
    local cx, cy = W * 0.50, H * 0.80
    local n = lite() and 4 or 8
    for i = 1, n do
        local x = cx + (math.random() - 0.5) * 90
        local y = cy + (math.random() - 0.5) * 24
        local p = spawn(x, y, (math.random() - 0.5) * 18, -70 - math.random() * 50, 480 + math.random() * 140,
            0.42, 1.0, 0.54, 0.85, 3.0 + math.random() * 1.6, 3.0 + math.random() * 1.6)
        p.kind = 'heal'
    end
    if fx_on('dx11_glow') then
        local p = spawn(cx, cy - 12, 0, -8, 320, 0.42, 1.0, 0.54, 0.75, 9, 9)
        p.kind = 'heal'
    end
end

-- Contained elemental burst: ~60-70% of a crit's punch, one color, no fog.
function M.proc(rt)
    if not ensure() or not parts_on() then return end
    rt = norm_rt(rt)
    update_anchor()
    clear_combat_fx()
    local style = chosen_style('proc')
    M.last_draw = use_ex() and 'sprite_ex' or 'fallback'
    emit_style('proc', style, rt)
    if not use_ex() then
        local pal = style_pal(style, rt)
        local col = RT[rt] or RT.Magic
        if pal == 'fire' or pal == 'blood' then col = RT.Fire
        elseif pal == 'cold' or pal == 'storm' then col = RT.Cold
        elseif pal == 'poison' then col = RT.Poison
        elseif pal == 'disease' then col = { 0.72, 0.58, 0.18 }
        elseif pal == 'holy' then col = { 1.2, 1.05, 0.45 }
        elseif pal == 'shadow' then col = { 0.55, 0.22, 0.85 }
        end
        emit_burst(AX, AY, lite() and 16 or 28, 280, 500, col[1], col[2], col[3], 5.8, true, 'proc')
        if fx_on('dx11_shockwave') then
            add_ring(AX, AY, 16, math.max(40, (CUR_R > 1 and CUR_R or burst_radius('proc')) * 1.20), 700, col[1], col[2], col[3], 'proc')
            rings[nrings].follow = true
        end
    end
end

function M.spell(rt)
    return M.proc(rt)
end

function M.preview(style, kind)
    if not ensure() then return end
    update_anchor()
    kind = (kind == 'crit') and 'crit' or 'proc'
    clear_combat_fx()
    M.last_draw = use_ex() and 'sprite_ex' or 'fallback'
    emit_style(kind, style or 'auto', 'Magic')
end

function M.shockwave(x, y, r, g, b)
    if not ensure() or not fx_on('dx11_shockwave') then return end
    add_ring(x or W * TX, y or H * TY, 18, 280, 640, r or 1, g or 0.82, b or 0.3, 'crit')
end

function M.flare(x, y)
    if not ensure() then return end
    x = x or W * 0.50; y = y or H * 0.18
    clear_kind('flare')
    if use_ex() then
        if fx_on('dx11_glow') then
            local p = spawn(x, y, 0, -3, 180, 2.15, 1.80, 1.05, 0.95, 7.5, 7.5)
            p.kind = 'flare'
            p.tex = 'core'
            p.core = true
            p.palette = 'fire'
            p = spawn(x, y, 0, 0, 280, 1.20, 0.95, 0.55, 0.72, 110, 4.8)
            p.kind = 'flare'
            p.tex = 'flare'
            p.palette = 'fire'
        end
        if fx_on('dx11_particles') then
            emit_tex_burst(x, y, lite() and 6 or 9, 230, 560, 'flare', 'fire', 'streak', {
                rise = true, grav = 36, drag = 1.5, len = 60, thick = 18, off = 18,
            })
        end
        return
    end
    if fx_on('dx11_glow') then M.glow_at(x, y, 1.0, 0.84, 0.25, 24, 700, 'flare') end
    if fx_on('dx11_particles') then emit_burst(x, y, lite() and 12 or 24, 200, 750, 1.0, 0.82, 0.22, 5.2, true, 'flare') end
end

function M.death()
    if not ensure() or not fx_on('dx11_glow') then return end
    death_t = now() + 4500
    local cx, cy = W * 0.5, H * 0.5
    M.glow_at(cx, cy, 0.55, 0.02, 0.06, 70, 1600, 'death')
    if fx_on('dx11_particles') then
        emit_burst(cx, cy, lite() and 10 or 20, 110, 1400, 0.7, 0.08, 0.1, 7, false, 'death')
    end
end

function M.set_heartbeat(on)
    heartbeat = on and true or false
end

function M.clear()
    emitter = nil
    pcall(BF.gpu_off)
    nparts, nrings, heartbeat, death_t, was_draw = 0, 0, false, 0, false
    if reset_ground then reset_ground() end
    if M._ready and M._api then
        pcall(function() M._api.rml_canvas_clear(WIN, ID) end)
        pcall(function() M._api.rml_canvas_trail(WIN, ID, 0) end)
        pcall(function() M._api.rml_canvas_bloom(WIN, ID, 0) end)
    end
end

local function push_sprite(n, x, y, rx, ry, r, g, b, a)
    if n >= sprcap then return n end
    local o = n * 8
    sprbuf[o + 0] = x; sprbuf[o + 1] = y
    sprbuf[o + 2] = rx; sprbuf[o + 3] = ry
    sprbuf[o + 4] = r; sprbuf[o + 5] = g; sprbuf[o + 6] = b; sprbuf[o + 7] = a
    return n + 1
end

local function resolve_size()
    if not M._api.rml_canvas_size then return end
    if not M._ow then M._ow = ffi.new('float[1]'); M._oh = ffi.new('float[1]') end
    if pcall(function() return M._api.rml_canvas_size(WIN, ID, M._ow, M._oh) end) then
        if M._ow[0] and M._oh[0] and M._ow[0] >= 8 and M._oh[0] >= 8 then W, H = M._ow[0], M._oh[0] end
    end
end

function M.frame(sw, sh)
    if not ensure() or not fx_on(nil) then
        if was_draw then M.clear() end
        return
    end
    if HAS_EX then load_textures(); load_marker_custom() end
    if sw and sw >= 8 then W = sw end
    if sh and sh >= 8 then H = sh end
    resolve_size()
    local t = now()
    if t0 == 0 then t0 = t end
    local dt = math.min(0.05, math.max(0.008, (t - (M._pt or t)) / 1000))
    M._pt = t
    update_anchor()
    tick_emitter(dt)

    local w = 1
    while w <= nparts do
        local p = parts[w]
        if not p then
            nparts = w - 1
            break
        end
        if p.delay and p.delay > 0 then
            p.delay = p.delay - dt * 1000
            w = w + 1
        else
        p.life = p.life - dt * 1000
        if p.spin_r and p.spin_r ~= 0 then
            p.rot = (p.rot or 0) + p.spin_r * dt
        end
        if p.orbit then
            if p.orb_y0 ~= nil then
                local u = 1 - math.max(0, math.min(1, p.life / math.max(1, p.max)))
                p.orb_a0 = (p.orb_a0 or 0) + (p.orb_spin or 0) * dt
                local r = (p.orb_r0 or 8) + ((p.orb_r1 or p.orb_r0 or 8) - (p.orb_r0 or 8)) * u
                p.orb_y0 = (p.orb_y0 or 0) + (p.orb_rise or 0) * dt
                local lim = body_span() * 0.52
                if p.orb_y0 < -lim then p.orb_y0 = -lim end
                if p.orb_y0 > lim then p.orb_y0 = lim end
                p.x = math.cos(p.orb_a0) * r
                p.y = p.orb_y0
                local z = math.sin(p.orb_a0) * r
                p.depth = z / math.max(10, r)
                p.vx = -math.sin(p.orb_a0) * math.max(40, math.abs((p.orb_spin or 1) * r))
                p.vy = p.orb_rise or -40
            else
                local u = 1 - math.max(0, math.min(1, p.life / math.max(1, p.max)))
                local grow = math.min(1, u / 0.26)
                local ee = 1 - (1 - grow) * (1 - grow)
                local r = (p.orb_r0 or 8) + ((p.orb_r1 or 80) - (p.orb_r0 or 8)) * ee
                local ang = (p.orb_a0 or 0) + (p.orb_spin or 0) * u
                local sq = p.orb_squash or 0.72
                p.x = math.cos(ang) * r
                p.y = math.sin(ang) * r * sq
                p.vx = -math.sin(ang) * math.max(40, r)
                p.vy =  math.cos(ang) * math.max(40, r) * sq
                p.fixed_ang = math.atan2(p.vy, p.vx)
                p.depth = math.sin(ang)
            end
        elseif p.spin and p.spin ~= 0 then
            local ang = p.spin * dt
            local c, s = math.cos(ang), math.sin(ang)
            local vx, vy = p.vx * c - p.vy * s, p.vx * s + p.vy * c
            p.vx, p.vy = vx, vy
        end
        if not p.orbit then
            if p.drag and p.drag > 0 then
                local d = math.max(0, 1 - p.drag * dt)
                p.vx, p.vy = p.vx * d, p.vy * d
            end
            if p.grav and p.grav ~= 0 then
                p.vy = p.vy + p.grav * dt
            end
            if p.drip then
                p.vy = p.vy + 220 * dt
            end
            if p.turb and p.turb > 0 then
                p.vx = p.vx + (math.random() - 0.5) * 2 * p.turb * dt
                p.vy = p.vy + (math.random() - 0.5) * 2 * p.turb * dt
            end
            p.x = p.x + p.vx * dt
            p.y = p.y + p.vy * dt
            if p.bounce and p.ground and p.y > p.ground and (p.vy or 0) > 0 then
                p.y = p.ground
                p.vy = -p.vy * p.bounce
                p.vx = (p.vx or 0) * 0.72
                p.spin_r = (p.spin_r or 0) * 0.7
            end
        end
        if p.follow and p.max_r and p.max_r > 0 then
            local dist = math.sqrt((p.x or 0) * (p.x or 0) + (p.y or 0) * (p.y or 0))
            if dist > p.max_r and dist > 0.001 then
                local s = p.max_r / dist
                p.x, p.y = p.x * s, p.y * s
            end
        end
        if p.life <= 0 then
            local sh, typ, sx, sy, sk = p.shatter, p.shatter, p.x, p.y, p.kind
            parts[w], parts[nparts] = parts[nparts], parts[w]
            nparts = nparts - 1
            if sh then do_shatter(sk, typ, sx, sy) end
        else
            w = w + 1
        end
        end
    end
    w = 1
    while w <= nrings do
        rings[w].life = rings[w].life - dt * 1000
        if rings[w].life <= 0 then
            rings[w], rings[nrings] = rings[nrings], rings[w]
            nrings = nrings - 1
        else
            w = w + 1
        end
    end
    if death_t > 0 and t > death_t then death_t = 0 end
    update_ground(dt)
    update_markers()
    BF.update()
    BF.gpu_tick()

    local hb = heartbeat and fx_on('dx11_heartbeat')
    local active = nparts > 0 or nrings > 0 or hb or death_t > t or ground_wants_draw() or marker_wants_draw() or BF.wants_draw()
    if not active then
        if was_draw then
            pcall(function() M._api.rml_canvas_clear(WIN, ID) end)
            pcall(function() M._api.rml_canvas_trail(WIN, ID, 0) end)
            pcall(function() M._api.rml_canvas_bloom(WIN, ID, 0) end)
            was_draw = false
        end
        return
    end

    pcall(function() M._api.rml_canvas_clear(WIN, ID) end)
    local has_crit, has_proc, has_heal, has_heavy = false, false, false, false
    for i = 1, nparts do
        local k = parts[i].kind
        if k == 'proc' or k == 'proc_core' or k == 'proc_ember' then has_proc = true
        elseif k == 'heal' then has_heal = true
        elseif k == 'crit' or k == 'crit_ember' or k == 'kill' or k == 'flare' then has_crit = true
        else has_heavy = true end
    end
    for i = 1, nrings do
        local k = rings[i].kind
        if k == 'proc' then has_proc = true
        elseif k == 'crit' or k == nil then has_crit = true
        end
    end
    -- trails smear sparks into a cartoon blob; keep them off for streak effects
    local trail = 0
    if fx_on('dx11_trails') and has_heavy and not has_proc and not has_crit then
        trail = 0.25
    end
    pcall(function() M._api.rml_canvas_trail(WIN, ID, trail) end)
    local bloom = 0
    if fx_on('dx11_glow') then
        if death_t > t then bloom = use_ex() and 0.48 or 1.05
        elseif hb then bloom = use_ex() and 0.40 or 0.70
        elseif has_crit or has_heavy then bloom = use_ex() and 0.56 or 0.70
        elseif has_heal then bloom = use_ex() and 0.12 or 0.16
        elseif has_proc then bloom = use_ex() and 0.50 or 0.42
        elseif ground_wants_draw() then
            local _, ast = aura_wanted()
            bloom = use_ex() and (is_showpiece(ast) and 0.34 or 0.22) or 0.18
        elseif BF.wants_draw() then
            bloom = use_ex() and 0.30 or 0.22
        elseif marker_wants_draw() then
            bloom = use_ex() and 0.20 or 0.16
        end
    end
    -- GPU body FX: bloom stays on only when the DLL masks it with the body capsule (features & 1024)
    if BF.gpu.on and not BF.gpu.masked then bloom = 0 end
    BF.gpu.bloom = bloom
    pcall(function() M._api.rml_canvas_bloom(WIN, ID, bloom) end)

    local fadeI = intensity()
    local MODE_FX = ADD + GLOW
    local function tex_id(name)
        return TEX[name] or TEX.streak or 0
    end
    local function push_ex(n, x, y, sx, sy, ang, r, g, b, a, tid, mode)
        if not sprExBuf or n >= sprExCap then return n end
        local o = n * 11
        sprExBuf[o + 0] = x; sprExBuf[o + 1] = y
        sprExBuf[o + 2] = sx; sprExBuf[o + 3] = sy
        sprExBuf[o + 4] = ang
        sprExBuf[o + 5] = r; sprExBuf[o + 6] = g; sprExBuf[o + 7] = b; sprExBuf[o + 8] = a
        sprExBuf[o + 9] = tid; sprExBuf[o + 10] = mode
        return n + 1
    end
    local function world_xy(p)
        if p.follow then return AX + (p.x or 0), AY + (p.y or 0) end
        return p.x, p.y
    end
    local function push_ex_part(ns, p)
        if p.delay and p.delay > 0 then return ns end
        if p.blink_on and p.blink_on > 0 then
            local elapsed = (p.max - p.life)
            local cyc = p.blink_on + (p.blink_off or 80)
            if cyc > 1 then
                local m = (elapsed + (p.blink_phase or 0)) % cyc
                if m > p.blink_on then return ns end
            end
        end
        local u = p.life / math.max(1, p.max)
        local au = u
        if p.fade_late and p.fade_late > 0 then
            au = math.min(1, p.life / p.fade_late)
        end
        local a = p.a * au * fadeI
        if a <= 0.015 then return ns end
        local grow = 1
        if p.grow0 then grow = lerp(p.grow0, p.grow1 or 1, 1 - u) end
        local tname = p.tex
        if p.frames then
            local nf = #p.frames
            if nf > 0 then
                local elapsed = (p.max - p.life) / 1000
                local idx = math.floor(elapsed * (p.fps or 12)) % nf + 1
                tname = p.frames[idx]
            end
        end
        local mode = (p.blend == 'alpha') and 0 or MODE_FX
        local cr, cg, cb
        if p.palette then
            if p.core then cr, cg, cb = core_colors(p.palette, u)
            else cr, cg, cb = palette_colors(p.palette, u) end
            if p.tint then
                cr = cr * 0.38 + p.tint[1] * 0.62
                cg = cg * 0.38 + p.tint[2] * 0.62
                cb = cb * 0.38 + p.tint[3] * 0.62
            end
        elseif p.fade_to then
            cr = p.r * u + p.fade_to[1] * (1 - u)
            cg = p.g * u + p.fade_to[2] * (1 - u)
            cb = p.b * u + p.fade_to[3] * (1 - u)
        else
            cr, cg, cb = p.r, p.g, p.b
        end
        cr, cg, cb = clip_tone(p, cr, cg, cb)
        local flick = 1
        if p.flicker then
            flick = 0.84 + 0.16 * (0.5 + 0.5 * math.sin(t * 0.045 + p.flicker))
        end
        a = a * flick
        local dscale, dalpha = depth_fac(p)
        a = a * dalpha
        local px, py = world_xy(p)
        if p.tex == 'flare' and not p.orient and not p.streak then
            local scale = 0.72 + 0.28 * u
            return push_ex(ns, px, py, p.rx * scale * grow * dscale, p.ry * scale * grow * dscale, p.rot or 0, cr, cg, cb, a * 0.85, tex_id('flare'), mode)
        end
        if p.orient or (p.streak and p.streak > 0) then
            local spd = math.sqrt(p.vx * p.vx + p.vy * p.vy)
            local ang = p.fixed_ang or 0
            if not p.fixed_ang and spd > 0.5 then ang = math.atan2(p.vy, p.vx) end
            local len
            if p.orbit or p.fixed_ang then
                len = (p.streak or (p.rx * 2)) * (0.88 + 0.12 * u)
            else
                len = (p.streak or (p.rx * 2)) * (0.52 + 0.48 * math.min(1, spd / 250)) * (0.72 + 0.28 * u)
            end
            local thick = (p.thick or (p.ry * 2)) * (0.80 + 0.22 * u)
            local sx, sy = len * 0.5 * dscale, thick * 0.5 * dscale
            local ux, uy = math.cos(ang), math.sin(ang)
            return push_ex(ns, px - ux * sx * 0.72, py - uy * sx * 0.72, sx * grow, sy * grow, ang, cr, cg, cb, a, tex_id(tname or 'streak'), mode)
        end
        local scale = 0.78 + 0.32 * u
        if p.core then scale = 0.52 + 0.55 * math.min(1, u * 1.35) end
        return push_ex(ns, px, py, (p.rx or 6) * scale * grow * dscale, (p.ry or 6) * scale * grow * dscale, p.rot or 0, cr, cg, cb, a, tex_id(tname or 'core'), mode)
    end
    if use_ex() then
        local ns = 0
        local gitems = collect_ground_sprites()
        for i = 1, #gitems do
            local it = gitems[i]
            local mode = (it.blend == 'alpha') and 0 or MODE_FX
            ns = push_ex(ns, it.x, it.y, it.sx, it.sy, it.ang or 0, it.r, it.g, it.b, it.a, tex_id(it.tex), mode)
        end
        local bitems = BF.collect()
        for i = 1, #bitems do
            local it = bitems[i]
            local mode = (it.blend == 'alpha') and 0 or MODE_FX
            ns = push_ex(ns, it.x, it.y, it.sx, it.sy, it.ang or 0, it.r, it.g, it.b, it.a, tex_id(it.tex), mode)
        end
        local mitems = collect_marker_sprites()
        for i = 1, #mitems do
            local it = mitems[i]
            local mode = (it.blend == 'alpha') and 0 or MODE_FX
            ns = push_ex(ns, it.x, it.y, it.sx, it.sy, it.ang or 0, it.r, it.g, it.b, it.a, tex_id(it.tex), mode)
        end
        local order = {}
        for i = 1, nparts do order[i] = i end
        table.sort(order, function(a, b)
            return (parts[a].depth or 0) < (parts[b].depth or 0)
        end)
        for oi = 1, #order do
            ns = push_ex_part(ns, parts[order[oi]])
        end
        if nrings > 0 then
            for i = 1, nrings do
                local R = rings[i]
                local u = 1 - R.life / R.max
                if R.ease == 'out' then u = 1 - (1 - u) * (1 - u) end
                local rad = R.r0 + (R.r1 - R.r0) * u
                local a = (1 - u * 0.72) * 0.90 * fadeI
                local rx, ry = rad * (R.sx or 1), rad * (R.sy or 1)
                local ang = (R.spin or 0) * u * 3.2
                local px, py = R.x, R.y
                if R.follow then px, py = AX + R.x, AY + R.y end
                local tid = 0
                if R.tex and TEX[R.tex] and TEX[R.tex] > 0 then tid = TEX[R.tex]
                elseif TEX.shell and TEX.shell > 0 then tid = TEX.shell
                elseif TEX.ring and TEX.ring > 0 then tid = TEX.ring end
                if tid > 0 then
                    ns = push_ex(ns, px, py, rx, ry, ang, R.r, R.g, R.b, a, tid, MODE_FX)
                end
            end
        end
        if ns > 0 then
            pcall(function() M._api.rml_canvas_sprites_ex(WIN, ID, sprExBuf, ns) end)
        end
        local extra = 0
        if death_t > t then
            local u = math.max(0, math.min(1, (death_t - t) / 4500))
            extra = push_sprite(extra, W * 0.5, H * 0.5, W * 0.46, H * 0.46, 0.62, 0.04, 0.08, 0.38 * u * fadeI)
        end
        if hb then
            local pulse = 0.22 + 0.38 * (0.5 + 0.5 * math.sin(t / 175.0))
            pulse = pulse * fadeI
            local th = math.max(48, H * 0.085)
            local tw = math.max(48, W * 0.055)
            extra = push_sprite(extra, W * 0.5, th * 0.45, W * 0.55, th, 0.55, 0.02, 0.05, pulse)
            extra = push_sprite(extra, W * 0.5, H - th * 0.45, W * 0.55, th, 0.55, 0.02, 0.05, pulse)
            extra = push_sprite(extra, tw * 0.45, H * 0.5, tw, H * 0.55, 0.55, 0.02, 0.05, pulse)
            extra = push_sprite(extra, W - tw * 0.45, H * 0.5, tw, H * 0.55, 0.55, 0.02, 0.05, pulse)
        end
        if extra > 0 then
            pcall(function() M._api.rml_canvas_sprites(WIN, ID, sprbuf, extra, SPRITE_FX) end)
        end
        was_draw = true
        if last_stat == 0 or t - last_stat >= 5000 then
            last_stat = t
            pcall(function()
                if not statbuf then statbuf = ffi.new('char[?]', 1024) end
                M._api.rml_canvas_stats(WIN, ID, statbuf, 1024)
            end)
        end
        return
    end
    local function push_part(ns, p)
        local u = p.life / p.max
        local dscale, dalpha = depth_fac(p)
        local a = p.a * u * fadeI * dalpha
        if a <= 0.02 then return ns end
        local cr, cg, cb = p.r, p.g, p.b
        if p.fade_to then
            cr = p.r * u + p.fade_to[1] * (1 - u)
            cg = p.g * u + p.fade_to[2] * (1 - u)
            cb = p.b * u + p.fade_to[3] * (1 - u)
        end
        if p.streak and p.streak > 0 then
            local spd = math.sqrt(p.vx * p.vx + p.vy * p.vy)
            local ux, uy = 0, 0
            if spd > 1 then ux, uy = p.vx / spd, p.vy / spd end
            -- length scales with current speed so slowing sparks shorten
            local len = p.streak * (0.55 + 0.45 * math.min(1, spd / 240)) * (0.70 + 0.30 * u)
            local thick = (p.thick or 2.0) * (0.80 + 0.25 * u)
            local flick = 1
            if p.flicker then
                flick = 0.80 + 0.20 * (0.5 + 0.5 * math.sin(t * 0.042 + p.flicker))
            end
            -- 3 tightly overlapped samples approximate a rotated streak
            -- with axis-aligned sprites (the API has no angle)
            local px, py = p.x, p.y
            if p.follow then px, py = AX + p.x, AY + p.y end
            for sidx = 0, 2 do
                local f = sidx / 2
                local sx = px - ux * len * f * 0.50
                local sy = py - uy * len * f * 0.50
                local frx = thick * 0.38 + math.abs(ux) * len * 0.42
                local fry = thick * 0.38 + math.abs(uy) * len * 0.42
                ns = push_sprite(ns, sx, sy, frx, fry, cr, cg, cb, a * flick * (1 - 0.16 * f))
            end
            if p.tip or p.hdr then
                local hr = p.hdr and (cr * 1.55) or 1.6
                local hg = p.hdr and (cg * 1.35) or 1.45
                local hb = p.hdr and (cb * 1.15) or 1.05
                local tip = thick * 0.90
                ns = push_sprite(ns, px, py, tip, tip, hr, hg, hb, math.min(1.35, a * 1.15) * flick)
            end
            return ns
        end
        local qx, qy = p.x, p.y
        if p.follow then qx, qy = AX + p.x, AY + p.y end
        return push_sprite(ns, qx, qy, p.rx * (0.7 + 0.5 * u) * dscale, p.ry * (0.7 + 0.5 * u) * dscale, cr, cg, cb, a)
    end
    local ns = 0
    for i = 1, nparts do
        if parts[i].kind == 'proc' then
            ns = push_part(ns, parts[i])
        end
    end
    -- sparks: additive only so they stay sharp streaks
    if ns > 0 then
        pcall(function() M._api.rml_canvas_sprites(WIN, ID, sprbuf, ns, SPRITE_FX) end)
    end
    ns = 0
    for i = 1, nparts do
        if parts[i].kind ~= 'proc' then
            ns = push_part(ns, parts[i])
        end
    end
    if death_t > t then
        local u = math.max(0, math.min(1, (death_t - t) / 4500))
        ns = push_sprite(ns, W * 0.5, H * 0.5, W * 0.46, H * 0.46, 0.62, 0.04, 0.08, 0.38 * u * fadeI)
    end
    if hb then
        local pulse = 0.22 + 0.38 * (0.5 + 0.5 * math.sin(t / 175.0))
        pulse = pulse * fadeI
        local th = math.max(48, H * 0.085)
        local tw = math.max(48, W * 0.055)
        ns = push_sprite(ns, W * 0.5, th * 0.45, W * 0.55, th, 0.55, 0.02, 0.05, pulse)
        ns = push_sprite(ns, W * 0.5, H - th * 0.45, W * 0.55, th, 0.55, 0.02, 0.05, pulse)
        ns = push_sprite(ns, tw * 0.45, H * 0.5, tw, H * 0.55, 0.55, 0.02, 0.05, pulse)
        ns = push_sprite(ns, W - tw * 0.45, H * 0.5, tw, H * 0.55, 0.55, 0.02, 0.05, pulse)
    end
    if ns > 0 then
        pcall(function() M._api.rml_canvas_sprites(WIN, ID, sprbuf, ns, SPRITE_FX) end)
    end
    if nrings > 0 and M._api.rml_canvas_circle then
        for i = 1, nrings do
            local R = rings[i]
            local u = 1 - R.life / R.max
            if R.ease == 'out' then u = 1 - (1 - u) * (1 - u) end
            local rad = R.r0 + (R.r1 - R.r0) * u
            local a = (1 - u) * 0.85 * fadeI
            local lw = R.width or ((R.kind == 'proc') and 3.8 or 5.0)
            local px, py = R.x, R.y
            if R.follow then px, py = AX + R.x, AY + R.y end
            pcall(function()
                M._api.rml_canvas_line_width(WIN, ID, lw)
                M._api.rml_canvas_circle(WIN, ID, px, py, rad, R.r, R.g, R.b, a, 40, GLOW + ADD)
            end)
        end
    end
    was_draw = true

    if last_stat == 0 or t - last_stat >= 5000 then
        last_stat = t
        pcall(function()
            if not statbuf then statbuf = ffi.new('char[?]', 1024) end
            M._api.rml_canvas_stats(WIN, ID, statbuf, 1024)
        end)
    end
end

function M.active()
    return nparts > 0 or nrings > 0 or heartbeat or death_t > now()
end

function M.last_counts()
    return nparts, nrings
end

function M.debug_fx_census()
    local kinds, styles, rkinds, rstyles = {}, {}, {}, {}
    local combat_n, combat_r = 0, 0
    for i = 1, nparts do
        local p = parts[i]
        if p then
            local k = p.kind or '?'
            kinds[k] = (kinds[k] or 0) + 1
            if COMBAT_FX_KIND[k] then
                combat_n = combat_n + 1
                local st = p.style or '?'
                styles[st] = (styles[st] or 0) + 1
            end
        end
    end
    for i = 1, nrings do
        local r = rings[i]
        if r then
            local k = r.kind or '?'
            rkinds[k] = (rkinds[k] or 0) + 1
            if COMBAT_FX_KIND[k] then
                combat_r = combat_r + 1
                local st = r.style or '?'
                rstyles[st] = (rstyles[st] or 0) + 1
            end
        end
    end
    return {
        nparts = nparts, nrings = nrings,
        combat_parts = combat_n, combat_rings = combat_r,
        kinds = kinds, styles = styles,
        ring_kinds = rkinds, ring_styles = rstyles,
        ax = AX, ay = AY, asrc = ANCHOR_SRC, aok = ANCHOR_OK,
    }
end

function M.debug_emitter()
    if not emitter then return nil end
    return { name = emitter.name, kind = emitter.kind, elapsed = emitter.elapsed, dur = emitter.dur }
end

function M.debug_particles()
    local t = {}
    for i = 1, nparts do
        local p = parts[i]
        if p then
            t[#t + 1] = {
                x = p.x, y = p.y, vx = p.vx, vy = p.vy,
                rx = p.rx, ry = p.ry, r = p.r, g = p.g, b = p.b, a = p.a,
                tex = p.tex, kind = p.kind, style = p.style, depth = p.depth or 0,
                life = p.life, max = p.max, rot = p.rot, palette = p.palette,
                core = p.core and true or nil, follow = p.follow and true or nil,
                orbit = p.orbit and true or nil, delay = p.delay,
                streak = p.streak, thick = p.thick, orient = p.orient and true or nil,
            }
        end
    end
    return t
end

function M.debug_draw_items()
    local tnow = now()
    local fadeI = intensity()
    local items = {}
    local order = {}
    for i = 1, nparts do order[i] = i end
    table.sort(order, function(a, b)
        return (parts[a].depth or 0) < (parts[b].depth or 0)
    end)
    for oi = 1, #order do
        local p = parts[order[oi]]
        if p and not (p.delay and p.delay > 0) then
            local u = p.life / math.max(1, p.max)
            local au = u
            if p.fade_late and p.fade_late > 0 then
                au = math.min(1, p.life / p.fade_late)
            end
            local a = (p.a or 1) * au * fadeI
            local dscale, dalpha = depth_fac(p)
            a = a * dalpha
            if a > 0.015 then
                local grow = 1
                if p.grow0 then grow = lerp(p.grow0, p.grow1 or 1, 1 - u) end
                local tname = p.tex
                if p.frames then
                    local nf = #p.frames
                    if nf > 0 then
                        local elapsed = (p.max - p.life) / 1000
                        local idx = math.floor(elapsed * (p.fps or 12)) % nf + 1
                        tname = p.frames[idx]
                    end
                end
                local cr, cg, cb
                if p.palette then
                    if p.core then cr, cg, cb = core_colors(p.palette, u)
                    else cr, cg, cb = palette_colors(p.palette, u) end
                    if p.tint then
                        cr = cr * 0.38 + p.tint[1] * 0.62
                        cg = cg * 0.38 + p.tint[2] * 0.62
                        cb = cb * 0.38 + p.tint[3] * 0.62
                    end
                elseif p.fade_to then
                    cr = p.r * u + p.fade_to[1] * (1 - u)
                    cg = p.g * u + p.fade_to[2] * (1 - u)
                    cb = p.b * u + p.fade_to[3] * (1 - u)
                else
                    cr, cg, cb = p.r, p.g, p.b
                end
                cr, cg, cb = clip_tone(p, cr, cg, cb)
                local flick = 1
                if p.flicker then
                    flick = 0.84 + 0.16 * (0.5 + 0.5 * math.sin(tnow * 0.045 + p.flicker))
                end
                a = a * flick
                local px, py = p.x, p.y
                if p.follow then px, py = AX + (p.x or 0), AY + (p.y or 0) end
                local sx, sy, ang = (p.rx or 6), (p.ry or 6), p.rot or 0
                if p.tex == 'flare' and not p.orient and not p.streak then
                    local scale = 0.72 + 0.28 * u
                    sx, sy = p.rx * scale * grow * dscale, p.ry * scale * grow * dscale
                    a = a * 0.85
                elseif p.orient or (p.streak and p.streak > 0) then
                    local spd = math.sqrt((p.vx or 0) * (p.vx or 0) + (p.vy or 0) * (p.vy or 0))
                    ang = p.fixed_ang or 0
                    if not p.fixed_ang and spd > 0.5 then ang = math.atan2(p.vy, p.vx) end
                    local len
                    if p.orbit or p.fixed_ang then
                        len = (p.streak or ((p.rx or 6) * 2)) * (0.88 + 0.12 * u)
                    else
                        len = (p.streak or ((p.rx or 6) * 2)) * (0.52 + 0.48 * math.min(1, spd / 250)) * (0.72 + 0.28 * u)
                    end
                    local thick = (p.thick or ((p.ry or 6) * 2)) * (0.80 + 0.22 * u)
                    sx, sy = len * 0.5 * dscale * grow, thick * 0.5 * dscale * grow
                    local ux, uy = math.cos(ang), math.sin(ang)
                    px = px - ux * sx * 0.72
                    py = py - uy * sx * 0.72
                else
                    local scale = 0.78 + 0.32 * u
                    if p.core then scale = 0.52 + 0.55 * math.min(1, u * 1.35) end
                    sx = (p.rx or 6) * scale * grow * dscale
                    sy = (p.ry or 6) * scale * grow * dscale
                end
                items[#items + 1] = {
                    x = px, y = py, sx = sx, sy = sy, ang = ang,
                    r = cr, g = cg, b = cb, a = a, tex = tname or 'core',
                    depth = p.depth or 0, blend = p.blend,
                }
            end
        end
    end
    return items, AX, AY, CUR_R, BODY_H, ANCHOR_SRC
end


ensure()
return M
