// Actor material tint proof (client-side only, local player + its attached armour actors).
//
// Client: eqgame.exe "Sep 11 2025 11:54:10" + its EQGraphics.dll (SHA-256 E8A72275...). RVAs are of that
// EQGraphics build (preferred base 0x180000000). Verified on the box (static disassembly) and on the running
// client (read-only memory reads of the local player's actors). Evidence:
//
// Body actor: PlayerClient + 0x1170 (mActorClient 0xFB8 + pActor 0x1B8), vftable +0x2B9D90 ("class M").
//   vft[0x228] = +0x60E80 SetMaterialTint(int index, const RGB*)  (MSVC reverse-overload order: eqlib's comment
//   for 0x228/0x230 is swapped; eqgame's call [ActorClient+0x1B8]->vft[0x228](0, &rgb) confirms).
//   0x60E80: X = vft[0x4C8]() (= *(actor+0x110+0xD8)); if vft[0x570]() X->vft[0x180](i, rgb) -> palette [X+0x88]
//   palette set +0x25560: if (i < pal+0x18 count) pal+0x20 tints[i] = rgb (0 -> FFFFFFFF), pal+0x30 = 1.
//   vft[0x230] (tint all) also stamps actor+0xB8 via +0x53A90 (not undoable) -> never used.
// Attachments: vft[0x358] GetAttachedActor(i) = +0x5DE30: p = *(actor+0x1F8+i*8) (i != -1); p ? p->vft[0x10]() : 0
//   attach point vftable +0x2B99E8: [0x10] = +0x9490 "mov rax,[rcx+8]" (attached actor), [0x0] = +0x57BA0
//   "mov rax,[rcx+0x38]; mov rax,[rax+0x98]" (point name, e.g. DWMCHEST_POINT_TRACK). HasAttachedActor (+0x5F090)
//   loops i = 0..0x1B -> 28 points.
//   Actor definition: vft[0x150] = +0x5ECD0 "mov rax,[rcx+0x1D0]"; def vftable +0x2B97E8 [0] = +0x541C0 GetTag ->
//   *(def+0x10) (e.g. IT6120_ACTORDEF).
//   "class A" vftable +0x2BA648 (hair/beard/chest plate): same vft[0x228]/[0x4C8]/[0x570] as class M, sub vft
//   +0x2B9CC0, X vft +0x2BAD08, palette [X+0x88].
//   "class B" vftable +0x2BC1B0 (gauntlets/legs/shoulders): vft[0x228] = +0x752F0: X = vft[0x4C0]() (+0x74D10:
//   sub(+0x110) vft +0x2BC0E0 [0x78] = +0x5ED00 "mov rax,[rcx+0xD8]"), X->vft[0x108](i, rgb) = +0x77C40:
//   palette = X->vft[0x70]() = +0x76410 "mov rax,[rcx+0x50]", then the same bounds-checked +0x25560.
// Live (De'Immortal, dwarf): point 11 DWMCHEST_POINT_TRACK -> IT6120_ACTORDEF class A, 2 materials FFF0F0F0.
//
// We only call vft[0x228]. Palettes, names and ArmorColor are read, never written. Every read and call is inside
// SEH; a fault turns the feature off for the session.
#include "NimbusClientOffsets.h"   // <mq/Plugin.h>, eqlib offsets (A), version-string RVAs
#include "ActorMaterial.h"
#include <windows.h>
#include <cstdio>
#include <cstring>
#include <cstdarg>

void Canvas_Log(const char* line);   // ElementCanvas.cpp

