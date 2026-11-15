#include <mq/Plugin.h>   // MacroQuest plugin API (MQ2Main, eqlib, PLUGIN_API)
#include "CanvasRenderer.h"
#include "shaders_canvas_bytecode.h"
#include "shaders_fx_bytecode.h"
#include "shaders_tfx_bytecode.h"
#include "TextFx.h"
#include "FxSim.h"
#include "D3D11StateBackup.h"

#include <d3d11.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <cstdio>
#include <cstdint>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>
#include <map>
#include <windows.h>

extern "C" unsigned char* stbi_load_from_memory(unsigned char const* buffer, int len,
	int* x, int* y, int* channels_in_file, int desired_channels);
extern "C" void stbi_image_free(void* retval_from_stbi_load);

#ifndef NOMINMAX
#define NOMINMAX
#endif

static constexpr int kMaxUpload = 65536;
static constexpr int kMaxSprites = 8192;

static CanvasDrawDiag g_lastDrawDiag{};
// Stage 0 perf counters (render thread only; snapshot string guarded by g_perfMtx)
static unsigned long long g_rtCreates = 0;      // render targets actually (re)allocated, lifetime
static std::mutex g_perfMtx;
static char g_perfLine[1024] = "no canvas draws yet";
static CanvasFxPerfInfo g_fxPerf{};             // guarded by g_perfMtx
static constexpr int kFxDotTex = -1;            // internal texture id: built-in soft dot (fx default)

#include "canvas_probe.inl"

enum {
	kFlagAdditive     = 0x0100,
	kFlagGlow         = 0x0200,
	kFlagSpriteSquare = 0x1000,
};

struct CB
{
	float vpW, vpH, originX, originY;
	float slotX, slotY, slotW, slotH;
	float texelX, texelY, dirX, dirY;
	float strength, time, energy, beat;
	float bgStyle, pad1, pad2, pad3;
};

struct SpriteGPU
{
	float x, y, rx, ry;
	float r, g, b, a;
};

struct SpriteExGPU
{
	float x, y, sx, sy;
	float r, g, b, a;
	float angle, pad0, pad1, pad2;
};

struct UserTex
{
	std::string path;
	std::string key;
	int w = 0, h = 0;
	std::vector<unsigned char> pixels;
	ID3D11Texture2D* tex = nullptr;
	ID3D11ShaderResourceView* srv = nullptr;
};

template <typename T>
static void Rel(T*& p)
{
	if (p) { p->Release(); p = nullptr; }
}

struct RT
{
	ID3D11Texture2D* tex = nullptr;
	ID3D11RenderTargetView* rtv = nullptr;
	ID3D11ShaderResourceView* srv = nullptr;
	int w = 0, h = 0;

	ID3D11Device* owner = nullptr;

	void Release()
	{
		Rel(srv); Rel(rtv); Rel(tex);
		owner = nullptr;
		w = h = 0;
	}

	bool Ensure(ID3D11Device* dev, int nw, int nh, DXGI_FORMAT fmt)
	{
		nw = std::max(2, nw);
		nh = std::max(2, nh);
		if (tex && owner == dev && w == nw && h == nh)
			return true;
		Release();
		D3D11_TEXTURE2D_DESC td{};
		td.Width = (UINT)nw;
		td.Height = (UINT)nh;
		td.MipLevels = 1;
		td.ArraySize = 1;
		td.Format = fmt;
		td.SampleDesc.Count = 1;
		td.Usage = D3D11_USAGE_DEFAULT;
		td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
		if (FAILED(dev->CreateTexture2D(&td, nullptr, &tex))
			|| FAILED(dev->CreateRenderTargetView(tex, nullptr, &rtv))
			|| FAILED(dev->CreateShaderResourceView(tex, nullptr, &srv)))
		{
			Release();
			return false;
		}
		owner = dev;
		w = nw; h = nh;
		++g_rtCreates;
		return true;
	}
};

using Backup = D3D11StateBackup;   // full snapshot (all VB slots used, IB, VS/PS CB+SRV+sampler, GS/HS/DS, 8 RTVs)

// Per-canvas render-target set (Stage 0): canvases of different sizes no longer reallocate one shared scene RT
// every frame. Keyed by the canvas element; unused sets are evicted after 5 s.
struct RTSet
{
	RT scene, trail;
	RT bloomA[3], bloomB[3];
	bool trailValid = false;
	double lastUse = 0.0;
	void Release()
	{
		scene.Release(); trail.Release();
		for (int i = 0; i < 3; ++i) { bloomA[i].Release(); bloomB[i].Release(); }
		trailValid = false;
	}
	unsigned long long Bytes() const
	{
		unsigned long long n = 0;
		auto add = [&](const RT& r) { if (r.tex) n += (unsigned long long)r.w * (unsigned long long)r.h * 8ull; };
		add(scene); add(trail);
		for (int i = 0; i < 3; ++i) { add(bloomA[i]); add(bloomB[i]); }
		return n;
	}
};

static double PerfNow()
{
	static LARGE_INTEGER f{};
	if (!f.QuadPart) QueryPerformanceFrequency(&f);
	LARGE_INTEGER t; QueryPerformanceCounter(&t);
	return (double)t.QuadPart * 1000.0 / (double)f.QuadPart;   // ms
}

class CanvasRendererImpl
{
public:
	void OnLostDevice()
	{
		for (auto& kv : m_sets)
			kv.second.Release();
		m_sets.clear();
		m_cur = &m_fallbackSet;
		m_fallbackSet.Release();
		ReleaseQueries();
		ReleaseFx();
		Rel(m_spriteVB);
		Rel(m_spriteExVB);
		Rel(m_cornerVB);
		Rel(m_layoutSprite);
		Rel(m_layoutSpriteEx);
		Rel(m_vsSpriteEx);
		Rel(m_psSpriteTex);
		Rel(m_whiteSRV);
		Rel(m_whiteTex);
		for (auto& t : m_userTex)
		{
			Rel(t.srv);
			Rel(t.tex);
		}
		Rel(m_samp);
		Rel(m_dss);
		Rel(m_rsNoScissor);
		Rel(m_rs);
		Rel(m_blendAdd);
		Rel(m_blendAlpha);
		Rel(m_psSpriteSq);
		Rel(m_psSprite);
		Rel(m_psComposite);
		Rel(m_vsSprite);
		Rel(m_psBg);
		Rel(m_psDown);
		Rel(m_psTex);
		Rel(m_psBlur);
		Rel(m_psColor);
		Rel(m_vs);
		Rel(m_layout);
		Rel(m_cb);
		Rel(m_vb);
		m_dev = nullptr;
	}

