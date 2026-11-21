-- Metrics.lua: numbers the client keeps about the character, written when
-- they change so trends can be drawn from the log:
--   SC  character stats (the character panel), with why they changed
--   SL  skill lines (weapons, defense, professions, languages)
--   WS  the client's own Statistics panel, one line per statistic that moved
--   AP  achievement (Legacy Challenge) totals, AE criteria earned, LV Legacy renown
--   LO  where a loot window's items came from (creature, object, container)
--   PR  which of the APIs Scarlet relies on this client build has
-- Every session starts with a full baseline of SC and SL, and the Statistics
-- baseline is rewritten once a day, so a pruned history still has a
-- starting point. Codes are in docs/FORMAT.md.
local _, ns = ...

local floor, type, pcall, select, tostring = math.floor, type, pcall, select, tostring
local Emit, Plain = ns.Emit, ns.Plain

local frame = CreateFrame("Frame")
local H = {}

local function Num(v) if Plain(v) and type(v) == "number" then return v end end
local function Str(v) if Plain(v) and type(v) == "string" and v ~= "" then return v end end
local function R2(v)
    v = Num(v)
    if not v then return end
    if v == floor(v) then return v end
    return floor(v * 100 + 0.5) / 100
end
local function Call(name, ...)
    local f = _G[name]
    if type(f) ~= "function" then return end
    return pcall(f, ...)
end

-- Character stats ----------------------------------------------------------------
-- SC <reason> <key> <value>. reason: s session baseline, g gear, l level,
-- t talents, a aura (buffs, camps, food), o other.

local function Second(name, ...)
    local ok, _, v = Call(name, ...)
    if ok then return v end
end
local function First(name, ...)
    local ok, v = Call(name, ...)
    if ok then return v end
end
local function AttackPower(name)
    local ok, base, pos, neg = Call(name, "player")
    if ok and Num(base) and Num(pos) and Num(neg) then return base + pos + neg end
end
local function BestSchool(name)
    local best
    for school = 2, 7 do
        local v = Num(First(name, school))
        if v and (not best or v > best) then best = v end
    end
    return best
end

local STATS = {
    { "str", function() return Second("UnitStat", "player", 1) end },
    { "agi", function() return Second("UnitStat", "player", 2) end },
    { "sta", function() return Second("UnitStat", "player", 3) end },
    { "int", function() return Second("UnitStat", "player", 4) end },
    { "spi", function() return Second("UnitStat", "player", 5) end },
    { "armor", function() return Second("UnitArmor", "player") end },
    { "hp", function() return First("UnitHealthMax", "player") end },
    { "mp", function() return First("UnitPowerMax", "player") end },
    { "ap", function() return AttackPower("UnitAttackPower") end },
    { "rap", function() return AttackPower("UnitRangedAttackPower") end },
    { "crit", function() return First("GetCritChance") end },
    { "rcrit", function() return First("GetRangedCritChance") end },
    { "scrit", function() return BestSchool("GetSpellCritChance") end },
    { "sp", function() return BestSchool("GetSpellBonusDamage") end },
    { "heal", function() return First("GetSpellBonusHealing") end },
    { "hit", function() return First("GetHitModifier") end },
    { "shit", function() return First("GetSpellHitModifier") end },
    { "exp", function() return First("GetExpertise") end },
    { "haste", function() return First("GetMeleeHaste") end },
    { "rhaste", function() return First("GetRangedHaste") end },
    { "shaste", function() return First("UnitSpellHaste", "player") end },
    { "swing", function() return First("UnitAttackSpeed", "player") end },
    { "regen", function() return First("GetManaRegen") end },
    { "dodge", function() return First("GetDodgeChance") end },
    { "parry", function() return First("GetParryChance") end },
    { "block", function() return First("GetBlockChance") end },
    { "rholy", function() return Second("UnitResistance", "player", 1) end },
    { "rfire", function() return Second("UnitResistance", "player", 2) end },
    { "rnature", function() return Second("UnitResistance", "player", 3) end },
    { "rfrost", function() return Second("UnitResistance", "player", 4) end },
    { "rshadow", function() return Second("UnitResistance", "player", 5) end },
    { "rarcane", function() return Second("UnitResistance", "player", 6) end },
    { "ilvl", function() return Second("GetAverageItemLevel") end },
}

