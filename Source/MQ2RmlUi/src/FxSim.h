#pragma once
// MQ2RmlUi Stage 1 GPU particles: shared emitter math (2026-11-12).
//
// Every particle is a pure function of (emitter constants, slot index, emitter clock): no per-particle GPU
// state, nothing to re-seed after device loss, nothing to stream per frame except one 544-byte constant
// buffer per emitter. FxEval() below is the C++ twin of FxEval() in shaders/fx.hlsl: same integer hash,
// same formula, same operation order. It drives the CPU fallback, the alive counts, and the offline
// shader-vs-reference proof (tools/fxsim_test). Change both together.
#include <cstdint>
#include <cmath>
#include <cstring>

namespace fx {

// ---- descriptor: float[64], fields mirror EQ's EmitterDefinition (see FX_API.md) ----------------------
enum : int {
	D_SHAPE = 0,        // 0 point, 1 sphere, 2 cylinder, 3 disk, 4 ring, 9 random ring
	D_SIZE_X = 1,       // radius (units)
	D_SIZE_Y = 2,       // height (cylinder, units)
	D_SIZE_Z = 3,       // fill 0..1 (0 = shell/edge, 1 = filled; ring/rand ring: radial jitter)
	D_OFF_X = 4, D_OFF_Y = 5, D_OFF_Z = 6,
	D_ARC0 = 7, D_ARC1 = 8,   // spawn arc in degrees (equal = full circle)
	D_RATE = 9,         // particles per second
	D_INITIAL = 10,     // one-shot burst at delay
	D_CAPACITY = 11,    // ring slots (0 = ceil(rate * lifetime) + 1)
	D_LIFE = 12,        // seconds
	D_LIFE_JIT = 13,    // 0..1 random shortening
	D_DELAY = 14,       // seconds before emission starts
	D_FADE_IN = 15, D_FADE_OUT = 16,  // seconds
	D_GROW = 17, D_SHRINK = 18,       // seconds of size ramp at birth / before death
	D_W0 = 19, D_W1 = 20, D_H0 = 21, D_H1 = 22,  // sprite size start/end (units; height 0 = width)
	D_SIZE_JIT = 23,    // 0..1 random size +-
	D_COL0 = 24,        // rgba start (24..27)
	D_COL1 = 28,        // rgba end (28..31)
	D_MAX_OP = 32,      // opacity multiplier (0 = 1)
	D_AXIAL = 33,       // vmin, vmax, accel (+z up)
	D_TRANS1 = 36,      // vmin, vmax, accel (x, screen right)
	D_TRANS2 = 39,      // vmin, vmax, accel (y, depth -> screen via tilt)
	D_RADIAL = 42,      // vmin, vmax, accel (outward from the axis)
	D_ORBITAL = 45,     // vmin, vmax, accel (degrees/s around the axis)
	D_GRAVITY = 48,     // units/s^2 down
	D_WIND_X = 49, D_WIND_Y = 50,     // units/s^2
	D_SPIN = 51, D_SPIN_JIT = 52,     // degrees/s, +- degrees/s
	D_RAND_ROT = 53,    // 1 = random start angle
	D_FRAMES = 54, D_FPS = 55,        // horizontal flipbook strip (GPU path)
	D_TEX = 56,         // rml_canvas_texture_load id, 0 = built-in soft dot
	D_BLEND = 57,       // 0 alpha, 1 additive
	D_FOLLOW = 58,      // Stage 1: particles always follow the anchor (stateless); kept for EQ parity
	D_SEED = 59,        // 0 = per-emitter random
	D_TILT = 60,        // screen y per unit of depth (y), default 0.35
	D_COL_JIT = 61,     // 0..1 brightness +-
	D_INTENSITY = 62,   // rgb multiplier (> 1 = HDR, feeds bloom), 0 = 1
	D_RESERVED = 63,
	D_COUNT = 64
};

static constexpr uint32_t kMaxCapacity = 65536;
static constexpr uint32_t kMaxBurstTotal = 16384;
static constexpr int kMaxBursts = 8;
static constexpr double kMaxDt = 0.100;     // clamp per tick (zone loads / hitches never jump the clock)

// HLSL: cbuffer FxCB : register(b1) in shaders/fx.hlsl (same order, 544 bytes)
struct alignas(16) FxCB
{
	float D[64];
	float S0[4];       // curFracAge, prevFracAge, stopAge, curInvRate
	float S1[4];       // prevInvRate, anchorX, anchorY, ppu
	float S2[4];       // vpW, vpH, depth01, 0
	uint32_t N0[4];    // C, curNMax, curSpan, curHas
	uint32_t N1[4];    // prevNMax, prevSpan, prevHas, seedMix
	uint32_t N2[4];    // burstCount, burstTotal, 0, 0
	float BA[8];       // burst ages
	uint32_t BN[8];    // burst counts
	uint32_t BO[8];    // burst first instance (relative to C)
	uint32_t BS[8];    // burst seeds
	float X[16];       // capsule: fx,fy,ux,uy | span,feather,enabled,0 | knots k0..k3 | k4..k6,0
};
static_assert(sizeof(FxCB) == 544, "FxCB must match shaders/fx.hlsl");

inline uint32_t pcg(uint32_t v)
{
	const uint32_t s = v * 747796405u + 2891336453u;
	const uint32_t w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
	return (w >> 22u) ^ w;
}
inline float U(uint32_t key, uint32_t s) { return (float)(pcg(key + s * 0x9E3779B9u) >> 8) * (1.0f / 16777216.0f); }
inline float lrp(float a, float b, float t) { return a + t * (b - a); }
inline float sat(float x) { return x < 0.0f ? 0.0f : (x > 1.0f ? 1.0f : x); }
inline float fmaxf_(float a, float b) { return a > b ? a : b; }

// Capsule half-width (fraction of span) at t along feet->crown; knots at t = 0,.2,.42,.70,.84,.94,1.08
inline float CapsuleHW(const float* X, float t)
{
	const float* k = X + 8;
	if (t < 0.20f) return lrp(k[0], k[1], sat(t / 0.20f));
	if (t < 0.42f) return lrp(k[1], k[2], (t - 0.20f) / 0.22f);
	if (t < 0.70f) return lrp(k[2], k[3], (t - 0.42f) / 0.28f);
	if (t < 0.84f) return lrp(k[3], k[4], (t - 0.70f) / 0.14f);
	if (t < 0.94f) return lrp(k[4], k[5], (t - 0.84f) / 0.10f);
	return lrp(k[5], k[6], sat((t - 0.94f) / 0.14f));
}

// Signed distance (px) outside the body capsule (< 0 = inside). Same shape as CombatFX BF.inside_excl:
// feet line is the bottom edge (t < 0 is outside), constant-width body, round cap above t = 1.08.
inline float CapsuleDist(const float* X, float px, float py)
{
	const float vx = px - X[0], vy = py - X[1];
	const float span = fmaxf_(X[4], 1.0f);
	const float along = vx * X[2] + vy * X[3];
	const float t = along / span;
	const float perp = std::fabs(-vx * X[3] + vy * X[2]);
	if (t > 1.08f)
	{
		const float cx = X[0] + X[2] * span * 1.08f, cy = X[1] + X[3] * span * 1.08f;
		const float dx = px - cx, dy = py - cy;
		return std::sqrt(dx * dx + dy * dy) - CapsuleHW(X, 1.08f) * span;
	}
	return fmaxf_(-along, perp - CapsuleHW(X, t) * span);
}

inline float CapsuleMask(const float* X, float px, float py)
{
	if (X[6] < 0.5f) return 1.0f;
	const float d = CapsuleDist(X, px, py);
	const float e = fmaxf_(X[5], 0.001f);
	const float t = sat(d / e);
	return t * t * (3.0f - 2.0f * t);
}

struct FxOut
{
	float cx, cy, hx, hy, rot, r, g, b, a, frame, age, life;
};

// Slot -> (age, key). Returns false for an empty slot. Mirrors FxAge() in fx.hlsl.
inline bool FxAge(const FxCB& c, uint32_t inst, float& age, uint32_t& key, float& life)
{
	const uint32_t C = c.N0[0];
	age = 0.0f; key = 0u; life = 0.0f;
	bool got = false;
	if (inst < C)
	{
		if (c.N0[3] != 0u)
		{
			const uint32_t d = ((c.N0[1] % C) + C - inst) % C;
			if (d <= c.N0[2]) { key = pcg(((c.N0[1] - d) * 2u) ^ c.N1[3]); age = c.S0[0] + (float)d * c.S0[3]; got = true; }
		}
		if (!got && c.N1[2] != 0u)
		{
			const uint32_t d = ((c.N1[0] % C) + C - inst) % C;
			if (d <= c.N1[1]) { key = pcg(((c.N1[0] - d) * 2u) ^ c.N1[3]); age = c.S0[1] + (float)d * c.S1[0]; got = true; }
		}
		if (!got || age < c.S0[2]) return false;
	}
	else
	{
		const uint32_t b = inst - C;
		for (uint32_t r = 0; r < 8u; ++r)
		{
			if (!got && r < c.N2[0])
			{
				const uint32_t o0 = c.BO[r], cnt = c.BN[r];
				if (b >= o0 && b < o0 + cnt) { key = pcg(((b - o0) * 2u + 1u) ^ c.BS[r]); age = c.BA[r]; got = true; }
			}
		}
		if (!got) return false;
	}
	life = c.D[D_LIFE] * (1.0f - sat(c.D[D_LIFE_JIT]) * U(key, 1u));
	return age >= 0.0f && age < life;
}

inline bool FxEval(const FxCB& c, uint32_t inst, FxOut& o)
{
	const float* D = c.D;
	float age, L; uint32_t key;
	if (!FxAge(c, inst, age, key, L))
		return false;
	const float t = age / L;
	const float DEG = 0.0174532925f;
	const float u2 = U(key, 2u), u3 = U(key, 3u), u4 = U(key, 4u);
	const float a0 = D[D_ARC0] * DEG, a1 = D[D_ARC1] * DEG;
	const float phi = (a1 != a0) ? (a0 + (a1 - a0) * u2) : (6.2831853f * u2);
	const int shape = (int)D[D_SHAPE];
	const float R = D[D_SIZE_X], H = D[D_SIZE_Y], fill = sat(D[D_SIZE_Z]);
	float r0 = 0.0f, z0 = 0.0f;
	if (shape == 1)
	{
		const float cz = 2.0f * u4 - 1.0f;
		const float sz = std::sqrt(fmaxf_(0.0f, 1.0f - cz * cz));
		const float rr = R * (1.0f - fill * u3);
		z0 = rr * cz; r0 = rr * sz;
	}
	else if (shape == 2) { r0 = R * (1.0f - fill * u3); z0 = H * u4; }
	else if (shape == 3) { r0 = R * std::sqrt(1.0f - fill * u3); }
	else if (shape == 4 || shape == 9)
	{
		const float j = (shape == 9 && fill <= 0.0f) ? 0.5f : fill;
		r0 = R * (1.0f + j * (u3 - 0.5f));
	}
	const float va = lrp(D[D_AXIAL], D[D_AXIAL + 1], U(key, 5u));
	const float vx = lrp(D[D_TRANS1], D[D_TRANS1 + 1], U(key, 6u));
	const float vy = lrp(D[D_TRANS2], D[D_TRANS2 + 1], U(key, 7u));
	const float vr = lrp(D[D_RADIAL], D[D_RADIAL + 1], U(key, 8u));
	const float vo = lrp(D[D_ORBITAL], D[D_ORBITAL + 1], U(key, 9u)) * DEG;
	const float h2 = 0.5f * age * age;
	const float rr = r0 + vr * age + D[D_RADIAL + 2] * h2;
	const float th = phi + vo * age + D[D_ORBITAL + 2] * DEG * h2;
	const float x = rr * std::cos(th) + vx * age + (D[D_TRANS1 + 2] + D[D_WIND_X]) * h2 + D[D_OFF_X];
	const float y = rr * std::sin(th) + vy * age + (D[D_TRANS2 + 2] + D[D_WIND_Y]) * h2 + D[D_OFF_Y];
	const float z = z0 + va * age + (D[D_AXIAL + 2] - D[D_GRAVITY]) * h2 + D[D_OFF_Z];
	const float ppu = c.S1[3];
	o.cx = c.S1[1] + x * ppu;
	o.cy = c.S1[2] - (z + y * D[D_TILT]) * ppu;
	const float sj = 1.0f + D[D_SIZE_JIT] * (2.0f * U(key, 10u) - 1.0f);
	const float gro = D[D_GROW] > 0.0f ? sat(age / D[D_GROW]) : 1.0f;
	const float shr = D[D_SHRINK] > 0.0f ? sat((L - age) / D[D_SHRINK]) : 1.0f;
	const float k = sj * gro * shr * ppu * 0.5f;
	const float wv = lrp(D[D_W0], D[D_W1], t);
	const float hv = (D[D_H0] + D[D_H1] > 0.0f) ? lrp(D[D_H0], D[D_H1], t) : wv;
	o.hx = wv * k; o.hy = hv * k;
	o.rot = (D[D_RAND_ROT] > 0.5f ? 6.2831853f * U(key, 11u) : 0.0f)
		+ (D[D_SPIN] + D[D_SPIN_JIT] * (2.0f * U(key, 12u) - 1.0f)) * DEG * age;
	const float cj = (1.0f + D[D_COL_JIT] * (2.0f * U(key, 13u) - 1.0f)) * D[D_INTENSITY];
	o.r = lrp(D[D_COL0 + 0], D[D_COL1 + 0], t) * cj;
	o.g = lrp(D[D_COL0 + 1], D[D_COL1 + 1], t) * cj;
	o.b = lrp(D[D_COL0 + 2], D[D_COL1 + 2], t) * cj;
	const float fi = D[D_FADE_IN] > 0.0f ? sat(age / D[D_FADE_IN]) : 1.0f;
	const float fo = D[D_FADE_OUT] > 0.0f ? sat((L - age) / D[D_FADE_OUT]) : 1.0f;
	o.a = lrp(D[D_COL0 + 3], D[D_COL1 + 3], t) * fi * fo * D[D_MAX_OP];
	const float fr = std::floor(age * D[D_FPS]);
	o.frame = fr - D[D_FRAMES] * std::floor(fr / D[D_FRAMES]);
	o.age = age; o.life = L;
	return true;
}

// ---- emitter clock / segments / bursts (CPU side; builds the FxCB each frame) -------------------------
inline void DefaultDesc(float* D)
{
	std::memset(D, 0, sizeof(float) * D_COUNT);
	D[D_LIFE] = 1.0f; D[D_W0] = 4.0f; D[D_W1] = 4.0f;
	D[D_COL0 + 0] = D[D_COL0 + 1] = D[D_COL0 + 2] = D[D_COL0 + 3] = 1.0f;
	D[D_COL1 + 0] = D[D_COL1 + 1] = D[D_COL1 + 2] = 1.0f;
	D[D_MAX_OP] = 1.0f; D[D_FRAMES] = 1.0f; D[D_FOLLOW] = 1.0f; D[D_TILT] = 0.35f; D[D_INTENSITY] = 1.0f;
}

inline float Clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

inline void SanitizeDesc(float* D)
{
	for (int i = 0; i < D_COUNT; ++i)
		if (!std::isfinite(D[i])) D[i] = 0.0f;
	if (D[D_LIFE] <= 0.0f) D[D_LIFE] = 1.0f;
	D[D_LIFE] = Clampf(D[D_LIFE], 0.01f, 600.0f);
	D[D_RATE] = Clampf(D[D_RATE], 0.0f, 200000.0f);
	D[D_CAPACITY] = std::floor(Clampf(D[D_CAPACITY], 0.0f, (float)kMaxCapacity));
	D[D_INITIAL] = std::floor(Clampf(D[D_INITIAL], 0.0f, (float)kMaxBurstTotal));
	D[D_DELAY] = Clampf(D[D_DELAY], 0.0f, 600.0f);
	D[D_FRAMES] = std::floor(Clampf(D[D_FRAMES], 1.0f, 256.0f));
	if (D[D_MAX_OP] <= 0.0f) D[D_MAX_OP] = 1.0f;
	if (D[D_INTENSITY] <= 0.0f) D[D_INTENSITY] = 1.0f;
	D[D_LIFE_JIT] = Clampf(D[D_LIFE_JIT], 0.0f, 0.95f);
	D[D_FOLLOW] = 1.0f;
}

struct FxSeg { double t0 = 0.0; double rate = 0.0; int64_t n0 = 0; int64_t nEnd = -1; bool valid = false; bool closed = false; };
struct FxBurst { double t = 0.0; uint32_t count = 0; uint32_t seed = 0; };

class FxEmitterCore
{
public:
	float D[D_COUNT]{};
	double T = 0.0;
	uint32_t C = 1;
	FxSeg cur, prev;
	double stopT = 1e300;
	bool killed = false;
	FxBurst bursts[kMaxBursts]{};
	int nb = 0;
	uint32_t serial = 0;
	uint32_t seedMix = 0;
	float ax = 0.0f, ay = 0.0f, ppu = 1.0f, depth = 0.0f;
	uint32_t handle = 0;

