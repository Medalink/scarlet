-- bench.lua: what Scarlet costs per event, under stock Lua 5.1 with stub WoW APIs.
--
--   sh tools/perf/build-lua51.sh <dir>          once: stock Lua 5.1.5 plus os.hires (a 0.03 us clock)
--   python -I tools/perf/svdecode.py <Scarlet.lua SavedVariables> <history.txt>     (read only; keep both out of git)
--   <dir>/lua5.1 tools/perf/bench.lua [--addon DIR] [--history history.txt] [--sv <Scarlet.lua copy>]
--       [--scenario NAME|all] [--cap N] [--out FILE] [--passes time,gc,api] [--scale N] [--perf] [--list]
--
-- Before and after a change: run with --addon <old copy> --out a.txt and --addon <new> --out b.txt, then cmp.
--
-- Scenarios: raid, idle, quest, move, seal, window, map. The streams are generated (fixed seed, virtual
-- clock), so two runs of the same addon see the same events.
-- --history is the decoded recording from svdecode.py (read only, never printed): the window and map
--   scenarios run on it, repeated --scale times (default 1) to stand in for a full 8 MB store.
-- --out writes everything the scenario recorded (ScarletDB, sorted) for a before/after diff.
-- --perf prints the addon's own /scarlet perf report after each scenario.
--
-- Numbers are relative: stock VM, a high resolution clock, stub APIs that cost what a Lua function
-- costs. They say what the addon's Lua does, not what the client's C APIs cost. Deflate is not
-- run here (Core:Encode is timed in game by /scarlet perf).

local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
local Env = dofile(here .. "env.lua")
local hires = os.hires or os.clock
Env.hires = hires

-- Options -----------------------------------------------------------------------------------

local opt = { addon = here .. "../../addon/Scarlet", scenario = "all", scale = 1, passes = "time,gc,api" }
do
    local i = 1
    while i <= #arg do
        local a = arg[i]
        local key = a:match("^%-%-(.+)$")
        if key == "perf" or key == "list" then
            opt[key] = true
        elseif key then
            i = i + 1
            opt[key] = arg[i]
        end
        i = i + 1
    end
    opt.scale = tonumber(opt.scale) or 1
end

local SCENARIOS = { "raid", "idle", "quest", "move", "seal", "window", "map" }
if opt.list then print(table.concat(SCENARIOS, " ")) os.exit(0) end

-- Deterministic random numbers, the same on every platform.
local seed = 12345
local function Rand(n)
    seed = (seed * 1103515245 + 12345) % 2147483648
    return n and (seed % n) + 1 or seed / 2147483648
end

-- History ---------------------------------------------------------------------------------------

