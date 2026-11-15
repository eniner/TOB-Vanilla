#pragma once

#include <cstdint>
#include <vector>

#include "FxSystem.h"

struct TextFxDraw;

struct CanvasGpuVert
{
	float x, y;
	uint32_t color;
};

struct CanvasTriBatch
{
	int flags = 0;
	std::vector<CanvasGpuVert> verts;
};

struct CanvasSpriteInst
{
	float x, y, rx, ry;
	float r, g, b, a;
};

struct CanvasSpriteBatch
{
	int flags = 0;
	std::vector<CanvasSpriteInst> items;
};

struct CanvasSpriteExInst
{
	float x, y, sx, sy, angle;
	float r, g, b, a;
	int tex_id = 0;
	int mode = 0;
};

struct CanvasFrame
{
	int bgStyle = 0;
	float bgTime = 0.f;
	float bgEnergy = 0.f;
	float bgBeat = 0.f;
	float trailDecay = 0.f;
	float bloomStrength = 1.45f;
};

// Stage 1 fx: last 5 s perf window (rml_fx_stats / rml_fx_mode)
struct CanvasFxPerfInfo
{
	int mode = 0;               // 0 nothing drawn yet, 1 CPU fallback, 2 GPU (vs_5_0/ps_5_0)
	double gpuMs = -1.0;        // GPU ms per canvas draw that had fx (timestamp queries), -1 = n/a
	double cpuMs = 0.0;         // CPU ms per canvas draw spent submitting (GPU) or simulating (fallback) fx
	unsigned long long draws = 0;
};

struct CanvasDrawDiag
{
	char reason[80] = "never";
	int entered = 0;
	int composite = 0;
	int fallback = 0;
	long deviceHr = 0;
	unsigned long long device = 0;
	unsigned long long mqDevice = 0;
	unsigned long long bakRtv = 0;
	int sceneW = 0, sceneH = 0, sceneOk = 0;
	float ox = 0, oy = 0, cw = 0, ch = 0;
	float destX = 0, destY = 0, destW = 0, destH = 0;
	float scL = 0, scT = 0, scR = 0, scB = 0;
	int scInL = 0, scInT = 0, scInR = 0, scInB = 0;
	float vpW = 0, vpH = 0;
	int nvp = 0, nsc = 0;
	int batches = 0, verts = 0, sprites = 0, spriteItems = 0;
	int bgStyle = 0;
};

class CanvasRenderer
{
public:
	static CanvasRenderer& Get();
	static const CanvasDrawDiag& LastDiag();
	void OnLostDevice();
	static void RequestProbe();
	static void SetPaintTarget(const char* win, void* tex, void* rtv, int w, int h);
	static void SetProbeElementInfo(const char* info);
	int LoadTexture(const char* path);
	void Draw(const std::vector<CanvasTriBatch>& batches,
		const std::vector<CanvasSpriteBatch>& sprites,
		const std::vector<CanvasSpriteExInst>& spritesEx,
		const CanvasFrame& frame,
		float offsetX, float offsetY, float width, float height,
		float* lastDrawMs, const void* owner = nullptr,    // owner = canvas element (per-canvas RT cache key)
		const std::vector<CanvasFxDraw>* fx = nullptr,     // Stage 1 particle emitters of this canvas
		const TextFxDraw* tfx = nullptr);                  // TextFX numbers of this canvas (drawn into the scene)
	// Last 5 s perf window ("perf ... cpu ms/draw ... gpu ms/draw ... rt_creates ..."), see rml_canvas_perf.
	static int PerfString(char* out, int cap);
	static CanvasFxPerfInfo FxPerf();
};
