-- Hot bar windows: one RmlUi window per ButtonMaster window entry (plus the simulator's demo bar).
-- Drag: only #hdr (drag="1", no action on it or an ancestor) and the resize corner. Position comes from the plugin's
-- 'windowmoved' event (rml_get_window as a backup), is saved per character, and is applied ONCE at open.
-- Per frame: drain events, refresh at most a few buttons' Lua (time-sliced), diff-write state 10x/s, step effect
-- frames with ONE body class write per visible animated bar at the quality rate. Hidden bars do nothing.
local mq = require('mq')
local rmlui = require('rmlui')
local C = require('buttonmaster_rml.core')
local P = require('buttonmaster_rml.paint')
local S = require('buttonmaster_rml.sim')
local B = { list = {}, demo = nil, hooks = {}, close_q = {}, tickn = 0, reopen_at = nil, closing = {} }
local NB = 48
local QFPS = { low = 6, balanced = 10, high = 15 }
B.QFPS = QFPS

-- ---------------------------------------------------------------- plugin window rect (feature bit 256)
local wl, wl_tried
local function wlib()
    if wl_tried then return wl end
    wl_tried = true
    pcall(function()
        local ffi = require('ffi')
        pcall(ffi.cdef, 'int rml_features(void);')
        local l = ffi.load('MQ2RmlUi')
        if math.floor((tonumber(l.rml_features()) or 0) / 256) % 2 == 1 then pcall(ffi.cdef, 'const char* rml_get_window(const char* name);'); wl = { l = l, ffi = ffi } end
    end)
    return wl
end
local function parse_rect(v)
    local x, y, w, h = tostring(v or ''):match('(%-?[%d%.]+),(%-?[%d%.]+),?(%-?[%d%.]*),?(%-?[%d%.]*)')
    if x then return math.floor(tonumber(x)), math.floor(tonumber(y)), tonumber(w), tonumber(h) end
end
B.parse_rect = parse_rect
function B.get_rect(name)
    if _G.__bm_get_rect then return _G.__bm_get_rect(name) end
    local w = wlib(); if not w then return nil end
    local ok, s = pcall(function() local r = w.l.rml_get_window(name); if r ~= nil then return w.ffi.string(r) end end)
    if ok and s then return parse_rect(s) end
end
function B.screen()
    local ok, sz = pcall(function() return ImGui.GetIO().DisplaySize end)
    if ok and sz and sz.x and sz.x > 0 then return math.floor(sz.x), math.floor(sz.y) end
    return 1920, 1080
end

-- ---------------------------------------------------------------- bar object
local Bar = {}; Bar.__index = Bar
function Bar:cfg() if self.id == 'demo' then return B.demo_cfg end; return C.win(self.id) end
function Bar:rml() local c = self:cfg(); c.Rml = c.Rml or {}; return c.Rml end
function Bar:sets() return self.id == 'demo' and { 'Demo' } or (self:cfg().Sets or {}) end
function Bar:set_name()
    local sets = self:sets(); local r = self:rml()
    local t = r.Tab or 1
    if self:cfg().CompactMode then t = 1 end
    if t > #sets then t = math.max(1, #sets) end
    r.Tab = t
    return sets[t]
end
function Bar:button(i)
    if self.id == 'demo' then return S.demo_buttons()[i], nil end
    local set = self:set_name(); if not set then return nil end
    return C.button_at(set, i)
end
function Bar:size()
    local r = self:rml(); local c = self:cfg()
    return math.max(24, math.min(96, tonumber(r.Size) or math.floor((tonumber(c.ButtonSize) or 6) * 10 * 0.8)))
end
function Bar:geometry()
    local r, c = self:rml(), self:cfg()
    local sz = self:size(); local gap = tonumber(r.Gap) or 4
    if not r.Cols then                              -- first run: derive the grid from the ImGui window size ButtonMaster saved
        local w, h = tonumber(c.Width) or 0, tonumber(c.Height) or 0
        r.Cols = w > 0 and math.max(1, math.min(12, math.floor((w - 16) / (sz + 4)))) or 6
        r.Rows = h > 0 and math.max(1, math.min(8, math.floor((h - 60) / (sz + 4)))) or 2
        if self.id ~= 'demo' then C.save_soon() end
    end
    local cols = math.max(1, math.min(12, r.Cols)); local rows = math.max(1, math.min(8, r.Rows or 1))
    while cols * rows > NB do rows = rows - 1 end
    local under = false
    for i = 1, cols * rows do local b = self:button(i); if b and b.Rml and b.Rml.LabelPos == 'under' and b.ShowLabel ~= false then under = true; break end end
    local lh = under and 14 or 0
    local pad = math.max(6, math.floor(sz * 0.2))
    local top = c.HideTitleBar and 0 or 24
    local W = pad * 2 + cols * sz + (cols - 1) * gap
    local H = top + pad * 2 + rows * (sz + lh) + (rows - 1) * gap
    if not c.HideTitleBar then W = math.max(W, 150) end
    return { cols = cols, rows = rows, n = cols * rows, sz = sz, gap = gap, pad = pad, lh = lh, top = top, W = W, H = H }
end

function B.new(id)
    local self = setmetatable({ id = id, name = id == 'demo' and 'ButtonMasterRml_Demo' or ('ButtonMasterRml_' .. id), fr = 0, next_anim = 0, next_state = 0, prev = {}, flash = {}, slice = 1 }, Bar)
    return self
end
function Bar:open()
    local c = self:cfg(); local g = self:geometry()
    local sw, sh = B.screen()
    c.Pos = c.Pos or { x = 60, y = 60 }
    local x = math.max(-g.W + 60, math.min(sw - 60, tonumber(c.Pos.x) or 60)); local y = math.max(0, math.min(sh - 30, tonumber(c.Pos.y) or 60))
    local doc = 'buttonmaster_rml/ui/bar' .. (self.id == 'demo' and 9 or ((self.id - 1) % 8) + 1) .. '.rml'
    local W, err = rmlui.open(self.name, doc, { width = g.W, height = g.H, x = x, y = y, theme = false })
    if not W then C.out('RmlUi window failed: %s (is MQ2RmlUi loaded?)', tostring(err)); return false end
    self.W = W; self.D = P.dom(W)
    pcall(function() W:reload() end)
    pcall(function() W:place(x, y, g.W, g.H) end)        -- once, at open
    self.rect = { x, y, g.W, g.H }; self.geo_key = nil; self.look_key = {}
    self.shown = true
    self:apply_visible()
    return true
end
-- Closing a document is NEVER done from inside an event callback or in the same tick it is reopened.
-- retire() stops every write and event for the bar at once; the real close happens at the start of the
-- next main-loop tick (B.tick), and windows are only (re)opened at least one tick after that.
function Bar:retire()
    if self.dead then return end
    if self.W and self.shown then pcall(function() self:remember(B.get_rect(self.name)) end) end
    self.dead = true
    if self.D then self.D.dead = true; self.D.c = {} end
    self.prev, self.flash, self.look_key, self.geo_key = {}, {}, {}, nil
    B.close_q[#B.close_q + 1] = self
end
function Bar:close()             -- direct close: only for shutdown (B.close_all) and the deferred queue
    self.dead = true
    if self.D then self.D.dead = true; self.D.c = {} end
    local W = self.W; self.W = nil
    if W then pcall(function() W:close() end) end
end
function Bar:remember(x, y)
    if not x or self.id == 'demo' then return end
    local c = self:cfg(); if not c then return end                 -- bar was deleted: nothing to remember
    c.Pos = c.Pos or {}
    if c.Pos.x ~= x or c.Pos.y ~= y then c.Pos.x, c.Pos.y = x, y; C.save_soon() end
end
function Bar:visible() return self.W ~= nil and self.shown and not self.dead end
function Bar:apply_visible()
    local c = self:cfg(); if not c then return end
    local want; if self.id == 'demo' then want = B.demo_on == true else want = c.Visible ~= false end
    if want ~= self.shown then
        if not want then self:remember(B.get_rect(self.name)) end
        self.shown = want; pcall(function() self.W:show(want) end)
        if want then self.D:reset(); self.geo_key = nil; self.look_key = {} end
    end
end
function Bar:invalidate() self.look_key = {}; self.geo_key = nil end

-- layout: button boxes + window size; only when the geometry changes
function Bar:layout()
    local g = self:geometry(); local c = self:cfg(); local r = self:rml()
    local key = table.concat({ g.cols, g.rows, g.sz, g.gap, g.lh, g.top, tostring(c.HideTitleBar) }, ',')
    if key == self.geo_key then return g end
    self.geo_key = key; self.look_key = {}
    local D = self.D
    for i = 1, NB do
        local on = i <= g.n
        D:class('b' .. i, 'on', on)
        if on then
            local col = (i - 1) % g.cols; local row = math.floor((i - 1) / g.cols)
            D:style('b' .. i, 'left', (g.pad + col * (g.sz + g.gap)) .. 'px'); D:style('b' .. i, 'top', (g.pad + row * (g.sz + g.lh + g.gap)) .. 'px')
            D:style('b' .. i, 'width', g.sz .. 'px'); D:style('b' .. i, 'height', g.sz .. 'px')
        end
    end
    if self.rect and (self.rect[3] ~= g.W or self.rect[4] ~= g.H) then
        local x, y = B.get_rect(self.name); x = x or self.rect[1]; y = y or self.rect[2]
        self.rect = { x, y, g.W, g.H }
        pcall(function() self.W:place(x, y, g.W, g.H) end)       -- size change only (user changed the layout)
    end
    return g
end

function Bar:chrome()
    local c, r, D = self:cfg(), self:rml(), self.D
    D:class('body', 'locked', c.Locked); D:attr('hdr', 'drag', c.Locked and '0' or '1')
    D:class('block', 'on', c.Locked)
    D:class('body', 'notitle', c.HideTitleBar); D:class('body', 'compact', c.CompactMode)
    D:class('body', 'clear', C.settings.Rml.Clear); D:class('body', 'rfx', C.settings.Rml.Reduced)
    D:class('body', 'sim', S.active(self.id)); D:class('bsim', 'on', S.active(self.id))
    for _, t in ipairs({ 'forge', 'arcane', 'steel', 'ember', 'none' }) do D:class('body', 'th-' .. t, (r.Theme or 'forge') == t) end
    local sets = self:sets()
    D:text('title', P.esc(P.clip(r.Title or (self.id == 'demo' and 'Demo bar' or (#sets > 0 and (#sets == 1 or c.CompactMode) and sets[1]) or ('Bar ' .. self.id)), 22)))
    for i = 1, 8 do
        local s = sets[i]
        D:class('t' .. i, 'off', s == nil or #sets < 2 or c.CompactMode)
        if s then D:text('t' .. i, P.esc(P.clip(s, 10))); D:class('t' .. i, 'on', i == (r.Tab or 1)) end
    end
    D:class('body', 'noset', #sets == 0)
end

local function tipfor(b, adv)
    local t = C.label(b)
    if adv and b.Cmd and b.Cmd ~= '' then t = t .. '\n' .. P.clip(tostring(b.Cmd):gsub('\n', ' | '), 120) end
    return t
end
-- full refresh of looks (diffed); cheap and only when something changed (look_key per slot)
function Bar:looks(g)
    local c = self:cfg(); local adv = c.AdvTooltips ~= false
    for i = 1, g.n do
        local b = self:button(i)
        local key = b and (tostring(b) .. (b.CachedLabel or '') .. tostring(b.Rml and b.Rml._v or 0) .. tostring(b.Icon) .. tostring(b.CachedIcon)) or 'e'
        if self.look_key[i] ~= key then
            self.look_key[i] = key
            P.look(self.D, '', i, b, { size = g.sz, label = b and C.label(b) or nil, tip = b and tipfor(b, adv) or nil, empty = tostring(i) })
        end
    end
end
function Bar:any_anim(g)
    if C.settings.Rml.Reduced then return false end
    for i = 1, g.n do if C.fx_animated(self:button(i)) then return true end end
    return false
end

-- one Lua refresh slice per frame per bar (labels/icons/timers/conditions), time-capped by the caller
function Bar:refresh_some(g, budget_end)
    if S.active(self.id) or self.id == 'demo' then return end
    local n = g.n; if n == 0 then return end
    local fps = tonumber(self:cfg().FPS) or 0
    local tries = 0
    while tries < n do
        if os.clock() > budget_end then return end
        local i = self.slice; self.slice = (i % n) + 1; tries = tries + 1
        local b = self:button(i)
        if b and (fps <= 0 or not b._bar_ran or C.now() - b._bar_ran >= fps / 10) and C.due(b) then
            b._bar_ran = C.now()
            local ol, oi = b.CachedLabel, b.CachedIcon
            C.label(b, true); C.icon(b, true); C.cooldown(b, true); C.cond(b, true)
            if ol ~= b.CachedLabel or oi ~= b.CachedIcon then self.look_key[i] = nil end
        end
    end
end
function Bar:states(g, t)
    local sim = S.active(self.id)
    for i = 1, g.n do
        local b = self:button(i)
        local st
        if not b then st = { cd = 0, tot = 0 }
        elseif sim then st = S.state(i)
        else
            local cd, tot, lock = b.CachedCountDown or 0, b.CachedCoolDownTimer or 0, b.CachedToggleLocked
            if cd > 0 and b.CachedLastRan then cd = math.max(0, cd - (C.now() - b.CachedLastRan)) end
            st = { cd = cd, tot = tot, lock = lock, cond = b.CachedCond }
            -- ready flash (one-shot, 450 ms) when a cooldown ends
            local oncd = cd > 0 and tot > 0
            if self.prev[i] and not oncd then self.flash[i] = t end
            self.prev[i] = oncd
            if self.flash[i] then local f = 1 - (t - self.flash[i]) / 450; if f <= 0 then self.flash[i] = nil; f = 0 end; st.flash = f end
        end
        if b and not (b.Rml and b.Rml.Fx and b.Rml.Fx.flash and b.Rml.Fx.flash.On) then st.flash = 0 end
        P.state(self.D, '', i, st)
    end
end

function Bar:frame(t, budget_end)
    if not self.W then return end
    for ev in self.W:events() do if self.dead or not self.W then break end; self:on_event(ev) end
    if self.dead or not self.W then return end
    self:apply_visible()
    if not self.shown then return end
    local g = self:layout()
    if S.active(self.id) then S.tick(t / 1000, g.n, function(i) return (self:button(i)) end) end
    self:refresh_some(g, budget_end)
    local sim = S.active(self.id)
    if t >= self.next_state or sim then
        self.next_state = t + 100
        self:chrome(); self:looks(g); self:states(g, t)
    end
    -- effect animation: one class write per step, only while some visible button animates
    if t >= self.next_anim then
        local fps = QFPS[C.settings.Rml.Quality] or 10
        self.next_anim = t + math.floor(1000 / fps)
        if self:any_anim(g) then
            local f = (self.fr + 1) % 8
            self.D:class('body', 'f' .. self.fr, false); self.D:class('body', 'f' .. f, true); self.fr = f
        end
    end
end

function Bar:on_event(ev)
    if self.dead or not self.W then return end                         -- events for a retired/closed window are ignored
    if ev.type == 'windowmoved' then
        local kind = tostring(ev.value or ''):match('^(%a+)')
        local x, y, w, h = parse_rect(ev.value)
        if x then
            self:remember(x, y)
            if self.rect then self.rect[1], self.rect[2] = x, y end
            if kind == 'resize' and w and h and self.rect then           -- resize corner: re-flow columns/rows
                local g = self:geometry(); local r = self:rml()
                local cols = math.max(1, math.min(12, math.floor((w - g.pad * 2 + g.gap) / (g.sz + g.gap))))
                local rows = math.max(1, math.min(8, math.floor((h - g.top - g.pad * 2 + g.gap) / (g.sz + g.lh + g.gap))))
                self.rect[3], self.rect[4] = w, h
                if cols ~= r.Cols or rows ~= r.Rows then r.Cols, r.Rows = cols, rows; C.save_soon() end
                self.geo_key = nil
            end
        end
        return
    end
    local a = ev.action or ''
    local btn = tonumber(ev.button) or 0
    local i = tonumber(a:match('^b:(%d+)$'))
    if ev.type == 'mousedown' and btn == 1 then                     -- right-click: edit this slot
        if i and self.id ~= 'demo' then B.hooks.edit(self.id, self:set_name(), i) end
        return
    end
    if ev.type ~= 'click' or btn ~= 0 then return end
    if i then
        local b = self:button(i)
        if S.active(self.id) then S.press(i, b); return end            -- simulator: never runs commands
        if self.id == 'demo' then return end
        if b then C.exec(b)
        else B.hooks.edit(self.id, self:set_name(), i, true) end        -- empty slot: create (from cursor when holding something)
        return
    end
    local k = tonumber(a:match('^tab:(%d+)$'))
    if k then self:rml().Tab = k; self.look_key = {}; self.geo_key = nil; C.save_soon(); return end
    if a == 'lock' then local c = self:cfg(); c.Locked = not c.Locked; C.save(true)
    elseif a == 'menu' then B.hooks.menu(self.id)
    elseif a == 'sim' then B.hooks.sim(self.id) end
end
B.Bar = Bar

-- ---------------------------------------------------------------- collection
function B.sync()
    if B.reopen_at then return end                              -- a close is still settling; B.tick opens later
    local wins = C.char().Windows
    for id = 1, math.max(#wins, #B.list) do
        local bar = B.list[id]
        if wins[id] and not bar then
            if B.closing['ButtonMasterRml_' .. id] then B.reopen_at = B.tickn + 2
            else bar = B.new(id); B.list[id] = bar; bar:open() end
        elseif not wins[id] and bar then bar:retire(); B.list[id] = nil; B.reopen_at = B.reopen_at or (B.tickn + 2) end
    end
end
-- request a rebuild of some bars (ids) or all of them (nil): safe to call from any event handler
function B.request_reopen(ids)
    if ids then for _, id in ipairs(ids) do local b = B.list[id]; if b then b:retire(); B.list[id] = nil end end
    else for id, b in pairs(B.list) do b:retire(); B.list[id] = nil end end
    B.reopen_at = B.tickn + 2
end
B.reopen_all = function() B.request_reopen(nil) end
-- add/remove bars on the next tick (never open or close from inside an event callback)
function B.request_sync() B.reopen_at = B.reopen_at or (B.tickn + 1) end
-- start of every main-loop tick, before any window polls events: close retired docs, then reopen later
function B.tick()
    B.tickn = B.tickn + 1
    if #B.close_q > 0 then
        local q = B.close_q; B.close_q = {}
        for _, bar in ipairs(q) do B.closing[bar.name] = B.tickn; bar:close() end
        if B.reopen_at and B.reopen_at <= B.tickn then B.reopen_at = B.tickn + 1 end
        return
    end
    if B.reopen_at and B.tickn >= B.reopen_at then
        B.reopen_at = nil; B.closing = {}
        B.sync()
    end
end
function B.demo_show(on)
    B.demo_on = on
    if on and not B.demo then
        B.demo_cfg = B.demo_cfg or { Visible = true, Pos = { x = 420, y = 220 }, Sets = { 'Demo' }, Rml = { Cols = 6, Rows = 2, Size = 52, Gap = 8, Title = 'Simulator demo bar' } }
        B.demo = B.new('demo'); B.demo:open()
    end
end
function B.frame(t)
    local budget_end = os.clock() + 0.0015                    -- 1.5 ms of Lua timer/label work per frame, all bars together
    for _, bar in pairs(B.list) do if not bar.dead then bar:frame(t, budget_end) end end
    if B.demo and not B.demo.dead then B.demo:frame(t, budget_end) end
end
function B.close_all() for _, bar in ipairs(B.close_q) do bar:close() end; B.close_q = {}; for _, bar in pairs(B.list) do bar:close() end; if B.demo then B.demo:close() end end
function B.count_anim()
    local nb, nv = 0, 0
    for _, bar in pairs(B.list) do
        if bar:visible() then nv = nv + 1; local g = bar:geometry(); for i = 1, g.n do if C.fx_animated(bar:button(i)) then nb = nb + 1 end end end
    end
    return nb, nv
end
return B
