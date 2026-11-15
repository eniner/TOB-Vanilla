-- combatfx/fightui.lua (fd1): Parses > fight detail, a parser-style view of one fight: DPS / HPS / damage-taken
-- graphs (per second, optional smoothing, a line per source or per ability, click a second for its breakdown),
-- sortable breakdown tables (sources, abilities, incoming, healing), the event log (filter by type / source /
-- ability / second) and the cast / spell marker strip on the graph's time axis. Plain RML (divs), built on click
-- only: nothing here runs per frame. Every name from the fight goes through C.esc.
local C = require('combatfx.core')
local FT = require('combatfx.features')
local PS = require('combatfx.parses')
local U = { REV = 'fd1' }
local A, btn, seg, render                      -- ui.lua helpers, bound by U.bind
function U.bind(h) A, btn, seg, render = h.A, h.btn, h.seg, h.render end
local e = function(s) return C.esc(s) end
local PW, PH, GUT = 600, 150, 44              -- plot width / height (px), y-axis gutter
U.SHORT = 3                                    -- ps1: fewer columns than this draw as bars, not a line
U.COLS = 150                                  -- most graph columns drawn (one per second up to 2.5 min)
U.PAGE = 40                                   -- event rows per page
local COL = { '#ffd27a', '#ff8a8a', '#8ac8ff', '#6aff8a', '#d090ff', '#ffb347', '#40e0d0', '#ff70c0', '#c8ff40', '#a0a8b8', '#ff5a4a', '#70a0ff', '#e0c090' }
local TLC = { burn = '#ff5a4a', cast = '#8ac8ff', aa = '#d090ff', spell = '#ffb347', proc = '#6aff8a' }
U.TLC = TLC
-- view state
local S = { tab = 'dmg', gm = 'dps', sm = 0, hide = {}, sel = nil, sort = {}, evk = 'all', evs = 'all', eva = nil, evp = 1, src = 'all' }
U.S = S
function U.reset() S.tab, S.gm, S.sel, S.hide, S.evk, S.evs, S.eva, S.evp, S.src = 'dmg', 'dps', nil, {}, 'all', 'all', nil, 1, 'all' end

local function short(n)
    n = tonumber(n) or 0
    local a = math.abs(n)
    if a >= 1e9 then return string.format('%.2fb', n / 1e9) end
    if a >= 1e6 then return string.format('%.2fm', n / 1e6) end
    if a >= 1e4 then return string.format('%.1fk', n / 1e3) end
    return tostring(math.floor(n + 0.5))
end
U.short = short
local function pct(a, b) return (b or 0) > 0 and (a / b * 100) or 0 end
local function nice(v)
    if v <= 0 then return 1 end
    local p = 10 ^ math.floor(math.log10 and math.log10(v) or (math.log(v) / math.log(10)))
    for _, m in ipairs({ 1, 2, 2.5, 5, 10 }) do if v <= m * p then return m * p end end
    return 10 * p
end
local function nm(d, i) return (d.names or {})[i] or '' end
local function srcname(d, s) if s == 'Pet' and d and (d.pet or '') ~= '' then return 'Pet (' .. d.pet .. ')' end; return s end
U.srcname = srcname

-- ---------------------------------------------------------------- series -> display columns
-- arr = sums per bucket of d.bs seconds; returns per-second rates per display column, column count, seconds per column
local function columns(d, arr, nref)
    local n = #arr
    local g = math.max(1, math.ceil(math.max(n, nref or 0) / U.COLS))   -- same bucketing for every line on one graph
    local o = {}
    local spc = g * (d.bs or 1)
    for c = 1, math.ceil(n / g) do
        local s = 0
        for i = (c - 1) * g + 1, math.min(n, c * g) do s = s + (arr[i] or 0) end
        local secs = math.max(1, math.min(spc, (d.len or n) - (c - 1) * spc))
        o[c] = s / secs
    end
    return o, g, spc
