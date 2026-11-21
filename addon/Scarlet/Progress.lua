-- Progress.lua: the progress trackers beyond Capture, Track and Metrics (L, X, RX, RP, AC, AN, AE, LV):
--   RF  a faction's standing: tier, standing and tier bounds, when one of them changed
--   FN  a faction's name, once per session
--   RG  a paragon track: progress, reward pending, level
--   RV  major faction renown: a baseline, a level change, an unlock
--   RR  what a renown level gave
--   AD  an achievement as the client reported it earned: category, guild, reward text
--   AT  a tracked achievement's criterion progress
-- Codes are in docs/FORMAT.md. Event driven only, nothing on a timer; every client value
-- goes through Plain() before it is compared or indexed. Standings are read from a
-- debounced scan and written only when they differ from what was last written. No chat
-- text, no other player's achievements, no Mythic+, Delves or Trading Post (not in Forever).
local _, ns = ...

local type, pcall, pairs = type, pcall, pairs
local min = math.min
local Emit, Plain = ns.Emit, ns.Plain
local ItemName, SpellName = ns.ItemName, ns.SpellName

local REP = C_Reputation
local MAJOR = C_MajorFactions
local ACHI = C_AchievementInfo

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

-- Per-character state kept in SavedVariables so a login does not rewrite what is
-- already known: rf and rg (last written standing and paragon keys, cleared once a
-- day so each day starts with a full set), ids (factions seen, since the client
-- lists only the ones under expanded headers) and ad (achievements already written).
local function Store()
    local ch = ns.char
    if not ch then return end
    local p = ch.prog
    if type(p) ~= "table" then
        p = {}
        ch.prog = p
    end
    local today = date("%Y%m%d")
    if p.day ~= today then
        p.day, p.rf, p.rg = today, {}, {}
    end
    p.ids = p.ids or {}
    p.ad = p.ad or {}
    p.adN = p.adN or 0
    return p
end

-- Reputation ---------------------------------------------------------------------------
-- RF <factionID> <reaction> <standing> <floor> <ceiling> <atWar> <accountWide> <why>.
-- reaction is the client's tier (1 hated ... 8 exalted); standing, floor and ceiling are
-- the client's numbers for it. why `s` on the first read of the session. Written when the
-- tier, the standing or the war flag differs from the last line, so a reputation gain
-- shows up here once the scan after it runs. RP keeps the change by faction name.
-- RG <factionID> <value> <threshold> <rewardPending> <level> <why>: a paragon track,
-- written when its reward becomes pending or its level moves.
-- FN <factionID> <name> names a faction once per session.

local named = {}
local function FactionName(id, name)
    if named[id] or not Str(name) then return end
    named[id] = true
    Emit("FN", id, name)
end

local firstScan = true
local MAX_REACTION = 8

local function Paragon(p, id)
    local r = Pack(REP.GetFactionParagonInfo, id)
    local value, threshold = r and Num(r[2]), r and Num(r[3])
    if not value or not threshold then return end
    local pending, level = r[5], Num(r[7]) or 0
    local key = level .. ":" .. (Plain(pending) and pending and 1 or 0)
    if p.rg[id] == key then return end
    p.rg[id] = key
    Emit("RG", id, value, threshold, Flag(pending), level, firstScan and "s" or "")
end

local function Standing(p, data)
    if type(data) ~= "table" then return end
    local id = Num(data.factionID)
    if not id then return end
    if Plain(data.isHeader) and data.isHeader and not (Plain(data.isHeaderWithRep) and data.isHeaderWithRep) then
        return
    end
    p.ids[id] = true
    local reaction, standing = Num(data.reaction), Num(data.currentStanding)
    if not reaction or not standing then return end
    local war = Plain(data.atWarWith) and data.atWarWith and 1 or 0
    local key = reaction .. ":" .. standing .. ":" .. war
    if p.rf[id] ~= key then
        p.rf[id] = key
        FactionName(id, data.name)
        Emit("RF", id, reaction, standing, Num(data.currentReactionThreshold) or "",
            Num(data.nextReactionThreshold) or "", war, Flag(data.isAccountWide), firstScan and "s" or "")
    end
    if reaction >= MAX_REACTION and Call(REP.IsFactionParagonForCurrentPlayer, id) then
        Paragon(p, id)
    end
    return id
end

local due, queued, started = false, false, false

local function Scan()
    queued = false
    local p = REP and Store()
    if not p then return end
    if InCombatLockdown() then
        due = true
        return
    end
    due = false
    local done = {}
    local n = Num(Call(REP.GetNumFactions))
    if n then
        for i = 1, min(n, 400) do
            local id = Standing(p, Call(REP.GetFactionDataByIndex, i))
            if id then done[id] = true end
        end
    end
    local id = Standing(p, Call(REP.GetGuildFactionData))
    if id then done[id] = true end
    -- Factions under collapsed headers are missed by the index; the ones seen before
    -- are read by id.
    for fid in pairs(p.ids) do
        if not done[fid] then
            -- Forget an id only when the client answered with no faction; a failed
            -- or secret read keeps it for the next scan.
            local ok, data = pcall(REP.GetFactionDataByID, fid)
            if ok and not data then
                p.ids[fid] = nil
            elseif ok and Plain(data) then
                Standing(p, data)
            end
        end
    end
    firstScan = false
end

local function Soon()
    if queued or not started then return end
    queued = true
    C_Timer.After(3, Scan)
end

H.UPDATE_FACTION = Soon

function H.FACTION_STANDING_CHANGED(factionID)
    local p = Store()
    if p and Num(factionID) then p.ids[factionID] = true end
    Soon()
