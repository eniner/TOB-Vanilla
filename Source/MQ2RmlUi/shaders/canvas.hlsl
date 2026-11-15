cbuffer CB : register(b0)
{
	float2 vpSize;
	float2 origin;
	float4 slot;
	float2 texel;
	float2 blurDir;
	float strength;
	float time;
	float energy;
	float beat;
	float bgStyle;
	float3 _pad;
};

struct VSIn
{
	float2 pos : POSITION;
	float4 col : COLOR0;
};

struct VSOut
{
	float4 pos : SV_POSITION;
	float4 col : COLOR0;
};

struct VSSpriteIn
{
	float2 corner : POSITION;
	float4 xyrr : TEXCOORD0;
	float4 col : COLOR0;
};

struct VSSpriteOut
{
	float4 pos : SV_POSITION;
	float4 col : COLOR0;
	float2 corner : TEXCOORD0;
};

VSOut vs_main(VSIn i)
{
	VSOut o;
	float2 p = i.pos - origin;
	float2 ndc = float2(p.x / vpSize.x * 2.0 - 1.0, 1.0 - p.y / vpSize.y * 2.0);
	o.pos = float4(ndc, 0.0, 1.0);
	o.col = i.col;
	return o;
}

VSSpriteOut vs_sprite(VSSpriteIn i)
{
	VSSpriteOut o;
	float2 p = i.xyrr.xy + i.corner * i.xyrr.zw - origin;
	float2 ndc = float2(p.x / vpSize.x * 2.0 - 1.0, 1.0 - p.y / vpSize.y * 2.0);
	o.pos = float4(ndc, 0.0, 1.0);
	o.col = i.col;
	o.corner = i.corner;
	return o;
}

float4 ps_color(VSOut i) : SV_Target
{
	return i.col;
}

Texture2D tex : register(t0);
SamplerState samp : register(s0);

float2 DestUV(float4 spos)
{
	if (slot.z > 0.5)
		return (spos.xy - slot.xy) / slot.zw;
	return spos.xy * texel;
}

float4 ps_blur(VSOut i) : SV_Target
{
	float2 uv = DestUV(i.pos);
	float2 step = blurDir * texel;
	float4 c = tex.Sample(samp, uv) * 0.227027;
	c += tex.Sample(samp, uv + step) * 0.1945946;
	c += tex.Sample(samp, uv - step) * 0.1945946;
	c += tex.Sample(samp, uv + step * 2) * 0.1216216;
	c += tex.Sample(samp, uv - step * 2) * 0.1216216;
	c += tex.Sample(samp, uv + step * 3) * 0.054054;
	c += tex.Sample(samp, uv - step * 3) * 0.054054;
	c += tex.Sample(samp, uv + step * 4) * 0.016216;
	c += tex.Sample(samp, uv - step * 4) * 0.016216;
	return c;
}

float4 ps_tex(VSOut i) : SV_Target
{
	float2 uv = DestUV(i.pos);
	return tex.Sample(samp, uv) * strength;
}

float4 ps_downsample(VSOut i) : SV_Target
{
	float2 uv = DestUV(i.pos);
	float2 t = texel * 0.5;
	float4 c = tex.Sample(samp, uv);
	c += tex.Sample(samp, uv + float2(t.x, t.y));
	c += tex.Sample(samp, uv + float2(-t.x, t.y));
	c += tex.Sample(samp, uv + float2(t.x, -t.y));
	c += tex.Sample(samp, uv + float2(-t.x, -t.y));
	c *= 0.2;
	float lum = dot(c.rgb, float3(0.2126, 0.7152, 0.0722));
	float boost = 0.50 + saturate(lum - 0.10) * 1.5;
	return float4(c.rgb * boost, c.a);
}

