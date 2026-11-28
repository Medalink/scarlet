-- Overview.lua: the Character page. History comes from the companion's Digest.lua (ScarletDigest,
-- every session up to `through`) and from the rows the addon sums itself (ScarletDB.chars[key].ov,
-- see docs/OVERVIEW.md); the open session is added live. Built by UI.lua, refreshed only while shown.
local _, ns = ...

local floor, format, max, min, abs = math.floor, string.format, math.max, math.min, math.abs
local Plain = ns.Plain

local PANEL_H, PANEL_GAP, ROW_H, ROWS = 132, 10, 22, 4
local DAYS, SPARK_H = 7, 26
local MATES, DEATHS = 3, 3

-- Level estimates, see "Level estimates" in docs/OVERVIEW.md.
local MIN_FIT_LEVELS = 5
local MIN_LEVEL_PLAYED = 900 -- a level needs this much played time to count as a point of the fit
local MAX_GROWTH = math.log(1.05) -- most the pace may rise a level, as a log
local DAY_WINDOW = 14      -- most days the calendar rate is measured over
local MAX_DAYS = 3650      -- a date further away than this is left out
local FALLBACK_CAP = 60    -- the cap when neither the client nor the digest reports one
local FOCUS_SECONDS = 3600 -- played time at the cap before the page leads with max level data
-- NEED[n]: XP that level n needs to reach level n + 1 (the table ends at level 60).
local NEED = { 400, 900, 1400, 2100, 2800, 3600, 4500, 5400, 6500, 7600, 8800, 10100, 11400, 12900, 14400,
    16000, 17700, 19400, 21300, 23200, 25200, 27300, 29400, 31700, 34000, 36400, 38900, 41400, 44300, 47400,
    50800, 54500, 58600, 62800, 67100, 71600, 76100, 80800, 85700, 90700, 95800, 101000, 106300, 111800, 117500,
    123200, 129100, 135100, 141200, 147500, 153900, 160400, 167100, 173900, 180800, 187900, 195000, 202300, 209800 }

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
ns.WeekStart = WeekStart

local function DigestFor(key)
    local d = _G.ScarletDigest
    if type(d) ~= "table" or type(d.chars) ~= "table" then return end
    local c = d.chars[key]
    if type(c) == "table" then return c end
end

