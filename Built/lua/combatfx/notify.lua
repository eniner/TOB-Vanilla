-- combatfx/notify.lua (ps1): the one list behind Parses > Settings: every on-screen card / popup / alert and every
-- sound the parser, tracking and alerts produce. Each switch reads and writes the item's EXISTING key (the same key
-- its own tab toggles), so the tabs never disagree. New keys only where nothing existed: C.cfg.notify.cards /
-- .sounds (the two masters, inverted: false = all off), .snd_named / .snd_loot (the kill / loot moments shared one
-- sound pick) and the *_last picks that an off switch remembers. The gates live at the emit points (fx.lua for the
-- cards master, features F.play for the sound master, events / track for the per-item sounds).
local C = require('combatfx.core')
local M = { REV = 'ps1' }

local function fx(k) return C.cfg.fx end
local function tr() return C.cfg.track or {} end
local function ps() return C.cfg.parses or {} end
local function nt() C.cfg.notify = C.cfg.notify or {}; return C.cfg.notify end
local function al() C.cfg.alerts = C.cfg.alerts or {}; return C.cfg.alerts end
local function FXm() return package.loaded['combatfx.fx'] end

-- a card bound to one boolean key
local function key(tbl, k) return { get = function() return tbl()[k] == true end, set = function(on) tbl()[k] = on end, def = true } end
-- a card shown only when the feature switch AND its alert switch are on (the Tracking / Warnings tabs flip both);
-- off here clears both too unless keep_feat (the feature also feeds something else: spawn scanning feeds its sound)
local function pair(ftbl, fk, ak, keep_feat)
    return { get = function() return ftbl()[fk] == true and al()[ak] == true end,
        set = function(on) if on or not keep_feat then ftbl()[fk] = on end; al()[ak] = on end, def = true }
end

local function moment_sound(id)
    return {
        get = function() return C.cfg.moments.sound ~= 'off' and nt()['snd_' .. id] ~= false end,
        set = function(on)
            local n = nt()
            n['snd_' .. id] = on
            if on and C.cfg.moments.sound == 'off' then C.cfg.moments.sound = n.moment_last or 'chimes' end
            if C.cfg.moments.sound ~= 'off' then n.moment_last = C.cfg.moments.sound end
        end,
        name = function() local s = C.cfg.moments.sound; if s == 'off' then s = nt().moment_last or 'chimes' end; return s end,
        def = false,                                                  -- moments.sound ships 'off'
        shared = 'Shares the sound picked on Alerts > Kill & loot moments',
    }
end

M.SECTIONS = {
    { 'fight', 'FIGHT CARDS', 'the parser: recap, meters, death, banners' },
    { 'alert', 'ALERTS &amp; MOMENTS', 'callouts beside your character, kill / loot flourish' },
    { 'track', 'WARNINGS &amp; TRACKING', 'mob abilities, casts, named spawns, DoTs, feign, the tracking panel' },
}

