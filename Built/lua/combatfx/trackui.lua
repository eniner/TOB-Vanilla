-- combatfx/trackui.lua (f10): HTML for the on-screen Tracking panel and the read-only tables of the Tracking tab.
-- No actions here (ui.lua owns buttons); everything is escaped; the panel keeps a fixed row height so its box is exact.
local C = require('combatfx.core')
local U = {}
local e, f = C.esc, C.fmt
local function secs_txt(s)
    s = math.max(0, math.floor(s + 0.5))
    if s >= 3600 then return string.format('%dh%02d', math.floor(s / 3600), math.floor(s % 3600 / 60)) end
    if s >= 60 then return string.format('%dm%02d', math.floor(s / 60), s % 60) end
    return s .. 's'
end
U.secs_txt = secs_txt
local function trunc(s, n) s = tostring(s or ''); if #s <= n then return s end; return s:sub(1, n - 1) .. '..' end
U.trunc = trunc
local function bar_row(name, frac, color, val, warn)
    return string.format('<div class="tkr%s"><span class="tkn">%s</span><div class="tkb"><div class="tkf" style="width: %d%%; background-color: %s;"></div></div><span class="tkv">%s</span></div>',
        warn and ' warn' or '', e(trunc(name, 22)), math.max(2, math.min(100, math.floor(frac * 100 + 0.5))), color, val)
