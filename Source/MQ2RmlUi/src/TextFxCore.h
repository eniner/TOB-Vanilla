#pragma once
// TextFX (2026-11-14): GPU combat text for CombatFX themes. Device-agnostic core shared by the plugin
// (TextFx.cpp + CanvasRenderer.cpp) and tools/tfx_harness (WARP renderer used for the preview frames).
//  * SDF glyph atlas from a TrueType font (stb_truetype), built once on the CPU.
//  * Number instances with analytic motion (rise/arc/fountain/static/scroll/heal/pop), crit punch, combo badge.
//  * Per frame: glyph records + style records (drawn by vs_tfx_glyph/ps_tfx_glyph) and one particle record per
//    number (vs_tfx_part/ps_tfx_part evaluate every particle statelessly from it, like fx.hlsl).
//  * Body capsule (same 16-float layout as fx::BuildCapsule) masks every pixel; spawns are pushed out of it.
#include "FxSim.h"
#include "../contrib/stb/stb_truetype.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace tfx {

// ---- descriptor (float[48]; Lua passes n <= 48, missing = default) -------------------------------
enum : int {
	D_X = 0, D_Y, D_SIZE, D_LIFE, D_MOTION, D_DIR, D_TRAVEL, D_STYLE,
	D_FILL_T = 8,  /* 8..10 */ D_FILL_B = 11, /* 11..13 */ D_OUT_C = 14, /* 14..16 */ D_OUT_W = 17,
	D_GLOW_C = 18, /* 18..20 */ D_GLOW_R = 21, D_GLOW_S = 22, D_HDR = 23, D_SHINE = 24, D_SHINE_SPD = 25,
	D_CRIT = 26, D_PUNCH = 27, D_FLASH = 28, D_SPARKS = 29, D_SPARK_SPD = 30,
	D_PTYPE = 31, D_PRATE = 32, D_PSIZE = 33, D_PCOL = 34, /* 34..36 */ D_SHATTER = 37,
	D_SHAKE = 38, D_SHAKE_T = 39, D_TRAIL = 40, D_LOOP = 41, D_LOOP_GAP = 42, D_SEED = 43,
	D_ALPHA = 44, D_DELAY = 45, D_COMBO = 46, D_SHADOW = 47,
	kDesc = 48
};
enum Motion { M_STATIC = 0, M_RISE, M_ARC, M_FOUNTAIN, M_SCROLL, M_HEAL, M_POP, M_COUNT };
enum Style { S_FLAT = 0, S_NEON, S_METAL, S_FIRE, S_FROST, S_HOLY, S_VOID, S_STORM, S_TOXIC, S_BLOOD, S_COUNT };
enum PType { P_NONE = 0, P_EMBER, P_SHARD, P_SPARKLE, P_MOTE, P_SPARK, P_DROP, P_BUBBLE, P_RUNE, P_COUNT };

constexpr int kAtlasW = 1024, kAtlasH = 512;
constexpr float kBasePx = 48.f;       // SDF rasterised at this pixel height
constexpr int kPad = 12;              // SDF padding (atlas px)
constexpr float kOnEdge = 96.f;       // byte value on the outline
constexpr float kDistScale = 7.6f;    // bytes per atlas px -> outside 96/7.6 = 12.6 px (covers the 12 px pad: glow reaches 0
                                      // before the quad edge, no boxes), inside 159/7.6 = 20.9 px
constexpr int kMaxNums = 64;          // live numbers per canvas
constexpr int kPartBudget = 64;       // particle instances per number
constexpr int kPathN = 16;

inline float Clamp(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }
inline float Sat(float v) { return Clamp(v, 0.f, 1.f); }
inline float EaseOutCubic(float u) { u = 1.f - Sat(u); return 1.f - u * u * u; }
inline float EaseOutQuad(float u) { u = Sat(u); return 1.f - (1.f - u) * (1.f - u); }
inline float EaseOutBack(float u) { u = Sat(u); const float c1 = 1.70158f, c3 = c1 + 1.f; const float v = u - 1.f; return 1.f + c3 * v * v * v + c1 * v * v; }