-- id, section, label, where it shows / what triggers it, code emit point, card binding, preview (SIM key or TK kind), sound
M.ITEMS = {
    { id = 'recap', sec = 'fight', label = 'Fight recap card', desc = 'After COMBAT ENDED: top abilities, crits, graph (left / right column)',
      emit = 'fx.lua FX.recap <- addons.lua fight end', card = key(fx, 'recap'), sim = 'recap', also = 'Combat+ > Encounter recap' },
    { id = 'livemeter', sec = 'fight', label = 'In-combat DPS meter', desc = 'Live DPS, 10 s rate and sparkline while you fight (left column)',
      emit = 'fx.lua FX.meter_live <- events.lua frame', card = key(fx, 'livemeter'), also = 'Combat+ > Live meter',
      off = function() local F = FXm(); if F then F.meter_live(nil) end end },
    { id = 'group', sec = 'fight', label = 'Group / raid meter', desc = 'Ranked live panel in group fights and its section in the recap',
      emit = 'fx.lua FX.group_meter <- parses.lua gm_tick', card = key(ps, 'group'), sim = 'groupmeter', also = 'Parses > Group',
      off = function() local F = FXm(); if F then F.group_meter(nil) end end },
    { id = 'deathrecap', sec = 'fight', label = 'Death recap card', desc = 'On "You have been slain": the last 10 s of hits, heals and HP (15 s)',
      emit = 'fx.lua FX.death_recap <- parses.lua on_died', card = key(ps, 'death'), sim = 'deathrecap', also = 'Parses > Death' },
    { id = 'deathscreen', sec = 'fight', label = 'Death screen', desc = 'Red "slain by" screen when you die',
      emit = 'fx.lua FX.death <- addons.lua died', card = key(fx, 'death'), also = 'Combat FX > Death screen' },
    { id = 'combatbanner', sec = 'fight', label = 'ENGAGED / COMBAT ENDED banner', desc = 'Banner at the top when a fight starts and ends',
      emit = 'fx.lua FX.banner(combat) <- events.lua', card = key(fx, 'combatbanner'), sim = 'combat', also = 'Combat FX' },
    { id = 'killbanner', sec = 'fight', label = 'SLAIN banner', desc = 'Banner when your target dies',
      emit = 'fx.lua FX.banner(kill) <- events.lua kill', card = key(fx, 'killbanner'), sim = 'kill', also = 'Combat FX' },
    { id = 'streak', sec = 'fight', label = 'Combo counter', desc = '"10 HIT COMBO" every 5 hits in a row',
      emit = 'fx.lua FX.streak <- events.lua', card = key(fx, 'streak'), sim = 'streak', also = 'Combat FX' },
    { id = 'bighit', sec = 'fight', label = 'Personal best / MASSIVE stamp', desc = 'NEW RECORD on your best single hit, MASSIVE on huge hits',
      emit = 'fx.lua FX.stamp <- addons.lua big_hit', card = key(fx, 'bighit'), sim = 'bighit', also = 'Combat FX' },
    { id = 'stamps', sec = 'fight', label = 'Named / level / AA stamps', desc = 'NAMED on engage, GREY CON, LEVEL and AA POINT text',
      emit = 'fx.lua FX.toast(stamps) <- addons.lua', card = key(fx, 'stamps'), also = 'Combat FX' },

    { id = 'proc', sec = 'alert', label = 'Key proc alert', desc = 'Crippling / Finishing Blow and procs on your list',
      emit = 'fx.lua FX.alert(proc) <- events.lua', card = key(al, 'proc'), sim = 'alertproc', also = 'Alerts' },
    { id = 'buff', sec = 'alert', label = 'Buff about to drop', desc = 'A watched buff under the warning time',
      emit = 'fx.lua FX.alert(buff) <- addons.lua buff_tick', card = key(al, 'buff'), sim = 'alertbuff', also = 'Alerts' },
    { id = 'buffwarn', sec = 'alert', label = 'Buff faded text', desc = '"<buff> faded" line (also the fallback when there is no room for the alert)',
      emit = 'fx.lua FX.toast(buffwarn) <- addons.lua', card = key(fx, 'buffwarn'), sim = 'buffwarn', also = 'Combat FX' },
    { id = 'heal', sec = 'alert', label = 'Big heal alert', desc = 'A heal on you bigger than a share of your max HP',
      emit = 'fx.lua FX.alert(heal) <- events.lua', card = key(al, 'heal'), sim = 'alertheal', also = 'Alerts' },
    { id = 'ready', sec = 'alert', label = 'Spell ready ping', desc = '"<spell> READY" after a long recast',
      emit = 'fx.lua FX.toast(ready) <- addons.lua', card = key(fx, 'ready'), sim = 'ready', also = 'Combat FX' },
    { id = 'ccbreak', sec = 'alert', label = 'Mez / root break + aggro', desc = 'MEZ BROKE, ROOT FADED, AGGRO text with an edge flash',
      emit = 'fx.lua FX.toast/edge(ccbreak) <- addons.lua', card = key(fx, 'ccbreak'), sim = 'mezbreak', also = 'Combat FX' },
    { id = 'groupdanger', sec = 'alert', label = 'Group danger', desc = 'A group member low on HP or dead, with an edge flash',
      emit = 'fx.lua FX.toast/edge(group) <- addons.lua', card = key(fx, 'group'), sim = 'group', also = 'Combat FX' },
    { id = 'named', sec = 'alert', label = 'Named kill moment', desc = 'Gold NAMED SLAIN flourish above you',
      emit = 'fx.lua FX.moment <- events.lua kill', card = key(function() return C.cfg.moments end, 'named'), sim = 'namedkill', also = 'Alerts > Moments',
      sound = moment_sound('named'), snd_emit = 'features F.play <- events.lua kill (F.moment_snd named)' },
    { id = 'loot', sec = 'alert', label = 'Rare / lore drop moment', desc = 'LORE / WATCHED / VALUABLE DROP flourish when you loot',
      emit = 'fx.lua FX.moment <- events.lua loot queue', card = key(function() return C.cfg.moments end, 'loot'), sim = 'lootrare', also = 'Alerts > Moments',
      sound = moment_sound('loot'), snd_emit = 'features F.play <- events.lua loot queue (F.moment_snd loot)' },

    { id = 'mob', sec = 'track', label = 'Mob ability warning', desc = 'Learned big hits / AEs when a known mob is engaged or casts',
      emit = 'fx.lua FX.alert(mob) <- parses.lua on_engage / on_ocast', card = pair(ps, 'mobwarn', 'mob'), sim = 'mobwarn', also = 'Parses > Warnings' },
    { id = 'cast', sec = 'track', label = 'Cast warning above the mob', desc = 'Gate, AE, Complete Heal ... over the caster (or beside you)',
      emit = 'fx.lua FX.wlabel / FX.alert(cast) <- track.lua on_warn', card = pair(tr, 'castwarn', 'cast'), tk = 'cast', also = 'Tracking > Casts' },
    { id = 'spawn', sec = 'track', label = 'Named spawn alert', desc = 'Label + glow at a named / listed mob that pops',
      emit = 'fx.lua FX.wlabel / FX.alert(spawn) <- track.lua on_spawns', card = pair(tr, 'spawn', 'spawn', true), tk = 'spawn', also = 'Tracking > Spawns',
      sound = {
          get = function() return tr().spawn == true and tr().spawn_sound ~= nil and tr().spawn_sound ~= 'off' end,
          set = function(on)
              local c, n = tr(), nt()
              if on then
                  if not c.spawn then c.spawn = true; al().spawn = false end   -- scanning on for the sound, the card stays as it was (off)
                  if c.spawn_sound == 'off' then c.spawn_sound = n.spawn_last or 'ding' end
              else
                  if c.spawn_sound ~= 'off' then n.spawn_last = c.spawn_sound end
                  c.spawn_sound = 'off'
              end
          end,
          name = function() local s = tr().spawn_sound; if not s or s == 'off' then s = nt().spawn_last or 'ding' end; return s end,
          def = true, shared = 'Pick the sound on Tracking > Spawns',
      }, snd_emit = 'features F.play <- track.lua on_spawns' },
    { id = 'dot', sec = 'track', label = 'DoT fading warning', desc = 'Your DoT on the target about to drop',
      emit = 'fx.lua FX.alert(dot) <- track.lua dot_warn', card = key(al, 'dot'), tk = 'dot', also = 'Tracking > Buffs & DoTs' },
    { id = 'fd', sec = 'track', label = 'Feign death flash', desc = 'FEIGN DEATH / FEIGN FAILED / FEIGN BROKEN',
      emit = 'fx.lua FX.alert(fd) <- track.lua fd_flash', card = pair(tr, 'fd', 'fd'), tk = 'fd_ok', also = 'Tracking > Feign' },
    { id = 'panel', sec = 'track', label = 'Tracking panel', desc = 'Buffs fading, DoTs on the target, pet split (right column)',
      emit = 'fx.lua FX.track_panel <- track.lua panel_tick', tk = 'panel', also = 'Tracking > Panel (In combat / Always / Off)',
      card = {
          get = function() return tr().panel ~= nil and tr().panel ~= 'off' end,
          set = function(on) local c, n = tr(), nt(); if on then if c.panel == 'off' then c.panel = n.panel_last or 'combat' end else if c.panel ~= 'off' then n.panel_last = c.panel end; c.panel = 'off' end end,
          def = true,
      },
      off = function() local F = FXm(); if F then F.track_panel(nil) end end },
}
M.BY = {}
for _, it in ipairs(M.ITEMS) do M.BY[it.id] = it end

