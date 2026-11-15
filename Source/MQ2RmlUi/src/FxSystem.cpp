#include <mq/Plugin.h>   // MacroQuest plugin API (MQ2Main, eqlib, PLUGIN_API)
// Stage 1 GPU particles: emitter registry and the rml_fx_* exports (API v5, additive).
#include "FxSystem.h"
#include "ElementCanvas.h"
#include "CanvasRenderer.h"

#include <windows.h>
#include <cstdio>
#include <cstring>
#include <map>
#include <mutex>

namespace {

struct Emitter
{
	fx::FxEmitterCore core;
	const void* canvas = nullptr;
	const void* ctx = nullptr;
	double lastTick = -1.0;
	fx::FxCB last{};
	uint32_t lastInst = 0;
	bool hasLast = false;
};

struct Capsule { float X[16]; };

std::mutex g_mtx;
std::map<int, Emitter> g_em;
std::map<const void*, Capsule> g_caps;
int g_next = 1;
bool g_forceCpu = false;
constexpr size_t kMaxEmitters = 256;

double NowS()
{
	static LARGE_INTEGER f{};
	if (!f.QuadPart) QueryPerformanceFrequency(&f);
	LARGE_INTEGER t; QueryPerformanceCounter(&t);
	return (double)t.QuadPart / (double)f.QuadPart;
}

const float* CapsFor(const void* canvas)
{
	auto it = g_caps.find(canvas);
	return it != g_caps.end() ? it->second.X : nullptr;
}

Emitter* Find(int h)
{
	auto it = g_em.find(h);
	return it != g_em.end() ? &it->second : nullptr;
}

} // namespace

void Fx_Collect(const void* canvas, std::vector<CanvasFxDraw>& out)
{
	std::lock_guard<std::mutex> lock(g_mtx);
	const double now = NowS();
	const float* caps = CapsFor(canvas);
	for (auto& [h, e] : g_em)
	{
		if (e.canvas != canvas)
			continue;
		const double dt = e.lastTick < 0.0 ? 0.0 : now - e.lastTick;
		e.lastTick = now;
		e.core.Advance(dt);                  // clamped to fx::kMaxDt
		if (!e.core.Active())
			continue;
		CanvasFxDraw d;
		e.core.Build(d.cb, caps);
		d.instances = e.core.Instances();
		d.texId = (int)e.core.D[fx::D_TEX];
		d.additive = e.core.D[fx::D_BLEND] > 0.5f;
		d.handle = h;
		e.last = d.cb;
		e.lastInst = d.instances;
		e.hasLast = true;
		if (d.instances)
			out.push_back(d);
	}
}

bool Fx_CanvasCapsule(const void* canvas, float* outX16)
{
	if (!canvas || !outX16)
		return false;
	std::lock_guard<std::mutex> lock(g_mtx);
	const float* c = CapsFor(canvas);
	if (!c || c[6] < 0.5f)
		return false;
	std::memcpy(outX16, c, sizeof(float) * 16);
	return true;
}

bool Fx_ContextLive(const void* ctx)
{
	if (!ctx)
		return false;
	std::lock_guard<std::mutex> lock(g_mtx);
	for (const auto& [h, e] : g_em)
		if (e.ctx == ctx && e.core.Active())
			return true;
	return false;
}

void Fx_OnCanvasDestroyed(const void* canvas)
{
	std::lock_guard<std::mutex> lock(g_mtx);
	for (auto it = g_em.begin(); it != g_em.end();)
		it = (it->second.canvas == canvas) ? g_em.erase(it) : std::next(it);
	g_caps.erase(canvas);
}

void Fx_Shutdown()
{
	std::lock_guard<std::mutex> lock(g_mtx);
	g_em.clear();
	g_caps.clear();
}

FxTotals Fx_Totals()
{
	std::lock_guard<std::mutex> lock(g_mtx);
	FxTotals t;
	for (const auto& [h, e] : g_em)
	{
		++t.emitters;
		t.capacity += e.core.C;
		if (!e.core.Active())
			continue;
		++t.active;
		t.instances += e.core.Instances();
		if (e.hasLast)
			t.alive += fx::FxEmitterCore::CountAlive(e.last, e.lastInst);
	}
	return t;
}

bool Fx_ForceCpu()
{
	return g_forceCpu;
}

// ---------------------------------------------------------------------------------------------
// Lua FFI (API v5). All return 0 on bad handles / unknown canvases; safe before the device exists.