namespace {

using namespace NimbusOffsets;

constexpr size_t kOffArmorColor = offsetof(eqlib::PlayerZoneClient, mActorClient) + offsetof(eqlib::ActorClient, ArmorColor);
static_assert(kOffArmorColor == 0x101C, "eqlib mActorClient.ArmorColor differs from the RE'd client");

// ---- EQGraphics.dll RVAs (base 0x180000000)
constexpr uintptr_t kVftM = 0x2B9D90, kVftA = 0x2BA648, kVftB = 0x2BC1B0;
constexpr uintptr_t kSubVftMA = 0x2B9CC0, kSubVftB = 0x2BC0E0;
constexpr uintptr_t kXVftMA = 0x2BAD08, kXVftB = 0x2BC868;
constexpr uintptr_t kPtVft = 0x2B99E8, kDefVft = 0x2B97E8;
constexpr uintptr_t kFnTintMA = 0x060E80, kFnGetXMA = 0x05ED10, kFnPalPtrMA = 0x05ED30, kFnSubGetX = 0x05ED00;
constexpr uintptr_t kFnXPalMA = 0x0650E0, kFnXTintMA = 0x066C90, kFnPalSet = 0x025560;
constexpr uintptr_t kFnTintB = 0x0752F0, kFnGetXB = 0x074D10, kFnXTintB = 0x077C40, kFnXPalB = 0x076410;
constexpr uintptr_t kFnPtActor = 0x009490, kFnPtName = 0x057BA0, kFnGetDef = 0x05ECD0, kFnDefTag = 0x0541C0;
constexpr size_t kSlotTint = 0x228;
constexpr size_t kOffSub = 0x110, kOffSubX = 0xD8, kOffXPalMA = 0x88, kOffXPalB = 0x50, kOffPalCount = 0x18, kOffPalTints = 0x20;
constexpr size_t kOffAttach = 0x1F8, kOffDef = 0x1D0, kOffDefTag = 0x10, kOffPtActor = 8, kOffPtInfo = 0x38, kOffPtInfoName = 0x98;
constexpr int kNumAttach = 28, kMaxMat = 256, kMaxAttMat = 32;

struct Sig { uintptr_t rva; unsigned char b[16]; size_t n; const char* what; };
const Sig kSigs[] = {
	{ kFnTintMA, {0x4d,0x85,0xc0,0x74,0x65,0x48,0x89,0x6c,0x24,0x10,0x48,0x89,0x74,0x24,0x18,0x57}, 16, "tint M/A" },
	{ kFnPalSet, {0x3b,0x51,0x18,0x73,0x25,0x45,0x8b,0x00,0x41,0xb9,0xff,0xff,0xff,0xff,0x48,0x8b}, 16, "palette set" },
	{ kFnXTintMA,{0x48,0x89,0x5c,0x24,0x08,0x48,0x89,0x74,0x24,0x10,0x57,0x48,0x83,0xec,0x20,0x48}, 16, "X tint M/A" },
	{ kFnXPalMA, {0x48,0x8b,0x81,0x88,0x00,0x00,0x00,0xc3}, 8, "X palette M/A" },
	{ kFnSubGetX,{0x48,0x8b,0x81,0xd8,0x00,0x00,0x00,0xc3}, 8, "sub getX" },
	{ kFnGetXMA, {0x48,0x81,0xc1,0x10,0x01,0x00,0x00,0x48,0x8b,0x01,0x48,0xff,0xa0,0x88,0x00,0x00}, 16, "getX M/A" },
	{ kFnPalPtrMA,{0x48,0x83,0xec,0x28,0x48,0x81,0xc1,0x10,0x01,0x00,0x00,0x48,0x8b,0x01,0xff,0x90}, 16, "pal ptr M/A" },
	{ kFnTintB,  {0x4d,0x85,0xc0,0x74,0x39,0x48,0x89,0x5c,0x24,0x08,0x57,0x48,0x83,0xec,0x20,0x48}, 16, "tint B" },
	{ kFnGetXB,  {0x48,0x81,0xc1,0x10,0x01,0x00,0x00,0x48,0x8b,0x01,0x48,0xff,0x60,0x78}, 14, "getX B" },
	{ kFnXTintB, {0x48,0x89,0x5c,0x24,0x08,0x48,0x89,0x74,0x24,0x10,0x57,0x48,0x83,0xec,0x20,0x48}, 16, "X tint B" },
	{ kFnXPalB,  {0x48,0x8b,0x41,0x50,0xc3}, 5, "X palette B" },
	{ kFnPtActor,{0x48,0x8b,0x41,0x08,0xc3}, 5, "point actor" },
	{ kFnPtName, {0x48,0x8b,0x41,0x38,0x48,0x8b,0x80,0x98,0x00,0x00,0x00,0xc3}, 12, "point name" },
	{ kFnGetDef, {0x48,0x8b,0x81,0xd0,0x01,0x00,0x00,0xc3}, 8, "get definition" },
	{ kFnDefTag, {0x48,0x83,0xc1,0x08,0xe9}, 5, "def tag" },
};
struct Slot { uintptr_t vft; size_t off; uintptr_t fn; };
const Slot kSlots[] = {
	{ kVftM, 0x228, kFnTintMA }, { kVftM, 0x4C8, kFnGetXMA }, { kVftM, 0x570, kFnPalPtrMA }, { kVftM, 0x150, kFnGetDef },
	{ kVftA, 0x228, kFnTintMA }, { kVftA, 0x4C8, kFnGetXMA }, { kVftA, 0x570, kFnPalPtrMA }, { kVftA, 0x150, kFnGetDef },
	{ kVftB, 0x228, kFnTintB },  { kVftB, 0x4C0, kFnGetXB },  { kVftB, 0x150, kFnGetDef },
	{ kSubVftMA, 0x88, kFnSubGetX }, { kSubVftB, 0x78, kFnSubGetX },
	{ kXVftMA, 0x68, kFnXPalMA }, { kXVftMA, 0x180, kFnXTintMA },
	{ kXVftB, 0x70, kFnXPalB }, { kXVftB, 0x108, kFnXTintB },
	{ kPtVft, 0x10, kFnPtActor }, { kPtVft, 0x0, kFnPtName }, { kDefVft, 0x0, kFnDefTag },
};

using TintIdxFn = void(__fastcall*)(void* actor, int index, const uint32_t* rgb);

struct Module { uintptr_t base = 0, size = 0; };
enum Op { kOpTint, kOpAll, kOpSlot, kOpAttTint, kOpAttAll, kOpReset };
struct Req { Op op; int a; int b; uint32_t argb; };

// one actor whose palette we can tint
struct MatTarget
{
	uintptr_t actor = 0;
	char cls = '-';        // 'M' body, 'A', 'B', '?' unverified class, '-' none
	uintptr_t tints = 0;
	int count = 0;
	char point[40] = "";
	char def[40] = "";
};
struct Snap { uintptr_t actor = 0; int count = 0; bool changed = false; uint32_t v[kMaxMat] = {}; };

struct State
{
	Module game, gfx;
	int verified = 0;
	char verifyWhy[64] = "";
	bool disabled = false;
	Req q[32]; int nq = 0;
	Snap body;
	Snap att[kNumAttach];
	uint32_t armor[9] = {};
	int live = -1;
	MatTarget bodyT;
	MatTarget attT[kNumAttach];
	uintptr_t actorVft = 0;
	int calls = 0;
	char last[200] = "idle";
	char status[4096] = "";
};
State S;

Module FindModule(const char* name)
{
	Module m;
	HMODULE h = GetModuleHandleA(name);
	if (!h) return m;
	m.base = (uintptr_t)h;
	__try
	{
		auto dos = (IMAGE_DOS_HEADER*)h;
		auto nt = (IMAGE_NT_HEADERS64*)(m.base + dos->e_lfanew);
		if (dos->e_magic == IMAGE_DOS_SIGNATURE && nt->Signature == IMAGE_NT_SIGNATURE && nt->FileHeader.Machine == IMAGE_FILE_MACHINE_AMD64)
			m.size = nt->OptionalHeader.SizeOfImage;
	}
	__except (EXCEPTION_EXECUTE_HANDLER) { m.size = 0; }
	if (!m.size) m.base = 0;
	return m;
}
bool InModule(const Module& m, uintptr_t p, size_t n = 1) { return m.base && p >= m.base && p + n <= m.base + m.size; }
bool HeapPtr(uintptr_t p) { return p >= 0x10000 && p < 0x00007FFFFFFF0000ull && !InModule(S.game, p) && !InModule(S.gfx, p); }
bool HeapPtr8(uintptr_t p) { return HeapPtr(p) && (p & 7) == 0; }

void Log(const char* fmt, ...)
{
	char line[400];
	va_list ap; va_start(ap, fmt);
	int n = snprintf(line, sizeof(line), "matproof ");
	vsnprintf(line + n, sizeof(line) - n, fmt, ap);
	va_end(ap);
	Canvas_Log(line);
	strncpy(S.last, line + n, sizeof(S.last) - 1);
	S.last[sizeof(S.last) - 1] = 0;
}

void Fault(const char* where, DWORD code)
{
	S.disabled = true; S.nq = 0;
	Log("FAULT in %s code=0x%08lX -> material proof disabled for this session", where, code);
}

int VerifyBuild()
{
	S.game = FindModule("eqgame.exe");
	if (!S.game.base) S.game = FindModule(nullptr);
	S.gfx = FindModule("EQGraphics.dll");
	if (!S.game.base || !S.gfx.base) { strcpy(S.verifyWhy, "module not found"); return -1; }
	__try
	{
		const uintptr_t g = S.gfx.base;
		if (memcmp((void*)(S.game.base + kRvaVerDate), kExpectedDate, sizeof(kExpectedDate)) != 0 ||
			memcmp((void*)(S.game.base + kRvaVerTime), kExpectedTime, sizeof(kExpectedTime)) != 0) { strcpy(S.verifyWhy, "eqgame version string"); return -1; }
		for (const Sig& s : kSigs)
			if (memcmp((void*)(g + s.rva), s.b, s.n) != 0) { snprintf(S.verifyWhy, sizeof(S.verifyWhy), "sig %s", s.what); return -1; }
		for (const Slot& s : kSlots)
			if (((const uintptr_t*)(g + s.vft))[s.off / 8] != g + s.fn) { snprintf(S.verifyWhy, sizeof(S.verifyWhy), "vft %llX[%llX]", (unsigned long long)s.vft, (unsigned long long)s.off); return -1; }
	}
	__except (EXCEPTION_EXECUTE_HANDLER) { strcpy(S.verifyWhy, "fault while verifying"); return -1; }
	strcpy(S.verifyWhy, "ok");
	return 1;
}

bool EnsureVerified()
{
	if (S.verified == 0)
	{
		S.verified = VerifyBuild();
		Log("verify: %s", S.verifyWhy);
	}
	return S.verified == 1 && !S.disabled;
}

void CopyStr(char* dst, size_t cap, uintptr_t src)
{   // SEH caller; bounded printable copy
	dst[0] = 0;
	if (!HeapPtr(src)) return;
	size_t i = 0;
	for (; i + 1 < cap; ++i)
	{
		char c = ((const char*)src)[i];
		if (!c) break;
		dst[i] = (c >= 32 && c < 127) ? c : '?';
	}
	dst[i] = 0;
}

// Fill t from actor a (SEH caller). 0 ok, else reason.
int ResolveActorRaw(uintptr_t a, MatTarget* t)
{
	t->actor = a; t->cls = '-'; t->tints = 0; t->count = 0; t->def[0] = 0;
	if (!HeapPtr8(a)) return 20;
	const uintptr_t g = S.gfx.base, vft = *(uintptr_t*)a;
	if (!InModule(S.gfx, vft, 8)) return 21;
	char cls = vft == g + kVftM ? 'M' : vft == g + kVftA ? 'A' : vft == g + kVftB ? 'B' : '?';
	t->cls = cls;
	uintptr_t def = *(uintptr_t*)(a + kOffDef);
	if (HeapPtr(def) && *(uintptr_t*)def == g + kDefVft) CopyStr(t->def, sizeof(t->def), *(uintptr_t*)(def + kOffDefTag));
	if (cls == '?') return 22;
	const uintptr_t sub = *(uintptr_t*)(a + kOffSub);
	if (sub != g + (cls == 'B' ? kSubVftB : kSubVftMA)) return 23;
	uintptr_t x = *(uintptr_t*)(a + kOffSub + kOffSubX);
	if (!HeapPtr8(x) || *(uintptr_t*)x != g + (cls == 'B' ? kXVftB : kXVftMA)) return 24;
	uintptr_t pal = *(uintptr_t*)(x + (cls == 'B' ? kOffXPalB : kOffXPalMA));
	if (!HeapPtr8(pal)) return 25;
	int n = (int)*(uint32_t*)(pal + kOffPalCount);
	uintptr_t tints = *(uintptr_t*)(pal + kOffPalTints);
	if (n <= 0 || n > kMaxMat || !HeapPtr(tints) || (tints & 3)) return 26;
	t->tints = tints; t->count = n;
	return 0;
}
int ResolveActor(uintptr_t a, MatTarget* t)
{
	__try { return ResolveActorRaw(a, t); }
	__except (EXCEPTION_EXECUTE_HANDLER) { t->count = 0; return 7; }
}

// attach point i of the body actor. 0 ok, 1 no point, 2 empty, else reason
int ResolveAttach(uintptr_t body, int i, MatTarget* t)
{
	*t = MatTarget();
	__try
	{
		uintptr_t pt = *(uintptr_t*)(body + kOffAttach + (size_t)i * 8);
		if (!pt) return 1;
		if (!HeapPtr8(pt) || *(uintptr_t*)pt != S.gfx.base + kPtVft) return 30;
		uintptr_t info = *(uintptr_t*)(pt + kOffPtInfo);
		if (HeapPtr8(info)) CopyStr(t->point, sizeof(t->point), *(uintptr_t*)(info + kOffPtInfoName));
		uintptr_t a = *(uintptr_t*)(pt + kOffPtActor);
		if (!a) return 2;
		char keep[40]; memcpy(keep, t->point, sizeof(keep));
		int r = ResolveActorRaw(a, t);
		memcpy(t->point, keep, sizeof(keep));
		return r;
	}
	__except (EXCEPTION_EXECUTE_HANDLER) { t->count = 0; return 7; }
}

// body actor (must be class M). 0 ok
int ReadLive(uintptr_t* plOut)
{
	*plOut = 0;
	uintptr_t body = 0;
	__try
	{
		uintptr_t pl = *(uintptr_t*)(S.game.base + kRvaLocalPlayer);
		if (!HeapPtr8(pl)) return 1;
		if (!InModule(S.game, *(uintptr_t*)pl, 8)) return 2;
		uintptr_t a = *(uintptr_t*)(pl + kOffActor);
		if (!HeapPtr8(a)) return 3;
		S.actorVft = *(uintptr_t*)a;
		if (!InModule(S.gfx, S.actorVft, 8)) return 4;
		if (S.actorVft != S.gfx.base + kVftM) return 5;
		*plOut = pl;
		body = a;
	}
	__except (EXCEPTION_EXECUTE_HANDLER) { return 7; }
	return ResolveActor(body, &S.bodyT);
}

int ReadTints(uintptr_t t, int n, uint32_t* out)
{
	__try { memcpy(out, (const void*)t, (size_t)n * 4); }
	__except (EXCEPTION_EXECUTE_HANDLER) { return -1; }
	return 0;
}
int ReadArmor(uintptr_t pl, uint32_t* out)
{
	__try { memcpy(out, (const void*)(pl + kOffArmorColor), 9 * 4); }
	__except (EXCEPTION_EXECUTE_HANDLER) { return -1; }
	return 0;
}
int CallTint(uintptr_t actor, int index, uint32_t argb, DWORD* code)
{
	uint32_t rgb = argb;
	__try
	{
		TintIdxFn fn = (TintIdxFn)(*(uintptr_t**)actor)[kSlotTint / 8];
		fn((void*)actor, index, &rgb);
	}
	__except (*code = GetExceptionCode(), EXCEPTION_EXECUTE_HANDLER) { return -1; }
	return 0;
}

int Queue(Op op, int a, int b, uint32_t argb)
{
	if (!EnsureVerified()) return S.disabled ? -1 : -2;
	if (S.nq >= (int)(sizeof(S.q) / sizeof(S.q[0]))) return -4;
	S.q[S.nq++] = { op, a, b, argb };
	return S.nq;
}

// 1 changed, 0 skipped, -1 fault
int TintIndex(const MatTarget& t, Snap& s, int idx, uint32_t argb)
{
	if (t.cls != 'M' && t.cls != 'A' && t.cls != 'B') return 0;
	if (idx < 0 || idx >= t.count) return 0;
	DWORD code = 0;
	if (CallTint(t.actor, idx, argb, &code) != 0) { Fault("SetMaterialTint", code); return -1; }
	++S.calls; s.changed = true;
	return 1;
}

// keep a snapshot in sync with a live target
void SyncSnap(const MatTarget& t, Snap& s, int cap)
{
	if (t.count <= 0 || t.count > cap) { s = Snap(); return; }
	if (t.actor != s.actor || t.count != s.count)
	{
		s.actor = t.actor; s.count = t.count; s.changed = false;
		if (ReadTints(t.tints, t.count, s.v) != 0) s = Snap();
	}
	else if (!s.changed)
	{
		if (ReadTints(t.tints, t.count, s.v) != 0) s = Snap();
	}
}

int RestoreTarget(const MatTarget& t, Snap& s)
{
	if (!s.changed || t.actor != s.actor || t.count != s.count) { s.changed = false; return 0; }
	int done = 0;
	for (int i = 0; i < s.count; ++i)
	{
		uint32_t cur = 0;
		if (ReadTints(t.tints + (size_t)i * 4, 1, &cur) != 0) { Fault("read tint", 0); return -1; }
		if (cur != s.v[i]) { int d = TintIndex(t, s, i, s.v[i]); if (d < 0) return -1; done += d; }
	}
	s.changed = false;
	return done;
}

void Process(uintptr_t pl)
{
	const MatTarget& bt = S.bodyT;
	for (int k = 0; k < S.nq && !S.disabled; ++k)
	{
		const Req r = S.q[k];
		int done = 0;
		switch (r.op)
		{
		case kOpTint:
			if (r.a < 0 || r.a >= bt.count) { Log("tint index %d out of range (count %d)", r.a, bt.count); break; }
			done = TintIndex(bt, S.body, r.a, r.argb);
			Log("body tint index %d -> %08X (%d)", r.a, r.argb, done);
			break;
		case kOpAll:
			for (int i = 0; i < bt.count && done >= 0; ++i) { int d = TintIndex(bt, S.body, i, r.argb); done = d < 0 ? -1 : done + d; }
			Log("body tint all %d indices -> %08X", done, r.argb);
			break;
		case kOpSlot:
		{
			if (r.a < 0 || r.a > 8) { Log("slot %d out of range 0..8", r.a); break; }
			const uint32_t want = S.armor[r.a];
			if ((want & 0xFFFFFF) == 0) { Log("slot %d has no ArmorColor (%08X)", r.a, want); break; }
			int other = -1;
			for (int s = 0; s < 9; ++s) if (s != r.a && S.armor[s] == want) other = s;
			if (other >= 0) { Log("slot %d colour %08X also used by slot %d: ambiguous, use rml_mat_tint(index)", r.a, want, other); break; }
			char idxs[200] = ""; size_t n = 0;
			for (int i = 0; i < S.body.count && done >= 0; ++i)
				if (S.body.v[i] == want)
				{
					int d = TintIndex(bt, S.body, i, r.argb);
					if (d < 0) { done = -1; break; }
					done += d;
					if (n < sizeof(idxs) - 8) n += snprintf(idxs + n, sizeof(idxs) - n, "%d,", i);
				}
			Log("body tint slot %d (orig %08X) indices [%s] -> %08X (%d)", r.a, want, idxs, r.argb, done);
			break;
		}
		case kOpAttTint:
		case kOpAttAll:
		{
			if (r.a < 0 || r.a >= kNumAttach) { Log("attach %d out of range 0..27", r.a); break; }
			const MatTarget& t = S.attT[r.a];
			if (t.count <= 0 || t.actor != S.att[r.a].actor) { Log("attach %d has no verified actor/palette (cls %c)", r.a, t.cls); break; }
			if (r.op == kOpAttTint)
			{
				if (r.b < 0 || r.b >= t.count) { Log("attach %d index %d out of range (count %d)", r.a, r.b, t.count); break; }
				done = TintIndex(t, S.att[r.a], r.b, r.argb);
			}
			else
				for (int i = 0; i < t.count && done >= 0; ++i) { int d = TintIndex(t, S.att[r.a], i, r.argb); done = d < 0 ? -1 : done + d; }
			Log("attach %d %s/%s idx %d -> %08X (%d)", r.a, t.point, t.def, r.op == kOpAttTint ? r.b : -1, r.argb, done);
			break;
		}
		case kOpReset:
		{
			int d = RestoreTarget(bt, S.body);
			done = d < 0 ? -1 : d;
			for (int i = 0; i < kNumAttach && done >= 0; ++i) { d = RestoreTarget(S.attT[i], S.att[i]); done = d < 0 ? -1 : done + d; }
			Log("reset: %d indices restored", done);
			break;
		}
		}
	}
	S.nq = 0;
}

void ReadAll(uintptr_t pl)
{
	for (int i = 0; i < kNumAttach; ++i)
	{
		int r = ResolveAttach(S.bodyT.actor, i, &S.attT[i]);
		if (r == 7) { Fault("read attach", 0); return; }
		if (r != 0) S.attT[i].count = 0;
	}
	(void)pl;
}

void ForgetAll()
{
	S.body = Snap();
	for (auto& s : S.att) s = Snap();
	S.nq = 0;
}

} // namespace

