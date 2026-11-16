// MQ2RmlUi - RmlUi (HTML/CSS-style UI with flexbox, transitions and animations) for MacroQuest emu.
//
// Each RmlUi document gets its own Rml::Context, rendered into a D3D11 render target during MQ's
// GraphicsSceneRender callback and presented inside a borderless ImGui window. That is the same
// host model as every RedGuides Lua UI: ImGui owns focus, z-order and "mouse is over UI", and
// we forward those events into Rml.
//
// Frame contract (match mq.imgui.init):
//   OnUpdateImGui  → Begin host window, feed mouse/keys, Context::Update (click events fire)
//   Lua imgui.init → script drains rml_poll and writes DOM (same thread as ImGui widgets)
//   GraphicsSceneRender → paint the RT (Update only if ImGui has not run yet this frame)
//
// Do NOT drive clicks from the script delay loop. Autoclose still uses rml_poll as a heartbeat
// because that is what Lua calls from its imgui callback.
//
// Lua talks to the plugin through the rml_* C exports below via LuaJIT FFI (see lua/rmlui/init.lua).

#include <mq/Plugin.h>   // MacroQuest plugin API (MQ2Main, eqlib, PLUGIN_API)
#include "RenderInterface_DX11.h"
#include "EqIconAtlas.h"
#include "NativeNimbus.h"
#include "ActorMaterial.h"
#include "OrnamentSwap.h"
#include "ElementCanvas.h"
#include "D3D11StateBackup.h"
#include "FxSystem.h"
#include "TextFx.h"

#include "imgui.h"

#include <RmlUi/Core.h>
#include <RmlUi/Debugger.h>
#include <RmlUi/Core/DataModelHandle.h>
#include <RmlUi/Core/DataTypeRegister.h>

#include <windows.h>

#include <chrono>
#include <cstdarg>
#include <deque>
#include <map>
#include <memory>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------------------------
// Plugin identity (checked by MQ's plugin loader)

PreSetup("MQ2RmlUi");
PLUGIN_VERSION(1.0);

static constexpr int kApiVersion = 5;   // 5 = Stage 1 particles (rml_fx_*), additive over 4

enum WindowFlags
{
	RMLWIN_AUTOCLOSE = 1,   // close if the owner stops polling (Lua script ended)
	RMLWIN_CLICKTHROUGH = 2, // never take mouse input
};

static constexpr double kAutoCloseSeconds = 5.0;

// ---------------------------------------------------------------------------------------------

namespace {

double NowSeconds()
{
	static const auto start = std::chrono::steady_clock::now();
	return std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
}

void Chat(const char* format, ...)
{
	char buffer[1024];
	va_list args;
	va_start(args, format);
	vsnprintf(buffer, sizeof(buffer), format, args);
	va_end(args);
	mq::WriteChatf("\at[MQ2RmlUi]\ax %s", buffer);
}

std::string NormalizePath(const char* path)
{
	std::string p = path ? path : "";
	for (char& c : p)
		if (c == '\\') c = '/';

	const bool absolute = (p.size() > 1 && p[1] == ':') || (!p.empty() && p[0] == '/');
	if (!absolute)
	{
		std::string root = mq::gPathMQRoot;
		for (char& c : root)
			if (c == '\\') c = '/';
		p = root + "/lua/" + p;
	}
	return p;
}

std::string EscapeRml(const char* text)
{
	std::string out;
	for (const char* c = text ? text : ""; *c; ++c)
	{
		switch (*c)
		{
		case '&': out += "&amp;"; break;
		case '<': out += "&lt;"; break;
		case '>': out += "&gt;"; break;
		case '"': out += "&quot;"; break;
		default: out += *c; break;
		}
	}
	return out;
}

std::string Sanitize(const std::string& s)
{
	std::string out = s;
	for (char& c : out)
		if (c == '\t' || c == '\n' || c == '\r') c = ' ';
	return out;
}

void AppendUtf8(std::string& out, unsigned int cp)
{
	if (cp < 0x80) out += (char)cp;
	else if (cp < 0x800) { out += (char)(0xC0 | (cp >> 6)); out += (char)(0x80 | (cp & 0x3F)); }
	else if (cp < 0x10000) { out += (char)(0xE0 | (cp >> 12)); out += (char)(0x80 | ((cp >> 6) & 0x3F)); out += (char)(0x80 | (cp & 0x3F)); }
	else { out += (char)(0xF0 | (cp >> 18)); out += (char)(0x80 | ((cp >> 12) & 0x3F)); out += (char)(0x80 | ((cp >> 6) & 0x3F)); out += (char)(0x80 | (cp & 0x3F)); }
}

bool IsTextInput(Rml::Element* e)
{
	if (!e) return false;
	const Rml::String& tag = e->GetTagName();
	if (tag == "textarea" || tag == "select")
		return true;
	if (tag != "input")
		return false;
	// Range/button/checkbox are not text fields; treating them as such made
	// MQ flush EQ DirectInput (WantTextInput) after a seek-slider click.
	const Rml::String type = e->GetAttribute<Rml::String>("type", "text");
	return type != "range" && type != "button" && type != "checkbox" && type != "radio"
		&& type != "submit" && type != "reset" && type != "hidden" && type != "file"
		&& type != "image" && type != "color";
}

// ---------------------------------------------------------------------------------------------

class SystemInterface_MQ : public Rml::SystemInterface
{
public:
	double GetElapsedTime() override { return NowSeconds(); }

	bool LogMessage(Rml::Log::Type type, const Rml::String& message) override
	{
		OutputDebugStringA(("[MQ2RmlUi] " + message + "\n").c_str());
		if (type == Rml::Log::LT_ERROR || type == Rml::Log::LT_ASSERT || type == Rml::Log::LT_WARNING)
		{
			const double now = NowSeconds();
			if (now - m_windowStart > 5.0) { m_windowStart = now; m_count = 0; }
			if (++m_count <= 12)
				Chat("%s%s", type == Rml::Log::LT_WARNING ? "\ay" : "\ar", message.c_str());
		}
		return true;
	}

	void SetClipboardText(const Rml::String& text) override { ImGui::SetClipboardText(text.c_str()); }

	void GetClipboardText(Rml::String& text) override
	{
		const char* c = ImGui::GetClipboardText();
		text = c ? c : "";
	}

private:
	double m_windowStart = 0;
	int m_count = 0;
};

struct RmlWindow;

class DocumentListener : public Rml::EventListener
{
public:
	explicit DocumentListener(RmlWindow* owner) : m_owner(owner) {}
	void ProcessEvent(Rml::Event& event) override;

private:
	RmlWindow* m_owner;
};

// ---------------------------------------------------------------------------------------------
// Lua data models (v3). Values live here; RmlUi reads/writes them through BindFunc getters/setters,
// lists are bound as std::vector<std::vector<String>> (address them as list[i][col] in RML).
struct RmlWindow;
void ModelChanged(RmlWindow* owner, const std::string& model, const std::string& key, const Rml::Variant& value);

using ModelRow = std::vector<Rml::String>;
using ModelList = std::vector<ModelRow>;

struct LuaModel
{
	RmlWindow* owner = nullptr;
	std::string name;
	Rml::DataModelConstructor ctor;
	Rml::DataModelHandle handle;
	std::map<std::string, Rml::Variant> values;
	std::map<std::string, std::unique_ptr<ModelList>> lists;
};

struct RmlWindow
{
	std::string name;
	std::string path;
	int flags = 0;

	Rml::Context* context = nullptr;
	Rml::ElementDocument* document = nullptr;
	std::unique_ptr<DocumentListener> listener;
	bool isDebuggerHost = false;

	bool visible = true;
	float defaultW = 320, defaultH = 240;
	float defaultX = -1, defaultY = -1;
	bool hasPendingRect = false;
	float pendingX = -1, pendingY = -1, pendingW = 0, pendingH = 0;

	// Size of the ImGui content region; the render target follows it.
	int wantW = 0, wantH = 0;
	double lastShown = -100;
	double lastPoll = 0;
	double updatedAt = -100;
	// Focused, hovered, or dragging — only then do we Update/re-paint every frame.
	// Unfocused windows keep their last RT (frozen) so idle UIs stop costing FPS.
	bool interactive = false;
	int lastPaintW = 0, lastPaintH = 0;

	ID3D11Texture2D* rt = nullptr;
	ID3D11ShaderResourceView* rtSrv = nullptr;
	ID3D11RenderTargetView* rtRtv = nullptr;
	ID3D11Texture2D* rtDepthTex = nullptr;
	ID3D11DepthStencilView* rtDsv = nullptr;
	int rtW = 0, rtH = 0;
	bool rendered = false;

