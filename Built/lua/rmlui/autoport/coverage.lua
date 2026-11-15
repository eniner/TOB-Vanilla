--[[ AutoPort coverage — map ImGui calls to portable / soft / hard.
     HARD blockers → refuse template stub (FAIL loudly + COVERAGE.md).
     SOFT issues → caution only; still allow A/B/C/D template ports.
     Theme push/pop and tooltips are SOFT — almost every RedGuides script has them. ]]
local M = {}

-- HARD: template cannot faithfully express these. Refuse stub.
-- TreeNode is SOFT (collapsible cards). InputTextMultiline is SOFT but must NOT
-- emit a native <textarea> — that widget hard-crashes MQ2RmlUi on click.
local HARD_BLOCKED = {
    PlotLines = 'no Rml plot widget',
    PlotHistogram = 'no Rml plot widget',
}

-- Key polls are SOFT by default (hotkeys). HARD only when console chords exist (HARD_ARCH).
local KEY_SOFT = {
    IsKeyPressed = 'hotkey poll — soft unless Enter/Tab/Ctrl console chords present',
    IsKeyDown = 'hotkey poll — soft unless used as primary input model',
    IsKeyReleased = 'hotkey poll — soft',
    GetKeyIndex = 'hotkey poll — soft',
    Shortcut = 'shortcut helper — soft unless primary input',
}

-- SOFT: missing polish, not a reason to refuse the whole port.
local SOFT_BLOCKED = {
    OpenPopup = 'modals need hand wiring',
    BeginPopupModal = 'modals need hand wiring',
    BeginPopup = 'popups need hand wiring',
    BeginTooltip = 'tooltips omitted in template (hover later)',
    EndTooltip = 'tooltips omitted in template',
    ColorEdit = 'no color picker',
    ColorEdit3 = 'no color picker',
    ColorEdit4 = 'no color picker',
    ColorPicker3 = 'no color picker',
    ColorPicker4 = 'no color picker',
    DragFloat = 'no drag scalar',
    DragInt = 'no drag scalar',
    SliderFloat = 'range input needs hand wiring',
    SliderInt = 'range input needs hand wiring',
    TreeNode = 'collapsible → Rml section (template still usable)',
    TreeNodeEx = 'collapsible → Rml section (template still usable)',
    TreeNodeV = 'collapsible → Rml section (template still usable)',
    InputTextMultiline = 'multiline → single-line <input> (native textarea crashes MQ2RmlUi)',
    SetClipboardText = 'copy button omitted — not a reason to refuse the port',
    GetClipboardText = 'paste button omitted — not a reason to refuse the port',
}

-- HARD architecture — unportable by design / needs view-model
local HARD_ARCH = {
    { pat = 'registerCustomTab', why = 'foreign ImGui callbacks injected into tabs — unportable by design' },
    { pat = 'drawNavOverlay', why = 'second overlay window' },
    { pat = 'IsKeyPressed%s*%(%s*ImGuiKey%.Enter', why = 'Enter-to-eval needs keydown host support' },
    { pat = 'ImGuiKey%.Tab', why = 'Tab autocomplete needs keydown host support' },
    { pat = 'ImGuiKey%.LeftCtrl', why = 'Ctrl+Space autocomplete needs keydown host support' },
    { pat = 'ImGuiKey%.RightCtrl', why = 'Ctrl chord needs keydown host support' },
}

-- SOFT architecture — note in report, do not FAIL
local SOFT_ARCH = {
    { pat = 'PushStyleColor', why = 'theme push/pop → RCSS theme (template still usable)' },
    { pat = 'PushStyleVar', why = 'style vars → RCSS (template still usable)' },
}

local PORTABLE = {
    Button = true, SmallButton = true, InvisibleButton = true,
    Checkbox = true, RadioButton = true,
    InputText = true, InputInt = true, InputFloat = true, InputTextWithHint = true,
    BeginCombo = true, Combo = true, Selectable = true,
    Begin = true, End = true,
    BeginTabBar = true, EndTabBar = true, BeginTabItem = true, EndTabItem = true,
    BeginMenuBar = true, BeginMenu = true, EndMenu = true, MenuItem = true,
    Text = true, TextWrapped = true, TextColored = true, TextDisabled = true,
    Separator = true, SameLine = true, NewLine = true, Spacing = true,
    Dummy = true, Indent = true, Unindent = true,
    ProgressBar = true, Bullet = true, BulletText = true,
    Image = true, ImageButton = true,
    Columns = true, NextColumn = true, TableNextColumn = true,
    BeginTable = true, EndTable = true, TableNextRow = true, TableSetupColumn = true,
    BeginChild = true, EndChild = true, BeginGroup = true, EndGroup = true,
    CollapsingHeader = true, PopStyleColor = true, PopStyleVar = true,
}

