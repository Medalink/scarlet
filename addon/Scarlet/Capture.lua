-- Capture.lua: turns game events into Scarlet lines. Event driven only: no
-- combat log events (Forever blocks them), unit events for "player" only, and
-- a 1 s ticker that runs only while the player is moving.
local ADDON, ns = ...

local floor, abs, sqrt, tonumber, type, strsplit = math.floor, math.abs, math.sqrt, tonumber, type, strsplit
local GetTime = GetTime
local Emit, Add, Plain, Ov = ns.Emit, ns.Add, ns.Plain, ns.Ov
local issecretvalue = issecretvalue or function(_) return false end

local SAMPLE_SECONDS = 1
local MAX_YARDS_PER_SECOND = 120 -- anything faster between samples is a teleport
local PATH_MIN_STEP = 3         -- map units of 1/10000; skip path points closer than this
local WALK_MAX = 4              -- yards/s on foot below this is walking (walk 2.5, backpedal 4.5, run 7)
local MODE_STAT = { f = "foot", w = "walk", m = "mount", s = "swim", a = "fly" }
local MODE_TIME = { f = "footTime", w = "walkTime", m = "mountTime", s = "swimTime", a = "flyTime" }

local frame = CreateFrame("Frame")
local H = {}
local playerGUID

local function Round1(v) return floor(v * 10 + 0.5) / 10 end

-- Small readers for client values: a field that is secret, missing or the wrong type reads as nil.
local function Str(v)
    if Plain(v) and type(v) == "string" and v ~= "" then return v end
end

local function Num(v)
    if Plain(v) and type(v) == "number" then return v end
end

-- Every return value of fn(...) in a table, shifted by one: r[1] is pcall's flag.
-- Index it only through Str and Num.
local function Pack(fn, ...)
    if type(fn) ~= "function" then return end
    local r = { pcall(fn, ...) }
    if r[1] then return r end
end

-- Movement --------------------------------------------------------------------

local move = { on = false }
local ticker
local taxi = { on = false }

local function Mode()
    if IsFlying() then return "a" end
    if IsSwimming() then return "s" end
    if IsMounted() then return "m" end
    -- There is no walk-toggle API, so walking is told apart by speed. A slow
    -- (Hamstring, Crippling Poison) can also put a run under this line.
    local speed = GetUnitSpeed("player")
    if Plain(speed) and speed > 0 and speed < WALK_MAX then return "w" end
    return "f"
end

-- Time totals: one running timer per stat key, added to the stat when it stops.
local timers = {}
local function TimerOn(key)
    if not timers[key] then timers[key] = GetTime() end
end
local function TimerOff(key)
    local t0 = timers[key]
    if t0 then
        timers[key] = nil
        Add(key, GetTime() - t0)
    end
end
local function TimerSet(onKey, offKey, on)
    if on then TimerOff(offKey) TimerOn(onKey) else TimerOff(onKey) TimerOn(offKey) end
end

-- Seconds on the timers still running, so the window can include them.
function ns.OpenTimers(out)
    wipe(out)
    local now = GetTime()
    for k, t0 in pairs(timers) do out[k] = now - t0 end
    return out
end

-- Standing still: time between stopping and starting to move, outside taxis.
local function FlushStill() TimerOff("stillTime") end

-- The way the player faces, as one of 16 directions (0 north, counter-clockwise like the client's
-- radians), empty when the client gives none.
local function Facing()
    local f = _G.GetPlayerFacing and _G.GetPlayerFacing()
    if not Plain(f) or type(f) ~= "number" then return "" end
    return floor(f / (2 * math.pi) * 16 + 0.5) % 16
end

local function MapPoint()
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID or not Plain(mapID) then return end
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return end
    local x, y = pos:GetXY()
    if not Plain(x) or not Plain(y) then return end
    return mapID, floor(x * 10000 + 0.5), floor(y * 10000 + 0.5)
end

local function WorldPos()
    local x, y, _, inst = UnitPosition("player")
    if Plain(x) and Plain(y) and Plain(inst) then return x, y, inst end
end

local function Sample()
    local now = GetTime()
    local dt = now - move.tLast
    move.tLast = now
    local x, y, inst = WorldPos()
    local d
    if x and move.x and inst == move.inst then
        local dx, dy = x - move.x, y - move.y
        d = sqrt(dx * dx + dy * dy)
        if d > dt * MAX_YARDS_PER_SECOND + 5 then d = 0 end
    else
        local speed = GetUnitSpeed("player")
        d = (Plain(speed) and speed or 0) * dt
    end
    move.x, move.y, move.inst = x, y, inst
    move.yards = move.yards + d
    if ns.opt.path then
        local m, px, py = MapPoint()
        if m and (m ~= move.map or abs(px - move.px) + abs(py - move.py) >= PATH_MIN_STEP) then
            move.map, move.px, move.py = m, px, py
            Emit("P", m, px, py, Facing())
        end
    end
end

local JUMP_AT_CAP = 20

local function StartSegment()
    local now = GetTime()
    move.on, move.mode, move.t0, move.tLast = true, Mode(), now, now
    move.yards, move.jumps, move.jumpAt = 0, 0, {}
    move.x, move.y, move.inst = WorldPos()
end

local function EndSegment()
    if not move.on then return end
    Sample()
    move.on = false
    local yards, secs = move.yards, GetTime() - move.t0
    Add(MODE_TIME[move.mode], secs)
    if yards >= 1 then
        Emit("W", move.mode, floor(yards + 0.5), Round1(secs), move.jumps, table.concat(move.jumpAt or {}, ","))
        Add(MODE_STAT[move.mode], yards)
    end
end

local function StopTicker()
    if ticker then ticker:Cancel(); ticker = nil end
end

local function Tick()
    if not move.on then StopTicker() return end
    if UnitOnTaxi("player") then
        EndSegment()
        StopTicker()
        return
    end
    Sample()
    if Mode() ~= move.mode then
        EndSegment()
        StartSegment()
    end
end

function H.PLAYER_STARTED_MOVING()
    if move.on or taxi.on or UnitOnTaxi("player") then return end
    FlushStill()
    StartSegment()
    if ns.opt.path then
        local m, px, py = MapPoint()
        -- The client can toggle started/stopped moving many times a second on the same spot;
        -- like Sample, a point closer than PATH_MIN_STEP to the last one is not written again.
        if m and (m ~= move.map or not move.px
                or abs(px - move.px) + abs(py - move.py) >= PATH_MIN_STEP) then
            move.map, move.px, move.py = m, px, py
            Emit("P", m, px, py, Facing())
        end
    end
    if not ticker then ticker = C_Timer.NewTicker(SAMPLE_SECONDS, ns.Perf.Fn("Capture:Tick", Tick)) end
end

function H.PLAYER_STOPPED_MOVING()
    EndSegment()
    StopTicker()
    if not taxi.on then TimerOn("stillTime") end
end

if JumpOrAscendStart then
    hooksecurefunc("JumpOrAscendStart", function()
        if IsFlying() or IsSwimming() then return end
        Add("jumps")
        if move.on then
            move.jumps = move.jumps + 1
            local at = move.jumpAt
            if at and #at < JUMP_AT_CAP then at[#at + 1] = Round1(GetTime() - move.t0) end
        end
    end)
end

local function TaxiCheck()
    if taxi.on or not UnitOnTaxi("player") then return end
    EndSegment()
    StopTicker()
    FlushStill()
    taxi.on, taxi.t0 = true, GetTime()
    local m, x, y = MapPoint()
    Emit("T", 1, m, x, y)
    Add("flights")
end

function H.PLAYER_CONTROL_LOST()
    C_Timer.After(0.5, TaxiCheck)
end