	int lastMouseX = -1, lastMouseY = -1;
	bool mouseInside = false;
	int buttonsDown = 0;
	bool wasFocused = false;
	enum class Drag { None, Move, Resize } drag = Drag::None;

	// Window chrome state driven by action="window:*" elements (rmlui/theme/window.rml).
	bool pinned = false;
	bool collapsed = false;
	bool toggleCollapse = false;
	float expandedHeight = 0;
	ImVec2 windowSize = ImVec2(0, 0);
	ImVec2 windowPos = ImVec2(0, 0); // drag patch: last on-screen position, read by rml_get_window

	std::deque<std::string> events;

	// v3: key forwarding (0 off, 1 observe: report keys and still let EQ have them, 2 capture: report
	// keys and keep them from EQ while this window is focused) and Lua data models.
	int keyMode = 0;
	std::unique_ptr<Rml::DataTypeRegister> modelTypes;
	bool modelArraysRegistered = false;
	std::map<std::string, std::unique_ptr<LuaModel>> models;

	void ReleaseTarget()
	{
		if (rtDsv) { rtDsv->Release(); rtDsv = nullptr; }
		if (rtDepthTex) { rtDepthTex->Release(); rtDepthTex = nullptr; }
		if (rtRtv) { rtRtv->Release(); rtRtv = nullptr; }
		if (rtSrv) { rtSrv->Release(); rtSrv = nullptr; }
		if (rt) { rt->Release(); rt = nullptr; }
		rtW = rtH = 0;
		rendered = false;
	}