inline void DefaultDesc(float* d)
{
	for (int i = 0; i < kDesc; ++i) d[i] = 0.f;
	d[D_SIZE] = 24.f; d[D_LIFE] = 1.3f; d[D_MOTION] = M_RISE; d[D_DIR] = 1.f; d[D_TRAVEL] = 95.f;
	d[D_FILL_T] = d[D_FILL_T + 1] = d[D_FILL_T + 2] = 1.f;
	d[D_FILL_B] = d[D_FILL_B + 1] = d[D_FILL_B + 2] = 1.f;
	d[D_OUT_W] = 2.f; d[D_GLOW_R] = 6.f; d[D_HDR] = 1.6f; d[D_SHINE_SPD] = 1.f;
	d[D_PUNCH] = 1.25f; d[D_SPARK_SPD] = 260.f; d[D_PSIZE] = 5.f;
	d[D_PCOL] = 1.f; d[D_PCOL + 1] = 0.6f; d[D_PCOL + 2] = 0.2f;
	d[D_LOOP_GAP] = 0.35f; d[D_ALPHA] = 1.f; d[D_SHAKE_T] = 0.25f;
}

// Lua floats -> descriptor; everything clamped so a bad theme can never produce huge quads or NaNs.
inline void LoadDesc(float* d, const float* in, int n)
{
	DefaultDesc(d);
	if (in && n > 0)
	{
		if (n > kDesc) n = kDesc;
		for (int i = 0; i < n; ++i)
		{
			const float v = in[i];
			if (v == v && std::fabs(v) < 1e7f) d[i] = v;   // NaN / garbage keep the default
		}
	}
	d[D_SIZE] = Clamp(d[D_SIZE], 6.f, 160.f);
	d[D_LIFE] = Clamp(d[D_LIFE], 0.15f, 8.f);
	d[D_MOTION] = Clamp(std::floor(d[D_MOTION] + 0.5f), 0.f, (float)(M_COUNT - 1));
	d[D_DIR] = d[D_DIR] < 0.f ? -1.f : 1.f;
	d[D_TRAVEL] = Clamp(d[D_TRAVEL], 0.f, 600.f);
	d[D_STYLE] = Clamp(std::floor(d[D_STYLE] + 0.5f), 0.f, (float)(S_COUNT - 1));
	for (int i = 0; i < 3; ++i)
	{
		d[D_FILL_T + i] = Clamp(d[D_FILL_T + i], 0.f, 4.f); d[D_FILL_B + i] = Clamp(d[D_FILL_B + i], 0.f, 4.f);
		d[D_OUT_C + i] = Clamp(d[D_OUT_C + i], 0.f, 4.f); d[D_GLOW_C + i] = Clamp(d[D_GLOW_C + i], 0.f, 4.f);
		d[D_PCOL + i] = Clamp(d[D_PCOL + i], 0.f, 4.f);
	}
	d[D_OUT_W] = Clamp(d[D_OUT_W], 0.f, 6.f);
	d[D_GLOW_R] = Clamp(d[D_GLOW_R], 0.f, 11.f);
	d[D_GLOW_S] = Clamp(d[D_GLOW_S], 0.f, 4.f);
	d[D_HDR] = Clamp(d[D_HDR], 0.2f, 6.f);
	d[D_SHINE] = Clamp(d[D_SHINE], 0.f, 3.f);
	d[D_SHINE_SPD] = Clamp(d[D_SHINE_SPD], 0.f, 6.f);
	d[D_PUNCH] = Clamp(d[D_PUNCH], 1.f, 4.f);
	d[D_FLASH] = Clamp(d[D_FLASH], 0.f, 3.f);
	d[D_SPARKS] = Clamp(std::floor(d[D_SPARKS]), 0.f, 24.f);
	d[D_SPARK_SPD] = Clamp(d[D_SPARK_SPD], 0.f, 900.f);
	d[D_PTYPE] = Clamp(std::floor(d[D_PTYPE] + 0.5f), 0.f, (float)(P_COUNT - 1));
	d[D_PRATE] = Clamp(d[D_PRATE], 0.f, 60.f);
	d[D_PSIZE] = Clamp(d[D_PSIZE], 0.5f, 40.f);
	d[D_SHATTER] = Clamp(std::floor(d[D_SHATTER]), 0.f, 16.f);
	d[D_SHAKE] = Clamp(d[D_SHAKE], 0.f, 14.f);
	d[D_SHAKE_T] = Clamp(d[D_SHAKE_T], 0.05f, 1.f);
	d[D_TRAIL] = Clamp(d[D_TRAIL], 0.f, 1.f);
	d[D_LOOP_GAP] = Clamp(d[D_LOOP_GAP], 0.f, 5.f);
	d[D_ALPHA] = Clamp(d[D_ALPHA], 0.f, 1.f);
	d[D_DELAY] = Clamp(d[D_DELAY], 0.f, 5.f);
	d[D_COMBO] = Clamp(std::floor(d[D_COMBO]), 0.f, 9999.f);
	d[D_SHADOW] = Clamp(d[D_SHADOW], 0.f, 1.f);
}

