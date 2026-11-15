--[[ AutoPort v4 — emit azure-chrome RML + rml_ui.lua (host.open / host.tick).

  RmlUi host rules baked into every emit (Lua Console crash lessons):
  - Toggle / flex-row labels in <span> (anonymous text is dropped).
  - Never color:inherit / border-radius:inherit (RCSS parse error).
  - Never font-family: Consolas — use Segoe UI (plugin loads that face).
  - Never <textarea> — MQ2RmlUi hard-crashes on click; InputTextMultiline → <input>.
  - Never display:none around input widgets; .tab-host parks panels off-screen.
  - SetInnerRML only when HTML actually changes (rml_if).
]]
local M = {}

local AUTO_PORT_VER = 16

-- Shared RCSS for tab/window switchers. Must beat tool.rcss `.tab-panel { display: none }`.
local HOST_CSS = {
    '.tab-host { position: relative; flex: 1; min-height: 180dp; min-width: 0; overflow: hidden; }',
    '.tab-host > .tab-panel { display: flex; flex-direction: column; gap: 8dp; position: absolute; top: 0; left: -12000dp; width: 100%; height: 100%; overflow: auto; z-index: 0; pointer-events: none; }',
    '.tab-host > .tab-panel.on { left: 0; z-index: 1; pointer-events: auto; }',
    '.mod-host, .mtab-host { position: relative; flex: 1; min-height: 120dp; min-width: 0; overflow: hidden; }',
    '.mod-host > .mod-win, .mtab-host > .mtab-body { display: flex; flex-direction: column; gap: 8dp; position: absolute; top: 0; left: -12000dp; width: 100%; height: 100%; overflow: auto; z-index: 0; pointer-events: none; }',
    '.mod-host > .mod-win.on, .mtab-host > .mtab-body.on { left: 0; z-index: 1; pointer-events: auto; }',
}

local function esc(s)
    return tostring(s or '')
        :gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'):gsub('"', '&quot;')
end

local function slug(s)
    s = tostring(s or 'x'):lower():gsub('[^a-z0-9]+', '_'):gsub('^_+', ''):gsub('_+$', '')
    return (s ~= '' and s) or 'x'
end

