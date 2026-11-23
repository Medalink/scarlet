local _, ns = ...

local floor, ceil, max, min, format, sort = math.floor, math.ceil, math.max, math.min, string.format, table.sort
local GetTime = GetTime

local BUCKETS_MAX = 96
local RING_MAX = 256
local STEP_YARDS = 40
local ZONES_MAX = 48
local MOMENTS_MAX = 40
local SHORT_STRETCH = 30
local SESSIONS_COMPARED = 30
local SESSIONS_MIN = 5
local LONG_ENOUGH = 600

local Recap = {}
ns.Recap = Recap

local S
local stamp = 0
local view

local function Touch()
    stamp = stamp + 1
end

function Recap.Stamp()
    return stamp
end

function Recap.Start(wall)
    S = { wall = wall, g0 = GetTime(), secs = 300, xp = {}, combat = {}, zones = {}, levels = {}, moments = {},
        rx = {}, ry = {}, rt = {}, ri = {}, ra = {}, n = 0, step2 = STEP_YARDS * STEP_YARDS, buckets = 0 }
    view = nil
    Touch()
end

local function Fold(st)
    local xp, combat = st.xp, st.combat
    for i = 1, BUCKETS_MAX / 2 do
        xp[i] = (xp[2 * i - 1] or 0) + (xp[2 * i] or 0)
        combat[i] = (combat[2 * i - 1] or 0) + (combat[2 * i] or 0)
    end
    for i = BUCKETS_MAX / 2 + 1, BUCKETS_MAX do
        xp[i], combat[i] = nil, nil
    end
    st.secs = st.secs * 2
    st.buckets = min(st.buckets, BUCKETS_MAX / 2)
end

local function BucketAt(st, g)
    local i = floor(g / st.secs) + 1
    while i > BUCKETS_MAX do
        Fold(st)
        i = floor(g / st.secs) + 1
    end
    if i > st.buckets then
        for k = st.buckets + 1, i do
            st.xp[k] = st.xp[k] or 0
            st.combat[k] = st.combat[k] or 0
        end
        st.buckets = i
    end
    return i
end

function Recap.XP(amount)
    local st = S
    if not st or type(amount) ~= "number" then return end
    local i = BucketAt(st, GetTime() - st.g0)
    st.xp[i] = st.xp[i] + amount
    Touch()
end

function Recap.Combat(t0, t1)
    local st = S
    if not st or not t0 or t1 <= t0 then return end
    local a, b = max(0, t0 - st.g0), t1 - st.g0
    while a < b do
        local i = BucketAt(st, a)
        local edge = i * st.secs
        local piece = min(b, edge) - a
        st.combat[i] = st.combat[i] + piece
        a = a + piece
        if piece <= 0 then break end
    end
    Touch()
end

