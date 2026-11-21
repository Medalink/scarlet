-- World.lua: the world and travel trackers beyond Capture's movement, zone and flight lines:
--   TN  a flight point's name, once per session, when a flight master's map shows it
--   TF  the flight you picked: destination, origin, price
--   MO  mounting and dismounting, with the mount
--   WP  the map waypoint you set or cleared
--   SM  a summon: offered, accepted, cancelled
--   HB  (baseline) the hearthstone bind found at login when it differs from the last one written
--   TM  a countdown the client started: battleground gates, pull timers, world state timers
--   IB  the countdown that removes you from an instance
--   DF  the dungeon and raid difficulty you have picked
--   VG  a vignette (rare, treasure, event pin) that came into range, and its death
--   AI  an event point of interest on your map, with its timer
--   MP  the minimap tracking types switched on
--   SE  a scenario's stage, its criteria, its end
-- Codes are in docs/FORMAT.md. Event driven only, nothing on a timer except short debounces;
-- every client value goes through Plain() before it is compared or indexed. Nothing here
-- records another player: no summoner, no countdown initiator, no minimap pings.
local _, ns = ...

local type, pcall = type, pcall
local floor, min = math.floor, math.min
local concat = table.concat
local GetTime = GetTime
local Emit, Plain = ns.Emit, ns.Plain
local Round1, SpellName = ns.Round1, ns.SpellName

local MAP = C_Map
local TAXI = C_TaxiMap
local SUMMON = C_SummonInfo
local VIGNETTE = C_VignetteInfo
local POI = C_AreaPoiInfo
local MINIMAP = C_Minimap
local SCENARIO = C_ScenarioInfo
local MOUNTS = C_MountJournal

local frame = CreateFrame("Frame")
local H = {}

local function Str(v)
    if Plain(v) and type(v) == "string" and v ~= "" then return v end
end

local function Num(v)
    if Plain(v) and type(v) == "number" then return v end
end

-- 1 or 0 for a plain boolean, "" for nil or a secret value.
local function Flag(v)
    if not Plain(v) then return "" end
    return v and 1 or 0
end

-- First return value of fn(...), or nil when it errors or comes back secret.
local function Call(fn, ...)
    if type(fn) ~= "function" then return end
    local ok, v = pcall(fn, ...)
    if ok and Plain(v) then return v end
end

-- Every return value of fn(...) in a table, shifted by one: r[1] is pcall's flag.
-- Index it only through Str, Num and Flag.
local function Pack(fn, ...)
    if type(fn) ~= "function" then return end
    local r = { pcall(fn, ...) }
    if r[1] then return r end
end

-- x and y of a Vector2D, which the client gives as a table with a GetXY method.
local function XY(v)
    if type(v) ~= "table" then return end
    local get = v.GetXY
    if type(get) == "function" then
        local ok, x, y = pcall(get, v)
        if ok then return Num(x), Num(y) end
        return
    end
    return Num(v.x), Num(v.y)
end

-- Map units of 1/10000, the way P and DL write them.
local function Units(v)
    return floor(v * 10000 + 0.5)
end

-- One pending call per key: an event that fires in bursts runs its reader once.
local pending = {}
local function Soon(key, delay, fn)
    if pending[key] then return end
    pending[key] = true
    C_Timer.After(delay, function()
        pending[key] = nil
        fn()
    end)
end

local function Store()
    local ch = ns.char
    if not ch then return end
    if type(ch.world) ~= "table" then ch.world = {} end
    return ch.world
end

-- Flights ------------------------------------------------------------------------------
-- TN <nodeID> <name> <state> <slot>: a flight point seen on a flight master's map, once per
-- session. state: 0 you are here, 1 reachable, 2 unreachable (not discovered, or no route).
-- TF <toNodeID> <fromNodeID> <cost>: you picked a flight. cost is copper, empty when the
-- client gave none. The flight itself is Capture's T 1 and T 0 that follow.

local nodes, nodeNamed, origin = {}, {}, nil
local taxiOpen = false

