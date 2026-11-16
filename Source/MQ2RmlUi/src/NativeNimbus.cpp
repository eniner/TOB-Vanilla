// Native EQ nimbus (Phase A, opt-in). See NIMBUS_NATIVE.md for the reverse-engineering proof.
//
// Client: eqgame.exe "Sep 11 2025 11:54:10" (TOB 630), EQGraphics.dll of the same build. All addresses are
// RVAs of that build (preferred bases 0x140000000 / 0x180000000; both images are ASLR, so base + RVA).
//
//   eqgame+0x1E2060  void ActivateStateFlavorSpellParticleEffect(uint32 spawnId, int effectId)
//                    = the OP_AddNimbusEffect (0x54b1) handler body: GetSpawnByID(spawnId) via
//                    pSpawnManager->vtbl[0x10], record = SpellEffectNew[effectId] (0x10c each), then
//                    PlaySpellEffectStage(effectId, stage 2, record, spawn, spawn, &spawn->Y/X/Z, 0,0,0,0,-1)
//                    which creates every stage-2 emitter through CParticleSystem vtbl[0x30] with
//                    key = SpawnID << 16 | effectId, attached to spawn->mActorClient.pActor at its bone.
//   eqgame+0x1E2890  int RemoveNimbus(uint32 spawnId, uint32 effectId)  (OP_RemoveNimbusEffect 0x4e88)
//                    = tail call CParticleSystem vtbl[0x70](ps, SpawnID << 16 | effectId): kill by key.
//
// t468 custom proc effects (feature 131072): NEW effects that are not in spellsnew.eff. CustomFxData.h holds emitter
// definitions in EQ's own .edd record format (each a byte clone of a stock EQ emitter - its texture, flipbook, blend - with
// only shape / motion / size / colour / count re-tuned). On first use they are appended to the client's SpellsNew emitter
// collection (CParticleSystem +0x18) IN MEMORY with EQGraphics' own AddEmitterDefinition (0x9AF50, the call the client uses
// for runtime emitters) + the loader's radius step (0x9A480); textures bind lazily by name at draw time (0x1800AFAC0), as
// for every stock emitter. They are played with eqgame's own PlaySpellEffectStage (0x275030, the body of the nimbus
// handler) on a DLL-owned 268-byte effect record whose stage-2 slots point at those emitters, effect id 0x7C00 + n, so the
// key / kill-by-key path is the stock one. No client file is changed; the emitters live until the client exits.
//
// Guards: exact version strings, byte signatures of both functions, the particle system's vtable pointer
// and its two slots, module ranges for every pointer, local player + actor non-null, effect id in range
// with at least one stage-2 emitter. Every read and call is inside SEH; an access violation logs, turns
// the feature off for the session and never retries.
#include "NimbusClientOffsets.h"   // includes <mq/Plugin.h>
#include "NativeNimbus.h"
#include "CustomFxData.h"   // t468: generated custom proc effect emitters (EQ .edd record format)
#include <windows.h>
#include <cstdio>
#include <cstring>
#include <cstdarg>
#include <cmath>

void Canvas_Log(const char* line);   // ElementCanvas.cpp: one line to Logs\rmlui_canvas.log
static double NowSeconds() { return (double)GetTickCount64() * 0.001; }

