local _, ns = ...

local floor, max, min, format = math.floor, math.max, math.min, string.format

local LEFT_W, GAP, PAGE_W = 226, 20, 655
local WALL_W = PAGE_W - LEFT_W - GAP - 12
local CREST, STEP, HEAD_H = 36, 48, 34
local MARK_PAD = 2
local PER_ROW = floor((WALL_W + STEP - CREST) / STEP)
local CHIP_H, CHIP_GAP = 24, 6
local CLOSEST_ROWS = 3
local WHEEL_STEP = 64
local SITE = "scarletweb.io"

local current
local filter, firstShown

--- Opens the Feats page on one feat.
function ns.OpenFeat(key, account)
    ns.UI.Open("feats")
    if current then current:Pick(key, account) end
end

function ns.FeatsPage(parent, ui)
    local T, Text, Fill, Num = ui.T, ui.Text, ui.Fill, ui.Num
    local Feats, tierName = ns.Feats, ns.TierName
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
            if self.feat and self.feat.key then page:Pick(self.feat.key, self.feat.account) end
        end)
        rows[i] = r
    end

    local card = CreateFrame("Frame", nil, left)
    card:SetPoint("TOPLEFT", 0, -304)
    card:SetSize(LEFT_W, 104)
    Fill(card, T.panel, 1):SetAllPoints()
    ui.Border(card, T.line)
    card.crest = ui.Crest(card, 64)
    card.crest:SetPoint("TOPLEFT", 12, -12)
    card.name = Text(card, 21, T.fg, "LEFT", "display")
    card.name:SetPoint("TOPLEFT", 86, -14)
    card.chip = ui.TierChip(card, 11)
    card.chip:SetPoint("LEFT", card.name, "RIGHT", 7, -1)
    card.count = Text(card, 12, T.text)
    card.count:SetPoint("TOPLEFT", 86, -42)
    card.count:SetWidth(LEFT_W - 98)
    card.holder = Text(card, 12, T.muted)
    card.holder:SetPoint("TOPLEFT", 86, -58)
    card.holder:SetWidth(LEFT_W - 98)
    card.dot = Fill(card, T.accent, 1, "ARTWORK")
    card.dot:SetSize(5, 5)
    card.dot:SetRotation(math.pi / 4)
    card.dot:SetPoint("TOPLEFT", 14, -87)
    card.left = Text(card, 12, T.muted)
    card.left:SetPoint("TOPLEFT", 12, -82)
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
        thumb:SetPoint("TOPLEFT", wall, "TOPRIGHT", 9, -y)
        thumb:SetHeight(h)
    end
    wall:SetScript("OnMouseWheel", function(self, delta)
        local top = max(0, child:GetHeight() - self:GetHeight())
        self:SetVerticalScroll(min(top, max(0, self:GetVerticalScroll() - delta * WHEEL_STEP)))
        Thumb()
    end)

    local mark = CreateFrame("Frame", nil, child)
    mark:SetSize(CREST + 4, CREST + 4)
    mark:SetFrameLevel(child:GetFrameLevel() + 5)
    ui.Border(mark, T.fg)
    mark:Hide()

    local cells, acells, groups = {}, {}, {}
    local function Web()
        local file = Feats.File()
        return file ~= nil and file.source == "web"
    end
    local function Shown(f) return f.live ~= nil or Web() end

    local function CountText(f, info)
        return Feats.Count(f, info.value) .. (info.account and " on the account" or "")
    end

    local waiting, order, nextAt, pumping = {}, {}, 1, false

    local function Cell(f, account)
        local b = CreateFrame("Button", nil, child)
        b:SetSize(CREST, CREST)
        b.crest = ui.Crest(b, CREST)
        b.crest:SetAllPoints()
        b.dot = Fill(b, T.accent, 1, "OVERLAY")
        b.dot:SetSize(5, 5)
        b.dot:SetRotation(math.pi / 4)
        b.dot:SetPoint("CENTER", b, "TOPRIGHT", 3, -1)
        b.def = f
        b:SetScript("OnClick", function() page:Pick(f.key, account) end)
        b:SetScript("OnEnter", function(self)
            local info = account and Feats.AccountInfo(f.key) or Feats.Info(f.key)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(f.name)
            GameTooltip:AddLine(CountText(f, info), T.muted[1], T.muted[2], T.muted[3])
            if account and f.account == "max" and info.holder then
                GameTooltip:AddLine("Held by " .. ns.DisplayName(info.holder), T.muted[1], T.muted[2], T.muted[3])
            end
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        if account then acells[f.key] = b else cells[f.key] = b end
        return b
    end

    local placed = {}
    local function Slot(b, i, y)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", child, "TOPLEFT", MARK_PAD + ((i - 1) % PER_ROW) * STEP,
            -(y + HEAD_H + floor((i - 1) / PER_ROW) * STEP))
        b:Show()
        placed[b] = true
    end

    local function Paint(b, f, info, spells)
        b.crest:Set("account", f.glyph, info.tier, info.progress, spells and spells[f.key])
        b.dot:SetShown(Feats.Moves(f))
    end

    local function Build(key)
        local w = waiting[key]
        if not w then return acells[key] end
        waiting[key] = nil
        local b = Cell(w.f, true)
        Slot(b, w.i, w.y)
        Paint(b, w.f, Feats.AccountInfo(key), ns.char and ns.char.featSpell)
        return b
    end

    local function Pump()
        pumping = false
        local n = 0
        while nextAt <= #order and n < PER_ROW do
            local key = order[nextAt]
            nextAt = nextAt + 1
            if waiting[key] then
                Build(key)
                n = n + 1
            end
        end
        if nextAt <= #order then
            pumping = true
            C_Timer.After(0, Pump)
        end
    end

    local function Defer(f, i, y)
        waiting[f.key] = { f = f, i = i, y = y }
        order[#order + 1] = f.key
        if not pumping then
            pumping = true
            C_Timer.After(0, Pump)
        end
    end

    local function Group(name, list, account, y)
        local g = groups[name]
        if not g then
            g = CreateFrame("Frame", nil, child)
            g.name = Text(g, 19, T.fg, "LEFT", "display")
            g.name:SetPoint("TOPLEFT", 0, 2)
            g.name:SetText(name)
            g.count = Text(g, 12, T.muted)
            g.count:SetPoint("BOTTOMLEFT", g.name, "BOTTOMRIGHT", 10, 2)
            groups[name] = g
        end
        local lines = floor((#list - 1) / PER_ROW) + 1
        local h = HEAD_H + lines * STEP
        g:ClearAllPoints()
        g:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
        g:SetSize(WALL_W, h)
        g:Show()
        g.list = list
        local pool = account and acells or cells
        for i, f in ipairs(list) do
            local b = pool[f.key]
            if b then
                Slot(b, i, y)
            elseif account then
                Defer(f, i, y)
            else
                Slot(Cell(f, false), i, y)
            end
        end
        return h
    end

    local chips, more = {}, nil

    local function Chip(name)
        local b = CreateFrame("Button", nil, page)
        b:SetHeight(CHIP_H)
        Fill(b, T.fg, 0.05):SetAllPoints()
        b.on = Fill(b, T.accent, 0.2, "BORDER")
        b.on:SetAllPoints()
        b.label = Text(b, 12, T.muted, "CENTER", "strong")
        b.label:SetPoint("CENTER")
        b.label:SetText(name)
        b:SetWidth((b.label:GetStringWidth() or 40) + 18)
        b:SetScript("OnClick", function() page:Filter(name) end)
        chips[name] = b
        return b
    end

    local function LayoutChips(entries)
        for _, b in pairs(chips) do b:Hide() end
        local x, y = 0, 0
        local area = PAGE_W - LEFT_W - GAP
        for _, e in ipairs(entries) do
            local b = chips[e.name] or Chip(e.name)
            local w = b:GetWidth()
            if x > 0 and x + w > area then x, y = 0, y + CHIP_H + CHIP_GAP end
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", page, "TOPLEFT", LEFT_W + GAP + x, -y)
            b:Show()
            local chosen = e.name == filter
            b.on:SetShown(chosen)
            local c = chosen and T.fg or T.muted
            b.label:SetTextColor(c[1], c[2], c[3])
            x = x + w + CHIP_GAP
        end
        wall:ClearAllPoints()
        wall:SetPoint("TOPLEFT", LEFT_W + GAP, -(#entries > 0 and y + CHIP_H + 12 or 0))
        wall:SetPoint("BOTTOMRIGHT", -12, 0)
    end

    local function Layout()
        built = true
        wipe(waiting)
        wipe(order)
        wipe(placed)
        nextAt = 1
        local entries = {}
        if Feats.HasAccount() then
            local account = {}
            for _, f in ipairs(Feats.AccountFeats()) do
                if Shown(f) then account[#account + 1] = f end
            end
            if #account > 0 then entries[#entries + 1] = { name = "Account", list = account, account = true } end
        end
        for _, group in ipairs(Feats.Collections()) do
            local list = {}
            for _, f in ipairs(group.feats) do
                if Shown(f) then list[#list + 1] = f end
            end
            if #list > 0 then entries[#entries + 1] = { name = group.name, list = list } end
        end
        local known = false
        for _, e in ipairs(entries) do
            if e.name == filter then known = true end
        end
        if not known then filter = entries[1] and entries[1].name end
        LayoutChips(entries)
        for _, g in pairs(groups) do g:Hide() end
        local y = 0
        for _, e in ipairs(entries) do
            if e.name == filter then
                y = y + Group(e.name, e.list, e.account == true, y)
                firstShown = (e.account and "account:" or "") .. e.list[1].key
            end
        end
        for _, pool in ipairs({ cells, acells }) do
            for _, b in pairs(pool) do
                if not placed[b] then b:Hide() end
            end
        end
        if not Web() then
            if not more then more = Text(child, 12, T.muted) end
            more:ClearAllPoints()
            more:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -(y + 10))
            more:SetText(format("The website counts all %d feats · %s", #ns.FEATS, SITE))
            more:Show()
            y = y + 34
        elseif more then
            more:Hide()
        end
        child:SetHeight(max(1, y))
    end

    local function Reveal(token)
        if not built then return end
        local account = token:sub(1, 8) == "account:"
        local key = account and token:sub(9) or token
        local want = account and "Account" or nil
        if not account then
            for _, group in ipairs(Feats.Collections()) do
                for _, f in ipairs(group.feats) do
                    if f.key == key then want = group.name end
                end
            end
        end
        if want and want ~= filter and chips[want] then
            filter = want
            Layout()
            wall:SetVerticalScroll(0)
        end
    end

    local function CellOf(token)
        if not token then return end
        if token:sub(1, 8) == "account:" then return Build(token:sub(9)) end
        return cells[token]
    end

    local function Card(token)
        local account = token ~= nil and token:sub(1, 8) == "account:"
        local key = token and (account and token:sub(9) or token)
        local info = key and (account and Feats.AccountInfo(key) or Feats.Info(key))
        card:SetShown(info ~= nil)
        if not info then return end
        local f = info.def
        local spells = ns.char and ns.char.featSpell
        card.crest:Set(account and "account" or f.crest, f.glyph, info.tier, info.progress, spells and spells[f.key])
        card.name:SetText(f.name)
        card.chip:Set(info.tier)
        local fresh = not account and ns.char and ns.char.featNew and ns.char.featNew[key]
        card.count:SetText(CountText(f, info) .. (fresh and fresh <= info.tier and " · new tier" or ""))
        card.holder:SetText(account and f.account == "max" and info.holder and ("Held by " .. ns.DisplayName(info.holder)) or "")
        local moves = Feats.Moves(f)
        local text = info.next and format("%s to %s", Num(info.left), tierName(info.tier + 1)) or "Highest tier held"
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
        local spells = ns.char and ns.char.featSpell
        local ag = groups.Account
        if ag and ag.list then
            local own = 0
            for _, f in ipairs(ag.list) do
                local info = Feats.AccountInfo(f.key)
                local b = acells[f.key]
                if b then Paint(b, f, info, spells) end
                if info.tier > 0 then own = own + 1 end
            end
            ag.count:SetText(format("%d of %d", own, #ag.list))
        end
        for _, group in ipairs(Feats.Collections()) do
            local own, listed = 0, 0
            for _, f in ipairs(group.feats) do
                if Shown(f) then
                    local info = Feats.Info(f.key)
                    local b = cells[f.key]
                    if b then
                        b.crest:Set(f.crest, f.glyph, info.tier, info.progress, spells and spells[f.key])
                        b.dot:SetShown(Feats.Moves(f))
                    end
                    total, listed = total + 1, listed + 1
                    if info.tier > 0 then
                        held, own = held + 1, own + 1
                        counts[info.tier] = counts[info.tier] + 1
                    end
                end
            end
            if groups[group.name] then groups[group.name].count:SetText(format("%d of %d", own, listed)) end
        end
        ring:Set(total > 0 and held / total or 0, tostring(held))
        of:SetText(format("of %d feats", total))
        local parts = {}
        for t = 5, 1, -1 do
            if counts[t] > 0 then parts[#parts + 1] = format("%d %s", counts[t], tierName(t)) end
        end
        tiers:SetText(table.concat(parts, " · "))
        local shown = Feats.Closest(CLOSEST_ROWS, Shown)
        for i = 1, CLOSEST_ROWS do
            local info = shown[i]
            rows[i]:SetShown(info ~= nil)
            if info then rows[i]:Set(Feats.ClosestRow(info)) end
        end
        closestTitle:SetShown(#shown > 0)
        local file = Feats.File()
        foot:SetText(file and file.through and "Counted through the last export" or "Counted since install")
        local at = CellOf(picked)
        if not at or not at:IsShown() then
            picked = firstShown
            for _, info in ipairs(shown) do
                local token = (info.account and "account:" or "") .. info.def.key
                local cell = CellOf(token)
                if cell and cell:IsShown() then
                    picked = token
                    break
                end
            end
        end
        Card(picked)
        local b = CellOf(picked)
        mark:SetShown(b ~= nil and b:IsShown())
        if b then
            mark:ClearAllPoints()
            mark:SetPoint("CENTER", b, "CENTER")
        end
    end

    --- Shows one collection's crests: the chip's name.
    function page:Filter(name)
        filter = name
        Layout()
        Redraw()
        wall:SetVerticalScroll(0)
        Thumb()
    end

    function page:Pick(key, account)
        local token = account and ("account:" .. key) or key
        if built then
            local before = filter
            Reveal(token)
            if filter ~= before then Redraw() end
        end
        local b = CellOf(token)
        if not b then return end
        picked = token
        if not account and ns.char and ns.char.featNew then ns.char.featNew[key] = nil end
        Card(token)
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
        if not built then
            if not Feats.Indexed() then return end
            Layout()
        end
        drawn = stamp
        Redraw()
        Thumb()
    end

    return page
end