// ---- motion: offset from the spawn point, scale and alpha at time t of a life L ------------------
struct Pose { float ox, oy, sc, al; };
inline Pose MotionAt(const float* d, float t, float L)
{
	Pose p{ 0.f, 0.f, 1.f, 1.f };
	const float u = Sat(t / L);
	const float tr = d[D_TRAVEL], dir = d[D_DIR];
	switch ((int)d[D_MOTION])
	{
	case M_RISE: p.oy = -tr * EaseOutCubic(u); break;
	case M_ARC:
		p.ox = dir * tr * 0.85f * EaseOutQuad(u);
		p.oy = -tr * 0.62f * (4.f * u * (1.f - u)) - tr * 0.18f * u;
		break;
	case M_FOUNTAIN:
	{
		const float vx = dir * tr * 0.55f / L, vy = -tr * 2.4f / L, g = tr * 4.2f / (L * L);
		const float tt = Clamp(t, 0.f, L);
		p.ox = vx * tt; p.oy = vy * tt + 0.5f * g * tt * tt;
		break;
	}
	case M_SCROLL: p.ox = dir * tr * 1.45f * EaseOutQuad(u); p.oy = -tr * 0.08f * u; break;
	case M_HEAL:
		p.oy = -tr * 1.15f * EaseOutQuad(u);
		p.ox = std::sin(u * 6.2831853f * 1.15f) * 0.07f * tr;
		break;
	case M_POP: p.oy = -tr * 0.38f * EaseOutCubic(Sat((u - 0.12f) / 0.88f)); break;
	default: break;
	}
	// punch-in: big -> overshoot -> 1 (crit 0.22 s, normal 0.12 s)
	const float punch = d[D_PUNCH];
	const float pt = d[D_CRIT] > 0.5f ? 0.22f : 0.12f;
	if (punch > 1.001f && t < pt)
	{
		const float k = t / pt;
		p.sc = punch + (1.f - punch) * EaseOutBack(k);
	}
	if (u > 0.82f) p.sc *= 1.f - 0.10f * (u - 0.82f) / 0.18f;
	p.al = Sat(t / 0.05f);
	if (u > 0.68f) p.al *= Sat(1.f - (u - 0.68f) / 0.32f);
	return p;
}

// ---- SDF atlas ------------------------------------------------------------------------------------
struct Glyph { float u0, v0, u1, v1; float xoff, yoff, w, h; float adv; bool ok; };
struct Atlas
{
	bool ready = false;
	std::vector<unsigned char> px;   // kAtlasW * kAtlasH, R8
	Glyph g[128]{};
	float ascent = 0, descent = 0;   // at kBasePx
	std::vector<unsigned char> fontData;
	stbtt_fontinfo font{};
	float scale = 1.f;
	char fontPath[260] = "";

