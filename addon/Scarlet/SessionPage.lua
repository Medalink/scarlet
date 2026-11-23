local _, ns = ...

local floor, max, min, format = math.floor, math.max, math.min, string.format

local TAB_ROW, TITLE_H = 34, 36
local ROUTE_W, ROUTE_H = 236, 176
local GRID_X, TILE_W, TILE_H = 252, 201, 88
local BEST = "Best of the last 30 sessions"
local STRIP_H, PAGE_W = 68, 655
local COL_W, COL_X = 199, { 0, 228, 456 }
local EARLIER_ROW = 26

local MORE = {
    { "Quests turned in", "quests" }, { "Deaths", "deaths" }, { "Casts", "casts" }, { "Damage done", "damage" },
    { "Items looted", "loot" }, { "Places discovered", "discoveries" }, { "Healing done", "healing" },
    { "Damage taken", "damageTaken" }, { "Interrupts", "interrupts" }, { "NPCs talked to", "npcTalks" },
    { "Jumps", "jumps" },
}
local MORE_ROWS = 6

local function Total(t)
    local sum = 0
    for _, v in pairs(t) do sum = sum + v end
    return sum
end

local function Rate(n, played)
    if played < 300 then return nil end
    return floor(n / (played / 3600) + 0.5)
end

local current

--- Opens the Session page on one of its tabs: this, last, earlier or log.
function ns.OpenSession(tab)
    ns.UI.Open("recap")
    if current then current:Open(tab) end
end

