--[[
  ProFusion Wiki RmlUi — layout/colors match eqprofusion-wiki-demo, not Mini Wiki.
]]

local host = require('rmlui.host')

local M = {
    win = nil,
    page_id = 'home',
    filter = '',
    _nav_sig = '',
    _page_sig = '',
    _filter_push = nil,
}

local SECTION_ICONS = {
    Server = '✦',
    General = '⚔',
    Progression = '↑',
    Items = '♦',
    Astrial = '✵',
    Epics = '♕',
    MacroQuest = '⚙',
    ['ProFusion Macro'] = '⚛',
}

-- Match live wiki sidebar section order (Home is separate)
local SECTION_ORDER = {
    'General', 'Items', 'Astrial', 'Epics', 'MacroQuest', 'ProFusion Macro', 'Progression', 'Server',
}

local function esc(s) return host.esc(s) end

local function content()
    local ok, mod = pcall(require, 'pfwiki.content')
    if ok then return mod end
    ok, mod = pcall(require, 'content')
    if ok then return mod end
    return nil
end

function M.ensure()
    if M.win and M.win:is_open() then return true end
    local win, err = host.open('ProFusionWiki', 'pfwiki/ui/main.rml', {
        width = 1180, height = 820, theme = 'redguides', title = 'EverQuest ProFusion',
        reload = true,
    })
    if not win then
        print('[ProFusion Wiki] Rml failed: ' .. tostring(err))
        return false
    end
    win:text('window-title', 'EverQuest ProFusion')
    win:class('body', 'pinned', false)
    win:class('body', 'pf-wiki', true)
    M.win = win
    M._nav_sig = ''
    M._page_sig = ''
    local c = content()
    if c and c.defaultPageId then
        M.page_id = c.defaultPageId()
    end
    return true
end

function M.close()
    if M.win then M.win:close(); M.win = nil end
end

function M.show(v)
    if M.win then M.win:show(v ~= false) end
end

function M.hide_all() M.show(false) end

local function match(label, filter)
    if not filter or filter == '' then return true end
    return tostring(label or ''):lower():find(filter:lower(), 1, true) ~= nil
end

