// Ornament (model) swap proof: client-side only, local player.
//
// Evidence (EQGraphics.dll of eqgame "Sep 11 2025 11:54:10", RVAs base 0x180000000; static disassembly on the box,
// read-only memory reads of the running client):
//  * eqgame wear-change path (function eqgame+0x305D50) builds "IT%u" (eqgame+0x306ACE) and calls
//    [PlayerClient+0x1170]->vft[0x270](point, "IT####", NULL) (eqgame+0x3070FD); with tag NULL it detaches
//    (eqgame+0x306BF6). The same function also sends packets in other branches, so we do NOT call it; we call
//    only the engine slot it uses.
//  * body vft +0x2B9D90 [0x270] = +0x5C2C0 ChangeBoneAttachment(int point, const char* tag, const CMatrix44* m):
//      p = *(this+0x1F8+point*8); if !p return 0; old = p->vft[0x10]()
//      tag NULL or '0...' -> p->vft[0x18](NULL); delete old; return 0
//      name = "%s_ACTORDEF" (+0x2BA460); if tag "IT<n>" and n in resmgr remap hash (resmgr+0x90/+0x98) -> "IT%d_ACTORDEF"
//      resmgr (= *(EQGraphics+0x34BC28)) find(0x1008, name, &def, load=1, 3) (+0x8C3F0): if not in the table it
//      calls resmgr->vft[0x248] (+0x813B0) = load-on-demand from the archive listed for it, then retries.
//      not found -> detach + delete old, return 0.   found -> new actor, p->vft[0x18](new), delete old, return new.
//  * attach point vft +0x2B99E8: [0x10] = +0x9490 (attached actor at p+8), [0] = +0x57BA0 point name.
//  * definition tag: actor+0x1D0 -> def (vft +0x2B97E8), *(def+0x10) = "IT6120_ACTORDEF".
//  Live (De'Immortal, DWM): point 11 DWMCHEST_POINT_TRACK = IT6120, 3 DWMR_POINT_TRACK (empty), 26/27 shoulders.
//
// Restore: ChangeBoneAttachment(point, original tag or NULL) and re-apply the original per-material tints through
// the verified SetMaterialTint(int, RGB*) path (ActorMaterial). Only if the piece at the point is still ours (if
// the game re-attached something itself, e.g. a real wear change, we leave it alone).
// Every read and call is inside SEH; a fault disables the feature for the session.
//
// chestfix (HeroForge / NewArmor pieces). eqgame's real wear-slot update is +0x98890 (this = PlayerClient+0xFB8,
// called e.g. from +0x2FD7FE). For a slot whose equipment has a HeroForge model it looks up a record
// r = +0x2CFC20(mgr, hfId, raceTag) (mgr = +0x2CFCD0() = eqgame+0xEE48A0, raceTag from +0x25E770 table
// eqgame+0xE65CC0 by race/gender; record: +0 IT first point, +4 IT second point, +8 "no offset matrix",
// +0xA "hide body skin region", +0xC hfId, +0x10 race tag) and then, besides the first-point attach that we
// already did, it also:
//   (1) attaches r+4 at the slot's SECOND point, or detaches it ("0") when r+4 = 0. Chest = points 11 + 7
//       (+0x98C06 [rsp+2C]=7, +0x98a24 [rsp+28]=11). The plain chest path puts a second model at point 7 too
//       (+0x9926E..+0x992BD), so a chest swap that only replaces point 11 leaves the old lower chest piece at 7
//       inside the new model: two coincident surfaces = the lower-chest shimmer (only on swapped chests).
//   (2) hides the body's own skin region of the slot: body vft[0x1D8] (+0x60B50) -> sprite vft[0x78] (+0x66A50)
//       sets byte region[slot] in one of two layers (+0x90 / +0x97; drawn hidden if either, +0x65F50).
//       Values: chest loop +0x98D25 layer 1 regions 1..6 except 4,6 = r+0xA && robe; then +0x98DFA layer 0
//       region slot = r+0xA && !robe (robe = (unsigned)(chest material - 10) <= 6, +0x98923; see Robe()). Regions: CH 1 UA 2 FA 3 HN 4 LG 5 FT 6
//       (+0x24820).
//   (3) passes an offset matrix to ChangeBoneAttachment when r+8 = 0: +0x2CFB60(mgr, point, variant, raceTag)
//       (variant 1 only for point 11 when v<=6), +0x98FBB.
// We find r read-only by IT number + the player's race tag (a reverse scan of the same table) and do the same
// three things; every change is snapshotted and put back on restore. rml_orn_opts(mask) switches them
// (1 = second point, 2 = skin regions, 4 = matrix, 8 = test: skin hide even if fa=0; default 7, user-confirmed chest fix) for A/B tests; rml_orn_diag() reports all of it.
#include "NimbusClientOffsets.h"
#include "OrnamentSwap.h"
#include "ActorMaterial.h"
#include <windows.h>
#include <cstdio>
#include <cstring>
#include <cstdarg>
#include <cctype>

void Canvas_Log(const char* line);