	void PushEvent(std::string e)
	{
		if (events.size() >= 256)
			events.pop_front();
		events.push_back(std::move(e));
	}
};

void DocumentListener::ProcessEvent(Rml::Event& event)
{
	Rml::Element* target = event.GetTargetElement();
	std::string id, action;
	for (Rml::Element* e = target; e; e = e->GetParentNode())
	{
		if (id.empty() && !e->GetId().empty())
			id = e->GetId();
		if (action.empty())
			action = e->GetAttribute<Rml::String>("action", "");
		if (!id.empty() && !action.empty())
			break;
	}

	const Rml::String& type = event.GetType();
	if ((type == "click" || type == "dblclick" || type == "mousedown") && id.empty() && action.empty())
		return;

	std::string value = event.GetParameter<Rml::String>("value", "");
	if (value.empty() && target && (type == "change" || type == "submit"))
		value = target->GetAttribute<Rml::String>("value", "");

	std::string button;
	if (type == "click" || type == "mousedown" || type == "dblclick")
		button = std::to_string(event.GetParameter<int>("button", 0));

	if (type == "click" && action.rfind("window:", 0) == 0)
	{
		RmlWindow* w = m_owner;
		if (action == "window:close")
		{
			w->visible = false;
		}
		else if (action == "window:collapse")
		{
			w->toggleCollapse = true;
		}
		else if (action == "window:pin")
		{
			w->pinned = !w->pinned;
			if (w->document)
				w->document->SetClass("pinned", w->pinned);
		}
	}
	else if (type == "dblclick" && target && action.empty())
	{
		for (Rml::Element* e = target; e; e = e->GetParentNode())
		{
			if (e->GetId() == "window-titlebar")
			{
				m_owner->toggleCollapse = true;
				break;
			}
		}
	}

	// Clicks are emitted from HandleInput after Update() (ImGui mouse-release).
	// Listening here too double-toggles Lua actions.
	if (type == "click" || type == "dblclick" || type == "mousedown")
		return;

	m_owner->PushEvent(type + "\t" + Sanitize(id) + "\t" + Sanitize(action) + "\t" + Sanitize(value) + "\t" + button);
}

void ModelChanged(RmlWindow* owner, const std::string& model, const std::string& key, const Rml::Variant& value)
{
	// Two-way bindings (data-value / data-checked) report back through the normal event queue:
	// "modelchange\t<model>\t<key>\t<value>\t"
	if (owner)
		owner->PushEvent("modelchange\t" + Sanitize(model) + "\t" + Sanitize(key) + "\t" + Sanitize(value.Get<Rml::String>()) + "\t");
}

// ---------------------------------------------------------------------------------------------
// Global state

SystemInterface_MQ g_system;
RenderInterface_DX11 g_render;
bool g_initialized = false;
bool g_deviceReady = false;
int g_renderCallbacksId = -1;
std::map<std::string, std::unique_ptr<RmlWindow>> g_windows;
std::string g_returnBuffer;
RmlWindow* g_debuggerHost = nullptr;
bool g_debuggerInitialized = false;
std::vector<Rml::byte> g_iconFontData; // must outlive the font engine

RmlWindow* FindRmlWindow(const char* name)
{
	if (!g_initialized || !name)
		return nullptr;
	auto it = g_windows.find(name);
	return it == g_windows.end() ? nullptr : it->second.get();
}

Rml::Element* FindElement(const char* window, const char* id)
{
	RmlWindow* w = FindRmlWindow(window);
	if (!w || !w->document)
		return nullptr;
	if (!id || !*id || strcmp(id, "body") == 0)
		return w->document;
	return w->document->GetElementById(id);
}

void UnloadDocument(RmlWindow* w)
{
	if (w->document)
	{
		if (w->listener)
		{
			for (const char* type : { "click", "dblclick", "change", "submit" })
				w->document->RemoveEventListener(type, w->listener.get(), true);
		}
		w->context->UnloadDocument(w->document);
		w->document = nullptr;
		w->context->Update();
	}
}

bool LoadDocument(RmlWindow* w)
{
	UnloadDocument(w);

	w->document = w->context->LoadDocument(w->path);
	if (!w->document)
	{
		Chat("\arfailed to load '%s'", w->path.c_str());
		return false;
	}

	if (!w->listener)
		w->listener = std::make_unique<DocumentListener>(w);
	for (const char* type : { "click", "dblclick", "change", "submit" })
		w->document->AddEventListener(type, w->listener.get(), true);

	if (Rml::Element* title = w->document->GetElementById("window-title"))
		title->SetInnerRML(EscapeRml(w->document->GetTitle().c_str()));
	w->document->SetClass("pinned", w->pinned);
	w->document->SetClass("collapsed", w->collapsed);

	w->document->Show();
	return true;
}

void DestroyRmlWindow(const std::string& name)
{
	auto it = g_windows.find(name);
	if (it == g_windows.end())
		return;

	RmlWindow* w = it->second.get();
	if (g_debuggerInitialized && g_debuggerHost && w != g_debuggerHost)
	{
		Rml::Debugger::SetVisible(false);
		Rml::Debugger::SetContext(g_debuggerHost->context);
	}
	if (w == g_debuggerHost)
		return; // the debugger host lives until shutdown

	UnloadDocument(w);
	w->ReleaseTarget();
	Rml::RemoveContext(w->context->GetName());
	g_windows.erase(it);
}

RmlWindow* CreateRmlWindow(const std::string& name)
{
	auto w = std::make_unique<RmlWindow>();
	w->name = name;
	w->lastPoll = NowSeconds();
	w->context = Rml::CreateContext("mq2rmlui_" + name, Rml::Vector2i(320, 240), &g_render);
	if (!w->context)
		return nullptr;
	RmlWindow* raw = w.get();
	g_windows[name] = std::move(w);
	return raw;
}

// ---------------------------------------------------------------------------------------------
// Rendering (MQ GraphicsSceneRender callback, inside EQ's scene)

bool EnsureTarget(ID3D11Device* device, RmlWindow* w)
{
	const int width = Rml::Math::Clamp(w->wantW, 1, 4096);
	const int height = Rml::Math::Clamp(w->wantH, 1, 4096);
	if (w->rt && w->rtW == width && w->rtH == height)
		return true;

	w->ReleaseTarget();

	D3D11_TEXTURE2D_DESC td = {};
	td.Width = width;
	td.Height = height;
	td.MipLevels = 1;
	td.ArraySize = 1;
	td.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
	td.SampleDesc.Count = 1;
	td.Usage = D3D11_USAGE_DEFAULT;
	td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
	if (FAILED(device->CreateTexture2D(&td, nullptr, &w->rt)))
		return false;
	if (FAILED(device->CreateRenderTargetView(w->rt, nullptr, &w->rtRtv))
		|| FAILED(device->CreateShaderResourceView(w->rt, nullptr, &w->rtSrv)))
	{
		w->ReleaseTarget();
		return false;
	}

	D3D11_TEXTURE2D_DESC dd = td;
	dd.Format = DXGI_FORMAT_D24_UNORM_S8_UINT;
	dd.BindFlags = D3D11_BIND_DEPTH_STENCIL;
	dd.MiscFlags = 0;
	if (FAILED(device->CreateTexture2D(&dd, nullptr, &w->rtDepthTex)))
	{
		w->ReleaseTarget();
		return false;
	}
	D3D11_DEPTH_STENCIL_VIEW_DESC dsvd = {};
	dsvd.Format = DXGI_FORMAT_D24_UNORM_S8_UINT;
	dsvd.ViewDimension = D3D11_DSV_DIMENSION_TEXTURE2D;
	dsvd.Texture2D.MipSlice = 0;
	if (FAILED(device->CreateDepthStencilView(w->rtDepthTex, &dsvd, &w->rtDsv)))
	{
		w->ReleaseTarget();
		return false;
	}

	w->rtW = width;
	w->rtH = height;
	return true;
}

void OnCreateDeviceObjects()
{
	g_render.SetDevice(mq::gpD3D11Device);
	g_deviceReady = mq::gpD3D11Device != nullptr;
}

void OnInvalidateDeviceObjects()
{
	g_deviceReady = false;
	for (auto& [_, w] : g_windows)
		w->ReleaseTarget();
	Canvas_OnLostDevice();
	g_render.OnLostDevice();
}

// Full D3D11 pipeline snapshot around Rml paint (D3D11StateBackup.h): nothing we bind leaks into EQ.
using D3D11Backup = D3D11StateBackup;

void OnGraphicsSceneRender()
{
	if (!g_initialized || !g_deviceReady || !mq::gpD3D11Device)
		return;

	ID3D11Device* device = mq::gpD3D11Device;
	g_render.SetDevice(device);
	ID3D11DeviceContext* ctx = g_render.GetContext();
	if (!ctx)
		return;

	const double now = NowSeconds();
	std::vector<RmlWindow*> pending;
	for (auto& [_, w] : g_windows)
	{
		// Paint only while the ImGui surface was recently interactive (focused/hovered/drag),
		// or once after resize so the frozen frame matches the new size.
		const bool canvasLive = Canvas_ContextWantsPaint(w->context);
		const bool needsPaint = w->visible && w->context && w->wantW > 0 && w->wantH > 0
			&& (w->interactive || canvasLive || !w->rendered || w->wantW != w->lastPaintW || w->wantH != w->lastPaintH)
			&& (w->interactive ? (now - w->lastShown < 0.5) : true);
		if (needsPaint)
			pending.push_back(w.get());
	}
	if (pending.empty())
		return;

	D3D11Backup backup;
	backup.Capture(ctx);
	D3D11StateBackup::ClearExtraStages(ctx);

	for (RmlWindow* w : pending)
	{
		if (!EnsureTarget(device, w))
			continue;

		w->context->SetDimensions(Rml::Vector2i(w->rtW, w->rtH));
		if (w->interactive && now - w->updatedAt > 0.008)
			w->context->Update();
		else if (!w->interactive && (w->wantW != w->lastPaintW || w->wantH != w->lastPaintH))
			w->context->Update(); // one-shot after resize while frozen

		Canvas_SetPaintTarget(w->name.c_str(), w->rt, w->rtRtv, w->rtW, w->rtH);
		ctx->OMSetRenderTargets(1, &w->rtRtv, w->rtDsv);
		g_render.BeginFrame(w->rtW, w->rtH);
		w->context->Render();
		g_render.EndFrame();
		Canvas_SetPaintTarget(nullptr, nullptr, nullptr, 0, 0);
		w->rendered = true;
		w->lastPaintW = w->rtW;
		w->lastPaintH = w->rtH;
	}

	backup.Restore(ctx);
}

// Premultiplied RT; ImGui DX11 typically blends straight alpha — force ONE / INV_SRC_ALPHA.
void SetPremultipliedBlend(const ImDrawList*, const ImDrawCmd*)
{
	ID3D11Device* device = mq::gpD3D11Device;
	if (!device)
		return;
	ID3D11DeviceContext* ctx = nullptr;
	device->GetImmediateContext(&ctx);
	if (!ctx)
		return;
	static ID3D11BlendState* s_blend = nullptr;
	if (!s_blend)
	{
		D3D11_BLEND_DESC bd = {};
		bd.RenderTarget[0].BlendEnable = TRUE;
		bd.RenderTarget[0].SrcBlend = D3D11_BLEND_ONE;
		bd.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
		bd.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
		bd.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
		bd.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
		bd.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
		bd.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
		device->CreateBlendState(&bd, &s_blend);
	}
	const float factor[4] = { 0, 0, 0, 0 };
	if (s_blend)
		ctx->OMSetBlendState(s_blend, factor, 0xFFFFFFFF);
	ctx->Release();
}

// ---------------------------------------------------------------------------------------------
// ImGui hosting and input forwarding

struct KeyMap { ImGuiKey imgui; Rml::Input::KeyIdentifier rml; };
const KeyMap kKeys[] = {
	{ ImGuiKey_Backspace, Rml::Input::KI_BACK }, { ImGuiKey_Delete, Rml::Input::KI_DELETE },
	{ ImGuiKey_LeftArrow, Rml::Input::KI_LEFT }, { ImGuiKey_RightArrow, Rml::Input::KI_RIGHT },
	{ ImGuiKey_UpArrow, Rml::Input::KI_UP }, { ImGuiKey_DownArrow, Rml::Input::KI_DOWN },
	{ ImGuiKey_Home, Rml::Input::KI_HOME }, { ImGuiKey_End, Rml::Input::KI_END },
	{ ImGuiKey_PageUp, Rml::Input::KI_PRIOR }, { ImGuiKey_PageDown, Rml::Input::KI_NEXT },
	{ ImGuiKey_Enter, Rml::Input::KI_RETURN }, { ImGuiKey_KeypadEnter, Rml::Input::KI_NUMPADENTER },
	{ ImGuiKey_Tab, Rml::Input::KI_TAB }, { ImGuiKey_Escape, Rml::Input::KI_ESCAPE },
	{ ImGuiKey_A, Rml::Input::KI_A }, { ImGuiKey_C, Rml::Input::KI_C },
	{ ImGuiKey_V, Rml::Input::KI_V }, { ImGuiKey_X, Rml::Input::KI_X },
	{ ImGuiKey_Z, Rml::Input::KI_Z }, { ImGuiKey_F8, Rml::Input::KI_F8 },
};

int KeyModifiers(const ImGuiIO& io)
{
	int mods = 0;
	if (io.KeyCtrl) mods |= Rml::Input::KM_CTRL;
	if (io.KeyShift) mods |= Rml::Input::KM_SHIFT;
	if (io.KeyAlt) mods |= Rml::Input::KM_ALT;
	return mods;
}

RmlWindow::Drag DragModeAt(Rml::Element* element)
{
	for (Rml::Element* e = element; e; e = e->GetParentNode())
	{
		if (e->GetId() == "window-shadow")
			continue;
		if (e->HasAttribute("resize"))
			return RmlWindow::Drag::Resize;
		if (e->HasAttribute("action") || IsTextInput(e) || e->GetTagName() == "button")
			return RmlWindow::Drag::None;
		if (e->HasAttribute("drag"))
			return RmlWindow::Drag::Move;
	}
	return RmlWindow::Drag::None;
}

void ApplyWindowAction(RmlWindow* w, const std::string& action)
{
	if (action == "window:close")
		w->visible = false;
	else if (action == "window:collapse")
		w->toggleCollapse = true;
	else if (action == "window:pin")
	{
		w->pinned = !w->pinned;
		if (w->document)
			w->document->SetClass("pinned", w->pinned);
	}
}

void EmitClickFromElement(RmlWindow* w, Rml::Element* start, const char* type, int button)
{
	if (!start)
		return;
	std::string id, action;
	for (Rml::Element* e = start; e; e = e->GetParentNode())
	{
		if (e->GetId() == "window-shadow")
			continue;
		if (id.empty() && !e->GetId().empty() && e->GetId() != "window-shadow")
			id = e->GetId();
		if (action.empty())
			action = e->GetAttribute<Rml::String>("action", "");
		if (!id.empty() && !action.empty())
			break;
	}
	if (id.empty() && action.empty())
		return;
	if (action.rfind("window:", 0) == 0)
		ApplyWindowAction(w, action);
	w->PushEvent(std::string(type) + "\t" + Sanitize(id) + "\t" + Sanitize(action) + "\t\t" + std::to_string(button));
}

bool IsForwardableKey(ImGuiKey key)
{
	if (key >= ImGuiKey_GamepadStart && key <= ImGuiKey_GamepadRStickDown)
		return false;
	if (key >= ImGuiKey_MouseLeft && key <= ImGuiKey_MouseWheelY)
		return false;
	if (key >= ImGuiKey_ReservedForModCtrl && key <= ImGuiKey_ReservedForModSuper)
		return false;
	return true;
}

// Reports keydown/keyup to Lua as "keydown\t<focused element id>\t\t<ImGui key name>\t<mods>", mods = 1 ctrl,
// 2 shift, 4 alt. Only runs for the focused window and only when Lua enabled it with rml_key_mode.
void ForwardKeys(RmlWindow* w, Rml::Element* focus, const ImGuiIO& io)
{
	const int mods = (io.KeyCtrl ? 1 : 0) | (io.KeyShift ? 2 : 0) | (io.KeyAlt ? 4 : 0);
	const std::string id = (focus && focus != w->document) ? Sanitize(focus->GetId()) : std::string();
	for (int k = ImGuiKey_NamedKey_BEGIN; k < ImGuiKey_NamedKey_END; ++k)
	{
		const ImGuiKey key = (ImGuiKey)k;
		if (!IsForwardableKey(key))
			continue;
		const bool down = ImGui::IsKeyPressed(key, false);
		const bool up = !down && ImGui::IsKeyReleased(key);
		if (!down && !up)
			continue;
		const char* name = ImGui::GetKeyName(key);
		w->PushEvent(std::string(down ? "keydown" : "keyup") + "\t" + id + "\t\t" + Sanitize(name ? name : "") + "\t" + std::to_string(mods));
	}
}

void HandleInput(RmlWindow* w, const ImVec2& origin, bool hovered)
{
	ImGuiIO& io = ImGui::GetIO();
	Rml::Context* ctx = w->context;
	const int mods = KeyModifiers(io);

	if (w->flags & RMLWIN_CLICKTHROUGH)
		hovered = false;

	const ImVec2 mouse = ImGui::GetMousePos();
	const int mx = (int)(mouse.x - origin.x);
	const int my = (int)(mouse.y - origin.y);

	if (hovered || w->buttonsDown)
	{
		if (mx != w->lastMouseX || my != w->lastMouseY || !w->mouseInside)
		{
			ctx->ProcessMouseMove(mx, my, mods);
			w->lastMouseX = mx;
			w->lastMouseY = my;
		}
		w->mouseInside = true;

		for (int b = 0; b < 3; ++b)
		{
			const int bit = 1 << b;
			if (hovered && ImGui::IsMouseClicked(b))
			{
				if (b == 0)
					w->drag = w->pinned ? RmlWindow::Drag::None : DragModeAt(ctx->GetHoverElement());
				ctx->ProcessMouseButtonDown(b, mods);
				w->buttonsDown |= bit;
			}
			else if ((w->buttonsDown & bit) && (ImGui::IsMouseReleased(b) || !ImGui::IsMouseDown(b)))
			{
				ctx->ProcessMouseButtonUp(b, mods);
				w->buttonsDown &= ~bit;
				if (b == 0)
				{
					// drag patch: tell Lua where the window ended up so it can save it.
					// "windowmoved\t\t<move|resize>\t<x>,<y>,<w>,<h>\t0"
					if (w->drag != RmlWindow::Drag::None)
					{
						const ImVec2 p = ImGui::GetWindowPos();
						const ImVec2 s = ImGui::GetWindowSize();
						char buf[96];
						snprintf(buf, sizeof(buf), "%d,%d,%d,%d", (int)p.x, (int)p.y, (int)s.x, (int)s.y);
						w->PushEvent(std::string("windowmoved\t\t") + (w->drag == RmlWindow::Drag::Move ? "move" : "resize") + "\t" + buf + "\t0");
					}
					w->drag = RmlWindow::Drag::None;
				}
			}
		}

		if (hovered && io.MouseWheel != 0.0f)
			ctx->ProcessMouseWheel(-io.MouseWheel, mods);
	}
	else if (w->mouseInside)
	{
		ctx->ProcessMouseLeave();
		w->mouseInside = false;
		w->lastMouseX = w->lastMouseY = -1;
	}

	if (w->drag != RmlWindow::Drag::None && !ImGui::IsMouseDown(0))
		w->drag = RmlWindow::Drag::None; // drag patch: released outside every window / focus lost
	if (w->drag != RmlWindow::Drag::None && ImGui::IsMouseDown(0))
	{
		const ImVec2 delta = io.MouseDelta;
		if (delta.x != 0.0f || delta.y != 0.0f)
		{
			if (w->drag == RmlWindow::Drag::Move)
			{
				ImGui::SetWindowPos(ImGui::GetWindowPos() + delta);
			}
			else
			{
				ImVec2 size = ImGui::GetWindowSize() + delta;
				size.x = size.x < 120.0f ? 120.0f : size.x;
				size.y = size.y < 60.0f ? 60.0f : size.y;
				ImGui::SetWindowSize(size);
			}
		}
	}

	const bool focused = ImGui::IsWindowFocused();
	if (w->document)
		w->document->SetClass("focused", focused);
	Rml::Element* focus = ctx->GetFocusElement();
	const bool typing = IsTextInput(focus);

	if (focused)
	{
		for (const KeyMap& k : kKeys)
		{
			if (ImGui::IsKeyPressed(k.imgui, true))
				ctx->ProcessKeyDown(k.rml, mods);
			if (ImGui::IsKeyReleased(k.imgui))
				ctx->ProcessKeyUp(k.rml, mods);
		}

		if (w->keyMode > 0)
			ForwardKeys(w, focus, io);

		if (typing)
		{
			std::string text;
			for (int i = 0; i < io.InputQueueCharacters.Size; ++i)
			{
				const unsigned int c = io.InputQueueCharacters[i];
				if (c >= 32 && c != 127)
					AppendUtf8(text, c);
			}
			if (!text.empty())
				ctx->ProcessTextInput(text);
			ImGui::SetNextFrameWantCaptureKeyboard(true);
			// MQ only flushes EQ DirectInput when WantTextInput, or WantCaptureKeyboard while NOT WantCaptureMouse (GraphicsEngine.cpp ProcessKeyboardEvents_Detour). We also capture mouse while hovered, so set it like ImGuiTextEditor does.
			ImGui::GetIO().WantCaptureKeyboard = true;
			ImGui::GetIO().WantTextInput = true;
		}
	}
	else if (w->wasFocused && focus && focus != w->document)
	{
		focus->Blur();
	}
	w->wasFocused = focused;
	if (focused && w->keyMode >= 2)
	{
		ImGui::SetNextFrameWantCaptureKeyboard(true);
		// MQ only flushes EQ DirectInput when WantTextInput, or WantCaptureKeyboard while NOT WantCaptureMouse (GraphicsEngine.cpp ProcessKeyboardEvents_Detour). We also capture mouse while hovered, so set it like ImGuiTextEditor does.
		ImGui::GetIO().WantCaptureKeyboard = true;
		ImGui::GetIO().WantTextInput = true;
	}

	// Same contract as a normal MQ ImGui window: while the cursor is on us,
	// EQ must not also get the click (move / target / hotbar).
	if (hovered || w->buttonsDown)
		ImGui::SetNextFrameWantCaptureMouse(true);
}

void DrawWindow(RmlWindow* w)
{
	const std::string title = (w->isDebuggerHost ? std::string("RmlUi Debugger") : w->name) + "##mq2rmlui";

	if (w->hasPendingRect)
	{
		if (w->pendingX >= 0 && w->pendingY >= 0)
			ImGui::SetNextWindowPos(ImVec2(w->pendingX, w->pendingY), ImGuiCond_Always);
		if (w->pendingW > 0 && w->pendingH > 0)
			ImGui::SetNextWindowSize(ImVec2(w->pendingW, w->pendingH), ImGuiCond_Always);
		w->hasPendingRect = false;
	}
	else
	{
		if (w->defaultX >= 0 && w->defaultY >= 0)
			ImGui::SetNextWindowPos(ImVec2(w->defaultX, w->defaultY), ImGuiCond_FirstUseEver);
		ImGui::SetNextWindowSize(ImVec2(w->defaultW, w->defaultH), ImGuiCond_FirstUseEver);
	}

	if (w->toggleCollapse && w->document && w->windowSize.x > 0)
	{
		w->toggleCollapse = false;
		if (!w->collapsed)
		{
			Rml::Element* bar = w->document->GetElementById("window-titlebar");
			Rml::Element* frame = w->document->GetElementById("window-frame");
			if (bar && frame)
			{
				const float frameBottomGap = (float)w->rtH - (frame->GetAbsoluteTop() + frame->GetOffsetHeight());
				const float height = bar->GetAbsoluteTop() + bar->GetOffsetHeight() + frame->GetClientTop() + frameBottomGap;
				w->expandedHeight = w->windowSize.y;
				w->collapsed = true;
				ImGui::SetNextWindowSize(ImVec2(w->windowSize.x, height), ImGuiCond_Always);
			}
		}
		else
		{
			w->collapsed = false;
			ImGui::SetNextWindowSize(ImVec2(w->windowSize.x, w->expandedHeight), ImGuiCond_Always);
		}
		w->document->SetClass("collapsed", w->collapsed);
	}
	w->toggleCollapse = false;

	ImGuiWindowFlags flags = ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoScrollWithMouse
		| ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoBackground | ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoNav;
	if (w->flags & RMLWIN_CLICKTHROUGH)
		flags |= ImGuiWindowFlags_NoInputs;

	ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0, 0));
	ImGui::PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0.0f);
	ImGui::PushStyleVar(ImGuiStyleVar_WindowMinSize, ImVec2(16, 16));
	const bool open = ImGui::Begin(title.c_str(), nullptr, flags);
	ImGui::PopStyleVar(3);

	if (open)
	{
		ImVec2 avail = ImGui::GetContentRegionAvail();
		if (avail.x < 1) avail.x = 1;
		if (avail.y < 1) avail.y = 1;
		w->wantW = (int)avail.x;
		w->wantH = (int)avail.y;
		w->windowSize = ImGui::GetWindowSize();
		w->windowPos = ImGui::GetWindowPos();

		const ImVec2 origin = ImGui::GetCursorScreenPos();
		if (w->rt && w->rendered)
		{
			ImDrawList* drawList = ImGui::GetWindowDrawList();
			drawList->AddCallback(SetPremultipliedBlend, nullptr);
			// OpenVanilla imgui-64: AddImage(ImTextureRef, ...); TexID is ImGuiTextureObject (SRV).
			drawList->AddImage(ImTextureRef(ImGuiTextureObject(w->rtSrv)), origin, origin + ImVec2((float)w->rtW, (float)w->rtH));
			drawList->AddCallback(ImDrawCallback_ResetRenderState, nullptr);
		}

		ImGui::InvisibleButton("##rmlsurface", avail,
			ImGuiButtonFlags_MouseButtonLeft | ImGuiButtonFlags_MouseButtonRight | ImGuiButtonFlags_MouseButtonMiddle);
		const bool hovered = ImGui::IsWindowHovered(ImGuiHoveredFlags_AllowWhenBlockedByActiveItem)
			|| ImGui::IsItemHovered(ImGuiHoveredFlags_AllowWhenBlockedByActiveItem);
		const bool focused = ImGui::IsWindowFocused();
		// Keep animating while using the window; freeze Update/GPU paint when idle elsewhere.
		// Click-through overlays stay live (they never take focus/hover for input).
		w->interactive = (w->flags & RMLWIN_CLICKTHROUGH) != 0
			|| focused || hovered || w->drag != RmlWindow::Drag::None || !w->rendered;
		if (w->interactive)
			w->lastShown = NowSeconds();

		HandleInput(w, origin, hovered);

		// Only advance RmlUi (animations, layout) while interactive. Idle windows keep the last frame.
		if (w->interactive && w->context && w->wantW > 0 && w->wantH > 0)
		{
			w->context->SetDimensions(Rml::Vector2i(
				Rml::Math::Clamp(w->wantW, 1, 4096),
				Rml::Math::Clamp(w->wantH, 1, 4096)));
			w->context->Update();
			w->updatedAt = NowSeconds();
		}
		else if (w->context && w->wantW > 0 && w->wantH > 0
			&& (w->wantW != w->lastPaintW || w->wantH != w->lastPaintH))
		{
			w->context->SetDimensions(Rml::Vector2i(
				Rml::Math::Clamp(w->wantW, 1, 4096),
				Rml::Math::Clamp(w->wantH, 1, 4096)));
		}

		// ImGui-style activate-on-release, after Update so hover is current.
		if (hovered && w->drag == RmlWindow::Drag::None && w->context)
		{
			if (ImGui::IsMouseReleased(0))
				EmitClickFromElement(w, w->context->GetHoverElement(), "click", 0);
			if (ImGui::IsMouseDoubleClicked(0))
				EmitClickFromElement(w, w->context->GetHoverElement(), "dblclick", 0);
		}
	}
	else
	{
		w->interactive = false;
	}
	ImGui::End();
}