	static void Load(float* out, const float* d, int n)
	{
		DefaultDesc(out);
		if (d && n > 0)
			std::memcpy(out, d, sizeof(float) * (size_t)(n < D_COUNT ? n : D_COUNT));
		SanitizeDesc(out);
	}

	void Init(const float* d, int n, uint32_t h)
	{
		handle = h;
		Load(D, d, n);
		T = 0.0; stopT = 1e300; killed = false; nb = 0; serial = 0;
		Reseed();
		C = AutoCapacity();
		cur = FxSeg{}; prev = FxSeg{};
		cur.t0 = D[D_DELAY]; cur.rate = D[D_RATE]; cur.n0 = 0; cur.valid = cur.rate > 0.0;
		if (D[D_INITIAL] >= 1.0f)
			AddBurst((uint32_t)D[D_INITIAL], D[D_DELAY]);
	}

	// live change: no particle reset (rate changes open a new segment; old particles finish their lives)
	void Update(const float* d, int n)
	{
		float nd[D_COUNT];
		Load(nd, d, n);
		const bool capChange = nd[D_CAPACITY] != D[D_CAPACITY] && nd[D_CAPACITY] > 0.0f;
		const bool rateChange = nd[D_RATE] != D[D_RATE];
		const bool seedChange = nd[D_SEED] != D[D_SEED];
		std::memcpy(D, nd, sizeof(D));
		if (seedChange) Reseed();
		if (capChange)
		{
			C = AutoCapacity();
			cur = FxSeg{}; prev = FxSeg{};
			cur.t0 = T; cur.rate = D[D_RATE]; cur.valid = cur.rate > 0.0;
			return;
		}
		if (rateChange && !Stopped())
		{
			const int64_t nMax = NMax(cur, T);
			prev = cur;
			prev.nEnd = nMax; prev.closed = true;
			prev.valid = cur.valid && nMax >= cur.n0;
			FxSeg s; s.t0 = T; s.rate = D[D_RATE]; s.n0 = nMax + 1; s.valid = s.rate > 0.0;
			cur = s;
		}
	}

