-- PvP.lua: battleground and match tracking beyond Track's honor, kills and flag (HK, HN, PV, DU, DW):
--   BQ  a battleground queue changed: queued, match ready, entered, left
--   BM  a match: entered, started, over (with the winner), left
--   BS  your own scoreboard row, once per match
--   BN  a scoreboard stat's name, once per session
--   HL  honor level changed
--   PB  PvP baseline: honor level and war mode, at login and when war mode changes
--   ZP  the zone's PvP kind (sanctuary, friendly, contested, hostile, arena, combat)
-- Codes are in docs/FORMAT.md. Event driven only, nothing on a timer except three short
-- retries after a match ends. Every client value goes through Plain() before it is compared
-- or indexed. The scoreboard is secret while a match is active, so the own row is read only
-- after PVP_MATCH_COMPLETE, by GUID (the index list follows the faction tab), and written
-- once; UPDATE_BATTLEFIELD_SCORE returns at once when no row is waiting. No chat text and no
-- other player's row.
local _, ns = ...

local type, pcall = type, pcall
local min = math.min
local Emit, Plain, Round1 = ns.Emit, ns.Plain, ns.Round1

local PVP = C_PvP or {}
local GetStatus = _G.GetBattlefieldStatus
local GetMax = _G.GetMaxBattlefieldID
local GetWaited = _G.GetBattlefieldTimeWaited

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

local seen = false

-- Queues -------------------------------------------------------------------------------
-- BQ <state> <index> <map> <teamSize> <rated> <queueType> <role> <seconds> <from> <baseline>.
-- state: `q` queued, `c` the match is ready, `a` you entered it, `x` the queue ended. seconds
-- is how long the queue spent in its last state (waiting for `c`, deciding for `a`, inside for
-- `x`), from is that last state (`q`, `c` or `a`) on `x`. baseline `s` for a queue already
-- there when the session began. Written once per change of status or map for each queue slot.

local CODE = { queued = "q", confirm = "c", active = "a" }
local queues = {}

local function Queue(index, baseline)
    index = Num(index)
    if not index or index < 1 or index > 16 then return end
    local r = Pack(GetStatus, index)
    if not r then return end
    local status = Str(r[2]) or "none"
    local map = Str(r[3]) or ""
    local prev = queues[index]
    local key = status .. ":" .. map
    if prev and prev.key == key then return end
    local now = GetTime()
    local q = { key = key, status = status, t0 = now, map = map, team = Num(r[4]) or "", rated = Flag(r[5]),
        kind = Str(r[7]) or "", role = Str(r[9]) or "" }
    queues[index] = q
    local code, was = CODE[status], prev and CODE[prev.status]
    if code then
        local secs = ""
        if prev and was then
            secs = Round1(now - prev.t0)
        elseif not prev and status == "queued" and type(GetWaited) == "function" then
            local waited = Num(Call(GetWaited, index))
            if waited then
                q.t0 = now - waited / 1000
                secs = Round1(waited / 1000)
            end
        end
        Emit("BQ", code, index, map, q.team, q.rated, q.kind, q.role, secs, was or "", baseline and "s" or "")
    elseif was then
        Emit("BQ", "x", index, prev.map, prev.team, prev.rated, prev.kind, prev.role, Round1(now - prev.t0), was, "")
    end
end

local function ScanQueues(baseline)
    local n = Num(Call(GetMax)) or 3
    for i = 1, min(n, 8) do Queue(i, baseline) end
end

function H.UPDATE_BATTLEFIELD_STATUS(index)
    Queue(index, not seen)
end

-- Matches ------------------------------------------------------------------------------
-- BM 1 <instanceMapID> <zone> <instanceType> <matchState> <baseline> <rated> <factional> <arena>
--    <team>: you are in a match. matchState is the client's PvPMatchState (0 inactive, 1 waiting,
--    2 start-up, 3 engaged, 4 post-round, 5 complete). team is your side (0 Horde, 1 Alliance).
--    baseline `s` for a match already running when the session began.
-- BM 2 <instanceMapID>: the match started (gates open).
-- BM 0 <instanceMapID> <winner> <duration> <team> <result> <affectsRating> <arena>: the match
--    ended. winner is the client's side (0 Horde, 1 Alliance; in an arena a team index;
--    anything else is a draw); result is `w` you won, `l` you lost, `d` a draw; duration is
--    the client's number.
-- BM 3 <instanceMapID> <seconds>: you left it, with how long you were inside.

