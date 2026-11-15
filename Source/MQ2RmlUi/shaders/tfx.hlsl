// MQ2RmlUi TextFX (2026-11-14): CombatFX theme numbers on the GPU.
// vs_tfx_glyph/ps_tfx_glyph: SDF glyph quads with per-number shader styles (glow, soft outline, gradient,
// moving metal/fire shine, frost facets, holy rays, void rim, storm veins, toxic bubbles, blood gloss).
// vs_tfx_part/ps_tfx_part: stateless number particles (embers, shards, sparkles, motes, sparks, drops,
// bubbles, runes) + crit flash/ring/sparks + frost shatter, all evaluated from one record per number.
// Every pixel is multiplied by the body capsule mask (same layout/maths as fx.hlsl) -> nothing on the character.
// Output is premultiplied (ONE, INV_SRC_ALPHA); alpha 0 with rgb > 0 = additive light.

cbuffer TfxCB : register(b1)
{
	float4 S0;   // sceneW, sceneH, atlasW, atlasH
	float4 S1;   // clock, glyphs, parts, 0
	float4 X[4]; // capsule: fx,fy,ux,uy | span,feather,enabled,0 | k0..k3 | k4..k6,0
};
#define XS(i) X[(i) >> 2][(i) & 3]

float lrp(float a, float b, float t) { return a + t * (b - a); }
float CapsuleHW(float t)
{
	if (t < 0.20) return lrp(XS(8), XS(9), saturate(t / 0.20));
	if (t < 0.42) return lrp(XS(9), XS(10), (t - 0.20) / 0.22);
	if (t < 0.70) return lrp(XS(10), XS(11), (t - 0.42) / 0.28);
	if (t < 0.84) return lrp(XS(11), XS(12), (t - 0.70) / 0.14);
	if (t < 0.94) return lrp(XS(12), XS(13), (t - 0.84) / 0.10);
	return lrp(XS(13), XS(14), saturate((t - 0.94) / 0.14));
}
float CapsuleDist(float2 p)
{
	float2 v = p - X[0].xy;
	float span = max(X[1].x, 1.0);
	float along = dot(v, X[0].zw);
	float t = along / span;
	float perp = abs(-v.x * X[0].w + v.y * X[0].z);
	if (t > 1.08)
	{
		float2 c = X[0].xy + X[0].zw * span * 1.08;
		return length(p - c) - CapsuleHW(1.08) * span;
	}
	return max(-along, perp - CapsuleHW(t) * span);
}
float CapsuleMask(float2 p)
{
	if (X[1].z < 0.5) return 1.0;
	float t = saturate(CapsuleDist(p) / max(X[1].y, 0.001));
	return t * t * (3.0 - 2.0 * t);
}

uint pcg(uint v)
{
	uint s = v * 747796405u + 2891336453u;
	uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
	return (w >> 22u) ^ w;
}
float U(uint key, uint s) { return (float)(pcg(key + s * 0x9E3779B9u) >> 8) * (1.0 / 16777216.0); }
float h21(float2 p) { float3 q = frac(p.xyx * 0.1031); q += dot(q, q.yzx + 33.33); return frac((q.x + q.y) * q.z); }
float vnoise(float2 p)
{
	float2 i = floor(p), f = frac(p);
	float2 u = f * f * (3.0 - 2.0 * f);
	return lerp(lerp(h21(i), h21(i + float2(1, 0)), u.x), lerp(h21(i + float2(0, 1)), h21(i + float2(1, 1)), u.x), u.y);
}
float fbm(float2 p) { return 0.5 * vnoise(p) + 0.27 * vnoise(p * 2.03 + 7.1) + 0.15 * vnoise(p * 4.1 + 3.7) + 0.08 * vnoise(p * 8.3 + 1.3); }
float2 cellEdge(float2 p)    // x = distance to nearest cell edge, y = cell id hash
{
	float2 i = floor(p), f = frac(p);
	float d1 = 8.0, d2 = 8.0, id = 0.0;
	[unroll] for (int y = -1; y <= 1; ++y)
	[unroll] for (int x = -1; x <= 1; ++x)
	{
		float2 g = float2(x, y);
		float2 o = float2(h21(i + g), h21(i + g + 19.7));
		float d = length(g + o - f);
		if (d < d1) { d2 = d1; d1 = d; id = h21(i + g + 3.3); }
		else if (d < d2) d2 = d;
	}
	return float2(d2 - d1, id);
}