	void Advance(double dt)
	{
		if (!(dt > 0.0)) return;
		if (dt > kMaxDt) dt = kMaxDt;
		T += dt;
		// drop finished bursts (instance offsets shift; keys are per-burst so particles stay identical)
		int w = 0;
		for (int i = 0; i < nb; ++i)
			if (T - bursts[i].t <= (double)D[D_LIFE] + 0.05) bursts[w++] = bursts[i];
		nb = w;
	}

	int Burst(uint32_t count) { return AddBurst(count, T); }

	void Stop(bool fadeOut)
	{
		if (fadeOut) { if (stopT > T) stopT = T; }
		else killed = true;
	}

	bool Stopped() const { return stopT < 1e299; }

	// anything that can still be visible (drives paint gating and drawing)
	bool Active() const
	{
		if (killed) return false;
		const double life = (double)D[D_LIFE] + 0.05;
		for (int i = 0; i < nb; ++i)
			if (T - bursts[i].t <= life) return true;
		if (cur.valid)
		{
			if (!Stopped()) return true;
			if (T - stopT <= life) return true;
		}
		if (prev.valid && T - cur.t0 <= life) return true;
		return false;
	}

	uint32_t BurstTotal() const { uint32_t n = 0; for (int i = 0; i < nb; ++i) n += bursts[i].count; return n; }
	uint32_t Instances() const { return killed ? 0u : C + BurstTotal(); }