namespace {

// Addresses: NimbusClientOffsets.h ((A) from eqlib, (B) RE'd + signature-checked below).
using namespace NimbusOffsets;

const unsigned char kSigAdd[] = {   // eqgame+0x1E2060, 48 bytes (RIP-relative operands included: same build)
	0x40,0x53,0x48,0x83,0xec,0x70,0x48,0x63,0xda,0x8b,0xd1,0x85,0xdb,0x0f,0x8e,0x8d,0x00,0x00,0x00,0x3b,0x1d,0x6f,0x43,0xbd,
	0x00,0x0f,0x8d,0x81,0x00,0x00,0x00,0x48,0x8b,0x0d,0xba,0x2a,0xd0,0x00,0x48,0x8b,0x01,0xff,0x50,0x10,0x4c,0x69,0xc3,0x0c };
const unsigned char kSigRemove[] = {  // eqgame+0x1E2890, 24 bytes: mov r8d,ecx; mov rcx,[ps]; shl r8d,16; or edx,r8d; jmp [rax+70h]
	0x44,0x8b,0xc1,0x48,0x8b,0x0d,0x86,0xc0,0xd2,0x00,0x41,0xc1,0xe0,0x10,0x41,0x0b,0xd0,0x48,0x8b,0x01,0x48,0xff,0x60,0x70 };
const unsigned char kSigKill[] = {    // EQGraphics+0xA0650, 16 bytes
	0x48,0x89,0x5c,0x24,0x08,0x48,0x89,0x6c,0x24,0x10,0x48,0x89,0x74,0x24,0x18,0x57 };

// t468 custom effects (checked only when they are first used; a mismatch turns custom effects off, nothing else)
const unsigned char kSigPlay[] = {    // eqgame+0x275030 PlaySpellEffectStage, 32 bytes
	0x48,0x8b,0xc4,0x48,0x89,0x58,0x10,0x89,0x48,0x08,0x55,0x56,0x57,0x41,0x54,0x41,0x55,0x41,0x56,0x41,0x57,0x48,0x81,0xec,
	0xc0,0x00,0x00,0x00,0x45,0x33,0xf6,0x0f };
const unsigned char kSigAddDef[] = {  // EQGraphics+0x9AF50 AddEmitterDefinition, 32 bytes (incl. the RIP-relative cookie load)
	0x48,0x89,0x5c,0x24,0x18,0x48,0x89,0x6c,0x24,0x20,0x56,0x57,0x41,0x55,0x41,0x56,0x41,0x57,0x48,0x81,0xec,0x50,0x01,0x00,
	0x00,0x48,0x8b,0x05,0x38,0xe0,0x2a,0x00 };
const unsigned char kSigRadius[] = {  // EQGraphics+0x9A480 CEmitterDef radius, 24 bytes
	0x40,0x53,0x48,0x83,0xec,0x20,0x48,0x8b,0x41,0x20,0x48,0x8b,0xd9,0xf3,0x0f,0x10,0x58,0x7c,0xf3,0x0f,0x10,0x88,0xac,0x00 };
using PlayStageFn = int(__fastcall*)(uint32_t effId, int stage, void* rec, void* caster, void* target, float* pos, void* missile,
	int duration, char chk, char flag, int extra);
using AddDefFn = void(__fastcall*)(void* coll, const void* record);
using RadiusFn = void(__fastcall*)(void* def);

using AddFn = void(__fastcall*)(uint32_t spawnId, int effectId);
using RemoveFn = int(__fastcall*)(uint32_t spawnId, uint32_t effectId);

struct Module { uintptr_t base = 0, size = 0; };

enum Req { kNone, kAdd, kRemove };

// aura rework: independent slots on the same client call. Slot 0 = the Body FX nimbus (old exports), slot 1 = the
// ground aura. Each slot owns its own key (SpawnID << 16 | effectId), so two different effects never touch each other;
// the same effect id is refused in a second slot (one key, one owner).
constexpr int kSlots = 3;   // 0 Body FX nimbus, 1 ground aura, 2 foot trail (t485; stock or custom trail records)
struct Slot
{
	int wantId = 0;          // effect we keep on (0 = none)
	int wantHandle = 0;
	int flags = 0;           // 1 = autoclose (needs a status/keepalive call every 5 s)
	double lastTouch = 0.0;
	int activeId = 0;        // what the client has for this slot
	uint32_t activeSpawn = 0;
	uintptr_t activeActor = 0;
	Req req = kNone;
	int reqId = 0;
	int lastEmitters = -1;
	char status[512] = "";
	// t487 (slot 2 foot trail): where EQ anchors the feet emitters. 0 = the foot points (record as is), 1 = the root
	// point (attach 1), 2 = the floor under the spawn (attach 12, no bone). Raised when the point the trail is attached
	// to turns out to sit away from the character (a model whose foot points are elsewhere); reset on a new actor.
	int anchor = 0;
	bool anchorChecked = false;
	double addedAt = 0.0;
	float anchorDxy = -1.f, anchorDz = 0.f;
	alignas(8) unsigned char rec[0x10c] = {};   // DLL-owned copy of the record with the feet re-anchored
};

struct State
{
	Module game, gfx;
	int verified = 0;        // 0 unknown, 1 ok, -1 mismatch
	char verifyWhy[96] = "";
	bool disabled = false;   // SEH fault: off for the session
	Slot slot[kSlots];
	// re-add pacing (shared: one local actor)
	double readyAt = 0.0;    // earliest add after zone-in / actor change
	uint32_t seenSpawn = 0;
	uintptr_t seenActor = 0;
	int nextHandle = 1;
	int liveCode = -1;      // ReadLive result of the last pulse (0 = ready)
	float density = -1.f, opacity = -1.f;
	char last[160] = "idle";
};
State S;

// ---- proc burst (feature 65536): one short native effect on ANY spawn (your target or you). Same client call
// (ActivateStateFlavorSpellParticleEffect = the OP_AddNimbusEffect handler, which the server uses for every spawn),
// so EQ attaches the record's stage-2 emitters to that spawn's own bones in the 3D world. Removed by key after
// `ms` (one-shot spell-hit records have usually ended by then; persistent ones are cut there).
struct Burst
{
	bool reqPending = false;
	int reqId = 0;
	uint32_t reqSpawn = 0;     // 0 = you
	double reqUntil = 0.0;
	int id = 0;                // active effect (0 = none)
	uint32_t spawn = 0;
	bool owned = false;        // false: the key already had emitters (a real buff / a slot): never removed by us
	double until = 0.0;
	int alive = -1;
	int played = 0, refused = 0;
	int reqFlags = 0;          // 1 = preview: if the target cannot take it, play it on you instead (and say so)
	int attached = -1;         // emitters with a bone/attach object (+0x78) on the last play
	int ownerOk = -1;          // emitters whose owner (+0x70) is the spawn's own actor
	int fell = 0;              // 1 = the last play went to you because the target could not take it
	int tfail = 0;             // consecutive plays where the target got no emitters / was not usable
	int layers = 1, stage = 2; // t469: stock plays: layers (Brightness >= 150%) and the stage played (2 body, 0 caster)
	char status[700] = "";
	char last[160] = "idle";
};
Burst B;

// t468 custom effects state
struct Cfx
{
	int verified = 0;          // 0 unknown, 1 signatures ok, -1 off for the session
	char why[112] = "not used yet";
	bool ready = false;        // our emitters are in the live collection at `base`
	int base = -1;             // def index of CustomFx::kRecords[0]
	uintptr_t coll = 0;        // collection they were found / put in
	int injected = 0, reused = 0, before = -1, alloc = -1;
	// t469 Brightness / Size (Proc FX look options) applied to our emitter records in place (EQ reads def +0x20 -> record
	// every update; capacity is computed when an emitter is created, so a change takes effect on the next play)
	int wantB = 100, wantS = 100;   // percent, from rml_nimbus_custom_tune
	int tunedB = -1, tunedS = -1, tunedBase = -1;
	int tuneWrites = 0;
	alignas(8) unsigned char rec[CustomFx::kEffects][0x10c] = {};   // DLL-owned SpellEffectNew records (stage 2 only)
};
Cfx X;
int StockBright = 100;          // t469: Brightness for EQ's own records (>= 150 plays the record twice, layered)
bool IsCustom(int id) { return id > CustomFx::kBaseId && id <= CustomFx::kBaseId + CustomFx::kEffects; }

Module FindModule(const char* name)
{
	Module m;
	HMODULE h = GetModuleHandleA(name);
	if (!h)
		return m;
	m.base = (uintptr_t)h;
	__try
	{
		auto dos = (IMAGE_DOS_HEADER*)h;
		auto nt = (IMAGE_NT_HEADERS64*)(m.base + dos->e_lfanew);
		if (dos->e_magic == IMAGE_DOS_SIGNATURE && nt->Signature == IMAGE_NT_SIGNATURE && nt->FileHeader.Machine == IMAGE_FILE_MACHINE_AMD64)
			m.size = nt->OptionalHeader.SizeOfImage;
	}
	__except (EXCEPTION_EXECUTE_HANDLER) { m.size = 0; }
	if (!m.size)
		m.base = 0;
	return m;
}

bool InModule(const Module& m, uintptr_t p, size_t n = 1) { return m.base && p >= m.base && p + n <= m.base + m.size; }
// heap / not-a-module pointer sanity: canonical user-mode, aligned, outside both images
bool HeapPtr(uintptr_t p) { return p >= 0x10000 && p < 0x00007FFFFFFF0000ull && (p & 7) == 0 && !InModule(S.game, p) && !InModule(S.gfx, p); }

void Log(const char* fmt, ...)
{
	char line[400];
	va_list ap; va_start(ap, fmt);
	int n = snprintf(line, sizeof(line), "nimbus ");
	vsnprintf(line + n, sizeof(line) - n, fmt, ap);
	va_end(ap);
	Canvas_Log(line);
	strncpy(S.last, line + n, sizeof(S.last) - 1);
}

void Fault(const char* where, DWORD code)
{
	S.disabled = true;
	for (Slot& q : S.slot) { q.activeId = 0; q.wantId = 0; q.req = kNone; }
	B.id = 0; B.reqPending = false;
	Log("FAULT in %s code=0x%08lX -> native nimbus disabled for this session", where, code);
}

// ---- SEH-only helpers (no C++ objects with destructors inside __try)
int VerifyBuild()
{
	S.game = FindModule("eqgame.exe");
	if (!S.game.base)
		S.game = FindModule(nullptr);
	S.gfx = FindModule("EQGraphics.dll");
	if (!S.game.base || !S.gfx.base) { strcpy(S.verifyWhy, "module not found"); return -1; }
	__try
	{
		const char* d = (const char*)(S.game.base + kRvaVerDate);
		const char* t = (const char*)(S.game.base + kRvaVerTime);
		if (memcmp(d, kExpectedDate, sizeof(kExpectedDate)) != 0 || memcmp(t, kExpectedTime, sizeof(kExpectedTime)) != 0) { strcpy(S.verifyWhy, "eqgame version string"); return -1; }
		if (memcmp((void*)(S.game.base + kRvaAdd), kSigAdd, sizeof(kSigAdd)) != 0) { strcpy(S.verifyWhy, "add signature"); return -1; }
		if (memcmp((void*)(S.game.base + kRvaRemove), kSigRemove, sizeof(kSigRemove)) != 0) { strcpy(S.verifyWhy, "remove signature"); return -1; }
		if (memcmp((void*)(S.gfx.base + kRvaPsKillKey), kSigKill, sizeof(kSigKill)) != 0) { strcpy(S.verifyWhy, "EQGraphics kill signature"); return -1; }
		const uintptr_t* vt = (const uintptr_t*)(S.gfx.base + kRvaPsVtbl);
		if (vt[0x30 / 8] != S.gfx.base + kRvaPsCreate || vt[0x70 / 8] != S.gfx.base + kRvaPsKillKey) { strcpy(S.verifyWhy, "EQGraphics vtable slots"); return -1; }
	}
	__except (EXCEPTION_EXECUTE_HANDLER) { strcpy(S.verifyWhy, "fault while verifying"); return -1; }
	strcpy(S.verifyWhy, "ok");
	return 1;
}

// live pointers; 0 = ok, else reason code
int ReadLive(uint32_t* spawnId, uintptr_t* actor, uintptr_t* ps)
{
	*spawnId = 0; *actor = 0; *ps = 0;
	__try
	{
		uintptr_t pl = *(uintptr_t*)(S.game.base + kRvaLocalPlayer);
		if (!HeapPtr(pl)) return 1;
		uintptr_t plVt = *(uintptr_t*)pl;
		if (!InModule(S.game, plVt, 8)) return 2;
		uintptr_t sm = *(uintptr_t*)(S.game.base + kRvaSpawnMgr);
		if (!HeapPtr(sm) || !InModule(S.game, *(uintptr_t*)sm, 0x18)) return 3;
		uintptr_t p = *(uintptr_t*)(S.game.base + kRvaParticleSys);
		if (!HeapPtr(p) || *(uintptr_t*)p != S.gfx.base + kRvaPsVtbl) return 4;
		uintptr_t a = *(uintptr_t*)(pl + kOffActor);
		if (!HeapPtr(a) || !InModule(S.gfx, *(uintptr_t*)a, 8)) return 5;   // CActor lives in EQGraphics
		uint32_t id = *(uint32_t*)(pl + kOffSpawnId);
		if (id == 0 || id > 0xFFFF) return 6;                                // key packs SpawnID << 16
		S.density = *(float*)(S.game.base + kRvaDensity);
		S.opacity = *(float*)(S.game.base + kRvaDensity + 4);
		*spawnId = id; *actor = a; *ps = p;
	}
	__except (EXCEPTION_EXECUTE_HANDLER) { return 7; }
	return 0;
}

// 1 ok, 0 not a nimbus-capable record, -1 fault. t469: *stage = 2 (on-body stage, the nimbus handler) or, for records with
// no stage-2 emitters, 0 (the caster stage: every such slot's location is 'caster', and we pass the spawn as the caster)
int CheckEffect(int id, int* nEmit, int* stage = nullptr)
{
	*nEmit = 0;
	if (stage) *stage = 2;
	__try
	{
		int count = *(int*)(S.game.base + kRvaEffCount);
		uintptr_t tab = *(uintptr_t*)(S.game.base + kRvaEffTable);
		if (id <= 0 || id >= count || !HeapPtr(tab)) return 0;
		const int* em = (const int*)(tab + (size_t)id * kRecSize + kStage2Emit);
		for (int k = 0; k < 4; ++k)
			if (em[k * 4] > 0) ++*nEmit;
		if (*nEmit == 0 && stage)
		{
			const int* e0 = (const int*)(tab + (size_t)id * kRecSize + kStage0Emit);
			for (int k = 0; k < 4; ++k)
				if (e0[k * 4] > 0 && e0[k * 4 + 2] == 1) ++*nEmit;   // location 1 = caster
			if (*nEmit > 0) *stage = 0;
		}
	}
	__except (EXCEPTION_EXECUTE_HANDLER) { return -1; }
	return *nEmit > 0 ? 1 : 0;
}

// emitters alive with our key on the spell-emitter list (ps+0x18): {.. +0x18 count, +0x20 defs[]};
// def +8 enabled, +0x18 first emitter; emitter +0xc key, +0xa8 next. Read-only, bounded.
int CountKey(uintptr_t ps, uint32_t key)
{
	int n = 0;
	__try
	{
		uintptr_t list = ps + 0x18;
		int cnt = *(int*)(list + 0x18);
		uintptr_t defs = *(uintptr_t*)(list + 0x20);
		if (cnt < 0 || cnt > 200000 || (cnt && !HeapPtr(defs))) return -2;
		for (int i = 0; i < cnt; ++i)
		{
			uintptr_t def = ((uintptr_t*)defs)[i];
			if (!def || !*(unsigned char*)(def + 8)) continue;
			uintptr_t e = *(uintptr_t*)(def + 0x18);
			for (int guard = 0; e && guard < 4096; ++guard)
			{
				if (*(uint32_t*)(e + 0xc) == key) ++n;
				e = *(uintptr_t*)(e + 0xa8);
			}
		}
	}
	__except (EXCEPTION_EXECUTE_HANDLER) { return -1; }
	return n;
}

// same walk, plus how many of the key's emitters have an attach object (+0x78, the bone) and which owner (+0x70)
// matches `actor` (CEmitter ctor 0x99E50: +0xC key, +0x70 owner, +0x78 attach). Read-only diagnostics.
int CountKeyEx(uintptr_t ps, uint32_t key, uintptr_t actor, int* attached, int* ownerOk)
{
	int n = 0; *attached = 0; *ownerOk = 0;
	__try
	{
		uintptr_t list = ps + 0x18;
		int cnt = *(int*)(list + 0x18);
		uintptr_t defs = *(uintptr_t*)(list + 0x20);
		if (cnt < 0 || cnt > 200000 || (cnt && !HeapPtr(defs))) return -2;
		for (int i = 0; i < cnt; ++i)
		{
			uintptr_t def = ((uintptr_t*)defs)[i];
			if (!def || !*(unsigned char*)(def + 8)) continue;
			uintptr_t e = *(uintptr_t*)(def + 0x18);
			for (int guard = 0; e && guard < 4096; ++guard)
			{
				if (*(uint32_t*)(e + 0xc) == key)
				{
					++n;
					if (*(uintptr_t*)(e + 0x78)) ++*attached;
					if (actor && *(uintptr_t*)(e + 0x70) == actor) ++*ownerOk;
				}
				e = *(uintptr_t*)(e + 0xa8);
			}
		}
	}
	__except (EXCEPTION_EXECUTE_HANDLER) { return -1; }
	return n;
}
uintptr_t SpawnActor(void* sp)
{
	uintptr_t a = 0;
	if (!HeapPtr((uintptr_t)sp)) return 0;
	__try { a = *(uintptr_t*)((uintptr_t)sp + kOffActor); }
	__except (EXCEPTION_EXECUTE_HANDLER) { a = 0; }
	return HeapPtr(a) ? a : 0;
}

// ---- t472: EQ's Options > Display > Spell Particle Density / Opacity must not hide OUR effects -----------------------
// PlaySpellEffectStage (kRvaPlayStage) hands every emitter to CParticleSystem::Create (vtbl[0x30]) with the two globals
// at kRvaDensity / +4 as density / opacity (the 'flag' argument is 0 on our calls). eqgame writes them from the Options
// combo (0 / 0.25 / 0.5 / 1.0 at 0x493FF6..0x49403B) and from eqclient.ini keys SpellParticleDensity / -Opacity
// (0x2A5135 / 0x2A5164), so "Off" there = density 0 = our emitters are created empty. EQ's own spell effects are also
// gated BEFORE they reach PlaySpellEffectStage (0x2749EE: density > 0 && opacity > 0), our calls are not.
// So around OUR calls only (game thread, synchronous) the two globals read 1.0 ("High") and are put back right after:
// EQ's own effects keep the user's setting, and the saved setting (eqclient.ini) is never written.
// Proven at run time: both movss loads inside PlaySpellEffectStage must point at kRvaDensity / +4, else no override.
constexpr size_t kOffLoadDensity = 0x275489 - 0x275030;   // movss xmm1, [rip+disp] -> SpellParticleDensity
constexpr size_t kOffLoadOpacity = 0x2754AD - 0x275030;   // movss xmm0, [rip+disp] -> SpellParticleOpacity
struct PLvl { float d, o; int on; };
struct PLvlState { int ok = 0; int forced = 0; float userD = -1.f, userO = -1.f; char why[64] = "not checked"; };
PLvlState L;
bool LevelsVerified()
{
	if (L.ok) return L.ok == 1;
	if (S.verified != 1) return false;
	__try
	{
		const unsigned char* a = (const unsigned char*)(S.game.base + kRvaPlayStage + kOffLoadDensity);
		const unsigned char* b = (const unsigned char*)(S.game.base + kRvaPlayStage + kOffLoadOpacity);
		const bool fa = a[0] == 0xF3 && a[1] == 0x0F && a[2] == 0x10 && a[3] == 0x0D;
		const bool fb = b[0] == 0xF3 && b[1] == 0x0F && b[2] == 0x10 && b[3] == 0x05;
		const uintptr_t ta = (uintptr_t)(a + 8) + *(const int32_t*)(a + 4);
		const uintptr_t tb = (uintptr_t)(b + 8) + *(const int32_t*)(b + 4);
		if (!fa || !fb || ta != S.game.base + kRvaDensity || tb != S.game.base + kRvaDensity + 4)
		{
			L.ok = -1; strcpy(L.why, "density/opacity loads not found"); return false;
		}
	}
	__except (EXCEPTION_EXECUTE_HANDLER) { L.ok = -1; strcpy(L.why, "fault while checking"); return false; }
	L.ok = 1; strcpy(L.why, "ok");
	return true;
}
void LvlForce(PLvl* s)
{
	s->on = 0;
	if (!LevelsVerified()) return;
	float* g = (float*)(S.game.base + kRvaDensity);
	s->d = g[0]; s->o = g[1];
	L.userD = s->d; L.userO = s->o;
	if (s->d >= 1.f && s->o >= 1.f) return;
	g[0] = 1.f; g[1] = 1.f;
	s->on = 1; ++L.forced;
}
void LvlRestore(const PLvl* s)
{
	if (!s->on) return;
	float* g = (float*)(S.game.base + kRvaDensity);
	g[0] = s->d; g[1] = s->o;
}
int CallAdd(uint32_t spawnId, int effectId, DWORD* code)
{
	PLvl lv; LvlForce(&lv);
	__try { ((AddFn)(S.game.base + kRvaAdd))(spawnId, effectId); }
	__except (*code = GetExceptionCode(), EXCEPTION_EXECUTE_HANDLER) { LvlRestore(&lv); return -1; }
	LvlRestore(&lv);
	return 0;
}

int CallRemove(uint32_t spawnId, uint32_t effectId, int* rc, DWORD* code)
{
	__try { *rc = ((RemoveFn)(S.game.base + kRvaRemove))(spawnId, effectId); }
	__except (*code = GetExceptionCode(), EXCEPTION_EXECUTE_HANDLER) { return -1; }
	return 0;
}

bool EnsureVerified()
{
	if (S.verified == 0)
	{
		S.verified = VerifyBuild();
		Log("verify %s (eqgame=%p EQGraphics=%p)", S.verifyWhy, (void*)S.game.base, (void*)S.gfx.base);
	}
	return S.verified == 1 && !S.disabled;
}

void DoRemove(Slot& q, int si, const char* why)
{
	if (!q.activeId)
		return;
	uintptr_t ps = 0;
	{
		uint32_t sid; uintptr_t a;
		ReadLive(&sid, &a, &ps);
	}
	int rc = -9; DWORD code = 0;
	if (CallRemove(q.activeSpawn, (uint32_t)q.activeId, &rc, &code) != 0) { Fault("remove", code); return; }
	const uint32_t key = (q.activeSpawn << 16) | (uint32_t)q.activeId;
	const int left = ps ? CountKey(ps, key) : -3;
	Log("slot%d removed id=%d spawn=%u key=0x%08X rc=%d left=%d (%s)", si, q.activeId, q.activeSpawn, key, rc, left, why);
	q.activeId = 0; q.activeSpawn = 0; q.activeActor = 0; q.lastEmitters = -1;
}

int EnsureCustom(uintptr_t ps);
int CallCustom(uint32_t spawnId, int id, DWORD* code);
int CallRec(uint32_t spawnId, int id, void* rec, DWORD* code);
const char* kAnchorName[3] = { "feet", "root", "floor" };
// t487: copy the effect record (stock table / our custom one) and move its foot emitters (attach 6 / 7) to the anchor
bool BuildAnchored(Slot& q, int id)
{
	const unsigned char* src = nullptr;
	__try
	{
		if (IsCustom(id)) src = X.rec[id - CustomFx::kBaseId - 1];
		else
		{
			uintptr_t tab = *(uintptr_t*)(S.game.base + kRvaEffTable);
			if (!HeapPtr(tab)) return false;
			src = (const unsigned char*)(tab + (size_t)id * kRecSize);
		}
		memcpy(q.rec, src, kRecSize);
	}
	__except (EXCEPTION_EXECUTE_HANDLER) { return false; }
	int* st = (int*)(q.rec + 0x40 + 2 * 0x44);
	for (int k = 0; k < 4; ++k)
		if (st[1 + 4 * k] > 0 && (st[4 + 4 * k] == 6 || st[4 + 4 * k] == 7))
			st[4 + 4 * k] = q.anchor == 1 ? 1 : 12;
	return true;
}
void DoAdd(Slot& q, int si, uint32_t spawnId, uintptr_t actor, uintptr_t ps)
{
	int nEmit = 0;
	const bool custom = IsCustom(q.wantId);
	if (custom)
	{   // t485: a custom persistent record (foot trail): our emitters in the client's collection + PlaySpellEffectStage,
		// the same stage-2 play the OP_AddNimbusEffect handler does; removed by key like any nimbus
		if (EnsureCustom(ps) != 0)
		{
			if (X.verified == -1) { Log("slot%d reject id=%d: custom effects off (%s)", si, q.wantId, X.why); q.wantId = 0; }
			return;   // not ready yet: retried on the next pulse
		}
		nEmit = CustomFx::kEff[q.wantId - CustomFx::kBaseId - 1].n;
	}
	else
	{
		int ok = CheckEffect(q.wantId, &nEmit);
		if (ok < 0) { Fault("effect check", 0); return; }
		if (ok == 0) { Log("slot%d reject id=%d: not a stage-2 (nimbus) effect record", si, q.wantId); q.wantId = 0; return; }
	}
	const uint32_t key = (spawnId << 16) | (uint32_t)q.wantId;
	const int before = CountKey(ps, key);
	if (before > 0)
	{   // the server (a real buff) or an earlier add already owns this key: do not stack a second copy
		Log("slot%d skip add id=%d: %d emitters with key 0x%08X already exist", si, q.wantId, before, key);
		q.activeId = q.wantId; q.activeSpawn = spawnId; q.activeActor = actor; q.lastEmitters = before;
		return;
	}
	DWORD code = 0;
	if (si == 2 && q.anchor > 0)
	{   // t487: the foot points of this model are away from the body: same record, feet emitters on root / floor
		if (!BuildAnchored(q, q.wantId)) { Log("slot%d reject id=%d: record copy failed", si, q.wantId); q.wantId = 0; return; }
		const int cr = CallRec(spawnId, q.wantId, q.rec, &code);
		if (cr < 0) { Fault("anchored slot play", code); return; }
		if (cr > 0) return;
	}
	else if (custom)
	{
		const int cr = CallCustom(spawnId, q.wantId, &code);
		if (cr < 0) { Fault("custom slot play", code); return; }
		if (cr > 0) return;   // spawn not usable yet: retried on the next pulse
	}
	else if (CallAdd(spawnId, q.wantId, &code) != 0) { Fault("add", code); return; }
	const int after = CountKey(ps, key);
	q.activeId = q.wantId; q.activeSpawn = spawnId; q.activeActor = actor; q.lastEmitters = after;
	q.addedAt = NowSeconds(); q.anchorChecked = false;
	Log("slot%d added id=%d spawn=%u key=0x%08X record_emitters=%d alive=%d density=%.2f opacity=%.2f%s%s",
		si, q.wantId, spawnId, key, nEmit, after, S.density, S.opacity, si == 2 ? " anchor=" : "", si == 2 ? kAnchorName[q.anchor] : "");
}

// burst: is spawnId a live spawn with a built actor? (MQ's own spawn lookup + the same pointer sanity as ReadLive)
void* LookupSpawn(uint32_t spawnId)
{
	eqlib::PlayerManagerClient* mgr = eqlib::pSpawnManager.get();
	if (!mgr) return nullptr;
	void* p = nullptr;
	__try { p = mgr->GetSpawnByID((int)spawnId); }
	__except (EXCEPTION_EXECUTE_HANDLER) { p = nullptr; }
	return p;
}
int SpawnUsable(void* sp, uint32_t spawnId)   // 0 ok, else reason
{
	uintptr_t pl = (uintptr_t)sp;
	if (!HeapPtr(pl)) return 1;
	__try
	{
		if (!InModule(S.game, *(uintptr_t*)pl, 8)) return 2;
		if (*(uint32_t*)(pl + kOffSpawnId) != spawnId) return 3;
		uintptr_t a = *(uintptr_t*)(pl + kOffActor);
		if (!HeapPtr(a) || !InModule(S.gfx, *(uintptr_t*)a, 8)) return 4;
	}
	__except (EXCEPTION_EXECUTE_HANDLER) { return 5; }
	return 0;
}
// ---- t468 custom proc effects (SEH-only helpers; see the header comment) ----------------------------------------
int VerifyCustom()
{
	if (X.verified != 0) return X.verified;
	if (S.verified != 1) { strcpy(X.why, "client build not verified"); return 0; }
	__try
	{
		if (memcmp((void*)(S.game.base + kRvaPlayStage), kSigPlay, sizeof(kSigPlay)) != 0) { strcpy(X.why, "PlaySpellEffectStage signature"); X.verified = -1; return -1; }
		if (memcmp((void*)(S.gfx.base + kRvaAddEmitDef), kSigAddDef, sizeof(kSigAddDef)) != 0) { strcpy(X.why, "AddEmitterDefinition signature"); X.verified = -1; return -1; }
		if (memcmp((void*)(S.gfx.base + kRvaDefRadius), kSigRadius, sizeof(kSigRadius)) != 0) { strcpy(X.why, "emitter radius signature"); X.verified = -1; return -1; }
	}
	__except (EXCEPTION_EXECUTE_HANDLER) { strcpy(X.why, "fault while verifying"); X.verified = -1; return -1; }
	X.verified = 1;
	strcpy(X.why, "verified (emitters go in on the first play)");
	return 1;
}
// def i of the collection's def array holds a record whose name is CustomFx::kRecords[k]'s (def +0x20 -> record, name at +0)
bool DefIs(uintptr_t defs, int cnt, int i, int k)
{
	if (i < 0 || i >= cnt) return false;
	uintptr_t def = ((uintptr_t*)defs)[i];
	if (!HeapPtr(def)) return false;
	uintptr_t r = *(uintptr_t*)(def + 0x20);
	if (!HeapPtr(r)) return false;
	return strncmp((const char*)r, (const char*)CustomFx::kRecords[k], 64) == 0;
}
// 0 ready; > 0 not now (X.why); -1 fault; -2 an add did not land as expected (custom effects off for the session)
// Collection (CParticleSystem +0x18, the SpellsNew emitters): records {count +0, ptr +8, alloc +0x10}, defs {count +0x18, ptr +0x20}.
int EnsureCustomRaw(uintptr_t ps, DWORD* code)
{
	const int K = CustomFx::kEmitters;
	const uintptr_t coll = ps + 0x18;
	__try
	{
		const int rc = *(int*)coll, cnt = *(int*)(coll + 0x18);
		const uintptr_t defs = *(uintptr_t*)(coll + 0x20);
		if (cnt <= 0 || cnt > 200000 || !HeapPtr(defs)) { strcpy(X.why, "emitter collection not readable yet"); return 2; }
		if (X.ready && X.coll == coll && DefIs(defs, cnt, X.base, 0) && DefIs(defs, cnt, X.base + K - 1, K - 1)) return 0;
		X.ready = false;
		for (int i = cnt - K; i >= 1 && i >= cnt - 8192; --i)   // already there (plugin reloaded with the same data)? newest first
		{
			if (!DefIs(defs, cnt, i, 0)) continue;
			bool all = true;
			for (int k = 1; k < K && all; ++k) all = DefIs(defs, cnt, i + k, k);
			if (all) { X.base = i; X.coll = coll; X.ready = true; ++X.reused; return 0; }
		}
		if (rc != cnt) { snprintf(X.why, sizeof(X.why), "collection counts differ (%d records, %d defs)", rc, cnt); return 3; }
		X.before = cnt; X.alloc = *(int*)(coll + 0x10);
		for (int k = 0; k < K; ++k)
		{
			((AddDefFn)(S.gfx.base + kRvaAddEmitDef))((void*)coll, CustomFx::kRecords[k]);
			const int c2 = *(int*)(coll + 0x18);
			const uintptr_t d2 = *(uintptr_t*)(coll + 0x20);
			if (c2 != cnt + k + 1 || *(int*)coll != c2 || !HeapPtr(d2) || !DefIs(d2, c2, c2 - 1, k))
			{
				snprintf(X.why, sizeof(X.why), "emitter %d did not land (defs %d records %d)", k, c2, *(int*)coll);
				return -2;
			}
			((RadiusFn)(S.gfx.base + kRvaDefRadius))((void*)((uintptr_t*)d2)[c2 - 1]);
			++X.injected;
		}
		X.base = cnt; X.coll = coll; X.ready = true;
	}
	__except (*code = GetExceptionCode(), EXCEPTION_EXECUTE_HANDLER) { return -1; }
	return 0;
}
void BuildCustomRecords()
{
	for (int e = 0; e < CustomFx::kEffects; ++e)
	{
		unsigned char* r = X.rec[e];
		memset(r, 0, sizeof(X.rec[e]));
		snprintf((char*)r, 64, "%s %d", CustomFx::kTag, e + 1);
		int* st = (int*)(r + 0x40 + 2 * 0x44);      // stage 2: sound, then 4 x {emitter, min level, location, attach}
		for (int k = 0; k < 4; ++k)
			if (CustomFx::kEff[e].emit[k] >= 0)
			{
				st[1 + 4 * k] = X.base + CustomFx::kEff[e].emit[k];
				st[2 + 4 * k] = 0;
				st[3 + 4 * k] = 1;                       // location 1 = the caster argument (we pass the spawn as both)
				st[4 + 4 * k] = CustomFx::kEff[e].attach[k];
			}
	}
}
// 0 ready, > 0 not now / off (X.why)
int EnsureCustom(uintptr_t ps)
{
	if (VerifyCustom() != 1) return 1;
	const int oldBase = X.ready ? X.base : -1;
	const int injBefore = X.injected, reuBefore = X.reused;
	DWORD code = 0;
	const int r = EnsureCustomRaw(ps, &code);
	if (r == 0)
	{
		if (X.base != oldBase)
		{
			BuildCustomRecords();
			snprintf(X.why, sizeof(X.why), "ready (%s)", X.injected > injBefore ? "added" : (X.reused > reuBefore ? "found from an earlier load" : "kept"));
			Log("custom effects %s: %d emitters at def %d (collection had %d, alloc %d) tag=%s", X.injected > injBefore ? "added" : "found",
				CustomFx::kEmitters, X.base, X.before, X.alloc, CustomFx::kTag);
		}
		return 0;
	}
	if (r < 0)
	{
		X.verified = -1; X.ready = false;
		if (r == -1) { snprintf(X.why, sizeof(X.why), "fault 0x%08lX while adding emitters", code); Fault("custom emitter add", code); }
		Log("custom effects off for this session: %s", X.why);
		return 4;
	}
	return r;
}
// play custom effect `id` on spawnId with eqgame's PlaySpellEffectStage; 0 played, 1 spawn not usable, -1 fault
int CallCustom(uint32_t spawnId, int id, DWORD* code)
{
	void* sp = LookupSpawn(spawnId);
	if (SpawnUsable(sp, spawnId) != 0) return 1;
	unsigned char* rec = X.rec[id - CustomFx::kBaseId - 1];
	PLvl lv; LvlForce(&lv);
	__try
	{
		float pos[3] = { *(float*)((uintptr_t)sp + 0x74), *(float*)((uintptr_t)sp + 0x78), *(float*)((uintptr_t)sp + 0x7c) };
		((PlayStageFn)(S.game.base + kRvaPlayStage))((uint32_t)id, 2, rec, sp, sp, pos, nullptr, 0, 0, 0, -1);
	}
	__except (*code = GetExceptionCode(), EXCEPTION_EXECUTE_HANDLER) { LvlRestore(&lv); return -1; }
	LvlRestore(&lv);
	return 0;
}
// t487: play `rec` (a DLL-owned copy) under effect id `id` (key SpawnID << 16 | id, removed by key like any nimbus)
int CallRec(uint32_t spawnId, int id, void* rec, DWORD* code)
{
	void* sp = LookupSpawn(spawnId);
	if (SpawnUsable(sp, spawnId) != 0) return 1;
	PLvl lv; LvlForce(&lv);
	__try
	{
		float pos[3] = { *(float*)((uintptr_t)sp + 0x74), *(float*)((uintptr_t)sp + 0x78), *(float*)((uintptr_t)sp + 0x7c) };
		((PlayStageFn)(S.game.base + kRvaPlayStage))((uint32_t)id, 2, rec, sp, sp, pos, nullptr, 0, 0, 0, -1);
	}
	__except (*code = GetExceptionCode(), EXCEPTION_EXECUTE_HANDLER) { LvlRestore(&lv); return -1; }
	LvlRestore(&lv);
	return 0;
}
// t487: once the trail has run 1.5 s (EQGraphics refreshes an attached point's world position, +0xF0, while an emitter
// uses it - FUN_1800a0cd0), compare that point with the spawn position. 0 fine / not decidable, 1 detached.
// The point EQ used: attach 6 -> pParticlePoints[5] (null -> [0]); attach 1 -> [0] (PlaySpellEffectStage switch).
int AnchorDetached(Slot& q)
{
	void* sp = LookupSpawn(q.activeSpawn);
	if (SpawnUsable(sp, q.activeSpawn) != 0) return 0;
	__try
	{
		uintptr_t* pts = (uintptr_t*)((uintptr_t)sp + kOffPoints);
		uintptr_t p = 0;
		if (q.anchor == 0) p = HeapPtr(pts[5]) ? pts[5] : pts[0];
		else if (q.anchor == 1) p = pts[0];
		if (!HeapPtr(p)) { q.anchorDxy = -1.f; return 0; }   // no point: EQ placed it at the spawn (floor path is fine)
		const float* w = (const float*)(p + 0xf0);
		const float* s = (const float*)((uintptr_t)sp + 0x74);
		const float dx = w[0] - s[0], dy = w[1] - s[1], dz = w[2] - s[2];
		if (dx != dx || dy != dy || dz != dz) return 0;
		q.anchorDxy = sqrtf(dx * dx + dy * dy); q.anchorDz = dz;
		if (w[0] == 0.f && w[1] == 0.f && w[2] == 0.f) return 1;   // never placed in the world
		return (q.anchorDxy > 4.0f || q.anchorDz > 3.0f) ? 1 : 0;
	}
	__except (EXCEPTION_EXECUTE_HANDLER) { return 0; }
}
// t469: write Brightness / Size into our live emitter records (from the pristine CustomFx::kRecords every time)
// b, s: percent. Brightness > 100: opacity up to 1, colours brighter, more particles (rate; never the spoke count of an
// even ring), slightly larger quads. Brightness < 100: opacity down. Size scales the quads.
void TuneRecord(unsigned char* r, const unsigned char* p, int bp, int sp)
{
	const float b = (float)bp / 100.f, s = (float)sp / 100.f;
	float op = *(const float*)(p + 0xa4) * b;
	*(float*)(r + 0xa4) = op > 1.f ? 1.f : (op < 0.05f ? 0.05f : op);
	const float up = b > 1.f ? b - 1.f : 0.f;
	for (int o = 0xd4; o < 0xec; o += 4)
	{
		const int c = *(const int*)(p + o);
		int v = (int)((float)c * (1.f + up * 0.6f) + 0.5f);
		*(int*)(r + o) = v > 255 ? 255 : v;
	}
	const unsigned shape = *(const unsigned*)(p + 0xa8);
	const bool ring = shape == 1 || shape == 2;   // even rings: initial / per_tick = spokes
	const float more = 1.f + up * 0.8f;
	const int ini = *(const int*)(p + 0x80), pt = *(const int*)(p + 0x84);
	const float tk = *(const float*)(p + 0x88);
	if (!ring)
	{
		*(int*)(r + 0x80) = (int)((float)ini * more + 0.5f);
		*(int*)(r + 0x84) = (int)((float)pt * more + 0.5f);
		*(float*)(r + 0x88) = tk;
	}
	else
	{
		*(int*)(r + 0x80) = ini; *(int*)(r + 0x84) = pt;
		*(float*)(r + 0x88) = (pt > 0 && tk > 1.f) ? tk * more : tk;
	}
	const float k = s * (1.f + up * 0.25f);
	static const int sz[] = { 0xcc, 0x184, 0x17c, 0x180 };
	for (int o : sz) *(float*)(r + o) = *(const float*)(p + o) * k;
}
// 0 ok / nothing to do, -1 fault
int ApplyTuneRaw(uintptr_t ps, DWORD* code)
{
	if (!X.ready) return 0;
	if (X.tunedB == X.wantB && X.tunedS == X.wantS && X.tunedBase == X.base) return 0;
	const int K = CustomFx::kTuneEmitters;   // t485: proc emitters only; the foot trails keep their own look
	const uintptr_t coll = ps + 0x18;
	__try
	{
		const int cnt = *(int*)(coll + 0x18);
		const uintptr_t defs = *(uintptr_t*)(coll + 0x20);
		if (!HeapPtr(defs)) return 0;
		for (int k = 0; k < K; ++k)
		{
			if (!DefIs(defs, cnt, X.base + k, k)) return 0;      // not ours any more: EnsureCustom sorts it out next play
			unsigned char* r = (unsigned char*)*(uintptr_t*)(((uintptr_t*)defs)[X.base + k] + 0x20);
			TuneRecord(r, CustomFx::kRecords[k], X.wantB, X.wantS);
		}
		X.tunedB = X.wantB; X.tunedS = X.wantS; X.tunedBase = X.base; ++X.tuneWrites;
	}
	__except (*code = GetExceptionCode(), EXCEPTION_EXECUTE_HANDLER) { return -1; }
	return 0;
}
// t469: a stock record's caster stage (records with no stage-2 emitters) through PlaySpellEffectStage, like the nimbus handler
int CallStage(uint32_t spawnId, int id, int stage, DWORD* code)
{
	void* sp = LookupSpawn(spawnId);
	if (SpawnUsable(sp, spawnId) != 0) return 1;
	PLvl lv; LvlForce(&lv);
	int r = 0;
	__try
	{
		uintptr_t tab = *(uintptr_t*)(S.game.base + kRvaEffTable);
		if (!HeapPtr(tab)) r = 1;
		else
		{
			void* rec = (void*)(tab + (size_t)id * kRecSize);
			float pos[3] = { *(float*)((uintptr_t)sp + 0x74), *(float*)((uintptr_t)sp + 0x78), *(float*)((uintptr_t)sp + 0x7c) };
			((PlayStageFn)(S.game.base + kRvaPlayStage))((uint32_t)id, stage, rec, sp, sp, pos, nullptr, 0, 0, 0, -1);
		}
	}
	__except (*code = GetExceptionCode(), EXCEPTION_EXECUTE_HANDLER) { LvlRestore(&lv); return -1; }
	LvlRestore(&lv);
	return r;
}
void BLog(const char* fmt, ...)
{
	char line[300];
	va_list ap; va_start(ap, fmt);
	int n = snprintf(line, sizeof(line), "nimbus burst ");
	vsnprintf(line + n, sizeof(line) - n, fmt, ap);
	va_end(ap);
	Canvas_Log(line);
	strncpy(B.last, line + 13, sizeof(B.last) - 1);
}
bool SlotHolds(uint32_t spawn, int id)
{
	for (const Slot& q : S.slot)
		if (q.activeId == id && q.activeSpawn == spawn) return true;
	return false;
}
void BurstRemove(const char* why)
{
	if (!B.id) return;
	if (B.owned && !SlotHolds(B.spawn, B.id))
	{
		int rc = -9; DWORD code = 0;
		if (CallRemove(B.spawn, (uint32_t)B.id, &rc, &code) != 0) { Fault("burst remove", code); return; }
	}
	if (strcmp(why, "replaced") != 0) BLog("end id=%d spawn=%u (%s)", B.id, B.spawn, why);
	B.id = 0; B.spawn = 0; B.owned = false; B.alive = -1;
}
// one add on `want`; returns emitters alive with the key afterwards (<0 = fault already handled / not played)
int BurstPlayOn(uint32_t want, uint32_t sid, uintptr_t ps, uintptr_t actor, int* nEmitOut)
{
	int nEmit = 0, stage = 2;
	const bool custom = IsCustom(B.reqId);
	if (custom)
	{   // t468: our own emitters (added to the client's collection on first use) + a DLL-owned effect record
		if (EnsureCustom(ps) != 0) { *nEmitOut = 0; return S.disabled ? -100 : -102; }
		nEmit = CustomFx::kEff[B.reqId - CustomFx::kBaseId - 1].n;
		DWORD tc = 0;
		if (ApplyTuneRaw(ps, &tc) != 0) { *nEmitOut = 0; Fault("custom tune", tc); return -100; }
	}
	else
	{
		int ok = CheckEffect(B.reqId, &nEmit, &stage);
		if (ok < 0) { *nEmitOut = 0; Fault("burst effect check", 0); return -100; }
		if (ok == 0) { *nEmitOut = 0; return -101; }
		if (stage != 2 && VerifyCustom() != 1) { *nEmitOut = 0; return -101; }   // caster stage needs PlaySpellEffectStage verified
	}
	*nEmitOut = nEmit;
	const uint32_t key = (want << 16) | (uint32_t)B.reqId;
	const int before = CountKey(ps, key);
	B.owned = before <= 0;
	if (B.owned)
	{
		DWORD code = 0;
		if (custom)
		{
			const int cr = CallCustom(want, B.reqId, &code);
			if (cr < 0) { Fault("custom play", code); return -100; }
		}
		else
		{   // t469: Brightness >= 150% plays EQ's own record twice (two layers of its emitters under the same key)
			const int layers = StockBright >= 150 ? 2 : 1;
			for (int l = 0; l < layers; ++l)
			{
				if (stage == 2) { if (CallAdd(want, B.reqId, &code) != 0) { Fault("burst add", code); return -100; } }
				else
				{
					const int cr = CallStage(want, B.reqId, stage, &code);
					if (cr < 0) { Fault("burst stage play", code); return -100; }
				}
			}
			B.layers = layers; B.stage = stage;
		}
	}
	B.id = B.reqId; B.spawn = want;
	B.alive = CountKeyEx(ps, key, actor, &B.attached, &B.ownerOk);
	(void)sid;
	return B.alive;
}
void BurstPulse(double now, uint32_t sid, uintptr_t ps, uintptr_t selfActor)
{
	if (B.reqPending)
	{
		B.reqPending = false;
		if (B.id) BurstRemove("replaced");   // a repeat restarts it, so one-shot emitters play again
		if (S.disabled) return;
		const uint32_t want = B.reqSpawn ? B.reqSpawn : sid;
		const bool preview = (B.reqFlags & 1) != 0;
		const int ms = (int)((B.reqUntil - now) * 1000.0);
		if (now >= B.reqUntil) { ++B.refused; BLog("drop id=%d spawn=%u: stale (zoning / not ready)", B.reqId, want); }
		else
		{
			B.fell = 0;
			int why = 0;
			uintptr_t tActor = selfActor;
			if (want != sid)
			{
				void* sp = LookupSpawn(want);
				why = SpawnUsable(sp, want);
				tActor = why ? 0 : SpawnActor(sp);
			}
			int nEmit = 0, alive = -1;
			if (!why)
			{
				alive = BurstPlayOn(want, sid, ps, tActor, &nEmit);
				if (alive == -100) return;
				if (alive == -101) { ++B.refused; B.id = 0; BLog("refuse id=%d: no stage-2 emitters", B.reqId); return; }
				if (alive == -102) { ++B.refused; B.id = 0; BLog("refuse id=%d: custom effects not available (%s)", B.reqId, X.why); return; }
			}
			if (want != sid && (why || alive <= 0))
			{   // the target could not take it (not a usable spawn, or the client made no emitters on it)
				++B.tfail;
				if (B.id && B.owned && alive <= 0) { BurstRemove("replaced"); }
				else if (alive <= 0) { B.id = 0; }
				if (!preview)
				{
					++B.refused;
					BLog("refuse id=%d spawn=%u: %s%d (target failures in a row: %d)", B.reqId, want,
						why ? "spawn not usable code=" : "no emitters made on the target, alive=", why ? why : alive, B.tfail);
					return;
				}
				BLog("target spawn=%u could not take id=%d (%s%d): playing it on you instead", want, B.reqId,
					why ? "spawn not usable code=" : "alive=", why ? why : alive);
				alive = BurstPlayOn(sid, sid, ps, selfActor, &nEmit);
				if (alive == -100) return;
				if (alive < 0) { ++B.refused; B.id = 0; return; }
				B.fell = 1;
			}
			else if (want != sid) B.tfail = 0;
			B.until = B.reqUntil; ++B.played;
			BLog("play id=%d spawn=%u%s key=0x%08X record_emitters=%d alive=%d attached=%d owner_ok=%d owned=%d ms=%d%s%s",
				B.id, B.spawn, B.spawn == sid ? "(you)" : "", (B.spawn << 16) | (uint32_t)B.id, nEmit, B.alive, B.attached, B.ownerOk,
				B.owned ? 1 : 0, ms, preview ? " preview" : "", B.fell ? " fell_back_to_you" : "");
			if (!IsCustom(B.id) && (B.layers > 1 || B.stage != 2)) BLog("  stock id=%d stage=%d layers=%d", B.id, B.stage, B.layers);
		}
	}
	if (B.id && now >= B.until)
		BurstRemove("done");
}

bool SlotOk(int si) { return si >= 0 && si < kSlots; }

} // namespace

