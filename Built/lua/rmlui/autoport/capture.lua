--[[ AutoPort v5 · capture — virtual ImGui that records the per-frame call tree.

  The tool's draw callbacks run against this proxy instead of real ImGui. Nothing is
  drawn by ImGui; every call becomes a node { k = kind, id = stable id, ... } in a tree
  per window. Return values come from S (the input state fed back from RmlUi events),
  so a click in RmlUi on frame N is returned by ImGui.Button(...) on frame N+1.

  Stable ids follow ImGui rules: "Label##id" -> id part, "Shown###id" -> id part,
  otherwise the label, scoped by window / container / PushID stack, with a duplicate
  counter. Text-like nodes are positional (they have no ImGui id).
]]
local M = {}

local unpack = table.unpack or unpack
local fmt = string.format

-- ---------------------------------------------------------------- input state
local S = {
    click = {},    -- nid -> true      (button / checkbox / selectable / menu item / tab head)
    val = {},      -- nid -> string    (input / slider / combo / color value from RmlUi)
    open = {},     -- nid -> bool      (tree, header, menu, popup, combo)
    tab = {},      -- tabbar nid -> tab nid
    winopen = {},  -- window nid -> false when closed from the titlebar
    ctxreq = {},   -- item nid -> true  (right mouse on that item)
}
M.S = S

-- ---------------------------------------------------------------- frame state
local F            -- current frame { windows = {...}, order = {...} }
local stack        -- container stack (nodes)
local idstack      -- PushID stack (strings)
local last_item    -- last item node
local popup_stack  -- names of popups being drawn (for CloseCurrentPopup)
local pending_sl   -- SameLine called -> next node goes on the same row
local used = {}    -- unknown/partial ImGui functions seen (name -> count)
M.used = used
M.stats = { frames = 0, nodes = 0, errors = 0, last_error = nil }

local function vec2(x, y)
    if ImVec2 then local ok, v = pcall(ImVec2, x, y); if ok and v then return v end end
    return { x = x, y = y }
end
local function vec4(x, y, z, w)
    if ImVec4 then local ok, v = pcall(ImVec4, x, y, z, w); if ok and v then return v end end
    return { x = x, y = y, z = z, w = w }
end
M.vec2, M.vec4 = vec2, vec4

local function note(name, kind) local k = (kind or 'unsupported') .. ':' .. name; used[k] = (used[k] or 0) + 1 end

local function split_label(label)
    label = tostring(label == nil and '' or label)
    local shown, key = label:match('^(.-)###(.*)$')
    if shown then return shown, '###' .. key end
    shown, key = label:match('^(.-)##(.*)$')
    if shown then return shown, label end
    return label, label
end
M.split_label = split_label

