-- combatfx Body FX on MQ2RmlUi GPU particles (Stage 3 v2, API v5 rml_fx_*; feature 512, bloom mask 1024).
-- Pure descriptor builder (no requires, no ffi) so tools can run it offline; canvas.lua owns the runtime.
-- Units: body heights. canvas.lua anchors every emitter at the projected feet with px_per_unit = the
-- projected feet->crown span, so the same numbers fit a gnome or an ogre.
-- v2 look: a soft volumetric aura (backlight) on ellipsoid shells LARGER than the body, big soft dots,
-- sparkles drifting out and up at random. The body mask is ONE smooth vertical ellipse (no arm, neck or
-- leg knots) with a wide feather (a large fraction of the body width), so the light fades into the body
-- region instead of stopping at a silhouette-shaped edge. Opaque only in the core (torso/face); the
-- feather can tint the body edge at low alpha. No rays, pillars or rings; the floor pool stays a Lua sprite.
-- EQ sources (spellsnew.edd via /workspace/nimbus_research): 455 quellious01 glowbody, 454 wisps
-- (sphere surface, orbital), 462 pyrilen flame chest, 644 frost fog, 512 midnight, 446 bertox, 546 blood.
local G = { REV = 'gpu2' }

-- core mask: half-width (fraction of span) at t = 0,.2,.42,.70,.84,.94,1.08 = an ellipse
-- (rounded capsule: flat-ish base, .25 wide at the chest, tapered head) closed by the DLL's round cap; feather = FEATHER_FRAC * span px
G.KNOTS = { 0.160, 0.220, 0.250, 0.250, 0.230, 0.195, 0.080 }
G.KNOT_MUL = 1.0
G.FEATHER_FRAC = 0.26
G.FEATHER = 0.26     -- kept for logs (fraction of span)

G.STYLES = {
    inferno = {
        glow = { 1.00, 0.52, 0.14, 0.92, 0.16, 0.03 }, gop = 0.060, orb = { 14, 30 }, rise = { 0.05, 0.16 },
        spark = { 1.00, 0.82, 0.42, 1.00, 0.30, 0.04 }, sop = 0.75, srise = { 0.35, 0.80 }, sorb = { -20, 20 }, sgrav = 0,
        accent = { kind = 'flame', c = { 1.00, 0.45, 0.08, 0.85, 0.10, 0.02 }, op = 0.090 },
    },
    frost = {
        glow = { 0.55, 0.86, 1.00, 0.14, 0.52, 0.95 }, gop = 0.055, orb = { 10, 22 }, rise = { 0.01, 0.06 },
        spark = { 0.88, 0.97, 1.00, 0.40, 0.78, 1.00 }, sop = 0.55, srise = { -0.10, 0.05 }, sorb = { 30, 70 }, sgrav = 0.25,
        accent = { kind = 'mist', c = { 0.60, 0.88, 1.00, 0.20, 0.60, 0.95 }, op = 0.045 },
    },
    storm = {
        glow = { 0.50, 0.76, 1.00, 0.10, 0.40, 1.00 }, gop = 0.055, orb = { 30, 60 }, rise = { 0.02, 0.08 },
        spark = { 0.85, 0.92, 1.00, 0.35, 0.62, 1.00 }, sop = 0.70, srise = { -0.05, 0.10 }, sorb = { 160, 300 }, sgrav = 0,
        accent = { kind = 'crackle', c = { 0.80, 0.90, 1.00, 0.30, 0.55, 1.00 }, op = 0.55 },
    },
    holy = {
        glow = { 1.00, 0.88, 0.42, 0.95, 0.70, 0.22 }, gop = 0.042, orb = { 8, 18 }, rise = { 0.04, 0.12 },
        spark = { 1.00, 0.95, 0.70, 1.00, 0.82, 0.35 }, sop = 0.55, srise = { 0.15, 0.40 }, sorb = { -15, 15 }, sgrav = 0,
        accent = { kind = 'halo', c = { 1.00, 0.86, 0.45, 0.95, 0.72, 0.25 }, op = 0.050 },
    },
    void = {
        glow = { 0.46, 0.24, 1.00, 0.18, 0.08, 0.62 }, gop = 0.075, orb = { -40, -18 }, rise = { 0.00, 0.06 },
        spark = { 0.78, 0.62, 1.00, 0.42, 0.26, 1.00 }, sop = 0.70, srise = { -0.05, 0.10 }, sorb = { -120, -60 }, sgrav = 0,
        accent = { kind = 'orbit', c = { 0.55, 0.32, 1.00, 0.27, 0.20, 1.00 }, op = 0.30 },
    },
    toxic = {
        glow = { 0.52, 1.00, 0.12, 0.26, 0.78, 0.04 }, gop = 0.055, orb = { 8, 20 }, rise = { 0.03, 0.10 },
        spark = { 0.80, 1.00, 0.45, 0.50, 1.00, 0.18 }, sop = 0.55, srise = { 0.20, 0.45 }, sorb = { -10, 10 }, sgrav = 0,
        accent = { kind = 'bubble', c = { 0.70, 1.00, 0.20, 0.45, 0.95, 0.10 }, op = 0.22 },
    },
    arcane = {
        glow = { 0.92, 0.50, 0.70, 0.62, 0.38, 1.00 }, gop = 0.060, orb = { 20, 45 }, rise = { 0.02, 0.10 },
        spark = { 1.00, 0.75, 0.95, 0.72, 0.55, 1.00 }, sop = 0.65, srise = { -0.05, 0.12 }, sorb = { 90, 150 }, sgrav = 0,
        accent = { kind = 'orbit', c = { 1.00, 0.58, 0.45, 0.70, 0.50, 1.00 }, op = 0.30 },
    },
    blood = {
        glow = { 0.98, 0.14, 0.10, 0.58, 0.02, 0.02 }, gop = 0.070, orb = { 8, 18 }, rise = { -0.02, 0.05 },
        spark = { 1.00, 0.45, 0.38, 0.85, 0.08, 0.05 }, sop = 0.60, srise = { -0.10, 0.05 }, sorb = { -15, 15 }, sgrav = 0.45,
        accent = { kind = 'drip', c = { 0.95, 0.12, 0.08, 0.60, 0.02, 0.02 }, op = 0.35 },
    },
}

