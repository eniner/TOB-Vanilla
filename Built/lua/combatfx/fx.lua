-- combatfx overlay: fixed pool of reusable elements in one click-through window.
-- Every effect is a one-shot animation restarted with a single style write; the window hides itself when idle.
local C = require('combatfx.core')
local CV
pcall(function() CV = require('combatfx.canvas') end)
local function cv(name, ...)
    if not CV then return end
    local fn = CV[name]
    if fn then pcall(fn, ...) end
end
local M = { active = 0 }
local O
local TFX                        -- tfx1: DX11 themed numbers (MQ2RmlUi TextFX); nil/unavailable -> old text path
do local ok, t = pcall(require, 'combatfx.themefx'); if ok and type(t) == 'table' then TFX = t end end
local FT = require('combatfx.features')   -- f8: role filter / looks, perf tier, min text size, alerts, moments, live meter
local tjit = 0
local POOL_MAX = 40
local slots = {}                 -- [i] = { busy_until, kind, t0, n, text }
local nexti = 1
local SW, SH = 1920, 1080
local busy_until = 0
local vig_on, vig_next, plate_on = false, 0, false
local fx_until = {}              -- effect name -> end time (for the cost readout)
-- lanes: x, y as fraction of the screen
-- outgoing numbers + DX11 FX share the melee lane (where hits already float over the target)
local TARGET = { 0.585, 0.40 }
local LANE = { melee = TARGET, spell = { 0.625, 0.35 }, dot = { 0.665, 0.43 }, crit = TARGET, incoming = { 0.40, 0.52 },
    healin = { 0.50, 0.60 }, healout = { 0.57, 0.48 }, miss = { 0.43, 0.47 }, missout = { 0.60, 0.45 }, resist = { 0.61, 0.28 }, kill = { 0.50, 0.25 },
    proc = { 0.60, 0.25 }, pet = { 0.68, 0.50 }, group = { 0.545, 0.45 } }
local function target_xy() return SW * TARGET[1], SH * TARGET[2] end
local function body_xy()
    if CV and CV.body_xy then
        local ok, x, y = pcall(function() return CV.body_xy() end)
        if ok and x and y then return x, y end
    end
    return SW * 0.50, SH * 0.48
end
local EDGES = { 'vig', 'dmg', 'heal', 'agg' }

local function edge_html(pre)
    return string.format('<div class="eg et" id="%s_t"></div><div class="eg eb" id="%s_b"></div><div class="eg el" id="%s_l"></div><div class="eg er" id="%s_r"></div>', pre, pre, pre, pre)
end
function M.open()
    SW, SH = C.screen()
    if CV then pcall(function() CV.bind('CombatFxOverlay', 'cfx'); CV.set_size(SW, SH) end) end
    O = C.open({ key = 'Overlay', doc = 'overlay.rml', w = SW, h = SH, x = 0, y = 0, clickthrough = true, force_pos = true })
    if not O then return false end
    local p = {}
    for i = 1, POOL_MAX do p[i] = string.format('<div class="ft" id="n%d"></div>', i); slots[i] = { busy_until = 0 } end
    O:rml('pool', table.concat(p))
    local q = {}
    for i = 1, 8 do q[i] = string.format('<div class="pt" id="p%d"></div>', i) end
    O:rml('parts', table.concat(q))
    for _, e in ipairs(EDGES) do O:rml(e, edge_html(e)) end
    O:style('tplate', 'left', math.floor(SW * 0.5) .. 'px'); O:style('tplate', 'top', math.floor(SH * 0.17) .. 'px')
    O:style('streak', 'left', math.floor(SW * 0.80 - 220) .. 'px'); O:style('streak', 'top', math.floor(SH * 0.40) .. 'px')
    O:style('ban', 'top', math.floor(SH * 0.21) .. 'px'); O:style('ban2', 'top', math.floor(SH * 0.21) + 52 .. 'px')
    O:style('parts', 'left', '0px')
    O:style('stamp', 'top', math.floor(SH * 0.40) .. 'px')
    for i = 1, 4 do O:style('ts' .. i, 'top', math.floor(SH * 0.04) + (i - 1) * 30 .. 'px') end
    O:style('recap', 'left', math.floor(SW * 0.05) .. 'px'); O:style('recap', 'top', math.floor(SH * 0.40) .. 'px')
    O:style('cbar', 'left', math.floor(SW * 0.5) .. 'px'); O:style('cbar', 'top', math.floor(SH * 0.78) .. 'px')
    -- f8: in-combat meter (left, above the recap), alert slots and the kill / loot flourish
    local lb = {}
    for i = 1, 20 do lb[i] = string.format('<div class="lb" id="lb%d" style="left: %dpx;"></div>', i, (i - 1) * 11) end
    O:rml('lm', '<span class="lmk">DPS</span><span id="lmv">0</span><span id="lmt"></span><div id="lmg">' .. table.concat(lb) .. '</div><span id="lma"></span>')
    O:style('lm', 'left', math.floor(SW * 0.05) .. 'px'); O:style('lm', 'top', math.floor(SH * 0.27) .. 'px')
    M.apply_settings()
    O:show(false)
    return true
