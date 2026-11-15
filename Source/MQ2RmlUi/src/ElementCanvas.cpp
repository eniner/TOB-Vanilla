#include <mq/Plugin.h>   // MacroQuest plugin API (MQ2Main, eqlib, PLUGIN_API)
#include <eqlib/graphics/CameraInterface.h>   // CCameraInterface (world-to-screen)
#include "ElementCanvas.h"
#include "CanvasRenderer.h"
#include "FxSystem.h"
#include "TextFx.h"
#include "imgui.h"

#include <RmlUi/Core/Core.h>
#include <RmlUi/Core/ElementInstancer.h>
#include <RmlUi/Core/Factory.h>
#include <RmlUi/Core/Types.h>
#include <RmlUi/Core/ComputedValues.h>

#include <DirectXMath.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <mutex>
#include <vector>

using namespace DirectX;

static constexpr int kMaxVerts = 65536;
static constexpr int kStride = 6; // x,y,r,g,b,a

enum {
	RML_CANVAS_TRIANGLES  = 0,
	RML_CANVAS_QUADS      = 1,
	RML_CANVAS_LINES      = 2,
	RML_CANVAS_LINE_STRIP = 3,
	RML_CANVAS_POLYGON    = 4,
	RML_CANVAS_PRIM_MASK  = 0x000F,
	RML_CANVAS_ADDITIVE   = 0x0100,
	RML_CANVAS_GLOW       = 0x0200,
	RML_CANVAS_FILL       = 0x0400,
};

static double NowSeconds()
{
	static const auto start = std::chrono::steady_clock::now();
	return std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
}

static float clampf(float v, float lo, float hi)
{
	return v < lo ? lo : (v > hi ? hi : v);
}

static uint32_t PackColor(float r, float g, float b, float a)
{
	r = clampf(r, 0.f, 1.f);
	g = clampf(g, 0.f, 1.f);
	b = clampf(b, 0.f, 1.f);
	a = clampf(a, 0.f, 1.f);
	const int R = (int)(r * a * 255.f + 0.5f);
	const int G = (int)(g * a * 255.f + 0.5f);
	const int B = (int)(b * a * 255.f + 0.5f);
	const int A = (int)(a * 255.f + 0.5f);
	return ((uint32_t)A << 24) | ((uint32_t)B << 16) | ((uint32_t)G << 8) | (uint32_t)R;
}

static CanvasGpuVert V(float x, float y, float r, float g, float b, float a)
{
	return { x, y, PackColor(r, g, b, a) };
}

static CanvasGpuVert V6(const float* p)
{
	return V(p[0], p[1], p[2], p[3], p[4], p[5]);
}

static std::mutex g_liveMtx;
static std::vector<std::pair<Rml::Context*, double>> g_live;
static Rml::Element* (*g_find)(const char*, const char*) = nullptr;

void Canvas_SetFindElement(Rml::Element* (*fn)(const char*, const char*))
{
	g_find = fn;
}

void CanvasMarkLive(Rml::Context* ctx)
{
	if (!ctx)
		return;
	const double until = NowSeconds() + 0.40;
	std::lock_guard<std::mutex> lock(g_liveMtx);
	for (auto& e : g_live)
	{
		if (e.first == ctx)
		{
			e.second = until;
			return;
		}
	}
	g_live.push_back({ ctx, until });
}

bool Canvas_ContextWantsPaint(Rml::Context* ctx)
{
	if (!ctx)
		return false;
	const double now = NowSeconds();
	{
		std::lock_guard<std::mutex> lock(g_liveMtx);
		for (const auto& e : g_live)
		{
			if (e.first == ctx && now < e.second)
				return true;
		}
	}
	return Fx_ContextLive(ctx) || Tfx_ContextLive(ctx);   // live particle emitters / TextFX numbers keep their window painting
}

class ElementCanvas final : public Rml::Element
{
public:
	explicit ElementCanvas(const Rml::String& tag) : Rml::Element(tag) {}
	~ElementCanvas() override { Fx_OnCanvasDestroyed(this); Tfx_OnCanvasDestroyed(this); }   // document unload / window close frees emitters + numbers

	void OnRender() override
	{
		Rml::Element::OnRender();
		++m_onRender;
		const Rml::Vector2f offset = GetAbsoluteOffset(Rml::BoxArea::Content);
		const Rml::Vector2f size = GetBox().GetSize(Rml::BoxArea::Content);
		m_rectX = offset.x; m_rectY = offset.y; m_rectW = size.x; m_rectH = size.y;
		if (size.x < 1.f || size.y < 1.f)
		{
			++m_skipSize;
			return;
		}

		std::vector<CanvasTriBatch> draw;
		std::vector<CanvasSpriteBatch> sprites;
		std::vector<CanvasSpriteExInst> spritesEx;
		CanvasFrame frame;
		{
			std::lock_guard<std::mutex> lock(m_mtx);
			draw.swap(m_ready);
			if (draw.empty() && !m_pending.empty())
				draw = m_pending;
			sprites.swap(m_readySprites);
			if (sprites.empty() && !m_pendingSprites.empty())
				sprites = m_pendingSprites;
			spritesEx.swap(m_readySpritesEx);
			if (spritesEx.empty() && !m_pendingSpritesEx.empty())
				spritesEx = m_pendingSpritesEx;
			frame = m_frame;
		}
		m_handedB = (int)draw.size();
		m_handedV = 0;
		for (const auto& b : draw)
			m_handedV += (int)b.verts.size();
		m_handedS = (int)sprites.size();
		m_handedSI = 0;
		for (const auto& s : sprites)
			m_handedSI += (int)s.items.size();
		m_handedSI += (int)spritesEx.size();
		m_handedBg = frame.bgStyle;
		std::vector<CanvasFxDraw> fxDraw;
		Fx_Collect(this, fxDraw);
		TextFxDraw tfxDraw;
		const bool tfxAny = Tfx_Collect(this, tfxDraw) && (!tfxDraw.f.glyphs.empty() || !tfxDraw.f.parts.empty());
		if (draw.empty() && sprites.empty() && spritesEx.empty() && frame.bgStyle <= 0 && fxDraw.empty() && !tfxAny)
		{
			++m_skipEmpty;
			return;
		}
		++m_drawCalled;
		char chain[700];
		int cn = snprintf(chain, sizeof(chain), "opacity");
		for (Rml::Element* e = this; e && cn > 0 && cn < (int)sizeof(chain) - 64; e = e->GetParentNode())
		{
			float op = e->GetComputedValues().opacity();
			const char* tag = e->GetTagName().c_str();
			const char* id = e->GetId().empty() ? "-" : e->GetId().c_str();
			cn += snprintf(chain + cn, sizeof(chain) - (size_t)cn, " %s#%s=%.3f", tag ? tag : "?", id, op);
		}
		CanvasRenderer::SetProbeElementInfo(chain);
		CanvasRenderer::Get().Draw(draw, sprites, spritesEx, frame, offset.x, offset.y, size.x, size.y, &m_lastMs, this,
			fxDraw.empty() ? nullptr : &fxDraw, tfxAny ? &tfxDraw : nullptr);
		m_drawDiag = CanvasRenderer::LastDiag();
	}

	void Clear()
	{
		std::lock_guard<std::mutex> lock(m_mtx);
		m_pending.clear();
		m_ready.clear();
		m_pendingSprites.clear();
		m_readySprites.clear();
		m_pendingSpritesEx.clear();
		m_readySpritesEx.clear();
		m_frame = CanvasFrame{};
	}

	void PushBatch(CanvasTriBatch batch)
	{
		if (batch.verts.empty())
			return;
		std::lock_guard<std::mutex> lock(m_mtx);
		int total = 0;
		for (const auto& b : m_pending)
			total += (int)b.verts.size();
		if (total >= kMaxVerts)
			return;
		const int room = kMaxVerts - total;
		if ((int)batch.verts.size() > room)
			batch.verts.resize((size_t)(room - room % 3));
		if (batch.verts.size() < 3)
			return;
		++m_batchesRecv;
		m_vertsRecv += (uint64_t)batch.verts.size();
		m_pending.push_back(std::move(batch));
		m_ready = m_pending;
		CanvasMarkLive(GetContext());
	}

	void PushSprites(CanvasSpriteBatch batch)
	{
		if (batch.items.empty())
			return;
		std::lock_guard<std::mutex> lock(m_mtx);
		size_t total = 0;
		for (const auto& b : m_pendingSprites)
			total += b.items.size();
		if (total >= 8192)
			return;
		const size_t room = 8192 - total;
		if (batch.items.size() > room)
			batch.items.resize(room);
		if (batch.items.empty())
			return;
		++m_spriteBatchesRecv;
		m_spriteItemsRecv += (uint64_t)batch.items.size();
		m_pendingSprites.push_back(std::move(batch));
		m_readySprites = m_pendingSprites;
		CanvasMarkLive(GetContext());
	}

