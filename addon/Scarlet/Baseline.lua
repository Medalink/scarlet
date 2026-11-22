local _, ns = ...

local type, pairs, pcall, tostring, select = type, pairs, pcall, tostring, select
local min = math.min
local sort, concat = table.sort, table.concat
local Emit, Plain = ns.Emit, ns.Plain

local QUEST_LINE_IDS = 400
local EXPLORED_LINE_MAPS = 150
local MAPS_PER_FRAME = 6
local EXPLORED_KEPT_CHARS = 16000
local COSMIC_MAP_TYPE = 0
local ZONE_MAP_TYPE = 3
local COSMIC_MAP_FALLBACK = 946
local PARENT_STEPS = 20
local PROBES_PER_FRAME = 5
local WORLD_BOSS_LOCK = 2

local CONTENT_PROBES = {
    "e:ACTIVE_DELVE_DATA_UPDATE",
    "e:BATTLEFIELDS_SHOW",
    "e:DELVES_ACCOUNT_DATA_ELEMENT_CHANGED",
    "e:FOG_OF_WAR_UPDATED",
    "e:REMIX_END_OF_EVENT",
    "e:SHOW_DELVES_COMPANION_CONFIGURATION_UI",
    "e:WORLD_LOOT_OBJECT_INFO_UPDATED",
    "f:C_DelvesUI.GetCreatureDisplayInfoForCompanion",
    "f:C_DelvesUI.GetCurrentDelvesSeasonNumber",
    "f:C_DelvesUI.GetFactionForCompanion",
    "f:C_DelvesUI.GetFlavorNodeForCompanion",
    "f:C_DelvesUI.GetFlavorNodeNameForCompanion",
    "f:C_DelvesUI.GetPlayerCompanionPDEID",
    "f:C_DelvesUI.GetRoleNodeForCompanion",
    "f:C_DelvesUI.GetTraitTreeForCompanion",
    "f:C_DelvesUI.GetWorldTierDifficultyForActivePlayer",
    "f:C_DelvesUI.HasActiveDelve",
    "f:C_DelvesUI.HasActiveLFGLair",
    "f:C_DelvesUI.IsInLair",
    "f:C_FogOfWar.GetFogOfWarForMap",
    "f:C_PlayerInfo.CanPlayerEnterChromieTime",
    "f:C_PlayerInfo.IsPlayerInChromieTime",
    "f:C_ScenarioInfo.GetTieredEntranceActiveSpells",
    "f:C_ScenarioInfo.IsTieredEntranceScenario",
    "f:C_TimerunningUI.GetActiveTimerunningSeasonID",
    "f:C_WeeklyRewards.GetActivities",
    "f:C_WeeklyRewards.GetNumCompletedDungeonRuns",
    "f:C_WorldLootObject.GetWorldLootObjectInfo",
    "f:C_WorldLootObject.IsWorldLootObject",
    "f:C_WorldLootObject.IsWorldLootObjectInRange",
    "f:UnitChromieTimeID",
}

local PLAYER_UNIT_PROBES = {
    ["C_WorldLootObject.GetWorldLootObjectInfo"] = true,
    ["C_WorldLootObject.IsWorldLootObject"] = true,
    ["C_WorldLootObject.IsWorldLootObjectInRange"] = true,
    ["UnitChromieTimeID"] = true,
}
local PLAYER_MAP_PROBES = {
    ["C_FogOfWar.GetFogOfWarForMap"] = true,
}

local function Num(v)
    if Plain(v) and type(v) == "number" and v == v then return v end
end

local function Str(v)
    if Plain(v) and type(v) == "string" then return v end
end

local function Flag(v)
    if Plain(v) and type(v) == "boolean" then return v and 1 or 0 end
    return ""
end

local function Call(fn, ...)
    if type(fn) ~= "function" then return end
    local ok, a, b, c, d, e, f, g, h, i, j, k, l, m, n = pcall(fn, ...)
    if ok then return a, b, c, d, e, f, g, h, i, j, k, l, m, n end
end

local function Resolve(path)
    local node = _G
    for part in path:gmatch("[^.]+") do
        if type(node) ~= "table" then return end
        node = node[part]
    end
    return node
end

local function BestMap()
    return C_Map and Num(Call(C_Map.GetBestMapForUnit, "player"))
end

local function ClientTable(v)
    return Plain(v) and type(v) == "table"
