--[[
  Live ImGui → Rml bridge.

  The port loads the original script unchanged. require('ImGui') returns this
  shim, mq.imgui.init stores the real draw callback, and each frame that
  callback runs here. Widgets, values, and clicks are the script's own.
]]

local mq = require('mq')
local host = require('rmlui.host')

local M = {}

local function esc(s)
    return tostring(s or '')
        :gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'):gsub('"', '&quot;')
end

local function vis_label(label)
    label = tostring(label or '')
    local show = label:match('^(.-)##') or label
    show = show:gsub('^%s+', ''):gsub('%s+$', '')
    if show == '' then
        show = label:match('##(.+)$') or ''
        show = show:gsub('^#+', '')
    end
    return show
end

local function vec(x, y)
    local v = { x = tonumber(x) or 0, y = tonumber(y) or 0 }
    return setmetatable(v, {
        __add = function(a, b)
            return vec((a.x or 0) + (b.x or 0), (a.y or 0) + (b.y or 0))
        end,
        __sub = function(a, b)
            return vec((a.x or 0) - (b.x or 0), (a.y or 0) - (b.y or 0))
        end,
    })
end

local clicks, changes = {}, {}
local open_state, tab_state = {}, {}
local id2short, seq = {}, 0

local function short(stable)
    local s = id2short[stable]
    if not s then
        seq = seq + 1
        s = 'i' .. tostring(seq)
        id2short[stable] = s
    end
    return s
end

local function fmt(first, ...)
    local s = tostring(first or '')
    if select('#', ...) > 0 and s:find('%%', 1, true) then
        local ok, r = pcall(string.format, s, ...)
        if ok then return r end
    end
    return s
end

local S = {
    parts = {},
    stack = {},
    path = {},
    counts = {},
    line = false,
    same = false,
    capture = nil,
    colors = {},
    binds = {},
    n = 0,
    combo = nil,
}

local function reset_frame()
    S.parts = {}
    S.stack = {}
    S.path = {}
    S.counts = {}
    S.line = false
    S.same = false
    S.capture = nil
    S.colors = {}
    S.binds = {}
    S.n = 0
    S.combo = nil
end

