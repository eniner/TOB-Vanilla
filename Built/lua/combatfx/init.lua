--[[
  combatfx - standalone RmlUi combat effects for MacroQuest (RoF2 / EQEmu). Independent of eqrml.
  Run: /lua run combatfx      Stop: launcher right-click > Stop combatfx, or /lua stop combatfx
  Click the small FX button for settings; right-click it for the quick menu. No commands needed.
  Performance: fixed element pool, one-shot animations only, diffed writes, overlay hidden when idle.
]]
local mq = require('mq')
local C = require('combatfx.core')
local FX = require('combatfx.fx')
local E = require('combatfx.events')
local SIM = require('combatfx.sim')
local UI = require('combatfx.ui')
local TR = require('combatfx.tracker')
local AD = require('combatfx.addons')
local NB = require('combatfx.nimbus')   -- t362: native EQ nimbus (Body FX)
local NA = require('combatfx.aura')     -- t436: native EQ ground aura (Aura tab, native slot 1)
local OR = require('combatfx.ornament') -- orn1: ornament model swaps (Ornaments tab)
local PS = require('combatfx.parses')   -- f8b: history, group meter, death recap, mob warnings, export
local LO = require('combatfx.loadout')  -- f8b: one-click loadouts
local TK = require('combatfx.track')    -- f10: Tracking tab (buffs / DoTs, cast warnings, pet, taken, resists, efficiency, session, spawns)

-- Lightweight spawn log (flag on). Lives here so it runs even if canvas/fx/events
-- were already in package.loaded from an earlier /lua run.
local DEBUG_FX = true
local PT = require('combatfx.paths')   -- portable: MQ TLO paths + config\combatfx_paths.ini
local function fxlog_path() return PT.log_path('combatfx_fx.log') end   -- nil unless debug_logs=1
local function fxlog(msg)
    if not DEBUG_FX then return end
    local path = fxlog_path()
    if not path then return end
    local f = io.open(path, 'a')
    if not f then return end
    local ts = os.date('%Y-%m-%d %H:%M:%S')
    f:write(ts, ' ', msg, '\n')
    f:flush()
    f:close()
end
local function clip(v)
    return tostring(v == nil and '-' or v):gsub('[%c]', ' '):sub(1, 180)
end
if PT.get().debug then   -- debug wrappers only when debug_logs=1 in config\combatfx_paths.ini (off by default: no cost, no files)
    local CV = package.loaded['combatfx.canvas']
    local last_rec = nil
    if E and type(E.one) == 'function' then
        local orig_one = E.one
        E.one = function(r)
            last_rec = r
            return orig_one(r)
        end
    end
    local function rec_bits()
        local r = last_rec
        if type(r) ~= 'table' then
            return string.format('kind=- src=- typ=- sp=- handler=%s line=%s',
                clip(E and E.last_handler), clip(E and E.last_line))
        end
        return string.format('kind=%s src=%s typ=%s sp=%s handler=%s line=%s',
            clip(r.k), clip(r.src), clip(r.typ), clip(r.sp),
            clip(E and E.last_handler), clip(E and E.last_line))
    end
    local function wrap(obj, name, label)
        if not obj or type(obj[name]) ~= 'function' then return false end
        local orig = obj[name]
        obj[name] = function(...)
            local a1, a2, a3 = ...
            local ok, err = pcall(orig, ...)
            local np, nr = '?', '?'
            if CV and CV.last_counts then
                local x, y = CV.last_counts()
                np, nr = tostring(x), tostring(y)
            end
            fxlog(string.format('fn=%s a1=%s a2=%s a3=%s nparts=%s nrings=%s REV=%s draw=%s R=%s half=%s szsrc=%s ax=%s ay=%s asrc=%s %s',
                label, clip(a1), clip(a2), clip(a3), np, nr,
                (CV and CV.REV) or 'no-REV', clip(CV and CV.last_draw),
                clip(CV and CV.last_R), clip(CV and CV.last_half_h), clip(CV and CV.last_size_src),
                clip(CV and CV.anchor_x), clip(CV and CV.anchor_y), clip(CV and CV.anchor_src), rec_bits()))
            if not ok then fxlog(string.format('ERR fn=%s %s', label, clip(err))) end
        end
        return true
    end
    wrap(FX, 'burst', 'FX.burst')
    wrap(FX, 'heal_fx', 'FX.heal_fx')
    wrap(FX, 'stamp', 'FX.stamp')
    wrap(CV, 'proc', 'CV.proc')
    wrap(CV, 'spell', 'CV.spell')
    wrap(CV, 'heal', 'CV.heal')
    wrap(CV, 'crit', 'CV.crit')
    wrap(CV, 'kill', 'CV.kill')
    wrap(CV, 'flare', 'CV.flare')
    wrap(CV, 'shockwave', 'CV.shockwave')
    wrap(CV, 'death', 'CV.death')
    wrap(CV, 'preview', 'CV.preview')
    fxlog(string.format('START combatfx debug CV.REV=%s has_proc=%s has_spell=%s has_last_counts=%s path=%s',
        (CV and CV.REV) or 'no-REV',
        tostring(CV ~= nil and type(CV.proc) == 'function'),
        tostring(CV ~= nil and type(CV.spell) == 'function'),
        tostring(CV ~= nil and type(CV.last_counts) == 'function'),
        clip(fxlog_path())))
    print(C.TAG .. 'debug FX log -> ' .. tostring(fxlog_path()) .. ' (' .. ((CV and CV.REV) or 'no-REV') .. ')')