	void Build(FxCB& c, const float* capsuleX16) const
	{
		std::memset(&c, 0, sizeof(c));
		std::memcpy(c.D, D, sizeof(D));
		c.N0[0] = C;
		c.N1[3] = seedMix;
		const double Te = T < stopT ? T : stopT;
		const int64_t cm = NMax(cur, Te);
		if (cur.valid && cm >= cur.n0)
		{
			c.N0[1] = (uint32_t)cm; c.N0[2] = (uint32_t)(cm - cur.n0); c.N0[3] = 1u;
			c.S0[0] = (float)((T - cur.t0) - (double)(cm - cur.n0) / cur.rate);
			c.S0[3] = (float)(1.0 / cur.rate);
		}
		if (prev.valid && prev.nEnd >= prev.n0)
		{
			c.N1[0] = (uint32_t)prev.nEnd; c.N1[1] = (uint32_t)(prev.nEnd - prev.n0); c.N1[2] = 1u;
			c.S0[1] = (float)((T - prev.t0) - (double)(prev.nEnd - prev.n0) / prev.rate);
			c.S1[0] = (float)(1.0 / prev.rate);
		}
		c.S0[2] = Stopped() ? (float)(T - stopT) : -1e30f;
		c.S1[1] = ax; c.S1[2] = ay; c.S1[3] = ppu;
		c.S2[2] = depth;
		uint32_t off = 0;
		c.N2[0] = (uint32_t)nb;
		for (int i = 0; i < nb; ++i)
		{
			c.BA[i] = (float)(T - bursts[i].t);
			c.BN[i] = bursts[i].count;
			c.BO[i] = off;
			c.BS[i] = bursts[i].seed;
			off += bursts[i].count;
		}
		c.N2[1] = off;
		if (capsuleX16) std::memcpy(c.X, capsuleX16, sizeof(c.X));
	}

