local _, ns = ...

local floor, format, max, min = math.floor, string.format, math.max, math.min
local lower, find = string.lower, string.find
local Plain = ns.Plain

local PAGE_W, TAB_ROW = 655, 40
local CHAR_TABS = { { key = "characters", label = "Characters" }, { key = "estimates", label = "Estimates" },
    { key = "imported", label = "Imported" } }
local CHAR_TAB = { characters = true, estimates = true, imported = true }
local ROW_H, HEAD_H, SECTION_GAP, STAT_H = 26, 20, 30, 62
local TITLE_H = 36

local CHARS = {
    { x = 0, w = 180 }, { x = 184, w = 36, just = "RIGHT" }, { x = 232, w = 140 },
    { x = 380, w = 78, just = "RIGHT" }, { x = 466, w = 78, just = "RIGHT" }, { x = 552, w = 103, just = "RIGHT" },
}
local CHARS_ACCOUNT = {
    { x = 0, w = 150 }, { x = 154, w = 88 }, { x = 246, w = 32, just = "RIGHT" }, { x = 284, w = 110 },
    { x = 398, w = 76, just = "RIGHT" }, { x = 480, w = 70, just = "RIGHT" }, { x = 556, w = 99, just = "RIGHT" },
}
local WEEK = {
    { x = 0, w = 180 }, { x = 190, w = 90, just = "RIGHT" }, { x = 290, w = 70, just = "RIGHT" },
    { x = 370, w = 140, just = "RIGHT" }, { x = 520, w = 80, just = "RIGHT" },
}
local ETA = { { x = 0, w = 180 }, { x = 190, w = 110 }, { x = 310, w = 90, just = "RIGHT" }, { x = 420, w = 230 } }
local TOGETHER = {
    { x = 0, w = 170 }, { x = 176, w = 170 }, { x = 352, w = 90, just = "RIGHT" },
    { x = 448, w = 90, just = "RIGHT" }, { x = 544, w = 111, just = "RIGHT" },
}

local function N(v)
    if type(v) == "number" and v == v and v > -1e15 and v < 1e15 then return v end
    return 0
end

local function CNum(v)
    if Plain(v) and type(v) == "number" then return v end
end

local function CStr(v)
    if Plain(v) and type(v) == "string" and v ~= "" then return v end
end

local ITEMS = {
    { x = 0, w = 240 }, { x = 250, w = 170 }, { x = 430, w = 100, just = "RIGHT" }, { x = 540, w = 115, just = "RIGHT" },
}
local IMPORTED = {
    { x = 0, w = 170 }, { x = 176, w = 100 }, { x = 282, w = 70, just = "RIGHT" }, { x = 358, w = 100, just = "RIGHT" },
    { x = 466, w = 70, just = "RIGHT" }, { x = 542, w = 113, just = "RIGHT" },
}
local IMPORTED_DAYS = {
    { x = 0, w = 120 }, { x = 130, w = 90, just = "RIGHT" }, { x = 230, w = 140, just = "RIGHT" },
    { x = 380, w = 90, just = "RIGHT" }, { x = 480, w = 175, just = "RIGHT" },
}
local IMPORTED_ITEMS = {
    { x = 0, w = 260 }, { x = 270, w = 80, just = "RIGHT" }, { x = 360, w = 100, just = "RIGHT" },
    { x = 470, w = 100, just = "RIGHT" }, { x = 580, w = 75, just = "RIGHT" },
}
local IMPORTED_GOLD = { { x = 0, w = 180 }, { x = 190, w = 180, just = "RIGHT" } }
local MIN_QUERY, MAX_HITS, BOX_H = 2, 100, 28
local LIVE_REDRAW_S, IDLE_REDRAW_S = 5, 30
local IMPORTED_DAYS_SHOWN, IMPORTED_ITEMS_SHOWN, IMPORTED_GOLD_SHOWN = 14, 12, 14

local imported = {}

local rows, pairsList = {}, {}
local liveBags = {}
local grouped, severalAccounts = false, false

local function Span(secs)
    local m = max(1, floor(secs / 60 + 0.5))
    local d, h = floor(m / 1440), floor(m % 1440 / 60)
    if d > 0 then return format("%dd %dh", d, h) end
    if h > 0 then return format("%dh %dm", h, m % 60) end
    return format("%dm", m)
end

