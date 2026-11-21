-- Places.lua: where creatures and objects are met.
--   NP  a map cell where an npc or an object was seen, talked to or looted
-- Codes are in docs/FORMAT.md. No events of its own: Capture (sight), Quests (a window opened) and
-- Metrics (a loot window read) call ns.Place and ns.PlaceGUID at the moment they see the thing.
-- The cell is where YOU stood, as in NS: the client gives no position for another unit. Your own cell
-- is read at most once a second (compared against GetTime, no timer). Every client value goes
-- through Plain() before it is compared or indexed.
local _, ns = ...

local floor, type, tonumber, strsplit = math.floor, type, tonumber, strsplit
local GetTime = GetTime
local Emit, Plain = ns.Emit, ns.Plain

local CELL = 150          -- 0.015 of the map in the map's 1/10000 units, like NS
local KEYS_CAP = 4000     -- npc or object and map pairs a character keeps
local CELLS_PER = 24      -- cells kept for one npc or object on one map
local SESSION_CAP = 1500  -- NP lines a session
local KEY_SHIFT = 16384   -- key = id * KEY_SHIFT + uiMapID

local function Num(v)
    if Plain(v) and type(v) == "number" then return v end
end

local ses = { n = {}, o = {} } -- session: kind -> key -> cells
local sesN = 0

-- Your own cell on the map you are on, kept for a second.
local hereT, hereMap, hereCell = -10, nil, nil
-- Capture calls this on every zone change and loading screen.
function ns.PlaceMoved() hereT = -10 end
local function Here()
    local now = GetTime()
    if now - hereT >= 1 then
        hereT = now
        local map, x, y = ns.MapPoint()
        if map and x and y then
            hereMap, hereCell = map, floor(x / CELL) * 100 + floor(y / CELL)
        else
            hereMap, hereCell = nil, nil
        end
    end
    return hereMap, hereCell
end

local function Has(list, cell)
    for i = 1, #list do
        if list[i] == cell then return true end
    end
    return false
end

-- kind `n` a creature (npcID) or `o` an object (objectID); how `s` seen, `t` talked to, `l` looted.
-- unit is the token of a seen creature, so a pet or another player's creature can be skipped.
function ns.Place(kind, id, how, unit)
    id = Num(id)
    if not id or id < 0 or sesN >= SESSION_CAP then return end
    if unit then
        local controlled = UnitPlayerControlled(unit)
        if not Plain(controlled) or controlled then return end
    end
    local map, cell = Here()
    if not map or not cell or map >= KEY_SHIFT then return end
    local key = id * KEY_SHIFT + map
    local byKey = ses[kind]
    local mine = byKey[key]
    if mine and Has(mine, cell) then return end
    if mine and #mine >= CELLS_PER then return end
    local ch = ns.char
    if not ch then return end
    local np = ch.np
    if type(np) ~= "table" then
        np = { n = {}, o = {}, k = 0 }
        ch.np = np
    end
    local seen = np[kind]
    local kept = seen[key]
    if not mine then
        mine = {}
        byKey[key] = mine
    end
    mine[#mine + 1] = cell
    if kept then
        if Has(kept, cell) or #kept >= CELLS_PER then return end
    elseif np.k < KEYS_CAP then
        kept = {}
        seen[key] = kept
        np.k = np.k + 1
    end
    if kept then kept[#kept + 1] = cell end
    sesN = sesN + 1
    Emit("NP", kind, id, map, floor(cell / 100), cell % 100, how)
end

-- The same from a guid: Creature and Vehicle guids carry an npcID, GameObject guids an objectID.
function ns.PlaceGUID(guid, how)
    if not Plain(guid) or type(guid) ~= "string" then return end
    local kind, _, _, _, _, id = strsplit("-", guid)
    id = tonumber(id)
    if kind == "Creature" or kind == "Vehicle" then
        ns.Place("n", id, how)
    elseif kind == "GameObject" then
        ns.Place("o", id, how)
    end
end