end

local running = true
local had = C.load_cfg()
pcall(function() require('combatfx.features').set_burns(C.cfg.parses.burns) end)   -- f8b: burn names for the timeline
pcall(function() require('combatfx.themefx').after_load() end)
C.guard('track init', TK.init)                                     -- f10: session start + resist book   -- tfx1: give the current theme its DX11 look once
if not had then C.save_cfg_now() end
do  -- portable: say once where things were found, and what is off on this PC
    local i = PT.get()
    if PT.created then print(C.TAG .. 'created ' .. PT.ini_path() .. ' (optional path overrides; empty = auto-detect)') end
    if not i.eq then print(C.TAG .. 'EQ folder not found (' .. tostring(i.eq_why) .. '): set eq_folder in combatfx_paths.ini. Everything else works.') end
    if not i.snd then print(C.TAG .. 'alert sounds off: ' .. tostring(i.snd_why) .. ' (set sounds in combatfx_paths.ini)') end
end
math.randomseed(mq.gettime() % 100000)

if not FX.open() then print(C.TAG .. 'overlay could not open - is MQ2RmlUi loaded?'); return end
do
    local CV = package.loaded['combatfx.canvas']
    fxlog(string.format('CANVAS using_ex=%s using_ov=%s last_draw=%s REV=%s',
        tostring(CV and CV.using_ex and CV.using_ex() or 'n/a'),
        tostring(CV and CV.using_ov and CV.using_ov() or 'n/a'),
        clip(CV and CV.last_draw), (CV and CV.REV) or 'no-REV'))
end
UI.open()
TR.open()
UI.stop_cb = function() running = false end
E.register()
TR.register()
fxlog(string.format('CHAT path=%s registered=%s', tostring(E._chat), tostring(E.registered)))

-- each step guarded on its own: one failing step can't skip the rest of the frame
local STEPS = { { 'poll', C.poll }, { 'sim', SIM.frame }, { 'process', E.process }, { 'watch', E.watch }, { 'fx', FX.frame },
    { 'ui', UI.frame }, { 'tracker', TR.poll }, { 'addons', AD.poll }, { 'parses', PS.frame }, { 'track', TK.frame }, { 'save', C.save_tick } }
local function frame()
    for _, s in ipairs(STEPS) do C.guard(s[1], s[2]) end
end

local cleaned = false
local function cleanup()
    if cleaned then return end; cleaned = true
    pcall(NB.shutdown)            -- t362: take the native nimbus off when CombatFX stops
    pcall(NA.shutdown)            -- t436: and the native aura
    pcall(OR.shutdown)            -- orn1: real gear back when CombatFX stops (unless 'Keep on stop')
    pcall(E.unregister)
    pcall(TR.unregister)
    pcall(function() if TK._res_dirty then TK.res_save() end end)   -- f10: resist book
    pcall(function() mq.imgui.destroy('combatfx') end)
    pcall(C.capture_positions)   -- patched DLL only: remember where windows were dragged (per character)
    pcall(C.save_cfg_now)
    C.close_all()
end
-- plain "/lua stop combatfx" never runs code after the loop: the state's __gc closes our windows
local sentinel = newproxy and newproxy(true)
if sentinel then getmetatable(sentinel).__gc = function() pcall(cleanup) end end
_G.__combatfx_sentinel = sentinel

mq.imgui.init('combatfx', function() local ok, e = pcall(frame); if not ok then print(C.TAG .. tostring(e)) end end)
print(string.format('%sloaded for %s (%d chat events). Click the FX button for settings, right-click for the menu.', C.TAG, C.CHAR, E.registered))
while running do
    mq.doevents()
    C.guard('process', E.process)   -- drain chat even if the ImGui callback hiccups
    C.guard('nimbus', NB.tick)      -- t362: re-apply the saved nimbus once in game, read its status (1 Hz)
    C.guard('naura', NA.tick)       -- t436: native aura: re-apply / pause with particles / preview timeout (1 Hz)
    C.guard('orn', OR.tick)         -- orn1: put saved ornaments back after zoning / gear changes (1 Hz, rate limited)
    C.guard('track slow', TK.slow)  -- f10: spells_us.txt read 600 lines per tick until done (mana / durations / feign)
    mq.delay(50)
end
cleanup()
print(C.TAG .. 'stopped.')