local function AddWeek(r, row)
    r.wp, r.wq, r.wg = r.wp + N(row.p), r.wq + N(row.q), r.wg + N(row.g) - N(row.s)
    r.wr = r.wr + N(row.r)
end

local function Gather(key, c, ch, weekStart, folderOf, here)
    local r = { key = key, wp = 0, wq = 0, wg = 0, wr = 0, played = 0, last = 0, live = key == ns.charKey }
    r.account = folderOf[key]
    r.here = type(ch) == "table" or (here ~= nil and folderOf[key] == here)
    local through = -1
    if type(c) == "table" then
        r.class, r.level, r.zone, r.played = c.class, N(c.level), c.zone, N(c.played)
        r.known = r.played > 0
        r.money = type(c.money) == "number" and c.money or nil
        r.xp, r.xpMax = N(c.xp), N(c.xpMax)
        through = N(c.through)
        local newest = type(c.sessions) == "table" and c.sessions[1]
        r.last = through + (type(newest) == "table" and N(newest.p) or 0)
        if type(c.days) == "table" then
            for _, day in ipairs(c.days) do
                if type(day) == "table" and N(day.d) >= weekStart then AddWeek(r, day) end
            end
        elseif type(c.sessions) == "table" then
            for _, s in ipairs(c.sessions) do
                if type(s) == "table" and N(s.t) >= weekStart and N(s.t) <= through then AddWeek(r, s) end
            end
        end
    end
    local o = type(ch) == "table" and ch.ov
    if type(o) == "table" and type(o.sess) == "table" then
        for _, s in ipairs(o.sess) do
            if type(s) == "table" then
                local t = N(s.t)
                if t > through + 3 then
                    if r.known then r.played = r.played + N(s.p) end
                    if type(s.m) == "number" then r.money = s.m end
                    if N(s.l1) > 0 then r.level = s.l1 end
                    r.last = max(r.last, t + N(s.p))
                    if t >= weekStart then AddWeek(r, s) end
                end
            end
        end
    end
    if not r.known and type(ch) == "table" and N(ch.played) > 0 then
        r.played, r.known, r.counter, r.readAt = ch.played, true, true, N(ch.playedAt)
    end
    return r
end

local function ByOrder(a, b)
    if grouped then
        if a.here ~= b.here then return a.here end
    elseif a.live ~= b.live then
        return a.live
    end
    if a.last ~= b.last then return a.last > b.last end
    return a.key < b.key
end

local function Estimate(r)
    local lvl, secs, when, cap
    if r.live then
        local level = CNum(UnitLevel("player"))
        local xp, xpMax
        if ns.Cap.Levelling() then xp, xpMax = CNum(UnitXP("player")), CNum(UnitXPMax("player")) end
        lvl, secs, when, cap = ns.CapEstimate(r.key, level, xp, xpMax, ns.Ov.Live())
        r.etaLevel = level
    else
        lvl, secs, when, cap = ns.CapEstimate(r.key)
    end
    r.eta = lvl and { level = lvl, secs = secs, when = when, cap = cap } or nil
end

