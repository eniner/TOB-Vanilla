#pragma once
// Stage 1 GPU particles: emitter registry + Lua API v5 (rml_fx_*). See FX_API.md.
// Emitters are keyed by (window, canvas id) -> the canvas element; freed when the canvas element is destroyed
// (document unload / window close / autoclose), on plugin shutdown, or by rml_fx_destroy. They hold no GPU
// objects (stateless formula), so device loss only drops the renderer's shaders, which are recreated lazily.
#include "FxSim.h"
#include <cstdint>
#include <vector>

struct CanvasFxDraw
{
	fx::FxCB cb;              // anchor/capsule/clock baked in; renderer fills S2.xy (scene size)
	uint32_t instances = 0;   // slots + burst particles
	int texId = 0;            // rml_canvas_texture_load id, 0 = built-in soft dot
	bool additive = false;
	int handle = 0;
};

struct FxTotals
{
	int emitters = 0, active = 0;
	unsigned alive = 0, capacity = 0, instances = 0;
};

void Fx_Collect(const void* canvas, std::vector<CanvasFxDraw>& out);   // ticks this canvas' emitters (dt <= 100 ms)
bool Fx_ContextLive(const void* ctx);                                  // any active emitter keeps the window painting
void Fx_OnCanvasDestroyed(const void* canvas);
void Fx_Shutdown();
FxTotals Fx_Totals();
bool Fx_ForceCpu();
bool Fx_CanvasCapsule(const void* canvas, float* outX16);             // Stage 3: capsule for the post-bloom mask