namespace {

using namespace NimbusOffsets;

constexpr uintptr_t kVftBody = 0x2B9D90, kPtVft = 0x2B99E8, kDefVft = 0x2B97E8;
constexpr uintptr_t kFnCBA = 0x05C2C0, kFnPtActor = 0x009490, kFnPtName = 0x057BA0, kFnDefTag = 0x0541C0, kFnGetDef = 0x05ECD0;
constexpr uintptr_t kFnResFind = 0x08C3F0, kFnTabFind = 0x224A40, kRvaResMgr = 0x34BC28, kRvaFmt = 0x2BA460;
constexpr size_t kSlotCBA = 0x270;
constexpr size_t kOffAttach = 0x1F8, kOffPtActor = 8, kOffPtInfo = 0x38, kOffPtInfoName = 0x98, kOffDef = 0x1D0, kOffDefTag = 0x10;
constexpr size_t kResTab = 8 + 0x20, kRemapBuckets = 0x90, kRemapCount = 0x98;
constexpr int kNumPoints = 28, kTagMax = 64, kPalMax = 32;

// chestfix: eqgame (+ EQGraphics) addresses for the HeroForge record table and body skin regions
constexpr uintptr_t kRvaHFMgr = 0xEE48A0, kRvaRaceTab = 0xE65CC0;
constexpr size_t kOffEqSub = 0xFB8, kOffSubV = 0xAC, kOffSubRace = 0x18, kOffSubRace2 = 0x14, kOffSubGender = 0x20;
constexpr uintptr_t kFnSetRegion = 0x060B50, kFnSprSetRegion = 0x066A50, kFnSprGetter = 0x05ED10, kSubVft = 0x2B9CC0, kFnSubGet = 0x05ED00;
constexpr size_t kSlotSetRegion = 0x1D8, kSlotGetSprite = 0x4C8, kOffSub = 0x110, kOffSprite = 0x1E8, kOffRegion0 = 0x90, kOffRegion1 = 0x97;
constexpr size_t kOffActMtx = 0xC0, kOffActMtxOn = 0x100;
constexpr int kNumRegions = 7;
constexpr unsigned kOptCompanion = 1, kOptRegions = 2, kOptMatrix = 4, kOptForceSkin = 8, kOptAll = 15, kOptDefault = kOptCompanion | kOptRegions | kOptMatrix;

struct Sig { uintptr_t rva; unsigned char b[32]; size_t n; const char* what; };
// matfix: body region material (texture) swap through eqgame's own +0x9B9F0
//   bool SetArmorTexture(ActorClient* ac /* = PlayerClient+0xFB8 */, int region /* 1 CH 2 UA 3 FA 4 HN 5 LG 6 FT */,
//                        int oldMat, int newMat, int tint, uint8 variation, int p7 /* = [ac+0x1C], caller +0x30340E */, uint8 hf)
// builds "<race><region>%02d01_MDF" (+0x9BC23) for old and new, calls body vft[0x1D0](oldMDF, newMDF, &tint, 0, variant, 0)
// per sub-texture (+0x9BD6D / +0x9C022) and on success writes ActorEquipment[region].Material (+0x9C3B0, ac+0x98+r*0x14)
// and tint (+0x9C3BD, ac+0x64+r*4). hf != 0 draws untinted (+0x9BCC1), as for an item with a HeroForge model (+0x9A1B8).
// Callers: +0x30342E (PlayerClient wrapper), +0x9A1CC (all regions). No network code in it.
constexpr uintptr_t kFnSetArmorTex = 0x9B9F0;
constexpr size_t kOffEquip = 0x98, kEquipStride = 0x14, kOffEquipTint = 0x64, kOffAcP7 = 0x1C, kSlotReplaceMat = 0x1D0;
const Sig kMatSigs[] = {   // eqgame.exe
	{ kFnSetArmorTex, {0x40,0x55,0x53,0x56,0x57,0x41,0x54,0x41,0x55,0x41,0x56,0x41,0x57,0x48,0x8d,0xac,0x24,0xf8,0xfe,0xff,0xff,0x48,0x81,0xec,0x08,0x02,0x00,0x00,0x48,0x8b,0x05,0xf5}, 32, "SetArmorTexture prologue" },
	{ 0x9BC23, {0x48,0x8d,0x15,0x4e,0x67,0x7a,0x00}, 7, "SetArmorTexture MDF format" },
	{ 0x842378, {'%','s','%','0','2','d','0','1','_','M','D','F',0}, 13, "%s%02d01_MDF string" },
	{ 0x9BD6D, {0xff,0x90,0xd0,0x01,0x00,0x00}, 6, "SetArmorTexture vft[0x1d0] chest" },
	{ 0x9C022, {0xff,0x90,0xd0,0x01,0x00,0x00}, 6, "SetArmorTexture vft[0x1d0] hands" },
	{ 0x9C3B0, {0x89,0x94,0x87,0x98,0x00,0x00,0x00}, 7, "SetArmorTexture material write" },
	{ 0x9C3BD, {0x89,0x44,0x8f,0x64}, 4, "SetArmorTexture tint write" },
	{ 0x303400, {0x48,0x8d,0x8b,0xb8,0x0f,0x00,0x00}, 7, "wrapper ActorClient = pl+0xFB8" },
	{ 0x30340E, {0x8b,0x83,0xd4,0x0f,0x00,0x00}, 6, "wrapper p7 = [ac+0x1C]" },
	{ 0x30342E, {0xe8,0xbd,0x85,0xd9,0xff}, 5, "wrapper call +0x9B9F0" },
};
using SetArmorTexFn = bool(__fastcall*)(void* ac, int region, int oldMat, int newMat, int tint, uint8_t variation, int p7, uint8_t hf);
struct MatState { bool ours = false; uintptr_t body = 0; int origMat = 0, myMat = 0; uint32_t origTint = 0; uint8_t var = 0; };
const Sig kGameSigs[] = {   // eqgame.exe
	{ 0x2CFCD0, {0x40,0x53,0x48,0x83,0xec,0x20,0x8b,0x0d,0xc4,0xee,0x29,0x01,0x65,0x48,0x8b,0x04,0x25,0x58,0x00,0x00,0x00,0xba,0x04,0x00,0x00,0x00,0x48,0x8b,0x0c,0xc8,0x8b,0x04}, 32, "hf mgr getter" },
	{ 0x2CFCF9, {0x48,0x8d,0x05,0xa0,0x4b,0xc1,0x00}, 7, "hf mgr lea" },
	{ 0x2CFC71, {0xf7,0x73,0x08,0x48,0x8b,0x03,0x48,0x8b,0x04,0xd0,0x48,0x85,0xc0,0x74,0x2f}, 15, "hf record find" },
	{ 0x2CFC90, {0x44,0x39,0x48,0x0c,0x75,0x10,0x44,0x38,0x40,0x10,0x75,0x0a,0x38,0x50,0x11,0x75}, 16, "hf record key" },
	{ 0x2CFBC4, {0xf7,0x73,0x20,0x48,0x8b,0x43,0x18,0x48,0x8b,0x04,0xd0,0x48,0x85,0xc0,0x74,0x35}, 16, "hf matrix find" },
	{ 0x2CFBE4, {0x44,0x39,0x50,0x40,0x75,0x16,0x44,0x39,0x48,0x44,0x75,0x10,0x44,0x38,0x40,0x48}, 16, "hf matrix key" },
	{ 0x25E770, {0x48,0x89,0x5c,0x24,0x08,0x48,0x8b,0xda,0x47,0x8d,0x1c,0x08,0x33,0xd2,0x41,0x8b,0xc3,0xf7,0x71,0x08,0x48,0x8b,0x01,0x48,0x8b,0x0c,0xd0,0x48,0x85,0xc9,0x74,0x0e}, 32, "race tag find" },
	{ 0x25E719, {0x48,0x8d,0x05,0xa0,0x75,0xc0,0x00}, 7, "race tag table lea" },
	{ 0x098923, {0x41,0x8b,0x87,0xac,0x00,0x00,0x00,0x83,0xc0,0xf6}, 10, "wear v field" },
	{ 0x098A83, {0x41,0x8b,0x77,0x18,0x85,0xf6,0x75,0x04,0x41,0x8b,0x77,0x14,0x41,0x0f,0xb6,0x5f,0x20}, 17, "wear race/gender" },
	{ 0x098FBB, {0x41,0x38,0x44,0x24,0x08,0x75,0x2a,0x41,0x83,0xf8,0x06,0x77,0x09,0x41,0x83,0xfe,0x0b,0x75,0x03,0x8d,0x58,0x01}, 22, "wear matrix variant" },
	{ 0x098C06, {0xc7,0x44,0x24,0x2c,0x07,0x00,0x00,0x00}, 8, "chest second point 7" },
	{ 0x098A24, {0xc7,0x44,0x24,0x28,0x0b,0x00,0x00,0x00}, 8, "chest first point 11" },
};
const Sig kGfxSigs2[] = {   // EQGraphics.dll
	{ kFnSetRegion, {0x48,0x89,0x5c,0x24,0x08,0x48,0x89,0x6c,0x24,0x10,0x48,0x89,0x74,0x24,0x18,0x57,0x48,0x83,0xec,0x20,0x48,0x8b,0x01,0x41,0x0f,0xb6,0xf9,0x41,0x0f,0xb6,0xf0,0x8b}, 32, "body set region" },
	{ kFnSprSetRegion, {0x83,0xfa,0x06,0x77,0x1e,0x48,0x63,0xc2,0x45,0x84,0xc9,0x75,0x0b,0x44,0x88,0x84,0x08,0x90,0x00,0x00,0x00,0xb0,0x01,0xc3,0x44,0x88,0x84,0x08,0x97,0x00,0x00,0x00}, 32, "sprite set region" },
	{ kFnSprGetter, {0x48,0x81,0xc1,0x10,0x01,0x00,0x00,0x48,0x8b,0x01,0x48,0xff,0xa0,0x88,0x00,0x00}, 16, "body sprite getter" },
	{ kFnSubGet, {0x48,0x8b,0x81,0xd8,0x00,0x00,0x00,0xc3}, 8, "sub sprite getter" },
	{ kFnCBA + 0x3D0, {0x89,0x83,0xc0,0x00,0x00,0x00}, 6, "CBA matrix copy" },
	{ kFnCBA + 0x45D, {0xc6,0x83,0x00,0x01,0x00,0x00,0x01}, 7, "CBA matrix flag" },
};
const Sig kSigs[] = {
	{ kFnCBA, {0x40,0x53,0x55,0x56,0x57,0x41,0x54,0x41,0x55,0x41,0x56,0x41,0x57,0x48,0x81,0xec,0x28,0x01,0x00,0x00,0x48,0x8b,0x05,0xcd,0xcc,0x2e,0x00,0x48,0x33,0xc4,0x48,0x89}, 32, "ChangeBoneAttachment" },
	{ kFnCBA + 0x16A, {0x4c,0x8d,0x05,0x2f,0xe0,0x25,0x00}, 7, "CBA %s_ACTORDEF lea" },
	{ kFnCBA + 0x1A3, {0x48,0x8b,0x0d,0xbe,0xf7,0x2e,0x00}, 7, "CBA remap resmgr" },
	{ kFnCBA + 0x1FB, {0x48,0x8b,0x0d,0x66,0xf7,0x2e,0x00,0xe8,0x29,0xff,0x02,0x00}, 12, "CBA resmgr find call" },
	{ kFnResFind, {0x48,0x89,0x5c,0x24,0x08,0x48,0x89,0x6c,0x24,0x10,0x48,0x89,0x74,0x24,0x18,0x57}, 16, "resmgr find" },
	{ kFnTabFind, {0x48,0x89,0x5c,0x24,0x08,0x48,0x89,0x74,0x24,0x10,0x48,0x89,0x7c,0x24,0x18,0xff}, 16, "table find" },
	{ kFnPtActor, {0x48,0x8b,0x41,0x08,0xc3}, 5, "point actor" },
	{ kFnPtName, {0x48,0x8b,0x41,0x38,0x48,0x8b,0x80,0x98,0x00,0x00,0x00,0xc3}, 12, "point name" },
	{ kFnGetDef, {0x48,0x8b,0x81,0xd0,0x01,0x00,0x00,0xc3}, 8, "get definition" },
	{ kFnDefTag, {0x48,0x83,0xc1,0x08,0xe9}, 5, "def tag" },
	{ kRvaFmt, {'%','s','_','A','C','T','O','R','D','E','F',0}, 12, "%s_ACTORDEF string" },
};

using CBAFn = void*(__fastcall*)(void* actor, int point, const char* tag, const void* mtx);
using SetRegionFn = void(__fastcall*)(void* actor, int region, bool hide, bool layer1);

struct Module { uintptr_t base = 0, size = 0; };
enum Op { kSet, kRestore, kMat };
struct Req { Op op; int point; char tag[kTagMax]; };

struct PointState
{
	bool ours = false;          // we changed this point
	uintptr_t body = 0;         // body actor it belongs to
	uintptr_t mine = 0;         // actor we attached (0 if the set failed and the point is now empty)
	char origTag[kTagMax] = ""; // "" = point was empty
	char myTag[kTagMax] = "";
	int palCount = 0;
	uint32_t pal[kPalMax] = {};
	bool origMtxOn = false;      // the original piece had an attach matrix (actor+0x100) -> put it back with it
	float origMtx[16] = {};
	int compOf = -1;            // this point was changed as the second point of another point's swap
	char hf[96] = "";           // what the HeroForge emulation did (diag)
};
struct Cell { bool touched = false; uint8_t orig = 0, wrote = 0; int owner = -1; };
struct HFRec { bool found = false; unsigned itA = 0, itB = 0; uint8_t f8 = 0, f9 = 0, fa = 0; unsigned key = 0; int matches = 0; int conflicts = 0; };

struct State
{
	Module game, gfx;
	int verified = 0;
	char verifyWhy[64] = "";
	bool disabled = false;
	Req q[16]; int nq = 0;
	PointState pt[kNumPoints];
	int hfOk = 0;                // 1 HeroForge emulation verified, -1 not (swap still works, without it)
	char hfWhy[64] = "";
	unsigned opts = kOptDefault;   // 7: point 7 + skin regions + matrix (user-confirmed chest fix); 8 = test: hide slot skin even if fa=0
	Cell cell[2][kNumRegions];
	int matOk = 0;               // 1 SetArmorTexture verified, -1 not (material swap off)
	char matWhy[64] = "";
	MatState mat[kNumRegions];
	char diag[4096] = "";
	uintptr_t body = 0;
	int live = -1;
	int calls = 0;
	char last[240] = "idle";
	char status[3072] = "";
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
	char line[1000];
	va_list ap; va_start(ap, fmt);
	int n = snprintf(line, sizeof(line), "ornproof ");
	vsnprintf(line + n, sizeof(line) - n, fmt, ap);
	va_end(ap);
	Canvas_Log(line);
	strncpy(S.last, line + n, sizeof(S.last) - 1);
	S.last[sizeof(S.last) - 1] = 0;
}
void Fault(const char* where, DWORD code)
{
	S.disabled = true; S.nq = 0;
	Log("FAULT in %s code=0x%08lX -> ornament proof disabled for this session", where, code);
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
		if (((const uintptr_t*)(g + kVftBody))[kSlotCBA / 8] != g + kFnCBA) { strcpy(S.verifyWhy, "body vft[0x270]"); return -1; }
		if (((const uintptr_t*)(g + kVftBody))[0x150 / 8] != g + kFnGetDef) { strcpy(S.verifyWhy, "body vft[0x150]"); return -1; }
		if (((const uintptr_t*)(g + kPtVft))[0x10 / 8] != g + kFnPtActor || ((const uintptr_t*)(g + kPtVft))[0] != g + kFnPtName) { strcpy(S.verifyWhy, "point vft"); return -1; }
		if (((const uintptr_t*)(g + kDefVft))[0] != g + kFnDefTag) { strcpy(S.verifyWhy, "def vft"); return -1; }
	}
	__except (EXCEPTION_EXECUTE_HANDLER) { strcpy(S.verifyWhy, "fault while verifying"); return -1; }
	strcpy(S.verifyWhy, "ok");
	// chestfix extras: separate check, a failure only turns the HeroForge emulation off
	S.hfOk = -1;
	__try
	{
		const uintptr_t g = S.gfx.base;
		bool ok = true;
		for (const Sig& sg : kGameSigs) if (memcmp((void*)(S.game.base + sg.rva), sg.b, sg.n) != 0) { snprintf(S.hfWhy, sizeof(S.hfWhy), "sig %s", sg.what); ok = false; break; }
		if (ok) for (const Sig& sg : kGfxSigs2) if (memcmp((void*)(g + sg.rva), sg.b, sg.n) != 0) { snprintf(S.hfWhy, sizeof(S.hfWhy), "sig %s", sg.what); ok = false; break; }
		if (ok && ((const uintptr_t*)(g + kVftBody))[kSlotSetRegion / 8] != g + kFnSetRegion) { strcpy(S.hfWhy, "body vft[0x1d8]"); ok = false; }
		if (ok && ((const uintptr_t*)(g + kVftBody))[kSlotGetSprite / 8] != g + kFnSprGetter) { strcpy(S.hfWhy, "body vft[0x4c8]"); ok = false; }
		if (ok && ((const uintptr_t*)(g + kSubVft))[0x88 / 8] != g + kFnSubGet) { strcpy(S.hfWhy, "sub vft[0x88]"); ok = false; }
		if (ok) { S.hfOk = 1; strcpy(S.hfWhy, "ok"); }
	}
	__except (EXCEPTION_EXECUTE_HANDLER) { strcpy(S.hfWhy, "fault while verifying"); S.hfOk = -1; }
	// matfix: separate check, a failure only turns the material swap off
	S.matOk = -1;
	__try
	{
		bool ok = true;
		for (const Sig& sg : kMatSigs) if (memcmp((void*)(S.game.base + sg.rva), sg.b, sg.n) != 0) { snprintf(S.matWhy, sizeof(S.matWhy), "sig %s", sg.what); ok = false; break; }
		if (ok && !InModule(S.gfx, ((const uintptr_t*)(S.gfx.base + kVftBody))[kSlotReplaceMat / 8])) { strcpy(S.matWhy, "body vft[0x1d0] not in EQGraphics"); ok = false; }
		if (ok) { S.matOk = 1; strcpy(S.matWhy, "ok"); }
	}
	__except (EXCEPTION_EXECUTE_HANDLER) { strcpy(S.matWhy, "fault while verifying"); S.matOk = -1; }
	return 1;
}
bool EnsureVerified()
{
	if (S.verified == 0) { S.verified = VerifyBuild(); Log("verify: %s", S.verifyWhy); }
	return S.verified == 1 && !S.disabled;
}

