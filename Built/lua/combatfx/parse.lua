-- combatfx/parse.lua (pa1): one classifier for every combat line EQ prints, RoF2 (eqstr_us of the RoF2 client) and
-- TOB client strings (eqstr_us of the TOB client) side by side. Returns zero or more events; no UI, no globals.
--   dmg      { who = 'me'|'pet', cat = 'melee'|'spell'|'dot'|'ds', n, crit, tgt, verb, sp, typ, flags, cripple }
--   odmg     { who = name, n, crit, tgt, spell }            someone else's hit (group / others)
--   inc      { cat = 'melee'|'spell'|'dot'|'ds'|'env', n, who, flags }
--   swing_in { how = 'miss'|'dodge'|'parry'|'block'|'riposte'|'rune'|'invuln'|'other', who }
--   swing_out{ how, tgt }    swing_pet { how }
--   heal_in  { n, who, crit, over, sp, hot }   heal_out { n, tgt, crit, over, sp, hot, self }
--   resist_out { sp }  resist_in { sp }  absorb { n }  finish {}  ods { n, who } (a non-melee hit that was not your shield)
--   f8b: oheal { who, tgt, n } (others healing others), cast { sp } / activate { sp } (yours), ocast { who, sp }, died { by }
-- Crit announcements of the RoF2 client ("Tester scores a critical hit! (N)", "You deliver a critical blast! (N)",
-- "... lands a Crippling Blow!(N)", "... performs an exceptional heal! (N)") are never damage: they flag the next
-- matching line of the same actor (your pet's melee for your melee crits). Their number is not the damage on this
-- server (seen: crit (14347) -> slash 14430), so amounts always come from the damage line.
-- "X was hit by non-melee for N points of damage." (eqstr 434) is your damage shield when X swings at YOU right after
-- (EQ prints the shield before the swing); otherwise it is someone else's and never counted as yours.
local P = {}
local VERB = {}
for v in ([[hit hits slash slashes crush crushes pierce pierces punch punches kick kicks bash bashes backstab backstabs bite bites
    claw claws strike strikes smash smashes slice slices sting stings maul mauls gore gores rend rends shoot shoots slam slams hack hacks
    backhand backhands bludgeon bludgeons lash lashes stab stabs beat beats burn burns rake rakes sweep sweeps stomp stomps chomp chomps
    thrust thrusts frenzy frenzies learn learns]]):gmatch('%a+') do VERB[v] = true end
P.VERB = VERB
local WEAPON = { hit = 1, hits = 1, slash = 1, slashes = 1, crush = 1, crushes = 1, pierce = 1, pierces = 1, punch = 1, punches = 1, bite = 1, claw = 1,
    strike = 1, smash = 1, slice = 1, sting = 1, maul = 1, gore = 1, rend = 1, hack = 1, backhand = 1, shoot = 1 }
P.WEAPON = WEAPON
local CRITW = { ['Critical'] = true, ['Lucky Critical'] = true, ['Crippling Blow'] = true, ['Deadly Strike'] = true }
local SPECIAL = { ['Finishing Blow'] = true, ['Headshot'] = true, ['Assassinate'] = true, ['Decapitate'] = true, ['Slay Undead'] = true, ['Holy Blade'] = true }
P.SPECIAL = SPECIAL

local function num(s) return tonumber((tostring(s or ''):gsub(',', ''))) end
local function lower(s) return tostring(s or ''):lower() end
local function esc(s) return (tostring(s):gsub('([%^%$%(%)%%%.%[%]%*%+%-%?])', '%%%1')) end

-- trailing "(Critical)" "(Lucky Critical) (Twincast)" ...: only word groups, never "(1234)"
local function split_suffix(line)
    local base, flags = line, {}
    while true do
        local b, f = base:match('^(.-)%s*%(([%a][%a ]*)%)%s*$')
        if not b or b == '' then break end
        table.insert(flags, 1, f); base = b
    end
    if #flags == 0 then return line, flags end
    -- only strip from combat sentences (keeps "X begins to cast a spell. (Name)" untouched)
    if not (base:find('damage%.?$') or base:find('points?%.?$') or base:find('[!%.]$')) then return line, {} end
    return base, flags
end
P.split_suffix = split_suffix

local function avoid_kind(how)
    local h = lower(how)
    if h == 'miss' or h == 'misses' or h:find(' misses$') or h:find(' miss$') then return 'miss' end
    if h:find('invulnerable', 1, true) then return 'invuln' end
    if h:find('magical skin', 1, true) or h:find('absorb', 1, true) then return 'rune' end
    if h:find('dodge', 1, true) then return 'dodge' end
    if h:find('parr', 1, true) then return 'parry' end
    if h:find('block', 1, true) then return 'block' end
    if h:find('ripost', 1, true) then return 'riposte' end
    return 'other'
end
P.avoid_kind = avoid_kind

function P.new(me_fn, pet_fn)
    local S = { pend = {}, ds = {}, carry = {}, i = 0, me_fn = me_fn, pet_fn = pet_fn }
    return setmetatable(S, { __index = P })
end
function P:me() local m = self.me_fn and self.me_fn() or ''; return lower(m) end
function P:pet() local p = self.pet_fn and self.pet_fn() or ''; return lower(p) end
function P:who(a)
    local l = lower(a)
    if l == 'you' or l == 'your' or (l ~= '' and l == self:me()) then return 'me' end
    local pet = self:pet()
    if pet ~= '' and l == pet then return 'pet' end
    local me = self:me()
    if me ~= '' and (l == me .. '`s pet' or l == me .. '`s warder' or l == me .. '`s familiar') then return 'pet' end
    return 'other'
end
function P:is_you(t) local l = lower(t); return l == 'you' or l == 'yourself' or (l ~= '' and l == self:me()) end

local function take(self, kind, actor, now, name)
    for k, p in ipairs(self.pend) do
        if p.kind == kind and ((actor ~= 'other' and p.a == actor) or (kind == 'melee' and p.a == 'me' and actor == 'pet')
            or (actor == 'other' and p.a == 'other' and lower(p.name) == lower(name))) then table.remove(self.pend, k); return p end
    end
end

-- your shield fired on X: claim the pending "X was hit by non-melee" when X swings at you
local function claim_ds(self, who, out)
    local l = lower(who)
    for k, p in ipairs(self.ds) do
        if p.who == l then table.remove(self.ds, k); out[#out + 1] = { k = 'dmg', who = 'me', cat = 'ds', n = p.n, tgt = who, sp = 'Damage shield', flags = {} }; return end
    end
end

-- split "<actor> <verb> <target>" where the target is known to be YOU, or the actor is You / your pet / anyone
local function melee_parts(self, left)
    local w = {}
    for x in left:gmatch('%S+') do w[#w + 1] = x end
    if #w < 3 then return nil end
    -- incoming: "<actor words> <verb> YOU"
    if w[#w] == 'YOU' and VERB[lower(w[#w - 1])] then return table.concat(w, ' ', 1, #w - 2), lower(w[#w - 1]), 'YOU' end
    if w[#w] == 'YOU' and #w >= 4 and lower(w[#w - 1]) == 'on' and VERB[lower(w[#w - 2])] then return table.concat(w, ' ', 1, #w - 3), lower(w[#w - 2]) .. ' on', 'YOU' end
    if w[1] == 'You' and VERB[lower(w[2])] then
        if lower(w[3]) == 'on' and #w >= 4 then return 'You', lower(w[2]) .. ' on', table.concat(w, ' ', 4) end
        return 'You', lower(w[2]), table.concat(w, ' ', 3)
    end
    local pet = self:pet()
    if pet ~= '' and lower(left):sub(1, #pet + 1) == pet .. ' ' then
        local rest = left:sub(#pet + 2)
        local v, t = rest:match('^(%a+) (.+)$')
        if v and VERB[lower(v)] then
            if lower(t):sub(1, 3) == 'on ' then return left:sub(1, #pet), lower(v) .. ' on', t:sub(4) end
            return left:sub(1, #pet), lower(v), t
        end
    end
    for i = 2, #w - 1 do
        if VERB[lower(w[i])] then
            local j = i + 1
            local v = lower(w[i])
            if lower(w[j]) == 'on' and j < #w then v = v .. ' on'; j = j + 1 end
            return table.concat(w, ' ', 1, i - 1), v, table.concat(w, ' ', j)
        end
    end
end

function P:classify1(line, now)
    now = now or 0
    line = tostring(line or ''):gsub('[\r\n%s]+$', '')   -- log files saved on Windows end in CR LF
    self.i = self.i + 1
    local out = {}
    -- age out pending crit flags (1 s / 4 lines) and pending shields (1 s / 3 lines)
    for k = #self.pend, 1, -1 do local p = self.pend[k]; if now - p.t > 1000 or self.i - p.i > 4 then table.remove(self.pend, k) end end
    for k = #self.ds, 1, -1 do
        local p = self.ds[k]
        if now - p.t > 1000 or self.i - p.i > 3 then table.remove(self.ds, k); self.carry[#self.carry + 1] = { k = 'ods', n = p.n, who = p.who } end
    end
    local base, flags = split_suffix(line)
    local crit, cripple, special = false, false, nil
    for _, f in ipairs(flags) do
        if CRITW[f] then crit = true end
        if f == 'Crippling Blow' then cripple = true end
        if SPECIAL[f] then special = f end
    end
    local a, n
    -- crit announcements (RoF2 1023 / 1021 / 1040 / 428 / 1039 / 427)
    a, n = base:match('^(.-) scores? a critical hit! ?%(([%d,]+)%)$')
    if not a then a, n = base:match('^(You) score a critical hit! ?%(([%d,]+)%)$') end
    if a then self.pend[#self.pend + 1] = { kind = 'melee', a = self:who(a), t = now, i = self.i, n = num(n), name = a }; out.ann = 'melee'; return out end
    a, n = base:match('^(.-) lands? a Crippling Blow! ?%(([%d,]+)%)$')
    if not a then a, n = base:match('^(.-) scores? a Crippling Blow! ?%(([%d,]+)%)$') end
    if a then
        local wa = self:who(a)
        self.pend[#self.pend + 1] = { kind = 'melee', a = wa, t = now, i = self.i, n = num(n), cripple = true, name = a }
        if wa == 'me' then out[#out + 1] = { k = 'cripple_ann' } end    -- the callout shows now; the damage line counts it
        out.ann = 'cripple'; return out
    end
    a, n = base:match('^(.-) delivers? a critical blast! ?%(([%d,]+)%)$')
    if a then self.pend[#self.pend + 1] = { kind = 'spell', a = self:who(a), t = now, i = self.i, n = num(n), name = a }; out.ann = 'spell'; return out end
    a, n = base:match('^(.-) performs? an exceptional heal! ?%(([%d,]+)%)$')
    if a then self.pend[#self.pend + 1] = { kind = 'heal', a = self:who(a), t = now, i = self.i, n = num(n), name = a }; out.ann = 'heal'; return out end
    a = base:match('^(.-) scores? a Finishing Blow!*$')
    if a then if self:who(a) == 'me' then out[#out + 1] = { k = 'finish' } end; out.ann = 'finish'; return out end

    -- damage shields
    local t
    t, n = base:match('^(.-) was hit by non%-melee for ([%d,]+) points? of damage%.$')
    if t then self.ds[#self.ds + 1] = { who = lower(t), n = num(n), t = now, i = self.i }; out.pending = true; return out end
    local sp
    t, sp, n = base:match('^(.-) is %a+ by YOUR (.-) for ([%d,]+) points? of non%-melee damage%.$')
    if not t then t, sp, n = base:match('^(.-) was %a+ by YOUR (.-) for ([%d,]+) points? of non%-melee damage%.$') end
    if t then out[#out + 1] = { k = 'dmg', who = 'me', cat = 'ds', n = num(n), tgt = t, sp = 'Damage shield', crit = crit, flags = flags }; return out end
    a, n = base:match("^YOU are %a+ by (.-)'s .- for ([%d,]+) points? of non%-melee damage[%.!]$")
    if not a then a, n = base:match("^Your mind burns from (.-)'s feedback for ([%d,]+) points? of non%-melee damage[%.!]$") end
    if a then out[#out + 1] = { k = 'inc', cat = 'ds', n = num(n), who = a, flags = flags }; return out end
    t, n = base:match("^(.-)'s mind burns from YOUR feedback for ([%d,]+) points? of non%-melee damage[%.!]$")
    if t then out[#out + 1] = { k = 'dmg', who = 'me', cat = 'ds', n = num(n), tgt = t, sp = 'Damage shield', crit = crit, flags = flags }; return out end
    n = base:match('^YOU are chilled to the bone for ([%d,]+) points? of non%-melee damage[%.!]$')
    if n then out[#out + 1] = { k = 'inc', cat = 'env', n = num(n), who = '', flags = flags }; return out end
    local ot, oa
    ot, oa, n = base:match("^(.-) is %a+ by (.-)'s .- for ([%d,]+) points? of non%-melee damage[%.!]$")
    if ot then
        -- lc1: TOB prints a DS twice: "X was hit by non-melee for N points of damage." then "X is pierced by Mypet's thorns for N
        -- points of non-melee damage." (live log 2026-11-15). The named line wins; drop the generic copy so it is not also an 'ods'.
        for k = #self.ds, 1, -1 do local p = self.ds[k]; if p.who == lower(ot) and p.n == num(n) then table.remove(self.ds, k); break end end
        if self:who(oa) == 'pet' then out[#out + 1] = { k = 'dmg', who = 'pet', cat = 'ds', n = num(n), tgt = ot, flags = flags }
        else out[#out + 1] = { k = 'ods', n = num(n), who = oa } end
        return out
    end
    n = base:match('^You were hit by non%-melee for ([%d,]+) d?a?m?a?g?e?')
    if not n then n = base:match('^You were hit by non%-melee for ([%d,]+) points? of damage') end
    if n then out[#out + 1] = { k = 'inc', cat = 'ds', n = num(n), who = '', flags = flags }; return out end

    -- spells: 9073 (TOB) "A hit T for N points of TYPE damage by SPELL." / (RoF2) "A hit T for N points of non-melee damage."
    local typ, rest
    a, t, n, typ, rest = base:match('^(.-) hit (.-) for ([%d,]+) points? of ([%a%-]*) ?damage(.*)$')
    if a and (typ ~= '' or rest:find('^ by ')) then
        sp = rest:match('^ by (.-)%.?$')
        if sp == '' then sp = nil end
        if typ == '' then typ = nil end
        local wa = self:who(a)
        n = num(n)
        if self:is_you(t) and wa ~= 'me' then out[#out + 1] = { k = 'inc', cat = 'spell', n = n, who = a, sp = sp, flags = flags }; return out end
        if lower(t) == lower(a) then return out end                               -- "Honey hit Honey" (self damage)
        if wa == 'other' then
            local p = take(self, 'spell', 'other', now, a)
            out[#out + 1] = { k = 'odmg', who = a, n = n, crit = crit or p ~= nil, tgt = t, spell = true, typ = typ, sp = sp }; return out
        end
        local p = take(self, 'spell', wa, now)
        out[#out + 1] = { k = 'dmg', who = wa, cat = (wa == 'pet') and 'spell' or 'spell', n = n, crit = crit or p ~= nil, tgt = t, typ = typ, sp = sp, flags = flags }
        return out
    end
    -- melee: "<A> <verb> <T> for N points of damage." (client builds it from 12160)
    local left
    left, n = base:match('^(.-) for ([%d,]+) points? of damage%.$')
    if left then
        local ma, v, mt = melee_parts(self, left)
        if ma then
            n = num(n)
            if mt == 'YOU' or self:is_you(mt) then
                claim_ds(self, ma, out)
                out[#out + 1] = { k = 'inc', cat = 'melee', n = n, who = ma, verb = v, flags = flags }
                return out
            end
            local wa = self:who(ma)
            if wa == 'other' then
                local p = take(self, 'melee', 'other', now, ma)
                out[#out + 1] = { k = 'odmg', who = ma, n = n, crit = crit or p ~= nil, tgt = mt, verb = v }; return out
            end
            local p = take(self, 'melee', wa, now)
            out[#out + 1] = { k = 'dmg', who = wa, cat = 'melee', n = n, crit = crit or p ~= nil, cripple = cripple or (p and p.cripple) or false,
                cripple_shown = (p and p.cripple) or false, special = special, tgt = mt, verb = v, flags = flags }
            return out
        end
    end
    -- DoTs: 9072 / 13327 / 12954 / 12956
    t, n, sp = base:match('^(.-) has taken ([%d,]+) damage from your (.-)%.?$')
    if t then out[#out + 1] = { k = 'dmg', who = 'me', cat = 'dot', n = num(n), crit = crit, tgt = t, sp = sp, flags = flags }; return out end
    n, a, sp = base:match('^You have taken ([%d,]+) damage from (.-) by (.-)%.?$')
    if not n then n, a = base:match('^You have taken ([%d,]+) damage from (.-)%.?$') end
    if n then out[#out + 1] = { k = 'inc', cat = 'dot', n = num(n), who = a, sp = sp, flags = flags }; return out end
    n = base:match('You have taken ([%d,]+) points? of damage%.$')                 -- 12203 traps / environment
    if n then out[#out + 1] = { k = 'inc', cat = 'env', n = num(n), who = '', flags = flags }; return out end
    -- 13327: caster first, then the spell (real RoF2 log: "a ghostly student has taken 3031 damage from a ghostly scholar by Suffocate.")
    t, n, a, sp = base:match('^(.-) has taken ([%d,]+) damage from (.-) by (.-)%.?$')
    if t then
        local wa = self:who(a)
        if wa == 'pet' then out[#out + 1] = { k = 'dmg', who = 'pet', cat = 'dot', n = num(n), crit = crit, tgt = t, sp = sp, flags = flags }
        elseif wa == 'me' then out[#out + 1] = { k = 'dmg', who = 'me', cat = 'dot', n = num(n), crit = crit, tgt = t, sp = sp, flags = flags }
        else out[#out + 1] = { k = 'odmg', who = a, n = num(n), crit = crit, tgt = t, spell = true, sp = sp } end
        return out
    end
    -- swings that did not land: 12159 "%1 tries to %2 %3, but %4!"
    local v, how
    v, t, how = base:match('^You try to (%a+) (.-), but (.-)!$')
    if v then out[#out + 1] = { k = 'swing_out', how = avoid_kind(how), tgt = t, verb = v }; return out end
    a, v, how = base:match('^(.-) tries to (%a+) YOU, but (.-)!$')
    if not a then a, v, how = base:match('^(.-) tries to (%a+ on) YOU, but (.-)!$') end
    if a then claim_ds(self, a, out); out[#out + 1] = { k = 'swing_in', how = avoid_kind(how), who = a }; return out end
    a, v, t, how = base:match('^(.-) tries to (%a+) (.-), but (.-)!$')
    if a then
        if self:who(a) == 'pet' then out[#out + 1] = { k = 'swing_pet', how = avoid_kind(how), tgt = t } end
        return out
    end
    -- heals (RoF2 9068 / 419 / 4600 / 9069 / 725; TOB 8173 / 8176 / 8177 / 8178 / 12976 / 12997 / 12998 / 13046)
    local function heal(healer, tgt, n2, rest2, hot)
        rest2 = rest2 or ''
        local pot = num(rest2:match('^%s*%(([%d,]+)%)'))
        local hsp = rest2:match(' by your (.-)%.?$') or rest2:match(' by (.-)%.?$') or rest2:match(' with your (.-)%.?$')
        n2 = num(n2)
        local over = (pot and pot > n2) and (pot - n2) or 0
        local wh = healer and self:who(healer) or 'other'
        local p = take(self, 'heal', wh, now)
        local c = crit or p ~= nil
        local you = self:is_you(tgt)
        if wh == 'me' then
            out[#out + 1] = { k = 'heal_out', n = n2, tgt = you and 'You' or tgt, crit = c, over = over, sp = hsp, hot = hot, self = you }
            if you then out[#out + 1] = { k = 'heal_in', n = n2, who = 'You', crit = c, over = over, sp = hsp, hot = hot, self = true } end
        elseif you then
            out[#out + 1] = { k = 'heal_in', n = n2, who = healer or '', crit = c, over = over, sp = hsp, hot = hot }
        elseif healer and healer ~= '' then                              -- f8b: someone else healing someone else (group meter)
            out[#out + 1] = { k = 'oheal', who = healer, tgt = tgt, n = n2, crit = c, over = over, sp = hsp, hot = hot }
        end
        return out
    end
    local h, ht, hn, hr = base:match('^(.-) healed (.-) over time for ([%d,]+)(.*)$')
    if h then return heal(h, ht, hn, hr, true) end
    h, ht, hn, hr = base:match('^You have healed (.-) for ([%d,]+)(.*)$')
    if h then return heal('You', h, ht, hn, false) end
    h, hn, hr = base:match('^(.-) has healed you for ([%d,]+)(.*)$')
    if h then return heal(h, 'you', hn, hr, false) end
    h, ht, hn, hr = base:match('^(.-) healed (.-) for ([%d,]+)(.*)$')
    if h and not h:find(' been$') then return heal(h, ht, hn, hr, false) end
    ht, hn, hr = base:match('^(.-) ha[sv]e? been healed over time for ([%d,]+)(.*)$')
    if ht then return heal(nil, (lower(ht):match('you$') and 'you') or ht, hn, hr, true) end
    ht, hn, hr = base:match('^(.-) ha[sv]e? been healed f?o?r? ?([%d,]+)(.*)$')
    if ht then
        local by = hr:match(' by your ')
        return heal(by and 'You' or nil, (lower(ht):match('you$') and 'you') or ht, hn, hr, false)
    end
    ht, hn = base:match('^The gods have healed (.-) for ([%d,]+) points?')
    if ht then return heal(nil, ht, hn, '', false) end
    -- f8b: casts and deaths for the spell timeline, mob warnings and the death recap (eqstr 12205 / 8065 / 8286 / 12206 / 1038)
    sp = base:match('^You begin casting (.-)%.$') or base:match('^You begin singing (.-)%.$')
    if sp then out[#out + 1] = { k = 'cast', sp = sp }; return out end
    -- f10: TOB / RoF2 echo the spell name in brackets; names with ':' or 'Rk. II' are not stripped as a flag
    -- (real log: "You begin casting Ancient: Touch of Orshilak. (Ancient: Touch of Orshilak)")
    sp = line:match('^You begin casting .-%.%s*%((.+)%)$') or line:match('^You begin singing .-%.%s*%((.+)%)$')
    if sp then out[#out + 1] = { k = 'cast', sp = sp }; return out end
    sp = base:match('^You activate (.-)%.$')
    if sp then out[#out + 1] = { k = 'activate', sp = sp }; return out end
    a, sp = base:match('^(.-) begins casting (.-)%.$')
    if not a then a, sp = line:match('^(.-) begins to cast a spell%.%s*%((.+)%)$') end   -- RoF2 12206 + "(Spell)" (real logs)
    if not a then a = base:match('^(.-) begins to cast a spell%.$'); sp = a and '' end
    if a and not self:is_you(a) then out[#out + 1] = { k = 'ocast', who = a, sp = sp }; return out end
    a = base:match('^You have been slain by (.-)!$')
    if a then out[#out + 1] = { k = 'died', by = a }; return out end
    if base == 'You died.' then out[#out + 1] = { k = 'died', by = '' }; return out end
    -- resists: RoF2 425 / 426, TOB 425 / 426 / 12438 / 9013 / 10005
    sp = base:match('^Your target resisted the (.-) spell%.$')
    if sp then out[#out + 1] = { k = 'resist_out', sp = sp }; return out end
    t, sp = base:match('^(.-) resisted your (.-)!$')
    if t then out[#out + 1] = { k = 'resist_out', sp = sp, tgt = t }; return out end
    sp = base:match('^You resist the (.-) spell!+$') or base:match("^You resist .-'s (.-)!$") or base:match('^You resist (.-)!$')
    if sp then out[#out + 1] = { k = 'resist_in', sp = sp }; return out end
    n = base:match('^The Spellshield absorbed ([%d,]+) of [%d,]+ points? of damage')
    if n then out[#out + 1] = { k = 'absorb', n = num(n) }; return out end
    return P.f10(self, line, base)
end
-- lc1: a pet / other's damage spell prints twice on this server (live log 2026-11-15, Mychar + Mypet, TOB client):
--   "Mypet strikes an undead training dummy for 21550 points of damage."
--   "Mypet hit an undead training dummy for 21550 points of magic damage by Specter Lifetap."
-- one cast ("beams a smile"), one "staggers", one hit. A non-you "strikes" line is held for one line: dropped when the next
-- line is the same actor's typed spell hit on the same target for the same amount, otherwise released in front of that line
-- (or by P:flush from the 4 Hz watcher), so real "strikes" melee is still counted, just one line later.
P.HOLD_MS = 1000
-- lc2: your own nukes print twice too (live log 2026-11-15 11:39:53, TOB client):
--   "Mychar hit an undead training dummy for 4300 points of  damage by ."            (no type, no spell)
--   "You hit an undead training dummy for 4300 points of magic damage by Ancient: Touch of Orshilak."
-- the bare one is held the same way and dropped when the named "You hit" twin follows.
local function holdable(e)
    if e and e.k == 'dmg' and e.who == 'me' and e.cat == 'spell' and not e.sp and not e.typ then return true end
    return e and e.verb == 'strikes' and ((e.k == 'dmg' and e.who == 'pet' and e.cat == 'melee') or e.k == 'odmg')
end
local function same_hit(h, e, now)
    if not (e and (e.k == 'dmg' or e.k == 'odmg') and e.k == h.ev.k and e.sp and e.n == h.ev.n) then return false end
    if e.k == 'dmg' then if not (e.who == h.ev.who and e.cat == 'spell' and e ~= h.ev) then return false end
    elseif not (e.spell and lower(e.who) == lower(h.ev.who)) then return false end
    return lower(e.tgt or '') == lower(h.ev.tgt or '') and now - h.t <= P.HOLD_MS
end
function P:classify(line, now)
    now = now or 0
    local h = self.hold; self.hold = nil
    local out = self:classify1(line, now)
    if h then
        local dup = false
        for _, e in ipairs(out or {}) do if same_hit(h, e, now) then dup = true; e.dup_strike = true; break end end
        if dup then self.dup_strikes = (self.dup_strikes or 0) + 1; h = nil end
    end
    if out then                                                   -- hold this line's strikes (never the one being released)
        for k = #out, 1, -1 do
            if holdable(out[k]) then self.hold = { ev = table.remove(out, k), t = now }; out.pending = true; break end
        end
    end
    if h then out = out or {}; table.insert(out, 1, h.ev) end
    -- aged-out generic DS copies ride on the next classified line (an unclassified line returns nil and must stay unclaimed
    -- so "You have slain X!" etc. still reach their handlers), or on flush
    if out and #self.carry > 0 then for k = #self.carry, 1, -1 do table.insert(out, 1, self.carry[k]) end; self.carry = {} end
    return out
end
-- release a held "strikes" hit once no matching spell line followed (called by the events watcher)
function P:flush(now)
    local out
    local h = self.hold
    if h and (now or 0) - h.t >= 250 then self.hold = nil; out = { h.ev } end
    if #self.carry > 0 then out = out or {}; for k = #self.carry, 1, -1 do table.insert(out, 1, self.carry[k]) end; self.carry = {} end
    return out
end
-- ---------------------------------------------------------------- f10: tracking lines (none of these were classified before)
-- mob actions: eqstr 1031 "%1 Gates.", 1042 "%1 has become ENRAGED.", 1043 "%1 is no longer enraged.", 1027 "%1 goes into a
-- berserker frenzy!"; real logs: "X goes on a RAMPAGE!", "X goes on a WILD RAMPAGE!", "X executes a FLURRY of attacks on Y!"
-- feign death: 1456 "%1 has fallen to the ground." (EQ's feign-failed line), 176/254/276/363-366 "You are no longer feigning
-- death, because ...", 9174 resume. Coin: 12072 "You receive %1 from the corpse%2.", 12071 "... as your split%2.", 1442 "You
-- receive %1 platinum %2." (real: "You receive 120 gold ."). XP (real): "You have gained (3751448) experience! (7.076%)",
-- "... raid experience! ...", 138/139 "You gain (party) experience!". AA (real): "You have gained 1 ability point(s)!  You now have 9 ability point(s)."
local COIN = { platinum = 1000, gold = 100, silver = 10, copper = 1 }
function P.coins(s)
    local cp, any = 0, false
    for n, u in tostring(s or ''):gmatch('([%d,]+) (%a+)') do
        local m = COIN[u:lower()]; if m then cp = cp + (num(n) or 0) * m; any = true end
    end
    return any and cp or nil
end
function P.f10(self, line, base)
    local out = {}
    local a, t, how
    a = base:match('^(.-) Gates%.$')
    if a and a ~= '' and not self:is_you(a) then out[1] = { k = 'mobact', who = a, act = 'gate' }; return out end
    a = base:match('^(.-) has become ENRAGED%.$')
    if a then out[1] = { k = 'mobact', who = a, act = 'enrage' }; return out end
    a = base:match('^(.-) is no longer enraged%.$')
    if a then out[1] = { k = 'mobact', who = a, act = 'enrage_end' }; return out end
    a = base:match('^(.-) goes on a WILD RAMPAGE!$')
    if a then out[1] = { k = 'mobact', who = a, act = 'wild rampage' }; return out end
    a = base:match('^(.-) goes on a RAMPAGE!$')
    if a then out[1] = { k = 'mobact', who = a, act = 'rampage' }; return out end
    a, t = base:match('^(.-) executes a FLURRY of attacks on (.-)!$')
    if a then out[1] = { k = 'mobact', who = a, act = 'flurry', tgt = t }; return out end
    a = base:match('^(.-) goes into a berserker frenzy!$')
    if a then if not self:is_you(a) then out[1] = { k = 'mobact', who = a, act = 'frenzy' } end; return out end
    a = base:match('^(.-) has fallen to the ground%.$')
    if a and self:is_you(a) then out[1] = { k = 'fd_fail' }; return out end
    how = base:match('^You are no longer feigning death, because (.-)%.$')
    if how then out[1] = { k = 'fd_break', why = how }; return out end
    if base == 'The strength of your will allows you to resume feigning death.' then out[1] = { k = 'fd_resume' }; return out end
    if base == 'Your spell did not take hold.' then out[1] = { k = 'nohold' }; return out end
    local m = base:match('^You receive (.-) from the corpse.-%.$')
    if m then local cp = P.coins(m); if cp then out[1] = { k = 'coin', cp = cp, src = 'corpse' }; return out end end
    m = base:match('^You receive (.-) as your split.-%.$')
    if m then local cp = P.coins(m); if cp then out[1] = { k = 'coin', cp = cp, src = 'split' }; return out end end
    local n, u = base:match('^You receive ([%d,]+) (%a+) %.$')
    if n and COIN[u:lower()] then out[1] = { k = 'coin', cp = (num(n) or 0) * COIN[u:lower()], src = 'reward' }; return out end
    local xn, kind, pct = line:match('^You have gained %(([%d,]+)%) (.-)experience! %(([%d%.]+)%%%)%s*$')
    if xn then out[1] = { k = 'xp', n = num(xn), pct = tonumber(pct), kind = (kind:gsub('%s+$', '')) }; return out end
    kind = base:match('^You gaine?d? (%a*) ?experience!*$')
    if kind then out[1] = { k = 'xp', kind = kind }; return out end
    n = base:match('^You have gained ([%d,]+) ability point%(s%)!')
    if n then out[1] = { k = 'aapt', n = num(n) }; return out end
    return nil
end
return P
