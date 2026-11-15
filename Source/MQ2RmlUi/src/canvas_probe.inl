// GPU readback probe (measurement only; does not change draw results).
#include <cstdarg>
#include <dxgi.h>

// Implemented in EqIconAtlas.cpp (STB_IMAGE_WRITE_IMPLEMENTATION + STBI_WRITE_NO_STDIO).
extern "C" unsigned char* stbi_write_png_to_mem(const unsigned char* pixels, int stride_bytes, int x, int y, int n, int* out_len);

static volatile long g_probeReq = 0;
static bool g_autoProbed = false;
static char g_paintWin[80] = {};
static ID3D11Texture2D* g_paintTex = nullptr;
static ID3D11RenderTargetView* g_paintRtv = nullptr;
static int g_paintW = 0, g_paintH = 0;
static char g_elemInfo[800] = {};

void CanvasRenderer::RequestProbe()
{
	InterlockedExchange(&g_probeReq, 1);
}

void CanvasRenderer::SetPaintTarget(const char* win, void* tex, void* rtv, int w, int h)
{
	snprintf(g_paintWin, sizeof(g_paintWin), "%s", win ? win : "");
	g_paintTex = static_cast<ID3D11Texture2D*>(tex);
	g_paintRtv = static_cast<ID3D11RenderTargetView*>(rtv);
	g_paintW = w;
	g_paintH = h;
}

void CanvasRenderer::SetProbeElementInfo(const char* info)
{
	snprintf(g_elemInfo, sizeof(g_elemInfo), "%s", info ? info : "");
}

static void ProbeAppendLog(const char* line)
{
	if (!line || !line[0])
		return;
	char dir[MAX_PATH];
	char path[MAX_PATH];
	snprintf(dir, sizeof(dir), "%s\\Logs", mq::gPathMQRoot);
	CreateDirectoryA(dir, nullptr);
	snprintf(path, sizeof(path), "%s\\rmlui_canvas.log", dir);
	FILE* f = nullptr;
	if (fopen_s(&f, path, "a") != 0 || !f)
		return;
	SYSTEMTIME st{};
	GetLocalTime(&st);
	fprintf(f, "%02d:%02d:%02d.%03d %s\n",
		st.wHour, st.wMinute, st.wSecond, st.wMilliseconds, line);
	fclose(f);
}

static void ProbeLogf(const char* fmt, ...)
{
	char buf[2400];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	ProbeAppendLog(buf);
}

static const char* DxgiFmtName(DXGI_FORMAT f)
{
	switch (f)
	{
	case DXGI_FORMAT_R8G8B8A8_UNORM: return "R8G8B8A8_UNORM";
	case DXGI_FORMAT_R8G8B8A8_UNORM_SRGB: return "R8G8B8A8_UNORM_SRGB";
	case DXGI_FORMAT_B8G8R8A8_UNORM: return "B8G8R8A8_UNORM";
	case DXGI_FORMAT_B8G8R8A8_UNORM_SRGB: return "B8G8R8A8_UNORM_SRGB";
	case DXGI_FORMAT_R16G16B16A16_FLOAT: return "R16G16B16A16_FLOAT";
	case DXGI_FORMAT_R32G32B32A32_FLOAT: return "R32G32B32A32_FLOAT";
	case DXGI_FORMAT_R10G10B10A2_UNORM: return "R10G10B10A2_UNORM";
	default: return "OTHER";
	}
}

static float HalfToFloat(uint16_t h)
{
	const uint32_t s = (h >> 15) & 1u;
	uint32_t e = (h >> 10) & 0x1fu;
	uint32_t m = h & 0x3ffu;
	uint32_t out;
	if (e == 0)
	{
		if (m == 0)
			out = s << 31;
		else
		{
			e = 1;
			while ((m & 0x400u) == 0) { m <<= 1; --e; }
			m &= 0x3ffu;
			out = (s << 31) | ((e + 127 - 15) << 23) | (m << 13);
		}
	}
	else if (e == 31)
		out = (s << 31) | 0x7f800000u | (m << 13);
	else
		out = (s << 31) | ((e + 127 - 15) << 23) | (m << 13);
	float f;
	std::memcpy(&f, &out, 4);
	return f;
}