local stats          -- key -> last value written this session; nil until the baseline
local statWhy        -- strongest reason seen since the last scan
local statPending, statDue = false, false
local WHY_RANK = { o = 1, a = 2, t = 3, g = 4, l = 5 }

local function StatScan()
    statPending = false
    if InCombatLockdown() then
        statDue = true -- some values are hidden in combat; read them after
        return
    end
    statDue = false
    local why = stats and (statWhy or "o") or "s"
    statWhy = nil
    stats = stats or {}
    for i = 1, #STATS do
        local key, get = STATS[i][1], STATS[i][2]
        local ok, v = pcall(get)
        v = ok and R2(v) or nil
        if v ~= nil and stats[key] ~= v then
            stats[key] = v
            Emit("SC", why, key, v)
        end
    end
end

local function StatDirty(why)
    if not statWhy or WHY_RANK[why] > WHY_RANK[statWhy] then statWhy = why end
    if statPending or not stats then return end
    statPending = true
    C_Timer.After(2, StatScan)
end

local function Other() StatDirty("o") end
for _, e in ipairs({ "UNIT_STATS", "UNIT_RESISTANCES", "UNIT_ATTACK_POWER", "UNIT_RANGED_ATTACK_POWER",
    "UNIT_MAXHEALTH", "UNIT_MAXPOWER", "UNIT_ATTACK_SPEED", "UNIT_SPELL_HASTE", "UNIT_DEFENSE",
    "COMBAT_RATING_UPDATE", "SPELL_POWER_CHANGED", "PLAYER_DAMAGE_DONE_MODS", "PLAYER_AVG_ITEM_LEVEL_UPDATE" }) do
    H[e] = Other
end
function H.PLAYER_EQUIPMENT_CHANGED() StatDirty("g") end
function H.UNIT_AURA() StatDirty("a") end
function H.TRAIT_CONFIG_UPDATED() StatDirty("t") end
function H.PLAYER_LEVEL_UP() StatDirty("l") end
function H.CHARACTER_POINTS_CHANGED() StatDirty("t") end
function H.ACTIVE_TALENT_GROUP_CHANGED() StatDirty("t") end

-- Skill lines --------------------------------------------------------------------
-- SL <skillID> <rank> <max> <modifier> <s on the session baseline>. KN names
-- the skill once per session. Only expanded headers are visible to the API.

local skills, skillNamed = nil, {}
local skillPending = false

local function SkillScan()
    skillPending = false
    local SI = C_SkillInfo
    if not SI or not SI.GetNumSkillLines then return end
    local ok, n = pcall(SI.GetNumSkillLines)
    if not ok or not Num(n) then return end
    local base = not skills
    skills = skills or {}
    for i = 1, n do
        local okI, a = pcall(SI.GetSkillLineInfo, i)
        if okI and type(a) == "table" and Num(a.skillID) and not (Plain(a.isHeader) and a.isHeader) then
            local id = a.skillID
            local rank, max, mod = Num(a.rank) or "", Num(a.maxRank) or "", Num(a.modifier) or ""
            local key = rank .. "/" .. max .. "/" .. mod
            if skills[id] ~= key then
                skills[id] = key
                if not skillNamed[id] and Str(a.name) then
                    skillNamed[id] = true
                    Emit("KN", id, a.name, Num(a.skillLineCategoryID) or "")
                end
                Emit("SL", id, rank, max, mod, base and "s" or "")
            end
        end
    end
end

function H.SKILL_LINES_CHANGED()
    if skillPending or not skills then return end
    skillPending = true
    C_Timer.After(1, SkillScan)
end

-- The client's Statistics panel ----------------------------------------------------
-- WS <statisticID> <value>: a statistic that changed since it was last written.
-- WN <statisticID> <name> <categoryID> names it once per session. The value
-- is the client's own text: a number, or money with |T...|t coin icons.

local wsNamed = {}
local wsDue, wsNext = false, 0
local WS_EVERY = 60

