// Native nimbus: client-specific addresses.
//
// Split in two on purpose:
//   (A) Addresses MacroQuest's eqlib already knows. These come from eqlib/offsets/eqgame.h of the eqlib this
//       plugin is built against, so they follow eqlib when MQ updates it.
//   (B) Addresses eqlib does NOT have (the OP_AddNimbusEffect / OP_RemoveNimbusEffect handler bodies, the
//       spellsnew.eff table, CParticleSystem internals). These were reverse-engineered from ONE client build:
//       eqgame.exe "Sep 11 2025 11:54:10" + its EQGraphics.dll. They are never trusted blindly: NativeNimbus.cpp
//       checks the version strings, byte signatures of both handler functions, the EQGraphics kill function and
//       the particle-system vtable slots before the first call, and turns the feature off (rml_nimbus_* return
//       an error, nothing else is affected) if any check fails. On a different client build, update (B) and the
//       signatures in NativeNimbus.cpp, or leave the feature disabled.
#pragma once

#include <mq/Plugin.h>
#include <eqlib/offsets/eqgame.h>

#include <cstddef>
#include <cstdint>

namespace NimbusOffsets {

// ---- (A) from eqlib (RVA = absolute - preferred base) --------------------------------------------------------
constexpr uintptr_t kRvaLocalPlayer = pinstLocalPlayer_x - eqlib::EQGamePreferredAddress;    // pinstLocalPlayer
constexpr uintptr_t kRvaSpawnMgr    = pinstSpawnManager_x - eqlib::EQGamePreferredAddress;   // pinstSpawnManager
constexpr uintptr_t kRvaVerDate     = __ActualVersionDate_x - eqlib::EQGamePreferredAddress; // "Sep 11 2025"
constexpr uintptr_t kRvaVerTime     = __ActualVersionTime_x - eqlib::EQGamePreferredAddress; // "11:54:10"

// PlayerClient field offsets from eqlib's own class layout.
constexpr size_t kOffSpawnId = offsetof(eqlib::PlayerBase, SpawnID);
constexpr size_t kOffActor   = offsetof(eqlib::PlayerZoneClient, mActorClient) + offsetof(eqlib::ActorClient, pActor);

// Version strings the (B) addresses were taken from. Must equal eqlib's expected client, or (B) is meaningless.
constexpr char kExpectedDate[] = "Sep 11 2025";
constexpr char kExpectedTime[] = "11:54:10";

// Proof that switching to eqlib did not change anything for the client this was reverse-engineered on.
// If you rebuild against a newer eqlib, these fire: re-verify (B) for that client before relaxing them.
static_assert(kRvaLocalPlayer == 0xE66228, "eqlib pinstLocalPlayer differs from the RE'd client");
static_assert(kRvaSpawnMgr    == 0xEE4B40, "eqlib pinstSpawnManager differs from the RE'd client");
static_assert(kRvaVerDate     == 0x964B00, "eqlib __ActualVersionDate differs from the RE'd client");
static_assert(kRvaVerTime     == 0x964AF0, "eqlib __ActualVersionTime differs from the RE'd client");
static_assert(kOffSpawnId == 0x168,  "eqlib PlayerBase::SpawnID differs from the RE'd client");
static_assert(kOffActor   == 0x1170, "eqlib mActorClient.pActor differs from the RE'd client");

// ---- (B) signature-checked fallback: not in eqlib ------------------------------------------------------------
// eqgame.exe RVAs (base 0x140000000)
constexpr uintptr_t kRvaAdd         = 0x1E2060;   // ActivateStateFlavorSpellParticleEffect (OP_AddNimbusEffect 0x54b1)
constexpr uintptr_t kRvaRemove      = 0x1E2890;   // OP_RemoveNimbusEffect (0x4e88) body
constexpr uintptr_t kRvaParticleSys = 0xF0E920;   // CParticleSystemInterface* (remove body, vtbl calls)
constexpr uintptr_t kRvaEffTable    = 0xDB63E0;   // SpellEffectNew* table (spellsnew.eff)
constexpr uintptr_t kRvaEffCount    = 0xDB63E8;   // int record count
constexpr uintptr_t kRvaDensity     = 0xEE2A94;   // float pair passed as density/opacity to vtbl[0x30]
// EQGraphics.dll RVAs (base 0x180000000)
constexpr uintptr_t kRvaPsVtbl      = 0x2BEB28;   // CParticleSystem vftable (ctor FUN_18009de70)
constexpr uintptr_t kRvaPsCreate    = 0x09FE50;   // vtbl[0x30] create on list +0x18 (spell emitters)
constexpr uintptr_t kRvaPsKillKey   = 0x0A0650;   // vtbl[0x70] kill emitters whose key (+0xc) matches
// spellsnew.eff record layout
constexpr size_t kRecSize    = 0x10c;                 // SpellEffectNew
constexpr size_t kStage2Emit = 0x40 + 2 * 0x44 + 4;   // Stages[2].Emitters[0]

} // namespace NimbusOffsets
