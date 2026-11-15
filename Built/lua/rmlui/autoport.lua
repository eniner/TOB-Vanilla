--[[
  AutoPort v4.13 — copy-based ImGui → RmlUi converter.

  COPY-BASED: originals are never mutated. Apply writes under lua/ports/<pack>/
  and you run the copy with /lua run ports/<pack>. Live scripts stay ImGui.

  Follows launcher stubs (ezquests.lua → nested init). TreeNode/multiline are
  SOFT. Theme hrefs are computed from RML folder depth. Table-driven labels
  are harvested. Native rml_ui.lua (including nested packages) is activated,
  never scraped over.

  RmlUi host: no inherit, no Consolas-without-load, no <textarea>, no
  display:none around inputs (.tab-host), toggle labels in <span>.

  This is a structure scraper + template/VIEW emitter, not an ImGui compiler.
  Split packages (ui/*.lua draw() tabs) go to VIEW. Template A/B/C/D only when
  coverage PASSES on a single-file UI. Hand ports (no AUTO_PORT_VER) are kept.

  Apply ALWAYS rebuilds AutoPort-generated ports (never keeps a stale copy).
]]

local mq = require('mq')
local analyze = require('rmlui.autoport.analyze')
local emit = require('rmlui.autoport.emit')
local inj = require('rmlui.autoport.inject')
local coverage = require('rmlui.autoport.coverage')

local M = { version = '4.13', PORT_VER = emit.AUTO_PORT_VER or 16 }

local LOG, LOG_MAX = {}, 140

function M.log(level, msg)
    msg = tostring(msg or '')
    LOG[#LOG + 1] = { t = os.date('%H:%M:%S'), level = tostring(level or 'info'), msg = msg }
    while #LOG > LOG_MAX do table.remove(LOG, 1) end
    print('[autoport] ' .. msg)
end

function M.logs() return LOG end
function M.clear_log() LOG = {} end
function M.active() return true end
function M.hijack() return M end
function M.restore() end
function M.close_all() end
function M.set_replace() end
function M.sessions() return {} end

local function norm(p)
    return tostring(p or ''):gsub('\\', '/')
end

local function pack_of(rel)
    rel = norm(rel)
    local dir, file = rel:match('^(.+)/([^/]+)$')
    if file == 'init.lua' or file == 'ui_core.lua' then
        return dir
    end
    local stem = (file or rel):gsub('%.lua$', '')
    return stem:lower()
end

local function port_paths(rel)
    local pack = pack_of(rel)
    local port_pack = 'ports/' .. pack
    return {
        pack = pack,
        port_pack = port_pack,
        port_rel = port_pack .. '/init.lua',
        req = port_pack:gsub('/', '.') .. '.rml_ui',
        rml_rel = port_pack .. '/ui/main.rml',
        lua_path_suffix = port_pack .. '/rml_ui.lua',
    }
end

local function read_file(path) return inj.read_file(path) end
local function write_file(path, s) return inj.write_file(path, s) end

--- Strip ONLY AutoPort inject markers. Never touch native USE_RML / rml_ui that
--- a script already ships (GearScoreX, Transmute, etc.). Never invent edits.
local function scrub_original(src)
    if not src then return src, false end
    local out = inj.strip_hijack(src)
    local board = inj.strip_board_stub(out)
    if board ~= out then out = board end
    -- Remove ONLY the exact AutoPort tick early-return inject (not native rml_ui.poll/update)
    local n
    out, n = out:gsub(
        "\r?\n%s*if%s+USE_RML%s+and%s+rml_ui%s+then%s*\r?\n%s*rml_ui%.tick%s*%(%s*%)%s*\r?\n%s*return%s*\r?\n%s*end%s*",
        '\n')
    local changed = out ~= src
    return out, changed
end

--- Apply never mutates originals. If an old inject is present, scrub in-memory for
--- analysis only — write back ONLY when syntax-valid AND content actually had markers.
local function maybe_restore_original(path, src)
    if not src then return src end
    local cleaned, scrubbed = scrub_original(src)
    if not scrubbed then return src end
    local ok, err = inj.validate_lua(cleaned, path)
    if not ok then
        M.log('err', 'scrub refused (would break syntax)  ·  ' .. tostring(path) .. '  ·  ' .. tostring(err))
        return src
    end
    -- Only write if we removed a known hijack/board/tick inject marker
    local had_marker = src:find('rmlui.autoport', 1, true)
        or src:find('rmlui.board', 1, true)
        or src:find("rml_ui.tick()\n        return", 1, true)
        or src:find("rml_ui.tick(); return", 1, true)
    if not had_marker then
        M.log('info', 'left original alone (no AutoPort inject markers)  ·  ' .. tostring(path))
        return src
    end
    if write_file(path, cleaned) then
        M.log('ok', 'restored original (removed AutoPort inject)  ·  ' .. tostring(path))
        return cleaned
    end
    return src
end

function M.parse_imgui(src)
    return analyze.parse(src, {})
end

function M.preview(rel, root)
    root = norm(root or mq.luaDir or '.')
    rel = tostring(rel or ''):gsub('\\', '/')
    local blob, discovered = analyze.collect_sources(root, rel, read_file)
    local model = analyze.parse(blob, discovered)
    model.coverage = coverage.scan(blob)
    return model
end

function M.coverage_report(rel, root)
    root = norm(root or mq.luaDir or '.')
    rel = tostring(rel or ''):gsub('\\', '/')
    local blob = select(1, analyze.collect_sources(root, rel, read_file))
    local cov = coverage.scan(blob)
    local pack = pack_of(rel)
    return cov, coverage.format_report(cov, pack, pack)
end

local function is_stale_stub(lua_src, rml_src)
    if not lua_src and not rml_src then return true end
    -- Body <style> = broken emit (Rml paints CSS as text) — always rebuild
    if rml_src and rml_src:find('</head>', 1, true) then
        local body = rml_src:match('</head>(.*)')
        if body and body:find('<style', 1, true) then return true end
    end
    if lua_src and lua_src:find('shape=UNSUPPORTED', 1, true) then return true end
    if inj.is_hand_port(lua_src) then return false end
    -- Any AutoPort stub not at current VER must rebuild
    if lua_src and lua_src:find('AUTO_PORT_VER', 1, true) then
        if not lua_src:find('AUTO_PORT_VER%s*=%s*' .. tostring(M.PORT_VER)) then
            return true
        end
        return false
    end
    if lua_src and inj.is_autoport_generated(lua_src) then return true end
    if rml_src and (rml_src:find('AutoPort', 1, true) or rml_src:find('Rml port', 1, true))
        and not rml_src:find('AUTO_PORT_VER=' .. tostring(M.PORT_VER), 1, true) then
        return true
    end
    return lua_src == nil or rml_src == nil
end

local function bust_port_cache(pp)
    local req = pp.req
    if package.loaded[req] then package.loaded[req] = nil end
    local alt = req:gsub('%.', '/')
    if package.loaded[alt] then package.loaded[alt] = nil end
end

local function activate_port(pp, classic)
    classic = tostring(classic or pp.pack or '')
    local port = pp.port_pack
    if classic ~= '' and classic ~= port then
        pcall(function() mq.cmdf('/lua stop %s', classic) end)
    end
    pcall(function() mq.cmdf('/lua stop %s', port) end)
    bust_port_cache(pp)
    mq.cmdf('/lua run %s', port)
    M.log('ok', 'ACTIVATED port  ·  stopped ' .. classic .. '  ·  /lua run ' .. port)
end

local function slim_window(w, wi)
    local tabs = {}
    for ti = 1, math.min(16, #(w.tabs or {})) do
        local t = w.tabs[ti]
        local btns, chks, secs, inps = {}, {}, {}, {}
        for bi = 1, math.min(14, #(t.buttons or {})) do
            btns[#btns + 1] = (t.buttons[bi].label or t.buttons[bi])
        end
        for ci = 1, math.min(10, #(t.checks or {})) do
            chks[#chks + 1] = (t.checks[ci].label or t.checks[ci])
        end
        for si = 1, math.min(10, #(t.sections or {})) do
            secs[#secs + 1] = (t.sections[si].label or ('Section ' .. si))
        end
        for ii = 1, math.min(8, #(t.inputs or {})) do
            inps[#inps + 1] = t.inputs[ii]
        end
        tabs[#tabs + 1] = {
            label = t.label or ('Tab ' .. ti),
            buttons = btns, checks = chks, sections = secs, inputs = inps,
        }
    end
    local wbtns, wchks, wsecs, winps = {}, {}, {}, {}
    for bi = 1, math.min(14, #(w.buttons or {})) do
        wbtns[#wbtns + 1] = (w.buttons[bi].label or w.buttons[bi])
    end
    for ci = 1, math.min(10, #(w.checks or {})) do
        wchks[#wchks + 1] = (w.checks[ci].label or w.checks[ci])
    end
    for si = 1, math.min(10, #(w.sections or {})) do
        wsecs[#wsecs + 1] = (w.sections[si].label or ('Section ' .. si))
    end
    for ii = 1, math.min(8, #(w.inputs or {})) do
        winps[#winps + 1] = w.inputs[ii]
    end
    return {
        title = w.title or ('Window ' .. wi),
        tabs = tabs,
        buttons = wbtns, checks = wchks, sections = wsecs, inputs = winps,
    }
end

local function scrape_slash_cmds(src)
    local cmds, seen = {}, {}
    for line in tostring(src or ''):gmatch('[^\r\n]+') do
        local c = line:match('(/[%w_]+%s+show[%w_]*)')
            or line:match('(/[%w_]+%s+popup[%w_]*)')
            or line:match('(/[%w_]+%s+toggle[%w_]*)')
        if c and not seen[c] then
            seen[c] = true
            cmds[#cmds + 1] = c
            if #cmds >= 5 then break end
        end
    end
    return cmds
end

--- Rich modules for VIEW: each module lists its ImGui windows + tabs (not empty shells).
--- view_panels is a FALLBACK when no ui/Modules files exist (LEM). Never skip a real scrape.
local function discover_view_modules(root, rel, tool)
    local modules = {}
    local dir = tostring(rel or ''):match('^(.+)/[^/]+$')
    if not dir then dir = pack_of(rel) end
    local files, seen = {}, {}
    local SKIP = {
        template = true, ui_utils = true, ui_theme = true, utils = true,
        util = true, dkjson = true, json = true, common = true, colors = true,
        write = true, base64 = true, persistence = true,
    }
    local function add_dir(sub)
        local mod_dir = root .. '/' .. dir .. '/' .. sub
        local p = io.popen('dir /b "' .. mod_dir:gsub('/', '\\') .. '\\*.lua" 2>nul')
        if not p then return 0 end
        local n = 0
        for line in p:lines() do
            local name = line:match('^(.+)%.lua$')
            local key = name and name:lower() or ''
            if name and not SKIP[key] and not seen[key] then
                seen[key] = true
                files[#files + 1] = { name = name, path = dir .. '/' .. sub .. '/' .. name .. '.lua' }
                n = n + 1
            end
        end
        p:close()
        return n
    end
    -- Prefer ui/ (SmartLoot) over engine modules/ (database, engine, …).
    local ui_n = add_dir('ui') + add_dir('UI')
    if ui_n == 0 then
        add_dir('Modules'); add_dir('modules'); add_dir('Module')
    end
    table.sort(files, function(a, b) return a.name:lower() < b.name:lower() end)

    local function title_case(name)
        local s = tostring(name or ''):gsub('^ui[_%-]?', ''):gsub('^UI[_%-]?', ''):gsub('[_%-]+', ' ')
        return s:gsub('(%a)([%w]*)', function(a, b) return a:upper() .. b:lower() end)
    end

    local host_src = read_file(root .. '/' .. rel)
    if host_src then
        local model = analyze.parse(host_src, {})
        local wins = {}
        for wi = 1, math.min(6, #(model.windows or {})) do
            wins[#wins + 1] = slim_window(model.windows[wi], wi)
        end
        if #wins == 0 then
            wins[1] = { title = 'Main', tabs = {}, buttons = {}, checks = {}, sections = { 'Modules' } }
        end
        modules[#modules + 1] = {
            id = 'host',
            label = (tool and tool.label) or pack_of(rel),
            windows = wins,
            cmds = {},
            is_host = true,
        }
    end

    for i = 1, #files do
        local f = files[i]
        local src = read_file(root .. '/' .. f.path) or ''
        local nice = src:match("Module%.Name%s*=%s*['\"]([^'\"]+)['\"]")
            or title_case(f.name)
        local model = analyze.parse(src, {})
        local wins = {}
        for wi = 1, math.min(8, #(model.windows or {})) do
            local sw = slim_window(model.windows[wi], wi)
            if sw.title == 'Window' then
                sw.title = (sw.tabs[1] and sw.tabs[1].label) or nice
            end
            if sw.title ~= 'Window' or #(model.windows or {}) == 1 then
                wins[#wins + 1] = sw
            end
        end
        if #wins == 0 then
            wins[1] = { title = nice, tabs = {}, buttons = {}, checks = {}, sections = {} }
        end
        modules[#modules + 1] = {
            id = f.name:lower():gsub('[^a-z0-9]+', '_'),
            label = nice,
            windows = wins,
            cmds = scrape_slash_cmds(src),
        }
    end

    -- Named sidebar panels (LEM). Never wipe a real host scrape into empty shells.
    if #files == 0 and tool and tool.view_panels then
        local leftover = {}
        for i = 1, #modules do
            for wi = 1, #(modules[i].windows or {}) do
                leftover[#leftover + 1] = modules[i].windows[wi]
            end
        end
        local function has_meat(w)
            if not w then return false end
            return #(w.tabs or {}) > 0 or #(w.buttons or {}) > 0 or #(w.checks or {}) > 0
                or #(w.inputs or {}) > 0 or #(w.sections or {}) > 0
        end
        local function take_named(name)
            local nl = tostring(name or ''):lower()
            for i = 1, #leftover do
                local w = leftover[i]
                local t = tostring(w.title or ''):lower()
                if t ~= '' and (t:find(nl, 1, true) or nl:find(t, 1, true)) then
                    return table.remove(leftover, i)
                end
                for ti = 1, #(w.tabs or {}) do
                    local tl = tostring(w.tabs[ti].label or ''):lower()
                    if tl ~= '' and (tl:find(nl, 1, true) or nl:find(tl, 1, true)) then
                        return {
                            title = w.tabs[ti].label or name,
                            tabs = { w.tabs[ti] },
                            buttons = w.buttons or {},
                            checks = w.checks or {},
                            sections = w.tabs[ti].sections or w.sections or {},
                        }
                    end
                end
            end
            return nil
        end
        local built = {}
        for i = 1, #tool.view_panels do
            local name = tool.view_panels[i]
            local w = take_named(name)
            if not has_meat(w) then
                for li = 1, #leftover do
                    if has_meat(leftover[li]) then
                        w = table.remove(leftover, li)
                        break
                    end
                end
            end
            built[#built + 1] = {
                id = tostring(name):lower():gsub('[^a-z0-9]+', '_'),
                label = name,
                windows = { w or { title = name, tabs = {}, buttons = {}, checks = {}, sections = {} } },
                cmds = (modules[1] and modules[1].cmds) or {},
            }
        end
        for i = 1, #leftover do
            if has_meat(leftover[i]) then
                local w = leftover[i]
                built[#built + 1] = {
                    id = tostring(w.title or ('win' .. i)):lower():gsub('[^a-z0-9]+', '_'),
                    label = w.title or ('Window ' .. i),
                    windows = { w },
                    cmds = {},
                }
            end
        end
        if #built > 0 then modules = built end
    end

    if #modules == 0 then
        modules[1] = {
            id = 'main', label = 'Main',
            windows = { { title = 'Main', tabs = {}, buttons = {}, checks = {}, sections = {} } },
            cmds = {},
        }
    end
    return modules
end

local function discover_view_panels(root, rel, tool)
    local mods = discover_view_modules(root, rel, tool)
    local panels = {}
    for i = 1, #mods do panels[i] = mods[i].label end
    return panels
end

local function native_rml_pack(root, rel)
    rel = tostring(rel or ''):gsub('\\', '/')
    local pack = pack_of(rel)
    -- GearScoreX.lua → GearScoreX/rml_ui.lua
    if read_file(root .. '/' .. pack .. '/rml_ui.lua') then
        return pack
    end
    -- foo/init.lua → foo/rml_ui.lua
    local dir = rel:match('^(.+)/[^/]+$')
    if dir and read_file(root .. '/' .. dir .. '/rml_ui.lua') then
        return dir
    end
    -- TOOLS.native_dir (ezquests.lua → EZQuests-main/EZQuests-main)
    for i = 1, #(M.TOOLS or {}) do
        local t = M.TOOLS[i]
        if t.rel == rel and t.native_dir and read_file(root .. '/' .. t.native_dir .. '/rml_ui.lua') then
            return t.native_dir
        end
    end
    -- loadfile / package.path stubs → look next to the real init.lua
    local src = read_file(root .. '/' .. rel)
    if src then
        local scan_rel, _, followed = analyze.resolve_entry(root, rel, src, read_file)
        if followed then
            local ndir = tostring(scan_rel):match('^(.+)/[^/]+$')
            if ndir and read_file(root .. '/' .. ndir .. '/rml_ui.lua') then return ndir end
        end
    end
    return nil
end

local function is_complex_source(src)
    if not src then return true end
    if #src >= 100000 then return true end -- ~100KB — too big to load as a port shim
    local _, n_init = src:gsub('mq%.imgui%.init', '')
    if n_init > 1 then return true end
    -- Top-level game loop after imgui.init will hang the runner forever
    if src:find('while%s+', 1, false) and src:find('mq%.delay', 1, false) and #src >= 40000 then
        return true
    end
    return false
end

--- Safe scaffold runner: opens Rml UI only. Never load()s the original init
--- (that hangs complex tools like Lua Console and can spawn invisible blockers).
local function emit_port_runner(pp, label, orig_rel, complex)
    local note = complex
        and 'VIEW port — module windows/tabs scraped into Rml. Open Module runs classic slash cmds.'
        or 'Scaffold port — original package untouched.'
    return table.concat({
        '--[[\n',
        '  AutoPort COPY under ', pp.port_pack, '\n',
        '  Original: ', orig_rel, ' (untouched)\n',
        '  Run:  /lua run ', pp.port_pack, '\n',
        '  Stop: /lua stop ', pp.port_pack, '\n',
        '  ', note, '\n',
        ']]\n',
        "local mq = require('mq')\n",
        'local running = true\n',
        "package.loaded['", pp.req, "'] = nil\n",
        "local ok, rml_ui = pcall(require, '", pp.req, "')\n",
        'if not ok then\n',
        "    print('[autoport] ", label, " port UI failed: ' .. tostring(rml_ui))\n",
        '    return\n',
        'end\n\n',
        "print('[autoport] ", label, " port open → /lua stop ", pp.port_pack, "')\n",
        "print('[autoport] ", note, "')\n",
        "print('[autoport] classic original: /lua run ", pp.pack, "')\n\n",
        "mq.imgui.init('AutoPort_", pp.pack:gsub('[^%w]', '_'), "', function()\n",
        '    if not running then return end\n',
        '    local okTick, err = pcall(function()\n',
        '        rml_ui.tick({\n',
        "            status = function() return '", note:gsub("'", ''), "' end,\n",
        '            refreshTab = function(w, t)\n',
        "                return string.format('<div class=\"live-line\">%s · tab %d</div>',\n",
        "                    '", label:gsub("'", ''), "', tonumber(t) or 1)\n",
        '            end,\n',
        '        })\n',
        '    end)\n',
        "    if not okTick then print('[autoport] tick error: ' .. tostring(err)) end\n",
        'end)\n\n',
        "while running and mq.TLO.MacroQuest.GameState() == 'INGAME' do\n",
        '    mq.doevents()\n',
        '    mq.delay(50)\n',
        'end\n',
        'running = false\n',
        'pcall(function() if rml_ui.close then rml_ui.close() end end)\n',
    })
end

function M.convert(rels, root, opts)
    opts = opts or {}
    -- Apply always rebuilds AutoPort stubs. force=true is explicit Rebuild.
    local force = opts.force ~= false
    root = norm(root or mq.luaDir or '.')
    local ok, skip = {}, {}
    local by_rel = {}
    for i = 1, #M.TOOLS do by_rel[M.TOOLS[i].rel] = M.TOOLS[i] end

    inj.mkdir(root .. '/ports')

    for _, rel in ipairs(rels or {}) do
        rel = tostring(rel or ''):gsub('\\', '/')
        if rel:match('^ports/') then
            skip[#skip + 1] = rel .. ' (already a port copy — select the original tool)'
        else
            local tool = by_rel[rel] or { label = rel, rel = rel }
            local native = native_rml_pack(root, rel)
            if tool.always or native then
                -- Already has real Rml — never structure-scrape a fake stub
                local classic = tool.run or pack_of(rel)
                ok[#ok + 1] = rel
                M.log('ok', string.format(
                    'NATIVE Rml  ·  /lua run %s%s',
                    classic, native and ('  ·  ' .. native .. '/rml_ui.lua') or ''))
                if classic ~= '' then
                    pcall(function() mq.cmdf('/lua stop %s', classic) end)
                    mq.cmdf('/lua run %s', classic)
                    M.log('ok', 'ACTIVATED native  ·  /lua run ' .. classic)
                end
            else
                local path = root .. '/' .. rel
                local src = read_file(path)
                if not src then
                    skip[#skip + 1] = rel .. ' (missing)'
                else
                    -- Never gut native USE_RML. Only peel AutoPort inject markers, syntax-gated.
                    src = maybe_restore_original(path, src)
                    local scan_rel, scan_src, followed = analyze.resolve_entry(root, rel, src, read_file)
                    if followed then
                        M.log('info', 'followed stub  ·  ' .. rel .. '  →  ' .. scan_rel)
                    end

                    if not (scan_src:find('mq%.imgui%.init', 1, false) or scan_src:find('ImGui%.Register', 1, false)
                        or scan_src:find('[Ii]m[Gg]ui%.Begin%s*%(', 1, false)) then
                        skip[#skip + 1] = rel .. ' (no ImGui init)'
                        M.log('err', 'skip  ·  ' .. rel .. '  ·  no ImGui init after stub follow')
                    else
                        local pp = port_paths(rel)
                        local label = tool.label or pp.pack
                        local lua_path = root .. '/' .. pp.lua_path_suffix
                        local rml_path = root .. '/' .. pp.rml_rel
                        local runner_path = root .. '/' .. pp.port_rel
                        local existing_lua = read_file(lua_path)
                        local existing_rml = read_file(rml_path)

                        -- Hand ports (no AUTO_PORT_VER) are never overwritten — including Lua Console / LEM.
                        local protect_hand = inj.is_hand_port(existing_lua)
                        if protect_hand then
                            ok[#ok + 1] = pp.port_rel
                            M.log('ok', 'hand port kept  ·  /lua run ' .. pp.port_pack)
                            activate_port(pp, tool.run or pp.pack)
                        else
                            local classic = tool.run or pp.pack
                            local blob, discovered = analyze.collect_sources(root, scan_rel, read_file)
                            local cov = coverage.scan(blob)
                            local report = coverage.format_report(cov, label, classic)
                            -- view_model / coverage_gate / split ui/ folders → VIEW.
                            -- Never scrape A* (misses modules) and never activate an empty refuse wall.
                            local want_view = tool.view_model == true or tool.coverage_gate == true
                                or tool.complex == true
                                or (discovered and analyze.has_split_ui(discovered))
                            M.log((cov.ok or want_view) and 'info' or 'err', string.format(
                                'coverage %s · %s (hard_blocked=%d hard_arch=%d soft=%d+%d depth=%d)',
                                label, cov.ok and 'PASS' or 'FAIL',
                                (cov.stats and cov.stats.blocked) or 0,
                                (cov.stats and cov.stats.arch) or 0,
                                (cov.stats and cov.stats.soft_blocked) or 0,
                                (cov.stats and cov.stats.soft_arch) or 0,
                                (cov.stats and cov.stats.max_tab_depth) or 0))
                            local fail_template = (not cov.ok) and not tool.force_template and not want_view
                            local shape_out = nil

                            local regen = force or is_stale_stub(existing_lua, existing_rml)
                            local failed = false
                            local wrote_port = false
                            if regen then
                                inj.mkdir(root .. '/' .. pp.port_pack)
                                inj.mkdir(root .. '/' .. pp.port_pack .. '/ui')
                                write_file(root .. '/' .. pp.port_pack .. '/COVERAGE.md', report)

                                local rml_src, lua_src, shape
                                local emit_ok, emit_err = pcall(function()
                                    if want_view then
                                        local modules = discover_view_modules(root, rel, tool)
                                        local nwin = 0
                                        for mi = 1, #modules do
                                            nwin = nwin + #(modules[mi].windows or {})
                                        end
                                        rml_src, lua_src, shape = emit.emit_view_scaffold(
                                            label, pp.port_pack, classic, modules, {
                                                coverage_ok = cov.ok,
                                                report = report,
                                                soft = (cov.stats and cov.stats.soft_blocked) or 0,
                                                host_cmd = classic,
                                            })
                                        M.log('ok', string.format(
                                            'VIEW scaffold (%d modules / %d windows)%s  ·  %s',
                                            #modules, nwin,
                                            cov.ok and '' or ' — hard FAIL mapped to panels, no fake template',
                                            pp.port_pack))
                                    elseif fail_template then
                                        -- Report only — do not ship as runnable "port"
                                        rml_src, lua_src, shape = emit.emit_coverage(
                                            label, pp.port_pack, classic, cov, report)
                                        M.log('err', 'COVERAGE report only — not activating  ·  '
                                            .. pp.port_pack .. '/COVERAGE.md')
                                    else
                                        local model = analyze.parse(blob, discovered)
                                        if tool.complex or tool.manual or is_complex_source(blob) then
                                            model.complex = true
                                            if model.shape ~= 'B' then model.shape = 'A' end
                                        end
                                        model.coverage = cov
                                        local st = model.stats or {}
                                        M.log('info', string.format(
                                            'scrape %s · shape=%s primary_tabs=%d → %s',
                                            label, model.shape or '?', st.primary_tabs or 0, pp.port_pack))
                                        rml_src, shape = emit.emit_rml(model, label, pp.rml_rel)
                                        model.shape = shape
                                        local safe_name = label:gsub('[^%w]', '')
                                        if safe_name == '' then safe_name = pp.pack:gsub('[^%w]', '') end
                                        lua_src = emit.emit_lua(model, safe_name, pp.rml_rel, label)
                                    end
                                end)
                                shape_out = shape
                                if not emit_ok then
                                    skip[#skip + 1] = rel .. ' (emit crash: ' .. tostring(emit_err) .. ')'
                                    M.log('err', 'emit CRASH  ·  ' .. label .. '  ·  ' .. tostring(emit_err))
                                    failed = true
                                else
                                    local rok, rerr = inj.validate_rml(rml_src)
                                    if not rok then
                                        skip[#skip + 1] = rel .. ' (rml refused: ' .. tostring(rerr) .. ')'
                                        M.log('err', 'refused RML  ·  ' .. label .. '  ·  ' .. tostring(rerr))
                                        failed = true
                                    else
                                        local lok, lerr = inj.validate_lua(lua_src, lua_path)
                                        if not lok then
                                            skip[#skip + 1] = rel .. ' (lua refused: ' .. tostring(lerr) .. ')'
                                            failed = true
                                        else
                                            if not write_file(lua_path, lua_src) or not write_file(rml_path, rml_src) then
                                                skip[#skip + 1] = rel .. ' (write failed)'
                                                failed = true
                                            else
                                                bust_port_cache(pp)
                                                wrote_port = true
                                                M.log('ok', string.format('rebuilt %s  ·  %s', shape, pp.port_pack))
                                            end
                                        end
                                    end
                                end
                            else
                                wrote_port = existing_lua ~= nil
                                if existing_lua and existing_lua:find('shape=COVERAGE', 1, true) then
                                    shape_out = 'COVERAGE'
                                elseif existing_lua and existing_lua:find('shape=VIEW', 1, true) then
                                    shape_out = 'VIEW'
                                end
                                M.log('info', 'kept current VER port  ·  ' .. pp.port_pack)
                            end

                            if not failed then
                                inj.mkdir(root .. '/' .. pp.port_pack)
                                local runner = emit_port_runner(pp, label, rel, fail_template or want_view)
                                if write_file(runner_path, runner) then
                                    bust_port_cache(pp)
                                    -- Never treat a COVERAGE refuse UI as a successful runnable port
                                    if shape_out == 'COVERAGE' then
                                        skip[#skip + 1] = rel .. ' (coverage refuse — classic only)'
                                        M.log('err', 'not activating coverage wall  ·  use classic /lua run ' .. classic)
                                    else
                                        ok[#ok + 1] = pp.port_rel
                                        M.log('ok', 'original untouched  ·  /lua run ' .. pp.port_pack
                                            .. '  ·  classic /lua run ' .. classic)
                                    end
                                else
                                    skip[#skip + 1] = rel .. ' (runner write failed)'
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return ok, skip
end

-- Apply = force rebuild + stop classic + launch ports/X (or native already activated in convert)
function M.apply_ports(rels, root)
    local ok, skip = M.convert(rels, root, { force = true })
    root = norm(root or mq.luaDir or '.')
    for i = 1, #ok do
        local port_rel = ok[i]
        -- Native activations already ran classic in convert; only activate AutoPort copies here
        if tostring(port_rel):match('^ports/') then
            local tool_rel = M.port_to_orig(port_rel) or port_rel
            local pp = port_paths(tool_rel)
            local classic = pack_of(tool_rel)
            for ti = 1, #M.TOOLS do
                if M.TOOLS[ti].rel == tool_rel then
                    classic = M.TOOLS[ti].run or classic
                    break
                end
            end
            if read_file(root .. '/' .. pp.port_rel) and read_file(root .. '/' .. pp.lua_path_suffix) then
                local lua_src = read_file(root .. '/' .. pp.lua_path_suffix) or ''
                if lua_src:find('shape=COVERAGE', 1, true) then
                    M.log('err', 'skip activate — coverage refuse wall  ·  ' .. pp.port_pack)
                elseif not native_rml_pack(root, tool_rel) then
                    activate_port(pp, classic)
                end
            else
                M.log('err', 'port incomplete — not activating  ·  ' .. pp.port_pack)
            end
        end
    end
    return ok, skip
end

function M.rebuild_ports(rels, root)
    return M.apply_ports(rels, root)
end

function M.activate_ports(rels, root)
    root = norm(root or mq.luaDir or '.')
    local n = 0
    for _, rel in ipairs(rels or {}) do
        rel = tostring(rel or ''):gsub('\\', '/')
        local tool_rel = rel:match('^ports/') and (M.port_to_orig(rel) or rel) or rel
        local pp = port_paths(tool_rel)
        if read_file(root .. '/' .. pp.port_rel) then
            local classic = pack_of(tool_rel)
            for ti = 1, #M.TOOLS do
                if M.TOOLS[ti].rel == tool_rel then classic = M.TOOLS[ti].run or classic; break end
            end
            activate_port(pp, classic)
            n = n + 1
        end
    end
    return n
end

function M.port_to_orig(port_rel)
    port_rel = tostring(port_rel or ''):gsub('\\', '/')
    local pack = port_rel:match('^ports/([^/]+)')
    if not pack then return nil end
    for i = 1, #M.TOOLS do
        if pack_of(M.TOOLS[i].rel) == pack then return M.TOOLS[i].rel end
    end
    return pack .. '/init.lua'
end

function M.unapply_ports(rels, root)
    root = norm(root or mq.luaDir or '.')
    local removed = {}
    for _, rel in ipairs(rels or {}) do
        rel = tostring(rel or ''):gsub('\\', '/')
        local tool_rel = rel:match('^ports/') and (M.port_to_orig(rel) or rel) or rel
        local pp = port_paths(tool_rel)
        local path = root .. '/' .. tool_rel
        local src = read_file(path)
        if src then
            maybe_restore_original(path, src)
        end
        removed[#removed + 1] = tool_rel
        M.log('ok', 'original clean  ·  /lua stop ' .. pp.port_pack .. '  then /lua run ' .. (pack_of(tool_rel)))
    end
    return removed
end

function M.apply_selected(rels, root) return M.apply_ports(rels, root) end
function M.unapply_selected(rels, root) return M.unapply_ports(rels, root) end

function M.set_use_rml(rel, on, root)
    M.log('info', 'set_use_rml ignored — AutoPort is copy-based (ports/)')
    return false, 'use Apply/Unapply (copy-based)'
end

function M.apply(root)
    local rows = M.list_tools(root)
    local rels = {}
    for i = 1, #rows do
        if rows[i].kind == 'imgui' and rows[i].rel and not tostring(rows[i].rel):match('^ports/') then
            rels[#rels + 1] = rows[i].rel
        end
    end
    return { applied = M.apply_ports(rels, root) }
end

function M.unapply(root)
    local rows = M.list_tools(root)
    local rels = {}
    for i = 1, #rows do
        if rows[i].kind == 'rml' and rows[i].orig then
            rels[#rels + 1] = rows[i].orig
        end
    end
    return M.unapply_ports(rels, root)
end

local RUN_MAP = {
    spawnwatch = 'spawnrml',
    ['spawnwatch/init'] = 'spawnrml',
    spawn = 'spawnrml',
    spawn_modern = 'spawnrml',
}

function M.run_name(rel)
    rel = tostring(rel or ''):gsub('\\', '/'):gsub('%.lua$', '')
    if rel:match('^ports/') then
        return rel:gsub('/init$', '')
    end
    rel = rel:gsub('/init$', '')
    return RUN_MAP[rel] or RUN_MAP[rel:lower()] or rel
end

function M.port_run_name(rel)
    return port_paths(rel).port_pack
end

M.TOOLS = {
    { label = 'SpawnWatch', rel = 'spawnrml/init.lua', run = 'spawnrml', always = true, port = true },
    { label = 'MAUI', rel = 'maui/init.lua', run = 'maui', always = true, port = true },
    { label = 'UEQ Launcher', rel = 'ueqtool.lua', run = 'ueqtool', always = true, port = true },
    { label = 'God Tier', rel = 'godtier.lua', run = 'godtier', always = true, port = true },
    { label = 'UltimateEQ', rel = 'UltimateEQ/init.lua', run = 'UltimateEQ', always = true, port = true },
    { label = 'GearScoreX', rel = 'GearScoreX.lua', run = 'GearScoreX', port = true },
    { label = 'Teg HUD', rel = 'teghud.lua', run = 'teghud', always = true, port = true },
    { label = 'EmuHUD', rel = 'emuhud.lua', run = 'emuhud', port = true },
    { label = 'GM Console', rel = 'gmconsole/init.lua', run = 'gmconsole', always = true, port = true },
    { label = 'Expr Evaluator', rel = 'expression_evaluator.lua', run = 'expression_evaluator', port = true },
    { label = 'AutoAug', rel = 'AutoAug.lua', run = 'AutoAug', port = true },
    { label = 'ZoneView', rel = 'zoneview.lua', run = 'zoneview', always = true, port = true },
    { label = 'InvUI', rel = 'invui/init.lua', run = 'invui', always = true, port = true },
    { label = 'UltimateInv', rel = 'UltimateInv/init.lua', run = 'UltimateInv', port = true },
    { label = 'Port', rel = 'Port.lua', run = 'Port', port = true },
    { label = 'Condition Builder', rel = 'condition_builder.lua', run = 'condition_builder', port = true },
    { label = 'SmartLoot', rel = 'smartloot/init.lua', run = 'smartloot', port = true },
    { label = 'EZInventory', rel = 'EZInventory/init.lua', run = 'EZInventory', port = true },
    { label = 'Grouper', rel = 'grouper/init.lua', run = 'grouper', port = true },
    { label = 'BuffBot', rel = 'buffbot/init.lua', run = 'buffbot' },
    { label = 'ButtonMaster', rel = 'buttonmaster/init.lua', run = 'buttonmaster' },
    -- complex / view_model: coverage-gated. VIEW scaffold on FAIL, never empty refuse wall.
    -- LEM hand port is ports/lem (no AUTO_PORT_VER=); Apply keeps it and does not scrape a stub.
    { label = 'LEM', rel = 'lem/init.lua', run = 'lem',
      complex = true, coverage_gate = true, view_model = true,
      view_panels = { 'Text Events', 'Condition Events', 'Categories', 'Settings', 'Reload', 'Import' } },
    { label = 'Lua Console', rel = 'luaconsole/init.lua', run = 'luaconsole',
      complex = true, view_model = true, coverage_gate = true,
      view_panels = { 'Console', 'Watches', 'Snippets', 'Inspect', 'Logs', 'Systems', 'Settings' } },
    { label = 'UEQ Credit', rel = 'ueqcredit.lua', run = 'ueqcredit' },
    { label = 'Transmute', rel = 'Transmute.lua', run = 'Transmute' },
    { label = 'Mini Wiki', rel = 'ulti/init.lua', run = 'ulti' },
    { label = 'MyUI', rel = 'myui/init.lua', run = 'myui',
      complex = true, coverage_gate = true, view_model = true },
    { label = 'EQUI', rel = 'EQUI/ui_core.lua', run = 'EQUI',
      complex = true, coverage_gate = true, view_model = true },
    { label = 'EZQuests', rel = 'ezquests.lua', run = 'ezquests', port = true,
      native_dir = 'EZQuests-main/EZQuests-main' },
}
M.KNOWN = M.TOOLS

function M.tool_status(tool, root)
    root = norm(root or mq.luaDir or '.')
    local src = read_file(root .. '/' .. tool.rel)
    if not src then
        return { kind = 'missing', on = false, label = tool.label, rel = tool.rel, run = tool.run }
    end
    local native = native_rml_pack(root, tool.rel)
    if tool.always or native then
        return {
            kind = 'rml', on = true,
            label = tool.label .. (native and ' (native)' or ''),
            rel = tool.rel, run = tool.run, native = native or true,
        }
    end
    local pp = port_paths(tool.rel)
    local has_port = read_file(root .. '/' .. pp.port_rel) ~= nil
        or read_file(root .. '/' .. pp.lua_path_suffix) ~= nil
    if has_port then
        return {
            kind = 'rml', on = true, label = tool.label .. ' (port)',
            rel = tool.rel, run = pp.port_pack, orig = tool.rel, port = pp.port_pack,
        }
    end
    return { kind = 'imgui', on = false, label = tool.label, rel = tool.rel, run = tool.run }
end

function M.list_tools(root)
    local rows = {}
    for i = 1, #M.TOOLS do
        rows[#rows + 1] = M.tool_status(M.TOOLS[i], root)
    end
    return rows
end

return M
