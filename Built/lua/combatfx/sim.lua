-- combatfx simulator: generates real RoF2-format chat lines and fake player/target state, and pushes them
-- through the SAME handler table (events.inject) and watcher as live combat. It never sends anything to the game.
local C = require('combatfx.core')
local E = require('combatfx.events')
local A = require('combatfx.addons')
local FX = require('combatfx.fx')
local FT = require('combatfx.features')
local M = { running = nil, fired = 0 }
local st                         -- fake state (events.sim_state while active)
local gen, next_t, end_t, hold_until = nil, 0, 0, 0
local rnd = math.random

local function fresh()
    return { hp = 100, maxhp = 24000, combat = false, tid = 0, tname = '', tpct = nil, casting = '', ttype = 'NPC', mobhp = 0, mobmax = 1, pet = 'Gabaner' }
end
local function activate()
    if not st then st = fresh() end
    if E.sim_state ~= st then E.sim_state = st; E.reset_watch() end
end
local function deactivate()
    E.sim_state = nil; st = nil; E.reset_watch()
end
local function P(n) return math.floor(n * (C.cfg.sim_power or 1)) end
local function feed(line) M.fired = M.fired + 1; E.inject(line) end
local function hit_mob(n)
    st.mobhp = math.max(0, st.mobhp - n)
    st.tpct = math.floor(st.mobhp / st.mobmax * 100 + 0.5)
end
local function new_mob(name, max)
    st.tid = (st.tid or 0) + 1; st.tname = name; st.mobmax = max; st.mobhp = max; st.tpct = 100; st.combat = true
end
local VERBS = { 'slash', 'hit', 'kick', 'pierce', 'crush', 'bash' }
local AVOID = { 'parry', 'dodge', 'riposte', 'block' }
local function cap(s) return (s:gsub('^%l', string.upper)) end