bool Nimbus_Available() { return EnsureVerified(); }

int Nimbus_AddSlot(int si, int effectId, int flags)
{
	if (!SlotOk(si)) return -4;
	if (S.disabled) return -1;
	if (!EnsureVerified()) return -2;
	if (effectId <= 0 || effectId > 0xFFFF) return -3;
	if (IsCustom(effectId) && VerifyCustom() == -1) return -7;   // t485: custom records off (signature / earlier failure)
	for (int o = 0; o < kSlots; ++o)   // one key, one owner: the same effect cannot live in two slots
		if (o != si && (S.slot[o].activeId == effectId || S.slot[o].wantId == effectId || (S.slot[o].req == kAdd && S.slot[o].reqId == effectId)))
			return -5;
	Slot& q = S.slot[si];
	q.req = kAdd; q.reqId = effectId;
	q.flags = flags;
	q.lastTouch = NowSeconds();
	q.wantHandle = S.nextHandle++;
	return q.wantHandle;
}

int Nimbus_RemoveSlot(int si)
{
	if (!SlotOk(si)) return -4;
	if (S.verified != 1) return 0;
	S.slot[si].req = kRemove;
	return 1;
}

int Nimbus_Add(int effectId, int flags) { return Nimbus_AddSlot(0, effectId, flags); }