function H.PLAYER_CONTROL_GAINED()
    if not taxi.on then return end
    taxi.on = false
    local m, x, y = MapPoint()
    local secs = GetTime() - taxi.t0
    Emit("T", 0, m, x, y, Round1(secs))
    Add("taxiTime", secs)
    TimerOn("stillTime")
end

-- Zones -------------------------------------------------------------------------

-- SZ <uiMapID> <subzone> <x> <y>: the first time this character enters a subzone, and where
-- it stood on the map (the P units). The companion's Survey map reads its place names from
-- the client's own tables, which several maps have none of; these lines give it a point
-- there. One line per subzone per character, so it costs almost nothing after the first
-- visit. The set is kept in the character's SavedVariables up to SZ_CAP subzones; past that
-- a subzone is written once a session, like II.
local SZ_CAP = 2000
local szRetries, szSession = 0, {}

local function Subzone()
    local ch = ns.char
    local sub = Str(GetSubZoneText())
    if not ch or not sub then return end
    local map, x, y = MapPoint()
    if not map or not x or not y then
        -- At login the map position can still be missing; wait for the world to settle.
        if szRetries < 10 then
            szRetries = szRetries + 1
            C_Timer.After(1, Subzone)
        end
        return
    end
    szRetries = 0
    local seen = ch.sz
    if type(seen) ~= "table" then
        seen = {}
        ch.sz, ch.szN = seen, 0
    end
    local key = ns.Field(map) .. ":" .. ns.Field(sub)
    if seen[key] then return end
    if (ch.szN or 0) >= SZ_CAP then
        if szSession[key] then return end
        szSession[key] = true
    else
        seen[key] = true
        ch.szN = (ch.szN or 0) + 1
    end
    Emit("SZ", map, sub, x, y)
end

local lastZone
local zoneRetries = 0
local function Zone()
    if ns.PlaceMoved then ns.PlaceMoved() end
    local mapID = C_Map.GetBestMapForUnit("player")
    local _, itype, diff, _, _, _, _, inst = GetInstanceInfo()
    local zone, sub = GetRealZoneText(), GetSubZoneText()
    -- At login the zone name is still empty and the map is the continent;
    -- wait for the world to finish loading instead of logging a blank zone.
    if Plain(zone) and zone == "" then
        if zoneRetries < 10 then
            zoneRetries = zoneRetries + 1
            C_Timer.After(1, Zone)
        end
        return
    end
    zoneRetries = 0
    local key = ns.Field(mapID) .. ":" .. ns.Field(inst) .. ":" .. ns.Field(zone) .. ":" .. ns.Field(sub)
    if key == lastZone then return end
    lastZone = key
    Emit("Z", mapID, inst, itype, diff, zone, sub)
    -- A subzone with no name yet has nothing to record; one late look covers a
    -- name that trails the zone at login. Each entry gets its own retry budget.
    szRetries = 0
    if Str(sub) then Subzone() else C_Timer.After(5, Subzone) end
    Ov.Zone(Str(zone), Str(itype), Num(inst))
    -- A position with every zone line, so events after a login, hearth or
    -- flight link to a place on this map, not the last one walked on.
    if ns.opt.path then
        local m, px, py = MapPoint()
        if m then
            move.map, move.px, move.py = m, px, py
            Emit("P", m, px, py, Facing())
        end
    end
    if not ns.char or not Plain(itype) or not Plain(inst) then return end
    if itype == "party" or itype == "raid" then
        if ns.char.lastInst ~= inst then
            ns.char.lastInst = inst
            Add("dungeons")
        end
    elseif itype == "none" then
        ns.char.lastInst = nil
    end
end
H.ZONE_CHANGED_NEW_AREA = Zone
H.ZONE_CHANGED = Zone
H.ZONE_CHANGED_INDOORS = Zone

-- Kills and names ---------------------------------------------------------------

local names, named = {}, {}

local function NpcID(guid)
    if not Plain(guid) or type(guid) ~= "string" then return "?" end
    local kind, _, _, _, _, id = strsplit("-", guid)
    if kind == "Creature" or kind == "Vehicle" then return tonumber(id) or "?" end
    if kind == "Player" then return "p" end
    return kind or "?"
end

local Sighted -- defined below, once the small readers exist

local function Learn(unit)
    local isPlayer = UnitIsPlayer(unit)
    if not Plain(isPlayer) or isPlayer then return end
    local id = NpcID(UnitGUID(unit))
    if type(id) ~= "number" then return end
    if not names[id] then
        local name = UnitName(unit)
        if Plain(name) and name then names[id] = name end
    end
    Sighted(unit, id)
    ns.Place("n", id, "s", unit)
end

function H.PLAYER_TARGET_CHANGED()
    if UnitExists("target") then Learn("target") end
end

function H.NAME_PLATE_UNIT_ADDED(unit)
    Learn(unit)
end

function H.UPDATE_MOUSEOVER_UNIT()
    Learn("mouseover")
end

-- Kills come from PARTY_KILL. It does not fire for every death (a solo kill on
-- 2026-11-20 was looted with no K line), so a mob you or your pet had on its threat
-- list that dies with no PARTY_KILL within a moment is written as K <npcID> 2.
local reported, engaged, nEngaged = {}, {}, 0
local KILL_WAIT = 0.5

local function NameNpc(id, guid)
    if type(id) ~= "number" or named[id] then return end
    local name = names[id]
    if not name and UnitTokenFromGUID and Plain(guid) then
        local token = UnitTokenFromGUID(guid)
        if token then
            local n = UnitName(token)
            if Plain(n) then name = n end
        end
    end
    if name then
        named[id] = true
        Emit("N", id, name)
    end
end

-- PK <name> <classFile> <raceFile> <level> <by> <faction>: a player died to your group. name is
-- Name-Surname; level and faction come from the unit when the client still has a token for it.
local function PlayerKill(guid, by)
    local r = Pack(_G.GetPlayerInfoByGUID, guid)
    local name = r and Str(r[7])
    if not name then return end
    local realm = Str(r[8])
    if realm then name = name .. "-" .. realm end
    local token = UnitTokenFromGUID and UnitTokenFromGUID(guid)
    token = Plain(token) and token or nil
    Emit("PK", name, Str(r[3]) or "", Str(r[5]) or "", token and Num(UnitLevel(token)) or "", by,
        token and Str(UnitFactionGroup(token)) or "")
end

function H.PARTY_KILL(attacker, target)
    local by = "?"
    if Plain(attacker) then
        local pet = UnitGUID("pet")
        by = (attacker == playerGUID or (Plain(pet) and attacker == pet)) and 1 or 0
    end
    if Plain(target) then
        if reported[target] then return end
        reported[target] = true
    end
    local id = NpcID(target)
    NameNpc(id, target)
    Emit("K", id, by)
    Ov.Kill()
    if id == "p" and Plain(target) then
        PlayerKill(target, by)
        if by == 1 then ns.AutoShot("pk") end
    end
    ns.XPSource("k", id)
    Add("kills")
    if by == 1 then Add("blows") end
end

local function Threat(who, unit)
    local ok, v = pcall(UnitThreatSituation, who, unit)
    return ok and Plain(v) and v ~= nil
end

-- UNIT_HEALTH reaches every frame for every unit the client updates (a raid sends thousands a
-- second), and Died does nothing while no mob is engaged, so the event is registered only while one is.
local healthOn = false
local function WatchHealth(on)
    if on == healthOn then return end
    healthOn = on
    if on then frame:RegisterEvent("UNIT_HEALTH") else frame:UnregisterEvent("UNIT_HEALTH") end
end

function H.UNIT_THREAT_LIST_UPDATE(unit)
    local guid = UnitGUID(unit)
    if not Plain(guid) or engaged[guid] then return end
    if Threat("player", unit) or (UnitExists("pet") and Threat("pet", unit)) then
        engaged[guid] = true
        nEngaged = nEngaged + 1
        WatchHealth(true)
    end