	void PushSpritesEx(std::vector<CanvasSpriteExInst> items)
	{
		if (items.empty())
			return;
		std::lock_guard<std::mutex> lock(m_mtx);
		const size_t total = m_pendingSpritesEx.size();
		if (total >= 8192)
			return;
		const size_t room = 8192 - total;
		if (items.size() > room)
			items.resize(room);
		if (items.empty())
			return;
		++m_spriteBatchesRecv;
		m_spriteItemsRecv += (uint64_t)items.size();
		m_pendingSpritesEx.insert(m_pendingSpritesEx.end(), items.begin(), items.end());
		m_readySpritesEx = m_pendingSpritesEx;
		CanvasMarkLive(GetContext());
	}

	void SetBg(int style, float time, float energy, float beat)
	{
		std::lock_guard<std::mutex> lock(m_mtx);
		m_frame.bgStyle = style;
		m_frame.bgTime = time;
		m_frame.bgEnergy = energy;
		m_frame.bgBeat = beat;
		CanvasMarkLive(GetContext());
	}

	void SetTrail(float decay)
	{
		std::lock_guard<std::mutex> lock(m_mtx);
		m_frame.trailDecay = decay < 0.f ? 0.f : (decay > 0.98f ? 0.98f : decay);
		CanvasMarkLive(GetContext());
	}

	void SetBloom(float strength)
	{
		std::lock_guard<std::mutex> lock(m_mtx);
		m_frame.bloomStrength = strength < 0.f ? 0.f : strength;
		CanvasMarkLive(GetContext());
	}

	void SetLineWidth(float w) { m_lineWidth = (w < 0.5f) ? 0.5f : w; }
	float LineWidth() const { return m_lineWidth; }
	float LastMs() const { return m_lastMs; }
	void LastRect(float& x, float& y, float& w, float& h) const
	{
		x = m_rectX; y = m_rectY; w = m_rectW; h = m_rectH;
	}

	void FormatStats(char* out, int cap, const char* win) const
	{
		if (!out || cap < 8)
			return;
		const char* ctxName = "?";
		if (Rml::Context* ctx = const_cast<ElementCanvas*>(this)->GetContext())
			ctxName = ctx->GetName().c_str();
		const CanvasDrawDiag& d = m_drawDiag;
		snprintf(out, (size_t)cap,
			"win=%s id=%s ctx=%s onR=%llu skipSz=%llu skipEmpty=%llu draw=%llu "
			"batchesRecv=%llu vertsRecv=%llu sprRecv=%llu sprN=%llu "
			"handedB=%d handedV=%d handedS=%d handedSI=%d bg=%d "
			"reason=%s scene=%dx%d sceneOk=%d "
			"elem=%.1f,%.1f %.1fx%.1f dest=%.1f,%.1f %.1fx%.1f "
			"scissor=%.0f,%.0f,%.0f,%.0f scIn=%d,%d,%d,%d vp=%.0fx%.0f nvp=%d nsc=%d "
			"composite=%d fallback=%d devHR=0x%lX dev=0x%llx mqdev=0x%llx rtv=0x%llx lastMs=%.3f "
			"inBatches=%d inVerts=%d inSpr=%d inSprN=%d",
			win ? win : "?", GetId().c_str(), ctxName ? ctxName : "?",
			(unsigned long long)m_onRender, (unsigned long long)m_skipSize,
			(unsigned long long)m_skipEmpty, (unsigned long long)m_drawCalled,
			(unsigned long long)m_batchesRecv, (unsigned long long)m_vertsRecv,
			(unsigned long long)m_spriteBatchesRecv, (unsigned long long)m_spriteItemsRecv,
			m_handedB, m_handedV, m_handedS, m_handedSI, m_handedBg,
			d.reason, d.sceneW, d.sceneH, d.sceneOk,
			m_rectX, m_rectY, m_rectW, m_rectH, d.destX, d.destY, d.destW, d.destH,
			d.scL, d.scT, d.scR, d.scB, d.scInL, d.scInT, d.scInR, d.scInB,
			d.vpW, d.vpH, d.nvp, d.nsc,
			d.composite, d.fallback, (unsigned long)d.deviceHr,
			(unsigned long long)d.device, (unsigned long long)d.mqDevice,
			(unsigned long long)d.bakRtv, m_lastMs,
			d.batches, d.verts, d.sprites, d.spriteItems);
	}

	Rml::Vector2f ContentSize()
	{
		return GetBox().GetSize(Rml::BoxArea::Content);
	}

private:
	std::mutex m_mtx;
	std::vector<CanvasTriBatch> m_pending;
	std::vector<CanvasTriBatch> m_ready;
	std::vector<CanvasSpriteBatch> m_pendingSprites;
	std::vector<CanvasSpriteBatch> m_readySprites;
	std::vector<CanvasSpriteExInst> m_pendingSpritesEx;
	std::vector<CanvasSpriteExInst> m_readySpritesEx;
	CanvasFrame m_frame;
	float m_lineWidth = 2.f;
	float m_lastMs = 0.f;
	float m_rectX = 0.f, m_rectY = 0.f, m_rectW = 0.f, m_rectH = 0.f;
	uint64_t m_batchesRecv = 0;
	uint64_t m_vertsRecv = 0;
	uint64_t m_spriteBatchesRecv = 0;
	uint64_t m_spriteItemsRecv = 0;
	uint64_t m_onRender = 0;
	uint64_t m_skipSize = 0;
	uint64_t m_skipEmpty = 0;
	uint64_t m_drawCalled = 0;
	int m_handedB = 0, m_handedV = 0, m_handedS = 0, m_handedSI = 0, m_handedBg = 0;
	CanvasDrawDiag m_drawDiag{};
};

class ElementCanvasInstancer final : public Rml::ElementInstancer
{
public:
	Rml::ElementPtr InstanceElement(Rml::Element*, const Rml::String& tag, const Rml::XMLAttributes&) override
	{
		return Rml::ElementPtr(new ElementCanvas(tag));
	}
	void ReleaseElement(Rml::Element* element) override
	{
		delete element;
	}
};

void RegisterCanvasElement()
{
	static ElementCanvasInstancer instancer;
	Rml::Factory::RegisterElementInstancer("canvas", &instancer);
}

void Canvas_OnLostDevice()
{
	CanvasRenderer::Get().OnLostDevice();
}

static ElementCanvas* FindCanvas(const char* win, const char* id)
{
	if (!g_find)
		return nullptr;
	Rml::Element* e = g_find(win, id);
	return dynamic_cast<ElementCanvas*>(e);
}

const void* Canvas_Resolve(const char* win, const char* id, const void** outCtx)
{
	if (outCtx)
		*outCtx = nullptr;
	if (!win || !id)
		return nullptr;
	ElementCanvas* c = FindCanvas(win, id);
	if (c && outCtx)
		*outCtx = c->GetContext();
	return c;
}

static void AddTri(CanvasTriBatch& b, const CanvasGpuVert& a, const CanvasGpuVert& c, const CanvasGpuVert& d)
{
	b.verts.push_back(a);
	b.verts.push_back(c);
	b.verts.push_back(d);
}

static void AddQuad(CanvasTriBatch& b, const CanvasGpuVert& a, const CanvasGpuVert& c,
	const CanvasGpuVert& d, const CanvasGpuVert& e)
{
	AddTri(b, a, c, d);
	AddTri(b, a, d, e);
}

static void EmitThickSegment(CanvasTriBatch& b, float x0, float y0, float x1, float y1,
	float r0, float g0, float b0, float a0,
	float r1, float g1, float b1, float a1, float thickness)
{
	float dx = x1 - x0, dy = y1 - y0;
	const float len = std::sqrt(dx * dx + dy * dy);
	if (len < 1e-4f)
		return;
	dx /= len; dy /= len;
	const float px = -dy * (thickness * 0.5f);
	const float py = dx * (thickness * 0.5f);
	AddQuad(b,
		V(x0 + px, y0 + py, r0, g0, b0, a0),
		V(x1 + px, y1 + py, r1, g1, b1, a1),
		V(x1 - px, y1 - py, r1, g1, b1, a1),
		V(x0 - px, y0 - py, r0, g0, b0, a0));
}