int Nimbus_Remove(int handleOrId)
{
	(void)handleOrId;   // slot 0 holds one native nimbus: any value removes it
	return Nimbus_RemoveSlot(0);
}

int Nimbus_BurstEx(uint32_t spawnId, int effectId, int ms, int flags)
{
	if (S.disabled) return -1;
	if (!EnsureVerified()) return -2;
	if (effectId <= 0 || effectId > 0xFFFF) return -3;
	if (spawnId > 0xFFFF) return -6;                     // key packs SpawnID << 16
	if (IsCustom(effectId) && VerifyCustom() == -1) return -7;   // t468: custom effects off (signature / earlier failure)
	for (const Slot& q : S.slot)   // the same record already worn on you (Body FX / aura): leave it to that slot
		if ((spawnId == 0 || spawnId == q.activeSpawn) && (q.activeId == effectId || q.wantId == effectId)) return -5;
	if (ms < 300) ms = 300;
	if (ms > 8000) ms = 8000;
	B.reqPending = true; B.reqId = effectId; B.reqSpawn = spawnId; B.reqFlags = flags;
	B.reqUntil = NowSeconds() + ms * 0.001;
	return 1;
}

int Nimbus_Burst(uint32_t spawnId, int effectId, int ms) { return Nimbus_BurstEx(spawnId, effectId, ms, 0); }