local function top() return stack[#stack] end

local function scope()
    local t = top()
    local s = t and t.id or ''
    if #idstack > 0 then s = s .. '|' .. table.concat(idstack, '|') end
    return s
end

-- style stack: PushStyleColor(Text / Button) and PushTextWrapPos reach the items drawn under them
local colstk, wrapstk = {}, {}
local COL_TEXT, COL_BUTTON, COL_CHECK = 0, 21, 18
local function style_col(idx) for i = #colstk, 1, -1 do if colstk[i][1] == idx then return colstk[i][2] end end end
M._style = { colstk = colstk, wrapstk = wrapstk }

local function add(node, key)
    local parent = top()
    if not parent then -- call outside any window: not mirrored
        node.id = '?'; last_item = node
        return node
    end
    local holder = parent
    if node.k == 'header' then parent._hdr = nil
    elseif parent._hdr then holder = parent._hdr end
    local base
    if key then
        base = scope() .. '/' .. node.k:sub(1, 2) .. ':' .. key
        parent._dup = parent._dup or {}
        local n = (parent._dup[base] or 0) + 1
        parent._dup[base] = n
        if n > 1 then base = base .. '#' .. n end
    else
        parent._pos = (parent._pos or 0) + 1
        base = (parent.id or '') .. '/' .. node.k:sub(1, 2) .. parent._pos
    end
    node.id = base
    if #colstk > 0 then
        local tc = style_col(COL_TEXT)
        if node.k == 'text' then node.color = node.color or tc
        elseif node.k == 'button' or node.k == 'sbutton' then node.fg = tc; node.bg = style_col(COL_BUTTON)
        elseif tc and (node.k == 'check' or node.k == 'radio' or node.k == 'select' or node.k == 'menuitem' or node.k == 'tree' or node.k == 'header') then node.fg = tc end
    end
    if node.k == 'text' and wrapstk[#wrapstk] then node.wrap = true end
    if pending_sl then node.sl = true; pending_sl = false end
    if parent._indent and parent._indent > 0 then node.ind = parent._indent end
    if parent._disabled and parent._disabled > 0 then node.dis = true end
    holder.c = holder.c or {}
    holder.c[#holder.c + 1] = node
    F.sig[#F.sig + 1] = node.k .. '\1' .. base
    M.stats.nodes = M.stats.nodes + 1
    last_item = node
    return node
end

local function push(node) stack[#stack + 1] = node; node.c = node.c or {} end
local function pop_to(kind)
    for i = #stack, 1, -1 do
        if stack[i].k == kind then
            for j = #stack, i, -1 do stack[j] = nil end
            return
        end
    end
end
local function nearest(kind)
    for i = #stack, 1, -1 do if stack[i].k == kind then return stack[i], i end end
end

local function take_click(nid) if S.click[nid] then S.click[nid] = nil; M._lastclick = nid; return true end return false end
local function take_val(nid) local v = S.val[nid]; if v ~= nil then S.val[nid] = nil end return v end

local function format_text(fmt_, ...)
    if select('#', ...) == 0 then return tostring(fmt_ == nil and '' or fmt_) end
    local ok, s = pcall(fmt, tostring(fmt_), ...)
    return ok and s or tostring(fmt_)
end

local function color_of(c)
    if type(c) == 'number' then -- packed ImU32 (ABGR)
        local r, g, b = c % 256, math.floor(c / 256) % 256, math.floor(c / 65536) % 256
        return fmt('#%02x%02x%02x', r, g, b)
    end
    if type(c) == 'table' or type(c) == 'userdata' then
        local ok, r, g, b = pcall(function() return c.x or c[1], c.y or c[2], c.z or c[3] end)
        if ok and r then
            local function cl(v) v = tonumber(v) or 0; return math.max(0, math.min(255, math.floor(v * 255 + 0.5))) end
            return fmt('#%02x%02x%02x', cl(r), cl(g), cl(b))
        end
    end
    return nil
end
M.color_of = color_of

local function num(v, d) v = tonumber(v); if v == nil then return d end return v end
local function has_flag(flags, bit) flags = num(flags, 0); return (flags % (bit * 2)) >= bit end
local function sizexy(a, b)
    if type(a) == 'table' or type(a) == 'userdata' then
        local ok, x, y = pcall(function() return a.x, a.y end)
        if ok then return num(x, 0), num(y, 0) end
        return 0, 0
    end
    return num(a, 0), num(b, 0)
end

-- ================================================================ the proxy
local G = {}

-- windows ----------------------------------------------------------------
local next_win = {}
function G.SetNextWindowSize(a, b) next_win.w, next_win.h = sizexy(a, b) end
function G.SetNextWindowPos(a, b) next_win.x, next_win.y = sizexy(a, b) end
function G.SetNextWindowSizeConstraints() end
function G.SetNextWindowBgAlpha() end
function G.SetNextWindowCollapsed() end
function G.SetNextWindowFocus() end
function G.SetWindowSize() end
function G.SetWindowPos() end
function G.SetWindowFontScale() end

function G.Begin(name, p_open, flags)
    local has_open = select('#', name, p_open) >= 2 and type(p_open) == 'boolean'
    local title, key = split_label(name)
    local id = 'W:' .. key
    local w = F.windows[id]
    if not w then
        w = { k = 'window', id = id, title = title, c = {}, has_open = has_open, flags = flags }
        F.windows[id] = w; F.order[#F.order + 1] = id
    end
    w.title = title -- '##id' windows have no visible title in ImGui
    if next_win.w and next_win.w > 0 then w.w, w.h = next_win.w, next_win.h end
    if next_win.x then w.x, w.y = next_win.x, next_win.y end
    next_win = {}
    F.sig[#F.sig + 1] = 'window\1' .. id
    push(w)
    local open = true
    if S.winopen[id] == false then
        open = false
        if has_open then S.winopen[id] = nil end -- tool owns the flag now
    end
    if has_open then
        if p_open == false then w.hidden = true end
        return open and p_open, open and p_open
    end
    return open
end
function G.End() pop_to('window') end

-- child / group ----------------------------------------------------------
function G.BeginChild(id, a, b, border)
    local w, h = sizexy(a, b)
    if type(a) == 'table' or type(a) == 'userdata' then border = b end
    local _, key = split_label(id)
    local n = add({ k = 'child', w = w, h = h, border = border and true or false }, tostring(key))
    push(n)
    return true
end
function G.EndChild() pop_to('child') end
function G.BeginGroup() local n = add({ k = 'group' }); push(n) end
function G.EndGroup() pop_to('group') end

-- layout -------------------------------------------------------------------
function G.SameLine() pending_sl = true end
function G.NewLine() add({ k = 'space', h = 10 }) end
function G.Spacing() add({ k = 'space', h = 6 }) end
function G.Dummy(a, b) local _, h = sizexy(a, b); add({ k = 'space', h = math.min(h, 200) }) end
function G.Separator() add({ k = 'sep' }) end
function G.SeparatorText(t) add({ k = 'septext', text = tostring(t or '') }) end
function G.Indent() local t = top(); if t then t._indent = (t._indent or 0) + 1 end end
function G.Unindent() local t = top(); if t then t._indent = math.max(0, (t._indent or 0) - 1) end end
function G.BeginDisabled(d) local t = top(); if t and d ~= false then t._disabled = (t._disabled or 0) + 1 end end
function G.EndDisabled() local t = top(); if t and t._disabled then t._disabled = math.max(0, t._disabled - 1) end end
function G.PushID(v) idstack[#idstack + 1] = tostring(v) end
function G.PopID() idstack[#idstack] = nil end
function G.SetNextItemWidth() end
function G.PushItemWidth() end
function G.PopItemWidth() end
function G.AlignTextToFramePadding() end
function G.PushTextWrapPos(pos) pos = tonumber(pos) or 0; wrapstk[#wrapstk + 1] = pos >= 0 end
function G.PopTextWrapPos() wrapstk[#wrapstk] = nil end
function G.PushStyleColor(idx, a, b, c2, d)
    local col
    if type(a) == 'number' and type(b) == 'number' then col = color_of({ a, b, c2 }) else col = color_of(a) end
    colstk[#colstk + 1] = { tonumber(idx) or -1, col }
end
function G.PopStyleColor(n) for _ = 1, math.max(1, tonumber(n) or 1) do colstk[#colstk] = nil end end
function G.PushStyleVar() end
function G.PopStyleVar() end
function G.PushFont() end
function G.PopFont() end
function G.SetCursorPos() end
function G.SetCursorPosX() end
function G.SetCursorPosY() end
function G.SetCursorScreenPos() end
function G.SetItemDefaultFocus() end
function G.SetKeyboardFocusHere() end
function G.SetScrollHereY() end
function G.SetScrollY() end
function G.SetScrollX() end
function G.SetItemAllowOverlap() end
function G.SetNextItemOpen(open) local t = top(); if t then t._next_open = open and true or false end end

-- text ---------------------------------------------------------------------
function G.Text(f, ...) add({ k = 'text', text = format_text(f, ...) }) end
function G.TextUnformatted(t) add({ k = 'text', text = tostring(t or '') }) end
function G.TextWrapped(f, ...) add({ k = 'text', text = format_text(f, ...), wrap = true }) end
function G.TextDisabled(f, ...) add({ k = 'text', text = format_text(f, ...), muted = true }) end
function G.TextColored(c, ...)
    -- MQ allows TextColored(ImVec4, fmt, ...) and TextColored(r, g, b, a, fmt, ...)
    if type(c) == 'number' and select('#', ...) >= 4 and type((select(4, ...))) == 'string' then
        local g, b, _, f = ...
        local col = color_of({ c, g, b })
        add({ k = 'text', text = format_text(f, select(5, ...)), color = col })
        return
    end
    local f = ...
    add({ k = 'text', text = format_text(f, select(2, ...)), color = color_of(c) })
end
function G.LabelText(label, f, ...) local shown = split_label(label); add({ k = 'text', text = format_text(f, ...) .. '  ' .. shown }) end
function G.BulletText(f, ...) add({ k = 'text', text = '\226\128\162 ' .. format_text(f, ...) }) end
function G.Bullet() add({ k = 'text', text = '\226\128\162' }) end
function G.TextLink(t) local shown, key = split_label(t); local n = add({ k = 'button', label = shown, link = true }, key); return take_click(n.id) end

-- buttons ------------------------------------------------------------------
local function button(kind, label, a, b)
    local shown, key = split_label(label)
    local w = sizexy(a, b)
    local n = add({ k = kind, label = shown, w = w }, key)
    return take_click(n.id)
end
function G.Button(label, a, b) return button('button', label, a, b) end
function G.SmallButton(label) return button('sbutton', label) end
function G.InvisibleButton(id, a, b) return button('button', id, a, b) end
function G.ArrowButton(id, dir) local _, key = split_label(id); local n = add({ k = 'sbutton', label = (dir == 0 and '<') or (dir == 1 and '>') or (dir == 2 and '^') or 'v' }, key); return take_click(n.id) end
function G.ImageButton(id) local _, key = split_label(tostring(id)); local n = add({ k = 'button', label = '[img]' }, key); note('ImageButton', 'partial'); return take_click(n.id) end

function G.Checkbox(label, v)
    local shown, key = split_label(label)
    local n = add({ k = 'check', label = shown, v = v and true or false }, key)
    if take_click(n.id) then n.v = not n.v; return n.v, true end
    return v, false
end
function G.CheckboxFlags(label, flags, value)
    local shown, key = split_label(label)
    flags = num(flags, 0); value = num(value, 0)
    local on = value ~= 0 and (flags % (value * 2)) >= value
    local n = add({ k = 'check', label = shown, v = on }, key)
    if take_click(n.id) then
        if on then flags = flags - value else flags = flags + value end
        n.v = not on
        return flags, true
    end
    return flags, false
end
function G.RadioButton(label, a, b)
    local shown, key = split_label(label)
    if b ~= nil then -- (label, v, v_button) -> v, pressed
        local n = add({ k = 'radio', label = shown, v = a == b }, key)
        if take_click(n.id) then n.v = true; return b, true end
        return a, false
    end
    local n = add({ k = 'radio', label = shown, v = a and true or false }, key)
    return take_click(n.id)
end

function G.Selectable(label, selected, flags, a, b)
    local shown, key = split_label(label)
    local combo = nearest('combo')
    local n = add({ k = 'select', label = shown, v = selected and true or false }, key)
    if combo and top() == combo then
        combo.opts = combo.opts or {}
        combo.opts[#combo.opts + 1] = n
        if selected then combo.cur = n.id end
    end
    local clicked = take_click(n.id)
    if clicked then
        n.v = true
        -- ImGui: a Selectable inside a popup closes it (unless DontClosePopups = 1)
        if popup_stack[#popup_stack] and not has_flag(flags, 1) then S.open[popup_stack[#popup_stack]] = false end
    end
    return clicked, clicked
end

-- inputs -----------------------------------------------------------------
local function input(kind, label, v, extra)
    local shown, key = split_label(label)
    local n = add({ k = kind, label = shown, v = v }, key)
    if extra then for k2, x in pairs(extra) do n[k2] = x end end
    local nv = take_val(n.id)
    if nv ~= nil then
        if kind == 'inputint' or kind == 'slider' or kind == 'drag' or kind == 'inputnum' then
            local x = tonumber(nv)
            if x == nil then return v, false end
            if n.int then x = math.floor(x + 0.5) end
            if n.min and n.max and n.max > n.min then x = math.max(n.min, math.min(n.max, x)) end
            n.v = x
            return x, x ~= v
        end
        n.v = nv
        return nv, nv ~= v
    end
    return v, false
end
function G.InputText(label, text, flags) return input('input', label, tostring(text or '')) end
function G.InputTextWithHint(label, hint, text) return input('input', label, tostring(text or ''), { hint = hint }) end
function G.InputTextMultiline(label, text) return input('input', label, tostring(text or ''), { multi = true }) end
function G.InputInt(label, v, step) return input('inputint', label, num(v, 0), { int = true, step = step }) end
function G.InputFloat(label, v) return input('inputnum', label, num(v, 0)) end
function G.InputDouble(label, v) return input('inputnum', label, num(v, 0)) end
function G.SliderInt(label, v, mn, mx) return input('slider', label, num(v, 0), { int = true, min = num(mn, 0), max = num(mx, 100) }) end
function G.SliderFloat(label, v, mn, mx) return input('slider', label, num(v, 0), { min = num(mn, 0), max = num(mx, 1) }) end
function G.DragInt(label, v, speed, mn, mx)
    mn, mx = num(mn, 0), num(mx, 0)
    if mx <= mn then return input('inputint', label, num(v, 0), { int = true }) end
    return input('slider', label, num(v, 0), { int = true, min = mn, max = mx })
end
function G.DragFloat(label, v, speed, mn, mx)
    mn, mx = num(mn, 0), num(mx, 0)
    if mx <= mn then return input('inputnum', label, num(v, 0)) end
    return input('slider', label, num(v, 0), { min = mn, max = mx })
end
function G.SliderAngle(label, v) return input('slider', label, num(v, 0), { min = -6.2832, max = 6.2832 }) end
function G.VSliderInt(label, _, v, mn, mx) return G.SliderInt(label, v, mn, mx) end
function G.VSliderFloat(label, _, v, mn, mx) return G.SliderFloat(label, v, mn, mx) end

-- 2/3/4-component variants: one field per component on a row; returns the table back
local function multi(kind, n, label, vals, extra)
    local shown, key = split_label(label)
    local out, changed = {}, false
    local get = function(i) local ok, v = pcall(function() return vals[i] or (i == 1 and vals.x) or (i == 2 and vals.y) or (i == 3 and vals.z) or (i == 4 and vals.w) end); return ok and tonumber(v) or 0 end
    for i = 1, n do
        if i > 1 then pending_sl = true end
        local v, c = input(kind, (i == n and shown or '') .. '##' .. key .. '#' .. i, get(i), extra)
        out[i] = v; changed = changed or c
    end
    if type(vals) == 'table' and vals[1] == nil and vals.x ~= nil then
        return (n == 2 and vec2(out[1], out[2])) or vec4(out[1], out[2], out[3] or 0, out[4] or 0), changed
    end
    return out, changed
end
for n = 2, 4 do
    G['InputInt' .. n] = function(label, v) return multi('inputint', n, label, v, { int = true }) end
    G['InputFloat' .. n] = function(label, v) return multi('inputnum', n, label, v) end
    G['DragInt' .. n] = function(label, v) return multi('inputint', n, label, v, { int = true }) end
    G['DragFloat' .. n] = function(label, v) return multi('inputnum', n, label, v) end
    G['SliderInt' .. n] = function(label, v, mn, mx) return multi('slider', n, label, v, { int = true, min = num(mn, 0), max = num(mx, 100) }) end
    G['SliderFloat' .. n] = function(label, v, mn, mx) return multi('slider', n, label, v, { min = num(mn, 0), max = num(mx, 1) }) end
end
-- known no-ops / not mirrorable (recorded as partial, never break the tool)
for _, name in ipairs({ 'BeginDragDropSource', 'BeginDragDropTarget', 'BeginDragDropTargetCustom' }) do
    G[name] = function() note(name, 'partial'); return false end
end
function G.SetDragDropPayload() return false end
function G.AcceptDragDropPayload() return nil end
function G.GetDragDropPayload() return nil end
function G.EndDragDropSource() end
function G.EndDragDropTarget() end
function G.SetNextItemAllowOverlap() end
function G.ConsoleFont() note('ConsoleFont', 'partial'); return nil end
function G.PushTabStop() end
function G.PopTabStop() end
function G.PushButtonRepeat() end
function G.PopButtonRepeat() end
function G.PushAllowKeyboardFocus() end
function G.PopAllowKeyboardFocus() end
function G.SetMouseCursor() end
function G.CaptureMouseFromApp() end
function G.CaptureKeyboardFromApp() end
function G.SetNextFrameWantCaptureMouse() end
function G.SetNextFrameWantCaptureKeyboard() end
function G.LogToClipboard() end
function G.LogFinish() end
-- coverage gaps found by the corpus scan (COVERAGE.md) ---------------------------
-- MQ helper: "(?)" marker whose tooltip is the help text
function G.HelpMarker(desc) local n = add({ k = 'text', text = '(?)', muted = true }); n.tip = tostring(desc or ''); last_item = n end
function G.LogText() end                       -- ImGui log output only, nothing on screen
function G.PushClipRect() end
function G.PopClipRect() end
function G.SetWindowFocus() end
function G.IsKeyReleased() return false end
function G.IsKeyChordPressed() return false end
function G.ResetMouseDragDelta() end
function G.GetScrollX() return 0 end
function G.GetScrollMaxX() return 0 end
function G.GetStyleColorName(i) return 'Col' .. tostring(i) end
function G.GetFont() return setmetatable({ FontSize = 14, Scale = 1 }, { __index = function() return function() return 14 end end }) end
function G.GetWindowViewport() return G.GetMainViewport() end
function G.GetStyleColor(i) return G.GetStyleColorVec4(i) end
function G.GetMousePosOnOpeningCurrentPopup() return 0, 0 end
function G.GetMousePosOnOpeningCurrentPopupVec() return vec2(0, 0) end
-- MQ ConsoleWidget: a scrolling text log. Mirrored as a bordered child with one text row per line
-- (MQ \a color codes stripped; newest lines kept, at most maxBufferLines / 300 shown).
local function strip_mq(t) return (tostring(t or ''):gsub('\a%-?[%a#]%x*', ''):gsub('\a', '')) end
local Console = {}
Console.__index = Console
function Console:AppendText(f, ...)
    local t = select('#', ...) > 0 and format_text(f, ...) or tostring(f or '')
    for line in (strip_mq(t) .. '\n'):gmatch('([^\n]*)\n') do self.lines[#self.lines + 1] = line end
    local cap_n = math.max(1, tonumber(self.maxBufferLines) or 1000)
    while #self.lines > cap_n do table.remove(self.lines, 1) end
end
Console.AppendTextUnformatted = Console.AppendText
function Console:Clear() self.lines = {} end
function Console:Render(a, b)
    local w, h = sizexy(a, b)
    G.BeginChild(self.id, w, (h and h > 0) and h or 200, true)
    local from = math.max(1, #self.lines - 299)
    for i = from, #self.lines do add({ k = 'text', text = self.lines[i] }) end
    G.EndChild()
end
function Console:GetLineCount() return #self.lines end
G.ConsoleWidget = { new = function(id) return setmetatable({ id = tostring(id or 'console'), lines = {}, maxBufferLines = 1000, autoScroll = true }, Console) end }
-- ImGui.Register(name, fn) is MQ's other way to add a draw callback
function G.Register(name, fn) if M.on_register then M.on_register(name, fn) end end
function G.Unregister(name) if M.on_unregister then M.on_unregister(name) end end
function G.GetVersion() if M.real and M.real.GetVersion then local ok, v = pcall(M.real.GetVersion); if ok then return v end end return '1.90' end
function G.ShowDemoWindow() note('ShowDemoWindow', 'unsupported') end

local function color_edit(label, col, has_alpha)
    local shown, key = split_label(label)
    local hex = color_of(col) or '#ffffff'
    local n = add({ k = 'color', label = shown, v = hex }, key)
    local nv = take_val(n.id)
    if nv then
        local r, g, b = tostring(nv):match('^#?(%x%x)(%x%x)(%x%x)')
        if r then
            n.v = '#' .. r .. g .. b
            local R, Gc, B = tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255
            local a = 1
            pcall(function() a = col.w or col[4] or 1 end)
            if type(col) == 'table' and col[1] ~= nil then
                local out = { R, Gc, B }; if has_alpha then out[4] = a end
                return out, true
            end
            return vec4(R, Gc, B, a), true
        end
    end
    return col, false
end
function G.ColorEdit3(label, col) return color_edit(label, col, false) end
function G.ColorEdit4(label, col) return color_edit(label, col, true) end
function G.ColorPicker3(label, col) return color_edit(label, col, false) end
function G.ColorPicker4(label, col) return color_edit(label, col, true) end
function G.ColorButton(id, col) local n = add({ k = 'color', label = '', v = color_of(col) or '#ffffff', ro = true }, tostring(id)); return take_click(n.id) end

-- combos / lists -----------------------------------------------------------
function G.Combo(label, cur, items, count)
    local shown, key = split_label(label)
    local list = {}
    if type(items) == 'string' then
        for s in (items .. '\0'):gmatch('([^%z]*)%z') do if s ~= '' then list[#list + 1] = s end end
    elseif type(items) == 'table' then
        for i = 1, (tonumber(count) or #items) do list[#list + 1] = tostring(items[i] or '') end
    end
    local n = add({ k = 'combo', label = shown, items = list, v = num(cur, 1) }, key)
    F.sig[#F.sig] = F.sig[#F.sig] .. '\1' .. table.concat(list, '\2')
    local nv = tonumber(take_val(n.id) or '')
    if nv then n.v = nv; return nv, nv ~= cur end
    return cur, false
end
function G.ListBox(label, cur, items, count) return G.Combo(label, cur, items, count) end
function G.BeginCombo(label, preview)
    local shown, key = split_label(label)
    local n = add({ k = 'combo', label = shown, preview = tostring(preview or ''), opts = {} }, key)
    push(n)
    return true
end
function G.EndCombo()
    local n = nearest('combo')
    if n and n.opts then
        local labs = {}
        for i = 1, #n.opts do labs[i] = n.opts[i].label end
        -- sig for combo: option set (structure), not current value
        F.sig[#F.sig + 1] = 'opts\1' .. n.id .. '\1' .. table.concat(labs, '\2')
    end
    pop_to('combo')
end
function G.BeginListBox(label) local shown, key = split_label(label); local n = add({ k = 'child', label = shown, h = 120, border = true }, key); push(n); return true end
function G.EndListBox() pop_to('child') end

-- trees / headers ----------------------------------------------------------
local DEFAULT_OPEN = 32
local function tree(kind, label, flags, push_it)
    local shown, key = split_label(label)
    local t = top()
    local n = add({ k = kind, label = shown }, key)
    if S.open[n.id] == nil then
        if t and t._next_open ~= nil then S.open[n.id] = t._next_open
        else S.open[n.id] = has_flag(flags, DEFAULT_OPEN) end
    end
    if t then t._next_open = nil end
    if take_click(n.id) then S.open[n.id] = not S.open[n.id] end
    n.open = S.open[n.id]
    F.sig[#F.sig] = F.sig[#F.sig] .. (n.open and '+' or '-')
    if n.open and push_it then push(n) end
    return n.open, n
end
function G.TreeNode(label, f, ...)
    if f ~= nil then label = format_text(f, ...) .. '##' .. tostring(label) end
    local open = tree('tree', label, 0, true); return open
end
function G.TreeNodeEx(label, flags, f, ...)
    if f ~= nil then label = format_text(f, ...) .. '##' .. tostring(label) end
    -- NoTreePushOnOpen = 8: tool will not call TreePop
    local open, n = tree('tree', label, flags, not has_flag(flags, 8))
    return open
end
function G.TreePop() pop_to('tree') end
function G.TreePush(id) local n = add({ k = 'group' }, tostring(id or 'tp')); n.k = 'tree'; n.open = true; push(n) end
function G.CollapsingHeader(label, a, b)
    local flags, has_vis = a, false
    if type(a) == 'boolean' then flags = b; has_vis = true end
    local open, n = tree('header', label, flags, false)
    -- headers don't push in ImGui; following items are siblings. We nest the
    -- following items until the next header / end of container for layout.
    if open then n.c = {}; n._hdr = true; local t = top(); if t then t._hdr = n end end
    if has_vis then return open, true end
    return open
end

-- tabs ---------------------------------------------------------------------
function G.BeginTabBar(id)
    local _, key = split_label(id)
    local n = add({ k = 'tabbar', tabs = {} }, key)
    push(n)
    return true
end
function G.EndTabBar() pop_to('tabbar') end
function G.BeginTabItem(label, p_open, flags)
    local bar = nearest('tabbar')
    local shown, key = split_label(label)
    if not bar then return false end
    local tid = bar.id .. '/ti:' .. key
    bar.tabs[#bar.tabs + 1] = { id = tid, label = shown }
    F.sig[#F.sig + 1] = 'tab\1' .. tid
    if take_click(tid) then S.tab[bar.id] = tid end
    if type(flags) == 'number' and has_flag(flags, 2) then S.tab[bar.id] = tid end -- SetSelected
    if S.tab[bar.id] == nil then S.tab[bar.id] = tid end
    local sel = S.tab[bar.id] == tid
    if sel then
        bar.active = tid
        local n = { k = 'tabitem', id = tid, label = shown, c = {} }
        bar.c[#bar.c + 1] = n
        F.sig[#F.sig + 1] = 'tabsel\1' .. tid
        push(n)
    end
    if type(p_open) == 'boolean' then return sel, p_open end
    return sel
end
function G.EndTabItem() pop_to('tabitem') end
function G.TabItemButton(label) local bar = nearest('tabbar'); local shown, key = split_label(label); if not bar then return false end; local tid = bar.id .. '/tb:' .. key; bar.tabs[#bar.tabs + 1] = { id = tid, label = shown, btn = true }; return take_click(tid) end
function G.SetTabItemClosed() end

-- tables / columns -----------------------------------------------------------
function G.BeginTable(id, ncols, flags)
    local _, key = split_label(id)
    local n = add({ k = 'table', ncols = math.max(1, num(ncols, 1)), cols = {}, rows = {} }, key)
    n.c = n.c or {}
    push(n)
    return true
end
local function tbl_close_cell(t) local _, i = nearest('table'); if i then for j = #stack, i + 1, -1 do stack[j] = nil end end end
local function tbl_new_row(t)
    tbl_close_cell(t)
    local r = { k = 'row', c = {}, id = t.id .. '/r' .. (#t.c + 1) }
    t.c[#t.c + 1] = r; t._row = r; t._col = 0
    F.sig[#F.sig + 1] = 'row\1' .. r.id
    return r
end
local function tbl_cell(t, col)
    if not t._row then tbl_new_row(t) end
    if col > t.ncols then tbl_new_row(t); col = 1 end
    tbl_close_cell(t)
    local r = t._row
    local cell = r.c[col]
    for i = #r.c + 1, col do r.c[i] = { k = 'cell', c = {}, id = r.id .. '/c' .. i } end
    cell = r.c[col]
    t._col = col
    F.sig[#F.sig + 1] = 'cell\1' .. cell.id
    push(cell)
end
function G.TableSetupColumn(label, flags, w) local t = nearest('table'); if t then t.cols[#t.cols + 1] = split_label(label); if tonumber(w) and tonumber(w) > 0 then t.colw = t.colw or {}; t.colw[#t.cols] = tonumber(w) end end end
function G.TableSetupScrollFreeze() end
function G.TableHeadersRow() local t = nearest('table'); if t then t.hdr = true; F.sig[#F.sig + 1] = 'hdr\1' .. t.id .. table.concat(t.cols, '\2') end end
function G.TableHeader(label) local t = nearest('table'); if t then t.hdr = true end end
function G.TableNextRow() local t = nearest('table'); if t then tbl_new_row(t) end end
function G.TableNextColumn() local t = nearest('table'); if not t then return false end; tbl_cell(t, (t._col or 0) + 1); return true end
function G.TableSetColumnIndex(i) local t = nearest('table'); if not t then return false end; tbl_cell(t, num(i, 0) + 1); return true end
function G.TableGetColumnIndex() local t = nearest('table'); return t and math.max(0, (t._col or 1) - 1) or 0 end
function G.TableGetRowIndex() local t = nearest('table'); return t and #t.c or 0 end
function G.TableSetBgColor() end
function G.TableGetSortSpecs() return nil end
function G.TableGetColumnCount() local t = nearest('table'); return t and t.ncols or 0 end
function G.EndTable() pop_to('table') end
function G.Columns(n, id)
    n = num(n, 1)
    local cur = nearest('table')
    if cur and cur.legacy then pop_to('table') end
    if n > 1 then
        local t = add({ k = 'table', ncols = n, cols = {}, legacy = true }, 'cols:' .. tostring(id or ''))
        t.c = {}
        push(t)
        tbl_cell(t, 1)
    end
end
function G.NextColumn() local t = nearest('table'); if t and t.legacy then tbl_cell(t, (t._col or 0) + 1) end end
function G.SetColumnWidth(i, w) local t = nearest('table'); if t and tonumber(w) then t.colw = t.colw or {}; t.colw[num(i, 0) + 1] = tonumber(w) end end
function G.TableSetupColumn_w() end
function G.GetColumnWidth() return 120 end
function G.GetColumnIndex() local t = nearest('table'); return t and math.max(0, (t._col or 1) - 1) or 0 end

-- menus --------------------------------------------------------------------
function G.BeginMenuBar() local w = nearest('window') or top(); if not w then return false end; local n = add({ k = 'menubar' }, 'menubar'); push(n); return true end
function G.EndMenuBar() pop_to('menubar') end
function G.BeginMainMenuBar() return G.BeginMenuBar() end
function G.EndMainMenuBar() return G.EndMenuBar() end
function G.BeginMenu(label, enabled)
    local shown, key = split_label(label)
    local n = add({ k = 'menu', label = shown }, key)
    if take_click(n.id) then
        local was = S.open[n.id]
        S.open[n.id] = not was
    end
    n.open = S.open[n.id] and true or false
    F.sig[#F.sig] = F.sig[#F.sig] .. (n.open and '+' or '-')
    if n.open then push(n) end
    return n.open
end
function G.EndMenu() pop_to('menu') end
function G.MenuItem(label, shortcut, selected, enabled)
    local shown, key = split_label(label)
    local n = add({ k = 'menuitem', label = shown, short = type(shortcut) == 'string' and shortcut or nil, v = selected == true }, key)
    local clicked = take_click(n.id)
    if clicked and popup_stack[#popup_stack] then S.open[popup_stack[#popup_stack]] = false end
    if clicked then for k2 in pairs(S.open) do if k2:find('/me:', 1, true) then S.open[k2] = false end end end
    if type(selected) == 'boolean' then
        if clicked then return not selected, true end
        return selected, false
    end
    return clicked
end

-- popups -------------------------------------------------------------------
local function popup_key(id)
    local w = nearest('window')
    return (w and w.id or '') .. '/pop:' .. tostring(id)
end
function G.OpenPopup(id) S.open[popup_key(id)] = true end
function G.OpenPopupOnItemClick(id) if last_item and S.ctxreq[last_item.id] then S.ctxreq[last_item.id] = nil; S.open[popup_key(id or last_item.id)] = true end end
function G.IsPopupOpen(id) return S.open[popup_key(id)] == true end
local function begin_popup(id, modal, p_open)
    local key = popup_key(id)
    if not S.open[key] then return false end
    local title = split_label(tostring(id))
    local w = nearest('window')
    local n = { k = 'popup', id = key, title = title, modal = modal, c = {} }
    if w then w.popups = w.popups or {}; w.popups[#w.popups + 1] = n end
    F.sig[#F.sig + 1] = 'popup\1' .. key
    push(n)
    popup_stack[#popup_stack + 1] = key
    return true
end
function G.BeginPopup(id) return begin_popup(id, false) end
function G.BeginPopupModal(id, p_open)
    local r = begin_popup(id, true)
    if type(p_open) == 'boolean' then return r, r end
    return r
end
function G.BeginPopupContextItem(id)
    local item = last_item
    local pid = id or (item and item.id) or 'ctx'
    if item and S.ctxreq[item.id] then S.ctxreq[item.id] = nil; S.open[popup_key(pid)] = true end
    if item and not item.ctx and item.id ~= '?' then item.ctx = true; F.sig[#F.sig + 1] = 'ctx\1' .. item.id end
    return begin_popup(pid, false)
end
function G.BeginPopupContextWindow(id) local pid = id or 'ctxwin'; return begin_popup(pid, false) end
function G.BeginPopupContextVoid(id) return false end
function G.CloseCurrentPopup() local k = popup_stack[#popup_stack]; if k then S.open[k] = false end end
function G.EndPopup() pop_to('popup'); popup_stack[#popup_stack] = nil end

-- tooltips (no hover in replay: text kept as a title on the last item) ---------
local sink = { k = 'sink', c = {} }
-- BeginTooltip content is collected as text and shown as the hovered item's tooltip
function G.BeginTooltip() push({ k = 'tooltip', id = 'tt', c = {}, owner = last_item }); return true end
function G.EndTooltip()
    local t = nearest('tooltip')
    pop_to('tooltip')
    if t and t.owner then
        local parts = {}
        local function walk(n) for i = 1, #(n.c or {}) do local x = n.c[i]; if x.text then parts[#parts + 1] = x.text elseif x.label and x.label ~= '' then parts[#parts + 1] = x.label end; walk(x) end end
        walk(t)
        if #parts > 0 then t.owner.tip = table.concat(parts, '\n') end
        last_item = t.owner
    end
end
function G.SetTooltip(f, ...) if last_item then last_item.tip = format_text(f, ...) end end
function G.SetItemTooltip(f, ...) if last_item then last_item.tip = format_text(f, ...) end end
function G.BeginItemTooltip() return false end

-- progress / plots / images ------------------------------------------------
function G.ProgressBar(frac, a, b, overlay)
    if type(a) == 'string' then overlay = a elseif type(b) == 'string' then overlay = b end
    add({ k = 'progress', v = math.max(0, math.min(1, num(frac, 0))), text = overlay })
end
local function plot(kind, label, values, count, offset, overlay, mn, mx)
    local shown = split_label(label)
    local vals = {}
    if type(values) == 'table' then
        local n = tonumber(count) or #values
        for i = 1, n do vals[i] = tonumber(values[i]) or 0 end
    elseif type(values) == 'function' then
        note(kind .. '(getter)', 'partial')
    end
    add({ k = 'plot', style = kind, label = shown, vals = vals, text = type(overlay) == 'string' and overlay or nil, min = tonumber(mn), max = tonumber(mx) }, shown)
end
function G.PlotLines(...) plot('lines', ...) end
function G.PlotHistogram(...) plot('hist', ...) end
function G.Image(_, a, b) local w, h = sizexy(a, b); add({ k = 'image', w = w, h = h }) end
function G.DrawTextureAnimation(_, w, h) add({ k = 'image', w = num(w, 32), h = num(h, 32) }) end

-- item / window queries ----------------------------------------------------
function G.IsItemClicked()
    if not last_item or last_item.id == '?' then return false end
    if M._lastclick == last_item.id then return true end
    if not last_item.clk then last_item.clk = true; F.sig[#F.sig + 1] = 'clk\1' .. last_item.id end
    return take_click(last_item.id)
end
-- Hover is decided by RmlUi at display time, so tooltip code must run every frame: report "hovered" for a
-- real item (~90% of IsItemHovered blocks in the corpus only build a tooltip, which is then shown on CSS hover).
function G.IsItemHovered() return last_item ~= nil and last_item.id ~= '?' and nearest('tooltip') == nil end
function G.IsItemActive() return false end
function G.IsItemFocused() return false end
function G.IsItemEdited() return false end
function G.IsItemDeactivatedAfterEdit() return false end
function G.IsItemVisible() return true end
function G.IsWindowHovered() return false end
function G.IsWindowFocused() return false end
function G.IsWindowCollapsed() return false end
function G.IsWindowAppearing() return false end
function G.IsMouseClicked() return false end
function G.IsMouseDoubleClicked() return false end
function G.IsMouseDown() return false end
function G.IsMouseReleased() return false end
function G.IsMouseDragging() return false end
function G.IsKeyPressed() return false end
function G.IsKeyDown() return false end
function G.IsAnyItemHovered() return false end
function G.IsAnyItemActive() return false end
function G.GetWindowWidth() local w = nearest('window'); return (w and w.w and w.w > 0) and w.w or 480 end
function G.GetWindowHeight() local w = nearest('window'); return (w and w.h and w.h > 0) and w.h or 400 end
-- MQ binding convention: Get*Pos/Size/Avail return two numbers (x, y); the *Vec variants return ImVec2.
local function pair(name, fx, fy)
    G[name] = function(...) return fx(...), fy(...) end
    G[name .. 'Vec'] = function(...) return vec2(fx(...), fy(...)) end
end
local function c(v) return function() return v end end
local function ww() return G.GetWindowWidth() end
local function wh() return G.GetWindowHeight() end
pair('GetWindowSize', ww, wh)
pair('GetWindowPos', c(160), c(100))
pair('GetContentRegionAvail', function() return ww() - 16 end, function() return wh() - 40 end)
pair('GetContentRegionMax', function() return ww() - 8 end, function() return wh() - 8 end)
pair('GetWindowContentRegionMax', function() return ww() - 8 end, function() return wh() - 8 end)
pair('GetWindowContentRegionMin', c(8), c(30))
pair('GetCursorPos', c(8), c(30))
pair('GetCursorStartPos', c(8), c(30))
pair('GetCursorScreenPos', c(168), c(130))
pair('GetItemRectSize', c(80), c(22))
pair('GetItemRectMin', c(0), c(0))
pair('GetItemRectMax', c(80), c(22))
pair('GetMousePos', c(0), c(0))
pair('GetMouseDragDelta', c(0), c(0))
pair('CalcTextSize', function(t) return #tostring(t or '') * 7 end, c(14))
function G.GetWindowContentRegionWidth() return ww() - 16 end
function G.GetContentRegionAvailWidth() return ww() - 16 end
function G.GetCursorPosX() return 8 end
function G.GetCursorPosY() return 30 end
function G.GetTextLineHeight() return 14 end
function G.GetTextLineHeightWithSpacing() return 18 end
function G.GetFrameHeight() return 22 end
function G.GetFrameHeightWithSpacing() return 26 end
function G.GetFontSize() return 14 end
function G.GetScrollY() return 0 end
function G.GetScrollMaxY() return 0 end
function G.GetTime() return os.clock() end
function G.GetFrameCount() return M.stats.frames end
function G.CalcItemWidth() return 160 end
function G.GetID(s) return tostring(s) end
function G.GetColorU32() return 0xffffffff end
function G.ColorConvertFloat4ToU32() return 0xffffffff end
function G.ColorConvertU32ToFloat4() return vec4(1, 1, 1, 1) end
function G.GetStyleColorVec4() return vec4(1, 1, 1, 1) end

local function anyvec() return setmetatable({}, { __index = function(_, k) if k == 'x' or k == 'y' then return 0 end return vec2(4, 4) end }) end
local style = setmetatable({}, { __index = function() return vec2(4, 4) end, __newindex = function() end })
pcall(function() rawset(style, 'Colors', setmetatable({}, { __index = function() return vec4(1, 1, 1, 1) end, __newindex = function() end })) end)
function G.GetStyle() return style end
local io_ = setmetatable({ DisplaySize = vec2(1920, 1080), DeltaTime = 1 / 60, Framerate = 60, MousePos = vec2(0, 0),
    KeyCtrl = false, KeyShift = false, KeyAlt = false, WantCaptureMouse = false, WantCaptureKeyboard = false, FontGlobalScale = 1 },
    { __index = function() return false end })
function G.GetIO() return io_ end
function G.GetMainViewport() return { Pos = vec2(0, 0), Size = vec2(1920, 1080), WorkPos = vec2(0, 0), WorkSize = vec2(1920, 1080) } end

-- draw lists: custom drawing cannot be mirrored; calls are counted and ignored
local dl = setmetatable({}, { __index = function(_, name) note('DrawList.' .. tostring(name), 'unsupported'); return function() end end })
function G.GetWindowDrawList() return dl end
function G.GetForegroundDrawList() return dl end
function G.GetBackgroundDrawList() return dl end

-- clipboard passes through to real ImGui when available (no frame needed)
function G.SetClipboardText(t) if M.real and M.real.SetClipboardText then pcall(M.real.SetClipboardText, t) end end
function G.GetClipboardText() if M.real and M.real.GetClipboardText then local ok, v = pcall(M.real.GetClipboardText); if ok then return v end end return '' end

-- anything else: heuristic default, recorded so the report can list it
local proxy = setmetatable({}, {
    __index = function(_, name)
        local f = G[name]
        if f then return f end
        -- constants/enums some tools read off ImGui itself
        if M.real then
            local ok, v = pcall(function() return M.real[name] end)
            if ok and v ~= nil and type(v) ~= 'function' then return v end
        end
        note(name, 'unsupported')
        local s = tostring(name)
        if s:match('^Is') or s:match('^Begin') then return function() return false end end
        if s:match('Size$') or s:match('Pos$') or s:match('Avail$') or s:match('Min$') or s:match('Max$') then return function() return vec2(0, 0) end end
        if s:match('^Get') then return function() return 0 end end
        return function() end
    end,
    __newindex = function(_, k, v) G[k] = v end,
})
M.proxy = proxy
M.G = G

-- ---------------------------------------------------------------- frame api
function M.begin_frame()
    F = { windows = {}, order = {}, sig = {} }
    stack, idstack, popup_stack = {}, {}, {}
    for k in pairs(colstk) do colstk[k] = nil end
    for k in pairs(wrapstk) do wrapstk[k] = nil end
    last_item, pending_sl = nil, false
    M._lastclick = nil
    M.stats.nodes = 0
end

--- Run fn inside a capture frame; returns frame (windows by id + order + signature per window).
function M.frame(fns)
    M.begin_frame()
    for i = 1, #fns do
        local ok, err = pcall(fns[i])
        if not ok then M.stats.errors = M.stats.errors + 1; M.stats.last_error = tostring(err) end
        stack = {}; idstack = {}
    end
    M.stats.frames = M.stats.frames + 1
    -- unconsumed one-shot input expires (ImGui semantics: a click is a one-frame event)
    for k in pairs(S.click) do S.click[k] = nil end
    for k in pairs(S.ctxreq) do S.ctxreq[k] = nil end
    -- per-window signature
    local per = {}
    local cur
    for i = 1, #F.sig do
        local s = F.sig[i]
        local wid = s:match('^window\1(.*)$')
        if wid then cur = wid; per[wid] = per[wid] or {} elseif cur then local t = per[cur]; t[#t + 1] = s end
    end
    for wid, t in pairs(per) do if F.windows[wid] then F.windows[wid].sig = table.concat(t, '\n') end end
    return F
end

return M