void LoadDefaultFonts()
{
	char windir[MAX_PATH] = {};
	GetWindowsDirectoryA(windir, MAX_PATH);
	const std::string fonts = std::string(windir) + "/Fonts/";

	int loaded = 0;
	for (const char* file : { "segoeui.ttf", "segoeuib.ttf", "seguisb.ttf", "segoeuii.ttf", "segoeuil.ttf" })
	{
		const std::string path = fonts + file;
		if (GetFileAttributesA(path.c_str()) != INVALID_FILE_ATTRIBUTES && Rml::LoadFontFace(path))
			++loaded;
	}
	for (const char* file : { "seguisym.ttf", "seguiemj.ttf" })
	{
		const std::string path = fonts + file;
		if (GetFileAttributesA(path.c_str()) != INVALID_FILE_ATTRIBUTES)
			Rml::LoadFontFace(path, true);
	}
	if (loaded == 0)
		Rml::LoadFontFace(fonts + "arial.ttf", true);

	// Window chrome glyphs use font-family "Icons": Segoe Fluent Icons (Win11) or Segoe MDL2 Assets (Win10),
	// which share code points for the glyphs the theme uses.
	for (const char* file : { "SegoeIcons.ttf", "segmdl2.ttf" })
	{
		FILE* f = fopen((fonts + file).c_str(), "rb");
		if (!f)
			continue;
		fseek(f, 0, SEEK_END);
		g_iconFontData.resize((size_t)ftell(f));
		fseek(f, 0, SEEK_SET);
		fread(g_iconFontData.data(), 1, g_iconFontData.size(), f);
		fclose(f);
		if (Rml::LoadFontFace(Rml::Span<const Rml::byte>(g_iconFontData.data(), g_iconFontData.size()), "Icons",
			Rml::Style::FontStyle::Normal, Rml::Style::FontWeight::Normal))
			break;
	}
}

