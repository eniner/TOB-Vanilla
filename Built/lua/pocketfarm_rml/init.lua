--[[
╔══════════════════════════════════════════════════════════════╗
║              PocketFarm.lua  v3.5                           ║
║  Farming engine (from PocketFarm.mac by Kaen01)             ║
║  + Integrated SpawnWatch spawn detection & watchlist        ║
║  RmlUi edition (pocketfarm_rml): Harvest Grove window       ║
╚══════════════════════════════════════════════════════════════╝

  Farming Commands:
    /pkf go              – Start actively farming
    /pkf pause           – Pause farming (still self-defends)
    /pkf radius ##       – Set XY search radius
    /pkf zradius ##      – Set Z-axis radius
    /pkf ignore "name"   – Add to temp ignore list
    /pkf pull "name"     – Add to temp pull-only list
    /pkf clear ignore|pull – Clear a list
    /pkf list            – Show both alert lists in chat
    /pkf load            – Reload zone INI settings
    /pkf ui              – Toggle main window
    /pkf debug           – Toggle debug output

  SpawnWatch Commands:
    /pkf watch add "query"   – Add spawn query to watchlist
    /pkf watch del "query"   – Remove a query
    /pkf watch list          – List current zone watchlist
    /pkf watch scan          – Force-rescan now
    /pkf watch clear         – Clear zone watchlist

  Start options:
    /lua run pocketfarm_rml
    /lua run pocketfarm_rml go
    /lua run pocketfarm_rml camp
    /lua run pocketfarm_rml camp 500

  The window does everything; /pkf commands are optional aliases.
  Engine logic is the original v3.5 code. UI changes: ImGui console -> RmlUi (ui_rml.lua);
  spawn scans and the quest-NPC scan are spread across frames so loading and scanning hold FPS.
]]

local mq    = require('mq')
local UI    = require('pocketfarm_rml.ui_rml')

local Icons = {}
pcall(function() Icons = require('mq/Icons') end)

local ICON_TARGET = Icons.FA_CROSSHAIRS    or '[T]'
local ICON_NAV    = Icons.FA_LOCATION_ARROW or '[N]'
local ICON_EYE    = Icons.FA_EYE           or '[V]'
local ICON_TRASH  = Icons.FA_TRASH         or '[X]'
local ICON_PLUS   = Icons.FA_PLUS          or '[+]'
local ICON_SYNC   = Icons.FA_REFRESH       or '[R]'
local ICON_BELL   = Icons.FA_BELL          or '[!]'

---------------------------------------------------------------
-- CONSTANTS
---------------------------------------------------------------
local VERSION      = '3.5'
local ALERT_IGNORE = 1
local ALERT_PULL   = 10
local INI_FILE     = 'PocketFarm.ini'
local SW_FILE      = 'PocketFarm_watchlist.json'
local SW_INTERVAL  = 5000   -- ms between auto-scans
local LOG_MAX      = 300
local SCAN_SLICE   = 15     -- spawns read per frame during a scan

local BLOCKED_TYPES = {
    AURA=true, BANNER=true, CAMPFIRE=true, CORPSE=true,
    CHEST=true, ITEM=true, TRIGGER=true, TRAP=true,
    TIMER=true, MOUNT=true, MERCENARY=true, OBJECT=true,
}

---------------------------------------------------------------
-- FARMING STATE
---------------------------------------------------------------
local state = {
    running       = false,
    goFarming     = false,
    resting       = false,
    attach        = false,
    announce      = false,
    noKillCounter = 0,
    myTargetID    = 0,
    lastHeading   = '',
    cantHit       = false,
    cantHitTimer  = 0,

    radius        = 250,
    zRadius       = 125,
    campOn        = false,
    campX         = 0,
    campY         = 0,
    campZ         = 0,
    ignore        = 'NONE',
    pull          = 'ALL',
    debugOn       = false,

    showUI        = true,
}

---------------------------------------------------------------
-- SPAWN WATCH STATE
---------------------------------------------------------------
local sw = {
    watchlist    = {},  -- zone -> { query, ... }
    tracked      = {},  -- zone -> { {id,name,location,distance,pctHPs,level,isUp,lastSeen}, ... }
    timers       = {},  -- name -> { downAt, upAt, notes }
    alertsOn     = true,
    autoScan     = true,
    showAllZones = false,
    sortCol      = 'dist',
    sortDir      = 1,
    inputQuery   = '',
    actionStatus = '',
    scanDirty    = true,
    lastScanMs   = 0,
    scanAllZone  = true, -- when true, scan all targetable NPCs in zone
}

---------------------------------------------------------------
-- LOG SYSTEM
---------------------------------------------------------------
local consoleLines    = {}
local logRev          = 0

local function addLine(text, kind)
    if #consoleLines >= LOG_MAX then table.remove(consoleLines, 1) end
    table.insert(consoleLines, { text=text, kind=kind })
    logRev = logRev + 1
    mq.cmdf('/echo [PKF] %s', text)
end

local function pfMsg(m)  addLine('[PKF] '..m, 'msg') end
local function pfErr(m)  addLine('[ERR] '..m, 'err') end
local function pfGood(m) addLine('[PKF] '..m, 'good') end
local function pfWarn(m) addLine('[PKF] '..m, 'warn') end
local function pfSW(m)   addLine('[SW]  '..m, 'sw') end
local function pfDbg(m)
    if state.debugOn then addLine('[DBG] '..m, 'dbg') end
end
local dbgThrottle = {}
local function pfDbgEvery(key, ms, msg)
    if not state.debugOn then return end
    local now = mq.gettime and mq.gettime() or math.floor(os.clock() * 1000)
    local nextAt = dbgThrottle[key] or 0
    if now >= nextAt then
        dbgThrottle[key] = now + ms
        pfDbg(msg)
    end
end

---------------------------------------------------------------
-- JSON HELPERS
---------------------------------------------------------------
local function escJson(s)
    s = tostring(s or '')
    s = s:gsub('\\','\\\\')
    s = s:gsub('"','\\"')
    return s
end

