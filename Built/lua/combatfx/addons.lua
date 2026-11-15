-- combatfx add-ons: big hits + record, skill callouts, pet numbers, buff fading, spell ready, mez break + aggro,
-- group danger, fight recap, named / level / AA stamps, resist type, death screen, cast bar.
-- Chat-driven parts are called from events.lua; TLO parts poll here at 1-2 Hz only (never per frame).
local mq = require('mq')
local C = require('combatfx.core')
local FX = require('combatfx.fx')
local FT = require('combatfx.features')   -- f8
local M = { sim = false }

-- ---------------------------------------------------------------- per-fight counters (recap)
local F
function M.fight_reset() F = { hits = 0, crits = 0, top = 0, swings = 0, misses = 0, inhits = 0, avoid = 0, resists = 0, petdmg = 0 } end
M.fight_reset()
function M.fight() return F end
function M.count(k, n) F[k] = (F[k] or 0) + (n or 1) end

-- ---------------------------------------------------------------- 1 big hits: session 95th percentile + per-character best
local hist, nh, thr = {}, 0, nil
function M.hit(n, crit)
    if not n or n <= 0 then return end
    F.hits = F.hits + 1; if crit then F.crits = F.crits + 1 end; if n > F.top then F.top = n end
    nh = nh + 1; hist[(nh - 1) % 200 + 1] = n
    if nh >= 40 and nh % 20 == 0 then
        local t = {}; for i = 1, math.min(nh, 200) do t[i] = hist[i] end
        table.sort(t); thr = t[math.max(1, math.floor(#t * 0.95))]
    end
    local best = M.sim and (M.sim_best or C.cfg.rec.best or 0) or (C.cfg.rec.best or 0)
    if n > best then
        if M.sim then M.sim_best = n else C.cfg.rec.best = n; C.save_cfg() end      -- practice hits never touch your record
        if best > 0 then FX.stamp('NEW RECORD  ' .. C.fmt(n), '#ffe040'); return end
    end
    if thr and n >= thr then FX.stamp('MASSIVE', '#ffb347') end
end

-- ---------------------------------------------------------------- 2 skill callouts
M.PROC_VERB = { backstab = 'BACKSTAB', frenzy = 'FRENZY' }
function M.callout(word)
    if FX.on('procs') and C.cfg.on.proc then FX.number('proc', word, {}) end
end

-- ---------------------------------------------------------------- 3 pet name (sim or live)
function M.pet_name(st)
    if st and st.pet then return st.pet end
    return C.str(function() return mq.TLO.Me.Pet.CleanName() end, '')
end

-- ---------------------------------------------------------------- 6 / 10 / 4 spell helpers
local SIM_SPELL = { ["Tashan's Lingering Cry"] = { rt = 'Magic' }, ['Ancient: Chaotic Visions'] = { rt = 'Magic' }, ['Flame Lick'] = { rt = 'Fire' },
    ['Color Slant'] = { sub = 'Enthrall' }, ['Greater Fetter'] = { sub = 'Root' }, ['Gift of Pure Thought'] = { ms = 2500 } }
local function spell(name, field)
    local v = C.safe(function() return mq.TLO.Spell(name)[field]() end)
    if v == nil or v == 'NULL' then local s = SIM_SPELL[name]; if s then v = (field == 'ResistType' and s.rt) or (field == 'Subcategory' and s.sub) or (field == 'MyCastTime' and s.ms) or nil end end
    return v
end
M.spell = spell
local RT_COL = { Magic = '#b080ff', Fire = '#ff7a3a', Cold = '#7ac8ff', Poison = '#7ad040', Disease = '#c8b060', Chromatic = '#ffffff', Prismatic = '#ffffff', Corruption = '#a03050', Unresistable = '#ffffff' }
function M.resist_word(sp)
    F.resists = F.resists + 1
    if not (sp and FX.on('resisttype')) then return 'RESIST', nil end
    local rt = spell(sp, 'ResistType')
    if not rt or rt == '' then return 'RESIST', nil end
    return 'RESIST · ' .. tostring(rt):upper(), RT_COL[tostring(rt)]
end

-- worn-off lines: "Your X spell has worn off." (you) or "... worn off of Y." (your spell on a target)
function M.worn_off(sp, rest)
    local on = tostring(rest or ''):match('^ of (.-)%.?$')
    if on and on ~= '' then
        local sub = tostring(spell(sp, 'Subcategory') or '')
        local low = sp:lower()
        if sub == 'Enthrall' or sub == 'Root' or low:find('mez') or low:find('root') or low:find('fetter') then
            FX.toast('ccbreak', string.format('%s FADED  ·  %s', (sub == 'Root' or low:find('root') or low:find('fetter')) and 'ROOT' or 'MEZ', on), '#ff9a5a'); FX.edge('ccbreak')
        end
        return
    end
    FX.toast('buffwarn', sp .. ' faded', '#a0a8b8')
end
function M.awakened(who, by)
    FX.toast('ccbreak', string.format('MEZ BROKE  ·  %s (by %s)', who or '?', by or '?'), '#ff6a4a'); FX.edge('ccbreak')
end

-- ---------------------------------------------------------------- 7 group deaths (chat)
local function group_names()
    local t = {}
    local n = C.num(function() return mq.TLO.Group.Members() end, 0)
    for i = 1, n do local nm = C.str(function() return mq.TLO.Group.Member(i).CleanName() end, nil); if nm then t[nm:lower()] = nm end end
    return t
end
-- f8: group member names (Group.Member(i).CleanName, refreshed at most once a second) for group-hit numbers
local gcache, gcache_t = {}, -1e9
M.SIM_GROUP = { tankard = 'Tankard', clerica = 'Clerica', stabbs = 'Stabbs' }
function M.is_group(who)
    if not who or who == '' then return false end
    if M.sim then return M.SIM_GROUP[who:lower()] ~= nil end
    local now = C.now()
    if now - gcache_t > 1000 then gcache_t = now; gcache = group_names() end
    return gcache[who:lower()] ~= nil
end
-- f8: named mobs you engaged (Target.Named() at engage, the same TLO the NAMED stamp uses), checked on 'You have slain X!'
local named_seen = {}
function M.named_killed(who)
    if not who or who == '' then return false end
    local low = who:lower()
    local e = named_seen[low]
    if e and C.now() - e < 1800000 then named_seen[low] = nil; return true end
    if M.sim then return false end
    -- you may kill a named you never engaged through the watcher (e.g. one-shot): the live target is the evidence
    local tn = C.str(function() return mq.TLO.Target.CleanName() end, '')
    if tn:lower() == low and C.safe(function() return mq.TLO.Target.Named() end) == true then return true end
    return false
end
function M.note_named(name) if name and name ~= '' then named_seen[name:lower()] = C.now() end end
-- f8: item flags for loot moments (FindItem finds it in your bags right after looting)
M.SIM_ITEMS = { ['Cloak of Flames'] = { lore = true, v = 250000 }, ['Bone Chip'] = { lore = false, v = 5 }, ['Ruby'] = { lore = false, v = 95000 } }
function M.item_info(name)
    if M.sim then local it = M.SIM_ITEMS[name]; if it then return it.lore, it.v end; return false, nil end
    local lore = C.safe(function() local it = mq.TLO.FindItem('=' .. name); if it() then return it.Lore() end end)
    local val = C.num(function() local it = mq.TLO.FindItem('=' .. name); if it() then return it.Value() end end, nil)
    return lore == true, val
end
function M.slain_other(who, by)
    if not who then return end
    local g = M.sim and { tankard = 'Tankard' } or group_names()
    local nm = g[who:lower()]
    if nm then FX.toast('group', nm .. ' DIED', '#ff4040'); FX.edge('group') end
end
function M.group_low(name, pct) FX.toast('group', string.format('%s  %d%%', name, pct), '#ff6060'); FX.edge('group') end

-- ---------------------------------------------------------------- 9 stamps
function M.engage(st)
    local named, con
    if M.sim then named, con = st.named, st.con
    else
        named = C.safe(function() return mq.TLO.Target.Named() end) == true
        con = C.str(function() return mq.TLO.Target.ConColor() end, '')
    end
    if named then FX.toast('stamps', 'NAMED  ·  ' .. (st.tname or ''), '#ffd040'); pcall(function() FX.gold_flare() end); M.note_named(st.tname) end
    if con == 'GREY' then FX.toast('stamps', 'GREY CON  ·  no experience', '#a0a8b8') end
end
function M.level(n) FX.toast('stamps', 'LEVEL ' .. tostring(n or '') .. '!', '#ffe08a'); pcall(function() FX.gold_flare() end) end
function M.aa() FX.toast('stamps', 'AA POINT GAINED', '#c8a0ff') end

-- ---------------------------------------------------------------- 8 recap
function M.recap(secs, dmg, heal)
    -- pa1: the parser stats decide (a one-hit fight still gets a recap; secs is first -> last event, min 1 s)
    local st = FT.stats_export and FT.stats_export() or nil
    local any = st and (st.events or 0) > 0
    if not any and (not F or F.hits + F.swings + F.inhits == 0 or secs < 3) then return end
    -- f8: full breakdown (top abilities, crit rate, biggest hit, damage-over-time graph) when there is ability data
    local d = FT.recap_data(secs, 36)
    if d.hits > 0 or any then
        d.st = st
        local extra = {}
        if (d.group or 0) > 0 then extra[#extra + 1] = { 'Group damage', C.fmt(d.group) } end
        -- f8b: spell timeline strip + group / raid ranking; dropped (group first) when the card would not fit the screen
        local PS = package.loaded['combatfx.parses']
        local tlh = (C.cfg.parses == nil or C.cfg.parses.tl ~= false) and FT.timeline_html(st and st.tl, secs, (C.cfg.parses and tonumber(C.cfg.parses.gap)) or 3) or ''
        local gh = (PS and st) and PS.group_html(st, secs) or ''
        local _, SH = C.screen()
        local lim = math.max(300, (tonumber(SH) or 1080) - 16)
        d.more = tlh .. gh
        local html = FT.recap_html(d, extra)
        if FT.recap_height(html) > lim and gh ~= '' then d.more = tlh; html = FT.recap_html(d, extra) end
        if FT.recap_height(html) > lim and tlh ~= '' then d.more = ''; html = FT.recap_html(d, extra) end
        M.last_recap = d
        FX.recap(html, 12)
        return
    end
    local function r(k, v) return string.format('<span class="rr"><span class="rk">%s</span><span class="rv">%s</span></span>', k, v) end
    local crit = F.hits > 0 and (F.crits / F.hits * 100) or 0
    local att = F.inhits + F.avoid
    local html = '<span class="rh">FIGHT RECAP  ·  ' .. math.floor(secs) .. 's</span>' ..
        r('Damage', string.format('%s  (%s dps)', C.fmt(dmg), C.fmt(dmg / secs))) ..
        r('Top hit', C.fmt(F.top)) ..
        r('Crit rate', string.format('%.0f%%  (%d of %d)', crit, F.crits, F.hits)) ..
        r('You avoided', att > 0 and string.format('%.0f%%  (%d of %d)', F.avoid / att * 100, F.avoid, att) or '-') ..
        r('Healing done', C.fmt(heal or 0)) ..
        (F.petdmg > 0 and r('Pet damage', C.fmt(F.petdmg)) or '') ..
        (F.resists > 0 and r('Resists', tostring(F.resists)) or '')
    FX.recap(html)
end

-- ---------------------------------------------------------------- 11 death
function M.died(by)
    local zone = C.str(function() return mq.TLO.Zone.Name() end, '')
    FX.vignette(false)
    FX.death(string.format('Slain by %s%s  ·  %s', by or '?', zone ~= '' and ('  ·  ' .. zone) or '', os.date('%H:%M')))
end

-- ---------------------------------------------------------------- 12 cast bar
function M.cast(sp)
    FX._spell_rt = spell(sp, 'ResistType')
    local v = tonumber(spell(sp, 'MyCastTime') or nil)
    if v and v > 0 and v <= 60 then v = v * 1000 end               -- builds differ: seconds or ms
    FX.cast_start(sp, v)
end

-- ---------------------------------------------------------------- TLO polling: buffs + gems (1 Hz), group + aggro (2 Hz)
local nxt1, nxt2 = 0, 0
local buffs, gems, glow, aggro_last = {}, {}, {}, 0
M.BUFF_WARN_S = 15
function M.buff_tick(name, secs, now)
    local b = buffs[name]; if not b then b = { max = secs }; buffs[name] = b end
    if secs > b.max then b.max = secs end
    b.seen = now
    -- f8: threshold + watch list from settings (Alerts tab); the alert is drawn beside the character
    local thr = (C.cfg.alerts and C.cfg.alerts.buff) and FT.buff_threshold() or M.BUFF_WARN_S
    local listed = FT.buff_watched(name)
    local has_list = FT._buffs and #FT._buffs > 0
    if secs > thr + 2 then b.warned = false
    elseif not b.warned and secs > 0 and listed and (b.max >= 60 or has_list) then
        b.warned = true
        local txt = string.format('%d:%02d', math.floor(secs / 60), math.floor(secs % 60))
        if not FX.alert('buff', name, txt .. ' left', '#ffd27a') then FX.toast('buffwarn', string.format('%s fading  %s', name, txt), '#ffd27a') end
    end
end
function M.gem_tick(i, name, ready, now)
    local g = gems[i]
    if not g or g.name ~= name then gems[i] = { name = name, ready = ready, since = now }; return end
    if ready ~= g.ready then
        if ready and now - g.since >= 20000 then FX.toast('ready', name .. '  READY', '#8ac8ff') end
        g.ready, g.since = ready, now
    end
end
function M.group_tick(name, pct, now)
    local g = glow[name]; if not g then g = { pct = pct, t = 0 }; glow[name] = g end
    if pct and pct > 0 and pct < 30 and (g.pct or 100) >= 30 and now - g.t > 8000 then g.t = now; M.group_low(name, math.floor(pct)) end
    g.pct = pct
end
function M.aggro_tick(pct, ingroup, combat)
    if ingroup and combat and pct >= 100 and aggro_last < 100 then FX.toast('ccbreak', 'AGGRO  ·  the mob is on you', '#ff8a00'); FX.edge('ccbreak') end
    aggro_last = pct
end
function M.poll()
    if M.sim or not C.cfg.master then return end
    local now = C.now()
    if now >= nxt1 then
        nxt1 = now + 1000
        if C.cfg.fx.buffwarn or (C.cfg.alerts and C.cfg.alerts.buff) then
            local slots = C.num(function() return mq.TLO.Me.MaxBuffSlots() end, 30)
            for i = 1, math.min(slots, 42) do
                local nm = C.str(function() return mq.TLO.Me.Buff(i).Name() end, nil)
                if nm then
                    local s = C.num(function() return mq.TLO.Me.Buff(i).Duration.TotalSeconds() end, nil)
                    if s then M.buff_tick(nm, s, now) end
                end
            end
            for k, b in pairs(buffs) do if now - (b.seen or 0) > 5000 then buffs[k] = nil end end
        end
        if C.cfg.fx.ready then
            local n = C.num(function() return mq.TLO.Me.NumGems() end, 8)
            for i = 1, math.min(n, 14) do
                local nm = C.str(function() return mq.TLO.Me.Gem(i).Name() end, nil)
                if nm then M.gem_tick(i, nm, C.safe(function() return mq.TLO.Me.SpellReady(i)() end) == true, now) else gems[i] = nil end
            end
        end
    end
    if now >= nxt2 then
        nxt2 = now + 500
        local n = C.num(function() return mq.TLO.Group.Members() end, 0)
        if C.cfg.fx.group then
            for i = 1, n do
                local nm = C.str(function() return mq.TLO.Group.Member(i).CleanName() end, nil)
                if nm then M.group_tick(nm, C.num(function() return mq.TLO.Group.Member(i).PctHPs() end, nil), now) end
            end
        end
        if C.cfg.fx.ccbreak then
            local combat = C.safe(function() return mq.TLO.Me.CombatState() end) == 'COMBAT'
            M.aggro_tick(C.num(function() return mq.TLO.Me.PctAggro() end, 0), n > 0, combat)
        end
    end
end
return M