end
-- data = { dots, buffs, pet, fd, hint, tname, warn, nbuffs, title }
function U.panel_from(d)
    local h, rows = {}, 0
    local function head(t, dim) h[#h + 1] = '<span class="tkh">' .. t .. (dim and (' <span class="dim">' .. dim .. '</span>') or '') .. '</span>'; rows = rows + 1 end
    if d.title then head(d.title) end
    if #d.dots > 0 then
        head('YOUR DOTS', d.tname ~= '' and ('&#183; ' .. e(trunc(d.tname, 20))) or nil)
        for i = 1, math.min(6, #d.dots) do
            local x = d.dots[i]
            local tot = (x.total and x.total > 0) and x.total * 6 or math.max(x.left, 18)
            local est = x.src == 'est' and '~' or ''
            h[#h + 1] = bar_row(x.sp, x.left / math.max(1, tot), '#c8a0ff', est .. secs_txt(x.left), x.left <= d.warn); rows = rows + 1
        end
        if d.others and d.others > 0 then h[#h + 1] = string.format('<span class="tkx">+%d running on other mobs</span>', d.others); rows = rows + 0.93 end
    end
    if #d.buffs > 0 then
        head('BUFFS FADING')
        for i = 1, math.min(d.nbuffs or 5, #d.buffs) do
            local b = d.buffs[i]
            h[#h + 1] = bar_row(b.name, b.left / math.max(1, b.max), b.song and '#8ac8ff' or '#6aff8a', secs_txt(b.left), b.left <= (d.bwarn or 15)); rows = rows + 1
        end
    end
    if d.pet and d.pet.total > 0 then
        head('PET', string.format('&#183; %s &#183; %d%% of your damage', f(d.pet.total), math.floor(d.pet.share + 0.5)))
        h[#h + 1] = bar_row('melee', d.pet.melee / d.pet.total, '#ff8a8a', f(d.pet.melee)); rows = rows + 1
        if d.pet.spell > 0 then h[#h + 1] = bar_row('spells / procs', d.pet.spell / d.pet.total, '#ffb347', f(d.pet.spell)); rows = rows + 1 end
    end
    if d.fd then h[#h + 1] = string.format('<span class="tkx" style="color: %s;">%s</span>', d.fd.ok and '#6aff8a' or '#ff6050', e(d.fd.txt)); rows = rows + 0.93 end
    if d.hint then h[#h + 1] = '<span class="tkx" style="color: #ffc35a;">EQ log off: type /log on (optional)</span>'; rows = rows + 0.93 end
    if rows == 0 then return nil end
    return table.concat(h), math.floor(12 + rows * 15 + 0.5)
end
function U.collect(TK, now)
    local tn = TK.target_name()
    local all = TK.dot_rows(now)
    local dots, others = {}, 0
    for _, x in ipairs(all) do if tn ~= '' and x.tgt:lower() == tn:lower() then dots[#dots + 1] = x else others = others + 1 end end
    if tn == '' then dots, others = all, 0 end
    local thr = 15
    local FT = package.loaded['combatfx.features']
    if FT and FT.buff_threshold then thr = FT.buff_threshold() end
    local buffs = {}
    for _, b in ipairs(TK.buffs) do if b.max >= 60 and b.left <= math.max(thr * 4, 90) then buffs[#buffs + 1] = b end end
    local pet
    local F = TK.fight()
    if TK.cfg().pet and F then
        local p = F.pet
        local tot = p.melee[1] + p.spell[1] + p.ds[1]
        local FTs = FT and FT.stats and FT.stats()
        local mine = 0
        if FTs and FTs.out then for k, v in pairs(FTs.out) do if k ~= 'pet' then mine = mine + (v[1] or 0) end end end
        pet = { total = tot, melee = p.melee[1], spell = p.spell[1] + p.ds[1], share = (tot + mine) > 0 and tot / (tot + mine) * 100 or 0 }
    end
    local fd
    if TK.fd.last and now - TK.fd.last.t < 8000 then fd = { ok = TK.fd.last.ok, txt = (TK.fd.last.ok and 'Feigned' or 'Feign failed') .. ' &#183; ' .. tostring(TK.fd.last.sub or '') } end
    if fd then fd.txt = fd.txt:gsub('&#183;', '-') end
    return { dots = TK.cfg().dots and dots or {}, others = TK.cfg().dots and others or 0, buffs = buffs, pet = pet, fd = fd, hint = TK.cfg().loghint and TK.log_hint() ~= nil,
        tname = tn, warn = tonumber(TK.cfg().dot_warn) or 4, nbuffs = tonumber(TK.cfg().pbuffs) or 5, bwarn = thr }
end
function U.panel_html(TK, now)
    return U.panel_from(U.collect(TK, now))
end

-- ---------------------------------------------------------------- Tracking tab tables (read-only rows; ui.lua adds the controls)
local function lrow(left, right, cls) return string.format('<div class="lrow%s"><span class="ln">%s</span><span class="lv">%s</span></div>', cls and (' ' .. cls) or '', left, right) end
U.lrow = lrow
local function pct_cls(p) if p >= 30 then return 'wn' elseif p >= 10 then return 'dim' end; return 'ok' end
function U.taken_html(rows, T)
    local h = {}
    if #rows == 0 then return '<div class="empty">Nothing has hit you yet this session</div>' end
    local avs = {}
    for _, k in ipairs({ 'miss', 'dodge', 'parry', 'block', 'riposte', 'rune', 'invuln' }) do if (T.avoid or {})[k] then avs[#avs + 1] = T.avoid[k] .. ' ' .. k end end
    h[#h + 1] = lrow('<span class="lc">Total</span>' .. f(T.tk.n) .. ' in ' .. T.tk.hits .. ' hits', (#avs > 0 and table.concat(avs, ', ') or 'nothing avoided') .. ((T.absorbed or 0) > 0 and (' &#183; spellshield ' .. f(T.absorbed)) or ''))
    for _, r in ipairs(rows) do
        local ab = {}
        for j = 1, math.min(3, #r.ab) do local a = r.ab[j]; ab[#ab + 1] = string.format('%s %s', e(trunc(a[1], 22)), f(a[2])) end
        local av = r.avn > 0 and string.format(' &#183; <span class="ok">%d avoided</span>', r.avn) or ''
        h[#h + 1] = lrow(string.format('<span class="lc">%d%%</span>%s &#183; <span class="dim">%s</span>%s', math.floor(r.share + 0.5), e(trunc(r.who, 26)), table.concat(ab, ', '), av), f(r.n) .. ' / max ' .. f(r.max))
    end
    return table.concat(h)
end
function U.resist_html(rows, kind)
    if #rows == 0 then return '<div class="empty">' .. (kind == 'mob' and 'No mob has resisted or taken a spell of yours yet' or 'No resistable casts counted yet') .. '</div>' end
    local h = {}
    for _, r in ipairs(rows) do
        local extra = ''
        if kind == 'mob' and r[6] then
            local w; for sp, x in pairs(r[6]) do if x.res > 0 and (not w or x.res > w[2]) then w = { sp, x.res } end end
            if w then extra = ' &#183; <span class="dim">most resisted: ' .. e(trunc(w[1], 20)) .. '</span>' end
        end
        h[#h + 1] = lrow(string.format('<span class="lc %s">%d%%</span>%s%s', pct_cls(r[4]), math.floor(r[4] + 0.5), e(trunc(r[1], 30)), extra), string.format('%d resisted / %d', r[3], r[5]))
    end
    return table.concat(h)
end
function U.eff_html(rows, db)
    if #rows == 0 then return '<div class="empty">No damage spells cast yet this session</div>' end
    local h = {}
    for i, r in ipairs(rows) do
        if i > 12 then break end
        local right = r.dpm and string.format('%.1f dmg / mana', r.dpm) or (r.endur and r.endur > 0 and string.format('%s dmg / %d end', f(r.per), r.endur) or 'mana ?')
        h[#h + 1] = lrow(string.format('<span class="lc">%dx</span>%s &#183; <span class="dim">%s each &#183; %s mana%s</span>', r.casts, e(trunc(r.sp, 28)), f(r.per), r.mana and tostring(r.mana) or '?', r.src == 'Spell TLO' and ' (TLO)' or ''), right)
    end
    return table.concat(h)
end
function U.session_html(r)
    local h = {}
    local mins = r.mins
    h[#h + 1] = lrow('<span class="lc">Session</span>' .. secs_txt(mins * 60), string.format('%d kills &#183; %.1f / h', r.kills, r.kph))
    h[#h + 1] = lrow('<span class="lc">XP</span>' .. string.format('%.2f%% of a level', r.xp) .. ' <span class="dim">(' .. r.xp_src .. ')</span>', string.format('%.2f%% / h', r.xph))
    if r.ttl then h[#h + 1] = lrow('<span class="lc">To level</span>' .. (r.lvl and ('level ' .. (r.lvl + 1)) or ''), secs_txt(r.ttl * 60)) end
    h[#h + 1] = lrow('<span class="lc">AA</span>' .. string.format('%.2f%% AA exp &#183; %d points', r.aa, r.aapts), string.format('%.2f%% / h', r.aah))
    -- plain text coins (the tracker's coin icons are sized for its own window)
    local function money(cp)
        cp = math.floor(cp or 0)
        local pp, gp = math.floor(cp / 1000), math.floor(cp % 1000 / 100)
        if pp >= 100 then return f(pp) .. ' pp' end
        if pp > 0 then return pp .. ' pp ' .. gp .. ' gp' end
        return gp .. ' gp ' .. math.floor(cp % 100 / 10) .. ' sp'
    end
    h[#h + 1] = lrow('<span class="lc">Coin</span>' .. money(math.floor(r.coin)) .. (r.reward > 0 and (' <span class="dim">+ ' .. money(r.reward) .. ' quest</span>') or ''), money(math.floor(r.cph)) .. ' / h')
    h[#h + 1] = lrow('<span class="lc">Loot</span>' .. r.items .. ' items' .. (r.lval and (' &#183; worth ' .. money(math.floor(r.lval))) or ''), string.format('%.1f / h', r.iph) .. (r.lvph and (' &#183; ' .. money(math.floor(r.lvph)) .. ' / h') or ''))
    if r.deaths > 0 then h[#h + 1] = lrow('<span class="lc wn">Deaths</span>' .. r.deaths, '') end
    return table.concat(h)
end
function U.dots_html(rows, per)
    local h = {}
    if #rows == 0 then h[#h + 1] = '<div class="empty">No DoTs of yours running</div>' end
    for _, x in ipairs(rows) do
        h[#h + 1] = lrow(string.format('<span class="lc">%s%s</span>%s &#183; <span class="dim">%s</span>', x.src == 'est' and '~' or '', secs_txt(x.left), e(trunc(x.sp, 26)), e(trunc(x.tgt, 22))), string.format('%d ticks &#183; %s', x.ticks, f(x.dmg)))
    end
    return table.concat(h)
end
function U.dotsplit_html(dots)
    local list = {}
    for sp, x in pairs(dots or {}) do list[#list + 1] = { sp, x } end
    table.sort(list, function(a, b) return a[2].n > b[2].n end)
    if #list == 0 then return '<div class="empty">No DoT ticks in this fight</div>' end
    local tot = 0; for _, x in ipairs(list) do tot = tot + x[2].n end
    local h = {}
    for _, x in ipairs(list) do
        local d = x[2]
        h[#h + 1] = lrow(string.format('<span class="lc">%d%%</span>%s &#183; <span class="dim">%d ticks, avg %s, max %s%s</span>', math.floor(d.n / math.max(1, tot) * 100 + 0.5), e(trunc(x[1], 26)), d.ticks, f(d.n / math.max(1, d.ticks)), f(d.max), d.crits > 0 and (', ' .. d.crits .. ' crit') or ''), f(d.n))
    end
    return table.concat(h)
end
return U
