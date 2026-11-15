--[[
  ProFusion wiki content API — navGroups() + getPage(id).
]]

local data
do
    local ok, mod = pcall(require, 'pfwiki.data_pages')
    if ok then
        data = mod
    else
        data = require('data_pages')
    end
end

local M = {}

local by_id = {}
for i = 1, #(data.pages or {}) do
    local p = data.pages[i]
    if p and p.id then
        by_id[p.id] = p
    end
end

function M.pageCount()
    return #(data.pages or {})
end

function M.navGroups()
    local groups = {}
    local order = data.section_order or {}
    local buckets = {}
    for i = 1, #(data.pages or {}) do
        local p = data.pages[i]
        local sec = p.section or 'Server'
        if not buckets[sec] then
            buckets[sec] = {}
        end
        buckets[sec][#buckets[sec] + 1] = {
            id = p.id,
            label = p.title or p.id,
        }
    end
    for i = 1, #order do
        local sec = order[i]
        local items = buckets[sec]
        if items and #items > 0 then
            groups[#groups + 1] = { title = sec, items = items }
            buckets[sec] = nil
        end
    end
    for sec, items in pairs(buckets) do
        if items and #items > 0 then
            groups[#groups + 1] = { title = sec, items = items }
        end
    end
    return groups
end

function M.getPage(id)
    local p = by_id[id]
    if not p then
        return { id = id, title = tostring(id or '?'), section = '', lines = { 'Page not found.' } }
    end
    return {
        id = p.id,
        title = p.title or p.id,
        section = p.section or '',
        url = p.url or '',
        lines = p.lines or {},
    }
end

function M.defaultPageId()
    if by_id.home then return 'home' end
    local p = data.pages and data.pages[1]
    return p and p.id or 'home'
end

return M
