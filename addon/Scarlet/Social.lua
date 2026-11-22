-- Social.lua: what a character does with other players:
--   GU  guild membership: a baseline, joining, leaving, a rank change, an invite
--   GH  guild head count: members and how many are online
--   FR  friends and the ignore list: adds, removes, friends coming online and going offline
--   FC  friend, ignore and Battle.net counts
--   GI  party invites you received, sent, answered or cancelled, and the group actions you took
--   GL  your group: leader, each member's role, guild mate and friend flags, role polls, group kind
--   RC  ready checks: started, each answer, finished
--   LF  the group finder: your listing, searches, and the dungeon finder when the client has one
--   IV  a player you inspected
--   CT  chat activity as counts only: messages and words per channel type, sent and received
--   DQ  duel details beyond DU and DW: to the death, boundary, finished
--   CE  the calendar: pending invites, an alarm, an event opened
--   CM  communities and the community finder
-- Codes are in docs/FORMAT.md. Event driven only, nothing on a timer; every client value
-- goes through Plain() before it is compared or indexed. Rosters and friend events burst, so
-- they are read from a debounced scan and written only when they differ from the last line.
-- Never recorded: chat text, whispers, guild notes and message of the day, calendar titles,
-- community descriptions, listing titles and comments, rank names, Battle.net names or tags.
-- Other players appear by character name only, as GM already does.
local _, ns = ...

local type, pcall, pairs = type, pcall, pairs
local min = math.min
local concat = table.concat
local GetTime = GetTime
local Emit, Plain = ns.Emit, ns.Plain

local FL = C_FriendList
local GUILDI = C_GuildInfo
local PARTY = C_PartyInfo
local LFGL = C_LFGList
local LFGI = C_LFGInfo
local LFGR = C_LFGListRoles
local CAL = C_Calendar
local CLUB = C_Club
local FINDER = C_ClubFinder

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

-- A unit's name written the way Capture writes a GM name: Name, plus -Realm when the
-- client gives one.
local function UnitKey(unit)
    local name, realm = UnitName(unit)
    if not Plain(name) or type(name) ~= "string" or name == "" or name == _G.UNKNOWNOBJECT then return end
    if Plain(realm) and type(realm) == "string" and realm ~= "" then name = name .. "-" .. realm end
    return name
end

local ROLE = { TANK = "t", HEALER = "h", DAMAGER = "d" }
local function RoleCode(v)
    v = Str(v)
    return v and ROLE[v] or ""
end

-- Per-character state kept in SavedVariables: fr and ig (the friend and ignore names last
-- written, so a login does not rewrite the lists; frInit and igInit say the first full list
-- was written).
local function Store()
    local ch = ns.char
    if not ch then return end
    local s = ch.soc
    if type(s) ~= "table" then
        s = {}
        ch.soc = s
    end
    s.fr = s.fr or {}
    s.ig = s.ig or {}
    return s
end

local started = false
local queued = {}

-- Run fn once, delay seconds from now, however many times it is asked for meanwhile.
local function Later(key, delay, fn)
    if queued[key] or not started then return end
    queued[key] = true
    C_Timer.After(delay, function()
        queued[key] = nil
        fn()
    end)
end

local lastAt = {}
-- true when key was last allowed at least secs ago; stamps the time when it is.
local function Due(key, secs)
    local now = GetTime()
    local t = lastAt[key]
    if t and now - t < secs then return false end
    lastAt[key] = now
    return true
end

local function Hook(tbl, name, fn)
    if type(tbl) == "table" and type(tbl[name]) == "function" then pcall(hooksecurefunc, tbl, name, fn) end
end

local function HookG(name, fn)
    if type(_G[name]) == "function" then pcall(hooksecurefunc, name, fn) end
end

local TOKENS = { target = true, mouseover = true, focus = true, player = true, party1 = true, party2 = true,
    party3 = true, party4 = true, softtarget = true }

-- A name given to an invite or a group action: a unit token becomes that unit's name.
local function Who(v)
    v = Str(v)
    if not v then return end
    if TOKENS[v] then return UnitKey(v) or v end
    return v
end

-- Guild ---------------------------------------------------------------------------------
-- GU <kind> <guildName> <rankIndex> <officer> <leader> <who>. kind: s the state at the start
-- of the session (empty guildName when in none), j joined (or the guild changed), l left,
-- k the rank, officer or leader flag changed, i an invite arrived (who is the inviter),
-- x the invite was withdrawn, a you accepted it, d you declined it. rankIndex is the
-- client's number (0 is the guild leader); the rank's name is free text and is not kept.
-- GH <members> <online> <onlineOrMobile> <why>: the guild's head count, written when the
-- roster changes, at most every five minutes unless the member count moved.

local gKnown, gName, gRank, gKey, gTries = false, nil, nil, nil, 0
local inviteGuild

local function GuildRead()
    local inGuild = Call(_G.IsInGuild)
    if inGuild == nil then return end
    local name, rank
    if inGuild then
        local r = Pack(_G.GetGuildInfo, "player")
        name, rank = r and Str(r[2]), r and Num(r[4])
        if not name then
            -- the client has not loaded the guild yet
            gTries = gTries + 1
            if gTries <= 3 then Later("guild", 5, GuildRead) end
            return
        end
    end
    gTries = 0
    local officer = inGuild and Flag(Call(GUILDI and GUILDI.IsGuildOfficer)) or 0
    local leader = inGuild and Flag(Call(_G.IsGuildLeader)) or 0
    local key = (name or "") .. ":" .. (rank or "") .. ":" .. officer .. ":" .. leader
    if key == gKey then return end
    if not gKnown then
        Emit("GU", "s", name or "", rank or "", officer, leader, "")
    elseif name ~= gName then
        if gName then Emit("GU", "l", gName, gRank or "", "", "", "") end
        if name then Emit("GU", "j", name, rank or "", officer, leader, "") end
    elseif name then
        Emit("GU", "k", name, rank or "", officer, leader, "")
    end
    gKnown, gName, gRank, gKey = true, name, rank, key