void CopyStr(char* dst, size_t cap, uintptr_t src)
{   // SEH caller
	dst[0] = 0;
	if (!HeapPtr(src)) return;
	size_t i = 0;
	for (; i + 1 < cap; ++i) { char c = ((const char*)src)[i]; if (!c) break; dst[i] = (c >= 32 && c < 127) ? c : '?'; }
	dst[i] = 0;
}

int ReadBody(uintptr_t* body)
{
	*body = 0;
	__try
	{
		uintptr_t pl = *(uintptr_t*)(S.game.base + kRvaLocalPlayer);
		if (!HeapPtr8(pl)) return 1;
		if (!InModule(S.game, *(uintptr_t*)pl, 8)) return 2;
		uintptr_t a = *(uintptr_t*)(pl + kOffActor);
		if (!HeapPtr8(a)) return 3;
		if (*(uintptr_t*)a != S.gfx.base + kVftBody) return 5;
		*body = a;
	}
	__except (EXCEPTION_EXECUTE_HANDLER) { return 7; }
	return 0;
}

// definition name of an attached piece. Class A pieces (vft +0x2BA648) hold a kDefVft def (+0x10 = tag). Class B
// pieces (vft +0x2BC1B0, ctors +0x72FA0 / +0x73420) hold another definition class at +0x1D0 whose name the ctor reads
// through def->vft[0]() (+0x73087 / +0x73548); its address is not always 8-aligned (pt26 def ...F234), which the old
// HeapPtr8 check rejected -> '' tag (shoulder 26 refused, status '?' -> Lua resent). We never call vft[0]: we decode
// its body (only 'add rcx,imm8 ; jmp' and 'mov rax,[rcx+d] ; ret' / 'lea rax,[rcx+d] ; ret') and do the reads.
bool DefName(uintptr_t def, char* tag, size_t tcap, uintptr_t* dvtOut = nullptr, uintptr_t* fnOut = nullptr)
{
	tag[0] = 0;
	if (!HeapPtr(def)) return false;
	uintptr_t dvt = *(uintptr_t*)def;
	if (dvtOut) *dvtOut = dvt;
	if (!InModule(S.gfx, dvt, 8))
	{   // not an object: accept only an inline 'IT<digits>' string (the misaligned pointer may be a name)
		const char* c = (const char*)def;
		if (c[0] == 'I' && c[1] == 'T' && c[2] >= '0' && c[2] <= '9') { CopyStr(tag, tcap, def); return true; }
		return false;
	}
	if (dvt == S.gfx.base + kDefVft) { CopyStr(tag, tcap, *(uintptr_t*)(def + kOffDefTag)); return tag[0] != 0; }
	uintptr_t f = *(uintptr_t*)dvt, rcx = def;
	if (fnOut) *fnOut = f;
	for (int depth = 0; depth < 4 && InModule(S.gfx, f, 16); ++depth)
	{
		const uint8_t* c = (const uint8_t*)f;
		if (c[0] == 0x48 && c[1] == 0x83 && c[2] == 0xC1 && c[4] == 0xE9) { rcx += (int8_t)c[3]; f = f + 9 + *(int32_t*)(c + 5); continue; }
		int d = 0, len = 0;
		if (c[0] == 0x48 && (c[1] == 0x8B || c[1] == 0x8D) && c[2] == 0x41) { d = (int8_t)c[3]; len = 4; }
		else if (c[0] == 0x48 && (c[1] == 0x8B || c[1] == 0x8D) && c[2] == 0x81) { d = *(int32_t*)(c + 3); len = 7; }
		else return false;
		if (c[len] != 0xC3) return false;
		uintptr_t str = (c[1] == 0x8B) ? *(uintptr_t*)(rcx + d) : rcx + d;
		if (!HeapPtr(str)) return false;
		CopyStr(tag, tcap, str);
		return tag[0] != 0;
	}
	return false;
}