float hash21(float2 p)
{
	float3 p3 = frac(float3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return frac((p3.x + p3.y) * p3.z);
}

float4 ps_bg(VSOut i) : SV_Target
{
	float2 uv = DestUV(i.pos);
	float2 p = uv * 2.0 - 1.0;
	p.x *= vpSize.x / max(vpSize.y, 1.0);
	float t = time;

	float3 col = float3(0.015, 0.018, 0.045);
	if (bgStyle > 1.5)
	{
		col = lerp(float3(0.02, 0.015, 0.04), float3(0.04, 0.02, 0.01), uv.y);
		col += float3(0.05, 0.02, 0.08) * (0.5 + 0.5 * sin(uv.x * 3.0 + t * 0.2)) * (0.25 + energy * 0.4);
	}
	else
	{
		float n = 0.0;
		n += 0.55 * sin(uv.x * 5.5 + t * 0.17) * sin(uv.y * 3.8 - t * 0.11);
		n += 0.35 * sin(uv.x * 11.0 - uv.y * 7.0 + t * 0.23);
		n += 0.18 * sin((uv.x + uv.y) * 17.0 - t * 0.4);
		float3 nebA = float3(0.35, 0.08, 0.55);
		float3 nebB = float3(0.05, 0.35, 0.75);
		float3 nebC = float3(0.70, 0.18, 0.08);
		col += nebA * saturate(n * 0.55 + 0.12) * (0.35 + energy * 0.55);
		col += nebB * saturate(-n * 0.45 + 0.18) * 0.55;
		col += nebC * saturate(n * n) * (0.15 + beat * 0.35);
	}

	float2 gv = uv * float2(170.0, 130.0);
	float2 id = floor(gv);
	float2 f = frac(gv) - 0.5;
	float h = hash21(id);
	float star = saturate(0.010 / (length(f) + 0.002)) * step(0.72, h);
	star *= 0.40 + 0.60 * sin(t * (1.5 + h * 4.0) + h * 20.0);
	col += star * lerp(float3(0.7, 0.85, 1.0), float3(1.0, 0.8, 0.55), h);

	// second sparser big-star layer
	float2 gv2 = uv * float2(55.0, 42.0);
	float2 id2 = floor(gv2);
	float2 f2 = frac(gv2) - 0.5;
	float h2 = hash21(id2 + 17.0);
	float star2 = saturate(0.018 / (length(f2) + 0.002)) * step(0.93, h2);
	col += star2 * float3(0.95, 0.92, 1.0) * 0.85;

	// milky band across the upper sky
	float bandY = uv.y - (0.26 + 0.07 * sin(uv.x * 3.1 + 0.4));
	float band = exp(-bandY * bandY * 26.0);
	col += float3(0.42, 0.38, 0.95) * band * 0.22;
	col += float3(0.85, 0.55, 1.0) * band * band * 0.16;
	col += float3(0.15, 0.35, 0.95) * saturate(1.0 - uv.y * 1.15) * 0.12;

	float vig = saturate(1.18 - dot(p * 0.52, p * 0.52));
	col *= vig;
	return float4(col, 1.0);
}

float4 ps_sprite(VSSpriteOut i) : SV_Target
{
	float d = length(i.corner);
	float a = saturate(1.0 - d);
	a = a * a * (0.35 + 0.65 * a);
	float3 rgb = i.col.rgb * a;
	return float4(rgb, i.col.a * a);
}

float4 ps_sprite_sq(VSSpriteOut i) : SV_Target
{
	float m = max(abs(i.corner.x), abs(i.corner.y));
	float a = saturate((1.0 - m) * 2.4);
	a = a * a;
	float3 rgb = i.col.rgb * a;
	return float4(rgb, i.col.a * a);
}

float3 TonemapACES(float3 x)
{
	const float a = 2.51;
	const float b = 0.03;
	const float c = 2.43;
	const float d = 0.59;
	const float e = 0.14;
	return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

float4 ps_composite(VSOut i) : SV_Target
{
	float2 uv = DestUV(i.pos);
	float4 s = tex.Sample(samp, uv);
	float3 c = max(s.rgb, 0.0) * strength;
	c = min(c, 1024.0);
	c = TonemapACES(c);
	float a = saturate(s.a);
	return float4(c, a);
}

struct VSSpriteExIn
{
	float2 corner : POSITION;
	float4 pos_scale : TEXCOORD0;
	float4 col : COLOR0;
	float4 extra : TEXCOORD1;
};

struct VSSpriteExOut
{
	float4 pos : SV_POSITION;
	float4 col : COLOR0;
	float2 uv : TEXCOORD0;
};

VSSpriteExOut vs_sprite_ex(VSSpriteExIn i)
{
	VSSpriteExOut o;
	float ang = i.extra.x;
	float ca = cos(ang);
	float sa = sin(ang);
	float2 local = i.corner * i.pos_scale.zw;
	float2 rot = float2(ca * local.x - sa * local.y, sa * local.x + ca * local.y);
	float2 p = i.pos_scale.xy + rot - origin;
	float2 ndc = float2(p.x / vpSize.x * 2.0 - 1.0, 1.0 - p.y / vpSize.y * 2.0);
	o.pos = float4(ndc, 0.0, 1.0);
	o.col = i.col;
	o.uv = i.corner * 0.5 + 0.5;
	return o;
}

float4 ps_sprite_tex(VSSpriteExOut i) : SV_Target
{
	float4 t = tex.Sample(samp, i.uv);
	float a = t.a * i.col.a;
	float3 rgb = t.rgb * i.col.rgb;
	return float4(rgb * a, a);
}
