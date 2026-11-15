-- combatfx trackers: XP/AA per hour window + loot value per hour window. Both optional (settings > XP & Loot).
-- Polls TLOs at 1 Hz, all writes go through the diffed proxy (values only change -> 0 idle writes; the session
-- clock is shown in whole minutes). Loot lines come from mq.event (registered on the main thread from init.lua).
local mq = require('mq')
local C = require('combatfx.core')
local M = { registered = 0 }
local XW, LW
local ROWS, HIST = 8, 40

-- ---------------------------------------------------------------- XP
local X = {}
function M.reset_xp()
    X.t0 = C.now(); X.xp, X.aa = 0, 0; X.lvl, X.pct, X.aapts, X.aapct = nil, nil, nil, nil; X.lost = 0
end
local function lvl_now() return C.num(function() return mq.TLO.Me.Level() end, nil) end
local function pct_now() return C.num(function() return mq.TLO.Me.PctExp() end, nil) end
local function aapct_now() return C.num(function() return mq.TLO.Me.PctAAExp() end, nil) end
local function aapts_now()
    local t = C.num(function() return mq.TLO.Me.AAPointsTotal() end, nil)
    if t then return t end
    local a, s = C.num(function() return mq.TLO.Me.AAPoints() end, nil), C.num(function() return mq.TLO.Me.AAPointsSpent() end, 0)
    return a and (a + s) or nil
end
-- pure delta math (exported for the mock): progress in "percent of a level / AA point"
function M.delta(l0, p0, l1, p1)
    if not (l0 and p0 and l1 and p1) then return 0, false end
    if l1 > l0 then return (100 - p0) + p1 + 100 * (l1 - l0 - 1), false end
    if l1 < l0 then return 0, true end                        -- delevel (death): rebaseline
    if p1 < p0 - 0.0001 then return 0, true end               -- death xp loss: rebaseline, not counted
    return p1 - p0, false
end
function M.sample_xp(lvl, pct, aapts, aapct)
    if X.lvl then
        local d, lost = M.delta(X.lvl, X.pct, lvl, pct); X.xp = X.xp + d; if lost then X.lost = X.lost + 1 end
        local a = M.delta(X.aapts, X.aapct, aapts, aapct); X.aa = X.aa + a
    end
    X.lvl, X.pct, X.aapts, X.aapct = lvl, pct, aapts, aapct
end

-- ---------------------------------------------------------------- loot
local L = { hist = {}, page = 1 }
function M.reset_loot() L.t0 = C.now(); L.total, L.items, L.unknown = 0, 0, 0; L.hist = {}; L.page = 1; L.pending = {}; L.last = nil end
function M.loot_totals() return L.total, L.items, L.t0 end      -- f10: Tracking > Session (loot value per hour)
local function split(cp)
    cp = math.floor(cp or 0)
    local pp, r = math.floor(cp / 1000), cp % 1000
    local gp, r2 = math.floor(r / 100), r % 100
    return pp, gp, math.floor(r2 / 10), r2 % 10