// point info: 0 ok (actor may be 0 = empty), 1 no point, 7 fault, 30 bad point
int ReadPoint(uintptr_t body, int i, uintptr_t* actor, char* pname, size_t pcap, char* tag, size_t tcap)
{
	*actor = 0; if (pname) pname[0] = 0; if (tag) tag[0] = 0;
	__try
	{
		uintptr_t p = *(uintptr_t*)(body + kOffAttach + (size_t)i * 8);
		if (!p) return 1;
		if (!HeapPtr8(p) || *(uintptr_t*)p != S.gfx.base + kPtVft) return 30;
		uintptr_t info = *(uintptr_t*)(p + kOffPtInfo);
		if (pname && HeapPtr8(info)) CopyStr(pname, pcap, *(uintptr_t*)(info + kOffPtInfoName));
		uintptr_t a = *(uintptr_t*)(p + kOffPtActor);
		if (a)
		{
			if (!HeapPtr8(a)) return 31;
			*actor = a;
			uintptr_t def = *(uintptr_t*)(a + kOffDef);
			if (tag) DefName(def, tag, tcap);
		}
	}
	__except (EXCEPTION_EXECUTE_HANDLER) { return 7; }
	return 0;
}

// read-only raw dump of the piece at a point whose definition tag we cannot read (diag / refuse log)
void RawPointInfo(uintptr_t body, int i, char* out, size_t cap)
{
	out[0] = 0;
	size_t m = 0;
	auto rva = [](uintptr_t v, char* b, size_t n) {
		if (InModule(S.gfx, v)) snprintf(b, n, "gfx+%llX", (unsigned long long)(v - S.gfx.base));
		else if (InModule(S.game, v)) snprintf(b, n, "game+%llX", (unsigned long long)(v - S.game.base));
		else snprintf(b, n, "%p", (void*)v);
	};
	__try
	{
		uintptr_t p = *(uintptr_t*)(body + kOffAttach + (size_t)i * 8);
		if (!HeapPtr8(p)) { snprintf(out, cap, "pt%d p=%p", i, (void*)p); return; }
		uintptr_t a = *(uintptr_t*)(p + kOffPtActor);
		if (!HeapPtr8(a)) { snprintf(out, cap, "pt%d a=%p", i, (void*)a); return; }
		char b1[40], b2[40], b3[40];
		uintptr_t avt = *(uintptr_t*)a; rva(avt, b1, sizeof(b1));
		uintptr_t def = *(uintptr_t*)(a + kOffDef);
		m += snprintf(out + m, cap - m, "pt%d a=%p avt=%s def=%p", i, (void*)a, b1, (void*)def);
		if (InModule(S.gfx, avt, 0x158)) { rva(((uintptr_t*)avt)[0x150 / 8], b2, sizeof(b2)); m += snprintf(out + m, cap - m, " avt[150]=%s", b2); }
		{
			char nm[kTagMax]; uintptr_t dv = 0, fn = 0; const bool okn = DefName(def, nm, sizeof(nm), &dv, &fn);
			char b4[40]; rva(fn, b4, sizeof(b4));
			m += snprintf(out + m, cap - m, " name=%s'%s' f0=%s", okn ? "ok" : "fail", nm, b4);
		}
		if (HeapPtr(def))
		{
			uintptr_t dvt = *(uintptr_t*)def; rva(dvt, b3, sizeof(b3));
			m += snprintf(out + m, cap - m, " dvt=%s q=", b3);
			for (int k = 1; k < 8 && m < cap - 40; ++k)
			{
				uintptr_t q = ((uintptr_t*)def)[k];
				char s[24] = "";
				if (q >= 0x10000 && q < 0x00007FFFFFFF0000ull)
				{
					size_t j = 0;
					for (; j < sizeof(s) - 1; ++j) { char c = ((const char*)q)[j]; if (c < 32 || c >= 127) break; s[j] = c; }
					s[j] = 0;
				}
				m += snprintf(out + m, cap - m, "%llX%s%s%s,", (unsigned long long)q, s[0] ? "\"" : "", s, s[0] ? "\"" : "");
			}
		}
	}
	__except (EXCEPTION_EXECUTE_HANDLER) { if (m < cap - 8) strcpy(out + m, " FAULT"); }
}

// "IT6120_ACTORDEF" -> "IT6120"; validates [A-Za-z0-9_], returns false on bad input
bool NormalizeTag(const char* in, char* out, size_t cap)
{
	if (!in) return false;
	size_t n = strlen(in);
	if (n == 0 || n >= cap) return false;
	for (size_t i = 0; i < n; ++i) if (!(isalnum((unsigned char)in[i]) || in[i] == '_')) return false;
	memcpy(out, in, n + 1);
	const char suf[] = "_ACTORDEF";
	const size_t sl = sizeof(suf) - 1;
	if (n > sl && _stricmp(out + n - sl, suf) == 0) out[n - sl] = 0;
	if (!out[0] || out[0] == '0') return false;   // engine treats '0...' as detach
	return true;
}

// read-only: is tag in the remap table (would be renamed by the engine)? 1 yes, 0 no, <0 error
int IsRemapped(const char* tag)
{
	if (_strnicmp(tag, "IT", 2) != 0 || !isdigit((unsigned char)tag[2])) return 0;
	const unsigned key = (unsigned)atoi(tag + 2);
	__try
	{
		uintptr_t rm = *(uintptr_t*)(S.gfx.base + kRvaResMgr);
		if (!HeapPtr8(rm)) return -1;
		uintptr_t b = *(uintptr_t*)(rm + kRemapBuckets);
		unsigned nb = *(unsigned*)(rm + kRemapCount);
		if (!HeapPtr8(b) || nb == 0 || nb > 1000000) return -2;
		uintptr_t e = ((uintptr_t*)b)[key % nb];
		for (int g = 0; e && g < 100000; ++g)
		{
			if (!HeapPtr8(e)) return -3;
			if (*(unsigned*)(e + 0x10) == key) return 1;
			e = *(uintptr_t*)(e + 0x18);
		}
	}
	__except (EXCEPTION_EXECUTE_HANDLER) { return -7; }
	return 0;
}

// read-only replica of the table find at +0x224A40 (hash h = (h*31 + c) ^ (h >> 26), signed shift)
int IsLoaded(const char* fullName)
{
	int h = 0;
	for (const char* p = fullName; *p; ++p) { int e = h * 31 + (int)(signed char)*p; h = e ^ (h >> 26); }
	__try
	{
		uintptr_t rm = *(uintptr_t*)(S.gfx.base + kRvaResMgr);
		if (!HeapPtr8(rm)) return -1;
		uintptr_t t = *(uintptr_t*)(rm + kResTab);
		if (!HeapPtr8(t)) return -2;
		uintptr_t b = *(uintptr_t*)t;
		unsigned nb = *(unsigned*)(t + 8);
		if (!HeapPtr8(b) || nb == 0 || nb > 10000000) return -3;
		uintptr_t e = ((uintptr_t*)b)[(unsigned)h % nb];
		for (int g = 0; e && g < 100000; ++g)
		{
			if (!HeapPtr8(e)) return -4;
			if (*(int*)e == h)
			{
				const char* nm = *(const char**)(e + 0x18);
				if (nm && HeapPtr((uintptr_t)nm) && strcmp(nm, fullName) == 0) return 1;
			}
			e = *(uintptr_t*)(e + 8);
		}
	}
	__except (EXCEPTION_EXECUTE_HANDLER) { return -7; }
	return 0;
}

int CallCBA(uintptr_t body, int point, const char* tag, const void* mtx, uintptr_t* result, DWORD* code)
{
	*result = 0;
	__try
	{
		CBAFn fn = (CBAFn)(*(uintptr_t**)body)[kSlotCBA / 8];
		*result = (uintptr_t)fn((void*)body, point, tag, mtx);
	}
	__except (*code = GetExceptionCode(), EXCEPTION_EXECUTE_HANDLER) { return -1; }
	++S.calls;
	return 0;
}

// ---------------------------------------------------------------- chestfix: HeroForge wear emulation
// wear slot (= body skin region) and side of an attach point, from +0x98890 (jump table +0x99454, [rsp+2C])
int PointSlot(int point, int* side)
{
	*side = 0;
	switch (point)
	{
	case 1: return 0;
	case 11: return 1;
	case 7: *side = 1; return 1;
	case 27: case 17: return 2;
	case 26: *side = 1; return 2;
	case 13: return 3;
	case 12: *side = 1; return 3;
	case 19: return 4;
	case 18: *side = 1; return 4;
	case 14: case 20: return 5;
	case 21: return 6;
	case 22: *side = 1; return 6;
	}
	return -1;
}
constexpr int kChestPoint = 11, kChestSecond = 7, kHelmPoint = 1, kHairPoint = 8;