static CanvasTriBatch Tessellate(const float* verts, int count, int mode, float thickness)
{
	CanvasTriBatch batch;
	batch.flags = mode & (RML_CANVAS_ADDITIVE | RML_CANVAS_GLOW);
	if (!verts || count <= 0)
		return batch;
	const int prim = mode & RML_CANVAS_PRIM_MASK;
	if (prim == RML_CANVAS_TRIANGLES)
	{
		const int n = count - count % 3;
		batch.verts.reserve((size_t)n);
		for (int i = 0; i < n; ++i)
			batch.verts.push_back(V6(verts + i * kStride));
	}
	else if (prim == RML_CANVAS_QUADS)
	{
		const int q = count / 4;
		batch.verts.reserve((size_t)q * 6);
		for (int i = 0; i < q; ++i)
		{
			const float* p = verts + i * 4 * kStride;
			AddQuad(batch, V6(p), V6(p + 6), V6(p + 12), V6(p + 18));
		}
	}
	else if (prim == RML_CANVAS_LINES)
	{
		const int n = count / 2;
		batch.verts.reserve((size_t)n * 6);
		for (int i = 0; i < n; ++i)
		{
			const float* a = verts + (i * 2) * kStride;
			const float* c = a + kStride;
			EmitThickSegment(batch, a[0], a[1], c[0], c[1], a[2], a[3], a[4], a[5], c[2], c[3], c[4], c[5], thickness);
		}
	}
	else if (prim == RML_CANVAS_LINE_STRIP)
	{
		if (count >= 2)
		{
			batch.verts.reserve((size_t)(count - 1) * 6);
			for (int i = 0; i < count - 1; ++i)
			{
				const float* a = verts + i * kStride;
				const float* c = a + kStride;
				EmitThickSegment(batch, a[0], a[1], c[0], c[1], a[2], a[3], a[4], a[5], c[2], c[3], c[4], c[5], thickness);
			}
		}
	}
	else if (prim == RML_CANVAS_POLYGON)
	{
		if (count >= 3)
		{
			batch.verts.reserve((size_t)(count - 2) * 3);
			const CanvasGpuVert origin = V6(verts);
			for (int i = 1; i < count - 1; ++i)
				AddTri(batch, origin, V6(verts + i * kStride), V6(verts + (i + 1) * kStride));
		}
	}
	return batch;
}

