local _, ns = ...

local floor, ceil, max, format = math.floor, math.ceil, math.max, string.format

local SECTIONS = {
    { name = "Character", cards = { "Time recorded", "Experience", "Rested bonus XP", "Deaths", "Spells learned",
        "Buffs gained", "Screenshots" } },
    { name = "Combat", cards = { "Kills", "Killing blows", "Casts", "Damage done", "Healing done", "Damage taken",
        "Interrupts", "Time in combat", "Dungeons", "Bosses", "Duels won", "Duels lost", "Honorable kills",
        "Flagged for PvP" } },
    { name = "Travel and time", travel = true, cards = { "Distance", "Steps", "Jumps", "Walking", "Flying", "AFK",
        "Casting", "At camp", "Time underwater" } },
    { name = "Quests and world", cards = { "Quests", "Quests abandoned", "Places discovered", "NPCs talked to",
        "Camps" } },
    { name = "Crafting and loot", cards = { "Items looted", "Items sold", "Gold earned", "Gold spent", "Repairs" } },
    { name = "People", people = true, cards = { "Players grouped with", "Emotes", "Said \"lol\"", "Said \"rip\"" } },
}

local TILE_W, TILE_H, COLS = 164, 62, 4
local LIST_X, LIST_W = 338, 318
local BAR_X, BAR_W, BAR_ROW = 116, 540, 40
local MATE_ROWS, MATE_ROW_H = 6, 24
local SLOW_SECONDS, WHEEL_STEP, HEADING_H, GAP = 2, 62, 34, 28

local function IsZero(text)
    return text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):match("^0%D*$") ~= nil
end