void ShutdownRml()
{
	if (!g_initialized)
		return;
	g_initialized = false;

	if (g_debuggerInitialized)
	{
		Rml::Debugger::Shutdown();
		g_debuggerInitialized = false;
	}
	g_debuggerHost = nullptr;

	for (auto& [_, w] : g_windows)
	{
		UnloadDocument(w.get());
		w->ReleaseTarget();
	}
	Rml::Shutdown();
	g_windows.clear();
	g_iconFontData.clear();
}

} // namespace

// ---------------------------------------------------------------------------------------------
// MQ plugin callbacks

PLUGIN_API void InitializePlugin()
{
	Rml::SetSystemInterface(&g_system);
	Rml::SetRenderInterface(&g_render);
	if (!Rml::Initialise())
	{
		Chat("\arRmlUi failed to initialise");
		return;
	}
	LoadDefaultFonts();
	RegisterCanvasElement();
	Canvas_SetFindElement(FindElement);
	g_initialized = true;

	mq::MQRenderCallbacks callbacks;
	callbacks.CreateDeviceObjects = OnCreateDeviceObjects;
	callbacks.InvalidateDeviceObjects = OnInvalidateDeviceObjects;
	callbacks.GraphicsSceneRender = OnGraphicsSceneRender;
	g_renderCallbacksId = mq::AddRenderCallbacks(callbacks);

	Chat("RmlUi %s loaded. Try \ay/lua run rmlhud\ax", Rml::GetVersion().c_str());
}

PLUGIN_API void ShutdownPlugin()
{
	Orn_Shutdown();      // put back the original attached models if we swapped any (game thread, before Mat_Shutdown)
	Mat_Shutdown();      // restore original material tints if we changed any (game thread)
	Nimbus_Shutdown();   // take a native nimbus we added off the character (game thread)
	if (g_renderCallbacksId >= 0)
	{
		mq::RemoveRenderCallbacks(g_renderCallbacksId);
		g_renderCallbacksId = -1;
	}
	ShutdownRml();
	Fx_Shutdown();   // canvases are gone (their destructors freed their emitters); drop anything left
	Tfx_Shutdown();  // TextFX numbers (and the atlas build thread)
	// Release the canvas renderer's D3D objects (shaders, buffers, RT sets, textures, queries) on unload.
	// Safe if the device is already gone: the COM children still hold their own references.
	Canvas_OnLostDevice();
	g_deviceReady = false;
	g_render.SetDevice(nullptr);
}