local match, completed = nil, false
local pending, lastTry = false, 0
local startPending = false
local Leave

local function InstanceKind()
    local _, itype, _, _, _, _, _, id = GetInstanceInfo()
    return Str(itype) or "", Num(id) or ""
end

local function Team()
    return Num(Call(_G.GetBattlefieldArenaFaction))
end

-- force: an event said you joined a match. It can fire before the instance info has
-- caught up, so an unclear type is read again a second later instead of written.
-- A different instance while in a match is a hop from one match to the next.
local function Enter(force, baseline)
    local itype, id = InstanceKind()
    if itype ~= "pvp" and itype ~= "arena" then
        if force then C_Timer.After(1, function() Enter(false, baseline) end) end
        return
    end
    -- A join event after the match ended is the next match, even on the same map.
    if match then
        if match.id == id and not (force and completed) then return end
        Leave()
    end
    match, completed, pending = { id = id, t0 = GetTime() }, false, false
    Emit("BM", 1, id, Str(GetRealZoneText()) or "", itype, Num(Call(PVP.GetActiveMatchState)) or "",
        baseline and "s" or "", Flag(Call(PVP.IsRatedMap)), Flag(Call(PVP.IsMatchFactional)),
        Flag(Call(PVP.IsMatchConsideredArena)), Team() or "")
    if startPending then
        startPending = false
        Emit("BM", 2, id)
    end
end

function H.PLAYER_JOINED_PVP_MATCH()
    Enter(true, false)
end

-- Classic's name for the same moment; whichever comes first writes the line.
function H.PLAYER_ENTERING_BATTLEGROUND()
    Enter(true, false)
end

-- When the instance info is not settled yet, BM 2 follows the BM 1 the retry writes.
function H.PVP_MATCH_ACTIVE()
    Enter(true, false)
    if match then
        Emit("BM", 2, match.id)
    else
        startPending = true
    end
end

local named = {}

local function StatName(id, name)
    if named[id] or not Str(name) then return end
    named[id] = true
    Emit("BN", id, name)
end