static const float2 kCorner[6] = { float2(-1, -1), float2(1, -1), float2(1, 1), float2(-1, -1), float2(1, 1), float2(-1, 1) };

// ------------------------------------------------------------------------------------------- glyphs
struct GlyphRec { float4 r; float4 uv; float4 w; float4 m; };          // m = alpha, k, style, flags
struct StyleRec { float4 fillT; float4 fillB; float4 outC; float4 glowC; float4 p0; float4 p1; float4 p2; float4 p3; };
StructuredBuffer<GlyphRec> gGlyph : register(t0);   // VS
StructuredBuffer<StyleRec> gStyle : register(t1);   // VS + PS
Texture2D<float> gAtlas : register(t0);             // PS
SamplerState gSamp : register(s0);

struct GOut
{
	float4 pos : SV_POSITION;
	float2 uv : TEXCOORD0;
	float2 w : TEXCOORD1;
	nointerpolation float4 m : TEXCOORD2;
};

GOut vs_tfx_glyph(uint vid : SV_VertexID, uint iid : SV_InstanceID)
{
	GOut o;
	GlyphRec g = gGlyph[iid];
	float2 c = kCorner[vid % 6u] * 0.5 + 0.5;
	float2 p = lerp(g.r.xy, g.r.zw, c);
	o.pos = float4(p.x / S0.x * 2.0 - 1.0, 1.0 - p.y / S0.y * 2.0, 0.0, 1.0);
	o.uv = lerp(g.uv.xy, g.uv.zw, c);
	o.w = lerp(g.w.xy, g.w.zw, c);
	o.m = g.m;
	return o;
}

float SdAt(float2 uv) { return (gAtlas.SampleLevel(gSamp, uv, 0) * 255.0 - 96.0) / 7.6; }    // atlas px, + inside (== kDistScale)

float3 FireRamp(float h)
{
	float3 a = float3(0.40, 0.02, 0.00), b = float3(1.25, 0.28, 0.02), c = float3(1.70, 1.00, 0.18), d = float3(1.90, 1.65, 1.00);
	if (h < 0.40) return lerp(a, b, h / 0.40);
	if (h < 0.75) return lerp(b, c, (h - 0.40) / 0.35);
	return lerp(c, d, saturate((h - 0.75) / 0.25));
}

// glow fix (gfx2): the canvas composite runs ACES per channel, which pushes any bright colour toward white,
// and the canvas bloom has no threshold. Glyphs are now drawn AFTER bloom (CanvasRenderer) and written
// display-referred: a hue-preserving soft clip (max channel <= 0.96) then the exact inverse of the composite's
// ACES, so what reaches the screen is the theme colour itself, never a white blob.
float3 HueClip(float3 c, float knee, float top)
{
	float m = max(max(c.r, c.g), c.b);
	if (m <= knee) return c;
	float r = top - knee;
	float nm = knee + r * (1.0 - exp(-(m - knee) / r));
	return c * (nm / m);
}
float3 AcesInv(float3 y)
{
	y = clamp(y, 0.0, 0.97);
	float3 A = 2.51 - 2.43 * y;
	float3 B = 0.03 - 0.59 * y;
	return (-B + sqrt(B * B + 4.0 * A * 0.14 * y)) / (2.0 * A);
}

