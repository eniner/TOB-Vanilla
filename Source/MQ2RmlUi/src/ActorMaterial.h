// Client-side material tint on the LOCAL player's own actor and its attached armour actors (proof test).
// Calls only EQGraphics' own CActor::SetMaterialTint(int index, const RGB*) (vftable slot 0x228) of each
// actor; never touches server-sent data. Requests are queued by the exports and run in OnPulse (game thread).
#pragma once
#include <cstdint>

void Mat_Pulse(bool zoning);       // game thread, every OnPulse
void Mat_BeginZone();              // actors are about to be rebuilt: forget the snapshots
void Mat_Shutdown();               // ShutdownPlugin: restore original tints if the actors are unchanged
bool Mat_Available();              // exact client build + EQGraphics signatures verified, not disabled
int  Mat_Tint(int index, uint32_t argb);     // body: one material index of the palette
int  Mat_TintAll(uint32_t argb);             // body: every material index
int  Mat_TintSlot(int slot, uint32_t argb);  // body: indices whose original tint == ActorClient.ArmorColor[slot]
int  Mat_TintAttach(int attach, int index, uint32_t argb);  // attached actor at attach point 0..27
int  Mat_TintAttachAll(int attach, uint32_t argb);
int  Mat_AttachFind(const char* text);       // first attach point whose point/def name contains text (case-insens.), -1 none
int  Mat_Reset();                            // restore body + every attachment to the snapshots
const char* Mat_Status();                    // one line, for logs / Lua
// helpers for OrnamentSwap (game thread, SEH inside): palette of a verified actor class (M/A/B)
int  Mat_ReadPalette(uintptr_t actor, uint32_t* out, int cap);   // count (> 0) or < 0 if not a verified class
int  Mat_TintActor(uintptr_t actor, int index, uint32_t argb);   // 1 ok, 0 skipped, -1 fault (feature disabled)