bool Mat_Available() { return EnsureVerified(); }

void Mat_Pulse(bool zoning)
{
	if (S.verified != 1 || S.disabled) return;
	if (zoning) { ForgetAll(); return; }
	uintptr_t pl;
	S.live = ReadLive(&pl);
	if (S.live == 7) { Fault("read", 0); return; }
	if (S.live != 0) { S.bodyT = MatTarget(); return; }   // char select / zoning / unverified actor class: queue waits
	ReadAll(pl);
	if (S.disabled) return;
	if (S.bodyT.actor != S.body.actor || !S.body.changed)
		if (ReadArmor(pl, S.armor) != 0) { Fault("armor", 0); return; }
	SyncSnap(S.bodyT, S.body, kMaxMat);
	for (int i = 0; i < kNumAttach; ++i) SyncSnap(S.attT[i], S.att[i], kMaxAttMat);
	if (S.nq) Process(pl);
}

void Mat_BeginZone() { ForgetAll(); }

void Mat_Shutdown()
{
	if (S.verified != 1 || S.disabled) return;
	uintptr_t pl;
	if (ReadLive(&pl) != 0) return;
	ReadAll(pl);
	if (S.disabled) return;
	S.nq = 0; S.q[S.nq++] = { kOpReset, 0, 0, 0 };
	Process(pl);
}