struct ProbePixStats
{
	int ok = 0;
	int w = 0, h = 0;
	int n = 0, nzA = 0, nzRGB = 0;
	float maxR = 0, maxG = 0, maxB = 0, maxA = 0;
	double sumR = 0, sumG = 0, sumB = 0, sumA = 0;
	char err[96] = "unset";
	std::vector<uint8_t> ldr; // RGBA8 preview
};

static ID3D11Texture2D* TexFromRTV(ID3D11RenderTargetView* rtv)
{
	if (!rtv)
		return nullptr;
	ID3D11Resource* res = nullptr;
	rtv->GetResource(&res);
	if (!res)
		return nullptr;
	ID3D11Texture2D* tex = nullptr;
	res->QueryInterface(__uuidof(ID3D11Texture2D), reinterpret_cast<void**>(&tex));
	res->Release();
	return tex;
}

static void Accumulate(ProbePixStats& s, float r, float g, float b, float a)
{
	++s.n;
	s.sumR += r; s.sumG += g; s.sumB += b; s.sumA += a;
	if (r > s.maxR) s.maxR = r;
	if (g > s.maxG) s.maxG = g;
	if (b > s.maxB) s.maxB = b;
	if (a > s.maxA) s.maxA = a;
	if (a > 1e-4f) ++s.nzA;
	if (std::fabs(r) > 1e-4f || std::fabs(g) > 1e-4f || std::fabs(b) > 1e-4f) ++s.nzRGB;
	auto enc = [](float v) -> uint8_t {
		if (v < 0.f) v = 0.f;
		if (v > 1.f) v = 1.f;
		return (uint8_t)(v * 255.f + 0.5f);
	};
	s.ldr.push_back(enc(r));
	s.ldr.push_back(enc(g));
	s.ldr.push_back(enc(b));
	s.ldr.push_back(enc(a));
}