	bool Build(const unsigned char* ttf, size_t len, const char* path)
	{
		ready = false;
		fontData.assign(ttf, ttf + len);
		if (!stbtt_InitFont(&font, fontData.data(), stbtt_GetFontOffsetForIndex(fontData.data(), 0)))
			return false;
		scale = stbtt_ScaleForPixelHeight(&font, kBasePx);
		int a, de, lg; stbtt_GetFontVMetrics(&font, &a, &de, &lg);
		ascent = a * scale; descent = de * scale;
		px.assign((size_t)kAtlasW * kAtlasH, 0);
		int x = 1, y = 1, rowH = 0;
		for (int c = 32; c < 127; ++c)
		{
			Glyph& G = g[c];
			G = Glyph{};
			int adv, lsb; stbtt_GetCodepointHMetrics(&font, c, &adv, &lsb);
			G.adv = adv * scale;
			int w = 0, h = 0, xo = 0, yo = 0;
			unsigned char* s = stbtt_GetCodepointSDF(&font, scale, c, kPad, (unsigned char)kOnEdge, kDistScale, &w, &h, &xo, &yo);
			if (!s) { G.ok = false; continue; }
			if (x + w + 1 > kAtlasW) { x = 1; y += rowH + 1; rowH = 0; }
			if (y + h + 1 > kAtlasH) { stbtt_FreeSDF(s, nullptr); break; }
			for (int r = 0; r < h; ++r) std::memcpy(&px[(size_t)(y + r) * kAtlasW + x], s + (size_t)r * w, (size_t)w);
			stbtt_FreeSDF(s, nullptr);
			G.u0 = (float)x / kAtlasW; G.v0 = (float)y / kAtlasH; G.u1 = (float)(x + w) / kAtlasW; G.v1 = (float)(y + h) / kAtlasH;
			G.xoff = (float)xo; G.yoff = (float)yo; G.w = (float)w; G.h = (float)h; G.ok = true;
			x += w + 1; if (h > rowH) rowH = h;
		}
		snprintf(fontPath, sizeof(fontPath), "%s", path ? path : "");
		ready = true;
		return true;
	}
	float Kern(int a, int b) const { return (a > 0 && b > 0) ? stbtt_GetCodepointKernAdvance(&font, a, b) * scale : 0.f; }
};

// ---- GPU records (std layout mirrored in shaders/tfx.hlsl) ---------------------------------------
struct GlyphGPU   // 64 B
{
	float x0, y0, x1, y1;      // screen px (canvas local)
	float u0, v0, u1, v1;      // atlas uv
	float wx0, wy0, wx1, wy1;  // word-space coords of the corners (0..1 over the text box)
	float alpha, k;            // opacity, screen px per atlas px
	float num, flags;          // style index, 1 = ghost (trail), 2 = combo badge
};
struct StyleGPU   // 128 B
{
	float fillT[4];            // rgb, hdr
	float fillB[4];            // rgb, glow strength
	float outC[4];             // rgb, outline width (atlas px)
	float glowC[4];            // rgb, glow radius (atlas px)
	float p0[4];               // style, time since spawn, life fraction, crit
	float p1[4];               // shine, shine speed, seed, shadow
	float p2[4];               // box w px, box h px, flash (0..1 now), pad
	float p3[4];
};
struct PartGPU    // 224 B
{
	float o[4];                // origin x,y, shake x,y
	float t[4];                // t since spawn, number life, base size px, scale k
	float c[4];                // particle rgb, intensity
	float a[4];                // type, rate, sparks, spark speed
	float b[4];                // shatter, flash, seed, psize
	float e[4];                // box w, box h, alpha, crit
	float path[kPathN][2];     // offsets of the number path at t = L*i/(N-1)   (128 B)
};
static_assert(sizeof(GlyphGPU) == 64, "GlyphGPU");
static_assert(sizeof(StyleGPU) == 128, "StyleGPU");
static_assert(sizeof(PartGPU) == 224, "PartGPU");

struct FrameOut
{
	std::vector<GlyphGPU> glyphs;
	std::vector<StyleGPU> styles;
	std::vector<PartGPU> parts;
	float bloom = 0.f;          // strongest requested bloom (rml_tfx_bloom)
	bool any = false;
};

struct Num
{
	float d[kDesc]{};
	std::string text;
	int combo = 0;
	double born = 0.0;          // emitter clock at spawn (after delay)
	double pulse = -10.0;       // clock of last combo pulse
	double kill = -1.0;         // clock of a fade kill
	uint32_t seed = 1;
	float bx = 0, by = 0;       // spawn point after capsule push
	float boxW = 0, boxH = 0;   // text box at scale 1 (px)
	int handle = 0;
	bool dead = false;
};

inline float TextWidth(const Atlas& A, const std::string& s, float k)
{
	float w = 0.f; int prev = 0;
	for (unsigned char ch : s)
	{
		int c = (ch < 32 || ch > 126) ? '?' : ch;
		w += (A.g[c].adv + A.Kern(prev, c)) * k; prev = c;
	}
	return w;
}