	static uint32_t CountAlive(const FxCB& c, uint32_t instances)
	{
		uint32_t n = 0; float age, life; uint32_t key;
		for (uint32_t i = 0; i < instances; ++i)
			if (FxAge(c, i, age, key, life)) ++n;
		return n;
	}

private:
	static int64_t NMax(const FxSeg& s, double Te)
	{
		if (!s.valid || Te < s.t0 || s.rate <= 0.0) return s.n0 - 1;
		return s.n0 + (int64_t)std::floor((Te - s.t0) * s.rate);
	}
	uint32_t AutoCapacity() const
	{
		double c = D[D_CAPACITY] > 0.0f ? (double)D[D_CAPACITY] : std::ceil((double)D[D_RATE] * (double)D[D_LIFE]) + 1.0;
		if (c < 1.0) c = 1.0;
		if (c > (double)kMaxCapacity) c = (double)kMaxCapacity;
		return (uint32_t)c;
	}
	void Reseed()
	{
		const uint32_t s = (uint32_t)(int64_t)D[D_SEED];
		seedMix = s != 0u ? pcg(s) : pcg(handle * 2654435761u + 0x68E31DA4u);
	}
	int AddBurst(uint32_t count, double t)
	{
		if (count == 0u || killed) return 0;
		uint32_t total = BurstTotal();
		if (nb == kMaxBursts) { total -= bursts[0].count; for (int i = 1; i < nb; ++i) bursts[i - 1] = bursts[i]; --nb; }
		if (total >= kMaxBurstTotal) return 0;
		if (count > kMaxBurstTotal - total) count = kMaxBurstTotal - total;
		FxBurst b; b.t = t; b.count = count; b.seed = pcg(seedMix ^ ((++serial) * 0x85EBCA6Bu));
		bursts[nb++] = b;
		return (int)count;
	}
};

// rml_fx_exclude params -> FxCB.X (fx, fy, ux, uy, span [, 7 knots] [, feather px])
inline void BuildCapsule(float* X, const float* p, int n)
{
	std::memset(X, 0, sizeof(float) * 16);
	if (!p || n < 5) return;
	float ux = p[2], uy = p[3];
	const float l = std::sqrt(ux * ux + uy * uy);
	if (!(l > 1e-6f) || !(p[4] > 1.0f)) return;
	ux /= l; uy /= l;
	static const float kDef[7] = { 0.20f, 0.18f, 0.24f, 0.27f, 0.18f, 0.17f, 0.17f };  // CombatFX BF.excl_hw (w + 0.02)
	X[0] = p[0]; X[1] = p[1]; X[2] = ux; X[3] = uy; X[4] = p[4];
	X[5] = n >= 13 ? Clampf(p[12], 0.5f, 256.0f) : 6.0f;
	X[6] = 1.0f;
	for (int i = 0; i < 7; ++i) X[8 + i] = (n >= 12) ? Clampf(p[5 + i], 0.0f, 4.0f) : kDef[i];
}

} // namespace fx