struct PlayerHF { int v = 0, race = 0, gender = 0; char tag[4] = ""; };
// v = ActorClient.ActorEquipment[1].Material - 10 ([PlayerClient+0xFB8+0xAC]; eqlib Actors.h: ActorEquipment at
// ActorClient+0x98, 0x14 per slot, slot 1 = chest). eqgame compares it UNSIGNED (+0x98AF6/+0x98D3C/+0x98E05/
// +0x98FC2 'ja', +0x98F5A 'jbe'): true only for chest materials 10..16 (robes). A signed compare made a plate
// wearer (material 3 -> -7) take the robe branch and hide chest + arms + forearms + legs (chestfix v1 bug).
inline bool Robe(const PlayerHF& p) { return (unsigned)p.v <= 6u; }
bool ReadPlayerHF(PlayerHF* o)
{
	*o = PlayerHF();
	__try
	{
		uintptr_t pl = *(uintptr_t*)(S.game.base + kRvaLocalPlayer);
		if (!HeapPtr8(pl) || !InModule(S.game, *(uintptr_t*)pl, 8)) return false;
		const uintptr_t sub = pl + kOffEqSub;
		o->v = *(int*)(sub + kOffSubV) - 10;
		int r = *(int*)(sub + kOffSubRace);
		if (!r) r = *(int*)(sub + kOffSubRace2);
		o->race = r;
		o->gender = *(uint8_t*)(sub + kOffSubGender);
		strcpy(o->tag, o->gender == 1 ? "HUF" : "HUM");          // +0x25E79E default
		const uintptr_t t = S.game.base + kRvaRaceTab;           // replica of +0x25E770
		uintptr_t b = *(uintptr_t*)t; unsigned n = *(unsigned*)(t + 8);
		if (HeapPtr8(b) && n > 0 && n < 1000000)
		{
			const unsigned k = (unsigned)(r + o->gender);
			uintptr_t e = ((uintptr_t*)b)[k % n];
			for (int g = 0; e && g < 100000; ++g)
			{
				if (!HeapPtr8(e)) break;
				if (*(unsigned*)e == k && *(int*)(e + 0x28) == r && *(int*)(e + 0x2C) == o->gender)
				{
					for (int i = 0; i < 3; ++i) { char c = *(char*)(e + 0x10 + i); o->tag[i] = (c >= 32 && c < 127) ? c : '?'; }
					o->tag[3] = 0;
					break;
				}
				e = *(uintptr_t*)(e + 8);
			}
		}
	}
	__except (EXCEPTION_EXECUTE_HANDLER) { return false; }
	return true;
}

// read-only reverse scan of the HeroForge record table (+0x2CFC20's hash) for IT number `it` on `side`
HFRec FindHF(unsigned it, int side, const char* rt)
{
	HFRec r;
	__try
	{
		const uintptr_t m = S.game.base + kRvaHFMgr;
		uintptr_t b = *(uintptr_t*)m; unsigned n = *(unsigned*)(m + 8);
		if (!HeapPtr8(b) || n == 0 || n > 4000000) { r.matches = -1; return r; }
		int guard = 0;
		for (unsigned i = 0; i < n && guard < 4000000; ++i)
			for (uintptr_t e = ((uintptr_t*)b)[i]; e && guard < 4000000; ++guard)
			{
				if (!HeapPtr8(e)) { r.matches = -2; return r; }
				const unsigned a = *(unsigned*)e, bb = *(unsigned*)(e + 4);
				if ((side == 0 ? a : bb) == it && memcmp((const void*)(e + 0x10), rt, 3) == 0)
				{
					const uint8_t f8 = *(uint8_t*)(e + 8), f9 = *(uint8_t*)(e + 9), fa = *(uint8_t*)(e + 0xA);
					if (!r.found) { r.found = true; r.itA = a; r.itB = bb; r.f8 = f8; r.f9 = f9; r.fa = fa; r.key = *(unsigned*)(e + 0xC); }
					else if (r.itA != a || r.itB != bb || r.f8 != f8 || r.fa != fa) ++r.conflicts;
					++r.matches;
				}
				e = *(uintptr_t*)(e + 0x18);
			}
	}
	__except (EXCEPTION_EXECUTE_HANDLER) { r = HFRec(); r.matches = -7; }
	return r;
}

// read-only scan of the attach matrix table (+0x2CFB60's hash); returns the entry (its first 0x40 bytes = matrix)
uintptr_t FindMtx(int point, int variant, const char* rt)
{
	__try
	{
		const uintptr_t m = S.game.base + kRvaHFMgr;
		uintptr_t b = *(uintptr_t*)(m + 0x18); unsigned n = *(unsigned*)(m + 0x20);
		if (!HeapPtr8(b) || n == 0 || n > 4000000) return 0;
		int guard = 0;
		for (unsigned i = 0; i < n && guard < 4000000; ++i)
			for (uintptr_t e = ((uintptr_t*)b)[i]; e && guard < 4000000; ++guard)
			{
				if (!HeapPtr8(e)) return 0;
				if (*(int*)(e + 0x40) == point && *(int*)(e + 0x44) == variant && memcmp((const void*)(e + 0x48), rt, 3) == 0) return e;
				e = *(uintptr_t*)(e + 0x50);
			}
	}
	__except (EXCEPTION_EXECUTE_HANDLER) { return 0; }
	return 0;
}

// body skin region bytes live in the body's sprite instance ([body+0x110]->vft[0x88]() = [body+0x1E8])
uintptr_t ReadSprite(uintptr_t body)
{
	__try
	{
		uintptr_t svt = *(uintptr_t*)(body + kOffSub);
		if (!InModule(S.gfx, svt, 0x90) || *(uintptr_t*)(svt + 0x88) != S.gfx.base + kFnSubGet) return 0;
		uintptr_t sp = *(uintptr_t*)(body + kOffSprite);
		if (!HeapPtr8(sp)) return 0;
		uintptr_t vt = *(uintptr_t*)sp;
		if (!InModule(S.gfx, vt, 0x80) || *(uintptr_t*)(vt + 0x78) != S.gfx.base + kFnSprSetRegion) return 0;
		return sp;
	}
	__except (EXCEPTION_EXECUTE_HANDLER) { return 0; }
}
int ReadCell(uintptr_t sp, int layer, int r)
{
	__try { return *(uint8_t*)(sp + (layer ? kOffRegion1 : kOffRegion0) + r); }
	__except (EXCEPTION_EXECUTE_HANDLER) { return -1; }
}
int CallSetRegion(uintptr_t body, int r, bool hide, int layer, DWORD* code)
{
	__try
	{
		SetRegionFn fn = (SetRegionFn)(*(uintptr_t**)body)[kSlotSetRegion / 8];
		fn((void*)body, r, hide, layer != 0);
	}
	__except (*code = GetExceptionCode(), EXCEPTION_EXECUTE_HANDLER) { return -1; }
	return 0;
}

// another point of the same slot we still own (inherits region cells), -1 none
int CellHeir(int owner)
{
	int side; const int slot = PointSlot(owner, &side);
	if (slot < 0) return -1;
	for (int q = 0; q < kNumPoints; ++q)
	{
		int s2; if (q == owner || !S.pt[q].ours || S.pt[q].compOf >= 0) continue;
		if (PointSlot(q, &s2) == slot) return q;
	}
	return -1;
}
// put back every skin region cell `owner` changed (only if it still holds what we wrote)
bool RevertCells(uintptr_t body, int owner, bool forgetOnly)
{
	const uintptr_t sp = forgetOnly ? 0 : ReadSprite(body);
	for (int l = 0; l < 2; ++l)
		for (int r = 0; r < kNumRegions; ++r)
		{
			Cell& c = S.cell[l][r];
			if (!c.touched || c.owner != owner) continue;
			if (!forgetOnly) { const int h = CellHeir(owner); if (h >= 0) { c.owner = h; continue; } }
			if (sp)
			{
				const int cur = ReadCell(sp, l, r);
				if (cur == c.wrote && cur != c.orig)
				{
					DWORD code = 0;
					if (CallSetRegion(body, r, c.orig != 0, l, &code) != 0) { Fault("SetRegion restore", code); return false; }
				}
			}
			c = Cell();
		}
	return true;
}