end

function M.apply_settings()
    if not O then return end
    local cfg = C.cfg
    for _, s in ipairs({ 'bold', 'normal', 'heavy', 'shadow' }) do O:class('body', 'fs-' .. s, cfg.style == s) end
    local e = math.floor(cfg.edge)
    for _, pre in ipairs(EDGES) do
        local th = pre == 'vig' and math.floor(e * 1.6) or e
        O:style(pre .. '_t', 'height', th .. 'px'); O:style(pre .. '_b', 'height', th .. 'px')
        O:style(pre .. '_l', 'width', th .. 'px'); O:style(pre .. '_r', 'width', th .. 'px')
    end
    local a = string.format('%.2f', cfg.intensity / 100)
    O:style('healw', 'opacity', a); O:style('aggw', 'opacity', a); O:style('vigw', 'opacity', a); O:style('cfw', 'opacity', a); O:style('parts', 'opacity', a)
    local pc = cfg.color.healin or '#6aff8a'
    for i = 1, 8 do O:style('p' .. i, 'background-color', pc) end
    O:style('burst', 'border-color', cfg.color.spell or '#8ac8ff')
    O:style('streak', 'color', cfg.color.crit or '#ffb347')
end

local last_assert = 0
local function wake(dur)
    local now = C.now()
    local t = now + math.floor(dur * 1000) + 150; if t > busy_until then busy_until = t end
    -- re-assert visibility at most once a second: if the window was hidden behind our back, the diffed
    -- proxy would otherwise believe it is still showing and every effect would play invisibly
    if now - last_assert > 1000 then last_assert = now; O.visible = nil end
    O:show(true)
end
local function mark(name, dur) fx_until[name] = C.now() + math.floor(dur * 1000) end

-- floating number / word
local coal = {}
function M.number(kind, value, opts)
    if not O or not C.cfg.master or not C.cfg.fx.numbers then return end
    local lk = kind
    if kind == 'miss' and opts and opts.out then lk = 'missout' end
    if not C.cfg.on[kind] then return end
    if not FT.shown(kind, lk) then return end                 -- f8: your hits / group / on you / pet toggles
    opts = opts or {}
    local now = C.now()
    local crit = opts.crit or kind == 'crit'
    -- tfx1: themed GPU numbers (shader text, particles, crit impact, combo) when the DLL supports it
    if TFX then
        tjit = tjit + 1
        local lane = LANE[lk] or LANE.melee
        local x = SW * (lane[1] + ((tjit * 37) % 9 - 4) * 0.012)
        local y = SH * (lane[2] + ((tjit * 23) % 5) * 0.012)
        local ok, done, life = pcall(TFX.number, kind, lk, value, opts, x, y, (tjit % 2 == 0) and -1 or 1)
        if ok and done then
            if life then
                if crit then cv('crit') elseif kind == 'kill' then cv('kill', x, y) end
                wake(life + 0.7)
            end
            return
        end
    end
    -- coalesce bursts of the same kind (e.g. fast melee) into one label instead of spawning dozens
    local c = coal[lk]
    if type(value) == 'number' and c and now - c.t < 250 and slots[c.slot].busy_until > now and not crit then
        c.n = c.n + value; c.cnt = c.cnt + 1; c.prefix = opts.prefix or ''
        c.dirty = true                                            -- label text is flushed at most every 100 ms (frame)
        return
    end
    if crit and now - (M._last_crit or 0) < 120 then
        local cc = coal.crit_merge
        if cc and slots[cc.slot].busy_until > now and type(value) == 'number' then cc.n = cc.n + value; cc.cnt = cc.cnt + 1; cc.dirty = true; cc.crit = true; return end
    end
    local cap = C.cfg.lite and math.min(8, C.cfg.max) or C.cfg.max
    cap = C.clamp(FT.cap(cap), 1, POOL_MAX)
    local active, oldest, oi = 0, math.huge, nil
    for i = 1, cap do local s = slots[i]; if s.busy_until > now then active = active + 1; if s.t0 < oldest then oldest, oi = s.t0, i end end end
    local slot
    if active >= cap then
        if not crit and kind ~= 'kill' then return end      -- at the cap only crits/kills may replace the oldest
        slot = oi
    else
        for k = 0, cap - 1 do local i = (nexti + k - 1) % cap + 1; if slots[i].busy_until <= now then slot = i; break end end
        nexti = slot % cap + 1
    end
    local id = 'n' .. slot
    local lane = LANE[lk] or LANE.melee
    local jx = ((slot * 37) % 9 - 4) * 0.012
    local jy = ((slot * 23) % 5) * 0.012
    local text = type(value) == 'number' and ((opts.prefix or '') .. C.fmt(value)) or tostring(value)
    if crit and type(value) == 'number' then text = text .. '!' end
    O:text(id, text)
    O:style(id, 'left', math.floor(SW * (lane[1] + jx)) .. 'px')
    O:style(id, 'top', math.floor(SH * (lane[2] + jy)) .. 'px')
    if crit then cv('crit')
    elseif kind == 'kill' then cv('kill', SW * (lane[1] + jx), SH * (lane[2] + jy)) end
    local rmod = FT.role_mod(kind, lk)
    local scol
    if opts.school and ((C.cfg.school and C.cfg.school.on) or FT.forced('school')) then
        local sc = FT.school_of(opts.school); local T = TFX
        local pc = sc and T and T.COLORS[FT.SCHOOL_LOOK[sc]]
        scol = pc and (pc[kind] or pc.spell) or nil
    end
    O:style(id, 'color', opts.color or scol or C.cfg.color[kind] or '#ffffff')
    O:style(id, 'font-effect', C.font_effect(lk == 'missout' and 'miss' or kind))   -- static per pop (diffed: usually 0 writes)
    local size = C.cfg.size
    if crit then size = math.floor(size * 1.45) elseif kind == 'miss' or kind == 'dot' or kind == 'pet' then size = math.floor(size * 0.78) elseif kind == 'kill' then size = math.floor(size * 1.2) end
    size = math.floor(FT.min_size(size * (rmod.size or 1)))
    O:style(id, 'font-size', size .. 'px')
    local m = C.cfg.motion
    if C.cfg.lite then m = 'rise' end
    local name = ({ rise = 'rise', static = 'static', scroll = 'scroll', arc = (slot % 2 == 0) and 'arcl' or 'arcr', fountain = (slot % 2 == 0) and 'fntl' or 'fntr' })[m] or 'rise'
    local dur = C.cfg.dur * (crit and 1.25 or 1)
    O:anim(id, (crit and not C.cfg.lite and 'c_' or 'm_') .. name, dur, 'cubic-out')
    slots[slot] = { busy_until = now + math.floor(dur * 1000), t0 = now }
    coal[lk] = { t = now, slot = slot, n = type(value) == 'number' and value or 0, cnt = 1, wt = now }
    if crit then M._last_crit = now; coal.crit_merge = coal[lk] end
    wake(dur)
