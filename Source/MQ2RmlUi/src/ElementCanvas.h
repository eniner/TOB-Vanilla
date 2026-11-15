#pragma once

#include <RmlUi/Core/Context.h>
#include <RmlUi/Core/Element.h>

// Custom <canvas> element + Lua FFI rml_canvas_* API.
// Drawn during Element::OnRender into the document's DX11 RT so z-order,
// clipping, move and collapse stay correct.

void RegisterCanvasElement();
void Canvas_SetFindElement(Rml::Element* (*fn)(const char* window, const char* id));
void Canvas_OnLostDevice();
bool Canvas_ContextWantsPaint(Rml::Context* ctx);
void Canvas_PulseWorldToScreenLog();
void Canvas_SetPaintTarget(const char* win, void* tex, void* rtv, int w, int h);
void Canvas_RequestProbe();
void Canvas_Log(const char* line); // one line to Logs\rmlui_canvas.log
// Stage 1 fx: canvas element for (window, id) as an opaque key (+ its Rml context), nullptr if none
const void* Canvas_Resolve(const char* win, const char* id, const void** outCtx);