// Autoclose hold. The Lua heartbeat (rml_poll via win:events()) runs from the mq.imgui callback, and ImGui
// frames stop while EQ zones / loads. Without a hold, the first OnPulse after a zone saw lastPoll > 5 s old
// and destroyed every autoclose window while its script kept running ("gone after zone, already running").
static bool g_zoning = false;          // OnBeginZone .. OnEndZone/OnZoned, or game state != INGAME
static double g_holdUntil = 0.0;       // no autoclose before this (grace after zone / stall)
static double g_lastPulse = 0.0;
static constexpr double kZoneGraceSeconds = 10.0;
static constexpr double kPulseStallSeconds = 1.0;
static constexpr int kGameStateInGame = GAMESTATE_INGAME;

static void HoldAutoclose(double seconds)
{
	const double now = NowSeconds();
	if (now + seconds > g_holdUntil)
		g_holdUntil = now + seconds;
}

PLUGIN_API void OnBeginZone() { g_zoning = true; Nimbus_BeginZone(); Mat_BeginZone(); Orn_BeginZone(); }
PLUGIN_API void OnEndZone() { g_zoning = false; HoldAutoclose(kZoneGraceSeconds); }
PLUGIN_API void OnZoned() { g_zoning = false; HoldAutoclose(kZoneGraceSeconds); }
PLUGIN_API void SetGameState(int gameState)
{
	g_zoning = gameState != kGameStateInGame;
	if (g_zoning)
	{
		Nimbus_BeginZone();
		Mat_BeginZone();
		Orn_BeginZone();
	}
	HoldAutoclose(kZoneGraceSeconds);
}

PLUGIN_API void OnPulse()
{
	if (!g_initialized)
		return;

	Canvas_PulseWorldToScreenLog();
	Nimbus_Pulse(g_zoning);   // native nimbus requests run here, on the game thread
	Mat_Pulse(g_zoning);
	Orn_Pulse(g_zoning);      // ornament model swap requests (proof test), game thread

	const double now = NowSeconds();
	// A long gap between pulses = the game thread was blocked (zone load, hitch); Lua could not poll either.
	if (g_lastPulse > 0.0 && now - g_lastPulse > kPulseStallSeconds)
		HoldAutoclose(kZoneGraceSeconds);
	g_lastPulse = now;

	if (g_zoning || now < g_holdUntil)
	{
		// Keep owners alive while they cannot poll; the normal 5 s rule resumes after the grace period.
		for (auto& [name, w] : g_windows)
			if (w->lastPoll < now)
				w->lastPoll = now;
		return;
	}

	std::vector<std::string> expired;
	for (auto& [name, w] : g_windows)
	{
		if ((w->flags & RMLWIN_AUTOCLOSE) && now - w->lastPoll > kAutoCloseSeconds)
			expired.push_back(name);
	}
	for (const std::string& name : expired)
	{
		char line[256];
		RmlWindow* w = FindRmlWindow(name.c_str());
		snprintf(line, sizeof(line), "autoclose win=%s no poll for %.1f s", name.c_str(), w ? now - w->lastPoll : -1.0);
		Canvas_Log(line);
		DestroyRmlWindow(name);
	}
}

PLUGIN_API void OnUpdateImGui()
{
	if (!g_initialized)
		return;

	for (auto& [_, w] : g_windows)
	{
		if (w->visible && w->context && (w->document || w->isDebuggerHost))
			DrawWindow(w.get());
	}
}

// ---------------------------------------------------------------------------------------------
// Lua FFI API. All functions are safe to call when the plugin is not initialized.

PLUGIN_API int rml_api_version() { return kApiVersion; }
PLUGIN_API int rml_ready() { return g_initialized ? 1 : 0; }

// Bitmask of what this DLL's DX11 renderer can draw (core path; advanced caps currently 0):
// 1 gradients, 2 filters, 4 layers, 8 box-shadow, 16 backdrop-filter, 32 mask-image. 0 when not ready.
// Optional export: older DLLs don't have it, so Lua should probe it with pcall. API version is unchanged.
PLUGIN_API int rml_render_caps()
{
	if (!g_initialized || !g_deviceReady || !mq::gpD3D11Device)
		return 0;
	g_render.SetDevice(mq::gpD3D11Device);
	return (int)g_render.GetRenderCaps();
}

PLUGIN_API int rml_open(const char* name, const char* path, int width, int height, int flags)
{
	if (!g_initialized || !name || !*name || !path)
		return 0;

	RmlWindow* w = FindRmlWindow(name);
	const std::string fullPath = NormalizePath(path);
	if (!w)
	{
		w = CreateRmlWindow(name);
		if (!w)
			return 0;
	}
	w->flags = flags;
	w->lastPoll = NowSeconds();
	w->visible = true;
	if (width > 0) w->defaultW = (float)width;
	if (height > 0) w->defaultH = (float)height;

	if (w->document && w->path == fullPath)
		return 1;

	w->path = fullPath;
	if (!LoadDocument(w))
	{
		DestroyRmlWindow(name);
		return 0;
	}
	return 1;
}

PLUGIN_API int rml_close(const char* name)
{
	if (!FindRmlWindow(name))
		return 0;
	DestroyRmlWindow(name);
	return 1;
}

PLUGIN_API int rml_reload(const char* name)
{
	RmlWindow* w = FindRmlWindow(name);
	if (!w || w->path.empty())
		return 0;
	Rml::Factory::ClearStyleSheetCache();
	Rml::Factory::ClearTemplateCache();
	return LoadDocument(w) ? 1 : 0;
}

PLUGIN_API int rml_show(const char* name, int show)
{
	RmlWindow* w = FindRmlWindow(name);
	if (!w)
		return 0;
	w->visible = show != 0;
	return 1;
}

PLUGIN_API int rml_is_open(const char* name)
{
	RmlWindow* w = FindRmlWindow(name);
	return (w && w->document) ? 1 : 0;
}

PLUGIN_API int rml_set_window(const char* name, float x, float y, float width, float height)
{
	RmlWindow* w = FindRmlWindow(name);
	if (!w)
		return 0;
	w->pendingX = x;
	w->pendingY = y;
	w->pendingW = width;
	w->pendingH = height;
	w->hasPendingRect = true;
	return 1;
}

PLUGIN_API int rml_set_default_pos(const char* name, float x, float y)
{
	RmlWindow* w = FindRmlWindow(name);
	if (!w)
		return 0;
	w->defaultX = x;
	w->defaultY = y;
	return 1;
}

PLUGIN_API int rml_set_rml(const char* window, const char* id, const char* rml)
{
	Rml::Element* e = FindElement(window, id);
	if (!e)
		return 0;
	e->SetInnerRML(rml ? rml : "");
	return 1;
}

PLUGIN_API int rml_set_text(const char* window, const char* id, const char* text)
{
	Rml::Element* e = FindElement(window, id);
	if (!e)
		return 0;
	e->SetInnerRML(EscapeRml(text));
	return 1;
}

PLUGIN_API int rml_set_attr(const char* window, const char* id, const char* attr, const char* value)
{
	Rml::Element* e = FindElement(window, id);
	if (!e || !attr)
		return 0;
	if (value)
		e->SetAttribute(attr, Rml::String(value));
	else
		e->RemoveAttribute(attr);
	return 1;
}

PLUGIN_API int rml_set_class(const char* window, const char* id, const char* cls, int on)
{
	Rml::Element* e = FindElement(window, id);
	if (!e || !cls)
		return 0;
	e->SetClass(cls, on != 0);
	return 1;
}

PLUGIN_API int rml_set_style(const char* window, const char* id, const char* property, const char* value)
{
	Rml::Element* e = FindElement(window, id);
	if (!e || !property)
		return 0;
	if (!value || !*value)
	{
		e->RemoveProperty(property);
		return 1;
	}
	return e->SetProperty(property, value) ? 1 : 0;
}

PLUGIN_API int rml_set_value(const char* window, const char* id, const char* value)
{
	Rml::Element* e = FindElement(window, id);
	auto* control = dynamic_cast<Rml::ElementFormControl*>(e);
	if (!control)
		return 0;
	control->SetValue(value ? value : "");
	return 1;
}