bool TakeOriginal(PointState& ps, uintptr_t body, int point, uintptr_t cur, const char* ctag)
{   // first change at this point: remember the original piece (tag, tints, attach matrix)
	ps = PointState();
	char norm[kTagMax] = "";
	if (cur)
	{
		if (!NormalizeTag(ctag, norm, sizeof(norm)))
		{
			char raw[420]; RawPointInfo(body, point, raw, sizeof(raw));
			// fallback for pair points: stock left/right pieces are ITn / ITn+1 (12/13 IT8127/8126, 21/22 IT9126/9127,
			// 27 IT7126). Use the partner's original +-1, only if that definition is already loaded.
			int side = 0, slot = PointSlot(point, &side), partner = -1;
			switch (point) { case 26: partner = 27; break; case 27: partner = 26; break; case 12: partner = 13; break; case 13: partner = 12; break;
				case 18: partner = 19; break; case 19: partner = 18; break; case 21: partner = 22; break; case 22: partner = 21; break; }
			(void)slot;
			char ptag[kTagMax] = "", guess[kTagMax] = "";
			if (partner >= 0)
			{
				if (S.pt[partner].ours && S.pt[partner].body == body) strncpy(ptag, S.pt[partner].origTag, sizeof(ptag) - 1);
				else { uintptr_t pa; ReadPoint(body, partner, &pa, nullptr, 0, ptag, sizeof(ptag)); }
				if (_strnicmp(ptag, "IT", 2) == 0 && isdigit((unsigned char)ptag[2]))
				{
					// point 26/12/18/22 is side 1 in the game's table except feet (21 side 0, 22 side 1)
					const int n = atoi(ptag + 2) + (side == 1 ? 1 : -1);
					snprintf(guess, sizeof(guess), "IT%d", n);
					char full[kTagMax + 16]; snprintf(full, sizeof(full), "%s_ACTORDEF", guess);
					if (IsLoaded(full) != 1) guess[0] = 0;
				}
			}
			if (!guess[0] || !NormalizeTag(guess, norm, sizeof(norm)))
			{
				Log("set %d: original tag '%s' unreadable, refusing; partner %d '%s'; raw %s", point, ctag, partner, ptag, raw);
				return false;
			}
			Log("set %d: original tag unreadable, using partner-derived %s (partner %d %s, loaded); raw %s", point, norm, partner, ptag, raw);
		}
		if (IsRemapped(norm) != 0) { Log("set %d: original %s is in the remap table, restore would differ, refusing", point, norm); return false; }
		int n = Mat_ReadPalette(cur, ps.pal, kPalMax);
		ps.palCount = n > 0 ? n : 0;
		__try
		{
			ps.origMtxOn = *(uint8_t*)(cur + kOffActMtxOn) != 0;
			if (ps.origMtxOn) memcpy(ps.origMtx, (const void*)(cur + kOffActMtx), sizeof(ps.origMtx));
		}
		__except (EXCEPTION_EXECUTE_HANDLER) { ps.origMtxOn = false; }
	}
	strcpy(ps.origTag, norm);
	ps.body = body;
	return true;
}

void DoRestore(uintptr_t body, int point, const char* why);

// after a successful set at `point`: do what +0x98890 does for a HeroForge piece besides the first attach
void ApplyExtras(uintptr_t body, int point, const HFRec& rec, const PlayerHF& pi, bool havePi)
{
	int side; const int slot = PointSlot(point, &side);
	PointState& ps = S.pt[point];
	// (2) skin regions
	bool want[2][kNumRegions] = {}, use[2][kNumRegions] = {};
	if (rec.found && havePi && (S.opts & kOptRegions) && slot >= 0 && slot < kNumRegions)
	{
		const bool fa = rec.fa != 0;
		if (point == kChestPoint)
		{
			const int b0 = pi.race != 3 ? 1 : 0, b1 = pi.race == 0x14A ? 3 : 6;
			for (int b = b0; b <= b1 && b < kNumRegions; ++b) if (b != 4 && b != 6) { use[1][b] = true; want[1][b] = fa && Robe(pi); }
		}
		// bit 8 (test) never applies to hands: user-proven (chestfix4, opts 15) that HF hand pieces on 18/19 draw
		// nothing for this race, so hiding region 4 removes the hands. The game itself hides it only if fa.
		const bool force = (S.opts & kOptForceSkin) && slot != 4;
		use[0][slot] = true; want[0][slot] = (fa || force) && !Robe(pi);
	}
	int changed = 0;
	const uintptr_t sp = ReadSprite(body);
	for (int l = 0; l < 2 && sp; ++l)
		for (int r = 0; r < kNumRegions; ++r)
		{
			Cell& c = S.cell[l][r];
			if (!use[l][r]) continue;
			const int cur = ReadCell(sp, l, r);
			if (cur < 0) continue;
			if (cur == (int)want[l][r] && !c.touched) continue;     // already what the game would have
			if (!c.touched) { c.touched = true; c.orig = (uint8_t)cur; c.owner = point; }
			if (cur != (int)want[l][r])
			{
				DWORD code = 0;
				if (CallSetRegion(body, r, want[l][r], l, &code) != 0) { Fault("SetRegion", code); return; }
				++changed;
			}
			c.wrote = want[l][r];
		}
	// cells this point changed earlier that the new piece does not want any more
	for (int l = 0; l < 2; ++l)
		for (int r = 0; r < kNumRegions; ++r)
		{
			Cell& c = S.cell[l][r];
			if (!c.touched || c.owner != point || use[l][r]) continue;
			if (sp) { const int cur = ReadCell(sp, l, r); DWORD code = 0;
				if (cur == c.wrote && cur != c.orig && CallSetRegion(body, r, c.orig != 0, l, &code) != 0) { Fault("SetRegion restore", code); return; } }
			c = Cell();
		}
	// (1) second point: chest -> 7 = itB (+0x9909A); helm -> 8 (hair) detached when the record's f9 == 0
	// (+0x99336..+0x993BF: race != 0x82, hair point and helm point attached, !f9 -> CBA(8, "0") = remove hair)
	char comp[48] = "-";
	const int kCompPt = point == kChestPoint ? kChestSecond : (point == kHelmPoint ? kHairPoint : -1);
	if (kCompPt >= 0)
	{
		PointState& cs = S.pt[kCompPt];
		const bool wantComp = rec.found && (S.opts & kOptCompanion) && (point == kChestPoint || (rec.f9 == 0 && havePi && pi.race != 0x82));
		if (wantComp)
		{
			char target[kTagMax] = "";
			if (point == kChestPoint && rec.itB) snprintf(target, sizeof(target), "IT%u", rec.itB);
			uintptr_t cur = 0; char pname[48], ctag[kTagMax], cnorm[kTagMax] = "";
			if (ReadPoint(body, kCompPt, &cur, pname, sizeof(pname), ctag, sizeof(ctag)) == 0)
			{
				if (cur) NormalizeTag(ctag, cnorm, sizeof(cnorm));
				const bool same = target[0] ? (cur && _stricmp(cnorm, target) == 0) : (cur == 0);
				if (same) snprintf(comp, sizeof(comp), "%d already %s", kCompPt, target[0] ? target : "empty");
				else
				{
					bool ok = true;
					if (!cs.ours || cs.body != body || cur != cs.mine) ok = TakeOriginal(cs, body, kCompPt, cur, ctag);
					if (ok)
					{
						const void* m2 = nullptr;
						if ((S.opts & kOptMatrix) && rec.f8 == 0 && havePi && target[0]) m2 = (const void*)FindMtx(kCompPt, 0, pi.tag);
						uintptr_t res = 0; DWORD code = 0;
						if (CallCBA(body, kCompPt, target[0] ? target : nullptr, m2, &res, &code) != 0) { Fault("ChangeBoneAttachment companion", code); return; }
						cs.ours = true; cs.mine = res; cs.compOf = point;
						strncpy(cs.myTag, target[0] ? target : "(empty)", sizeof(cs.myTag) - 1);
						snprintf(comp, sizeof(comp), "%d %s->%s%s", kCompPt, cs.origTag[0] ? cs.origTag : "(empty)", target[0] ? target : "(empty)", (target[0] && !res) ? "(load failed)" : "");
					}
					else snprintf(comp, sizeof(comp), "%d refused", kCompPt);
				}
			}
		}
		else if (cs.ours && cs.compOf == point) { DoRestore(body, kCompPt, "piece needs no second point"); snprintf(comp, sizeof(comp), "%d restored", kCompPt); }
	}
	if (rec.found)
		snprintf(ps.hf, sizeof(ps.hf), "hf id=%u A=%u B=%u f8=%u f9=%u fa=%u n=%d%s regions+%d %s", rec.key, rec.itA, rec.itB, rec.f8, rec.f9, rec.fa, rec.matches, rec.conflicts ? "(conflict)" : "", changed, comp);
	else snprintf(ps.hf, sizeof(ps.hf), "no hf record (n=%d) %s", rec.matches, comp);
}

