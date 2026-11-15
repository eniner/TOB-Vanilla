--[[
  Shared RmlUi host for MQ Lua tools.

  Tick from mq.imgui.init — never the delay loop.
  Clicks only fire when ev.action is set (or a handler maps a known id).
]]

local mq = require('mq')
local rmlui = require('rmlui')

local M = {}

function M.esc(s)
    return tostring(s or ''):gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'):gsub('"', '&quot;')
end

--- Visual glass (body.see-through). Not click-through.
local function apply_glass(win)
    if not win then return end
    local on = win._glass == true
    pcall(function()
        win:class('body', 'see-through', on)
        win:class('window-glass', 'on', on)
        win:class('btn_glass', 'on', on)
    end)
end

function M.set_glass(win, on)
    if not win then return false end
    win._glass = on == true
    apply_glass(win)
    return win._glass
end

function M.toggle_glass(win)
    if not win then return false end
    return M.set_glass(win, not win._glass)
end

function M.open(name, path, opts)
    opts = opts or {}
    local win, err = rmlui.open(name, path, {
        width = opts.width or 640,
        height = opts.height or 520,
        autoclose = opts.autoclose == true,
    })
    if not win then
        return nil, err
    end
    -- rml_open reuses a cached document when the path matches — reload so
    -- theme/RCSS/logo edits on disk actually show up.
    if opts.reload ~= false then
        pcall(function() win:reload() end)
    end
    win:theme(opts.theme or 'redguides')
    if opts.title then
        win:text('window-title', opts.title)
    end
    -- Ports are always resizable (corner grip). Pin must never be left on by default —
    -- pin only locks move; resize stays available in the plugin.
    win:class('body', 'pinned', false)
    -- AutoPort / host.open windows get a titlebar see-through toggle by default.
    if opts.glass_toggle ~= false then
        win:class('body', 'has-glass', true)
    end
    win._glass = opts.glass == true or opts.see_through == true
    apply_glass(win)
    pcall(function() win:show(true) end)
    -- Visible default placement so a broken/transparent doc can't sit as an invisible blocker
    pcall(function()
        win:place(opts.x or 160, opts.y or 100, opts.width or 900, opts.height or 720)
    end)
    return win
end

function M.tick(win, handlers)
    handlers = handlers or {}
    if not win then return false end
    if not win:is_open() then
        if handlers.closed then handlers.closed() end
        return false
    end
    for ev in win:events() do
        local typ = ev.type or ''
        if typ == 'click' or typ == 'dblclick' then
            local action = ev.action or ''
            if action == 'window:close' then
                if handlers.close then pcall(handlers.close, ev) end
            elseif action == 'ui:glass' then
                M.toggle_glass(win)
                if handlers.glass then pcall(handlers.glass, win._glass == true) end
            elseif action ~= '' and action:sub(1, 7) ~= 'window:' then
                if handlers[action] then
                    local ok, err = pcall(handlers[action], ev)
                    if not ok then print('[Rml] action ' .. action .. ': ' .. tostring(err)) end
                elseif handlers.action then
                    local ok, err = pcall(handlers.action, action, ev)
                    if not ok then print('[Rml] action: ' .. tostring(err)) end
                end
            end
        elseif typ == 'change' or typ == 'submit' then
            if handlers.change then pcall(handlers.change, ev) end
        end
    end
    if handlers.update then
        local ok, err = pcall(handlers.update, win)
        if not ok then print('[Rml] update: ' .. tostring(err)) end
    end
    apply_glass(win)
    return true
end

function M.bind_loop(imgui_name, on_frame, running_fn)
    mq.imgui.init(imgui_name, function()
        local ok, err = pcall(on_frame)
        if not ok then print('[' .. imgui_name .. '] ' .. tostring(err)) end
    end)
    while running_fn() do
        mq.doevents()
        mq.delay(50)
    end
    pcall(function() mq.imgui.destroy(imgui_name) end)
end

return M
