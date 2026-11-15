#include <mq/Plugin.h>   // MacroQuest plugin API (MQ2Main, eqlib, PLUGIN_API)
// TextFX registry + Lua FFI. See TextFxCore.h / shaders/tfx.hlsl / CANVAS_API.md (TextFX section).
#define STB_TRUETYPE_IMPLEMENTATION
#define STBTT_STATIC
#include "TextFx.h"
#include "ElementCanvas.h"

#include <windows.h>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace {

struct Layer
{
	const void* ctx = nullptr;
	std::vector<tfx::Num> nums;
	float caps[16]{};
	bool hasCaps = false;
	float shakeAmp = 0.f, shakeDur = 0.25f;
	double shakeT0 = -10.0;
	float bloom = 0.f;
};

std::mutex g_mtx;
std::map<const void*, Layer> g_layers;
std::map<int, const void*> g_handles;
int g_next = 1;

std::unique_ptr<tfx::Atlas> g_atlas;          // published once g_atlasState == 1
std::atomic<int> g_atlasState{ 0 };           // 0 idle, 2 building, 1 ready, -1 failed
std::atomic<int> g_gpuState{ 0 };             // renderer: 0 unknown, 1 ok, -1 unavailable
std::thread g_buildThread;
char g_fontOverride[MAX_PATH] = "";

std::mutex g_perfMtx;
double g_pCpu = 0; unsigned long long g_pDraws = 0; long long g_pGlyphs = 0, g_pParts = 0;
char g_lastPerf[200] = "";
char g_atlasMsg[400] = "";             // written by the build thread, logged from the game thread

double NowS()
{
	static LARGE_INTEGER f{};
	if (!f.QuadPart) QueryPerformanceFrequency(&f);
	LARGE_INTEGER t; QueryPerformanceCounter(&t);
	return (double)t.QuadPart / (double)f.QuadPart;
}

bool LoadBytes(const char* path, std::vector<unsigned char>& out)
{
	FILE* f = nullptr;
	if (fopen_s(&f, path, "rb") != 0 || !f) return false;
	fseek(f, 0, SEEK_END);
	const long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	if (n <= 0 || n > 64 * 1024 * 1024) { fclose(f); return false; }
	out.resize((size_t)n);
	const bool ok = fread(out.data(), 1, (size_t)n, f) == (size_t)n;
	fclose(f);
	return ok;
}

void BuildAtlasThread(std::string over)
{
	char win[MAX_PATH] = {};
	if (!GetWindowsDirectoryA(win, MAX_PATH))
		GetEnvironmentVariableA("SystemRoot", win, MAX_PATH); // no hard-coded drive
	std::vector<std::string> cands;
	if (!over.empty()) cands.push_back(over);
	for (const char* f : { "segoeuib.ttf", "arialbd.ttf", "segoeui.ttf", "arial.ttf" })
		cands.push_back(std::string(win) + "\\Fonts\\" + f);
	const double t0 = NowS();
	for (const auto& p : cands)
	{
		std::vector<unsigned char> data;
		if (!LoadBytes(p.c_str(), data)) continue;
		auto a = std::make_unique<tfx::Atlas>();
		if (!a->Build(data.data(), data.size(), p.c_str())) continue;
		{
			std::lock_guard<std::mutex> lock(g_mtx);
			g_atlas = std::move(a);
		}
		g_atlasState = 1;
		{
			std::lock_guard<std::mutex> lock(g_perfMtx);
			snprintf(g_atlasMsg, sizeof(g_atlasMsg), "tfx atlas ready font=%s build_ms=%.1f size=%dx%d", p.c_str(), (NowS() - t0) * 1000.0, tfx::kAtlasW, tfx::kAtlasH);
		}
		return;
	}
	{
		std::lock_guard<std::mutex> lock(g_perfMtx);
		snprintf(g_atlasMsg, sizeof(g_atlasMsg), "tfx atlas FAILED: no usable font (segoeuib/arialbd/segoeui/arial)");
	}
	g_atlasState = -1;
}

int StartAtlas()
{
	int s = g_atlasState.load();
	if (s == 0)
	{
		int expected = 0;
		if (g_atlasState.compare_exchange_strong(expected, 2))
		{
			if (g_buildThread.joinable()) g_buildThread.join();
			g_buildThread = std::thread(BuildAtlasThread, std::string(g_fontOverride));
		}
		s = 2;
	}
	return s;
}

