-- Loot.lua: loot rules and who got what in a group, beyond Capture's O, LO and GM and Economy's RW:
--   LM  the loot rule changed: method, threshold, master looter, group size
--   LT  another group member received an item
--   LD  a group roll on an item: someone's roll, choice or pass, the winner, or everyone passing
--   IQ  an item's quality, once per session per item
-- Codes are in docs/FORMAT.md. Event driven only, nothing on a timer except one 5 second wait
-- for the session baseline (the client reports the group a few seconds after login). Every
-- client value goes through Plain() before it is compared or indexed. Chat text is parsed into
-- fields with the client's own format strings and is never stored. Your own receipts (O) and
-- rolls (RL, RW) stay with Capture, Track and Economy; this file writes only other players'.
local _, ns = ...

local type, pcall, pairs, ipairs, tonumber, tostring = type, pcall, pairs, ipairs, tonumber, tostring
local Emit, Plain, ItemName = ns.Emit, ns.Plain, ns.ItemName

local frame = CreateFrame("Frame")
local H = {}

local function Str(v)
    if Plain(v) and type(v) == "string" and v ~= "" then return v end
end

local function Num(v)
    if Plain(v) and type(v) == "number" then return v end
end

-- First return value of fn(...), or nil when it errors or comes back secret.
local function Call(fn, ...)
    if type(fn) ~= "function" then return end
    local ok, v = pcall(fn, ...)
    if ok and Plain(v) then return v end
end

-- Every return value of fn(...) in a table, shifted by one: r[1] is pcall's flag.
-- Index it only through Str and Num.
local function Pack(fn, ...)
    if type(fn) ~= "function" then return end
    local r = { pcall(fn, ...) }
    if r[1] then return r end
end

-- Players ------------------------------------------------------------------------------
-- A member's key is the one Capture writes in GM lines: UnitName, with "-" and the realm
-- when there is one. Names in chat and in the roll history are mapped onto those keys. A
-- name is never split on "-" ("The-Lich" is a character).

local roster = {}

local function UnitKey(unit)
    local name, realm = UnitName(unit)
    if Plain(name) and type(name) == "string" and name ~= "" and name ~= UNKNOWNOBJECT then
        if Plain(realm) and type(realm) == "string" and realm ~= "" then name = name .. "-" .. realm end
        return name
    end
end

local function SelfUnit(unit)
    return Call(UnitIsUnit, unit, "player") == true
end

local function ReadRoster()
    for key in pairs(roster) do roster[key] = nil end
    local raid, n = IsInRaid(), GetNumGroupMembers()
    if not Plain(raid) or not Plain(n) then return end
    for i = 1, raid and n or n - 1 do
        local unit = raid and ("raid" .. i) or ("party" .. i)
        if not SelfUnit(unit) then
            local key = UnitKey(unit)
            if key then roster[key] = true end
        end
    end
end

-- The roster key for a name from chat or the roll history: the name itself when it is a
-- key, else the one key that starts with "<name>-", else the name as it came.
local function Clean(name)
    -- Forever's loot messages show "Name Surname"; characters are keyed Name-Surname.
    return (name:match("^%s*(.-)%s*$"):gsub("%s+", "-"))
end

function ns.RosterKey(name)
    if not Str(name) then return end
    name = Clean(name)
    if roster[name] then return name end
    local prefix, hit = name .. "-", nil
    for key in pairs(roster) do
        if key:sub(1, #prefix) == prefix then
            if hit then return nil end
            hit = key
        end
    end
    return hit
end

function ns.SenderKey(sender)
    if not Str(sender) then return end
    local key = ns.RosterKey(sender)
    if key then return key end
    local base = Clean(sender):match("^(.+)%-[^-]+$")
    if base and roster[base] then return base end
end

local function Resolve(name)
    if not Str(name) then return end
    return ns.RosterKey(name) or Clean(name)
end

local function IsSelf(who)
    return who == ns.charKey or who == UnitName("player")
end

-- The loot rule ------------------------------------------------------------------------
-- LM <method> <threshold> <master> <size> <why>. method is `solo` when you are not in a
-- group, else the client's loot method in lower case (`group`, `needbeforegreed`,
-- `masterlooter`, `freeforall`, `roundrobin`, `personal`). threshold is the item quality from
-- which the rule applies (2 uncommon, 3 rare, ...). master is the master looter's
-- Name-Surname for `masterlooter`, else empty. size is the group size (1 solo). why: `s` the
-- baseline 5 seconds into the session, `c` a change. Written only when a value differs from
-- the last LM line.