extern "C" {

PLUGIN_API int rml_canvas_clear(const char* win, const char* id)
{
	ElementCanvas* c = FindCanvas(win, id);
	if (!c)
		return 0;
	c->Clear();
	CanvasMarkLive(c->GetContext());
	return 1;
}

PLUGIN_API int rml_canvas_submit(const char* win, const char* id, const float* verts, int count, int mode)
{
	ElementCanvas* c = FindCanvas(win, id);
	if (!c)
		return 0;
	c->PushBatch(Tessellate(verts, count, mode, c->LineWidth()));
	return 1;
}

PLUGIN_API int rml_canvas_line_width(const char* win, const char* id, float width)
{
	ElementCanvas* c = FindCanvas(win, id);
	if (!c)
		return 0;
	c->SetLineWidth(width);
	return 1;
}

PLUGIN_API int rml_canvas_circle(const char* win, const char* id,
	float x, float y, float radius,
	float r, float g, float b, float a,
	int segments, int mode)
{
	ElementCanvas* c = FindCanvas(win, id);
	if (!c || radius <= 0.f)
		return 0;
	if (segments < 8) segments = 8;
	if (segments > 64) segments = 64;
	std::vector<float> tmp;
	const bool fill = (mode & RML_CANVAS_FILL) != 0;
	if (fill)
	{
		tmp.resize((size_t)(segments + 2) * kStride);
		int n = 0;
		auto put = [&](float px, float py) {
			float* p = tmp.data() + n * kStride;
			p[0] = px; p[1] = py; p[2] = r; p[3] = g; p[4] = b; p[5] = a;
			++n;
		};
		put(x, y);
		for (int i = 0; i <= segments; ++i)
		{
			const float t = (float)i / (float)segments * 6.2831853f;
			put(x + std::cos(t) * radius, y + std::sin(t) * radius);
		}
		c->PushBatch(Tessellate(tmp.data(), n, (mode & ~RML_CANVAS_PRIM_MASK) | RML_CANVAS_POLYGON, c->LineWidth()));
	}
	else
	{
		tmp.resize((size_t)(segments + 1) * kStride);
		for (int i = 0; i <= segments; ++i)
		{
			const float t = (float)i / (float)segments * 6.2831853f;
			float* p = tmp.data() + i * kStride;
			p[0] = x + std::cos(t) * radius;
			p[1] = y + std::sin(t) * radius;
			p[2] = r; p[3] = g; p[4] = b; p[5] = a;
		}
		c->PushBatch(Tessellate(tmp.data(), segments + 1, (mode & ~RML_CANVAS_PRIM_MASK) | RML_CANVAS_LINE_STRIP, c->LineWidth()));
	}
	return 1;
}

PLUGIN_API int rml_canvas_arc(const char* win, const char* id,
	float x, float y, float radius, float a0, float a1,
	float r, float g, float b, float a, int mode)
{
	ElementCanvas* c = FindCanvas(win, id);
	if (!c || radius <= 0.f)
		return 0;
	int segments = (int)std::ceil(std::fabs(a1 - a0) / 6.2831853f * 48.f);
	if (segments < 6) segments = 6;
	if (segments > 64) segments = 64;
	std::vector<float> tmp;
	const bool fill = (mode & RML_CANVAS_FILL) != 0;
	if (fill)
	{
		tmp.resize((size_t)(segments + 2) * kStride);
		int n = 0;
		auto put = [&](float px, float py) {
			float* p = tmp.data() + n * kStride;
			p[0] = px; p[1] = py; p[2] = r; p[3] = g; p[4] = b; p[5] = a;
			++n;
		};
		put(x, y);
		for (int i = 0; i <= segments; ++i)
		{
			const float t = a0 + (a1 - a0) * ((float)i / (float)segments);
			put(x + std::cos(t) * radius, y + std::sin(t) * radius);
		}
		c->PushBatch(Tessellate(tmp.data(), n, (mode & ~RML_CANVAS_PRIM_MASK) | RML_CANVAS_POLYGON, c->LineWidth()));
	}
	else
	{
		tmp.resize((size_t)(segments + 1) * kStride);
		for (int i = 0; i <= segments; ++i)
		{
			const float t = a0 + (a1 - a0) * ((float)i / (float)segments);
			float* p = tmp.data() + i * kStride;
			p[0] = x + std::cos(t) * radius;
			p[1] = y + std::sin(t) * radius;
			p[2] = r; p[3] = g; p[4] = b; p[5] = a;
		}
		c->PushBatch(Tessellate(tmp.data(), segments + 1, (mode & ~RML_CANVAS_PRIM_MASK) | RML_CANVAS_LINE_STRIP, c->LineWidth()));
	}
	return 1;
}

PLUGIN_API int rml_canvas_size(const char* win, const char* id, float* out_w, float* out_h)
{
	ElementCanvas* c = FindCanvas(win, id);
	if (!c)
		return 0;
	const Rml::Vector2f s = c->ContentSize();
	if (out_w) *out_w = s.x;
	if (out_h) *out_h = s.y;
	return 1;
}

PLUGIN_API float rml_canvas_draw_ms(const char* win, const char* id)
{
	ElementCanvas* c = FindCanvas(win, id);
	return c ? c->LastMs() : 0.f;
}

// Stage 0: renderer-wide perf of the last 5 s window (same line as Logs\rmlui_canvas.log "perf ..."):
// draws/s, CPU and GPU ms per draw for scene / bloom / composite, RT (re)allocations per second, RT memory.
PLUGIN_API int rml_canvas_perf(char* out, int cap)
{
	return CanvasRenderer::PerfString(out, cap);
}

static void AppendCanvasLog(const char* line)
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

extern "C++" void Canvas_Log(const char* line) { AppendCanvasLog(line); } // file region is extern "C"

PLUGIN_API int rml_canvas_probe()
{
	CanvasRenderer::RequestProbe();
	AppendCanvasLog("probe armed (rml_canvas_probe / command)");
	return 1;
}

PLUGIN_API int rml_canvas_stats(const char* win, const char* id, char* out, int cap)
{
	ElementCanvas* c = FindCanvas(win, id);
	if (!out || cap < 8)
		return 0;
	if (!c)
	{
		snprintf(out, (size_t)cap, "win=%s id=%s reason=canvas_not_found onR=0 draw=0",
			win ? win : "?", id ? id : "?");
		AppendCanvasLog(out);
		return 1;
	}
	c->FormatStats(out, cap, win ? win : "");
	AppendCanvasLog(out);
	return 1;
}

// ---------------------------------------------------------------------------
// World-to-screen (instrumentation only; no render-path changes).
//
// CVector3 (eqlib MathTypes.h) is {float X, Y, Z} in that memory order.
// PlayerBase (eqlib-live-tmp PlayerClient.h) stores named fields at:
//   Y=+0x074  X=+0x078  Z=+0x07c  Name=+0x0b4  DisplayedName=+0x0f4  SpawnID=+0x168
//   hierarchy: PlayerClient -> PlayerZoneClient -> PlayerBase (same address).
// rml_spawn_to_screen builds CVector3(spawn.X, spawn.Y, spawn.Z + headOffset).
// Camera: pDisplay (eqlib.dll ForeignPointer) -> CDisplay::pCamera at +0x118
//   then CCameraInterface::ProjectWorldCoordinatesToScreen (vtable index 29).
// Vtable order matches both eqlib-live-tmp and openvanilla-pr CameraInterface.h.
// Running MQ 3.1.6.11 / eqlib.dll targets eqgame "Sep 11 2025 11:54:10".
// MQ port: built against eqlib emu-tob 16db84cc (eqgame.h "Sep 11 2025 11:54:10").
// The raw offsets below are kept (identical behaviour) and static_assert'ed against eqlib.
// ---------------------------------------------------------------------------

namespace {

constexpr int kGameStateInGame = GAMESTATE_INGAME;
constexpr unsigned kDisplayCameraOff = 0x118;
constexpr unsigned kSpawnY = 0x074;
constexpr unsigned kSpawnX = 0x078;
constexpr unsigned kSpawnZ = 0x07c;
constexpr unsigned kSpawnName = 0x0b4;
constexpr unsigned kSpawnDispName = 0x0f4;
constexpr unsigned kSpawnAvatarHeight = 0x150;
constexpr unsigned kSpawnHeight = 0x154;
constexpr unsigned kSpawnID = 0x168;
constexpr unsigned kCamLeft = 0x034;
constexpr unsigned kCamTop = 0x038;
constexpr unsigned kCamHalfW = 0x03c;
constexpr unsigned kCamHalfH = 0x040;
constexpr unsigned kCamRenderW = 0x0d0; // NOT trusted: live log reads 1009x1009 here
constexpr unsigned kCamRenderH = 0x0d4; // while GetRenderBuffer* and 2*half are 1920x1009
constexpr unsigned kCamHalfAngle = 0x08;
constexpr unsigned kCamAspect = 0x0c;
constexpr unsigned kCamEyeZ = 0x5c;      // worldToEyeCoef[2] if vec3s are packed
constexpr unsigned kCamCot = 0x68;
constexpr unsigned kCamImageX = 0x88;    // worldToImageXAxisCot
constexpr unsigned kCamImageY = 0x94;    // worldToImageYAxisCotAspect
constexpr int kEqMaxName = 64;

// eqlib types (same layout/vtable the hand-written copies used; proven by the static_asserts below).
using EqVec3 = eqlib::CVector3;
using EqCamera = eqlib::CCameraInterface;

static_assert(offsetof(eqlib::CDisplay, pCamera) == kDisplayCameraOff, "eqlib CDisplay::pCamera moved");
static_assert(offsetof(eqlib::PlayerBase, Y) == kSpawnY, "eqlib PlayerBase::Y moved");
static_assert(offsetof(eqlib::PlayerBase, X) == kSpawnX, "eqlib PlayerBase::X moved");
static_assert(offsetof(eqlib::PlayerBase, Z) == kSpawnZ, "eqlib PlayerBase::Z moved");
static_assert(offsetof(eqlib::PlayerBase, Name) == kSpawnName, "eqlib PlayerBase::Name moved");
static_assert(offsetof(eqlib::PlayerBase, DisplayedName) == kSpawnDispName, "eqlib PlayerBase::DisplayedName moved");
static_assert(offsetof(eqlib::PlayerBase, AvatarHeight) == kSpawnAvatarHeight, "eqlib PlayerBase::AvatarHeight moved");
static_assert(offsetof(eqlib::PlayerBase, Height) == kSpawnHeight, "eqlib PlayerBase::Height moved");
static_assert(offsetof(eqlib::PlayerBase, SpawnID) == kSpawnID, "eqlib PlayerBase::SpawnID moved");
static_assert(sizeof(EqVec3) == 12, "CVector3 must be 3 packed floats");

// eqlib globals (were GetProcAddress("eqlib.dll", name) on the ForeignPointer exports).
void* EqForeignGet(const char* name)
{
	if (!strcmp(name, "pDisplay")) return static_cast<void*>(eqlib::pDisplay.get());
	if (!strcmp(name, "pSpawnManager")) return static_cast<void*>(eqlib::pSpawnManager.get());
	if (!strcmp(name, "pLocalPlayer")) return static_cast<void*>(eqlib::pLocalPlayer.get());
	if (!strcmp(name, "pTarget")) return static_cast<void*>(eqlib::pTarget.get());
	return nullptr;
}

EqCamera* EqCameraFromDisplay(void* display)
{
	if (!display)
		return nullptr;
	return static_cast<eqlib::CDisplay*>(display)->pCamera;
}

// EQ stores spawn loc as Y,X,Z and CCamera::GetX/GetY follow that same packed
// order. Logged 2026-11-11 05:31 (user targeted self id=144):
//   named world X,Y,Z = -11.62, 218.00, 2.87
//   GetX,GetY,GetZ    = 195.0, -10.7, 5.8   heading=509 (0-512) pitch=-8.5 deg
//   GetX 195 is 23u behind player Y 218; GetY -10.7 matches player X -11.62.
// Passing CVector3(worldX,worldY,worldZ) therefore subtracts world X from
// camera Y and yields the observed off-screen raw=-652,678 -> ov=307.8,-186.4.
// Passing CVector3(worldY,worldX,worldZ) matches the camera frame.
// Offline pose replay of that frame (ha=45 deg, aspect=1.902):
//   self chest  -> overlay (958.4, 494.6)   [need ~960, 500-700]
//   dummy chest -> overlay (959.4, 497.2)   (in front, on screen)
int ProjectWorldSeh(EqCamera* cam, float x, float y, float z, float* sx, float* sy)
{
	__try
	{
		if (!cam)
			return -1;
		EqVec3 pt;
		pt.X = y; // world Y -> camera GetX slot
		pt.Y = x; // world X -> camera GetY slot
		pt.Z = z;
		float ox = 0.f, oy = 0.f;
		const bool vis = cam->ProjectWorldCoordinatesToScreen(pt, ox, oy);
		if (sx) *sx = ox;
		if (sy) *sy = oy;
		return vis ? 1 : 0;
	}
	__except (EXCEPTION_EXECUTE_HANDLER)
	{
		return -1;
	}
}

int CameraSizeSeh(EqCamera* cam, float* w, float* h)
{
	__try
	{
		if (!cam)
			return -1;
		if (w) *w = cam->GetRenderBufferWidth();
		if (h) *h = cam->GetRenderBufferHeight();
		return 0;
	}
	__except (EXCEPTION_EXECUTE_HANDLER)
	{
		return -1;
	}
}

void ReadSpawnXYZ(const void* spawn, float& x, float& y, float& z)
{
	const char* p = static_cast<const char*>(spawn);
	y = *reinterpret_cast<const float*>(p + kSpawnY);
	x = *reinterpret_cast<const float*>(p + kSpawnX);
	z = *reinterpret_cast<const float*>(p + kSpawnZ);
}

unsigned ReadSpawnId(const void* spawn)
{
	return *reinterpret_cast<const unsigned*>(static_cast<const char*>(spawn) + kSpawnID);
}

void ReadSpawnName(const void* spawn, char* out, int cap)
{
	if (!out || cap < 2)
		return;
	out[0] = 0;
	if (!spawn)
		return;
	const char* disp = static_cast<const char*>(spawn) + kSpawnDispName;
	const char* raw = static_cast<const char*>(spawn) + kSpawnName;
	const char* src = (static_cast<unsigned char>(disp[0]) >= 32 && static_cast<unsigned char>(disp[0]) < 127) ? disp : raw;
	int n = 0;
	for (; n < cap - 1 && n < kEqMaxName; ++n)
	{
		const unsigned char c = static_cast<unsigned char>(src[n]);
		if (c == 0)
			break;
		out[n] = (c >= 32 && c < 127) ? static_cast<char>(c) : '?';
	}
	out[n] = 0;
}

int ReadSpawnXYZSeh(const void* spawn, float* x, float* y, float* z, unsigned* id, char* name, int nameCap)
{
	__try
	{
		if (!spawn)
			return -1;
		float lx = 0, ly = 0, lz = 0;
		ReadSpawnXYZ(spawn, lx, ly, lz);
		if (x) *x = lx;
		if (y) *y = ly;
		if (z) *z = lz;
		if (id) *id = ReadSpawnId(spawn);
		if (name && nameCap > 0)
			ReadSpawnName(spawn, name, nameCap);
		return 0;
	}
	__except (EXCEPTION_EXECUTE_HANDLER)
	{
		return -1;
	}
}

void* SpawnById(int spawnId)
{
	if (spawnId <= 0)
		return nullptr;
	eqlib::PlayerManagerClient* mgr = eqlib::pSpawnManager.get();
	if (!mgr)
		return nullptr;
	__try
	{
		return mgr->GetSpawnByID(spawnId);
	}
	__except (EXCEPTION_EXECUTE_HANDLER)
	{
		return nullptr;
	}
}

void FillW2SEntity(void* spawn, const char* tag, char* buf, int cap)
{
	float x = 0, y = 0, z = 0, sx = 0, sy = 0;
	unsigned id = 0;
	char name[kEqMaxName + 1] = "-";
	int rc = -1;
	if (spawn && ReadSpawnXYZSeh(spawn, &x, &y, &z, &id, name, (int)sizeof(name)) == 0)
	{
		if (!name[0])
			snprintf(name, sizeof(name), "-");
		rc = ProjectWorldSeh(EqCameraFromDisplay(EqForeignGet("pDisplay")), x, y, z, &sx, &sy);
	}
	snprintf(buf, (size_t)cap, "%s id=%u name=%s xyz=%.2f,%.2f,%.2f rc=%d sx=%.1f sy=%.1f",
		tag, id, name, x, y, z, rc, sx, sy);
}

} // namespace

struct CamView
{
	float left = 0, top = 0, halfW = 0, halfH = 0, renderW = 0, renderH = 0;
};

int ReadCamViewSeh(EqCamera* cam, CamView* v)
{
	__try
	{
		if (!cam || !v)
			return -1;
		const char* p = reinterpret_cast<const char*>(cam);
		v->left = *reinterpret_cast<const float*>(p + kCamLeft);
		v->top = *reinterpret_cast<const float*>(p + kCamTop);
		v->halfW = *reinterpret_cast<const float*>(p + kCamHalfW);
		v->halfH = *reinterpret_cast<const float*>(p + kCamHalfH);
		v->renderW = static_cast<float>(*reinterpret_cast<const unsigned*>(p + kCamRenderW));
		v->renderH = static_cast<float>(*reinterpret_cast<const unsigned*>(p + kCamRenderH));
		return 0;
	}
	__except (EXCEPTION_EXECUTE_HANDLER)
	{
		return -1;
	}
}

int ReadSpawnHeightSeh(const void* spawn, float* outH)
{
	__try
	{
		if (!spawn)
			return -1;
		const char* p = static_cast<const char*>(spawn);
		const float ah = *reinterpret_cast<const float*>(p + kSpawnAvatarHeight);
		const float h = *reinterpret_cast<const float*>(p + kSpawnHeight);
		float use = (ah > 0.5f && ah < 40.f) ? ah : h;
		if (use < 0.5f || use > 40.f)
			use = 6.0f;
		if (outH)
			*outH = use;
		return 0;
	}
	__except (EXCEPTION_EXECUTE_HANDLER)
	{
		return -1;
	}
}

// ProjectWorldCoordinatesToScreen returns center-origin, Y-up camera pixels
// (logged raw sx was -600..-2300 while the dummy was on screen). Convert to
// top-left overlay pixels and scale the 3D buffer to the overlay.
//
// PROOF (rmlui_canvas.log 2026-11-11 05:08:23, Test Dummy One):
//   raw=-1527.1,1317.5  half=960.0x504.5  rend@0xD0/0xD4=1009x1009
//   screen GetRenderBuffer*=1920x1009  ov dest 1920x1080  left=0 top=0
//   old formula used camW=rendW=1009:
//     px = 0+960+(-1527.1) = -567.1
//     py = 0+504.5-1317.5 = -813.0
//     ox = -567.1 * (1920/1009) = -1079.1   (matches logged ovx)
//     oy = -813.0 * (1080/1009) = -870.2    (matches logged ovy)
//   So the 1009x1009 overwrite is real, and it stretches X the wrong way.
//   Using the real buffer 1920x1009 instead:
//     ox = -567.1 * (1920/1920) = -567.1
//     oy = -813.0 * (1080/1009) = -870.2
//   Still off-screen: EQ's raw pair itself is not an on-screen pixel offset
//   for a dummy the player is looking at. Overlay success therefore also
//   tries a pose projection (camera GetX/Y/Z + heading/pitch + FOV) and an
//   axes projection from the CCamera worldToImage vectors.

bool OverlayOnScreen(float ox, float oy, float ovW, float ovH)
{
	return ox > -48.f && oy > -48.f && ox < ovW + 48.f && oy < ovH + 48.f
		&& ox == ox && oy == oy
		&& ox > -100000.f && ox < 100000.f
		&& oy > -100000.f && oy < 100000.f;
}

int FillCamView(EqCamera* cam, float ovW, float ovH, CamView* v, float* outW, float* outH)
{
	CamView local{};
	if (!v) v = &local;
	float methodW = 0.f, methodH = 0.f;
	CameraSizeSeh(cam, &methodW, &methodH);
	if (ReadCamViewSeh(cam, v) != 0)
	{
		v->halfW = methodW * 0.5f;
		v->halfH = methodH * 0.5f;
	}
	if (v->halfW < 8.f || v->halfW > 4096.f) v->halfW = methodW * 0.5f;
	if (v->halfH < 8.f || v->halfH > 4096.f) v->halfH = methodH * 0.5f;
	if (v->left < -4096.f || v->left > 4096.f) v->left = 0.f;
	if (v->top < -4096.f || v->top > 4096.f) v->top = 0.f;

	const float halfBasedW = (v->halfW >= 8.f) ? (v->halfW * 2.f) : 0.f;
	const float halfBasedH = (v->halfH >= 8.f) ? (v->halfH * 2.f) : 0.f;

	// Prefer GetRenderBufferWidth/Height (logged 1920x1009 every sample) and
	// 2*half (1920x1009). Reject rend 1009x1009 when it disagrees with those.
	float camW = methodW;
	float camH = methodH;
	const bool rendPlausible =
		v->renderW >= 64.f && v->renderH >= 64.f
		&& (halfBasedW < 64.f || fabsf(v->renderW - halfBasedW) <= 8.f)
		&& (methodW < 64.f || fabsf(v->renderW - methodW) <= 8.f)
		&& (halfBasedH < 64.f || fabsf(v->renderH - halfBasedH) <= 8.f)
		&& (methodH < 64.f || fabsf(v->renderH - methodH) <= 8.f);
	if (rendPlausible)
	{
		camW = v->renderW;
		camH = v->renderH;
	}
	else
	{
		if (camW < 8.f) camW = halfBasedW;
		if (camH < 8.f) camH = halfBasedH;
	}
	if (camW < 8.f) camW = (ovW >= 8.f) ? ovW : 1920.f;
	if (camH < 8.f) camH = (ovH >= 8.f) ? ovH : 1080.f;
	if (ovW < 8.f) ovW = camW;
	if (ovH < 8.f) ovH = camH;
	if (v->halfW < 1.f) v->halfW = camW * 0.5f;
	if (v->halfH < 1.f) v->halfH = camH * 0.5f;
	v->renderW = camW;
	v->renderH = camH;
	if (outW) *outW = camW;
	if (outH) *outH = camH;
	return 0;
}

int ConvertRawToOverlay(EqCamera* cam, float rawX, float rawY, float ovW, float ovH,
	float* ox, float* oy, CamView* dbg)
{
	CamView v{};
	float camW = 0.f, camH = 0.f;
	FillCamView(cam, ovW, ovH, &v, &camW, &camH);
	if (ovW < 8.f) ovW = camW;
	if (ovH < 8.f) ovH = camH;
	const float px = v.left + v.halfW + rawX;
	const float py = v.top + v.halfH - rawY;
	if (ox) *ox = px * (ovW / camW);
	if (oy) *oy = py * (ovH / camH);
	if (dbg)
	{
		*dbg = v;
		dbg->renderW = camW;
		dbg->renderH = camH;
	}
	if (!ox || !oy)
		return 0;
	return OverlayOnScreen(*ox, *oy, ovW, ovH) ? 1 : 0;
}

int GetCamPoseSeh(EqCamera* cam, float* x, float* y, float* z, float* heading, float* pitch)
{
	__try
	{
		if (!cam)
			return -1;
		if (x) *x = cam->GetX();
		if (y) *y = cam->GetY();
		if (z) *z = cam->GetZ();
		if (heading) *heading = cam->GetHeading();
		if (pitch) *pitch = cam->GetPitch();
		return 0;
	}
	__except (EXCEPTION_EXECUTE_HANDLER)
	{
		return -1;
	}
}

int ReadCamFloatSeh(EqCamera* cam, unsigned off, float* out)
{
	__try
	{
		if (!cam || !out)
			return -1;
		*out = *reinterpret_cast<const float*>(reinterpret_cast<const char*>(cam) + off);
		return 0;
	}
	__except (EXCEPTION_EXECUTE_HANDLER)
	{
		return -1;
	}
}

int ReadCamVec3Seh(EqCamera* cam, unsigned off, float* x, float* y, float* z)
{
	__try
	{
		if (!cam)
			return -1;
		const float* v = reinterpret_cast<const float*>(reinterpret_cast<const char*>(cam) + off);
		if (x) *x = v[0];
		if (y) *y = v[1];
		if (z) *z = v[2];
		return 0;
	}
	__except (EXCEPTION_EXECUTE_HANDLER)
	{
		return -1;
	}
}

int ProjectViaCameraSpaceSeh(EqCamera* cam, float wx, float wy, float wz, float* sx, float* sy)
{
	__try
	{
		if (!cam || !sx || !sy)
			return -1;
		EqVec3 world;
		world.X = wy;
		world.Y = wx;
		world.Z = wz;
		EqVec3 camPt;
		camPt.X = camPt.Y = camPt.Z = 0.f;
		cam->TransformWorldCoordinatesToCameraCoordinates(world, camPt);
		float ox = 0.f, oy = 0.f;
		const bool vis = cam->ProjectCameraToScreen(camPt, ox, oy);
		*sx = ox;
		*sy = oy;
		return vis ? 1 : 0;
	}
	__except (EXCEPTION_EXECUTE_HANDLER)
	{
		return -1;
	}
}

bool ProjectByPose(EqCamera* cam, float wx, float wy, float wz, float ovW, float ovH,
	float heading, float pitch, float* ox, float* oy, float* ndc2)
{
	float gx = 0, gy = 0, gz = 0, dummyH = 0, dummyP = 0;
	if (GetCamPoseSeh(cam, &gx, &gy, &gz, &dummyH, &dummyP) != 0)
		return false;
	// GetX/GetY are EQ Y,X (see ProjectWorldSeh). Remap to world X,Y,Z.
	const float cx = gy;
	const float cy = gx;
	const float cz = gz;
	float halfAngle = 0.f, aspect = 0.f, cot = 0.f;
	ReadCamFloatSeh(cam, kCamHalfAngle, &halfAngle);
	ReadCamFloatSeh(cam, kCamAspect, &aspect);
	ReadCamFloatSeh(cam, kCamCot, &cot);

	float halfRad = halfAngle;
	if (halfAngle > 15.f && halfAngle < 89.f)
		halfRad = halfAngle * (3.14159265f / 180.f);
	if (halfRad < 0.15f || halfRad > 1.45f)
		halfRad = 0.785398f;
	float f = (cot > 0.25f && cot < 20.f) ? cot : (1.f / tanf(halfRad));
	if (aspect < 0.35f || aspect > 3.8f)
	{
		float bw = 0.f, bh = 0.f;
		CameraSizeSeh(cam, &bw, &bh);
		aspect = (bh > 8.f) ? (bw / bh) : ((ovH > 8.f) ? (ovW / ovH) : (1920.f / 1080.f));
	}

	const float ch = cosf(heading);
	const float sh = sinf(heading);
	const float cp = cosf(pitch);
	const float sp = sinf(pitch);
	// heading 0 = north = +Y; increases clockwise (right turn faces +X / east)
	const float fwdX = sh * cp;
	const float fwdY = ch * cp;
	const float fwdZ = sp;
	float rightX = fwdY;
	float rightY = -fwdX;
	float rightZ = 0.f;
	const float rlen = sqrtf(rightX * rightX + rightY * rightY + rightZ * rightZ);
	if (rlen < 1e-5f)
		return false;
	rightX /= rlen;
	rightY /= rlen;
	rightZ /= rlen;
	const float upX = rightY * fwdZ - rightZ * fwdY;
	const float upY = rightZ * fwdX - rightX * fwdZ;
	const float upZ = rightX * fwdY - rightY * fwdX;

	const float dx = wx - cx;
	const float dy = wy - cy;
	const float dz = wz - cz;
	const float depth = dx * fwdX + dy * fwdY + dz * fwdZ;
	if (depth < 0.20f)
		return false;
	const float rx = dx * rightX + dy * rightY + dz * rightZ;
	const float ry = dx * upX + dy * upY + dz * upZ;
	const float ndcX = (rx / depth) * f / aspect;
	const float ndcY = (ry / depth) * f;
	if (fabsf(ndcX) > 1.55f || fabsf(ndcY) > 1.55f)
		return false;
	if (ox) *ox = (ndcX * 0.5f + 0.5f) * ovW;
	if (oy) *oy = (1.f - (ndcY * 0.5f + 0.5f)) * ovH;
	if (ndc2) *ndc2 = ndcX * ndcX + ndcY * ndcY;
	return ox && oy && OverlayOnScreen(*ox, *oy, ovW, ovH);
}

bool ProjectByAxes(EqCamera* cam, float wx, float wy, float wz, float ovW, float ovH,
	bool divide, float* ox, float* oy, float* score)
{
	float gx = 0, gy = 0, gz = 0, h = 0, p = 0;
	if (GetCamPoseSeh(cam, &gx, &gy, &gz, &h, &p) != 0)
		return false;
	// Same Y,X,Z camera frame as ProjectWorldSeh: compare (Y,X,Z) to GetX/GetY/GetZ.
	const float dx = wy - gx;
	const float dy = wx - gy;
	const float dz = wz - gz;
	float ix0 = 0, ix1 = 0, ix2 = 0, iy0 = 0, iy1 = 0, iy2 = 0, ez0 = 0, ez1 = 0, ez2 = 0;
	if (ReadCamVec3Seh(cam, kCamImageX, &ix0, &ix1, &ix2) != 0)
		return false;
	if (ReadCamVec3Seh(cam, kCamImageY, &iy0, &iy1, &iy2) != 0)
		return false;
	ReadCamVec3Seh(cam, kCamEyeZ, &ez0, &ez1, &ez2);
	float ix = dx * ix0 + dy * ix1 + dz * ix2;
	float iy = dx * iy0 + dy * iy1 + dz * iy2;
	const float depth = dx * ez0 + dy * ez1 + dz * ez2;
	if (divide)
	{
		if (depth < 0.20f)
			return false;
		ix /= depth;
		iy /= depth;
	}
	CamView v{};
	float camW = 0.f, camH = 0.f;
	FillCamView(cam, ovW, ovH, &v, &camW, &camH);
	if (ovW < 8.f) ovW = camW;
	if (ovH < 8.f) ovH = camH;
	const float px = v.left + v.halfW + ix;
	const float py = v.top + v.halfH - iy;
	if (ox) *ox = px * (ovW / camW);
	if (oy) *oy = py * (ovH / camH);
	if (score) *score = ix * ix + iy * iy;
	return ox && oy && OverlayOnScreen(*ox, *oy, ovW, ovH);
}

struct OverlayCand
{
	float x = 0, y = 0, score = 1e12f;
	const char* tag = "none";
	bool on = false;
};

void ConsiderOverlay(OverlayCand* best, float x, float y, float score, const char* tag, float ovW, float ovH)
{
	if (!best || !OverlayOnScreen(x, y, ovW, ovH))
		return;
	if (!best->on || score < best->score)
	{
		best->x = x;
		best->y = y;
		best->score = score;
		best->tag = tag;
		best->on = true;
	}
}

int ResolveWorldToOverlay(EqCamera* cam, float wx, float wy, float wz,
	float ovW, float ovH, float* sx, float* sy, char* why, int whyCap)
{
	if (sx) *sx = 0.f;
	if (sy) *sy = 0.f;
	if (!cam || !sx || !sy)
		return -1;

	float rawx = 0.f, rawy = 0.f, eqx = 0.f, eqy = 0.f;
	const int prc = ProjectWorldSeh(cam, wx, wy, wz, &rawx, &rawy);
	int vis = -1;
	if (prc >= 0)
		vis = ConvertRawToOverlay(cam, rawx, rawy, ovW, ovH, &eqx, &eqy, nullptr);

	// Trust EQ's own projector when the *corrected* conversion lands on screen.
	if (vis == 1)
	{
		*sx = eqx;
		*sy = eqy;
		if (why && whyCap > 0)
			snprintf(why, (size_t)whyCap, "eq-raw");
		return 1;
	}

	OverlayCand best{};
	const float midX = ovW * 0.5f;
	const float midY = ovH * 0.42f;
	auto dist2 = [&](float x, float y) {
		const float dx = x - midX;
		const float dy = y - midY;
		return dx * dx + dy * dy;
	};

	float heading = 0.f, pitch = 0.f, cx = 0.f, cy = 0.f, cz = 0.f;
	const bool havePose = GetCamPoseSeh(cam, &cx, &cy, &cz, &heading, &pitch) == 0;

	if (havePose)
	{
		struct HeadTry { float h; const char* tag; } tries[6] = {
			{ heading, "pose-rad" },
			{ heading * (3.14159265f / 256.f), "pose-eq512" },
			{ heading * (3.14159265f / 180.f), "pose-deg" },
			{ -heading, "pose-rad-neg" },
			{ -heading * (3.14159265f / 256.f), "pose-eq512-neg" },
			{ heading + 3.14159265f, "pose-rad-pi" },
		};
		for (int i = 0; i < 6; ++i)
		{
			float ox = 0.f, oy = 0.f, n2 = 1e6f;
			if (ProjectByPose(cam, wx, wy, wz, ovW, ovH, tries[i].h, pitch, &ox, &oy, &n2))
				ConsiderOverlay(&best, ox, oy, n2, tries[i].tag, ovW, ovH);
		}
	}

	float ox = 0.f, oy = 0.f, sc = 0.f;
	if (ProjectByAxes(cam, wx, wy, wz, ovW, ovH, false, &ox, &oy, &sc))
		ConsiderOverlay(&best, ox, oy, sc, "axes", ovW, ovH);
	if (ProjectByAxes(cam, wx, wy, wz, ovW, ovH, true, &ox, &oy, &sc))
		ConsiderOverlay(&best, ox, oy, sc, "axes-div", ovW, ovH);

	float csx = 0.f, csy = 0.f;
	if (ProjectViaCameraSpaceSeh(cam, wx, wy, wz, &csx, &csy) >= 0)
	{
		float cox = 0.f, coy = 0.f;
		if (ConvertRawToOverlay(cam, csx, csy, ovW, ovH, &cox, &coy, nullptr) == 1)
			ConsiderOverlay(&best, cox, coy, dist2(cox, coy), "camspace", ovW, ovH);
	}

	if (best.on)
	{
		*sx = best.x;
		*sy = best.y;
		if (why && whyCap > 0)
			snprintf(why, (size_t)whyCap, "%s", best.tag);
		return 1;
	}

	if (vis >= 0)
	{
		*sx = eqx;
		*sy = eqy;
		if (why && whyCap > 0)
			snprintf(why, (size_t)whyCap, "eq-raw-off");
		return 0;
	}
	if (why && whyCap > 0)
		snprintf(why, (size_t)whyCap, "fail");
	return -1;
}

PLUGIN_API int rml_world_to_screen(float x, float y, float z, float* sx, float* sy)
{
	if (sx) *sx = 0.f;
	if (sy) *sy = 0.f;
	if (!sx || !sy)
		return -1;
	void* display = EqForeignGet("pDisplay");
	EqCamera* cam = EqCameraFromDisplay(display);
	if (!display || !cam)
		return -1;
	return ProjectWorldSeh(cam, x, y, z, sx, sy);
}

PLUGIN_API int rml_spawn_to_screen(int spawnId, float headOffset, float* sx, float* sy)
{
	if (sx) *sx = 0.f;
	if (sy) *sy = 0.f;
	if (!sx || !sy)
		return -1;
	void* display = EqForeignGet("pDisplay");
	EqCamera* cam = EqCameraFromDisplay(display);
	if (!display || !cam)
		return -1;
	void* spawn = SpawnById(spawnId);
	if (!spawn)
		return -1;
	float x = 0, y = 0, z = 0;
	if (ReadSpawnXYZSeh(spawn, &x, &y, &z, nullptr, nullptr, 0) != 0)
		return -1;
	return ProjectWorldSeh(cam, x, y, z + headOffset, sx, sy);
}

PLUGIN_API int rml_world_to_overlay(float x, float y, float z, float ovW, float ovH, float* sx, float* sy)
{
	if (sx) *sx = 0.f;
	if (sy) *sy = 0.f;
	if (!sx || !sy)
		return -1;
	void* display = EqForeignGet("pDisplay");
	EqCamera* cam = EqCameraFromDisplay(display);
	if (!display || !cam)
		return -1;
	return ResolveWorldToOverlay(cam, x, y, z, ovW, ovH, sx, sy, nullptr, 0);
}

PLUGIN_API int rml_spawn_to_overlay(int spawnId, float heightFrac, float ovW, float ovH, float* sx, float* sy)
{
	if (sx) *sx = 0.f;
	if (sy) *sy = 0.f;
	if (!sx || !sy)
		return -1;
	if (heightFrac < 0.05f || heightFrac > 1.5f)
		heightFrac = 0.58f;
	void* display = EqForeignGet("pDisplay");
	EqCamera* cam = EqCameraFromDisplay(display);
	if (!display || !cam)
		return -1;
	void* spawn = SpawnById(spawnId);
	if (!spawn)
		return -1;
	float x = 0, y = 0, z = 0, h = 6.f;
	if (ReadSpawnXYZSeh(spawn, &x, &y, &z, nullptr, nullptr, 0) != 0)
		return -1;
	ReadSpawnHeightSeh(spawn, &h);
	return rml_world_to_overlay(x, y, z + h * heightFrac, ovW, ovH, sx, sy);
}

PLUGIN_API int rml_canvas_lookat(float* out16,
	float ex, float ey, float ez,
	float ax, float ay, float az,
	float ux, float uy, float uz,
	float fov_y_deg, float aspect, float znear, float zfar)
{
	if (!out16 || aspect <= 0.f || fov_y_deg <= 0.f)
		return 0;
	const XMVECTOR eye = XMVectorSet(ex, ey, ez, 0);
	const XMVECTOR at = XMVectorSet(ax, ay, az, 0);
	XMVECTOR up = XMVectorSet(ux, uy, uz, 0);
	if (XMVectorGetX(XMVector3LengthSq(up)) < 1e-8f)
		up = XMVectorSet(0, 1, 0, 0);
	const XMMATRIX view = XMMatrixLookAtLH(eye, at, up);
	const XMMATRIX proj = XMMatrixPerspectiveFovLH(fov_y_deg * (3.14159265f / 180.f), aspect, znear, zfar);
	XMFLOAT4X4 stored;
	XMStoreFloat4x4(&stored, view * proj);
	std::memcpy(out16, &stored, sizeof(stored));
	return 1;
}

PLUGIN_API int rml_canvas_project(float x, float y, float z, const float* m16,
	float vp_w, float vp_h, float* out_x, float* out_y)
{
	if (!m16 || !out_x || !out_y || vp_w <= 0.f || vp_h <= 0.f)
		return 0;
	XMFLOAT4X4 mat;
	std::memcpy(&mat, m16, sizeof(mat));
	const XMVECTOR c = XMVector4Transform(XMVectorSet(x, y, z, 1.f), XMLoadFloat4x4(&mat));
	const float w = XMVectorGetW(c);
	if (w <= 1e-5f)
		return 0;
	const float ndcX = XMVectorGetX(c) / w;
	const float ndcY = XMVectorGetY(c) / w;
	*out_x = (ndcX * 0.5f + 0.5f) * vp_w;
	*out_y = (1.f - (ndcY * 0.5f + 0.5f)) * vp_h;
	return 1;
}

PLUGIN_API int rml_canvas_project_n(const float* xyz, int n, const float* m16,
	float vp_w, float vp_h, float* out_xy)
{
	if (!xyz || !m16 || !out_xy || n <= 0 || vp_w <= 0.f || vp_h <= 0.f)
		return 0;
	XMFLOAT4X4 mat;
	std::memcpy(&mat, m16, sizeof(mat));
	const XMMATRIX M = XMLoadFloat4x4(&mat);
	int written = 0;
	for (int i = 0; i < n; ++i)
	{
		const float x = xyz[i * 3 + 0];
		const float y = xyz[i * 3 + 1];
		const float z = xyz[i * 3 + 2];
		const XMVECTOR c = XMVector4Transform(XMVectorSet(x, y, z, 1.f), M);
		const float w = XMVectorGetW(c);
		if (w <= 1e-5f)
		{
			out_xy[i * 2 + 0] = -1e6f;
			out_xy[i * 2 + 1] = -1e6f;
			continue;
		}
		const float ndcX = XMVectorGetX(c) / w;
		const float ndcY = XMVectorGetY(c) / w;
		out_xy[i * 2 + 0] = (ndcX * 0.5f + 0.5f) * vp_w;
		out_xy[i * 2 + 1] = (1.f - (ndcY * 0.5f + 0.5f)) * vp_h;
		++written;
	}
	return written;
}


PLUGIN_API int rml_canvas_bg(const char* win, const char* id, int style, float time, float energy, float beat)
{
	ElementCanvas* c = FindCanvas(win, id);
	if (!c)
		return 0;
	c->SetBg(style, time, energy, beat);
	return 1;
}

PLUGIN_API int rml_canvas_trail(const char* win, const char* id, float decay)
{
	ElementCanvas* c = FindCanvas(win, id);
	if (!c)
		return 0;
	c->SetTrail(decay);
	return 1;
}

PLUGIN_API int rml_canvas_bloom(const char* win, const char* id, float strength)
{
	ElementCanvas* c = FindCanvas(win, id);
	if (!c)
		return 0;
	c->SetBloom(strength);
	return 1;
}

PLUGIN_API int rml_canvas_sprites(const char* win, const char* id, const float* data, int count, int mode)
{
	ElementCanvas* c = FindCanvas(win, id);
	if (!c || !data || count <= 0)
		return 0;
	if (count > 8192)
		count = 8192;
	CanvasSpriteBatch batch;
	batch.flags = mode;
	batch.items.reserve((size_t)count);
	for (int i = 0; i < count; ++i)
	{
		const float* p = data + i * 8;
		CanvasSpriteInst s;
		s.x = p[0]; s.y = p[1]; s.rx = p[2]; s.ry = p[3];
		s.r = p[4]; s.g = p[5]; s.b = p[6]; s.a = p[7];
		batch.items.push_back(s);
	}
	c->PushSprites(std::move(batch));
	return 1;
}

PLUGIN_API int rml_canvas_rect(const char* win, const char* id, float* x, float* y, float* w, float* h)
{
	ElementCanvas* c = FindCanvas(win, id);
	if (!c || !x || !y || !w || !h)
		return 0;
	c->LastRect(*x, *y, *w, *h);
	return 1;
}

PLUGIN_API int rml_canvas_sprite(const char* win, const char* id,
	float x, float y, float rx, float ry,
	float r, float g, float b, float a, int mode)
{
	float tmp[8] = { x, y, rx, ry, r, g, b, a };
	return rml_canvas_sprites(win, id, tmp, 1, mode);
}

PLUGIN_API int rml_canvas_texture_load(const char* win, const char* id, const char* path)
{
	if (!path || !path[0])
		return 0;
	if (win && win[0] && id && id[0] && !FindCanvas(win, id))
		return 0;
	return CanvasRenderer::Get().LoadTexture(path);
}

PLUGIN_API int rml_canvas_sprites_ex(const char* win, const char* id, const float* data, int count)
{
	ElementCanvas* c = FindCanvas(win, id);
	if (!c || !data || count <= 0)
		return 0;
	if (count > 8192)
		count = 8192;
	std::vector<CanvasSpriteExInst> items;
	items.reserve((size_t)count);
	for (int i = 0; i < count; ++i)
	{
		const float* p = data + i * 11;
		CanvasSpriteExInst s;
		s.x = p[0];
		s.y = p[1];
		s.sx = p[2];
		s.sy = p[3];
		s.angle = p[4];
		s.r = p[5];
		s.g = p[6];
		s.b = p[7];
		s.a = p[8];
		s.tex_id = (int)p[9];
		s.mode = (int)p[10];
		items.push_back(s);
	}
	c->PushSpritesEx(std::move(items));
	return 1;
}

PLUGIN_API int rml_canvas_sprite_ex(const char* win, const char* id,
	float x, float y, float sx, float sy, float angle,
	float r, float g, float b, float a, int tex_id, int mode)
{
	float tmp[11] = { x, y, sx, sy, angle, r, g, b, a, (float)tex_id, (float)mode };
	return rml_canvas_sprites_ex(win, id, tmp, 1);
}

} // extern "C"