int Mat_Tint(int index, uint32_t argb) { if (index < 0 || index >= kMaxMat) return -3; return Queue(kOpTint, index, 0, argb); }
int Mat_TintAll(uint32_t argb) { return Queue(kOpAll, 0, 0, argb); }
int Mat_TintSlot(int slot, uint32_t argb) { if (slot < 0 || slot > 8) return -3; return Queue(kOpSlot, slot, 0, argb); }
int Mat_TintAttach(int attach, int index, uint32_t argb)
{
	if (attach < 0 || attach >= kNumAttach || index < 0 || index >= kMaxAttMat) return -3;
	return Queue(kOpAttTint, attach, index, argb);
}
int Mat_TintAttachAll(int attach, uint32_t argb) { if (attach < 0 || attach >= kNumAttach) return -3; return Queue(kOpAttAll, attach, 0, argb); }
int Mat_Reset() { return Queue(kOpReset, 0, 0, 0); }

int Mat_AttachFind(const char* text)
{
	if (!text || !*text || !EnsureVerified()) return -1;
	uintptr_t pl;
	if (ReadLive(&pl) != 0) return -1;
	MatTarget t;
	for (int i = 0; i < kNumAttach; ++i)
	{
		if (ResolveAttach(S.bodyT.actor, i, &t) != 0) continue;
		char hay[96];
		snprintf(hay, sizeof(hay), "%s|%s", t.point, t.def);
		_strupr_s(hay);
		char needle[64]; strncpy(needle, text, sizeof(needle) - 1); needle[sizeof(needle) - 1] = 0; _strupr_s(needle);
		if (strstr(hay, needle)) return i;
	}
	return -1;
}