// Push the spawn point horizontally out of the body capsule so the number never sits on the character
// (pixels are masked anyway; this keeps whole digits readable instead of cut).
inline void PushOutOfCapsule(const float* X, Num& n)
{
	if (!X || X[6] < 0.5f) return;
	const float hw = n.boxW * 0.5f * n.d[D_PUNCH] * 0.75f + 10.f, hh = n.boxH * 0.5f + 6.f;
	for (int it = 0; it < 6; ++it)
	{
		float worst = 1.f;
		for (int s = 0; s < kPathN; s += 3)
		{
			const Pose p = MotionAt(n.d, n.d[D_LIFE] * s / (kPathN - 1), n.d[D_LIFE]);
			const float cx = n.bx + p.ox, cy = n.by + p.oy;
			const float pts[5][2] = { { cx, cy }, { cx - hw, cy - hh }, { cx + hw, cy - hh }, { cx - hw, cy + hh }, { cx + hw, cy + hh } };
			for (auto& q : pts) { const float m = fx::CapsuleMask(X, q[0], q[1]); if (m < worst) worst = m; }
		}
		if (worst > 0.98f) return;
		// side: away from the capsule axis at this height
		const float vx = n.bx - X[0], vy = n.by - X[1];
		const float perp = -vx * X[3] + vy * X[2];
		float side = perp >= 0.f ? 1.f : -1.f;
		// perpendicular direction in screen space (axis is ~vertical, so this is ~horizontal)
		float px = -X[3] * side, py = X[2] * side;
		if (std::fabs(px) < 0.2f) { px = side; py = 0.f; }
		const float step = X[4] * 0.12f + hw * 0.5f;
		n.bx += px * step; n.by += py * step * 0.3f;
	}
}

