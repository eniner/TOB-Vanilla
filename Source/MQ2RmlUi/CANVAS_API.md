# MQ2RmlUi canvas API (x64 / DX11)

A `<canvas>` custom element draws through its own DX11 pipeline **during** the document’s `Context::Render()`, into that window’s offscreen RT. Z-order, clipping, move, collapse and resize follow the Rml document — there is no Present-hook overlay.

API version: **4** (`rml_api_version()`). Version 3 submit/helpers stay compatible.

## RML

```xml
<canvas id="viz"/>
```

```css
canvas {
    display: block;
    width: 100%;
    flex: 1 1 auto;
    min-height: 80dp;
    overflow: hidden;
    background-color: #050510;
}
```

Windows that receive canvas submits are painted every frame for ~0.4s after the last submit, even when unfocused (so a visualizer keeps animating).

## Vertex format

`rml_canvas_submit` takes `count` vertices. Each vertex is **6 floats**:

`x, y, r, g, b, a`

- `x,y` are **canvas-local pixels**, origin at the top-left of the canvas content box, Y down.
- `r,g,b,a` are 0..1. The renderer premultiplies RGB by alpha.

## Mode bits

Primitive (low 4 bits):

| Value | Name | Layout |
|------:|------|--------|
| 0 | `RML_CANVAS_TRIANGLES` | `count % 3 == 0` |
| 1 | `RML_CANVAS_QUADS` | `count % 4 == 0`, each quad becomes two triangles |
| 2 | `RML_CANVAS_LINES` | pairs, expanded to thick-line quads |
| 3 | `RML_CANVAS_LINE_STRIP` | connected segments |
| 4 | `RML_CANVAS_POLYGON` | convex triangle fan |

Flags (OR with the primitive):

| Mask | Name | Meaning |
|-----:|------|---------|
| `0x0100` | `RML_CANVAS_ADDITIVE` | additive blend |
| `0x0200` | `RML_CANVAS_GLOW` | also drawn into an offscreen bloom RT and composited |
| `0x0400` | `RML_CANVAS_FILL` | filled circle/arc (helpers only) |
| `0x1000` | `RML_CANVAS_SPRITE_SQUARE` | soft square sprites (`rml_canvas_sprites` mode) |

Default line thickness is 2px; change it with `rml_canvas_line_width`.

## C / LuaJIT FFI

```c
int   rml_canvas_clear(const char* win, const char* id);
int   rml_canvas_submit(const char* win, const char* id, const float* verts, int count, int mode);
int   rml_canvas_line_width(const char* win, const char* id, float width);
int   rml_canvas_circle(const char* win, const char* id,
                        float x, float y, float radius,
                        float r, float g, float b, float a,
                        int segments, int mode);
int   rml_canvas_arc(const char* win, const char* id,
                     float x, float y, float radius, float a0, float a1,
                     float r, float g, float b, float a, int mode);
int   rml_canvas_size(const char* win, const char* id, float* out_w, float* out_h);
float rml_canvas_draw_ms(const char* win, const char* id);

/* row-major 4x4 view-projection, DirectX LH, XMStoreFloat4x4 layout */
int   rml_canvas_lookat(float* out16,
                        float ex, float ey, float ez,
                        float ax, float ay, float az,
                        float ux, float uy, float uz,
                        float fov_y_deg, float aspect, float znear, float zfar);
int   rml_canvas_project(float x, float y, float z, const float* m16,
                         float vp_w, float vp_h, float* out_x, float* out_y);
int   rml_canvas_project_n(const float* xyz, int n, const float* m16,
                           float vp_w, float vp_h, float* out_xy);

/* v4: background shader, motion trail, bloom strength, GPU sprites */
int   rml_canvas_bg(const char* win, const char* id, int style, float time, float energy, float beat);
int   rml_canvas_trail(const char* win, const char* id, float decay);
int   rml_canvas_bloom(const char* win, const char* id, float strength);
int   rml_canvas_sprites(const char* win, const char* id, const float* data, int count, int mode);
int   rml_canvas_sprite(const char* win, const char* id,
                        float x, float y, float rx, float ry,
                        float r, float g, float b, float a, int mode);

/* textured / rotated sprites (old sprite API is unchanged) */
int   rml_canvas_texture_load(const char* win, const char* id, const char* path);
int   rml_canvas_sprite_ex(const char* win, const char* id,
                           float x, float y, float sx, float sy, float angle,
                           float r, float g, float b, float a, int tex_id, int mode);
int   rml_canvas_sprites_ex(const char* win, const char* id, const float* data, int count);
```

### v4 renderer

Each canvas draws into an HDR scene RT (`R16G16B16A16_FLOAT`, RGBA8 fallback):

1. Clear scene, then optionally blit last frame * `decay` (motion trails). `decay` is clamped to `0..0.98`. `0` disables trails; the trail texture itself survives `clear` until the canvas is resized.
2. Draw submitted batches (additive if `0x0100`) and GPU-instanced sprites (legacy sprites are always additive, max 8192). `rml_canvas_sprites_ex` draws rotated textured quads in the same HDR scene pass; `0x0100` selects additive blend, otherwise premultiplied alpha (`ONE` / `INV_SRC_ALPHA`).
3. 1/2 + 1/4 + 1/8 downsample bloom with bright-pass boost, separable blur, upsample-add, then composite onto the scene. Default strength is `1.45`.
4. Copy the *pre-bloom* scene to the trail RT (bloom must not feed back into trails; that diverges to HDR white).
5. On the document: optional background shader (`style` 1 = nebula + stars, `style` 2 = dark gradient), then ACES-tonemap and alpha-composite the scene over it. Trail textures are cleared on create/resize.

`rml_canvas_clear` resets batches, sprites, bg/trail/bloom parameters (bloom back to `1.45`). Call the v4 setters every frame after `clear`. `0x0200` GLOW is kept for compatibility; v4 bloom is driven by scene brightness and `rml_canvas_bloom` instead of a separate glow buffer.


`rml_canvas_texture_load` loads a PNG once (stb_image) into an SRV, cached by normalized path, and returns a `tex_id` (`0` on failure). GPU copies are rebuilt after device loss from the cached pixels and released on unload or `OnLostDevice`.

`rml_canvas_sprites_ex` takes `count` records of **11 floats**: `x, y, sx, sy, angle, r, g, b, a, tex_id, mode`. `sx`/`sy` are local half-extents before rotation; `angle` is radians (use `atan2(vy, vx)` so local +X follows velocity). The pixel shader samples the texture times the instance color (HDR > 1 is allowed) and premultiplies by `tex.a * color.a`. `tex_id` `0` binds a 1x1 white fallback.

Sprite `data` is `count` records of 8 floats: `x, y, rx, ry, r, g, b, a` (canvas-local pixels, half-extents `rx`/`ry`). `mode` `0` = soft circle, `0x1000` = soft square. Colors are premultiplied by the renderer.

Load with the same pattern as the rest of the host:

```lua
local ffi = require('ffi')
local rml = ffi.load('MQ2RmlUi')
```

Prefer `rml_canvas_project_n` over per-point `rml_canvas_project` when projecting many vertices (3D city, etc.).

`rml_canvas_clear` drops queued batches and sprites and resets frame FX. Call it once per frame before submitting new geometry and v4 setters. Shaders are precompiled with `fxc` `vs_4_0`/`ps_4_0` into `src/shaders_canvas_bytecode.h` (no runtime `D3DCompiler`). Rebuild them with `compile-shaders.ps1`.

Do not `print()` from an `mq.imgui.init` callback — that thread is not the game thread. Drain logs from the script delay loop.