float4 ps_tfx_glyph(GOut i) : SV_Target
{
	StyleRec S = gStyle[(uint)i.m.z];
	const float k = max(i.m.y, 0.05);
	const uint style = (uint)(S.p0.x + 0.5);
	const float t = S.p0.y;
	const float seed = S.p1.z;
	const bool ghost = i.m.w > 0.5 && i.m.w < 1.5;
	const float2 w = i.w;
	const float2 px = i.pos.xy;

	float sd = SdAt(i.uv);
	float aa = max(fwidth(sd), 0.03) * (ghost ? 2.2 : 0.75);
	float fillA = smoothstep(-aa, aa, sd);
	float ow = min(S.outC.w / k, 9.0);              // outline width given in screen px -> atlas px (stays inside the pad)
	float outA = ow > 0.01 ? smoothstep(-ow - aa, -ow + aa, sd) : fillA;
	float gr = max(S.glowC.w, 0.25);
	// distance outside the outline; falls to exactly 0 at 10.5 atlas px (< the 12 px pad) so a glyph quad never shows its edge
	float gd = max(-sd - ow, 0.0);
	float gf = saturate(1.0 - gd / 10.5);
	// glow starts ~2.5 atlas px off the outline: a thin dark gap keeps the digits readable on bright/white looks
	float glow = exp(-gd / (gr * 0.5)) * gf * gf * smoothstep(0.0, 2.5, gd) * saturate(1.0 - outA) * S.fillB.w;
	float halo = exp(-gd / 1.8) * saturate(1.0 - outA) * 0.45;     // soft dark contrast halo hugging the outline

	float hdr = S.fillT.w;
	float3 fill = lerp(S.fillT.rgb, S.fillB.rgb, saturate(w.y));
	float3 glowC = S.glowC.rgb;
	float3 outC = S.outC.rgb;

	if (style == 1u)            // NEON: hot white core, wide coloured glow, mains flicker
	{
		float core = smoothstep(1.2, 4.0, sd);
		fill = lerp(fill, float3(1.0, 1.0, 1.0), core * 0.65);
		glow *= 0.92 + 0.08 * sin(t * 38.0 + seed * 40.0);
	}
	else if (style == 2u)       // METAL: brushed bands, top specular, moving shine sweep
	{
		float bands = 0.62 + 0.38 * cos((w.y * 3.1 - 0.55) * 3.14159);
		fill *= bands;
		fill += exp(-pow(w.y - 0.30, 2.0) * 90.0) * 0.55;
		fill *= 0.92 + 0.08 * vnoise(float2(w.x * 60.0, w.y * 3.0));
		float ph = frac(t * S.p1.y * 0.55 + seed) * 2.6 - 0.8;
		float band = exp(-pow((w.x * 0.78 + w.y * 0.32) - ph, 2.0) * 55.0) * S.p1.x;
		fill += band * float3(1.6, 1.5, 1.3);
	}
	else if (style == 3u)       // FIRE: animated noise heat ramp, flames licking up in the glow
	{
		float n = fbm(float2(w.x * 4.0 + seed * 7.0, w.y * 3.0 + t * 3.4));
		float heat = saturate((1.0 - w.y) * 0.45 + n * 0.85 - 0.12);
		fill = FireRamp(heat) / max(hdr, 0.5);
		float fl = fbm(float2(px.x / 13.0 + seed * 3.0, px.y / 13.0 + t * 3.6));
		glow *= saturate(0.35 + 1.25 * fl) * (0.8 + 0.6 * saturate(-sd / (gr * 0.8)));
		glowC = lerp(glowC, float3(1.6, 0.35, 0.02), saturate(-sd / gr));
		float ph = frac(t * S.p1.y * 0.5 + seed) * 2.6 - 0.8;
		fill += exp(-pow((w.x * 0.8 + w.y * 0.3) - ph, 2.0) * 40.0) * S.p1.x * float3(1.4, 0.9, 0.3);
	}
	else if (style == 4u)       // FROST: crystal facets, white inner rim, glints
	{
		float2 ce = cellEdge(float2(w.x * 6.0 + seed * 5.0, w.y * 3.4));
		fill *= 0.82 + 0.30 * ce.y;
		fill += smoothstep(0.07, 0.0, ce.x) * 0.55;
		fill += smoothstep(2.4, 0.4, sd) * fillA * 0.65;
		float gl = pow(saturate(sin(w.x * 23.0 + t * 3.0 + seed * 9.0) * sin(w.y * 17.0 - t * 2.1)), 22.0);
		fill += gl * 2.2;
		float ph = frac(t * S.p1.y * 0.45 + seed) * 2.6 - 0.8;
		fill += exp(-pow((w.x * 0.8 + w.y * 0.35) - ph, 2.0) * 60.0) * S.p1.x * float3(1.2, 1.4, 1.6);
	}
	else if (style == 5u)       // HOLY: shimmering gold-white, sun rays in the glow
	{
		fill += 0.45 * pow(sin(w.x * 11.0 - t * 5.0) * 0.5 + 0.5, 6.0);
		float2 q = float2((w.x - 0.5) * max(S.p2.x, 1.0) / max(S.p2.y, 1.0), w.y - 0.5);
		float a = atan2(q.y, q.x);
		float rays = 0.45 + 0.75 * pow(abs(sin(a * 6.0 + t * 1.4 + seed * 6.0)), 3.0);
		glow *= rays * 1.25;
		float ph = frac(t * S.p1.y * 0.5 + seed) * 2.6 - 0.8;
		fill += exp(-pow((w.x * 0.8 + w.y * 0.3) - ph, 2.0) * 50.0) * S.p1.x * float3(1.5, 1.3, 0.8);
	}
	else if (style == 6u)       // VOID: near-black core, violet rim light, swirling dark glow
	{
		float rim = smoothstep(3.2, 0.2, sd);
		fill = lerp(S.fillB.rgb * 0.35, S.fillT.rgb * 1.4, rim);
		float2 c = px / 18.0;
		float sw = fbm(float2(c.x + sin(t * 1.3) * 0.8, c.y - t * 0.9));
		glow *= 0.45 + 0.9 * sw;
		glowC *= 0.7 + 0.5 * sw;
	}
	else if (style == 7u)       // STORM: electric veins crawling through, stuttering glow
	{
		float v = abs(fbm(float2(w.x * 5.0 + seed * 4.0, w.y * 3.5 + t * 7.0)) - 0.5);
		float vein = smoothstep(0.055, 0.0, v);
		fill += vein * float3(1.6, 1.8, 2.2);
		float fl = step(0.35, h21(float2(floor(t * 22.0), seed * 100.0)));
		glow *= 0.55 + 0.75 * fl;
	}
	else if (style == 8u)       // TOXIC: rising bubbles inside the digits, sickly pulse
	{
		float2 bp = float2(w.x * 7.0 + seed * 3.0, w.y * 3.0 + t * 1.6);
		float2 ce = cellEdge(bp);
		float bub = smoothstep(0.30, 0.18, ce.x) * smoothstep(0.08, 0.16, ce.x);
		fill = lerp(fill, fill * 1.8 + 0.25, bub * 0.7);
		glow *= 0.75 + 0.35 * sin(t * 6.0 + seed * 10.0);
	}
	else if (style == 9u)       // BLOOD: deep gloss, darker bottom, wet highlight
	{
		fill *= lerp(1.15, 0.55, saturate(w.y));
		fill += exp(-pow(w.y - 0.22, 2.0) * 120.0) * float3(0.9, 0.35, 0.35);
	}
	else                        // FLAT / classic: optional metal shine when shine > 0
	{
		float ph = frac(t * S.p1.y * 0.55 + seed) * 2.6 - 0.8;
		fill += exp(-pow((w.x * 0.78 + w.y * 0.32) - ph, 2.0) * 55.0) * S.p1.x * float3(1.3, 1.25, 1.1);
	}

	// crit flash: brighten in the number's own hue (was +2.0 white, which blew the digits out)
	fill = lerp(fill, fill * 1.35 + glowC * 0.18 + 0.05, saturate(S.p2.z * 0.6));
	if (i.m.w > 1.5) fill *= 1.12;                  // combo badge

	float3 col;
	float a;
	if (ghost)
	{
		col = HueClip(fill * hdr, 0.75, 0.96) * fillA * 0.9;   // trail: soft additive light only
		a = 0.0;
	}
	else
	{
		float3 fc = HueClip(fill * hdr, 0.80, 0.96);
		col = fc * fillA + outC * saturate(outA - fillA);
		a = outA + halo * (1.0 - outA);
		// additive glow in the theme hue, capped so it never reaches white
		col += HueClip(glowC * glow * hdr * 0.6, 0.45, 0.70) * (1.0 - fillA);
		a = saturate(a + glow * 0.10);
		if (S.p1.w > 0.01)                          // drop shadow 2 px down-right
		{
			float2 off = float2(2.0, 2.0) / (k * S0.zw);
			float sh = smoothstep(-ow - 1.0, -ow + 1.0, SdAt(i.uv - off)) * S.p1.w * 0.75;
			a = a + sh * (1.0 - a);
		}
	}
	float m = CapsuleMask(px) * i.m.x;
	col = AcesInv(HueClip(col, 0.85, 0.96));        // composite ACES(x) then gives back exactly col
	return float4(col * m, a * m);
}

