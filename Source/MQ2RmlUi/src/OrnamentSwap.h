// Client-side model swap of the piece attached at one of the LOCAL player's body attach points (proof test).
// Uses only EQGraphics' own CActor::ChangeBoneAttachment(int point, const char* tag, const CMatrix44*) (body
// vftable slot 0x270), the same call eqgame makes on a wear change (eqgame+0x3070FD: [pl+0x1170]->vft[0x270](
// point, "IT%u", 0)). No network, no server data. Requests are queued and run in OnPulse (game thread).
#pragma once
#include <cstdint>

void Orn_Pulse(bool zoning);       // game thread, every OnPulse
void Orn_BeginZone();              // actors are rebuilt on zone: forget everything (EQ re-attaches the real gear)
void Orn_Shutdown();               // ShutdownPlugin: restore every point we changed (game thread)
bool Orn_Available();
int  Orn_Set(int point, const char* tag);    // tag "IT14118" or "IT14118_ACTORDEF"; queue; > 0 ok, < 0 error
int  Orn_Restore(int point);                 // -1 = all
int  Orn_Loaded(const char* tag);            // read-only: 1 definition already in the resource table, 0 not, < 0 error
const char* Orn_Status();
// chestfix: HeroForge wear emulation switches (1 = chest second point 7, 2 = body skin regions, 4 = attach matrix;
// default 7 = all three; 8 = test: hide the slot skin even when the record says fa=0); mask < 0 only reads. Returns the previous mask. Applies to the next rml_orn_set.
unsigned Orn_Opts(int mask);
const char* Orn_Diag();            // read-only one-line report (player tag/v, skin regions, points, HF records)
// matfix: body region (1 CH 2 UA 3 FA 4 HN 5 LG 6 FT) material swap via eqgame's own SetArmorTexture (+0x9B9F0);
// material 0..3 or 17..23, -1 = restore. Queued, > 0 ok; -5 = function not verified on this build.
int  Orn_Mat(int region, int material);