end

local function Died(unit)
    if nEngaged == 0 then return end
    local guid = UnitGUID(unit)
    if not Plain(guid) or not engaged[guid] or reported[guid] then return end
    local dead = UnitIsDead(unit)
    if not Plain(dead) or not dead then return end
    -- Someone outside the group tagged it: not your kill.
    local denied = UnitIsTapDenied(unit)
    if Plain(denied) and denied then return end
    engaged[guid] = nil
    nEngaged = nEngaged - 1
    if nEngaged == 0 then WatchHealth(false) end
    local id = NpcID(guid)
    NameNpc(id, guid)
    C_Timer.After(KILL_WAIT, function()
        if reported[guid] then return end
        reported[guid] = true
        Emit("K", id, 2)
        Ov.Kill()
        ns.XPSource("k", id)
        Add("kills")
    end)
end
H.UNIT_HEALTH = Died
H.NAME_PLATE_UNIT_REMOVED = Died

-- Out of combat nothing on the list can still die to you; the reported set only
-- has to outlive a PARTY_KILL that arrives late.
local function ForgetKills()
    if InCombatLockdown() then return end
    engaged, nEngaged, reported = {}, 0, {}
    WatchHealth(false)
end

-- Spell and item names: each is written once per session (SN / IN lines) so
-- the companion can show names instead of IDs.

local spellNamed, itemNamed = {}, {}

-- A spell the client has not loaded yet has no name (aura 16609 and cast 1331725 on
-- 2026-11-20 got no SN line). fallback is a name the caller already has, such as the
-- aura's; otherwise the client is asked to load the spell and SN follows when it has.
local spellPending, spellFailed = {}, {}

local function SpellName(id, fallback)
    if not Plain(id) or type(id) ~= "number" or spellNamed[id] then return end
    local name = C_Spell.GetSpellName(id)
    if not (Plain(name) and type(name) == "string" and name ~= "") then
        name = Plain(fallback) and type(fallback) == "string" and fallback ~= "" and fallback or nil
    end
    if name then
        spellNamed[id] = true
        spellPending[id] = nil
        Emit("SN", id, name)
        ns.SpellFact(id)
    elseif not spellPending[id] and not spellFailed[id] and C_Spell.RequestLoadSpellData then
        spellPending[id] = true
        pcall(C_Spell.RequestLoadSpellData, id)
    end
end

function H.SPELL_DATA_LOAD_RESULT(spellID, success)
    if not Plain(spellID) or not spellPending[spellID] then return end
    spellPending[spellID] = nil
    -- Asked once per session: whatever the answer, the spell is not asked for again.
    spellFailed[spellID] = true
    if Plain(success) and success then SpellName(spellID) end
end

-- Item facts: II <itemID> <classID> <subclassID> <equipLoc> <itemLevel> <reqLevel> <sellPrice>
-- <bindType> <stack>, once per item per character (ns.char.ii holds the ids seen, up to
-- II_CAP; past it an item is still written once a session). Items above CUSTOM_ITEM are
-- Forever's own, so their tooltip text is kept too: IT <itemID> <lines joined by " | ">.
-- An item the client has not loaded waits in pend for GET_ITEM_INFO_RECEIVED.
local II_CAP = 8000
local II_PENDING_CAP = 100
local CUSTOM_ITEM = 270000
local TIP_LINES, TIP_CHARS = 14, 700
local iiSession, iiPend, iiPendN = {}, {}, 0

-- Colour, texture, link and hyperlink codes out of tooltip text.
local function CleanTip(text)
    text = text:gsub("|4[^:;]*:([^;]*);", "%1") -- |4singular:plural; keeps the plural
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cn[%w_]+:", ""):gsub("|r", ""):gsub("|T.-|t", "")
    text = text:gsub("|H.-|h", ""):gsub("|h", ""):gsub("||", "|"):gsub("|A.-|a", "")
    return text
end