void DoSet(uintptr_t body, int point, const char* tag)
{
	PointState& ps = S.pt[point];
	uintptr_t cur = 0; char pname[48], ctag[kTagMax];
	if (ReadPoint(body, point, &cur, pname, sizeof(pname), ctag, sizeof(ctag)) != 0) { Log("set %d: no verified attach point", point); return; }
	if (!ps.ours || ps.body != body)
	{
		if (!TakeOriginal(ps, body, point, cur, ctag)) return;
	}
	else if (cur != ps.mine)
	{   // the game replaced our piece itself (wear change): treat the current piece as the new original
		Log("set %d: piece changed by the game since our swap; taking it as the new original", point);
		RevertCells(body, point, true);        // the game recomputed the regions itself
		ps.ours = false;
		DoSet(body, point, tag);
		return;
	}
	// HeroForge record for this IT (read-only) -> attach matrix like +0x98FBB
	HFRec rec; PlayerHF pi; bool havePi = false; const void* mtx = nullptr;
	int side; const int slot = PointSlot(point, &side);
	if (S.hfOk == 1 && slot >= 0 && _strnicmp(tag, "IT", 2) == 0 && isdigit((unsigned char)tag[2]) && (havePi = ReadPlayerHF(&pi)))
	{
		rec = FindHF((unsigned)atoi(tag + 2), side, pi.tag);
		if (rec.found && (S.opts & kOptMatrix) && rec.f8 == 0) mtx = (const void*)FindMtx(point, (Robe(pi) && point == kChestPoint) ? 1 : 0, pi.tag);
	}
	char full[kTagMax + 16]; snprintf(full, sizeof(full), "%s_ACTORDEF", tag);
	const int loaded = IsLoaded(full), remap = IsRemapped(tag);
	uintptr_t res = 0; DWORD code = 0;
	if (CallCBA(body, point, tag, mtx, &res, &code) != 0) { Fault("ChangeBoneAttachment", code); return; }
	ps.ours = true; ps.mine = res;
	strncpy(ps.myTag, tag, sizeof(ps.myTag) - 1);
	if (!res)
	{   // engine could not resolve the definition: it detached the old piece. Put the original back right away.
		Log("set %d %s: engine returned 0 (definition not found/loadable; loaded=%d remap=%d) -> restoring %s", point, tag, loaded, remap, ps.origTag[0] ? ps.origTag : "(empty)");
		DoRestore(body, point, "set failed");
		return;
	}
	if (S.hfOk == 1) ApplyExtras(body, point, rec, pi, havePi);
	else snprintf(ps.hf, sizeof(ps.hf), "hf emulation off (%s)", S.hfWhy);
	if (S.disabled) return;
	Log("set %d (%s) %s -> %s actor=%p (loaded before=%d remap=%d) mtx=%p %s", point, pname, ps.origTag[0] ? ps.origTag : "(empty)", tag, (void*)res, loaded, remap, mtx, ps.hf);
}

void RestoreCompanion(uintptr_t body, int point, const char* why)
{
	const int c = point == kChestPoint ? kChestSecond : (point == kHelmPoint ? kHairPoint : -1);
	if (c >= 0 && S.pt[c].ours && S.pt[c].compOf == point) DoRestore(body, c, why);
}

void DoRestore(uintptr_t body, int point, const char* why)
{
	PointState& ps = S.pt[point];
	if (!ps.ours) return;
	if (ps.body != body) { ps = PointState(); return; }
	uintptr_t cur = 0;
	if (ReadPoint(body, point, &cur, nullptr, 0, nullptr, 0) != 0 || cur != ps.mine)
	{
		Log("restore %d (%s): piece is no longer ours (game re-attached), leaving it", point, why);
		RevertCells(body, point, true);
		ps = PointState();
		RestoreCompanion(body, point, why);
		return;
	}
	uintptr_t back = 0; DWORD code = 0;
	const void* mtx = ps.origMtxOn ? (const void*)ps.origMtx : nullptr;
	if (CallCBA(body, point, ps.origTag[0] ? ps.origTag : nullptr, mtx, &back, &code) != 0) { Fault("ChangeBoneAttachment restore", code); return; }
	int tinted = 0;
	for (int i = 0; back && i < ps.palCount; ++i) { int d = Mat_TintActor(back, i, ps.pal[i]); if (d < 0) return; tinted += d; }
	Log("restore %d (%s): %s -> %s actor=%p tints=%d/%d mtx=%d", point, why, ps.myTag, ps.origTag[0] ? ps.origTag : "(empty)", (void*)back, tinted, ps.palCount, ps.origMtxOn ? 1 : 0);
	ps = PointState();
	RestoreCompanion(body, point, why);
	RevertCells(body, point, false);
}

// ---------------------------------------------------------------- matfix: body region material
uintptr_t ReadAc()
{
	__try
	{
		uintptr_t pl = *(uintptr_t*)(S.game.base + kRvaLocalPlayer);
		if (!HeapPtr8(pl) || !InModule(S.game, *(uintptr_t*)pl, 8)) return 0;
		return pl + kOffEqSub;
	}
	__except (EXCEPTION_EXECUTE_HANDLER) { return 0; }
}
bool ReadEquip(uintptr_t ac, int r, int* mat, uint32_t* tint, uint8_t* var, int* p7)
{
	__try
	{
		*mat = *(int*)(ac + kOffEquip + (size_t)r * kEquipStride);
		*var = (uint8_t)*(int*)(ac + kOffEquip + (size_t)r * kEquipStride + 4);
		*tint = *(uint32_t*)(ac + kOffEquipTint + (size_t)r * 4);
		*p7 = *(int*)(ac + kOffAcP7);
	}
	__except (EXCEPTION_EXECUTE_HANDLER) { return false; }
	return true;
}
int CallSetArmorTex(uintptr_t ac, int r, int oldMat, int newMat, uint32_t tint, uint8_t var, int p7, bool hf, bool* ok, DWORD* code)
{
	*ok = false;
	__try
	{
		SetArmorTexFn fn = (SetArmorTexFn)(S.game.base + kFnSetArmorTex);
		*ok = fn((void*)ac, r, oldMat, newMat, (int)tint, var, p7, hf ? 1 : 0);
	}
	__except (*code = GetExceptionCode(), EXCEPTION_EXECUTE_HANDLER) { return -1; }
	++S.calls;
	return 0;
}
bool MatAllowed(int m) { return (m >= 0 && m <= 3) || (m >= 17 && m <= 23); }   // textures proven in globaldwm_chr / global17..23_amr; no robes (10..16)

void DoMatRestore(uintptr_t body, int r, const char* why)
{
	MatState& ms = S.mat[r];
	if (!ms.ours) return;
	const uintptr_t ac = ReadAc();
	int cur = 0, p7 = 0; uint32_t tint = 0; uint8_t var = 0;
	if (!ac || ms.body != body || !ReadEquip(ac, r, &cur, &tint, &var, &p7)) { ms = MatState(); return; }
	if (cur != ms.myMat) { Log("mat restore %d (%s): material is %d now, not ours (%d), leaving it", r, why, cur, ms.myMat); ms = MatState(); return; }
	bool ok = false; DWORD code = 0;
	if (CallSetArmorTex(ac, r, cur, ms.origMat, ms.origTint, ms.var, p7, false, &ok, &code) != 0) { Fault("SetArmorTexture restore", code); return; }
	int after = -1; ReadEquip(ac, r, &after, &tint, &var, &p7);
	Log("mat restore %d (%s): %d -> %d ok=%d now=%d", r, why, cur, ms.origMat, ok ? 1 : 0, after);
	ms = MatState();
}

void DoMat(uintptr_t body, int r, int m)
{
	if (S.matOk != 1) { Log("mat %d: off (%s)", r, S.matWhy); return; }
	if (m < 0) { DoMatRestore(body, r, "requested"); return; }
	MatState& ms = S.mat[r];
	const uintptr_t ac = ReadAc();
	int cur = 0, p7 = 0; uint32_t tint = 0; uint8_t var = 0;
	if (!ac || !ReadEquip(ac, r, &cur, &tint, &var, &p7)) { Log("mat %d: no player", r); return; }
	if (ms.ours && (ms.body != body || cur != ms.myMat)) ms = MatState();     // game changed it: current is the new original
	if (!ms.ours) { ms.origMat = cur; ms.origTint = tint; ms.var = var; ms.body = body; }
	if (cur == m && ms.ours) return;
	bool ok = false; DWORD code = 0;
	if (CallSetArmorTex(ac, r, cur, m, tint, var, p7, true, &ok, &code) != 0) { Fault("SetArmorTexture", code); return; }
	int after = -1; uint32_t t2 = 0; uint8_t v2 = 0; int p72 = 0; ReadEquip(ac, r, &after, &t2, &v2, &p72);
	if (after == m) { ms.ours = true; ms.myMat = m; }
	else if (!ms.ours) ms = MatState();
	Log("mat %d: %d -> %d ok=%d now=%d (orig %d tint %08X)", r, cur, m, ok ? 1 : 0, after, ms.ours ? ms.origMat : cur, tint);
}

// zone / body rebuild: the game rebuilds the body from ActorEquipment, so put the original material + tint values back
// first (memory only, no texture call: the old body is going away)
void ForgetMats()
{
	const uintptr_t ac = ReadAc();
	for (int r = 0; r < kNumRegions; ++r)
	{
		MatState& ms = S.mat[r];
		if (ms.ours && ac)
			__try
			{
				int* pm = (int*)(ac + kOffEquip + (size_t)r * kEquipStride);
				if (*pm == ms.myMat) { *pm = ms.origMat; *(uint32_t*)(ac + kOffEquipTint + (size_t)r * 4) = ms.origTint; }
			}
			__except (EXCEPTION_EXECUTE_HANDLER) {}
		ms = MatState();
	}
}

void ForgetAll() { ForgetMats(); for (auto& p : S.pt) p = PointState(); for (auto& l : S.cell) for (auto& c : l) c = Cell(); S.nq = 0; }

} // namespace

bool Orn_Available() { return EnsureVerified() && Mat_Available(); }