end

local function GuildSoon()
    Later("guild", 2, GuildRead)
end

function H.PLAYER_GUILD_UPDATE(unit)
    if Plain(unit) and unit == "player" then GuildSoon() end
end

H.GUILD_RANKS_UPDATE = GuildSoon
H.GUILD_RANKS_UPDATE_ACTIVE_PLAYER = GuildSoon

function H.GUILD_INVITE_REQUEST(inviter, guildName)
    inviteGuild = Str(guildName) or "?"
    Emit("GU", "i", inviteGuild, "", "", "", Str(inviter) or "")
end

-- The cancel event also follows an answer; only an unanswered invite is written as withdrawn.
function H.GUILD_INVITE_CANCEL()
    if inviteGuild then Emit("GU", "x", inviteGuild, "", "", "", "") end
    inviteGuild = nil
end

local function InviteAnswered(kind)
    if not inviteGuild then return end
    Emit("GU", kind, inviteGuild, "", "", "", "")
    inviteGuild = nil
end

HookG("AcceptGuild", function() InviteAnswered("a") end)
HookG("DeclineGuild", function() InviteAnswered("d") end)

local lastHead, lastHeadTotal
local function Headcount()
    local r = Pack(_G.GetNumGuildMembers)
    local total, online, mobile = r and Num(r[2]), r and Num(r[3]), r and Num(r[4])
    if not total or total == 0 then return end
    local key = total .. ":" .. (online or "")
    if key == lastHead then return end
    if total == lastHeadTotal and not Due("GH", 300) then return end
    Due("GH", 0)
    lastHead, lastHeadTotal = key, total
    Emit("GH", total, online or "", mobile or "", "")
end

function H.GUILD_ROSTER_UPDATE()
    Later("headcount", 5, function()
        Headcount()
        GuildRead()
    end)
end

-- Friends and ignored players -------------------------------------------------------------
-- FR <kind> <name> <level> <class> <why>. kind: a added to the friends list, r removed, n came
-- online, f went offline, i added to the ignore list, u removed from it. why `b` for the
-- first full list this character ever wrote. class is the client's class name; level and
-- class are empty for ignore lines. Notes on friends are never read.
-- FC <friends> <friendsOnline> <ignored> <bnFriends> <bnOnline> <bnInvites> <bnBlocked>: the
-- counts, written when they change, at most every five minutes. Battle.net friends are
-- counted and never named.

-- frSeen and igSeen: a scan of this session has read a non-empty list. Removals wait for
-- that or for the third scan, since an empty or partial list at login is the list still
-- loading.
local online, lastFC = {}, nil
local frSeen, igSeen, frScans = false, false, 0

local function Counts()
    local friends = Num(Call(FL and FL.GetNumFriends))
    local on = Num(Call(FL and FL.GetNumOnlineFriends))
    local ignores = Num(Call(FL and FL.GetNumIgnores))
    local bn = Pack(_G.BNGetNumFriends)
    local invites = Num(Call(_G.BNGetNumFriendInvites))
    local blocked = Num(Call(_G.BNGetNumBlocked))
    local key = (friends or "") .. ":" .. (on or "") .. ":" .. (ignores or "") .. ":" .. (bn and Num(bn[2]) or "")
        .. ":" .. (bn and Num(bn[3]) or "") .. ":" .. (invites or "") .. ":" .. (blocked or "")
    if key == lastFC then return end
    if lastFC ~= nil and not Due("FC", 300) then return end
    if lastFC == nil then Due("FC", 0) end
    lastFC = key
    Emit("FC", friends or "", on or "", ignores or "", bn and Num(bn[2]) or "", bn and Num(bn[3]) or "",
        invites or "", blocked or "")
end

local function FriendScan()
    local s = Store()
    if not s or not FL then return end
    local n = Num(Call(FL.GetNumFriends))
    if n then
        local seen, complete = {}, true
        for i = 1, min(n, 200) do
            local info = Call(FL.GetFriendInfoByIndex, i)
            local name = type(info) == "table" and Str(info.name)
            if name then
                local on = Plain(info.connected) and info.connected and 1 or 0
                local level, class = Num(info.level) or "", Str(info.className) or ""
                seen[name] = true
                if not s.fr[name] then
                    s.fr[name] = 1
                    Emit("FR", "a", name, level, class, s.frInit and "" or "b")
                end
                local was = online[name]
                if was ~= on then
                    online[name] = on
                    if was ~= nil then Emit("FR", on == 1 and "n" or "f", name, level, class, "") end
                end
            else
                complete = false
            end
        end
        -- The list is not trusted to be loaded on the first scan of a session.
        if complete and (frSeen or frScans >= 2) then
            for name in pairs(s.fr) do
                if not seen[name] then
                    s.fr[name] = nil
                    online[name] = nil
                    Emit("FR", "r", name, "", "", "")
                end
            end
        end
        if n > 0 or frScans > 0 then s.frInit = true end
        if n > 0 then frSeen = true end
    end
    local ni = Num(Call(FL.GetNumIgnores))
    if ni then
        local seen, complete = {}, true
        for i = 1, min(ni, 100) do
            local name = Str(Call(FL.GetIgnoreName, i))
            if name then
                seen[name] = true
                if not s.ig[name] then
                    s.ig[name] = 1
                    Emit("FR", "i", name, "", "", s.igInit and "" or "b")
                end
            else
                complete = false
            end
        end
        if complete and (igSeen or frScans >= 2) then
            for name in pairs(s.ig) do
                if not seen[name] then
                    s.ig[name] = nil
                    Emit("FR", "u", name, "", "", "")
                end
            end
        end
        if ni > 0 or frScans > 0 then s.igInit = true end
        if ni > 0 then igSeen = true end
    end
    frScans = frScans + 1
    Counts()
end

local function FriendsSoon()
    Later("friends", 3, FriendScan)
end