local METHODS = {}
for name, value in pairs(Enum and Enum.LootMethod or {}) do METHODS[value] = name:lower() end

local function MasterKey(partyID, raidID)
    local unit
    if Num(partyID) then
        unit = partyID == 0 and "player" or ("party" .. partyID)
    elseif Num(raidID) and raidID > 0 then
        unit = "raid" .. raidID
    end
    if not unit then return "" end
    if SelfUnit(unit) then return ns.charKey or "" end
    return UnitKey(unit) or ""
end

local function ReadRule()
    local grouped = IsInGroup()
    if not Plain(grouped) then return end
    if not grouped then return "solo", "", "", 1 end
    local size = Num(GetNumGroupMembers()) or ""
    local r = Pack(C_PartyInfo and C_PartyInfo.GetLootMethod or _G.GetLootMethod)
    if not r then return "unknown", "", "", size end
    -- Retail returns the LootMethod enum, a classic client returns its name.
    local m = r[2]
    local method = (Num(m) and (METHODS[m] or tostring(m))) or (Str(m) and m:lower()) or "unknown"
    local master = ""
    if method == "masterlooter" or method == "master" then master = MasterKey(r[3], r[4]) end
    return method, Num(Call(_G.GetLootThreshold)) or "", master, size
end

local seen, lastRule = false, nil

local function Rule(why)
    local method, threshold, master, size = ReadRule()
    if not method then return end
    local key = method .. ":" .. threshold .. ":" .. master .. ":" .. size
    if key == lastRule then return end
    lastRule = key
    Emit("LM", method, threshold, master, size, why)
end

function H.PARTY_LOOT_METHOD_CHANGED()
    ReadRoster()
    if seen then Rule("c") end
end

function H.GROUP_ROSTER_UPDATE()
    ReadRoster()
    if seen then Rule("c") end
end

-- Quality ------------------------------------------------------------------------------
-- IQ <itemID> <quality>: the client's item quality (0 poor, 1 common, 2 uncommon, 3 rare,
-- 4 epic, 5 legendary), once per session per item, for the items other players' LT and LD
-- lines and your own loot messages name. O lines carry no quality; the companion joins it
-- by itemID.

local HEX_QUALITY = {
    ["9d9d9d"] = 0, ["ffffff"] = 1, ["1eff00"] = 2, ["0070dd"] = 3, ["a335ee"] = 4,
    ["ff8000"] = 5, ["e6cc80"] = 6,
}

local function LinkQuality(link)
    local q = link:match("|cnIQ(%d+):")
    if q then return tonumber(q) end
    local hex = link:match("|cff(%x%x%x%x%x%x)")
    return hex and HEX_QUALITY[hex:lower()] or nil
end

local qualityDone = {}

local function Quality(id, link)
    if qualityDone[id] then return end
    local q = Num(Call(C_Item and C_Item.GetItemQualityByID, id))
    if not q and Str(link) then q = LinkQuality(link) end
    if not q then return end
    qualityDone[id] = true
    Emit("IQ", id, q)
end

-- Loot messages ------------------------------------------------------------------------
-- The client's format strings (GlobalStrings) become Lua patterns here, so this works in
-- every language and Scarlet never stores a message. A string the client does not have is
-- skipped. Specific forms come before general ones: the "multiple" forms before the single
-- ones, and your own ("You won: ...") before the third person ("%s won: ...").
--
-- LT <kind> <who> <itemID> <quantity>: another member received an item. kind: `l` looted
--    (by the rule, a roll win or a master looter's pick), `p` was handed it (an item the
--    client pushed to them).
-- LD <kind> <who> <itemID> <rollType> <roll> <src>: a group roll. kind: `r` rolled (roll is
--    the number), `s` chose without a number yet, `p` passed, `w` won, `a` everyone passed
--    (who empty). rollType is the client's LootRollType (0 pass, 1 need, 2 greed,
--    3 disenchant, 4 transmog), empty when the message does not say. src: `c` from the
--    chat roll messages, `h` from the client's roll history. Your own rolls are RL and RW.