function Recap.Level(level)
    local st = S
    if not st then return end
    st.levels[#st.levels + 1] = { level = level, at = GetTime() - st.g0 }
    Touch()
end

function Recap.Zone(name, kind)
    local st = S
    if not st or not name then return end
    local g, zones = GetTime() - st.g0, st.zones
    local last = zones[#zones]
    if last and last.open then
        last.secs, last.open = g - last.at, nil
        if last.secs < SHORT_STRETCH and #zones > 1 then
            local prev = zones[#zones - 1]
            prev.secs = prev.secs + last.secs
            zones[#zones] = nil
            last = prev
        end
    end
    local inst = kind == "party" or kind == "raid"
    if last and last.name == name then
        last.open = true
        last.secs = nil
    elseif #zones < ZONES_MAX then
        zones[#zones + 1] = { name = name, at = g, open = true, inst = inst }
    end
    Touch()
end

--- Seconds since the open session began; 0 before login.
function Recap.Elapsed()
    return S and GetTime() - S.g0 or 0
end

function Recap.Moment(kind, text, feat, tier)
    local st = S
    if not st or #st.moments >= MOMENTS_MAX then return end
    st.moments[#st.moments + 1] = { at = GetTime() - st.g0, kind = kind, text = text or "", feat = feat, tier = tier }
    Touch()
end

function Recap.Pos(x, y, inst, air)
    local st = S
    if not st or not x then return end
    local n = st.n
    local rx, ry, rt, ri, ra = st.rx, st.ry, st.rt, st.ri, st.ra
    if n > 0 and not air and ri[n] == inst then
        local dx, dy = x - rx[n], y - ry[n]
        if dx * dx + dy * dy < st.step2 then return end
    end
    if n >= RING_MAX then
        local j = 0
        for i = 1, n, 2 do
            j = j + 1
            rx[j], ry[j], rt[j], ri[j] = rx[i], ry[i], rt[i], ri[i]
            ra[j] = ra[i] or ra[i + 1] or false
        end
        for i = j + 1, n do
            rx[i], ry[i], rt[i], ri[i], ra[i] = nil, nil, nil, nil, nil
        end
        n = j
        st.step2 = st.step2 * 4
    end
    n = n + 1
    rx[n], ry[n], rt[n], ri[n], ra[n] = x, y, GetTime() - st.g0, inst, air or false
    st.n = n
    Touch()
end

local function TopZone(zones, now)
    local best, secs, inst
    for i = 1, #zones do
        local z = zones[i]
        local s = z.secs or (now - z.at)
        if not best or s > secs then best, secs, inst = z.name, s, z.inst end
    end
    return best, inst
end

local function Duration(secs)
    return ns.UI.Duration(secs)
end

--- The title of a session and the rule that chose it (DESIGN.md, "The title"). t holds l0, l1, zone, dungeon, runs,
--- quests, kills, miles, zones and played; a surface leaves out what it does not know.
function Recap.Title(t)
    local z = t.zone
    local where = z and (" in " .. z) or ""
    if t.l0 and t.l1 and t.l1 ~= t.l0 then
        return format("Level %d to %d%s", t.l0, t.l1, where), "level"
    end
    if t.dungeon and z then
        local runs = t.runs or 0
        return runs > 1 and format("%d runs of %s", runs, z) or ("A run of " .. z), "dungeon"
    end
    local quests, kills = t.quests or 0, t.kills or 0
    if quests >= 5 then return format("%d quest%s%s", quests, quests == 1 and "" or "s", where), "quests" end
    if kills >= 50 then return format("%d kills%s", kills, where), "kills" end
    if (t.miles or 0) >= 3 and (t.zones or 0) >= 3 then
        return format("%.1f miles across %d zones", t.miles, t.zones), "travel"
    end
    return Duration(t.played or 0) .. where, "time"
end

local function RowSummary(row)
    local zone, best, total = nil, -1, 0
    for name, s in pairs(row.zn or {}) do
        local p = s.p or 0
        total = total + p
        if p > best or (p == best and name < (zone or "~")) then zone, best = name, p end
    end
    return {
        l0 = row.l0, l1 = row.l1, zone = zone, runs = row.r, quests = row.q, kills = row.k, played = row.p,
        dungeon = zone ~= nil and type(row.zi) == "table" and row.zi[zone] == true,
        zones = row.z,
    }
end

function Recap.RowTitle(row)
    return Recap.Title(RowSummary(row))
end

local function XPOf(row)
    return (row.xk or 0) + (row.xd or 0) + (row.xq or 0) + (row.xe or 0) + (row.xo or 0)
end

local METRICS = {
    xp_h = function(r) return XPOf(r) / (r.p / 3600) end,
    kills_h = function(r) return (r.k or 0) / (r.p / 3600) end,
    quests_h = function(r) return (r.q or 0) / (r.p / 3600) end,
    deaths = function(r) return r.dd or 0 end,
    played = function(r) return r.p end,
}
local BEST_OF = {
    xp = XPOf,
    kills = function(r) return r.k or 0 end,
    quests = function(r) return r.q or 0 end,
    earned = function(r) return r.g or 0 end,
    xp_h = METRICS.xp_h,
}

local earlier = {}

local function EarlierRows(before)
    local rows = ns.char and ns.char.ov and ns.char.ov.sess
    for i = #earlier, 1, -1 do earlier[i] = nil end
    if type(rows) ~= "table" then return earlier end
    for i = #rows, 1, -1 do
        local r = rows[i]
        if type(r) == "table" and type(r.t) == "number" and r.t < before and (r.p or 0) >= LONG_ENOUGH then
            earlier[#earlier + 1] = r
            if #earlier >= SESSIONS_COMPARED then break end
        end
    end
    return earlier
end

local function Percentile(sorted, q)
    return sorted[min(#sorted, max(1, ceil(#sorted * q)))]
end

local function Compare(row)
    local rows = EarlierRows(row.t)
    if #rows < SESSIONS_MIN then return {}, nil end
    local bests = {}
    for key, fn in pairs(BEST_OF) do
        local top, mine = 0, fn(row)
        for i = 1, #rows do top = max(top, fn(rows[i])) end
        if mine > 0 and mine > top then bests[#bests + 1] = key end
    end
    sort(bests)
    local metrics = {}
    for key, fn in pairs(METRICS) do
        local vals = {}
        for i = 1, #rows do vals[i] = fn(rows[i]) end
        sort(vals)
        metrics[key] = { p10 = Percentile(vals, 0.1), p25 = Percentile(vals, 0.25), p50 = Percentile(vals, 0.5),
            p75 = Percentile(vals, 0.75), p90 = Percentile(vals, 0.9), you = (row.p or 0) > 0 and fn(row) or 0 }
    end
    return bests, { n = #rows, metrics = metrics }
end

local function Class()
    local ok, _, class = pcall(UnitClass, "player")
    return ok and type(class) == "string" and class or ""
end

local function Route(st)
    local n = st.n
    if n < 2 then return nil end
    local counts, dom, domN = {}, nil, 0
    for i = 1, n do
        local c = (counts[st.ri[i]] or 0) + 1
        counts[st.ri[i]] = c
        if c > domN then dom, domN = st.ri[i], c end
    end
    if domN < 2 then return nil end
    local minX, maxX, minY, maxY = 1e18, -1e18, 1e18, -1e18
    for i = 1, n do
        if st.ri[i] == dom then
            local sx, sy = -st.ry[i], st.rx[i]
            minX, maxX, minY, maxY = min(minX, sx), max(maxX, sx), min(minY, sy), max(maxY, sy)
        end
    end
    local w, h = max(maxX - minX, 1), max(maxY - minY, 1)
    local scale = 1000 / max(w, h)
    local points, breaks, air, index, k, prev = {}, {}, {}, {}, 0, 0
    for i = 1, n do
        if st.ri[i] == dom then
            k = k + 1
            points[2 * k - 1] = floor((-st.ry[i] - minX) * scale + 0.5)
            points[2 * k] = floor((st.rx[i] - minY) * scale + 0.5)
            index[i] = k
            if prev > 0 and prev ~= i - 1 then breaks[#breaks + 1] = k end
            if st.ra[i] and prev == i - 1 then air[k] = true end
            prev = i
        end
    end
    local marks = {}
    local function Mark(at, kind)
        for i = 1, n do
            if st.rt[i] >= at and index[i] then
                marks[#marks + 1] = { index[i], kind }
                return
            end
        end
    end
    for i = 1, #st.levels do Mark(st.levels[i].at, "level") end
    for i = 1, #st.moments do
        if st.moments[i].kind == "death" then Mark(st.moments[i].at, "death") end
    end
    return { sheet = { aspect = w / h, points = points, breaks = breaks, air = air, marks = marks } }
end

local function Counters(from)
    local out = {}
    for _, key in ipairs(ns.STAT_KEYS) do
        local v = from[key]
        if type(v) == "number" and v ~= 0 then out[key] = v end
    end
    return out
end

local function Compose(row, counters, st, now, withOwn)
    local zones = {}
    for i = 1, #st.zones do
        local z = st.zones[i]
        zones[i] = { name = z.name, at = floor(z.at), secs = floor(z.secs or (now - z.at)), inst = z.inst or nil }
    end
    local zone, inst = TopZone(st.zones, now)
    local miles = ((counters.foot or 0) + (counters.walk or 0) + (counters.mount or 0) + (counters.swim or 0)) / 1760
    local title, rule = Recap.Title({ l0 = row.l0, l1 = row.l1, zone = zone, dungeon = inst, runs = row.r,
        quests = row.q, kills = row.k, miles = miles, zones = #zones, played = row.p })
    local xp, combat = {}, {}
    for i = 1, st.buckets do xp[i], combat[i] = floor(st.xp[i]), floor(st.combat[i]) end
    local moments = {}
    for i = 1, #st.moments do
        local m = st.moments[i]
        moments[i] = { at = floor(m.at), kind = m.kind, text = m.text, feat = m.feat, tier = m.tier }
    end
    local levels = {}
    for i = 1, #st.levels do levels[i] = { level = st.levels[i].level, at = floor(st.levels[i].at) } end
    local bests, own = {}, nil
    if withOwn then bests, own = Compare(row) end
    return {
        v = 1, character = ns.charKey, class = Class(), start = row.t, ["end"] = floor(st.wall + now),
        played = floor(row.p or 0), level = { row.l0, row.l1 }, zone = zone, title = { rule = rule, text = title },
        xp = { kills = row.xk or 0, dungeons = row.xd or 0, quests = row.xq or 0, explore = row.xe or 0, other = row.xo or 0 },
        runs = row.r or 0, counters = counters, buckets = { secs = st.secs, xp = xp, combat = combat }, zones = zones,
        levels = levels, moments = moments, route = Route(st), feats = { earned = {}, near = {} },
        bests = bests, own = own, gold = { earned = row.g or 0, spent = row.s or 0 },
    }
end

function Recap.Seal(row)
    local st = S
    if not st or not ns.char or type(row) ~= "table" or type(row.t) ~= "number" then return end
    local now = GetTime() - st.g0
    local counters = Counters(ns.sess)
    local recap = Compose(row, counters, st, now, true)
    recap.own = nil
    if ns.Feats and ns.Feats.Changes then recap.feats = ns.Feats.Changes() end
    ns.char.last = recap
end

--- The open session as a recap, rebuilt when something it draws has changed. nil before login.
function Recap.View()
    local st = S
    if not st or not ns.Ov then return nil end
    if view and view.stamp == stamp and view.at == floor(GetTime()) then return view.recap end
    local row = ns.Ov.Live()
    if not row then return nil end
    local now = GetTime() - st.g0
    local recap = Compose(row, Counters(ns.sess), st, now, true)
    if ns.Feats and ns.Feats.Changes then recap.feats = ns.Feats.Changes() end
    view = { stamp = stamp, at = floor(GetTime()), recap = recap }
    return recap
end

local function FromApp()
    local d = _G.ScarletRecaps
    local list = type(d) == "table" and type(d.chars) == "table" and d.chars[ns.charKey]
    return type(list) == "table" and list or nil
end

--- The last closed session: the copy the addon saved, or the app's when that one is newer or the same.
function Recap.Last()
    local saved = ns.char and type(ns.char.last) == "table" and ns.char.last or nil
    local app = FromApp()
    local newest = app and app[1]
    if type(newest) == "table" and type(newest.start) == "number" and type(newest.played) == "number"
        and (not saved or newest.start >= (saved.start or 0)) then
        return newest
    end
    return saved
end

--- The app's recap for the session that began at start, or nil.
function Recap.FromApp(start)
    local list = FromApp()
    if not list then return nil end
    for i = 1, #list do
        if list[i].start == start then return list[i] end
    end
end

--- The closed session rows, newest first.
function Recap.Earlier(out)
    for i = #out, 1, -1 do out[i] = nil end
    local rows = ns.char and ns.char.ov and ns.char.ov.sess
    if type(rows) ~= "table" then return out end
    for i = #rows, 1, -1 do
        if type(rows[i]) == "table" and type(rows[i].t) == "number" then out[#out + 1] = rows[i] end
    end
    return out
end