// ---------------------------------------------------------------------------------------- particles
struct PartRec { float4 o; float4 t; float4 c; float4 a; float4 b; float4 e; float4 path[8]; };   // path: 16 x float2
StructuredBuffer<PartRec> gPart : register(t0);   // VS

struct POut
{
	float4 pos : SV_POSITION;
	float2 cr : TEXCOORD0;
	nointerpolation float4 col : COLOR0;          // rgb (HDR), alpha
	nointerpolation float4 info : TEXCOORD1;      // shape, additive(1)/solid(0), 0, 0
};

float2 PathAt(PartRec P, float u)
{
	float f = saturate(u) * 15.0;
	uint i0 = min((uint)f, 14u);
	float fr = f - (float)i0;
	float4 A = P.path[i0 >> 1], B = P.path[(i0 + 1) >> 1];
	float2 a = (i0 & 1u) ? A.zw : A.xy;
	float2 b = ((i0 + 1) & 1u) ? B.zw : B.xy;
	return lerp(a, b, fr);
}

POut Cull()
{
	POut o;
	o.pos = float4(-2.0, -2.0, 0.0, 1.0);
	o.cr = 0; o.col = 0; o.info = 0;
	return o;
}

POut vs_tfx_part(uint vid : SV_VertexID, uint iid : SV_InstanceID)
{
	const uint sys = iid / 64u, j = iid % 64u;
	if (sys >= (uint)S1.z) return Cull();
	PartRec P = gPart[sys];
	const float t = P.t.x, L = P.t.y, size = P.t.z, sc = P.t.w;
	const uint type = (uint)(P.a.x + 0.5);
	const float rate = P.a.y, sparks = P.a.z, sspd = P.a.w, shatter = P.b.x, flash = P.b.y, ps = P.b.w;
	const uint key0 = pcg((uint)P.b.z * 977u + sys * 131u) ^ 0x5bd1e995u;
	const uint key = pcg(key0 + j * 7919u);
	const float2 org = P.o.xy + P.o.zw;
	const float bw = max(P.e.x, 4.0), bh = max(P.e.y, 4.0);
	const float galpha = P.e.z;
	const float3 pc = P.c.rgb;
	const float hdr = max(P.c.w, 0.5);

	float2 c = 0, hs = 0; float rot = 0; float4 col = 0; float shape = 0, add = 1;
	float age = -1, life = 1;

	uint start = 2u;
	const uint nsp = (uint)sparks, nsh = (uint)shatter;
	if (j == 0u)                                     // crit flash
	{
		if (flash <= 0.01) return Cull();
		life = 0.20; age = t;
		if (age < 0 || age > life) return Cull();
		float u = age / life;
		c = org + PathAt(P, 0);
		float r = size * 1.4 * flash * (0.65 + 0.5 * u);
		hs = float2(r, r * 0.62);
		col = float4(pc * 1.05, (1.0 - u) * (1.0 - u) * 0.30);    // theme-tinted, small and soft (was white-hot 2.4 at 0.85, radius 2x)
		shape = 5;
	}
	else if (j == 1u)                                // crit ring (crits only; big non-crit hits just flash)
	{
		if (flash <= 0.01 || P.e.w < 0.5) return Cull();
		life = 0.34; age = t;
		if (age < 0 || age > life) return Cull();
		float u = age / life;
		c = org + PathAt(P, 0);
		float r = lerp(size * 0.5, size * 2.2, 1.0 - (1.0 - u) * (1.0 - u) * (1.0 - u));
		hs = float2(r, r * 0.62);
		col = float4(pc * 1.4 + 0.2, (1.0 - u) * (1.0 - u) * 0.6);
		shape = 4;
	}
	else if (j < start + nsp)                        // crit sparks
	{
		life = 0.35 + 0.25 * U(key, 1u); age = t;
		if (age > life) return Cull();
		float ang = -1.5708 + (U(key, 2u) * 2.0 - 1.0) * 2.4;
		float sp = sspd * (0.45 + 0.55 * U(key, 3u));
		float2 v0 = float2(cos(ang), sin(ang)) * sp;
		float dr = 3.2;
		float e = (1.0 - exp(-dr * age)) / dr;
		float2 g = float2(0.0, 420.0);
		c = org + PathAt(P, 0) + v0 * e + 0.5 * g * age * age;
		float2 vel = v0 * exp(-dr * age) + g * age;
		float len = clamp(length(vel) * 0.035, 2.0, 22.0);
		hs = float2(len, max(1.2, ps * 0.32)) * (1.0 - 0.5 * age / life);
		rot = atan2(vel.y, vel.x);
		col = float4(lerp(pc * 1.35 + 0.08, pc * 1.15, age / life), 1.0 - age / life);
		shape = 1;
	}
	else if (j < start + nsp + nsh)                  // frost / crit shatter at the end of the number
	{
		float tb = L * 0.80;
		life = 0.50 + 0.2 * U(key, 1u); age = t - tb;
		if (age < 0 || age > life) return Cull();
		float2 c0 = org + PathAt(P, 0.80) + float2((U(key, 2u) - 0.5) * bw * 0.9 * sc, (U(key, 3u) - 0.5) * bh * 0.8 * sc);
		float ang = U(key, 4u) * 6.2831853;
		float sp = 80.0 + 160.0 * U(key, 5u);
		float2 v0 = float2(cos(ang), sin(ang) * 0.8 - 0.35) * sp;
		c = c0 + v0 * age + 0.5 * float2(0, 520.0) * age * age;
		float s = ps * (1.0 + 1.2 * U(key, 6u));
		hs = float2(s, s * 0.55);
		rot = U(key, 7u) * 6.28 + age * (U(key, 8u) * 2.0 - 1.0) * 14.0;
		col = float4(lerp(pc * 1.6 + 0.4, pc, age / life), (1.0 - age / life) * 0.95);
		shape = 2; add = 0.35;
	}
	else                                             // stream particles of the theme
	{
		if (type == 0u || rate <= 0.01) return Cull();
		uint k = j - (start + nsp + nsh);
		float tb = ((float)k + 0.25 + 0.5 * U(key, 9u)) / rate;
		if (tb > L * 0.92) return Cull();
		age = t - tb;
		if (age < 0) return Cull();
		float2 at = org + PathAt(P, tb / L);
		float2 jit = float2((U(key, 2u) - 0.5) * bw, (U(key, 3u) - 0.5) * bh) * 0.9;
		float r1 = U(key, 4u), r2 = U(key, 5u), r3 = U(key, 6u);
		if (type == 1u)          // EMBER: shed from the digits, rising, flickering, cooling
		{
			life = 0.65 + 0.45 * r1;
			if (age > life) return Cull();
			float u = age / life;
			float2 v = float2((r2 - 0.5) * 50.0, -55.0 - 75.0 * r3);
			c = at + jit + v * age + 0.5 * float2(sin(age * 9.0 + r1 * 20.0) * 30.0, -40.0) * age * age;
			float s = ps * (0.6 + 0.8 * r2) * (1.0 - 0.65 * u);
			hs = float2(s * 1.7, s);
			rot = atan2(v.y - 40.0 * age, v.x);
			float fl = 0.75 + 0.25 * sin(age * 40.0 + r3 * 30.0);
			col = float4(lerp(float3(2.4, 1.5, 0.35), float3(1.2, 0.18, 0.02), u) * fl, (1.0 - u));
			shape = 1;
		}
		else if (type == 2u)     // SHARD: ice flakes falling off the number
		{
			life = 0.75 + 0.3 * r1;
			if (age > life) return Cull();
			float u = age / life;
			float2 v = float2((r2 - 0.5) * 60.0, 15.0 + 45.0 * r3);
			c = at + jit + v * age + 0.5 * float2(0.0, 90.0) * age * age;
			float s = ps * (0.7 + 0.8 * r2);
			hs = float2(s, s * 0.55);
			rot = r1 * 6.28 + age * (r3 - 0.5) * 10.0;
			col = float4(lerp(pc * 1.5 + 0.35, pc * 0.9, u), 1.0 - u);
			shape = 2; add = 0.5;
		}
		else if (type == 3u)     // SPARKLE: holy four-point twinkles around the digits
		{
			life = 0.45 + 0.25 * r1;
			if (age > life) return Cull();
			float u = age / life;
			c = at + jit * 1.35 + float2(0.0, -14.0 * age);
			float tw = sin(3.14159 * u);
			float s = ps * (1.2 + 1.3 * r2) * tw;
			hs = float2(s, s);
			rot = r3 * 0.6;
			col = float4(lerp(float3(2.6, 2.4, 1.6), pc * 2.0, r3 * 0.6), tw);
			shape = 3;
		}
		else if (type == 4u)     // MOTE: void motes drawn inward to the number, some dark
		{
			life = 0.55 + 0.25 * r1;
			if (age > life) return Cull();
			float u = age / life;
			float ang = r2 * 6.2831853;
			float R = max(bw, bh) * sc * (0.75 + 0.5 * r3);
			float2 ring = at + float2(cos(ang), sin(ang) * 0.6) * R;
			float2 dst = org + PathAt(P, (tb + age) / L);
			float e = u * u;
			c = lerp(ring, dst, e);
			float s = ps * (0.7 + 0.8 * r3) * (1.0 - 0.5 * e);
			hs = float2(s, s);
			bool dark = r1 < 0.4;
			col = dark ? float4(0.0, 0.0, 0.0, 0.55 * sin(3.14159 * u)) : float4(pc * 2.0, sin(3.14159 * u));
			add = dark ? 0.0 : 1.0;
			shape = 0;
		}
		else if (type == 5u)     // SPARK: storm arcs jumping off the digits
		{
			life = 0.14 + 0.14 * r1;
			if (age > life) return Cull();
			float u = age / life;
			float ang = r2 * 6.2831853;
			float sp = 140.0 + 160.0 * r3;
			float2 v = float2(cos(ang), sin(ang)) * sp;
			c = at + jit + v * age;
			hs = float2(clamp(sp * 0.05, 3.0, 14.0), max(1.0, ps * 0.28));
			rot = ang + (U(key, 7u) - 0.5) * 0.6;
			float fl = step(0.3, U(key + (uint)(age * 60.0), 8u));
			col = float4(float3(1.7, 2.0, 2.6) * fl, (1.0 - u));
			shape = 1;
		}
		else if (type == 6u)     // DROP: blood drips falling from the number
		{
			life = 0.6 + 0.3 * r1;
			if (age > life) return Cull();
			float u = age / life;
			float2 c0 = at + float2(jit.x, bh * 0.35);
			float2 v = float2((r2 - 0.5) * 40.0, -10.0 + 30.0 * r3);
			c = c0 + v * age + 0.5 * float2(0.0, 760.0) * age * age;
			float2 vel = v + float2(0.0, 760.0) * age;
			float s = ps * (0.6 + 0.6 * r2);
			hs = float2(s * clamp(length(vel) / 140.0, 1.0, 2.8), s * 0.75);
			rot = atan2(vel.y, vel.x);
			col = float4(pc, 1.0 - u * u);
			shape = 0; add = 0.0;
		}
		else if (type == 7u)     // BUBBLE: toxic bubbles rising and popping
		{
			life = 0.7 + 0.35 * r1;
			if (age > life) return Cull();
			float u = age / life;
			c = at + jit + float2(sin(age * 7.0 + r2 * 10.0) * 7.0, -(40.0 + 30.0 * r3) * age);
			float s = ps * (0.8 + 0.9 * r2) * (u > 0.85 ? 1.0 + (u - 0.85) * 4.0 : 1.0);
			hs = float2(s, s);
			col = float4(pc * 1.6, u > 0.85 ? (1.0 - u) / 0.15 : 0.9);
			shape = 7; add = 0.6;
		}
		else                     // RUNE: arcane glyph-squares orbiting the number
		{
			life = L - tb;
			if (age > life) return Cull();
			float u = age / max(life, 0.01);
			float2 ctr = org + PathAt(P, (tb + age) / L);
			float ang = r2 * 6.2831853 + age * (2.4 + 1.2 * r3) * (r1 < 0.5 ? 1.0 : -1.0);
			float R = max(bw * 0.62, bh) * sc * (0.85 + 0.3 * r3);
			c = ctr + float2(cos(ang) * R, sin(ang) * R * 0.42);
			float s = ps * (0.9 + 0.6 * r1);
			hs = float2(s, s);
			rot = age * 2.0;
			col = float4(pc * 1.8, saturate(age / 0.12) * (1.0 - u));
			shape = 6;
		}
	}

	if (col.a <= 0.002 || (hs.x <= 0.01 && hs.y <= 0.01)) return Cull();
	col.a *= galpha;
	col.rgb = HueClip(col.rgb * (hdr / 1.6), 0.9, 1.4);   // particles stay in their hue before bloom
	POut o;
	float2 cr = kCorner[vid % 6u];
	float2 l = cr * hs;
	float cs = cos(rot), sn = sin(rot);
	float2 q = c + float2(cs * l.x - sn * l.y, sn * l.x + cs * l.y);
	o.pos = float4(q.x / S0.x * 2.0 - 1.0, 1.0 - q.y / S0.y * 2.0, 0.0, 1.0);
	o.cr = cr;
	o.col = col;
	o.info = float4(shape, add, 0, 0);
	return o;
}