const char* Mat_Status()
{
	EnsureVerified();
	char body[48 * 9 + 1] = "";
	char att[2600] = "";
	if (S.verified == 1 && !S.disabled)
	{
		uintptr_t pl;
		if (ReadLive(&pl) == 0)
		{
			uint32_t v[kMaxMat];
			int n = 0;
			const MatTarget& b = S.bodyT;
			if (ReadTints(b.tints, b.count, v) == 0)
				for (int i = 0; i < b.count && i < 48; ++i) n += snprintf(body + n, sizeof(body) - n, "%X%s", v[i], i + 1 < b.count ? "," : "");
			size_t m = 0;
			for (int i = 0; i < kNumAttach && m < sizeof(att) - 160; ++i)
			{
				MatTarget t;
				int r = ResolveAttach(b.actor, i, &t);
				if (r == 1) continue;
				m += snprintf(att + m, sizeof(att) - m, " %d:%s:%s:%c:r%d:n%d:", i, t.point[0] ? t.point : "-", t.def[0] ? t.def : "-", t.cls, r, t.count);
				if (r == 0 && t.count > 0 && t.count <= kMaxAttMat && ReadTints(t.tints, t.count, v) == 0)
					for (int k = 0; k < t.count && k < 8 && m < sizeof(att) - 12; ++k) m += snprintf(att + m, sizeof(att) - m, "%X%s", v[k], k + 1 < t.count ? "," : "");
				if (S.att[i].changed) m += snprintf(att + m, sizeof(att) - m, "*");
			}
		}
	}
	char arm[9 * 9 + 1] = ""; int m2 = 0;
	for (int s = 0; s < 9; ++s) m2 += snprintf(arm + m2, sizeof(arm) - m2, "%X%s", S.armor[s], s < 8 ? "," : "");
	const uintptr_t vftRva = (S.actorVft && InModule(S.gfx, S.actorVft)) ? S.actorVft - S.gfx.base : 0;
	snprintf(S.status, sizeof(S.status),
		"verified=%d(%s) disabled=%d live=%d actor=%p vft=EQGraphics+0x%llX(%s) count=%d changed=%d calls=%d queued=%d armor=[%s] body=[%s] attach{idx:point:def:class:r:n:tints(*=changed)}=[%s ] last=%s",
		S.verified, S.verifyWhy, S.disabled ? 1 : 0, S.live, (void*)S.bodyT.actor, (unsigned long long)vftRva,
		vftRva == kVftM ? "ok" : (S.actorVft ? "UNVERIFIED" : "-"), S.bodyT.count, S.body.changed ? 1 : 0, S.calls, S.nq, arm, body, att, S.last);
	return S.status;
}

int Mat_ReadPalette(uintptr_t actor, uint32_t* out, int cap)
{
	if (!EnsureVerified()) return -2;
	MatTarget t;
	if (ResolveActor(actor, &t) != 0 || t.count <= 0) return -3;
	if (t.count > cap) return -4;
	if (ReadTints(t.tints, t.count, out) != 0) return -5;
	return t.count;
}

int Mat_TintActor(uintptr_t actor, int index, uint32_t argb)
{
	if (!EnsureVerified()) return 0;
	MatTarget t;
	if (ResolveActor(actor, &t) != 0 || index < 0 || index >= t.count) return 0;
	DWORD code = 0;
	if (CallTint(actor, index, argb, &code) != 0) { Fault("SetMaterialTint (ornament restore)", code); return -1; }
	++S.calls;
	return 1;
}
