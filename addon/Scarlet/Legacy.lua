-- Legacy.lua: WoW Forever's Legacy system over time (LB, LA, LN):
--   LB  the Legacy points balance: earned, available, spent, caps, spent per tree
--   LA  the Legacy points a newly earned challenge paid
--   LN  a Legacy tree node's committed rank: a login baseline and each change
-- Codes are in docs/FORMAT.md. Event driven only, nothing on a timer; every client value
-- goes through Plain() before it is compared or used. The three Legacy trees are trait trees
-- like class talents, so every trait event is checked against the Legacy trees and configs
-- first, and a class talent change writes nothing. Nothing is kept in SavedVariables: the
-- baseline is read again each session and the last values live in this file's locals.
local _, ns = ...

local type, pcall = type, pcall
local min = math.min
local Emit, Plain, SpellName = ns.Emit, ns.Plain, ns.SpellName

local TRAITS = C_Traits
local MAJOR = C_MajorFactions

local C = _G.Constants
local L = C and C.LegacyConsts
local FACTION = L and L.LEGACY_REWARD_TRACK_FACTION_ID
local CURRENCY = L and L.LEGACY_POINTS_TRAIT_CURRENCY_ID
local TREES = L and { L.LEGACY_TREE_PROFESSIONS_ID, L.LEGACY_TREE_ADVENTURE_ID, L.LEGACY_TREE_PROGRESSION_ID }

-- Not Forever, or an API is missing: write nothing.
if not (TRAITS and MAJOR and TREES and type(FACTION) == "number" and type(CURRENCY) == "number") then return end
for i = 1, #TREES do
    if type(TREES[i]) ~= "number" then return end
end

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

local isTree = {}
for i = 1, #TREES do isTree[TREES[i]] = true end

local cfgOf = {}      -- treeID -> configID, once the client has the config
local isConfig = {}   -- configID -> true for the configs above
local treeNodes = {}  -- treeID -> nodeIDs (static)
local nodeTree = {}   -- nodeID -> treeID
local based = {}      -- treeID -> true once its baseline was read
local nBased = 0
local rank = {}       -- nodeID -> committed rank as last read
local entryOf = {}    -- nodeID -> entryID as last read (a choice node can swap entries)
local balanceKey      -- the last LB written, as one string
local paid = {}       -- achievementID -> true once LA was written

local started, queued, due = false, false, false
local tries = 0
local MAX_TRIES = 6