int Nimbus_CustomTune(int brightPct, int sizePct)
{
	if (brightPct < 25) brightPct = 25;
	if (brightPct > 300) brightPct = 300;
	if (sizePct < 25) sizePct = 25;
	if (sizePct > 300) sizePct = 300;
	X.wantB = brightPct; X.wantS = sizePct; StockBright = brightPct;
	return 1;   // written into the records on the next custom play (game thread)
}

bool Nimbus_LevelBypass() { return EnsureVerified() && LevelsVerified(); }
bool Nimbus_CustomAvailable()
{
	if (!EnsureVerified()) return false;
	return VerifyCustom() == 1;
}

const char* Nimbus_CustomInfo()
{
	static char buf[300];
	if (S.verified == 0) EnsureVerified();
	if (S.verified == 1) VerifyCustom();
	snprintf(buf, sizeof(buf), "tag=%s base_id=%d count=%d emitters=%d verified=%d ready=%d base=%d injected=%d reused=%d bright=%d size=%d tuned=%d/%d why=%s",
		CustomFx::kTag, CustomFx::kBaseId, CustomFx::kEffects, CustomFx::kEmitters, X.verified, X.ready ? 1 : 0, X.ready ? X.base : -1,
		X.injected, X.reused, X.wantB, X.wantS, X.tunedB, X.tunedS, X.why);
	return buf;
}