void Shake(const Layer& L, double now, float& sx, float& sy)
{
	sx = sy = 0.f;
	const double age = now - L.shakeT0;
	if (L.shakeAmp <= 0.f || age < 0.0 || age > L.shakeDur) return;
	const float k = 1.f - (float)(age / L.shakeDur);
	const float a = L.shakeAmp * k * k;
	sx = a * std::sin((float)age * 57.f);
	sy = a * 0.6f * std::cos((float)age * 43.f + 1.3f);
}

tfx::Num* FindNum(int h, Layer** outL)
{
	auto it = g_handles.find(h);
	if (it == g_handles.end()) return nullptr;
	auto lit = g_layers.find(it->second);
	if (lit == g_layers.end()) return nullptr;
	for (auto& n : lit->second.nums)
		if (n.handle == h) { if (outL) *outL = &lit->second; return &n; }
	return nullptr;
}

void EraseHandlesOf(const Layer& L)
{
	for (const auto& n : L.nums) g_handles.erase(n.handle);
}

} // namespace

const tfx::Atlas* Tfx_Atlas()
{
	if (g_atlasState.load() != 1) return nullptr;
	return g_atlas.get();   // never replaced after publish (font override only before the first build)
}

void Tfx_SetGpuState(int state) { g_gpuState = state; }

bool Tfx_Collect(const void* canvas, TextFxDraw& out)
{
	const double c0 = NowS();
	const tfx::Atlas* A = Tfx_Atlas();
	std::lock_guard<std::mutex> lock(g_mtx);
	auto it = g_layers.find(canvas);
	if (it == g_layers.end() || !A) return false;
	Layer& L = it->second;
	const double now = NowS();
	float sx, sy; Shake(L, now, sx, sy);
	out.clock = now;
	for (size_t i = 0; i < L.nums.size();)
	{
		tfx::Num& n = L.nums[i];
		if (!tfx::BuildNum(*A, n, now, sx, sy, 0, out.f))
		{
			g_handles.erase(n.handle);
			L.nums.erase(L.nums.begin() + (ptrdiff_t)i);
			continue;
		}
		++i;
	}
	out.nums = (int)L.nums.size();
	if (L.hasCaps) { std::memcpy(out.caps, L.caps, sizeof(out.caps)); out.hasCaps = true; }
	out.bloom = L.bloom;
	out.cpuMs = (NowS() - c0) * 1000.0;
	return out.f.any || !L.nums.empty();
}

bool Tfx_ContextLive(const void* ctx)
{
	if (!ctx) return false;
	std::lock_guard<std::mutex> lock(g_mtx);
	for (const auto& [c, L] : g_layers)
		if (L.ctx == ctx && !L.nums.empty()) return true;
	return false;
}

void Tfx_OnCanvasDestroyed(const void* canvas)
{
	std::lock_guard<std::mutex> lock(g_mtx);
	auto it = g_layers.find(canvas);
	if (it == g_layers.end()) return;
	EraseHandlesOf(it->second);
	g_layers.erase(it);
}

void Tfx_Shutdown()
{
	if (g_buildThread.joinable()) g_buildThread.join();
	std::lock_guard<std::mutex> lock(g_mtx);
	g_layers.clear();
	g_handles.clear();
}

void Tfx_NotePerf(double cpuMs, int glyphs, int parts)
{
	std::lock_guard<std::mutex> lock(g_perfMtx);
	++g_pDraws; g_pCpu += cpuMs; g_pGlyphs += glyphs; g_pParts += parts;
}

int Tfx_PerfSuffix(char* out, int cap, double gpuMs)
{
	int nums = 0, layers = 0;
	{
		std::lock_guard<std::mutex> lock(g_mtx);
		for (const auto& [c, L] : g_layers) { ++layers; nums += (int)L.nums.size(); }
	}
	std::lock_guard<std::mutex> lock(g_perfMtx);
	if (!g_pDraws && !nums) return 0;
	const double n = g_pDraws ? (double)g_pDraws : 1.0;
	snprintf(out, (size_t)cap, " | tfx layers=%d nums=%d draws=%llu glyphs/draw=%.1f psys/draw=%.1f cpu ms/draw=%.3f gpu ms/draw=%.3f",
		layers, nums, g_pDraws, (double)g_pGlyphs / n, (double)g_pParts / n, g_pCpu / n, gpuMs);
	snprintf(g_lastPerf, sizeof(g_lastPerf), "%s", out + 3);
	g_pCpu = 0; g_pDraws = 0; g_pGlyphs = g_pParts = 0;
	return 1;
}