local function StatisticsScan()
    if InCombatLockdown() then
        wsDue = true
        return
    end
    wsDue = false
    wsNext = GetTime() + WS_EVERY
    if not ns.char then return end
    local list, count, get = _G.GetStatisticsCategoryList, _G.GetCategoryNumAchievements, _G.GetStatistic
    if type(list) ~= "function" or type(count) ~= "function" or type(get) ~= "function" then return end
    local ok, cats = pcall(list)
    if not ok or type(cats) ~= "table" then return end
    -- Kept per character so only changes are written; rewritten whole once a day.
    local today = date("%Y%m%d")
    if ns.char.wsDay ~= today then
        ns.char.wsDay, ns.char.ws = today, {}
    end
    local seen = ns.char.ws
    for c = 1, #cats do
        local cat = cats[c]
        local okN, n = pcall(count, cat)
        if okN and Num(n) then
            for i = 1, n do
                local okS, qty, skip, id = pcall(get, cat, i)
                if okS and Num(id) and not (Plain(skip) and skip) and Plain(qty) and qty ~= nil then
                    local v = tostring(qty)
                    if seen[id] ~= v then
                        seen[id] = v
                        if not wsNamed[id] then
                            wsNamed[id] = true
                            local okA, _, name = Call("GetAchievementInfo", id)
                            if okA and Str(name) then Emit("WN", id, name, Num(cat) or "") end
                        end
                        Emit("WS", id, v)
                    end
                end
            end
        end
    end
end

local wsQueued = false
local function StatisticsSoon()
    if wsQueued then return end
    wsQueued = true
    C_Timer.After(math.max(1, wsNext - GetTime()), function()
        wsQueued = false
        StatisticsScan()
    end)
end
H.CRITERIA_UPDATE = StatisticsSoon

-- Achievements, criteria and Legacy renown ---------------------------------------
-- Forever shows achievements as Legacy Challenges; the API is the same.

local C = _G.Constants
local LEGACY_FACTION = C and C.LegacyConsts and C.LegacyConsts.LEGACY_REWARD_TRACK_FACTION_ID

local function Totals()
    local okP, points = Call("GetTotalAchievementPoints")
    local okC, total, done = Call("GetNumCompletedAchievements")
    if okP or okC then
        Emit("AP", okP and Num(points) or "", okC and Num(done) or "", okC and Num(total) or "")
    end
end

local lastRenown
local function Renown()
    local MF = C_MajorFactions
    if not LEGACY_FACTION or not MF or not MF.GetCurrentRenownLevel then return end
    local ok, level = pcall(MF.GetCurrentRenownLevel, LEGACY_FACTION)
    if ok and Num(level) and level ~= lastRenown then
        lastRenown = level
        Emit("LV", level)
    end
end
H.MAJOR_FACTION_RENOWN_LEVEL_CHANGED = Renown

function H.ACHIEVEMENT_EARNED(id, alreadyEarned)
    if Plain(alreadyEarned) and alreadyEarned then return end
    if Num(id) then
        local ok, _, name, points = Call("GetAchievementInfo", id)
        if ok and Str(name) then Emit("AN", id, name, Num(points) or "") end
    end
    Totals()
    StatisticsSoon()
end

function H.CRITERIA_EARNED(id, description)
    Emit("AE", Num(id) or "", Str(description) or "")
end

-- Loot sources -------------------------------------------------------------------
-- LO <kind> <id> <slots> <items> <again>: kind c creature (npcID), g object such
-- as a herb, vein, chest or fishing bobber (objectID), i an item opened from the
-- bags. items is what this source put in the window (itemIDxquantity, m coin,
-- c<currencyID>), read from the window itself, so a drop is tied to its mob or
-- object without relying on the order of the O lines after it. again is 1 when
-- this corpse or object was already read this session (skinning it, opening it a
-- second time), 0 for a first read, empty for an item.

local KINDS = { Creature = "c", Vehicle = "c", GameObject = "g", Item = "i" }

-- Read at LOOT_READY: fast-loot addons empty the window before LOOT_OPENED, which
-- left no LO line at all on 2026-11-20 (fishing, kills). LOOT_OPENED stays as a
-- fallback; one read per loot window.
local lootRead = false