function ns.StatsPage(parent, ui)
    local T, Text, Hair = ui.T, ui.Text, ui.Hair
    local Duration = ui.Duration

    local byLabel = {}
    for _, list in ipairs(ui.Cards) do
        for _, def in ipairs(list) do byLabel[def[1]] = def end
    end

    local BARS = {
        { label = "Travel", colors = { T.accent, T.s2, T.s3, T.s4, T.gold, T.rest }, rows = {
            { "On foot", function(s) return s.footTime + s.walkTime end },
            { "Mounted", function(s) return s.mountTime end },
            { "Swimming", function(s) return s.swimTime end },
            { "Flying", function(s) return s.flyTime end },
            { "Flight paths", function(s) return s.taxiTime end },
            { "Standing still", function(s) return s.stillTime end } } },
        { label = "Combat", colors = { T.accent, T.rest }, rows = {
            { "In combat", function(s) return s.combat end },
            { "Out of combat", function(s) return max(0, s.tracked - s.combat) end } } },
        { label = "Rested", colors = { T.accent, T.rest }, rows = {
            { "Rested", function(s) return s.restedTime end },
            { "Not rested", function(s) return s.unrestedTime end } } },
        { label = "Group", colors = { T.accent, T.rest }, rows = {
            { "In a group", function(s) return s.groupTime end },
            { "Solo", function(s) return s.soloTime end } } },
    }

    local page = CreateFrame("Frame", nil, parent)
    page:SetAllPoints()

    local scroll = CreateFrame("ScrollFrame", nil, page)
    scroll:SetPoint("TOPLEFT", 0, -30)
    scroll:SetPoint("BOTTOMRIGHT")
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(TILE_W * COLS, 1)
    scroll:SetScrollChild(child)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local top = max(0, child:GetHeight() - self:GetHeight())
        self:SetVerticalScroll(math.min(top, max(0, self:GetVerticalScroll() - delta * WHEEL_STEP)))
    end)

    local sections, offsets = {}, {}
    local linkX = 0
    for i, def in ipairs(SECTIONS) do
        local sec = { def = def, tiles = {}, on = {}, texts = {} }
        sections[i] = sec
        sec.title = Text(child, 19, T.fg, "LEFT", "display")
        sec.title:SetText(def.name)
        sec.empty = Text(child, 13, T.muted)
        sec.empty:SetText("Nothing recorded yet")
        for k = 1, #def.cards do
            local tile = ui.Tile(child, TILE_W, TILE_H)
            tile:Hide()
            sec.tiles[k] = tile
            sec.on[k] = false
        end
        if def.travel then
            sec.bars = {}
            for b, bar in ipairs(BARS) do
                local row = { def = bar, on = false, items = {}, list = {} }
                row.label = Text(child, 13, T.muted)
                row.label:SetText(bar.label)
                row.stack = ui.Stack(child, BAR_W, 6)
                row.label:Hide()
                row.stack:Hide()
                for r, spec in ipairs(bar.rows) do
                    row.items[r] = { label = spec[1], value = 0, color = bar.colors[r], text = "" }
                end
                sec.bars[b] = row
            end
        end
        if def.people then
            sec.listTitle = Text(child, 19, T.fg, "LEFT", "display")
            sec.listTitle:SetText("Grouped with most")
            sec.listTitle:Hide()
            sec.rows = {}
            for r = 1, MATE_ROWS do
                local row = CreateFrame("Frame", nil, child)
                row:SetSize(LIST_W, MATE_ROW_H)
                Hair(row, "BOTTOM")
                row.name = Text(row, 14, T.fg)
                row.name:SetPoint("LEFT")
                row.name:SetPoint("RIGHT", -150, 0)
                row.value = Text(row, 13, T.text, "RIGHT")
                row.value:SetPoint("RIGHT")
                row:Hide()
                sec.rows[r] = row
            end
            sec.shownRows = 0
        end

        local link = CreateFrame("Button", nil, page)
        local text = Text(link, 13, T.muted)
        text:SetPoint("LEFT")
        text:SetText(def.name)
        local width = (text:GetStringWidth() or 60) + 2
        link:SetSize(width, 20)
        link:SetPoint("TOPLEFT", linkX, 0)
        linkX = linkX + width + 22
        link:SetScript("OnClick", function()
            local top = max(0, child:GetHeight() - scroll:GetHeight())
            scroll:SetVerticalScroll(math.min(top, offsets[i] or 0))
        end)
        link:SetScript("OnEnter", function() text:SetTextColor(T.fg[1], T.fg[2], T.fg[3]) end)
        link:SetScript("OnLeave", function() text:SetTextColor(T.muted[1], T.muted[2], T.muted[3]) end)
    end

    local function Layout()
        local y = 0
        for i, sec in ipairs(sections) do
            offsets[i] = y
            sec.title:ClearAllPoints()
            sec.title:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
            y = y + HEADING_H
            local any = false
            if sec.bars then
                local n = 0
                for _, row in ipairs(sec.bars) do
                    row.label:SetShown(row.on)
                    row.stack:SetShown(row.on)
                    if row.on then
                        any = true
                        row.label:ClearAllPoints()
                        row.label:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -(y + n * BAR_ROW))
                        row.stack:ClearAllPoints()
                        row.stack:SetPoint("TOPLEFT", child, "TOPLEFT", BAR_X, -(y + n * BAR_ROW))
                        n = n + 1
                    end
                end
                y = y + n * BAR_ROW
            end
            local cols = sec.def.people and 2 or COLS
            local n = 0
            for k, tile in ipairs(sec.tiles) do
                tile:SetShown(sec.on[k])
                if sec.on[k] then
                    tile:ClearAllPoints()
                    tile:SetPoint("TOPLEFT", child, "TOPLEFT", (n % cols) * TILE_W, -(y + floor(n / cols) * TILE_H))
                    n = n + 1
                end
            end
            local height = ceil(n / cols) * TILE_H
            if n > 0 then any = true end
            if sec.rows then
                for r, row in ipairs(sec.rows) do
                    row:SetShown(r <= sec.shownRows)
                    if r <= sec.shownRows then
                        row:ClearAllPoints()
                        row:SetPoint("TOPLEFT", child, "TOPLEFT", LIST_X, -(y + (r - 1) * MATE_ROW_H))
                    end
                end
                sec.listTitle:SetShown(sec.shownRows > 0)
                sec.listTitle:ClearAllPoints()
                sec.listTitle:SetPoint("TOPLEFT", child, "TOPLEFT", LIST_X, -(y - HEADING_H))
                height = max(height, sec.shownRows * MATE_ROW_H)
                if sec.shownRows > 0 then any = true end
            end
            sec.empty:SetShown(not any)
            if not any then
                sec.empty:ClearAllPoints()
                sec.empty:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
                height = 18
            end
            y = y + height + GAP
        end
        child:SetHeight(max(1, y - GAP))
    end

    local mateList = {}
    local lastSlow, laidOut = -SLOW_SECONDS, false

    function page:Refresh()
        local s = ui.Snapshot(ns.char or ns.sess, true, ns.char ~= nil)
        local partial = s.history ~= nil
        local dirty = false
        for _, sec in ipairs(sections) do
            for k, label in ipairs(sec.def.cards) do
                local def = byLabel[label]
                if def then
                    local text = def[2](s)
                    if text ~= sec.texts[k] then
                        sec.texts[k] = text
                        local on = not IsZero(text)
                        if on ~= sec.on[k] then
                            sec.on[k] = on
                            dirty = true
                        end
                        sec.tiles[k]:Set(label, text, partial and not ui.FullHistory[label] and "since install" or nil)
                    end
                end
            end
        end

        local now = GetTime()
        if now - lastSlow >= SLOW_SECONDS then
            lastSlow = now
            for _, sec in ipairs(sections) do
                if sec.bars then
                    for _, row in ipairs(sec.bars) do
                        local sum, n = 0, 0
                        for i = #row.list, 1, -1 do row.list[i] = nil end
                        for r, spec in ipairs(row.def.rows) do
                            local item = row.items[r]
                            item.value = max(0, spec[2](s))
                            item.text = Duration(item.value)
                            sum = sum + item.value
                            if item.value > 0 then
                                n = n + 1
                                row.list[n] = item
                            end
                        end
                        row.stack:Set(row.list)
                        local on = sum > 0
                        if on ~= row.on then
                            row.on = on
                            dirty = true
                        end
                    end
                end
                if sec.rows then
                    for i = #mateList, 1, -1 do mateList[i] = nil end
                    local mates = ns.char and ns.char.mates
                    if mates then
                        for key in pairs(mates) do
                            if not ns.IsOwnChar(key) then mateList[#mateList + 1] = key end
                        end
                        table.sort(mateList, function(a, b) return mates[a].secs > mates[b].secs end)
                    end
                    local shown = math.min(MATE_ROWS, #mateList)
                    for r = 1, shown do
                        local m = mates[mateList[r]]
                        local row = sec.rows[r]
                        row.name:SetText(ns.DisplayName(mateList[r]))
                        row.value:SetText(format("%s together, %d group%s", Duration(m.secs), m.groups,
                            m.groups == 1 and "" or "s"))
                    end
                    if shown ~= sec.shownRows then
                        sec.shownRows = shown
                        dirty = true
                    end
                end
            end
        end
        if dirty or not laidOut then
            laidOut = true
            Layout()
        end
    end

    page:SetScript("OnShow", function() scroll:SetVerticalScroll(0) end)
    return page
end