int Nimbus_BurstStop()
{
	B.reqPending = false;
	if (B.id) B.until = 0.0;   // removed on the next pulse (game thread)
	return 1;
}

const char* Nimbus_BurstStatus()
{
	if (S.verified == 0) EnsureVerified();
	const double now = NowSeconds();
	snprintf(B.status, sizeof(B.status), "verified=%d(%s) disabled=%d live=%d active=%d spawn=%u owned=%d left_ms=%d alive=%d attached=%d owner_ok=%d fell=%d tfail=%d played=%d refused=%d cfx=%d cfxbase=%d layers=%d stage=%d plvl=%d forced=%d eqdensity=%.2f eqopacity=%.2f last=%s",
		S.verified, S.verifyWhy, S.disabled ? 1 : 0, S.liveCode, B.id, B.spawn, B.owned ? 1 : 0,
		B.id ? (int)((B.until - now) * 1000.0) : 0, B.alive, B.attached, B.ownerOk, B.fell, B.tfail, B.played, B.refused,
		X.verified == -1 ? -1 : (X.ready ? 2 : X.verified), X.ready ? X.base : -1, B.layers, B.stage, L.ok, L.forced, L.userD, L.userO, B.last);
	return B.status;
}

void Nimbus_BeginZone()
{
	if (!S.disabled)
		for (int i = 0; i < kSlots; ++i)
			if (S.slot[i].activeId) DoRemove(S.slot[i], i, "zone out");
	if (!S.disabled && S.verified == 1) BurstRemove("zone out");
	B.reqPending = false;
	S.readyAt = NowSeconds() + 3.0;
}