// ---------------------------------------------------------------------------------------------
// Lua FFI. All return 0 on unknown canvases / bad handles; safe before the device exists.
extern "C" {

// 1 = atlas + shaders ready, 0 = building (call again), -1 = no font, -2 = GPU path unavailable (FL < 11_0)
PLUGIN_API int rml_tfx_ready()
{
	{
		char msg[400] = "";
		{
			std::lock_guard<std::mutex> lock(g_perfMtx);
			if (g_atlasMsg[0]) { snprintf(msg, sizeof(msg), "%s", g_atlasMsg); g_atlasMsg[0] = 0; }
		}
		if (msg[0]) Canvas_Log(msg);
	}
	if (g_gpuState.load() < 0) return -2;
	const int s = StartAtlas();
	return s == 1 ? 1 : (s == -1 ? -1 : 0);
}

PLUGIN_API int rml_tfx_font(const char* path)
{
	if (!path || g_atlasState.load() != 0) return 0;   // only before the first build
	snprintf(g_fontOverride, sizeof(g_fontOverride), "%s", path);
	return 1;
}

// text: ASCII (others draw '?'), <= 32 chars. desc: float[48] (TextFxCore.h D_*). Returns handle, 0 = refused.
PLUGIN_API int rml_tfx_spawn(const char* win, const char* id, const char* text, const float* desc, int n)
{
	const tfx::Atlas* A = Tfx_Atlas();
	if (!A || !text || g_gpuState.load() < 0) return 0;
	const void* ctx = nullptr;
	const void* canvas = Canvas_Resolve(win, id, &ctx);
	if (!canvas) return 0;
	tfx::Num num;
	tfx::LoadDesc(num.d, desc, n);
	num.text.assign(text, strnlen(text, 32));
	if (num.text.empty()) return 0;
	const double now = NowS();
	num.born = now + num.d[tfx::D_DELAY];
	num.combo = (int)num.d[tfx::D_COMBO];
	const float k = num.d[tfx::D_SIZE] / tfx::kBasePx;
	num.boxW = tfx::TextWidth(*A, num.text, k);
	num.boxH = A->ascent * 0.72f * k;
	num.bx = num.d[tfx::D_X]; num.by = num.d[tfx::D_Y];
	std::lock_guard<std::mutex> lock(g_mtx);
	Layer& L = g_layers[canvas];
	L.ctx = ctx;
	if (L.hasCaps) tfx::PushOutOfCapsule(L.caps, num);
	if ((int)L.nums.size() >= tfx::kMaxNums)
	{
		size_t oi = L.nums.size();
		double ob = 1e300;
		for (size_t i = 0; i < L.nums.size(); ++i)
			if (L.nums[i].d[tfx::D_LOOP] < 0.5f && L.nums[i].born < ob) { ob = L.nums[i].born; oi = i; }
		if (oi == L.nums.size()) return 0;
		g_handles.erase(L.nums[oi].handle);
		L.nums.erase(L.nums.begin() + (ptrdiff_t)oi);
	}
	if (g_next <= 0) g_next = 1;
	num.handle = g_next++;
	num.seed = num.d[tfx::D_SEED] > 0.f ? (uint32_t)num.d[tfx::D_SEED] : fx::pcg((uint32_t)num.handle * 2654435761u);
	if (num.d[tfx::D_SHAKE] > 0.f && now - L.shakeT0 > 0.05)
	{
		L.shakeAmp = num.d[tfx::D_SHAKE]; L.shakeDur = num.d[tfx::D_SHAKE_T]; L.shakeT0 = num.born;
	}
	g_handles[num.handle] = canvas;
	L.nums.push_back(num);
	return num.handle;
}

// Update a live number: text (nullptr/"" = keep), combo (< 0 = keep), pulse != 0 = punch the badge now.
PLUGIN_API int rml_tfx_set(int h, const char* text, int combo, int pulse)
{
	const tfx::Atlas* A = Tfx_Atlas();
	std::lock_guard<std::mutex> lock(g_mtx);
	tfx::Num* n = FindNum(h, nullptr);
	if (!n || !A) return 0;
	if (text && *text)
	{
		n->text.assign(text, strnlen(text, 32));
		n->boxW = tfx::TextWidth(*A, n->text, n->d[tfx::D_SIZE] / tfx::kBasePx);
	}
	if (combo >= 0) n->combo = combo;
	if (pulse) n->pulse = NowS();
	return 1;
}

// fade != 0: 0.18 s fade-out, 0: remove now
PLUGIN_API int rml_tfx_kill(int h, int fade)
{
	std::lock_guard<std::mutex> lock(g_mtx);
	Layer* L = nullptr;
	tfx::Num* n = FindNum(h, &L);
	if (!n || !L) return 0;
	if (fade) { n->kill = NowS(); n->d[tfx::D_LOOP] = 0.f; return 1; }
	for (size_t i = 0; i < L->nums.size(); ++i)
		if (L->nums[i].handle == h) { L->nums.erase(L->nums.begin() + (ptrdiff_t)i); break; }
	g_handles.erase(h);
	return 1;
}

PLUGIN_API int rml_tfx_clear(const char* win, const char* id)
{
	const void* canvas = Canvas_Resolve(win, id, nullptr);
	if (!canvas) return 0;
	std::lock_guard<std::mutex> lock(g_mtx);
	auto it = g_layers.find(canvas);
	if (it == g_layers.end()) return 1;
	EraseHandlesOf(it->second);
	it->second.nums.clear();
	return 1;
}

// Body capsule for this canvas' numbers (same float layout as rml_fx_exclude). n < 5 clears.
PLUGIN_API int rml_tfx_exclude(const char* win, const char* id, const float* p, int n)
{
	const void* ctx = nullptr;
	const void* canvas = Canvas_Resolve(win, id, &ctx);
	if (!canvas) return 0;
	std::lock_guard<std::mutex> lock(g_mtx);
	Layer& L = g_layers[canvas];
	L.ctx = ctx;
	if (!p || n < 5) { L.hasCaps = false; return 1; }
	fx::BuildCapsule(L.caps, p, n);
	L.hasCaps = L.caps[6] >= 0.5f;
	return L.hasCaps ? 1 : 0;
}

// Shake the number layer (text + its particles only; the 3D view is not touched).
PLUGIN_API int rml_tfx_shake(const char* win, const char* id, float px, float seconds)
{
	const void* ctx = nullptr;
	const void* canvas = Canvas_Resolve(win, id, &ctx);
	if (!canvas) return 0;
	std::lock_guard<std::mutex> lock(g_mtx);
	Layer& L = g_layers[canvas];
	L.ctx = ctx;
	L.shakeAmp = tfx::Clamp(px, 0.f, 14.f);
	L.shakeDur = tfx::Clamp(seconds, 0.05f, 1.f);
	L.shakeT0 = NowS();
	return 1;
}

// Bloom used while this canvas has numbers (max with rml_canvas_bloom). Effects layer only, capsule-masked.
PLUGIN_API int rml_tfx_bloom(const char* win, const char* id, float strength)
{
	const void* ctx = nullptr;
	const void* canvas = Canvas_Resolve(win, id, &ctx);
	if (!canvas) return 0;
	std::lock_guard<std::mutex> lock(g_mtx);
	Layer& L = g_layers[canvas];
	L.ctx = ctx;
	L.bloom = tfx::Clamp(strength, 0.f, 3.f);
	return 1;
}

PLUGIN_API int rml_tfx_stats(char* out, int cap)
{
	if (!out || cap < 16) return 0;
	int nums = 0, layers = 0, caps = 0;
	{
		std::lock_guard<std::mutex> lock(g_mtx);
		for (const auto& [c, L] : g_layers) { ++layers; nums += (int)L.nums.size(); caps += L.hasCaps ? 1 : 0; }
	}
	const tfx::Atlas* A = Tfx_Atlas();
	std::lock_guard<std::mutex> lock(g_perfMtx);
	snprintf(out, (size_t)cap, "atlas=%d gpu=%d font=%s layers=%d nums=%d capsules=%d last=[%s]",
		g_atlasState.load(), g_gpuState.load(), A ? A->fontPath : "-", layers, nums, caps, g_lastPerf);
	return 1;
}

} // extern "C"
