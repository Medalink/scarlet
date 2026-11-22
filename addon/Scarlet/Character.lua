-- Character.lua: the character itself over time, beyond Capture, Track and Metrics (L, X, RX, G, SC, SL, LP, GR):
--   TG  the active talent group, spec and points spent per talent tab
--   TA  a talent node's committed rank: a baseline per talent group and each change
--   TY  a talent tab's name, once per session
--   TQ  a respec offered, or talents or spec changed by the client
--   TI  the title shown with the name
--   EQ  equipment sets: seen, changed, removed, swapped to
--   PD  the pet's level, loyalty, happiness and training points
--   XD  whether experience gain is turned off
--   BA  a barber shop change applied
--   GA  the active game mode
--   RU  every signal that might name the ruleset, read together
--   CD  sex, class and race ids, effective level
--   SX  more character numbers: defense, penetration, weapon damage, item levels
-- Codes are in docs/FORMAT.md. Event driven only, nothing on a timer; every client value
-- goes through Plain() before it is compared or used. Each state is read once 10 seconds
-- after login and written on change. Nothing is kept in SavedVariables: the last values live
-- in this file's locals, so every session starts with a baseline. Reads that can be secret
-- in combat wait for the fight to end. No other player's data, no inspect.
local _, ns = ...

local type, pcall, pairs, ipairs, unpack = type, pcall, pairs, ipairs, unpack
local floor, min = math.floor, math.min
local concat = table.concat
local Emit, Plain, SpellName = ns.Emit, ns.Plain, ns.SpellName

local SPEC = C_SpecializationInfo
local TRAITS = C_Traits
local CT = C_ClassTalents
local EQS = C_EquipmentSet
local RULES = C_GameRules
local PVP = C_PvP
local PLAYERINFO = C_PlayerInfo
local PETINFO = C_PetInfo
local BARBER = C_BarberShop
local PAPER = C_PaperDollInfo

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

-- Rounded to two places, so a float that did not change does not look changed.
local function R2(v)
    v = Num(v)
    if not v then return end
    if v == floor(v) then return v end
    return floor(v * 100 + 0.5) / 100
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

-- The nth return value of fn(...) as a number.
local function NthNum(n, fn, ...)
    local r = Pack(fn, ...)
    return r and Num(r[n + 1])
end

