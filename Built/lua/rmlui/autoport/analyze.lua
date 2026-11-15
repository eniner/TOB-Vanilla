--[[ AutoPort v4 — analyze ImGui Lua into a classified GUI model.
     Complex tools: primary TabBar only (depth 1); nested tabs become sections. ]]
local M = {}

local function vis(label)
    label = tostring(label or '')
    label = label:gsub('Icons%.[A-Z0-9_]+%s*%.%.%s*', '')
    label = label:gsub('###.*', ''):gsub('##.*', '')
    label = label:gsub('%%%-?%d*%.?%d*[sdfiouxXeEgGcaAp]', '') -- strip printf tokens
    label = label:gsub('%(%s*%)', '')
    return label:gsub('^%s+', ''):gsub('%s+$', '')
end

local ICON_GLYPH = {
    MD_SETTINGS = '&#xE713;', MD_SAVE = '&#xE74E;', MD_DELETE = '&#xE74D;',
    MD_ADD = '&#xE710;', MD_SEARCH = '&#xE721;', MD_REFRESH = '&#xE72C;',
    MD_CHECK = '&#xE73E;', MD_CLOSE = '&#xE8BB;', MD_MENU = '&#xE700;',
    FA_COG = '&#xE713;', FA_SAVE = '&#xE74E;', FA_TRASH = '&#xE74D;',
    FA_PLUS = '&#xE710;', FA_SEARCH = '&#xE721;', FA_SYNC = '&#xE72C;',
    FA_LOCK = '&#xE72E;', FA_UNLOCK = '&#xE785;', FA_PLAY = '&#xE768;',
    FA_PAUSE = '&#xE769;', FA_BARS = '&#xE700;', FA_HOME = '&#xE80F;',
}

function M.icon_glyph(name)
    return ICON_GLYPH[name]
end

local function has_imgui(s)
    if not s or s == '' then return false end
    return s:find('mq%.imgui%.init', 1, false)
        or s:find('ImGui%.Register', 1, false)
        or s:find('[Ii]m[Gg]ui%.Begin%s*%(', 1, false)
end

