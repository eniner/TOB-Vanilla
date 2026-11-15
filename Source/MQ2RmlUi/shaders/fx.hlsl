// MQ2RmlUi Stage 1 GPU particles (2026-11-12). Stateless formula emitter: each particle is a pure function
// of (FxCB, instance id). FxAge/FxEval are the twins of src/FxSim.h (same hash, same op order).
// Entry points: vs_fx (vs_5_0), ps_fx (ps_5_0); cs_fx_eval (cs_5_0) is used only by tools/fxsim_test.

cbuffer FxCB : register(b1)
{
	float4 D[16];
	float4 S0;   // curFracAge, prevFracAge, stopAge, curInvRate
	float4 S1;   // prevInvRate, anchorX, anchorY, ppu
	float4 S2;   // vpW, vpH, depth01, 0
	uint4 N0;    // C, curNMax, curSpan, curHas
	uint4 N1;    // prevNMax, prevSpan, prevHas, seedMix
	uint4 N2;    // burstCount, burstTotal
	float4 BA[2];
	uint4 BN[2];
	uint4 BO[2];
	uint4 BS[2];
	float4 X[4]; // capsule: fx,fy,ux,uy | span,feather,enabled,0 | k0..k3 | k4..k6,0
};

#define DS(i) D[(i) >> 2][(i) & 3]
#define XS(i) X[(i) >> 2][(i) & 3]

uint pcg(uint v)
{
	uint s = v * 747796405u + 2891336453u;
	uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
	return (w >> 22u) ^ w;
}
float U(uint key, uint s) { return (float)(pcg(key + s * 0x9E3779B9u) >> 8) * (1.0 / 16777216.0); }
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
	float d = CapsuleDist(p);
	float t = saturate(d / max(X[1].y, 0.001));
	return t * t * (3.0 - 2.0 * t);
}

struct FxP
{
	bool alive;
	float2 c;
	float2 hs;
	float rot;
	float4 col;
	float frame;
	float age;
};

bool FxAge(uint inst, out float age, out uint key, out float life)
{
	uint C = N0.x;
	age = 0.0; key = 0u; life = 0.0;
	bool got = false;
	if (inst < C)
	{
		if (N0.w != 0u)
		{
			uint d = ((N0.y % C) + C - inst) % C;
			if (d <= N0.z) { key = pcg(((N0.y - d) * 2u) ^ N1.w); age = S0.x + (float)d * S0.w; got = true; }
		}
		if (!got && N1.z != 0u)
		{
			uint d = ((N1.x % C) + C - inst) % C;
			if (d <= N1.y) { key = pcg(((N1.x - d) * 2u) ^ N1.w); age = S0.y + (float)d * S1.x; got = true; }
		}
		if (!got || age < S0.z) return false;
	}
	else
	{
		uint b = inst - C;
		[unroll] for (uint r = 0; r < 8u; ++r)
		{
			if (!got && r < N2.x)
			{
				uint o0 = BO[r >> 2][r & 3];
				uint cnt = BN[r >> 2][r & 3];
				if (b >= o0 && b < o0 + cnt) { key = pcg(((b - o0) * 2u + 1u) ^ BS[r >> 2][r & 3]); age = BA[r >> 2][r & 3]; got = true; }
			}
		}
		if (!got) return false;
	}
	life = DS(12) * (1.0 - saturate(DS(13)) * U(key, 1u));
	return age >= 0.0 && age < life;
}

FxP FxEval(uint inst)
{
	FxP o = (FxP)0;
	float age, L; uint key;
	if (!FxAge(inst, age, key, L))
		return o;
	float t = age / L;
	const float DEG = 0.0174532925;
	float u2 = U(key, 2u), u3 = U(key, 3u), u4 = U(key, 4u);
	float a0 = DS(7) * DEG, a1 = DS(8) * DEG;
	float phi = (a1 != a0) ? (a0 + (a1 - a0) * u2) : (6.2831853 * u2);
	int shape = (int)DS(0);
	float R = DS(1), H = DS(2), fill = saturate(DS(3));
	float r0 = 0.0, z0 = 0.0;
	if (shape == 1)
	{
		float cz = 2.0 * u4 - 1.0;
		float sz = sqrt(max(0.0, 1.0 - cz * cz));
		float rr0 = R * (1.0 - fill * u3);
		z0 = rr0 * cz; r0 = rr0 * sz;
	}
	else if (shape == 2) { r0 = R * (1.0 - fill * u3); z0 = H * u4; }
	else if (shape == 3) { r0 = R * sqrt(1.0 - fill * u3); }
	else if (shape == 4 || shape == 9)
	{
		float j = (shape == 9 && fill <= 0.0) ? 0.5 : fill;
		r0 = R * (1.0 + j * (u3 - 0.5));
	}
	float va = lrp(DS(33), DS(34), U(key, 5u));
	float vx = lrp(DS(36), DS(37), U(key, 6u));
	float vy = lrp(DS(39), DS(40), U(key, 7u));
	float vr = lrp(DS(42), DS(43), U(key, 8u));
	float vo = lrp(DS(45), DS(46), U(key, 9u)) * DEG;
	float h2 = 0.5 * age * age;
	float rr = r0 + vr * age + DS(44) * h2;
	float th = phi + vo * age + DS(47) * DEG * h2;
	float x = rr * cos(th) + vx * age + (DS(38) + DS(49)) * h2 + DS(4);
	float y = rr * sin(th) + vy * age + (DS(41) + DS(50)) * h2 + DS(5);
	float z = z0 + va * age + (DS(35) - DS(48)) * h2 + DS(6);
	float ppu = S1.w;
	o.c = float2(S1.y + x * ppu, S1.z - (z + y * DS(60)) * ppu);
	float sj = 1.0 + DS(23) * (2.0 * U(key, 10u) - 1.0);
	float gro = DS(17) > 0.0 ? saturate(age / DS(17)) : 1.0;
	float shr = DS(18) > 0.0 ? saturate((L - age) / DS(18)) : 1.0;
	float k = sj * gro * shr * ppu * 0.5;
	float wv = lrp(DS(19), DS(20), t);
	float hv = (DS(21) + DS(22) > 0.0) ? lrp(DS(21), DS(22), t) : wv;
	o.hs = float2(wv * k, hv * k);
	o.rot = (DS(53) > 0.5 ? 6.2831853 * U(key, 11u) : 0.0) + (DS(51) + DS(52) * (2.0 * U(key, 12u) - 1.0)) * DEG * age;
	float cj = (1.0 + DS(61) * (2.0 * U(key, 13u) - 1.0)) * DS(62);
	o.col.r = lrp(DS(24), DS(28), t) * cj;
	o.col.g = lrp(DS(25), DS(29), t) * cj;
	o.col.b = lrp(DS(26), DS(30), t) * cj;
	float fi = DS(15) > 0.0 ? saturate(age / DS(15)) : 1.0;
	float fo = DS(16) > 0.0 ? saturate((L - age) / DS(16)) : 1.0;
	o.col.a = lrp(DS(27), DS(31), t) * fi * fo * DS(32);
	float fr = floor(age * DS(55));
	o.frame = fr - DS(54) * floor(fr / DS(54));
	o.age = age;
	o.alive = true;
	return o;
}