end

-- red edge flash scaled by % of max HP lost
function M.damage_flash(pct)
    if not O or not C.cfg.master or not C.cfg.fx.dmgfx then return end
    local s = C.clamp((pct or 5) / 12, 0.2, 1) * C.cfg.intensity / 100
    O:style('dmgw', 'opacity', string.format('%.2f', s))
    O:anim('dmg', 'flash', C.cfg.lite and 0.35 or 0.55, 'quadratic-out'); mark('dmg', 0.55); wake(0.6)
end
function M.heal_fx()
    if not O or not C.cfg.master or not C.cfg.fx.healfx then return end
    O:anim('heal', 'pulse', 0.9, 'sine-in-out'); mark('heal', 0.9)
    if not C.cfg.lite and C.particles_on() then
        local bx, by = SW * 0.5, SH * 0.72
        for i = 1, 8 do
            local id = 'p' .. i
            O:style(id, 'left', math.floor(bx + (i - 4.5) * 14) .. 'px'); O:style(id, 'top', math.floor(by + (i % 3) * 8) .. 'px')
            O:anim(id, 'pt' .. i, 1.1 + (i % 3) * 0.15, 'quadratic-out')
        end
        mark('parts', 1.4)
    end
    cv('heal')
    wake(1.4)
end
function M.crit_flash()
    if not O or not C.cfg.master or not C.cfg.fx.critflash or C.cfg.lite then return end
    local now = C.now(); if now - (M._last_flash or 0) < 400 then return end; M._last_flash = now
    O:anim('cflash', 'flash', 0.3, 'quadratic-out'); mark('cflash', 0.3); wake(0.35)
end
function M.burst(rt, handler, line)
    if not O or not C.cfg.master or not C.cfg.fx.burst or C.cfg.lite or not C.particles_on() then return end
    -- t464: native proc effect: EQ wraps the target's (or your) body in a real spell-hit record in the 3D world;
    -- nothing is drawn on the screen then. Off / unavailable / refused -> the old screen-drawn burst below.
    local PF = package.loaded['combatfx.procfx']
    if PF and PF.fire then
        local ok, owned = pcall(PF.fire, 'proc', rt)
        if ok and owned then return end
    end
    local x, y = target_xy()
    O:style('burst', 'left', math.floor(x) .. 'px'); O:style('burst', 'top', math.floor(y) .. 'px')
    O:anim('burst', 'burst', 0.5, 'cubic-out'); mark('burst', 0.5); wake(0.55)
    -- prefer the damage-line resist type; fall back to the last-cast spell
    -- events.lua already mapped ResistType when a spell name was present;
    -- do not fall back to the last-cast resist (that paints weapon procs as a buff).
    cv('proc', rt, handler, line)