-- True for another character of the same player: one this account recorded, or one the companion's
-- digest holds from any account (a player who dual boxes groups their two clients' characters).
-- Such a character is not "someone you played with".
function ns.IsOwnChar(name)
    if type(name) ~= "string" or name == ns.charKey then return false end
    local chars = ns.db and ns.db.chars
    if type(chars) == "table" and type(chars[name]) == "table" then return true end
    local d = _G.ScarletDigest
    return type(d) == "table" and type(d.chars) == "table" and type(d.chars[name]) == "table"
end

-- The digest's totals for the sessions the addon did not record itself (docs/OVERVIEW.md, `before`),
-- for the Stats pages to add to their own counters; nil when the character has none.
local HISTORY_KEYS = { "kills", "deaths", "dungeons", "bosses", "quests", "xp", "earned", "spent", "loot", "tracked" }
function ns.History(key)
    local d = DigestFor(key)
    local before = d and d.before
    if type(before) ~= "table" then return end
    local out = {}
    for _, k in ipairs(HISTORY_KEYS) do out[k] = N(before[k]) end
    return out
end

function ns.LevelFacts(key, level)
    local d = DigestFor(key)
    local dl = d and type(d.levels) == "table" and d.levels[level]
    if type(dl) ~= "table" then dl = nil end
    local chars = ns.db and ns.db.chars
    local ch = key == ns.charKey and ns.char or (type(chars) == "table" and chars[key]) or nil
    local o = type(ch) == "table" and type(ch.ov) == "table" and ch.ov or nil
    local ding = o and type(o.ding) == "table" and o.ding or nil
    local hole = o and type(o.hole) == "table" and o.hole[level] or false
    local seenIn = (dl and dl.whole == true) or (ding and type(ding[level]) == "table") or false
    local whole = seenIn and not hole
    local seenOut = (dl and dl.complete == true) or (ding and type(ding[level + 1]) == "table") or false
    local pd = dl and N(dl.pd) or 0
    if ding and type(ding[level]) == "table" and N(ding[level].p) > 0 then pd = N(ding[level].p) end
    return whole, whole and seenOut, pd
end

function ns.FirstLevel(key)
    local d = DigestFor(key)
    if d and N(d.firstLevel) > 0 then return d.firstLevel end
    local chars = ns.db and ns.db.chars
    local ch = key == ns.charKey and ns.char or (type(chars) == "table" and chars[key]) or nil
    local o = type(ch) == "table" and ch.ov
    return type(o) == "table" and N(o.f0) > 0 and o.f0 or nil
end

local function AddWeek(b, row)
    b.wp = b.wp + N(row.p)
    b.wq = b.wq + N(row.q)
    b.wg = b.wg + N(row.g)
    b.ws = b.ws + N(row.s)
    b.wr = b.wr + N(row.r)
end

local function DayStart()
    local d = date("*t")
    d.hour, d.min, d.sec, d.isdst = 0, 0, 0, nil
    return time(d) - (DAYS - 1) * 86400
end

local function DayOf(t, from)
    return max(1, min(DAYS, floor((t - from) / 86400) + 1))
end

local function AddDay(b, row, t, from)
    local i = DayOf(t, from)
    local d = b.days
    d.p[i] = d.p[i] + N(row.p)
    d.q[i] = d.q[i] + N(row.q)
    d.g[i] = d.g[i] + N(row.g) - N(row.s)
    d.r[i] = d.r[i] + N(row.r)
end

-- The level cap: the client's (ns.Cap, Core.lua), else the one the digest recorded.
local function CapOf(d)
    if ns.Cap.level then return ns.Cap.level end
    local c = d and d.cap
    if type(c) == "table" and type(c.level) == "number" and c.level > 0 then return c.level end
end

-- A level's share, in the digest's levels table and in a session row's lv table (same keys).
local function AddLevel(b, s)
    if type(s) ~= "table" then return end
    b.lp = b.lp + N(s.p)
    b.lxk = b.lxk + N(s.xk) + N(s.xd)
    b.lxq = b.lxq + N(s.xq)
    b.lk = b.lk + N(s.k)
    b.ldd = b.ldd + N(s.dd)
    b.lxe = b.lxe + N(s.xe)
    b.lxo = b.lxo + N(s.xo)
    b.lq = b.lq + N(s.q)
end

-- The share of the cap level: time, gold, runs, kills, deaths, quests.
local CAP_KEYS = { "p", "g", "s", "r", "k", "dd", "q" }
local function AddCap(b, s)
    if type(s) ~= "table" then return end
    for _, k in ipairs(CAP_KEYS) do b.cap[k] = b.cap[k] + N(s[k]) end
end

-- What the levels before the cap held, for the Levelling card: played time and XP by source.
local function AddBelow(b, levels, cap)
    if type(levels) ~= "table" then return end
    for n, s in pairs(levels) do
        if type(n) == "number" and n < cap and type(s) == "table" then
            local t = b.below
            t.p, t.xk, t.xq = t.p + N(s.p), t.xk + N(s.xk) + N(s.xd), t.xq + N(s.xq)
            t.xo = t.xo + N(s.xe) + N(s.xo)
        end
    end
end

-- All XP of a row or a level's share: kills, dungeons, quests, exploration and other.
local function XPOf(row)
    return N(row.xk) + N(row.xd) + N(row.xq) + N(row.xe) + N(row.xo)
end

-- Every level's played seconds and XP, for the level estimates: the same tables, level by level.
local function AddLevels(b, levels)
    if type(levels) ~= "table" then return end
    local top = b.cap.level or FALLBACK_CAP
    for n, s in pairs(levels) do
        if type(n) == "number" and n >= 1 and n < top and n == floor(n) and type(s) == "table" then
            b.levelP[n] = (b.levelP[n] or 0) + N(s.p)
            b.levelX[n] = (b.levelX[n] or 0) + XPOf(s)
        end
    end
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

-- Level estimates -----------------------------------------------------------------

-- Does a row already hold the open session (the same start, within 3 seconds)? Rows are newest first.
local function LiveHeld(rows, live)
    local t = N(live.t)
    for i = 1, #rows do
        local rt = rows[i].t
        if rt < t - 3 then break end
        if rt <= t + 3 then return true end
    end
    return false
end

-- Played seconds of the last DAY_WINDOW days, the open session counting as the newest row.
local function DayPlayed(rows, live, held, now)
    local dayStart, day = now - DAY_WINDOW * 86400, 0
    if live and not held and N(live.t) >= dayStart then day = N(live.p) end
    for i = 1, #rows do
        if rows[i].t >= dayStart then day = day + rows[i].p end
    end
    return day
end

-- The level-weighted pace: XP per played second at level n is exp(a + b * n).
local pace = { a = 0, b = 0, levels = 0, flat = true }
local pn, pp, py = {}, {}, {} -- the levels the fit uses: n, played seconds, ln(XP / played second)

local function FitPace(lp, lx, live, held, lvl, key)
    local lv = live and not held and live.lv
    local count = 0
    for n = 1, lvl do
        local _, complete = ns.LevelFacts(key, n)
        if complete then
            local p, x = lp[n] or 0, lx[n] or 0
            local s = lv and lv[n]
            if type(s) == "table" then p, x = p + N(s.p), x + XPOf(s) end
            if p >= MIN_LEVEL_PLAYED and x > 0 then
                count = count + 1
                pn[count], pp[count], py[count] = n, p, math.log(x / p)
            end
        end
    end
    if count < MIN_FIT_LEVELS then return false end
    local w, sn, sy = 0, 0, 0
    for i = 1, count do
        w, sn, sy = w + pp[i], sn + pp[i] * pn[i], sy + pp[i] * py[i]
    end
    local meanN, meanY = sn / w, sy / w
    local sxx, sxy = 0, 0
    for i = 1, count do
        local dn = pn[i] - meanN
        sxx, sxy = sxx + pp[i] * (dn * dn), sxy + pp[i] * dn * (py[i] - meanY)
    end
    local raw = sxy / sxx
    local b = math.min(math.max(raw, 0), MAX_GROWTH)
    local a
    if b == raw then
        a = meanY - b * meanN
    else
        a = 0
        for i = 1, count do a = a + pp[i] * (py[i] - b * pn[i]) end
        a = a / w
    end
    pace.a, pace.b, pace.levels, pace.flat = a, b, count, b == 0
    return true
end

-- XP per played second at level n.
local function Rate(n) return math.exp(pace.a + pace.b * n) end

-- The levels to show for a character at level lvl: the next, the next multiple of 10, 60.
local function Targets(lvl, out, cap)
    -- NEED ends at level 60: a longer climb is not estimated past it.
    cap = math.min(cap, #NEED + 1)
    if lvl >= cap then return 0 end
    local n = 1
    out[1] = lvl + 1
    local major = (floor(lvl / 10) + 1) * 10
    if major ~= lvl + 1 and major < cap then n = n + 1; out[n] = major end
    if lvl + 1 ~= cap then n = n + 1; out[n] = cap end
    return n
end

-- Played seconds to reach level target, from level lvl with xp of xpMax on the bar, at the fitted pace.
local function SecondsTo(lvl, xp, xpMax, target)
    local secs = max(0, xpMax - xp) / Rate(lvl)
    for n = lvl + 1, target - 1 do secs = secs + (NEED[n] or 0) / Rate(n) end
    return secs
end

-- "3d 4h", "1h 52m", "41m".
local function Span(secs)
    local m = max(1, floor(secs / 60 + 0.5))
    local d, h = floor(m / 1440), floor(m % 1440 / 60)
    if d > 0 then return format("%dd %dh", d, h) end
    if h > 0 then return format("%dh %dm", h, m % 60) end
    return format("%dm", m)
end

-- Everything that does not change while the window is open: the digest's sessions up to
-- `through`, the addon's closed rows after it. The open session is added on each refresh.
local function Collect(key, lvl, weekStart, ch)
    ch = ch or ns.char
    local d = DigestFor(key)
    local cap = CapOf(d)
    local capped = cap ~= nil and (lvl or (d and N(d.level)) or 0) >= cap
    local b = { key = key, level = lvl, weekStart = weekStart, wp = 0, wq = 0, wg = 0, ws = 0, wr = 0,
        lp = 0, lxk = 0, lxq = 0, lxe = 0, lxo = 0, lq = 0, lk = 0, ldd = 0, zd = {}, mn = {}, mv = {}, dt = {}, levelP = {}, levelX = {},
        capped = capped, extra = d and type(d.cap) == "table" and d.cap or {},
        cap = { level = cap, p = 0, g = 0, s = 0, r = 0, k = 0, dd = 0, q = 0 },
        below = { p = 0, xk = 0, xq = 0, xo = 0 } }
    local dayFrom = DayStart()
    local seen = min(weekStart, dayFrom)
    b.days = { p = {}, q = {}, g = {}, r = {} }
    for i = 1, DAYS do b.days.p[i], b.days.q[i], b.days.g[i], b.days.r[i] = 0, 0, 0, 0 end
    local through = -1
    local mates = {}
    if d then
        through = N(d.through)
        if type(d.sessions) == "table" then
            for _, row in ipairs(d.sessions) do
                if type(row) == "table" then
                    local t = N(row.t)
                    if t >= seen and t <= through then
                        if t >= weekStart then AddWeek(b, row) end
                        if t >= dayFrom then AddDay(b, row, t, dayFrom) end
                        b.dt[#b.dt + 1] = t
                    end
                end
            end
        end
        if lvl and type(d.levels) == "table" then AddLevel(b, d.levels[lvl]) end
        if capped then
            -- At the cap nothing is fitted or estimated: the levels only add up to the Levelling card.
            AddBelow(b, d.levels, cap)
            if type(d.levels) == "table" then AddCap(b, d.levels[cap]) end
        else
            AddLevels(b, d.levels)
        end
        if type(d.deathZones) == "table" then
            for _, z in ipairs(d.deathZones) do
                if type(z) == "table" and type(z.name) == "string" then b.zd[z.name] = (b.zd[z.name] or 0) + N(z.n) end
            end
        end
        if type(d.mates) == "table" then
            for _, m in ipairs(d.mates) do
                if type(m) == "table" and type(m.name) == "string" and not ns.IsOwnChar(m.name) then
                    mates[m.name] = N(m.p)
                end
            end
        end
        b.zone, b.class, b.level0 = d.zone, d.class, d.level
    end
    local o = ch and ch.ov
    if type(o) == "table" and type(o.sess) == "table" then
        for _, row in ipairs(o.sess) do
            local t = type(row) == "table" and N(row.t) or 0
            -- A week row the digest does not hold (it ends at the last export, or lost a session).
            if t <= through + 3 and t >= seen then
                local held = false
                for i = 1, #b.dt do
                    if abs(b.dt[i] - t) <= 3 then held = true; break end
                end
                if not held then
                    if t >= weekStart then AddWeek(b, row) end
                    if t >= dayFrom then AddDay(b, row, t, dayFrom) end
                end
            end
            -- Two keys within 3 seconds are one session; the digest already has it.
            if t > through + 3 then
                if N(row.t) >= weekStart then AddWeek(b, row) end
                if N(row.t) >= dayFrom then AddDay(b, row, N(row.t), dayFrom) end
                if lvl and type(row.lv) == "table" then AddLevel(b, row.lv[lvl]) end
                if capped then
                    AddBelow(b, row.lv, cap)
                    if type(row.lv) == "table" then AddCap(b, row.lv[cap]) end
                else
                    AddLevels(b, row.lv)
                end
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
    local own = ch and ch.mates
    if type(own) == "table" then
        for name, m in pairs(own) do
            if type(name) == "string" and type(m) == "table" and not ns.IsOwnChar(name) then
                mates[name] = max(mates[name] or 0, N(m.secs))
            end
        end
    end
    Top(mates, MATES, b.mn, b.mv)

    -- Rows for the level estimates, newest first: the digest's `recent` (its `sessions` when an older
    -- digest has no `recent`), plus the addon's rows after `through` (two keys within 3 seconds are one
    -- session). `first` is the start of the oldest recorded session.
    local rows = {}
    if d then
        local list = not capped and (type(d.recent) == "table" and d.recent or d.sessions)
        if type(list) == "table" then
            for _, row in ipairs(list) do
                local t = type(row) == "table" and N(row.t) or 0
                if t > 0 then
                    rows[#rows + 1] = { t = t, p = N(row.p), x = row.x ~= nil and N(row.x) or XPOf(row) }
                end
            end
        end
        b.first = N(d.first) > 0 and N(d.first) or nil
    end
    if not capped and type(o) == "table" and type(o.sess) == "table" then
        for _, row in ipairs(o.sess) do
            local t = type(row) == "table" and N(row.t) or 0
            if t > through + 3 then rows[#rows + 1] = { t = t, p = N(row.p), x = XPOf(row) } end
        end
    end
    table.sort(rows, function(a, c) return a.t > c.t end)
    b.rows = rows
    return b
end

function ns.CapEstimate(key, lvl, xp, xpMax, live)
    local d = DigestFor(key)
    if not d then return end
    lvl, xp, xpMax = lvl or N(d.level), xp or N(d.xp), xpMax or N(d.xpMax)
    local cap = min(CapOf(d) or FALLBACK_CAP, #NEED + 1)
    if lvl <= 0 or lvl >= cap or xpMax <= 0 then return end
    local ch = ns.db and ns.db.chars and ns.db.chars[key]
    local b = Collect(key, lvl, WeekStart(), ch)
    if b.capped then return end
    local held = live ~= nil and LiveHeld(b.rows, live)
    if not FitPace(b.levelP, b.levelX, live, held, lvl, key) then return end
    local secs = SecondsTo(lvl, xp, xpMax, cap)
    local now = time()
    local oldest = b.first or (b.rows[#b.rows] and b.rows[#b.rows].t) or (live and N(live.t)) or now
    local rate = DayPlayed(b.rows, live, held, now) / min(DAY_WINDOW, max(1, (now - oldest) / 86400))
    local when
    if rate > 0 and secs / rate <= MAX_DAYS then when = ns.Day(floor(now + secs / rate * 86400), true) end
    return lvl, secs, when, cap
end

-- Played seconds at the cap: the larger of the time the rows and the digest hold for the cap level, the
-- digest's own figure (which also reads the client's /played seconds on the level) and the addon's last
-- /played read at the cap. docs/OVERVIEW.md, "Max level".
local function CapSeconds(b, live)
    local secs = b.cap.p
    local lv = live and b.cap.level and live.lv[b.cap.level]
    if type(lv) == "table" then secs = secs + N(lv.p) end
    local ding = b.cap.level and ns.char and ns.char.ov and ns.char.ov.ding and ns.char.ov.ding[b.cap.level]
    if N(b.extra.reached) > 0 or type(ding) == "table" then
        secs = max(secs, N(b.extra.p), N(ns.char and ns.char.capSecs))
    end
    return secs
end

-- Page -----------------------------------------------------------------------------

function ns.OverviewPage(parent, ui)
    local T, Fill, Border, Text = ui.T, ui.Fill, ui.Border, ui.Text
    local Num, Money, Duration = ui.Num, ui.Money, ui.Duration

    local page = CreateFrame("Frame", nil, parent)
    page:SetAllPoints()

    local name = Text(page, 40, T.fg, "LEFT", "display")
    name:SetPoint("TOPLEFT", 0, 2)
    local where = Text(page, 14, T.fg, "RIGHT")
    where:SetPoint("BOTTOMRIGHT", page, "TOPRIGHT", 0, -34)

    local lvlPage = CreateFrame("Frame", nil, page)
    lvlPage:SetAllPoints()

    local COL_W, COL_X = 318, 338
    local subtitle = Text(lvlPage, 13, T.text)
    subtitle:SetPoint("TOPLEFT", 0, -42)
    local headA = Text(lvlPage, 13, T.text, "RIGHT")
    headA:SetPoint("TOPRIGHT", 0, -12)
    local headB = Text(lvlPage, 11.5, T.muted, "RIGHT")
    headB:SetPoint("TOPRIGHT", 0, -30)

    local bar = CreateFrame("Frame", nil, lvlPage)
    bar:SetHeight(6)
    bar:SetPoint("TOPLEFT", 0, -62)
    bar:SetPoint("TOPRIGHT", 0, -62)
    Fill(bar, T.grey):SetAllPoints()
    local barFill = Fill(bar, T.accent, 1, "ARTWORK")
    barFill:SetPoint("TOPLEFT")
    barFill:SetPoint("BOTTOMLEFT")
    barFill:SetWidth(1)
    local barRested = Fill(bar, T.rest, 1, "ARTWORK")
    barRested:SetPoint("TOPLEFT", barFill, "TOPRIGHT")
    barRested:SetPoint("BOTTOMLEFT", barFill, "BOTTOMRIGHT")
    barRested:SetWidth(1)

    local strip = CreateFrame("Frame", nil, lvlPage)
    strip:SetHeight(26)
    strip:SetPoint("TOPLEFT", 0, -76)
    strip:SetPoint("TOPRIGHT", 0, -76)
    strip:EnableMouse(true)
    Border(strip, T.line)
    local etaLevel, etaTime, etaDate = {}, {}, {}
    local CELL = 656 / 3
    for i = 1, 3 do
        local x = (i - 1) * CELL
        if i > 1 then
            local divide = Fill(strip, T.line, 1, "ARTWORK")
            divide:SetPoint("TOPLEFT", x, 0)
            divide:SetPoint("BOTTOMLEFT", x, 0)
            divide:SetWidth(1)
        end
        etaLevel[i] = Text(strip, 13, T.fg, "LEFT", "strong")
        etaLevel[i]:SetPoint("TOPLEFT", x + 10, -5)
        etaLevel[i]:SetWidth(56)
        etaTime[i] = Text(strip, 13, T.text)
        etaTime[i]:SetPoint("TOPLEFT", x + 66, -5)
        etaTime[i]:SetWidth(62)
        etaDate[i] = Text(strip, 13, T.muted)
        etaDate[i]:SetPoint("TOPLEFT", x + 130, -5)
        etaDate[i]:SetWidth(CELL - 136)
    end
    local basisText = ""
    strip:SetScript("OnEnter", function(self)
        if basisText == "" then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(basisText, T.muted[1], T.muted[2], T.muted[3], true)
        GameTooltip:Show()
    end)
    strip:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local targets = {}

    local tiles, sparks = {}, {}
    local tileBox = CreateFrame("Frame", nil, lvlPage)
    tileBox:SetHeight(62)
    tileBox:SetPoint("TOPLEFT", 0, -110)
    tileBox:SetPoint("TOPRIGHT", 0, -110)
    Border(tileBox, T.line)
    for i = 1, 4 do
        local t = ui.Tile(tileBox, 164, 62)
        t:SetPoint("TOPLEFT", (i - 1) * 164, 0)
        tiles[i] = t
        sparks[i] = {}
        for d = 1, DAYS do
            local c = Fill(t, T.fg, 0.22, "ARTWORK")
            c:SetSize(5, 1)
            c:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", -12 - (DAYS - d) * 8, 10)
            sparks[i][d] = c
        end
    end
    local function Spark(i, values)
        local top = 0
        for d = 1, DAYS do top = max(top, values[d]) end
        for d = 1, DAYS do
            local v, c = values[d], sparks[i][d]
            c:SetHeight(v > 0 and top > 0 and max(2, v / top * SPARK_H) or 1)
            local col = d == DAYS and T.accent or T.fg
            c:SetVertexColor(col[1], col[2], col[3], (v > 0 and (d == DAYS and 1 or 0.3)) or 0.1)
        end
    end

    local closeTitle = Text(lvlPage, 19, T.fg, "LEFT", "display")
    closeTitle:SetPoint("TOPLEFT", 0, -180)
    closeTitle:SetText("Closest feats")
    local closeHeld = Text(lvlPage, 12, T.muted, "RIGHT")
    closeHeld:SetPoint("TOPRIGHT", lvlPage, "TOPLEFT", COL_W, -186)
    local closeRows = {}
    for i = 1, 3 do
        local r = ui.FeatRow(lvlPage, COL_W)
        r:SetHeight(40)
        r:SetPoint("TOPLEFT", 0, -204 - (i - 1) * 40)
        r:SetScript("OnClick", function(self)
            if self.feat and self.feat.key and ns.OpenFeat then ns.OpenFeat(self.feat.key, self.feat.account) end
        end)
        closeRows[i] = r
    end

    local soFar = Text(lvlPage, 19, T.fg, "LEFT", "display")
    soFar:SetPoint("TOPLEFT", COL_X, -180)
    local xpStack = ui.Stack(lvlPage, COL_W, 8)
    xpStack:SetPoint("TOPLEFT", COL_X, -210)
    local counts = Text(lvlPage, 13, T.text)
    counts:SetPoint("TOPLEFT", xpStack, "BOTTOMLEFT", 0, -8)
    local lastBtn = CreateFrame("Button", nil, lvlPage)
    lastBtn:SetSize(COL_W, 20)
    lastBtn:SetPoint("TOPLEFT", counts, "BOTTOMLEFT", 0, -8)
    local lastText = Text(lastBtn, 13, T.text)
    lastText:SetPoint("LEFT")
    lastText:SetPoint("RIGHT")
    lastBtn:SetScript("OnClick", function()
        if ns.OpenSession then ns.OpenSession("last") end
    end)
    lastBtn:SetScript("OnEnter", function() lastText:SetTextColor(T.fg[1], T.fg[2], T.fg[3]) end)
    lastBtn:SetScript("OnLeave", function() lastText:SetTextColor(T.text[1], T.text[2], T.text[3]) end)

    local classTitle = Text(lvlPage, 19, T.fg, "LEFT", "display")
    classTitle:SetPoint("TOPLEFT", 0, -326)
    local classHeld = Text(lvlPage, 12, T.muted, "RIGHT")
    classHeld:SetPoint("TOPRIGHT", 0, -332)
    local classGroups, classBuilt = {}, false

    local matesTitle = Text(lvlPage, 19, T.fg, "LEFT", "display")
    matesTitle:SetPoint("TOPLEFT", 0, -398)
    matesTitle:SetText("Played with")
    local matesBars = ui.Bars(lvlPage, COL_W, 2, 26)
    matesBars:SetPoint("TOPLEFT", 0, -420)
    local matesEmpty = Text(lvlPage, 13, T.muted)
    matesEmpty:SetPoint("TOPLEFT", 0, -424)
    matesEmpty:SetText("No groups recorded")
    local deathTitle = Text(lvlPage, 19, T.fg, "LEFT", "display")
    deathTitle:SetPoint("TOPLEFT", COL_X, -398)
    deathTitle:SetText("Deaths by zone")
    local deathBars = ui.Bars(lvlPage, COL_W, 2, 26)
    deathBars:SetPoint("TOPLEFT", COL_X, -420)
    local deathEmpty = Text(lvlPage, 13, T.muted)
    deathEmpty:SetPoint("TOPLEFT", COL_X, -424)
    deathEmpty:SetText("No deaths recorded")

    -- Fills the rows for a character at level lvl; no rows (and no basis line) at level 60 or when
    -- the client hides the experience bar.
    local function ShowEta(b, live, lvl, xp, xpMax)
        local rows, first = b.rows, b.first
        local n = 0
        local basis = ""
        if lvl and xp and xpMax and xpMax > 0 then
            n = Targets(lvl, targets, b.cap.level or FALLBACK_CAP)
        end
        if n > 0 then
            local now = time()
            local held = live ~= nil and LiveHeld(rows, live)
            if not FitPace(b.levelP, b.levelX, live, held, lvl, b.key) then
                n = 0
                basis = format("Needs %d complete levels of 15m or more with XP recorded", MIN_FIT_LEVELS)
            else
                -- Played seconds per calendar day over the days recorded, at most DAY_WINDOW and at least 1.
                local oldest = first or (rows[#rows] and rows[#rows].t) or (live and N(live.t)) or now
                local rate = DayPlayed(rows, live, held, now) / math.min(DAY_WINDOW, max(1, (now - oldest) / 86400))
                for i = 1, n do
                    local secs = SecondsTo(lvl, xp, xpMax, targets[i])
                    local when
                    if rate > 0 and secs / rate <= MAX_DAYS then
                        when = ns.Day(floor(now + secs / rate * 86400), true)
                    end
                    etaLevel[i]:SetText("Level " .. targets[i])
                    etaTime[i]:SetText(Span(secs))
                    etaDate[i]:SetText(when or "")
                end
                basis = format("Based on %d complete levels played: %s XP an hour", pace.levels, Num(Rate(lvl) * 3600))
                if not pace.flat then
                    basis = format("%s at level %d, rising %.1f%% a level", basis, lvl, (math.exp(pace.b) - 1) * 100)
                end
            end
        end
        basisText = basis
        for i = n + 1, 3 do
            etaLevel[i]:SetText("")
            etaTime[i]:SetText("")
            etaDate[i]:SetText("")
        end
    end

    local function Card(host, col, row, title)
        local c = CreateFrame("Frame", nil, host)
        c:SetHeight(PANEL_H)
        local y = -row * (PANEL_H + PANEL_GAP)
        if col == 0 then
            c:SetPoint("TOPLEFT", 0, y)
            c:SetPoint("TOPRIGHT", host, "TOP", -PANEL_GAP / 2, y)
        else
            c:SetPoint("TOPLEFT", host, "TOP", PANEL_GAP / 2, y)
            c:SetPoint("TOPRIGHT", 0, y)
        end
        Fill(c, T.panel):SetAllPoints()
        Border(c, T.line)
        c.title = Text(c, 15, T.accentSoft, "LEFT", "strong")
        c.title:SetPoint("TOPLEFT", 14, -12)
        c.title:SetText(title)
        c.left, c.right = {}, {}
        for i = 1, ROWS do
            local l = Text(c, 14, T.text)
            l:SetPoint("TOPLEFT", 14, -36 - (i - 1) * ROW_H)
            l:SetWidth(180)
            local r = Text(c, 14, T.fg, "RIGHT")
            r:SetPoint("TOPRIGHT", -14, -36 - (i - 1) * ROW_H)
            r:SetWidth(96)
            c.left[i], c.right[i] = l, r
        end
        c.empty = Text(c, 14, T.muted)
        c.empty:SetPoint("TOPLEFT", 14, -36)
        c.empty:Hide()
        -- Row i shows label and value; rows after the last one given are cleared.
        c.hot, c.tipAt = {}, {}
        function c:Set(i, label, value, tipAt)
            self.left[i]:SetText(label or "")
            self.right[i]:SetText(value or "")
            self.tipAt[i] = tipAt
            if tipAt and not self.hot[i] then
                local hot = CreateFrame("Frame", nil, self)
                hot:SetPoint("TOPLEFT", 14, -36 - (i - 1) * ROW_H)
                hot:SetPoint("TOPRIGHT", -14, -36 - (i - 1) * ROW_H)
                hot:SetHeight(ROW_H)
                hot:EnableMouse(true)
                hot:SetScript("OnEnter", function(frame)
                    if self.tipAt[i] then ns.ShowExact(frame, self.tipAt[i], false, "ANCHOR_BOTTOM") end
                end)
                hot:SetScript("OnLeave", function() GameTooltip:Hide() end)
                self.hot[i] = hot
            end
        end
        function c:Rows(count, emptyText)
            for i = count + 1, ROWS do self:Set(i) end
            self.empty:SetText(emptyText or "")
            self.empty:SetShown(count == 0 and emptyText ~= nil)
        end
        return c
    end

    local drawnFeats
    local base
    local deathMap, deathNames, deathVals = {}, {}, {}
    local dayP, dayQ, dayG, dayR = {}, {}, {}, {}
    local xpRows = { { label = "Kills", color = T.accent }, { label = "Exploring", color = T.s2 },
        { label = "Quests", color = T.s3 }, { label = "Other", color = T.rest } }
    local mateItems, deathItems = {}, {}
    local matePool, deathPool = { {}, {}, {} }, { {}, {}, {} }

    local function Rows(out, pool, names, vals, n, label, text)
        for i = #out, 1, -1 do out[i] = nil end
        for i = 1, n do
            if names[i] then
                local row = pool[i]
                row.label = label and label(names[i]) or names[i]
                row.value = vals[i]
                row.text = text and text(vals[i]) or nil
                out[#out + 1] = row
            end
        end
        return #out
    end

    -- Max level group ---------------------------------------------------------------------
    -- Built the first time a character has an hour at the cap, so a levelling character never pays for it.
    local maxPage, maxCards
    local MAX_TOP, MAX_ROWS_OF_CARDS = 56, 4

    local function Signed(copper)
        if copper < 0 then return "-" .. Money(-copper) end
        return "+" .. Money(copper)
    end

    local function BuildMax()
        maxPage = CreateFrame("ScrollFrame", nil, page)
        maxPage:SetPoint("TOPLEFT", 0, -MAX_TOP)
        maxPage:SetPoint("BOTTOMRIGHT")
        local child = CreateFrame("Frame", nil, maxPage)
        child:SetSize(1, MAX_ROWS_OF_CARDS * (PANEL_H + PANEL_GAP) + 24)
        maxPage:SetScrollChild(child)
        maxPage:EnableMouseWheel(true)
        maxPage:SetScript("OnMouseWheel", function(self, delta)
            local top = max(0, child:GetHeight() - self:GetHeight())
            self:SetVerticalScroll(math.min(top, max(0, self:GetVerticalScroll() - delta * ROW_H * 3)))
        end)
        maxPage:SetScript("OnSizeChanged", function(_, w) child:SetWidth(w) end)
        local function C(col, row, title) return Card(child, col, row, title) end
        maxCards = { atMax = C(0, 0, "At max level"), gold = C(1, 0, "Gold"), runs = C(0, 1, "Dungeons and raids"),
            deaths = C(1, 1, "Deaths"), rep = C(0, 2, "Reputation and professions"), legacy = C(1, 2, "Legacy and PvP"),
            levelling = C(0, 3, "Levelling"), mates = C(1, 3, "Played with") }
        local f = Text(child, 13, T.muted)
        f:SetPoint("TOPLEFT", 0, -MAX_ROWS_OF_CARDS * (PANEL_H + PANEL_GAP) - 2)
        f:SetText("History through the last export \194\183 this session live")
    end

    -- The page is redrawn only when something it shows moved: the minute of played time, or a count
    -- the open session changed. The ticker calls Refresh every half second while the window is open.
    local drawnBase, drawnStamp
    local function RefreshMax(b, live)
        if not maxCards then BuildMax() end
        local cap, x, secs = b.cap, b.extra, CapSeconds(b, live)
        local lvCap0 = live and cap.level and live.lv[cap.level]
        local stamp = floor(secs / 60)
        if type(lvCap0) == "table" then
            stamp = stamp + N(lvCap0.g) * 7 + N(lvCap0.s) * 13 + N(lvCap0.dd) * 10007 + N(lvCap0.r) * 100003
        end
        if b == drawnBase and stamp == drawnStamp then return end
        drawnBase, drawnStamp = b, stamp
        local g, s, r, dd = cap.g, cap.s, cap.r, cap.dd
        local lvCap = live and cap.level and live.lv[cap.level]
        if type(lvCap) == "table" then
            g, s, r, dd = g + N(lvCap.g), s + N(lvCap.s), r + N(lvCap.r), dd + N(lvCap.dd)
        end
        local hours = max(secs / 3600, 1)
        local net = g - s
        local m = maxCards

        local capDing = cap.level and ns.char and ns.char.ov and ns.char.ov.ding and ns.char.ov.ding[cap.level]
        local reached = N(x.reached)
        if reached == 0 and type(capDing) == "table" then reached = N(capDing.t) end
        m.atMax:Set(1, reached > 0 and "Time at max level" or "Recorded at max level", Duration(secs))
        m.atMax:Set(2, "Reached", reached > 0 and ns.Day(reached) or "Before recording",
            reached > 0 and reached or nil)
        m.atMax:Set(3, "Item level", N(x.ilvl) > 0 and Num(x.ilvl) or "")
        m.atMax:Set(4, "Items looted", Num(N(x.loot)))
        m.atMax:Rows(4)

        m.gold:Set(1, "Earned", Money(g))
        m.gold:Set(2, "Spent", Money(s))
        m.gold:Set(3, "Net", Signed(net))
        m.gold:Set(4, "Net an hour", Signed(floor(net / hours)))
        m.gold:Rows(4)

        m.runs:Set(1, "Runs", Num(r))
        m.runs:Set(2, "Bosses", Num(N(x.bosses)))
        local shown = 2
        for i = 1, 2 do
            local run = type(x.runs) == "table" and x.runs[i]
            if type(run) == "table" and type(run.name) == "string" then
                shown = 2 + i
                m.runs:Set(shown, run.name, Num(N(run.n)) .. " \194\183 " .. Duration(N(run.p)))
            end
        end
        m.runs:Rows(shown)

        m.deaths:Set(1, "Deaths", Num(dd))
        m.deaths:Set(2, "Deaths an hour", format("%.1f", dd / hours))
        local killer = type(x.killers) == "table" and x.killers[1]
        local dz = type(x.dz) == "table" and x.dz[1]
        local n = 2
        if type(killer) == "table" and type(killer.name) == "string" then
            n = n + 1
            m.deaths:Set(n, "By " .. killer.name, Num(N(killer.n)))
        end
        if type(dz) == "table" and type(dz.name) == "string" then
            n = n + 1
            m.deaths:Set(n, "In " .. dz.name, Num(N(dz.n)))
        end
        m.deaths:Rows(n)

        n = 0
        for i = 1, 3 do
            local rep = type(x.rep) == "table" and x.rep[i]
            if type(rep) == "table" and type(rep.name) == "string" then
                n = n + 1
                m.rep:Set(n, rep.name, "+" .. Num(N(rep.n)))
            end
        end
        n = n + 1
        m.rep:Set(n, "Skill-ups", Num(N(x.skillups)))
        m.rep:Rows(n)

        m.legacy:Set(1, "Legacy Challenges", format("%s of %s", Num(N(x.ldone)), Num(N(x.ltotal))))
        m.legacy:Set(2, "Legacy points", Num(N(x.lpoints)))
        m.legacy:Set(3, "Honorable kills", Num(N(x.hks)))
        m.legacy:Set(4, "Honor", Num(N(x.honor)))
        m.legacy:Rows(4)

        local bl = b.below
        local first = ns.FirstLevel(b.key)
        local sawLevelling = not (first and cap.level and first >= cap.level)
        m.levelling:SetShown(sawLevelling)
        m.levelling.title:SetText(first and first > 1 and ("Levelling from level " .. first) or "Levelling")
        local _, _, toCap = ns.LevelFacts(b.key, cap.level or 0)
        m.levelling:Set(1, "Time to reach max level", toCap > 0 and Duration(toCap) or "Not recorded")
        m.levelling:Set(2, "XP from kills", Num(bl.xk))
        m.levelling:Set(3, "XP from quests", Num(bl.xq))
        m.levelling:Set(4, "XP from other", Num(bl.xo))
        m.levelling:Rows(4)

        shown = 0
        for i = 1, MATES do
            if b.mn[i] then
                shown = i
                m.mates:Set(i, ns.DisplayName(b.mn[i]), Duration(b.mv[i]))
            end
        end
        m.mates:Rows(shown, "No groups recorded")
    end

    local function DrawHeader(key, lvl, clientLevel, zone, live, levelTime)
        local levelling = ns.Cap.Levelling()
        local xp, xpMax
        if levelling then xp, xpMax = CNum(UnitXP("player")), CNum(UnitXPMax("player")) end

        local id = {}
        if lvl then id[1] = "Level " .. lvl end
        id[#id + 1] = CStr((UnitRace("player")))
        id[#id + 1] = CStr((UnitClass("player")))
        local head = { table.concat(id, " ") }
        if ns.specName then head[#head + 1] = ns.specName end
        if zone then head[#head + 1] = zone end
        local history = ns.History(key)
        local recorded = N(ns.char and ns.char.tracked) + (history and history.tracked or 0)
            + (ns.sessionG and GetTime() - ns.sessionG or 0)
        if recorded >= 60 then head[#head + 1] = Duration(recorded) .. " recorded" end
        subtitle:SetText(table.concat(head, " \194\183 "))

        if xp and xpMax and xpMax > 0 then
            local ratio = min(1, max(0, xp / xpMax))
            local w = bar:GetWidth() or 0
            barFill:SetWidth(max(1, ratio * w))
            local rested = type(GetXPExhaustion) == "function" and CNum(GetXPExhaustion()) or nil
            local extra = rested and rested > 0 and min(1 - ratio, rested / xpMax) or 0
            barRested:SetWidth(max(0.01, extra * w))
            barRested:SetShown(extra > 0)
            local text = format("%d%% to level %d", floor(ratio * 100), (lvl or 0) + 1)
            if levelTime > 0 then text = text .. " \194\183 " .. Duration(levelTime) .. " on this level" end
            headA:SetText(text)
            headB:SetText(rested and rested > 0 and (Num(rested) .. " rested XP left") or "")
        else
            barFill:SetWidth(1)
            barRested:Hide()
            headA:SetText(levelTime > 0 and ("This level " .. Duration(levelTime)) or "")
            headB:SetText("")
        end
        if levelling then
            ShowEta(base, live, clientLevel, xp, xpMax)
        else
            ShowEta(base, live, nil, nil, nil)
        end
        strip:SetShown(levelling and xp ~= nil and xpMax ~= nil)
    end

    local function DrawWeek(live)
        local wp, wq, wg, ws, wr = base.wp, base.wq, base.wg, base.ws, base.wr
        local days = base.days
        for i = 1, DAYS do
            dayP[i], dayQ[i], dayG[i], dayR[i] = days.p[i], days.q[i], max(0, days.g[i]), days.r[i]
        end
        if live then
            dayP[DAYS], dayQ[DAYS] = dayP[DAYS] + N(live.p), dayQ[DAYS] + N(live.q)
            dayG[DAYS], dayR[DAYS] = max(0, dayG[DAYS] + N(live.g) - N(live.s)), dayR[DAYS] + N(live.r)
            if N(live.t) >= base.weekStart then
                wp, wq, wg, ws, wr = wp + N(live.p), wq + N(live.q), wg + N(live.g), ws + N(live.s), wr + N(live.r)
            end
        end
        local net = wg - ws
        tiles[1]:Set("Played this week", Duration(wp))
        tiles[2]:Set("Quests this week", Num(wq))
        tiles[3]:Set("Gold this week", net < 0 and ("-" .. Money(-net)) or ("+" .. Money(net)))
        tiles[4]:Set("Dungeons this week", Num(wr))
        Spark(1, dayP)
        Spark(2, dayQ)
        Spark(3, dayG)
        Spark(4, dayR)
    end

    local function DrawFeats()
        local Feats = ns.Feats
        local stamp = Feats and Feats.Stamp()
        if Feats and stamp ~= drawnFeats then
            drawnFeats = stamp
            local held, total = Feats.Held()
            closeHeld:SetText(total > 0 and format("%d of %d held", held, total) or "")
            local near = Feats.Closest(3, Feats.Shown)
            for i = 1, 3 do
                local info = near[i]
                closeRows[i]:SetShown(info ~= nil)
                if info then
                    closeRows[i]:Set(Feats.ClosestRow(info))
                end
            end
            closeTitle:SetShown(true)

            if not classBuilt then
                local groups = Feats.Collections()
                for _, group in ipairs(groups) do
                    local first = group.feats[1]
                    if first and (first.scope == "class" or first.scope == "tree") then
                        local g = { label = Text(lvlPage, 11, T.muted), crests = {}, feats = group.feats }
                        for i = 1, #group.feats do
                            g.crests[i] = ui.FeatCrest(lvlPage, 28)
                        end
                        g.label:SetText(group.name)
                        classGroups[#classGroups + 1] = g
                    end
                end
                classBuilt = #groups > 0
            end
            local x, heldClass, totalClass = 0, 0, 0
            for _, g in ipairs(classGroups) do
                local at = 0
                for i, f in ipairs(g.feats) do
                    local crest = g.crests[i]
                    if Feats.Shown(f) then
                        local info = Feats.Info(f.key)
                        crest:ClearAllPoints()
                        crest:SetPoint("TOPLEFT", lvlPage, "TOPLEFT", x + at * 32, -366)
                        crest:Set(f, info, Feats.Moves(f))
                        crest:Show()
                        at = at + 1
                        totalClass = totalClass + 1
                        if info.tier > 0 then heldClass = heldClass + 1 end
                    else
                        crest:Hide()
                    end
                end
                g.label:ClearAllPoints()
                g.label:SetPoint("TOPLEFT", lvlPage, "TOPLEFT", x, -352)
                g.label:SetShown(at > 0)
                x = x + at * 32 + 24
            end
            local className = CStr((UnitClass("player")))
            classTitle:SetText(className and (className .. " feats") or "Class feats")
            classTitle:SetShown(totalClass > 0)
            classHeld:SetText(totalClass > 0 and format("%d of %d held", heldClass, totalClass) or "")
        end
    end

    local function DrawLevel(lvl, lv, wholeLevel, live)
        local xk, xe, xq, xo = base.lxk, base.lxe, base.lxq, base.lxo
        local kills, dead, quests = base.lk, base.ldd, base.lq
        if lv then
            xk, xe, xq, xo = xk + N(lv.xk) + N(lv.xd), xe + N(lv.xe), xq + N(lv.xq), xo + N(lv.xo)
            kills, dead, quests = kills + N(lv.k), dead + N(lv.dd), quests + N(lv.q)
        end
        soFar:SetText(lvl and format(wholeLevel and "Level %d so far" or "Level %d, recorded part", lvl) or "This level so far")
        xpRows[1].value, xpRows[2].value, xpRows[3].value, xpRows[4].value = xk, xe, xq, xo
        xpStack:Set(xpRows)
        counts:SetText(format("%s %s \194\183 %s %s \194\183 %s %s", Num(kills), kills == 1 and "kill" or "kills",
            Num(dead), dead == 1 and "death" or "deaths", Num(quests), quests == 1 and "quest" or "quests"))
        local last = ns.Recap and ns.Recap.Last()
        if last and type(last.played) == "number" then
            local title = type(last.title) == "table" and last.title.text
            lastText:SetText("Last session  " .. Duration(last.played) .. (title and (" \194\183 " .. title) or ""))
        else
            lastText:SetText("")
        end
        lastBtn:SetShown(lastText:GetText() ~= "")

        matesEmpty:SetShown(Rows(mateItems, matePool, base.mn, base.mv, MATES, ns.DisplayName, Duration) == 0)
        matesBars:Set(mateItems)

        wipe(deathMap)
        for zname, n in pairs(base.zd) do deathMap[zname] = n end
        if live then
            for zname, z in pairs(live.zn) do
                if type(z) == "table" and N(z.dd) > 0 then deathMap[zname] = (deathMap[zname] or 0) + z.dd end
            end
        end
        Top(deathMap, DEATHS, deathNames, deathVals)
        deathEmpty:SetShown(Rows(deathItems, deathPool, deathNames, deathVals, DEATHS) == 0)
        deathBars:Set(deathItems)
    end

    function page:Refresh()
        local key = ns.charKey
        if not key then return end
        local lvl = CNum(UnitLevel("player"))
        local weekStart = WeekStart()
        if not base or base.key ~= key or base.level ~= lvl or base.weekStart ~= weekStart then
            base = Collect(key, lvl, weekStart)
        end
        local live = ns.Ov.Live()

        -- Header
        local _, classFile = UnitClass("player")
        classFile = CStr(classFile) or base.class
        local color = classFile and _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[classFile] or T.fg
        name:SetText(ns.DisplayName(key))
        name:SetTextColor(color.r or color[1], color.g or color[2], color.b or color[3])
        local clientLevel = lvl
        lvl = lvl or (type(base.level0) == "number" and base.level0) or nil
        local zone = CStr(GetRealZoneText()) or (type(base.zone) == "string" and base.zone) or nil
        if lvl and zone then
            where:SetText(format("Level %d \194\183 %s", lvl, zone))
        else
            where:SetText(lvl and format("Level %d", lvl) or (zone or ""))
        end

        local lv = live and lvl and live.lv[lvl]
        local levelTime = base.lp + (lv and N(lv.p) or 0)
        local wholeLevel = lvl ~= nil and ns.LevelFacts(key, lvl)

        -- An hour at the cap: the page leads with max level data and the levelling moves down.
        local focus = base.capped and CapSeconds(base, live) >= FOCUS_SECONDS
        lvlPage:SetShown(not focus)
        where:SetShown(focus)
        if maxPage then maxPage:SetShown(focus) end
        if focus then
            RefreshMax(base, live)
            maxPage:SetShown(true)
            return
        end

        DrawHeader(key, lvl, clientLevel, zone, live, levelTime)
        DrawWeek(live)
        DrawFeats()
        DrawLevel(lvl, lv, wholeLevel, live)
    end

    page:SetScript("OnShow", function()
        base, drawnFeats = nil, nil
    end)
    return page
end

