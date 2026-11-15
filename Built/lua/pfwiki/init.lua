--[[
  ProFusion Wiki (RmlUi) — /lua run pfwiki
]]

local mq = require('mq')

local openGUI = true
local rml_ui = nil

do
    local ok, mod = pcall(require, 'pfwiki.rml_ui')
    if ok then
        rml_ui = mod
    else
        print('[ProFusion Wiki] Rml load failed: ' .. tostring(mod))
    end
end

if not rml_ui then
    print('[ProFusion Wiki] Aborting — rml_ui unavailable.')
    return
end

do
    local ok, content = pcall(require, 'pfwiki.content')
    if ok and content and content.getPage then
        local home = content.getPage('home')
        print(string.format('[ProFusion Wiki] home blocks=%d pages=%d',
            #(home.lines or {}), content.pageCount and content.pageCount() or 0))
    else
        print('[ProFusion Wiki] content load failed: ' .. tostring(content))
    end
end
print('[ProFusion Wiki] Starting. Close the window or /lua stop pfwiki to exit.')

mq.imgui.init('ProFusionWiki', function()
    if not openGUI then return end
    rml_ui.tick({
        set_open = function(v)
            openGUI = v ~= false
            if rml_ui then rml_ui.show(openGUI) end
        end,
    })
end)

while openGUI do
    mq.doevents()
    mq.delay(100)
end

if rml_ui then
    rml_ui.close()
end
