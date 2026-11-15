--[[ ButtonMaster RML - an RmlUi port of ButtonMaster v2.3 (Derple, Special.Ed) for MQ2RmlUi.
     Own config: config/ButtonMaster_RML.lua (copied once from config/ButtonMaster.lua; the original is never written).
     Run:  /lua run buttonmaster_rml        Stop: /lua stop buttonmaster_rml
     Everything is in the UI (gear on a bar, right-click a button). Optional aliases: /bmr, /btn <n>, /btnexec, /btncopy. ]]
local mq = require('mq')
local C = require('buttonmaster_rml.core')
local P = require('buttonmaster_rml.paint')
local S = require('buttonmaster_rml.sim')
local B = require('buttonmaster_rml.bars')
local E = require('buttonmaster_rml.editor')
local F = require('buttonmaster_rml.forge')
local running = true
local last_ms = 0
local args = ... or ''

C.load()
pcall(function()
    local actors = require('actors')
    C.actor = actors.register(function(message)
        local m = message()
        if type(m) ~= 'table' or m.script ~= 'ButtonMasterRml' then return end
        if m.from == C.tlo(function() return mq.TLO.Me.DisplayName() end, '') then return end
        if m.event == 'SaveSettings' and type(m.newSettings) == 'table' then
            local mine = C.settings.Characters[C.CharConfig]
            C.settings = m.newSettings
            C.settings.Characters[C.CharConfig] = C.settings.Characters[C.CharConfig] or mine
            C.settings.Rml = C.settings.Rml or { Styles = {}, Quality = 'balanced', Reduced = false }
            C.reload_due = true
        end
    end)
end)

local function invalidate() for _, b in pairs(B.list) do b:invalidate() end; if B.demo then B.demo:invalidate() end end
local function bar_of(id) if id == 'demo' then return B.demo end; return B.list[id] end
B.hooks.edit = function(bar, set, idx, create) E.open(bar, set, idx, create) end
B.hooks.menu = function(id) F.open('bars', id) end
B.hooks.sim = function(id)
    if S.active(id) then F.stop_sim() else F.start_sim(id) end
    F.open('sim', id)
end
E.hooks = { changed = function() invalidate(); F.paint() end, bar = bar_of, parse = B.parse_rect, screen = B.screen,
    msg = function(t) F.msg(t) end, clear = function() invalidate(); F.paint() end,
    simulate = function(id) if id then F.start_sim(id) end; F.open('sim', id) end }
F.hooks = { bar = bar_of, edit = function(bar, set, idx, create, key) E.open(bar, set, idx, create, key) end, parse = B.parse_rect, screen = B.screen,
    sync = B.request_sync, reopen = function() S.stop(); B.reopen_all() end, invalidate = invalidate, clear = function() invalidate() end,
    reopen_one = function(id) B.request_reopen({ id }) end,
    demo = function(on) B.demo_show(on) end, count_anim = B.count_anim, last_ms = function() return last_ms end }

-- ---------------------------------------------------------------- optional command aliases (everything is also in the UI)
mq.bind('/bmr', function(a)
    a = tostring(a or ''):lower()
    if a == 'sim' then F.open('sim') elseif a == 'stop' then running = false else F.toggle() end
end)
mq.bind('/btn', function(n) n = tonumber(n) or 1; local w = C.win(n); if w then w.Visible = w.Visible == false; C.save(true) end end)
mq.bind('/btnexec', function(set, idx)
    if not set or not idx then C.out('Usage: /btnexec "set" index'); return end
    local b = C.button_at(set, tonumber(idx) or 0)
    if not b then C.out('\arSet %s slot %s is not assigned.', tostring(set), tostring(idx)); return end
    C.out('Running %s slot %s: %s', set, idx, C.label(b, true)); C.exec(b)
end)
mq.bind('/btncopy', function(server, char)
    if not server or not char then return end
    local key = server .. '_' .. char:sub(1, 1):upper() .. char:sub(2)
    if C.copy_local(key) then S.stop(); B.request_reopen(nil) else C.out('\arProfile %s not found.', key) end
end)

-- ---------------------------------------------------------------- loop
B.sync()
E.create(); F.create()
local VERSION = '1.1'
local r = C.settings.Rml
if C.first_run then F.open('bars', 1); F.msg('Your ButtonMaster buttons were copied in. Right-click a button to style it.')
elseif r.SeenVersion ~= VERSION or r.ForgeOpen then F.open('bars', 1) end
if r.SeenVersion ~= VERSION then r.SeenVersion = VERSION; C.save_soon() end
C.out('v1.1 loaded. Settings: gear on a bar or /bmr. Right-click a button = Button Forge. /lua stop buttonmaster_rml to close.')

local function frame()
    local t0 = os.clock()
    local t = mq.gettime()
    B.tick()
    if C.reload_due then C.reload_due = false; S.stop(); B.reopen_all() end
    B.frame(t); E.frame(t); F.frame(t)
    C.tick_save()
    last_ms = (os.clock() - t0) * 1000
end
mq.imgui.init('ButtonMasterRml', function() local ok, e = pcall(frame); if not ok then print('[ButtonMaster RML] ' .. tostring(e)) end end)

while running do
    mq.delay(50)
    if C.tlo(function() return mq.TLO.MacroQuest.GameState() end, 'INGAME') ~= 'INGAME' then C.out('Not in game, stopping.'); break end
end
C.save(false)
pcall(function() mq.imgui.destroy('ButtonMasterRml') end)
B.close_all(); E.shutdown(); F.shutdown()
