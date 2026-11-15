--[[ AutoPort v5 — live-capture ports on top of the v4 static converter.

  require('rmlui.autoport5').patch() upgrades the already-loaded
  require('rmlui.autoport') table IN MEMORY (v4 files are not edited):
    convert()/apply_ports() still build the v4 static copy under ports/<pack>/,
    then v5 moves its runner to ports/<pack>/static_init.lua and writes a live
    ports/<pack>/init.lua that runs the ORIGINAL tool through the capture shim.
  Copy-based as before: originals are only ever read.
]]
local M = { version = '5.0', LIVE_VER = 1 }
local unpack = table.unpack or unpack

local function norm(p) return tostring(p or ''):gsub('\\', '/') end

function M.pack_of(rel)
    rel = norm(rel)
    local dir, file = rel:match('^(.+)/([^/]+)$')
    if file == 'init.lua' or file == 'ui_core.lua' then return dir end
    return ((file or rel):gsub('%.lua$', '')):lower()
end

local function read(path) local f = io.open(path, 'rb'); if not f then return nil end local s = f:read('*a'); f:close(); return s end
local function write(path, s) local f = io.open(path, 'wb'); if not f then return false end f:write(s); f:close(); return read(path) == s end
local function mkdirs(path)
    local ok, inj = pcall(require, 'rmlui.autoport.inject')
    if ok and inj and inj.mkdir then pcall(inj.mkdir, path); return end
    local lok, lfs = pcall(require, 'lfs')
    if lok and lfs then
        local acc = ''
        for part in norm(path):gmatch('[^/]+') do acc = acc .. part; pcall(lfs.mkdir, acc); acc = acc .. '/' end
    end
end
M._mkdirs = mkdirs

function M.launcher_source(tool_rel, pack, title, has_static)
    return table.concat({
        '-- AUTO_PORT_VER=', '17', ' shape=LIVE\n',
        '--[[ AutoPort v5 LIVE port of ', tool_rel, '\n',
        '  Run:  /lua run ports/', pack, '      Stop: /lua stop ports/', pack, '\n',
        '  The original tool runs unmodified; its ImGui calls are captured and mirrored\n',
        '  into basic RmlUi windows. Delete the AUTO_PORT_VER line to protect hand edits.\n',
        ']]\n',
        "require('rmlui.autoport5.live').run({\n",
        '    pack = ', string.format('%q', pack), ',\n',
        '    entry = ', string.format('%q', norm(tool_rel)), ',\n',
        '    title = ', string.format('%q', title or pack), ',\n',
        '    static = ', has_static and string.format('%q', 'ports/' .. pack .. '/static_init.lua') or 'nil', ',\n',
        '    args = { ... },\n',
        '})\n',
    })
end

--- Write/refresh the live launcher for one tool. Returns port init rel or nil, err.
function M.write_live(root, tool_rel, title)
    root = norm(root)
    tool_rel = norm(tool_rel)
    local pack = M.pack_of(tool_rel)
    local src = read(root .. '/' .. tool_rel) or ''
    if src:find("require%(?%s*['\"]rmlui") or src:find('rmlui.host', 1, true) or src:find('rml_ui', 1, true) then
        return nil, 'native RmlUi tool (already draws RmlUi) - live port skipped: ' .. tool_rel
    end
    local dir = root .. '/ports/' .. pack
    mkdirs(dir .. '/ui')
    local init = dir .. '/init.lua'
    local cur = read(init)
    if cur and not cur:find('AUTO_PORT_VER', 1, true) and not cur:find('AutoPort COPY', 1, true) then
        return nil, 'hand port kept (no AUTO_PORT_VER): ports/' .. pack
    end
    local has_static = false
    if cur and cur:find('AutoPort COPY', 1, true) then -- v4 runner -> static fallback
        has_static = write(dir .. '/static_init.lua', cur)
    elseif read(dir .. '/static_init.lua') then
        has_static = true
    end
    local src = M.launcher_source(tool_rel, pack, title, has_static)
    if not write(init, src) then return nil, 'write failed: ' .. init end
    return 'ports/' .. pack .. '/init.lua'
end

function M.patch(ap)
    ap = ap or require('rmlui.autoport')
    if ap._ap5 then return ap end
    ap._ap5 = true
    local mq = require('mq')
    local v4_convert, v4_apply = ap.convert, ap.apply_ports
    ap.version = '5.0 (v4 ' .. tostring(ap.version) .. ' static fallback)'
    -- v4 can write a "restored" original back when it finds old inject markers.
    -- v5 guarantee: during convert, writes are only allowed under lua/ports/.
    local inj_ok, inj = pcall(require, 'rmlui.autoport.inject')
    local function guarded(fn, ...)
        if not (inj_ok and inj and inj.write_file) then return fn(...) end
        local real_write = inj.write_file
        inj.write_file = function(path, s)
            if not norm(path):find('/ports/', 1, true) and not norm(path):match('^ports/') then
                ap.log('info', 'v5 guard: original left untouched  ·  ' .. tostring(path))
                return false
            end
            return real_write(path, s)
        end
        local res = { pcall(fn, ...) }
        inj.write_file = real_write
        if not res[1] then error(res[2], 0) end
        return select(2, unpack(res))
    end
    ap.convert = function(rels, root, opts)
        local ok, skip = guarded(v4_convert, rels, root, opts)
        root = norm(root or mq.luaDir or '.')
        for _, rel in ipairs(rels or {}) do
            rel = norm(rel)
            if not rel:match('^ports/') then
                local r, err = M.write_live(root, rel)
                if r then
                    ap.log('ok', 'live port  ·  ' .. r)
                    local have = false
                    for i = 1, #ok do if ok[i] == r then have = true end end
                    if not have then ok[#ok + 1] = r end
                else ap.log('warn', tostring(err)) end
            end
        end
        return ok, skip
    end
    ap.apply_ports = function(rels, root)
        local ok, skip = ap.convert(rels, root, { force = true })
        for i = 1, #ok do
            local port = tostring(ok[i]):match('^(ports/.+)/init%.lua$')
            if port then
                local tool = ap.port_to_orig and ap.port_to_orig(ok[i]) or nil
                local classic = tool and M.pack_of(tool)
                if classic then mq.cmdf('/squelch /lua stop %s', classic) end
                mq.cmdf('/squelch /lua stop %s', port)
                mq.cmdf('/timed 5 /lua run %s', port)
                ap.log('ok', 'launched live  ·  ' .. port)
            end
        end
        return ok, skip
    end
    ap.rebuild_ports = ap.apply_ports
    ap.apply_selected = ap.apply_ports
    return ap
end

return M