-- An item GUID carries no item ID, so remember what was used from the bags: a
-- clam or a fished crate then reads LO i 7973, and its O lines link back
-- through the clam's own O line to the bobber that caught it.
local USED_FOR = 5
local usedItem, usedT

local function Used(id)
    id = Num(id)
    if id then usedItem, usedT = id, GetTime() end
end
if C_Container and C_Container.UseContainerItem then
    hooksecurefunc(C_Container, "UseContainerItem", function(bag, slot)
        local ok, id = pcall(C_Container.GetContainerItemID, bag, slot)
        if ok then Used(id) end
    end)
end
if type(_G.UseItemByName) == "function" then
    hooksecurefunc("UseItemByName", function(item)
        if not Plain(item) then return end
        local getID = C_Item and C_Item.GetItemInfoInstant or _G.GetItemInfoInstant
        if type(getID) ~= "function" then return end
        local ok, id = pcall(getID, item)
        if ok then Used(id) end
    end)
end
-- Taken once: a later bag-item window must not inherit an item sold or used before it.
local function UsedItem()
    local id = usedT and GetTime() - usedT < USED_FOR and usedItem
    usedItem, usedT = nil, nil
    return id and tostring(id) or ""
end

-- What a loot slot holds: an itemID, `m` coin, or `c<currencyID>`.
local function SlotToken(slot)
    local okT, slotType = Call("GetLootSlotType", slot)
    slotType = okT and Num(slotType)
    if slotType == 2 then return "m" end
    local okI, _, _, _, currencyID, _, _, _, _, _, isCoin = Call("GetLootSlotInfo", slot)
    if okI and Plain(isCoin) and isCoin then return "m" end
    if slotType == 3 and okI and Num(currencyID) then return "c" .. currencyID end
    local okL, link = Call("GetLootSlotLink", slot)
    local id = okL and Str(link) and link:match("item:(%d+)")
    return id
end

-- Corpses and objects read lately: skinning a corpse or opening it a second time
-- reads the same GUID again, and those windows are not new drops. A read older
-- than REREAD_FOR is a first read again, in case a respawn keeps its GUID.
local readGUIDs, nRead = {}, 0
local REREAD_FOR = 300