end

local function IsTrue(v)
    return Plain(v) and v == true
end

local function SortedNumbers(list)
    local out = {}
    if ClientTable(list) then
        for _, v in pairs(list) do
            v = Num(v)
            if v then out[#out + 1] = v end
        end
        sort(out)
    end
    return out
end

local function EmitChunks(code, total, items, per)
    if #items == 0 then
        Emit(code, total, "")
        return
    end
    for first = 1, #items, per do
        Emit(code, total, concat(items, ",", first, min(first + per - 1, #items)))
    end
end

local function QuestsRead()
    local ch = ns.char
    if not ch or not C_QuestLog then return end
    local list = Call(C_QuestLog.GetAllCompletedQuestIDs)
    if not ClientTable(list) then return end
    local ids = SortedNumbers(list)
    local total = #ids
    local base = ch.qb
    if type(base) == "table" and base.total == total - (base.since or 0) then return end
    ch.qb = { total = total, since = 0 }
    EmitChunks("QB", total, ids, QUEST_LINE_IDS)
end

local function QuestTurnedIn()
    local ch = ns.char
    local base = ch and ch.qb
    if type(base) == "table" then base.since = (base.since or 0) + 1 end
end

local function TitlesRead()
    local ch = ns.char
    local count = Num(Call(_G.GetNumTitles))
    if not ch or not count or type(_G.IsTitleKnown) ~= "function" then return end
    local known = {}
    for id = 1, count do
        if IsTrue(Call(_G.IsTitleKnown, id)) then known[#known + 1] = id end
    end
    local line = concat(known, ",")
    if ch.kt == line then return end
    ch.kt = line
    Emit("KT", #known, line)
end

local function CosmicMap()
    local map = BestMap()
    for _ = 1, PARENT_STEPS do
        if not map or map == 0 then break end
        local info = Call(C_Map.GetMapInfo, map)
        if not ClientTable(info) then break end
        if Num(info.mapType) == COSMIC_MAP_TYPE then return map end
        map = Num(info.parentMapID)
    end
    local info = Call(C_Map.GetMapInfo, COSMIC_MAP_FALLBACK)
    if ClientTable(info) and Num(info.mapType) == COSMIC_MAP_TYPE then return COSMIC_MAP_FALLBACK end
end

local function ExploredWrite(entries)
    local ch = ns.char
    if not ch then return end
    local line = concat(entries, ",")
    local kept = line:sub(1, EXPLORED_KEPT_CHARS)
    if ch.eb == kept then return end
    ch.eb = kept
    for first = 1, #entries, EXPLORED_LINE_MAPS do
        Emit("EB", concat(entries, ",", first, min(first + EXPLORED_LINE_MAPS - 1, #entries)))
    end
end

local exploredStarted = false
local function ExploredRead()
    if exploredStarted or not C_Map or not C_MapExplorationInfo then return end
    local cosmic = CosmicMap()
    if not cosmic then return end
    local children = Call(C_Map.GetMapChildrenInfo, cosmic, ZONE_MAP_TYPE, true)
    if not Plain(children) or type(children) ~= "table" then return end
    exploredStarted = true
    local maps = {}
    for _, info in pairs(children) do
        local id = ClientTable(info) and Num(info.mapID)
        if id then maps[#maps + 1] = id end
    end
    sort(maps)
    local entries, nextMap = {}, 1
    local function Step()
        local last = min(nextMap + MAPS_PER_FRAME - 1, #maps)
        for i = nextMap, last do
            local overlays = Call(C_MapExplorationInfo.GetExploredMapTextures, maps[i])
            local n = ClientTable(overlays) and #overlays or 0
            if n > 0 then entries[#entries + 1] = maps[i] .. ":" .. n end
        end
        nextMap = last + 1
        if nextMap <= #maps then
            C_Timer.After(0, Step)
        else
            ExploredWrite(entries)
        end
    end
    Step()
end

local lockSeen = {}
local locksRead = false

local function LocksRead()
    local count = Num(Call(_G.GetNumSavedInstances))
    if not count or type(_G.GetSavedInstanceInfo) ~= "function" then return end
    for i = 1, count do
        local name, lockID, reset, difficulty, locked, extended, _, raid, maxPlayers, _, total, done, _, instanceID =
            Call(_G.GetSavedInstanceInfo, i)
        name, lockID, reset = Str(name), Num(lockID), Num(reset)
        if name and lockID and reset and (reset > 0 or IsTrue(extended)) then
            local key = name .. "|" .. lockID .. "|" .. tostring(Num(difficulty))
            local progress = Num(done) or -1
            if lockSeen[key] ~= progress then
                local why = locksRead and "c" or "s"
                lockSeen[key] = progress
                Emit("IS", name, Num(instanceID), Num(difficulty), reset, Flag(locked), Flag(extended), Flag(raid),
                    Num(maxPlayers), Num(done), Num(total), why)
            end
        end
    end
    local bosses = Num(Call(_G.GetNumSavedWorldBosses)) or 0
    for i = 1, bosses do
        local name, bossID, reset = Call(_G.GetSavedWorldBossInfo, i)
        name, bossID, reset = Str(name), Num(bossID), Num(reset)
        if name and bossID and reset and reset > 0 then
            local key = "w|" .. bossID
            if not lockSeen[key] then
                lockSeen[key] = 1
                Emit("IS", name, bossID, "", reset, 1, 0, WORLD_BOSS_LOCK, "", "", "", locksRead and "c" or "s")
            end
        end
    end
    locksRead = true
end

local function LocksAsk()
    if type(_G.RequestRaidInfo) == "function" then pcall(_G.RequestRaidInfo) end
end

local weatherKey

local function WeatherRead()
    if not C_Weather then return end
    local info = Call(C_Weather.GetCurrentWeather)
    if not ClientTable(info) then return end
    local kind, intensity = Num(info.type), Num(info.intensity)
    if not kind or not intensity then return end
    local key = kind .. ":" .. intensity
    if key == weatherKey then return end
    weatherKey = key
    Emit("WX", kind, intensity)
end

local H = {}
local eventSeen = {}

local function EventProbe(event)
    if eventSeen[event] then return end
    eventSeen[event] = true
    Emit("PR", "?e:" .. event, 1)
end

local function Present(v)
    if not Plain(v) then return 0 end
    if v == true then return 1 end
    if type(v) == "number" then return v > 0 and 1 or 0, v end
    if type(v) == "string" then return v ~= "" and 1 or 0 end
    if ClientTable(v) then
        local n = 0
        for _ in pairs(v) do n = n + 1 end
        return n > 0 and 1 or 0, n
    end
    return 0
end

local function FunctionProbe(path)
    local fn = Resolve(path)
    local arg, needsArg = nil, false
    if PLAYER_UNIT_PROBES[path] then
        arg, needsArg = "player", true
    elseif PLAYER_MAP_PROBES[path] then
        arg, needsArg = BestMap(), true
    end
    local v
    if not needsArg or arg ~= nil then v = Call(fn, arg) end
    local present, detail = Present(v)
    Emit("PR", "?f:" .. path, present, detail)
end

local functionProbes = {}
for _, entry in ipairs(CONTENT_PROBES) do
    local kind, name = entry:sub(1, 1), entry:sub(3)
    if kind == "e" then
        H[name] = function() EventProbe(name) end
    else
        functionProbes[#functionProbes + 1] = name
    end
end

local function ProbesRun()
    local db = ns.db
    if not db then return end
    local build = select(2, GetBuildInfo())
    local key = tostring(build) .. ":" .. date("%Y%m%d")
    if db.contentProbed == key then return end
    db.contentProbed = key
    local nextProbe = 1
    local function Step()
        local last = min(nextProbe + PROBES_PER_FRAME - 1, #functionProbes)
        for i = nextProbe, last do FunctionProbe(functionProbes[i]) end
        nextProbe = last + 1
        if nextProbe <= #functionProbes then C_Timer.After(0, Step) end
    end
    Step()
end

local entered = false

function H.PLAYER_ENTERING_WORLD()
    if entered then return end
    entered = true
    C_Timer.After(8, QuestsRead)
    C_Timer.After(8, TitlesRead)
    C_Timer.After(10, LocksAsk)
    C_Timer.After(12, ExploredRead)
    C_Timer.After(15, ProbesRun)
end

function H.QUEST_TURNED_IN()
    QuestTurnedIn()
end

function H.UPDATE_INSTANCE_INFO()
    if entered then LocksRead() end
end

function H.WEATHER_CHANGED()
    WeatherRead()
end

ns.Listen(CreateFrame("Frame"), H, "Baseline")