H.FRIENDLIST_UPDATE = FriendsSoon
H.IGNORELIST_UPDATE = FriendsSoon
H.BN_FRIEND_LIST_SIZE_CHANGED = FriendsSoon
H.BN_FRIEND_ACCOUNT_ONLINE = FriendsSoon
H.BN_FRIEND_ACCOUNT_OFFLINE = FriendsSoon
H.BN_FRIEND_INVITE_ADDED = FriendsSoon
H.BN_FRIEND_INVITE_REMOVED = FriendsSoon
H.BN_FRIEND_INVITE_LIST_INITIALIZED = FriendsSoon
H.BN_BLOCK_LIST_UPDATED = FriendsSoon
H.BN_CONNECTED = FriendsSoon
H.BN_DISCONNECTED = FriendsSoon

-- Party invites and group actions ----------------------------------------------------------
-- GI <kind> <who> <roles>. kind: r an invite reached you (who is the inviter, roles the
-- roles they offered as t, h and d), x it was cancelled before you answered, a you accepted,
-- d you declined, s you invited someone, q you asked to join someone's group, k you removed
-- a member, p you gave the lead, m you made an assistant, u you removed an assistant, c you
-- converted the group to a raid, y you converted it back to a party, l you left the group,
-- e you changed "everyone is an assistant" (who is 1 or 0). who is the name as the client gave
-- it, which may carry no surname.

local pending
local lastGI, lastGIAt

local function Invite(kind, who, roles)
    local now = GetTime()
    local key = kind .. ":" .. (who or "")
    -- the namespaced and the global function can both run for one action
    if key == lastGI and now - lastGIAt < 0.5 then return end
    lastGI, lastGIAt = key, now
    Emit("GI", kind, who or "", roles or "")
end

function H.PARTY_INVITE_REQUEST(name, tank, healer, damage)
    local who = Str(name)
    local roles = (Plain(tank) and tank and "t" or "") .. (Plain(healer) and healer and "h" or "")
        .. (Plain(damage) and damage and "d" or "")
    pending = { who = who, answered = false }
    Invite("r", who, roles)
end

function H.PARTY_INVITE_CANCEL()
    if pending and not pending.answered then Invite("x", pending.who) end
    pending = nil
end

local function Answered(kind)
    if not pending then return end
    pending.answered = true
    Invite(kind, pending.who)
end

HookG("AcceptGroup", function() Answered("a") end)
HookG("DeclineGroup", function() Answered("d") end)

local function Act(kind)
    return function(name) Invite(kind, Who(name)) end
end

for _, fn in pairs({ { "InviteUnit", "s" }, { "RequestInviteFromUnit", "q" }, { "UninviteUnit", "k" },
    { "PromoteToLeader", "p" }, { "PromoteToAssistant", "m" }, { "DemoteAssistant", "u" } }) do
    Hook(PARTY, fn[1], Act(fn[2]))
    HookG(fn[1], Act(fn[2]))
end
for _, fn in pairs({ { "ConvertToRaid", "c" }, { "ConvertToParty", "y" }, { "LeaveParty", "l" } }) do
    local kind = fn[2]
    Hook(PARTY, fn[1], function() Invite(kind) end)
    HookG(fn[1], function() Invite(kind) end)
end
local function Everyone(on) Invite("e", Plain(on) and (on and "1" or "0") or "") end
Hook(PARTY, "SetEveryoneIsAssistant", Everyone)
HookG("SetEveryoneIsAssistant", Everyone)

-- Your group ---------------------------------------------------------------------------
-- GL <kind> ...:
--   m <name> <role> <leader> <assistant> <subgroup> <guildMate> <friend> <level> <class> <online>:
--     a member's state, written when the member appears or any of it changes. role is t, h, d
--     or empty; subgroup is the raid group (empty in a party); class is the class file. You
--     are in the list under your own name.
--   l <name> <isYou>: the group leader changed.
--   s <raid> <crossFaction> <full> <guildGroup>: what kind of group it is, written on change.
--   j <category> and x <category>: a group of that category (1 home party, 2 instance group)
--     formed around you or you left it.
--   p <name>: a role poll started (name is who started it).
--   c <name> <by> <old> <new>: a member's role was changed by `by`, roles as t, h, d or empty.

local members, leaderKey, stateKey = {}, nil, nil
local guildParty = ""
local Met -- players met, below

local function Is(v)
    return Plain(v) and v and true or false
end

local function MemberRow(unit, key, raidIndex)
    local guid = UnitGUID(unit)
    if not Plain(guid) or type(guid) ~= "string" then guid = nil end
    local role = RoleCode(UnitGroupRolesAssigned(unit))
    local lead = Flag(UnitIsGroupLeader(unit))
    local assist = Flag(UnitIsGroupAssistant(unit))
    local sub = ""
    if raidIndex then
        local r = Pack(_G.GetRaidRosterInfo, raidIndex)
        sub = r and Num(r[4]) or ""
    end
    local guild = guid and Flag(Call(_G.IsPlayerInGuildFromGUID, guid)) or ""
    local friend = guid and Flag(Call(FL and FL.IsFriend, guid)) or ""
    local _, class = UnitClass(unit)
    local _, race = UnitRace(unit)
    local fields = { key, role, lead, assist, sub, guild, friend, Num(UnitLevel(unit)) or "",
        Str(class) or "", Flag(UnitIsConnected(unit)), Str(race) or "", Str(UnitFactionGroup(unit)) or "",
        Str(Call(_G.GetGuildInfo, unit)) or "" }
    return concat(fields, "\t"), fields, lead == 1
end