-- each scenario: function(step) -> line(s) or 'done'; mutates st
local S = {}
S.solo = { label = 'Solo melee fight', fn = function(i)
    if i == 1 then new_mob('a goblin warlord', P(9000)); return nil end
    if st.mobhp <= 0 then
        if not st.dead then st.dead = true; return { 'You have slain a goblin warlord!' } end
        st.combat = false; return 'done' end
    local r = rnd()
    local mob = st.tname
    if r < 0.12 then local n = P(rnd(380, 620)); hit_mob(n); return { 'You score a critical hit! (' .. n .. ')', 'You slash ' .. mob .. ' for ' .. n .. ' points of damage.' }
    elseif r < 0.60 then local n = P(rnd(90, 260)); hit_mob(n); return { 'You ' .. VERBS[rnd(#VERBS)] .. ' ' .. mob .. ' for ' .. n .. ' points of damage.' }
    elseif r < 0.70 then return { 'You try to slash ' .. mob .. ', but miss!' }
    elseif r < 0.88 then local n = P(rnd(150, 420)); st.hp = math.max(5, st.hp - n / st.maxhp * 100); return { cap(mob) .. ' hits YOU for ' .. n .. ' points of damage.' }
    else return { cap(mob) .. ' tries to hit YOU, but YOU ' .. AVOID[rnd(#AVOID)] .. '!' } end
end }
S.caster = { label = 'Caster nukes + DoTs', fn = function(i)
    if i == 1 then new_mob('an undead knight', P(16000)); return nil end
    if st.mobhp <= 0 then if not st.dead then st.dead = true; st.casting = ''; return { 'You have slain an undead knight!' } end; st.combat = false; return 'done' end
    local mob = st.tname
    local ph = i % 5
    if ph == 2 then st.casting = 'Ancient: Chaotic Visions'; return { 'You begin casting Ancient: Chaotic Visions.' } end
    if ph == 3 then
        st.casting = ''
        if rnd() < 0.1 then return { 'Your target resisted the Ancient: Chaotic Visions spell.' } end
        local n = P(rnd(1100, 1500)); hit_mob(n)
        if rnd() < 0.25 then n = P(rnd(2300, 3200)); hit_mob(n); return { 'You deliver a critical blast! (' .. n .. ')', 'You hit ' .. mob .. ' for ' .. n .. ' points of non-melee damage.' } end
        return { 'You hit ' .. mob .. ' for ' .. n .. ' points of non-melee damage.' }
    end
    local n = P(rnd(140, 220)); hit_mob(n)
    return { cap(mob) .. ' has taken ' .. n .. ' damage from your ' .. (ph == 4 and "Severan's Rot." or 'Ashengate Pyre.') }
end }
S.group = { label = 'Group heal-heavy fight', fn = function(i)
    if i == 1 then new_mob('a frenzied ghoul', P(30000)); return nil end
    if i > 70 or st.mobhp <= 0 then if not st.dead then st.dead = true; return { 'You have slain a frenzied ghoul!' } end; st.combat = false; return 'done' end
    local r, mob = rnd(), st.tname
    if r < 0.35 then local n = P(rnd(500, 1300)); st.hp = math.max(8, st.hp - n / st.maxhp * 100); return { cap(mob) .. ' hits YOU for ' .. n .. ' points of damage.' }
    elseif r < 0.50 then local n = P(rnd(1500, 3000)); st.hp = math.min(100, st.hp + n / st.maxhp * 100); return { 'Clerica has healed you for ' .. n .. ' points.' }
    elseif r < 0.70 then local n = P(rnd(900, 2400)); return { 'You have healed ' .. ({ 'Tankard', 'Clerica', 'Stabbs' })[rnd(3)] .. ' for ' .. n .. ' points.' }
    elseif r < 0.80 then local n = P(rnd(800, 1600)); st.hp = math.min(100, st.hp + n / st.maxhp * 100); return { 'You have been healed for ' .. n .. ' points.' }
    elseif r < 0.90 then local n = P(rnd(150, 300)); hit_mob(n * 4); return { 'You hit ' .. mob .. ' for ' .. n .. ' points of damage.' }
    else local who = ({ 'Tankard', 'Stabbs' })[rnd(2)]; local n = P(rnd(200, 700)); hit_mob(n); return { who .. ' ' .. ({ 'slashes', 'pierces', 'crushes' })[rnd(3)] .. ' ' .. mob .. ' for ' .. n .. ' points of damage.' } end
end }
S.raid = { label = 'Raid burn (crit spam)', fn = function(i)
    if i == 1 then new_mob('Lord Bob the Unending', P(900000)); return nil end
    if i > 120 then st.combat = false; return 'done' end
    local r, mob = rnd(), st.tname
    if r < 0.40 then local n = P(rnd(9000, 26000)); hit_mob(n); return { 'You deliver a critical blast! (' .. n .. ')', 'You hit ' .. mob .. ' for ' .. n .. ' points of non-melee damage.' }
    elseif r < 0.65 then local n = P(rnd(2500, 6000)); hit_mob(n); return { 'You score a critical hit! (' .. n .. ')', 'You backstab ' .. mob .. ' for ' .. n .. ' points of damage.' }
    elseif r < 0.85 then local n = P(rnd(3000, 9000)); hit_mob(n); return { 'You hit ' .. mob .. ' for ' .. n .. ' points of non-melee damage.' }
    else local n = P(rnd(800, 2000)); hit_mob(n); return { cap(mob) .. ' has taken ' .. n .. ' damage from your Pyre of the Fallen.' } end
end }
S.lowhp = { label = 'Heavy damage to low HP', fn = function(i)
    if i == 1 then new_mob('a raging minotaur', P(50000)); return nil end
    if i <= 26 then local n = P(rnd(700, 1300)); st.hp = math.max(9, st.hp - n / st.maxhp * 100); return { 'A raging minotaur hits YOU for ' .. n .. ' points of damage.' } end
    if i <= 34 then return { 'A raging minotaur tries to hit YOU, but YOU dodge!' } end
    if i <= 40 then local n = P(rnd(3000, 5000)); st.hp = math.min(100, st.hp + n / st.maxhp * 100); return { 'Clerica has healed you for ' .. n .. ' points.' } end
    st.combat = false; return 'done'
end }
S.streak = { label = 'Kill streak', fn = function(i)
    local mobs = { 'a rat', 'a snake', 'a bat', 'a beetle', 'a spider' }
    local k = math.floor((i - 1) / 9) + 1
    if k > #mobs then st.combat = false; return 'done' end
    local j = (i - 1) % 9
    if j == 0 then new_mob(mobs[k], P(1200)); st.dead = false; return nil end
    if j == 8 then st.mobhp = 0; st.tpct = 0; return { 'You have slain ' .. mobs[k] .. '!' } end
    local n = P(rnd(120, 200)); hit_mob(n)
    return { 'You ' .. VERBS[rnd(#VERBS)] .. ' ' .. mobs[k] .. ' for ' .. n .. ' points of damage.' }
end }
M.ORDER = { 'solo', 'caster', 'group', 'raid', 'lowhp', 'streak' }
M.S = S

function M.start(name)
    if not S[name] then return end
    st = fresh(); activate()
    M.running = name; M.last = name; gen = S[name].fn; M.step = 0
    next_t = C.now() + 300; end_t = 0
end
function M.stop() M.running = nil; gen = nil; if st then st.combat = false end; hold_until = C.now() + 2600 end

-- single fire buttons: feed one representative line (or state change) through the same pipeline
M.FIRE = {
    { 'melee', 'Melee', function() feed('You slash ' .. (st.tname ~= '' and st.tname or 'a training dummy') .. ' for ' .. P(rnd(120, 300)) .. ' points of damage.') end },
    { 'spell', 'Spell', function() feed('You hit a training dummy for ' .. P(rnd(1100, 1600)) .. ' points of non-melee damage.') end },
    { 'dot', 'DoT', function() feed("A training dummy has taken " .. P(rnd(150, 250)) .. " damage from your Severan's Rot.") end },
    { 'crit', 'Crit', function() local n = P(rnd(2000, 4000)); feed('You score a critical hit! (' .. n .. ')'); feed('You slash a training dummy for ' .. n .. ' points of damage.') end },
    { 'incoming', 'Hit taken', function() local n = P(rnd(600, 1500)); st.hp = math.max(10, st.hp - n / st.maxhp * 100); feed('A training dummy hits YOU for ' .. n .. ' points of damage.') end },
    { 'healin', 'Heal in', function() local n = P(rnd(1500, 3000)); st.hp = math.min(100, st.hp + n / st.maxhp * 100); feed('Clerica has healed you for ' .. n .. ' points.') end },
    { 'healout', 'Heal out', function() feed('You have healed Tankard for ' .. P(rnd(1000, 2500)) .. ' points.') end },
    { 'miss', 'Miss/parry', function() feed('A training dummy tries to hit YOU, but YOU ' .. AVOID[rnd(#AVOID)] .. '!') end },
    { 'resist', 'Resist', function() feed('Your target resisted the Tashan\'s Lingering Cry spell.') end },
    { 'kill', 'Kill', function() feed('You have slain a training dummy!') end },
    { 'lowhp', 'Low HP', function() st.hp = 18 end },
    { 'bigdmg', 'Big hit', function() local n = P(6000); st.hp = math.max(10, st.hp - 25); feed('A training dummy hits YOU for ' .. n .. ' points of damage.') end },
    { 'castland', 'Cast lands', function() st.casting = 'Gift of Pure Thought'; M._land = C.now() + 400 end },
    { 'combat', 'Combat on/off', function() if not st.combat then new_mob('a training dummy', P(20000)) else st.combat = false end end },
    { 'combat_on', nil, function() if not st.combat then new_mob('a training dummy', P(20000)) end end },
    { 'combat_off', nil, function() st.combat = false end },
    { 'streak', 'Streak x5', function() for _ = 1, 5 do feed('You hit a training dummy for ' .. P(rnd(100, 200)) .. ' points of damage.') end end },
    -- add-ons (each feeds the real chat line where there is one; TLO-polled features call the same alert the poller calls)
    { 'bighit', 'Record hit', function() local n = math.floor(math.max((A.sim_best or C.cfg.rec.best or 0) * 1.25, 40000)); feed('You score a critical hit! (' .. n .. ')'); feed('You slash a training dummy for ' .. n .. ' points of damage.') end },
    { 'proc', 'Backstab', function() feed('You backstab a training dummy for ' .. P(rnd(900, 1800)) .. ' points of damage.') end },
    { 'pet', 'Pet hit', function() feed((st.pet or 'Gabaner') .. ' hits a training dummy for ' .. P(rnd(80, 240)) .. ' points of damage.') end },
    { 'buffwarn', 'Buff fading', function() A.buff_tick('Speed of Vallon', 900, C.now()); A.buff_tick('Speed of Vallon', 12, C.now()); feed('Your Spirit of Wolf spell has worn off.') end },
    { 'ready', 'Spell ready', function() A.gem_tick(99, 'Gift of Pure Thought', false, C.now() - 30000); A.gem_tick(99, 'Gift of Pure Thought', true, C.now()) end },
    { 'mezbreak', 'Mez break', function() feed('A training dummy has been awakened by Tankard.') end },
    { 'aggro', 'Aggro', function() A.aggro_tick(0, true, true); A.aggro_tick(100, true, true) end },
    { 'group', 'Group danger', function() A.group_tick('Clerica', 80, C.now() - 9000); A.group_tick('Clerica', 24, C.now()); feed('Tankard has been slain by a training dummy!') end },
    { 'recap', 'Fight recap', function()
        -- a 38 s practice encounter pushed through the same per-ability / per-second counters live hits use
        local F = A.fight(); A.fight_reset(); F = A.fight(); F.hits, F.crits, F.top, F.inhits, F.avoid, F.petdmg, F.resists = 42, 9, P(4210), 18, 7, P(3100), 1
        local t0 = C.now() - 38000
        FT.enc_reset(t0, 'a goblin warlord')
        local AB = { { 'Backstab', 1500, 0.30 }, { 'Melee', 260, 0.12 }, { 'Ancient: Chaotic Visions', 1300, 0.25 }, { "Severan's Rot", 180, 0 }, { 'Kick', 120, 0.05 }, { 'Non-melee procs', 220, 0.1 } }
        local seed = 7
        local function rr() seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648 end
        local total = 0
        for sec = 0, 37 do
            local burst = (sec > 8 and sec < 16) and 1.8 or ((sec > 28) and 0.6 or 1)
            for _, a in ipairs(AB) do
                if rr() < 0.55 then
                    local crit = rr() < a[3]
                    local n = P(math.floor(a[2] * (0.7 + rr() * 0.6) * burst * (crit and 2.2 or 1)))
                    FT.enc_hit(a[1], n, crit, t0 + sec * 1000 + 300); total = total + n
                end
            end
        end
        A.recap(38, total, P(8200))
    end },
    -- f8 features: each one feeds the real chat line (or calls the same function the TLO poller calls)
    { 'grouphit', 'Group hit', function() FT.force('show.group'); local n = P(rnd(300, 900)); feed('Tankard scores a critical hit! (' .. n .. ')'); feed('Tankard slashes a training dummy for ' .. n .. ' points of damage.'); feed('Stabbs pierces a training dummy for ' .. P(rnd(150, 400)) .. ' points of damage.') end },
    { 'school', 'Spell schools', function()
        FT.force('school')
        local L = { { 'fire', 'Flame Lick' }, { 'cold', 'Frost Shock' }, { 'poison', 'Envenomed Bolt' }, { 'disease', 'Plague Swarm' }, { 'magic', 'Force Snap' }, { 'chromatic', 'Prism Strike' }, { 'corruption', 'Dark Bargain' } }
        M._sc = (M._sc or 0) % #L + 1; local it = L[M._sc]
        feed('You hit a training dummy for ' .. P(rnd(900, 1600)) .. ' points of ' .. it[1] .. ' damage by ' .. it[2] .. '.')
    end },
    { 'alertproc', 'Proc alert', function() FT.force('alert.proc'); feed('You score a Crippling Blow! (' .. P(rnd(1800, 2600)) .. ')') end },
    { 'alertbuff', 'Buff alert', function() FT.force('alert.buff'); local nm = (FT._buffs and FT._buffs[1]) and FT._buffs[1]:gsub('^%l', string.upper) or 'Speed of Vallon'; A.buff_tick(nm, 900, C.now()); A.buff_tick(nm, math.min(12, FT.buff_threshold() - 1), C.now()) end },
    { 'alertheal', 'Big heal', function() FT.force('alert.heal'); local n = math.floor(st.maxhp * 0.42); st.hp = math.min(100, st.hp + 42); feed('Clerica has healed you for ' .. n .. ' points.') end },
    { 'namedkill', 'Named kill', function() FT.force('moment.named'); A.engage({ tname = 'Lord Bob the Unending', named = true }); feed('You have slain Lord Bob the Unending!') end },
    { 'lootrare', 'Lore drop', function() FT.force('moment.loot', 3000); feed("--You have looted a Cloak of Flames from Lord Bob the Unending's corpse.--") end },
    { 'named', 'Named / ding', function() A.engage({ tname = 'Lord Bob the Unending', named = true }); feed('You have gained a level! Welcome to level 61!'); feed('You have gained an ability point! You now have 1 ability point.') end },
    { 'resisttype', 'Resist type', function() feed("Your target resisted the Tashan's Lingering Cry spell.") end },
    { 'death', 'Death', function() feed('You have been slain by a training dummy!') end },
    { 'castbar', 'Cast bar', function() feed('You begin casting Gift of Pure Thought.'); st.casting = 'Gift of Pure Thought'; M._land = C.now() + 2600 end },
    -- f8b previews: chat lines in the real formats replayed through the same parser with their own timestamps
    { 'tlrecap', 'Timeline recap', function() M.replay_fight(M.TL_FIGHT, 'a goblin warlord') end },
    { 'deathrecap', 'Death recap', function() M.replay_death(M.DEATH_LINES, 'a raging minotaur') end },
    { 'mobwarn', 'Mob warning', function()
        FT.force('alert.mob')
        local PS = package.loaded['combatfx.parses']
        if PS then PS.preview_warning() end
    end },
    { 'groupmeter', 'Group meter', function() if not M.running then M.start('group') end end },
}
-- f8b: a 30 s fight in real chat-line formats (casts, AAs, a burn, spell damage, a proc, melee), replayed with times
M.TL_FIGHT = {
    { 0.0, 'You begin casting Ancient: Chaotic Visions.' }, { 2.6, 'You hit a goblin warlord for 1,420 points of non-melee damage by Ancient: Chaotic Visions.' },
    { 3.0, 'You slash a goblin warlord for 260 points of damage.' }, { 4.1, 'You activate Glyph of Destruction.' }, { 4.5, 'You begin casting Ancient: Chaotic Visions.' },
    { 7.0, 'You hit a goblin warlord for 2,980 points of non-melee damage by Ancient: Chaotic Visions. (Critical)' }, { 7.5, 'You slash a goblin warlord for 310 points of damage.' },
    { 8.2, 'You hit a goblin warlord for 640 points of fire damage by Flame Lick.' }, { 9.0, 'You begin casting Pyre of the Fallen.' },
    { 11.0, "A goblin warlord has taken 520 damage from your Pyre of the Fallen." }, { 14.0, "A goblin warlord has taken 520 damage from your Pyre of the Fallen." },
    { 15.5, 'You slash a goblin warlord for 280 points of damage.' }, { 21.0, 'You begin casting Ancient: Chaotic Visions.' },
    { 23.5, 'You hit a goblin warlord for 1,390 points of non-melee damage by Ancient: Chaotic Visions.' }, { 24.0, 'You activate Fury of the Gods.' },
    { 25.2, 'You slash a goblin warlord for 300 points of damage.' }, { 27.0, 'You hit a goblin warlord for 610 points of fire damage by Flame Lick.' },
    { 29.0, 'You slash a goblin warlord for 240 points of damage.' }, { 30.0, 'You have slain a goblin warlord!' },
}
M.DEATH_LINES = {
    { 9.6, 'A raging minotaur hits YOU for 1,120 points of damage.', 82 }, { 8.4, 'A raging minotaur tries to hit YOU, but YOU dodge!', 82 },
    { 7.9, 'Clerica has healed you for 2,400 points.', 92 }, { 6.8, 'A raging minotaur hits YOU for 1,380 points of damage.', 86 },
    { 5.2, 'A raging minotaur hit you for 5,600 points of fire damage by Minotaur Fire Breath.', 63 }, { 4.0, 'A raging minotaur hits YOU for 1,250 points of damage.', 58 },
    { 2.9, 'A raging minotaur hits YOU for 1,410 points of damage.', 52 }, { 1.4, 'A raging minotaur hit you for 6,100 points of fire damage by Minotaur Fire Breath.', 26 },
    { 0.3, 'A raging minotaur hits YOU for 1,500 points of damage.', 0 },
}
function M.replay_fight(list, mob)
    local now = C.now()
    local t0 = now - math.floor(list[#list][1] * 1000) - 500
    FT.enc_reset(t0, mob); FT.st_reset(t0, t0)
    local total = 0
    for _, l in ipairs(list) do
        local evs = E.parser:classify(l[2], t0 + math.floor(l[1] * 1000)) or {}
        for _, ev in ipairs(evs) do
            FT.st_add(ev, t0 + math.floor(l[1] * 1000))
            if ev.k == 'dmg' and ev.who == 'me' then total = total + ev.n; FT.enc_hit(FT.ABIL_NAME(ev), ev.n, ev.crit, t0 + math.floor(l[1] * 1000)) end
        end
    end
    A.recap(FT.st_secs(), total, 0)
end
function M.replay_death(list, by)
    local PS = package.loaded['combatfx.parses']
    if not PS then return end
    local now = C.now()
    PS.reset_hp()                                                  -- the replay writes its own past samples
    for _, l in ipairs(list) do
        local t = now - math.floor(l[1] * 1000)
        PS.sample_hp(t, l[3], math.floor(24000 * l[3] / 100), 24000)
        for _, ev in ipairs(E.parser:classify(l[2], t) or {}) do PS.note(ev, t) end
    end
    PS.on_died(by, now, true)
end
function M.school_index(j) M._sc = (tonumber(j) or 1) - 1 end
function M.fire(key)
    activate()
    for _, f in ipairs(M.FIRE) do if f[1] == key then f[3](); break end end
    hold_until = C.now() + (key == 'lowhp' and 4500 or 3000)
end
-- preview after a color edit: one sample of that kind
function M.preview(kind) M.fire(kind) end

-- the full-effect showcase (Preview/Test button): every effect, staggered
local show_q = {}
function M.showcase()
    if M.running then M.stop() end
    local seq = { 'combat_on', 'melee', 'spell', 'dot', 'crit', 'miss', 'resist', 'incoming', 'bigdmg', 'healin', 'healout', 'castland', 'streak', 'lowhp', 'kill', 'combat_off',
        'bighit', 'proc', 'pet', 'buffwarn', 'ready', 'mezbreak', 'aggro', 'group', 'named', 'resisttype', 'castbar', 'recap', 'grouphit', 'school', 'alertproc', 'alertbuff', 'alertheal', 'namedkill', 'lootrare', 'death' }
    local t = C.now()
    show_q = {}
    for k, key in ipairs(seq) do show_q[#show_q + 1] = { t = t + (k - 1) * 380, key = key } end
end

function M.frame()
    local now = C.now()
    while show_q[1] and show_q[1].t <= now do M.fire(table.remove(show_q, 1).key) end
    if M._land and now >= M._land and st then st.casting = ''; M._land = nil end
    if gen then
        local eps = C.clamp(C.cfg.sim_eps or 6, 1, 30) * (M.running == 'raid' and 1.6 or 1)
        local guard = 0
        while gen and now >= next_t and guard < 8 do
            guard = guard + 1
            next_t = next_t + 1000 / eps
            M.step = M.step + 1
            local out = gen(M.step)
            if out == 'done' then
                if C.cfg.sim_loop then local n = M.running; M.stop(); hold_until = 0; M.start(n); next_t = now + 1500
                else M.stop() end
            elseif type(out) == 'table' then for _, l in ipairs(out) do feed(l) end end
        end
    elseif st and #show_q == 0 and now > hold_until and (not st.combat or now > hold_until + 8000) then
        deactivate()                                                -- a forgotten "Combat on" ends itself after ~10 s
    end
end
function M.active() return E.sim_state ~= nil end
return M