--- Follow launcher stubs (ezquests.lua → EZQuests-main/.../init.lua) to the real ImGui file.
function M.resolve_entry(root, rel, src, read_file)
    root = tostring(root or ''):gsub('\\', '/')
    rel = tostring(rel or ''):gsub('\\', '/')
    src = src or (read_file and read_file(root .. '/' .. rel)) or ''
    if has_imgui(src) then return rel, src, false end
    local candidates = {}
    local nested = src:match("root%s*%.%.%s*['\"](/[^'\"]+%.lua)['\"]")
    if nested then candidates[#candidates + 1] = nested:gsub('^/', '') end
    local lf = src:match("loadfile%s*%(%s*['\"]([^'\"]+%.lua)['\"]")
    if lf then candidates[#candidates + 1] = lf:gsub('\\', '/') end
    local df = src:match("dofile%s*%(%s*['\"]([^'\"]+%.lua)['\"]")
    if df then candidates[#candidates + 1] = df:gsub('\\', '/') end
    local path_pre = src:match("package%.path%s*=%s*root%s*%.%.%s*['\"](/[^'\"]+)/%?%.lua")
    if path_pre then candidates[#candidates + 1] = path_pre:sub(2) .. '/init.lua' end
    for i = 1, #candidates do
        local nrel = candidates[i]
        if nrel and nrel ~= rel then
            local nsrc = read_file and read_file(root .. '/' .. nrel)
            if nsrc and has_imgui(nsrc) then
                return nrel, nsrc, true
            end
        end
    end
    return rel, src, false
end

local function new_bucket()
    return { buttons = {}, checks = {}, inputs = {}, combos = {}, sections = {}, selectables = {} }
end

local function new_window(title, kind)
    local w = new_bucket()
    w.title = title or 'Window'
    w.kind = kind or 'main'
    w.tabs = {}
    w.menus = {}
    w.mode_tabs = {}
    return w
end

local function add_unique(list, label, limit, extra)
    limit = limit or 80
    label = vis(label)
    if label == '' then return end
    for i = 1, #list do
        if (list[i].label or list[i]) == label then
            if extra then
                for k, v in pairs(extra) do list[i][k] = v end
            end
            return
        end
    end
    if #list >= limit then return end
    local row = { label = label }
    if extra then
        for k, v in pairs(extra) do row[k] = v end
    end
    list[#list + 1] = row
end

local function glob_lua(root, folder)
    local names = {}
    local win = (tostring(root or '') .. '/' .. tostring(folder or '')):gsub('/', '\\')
    local p = io.popen('dir /b "' .. win .. '\\*.lua" 2>nul')
    if not p then return names end
    for line in p:lines() do
        local name = line:match('^(.+)%.[Ll][Uu][Aa]$')
        if name then names[#names + 1] = name end
    end
    p:close()
    return names
end

--- True when the package splits UI across ui/, UI/, or Modules/ (not a single init.lua).
function M.has_split_ui(discovered)
    local n = 0
    for i = 1, #(discovered and discovered.files or {}) do
        local f = tostring(discovered.files[i])
        if f:find('/ui/', 1, true) or f:find('/UI/', 1, true)
            or f:find('/Modules/', 1, true) or f:find('/modules/', 1, true) then
            n = n + 1
        end
    end
    return n >= 2
end

function M.collect_sources(root, rel, read_file)
    root = tostring(root or ''):gsub('\\', '/')
    rel = tostring(rel or ''):gsub('\\', '/')
    local src0 = read_file(root .. '/' .. rel) or ''
    local scan_rel, scan_src, followed = M.resolve_entry(root, rel, src0, read_file)
    local parts = { scan_src }
    local dir = scan_rel:match('^(.+)/[^/]+$')
    local discovered = {
        content = nil, data_lines = {}, files = { scan_rel }, split_ui = false,
        followed = followed, origin = rel,
    }
    local seen = {}
    seen[scan_rel:lower()] = true
    seen[rel:lower()] = true

    local function add(path, kind)
        path = tostring(path or ''):gsub('\\', '/')
        if path == '' then return end
        local key = path:lower()
        if seen[key] then return end
        local s = read_file(root .. '/' .. path)
        if not s or s == '' then return end
        seen[key] = true
        parts[#parts + 1] = s
        discovered.files[#discovered.files + 1] = path
        if kind == 'content' then discovered.content = path end
        if kind == 'data' then
            for block in s:gmatch('%.lines%s*=%s*%{(.-)%}') do
                local lines = {}
                for q in block:gmatch('[\'"]([^\'"]+)[\'"]') do
                    lines[#lines + 1] = q
                    if #lines >= 40 then break end
                end
                if #lines > 0 then
                    discovered.data_lines[#discovered.data_lines + 1] = { file = path, lines = lines }
                end
            end
        end
    end

    local function add_glob(sub, kind)
        if not dir then return end
        local folder = dir .. '/' .. sub
        local names = glob_lua(root, folder)
        for i = 1, #names do
            add(folder .. '/' .. names[i] .. '.lua', kind)
        end
    end

    if dir then
        local named = {
            'content.lua', 'gui.lua', 'draw.lua', 'window.lua', 'windows.lua',
            'tabs.lua', 'menu.lua', 'render.lua', 'imgui.lua', 'ui.lua',
            'bmHotbarClass.lua', 'ezimHotbarClass.lua', 'ui_popups.lua', 'ui_main.lua',
        }
        for i = 1, #named do
            local p = dir .. '/' .. named[i]
            if p ~= rel then
                add(p, (named[i] == 'content.lua') and 'content' or 'code')
            end
        end
        local data_names = {
            'data_progression.lua', 'data_systems.lua', 'data_getting_started.lua',
            'data_macroquest.lua', 'data_aa_grinding.lua', 'data_epics.lua',
            'data_sword_experience.lua', 'data_server_commands.lua', 'data_zone_names.lua',
            'data_aa.lua', 'data_reaper.lua',
        }
        for i = 1, #data_names do add(dir .. '/' .. data_names[i], 'data') end

        -- Glob UI files. Prefer ui/ (SmartLoot) over engine modules/ (database, engine).
        -- The old named-whitelist only picked ui_popups.lua and missed the real tabs.
        local before_ui = #discovered.files
        add_glob('ui', 'code')
        add_glob('UI', 'code')
        local got_ui = #discovered.files > before_ui
        add_glob('lib', 'code')
        if not got_ui then
            add_glob('Modules', 'code')
            add_glob('modules', 'code')
        end

        -- Follow require("ui.foo") / safeRequire("ui.foo") from already-collected files.
        local i = 1
        while i <= #discovered.files do
            local src = parts[i] or ''
            for req in src:gmatch("require%s*%(?%s*['\"]([^'\"]+)['\"]") do
                if req:match('^ui%.') or req:match('^UI%.') then
                    add(dir .. '/' .. req:gsub('%.', '/') .. '.lua', 'code')
                end
            end
            for req in src:gmatch("safeRequire%s*%(%s*['\"]([^'\"]+)['\"]") do
                add(dir .. '/' .. req:gsub('%.', '/') .. '.lua', 'code')
            end
            i = i + 1
        end
    end

    discovered.split_ui = M.has_split_ui(discovered)
    return table.concat(parts, '\n'), discovered
end

function M.parse(src, discovered)
    discovered = discovered or {}
    local wins, cur = {}, new_window('Window', 'main')
    local tab, section = nil, nil
    local menu = nil
    local tab_depth = 0 -- BeginTabBar nesting; depth 1 = primary tabs
    local tabbar_win = nil -- last window that opened a primary TabBar (tabs may live in other files)
    local stats = {
        windows = 0, tabs = 0, sections = 0, buttons = 0, checks = 0,
        inputs = 0, menus = 0, icons = 0, selectables = 0, mode_tabs = 0,
        sidebars = 0, content_calls = 0, lines_tables = #(discovered.data_lines or {}),
        item_icons = 0, begins = 0, primary_tabs = 0, nested_tabs = 0, src_bytes = #tostring(src or ''),
    }

    local function push_win()
        local n = #cur.tabs + #cur.sections + #cur.buttons + #cur.checks
            + #cur.inputs + #cur.menus + #cur.mode_tabs + #cur.selectables
        if n > 0 or cur.title ~= 'Window' then
            wins[#wins + 1] = cur
            stats.windows = stats.windows + 1
        end
    end

    local function bucket()
        return section or tab or cur
    end

    for raw in tostring(src or ''):gmatch('[^\r\n]+') do
        local line = raw:gsub('%-%-.*$', '')

        if line:find('BeginChild%s*%(%s*[\'"][Ss]idebar', 1, false)
            or line:find('BeginChild%s*%(%s*[\'"]left', 1, false)
            or line:find('BeginChild%s*%(%s*[\'"]Left', 1, false) then
            stats.sidebars = stats.sidebars + 1
        end
        if line:find('content%s*%[', 1, false) or line:find('getPageForRml', 1, true)
            or line:find('navGroups', 1, true) then
            stats.content_calls = stats.content_calls + 1
        end
        if line:find('%.Icon%s*%(', 1, false) or line:find('resolveEqItemIcon', 1, true)
            or line:find('item_icon_img', 1, true)
            or line:find('DrawTextureAnimation', 1, true)
            or line:find('A_DragItem', 1, true)
            or line:find('SetTextureCell', 1, true)
            or line:find('FindTextureAnimation', 1, true) then
            stats.item_icons = stats.item_icons + 1
        end

        local popup = line:match('BeginPopupModal%s*%(%s*[\'"]([^\'"]+)')
            or line:match('BeginPopup%s*%(%s*[\'"]([^\'"]+)')
        local begin = line:match('[Ii]m[Gg]ui%.Begin%s*%(%s*[\'"]([^\'"]+)')
        if popup then
            push_win(); cur = new_window(vis(popup), 'popup'); tab, section, menu = nil, nil, nil
            tab_depth = 0
            stats.begins = stats.begins + 1
        elseif begin then
            push_win(); cur = new_window(vis(begin), 'main'); tab, section, menu = nil, nil, nil
            tab_depth = 0
            stats.begins = stats.begins + 1
        end

        if line:find('BeginTabBar%s*%(', 1, false) then
            tab_depth = tab_depth + 1
            if tab_depth == 1 then tabbar_win = cur end
        end
        if line:find('EndTabBar', 1, true) then
            tab_depth = math.max(0, tab_depth - 1)
        end

        local modeId, modeLabel = line:match('drawModeTab%s*%(%s*[\'"]([^\'"]+)[\'"]%s*,%s*[\'"]([^\'"]+)')
        if modeId then
            cur.mode_tabs[#cur.mode_tabs + 1] = { id = modeId, label = vis(modeLabel or modeId) }
            stats.mode_tabs = stats.mode_tabs + 1
            stats.primary_tabs = stats.primary_tabs + 1
        end

        local tabLabel = line:match('BeginTabItem%s*%(%s*[\'"]([^\'"]+)')
            or line:match('BeginTabItem%s*%(%s*string%.format%s*%(%s*[\'"]([^\'"]+)')
        if not tabLabel and line:find('BeginTabItem%s*%(', 1, false) then
            -- Concatenated labels: Icons.X .. " Loot Rules Editor"
            local last
            for q in line:gmatch('[\'"]([^\'"]+)[\'"]') do last = q end
            if last and vis(last) ~= '' then tabLabel = last end
        end
        if tabLabel then
            local clean = vis(tabLabel)
            if tab_depth <= 1 then
                -- Primary tab. Depth 0 = TabItem lives in another file after EndTabBar
                -- in the concatenated blob — attach to the window that owned the TabBar.
                -- Per-file VIEW scrape: never pin tabs onto a popup that appeared earlier
                -- in the same module (SmartLoot ui_loot_rules / ui_settings).
                local host_win = cur
                if tab_depth == 0 and tabbar_win and tabbar_win.kind ~= 'popup' then
                    host_win = tabbar_win
                    cur = tabbar_win
                elseif tab_depth == 0 and (not tabbar_win or cur.kind == 'popup') then
                    push_win()
                    cur = new_window(clean ~= '' and clean or 'Main', 'main')
                    tabbar_win = cur
                    host_win = cur
                    tab, section, menu = nil, nil, nil
                end
                tab = new_bucket()
                tab.label = clean
                tab.sections = {}
                tab.primary = true
                local icn = line:match('Icons%.([A-Z0-9_]+)')
                if icn then tab.icon, tab.glyph = icn, ICON_GLYPH[icn]; stats.icons = stats.icons + 1 end
                host_win.tabs[#host_win.tabs + 1] = tab
                section = nil
                stats.tabs = stats.tabs + 1
                stats.primary_tabs = stats.primary_tabs + 1
            else
                -- Nested tab → section under current primary tab
                stats.nested_tabs = stats.nested_tabs + 1
                local parent = tab or cur
                section = new_bucket()
                section.label = clean
                section.open = true
                parent.sections = parent.sections or {}
                parent.sections[#parent.sections + 1] = section
                stats.sections = stats.sections + 1
            end
        end
        if line:find('EndTabItem', 1, true) then
            if tab_depth <= 1 then
                section = nil
                tab = nil
            else
                section = nil
            end
        end

        local hdr = line:match('CollapsingHeader%s*%(%s*[\'"]([^\'"]+)')
            or line:match('TreeNodeEx%s*%(%s*[\'"]([^\'"]+)')
            or line:match('TreeNode%s*%(%s*[\'"]([^\'"]+)')
        if hdr then
            section = new_bucket()
            section.label = vis(hdr)
            section.open = true
            local b = tab or cur
            b.sections = b.sections or {}
            -- Cap sections per tab for complex tools
            if #b.sections < 12 then
                b.sections[#b.sections + 1] = section
                stats.sections = stats.sections + 1
            end
        end

        local menuTitle = line:match('BeginMenu%s*%(%s*[\'"]([^\'"]+)')
        if menuTitle then
            menu = { label = vis(menuTitle), items = {} }
            cur.menus[#cur.menus + 1] = menu
            stats.menus = stats.menus + 1
        end
        local mi = line:match('MenuItem%s*%(%s*[\'"]([^\'"]+)')
        if mi and menu then
            menu.items[#menu.items + 1] = { label = vis(mi) }
        end
        if line:find('EndMenu', 1, true) then menu = nil end

        local bkt = bucket()
        local btnExpr = line:match('[Ii]m[Gg]ui%.Button%s*%(([^%)]*)')
            or line:match('[Ii]m[Gg]ui%.SmallButton%s*%(([^%)]*)')
            or line:match('neonButton%s*%(([^%)]*)')
        if btnExpr then
            local icn = btnExpr:match('Icons%.([A-Z0-9_]+)')
            local label = btnExpr:match('[\'"]([^\'"]+)[\'"]')
            label = vis(label)
            if label == '' and icn then label = icn:gsub('^MD_', ''):gsub('^FA_', ''):gsub('_', ' ') end
            if label ~= '' and #(bkt.buttons or {}) < 24 then
                bkt.buttons[#bkt.buttons + 1] = {
                    label = label, icon = icn, glyph = icn and ICON_GLYPH[icn] or nil,
                }
                stats.buttons = stats.buttons + 1
                if icn then stats.icons = stats.icons + 1 end
            end
        end

        local chk = line:match('[Ii]m[Gg]ui%.Checkbox%s*%(%s*[\'"]([^\'"]+)')
        if chk then add_unique(bkt.checks, chk, 20); stats.checks = stats.checks + 1 end

        local inpMulti = line:match('[Ii]m[Gg]ui%.InputTextMultiline%s*%(%s*[\'"]([^\'"]+)')
        if inpMulti then
            add_unique(bkt.inputs, inpMulti, 16, { multiline = true })
            stats.inputs = stats.inputs + 1
        else
            local inp = line:match('[Ii]m[Gg]ui%.InputText[A-Za-z]*%s*%(%s*[\'"]([^\'"]+)')
            if inp then add_unique(bkt.inputs, inp, 16); stats.inputs = stats.inputs + 1 end
        end

        local combo = line:match('[Ii]m[Gg]ui%.BeginCombo%s*%(%s*[\'"]([^\'"]+)')
            or line:match('[Ii]m[Gg]ui%.Combo%s*%(%s*[\'"]([^\'"]+)')
        if combo then add_unique(bkt.combos, combo, 16) end

        local sel = line:match('[Ii]m[Gg]ui%.Selectable%s*%(%s*[\'"]([^\'"]+)')
        if sel then
            add_unique(bkt.selectables, sel, 40)
            stats.selectables = stats.selectables + 1
        end
        if line:find('Selectable%s*%(', 1, false) and not sel then
            stats.selectables = stats.selectables + 1
        end
    end
    push_win()
    if #wins == 0 then wins[1] = cur end

    -- Table-driven palettes (Grouper ui_elements = { Scatter={ label='Scatter', … } }).
    -- Literal ImGui.Button('x') misses these; harvest labels onto the main window.
    local host_win = wins[1] or cur
    for i = 1, #wins do
        if (wins[i].kind or 'main') ~= 'popup' then host_win = wins[i]; break end
    end
    host_win.buttons = host_win.buttons or {}
    local before_btns = #(host_win.buttons)
    for label in tostring(src or ''):gmatch("label%s*=%s*['\"]([^'\"]+)['\"]") do
        local v = vis(label)
        if v ~= '' and v ~= 'SameLine' and v ~= 'Separator' then
            add_unique(host_win.buttons, v, 48)
        end
    end
    stats.buttons = stats.buttons + math.max(0, #(host_win.buttons) - before_btns)

    -- Prefer the window with the most primary tabs as main
    table.sort(wins, function(a, b) return #(a.tabs or {}) > #(b.tabs or {}) end)

    for i = 1, #wins do
        local w = wins[i]
        if #w.tabs == 0 and #w.mode_tabs > 0 then
            for mi = 1, #w.mode_tabs do
                local t = new_bucket()
                t.label = w.mode_tabs[mi].label
                t.id = w.mode_tabs[mi].id
                t.sections = {}
                t.primary = true
                w.tabs[#w.tabs + 1] = t
            end
        end
    end

    local primary = stats.primary_tabs
    local complex = (stats.src_bytes >= 80000) or (primary >= 6) or (stats.nested_tabs >= 3 and primary >= 4)

    local shape = 'C'
    if stats.sidebars > 0 or stats.content_calls > 0 or (discovered.content and stats.selectables >= 3) then
        shape = 'B'
    elseif primary >= 2 or stats.mode_tabs >= 2 then
        shape = 'A'
    elseif stats.begins >= 2 or stats.windows >= 2 then
        shape = complex and 'A' or 'D'
    elseif stats.selectables >= 8 and stats.buttons <= 6 then
        shape = 'B'
    elseif stats.tabs >= 1 then
        shape = 'A'
    end

    if (stats.sidebars > 0 or discovered.content or stats.content_calls > 0 or stats.lines_tables > 0)
        and (stats.selectables >= 3 or stats.content_calls > 0 or discovered.content) then
        shape = 'B'
    end

    if complex and shape ~= 'B' then shape = 'A' end

    local content_rich = (discovered.content ~= nil)
        or stats.content_calls > 0
        or stats.lines_tables > 0

    return {
        windows = wins,
        stats = stats,
        shape = shape,
        complex = complex,
        discovered = discovered,
        content_rich = content_rich,
    }
end

return M