local function GroupScan()
    local inGroup = IsInGroup()
    if not Plain(inGroup) then return end
    if not inGroup then
        if next(members) or leaderKey or stateKey then
            members, leaderKey, stateKey = {}, nil, nil
        end
        return
    end
    local raid = IsInRaid()
    local n = Num(GetNumGroupMembers())
    if not Plain(raid) or not n then return end
    local seen, leader = {}, nil
    local last = raid and min(n, 40) or n
    for i = 1, last do
        local unit, idx
        if raid then
            unit, idx = "raid" .. i, i
        else
            unit = i == 1 and "player" or ("party" .. (i - 1))
        end
        if Is(UnitExists(unit)) then
            local key
            if Is(UnitIsUnit(unit, "player")) then
                key = ns.charKey
            else
                key = UnitKey(unit)
                Met(unit)
            end
            if key then
                local row, fields, isLead = MemberRow(unit, key, idx)
                seen[key] = true
                if isLead then leader = key end
                if members[key] ~= row then
                    members[key] = row
                    Emit("GL", "m", fields[1], fields[2], fields[3], fields[4], fields[5], fields[6],
                        fields[7], fields[8], fields[9], fields[10], fields[11], fields[12], fields[13])
                end
            end
        end
    end
    for key in pairs(members) do
        if not seen[key] then members[key] = nil end
    end
    if leader and leader ~= leaderKey then
        leaderKey = leader
        Emit("GL", "l", leader, leader == ns.charKey and 1 or 0)
    end
    local cross = Flag(Call(PARTY and PARTY.IsCrossFactionParty))
    local full = Flag(Call(PARTY and PARTY.IsPartyFull))
    local key = (raid and 1 or 0) .. ":" .. cross .. ":" .. full .. ":" .. guildParty
    if key ~= stateKey then
        stateKey = key
        Emit("GL", "s", raid and 1 or 0, cross, full, guildParty)
    end
end

local function GroupSoon()
    Later("group", 1.5, GroupScan)
end

H.GROUP_ROSTER_UPDATE = GroupSoon
H.RAID_ROSTER_UPDATE = GroupSoon
H.PLAYER_ROLES_ASSIGNED = GroupSoon
H.PARTY_LEADER_CHANGED = GroupSoon
H.PARTY_MEMBER_ENABLE = GroupSoon
H.PARTY_MEMBER_DISABLE = GroupSoon

function H.GUILD_PARTY_STATE_UPDATED(inGuildParty)
    guildParty = Flag(inGuildParty)
    GroupSoon()
end

function H.GROUP_JOINED(category)
    Emit("GL", "j", Num(category) or "")
    GroupSoon()
end

function H.GROUP_LEFT(category)
    Emit("GL", "x", Num(category) or "")
    GroupSoon()
end

function H.ROLE_POLL_BEGIN(fromName)
    Emit("GL", "p", Str(fromName) or "")
end

function H.ROLE_CHANGED_INFORM(changed, from, old, new)
    Emit("GL", "c", Str(changed) or "", Str(from) or "", RoleCode(old), RoleCode(new))
end

-- Ready checks -------------------------------------------------------------------------
-- RC s <initiator> <seconds>: a ready check started (initiator is you when you called it).
-- RC r <name> <ready> <seconds>: a member answered, seconds after the start (name is you for
-- your own answer). ready is 1 or 0.
-- RC e <preempted> <seconds> <ready> <notReady>: it ended; ready and notReady count the
-- answers seen, members who never answered are in neither.

local rcT, rcReady, rcNot = nil, 0, 0

function H.READY_CHECK(initiator, timeLeft)
    rcT, rcReady, rcNot = GetTime(), 0, 0
    Emit("RC", "s", Str(initiator) or "", Num(timeLeft) or "")
end

function H.READY_CHECK_CONFIRM(unit, isReady)
    if not Plain(unit) or type(unit) ~= "string" then return end
    local name
    if unit == "player" then
        name = ns.charKey
    else
        name = UnitKey(unit)
    end
    if not name then return end
    local ready = Plain(isReady) and isReady and 1 or 0
    if ready == 1 then rcReady = rcReady + 1 else rcNot = rcNot + 1 end
    Emit("RC", "r", name, ready, rcT and math.floor((GetTime() - rcT) * 10 + 0.5) / 10 or "")
end

function H.READY_CHECK_FINISHED(preempted)
    Emit("RC", "e", Flag(preempted), rcT and math.floor((GetTime() - rcT) * 10 + 0.5) / 10 or "", rcReady, rcNot)
    rcT = nil
end