local function Collect()
    wipe(rows)
    wipe(pairsList)
    local d = _G.ScarletDigest
    local chars = type(d) == "table" and type(d.chars) == "table" and d.chars or {}
    local mine = ns.db and ns.db.chars or {}
    local folderOf = {}
    if type(d) == "table" and type(d.accounts) == "table" then
        for folder, list in pairs(d.accounts) do
            if type(list) == "table" then
                for _, name in ipairs(list) do folderOf[name] = folder end
            end
        end
    end
    local here = folderOf[ns.charKey]
    local names = {}
    for key in pairs(chars) do names[key] = true end
    for key in pairs(mine) do names[key] = true end
    if ns.charKey then names[ns.charKey] = true end
    local weekStart = ns.WeekStart()
    grouped = type(d) == "table" and d.groupByAccount == true
    local firstAccount
    severalAccounts = false
    for key in pairs(names) do
        if type(key) == "string" then
            local r = Gather(key, chars[key], mine[key], weekStart, folderOf, here)
            Estimate(r)
            rows[#rows + 1] = r
            if r.account then
                firstAccount = firstAccount or r.account
                if r.account ~= firstAccount then severalAccounts = true end
            end
        end
    end
    table.sort(rows, ByOrder)

    wipe(imported)
    for _, r in ipairs(rows) do
        local c = chars[r.key]
        local v = type(c) == "table" and c.imported
        if type(v) == "table" and type(v.sources) == "table" and #v.sources > 0 then
            imported[#imported + 1] = { key = r.key, v = v }
        end
    end

    local seen = {}
    for key, c in pairs(chars) do
        if type(c) == "table" and type(c.alts) == "table" then
            for _, a in ipairs(c.alts) do
                if type(a) == "table" and type(a.name) == "string" then
                    local lo, hi = key, a.name
                    if hi < lo then lo, hi = hi, lo end
                    local id = lo .. "\n" .. hi
                    local p = seen[id]
                    if not p then
                        p = { a = lo, b = hi, o = 0, p = 0, last = 0 }
                        seen[id] = p
                        pairsList[#pairsList + 1] = p
                    end
                    p.o, p.p, p.last = max(p.o, N(a.o)), max(p.p, N(a.p)), max(p.last, N(a.last))
                end
            end
        end
    end
    table.sort(pairsList, function(x, y)
        if x.o ~= y.o then return x.o > y.o end
        if x.p ~= y.p then return x.p > y.p end
        return x.a .. x.b < y.a .. y.b
    end)
end

local function AddHits(hits, key, bags, bank, names, query, want)
    local seen = {}
    for _, list in ipairs({ bags, bank }) do
        for id in pairs(list) do
            if type(id) == "number" and not seen[id] then
                seen[id] = true
                local name = names[id]
                if not name and C_Item and C_Item.GetItemNameByID then name = CStr(C_Item.GetItemNameByID(id)) end
                if id == want or (name and find(lower(name), query, 1, true)) then
                    local b, k = N(bags[id]), N(bank[id])
                    hits[#hits + 1] = { id = id, name = name or ("Item " .. id), key = key, bags = b, bank = k,
                        total = b + k }
                end
            end
        end
    end
end

local function Find(query)
    local data = _G.ScarletItems
    local ok = type(data) == "table"
    local names = ok and type(data.names) == "table" and data.names or {}
    local stored = ok and type(data.chars) == "table" and data.chars or {}
    local want = tonumber(query)
    local keys = {}
    for key in pairs(stored) do keys[key] = true end
    if ns.charKey then keys[ns.charKey] = true end
    local hits = {}
    for key in pairs(keys) do
        if type(key) == "string" then
            local c = type(stored[key]) == "table" and stored[key] or {}
            local bags = type(c.b) == "table" and c.b or {}
            local bank = type(c.k) == "table" and c.k or {}
            if key == ns.charKey and ns.CountBags then
                ns.CountBags(liveBags)
                bags = liveBags
            end
            AddHits(hits, key, bags, bank, names, query, want)
        end
    end
    table.sort(hits, function(a, b)
        local x, y = lower(a.name), lower(b.name)
        if x ~= y then return x < y end
        if a.id ~= b.id then return a.id < b.id end
        if a.total ~= b.total then return a.total > b.total end
        return a.key < b.key
    end)
    return hits
end

local function Tint(fs, class, fallback)
    local c = class and _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[class]
    if c then fs:SetTextColor(c.r, c.g, c.b) else fs:SetTextColor(fallback[1], fallback[2], fallback[3]) end
end

local function ClassOf(key)
    if key == ns.charKey then
        local _, class = UnitClass("player")
        if CStr(class) then return class end
    end
    local d = _G.ScarletDigest
    local c = type(d) == "table" and type(d.chars) == "table" and d.chars[key]
    return type(c) == "table" and c.class or nil
end

local function Flow(ui, child)
    local T, Fill, Hair, Text = ui.T, ui.Fill, ui.Hair, ui.Text
    local flow = { y = 0 }

    function flow.Section(title, spec, labels)
        local sec = { spec = spec, rows = {} }
        if title then
            sec.title = Text(child, 24, T.fg, "LEFT", "display")
            sec.title:SetText(title)
        end
        sec.head = CreateFrame("Frame", nil, child)
        sec.head:SetHeight(HEAD_H)
        for i, label in ipairs(labels) do
            local fs = Text(sec.head, 12, T.muted, spec[i].just)
            fs:SetPoint("LEFT", spec[i].x, 0)
            fs:SetWidth(spec[i].w)
            fs:SetText(label)
        end
        sec.empty = Text(child, 14, T.muted)
        return sec
    end

    local function Line(sec, i)
        local line = sec.rows[i]
        if line then return line end
        local f = CreateFrame("Frame", nil, child)
        f:SetHeight(ROW_H)
        Hair(f, "BOTTOM")
        local wash = Fill(f, T.accent, 0.08)
        wash:SetAllPoints()
        wash:Hide()
        local cols = {}
        for j, c in ipairs(sec.spec) do
            local fs = Text(f, 13, T.text, c.just)
            fs:SetPoint("LEFT", c.x, 0)
            fs:SetWidth(c.w)
            cols[j] = fs
        end
        line = { frame = f, cols = cols, wash = wash }
        f:EnableMouse(true)
        f:SetScript("OnEnter", function(self)
            if line.tipAt then ns.ShowExact(self, line.tipAt, line.tipUtc, "ANCHOR_BOTTOM") end
        end)
        f:SetScript("OnLeave", function() GameTooltip:Hide() end)
        sec.rows[i] = line
        return line
    end

    function flow.Below(frame, gap)
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", 0, flow.y)
        frame:SetPoint("TOPRIGHT", 0, flow.y)
        flow.y = flow.y - gap
    end

    function flow.Open(sec)
        sec.title:ClearAllPoints()
        sec.title:SetPoint("TOPLEFT", 0, flow.y)
        sec.title:Show()
        flow.y = flow.y - TITLE_H
        sec.head:Show()
        flow.Below(sec.head, HEAD_H)
        sec.empty:Hide()
    end

    function flow.Place(sec, i, label)
        local line = Line(sec, i)
        line.frame:Show()
        flow.Below(line.frame, ROW_H)
        line.wash:Hide()
        line.tipAt, line.tipUtc = nil, nil
        for j = 1, #sec.spec do line.cols[j]:SetText("") end
        if label then
            line.cols[1]:SetText(label)
            line.cols[1]:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
        else
            for j = 1, #sec.spec do line.cols[j]:SetTextColor(T.text[1], T.text[2], T.text[3]) end
        end
        return line
    end

    function flow.Close(sec, n, emptyText)
        if n == 0 and emptyText then
            sec.empty:ClearAllPoints()
            sec.empty:SetPoint("TOPLEFT", 0, flow.y)
            sec.empty:SetText(emptyText)
            sec.empty:Show()
            flow.y = flow.y - ROW_H
        end
        flow.y = flow.y - SECTION_GAP
    end

    function flow.Hide(sec)
        if sec.title then sec.title:Hide() end
        sec.head:Hide()
        sec.empty:Hide()
        for _, line in ipairs(sec.rows) do line.frame:Hide() end
    end

    return flow
end

function ns.CharactersPage(parent, ui)
    local T, Text = ui.T, ui.Text
    local Num, Money, Duration = ui.Num, ui.Money, ui.Duration

    local function Signed(copper)
        if copper < 0 then return "-" .. Money(-copper) end
        return "+" .. Money(copper)
    end

    local function Ago(t, now, live)
        if live then return "Now" end
        return ns.Ago(t, now)
    end

    local page = CreateFrame("Frame", nil, parent)
    page:SetAllPoints()
    local tab = "characters"
    local tabs = ui.Tabs(page, CHAR_TABS, function(key) page:Open(key) end)
    tabs:SetPoint("TOPLEFT")
    local scroll, child = ui.Scroll(page, ROW_H * 2)
    scroll:SetPoint("TOPLEFT", 0, -TAB_ROW)
    scroll:SetPoint("BOTTOMRIGHT")

    local flow = Flow(ui, child)
    local Section, Open, Place, Close, Hide = flow.Section, flow.Open, flow.Place, flow.Close, flow.Hide

    local cells = {}
    for i, label in ipairs({ "Characters", "Played", "Gold" }) do
        local cell = CreateFrame("Frame", nil, child)
        cell:SetHeight(STAT_H)
        cell.value = Text(cell, 32, T.fg, "LEFT", "display")
        cell.value:SetPoint("TOPLEFT", 0, 0)
        cell.label = Text(cell, 13, T.muted)
        cell.label:SetPoint("TOPLEFT", 0, -38)
        cell.label:SetText(label)
        cells[i] = cell
    end

    local charSec = Section("Character list", CHARS, { "Character", "Level", "Zone", "Played", "Last played", "Gold" })
    local charAccountSec = Section("Character list", CHARS_ACCOUNT,
        { "Character", "Game account", "Level", "Zone", "Played", "Last played", "Gold" })
    local weekSec = Section("This week", WEEK, { "Character", "Played", "Quests", "Gold", "Dungeons" })
    local etaSec = Section("Level estimates", ETA, { "Character", "Level", "Time", "Date" })
    local togetherSec = Section("Played together", TOGETHER,
        { "Character", "Character", "Online together", "Grouped", "Last" })
    local impSec = Section("Imported history", IMPORTED,
        { "Character", "Source", "Sales", "Sold for", "Purchases", "Bought for" })
    local impDaysSec = Section("Imported sales by day", IMPORTED_DAYS, { "Day", "Sold", "Sold for", "Bought", "Bought for" })
    local impItemsSec = Section("Imported item prices", IMPORTED_ITEMS, { "Item", "Sold", "Lowest", "Highest", "Bought" })
    local impGoldSec = Section("Imported gold by day", IMPORTED_GOLD, { "Day", "Gold at the end of the day" })
    local note = Text(child, 14, T.muted)

    local sectionsOf = {
        characters = { charSec, charAccountSec, weekSec },
        estimates = { etaSec, togetherSec },
        imported = { impSec, impDaysSec, impItemsSec, impGoldSec },
    }

    local shown = {}

    local function Show(r, live, weekStart)
        local s = shown[r] or {}
        shown[r] = s
        s.played, s.money, s.level, s.zone = r.played, r.money, r.level, r.zone
        s.known = r.known == true
        s.wp, s.wq, s.wg, s.wr = r.wp, r.wq, r.wg, r.wr
        if r.live then
            local level, money, zone = CNum(UnitLevel("player")), CNum(GetMoney()), CStr(GetRealZoneText())
            s.level, s.money, s.zone = level or s.level, money or s.money, zone or s.zone
            if r.counter and r.readAt > 0 then s.played = s.played + max(0, time() - r.readAt) end
            if live then
                if s.known and not r.counter then s.played = s.played + N(live.p) end
                if N(live.t) >= weekStart then
                    s.wp, s.wq, s.wg, s.wr = s.wp + N(live.p), s.wq + N(live.q), s.wg + N(live.g) - N(live.s),
                        s.wr + N(live.r)
                end
            end
            local _, class = UnitClass("player")
            s.class = CStr(class) or r.class
        else
            s.class = r.class
        end
        return s
    end

    local function DrawCharacters(list, now)
        local n, played, gold = #rows, 0, 0
        for i = 1, n do
            if list[i].known then played = played + list[i].played end
            gold = gold + N(list[i].money)
        end
        cells[1].value:SetText(Num(n))
        cells[2].value:SetText(Duration(played))
        cells[3].value:SetText(Money(gold))
        local width = scroll:GetWidth()
        local cw = floor((width and width > 1 and width or PAGE_W) / 3)
        for i, cell in ipairs(cells) do
            cell:ClearAllPoints()
            cell:SetPoint("TOPLEFT", (i - 1) * cw, 0)
            cell:SetWidth(cw)
            cell:Show()
        end
        flow.y = -(STAT_H + SECTION_GAP)

        local withAccount = severalAccounts and not grouped
        local listSec, unusedSec = charSec, charAccountSec
        if withAccount then listSec, unusedSec = charAccountSec, charSec end
        Hide(unusedSec)
        Open(listSec)
        local count, group = 0, nil
        local both = false
        for _, r in ipairs(rows) do
            if r.here ~= rows[1].here then both = true end
        end
        for i, r in ipairs(rows) do
            if grouped and both and r.here ~= group then
                group = r.here
                count = count + 1
                Place(listSec, count, group and "This account" or "Other accounts")
            end
            local s = list[i]
            count = count + 1
            local line = Place(listSec, count)
            local c = line.cols
            c[1]:SetText(ns.DisplayName(r.key))
            Tint(c[1], s.class, T.fg)
            local at = 2
            if withAccount then
                c[2]:SetText(r.account or "")
                at = 3
            end
            c[at]:SetText(s.level and s.level > 0 and Num(s.level) or "")
            c[at + 1]:SetText(s.zone or "")
            c[at + 2]:SetText(s.known and Duration(s.played) or "")
            c[at + 3]:SetText(Ago(r.last, now, r.live))
            c[at + 4]:SetText(s.money and Money(s.money) or "")
            line.wash:SetShown(r.live)
            if not r.live and r.last > 0 then line.tipAt = r.last end
        end
        for i = #listSec.rows, count + 1, -1 do listSec.rows[i].frame:Hide() end
        Close(listSec, count)

        local week = 0
        Open(weekSec)
        local tp, tq, tg, tr = 0, 0, 0, 0
        for i, r in ipairs(rows) do
            local s = list[i]
            if s.wp > 0 or s.wq > 0 or s.wg ~= 0 or s.wr > 0 then
                week = week + 1
                local c = Place(weekSec, week).cols
                c[1]:SetText(ns.DisplayName(r.key))
                Tint(c[1], s.class, T.fg)
                c[2]:SetText(Duration(s.wp))
                c[3]:SetText(Num(s.wq))
                c[4]:SetText(Signed(s.wg))
                c[5]:SetText(Num(s.wr))
                tp, tq, tg, tr = tp + s.wp, tq + s.wq, tg + s.wg, tr + s.wr
            end
        end
        if week > 1 then
            week = week + 1
            local c = Place(weekSec, week).cols
            c[1]:SetText("All characters")
            c[1]:SetTextColor(T.fg[1], T.fg[2], T.fg[3])
            c[2]:SetText(Duration(tp))
            c[3]:SetText(Num(tq))
            c[4]:SetText(Signed(tg))
            c[5]:SetText(Num(tr))
        end
        for i = #weekSec.rows, week + 1, -1 do weekSec.rows[i].frame:Hide() end
        Close(weekSec, week, "No play recorded this week")
    end

    local function DrawEstimates(list, now)
        local etas = {}
        for i, r in ipairs(rows) do
            if r.eta then etas[#etas + 1] = { r = r, s = list[i] } end
        end
        table.sort(etas, function(a, b) return a.r.eta.secs < b.r.eta.secs end)
        if #etas > 0 then
            Open(etaSec)
            for i, e in ipairs(etas) do
                local eta = e.r.eta
                local c = Place(etaSec, i).cols
                c[1]:SetText(ns.DisplayName(e.r.key))
                Tint(c[1], e.s.class, T.fg)
                c[2]:SetText(format("%d to %d", eta.level, eta.cap))
                c[3]:SetText(Span(eta.secs))
                c[4]:SetText(eta.when and ("about " .. eta.when) or "")
            end
            for i = #etaSec.rows, #etas + 1, -1 do etaSec.rows[i].frame:Hide() end
            Close(etaSec, #etas)
        else
            Hide(etaSec)
        end

        if #pairsList > 0 then
            Open(togetherSec)
            for i, p in ipairs(pairsList) do
                local line = Place(togetherSec, i)
                local c = line.cols
                c[1]:SetText(ns.DisplayName(p.a))
                c[2]:SetText(ns.DisplayName(p.b))
                c[3]:SetText(p.o > 0 and Duration(p.o) or "")
                c[4]:SetText(p.p > 0 and Duration(p.p) or "")
                c[5]:SetText(Ago(p.last, now, false))
                if p.last > 0 then line.tipAt = p.last end
            end
            for i = #togetherSec.rows, #pairsList + 1, -1 do togetherSec.rows[i].frame:Hide() end
            Close(togetherSec, #pairsList)
        else
            Hide(togetherSec)
        end
        return #etas > 0 or #pairsList > 0
    end

    local function DrawImported()
        if #imported == 0 then
            Hide(impSec)
            Hide(impDaysSec)
            Hide(impItemsSec)
            Hide(impGoldSec)
            return false
        end
        local pick = imported[1]
        for _, e in ipairs(imported) do
            if e.key == ns.charKey then pick = e end
        end
        local v = pick.v
        local source = table.concat(v.sources, " and ")
        impSec.title:SetText("Imported from " .. source)
        Open(impSec)
        for i, e in ipairs(imported) do
            local c = Place(impSec, i).cols
            c[1]:SetText(ns.DisplayName(e.key))
            c[2]:SetText(table.concat(e.v.sources, " and "))
            c[3]:SetText(Num(N(e.v.sales)))
            c[4]:SetText(Money(N(e.v.sales_copper)))
            c[5]:SetText(Num(N(e.v.buys)))
            c[6]:SetText(Money(N(e.v.buys_copper)))
        end
        for i = #impSec.rows, #imported + 1, -1 do impSec.rows[i].frame:Hide() end
        Close(impSec, #imported)

        local days = type(v.days) == "table" and v.days or {}
        local shownDays = 0
        impDaysSec.title:SetText(format("%s: sales by day", ns.DisplayName(pick.key)))
        Open(impDaysSec)
        for _, d in ipairs(days) do
            if type(d) == "table" and shownDays < IMPORTED_DAYS_SHOWN then
                shownDays = shownDays + 1
                local line = Place(impDaysSec, shownDays)
                local c = line.cols
                c[1]:SetText(ns.Day(N(d.d), false, true))
                if N(d.d) > 0 then line.tipAt, line.tipUtc = N(d.d), true end
                c[2]:SetText(Num(N(d.sold)))
                c[3]:SetText(Money(N(d.sold_copper)))
                c[4]:SetText(Num(N(d.bought)))
                c[5]:SetText(Money(N(d.bought_copper)))
            end
        end
        for i = #impDaysSec.rows, shownDays + 1, -1 do impDaysSec.rows[i].frame:Hide() end
        Close(impDaysSec, shownDays)

        local items = type(v.items) == "table" and v.items or {}
        local shownItems = 0
        impItemsSec.title:SetText(format("%s: item prices", ns.DisplayName(pick.key)))
        Open(impItemsSec)
        for _, it in ipairs(items) do
            if type(it) == "table" and N(it.sold) > 0 and shownItems < IMPORTED_ITEMS_SHOWN then
                shownItems = shownItems + 1
                local id = N(it.id)
                local name = CStr(it.name)
                if not name and id > 0 and C_Item and C_Item.GetItemNameByID then
                    name = CStr(C_Item.GetItemNameByID(id))
                end
                local c = Place(impItemsSec, shownItems).cols
                c[1]:SetText(name or ("Item " .. id))
                c[2]:SetText(Num(N(it.sold)))
                c[3]:SetText(Money(N(it.low)))
                c[4]:SetText(Money(N(it.high)))
                c[5]:SetText(N(it.bought) > 0 and Num(N(it.bought)) or "")
            end
        end
        for i = #impItemsSec.rows, shownItems + 1, -1 do impItemsSec.rows[i].frame:Hide() end
        Close(impItemsSec, shownItems)

        local gold = type(v.gold) == "table" and v.gold or {}
        local shownGold = 0
        impGoldSec.title:SetText(format("%s: gold by day", ns.DisplayName(pick.key)))
        Open(impGoldSec)
        for i = #gold, 1, -1 do
            local g = gold[i]
            if type(g) == "table" and shownGold < IMPORTED_GOLD_SHOWN then
                shownGold = shownGold + 1
                local line = Place(impGoldSec, shownGold)
                local c = line.cols
                c[1]:SetText(ns.Day(N(g.t), false, true))
                if N(g.t) > 0 then line.tipAt, line.tipUtc = N(g.t), true end
                c[2]:SetText(Money(N(g.m)))
            end
        end
        for i = #impGoldSec.rows, shownGold + 1, -1 do impGoldSec.rows[i].frame:Hide() end
        Close(impGoldSec, shownGold)
        return true
    end

    local stamp
    local function Draw(force)
        local live = ns.Ov.Live()
        local weekStart = ns.WeekStart()
        local level, money = CNum(UnitLevel("player")) or 0, CNum(GetMoney()) or 0
        local sig = format("%s:%d:%d:%d:%d:%d", tab, floor(N(live and live.p) / 15), money, level, #rows,
            floor(time() / 30))
        if not force and sig == stamp then return end
        stamp = sig
        local now = time()
        for _, r in ipairs(rows) do
            if r.live and r.etaLevel ~= level then Estimate(r) end
        end
        local list = {}
        for i, r in ipairs(rows) do list[i] = Show(r, live, weekStart) end

        for key, secs in pairs(sectionsOf) do
            if key ~= tab then
                for _, sec in ipairs(secs) do Hide(sec) end
            end
        end
        flow.y = 0
        local filled = true
        if tab == "characters" then
            DrawCharacters(list, now)
        else
            for _, cell in ipairs(cells) do cell:Hide() end
            if tab == "estimates" then
                filled = DrawEstimates(list, now)
            else
                filled = DrawImported()
            end
        end
        note:SetShown(not filled)
        if not filled then
            note:ClearAllPoints()
            note:SetPoint("TOPLEFT", 0, 0)
            note:SetText(tab == "estimates" and "No level estimates or group time recorded" or "No imported history")
            flow.y = -ROW_H
        end
        child:SetHeight(max(1, -flow.y))
    end

    local dirty = true
    function page:Refresh()
        if dirty then
            dirty = false
            Collect()
            scroll:SetVerticalScroll(0)
            Draw(true)
        else
            Draw(false)
        end
    end

    --- Opens one of the tabs: characters, estimates or imported.
    function page:Open(key)
        if not CHAR_TAB[key] then return end
        tab = key
        tabs:Select(key, true)
        dirty = true
        self:Refresh()
    end

    page:SetScript("OnShow", function() dirty = true end)
    return page
end

function ns.ItemsPage(parent, ui)
    local T, Fill, Border, Num = ui.T, ui.Fill, ui.Border, ui.Num

    local page = CreateFrame("Frame", nil, parent)
    page:SetAllPoints()

    local query = ""
    local box = CreateFrame("Frame", nil, page)
    box:SetSize(320, BOX_H)
    box:SetPoint("TOPLEFT", 0, 0)
    Fill(box, T.panel):SetAllPoints()
    Border(box, T.line2)
    local edit = CreateFrame("EditBox", nil, box)
    edit:SetPoint("TOPLEFT", 8, 0)
    edit:SetPoint("BOTTOMRIGHT", -8, 0)
    edit:SetAutoFocus(false)
    edit:SetMaxLetters(40)
    ui.SetFont(edit, ui.Face("body"), 13)
    edit:SetTextColor(T.fg[1], T.fg[2], T.fg[3])
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    local scroll, child = ui.Scroll(page, ROW_H * 2)
    scroll:SetPoint("TOPLEFT", 0, -(BOX_H + 14))
    scroll:SetPoint("BOTTOMRIGHT")
    local flow = Flow(ui, child)
    local findSec = flow.Section(nil, ITEMS, { "Item", "Character", "Bags", "Bank" })

    local stamp
    local function Draw(force)
        local sig = format("%s:%d", query, floor(GetTime() / (#query == 0 and IDLE_REDRAW_S or LIVE_REDRAW_S)))
        if not force and sig == stamp then return end
        stamp = sig
        flow.y = 0
        local hits = (#query == 0 or #query >= MIN_QUERY) and Find(query) or nil
        local found = 0
        findSec.empty:Hide()
        if hits and #hits > 0 then
            findSec.head:Show()
            flow.Below(findSec.head, HEAD_H)
            for i = 1, min(#hits, MAX_HITS) do
                local h = hits[i]
                found = found + 1
                local c = flow.Place(findSec, found).cols
                c[1]:SetText(h.name)
                c[2]:SetText(ns.DisplayName(h.key))
                Tint(c[2], ClassOf(h.key), T.fg)
                c[3]:SetText(h.bags > 0 and Num(h.bags) or "")
                c[4]:SetText(h.bank > 0 and Num(h.bank) or "")
            end
            if #hits > MAX_HITS then
                found = found + 1
                flow.Place(findSec, found, format("Showing %d of %d", MAX_HITS, #hits))
            end
        else
            findSec.head:Hide()
        end
        for i = #findSec.rows, found + 1, -1 do findSec.rows[i].frame:Hide() end
        flow.Close(findSec, found, hits and "No items match" or nil)
        child:SetHeight(max(1, -flow.y))
    end

    edit:SetScript("OnTextChanged", function(self)
        query = lower(self:GetText():match("^%s*(.-)%s*$"))
        if page:IsShown() then
            scroll:SetVerticalScroll(0)
            Draw(true)
        end
    end)

    local dirty = true
    function page:Refresh()
        if dirty then
            dirty = false
            scroll:SetVerticalScroll(0)
            Draw(true)
        else
            Draw(false)
        end
    end

    page:SetScript("OnShow", function() dirty = true end)
    page:SetScript("OnHide", function() edit:ClearFocus() end)
    return page
end