local function ItemTip(id)
    local TT = C_TooltipInfo
    if not TT or not TT.GetHyperlink then return end
    local ok, data = pcall(TT.GetHyperlink, "item:" .. id)
    if not ok or type(data) ~= "table" or not Plain(data) or type(data.lines) ~= "table" or not Plain(data.lines) then
        return
    end
    local out, chars = {}, 0
    for i = 1, math.min(#data.lines, TIP_LINES) do
        local line = data.lines[i]
        if type(line) == "table" and Plain(line) then
            for _, side in ipairs({ line.leftText, line.rightText }) do
                local t = Str(side)
                if t then
                    t = CleanTip(t)
                    if t ~= "" and chars + #t <= TIP_CHARS then
                        out[#out + 1] = t
                        chars = chars + #t
                    end
                end
            end
        end
    end
    if #out > 0 then Emit("IT", id, table.concat(out, " | ")) end
end

local function ItemInfo(id)
    local ch = ns.char
    if not ch or iiSession[id] then return end
    local seen = ch.ii
    if type(seen) ~= "table" then
        seen = {}
        ch.ii, ch.iiN = seen, 0
    end
    if seen[id] then return end
    local r = Pack(C_Item and C_Item.GetItemInfo, id)
    if not r or not Str(r[2]) then
        -- Not loaded yet: ask once, then GET_ITEM_INFO_RECEIVED finishes it.
        if not iiPend[id] and iiPendN < II_PENDING_CAP then
            iiPend[id], iiPendN = true, iiPendN + 1
            if C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
            -- No answer in 30 s frees the slot; a later sighting of the item asks again.
            C_Timer.After(30, function()
                if iiPend[id] then iiPend[id], iiPendN = nil, iiPendN - 1 end
            end)
        end
        return
    end
    iiSession[id] = true
    if (ch.iiN or 0) < II_CAP then
        seen[id] = 1
        ch.iiN = (ch.iiN or 0) + 1
    end
    Emit("II", id, Num(r[13]) or "", Num(r[14]) or "", Str(r[10]) or "", Num(r[5]) or "", Num(r[6]) or "",
        Num(r[12]) or "", Num(r[15]) or "", Num(r[9]) or "")
    if id > CUSTOM_ITEM then ItemTip(id) end
end

function H.GET_ITEM_INFO_RECEIVED(itemID, success)
    if not Plain(itemID) or not iiPend[itemID] then return end
    iiPend[itemID], iiPendN = nil, iiPendN - 1
    if Plain(success) and success then ItemInfo(itemID) else iiSession[itemID] = true end
end

-- The parts of an item link that tell two copies of one item apart: suffixID, the bonus IDs
-- (comma-joined) and the upgrade level the client reports for the link. Link layout:
-- item:id:enchant:gem1:gem2:gem3:gem4:suffix:unique:linkLevel:spec:mask:context:numBonus:bonus...
-- The unique ID is a per-item serial and is left out.
local function LinkVariant(link)
    if not Str(link) then return "", "", "" end
    local body = link:match("|Hitem:([^|]+)") or link:match("^item:([^|]+)")
    if not body then return "", "", "" end
    local f = { strsplit(":", body) }
    local suffix = tonumber(f[7])
    local bonus = {}
    local n = tonumber(f[13]) or 0
    for i = 1, math.min(n, 12) do
        local b = tonumber(f[13 + i])
        if b then bonus[#bonus + 1] = b end
    end
    local upgrade = ""
    if #bonus > 0 and C_Item and C_Item.GetItemUpgradeInfo then
        local ok, info = pcall(C_Item.GetItemUpgradeInfo, link)
        if ok and type(info) == "table" and Plain(info) then upgrade = Num(info.currentLevel) or "" end
    end
    return suffix and suffix ~= 0 and suffix or "", table.concat(bonus, ","), upgrade
end

-- Creature sightings: NS <npcID> <level> <classification> <creatureType> <typeID> <family> <familyID>
-- <reaction> <uiMapID> <cellX> <cellY>, from your target, mouseover and nameplates, after the npc's N
-- line. Once per npc per character (ns.char.cs holds the level written, up to CS_CAP npcs; a new level for a known
-- npc is written again) and at most once per npc per session, with SESSION_CAP lines a session.
-- Pets, guardians, totems and other player-controlled units are skipped. The map cell is where
-- YOU stood when you first saw it (map units in 0.015 steps), not where the creature was.
local CS_CAP = 6000
local SESSION_CAP = 1200
local CELL = 150
local sightSeen, sightN = {}, 0

Sighted = function(unit, id)
    local ch = ns.char
    local level = Num(UnitLevel(unit))
    if not ch or not level or sightSeen[id] == level then return end
    -- Secret in combat on nameplates and mouseover: not marked seen, so a later sighting writes it.
    local controlled = UnitPlayerControlled(unit)
    if not Plain(controlled) then return end
    if sightSeen[id] == nil then
        if sightN >= SESSION_CAP then return end
        sightN = sightN + 1
    end
    sightSeen[id] = level
    if controlled then return end
    if type(ch.cs) ~= "table" then ch.cs, ch.csN = {}, 0 end
    local known = ch.cs[id]
    if known == level then return end
    if known or (ch.csN or 0) < CS_CAP then
        if not known then ch.csN = (ch.csN or 0) + 1 end
        ch.cs[id] = level
    end
    NameNpc(id) -- the N line comes first, so the NS line has a name
    local ctype = Pack(UnitCreatureType, unit)
    local family = Pack(UnitCreatureFamily, unit)
    local map, px, py = MapPoint()
    Emit("NS", id, level, Str(UnitClassification(unit)) or "", ctype and Str(ctype[2]) or "", ctype and Num(ctype[3]) or "",
        family and Str(family[2]) or "", family and Num(family[3]) or "", Num(UnitReaction("player", unit)) or "",
        map or "", px and floor(px / CELL) or "", py and floor(py / CELL) or "")
end

local function ItemName(id)
    if not Plain(id) or type(id) ~= "number" then return end
    if not itemNamed[id] then
        local name = C_Item.GetItemNameByID(id)
        if Plain(name) and type(name) == "string" then
            itemNamed[id] = true
            Emit("IN", id, name)
        end
    end
    ItemInfo(id) -- after IN, so the II line has a name
end

-- Shared with the domain files loaded after this one (Combat.lua).
ns.SpellName, ns.ItemName, ns.Round1 = SpellName, ItemName, Round1

-- Casts, death, combat, encounters ---------------------------------------------

-- Cast and channel times. C carries the cast time when the cast had one;
-- channels (fishing, some crafts) end with CH, interrupted casts with CI.
-- Per-spell seconds go into the character's spellTime table.
local cast = { id = nil, t0 = 0, chan = false }

local function SpellTime(id, secs)
    Add("castTime", secs)
    local ch = ns.char
    if not ch then return end
    ch.spellTime = ch.spellTime or {}
    ch.spellTime[id] = (ch.spellTime[id] or 0) + secs
end

local function CastBegin(id, chan)
    if not Plain(id) then cast.id = nil return end
    cast.id, cast.t0, cast.chan = id, GetTime(), chan
end

function H.UNIT_SPELLCAST_START(_, _, spellID) CastBegin(spellID, false) end
function H.UNIT_SPELLCAST_CHANNEL_START(_, _, spellID)
    SpellName(spellID)
    CastBegin(spellID, true)
end

-- The client casts some hidden spells on you over and over (in Gadgetzan,
-- spell 1303872 every second). A spell you do not know that repeats within
-- REPEAT_SECONDS of itself is not written again or counted as a cast.
local REPEAT_SECONDS = 1.5
local lastHidden, lastHiddenT = nil, 0

local function HiddenRepeat(spellID)
    if not Plain(spellID) or type(spellID) ~= "number" then return false end
    local known = _G.IsPlayerSpell and _G.IsPlayerSpell(spellID)
    if not Plain(known) or known then return false end
    local now = GetTime()
    local again = lastHidden == spellID and now - lastHiddenT < REPEAT_SECONDS
    lastHidden, lastHiddenT = spellID, now
    return again
end

function H.UNIT_SPELLCAST_SUCCEEDED(_, _, spellID)
    if HiddenRepeat(spellID) then return end
    SpellName(spellID)
    local secs = ""
    if cast.id and not cast.chan and Plain(spellID) and spellID == cast.id then
        local s = GetTime() - cast.t0
        cast.id = nil
        secs = Round1(s)
        SpellTime(spellID, s)
    end
    Emit("C", spellID, secs)
    Add("casts")
end

function H.UNIT_SPELLCAST_CHANNEL_STOP()
    if not cast.id or not cast.chan then return end
    local id, s = cast.id, GetTime() - cast.t0
    cast.id = nil
    Emit("CH", id, Round1(s))
    SpellTime(id, s)
end

function H.UNIT_SPELLCAST_INTERRUPTED(_, _, spellID)
    if not cast.id or cast.chan or not Plain(spellID) or spellID ~= cast.id then return end
    local s = GetTime() - cast.t0
    cast.id = nil
    Emit("CI", spellID, Round1(s))
    SpellTime(spellID, s)
end

-- Auras and camps ----------------------------------------------------------------
-- Every buff and debuff on the player: A 1 when gained, A 0 when it ends.
-- A camp visit starts with the first camp aura and ends when the last one goes.

-- Forever camp spells from the 1.60.1 SpellName table. Any aura whose name
-- contains "Camp" counts too.
local CAMP = {}
for _, id in ipairs({ 1229432, 1229487, 1255248, 1307230, -- Camp Tent
    1229517, 1255250, 1307229,                            -- Camp Chair
    1229736, 1229737, 1307227, 1229739, 1289723,          -- Campfire, Basic, Welcoming
    1283400, 1307252, 1291341, 1307237,                   -- Journeyman, Expert Campfire
    1283391,
    1229451, 1325299,                                     -- Boosted Rest
    1290211, 1304323, 1308027, 1308302, 1310090, 1327906, -- Camping
}) do CAMP[id] = true end

local BUFFS_KEPT_AFTER_LEAVING_CAMP = { [1229741] = true, [1289378] = true, [1232234] = true }

local auras = {}   -- auraInstanceID -> { id, t, camp }
local campN, campT0 = 0, nil
local auraSeen = {}
local auraStale = false

local function AuraAdded(a, initial)
    if not a or not Plain(a) then return end
    local iid, id = a.auraInstanceID, a.spellId
    if not Plain(iid) or not Plain(id) or not iid or not id or auras[iid] then return end
    local name = a.name
    local camp = CAMP[id] or false
    if not camp and not BUFFS_KEPT_AFTER_LEAVING_CAMP[id] and Plain(name) and type(name) == "string" and name:find("Camp", 1, true) then camp = true end
    local now = GetTime()
    auras[iid] = { id = id, t = now, camp = camp }
    SpellName(id, name)
    local helpful = a.isHelpful
    local src = a.sourceUnit
    local by = ""
    if Plain(src) and src then by = (src == "player" or src == "pet") and 1 or 0 end
    local dur = a.duration
    -- initial: already on the player when the session started (login or reload)
    Emit("A", 1, id, Plain(helpful) and (helpful and 1 or 0) or "?", Plain(dur) and Round1(dur or 0) or "?", by,
        initial and "s" or "")
    if not initial and Plain(helpful) and helpful then Add("buffs") end
    if camp then
        if campN == 0 then
            campT0 = now
            TimerOn("camptime")
            -- A reload at camp continues the same visit instead of counting a new one.
            local cont = ns.char and ns.char.campLeft and time() - ns.char.campLeft < 300
            Emit("CP", 1, id, cont and 1 or 0)
            if not cont then Add("camps") end
            if ns.char then ns.char.campLeft = nil end
        end
        campN = campN + 1
    end
end

local function AuraRemoved(iid)
    local e = auras[iid]
    if not e then return end
    auras[iid] = nil
    local now = GetTime()
    Emit("A", 0, e.id, Round1(now - e.t))
    if e.camp then
        campN = campN - 1
        if campN <= 0 then
            campN = 0
            local secs = campT0 and now - campT0 or 0
            campT0 = nil
            Emit("CP", 0, Round1(secs))
            TimerOff("camptime")
        end
    end
end

-- Rebuild from the client's aura list: new ones are added, missing ones end.
local AURA_FILTERS = { "HELPFUL", "HARMFUL" }
local function AuraScan(initial)
    auraStale = false
    wipe(auraSeen)
    for _, filter in ipairs(AURA_FILTERS) do
        for i = 1, 255 do
            local a = C_UnitAuras.GetAuraDataByIndex("player", i, filter)
            if not a then break end
            if not Plain(a) or not Plain(a.auraInstanceID) then
                auraStale = true
                return
            end
            auraSeen[a.auraInstanceID] = true
            AuraAdded(a, initial)
        end
    end
    for iid in pairs(auras) do
        if not auraSeen[iid] then AuraRemoved(iid) end
    end
end

local entered = false

function H.UNIT_AURA(_, info)
    if not entered then return end -- the first PLAYER_ENTERING_WORLD scans them all
    -- The table can be plain while a field in it is secret; a secret field reads as a full
    -- update (a rescan, or a stale mark in combat). Absent fields are normal: an update
    -- carries only what changed.
    local ok = Plain(info) and info
    local full = ok and info.isFullUpdate
    local added = ok and info.addedAuras
    local removed = ok and info.removedAuraInstanceIDs
    if not ok or issecretvalue(full) or issecretvalue(added) or issecretvalue(removed) or full then
        if InCombatLockdown() then auraStale = true else AuraScan() end
        return
    end
    if added then
        for i = 1, #added do AuraAdded(added[i]) end
    end
    if removed then
        for i = 1, #removed do
            local iid = removed[i]
            if Plain(iid) then AuraRemoved(iid) end
        end
    end
end

local wasResting
function H.PLAYER_UPDATE_RESTING()
    local r = IsResting()
    if not Plain(r) or r == wasResting then return end
    wasResting = r
    Emit("RS", r and 1 or 0)
end

-- Bags ------------------------------------------------------------------------------
-- I <itemID> <delta> <where>: what entered or left the bags, and what was open
-- at the time (v vendor, b bank, m mail, t trade, l loot, a auction house,
-- c profession window: reagents used and items made). Moves inside the
-- bags net to zero and write nothing.

local bagCounts, bagScratch = {}, {}
local bankScratch = {}
local bagsReady = false
local where, whereUntil

local function CountBags(out)
    wipe(out)
    for bag = 0, NUM_BAG_SLOTS or 4 do
        local slots = C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info then
                local id, n = info.itemID, info.stackCount
                if Plain(id) and Plain(n) and id then out[id] = (out[id] or 0) + (n or 1) end
            end
        end
    end
end
ns.CountBags = CountBags

-- At a vendor an I line also carries the vendor's npcID and, for a sale, the item's vendor sell price
-- per unit (copper, from the item's info).
local function VendorNpc()
    local guid = UnitGUID("npc")
    local id = Plain(guid) and NpcID(guid)
    return type(id) == "number" and id or ""
end

local function SellPrice(id)
    local r = Pack(C_Item and C_Item.GetItemInfo, id)
    return r and Num(r[12]) or ""
end

local BC_ITEMS = 150
local BANK_READ_DELAY = 0.6
local bankCounts, bankSig, bankWritten = {}, nil, nil
local bankOpen = false

local function WriteCounts(code, counts)
    local ids = {}
    for id in pairs(counts) do ids[#ids + 1] = id end
    table.sort(ids)
    for i = 1, #ids do ItemName(ids[i]) end
    if #ids == 0 then
        Emit("BC", code, "")
        return
    end
    local list = {}
    for i = 1, #ids do
        list[#list + 1] = ids[i] .. ":" .. counts[ids[i]]
        if #list == BC_ITEMS or i == #ids then
            Emit("BC", code, table.concat(list, ","))
            wipe(list)
        end
    end
end

local function ListSig(counts)
    local ids = {}
    for id in pairs(counts) do ids[#ids + 1] = id end
    table.sort(ids)
    for i = 1, #ids do ids[i] = ids[i] .. ":" .. counts[ids[i]] end
    return table.concat(ids, ",")
end

local function ReadBank()
    local bank, kind = _G.C_Bank, _G.Enum and _G.Enum.BankType
    if not (bank and bank.FetchPurchasedBankTabData and kind and kind.Character) then return end
    local tabs = bank.FetchPurchasedBankTabData(kind.Character)
    if not Plain(tabs) or type(tabs) ~= "table" then return end
    local seen = 0
    wipe(bankScratch)
    for _, tab in ipairs(tabs) do
        local id = type(tab) == "table" and tab.ID
        if Plain(id) and type(id) == "number" then
            local slots = C_Container.GetContainerNumSlots(id) or 0
            seen = seen + slots
            for slot = 1, slots do
                local info = C_Container.GetContainerItemInfo(id, slot)
                local item, n = info and info.itemID, info and info.stackCount
                if item and Plain(item) and Plain(n) then bankScratch[item] = (bankScratch[item] or 0) + (n or 1) end
            end
        end
    end
    if seen == 0 then return end
    bankCounts, bankScratch = bankScratch, bankCounts
    bankSig = nil
end

function H.BAG_UPDATE_DELAYED()
    if not bagsReady then
        CountBags(bagCounts)
        bagsReady = true
        return
    end
    CountBags(bagScratch)
    if whereUntil and GetTime() > whereUntil then where, whereUntil = nil, nil end
    local ctx = where or ""
    for id, n in pairs(bagScratch) do
        local d = n - (bagCounts[id] or 0)
        if d ~= 0 then
            ItemName(id)
            if ctx == "v" then
                Emit("I", id, d, ctx, VendorNpc(), d < 0 and SellPrice(id) or "")
            else
                Emit("I", id, d, ctx)
            end
            if d < 0 and ctx == "v" then Add("sold", -d) end
        end
    end
    for id, n in pairs(bagCounts) do
        if not bagScratch[id] then
            ItemName(id)
            if ctx == "v" then
                Emit("I", id, -n, ctx, VendorNpc(), SellPrice(id))
                Add("sold", n)
            else
                Emit("I", id, -n, ctx)
            end
        end
    end
    bagCounts, bagScratch = bagScratch, bagCounts
    if bankOpen then ReadBank() end
end

local function Opened(code) return function() where, whereUntil = code, nil end end
-- Keep the context a moment after closing so the last change still gets it:
-- fished and opened items reach the bags up to about 1.2 s after the window.
local function Closed() whereUntil = GetTime() + 2 end
H.MERCHANT_SHOW, H.MERCHANT_CLOSED = Opened("v"), Closed

function H.BANKFRAME_OPENED()
    where, whereUntil = "b", nil
    bankOpen = true
    C_Timer.After(BANK_READ_DELAY, function() if bankOpen then ReadBank() end end)
end

function H.BANKFRAME_CLOSED()
    Closed()
    if bankOpen then ReadBank() end
    bankOpen = false
    local sig = bankSig or ListSig(bankCounts)
    bankSig = sig
    if next(bankCounts) ~= nil and sig ~= bankWritten then
        bankWritten = sig
        WriteCounts("k", bankCounts)
    end
end
H.MAIL_SHOW, H.MAIL_CLOSED = Opened("m"), Closed
H.TRADE_SHOW, H.TRADE_CLOSED = Opened("t"), Closed
-- LOOT_READY too: fast-loot addons take everything before LOOT_OPENED.
H.LOOT_READY, H.LOOT_OPENED, H.LOOT_CLOSED = Opened("l"), Opened("l"), Closed
H.AUCTION_HOUSE_SHOW, H.AUCTION_HOUSE_CLOSED = Opened("a"), Closed
H.TRADE_SKILL_SHOW, H.TRADE_SKILL_CLOSE = Opened("c"), Closed

-- The guild bank opens only through the interaction manager (type 10) in
-- Forever; its UI never listens to GUILDBANKFRAME_OPENED.
local GUILD_BANKER = 10
function H.PLAYER_INTERACTION_MANAGER_FRAME_SHOW(kind)
    if Plain(kind) and kind == GUILD_BANKER then where, whereUntil = "g", nil end
end
function H.PLAYER_INTERACTION_MANAGER_FRAME_HIDE(kind)
    if Plain(kind) and kind == GUILD_BANKER then Closed() end
end

-- PLAYER_ALIVE also fires at every login and reload, so it only counts after
-- a death this session (or when logging in dead).
local dead = false

function H.PLAYER_DEAD()
    dead = true
    Emit("D")
    Ov.Death()
    Add("deaths")
end

function H.PLAYER_ALIVE()
    if not dead then return end
    if UnitIsGhost("player") then
        Emit("R")
    else
        dead = false
        Emit("U")
    end
end

function H.PLAYER_UNGHOST()
    if not dead then return end
    dead = false
    Emit("U")
end

local combatStart
function H.PLAYER_REGEN_DISABLED()
    combatStart = GetTime()
    TimerOn("combat")
    Emit("F", 1)
end

function H.PLAYER_REGEN_ENABLED()
    C_Timer.After(5, ForgetKills)
    if combatStart then
        local secs = GetTime() - combatStart
        combatStart = nil
        Emit("F", 0, Round1(secs))
        TimerOff("combat")
    end
    if auraStale then AuraScan() end
    ns.SealIfPending()
end

local encStart
function H.ENCOUNTER_START(id, name, difficulty, size)
    encStart = GetTime()
    Emit("E", 1, id, difficulty, size, name)
end

function H.ENCOUNTER_END(id, _, _, _, success)
    Emit("E", 0, id, success, encStart and Round1(GetTime() - encStart) or "")
    encStart = nil
end

function H.BOSS_KILL(id, name)
    Emit("B", id, name)
    Add("bosses")
    ns.AutoShot("bk")
end

-- Progress: xp, money, loot, quests, gear, skills, reputation --------------------

local lastXP, lastMax, lastMoney

-- What gave the experience: X <amount> <xp> <xpMax> <source> <id>. The sources are noted as they
-- happen (a kill's PARTY_KILL, a quest turn-in, an area discovery) and the X line waits
-- XP_WAIT seconds so a source that arrives just after PLAYER_XP_UPDATE is still found. The nearest
-- source within XP_WINDOW seconds is used once; a quest or discovery wins over a kill. source k
-- kill (id the npcID), q quest (id the questID), e discovery, o none found.
local XP_WAIT, XP_WINDOW = 0.8, 1.5
local xpSources, xpPending = {}, {}

function ns.XPSource(kind, id)
    xpSources[#xpSources + 1] = { kind = kind, id = id, t = GetTime() }
    while #xpSources > 8 do table.remove(xpSources, 1) end
end
ns.Cap.Swap(ns, "XPSource") -- a no-op at max level, so a kill costs nothing for XP

local function TakeXPSource(t)
    local best, bestD, bestRank
    for i = 1, #xpSources do
        local s = xpSources[i]
        local d = math.abs(s.t - t)
        local rank = s.kind == "k" and 1 or 2
        if d <= XP_WINDOW and (not best or rank > bestRank or (rank == bestRank and d < bestD)) then
            best, bestD, bestRank = i, d, rank
        end
    end
    if not best then return "o", "" end
    local s = table.remove(xpSources, best)
    return s.kind, s.id
end

-- Writes a waiting X line; a logout or reload inside the wait writes them first.
local function FlushXP(p)
    if p.done then return end
    p.done = true
    local kind, id = TakeXPSource(p.t)
    Emit("X", p.gain, p.cur, p.max, kind, id)
    Ov.XP(kind, p.gain)
    while xpPending[1] and xpPending[1].done do table.remove(xpPending, 1) end
end

-- Registered only while the character levels (ns.Cap in Core.lua); at max level the client's bar is empty.
function H.PLAYER_XP_UPDATE()
    local cur, max = UnitXP("player"), UnitXPMax("player")
    if not Plain(cur) or not Plain(max) then return end
    if not max or max <= 0 then
        lastXP, lastMax = nil, nil
        return
    end
    if lastXP then
        local gain = cur >= lastXP and cur - lastXP or (lastMax - lastXP) + cur
        if gain > 0 then
            Add("xp", gain)
            local p = { t = GetTime(), gain = gain, cur = cur, max = max }
            xpPending[#xpPending + 1] = p
            C_Timer.After(XP_WAIT, function() FlushXP(p) end)
        end
    end
    lastXP, lastMax = cur, max
end

function H.PLAYER_LEVEL_UP(level)
    -- Into the cap: the last X line of the level is still waiting on its timer, and the events stay registered for 2 seconds.
    ns.Cap.Refresh(level, XP_WAIT + 1.2)
    Emit("L", level)
    Ov.Level(Num(level))
    Add("levels")
    ns.AutoShot("lv")
end

-- Money mailed between your own characters is a transfer: M carries it as a
-- second field and it is neither earned nor spent. Postage stays spent.
local MAIL_WINDOW = 10
local mailMove -- { copper = signed transfer, t = GetTime() }

-- Forever has no realms: a character's full name is Name-Surname, the key in
-- ScarletDB.chars and the client's own WTF folder name. Mail may give it as
-- "Name Surname", "Name-Surname" or just "Name".
local function HasChar(chars, name)
    if type(chars) ~= "table" then return false end
    for key in pairs(chars) do
        if type(key) == "string" then
            local k = key:lower()
            if k == name or k:match("^[^-]+") == name then return true end
        end
    end
    return false
end

local function OwnChar(name)
    if not Plain(name) or type(name) ~= "string" or name == "" then return false end
    name = (name:gsub("%s+", "-")):lower()
    if HasChar(ns.db and ns.db.chars, name) then return true end
    local d = _G.ScarletDigest
    return type(d) == "table" and HasChar(d.chars, name)
end
ns.OwnChar = OwnChar

function ns.MarkTransfer(copper)
    mailMove = copper and copper ~= 0 and { copper = copper, t = GetTime() } or nil
end

-- The money on the send form, kept as it changes in case the form is
-- already cleared when the SendMail hook runs.
local draftMoney = 0
function H.SEND_MAIL_MONEY_CHANGED()
    local copper = _G.GetSendMailMoney and _G.GetSendMailMoney()
    draftMoney = Plain(copper) and copper or 0
end

if type(_G.SendMail) == "function" then
    hooksecurefunc("SendMail", function(recipient)
        local copper = _G.GetSendMailMoney and _G.GetSendMailMoney()
        if not Plain(copper) or copper <= 0 then copper = draftMoney end
        draftMoney = 0
        if OwnChar(recipient) and copper > 0 then
            mailMove = { copper = -copper, t = GetTime() }
        end
    end)
end

function H.MAIL_FAILED() mailMove = nil end

local function TookMail(index)
    if not Plain(index) or not _G.GetInboxHeaderInfo then return end
    local _, _, sender, _, copper = _G.GetInboxHeaderInfo(index)
    if OwnChar(sender) and Plain(copper) and copper > 0 then
        mailMove = { copper = copper, t = GetTime() }
    end
end
for _, fn in ipairs({ "TakeInboxMoney", "AutoLootMailItem" }) do
    if type(_G[fn]) == "function" then hooksecurefunc(fn, TookMail) end
end

function H.PLAYER_MONEY()
    local money = GetMoney()
    if lastMoney and money ~= lastMoney then
        local delta = money - lastMoney
        local moved = 0
        local m = mailMove
        if m and GetTime() - m.t < MAIL_WINDOW
            and ((m.copper < 0 and delta <= m.copper) or (m.copper > 0 and delta >= m.copper)) then
            moved, mailMove = m.copper, nil
        end
        local rest = delta - moved
        -- The transfer field stays in place (empty when there is none) so the balance is always field 3.
        Emit("M", delta, moved ~= 0 and moved or "", money)
        Ov.Money(delta - moved, money)
        if rest > 0 then Add("earned", rest) elseif rest < 0 then Add("spent", -rest) end
    end
    lastMoney = money
end

local LOOT_PREFIXES = {}
for _, key in ipairs({ "LOOT_ITEM_SELF", "LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_PUSHED_SELF",
    "LOOT_ITEM_PUSHED_SELF_MULTIPLE", "LOOT_ITEM_CREATED_SELF", "LOOT_ITEM_CREATED_SELF_MULTIPLE" }) do
    local fmt = _G[key]
    local prefix = type(fmt) == "string" and fmt:match("^(.-)%%")
    if prefix and prefix ~= "" then LOOT_PREFIXES[#LOOT_PREFIXES + 1] = prefix end
end

-- Items bought, taken from the bank or mail, traded, won at auction or crafted
-- also print "You receive"; those are I lines with their where, not loot.
local NOT_LOOT = { v = true, b = true, m = true, t = true, a = true, c = true, g = true }

function H.CHAT_MSG_LOOT(text)
    if not Plain(text) or type(text) ~= "string" then return end
    if whereUntil and GetTime() > whereUntil then where, whereUntil = nil, nil end
    if where and NOT_LOOT[where] then return end
    for i = 1, #LOOT_PREFIXES do
        local prefix = LOOT_PREFIXES[i]
        if text:sub(1, #prefix) == prefix then
            local id = tonumber(text:match("|Hitem:(%d+)"))
            if not id then return end
            local count = tonumber(text:match("|h|rx(%d+)")) or 1
            ItemName(id)
            Emit("O", id, count, LinkVariant(text:match("|Hitem:[^|]+")))
            Add("loot", count)
            local quality = C_Item and C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(id)
            if Plain(quality) and type(quality) == "number" and quality >= 4 then ns.AutoShot("ep") end
            return
        end
    end
end

function H.QUEST_ACCEPTED(questID)
    Emit("Q", 1, questID)
end

function H.QUEST_TURNED_IN(questID, xp, money)
    Emit("Q", 2, questID, xp, money)
    Ov.Quest()
    if Plain(questID) and Plain(xp) and xp and xp > 0 then ns.XPSource("q", questID) end
    Add("quests")
end

function H.PLAYER_EQUIPMENT_CHANGED(slot)
    local id = _G.GetInventoryItemID and _G.GetInventoryItemID("player", slot)
    ItemName(id)
    Emit("G", slot, id or 0, LinkVariant(_G.GetInventoryItemLink and _G.GetInventoryItemLink("player", slot)))
end

-- alreadyEarned: the client re-announces account achievements this character
-- already has (a burst at login). Only new ones are written and counted.
function H.ACHIEVEMENT_EARNED(id, alreadyEarned)
    if Plain(alreadyEarned) and alreadyEarned then return end
    Emit("AC", id)
    Add("achievements")
end

-- Turns a client format string like "Your skill in %s has increased to %d." into a Lua pattern.
local function Pattern(fmt)
    if type(fmt) ~= "string" then return end
    fmt = fmt:gsub("%%%d?%$?s", "\001"):gsub("%%%d?%$?d", "\002")
    fmt = fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$%%])", "%%%1")
    fmt = fmt:gsub("\001", "(.+)"):gsub("\002", "(%%d+)")
    return "^" .. fmt .. "$"
end

local SKILL_UP = Pattern(SKILL_RANK_UP)
local REP_UP = Pattern(FACTION_STANDING_INCREASED)
local REP_DOWN = Pattern(FACTION_STANDING_DECREASED)

function H.CHAT_MSG_SKILL(text)
    if not SKILL_UP or not Plain(text) then return end
    local skill, rank = text:match(SKILL_UP)
    if skill then Emit("SK", skill, rank) end
end

function H.CHAT_MSG_COMBAT_FACTION_CHANGE(text)
    if not Plain(text) then return end
    if REP_UP then
        local faction, amount = text:match(REP_UP)
        if faction then Emit("RP", faction, amount) return end
    end
    if REP_DOWN then
        local faction, amount = text:match(REP_DOWN)
        if faction then Emit("RP", faction, -(tonumber(amount) or 0)) end
    end
end

-- AFK, rested XP, groups ------------------------------------------------------------

local afk
local function SetAFK()
    local a = UnitIsAFK("player")
    if not Plain(a) then return end
    a = a and true or false
    if a == afk then return end
    afk = a
    Emit("AFK", a and 1 or 0)
    if a then TimerOn("afkTime") else TimerOff("afkTime") end
end
H.PLAYER_FLAGS_CHANGED = SetAFK

local rested
local function SetRested()
    if not ns.Cap.Levelling() then return end
    local x = GetXPExhaustion()
    if not Plain(x) then return end
    local r = (x or 0) > 0
    if r == rested then return end
    rested = r
    Emit("RX", r and 1 or 0, x or 0)
    TimerSet("restedTime", "unrestedTime", r)
end
H.UPDATE_EXHAUSTION = SetRested

-- Levelling ends (the cap, or experience turned off): the rested timers and the XP bar baseline
-- are dropped. It starts again: both are read fresh.
ns.Cap.OnChange(function(levelling)
    if levelling then
        local x, m = UnitXP("player"), UnitXPMax("player")
        if Plain(x) and Plain(m) and m and m > 0 then lastXP, lastMax = x, m end
        if entered then SetRested() end
    else
        TimerOff("restedTime")
        TimerOff("unrestedTime")
        rested, lastXP, lastMax = nil, nil, nil
    end
end)

-- Group members by Name-Realm: GM 1 when they join (or are there when the
-- session starts), GM 0 with seconds together when they leave. Per-person
-- totals go into the character's mates table.
local inGroup
local mates, roster = {}, {}

local function MateLeft(key, now)
    local t0 = mates[key]
    mates[key] = nil
    local secs = now - t0
    Emit("GM", 0, key, Round1(secs))
    local ch = ns.char
    if ch then
        ch.mates = ch.mates or {}
        local m = ch.mates[key] or { secs = 0, groups = 0 }
        ch.mates[key] = m
        m.secs = m.secs + secs
    end
end

local function FlushMates()
    local now = GetTime()
    for key in pairs(mates) do MateLeft(key, now) end
end

local function Roster()
    local g = IsInGroup()
    if Plain(g) then
        g = g and true or false
        if g ~= inGroup then
            inGroup = g
            Emit("GP", g and 1 or 0, GetNumGroupMembers())
            TimerSet("groupTime", "soloTime", g)
        end
    end
    wipe(roster)
    local raid = IsInRaid()
    local n = GetNumGroupMembers()
    if Plain(n) and Plain(raid) then
        for i = 1, raid and n or n - 1 do
            local unit = raid and ("raid" .. i) or ("party" .. i)
            local same = UnitIsUnit(unit, "player")
            if Plain(same) and not same then
                local name, realm = UnitName(unit)
                if Plain(name) and name ~= UNKNOWNOBJECT then
                    -- realm is nil for players on your own realm; Plain(nil) is false
                    if Plain(realm) and realm ~= "" then name = name .. "-" .. realm end
                    roster[name] = true
                end
            end
        end
    end
    local now = GetTime()
    for key in pairs(mates) do
        if not roster[key] then MateLeft(key, now) end
    end
    for key in pairs(roster) do
        if not mates[key] then
            mates[key] = now
            Emit("GM", 1, key)
            local ch = ns.char
            if ch then
                ch.mates = ch.mates or {}
                local m = ch.mates[key] or { secs = 0, groups = 0 }
                ch.mates[key] = m
                m.groups = m.groups + 1
            end
        end
    end
end
H.GROUP_ROSTER_UPDATE = Roster

-- Your own chat: only counts of a few words are kept, never the message.
-- Emotes are recorded by token (LOL, WAVE, ...).
local WORDS = { { "lol", "%f[%a]lo+l%f[%A]" }, { "rip", "%f[%a]rip%f[%A]" }, { "rip", "r%.i%.p" } }
local WORD_STAT = { lol = "saidLol", rip = "saidRip" }

local lastSay, lastSayT
local function OnSay(msg)
    if type(msg) ~= "string" or not Plain(msg) then return end
    -- Both hooks below can see one message; count it once.
    local now = GetTime()
    if msg == lastSay and now == lastSayT then return end
    lastSay, lastSayT = msg, now
    local low = msg:lower()
    for i = 1, #WORDS do
        local w = WORDS[i]
        local _, n = low:gsub(w[2], "")
        if n > 0 then
            Emit("WD", w[1], n)
            Add(WORD_STAT[w[1]], n)
        end
    end
end

local lastEmote, lastEmoteT
local function OnEmote(token, _, hold)
    if hold or type(token) ~= "string" or not Plain(token) then return end
    local now = GetTime()
    if token == lastEmote and now == lastEmoteT then return end
    lastEmote, lastEmoteT = token, now
    Emit("EM", token)
    Add("emotes")
    local ch = ns.char
    if ch then
        ch.emoteCounts = ch.emoteCounts or {}
        ch.emoteCounts[token] = (ch.emoteCounts[token] or 0) + 1
    end
end

if C_ChatInfo and C_ChatInfo.SendChatMessage then hooksecurefunc(C_ChatInfo, "SendChatMessage", OnSay) end
if SendChatMessage then hooksecurefunc("SendChatMessage", OnSay) end
if C_ChatInfo and C_ChatInfo.PerformEmote then hooksecurefunc(C_ChatInfo, "PerformEmote", OnEmote) end
if DoEmote then hooksecurefunc("DoEmote", OnEmote) end

-- Session --------------------------------------------------------------------------

local function EnsureLogging()
    if not ns.opt.combatLog or not LoggingCombat or InCombatLockdown() then return end
    if not LoggingCombat() then
        LoggingCombat(true)
        Emit("LG", 1)
    end
end

function H.ADDON_LOADED(name)
    if name ~= ADDON then return end
    frame:UnregisterEvent("ADDON_LOADED")
    ns.InitDB()
end

function H.PLAYER_LOGIN()
    -- On Forever the second part is the surname (no realms): Thrall-Doomhammer,
    -- the same as the client's WTF folder. A name without one falls back to the server.
    local name, realm = UnitFullName("player")
    if not Plain(realm) or realm == "" then realm = GetNormalizedRealmName() or GetRealmName() end
    ns.InitChar(ns.Field(name) .. "-" .. ns.Field(realm))
    playerGUID = UnitGUID("player")
    ns.session, ns.sessionG = time(), GetTime()
    local _, class = UnitClass("player")
    local _, race = UnitRace("player")
    -- server: the realm ID of the server you picked at login (PvE or PvP; 91 in
    -- the client's WTF folder), so data from different servers stays apart.
    -- Forever's realm name is empty, so the ID is the field that tells them apart.
    -- The cap decides whether any levelling work runs this session (Core.lua, ns.Cap).
    ns.Cap.Refresh()
    if ns.Cap.Levelling() then
        lastXP, lastMax = UnitXP("player"), UnitXPMax("player")
        if not Plain(lastXP) or not Plain(lastMax) then lastXP, lastMax = nil, nil end
    else
        lastXP, lastMax = nil, nil
    end
    -- Appended to S: region (the client's region id), toc (the interface number), the
    -- experience bar (xp, xpMax), money (the copper you carry), and the level cap the client reports
    -- (empty when it does not say). At the cap or with experience off the bar fields are empty.
    lastMoney = GetMoney()
    Emit("S", (GetBuildInfo()), class, race, UnitLevel("player"), (UnitFactionGroup("player")), ns.VERSION,
        _G.GetRealmID and _G.GetRealmID() or "", GetRealmName(),
        _G.GetCurrentRegion and _G.GetCurrentRegion() or "", select(4, GetBuildInfo()), lastXP or "", lastMax or "",
        lastMoney, ns.Cap.level or "")
    Ov.Start(ns.session, Num(UnitLevel("player")), Num(lastMoney), Num(lastXP), Num(lastMax))
    dead = UnitIsDeadOrGhost("player") and true or false
    if ns.OnLogin then ns.OnLogin() end
end

function H.PLAYER_ENTERING_WORLD()
    Zone()
    EnsureLogging()
    if not entered then
        entered = true
        TimerOn("stillTime")
        SetAFK()
        SetRested()
        Roster()
        AuraScan(true)
        wasResting = IsResting()
        if Plain(wasResting) then Emit("RS", wasResting and 1 or 0) end
        CountBags(bagCounts)
        bagsReady = true
    end
end

function H.PLAYER_LOGOUT()
    while xpPending[1] do FlushXP(table.remove(xpPending, 1)) end
    local xpNow, xpMaxNow
    if ns.Cap.Levelling() then xpNow, xpMaxNow = Num(UnitXP("player")), Num(UnitXPMax("player")) end
    Ov.End(xpNow, xpMaxNow)
    EndSegment()
    StopTicker()
    if campT0 then
        Emit("CP", 0, Round1(GetTime() - campT0))
        if ns.char then ns.char.campLeft = time() end
    end
    FlushMates()
    for k in pairs(timers) do TimerOff(k) end
    if bagsReady then WriteCounts("b", bagCounts) end
    if ns.Cap.Levelling() then
        local rest, xpMax, resting = GetXPExhaustion(), UnitXPMax("player"), IsResting()
        if Plain(rest) and Plain(xpMax) and Plain(resting) then
            Emit("RO", rest or 0, xpMax or 0, resting and 1 or 0)
        end
    end
    Emit("ES")
    if ns.sessionG then Add("tracked", GetTime() - ns.sessionG) end
    ns.Seal(true)
end

-- Registration ----------------------------------------------------------------------

-- Shared with Track.lua.
ns.SpellName, ns.ItemName, ns.MapPoint, ns.NpcID, ns.Pattern = SpellName, ItemName, MapPoint, NpcID, Pattern
ns.Round1, ns.TimerOn, ns.TimerOff = Round1, TimerOn, TimerOff
ns.WriteCounts, ns.ListSig = WriteCounts, ListSig

local LEVELLING_EVENTS = { "PLAYER_XP_UPDATE", "UPDATE_EXHAUSTION" }
ns.Listen(frame, H, "Capture", { UNIT_HEALTH = true, PLAYER_XP_UPDATE = true, UPDATE_EXHAUSTION = true })
ns.Cap.Watch(frame, LEVELLING_EVENTS)