PLUGIN_API const char* rml_get_value(const char* window, const char* id)
{
	Rml::Element* e = FindElement(window, id);
	if (!e)
		return nullptr;
	if (auto* control = dynamic_cast<Rml::ElementFormControl*>(e))
		g_returnBuffer = control->GetValue();
	else
		g_returnBuffer = e->GetInnerRML();
	return g_returnBuffer.c_str();
}

// Returns the next queued event as "type\tid\taction\tvalue\tbutton", or NULL. Also serves as the
// owner heartbeat for RMLWIN_AUTOCLOSE windows.
PLUGIN_API const char* rml_poll(const char* name)
{
	RmlWindow* w = FindRmlWindow(name);
	if (!w)
		return nullptr;
	w->lastPoll = NowSeconds();
	if (w->events.empty())
		return nullptr;
	g_returnBuffer = std::move(w->events.front());
	w->events.pop_front();
	return g_returnBuffer.c_str();
}

// ---------------------------------------------------------------------------------------------
// v3 additions (optional exports; API version unchanged, older Lua keeps working).

// rml_render_caps() bits plus 64 = key forwarding, 128 = data models.
PLUGIN_API int rml_features()
{
	if (!g_initialized)
		return 0;
	int caps = 0;
	if (g_deviceReady && mq::gpD3D11Device)
	{
		g_render.SetDevice(mq::gpD3D11Device);
		caps = (int)g_render.GetRenderCaps();
	}
	return caps | 64 | 128 | 256 | 512 | 1024 | (Nimbus_Available() ? (2048 | 32768 | 65536) : 0) | (Nimbus_CustomAvailable() ? (131072 | 262144 | 1048576) : 0) | (Nimbus_LevelBypass() ? 524288 : 0) | (Mat_Available() ? 4096 : 0) | (Orn_Available() ? 8192 : 0) | 16384; // 16384 = rml_tfx_* GPU combat text (TextFX) // 32768 = rml_nimbus_*_slot (second native slot: ground aura) // 1048576 = slot 2 foot trail takes custom trail records (t485) // 65536 = rml_nimbus_burst (native proc effect on a spawn) // 2048 = native EQ nimbus (exact client build verified), 256 = drag patch (windowmoved event + rml_get_window), 512 = rml_fx_* particles, 1024 = bloom masked by the fx body capsule
}

PLUGIN_API int rml_key_mode(const char* name, int mode)
{
	RmlWindow* w = FindRmlWindow(name);
	if (!w)
		return 0;
	w->keyMode = mode < 0 ? 0 : (mode > 2 ? 2 : mode);
	return 1;
}

LuaModel* FindModel(const char* window, const char* model)
{
	RmlWindow* w = FindRmlWindow(window);
	if (!w || !model)
		return nullptr;
	auto it = w->models.find(model);
	return it == w->models.end() ? nullptr : it->second.get();
}

// Creates (or returns) a model. Bindings are resolved when a document loads, so create the model and
// set every key before rml_open, or call rml_reload afterwards. Creates the window (without a document)
// if it doesn't exist yet; rml_open then reuses it.
PLUGIN_API int rml_model_create(const char* window, const char* model)
{
	if (!g_initialized || !window || !*window || !model || !*model)
		return 0;
	RmlWindow* w = FindRmlWindow(window);
	if (!w)
	{
		w = CreateRmlWindow(window);
		if (!w)
			return 0;
	}
	if (w->models.count(model))
		return 1;
	if (!w->modelTypes)
		w->modelTypes = std::make_unique<Rml::DataTypeRegister>();
	auto m = std::make_unique<LuaModel>();
	m->owner = w;
	m->name = model;
	m->ctor = w->context->CreateDataModel(model, w->modelTypes.get());
	if (!m->ctor)
		return 0;
	if (!w->modelArraysRegistered)
	{
		m->ctor.RegisterArray<ModelRow>();
		m->ctor.RegisterArray<ModelList>();
		w->modelArraysRegistered = true;
	}
	m->handle = m->ctor.GetModelHandle();
	w->models[model] = std::move(m);
	return 1;
}

bool EnsureScalar(LuaModel* m, const std::string& key)
{
	if (m->values.count(key) || m->lists.count(key))
		return m->values.count(key) != 0;
	m->values[key] = Rml::Variant(Rml::String());
	LuaModel* raw = m;
	return m->ctor.BindFunc(key,
		[raw, key](Rml::Variant& out) { out = raw->values[key]; },
		[raw, key](const Rml::Variant& in) {
			raw->values[key] = in;
			ModelChanged(raw->owner, raw->name, key, in);
		});
}

// type: 0 string, 1 number, 2 bool ("1"/"true").
PLUGIN_API int rml_model_set(const char* window, const char* model, const char* key, const char* value, int type)
{
	LuaModel* m = FindModel(window, model);
	if (!m || !key || !*key || !EnsureScalar(m, key))
		return 0;
	const std::string v = value ? value : "";
	Rml::Variant nv;
	if (type == 1)
		nv = Rml::Variant(std::atof(v.c_str()));
	else if (type == 2)
		nv = Rml::Variant(v == "1" || v == "true");
	else
		nv = Rml::Variant(v);
	Rml::Variant& cur = m->values[key];
	if (cur.GetType() == nv.GetType() && cur == nv)
		return 1;
	cur = nv;
	m->handle.DirtyVariable(key);
	return 1;
}

PLUGIN_API const char* rml_model_get(const char* window, const char* model, const char* key)
{
	LuaModel* m = FindModel(window, model);
	if (!m || !key)
		return nullptr;
	auto it = m->values.find(key);
	if (it == m->values.end())
		return nullptr;
	g_returnBuffer = it->second.Get<Rml::String>();
	return g_returnBuffer.c_str();
}

// Lists: rml_model_list_size declares/resizes list `key` (rows x cols of strings);
// rml_model_list_set writes one cell (0-based). Use data-for="row : key" and {{row[0]}} in RML.
PLUGIN_API int rml_model_list_size(const char* window, const char* model, const char* key, int rows, int cols)
{
	LuaModel* m = FindModel(window, model);
	if (!m || !key || !*key || m->values.count(key) || rows < 0 || cols < 0 || rows > 4096 || cols > 64)
		return 0;
	auto it = m->lists.find(key);
	if (it == m->lists.end())
	{
		auto list = std::make_unique<ModelList>();
		if (!m->ctor.Bind(key, list.get()))
			return 0;
		it = m->lists.emplace(key, std::move(list)).first;
	}
	ModelList& list = *it->second;
	list.resize((size_t)rows);
	for (ModelRow& r : list)
		r.resize((size_t)cols);
	m->handle.DirtyVariable(key);
	return 1;
}

PLUGIN_API int rml_model_list_set(const char* window, const char* model, const char* key, int row, int col, const char* value)
{
	LuaModel* m = FindModel(window, model);
	if (!m || !key)
		return 0;
	auto it = m->lists.find(key);
	if (it == m->lists.end() || row < 0 || col < 0 || (size_t)row >= it->second->size() || (size_t)col >= (*it->second)[row].size())
		return 0;
	Rml::String& cell = (*it->second)[row][col];
	const Rml::String v = value ? value : "";
	if (cell == v)
		return 1;
	cell = v;
	m->handle.DirtyVariable(key);
	return 1;
}

PLUGIN_API int rml_model_dirty(const char* window, const char* model, const char* key)
{
	LuaModel* m = FindModel(window, model);
	if (!m)
		return 0;
	if (key && *key)
		m->handle.DirtyVariable(key);
	else
		m->handle.DirtyAllVariables();
	return 1;
}

PLUGIN_API int rml_load_font(const char* path, int fallback)
{
	if (!g_initialized || !path)
		return 0;
	return Rml::LoadFontFace(NormalizePath(path), fallback != 0) ? 1 : 0;
}

PLUGIN_API int rml_debugger(const char* name, int show)
{
	if (!g_initialized)
		return 0;

	if (!g_debuggerHost)
	{
		g_debuggerHost = CreateRmlWindow("__rmlui_debugger");
		if (!g_debuggerHost)
			return 0;
		g_debuggerHost->isDebuggerHost = true;
		g_debuggerHost->defaultW = 1000;
		g_debuggerHost->defaultH = 700;
		g_debuggerInitialized = Rml::Debugger::Initialise(g_debuggerHost->context);
	}
	if (!g_debuggerInitialized)
		return 0;

	RmlWindow* target = FindRmlWindow(name);
	Rml::Debugger::SetContext(target ? target->context : g_debuggerHost->context);
	Rml::Debugger::SetVisible(show != 0);
	g_debuggerHost->visible = show != 0;
	return 1;
}

