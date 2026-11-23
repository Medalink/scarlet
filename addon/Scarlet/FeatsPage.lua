local _, ns = ...

local floor, max, min, format = math.floor, math.max, math.min, string.format

local LEFT_W, GAP = 226, 20
local WALL_W = 656 - LEFT_W - GAP - 12
local SEAL, STEP, LABEL_W, ROW_PAD = 28, 32, 96, 10
local PER_ROW = floor((WALL_W - LABEL_W) / STEP)
local CLOSEST_ROWS = 3
local WHEEL_STEP = 64
local SITE = "scarletweb.io"

local current

--- Opens the Feats page on one feat.
function ns.OpenFeat(key)
    ns.UI.Open("feats")
    if current then current:Pick(key) end
end

function ns.FeatsPage(parent, ui)
    local T, Text, Fill, Hair, Num = ui.T, ui.Text, ui.Fill, ui.Hair, ui.Num
    local Feats, names = ns.Feats, ns.FEAT_TIER_NAMES
    local page = CreateFrame("Frame", nil, parent)
    page:SetAllPoints()
    current = page
    local picked, drawn, built

    local left = CreateFrame("Frame", nil, page)
    left:SetPoint("TOPLEFT")
    left:SetPoint("BOTTOMLEFT")
    left:SetWidth(LEFT_W)
    local title = Text(left, 30, T.fg, "LEFT", "display")
    title:SetPoint("TOPLEFT", 0, 2)
    title:SetText("Feats")
    local ring = ui.Ring(left, 74, 36)
    ring:SetPoint("TOPLEFT", 0, -46)
    local of = Text(left, 12, T.fg, "LEFT", "strong")
    of:SetPoint("TOPLEFT", ring, "TOPRIGHT", 12, -18)
    local tiers = Text(left, 12, T.muted)
    tiers:SetPoint("TOPLEFT", of, "BOTTOMLEFT", 0, -3)
    tiers:SetWordWrap(true)
    tiers:SetWidth(LEFT_W - 90)
    tiers:SetJustifyV("TOP")

    local closestTitle = Text(left, 19, T.fg, "LEFT", "display")
    closestTitle:SetPoint("TOPLEFT", 0, -134)
    closestTitle:SetText("Closest")
    local rows = {}
    for i = 1, CLOSEST_ROWS do
        local r = ui.FeatRow(left, LEFT_W)
        r:SetPoint("TOPLEFT", 0, -160 - (i - 1) * 44)
        r:SetScript("OnClick", function(self)
            if self.feat and self.feat.key then page:Pick(self.feat.key) end
        end)
        rows[i] = r
    end

    local card = CreateFrame("Frame", nil, left)
    card:SetPoint("TOPLEFT", 0, -304)
    card:SetSize(LEFT_W, 100)
    Fill(card, T.panel, 1):SetAllPoints()
    ui.Border(card, T.line)
    card.seal = ui.Seal(card, 56)
    card.seal:SetPoint("TOPLEFT", 12, -12)
    card.name = Text(card, 21, T.fg, "LEFT", "display")
    card.name:SetPoint("TOPLEFT", 78, -14)
    card.chip = Text(card, 11, T.fg, "LEFT", "strong")
    card.chip:SetPoint("LEFT", card.name, "RIGHT", 7, -1)
    card.count = Text(card, 12, T.text)
    card.count:SetPoint("TOPLEFT", 78, -42)
    card.count:SetWidth(LEFT_W - 90)
    card.dot = Fill(card, T.accent, 1, "ARTWORK")
    card.dot:SetSize(5, 5)
    card.dot:SetRotation(math.pi / 4)
    card.dot:SetPoint("TOPLEFT", 14, -83)
    card.left = Text(card, 12, T.muted)
    card.left:SetPoint("TOPLEFT", 12, -78)
    card.left:SetWidth(LEFT_W - 24)
    card.liveText = Text(card, 12, T.muted)
    card.liveText:SetText("counts while you play")

    local foot = Text(left, 11.5, T.muted)
    foot:SetPoint("BOTTOMLEFT", 0, 16)
    local footDot = Fill(left, T.accent, 1, "ARTWORK")
    footDot:SetSize(5, 5)
    footDot:SetRotation(math.pi / 4)
    footDot:SetPoint("BOTTOMLEFT", 2, 4)
    local footLive = Text(left, 11.5, T.muted)
    footLive:SetPoint("BOTTOMLEFT", 12, 0)
    footLive:SetText("this session live")

    local wall = CreateFrame("ScrollFrame", nil, page)
    wall:SetPoint("TOPLEFT", LEFT_W + GAP, 0)
    wall:SetPoint("BOTTOMRIGHT", -12, 0)
    local child = CreateFrame("Frame", nil, wall)
    child:SetSize(WALL_W, 1)
    wall:SetScrollChild(child)
    wall:EnableMouseWheel(true)
    local thumb = Fill(page, T.fg, 0.18, "OVERLAY")
    thumb:SetWidth(3)
    local function Thumb()
        local view, total = wall:GetHeight(), child:GetHeight()
        thumb:SetShown(total > view)
        if total <= view then return end
        local h = max(24, view * view / total)
        local y = wall:GetVerticalScroll() / (total - view) * (view - h)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, -y)
        thumb:SetHeight(h)
    end
    wall:SetScript("OnMouseWheel", function(self, delta)
        local top = max(0, child:GetHeight() - self:GetHeight())
        self:SetVerticalScroll(min(top, max(0, self:GetVerticalScroll() - delta * WHEEL_STEP)))
        Thumb()
    end)

    local mark = CreateFrame("Frame", nil, child)
    mark:SetSize(SEAL + 4, SEAL + 4)
    mark:SetFrameLevel(child:GetFrameLevel() + 5)
    ui.Border(mark, T.fg)
    mark:Hide()

    local cells, groups = {}, {}
    local function Web()
        local file = Feats.File()
        return file ~= nil and file.source == "web"
    end
    local function Shown(f) return f.live ~= nil or Web() end

    local function Cell(f)
        local b = CreateFrame("Button", nil, child)
        b:SetSize(SEAL, SEAL)
        b.seal = ui.Seal(b, SEAL)
        b.seal:SetAllPoints()
        b.dot = Fill(b, T.accent, 1, "OVERLAY")
        b.dot:SetSize(5, 5)
        b.dot:SetRotation(math.pi / 4)
        b.dot:SetPoint("CENTER", b, "TOPRIGHT", -2, -2)
        b.def = f
        b:SetScript("OnClick", function() page:Pick(f.key) end)
        b:SetScript("OnEnter", function(self)
            local info = Feats.Info(f.key)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(f.name)
            GameTooltip:AddLine(Feats.Count(f, info.value), T.muted[1], T.muted[2], T.muted[3])
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        cells[f.key] = b
        return b
    end

    local function Layout()
        built = true
        local y = 0
        for _, group in ipairs(Feats.Collections()) do
            local list = {}
            for _, f in ipairs(group.feats) do
                if Shown(f) then list[#list + 1] = f end
            end
            if #list > 0 then
                local g = groups[group.name]
                if not g then
                    g = CreateFrame("Frame", nil, child)
                    g.name = Text(g, 13, T.fg, "LEFT", "strong")
                    g.name:SetPoint("TOPLEFT", 0, -3)
                    g.name:SetWidth(LABEL_W - 8)
                    g.count = Text(g, 12, T.muted)
                    g.count:SetPoint("TOPLEFT", 0, -20)
                    Hair(g, "BOTTOM")
                    g.name:SetText(group.name)
                    groups[group.name] = g
                end
                local lines = floor((#list - 1) / PER_ROW) + 1
                local h = lines * STEP + ROW_PAD
                g:ClearAllPoints()
                g:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
                g:SetSize(WALL_W, h)
                g:Show()
                g.list = list
                for i, f in ipairs(list) do
                    local b = cells[f.key] or Cell(f)
                    b:ClearAllPoints()
                    b:SetPoint("TOPLEFT", child, "TOPLEFT", LABEL_W + ((i - 1) % PER_ROW) * STEP,
                        -(y + floor((i - 1) / PER_ROW) * STEP + 2))
                    b:Show()
                end
                y = y + h
            end
        end
        for _, b in pairs(cells) do
            if not Shown(b.def) then b:Hide() end
        end
        if not Web() then
            local more = groups.__more
            if not more then
                more = Text(child, 12, T.muted)
                groups.__more = more
            end
            more:ClearAllPoints()
            more:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -(y + 10))
            more:SetText(format("The website counts all %d feats · %s", #ns.FEATS, SITE))
            more:Show()
            y = y + 34
        elseif groups.__more then
            groups.__more:Hide()
        end
        child:SetHeight(max(1, y))
    end

    local function Card(key)
        local info = key and Feats.Info(key)
        card:SetShown(info ~= nil)
        if not info then return end
        local f = info.def
        local spells = ns.char and ns.char.featSpell
        card.seal:Set({ family = f.family, glyph = f.glyph, tier = info.tier, progress = info.progress,
            spell = spells and spells[f.key] })
        card.name:SetText(f.name)
        card.chip:SetText(info.tier > 0 and names[info.tier] or "")
        local c = info.tier > 0 and ui.TierColor[info.tier] or T.muted
        card.chip:SetTextColor(c[1], c[2], c[3])
        local fresh = ns.char and ns.char.featNew and ns.char.featNew[key]
        card.count:SetText(Feats.Count(f, info.value) .. (fresh and fresh <= info.tier and " · new tier" or ""))
        local moves = Feats.Moves(f)
        local text = info.next and format("%s to %s", Num(info.left), names[info.tier + 1]) or "Highest tier held"
        card.left:SetText(text .. (moves and " ·" or ""))
        card.dot:SetShown(moves)
        card.dot:ClearAllPoints()
        card.dot:SetPoint("LEFT", card.left, "LEFT", (card.left:GetStringWidth() or 0) + 7, 0)
        card.liveText:ClearAllPoints()
        card.liveText:SetPoint("LEFT", card.dot, "RIGHT", 6, 0)
        card.liveText:SetShown(moves)
    end

    local function Redraw()
        local held, total = 0, 0
        local counts = { 0, 0, 0, 0, 0 }
        for _, group in ipairs(Feats.Collections()) do
            local own = 0
            local list = groups[group.name] and groups[group.name].list
            if list then
                for _, f in ipairs(list) do
                    local info = Feats.Info(f.key)
                    local b = cells[f.key]
                    local spells = ns.char and ns.char.featSpell
                    b.seal:Set({ family = f.family, glyph = f.glyph, tier = info.tier, progress = info.progress,
                        spell = spells and spells[f.key], bg = T.win })
                    b.dot:SetShown(Feats.Moves(f))
                    total = total + 1
                    if info.tier > 0 then
                        held, own = held + 1, own + 1
                        counts[info.tier] = counts[info.tier] + 1
                    end
                end
                groups[group.name].count:SetText(format("%d of %d", own, #list))
            end
        end
        ring:Set(total > 0 and held / total or 0, tostring(held))
        of:SetText(format("of %d feats", total))
        local parts = {}
        for t = 5, 1, -1 do
            if counts[t] > 0 then parts[#parts + 1] = format("%d %s", counts[t], names[t]) end
        end
        tiers:SetText(table.concat(parts, " · "))
        local shown = Feats.Closest(CLOSEST_ROWS, Shown)
        for i = 1, CLOSEST_ROWS do
            local info = shown[i]
            rows[i]:SetShown(info ~= nil)
            if info then
                local f = info.def
                local spells = ns.char and ns.char.featSpell
                rows[i]:Set({ key = f.key, name = f.name, line = format("%s to %s", Num(info.left), names[info.tier + 1]),
                    progress = info.progress, tier = info.tier, family = f.family, glyph = f.glyph,
                    spell = spells and spells[f.key], bg = T.win })
            end
        end
        closestTitle:SetShown(#shown > 0)
        local file = Feats.File()
        foot:SetText(file and file.through and "Counted through the last export" or "Counted since install")
        if not picked or not cells[picked] or not cells[picked]:IsShown() then
            picked = shown[1] and shown[1].def.key or nil
            if not picked then
                local first = Feats.Collections()[1]
                picked = first and first.feats[1] and first.feats[1].key
            end
        end
        Card(picked)
        local b = picked and cells[picked]
        mark:SetShown(b ~= nil and b:IsShown())
        if b then
            mark:ClearAllPoints()
            mark:SetPoint("CENTER", b, "CENTER")
        end
    end

    function page:Pick(key)
        local b = cells[key]
        if not b then return end
        picked = key
        if ns.char and ns.char.featNew then ns.char.featNew[key] = nil end
        Card(key)
        mark:ClearAllPoints()
        mark:SetPoint("CENTER", b, "CENTER")
        mark:Show()
        local _, _, _, _, y = b:GetPoint()
        local top = max(0, child:GetHeight() - wall:GetHeight())
        if y then wall:SetVerticalScroll(min(top, max(0, -y - 20))) end
        Thumb()
    end

    function page:Refresh()
        local stamp = Feats.Stamp()
        if built and drawn == stamp then return end
        if not built then Layout() end
        drawn = stamp
        Redraw()
        Thumb()
    end

    return page
end