local SPECS = {
    { "LOOT_ITEM_SELF_MULTIPLE", "self", { "item", "count" } },
    { "LOOT_ITEM_SELF", "self", { "item" } },
    { "LOOT_ITEM_PUSHED_SELF_MULTIPLE", "self", { "item", "count" } },
    { "LOOT_ITEM_PUSHED_SELF", "self", { "item" } },
    { "LOOT_ROLL_YOU_WON", "self", { "item" } },
    { "LOOT_ROLL_PASSED_SELF", "self", { "item" } },
    { "LOOT_ROLL_PASSED_SELF_AUTO", "self", { "item" } },
    { "LOOT_ROLL_NEED_SELF", "self", { "item" } },
    { "LOOT_ROLL_GREED_SELF", "self", { "item" } },
    { "LOOT_ROLL_DISENCHANT_SELF", "self", { "item" } },
    { "LOOT_ROLL_TRANSMOG_SELF", "self", { "item" } },
    { "LOOT_ITEM_MULTIPLE", "l", { "who", "item", "count" } },
    { "LOOT_ITEM", "l", { "who", "item" } },
    { "LOOT_ITEM_PUSHED_MULTIPLE", "p", { "who", "item", "count" } },
    { "LOOT_ITEM_PUSHED", "p", { "who", "item" } },
    { "LOOT_ROLL_ROLLED_NEED", "r", { "roll", "item", "who" }, 1 },
    { "LOOT_ROLL_ROLLED_GREED", "r", { "roll", "item", "who" }, 2 },
    { "LOOT_ROLL_ROLLED_DE", "r", { "roll", "item", "who" }, 3 },
    { "LOOT_ROLL_ROLLED_TRANSMOG", "r", { "roll", "item", "who" }, 4 },
    { "LOOT_ROLL_NEED", "s", { "who", "item" }, 1 },
    { "LOOT_ROLL_GREED", "s", { "who", "item" }, 2 },
    { "LOOT_ROLL_DISENCHANT", "s", { "who", "item" }, 3 },
    { "LOOT_ROLL_TRANSMOG", "s", { "who", "item" }, 4 },
    -- The general "%s passed on: %s" matches these too, so they come first.
    { "LOOT_ROLL_ALL_PASSED", "a", { "item" } },
    { "LOOT_ROLL_PASSED_AUTO", "p", { "who", "item" }, 0 },
    { "LOOT_ROLL_PASSED_AUTO_FEMALE", "p", { "who", "item" }, 0 },
    { "LOOT_ROLL_PASSED", "p", { "who", "item" }, 0 },
    { "LOOT_ROLL_WON_NO_SPAM_NEED", "w", { "who", "roll", "item" }, 1 },
    { "LOOT_ROLL_WON_NO_SPAM_GREED", "w", { "who", "roll", "item" }, 2 },
    { "LOOT_ROLL_WON_NO_SPAM_DE", "w", { "who", "roll", "item" }, 3 },
    { "LOOT_ROLL_WON", "w", { "who", "item" } },
}

-- A format string as a pattern. order[i] is the argument position the i-th capture holds,
-- which differs from i in positional formats ("%1$s won: %3$s (Need - %2$d)").
local function Build(key)
    local fmt = _G[key]
    if type(fmt) ~= "string" or fmt == "" then return end
    local order, n = {}, 0
    local marked = fmt:gsub("%%(%d*)%$?([sd])", function(pos, kind)
        n = n + 1
        order[n] = tonumber(pos) or n
        return "\1" .. kind .. "\2"
    end)
    if n == 0 then return end
    marked = marked:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
    marked = marked:gsub("\1s\2", "(.-)"):gsub("\1d\2", "(%%d+)")
    return "^" .. marked .. "$", order
end