-- The group finder ----------------------------------------------------------------------
-- Forever's group finder is the "vanilla style" premade list (Blizzard_GroupFinder_VanillaStyle):
-- you list a group, browse listings and whisper a leader. The dungeon finder (LFD) is not in
-- the client (Blizzard_GroupFinder does not load for Forever); its events are kept in case
-- the server sends them.
-- LF b <groupFinder> <dungeonFinder> <premade> <enabled>: what the client lets you use, at the
--   start of the session and when the dungeon finder is switched on or off.
-- LF l <activityIDs> <activity> <autoAccept> <private> <minItemLevel> <seconds> <newPlayers>:
--   you listed a group (activityIDs joined by commas; activity names the first). u is the same
--   after you changed the listing. The listing's title and comment are never read.
-- LF r <why>: the listing ended. why x you removed it or it went away, t it timed out, f the
--   group filled.
-- LF s <category> <activities> <results> <shown>: a search finished (how many activities were
--   asked for, how many listings matched, how many passed the filters). f a search failed
--   (the third field is the client's reason). Listings and their leaders are not read.
-- LF o <tank> <healer> <dps>: the roles you picked for the finder changed.
-- LF w <results> <total>: a /who search came back with that many names shown and in total.
-- LF d <what> <id>: dungeon finder step. what: p a proposal appeared, y it was accepted by all,
--   n it failed, r a role check ran, c a ready check ran, w the completion reward arrived,
--   o the finder offered to continue (id is the dungeon).

local listed, listKey = false, nil
local search

local function ActivityList(t)
    if type(t) ~= "table" then return "", nil end
    local ids = {}
    for i = 1, min(#t, 8) do
        local id = Num(t[i])
        if id then ids[#ids + 1] = id end
    end
    return concat(ids, ","), ids[1]
end

local function ListingRead()
    if not LFGL then return end
    local has = Call(LFGL.HasActiveEntryInfo)
    if has == nil then return end
    if not has then
        if listed then
            listed, listKey = false, nil
            Emit("LF", "r", "x")
        end
        return
    end
    local e = Call(LFGL.GetActiveEntryInfo)
    if type(e) ~= "table" then return end
    local ids, first = ActivityList(e.activityIDs)
    local name = ""
    if first then
        local a = Call(LFGL.GetActivityInfoTable, first)
        if type(a) == "table" then name = Str(a.fullName) or "" end
    end
    local key = concat({ ids, Flag(e.autoAccept), Flag(e.privateGroup), Num(e.requiredItemLevel) or "",
        Num(e.duration) or "", Flag(e.newPlayerFriendly) }, ":")
    if key == listKey then return end
    Emit("LF", listed and "u" or "l", ids, name, Flag(e.autoAccept), Flag(e.privateGroup),
        Num(e.requiredItemLevel) or "", Num(e.duration) or "", Flag(e.newPlayerFriendly))
    listed, listKey = true, key
end

function H.LFG_LIST_ACTIVE_ENTRY_UPDATE()
    Later("listing", 1, ListingRead)
end

function H.LFG_LIST_ENTRY_EXPIRED_TIMEOUT()
    listed, listKey = false, nil
    Emit("LF", "r", "t")
end

function H.LFG_LIST_ENTRY_EXPIRED_TOO_MANY_PLAYERS()
    listed, listKey = false, nil
    Emit("LF", "r", "f")
end

Hook(LFGL, "Search", function(category, _, _, _, _, _, activityIDs)
    search = { category = Num(category), count = type(activityIDs) == "table" and #activityIDs or nil }
end)

function H.LFG_LIST_SEARCH_RESULTS_RECEIVED()
    local r = Pack(LFGL and LFGL.GetFilteredSearchResults)
    local total = r and Num(r[2])
    local shown = r and type(r[3]) == "table" and Plain(r[3]) and #r[3] or nil
    Emit("LF", "s", search and search.category or "", search and search.count or "", total or "", shown or "")
    search = nil
end

function H.LFG_LIST_SEARCH_FAILED(reason)
    Emit("LF", "f", search and search.category or "", search and search.count or "", Str(reason) or Num(reason) or "")
    search = nil
end

local lastRoles
function H.LFG_LIST_ROLE_UPDATE()
    local r = Call(LFGR and LFGR.GetRoles)
    if type(r) ~= "table" then return end
    local key = Flag(r.tank) .. Flag(r.healer) .. Flag(r.dps)
    if key == lastRoles then return end
    lastRoles = key
    Emit("LF", "o", Flag(r.tank), Flag(r.healer), Flag(r.dps))
end

function H.WHO_LIST_UPDATE()
    if not Due("who", 2) then return end
    local r = Pack(FL and FL.GetNumWhoResults)
    Emit("LF", "w", r and Num(r[2]) or "", r and Num(r[3]) or "")
end

local function Baseline(why)
    local function usable(fn)
        local r = Pack(fn)
        return r and Flag(r[2]) or ""
    end
    Emit("LF", "b", usable(LFGI and LFGI.CanPlayerUseGroupFinder), usable(LFGI and LFGI.CanPlayerUseLFD),
        usable(LFGI and LFGI.CanPlayerUsePremadeGroup), Flag(Call(LFGI and LFGI.IsGroupFinderEnabled)), why or "")
end

function H.LFG_ENABLED_STATE_CHANGED()
    Later("lfgstate", 1, function() Baseline("e") end)
end

local lastLF, lastLFAt
local function Finder(what, id)
    local now = GetTime()
    if what == lastLF and now - lastLFAt < 1 then return end
    lastLF, lastLFAt = what, now
    Emit("LF", "d", what, Num(id) or "")
end

function H.LFG_PROPOSAL_SHOW() Finder("p") end
function H.LFG_PROPOSAL_SUCCEEDED() Finder("y") end
function H.LFG_PROPOSAL_FAILED() Finder("n") end
function H.LFG_ROLE_CHECK_UPDATE() Finder("r") end
function H.LFG_READY_CHECK_UPDATE() Finder("c") end
function H.LFG_COMPLETION_REWARD() Finder("w") end
function H.LFG_OFFER_CONTINUE(_, dungeonID) Finder("o", dungeonID) end

-- Inspections ---------------------------------------------------------------------------
-- IV <name> <level> <class>: you opened another player's inspect window. class is the class
-- file. Gear scans by other addons use NotifyInspect and are not recorded.

local lastIV, lastIVAt = nil, 0

local function Inspected(unit)
    if not Plain(unit) or type(unit) ~= "string" then return end
    if not Is(UnitExists(unit)) or not Is(UnitIsPlayer(unit)) or Is(UnitIsUnit(unit, "player")) then return end
    local name = UnitKey(unit)
    if not name then return end
    -- The same player again within 5 s is the same inspect.
    local now = GetTime()
    if name == lastIV and now - lastIVAt < 5 then return end
    lastIV, lastIVAt = name, now
    local _, class = UnitClass(unit)
    local _, race = UnitRace(unit)
    Emit("IV", name, Num(UnitLevel(unit)) or "", Str(class) or "", Str(race) or "",
        Str(UnitFactionGroup(unit)) or "", Str(Call(_G.GetGuildInfo, unit)) or "")
    ns.Inspected(name, unit)
end

HookG("InspectUnit", Inspected)

-- Players met ------------------------------------------------------------------------------
-- PM <name> <classFile> <raceFile> <faction> <level> <guild>: another player you saw on your
-- target, mouseover, a nameplate or in your group. name is Name-Surname. Once per player per
-- day per character (ns.char.pm holds the day's names, at most PM_CAP, and starts over each
-- day) and at most once per session. guild is the guild's name, empty for none. Chat, whispers,
-- guids and notes are not read.
-- AL <name> <level> <classID> <raceID> <type> <time> <place> <itemID> <difficultyID> <difficultyLevel>:
-- the client's recent allies list (people you played with), read only. Each ally's latest
-- interaction: type is the client's RolodexType, time its epoch seconds, place the location
-- name. Written once per ally and again when a newer interaction appears (ns.char.al, up to
-- AL_CAP allies). The interaction description, note and guid are not read, and the request
-- function is never called.

local PM_CAP, PM_SESSION_CAP = 1500, 3000
local metSeen, metN = {}, 0
local dayText, dayAt = nil, -1000

local function Today()
    local now = GetTime()
    if not dayText or now - dayAt > 300 then
        dayText, dayAt = date("%Y%m%d"), now
    end
    return dayText
end

Met = function(unit)
    if not started or not Is(UnitIsPlayer(unit)) or Is(UnitIsUnit(unit, "player")) then return end
    local name = UnitKey(unit)
    if not name or metSeen[name] or metN >= PM_SESSION_CAP then return end
    local ch = ns.char
    if not ch then return end
    -- A unit whose data has not loaded yet has no class; it is written on a later sighting.
    local _, class = UnitClass(unit)
    if not Str(class) then return end
    metSeen[name], metN = true, metN + 1
    local day = Today()
    local pm = ch.pm
    if type(pm) ~= "table" or pm.day ~= day then
        pm = { day = day, n = 0, set = {} }
        ch.pm = pm
    end
    if pm.set[name] or pm.n >= PM_CAP then return end
    pm.set[name], pm.n = 1, pm.n + 1
    local _, race = UnitRace(unit)
    Emit("PM", name, Str(class) or "", Str(race) or "", Str(UnitFactionGroup(unit)) or "", Num(UnitLevel(unit)) or "",
        Str(Call(_G.GetGuildInfo, unit)) or "")
end

function H.PLAYER_TARGET_CHANGED() Met("target") end
function H.UPDATE_MOUSEOVER_UNIT() Met("mouseover") end
function H.NAME_PLATE_UNIT_ADDED(unit)
    if Plain(unit) and type(unit) == "string" then Met(unit) end
end

local RA = C_RecentAllies
local AL_CAP = 300
local alSession = {}

local function AlliesRead()
    local ch = ns.char
    if not RA or not ch or Call(RA.IsSystemEnabled) == false then return end
    local list = Call(RA.GetRecentAllies)
    if type(list) ~= "table" then return end
    if type(ch.al) ~= "table" then ch.al, ch.alN = {}, 0 end
    for i = 1, min(#list, AL_CAP) do
        local d = list[i]
        local cd = type(d) == "table" and Plain(d) and d.characterData
        if type(cd) == "table" and Plain(cd) then
            local name = Str(cd.fullName) or Str(cd.name)
            -- The list gives "Name Surname"; everywhere else a player is Name-Surname.
            if name then name = name:gsub("%s+", "-") end
            local inter = type(d.interactionData) == "table" and Plain(d.interactionData)
                and d.interactionData.interactions
            local last
            if name and type(inter) == "table" and Plain(inter) then
                for j = 1, min(#inter, 50) do
                    local it = inter[j]
                    local t = type(it) == "table" and Plain(it) and Num(it.timestamp)
                    if t and (not last or t > Num(last.timestamp)) then last = it end
                end
            end
            local stamp = last and Num(last.timestamp) or 0
            if name and alSession[name] ~= stamp and (ch.al[name] or -1) < stamp then
                alSession[name] = stamp
                if ch.al[name] or (ch.alN or 0) < AL_CAP then
                    if not ch.al[name] then ch.alN = (ch.alN or 0) + 1 end
                    ch.al[name] = stamp
                end
                local ctx = last and type(last.contextData) == "table" and Plain(last.contextData) and last.contextData
                    or {}
                local sd = type(d.stateData) == "table" and Plain(d.stateData) and d.stateData or {}
                Emit("AL", name, Num(cd.level) or "", Num(cd.classID) or "", Num(cd.raceID) or "",
                    last and Num(last.type) or "", stamp > 0 and stamp or "", Str(ctx.locationName) or "",
                    Num(ctx.itemID) or "", Num(ctx.activityDifficultyID) or "", Num(ctx.activityDifficultyLevel) or "",
                    Num(sd.pinExpirationDate) or "")
            end
        end
    end
end

function H.RECENT_ALLIES_DATA_READY() Later("allies", 3, AlliesRead) end
function H.RECENT_ALLIES_CACHE_UPDATE() Later("allies", 3, AlliesRead) end

-- Chat activity -------------------------------------------------------------------------
-- CT <type> <channel> <sentMessages> <sentWords> <receivedMessages> <receivedWords> <seconds>:
-- chat as counts, never the text. type: say, yell, party, raid, raidwarning, guild, officer,
-- whisper, bnwhisper, channel, instance, emote (custom /me text), textemote (the standard
-- emote messages; words are 0), community, afk and dnd (auto replies you received). channel is
-- the base name of a built-in channel (General, Trade, ...) and `custom` for any other.
-- One line per type with activity, written when a message arrives at least five minutes after
-- the last write, and when the world is left; seconds is the time the counts cover. Messages
-- you sent count as sent, everything else as received.

local CHAT = {
    ["CHAT_MSG_SAY"] = "say", ["CHAT_MSG_YELL"] = "yell", ["CHAT_MSG_PARTY"] = "party",
    ["CHAT_MSG_PARTY_LEADER"] = "party", ["CHAT_MSG_RAID"] = "raid", ["CHAT_MSG_RAID_LEADER"] = "raid",
    ["CHAT_MSG_RAID_WARNING"] = "raidwarning", ["CHAT_MSG_GUILD"] = "guild", ["CHAT_MSG_OFFICER"] = "officer",
    ["CHAT_MSG_WHISPER"] = "whisper", ["CHAT_MSG_WHISPER_INFORM"] = "whisper",
    ["CHAT_MSG_BN_WHISPER"] = "bnwhisper", ["CHAT_MSG_BN_WHISPER_INFORM"] = "bnwhisper",
    ["CHAT_MSG_CHANNEL"] = "channel", ["CHAT_MSG_INSTANCE_CHAT"] = "instance",
    ["CHAT_MSG_INSTANCE_CHAT_LEADER"] = "instance", ["CHAT_MSG_EMOTE"] = "emote",
    ["CHAT_MSG_TEXT_EMOTE"] = "textemote", ["CHAT_MSG_COMMUNITIES_CHANNEL"] = "community",
    ["CHAT_MSG_AFK"] = "afk", ["CHAT_MSG_DND"] = "dnd",
}
local SENT = { ["CHAT_MSG_WHISPER_INFORM"] = true, ["CHAT_MSG_BN_WHISPER_INFORM"] = true }

local tally, tallyStart = {}, nil
local myGUID

local function Flush()
    if not next(tally) then return end
    local now = GetTime()
    local secs = tallyStart and math.floor(now - tallyStart + 0.5) or ""
    for key, t in pairs(tally) do
        local kind, channel = key:match("^([^\t]*)\t(.*)$")
        Emit("CT", kind, channel, t[1], t[2], t[3], t[4], secs)
    end
    tally, tallyStart = {}, nil
    lastAt.CT = now
end

local function Words(text)
    if not Plain(text) or type(text) ~= "string" then return 0 end
    local n = 0
    for _ in text:gmatch("%S+") do n = n + 1 end
    return n
end

for event, kind in pairs(CHAT) do
    local sentEvent = SENT[event]
    H[event] = function(text, _, _, _, _, _, zoneChannelID, _, baseName, _, _, guid)
        local sub = ""
        if kind == "channel" then
            local zone = Num(zoneChannelID)
            sub = zone and zone > 0 and Str(baseName) or "custom"
        end
        local sent = sentEvent
        if not sent and Plain(guid) and type(guid) == "string" then
            if not myGUID then
                local g = UnitGUID("player")
                if Plain(g) then myGUID = g end
            end
            sent = guid == myGUID
        end
        local key = kind .. "\t" .. sub
        local t = tally[key]
        if not t then
            t = { 0, 0, 0, 0 }
            tally[key] = t
        end
        if not tallyStart then tallyStart = GetTime() end
        local words = kind == "textemote" and 0 or Words(text)
        if sent then
            t[1], t[2] = t[1] + 1, t[2] + words
        else
            t[3], t[4] = t[3] + 1, t[4] + words
        end
        if not lastAt.CT then lastAt.CT = tallyStart end
        if GetTime() - lastAt.CT >= 300 then Flush() end
    end
end

-- Written before ES, which Capture writes at PLAYER_LOGOUT.
function H.PLAYER_LEAVING_WORLD()
    Flush()
end

-- Duels ---------------------------------------------------------------------------------
-- DQ <kind> <who>: duel details beyond DU (the request) and DW (the result). kind: d a duel to
-- the death was requested (who is the challenger), f the duel finished, o you left the duel
-- boundary, i you came back inside it.

function H.DUEL_TO_THE_DEATH_REQUESTED(name)
    Emit("DQ", "d", Str(name) or "")
end

function H.DUEL_FINISHED() Emit("DQ", "f", "") end
function H.DUEL_OUTOFBOUNDS() Emit("DQ", "o", "") end
function H.DUEL_INBOUNDS() Emit("DQ", "i", "") end

-- The calendar --------------------------------------------------------------------------
-- CE <kind> <a> <b>: kind p the number of calendar invites waiting for you (a); a an event
-- alarm went off (a hour, b minute; the title is not kept); o you opened an event (a is the
-- client's calendar type); n you started a new event (a is 1 for a copy); i the open event's
-- invite list is complete (a is its size); g the guild's event count (a).

local lastPending, lastGuildEvents
local lastInvites  -- the invite list size last written for the open event

function H.CALENDAR_UPDATE_PENDING_INVITES()
    local n = Num(Call(CAL and CAL.GetNumPendingInvites))
    if n and n ~= lastPending then
        lastPending = n
        Emit("CE", "p", n, "")
    end
end

function H.CALENDAR_EVENT_ALARM(_, hour, minute)
    Emit("CE", "a", Num(hour) or "", Num(minute) or "")
end

function H.CALENDAR_OPEN_EVENT(calendarType)
    lastInvites = nil
    Emit("CE", "o", Str(calendarType) or "", "")
end

function H.CALENDAR_NEW_EVENT(isCopy)
    lastInvites = nil
    Emit("CE", "n", Flag(isCopy), "")
end

function H.CALENDAR_UPDATE_INVITE_LIST(hasCompleteList)
    if not Plain(hasCompleteList) or not hasCompleteList then return end
    local n = Num(Call(CAL and CAL.GetNumInvites))
    if n and n ~= lastInvites then
        lastInvites = n
        Emit("CE", "i", n, "")
    end
end

function H.CALENDAR_UPDATE_GUILD_EVENTS()
    local n = Num(Call(CAL and CAL.GetNumGuildEvents))
    if n and n ~= lastGuildEvents then
        lastGuildEvents = n
        Emit("CE", "g", n, "")
    end
end

-- Communities and the community finder ------------------------------------------------------
-- CM <kind> <clubType> <name> <a> <b>. clubType is the client's number: 0 Battle.net
-- community, 1 character community, 2 guild, 3 other. name is kept for types 1 and 2 only;
-- Battle.net community names and every member name in one are left out, and descriptions and
-- messages are never read. Kinds:
--   s a community you belong to at the start of the session (a members, b your role)
--   a you joined one (a members); x you left or were removed from one
--   k you were removed: a is the client's reason (1 banned, 2 removed, 3 community deleted)
--   i an invitation arrived (a is the inviter's name for types 1 and 2); d an invitation went
--     away, accepted or not
--   r your role changed (a is the role: 1 owner, 2 leader, 3 moderator, 4 member)
--   j a member joined (a is the name for types 1 and 2); q a member left
--   f you applied through the finder; c you cancelled an application; u your applications
--     changed (a is how many are listed); v a recruiter invited you (a is how many)
--   o you joined one while offline

local clubs = {}
local clubsLoaded, clubsBase = false, false
local memberBudget, memberWindow = 30, 0

local function ClubName(info)
    local t = type(info) == "table" and Num(info.clubType)
    if t == 1 or t == 2 then return Str(info.name) or "" end
    return ""
end

local function Remember(id, info)
    if type(info) ~= "table" or not Num(id) then return end
    clubs[id] = { type = Num(info.clubType), name = ClubName(info) }
end

local function ClubBaseline()
    if not CLUB or clubsBase then return end
    local list = Call(CLUB.GetSubscribedClubs)
    if type(list) ~= "table" then return end
    clubsBase = true
    for i = 1, min(#list, 50) do
        local info = list[i]
        local id = type(info) == "table" and Num(info.clubId)
        if id then
            Remember(id, info)
            local me = Call(CLUB.GetMemberInfoForSelf, id)
            Emit("CM", "s", Num(info.clubType) or "", ClubName(info), Num(info.memberCount) or "",
                type(me) == "table" and Num(me.role) or "")
        end
    end
    local invites = Call(CLUB.GetInvitationsForSelf)
    if type(invites) == "table" then
        for i = 1, min(#invites, 20) do
            local inv = invites[i]
            local c = type(inv) == "table" and inv.club
            if type(c) == "table" then
                local named = ClubName(c) ~= ""
                Emit("CM", "i", Num(c.clubType) or "", ClubName(c),
                    named and type(inv.inviter) == "table" and Str(inv.inviter.name) or "", "s")
            end
        end
    end
end

function H.INITIAL_CLUBS_LOADED()
    clubsLoaded = true
    Later("clubs", 3, ClubBaseline)
end

function H.CLUB_ADDED(clubId)
    local info = Call(CLUB and CLUB.GetClubInfo, clubId)
    if type(info) ~= "table" then return end
    Remember(clubId, info)
    Emit("CM", "a", Num(info.clubType) or "", ClubName(info), Num(info.memberCount) or "", "")
end

function H.CLUB_REMOVED(clubId)
    if not Num(clubId) then return end
    local c = clubs[clubId]
    clubs[clubId] = nil
    Emit("CM", "x", c and c.type or "", c and c.name or "", "", "")
end

function H.CLUB_REMOVED_MESSAGE(_, reason)
    Emit("CM", "k", "", "", Num(reason) or "", "")
end

function H.CLUB_INVITATION_ADDED_FOR_SELF(invitation)
    local c = type(invitation) == "table" and invitation.club
    if type(c) ~= "table" then return end
    local named = ClubName(c) ~= ""
    Emit("CM", "i", Num(c.clubType) or "", ClubName(c),
        named and type(invitation.inviter) == "table" and Str(invitation.inviter.name) or "", "")
end

function H.CLUB_INVITATION_REMOVED_FOR_SELF()
    Emit("CM", "d", "", "", "", "")
end

function H.CLUB_SELF_MEMBER_ROLE_UPDATED(clubId, roleId)
    if not Num(clubId) then return end
    local c = clubs[clubId]
    Emit("CM", "r", c and c.type or "", c and c.name or "", Num(roleId) or "", "")
end

-- Member joins and leaves arrive in bursts while a community loads; at most 30 a minute.
local function MemberBudget()
    local now = GetTime()
    if now - memberWindow > 60 then memberWindow, memberBudget = now, 30 end
    if memberBudget <= 0 then return false end
    memberBudget = memberBudget - 1
    return true
end

function H.CLUB_MEMBER_ADDED(clubId, memberId)
    if not clubsBase or not Num(clubId) or not MemberBudget() then return end
    local c = clubs[clubId]
    local name = ""
    if c and c.name ~= "" then
        local m = Call(CLUB and CLUB.GetMemberInfo, clubId, memberId)
        name = type(m) == "table" and Str(m.name) or ""
    end
    Emit("CM", "j", c and c.type or "", c and c.name or "", name, "")
end

function H.CLUB_MEMBER_REMOVED(clubId)
    if not clubsBase or not Num(clubId) or not MemberBudget() then return end
    local c = clubs[clubId]
    Emit("CM", "q", c and c.type or "", c and c.name or "", "", "")
end

local function FinderType(guid)
    return Num(Call(FINDER and FINDER.GetClubTypeFromFinderGUID, guid)) or ""
end

Hook(FINDER, "RequestMembershipToClub", function(guid)
    Emit("CM", "f", FinderType(guid), "", "", "")
end)

Hook(FINDER, "CancelMembershipRequest", function(guid)
    Emit("CM", "c", FinderType(guid), "", "", "")
end)

function H.CLUB_FINDER_APPLICATIONS_UPDATED(_, guids)
    if not Due("finderApps", 5) then return end
    Emit("CM", "u", "", "", type(guids) == "table" and Plain(guids) and #guids or "", "")
end

function H.CLUB_FINDER_APPLICANT_INVITE_RECIEVED(guids)
    Emit("CM", "v", "", "", type(guids) == "table" and Plain(guids) and #guids or "", "")
end

function H.CLUB_FINDER_COMMUNITY_OFFLINE_JOIN(clubId)
    local info = Call(CLUB and CLUB.GetClubInfo, clubId)
    if type(info) ~= "table" then return end
    Remember(clubId, info)
    Emit("CM", "o", Num(info.clubType) or "", ClubName(info), "", "")
end

-- Lifecycle ------------------------------------------------------------------------------

local entered = false
function H.PLAYER_ENTERING_WORLD()
    if entered then return end
    entered = true
    -- Roster, friend and guild events burst at login; the first reads wait for them to settle.
    C_Timer.After(8, function()
        started = true
        pcall(function() if GUILDI then GUILDI.GuildRoster() end end)
        GuildRead()
        FriendScan()
        GroupScan()
        AlliesRead()
        Baseline("s")
        if clubsLoaded then ClubBaseline() end
    end)
end

ns.Listen(frame, H, "Social")