end

function H.PLAYER_REGEN_ENABLED()
    if due then Soon() end
end

-- Renown -------------------------------------------------------------------------------
-- RV <kind> <factionID> <level> <old or max> <earned> <threshold>. kind `b` a baseline at
-- the start of the session for each unlocked major faction (level, max level, renown earned
-- toward the next level, what that level needs), `l` a level change (level, old level; the
-- Legacy reward track's level change is LV), `u` a major faction unlocked.
-- RR <factionID> <level> <itemID> <spellID> <mountID> <transmogSetID> <titleMaskID>: one
-- line per reward of a renown level you reached.

local C = _G.Constants
local LEGACY = C and C.LegacyConsts and C.LegacyConsts.LEGACY_REWARD_TRACK_FACTION_ID

local function MajorName(id)
    local d = MAJOR and Call(MAJOR.GetMajorFactionData, id)
    if type(d) == "table" then
        FactionName(id, d.name)
        return d
    end
end

local function Baseline()
    if not MAJOR then return end
    local ids = {}
    if Num(LEGACY) then ids[1] = LEGACY end
    local list = Call(MAJOR.GetMajorFactionIDs)
    if type(list) == "table" then
        for i = 1, min(#list, 50) do
            local id = Num(list[i])
            if id and id ~= LEGACY then ids[#ids + 1] = id end
        end
    end
    for i = 1, #ids do
        local d = MajorName(ids[i])
        if d and Plain(d.isUnlocked) and d.isUnlocked and Num(d.renownLevel) then
            Emit("RV", "b", ids[i], d.renownLevel, Num(d.maxLevel) or "", Num(d.renownReputationEarned) or "",
                Num(d.renownLevelThreshold) or "")
        end
    end
end

local function Rewards(id, level)
    local list = MAJOR and Call(MAJOR.GetRenownRewardsForLevel, id, level)
    if type(list) ~= "table" then return end
    for i = 1, min(#list, 20) do
        local r = list[i]
        if type(r) == "table" then
            local item, spell = Num(r.itemID), Num(r.spellID)
            if item then ItemName(item) end
            if spell then SpellName(spell) end
            Emit("RR", id, level, item or "", spell or "", Num(r.mountID) or "", Num(r.transmogSetID) or "",
                Num(r.titleMaskID) or "")
        end
    end
end

function H.MAJOR_FACTION_RENOWN_LEVEL_CHANGED(id, new, old)
    if not Num(id) or not Num(new) then return end
    if id ~= LEGACY then
        MajorName(id)
        Emit("RV", "l", id, new, Num(old) or "")
    end
    Rewards(id, new)
end

function H.MAJOR_FACTION_UNLOCKED(id)
    if not Num(id) then return end
    MajorName(id)
    Emit("RV", "u", id)
end

-- Achievements -------------------------------------------------------------------------
-- AD <achievementID> <alreadyEarned> <guild> <categoryID> <rewardText>: the client's
-- details for an achievement it reported newly earned, once per achievement per character.
-- The client re-announces old earns (alreadyEarned) on some logins; those write nothing.
-- rewardText is what the achievement pays out (a title, a mount).
-- AT <achievementID> <criteriaID> <quantity> <required> <done> <text> <duration>: a tracked
-- achievement's criterion changed its numbers (written only when they changed; text on the
-- first line for that criterion in a session; duration for a timed one). Tracking and
-- untracking is CK type 2.

local AD_MAX = 4000

function H.ACHIEVEMENT_EARNED(id, already)
    if Plain(already) and already then return end
    local p = Store()
    if not p or not Num(id) or p.ad[id] or p.adN >= AD_MAX then return end
    p.ad[id] = 1
    p.adN = p.adN + 1
    local r = Pack(_G.GetAchievementInfo, id)
    local guild = ACHI and Call(ACHI.IsGuildAchievement, id)
    if guild == nil and r then guild = r[13] end
    Emit("AD", id, Flag(already), Flag(guild), Num(Call(_G.GetAchievementCategory, id)) or "",
        r and Str(r[12]) or "")
end

local crit, critN = {}, 0

function H.TRACKED_ACHIEVEMENT_UPDATE(id, criteriaID, _, duration)
    local cid = Num(criteriaID)
    if not Num(id) or not cid then return end
    local count, info = _G.GetAchievementNumCriteria, _G.GetAchievementCriteriaInfo
    local n = Num(Call(count, id))
    if not n or type(info) ~= "function" then return end
    for i = 1, min(n, 60) do
        local r = Pack(info, id, i)
        if r and Num(r[11]) == cid then
            local qty, req, done = Num(r[5]), Num(r[6]), Flag(r[4])
            local dur = Num(duration)
            local key = id .. ":" .. cid
            local state = (qty or "") .. ":" .. done .. ":" .. (dur or "")
            local before = crit[key]
            if before == state then return end
            if before == nil then
                critN = critN + 1
                if critN > 500 then crit, critN = {}, 1 end
            end
            crit[key] = state
            Emit("AT", id, cid, qty or "", req or "", done, before == nil and Str(r[2]) or "", dur or "")
            return
        end
    end
end

-- Lifecycle ----------------------------------------------------------------------------

local entered = false
function H.PLAYER_ENTERING_WORLD()
    if entered then return end
    entered = true
    -- UPDATE_FACTION fires for every faction at login; the first scan waits for it to settle.
    C_Timer.After(8, function()
        started = true
        Scan()
        Baseline()
    end)
end

ns.Listen(frame, H, "Progress")