local function take(list, n)
    local out = {}
    for i = 1, math.min(n or 8, #(list or {})) do out[i] = list[i] end
    return out
end

local function gather_flat(model)
    local buttons, checks, inputs, sections, menus, selectables, combos = {}, {}, {}, {}, {}, {}, {}
    local function merge(dst, src, lim)
        for i = 1, #(src or {}) do
            if #dst >= (lim or 80) then return end
            dst[#dst + 1] = src[i]
        end
    end
    for wi = 1, #(model.windows or {}) do
        local w = model.windows[wi]
        merge(buttons, w.buttons); merge(checks, w.checks); merge(inputs, w.inputs)
        merge(sections, w.sections); merge(menus, w.menus); merge(selectables, w.selectables)
        merge(combos, w.combos)
        for ti = 1, #(w.tabs or {}) do
            local t = w.tabs[ti]
            merge(buttons, t.buttons); merge(checks, t.checks); merge(inputs, t.inputs)
            merge(sections, t.sections); merge(selectables, t.selectables); merge(combos, t.combos)
            for si = 1, #(t.sections or {}) do
                local s = t.sections[si]
                merge(buttons, s.buttons); merge(checks, s.checks); merge(inputs, s.inputs)
                merge(selectables, s.selectables)
            end
        end
    end
    return {
        buttons = buttons, checks = checks, inputs = inputs, sections = sections,
        menus = menus, selectables = selectables, combos = combos,
    }
end

local function render_controls(parts, bucket, wid, prefix, indent)
    indent = indent or '\t\t\t'
    prefix = prefix or tostring(wid)

    if bucket.buttons and #bucket.buttons > 0 then
        parts[#parts + 1] = indent .. '<div class="row">\n'
        for i = 1, #bucket.buttons do
            local b = bucket.buttons[i]
            local primary = (i == 1) and ' primary' or ''
            local inner = esc(b.label)
            if b.glyph then inner = '<span class="ico">' .. b.glyph .. '</span>' .. inner end
            parts[#parts + 1] = string.format(
                '%s\t<div class="btn%s" action="btn:%s:%d">%s</div>\n',
                indent, primary, prefix, i, inner)
        end
        parts[#parts + 1] = indent .. '</div>\n'
    end

    if bucket.checks and #bucket.checks > 0 then
        parts[#parts + 1] = indent .. '<div class="row">\n'
        for i = 1, #bucket.checks do
            local c = bucket.checks[i]
            parts[#parts + 1] = string.format(
                '%s\t<div id="chk_%s_%d" class="toggle" action="chk:%s:%d"><div class="sw"><div class="knob"></div></div><span>%s</span></div>\n',
                indent, prefix:gsub('%W', '_'), i, prefix, i, esc(c.label or c))
        end
        parts[#parts + 1] = indent .. '</div>\n'
    end

    if bucket.combos and #bucket.combos > 0 then
        for i = 1, #bucket.combos do
            local c = bucket.combos[i]
            parts[#parts + 1] = string.format(
                '%s<div class="row"><div class="kv-k">%s</div><div class="text-btn" action="combo:%s:%d">Select...</div></div>\n',
                indent, esc(c.label or c), prefix, i)
        end
    end

    for i = 1, #(bucket.inputs or {}) do
        local inp = bucket.inputs[i]
        local iid = string.format('in_%s_%d', prefix:gsub('%W', '_'), i)
        -- Never emit <textarea>: MQ2RmlUi crashes on click (Lua Console snippets).
        parts[#parts + 1] = string.format(
            '%s<div class="row"><span class="hint">%s</span><input id="%s" class="text" type="text" name="%s"/></div>\n',
            indent, esc(inp.label or inp), iid, iid)
        if inp.multiline then
            parts[#parts + 1] = indent
                .. '<div class="hint">ImGui multiline → single-line field (native textarea crashes the client).</div>\n'
        end
    end

    if bucket.selectables and #bucket.selectables > 0 then
        parts[#parts + 1] = indent .. '<div class="col">\n'
        for i = 1, math.min(#bucket.selectables, 24) do
            local s = bucket.selectables[i]
            parts[#parts + 1] = string.format(
                '%s\t<div class="item" action="sel:%s:%d">%s</div>\n',
                indent, prefix, i, esc(s.label or s))
        end
        parts[#parts + 1] = indent .. '</div>\n'
    end

    for i = 1, #(bucket.sections or {}) do
        local sec = bucket.sections[i]
        local sid = slug(sec.label or ('s' .. i))
        parts[#parts + 1] = string.format(
            '%s<div id="sec_%s" class="panel"><div class="panel-head" action="sec:%s">%s</div><div class="panel-body">\n',
            indent, sid, sid, esc(sec.label or 'Section'))
        render_controls(parts, sec, wid, prefix .. 's' .. i, indent .. '\t')
        parts[#parts + 1] = indent .. '</div></div>\n'
    end
end

--- One collapsible section panel (used by shape A).
local function section_html(sec, wid, prefix, indent)
    sec = sec or {}
    wid = wid or 1
    prefix = prefix or 'sec'
    indent = indent or '\t\t\t\t'
    local parts = {}
    local sid = slug(sec.label or 'section')
    parts[#parts + 1] = string.format(
        '%s<div id="sec_%s" class="section"><div class="section-head" action="sec:%s">'
        .. '<span class="section-caret">&#xE70D;</span><span>%s</span></div><div class="section-body">\n',
        indent, sid, sid, esc(sec.label or 'Section'))
    render_controls(parts, {
        buttons = sec.buttons, checks = sec.checks, inputs = sec.inputs,
        selectables = sec.selectables, combos = sec.combos, sections = {},
    }, wid, prefix .. '_' .. sid, indent .. '\t')
    parts[#parts + 1] = indent .. '</div></div>\n'
    return table.concat(parts)
end

local function theme_href_for(rml_rel)
    -- Count directories between lua/ and the .rml file so nested packages
    -- (EZQuests-main/EZQuests-main/ui) get ../../../ and grouper/ui gets ../../.
    rml_rel = tostring(rml_rel or 'ports/x/ui/main.rml'):gsub('\\', '/')
    local dir = rml_rel:match('^(.+)/[^/]+$') or 'ports/x/ui'
    local n = 0
    for _ in dir:gmatch('[^/]+') do n = n + 1 end
    if n < 2 then n = 2 end
    return string.rep('../', n) .. 'rmlui/theme'
end

local current_theme_href = '../../../rmlui/theme'

local function head(title, extra_head)
    local href = current_theme_href
    local parts = {
        '<rml>\n<head>\n\t<title>', esc(title), '</title>\n',
        '\t<link type="text/template" href="', href, '/window.rml"/>\n',
        '\t<link type="text/rcss" href="', href, '/tool.rcss"/>\n',
    }
    if extra_head and extra_head ~= '' then
        parts[#parts + 1] = extra_head
        if extra_head:sub(-1) ~= '\n' then parts[#parts + 1] = '\n' end
    end
    parts[#parts + 1] = '</head>\n<body template="window">\n'
    return table.concat(parts)
end

local EQ_ICON_CSS = {
    '.eq-icon, .item-icon { width: 28dp; height: 28dp; flex: 0 0 auto; pointer-events: none; border-radius: 6dp; background-color: #ffffff10; }',
    '.eq-icon.missing, .item-icon.missing { background-color: #ffffff14; }',
}

local function style_block(css_lines, with_item_icons)
    local parts = { '\t<style>\n' }
    for i = 1, #HOST_CSS do
        parts[#parts + 1] = '\t\t' .. HOST_CSS[i] .. '\n'
    end
    for i = 1, #(css_lines or {}) do
        parts[#parts + 1] = '\t\t' .. css_lines[i] .. '\n'
    end
    -- Always include EQ item-icon plates. Icons.FA_* is a font; Item.Icon is A_DragItem.
    if with_item_icons ~= false then
        for i = 1, #EQ_ICON_CSS do
            parts[#parts + 1] = '\t\t' .. EQ_ICON_CSS[i] .. '\n'
        end
    end
    parts[#parts + 1] = '\t</style>\n'
    return table.concat(parts)
end

local function hero(title, shape, extra_chips)
    local chips = {
        '<span class="chip">ported</span>',
        '<span class="chip ghost">AutoPort v', tostring(AUTO_PORT_VER), '</span>',
        '<span class="chip ghost">shape ', esc(shape), '</span>',
    }
    if extra_chips then
        for i = 1, #extra_chips do chips[#chips + 1] = extra_chips[i] end
    end
    return table.concat({
        '\t<div class="hero">\n',
        '\t\t<div class="hero-card">\n',
        '\t\t\t<div class="eyebrow">Rml port</div>\n',
        '\t\t\t<div id="title" class="hero-title">', esc(title), '</div>\n',
        '\t\t\t<div class="hero-sub">Structure port · tabs · sections · icons · RedGuides</div>\n',
        '\t\t\t<div class="hero-meta">', table.concat(chips), '</div>\n',
        '\t\t</div>\n',
        '\t</div>\n',
    })
end

--- Built into every AutoPort window: labeled see-through toggle (titlebar also has ui:glass).
local function glass_bar()
    return table.concat({
        '\t<div class="toolbar glass-bar">\n',
        '\t\t<div class="spacer"></div>\n',
        '\t\t<div id="btn_glass" class="toggle" action="ui:glass" title="See-through window">\n',
        '\t\t\t<div class="sw"><div class="knob"></div></div><span>See-through</span>\n',
        '\t\t</div>\n',
        '\t</div>\n',
    })
end

local function build_nav(model, title)
    local nav = {}
    local disc = model.discovered or {}
    if disc.data_lines and #disc.data_lines > 0 then
        for i = 1, #disc.data_lines do
            local block = disc.data_lines[i]
            local name = (block.file or ''):match('data_([%w_]+)%.lua$') or ('chapter_' .. i)
            local label = name:gsub('_', ' '):gsub('(%a)([%w ]*)', function(a, b)
                return a:upper() .. b
            end)
            nav[#nav + 1] = {
                id = slug(name),
                label = label,
                lines = block.lines or { label },
            }
        end
    end
    local flat = gather_flat(model)
    if #nav == 0 then
        for i = 1, math.min(40, #flat.selectables) do
            local L = flat.selectables[i].label or flat.selectables[i]
            nav[#nav + 1] = { id = slug(L), label = L, lines = { L } }
        end
    end
    if #nav == 0 then
        for i = 1, math.min(20, #flat.sections) do
            local L = flat.sections[i].label or ('Section ' .. i)
            nav[#nav + 1] = { id = slug(L), label = L, lines = { 'Content for ' .. L .. ' -- wire api.getPageForRml / api.navGroups.' } }
        end
    end
    if #nav == 0 then
        nav[1] = {
            id = 'overview',
            label = 'Overview',
            lines = {
                title .. ' uses a sidebar + document layout.',
                'AutoPort detected a content-style UI (sidebar / content.lua / data_*).',
                'Provide api.getPageForRml(id) or api.navGroups() from the host script for live pages.',
                'This scaffold is intentional -- Apply never ships an empty body.',
            },
        }
    end
    model._nav = nav
    return nav
end

--- Shape A: tabbed chrome — for complex tools uses PRIMARY window tabs only (opaque).
local function emit_rml_A(model, title)
    local wins = model.windows or {}
    if #wins == 0 then wins = { { title = title, tabs = {}, menus = {}, buttons = {}, checks = {}, inputs = {}, sections = {} } } end
    -- Complex: one chrome window = richest tab set (already sorted by analyze)
    local use = model.complex and { wins[1] } or wins
    local parts = {
        head(title, style_block({
            '#window-content { background-color: #0a0a0c; }',
            '.panel, .tab-panel, .section, .hero-card { background-color: #121214; }',
            '.live-box { min-height: 120dp; padding: 8dp; color: #c9b27a; background-color: #0a0a0c; border: 1dp #f0b42922; border-radius: 8dp; margin-top: 8dp; }',
            '.live-line { color: #f5e6b8; margin-bottom: 4dp; }',
        })),
        hero(title, model.complex and 'A*' or 'A', model.complex and { '<span class="chip ghost">complex</span>' } or nil),
        glass_bar(),
    }

    for w = 1, #use do
        local win = use[w]
        parts[#parts + 1] = '\t<div class="panel ap-win">\n'
        parts[#parts + 1] = '\t\t<div class="panel-head">' .. esc(win.title or title) .. '</div>\n'
        parts[#parts + 1] = '\t\t<div class="panel-body">\n'

        local tabs = win.tabs or {}
        if #tabs == 0 then
            tabs = { { label = 'Main', buttons = win.buttons, checks = win.checks, inputs = win.inputs, sections = win.sections } }
        end

        parts[#parts + 1] = '\t\t\t<div class="toolbar"><div class="seg" id="seg_' .. w .. '">\n'
        for i = 1, #tabs do
            local t = tabs[i]
            local inner = esc(t.label or ('Tab ' .. i))
            if t.glyph then inner = '<span class="ico">' .. t.glyph .. '</span> ' .. inner end
            parts[#parts + 1] = string.format(
                '\t\t\t\t<div id="tab_%d_%d" class="seg-item%s" action="tab:%d:%d">%s</div>\n',
                w, i, i == 1 and ' on' or '', w, i, inner)
        end
        parts[#parts + 1] = '\t\t\t</div></div>\n'
        parts[#parts + 1] = '\t\t\t<div class="tab-host">\n'

        for i = 1, #tabs do
            local t = tabs[i]
            parts[#parts + 1] = string.format(
                '\t\t\t<div id="panel_%d_%d" class="tab-panel%s">\n',
                w, i, i == 1 and ' on' or '')

            -- Cap clutter: max 6 sections, 10 buttons, 6 inputs per tab
            local secs = t.sections or {}
            local nsec = math.min(#secs, model.complex and 6 or 12)
            if nsec > 0 then
                for si = 1, nsec do
                    local sec = secs[si]
                    -- trim children
                    sec.buttons = take(sec.buttons, 8)
                    sec.checks = take(sec.checks, 6)
                    sec.inputs = take(sec.inputs, 4)
                    parts[#parts + 1] = section_html(sec)
                end
            else
                local slim = {
                    label = t.label or 'Panel',
                    buttons = take(t.buttons, 10),
                    checks = take(t.checks, 8),
                    inputs = take(t.inputs, 6),
                    selectables = take(t.selectables, 12),
                }
                local empty = #(slim.buttons) + #(slim.checks) + #(slim.inputs) + #(slim.selectables) == 0
                if empty then
                    parts[#parts + 1] = string.format(
                        '\t\t\t\t<div class="hint">%s — live content via api.refreshTab.</div>\n',
                        esc(t.label or ('Tab ' .. i)))
                else
                    parts[#parts + 1] = section_html(slim)
                end
            end
            parts[#parts + 1] = string.format(
                '\t\t\t\t<div class="live-box" id="live_%d_%d"><div class="live-line muted">Live panel</div></div>\n',
                w, i)
            parts[#parts + 1] = '\t\t\t</div>\n'
        end
        parts[#parts + 1] = '\t\t\t</div>\n'

        parts[#parts + 1] = '\t\t</div>\n\t</div>\n'
    end

    parts[#parts + 1] = '\t<div class="status"><span class="dot"></span><span id="status">Ready.</span></div>\n'
    parts[#parts + 1] = '</body>\n</rml>\n'
    return table.concat(parts)
end

--- Shape B: sidebar + document (wiki / content tools) — NEVER empty
local function emit_rml_B(model, title)
    local nav = build_nav(model, title)
    local flat = gather_flat(model)
    local parts = {
        head(title, style_block({
            '.wiki-split { flex: 1; display: flex; flex-direction: row; gap: 10dp; min-height: 0; overflow: hidden; }',
            '.wiki-nav { flex: 0 0 260dp; background-color: #121214; }',
            '.wiki-page { flex: 1; background-color: #121214; }',
            '.wiki-nav-body, .wiki-page-body { gap: 2dp; padding: 8dp; overflow-y: auto; background-color: #0a0a0c; }',
            '.nav-item { padding: 6dp 10dp; border-radius: 8dp; color: #f5e6b8; cursor: pointer; }',
            '.nav-item:hover { background-color: #1a1010; }',
            '.nav-item.on { background-color: #e619211c; border: 1dp #e6192166; color: #f5e6b8; }',
            '.doc-line { color: #c9b27a; margin-bottom: 6dp; line-height: 1.35; }',
        })),
        hero(title, 'B', { '<span class="chip ghost">sidebar+doc</span>' }),
        glass_bar(),
    }

    if #flat.buttons > 0 then
        parts[#parts + 1] = '\t<div class="toolbar">\n'
        for i = 1, math.min(8, #flat.buttons) do
            local b = flat.buttons[i]
            local inner = esc(b.label)
            if b.glyph then inner = '<span class="ico">' .. b.glyph .. '</span>' .. inner end
            parts[#parts + 1] = string.format('\t\t<div class="btn" action="btn:top:%d">%s</div>\n', i, inner)
        end
        parts[#parts + 1] = '\t\t<div class="spacer"></div>\n\t</div>\n'
    end

    parts[#parts + 1] = '\t<div class="wiki-split">\n'
    parts[#parts + 1] = '\t\t<div class="panel wiki-nav">\n'
    parts[#parts + 1] = '\t\t\t<div class="panel-head">Categories</div>\n'
    parts[#parts + 1] = '\t\t\t<div id="nav" class="panel-body wiki-nav-body">\n'
    for i = 1, #nav do
        parts[#parts + 1] = string.format(
            '\t\t\t\t<div class="nav-item%s" id="nav_%s" action="nav:%s">%s</div>\n',
            i == 1 and ' on' or '', esc(nav[i].id), esc(nav[i].id), esc(nav[i].label))
    end
    parts[#parts + 1] = '\t\t\t</div>\n\t\t</div>\n'
    parts[#parts + 1] = '\t\t<div class="panel wiki-page">\n'
    parts[#parts + 1] = '\t\t\t<div class="panel-head" id="page_title">' .. esc(nav[1].label) .. '</div>\n'
    parts[#parts + 1] = '\t\t\t<div id="page" class="panel-body wiki-page-body">\n'
    for i = 1, #(nav[1].lines or {}) do
        parts[#parts + 1] = '\t\t\t\t<div class="doc-line">' .. esc(nav[1].lines[i]) .. '</div>\n'
    end
    parts[#parts + 1] = '\t\t\t</div>\n\t\t</div>\n\t</div>\n'
    parts[#parts + 1] = '\t<div class="status"><span class="dot"></span><span id="status">Ready.</span></div>\n'
    parts[#parts + 1] = '</body>\n</rml>\n'
    return table.concat(parts)
end

--- Shape C: list + actions
local function emit_rml_C(model, title)
    local flat = gather_flat(model)
    local items = {}
    for i = 1, math.min(40, #flat.selectables) do
        items[#items + 1] = flat.selectables[i]
    end
    if #items == 0 then
        for i = 1, math.min(12, #flat.sections) do
            items[#items + 1] = { label = flat.sections[i].label }
        end
    end
    if #items == 0 then
        for i = 1, math.min(8, #flat.checks) do
            items[#items + 1] = { label = flat.checks[i].label or flat.checks[i] }
        end
    end
    if #items == 0 then
        items = { { label = 'Row 1' }, { label = 'Row 2' }, { label = 'Row 3' } }
    end
    model._list_seed = items

    local parts = { head(title), hero(title, 'C'), glass_bar() }
    parts[#parts + 1] = '\t<div class="toolbar">\n'
    if #flat.buttons > 0 then
        for i = 1, math.min(10, #flat.buttons) do
            local b = flat.buttons[i]
            local inner = esc(b.label)
            if b.glyph then inner = '<span class="ico">' .. b.glyph .. '</span>' .. inner end
            parts[#parts + 1] = string.format('\t\t<div class="btn%s" action="btn:top:%d">%s</div>\n', i == 1 and ' primary' or '', i, inner)
        end
    else
        parts[#parts + 1] = '\t\t<div class="btn primary" action="btn:top:1">Refresh</div>\n'
    end
    parts[#parts + 1] = '\t\t<div class="spacer"></div>\n\t</div>\n'

    parts[#parts + 1] = '\t<div class="wiki-split" style="flex:1;display:flex;gap:10dp;min-height:0;">\n'
    parts[#parts + 1] = '\t\t<div class="panel" style="flex:0 0 45%;background-color:#0c0f17;">\n'
    parts[#parts + 1] = '\t\t\t<div class="panel-head">List</div>\n'
    parts[#parts + 1] = '\t\t\t<div id="list" class="panel-body">\n'
    for i = 1, #items do
        local L = items[i].label or items[i]
        parts[#parts + 1] = string.format(
            '\t\t\t\t<div class="item%s" action="sel:list:%d">%s</div>\n',
            i == 1 and ' on' or '', i, esc(L))
    end
    parts[#parts + 1] = '\t\t\t</div>\n\t\t</div>\n'
    parts[#parts + 1] = '\t\t<div class="panel" style="flex:1;background-color:#0c0f17;">\n'
    parts[#parts + 1] = '\t\t\t<div class="panel-head" id="detail_title">Detail</div>\n'
    parts[#parts + 1] = '\t\t\t<div id="detail" class="panel-body">\n'
    if #flat.inputs > 0 or #flat.checks > 0 or #flat.sections > 0 then
        render_controls(parts, {
            inputs = flat.inputs, checks = flat.checks, sections = flat.sections, buttons = {},
        }, 1, 'd', '\t\t\t\t')
    else
        parts[#parts + 1] = '\t\t\t\t<div class="hint" id="detail_hint">Select a row. Live data via api.refreshList / api.action.</div>\n'
    end
    parts[#parts + 1] = '\t\t\t</div>\n\t\t</div>\n\t</div>\n'
    parts[#parts + 1] = '\t<div class="status"><span class="dot"></span><span id="status">Ready.</span></div>\n'
    parts[#parts + 1] = '</body>\n</rml>\n'
    return table.concat(parts)
end

--- Shape D: multi-window — window switcher + A or C body
local function emit_rml_D(model, title)
    local wins = model.windows or {}
    local has_tabs = false
    for i = 1, #wins do
        if #(wins[i].tabs or {}) > 0 then has_tabs = true; break end
    end
    local body = has_tabs and emit_rml_A(model, title) or emit_rml_C(model, title)
    if #wins < 2 then return body end

    local switch = { '\t<div class="toolbar" id="win_switch">\n' }
    for i = 1, #wins do
        switch[#switch + 1] = string.format(
            '\t\t<div id="winbtn_%d" class="seg-item%s" action="win:%d">%s</div>\n',
            i, i == 1 and ' on' or '', i, esc(wins[i].title or ('Window ' .. i)))
    end
    switch[#switch + 1] = '\t</div>\n'
    return body:gsub('(<div class="hero">)', table.concat(switch) .. '%1', 1)
end

--- Honest coverage FAIL UI — never a fake tabs/sidebar stub.
function M.emit_coverage(title, port_pack, classic_run, cov, report_text)
    title = title or 'Tool'
    port_pack = port_pack or ('ports/' .. (classic_run or 'tool'))
    current_theme_href = theme_href_for(port_pack .. '/ui/main.rml')
    classic_run = classic_run or 'tool'
    cov = cov or {}
    local st = cov.stats or {}
    local rows = {}
    local function add_row(cls, text)
        rows[#rows + 1] = string.format(
            '<div class="lc-line %s">%s</div>', cls or '', esc(text))
    end
    add_row('err', cov.reason or 'Coverage FAIL — template port refused')
    add_row('muted', string.format(
        'calls=%d portable=%d blocked=%d caution=%d arch=%d tab_depth=%d',
        st.imgui_calls or 0, st.portable or 0, st.blocked or 0,
        st.caution or 0, st.arch or 0, st.max_tab_depth or 0))
    for i = 1, math.min(12, #(cov.arch or {})) do
        local e = cov.arch[i]
        add_row('input', string.format('ARCH L%s  %s — %s', e.line > 0 and e.line or '?', e.call, e.why))
    end
    for i = 1, math.min(20, #(cov.blocked or {})) do
        local e = cov.blocked[i]
        add_row('err', string.format('L%d  %s — %s', e.line, e.call, e.why))
    end
    add_row('muted', 'Full report: ' .. port_pack .. '/COVERAGE.md')
    add_row('ok', 'Fix: port the view layer only (state stays). Do not template-scrape this file.')

    local rml = table.concat({
        head(title, style_block({
            '#window-content { background-color: #0a0a0c; }',
            '.panel { background-color: #121214; border: 1dp #f0b42933; }',
            '.hero-card { background-color: #1a1010; border: 1dp #e6192144; }',
            '.cov-log { font-family: Segoe UI; font-size: 11dp; padding: 8dp; overflow-y: auto; min-height: 280dp; max-height: 520dp; background-color: #0a0a0c; }',
            '.lc-line { color: #f5e6b8; margin-bottom: 3dp; }',
            '.lc-line.err { color: #ff6b6b; }',
            '.lc-line.ok { color: #5fe0b0; }',
            '.lc-line.input { color: #f0b429; }',
            '.lc-line.muted { color: #8d97ad; }',
        })),
        '\t<div class="hero"><div class="hero-card">\n',
        '\t\t<div class="eyebrow">AutoPort coverage</div>\n',
        '\t\t<div id="title" class="hero-title">', esc(title), '</div>\n',
        '\t\t<div class="hero-sub">FAIL — refused template stub</div>\n',
        '\t\t<div class="hero-meta"><span class="chip">coverage</span>',
        '<span class="chip ghost">view-model required</span></div>\n',
        '\t</div></div>\n',
        glass_bar(),
        '\t<div class="panel"><div class="panel-head">Unmapped / blocked</div>\n',
        '\t\t<div id="cov" class="panel-body cov-log">', table.concat(rows), '</div>\n',
        '\t</div>\n',
        '\t<div class="toolbar">\n',
        '\t\t<div class="btn primary" action="classic">Run classic</div>\n',
        '\t\t<div class="btn" action="close">Close</div>\n',
        '\t</div>\n',
        '\t<div class="status"><span class="dot"></span><span id="status">Coverage FAIL — no fake UI.</span></div>\n',
        '</body>\n</rml>\n',
    })

    local safe = (title:gsub('[^%w]', ''))
    if safe == '' then safe = 'Tool' end
    local win_name = 'AP_Cov_' .. safe
    local lua = table.concat({
        '-- AUTO_PORT_VER=', tostring(AUTO_PORT_VER), ' shape=COVERAGE\n',
        '-- Coverage FAIL — not a structure port. See COVERAGE.md\n',
        "local host = require('rmlui.host')\n",
        "local mq = require('mq')\n",
        'local M = { win = nil, glass = false }\n',
        'local CLASSIC = ', string.format('%q', classic_run), '\n\n',
        'function M.ensure()\n',
        '    if M.win and M.win:is_open() then return true end\n',
        "    local win, err = host.open('", win_name, "', '", port_pack, "/ui/main.rml', ",
        "{ width = 720, height = 640, theme = 'redguides', title = '", title:gsub("'", ''), "', reload = true, glass = M.glass })\n",
        "    if not win then print('[AutoPort] coverage UI failed: ' .. tostring(err)); return false end\n",
        "    win:text('window-title', '", title:gsub("'", ''), "')\n",
        "    win:class('body', 'pinned', false)\n",
        '    pcall(function() win:show(true) end)\n',
        '    pcall(function() win:place(160, 100, 720, 640) end)\n',
        '    M.win = win\n',
        '    return true\n',
        'end\n\n',
        'function M.close() if M.win then pcall(function() M.win:show(false) end) end end\n',
        'function M.show(v) if M.win then M.win:show(v ~= false) end end\n',
        'function M.hide_all() M.show(false) end\n\n',
        'function M.tick(api)\n',
        '    if not M.ensure() then return false end\n',
        '    host.tick(M.win, {\n',
        '        close = function() M.show(false) end,\n',
        '        action = function(a)\n',
        "            if a == 'classic' then mq.cmdf('/lua run %s', CLASSIC); M.show(false) end\n",
        "            if a == 'close' then M.show(false) end\n",
        '        end,\n',
        '        glass = function(on) M.glass = on end,\n',
        '        update = function() end,\n',
        '    })\n',
        '    return true\n',
        'end\n\n',
        'return M\n',
    })
    return rml, lua, 'COVERAGE', report_text
end

--- View-model scaffold: modules with nested ImGui windows + tabs (not empty shells).
--- modules: list of { id, label, windows={{title,tabs,buttons,checks,sections}}, cmds={} }
---   OR legacy string panel names.
--- opts: { coverage_ok, soft, host_cmd }
function M.emit_view_scaffold(title, port_pack, classic_run, modules, opts)
    title = title or 'Tool'
    port_pack = port_pack or ('ports/' .. (classic_run or 'tool'))
    current_theme_href = theme_href_for(port_pack .. '/ui/main.rml')
    classic_run = classic_run or 'tool'
    opts = opts or {}
    -- Normalize legacy string panels → modules
    if type(modules) ~= 'table' or #modules == 0 then
        modules = { { id = 'main', label = 'Main', windows = { { title = 'Main', tabs = {}, buttons = {}, checks = {}, sections = {} } }, cmds = {} } }
    elseif type(modules[1]) == 'string' then
        local norm = {}
        for i = 1, #modules do
            local name = modules[i]
            norm[i] = {
                id = tostring(name):lower():gsub('[^a-z0-9]+', '_'),
                label = name,
                windows = { { title = name, tabs = {}, buttons = {}, checks = {}, sections = {} } },
                cmds = {},
            }
        end
        modules = norm
    end

    local function lab_of(x)
        if type(x) == 'table' then return tostring(x.label or x.name or '') end
        return tostring(x or '')
    end
    local function emit_inputs(parts, bucket, prefix, indent)
        for ii = 1, #(bucket.inputs or {}) do
            local lab = lab_of(bucket.inputs[ii])
            if lab == '' then lab = 'Input ' .. ii end
            local iid = ('vin_%s_%d'):format(prefix:gsub('%W', '_'), ii)
            parts[#parts + 1] = string.format(
                '%s<div class="row"><span class="hint">%s</span><input id="%s" class="text" type="text" name="%s"/></div>\n',
                indent, esc(lab), iid, iid)
        end
    end
    local function ctrl_html(win, mid, wi)
        local parts = {}
        local tabs = win.tabs or {}
        if #tabs > 0 then
            parts[#parts + 1] = '\t\t\t\t\t<div class="seg win-tabs" id="mtabs_' .. mid .. '_' .. wi .. '">\n'
            for ti = 1, #tabs do
                local tid = mid .. '_w' .. wi .. '_t' .. ti
                local on = ti == 1 and ' on' or ''
                parts[#parts + 1] = string.format(
                    '\t\t\t\t\t\t<div id="mtab_%s" class="seg-item%s" action="mtab:%s:%d:%d">%s</div>\n',
                    tid, on, mid, wi, ti, esc(tabs[ti].label or ('Tab ' .. ti)))
            end
            parts[#parts + 1] = '\t\t\t\t\t</div>\n'
            parts[#parts + 1] = '\t\t\t\t\t<div class="mtab-host">\n'
            for ti = 1, #tabs do
                local tid = mid .. '_w' .. wi .. '_t' .. ti
                local ton = ti == 1 and ' on' or ''
                local t = tabs[ti]
                parts[#parts + 1] = string.format(
                    '\t\t\t\t\t<div id="mbody_%s" class="mtab-body%s">\n', tid, ton)
                if #(t.sections or {}) > 0 then
                    for si = 1, #t.sections do
                        parts[#parts + 1] = string.format(
                            '\t\t\t\t\t\t<div class="section"><div class="section-head"><span>%s</span></div></div>\n',
                            esc(lab_of(t.sections[si])))
                    end
                end
                if #(t.buttons or {}) > 0 then
                    parts[#parts + 1] = '\t\t\t\t\t\t<div class="row wrap">\n'
                    for bi = 1, #t.buttons do
                        parts[#parts + 1] = string.format(
                            '\t\t\t\t\t\t\t<div class="btn ghost">%s</div>\n', esc(lab_of(t.buttons[bi])))
                    end
                    parts[#parts + 1] = '\t\t\t\t\t\t</div>\n'
                end
                if #(t.checks or {}) > 0 then
                    for ci = 1, #t.checks do
                        parts[#parts + 1] = string.format(
                            '\t\t\t\t\t\t<div class="check-row"><span class="check"></span><span>%s</span></div>\n',
                            esc(lab_of(t.checks[ci])))
                    end
                end
                emit_inputs(parts, t, mid .. '_w' .. wi .. '_t' .. ti, '\t\t\t\t\t\t')
                if #(t.sections or {}) == 0 and #(t.buttons or {}) == 0 and #(t.checks or {}) == 0
                    and #(t.inputs or {}) == 0 then
                    parts[#parts + 1] = string.format(
                        '\t\t\t\t\t\t<div class="hint">Tab <b>%s</b> — structure captured; bind live data or Classic.</div>\n',
                        esc(t.label or ''))
                end
                parts[#parts + 1] = '\t\t\t\t\t</div>\n'
            end
            parts[#parts + 1] = '\t\t\t\t\t</div>\n'
        else
            if #(win.sections or {}) > 0 then
                for si = 1, #win.sections do
                    parts[#parts + 1] = string.format(
                        '\t\t\t\t\t<div class="section"><div class="section-head"><span>%s</span></div></div>\n',
                        esc(lab_of(win.sections[si])))
                end
            end
            if #(win.buttons or {}) > 0 then
                parts[#parts + 1] = '\t\t\t\t\t<div class="row wrap">\n'
                for bi = 1, #win.buttons do
                    parts[#parts + 1] = string.format(
                        '\t\t\t\t\t\t<div class="btn ghost">%s</div>\n', esc(lab_of(win.buttons[bi])))
                end
                parts[#parts + 1] = '\t\t\t\t\t</div>\n'
            end
            if #(win.checks or {}) > 0 then
                for ci = 1, #win.checks do
                    parts[#parts + 1] = string.format(
                        '\t\t\t\t\t<div class="check-row"><span class="check"></span><span>%s</span></div>\n',
                        esc(lab_of(win.checks[ci])))
                end
            end
            emit_inputs(parts, win, mid .. '_w' .. wi, '\t\t\t\t\t')
            if #(win.sections or {}) == 0 and #(win.buttons or {}) == 0 and #(win.checks or {}) == 0
                and #(win.inputs or {}) == 0 then
                parts[#parts + 1] = string.format(
                    '\t\t\t\t\t<div class="hint">Window <b>%s</b> — open via Classic or module slash cmd.</div>\n',
                    esc(win.title or ''))
            end
        end
        return table.concat(parts)
    end

    local nav, panes = {}, {}
    local total_wins, total_tabs = 0, 0
    for i = 1, #modules do
        local m = modules[i]
        local mid = m.id or slug(m.label)
        local on = i == 1 and ' on' or ''
        local nw = #(m.windows or {})
        total_wins = total_wins + nw
        local ntabs = 0
        for wi = 1, nw do ntabs = ntabs + #((m.windows[wi].tabs) or {}) end
        total_tabs = total_tabs + ntabs
        local badge = nw > 0 and string.format(' (%d)', nw) or ''
        nav[#nav + 1] = string.format(
            '\t\t\t<div id="tab_%s" class="nav-item%s" action="tab:%s">%s%s</div>\n',
            mid, on, mid, esc(m.label or mid), badge)

        local body = {}
        body[#body + 1] = string.format(
            '\t\t\t<div id="panel_%s" class="tab-panel%s">\n', mid, on)
        body[#body + 1] = '\t\t\t\t<div class="panel">\n'
        body[#body + 1] = string.format(
            '\t\t\t\t\t<div class="panel-head">%s · %d window%s</div>\n',
            esc(m.label or mid), nw, nw == 1 and '' or 's')
        -- Open / classic module actions
        body[#body + 1] = '\t\t\t\t\t<div class="row wrap mod-actions">\n'
        if not m.is_host then
            body[#body + 1] = string.format(
                '\t\t\t\t\t\t<div class="btn" action="openmod:%s">Open Module</div>\n',
                esc(m.label or mid))
        end
        for ci = 1, #(m.cmds or {}) do
            body[#body + 1] = string.format(
                '\t\t\t\t\t\t<div class="btn ghost" action="cmd:%s">%s</div>\n',
                esc(m.cmds[ci]), esc(m.cmds[ci]))
        end
        body[#body + 1] = '\t\t\t\t\t</div>\n'
        -- Window switcher
        if nw > 1 then
            body[#body + 1] = string.format(
                '\t\t\t\t\t<div class="seg" id="wins_%s">\n', mid)
            for wi = 1, nw do
                local won = wi == 1 and ' on' or ''
                body[#body + 1] = string.format(
                    '\t\t\t\t\t\t<div id="winbtn_%s_%d" class="seg-item%s" action="win:%s:%d">%s</div>\n',
                    mid, wi, won, mid, wi, esc(m.windows[wi].title or ('Win ' .. wi)))
            end
            body[#body + 1] = '\t\t\t\t\t</div>\n'
        end
        body[#body + 1] = '\t\t\t\t\t<div class="mod-host">\n'
        for wi = 1, math.max(1, nw) do
            local win = (m.windows and m.windows[wi]) or { title = m.label, tabs = {}, buttons = {}, checks = {}, sections = {} }
            local won = wi == 1 and ' on' or ''
            body[#body + 1] = string.format(
                '\t\t\t\t\t<div id="win_%s_%d" class="mod-win%s">\n', mid, wi, won)
            if nw <= 1 then
                body[#body + 1] = string.format(
                    '\t\t\t\t\t\t<div class="eyebrow">%s</div>\n', esc(win.title or m.label or ''))
            end
            body[#body + 1] = ctrl_html(win, mid, wi)
            body[#body + 1] = '\t\t\t\t\t</div>\n'
        end
        body[#body + 1] = '\t\t\t\t\t</div>\n'
        body[#body + 1] = '\t\t\t\t</div>\n\t\t\t</div>\n'
        panes[#panes + 1] = table.concat(body)
    end

    local chips = {
        '<span class="chip ghost">view-model</span>',
        string.format('<span class="chip ghost">%d modules</span>', #modules),
        string.format('<span class="chip ghost">%d windows</span>', total_wins),
        string.format('<span class="chip ghost">%d tabs</span>', total_tabs),
    }
    if opts.coverage_ok == false then
        chips[#chips + 1] = '<span class="chip danger">coverage FAIL</span>'
    elseif opts.soft and opts.soft > 0 then
        chips[#chips + 1] = string.format('<span class="chip ghost">soft %d</span>', opts.soft)
    end

    local status = string.format(
        'VIEW · %d modules · %d windows · %d tabs — click module, then its windows/tabs.',
        #modules, total_wins, total_tabs)

    local rml = table.concat({
        head(title, style_block({
            '.vm-split { display: flex; flex-direction: row; gap: 10dp; flex: 1; min-height: 0; }',
            '.vm-nav { width: 190dp; overflow-y: auto; display: flex; flex-direction: column; gap: 2dp; '
                .. 'border-right: 1dp #3a2a18; padding-right: 8dp; flex-shrink: 0; }',
            '.nav-item { padding: 6dp 10dp; color: #c9b896; cursor: pointer; border-radius: 3dp; font-size: 12dp; }',
            '.nav-item:hover { background-color: #2a1e10; color: #f5e6b8; }',
            '.nav-item.on { background-color: #5c1a1a; color: #ffffff; font-weight: bold; }',
            '.vm-main { flex: 1; min-width: 0; display: flex; flex-direction: column; overflow: hidden; }',
            '.check-row { color: #d4c4a0; font-size: 12dp; margin: 2dp 0; }',
            '.check { display: inline-block; width: 10dp; height: 10dp; border: 1dp #c9a227; margin-right: 6dp; }',
            '.mod-actions { margin-bottom: 8dp; }',
            '.win-tabs { margin: 4dp 0 8dp 0; }',
            '.row.wrap { display: flex; flex-wrap: wrap; gap: 6dp; }',
        })),
        hero(title, 'VIEW', chips),
        glass_bar(),
        '\t<div class="toolbar"><div class="spacer"></div>\n',
        '\t\t<div class="text-btn" action="classic">Classic ImGui</div>\n\t</div>\n',
        '\t<div class="vm-split">\n',
        '\t\t<div class="vm-nav" id="tabs">\n', table.concat(nav), '\t\t</div>\n',
        '\t\t<div class="vm-main tab-host">\n', table.concat(panes), '\t\t</div>\n',
        '\t</div>\n',
        '\t<div class="status"><span class="dot"></span><span id="status">', esc(status), '</span></div>\n',
        '</body>\n</rml>\n',
    })

    local safe = (title:gsub('[^%w]', ''))
    if safe == '' then safe = 'Tool' end
    local first = modules[1].id or slug(modules[1].label)

    -- Build Lua state tables
    local tab_list, label_map, win_counts, cmd_map, load_map = {}, {}, {}, {}, {}
    for i = 1, #modules do
        local m = modules[i]
        local mid = m.id or slug(m.label)
        tab_list[i] = string.format('%q', mid)
        label_map[i] = string.format('[%q]=%q', mid, m.label or mid)
        win_counts[i] = string.format('[%q]=%d', mid, math.max(1, #(m.windows or {})))
        load_map[i] = string.format('[%q]=%q', mid, m.label or mid)
        local cmds = m.cmds or {}
        if #cmds > 0 then
            local parts = {}
            for ci = 1, #cmds do parts[ci] = string.format('%q', cmds[ci]) end
            cmd_map[i] = string.format('[%q]={%s}', mid, table.concat(parts, ','))
        end
    end

    local host_load = opts.host_cmd or classic_run
    local lua = table.concat({
        '-- AUTO_PORT_VER=', tostring(AUTO_PORT_VER), ' shape=VIEW\n',
        '-- View-model: ', tostring(#modules), ' modules / ', tostring(total_wins),
        ' windows / ', tostring(total_tabs), ' tabs. Nested win/tab switchers included.\n',
        "local host = require('rmlui.host')\n",
        "local mq = require('mq')\n",
        'local M = { win = nil, glass = false, tab = ', string.format('%q', first),
        ', win_i = {}, tab_i = {}, _sig = {} }\n',
        'local CLASSIC = ', string.format('%q', classic_run), '\n',
        'local HOST_LOAD = ', string.format('%q', host_load), '\n',
        'local TABS = {', table.concat(tab_list, ', '), '}\n',
        'local LABELS = {', table.concat(label_map, ', '), '}\n',
        'local WIN_N = {', table.concat(win_counts, ', '), '}\n',
        'local LOAD_NAME = {', table.concat(load_map, ', '), '}\n',
        'local CMDS = {', table.concat(cmd_map, ', '), '}\n\n',
        'for i = 1, #TABS do\n',
        '    local id = TABS[i]\n',
        '    M.win_i[id] = 1\n',
        '    M.tab_i[id] = {}\n',
        '    for w = 1, (WIN_N[id] or 1) do M.tab_i[id][w] = 1 end\n',
        'end\n\n',
        'function M.ensure()\n',
        '    if M.win and M.win:is_open() then return true end\n',
        "    local win, err = host.open('AP_View_", safe, "', '", port_pack, "/ui/main.rml', ",
        "{ width = 1100, height = 820, theme = 'redguides', title = '", title:gsub("'", ''), "', reload = true, glass = M.glass })\n",
        "    if not win then print('[AutoPort] view UI failed: ' .. tostring(err)); return false end\n",
        "    win:text('window-title', '", title:gsub("'", ''), "')\n",
        "    win:class('body', 'pinned', false)\n",
        '    pcall(function() win:place(100, 40, 1100, 820) end)\n',
        '    M.win = win\n',
        '    return true\n',
        'end\n\n',
        'function M.close() if M.win then pcall(function() M.win:show(false) end) end end\n',
        'function M.show(v) if M.win then M.win:show(v ~= false) end end\n',
        'function M.hide_all() M.show(false) end\n\n',
        'local function paint(w)\n',
        '    for i = 1, #TABS do\n',
        '        local id = TABS[i]\n',
        "        w:class('tab_' .. id, 'on', M.tab == id)\n",
        "        w:class('panel_' .. id, 'on', M.tab == id)\n",
        '        local wn = WIN_N[id] or 1\n',
        '        local cur = M.win_i[id] or 1\n',
        '        for wi = 1, wn do\n',
        "            w:class('winbtn_' .. id .. '_' .. wi, 'on', cur == wi)\n",
        "            w:class('win_' .. id .. '_' .. wi, 'on', cur == wi)\n",
        '            local ti_cur = (M.tab_i[id] and M.tab_i[id][wi]) or 1\n',
        '            for ti = 1, 12 do\n',
        "                local tid = id .. '_w' .. wi .. '_t' .. ti\n",
        "                pcall(function() w:class('mtab_' .. tid, 'on', ti_cur == ti) end)\n",
        "                pcall(function() w:class('mbody_' .. tid, 'on', ti_cur == ti) end)\n",
        '            end\n',
        '        end\n',
        '    end\n',
        'end\n\n',
        'function M.tick(api)\n',
        '    if not M.ensure() then return false end\n',
        '    host.tick(M.win, {\n',
        '        close = function() M.show(false) end,\n',
        '        action = function(a)\n',
        "            local t = a:match('^tab:(.+)$')\n",
        '            if t then M.tab = t; return end\n',
        "            local mid, wi = a:match('^win:([^:]+):(%d+)$')\n",
        '            if mid then M.win_i[mid] = tonumber(wi) or 1; return end\n',
        "            local m2, w2, t2 = a:match('^mtab:([^:]+):(%d+):(%d+)$')\n",
        '            if m2 then\n',
        '                M.tab_i[m2] = M.tab_i[m2] or {}\n',
        '                M.tab_i[m2][tonumber(w2) or 1] = tonumber(t2) or 1\n',
        '                return\n',
        '            end\n',
        "            local open = a:match('^openmod:(.+)$')\n",
        '            if open then\n',
        "                mq.cmdf('/lua run %s', HOST_LOAD)\n",
        "                if HOST_LOAD == 'myui' then mq.cmdf('/myui load %s', open) end\n",
        '                local cmds = CMDS[M.tab]\n',
        '                if cmds and cmds[1] then mq.cmdf(cmds[1]) end\n',
        '                return\n',
        '            end\n',
        "            local cmd = a:match('^cmd:(.+)$')\n",
        '            if cmd then mq.cmdf(cmd); return end\n',
        "            if a == 'classic' then mq.cmdf('/lua run %s', CLASSIC) end\n",
        "            if type(api) == 'table' and api.action then pcall(api.action, a) end\n",
        '        end,\n',
        '        glass = function(on) M.glass = on end,\n',
        '        update = function(w)\n',
        '            paint(w)\n',
        '            local st = string.format(\'VIEW · %s · win %d/%d\',\n',
        '                LABELS[M.tab] or M.tab,\n',
        '                M.win_i[M.tab] or 1, WIN_N[M.tab] or 1)\n',
        "            if type(api) == 'table' and api.status then\n",
        '                local s = api.status(); if s and s ~= \'\' then st = s end\n',
        '            end\n',
        "            w:text('status', st)\n",
        '        end,\n',
        '    })\n',
        '    return true\n',
        'end\n\n',
        'return M\n',
    })
    return rml, lua, 'VIEW'
end

function M.emit_unsupported(title, port_pack, classic_run, reason)
    local cov = { ok = false, reason = reason, stats = {}, arch = {}, blocked = {}, caution = {} }
    return M.emit_coverage(title, port_pack, classic_run, cov, reason or '')
end

function M.emit_rml(model, title, rml_rel)
    title = title or 'Tool'
    current_theme_href = theme_href_for(rml_rel or 'ports/x/ui/main.rml')
    local shape = model.shape or 'C'
    if shape == 'B' then return emit_rml_B(model, title), 'B' end
    if shape == 'A' then
        return emit_rml_A(model, title), model.complex and 'A*' or 'A'
    end
    if shape == 'D' then return emit_rml_D(model, title), 'D' end
    return emit_rml_C(model, title), 'C'
end

function M.emit_lua(model, name, rml_rel, title)
    local shape = model.shape or 'C'
    local wins = model.windows or {}
    local nwin = math.max(1, #wins)
    local tabInits = {}
    for w = 1, nwin do tabInits[#tabInits + 1] = string.format('[%d]=1', w) end

    local nav_init = 'nil'
    if shape == 'B' and model._nav and model._nav[1] then
        nav_init = string.format('%q', model._nav[1].id)
    end

    local nav_blob = 'nil'
    if shape == 'B' and model._nav then
        local chunks = { '{' }
        for i = 1, #model._nav do
            local n = model._nav[i]
            chunks[#chunks + 1] = string.format('[%q]={label=%q,lines={', n.id, n.label)
            for li = 1, #(n.lines or {}) do
                chunks[#chunks + 1] = string.format('%q,', n.lines[li])
            end
            chunks[#chunks + 1] = '}},'
        end
        chunks[#chunks + 1] = '}'
        nav_blob = table.concat(chunks)
    end

    local safe_title = (title or name):gsub("'", '')
    local safe_name = (name or 'Tool'):gsub('[^%w]', '')
    if safe_name == '' then safe_name = 'Tool' end
    -- Unique Rml window name so ports never collide with AutoPort / originals
    local win_name = 'AP_' .. safe_name

    return table.concat({
        '-- AUTO_PORT_VER=', tostring(AUTO_PORT_VER), ' shape=', shape, '\n',
        '-- Generated by AutoPort v', tostring(AUTO_PORT_VER), '. Delete AUTO_PORT_VER line to protect from Apply overwrite.\n',
        "local host = require('rmlui.host')\n",
        "local mq = require('mq')\n",
        "local rmlui = require('rmlui')\n",
        'local M = {\n',
        '    win = nil,\n',
        '    tab = {', table.concat(tabInits, ','), '},\n',
        '    win_i = 1,\n',
        '    nav = ', nav_init, ',\n',
        '    pages = ', nav_blob, ',\n',
        '    sec_closed = {},\n',
        '    chk = {},\n',
        '    glass = false,\n',
        '    complex = ', model.complex and 'true' or 'false', ',\n',
        '    _live = {},\n',
        '    _sig = {},\n',
        '}\n\n',
        'local function rml_if(w, id, html)\n',
        '    html = html or \'\'\n',
        '    if M._sig[id] == html then return end\n',
        '    M._sig[id] = html\n',
        '    pcall(function() w:rml(id, html) end)\n',
        'end\n\n',
        '-- FA/MD Icons.* → HTML entities in chrome. EQ item bitmaps need atlas ids:\n',
        'local function item_icon_html(icon_id)\n',
        '    local ok, html = pcall(rmlui.item_icon_img, tonumber(icon_id) or 0, \'eq-icon\')\n',
        '    if ok and type(html) == \'string\' then return html end\n',
        '    return \'<div class="eq-icon missing"></div>\'\n',
        'end\n',
        'M.item_icon_html = item_icon_html\n\n',
        'function M.ensure()\n',
        '    if M.win and M.win:is_open() then return true end\n',
        "    local win, err = host.open('", win_name, "', '", rml_rel,
        "', { width = 900, height = 720, theme = 'redguides', title = '", safe_title, "', reload = true, glass = M.glass })\n",
        "    if not win then print('[", safe_name, "] Rml failed: ' .. tostring(err)); return false end\n",
        "    win:text('window-title', '", safe_title, "')\n",
        "    win:class('body', 'pinned', false)\n",
        "    pcall(function() win:show(true) end)\n",
        "    pcall(function() win:place(180, 110, 900, 720) end)\n",
        '    M.win = win\n',
        '    M._live = {}\n',
        '    M._sig = {}\n',
        '    return true\n',
        'end\n\n',
        'function M.close()\n',
        '    -- Hide only from UI; never rml_close mid-event (crashes client).\n',
        '    if M.win then pcall(function() M.win:show(false) end) end\n',
        'end\n',
        'function M.hard_close()\n',
        '    local win = M.win; M.win = nil\n',
        '    if win then pcall(function() win:close() end) end\n',
        'end\n',
        'function M.show(v) if M.win then M.win:show(v ~= false) end end\n',
        'function M.hide_all() M.show(false) end\n\n',
        'local function paint_tabs(w)\n',
        '    for wi, cur in pairs(M.tab) do\n',
        '        for ti = 1, 32 do\n',
        "            local id = string.format('tab_%d_%d', wi, ti)\n",
        "            local pid = string.format('panel_%d_%d', wi, ti)\n",
        '            w:class(id, \'on\', cur == ti)\n',
        '            w:class(pid, \'on\', cur == ti)\n',
        '        end\n',
        '    end\n',
        'end\n\n',
        'local function paint_live(w, api)\n',
        '    if not M.complex then return end\n',
        '    for wi, cur in pairs(M.tab) do\n',
        "        local lid = string.format('live_%d_%d', wi, cur)\n",
        '        local html\n',
        '        if type(api) == \'table\' and type(api.refreshTab) == \'function\' then\n',
        '            local ok, out = pcall(api.refreshTab, wi, cur)\n',
        '            if ok and type(out) == \'string\' and out ~= \'\' then html = out end\n',
        '            if ok and type(out) == \'table\' then\n',
        '                local parts = {}\n',
        '                for i = 1, #out do\n',
        "                    parts[#parts + 1] = '<div class=\"live-line\">' .. host.esc(tostring(out[i])) .. '</div>'\n",
        '                end\n',
        '                html = table.concat(parts)\n',
        '            end\n',
        '        end\n',
        '        if not html then\n',
        "            html = string.format('<div class=\"live-line muted\">%s · tab %d — wire api.refreshTab for live content</div>',\n",
        "                '", safe_title, "', cur)\n",
        '        end\n',
        '        rml_if(w, lid, html)\n',
        '    end\n',
        'end\n\n',
        'local function paint_nav(w)\n',
        '    if not M.pages then return end\n',
        '    for id, _ in pairs(M.pages) do\n',
        "        w:class('nav_' .. id, 'on', M.nav == id)\n",
        '    end\n',
        '    local page = M.pages[M.nav]\n',
        '    if not page then return end\n',
        "    w:text('page_title', page.label or M.nav)\n",
        '    local html = {}\n',
        '    for i = 1, #(page.lines or {}) do\n',
        "        html[#html + 1] = '<div class=\"doc-line\">' .. host.esc(page.lines[i]) .. '</div>'\n",
        '    end\n',
        "    rml_if(w, 'page', table.concat(html))\n",
        'end\n\n',
        'local function apply_api_page(api)\n',
        '    if type(api) ~= \'table\' then return end\n',
        '    if type(api.getPageForRml) == \'function\' then\n',
        '        local ok, page = pcall(api.getPageForRml, M.nav)\n',
        '        if ok and type(page) == \'table\' then\n',
        '            M.pages = M.pages or {}\n',
        '            M.pages[M.nav or \'page\'] = {\n',
        '                label = page.title or page.name or M.nav,\n',
        '                lines = page.lines or page.body or {},\n',
        '            }\n',
        '            if type(M.pages[M.nav].lines) == \'string\' then\n',
        '                M.pages[M.nav].lines = { M.pages[M.nav].lines }\n',
        '            end\n',
        '        end\n',
        '    end\n',
        '    if type(api.navGroups) == \'function\' then\n',
        '        local ok, groups = pcall(api.navGroups)\n',
        '        if ok and type(groups) == \'table\' and M.win then\n',
        '            local html = {}\n',
        '            M.pages = {}\n',
        '            for gi = 1, #groups do\n',
        '                local g = groups[gi]\n',
        '                local gid = tostring(g.id or g.key or (\'g\' .. gi))\n',
        '                local glabel = tostring(g.label or g.name or gid)\n',
        '                if not M.nav then M.nav = gid end\n',
        '                M.pages[gid] = { label = glabel, lines = g.lines or g.body or { glabel } }\n',
        '                if type(M.pages[gid].lines) == \'string\' then M.pages[gid].lines = { M.pages[gid].lines } end\n',
        "                html[#html + 1] = string.format('<div class=\"nav-item%s\" id=\"nav_%s\" action=\"nav:%s\">%s</div>',\n",
        "                    M.nav == gid and ' on' or '', gid, gid, host.esc(glabel))\n",
        '            end\n',
        "            if #html > 0 then rml_if(M.win, 'nav', table.concat(html)) end\n",
        '        end\n',
        '    end\n',
        'end\n\n',
        'function M.tick(api)\n',
        '    if not M.ensure() then return false end\n',
        '    host.tick(M.win, {\n',
        '        close = function()\n',
        '            if type(api) == \'table\' and api.set_open then api.set_open(false) else M.show(false) end\n',
        '        end,\n',
        '        action = function(a)\n',
        '            local w, t = a:match(\'^tab:(%d+):(%d+)$\')\n',
        '            if w then M.tab[tonumber(w)] = tonumber(t); M.win:text(\'status\', \'tab \' .. t); return end\n',
        '            local wi = a:match(\'^win:(%d+)$\')\n',
        '            if wi then M.win_i = tonumber(wi); M.win:text(\'status\', \'window \' .. wi); return end\n',
        '            local nid = a:match(\'^nav:(.+)$\')\n',
        '            if nid then M.nav = nid; paint_nav(M.win); M.win:text(\'status\', nid); return end\n',
        '            local sid = a:match(\'^sec:(.+)$\')\n',
        '            if sid then\n',
        '                M.sec_closed[sid] = not M.sec_closed[sid]\n',
        "                M.win:class('sec_' .. sid:gsub('%W', '_'), 'closed', M.sec_closed[sid])\n",
        '                return\n',
        '            end\n',
        '            local ck = a:match(\'^chk:(.+)$\')\n',
        '            if ck then\n',
        '                M.chk[ck] = not M.chk[ck]\n',
        "                local eid = 'chk_' .. ck:gsub(':', '_'):gsub('%W', '_')\n",
        '                M.win:class(eid, \'on\', M.chk[ck])\n',
        '            end\n',
        '            local slash = a:match(\'^slash:(.+)$\')\n',
        '            if slash then mq.cmd(slash); M.win:text(\'status\', slash); return end\n',
        '            M.win:text(\'status\', a)\n',
        '            if type(api) == \'table\' and api.action then pcall(api.action, a) end\n',
        '            if type(api) == \'table\' and api.onAction then pcall(api.onAction, a) end\n',
        '            if type(api) == \'table\' and api.onNav and nid then pcall(api.onNav, nid) end\n',
        '        end,\n',
        '        change = function(ev)\n',
        '            if type(api) == \'table\' and api.change then pcall(api.change, ev) end\n',
        '        end,\n',
        '        glass = function(on) M.glass = on end,\n',
        '        update = function(w)\n',
        '            paint_tabs(w)\n',
        '            paint_live(w, api)\n',
        "            if '", shape, "' == 'B' then\n",
        '                apply_api_page(api)\n',
        '                paint_nav(w)\n',
        '            end\n',
        '            if type(api) == \'table\' and api.update then pcall(api.update, w) end\n',
        '            if type(api) == \'table\' and api.status then\n',
        '                local s = api.status()\n',
        '                if s then w:text(\'status\', s) end\n',
        '            end\n',
        '            if type(api) == \'table\' and api.refreshList then\n',
        '                local ok, rows = pcall(api.refreshList)\n',
        '                if ok and type(rows) == \'table\' then\n',
        '                    local html = {}\n',
        '                    for i = 1, #rows do\n',
        '                        local L = tostring(rows[i].label or rows[i].name or rows[i] or (\'#\' .. i))\n',
        "                        html[#html + 1] = string.format('<div class=\"item\" action=\"sel:list:%d\">%s</div>', i, host.esc(L))\n",
        '                    end\n',
        "                    if #html > 0 then rml_if(w, 'list', table.concat(html)) end\n",
        '                end\n',
        '            end\n',
        '        end,\n',
        '    })\n',
        '    return true\n',
        'end\n\n',
        'return M\n',
    }), shape
end

M.AUTO_PORT_VER = AUTO_PORT_VER
return M
