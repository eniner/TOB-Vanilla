-- combatfx event pipeline. ONE handler table serves both real chat (mq.event) and the simulator
-- (inject(line) runs the same patterns through a Lua matcher with MQ's #n# / #*# semantics).
-- Handlers only queue small records; all DOM work happens in the ImGui frame (process()).
local mq = require('mq')
local C = require('combatfx.core')
local FX = require('combatfx.fx')
local A = require('combatfx.addons')
local FT = require('combatfx.features')   -- f8
local PS = require('combatfx.parses')     -- f8b
local TK = require('combatfx.track')      -- f10
local M = { handlers = {}, queue = {}, registered = 0, matched = 0 }
local Q = M.queue
M.last_line, M.last_handler = '', ''

local function num(s) return tonumber((tostring(s or ''):gsub(',', ''))) end
local function push(r)
    -- never silently drop the newest hit: if imgui/doevents stalled, evict the oldest
    if #Q >= 400 then table.remove(Q, 1) end
    Q[#Q + 1] = r
end

-- state source: real TLOs, or the simulator's fake state while it runs (same downstream code)
M.sim_state = nil
function M.state()
    local s = M.sim_state
    if s then return s end
    return {
        hp = C.num(function() return mq.TLO.Me.PctHPs() end, 100), maxhp = C.num(function() return mq.TLO.Me.MaxHPs() end, 0),
        combat = C.safe(function() return mq.TLO.Me.CombatState() end) == 'COMBAT' or C.safe(function() return mq.TLO.Me.Combat() end) == true,
        tid = C.num(function() return mq.TLO.Target.ID() end, 0), tname = C.str(function() return mq.TLO.Target.CleanName() end, ''),
        tpct = C.num(function() return mq.TLO.Target.PctHPs() end, nil), casting = C.str(function() return mq.TLO.Me.Casting.Name() end, ''),
        ttype = C.str(function() return mq.TLO.Target.Type() end, ''),
        attack = C.safe(function() return mq.TLO.Me.Combat() end) == true,
    }
end

local function on(name, pat, fn) M.handlers[#M.handlers + 1] = { name = 'combatfx_' .. name, pat = pat, fn = fn } end
local function line_is_crit(line) return tostring(line or ''):find('Critical', 1, true) ~= nil end
local function my_name()
    if M.sim_state and M.sim_state.me and M.sim_state.me ~= '' then return M.sim_state.me end
    if C.CHAR and C.CHAR ~= '' and C.CHAR ~= 'char' then return C.CHAR end
    return C.str(function() return mq.TLO.Me.CleanName() end, '')
end
local function is_self(who)
    who = tostring(who or '')
    if who == '' then return false end
    local w = who:lower()
    if w == 'you' then return true end
    local me = my_name()
    return me ~= '' and w == me:lower()
end
local function push_spell(line, who, n, typ, sp)
    n = num(n)
    if not n then return end
    if line_is_crit(line) then push({ k = 'crit', n = n, src = 'spell', who = who, typ = typ, sp = sp })
    else push({ k = 'out', n = n, src = 'spell', who = who, typ = typ, sp = sp }) end
end
-- Live chat + debug capture. Named mq.event callbacks can go quiet while a #*#
-- "#*#" handler still sees every line (seen 2026-11-10: linelog tagged 90 youhits
-- after 22:28 while CV.crit/CV.proc never ran). Dispatch through the same Lua
-- matcher inject() uses, from the #*# path, so attack-off / re-engage still works.
M.LINE_LOG = true
local function logs_path(name)                    -- nil unless debug_logs=1 in config\combatfx_paths.ini
    local ok, PT = pcall(require, 'combatfx.paths')
    return ok and PT.log_path(name) or nil
end
local function line_interesting(line)
    local low = line:lower()
    local st = M.state()
    local tname = tostring(st.tname or ''):lower()
    return low:find('damage', 1, true)
        or low:find('non-melee', 1, true)
        or low:find('dummy', 1, true)
        or low:find('you hit', 1, true)
        or low:find('was hit', 1, true)
        or (tname ~= '' and #tname >= 3 and low:find(tname, 1, true))
end
local function write_line_log(line, tag)
    if not M.LINE_LOG then return end
    local path = logs_path('combatfx_lines.log')                 -- nil (debug_logs=0): skip before any TLO work
    if not path or not line_interesting(line) then return end
    local f = io.open(path, 'a')
    if not f then return end
    f:write(os.date('%Y-%m-%d %H:%M:%S'), ' match=', tag, ' line=', line:gsub('[%c]', ' '), '\n')
    f:flush()
    f:close()
end
M.lines = 0
function M.on_line(line)
    line = tostring(line or '')
    if line == '' then return nil end
    M.lines = M.lines + 1                                         -- f10: chat lines seen (Tracking: EQ log file hint)
    if FT._procs and #FT._procs > 0 then                          -- f8: your key-proc names, anywhere in a chat line
        local p = FT.proc_match(line); if p then push({ k = 'keyproc', name = p, line = line }) end
    end
    local evs = M.parser:classify(line, C.now())
    if evs then
        write_line_log(line, 'combatfx_' .. ((evs[1] and evs[1].k) or evs.ann or (evs.pending and 'ds?') or 'combat'))
        M.matched = M.matched + 1
        M.last_line, M.last_handler = line, 'combatfx_combat'
        C.guard('event combat', M.dispatch, evs, line)
        return 'combatfx_combat'
    end
    local h = M.first(line)
    write_line_log(line, h and h.name or 'NO_MATCH')
    if not h then return nil end
    M.matched = M.matched + 1
    M.last_line, M.last_handler = line, h.name
    local caps = { line:match(h.lpat) }
    C.guard('event ' .. h.name, h.fn, line, unpack(caps))
    return h.name
end
function M.capture_line(line)
    return M.on_line(line)
end
-- RoF2 / EQEmu chat formats (eqstr_us). Order matters only for the simulator matcher (first match wins, like distinct MQ events).
-- Trailing #*# so suffixes like " (Critical)" still match. Lines containing "Critical" are queued as crits.
-- pa1: every damage / heal / avoid / resist line goes through combatfx.parse (one classifier for the RoF2 and the TOB
-- client strings, crit announcements folded into the line they belong to, damage shields attributed by the swing
-- that follows). The handlers below only cover the non-combat lines.
on('slain', 'You have slain #1#!', function(_, who) push({ k = 'kill', who = who }) end)
on('slainby', '#1# has been slain by #2#!', function(_, who, by) push({ k = 'killby', who = who, by = by }) end)
on('begincast', 'You begin casting #1#.', function(_, sp) push({ k = 'cast', sp = sp }) end)
on('interrupt', 'Your spell is interrupted.', function() push({ k = 'castfail' }) end)
on('interrupt2', 'Your casting has been interrupted#*#', function() push({ k = 'castfail' }) end)
on('fizzle', 'Your spell fizzles!', function() push({ k = 'castfail' }) end)
-- add-ons
on('wornoff', 'Your #1# spell has worn off#2#', function(_, sp, rest) push({ k = 'wornoff', sp = sp, rest = rest }) end)
on('awaken', '#1# has been awakened by #2#.', function(_, who, by) push({ k = 'awaken', who = who, by = by }) end)
on('levelup', 'You have gained a level! Welcome to level #1#!', function(_, n) push({ k = 'level', n = n }) end)
on('aapoint', 'You have gained an ability point!#*#', function() push({ k = 'aa' }) end)
on('died', 'You have been slain by #1#!', function(_, by) push({ k = 'died', by = by }) end)
-- f8: loot lines for kill / loot moments (the loot window keeps its own mq.event registrations)
on('looted2', '--You have looted #1#.--#*#', function(line) push({ k = 'loot', line = line }) end)
on('looted', 'You have looted #1#.#*#', function(line) push({ k = 'loot', line = line }) end)

-- ---------------------------------------------------------------- combat lines -> queue records (pa1)
local P = require('combatfx.parse')
local pet_c, pet_t = '', -1e9
local function pet_name()
    if M.sim_state then return A.pet_name(M.sim_state) end
    local now = C.now()
    if now - pet_t > 1000 then pet_t = now; pet_c = A.pet_name(nil) or '' end
    return pet_c
end
M.parser = P.new(my_name, pet_name)
local AVOID_WORD = { miss = 'miss', dodge = 'dodge', parry = 'parry', block = 'block', riposte = 'riposte', rune = 'absorbed', invuln = 'invulnerable', other = 'miss' }
local SPECIAL_WORD = { ['Finishing Blow'] = 'FINISHING BLOW', ['Headshot'] = 'HEADSHOT', ['Assassinate'] = 'ASSASSINATE', ['Decapitate'] = 'DECAPITATE', ['Slay Undead'] = 'SLAY UNDEAD', ['Holy Blade'] = 'HOLY BLADE' }
function M.dispatch(evs, line)
    for _, ev in ipairs(evs) do
        local k = ev.k
        if k == 'dmg' and ev.who == 'me' then
            if ev.cat == 'melee' then
                local ab = FT.melee_ability(ev.verb)
                push({ k = ev.crit and 'crit' or 'out', n = ev.n, src = 'melee', who = ev.tgt, ab = ab, ev = ev })
                local w = A.PROC_VERB[ev.verb]; if w then push({ k = 'proc', w = w }) end
                if ev.cripple and not ev.cripple_shown then push({ k = 'proc', w = 'CRIPPLING BLOW' }); push({ k = 'keyproc', name = 'Crippling Blow' }) end
                if ev.special then push({ k = 'word', kind = 'crit', w = SPECIAL_WORD[ev.special] or ev.special:upper() }); push({ k = 'keyproc', name = ev.special }) end
            else
                push({ k = ev.crit and 'crit' or 'out', n = ev.n, src = ev.cat, who = ev.tgt, typ = ev.typ, sp = ev.sp, ev = ev })
            end
        elseif k == 'dmg' then                                   -- your pet
            push({ k = 'pet', who = pet_name(), n = ev.n, crit = ev.crit, spell = ev.cat ~= 'melee', typ = ev.typ, sp = ev.sp, ev = ev })
        elseif k == 'odmg' then
            push({ k = 'pet', who = ev.who, n = ev.n, crit = ev.crit, spell = ev.spell, typ = ev.typ, sp = ev.sp, ev = ev })
        elseif k == 'inc' then
            push({ k = 'in', n = ev.n, who = ev.who, dot = ev.cat == 'dot', ev = ev })
        elseif k == 'swing_in' then
            push({ k = 'word', kind = 'miss', w = AVOID_WORD[ev.how] or 'miss', avoid = true, ev = ev })
        elseif k == 'swing_out' then
            push({ k = 'word', kind = 'miss', w = AVOID_WORD[ev.how] or 'miss', out = true, ev = ev })
        elseif k == 'heal_in' then
            push({ k = 'healin', n = ev.n, who = ev.who ~= 'You' and ev.who or nil, ev = ev })
        elseif k == 'heal_out' then
            if ev.self then push({ k = 'stat', ev = ev }) else push({ k = 'healout', n = ev.n, who = ev.tgt, ev = ev }) end
        elseif k == 'resist_out' then
            push({ k = 'resist', sp = ev.sp, ev = ev }); push({ k = 'castfail' })
        elseif k == 'resist_in' then
            push({ k = 'word', kind = 'resist', w = 'resisted', ev = ev })
        elseif k == 'cripple_ann' then
            push({ k = 'proc', w = 'CRIPPLING BLOW' }); push({ k = 'keyproc', name = 'Crippling Blow' })
        elseif k == 'finish' then
            push({ k = 'word', kind = 'crit', w = 'FINISHING BLOW', ev = ev }); push({ k = 'keyproc', name = 'Finishing Blow' })
        elseif k == 'cast' then push({ k = 'cast', sp = ev.sp, ev = ev })                 -- f8b: the parser owns these lines now
        elseif k == 'died' then push({ k = 'died', by = ev.by, ev = ev })
        elseif k == 'ocast' then push({ k = 'ocast', who = ev.who, sp = ev.sp, ev = ev })
        else
            push({ k = 'stat', ev = ev })                         -- swing_pet, absorb, ods: numbers only
        end
    end
end

-- ---------------------------------------------------------------- matcher (simulator + mock)
local function topat(p)
    local s = p:gsub('([%^%$%(%)%%%.%[%]%+%-%?%*])', '%%%1')
    s = s:gsub('#%d#', '(.-)'):gsub('#%%%*#', '.-')
    return '^' .. s .. '$'
end
for _, h in ipairs(M.handlers) do h.lpat = topat(h.pat) end
M.topat = topat
-- run a line through the handler table: returns the handler name that matched (first match wins)
function M.inject(line)
    return M.on_line(line)
end

function M.first(line)
    for _, h in ipairs(M.handlers) do if line:match(h.lpat) then return h end end
end
function M.register()
    -- Prefer a single #*# ingest: first() picks the handler, same as inject().
    -- Named mq.event entries are a fallback only (they can stop firing while #*# continues).
    local ok = pcall(mq.event, 'combatfx_linelog', '#*#', function(line)
        M.on_line(line)
    end)
    if ok then
        M.registered = #M.handlers
        M._chat = 'linelog'
        return
    end
    local okc = 0
    for _, h in ipairs(M.handlers) do
        local ok2 = pcall(mq.event, h.name, h.pat, function(line, ...)
            local f = M.first(line)
            if f and f ~= h then return end
            M.on_line(line)
        end)
        if ok2 then okc = okc + 1 end
    end
    M.registered = okc
    M._chat = 'named'
end
function M.unregister()
    for _, h in ipairs(M.handlers) do pcall(mq.unevent, h.name) end
    pcall(mq.unevent, 'combatfx_linelog')
end

-- ---------------------------------------------------------------- stats (DPS / HPS / DTPS)
local S = { out = {}, heal = {}, inc = {}, fight_dmg = 0, fight_t0 = nil, fight_heal = 0, last_fight = nil }
M.stats = S
local function rec(list, n) list[#list + 1] = { C.now(), n } end
local function rate(list, win)
    local now, sum, i = C.now(), 0, 1
    while list[i] and now - list[i][1] > win do i = i + 1 end
    if i > 1 then for _ = 1, i - 1 do table.remove(list, 1) end end
    for _, e in ipairs(list) do sum = sum + e[2] end
    -- pa1: a fight younger than the window divides by its own age (min 1 s), not by the full 10 s
    local span = win
    if S.fight_t0 then span = math.max(1000, math.min(win, now - S.fight_t0)) end
    return sum / (span / 1000)
end
M.RATE_WIN = 10000
function M.rates() return rate(S.out, M.RATE_WIN), rate(S.heal, M.RATE_WIN), rate(S.inc, M.RATE_WIN) end

-- ---------------------------------------------------------------- processing (ImGui frame)
local ensure_fight
local last_out, last_in, last_heal_in, last_act = 0, 0, 0, 0
local streak, streak_t, streak_shown = 0, 0, 0
local cast = { sp = nil, t = 0, fail = false }
local crit_n, crit_t = nil, 0
local last_burst = 0
local last_spell_n, last_spell_t = nil, 0
local function resist_of(typ, sp)
    local t = typ and tostring(typ):gsub('^%s+', ''):gsub('%s+$', '') or ''
    if t ~= '' then
        local low = t:lower()
        if low ~= 'non-melee' and low ~= 'non melee' then return t end
    end
    if sp and tostring(sp) ~= '' then
        local name = tostring(sp):gsub('%.$', ''):gsub('%s+$', '')
        local rt = A.spell and A.spell(name, 'ResistType') or nil
        if rt and tostring(rt) ~= '' and tostring(rt) ~= 'NULL' then return tostring(rt) end
    end
    return nil
end
local function mark_spell(n)
    last_spell_n, last_spell_t = n, C.now()
end
local function is_spell_echo(n)
    return n and last_spell_n == n and C.now() - last_spell_t < 250
end
local function do_burst(typ, handler, line, sp)
    last_burst = C.now()
    FX.burst(resist_of(typ, sp), handler or M.last_handler, line or M.last_line)
end
local function hit_out(n)
    last_out = C.now(); ensure_fight()
    S.fight_dmg = S.fight_dmg + n; rec(S.out, n)
    FX.shake()
    if C.now() - streak_t > 2500 then streak = 0 end
    streak, streak_t = streak + 1, C.now()
    if streak >= 5 and (streak % 5 == 0) and streak ~= streak_shown then streak_shown = streak; FX.streak(streak) end
end
M.IDLE_END = 12000
M.DOT_GRACE = 7000                                                -- ps1: a DoT ticks every 6 s
function M.start_fight(now, st, banner)
    -- f8: EQ's combat flag often turns on a moment after the first hit already opened the fight: keep those hits
    if S.fight_t0 and now - S.fight_t0 < 5000 then
        if banner then FX.banner('ENGAGED', st.tname ~= '' and st.tname or '', '#ffb070', 'combat'); A.engage(st) end
        return
    end
    S.fight_t0, S.fight_dmg, S.fight_heal = now, 0, 0
    S.saw_combat = st and st.combat or false                     -- ps1
    C.guard('track fight', TK.fight_start, now)                  -- f10
    S.killed = false
    A.fight_reset()
    FT.enc_reset(now, st and st.tname or '')
    FT.st_reset(now, now)                                         -- pa1
    if banner then
        FX.banner('ENGAGED', st.tname ~= '' and st.tname or '', '#ffb070', 'combat'); A.engage(st)
    end
    if st and st.tname and st.tname ~= '' then C.guard('mob warn', PS.on_engage, st.tname, now) end      -- f8b
end
function M.end_fight(now)
    if not S.fight_t0 then return end
    local secs = (math.max(last_out, last_in, last_act, S.fight_t0) - S.fight_t0) / 1000      -- active time, not idle tail
    if FT.stats().events > 0 then secs = FT.st_secs(now) end      -- pa1: first -> last damage / swing, min 1 s (one-hit fights)
    S.last_fight = { dmg = S.fight_dmg, secs = secs, heal = S.fight_heal }
    S.fight_t0 = nil
    C.guard('track fight', TK.fight_end, now)                    -- f10
    FX.banner('COMBAT ENDED', string.format('%s dmg in %ds (%s dps)', C.fmt(S.last_fight.dmg), math.floor(secs), C.fmt(secs > 0 and S.last_fight.dmg / secs or 0)), '#a0d0ff', 'combat')
    FX.meter_live(nil)
    local st = FT.stats().events > 0 and FT.stats_export() or nil
    C.guard('parse history', PS.on_fight_end, secs, st, { mob = FT.enc_target and FT.enc_target() or nil, killed = S.killed })      -- f8b
    A.recap(secs, S.last_fight.dmg, S.last_fight.heal)
end
function M.in_fight() return S.fight_t0 ~= nil end                 -- fd1: Parses > Current fight
ensure_fight = function() if not S.fight_t0 then M.start_fight(C.now(), M.state(), false) end end
function M.process()
    A.sim = M.sim_state ~= nil
    local budget = 40                                             -- bound per-frame work even under chat floods
    while Q[1] and budget > 0 do
        budget = budget - 1
        local r = table.remove(Q, 1)
        C.guard('record ' .. tostring(r.k), M.one, r)
    end
end
-- f8: ability name for the recap (verb / spell / DoT name), the spell school for the school looks
local function ab_name(r)
    if r.ab then return r.ab end
    if r.sp and r.sp ~= '' then return (tostring(r.sp):gsub('%.$', '')) end
    if r.src == 'spell' then return 'Spells' end
    if r.src == 'dot' then return 'DoTs' end
    return 'Melee'
end
local crit_ab = nil
local ocrit = {}
local loot_q = {}
M.loot_q = loot_q
local function school_opts(r, base)
    if not ((C.cfg.school and C.cfg.school.on) or FT.forced('school')) then return base end
    if r.src ~= 'spell' and r.src ~= 'dot' and not r.typ then return base end
    local sc = FT.school_of(resist_of(r.typ, r.sp))
    if not sc then return base end
    local o = {}; for k2, v in pairs(base or {}) do o[k2] = v end
    o.school = sc
    return o
end
M.school_opts = school_opts
function M.one(r)
    do
        local k = r.k
        local ev = r.ev
        if ev then                                                -- pa1: fight stats (every kind, numbers only)
            if FT.ST_ACTIVE[ev.k] then ensure_fight(); last_act = C.now() end
            if S.fight_t0 then FT.st_add(ev, C.now()) end
            C.guard('parses note', PS.note, ev, C.now())                -- f8b: death-recap ring + mob learning
            C.guard('track', TK.on_ev, ev, C.now())                    -- f10: Tracking tab
        else C.guard('track', TK.on_rec, r, C.now()) end
        if k == 'stat' then
        elseif k == 'out' and r.n then
            FX.number(r.src == 'ds' and 'spell' or r.src, r.n, school_opts(r, nil)); hit_out(r.n); A.hit(r.n, false)
            FT.enc_hit(ab_name(r), r.n, false, C.now())
            if r.src == 'spell' then mark_spell(r.n); do_burst(r.typ, nil, nil, r.sp) end
        elseif k == 'crit' and r.n then
            FX.number('crit', r.n, school_opts(r, { crit = true })); FX.crit_flash(); hit_out(0)
            S.fight_dmg = S.fight_dmg + r.n; rec(S.out, r.n); A.hit(r.n, true)
            crit_ab = ab_name(r); FT.enc_hit(crit_ab, r.n, true, C.now())
            -- typed spell / proc crits keep the stronger gold crit and add a tight colored flash
            if r.src == 'spell' or r.typ then mark_spell(r.n); do_burst(r.typ, nil, nil, r.sp) end
        elseif k == 'in' and r.n then
            last_in = C.now(); ensure_fight(); A.count('inhits')
            FX.number('incoming', r.n, { prefix = '-' }); rec(S.inc, r.n)
            local st = M.state()
            local pct = (st.maxhp and st.maxhp > 0) and (r.n / st.maxhp * 100) or 4
            FX.damage_flash(pct)
        elseif k == 'healin' and r.n then
            last_heal_in = C.now()
            FX.number('healin', r.n, { prefix = '+' }); FX.heal_fx()
            local st = M.state()
            if FT.big_heal(r.n, st.maxhp) then
                FX.alert('heal', '+' .. C.fmt(r.n), string.format('%s%d%% of max HP', r.who and (r.who .. ' · ') or '', math.floor(r.n / st.maxhp * 100 + 0.5)), C.cfg.color.healin)
            end
        elseif k == 'healout' and r.n then
            FX.number('healout', r.n, { prefix = '+' }); S.fight_heal = S.fight_heal + r.n; rec(S.heal, r.n)
        elseif k == 'word' then
            FX.number(r.kind, r.w, { out = r.out })
            if r.avoid then A.count('avoid') elseif r.out then A.count('swings') end
        elseif k == 'resist' then
            local w, col = A.resist_word(r.sp)
            FX.number('resist', w, { color = col })
        elseif k == 'proc' then A.callout(r.w)
        elseif k == 'keyproc' then
            local now = C.now()
            if now - (M._kp_t or 0) > 1200 or M._kp_n ~= r.name then
                M._kp_t, M._kp_n = now, r.name
                FX.alert('proc', (tostring(r.name):gsub('^%l', string.upper)):gsub(' %l', string.upper), 'proc', C.cfg.color.proc)
            end
        elseif k == 'ocrit' then
            if r.who then ocrit[r.who:lower()] = { n = r.n, t = C.now() } end
        elseif k == 'pet' and r.n then
            local pn = A.pet_name(M.sim_state)
            if pn ~= '' and r.who and r.who:lower() == pn:lower() then
                A.count('petdmg', r.n); S.fight_dmg = S.fight_dmg + r.n; rec(S.out, r.n)
                FT.enc_other('pet', r.n)
                if FX.on('pet') then FX.number('pet', r.n) end
            elseif r.who and A.is_group(r.who) then
                -- f8: a group member's hit (only when EQ shows others' hits in chat); never counted as your damage
                local oc = ocrit[r.who:lower()]
                local crit = r.crit or (oc and oc.n == r.n and C.now() - oc.t < 400)
                FT.enc_other('group', r.n)
                FX.number('group', r.n, school_opts(r, { crit = crit or nil, group = true }))
            end
        elseif k == 'wornoff' then A.worn_off(r.sp, r.rest)
        elseif k == 'awaken' then A.awakened(r.who, r.by)
        elseif k == 'level' then A.level(r.n)
        elseif k == 'aa' then A.aa()
        elseif k == 'died' then A.died(r.by); C.guard('death recap', PS.on_died, r.by, C.now())
        elseif k == 'ocast' then if not TK.warned_now(r.who, r.sp) then C.guard('mob cast', PS.on_ocast, r.who, r.sp, C.now()) end
        elseif k == 'kill' then
            S.killed = true
            FX.number('kill', 'SLAIN', {})
            -- a named kill: the flourish carries the name, so the SLAIN banner does not repeat it underneath
            -- ps1: the card and its sound are separate switches (Parses > Settings); card off + sound on = the sound alone
            local card, snd = C.cfg.moments.named or FT.forced('moment.named'), FT.moment_snd('named')
            local nk = (card or snd) and A.named_killed(r.who)
            local shown = nk and card and FX.moment('NAMED SLAIN', r.who or '', '#ffd040', snd)
            if nk and not card and snd then FT.play() end
            FX.banner('SLAIN', shown and '' or (r.who or ''), C.cfg.color.kill, 'kill')
        elseif k == 'loot' then
            local okT, TR = pcall(require, 'combatfx.tracker')
            local name = okT and TR and TR.parse and TR.parse(r.line)
            local card = C.cfg.moments.loot or FT.forced('moment.loot')
            if name and (card or FT.moment_snd('loot')) then loot_q[#loot_q + 1] = { name = name, t = C.now() + 450, card = card } end    -- item lands in bags a moment later
        elseif k == 'killby' then
            -- kills by others are not celebrated; a group member dying is an alert (add-on)
            A.slain_other(r.who, r.by)
        elseif k == 'cast' then cast = { sp = r.sp, t = C.now(), fail = false }; A.cast(r.sp)
        elseif k == 'castfail' then cast.fail = true; FX.cast_stop()
        end
    end
end

-- ---------------------------------------------------------------- state watcher (4 Hz): HP effects, combat banners, plate, fallbacks
local W = { hp = nil, combat = false, tid = 0, tpct = nil, casting = '', next = 0, low = false }
function M.reset_watch() W.hp, W.combat, W.tid, W.tpct, W.casting = nil, false, 0, nil, '' end
function M.watch()
    local now = C.now()
    if now < W.next then return end
    W.next = now + 250
    local held = M.parser.flush and M.parser:flush(now)                -- lc1: a held pet "strikes" hit with no spell twin
    if held then C.guard('event combat', M.dispatch, held, '') end
    local st = M.state()
    -- self HP: damage flash fallback (no "hits YOU" line in 600 ms) and heal glow fallback
    if st.hp and W.hp then
        local d = W.hp - st.hp
        if d >= 3 and now - last_in > 600 then FX.damage_flash(d) end
        if d <= -8 and now - last_heal_in > 600 then FX.heal_fx() end
    end
    W.hp = st.hp
    local low = st.hp and st.hp > 0 and st.hp < 35
    if low ~= W.low then W.low = low; FX.vignette(low) end
    -- fight start / end. A fight ends when: EQ says combat is over, OR attack is off and there is no target,
    -- OR nothing hit you or was hit by you for IDLE_END ms. A new fight starts on the next engage or on the next hit.
    -- ps1 fix: EQ's combat flag is not proof the fight is over. A caster DoTing (or nuking) a mob that never fights back
    -- (training dummy, a mezzed / rooted mob) has CombatState != COMBAT and Me.Combat false the whole time: the old
    -- "not st.combat -> end" closed the fight 250 ms after the first tick, so every later tick opened a new 1 s fight.
    -- Now: the flag only ends a fight it was seen on (or on 'lost'), and then only after the kill or once nothing has
    -- landed for DOT_GRACE (one 6 s DoT tick + slack). Without the flag, only IDLE_END (12 s, as the reference) ends it.
    local quiet = S.fight_t0 and now - math.max(last_out, last_in, last_act, S.fight_t0)
    local idle = S.fight_t0 and quiet > M.IDLE_END
    if S.fight_t0 and st.combat then S.saw_combat = true end
    local lost = S.fight_t0 and not st.attack and (st.tid or 0) == 0
    local off = S.fight_t0 and ((not st.combat and S.saw_combat) or lost)
    if S.fight_t0 and (idle or (off and (S.killed or quiet > M.DOT_GRACE))) then M.end_fight(now) end
    if st.combat and not W.combat then M.start_fight(now, st, true) end
    W.combat = st.combat
    -- target plate + outgoing fallback (target HP% dropped while we fight and no damage line matched)
    local npc = st.ttype == '' or st.ttype == 'NPC'
    FX.plate(st.combat and st.tid ~= 0 and npc, st.tname, st.tpct)
    if st.tid ~= W.tid then W.tid, W.tpct = st.tid, st.tpct
    else
        if st.tpct and W.tpct and st.tpct < W.tpct and st.combat and now - last_out > 2500 then
            FX.number('melee', string.format('-%d%%', W.tpct - st.tpct)); FX.shake(); last_out = now
        end
        W.tpct = st.tpct
    end
    -- cast landing: casting -> idle without an interrupt/fizzle/resist
    if W.casting ~= '' and st.casting == '' then
        FX.cast_stop()
        local c = cast
        -- only if no damage line already spawned a proc/burst (avoids stacking two clouds per nuke)
        if not c.fail and now - c.t < 20000 and now - last_out > 500 and now - last_burst > 500 then do_burst(nil, 'cast-end', W.casting, W.casting) end
        cast.fail = false
    end
    W.casting = st.casting or ''
    -- f8: live meter (2 Hz, diffed writes) and loot moments (FindItem once the item is in your bags)
    if now >= (W.lm_next or 0) then
        W.lm_next = now + 500
        if S.fight_t0 then FX.meter_live(FT.meter_data(now, (M.rates()))) else FX.meter_live(nil) end
    end
    local i = 1
    while loot_q[i] do
        local e = loot_q[i]
        if now >= e.t then
            table.remove(loot_q, i)
            local lore, val = A.item_info(e.name)
            local why = FT.loot_interesting(e.name, lore, val)
            local snd = FT.moment_snd('loot')
            if why and e.card then FX.moment(why == 'LORE' and 'LORE DROP' or (why == 'VALUABLE' and 'VALUABLE DROP' or 'WATCHED DROP'), e.name, why == 'LORE' and '#ffb040' or '#80e0ff', snd)
            elseif why and snd then FT.play() end
        else i = i + 1 end
    end
end
return M