	bool Ensure(ID3D11Device* dev)
	{
		if (!dev)
			return false;
		if (m_vb && m_vs && m_vsSprite && m_vsSpriteEx && m_dev == dev)
			return true;
		OnLostDevice();
		m_dev = dev;
		{
			const D3D_FEATURE_LEVEL fl = dev->GetFeatureLevel();
			ProbeLogf("device %p feature_level=%d_%d (0x%x) cs5=%d", static_cast<void*>(dev),
				((int)fl >> 12) & 0xF, ((int)fl >> 8) & 0xF, (unsigned)fl, fl >= D3D_FEATURE_LEVEL_11_0 ? 1 : 0);
			m_featureLevel = (unsigned)fl;
		}

		D3D11_BUFFER_DESC vbd{};
		vbd.ByteWidth = sizeof(CanvasGpuVert) * kMaxUpload;
		vbd.Usage = D3D11_USAGE_DYNAMIC;
		vbd.BindFlags = D3D11_BIND_VERTEX_BUFFER;
		vbd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
		if (FAILED(dev->CreateBuffer(&vbd, nullptr, &m_vb)))
			return false;

		D3D11_BUFFER_DESC cbd{};
		cbd.ByteWidth = sizeof(CB);
		cbd.Usage = D3D11_USAGE_DYNAMIC;
		cbd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
		cbd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
		if (FAILED(dev->CreateBuffer(&cbd, nullptr, &m_cb)))
			return false;

		D3D11_BUFFER_DESC sbd{};
		sbd.ByteWidth = sizeof(SpriteGPU) * kMaxSprites;
		sbd.Usage = D3D11_USAGE_DYNAMIC;
		sbd.BindFlags = D3D11_BIND_VERTEX_BUFFER;
		sbd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
		if (FAILED(dev->CreateBuffer(&sbd, nullptr, &m_spriteVB)))
			return false;

		D3D11_BUFFER_DESC ebd{};
		ebd.ByteWidth = sizeof(SpriteExGPU) * kMaxSprites;
		ebd.Usage = D3D11_USAGE_DYNAMIC;
		ebd.BindFlags = D3D11_BIND_VERTEX_BUFFER;
		ebd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
		if (FAILED(dev->CreateBuffer(&ebd, nullptr, &m_spriteExVB)))
			return false;

		const float corners[12] = {
			-1, -1, 1, -1, 1, 1,
			-1, -1, 1, 1, -1, 1
		};
		D3D11_BUFFER_DESC cnb{};
		cnb.ByteWidth = sizeof(corners);
		cnb.Usage = D3D11_USAGE_IMMUTABLE;
		cnb.BindFlags = D3D11_BIND_VERTEX_BUFFER;
		D3D11_SUBRESOURCE_DATA cnd{ corners, 0, 0 };
		if (FAILED(dev->CreateBuffer(&cnb, &cnd, &m_cornerVB)))
			return false;

		if (FAILED(dev->CreateVertexShader(kBC_vs_main, kBC_vs_main_len, nullptr, &m_vs))
			|| FAILED(dev->CreateVertexShader(kBC_vs_sprite, kBC_vs_sprite_len, nullptr, &m_vsSprite))
			|| FAILED(dev->CreateVertexShader(kBC_vs_sprite_ex, kBC_vs_sprite_ex_len, nullptr, &m_vsSpriteEx))
			|| FAILED(dev->CreatePixelShader(kBC_ps_color, kBC_ps_color_len, nullptr, &m_psColor))
			|| FAILED(dev->CreatePixelShader(kBC_ps_blur, kBC_ps_blur_len, nullptr, &m_psBlur))
			|| FAILED(dev->CreatePixelShader(kBC_ps_tex, kBC_ps_tex_len, nullptr, &m_psTex))
			|| FAILED(dev->CreatePixelShader(kBC_ps_downsample, kBC_ps_downsample_len, nullptr, &m_psDown))
			|| FAILED(dev->CreatePixelShader(kBC_ps_bg, kBC_ps_bg_len, nullptr, &m_psBg))
			|| FAILED(dev->CreatePixelShader(kBC_ps_sprite, kBC_ps_sprite_len, nullptr, &m_psSprite))
			|| FAILED(dev->CreatePixelShader(kBC_ps_sprite_sq, kBC_ps_sprite_sq_len, nullptr, &m_psSpriteSq))
			|| FAILED(dev->CreatePixelShader(kBC_ps_sprite_tex, kBC_ps_sprite_tex_len, nullptr, &m_psSpriteTex))
			|| FAILED(dev->CreatePixelShader(kBC_ps_composite, kBC_ps_composite_len, nullptr, &m_psComposite)))
		{
			OnLostDevice();
			return false;
		}

		D3D11_INPUT_ELEMENT_DESC layout[] = {
			{ "POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0 },
			{ "COLOR", 0, DXGI_FORMAT_R8G8B8A8_UNORM, 0, 8, D3D11_INPUT_PER_VERTEX_DATA, 0 },
		};
		if (FAILED(dev->CreateInputLayout(layout, 2, kBC_vs_main, kBC_vs_main_len, &m_layout)))
		{
			OnLostDevice();
			return false;
		}

		D3D11_INPUT_ELEMENT_DESC slayout[] = {
			{ "POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0 },
			{ "TEXCOORD", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 1, 0, D3D11_INPUT_PER_INSTANCE_DATA, 1 },
			{ "COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 1, 16, D3D11_INPUT_PER_INSTANCE_DATA, 1 },
		};
		if (FAILED(dev->CreateInputLayout(slayout, 3, kBC_vs_sprite, kBC_vs_sprite_len, &m_layoutSprite)))
		{
			OnLostDevice();
			return false;
		}

		D3D11_INPUT_ELEMENT_DESC xlayout[] = {
			{ "POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0 },
			{ "TEXCOORD", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 1, 0, D3D11_INPUT_PER_INSTANCE_DATA, 1 },
			{ "COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 1, 16, D3D11_INPUT_PER_INSTANCE_DATA, 1 },
			{ "TEXCOORD", 1, DXGI_FORMAT_R32G32B32A32_FLOAT, 1, 32, D3D11_INPUT_PER_INSTANCE_DATA, 1 },
		};
		if (FAILED(dev->CreateInputLayout(xlayout, 4, kBC_vs_sprite_ex, kBC_vs_sprite_ex_len, &m_layoutSpriteEx)))
		{
			OnLostDevice();
			return false;
		}

		auto makeBlend = [&](bool add, ID3D11BlendState** out) -> bool {
			D3D11_BLEND_DESC bd{};
			bd.RenderTarget[0].BlendEnable = TRUE;
			bd.RenderTarget[0].SrcBlend = D3D11_BLEND_ONE;
			bd.RenderTarget[0].DestBlend = add ? D3D11_BLEND_ONE : D3D11_BLEND_INV_SRC_ALPHA;
			bd.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
			bd.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
			bd.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
			bd.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
			bd.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
			return SUCCEEDED(dev->CreateBlendState(&bd, out));
		};
		if (!makeBlend(false, &m_blendAlpha) || !makeBlend(true, &m_blendAdd))
		{
			OnLostDevice();
			return false;
		}

		D3D11_RASTERIZER_DESC rd{};
		rd.FillMode = D3D11_FILL_SOLID;
		rd.CullMode = D3D11_CULL_NONE;
		rd.ScissorEnable = TRUE;
		rd.DepthClipEnable = TRUE;
		if (FAILED(dev->CreateRasterizerState(&rd, &m_rs)))
		{
			OnLostDevice();
			return false;
		}
		rd.ScissorEnable = FALSE;
		if (FAILED(dev->CreateRasterizerState(&rd, &m_rsNoScissor)))
		{
			OnLostDevice();
			return false;
		}

		D3D11_DEPTH_STENCIL_DESC dd{};
		dd.DepthEnable = FALSE;
		dd.StencilEnable = FALSE;
		if (FAILED(dev->CreateDepthStencilState(&dd, &m_dss)))
		{
			OnLostDevice();
			return false;
		}

		D3D11_SAMPLER_DESC sd{};
		sd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
		sd.AddressU = sd.AddressV = sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
		sd.MaxLOD = D3D11_FLOAT32_MAX;
		if (FAILED(dev->CreateSamplerState(&sd, &m_samp)))
		{
			OnLostDevice();
			return false;
		}

		const unsigned char whitePx[4] = { 255, 255, 255, 255 };
		D3D11_TEXTURE2D_DESC wtd{};
		wtd.Width = 1;
		wtd.Height = 1;
		wtd.MipLevels = 1;
		wtd.ArraySize = 1;
		wtd.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
		wtd.SampleDesc.Count = 1;
		wtd.Usage = D3D11_USAGE_IMMUTABLE;
		wtd.BindFlags = D3D11_BIND_SHADER_RESOURCE;
		D3D11_SUBRESOURCE_DATA wsd{ whitePx, 4, 0 };
		if (FAILED(dev->CreateTexture2D(&wtd, &wsd, &m_whiteTex))
			|| FAILED(dev->CreateShaderResourceView(m_whiteTex, nullptr, &m_whiteSRV)))
		{
			OnLostDevice();
			return false;
		}
		return true;
	}

	void Draw(const std::vector<CanvasTriBatch>& batches,
		const std::vector<CanvasSpriteBatch>& sprites,
		const std::vector<CanvasSpriteExInst>& spritesEx,
		const CanvasFrame& frame,
		float ox, float oy, float cw, float ch, float* lastMs, const void* owner,
		const std::vector<CanvasFxDraw>* fx, const TextFxDraw* tfx = nullptr)
	{
		LARGE_INTEGER t0, t1, freq;
		QueryPerformanceCounter(&t0);

		CanvasDrawDiag d{};
		d.entered = 1;
		d.ox = ox; d.oy = oy; d.cw = cw; d.ch = ch;
		d.bgStyle = frame.bgStyle;
		d.mqDevice = (unsigned long long)(uintptr_t)mq::gpD3D11Device;
		d.batches = (int)batches.size();
		for (const auto& b : batches)
			d.verts += (int)b.verts.size();
		d.sprites = (int)sprites.size();
		for (const auto& s : sprites)
			d.spriteItems += (int)s.items.size();
		d.spriteItems += (int)spritesEx.size();
		snprintf(d.reason, sizeof(d.reason), "entered");
		struct Flush { CanvasDrawDiag* p; ~Flush() { g_lastDrawDiag = *p; } } flush{ &d };

		ID3D11Device* dev = mq::gpD3D11Device;
		d.device = (unsigned long long)(uintptr_t)dev;
		if (!dev)
		{
			snprintf(d.reason, sizeof(d.reason), "no_device");
			return;
		}
		d.deviceHr = (long)dev->GetDeviceRemovedReason();
		if (FAILED((HRESULT)d.deviceHr))
		{
			OnLostDevice();
			snprintf(d.reason, sizeof(d.reason), "device_removed");
			return;
		}
		if (!Ensure(dev) || !m_vb)
		{
			snprintf(d.reason, sizeof(d.reason), "ensure_failed");
			return;
		}
		ID3D11DeviceContext* ctx = nullptr;
		dev->GetImmediateContext(&ctx);
		if (!ctx)
		{
			snprintf(d.reason, sizeof(d.reason), "no_context");
			return;
		}

		Backup bak;
		bak.Capture(ctx);
		D3D11StateBackup::ClearExtraStages(ctx);

		float rtW = 0, rtH = 0;
		if (bak.nvp > 0)
		{
			rtW = bak.vps[0].Width;
			rtH = bak.vps[0].Height;
		}
		d.vpW = rtW; d.vpH = rtH;
		d.nvp = (int)bak.nvp; d.nsc = (int)bak.nsc;
		d.bakRtv = (unsigned long long)(uintptr_t)bak.rtv;
		if (bak.nsc > 0)
		{
			d.scInL = (int)bak.sc[0].left;
			d.scInT = (int)bak.sc[0].top;
			d.scInR = (int)bak.sc[0].right;
			d.scInB = (int)bak.sc[0].bottom;
		}
		if (rtW < 1.f || rtH < 1.f)
		{
			bak.Restore(ctx);
			ctx->Release();
			snprintf(d.reason, sizeof(d.reason), "no_viewport");
			return;
		}

		// Dest is the canvas content box. Intersect with Rml's scissor, but
		// never expand to a document-sized clip — that painted over the
		// window titlebar. Snap X left when the element-row scissor starts
		// a few px before GetAbsoluteOffset (the leftover dark strip).
		float destX = ox, destY = oy, destW = cw, destH = ch;
		if (bak.nsc > 0 && bak.sc[0].right > bak.sc[0].left && bak.sc[0].bottom > bak.sc[0].top)
		{
			const float sx = (float)bak.sc[0].left;
			const float sy = (float)bak.sc[0].top;
			const float sr = (float)bak.sc[0].right;
			const float sb = (float)bak.sc[0].bottom;
			const float scW = sr - sx;
			const float scH = sb - sy;
			const bool scissorIsWindow = (sy <= 2.f && sx <= 2.f && scH > ch + 16.f);
			float x0 = destX;
			float y0 = destY;
			if (!scissorIsWindow)
			{
				if (sx < x0 && (x0 - sx) <= 48.f && std::fabs(scH - ch) < 28.f && std::fabs(sy - oy) < 28.f)
					x0 = sx;
				x0 = std::max(x0, sx);
				y0 = std::max(y0, sy);
			}
			const float x1 = std::min(destX + destW, sr);
			const float y1 = std::min(destY + destH, sb);
			if (x1 > x0 && y1 > y0)
			{
				destX = x0;
				destY = y0;
				destW = x1 - x0;
				destH = y1 - y0;
			}
			(void)scW;
		}
		D3D11_RECT sc{};
		sc.left = (LONG)std::floor(destX);
		sc.top = (LONG)std::floor(destY);
		sc.right = (LONG)std::ceil(destX + destW);
		sc.bottom = (LONG)std::ceil(destY + destH);
		d.destX = destX; d.destY = destY; d.destW = destW; d.destH = destH;
		d.scL = (float)sc.left; d.scT = (float)sc.top; d.scR = (float)sc.right; d.scB = (float)sc.bottom;
		if (sc.right <= sc.left || sc.bottom <= sc.top)
		{
			bak.Restore(ctx);
			ctx->Release();
			snprintf(d.reason, sizeof(d.reason), "empty_scissor");
			return;
		}

		// Scene size: canvas content box, capped at the target it composites into (the window RT) and 4096.
		// (Was a fixed 1920x1080 cap, which stretched full-screen canvases above 1080p.)
		const int capW = std::min(4096, std::max(1920, (int)(rtW + 0.5f)));
		const int capH = std::min(4096, std::max(1080, (int)(rtH + 0.5f)));
		const int iw = std::max(8, std::min((int)(cw + 0.5f), capW));
		const int ih = std::max(8, std::min((int)(ch + 0.5f), capH));
		const double tNow = PerfNow();
		m_cur = AcquireSet(owner, tNow);
		DXGI_FORMAT fmt = DXGI_FORMAT_R16G16B16A16_FLOAT;
		if (!m_cur->scene.Ensure(dev, iw, ih, fmt))
		{
			fmt = DXGI_FORMAT_R8G8B8A8_UNORM;
			if (!m_cur->scene.Ensure(dev, iw, ih, fmt))
			{
				d.deviceHr = (long)dev->GetDeviceRemovedReason();
				if (FAILED((HRESULT)d.deviceHr))
				{
					bak.Restore(ctx);
					ctx->Release();
					OnLostDevice();
					snprintf(d.reason, sizeof(d.reason), "rt_create_device_removed");
					return;
				}
				d.fallback = 1;
				DrawFallback(ctx, bak, batches, ox, oy, rtW, rtH, sc);
				bak.Restore(ctx);
				ctx->Release();
				snprintf(d.reason, sizeof(d.reason), "rt_create_failed_fallback");
				return;
			}
		}

		const float clear0[4] = { 0, 0, 0, 0 };
		if (frame.trailDecay > 0.01f)
		{
			const bool same = m_cur->trail.tex && m_cur->trail.owner == dev && m_cur->trail.w == iw && m_cur->trail.h == ih;
			if (!m_cur->trail.Ensure(dev, iw, ih, fmt))
			{
				m_cur->trailValid = false;
			}
			else if (!same)
			{
				ctx->ClearRenderTargetView(m_cur->trail.rtv, clear0);
				m_cur->trailValid = false;
			}
		}

		BindScene(ctx, iw, ih);
		ctx->ClearRenderTargetView(m_cur->scene.rtv, clear0);

		// scene = previous * decay  (clear-then-additive blit of decayed trail)
		if (frame.trailDecay > 0.01f && m_cur->trailValid && m_cur->trail.srv)
			BlitInternal(ctx, m_cur->trail.srv, iw, ih, iw, ih, frame.trailDecay, true, false);

		QSet* q = BeginQueries(ctx);
		const double cpu0 = PerfNow();
		DrawBatches(ctx, batches, 0, 0, (float)iw, (float)ih, true);
		DrawSprites(ctx, sprites, (float)iw, (float)ih);
		DrawSpritesEx(ctx, spritesEx, (float)iw, (float)ih);
		// Stage 1 particles: drawn into the scene (so bloom/composite treat them like sprites), timed on their own
		if (q) ctx->End(q->ts[4]);
		const double cpuFx0 = PerfNow();
		const bool fxDrawn = fx && !fx->empty();
		if (fxDrawn)
			DrawFx(ctx, *fx, iw, ih);
		// TextFX: number particles go into the HDR scene before bloom (they glow); the digits themselves are
		// drawn AFTER bloom (gfx2) so the threshold-less bloom can never wash them out to white. Bloom still only
		// ever sees this canvas's effects layer, never the game image.
		bool tfxDrawn = false;
		double tfxCpu = 0.0;
		if (tfx && (!tfx->f.glyphs.empty() || !tfx->f.parts.empty()))
		{
			if (q) ctx->End(q->ts[5]);
			const double ct0 = PerfNow();
			tfxDrawn = DrawTfx(ctx, *tfx, iw, ih, 1);
			if (q) ctx->End(q->ts[6]);
			tfxCpu = PerfNow() - ct0;
		}
		if (q) ctx->End(q->ts[1]);
		const double cpu1 = PerfNow();

		const bool doProbe = ConsumeProbeRequest(d.spriteItems, d.verts);
		ProbePixStats stScene{}, stBloom{}, stBefore{}, stAfter{};
		ID3D11Texture2D* bakTex = nullptr;
		if (doProbe)
		{
			ProbeLogf("probe begin win=%s handedV=%d handedSI=%d bloom=%.3f dest=%.1f,%.1f %.1fx%.1f elem=%.1f,%.1f %.1fx%.1f vp=%.0fx%.0f scissor=%ld,%ld,%ld,%ld",
				g_paintWin[0] ? g_paintWin : "?", d.verts, d.spriteItems, frame.bloomStrength,
				destX, destY, destW, destH, ox, oy, cw, ch, rtW, rtH,
				sc.left, sc.top, sc.right, sc.bottom);
			stScene = ReadbackTex(dev, ctx, m_cur->scene.tex, 0, 0, m_cur->scene.w, m_cur->scene.h);
			LogStats("scene", stScene);
		}

		// Snapshot trails BEFORE bloom. Copying the bloomed HDR target back into
		// the trail RT made each frame: trail = bloom(trail * decay + geo),
		// which diverges to +inf (solid white) at MusicViz bloom strengths.
		if (frame.trailDecay > 0.01f && m_cur->trail.rtv)
		{
			ctx->CopyResource(m_cur->trail.tex, m_cur->scene.tex);
			m_cur->trailValid = true;
		}

		float bloomS = frame.bloomStrength;
		if (tfxDrawn && tfx->bloom > bloomS)
			bloomS = tfx->bloom;
		if (bloomS > 0.01f)
		{
			float capsX[16];
			bool caps = Fx_CanvasCapsule(owner, capsX);   // Stage 3: keep bloom off the body capsule
			if (!caps && tfxDrawn && tfx->hasCaps)       // TextFX capsule when no body-FX capsule is set
			{
				std::memcpy(capsX, tfx->caps, sizeof(capsX));
				caps = true;
			}
			ApplyBloom(ctx, dev, fmt, iw, ih, bloomS, caps ? capsX : nullptr);
		}
		if (q) ctx->End(q->ts[2]);
		if (tfxDrawn)
		{
			if (q) ctx->End(q->ts[7]);
			const double ct1 = PerfNow();
			BindScene(ctx, iw, ih);
			DrawTfx(ctx, *tfx, iw, ih, 2);
			if (q) ctx->End(q->ts[8]);
			tfxCpu += PerfNow() - ct1;
			Tfx_NotePerf(tfx->cpuMs + tfxCpu, (int)tfx->f.glyphs.size(), (int)tfx->f.parts.size());
		}
		const double cpu2 = PerfNow();

		if (doProbe)
		{
			if (frame.bloomStrength > 0.01f)
			{
				stBloom = ReadbackTex(dev, ctx, m_cur->scene.tex, 0, 0, m_cur->scene.w, m_cur->scene.h);
				LogStats("bloom", stBloom);
			}
			else
				ProbeLogf("probe bloom skipped strength=%.3f", frame.bloomStrength);
			bakTex = TexFromRTV(bak.rtv);
			stBefore = ReadbackTex(dev, ctx, bakTex, (int)std::floor(destX), (int)std::floor(destY),
				(int)std::ceil(destW), (int)std::ceil(destH));
			LogStats("bak_before", stBefore);
		}

		ctx->OMSetRenderTargets(1, &bak.rtv, bak.dsv);
		D3D11_VIEWPORT cvp{};
		cvp.TopLeftX = destX;
		cvp.TopLeftY = destY;
		cvp.Width = destW;
		cvp.Height = destH;
		cvp.MaxDepth = 1.f;
		ctx->RSSetViewports(1, &cvp);
		ctx->RSSetScissorRects(1, &sc);
		ctx->RSSetState(m_rs);

		// Local 0..dest quad. vs_main maps that to this viewport.
		// DestUV still uses RT-absolute SV_POSITION, so slot is the dest rect.
		if (frame.bgStyle > 0)
		{
			CB cb = BaseCB(destW, destH, frame);
			cb.originX = 0.f; cb.originY = 0.f;
			cb.slotX = destX; cb.slotY = destY; cb.slotW = destW; cb.slotH = destH;
			cb.texelX = 1.f / destW; cb.texelY = 1.f / destH;
			cb.bgStyle = (float)frame.bgStyle;
			UpdateCB(ctx, cb);
			BindColor(ctx, m_vs, m_layout, m_psBg, m_blendAlpha);
			CanvasGpuVert quad[6];
			FillBlit(quad, 0.f, 0.f, destW, destH, 0xFFFFFFFFu);
			UploadRaw(ctx, quad, 6);
			ctx->Draw(6, 0);
		}

		{
			CB cb = BaseCB(destW, destH, frame);
			cb.originX = 0.f; cb.originY = 0.f;
			cb.slotX = destX; cb.slotY = destY; cb.slotW = destW; cb.slotH = destH;
			cb.strength = 1.f;
			UpdateCB(ctx, cb);
			ID3D11PixelShader* psOut = m_psComposite ? m_psComposite : m_psTex;
			BindColor(ctx, m_vs, m_layout, psOut, m_blendAlpha);
			CanvasGpuVert quad[6];
			FillBlit(quad, 0.f, 0.f, destW, destH, 0xFFFFFFFFu);
			UploadRaw(ctx, quad, 6);
			ctx->PSSetShaderResources(0, 1, &m_cur->scene.srv);
			ctx->Draw(6, 0);
			ID3D11ShaderResourceView* none = nullptr;
			ctx->PSSetShaderResources(0, 1, &none);
		}

		if (doProbe)
		{
			stAfter = ReadbackTex(dev, ctx, bakTex, (int)std::floor(destX), (int)std::floor(destY),
				(int)std::ceil(destW), (int)std::ceil(destH));
			LogStats("bak_after", stAfter);
			RunCompositeSideLog(ctx, m_blendAlpha);
			ID3D11Texture2D* bb = SwapchainBuffer0();
			ProbeLogf("probe bakEqualsSwapchain=%d bakEqualsWindowRt=%d bakRtvEqualsPaintRtv=%d paintWin=%s paintRt=%dx%d gpSwap=%p",
				(bb && bakTex && bb == bakTex) ? 1 : 0,
				(g_paintTex && bakTex && g_paintTex == bakTex) ? 1 : 0,
				(g_paintRtv && bak.rtv && g_paintRtv == bak.rtv) ? 1 : 0,
				g_paintWin[0] ? g_paintWin : "?", g_paintW, g_paintH,
				static_cast<void*>(mq::gpDXGISwapChain));
			LogTexDesc("bak", bakTex);
			LogTexDesc("windowRt", g_paintTex);
			LogTexDesc("swapchain0", bb);
			if (bb) bb->Release();
			ProbeLogf("probe %s", g_elemInfo[0] ? g_elemInfo : "opacity unset");
			DumpPng("rmlui_probe_scene.png", stScene);
			DumpPng("rmlui_probe_after.png", stAfter);
			if (bakTex) { bakTex->Release(); bakTex = nullptr; }
		}

		if (q) { ctx->End(q->ts[3]); ctx->End(q->disjoint); q->pending = true; q->bloom = bloomS > 0.01f; q->fx = fxDrawn; q->tfx = tfxDrawn; }
		const double cpu3 = PerfNow();
		bak.Restore(ctx);
		CollectQueries(ctx);
		ctx->Release();
		AccumulatePerf(cpu1 - cpu0, cpu2 - cpu1, cpu3 - cpu2, bloomS > 0.01f, tNow, fxDrawn, cpu1 - cpuFx0);

		QueryPerformanceCounter(&t1);
		QueryPerformanceFrequency(&freq);
		if (lastMs)
			*lastMs = (float)((t1.QuadPart - t0.QuadPart) * 1000.0 / (double)freq.QuadPart);
		d.composite = 1;
		d.sceneW = m_cur->scene.w;
		d.sceneH = m_cur->scene.h;
		d.sceneOk = (m_cur->scene.rtv != nullptr) ? 1 : 0;
		snprintf(d.reason, sizeof(d.reason), "ok");
	}

private:
	static CB BaseCB(float vpW, float vpH, const CanvasFrame& frame)
	{
		CB cb{};
		cb.vpW = vpW;
		cb.vpH = vpH;
		cb.strength = 1.f;
		cb.time = frame.bgTime;
		cb.energy = frame.bgEnergy;
		cb.beat = frame.bgBeat;
		cb.bgStyle = (float)frame.bgStyle;
		return cb;
	}

	void BindScene(ID3D11DeviceContext* ctx, int w, int h)
	{
		ctx->OMSetRenderTargets(1, &m_cur->scene.rtv, nullptr);
		D3D11_VIEWPORT vp{};
		vp.Width = (float)w;
		vp.Height = (float)h;
		vp.MaxDepth = 1.f;
		ctx->RSSetViewports(1, &vp);
		D3D11_RECT full{ 0, 0, w, h };
		ctx->RSSetScissorRects(1, &full);
		ctx->RSSetState(m_rsNoScissor);
	}

	void DrawFallback(ID3D11DeviceContext* ctx, Backup& bak,
		const std::vector<CanvasTriBatch>& batches,
		float ox, float oy, float rtW, float rtH, const D3D11_RECT& sc)
	{
		ctx->OMSetRenderTargets(1, &bak.rtv, bak.dsv);
		if (bak.nvp > 0)
			ctx->RSSetViewports(bak.nvp, bak.vps);
		ctx->RSSetScissorRects(1, &sc);
		DrawBatches(ctx, batches, ox, oy, rtW, rtH, false);
	}

	void UpdateCB(ID3D11DeviceContext* ctx, const CB& cb)
	{
		D3D11_MAPPED_SUBRESOURCE mapped{};
		if (FAILED(ctx->Map(m_cb, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped)) || !mapped.pData)
			return;
		std::memcpy(mapped.pData, &cb, sizeof(cb));
		ctx->Unmap(m_cb, 0);
	}

	void BindColor(ID3D11DeviceContext* ctx, ID3D11VertexShader* vs, ID3D11InputLayout* layout,
		ID3D11PixelShader* ps, ID3D11BlendState* blend)
	{
		const float bf[4] = { 0, 0, 0, 0 };
		UINT stride = sizeof(CanvasGpuVert), offset = 0;
		ctx->IASetInputLayout(layout);
		ctx->IASetVertexBuffers(0, 1, &m_vb, &stride, &offset);
		ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
		ctx->VSSetShader(vs, nullptr, 0);
		ctx->VSSetConstantBuffers(0, 1, &m_cb);
		ctx->PSSetShader(ps, nullptr, 0);
		ctx->PSSetSamplers(0, 1, &m_samp);
		ctx->PSSetConstantBuffers(0, 1, &m_cb);
		ctx->OMSetBlendState(blend, bf, 0xFFFFFFFF);
		ctx->OMSetDepthStencilState(m_dss, 0);
	}

	void UploadRaw(ID3D11DeviceContext* ctx, const CanvasGpuVert* v, int n)
	{
		if (n <= 0 || n > kMaxUpload)
			return;
		D3D11_MAPPED_SUBRESOURCE mapped{};
		if (FAILED(ctx->Map(m_vb, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped)) || !mapped.pData)
			return;
		std::memcpy(mapped.pData, v, sizeof(CanvasGpuVert) * n);
		ctx->Unmap(m_vb, 0);
	}

	static void FillBlit(CanvasGpuVert* q, float x0, float y0, float x1, float y1, uint32_t c)
	{
		q[0] = { x0, y0, c }; q[1] = { x1, y0, c }; q[2] = { x1, y1, c };
		q[3] = { x0, y0, c }; q[4] = { x1, y1, c }; q[5] = { x0, y1, c };
	}

	void DrawBatches(ID3D11DeviceContext* ctx, const std::vector<CanvasTriBatch>& batches,
		float ox, float oy, float vpW, float vpH, bool local)
	{
		for (const auto& b : batches)
		{
			if (b.verts.empty())
				continue;
			const int n = std::min((int)b.verts.size(), kMaxUpload);
			if (n < 3)
				continue;
			D3D11_MAPPED_SUBRESOURCE mapped{};
			if (FAILED(ctx->Map(m_vb, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped)) || !mapped.pData)
				continue;
			auto* dst = static_cast<CanvasGpuVert*>(mapped.pData);
			if (local || (ox == 0.f && oy == 0.f))
				std::memcpy(dst, b.verts.data(), sizeof(CanvasGpuVert) * n);
			else
			{
				for (int i = 0; i < n; ++i)
				{
					dst[i] = b.verts[i];
					dst[i].x += ox;
					dst[i].y += oy;
				}
			}
			ctx->Unmap(m_vb, 0);

			CB cb{};
			cb.vpW = vpW;
			cb.vpH = vpH;
			cb.strength = 1.f;
			UpdateCB(ctx, cb);
			BindColor(ctx, m_vs, m_layout, m_psColor,
				(b.flags & kFlagAdditive) ? m_blendAdd : m_blendAlpha);
			ctx->Draw((UINT)n, 0);
		}
	}

	void DrawSprites(ID3D11DeviceContext* ctx, const std::vector<CanvasSpriteBatch>& sprites,
		float vpW, float vpH)
	{
		if (sprites.empty() || !m_spriteVB)
			return;
		for (const auto& b : sprites)
		{
			if (b.items.empty())
				continue;
			int remaining = (int)b.items.size();
			int src = 0;
			while (remaining > 0)
			{
				const int n = std::min(remaining, kMaxSprites);
				D3D11_MAPPED_SUBRESOURCE mapped{};
				if (FAILED(ctx->Map(m_spriteVB, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped)) || !mapped.pData)
					break;
				auto* dst = static_cast<SpriteGPU*>(mapped.pData);
				for (int i = 0; i < n; ++i)
				{
					const auto& s = b.items[src + i];
					dst[i] = { s.x, s.y, s.rx, s.ry, s.r * s.a, s.g * s.a, s.b * s.a, s.a };
				}
				ctx->Unmap(m_spriteVB, 0);

				CB cb{};
				cb.vpW = vpW;
				cb.vpH = vpH;
				cb.strength = 1.f;
				UpdateCB(ctx, cb);

				ID3D11Buffer* vbs[2] = { m_cornerVB, m_spriteVB };
				UINT strides[2] = { sizeof(float) * 2, sizeof(SpriteGPU) };
				UINT offsets[2] = { 0, 0 };
				const float bf[4] = { 0, 0, 0, 0 };
				ctx->IASetInputLayout(m_layoutSprite);
				ctx->IASetVertexBuffers(0, 2, vbs, strides, offsets);
				ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
				ctx->VSSetShader(m_vsSprite, nullptr, 0);
				ctx->VSSetConstantBuffers(0, 1, &m_cb);
				ctx->PSSetShader((b.flags & kFlagSpriteSquare) ? m_psSpriteSq : m_psSprite, nullptr, 0);
				ctx->PSSetSamplers(0, 1, &m_samp);
				ctx->PSSetConstantBuffers(0, 1, &m_cb);
				ctx->OMSetBlendState(m_blendAdd, bf, 0xFFFFFFFF);
				ctx->OMSetDepthStencilState(m_dss, 0);
				ctx->DrawInstanced(6, (UINT)n, 0, 0);
				src += n;
				remaining -= n;
			}
		}
	}


	std::string NormTexPath(const char* path) const
	{
		char full[MAX_PATH];
		DWORD n = GetFullPathNameA(path, MAX_PATH, full, nullptr);
		std::string s = (n > 0 && n < MAX_PATH) ? full : path;
		for (char& c : s)
		{
			if (c == '/')
				c = '\\';
			else if (c >= 'A' && c <= 'Z')
				c = static_cast<char>(c - 'A' + 'a');
		}
		return s;
	}

	bool EnsureTexGpu(UserTex& t)
	{
		if (t.srv)
			return true;
		if (t.pixels.empty() || t.w < 1 || t.h < 1)
			return false;
		ID3D11Device* dev = m_dev ? m_dev : mq::gpD3D11Device;
		if (!dev)
			return false;
		D3D11_TEXTURE2D_DESC td{};
		td.Width = (UINT)t.w;
		td.Height = (UINT)t.h;
		td.MipLevels = 1;
		td.ArraySize = 1;
		td.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
		td.SampleDesc.Count = 1;
		td.Usage = D3D11_USAGE_IMMUTABLE;
		td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
		D3D11_SUBRESOURCE_DATA sd{ t.pixels.data(), (UINT)(t.w * 4), 0 };
		if (FAILED(dev->CreateTexture2D(&td, &sd, &t.tex)))
			return false;
		if (FAILED(dev->CreateShaderResourceView(t.tex, nullptr, &t.srv)))
		{
			Rel(t.tex);
			return false;
		}
		return true;
	}

	public:
	int LoadTexture(const char* path)
	{
		if (!path || !path[0])
			return 0;
		const std::string key = NormTexPath(path);
		std::lock_guard<std::mutex> lock(m_texMtx);
		auto it = m_texByPath.find(key);
		if (it != m_texByPath.end())
		{
			const int id = it->second;
			if (id > 0 && id <= (int)m_userTex.size())
				EnsureTexGpu(m_userTex[(size_t)id - 1]);
			return id;
		}
		FILE* fp = nullptr;
		if (fopen_s(&fp, path, "rb") != 0 || !fp)
			return 0;
		if (fseek(fp, 0, SEEK_END) != 0)
		{
			fclose(fp);
			return 0;
		}
		const long sz = ftell(fp);
		if (sz <= 0)
		{
			fclose(fp);
			return 0;
		}
		rewind(fp);
		std::vector<unsigned char> file((size_t)sz);
		const size_t got = fread(file.data(), 1, (size_t)sz, fp);
		fclose(fp);
		if (got != (size_t)sz)
			return 0;
		int w = 0, h = 0, comp = 0;
		unsigned char* data = stbi_load_from_memory(file.data(), (int)sz, &w, &h, &comp, 4);
		if (!data)
			return 0;
		UserTex t;
		t.path = path;
		t.key = key;
		t.w = w;
		t.h = h;
		t.pixels.assign(data, data + (size_t)w * (size_t)h * 4u);
		stbi_image_free(data);
		EnsureTexGpu(t);
		m_userTex.push_back(std::move(t));
		const int id = (int)m_userTex.size();
		m_texByPath[key] = id;
		return id;
	}

	private:
	ID3D11ShaderResourceView* SrvForTex(int texId)
	{
		if (texId == kFxDotTex)
			return m_fxDotSRV ? m_fxDotSRV : m_whiteSRV;
		std::lock_guard<std::mutex> lock(m_texMtx);
		if (texId > 0 && texId <= (int)m_userTex.size())
		{
			UserTex& t = m_userTex[(size_t)texId - 1];
			if (EnsureTexGpu(t) && t.srv)
				return t.srv;
		}
		return m_whiteSRV;
	}

	void DrawSpritesEx(ID3D11DeviceContext* ctx, const std::vector<CanvasSpriteExInst>& items,
		float vpW, float vpH)
	{
		if (items.empty() || !m_spriteExVB || !m_vsSpriteEx || !m_psSpriteTex)
			return;
		int remaining = (int)items.size();
		int src = 0;
		while (remaining > 0)
		{
			const auto& first = items[(size_t)src];
			const int texId = first.tex_id;
			const bool add = (first.mode & kFlagAdditive) != 0;
			int n = 0;
			while (n < remaining && n < kMaxSprites)
			{
				const auto& s = items[(size_t)(src + n)];
				if (s.tex_id != texId || ((s.mode & kFlagAdditive) != 0) != add)
					break;
				++n;
			}

			D3D11_MAPPED_SUBRESOURCE mapped{};
			if (FAILED(ctx->Map(m_spriteExVB, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped)) || !mapped.pData)
				break;
			auto* dst = static_cast<SpriteExGPU*>(mapped.pData);
			for (int i = 0; i < n; ++i)
			{
				const auto& s = items[(size_t)(src + i)];
				dst[i] = { s.x, s.y, s.sx, s.sy, s.r, s.g, s.b, s.a, s.angle, 0.f, 0.f, 0.f };
			}
			ctx->Unmap(m_spriteExVB, 0);

			CB cb{};
			cb.vpW = vpW;
			cb.vpH = vpH;
			cb.strength = 1.f;
			UpdateCB(ctx, cb);

			ID3D11Buffer* vbs[2] = { m_cornerVB, m_spriteExVB };
			UINT strides[2] = { sizeof(float) * 2, sizeof(SpriteExGPU) };
			UINT offsets[2] = { 0, 0 };
			const float bf[4] = { 0, 0, 0, 0 };
			ID3D11ShaderResourceView* srv = SrvForTex(texId);
			ctx->IASetInputLayout(m_layoutSpriteEx);
			ctx->IASetVertexBuffers(0, 2, vbs, strides, offsets);
			ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
			ctx->VSSetShader(m_vsSpriteEx, nullptr, 0);
			ctx->VSSetConstantBuffers(0, 1, &m_cb);
			ctx->PSSetShader(m_psSpriteTex, nullptr, 0);
			ctx->PSSetSamplers(0, 1, &m_samp);
			ctx->PSSetConstantBuffers(0, 1, &m_cb);
			ctx->PSSetShaderResources(0, 1, &srv);
			ctx->OMSetBlendState(add ? m_blendAdd : m_blendAlpha, bf, 0xFFFFFFFF);
			ctx->OMSetDepthStencilState(m_dss, 0);
			ctx->DrawInstanced(6, (UINT)n, 0, 0);
			ID3D11ShaderResourceView* none = nullptr;
			ctx->PSSetShaderResources(0, 1, &none);

			src += n;
			remaining -= n;
		}
	}

	void BlitInternal(ID3D11DeviceContext* ctx, ID3D11ShaderResourceView* src,
		int destW, int destH, int /*srcW*/, int /*srcH*/, float strength, bool additive, bool downsample)
	{
		D3D11_VIEWPORT vp{};
		vp.Width = (float)destW;
		vp.Height = (float)destH;
		vp.MaxDepth = 1.f;
		ctx->RSSetViewports(1, &vp);
		D3D11_RECT full{ 0, 0, destW, destH };
		ctx->RSSetScissorRects(1, &full);

		CB cb{};
		cb.vpW = (float)destW;
		cb.vpH = (float)destH;
		cb.texelX = 1.f / (float)destW;
		cb.texelY = 1.f / (float)destH;
		cb.strength = strength;
		UpdateCB(ctx, cb);
		BindColor(ctx, m_vs, m_layout, downsample ? m_psDown : m_psTex, additive ? m_blendAdd : m_blendAlpha);
		CanvasGpuVert quad[6];
		FillBlit(quad, 0, 0, (float)destW, (float)destH, 0xFFFFFFFFu);
		UploadRaw(ctx, quad, 6);
		ctx->PSSetShaderResources(0, 1, &src);
		ctx->Draw(6, 0);
		ID3D11ShaderResourceView* none = nullptr;
		ctx->PSSetShaderResources(0, 1, &none);
	}

	void Blur(ID3D11DeviceContext* ctx, RT& src, RT& tmp)
	{
		const float clear0[4] = { 0, 0, 0, 0 };
		for (int pass = 0; pass < 2; ++pass)
		{
			RT& from = (pass == 0) ? src : tmp;
			RT& to = (pass == 0) ? tmp : src;
			ctx->OMSetRenderTargets(1, &to.rtv, nullptr);
			ctx->ClearRenderTargetView(to.rtv, clear0);
			D3D11_VIEWPORT vp{};
			vp.Width = (float)to.w;
			vp.Height = (float)to.h;
			vp.MaxDepth = 1.f;
			ctx->RSSetViewports(1, &vp);
			D3D11_RECT full{ 0, 0, to.w, to.h };
			ctx->RSSetScissorRects(1, &full);

			CB cb{};
			cb.vpW = (float)to.w;
			cb.vpH = (float)to.h;
			cb.texelX = 1.f / (float)from.w;
			cb.texelY = 1.f / (float)from.h;
			cb.dirX = (pass == 0) ? 1.f : 0.f;
			cb.dirY = (pass == 0) ? 0.f : 1.f;
			cb.strength = 1.f;
			UpdateCB(ctx, cb);
			BindColor(ctx, m_vs, m_layout, m_psBlur, m_blendAlpha);
			CanvasGpuVert quad[6];
			FillBlit(quad, 0, 0, (float)to.w, (float)to.h, 0xFFFFFFFFu);
			UploadRaw(ctx, quad, 6);
			ctx->PSSetShaderResources(0, 1, &from.srv);
			ctx->Draw(6, 0);
			ID3D11ShaderResourceView* none = nullptr;
			ctx->PSSetShaderResources(0, 1, &none);
		}
	}

	void ApplyBloom(ID3D11DeviceContext* ctx, ID3D11Device* dev, DXGI_FORMAT fmt,
		int iw, int ih, float strength, const float* capsX = nullptr)
	{
		int w = iw, h = ih;
		for (int i = 0; i < 3; ++i)
		{
			w = std::max(2, w / 2);
			h = std::max(2, h / 2);
			if (!m_cur->bloomA[i].Ensure(dev, w, h, fmt) || !m_cur->bloomB[i].Ensure(dev, w, h, fmt))
				return;
		}

		const float clear0[4] = { 0, 0, 0, 0 };
		ctx->OMSetRenderTargets(1, &m_cur->bloomA[0].rtv, nullptr);
		ctx->ClearRenderTargetView(m_cur->bloomA[0].rtv, clear0);
		BlitInternal(ctx, m_cur->scene.srv, m_cur->bloomA[0].w, m_cur->bloomA[0].h, iw, ih, 1.f, false, true);
		Blur(ctx, m_cur->bloomA[0], m_cur->bloomB[0]);

		for (int i = 1; i < 3; ++i)
		{
			ctx->OMSetRenderTargets(1, &m_cur->bloomA[i].rtv, nullptr);
			ctx->ClearRenderTargetView(m_cur->bloomA[i].rtv, clear0);
			BlitInternal(ctx, m_cur->bloomA[i - 1].srv, m_cur->bloomA[i].w, m_cur->bloomA[i].h,
				m_cur->bloomA[i - 1].w, m_cur->bloomA[i - 1].h, 1.f, false, true);
			Blur(ctx, m_cur->bloomA[i], m_cur->bloomB[i]);
		}

		for (int i = 2; i > 0; --i)
		{
			ctx->OMSetRenderTargets(1, &m_cur->bloomA[i - 1].rtv, nullptr);
			BlitInternal(ctx, m_cur->bloomA[i].srv, m_cur->bloomA[i - 1].w, m_cur->bloomA[i - 1].h,
				m_cur->bloomA[i].w, m_cur->bloomA[i].h, 1.f, true, false);
		}

		BindScene(ctx, iw, ih);
		if (capsX && BloomMaskedAdd(ctx, m_cur->bloomA[0].srv, iw, ih, strength, capsX))
			return;
		BlitInternal(ctx, m_cur->bloomA[0].srv, iw, ih, m_cur->bloomA[0].w, m_cur->bloomA[0].h,
			strength, true, false);
	}

	// Stage 3: final bloom add with the canvas body capsule mask (ps_bloom_mask). false = not available,
	// caller does the plain add (old behaviour).
	bool BloomMaskedAdd(ID3D11DeviceContext* ctx, ID3D11ShaderResourceView* src, int iw, int ih, float strength, const float* capsX)
	{
		if (!EnsureFx(m_dev) || !m_psBloomMask || !m_fxCB || !src)
			return false;
		D3D11_VIEWPORT vp{};
		vp.Width = (float)iw;
		vp.Height = (float)ih;
		vp.MaxDepth = 1.f;
		ctx->RSSetViewports(1, &vp);
		D3D11_RECT full{ 0, 0, iw, ih };
		ctx->RSSetScissorRects(1, &full);
		CB cb{};
		cb.vpW = (float)iw;
		cb.vpH = (float)ih;
		cb.texelX = 1.f / (float)iw;
		cb.texelY = 1.f / (float)ih;
		cb.strength = strength;
		UpdateCB(ctx, cb);
		fx::FxCB fcb{};
		std::memcpy(fcb.X, capsX, sizeof(float) * 16);
		fcb.S2[0] = (float)iw; fcb.S2[1] = (float)ih; fcb.S2[2] = 0.f; fcb.S2[3] = strength;
		D3D11_MAPPED_SUBRESOURCE mapped{};
		if (FAILED(ctx->Map(m_fxCB, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped)) || !mapped.pData)
			return false;
		std::memcpy(mapped.pData, &fcb, sizeof(fcb));
		ctx->Unmap(m_fxCB, 0);
		BindColor(ctx, m_vs, m_layout, m_psBloomMask, m_blendAdd);
		ctx->PSSetConstantBuffers(1, 1, &m_fxCB);
		CanvasGpuVert quad[6];
		FillBlit(quad, 0, 0, (float)iw, (float)ih, 0xFFFFFFFFu);
		UploadRaw(ctx, quad, 6);
		ctx->PSSetShaderResources(0, 1, &src);
		ctx->Draw(6, 0);
		ID3D11ShaderResourceView* none = nullptr;
		ctx->PSSetShaderResources(0, 1, &none);
		ID3D11Buffer* noCb = nullptr;
		ctx->PSSetConstantBuffers(1, 1, &noCb);
		if (m_bloomMasked == 0)
			ProbeLogf("fx bloom mask active (bloom composited with the canvas body capsule; strength=%.3f)", strength);
		++m_bloomMasked;
		return true;
	}

	// ---- Stage 1 particles -------------------------------------------------------------------------
	void ReleaseFx()
	{
		Rel(m_vsFx); Rel(m_psFx); Rel(m_fxCB); Rel(m_fxDotSRV); Rel(m_fxDotTex); Rel(m_psBloomMask);
		m_fxTried = false;
		m_fxOk = false;
		ReleaseTfx();
	}

	// ---- TextFX (CombatFX theme numbers) -------------------------------------------------------------
	struct TfxCB { float S0[4]; float S1[4]; float X[16]; };
	static constexpr UINT kTfxMaxGlyphs = 4096, kTfxMaxStyles = 512, kTfxMaxParts = 512;

	void ReleaseTfx()
	{
		Rel(m_vsTfxG); Rel(m_psTfxG); Rel(m_vsTfxP); Rel(m_psTfxP); Rel(m_tfxCB);
		Rel(m_tfxGlyphSRV); Rel(m_tfxGlyphBuf); Rel(m_tfxStyleSRV); Rel(m_tfxStyleBuf); Rel(m_tfxPartSRV); Rel(m_tfxPartBuf);
		Rel(m_tfxAtlasSRV); Rel(m_tfxAtlasTex);
		m_tfxTried = false;
		m_tfxOk = false;
	}

	bool MakeStructured(ID3D11Device* dev, UINT stride, UINT count, ID3D11Buffer** buf, ID3D11ShaderResourceView** srv)
	{
		D3D11_BUFFER_DESC bd{};
		bd.ByteWidth = stride * count;
		bd.Usage = D3D11_USAGE_DYNAMIC;
		bd.BindFlags = D3D11_BIND_SHADER_RESOURCE;
		bd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
		bd.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;
		bd.StructureByteStride = stride;
		if (FAILED(dev->CreateBuffer(&bd, nullptr, buf)))
			return false;
		D3D11_SHADER_RESOURCE_VIEW_DESC vd{};
		vd.Format = DXGI_FORMAT_UNKNOWN;
		vd.ViewDimension = D3D11_SRV_DIMENSION_BUFFER;
		vd.Buffer.FirstElement = 0;
		vd.Buffer.NumElements = count;
		return SUCCEEDED(dev->CreateShaderResourceView(*buf, &vd, srv));
	}

	bool EnsureTfx(ID3D11Device* dev)
	{
		if (!m_tfxTried)
		{
			m_tfxTried = true;
			m_tfxOk = false;
			if (!dev || dev->GetFeatureLevel() < D3D_FEATURE_LEVEL_11_0)
			{
				ProbeLogf("tfx off: feature level < 11_0");
				Tfx_SetGpuState(-1);
				return false;
			}
			D3D11_BUFFER_DESC cbd{};
			cbd.ByteWidth = sizeof(TfxCB);
			cbd.Usage = D3D11_USAGE_DYNAMIC;
			cbd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
			cbd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
			bool ok = SUCCEEDED(dev->CreateVertexShader(kBC_vs_tfx_glyph, kBC_vs_tfx_glyph_len, nullptr, &m_vsTfxG))
				&& SUCCEEDED(dev->CreatePixelShader(kBC_ps_tfx_glyph, kBC_ps_tfx_glyph_len, nullptr, &m_psTfxG))
				&& SUCCEEDED(dev->CreateVertexShader(kBC_vs_tfx_part, kBC_vs_tfx_part_len, nullptr, &m_vsTfxP))
				&& SUCCEEDED(dev->CreatePixelShader(kBC_ps_tfx_part, kBC_ps_tfx_part_len, nullptr, &m_psTfxP))
				&& SUCCEEDED(dev->CreateBuffer(&cbd, nullptr, &m_tfxCB))
				&& MakeStructured(dev, sizeof(tfx::GlyphGPU), kTfxMaxGlyphs, &m_tfxGlyphBuf, &m_tfxGlyphSRV)
				&& MakeStructured(dev, sizeof(tfx::StyleGPU), kTfxMaxStyles, &m_tfxStyleBuf, &m_tfxStyleSRV)
				&& MakeStructured(dev, sizeof(tfx::PartGPU), kTfxMaxParts, &m_tfxPartBuf, &m_tfxPartSRV);
			if (!ok)
			{
				ProbeLogf("tfx off: shader/buffer create failed");
				ReleaseTfx();
				m_tfxTried = true;
				Tfx_SetGpuState(-1);
				return false;
			}
			ProbeLogf("tfx gpu path ready (vs_5_0/ps_5_0 SDF text + stateless number particles)");
			Tfx_SetGpuState(1);
			m_tfxOk = true;
		}
		if (m_tfxOk && !m_tfxAtlasSRV)
		{
			const tfx::Atlas* A = Tfx_Atlas();
			if (A && A->ready && A->px.size() == (size_t)tfx::kAtlasW * tfx::kAtlasH)
			{
				D3D11_TEXTURE2D_DESC td{};
				td.Width = tfx::kAtlasW; td.Height = tfx::kAtlasH;
				td.MipLevels = 1; td.ArraySize = 1;
				td.Format = DXGI_FORMAT_R8_UNORM;
				td.SampleDesc.Count = 1;
				td.Usage = D3D11_USAGE_IMMUTABLE;
				td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
				D3D11_SUBRESOURCE_DATA sd{ A->px.data(), (UINT)tfx::kAtlasW, 0 };
				if (FAILED(dev->CreateTexture2D(&td, &sd, &m_tfxAtlasTex)) || FAILED(dev->CreateShaderResourceView(m_tfxAtlasTex, nullptr, &m_tfxAtlasSRV)))
				{
					Rel(m_tfxAtlasSRV); Rel(m_tfxAtlasTex);
				}
			}
		}
		return m_tfxOk && m_tfxAtlasSRV;
	}

	template <typename T>
	bool Upload(ID3D11DeviceContext* ctx, ID3D11Buffer* buf, const std::vector<T>& v, UINT maxN, UINT& n)
	{
		n = (UINT)std::min<size_t>(v.size(), maxN);
		if (!n) return true;
		D3D11_MAPPED_SUBRESOURCE m{};
		if (FAILED(ctx->Map(buf, 0, D3D11_MAP_WRITE_DISCARD, 0, &m)) || !m.pData) { n = 0; return false; }
		std::memcpy(m.pData, v.data(), sizeof(T) * n);
		ctx->Unmap(buf, 0);
		return true;
	}

	// which: 1 = particles (before bloom), 2 = glyphs (after bloom), 3 = both
	bool DrawTfx(ID3D11DeviceContext* ctx, const TextFxDraw& d, int iw, int ih, int which = 3)
	{
		if (!EnsureTfx(m_dev))
			return false;
		UINT ng = 0, ns = 0, np = 0;
		if (!Upload(ctx, m_tfxGlyphBuf, d.f.glyphs, kTfxMaxGlyphs, ng) || !Upload(ctx, m_tfxStyleBuf, d.f.styles, kTfxMaxStyles, ns)
			|| !Upload(ctx, m_tfxPartBuf, d.f.parts, kTfxMaxParts, np))
			return false;
		TfxCB cb{};
		cb.S0[0] = (float)iw; cb.S0[1] = (float)ih; cb.S0[2] = (float)tfx::kAtlasW; cb.S0[3] = (float)tfx::kAtlasH;
		cb.S1[0] = (float)std::fmod(d.clock, 1000.0); cb.S1[1] = (float)ng; cb.S1[2] = (float)np;
		if (d.hasCaps)
			std::memcpy(cb.X, d.caps, sizeof(cb.X));
		D3D11_MAPPED_SUBRESOURCE mapped{};
		if (FAILED(ctx->Map(m_tfxCB, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped)) || !mapped.pData)
			return false;
		std::memcpy(mapped.pData, &cb, sizeof(cb));
		ctx->Unmap(m_tfxCB, 0);

		const float bf[4] = { 0, 0, 0, 0 };
		ID3D11Buffer* noVB[2] = { nullptr, nullptr };
		UINT zero[2] = { 0, 0 };
		ctx->IASetInputLayout(nullptr);
		ctx->IASetVertexBuffers(0, 2, noVB, zero, zero);
		ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
		ctx->VSSetConstantBuffers(1, 1, &m_tfxCB);
		ctx->PSSetConstantBuffers(1, 1, &m_tfxCB);
		ctx->OMSetBlendState(m_blendAlpha, bf, 0xFFFFFFFF);    // premultiplied; alpha 0 = additive light
		ctx->OMSetDepthStencilState(m_dss, 0);
		ctx->PSSetSamplers(0, 1, &m_samp);
		ID3D11ShaderResourceView* none2[2] = { nullptr, nullptr };

		if (!(which & 1)) np = 0;
		if (!(which & 2)) ng = 0;
		if (np)   // particles behind the digits
		{
			ctx->VSSetShader(m_vsTfxP, nullptr, 0);
			ctx->PSSetShader(m_psTfxP, nullptr, 0);
			ctx->VSSetShaderResources(0, 1, &m_tfxPartSRV);
			ctx->DrawInstanced(6, np * (UINT)tfx::kPartBudget, 0, 0);
			ctx->VSSetShaderResources(0, 2, none2);
		}
		if (ng && ns)
		{
			ID3D11ShaderResourceView* vsr[2] = { m_tfxGlyphSRV, m_tfxStyleSRV };
			ID3D11ShaderResourceView* psr[2] = { m_tfxAtlasSRV, m_tfxStyleSRV };
			ctx->VSSetShader(m_vsTfxG, nullptr, 0);
			ctx->PSSetShader(m_psTfxG, nullptr, 0);
			ctx->VSSetShaderResources(0, 2, vsr);
			ctx->PSSetShaderResources(0, 2, psr);
			ctx->DrawInstanced(6, ng, 0, 0);
			ctx->VSSetShaderResources(0, 2, none2);
			ctx->PSSetShaderResources(0, 2, none2);
		}
		ID3D11Buffer* noCb = nullptr;
		ctx->VSSetConstantBuffers(1, 1, &noCb);
		ctx->PSSetConstantBuffers(1, 1, &noCb);
		return true;
	}

	ID3D11VertexShader* m_vsTfxG = nullptr;
	ID3D11PixelShader* m_psTfxG = nullptr;
	ID3D11VertexShader* m_vsTfxP = nullptr;
	ID3D11PixelShader* m_psTfxP = nullptr;
	ID3D11Buffer* m_tfxCB = nullptr;
	ID3D11Buffer* m_tfxGlyphBuf = nullptr;
	ID3D11ShaderResourceView* m_tfxGlyphSRV = nullptr;
	ID3D11Buffer* m_tfxStyleBuf = nullptr;
	ID3D11ShaderResourceView* m_tfxStyleSRV = nullptr;
	ID3D11Buffer* m_tfxPartBuf = nullptr;
	ID3D11ShaderResourceView* m_tfxPartSRV = nullptr;
	ID3D11Texture2D* m_tfxAtlasTex = nullptr;
	ID3D11ShaderResourceView* m_tfxAtlasSRV = nullptr;
	bool m_tfxTried = false;
	bool m_tfxOk = false;

	// Lazily (re)created after Ensure/device loss. The soft-dot texture is shared by both paths; the
	// vs_5_0/ps_5_0 pair needs feature level 11_0 - without it (or if creation fails) fx use the CPU fallback.
	bool EnsureFx(ID3D11Device* dev)
	{
		if (m_fxTried)
			return m_fxOk;
		m_fxTried = true;
		m_fxOk = false;
		if (!dev)
			return false;
		if (!m_fxDotSRV)
		{
			const int N = 64;
			std::vector<unsigned char> px((size_t)N * N * 4);
			for (int y = 0; y < N; ++y)
				for (int x = 0; x < N; ++x)
				{
					const float dx = ((float)x + 0.5f) / (N * 0.5f) - 1.f, dy = ((float)y + 0.5f) / (N * 0.5f) - 1.f;
					float a = 1.f - std::sqrt(dx * dx + dy * dy);
					a = a < 0.f ? 0.f : a;
					a = a * a * (0.35f + 0.65f * a);
					unsigned char* p = &px[((size_t)y * N + x) * 4];
					p[0] = p[1] = p[2] = 255;
					p[3] = (unsigned char)(a * 255.f + 0.5f);
				}
			D3D11_TEXTURE2D_DESC td{};
			td.Width = td.Height = (UINT)N;
			td.MipLevels = 1; td.ArraySize = 1;
			td.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
			td.SampleDesc.Count = 1;
			td.Usage = D3D11_USAGE_IMMUTABLE;
			td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
			D3D11_SUBRESOURCE_DATA sd{ px.data(), (UINT)(N * 4), 0 };
			if (FAILED(dev->CreateTexture2D(&td, &sd, &m_fxDotTex)) || FAILED(dev->CreateShaderResourceView(m_fxDotTex, nullptr, &m_fxDotSRV)))
			{
				Rel(m_fxDotSRV); Rel(m_fxDotTex);
			}
		}
		if (dev->GetFeatureLevel() < D3D_FEATURE_LEVEL_11_0)
		{
			ProbeLogf("fx gpu path off: feature level 0x%x < 11_0, using CPU fallback", (unsigned)dev->GetFeatureLevel());
			return false;
		}
		D3D11_BUFFER_DESC cbd{};
		cbd.ByteWidth = sizeof(fx::FxCB);
		cbd.Usage = D3D11_USAGE_DYNAMIC;
		cbd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
		cbd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
		const HRESULT h1 = dev->CreateVertexShader(kBC_vs_fx, kBC_vs_fx_len, nullptr, &m_vsFx);
		const HRESULT h2 = SUCCEEDED(h1) ? dev->CreatePixelShader(kBC_ps_fx, kBC_ps_fx_len, nullptr, &m_psFx) : h1;
		const HRESULT h3 = SUCCEEDED(h2) ? dev->CreateBuffer(&cbd, nullptr, &m_fxCB) : h2;
		if (SUCCEEDED(h3) && FAILED(dev->CreatePixelShader(kBC_ps_bloom_mask, kBC_ps_bloom_mask_len, nullptr, &m_psBloomMask)))
			ProbeLogf("fx bloom mask shader create failed: bloom stays unmasked");
		if (FAILED(h3))
		{
			ProbeLogf("fx gpu path off: create failed hr=0x%08lx, using CPU fallback", (unsigned long)h3);
			Rel(m_vsFx); Rel(m_psFx); Rel(m_fxCB); Rel(m_psBloomMask);
			return false;
		}
		ProbeLogf("fx gpu path ready (vs_5_0/ps_5_0 formula emitter, cb=%u bytes)", (unsigned)sizeof(fx::FxCB));
		m_fxOk = true;
		return true;
	}

	void DrawFx(ID3D11DeviceContext* ctx, const std::vector<CanvasFxDraw>& list, int iw, int ih)
	{
		const bool gpu = EnsureFx(m_dev) && !Fx_ForceCpu();
		m_fxMode = gpu ? 2 : 1;
		std::vector<CanvasSpriteExInst> cpuItems;
		const float bf[4] = { 0, 0, 0, 0 };
		for (const CanvasFxDraw& e : list)
		{
			if (!e.instances)
				continue;
			fx::FxCB cb = e.cb;
			cb.S2[0] = (float)iw;
			cb.S2[1] = (float)ih;
			const int tex = e.texId > 0 ? e.texId : kFxDotTex;
			if (gpu)
			{
				D3D11_MAPPED_SUBRESOURCE mapped{};
				if (FAILED(ctx->Map(m_fxCB, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped)) || !mapped.pData)
					continue;
				std::memcpy(mapped.pData, &cb, sizeof(cb));
				ctx->Unmap(m_fxCB, 0);
				ID3D11Buffer* noVB[2] = { nullptr, nullptr };
				UINT zero[2] = { 0, 0 };
				ctx->IASetInputLayout(nullptr);              // vs_fx reads only SV_VertexID / SV_InstanceID
				ctx->IASetVertexBuffers(0, 2, noVB, zero, zero);
				ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
				ctx->VSSetShader(m_vsFx, nullptr, 0);
				ctx->VSSetConstantBuffers(1, 1, &m_fxCB);
				ctx->PSSetShader(m_psFx, nullptr, 0);
				ctx->PSSetConstantBuffers(1, 1, &m_fxCB);
				ID3D11ShaderResourceView* srv = SrvForTex(tex);
				ctx->PSSetShaderResources(0, 1, &srv);
				ctx->PSSetSamplers(0, 1, &m_samp);
				ctx->OMSetBlendState(e.additive ? m_blendAdd : m_blendAlpha, bf, 0xFFFFFFFF);
				ctx->OMSetDepthStencilState(m_dss, 0);
				ctx->DrawInstanced(6, e.instances, 0, 0);
				ID3D11ShaderResourceView* none = nullptr;
				ctx->PSSetShaderResources(0, 1, &none);
			}
			else
			{
				// CPU fallback: same formula (FxSim.h), capsule applied per particle centre, drawn as sprites_ex
				fx::FxOut o{};
				for (uint32_t i = 0; i < e.instances; ++i)
				{
					if (!fx::FxEval(cb, i, o) || o.a <= 0.0005f || (o.hx <= 0.f && o.hy <= 0.f))
						continue;
					const float m = fx::CapsuleMask(cb.X, o.cx, o.cy);
					if (m <= 0.f)
						continue;
					CanvasSpriteExInst s;
					s.x = o.cx; s.y = o.cy; s.sx = o.hx; s.sy = o.hy; s.angle = o.rot;
					s.r = o.r; s.g = o.g; s.b = o.b; s.a = o.a * m;
					s.tex_id = tex;
					s.mode = e.additive ? kFlagAdditive : 0;
					cpuItems.push_back(s);
				}
			}
		}
		if (!cpuItems.empty())
			DrawSpritesEx(ctx, cpuItems, (float)iw, (float)ih);
		ID3D11Buffer* noCb = nullptr;
		ctx->VSSetConstantBuffers(1, 1, &noCb);
		ctx->PSSetConstantBuffers(1, 1, &noCb);
	}

	ID3D11VertexShader* m_vsFx = nullptr;
	ID3D11PixelShader* m_psFx = nullptr;
	ID3D11PixelShader* m_psBloomMask = nullptr;   // Stage 3
	unsigned long long m_bloomMasked = 0;
	ID3D11Buffer* m_fxCB = nullptr;
	ID3D11Texture2D* m_fxDotTex = nullptr;
	ID3D11ShaderResourceView* m_fxDotSRV = nullptr;
	bool m_fxTried = false;
	bool m_fxOk = false;
	int m_fxMode = 0;

	ID3D11Device* m_dev = nullptr;
	ID3D11Buffer* m_vb = nullptr;
	ID3D11Buffer* m_cb = nullptr;
	ID3D11Buffer* m_cornerVB = nullptr;
	ID3D11Buffer* m_spriteVB = nullptr;
	ID3D11Buffer* m_spriteExVB = nullptr;
	ID3D11InputLayout* m_layout = nullptr;
	ID3D11InputLayout* m_layoutSprite = nullptr;
	ID3D11InputLayout* m_layoutSpriteEx = nullptr;
	ID3D11VertexShader* m_vs = nullptr;
	ID3D11VertexShader* m_vsSprite = nullptr;
	ID3D11VertexShader* m_vsSpriteEx = nullptr;
	ID3D11PixelShader* m_psColor = nullptr;
	ID3D11PixelShader* m_psBlur = nullptr;
	ID3D11PixelShader* m_psTex = nullptr;
	ID3D11PixelShader* m_psDown = nullptr;
	ID3D11PixelShader* m_psBg = nullptr;
	ID3D11PixelShader* m_psSprite = nullptr;
	ID3D11PixelShader* m_psSpriteSq = nullptr;
	ID3D11PixelShader* m_psSpriteTex = nullptr;
	ID3D11PixelShader* m_psComposite = nullptr;
	ID3D11BlendState* m_blendAlpha = nullptr;
	ID3D11BlendState* m_blendAdd = nullptr;
	ID3D11RasterizerState* m_rs = nullptr;
	ID3D11RasterizerState* m_rsNoScissor = nullptr;
	ID3D11DepthStencilState* m_dss = nullptr;
	ID3D11SamplerState* m_samp = nullptr;
	ID3D11Texture2D* m_whiteTex = nullptr;
	ID3D11ShaderResourceView* m_whiteSRV = nullptr;
	std::mutex m_texMtx;
	std::vector<UserTex> m_userTex;
	std::unordered_map<std::string, int> m_texByPath;
	std::map<const void*, RTSet> m_sets;
	RTSet m_fallbackSet;
	RTSet* m_cur = &m_fallbackSet;
	unsigned m_featureLevel = 0;

	// GPU timestamp queries (non-blocking, read back a few frames later)
	struct QSet { ID3D11Query* disjoint = nullptr; ID3D11Query* ts[9]{}; bool pending = false; bool bloom = false; bool fx = false; bool tfx = false; };
	QSet m_q[16];
	int m_qNext = 0;
	bool m_qOk = true;
	struct PerfWin
	{
		double t0 = 0;
		unsigned long long draws = 0, bloomDraws = 0, rt0 = 0;
		double cpuScene = 0, cpuBloom = 0, cpuComp = 0;
		unsigned long long gpuN = 0, gpuBloomN = 0;
		double gpuScene = 0, gpuBloom = 0, gpuComp = 0;
		unsigned long long fxDraws = 0, gpuFxN = 0;
		double cpuFx = 0, gpuFx = 0;
		unsigned long long gpuTfxN = 0;
		double gpuTfx = 0;
	} m_pw;

	RTSet* AcquireSet(const void* owner, double now)
	{
		if (!owner)
			return &m_fallbackSet;
		auto it = m_sets.find(owner);
		if (it == m_sets.end())
			it = m_sets.emplace(owner, RTSet{}).first;
		RTSet* set = &it->second;
		if (now - set->lastUse > 1000.0)
			set->trailValid = false;            // stale (or a recycled element address): never smear old trails
		set->lastUse = now;
		// evict sets nobody drew for 5 s (destroyed canvases, closed windows); keep at most 32 (tfx1: theme card previews)
		for (auto e = m_sets.begin(); e != m_sets.end();)
		{
			if (&e->second != set && (now - e->second.lastUse > 5000.0 || m_sets.size() > 32))
			{
				e->second.Release();
				e = m_sets.erase(e);
			}
			else
				++e;
		}
		return set;
	}

	void ReleaseQueries()
	{
		for (auto& q : m_q)
		{
			Rel(q.disjoint);
			for (auto& t : q.ts) Rel(t);
			q.pending = false;
		}
		m_qOk = true;
	}

	QSet* BeginQueries(ID3D11DeviceContext* ctx)
	{
		if (!m_qOk || !m_dev)
			return nullptr;
		QSet& q = m_q[m_qNext];
		if (q.pending)
			return nullptr;                     // ring full: skip measuring this draw, never stall
		if (!q.disjoint)
		{
			D3D11_QUERY_DESC qd{ D3D11_QUERY_TIMESTAMP_DISJOINT, 0 };
			D3D11_QUERY_DESC td{ D3D11_QUERY_TIMESTAMP, 0 };
			bool ok = SUCCEEDED(m_dev->CreateQuery(&qd, &q.disjoint));
			for (auto& t : q.ts) ok = ok && SUCCEEDED(m_dev->CreateQuery(&td, &t));
			if (!ok) { ReleaseQueries(); m_qOk = false; return nullptr; }
		}
		m_qNext = (m_qNext + 1) % 16;
		ctx->Begin(q.disjoint);
		ctx->End(q.ts[0]);
		return &q;
	}

	void CollectQueries(ID3D11DeviceContext* ctx)
	{
		for (auto& q : m_q)
		{
			if (!q.pending)
				continue;
			D3D11_QUERY_DATA_TIMESTAMP_DISJOINT dj{};
			if (ctx->GetData(q.disjoint, &dj, sizeof(dj), D3D11_ASYNC_GETDATA_DONOTFLUSH) != S_OK)
				continue;
			UINT64 t[9]{};
			bool ok = true;
			const int nts = q.tfx ? 9 : 5;
			for (int i = 0; i < nts; ++i)
				ok = ok && ctx->GetData(q.ts[i], &t[i], sizeof(UINT64), D3D11_ASYNC_GETDATA_DONOTFLUSH) == S_OK;
			if (!ok)
				continue;
			q.pending = false;
			if (dj.Disjoint || dj.Frequency == 0)
				continue;
			const double k = 1000.0 / (double)dj.Frequency;
			m_pw.gpuScene += (double)(t[1] - t[0]) * k;
			m_pw.gpuBloom += (double)(t[2] - t[1]) * k;
			m_pw.gpuComp += (double)(t[3] - t[2]) * k;
			++m_pw.gpuN;
			if (q.bloom) ++m_pw.gpuBloomN;
			if (q.fx) { m_pw.gpuFx += (double)((q.tfx ? t[5] : t[1]) - t[4]) * k; ++m_pw.gpuFxN; }
			if (q.tfx) { m_pw.gpuTfx += (double)((t[6] - t[5]) + (t[8] - t[7])) * k; ++m_pw.gpuTfxN; }   // particles + glyphs
		}
	}

	void AccumulatePerf(double sceneMs, double bloomMs, double compMs, bool bloom, double now, bool fxDrawn, double fxCpuMs)
	{
		PerfWin& w = m_pw;
		if (w.t0 == 0) { w.t0 = now; w.rt0 = g_rtCreates; }
		++w.draws;
		if (bloom) ++w.bloomDraws;
		if (fxDrawn) { ++w.fxDraws; w.cpuFx += fxCpuMs; }
		w.cpuScene += sceneMs; w.cpuBloom += bloomMs; w.cpuComp += compMs;
		const double dur = now - w.t0;
		if (dur < 5000.0)
			return;
		unsigned long long bytes = m_fallbackSet.Bytes();
		for (const auto& kv : m_sets) bytes += kv.second.Bytes();
		const double n = (double)w.draws, gn = w.gpuN ? (double)w.gpuN : 1.0;
		const FxTotals ft = Fx_Totals();
		CanvasFxPerfInfo fp;
		fp.mode = w.fxDraws ? m_fxMode : 0;
		fp.cpuMs = w.fxDraws ? w.cpuFx / (double)w.fxDraws : 0.0;
		fp.gpuMs = w.gpuFxN ? w.gpuFx / (double)w.gpuFxN : -1.0;
		fp.draws = w.fxDraws;
		char line[1024];
		int ln = snprintf(line, sizeof(line),
			"perf %.1fs draws=%llu (%.0f/s) bloom=%llu fl=0x%x | cpu ms/draw scene=%.3f bloom=%.3f comp=%.3f"
			" | gpu ms/draw scene=%.3f bloom=%.3f comp=%.3f (n=%llu) | rt_creates=%llu (%.2f/s) sets=%d rt_mb=%.1f",
			dur / 1000.0, w.draws, n * 1000.0 / dur, w.bloomDraws, m_featureLevel,
			w.cpuScene / n, w.cpuBloom / n, w.cpuComp / n,
			w.gpuN ? w.gpuScene / gn : -1.0, w.gpuN ? w.gpuBloom / gn : -1.0, w.gpuN ? w.gpuComp / gn : -1.0, w.gpuN,
			g_rtCreates - w.rt0, (double)(g_rtCreates - w.rt0) * 1000.0 / dur, (int)m_sets.size(), (double)bytes / (1024.0 * 1024.0));
		if (ln > 0 && ln < (int)sizeof(line) && (ft.emitters > 0 || w.fxDraws > 0))
			snprintf(line + ln, sizeof(line) - (size_t)ln,
				" | fx emitters=%d active=%d alive=%u/%u mode=%s draws=%llu cpu ms/draw=%.3f gpu ms/draw=%.3f",
				ft.emitters, ft.active, ft.alive, ft.instances, fp.mode == 2 ? "gpu" : (fp.mode == 1 ? "cpu" : "none"),
				w.fxDraws, fp.cpuMs, fp.gpuMs);
		{
			const int used = (int)strnlen(line, sizeof(line));
			if (used < (int)sizeof(line) - 8)
				Tfx_PerfSuffix(line + used, (int)sizeof(line) - used, w.gpuTfxN ? w.gpuTfx / (double)w.gpuTfxN : -1.0);
		}
		ProbeLogf("%s", line);
		{
			std::lock_guard<std::mutex> lock(g_perfMtx);
			snprintf(g_perfLine, sizeof(g_perfLine), "%s", line);
			g_fxPerf = fp;
		}
		w = PerfWin{};
		w.t0 = now; w.rt0 = g_rtCreates;
	}
};

CanvasRenderer& CanvasRenderer::Get()
{
	static CanvasRenderer r;
	return r;
}

static CanvasRendererImpl g_impl;

const CanvasDrawDiag& CanvasRenderer::LastDiag()
{
	return g_lastDrawDiag;
}

void CanvasRenderer::OnLostDevice()
{
	g_impl.OnLostDevice();
}

int CanvasRenderer::PerfString(char* out, int cap)
{
	if (!out || cap < 2)
		return 0;
	std::lock_guard<std::mutex> lock(g_perfMtx);
	snprintf(out, (size_t)cap, "%s", g_perfLine);
	return 1;
}

CanvasFxPerfInfo CanvasRenderer::FxPerf()
{
	std::lock_guard<std::mutex> lock(g_perfMtx);
	return g_fxPerf;
}

int CanvasRenderer::LoadTexture(const char* path)
{
	return g_impl.LoadTexture(path);
}

void CanvasRenderer::Draw(const std::vector<CanvasTriBatch>& batches,
	const std::vector<CanvasSpriteBatch>& sprites,
	const std::vector<CanvasSpriteExInst>& spritesEx,
	const CanvasFrame& frame,
	float offsetX, float offsetY, float width, float height, float* lastDrawMs, const void* owner,
	const std::vector<CanvasFxDraw>* fx, const TextFxDraw* tfx)
{
	g_impl.Draw(batches, sprites, spritesEx, frame, offsetX, offsetY, width, height, lastDrawMs, owner, fx, tfx);
}