end
-- big coin row: painted coin icons, zero denominations dimmed
function M.money(cp)
    local v = { split(cp) }
    local o = {}
    for i, k in ipairs({ 'pp', 'gp', 'sp', 'cp' }) do
        o[#o + 1] = string.format('<span class="coin %s%s"><img src="../img/coin_%s_32.png"/>%d</span>', k, v[i] == 0 and ' z' or '', k, v[i])
    end
    return table.concat(o)
end
-- compact: only the two largest non-zero denominations, with small coin icons
function M.money_short(cp)
    local v = { split(cp) }
    local o = {}
    for i, k in ipairs({ 'pp', 'gp', 'sp', 'cp' }) do
        if v[i] > 0 and #o < (v[1] >= 100 and 1 or 2) then o[#o + 1] = string.format('%d<img src="../img/coin_%s_32.png"/>', v[i], k) end
    end
    if #o == 0 then o[1] = '0<img src="../img/coin_cp_32.png"/>' end
    return '<span class="mini">' .. table.concat(o, ' ') .. '</span>'
end
-- "You have looted 5 Bone Chips." / "--You have looted a Bone Chip from a skeleton's corpse.--" -> name, count
function M.parse(line)
    local s = tostring(line or ''):gsub('^%s+', ''):gsub('%s+$', '')
    s = s:gsub('^%-%-', ''):gsub('%-%-$', '')
    local body = s:match('^You have looted (.+)$'); if not body then return nil end
    body = body:gsub('%.$', ''):gsub(' from .-corpse$', ''):gsub('%.$', '')
    local n, rest = body:match('^(%d+) (.+)$')
    local cnt = tonumber(n) or 1
    if not n then rest = body:gsub('^an? ', ''):gsub('^some ', ''):gsub('^the ', '') end
    rest = rest:gsub('^%s+', ''):gsub('%s+$', '')
    if rest == '' then return nil end
    return rest, cnt
end
local function lookup(name)
    local function v(n) return C.num(function() local it = mq.TLO.FindItem('=' .. n); if it() then return it.Value() end end, nil) end
    local val = v(name)
    if not val and name:sub(-1) == 's' then val = v(name:sub(1, -2)) end
    if not val and name:sub(-2) == 'es' then val = v(name:sub(1, -3)) end
    return val
end
function M.on_loot(line)
    if not C.cfg.loot then return end
    local key = tostring(line)
    if L.last == key and C.now() - (L.last_t or 0) < 250 then return end   -- both patterns matched the same line
    L.last, L.last_t = key, C.now()
    local name, cnt = M.parse(line); if not name then return end
    L.pending[#L.pending + 1] = { name = name, cnt = cnt, t = C.now() + 400 }   -- item lands in bags a moment later
end
function M.add_loot(name, cnt, val)
    local unk = val == nil
    local tot = (val or 0) * cnt
    L.total, L.items = L.total + tot, L.items + cnt
    if unk then L.unknown = L.unknown + 1 end
    table.insert(L.hist, 1, { name = name, cnt = cnt, v = tot, unk = unk })
    if #L.hist > HIST then L.hist[#L.hist] = nil end
    L.page = 1
end
local LOOT_EVENTS = { { 'cfx_loot1', 'You have looted #1#.' }, { 'cfx_loot2', '--You have looted #1#.--' }, { 'cfx_loot3', '#*#--You have looted #1#.--#*#' } }
function M.register()
    local n = 0
    for _, e in ipairs(LOOT_EVENTS) do if pcall(mq.event, e[1], e[2], function(line) M.on_loot(line) end) then n = n + 1 end end
    M.registered = n
end
function M.unregister() for _, e in ipairs(LOOT_EVENTS) do pcall(mq.unevent, e[1]) end end

-- ---------------------------------------------------------------- windows
local function hrs(t0) return math.max((C.now() - (t0 or C.now())) / 3600000, 1 / 3600) end
local function hm(ms) local m = math.floor(ms / 60000); if m < 60 then return string.format('%d min', m) end; return string.format('%dh %02dm', math.floor(m / 60), m % 60) end
local WAIT = '<span class="tv wait">gathering&#8230;</span>'
local function val(id, html, waiting) return waiting and WAIT or html end
local function draw_xp()
    if not XW or not XW.visible then return end
    local p, ap = X.pct or 0, X.aapct or 0
    XW:style('xpf', 'width', string.format('%.1f%%', C.clamp(p, 0, 100)))
    XW:style('aaf', 'width', string.format('%.1f%%', C.clamp(ap, 0, 100)))
    XW:text('xpl', X.lvl and string.format('Level %s  -  %.1f%%', X.lvl, p) or 'Reading your level...')
    XW:text('aal', X.aapts and string.format('AA %s  -  %.1f%% to next point', X.aapts, ap) or 'AA')
    local h = hrs(X.t0)
    local xr, ar = X.xp / h, X.aa / h
    -- under 1 minute of data the rate is noise: friendly "gathering..." instead of numbers
    local early = C.now() - X.t0 < 60000
    XW:rml('xph', early and 'gathering&#8230;' or string.format('%.1f%%', xr))
    XW:class('xph', 'wait', early)
    XW:rml('aah', early and 'gathering&#8230;' or string.format('%.2f', ar / 100))
    XW:class('aah', 'wait', early)
    local ttl, tw = 'gathering&#8230;', true
    if not early then if xr > 0.05 then ttl, tw = hm((100 - p) / xr * 3600000), false else ttl = 'no progress yet' end end
    XW:rml('ttl', ttl); XW:class('ttl', 'wait', tw)
    XW:text('ses', hm(C.now() - X.t0))
    XW:text('sesk', X.lost > 0 and string.format('Session (%d death skipped)', X.lost) or (X.xp > 0 and string.format('Session +%.1f%% lvl', X.xp) or 'Session time'))
end
local function draw_loot()
    if not LW or not LW.visible then return end
    LW:rml('tot', M.money(L.total))
    local early = C.now() - L.t0 < 60000
    LW:rml('rate', early and 'gathering&#8230;' or M.money_short(L.total / hrs(L.t0)))
    LW:class('rate', 'wait', early)
    LW:text('cnt', tostring(L.items))
    LW:text('cntk', L.unknown > 0 and string.format('Items (%d no value)', L.unknown) or 'Items looted')
    local pages = math.max(1, math.ceil(#L.hist / ROWS)); L.page = C.clamp(L.page, 1, pages)
    LW:text('pg', #L.hist == 0 and 'nothing yet' or string.format('page %d of %d', L.page, pages))
    LW:class('a-prev', 'dis', L.page <= 1); LW:class('a-next', 'dis', L.page >= pages)
    for i = 1, ROWS do
        local e = L.hist[(L.page - 1) * ROWS + i]
        local h = ''
        if e then
            h = string.format('<span class="ln">%s%s</span><span class="lv%s">%s</span>', e.cnt > 1 and ('<span class="lc">' .. e.cnt .. 'x</span>') or '', C.esc(e.name),
                e.unk and ' unk' or '', e.unk and 'value unknown' or M.money_short(e.v))
        elseif i == 1 then h = '<span class="ln dim">Your loot will show up here</span>' end
        LW:rml('lr' .. i, h)
        LW:class('lr' .. i, 'empty2', e == nil)
    end
end
local function on_xp(ev)
    if ev.type ~= 'click' then return end
    if ev.action == 'reset' then M.reset_xp(); M.poll(true)
    elseif ev.action == 'close' then C.cfg.xp = false; C.save_cfg(); M.vis() end
end
local function on_loot_ev(ev)
    if ev.type ~= 'click' then return end
    local a = ev.action
    if a == 'reset' then M.reset_loot()
    elseif a == 'prev' then L.page = L.page - 1
    elseif a == 'next' then L.page = L.page + 1
    elseif a == 'close' then C.cfg.loot = false; C.save_cfg(); M.vis(); return end
    draw_loot()
end
function M.vis()
    if XW then XW:show(C.cfg.xp) end
    if LW then LW:show(C.cfg.loot) end
    draw_xp(); draw_loot()
end
function M.open()
    local sw, sh = C.screen()
    M.reset_xp(); M.reset_loot()
    XW = C.open({ key = 'XP', doc = 'xp.rml', w = 290, h = 214, x = sw - 580, y = math.floor(sh * 0.62), on_event = on_xp, hidden = true })
    LW = C.open({ key = 'Loot', doc = 'loot.rml', w = 300, h = 452, x = sw - 600, y = math.floor(sh * 0.62) - 460, on_event = on_loot_ev, hidden = true })
    M.vis()
end
local nxt = 0
function M.poll(force)
    local now = C.now()
    if not force and now < nxt then return end
    nxt = now + 1000
    -- redraw when a value changed, otherwise refresh rates/clock every 15 s (rates drift slowly when idle)
    local slow = force or now >= (M.slow_t or 0)
    if slow then M.slow_t = now + 15000 end
    if C.cfg.xp then
        local l, p = lvl_now(), pct_now()
        local sig0 = (tostring(X.lvl) .. '|' .. tostring(X.pct) .. '|' .. tostring(X.aapts) .. '|' .. tostring(X.aapct))
        if l and p then M.sample_xp(l, p, aapts_now(), aapct_now()) end
        if slow or sig0 ~= (tostring(X.lvl) .. '|' .. tostring(X.pct) .. '|' .. tostring(X.aapts) .. '|' .. tostring(X.aapct)) then draw_xp() end
    end
    if C.cfg.loot then
        local i = 1
        while L.pending[i] do
            local e = L.pending[i]
            if now >= e.t then table.remove(L.pending, i); M.add_loot(e.name, e.cnt, lookup(e.name)); slow = true else i = i + 1 end
        end
        if slow then draw_loot() end
    end
end
M.X, M.L = X, L
return M