function ns.SessionPage(parent, ui)
    local T, Text, Hair, Num, Duration, Money = ui.T, ui.Text, ui.Hair, ui.Num, ui.Duration, ui.Money
    local page = CreateFrame("Frame", nil, parent)
    page:SetAllPoints()
    current = page
    local tab = "this"
    local drawn

    local tabs = ui.Tabs(page, { { key = "this", label = "This session" }, { key = "last", label = "Last session" },
        { key = "earlier", label = "Earlier" }, { key = "log", label = "Log" } }, function(key) page:Open(key) end)
    tabs:SetPoint("TOPLEFT")
    local started = Text(page, 12, T.muted, "RIGHT")
    started:SetPoint("TOPRIGHT", 0, -9)

    local view = CreateFrame("Frame", nil, page)
    view:SetPoint("TOPLEFT", 0, -TAB_ROW)
    view:SetPoint("BOTTOMRIGHT")
    local title = Text(view, 30, T.fg, "LEFT", "display")
    title:SetPoint("TOPLEFT", 0, 2)
    title:SetPoint("RIGHT")
    local route = ui.Route(view, ROUTE_W, ROUTE_H)
    route:SetPoint("TOPLEFT", 0, -TITLE_H)
    local grid = CreateFrame("Frame", nil, view)
    grid:SetPoint("TOPLEFT", GRID_X, -TITLE_H)
    grid:SetSize(TILE_W * 2, TILE_H * 2)
    ui.Border(grid, T.line)
    local tiles = {}
    for i = 1, 4 do
        local t = ui.Tile(grid, TILE_W, TILE_H)
        t:SetPoint("TOPLEFT", ((i - 1) % 2) * TILE_W, -floor((i - 1) / 2) * TILE_H)
        tiles[i] = t
    end
    local strip = ui.Strip(view, PAGE_W, STRIP_H, true)
    strip:SetPoint("TOPLEFT", 0, -(TITLE_H + ROUTE_H + 10))
    local colTop = TITLE_H + ROUTE_H + 10 + STRIP_H + 10
    local function Heading(x, text)
        local h = Text(view, 19, T.fg, "LEFT", "display")
        h:SetPoint("TOPLEFT", x, -colTop)
        h:SetText(text)
    end
    Heading(COL_X[1], "Feats")
    Heading(COL_X[2], "Time")
    Heading(COL_X[3], "More")
    local bodyTop = colTop + 28

    local featRows = {}
    for i = 1, 3 do
        local r = ui.FeatRow(view, COL_W)
        r:SetPoint("TOPLEFT", COL_X[1], -(bodyTop + (i - 1) * 44))
        r:SetScript("OnClick", function(self)
            if ns.OpenFeat and self.feat and self.feat.key then ns.OpenFeat(self.feat.key) end
        end)
        featRows[i] = r
    end
    local noFeats = Text(view, 13, T.muted)
    noFeats:SetPoint("TOPLEFT", COL_X[1], -bodyTop)
    noFeats:SetText("No feats earned or near.")

    local travel = ui.Stack(view, COL_W, 10)
    travel:SetPoint("TOPLEFT", COL_X[2], -bodyTop)
    local combat = ui.Stack(view, COL_W, 10)
    combat:SetPoint("TOPLEFT", travel, "BOTTOMLEFT", 0, -14)

    local more = {}
    for i = 1, MORE_ROWS do
        local label = Text(view, 13, T.text)
        label:SetPoint("TOPLEFT", COL_X[3], -(bodyTop + (i - 1) * 22))
        local value = Text(view, 13, T.fg, "RIGHT", "strong")
        value:SetPoint("TOPRIGHT", view, "TOPLEFT", COL_X[3] + COL_W, -(bodyTop + (i - 1) * 22))
        more[i] = { label = label, value = value }
    end
    local empty = Text(view, 14, T.muted)
    empty:SetPoint("TOPLEFT", 0, -TITLE_H)

    local function DrawFeats(recap)
        local rows = ns.Feats and ns.Feats.SessionRows and ns.Feats.SessionRows(recap) or nil
        for i = 1, 3 do
            local r = rows and rows[i]
            featRows[i]:SetShown(r ~= nil)
            if r then
                r.bg = T.win
                featRows[i]:Set(r)
            end
        end
        noFeats:SetShown(not (rows and rows[1]))
    end

    local function Draw(recap)
        local c, played = recap.counters or {}, recap.played or 0
        title:SetText(recap.title and recap.title.text or "")
        local best = {}
        for _, k in ipairs(recap.bests or {}) do best[k] = true end
        local xp = Total(recap.xp or {})
        local xph = Rate(xp, played)
        tiles[1]:Set("Experience", Num(xp), xph and (Num(xph) .. " an hour") or "",
            (best.xp or best.xp_h) and BEST or nil)
        local kph = Rate(c.kills or 0, played)
        local blows = c.blows or 0
        tiles[2]:Set("Kills", Num(c.kills or 0), kph and format("%s an hour%s", Num(kph),
            blows > 0 and format(" · %s killing blow%s", Num(blows), blows == 1 and "" or "s") or "") or "",
            best.kills and BEST or nil)
        local g = recap.gold or { earned = c.earned or 0, spent = c.spent or 0 }
        local net = g.earned - g.spent
        tiles[3]:Set("Gold", (net < 0 and "-" or "+") .. Money(math.abs(net)),
            format("Earned %s · spent %s", Money(g.earned), Money(g.spent)), best.earned and BEST or nil)
        local swum, onFoot = c.swim or 0, (c.foot or 0) + (c.walk or 0)
        local mounted = (c.mount or 0) + (c.fly or 0)
        local yards = swum + onFoot + mounted
        local modes = {}
        if swum > 0 then modes[#modes + 1] = { value = swum, color = T.s2 } end
        if onFoot > 0 then modes[#modes + 1] = { value = onFoot, color = T.accent } end
        if mounted > 0 then modes[#modes + 1] = { value = mounted, color = T.s3 } end
        tiles[4]:Set("Distance", ui.Distance(yards), best.distance and BEST or format("%s jumps", Num(c.jumps or 0)),
            nil, #modes > 0 and modes or nil)
        strip:Set(recap)
        route:Set(recap.route and recap.route.sheet)
        DrawFeats(recap)
        local rows = {}
        local function Add(label, secs, color)
            if (secs or 0) >= 1 then rows[#rows + 1] = { label = label, value = secs, text = Duration(secs), color = color } end
        end
        Add("Swimming", c.swimTime, T.s2)
        Add("On foot", (c.footTime or 0) + (c.walkTime or 0), T.accent)
        Add("Mounted", (c.mountTime or 0) + (c.flyTime or 0), T.s3)
        Add("Flight paths", c.taxiTime, T.s4)
        Add("Standing still", c.stillTime, T.rest)
        travel:Set(rows)
        local fight = min(c.combat or 0, played)
        combat:Set({ { label = "In combat", value = fight, text = Duration(fight), color = T.accent },
            { label = "Out of combat", value = max(0, played - fight), text = Duration(max(0, played - fight)), color = T.rest } })
        local n = 0
        for i = 1, #MORE do
            local v = c[MORE[i][2]]
            if v and v > 0 and n < MORE_ROWS then
                n = n + 1
                more[n].label:SetText(MORE[i][1])
                more[n].value:SetText(Num(v))
            end
        end
        for i = 1, MORE_ROWS do
            local on = i <= n
            more[i].label:SetShown(on)
            more[i].value:SetShown(on)
        end
        started:SetText(format("Started %s · %s", date(tab == "this" and "%H:%M" or "%b %d %H:%M", recap.start),
            Duration(played)))
    end

    local function Show(recap, none)
        drawn = recap
        local on = recap ~= nil
        for _, f in ipairs({ route, grid, strip }) do f:SetShown(on) end
        title:SetShown(on)
        empty:SetShown(not on)
        empty:SetText(none or "")
        started:SetShown(on)
        if not on then
            for i = 1, 3 do featRows[i]:Hide() end
            noFeats:Hide()
            travel:Hide()
            combat:Hide()
            for i = 1, MORE_ROWS do more[i].label:Hide() more[i].value:Hide() end
            return
        end
        travel:Show()
        combat:Show()
        Draw(recap)
    end

    local earlier = CreateFrame("ScrollFrame", nil, page)
    earlier:SetPoint("TOPLEFT", 0, -TAB_ROW - 8)
    earlier:SetPoint("BOTTOMRIGHT")
    local child = CreateFrame("Frame", nil, earlier)
    child:SetSize(PAGE_W, 1)
    earlier:SetScrollChild(child)
    earlier:EnableMouseWheel(true)
    earlier:SetScript("OnMouseWheel", function(self, delta)
        local top = max(0, child:GetHeight() - self:GetHeight())
        self:SetVerticalScroll(min(top, max(0, self:GetVerticalScroll() - delta * EARLIER_ROW * 3)))
    end)
    local noRows = Text(earlier, 14, T.muted)
    noRows:SetPoint("TOPLEFT", 0, 0)
    noRows:SetText("No sessions recorded yet.")
    local list, rows = {}, {}

    local function EarlierRow(i)
        local row = CreateFrame("Button", nil, child)
        row:SetHeight(EARLIER_ROW)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * EARLIER_ROW)
        row:SetPoint("TOPRIGHT", 0, -(i - 1) * EARLIER_ROW)
        local hover = ui.Fill(row, T.fg, 0.03)
        hover:SetAllPoints()
        hover:Hide()
        Hair(row, "BOTTOM")
        row.date = Text(row, 13, T.muted)
        row.date:SetPoint("LEFT", 0, 0)
        row.title = Text(row, 14, T.fg, "LEFT", "strong")
        row.title:SetPoint("LEFT", 110, 0)
        row.title:SetWidth(270)
        row.played = Text(row, 13, T.text, "RIGHT")
        row.played:SetPoint("LEFT", 390, 0)
        row.played:SetWidth(80)
        row.levels = Text(row, 13, T.text, "RIGHT")
        row.levels:SetPoint("LEFT", 480, 0)
        row.levels:SetWidth(90)
        row.kills = Text(row, 13, T.text, "RIGHT")
        row.kills:SetPoint("LEFT", 576, 0)
        row.kills:SetWidth(80)
        row:SetScript("OnEnter", function(self)
            if self.recap then hover:Show() end
        end)
        row:SetScript("OnLeave", function() hover:Hide() end)
        row:SetScript("OnClick", function(self)
            if self.recap then page:Open("last", self.recap) end
        end)
        return row
    end

    local function RefreshEarlier()
        ns.Recap.Earlier(list)
        noRows:SetShown(#list == 0)
        for i = 1, #list do
            local r, row = list[i], rows[i]
            if not row then
                row = EarlierRow(i)
                rows[i] = row
            end
            row:Show()
            row.recap = ns.Recap.For(r.t)
            row:SetEnabled(row.recap ~= nil)
            row:SetAlpha(row.recap and 1 or 0.45)
            row.date:SetText(date("%b %d  %H:%M", r.t))
            row.title:SetText((ns.Recap.RowTitle(r)))
            row.played:SetText(Duration(r.p or 0))
            row.levels:SetText(r.l0 == r.l1 and ("Level " .. (r.l0 or "?")) or format("%s to %s", r.l0 or "?", r.l1 or "?"))
            row.kills:SetText(format("%s kill%s", Num(r.k or 0), r.k == 1 and "" or "s"))
        end
        for i = #list + 1, #rows do rows[i]:Hide() end
        child:SetHeight(max(1, #list * EARLIER_ROW))
    end

    local log = CreateFrame("Frame", nil, page)
    log:SetPoint("TOPLEFT", 0, -TAB_ROW - 8)
    log:SetPoint("BOTTOMRIGHT")
    local logPage = ui.LivePage(log)

    function page:Open(key, recap)
        tab = key
        tabs:Select(key, true)
        view:SetShown(key == "this" or key == "last")
        earlier:SetShown(key == "earlier")
        log:SetShown(key == "log")
        started:SetShown(key == "this" or key == "last")
        if key == "last" then
            local r = recap or ns.Recap.Last()
            Show(r, "No earlier session recorded yet.")
        elseif key == "this" then
            drawn = nil
            self:Refresh()
        elseif key == "earlier" then
            RefreshEarlier()
        else
            logPage:Refresh()
        end
    end

    function page:Refresh()
        if tab == "this" then
            local recap = ns.Recap.View()
            if recap ~= drawn then Show(recap, "Not recording yet.") end
        elseif tab == "log" then
            logPage:Refresh()
        end
    end

    page:Open("this")
    return page
end