local function line_no(src, idx)
    local n = 1
    for i = 1, math.min(idx, #src) do
        if src:sub(i, i) == '\n' then n = n + 1 end
    end
    return n
end

local function scan_pats(src, pats, out, limit)
    limit = limit or 40
    for i = 1, #pats do
        local ap = pats[i]
        local start = 1
        while #out < limit do
            local a, b = src:find(ap.pat, start)
            if not a then break end
            out[#out + 1] = { line = line_no(src, a), call = ap.pat, why = ap.why, hard = ap.hard }
            start = b + 1
        end
    end
end

function M.scan(src, opts)
    opts = opts or {}
    src = tostring(src or '')
    local portable, blocked, soft_blocked, caution, arch, soft_arch = {}, {}, {}, {}, {}, {}
    local counts = {
        imgui_calls = 0, portable = 0, blocked = 0, soft_blocked = 0,
        caution = 0, arch = 0, soft_arch = 0, item_icons = 0,
    }
    if src:find('A_DragItem', 1, true) then counts.item_icons = counts.item_icons + 1 end
    if src:find('DrawTextureAnimation', 1, true) then counts.item_icons = counts.item_icons + 1 end
    if src:find('SetTextureCell', 1, true) then counts.item_icons = counts.item_icons + 1 end
    if src:find('item_icon_img', 1, true) then counts.item_icons = counts.item_icons + 1 end
    if src:find('.Icon(', 1, true) then counts.item_icons = counts.item_icons + 1 end
    local tab_bars = 0
    local tab_items = 0
    local max_tab_depth, depth = 0, 0

    scan_pats(src, HARD_ARCH, arch, 40)
    counts.arch = #arch
    scan_pats(src, SOFT_ARCH, soft_arch, 20)
    counts.soft_arch = #soft_arch

    local pos = 1
    while true do
        local a, b, name = src:find('[Ii]m[Gg]ui%.([A-Za-z_][A-Za-z0-9_]*)%s*%(', pos)
        if not a then break end
        counts.imgui_calls = counts.imgui_calls + 1
        local ln = line_no(src, a)
        local entry = { line = ln, call = 'ImGui.' .. name }

        if name == 'BeginTabBar' then
            depth = depth + 1
            tab_bars = tab_bars + 1
            if depth > max_tab_depth then max_tab_depth = depth end
            if depth > 1 then
                blocked[#blocked + 1] = {
                    line = ln, call = 'ImGui.BeginTabBar',
                    why = 'nested tab bar (depth ' .. depth .. ') — template only scrapes depth 1',
                }
                counts.blocked = counts.blocked + 1
            else
                portable[#portable + 1] = entry
                counts.portable = counts.portable + 1
            end
        elseif name == 'EndTabBar' then
            depth = math.max(0, depth - 1)
            portable[#portable + 1] = entry
            counts.portable = counts.portable + 1
        elseif HARD_BLOCKED[name] then
            blocked[#blocked + 1] = { line = ln, call = 'ImGui.' .. name, why = HARD_BLOCKED[name] }
            counts.blocked = counts.blocked + 1
        elseif KEY_SOFT[name] then
            soft_blocked[#soft_blocked + 1] = { line = ln, call = 'ImGui.' .. name, why = KEY_SOFT[name] }
            counts.soft_blocked = counts.soft_blocked + 1
            caution[#caution + 1] = soft_blocked[#soft_blocked]
            counts.caution = counts.caution + 1
        elseif SOFT_BLOCKED[name] then
            soft_blocked[#soft_blocked + 1] = { line = ln, call = 'ImGui.' .. name, why = SOFT_BLOCKED[name] }
            counts.soft_blocked = counts.soft_blocked + 1
            caution[#caution + 1] = soft_blocked[#soft_blocked]
            counts.caution = counts.caution + 1
        elseif PORTABLE[name] then
            portable[#portable + 1] = entry
            counts.portable = counts.portable + 1
            if name == 'BeginTabItem' then tab_items = tab_items + 1 end
            if name == 'Checkbox' or name == 'InputText' or name == 'InputInt'
                or name == 'InputFloat' or name == 'InputTextWithHint' then
                caution[#caution + 1] = {
                    line = ln, call = 'ImGui.' .. name,
                    why = 'immediate-mode assign needs retained value + focus-guard on change',
                }
                counts.caution = counts.caution + 1
            end
        else
            caution[#caution + 1] = {
                line = ln, call = 'ImGui.' .. name, why = 'unmapped — soft (template may omit)',
            }
            counts.caution = counts.caution + 1
        end
        pos = b + 1
        if counts.imgui_calls >= 12000 then break end
    end

    if tab_bars >= 1 and tab_items == 0 then
        arch[#arch + 1] = {
            line = 0, call = 'BeginTabBar without BeginTabItem',
            why = 'tabs live in other files that were not collected — glob ui/*.lua and use view-model',
        }
        counts.arch = counts.arch + 1
    end

    -- Multiple TabBars in one file is HARD only when depth>1 already counted,
    -- or when paired with other hard signals. Alone → soft.
    if tab_bars >= 2 and max_tab_depth <= 1 then
        soft_arch[#soft_arch + 1] = {
            line = 0, call = 'BeginTabBar×' .. tab_bars,
            why = 'multiple sibling TabBars — template uses richest window only',
        }
        counts.soft_arch = counts.soft_arch + 1
    elseif tab_bars >= 2 and max_tab_depth > 1 then
        arch[#arch + 1] = {
            line = 0, call = 'BeginTabBar×' .. tab_bars,
            why = 'nested TabBars — needs view-model, not template scrape',
        }
        counts.arch = counts.arch + 1
    end

    local dyn = 0
    for _ in src:gmatch('##[%w_]*%%[ds]') do dyn = dyn + 1 end
    if dyn >= 12 then
        soft_arch[#soft_arch + 1] = {
            line = 0, call = 'dynamic_##id',
            why = string.format('%d dynamic ImGui ids — row actions need stable ids in view-model', dyn),
        }
        counts.soft_arch = counts.soft_arch + 1
    end

    -- Only flag huge console-style log rebuilds, not every large script with table.concat
    if src:find('MAX_LOG', 1, true) and src:find('state%.logs', 1, false)
        and src:find('table%.concat', 1, false) and #src >= 100000 then
        soft_arch[#soft_arch + 1] = {
            line = 0, call = 'log_rebuild',
            why = 'large console log — prefer incremental append + cap when porting Logs panel',
        }
        counts.soft_arch = counts.soft_arch + 1
    end

    -- Console-style key chords (HARD_ARCH) promote key polls to hard blocked
    if #arch > 0 then
        local key_hard = false
        for i = 1, #arch do
            local c = tostring(arch[i].call or '')
            if c:find('ImGuiKey', 1, true) or c:find('IsKeyPressed', 1, true) then
                key_hard = true
                break
            end
        end
        if key_hard then
            for i = #soft_blocked, 1, -1 do
                local e = soft_blocked[i]
                local nm = (e.call or ''):match('ImGui%.(.+)') or ''
                if KEY_SOFT[nm] then
                    table.remove(soft_blocked, i)
                    counts.soft_blocked = counts.soft_blocked - 1
                    blocked[#blocked + 1] = {
                        line = e.line, call = e.call,
                        why = 'console key chord present — ' .. (KEY_SOFT[nm] or 'needs host keydown'),
                    }
                    counts.blocked = counts.blocked + 1
                end
            end
        end
    end

    local hard_n = #blocked + #arch
    local ok = hard_n == 0
    local reason
    if not ok then
        reason = string.format(
            '%d hard blocked, %d hard arch (soft blocked=%d soft arch=%d) — template would lie',
            #blocked, #arch, #soft_blocked, #soft_arch)
    elseif #soft_blocked + #soft_arch > 0 then
        reason = string.format(
            'PASS with cautions (soft blocked=%d soft arch=%d) — template allowed',
            #soft_blocked, #soft_arch)
    end

    local function take(t, n)
        local o = {}
        for i = 1, math.min(#t, n or 80) do o[i] = t[i] end
        return o
    end

    return {
        ok = ok,
        reason = reason,
        portable = take(portable, 40),
        blocked = take(blocked, 80),
        soft_blocked = take(soft_blocked, 40),
        caution = take(caution, 60),
        arch = take(arch, 40),
        soft_arch = take(soft_arch, 40),
        stats = {
            imgui_calls = counts.imgui_calls,
            portable = counts.portable,
            blocked = counts.blocked,
            soft_blocked = counts.soft_blocked,
            caution = counts.caution,
            arch = counts.arch,
            soft_arch = counts.soft_arch,
            tab_bars = tab_bars,
            max_tab_depth = max_tab_depth,
            dynamic_ids = dyn,
            src_bytes = #src,
            item_icons = counts.item_icons,
        },
    }
end

function M.format_report(cov, label, classic)
    cov = cov or {}
    local st = cov.stats or {}
    local lines = {
        '# AutoPort coverage — ' .. tostring(label or 'tool'),
        '',
        string.format('Verdict: %s', cov.ok and 'PASS (template-eligible)' or 'FAIL (view-model / hand port required)'),
        cov.reason and ('Reason: ' .. cov.reason) or '',
        classic and ('Classic: /lua run ' .. classic) or '',
        '',
        '## Stats',
        string.format('- ImGui calls scanned: %d', st.imgui_calls or 0),
        string.format('- Portable: %d', st.portable or 0),
        string.format('- Hard blocked: %d', st.blocked or 0),
        string.format('- Soft blocked: %d', st.soft_blocked or 0),
        string.format('- Caution: %d', st.caution or 0),
        string.format('- Hard architecture: %d', st.arch or 0),
        string.format('- Soft architecture: %d', st.soft_arch or 0),
        string.format('- Tab bars: %d (max depth %d)', st.tab_bars or 0, st.max_tab_depth or 0),
        string.format('- Dynamic ##id patterns: %d', st.dynamic_ids or 0),
        string.format('- Source bytes: %d', st.src_bytes or 0),
        '',
        '## Item / spell icons',
        '- Icons.FA_* / Icons.MD_* → Rml `font-family: Icons` HTML entities (chrome only).',
        '- EQ item bitmaps (Item.Icon, A_DragItem, DrawTextureAnimation) are NOT Font Awesome.',
        '- Ports must emit `rmlui.item_icon_img(iconId)` / `eq://item/N` (atlas cell = Item.Icon).',
        '- Looking up Icon() only on FindItem shows empty plates for items not in bags.',
        '- Prefer UltDev/catalog/*/items.json `"id","name","icon"` for known item ids.',
        string.format('- Icon-draw hits in this scan: %d', st.item_icons or 0),
        '',
        '## Hard architecture blockers',
    }
    if #(cov.arch or {}) == 0 then
        lines[#lines + 1] = '- (none)'
    else
        for i = 1, #cov.arch do
            local e = cov.arch[i]
            lines[#lines + 1] = string.format('- L%s  %s — %s', e.line > 0 and e.line or '?', e.call, e.why)
        end
    end
    lines[#lines + 1] = ''
    lines[#lines + 1] = '## Hard blocked ImGui calls'
    if #(cov.blocked or {}) == 0 then
        lines[#lines + 1] = '- (none)'
    else
        for i = 1, #cov.blocked do
            local e = cov.blocked[i]
            lines[#lines + 1] = string.format('- L%d  %s — %s', e.line, e.call, e.why)
        end
    end
    lines[#lines + 1] = ''
    lines[#lines + 1] = '## Soft (does not refuse template)'
    local soft = {}
    for i = 1, #(cov.soft_arch or {}) do soft[#soft + 1] = cov.soft_arch[i] end
    for i = 1, #(cov.soft_blocked or {}) do soft[#soft + 1] = cov.soft_blocked[i] end
    if #soft == 0 then
        lines[#lines + 1] = '- (none)'
    else
        for i = 1, math.min(30, #soft) do
            local e = soft[i]
            lines[#lines + 1] = string.format('- L%s  %s — %s', (e.line and e.line > 0) and e.line or '?', e.call, e.why)
        end
    end
    lines[#lines + 1] = ''
    lines[#lines + 1] = '## RmlUi host rules (baked into AutoPort emit)'
    lines[#lines + 1] = '- Toggle / flex-row labels must be `<span>` — RmlUi flex drops anonymous text (blank switches).'
    lines[#lines + 1] = '- Never `color: inherit` or `border-radius: inherit` — RCSS parse error.'
    lines[#lines + 1] = '- Never `font-family: Consolas` unless loaded. Default UI face is Segoe UI; rmlui.init loads consola.ttf.'
    lines[#lines + 1] = '- Never emit `<textarea>`. InputTextMultiline → `<input type="text">`. Native textarea click hard-crashes MQ2RmlUi.'
    lines[#lines + 1] = '- Never `display: none` on a panel that contains inputs. Use `.tab-host` / `.mod-host` / `.mtab-host` off-screen overlay.'
    lines[#lines + 1] = '- Do not SetInnerRML every frame for live values; cache HTML (`rml_if`) or `w:text` on cell ids.'
    lines[#lines + 1] = '- Hand ports without `AUTO_PORT_VER=` are never overwritten.'
    lines[#lines + 1] = ''
    lines[#lines + 1] = '## What to do'
    if cov.ok then
        lines[#lines + 1] = '- Template port is allowed. Soft items may be omitted or hand-finished.'
    else
        lines[#lines + 1] = '- Do NOT ship a tabs/sidebar/list template stub for this tool.'
        lines[#lines + 1] = '- Port the view layer only: keep state + logic, replace draw* with view-model → w:rml.'
    end
    lines[#lines + 1] = ''
    return table.concat(lines, '\n')
end

return M