float4 ps_tfx_part(POut i) : SV_Target
{
	const uint shape = (uint)(i.info.x + 0.5);
	float2 p = i.cr;
	float r = length(p);
	float a;
	if (shape == 1u)       { a = saturate(1.0 - r); a = a * a * (0.4 + 0.6 * a); }                    // streak
	else if (shape == 2u)  { float d = abs(p.x) + abs(p.y); a = saturate((1.0 - d) * 3.0) * (0.55 + 0.45 * saturate(1.0 - d * 1.6) + 0.35 * saturate(0.25 - abs(p.x - p.y * 0.3))); }   // shard
	else if (shape == 3u)  { float cx = exp(-abs(p.y) * 14.0) * saturate(1.0 - abs(p.x)); float cy = exp(-abs(p.x) * 14.0) * saturate(1.0 - abs(p.y)); a = saturate(max(cx, cy) + pow(saturate(1.0 - r * 2.2), 2.0)); }   // star
	else if (shape == 4u)  { a = exp(-pow((r - 0.82) / 0.07, 2.0)) * step(r, 1.0); }                   // ring
	else if (shape == 5u)  { a = pow(saturate(1.0 - r), 2.6); }                                         // flash
	else if (shape == 6u)  { float m = max(abs(p.x), abs(p.y)); a = saturate(1.0 - abs(m - 0.62) * 9.0) + saturate(0.18 - abs(p.x)) * saturate(1.0 - abs(p.y) * 1.6) * 3.0; a = saturate(a) * step(m, 1.0); }   // rune
	else if (shape == 7u)  { a = saturate(1.0 - abs(r - 0.78) * 6.0) * step(r, 1.0) + pow(saturate(1.0 - length(p - float2(-0.3, -0.35)) * 4.0), 2.0); a = saturate(a); }   // bubble
	else                   { a = saturate(1.0 - r); a = a * a * (0.35 + 0.65 * a); }                  // dot
	float m = CapsuleMask(i.pos.xy);
	float al = a * i.col.a * m;
	float3 rgb = i.col.rgb * al;
	return float4(rgb, al * (1.0 - i.info.y));
}