local function Nodes()
    wipe(nodes)
    origin = nil
    if not TAXI then return end
    local map = Num(Call(_G.GetTaxiMapID))
    if not map then return end
    local list = Call(TAXI.GetAllTaxiNodes, map)
    if type(list) ~= "table" then return end
    for i = 1, min(#list, 200) do
        local n = list[i]
        if type(n) == "table" then
            local id, slot, state = Num(n.nodeID), Num(n.slotIndex), Num(n.state)
            local layer = Plain(n.isMapLayerTransition) and n.isMapLayerTransition
            if id and slot and not layer then
                local name = Str(n.name)
                if state == 0 then origin = id end
                local cost = state == 1 and Num(Call(_G.TaxiNodeCost, slot)) or nil
                nodes[slot] = { id = id, cost = cost }
                if name and not nodeNamed[id] then
                    nodeNamed[id] = true
                    Emit("TN", id, name, state or "", slot)
                end
            end
        end
    end
end

function H.TAXIMAP_OPENED()
    taxiOpen = true
    Nodes()
end

function H.TAXIMAP_CLOSED()
    taxiOpen = false
end

function H.TAXI_NODE_STATUS_CHANGED()
    if taxiOpen then Nodes() end
end

local MountEnd

if type(_G.TakeTaxiNode) == "function" then
    hooksecurefunc("TakeTaxiNode", function(slot)
        local n = Plain(slot) and nodes[slot]
        if not n then return end
        Emit("TF", n.id, origin or "", n.cost or "")
        -- A flight ends your mount; the taxi is not a ride.
        MountEnd()
    end)
end

-- Mounts -------------------------------------------------------------------------------
-- MO <1 or 0> <spellID> <mountID> <flyable or seconds> <baseline>: you mounted (1; flyable
-- is whether the area allows flying) or dismounted (0; seconds mounted). baseline `s` for a
-- mount already on when the session started. No line while on a taxi, and a mount still on
-- at logout has no end line: the session end closes it.

local mount

local function ActiveMount()
    if not MOUNTS then return end
    local ids = Call(MOUNTS.GetMountIDs)
    if type(ids) ~= "table" then return end
    for i = 1, min(#ids, 1500) do
        local r = Pack(MOUNTS.GetMountInfoByID, ids[i])
        if r and Plain(r[5]) and r[5] then
            -- r[1] is pcall's flag: r[3] is spellID; the loop's id is the mountID.
            return Num(r[3]), Num(ids[i])
        end
    end
end

local function MountCheck(initial)
    local on = Call(_G.IsMounted)
    if on == nil or Call(_G.UnitOnTaxi, "player") then return end
    on = on and true or false
    if on == (mount ~= nil) then return end
    if on then
        local spell, id = ActiveMount()
        if spell then SpellName(spell) end
        mount = { t = GetTime(), spell = spell or "", id = id or "" }
        Emit("MO", 1, mount.spell, mount.id, Flag(Call(_G.IsFlyableArea)), initial and "s" or "")
    else
        MountEnd()
    end
end

function MountEnd()
    local m = mount
    if not m then return end
    mount = nil
    Emit("MO", 0, m.spell, m.id, Round1(GetTime() - m.t))
end

-- The display changes in a burst, and a taxi takes the mount away: read the state once the
-- client has settled.
function H.PLAYER_MOUNT_DISPLAY_CHANGED()
    Soon("mount", 0.6, MountCheck)
end

-- Waypoint ------------------------------------------------------------------------------
-- WP <1 or 0> <uiMapID> <x> <y> <baseline>: the map waypoint you set (x and y are map
-- coordinates times 10000) or cleared. baseline `s` for one already set at login.

local waypoint

local function Waypoint(initial)
    if not MAP then return end
    local p = Call(MAP.GetUserWaypoint)
    local map, x, y
    if type(p) == "table" then
        map = Num(p.uiMapID)
        x, y = XY(p.position)
    end
    local key = (map and x and y) and (map .. ":" .. Units(x) .. ":" .. Units(y)) or ""
    if key == waypoint then return end
    local had = waypoint
    waypoint = key
    if key ~= "" then
        Emit("WP", 1, map, Units(x), Units(y), initial and "s" or "")
    elseif had and had ~= "" then
        Emit("WP", 0)
    end
end

function H.USER_WAYPOINT_UPDATED()
    Waypoint()
end

-- Summons --------------------------------------------------------------------------------
-- SM <kind> <reason> <area> <seconds> <skipsStart>: kind `o` a summon was offered (reason is
-- the client's summon reason, area the name of the place, seconds what it allows to answer,
-- skipsStart `1` when it skips the start experience), `a` you accepted it, `x` it was
-- cancelled or ran out. The summoner is not recorded.

local summon

function H.CONFIRM_SUMMON(reason, skipping)
    local left = SUMMON and Num(Call(SUMMON.GetSummonConfirmTimeLeft))
    summon = GetTime()
    Emit("SM", "o", Num(reason) or (SUMMON and Num(Call(SUMMON.GetSummonReason))) or "",
        SUMMON and Str(Call(SUMMON.GetSummonConfirmAreaName)) or "", left and floor(left) or "",
        Plain(skipping) and Flag(skipping) or (SUMMON and Flag(Call(SUMMON.IsSummonSkippingStartExperience))) or "")
end

local function SummonEnd(kind)
    if not summon then return end
    summon = nil
    Emit("SM", kind)
end

function H.CANCEL_SUMMON()
    SummonEnd("x")
end

-- Accepting and declining are calls, not events: the popup's buttons run them.
if SUMMON and type(SUMMON.ConfirmSummon) == "function" then
    hooksecurefunc(SUMMON, "ConfirmSummon", function() SummonEnd("a") end)
end
if SUMMON and type(SUMMON.CancelSummon) == "function" then
    hooksecurefunc(SUMMON, "CancelSummon", function() SummonEnd("x") end)
end

-- Hearthstone bind ------------------------------------------------------------------------
-- HB <place> <why> is Track's line when you bind. This adds why `s`: the bind found at
-- login when it differs from the last one this character wrote, so a bind set while the
-- addon was off, or before it existed, still has a line.

local function Home()
    local w = Store()
    local place = Str(Call(_G.GetBindLocation))
    if not w or not place or w.home == place then return end
    w.home = place
    Emit("HB", place, "s")
end

-- Track writes the HB line for a new bind; remember it so the next login does not repeat it.
function H.HEARTHSTONE_BOUND()
    C_Timer.After(1, function()
        local w = Store()
        local place = Str(Call(_G.GetBindLocation))
        if w and place then w.home = place end
    end)
end

-- Timers ---------------------------------------------------------------------------------
-- TM <1 or 0> <type> <seconds> <total> <id>: a countdown the client started (1) or ended
-- (0). type: `pvp` the battleground gate timer, `challenge` a challenge start countdown,
-- `countdown` a group pull timer, `plunder` Plunderstorm, `world` a world state timer (id is
-- its timerID, seconds empty). The player who started a pull timer is not recorded.
-- Breath and fatigue are MT.

local TIMER = { [0] = "pvp", [1] = "challenge", [2] = "countdown", [3] = "plunder" }
local lastCountdown = 0

local function Timer(kind, remaining, total)
    local name = TIMER[Num(kind)] or ""
    if name == "countdown" then
        local now = GetTime()
        if now - lastCountdown < 1 then return end
        lastCountdown = now
    end
    Emit("TM", 1, name, Num(remaining) and floor(remaining) or "", Num(total) and floor(total) or "")
end

function H.START_TIMER(kind, remaining, total)
    Timer(kind, remaining, total)
end

function H.START_PLAYER_COUNTDOWN(_, remaining, total)
    Timer(2, remaining, total)
end

function H.STOP_TIMER_OF_TYPE(kind)
    Emit("TM", 0, TIMER[Num(kind)] or "")
end

function H.CANCEL_PLAYER_COUNTDOWN()
    Emit("TM", 0, "countdown")
end

function H.WORLD_STATE_TIMER_START(id)
    Emit("TM", 1, "world", "", "", Num(id) or "")
end

function H.WORLD_STATE_TIMER_STOP(id)
    Emit("TM", 0, "world", "", "", Num(id) or "")
end

-- Instances --------------------------------------------------------------------------------
-- IB <1 or 0> <seconds>: the countdown that removes you from an instance started (seconds
-- left) or stopped.
-- DF <dungeon> <raid> <legacyRaid> <why>: the difficulty ids you have picked. why `s` at
-- login, `c` a change. Written only when a value differs from the last DF line.

function H.INSTANCE_BOOT_START()
    local left = Num(Call(_G.GetInstanceBootTimeRemaining))
    Emit("IB", 1, left and floor(left) or "")
end

function H.INSTANCE_BOOT_STOP()
    Emit("IB", 0)
end

local difficulty

local function Difficulty()
    local d = Num(Call(_G.GetDungeonDifficultyID))
    local r = Num(Call(_G.GetRaidDifficultyID))
    local l = Num(Call(_G.GetLegacyRaidDifficultyID))
    if not d and not r and not l then return end
    local key = (d or "") .. ":" .. (r or "") .. ":" .. (l or "")
    if key == difficulty then return end
    local first = difficulty == nil
    difficulty = key
    Emit("DF", d or "", r or "", l or "", first and "s" or "c")
end

function H.PLAYER_DIFFICULTY_CHANGED()
    Soon("difficulty", 1, Difficulty)
end

-- Vignettes ---------------------------------------------------------------------------------
-- VG <kind> <vignetteID> <type> <npcID> <uiMapID> <x> <y> <name>: a vignette (a rare, a
-- treasure, an event pin) came into range (kind `s`), or the first time it was seen dead
-- (`d`). type is the client's VignetteType (`0` normal, `1` PvP bounty, `3` treasure). npcID
-- is the creature behind it when it is one. x and y are map coordinates times 10000. Each
-- vignette is written once per session.

local vSeen, vCount = {}, 0
local VIGNETTE_MAX = 400

local function VignetteLine(kind, guid, info)
    local map = Num(Call(MAP.GetBestMapForUnit, "player"))
    local x, y
    if map then x, y = XY(Call(VIGNETTE.GetVignettePosition, guid, map)) end
    local npc = ns.NpcID(info.objectGUID)
    Emit("VG", kind, Num(info.vignetteID) or "", Num(info.type) or "", type(npc) == "number" and npc or "",
        map or "", x and Units(x) or "", y and Units(y) or "", Str(info.name) or "")
end

local function Vignettes()
    if not VIGNETTE or not MAP then return end
    local list = Call(VIGNETTE.GetVignettes)
    if type(list) ~= "table" then return end
    local n = min(#list, 100)
    -- At the cap keep only the vignettes still in range, so none of them is written again.
    if vCount >= VIGNETTE_MAX then
        local keep, kept = {}, 0
        for i = 1, n do
            local guid = list[i]
            if Plain(guid) and vSeen[guid] then
                keep[guid] = vSeen[guid]
                kept = kept + 1
            end
        end
        vSeen, vCount = keep, kept
    end
    for i = 1, n do
        local guid = list[i]
        -- A vignette already written dead has nothing left to say.
        if Plain(guid) and type(guid) == "string" and vSeen[guid] ~= 2 then
            local info = Call(VIGNETTE.GetVignetteInfo, guid)
            if type(info) == "table" then
                local dead = Plain(info.isDead) and info.isDead
                local seen = vSeen[guid]
                if not seen then
                    vCount = vCount + 1
                    vSeen[guid] = dead and 2 or 1
                    VignetteLine("s", guid, info)
                elseif seen == 1 and dead then
                    vSeen[guid] = 2
                    VignetteLine("d", guid, info)
                end
            end
        end
    end
end

function H.VIGNETTES_UPDATED()
    Soon("vignettes", 1, Vignettes)
end

-- Event points of interest -----------------------------------------------------------------
-- AI <poiID> <uiMapID> <seconds> <current> <name>: an event point of interest on your map
-- (or the maps above it) that you had not seen this session. seconds is what its timer has
-- left, empty when it has none. current is `1` for the event running now.

local poiSeen, poiCount = {}, 0
local POI_MAX = 300

local function Pois()
    if not POI or not MAP then return end
    local map = Num(Call(MAP.GetBestMapForUnit, "player"))
    for _ = 1, 4 do
        if not map then return end
        local ids = Call(POI.GetEventsForMap, map)
        if type(ids) == "table" then
            for i = 1, min(#ids, 50) do
                local id = Num(ids[i])
                local key = id and (map .. ":" .. id)
                if key and not poiSeen[key] then
                    local info = Call(POI.GetAreaPOIInfo, map, id)
                    if type(info) == "table" then
                        if poiCount >= POI_MAX then poiSeen, poiCount = {}, 0 end
                        poiCount = poiCount + 1
                        poiSeen[key] = true
                        local timed = Call(POI.IsAreaPOITimed, id)
                        local left = timed and Num(Call(POI.GetAreaPOISecondsLeft, id)) or nil
                        Emit("AI", id, map, left and floor(left) or "", Flag(info.isCurrentEvent),
                            Str(info.name) or "")
                    end
                end
            end
        end
        local info = Call(MAP.GetMapInfo, map)
        map = type(info) == "table" and Num(info.parentMapID) or nil
        if map == 0 then return end
    end
end

function H.AREA_POIS_UPDATED()
    Soon("pois", 2, Pois)
end

-- Minimap tracking ---------------------------------------------------------------------------
-- MP <types> <why>: the tracking types switched on, comma-joined: a spellID, or the name when
-- the type has none. why `s` at login, `c` a change. Written only when the set differs.

local tracking

local function Tracking()
    if not MINIMAP then return end
    local n = Num(Call(MINIMAP.GetNumTrackingTypes))
    if not n then return end
    local on = {}
    for i = 1, min(n, 40) do
        local t = Call(MINIMAP.GetTrackingInfo, i)
        if type(t) == "table" and Plain(t.active) and t.active then
            local spell = Num(t.spellID)
            if spell then
                SpellName(spell)
                on[#on + 1] = spell
            elseif Str(t.name) then
                on[#on + 1] = t.name
            end
        end
    end
    local key = concat(on, ",")
    if key == tracking then return end
    local first = tracking == nil
    tracking = key
    if first and key == "" then return end
    Emit("MP", key, first and "s" or "c")
end

function H.MINIMAP_UPDATE_TRACKING()
    Soon("tracking", 1, Tracking)
end

-- Scenarios ------------------------------------------------------------------------------------
-- SE s <scenarioID> <stage> <numStages> <name> <area>: a scenario started or reached a new stage.
-- SE l <scenarioID>: you left it. SE c <scenarioID> <xp> <money>: it was completed.
-- SE p <scenarioID> <criteriaID> <quantity> <total> <done> <text>: a criterion changed (text on
-- the first line for it in a session). Written when the numbers differ from the last line.

local scenario                  -- scenarioID of the one you are in
local scenarioStage             -- "<id>:<stage>"
local crit, critCount = {}, 0

local function Scenario()
    local info = SCENARIO and Call(SCENARIO.GetScenarioInfo)
    -- Outside a scenario the client answers with scenarioID 0.
    if type(info) ~= "table" or not Num(info.scenarioID) or info.scenarioID <= 0 then
        if scenario then
            Emit("SE", "l", scenario)
            scenario, scenarioStage = nil, nil
        end
        return
    end
    local id = info.scenarioID
    local key = id .. ":" .. (Num(info.currentStage) or "")
    if key == scenarioStage then return end
    scenario, scenarioStage = id, key
    Emit("SE", "s", id, Num(info.currentStage) or "", Num(info.numStages) or "", Str(info.name) or "",
        Str(info.area) or "")
end

function H.SCENARIO_UPDATE()
    Soon("scenario", 0.5, Scenario)
end

function H.SCENARIO_COMPLETED(_, xp, money)
    Emit("SE", "c", scenario or "", Num(xp) or "", Num(money) or "")
end

function H.SCENARIO_CRITERIA_UPDATE(criteriaID)
    local cid = Num(criteriaID)
    if not cid or not scenario or not SCENARIO then return end
    local step = Call(SCENARIO.GetScenarioStepInfo)
    local n = type(step) == "table" and Num(step.numCriteria) or nil
    if not n then return end
    for i = 1, min(n, 30) do
        local c = Call(SCENARIO.GetCriteriaInfo, i)
        if type(c) == "table" and Num(c.criteriaID) == cid then
            local qty, total, done = Num(c.quantity), Num(c.totalQuantity), Flag(c.completed)
            local key = scenario .. ":" .. cid
            local state = (qty or "") .. ":" .. (total or "") .. ":" .. done
            local before = crit[key]
            if before == state then return end
            if before == nil then
                critCount = critCount + 1
                if critCount > 300 then crit, critCount = {}, 1 end
            end
            crit[key] = state
            Emit("SE", "p", scenario, cid, qty or "", total or "", done, before == nil and Str(c.description) or "")
            return
        end
    end
end

-- Lifecycle -------------------------------------------------------------------------------------

local entered = false
function H.PLAYER_ENTERING_WORLD()
    if entered then return end
    entered = true
    -- Zone and mount state settle after the loading screen; the baselines wait for them.
    C_Timer.After(6, function()
        Home()
        Difficulty()
        Waypoint(true)
        Tracking()
        MountCheck(true)
        Scenario()
        Vignettes()
        Pois()
    end)
end

ns.Listen(frame, H, "World")