local function Discover(treeID)
    local cfg = Num(Call(TRAITS.GetConfigIDByTreeID, treeID))
    if not cfg then return end
    cfgOf[treeID] = cfg
    isConfig[cfg] = true
    if not treeNodes[treeID] then
        local list = Call(TRAITS.GetTreeNodes, treeID)
        if type(list) ~= "table" then return end
        local out = {}
        for i = 1, min(#list, 500) do
            local id = Num(list[i])
            if id then
                out[#out + 1] = id
                nodeTree[id] = treeID
            end
        end
        treeNodes[treeID] = out
    end
    return cfg
end

-- Balance -------------------------------------------------------------------------------
-- LB <earned> <available> <spent> <seasonalCap> <maxAvailable> <spentProfessions>
-- <spentAdventure> <spentProgression> <why>. The three trees share one currency (read
-- without staged changes, so only committed purchases count). why `s` on the first read
-- of the session, `c` when any number changed.

local function Currency(treeID)
    local cfg = cfgOf[treeID]
    if not cfg then return end
    local list = Call(TRAITS.GetTreeCurrencyInfo, cfg, treeID, true)
    if type(list) ~= "table" then return end
    for i = 1, min(#list, 8) do
        local c = list[i]
        if type(c) == "table" and Num(c.traitCurrencyID) == CURRENCY then return c end
    end
end

local function AnyTreeHasStagedPicks()
    for i = 1, #TREES do
        local cfg = cfgOf[TREES[i]]
        if cfg and Call(TRAITS.ConfigHasStagedChanges, cfg) then return true end
    end
end

local function Balance()
    if AnyTreeHasStagedPicks() then return end
    local info
    local spent = {}
    for i = 1, #TREES do
        local c = Currency(TREES[i])
        if c then
            info = info or c
            spent[i] = Num(c.spentInTree) or ""
        end
    end
    if not info then return end
    local earned = Num(Call(MAJOR.GetCurrentRenownLevel, FACTION)) or ""
    local available = Num(info.quantity) or ""
    local used = Num(info.spent) or ""
    local cap = Num(info.maxQuantity) or ""
    local max = Num(Call(TRAITS.GetMaxAvailableTraitCurrency, CURRENCY, false)) or ""
    -- The baseline waits until every tree has its currency row, so a tree that lists
    -- late is not written later as a change.
    if balanceKey == nil and (spent[1] == nil or spent[2] == nil or spent[3] == nil) and tries < MAX_TRIES then
        return
    end
    local a, b, c = spent[1] or "", spent[2] or "", spent[3] or ""
    local key = earned .. ":" .. available .. ":" .. used .. ":" .. cap .. ":" .. max .. ":" .. a .. ":" .. b .. ":" .. c
    if key == balanceKey then return end
    Emit("LB", earned, available, used, cap, max, a, b, c, balanceKey == nil and "s" or "c")
    balanceKey = key
end

-- Tree nodes ----------------------------------------------------------------------------
-- LN <treeID> <nodeID> <entryID> <rank> <oldRank> <ranksPurchased> <maxRanks> <spellID>
-- <why> <name>. rank is the node's activeRank, which the tree UI reads for a purchased
-- node. A tree with staged (unapplied) picks is not read until they are applied. why `s` baseline (nodes with a rank, oldRank
-- empty), `c` a committed change: a rank change, or a choice node swapping its entry. name is the definition's own name when it
-- has no spell. A spell name goes out as SN.

-- Returns true when the client gave this node's data. Before a config has loaded the
-- client answers with an empty node (ID not this node, rank 0), which is not a read.
local function Node(treeID, cfg, nodeID, baseline, out)
    local info = Call(TRAITS.GetNodeInfo, cfg, nodeID)
    if type(info) ~= "table" or Num(info.ID) ~= nodeID then return false end
    local now = Num(info.activeRank)
    if not now then return false end
    local entryID
    if type(info.activeEntry) == "table" then entryID = Num(info.activeEntry.entryID) end
    local old, oldEntry = rank[nodeID], entryOf[nodeID]
    rank[nodeID] = now
    if now > 0 then entryOf[nodeID] = entryID end
    if baseline then
        if now <= 0 then return true end
    elseif (old or 0) == now and (now == 0 or entryID == oldEntry) then
        return true
    end
    -- A refund has no active entry; name the one that was refunded.
    if not entryID then entryID = oldEntry end
    if not entryID and type(info.entryIDs) == "table" then entryID = Num(info.entryIDs[1]) end
    local spell, name
    if entryID then
        local entry = Call(TRAITS.GetEntryInfo, cfg, entryID)
        local definitionID = type(entry) == "table" and Num(entry.definitionID) or nil
        local def = definitionID and Call(TRAITS.GetDefinitionInfo, definitionID)
        if type(def) == "table" then
            spell = Num(def.spellID)
            if not spell then name = Str(def.overrideName) end
        end
    end
    out[#out + 1] = { spell or "", treeID, nodeID, entryID or "", now, baseline and "" or (old or 0),
        Num(info.ranksPurchased) or "", Num(info.maxRanks) or "", spell or "", baseline and "s" or "c", name or "" }
    return true
end

-- A tree counts as baselined only when every node read came back with real data; its
-- lines are held until then, so a partial pass writes nothing. A tree with staged
-- (unapplied) picks is not read: GetNodeInfo includes them (activeRank minus
-- ranksPurchased is what Forever's own talent code treats as granted), and the Apply
-- fires TRAIT_CONFIG_UPDATED, which reads it again.
local function ScanTree(treeID)
    local cfg = Discover(treeID)
    local nodes = cfg and treeNodes[treeID]
    if not nodes or #nodes == 0 then return end
    if Call(TRAITS.ConfigHasStagedChanges, cfg) then return end
    local baseline = not based[treeID]
    local failed, out = 0, {}
    for i = 1, #nodes do
        if not Node(treeID, cfg, nodes[i], baseline, out) then failed = failed + 1 end
    end
    if baseline then
        if failed > 0 then
            for i = 1, #nodes do rank[nodes[i]], entryOf[nodes[i]] = nil, nil end
            return
        end
        based[treeID] = true
        nBased = nBased + 1
    end
    for i = 1, #out do
        local row = out[i]
        if row[1] ~= "" then SpellName(row[1]) end
        Emit("LN", unpack(row, 2, 11))
    end
end

local TEXT_MAX = 300
local textedTree = {}

local function Texts(treeID, cfg)
    if textedTree[treeID] or type(TRAITS.GetTraitDescription) ~= "function" then return end
    textedTree[treeID] = true
    local rows = {}
    local nodes = treeNodes[treeID]
    for i = 1, #nodes do
        local info = Call(TRAITS.GetNodeInfo, cfg, nodes[i])
        local entries = type(info) == "table" and info.entryIDs
        local maxRanks = type(info) == "table" and Num(info.maxRanks)
        if type(entries) == "table" and maxRanks and maxRanks > 0 then
            for e = 1, min(#entries, 4) do
                local entryID = Num(entries[e])
                local entry = entryID and Call(TRAITS.GetEntryInfo, cfg, entryID)
                local definitionID = type(entry) == "table" and Num(entry.definitionID) or nil
                local def = definitionID and Call(TRAITS.GetDefinitionInfo, definitionID)
                local spell = type(def) == "table" and Num(def.spellID) or ""
                for r = 1, min(maxRanks, 10) do
                    local text = Str(Call(TRAITS.GetTraitDescription, entryID, r))
                    if text then
                        rows[#rows + 1] = { treeID, nodes[i], entryID, spell, r, maxRanks, text:sub(1, TEXT_MAX) }
                    end
                end
            end
        end
    end
    for i = 1, #rows do
        local spell = rows[i][4]
        if spell ~= "" then SpellName(spell) end
        Emit("LE", unpack(rows[i], 1, 7))
    end
end

local function Scan()
    queued = false
    if InCombatLockdown() then
        due = true
        return
    end
    due = false
    for i = 1, #TREES do
        ScanTree(TREES[i])
        if based[TREES[i]] then Texts(TREES[i], cfgOf[TREES[i]]) end
    end
    Balance()
    -- Configs can list after the first read; try again a few times until every tree
    -- has its baseline.
    if nBased < #TREES and tries < MAX_TRIES and not queued then
        tries = tries + 1
        queued = true
        C_Timer.After(5, Scan)
    end
end

-- Events before the first read (10 s after login) are covered by that read, and
-- Scan retries until every tree has its baseline.
local function Soon()
    if not started or queued then return end
    queued = true
    C_Timer.After(2, Scan)
end

function H.TRAIT_NODE_CHANGED(nodeID)
    local id = Num(nodeID)
    if id and nodeTree[id] then Soon() end
end

function H.TRAIT_CONFIG_UPDATED(configID)
    local id = Num(configID)
    if id and isConfig[id] then Soon() end
end

function H.TRAIT_TREE_CURRENCY_INFO_UPDATED(treeID)
    local id = Num(treeID)
    if id and isTree[id] then Soon() end
end

-- The configs are not there at login until the client lists them; read again then.
function H.TRAIT_CONFIG_LIST_UPDATED()
    if nBased < #TREES then Soon() end
end

function H.MAJOR_FACTION_RENOWN_LEVEL_CHANGED(id)
    if Num(id) == FACTION then Soon() end
end

-- Challenges ----------------------------------------------------------------------------
-- LA <achievementID> <points>: the Legacy points a newly earned achievement pays. The
-- client re-announces old earns (alreadyEarned) on some logins; those write nothing, and
-- an achievement that pays nothing is not a Legacy Challenge.

function H.ACHIEVEMENT_EARNED(id, already)
    if Plain(already) and already then return end
    local aid = Num(id)
    if not aid or paid[aid] then return end
    local points = Num(Call(TRAITS.GetTraitCurrencyForAchievement, CURRENCY, aid))
    if not points or points <= 0 then return end
    paid[aid] = true
    Emit("LA", aid, points)
    Soon()
end

-- Lifecycle -----------------------------------------------------------------------------

function H.PLAYER_REGEN_ENABLED()
    if due then Soon() end
end

local entered = false
function H.PLAYER_ENTERING_WORLD()
    if entered then return end
    entered = true
    C_Timer.After(10, function()
        started = true
        Scan()
    end)
end

ns.Listen(frame, H, "Legacy")
