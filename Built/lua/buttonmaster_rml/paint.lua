-- Shared DOM writer (every write diffed through a cache) and the hot-button painter used by bars and the editor preview.
local C = require('buttonmaster_rml.core')
local P = {}
P.writes = 0

local Dom = {}; Dom.__index = Dom
function P.dom(W) return setmetatable({ W = W, c = {} }, Dom) end
function Dom:put(k, v, fn) if self.dead or not self.W then return end; if self.c[k] == v then return end; self.c[k] = v; P.writes = P.writes + 1; pcall(fn) end
function Dom:text(id, v) v = tostring(v or ''); self:put('t' .. id, v, function() self.W:text(id, v) end) end
function Dom:class(id, cl, on) on = on and true or false; self:put('c' .. id .. ' ' .. cl, on, function() self.W:class(id, cl, on) end) end
function Dom:style(id, p, v) v = tostring(v); self:put('s' .. id .. ' ' .. p, v, function() self.W:style(id, p, v) end) end
function Dom:attr(id, n, v) v = tostring(v); self:put('a' .. id .. ' ' .. n, v, function() self.W:attr(id, n, v) end) end
function Dom:forget(id, n) self.c['a' .. id .. ' ' .. n] = nil end
function Dom:reset() self.c = {} end

function P.esc(s) return (tostring(s or ''):gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;')) end
function P.clip(s, n) s = tostring(s or ''); if #s > n then return s:sub(1, n - 2) .. '..' end; return s end
local function hex(c, d) c = tostring(c or ''):gsub('#', ''); if c:match('^%x%x%x%x%x%x$') then return '#' .. c:lower() end; return d end
P.hex = hex


-- icon source: Forge icons are files; EQ icons come from the plugin's atlas sampler (same as the eqrml hot bar)
function P.icon_src(id, ty)
    if id == nil or id == false or id == '' then return nil end
    if ty == 'Rml' then return '../img/ic/' .. tostring(id) .. '.png' end
    if ty == 'GI' then return '../img/gi/' .. tostring(id) .. '.png' end       -- game-icons.net white glyph, sits on the button plate
    local n = tonumber(id); if not n then return nil end
    local src = (ty == 'Item') and ('eq://itemcell/' .. n) or ('eq://spell/' .. n)
    if _G.__bm_eqsrc then return _G.__bm_eqsrc(src) end           -- box preview seam (no EQ atlases here)
    return src
end

local FXID = { glow = 'xg', pulse = 'xp', fire = 'xf', frost = 'xr', arcane = 'xa', bolt = 'xb', shine = 'xs', pack = 'xk' }
P.FXID = FXID
local TRIG = { 'always', 'ready', 'cooldown', 'hover', 'cond' }

-- static look of one button (cheap to call every refresh: all writes are diffed)
-- o: { size=px, label=string, tip=string, empty=slot number or nil, reduced=bool }
function P.look(D, p, i, b, o)
    local id = p .. 'b' .. i
    if not b then
        D:class(id, 'empty', true); D:class(id, 'noicon', true)
        for k in pairs(FXID) do D:class(p .. FXID[k] .. i, 'on', false) end
        D:class(id, 'lo-over', true); D:class(id, 'lo-under', false)
        D:text(p .. 'o' .. i, o.empty or ''); D:style(p .. 'o' .. i, 'color', '#8a7468')
        D:style(p .. 'o' .. i, 'font-size', math.max(9, math.floor((o.size or 40) * 0.26)) .. 'px')
        D:attr(p .. 'r' .. i, 'src', '../img/fr/plain_rounded.png'); D:style(p .. 'r' .. i, 'image-color', '#8a6a5a')
        D:style(p .. 'p' .. i, 'decorator', 'vertical-gradient(#1a1212a0 #0c0808a0)')
        for _, s in ipairs({ 'round', 'square', 'rounded', 'hex' }) do D:class(id, 'sh-' .. s, s == 'rounded') end
        D:style(p .. 'k' .. i, 'border-radius', math.floor((o.size or 40) * 0.22) .. 'px')
        D:class(id, 'bnc', false)
        return
    end
    local r = C.look(b)
    D:class(id, 'empty', false)
    local shape = r.Shape or 'rounded'
    for _, s in ipairs({ 'round', 'square', 'rounded', 'hex' }) do D:class(id, 'sh-' .. s, s == shape) end
    local sz = o.size or 40
    D:style(p .. 'k' .. i, 'border-radius', math.floor(sz * (({ round = 0.5, square = 0.04, rounded = 0.22, hex = 0.26 })[shape] or 0.22)) .. 'px')
    -- plate: two-colour gradient (or the ButtonMaster button colour when no Rml colours are set)
    local legacy = b.ButtonColorRGB and (function() local t = C.split(b.ButtonColorRGB, ','); if #t == 3 then return string.format('%02x%02x%02x', tonumber(t[1]) or 0, tonumber(t[2]) or 0, tonumber(t[3]) or 0) end end)()
    local c1 = hex(r.Bg1 or legacy, '#3a2620'); local c2 = hex(r.Bg2, legacy and ('#' .. legacy) or '#120a08')
    if shape == 'hex' then
        D:style(p .. 'p' .. i, 'decorator', 'image(../img/fr/plate_hex.png)'); D:style(p .. 'p' .. i, 'image-color', c1)
    else
        D:style(p .. 'p' .. i, 'decorator', 'vertical-gradient(' .. c1 .. ' ' .. c2 .. ')'); D:style(p .. 'p' .. i, 'image-color', '#ffffff')
    end
    local fr = r.Frame or 'metal'
    if fr == 'none' then D:class(p .. 'r' .. i, 'hide', true)
    else D:class(p .. 'r' .. i, 'hide', false); D:attr(p .. 'r' .. i, 'src', '../img/fr/' .. fr .. '_' .. shape .. '.png') end
    D:style(p .. 'r' .. i, 'image-color', hex(r.Border, '#e8a070'))
    local icid, icty = C.icon(b)
    local src = P.icon_src(icid, icty)
    D:class(id, 'noicon', src == nil)
    if src then D:attr(p .. 'i' .. i, 'src', src) end
    -- label
    local show = b.ShowLabel ~= false
    local lp = r.LabelPos or ((src and show) and 'over' or (show and 'over' or 'none'))
    if not show then lp = 'none' end
    D:class(id, 'lo-over', lp == 'over'); D:class(id, 'lo-under', lp == 'under')
    local fs = tonumber(r.LabelSize) or math.max(9, math.min(14, math.floor((o.size or 40) * 0.22)))
    local sz2 = o.size or 40
    local maxc = math.max(3, math.floor((lp == 'under' and (sz2 + 12) or (sz2 - 4)) / (fs * 0.56)))
    local lab = P.esc(P.clip(o.label or '', maxc))
    D:text(p .. (lp == 'under' and 'u' or 'o') .. i, lab); D:text(p .. (lp == 'under' and 'o' or 'u') .. i, '')
    local lc = hex(r.LabelColor or (b.TextColorRGB and (function() local t = C.split(b.TextColorRGB, ','); if #t == 3 then return string.format('%02x%02x%02x', tonumber(t[1]) or 255, tonumber(t[2]) or 255, tonumber(t[3]) or 255) end end)()), '#ffffff')
    D:style(p .. 'o' .. i, 'font-size', fs .. 'px'); D:style(p .. 'o' .. i, 'color', lc)
    D:style(p .. 'u' .. i, 'font-size', math.min(fs, 12) .. 'px'); D:style(p .. 'u' .. i, 'color', lc)
    D:style(p .. 'n' .. i, 'font-size', math.max(9, math.floor((o.size or 40) * 0.24)) .. 'px')
    D:text(p .. 'tp' .. i, P.esc(o.tip or ''))
    -- effects
    local fx = r.Fx or {}
    for k, eid in pairs(FXID) do
        local e = fx[k]
        local on = e and e.On and true or false
        D:class(p .. eid .. i, 'on', on)
        if on then
            local tr = e.Trig or 'always'
            for _, t in ipairs(TRIG) do D:class(p .. eid .. i, 'tw-' .. t, t == tr) end
            D:style(p .. eid .. i, 'opacity', string.format('%.2f', (tonumber(e.Int) or 100) / 100))
            local col = hex(e.Col, '#' .. ((k == 'pack' and C.PACK_COL[e.Kind or 'blaze']) or C.FX_DEFCOL[k] or 'ffffff'))
            if k == 'pack' then for _, pk in ipairs(C.PACK_KINDS) do D:class(p .. eid .. i, 'pk-' .. pk, pk == (e.Kind or 'blaze')) end end
            D:style(p .. (k == 'pulse' and 'xz' or eid) .. i, 'image-color', col)
        end
    end
    D:style(p .. 'xl' .. i, 'image-color', hex(fx.flash and fx.flash.Col, '#fff2c0'))
    D:class(id, 'bnc', fx.bounce and fx.bounce.On or false)
end

-- dynamic state: st = { ready=, cd=remaining s, tot=s, lock=, cond=, dis=, flash=0..1 }
function P.state(D, p, i, st, has_timer)
    local id = p .. 'b' .. i
    local oncd = (st.cd or 0) > 0 and (st.tot or 0) > 0
    D:class(id, 'cd', oncd); D:class(id, 'lck', st.lock and not oncd)
    D:class(id, 'rdy', not oncd and not st.dis and not st.lock)
    D:class(id, 'cnd', st.cond and true or false); D:class(id, 'dis', st.dis and true or false); D:class(id, 'prs', st.prs and true or false)
    if oncd then
        local k = math.max(0, math.min(23, math.floor((1 - st.cd / st.tot) * 24)))
        D:attr(p .. 'c' .. i, 'class', string.format('cd k%02d', k))
        local s = math.ceil(st.cd)
        D:text(p .. 'n' .. i, s >= 3600 and string.format('%dh', math.floor(s / 3600)) or (s >= 60 and string.format('%dm', math.floor(s / 60)) or tostring(s)))
    end
    D:style(p .. 'xl' .. i, 'opacity', string.format('%.2f', st.flash or 0))
end
return P