local function ordered_groups(c)
    local groups = (c and c.navGroups and c.navGroups()) or {}
    local by = {}
    for i = 1, #groups do
        by[groups[i].title] = groups[i]
    end
    local out = {}
    local used = {}
    for _, name in ipairs(SECTION_ORDER) do
        if by[name] then
            out[#out + 1] = by[name]
            used[name] = true
        end
    end
    for i = 1, #groups do
        local g = groups[i]
        if not used[g.title] then
            out[#out + 1] = g
        end
    end
    return out
end

local function render_nav(c)
    local parts = {}
    local home_on = (M.page_id == 'home') and ' on' or ''
    if match('Home', M.filter) or M.filter == '' then
        parts[#parts + 1] = string.format(
            '<div class="nav-home%s" action="page:home">⌂ Home</div>', home_on)
    end

    local any = (#parts > 0)
    local groups = ordered_groups(c)
    for gi = 1, #groups do
        local g = groups[gi]
        local group_parts = {}
        for _, item in ipairs(g.items or {}) do
            if item.id == 'home' then
                -- shown above
            elseif match(item.label, M.filter) then
                local on = (item.id == M.page_id) and ' on' or ''
                group_parts[#group_parts + 1] = string.format(
                    '<div class="nav-item%s" action="page:%s">%s</div>',
                    on, esc(item.id), esc(item.label))
            end
        end
        if #group_parts > 0 then
            any = true
            local ic = SECTION_ICONS[g.title or ''] or '·'
            parts[#parts + 1] = string.format(
                '<div class="nav-group"><span class="ic">%s</span>%s</div>',
                esc(ic), esc(g.title or ''))
            for i = 1, #group_parts do
                parts[#parts + 1] = group_parts[i]
            end
        end
    end
    if not any then
        parts[1] = '<div class="hint">No pages match.</div>'
    end
    return table.concat(parts)
end

local KIND_CLASS = {
    h1 = 'page-h1',
    h2 = 'page-h2',
    h3 = 'page-h3',
    h4 = 'page-h3',
    p = 'page-p',
    kv = 'page-kv',
    label = 'page-label',
    li = 'page-li',
    warn = 'page-warn',
    cmd = 'page-cmd',
    th = 'page-th',
    td = 'page-td',
    gap = 'page-gap',
}

local function render_table_row(block)
    local cells = block.cells or {}
    if #cells == 0 then return '' end
    local head = (block.k == 'trh')
    local n = math.min(#cells, 6)
    local row_cls = head and ('tbl-row head cols-' .. n) or ('tbl-row cols-' .. n)
    local cell_cls = head and 'tbl-cell head' or 'tbl-cell'
    local parts = { string.format('<div class="%s">', row_cls) }
    for i = 1, #cells do
        parts[#parts + 1] = string.format(
            '<div class="%s">%s</div>', cell_cls, cells[i] or '')
    end
    parts[#parts + 1] = '</div>'
    return table.concat(parts)
end

local function render_block(block)
    if type(block) == 'string' then
        if block == '' then return '<div class="page-gap"></div>' end
        return string.format('<div class="page-p">%s</div>', esc(block))
    end
    if type(block) ~= 'table' then return '' end
    local k = block.k or 'p'
    if k == 'gap' then return '<div class="page-gap"></div>' end
    if k == 'tr' or k == 'trh' then
        return render_table_row(block)
    end
    local cls = KIND_CLASS[k] or 'page-p'
    local inner = block.r
    if inner == nil or inner == '' then
        inner = esc(block.x or block.text or '')
    end
    if k == 'li' then
        return string.format('<div class="%s">◆ %s</div>', cls, inner)
    end
    return string.format('<div class="%s">%s</div>', cls, inner)
end

local HOME_BLURBS = {
    General = 'Start here: rules, setup and the server at a glance',
    Items = 'Prestige gear, boosts and notable loot',
    Astrial = 'The Astrial weapon and its infusions',
    Epics = 'Epic 1.0 through 6.0 and their augments',
    MacroQuest = 'MQ2 tips and built-in macros',
    ['ProFusion Macro'] = 'The ProFusion macro, explained',
    Progression = 'Level guides, tiers and raid gear',
    Server = 'Server home and overview',
}

local function extract_section_blocks(lines, start_pat, stop_pats)
    local out = {}
    local capturing = false
    for i = 1, #(lines or {}) do
        local b = lines[i]
        local k = type(b) == 'table' and b.k or nil
        local text = ''
        if type(b) == 'table' then
            text = tostring(b.r or '')
            if b.cells then
                text = table.concat(b.cells, ' ')
            end
        end
        local plain = text:gsub('<[^>]+>', '')
        if not capturing then
            if k and k:match('^h%d$') and plain:lower():find(start_pat, 1, true) then
                capturing = true
                out[#out + 1] = b
            end
        else
            if k and k:match('^h[123]$') then
                local stop = false
                local pl = plain:lower()
                for si = 1, #stop_pats do
                    if pl:find(stop_pats[si], 1, true) then
                        stop = true
                        break
                    end
                end
                if stop then break end
            end
            out[#out + 1] = b
        end
    end
    return out
end

local function render_lines(lines)
    local parts = {}
    local in_table = false
    for i = 1, #(lines or {}) do
        local block = lines[i]
        local k = type(block) == 'table' and block.k or nil
        if k == 'tr' or k == 'trh' then
            if not in_table then
                parts[#parts + 1] = '<div class="tbl">'
                in_table = true
            end
            parts[#parts + 1] = render_block(block)
        else
            if in_table then
                parts[#parts + 1] = '</div>'
                in_table = false
            end
            local html = render_block(block)
            if html ~= '' then
                parts[#parts + 1] = html
            end
        end
    end
    if in_table then
        parts[#parts + 1] = '</div>'
    end
    return parts
end

local function render_home(c, page)
    local n = (c and c.pageCount and c.pageCount()) or 51
    local lines = (page and page.lines) or {}
    local parts = {
        '<div class="home-hero">',
        '<div class="home-eyebrow">Archive of Norrath · RoF2 Emulator</div>',
        '<div class="home-title">EverQuest <span class="gold">ProFusion</span></div>',
        '<div class="home-lede">Guides, gear tiers, epics and Timekeeper Credits — the complete ProFusion wiki, restored.</div>',
        '<div class="home-cta" action="page:General__Getting_Started">Begin your journey</div>',
        '<div class="home-stats">',
        string.format('<div><div class="home-stat-num">%d</div><div class="home-stat-lbl">pages</div></div>', n),
        string.format('<div><div class="home-stat-num">%d</div><div class="home-stat-lbl">home blocks</div></div>', #lines),
        '<div><div class="home-stat-num">T1–T10</div><div class="home-stat-lbl">gear tiers</div></div>',
        '</div></div>',
    }

    -- Quick reference UP TOP so Class / Epic tables are visible without scrolling past cards
    local epic = extract_section_blocks(lines, 'epic weapons', { 'other', 'astrial', 'macroquest', 'class overview', 'augments', 'zone', 'progression zones' })
    local class = extract_section_blocks(lines, 'class overview', { 'augments', 'zone short', 'progression zones' })
    if #epic > 0 or #class > 0 then
        parts[#parts + 1] = '<div class="home-rule">Quick reference</div>'
        if #epic > 0 then
            local body = render_lines(epic)
            for i = 1, #body do parts[#parts + 1] = body[i] end
        end
        if #class > 0 then
            local body = render_lines(class)
            for i = 1, #body do parts[#parts + 1] = body[i] end
        end
    end

    parts[#parts + 1] = '<div class="home-rule">Explore the archives</div>'
    parts[#parts + 1] = '<div class="card-grid">'

    local groups = ordered_groups(c)
    for gi = 1, #groups do
        local g = groups[gi]
        local title = g.title or ''
        if title ~= 'Server' then
            local items = g.items or {}
            local ic = SECTION_ICONS[title] or '·'
            local blurb = HOME_BLURBS[title] or ''
            parts[#parts + 1] = '<div class="sec-card">'
            parts[#parts + 1] = string.format('<div class="sec-card-ic">%s</div>', esc(ic))
            parts[#parts + 1] = string.format('<div class="sec-card-count">%d pages</div>', #items)
            parts[#parts + 1] = string.format('<div class="sec-card-title">%s</div>', esc(title))
            parts[#parts + 1] = string.format('<div class="sec-card-blurb">%s</div>', esc(blurb))
            local max_links = 5
            for i = 1, math.min(#items, max_links) do
                local it = items[i]
                if it.id ~= 'home' then
                    parts[#parts + 1] = string.format(
                        '<div class="sec-card-link" action="page:%s">◆ %s</div>',
                        esc(it.id), esc(it.label))
                end
            end
            if #items > max_links then
                parts[#parts + 1] = string.format(
                    '<div class="sec-card-more">+%d more in sidebar</div>', #items - max_links)
            end
            parts[#parts + 1] = '</div>'
        end
    end
    parts[#parts + 1] = '</div>'
    return table.concat(parts)
end

local function render_page(c)
    local page = (c and c.getPage and c.getPage(M.page_id))
        or { title = 'ProFusion Wiki', section = '', lines = { { k = 'p', r = 'No content.' } } }

    if M.page_id == 'home' then
        -- Hero + Class/Epic grids first, then cards, then rest of original home page
        local parts = { render_home(c, page) }
        parts[#parts + 1] = '<div class="home-rule">From the original home page</div>'
        local body = render_lines(page.lines)
        for i = 1, #body do
            parts[#parts + 1] = body[i]
        end
        if #(page.lines or {}) == 0 then
            parts[#parts + 1] = '<div class="page-warn">Home content missing — luaDir may not be mq2-rmlui/lua. Check chat for [pfwiki] luaDir=</div>'
        end
        return page, table.concat(parts), 'EverQuest ProFusion'
    end

    local parts = render_lines(page.lines)
    if #parts == 0 then
        parts[1] = '<div class="page-p">No content.</div>'
    end
    return page, table.concat(parts), page.title or M.page_id
end

function M.tick(api)
    if not M.ensure() then return false end
    local c = content()

    host.tick(M.win, {
        close = function()
            if api and api.set_open then api.set_open(false) else M.show(false) end
        end,
        closed = function()
            if api and api.set_open then api.set_open(false) end
        end,
        action = function(a)
            local id = a:match('^page:(.+)$')
            if id then
                M.page_id = id
                M._page_sig = ''
                M._nav_sig = ''
            end
        end,
        change = function(ev)
            if ev.id == 'filter' then
                M.filter = ev.value or ''
                M._nav_sig = ''
            end
        end,
        update = function(w)
            local page, body, title = render_page(c)
            local sec = page.section
            if M.page_id == 'home' or sec == '' then sec = 'Home' end
            w:text('chip_sec', sec)
            w:text('st_pages', tostring((c and c.pageCount and c.pageCount()) or 0))
            w:text('status', 'Ready.')

            if M._filter_push ~= M.filter then
                w:set_value('filter', M.filter)
                M._filter_push = M.filter
            end

            local nav = render_nav(c)
            if nav ~= M._nav_sig then
                M._nav_sig = nav
                w:rml('nav', nav)
            end

            local sig = M.page_id .. '\n' .. body
            if sig ~= M._page_sig then
                M._page_sig = sig
                w:text('page_title', title)
                w:rml('page', body)
            end
        end,
    })
    return true
end

return M
