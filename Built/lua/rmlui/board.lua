--[[
  Thin Rml command board for large ImGui tools.
  Primary actions become Rml buttons; optional body HTML for live status.
]]

local mq = require('mq')
local host = require('rmlui.host')

local M = {}

function M.attach(opts)
    opts = opts or {}
    local name = opts.name or 'RmlBoard'
    local win, err = host.open(name, opts.rml or 'rmlui/board.rml', {
        width = opts.width or 520,
        height = opts.height or 360,
        theme = opts.theme or 'redguides',
        autoclose = opts.autoclose == true,
    })
    if not win then
        print('[' .. name .. '] Rml board failed: ' .. tostring(err))
        return nil
    end
    win:text('title', opts.title or name)
    win:text('window-title', opts.title or name)
    win:text('hint', opts.hint or '')
    local parts = {}
    for _, b in ipairs(opts.buttons or {}) do
        parts[#parts + 1] = string.format(
            '<div class="btn%s" action="%s">%s</div>',
            b.primary and ' primary' or '', host.esc(b.id), host.esc(b.label))
    end
    win:rml('buttons', table.concat(parts))

    local board = { win = win, visible = true, status = '' }

    function board.show(v)
        board.visible = v ~= false
        win:show(board.visible)
    end

    function board.close()
        win:close()
    end

    function board.tick()
        if not board.visible then return end
        host.tick(win, {
            close = function()
                if opts.on_close then opts.on_close() else board.show(false) end
            end,
            action = function(a)
                for _, b in ipairs(opts.buttons or {}) do
                    if b.id == a then
                        if b.fn then pcall(b.fn)
                        elseif b.cmd then mq.cmd(b.cmd) end
                        board.status = b.label
                        break
                    end
                end
            end,
            update = function(w)
                if opts.body then
                    local html = opts.body()
                    if html and html ~= board._body then
                        board._body = html
                        w:rml('body', html)
                    end
                end
                w:text('status', board.status)
            end,
        })
    end

    return board
end

return M