-- BS <killingBlows> <honorableKills> <deaths> <honorGained> <damageDone> <healingDone> <rating>
--    <ratingChange> <mmrChange> <honorLevel> <spec> <role> <teamSize> <enemySize> <stats>: your
--    own scoreboard row after the match. stats are the mode's objective numbers as id:value
--    joined by commas (BN names the ids). A value the client keeps secret is `?`. Written
--    once per match; a line with only `?` means the client gave no row at all.
local function Score(final)
    if not pending then return end
    local guid = UnitGUID("player")
    local info = Plain(guid) and Call(PVP.GetScoreInfoByPlayerGuid, guid) or nil
    if type(info) ~= "table" then
        if final then
            pending = false
            Emit("BS", "?")
        end
        return
    end
    if not final and not (Num(info.killingBlows) and Num(info.honorGained)) then return end
    pending = false
    local stats = ""
    local list = info.stats
    if Plain(list) and type(list) == "table" then
        for i = 1, min(#list, 12) do
            local s = list[i]
            if type(s) == "table" then
                local id, value = Num(s.pvpStatID), Num(s.pvpStatValue)
                if id and value then
                    StatName(id, s.name)
                    stats = stats .. (stats == "" and "" or ",") .. id .. ":" .. value
                end
            end
        end
    end
    local team = Team()
    local mine = team and Call(PVP.GetTeamInfo, team)
    local theirs = team and Call(PVP.GetTeamInfo, 1 - team)
    Emit("BS", info.killingBlows, info.honorableKills, info.deaths, info.honorGained, info.damageDone,
        info.healingDone, info.rating, info.ratingChange, info.mmrChange, info.honorLevel, info.talentSpec,
        info.roleAssigned, type(mine) == "table" and Num(mine.size) or "",
        type(theirs) == "table" and Num(theirs.size) or "", stats)
end

function H.PVP_MATCH_COMPLETE(winner, duration)
    if completed then return end
    completed = true
    local team, w = Team(), Num(winner)
    local result = ""
    if team and w then
        result = (w == team and "w") or ((w == 0 or w == 1) and "l") or "d"
    end
    Emit("BM", 0, match and match.id or select(2, InstanceKind()), w or "", Num(duration) or "", team or "", result,
        Flag(Call(PVP.DoesMatchOutcomeAffectRating)), Flag(Call(PVP.IsMatchConsideredArena)))
    pending = true
    local request = _G.RequestBattlefieldScoreData
    if type(request) == "function" then pcall(request) end
    C_Timer.After(2, function() Score(false) end)
    C_Timer.After(6, function() Score(false) end)
    C_Timer.After(15, function() Score(true) end)
end

-- The scoreboard refreshes about once a second during a match, all of it secret until the
-- match ends. Nothing to read before then.
function H.UPDATE_BATTLEFIELD_SCORE()
    if not pending then return end
    local now = GetTime()
    if now - lastTry < 1 then return end
    lastTry = now
    Score(false)
end

-- A loading screen after the match ended leaves it, so the next match on the same map
-- starts fresh.
function H.PLAYER_LEAVING_WORLD()
    Score(true)
    if completed and Leave then Leave() end
end

Leave = function()
    if not match then return end
    local m = match
    match = nil
    Emit("BM", 3, m.id, Round1(GetTime() - m.t0))
end

-- Honor and war mode -------------------------------------------------------------------
-- HL <level> <higher>: the honor level changed; higher is `1` for a gain.
-- PB <honorLevel> <warModeDesired> <warModeActive> <why>: why `s` at login, `w` when the
-- client reported a war mode change. Fields are empty where the client has no such thing.

local lastHL, lastPB

local function HonorLevel()
    return Num(Call(_G.UnitHonorLevel, "player"))
end

function H.HONOR_LEVEL_UPDATE(higher)
    local level = HonorLevel()
    local key = (level or "") .. ":" .. Flag(higher)
    if key == lastHL then return end
    lastHL = key
    Emit("HL", level or "", Flag(higher))
end

local function Baseline(why)
    local honor, desired, active = HonorLevel(), Call(PVP.IsWarModeDesired), Call(PVP.IsWarModeActive)
    if honor == nil and desired == nil and active == nil then return end
    local key = (honor or "") .. ":" .. Flag(desired) .. ":" .. Flag(active)
    if key == lastPB then return end
    lastPB = key
    Emit("PB", honor or "", Flag(desired), Flag(active), why)
end

function H.WAR_MODE_STATUS_UPDATE()
    Baseline("w")
end

-- Zone PvP kind ------------------------------------------------------------------------
-- ZP <pvpType> <subzonePvP> <faction>: the zone's PvP kind changed (`sanctuary`, `friendly`,
-- `contested`, `hostile`, `arena`, `combat`, or empty). subzonePvP `1` when the subzone has
-- its own rule. faction is the controlling faction's name when the client names one.

local lastZP

local function ZonePvP()
    local r = Pack(PVP.GetZonePVPInfo)
    local kind = r and Str(r[2]) or ""
    local sub = r and Flag(r[3]) or ""
    local faction = r and Str(r[4]) or ""
    local key = kind .. ":" .. sub .. ":" .. faction
    if key == lastZP then return end
    local first = lastZP == nil
    lastZP = key
    if first and kind == "" then return end
    Emit("ZP", kind, sub, faction)
end

H.ZONE_CHANGED = ZonePvP
H.ZONE_CHANGED_INDOORS = ZonePvP
H.ZONE_CHANGED_NEW_AREA = ZonePvP

-- Lifecycle ----------------------------------------------------------------------------
-- PLAYER_ENTERING_WORLD fires at every loading screen, so it also notices you left a match.

function H.PLAYER_ENTERING_WORLD()
    ZonePvP()
    local itype = InstanceKind()
    if match and itype ~= "pvp" and itype ~= "arena" then
        Leave()
    else
        Enter(false, not seen and not match)
    end
    if not seen then
        C_Timer.After(5, function()
            ScanQueues(true)
            Baseline("s")
            seen = true
        end)
    end
end

ns.Listen(frame, H, "PvP")
