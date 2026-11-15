# MQ2RmlUi (x64 / DX11)

RmlUi (HTML/CSS-style UI) host for MacroQuest on the 64-bit EverQuest clients. Lua scripts drive it through
LuaJIT FFI calls to the plugin's `rml_*` C exports: windows, data models, a GPU canvas element (lines, sprites,
bloom), GPU particle emitters (`rml_fx_*`), world-to-screen helpers, and (optional) the client's own nimbus
effects on your character (`rml_nimbus_*`). See `CANVAS_API.md` and `FX_API.md`.

Contents: [Getting Started](#getting-started) · [Creating a new RmlUi window](#creating-a-new-rmlui-window-lua--rmlrcss) · [ImGui comparison](#12-comparison-with-mqs-imgui-lua-same-window-both-ways) · [Building](#building-standard-macroquest-plugin-build) · [Native nimbus](#native-nimbus-client-specific-optional)

## Getting Started

```txt
/plugin MQ2RmlUi
/lua run rmlfx_test
```

The plugin draws nothing by itself; it is a host for Lua UIs.

### Commands

None. Everything is driven from Lua via FFI, for example:

```lua
local ffi = require('ffi')
ffi.cdef[[ int rml_api_version(); int rml_ready(); ]]
local rml = ffi.load('MQ2RmlUi')
print(rml.rml_api_version(), rml.rml_ready())
```

### Files written

* `Logs\rmlui_canvas.log` - performance and diagnostic lines (canvas draw times, nimbus status).

## Creating a new RmlUi window (Lua + RML/RCSS)

This section is a developer guide. Every function name, signature, event string and file path below comes from
this folder's source (`src\MQ2RmlUi.cpp`, `src\ElementCanvas.cpp`, `src\FxSystem.cpp`) or from the working
Lua consumers in the MacroQuest `lua\` folder (`lua\rmlui\init.lua`, `lua\rmlui\host.lua`, `lua\rmlui\ext.lua`,
`lua\rmlui\theme\window.rml` / `window.rcss`, `lua\combatfx`, `lua\rmlfps`, `lua\pfwiki`, `lua\gmconsole`,
`lua\rmlfx_test`). Anything that could not be confirmed from source is marked **(unverified)**.

### 1. How the pieces fit

```txt
MQ2RmlUi.dll  (this plugin, loaded by MQ)
  |  72 C exports named rml_*  (PLUGIN_API in src\*.cpp)
  v
LuaJIT FFI    ffi.cdef[[ ... ]] + ffi.load('MQ2RmlUi')
  |  usually through the shared wrapper  lua\rmlui\init.lua   -> require('rmlui')
  |  optional helpers                    lua\rmlui\host.lua   -> require('rmlui.host')
  |                                      lua\rmlui\ext.lua    -> require('rmlui.ext')  (keys, data models)
  v
your script   lua\yourwindow\init.lua
  |  rmlui.open(name, 'yourwindow/ui/main.rml', opts)   -> one Rml::Context + one document per window name
  v
RML document  lua\yourwindow\ui\main.rml   (HTML-like markup; ids, action="...", drag="1", resize="1")
RCSS          lua\yourwindow\ui\main.rcss  (CSS-like styles; linked from the .rml)
```

What happens each frame (from the header comment and `OnUpdateImGui` / `DrawWindow` in `src\MQ2RmlUi.cpp`):

1. `OnUpdateImGui` draws every visible window as a borderless ImGui window titled `<name>##mq2rmlui`. ImGui owns
   focus, z-order and "mouse is over UI"; the plugin forwards mouse/keys into RmlUi and calls `Context::Update`
   (this is where click events are produced).
2. Your Lua `mq.imgui.init` callback runs in the same ImGui frame: drain events with `win:events()` (wraps
   `rml_poll`) and write the DOM (`win:text`, `win:style`, ...).
3. `GraphicsSceneRender` paints the RmlUi document into an offscreen D3D11 render target, which the ImGui window
   shows as an image.

Rule from the plugin and wrapper comments: **poll and update from the `mq.imgui.init` callback, not from the
`mq.delay` loop**. Polling from the delay loop is "a different thread/timing than OnUpdateImGui, which is why
buttons feel dead or fire a frame late" (`lua\rmlui\init.lua`).

### 2. Prerequisites

* `/plugin MQ2RmlUi` loaded (64-bit client only). `rmlui.open` calls `ensure()`, which runs
  `/squelch /plugin MQ2RmlUi noauto` and waits up to 3 s if the plugin is not loaded. `mq.delay` is illegal
  inside `mq.imgui.init`, so make the **first** `rmlui.open` call from the script body, not from the callback.
* The wrapper requires `rml_api_version() >= 2`. This source reports **5**.
* **The DLL stays locked while any Lua script has it `ffi.load`-ed.** To replace `plugins\MQ2RmlUi.dll`:
  `/lua stop` (all scripts, otherwise FFI keeps the DLL loaded), `/plugin MQ2RmlUi unload`, copy the new
  DLL, then `/plugin MQ2RmlUi`. (`rml_*` calls are written to be safe when the plugin is not initialized: they
  return 0 / NULL.)

### 3. Recommended folder layout

Same layout as `lua\pfwiki` (`init.lua` + `ui\main.rml` + `ui\*.rcss`) and `lua\combatfx` (`init.lua` + `ui\*.rml/.rcss`):

```txt
lua\
  rmlui\                 shared wrapper + theme (already there, do not copy it into your folder)
    init.lua             require('rmlui')
    host.lua             require('rmlui.host')
    ext.lua              require('rmlui.ext')
    theme\window.rml     window chrome template (title bar, pin, collapse, close, resize grip)
    theme\window.rcss    chrome styles + base display rules + .btn / input.text / input.checkbox / input.range
  yourwindow\
    init.lua             /lua run yourwindow
    ui\main.rml
    ui\main.rcss
```

Paths: `rmlui.open` resolves a relative path against `mq.luaDir` (the plugin's `rml_open` would also prefix
`<MQ root>/lua/`). Inside an `.rml`, `href`/`src` are relative to the `.rml` file itself, so from
`lua\yourwindow\ui\main.rml` the chrome template is `../../rmlui/theme/window.rml` (exactly what
`lua\pfwiki\ui\main.rml` uses).

### 4. Complete minimal example: `hpwatch`

A window that shows your name and HP with a bar, a Ping button with a click counter, a text box, a Clear button,
the template's close (X) button, and a saved position. Built only from the patterns above.

`lua\hpwatch\ui\main.rml`

```xml
<rml>
<head>
	<title>HP Watch</title>
	<link type="text/template" href="../../rmlui/theme/window.rml"/>
	<link type="text/rcss" href="main.rcss"/>
</head>
<body template="window">
	<div id="hw" class="hw">
		<div class="row">
			<span id="who" class="who">-</span>
			<span class="grow"></span>
			<span id="hp" class="hpnum">0%</span>
		</div>
		<div class="hpbar"><div id="hpfill" class="hpfill"></div></div>
		<div class="row">
			<div id="ping" class="btn primary" action="ping">Ping</div>
			<div id="clear" class="btn" action="clear">Clear</div>
			<span class="muted">clicks: <span id="clicks">0</span></span>
		</div>
		<input id="note" class="text" type="text" value=""/>
	</div>
</body>
</rml>
```

* `<title>` is copied into the template's `#window-title` when the document loads (`LoadDocument`).
* Your markup is placed into the template's `#window-content` (`content="window-content"` in `window.rml`).
* `action="ping"` makes a click on that element (or a child) arrive in Lua as `ev.action == 'ping'`.
* `class="btn"`, `class="btn primary"` and `input class="text"` are styled by `rmlui\theme\window.rcss`.

`lua\hpwatch\ui\main.rcss`

```css
/* window.rcss (linked by the template) already sets div/span display, body font "Segoe UI" 13dp and .btn styles */
.hw { display: flex; flex-direction: column; gap: 8dp; }
.hw .row { display: flex; flex-direction: row; align-items: center; gap: 8dp; }
.hw .grow { flex: 1; }
.hw .who { font-weight: bold; color: #f5e6b8; }
.hw .hpnum { font-weight: bold; }
.hw .hpbar { height: 10dp; border-radius: 5dp; background-color: #ffffff14; }
.hw .hpfill { height: 100%; width: 0%; border-radius: 5dp; decorator: horizontal-gradient(#17603a #6fe39a); }
.hw .hpfill.low { decorator: horizontal-gradient(#a8202e #ff5a4a); }
.hw .muted { color: #8d97ad; font-size: 11.5dp; }
.hw input.text { width: 100%; }
```

`lua\hpwatch\init.lua`

```lua
--[[ hpwatch - minimal MQ2RmlUi window.  /lua run hpwatch   stop: the window's X or /lua stop hpwatch ]]
local mq = require('mq')
local rmlui = require('rmlui')                 -- lua\rmlui\init.lua (LuaJIT FFI wrapper)

local NAME = 'HpWatch'                         -- window name: the key for every rml_* call
local W, H = 340, 230                          -- host size; the template frame is inset 22dp on each side
local CFG = (mq.configDir or '.') .. '/hpwatch.ini'
local TAG = '\at[hpwatch]\ax '

-- saved position (x=/y= lines, the same idea as config\rmlfps.ini)
local function load_pos()
    local f = io.open(CFG, 'r'); if not f then return nil end
    local t = {}
    for l in f:lines() do local k, v = l:match('^(%w+)=(%-?%d+)'); if k then t[k] = tonumber(v) end end
    f:close()
    return t.x, t.y
end
local function save_pos(x, y)
    local f = io.open(CFG, 'w'); if not f then return end
    f:write('x=', x, '\n', 'y=', y, '\n'); f:close()
end

-- open ONCE from the script body (ensure() may load the plugin and mq.delay, illegal in the imgui callback)
local win, err = rmlui.open(NAME, 'hpwatch/ui/main.rml', { width = W, height = H, x = 200, y = 200 })
if not win then print(TAG .. 'open failed: ' .. tostring(err)); return end
win:reload()                                   -- plugin caches documents/style sheets; re-read edits from disk
local sx, sy = load_pos()
if sx then win:place(sx, sy, W, H) end

local running = true
local clicks, note = 0, ''

local function handle(ev)
    if ev.type == 'click' then
        if ev.action == 'window:close' then    -- template X; the plugin has already hidden the window
            running = false
        elseif ev.action == 'ping' then
            clicks = clicks + 1
            print(TAG .. 'ping #' .. clicks .. (note ~= '' and (' - ' .. note) or ''))
        elseif ev.action == 'clear' then
            note = ''
            win:set_value('note', '')
        end
    elseif ev.type == 'change' and ev.id == 'note' then
        note = ev.value or ''
    elseif ev.type == 'windowmoved' then       -- feature bit 256: sent when a drag/resize is released
        local x, y = tostring(ev.value):match('^(%-?%d+),(%-?%d+)')
        if x then save_pos(tonumber(x), tonumber(y)) end
    end
end

-- per-frame tick, inside MQ's ImGui frame (same place an ImGui script draws)
local function tick()
    if not win:is_open() then running = false; return end
    for ev in win:events() do handle(ev) end   -- drains rml_poll; also the autoclose heartbeat
    local hp = tonumber(mq.TLO.Me.PctHPs()) or 0
    win:text('who', mq.TLO.Me.CleanName() or '?')  -- wrapper skips the FFI call if the value is unchanged
    win:text('hp', hp .. '%')
    win:style('hpfill', 'width', hp .. '%')
    win:class('hpfill', 'low', hp < 35)
    win:text('clicks', clicks)
end

mq.imgui.init(NAME, function()
    local ok, e = pcall(tick)                  -- an error escaping an imgui callback terminates the script
    if not ok then print(TAG .. tostring(e)) end
end)

while running do
    mq.doevents()
    mq.delay(50)
end

-- normal exit (X button). On a plain /lua stop this code never runs; the wrapper's GC finalizer
-- closes every window this Lua state opened.
mq.imgui.destroy(NAME)
win:close()
print(TAG .. 'stopped.')
```

How each requirement maps to the API:

| Need | How (source) |
|---|---|
| Open document | `rmlui.open(name, path, { width, height, x, y, autoclose, clickthrough, theme })` -> `rml_open` (+ `rml_set_default_pos` when `x`/`y` given). Returns a `Window` or `nil, err`. |
| Re-read edited files | `win:reload()` -> `rml_reload` (clears RmlUi style sheet + template caches, reloads the document). `rml_open` on the same name + path just returns 1 without reloading. |
| Show / hide | `win:show(true|false)` -> `rml_show`. Hidden windows keep their document and state. |
| Close button | The template's X has `action="window:close"`: the plugin hides the window itself and still sends the click to Lua, so the script decides (stop, or `win:close()`). |
| Close / cleanup | `win:close()` -> `rml_close` (destroys context + document). `rmlui.close(name)`, `rmlui.close_all()`. On `/lua stop` a `ffi.gc` guard in the wrapper closes every window that Lua state opened. |
| Autoclose backup | `opts.autoclose` defaults to **true** in `rmlui.open` (flag 1): the plugin destroys the window if `rml_poll` is not called for 5 s (held during zoning + 10 s grace). `rmlui.host.open` defaults it to **false**. |
| Click-through overlay | `opts.clickthrough = true` (flag 2): the window never takes mouse input (`lua\rmlfx_test`, combatfx overlay). |
| Clicks | Element (or ancestor) with `action="..."` and/or `id`. Event `{ type='click', id, action, value='', button=0 }`. |
| Text inputs | `change` / `submit` events with `ev.id` and `ev.value`; read with `win:value(id)`, write with `win:set_value(id, v)`. |
| Per-frame text/value updates | `win:text(id, s)` (escaped), `win:rml(id, markup)` (raw inner RML), `win:style(id, prop, v)` (`''` removes), `win:class(id, cls, on)`, `win:attr(id, name, v)` (`nil` removes). `id = 'body'` targets the document root. The wrapper caches the last value per id, so calling them every frame only crosses FFI on change. |
| Position | `win:place(x, y, w, h)` -> `rml_set_window` (applied next frame with `ImGuiCond_Always`; `x/y < 0` or `w/h <= 0` = leave that part alone). First-run default: `opts.x/opts.y` -> `rml_set_default_pos` (`ImGuiCond_FirstUseEver`). Otherwise ImGui's own saved settings keep the host window's spot (`combatfx\core.lua`: "the plugin's own ImGui memory keeps them (all characters)"). |
| Save position yourself | DLL feature bit 256: `windowmoved` event (`ev.action` = `move`/`resize`, `ev.value` = `"x,y,w,h"`) on drag release, and `rml_get_window(name)` -> `"x,y,w,h"` (raw FFI, see `lua\rmlfps\init.lua` / `lua\combatfx\core.lua`). |
| Dragging / resizing | `drag="1"` on an element moves the window, `resize="1"` resizes it (min 120x60). Elements with `action`, text inputs and `<button>` never start a drag. While pinned (`window:pin`) this source starts no drag at all (move or resize). |
| Keyboard | Focused text inputs capture the keyboard automatically. For other keys: `rmlui.ext.key_mode(win, 0/1/2)` (see 6). |
| Debugging | `win:debugger(true)` -> `rml_debugger` opens the RmlUi debugger on that window's context. |

#### Variant: a plain document without the chrome template

`lua\combatfx\ui\*.rml` and `lua\rmlfps\fps.rml` do not use the template. Then:

* open with `theme = false` (otherwise `rmlui.open` toggles `theme-*` classes on `body` and writes a logo into `#window-logo`),
* put `drag="1"` on your own title bar element and your own close element with any `action` (combatfx uses `action="close"`),
* add the base display rules yourself (RmlUi has no default HTML stylesheet), e.g. from `cfxui.rcss`:
  `div { display: block; } span { display: inline; } img { display: inline-block; }`,
* set a font on `body` (`font-family: "Segoe UI";`).

#### Variant: the shared host helper (`require('rmlui.host')`)

`lua\pfwiki\rml_ui.lua` uses `host.open(name, path, opts)` + `host.tick(win, handlers)`. Differences from
`rmlui.open` (from `host.lua`): `autoclose` defaults to **false**; it always calls `win:reload()` (unless
`opts.reload == false`); applies the theme, optional `opts.title`, the glass toggle; and **always** calls
`win:place(opts.x or 160, opts.y or 100, opts.width or 900, opts.height or 720)`, so it overrides any remembered
position. `host.tick` handles `click`/`dblclick` (`window:close` -> `handlers.close`, `ui:glass`,
`handlers[action]` or `handlers.action(action, ev)`), `change`/`submit` -> `handlers.change`, then
`handlers.update(win)`. It drops `windowmoved`, `keydown`/`keyup` and `modelchange`; use `rmlui.ext.tick` (same
handlers plus `key`/`model`) or your own `win:events()` loop if you need those.

### 5. Events (`rml_poll` / `win:events()`)

`rml_poll(name)` returns one queued event as `"type\tid\taction\tvalue\tbutton"` (or NULL); the wrapper splits it
into `{ type, id, action, value, button }`. Tabs/newlines inside fields are replaced by spaces. The queue keeps at
most 256 events per window (oldest dropped), so drain it every frame.

| type | id | action | value | button | Produced by |
|---|---|---|---|---|---|
| `click` | nearest id on target/ancestors | nearest `action` | `''` | `0` | left mouse **release** over the element (ImGui-style), only if an id or action was found |
| `dblclick` | same | same | `''` | `0` | left double-click |
| `change` | target id | nearest action | form value | `''` | RmlUi `change` (inputs, checkboxes, ranges, selects). `lua\gmconsole` treats it as the live value of a text box. |
| `submit` | target id | nearest action | form value | `''` | RmlUi `submit` (combatfx accepts it as "Apply") **(when exactly RmlUi fires it for a bare input: unverified)** |
| `keydown` / `keyup` | focused element id (`''` = window) | `''` | ImGui key name (`A`, `F5`, `Keypad3`, `LeftCtrl`...) | mods: 1 ctrl, 2 shift, 4 alt | only with `rml_key_mode` >= 1 and the window focused |
| `modelchange` | model name | key | new value | `''` | two-way data bindings (`data-value`, `data-checked`) |
| `windowmoved` | `''` | `move` / `resize` | `"x,y,w,h"` | `0` | drag/resize released (feature bit 256) |

`window:*` actions are also handled by the plugin itself: `window:close` hides, `window:collapse` collapses
(also double-click on `#window-titlebar`), `window:pin` toggles pin and the `pinned` body class. The plugin also
maintains the body classes `focused`, `collapsed`, `pinned`.

Right click: this source emits **no** right-button or `mousedown` events (`DocumentListener` returns early for
`mousedown`; `EmitClickFromElement` is only called with button 0). `combatfx\ui.lua` checks
`ev.type == 'mousedown' and ev.button == 1`, which nothing in this source produces **(right click handling
unverified)**.

### 6. Keyboard and input focus

From `HandleInput` / `IsTextInput`:

* While an `<input>` text field (any type except range/button/checkbox/radio/submit/reset/hidden/file/image/color),
  `<textarea>` or `<select>` is focused in the focused window, the plugin sets ImGui `WantCaptureKeyboard` and
  `WantTextInput`, so EQ does not receive the typing (no movement, no hotkeys). Characters come from ImGui's input
  queue; editing keys forwarded to RmlUi are Backspace, Delete, arrows, Home/End, PageUp/PageDown, Enter,
  KeypadEnter, Tab, Escape, A, C, V, X, Z (Ctrl shortcuts) and F8.
* When the window loses ImGui focus, the focused element is blurred, so keys go back to EQ.
* `rmlui.ext.key_mode(win, mode)` -> `rml_key_mode`: `0` off, `1` observe (you get `keydown`/`keyup`, EQ still
  gets the keys), `2` capture (EQ does not get keys while this window is focused). `ext.capture(win, fn)` arms a
  one-shot "press a key to bind" (Escape cancels) and restores the previous mode.
* Clipboard uses ImGui's clipboard.

### 7. Data models (optional, `require('rmlui.ext')`)

From `lua\rmlui\ext.lua` and `rml_model_*`: create the model and set every key **before** the document loads (or
`win:reload()` afterwards), because bindings are resolved at load time.

```lua
local ext = require('rmlui.ext')
local m = ext.model('mywin', 'party')        -- nil when the DLL has no models (feature bit 128)
if m then
    m:set('title', 'Raid')                    -- string / number / boolean (type 0 / 1 / 2)
    m:list('members', { { 'Tanky', 'WAR', 88 }, { 'Healz', 'CLR', 35 } })   -- rows x cols of strings
end
local win = rmlui.open('mywin', 'myscript/ui.rml', { width = 320, height = 240 })
```

```xml
<div data-model="party">{{title}}
  <div data-for="p : members" data-class-low="p[2] < 50">{{p[0]}} {{p[2]}}%</div>
  <input type="text" data-value="title"/>   <!-- edits arrive as ev.type == 'modelchange' -->
</div>
```

Limits in source: lists up to 4096 rows x 64 columns; a key is either a scalar or a list, not both.

### 8. Lua wrapper reference (`require('rmlui')`, `lua\rmlui\init.lua`)

| Call | Does |
|---|---|
| `rmlui.ready()` | plugin loaded and `rml_ready() == 1` |
| `rmlui.open(name, path, opts)` | open/reuse window; `opts`: `width`, `height`, `x`, `y`, `autoclose` (default true), `clickthrough`, `theme` (`false` = none, default `'redguides'`) |
| `rmlui.init(name, fn)` / `rmlui.destroy(name)` | thin wrappers for `mq.imgui.init` / `mq.imgui.destroy` |
| `rmlui.close(name)` / `rmlui.close_all()` | close one window / every window this Lua state opened |
| `rmlui.load_font(path, fallback)` | `rml_load_font` (relative paths resolve against `mq.luaDir`) |
| `rmlui.render_caps()` | `rml_render_caps()` bitmask, 0 if unavailable |
| `rmlui.icon_src(kind, id, {file=})`, `export_icon`, `icon_ready`, `item_icon_img(id, cls)`, `spell_icon_img(id, cls)`, `set_uifiles_path(path)` | EQ item/spell icons (`<img src="eq://item/1234"/>`, `<img src="eq://spell/42"/>`) |
| `win:text / rml / style / class / attr` | DOM writes (cached, see table above) |
| `win:set_value(id, v)` / `win:value(id)` | form control value (for non-controls `value` returns inner RML) |
| `win:events()` / `win:poll()` | iterator / array of events |
| `win:show(v)`, `win:place(x,y,w,h)`, `win:reload()`, `win:is_open()`, `win:debugger(v)`, `win:close()` | see above |
| `win:theme(name)`, `win:brand()` | `theme-redguides`, `azure`, `violet`, `ember`, `jade`, `rose` body classes + logo |

`require('rmlui.ext')`: `features()`, `has(bit)`, `has_keys()`, `has_models()`, `key_mode(win, mode)`,
`parse_key(ev)`, `capture(win, fn, restore)`, `cancel_capture(win)`, `capturing(win)`, `dispatch(win, ev, handlers)`,
`tick(win, handlers)`, `model(win, name)` -> `m:set(key, v)`, `m:get(key)`, `m:list(key, rows, cols)`, `m:dirty(key)`.

`require('rmlui.host')`: `esc(s)`, `open(name, path, opts)`, `tick(win, handlers)`, `set_glass(win, on)`,
`toggle_glass(win)`, `bind_loop(imgui_name, on_frame, running_fn)`.

### 9. `rml_*` export reference (all 72)

Return convention: `int` functions return 1 on success, 0 on failure/unknown window or element. `const char*`
results point at one shared buffer: copy them (`ffi.string`) before the next call. `id` = element id; empty or
`"body"` = the document root. The wrapper declares the window/DOM/icon functions; declare others yourself with
`pcall(ffi.cdef, '...')` (one per function, as `ext.lua` does, to avoid redefinition errors).

Core / windows (`src\MQ2RmlUi.cpp`)

| Signature | Purpose |
|---|---|
| `int rml_api_version()` | API version (5) |
| `int rml_ready()` | 1 once RmlUi initialised |
| `int rml_render_caps()` | renderer caps: 1 gradients, 2 filters, 4 layers, 8 box-shadow, 16 backdrop-filter, 32 mask-image (this port returns 0) |
| `int rml_features()` | render caps \| 64 keys \| 128 models \| 256 drag patch (`windowmoved`, `rml_get_window`) \| 512 `rml_fx_*` \| 1024 fx bloom mask \| 2048 native nimbus available |
| `int rml_open(const char* name, const char* path, int width, int height, int flags)` | create/reuse window `name`, load `path` (flags 1 autoclose, 2 click-through) |
| `int rml_close(const char* name)` | destroy window |
| `int rml_reload(const char* name)` | clear style sheet/template caches and reload the document |
| `int rml_show(const char* name, int show)` | show/hide |
| `int rml_is_open(const char* name)` | 1 if the window has a document |
| `int rml_set_window(const char* name, float x, float y, float width, float height)` | move/resize next frame |
| `int rml_set_default_pos(const char* name, float x, float y)` | first-use position |
| `const char* rml_get_window(const char* name)` | current `"x,y,w,h"` or NULL |
| `int rml_set_rml(const char* window, const char* id, const char* rml)` | set inner RML (raw markup) |
| `int rml_set_text(const char* window, const char* id, const char* text)` | set inner text (escapes `& < > "`) |
| `int rml_set_attr(const char* window, const char* id, const char* attr, const char* value)` | set attribute (NULL removes) |
| `int rml_set_class(const char* window, const char* id, const char* cls, int on)` | toggle class |
| `int rml_set_style(const char* window, const char* id, const char* property, const char* value)` | set inline property (empty/NULL removes) |
| `int rml_set_value(const char* window, const char* id, const char* value)` | set form control value |
| `const char* rml_get_value(const char* window, const char* id)` | form value, or inner RML for other elements |
| `const char* rml_poll(const char* name)` | next event (see 5); also the autoclose heartbeat |
| `int rml_key_mode(const char* name, int mode)` | 0 off, 1 observe, 2 capture |
| `int rml_model_create(const char* window, const char* model)` | create data model (creates the window if needed) |
| `int rml_model_set(const char* window, const char* model, const char* key, const char* value, int type)` | scalar; type 0 string, 1 number, 2 bool |
| `const char* rml_model_get(const char* window, const char* model, const char* key)` | read scalar |
| `int rml_model_list_size(const char* window, const char* model, const char* key, int rows, int cols)` | declare/resize list |
| `int rml_model_list_set(const char* window, const char* model, const char* key, int row, int col, const char* value)` | set one cell (0-based) |
| `int rml_model_dirty(const char* window, const char* model, const char* key)` | mark key (or all if empty) dirty |
| `int rml_load_font(const char* path, int fallback)` | load a font face |
| `int rml_debugger(const char* name, int show)` | RmlUi debugger for a window |
| `int rml_set_uifiles_path(const char* path)` | EQ uifiles folder for icons |
| `const char* rml_icon_src(const char* kind, int id, int prefer_file)` | `eq://` source or exported PNG path |
| `const char* rml_export_icon(const char* kind, int id, const char* out_path)` | export icon PNG |
| `int rml_icon_ready(const char* kind, int id)` | icon atlas cell can be sampled now |
| `int rml_nimbus_add(int effect_id)` / `int rml_nimbus_add_ex(int effect_id, int flags)` | native EQ nimbus on your character (flags 1 = autoclose); >0 handle, -1 disabled, -2 client not verified, -3 bad id |
| `int rml_nimbus_remove(int handle_or_id)` | remove nimbus |
| `const char* rml_nimbus_status()` | nimbus status text (also its autoclose heartbeat) |

Canvas (`src\ElementCanvas.cpp`; details in `CANVAS_API.md`), used with a `<canvas id="...">` element

| Signature | Purpose |
|---|---|
| `int rml_canvas_clear(const char* win, const char* id)` | clear queued geometry |
| `int rml_canvas_submit(const char* win, const char* id, const float* verts, int count, int mode)` | vertices `x,y,r,g,b,a` + primitive/flag mode |
| `int rml_canvas_line_width(const char* win, const char* id, float width)` | line thickness |
| `int rml_canvas_circle(const char* win, const char* id, float x, float y, float radius, float r, float g, float b, float a, int segments, int mode)` | circle helper |
| `int rml_canvas_arc(const char* win, const char* id, float x, float y, float radius, float a0, float a1, float r, float g, float b, float a, int mode)` | arc helper |
| `int rml_canvas_size(const char* win, const char* id, float* out_w, float* out_h)` | canvas size |
| `int rml_canvas_rect(const char* win, const char* id, float* x, float* y, float* w, float* h)` | canvas rect |
| `float rml_canvas_draw_ms(const char* win, const char* id)` | last draw time |
| `int rml_canvas_perf(char* out, int cap)` / `int rml_canvas_stats(const char* win, const char* id, char* out, int cap)` | perf / stats text |
| `int rml_canvas_probe()` | arm a one-shot diagnostic dump |
| `int rml_canvas_bg(const char* win, const char* id, int style, float time, float energy, float beat)` | procedural background |
| `int rml_canvas_trail(const char* win, const char* id, float decay)` | trail/persistence |
| `int rml_canvas_bloom(const char* win, const char* id, float strength)` | bloom strength |
| `int rml_canvas_sprites(const char* win, const char* id, const float* data, int count, int mode)` | soft sprite batch |
| `int rml_canvas_sprite(const char* win, const char* id, float x, float y, float rx, float ry, float r, float g, float b, float a, int mode)` | one sprite |
| `int rml_canvas_texture_load(const char* win, const char* id, const char* path)` | load sprite texture |
| `int rml_canvas_sprites_ex(const char* win, const char* id, const float* data, int count)` | textured sprite batch |
| `int rml_canvas_sprite_ex(const char* win, const char* id, float x, float y, float sx, float sy, float angle, float r, float g, float b, float a, int tex_id, int mode)` | one textured sprite |
| `int rml_world_to_screen(float x, float y, float z, float* sx, float* sy)` | world -> screen |
| `int rml_spawn_to_screen(int spawnId, float headOffset, float* sx, float* sy)` | spawn -> screen |
| `int rml_world_to_overlay(float x, float y, float z, float ovW, float ovH, float* sx, float* sy)` | world -> overlay pixels |
| `int rml_spawn_to_overlay(int spawnId, float heightFrac, float ovW, float ovH, float* sx, float* sy)` | spawn -> overlay pixels |
| `int rml_canvas_lookat(float* out16, float ex, float ey, float ez, float ax, float ay, float az, float ux, float uy, float uz, float fov_y_deg, float aspect, float znear, float zfar)` | build view-projection matrix |
| `int rml_canvas_project(float x, float y, float z, const float* m16, float vp_w, float vp_h, float* out_x, float* out_y)` | project one point |
| `int rml_canvas_project_n(const float* xyz, int n, const float* m16, float vp_w, float vp_h, float* out_xy)` | project many points |

Particles (`src\FxSystem.cpp`; details in `FX_API.md`)

| Signature | Purpose |
|---|---|
| `int rml_fx_create(const char* win, const char* id, const float* desc, int n)` | create emitter on a canvas, returns handle |
| `int rml_fx_update(int h, const float* desc, int n)` | update descriptor |
| `int rml_fx_anchor(int h, float x, float y, float px_per_unit, float depth01)` | move emitter |
| `int rml_fx_exclude(const char* win, const char* id, const float* p, int n)` | exclusion shape |
| `int rml_fx_burst(int h, int count)` | burst |
| `int rml_fx_stop(int h, int fade_out)` / `int rml_fx_destroy(int h)` | stop / free |
| `int rml_fx_mode(int mode)` | GPU / CPU path |
| `int rml_fx_stats(int h, char* out, int cap)` | stats text |

### 10. RML / RCSS gotchas (evidenced in code)

* **No default HTML stylesheet.** `window.rcss` sets `body, div, p, h1.. { display: block; }` and
  `span, b, i, em, strong { display: inline; }`; documents without the template must do it themselves
  (`cfxui.rcss`: `div { display: block; } span { display: inline; } img { display: inline-block; }`).
* **Fonts: the `font-family` must name a loaded face.** The plugin loads `segoeui.ttf`, `segoeuib.ttf`,
  `seguisb.ttf`, `segoeuii.ttf`, `segoeuil.ttf` ("Segoe UI"), fallbacks `seguisym.ttf` and `seguiemj.ttf`, `arial.ttf`
  only if no Segoe face loaded, and `SegoeIcons.ttf` / `segmdl2.ttf` as family `Icons` (title bar glyphs). The
  wrapper additionally loads `consola.ttf` / `consolab.ttf` (Consolas); its comment: Consolas "was never loaded
  (MQ2RmlUi spam + click crash)". Any other family (some existing RCSS uses `Georgia`) must be loaded with
  `rmlui.load_font('C:/Windows/Fonts/<file>.ttf')` first. Only `.ttf` files are loaded anywhere in the source;
  OTF/WOFF/WOFF2 support and whether `seguiemj.ttf` draws colour emoji are **unverified**.
* **Renderer is the core path only.** `RenderInterface_DX11::GetRenderCaps()` returns 0 and `CompileShader`,
  `CompileFilter`, `PushLayer` are stubs. So shader decorators (`linear-gradient`, `repeating-linear-gradient`, ...),
  `filter`, `backdrop-filter`, `box-shadow` and `mask-image` draw nothing in this build (`rmluidemo_pro` uses
  `linear-gradient` and is affected). What working windows use: `decorator: vertical-gradient(a b)` /
  `horizontal-gradient(a b)`, `ninepatch(...)` spritesheets, images, `border-radius`, `opacity`, `transform`,
  `transition`, `@keyframes`. Probe with `rmlui.render_caps()`.
* **Scroll containers need a definite height.** `overflow: hidden auto` only scrolls when the box has a fixed
  `height` or absolute `top`/`bottom`. The t363 fix (`combatfx\ui\cfxui.rcss`, `.nlist`) is: `box-sizing:
  border-box; height: 140px; overflow: hidden auto; padding-bottom: 8px; margin-bottom: 10px;` with the height
  chosen so the box ends above the search/footer, "so last rows can scroll into view" (`#spage` uses absolute
  `top`/`bottom` + `overflow: hidden auto; padding-right: 4px`). Working windows also style
  `scrollbarvertical`, `slidertrack`, `sliderbar` and zero-size `sliderarrowdec` / `sliderarrowinc`.
* **Rebuilding a list with `win:rml()` replaces its children** and resets its scroll position; `combatfx\ui.lua`
  does partial updates ("selecting a row / applying must not rebuild the list (keeps the scroll position)").
* **Escape user text.** `win:text` escapes; `win:rml` does not (use `require('rmlui.host').esc(s)` inside markup).
* **Clicks need an id or action** on the element or an ancestor, otherwise nothing is sent. `action` also stops a
  drag starting on that element.
* **Template frame inset:** `#window-frame` sits 22dp inside the host window on each side (room for the shadow),
  so content is smaller than `width`/`height`.
* **Styling the `<body>` with your own class:** scope styles with your own wrapper element (`.hw` above).
  `lua\pfwiki` sets `class="pf-wiki"` on `<body template="window">` and also re-applies it from Lua
  (`win:class('body', 'pf-wiki', true)`); whether the attribute survives the template on its own is **unverified**.
* **Idle windows are frozen** (`DrawWindow` / `OnGraphicsSceneRender`): a window only runs `Context::Update` and
  repaints while it is focused, hovered, being dragged, click-through, during the first paint and after a resize.
  A window that receives `<canvas>` submits keeps repainting for 0.4 s after each submit (or while it has a live
  `rml_fx_*` emitter), but `Update` still runs only in the interactive case. Per source, DOM changes such as the
  HP text in the example are therefore drawn when the mouse is next over the window or it has focus. Use
  `clickthrough = true` for a HUD that must stay live without input. **How this looks in game was not
  verified.**

### 11. Troubleshooting

| Symptom | Cause / fix (from source) |
|---|---|
| Copying the DLL fails (file in use) | A Lua state still has it `ffi.load`-ed: `/lua stop` every script, `/plugin MQ2RmlUi unload`, copy, `/plugin MQ2RmlUi`. |
| `open failed: MQ2RmlUi is not ready` | Plugin not loaded or `rml_ready() == 0`. `rmlui.open` tries `/plugin MQ2RmlUi noauto` once; call it from the script body. |
| `MQ2RmlUi API version N, this script expects >= 2` | Old DLL; replace it (see above). |
| Chat: `[MQ2RmlUi] failed to load '<path>'` / `could not open <path>` | Wrong path. Lua paths are relative to `mq.luaDir`; `href`/`src` inside the RML are relative to the RML file. |
| RmlUi warnings/errors in chat | The plugin echoes RmlUi warnings/errors to chat (max 12 per 5 s). Usual causes: unknown font family, bad RCSS, missing file. `win:debugger(true)` shows the element tree and styles. |
| Window vanishes about 5 s after opening | `autoclose` is on and `win:events()` (`rml_poll`) is not being called, e.g. the imgui callback stopped or errored. Plugin log line `autoclose win=<name> no poll for N s` in `Logs\rmlui_canvas.log`. |
| Script stops with "ImGui Failure" or a Lua stack trace | An error escaped the `mq.imgui.init` callback; MQ terminates the script. Wrap the tick in `pcall`. |
| Buttons dead or a frame late | Events polled from the `mq.delay` loop; poll from the imgui callback. (`lua\gmconsole` still ticks from its delay loop.) |
| Edits to .rml/.rcss don't show | Document/style sheet cache: call `win:reload()` after `rmlui.open`, as every consumer does. |
| Window off-screen | `win:place(x, y, w, h)`; `lua\gmconsole` exposes `/gmconsole reset` doing exactly that. |
| Values only change when the mouse is over the window | Idle freeze (section 10). |
| Zoning | The plugin holds autoclose while zoning (`OnBeginZone` .. `OnEndZone`/`OnZoned`, or game state not in game) plus 10 s grace and after any pulse stall > 1 s, so windows survive a zone. |
| Typing moves the character | Only real text inputs capture the keyboard (section 6); use `input type="text"`, `textarea` or `select`, or `key_mode` 2. |

### 12. Comparison with MQ's ImGui Lua (same window both ways)

The ImGui side below uses only bindings present in `src\plugins\lua` of this MacroQuest tree
(`bindings\lua_MQBindings.cpp`: `mq.imgui.init/destroy/exists`; `bindings\lua_ImGuiCore.cpp`: `ImGui.Begin`
returns `open, show`, `ImGui.End`, `SetNextWindowSize(x, y, cond)`, `PushStyleColor(col, r, g, b, a)`,
`PopStyleColor(n)`, `SameLine`; `bindings\lua_ImGuiWidgets.cpp`: `Text`, `Button`, `ProgressBar(fraction, sx, sy)`,
`InputText(label, text)` returns `text, changed`) and the pattern of `lua\mq\eval.lua` / `lua\examples\autoassist.lua`.

`lua\hpwatch_imgui\init.lua` (ImGui version of the same window)

```lua
local mq = require('mq')
local NAME = 'HpWatchImGui'
local open, show = true, true
local clicks, note = 0, ''

local function draw()                          -- runs every frame; the whole window is rebuilt each time
    if not open then return end
    ImGui.SetNextWindowSize(300, 150, ImGuiCond.FirstUseEver)
    open, show = ImGui.Begin('HP Watch##' .. NAME, open)   -- title-bar X sets open = false
    if show then
        local hp = tonumber(mq.TLO.Me.PctHPs()) or 0
        ImGui.Text(string.format('%s   %d%%', mq.TLO.Me.CleanName() or '?', hp))
        if hp < 35 then ImGui.PushStyleColor(ImGuiCol.PlotHistogram, 1, 0.35, 0.29, 1)
        else ImGui.PushStyleColor(ImGuiCol.PlotHistogram, 0.18, 0.66, 0.41, 1) end
        ImGui.ProgressBar(hp / 100, -1, 10)
        ImGui.PopStyleColor()
        if ImGui.Button('Ping') then
            clicks = clicks + 1
            print('[hpwatch] ping #' .. clicks .. (note ~= '' and (' - ' .. note) or ''))
        end
        ImGui.SameLine()
        if ImGui.Button('Clear') then note = '' end
        ImGui.SameLine()
        ImGui.Text('clicks: ' .. clicks)
        note = ImGui.InputText('##note', note)
    end
    ImGui.End()                                -- always paired with Begin (as eval.lua does)
end

mq.imgui.init(NAME, draw)
while open do
    mq.doevents()
    mq.delay(50)
end
mq.imgui.destroy(NAME)
```

Mapping (ImGui column from the MQ Lua bindings, RmlUi column from this plugin + `lua\rmlui`):

| Concern | MQ ImGui Lua | MQ2RmlUi (RML/RCSS + Lua) |
|---|---|---|
| Window creation / registration | `mq.imgui.init(name, draw)`; the window exists while `ImGui.Begin` is called each frame | `rmlui.open(name, 'dir/ui/main.rml', opts)` once (retained document) **plus** `mq.imgui.init(name, tick)` for polling/updates |
| Per-frame model | Immediate mode: every widget is re-issued every frame | Retained DOM: the tick only drains events and pushes changed values; markup and layout live in the .rml/.rcss |
| Text / value updates | `ImGui.Text(...)` with the current value | `win:text(id, v)`, `win:style(id, 'width', v .. '%')`, `win:class(id, cls, on)`, `win:set_value(id, v)` (cached, FFI only on change) |
| Buttons / clicks | `if ImGui.Button('Ping') then ... end` | `<div class="btn" action="ping">` + `for ev in win:events() do if ev.action == 'ping' ...` |
| Text input | `note = ImGui.InputText('##note', note)` | `<input id="note" class="text" type="text"/>` + `change` event / `win:value('note')` |
| Layout / styling | `SameLine`, `SetNextWindowSize`, `PushStyleColor`/`PopStyleColor`, style vars | RCSS: flexbox, `gap`, `border-radius`, `decorator: horizontal-gradient(...)`, `transition`, `@keyframes`, classes toggled from Lua (core render path only, section 10) |
| Show / hide | Stop calling `Begin` (`if not open then return end`) | `win:show(false/true)`; window stays loaded |
| Close button | `open, show = ImGui.Begin(name, open)`; X sets `open = false` | Template X (`action="window:close"`): plugin hides, Lua gets the click; or your own element with any action |
| Close / cleanup | `mq.imgui.destroy(name)` or script end | `win:close()` / `rmlui.close_all()`; wrapper GC closes owned windows on `/lua stop`; `autoclose` after 5 s without polling |
| Position saving | ImGui saved settings + `SetNextWindowPos(x, y, ImGuiCond.FirstUseEver)` | Same ImGui memory for the host window (`<name>##mq2rmlui`, `rml_set_default_pos` = FirstUseEver); per-character: `windowmoved` event / `rml_get_window` + `win:place` |
| Input focus / keyboard | ImGui text widgets set `WantTextInput` themselves | Plugin sets `WantCaptureKeyboard`/`WantTextInput` while an RML text input is focused; `rml_key_mode` 1/2 for other keys |
| Thread rules | Callback cannot yield (`ScopedYieldDisabler` in `LuaImGui::Pulse`), so no `mq.delay` inside it; an error ends the script | Identical, because the RmlUi tick runs inside the same `mq.imgui.init` callback |
| Drawing primitives | `ImGui.GetWindowDrawList()` | `<canvas>` element + `rml_canvas_*` (`CANVAS_API.md`), particles `rml_fx_*` (`FX_API.md`) |
| Dependencies | Built into MQ's Lua plugin | `MQ2RmlUi` plugin loaded + `lua\rmlui` wrapper + LuaJIT FFI |

What changes when converting an ImGui script to RmlUi:

1. Move the widget tree out of the draw function into `ui\main.rml`; give every element you update an `id` and
   every clickable element an `action`.
2. Move colours, sizes, spacing and fonts from `PushStyleColor`/`SameLine`/size arguments into `ui\main.rcss`.
3. Open the window once from the script body with `rmlui.open(...)` then `win:reload()`.
4. Replace the draw function with a tick: `for ev in win:events() do ... end` (replaces `if ImGui.Button(...)`
   and `InputText` return values), then `win:text/style/class/set_value` for the live values. Wrap it in `pcall`.
5. Replace `open, show = ImGui.Begin(name, open)` with the `window:close` action (or your own close action) and
   `win:show()` / `win:close()`.
6. Keep `mq.imgui.init` / `mq.imgui.destroy` and the `while running do mq.doevents(); mq.delay(50) end` loop.
7. If the window must stay live while the mouse is elsewhere, see "Idle windows are frozen" (section 10).
8. No performance numbers are claimed here: none were measured for this comparison.

### 13. Not verified

* The `hpwatch` and `hpwatch_imgui` examples were written from the source and checked only for Lua syntax
  (LuaJIT 2.1 parser); they have not been run in game.
* How the idle freeze looks in game, when RmlUi fires `submit` for a bare `<input>`, right-click handling, `<body>`
  class surviving the template, OTF/WOFF/WOFF2 fonts and colour emoji.
* The name and location of the ImGui settings file that stores window positions.

## Building (standard MacroQuest plugin build)

Prerequisites: Visual Studio 2022 (or Build Tools 2022) with **Desktop development with C++** (v143 toolset,
Windows 10/11 SDK) and Git. Exactly what MacroQuest itself needs.

1. Clone MacroQuest (or Open Vanilla) and its submodules, e.g.
   `git clone https://github.com/macroquest/macroquest.git` then `git submodule update --init src/eqlib contrib/vcpkg`.
   Check out the branch / commit that matches your client (the TOB emulator build used for development is
   commit `3d1149f` on `emu-tob`, eqlib `16db84cc`, client "Sep 11 2025 11:54:10").
2. Put this folder at `plugins\MQ2RmlUi\` in that tree.
3. Open `src\MacroQuestToB.sln` (or `MacroQuest.sln` / `OpenVanilla.sln`), right-click the solution ->
   **Add -> Existing Project...** -> `plugins\MQ2RmlUi\MQ2RmlUi.vcxproj`.
4. Select **Release | x64** and build `MQ2RmlUi` (Visual Studio builds MQ2Main / eqlib / imgui / pluginapi first).

Command line equivalent (Developer PowerShell for VS 2022):

```powershell
msbuild src\main\MQ2Main.vcxproj /p:Configuration=Release /p:Platform=x64 /p:SolutionDir=$PWD\src\
msbuild src\plugins\pluginapi\pluginapi.vcxproj /p:Configuration=Release /p:Platform=x64 /p:SolutionDir=$PWD\src\
msbuild plugins\MQ2RmlUi\MQ2RmlUi.vcxproj /p:Configuration=Release /p:Platform=x64 /p:SolutionDir=$PWD\src\
```

Output: `build\bin\release\plugins\MQ2RmlUi.dll` (some MQ versions use `build\<eqlibClientTarget>\bin\release\plugins\`).

### Dependencies

* **RmlUi** (and FreeType/zlib) come from MacroQuest's own vcpkg (`contrib\vcpkg`):
  `vcpkg_mq.txt` lists `rmlui`, and MQ's build (`tools\build_scripts\vcpkg_mq.ps1`) installs it for the
  `x64-windows-static` triplet the first time you build. Statically linked; nothing extra to ship.
* Links against MQ's `MQ2Main.lib`, `eqlib.lib`, `imgui-64.lib` and `pluginapi.lib` from the same tree, plus
  `d3d11`, `dxgi`, `d3dcompiler` (Windows).

### Shaders

`shaders\canvas.hlsl` and `shaders\fx.hlsl` are compiled with `fxc` into `src\shaders_canvas_bytecode.h` and
`src\shaders_fx_bytecode.h`, which are embedded in the DLL and checked in. The project re-runs
`tools\compile-shaders.ps1` / `tools\compile-fx-shaders.ps1` automatically only when a `.hlsl` is newer than
its header (fxc ships with the Windows SDK).

## Native nimbus (client-specific, optional)

`rml_nimbus_add/remove/status` call the client's own OP_AddNimbusEffect / OP_RemoveNimbusEffect handlers so the
EQ renderer draws a stock (or custom `spellsnew.eff`) nimbus on **your own** character only. Client-side; it sends
nothing to the server.

The addresses live in `src\NimbusClientOffsets.h`:

* **(A)** local player, spawn manager, version strings and PlayerClient field offsets come from eqlib.
* **(B)** the handler bodies, effect table and particle-system internals are not in eqlib. They were
  reverse-engineered from eqgame "Sep 11 2025 11:54:10" and are verified at runtime (version strings + byte
  signatures + vtable slots). On any mismatch the nimbus calls return an error and the feature stays off for
  the session; the rest of the plugin is unaffected.

Building against a different eqlib trips the `static_assert`s in that header on purpose: re-verify (B) for that
client before changing them.

## Notes

* 64-bit clients only (x64 configurations only).
* The original standalone CMake project (hand-made `.def` import libs + trimmed `mq_api.h`) is superseded by this
  project; functionality and the exported `rml_*` API are unchanged.