extern "C" {

// desc = float[n] laid out as FX_API.md (n <= 64; missing fields take defaults). Returns handle > 0.
PLUGIN_API int rml_fx_create(const char* win, const char* id, const float* desc, int n)
{
	const void* ctx = nullptr;
	const void* canvas = Canvas_Resolve(win, id, &ctx);
	if (!canvas)
		return 0;
	std::lock_guard<std::mutex> lock(g_mtx);
	if (g_em.size() >= kMaxEmitters)
		return 0;
	const int h = g_next++;
	Emitter& e = g_em[h];
	e.canvas = canvas;
	e.ctx = ctx;
	e.core.Init(desc, n, (uint32_t)h);
	return h;
}

PLUGIN_API int rml_fx_update(int h, const float* desc, int n)
{
	std::lock_guard<std::mutex> lock(g_mtx);
	Emitter* e = Find(h);
	if (!e || !desc || n <= 0)
		return 0;
	e->core.Update(desc, n);
	return 1;
}

// x, y = canvas-local px of the emitter origin; px_per_unit converts descriptor units to px; depth01 reserved
PLUGIN_API int rml_fx_anchor(int h, float x, float y, float px_per_unit, float depth01)
{
	std::lock_guard<std::mutex> lock(g_mtx);
	Emitter* e = Find(h);
	if (!e || !std::isfinite(x) || !std::isfinite(y))
		return 0;
	e->core.ax = x;
	e->core.ay = y;
	if (std::isfinite(px_per_unit) && px_per_unit > 0.0f)
		e->core.ppu = px_per_unit;
	if (std::isfinite(depth01))
		e->core.depth = depth01;
	return 1;
}

// p = fx, fy, ux, uy, span [, 7 half-width knots (fraction of span) at t=0,.2,.42,.70,.84,.94,1.08] [, feather px]
// n < 5 clears. Same capsule as CombatFX BF.inside_excl; masked per pixel so no particle light lands inside.
PLUGIN_API int rml_fx_exclude(const char* win, const char* id, const float* p, int n)
{
	const void* canvas = Canvas_Resolve(win, id, nullptr);
	if (!canvas)
		return 0;
	std::lock_guard<std::mutex> lock(g_mtx);
	if (!p || n < 5)
	{
		g_caps.erase(canvas);
		return 1;
	}
	Capsule c;
	fx::BuildCapsule(c.X, p, n);
	if (c.X[6] < 0.5f)
	{
		g_caps.erase(canvas);
		return 0;
	}
	g_caps[canvas] = c;
	return 1;
}

PLUGIN_API int rml_fx_burst(int h, int count)
{
	std::lock_guard<std::mutex> lock(g_mtx);
	Emitter* e = Find(h);
	if (!e || count <= 0)
		return 0;
	return e->core.Burst((uint32_t)count);
}

// fade_out != 0: stop emitting, live particles finish; 0: remove everything now
PLUGIN_API int rml_fx_stop(int h, int fade_out)
{
	std::lock_guard<std::mutex> lock(g_mtx);
	Emitter* e = Find(h);
	if (!e)
		return 0;
	e->core.Stop(fade_out != 0);
	return 1;
}

PLUGIN_API int rml_fx_destroy(int h)
{
	std::lock_guard<std::mutex> lock(g_mtx);
	return g_em.erase(h) ? 1 : 0;
}

// mode: -1 query, 0 auto (GPU when available), 1 force the CPU fallback.
// Returns 2 = GPU path drawing, 1 = CPU fallback, 0 = nothing drawn yet.
PLUGIN_API int rml_fx_mode(int mode)
{
	if (mode == 0 || mode == 1)
		g_forceCpu = mode == 1;
	return CanvasRenderer::FxPerf().mode;
}

// h > 0: one emitter; h == 0: totals. "alive=... cap=... gpu_ms=..." (gpu/cpu ms = per canvas draw, last 5 s)
PLUGIN_API int rml_fx_stats(int h, char* out, int cap)
{
	if (!out || cap < 16)
		return 0;
	const CanvasFxPerfInfo pf = CanvasRenderer::FxPerf();
	const char* mode = pf.mode == 2 ? "gpu" : (pf.mode == 1 ? "cpu" : "none");
	if (h == 0)
	{
		const FxTotals t = Fx_Totals();
		snprintf(out, (size_t)cap, "emitters=%d active=%d alive=%u cap=%u inst=%u mode=%s fx_gpu_ms=%.3f fx_cpu_ms=%.3f draws=%llu force_cpu=%d",
			t.emitters, t.active, t.alive, t.capacity, t.instances, mode, pf.gpuMs, pf.cpuMs, pf.draws, g_forceCpu ? 1 : 0);
		return 1;
	}
	std::lock_guard<std::mutex> lock(g_mtx);
	Emitter* e = Find(h);
	if (!e)
	{
		snprintf(out, (size_t)cap, "h=%d missing", h);
		return 0;
	}
	fx::FxCB cb{};
	uint32_t inst = e->lastInst;
	if (e->hasLast)
		cb = e->last;
	else
	{
		e->core.Build(cb, CapsFor(e->canvas));
		inst = e->core.Instances();
	}
	const uint32_t alive = e->core.Active() ? fx::FxEmitterCore::CountAlive(cb, inst) : 0u;
	snprintf(out, (size_t)cap, "h=%d alive=%u cap=%u inst=%u bursts=%d T=%.2f rate=%.1f active=%d stopped=%d excl=%d mode=%s fx_gpu_ms=%.3f fx_cpu_ms=%.3f",
		h, alive, e->core.C, inst, e->core.nb, e->core.T, (double)e->core.D[fx::D_RATE], e->core.Active() ? 1 : 0,
		e->core.Stopped() ? 1 : 0, CapsFor(e->canvas) ? 1 : 0, mode, pf.gpuMs, pf.cpuMs);
	return 1;
}

} // extern "C"
