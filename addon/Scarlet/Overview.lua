-- Overview.lua: the Character page. History comes from the companion's Digest.lua (ScarletDigest,
-- every session up to `through`) and from the rows the addon sums itself (ScarletDB.chars[key].ov,
-- see docs/OVERVIEW.md); the open session is added live. Built by UI.lua, refreshed only while shown.
local _, ns = ...

local floor, format, max, abs = math.floor, string.format, math.max, math.abs
local Plain = ns.Plain

local CARD_H, CARD_GAP, CARD_TOP, ROW_H, ROWS = 104, 10, 70, 19, 4
local MATES, DEATHS = 3, 3

-- Readers for client values: a secret, missing or mistyped value reads as nil.
local function CNum(v)
    if Plain(v) and type(v) == "number" then return v end
end

local function CStr(v)
    if Plain(v) and type(v) == "string" and v ~= "" then return v end
end

-- Numbers out of SavedVariables and the digest: anything else counts as 0.
local function N(v)
    if type(v) == "number" and v == v and v > -1e15 and v < 1e15 then return v end
    return 0
end

-- Data -----------------------------------------------------------------------------

-- Monday 00:00 local time of this week.
local function WeekStart()
    local d = date("*t")
    d.day = d.day - (d.wday - 2) % 7
    d.hour, d.min, d.sec, d.isdst = 0, 0, 0, nil
    return time(d)
end

local function DigestFor(key)
    local d = _G.ScarletDigest
    if type(d) ~= "table" or type(d.chars) ~= "table" then return end
    local c = d.chars[key]
    if type(c) == "table" then return c end
end

local function AddWeek(b, row)
    b.wp = b.wp + N(row.p)
    b.wq = b.wq + N(row.q)
    b.wg = b.wg + N(row.g)
    b.ws = b.ws + N(row.s)
    b.wr = b.wr + N(row.r)
end

-- A level's share, in the digest's levels table and in a session row's lv table (same keys).
local function AddLevel(b, s)
    if type(s) ~= "table" then return end
    b.lp = b.lp + N(s.p)
    b.lxk = b.lxk + N(s.xk) + N(s.xd)
    b.lxq = b.lxq + N(s.xq)
    b.lk = b.lk + N(s.k)
    b.ldd = b.ldd + N(s.dd)
end

-- The n largest values of map, largest first, ties by name.
local function Top(map, n, names, vals)
    for i = 1, n do names[i], vals[i] = nil, nil end
    for i = 1, n do
        local bn, bv
        for name, v in pairs(map) do
            if v > 0 and (bv == nil or v > bv or (v == bv and name < bn)) then
                local used = false
                for j = 1, i - 1 do
                    if names[j] == name then used = true end
                end
                if not used then bn, bv = name, v end
            end
        end
        if not bn then break end
        names[i], vals[i] = bn, bv
    end
end