local history -- { { q, s, t, n, text }, ... } from svdecode.py, or nil
if opt.history then
    history = {}
    local cur
    for line in io.lines(opt.history) do
        if line:sub(1, 3) == "@@\t" then
            local f = {}
            for v in (line .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = v end
            cur = { q = tonumber(f[2]), s = tonumber(f[4]), t = tonumber(f[5]), n = tonumber(f[6]), lines = {} }
            history[#history + 1] = cur
        elseif cur then
            cur.lines[#cur.lines + 1] = line
        end
    end
    for _, c in ipairs(history) do c.text = table.concat(c.lines, "\n") end
end

-- Stats helpers -----------------------------------------------------------------------------------

local function Quantile(sorted, p)
    local n = #sorted
    if n == 0 then return 0 end
    return sorted[math.min(n, math.max(1, math.ceil(n * p)))]
end

local function Summarize(samples)
    table.sort(samples)
    local sum = 0
    for i = 1, #samples do sum = sum + samples[i] end
    return #samples, Quantile(samples, 0.5), Quantile(samples, 0.99), samples[#samples] or 0, sum
end

-- The clock's own cost (two reads and the call of an empty function), taken off every sample.
local overhead
do
    local f = function() end
    local acc = {}
    for i = 1, 20000 do
        local t0 = hires()
        f()
        acc[i] = (hires() - t0) * 1e6
    end
    local sum = 0
    for i = 1, #acc do sum = sum + acc[i] end
    overhead = sum / #acc -- the clock ticks every 0.1 us, so the median of one call is 0; the mean is not
end

-- Scenario streams ---------------------------------------------------------------------------------
-- An event is { t = seconds, name = "EVENT", a1, a2, a3, a4, pre = function() world changes end }.

local function NewStream()
    local s = { n = 0 }
    -- Up to five event arguments; a function as the last argument runs before the event (the world
    -- changes the event reports) and is not timed.
    function s.add(t, name, ...)
        local n = select("#", ...)
        local args = { ... }
        local pre
        if n > 0 and type(args[n]) == "function" then pre, args[n] = args[n], nil end
        s.n = s.n + 1
        s[s.n] = { t = t, name = name, pre = pre, i = s.n, args[1], args[2], args[3], args[4], args[5] }
    end
    -- fn runs at time t as a measured call under the bucket name; returning false drops the sample.
    function s.call(t, name, fn)
        s.n = s.n + 1
        s[s.n] = { t = t, name = name, call = fn, i = s.n }
    end
    function s.sort()
        table.sort(s, function(a, b)
            if a.t ~= b.t then return a.t < b.t end
            return a.i < b.i
        end)
    end
    return s
end

local function Creature(npc, n)
    return "Creature-0-1-2-3-" .. npc .. "-" .. string.format("%010X", n)
end

local function Aura(iid, spell, helpful)
    return { auraInstanceID = iid, spellId = spell, name = "Aura " .. spell, isHelpful = helpful, duration = 30,
        sourceUnit = "player" }
end

-- A bag with a few stacks, so a bag scan has something to read.
local function Bags(W, n)
    for i = 0, n - 1 do W.bagItems[math.floor(i / 16) * 100 + (i % 16) + 1] = { 2000 + i, 1 + i % 5 } end
end

local function Setup(W, raidSize)
    local P = W.player
    P.group, P.raid = raidSize or 0, (raidSize or 0) > 5
    Bags(W, 52)
    for i = 1, 6 do W.auras.HELPFUL[i] = Aura(100 + i, 5000 + i, true) end
    W.auras.HARMFUL[1] = Aura(200, 6000, false)
    for i = 1, raidSize or 0 do
        W.Unit("raid" .. i, { guid = "Player-1-" .. string.format("%08X", 100 + i), name = "Raider" .. i, player = true,
            level = 60, class = "MAGE", race = "Human", faction = "Alliance", controlled = true })
        W.Unit("raidpet" .. i, { guid = Creature(9000, i), name = "Pet" .. i, level = 60, controlled = true })
    end
end

local SCEN = {}

-- 25 players, one boss and its adds for 110 s. Rates (per second): UNIT_HEALTH on every unit, threat
-- updates on the mobs, nameplates coming and going, the player's own auras and casts.
function SCEN.raid(W)
    Setup(W, 25)
    local s = NewStream()
    local mobs, nextMob = {}, 1
    local function SpawnMob(t)
        local id = nextMob
        nextMob = nextMob + 1
        local slot = (id - 1) % 20 + 1
        local token = "nameplate" .. slot
        local npc = 20000 + id % 7
        s.add(t, "NAME_PLATE_UNIT_ADDED", token, nil, nil, nil, function()
            W.Unit(token, { guid = Creature(npc, id), name = "Add " .. npc, level = 62, classification = "elite" })
            mobs[#mobs + 1] = token
        end)
        s.add(t + 0.01, "UNIT_THREAT_LIST_UPDATE", token, nil, nil, nil, function() W.units[token].threat = 1 end)
        local life = 3 + Rand(12)
        s.add(t + life, "UNIT_HEALTH", token, nil, nil, nil, function() W.units[token].dead = true end)
        s.add(t + life + 0.5, "NAME_PLATE_UNIT_REMOVED", token, nil, nil, nil, function()
            W.units[token] = nil
        end)
    end
    s.add(0, "GROUP_ROSTER_UPDATE")
    s.add(0.2, "PLAYER_REGEN_DISABLED", nil, nil, nil, nil, function() Env.inCombat = true end)
    s.add(0.3, "ENCOUNTER_START", 2000, "Boss", 14, 25, function()
        W.Unit("boss1", { guid = Creature(30000, 1), name = "Boss", level = 63, classification = "worldboss" })
    end)
    local T = 110
    for sec = 0, T - 1 do
        for _ = 1, 600 do
            local r = Rand(100)
            local token
            if r <= 45 then token = "raid" .. Rand(25)
            elseif r <= 65 then token = "raidpet" .. Rand(25)
            elseif r <= 90 then token = "nameplate" .. Rand(20)
            elseif r <= 95 then token = "boss1"
            else token = "target" end
            s.add(sec + Rand() , "UNIT_HEALTH", token)
        end
        for _ = 1, 60 do s.add(sec + Rand(), "UNIT_THREAT_LIST_UPDATE", "nameplate" .. Rand(20)) end
        for _ = 1, 8 do
            local iid, spell = 1000 + sec * 10 + _, 7000 + Rand(40)
            s.add(sec + Rand(), "UNIT_AURA", "player", { addedAuras = { Aura(iid, spell, Rand(2) == 1) } })
            s.add(sec + Rand() + 0.2, "UNIT_AURA", "player", { removedAuraInstanceIDs = { iid } })
        end
        for _ = 1, 2 do
            s.add(sec + Rand(), "UNIT_SPELLCAST_START", "player", "cast", 8000 + Rand(8))
            s.add(sec + Rand(), "UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 8000 + Rand(8))
        end
        for _ = 1, 4 do s.add(sec + Rand(), "ACTIONBAR_SLOT_CHANGED", Rand(120)) end
        for _ = 1, 3 do s.add(sec + Rand(), "UNIT_INVENTORY_CHANGED", "raid" .. Rand(25)) end
        s.add(sec + Rand(), "UNIT_NAME_UPDATE", "raid" .. Rand(25))
        for _ = 1, 2 do s.add(sec + Rand(), "UPDATE_MOUSEOVER_UNIT", nil, nil, nil, nil, function()
            W.Unit("mouseover", { guid = "Player-1-" .. string.format("%08X", 100 + Rand(25)), name = "Raider1", player = true,
                level = 60, class = "MAGE", race = "Human", faction = "Alliance", controlled = true })
        end) end
        s.add(sec + Rand(), "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", 8000 + Rand(8))
        s.add(sec + Rand(), "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE", 8000 + Rand(8))
        if sec % 5 == 0 then s.add(sec + Rand(), "GROUP_ROSTER_UPDATE") end
        if sec % 10 == 0 then s.add(sec + Rand(), "RAID_TARGET_UPDATE") end
        if sec % 3 == 0 then s.add(sec + Rand(), "PLAYER_STARTED_MOVING") s.add(sec + 1 + Rand(), "PLAYER_STOPPED_MOVING") end
        if sec % 7 == 0 then s.add(sec + Rand(), "CRITERIA_UPDATE", 1) end
        if sec % 4 == 0 then SpawnMob(sec + 0.5) end
        if sec % 20 == 0 then s.add(sec + Rand(), "BAG_UPDATE_DELAYED") end
    end
    s.add(T + 0.5, "ENCOUNTER_END", 2000, "Boss", 14, 25, 1)
    s.add(T + 0.6, "BOSS_KILL", 2000, "Boss")
    s.add(T + 0.7, "PLAYER_REGEN_ENABLED", nil, nil, nil, nil, function() Env.inCombat = false end)
    for i = 1, 20 do
        s.add(T + 2 + i * 0.1, "CHAT_MSG_LOOT", "Raider" .. i .. " receives loot: |cff0070dd|Hitem:" .. (3000 + i) .. "::::::::60|h[Item]|h|r.")
    end
    s.add(T + 5, "BAG_UPDATE_DELAYED")
    s.sort()
    return s, T + 12
end

-- A raid between pulls: a minute of members healing back up, pets, nameplates of the city.
function SCEN.idle(W)
    Setup(W, 25)
    local s = NewStream()
    s.add(0, "GROUP_ROSTER_UPDATE")
    for sec = 0, 59 do
        for _ = 1, 250 do
            local r = Rand(100)
            s.add(sec + Rand(), "UNIT_HEALTH", r <= 70 and ("raid" .. Rand(25)) or r <= 90 and ("raidpet" .. Rand(25)) or "target")
        end
        for _ = 1, 4 do s.add(sec + Rand(), "UNIT_AURA", "player", { addedAuras = { Aura(7000 + sec * 4 + _, 7000 + Rand(20), true) } }) end
        s.add(sec + Rand(), "UPDATE_MOUSEOVER_UNIT")
    end
    s.sort()
    return s, 60
end

-- Ten minutes of questing: run, target, fight, loot, quest updates.
function SCEN.quest(W)
    Setup(W, 0)
    local s = NewStream()
    local P = W.player
    local T, id = 600, 0
    local t = 1
    local function Move(t0, secs)
        s.add(t0, "PLAYER_STARTED_MOVING")
        s.add(t0, "UPDATE_UI_WIDGET", { widgetID = 7000 + Rand(3), widgetSetID = 1, widgetType = 0 })
        for k = 1, secs do
            s.add(t0 + k - 0.01, "UNIT_SPELLCAST_SUCCEEDED", "player", "c", 9000 + Rand(2), nil, function()
                P.x, P.y = P.x + 7, P.y + 3
                P.mx, P.my = P.mx + 0.0004, P.my + 0.0002
            end)
        end
        s.add(t0 + secs, "PLAYER_STOPPED_MOVING")
        return t0 + secs
    end
    while t < T - 40 do
        t = Move(t, 12 + Rand(10))
        id = id + 1
        local npc, guid = 40000 + id % 9, Creature(40000 + id % 9, id)
        local token = "nameplate" .. (id % 10 + 1)
        s.add(t + 0.2, "NAME_PLATE_UNIT_ADDED", token, nil, nil, nil, function()
            W.Unit(token, { guid = guid, name = "Mob " .. npc, level = 12, classification = "normal" })
        end)
        s.add(t + 0.3, "PLAYER_TARGET_CHANGED", nil, nil, nil, nil, function() W.units.target = W.units[token] end)
        s.add(t + 0.4, "UPDATE_MOUSEOVER_UNIT", nil, nil, nil, nil, function() W.units.mouseover = W.units[token] end)
        s.add(t + 1, "PLAYER_REGEN_DISABLED", nil, nil, nil, nil, function() Env.inCombat = true end)
        s.add(t + 1.1, "UNIT_THREAT_LIST_UPDATE", token, nil, nil, nil, function() W.units[token].threat = 3 end)
        for k = 1, 5 do
            s.add(t + 1.5 + k, "UNIT_SPELLCAST_START", "player", "c", 9100 + k % 3)
            s.add(t + 2 + k, "UNIT_SPELLCAST_SUCCEEDED", "player", "c", 9100 + k % 3)
            s.add(t + 1.7 + k, "UNIT_HEALTH", token)
            s.add(t + 1.7 + k, "UNIT_HEALTH", "player")
            s.add(t + 1.8 + k, "UNIT_AURA", "player", { addedAuras = { Aura(500 + id * 10 + k, 7100 + k, k % 2 == 0) } })
        end
        s.add(t + 7, "UNIT_HEALTH", token, nil, nil, nil, function() W.units[token].dead = true end)
        s.add(t + 7.05, "PARTY_KILL", P.guid, guid)
        s.add(t + 7.1, "PLAYER_XP_UPDATE", "player", nil, nil, nil, function() P.xp = P.xp + 120 end)
        s.add(t + 7.1, "CHAT_MSG_COMBAT_XP_GAIN", string.format("%s dies, you gain %d experience.", "Mob", 120))
        s.add(t + 7.3, "NAME_PLATE_UNIT_REMOVED", token, nil, nil, nil, function() W.units[token] = nil end)
        s.add(t + 8, "PLAYER_REGEN_ENABLED", nil, nil, nil, nil, function() Env.inCombat = false end)
        s.add(t + 9, "LOOT_READY")
        s.add(t + 9, "LOOT_OPENED")
        s.add(t + 9.2, "CHAT_MSG_LOOT", "You receive loot: |cff9d9d9d|Hitem:" .. (4000 + id % 30) .. "::::::::12|h[Junk]|h|r.")
        s.add(t + 9.2, "CURSOR_CHANGED", true)
        s.add(t + 9.3, "PLAYER_MONEY", nil, nil, nil, nil, function() P.money = P.money + 37 end)
        s.add(t + 9.4, "BAG_UPDATE_DELAYED", nil, nil, nil, nil, function()
            W.bagItems[(60 + id) % 80 + 1] = { 4000 + id % 30, 1 }
        end)
        s.add(t + 9.5, "LOOT_CLOSED")
        if id % 4 == 0 then
            s.add(t + 10, "QUEST_WATCH_UPDATE", 1000 + id % 3)
            s.add(t + 10, "QUEST_LOG_UPDATE")
            s.add(t + 10.1, "QUEST_LOG_UPDATE")
        end
        t = t + 11
    end
    s.sort()
    return s, T
end

-- Running for ten minutes: the position ticker and little else.
function SCEN.move(W)
    Setup(W, 0)
    local s = NewStream()
    local P = W.player
    s.add(1, "PLAYER_STARTED_MOVING")
    for sec = 2, 600 do
        s.add(sec - 0.001, "UNIT_SPELLCAST_SUCCEEDED", "player", "c", 9999, nil, function()
            P.x, P.y = P.x + 7, P.y + 3
            P.mx, P.my = P.mx + 0.0004, P.my + 0.0002
        end)
    end
    s.add(601, "PLAYER_STOPPED_MOVING")
    s.sort()
    return s, 603
end

local DeepCopy
-- Seeding the saved data with the owner's history ---------------------------------------------------

function DeepCopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = DeepCopy(x) end
    return out
end

-- The owner's SavedVariables (read only), parsed once; its Lua is run with an empty environment.
local savedVars
if opt.sv then
    local f = assert(loadfile(opt.sv))
    local env = {}
    setfenv(f, env)
    f()
    savedVars = env.ScarletDB
end

-- Puts the recording's character under the harness's character key, so no real name is used at
-- run time, and points each chunk's payload at its decoded text.
local function InstallSV(ns)
    local W = Env.world
    local db = DeepCopy(savedVars)
    local big, bigN = nil, -1
    for key, ch in pairs(db.chars or {}) do
        local n = 0
        for _ in pairs(ch) do n = n + 1 end
        if n > bigN then big, bigN = key, n end
    end
    db.chars = { ["Tester-Realm"] = db.chars and db.chars[big] or {} }
    db.buf, db.bufT, db.bufC, db.bufS, db.gaps, db.warned = nil, nil, nil, nil, nil, nil
    for i, c in ipairs(db.chunks or {}) do
        c.c = "Tester-Realm"
        if history and history[i] then W.texts[c.z] = history[i].text end
    end
    _G.ScarletDB = db
end

-- Repeats the stored chunks scale times (new numbers), standing in for a store at its 8 MB limit.
local function Scale(ns, scale)
    local db, base = ns.db, ns.db.chunks
    local out, q = {}, 0
    for _ = 1, scale do
        for _, c in ipairs(base) do
            q = q + 1
            local copy = DeepCopy(c)
            copy.q = q
            out[#out + 1] = copy
        end
    end
    db.chunks, db.seq = out, q
    return #out
end

-- Scenarios that run on the owner's saved variables (--sv, with --history for the chunk text).
local NEEDS_SV = { window = true, map = true }

-- Sealing: a thousand real lines in, then the seal, a few times, with a growing store.
function SCEN.seal(W, ns)
    Setup(W, 0)
    local lines = {}
    if history then
        for _, c in ipairs(history) do
            for _, line in ipairs(c.lines) do
                local f = {}
                for v in (line .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = v end
                if #f >= 2 then lines[#lines + 1] = f end
            end
        end
    end
    if #lines < 8000 then
        for i = 1, 8000 do lines[#lines + 1] = { "0", "C", tostring(9000 + i % 50), "" } end
    end
    local s = NewStream()
    local at = 0
    for round = 1, 8 do
        for i = 1, 999 do
            local f = lines[(round - 1) * 999 + i]
            at = at + 0.01
            s.call(at, "Emit (one recorded line)", function() ns.Emit(f[2], unpack(f, 3)) end)
        end
        at = at + 0.01
        s.call(at, "Seal (999 lines, store of " .. (round - 1) .. " chunks)", function() ns.Seal(true) end)
    end
    s.sort()
    return s, at
end

-- The window: first open builds it, then each page is shown and refreshed.
function SCEN.window(W, ns)
    Setup(W, 0)
    local s = NewStream()
    local buttons
    local function Nav()
        if buttons then return buttons end
        buttons = {}
        local win = _G.ScarletWindow
        for _, f in ipairs(Env.frames) do
            if f.kind == "Button" and f.scripts.OnClick and f.parent and f.parent.parent == win then
                buttons[#buttons + 1] = f
            end
        end
        return buttons
    end
    s.call(1, "window: first open (Build)", function() ns.Toggle() end)
    for k = 1, 12 do
        s.call(1 + k * 1.2, "window: show a page", function()
            local b = Nav()[k]
            if not b then return false end
            b.scripts.OnClick(b)
        end)
    end
    s.call(16, "window: hide", function() ns.Toggle() end)
    s.call(17, "window: show again", function() ns.Toggle() end)
    s.sort()
    return s, 20
end

-- The map: the budgeted read of the stored chunks, one 4 ms pump per frame until it is done.
function SCEN.map(W, ns)
    Setup(W, 0)
    local chunks = Scale(ns, opt.scale)
    local s = NewStream()
    local done = false
    for frame = 1, 40000 do
        s.call(1 + frame / 60, "MapData.Pump(4) per frame, " .. chunks .. " chunks", function()
            if done then return false end
            local _, more = ns.MapData.Pump(4)
            if not more then done = true end
        end)
    end
    s.sort()
    return s, 40000 / 60
end

-- Dump ----------------------------------------------------------------------------------------------

local function Dump(v, out, indent)
    local t = type(v)
    if t == "table" then
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b)
            local ta, tb = type(a), type(b)
            if ta ~= tb then return ta < tb end
            return a < b
        end)
        out[#out + 1] = "{"
        for _, k in ipairs(keys) do
            out[#out + 1] = indent .. "  [" .. (type(k) == "string" and string.format("%q", k) or tostring(k)) .. "] = "
            Dump(v[k], out, indent .. "  ")
            out[#out + 1] = ",\n"
        end
        out[#out + 1] = indent .. "}"
    elseif t == "string" then
        out[#out + 1] = string.format("%q", v)
    elseif t == "number" then
        out[#out + 1] = string.format("%.17g", v)
    else
        out[#out + 1] = tostring(v)
    end
end

-- Running a stream ------------------------------------------------------------------------------------

local function Boot(countApi, withSV)
    collectgarbage()
    Env.countApi = countApi or false
    Env.cap = tonumber(opt.cap) -- --cap N: the client reports N as the level cap; without it the cap is unreadable
    local ns = Env.load(opt.addon)
    if withSV and savedVars then InstallSV(ns) end
    Env.login()
    return ns
end

local function Where(fn)
    local info = debug.getinfo(fn, "S")
    return (info.short_src:match("([^/\\]+)$") or "?") .. ":" .. info.linedefined
end

-- Plays the stream. mode "time": per-call microseconds; "gc": bytes allocated with the collector
-- stopped; "api": API calls per event. Returns buckets name -> samples.
local gcStart, gcTotals = 0, nil

local function Play(stream, mode)
    local buckets, dropped = {}, {}
    local function Add(name, v)
        local b = buckets[name]
        if not b then b = {} buckets[name] = b end
        b[#b + 1] = v
    end
    local collect = collectgarbage
    local apiN = 0
    if mode == "time" then
        Env.onTimer = function(fn, dt) Add("timer " .. Where(fn), dt * 1e6 - overhead) end
    elseif mode == "gc" then
        collect("collect")
        collect("stop")
        gcStart = collect("count")
        local before
        Env.onTimerStart = function() before = collect("count") end
        Env.onTimer = function(fn) Add("timer " .. Where(fn), (collect("count") - before) * 1024) end
    else
        local calls = Env.apiCalls
        Env.onTimerStart = function() apiN = 0 for _, n in pairs(calls) do apiN = apiN + n end end
        Env.onTimer = function(fn)
            local total = 0
            for _, n in pairs(calls) do total = total + n end
            Add("timer " .. Where(fn), total - apiN)
        end
    end
    local clockT = 0
    for i = 1, #stream do
        local e = stream[i]
        if e.t > clockT then
            Env.advance(e.t - clockT)
            clockT = e.t
        end
        if e.pre then e.pre() end
        local name = e.name
        local list = Env.byEvent[name]
        local a1, a2, a3, a4, a5 = e[1], e[2], e[3], e[4], e[5]
        if e.call then
            -- A direct call, not an event. Returning false drops the sample (a pass with nothing to do).
            local keep
            if mode == "time" then
                local t0 = hires()
                keep = e.call()
                if keep ~= false then Add(name, (hires() - t0) * 1e6 - overhead) end
            elseif mode == "gc" then
                local m0 = collect("count")
                keep = e.call()
                if keep ~= false then Add(name, (collect("count") - m0) * 1024) end
            else
                local calls, before, after = Env.apiCalls, 0, 0
                for _, n in pairs(calls) do before = before + n end
                keep = e.call()
                for _, n in pairs(calls) do after = after + n end
                if keep ~= false then Add(name, after - before) end
            end
        elseif not list or #list == 0 then
            -- No frame listens: the client never calls the addon, so there is nothing to time.
            dropped[name] = (dropped[name] or 0) + 1
        elseif mode == "time" then
            local t0 = hires()
            for k = 1, #list do local f = list[k] f.scripts.OnEvent(f, name, a1, a2, a3, a4, a5) end
            Add(name, (hires() - t0) * 1e6 - overhead)
        elseif mode == "gc" then
            local m0 = collect("count")
            for k = 1, #list do local f = list[k] f.scripts.OnEvent(f, name, a1, a2, a3, a4, a5) end
            Add(name, (collect("count") - m0) * 1024)
        else
            local calls = Env.apiCalls
            local before = 0
            for _, n in pairs(calls) do before = before + n end
            for k = 1, #list do local f = list[k] f.scripts.OnEvent(f, name, a1, a2, a3, a4, a5) end
            local after = 0
            for _, n in pairs(calls) do after = after + n end
            Add(name, after - before)
        end
    end
    if mode == "gc" then
        -- What the pass allocated in all, and how much of it is still alive after a full collect
        -- (the rest was garbage; the live part is data the addon keeps, such as the map's index).
        local grown = (collect("count") - gcStart) * 1024
        collect("restart")
        collect("collect")
        gcTotals = { grown = grown, kept = (collect("count") - gcStart) * 1024 }
    end
    Env.onTimer, Env.onTimerStart = nil, nil
    return buckets, clockT, dropped
end

-- Reporting ----------------------------------------------------------------------------------------------

local function Pad(s, n) return s .. string.rep(" ", n - #s) end

local function Report(title, T, results)
    print(("== %s: %.0f s of play =="):format(title, T))
    print(Pad("event", 44) .. "      n   med us    p99 us    max us  total ms   B/ev  api/ev")
    local names = {}
    for name in pairs(results.time) do names[#names + 1] = name end
    local total = {}
    for _, name in ipairs(names) do
        local n, med, p99, max, sum = Summarize(results.time[name])
        total[name] = sum
    end
    table.sort(names, function(a, b) return total[a] > total[b] end)
    local sumAll = 0
    for i, name in ipairs(names) do
        local samples = results.time[name]
        local n, med, p99, max, sum = Summarize(samples)
        sumAll = sumAll + sum
        local function Mean(b)
            local acc = b and results[b] and results[b][name]
            if not acc then return nil end
            local x = 0
            for j = 1, #acc do x = x + acc[j] end
            return x / #acc
        end
        local gc, api = Mean("gc"), Mean("api")
        if i <= 45 then
            print(("%s %7d %8.2f %9.2f %9.1f %9.2f %6s %7s"):format(Pad(name, 44), n, med, p99, max, sum / 1000,
                gc and ("%.0f"):format(gc) or "-", api and ("%.1f"):format(api) or "-"))
        end
    end
    print(("total %.1f ms over %.0f s = %.3f ms per second of play"):format(sumAll / 1000, T, sumAll / 1000 / T))
    local drops = {}
    for name, n in pairs(results.dropped or {}) do drops[#drops + 1] = ("%s %d"):format(name, n) end
    table.sort(drops)
    if #drops > 0 then print("not delivered (no frame registered, the client skips them): " .. table.concat(drops, ", ")) end
    print()
end

local function TopApi()
    local list = {}
    for name, n in pairs(Env.apiCalls) do list[#list + 1] = { name, n } end
    table.sort(list, function(a, b) return a[2] > b[2] end)
    local out = {}
    for i = 1, math.min(12, #list) do out[#out + 1] = ("%s %d"):format(list[i][1], list[i][2]) end
    return table.concat(out, ", ")
end

local passes = {}
for p in opt.passes:gmatch("[^,]+") do passes[p] = true end

local function RunScenario(name)
    local results, T, apiTop = {}, 0, nil
    local last, stream
    gcTotals = nil
    for _, mode in ipairs({ "time", "gc", "api" }) do
        if passes[mode] then
            seed = 12345
            local ns = Boot(mode == "api", NEEDS_SV[name])
            local gen = SCEN[name]
            local s, dur = gen(Env.world, ns)
            stream, T = s, dur
            if mode == "time" and opt.perf then ns.Perf.Start() end
            local buckets, _, dropped = Play(s, mode)
            results[mode] = buckets
            if mode == "time" then results.dropped = dropped end
            if mode == "api" then apiTop = TopApi() end
            if mode == "time" and opt.perf then
                print(ns.Perf.Report() or "")
                ns.Perf.Stop()
                last = ns
            end
            if mode == "time" and #Env.errors > 0 then
                print("errors (first of " .. #Env.errors .. "): " .. Env.errors[1])
            end
        end
    end
    Report(name .. " (" .. (stream and stream.n or 0) .. " events)", T, results)
    if gcTotals then
        print(("gc pass: %.0f KB allocated in all, %.0f KB still alive after a full collect"):format(
            gcTotals.grown / 1024, gcTotals.kept / 1024))
    end
    if apiTop then print("API calls, top: " .. apiTop) print() end
    return last
end

-- The recorded-output pass: the same stream, then everything the addon wrote, sorted.
local function Record(name)
    seed = 12345
    local ns = Boot(false, NEEDS_SV[name])
    local s = SCEN[name](Env.world, ns)
    Play(s, "api")
    ns.Seal(true)
    local out = {}
    -- Everything recorded (chunks, buffer, counters) and, once built, the map's index.
    Dump({ db = ScarletDB, map = ns.MapData and ns.MapData.stores }, out, "")
    return table.concat(out)
end

if opt.out and SCEN[opt.scenario] then
    local fh = assert(io.open(opt.out, "wb"))
    fh:write(Record(opt.scenario))
    fh:close()
    print("recorded " .. opt.scenario .. " -> " .. opt.out)
    os.exit(0)
end

print(("lua %s, clock overhead %.3f us taken off every sample, addon %s"):format(_VERSION, overhead, opt.addon))
print()
for _, name in ipairs(SCENARIOS) do
    if (opt.scenario == "all" or opt.scenario == name) and SCEN[name] then
        RunScenario(name)
    end
end
