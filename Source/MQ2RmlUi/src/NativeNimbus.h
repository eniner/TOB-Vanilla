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