// Build GPU records for one number at clock `now`. Returns false when the number is finished.
inline bool BuildNum(const Atlas& A, Num& n, double now, float shakeX, float shakeY, int styleIndex, FrameOut& out)
{
	const float* d = n.d;
	const float L = d[D_LIFE];
	double tl = now - n.born;
	if (tl < 0.0) return true;                       // delayed
	if (d[D_LOOP] > 0.5f)
	{
		const double period = L + d[D_LOOP_GAP];
		tl = std::fmod(tl, period);
		if (tl > L) return true;                     // gap between loops
	}
	else if (tl > L + 0.6) return false;             // particles get 0.6 s to finish after the text
	const float t = (float)tl;
	float killA = 1.f;
	if (n.kill >= 0.0) { killA = Sat(1.f - (float)(now - n.kill) / 0.18f); if (killA <= 0.f) return false; }

	const Pose p = MotionAt(d, t, L);
	float sc = p.sc;
	const float pulseAge = (float)(now - n.pulse);
	if (pulseAge >= 0.f && pulseAge < 0.5f) sc *= 1.f + 0.32f * std::exp(-pulseAge * 10.f);
	const float alpha = p.al * d[D_ALPHA] * killA;
	const float k = d[D_SIZE] / kBasePx * sc;
	const float cx = n.bx + p.ox + shakeX, cy = n.by + p.oy + shakeY;

	StyleGPU st{};
	for (int i = 0; i < 3; ++i) { st.fillT[i] = d[D_FILL_T + i]; st.fillB[i] = d[D_FILL_B + i]; st.outC[i] = d[D_OUT_C + i]; st.glowC[i] = d[D_GLOW_C + i]; }
	st.fillT[3] = d[D_HDR]; st.fillB[3] = d[D_GLOW_S]; st.outC[3] = d[D_OUT_W]; st.glowC[3] = d[D_GLOW_R];
	st.p0[0] = d[D_STYLE]; st.p0[1] = t; st.p0[2] = Sat(t / L); st.p0[3] = d[D_CRIT];
	st.p1[0] = d[D_SHINE]; st.p1[1] = d[D_SHINE_SPD]; st.p1[2] = (float)(n.seed % 1000) * 0.001f; st.p1[3] = d[D_SHADOW];
	const float flash = d[D_FLASH] > 0.f ? Sat(1.f - t / 0.16f) * d[D_FLASH] : 0.f;
	st.p2[0] = n.boxW * sc; st.p2[1] = n.boxH * sc; st.p2[2] = flash;
	const int si = (int)out.styles.size();
	(void)styleIndex;

	auto emitRun = [&](const std::string& s, float kk, float ox, float oy, float a, float flags)
	{
		const float w = TextWidth(A, s, kk);
		const float capH = A.ascent * 0.72f * kk;           // digits / caps height
		const float base = oy + capH * 0.5f;                 // baseline so the cap box is centred on oy
		const float wl = ox - w * 0.5f, wt = base - capH;
		const float iw = 1.f / (w > 1.f ? w : 1.f), ih = 1.f / (capH > 1.f ? capH : 1.f);
		float x = wl; int prev = 0;
		for (unsigned char ch : s)
		{
			const int c = (ch < 32 || ch > 126) ? '?' : ch;
			const Glyph& G = A.g[c];
			x += A.Kern(prev, c) * kk; prev = c;
			if (G.ok && G.w > 0 && c != ' ')
			{
				GlyphGPU q{};
				q.x0 = x + G.xoff * kk; q.y0 = base + G.yoff * kk;
				q.x1 = q.x0 + G.w * kk; q.y1 = q.y0 + G.h * kk;
				q.u0 = G.u0; q.v0 = G.v0; q.u1 = G.u1; q.v1 = G.v1;
				q.wx0 = (q.x0 - wl) * iw; q.wx1 = (q.x1 - wl) * iw;
				q.wy0 = (q.y0 - wt) * ih; q.wy1 = (q.y1 - wt) * ih;
				q.alpha = a; q.k = kk; q.num = (float)si; q.flags = flags;
				out.glyphs.push_back(q);
			}
			x += G.adv * kk;
		}
		return w;
	};

	bool drewText = t <= L && alpha > 0.002f;
	if (drewText)
	{
		// ghost trail (heal float / any theme with trail): 3 earlier poses, fading
		if (d[D_TRAIL] > 0.01f)
		{
			for (int gi = 3; gi >= 1; --gi)
			{
				const float tg = t - gi * 0.055f;
				if (tg <= 0.f) continue;
				const Pose g = MotionAt(d, tg, L);
				emitRun(n.text, d[D_SIZE] / kBasePx * g.sc, n.bx + g.ox + shakeX, n.by + g.oy + shakeY,
					alpha * d[D_TRAIL] * (0.42f - gi * 0.11f), 1.f);
			}
		}
		const float w = emitRun(n.text, k, cx, cy, alpha, 0.f);
		if (n.combo > 1)
		{
			char buf[16]; snprintf(buf, sizeof(buf), "x%d", n.combo);
			const float bk = k * 0.62f * (1.f + (pulseAge >= 0.f && pulseAge < 0.5f ? 0.45f * std::exp(-pulseAge * 9.f) : 0.f));
			const float bw = TextWidth(A, buf, bk);
			emitRun(buf, bk, cx + w * 0.5f + bw * 0.5f + 6.f * k, cy + A.ascent * 0.72f * (k - bk) * 0.5f, alpha, 2.f);
		}
		out.styles.push_back(st);
		out.any = true;
	}
	else if (t <= L)
		out.styles.push_back(st);   // keep index stable for particles of an invisible frame

	// particles: one record, the shader evaluates up to kPartBudget instances from it
	const bool wantP = d[D_PTYPE] > 0.5f || d[D_SPARKS] > 0.5f || d[D_FLASH] > 0.01f || d[D_SHATTER] > 0.5f;
	if (wantP)
	{
		PartGPU r{};
		r.o[0] = n.bx; r.o[1] = n.by; r.o[2] = shakeX; r.o[3] = shakeY;
		r.t[0] = t; r.t[1] = L; r.t[2] = d[D_SIZE]; r.t[3] = sc;
		r.c[0] = d[D_PCOL]; r.c[1] = d[D_PCOL + 1]; r.c[2] = d[D_PCOL + 2]; r.c[3] = d[D_HDR];
		r.a[0] = d[D_PTYPE]; r.a[1] = d[D_PRATE]; r.a[2] = d[D_SPARKS]; r.a[3] = d[D_SPARK_SPD];
		r.b[0] = d[D_SHATTER]; r.b[1] = d[D_FLASH]; r.b[2] = (float)(n.seed & 0xFFFF); r.b[3] = d[D_PSIZE];
		r.e[0] = n.boxW * sc; r.e[1] = n.boxH * sc; r.e[2] = d[D_ALPHA] * killA; r.e[3] = d[D_CRIT];
		for (int i = 0; i < kPathN; ++i)
		{
			const Pose q = MotionAt(d, L * i / (kPathN - 1), L);
			r.path[i][0] = q.ox; r.path[i][1] = q.oy;
		}
		out.parts.push_back(r);
		out.any = true;
	}
	return true;
}

} // namespace tfx