end
-- ps1: 'All cards off' (Parses > Settings): every card / popup / banner / alert / panel below; numbers and screen FX stay
function M.cards_on() return not (C.cfg.notify and C.cfg.notify.cards == false) end
local cards_on = M.cards_on
function M.banner(text, sub, color, which)
    if not O or not C.cfg.master or not cards_on() then return end
    if which == 'kill' and not C.cfg.fx.killbanner then return end
    if which == 'combat' and not C.cfg.fx.combatbanner then return end
    local d = C.cfg.lite and 1.4 or 2.2
    O:text('ban', text); O:style('ban', 'color', color or '#ffffff'); O:anim('ban', 'banner', d, 'cubic-out')
    if sub and sub ~= '' then O:text('ban2', sub); O:anim('ban2', 'banner', d, 'cubic-out') end
    mark('ban', d); wake(d)
end
function M.streak(n)
    if not O or not C.cfg.master or not C.cfg.fx.streak or not cards_on() then return end
    local now = C.now(); if now - (M._last_streak or 0) < 500 then M._streak_pending = n; return end; M._last_streak = now; M._streak_pending = nil
    O:text('streak', n .. ' HIT COMBO')
    O:anim('streak', 'pop', C.cfg.lite and 0.9 or 1.6, 'cubic-out'); mark('streak', 1.6); wake(1.6)