function M.cards_master() return nt().cards ~= false end
function M.sounds_master() return nt().sounds ~= false end
local function hide_panels() local F = FXm(); if F then pcall(F.meter_live, nil); pcall(F.group_meter, nil); pcall(F.track_panel, nil) end end
function M.set_cards_master(on) nt().cards = on; if not on then hide_panels() end end
function M.set_sounds_master(on) nt().sounds = on end

function M.card(id) local it = M.BY[id]; return it and it.card.get() or false end
function M.set_card(id, on)
    local it = M.BY[id]; if not it then return false end
    it.card.set(on); if not on and it.off then pcall(it.off) end
    return true
end
function M.sound(id) local it = M.BY[id]; return it and it.sound and it.sound.get() or false end
function M.set_sound(id, on) local it = M.BY[id]; if not (it and it.sound) then return false end; it.sound.set(on); return true end
-- Preview: the only path that plays a sound from this tab (a switch never plays one); plays even with All sounds off
function M.preview_sound(id)
    local it = M.BY[id]; if not (it and it.sound) then return false, 'no sound' end
    local F = require('combatfx.features')
    local nm = it.sound.name()
    local ok = F.play(nm, true)
    return ok, ok and nm or (F.sound_why or 'sound not found')
end
function M.restore_defaults()
    local n = nt()
    n.cards, n.sounds = true, true
    for _, it in ipairs(M.ITEMS) do
        it.card.set(it.card.def)
        if it.sound then it.sound.set(it.sound.def) end
    end
    n.snd_named, n.snd_loot = true, true                           -- moments.sound back to 'off' below keeps them silent
    C.cfg.moments.sound = 'off'
    tr().spawn_sound = 'ding'; tr().spawn = true; al().spawn = true
    tr().panel = 'combat'
end
-- counts for the header: cards on, sounds on, total of each
function M.counts()
    local c, cn, s, sn = 0, 0, 0, 0
    for _, it in ipairs(M.ITEMS) do
        cn = cn + 1; if it.card.get() then c = c + 1 end
        if it.sound then sn = sn + 1; if it.sound.get() then s = s + 1 end end
    end
    return c, cn, s, sn
end
return M
