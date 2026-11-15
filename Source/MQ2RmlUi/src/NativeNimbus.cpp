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
// Guards: exact version strings, byte signatures of both functions, the particle system's vtable pointer
// and its two slots, module ranges for every pointer, local player + actor non-null, effect id in range
// with at least one stage-2 emitter. Every read and call is inside SEH; an access violation logs, turns
// the feature off for the session and never retries.
#include "NimbusClientOffsets.h"   // includes <mq/Plugin.h>
#include "NativeNimbus.h"
#include <windows.h>
#include <cstdio>
#include <cstring>
#include <cstdarg>

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

using AddFn = void(__fastcall*)(uint32_t spawnId, int effectId);
using RemoveFn = int(__fastcall*)(uint32_t spawnId, uint32_t effectId);

struct Module { uintptr_t base = 0, size = 0; };

enum Req { kNone, kAdd, kRemove };

// aura rework: independent slots on the same client call. Slot 0 = the Body FX nimbus (old exports), slot 1 = the
// ground aura. Each slot owns its own key (SpawnID << 16 | effectId), so two different effects never touch each other;
// the same effect id is refused in a second slot (one key, one owner).
constexpr int kSlots = 2;
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

// 1 ok, 0 not a nimbus-capable record, -1 fault
int CheckEffect(int id, int* nEmit)
{
	*nEmit = 0;
	__try
	{
		int count = *(int*)(S.game.base + kRvaEffCount);
		uintptr_t tab = *(uintptr_t*)(S.game.base + kRvaEffTable);
		if (id <= 0 || id >= count || !HeapPtr(tab)) return 0;
		const int* em = (const int*)(tab + (size_t)id * kRecSize + kStage2Emit);
		for (int k = 0; k < 4; ++k)
			if (em[k * 4] > 0) ++*nEmit;
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

int CallAdd(uint32_t spawnId, int effectId, DWORD* code)
{
	__try { ((AddFn)(S.game.base + kRvaAdd))(spawnId, effectId); }
	__except (*code = GetExceptionCode(), EXCEPTION_EXECUTE_HANDLER) { return -1; }
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

void DoAdd(Slot& q, int si, uint32_t spawnId, uintptr_t actor, uintptr_t ps)
{
	int nEmit = 0;
	int ok = CheckEffect(q.wantId, &nEmit);
	if (ok < 0) { Fault("effect check", 0); return; }
	if (ok == 0) { Log("slot%d reject id=%d: not a stage-2 (nimbus) effect record", si, q.wantId); q.wantId = 0; return; }
	const uint32_t key = (spawnId << 16) | (uint32_t)q.wantId;
	const int before = CountKey(ps, key);
	if (before > 0)
	{   // the server (a real buff) or an earlier add already owns this key: do not stack a second copy
		Log("slot%d skip add id=%d: %d emitters with key 0x%08X already exist", si, q.wantId, before, key);
		q.activeId = q.wantId; q.activeSpawn = spawnId; q.activeActor = actor; q.lastEmitters = before;
		return;
	}
	DWORD code = 0;
	if (CallAdd(spawnId, q.wantId, &code) != 0) { Fault("add", code); return; }
	const int after = CountKey(ps, key);
	q.activeId = q.wantId; q.activeSpawn = spawnId; q.activeActor = actor; q.lastEmitters = after;
	Log("slot%d added id=%d spawn=%u key=0x%08X record_emitters=%d alive=%d density=%.2f opacity=%.2f",
		si, q.wantId, spawnId, key, nEmit, after, S.density, S.opacity);
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

void Nimbus_BeginZone()
{
	if (!S.disabled)
		for (int i = 0; i < kSlots; ++i)
			if (S.slot[i].activeId) DoRemove(S.slot[i], i, "zone out");
	S.readyAt = NowSeconds() + 3.0;
}

void Nimbus_Shutdown()
{
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
	{   // new spawn / new actor (zone-in, illusion rebuild): wait until it is stable
		S.seenSpawn = sid; S.seenActor = actor;
		if (now + 2.0 > S.readyAt) S.readyAt = now + 2.0;
	}
	for (int i = 0; i < kSlots && !S.disabled; ++i)
	{
		Slot& q = S.slot[i];
		if (q.activeId && (q.activeSpawn != sid || q.activeActor != actor))
			DoRemove(q, i, "actor changed");   // key = old SpawnID; then re-add below once stable
		if (!q.wantId && q.activeId)
			DoRemove(q, i, "not wanted");
		if (q.wantId && !q.activeId && now >= S.readyAt && !S.disabled)
			DoAdd(q, i, sid, actor, ps);
	}
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
	snprintf(q.status, sizeof(q.status), "verified=%d(%s) disabled=%d live=%d want=%d active=%d spawn=%u alive=%d density=%.2f opacity=%.2f slot=%d last=%s",
		S.verified, S.verifyWhy, S.disabled ? 1 : 0, S.liveCode, q.wantId, q.activeId, q.activeSpawn, alive, S.density, S.opacity, si, S.last);
	return q.status;
}

const char* Nimbus_Status() { return Nimbus_StatusSlot(0); }