-- Talents ---------------------------------------------------------------------------------
-- Forever's talent window (Blizzard_PlayerSpells, Camelot files) keeps one class tree per spec
-- group, a trait config read by C_Traits like the Legacy trees, with the talent tabs as
-- trait node groups and no PvP or hero talents. Two spec groups exist once dual spec is
-- unlocked.
-- TG <why> <group> <groups> <specID> <spec> <treeID> <tabs> <classPoints> <specPoints> <configID> <loadout>:
-- the active talent group (1 or 2) and how many exist; specID and spec the name from the spec
-- list (empty when the client has no spec selection); tabs is `groupID:spent:available` per
-- talent tab, comma-joined, from the client's group currency; the two unspent counts come from
-- HasUnspentTalentPoints. loadout is the client's loadout export string for the config
-- (C_Traits.GenerateImportString), read only with no picks staged; empty where the client gives none. why: `s` the first read of the session, `w` the active group changed,
-- `r` the client reset or changed it, `c` anything else. Written when a value differs from the
-- last TG of the session.
-- TA <group> <nodeID> <entryID> <rank> <oldRank> <maxRanks> <spellID> <tab> <why>: a node's
-- committed rank in that group's config (activeRank; a tree with staged picks is not read
-- until they are applied). why `s` is a baseline of every node with a rank, the first time
-- the group is read in the session (oldRank empty), `c` a change: a rank change, or a choice
-- node swapping its entry. tab is the node's talent tab. A spell name goes out as SN.
-- TY <groupID> <name> names a talent tab once per session.
-- TQ <kind> <a> <b>: `p` a respec was offered (cost in copper, the client's respec type),
-- `r` the client reset talents (a is `1` for a pet's), `i` it changed the spec (a is `1` for
-- a pet's).

local LEGACY = _G.Constants and _G.Constants.LegacyConsts
local isLegacy = {}
if LEGACY then
    for _, id in ipairs({ LEGACY.LEGACY_TREE_PROFESSIONS_ID, LEGACY.LEGACY_TREE_ADVENTURE_ID,
        LEGACY.LEGACY_TREE_PROGRESSION_ID }) do
        if type(id) == "number" then isLegacy[id] = true end
    end
end

local MAX_TRIES = 6
local tal = { started = false, queued = false, due = false, tries = 0, why = nil, tree = nil }
local based = {}      -- group -> true once its nodes were baselined
local rank = {}       -- "group:nodeID" -> committed rank as last read
local entryOf = {}    -- "group:nodeID" -> entryID as last read
local treeNodes = {}  -- treeID -> nodeIDs (static)
local nodeTree = {}   -- nodeID -> treeID
local cfgs = {}       -- configID -> true for the configs read
local tabNamed = {}
local tabSet = {}
local laidOut = {}
local tgKey
local WHY_RANK = { c = 1, w = 2, r = 3 }

---@type fun(why: string)
local SxDirty -- set below, once the extra stats exist

local function ActiveGroup()
    return SPEC and Num(Call(SPEC.GetActiveSpecGroup))
end

local function ConfigFor(group)
    local cfg = Num(Call(SPEC.GetCombatConfigIDForSpecGroup, group))
    if not cfg and CT then cfg = Num(Call(CT.GetActiveConfigID)) end
    return cfg
end

-- The spec's id and name; only where Forever's own character panel shows one.
local function CurrentSpec()
    local classID = Num(select(3, UnitClass("player")))
    if not classID or not Call(SPEC.IsSpecSelectionEnabled, classID) then return end
    local index = Num(Call(SPEC.GetSpecialization))
    if not index or index <= 0 then return end
    local r = Pack(SPEC.GetSpecializationInfo, index)
    if not r then return end
    -- The docs default specID to 0, which is no spec (and no spec name).
    local id = Num(r[2])
    if not id or id <= 0 then return end
    return id, Str(r[3])
end

local function TreeFor(cfg, specID)
    local tree = specID and CT and Num(Call(CT.GetTraitTreeForSpec, specID))
    if not tree then
        local info = Call(TRAITS.GetConfigInfo, cfg)
        if type(info) == "table" and type(info.treeIDs) == "table" then tree = Num(info.treeIDs[1]) end
    end
    if tree and not isLegacy[tree] then return tree end
end

local function Nodes(tree)
    if treeNodes[tree] then return treeNodes[tree] end
    local list = Call(TRAITS.GetTreeNodes, tree)
    if type(list) ~= "table" then return end
    local out = {}
    for i = 1, min(#list, 600) do
        local id = Num(list[i])
        if id then
            out[#out + 1] = id
            nodeTree[id] = tree
        end
    end
    treeNodes[tree] = out
    return out
end

-- "groupID:spent:available" for each talent tab of the tree.
local function Tabs(tree, cfg)
    local displays = Call(TRAITS.GetGroupDisplayInfoByTreeID, tree)
    if type(displays) ~= "table" then return "" end
    local ids = {}
    local shown = tabSet[tree] or {}
    tabSet[tree] = shown
    for i = 1, min(#displays, 10) do
        local d = displays[i]
        local gid = type(d) == "table" and Num(d.groupID)
        if gid then
            ids[#ids + 1] = gid
            shown[gid] = true
            if not tabNamed[gid] and Str(d.displayName) then
                tabNamed[gid] = true
                Emit("TY", gid, d.displayName)
            end
        end
    end
    local infos = #ids > 0 and Call(TRAITS.GetGroupCurrencyInfo, cfg, ids)
    local out = {}
    for i = 1, #ids do
        local spent, avail = "", ""
        if type(infos) == "table" then
            for j = 1, min(#infos, 10) do
                local gi = infos[j]
                if type(gi) == "table" and Num(gi.traitNodeGroupID) == ids[i] and type(gi.currencyInfos) == "table" then
                    local c = gi.currencyInfos[1]
                    if type(c) == "table" then spent, avail = Num(c.spent) or "", Num(c.quantity) or "" end
                end
            end
        end
        out[#out + 1] = ids[i] .. ":" .. spent .. ":" .. avail
    end
    return concat(out, ",")
end

local function Summary(group, cfg, specID, specName, tree, tabs)
    local groups = Num(Call(_G.GetNumSpecGroups)) or ""
    tabs = tabs or Tabs(tree, cfg)
    local u = CT and Pack(CT.HasUnspentTalentPoints)
    local classPoints, specPoints = u and Num(u[3]) or "", u and Num(u[4]) or ""
    local loadout = Str(Call(TRAITS.GenerateImportString, cfg)) or ""
    local key = concat({ group, groups, specID or "", specName or "", tree, tabs, classPoints, specPoints, cfg, loadout }, "|")
    if key == tgKey then return end
    local why = tgKey == nil and "s" or tal.why or "c"
    tgKey = key
    Emit("TG", why, group, groups, specID or "", specName or "", tree, tabs, classPoints, specPoints, cfg, loadout)
end

local function TabOf(tree, info)
    local shown = tabSet[tree]
    if not shown or type(info.groupIDs) ~= "table" then return "" end
    for i = 1, min(#info.groupIDs, 10) do
        local gid = Num(info.groupIDs[i])
        if gid and shown[gid] then return gid end
    end
    return ""
end

local function EntrySpell(cfg, entryID)
    local entry = Call(TRAITS.GetEntryInfo, cfg, entryID)
    if type(entry) ~= "table" then return end
    local definitionID = Num(entry.definitionID)
    local def = definitionID and Call(TRAITS.GetDefinitionInfo, definitionID)
    return type(def) == "table" and Num(def.spellID) or nil, Num(entry.maxRanks)
end

-- Returns true when the client gave this node's data. Before a config has loaded the
-- client answers with an empty node (ID not this node, rank 0), which is not a read.
local function Node(group, cfg, nodeID, baseline, out)
    local info = Call(TRAITS.GetNodeInfo, cfg, nodeID)
    if type(info) ~= "table" or Num(info.ID) ~= nodeID then return false end
    local now = Num(info.activeRank)
    if not now then return false end
    local entryID
    if type(info.activeEntry) == "table" then entryID = Num(info.activeEntry.entryID) end
    local key = group .. ":" .. nodeID
    local old, oldEntry = rank[key], entryOf[key]
    rank[key] = now
    if now > 0 then entryOf[key] = entryID end
    if baseline then
        if now <= 0 then return true end
    elseif (old or 0) == now and (now == 0 or entryID == oldEntry) then
        return true
    end
    -- A refund has no active entry; name the one that was refunded.
    if not entryID then entryID = oldEntry end
    if not entryID and type(info.entryIDs) == "table" then entryID = Num(info.entryIDs[1]) end
    local spell = entryID and EntrySpell(cfg, entryID)
    out[#out + 1] = { spell or "", group, nodeID, entryID or "", now, baseline and "" or (old or 0),
        Num(info.maxRanks) or "", spell or "", TabOf(nodeTree[nodeID], info), baseline and "s" or "c" }
    return true
end

-- A group counts as baselined only when every node read came back with real data; its
-- lines are held until then, so a partial pass writes nothing. Returns false when the
-- read has to be tried again; a second true when the tree has staged picks.
local function ScanNodes(group, cfg, tree)
    local nodes = Nodes(tree)
    if not nodes or #nodes == 0 then return false end
    -- GetNodeInfo includes unapplied picks; the apply fires TRAIT_CONFIG_UPDATED, which reads again.
    if Call(TRAITS.ConfigHasStagedChanges, cfg) then return true, true end
    local baseline = not based[group]
    local failed, out = 0, {}
    for i = 1, #nodes do
        if not Node(group, cfg, nodes[i], baseline, out) then failed = failed + 1 end
    end
    if baseline then
        if failed > 0 then
            for i = 1, #nodes do
                local key = group .. ":" .. nodes[i]
                rank[key], entryOf[key] = nil, nil
            end
            return false
        end
        based[group] = true
    end
    for i = 1, #out do
        local row = out[i]
        if row[1] ~= "" then SpellName(row[1]) end
        Emit("TA", unpack(row, 2, 10))
    end
    return true
end

local MAX_ENTRIES, MAX_EDGES = 6, 12

local function LayoutFields(cfg, tree, nodeID)
    local info = Call(TRAITS.GetNodeInfo, cfg, nodeID)
    if type(info) ~= "table" or Num(info.ID) ~= nodeID then return false end
    local shown = Flag(info.isVisible)
    if shown == "" then return false end
    if shown == 0 then return end
    local posX, posY = Num(info.posX), Num(info.posY)
    if not (posX and posY) then return false end
    local entries, edges = {}, {}
    local ids = type(info.entryIDs) == "table" and info.entryIDs or {}
    for i = 1, min(#ids, MAX_ENTRIES) do
        local entryID = Num(ids[i])
        if entryID then
            local spell, maxRanks = EntrySpell(cfg, entryID)
            if spell then SpellName(spell) end
            entries[#entries + 1] = entryID .. ":" .. (spell or "") .. ":" .. (maxRanks or "")
        end
    end
    local visible = type(info.visibleEdges) == "table" and info.visibleEdges or {}
    for i = 1, min(#visible, MAX_EDGES) do
        local edge = visible[i]
        local target = type(edge) == "table" and Num(edge.targetNode)
        if target then edges[#edges + 1] = target .. ":" .. (Num(edge.type) or "") end
    end
    return { tree, nodeID, posX, posY, Num(info.type) or "", Num(info.maxRanks) or "",
        TabOf(tree, info), concat(entries, ","), concat(edges, ",") }
end

local function LayoutHash(rows)
    local h = 5381
    for i = 1, #rows do
        local s = concat(rows[i], "|")
        for j = 1, #s do h = (h * 33 + s:byte(j)) % 4294967296 end
    end
    return ("%08x"):format(h)
end

local function Layout(cfg, tree)
    if laidOut[tree] then return end
    local nodes = Nodes(tree)
    if not nodes or #nodes == 0 then return end
    local rows = {}
    for i = 1, #nodes do
        local fields = LayoutFields(cfg, tree, nodes[i])
        if fields == false then return end
        rows[#rows + 1] = fields
    end
    laidOut[tree] = true
    local classID = Num(select(3, UnitClass("player"))) or ""
    Emit("TV", tree, classID, #rows, LayoutHash(rows))
    for i = 1, #rows do Emit("TD", unpack(rows[i], 1, 9)) end
end

local TalentScan

local function Retry()
    if tal.tries < MAX_TRIES and not tal.queued then
        tal.tries = tal.tries + 1
        tal.queued = true
        C_Timer.After(5, TalentScan)
    end
end

TalentScan = function()
    tal.queued = false
    if not (SPEC and TRAITS) then return end
    if InCombatLockdown() then
        tal.due = true
        return
    end
    tal.due = false
    if Call(SPEC.IsInitialized) == false then return Retry() end
    local group = ActiveGroup()
    local cfg = group and ConfigFor(group)
    if not cfg then return Retry() end
    cfgs[cfg] = true
    local specID, specName = CurrentSpec()
    local tree = TreeFor(cfg, specID)
    if not tree then return Retry() end
    tal.tree = tree
    -- Tab names (TY) go out before the first TA line that uses them.
    local tabs = Tabs(tree, cfg)
    local ok, staged = ScanNodes(group, cfg, tree)
    -- Group currency has no exclude-staged read, so with picks staged nothing is
    -- written; the Apply's TRAIT_CONFIG_UPDATED reads again and keeps tal.why.
    if staged then
        tal.tries = 0
        return
    end
    Summary(group, cfg, specID, specName, tree, tabs)
    tal.why = nil
    if ok then Layout(cfg, tree) end
    if ok and laidOut[tree] then tal.tries = 0 else Retry() end
end

local function TalentSoon(why)
    SxDirty("t")
    if why and (not tal.why or WHY_RANK[why] > WHY_RANK[tal.why]) then tal.why = why end
    if not tal.started or tal.queued then return end
    tal.queued = true
    C_Timer.After(2, TalentScan)
end

function H.ACTIVE_TALENT_GROUP_CHANGED() TalentSoon("w") end
function H.ACTIVE_COMBAT_CONFIG_CHANGED() TalentSoon("w") end
function H.PLAYER_TALENT_UPDATE() TalentSoon() end
function H.CHARACTER_POINTS_CHANGED() TalentSoon() end
function H.PLAYER_SPECIALIZATION_CHANGED() TalentSoon() end
function H.ACTIVE_PLAYER_SPECIALIZATION_CHANGED() TalentSoon() end

function H.TRAIT_CONFIG_UPDATED(configID)
    local id = Num(configID)
    if id and (cfgs[id] or next(cfgs) == nil) then TalentSoon() end
end

function H.TRAIT_NODE_CHANGED(nodeID)
    local id = Num(nodeID)
    if id and nodeTree[id] then TalentSoon() end
end

function H.TRAIT_TREE_CURRENCY_INFO_UPDATED(treeID)
    local id = Num(treeID)
    if id and id == tal.tree then TalentSoon() end
end

-- The configs are not there at login until the client lists them; read again then.
function H.TRAIT_CONFIG_LIST_UPDATED()
    if tgKey == nil then TalentSoon() end
end

function H.CONFIRM_TALENT_WIPE(cost, respecType)
    Emit("TQ", "p", Num(cost) or "", Num(respecType) or "")
end

function H.TALENTS_INVOLUNTARILY_RESET(isPet)
    Emit("TQ", "r", Flag(isPet))
    TalentSoon("r")
end

function H.SPEC_INVOLUNTARILY_CHANGED(isPet)
    Emit("TQ", "i", Flag(isPet))
    TalentSoon("r")
end

-- Title -----------------------------------------------------------------------------------
-- TI <titleID> <title> <why>: the title shown with your name (the client's title id and its
-- text with the name as %s; empty when none is chosen). why `s` the first read of the session,
-- `c` a change. Learning a title is NC; this is choosing one.

local titleKey
local titleQueued = false

local function TitleRead()
    titleQueued = false
    local id = Num(Call(_G.GetCurrentTitle))
    if not id then return end
    local name = ""
    if id > 0 then
        local r = Pack(_G.GetTitleName, id)
        name = r and Str(r[2]) or ""
    end
    local key = id .. ":" .. name
    if key == titleKey then return end
    Emit("TI", id, name, titleKey == nil and "s" or "c")
    titleKey = key
end

local started = false
local function TitleSoon()
    if titleQueued or not started then return end
    titleQueued = true
    C_Timer.After(1, TitleRead)
end

H.UNIT_NAME_UPDATE = TitleSoon
H.KNOWN_TITLES_UPDATE = TitleSoon

-- Equipment sets ----------------------------------------------------------------------------
-- EQ <kind> <setID> <name> <items> <spec> <ignored> <result>: `b` a set found at login, `c` a set
-- created or changed (name, icon, item count, the spec it is assigned to, or the slots it
-- ignores), `x` a set deleted, `w` a swap to a set finished (result `1` or `0`). items is the
-- number of items in the set, spec the spec index it is assigned to (empty when none),
-- ignored the number of slots it ignores.

local sets = {}      -- setID -> { key, name }
local setsBased = false
local setsQueued = false

local function SetsScan()
    setsQueued = false
    if not EQS then return end
    local ids = Call(EQS.GetEquipmentSetIDs)
    if type(ids) ~= "table" then return end
    local seen = {}
    for i = 1, min(#ids, 100) do
        local id = Num(ids[i])
        local r = id and Pack(EQS.GetEquipmentSetInfo, id)
        local name = r and Str(r[2])
        if name then
            seen[id] = true
            local items = Num(r[6]) or ""
            local spec = Num(Call(EQS.GetEquipmentSetAssignedSpec, id)) or ""
            local ignored = 0
            local list = Call(EQS.GetIgnoredSlots, id)
            if type(list) == "table" then
                for _, v in pairs(list) do
                    if Plain(v) and v then ignored = ignored + 1 end
                end
            end
            local key = name .. "|" .. (Num(r[3]) or "") .. "|" .. items .. "|" .. spec .. "|" .. ignored
            local before = sets[id]
            if not before or before.key ~= key then
                sets[id] = { key = key, name = name }
                Emit("EQ", setsBased and "c" or "b", id, name, items, spec, ignored)
            end
        end
    end
    for id, rec in pairs(sets) do
        if not seen[id] then
            sets[id] = nil
            Emit("EQ", "x", id, rec.name)
        end
    end
    setsBased = true
end

function H.EQUIPMENT_SETS_CHANGED()
    if setsQueued or not started then return end
    setsQueued = true
    C_Timer.After(1, SetsScan)
end

function H.EQUIPMENT_SWAP_FINISHED(result, setID)
    local id = Num(setID)
    Emit("EQ", "w", id or "", id and sets[id] and sets[id].name or "", "", "", "", Flag(result))
end

-- Pet ---------------------------------------------------------------------------------------
-- PD <name> <level> <xp> <xpMax> <happiness> <loyalty> <points> <used> <why>: the pet's own numbers
-- (hunter and warlock pets), written when its level, loyalty, happiness or training points
-- change, or when a pet is summoned or found at login (why `s`; `c` otherwise). xp is as of
-- that line: experience alone never writes one. happiness is the client's number (`1` mad,
-- `2` neutral, `3` happy) and loyalty its text, empty where the client has none; points and
-- used are training points. PT is the summon and dismiss.

local petKey, petName
local petQueued = false
local petTries = 0
local PetSoon

local function PetRead()
    petQueued = false
    local exists = UnitExists("pet")
    if not Plain(exists) or not exists then
        petKey, petName, petTries = nil, nil, 0
        return
    end
    -- A pet shows no name (or the client's "Unknown") for a moment after it is summoned;
    -- read it again a few times until it has one, so the summon writes one PD s.
    local name = Str(UnitName("pet"))
    if not name or name == _G.UNKNOWNOBJECT then
        if petTries < 3 then
            petTries = petTries + 1
            PetSoon()
        end
        return
    end
    petTries = 0
    local level = Num(UnitLevel("pet")) or ""
    local xpr = Pack(_G.GetPetExperience)
    local xp, xpMax = xpr and Num(xpr[2]) or "", xpr and Num(xpr[3]) or ""
    local loyalty = PETINFO and Str(Call(PETINFO.GetPetLoyalty)) or ""
    local happy = PETINFO and NthNum(1, PETINFO.GetPetHappiness) or ""
    local tp = PETINFO and Pack(PETINFO.GetPetTrainingPoints)
    local points, used = tp and Num(tp[2]) or "", tp and Num(tp[3]) or ""
    local key = concat({ name, level, loyalty, happy, points, used }, "|")
    if key == petKey then return end
    petKey = key
    local why = petName ~= name and "s" or "c"
    petName = name
    Emit("PD", name, level, xp, xpMax, happy, loyalty, points, used, why)
end

PetSoon = function()
    if petQueued or not started then return end
    petQueued = true
    C_Timer.After(3, PetRead)
end

H.UNIT_PET = PetSoon
H.UNIT_PET_EXPERIENCE = PetSoon
H.UNIT_HAPPINESS = PetSoon
H.UNIT_PET_TRAINING_POINTS = PetSoon

-- Experience gain, game mode, barber, identity -----------------------------------------------
-- XD <off> <why>: `1` when experience gain is turned off for the character (the client's
-- XP lock), `0` when it is on. why `s` the first read of the session, `c` a change.
-- GA <mode> <why>: the client's active game mode number. why as XD.
-- BA <kind> <success> <copper>: a barber shop change. `a` the new appearance was applied, `r` the
-- client's result for the purchase (success `1` or `0`). copper is the price the shop last
-- quoted. The window opening is NW type 62.
-- CD <sex> <classID> <raceID> <effectiveLevel> <why>: sex (`2` male, `3` female), the
-- client's class and race ids and the level the client treats you as (it differs from the
-- real level when scaled). why as XD; written again after a level up when a value moved.

local xpKey
local function XpRead()
    local off = Call(_G.IsXPUserDisabled)
    if off == nil then return end
    local v = off and 1 or 0
    if v == xpKey then return end
    Emit("XD", v, xpKey == nil and "s" or "c")
    xpKey = v
end

local function XpSoon()
    ns.Cap.Refresh() -- experience on or off decides whether levelling work runs
    if started then C_Timer.After(0.5, XpRead) end
end

H.DISABLE_XP_GAIN = XpSoon
H.ENABLE_XP_GAIN = XpSoon

local modeKey
local function ModeRead()
    local mode = RULES and Num(Call(RULES.GetActiveGameMode))
    if not mode or mode == modeKey then return end
    Emit("GA", mode, modeKey == nil and "s" or "c")
    modeKey = mode
end

function H.ACTIVE_GAME_MODE_UPDATED()
    if started then ModeRead() end
end

-- RU <record> <warOn> <warOff> <warArea> <desired> <active> <faction> <flagged> <server> <realm> <rules> <why>: the
-- signals that might tell the character's ruleset (Normal, PvP, RP, RP-PvP, Hardcore), read
-- together. The client has no call that names the ruleset, so none is guessed here; the web
-- maps these once they are known for each ruleset. record is the game mode record id the
-- realm picker switches by (GA is the mode enum, which does not tell rulesets apart).
-- warOn and warOff say whether the client allows turning war mode on and off, warArea
-- whether this area allows a toggle (`1` or `0`, empty when the client has no answer).
-- desired and active are the war mode state, faction the player's faction, flagged the PvP
-- flag. server is the realm id inside the player's GUID (`Player-<server>-<id>`), the only
-- server number the client reports on Forever; realm is `GetRealmID`, which reads 0 there.
-- rules are the names of the client's game rules that are active, comma-joined (60 at
-- most). why as XD.
local ruKey
local function RuRead()
    local rec = RULES and Num(Call(RULES.GetCurrentGameModeRecordID))
    local names = {}
    local enum = Enum and Enum.GameRule
    if RULES and type(enum) == "table" and RULES.IsGameRuleActive then
        for name, id in pairs(enum) do
            if type(name) == "string" and Num(id) and Call(RULES.IsGameRuleActive, id) then
                names[#names + 1] = name
            end
        end
        table.sort(names)
        for i = #names, 61, -1 do names[i] = nil end
    end
    local faction = Call(_G.UnitFactionGroup, "player")
    local guid = Call(_G.UnitGUID, "player")
    local server = type(guid) == "string" and guid:match("^Player%-(%d+)%-") or ""
    local fields = {
        rec or "",
        Flag(Call(PVP and PVP.CanToggleWarMode, true)),
        Flag(Call(PVP and PVP.CanToggleWarMode, false)),
        Flag(Call(PVP and PVP.CanToggleWarModeInArea)),
        Flag(Call(PVP and PVP.IsWarModeDesired)),
        Flag(Call(PVP and PVP.IsWarModeActive)),
        Str(faction) or "",
        Flag(Call(_G.UnitIsPVP, "player")),
        server,
        Num(Call(_G.GetRealmID)) or "",
        concat(names, ","),
    }
    local selfFound = Flag(Call(PLAYERINFO and PLAYERINFO.IsSelfFoundActive))
    local selfFoundAllowed = Flag(Call(RULES and RULES.IsSelfFoundAllowed))
    local key = concat(fields, "|") .. "|" .. selfFound .. "|" .. selfFoundAllowed
    if key == ruKey then return end
    local n = #fields
    fields[n + 1], fields[n + 2], fields[n + 3] = ruKey == nil and "s" or "c", selfFound, selfFoundAllowed
    Emit("RU", unpack(fields))
    ruKey = key
end

function H.GAME_RULES_CHANGED()
    if started then C_Timer.After(0.5, RuRead) end
end

local barberCost
function H.BARBER_SHOP_COST_UPDATE()
    barberCost = BARBER and Num(Call(BARBER.GetCurrentCost)) or barberCost
end

function H.BARBER_SHOP_RESULT(success)
    Emit("BA", "r", Flag(success), barberCost or "")
end

local SelfRead

-- A barber visit can change sex, so CD reads again after it.
-- The customization choices on the barber's chair: optionID:choiceID for each option, comma-joined
-- (60 at most), read while the shop is open.
local function BarberChoices()
    local cats = BARBER and Call(BARBER.GetAvailableCustomizations)
    if type(cats) ~= "table" then return "" end
    local out = {}
    for i = 1, math.min(#cats, 20) do
        local c = cats[i]
        local opts = type(c) == "table" and Plain(c) and c.options
        if type(opts) == "table" and Plain(opts) then
            for j = 1, math.min(#opts, 20) do
                local o = opts[j]
                if type(o) == "table" and Plain(o) and #out < 60 then
                    local oid, index = Num(o.id), Num(o.currentChoiceIndex)
                    local choice = index and type(o.choices) == "table" and Plain(o.choices) and o.choices[index]
                    local cid = type(choice) == "table" and Plain(choice) and Num(choice.id)
                    if oid and cid then out[#out + 1] = oid .. ":" .. cid end
                end
            end
        end
    end
    return concat(out, ",")
end

function H.BARBER_SHOP_APPEARANCE_APPLIED()
    Emit("BA", "a", "", barberCost or "", BarberChoices())
    if started then C_Timer.After(2, SelfRead) end
end

local selfKey
SelfRead = function()
    local sex = Num(UnitSex("player")) or ""
    local cls = Pack(_G.UnitClassBase, "player")
    local classID = cls and Num(cls[3]) or ""
    local raceID = Num(select(3, UnitRace("player"))) or ""
    local eff = Num(Call(_G.UnitEffectiveLevel, "player")) or ""
    local key = concat({ sex, classID, raceID, eff }, "|")
    if key == selfKey then return end
    Emit("CD", sex, classID, raceID, eff, selfKey == nil and "s" or "c")
    selfKey = key
end

-- More character numbers --------------------------------------------------------------------
-- SX <why> <key> <value>, the same shape as SC but with its own baseline: the numbers Forever's
-- character panel shows that SC does not. Keys: `defense` (skill with its modifier),
-- `armorpen`, `spen` (spell penetration), `dmin` `dmax` (main hand damage), `omin` `omax`
-- (off hand), `rmin` `rmax` (ranged), `ilvlall` (average item level with bags), `ilvlpvp`,
-- `ilvlmin` (the lowest equipped item). why: `s` session baseline, `g` gear, `l` level, `t`
-- talents, `o` other. Read 2 seconds after the client reports a change, out of combat only.

local SX_STATS = {
    { "defense", function()
        local r = Pack(_G.UnitDefenseSkill, "player")
        local base, mod = r and Num(r[2]), r and Num(r[3])
        if base and mod then return base + mod end
    end },
    { "armorpen", function() return Call(_G.GetArmorPenetration) end },
    { "spen", function() return Call(_G.GetSpellPenetration) end },
    { "dmin", function() return NthNum(1, _G.UnitDamage, "player") end },
    { "dmax", function() return NthNum(2, _G.UnitDamage, "player") end },
    { "omin", function() return NthNum(3, _G.UnitDamage, "player") end },
    { "omax", function() return NthNum(4, _G.UnitDamage, "player") end },
    { "rmin", function() return NthNum(2, _G.UnitRangedDamage, "player") end },
    { "rmax", function() return NthNum(3, _G.UnitRangedDamage, "player") end },
    { "ilvlall", function() return NthNum(1, _G.GetAverageItemLevel) end },
    { "ilvlpvp", function() return NthNum(3, _G.GetAverageItemLevel) end },
    { "ilvlmin", function() return PAPER and Call(PAPER.GetMinItemLevel) end },
}

local sx                 -- key -> last value written; nil until the baseline
local sxWhy
local sxPending, sxDue = false, false
local SX_RANK = { o = 1, t = 2, g = 3, l = 4 }

local function SxScan()
    sxPending = false
    if InCombatLockdown() then
        sxDue = true
        return
    end
    sxDue = false
    local why = sx and (sxWhy or "o") or "s"
    sxWhy = nil
    sx = sx or {}
    for i = 1, #SX_STATS do
        local key, get = SX_STATS[i][1], SX_STATS[i][2]
        local ok, v = pcall(get)
        v = ok and R2(v) or nil
        if v ~= nil and sx[key] ~= v then
            sx[key] = v
            Emit("SX", why, key, v)
        end
    end
end

SxDirty = function(why)
    if not sxWhy or SX_RANK[why] > SX_RANK[sxWhy] then sxWhy = why end
    if sxPending or not sx then return end
    sxPending = true
    C_Timer.After(2, SxScan)
end

local function SxOther() SxDirty("o") end
for _, e in ipairs({ "UNIT_STATS", "UNIT_DEFENSE", "UNIT_DAMAGE", "UNIT_RANGEDDAMAGE", "UNIT_ATTACK",
    "COMBAT_RATING_UPDATE", "SPELL_POWER_CHANGED", "PLAYER_AVG_ITEM_LEVEL_UPDATE" }) do
    H[e] = SxOther
end
function H.PLAYER_EQUIPMENT_CHANGED() SxDirty("g") end

-- Lifecycle ---------------------------------------------------------------------------------

function H.PLAYER_LEVEL_UP()
    SxDirty("l")
    TalentSoon()
    if started then C_Timer.After(2, SelfRead) end
end

function H.PLAYER_REGEN_ENABLED()
    if tal.due then TalentSoon() end
    if sxDue then C_Timer.After(1, SxScan) end
    TitleSoon() -- a safety net: a title change that sent no name update shows up after the next fight
end

local entered = false
function H.PLAYER_ENTERING_WORLD()
    if entered then return end
    entered = true
    -- The talent configs, titles and sets are not all there at the first events of a login.
    C_Timer.After(10, function()
        started, tal.started = true, true
        TalentScan()
        TitleRead()
        SetsScan()
        PetRead()
        XpRead()
        ModeRead()
        RuRead()
        SelfRead()
        SxScan()
    end)
end

ns.Listen(frame, H, "Character")

-- These unit events fire for every unit the client tracks, nameplates and group included.
-- Only the player's own are read. Pet happiness and training points are reported with the
-- pet as the unit in older clients, so those two take the pet as well.
local valid = C_EventUtils and C_EventUtils.IsEventValid
local function OwnUnits(events, ...)
    for _, e in ipairs(events) do
        if not valid or valid(e) then
            frame:UnregisterEvent(e)
            frame:RegisterUnitEvent(e, ...)
        end
    end
end
OwnUnits({ "UNIT_DAMAGE", "UNIT_RANGEDDAMAGE", "UNIT_ATTACK", "UNIT_NAME_UPDATE", "UNIT_PET_EXPERIENCE",
    "PLAYER_SPECIALIZATION_CHANGED" }, "player")
OwnUnits({ "UNIT_HAPPINESS", "UNIT_PET_TRAINING_POINTS" }, "player", "pet")