static ProbePixStats ReadbackTex(ID3D11Device* dev, ID3D11DeviceContext* ctx,
	ID3D11Texture2D* src, int x0, int y0, int rw, int rh)
{
	ProbePixStats s;
	if (!dev || !ctx || !src)
	{
		snprintf(s.err, sizeof(s.err), "null_src");
		return s;
	}
	D3D11_TEXTURE2D_DESC desc{};
	src->GetDesc(&desc);
	if (rw <= 0) rw = (int)desc.Width;
	if (rh <= 0) rh = (int)desc.Height;
	if (x0 < 0) x0 = 0;
	if (y0 < 0) y0 = 0;
	if (x0 >= (int)desc.Width || y0 >= (int)desc.Height)
	{
		snprintf(s.err, sizeof(s.err), "region_oob src=%ux%u req=%d,%d %dx%d",
			desc.Width, desc.Height, x0, y0, rw, rh);
		return s;
	}
	if (x0 + rw > (int)desc.Width) rw = (int)desc.Width - x0;
	if (y0 + rh > (int)desc.Height) rh = (int)desc.Height - y0;
	if (rw <= 0 || rh <= 0)
	{
		snprintf(s.err, sizeof(s.err), "empty_region");
		return s;
	}

	ID3D11Texture2D* copySrc = src;
	ID3D11Texture2D* resolved = nullptr;
	if (desc.SampleDesc.Count > 1)
	{
		D3D11_TEXTURE2D_DESC rd = desc;
		rd.SampleDesc.Count = 1;
		rd.SampleDesc.Quality = 0;
		rd.BindFlags = 0;
		rd.MiscFlags = 0;
		if (FAILED(dev->CreateTexture2D(&rd, nullptr, &resolved)) || !resolved)
		{
			snprintf(s.err, sizeof(s.err), "resolve_create_failed");
			return s;
		}
		ctx->ResolveSubresource(resolved, 0, src, 0, desc.Format);
		copySrc = resolved;
	}

	D3D11_TEXTURE2D_DESC sd{};
	sd.Width = (UINT)rw;
	sd.Height = (UINT)rh;
	sd.MipLevels = 1;
	sd.ArraySize = 1;
	sd.Format = desc.Format;
	sd.SampleDesc.Count = 1;
	sd.Usage = D3D11_USAGE_STAGING;
	sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
	ID3D11Texture2D* staging = nullptr;
	if (FAILED(dev->CreateTexture2D(&sd, nullptr, &staging)) || !staging)
	{
		if (resolved) resolved->Release();
		snprintf(s.err, sizeof(s.err), "staging_create_failed fmt=%s", DxgiFmtName(desc.Format));
		return s;
	}
	D3D11_BOX box{};
	box.left = (UINT)x0;
	box.top = (UINT)y0;
	box.right = (UINT)(x0 + rw);
	box.bottom = (UINT)(y0 + rh);
	box.front = 0;
	box.back = 1;
	ctx->CopySubresourceRegion(staging, 0, 0, 0, 0, copySrc, 0, &box);
	if (resolved) resolved->Release();

	D3D11_MAPPED_SUBRESOURCE mapped{};
	if (FAILED(ctx->Map(staging, 0, D3D11_MAP_READ, 0, &mapped)) || !mapped.pData)
	{
		staging->Release();
		snprintf(s.err, sizeof(s.err), "map_failed");
		return s;
	}

	s.w = rw; s.h = rh;
	s.ldr.reserve((size_t)rw * (size_t)rh * 4);
	const uint8_t* base = static_cast<const uint8_t*>(mapped.pData);
	for (int y = 0; y < rh; ++y)
	{
		const uint8_t* row = base + (size_t)y * mapped.RowPitch;
		for (int x = 0; x < rw; ++x)
		{
			float r = 0, g = 0, b = 0, a = 0;
			if (desc.Format == DXGI_FORMAT_R16G16B16A16_FLOAT)
			{
				const uint16_t* p = reinterpret_cast<const uint16_t*>(row + (size_t)x * 8);
				r = HalfToFloat(p[0]); g = HalfToFloat(p[1]); b = HalfToFloat(p[2]); a = HalfToFloat(p[3]);
			}
			else if (desc.Format == DXGI_FORMAT_R32G32B32A32_FLOAT)
			{
				const float* p = reinterpret_cast<const float*>(row + (size_t)x * 16);
				r = p[0]; g = p[1]; b = p[2]; a = p[3];
			}
			else if (desc.Format == DXGI_FORMAT_B8G8R8A8_UNORM || desc.Format == DXGI_FORMAT_B8G8R8A8_UNORM_SRGB)
			{
				const uint8_t* p = row + (size_t)x * 4;
				r = p[2] / 255.f; g = p[1] / 255.f; b = p[0] / 255.f; a = p[3] / 255.f;
			}
			else
			{
				const uint8_t* p = row + (size_t)x * 4;
				r = p[0] / 255.f; g = p[1] / 255.f; b = p[2] / 255.f; a = p[3] / 255.f;
			}
			Accumulate(s, r, g, b, a);
		}
	}
	ctx->Unmap(staging, 0);
	staging->Release();
	s.ok = 1;
	snprintf(s.err, sizeof(s.err), "ok");
	return s;
}

static void LogStats(const char* tag, const ProbePixStats& s)
{
	const float inv = s.n > 0 ? 1.f / (float)s.n : 0.f;
	ProbeLogf("probe %s ok=%d %dx%d n=%d nzA=%d nzRGB=%d maxRGBA=%.5f,%.5f,%.5f,%.5f avgRGBA=%.5f,%.5f,%.5f,%.5f err=%s",
		tag, s.ok, s.w, s.h, s.n, s.nzA, s.nzRGB,
		s.maxR, s.maxG, s.maxB, s.maxA,
		(float)s.sumR * inv, (float)s.sumG * inv, (float)s.sumB * inv, (float)s.sumA * inv,
		s.err);
}

static void DumpPng(const char* name, const ProbePixStats& s)
{
	if (!s.ok || s.w <= 0 || s.h <= 0 || (int)s.ldr.size() < s.w * s.h * 4)
		return;
	char path[MAX_PATH];
	snprintf(path, sizeof(path), "%s\\Logs\\%s", mq::gPathMQRoot, name);
	int len = 0;
	unsigned char* png = stbi_write_png_to_mem(s.ldr.data(), s.w * 4, s.w, s.h, 4, &len);
	if (!png || len <= 0)
	{
		ProbeLogf("probe png_write_failed %s", path);
		return;
	}
	FILE* f = nullptr;
	if (fopen_s(&f, path, "wb") != 0 || !f)
	{
		free(png);
		ProbeLogf("probe png_open_failed %s", path);
		return;
	}
	fwrite(png, 1, (size_t)len, f);
	fclose(f);
	free(png);
	ProbeLogf("probe wrote %s (%dx%d %d bytes)", path, s.w, s.h, len);
}