void Nimbus_Shutdown()
{
	if (!S.disabled && S.verified == 1) BurstRemove("plugin unload");
	B.reqPending = false;
	for (int i = 0; i < kSlots; ++i)
	{
		Slot& q = S.slot[i];
		if (q.activeId && !S.disabled && S.verified == 1)
			DoRemove(q, i, "plugin unload");
		q.wantId = 0;
		q.req = kNone;
	}
}

void Nimbus_Pulse(bool zoning)
{
	if (S.verified != 1 || S.disabled)
		return;
	const double now = NowSeconds();
	for (int i = 0; i < kSlots; ++i)
	{
		Slot& q = S.slot[i];
		if (q.req == kRemove)
		{
			q.req = kNone;
			q.wantId = 0;
			DoRemove(q, i, "requested");
		}
		else if (q.req == kAdd)
		{
			q.req = kNone;
			if (q.activeId && q.activeId != q.reqId)
				DoRemove(q, i, "replaced");
			q.wantId = q.reqId;
		}
		if ((q.flags & 1) && q.wantId && now - q.lastTouch > 5.0)
		{
			q.wantId = 0;
			DoRemove(q, i, "autoclose: owner stopped calling");
		}
		if (S.disabled) return;
	}
	if (zoning)
		return;
	uint32_t sid = 0; uintptr_t actor = 0, ps = 0;
	const int live = ReadLive(&sid, &actor, &ps);
	S.liveCode = live;
	if (live == 7) { Fault("read", 0); return; }
	if (live != 0)
	{
		S.seenSpawn = 0; S.seenActor = 0;
		return;   // not in a usable state yet (char select, zoning, actor not built)
	}
	if (sid != S.seenSpawn || actor != S.seenActor)
	{   // new spawn (zone-in): wait 2 s until it is stable. t488: same spawn, model rebuilt (illusion / wear change,
		// every ~5 s under some illusions): put the effects straight back on the new model (0.25 s), no 2 s gap
		const double wait = (sid == S.seenSpawn && S.seenSpawn != 0) ? 0.25 : 2.0;
		S.seenSpawn = sid; S.seenActor = actor;
		if (now + wait > S.readyAt) S.readyAt = now + wait;
	}
	for (int i = 0; i < kSlots && !S.disabled; ++i)
	{
		Slot& q = S.slot[i];
		if (q.activeId && (q.activeSpawn != sid || q.activeActor != actor))
			DoRemove(q, i, "actor changed");   // key = old SpawnID; re-added below on the new model
		// t488: no re-anchor check. The t487 check read the foot point's +0xF0 as a world position, but it is ~(0,0,0)
		// (log: "dxy" = distance from the zone origin, dz a constant -1.9), so it re-anchored every trail
		// feet -> root -> floor 1.5 s apart: the remove/re-add flicker. Trails play exactly like 566 (attach 6/7 feet).
		if (!q.wantId && q.activeId)
			DoRemove(q, i, "not wanted");
		if (q.wantId && !q.activeId && now >= S.readyAt && !S.disabled)
			DoAdd(q, i, sid, actor, ps);
	}
	if (!S.disabled)
		BurstPulse(now, sid, ps, actor);   // proc burst: needs the same ready local state (particle system, spawn manager)
}

const char* Nimbus_StatusSlot(int si)
{
	static char bad[64];
	if (!SlotOk(si)) { snprintf(bad, sizeof(bad), "verified=0(bad slot) slot=%d", si); return bad; }
	Slot& q = S.slot[si];
	q.lastTouch = NowSeconds();   // doubles as the autoclose keepalive
	if (S.verified == 0)
		EnsureVerified();
	int alive = -1;
	if (q.activeId && S.verified == 1 && !S.disabled)
	{
		uint32_t sid; uintptr_t a, ps;
		if (ReadLive(&sid, &a, &ps) == 0)
			alive = CountKey(ps, (q.activeSpawn << 16) | (uint32_t)q.activeId);
	}
	snprintf(q.status, sizeof(q.status), "verified=%d(%s) disabled=%d live=%d want=%d active=%d spawn=%u alive=%d density=%.2f opacity=%.2f slot=%d anchor=%s last=%s",
		S.verified, S.verifyWhy, S.disabled ? 1 : 0, S.liveCode, q.wantId, q.activeId, q.activeSpawn, alive, S.density, S.opacity, si, kAnchorName[q.anchor], S.last);
	return q.status;
}

const char* Nimbus_Status() { return Nimbus_StatusSlot(0); }