void Canvas_SetPaintTarget(const char* win, void* tex, void* rtv, int w, int h)
{
	CanvasRenderer::SetPaintTarget(win, tex, rtv, w, h);
}

void Canvas_RequestProbe()
{
	CanvasRenderer::RequestProbe();
}

void Canvas_PulseWorldToScreenLog()
{
	if (mq::GetGameState() != kGameStateInGame)
		return;
	static ULONGLONG s_last = 0;
	const ULONGLONG now = GetTickCount64();
	if (s_last != 0 && (now - s_last) < 5000)
		return;
	s_last = now;

	void* display = EqForeignGet("pDisplay");
	EqCamera* cam = EqCameraFromDisplay(display);
	float camW = 0, camH = 0;
	CameraSizeSeh(cam, &camW, &camH);

	float imguiW = 0, imguiH = 0;
	if (ImGui::GetCurrentContext())
	{
		const ImVec2 ds = ImGui::GetIO().DisplaySize;
		imguiW = ds.x;
		imguiH = ds.y;
	}

	char selfBuf[256];
	char tgtBuf[256];
	FillW2SEntity(EqForeignGet("pLocalPlayer"), "self", selfBuf, (int)sizeof(selfBuf));
	FillW2SEntity(EqForeignGet("pTarget"), "target", tgtBuf, (int)sizeof(tgtBuf));

	char convBuf[640] = "ov=-";
	float selfovx = 0, selfovy = 0, tgtovx = 0, tgtovy = 0;
	int selfrc = -1, tgtrc = -1;
	char selfWhy[24] = "-", tgtWhy[24] = "-";
	void* self = EqForeignGet("pLocalPlayer");
	void* tgt = EqForeignGet("pTarget");
	if (cam && self)
	{
		float sx = 0, sy = 0, sz = 0, sh = 6.f;
		if (ReadSpawnXYZSeh(self, &sx, &sy, &sz, nullptr, nullptr, 0) == 0)
		{
			ReadSpawnHeightSeh(self, &sh);
			selfrc = ResolveWorldToOverlay(cam, sx, sy, sz + sh * 0.58f, 1920.f, 1080.f,
				&selfovx, &selfovy, selfWhy, (int)sizeof(selfWhy));
		}
	}
	if (tgt && cam)
	{
		float tx = 0, ty = 0, tz = 0, th = 6.f, rawx = 0, rawy = 0, ox = 0, oy = 0;
		CamView cv{};
		if (ReadSpawnXYZSeh(tgt, &tx, &ty, &tz, nullptr, nullptr, 0) == 0)
		{
			ReadSpawnHeightSeh(tgt, &th);
			const int prc = ProjectWorldSeh(cam, tx, ty, tz + th * 0.58f, &rawx, &rawy);
			const int ovrcOld = ConvertRawToOverlay(cam, rawx, rawy, 1920.f, 1080.f, &ox, &oy, &cv);
			float rx = 0.f, ry = 0.f;
			const int ovrc = ResolveWorldToOverlay(cam, tx, ty, tz + th * 0.58f, 1920.f, 1080.f, &rx, &ry, tgtWhy, (int)sizeof(tgtWhy));
			tgtrc = ovrc;
			tgtovx = rx;
			tgtovy = ry;
			float cpx = 0, cpy = 0, cpz = 0, hd = 0, ptch = 0, ha = 0, asp = 0, cot = 0;
			GetCamPoseSeh(cam, &cpx, &cpy, &cpz, &hd, &ptch);
			ReadCamFloatSeh(cam, kCamHalfAngle, &ha);
			ReadCamFloatSeh(cam, kCamAspect, &asp);
			ReadCamFloatSeh(cam, kCamCot, &cot);
			const float ydn = (cv.top + cv.halfH + rawy) * (1080.f / (cv.renderH > 8.f ? cv.renderH : 1080.f));
			snprintf(convBuf, sizeof(convBuf),
				"h=%.2f raw=%.1f,%.1f prc=%d ov=%.1f,%.1f ovrc=%d ydn=%.1f cam=l%.1f,t%.1f,half=%.1fx%.1f,rend=%.0fx%.0f method=%s res=%.1f,%.1f pose=%.1f,%.1f,%.1f hd=%.3f pt=%.3f ha=%.3f asp=%.3f cot=%.3f oldovrc=%d order=YXZ selfov=%.1f,%.1f selfrc=%d tgtov=%.1f,%.1f tgtrc=%d",
				th, rawx, rawy, prc, ox, oy, ovrc, ydn, cv.left, cv.top, cv.halfW, cv.halfH, cv.renderW, cv.renderH,
				tgtWhy, rx, ry, cpx, cpy, cpz, hd, ptch, ha, asp, cot, ovrcOld,
				selfovx, selfovy, selfrc, tgtovx, tgtovy, tgtrc);
		}
	}

	char line[1400];
	snprintf(line, sizeof(line),
		"w2s pDisplay=%p pCamera=%p screen=%.0fx%.0f imgui=%.0fx%.0f %s %s %s",
		display, static_cast<void*>(cam), camW, camH, imguiW, imguiH, selfBuf, tgtBuf, convBuf);
	AppendCanvasLog(line);
}