end
local function smooth(v, w)
    if not w or w <= 1 then return v end
    local o, h = {}, math.floor(w / 2)
    for i = 1, #v do
        local s, k = 0, 0
        for j = math.max(1, i - h), math.min(#v, i + h) do s = s + v[j]; k = k + 1 end
        o[i] = s / math.max(1, k)
    end
    return o
end
U.columns, U.smooth = columns, smooth
-- ps1: time-axis ticks: whole seconds, unique, a nice step (1 2 5 10 15 20 30 s, 1 2 3 5 10 15 20 30 min ...), at most 6
local STEPS = { 1, 2, 5, 10, 15, 20, 30, 60, 120, 180, 300, 600, 900, 1200, 1800, 3600, 7200 }
function U.ticks(secs)
    secs = math.max(1, math.floor((secs or 1) + 0.5))
    local step = STEPS[#STEPS]
    for _, st in ipairs(STEPS) do if secs / st <= 5 then step = st; break end end
    local t = {}
    for v = 0, secs, step do t[#t + 1] = v end
    if secs - t[#t] >= step * 0.5 then t[#t + 1] = secs end       -- the end, when it is not crowding the last tick
    return t
end
function U.tlabel(v) if v >= 60 and v % 60 == 0 then return (v / 60) .. 'm' elseif v >= 60 then return string.format('%dm%02d', math.floor(v / 60), v % 60) end; return v .. 's' end
local function ser(d, kind, src, ab)
    for _, s in ipairs(d.ser or {}) do if s[1] == kind and (src == nil or s[2] == src) and (ab == nil or s[3] == ab) then return s[4] end end
end
-- the graph lines for a mode: { key, label, color, arr }
function U.lines(d, mode)
    local L = {}
    local ci = 0
    local function add(key, label, arr) ci = ci + 1; L[#L + 1] = { key = key, label = label, color = COL[(ci - 1) % #COL + 1], arr = arr } end
    for _, s in ipairs(d.ser or {}) do
        if mode == 'dps' and s[1] == 'o' then add('o|' .. s[2], srcname(d, s[2]), s[4])
        elseif mode == 'abil' and s[1] == 'a' then add('a|' .. s[2] .. '|' .. s[3], (s[2] == 'You' and '' or (srcname(d, s[2]) .. ': ')) .. s[3], s[4])
        elseif mode == 'dtps' and s[1] == 'ia' then add('ia|' .. s[2], s[2], s[4]) end
    end
    if mode == 'hps' then
        local h, hi = ser(d, 'h'), ser(d, 'hi')
        if h then add('h', 'Healing done', h) end
        if hi then add('hi', 'Healing received', hi) end
    end
    return L
end
-- the shaded total behind the lines (damage out, or damage taken)
local function total(d, mode)
    if mode == 'dtps' then return ser(d, 'i') end
    if mode == 'hps' then return nil end
    local t
    for _, s in ipairs(d.ser or {}) do
        if s[1] == 'o' then t = t or {}; for i, v in ipairs(s[4]) do t[i] = (t[i] or 0) + v end end
    end
    return t
end
U.total = total

-- ---------------------------------------------------------------- graph (divs: shaded columns + stepped lines)
local function seg_line(o, xs, ys, color)
    local n = #ys
    local i = 1
    while i <= n do                                                    -- horizontal runs at the same height
        local j = i
        while j < n and ys[j + 1] == ys[i] do j = j + 1 end
        o[#o + 1] = string.format('<div class="fgl" style="left: %dpx; bottom: %dpx; width: %dpx; height: 2px; background-color: %s;"></div>', xs[i], ys[i], math.max(1, xs[j + 1] - xs[i]), color)
        if j < n then
            local a, b = ys[j], ys[j + 1]
            local lo, hi = math.min(a, b), math.max(a, b)
            o[#o + 1] = string.format('<div class="fgl" style="left: %dpx; bottom: %dpx; width: 2px; height: %dpx; background-color: %s;"></div>', xs[j + 1] - 1, lo, hi - lo + 2, color)
        end
        i = j + 1
    end
end
-- opts: { lines = {...}, area = arr, len = secs, bs, tl = record timeline, sel = {c0, c1}, click = fn(col, spc), unit = 'dps' }
function U.graph(d, opts)
    local o = {}
    local nref = opts.area and #opts.area or 0
    for _, ln in ipairs(opts.lines or {}) do if #ln.arr > nref then nref = #ln.arr end end
    local area = opts.area and columns(d, opts.area, nref) or nil
    local cols, g, spc = nil, 1, d.bs or 1
    local vis = {}
    for _, ln in ipairs(opts.lines or {}) do
        local v; v, g, spc = columns(d, ln.arr, nref)
        local w = S.sm > 0 and math.max(1, math.floor(S.sm / spc + 0.5)) or 1
        v = smooth(v, w)
        cols = math.max(cols or 0, #v)
        if not S.hide[ln.key] then vis[#vis + 1] = { ln, v } end
    end
    if area then
        local w = S.sm > 0 and math.max(1, math.floor(S.sm / spc + 0.5)) or 1
        area = smooth(area, w); cols = math.max(cols or 0, #area)
        if not opts.lines or #opts.lines == 0 then g = math.max(1, math.ceil(nref / U.COLS)); spc = g * (d.bs or 1) end
    end
    cols = math.max(1, cols or 1)
    local mx = 0
    for _, x in ipairs(vis) do for _, v in ipairs(x[2]) do if v > mx then mx = v end end end
    if area then for _, v in ipairs(area) do if v > mx then mx = v end end end
    mx = nice(mx)
    local cw = PW / cols
    local xs = {}
    for c = 1, cols + 1 do xs[c] = math.floor((c - 1) * cw + 0.5) end
    local function y(v) return math.floor(math.min(1, (v or 0) / mx) * (PH - 2) + 0.5) end
    -- ps1: under U.SHORT columns a stepped line is one flat segment across the whole width (reads as "not a graph"):
    -- draw one bar per second per line instead, plus a note
    local short_fight = cols < U.SHORT
    o[#o + 1] = '<div class="fgw"><div class="fgp">'
    for _, f in ipairs({ 0.25, 0.5, 0.75, 1 }) do o[#o + 1] = string.format('<div class="fgh" style="bottom: %dpx;"></div>', math.floor(f * (PH - 2))) end
    if opts.sel then
        local a, b = opts.sel[1], opts.sel[2]
        o[#o + 1] = string.format('<div class="fgs" style="left: %dpx; width: %dpx;"></div>', xs[a] or 0, math.max(2, (xs[b + 1] or PW) - (xs[a] or 0)))
    end
    if area and not short_fight then
        for c, v in ipairs(area) do
            local h = y(v)
            if h > 0 then o[#o + 1] = string.format('<div class="fga" style="left: %dpx; width: %dpx; height: %dpx;%s"></div>', xs[c], math.max(1, xs[c + 1] - xs[c]), h, opts.area_color and (' background-color: ' .. opts.area_color .. ';') or '') end
        end
    end
    if short_fight then
        local nb = math.max(1, #vis + ((area and #vis == 0) and 1 or 0))
        for c = 1, cols do
            local cw2 = xs[c + 1] - xs[c]
            local bw = math.max(4, math.min(36, math.floor(cw2 * 0.6 / nb)))
            local x0 = xs[c] + math.floor((cw2 - bw * nb) / 2)
            if #vis == 0 and area then
                local h = y(area[c]); if h > 0 then o[#o + 1] = string.format('<div class="fgb" style="left: %dpx; width: %dpx; height: %dpx; background-color: %s;"></div>', x0, bw, h, opts.area_color or '#ffffff40') end
            end
            for i, x in ipairs(vis) do
                local h = y(x[2][c] or 0)
                if h > 0 then o[#o + 1] = string.format('<div class="fgb" style="left: %dpx; width: %dpx; height: %dpx; background-color: %s;"></div>', x0 + (i - 1) * bw, bw, h, x[1].color) end
            end
        end
    else
        for _, x in ipairs(vis) do
            local ys = {}
            for c = 1, #x[2] do ys[c] = y(x[2][c] or 0) end          -- a shorter fight's line ends where it ended
            seg_line(o, xs, ys, x[1].color)
        end
    end
    -- click targets (one per column): pick that second for the breakdown
    if opts.click then
        for c = 1, cols do
            o[#o + 1] = string.format('<div class="fgc%s" style="left: %dpx; width: %dpx;"%s></div>', (opts.sel and c >= opts.sel[1] and c <= opts.sel[2]) and ' sel' or '',
                xs[c], math.max(1, xs[c + 1] - xs[c]), A(function() opts.click(c, spc) end))
        end
    end
    o[#o + 1] = '</div>'
    local unit = opts.unit or 'dps'
    o[#o + 1] = string.format('<span class="fgy" style="top: 4px;">%s</span><span class="fgy" style="top: %dpx;">%s</span><span class="fgy" style="top: %dpx;">0</span>',
        short(mx), 4 + math.floor(PH / 2), short(mx / 2), PH + 2)
    local secs = d.len or (cols * spc)
    -- ps1: whole, unique, evenly stepped time ticks (was secs * i / 4 rounded: "0s 0s 1s 1s 1s" on a 1 s fight)
    for _, tk in ipairs(U.ticks(secs)) do
        local px = math.floor(tk / math.max(1, secs) * PW + 0.5)
        o[#o + 1] = string.format('<span class="fgx" style="left: %dpx;">%s</span>', GUT + px - (px >= PW - 20 and 26 or (px == 0 and 0 or 10)), U.tlabel(tk))
    end
    o[#o + 1] = string.format('<span class="fgu">%s%s%s</span>', short_fight and ('<span class="wn">' .. math.floor(secs + 0.5) .. ' s: too short for a line, one bar per second</span> &#183; ') or '', unit, S.sm > 0 and (' &#183; ' .. S.sm .. ' s avg') or '')
    -- marker strip on the same time axis: casts / AAs / burns / spells / procs (the timeline the card counted)
    if opts.tl and #opts.tl > 0 then
        o[#o + 1] = '<div class="fgm">'
        for _, ev in ipairs(opts.tl) do
            local x = math.floor(C.clamp((ev[3] or 0) / math.max(1, secs), 0, 1) * (PW - 3))
            o[#o + 1] = string.format('<div class="fgk" style="left: %dpx; background-color: %s;"></div>', x, TLC[ev[1]] or '#ffffff')
        end
        o[#o + 1] = '</div>'
    end
    o[#o + 1] = '</div>'
    return table.concat(o), cols, spc
end
local function legend(lines, total_label, total_v)
    local o = { '<div class="fgleg">' }
    if total_label then o[#o + 1] = string.format('<span class="fgli"><span class="fglc" style="background-color: #ffffff40;"></span>%s %s</span>', total_label, short(total_v)) end
    for _, ln in ipairs(lines) do
        local s = 0; for _, v in ipairs(ln.arr) do s = s + v end
        o[#o + 1] = string.format('<span class="fgli%s"%s><span class="fglc" style="background-color: %s;"></span>%s %s</span>', S.hide[ln.key] and ' off' or '',
            A(function() S.hide[ln.key] = not S.hide[ln.key]; render() end), ln.color, e(ln.label), short(s))
    end
    o[#o + 1] = '</div>'
    return table.concat(o)
end

-- ---------------------------------------------------------------- sortable table
-- cols: { key, label, width, fmt(row) -> text, num(row) -> sort value }
local function sorted(rows, tid, cols, def)
    local st = S.sort[tid] or { def or cols[2][1], true }
    local col
    for _, c in ipairs(cols) do if c[1] == st[1] then col = c end end
    col = col or cols[2]
    local t = {}
    for i, r in ipairs(rows) do t[i] = r end
    table.sort(t, function(a, b)
        local x, y = col[5](a), col[5](b)
        if x == y then return tostring(a.n or a[1]) < tostring(b.n or b[1]) end
        if type(x) ~= type(y) then x, y = tostring(x), tostring(y) end
        if st[2] then return x > y end
        return x < y
    end)
    return t, st
end
function U.table(tid, title, rows, cols, def, onrow, maxn)
    local o = {}
    local t, st = sorted(rows, tid, cols, def)
    o[#o + 1] = '<div class="ftb">'
    o[#o + 1] = string.format('<div class="ftt">%s</div>', title)
    local h = { '<div class="ftr fth">' }
    local x = 6
    for _, c in ipairs(cols) do
        local on = st[1] == c[1]
        h[#h + 1] = string.format('<span class="ftc%s%s" style="left: %dpx; width: %dpx;"%s>%s%s</span>', on and ' on' or '', c[6] and ' l' or '', x, c[3],
            A(function() local cur = S.sort[tid]; if cur and cur[1] == c[1] then cur[2] = not cur[2] else S.sort[tid] = { c[1], not c[6] } end; render() end),
            c[2], on and (st[2] and ' &#9660;' or ' &#9650;') or '')
        x = x + c[3] + 4
    end
    h[#h + 1] = '</div>'
    o[#o + 1] = table.concat(h)
    if #t == 0 then o[#o + 1] = '<div class="ftr"><span class="ftc l dim" style="left: 6px; width: 400px;">none in this fight</span></div>' end
    for i, r in ipairs(t) do
        if maxn and i > maxn then o[#o + 1] = string.format('<div class="ftr"><span class="ftc l dim" style="left: 6px; width: 400px;">+ %d more</span></div>', #t - maxn); break end
        local cells = {}
        x = 6
        for _, c in ipairs(cols) do
            cells[#cells + 1] = string.format('<span class="ftc%s" style="left: %dpx; width: %dpx;">%s</span>', c[6] and ' l' or '', x, c[3], c[4](r))
            x = x + c[3] + 4
        end
        o[#o + 1] = string.format('<div class="ftr%s%s"%s>%s</div>', i % 2 == 0 and ' z' or '', onrow and ' ck' or '', onrow and A(function() onrow(r) end) or '', table.concat(cells))
    end
    o[#o + 1] = '</div>'
    return table.concat(o)
end
local function avoid(r) return (r.miss or 0) + (r.dodge or 0) + (r.parry or 0) + (r.block or 0) + (r.riposte or 0) + (r.rune or 0) + (r.invuln or 0) + (r.other or 0) end
U.avoid = avoid

-- ---------------------------------------------------------------- the fight view
local function header(r, d, back)
    local o = {}
    local tot = (r.you or 0) + (r.pet or 0)
    o[#o + 1] = '<div class="fdh">' .. btn('&#9664; Back', back, 'sm') ..
        string.format('<span class="fdt">%s</span><span class="fdd">%s &#183; %s &#183; %ds%s%s</span><span class="fdn">%s dps</span><span class="fdm">%s dmg</span></div>',
            e(r.mob ~= '' and r.mob or 'fight'), r.live and 'fight in progress' or (r.id == -2 and 'practice fight (not saved)' or os.date('%m-%d %H:%M', r.t or 0)),
            e(r.zone ~= '' and r.zone or '?'), math.floor(r.secs or 0), r.label ~= '' and (' &#183; [' .. e(r.label) .. ']') or '',
            r.died and ' &#183; <span class="wn">died</span>' or '', C.fmt(r.dps or 0), C.fmt(tot))
    return table.concat(o)
end
-- what happened in seconds [t0, t1): for the graph mode shown (damage out, healing, or damage taken)
local function breakdown(d, t0, t1, mode)
    mode = mode or 'dps'
    local b0, b1 = math.floor(t0 / (d.bs or 1)) + 1, math.ceil(t1 / (d.bs or 1))
    local function sum(arr) local s = 0; for i = b0, math.min(#arr, b1) do s = s + (arr[i] or 0) end; return s end
    local secs = math.max(1, t1 - t0)
    local src, ab = {}, {}
    for _, s in ipairs(d.ser or {}) do
        local v = sum(s[4])
        if v > 0 then
            if (mode == 'dps' or mode == 'abil') and s[1] == 'o' then src[#src + 1] = { srcname(d, s[2]), v } end
            if (mode == 'dps' or mode == 'abil') and s[1] == 'a' then ab[#ab + 1] = { (s[2] == 'You' and '' or (srcname(d, s[2]) .. ': ')) .. s[3], v } end
            if mode == 'dtps' and s[1] == 'ia' then src[#src + 1] = { s[2], v } end
            if mode == 'hps' and s[1] == 'h' then src[#src + 1] = { 'Healing done', v } end
            if mode == 'hps' and s[1] == 'hi' then src[#src + 1] = { 'Healing received', v } end
        end
    end
    table.sort(src, function(a, b) return a[2] > b[2] end); table.sort(ab, function(a, b) return a[2] > b[2] end)
    local KM = { dps = { d = true }, abil = { d = true }, dtps = { i = true }, hps = { h = true, H = true } }
    local hits, crits, n = 0, 0, 0
    local byab = {}
    for _, ev in ipairs(d.ev or {}) do
        local t = ev[1] / 10
        if t >= t0 and t < t1 then
            n = n + 1
            if KM[mode][ev[2]] then
                hits = hits + 1; if tostring(ev[6]):find('c', 1, true) then crits = crits + 1 end
                if mode ~= 'dps' and mode ~= 'abil' then local k = nm(d, ev[4]); byab[k] = (byab[k] or 0) + (ev[5] or 0) end
            end
        end
    end
    for k, v in pairs(byab) do ab[#ab + 1] = { k, v } end
    table.sort(ab, function(a, b) return a[2] > b[2] end)
    local tot = 0
    if mode == 'hps' then for _, x in ipairs(src) do if x[1] == 'Healing done' then tot = x[2] end end; if tot == 0 and src[1] then tot = src[1][2] end
    else for _, x in ipairs(src) do tot = tot + x[2] end end
    local what = mode == 'dtps' and 'taken' or (mode == 'hps' and 'healed' or 'dmg')
    local o = { string.format('<div class="fbk"><span class="fbh">%ds &#8211; %ds</span> <span class="dim">%s %s &#183; %s / s &#183; %d %s, %d crits &#183; %d events</span>',
        math.floor(t0), math.floor(t1), short(tot), what, short(tot / secs), hits, mode == 'hps' and 'heals' or 'hits', crits, n) }
    local p = {}
    for i = 1, math.min(5, #src) do p[#p + 1] = e(src[i][1]) .. ' ' .. short(src[i][2]) end
    if #p > 0 then o[#o + 1] = '<div class="fbl">' .. (mode == 'dtps' and 'From: ' or (mode == 'hps' and '' or 'Sources: ')) .. table.concat(p, ' &#183; ') .. '</div>' end
    p = {}
    for i = 1, math.min(6, #ab) do p[#p + 1] = e(ab[i][1]) .. ' ' .. short(ab[i][2]) end
    if #p > 0 then o[#o + 1] = '<div class="fbl">' .. (mode == 'hps' and 'Spells: ' or 'Abilities: ') .. table.concat(p, ' &#183; ') .. '</div>' end
    if #src == 0 then o[#o + 1] = '<div class="fbl dim">Nothing of this kind in this second</div>' end
    o[#o + 1] = '</div>'
    return table.concat(o)
end
U.breakdown = breakdown
local GM = { { 'dps', 'DPS by source' }, { 'abil', 'DPS by ability' }, { 'hps', 'Healing' }, { 'dtps', 'Damage taken' } }
local SM = { { 0, 'Raw' }, { 3, '3 s' }, { 5, '5 s' }, { 10, '10 s' } }
local function graph_block(r, d, mode)
    local o = {}
    o[#o + 1] = '<div class="fgo">' .. seg(GM, mode, function(v) S.gm = v; S.hide = {}; render() end) .. seg(SM, S.sm, function(v) S.sm = v; render() end) .. '</div>'
    local lines = U.lines(d, mode)
    local area = total(d, mode)
    local unit = mode == 'hps' and 'hps' or (mode == 'dtps' and 'damage taken / s' or 'dps')
    if #lines == 0 and not area then o[#o + 1] = '<div class="empty">Nothing of this kind in this fight</div>'; return table.concat(o) end
    local sel = S.sel
    local html, cols, spc = U.graph(d, { lines = lines, area = area, tl = mode ~= 'dtps' and r.tl or nil, unit = unit,
        sel = sel and { sel[1], sel[2] } or nil, area_color = mode == 'dtps' and '#ff504040' or nil,
        click = function(c, sp) S.sel = { c, c, (c - 1) * sp, c * sp }; render() end })
    o[#o + 1] = html
    local at = 0; if area then for _, v in ipairs(area) do at = at + v end end
    o[#o + 1] = legend(lines, area and (mode == 'dtps' and 'Taken' or 'Total') or nil, at)
    if sel and sel[3] then
        o[#o + 1] = breakdown(d, sel[3], math.min(d.len or sel[4], sel[4]), mode)
        o[#o + 1] = '<div class="fbt">' .. btn('Events in this second', function() S.tab = 'ev'; S.evt = { sel[3], sel[4] }; S.evp = 1; render() end, 'sm') ..
            btn('Clear pick', function() S.sel = nil; render() end, 'sm') .. '</div>'
    else
        o[#o + 1] = '<div class="note2">Click the graph for what happened in that second. Click a name in the legend to hide or show its line. Markers under the graph: casts (blue), AAs (violet), burns (red), your spells landing (orange), procs (green).</div>'
    end
    return table.concat(o)
end
local function src_tab(d)
    local tot = 0; for _, s in ipairs(d.src or {}) do tot = tot + (s[2] or 0) end
    local rows = {}
    for _, s in ipairs(d.src or {}) do rows[#rows + 1] = { n = s[1], d = s[2], h = s[3], k = s[4], mx = s[5] } end
    local secs = math.max(1, d.len or 1)
    return U.table('src', 'DAMAGE BY SOURCE', rows, {
        { 'n', 'Source', 150, function(x) return e(srcname(d, x.n)) end, function(x) return x.n end, true },
        { 'd', 'Total', 70, function(x) return short(x.d) end, function(x) return x.d end },
        { 'p', '%', 44, function(x) return string.format('%.1f', pct(x.d, tot)) end, function(x) return x.d end },
        { 'dps', 'DPS', 60, function(x) return short(x.d / secs) end, function(x) return x.d end },
        { 'h', 'Hits', 50, function(x) return tostring(x.h) end, function(x) return x.h end },
        { 'a', 'Avg', 60, function(x) return short(x.d / math.max(1, x.h)) end, function(x) return x.d / math.max(1, x.h) end },
        { 'mx', 'Max', 60, function(x) return short(x.mx) end, function(x) return x.mx end },
        { 'k', 'Crit %', 50, function(x) return string.format('%.0f', pct(x.k, x.h)) end, function(x) return pct(x.k, x.h) end },
    }, 'd', function(x) S.src = x.n; render() end)
end
local function abil_tab(d, secs)
    local tot = 0; for _, a in ipairs(d.ab or {}) do tot = tot + (a.d or 0) end
    local rows = {}
    for _, a in ipairs(d.ab or {}) do if S.src == 'all' or a.s == S.src then rows[#rows + 1] = a end end
    local srcs = { { 'all', 'All' } }
    for i, s in ipairs(d.src or {}) do if i <= 5 then srcs[#srcs + 1] = { s[1], e(srcname(d, s[1])) } end end
    local o = { '<div class="fgo">' .. seg(srcs, S.src, function(v) S.src = v; render() end) .. '</div>' }
    o[#o + 1] = U.table('ab', 'DAMAGE BY ABILITY / SPELL &#183; <span class="dim">click a row for its events</span>', rows, {
        { 'n', 'Ability', 124, function(x) return e((x.s ~= 'You' and S.src == 'all') and (srcname(d, x.s) .. ': ' .. x.n) or x.n) end, function(x) return x.n end, true },
        { 'd', 'Total', 50, function(x) return short(x.d) end, function(x) return x.d end },
        { 'p', '%', 32, function(x) return string.format('%.1f', pct(x.d, tot)) end, function(x) return x.d end },
        { 'h', 'Hits', 32, function(x) return tostring(x.h) end, function(x) return x.h end },
        { 'a', 'Avg', 42, function(x) return short((x.d or 0) / math.max(1, x.h)) end, function(x) return (x.d or 0) / math.max(1, x.h) end },
        { 'mn', 'Min', 40, function(x) return short(x.mn) end, function(x) return x.mn or 0 end },
        { 'mx', 'Max', 42, function(x) return short(x.mx) end, function(x) return x.mx or 0 end },
        { 'k', 'Crits', 30, function(x) return tostring(x.k or 0) end, function(x) return x.k or 0 end },
        { 'kp', 'Crit%', 32, function(x) return string.format('%.0f', pct(x.k or 0, x.h)) end, function(x) return pct(x.k or 0, x.h) end },
        { 'ka', 'C.avg', 42, function(x) return (x.k or 0) > 0 and short(x.kd / x.k) or '-' end, function(x) return (x.k or 0) > 0 and x.kd / x.k or 0 end },
        { 'dps', 'DPS', 42, function(x) return short((x.d or 0) / math.max(1, secs)) end, function(x) return x.d or 0 end },
        { 'up', 'Upt%', 32, function(x) return x.up and tostring(x.up) or '-' end, function(x) return x.up or -1 end },
        { 'av', 'Avoid', 36, function(x) local v = avoid(x); return v > 0 and tostring(v) or '-' end, function(x) return avoid(x) end },
        { 'res', 'Res', 28, function(x) return (x.res or 0) > 0 and tostring(x.res) or '-' end, function(x) return x.res or 0 end },
    }, 'd', function(x) S.tab = 'ev'; S.evs = x.s; S.eva = x.n; S.evk = 'all'; S.evt = nil; S.evp = 1; render() end)
    -- avoidance per ability, spelled out (the table shows the sum)
    local p = {}
    for _, a in ipairs(rows) do
        local v = avoid(a)
        if v > 0 then
            local q = {}
            for _, kk in ipairs({ 'miss', 'dodge', 'parry', 'block', 'riposte', 'rune', 'invuln', 'other' }) do if (a[kk] or 0) > 0 then q[#q + 1] = a[kk] .. ' ' .. kk end end
            local swings = (a.h or 0) + v
            p[#p + 1] = string.format('%s: %s (%.0f%% of %d swings)', e((a.s ~= 'You' and (srcname(d, a.s) .. ' ') or '') .. a.n), table.concat(q, ', '), pct(v, swings), swings)
        end
    end
    if #p > 0 then o[#o + 1] = '<div class="note2">Not landed: ' .. table.concat(p, ' &#183; ') .. '</div>' end
    o[#o + 1] = '<div class="note2">Upt% = DoT uptime, counting 6 s before each tick (EQ ticks every 6 s). Avoid = swings that missed, were dodged, parried, blocked, riposted or absorbed. Res = spells resisted.</div>'
    return table.concat(o)
end
local function def_tab(r, d, secs)
    local o = {}
    local tot = 0; for _, a in ipairs(d.inc or {}) do tot = tot + (a.d or 0) end
    local by, order = {}, {}
    for _, a in ipairs(d.inc or {}) do
        local b = by[a.s]; if not b then b = { n = a.s, d = 0, h = 0, mx = 0, k = 0 }; by[a.s] = b; order[#order + 1] = b end
        b.d, b.h, b.k = b.d + (a.d or 0), b.h + (a.h or 0), b.k + (a.k or 0); if (a.mx or 0) > b.mx then b.mx = a.mx end
    end
    for who, m in pairs(d.avby or {}) do
        local b = by[who]; if not b then b = { n = who, d = 0, h = 0, mx = 0, k = 0 }; by[who] = b; order[#order + 1] = b end
        local s = 0; for _, v in pairs(m) do s = s + v end; b.av = s
    end
    o[#o + 1] = U.table('isrc', 'DAMAGE TAKEN BY SOURCE', order, {
        { 'n', 'Attacker', 170, function(x) return e(x.n) end, function(x) return x.n end, true },
        { 'd', 'Total', 70, function(x) return short(x.d) end, function(x) return x.d end },
        { 'p', '%', 44, function(x) return string.format('%.1f', pct(x.d, tot)) end, function(x) return x.d end },
        { 'dps', 'Per s', 60, function(x) return short(x.d / math.max(1, secs)) end, function(x) return x.d end },
        { 'h', 'Hits', 44, function(x) return tostring(x.h) end, function(x) return x.h end },
        { 'mx', 'Max', 60, function(x) return short(x.mx) end, function(x) return x.mx end },
        { 'av', 'Avoided', 56, function(x) return tostring(x.av or 0) end, function(x) return x.av or 0 end },
        { 'ap', 'Avoid %', 56, function(x) return string.format('%.0f', pct(x.av or 0, (x.av or 0) + x.h)) end, function(x) return pct(x.av or 0, (x.av or 0) + x.h) end },
    }, 'd')
    o[#o + 1] = U.table('iab', 'DAMAGE TAKEN BY ABILITY', d.inc or {}, {
        { 'n', 'Ability', 150, function(x) return e(x.n) end, function(x) return x.n end, true },
        { 's', 'From', 130, function(x) return e(x.s) end, function(x) return x.s end, true },
        { 'd', 'Total', 60, function(x) return short(x.d) end, function(x) return x.d end },
        { 'p', '%', 40, function(x) return string.format('%.1f', pct(x.d, tot)) end, function(x) return x.d end },
        { 'h', 'Hits', 40, function(x) return tostring(x.h) end, function(x) return x.h end },
        { 'a', 'Avg', 56, function(x) return short(x.d / math.max(1, x.h)) end, function(x) return x.d / math.max(1, x.h) end },
        { 'mx', 'Max', 56, function(x) return short(x.mx) end, function(x) return x.mx end },
    }, 'd')
    -- avoidance: every swing at you, landed or not
    local av = d.av or {}
    local hits = 0; for _, a in ipairs(d.inc or {}) do if a.c == 'melee' then hits = hits + (a.h or 0) end end
    local sw = hits; for _, v in pairs(av) do sw = sw + v end
    local bar, txt = {}, {}
    local AC = { hit = '#ff5040', miss = '#8ac8ff', dodge = '#6aff8a', parry = '#ffd27a', block = '#d090ff', riposte = '#ffb347', rune = '#40e0d0', invuln = '#ffffff', other = '#a0a8b8' }
    for _, kk in ipairs({ 'hit', 'miss', 'dodge', 'parry', 'block', 'riposte', 'rune', 'invuln', 'other' }) do
        local v = kk == 'hit' and hits or (av[kk] or 0)
        if v > 0 then
            bar[#bar + 1] = string.format('<div class="fmx" style="width: %.1f%%; background-color: %s;"></div>', pct(v, sw), AC[kk])
            txt[#txt + 1] = string.format('<span style="color: %s;">%s %d (%.0f%%)</span>', AC[kk], kk == 'hit' and 'landed' or kk, v, pct(v, sw))
        end
    end
    o[#o + 1] = '<div class="ftt">AVOIDANCE &#183; <span class="dim">' .. sw .. ' melee swings at you</span></div>'
    if sw > 0 then o[#o + 1] = '<div class="favb">' .. table.concat(bar) .. '</div><div class="fbl">' .. table.concat(txt, ' &#183; ') .. '</div>'
    else o[#o + 1] = '<div class="empty">Nothing swung at you in this fight</div>' end
    if (r.res_in or 0) > 0 then o[#o + 1] = '<div class="fbl">You resisted ' .. r.res_in .. ' spell' .. (r.res_in > 1 and 's' or '') .. '</div>' end
    return table.concat(o)
end
local function heal_tab(d, secs)
    local outr, inr = {}, {}
    local to, ti = 0, 0
    for _, h in ipairs(d.heal or {}) do if h.c == 'out' then outr[#outr + 1] = h; to = to + h.d else inr[#inr + 1] = h; ti = ti + h.d end end
    local function cols(total, who)
        return {
            { 'n', 'Spell', 140, function(x) return e(x.n) end, function(x) return x.n end, true },
            { 't', who, 120, function(x) return e(who == 'Target' and x.t or x.s) end, function(x) return who == 'Target' and x.t or x.s end, true },
            { 'd', 'Total', 56, function(x) return short(x.d) end, function(x) return x.d end },
            { 'p', '%', 38, function(x) return string.format('%.1f', pct(x.d, total)) end, function(x) return x.d end },
            { 'h', 'Count', 40, function(x) return tostring(x.h) end, function(x) return x.h end },
            { 'a', 'Avg', 50, function(x) return short(x.d / math.max(1, x.h)) end, function(x) return x.d / math.max(1, x.h) end },
            { 'mx', 'Max', 50, function(x) return short(x.mx) end, function(x) return x.mx end },
            { 'kp', 'Crit%', 38, function(x) return string.format('%.0f', pct(x.k, x.h)) end, function(x) return pct(x.k, x.h) end },
            { 'o', 'Over', 50, function(x) return (x.o or 0) > 0 and short(x.o) or '-' end, function(x) return x.o or 0 end },
        }
    end
    local o = {}
    o[#o + 1] = U.table('hout', string.format('HEALING DONE &#183; <span class="dim">%s (%s hps)</span>', short(to), short(to / math.max(1, secs))), outr, cols(to, 'Target'), 'd')
    o[#o + 1] = U.table('hin', string.format('HEALING RECEIVED &#183; <span class="dim">%s (%s hps)</span>', short(ti), short(ti / math.max(1, secs))), inr, cols(ti, 'Healer'), 'd')
    o[#o + 1] = '<div class="note2">Over = overhealing EQ printed in the heal line. Heals by others on others only show when the "Others Heals" chat filter is on.</div>'
    return table.concat(o)
end
-- ---------------------------------------------------------------- event log
local EVK = { { 'all', 'All' }, { 'dmg', 'Hits' }, { 'crit', 'Crits' }, { 'miss', 'Misses' }, { 'inc', 'Taken' }, { 'heal', 'Heals' }, { 'cast', 'Casts' } }
local KIND = { d = 'hit', m = 'miss', r = 'resist', i = 'taken', a = 'avoid', h = 'heal', H = 'healed', c = 'cast', x = 'died' }
local KCOL = { d = '#ffd27a', m = '#8ac8ff', r = '#d090ff', i = '#ff8a8a', a = '#6aff8a', h = '#6aff8a', H = '#6aff8a', c = '#8ac8ff', x = '#ff5040' }
function U.ev_match(d, ev)
    local k = ev[2]
    local f = tostring(ev[6] or '')
    if S.evk == 'dmg' and k ~= 'd' then return false end
    if S.evk == 'crit' and not ((k == 'd' or k == 'h' or k == 'i' or k == 'H') and f:find('c', 1, true)) then return false end
    if S.evk == 'miss' and not (k == 'm' or k == 'r' or k == 'a') then return false end
    if S.evk == 'inc' and not (k == 'i' or k == 'a') then return false end
    if S.evk == 'heal' and not (k == 'h' or k == 'H') then return false end
    if S.evk == 'cast' and k ~= 'c' then return false end
    if S.evs ~= 'all' and nm(d, ev[3]) ~= S.evs then return false end
    if S.eva and nm(d, ev[4]) ~= S.eva then return false end
    if S.evt then local t = ev[1] / 10; if t < S.evt[1] or t >= S.evt[2] then return false end end
    return true
end
local function ev_tab(r, d)
    local o = {}
    local srcs = { { 'all', 'All' } }
    for i, s in ipairs(d.src or {}) do if i <= 4 then srcs[#srcs + 1] = { s[1], e(srcname(d, s[1])) } end end
    local seen = {}; for _, x in ipairs(srcs) do seen[x[1]] = true end
    if not seen['You'] then srcs[#srcs + 1] = { 'You', 'You' } end
    if S.evs ~= 'all' and not seen[S.evs] and S.evs ~= 'You' then srcs[#srcs + 1] = { S.evs, e(S.evs) } end
    o[#o + 1] = '<div class="fgo">' .. seg(EVK, S.evk, function(v) S.evk = v; S.evp = 1; render() end) .. '</div>'
    o[#o + 1] = '<div class="fgo">' .. seg(srcs, S.evs, function(v) S.evs = v; S.eva = nil; S.evp = 1; render() end) .. '</div>'
    -- ability filter: step through the abilities of the picked source
    local abl, ai = {}, 0
    for _, a in ipairs(d.ab or {}) do if S.evs == 'all' or a.s == S.evs then abl[#abl + 1] = a.n end end
    for i, n in ipairs(abl) do if n == S.eva then ai = i end end
    local function step(dv) local i = ai + dv; if i < 0 then i = #abl end; if i > #abl then i = 0 end; S.eva = i > 0 and abl[i] or nil; S.evp = 1; render() end
    local chips = string.format('<div class="fgo"><span class="fel">Ability</span><div class="arr"%s>&#9664;</div><span class="fev">%s</span><div class="arr"%s>&#9654;</div>',
        A(function() step(-1) end), S.eva and e(S.eva) or 'all', A(function() step(1) end))
    if S.evt then chips = chips .. string.format('<span class="fel">Second %d&#8211;%ds</span>', math.floor(S.evt[1]), math.floor(S.evt[2])) .. btn('All seconds', function() S.evt = nil; S.evp = 1; render() end, 'sm') end
    o[#o + 1] = chips .. '</div>'
    if r.tl and #r.tl > 0 then                                          -- the marker strip, same as under the graph
        local secs = math.max(1, d.len or 1)
        local m = { '<div class="fgm2">' }
        for _, ev in ipairs(r.tl) do m[#m + 1] = string.format('<div class="fgk" style="left: %dpx; background-color: %s;"></div>', math.floor(C.clamp((ev[3] or 0) / secs, 0, 1) * (PW - 3)), TLC[ev[1]] or '#ffffff') end
        if S.evt then m[#m + 1] = string.format('<div class="fgs" style="left: %dpx; width: %dpx;"></div>', math.floor(C.clamp(S.evt[1] / secs, 0, 1) * PW), math.max(2, math.floor((S.evt[2] - S.evt[1]) / secs * PW))) end
        m[#m + 1] = '</div>'
        o[#o + 1] = table.concat(m)
    end
    local list = {}
    for _, ev in ipairs(d.ev or {}) do if U.ev_match(d, ev) then list[#list + 1] = ev end end
    local pages = math.max(1, math.ceil(#list / U.PAGE)); S.evp = C.clamp(S.evp, 1, pages)
    o[#o + 1] = string.format('<div class="ftt">%d EVENTS%s &#183; <span class="dim">time from the fight start</span></div>', #list,
        (d.cut or 0) > 0 and string.format(' <span class="wn">(log kept the first %d; %d later events counted in the graph and tables only)</span>', #(d.ev or {}), d.cut) or '')
    o[#o + 1] = '<div class="ftr fth"><span class="ftc l" style="left: 6px; width: 46px;">Time</span><span class="ftc l" style="left: 56px; width: 50px;">Type</span><span class="ftc l" style="left: 110px; width: 120px;">Source</span><span class="ftc l" style="left: 234px; width: 150px;">Ability</span><span class="ftc" style="left: 388px; width: 66px;">Amount</span><span class="ftc l" style="left: 462px; width: 180px;">Target / result</span></div>'
    for i = (S.evp - 1) * U.PAGE + 1, math.min(#list, S.evp * U.PAGE) do
        local ev = list[i]
        local k, f = ev[2], tostring(ev[6] or '')
        local tags = {}
        if f:find('c', 1, true) and k ~= 'c' then tags[#tags + 1] = '<span class="wn">CRIT</span>' end
        if f:find('C', 1, true) then tags[#tags + 1] = '<span class="wn">crippling</span>' end
        if f:find('o', 1, true) and (k == 'h' or k == 'H') then tags[#tags + 1] = 'HoT' end
        local res = (k == 'm' or k == 'a') and f or (k == 'r' and 'resisted' or (k == 'c' and (f == 'aa' and 'AA' or 'cast') or ''))
        local tg = (ev[7] or 0) > 0 and e(nm(d, ev[7])) or ''
        o[#o + 1] = string.format('<div class="ftr%s"><span class="ftc l dim" style="left: 6px; width: 46px;">%.1fs</span><span class="ftc l" style="left: 56px; width: 50px; color: %s;">%s</span><span class="ftc l" style="left: 110px; width: 120px;">%s</span><span class="ftc l" style="left: 234px; width: 150px;">%s</span><span class="ftc" style="left: 388px; width: 66px;">%s</span><span class="ftc l" style="left: 462px; width: 180px;">%s</span></div>',
            i % 2 == 0 and ' z' or '', ev[1] / 10, KCOL[k] or '#ffffff', KIND[k] or k, e(srcname(d, nm(d, ev[3]))), e(nm(d, ev[4])), (ev[5] or 0) > 0 and C.fmt(ev[5]) or '',
            (function() local q = {}; if tg ~= '' then q[#q + 1] = tg end; if res ~= '' then q[#q + 1] = res end; if #tags > 0 then q[#q + 1] = table.concat(tags, ' ') end; return table.concat(q, ' &#183; ') end)())
    end
    if #list == 0 then o[#o + 1] = '<div class="empty">No events match these filters</div>' end
    if pages > 1 then
        o[#o + 1] = string.format('<div class="pgr"><div class="arr%s"%s>&#9664;</div><span id="pg">%d / %d</span><div class="arr%s"%s>&#9654;</div></div>',
            S.evp <= 1 and ' dis' or '', A(function() S.evp = math.max(1, S.evp - 1); render() end), S.evp, pages, S.evp >= pages and ' dis' or '', A(function() S.evp = math.min(pages, S.evp + 1); render() end))
    end
    return table.concat(o)
end
local TABS = { { 'dmg', 'Damage' }, { 'def', 'Defensive' }, { 'heal', 'Healing' }, { 'ev', 'Event log' } }
-- the whole view; r = record, back = fn, extra = buttons html (compare / refresh)
function U.page(rr, r, back, extra)
    rr[#rr + 1] = header(r, nil, back)
    if extra and extra ~= '' then rr[#rr + 1] = '<div class="fbt">' .. extra .. '</div>' end
    local d, why = PS.detail(r)
    if not d then
        rr[#rr + 1] = '<div class="note2 wn2">' .. (PS.DETAIL_WHY[why] or PS.DETAIL_WHY.missing) .. '</div>'
        return false
    end
    local secs = math.max(1, tonumber(r.secs) or d.len or 1)
    rr[#rr + 1] = '<div class="pseg">' .. seg(TABS, S.tab, function(v) S.tab = v; if v == 'heal' then S.gm = 'hps' elseif v == 'def' then S.gm = 'dtps' elseif v == 'dmg' and (S.gm == 'hps' or S.gm == 'dtps') then S.gm = 'dps' end; render() end) .. '</div>'
    if S.tab == 'ev' then rr[#rr + 1] = ev_tab(r, d); return true end
    local mode = S.gm
    rr[#rr + 1] = graph_block(r, d, mode)
    if S.tab == 'dmg' then rr[#rr + 1] = src_tab(d); rr[#rr + 1] = abil_tab(d, secs)
    elseif S.tab == 'def' then rr[#rr + 1] = def_tab(r, d, secs)
    elseif S.tab == 'heal' then rr[#rr + 1] = heal_tab(d, secs) end
    if (d.pet or '') ~= '' then rr[#rr + 1] = '<div class="note2">Pet = ' .. e(d.pet) .. ' (Me.Pet when the fight ran): lines that start with that exact name, or with "' .. e(C.CHAR) .. '`s pet".</div>' end
    return true
end
-- ---------------------------------------------------------------- compare: two fights' DPS over time on one graph
function U.compare_graph(a, b)
    local da, db = PS.detail(a), PS.detail(b)
    if not (da and db) then
        local p = {}
        if not da then p[#p + 1] = 'A' end; if not db then p[#p + 1] = 'B' end
        return '<div class="note2">DPS over time needs fight detail for both fights; ' .. table.concat(p, ' and ') .. ' ha' .. (#p > 1 and 've' or 's') .. ' none (saved before fight detail, or trimmed).</div>'
    end
    -- both on one per-second axis (re-fold to the longer fight's bucket size)
    local function persec(d)
        local t, o = total(d, 'dps') or {}, {}
        for i, v in ipairs(t) do o[i] = v end
        return o, d.bs or 1
    end
    local ta, ba = persec(da); local tb, bb = persec(db)
    local bs = math.max(ba, bb)
    local function refold(t, b)
        if b == bs then return t end
        local o = {}
        for i, v in ipairs(t) do local j = math.floor((i - 1) * b / bs) + 1; o[j] = (o[j] or 0) + v end
        for i = 1, #o do o[i] = o[i] or 0 end
        return o
    end
    ta, tb = refold(ta, ba), refold(tb, bb)
    local d = { bs = bs, len = math.max(da.len or 0, db.len or 0) }
    local lines = { { key = 'A', label = 'A: ' .. (a.label ~= '' and ('[' .. a.label .. '] ') or '') .. a.mob, color = '#ffd27a', arr = ta },
        { key = 'B', label = 'B: ' .. (b.label ~= '' and ('[' .. b.label .. '] ') or '') .. b.mob, color = '#40e0d0', arr = tb } }
    local o = { '<div class="ftt">DPS OVER TIME &#183; <span class="dim">A gold, B teal, from each fight\'s start</span></div>' }
    o[#o + 1] = '<div class="fgo">' .. seg(SM, S.sm, function(v) S.sm = v; render() end) .. '</div>'
    o[#o + 1] = (U.graph(d, { lines = lines, unit = 'dps' }))
    o[#o + 1] = legend(lines)
    return table.concat(o)
end
return U