void Orn_Pulse(bool zoning)
{
	if (S.verified != 1 || S.disabled) return;
	if (zoning) { ForgetAll(); return; }
	uintptr_t body;
	S.live = ReadBody(&body);
	if (S.live == 7) { Fault("read", 0); return; }
	if (S.live != 0) { S.body = 0; return; }
	if (S.body && body != S.body) { for (auto& m : S.mat) m = MatState(); ForgetAll(); }   // body actor rebuilt: EQ re-attached the real gear (built from current ActorEquipment: mats not written back)
	S.body = body;
	for (int k = 0; k < S.nq && !S.disabled; ++k)
	{
		const Req& r = S.q[k];
		if (r.op == kSet) DoSet(body, r.point, r.tag);
		else if (r.op == kMat) DoMat(body, r.point, atoi(r.tag));
		else if (r.point < 0) { for (int i = 0; i < kNumPoints && !S.disabled; ++i) DoRestore(body, i, "requested"); for (int m = 1; m < kNumRegions && !S.disabled; ++m) DoMatRestore(body, m, "requested"); }
		else DoRestore(body, r.point, "requested");
	}
	S.nq = 0;
}

void Orn_BeginZone() { ForgetAll(); }

void Orn_Shutdown()
{
	if (S.verified != 1 || S.disabled) return;
	uintptr_t body;
	if (ReadBody(&body) != 0) return;
	for (int i = 0; i < kNumPoints && !S.disabled; ++i) DoRestore(body, i, "unload");
	for (int m = 1; m < kNumRegions && !S.disabled; ++m) DoMatRestore(body, m, "unload");
}

int Orn_Mat(int region, int material)
{
	if (!Orn_Available()) return S.disabled ? -1 : -2;
	if (S.matOk != 1) return -5;
	if (region < 1 || region > 6) return -3;
	if (material >= 0 && !MatAllowed(material)) return -3;
	if (S.nq >= (int)(sizeof(S.q) / sizeof(S.q[0]))) return -4;
	Req& r = S.q[S.nq++]; r.op = kMat; r.point = region; snprintf(r.tag, sizeof(r.tag), "%d", material < 0 ? -1 : material);
	return S.nq;
}

int Orn_Set(int point, const char* tag)
{
	if (!Orn_Available()) return S.disabled ? -1 : -2;
	if (point < 0 || point >= kNumPoints) return -3;
	char norm[kTagMax];
	if (!NormalizeTag(tag, norm, sizeof(norm))) return -3;
	if (S.nq >= (int)(sizeof(S.q) / sizeof(S.q[0]))) return -4;
	Req& r = S.q[S.nq++]; r.op = kSet; r.point = point; strcpy(r.tag, norm);
	return S.nq;
}

int Orn_Restore(int point)
{
	if (!EnsureVerified()) return S.disabled ? -1 : -2;
	if (point < -1 || point >= kNumPoints) return -3;
	if (S.nq >= (int)(sizeof(S.q) / sizeof(S.q[0]))) return -4;
	Req& r = S.q[S.nq++]; r.op = kRestore; r.point = point; r.tag[0] = 0;
	return S.nq;
}

int Orn_Loaded(const char* tag)
{
	if (!EnsureVerified()) return -2;
	char norm[kTagMax];
	if (!NormalizeTag(tag, norm, sizeof(norm))) return -3;
	char full[kTagMax + 16]; snprintf(full, sizeof(full), "%s_ACTORDEF", norm);
	return IsLoaded(full);
}

const char* Orn_Status()
{
	EnsureVerified();
	char pts[2200] = ""; size_t m = 0;
	uintptr_t body = 0;
	if (S.verified == 1 && !S.disabled && ReadBody(&body) == 0)
		for (int i = 0; i < kNumPoints && m < sizeof(pts) - 120; ++i)
		{
			uintptr_t a; char pn[48], tg[kTagMax];
			if (ReadPoint(body, i, &a, pn, sizeof(pn), tg, sizeof(tg)) == 1) continue;
			m += snprintf(pts + m, sizeof(pts) - m, " %d:%s:%s%s", i, pn[0] ? pn : "-", a ? (tg[0] ? tg : "?") : "(empty)",
				S.pt[i].ours ? (S.pt[i].origTag[0] ? "*" : "*was-empty") : "");
			if (S.pt[i].ours && S.pt[i].origTag[0]) m += snprintf(pts + m, sizeof(pts) - m, "(orig %s)", S.pt[i].origTag);
		}
	char mats[200] = ""; size_t mm = 0;
	const uintptr_t ac = (S.verified == 1 && !S.disabled) ? ReadAc() : 0;
	for (int r = 1; r < kNumRegions && ac; ++r)
	{
		int cur = 0, p7 = 0; uint32_t t = 0; uint8_t v = 0;
		if (!ReadEquip(ac, r, &cur, &t, &v, &p7)) break;
		mm += snprintf(mats + mm, sizeof(mats) - mm, " %d:%d%s", r, cur, S.mat[r].ours ? "*" : "");
		if (S.mat[r].ours) mm += snprintf(mats + mm, sizeof(mats) - mm, "(orig %d)", S.mat[r].origMat);
	}
	snprintf(S.status, sizeof(S.status), "verified=%d(%s) disabled=%d live=%d body=%p calls=%d queued=%d mat=%d(%s) mats{region:material *=ours}=[%s ] points{idx:name:model *=ours}=[%s ] last=%s",
		S.verified, S.verifyWhy, S.disabled ? 1 : 0, S.live, (void*)body, S.calls, S.nq, S.matOk, S.matWhy, mats, pts, S.last);
	return S.status;
}

unsigned Orn_Opts(int mask)
{
	const unsigned prev = S.opts;
	if (mask >= 0) S.opts = (unsigned)mask & kOptAll;
	return prev;
}

// read-only: everything the chestfix decisions are based on, for one-line checks from Lua
const char* Orn_Diag()
{
	EnsureVerified();
	size_t m = 0; char* o = S.diag; const size_t cap = sizeof(S.diag);
	auto add = [&](const char* fmt, auto... a) { if (m < cap) { int k = snprintf(o + m, cap - m, fmt, a...); if (k > 0) m += (size_t)k; if (m >= cap) m = cap - 1; } };
	add("hf=%d(%s) opts=%u", S.hfOk, S.hfWhy, S.opts);
	uintptr_t body = 0;
	if (S.verified != 1 || S.disabled || ReadBody(&body) != 0) { add(" body=none"); return S.diag; }
	PlayerHF pi; const bool havePi = ReadPlayerHF(&pi);
	if (havePi) add(" player{chestMat=%d robe=%d race=%d gender=%d tag=%s}", pi.v + 10, Robe(pi) ? 1 : 0, pi.race, pi.gender, pi.tag);
	uintptr_t b68 = 0;
	__try { b68 = *(uintptr_t*)(body + 0x68); } __except (EXCEPTION_EXECUTE_HANDLER) { b68 = 1; }
	add(" body=%p b68=%p", (void*)body, (void*)b68);
	const uintptr_t sp = ReadSprite(body);
	add(" sprite=%p", (void*)sp);
	if (sp)
	{
		add(" regions L0=");
		for (int r = 0; r < kNumRegions; ++r) add("%d", ReadCell(sp, 0, r));
		add(" L1=");
		for (int r = 0; r < kNumRegions; ++r) add("%d", ReadCell(sp, 1, r));
	}
	add(" cells[");
	for (int l = 0; l < 2; ++l) for (int r = 0; r < kNumRegions; ++r)
	{
		const Cell& c = S.cell[l][r];
		if (c.touched) add(" L%d.%d:%u->%u@%d", l, r, c.orig, c.wrote, c.owner);
	}
	add(" ] pts[");
	for (int i = 0; i < kNumPoints; ++i)
	{
		int side; const int slot = PointSlot(i, &side);
		if (slot < 0 && !S.pt[i].ours) continue;
		uintptr_t a = 0; char pn[48], tg[kTagMax];
		if (ReadPoint(body, i, &a, pn, sizeof(pn), tg, sizeof(tg)) != 0) continue;
		int mon = -1;
		if (a) { __try { mon = *(uint8_t*)(a + kOffActMtxOn); } __except (EXCEPTION_EXECUTE_HANDLER) { mon = -7; } }
		add(" %d:%s:%s mtx=%d", i, pn[0] ? pn : "-", a ? (tg[0] ? tg : "?") : "(empty)", mon);
		if (a && !tg[0]) { char raw[420]; RawPointInfo(body, i, raw, sizeof(raw)); add(" {raw %s}", raw); }
		const PointState& ps = S.pt[i];
		if (ps.ours) add(" *orig=%s%s%s", ps.origTag[0] ? ps.origTag : "(empty)", ps.origMtxOn ? "+mtx" : "", ps.compOf >= 0 ? "(2nd)" : "");
		if (ps.hf[0]) add(" {%s}", ps.hf);
		if (a && tg[0] && havePi && S.hfOk == 1 && slot >= 0)
		{
			char norm[kTagMax];
			if (NormalizeTag(tg, norm, sizeof(norm)) && _strnicmp(norm, "IT", 2) == 0 && isdigit((unsigned char)norm[2]))
			{
				HFRec r = FindHF((unsigned)atoi(norm + 2), side, pi.tag);
				if (r.found) add(" [hf id=%u A=%u B=%u f8=%u f9=%u fa=%u n=%d c=%d]", r.key, r.itA, r.itB, r.f8, r.f9, r.fa, r.matches, r.conflicts);
				else add(" [no hf n=%d]", r.matches);
			}
		}
	}
	add(" ]");
	return S.diag;
}
