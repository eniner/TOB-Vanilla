-- Simulator: drives a bar's button states (ready -> pressed -> cooldown sweep + timer -> ready flash) from a fake clock.
-- It NEVER runs commands: while a bar is simulated its clicks go to S.press(), not to core.exec, and Lua timers/conditions
-- of that bar are not evaluated (the simulated state replaces them).
local C = require('buttonmaster_rml.core')
local S = { target = nil, playing = false, speed = 1, mode = 'rot', slots = {}, clock = 0, last = nil, next_auto = 0, rot = 0, presses = 0 }
local DEMO_CD = { 6, 10, 4, 15, 8, 30, 5, 12, 20, 7, 3, 9 }

function S.active(id) return S.target ~= nil and S.target == id end
function S.start(id, n)
    S.target = id; S.slots = {}; S.clock = 0; S.last = nil; S.next_auto = 0.6; S.rot = 0; S.presses = 0; S.n = n or 12
    S.playing = false
end
function S.stop() S.target = nil; S.playing = false; S.slots = {} end
function S.reset() if S.target then S.start(S.target, S.n) end end
local function slot(i) local s = S.slots[i]; if not s then s = { st = 'ready', cond = false, flash = 0 }; S.slots[i] = s end; return s end
S.slot = slot
-- cooldown length used for a simulated press: the button's own timer when it has a fixed one, else a demo value
function S.cd_for(b, i)
    if b then
        if b.TimerType == 'Seconds Timer' and tonumber(b.Cooldown) then return tonumber(b.Cooldown) end
        if (b.CachedCoolDownTimer or 0) > 0 then return b.CachedCoolDownTimer end
    end
    return DEMO_CD[((i - 1) % #DEMO_CD) + 1]
end
function S.press(i, b)
    local s = slot(i)
    if s.st ~= 'ready' then return false end
    s.prs_until = S.clock + 0.16; s.tot = S.cd_for(b, i); s.cd_end = S.clock + 0.16 + s.tot; s.st = 'cd'
    S.presses = S.presses + 1
    return true
end
function S.set(i, st)
    local s = slot(i)
    if st == 'ready' then s.st = 'ready'; s.cd_end = nil
    elseif st == 'cd' then s.st = 'cd'; s.tot = s.tot or S.cd_for(nil, i); s.cd_end = S.clock + s.tot
    elseif st == 'dis' then s.st = (s.st == 'dis') and 'ready' or 'dis'
    elseif st == 'cond' then s.cond = not s.cond end
end
-- advance the fake clock (real seconds * speed); auto-press in rotation or random mode
function S.tick(real_now, n, button_of)
    if not S.target then return end
    local dt = S.last and math.max(0, math.min(0.25, real_now - S.last)) or 0
    S.last = real_now
    if S.playing then S.clock = S.clock + dt * S.speed end
    for i, s in pairs(S.slots) do
        if s.st == 'cd' and s.cd_end and S.clock >= s.cd_end then s.st = 'ready'; s.cd_end = nil; s.flash_at = S.clock end
        if s.flash_at then local f = 1 - (S.clock - s.flash_at) / 0.45; if f <= 0 then s.flash_at = nil; s.flash = 0 else s.flash = f end end
    end
    if S.playing and S.clock >= S.next_auto and n > 0 then
        if S.mode == 'rot' then
            for k = 1, n do
                local i = ((S.rot + k - 1) % n) + 1
                local b = button_of(i)
                if b and slot(i).st == 'ready' then S.press(i, b); S.rot = i; break end
            end
            S.next_auto = S.clock + 1.2
        else
            local ready = {}
            for i = 1, n do if button_of(i) and slot(i).st == 'ready' then ready[#ready + 1] = i end end
            if #ready > 0 then local i = ready[math.random(#ready)]; S.press(i, button_of(i)) end
            S.next_auto = S.clock + 0.5 + math.random() * 1.6
        end
    end
end
-- the state the painter needs for slot i
function S.state(i)
    local s = slot(i)
    local cd = (s.st == 'cd' and s.cd_end) and math.max(0, s.cd_end - S.clock) or 0
    return { cd = cd, tot = s.tot or 0, dis = s.st == 'dis', cond = s.cond, flash = s.flash or 0, prs = s.prs_until and S.clock < s.prs_until }
end
function S.describe(i)
    local s = slot(i)
    if s.st == 'dis' then return 'Out of range / disabled' end
    if s.st == 'cd' and s.cd_end then return string.format('Cooldown %.0fs of %.0fs', math.max(0, s.cd_end - S.clock), s.tot or 0) end
    return 'Ready' .. (s.cond and '  -  condition true' or '')
end
-- demo bar: 12 in-memory buttons showing every effect (never saved, never executable)
function S.demo_buttons()
    if S._demo then return S._demo end
    local D = {}
    local list = {
        { 'Inferno', 'fireball', { fire = { On = true, Trig = 'ready', Int = 100 }, flash = { On = true }, bounce = { On = true } }, 'rounded', 'metal', 'ff8a3a', '5a1a08', '1a0604' },
        { 'Glacier', 'snowflake-1', { frost = { On = true, Trig = 'always', Int = 85 } }, 'hex', 'gem', '9fdcff', '12345a', '06101e' },
        { 'Sigil', 'magic-swirl', { arcane = { On = true, Trig = 'always', Int = 100 } }, 'round', 'rune', 'c28bff', '3a1460', '0e0618' },
        { 'Storm', 'lightning-helix', { bolt = { On = true, Trig = 'cooldown', Int = 100 }, flash = { On = true, Col = 'dfe9ff' } }, 'square', 'metal', 'a8c8ff', '1c2850', '060a18' },
        { 'Heal', 'heart-plus', { pulse = { On = true, Trig = 'ready', Int = 90, Col = 'ff6a6a' } }, 'round', 'gem', 'ff8a8a', '5a1018', '1a0406' },
        { 'Shield', 'winged-shield', { shine = { On = true, Trig = 'always', Int = 70 }, glow = { On = true, Trig = 'hover', Int = 80, Col = 'ffe08a' } }, 'rounded', 'gem', 'ffe08a', '6a5014', '1e1404' },
        { 'Burn', 'burning-embers', { fire = { On = true, Trig = 'always', Int = 100 }, glow = { On = true, Trig = 'always', Int = 60 } }, 'hex', 'rune', 'ffb35a', '6a2008', '200804' },
        { 'Snare', 'spider-web', { glow = { On = true, Trig = 'cond', Int = 100, Col = '7ae08a' } }, 'square', 'plain', '7ae08a', '1a3a1e', '08140a' },
        { 'Mana', 'crystal-ball', { pulse = { On = true, Trig = 'cooldown', Int = 80, Col = '9fdcff' } }, 'round', 'metal', '9fdcff', '12345a', '06101e' },
        { 'Nuke', 'lightning-storm', { bolt = { On = true, Trig = 'ready', Int = 100, Col = 'c28bff' }, arcane = { On = true, Trig = 'ready', Int = 60 } }, 'rounded', 'rune', 'c28bff', '2a0c4a', '0a0414' },
        { 'Evac', 'wing-cloak', { shine = { On = true, Trig = 'ready', Int = 100 }, flash = { On = true } }, 'hex', 'gem', 'fff2c0', '5a4a1a', '1a1406' },
        { 'Camp', 'campfire', { bounce = { On = true } }, 'rounded', 'plain', 'b8a69c', '2a2422', '121010' },
    }
    for i, t in ipairs(list) do
        D[i] = { Label = t[1], Icon = t[2], IconType = 'GI', TimerType = 'Seconds Timer', Cooldown = DEMO_CD[i], Demo = true,
            Rml = { Shape = t[4], Frame = t[5], Border = t[6], Bg1 = t[7], Bg2 = t[8], LabelPos = 'under', Fx = t[3] } }
    end
    S._demo = D
    return D
end
return S