local COMPILED = {}
for _, spec in ipairs(SPECS) do
    local pattern, order = Build(spec[1])
    if pattern then
        COMPILED[#COMPILED + 1] = { pattern = pattern, order = order, kind = spec[2], roles = spec[3], rtype = spec[4] }
    end
end

local function Parse(text)
    for i = 1, #COMPILED do
        local c = COMPILED[i]
        local caps = { text:match(c.pattern) }
        if caps[1] ~= nil then
            local v = {}
            for j = 1, #caps do
                local role = c.roles[c.order[j]]
                if role then v[role] = caps[j] end
            end
            return c, v
        end
    end
end

local function ItemID(link)
    link = Str(link)
    return link and tonumber(link:match("item:(%d+)")) or nil
end

function H.CHAT_MSG_LOOT(text)
    if not Plain(text) or type(text) ~= "string" or #text > 600 then return end
    local c, v = Parse(text)
    if not c then return end
    local id = ItemID(v.item)
    if not id then return end
    Quality(id, v.item)
    if c.kind == "self" then return end
    local who = ""
    if c.kind ~= "a" then
        who = Resolve(v.who)
        if not who or IsSelf(who) then return end
    end
    ItemName(id)
    local kind = c.kind
    if kind == "l" or kind == "p" then
        Emit("LT", kind, who, id, tonumber(v.count) or 1)
    else
        Emit("LD", kind, who, id, c.rtype or "", tonumber(v.roll) or "", "c")
    end
end

-- Roll history -------------------------------------------------------------------------
-- LOOT_HISTORY_UPDATE_DROP fires as each roll comes in. A drop is written once, when it has
-- a winner or everyone passed: one LD line per other player's roll or pass, then the winner
-- (unless you won it, which is RW w) or `a`. EncounterLootDropRollState -> LootRollType:
-- need main and off spec 1, transmog 4, greed 2, pass 0; "no roll" is not written.

local ROLL_OF = { [0] = 1, [1] = 1, [2] = 4, [3] = 2 }
local settled, settledCount = {}, 0

function H.LOOT_HISTORY_UPDATE_DROP(encounterID, lootListKey)
    local LH = C_LootHistory
    if not LH or not Num(encounterID) or not Num(lootListKey) then return end
    local key = encounterID .. ":" .. lootListKey
    if settled[key] then return end
    local drop = Call(LH.GetSortedInfoForDrop, encounterID, lootListKey)
    if type(drop) ~= "table" then return end
    local winner = type(drop.winner) == "table" and drop.winner or nil
    local allPassed = Plain(drop.allPassed) and drop.allPassed == true
    if not winner and not allPassed then return end
    if settledCount > 200 then settled, settledCount = {}, 0 end
    settled[key], settledCount = true, settledCount + 1
    local id = ItemID(drop.itemHyperlink)
    if not id then return end
    ItemName(id)
    Quality(id, drop.itemHyperlink)
    if type(drop.rollInfos) == "table" then
        for _, r in ipairs(drop.rollInfos) do
            if type(r) == "table" and not (Plain(r.isSelf) and r.isSelf) then
                local who, state = Resolve(r.playerName), Num(r.state)
                if who and state == 5 then
                    Emit("LD", "p", who, id, 0, "", "h")
                elseif who and ROLL_OF[state] then
                    Emit("LD", "r", who, id, ROLL_OF[state], Num(r.roll) or "", "h")
                end
            end
        end
    end
    if winner and not (Plain(winner.isSelf) and winner.isSelf) then
        local who = Resolve(winner.playerName)
        if who then Emit("LD", "w", who, id, ROLL_OF[Num(winner.state)] or "", Num(winner.roll) or "", "h") end
    elseif allPassed then
        Emit("LD", "a", "", id, "", "", "h")
    end
end

-- API probe ----------------------------------------------------------------------------
-- PR <name> <1 or 0>, once per client build and day, for the APIs and the client format
-- strings this file reads, so a missing one is visible in the data.

local PROBE = { "C_PartyInfo", "GetLootMethod", "GetLootThreshold", "C_LootHistory", "C_Item" }
for _, spec in ipairs(SPECS) do PROBE[#PROBE + 1] = spec[1] end

local function Probe()
    local db = ns.db
    local key = tostring(select(2, GetBuildInfo())) .. ":" .. date("%Y%m%d")
    if not db or db.probedLoot == key then return end
    db.probedLoot = key
    for i = 1, #PROBE do
        Emit("PR", PROBE[i], _G[PROBE[i]] ~= nil and 1 or 0)
    end
end

-- Lifecycle ----------------------------------------------------------------------------
-- The client reports the group a few seconds after login, so the first rule is read 5
-- seconds in. PLAYER_ENTERING_WORLD fires at every loading screen and re-reads it.

function H.PLAYER_ENTERING_WORLD()
    ReadRoster()
    if seen then
        Rule("c")
        return
    end
    Probe()
    C_Timer.After(5, function()
        if seen then return end
        seen = true
        ReadRoster()
        Rule("s")
    end)
end

ns.Listen(frame, H, "Loot")