// ---- EQ item/spell icon atlas -----------------------------------------------

PLUGIN_API int rml_set_uifiles_path(const char* path)
{
	EqIcon::SetUiFilesPath(path);
	return 1;
}

// Sample icon into an Rml texture source string (eq://…) or export a PNG and return its path.
// prefer_file != 0 forces the PNG export path.
PLUGIN_API const char* rml_icon_src(const char* kind, int id, int prefer_file)
{
	g_returnBuffer = EqIcon::IconSrc(kind, id, prefer_file != 0);
	return g_returnBuffer.empty() ? nullptr : g_returnBuffer.c_str();
}

// Always attempt PNG export. out_path may be null for the default cache location.
PLUGIN_API const char* rml_export_icon(const char* kind, int id, const char* out_path)
{
	g_returnBuffer = EqIcon::ExportPng(kind, id, out_path);
	return g_returnBuffer.empty() ? nullptr : g_returnBuffer.c_str();
}

// Returns 1 if the atlas cell can be sampled right now (uifiles + D3D ready for DDS).
PLUGIN_API int rml_icon_ready(const char* kind, int id)
{
	std::vector<uint8_t> rgba;
	int w = 0, h = 0;
	return EqIcon::Sample(kind, id, rgba, w, h) ? 1 : 0;
}

// ---------------------------------------------------------------------------------------------
// drag patch: read a window's current rect as "x,y,w,h" (screen pixels), or NULL if unknown.
// Optional export: probe with pcall(ffi.cdef, ...) / rml_features() & 256.
PLUGIN_API const char* rml_get_window(const char* name)
{
	RmlWindow* w = FindRmlWindow(name);
	if (!w || w->windowSize.x <= 0)
		return nullptr;
	char buf[96];
	snprintf(buf, sizeof(buf), "%d,%d,%d,%d", (int)w->windowPos.x, (int)w->windowPos.y, (int)w->windowSize.x, (int)w->windowSize.y);
	g_returnBuffer = buf;
	return g_returnBuffer.c_str();
}

// ---------------------------------------------------------------------------------------------
// Native EQ nimbus (opt-in, client-side only). The client's own OP_AddNimbusEffect / OP_RemoveNimbusEffect
// code renders a spellsnew.eff effect (stage 2) on the local player; requests are queued and run in OnPulse.
// add: > 0 handle; -1 disabled after a fault, -2 client build not verified, -3 bad id.
// flags & 1 = autoclose: removed when rml_nimbus_status() is not called for 5 s (script stopped).
PLUGIN_API int rml_nimbus_add(int effect_id) { return Nimbus_Add(effect_id, 0); }
PLUGIN_API int rml_nimbus_add_ex(int effect_id, int flags) { return Nimbus_Add(effect_id, flags); }
PLUGIN_API int rml_nimbus_remove(int handle_or_id) { return Nimbus_Remove(handle_or_id); }
PLUGIN_API const char* rml_nimbus_status() { return Nimbus_Status(); }
// aura rework (feature 32768): a second, independent native slot for the ground aura (slot 1); slot 0 = the calls above.
PLUGIN_API int rml_nimbus_add_slot(int slot, int effect_id, int flags) { return Nimbus_AddSlot(slot, effect_id, flags); }
PLUGIN_API int rml_nimbus_remove_slot(int slot) { return Nimbus_RemoveSlot(slot); }
PLUGIN_API const char* rml_nimbus_status_slot(int slot) { return Nimbus_StatusSlot(slot); }
// proc rework (feature 65536): a short native spell effect on any spawn (spawn_id 0 = you, else e.g. your target), so EQ
// itself wraps that body in the record's stage-2 emitters in the 3D world; taken off again after ms (300..8000).
PLUGIN_API int rml_nimbus_burst(int spawn_id, int effect_id, int ms) { return Nimbus_Burst(spawn_id < 0 ? 0u : (uint32_t)spawn_id, effect_id, ms); }
PLUGIN_API int rml_nimbus_burst_ex(int spawn_id, int effect_id, int ms, int flags) { return Nimbus_BurstEx(spawn_id < 0 ? 0u : (uint32_t)spawn_id, effect_id, ms, flags); }
PLUGIN_API int rml_nimbus_burst_stop() { return Nimbus_BurstStop(); }
PLUGIN_API const char* rml_nimbus_burst_status() { return Nimbus_BurstStatus(); }
// t468 (feature 131072): NEW proc effects that are not in spellsnew.eff: emitters added to the client's emitter collection in
// memory on first use, played with ids base_id + 1 .. base_id + count through rml_nimbus_burst(_ex). One status line.
PLUGIN_API const char* rml_nimbus_custom_info() { return Nimbus_CustomInfo(); }
// t469: Proc FX Brightness / Size (percent, 25..300) for the custom effects (written into their emitter records on the next play;
// Brightness >= 150 also layers EQ's own records twice). Returns 1. Feature 262144.
PLUGIN_API int rml_nimbus_custom_tune(int bright_pct, int size_pct) { return Nimbus_CustomTune(bright_pct, size_pct); }
// ---------------------------------------------------------------------------------------------
// Actor material tint (proof test, client-side only, local player). Calls EQGraphics' own
// CActor::SetMaterialTint(int index, const RGB*) (vftable 0x228) in OnPulse; see ActorMaterial.cpp.
// argb = 0xAARRGGBB. Returns > 0 queued, -1 disabled after a fault, -2 client build not verified, -3 bad arg, -4 queue full.
// rml_features() & 4096 = available. Results show up in rml_mat_status() after the next pulse.
PLUGIN_API int rml_mat_tint(int index, unsigned int argb) { return Mat_Tint(index, argb); }
PLUGIN_API int rml_mat_tint_all(unsigned int argb) { return Mat_TintAll(argb); }
PLUGIN_API int rml_mat_tint_slot(int slot, unsigned int argb) { return Mat_TintSlot(slot, argb); }
PLUGIN_API int rml_mat_reset() { return Mat_Reset(); }
// Attached actors (armour pieces such as the chest plate, shoulders, gauntlets; hair/beard) at attach point 0..27
// of the body actor. rml_mat_attach_find("CHEST") -> index (point or definition name contains text), -1 none.
PLUGIN_API int rml_mat_tint_attach(int attach_index, int mat_index, unsigned int argb) { return Mat_TintAttach(attach_index, mat_index, argb); }
PLUGIN_API int rml_mat_tint_attach_all(int attach_index, unsigned int argb) { return Mat_TintAttachAll(attach_index, argb); }
PLUGIN_API int rml_mat_attach_find(const char* text) { return Mat_AttachFind(text); }
PLUGIN_API const char* rml_mat_status() { return Mat_Status(); }

// Ornament model swap (proof test): client-side only, local player. Replaces the model attached at body attach
// point `attach_index` (see rml_orn_status for indices, e.g. 11 = chest, 3 = right hand) with a stock model tag
// ("IT14118" or "IT14118_ACTORDEF"), using the engine's own ChangeBoneAttachment (the call eqgame makes on a wear
// change; loads the model from its .eqg on demand). rml_features() & 8192 = available. Queued: runs on the next
// pulse. rml_orn_restore(-1) restores all; unload restores; zoning forgets (the game re-attaches real gear).
PLUGIN_API int rml_orn_set(int attach_index, const char* tag) { return Orn_Set(attach_index, tag); }
PLUGIN_API int rml_orn_restore(int attach_index) { return Orn_Restore(attach_index); }
PLUGIN_API int rml_orn_loaded(const char* tag) { return Orn_Loaded(tag); }
PLUGIN_API const char* rml_orn_status() { return Orn_Status(); }
// chestfix: a swapped HeroForge piece now also gets what eqgame's own wear update gives it (second chest point 7,
// body skin region hide, attach matrix). rml_orn_opts(mask) 1|2|4 switches those (default 5, -1 reads), rml_orn_diag() reports.
PLUGIN_API int rml_orn_opts(int mask) { return (int)Orn_Opts(mask); }
PLUGIN_API const char* rml_orn_diag() { return Orn_Diag(); }
// matfix: body region material swap (1 chest 2 upper arms 3 forearms 4 hands 5 legs 6 feet; material 0-3 or 17-23, -1 restore)
// through eqgame's own SetArmorTexture; client-only, restored on rml_orn_restore(-1), unload and zone.
PLUGIN_API int rml_orn_mat(int region, int material) { return Orn_Mat(region, material); }
