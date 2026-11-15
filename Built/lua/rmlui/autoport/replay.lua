--[[ AutoPort v5 · replay — mirror a captured ImGui tree into basic RmlUi.

  Per window: one RmlUi document (never closed; hidden with show(false)).
  The DOM is rebuilt only when the window's structure signature changes
  (throttled to 4/s); every other frame only changed values are written
  (text, class on/off, input values, bar widths), inside a ~3 ms budget.

  Element ids: 'a' .. hash(node id). Clicks carry action="ap:<eid>"; the
  element map turns them back into capture input state (capture.S).
]]
local M = {}
local fmt = string.format
local bit = bit or bit32

-- FontAwesome / MDI glyphs (Unicode private use area) aren't in the plugin's
-- fonts and would render as boxes: strip them from mirrored labels.
local function strip_pua(s)
    s = s:gsub('\238[\128-\191][\128-\191]', ''):gsub('\239[\128-\163][\128-\191]', ''):gsub('\243[\176-\191][\128-\191][\128-\191]', '')
    return s
end
M.strip_pua = strip_pua
local function esc(s)
    return (strip_pua(tostring(s or '')):gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'):gsub('"', '&quot;'))
end
M.esc = esc

-- 32-bit FNV-1a, pure Lua arithmetic (works in LuaJIT and 5.1)
local eid_cache = {}
local function hash(s)
    local h = 2166136261
    for i = 1, #s do
        h = (h - (h % 1)) -- int
        local c = s:byte(i)
        -- xor via bit lib when present
        if bit then h = bit.bxor(h, c) % 4294967296 else h = (h + c) % 4294967296 end
        h = (h * 16777619) % 4294967296
    end
    return fmt('%08x', h)
end
local function eid(nid)
    local e = eid_cache[nid]
    if e then return e end
    e = 'a' .. hash(nid)
    eid_cache[nid] = e
    return e
end
M.eid = eid

local PLOT_BARS = 32 -- fixed pool per plot

-- ---------------------------------------------------------------- html
local B -- builder state { out = {}, map = {} }

local function w(s) B.out[#B.out + 1] = s end
local MENU_V = 'ap_menu'
M.MENU_V = MENU_V
local function map(e, node, role) B.map[e] = { nid = node.id, k = node.k, role = role, node = node } end

local function attrs_for(n)
    local cls = ''
    if n.ind then cls = cls .. ' ind' .. math.min(n.ind, 6) end
    if n.dis then cls = cls .. ' dis' end
    return cls
end


-- --------------------------------------------------------------- width estimate (dp, Segoe UI 13dp)
local function text_w(t)
    t = tostring(t or '')
    local wd = 0
    for ch in t:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
        local b = ch:byte()
        if b >= 0xEE then wd = wd + 14            -- icon font (PUA) glyphs
        elseif b >= 0x80 then wd = wd + 9
        elseif ch:match('[mwMW@%%]') then wd = wd + 11
        elseif ch:match('[%u%d#&]') then wd = wd + 8.2
        elseif ch:match('[ilj%.,:;|!\'%[%]%(%)]') then wd = wd + 3.6
        else wd = wd + 6.8 end
    end
    return math.ceil(wd)
end
M.text_w = text_w
local CW = { button = 22, sbutton = 14, check = 22, radio = 22, select = 14, menuitem = 14 }
local function node_w(n)
    local k = n.k
    if k == 'text' then return text_w(n.text) end
    if CW[k] then return math.max(text_w(n.label) + CW[k], (k == 'button' and n.w) or 0) end
    if k == 'input' or k == 'inputint' or k == 'inputnum' or k == 'combo' or k == 'slider' then return 96 + (n.label ~= '' and text_w(n.label) + 6 or 0) end
    if k == 'progress' then return 120 end
    return M.content_w(n)
end
function M.content_w(cell) -- SameLine chains add up, separate lines take the max
    local c, best, line = cell.c or {}, 0, 0
    for i = 1, #c do
        local x = node_w(c[i])
        if c[i].sl and i > 1 then line = line + 6 + x else line = x end
        if line > best then best = line end
    end
    return best
end

local emit_children, emit_node

local function emit_node0(n)
    local k, e = n.k, eid(n.id)
    local extra = attrs_for(n)
    if k == 'text' then
        local st = n.color and (' style="color:' .. n.color .. ';"') or ''
        local act = n.clk and (' action="ap:' .. e .. '"') or ''
        if n.clk then map(e, n, 'click') elseif n.ctx then map(e, n, 'ctx') end
        w(fmt('<div class="ap-text%s%s%s"%s%s><span id="%s">%s</span></div>', n.wrap and ' wrap' or '', n.muted and ' muted' or '', (n.clk and ' clk' or '') .. extra, act, st, e, esc(n.text)))
    elseif k == 'button' or k == 'sbutton' then
        map(e, n, 'click')
        -- ImGui size arg = the button's width; never narrower than its label (no squashed/clipped text)
        local sty = (n.w and n.w > 0) and fmt('min-width:%ddp;', math.floor(math.min(n.w, 600))) or ''
        if n.bg then sty = sty .. 'decorator:none;background-color:' .. n.bg .. ';' end
        if n.fg then sty = sty .. 'color:' .. n.fg .. ';' end
        sty = sty ~= '' and (' style="' .. sty .. '"') or ''
        w(fmt('<div id="%s" class="ap-btn%s%s%s" action="ap:%s"%s><span id="%s_l">%s</span></div>', e, k == 'sbutton' and ' sm' or '', n.link and ' link' or '', extra, e, sty, e, esc(n.label)))
    elseif k == 'check' or k == 'radio' then
        map(e, n, 'click')
        w(fmt('<div id="%s" class="ap-%s%s%s" action="ap:%s"><div class="box"><div class="mark"></div></div><span id="%s_l">%s</span></div>', e, k, n.v and ' on' or '', extra, e, e, esc(n.label)))
    elseif k == 'select' or k == 'menuitem' then
        map(e, n, 'click')
        w(fmt('<div id="%s" class="ap-sel%s%s" action="ap:%s"><span id="%s_l">%s</span>%s</div>', e, n.v and ' on' or '', extra, e, e, esc(n.label),
            n.short and ('<span class="short">' .. esc(n.short) .. '</span>') or ''))
    elseif k == 'input' or k == 'inputint' or k == 'inputnum' then
        map(e, n, 'value')
        w(fmt('<div class="ap-field%s"><input type="text" id="%s" value="%s"/>%s</div>', extra, e, esc(n.v),
            n.label ~= '' and ('<span class="lbl">' .. esc(n.label) .. '</span>') or ''))
    elseif k == 'slider' then
        map(e, n, 'value')
        local step = n.int and 1 or ((n.max - n.min) / 100)
        w(fmt('<div class="ap-field%s"><input type="range" id="%s" min="%s" max="%s" step="%s" value="%s"/><span class="val" id="%s_v">%s</span>%s</div>',
            extra, e, n.min, n.max, step, n.v, e, esc(n.int and fmt('%d', n.v) or fmt('%.2f', n.v)), e,
            n.label ~= '' and ('<span class="lbl">' .. esc(n.label) .. '</span>') or ''))
    elseif k == 'color' then
        map(e, n, 'value')
        w(fmt('<div class="ap-field%s"><div class="swatch" id="%s_s" style="background-color:%s;"></div>%s%s</div>', extra, e, n.v,
            n.ro and '' or fmt('<input type="text" class="hex" id="%s" value="%s"/>', e, esc(n.v)),
            n.label ~= '' and ('<span class="lbl">' .. esc(n.label) .. '</span>') or ''))
    elseif k == 'combo' then
        map(e, n, n.opts and 'opt' or 'index')
        -- A combo whose Selectables are all unselected is used as a menu (actions/toggles, e.g.
        -- "[ ] Auto Monitor"): show its preview as a fixed placeholder row so the control never
        -- defaults to (and fires) its first item, and reset to it after every pick.
        local cur
        if n.opts then for i = 1, #n.opts do local o = n.opts[i]; if o.v or n.cur == o.id then cur = eid(o.id) end end end
        local menu = n.opts and not cur
        B.map[e].cur = menu and MENU_V or cur
        B.map[e].menu = menu
        w(fmt('<div class="ap-field%s%s"><select id="%s">', extra, menu and ' ap-mcombo' or '', e))
        if menu then w(fmt('<option value="%s" selected>%s</option>', MENU_V, esc(n.preview ~= '' and n.preview or n.label))) end
        if n.opts then
            for i = 1, #n.opts do
                local o = n.opts[i]
                w(fmt('<option value="%s"%s>%s</option>', eid(o.id), (o.v or n.cur == o.id) and ' selected' or '', esc(o.label)))
                B.map[eid(o.id)] = { nid = o.id, k = 'select', role = 'click', node = o }
            end
            if #n.opts == 0 then w(fmt('<option value="">%s</option>', esc(n.preview))) end
        else
            for i = 1, #n.items do w(fmt('<option value="%d"%s>%s</option>', i, i == n.v and ' selected' or '', esc(n.items[i]))) end
        end
        w('</select>')
        if n.label ~= '' then w('<span class="lbl">' .. esc(n.label) .. '</span>') end
        w('</div>')
    elseif k == 'sep' then
        w('<div class="ap-sep"></div>')
    elseif k == 'septext' then
        w(fmt('<div class="ap-septext"><span>%s</span><div class="line"></div></div>', esc(n.text)))
    elseif k == 'space' then
        w(fmt('<div class="ap-space" style="height:%ddp;"></div>', math.max(2, math.floor(n.h or 6))))
    elseif k == 'progress' then
        w(fmt('<div class="ap-prog%s"><div class="fill" id="%s_f" style="width:%d%%;"></div><span id="%s_t">%s</span></div>', extra, e, math.floor(n.v * 100), e,
            esc(n.text or fmt('%d%%', math.floor(n.v * 100)))))
    elseif k == 'plot' then
        w(fmt('<div class="ap-plot%s"><div class="bars">', n.style == 'lines' and ' lines' or ''))
        for i = 1, PLOT_BARS do w(fmt('<div class="bar" id="%s_b%d"></div>', e, i)) end
        w(fmt('</div><span class="lbl" id="%s_t">%s</span></div>', e, esc(n.text or n.label)))
    elseif k == 'image' then
        w(fmt('<div class="ap-img" style="width:%ddp;height:%ddp;"></div>', math.max(8, math.min(n.w or 32, 256)), math.max(8, math.min(n.h or 32, 256))))
    elseif k == 'child' or k == 'group' then
        local sty = ''
        if k == 'child' then
            if n.h and n.h > 0 then sty = fmt(' style="height:%ddp;"', math.floor(math.min(n.h, 900)))
            elseif n.h and n.h < 0 then sty = ' style="flex:1;"' end
        end
        w(fmt('<div class="ap-%s%s%s" id="%s"%s>', k, n.border and ' border' or '', extra, e, sty))
        emit_children(n)
        w('</div>')
    elseif k == 'tree' or k == 'header' then
        map(e, n, 'toggle')
        w(fmt('<div class="ap-%s%s%s"><div class="head" id="%s" action="ap:%s"><span class="arr">%s</span><span id="%s_l">%s</span></div>', k, n.open and ' open' or '', extra, e, e,
            n.open and '-' or '+', e, esc(n.label)))
        if n.open then w('<div class="body">'); emit_children(n); w('</div>') end
        w('</div>')
    elseif k == 'tabbar' then
        w('<div class="ap-tabbar"><div class="tabs">')
        for i = 1, #n.tabs do
            local t = n.tabs[i]
            local te = eid(t.id)
            B.map[te] = { nid = t.id, k = 'tab', role = 'click' }
            w(fmt('<div class="tab%s" id="%s" action="ap:%s"><span>%s</span></div>', t.id == n.active and ' on' or '', te, te, esc(t.label)))
        end
        w('</div><div class="panel">')
        emit_children(n)
        w('</div></div>')
    elseif k == 'tabitem' or k == 'cell' then
        emit_children(n)
    elseif k == 'table' then
        -- Column widths: every row gets the same flex basis per column (so columns line up), sized to the
        -- widest content in that column; fixed widths from TableSetupColumn/SetColumnWidth are a minimum.
        -- Stretch columns share leftover space; a table wider than the window scrolls with the window.
        local est = {}
        for i = 1, n.ncols do est[i] = n.hdr and n.cols[i] and (M.text_w(n.cols[i]) + 12) or 24 end
        for r = 1, #n.c do local row = n.c[r]
            if row.k == 'row' then for i = 1, n.ncols do if row.c[i] then est[i] = math.max(est[i], M.content_w(row.c[i]) + 12) end end end
        end
        local total = 0
        local function cw(i)
            local px = n.colw and n.colw[i]
            local b = math.floor(math.max(est[i], px or 0))
            if px then return fmt('flex:0 0 %ddp;width:%ddp;', b, b) end
            return fmt('flex:1 0 %ddp;width:%ddp;', b, b)
        end
        for i = 1, n.ncols do total = total + math.floor(math.max(est[i], (n.colw and n.colw[i]) or 0)) end
        w(fmt('<div class="ap-table%s" style="min-width:%ddp;">', n.legacy and ' legacy' or '', total + 2))
        if n.hdr and #n.cols > 0 then
            w('<div class="tr th">')
            for i = 1, n.ncols do w(fmt('<div class="td" style="%s"><span>%s</span></div>', cw(i), esc(n.cols[i] or ''))) end
            w('</div>')
        end
        for r = 1, #n.c do
            local row = n.c[r]
            if row.k == 'row' then
                w(fmt('<div class="tr%s">', r % 2 == 0 and ' alt' or ''))
                for i = 1, n.ncols do
                    w(fmt('<div class="td" style="%s">', cw(i)))
                    if row.c[i] then emit_children(row.c[i]) end
                    w('</div>')
                end
                w('</div>')
            end
        end
        w('</div>')
    elseif k == 'menubar' then
        w('<div class="ap-menubar">')
        local open
        for i = 1, #(n.c or {}) do
            local m = n.c[i]
            if m.k == 'menu' then
                local me = eid(m.id)
                map(me, m, 'toggle')
                w(fmt('<div class="mb%s" id="%s" action="ap:%s"><span>%s</span></div>', m.open and ' on' or '', me, me, esc(m.label)))
                if m.open then open = m end
            else emit_node(m) end
        end
        w('</div>')
        if open then w('<div class="ap-menu">'); emit_children(open); w('</div>') end
    elseif k == 'menu' then -- nested submenu
        local me = eid(n.id)
        map(me, n, 'toggle')
        w(fmt('<div class="ap-sel sub" id="%s" action="ap:%s"><span>%s</span><span class="short">%s</span></div>', me, me, esc(n.label), n.open and '-' or '+'))
        if n.open then w('<div class="ap-submenu">'); emit_children(n); w('</div>') end
    end
end


-- items with a tooltip (SetTooltip / SetItemTooltip / BeginTooltip / HelpMarker): shown on hover
function emit_node(n)
    if not n.tip or n.tip == '' then return emit_node0(n) end
    w('<div class="ap-tipwrap">')
    emit_node0(n)
    w('<div class="ap-tip">' .. esc(n.tip):gsub('\n', '<br/>') .. '</div></div>')
end

-- SameLine: consecutive nodes chained with .sl go into one row
function emit_children(parent)
    local c = parent.c or {}
    local i = 1
    while i <= #c do
        local j = i
        while c[j + 1] and c[j + 1].sl do j = j + 1 end
        if j > i then
            w('<div class="ap-row">')
            for x = i, j do emit_node(c[x]) end
            w('</div>')
        else
            emit_node(c[i])
        end
        i = j + 1
    end
end

function M.build(win)
    B = { out = {}, map = {} }
    emit_children(win)
    for i = 1, #(win.popups or {}) do
        local p = win.popups[i]
        local e = eid(p.id)
        B.map[e .. '_x'] = { nid = p.id, k = 'popup', role = 'close' }
        w(fmt('<div class="ap-popup%s"><div class="ph"><span>%s</span><div class="x" action="ap:%s_x"><span>x</span></div></div><div class="pb">', p.modal and ' modal' or '', esc(p.title), e))
        emit_children(p)
        w('</div></div>')
    end
    local html = table.concat(B.out)
    local m = B.map
    B = nil
    return html, m
end

-- ---------------------------------------------------------------- per-frame value binds
-- yields write ops for every dynamic value; the doc cache drops unchanged ones
local function binds(n, out)
    local k, e = n.k, eid(n.id)
    if k == 'text' then out[#out + 1] = { 't', e, n.text }
    elseif k == 'button' or k == 'sbutton' then out[#out + 1] = { 't', e .. '_l', n.label }
    elseif k == 'check' or k == 'radio' or k == 'select' or k == 'menuitem' then
        out[#out + 1] = { 'c', e, 'on', n.v and true or false }
        out[#out + 1] = { 't', e .. '_l', n.label }
    elseif k == 'input' or k == 'inputint' or k == 'inputnum' then out[#out + 1] = { 'v', e, tostring(n.v) }
    elseif k == 'slider' then
        out[#out + 1] = { 'v', e, tostring(n.v) }
        out[#out + 1] = { 't', e .. '_v', n.int and fmt('%d', n.v) or fmt('%.2f', n.v) }
    elseif k == 'color' then
        out[#out + 1] = { 's', e .. '_s', 'background-color', n.v }
        if not n.ro then out[#out + 1] = { 'v', e, n.v } end
    elseif k == 'combo' then
        if n.opts then
            local cur
            for i = 1, #n.opts do if n.opts[i].v or n.cur == n.opts[i].id then cur = eid(n.opts[i].id) end end
            out[#out + 1] = { 'v', e, cur or MENU_V }
        else out[#out + 1] = { 'v', e, tostring(n.v) } end
    elseif k == 'progress' then
        out[#out + 1] = { 's', e .. '_f', 'width', fmt('%d%%', math.floor(n.v * 100)) }
        out[#out + 1] = { 't', e .. '_t', n.text or fmt('%d%%', math.floor(n.v * 100)) }
    elseif k == 'plot' then
        local v, cnt = n.vals, #n.vals
        local mn, mx = n.min, n.max
        if not mn or not mx then
            mn, mx = math.huge, -math.huge
            for i = 1, cnt do if v[i] < mn then mn = v[i] end; if v[i] > mx then mx = v[i] end end
            if cnt == 0 then mn, mx = 0, 1 end
            if mn > 0 then mn = 0 end
        end
        local span = (mx - mn); if span <= 0 then span = 1 end
        for i = 1, PLOT_BARS do
            local h = 0
            if cnt > 0 then
                local a = math.floor((i - 1) * cnt / PLOT_BARS) + 1
                local b2 = math.max(a, math.floor(i * cnt / PLOT_BARS))
                local s = 0
                for x = a, b2 do s = s + (v[x] or 0) end
                h = ((s / (b2 - a + 1)) - mn) / span
            end
            out[#out + 1] = { 's', e .. '_b' .. i, 'height', fmt('%d%%', math.max(0, math.min(100, math.floor(h * 100)))) }
        end
        out[#out + 1] = { 't', e .. '_t', n.text or n.label }
    end
    for i = 1, #(n.c or {}) do binds(n.c[i], out) end
    if k == 'table' then -- rows/cells already in c
    end
end
function M.binds(win)
    local out = {}
    binds(win, out)
    for i = 1, #(win.popups or {}) do binds(win.popups[i], out) end
    return out
end

return M
