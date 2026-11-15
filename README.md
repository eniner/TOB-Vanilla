# TOB Vanilla - MQ2RmlUi + CombatFX tester pack

RmlUi plugin (MQ2RmlUi) plus CombatFX, ButtonMaster RML, PF Wiki, RmlFPS and an RmlUi demo for EverQuest TOB / MacroQuest 64-bit.

## What's in here

| Path | What it is |
|---|---|
| `Built\` | Ready to use. Copy into your MacroQuest folder (same folder layout). |
| `Source\MQ2RmlUi\` | Plugin source, if you want to build the DLL yourself. |
| `Built\Plugins\MQ2RmlUi.dll` | The plugin. Draws HTML/CSS style (RmlUi) windows and effects for Lua scripts (DX11). |
| `Built\lua\rmlui` | Shared Lua library for the plugin. **Required** by every script below. |
| `Built\lua\combatfx` | Combat numbers, themes, auras, ornaments, parser, fight graphs, tracking, alerts. |
| `Built\lua\buttonmaster_rml` | ButtonMaster style hotbars drawn with RmlUi. |
| `Built\lua\pfwiki` | ProFusion wiki browser in game. |
| `Built\lua\rmlfps` | FPS / frame time / GPU meter. |
| `Built\lua\rmluidemo_pro` | Demo window showing what RmlUi can do. |

## Requirements

- EverQuest TOB 64-bit client, eqgame build `Sep 11 2025 11:54:10`.
- MacroQuest 64-bit (TOB build) with MQ2Lua. The DLL was built against that MQ/eqlib (emu-tob). A DLL built for a different MQ or client build may not load; rebuild from `Source\` in that case.
- Windows 10/11 (DirectX 11 and the Windows fonts; nothing else to install).
- Native auras / body FX / ornaments check the eqgame build above. On another build those features turn themselves off; the rest still works.

## Install

`<MQ>` = your MacroQuest folder (the one with MacroQuest.exe).

1. Close EverQuest, or at least unload the old plugin: `/plugin MQ2RmlUi unload`
2. Copy `Built\Plugins\MQ2RmlUi.dll` into `<MQ>\Plugins\`
3. Copy every folder in `Built\lua\` into `<MQ>\lua\` (you get `<MQ>\lua\rmlui`, `<MQ>\lua\combatfx`, ...)
4. Optional: copy `Built\config\combatfx_paths.ini` into `<MQ>\config\` - only if you don't already have one. CombatFX creates it by itself on first run.
5. In game:
   ```
   /plugin MQ2RmlUi
   /lua run combatfx
   /lua run buttonmaster_rml
   /lua run pfwiki
   /lua run rmlfps
   /lua run rmluidemo_pro
   ```
   Do **not** `/lua run rmlui` - it is a library the others use. Stop a script with `/lua stop <name>`.

## Autoload

- `/plugin MQ2RmlUi` saves it in MacroQuest.ini, so it loads every time after that.
- To start a script on login, add the line (e.g. `/lua run combatfx`) to `<MQ>\config\<Server>_<Character>.cfg` (create the file if it doesn't exist).

## If CombatFX can't find your EQ folder

It asks MacroQuest first. If that fails, open `<MQ>\config\combatfx_paths.ini` and set `eq_folder=D:\Games\EverQuest` (the folder with eqgame.exe), then `/lua stop combatfx` and `/lua run combatfx`.
Most parser / tracking features need EQ logging on: type `/log on`.

## Your settings

Saved in `<MQ>\config` (combatfx_&lt;server&gt;_&lt;char&gt;.ini, parses, ButtonMaster_RML.lua, rmlfps.ini ...). ButtonMaster RML imports your old `config\ButtonMaster.lua` buttons if you have one.

## Build from source (optional)

Needs Visual Studio 2022 (Desktop C++, v143) and the MacroQuest source for TOB (emu-tob branch).

1. Copy `Source\MQ2RmlUi` to `<MacroQuest source>\plugins\MQ2RmlUi`
2. Open the MacroQuest solution, **Add > Existing Project** > `plugins\MQ2RmlUi\MQ2RmlUi.vcxproj`
3. Build **Release | x64**. RmlUi comes from MQ's own vcpkg automatically (`vcpkg_mq.txt`).

Output: `build\bin\release\plugins\MQ2RmlUi.dll`. Details in `Source\MQ2RmlUi\README.md`.

## Uninstall

`/lua stop` each script, `/plugin MQ2RmlUi unload`, then delete `<MQ>\Plugins\MQ2RmlUi.dll` and the six folders above from `<MQ>\lua`. Delete the `combatfx_*`, `ButtonMaster_RML*` and `rmlfps.ini` files in `<MQ>\config` if you want your settings gone too.

## Note

Everything is client side. Only you see the visuals (auras, ornaments, numbers); nothing is sent to the server and other players see your normal gear.

Game icons in `buttonmaster_rml\img\gi` are from [game-icons.net](https://game-icons.net) (CC BY 3.0); see `Built\lua\buttonmaster_rml\CREDITS.txt`.