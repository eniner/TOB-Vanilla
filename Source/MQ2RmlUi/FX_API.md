# MQ2RmlUi particles - Stage 1 (API 5, additive; rml_features() bit 512)
Formula emitter: every particle is a pure function of (descriptor, slot, emitter clock), evaluated in the
vertex shader (vs_5_0/ps_5_0, FL 11_0) or, without it, by the same C++ code (src/FxSim.h) on the CPU.
No per-particle GPU state; one 544-byte constant buffer and one DrawInstanced(6, n) per emitter.

    int rml_fx_create(const char* win, const char* id, const float* desc, int n)   -> handle (0 = no such canvas)
    int rml_fx_update(int h, const float* desc, int n)        live change, no reset (rate change = new segment)
    int rml_fx_anchor(int h, float x, float y, float px_per_unit, float depth01)   canvas-local px; units -> px
    int rml_fx_exclude(const char* win, const char* id, const float* p, int n)     body capsule (n < 5 clears)
        p = feet x, feet y, up x, up y, span px [, 7 half-width knots as span fractions at t=0,.2,.42,.70,.84,.94,1.08] [, feather px]
        default knots = CombatFX BF.excl_hw (+0.02), feather 6 px; masked per pixel (no light inside)
    int rml_fx_burst(int h, int count)                        one-shot extra particles (<= 16384 live burst total)
    int rml_fx_stop(int h, int fade_out)                      1 = stop emitting, let particles finish; 0 = clear now
    int rml_fx_destroy(int h)
    int rml_fx_stats(int h, char* out, int cap)               h = 0 -> totals
    int rml_fx_mode(int mode)                                 -1 query, 0 auto, 1 force CPU; returns 2 gpu / 1 cpu / 0 none
Lifetime: emitters belong to the canvas element; freed on document unload/window close/autoclose, plugin
shutdown, or destroy. Device loss drops only shaders (recreated lazily). Clock advances per painted frame,
dt clamped to 100 ms. Active emitters keep their window painting.

Descriptor float[64] (missing/0 fields take defaults):
 0 shape (0 point,1 sphere,2 cylinder,3 disk,4 ring,9 random ring)  1 radius  2 height  3 fill/jitter 0..1
 4-6 offset xyz   7-8 arc start/end deg (equal = full)   9 rate/s  10 initial burst  11 capacity (0 = rate*life+1)
 12 lifetime s  13 life jitter  14 delay s  15 fade in s  16 fade out s  17 grow s  18 shrink s
 19/20 width start/end  21/22 height start/end (0 = width)  23 size jitter
 24-27 colour start rgba  28-31 colour end rgba  32 max opacity
 33-35 axial vmin/vmax/accel (+z up)  36-38 transverse1 (x)  39-41 transverse2 (depth y)  42-44 radial  45-47 orbital (deg/s)
 48 gravity  49/50 wind x/y  51 spin deg/s  52 spin jitter  53 random rotation  54 frames  55 fps (flipbook strip, GPU path)
 56 texture id (rml_canvas_texture_load, 0 = soft dot)  57 blend (0 alpha, 1 additive)  58 follow (Stage 1: always 1)
 59 seed (0 = per emitter)  60 depth tilt (default 0.35)  61 brightness jitter  62 intensity (rgb x, HDR ok)  63 reserved
Screen position: x_px = anchor.x + x*ppu,  y_px = anchor.y - (z + y*tilt)*ppu.
