// Native EQ nimbus on the local player (client-side only): calls the client's own OP_AddNimbusEffect /
// OP_RemoveNimbusEffect handlers. Off until rml_nimbus_add is called; everything runs in OnPulse.
#pragma once
#include <cstdint>

void Nimbus_Pulse(bool zoning);          // game thread, every OnPulse (also while zoning)
void Nimbus_BeginZone();                 // OnBeginZone: take ours off while the actor still exists
void Nimbus_Shutdown();                  // ShutdownPlugin: remove ours (game thread)
bool Nimbus_Available();                 // build verified (exact eqgame/EQGraphics match) and not disabled
int  Nimbus_Add(int effectId, int flags);  // queue; > 0 handle, < 0 error (see NativeNimbus.cpp)
int  Nimbus_Remove(int handleOrId);        // queue removal of ours (0 = whatever is active)
const char* Nimbus_Status();             // one line, for logs / Lua (slot 0)
// aura rework: same client call, independent slots (0 = Body FX nimbus, 1 = ground aura). -4 bad slot, -5 id in the other slot
int  Nimbus_AddSlot(int slot, int effectId, int flags);
int  Nimbus_RemoveSlot(int slot);
const char* Nimbus_StatusSlot(int slot);
// proc burst (feature 65536): one short native effect on any spawn (spawnId 0 = you), removed after ms (300..8000).
// > 0 queued; -1 disabled, -2 not verified, -3 bad id, -5 that id is worn on you in slot 0/1, -6 bad spawn id
int  Nimbus_Burst(uint32_t spawnId, int effectId, int ms);
// flags 1 = preview: when the target cannot take it, play it on you instead (status fell=1)
int  Nimbus_BurstEx(uint32_t spawnId, int effectId, int ms, int flags);
int  Nimbus_BurstStop();
const char* Nimbus_BurstStatus();
// t468 custom proc effects (feature 131072): ids CustomFx::kBaseId + 1 .. + kEffects play through Nimbus_Burst / _BurstEx
// (-7 = custom effects off). Available = client verified + the three extra signatures match.
bool Nimbus_CustomAvailable();
bool Nimbus_LevelBypass();               // t472: our effects ignore EQ's Spell Particle Density / Opacity (feature 524288)
int Nimbus_CustomTune(int brightPct, int sizePct);   // t469: Proc FX Brightness / Size (percent) for the custom records (+ stock layering >= 150)
const char* Nimbus_CustomInfo();          // "tag=.. base_id=.. count=.. ready=.. base=.. why=.."