local function new_frame()

    local table_top
    local button_extras
    local style_color

    local function raw(html)
        local cap = S.capture
        if cap and cap.kind == 'tabbar' then
            if cap.phase == 'skip' then return end
            if cap.phase == 'body' then
                cap.body[#cap.body + 1] = html
                return
            end
            return
        end
        S.parts[#S.parts + 1] = html
    end

    local function close_line()
        if S.line then
            raw('</div>')
            S.line = false
        end
    end

    local function bind(id, kind, value)
        S.binds[#S.binds + 1] = { id = id, kind = kind, value = tostring(value or '') }
    end

    local function node_id()
        S.n = S.n + 1
        return 'n' .. tostring(S.n)
    end

    local function emit(html)
        local t = table_top()
        if t and t.in_cell then
            raw(html)
            return
        end
        if not S.same then
            close_line()
            raw('<div class="ig-row">')
            S.line = true
        end
        raw(html)
        S.same = false
    end

    local function wid(label)
        local key = table.concat(S.path, '>') .. '|' .. tostring(label)
        S.counts[key] = (S.counts[key] or 0) + 1
        return key .. '#' .. tostring(S.counts[key])
    end

    local function take_click(token)
        if clicks[token] then
            clicks[token] = nil
            return true
        end
        return false
    end

    local api = {}

    function api.Begin(name, open)
        close_line()
        local title = vis_label(name)
        if title == '' then title = 'Window' end
        raw('<div class="ig-win"><div class="ig-wintitle">' .. esc(title) .. '</div>')
        S.stack[#S.stack + 1] = 'win'
        local opened = true
        if type(open) == 'boolean' then opened = open end
        return opened, opened
    end

    function api.End()
        close_line()
        if S.stack[#S.stack] == 'win' then
            S.stack[#S.stack] = nil
            raw('</div>')
        end
    end

    function api.BeginChild()
        close_line()
        raw('<div class="ig-child">')
        S.stack[#S.stack + 1] = 'child'
        return true
    end

    function api.EndChild()
        close_line()
        if S.stack[#S.stack] == 'child' then
            S.stack[#S.stack] = nil
            raw('</div>')
        end
    end

    function api.BeginTabBar(id)
        close_line()
        local bar = {
            kind = 'tabbar',
            id = tostring(id or 'tabs'),
            buttons = {},
            body = {},
            phase = 'chrome',
            parent = S.capture,
        }
        S.stack[#S.stack + 1] = bar
        S.capture = bar
        return true
    end

    function api.EndTabBar()
        close_line()
        local bar = S.capture
        if not bar or bar.kind ~= 'tabbar' then return end
        S.capture = bar.parent
        if S.stack[#S.stack] == bar then S.stack[#S.stack] = nil end
        raw('<div class="ig-tabs">' .. table.concat(bar.buttons) .. '</div>' .. table.concat(bar.body))
    end

    function api.BeginTabItem(label)
        local bar = S.capture
        if not bar or bar.kind ~= 'tabbar' then return false end
        if bar.phase == 'body' then close_line() end
        bar.phase = 'chrome'
        local show = vis_label(label)
        if show == '' then show = tostring(label or 'Tab') end
        local token = short(wid('tab:' .. bar.id .. ':' .. tostring(label)))
        if take_click(token) then tab_state[bar.id] = tostring(label) end
        if tab_state[bar.id] == nil then tab_state[bar.id] = tostring(label) end
        local on = tab_state[bar.id] == tostring(label)
        local face = esc(show)
        bar.buttons[#bar.buttons + 1] = '<button id="' .. token .. '" class="ig-tab' .. (on and ' on' or '') .. '" action="' .. token .. '">' .. face .. '</button>'
        bind(token, 'text', show)
        bar.phase = on and 'body' or 'skip'
        return on
    end

    function api.EndTabItem()
        local bar = S.capture
        if bar and bar.kind == 'tabbar' and bar.phase == 'body' then close_line() end
        if bar and bar.kind == 'tabbar' then bar.phase = 'chrome' end
    end

    function api.CollapsingHeader(label)
        local show = vis_label(label)
        if show == '' then show = tostring(label or 'Section') end
        local stable = wid('hdr:' .. tostring(label))
        local token = short(stable)
        if open_state[stable] == nil then open_state[stable] = true end
        if take_click(token) then open_state[stable] = not open_state[stable] end
        local on = open_state[stable] == true
        emit('<button class="ig-hdr' .. (on and ' on' or '') .. '" action="' .. token .. '">' .. esc(show) .. '</button>')
        return on
    end

    function api.TreeNode(label) return api.CollapsingHeader(label) end
    function api.TreeNodeEx(label) return api.CollapsingHeader(label) end
    function api.TreePop() end

    function api.Button(label)
        local show = vis_label(label)
        local token = short(wid('btn:' .. tostring(label)))
        local hit = take_click(token)
        local face = show ~= '' and show or '·'
        local extra, style = button_extras(face)
        emit('<button id="' .. token .. '" class="ig-btn' .. extra .. '" action="' .. token .. '"' .. style .. '>' .. esc(face) .. '</button>')
        bind(token, 'text', face)
        return hit
    end

    function api.SmallButton(label) return api.Button(label) end
    function api.InvisibleButton(label)
        local token = short(wid('hit:' .. tostring(label)))
        local hit = take_click(token)
        emit('<div class="ig-hit" action="' .. token .. '"></div>')
        return hit
    end

    function api.Checkbox(label, value)
        local show = vis_label(label)
        local token = short(wid('chk:' .. tostring(label)))
        local pressed = take_click(token)
        local cur = value and true or false
        if pressed then cur = not cur end
        local chunk = '<input id="' .. token .. '" class="checkbox" type="checkbox" action="' .. token .. '"'
            .. (cur and ' checked' or '') .. '/>'
        if show ~= '' then
            local tid = node_id()
            chunk = chunk .. '<span id="' .. tid .. '" class="ig-text" action="' .. token .. '">' .. esc(show) .. '</span>'
            bind(tid, 'text', show)
        end
        emit(chunk)
        bind(token, 'checked', cur and '1' or '0')
        return cur, pressed
    end

    function api.Selectable(label, selected)
        local show = vis_label(label)
        local token = short(wid('sel:' .. tostring(label)))
        local hit = take_click(token)
        local on = selected and true or false
        local face = show ~= '' and show or '·'
        emit('<button id="' .. token .. '" class="ig-btn' .. (on and ' on' or '') .. '" action="' .. token .. '">' .. esc(face) .. '</button>')
        bind(token, 'text', face)
        if hit and S.combo then open_state[S.combo] = false end
        return hit, hit
    end

    function api.MenuItem(label)
        return api.Button(label)
    end

    local function input_widget(label, text)
        local show = vis_label(label)
        local token = short(wid('in:' .. tostring(label)))
        local val = tostring(text or '')
        local changed = false
        if changes[token] ~= nil then
            local nxt = tostring(changes[token])
            changes[token] = nil
            if nxt ~= val then
                val = nxt
                changed = true
            end
        end
        local chunk = {}
        if show ~= '' then
            local tid = node_id()
            chunk[#chunk + 1] = '<span id="' .. tid .. '" class="ig-text">' .. esc(show) .. '</span>'
            bind(tid, 'text', show)
        end
        chunk[#chunk + 1] = '<input id="' .. token .. '" class="text" type="text" value="' .. esc(val) .. '"/>'
        bind(token, 'value', val)
        emit(table.concat(chunk))
        return val, changed
    end

    function api.InputText(label, text) return input_widget(label, text) end
    function api.InputTextWithHint(label, _, text) return input_widget(label, text) end
    function api.InputTextMultiline(label, text) return input_widget(label, text) end

    function api.InputInt(label, value)
        local text, changed = input_widget(label, tostring(value or 0))
        local n = tonumber(text)
        if n == nil then return value or 0, false end
        return n, changed
    end

    function api.InputFloat(label, value) return api.InputInt(label, value) end
    function api.DragInt(label, value) return api.InputInt(label, value) end
    function api.DragFloat(label, value) return api.InputInt(label, value) end
    local function clamp_num(n, minv, maxv)
        if type(minv) == 'number' and n < minv then n = minv end
        if type(maxv) == 'number' and n > maxv then n = maxv end
        return n
    end

    local function slider_widget(label, value, minv, maxv, step, fmt)
        local n = tonumber(value) or 0
        minv = tonumber(minv) or 0
        maxv = tonumber(maxv) or (minv + 1)
        if maxv < minv then maxv = minv end
        local show = vis_label(label)
        local token = short(wid('sld:' .. tostring(label)))
        if changes[token] ~= nil then
            local nxt = tonumber(changes[token])
            changes[token] = nil
            if nxt ~= nil then n = nxt end
        end
        n = clamp_num(n, minv, maxv)
        local shown = tostring(n)
        if type(fmt) == 'string' and fmt:find('%%', 1, true) then
            local ok, s = pcall(string.format, fmt, n)
            if ok then shown = s end
        end
        local chunk = {}
        if show ~= '' then
            local tid = node_id()
            chunk[#chunk + 1] = '<span id="' .. tid .. '" class="ig-text">' .. esc(show) .. '</span>'
            bind(tid, 'text', show)
        end
        chunk[#chunk + 1] = string.format(
            '<input id="%s" class="range" type="range" min="%s" max="%s" step="%s" value="%s"/>',
            token, minv, maxv, step, n)
        local vid = node_id()
        chunk[#chunk + 1] = '<span id="' .. vid .. '" class="ig-text">' .. esc(shown) .. '</span>'
        bind(token, 'value', tostring(n))
        bind(vid, 'text', shown)
        emit(table.concat(chunk))
        return n
    end

    function api.SliderInt(label, value, minv, maxv)
        return slider_widget(label, math.floor((tonumber(value) or 0) + 0.5), minv, maxv, '1', nil)
    end

    function api.SliderFloat(label, value, minv, maxv, fmt)
        local decimals = 1
        if type(fmt) == 'string' then
            local d = fmt:match('%%%.?(%d*)f')
            if d and d ~= '' then decimals = tonumber(d) or 1 end
        end
        local step = '0.' .. string.rep('0', math.max(0, decimals - 1)) .. '1'
        return slider_widget(label, value, minv, maxv, step, fmt)
    end

    function api.Combo(label, current, items, count)
        local show = vis_label(label)
        local idx = tonumber(current) or 1
        local list = {}
        if type(items) == 'table' then
            for i, v in ipairs(items) do list[i] = tostring(v) end
        elseif type(items) == 'function' then
            local n = tonumber(count) or 0
            for i = 1, n do
                local ok, v = pcall(items, i)
                list[i] = ok and tostring(v or '') or ''
            end
        end
        if show ~= '' then emit('<span class="ig-text">' .. esc(show) .. '</span>') end
        local changed = false
        local n = #list
        local cap = n > 24 and 24 or n
        for i = 1, cap do
            local token = short(wid('cmb:' .. tostring(label) .. ':' .. tostring(i)))
            if take_click(token) then
                idx = i
                changed = true
            end
            local on = i == idx
            emit('<button class="ig-btn' .. (on and ' on' or '') .. '" action="' .. token .. '">' .. esc(list[i]) .. '</button>')
        end
        if n > cap then
            emit('<span class="ig-note">+' .. tostring(n - cap) .. '</span>')
        end
        if n == 0 then
            emit('<span class="ig-note">' .. esc(show ~= '' and show or 'empty') .. '</span>')
        end
        return idx, changed
    end

    function api.BeginCombo(label, preview)
        local show = vis_label(label)
        local token = short(wid('cbo:' .. tostring(label)))
        if take_click(token) then open_state[token] = not open_state[token] end
        local on = open_state[token] == true
        local face = (show ~= '' and (show .. ': ') or '') .. tostring(preview or '')
        emit('<button id="' .. token .. '" class="ig-btn' .. (on and ' on' or '') .. '" action="' .. token .. '">' .. esc(face) .. '</button>')
        bind(token, 'text', face)
        if on then S.combo = token end
        return on
    end

    function api.EndCombo()
        S.combo = nil
    end

    function api.BeginMenuBar() return true end
    function api.EndMenuBar() end
    function api.BeginMenu(label) return api.BeginCombo(label, '') end
    function api.EndMenu() api.EndCombo() end

    function api.ListBox(label, current, items, count)
        local idx, changed = api.Combo(label, (tonumber(current) or 0) + 1, items, count)
        return idx - 1, changed
    end

    function api.RadioButton(label, active)
        local show = vis_label(label)
        local token = short(wid('rad:' .. tostring(label)))
        local hit = take_click(token)
        local on = active and true or false
        local face = (on and '(*) ' or '( ) ') .. show
        emit('<button id="' .. token .. '" class="ig-btn' .. (on and ' on' or '') .. '" action="' .. token .. '">' .. esc(face) .. '</button>')
        bind(token, 'text', face)
        return hit
    end

    function api.ColorEdit3(_, r, g, b) return r, g, b end
    function api.ColorEdit4(_, r, g, b, a) return r, g, b, a end

    local function channel(v)
        v = tonumber(v) or 0
        if v >= 0 and v <= 1 then v = v * 255 end
        return math.max(0, math.min(255, math.floor(v + 0.5)))
    end

    local function hex_color(c)
        return string.format('#%02x%02x%02x', channel(c.r), channel(c.g), channel(c.b))
    end

    function style_color(name)
        local want = ImGuiCol and ImGuiCol[name]
        if want == nil then return nil end
        for i = #S.colors, 1, -1 do
            if S.colors[i].col == want then return S.colors[i] end
        end
    end

    function button_extras(face)
        local extra = ''
        if tostring(face or ''):find('[\128-\255]') then extra = ' ig-ico' end
        local bits = {}
        local bg = style_color('Button')
        local fg = style_color('Text')
        if bg then bits[#bits + 1] = 'background-color:' .. hex_color(bg) end
        if fg then bits[#bits + 1] = 'color:' .. hex_color(fg) end
        local style = ''
        if #bits > 0 then style = ' style="' .. table.concat(bits, ';') .. ';"' end
        return extra, style
    end

    local function text_span(content, color)
        local id = node_id()
        local style = ''
        if color then style = ' style="color:' .. hex_color(color) .. ';"' end
        emit('<span id="' .. id .. '" class="ig-text"' .. style .. '>' .. esc(content) .. '</span>')
        bind(id, 'text', content)
    end

    function api.ProgressBar(frac, a, b, c)
        local pct = math.floor(((tonumber(frac) or 0) * 100) + 0.5)
        if pct < 0 then pct = 0 end
        if pct > 100 then pct = 100 end
        local overlay
        if type(a) == 'string' then overlay = a
        elseif type(b) == 'string' then overlay = b
        elseif type(c) == 'string' then overlay = c
        end
        local cap = overlay or (tostring(pct) .. '%')
        local fill = node_id()
        local cap_id = node_id()
        local col = style_color('PlotHistogram')
        local extra = col and (';background-color:' .. hex_color(col)) or ''
        emit('<div class="ig-bar"><div id="' .. fill .. '" class="ig-barfill" style="width:' .. pct .. '%' .. extra .. ';"></div></div><span id="' .. cap_id .. '" class="ig-text">' .. esc(cap) .. '</span>')
        bind(fill, 'width', tostring(pct) .. '%')
        bind(cap_id, 'text', cap)
    end

    function api.Text(text, ...)
        text_span(fmt(text, ...), style_color('Text'))
    end
    function api.TextUnformatted(text) api.Text(text) end
    function api.TextWrapped(text, ...) api.Text(text, ...) end
    function api.TextColored(a, b, c, d, e, ...)
        local col, text, more
        if type(a) == 'number' and type(b) == 'number' and type(c) == 'number' then
            col = { r = a, g = b, b = c, a = d or 1 }
            text = e
            more = { ... }
        else
            if type(a) == 'table' or type(a) == 'userdata' then
                col = { r = a.x or a.r or 1, g = a.y or a.g or 1, b = a.z or a.b or 1, a = a.w or a.a or 1 }
            end
            text = b
            more = { c, d, e, ... }
        end
        local args = {}
        for i = 1, #more do
            if more[i] ~= nil then args[#args + 1] = more[i] end
        end
        text_span(fmt(text, unpack(args)), col or style_color('Text'))
    end
    function api.TextDisabled(text, ...) api.Text(text, ...) end
    function api.LabelText(label, text, ...)
        api.Text(tostring(vis_label(label)) .. ' ' .. fmt(text, ...))
    end
    function api.BulletText(text, ...) api.Text('• ' .. fmt(text, ...)) end
    function api.Separator()
        close_line()
        raw('<div class="ig-sep"></div>')
    end
    function api.SameLine() S.same = true end
    function api.NewLine() close_line() end
    function api.Spacing() end
    function api.Dummy() end
    function api.Indent() end
    function api.Unindent() end

    function api.BeginTable(id, cols)
        close_line()
        raw('<div class="ig-table">')
        S.stack[#S.stack + 1] = {
            kind = 'table', cols = tonumber(cols) or 1, col = 0, row = false, in_cell = false, heads = {}, meta = {},
        }
        return true
    end

    function table_top()
        for i = #S.stack, 1, -1 do
            local t = S.stack[i]
            if type(t) == 'table' and t.kind == 'table' then return t end
        end
    end

    local function close_cell(t)
        if t.in_cell then
            raw('</div>')
            t.in_cell = false
        end
    end

    function api.EndTable()
        local t = table_top()
        if not t then return end
        close_cell(t)
        if t.row then raw('</div>') end
        for i = #S.stack, 1, -1 do
            if S.stack[i] == t then
                table.remove(S.stack, i)
                break
            end
        end
        raw('</div>')
    end

    local function cell_tag(t, index)
        local meta = t.meta and t.meta[index]
        local style
        if meta and meta.fixed and meta.width then
            local w = math.floor(meta.width)
            style = 'flex:0 0 ' .. w .. 'dp;min-width:' .. w .. 'dp;'
        else
            local grow = 1
            if meta and meta.width and meta.width > 0 and meta.width < 20 then grow = meta.width end
            style = 'flex:' .. tostring(grow) .. ';'
        end
        return '<div class="ig-cell" style="' .. style .. '">'
    end

    function api.TableSetupColumn(name, _, width)
        local t = table_top()
        if not t then return end
        local label = vis_label(name)
        t.heads[#t.heads + 1] = label
        local w = tonumber(width)
        t.meta[#t.heads] = { width = w, fixed = w ~= nil and w >= 20 }
    end

    function api.TableHeadersRow()
        local t = table_top()
        if not t or #t.heads == 0 then return end
        close_cell(t)
        if t.row then raw('</div>') end
        raw('<div class="ig-trow">')
        for i = 1, #t.heads do
            local id = node_id()
            local head = t.heads[i]
            local cls = 'ig-hdr'
            if tostring(head):find('[\128-\255]') then cls = cls .. ' ig-ico' end
            raw(cell_tag(t, i) .. '<span id="' .. id .. '" class="' .. cls .. '">' .. esc(head) .. '</span></div>')
            bind(id, 'text', head)
        end
        raw('</div>')
        t.row = false
        t.col = 0
    end

    function api.TableNextRow()
        local t = table_top()
        if not t then return end
        close_cell(t)
        if t.row then raw('</div>') end
        raw('<div class="ig-trow">')
        t.row = true
        t.col = 0
    end

    local function open_cell(t, index)
        if not t.row then
            raw('<div class="ig-trow">')
            t.row = true
            t.col = 0
        end
        close_cell(t)
        while t.col + 1 < index do
            t.col = t.col + 1
            raw(cell_tag(t, t.col) .. '</div>')
        end
        t.col = index
        raw(cell_tag(t, index))
        t.in_cell = true
    end

    function api.TableNextColumn()
        local t = table_top()
        if not t then return true end
        local next_col = t.col + 1
        if t.row and t.cols > 0 and next_col > t.cols then
            close_cell(t)
            raw('</div><div class="ig-trow">')
            t.col = 0
            next_col = 1
        end
        open_cell(t, next_col)
        return true
    end

    function api.TableSetColumnIndex(index)
        local t = table_top()
        if not t then return false end
        open_cell(t, (tonumber(index) or 0) + 1)
        return true
    end
    function api.TableSetupScrollFreeze() end

    function api.PushID(id) S.path[#S.path + 1] = tostring(id) end
    function api.PopID() S.path[#S.path] = nil end
    function api.BeginGroup() return true end
    function api.EndGroup() end
    function api.BeginDisabled() end
    function api.EndDisabled() end
    function api.PushStyleColor(col, r, g, b, a)
        local entry
        if type(r) == 'table' or type(r) == 'userdata' then
            entry = { col = col, r = r.x or r.r or 1, g = r.y or r.g or 1, b = r.z or r.b or 1, a = r.w or r.a or 1 }
        else
            entry = { col = col, r = r or 1, g = g or 1, b = b or 1, a = a or 1 }
        end
        S.colors[#S.colors + 1] = entry
    end

    function api.PopStyleColor(n)
        n = tonumber(n) or 1
        for _ = 1, n do
            S.colors[#S.colors] = nil
        end
    end
    function api.PushStyleVar() end
    function api.PopStyleVar() end
    function api.PushFont() end
    function api.PopFont() end
    function api.PushItemWidth() end
    function api.PopItemWidth() end
    function api.AlignTextToFramePadding() end
    function api.SetNextWindowSize() end
    function api.SetNextWindowPos() end
    function api.SetNextWindowCollapsed() end
    function api.SetNextItemWidth() end
    function api.SetCursorPos() end
    function api.SetCursorPosX() end
    function api.SetCursorPosY() end
    function api.SetTooltip() end
    function api.BeginTooltip() return false end
    function api.EndTooltip() end
    function api.BeginPopup() return false end
    function api.BeginPopupContextItem() return false end
    function api.BeginPopupModal() return false end
    function api.EndPopup() end
    function api.OpenPopup() end
    function api.CloseCurrentPopup() end
    function api.IsItemHovered() return false end
    function api.IsItemClicked() return false end
    function api.IsItemActive() return false end
    function api.IsWindowAppearing() return false end
    function api.IsWindowFocused() return true end
    function api.IsWindowHovered() return false end
    function api.IsAnyItemActive() return false end
    function api.IsMouseClicked() return false end
    function api.IsMouseDown() return false end

    function api.GetWindowWidth() return 640 end
    function api.GetWindowHeight() return 480 end
    function api.GetContentRegionAvail() return 640, 400 end
    function api.GetContentRegionAvailVec() return vec(640, 400) end
    function api.GetCursorPos() return 0, 0 end
    function api.GetCursorPosX() return 0 end
    function api.GetCursorPosY() return 0 end
    function api.GetCursorPosVec() return vec(0, 0) end
    function api.GetCursorScreenPos() return 0, 0 end
    function api.GetCursorScreenPosVec() return vec(0, 0) end
    function api.GetMousePosVec() return vec(-10000, -10000) end
    function api.GetItemRectMin() return 0, 0 end
    function api.GetItemRectMax() return 200, 16 end
    function api.GetItemRectMinVec() return vec(0, 0) end
    function api.GetItemRectMaxVec() return vec(200, 16) end
    function api.GetTextLineHeight() return 16 end
    function api.GetTextLineHeightWithSpacing() return 18 end
    function api.GetFontSize() return 14 end
    function api.GetFrameHeight() return 22 end
    function api.GetScrollY() return 0 end
    function api.GetScrollMaxY() return 0 end
    function api.GetStyleColorVec4()
        return { x = 0.45, y = 0.14, z = 0.12, w = 1 }
    end

    function api.CalcTextSize(text) return #(tostring(text or '')) * 7, 16 end
    function api.CalcTextSizeVec(text) return vec(#(tostring(text or '')) * 7, 16) end
    function api.GetFont() return {} end
    function api.GetTime() return os.clock() end

    local function pack_u32(r, g, b, a)
        r = math.max(0, math.min(255, channel(r)))
        g = math.max(0, math.min(255, channel(g)))
        b = math.max(0, math.min(255, channel(b)))
        a = math.max(0, math.min(255, channel(a)))
        if type(IM_COL32) == 'function' then
            local ok, n = pcall(IM_COL32, r, g, b, a)
            if ok and type(n) == 'number' then return n end
        end
        return r + g * 256 + b * 65536 + a * 16777216
    end

    function api.GetColorU32(c, g, b, a)
        if type(c) == 'number' and g ~= nil then
            return pack_u32(c, g, b, a or 1)
        end
        if type(c) == 'table' or type(c) == 'userdata' then
            return pack_u32(c.x or c.r or 1, c.y or c.g or 1, c.z or c.b or 1, c.w or c.a or 1)
        end
        if type(c) == 'number' then return c end
        return 0xFFFFFFFF
    end

    function api.ColorConvertFloat4ToU32(r, g, b, a)
        if type(r) == 'table' or type(r) == 'userdata' then
            return api.GetColorU32(r)
        end
        return api.GetColorU32(r or 1, g or 1, b or 1, a or 1)
    end

    function api.GetIO()
        return {
            Framerate = 60,
            ConfigFlags = 0,
            MousePos = vec(0, 0),
            DeltaTime = 0.016,
            DisplaySize = vec(1920, 1080),
        }
    end
    function api.GetStyle()
        return setmetatable({
            Alpha = 1,
            ItemSpacing = vec(8, 4),
            FramePadding = vec(4, 3),
            WindowPadding = vec(8, 8),
            IndentSpacing = 12,
            Colors = setmetatable({}, { __index = function() return vec(1, 1, 1, 1) end }),
        }, { __index = function() return vec(4, 4) end })
    end

    local drawlist = setmetatable({}, { __index = function() return function() end end })
    function api.GetWindowDrawList() return drawlist end
    function api.GetForegroundDrawList() return drawlist end
    function api.GetBackgroundDrawList() return drawlist end

    function api.Image() end
    function api.ImageButton() return false end

    local function finish()
        close_line()
        while #S.stack > 0 do
            local k = S.stack[#S.stack]
            S.stack[#S.stack] = nil
            if k == 'win' or k == 'child' then raw('</div>') end
            if type(k) == 'table' and k.kind == 'table' then
                if k.in_cell then raw('</div>') end
                if k.row then raw('</div>') end
                raw('</div>')
            elseif type(k) == 'table' and k.kind == 'tabbar' then
                S.capture = k.parent
                raw('<div class="ig-tabs">' .. table.concat(k.buttons) .. '</div>' .. table.concat(k.body))
            end
        end
        return table.concat(S.parts)
    end

    local missed = {}
    return setmetatable(api, {
        __index = function(_, key)
            if key == '_finish' then return finish end
            if not missed[key] then
                missed[key] = true
                print('[autoport] ImGui.' .. tostring(key) .. ' has no Rml equivalent; call ignored')
            end
            return function() return false end
        end,
    }), finish
end

local function implot_shim(emit_text)
    local P = {}
    function P.BeginPlot(title)
        emit_text(tostring(title or 'Plot'))
        return true
    end
    function P.EndPlot() end
    function P.PlotLine(name) emit_text(tostring(name or '')) end
    function P.SetupAxes() end
    function P.SetupAxisLimits() end
    return setmetatable(P, { __index = function() return function() return false end end })
end

function M.run(orig_rel, opts)
    opts = opts or {}
    orig_rel = tostring(orig_rel or ''):gsub('\\', '/')
    local root = tostring(mq.luaDir or ''):gsub('\\', '/')
    local full = root .. '/' .. orig_rel
    local dir = full:match('^(.*)/[^/]+$') or root
    local title = tostring(opts.title or orig_rel)

    local win, err = host.open('APLive_' .. title:gsub('[^%w]', ''), 'rmlui/live.rml', {
        width = 1100,
        height = 820,
        theme = 'redguides',
        title = title,
        reload = true,
    })
    if not win then
        print('[autoport] live UI failed: ' .. tostring(err))
        return
    end
    pcall(function() win:text('window-title', title) end)
    pcall(function() win:place(80, 40, 1100, 820) end)

    pcall(require, 'ImGui')
    local frame_api, finish = new_frame()
    reset_frame()

    package.loaded['ImGui'] = frame_api
    package.preload['ImGui'] = function() return frame_api end
    _G.ImGui = frame_api
    local real_require = require
    require = function(name, ...)
        if name == 'ImGui' then return frame_api end
        return real_require(name, ...)
    end
    local plot = implot_shim(function(s)
        if frame_api and frame_api.Text then frame_api.Text(s) end
    end)
    package.loaded['ImPlot'] = plot
    package.preload['ImPlot'] = function() return plot end

    if ImHashStr == nil then
        ImHashStr = function(s) return tostring(s) end
    end

    local function enum_table()
        return setmetatable({}, { __index = function() return 0 end })
    end

    local function anim_color(n)
        return setmetatable({ n = n or 0xFFFFFFFF }, {
            __index = function(_, key)
                if key == 'ToImU32' then
                    return function(self) return self.n end
                end
                return function() return 0 end
            end,
        })
    end

    local function anim_instance()
        return setmetatable({}, {
            __index = function(_, key)
                if key == 'Valid' then return function() return false end end
                if key == 'GetFloat' then return function() return 0 end end
                return function() return 0 end
            end,
        })
    end

    local anim = {
        TweenFloat = function(_, _, target, _, _, _, _, fallback)
            if type(target) == 'number' then return target end
            if type(fallback) == 'number' then return fallback end
            return 0
        end,
        TweenColor = function(_, _, color)
            if type(color) == 'table' or type(color) == 'userdata' then
                return { x = color.x or 1, y = color.y or 1, z = color.z or 1, w = color.w or 1 }
            end
            return { x = 1, y = 1, z = 1, w = 1 }
        end,
        EasePreset = function() return 0 end,
        EvalPreset = function(_, t) return tonumber(t) or 0 end,
        Oscillate = function(_, a) return tonumber(a) or 0 end,
        OscillateVec2 = function() return vec(0, 0) end,
        GetBlendedColor = function() return anim_color(0xFFFFFFFF) end,
        GetInstance = function() return anim_instance() end,
        PlayStagger = function() end,
    }
    setmetatable(anim, {
        __index = function() return function() return 0 end end,
    })
    package.loaded['ImAnim'] = anim
    package.preload['ImAnim'] = function() return anim end
    ImAnim = anim

    local clip_chain
    clip_chain = setmetatable({}, { __index = function() return function() return clip_chain end end })
    IamClip = setmetatable({}, { __index = function() return function() return clip_chain end end })
    if type(IamEaseType) ~= 'table' then IamEaseType = enum_table() end
    if type(IamPolicy) ~= 'table' then IamPolicy = enum_table() end
    if type(IamColorSpace) ~= 'table' then IamColorSpace = enum_table() end
    if type(IamDirection) ~= 'table' then IamDirection = enum_table() end
    if type(IamWaveType) ~= 'table' then IamWaveType = enum_table() end

    local draws = {}
    local real_init = mq.imgui.init
    mq.imgui.init = function(_, fn)
        if type(fn) == 'function' then draws[#draws + 1] = fn end
    end

    local last_err = ''
    local last_sk, pushed = nil, {}

    local function skeleton_of(html)
        html = html:gsub('value="[^"]*"', 'value=""')
        html = html:gsub('>([^<]-)</span>', '></span>')
        html = html:gsub('>([^<]-)</button>', '></button>')
        html = html:gsub('width:%s*[%d%.]+%%', 'width:0%')
        html = html:gsub('%schecked([/>])', '%1')
        return html
    end

    local function pump()
        if not win:is_open() then return end
        host.tick(win, {
            close = function()
                pcall(function() win:show(false) end)
            end,
            action = function(a)
                if type(a) == 'string' and a:sub(1, 1) == 'i' then clicks[a] = true end
            end,
            change = function(ev)
                if type(ev) == 'table' and ev.id and ev.id ~= '' then
                    changes[ev.id] = ev.value or ''
                end
            end,
        })
        reset_frame()
        for i = 1, #draws do
            local ok, e = pcall(draws[i])
            if not ok and e ~= last_err then
                last_err = tostring(e)
                print('[autoport] ui: ' .. last_err)
            end
        end
        local html = finish()
        if last_err ~= '' then
            html = '<div class="ig-note">' .. esc(last_err) .. '</div>' .. html
        end
        if html == '' then
            html = '<div class="ig-note">Waiting for the script UI. Draws registered: '
                .. tostring(#draws) .. '.</div>'
        end
        local sk = skeleton_of(html)
        if sk == last_sk then
            for i = 1, #S.binds do
                local b = S.binds[i]
                if pushed[b.id] ~= b.value then
                    if b.kind == 'text' then
                        pcall(function() win:text(b.id, b.value) end)
                    elseif b.kind == 'value' then
                        pcall(function() win:set_value(b.id, b.value) end)
                    elseif b.kind == 'width' then
                        pcall(function() win:style(b.id, 'width', b.value) end)
                    elseif b.kind == 'checked' then
                        if b.value == '1' then
                            pcall(function() win:attr(b.id, 'checked', 'checked') end)
                        else
                            pcall(function() win:attr(b.id, 'checked', nil) end)
                        end
                    end
                    pushed[b.id] = b.value
                end
            end
        else
            pcall(function() win:rml('page', html) end)
            last_sk = sk
            pushed = {}
            for i = 1, #S.binds do
                pushed[S.binds[i].id] = S.binds[i].value
            end
        end
        local st = 'Live · ' .. title
        if last_err ~= '' then st = 'Error · ' .. last_err:sub(1, 180) end
        pcall(function() win:text('status', st) end)
        clicks = {}
        changes = {}
    end

    real_init('APLive_' .. title:gsub('[^%w]', ''), function()
        local ok, e = pcall(pump)
        if not ok then print('[autoport] live tick: ' .. tostring(e)) end
    end)

    package.path = dir .. '/?.lua;' .. dir .. '/?/init.lua;' .. package.path

    print('[autoport] live port · ' .. orig_rel)
    print('[autoport] stop the classic script first, or this runs a second copy: /lua stop ' .. (orig_rel:match('^([^/]+)') or orig_rel))
    print('[autoport] stop this port: /lua stop ports/' .. (orig_rel:match('^([^/]+)') or 'tool'))

    local chunk, lerr = loadfile(full)
    if not chunk then
        print('[autoport] load failed: ' .. tostring(lerr))
        return
    end
    local ok, rerr = pcall(chunk)
    _G.ImGui = frame_api
    if not ok then
        print('[autoport] script error: ' .. tostring(rerr))
    end
end

return M