-- Everything that does not change while the window is open: the digest's sessions up to
-- `through`, the addon's closed rows after it. The open session is added on each refresh.
local function Collect(key, lvl, weekStart)
    local b = { key = key, level = lvl, weekStart = weekStart, wp = 0, wq = 0, wg = 0, ws = 0, wr = 0,
        lp = 0, lxk = 0, lxq = 0, lk = 0, ldd = 0, zd = {}, mn = {}, mv = {}, dt = {} }
    local d = DigestFor(key)
    local through = -1
    local mates = {}
    if d then
        through = N(d.through)
        if type(d.sessions) == "table" then
            for _, row in ipairs(d.sessions) do
                if type(row) == "table" then
                    local t = N(row.t)
                    if t >= weekStart and t <= through then
                        AddWeek(b, row)
                        b.dt[#b.dt + 1] = t
                    end
                end
            end
        end
        if lvl and type(d.levels) == "table" then AddLevel(b, d.levels[lvl]) end
        if type(d.deathZones) == "table" then
            for _, z in ipairs(d.deathZones) do
                if type(z) == "table" and type(z.name) == "string" then b.zd[z.name] = (b.zd[z.name] or 0) + N(z.n) end
            end
        end
        if type(d.mates) == "table" then
            for _, m in ipairs(d.mates) do
                if type(m) == "table" and type(m.name) == "string" then mates[m.name] = N(m.p) end
            end
        end
        b.zone, b.class, b.level0 = d.zone, d.class, d.level
    end
    local o = ns.char and ns.char.ov
    if type(o) == "table" and type(o.sess) == "table" then
        for _, row in ipairs(o.sess) do
            local t = type(row) == "table" and N(row.t) or 0
            -- A week row the digest does not hold (it ends at the last export, or lost a session).
            if t <= through + 3 and t >= weekStart then
                local held = false
                for i = 1, #b.dt do
                    if abs(b.dt[i] - t) <= 3 then held = true; break end
                end
                if not held then AddWeek(b, row) end
            end
            -- Two keys within 3 seconds are one session; the digest already has it.
            if t > through + 3 then
                if N(row.t) >= weekStart then AddWeek(b, row) end
                if lvl and type(row.lv) == "table" then AddLevel(b, row.lv[lvl]) end
                if type(row.zn) == "table" then
                    for name, z in pairs(row.zn) do
                        if type(name) == "string" and type(z) == "table" then
                            b.zd[name] = (b.zd[name] or 0) + N(z.dd)
                        end
                    end
                end
            end
        end
    end
    -- The addon's own totals for who you grouped with also hold what the digest has not seen yet;
    -- they cover the same time, so the larger of the two is used, not the sum.
    -- Rows fell off the end of the addon's list before the digest held them: older history is short.
    b.short = d ~= nil and type(o) == "table" and type(o.sess) == "table" and #o.sess >= ns.Ov.ROWS
        and type(o.sess[1]) == "table" and N(o.sess[1].t) > through + 3 or false
    local own = ns.char and ns.char.mates
    if type(own) == "table" then
        for name, m in pairs(own) do
            if type(name) == "string" and type(m) == "table" then mates[name] = max(mates[name] or 0, N(m.secs)) end
        end
    end
    Top(mates, MATES, b.mn, b.mv)
    return b
end

-- Page -----------------------------------------------------------------------------

function ns.OverviewPage(parent, ui)
    local T, Fill, Border, Text = ui.T, ui.Fill, ui.Border, ui.Text
    local Num, Money, Duration = ui.Num, ui.Money, ui.Duration

    local page = CreateFrame("Frame", nil, parent)
    page:SetAllPoints()

    local name = Text(page, 20, T.fg)
    name:SetPoint("TOPLEFT")
    local where = Text(page, 13, T.muted, "RIGHT")
    where:SetPoint("TOPRIGHT", 0, -5)

    local bar = CreateFrame("Frame", nil, page)
    bar:SetHeight(6)
    bar:SetPoint("TOPLEFT", 0, -34)
    bar:SetPoint("TOPRIGHT", 0, -34)
    Fill(bar, T.grey):SetAllPoints()
    local barFill = Fill(bar, T.accent, 1, "ARTWORK")
    barFill:SetPoint("TOPLEFT")
    barFill:SetPoint("BOTTOMLEFT")
    barFill:SetWidth(1)
    local progress = Text(page, 12, T.muted)
    progress:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -6)

    local function Card(col, row, title)
        local c = CreateFrame("Frame", nil, page)
        c:SetHeight(CARD_H)
        local y = -CARD_TOP - row * (CARD_H + CARD_GAP)
        if col == 0 then
            c:SetPoint("TOPLEFT", 0, y)
            c:SetPoint("TOPRIGHT", page, "TOP", -CARD_GAP / 2, y)
        else
            c:SetPoint("TOPLEFT", page, "TOP", CARD_GAP / 2, y)
            c:SetPoint("TOPRIGHT", 0, y)
        end
        Fill(c, T.card):SetAllPoints()
        Border(c, T.line, 0.8)
        local rail = Fill(c, T.accent, 0.9, "ARTWORK")
        rail:SetPoint("TOPLEFT", 1, -1)
        rail:SetPoint("BOTTOMLEFT", 1, 1)
        rail:SetWidth(2)
        c.title = Text(c, 13, T.accent)
        c.title:SetPoint("TOPLEFT", 14, -10)
        c.title:SetText(title)
        c.left, c.right = {}, {}
        for i = 1, ROWS do
            local l = Text(c, 12, T.fg)
            l:SetPoint("TOPLEFT", 14, -30 - (i - 1) * ROW_H)
            l:SetWidth(170)
            local r = Text(c, 12, T.muted, "RIGHT")
            r:SetPoint("TOPRIGHT", -12, -30 - (i - 1) * ROW_H)
            r:SetWidth(100)
            c.left[i], c.right[i] = l, r
        end
        c.empty = Text(c, 12, T.muted)
        c.empty:SetPoint("TOPLEFT", 14, -30)
        c.empty:Hide()
        -- Row i shows label and value; rows after the last one given are cleared.
        function c:Set(i, label, value)
            self.left[i]:SetText(label or "")
            self.right[i]:SetText(value or "")
        end
        function c:Rows(count, emptyText)
            for i = count + 1, ROWS do self:Set(i) end
            self.empty:SetText(emptyText or "")
            self.empty:SetShown(count == 0 and emptyText ~= nil)
        end
        return c
    end

    local week = Card(0, 0, "This week")
    local lvlCard = Card(1, 0, "")
    local mates = Card(0, 1, "Played with")
    local deaths = Card(1, 1, "Deaths")

    local footer = Text(page, 12, T.muted)
    footer:SetPoint("TOPLEFT", 0, -CARD_TOP - 2 * (CARD_H + CARD_GAP) - 2)

    local base
    local deathMap, deathNames, deathVals = {}, {}, {}

    function page:Refresh()
        local key = ns.charKey
        if not key then return end
        local lvl = CNum(UnitLevel("player"))
        local weekStart = WeekStart()
        if not base or base.key ~= key or base.level ~= lvl or base.weekStart ~= weekStart then
            base = Collect(key, lvl, weekStart)
        end
        local live = ns.Ov.Live()
        footer:SetText(base.short
            and "History through the last export, older sessions missing · |cff6fbf73this session live|r"
            or "History through the last export · |cff6fbf73this session live|r")

        -- Header
        local _, classFile = UnitClass("player")
        classFile = CStr(classFile) or base.class
        local color = classFile and _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[classFile] or T.fg
        name:SetText(key)
        name:SetTextColor(color.r or color[1], color.g or color[2], color.b or color[3])
        lvl = lvl or (type(base.level0) == "number" and base.level0) or nil
        local zone = CStr(GetRealZoneText()) or (type(base.zone) == "string" and base.zone) or nil
        if lvl and zone then
            where:SetText(format("Level %d · %s", lvl, zone))
        else
            where:SetText(lvl and format("Level %d", lvl) or (zone or ""))
        end

        local lv = live and lvl and live.lv[lvl]
        local levelTime = base.lp + (lv and N(lv.p) or 0)
        local xp, xpMax = CNum(UnitXP("player")), CNum(UnitXPMax("player"))
        if xp and xpMax and xpMax > 0 then
            local ratio = math.min(1, max(0, xp / xpMax))
            barFill:SetWidth(max(1, ratio * (bar:GetWidth() or 0)))
            local text = format("%d%% to %d", floor(ratio * 100), (lvl or 0) + 1)
            if levelTime > 0 then text = text .. " · this level " .. Duration(levelTime) .. " so far" end
            progress:SetText(text)
        else
            barFill:SetWidth(1)
            progress:SetText(levelTime > 0 and ("This level " .. Duration(levelTime) .. " so far") or "")
        end

        -- This week
        local wp, wq, wg, ws, wr = base.wp, base.wq, base.wg, base.ws, base.wr
        if live and N(live.t) >= base.weekStart then
            wp, wq, wg, ws, wr = wp + N(live.p), wq + N(live.q), wg + N(live.g), ws + N(live.s), wr + N(live.r)
        end
        local net = wg - ws
        week:Set(1, "Played", Duration(wp))
        week:Set(2, "Quests", Num(wq))
        week:Set(3, "Gold", net < 0 and ("-" .. Money(-net)) or ("+" .. Money(net)))
        week:Set(4, "Dungeons", Num(wr))
        week:Rows(4)

        -- The level so far
        local xk, xq, kills, dead = base.lxk, base.lxq, base.lk, base.ldd
        if lv then
            xk, xq = xk + N(lv.xk) + N(lv.xd), xq + N(lv.xq)
            kills, dead = kills + N(lv.k), dead + N(lv.dd)
        end
        lvlCard.title:SetText(lvl and format("Level %d so far", lvl) or "This level so far")
        lvlCard:Set(1, "XP from kills", Num(xk))
        lvlCard:Set(2, "XP from quests", Num(xq))
        lvlCard:Set(3, "Kills", Num(kills))
        lvlCard:Set(4, "Deaths", Num(dead))
        lvlCard:Rows(4)

        -- Played with
        local shown = 0
        for i = 1, MATES do
            if base.mn[i] then
                shown = i
                mates:Set(i, base.mn[i], Duration(base.mv[i]))
            end
        end
        mates:Rows(shown, "No groups recorded")

        -- Deaths: top zones
        wipe(deathMap)
        for zname, n in pairs(base.zd) do deathMap[zname] = n end
        if live then
            for zname, z in pairs(live.zn) do
                if type(z) == "table" and N(z.dd) > 0 then deathMap[zname] = (deathMap[zname] or 0) + z.dd end
            end
        end
        Top(deathMap, DEATHS, deathNames, deathVals)
        shown = 0
        for i = 1, DEATHS do
            if deathNames[i] then
                shown = i
                deaths:Set(i, deathNames[i], Num(deathVals[i]))
            end
        end
        deaths:Rows(shown, "No deaths recorded")
    end

    -- A new look at the data when the page opens.
    page:SetScript("OnShow", function() base = nil end)
    return page
end