local function watchlistToJson(tbl)
    local zones = {}
    for z in pairs(tbl) do zones[#zones+1] = z end
    table.sort(zones)
    local lines = {'{'}
    for zi, zone in ipairs(zones) do
        local qs, enc = tbl[zone] or {}, {}
        for _, q in ipairs(qs) do enc[#enc+1] = '"'..escJson(q)..'"' end
        lines[#lines+1] = string.format('    "%s": [%s]%s',
            escJson(zone), table.concat(enc,', '),
            zi < #zones and ',' or '')
    end
    lines[#lines+1] = '}'
    return table.concat(lines, '\n')
end

local function jsonToWatchlist(json)
    local tbl = {}
    for zone, inner in json:gmatch('"([^"]+)":%s*%[(.-)%]') do
        local qs = {}
        for q in inner:gmatch('"([^"]+)"') do qs[#qs+1] = q end
        tbl[zone] = qs
    end
    return tbl
end

---------------------------------------------------------------
-- PERSISTENT STORAGE
---------------------------------------------------------------
local function swFilePath()
    return (mq.luaDir or '.')..'/'..SW_FILE
end

local function saveWatchlist()
    local f = io.open(swFilePath(), 'w')
    if f then f:write(watchlistToJson(sw.watchlist)); f:close()
    else pfErr('Cannot write '..swFilePath()) end
end

local function loadWatchlist()
    local f = io.open(swFilePath(), 'r')
    if f then
        local content = f:read('*a'); f:close()
        sw.watchlist = jsonToWatchlist(content) or {}
        local n = 0
        for _ in pairs(sw.watchlist) do n=n+1 end
        pfSW(string.format('Watchlist loaded (%d zones).', n))
    else
        sw.watchlist = {}
        pfSW('No watchlist file — starting fresh.')
    end
end

---------------------------------------------------------------
-- HELPERS
---------------------------------------------------------------
local function getZone()
    return mq.TLO.Zone.ShortName() or 'Unknown'
end

local function navLoaded()
    local p = mq.TLO.Plugin('mq2nav')
    return p and p.IsLoaded() == true
end

local function spawnById(id)
    if not id or id <= 0 then return nil end
    local sp = mq.TLO.Spawn(('id %d'):format(id))
    return (sp and sp.ID() and sp.ID() > 0) and sp or nil
end

local function trim(s)
    return tostring(s or ''):match('^%s*(.-)%s*$')
end

local function listContainsToken(listStr, token)
    token = trim(token):lower()
    if token == '' then return false end
    for entry in tostring(listStr or ''):gmatch('[^|]+') do
        if trim(entry):lower() == token then
            return true
        end
    end
    return false
end

local function fmtDuration(secs)
    if not secs or secs < 0 then return '?' end
    secs = math.floor(secs)
    local h = math.floor(secs/3600)
    local m = math.floor((secs%3600)/60)
    local s = secs%60
    if h > 0 then return string.format('%dh %dm', h, m) end
    return string.format('%d:%02d', m, s)
end

---------------------------------------------------------------
-- INI HELPERS
---------------------------------------------------------------
local function iniRead(key, default)
    local val = mq.TLO.Ini(INI_FILE, getZone(), key)()
    if val == nil or val == 'NULL' or val == '' then return default end
    return val
end

local function iniWrite(key, value)
    mq.cmdf('/ini "%s" "%s" "%s" "%s"', INI_FILE, getZone(), key, tostring(value))
end

---------------------------------------------------------------
-- ALERT MANAGEMENT
---------------------------------------------------------------
local function alertAdd(slot, name)
    mq.cmdf('/squelch /alert add %d "%s"', slot, name)
end
local function alertClear(slot) mq.cmdf('/squelch /alert clear %d', slot) end
local function alertList(slot)  mq.cmdf('/alert list %d', slot) end

local function addIgnoreEntry(name)
    name = trim(name)
    if name == '' then return false end

    local cur = tostring(state.ignore or 'NONE')
    if cur == '' or cur == 'NULL' or cur:lower() == 'none' then
        state.ignore = name
    elseif not listContainsToken(cur, name) then
        state.ignore = cur .. '|' .. name
    end

    iniWrite('Ignore', state.ignore)
    alertAdd(ALERT_IGNORE, name)
    return true
end

local function clearIgnoreEntries()
    state.ignore = 'NONE'
    iniWrite('Ignore', state.ignore)
    alertClear(ALERT_IGNORE)
end

local function addPullEntry(name)
    name = trim(name)
    if name == '' then return false end

    local cur = tostring(state.pull or 'ALL')
    if cur == '' or cur == 'NULL' or cur:lower() == 'all' then
        state.pull = name
    elseif not listContainsToken(cur, name) then
        state.pull = cur .. '|' .. name
    end

    iniWrite('Pull', state.pull)
    alertAdd(ALERT_PULL, name)
    return true
end

local function clearPullEntries()
    state.pull = 'ALL'
    iniWrite('Pull', state.pull)
    alertClear(ALERT_PULL)
end

---------------------------------------------------------------
-- LOAD INI SETTINGS
---------------------------------------------------------------
local function loadIni(overrideRadius)
    if overrideRadius and overrideRadius > 0 then iniWrite('Radius', overrideRadius) end

    local r  = tonumber(iniRead('Radius',  '')) or 0
    local zr = tonumber(iniRead('ZRadius', '')) or 0
    local ig = iniRead('Ignore', '')
    local pl = iniRead('Pull',   '')

    if r  == 0 then iniWrite('Radius',  250); r  = 250 end
    if zr == 0 then iniWrite('ZRadius', 125); zr = 125 end
    if ig == '' or ig == 'NULL' then iniWrite('Ignore','NONE'); ig = 'NONE' end
    if pl == '' or pl == 'NULL' then iniWrite('Pull','ALL');    pl = 'ALL'  end

    state.radius  = r
    state.zRadius = zr
    state.ignore  = ig
    state.pull    = pl

    alertClear(ALERT_IGNORE)
    if ig ~= 'NONE' and ig ~= 'none' then
        for entry in ig:gmatch('[^|]+') do
            entry = entry:match('^%s*(.-)%s*$')
            if entry ~= '' then alertAdd(ALERT_IGNORE, entry) end
        end
    end

    alertClear(ALERT_PULL)
    if pl ~= 'ALL' and pl ~= 'all' then
        for entry in pl:gmatch('[^|]+') do
            entry = entry:match('^%s*(.-)%s*$')
            if entry ~= '' then alertAdd(ALERT_PULL, entry) end
        end
    end

    pfGood(string.format('Zone: %s | R:%d ZR:%d | Ignore:%s | Pull:%s',
        getZone(), r, zr, ig, pl))
end

---------------------------------------------------------------
-- AUTO-IGNORE: DETECT QUEST NPCS (have surnames)
---------------------------------------------------------------
local function autoIgnoreNPCs()
    pfMsg('Scanning for quest NPCs (with surnames)...')
    local total = mq.TLO.SpawnCount('npc targetable')() or 0
    local added = 0
    local batch = {}
    for i = 1, math.min(total, 200) do
        if i % 25 == 0 then mq.delay(1) end   -- spread over frames (load FPS)
        local sp = mq.TLO.NearestSpawn(i, 'npc targetable')
        if sp and sp.ID() and sp.ID() > 0 and
           sp.Surname() and sp.Surname() ~= '' then
            local nm  = sp.CleanName() or sp.Name() or '?'
            local sur = sp.Surname() or ''
            batch[#batch+1] = string.format('%s <%s>', nm, sur)
            if #batch >= 3 or i == total then
                pfMsg('  AutoIgnore: '..table.concat(batch,' | '))
                batch = {}
            end
            added = added + 1
        end
    end
    pfMsg(string.format('Auto-ignore scan done. %d NPC(s) tagged.', added))
end

-- Sort (strict comparator to avoid "invalid order function for sorting")
local function sortTracked(results)
    table.sort(results, function(a, b)
        local dir = (sw.sortDir == 1) and 1 or -1
        local col = sw.sortCol

        if col == 'name' then
            local an = tostring(a.name or '')
            local bn = tostring(b.name or '')
            if an ~= bn then
                if dir == 1 then return an < bn else return an > bn end
            end
        elseif col == 'dist' then
            local ad = tonumber(a.distance or 0) or 0
            local bd = tonumber(b.distance or 0) or 0
            if ad ~= bd then
                if dir == 1 then return ad < bd else return ad > bd end
            end
        else
            local ah = tonumber(a.pctHPs or 0) or 0
            local bh = tonumber(b.pctHPs or 0) or 0
            if ah ~= bh then
                -- HP column defaults to high->low when dir == 1
                if dir == 1 then return ah > bh else return ah < bh end
            end
        end

        local aid = tonumber(a.id or 0) or 0
        local bid = tonumber(b.id or 0) or 0
        return aid < bid
    end)

end

---------------------------------------------------------------
-- SPAWN WATCH: UPDATE TRACKED SPAWNS
---------------------------------------------------------------
local function swUpdateTracked()
    local zone    = getZone()
    local queries = sw.watchlist[zone]
    local scanAll = sw.scanAllZone == true

    if (not scanAll) and (not queries or #queries == 0) then
        scanAll = true
        sw.scanAllZone = true
        sw.actionStatus = string.format('No watch entries for %s, using zone scan.', zone)
        pfSW(string.format('No watch entries for %s - auto-enabled zone scan.', zone))
    end

    local results   = {}
    local seenIDs   = {}
    local seenNames = {}

    local function consumeSpawn(sp, queryLabel)
        if not (sp and sp.ID() and sp.ID() > 0) then return end
        local ok, parsed = pcall(function()
            local id = sp.ID()
            local styp = tostring(sp.Type() or ''):upper()
            return {
                id = id,
                styp = styp,
                name = sp.CleanName() or sp.Name() or 'Unknown',
                x = math.floor(sp.X() or 0),
                y = math.floor(sp.Y() or 0),
                z = math.floor(sp.Z() or 0),
                dist = sp.Distance() or 0,
                hp = sp.PctHPs() or 100,
                lvl = sp.Level() or 0,
            }
        end)
        if not ok or not parsed then
            pfDbg('SW scan skipped spawn due to read error.')
            return
        end

        local id = parsed.id
        if seenIDs[id] then return end
        seenIDs[id] = true

        local name = parsed.name
        local x = parsed.x
        local y = parsed.y
        local z = parsed.z
        local dist = parsed.dist
        local hp = parsed.hp
        local lvl = parsed.lvl
        local styp = parsed.styp
        if BLOCKED_TYPES[styp] then return end

        seenNames[name] = true
        results[#results+1] = {
            id       = id,
            name     = name,
            location = string.format('%d, %d, %d', x, y, z),
            distance = dist,
            pctHPs   = hp,
            level    = lvl,
            query    = queryLabel,
            isUp     = true,
            lastSeen = os.time(),
        }

        -- Mark as back up in timer
        if (not scanAll) and sw.timers[name] and not sw.timers[name].upAt then
            sw.timers[name].upAt = os.time()
            if sw.alertsOn then
                pfSW(string.format(
                    'ALERT: %s is UP! (down ~%s)',
                    name, fmtDuration(os.time()-(sw.timers[name].downAt or os.time()))))
            end
        end
    end

    if scanAll then
        local query = 'npc targetable'
        local count = mq.TLO.SpawnCount(query)() or 0
        for i = 1, count do
            if i % SCAN_SLICE == 0 then mq.delay(1) end   -- spread over frames
            local sp = mq.TLO.NearestSpawn(i, query)
            consumeSpawn(sp, query)
        end
    else
        for _, query in ipairs(queries) do
            local count = mq.TLO.SpawnCount(query)() or 0
            for i = 1, count do
                if i % SCAN_SLICE == 0 then mq.delay(1) end
                local sp = mq.TLO.NearestSpawn(i, query)
                consumeSpawn(sp, query)
            end
        end
    end

    -- Detect mobs that dropped off → start respawn timer
    if not scanAll then
        local prev = sw.tracked[zone] or {}
        for _, old in ipairs(prev) do
            if old.isUp and not seenNames[old.name] then
                if not sw.timers[old.name] then
                    sw.timers[old.name] = { downAt=os.time(), upAt=nil, notes='' }
                    pfSW(string.format('Timer started for %s.', old.name))
                end
            end
        end
    end

    sortTracked(results)

    sw.tracked[zone]  = results
    sw.actionStatus = string.format('%s scan %s  — %d up  [%s]',
        scanAll and 'Zone-wide' or 'Watchlist',
        zone, #results, os.date('%H:%M:%S'))
end

local function swUpdateTrackedSafe(sourceLabel)
    local ok, err = pcall(swUpdateTracked)
    if ok then return true end
    local src = sourceLabel or 'scan'
    local msg = tostring(err or 'unknown error')
    sw.actionStatus = string.format('SW %s error (see log).', src)
    pfErr(string.format('SpawnWatch %s error: %s', src, msg))
    return false
end

---------------------------------------------------------------
-- SPAWN WATCH: ACTIONS
---------------------------------------------------------------
local function swTarget(id, name)
    local sp = spawnById(id)
    if not sp then
        sw.actionStatus = 'Cannot target '..( name or 'spawn')..' — not up.'
        return
    end
    mq.cmdf('/squelch /target id %d', id)
    sw.actionStatus = 'Targeted: '..(sp.CleanName() or name or tostring(id))
end

local function swNav(id, name)
    if not navLoaded() then sw.actionStatus = 'MQ2Nav not loaded.'; return end
    local sp = spawnById(id)
    if not sp then
        sw.actionStatus = 'Cannot nav to '..(name or 'spawn')..' — not up.'
        return
    end
    mq.cmdf('/squelch /nav id %d', id)
    sw.actionStatus = 'Navigating → '..(sp.CleanName() or name or tostring(id))
end

---------------------------------------------------------------
-- SPAWN WATCH: ADD / REMOVE QUERY
---------------------------------------------------------------
local function swAddQuery(query, zone)
    zone  = zone or getZone()
    query = (query or ''):match('^%s*(.-)%s*$')
    if query == '' then return end
    sw.watchlist[zone] = sw.watchlist[zone] or {}
    for _, q in ipairs(sw.watchlist[zone]) do
        if q == query then
            pfSW(string.format('"%s" already in %s watchlist.', query, zone))
            return
        end
    end
    sw.watchlist[zone][#sw.watchlist[zone]+1] = query
    saveWatchlist()
    sw.scanDirty = true
    pfSW(string.format('Watchlist [%s] + "%s"', zone, query))
end

local function swDelQuery(query, zone)
    zone = zone or getZone()
    query = (query or ''):match('^%s*(.-)%s*$')
    if not sw.watchlist[zone] then return end
    for i, q in ipairs(sw.watchlist[zone]) do
        if q == query then
            table.remove(sw.watchlist[zone], i)
            if #sw.watchlist[zone] == 0 then sw.watchlist[zone] = nil end
            saveWatchlist()
            sw.scanDirty = true
            pfSW(string.format('Watchlist [%s] - "%s"', zone, query))
            return
        end
    end
    pfWarn(string.format('"%s" not found in %s watchlist.', query, zone))
end

---------------------------------------------------------------
-- FARMING: REST
---------------------------------------------------------------
local function handleRest()
    local pctEnd  = mq.TLO.Me.PctEndurance() or 100
    local pctHP   = mq.TLO.Me.PctHPs()       or 100
    local pctMana = mq.TLO.Me.PctMana()      or 100
    local canCast = mq.TLO.Me.Class.CanCast() or false

    if ((pctEnd < 10) or (pctHP < 30) or
        (canCast and pctMana >= 1 and pctMana <= 15)) and not state.resting then
        state.resting    = true
        state.myTargetID = 0
        pfMsg('Resting — low resources. Will self-defend.')
    end

    local manaOk = (not canCast) or (pctMana >= 99)
    if state.resting and pctEnd >= 99 and pctHP >= 99 and manaOk then
        state.resting = false
        pfGood('Fully rested — resuming!')
    end

    if state.resting then
        local castID = mq.TLO.Me.Casting.ID()
        if castID and castID > 0 then
            pfDbg('Casting '..(mq.TLO.Me.Casting.Name() or '?'))
            mq.delay(
                math.ceil(((mq.TLO.Me.Casting.CastTime and
                    mq.TLO.Me.Casting.CastTime.Float()) or 1)*1000)+200)
        elseif mq.TLO.Me.Standing() then
            mq.cmd('/sit')
            mq.delay(1000, function() return mq.TLO.Me.Sitting() end)
        end
    end
end

---------------------------------------------------------------
-- FARMING: MOB VALIDATION
---------------------------------------------------------------
local function mobIDValidate(mobID)
    if not mobID or mobID == 0 then return false end
    local sp = mq.TLO.Spawn('id '..mobID)
    if not sp or not sp.ID() or sp.ID() == 0 then return false end
    if sp.Type() == 'Corpse' then return false end
    local locX = sp.X() or 0
    local locY = sp.Y() or 0
    local myID = mq.TLO.Me.ID() or 0
    local pc  = mq.TLO.SpawnCount(
        string.format('loc %d %d radius 75 pc notid %d', locX, locY, myID))() or 0
    local grp = mq.TLO.SpawnCount(
        string.format('loc %d %d radius 75 pc group notid %d', locX, locY, myID))() or 0
    if (pc - grp) > 0 then
        mq.cmdf('/popcustom 13 1 Player near target — finding new!')
        mq.delay(1000)
        return false
    end
    return true
end

---------------------------------------------------------------
-- FARMING: NO-KILL
---------------------------------------------------------------
local function handleNoKill()
    local sp   = mq.TLO.Spawn('id '..state.myTargetID)
    local name = (sp and sp.CleanName()) or tostring(state.myTargetID)
    pfErr(string.format('Mob %s not killable — auto-ignoring.', name))
    mq.cmdf('/squelch /alert add %d id %d', ALERT_IGNORE, state.myTargetID)
    mq.cmd('/squelch /target clear')
    mq.cmd('/squelch /attack off')
    state.myTargetID    = 0
    state.noKillCounter = 0
end

---------------------------------------------------------------
-- FARMING: CAN'T HIT → REPOSITION
---------------------------------------------------------------
local function handleCantHit()
    if state.cantHit and os.clock() < state.cantHitTimer then return end
    state.cantHit      = true
    state.cantHitTimer = os.clock() + 5
    local targetID = mq.TLO.Target.ID()
    if not targetID or targetID == 0 then return end
    local tsp = mq.TLO.Spawn('id '..targetID)
    if not tsp then return end
    local tx,ty,tz = tsp.X() or 0, tsp.Y() or 0, tsp.Z() or 0
    local th = tsp.Heading.Degrees() or 0
    for i = 1, 72 do
        local angle = (360/36)*i + (th-5)
        local rad   = math.rad(angle)
        local xOff  = tx + 15*math.cos(rad)
        local yOff  = ty + 15*math.sin(rad)
        if mq.TLO.Navigation.PathExists(
               string.format('locyxz %f %f %f', yOff, xOff, tz))() and
           mq.TLO.LineOfSight(
               string.format('%f,%f,%f:%f,%f,%f', yOff,xOff,tz,ty,tx,tz))() and
           mq.TLO.EverQuest.ValidLoc(
               string.format('%f %f %f', xOff, yOff, tz))() then
            mq.cmdf('/nav locyxz %f %f %f facing=backward', yOff, xOff, tz)
            mq.delay(1000, function() return mq.TLO.Navigation.Active()==true  end)
            mq.delay(5000, function() return mq.TLO.Navigation.Active()==false end)
            if (mq.TLO.Target.ID() or 0) > 0 then mq.cmd('/face fast') end
            state.cantHit      = false
            state.cantHitTimer = os.clock() + 10
            return
        end
    end
end

---------------------------------------------------------------
-- FARMING: ENGAGE
---------------------------------------------------------------
local function engageMob()
    if not mobIDValidate(state.myTargetID) then
        state.myTargetID = 0; return
    end
    local sp = mq.TLO.Spawn('npc id '..state.myTargetID)
    if not sp or not sp.LineOfSight() then return end
    local dist = sp.Distance3D() or 9999
    local tid  = mq.TLO.Target.ID() or 0

    if tid ~= state.myTargetID and dist < 360 then
        mq.cmdf('/squelch /target id %d', state.myTargetID)
        mq.delay(5000, function()
            return (mq.TLO.Target.ID() or 0) == state.myTargetID
        end)
    end
    if mq.TLO.Target.Aggressive() then return end

    local ri = mq.TLO.Me.Inventory('ranged')
    if ri and ri.ID() then
        local rt  = ri.Type() or ''
        local rng = ri.Range() or 0
        local max = rt:find('Archery') and rng*2 or rng
        if dist >= 35 and dist <= max then
            if rt:find('Throwing') then mq.cmd('/ranged') end
            if rt:find('Archery') then
                local ammo = mq.TLO.Me.Inventory('ammo')
                if ammo and (ammo.Type() or ''):find('Arrow') then mq.cmd('/ranged') end
            end
            mq.delay(500)
        end
    end

    local class = mq.TLO.Me.Class.Name() or ''
    local level = mq.TLO.Me.Level()      or 0

    if class=='Monk' and level>=96 and dist<300
       and mq.TLO.Me.AltAbilityReady('Distant Strike') then
        mq.cmd('/alt act 376')
        mq.delay(1000, function() return not mq.TLO.Me.AltAbilityReady('Distant Strike') end)
    end
    if class=='Bard' and level>=63 and dist<250
       and mq.TLO.Me.AltAbilityReady('Sonic Disturbance') then
        mq.cmd('/alt act 200')
    end
    if dist<=70 and mq.TLO.Me.CombatAbility('Throw Stone')
       and mq.TLO.Me.CombatAbilityReady('Throw Stone') then
        mq.cmd('/disc Throw Stone')
    end
    if (mq.TLO.Target.ID() or 0)>0 and dist<25
       and mq.TLO.Me.Skill('Taunt') and mq.TLO.Me.AbilityReady('Taunt') then
        mq.cmd('/doability Taunt')
    end
    if mq.TLO.Me.Class.PetClass() and mq.TLO.Me.Pet.ID() then
        if not mq.TLO.Target.Aggressive() then
            mq.cmd('/pet attack')
            mq.delay(5000, function() return mq.TLO.Target.Aggressive()==true end)
        end
    end
end

---------------------------------------------------------------
-- FARMING: NAV TO MOB
---------------------------------------------------------------
local function navToMob()
    if not navLoaded() then
        pfDbgEvery('nav-missing', 1500, 'navToMob: mq2nav not loaded')
        return
    end
    if not mq.TLO.Navigation.Active() then
        pfDbgEvery('nav-start', 1000, string.format('navToMob: /nav id %d', state.myTargetID))
        mq.cmdf('/squelch /nav id %d dist=10', state.myTargetID)
    else
        local sp = mq.TLO.Spawn('id '..state.myTargetID)
        if sp then
            local h = sp.HeadingTo() or ''
            if h ~= state.lastHeading and (sp.Speed() or 0) > 25 then
                pfDbgEvery('nav-refresh', 1000, string.format(
                    'navToMob: target moving, refreshing nav id %d', state.myTargetID))
                mq.cmdf('/squelch /nav id %d dist=10', state.myTargetID)
                state.lastHeading = h
            end
        end
    end
    engageMob()
end

---------------------------------------------------------------
-- FARMING: COMBAT
---------------------------------------------------------------
local function handleCombat()
    local tid = mq.TLO.Target.ID() or 0
    if not mq.TLO.Me.Combat() then
        pfDbgEvery('combat-start', 1000, string.format(
            'handleCombat: attack on target=%d', state.myTargetID))
        if tid ~= state.myTargetID then
            mq.cmdf('/squelch /target id %d', state.myTargetID)
            state.noKillCounter = 0
        else
            state.noKillCounter = state.noKillCounter + 1
        end
        mq.cmd('/squelch /attack on')
        mq.cmdf('/squelch /face fast id %d', mq.TLO.Target.ID() or 0)
    elseif (mq.TLO.Target.ID() or 0) ~= state.myTargetID then
        pfDbgEvery('combat-retarget', 1000, string.format(
            'handleCombat: retarget from %d to %d',
            mq.TLO.Target.ID() or 0, state.myTargetID))
        mq.cmdf('/squelch /target id %d', state.myTargetID)
        mq.cmdf('/squelch /face id %d', mq.TLO.Target.ID() or 0)
        state.noKillCounter = 0
    end
    if (mq.TLO.Target.Type() or '') == 'corpse' then
        pfDbg('handleCombat: target became corpse, clearing target/myTargetID')
        mq.cmd('/squelch /target clear')
        state.myTargetID = 0
    end
    if state.noKillCounter >= 20 then
        pfDbg('handleCombat: target not entering combat, auto-ignore')
        handleNoKill()
    end
end

---------------------------------------------------------------
-- FARMING: FIND MOB
---------------------------------------------------------------
local function findMob()
    if state.resting then return end

    -- When Pull=ALL, alert slot 10 is empty so 'alert 10' returns zero results.
    -- Only use the alert clause when specific pull targets are configured.
    local pullIsAll = (tostring(state.pull or 'ALL'):lower() == 'all')
    local search
    if state.campOn then
        if pullIsAll then
            search = string.format(
                'npc noalert %d targetable loc %d %d radius %d zradius %d',
                ALERT_IGNORE, state.campX, state.campY, state.radius, state.zRadius)
        else
            search = string.format(
                'npc noalert %d targetable loc %d %d radius %d zradius %d alert %d',
                ALERT_IGNORE, state.campX, state.campY, state.radius, state.zRadius, ALERT_PULL)
        end
    else
        if pullIsAll then
            search = string.format(
                'npc noalert %d targetable radius %d zradius %d',
                ALERT_IGNORE, state.radius, state.zRadius)
        else
            search = string.format(
                'npc noalert %d targetable radius %d zradius %d alert %d',
                ALERT_IGNORE, state.radius, state.zRadius, ALERT_PULL)
        end
    end

    local count = math.min(mq.TLO.SpawnCount(search)() or 0, 25)
    local navReady = navLoaded()
    local zone = getZone()
    local skipBlocked, skipPassive, skipSurname, skipValidate, skipNoPath = 0, 0, 0, 0, 0
    pfDbgEvery('findMob-search', 1000, string.format(
        'findMob count=%d nav=%s pull=%s',
        count, tostring(navReady), tostring(state.pull)))

    if count == 0 then
        local swBestID, swBestDist = 0, math.huge
        local tracked = sw.tracked[zone] or {}
        pfDbgEvery('findMob-empty', 1500, string.format(
            'findMob no SpawnSearch hits; SW tracked=%d zone=%s', #tracked, zone))
        for _, entry in ipairs(tracked) do
            local mobID = tonumber(entry.id) or 0
            if mobID > 0 and mobID ~= state.myTargetID then
                local sp = mq.TLO.Spawn('id '..mobID)
                if sp and sp.ID() and sp.ID() > 0 then
                    local t = (sp.Type() or ''):upper()
                    if t ~= 'CORPSE' and not BLOCKED_TYPES[t] then
                        local dist = sp.Distance3D() or math.huge
                        if dist < swBestDist then
                            swBestDist = dist
                            swBestID = mobID
                        end
                    end
                end
            end
        end

        pfDbgEvery('findMob-fallback', 1500, string.format(
            'findMob fallback result swBestID=%d skips b=%d p=%d s=%d v=%d np=%d tracked=%d',
            swBestID, skipBlocked, skipPassive, skipSurname, skipValidate, skipNoPath, #tracked))
        if swBestID > 0 then
            state.myTargetID = swBestID
            state.announce = false
            state.noKillCounter = 0
            local sp = mq.TLO.Spawn('id '..swBestID)
            pfDbg(string.format('findMob SW pick id=%d dist=%.1f', swBestID, swBestDist))
            pfSW(string.format('Pulling %s (%d) - %.0f ft.',
                (sp and sp.Name()) or '?', swBestID, swBestDist))
            mq.delay(100)
            return
        end

        pfDbgEvery('findMob-wait', 2500, 'findMob no candidates from search/SW; entering wait')
        state.myTargetID = 0
        mq.delay(5000, function() return (mq.TLO.Me.XTarget() or 0)==0 end)
        if (mq.TLO.Me.XTarget() or 0) == 0 then
            if not state.announce then
                pfMsg('No mobs in range — waiting for respawn.')
                state.announce = true
                if state.campOn then
                    pfMsg('Returning to camp.')
                    mq.cmdf('/nav loc %d %d %d',
                        state.campY, state.campX, state.campZ)
                end
            end
            if mq.TLO.Me.Standing() and not mq.TLO.Navigation.Active() then
                mq.cmd('/sit')
            end
        end
        mq.delay(100)
        return
    end

    local bestID, bestPath = 0, math.huge
    for i = 1, count do
        local sp = mq.TLO.NearestSpawn(i, search)
        if sp and sp.ID() and sp.ID() > 0 then
            local mobID  = sp.ID()
            if BLOCKED_TYPES[(sp.Type() or ''):upper()] then skipBlocked = skipBlocked + 1; goto cont end
            if sp.Surname() and sp.Surname() ~= '' then skipSurname = skipSurname + 1; goto cont end
            local hasPath = true
            if navReady then
                hasPath = (mq.TLO.Navigation.PathExists('id '..mobID)() == true)
            end
            local valid = mobIDValidate(mobID)
            if not valid then skipValidate = skipValidate + 1; goto cont end
            if not hasPath then skipNoPath = skipNoPath + 1; goto cont end
            local pl = 0
            if navReady then
                pl = mq.TLO.Navigation.PathLength('id '..mobID)() or 0
            end
            local dist = (pl > 0) and pl or (sp.Distance3D() or math.huge)
            if dist < bestPath then
                bestID   = mobID
                bestPath = dist
            end
        end
        ::cont::
    end

    if bestID > 0 then
        state.myTargetID    = bestID
        state.announce      = false
        state.noKillCounter = 0
        local sp = mq.TLO.Spawn('id '..bestID)
        pfDbg(string.format(
            'findMob selected id=%d dist=%.1f skips b=%d p=%d s=%d v=%d np=%d',
            bestID, bestPath, skipBlocked, skipPassive, skipSurname, skipValidate, skipNoPath))
        pfMsg(string.format('Pulling %s (%d) — %.0f ft.',
            (sp and sp.Name()) or '?', bestID, bestPath))
    else
        local swBestID, swBestDist = 0, math.huge
        local tracked = sw.tracked[zone] or {}
        for _, entry in ipairs(tracked) do
            local mobID = tonumber(entry.id) or 0
            if mobID > 0 and mobID ~= state.myTargetID then
                local sp = mq.TLO.Spawn('id '..mobID)
                if sp and sp.ID() and sp.ID() > 0 then
                    local t = (sp.Type() or ''):upper()
                    if t ~= 'CORPSE' and not BLOCKED_TYPES[t] then
                        local dist = sp.Distance3D() or math.huge
                        if dist < swBestDist then
                            swBestDist = dist
                            swBestID = mobID
                        end
                    end
                end
            end
        end

        if swBestID > 0 then
            state.myTargetID = swBestID
            state.announce = false
            state.noKillCounter = 0
            local sp = mq.TLO.Spawn('id '..swBestID)
            pfDbg(string.format(
                'findMob fallback SW id=%d dist=%.1f skips b=%d p=%d s=%d v=%d np=%d',
                swBestID, swBestDist, skipBlocked, skipPassive, skipSurname, skipValidate, skipNoPath))
            pfSW(string.format('Pulling %s (%d) - %.0f ft.',
                (sp and sp.Name()) or '?', swBestID, swBestDist))
        end
    end
    mq.delay(100)
end

---------------------------------------------------------------
-- CAMP SETUP
---------------------------------------------------------------
local function setupCamp(radius)
    state.campX = mq.TLO.Me.X() or 0
    state.campY = mq.TLO.Me.Y() or 0
    state.campZ = mq.TLO.Me.Z() or 0
    if radius and radius > 0 then state.radius = radius end
    mq.cmdf('/squelch /maploc %d %d Size 20 width 5 color 0 0 255 radius %d color 0 0 255',
        state.campY, state.campX, state.radius)
    mq.cmd('/squelch /mapfilter SpellRadius 0')
    pfGood(string.format('Camp @ Y=%.0f X=%.0f Z=%.0f  R=%d',
        state.campY, state.campX, state.campZ, state.radius))
end

---------------------------------------------------------------
-- PLUGIN MANAGEMENT
---------------------------------------------------------------
local function ensurePlugins()
    local class    = (mq.TLO.Me.Class.ShortName() or ''):lower()
    local isRogBer = (class=='rog' or class=='ber')
    local hasMelee = mq.TLO.Plugin('mq2melee').IsLoaded()
    if not mq.TLO.Plugin('mq2nav').IsLoaded() then
        mq.cmd('/squelch /plugin mq2nav noauto')
    end
    if isRogBer and hasMelee and
       (mq.TLO.Plugin('mq2berzerker').IsLoaded() or
        mq.TLO.Plugin('mq2rogue').IsLoaded()) then
        pfMsg('Class plugin found — unloading mq2melee/cast temporarily.')
        mq.cmd('/squelch /plugin mq2melee unload noauto')
        mq.cmd('/squelch /plugin mq2cast unload noauto')
    else
        if not mq.TLO.Plugin('mq2melee').IsLoaded() then
            mq.cmd('/squelch /plugin mq2melee noauto')
        end
        if not mq.TLO.Plugin('mq2cast').IsLoaded() then
            mq.cmd('/squelch /plugin mq2cast noauto')
        end
    end
end

---------------------------------------------------------------
-- ACTIONS (shared by the window and the /pkf aliases)
---------------------------------------------------------------
local requests = {}
local function doGo()
    state.goFarming = true
    state.debugOn = true
    pfGood('PocketFarm GO!')
    pfMsg('Debug ON (auto).')
end
local function doPause() state.goFarming = false; pfMsg('PocketFarm PAUSED.') end
local function setRadius(r)
    if not (r and r > 0) then return false end
    state.radius = r; iniWrite('Radius', r)
    if state.campOn then
        mq.cmdf('/squelch /maploc %d %d Size 20 width 5 color 0 0 255 radius %d color 0 0 255', state.campY, state.campX, r)
    else mq.cmdf('/squelch /mapfilter SpellRadius %d', r) end
    pfGood('Radius → '..r)
    return true
end
local function setZRadius(z)
    if not (z and z > 0) then return false end
    state.zRadius = z; iniWrite('ZRadius', z); pfGood('Z-Radius → '..z)
    return true
end
local function toggleCamp()
    if state.campOn then
        state.campOn = false
        mq.cmd('/squelch /maploc remove')
        mq.cmdf('/squelch /mapfilter SpellRadius %d', state.radius)
        pfMsg('Camp disabled.')
    else
        state.campOn = true; setupCamp(0)
    end
end
local function clearZoneWatch(z)
    z = z or getZone()
    sw.watchlist[z] = nil; sw.tracked[z] = {}
    saveWatchlist(); pfSW('Watchlist cleared for '..z)
end

---------------------------------------------------------------
-- BIND COMMAND: /pkf
---------------------------------------------------------------
local function bindPkf(...)
    local args = {...}
    local cmd  = (args[1] or ''):lower()
    local arg2 = args[2] or ''
    local arg3 = args[3] or ''

    if     cmd == 'go'    then doGo()
    elseif cmd == 'pause' then doPause()
    elseif cmd == 'load'  then loadIni()
    elseif cmd == 'radius' then
        setRadius(tonumber(arg2))
    elseif cmd == 'zradius' then
        setZRadius(tonumber(arg2))
    elseif cmd == 'ignore' then
        if addIgnoreEntry(arg2) then pfMsg('Ignore + '..arg2) end
    elseif cmd == 'pull'   then
        if addPullEntry(arg2) then pfMsg('Pull + '..arg2) end
    elseif cmd == 'clear'  then
        if arg2=='ignore' then clearIgnoreEntries(); pfMsg('Ignore cleared.')
        elseif arg2=='pull' then clearPullEntries(); pfMsg('Pull cleared.') end
    elseif cmd == 'list'  then alertList(ALERT_IGNORE); alertList(ALERT_PULL)
    elseif cmd == 'watch' then
        local sub = arg2:lower()
        if sub == 'add'  then swAddQuery(arg3)
        elseif sub=='del' or sub=='remove' then swDelQuery(arg3)
        elseif sub=='scan' then
            sw.scanDirty=true; swUpdateTrackedSafe('cmd_watch_scan'); pfSW('Scan done.')
        elseif sub=='list' then
            local z=getZone(); local qs=sw.watchlist[z] or {}
            pfSW(string.format('Watchlist [%s] %d queries:', z, #qs))
            for i,q in ipairs(qs) do pfSW(string.format('  %d. %s',i,q)) end
        elseif sub=='clear' then
            clearZoneWatch()
        else pfMsg('/pkf watch add|del|list|scan|clear "query"') end
    elseif cmd == 'ui'    then state.showUI = not state.showUI
    elseif cmd == 'debug' then
        state.debugOn=not state.debugOn
        pfMsg('Debug '..(state.debugOn and 'ON' or 'OFF'))
    else
        pfMsg('=== PocketFarm v'..VERSION..' Commands ===')
        pfMsg('/pkf go|pause              — Farm control')
        pfMsg('/pkf load                  — Reload zone INI')
        pfMsg('/pkf radius ##             — XY search radius')
        pfMsg('/pkf zradius ##            — Z axis radius')
        pfMsg('/pkf ignore "name"         — Temp ignore')
        pfMsg('/pkf pull "name"           — Temp pull-only')
        pfMsg('/pkf clear ignore|pull     — Clear a list')
        pfMsg('/pkf list                  — Show lists in chat')
        pfMsg('/pkf watch add "query"     — Add to spawn watchlist')
        pfMsg('/pkf watch del "query"     — Remove from watchlist')
        pfMsg('/pkf watch scan            — Force rescan now')
        pfMsg('/pkf watch list            — Print zone watchlist')
        pfMsg('/pkf watch clear           — Clear zone watchlist')
        pfMsg('/pkf ui                    — Toggle window')
        pfMsg('/pkf debug                 — Toggle debug log')
    end
end

---------------------------------------------------------------
-- INIT
---------------------------------------------------------------
local function init(param0, param1)
    param0 = param0 or ''
    param1 = tonumber(param1) or 0

    state.campOn    = param0:lower() == 'camp'
    state.goFarming = param0:lower() == 'go'
    state.campX = mq.TLO.Me.X() or 0
    state.campY = mq.TLO.Me.Y() or 0
    state.campZ = mq.TLO.Me.Z() or 0
    if param1 > 0 then state.radius = param1 end

    mq.cmd('/squelch /nav setopt log=critical')
    mq.cmd('/squelch /alert clear 1')
    mq.cmd('/squelch /alert clear 10')

    pfGood(string.format('PocketFarm v%s  farming + SpawnWatch', VERSION))
    pfMsg('Everything is in the window. /pkf lists the optional command aliases.')

    loadIni(param1)
    loadWatchlist()
    autoIgnoreNPCs()

    if state.campOn then setupCamp(param1)
    else mq.cmdf('/squelch /mapfilter SpellRadius %d', state.radius) end

    ensurePlugins()

    if state.goFarming then pfGood('GO parameter — farming immediately!')
    else pfMsg('Ready. Use /pkf go to start.') end

    state.running = true
    sw.scanDirty  = true
end

---------------------------------------------------------------
-- REGISTER
---------------------------------------------------------------
pcall(function() mq.unevent('CantHitMelee') end)
pcall(function() mq.unevent('CantHitLOS') end)
mq.bind('/pkf', bindPkf)
mq.event('CantHitMelee', "You can't hit them from here.", handleCantHit)
mq.event('CantHitLOS',   'You cannot see your target.',   handleCantHit)

---------------------------------------------------------------
-- ENTRY POINT
---------------------------------------------------------------
local function spawnInfo(id)
    local sp = spawnById(id)
    if not sp then return nil end
    local ok, t = pcall(function()
        return { name = sp.CleanName() or sp.Name() or '?', hp = sp.PctHPs() or 0, dist = sp.Distance3D() or 0 }
    end)
    return ok and t or nil
end
local UIAPI = {
    state = state, sw = sw, version = VERSION, zone = getZone, fmtDuration = fmtDuration,
    log = function() return consoleLines end, logrev = function() return logRev end,
    clearLog = function() consoleLines = {}; logRev = logRev + 1 end,
    me = function() local me = mq.TLO.Me; return me.PctHPs() or 0, me.PctMana() or 0, me.PctEndurance() or 0 end,
    spawn_info = spawnInfo,
    go = doGo, pause = doPause,
    request = function(what) requests[what] = true; if what == 'scan' then sw.actionStatus = 'Scan queued...' end end,
    alertLists = function() alertList(ALERT_IGNORE); alertList(ALERT_PULL) end,
    target = swTarget, nav = swNav,
    addQuery = function(q, z) swAddQuery(q, z) end, delQuery = swDelQuery, clearZoneWatch = clearZoneWatch,
    clearTimers = function() sw.timers = {}; pfSW('All timers cleared.') end,
    resort = function() local t = sw.tracked[getZone()]; if t then sortTracked(t); sw.tracked[getZone()] = { unpack(t) } end end,
    addIgnore = function(n, say) if addIgnoreEntry(n) and say then pfMsg('Ignore + '..trim(n)) end end,
    addPull = function(n, say) if addPullEntry(n) and say then pfMsg('Pull + '..trim(n)) end end,
    clearIgnore = function() clearIgnoreEntries(); pfMsg('Ignore cleared.') end,
    clearPull = function() clearPullEntries(); pfMsg('Pull cleared.') end,
    setRadius = setRadius, setZRadius = setZRadius, toggleCamp = toggleCamp,
    setDebug = function(on) state.debugOn = on; pfMsg('Debug '..(on and 'ON' or 'OFF')) end,
    stop = function() state.running = false; state.stopRequested = true; pfMsg('Stop pressed.') end,
}
local startArgs = {...}
UI.init(UIAPI)      -- window first, so it is up while the zone settings load
mq.delay(1)
init(startArgs[1], startArgs[2])

local lastScanMs = 0

while state.running do
    mq.doevents()

    -- ── WINDOW REQUESTS (heavier work runs here, not in the frame callback) ──
    if requests.ini then requests.ini = nil; loadIni() end
    if requests.scan then
        requests.scan = nil
        swUpdateTrackedSafe('window'); pfSW('Manual scan triggered.')
        lastScanMs = mq.gettime(); sw.scanDirty = false
    end
    if not state.running then break end

    -- ── SPAWN WATCH SCAN ─────────────────────────────────
    local nowMs = mq.gettime()
    if sw.autoScan and (sw.scanDirty or (nowMs - lastScanMs) >= SW_INTERVAL) then
        swUpdateTrackedSafe('auto')
        lastScanMs   = nowMs
        sw.scanDirty = false
    end

    -- ── DEATH ────────────────────────────────────────────
    if mq.TLO.Me.Hovering() then
        pfErr('We died! Stopping farming.')
        state.running = false; state.goFarming = false; break
    end

    -- ── XTARGET PICKUP ───────────────────────────────────
    local xtCount = mq.TLO.Me.XTarget() or 0
    local tSp     = state.myTargetID > 0 and
                    mq.TLO.Spawn('id '..state.myTargetID) or nil
    local tAlive  = tSp and tSp.ID() and tSp.ID()>0 and tSp.Type()~='Corpse'

    if not tAlive and xtCount > 0 then
        local picked = 0
        for i = 1, math.min(xtCount, 5) do
            local xs = mq.TLO.Me.XTarget(i)
            local xid = (xs and xs.ID and xs.ID()) or 0
            if xid > 0 then
                local xsp = mq.TLO.Spawn('id '..xid)
                if xsp and xsp.ID() and xsp.ID() > 0 and xsp.Type() ~= 'Corpse' and
                   not BLOCKED_TYPES[(xsp.Type() or ''):upper()] then
                    picked = xid
                    break
                end
            end
        end
        state.myTargetID = picked
        if state.myTargetID > 0 then
            pfDbgEvery('xtarget-pick', 1000, string.format('XT pick id=%d', state.myTargetID))
            handleCombat()
        else
            pfDbgEvery('xtarget-unusable', 1500, string.format(
                'XT present (%d) but no usable target id; continuing normal find', xtCount))
        end
    end

    if mq.TLO.Me.Sitting() and xtCount > 0 then mq.cmd('/stand') end

    if not tAlive and xtCount == 0 then handleRest() end

    -- ── CLEAR SELF / CORPSE TARGET ───────────────────────
    local tid = mq.TLO.Target.ID() or 0
    if (mq.TLO.Target.Type() or '')=='corpse' or
       tid==(mq.TLO.Me.ID() or -1) then
        if not (mq.TLO.Me.Casting.ID() and mq.TLO.Me.Casting.ID()>0) then
            mq.cmd('/squelch /target clear')
        end
    end
    if (mq.TLO.Target.Type() or '')=='corpse' or
       tid==(mq.TLO.Me.ID() or -1) or tid==0 then
        mq.cmd('/squelch /attack off')
    end

    -- ── FIND MOB ─────────────────────────────────────────
    if state.goFarming then
        local sp2   = state.myTargetID>0 and
                      mq.TLO.Spawn('id '..state.myTargetID) or nil
        local alive2 = sp2 and sp2.ID() and sp2.ID()>0 and sp2.Type()~='Corpse'
        local cast   = mq.TLO.Me.Casting.ID()
        if not (cast and cast>0) and not alive2 then
            findMob()
        else
            pfDbgEvery('loop-find-gate', 1200, string.format(
                'GO gate blocked: cast=%s alive=%s xt=%d targetID=%d resting=%s',
                tostring((cast and cast>0) and true or false),
                tostring(alive2 and true or false),
                xtCount, state.myTargetID, tostring(state.resting)))
        end
    end

    -- ── NAV / COMBAT ─────────────────────────────────────
    local sp3 = state.myTargetID>0 and
                mq.TLO.Spawn('id '..state.myTargetID) or nil
    if sp3 and sp3.ID() and sp3.ID()>0 and sp3.Type()~='Corpse' then
        local dist = sp3.Distance3D() or 9999
        local maxR = sp3.MaxRangeTo()  or 15
        if not (mq.TLO.Me.Rooted.ID() and mq.TLO.Me.Rooted.ID()>0) then
            if dist > maxR then navToMob()
            else                handleCombat() end
        else
            pfDbgEvery('loop-rooted', 1500, string.format(
                'movement blocked: rooted with target id=%d dist=%.1f maxR=%.1f',
                state.myTargetID, dist, maxR))
        end
    end

    -- ── FACE TARGET ──────────────────────────────────────
    if mq.TLO.Me.Combat() and
       state.myTargetID == (mq.TLO.Target.ID() or 0) then
        local tgt = mq.TLO.Target
        if tgt and tgt.HeadingTo then
            local ht = tgt.HeadingTo.ShortName()
            local mh = mq.TLO.Me.Heading()
            if ht and mh and ht~=mh then mq.cmd('/face fast') end
        end
    end

    -- ── NO-KILL COUNTER ──────────────────────────────────
    if mq.TLO.Me.Combat() and
       state.myTargetID==(mq.TLO.Target.ID() or 0) and
       (mq.TLO.Target.PctHPs() or 0)==100 and
       not mq.TLO.Me.Moving() then
        state.noKillCounter = state.noKillCounter + 1
    end
    if state.noKillCounter >= 30 then handleNoKill() end

    mq.delay(300)
end

-- ── CLEANUP ──────────────────────────────────────────────────
pfMsg('Shutting down — cleaning up map/nav.')
mq.cmd('/squelch /maploc remove')
mq.cmd('/squelch /nav setopt log=info')
saveWatchlist()
pfMsg('Watchlist saved. Goodbye.')
UI.shutdown()