local function LootSources(isFromItem)
    if lootRead then return end
    local okN, n = Call("GetNumLootItems")
    if not okN or not Num(n) or n == 0 or type(_G.GetLootSourceInfo) ~= "function" then return end
    local sources, order, used = {}, {}, nil
    for slot = 1, n do
        local token = SlotToken(slot)
        local r = { pcall(_G.GetLootSourceInfo, slot) }
        if not r[1] then r = {} end
        -- The client returns guid1, quantity1, guid2, ... (one pair on Forever, which
        -- has no area loot).
        for j = 2, #r, 2 do
            local guid = Str(r[j])
            if guid then
                local kind = guid:match("^(%a+)-")
                local id = kind and guid:match("^%a+%-%d+%-%d+%-%d+%-%d+%-(%d+)")
                if kind == "Item" then
                    used = used or UsedItem()
                    id = used
                end
                local key = (KINDS[kind] or "o") .. ":" .. (id or "")
                local src = sources[key]
                if not src then
                    src = { slots = 0, items = {}, guid = guid }
                    sources[key] = src
                    order[#order + 1] = key
                end
                src.slots = src.slots + 1
                if token then
                    local qty = Num(r[j + 1])
                    src.items[#src.items + 1] = qty and qty > 0 and (token .. "x" .. qty) or token
                end
            end
        end
    end
    if #order == 0 and Plain(isFromItem) and isFromItem then
        lootRead = true
        Emit("LO", "i", used or UsedItem(), n)
        return
    end
    -- Only a window that produced a line counts as read; an empty read at
    -- LOOT_READY leaves LOOT_OPENED to try again.
    if #order > 0 then lootRead = true end
    if nRead > 500 then readGUIDs, nRead = {}, 0 end
    for i = 1, #order do
        local kind, id = order[i]:match("^(%a):(.*)$")
        local src = sources[order[i]]
        local again = ""
        if kind == "c" or kind == "g" then
            local now, t = GetTime(), readGUIDs[src.guid]
            again = t and now - t < REREAD_FOR and 1 or 0
            if again == 0 then
                if not t then nRead = nRead + 1 end
                readGUIDs[src.guid] = now
            end
        end
        Emit("LO", kind, id, src.slots, table.concat(src.items, ","), again)
        if kind == "c" or kind == "g" then ns.PlaceGUID(src.guid, "l") end
    end
end

function H.LOOT_READY() LootSources() end
function H.LOOT_OPENED(_, isFromItem) LootSources(isFromItem) end
function H.LOOT_CLOSED() lootRead = false end

-- API probe ----------------------------------------------------------------------
-- PR <name> <1 or 0>, once per client build and day: which globals Scarlet reads exist.

local PROBE = {
    "GetStatistic", "GetStatisticsCategoryList", "GetCategoryNumAchievements", "GetTotalAchievementPoints",
    "GetNumCompletedAchievements", "GetAchievementInfo", "GetLootSourceInfo", "GetNumLootItems",
    "GetCritChance", "GetRangedCritChance", "GetSpellCritChance", "GetSpellBonusDamage", "GetSpellBonusHealing",
    "GetHitModifier", "GetSpellHitModifier", "GetExpertise", "GetMeleeHaste", "GetRangedHaste", "UnitSpellHaste",
    "UnitAttackSpeed", "GetManaRegen", "GetDodgeChance", "GetParryChance", "GetBlockChance", "UnitResistance",
    "GetAverageItemLevel", "UnitAttackPower", "UnitRangedAttackPower", "GetInventoryItemID", "RollOnLoot",
    "GetLootRollItemLink", "C_SkillInfo", "C_TradeSkillUI", "C_DamageMeter", "C_DeathRecap", "C_MajorFactions",
    "C_Traits", "GetTaxiMapID", "TaxiNodeCost", "TakeTaxiNode", "GetBindLocation", "GetInstanceBootTimeRemaining",
    "GetDungeonDifficultyID", "GetRaidDifficultyID", "GetLegacyRaidDifficultyID", "IsFlyableArea", "IsMounted",
    "UnitOnTaxi", "C_TaxiMap", "C_SummonInfo", "C_VignetteInfo", "C_AreaPoiInfo", "C_Minimap", "C_ScenarioInfo",
    "C_MountJournal",
    "C_PetJournal", "C_ToyBox", "C_ToyBoxInfo", "C_Heirloom", "C_HeirloomInfo", "C_TransmogCollection",
    "C_TransmogSets", "C_TransmogOutfitInfo", "C_PetBattles",
    "C_GameRules", "C_CurrencyInfo", "C_EncodingUtil", "GetNumTotemSlots", "GetTotemInfo",
    "GetInstanceLockTimeRemaining", "C_DeathInfo", "C_ProfSpecs", "C_CraftingOrders",
    "C_QuestLog", "C_GossipInfo", "C_ContentTracking", "C_CampaignInfo", "C_PlayerChoice", "C_QuestInfoSystem",
    "GetQuestReward", "GetQuestItemLink", "GetNumQuestChoices", "GetQuestID", "ItemTextGetItem",
    "BuyMerchantItem", "BuybackItem", "GetMerchantItemLink", "GetBuybackItemInfo", "GetBuybackItemLink",
    "SendMail", "GetSendMailItem", "GetSendMailMoney", "GetSendMailCOD", "GetInboxHeaderInfo", "GetInboxItem",
    "TakeInboxMoney", "TakeInboxItem", "AutoLootMailItem", "ReturnInboxItem", "GetTradePlayerItemInfo",
    "GetTradeTargetItemInfo", "GetTradePlayerItemLink", "GetTradeTargetItemLink", "GetPlayerTradeMoney",
    "GetTargetTradeMoney", "DepositGuildBankMoney", "WithdrawGuildBankMoney", "DeleteCursorItem", "GetCursorInfo",
    "GetInventoryItemLink", "GetLootSpecialization", "GetUnitName", "C_AuctionHouse", "C_Bank", "C_Container",
    "C_MerchantFrame", "C_ItemUpgrade", "C_LootHistory", "C_WowTokenPublic", "C_Item",
    "C_Reputation", "C_AchievementInfo", "GetAchievementCriteriaInfo", "GetAchievementNumCriteria",
    "GetAchievementCategory", "UseItemByName",
    "C_PvP", "GetBattlefieldStatus", "GetMaxBattlefieldID", "GetBattlefieldTimeWaited",
    "GetBattlefieldArenaFaction", "RequestBattlefieldScoreData", "UnitHonorLevel",
    "GetCurrentTitle", "GetTitleName", "GetNumSpecGroups", "IsXPUserDisabled", "UnitDefenseSkill", "UnitDamage",
    "UnitRangedDamage", "GetArmorPenetration", "GetSpellPenetration", "UnitEffectiveLevel", "UnitClassBase",
    "GetPetExperience", "C_SpecializationInfo", "C_ClassTalents", "C_EquipmentSet", "C_PetInfo", "C_BarberShop",
    "C_PaperDollInfo",
    "C_SpellBook", "C_Spell", "C_ActionBar", "C_StableInfo", "C_Trainer", "GetActionInfo", "BuyTrainerService",
    "GetTrainerServiceInfo", "GetTrainerServiceCost", "GetMoney",
    "C_FriendList", "C_GuildInfo", "C_PartyInfo", "C_LFGList", "C_LFGInfo", "C_LFGListRoles", "C_Calendar", "C_Club", "C_ClubFinder", "InspectUnit", "GetGuildInfo", "GetNumGuildMembers", "IsPlayerInGuildFromGUID", "GetRaidRosterInfo", "BNGetNumFriends", "AcceptGroup", "DeclineGroup", "AcceptGuild", "DeclineGuild",
    "C_UIWidgetManager", "C_SuperTrack", "GetGameMessageInfo", "GetLocale", "GetRaidTargetIndex", "CanBeRaidTarget", "IsRaidMarkerActive", "SetRaidTarget", "PlaceRaidMarker", "ClearRaidMarker", "StopCinematic", "CinematicFinished", "MovieFrame",
    "C_TooltipInfo", "GetNumTrainerServices", "GetTrainerServiceSkillLine", "GetTrainerServiceSkillReq",
    "GetTrainerServiceNumAbilityReq", "GetTrainerServiceAbilityReq", "GetTrainerServiceCost",
    "GetMerchantNumItems", "GetMerchantItemID", "GetMerchantItemInfo", "GetMerchantItemCostInfo",
    "GetMerchantItemCostItem", "CanMerchantRepair",
    "UnitClassification", "UnitCreatureType", "UnitCreatureFamily", "UnitPlayerControlled", "UnitReaction",
    "UnitFactionGroup", "C_RecentAllies", "GetCurrentRegion", "UnitXP", "UnitXPMax", "C_AddOns",
    "GetInboxInvoiceInfo", "GetPlayerInfoByGUID", "GetPlayerFacing", "Screenshot",
    "GetSendMailPrice",
}

local function Probe()
    local db = ns.db
    local build = select(2, GetBuildInfo())
    -- Once per build and day, so pruning old chunks never loses the record.
    local key = tostring(build) .. ":" .. date("%Y%m%d")
    if not db or db.probed == key then return end
    db.probed = key
    for i = 1, #PROBE do
        local v = _G[PROBE[i]]
        Emit("PR", PROBE[i], (type(v) == "function" or type(v) == "table") and 1 or 0)
    end
end

-- Lifecycle ----------------------------------------------------------------------

function H.PLAYER_REGEN_ENABLED()
    if statDue then C_Timer.After(1, StatScan) end
    if wsDue then StatisticsSoon() end
end

local entered = false
function H.PLAYER_ENTERING_WORLD()
    if entered then return end
    entered = true
    Probe()
    C_Timer.After(3, StatScan)
    C_Timer.After(3, SkillScan)
    C_Timer.After(4, function()
        Totals()
        Renown()
    end)
    C_Timer.After(20, StatisticsScan)
end

function H.PLAYER_LOGOUT()
    -- Last values of the session. This frame may run after Capture.lua has
    -- sealed; these lines stay in the saved buffer and are sealed next login.
    if not InCombatLockdown() and GetTime() >= wsNext then StatisticsScan() end
end

ns.Listen(frame, H, "Metrics")