static void LogTexDesc(const char* tag, ID3D11Texture2D* tex)
{
	if (!tex)
	{
		ProbeLogf("probe %s tex=null", tag);
		return;
	}
	D3D11_TEXTURE2D_DESC d{};
	tex->GetDesc(&d);
	ProbeLogf("probe %s ptr=%p %ux%u mips=%u fmt=%s(%d) bind=0x%x samples=%u usage=%u cpu=0x%x",
		tag, static_cast<void*>(tex), d.Width, d.Height, d.MipLevels,
		DxgiFmtName(d.Format), (int)d.Format, d.BindFlags, d.SampleDesc.Count, d.Usage, d.CPUAccessFlags);
}

static ID3D11Texture2D* SwapchainBuffer0()
{
	if (!mq::gpDXGISwapChain)
		return nullptr;
	ID3D11Texture2D* bb = nullptr;
	mq::gpDXGISwapChain->GetBuffer(0, __uuidof(ID3D11Texture2D), reinterpret_cast<void**>(&bb));
	return bb;
}

static const char* BlendName(D3D11_BLEND b)
{
	switch (b)
	{
	case D3D11_BLEND_ZERO: return "ZERO";
	case D3D11_BLEND_ONE: return "ONE";
	case D3D11_BLEND_SRC_COLOR: return "SRC_COLOR";
	case D3D11_BLEND_INV_SRC_COLOR: return "INV_SRC_COLOR";
	case D3D11_BLEND_SRC_ALPHA: return "SRC_ALPHA";
	case D3D11_BLEND_INV_SRC_ALPHA: return "INV_SRC_ALPHA";
	case D3D11_BLEND_DEST_ALPHA: return "DEST_ALPHA";
	case D3D11_BLEND_INV_DEST_ALPHA: return "INV_DEST_ALPHA";
	case D3D11_BLEND_DEST_COLOR: return "DEST_COLOR";
	case D3D11_BLEND_INV_DEST_COLOR: return "INV_DEST_COLOR";
	default: return "OTHER";
	}
}

static bool ConsumeProbeRequest(int spriteItems, int verts)
{
	const bool cmd = InterlockedExchange(&g_probeReq, 0) != 0;
	if (cmd)
		return true;
	if (!g_autoProbed && (spriteItems > 0 || verts > 0))
	{
		g_autoProbed = true;
		return true;
	}
	return false;
}

static void RunCompositeSideLog(ID3D11DeviceContext* ctx, ID3D11BlendState* expectedBlend)
{
	ID3D11BlendState* cur = nullptr;
	FLOAT bf[4]{};
	UINT mask = 0;
	if (ctx)
		ctx->OMGetBlendState(&cur, bf, &mask);
	D3D11_BLEND_DESC bd{};
	const int samePtr = (cur == expectedBlend) ? 1 : 0;
	if (cur)
	{
		cur->GetDesc(&bd);
		cur->Release();
	}
	else if (expectedBlend)
		expectedBlend->GetDesc(&bd);
	const D3D11_RENDER_TARGET_BLEND_DESC& rt = bd.RenderTarget[0];
	ProbeLogf("probe compositeBlend enable=%d srcRGB=%s destRGB=%s op=%d srcA=%s destA=%s writeMask=0x%x sampleMask=0x%x equalsExpected=%d",
		(int)rt.BlendEnable,
		BlendName(rt.SrcBlend), BlendName(rt.DestBlend), (int)rt.BlendOp,
		BlendName(rt.SrcBlendAlpha), BlendName(rt.DestBlendAlpha),
		rt.RenderTargetWriteMask, mask, samePtr);
	ProbeLogf("probe compositeShader output='float4(TonemapACES(scene.rgb), saturate(scene.a))' premultiplied=0  (c not multiplied by a)");
	ProbeLogf("probe rmlLayerCaps=0 PushLayer=noop CompositeLayers=noop PopLayer=noop (RenderInterface_DX11::GetRenderCaps returns 0)");
}