end
-- target plate (our own nameplate stand-in; EQ's 3D nameplate position is not readable from Lua)
function M.plate(on, name, pct)
    if not O then return end
    on = on and C.cfg.master and C.cfg.fx.shake and not C.cfg.lite
    if on then
        O:text('tpn', name or ''); O:style('tpf', 'width', string.format('%d%%', C.clamp(math.floor(pct or 100), 0, 100)))
        O:style('tpn', 'color', C.cfg.color.melee or '#ffffff')
        O:show(true)
    end
    O:class('tplate', 'on', on); plate_on = on
end
function M.shake()
    local now = C.now()
    if plate_on and O and now - (M._last_shake or 0) >= 300 then M._last_shake = now; O:anim('tplate', 'shake', 0.28, 'linear') end
end
-- low-HP vignette: re-armed one-shot pulse (never an infinite animation); costs 1 write per ~1.1 s only while low
function M.vignette(low)
    if not O then return end
    vig_on = low and C.cfg.master and C.cfg.fx.vignette or false
    local use_hb = CV and C.cfg.fx.dx11 and C.cfg.fx.dx11_heartbeat
    if use_hb then cv('set_heartbeat', vig_on) end
    if vig_on then O:show(true) end
end

function M.frame()
    if not O then return end
    local now = C.now()
    -- f8: performance auto-scaling sample (cheap: counts at most 2x a second)
    if now - (M._pf_t or 0) >= 500 then
        M._pf_t = now
        local n = 0
        for i = 1, POOL_MAX do if slots[i].busy_until > now then n = n + 1 end end
        if TFX and TFX.live_count then local ok, c = pcall(TFX.live_count); if ok and c then n = n + c end end
        M._pf_n = n
    end
    FT.perf_frame(now, M._pf_n or 0)
    if M._streak_pending and now - (M._last_streak or 0) >= 500 then M.streak(M._streak_pending) end
    for _, c in pairs(coal) do
        if c.dirty and now - (c.wt or 0) >= 100 then
            c.dirty = false; c.wt = now
            O:text('n' .. c.slot, (c.prefix or '') .. C.fmt(c.n) .. (c.crit and '!' or '') .. ' x' .. c.cnt)
        end
    end
    if vig_on and now >= vig_next then
        vig_next = now + 1100
        local use_hb = CV and C.cfg.fx.dx11 and C.cfg.fx.dx11_heartbeat
        if not use_hb then O:anim('vig', 'pulse', 1.05, 'sine-in-out'); mark('vig', 1.05) end
        busy_until = math.max(busy_until, now + 1200)
    end
    cv('frame', SW, SH)
    if TFX then C.guard('tfx', TFX.frame) end
    if CV and CV.ground_live then
        local ok, live = pcall(CV.ground_live)
        if ok and live then wake(0.45) end
    end
    M.cast_frame(now)
    if O.visible and now > busy_until and not vig_on and not plate_on and not M._cb and not lm_on and not M._gm_rect then O:show(false) end
end
-- cost readout: live elements this instant
function M.cost()
    local now, n = C.now(), 0
    for i = 1, POOL_MAX do if slots[i].busy_until > now then n = n + 1 end end
    local e = 0
    for k, t in pairs(fx_until) do if t > now then e = e + (k == 'parts' and 8 or 1) end end
    return n, e, O and O.visible
end
function M.clear()
    if not O then return end
    for i = 1, POOL_MAX do slots[i].busy_until = 0 end
    vig_on = false; M.plate(false); busy_until = 0; M.cast_stop()
    cv('clear')
    if TFX then pcall(TFX.clear) end
end
function M.gold_flare()
    cv('flare', SW * 0.50, SH * 0.18)
    if O then wake(1.0) end
end
function M.preview_style(style, kind)
    if kind == 'aura' then
        if CV then pcall(function() CV.preview_aura(style) end) end
        if O then wake(2.2) end
        return
    end
    if kind == 'trail' then
        local NT = package.loaded['combatfx.trails']     -- t485: native foot trail preview when the DLL has slot 2
        if NT and NT.native and NT.native() and NT.D.by_style[style] then pcall(NT.preview, NT.D.by_style[style].id); return end
        if CV then pcall(function() CV.preview_trail(style) end) end
        if O then wake(2.2) end
        return
    end
    if kind == 'body' then
        if CV then pcall(function() CV.preview_body(style) end) end
        if O then wake(2.2) end
        return
    end
    cv('preview', style, kind)
    if O then wake(1.6) end
end
-- ---------------------------------------------------------------- add-ons: stamps, toasts, aggro edge, recap, death, cast bar
-- Same rules as above: one style write restarts a one-shot animation; nothing loops. Lite turns off bighit, procs, castbar.
local LITE_OFF = { bighit = true, procs = true, castbar = true }
function M.on(k) return O ~= nil and C.cfg.master and C.cfg.fx[k] and not (C.cfg.lite and LITE_OFF[k]) end
function M.stamp(text, color)
    if not M.on('bighit') or not cards_on() then return end
    O:text('stamp', text); O:style('stamp', 'color', color or '#ffd040')
    O:anim('stamp', 'pop', 1.4, 'cubic-out'); mark('stamp', 1.4); wake(1.4)
    local tx, ty = body_xy()
    cv('shockwave', tx, ty, 1.0, 0.82, 0.25)
    if CV then pcall(function() CV.glow_at(tx, ty, 1.0, 0.88, 0.25, 44, 700) end) end
    cv('crit', tx, ty)
end
local TN, tq, tlast = 4, {}, 0
function M.toast(k, text, color)
    if not M.on(k) or not cards_on() then return end
    local now = C.now()
    for i = 1, TN do if tq[i] and tq[i].text == text and tq[i].t > now - 1200 then return end end   -- same alert twice: once
    local slot
    for i = 1, TN do if not tq[i] or tq[i].t + 2400 <= now then slot = i; break end end
    if not slot then tlast = tlast % TN + 1; slot = tlast end
    local id = 'ts' .. slot
    O:text(id, text); O:style(id, 'color', color or '#ffffff'); O:anim(id, 'banner', 2.4, 'cubic-out')
    tq[slot] = { text = text, t = now }; mark('toast' .. slot, 2.4); wake(2.4)
end
function M.edge(k)
    if not M.on(k) or not cards_on() then return end
    local now = C.now(); if now - (M._last_edge or 0) < 700 then return end; M._last_edge = now
    O:anim('agg', 'flash', 0.6, 'quadratic-out'); mark('agg', 0.6); wake(0.65)
end
-- pa1: the recap sits beside you, never over you: left column by default, the right column when the body box
-- reaches the left one, otherwise beside the body box like the alerts; skipped when nothing fits (never drawn over you)
M._recap_rect = nil
local wl_rect = {}                                                 -- f10 world labels on screen: { x1, y1, x2, y2, until }
function M.recap_place(w, h)
    local x, y = math.floor(SW * 0.05), math.floor(SH * 0.30)
    if y + h > SH - 8 then y = math.max(8, SH - 8 - h) end
    local fx, fy, ux, uy, span, _, wmul = FT.capsule()
    local b = { FT.body_box(fx, fy, ux, uy, span, wmul) }
    local function clear(r) return not FT.overlap(r, b) end
    local r = { x, y, x + w, y + h }
    if clear(r) then return x, y, b end
    x = SW - math.floor(SW * 0.05) - w; r = { x, y, x + w, y + h }
    if clear(r) then return x, y, b end
    local px, py = FT.place_beside(w, h, 1, SW, SH, { fx, fy, ux, uy, span, 'x', wmul }, {})
    return px, py, b
end
function M.recap(html, dur)
    if not M.on('recap') or not cards_on() then return end
    dur = dur or 6
    local w, h = M.RECAP_W, (FT.recap_height and FT.recap_height(html)) or M.RECAP_H
    local x, y = M.recap_place(w, h)
    if not x then M._recap_rect = nil; return end
    M._recap_rect = { x, y, x + w, y + h }
    O:style('recap', 'left', x .. 'px'); O:style('recap', 'top', y .. 'px')
    O:rml('recap', html); O:anim('recap', 'recap', dur, 'linear'); mark('recap', dur); wake(dur)
end
-- ---------------------------------------------------------------- f8: alerts beside the character, kill / loot moments, live meter
-- panels already on screen that alerts / the moment must not cover (recap card while it shows, the live meter while on)
M.RECAP_W, M.RECAP_H, M.LM_W, M.LM_H = 366, 340, 264, 90
local lm_on = false
function M.panels()
    local now, p = C.now(), {}
    if (fx_until.recap or 0) > now and M._recap_rect then local r = M._recap_rect; p[#p + 1] = { r[1] - 6, r[2] - 6, r[3] + 6, r[4] + 6 } end
    if lm_on then local x, y = math.floor(SW * 0.05), math.floor(SH * 0.27); p[#p + 1] = { x - 6, y - 6, x + M.LM_W + 6, y + M.LM_H + 6 } end
    if (fx_until.drc or 0) > now and M._drc_rect then local r = M._drc_rect; p[#p + 1] = { r[1] - 6, r[2] - 6, r[3] + 6, r[4] + 6 } end
    if M._gm_rect then local r = M._gm_rect; p[#p + 1] = { r[1] - 6, r[2] - 6, r[3] + 6, r[4] + 6 } end
    if M._tk_rect then local r = M._tk_rect; p[#p + 1] = { r[1] - 6, r[2] - 6, r[3] + 6, r[4] + 6 } end       -- f10
    for i = 1, 3 do local r = wl_rect[i]; if r and r[5] > now then p[#p + 1] = { r[1] - 4, r[2] - 4, r[3] + 4, r[4] + 4 } end end
    return p
end
local AN, aq = 3, {}
M.ALERT_W, M.ALERT_H = 260, 48
local ALERT_TAG = { proc = 'PROC', buff = 'BUFF', heal = 'HEAL', mob = 'MOB', spawn = 'NAMED', fd = 'FEIGN', dot = 'DOT', cast = 'CAST' }
M._alert_log = {}
function M.alert(k, title, sub, color)
    if not O or not C.cfg.master or not cards_on() or not ((C.cfg.alerts and C.cfg.alerts[k]) or FT.forced('alert.' .. k)) then return false end
    local now = C.now()
    for i = 1, AN do if aq[i] and aq[i].title == title and aq[i].t > now - 2000 then return false end end
    local slot
    for i = 1, AN do if not aq[i] or aq[i].t + 2800 <= now then slot = i; break end end
    if not slot then local o = 1; for i = 2, AN do if aq[i].t < aq[o].t then o = i end end; slot = o end
    local x, y, side, box = FT.place_beside(M.ALERT_W, M.ALERT_H, slot, SW, SH, nil, M.panels())
    if not x then return false end                                   -- no room that keeps clear of the body: skip
    local id = 'al' .. slot
    local fs = math.floor(FT.min_size(16))
    color = color or '#ffd040'
    O:rml(id, string.format('<div class="alb" style="background-color: %s;"></div><span class="alk" style="color: %s;">%s</span><span class="alt" style="font-size: %dpx;">%s</span><span class="als">%s</span>',
        color, color, ALERT_TAG[k] or 'ALERT', fs, C.esc(title or ''), C.esc(sub or '')))
    O:style(id, 'left', x .. 'px'); O:style(id, 'top', y .. 'px')
    O:anim(id, 'alert' .. side, 2.8, 'cubic-out')
    aq[slot] = { title = title, t = now, x = x, y = y, side = side }
    M._alert_log[#M._alert_log + 1] = { k = k, title = title, x = x, y = y, w = M.ALERT_W, h = M.ALERT_H, side = side, box = box }
    if #M._alert_log > 20 then table.remove(M._alert_log, 1) end
    mark('alert' .. slot, 2.8); wake(2.8)
    -- a short GPU glow pulse on the badge (particles toggle / Lite respected; never inside the body box)
    if CV and C.particles_on() and not C.cfg.lite and C.cfg.fx.dx11 then
        local r, g, b = C.hex_rgb(color)
        pcall(function() CV.glow_at(x + 26, y + M.ALERT_H * 0.5, r, g, b, 30, 650) end)
    end
    return true
end
M.MOM_W, M.MOM_H = 380, 66
function M.moment(title, sub, color, sound)
    if not O or not C.cfg.master or not cards_on() then
        if O and C.cfg.master and sound then FT.play() end         -- ps1: the card is off, its own sound switch still counts
        return false
    end
    local x, y, side, box = FT.place_above(M.MOM_W, M.MOM_H, SW, SH, nil, M.panels())
    if not x then return false end
    color = color or '#ffd040'
    O:text('momt', title or ''); O:style('momt', 'color', color)
    O:style('momt', 'font-size', math.floor(FT.min_size(24)) .. 'px')
    O:text('moms', sub or '')
    O:style('mom', 'left', x .. 'px'); O:style('mom', 'top', y .. 'px')
    O:anim('mom', 'moment', 3.2, 'cubic-out'); O:anim('moml', 'orn', 3.2, 'cubic-out'); O:anim('momr', 'orn', 3.2, 'cubic-out')
    M._moment_last = { title = title, x = x, y = y, w = M.MOM_W, h = M.MOM_H, side = side, box = box }
    mark('moment', 3.2); wake(3.2)
    if CV and C.particles_on() and not C.cfg.lite then cv('flare', x + M.MOM_W * 0.5, y + M.MOM_H * 0.5) end
    if sound then FT.play() end
    return true
end
function M.meter_live(d)
    if not O then return end
    local on = d ~= nil and C.cfg.master and M.on('livemeter') and cards_on()
    if on then
        O:text('lmv', C.fmt(d.dps))
        -- pa1: big number = whole-fight DPS (first hit -> now); small = rolling last 10 s
        O:text('lmt', string.format('10s %s · %s in %ds · crit %.0f%%', C.fmt(d.rdps or d.dps), C.fmt(d.total), math.floor(d.secs), d.crit))
        for i = 1, 20 do
            local h = d.smax > 0 and math.max(1, math.floor((d.spark[i] or 0) / d.smax * 30 + 0.5)) or 1
            O:style('lb' .. i, 'height', h .. 'px'); O:style('lb' .. i, 'top', (30 - h) .. 'px')
        end
        O:text('lma', d.top ~= '' and string.format('Top: %s %d%%', d.top, d.topp) or '')
        O:show(true)
    end
    if on ~= lm_on then lm_on = on; O:class('lm', 'on', on) end
end
function M.meter_live_on() return lm_on end
-- ---------------------------------------------------------------- f8b: death recap card + group / raid meter (beside you, never over you)
M.DRC_W = 366
function M.death_recap(html, dur)
    if not O or not C.cfg.master or not cards_on() then return false end
    dur = dur or 15
    local w, h = M.DRC_W, (FT.recap_height and FT.recap_height(html)) or 300
    -- the opposite column from a recap that is still up; never over the body box
    local x, y = M.recap_place(w, h)
    if x and M._recap_rect and (fx_until.recap or 0) > C.now() and FT.overlap({ x, y, x + w, y + h }, M._recap_rect) then
        local fx, fy, ux, uy, span, _, wmul = FT.capsule()
        local b = { FT.body_box(fx, fy, ux, uy, span, wmul) }
        local x2 = (x < SW / 2) and (SW - math.floor(SW * 0.05) - w) or math.floor(SW * 0.05)
        if not FT.overlap({ x2, y, x2 + w, y + h }, b) then x = x2 else x = nil end
    end
    if not x then M._drc_rect = nil; return false end
    M._drc_rect = { x, y, x + w, y + h }
    O:style('drc', 'left', x .. 'px'); O:style('drc', 'top', y .. 'px')
    O:rml('drc', html); O:anim('drc', 'recap', dur, 'linear'); mark('drc', dur); wake(dur)
    return true
end
M.GM_W = 252
local gm_html = nil
function M.gm_place(h)
    local x, y = math.floor(SW * 0.05), math.floor(SH * 0.27) + (lm_on and (M.LM_H + 14) or 0)
    local fx, fy, ux, uy, span, _, wmul = FT.capsule()
    local b = { FT.body_box(fx, fy, ux, uy, span, wmul) }
    if not FT.overlap({ x, y, x + M.GM_W, y + h }, b) then return x, y end
    x = SW - math.floor(SW * 0.05) - M.GM_W
    if not FT.overlap({ x, y, x + M.GM_W, y + h }, b) then return x, y end
    return nil
end
-- html = nil hides the panel
function M.group_meter(html, h)
    if not O then return end
    if not html or not C.cfg.master or not cards_on() then
        if M._gm_rect then M._gm_rect = nil; gm_html = nil; O:class('gm', 'on', false) end
        return
    end
    local x, y = M.gm_place(h)
    if not x then if M._gm_rect then M._gm_rect = nil; gm_html = nil; O:class('gm', 'on', false) end; return end
    if html ~= gm_html then gm_html = html; O:rml('gm', html) end
    if not M._gm_rect or M._gm_rect[1] ~= x or M._gm_rect[2] ~= y then
        O:style('gm', 'left', x .. 'px'); O:style('gm', 'top', y .. 'px')
        if not M._gm_rect then O:class('gm', 'on', true) end
        M._gm_rect = { x, y, x + M.GM_W, y + h }
    end
    O:show(true)
end
-- ---------------------------------------------------------------- f10: Tracking panel + world labels above mobs
-- Tracking panel (buffs fading, DoTs on the target, pet split): right column, else left under the group meter;
-- never over the body box or another panel; hidden when nothing fits
M.TK_W = 236
local tk_html = nil
function M.tk_place(h)
    local fx, fy, ux, uy, span, _, wmul = FT.capsule()
    local b = { FT.body_box(fx, fy, ux, uy, span, wmul) }
    local others = {}
    for _, r in ipairs(M.panels()) do if not (M._tk_rect and r[1] == M._tk_rect[1] - 6 and r[2] == M._tk_rect[2] - 6) then others[#others + 1] = r end end
    local cands = {
        { SW - math.floor(SW * 0.05) - M.TK_W, math.floor(SH * 0.30) },
        { math.floor(SW * 0.05), math.floor(SH * 0.27) + (lm_on and (M.LM_H + 14) or 0) + (M._gm_rect and (M._gm_rect[4] - M._gm_rect[2] + 14) or 0) },
    }
    for _, c in ipairs(cands) do
        local r = { c[1], c[2], c[1] + M.TK_W, c[2] + h }
        if r[4] < SH - 8 and not FT.overlap(r, b) and FT.clear_of(r, others) then return c[1], c[2] end
    end
    return nil
end
function M.track_panel(html, h)
    if not O then return end
    if not html or not C.cfg.master or not cards_on() then
        if M._tk_rect then M._tk_rect = nil; tk_html = nil; O:class('tk', 'on', false) end
        return
    end
    local x, y = M.tk_place(h)
    if not x then if M._tk_rect then M._tk_rect = nil; tk_html = nil; O:class('tk', 'on', false) end; return end
    if html ~= tk_html then tk_html = html; O:rml('tk', html) end
    if not M._tk_rect or M._tk_rect[1] ~= x or M._tk_rect[2] ~= y or M._tk_rect[4] ~= y + h then
        O:style('tk', 'left', x .. 'px'); O:style('tk', 'top', y .. 'px')
        if not M._tk_rect then O:class('tk', 'on', true) end
        M._tk_rect = { x, y, x + M.TK_W, y + h }
    end
    O:show(true)
end
-- world label (track.lua places it above the mob's head and re-checks it against the body box every move)
M._wl_log = {}
function M.wlabel(slot, title, sub, color, x, y, dur, stem)
    if not O or not C.cfg.master or not cards_on() then return false end
    local id = 'wl' .. slot
    color = color or '#ff4030'
    O:rml(id, string.format('<div class="wlb" style="background-color: %s;"></div><span class="wlt" style="color: %s;">%s</span><span class="wls">%s</span><div class="wlp" id="wlp%d" style="background-color: %s; left: %dpx;"></div>',
        color, color, C.esc(title or ''), C.esc(sub or ''), slot, color, stem or 114))
    O:style(id, 'left', x .. 'px'); O:style(id, 'top', y .. 'px')
    O:anim(id, 'wlab', dur, 'linear')
    wl_rect[slot] = { x, y, x + 230, y + 44, C.now() + math.floor(dur * 1000), stem or 114 }
    M._wl_log[#M._wl_log + 1] = { slot = slot, title = title, x = x, y = y }
    if #M._wl_log > 20 then table.remove(M._wl_log, 1) end
    mark('wl' .. slot, dur); wake(dur)
    if CV and C.particles_on() and not C.cfg.lite and C.cfg.fx.dx11 then
        local r, g, b = C.hex_rgb(color)
        pcall(function() CV.glow_at(x + 115, y + 22, r * 0.9, g * 0.9, b * 0.9, 34, 600) end)   -- under the badge, not over you
    end
    return true
end
function M.wlabel_move(slot, x, y, stem)
    local r = wl_rect[slot]
    if not O or not r then return end
    if r[1] ~= x or r[2] ~= y then O:style('wl' .. slot, 'left', x .. 'px'); O:style('wl' .. slot, 'top', y .. 'px') end
    if stem and stem ~= r[6] then O:style('wlp' .. slot, 'left', stem .. 'px'); r[6] = stem end
    r[1], r[2], r[3], r[4] = x, y, x + 230, y + 44
end
function M.wlabel_hide(slot)
    if not O or not wl_rect[slot] then return end
    O:style('wl' .. slot, 'left', '-2000px'); wl_rect[slot] = nil
end
function M.wl_rects() return wl_rect end
function M.death(sub)
    if not M.on('death') or not cards_on() then return end
    O:text('dsub', sub or ''); O:anim('death', 'death', 4.5, 'linear'); mark('death', 4.5); wake(4.5)
    cv('death')
end
-- cast bar: width written at most 10x a second (whole percent, diffed), hidden as soon as the cast ends
function M.cast_start(name, ms)
    if not M.on('castbar') or not ms or ms < 300 then return end
    M._cb = { t0 = C.now(), ms = ms, next = 0 }
    O:text('cbn', name or ''); O:style('cbf', 'width', '0%'); O:class('cbar', 'on', true); O:show(true)
end
function M.cast_stop()
    if not M._cb then return end
    M._cb = nil; if O then O:class('cbar', 'on', false) end
end
function M.cast_frame(now)
    local cb = M._cb; if not cb or now < cb.next then return end
    cb.next = now + 100
    local el = now - cb.t0
    if el > cb.ms + 600 or not M.on('castbar') then return M.cast_stop() end
    O:style('cbf', 'width', math.floor(C.clamp(el / cb.ms * 100, 0, 100)) .. '%')
    O:text('cbt', string.format('%.1f', math.max(0, (cb.ms - el) / 1000)))
end
return M