local function base()
    local d = {}
    for i = 0, 63 do d[i] = 0 end
    d[12] = 1; d[24], d[25], d[26], d[27] = 1, 1, 1, 1; d[28], d[29], d[30], d[31] = 1, 1, 1, 0
    d[32] = 1; d[54] = 1; d[58] = 1; d[60] = 0.35; d[62] = 1; d[57] = 1
    return d
end
local function col(d, c, a0, a1)
    d[24], d[25], d[26], d[27] = c[1], c[2], c[3], a0 or 1
    d[28], d[29], d[30], d[31] = c[4], c[5], c[6], a1 or 0
end

-- intensity: BF.intensity() (global x body, default 0.80); clamped so max settings stay below white
function G.inten_mul(fadeI)
    local f = tonumber(fadeI) or 0.8
    if f < 0.25 then f = 0.25 elseif f > 1.08 then f = 1.08 end   -- at most 1.35x the tuned default
    return f / 0.8
end

G.TUNE = { aura = 1.0, haze = 1.0, spark = 1.0, accent = 1.0 }

-- returns { {name=, d=desc[0..63]}, ... } for a style; sz = BF.size() (0.5..2), fadeI = BF.intensity()
function G.build(style, sz, fadeI)
    local S = G.STYLES[style] or G.STYLES.inferno
    local T = G.TUNE
    sz = tonumber(sz) or 1
    if sz < 0.5 then sz = 0.5 elseif sz > 2 then sz = 2 end
    local im = G.inten_mul(fadeI)
    local am = im / (sz * sz)      -- big layers: particle area grows with sz^2, keep the brightness constant
    local R = 0.46 + 0.08 * sz     -- aura shell radius (body half-width ~0.2)
    local out = {}
    -- 1) aura: two overlapping sphere shells (hips, chest/head) = a tall ellipsoid around the whole body;
    -- big soft dots drifting outward; the core mask hides the part over the torso/face
    for k, oz in ipairs({ 0.34, 0.80 }) do
        local g = base()
        g[0] = 1; g[1] = R; g[3] = 0.45; g[6] = oz
        g[9] = 700; g[12] = 2.2; g[13] = 0.30; g[59] = 11 + k
        g[15] = 0.60; g[16] = 1.10; g[17] = 0.50
        g[19] = 0.36 * sz; g[20] = 0.56 * sz; g[23] = 0.30
        col(g, S.glow, 1.0, 0.40)
        g[32] = S.gop * 0.62 * am * T.aura
        g[33], g[34] = S.rise[1] * 0.6, S.rise[2] * 0.6
        g[42], g[43] = 0.02, 0.07
        g[45], g[46] = S.orb[1] * 0.4, S.orb[2] * 0.4
        g[53] = 1; g[61] = 0.25
        out[#out + 1] = { name = 'aura' .. k, d = g }
    end
    -- 1b) haze: one very wide, faint backlight sphere so the aura has no outer edge either
    local z = base()
    z[0] = 1; z[1] = 0.70 + 0.14 * sz; z[3] = 0.85; z[6] = 0.56
    z[9] = 420; z[12] = 2.6; z[13] = 0.30; z[59] = 17
    z[15] = 0.80; z[16] = 1.30; z[17] = 0.60
    z[19] = 0.60 * sz; z[20] = 0.90 * sz; z[23] = 0.30
    col(z, S.glow, 1.0, 0.35)
    z[32] = S.gop * 0.30 * am * T.haze
    z[42], z[43] = 0.0, 0.04
    z[53] = 1; z[61] = 0.2
    out[#out + 1] = { name = 'haze', d = z }
    -- 2) sparkles: random points through the aura volume, drifting outward and upward
    local s = base()
    s[0] = 1; s[1] = 0.56 + 0.10 * sz; s[3] = 0.75; s[6] = 0.56
    s[9] = 520; s[12] = 1.5; s[13] = 0.45; s[59] = 23
    s[15] = 0.15; s[16] = 0.60
    s[19] = 0.030 * sz; s[20] = 0.010 * sz; s[23] = 0.45
    col(s, S.spark, 1.0, 0.35)
    s[32] = S.sop * im * T.spark
    s[33], s[34] = 0.08 + 0.3 * math.max(0, S.srise[1]), 0.26 + 0.3 * math.max(0, S.srise[2])
    s[42], s[43] = 0.06, 0.20
    s[45], s[46] = S.sorb[1] * 0.5, S.sorb[2] * 0.5
    s[48] = (S.sgrav or 0) * 0.3
    s[61] = 0.45
    out[#out + 1] = { name = 'spark', d = s }
    -- 3) accent per style, all spawned out on the aura volume (never hugging the outline)
    local A = S.accent
    local a = base()
    a[59] = 29
    if A.kind == 'flame' then       -- EQ 462 flame chest: soft licks rising through the aura
        a[0] = 1; a[1] = R; a[3] = 0.50; a[6] = 0.45
        a[9] = 220; a[12] = 1.0; a[13] = 0.35; a[15] = 0.15; a[16] = 0.50; a[17] = 0.2
        a[19] = 0.12 * sz; a[20] = 0.05 * sz; a[21] = 0.20 * sz; a[22] = 0.09 * sz; a[23] = 0.3
        a[33], a[34] = 0.30, 0.65; a[42], a[43] = 0.0, 0.05; a[45], a[46] = -10, 10
    elseif A.kind == 'mist' then    -- EQ 644 fog_nimbus: big soft puffs low around the legs, slow
        a[0] = 1; a[1] = R + 0.04; a[3] = 0.55; a[6] = 0.22
        a[9] = 90; a[12] = 2.4; a[13] = 0.3; a[15] = 0.7; a[16] = 1.1; a[17] = 0.6
        a[19] = 0.34 * sz; a[20] = 0.50 * sz; a[23] = 0.3
        a[33], a[34] = -0.02, 0.04; a[42], a[43] = 0.03, 0.09; a[45], a[46] = 10, 20
    elseif A.kind == 'crackle' then -- storm: tiny fast flickers scattered through the aura
        a[0] = 1; a[1] = R + 0.06; a[3] = 0.6; a[6] = 0.56
        a[9] = 320; a[12] = 0.35; a[13] = 0.5; a[15] = 0.03; a[16] = 0.20
        a[19] = 0.018 * sz; a[20] = 0.006 * sz; a[23] = 0.5
        a[42], a[43] = 0.05, 0.25; a[45], a[46] = 250, 450; a[61] = 0.5
    elseif A.kind == 'halo' then    -- holy: soft light rising from above the shoulders and head
        a[0] = 1; a[1] = R * 0.8; a[3] = 0.50; a[6] = 0.95
        a[9] = 150; a[12] = 2.0; a[13] = 0.3; a[15] = 0.6; a[16] = 1.0; a[17] = 0.5
        a[19] = 0.26 * sz; a[20] = 0.42 * sz; a[23] = 0.3
        a[33], a[34] = 0.06, 0.16; a[42], a[43] = 0.02, 0.06; a[45], a[46] = 6, 14
    elseif A.kind == 'orbit' then   -- EQ 454 wisps: sphere surface around the chest, orbital swirl
        a[0] = 1; a[1] = R + 0.08; a[3] = 0.15; a[6] = 0.58
        a[9] = 160; a[12] = 1.6; a[13] = 0.3; a[15] = 0.4; a[16] = 0.6
        a[19] = 0.040 * sz; a[20] = 0.020 * sz; a[23] = 0.4
        local o1, o2 = 110, 160
        if style == 'void' then o1, o2 = -160, -110 end
        a[45], a[46] = o1, o2
    elseif A.kind == 'bubble' then  -- toxic: bubbles rising out of the aura (EQ 446 bertox)
        a[0] = 1; a[1] = R; a[3] = 0.6; a[6] = 0.40
        a[9] = 70; a[12] = 1.8; a[13] = 0.35; a[15] = 0.25; a[16] = 0.35; a[17] = 0.4
        a[19] = 0.025 * sz; a[20] = 0.055 * sz; a[23] = 0.4
        a[33], a[34] = 0.18, 0.40; a[42], a[43] = 0.02, 0.08; a[45], a[46] = -8, 8
    elseif A.kind == 'drip' then    -- blood: drops falling through the aura (EQ 546 blood aura)
        a[0] = 1; a[1] = R; a[3] = 0.6; a[6] = 0.62
        a[9] = 70; a[12] = 1.2; a[13] = 0.3; a[15] = 0.15; a[16] = 0.30
        a[19] = 0.022 * sz; a[20] = 0.016 * sz; a[21] = 0.040 * sz; a[22] = 0.060 * sz; a[23] = 0.3
        a[33], a[34] = -0.05, 0.0; a[42], a[43] = 0.02, 0.06; a[48] = 0.9
    end
    col(a, A.c, 1.0, 0.3)
    a[32] = A.op * ((A.kind == 'mist' or A.kind == 'halo' or A.kind == 'flame') and am or im) * T.accent
    out[#out + 1] = { name = 'accent', d = a }
    return out
end

-- params for rml_fx_exclude (13 floats): feet x,y, unit axis feet->crown, span, 7 knots, feather px
-- wmul (aura rework, optional, >= 1): body WIDTH scale / feet->crown span. When the camera looks down the span
-- shrinks but the body's on-screen width does not, so the half-widths and feather grow by wmul.
function G.capsule(fx, fy, ux, uy, span, out, wmul)
    out = out or {}
    wmul = tonumber(wmul) or 1
    if wmul < 1 then wmul = 1 elseif wmul > 4 then wmul = 4 end
    out[0], out[1], out[2], out[3], out[4] = fx, fy, ux, uy, span
    for i = 1, 7 do out[4 + i] = G.KNOTS[i] * G.KNOT_MUL * wmul end
    local f = G.FEATHER_FRAC * (tonumber(span) or 0) * wmul
    if f < 6 then f = 6 elseif f > 256 then f = 256 end
    out[12] = f
    return out
end

return G
