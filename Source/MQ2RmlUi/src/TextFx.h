#pragma once
// TextFX (2026-11-14): GPU combat numbers for CombatFX themes (rml_tfx_* exports, rml_features() & 16384).
// Numbers belong to a canvas element (window + canvas id), like the rml_fx_* emitters, and are freed with it.
#include "TextFxCore.h"

struct TextFxDraw
{
	tfx::FrameOut f;
	float caps[16]{};
	bool hasCaps = false;
	float bloom = 0.f;
	double clock = 0.0;
	double cpuMs = 0.0;     // collect/build time on the CPU for this canvas
	int nums = 0;
};

bool Tfx_Collect(const void* canvas, TextFxDraw& out);   // false = nothing to draw for this canvas
bool Tfx_ContextLive(const void* ctx);
void Tfx_OnCanvasDestroyed(const void* canvas);
void Tfx_Shutdown();
const tfx::Atlas* Tfx_Atlas();                           // nullptr until the background build finished
void Tfx_SetGpuState(int state);                         // renderer: 1 = shaders ok, -1 = unavailable
void Tfx_NotePerf(double cpuMs, int glyphs, int parts);
int Tfx_PerfSuffix(char* out, int cap, double gpuMs);    // " | tfx ..." for the 5 s perf line, 0 = nothing to add
