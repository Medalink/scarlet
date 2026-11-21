-- MapData.lua: the character's own recorded places, indexed per map for the world map layers (Map.lua).
-- Nothing here records anything. It reads what Capture, Track, Places, Teleport and Addons already wrote
-- (this character's chunks and the open buffers in ScarletDB and ScarletAddonsDB), the way the companion
-- app's Survey look reads them, and keeps the result in memory only. Nothing derived is saved.
-- It runs only when Map.lua asks, once the world map is open with a layer on. Sealed chunks are decoded in
-- a coroutine that Map.lua resumes from an OnUpdate with a time budget, so a long history never stalls a
-- frame. The open buffers are re-read in one go (a thousand lines at most) into a separate store.
-- Positions are the recorded unit divided by 10000: 0..1 across and down the map they were recorded on.
local _, ns = ...

local type, tonumber, pairs, floor = type, tonumber, pairs, math.floor
local find, sub, match, gmatch = string.find, string.sub, string.match, string.gmatch
local strsplit, wipe = strsplit, wipe
local cocreate, coresume, costatus, coyield = coroutine.create, coroutine.resume, coroutine.status, coroutine.yield

local MD = {}
ns.MapData = MD

-- The trail is kept in three tiers, so a map drawn small does not walk every point: a point closer than
-- the tier's step (units of 1/10000) to the last one kept in that tier is dropped. Map.lua draws the
-- coarsest tier whose step is still below its own pixel step.
local TRAIL_KEYS = { "trail", "trail2", "trail3" }
MD.TRAIL_KEYS = TRAIL_KEYS
MD.TRAIL_STEPS = { 8, 64, 512 }
local TRAIL_STEP2 = { 8 * 8, 64 * 64, 512 * 512 }
local TRAIL_LX = { "lx1", "lx2", "lx3" }
local TRAIL_LY = { "ly1", "ly2", "ly3" }
local TRAIL_JUMP2 = 800 * 800  -- farther than 800 units (8% of a map) between two points is not a walk: the trail breaks
local TRAIL_CAP = 250000       -- path points kept per store in the finest tier (16 bytes each)
local FISH_MS = 6000           -- a loot window this soon after a fishing channel ended is a catch
local FISH_SPELLS = { 7620, 18248, 7731 } -- Fishing (18248 is the one Forever casts); a spell with that name counts too
local LIVE_MAX_AGE = 3         -- seconds before the open buffers are read again
-- Points that fall in the same cell of this many units are kept once (as in the app).
local GRID = { gather = 40, fishing = 40, qacc = 40, qdone = 40, camps = 80 }

local debugprofilestop = _G.debugprofilestop or function() return 0 end

-- Stores ---------------------------------------------------------------------------------
-- A store holds one pass over the lines: maps[uiMapID] = { trail, deaths, gather, fishing, qacc, qdone,
-- camps, flights, teleports, found, foundName, foundIdx, npcs, npcN, npcIdx, seen }. The arrays are flat
-- (x, y, x, y ...); the trail holds -1, -1 where a stretch ends; flights and teleports hold x1, y1, x2, y2.

local function NewStore() return { maps = {}, trailN = 0 } end
local sealed, live = NewStore(), NewStore()
MD.stores = { sealed, live }

local function Reset(store)
    for _, ms in pairs(store.maps) do
        for k, v in pairs(ms) do
            if k == "seen" then
                for _, set in pairs(v) do wipe(set) end
            else
                wipe(v)
            end
        end
    end
    store.trailN = 0
end

local function MapOf(store, m)
    local ms = store.maps[m]
    if not ms then
        ms = { seen = {} }
        store.maps[m] = ms
    end
    return ms
end

local function List(ms, key)
    local a = ms[key]
    if not a then
        a = {}
        ms[key] = a
    end
    return a
end

-- State a pass carries from line to line: where the character last stood, whether it is on a flight.
local STATE_KEYS = { "hm", "hx", "hy", "flying", "fm", "fx", "fy", "fishedAt", "lastM", "rx", "ry", "lx1", "ly1", "lx2", "ly2",
    "lx3", "ly3" }

local function NewState()
    return { lastQ = 0, lastQa = 0, ms = 0, fishedAt = -1e15, flying = false }
end

local stS, stL = NewState(), NewState()

local function CopyState(dst, src)
    for i = 1, #STATE_KEYS do
        local k = STATE_KEYS[i]
        dst[k] = src[k]
    end
end

-- Adding points ---------------------------------------------------------------------------

local function AddPoint(ms, key, x, y)
    local g = GRID[key]
    if g then
        local set = ms.seen[key]
        if not set then
            set = {}
            ms.seen[key] = set
        end
        local k = floor(x * 10000 / g + 0.5) * 4096 + floor(y * 10000 / g + 0.5)
        if set[k] then return end
        set[k] = true
    end
    local a = List(ms, key)
    local n = #a
    a[n + 1], a[n + 2] = x, y
end

local function AddSegment(ms, key, x1, y1, x2, y2)
    local a = List(ms, key)
    local n = #a
    a[n + 1], a[n + 2], a[n + 3], a[n + 4] = x1, y1, x2, y2
end

-- The mean of the places an npc was talked to from.
local function AddNpc(ms, id, x, y)
    local idx, a, cnt = List(ms, "npcIdx"), List(ms, "npcs"), List(ms, "npcN")
    local i = idx[id]
    if not i then
        i = #cnt + 1
        idx[id] = i
        cnt[i] = 1
        a[i * 2 - 1], a[i * 2] = x, y
    else
        local n = cnt[i]
        a[i * 2 - 1] = (a[i * 2 - 1] * n + x) / (n + 1)
        a[i * 2] = (a[i * 2] * n + y) / (n + 1)
        cnt[i] = n + 1
    end
end

-- An area you discovered, at the place you stood; a second visit moves it.
local function AddFound(ms, name, x, y)
    local idx, a, names = List(ms, "foundIdx"), List(ms, "found"), List(ms, "foundName")
    local i = idx[name]
    if not i then
        i = #names + 1
        idx[name] = i
        names[i] = name
    end
    a[i * 2 - 1], a[i * 2] = x, y
end

local function TrailPoint(st, store, m, x, y)
    if st.flying or store.trailN >= TRAIL_CAP then return end
    local ms = MapOf(store, m)
    local same, jump = st.lastM == m, true
    if same then
        local dx, dy = x - st.rx, y - st.ry
        jump = dx * dx + dy * dy > TRAIL_JUMP2
    end
    for i = 1, 3 do
        local t = List(ms, TRAIL_KEYS[i])
        local n = #t
        local lx, ly = TRAIL_LX[i], TRAIL_LY[i]
        if same and not jump then
            local dx, dy = x - st[lx], y - st[ly]
            if dx * dx + dy * dy < TRAIL_STEP2[i] then
                n = nil
            elseif n == 0 then
                -- a store that starts mid-stretch (the open buffer) joins the last point of the one before
                t[1], t[2] = st[lx] / 10000, st[ly] / 10000
                n = 2
            end
        elseif n > 0 and t[n - 1] > -0.5 then
            t[n + 1], t[n + 2] = -1, -1
            n = n + 2
        end
        if n then
            t[n + 1], t[n + 2] = x / 10000, y / 10000
            st[lx], st[ly] = x, y
            if i == 1 then store.trailN = store.trailN + 1 end
        end
    end
    st.lastM, st.rx, st.ry = m, x, y
end

-- Fishing is told apart by name: the spell Forever calls Fishing has more than one id by rank.
local fishName
local fishCache = {}
local function IsFishing(id)
    if not id then return false end
    for i = 1, #FISH_SPELLS do
        if id == FISH_SPELLS[i] then return true end
    end
    local c = fishCache[id]
    if c ~= nil then return c end
    local C = _G.C_Spell
    if not C or not C.GetSpellName then return false end
    if fishName == nil then
        for i = 1, #FISH_SPELLS do
            fishName = C.GetSpellName(FISH_SPELLS[i]) or nil
            if fishName then break end
        end
        fishName = fishName or false
    end
    local name = C.GetSpellName(id)
    if not name then return false end
    c = fishName and name == fishName or false
    fishCache[id] = c
    return c
end

-- Lines of the main recording ---------------------------------------------------------------
-- Field i of a code (counting from 0 as docs/FORMAT.md does) is f[i + 3]: f[1] is dt and f[2] the code.

local H = {}

local function Here(st, store)
    if not st.hm then return end
    return MapOf(store, st.hm), st.hx / 10000, st.hy / 10000
end

H.T = function(st, store, f)
    local m, x, y = tonumber(f[4]), tonumber(f[5]), tonumber(f[6])
    if f[3] == "1" then
        st.flying, st.fm, st.fx, st.fy = true, m, x or 0, y or 0
        st.lastM = nil
    else
        if st.flying and m and x and y and st.fm == m then
            AddSegment(MapOf(store, m), "flights", st.fx / 10000, st.fy / 10000, x / 10000, y / 10000)
        end
        st.flying = false
    end
end

H.TE = function(_, store, f)
    local a, b = tonumber(f[6]), tonumber(f[9])
    local fx, fy, tx, ty = tonumber(f[7]), tonumber(f[8]), tonumber(f[10]), tonumber(f[11])
    if a and a == b and fx and fy and tx and ty then
        AddSegment(MapOf(store, a), "teleports", fx / 10000, fy / 10000, tx / 10000, ty / 10000)
    end
end

H.DL = function(_, store, f)
    local m, x, y = tonumber(f[3]), tonumber(f[4]), tonumber(f[5])
    if m and x and y then
        local a = List(MapOf(store, m), "deaths")
        local n = #a
        a[n + 1], a[n + 2] = x / 10000, y / 10000
    end
end

H.CH = function(st, _, f)
    if IsFishing(tonumber(f[3])) then st.fishedAt = st.ms end
end

H.LO = function(st, store, f)
    if f[3] ~= "g" or f[7] == "1" then return end
    local ms, x, y = Here(st, store)
    if ms then AddPoint(ms, st.ms - st.fishedAt < FISH_MS and "fishing" or "gather", x, y) end
end

H.NI = function(st, store, f)
    local id = f[4]
    if not id or id == "" then return end
    local ms, x, y = Here(st, store)
    if ms then AddNpc(ms, id, x, y) end
end

H.Q = function(st, store, f)
    local kind = f[3]
    if kind ~= "1" and kind ~= "2" then return end
    local ms, x, y = Here(st, store)
    if ms then AddPoint(ms, kind == "1" and "qacc" or "qdone", x, y) end
end

H.EX = function(st, store, f)
    local name = f[3]
    if not name or name == "" then return end
    local ms, x, y = Here(st, store)
    if ms then AddFound(ms, name, x, y) end
end

H.CP = function(st, store, f)
    if f[3] ~= "1" or f[5] == "1" then return end
    local ms, x, y = Here(st, store)
    if ms then AddPoint(ms, "camps", x, y) end
end

local function Main(st, store, line)
    local sp1 = find(line, "\t", 1, true)
    if not sp1 then return end
    st.ms = st.ms + (tonumber(sub(line, 1, sp1 - 1)) or 0) * 10
    local sp2 = find(line, "\t", sp1 + 1, true)
    local code = sub(line, sp1 + 1, sp2 and sp2 - 1 or -1)
    if code == "P" then
        local m, x, y = match(line, "^%d+\tP\t(%d+)\t(%d+)\t(%d+)")
        m, x, y = tonumber(m), tonumber(x), tonumber(y)
        if m and x and y then
            st.hm, st.hx, st.hy = m, x, y
            TrailPoint(st, store, m, x, y)
        end
    elseif code == "S" then
        st.hm, st.flying, st.lastM = nil, false, nil
    elseif code == "Z" then
        local m = tonumber(match(line, "^%d+\tZ\t(%d+)"))
        if st.hm and st.hm ~= m then st.hm = nil end
    else
        local h = H[code]
        if h then h(st, store, { strsplit("\t", line) }) end
    end
end

-- Lines other addons recorded (ScarletAddonsDB): GatherMate2 nodes and The Fishing Log catches.
-- Field i of a code is f[i + 4] here, since the line also names the integration.
local function AddonLine(store, line)
    local sp1 = find(line, "\t", 1, true)
    if not sp1 then return end
    local key = sub(line, sp1 + 1, sp1 + 2)
    if key ~= "gm" and key ~= "fl" then return end
    local f = { strsplit("\t", line) }
    local m, x, y, layer
    if key == "gm" and f[3] == "N" then
        m, x, y = tonumber(f[4]), tonumber(f[5]), tonumber(f[6])
        layer = f[7] == "Fishing" and "fishing" or "gather"
    elseif key == "fl" and f[3] == "C" then
        m, x, y = tonumber(f[9]), tonumber(f[10]), tonumber(f[11])
        layer = "fishing"
    end
    if m and x and y then AddPoint(MapOf(store, m), layer, x / 10000, y / 10000) end
end

-- Reading chunks ----------------------------------------------------------------------------

local function Text(c)
    if c.e == "txt" then return type(c.z) == "string" and c.z or nil end
    if c.e ~= "d64" or type(c.z) ~= "string" then return nil end
    local U = _G.C_EncodingUtil
    if not U or not U.DecodeBase64 or not U.DecompressString then return nil end
    local ok, packed = pcall(U.DecodeBase64, c.z)
    if not ok or type(packed) ~= "string" then return nil end
    local ok2, text = pcall(U.DecompressString, packed, Enum.CompressionMethod.Deflate)
    if ok2 and type(text) == "string" then return text end
end

-- The first chunk numbered above `last`. Chunks are in number order, and the addon drops old ones from
-- the front while a pass is paused, so a position is looked up each time.
local function NextChunk(chunks, last)
    local hi = #chunks
    if hi == 0 or chunks[hi].q <= last then return nil end
    local lo = 1
    while lo < hi do
        local mid = floor((lo + hi) / 2)
        if chunks[mid].q > last then hi = mid else lo = mid + 1 end
    end
    return chunks[lo]
end

local budget, started = 4, 0
local function Pause(force)
    if force or debugprofilestop() - started > budget then coyield() end
end

local function Build()
    local key = ns.charKey
    local db = ns.db
    local chunks = db and db.chunks
    while chunks do
        local c = NextChunk(chunks, stS.lastQ)
        if not c then break end
        stS.lastQ = c.q
        if c.c == key then
            local text = Text(c)
            if text then
                stS.ms = (tonumber(c.t) or 0) * 1000
                local n = 0
                for line in gmatch(text, "[^\n]+") do
                    Main(stS, sealed, line)
                    n = n + 1
                    if n % 128 == 0 then Pause() end
                end
            end
        end
        Pause()
    end
    local adb = _G.ScarletAddonsDB
    chunks = type(adb) == "table" and adb.chunks
    while chunks do
        local c = NextChunk(chunks, stS.lastQa)
        if not c then break end
        stS.lastQa = c.q
        if c.c == key then
            local text = Text(c)
            if text then
                local n = 0
                for line in gmatch(text, "[^\n]+") do
                    AddonLine(sealed, line)
                    n = n + 1
                    if n % 128 == 0 then Pause() end
                end
            end
        end
        Pause()
    end
end

local co
local liveN, liveA, liveT = -1, -1, -100

local function HasNew()
    local db = ns.db
    local chunks = db and db.chunks
    if chunks and #chunks > 0 and chunks[#chunks].q > stS.lastQ then return true end
    local adb = _G.ScarletAddonsDB
    chunks = type(adb) == "table" and adb.chunks
    return chunks and #chunks > 0 and chunks[#chunks].q > stS.lastQa or false
end

local function BufSizes()
    local db = ns.db
    local adb = _G.ScarletAddonsDB
    return db and type(db.buf) == "table" and #db.buf or 0,
        type(adb) == "table" and type(adb.buf) == "table" and #adb.buf or 0
end

local function RebuildLive()
    local db = ns.db
    Reset(live)
    CopyState(stL, stS)
    stL.ms = (tonumber(db and db.bufT) or 0) * 1000
    local buf = db and db.buf
    if type(buf) == "table" then
        for i = 1, #buf do Main(stL, live, buf[i]) end
    end
    local adb = _G.ScarletAddonsDB
    if type(adb) == "table" and type(adb.buf) == "table" and adb.bufC == ns.charKey then
        for i = 1, #adb.buf do AddonLine(live, adb.buf[i]) end
    end
    liveN, liveA = BufSizes()
    liveT = GetTime()
end

-- Brings the index up to date, spending about `ms` milliseconds of this frame on sealed chunks.
-- Returns changed (something new can be drawn) and busy (more to read: call again next frame).
function MD.Pump(ms)
    if not ns.db or not ns.charKey then return false, false end
    budget, started = ms or 4, debugprofilestop()
    local changed = false
    if not co and HasNew() then co = cocreate(Build) end
    if co then
        local ok, err = coresume(co)
        changed = true
        if not ok then
            co = nil
            geterrorhandler()(err)
            return true, false
        end
        if costatus(co) == "dead" then co = nil else return true, true end
    end
    -- The sealed chunks are all read: the open buffers follow, again when they have grown.
    local n, a = BufSizes()
    if n ~= liveN or a ~= liveA then
        if GetTime() - liveT >= LIVE_MAX_AGE or liveN < 0 or n < liveN then
            RebuildLive()
            changed = true
        end
    end
    return changed, false
end

-- Whether the open buffers or unread chunks could hold more than what is drawn (cheap; for polling).
function MD.Stale()
    if co or HasNew() then return true end
    local n, a = BufSizes()
    return n ~= liveN or a ~= liveA
end

-- The index is rebuilt from scratch for another character (a different charKey).
function MD.Forget()
    co = nil
    Reset(sealed)
    Reset(live)
    stS, stL = NewState(), NewState()
    liveN, liveA, liveT = -1, -1, -100
end