static const float2 kCorner[6] = { float2(-1, -1), float2(1, -1), float2(1, 1), float2(-1, -1), float2(1, 1), float2(-1, 1) };

struct FxVSOut
{
	float4 pos : SV_POSITION;
	float4 col : COLOR0;
	float2 uv : TEXCOORD0;
};

FxVSOut vs_fx(uint vid : SV_VertexID, uint iid : SV_InstanceID)
{
	FxVSOut o;
	FxP p = FxEval(iid);
	if (!p.alive || p.col.a <= 0.0005 || (p.hs.x <= 0.0 && p.hs.y <= 0.0))
	{
		o.pos = float4(-2.0, -2.0, 0.0, 1.0);   // all 6 corners equal -> zero-area, rasterizer drops it
		o.col = 0;
		o.uv = 0;
		return o;
	}
	float2 cr = kCorner[vid % 6u];
	float2 l = cr * p.hs;
	float cs = cos(p.rot), sn = sin(p.rot);
	float2 q = p.c + float2(cs * l.x - sn * l.y, sn * l.x + cs * l.y);
	o.pos = float4(q.x / S2.x * 2.0 - 1.0, 1.0 - q.y / S2.y * 2.0, 0.0, 1.0);
	o.col = p.col;
	float2 uv = cr * 0.5 + 0.5;
	o.uv = float2((p.frame + uv.x) / DS(54), uv.y);
	return o;
}

Texture2D fxTex : register(t0);
SamplerState fxSamp : register(s0);

// premultiplied out; body capsule mask per pixel (SV_Position = canvas-local px in the scene RT)
float4 ps_fx(FxVSOut i) : SV_Target
{
	float4 t = fxTex.Sample(fxSamp, i.uv);
	float m = CapsuleMask(i.pos.xy);
	float a = t.a * i.col.a * m;
	return float4(t.rgb * i.col.rgb * a, a);
}

// Stage 3: bloom composite for a canvas with a body capsule. ps_fx masks the particles, but bloom runs
// afterwards and would spread their light back onto the body; this pass adds the bloom chain to the scene
// with the same capsule mask (S2 = sceneW, sceneH, 0, strength; X = capsule). Same VS as the blits (vs_main).
float4 ps_bloom_mask(float4 pos : SV_POSITION, float4 col : COLOR0) : SV_Target
{
	float2 uv = pos.xy / max(S2.xy, float2(1.0, 1.0));
	return fxTex.Sample(fxSamp, uv) * (S2.w * CapsuleMask(pos.xy));
}

// ---- proof only (tools/fxsim_test): evaluate every instance, same FxEval as vs_fx ----
struct EvalOut { float4 a; float4 b; float4 c; };   // (alive,cx,cy,hx) (hy,rot,r,g) (b,a,frame,age)
RWStructuredBuffer<EvalOut> gEval : register(u0);
[numthreads(64, 1, 1)]
void cs_fx_eval(uint3 id : SV_DispatchThreadID)
{
	FxP p = FxEval(id.x);
	EvalOut e;
	e.a = float4(p.alive ? 1.0 : 0.0, p.c.x, p.c.y, p.hs.x);
	e.b = float4(p.hs.y, p.rot, p.col.r, p.col.g);
	e.c = float4(p.col.b, p.col.a, p.frame, p.age);
	gEval[id.x] = e;
}

// capsule mask probe for the proof: one thread per pixel of a W x H grid (W in S2.x)
RWStructuredBuffer<float> gMask : register(u1);
[numthreads(64, 1, 1)]
void cs_fx_mask(uint3 id : SV_DispatchThreadID)
{
	uint w = (uint)S2.x;
	float2 p = float2((float)(id.x % w) + 0.5, (float)(id.x / w) + 0.5);
	gMask[id.x] = CapsuleMask(p);
}
