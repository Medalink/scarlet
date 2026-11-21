-- Collections.lua: what a character and the account have collected, and when:
--   CL  collection totals per kind (mounts, pets, toys, heirlooms, appearances, sets, illusions,
--       transmog outfits and custom sets), a baseline and every change
--   CA  one collected item with its source (NC marks the moment, this says what it was)
--   CX  a pet or companion removed from the collection
--   SP  the companion pet that is out
--   TX  a transmog slot saved by the transmog window, with the cost
--   TO  a transmog outfit: the one shown, a new outfit, a new custom set
--   BT  a pet battle: start, XP, level, end
-- Codes are in docs/FORMAT.md. Event driven only, nothing on a timer; every client value
-- goes through Plain() before it is compared or indexed. Totals are read from a debounced
-- scan, never from a filtered count (the journals keep their filters between sessions), and
-- written only when they differ from what this character last wrote. Toy use has no event
-- and is not recorded here: a toy's spell is a C line. The Trading Post, warband scenes and
-- Plunderstorm are not in Forever.
local _, ns = ...

local type, pcall, pairs = type, pcall, pairs
local min = math.min
local concat = table.concat
local Emit, Plain = ns.Emit, ns.Plain
local ItemName, SpellName = ns.ItemName, ns.SpellName

local MJ = C_MountJournal
local PJ = C_PetJournal
local TOYB = _G.C_ToyBox
local TOYI = C_ToyBoxInfo
local HEIR = _G.C_Heirloom
local HEIRI = C_HeirloomInfo
local TMC = C_TransmogCollection
local TMS = C_TransmogSets
local TMO = C_TransmogOutfitInfo
local PBT = C_PetBattles

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

-- Journal text carries colour codes and line breaks.
local function Clean(v)
    local s = Str(v)
    if not s then return "" end
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|n", " / ")
    return s
end

-- Per-character state kept in SavedVariables: last (the last written key of each total, cleared
-- once a day so each day starts with a full set), old (the owned count in it), outfit (the outfit
-- shown last) and sets (custom set ids already seen).
local function Store()
    local ch = ns.char
    if not ch then return end
    local p = ch.coll
    if type(p) ~= "table" then
        p = {}
        ch.coll = p
    end
    local today = date("%Y%m%d")
    if p.day ~= today then
        p.day, p.last, p.old = today, {}, {}
    end
    p.sets = p.sets or {}
    return p
end

local started, inBattle = false, false

-- Totals -------------------------------------------------------------------------------
-- CL <kind> <owned> <total> <why> <old> <detail>. kind: mount, pet, toy, heirloom, appearance,
-- set, illusion, outfit, customset. why `s` the first read of the session, `c` a change since
-- the last line (old is the owned count it had). total is empty when the client has none.
-- detail: mount `dr<skyriding unlocked>:<skyriding mounts owned>`, appearance
-- `<TransmogCollectionType>:<owned>` per category with any.

local READ = {}

local function Count(list)
    if type(list) ~= "table" then return end
    return #list
end

READ.mount = function()
    if not MJ then return end
    local ids = Call(MJ.GetMountIDs)
    if type(ids) ~= "table" then return end
    local owned, total = 0, 0
    for i = 1, min(#ids, 3000) do
        local r = Pack(MJ.GetMountInfoByID, ids[i])
        if r then
            local hidden = Plain(r[11]) and r[11]
            local have = Plain(r[12]) and r[12]
            if have then owned = owned + 1 end
            if have or not hidden then total = total + 1 end
        end
    end
    if total == 0 then return end
    local unlocked = Call(MJ.IsDragonridingUnlocked)
    local dr = Count(Call(MJ.GetCollectedDragonridingMounts))
    local detail = ""
    if unlocked ~= nil or dr then detail = "dr" .. Flag(unlocked) .. ":" .. (dr or "") end
    return owned, total, detail
end

READ.pet = function()
    if not PJ then return end
    local n = Count(Call(PJ.GetOwnedPetIDs))
    if n then return n, "", "" end
end

-- The toy box and the heirloom tab count what their filters show; a changed filter would
-- look like a collection change, so they are read only while the filters are the defaults.
READ.toy = function()
    if not TOYB or Call(TOYI and TOYI.IsUsingDefaultFilters) == false then return end
    local owned, total = Num(Call(TOYB.GetNumLearnedDisplayedToys)), Num(Call(TOYB.GetNumTotalDisplayedToys))
    if owned and total and total > 0 then return owned, total, "" end
end

READ.heirloom = function()
    if not HEIR or Call(HEIRI and HEIRI.IsUsingDefaultFilters) == false then return end
    local total = Num(Call(HEIR.GetNumDisplayedHeirlooms))
    if not total or total == 0 then return end
    local owned = 0
    for i = 1, min(total, 1000) do
        local id = Num(Call(HEIR.GetHeirloomItemIDFromDisplayedIndex, i))
        if id and Call(HEIR.PlayerHasHeirloom, id) == true then owned = owned + 1 end
    end
    return owned, total, ""
end

READ.appearance = function()
    if not TMC or type(Enum) ~= "table" or type(Enum.TransmogCollectionType) ~= "table" then return end
    local cats = {}
    for _, v in pairs(Enum.TransmogCollectionType) do
        if Num(v) and v > 0 and v < 60 then cats[#cats + 1] = v end
    end
    table.sort(cats)
    local owned, total, detail = 0, 0, {}
    for i = 1, #cats do
        local c = Num(Call(TMC.GetCategoryCollectedCount, cats[i]))
        local t = Num(Call(TMC.GetCategoryTotal, cats[i]))
        if t then total = total + t end
        if c and c > 0 then
            owned = owned + c
            detail[#detail + 1] = cats[i] .. ":" .. c
        end
    end
    if total == 0 then return end
    return owned, total, concat(detail, ",")
end

READ.set = function()
    local r = TMS and Pack(TMS.GetFullBaseSetsCounts)
    local owned, total = r and Num(r[2]), r and Num(r[3])
    if owned and total and total > 0 then return owned, total, "" end
end

READ.illusion = function()
    local list = TMC and Call(TMC.GetIllusions)
    if type(list) ~= "table" or #list == 0 then return end
    local owned = 0
    for i = 1, min(#list, 500) do
        local d = list[i]
        if type(d) == "table" and Plain(d.isCollected) and d.isCollected then owned = owned + 1 end
    end
    return owned, #list, ""
end

READ.outfit = function()
    local list = TMO and Call(TMO.GetOutfitsInfo)
    local n = Count(list)
    if n then return n, Num(Call(TMO.GetMaxNumberOfUsableOutfits)) or "", "" end
end

READ.customset = function()
    local ids = TMC and Call(TMC.GetCustomSets)
    local n = Count(ids)
    if n then return n, Num(Call(TMC.GetNumMaxCustomSets)) or "", "" end
end

local seen = {}

local function Totals(kind)
    local p = Store()
    local read = READ[kind]
    if not p or not read then return end
    local owned, total, detail = read()
    if not owned then return end
    local key = owned .. ":" .. total .. ":" .. detail
    local before = p.last[kind]
    if before == key then
        seen[kind] = true
        return
    end
    -- A day change clears what was last written, so a read with nothing before it is a baseline.
    local change = seen[kind] and before ~= nil
    local old = p.old[kind]
    p.last[kind], p.old[kind] = key, owned
    Emit("CL", kind, owned, total, change and "c" or "s", change and old or "", detail)
    seen[kind] = true
end

local dirty, queued, due = {}, false, false

local function Run()
    queued = false
    if InCombatLockdown() or inBattle then
        due = true
        return
    end
    due = false
    for kind in pairs(dirty) do
        dirty[kind] = nil
        Totals(kind)
    end
end

local function Dirty(...)
    for i = 1, select("#", ...) do dirty[(select(i, ...))] = true end
    if queued or not started then return end
    queued = true
    C_Timer.After(4, Run)
end

function H.PLAYER_REGEN_ENABLED()
    if due and not queued then
        queued = true
        C_Timer.After(4, Run)
    end
end

-- Items collected ----------------------------------------------------------------------
-- CA <kind> <id> <name> <sourceType> <source> <item> <extra>: something added to a collection.
-- NC is the moment the client said so; this is what it was.
--   mount     id mountID, sourceType the journal's source type, source its text, extra spellID
--   pet       id speciesID, sourceType the pet type, source its text, extra the level
--   toy       id and item the itemID, extra its quality
--   heirloom  id and item the itemID, extra `new` or `upgrade`
--   appearance  id the sourceID, name the item's, sourceType the client's, item the itemID,
--             extra the TransmogCollectionType; cosmetic is the same for a cosmetic source
--   battleslot  a pet battle slot unlocked
--   mountequip  id the itemID of the mount equipment now applied, extra `1` or `0` (the result)
-- The kinds with no NC line (appearance, cosmetic, heirloom, battleslot, mountequip) wait for the
-- first scan, since the client can announce collected items while logging in. Learned items are
-- capped per session; CL has the total either way.

local got, gotN = {}, 0
local GOT_MAX = 400

local function Once(key)
    if got[key] or gotN >= GOT_MAX then return false end
    got[key] = true
    gotN = gotN + 1
    return true
end

local function Added(kind, id, name, sourceType, source, item, extra)
    Emit("CA", kind, id or "", name or "", sourceType or "", source or "", item or "", extra or "")
end

-- Before the first read (8 s after login) a replayed "new" announcement is not a new item.
function H.NEW_MOUNT_ADDED(mountID)
    if not started then return end
    local id = Num(mountID)
    if not id or not MJ or not Once("mount:" .. id) then return end
    local r = Pack(MJ.GetMountInfoByID, id)
    local x = Pack(MJ.GetMountInfoExtraByID, id)
    local spell = r and Num(r[3])
    if spell then SpellName(spell) end
    Added("mount", id, r and Str(r[2]), r and Num(r[7]), x and Clean(x[4]), nil, spell)
    Dirty("mount")
end

-- Species, name, source text, level and pet type of a journal pet, from the table call, else
-- from the older multi-value call.
local pets = {}

local function PetInfo(guid)
    if not PJ then return end
    local d = Call(PJ.GetPetInfoTableByPetID, guid)
    if type(d) == "table" then
        return Num(d.speciesID), Str(d.name), Clean(d.sourceText), Num(d.petLevel), Num(d.petType)
    end
    local r = Pack(PJ.GetPetInfoByPetID, guid)
    if r then return Num(r[2]), Str(r[9]), Clean(r[13]), Num(r[4]), Num(r[11]) end
end

function H.NEW_PET_ADDED(guid)
    if not Str(guid) then return end
    local species, name, source, level, ptype = PetInfo(guid)
    if not species then return end
    pets[guid] = species
    if not started then return end
    if Once("pet:" .. guid) then Added("pet", species, name, ptype, source, nil, level) end
    Dirty("pet")
end

function H.TOYS_UPDATED(itemID, isNew)
    Dirty("toy")
    local id = Num(itemID)
    if not started or not id or not (Plain(isNew) and isNew) or not Once("toy:" .. id) then return end
    ItemName(id)
    local r = TOYB and Pack(TOYB.GetToyInfo, id)
    Added("toy", id, nil, nil, nil, id, r and Num(r[7]))
end

function H.HEIRLOOMS_UPDATED(itemID, reason)
    Dirty("heirloom")
    local id, why = Num(itemID), Str(reason)
    if not started or not id or not why then return end
    why = why:lower()
    if why ~= "new" and why ~= "upgrade" then return end
    ItemName(id)
    if why == "new" and not Once("heirloom:" .. id) then return end
    Added("heirloom", id, nil, nil, nil, id, why)
end

local function Source(kind, sourceID)
    local id = Num(sourceID)
    if not started or not id or not Once(kind .. ":" .. id) then return end
    local d = TMC and Call(TMC.GetSourceInfo, id)
    if type(d) ~= "table" then return end
    local item = Num(d.itemID)
    if item then ItemName(item) end
    Added(kind, id, Str(d.name), Num(d.sourceType), nil, item, Num(d.categoryID))
end

function H.TRANSMOG_COLLECTION_SOURCE_ADDED(sourceID)
    Source("appearance", sourceID)
    Dirty("appearance", "set")
end

function H.TRANSMOG_COSMETIC_COLLECTION_SOURCE_ADDED(sourceID)
    Source("cosmetic", sourceID)
    Dirty("appearance")
end

function H.TRANSMOG_COLLECTION_UPDATED()
    Dirty("appearance", "set", "illusion")
end

function H.PET_JOURNAL_NEW_BATTLE_SLOT()
    if started then Added("battleslot") end
end

function H.MOUNT_EQUIPMENT_APPLY_RESULT(success)
    if not started then return end
    local item = MJ and Num(Call(MJ.GetAppliedMountEquipmentID))
    if item then ItemName(item) end
    Added("mountequip", item, nil, nil, nil, nil, Flag(success))
end

-- Collection losses and list changes ---------------------------------------------------
-- CX <kind> <id>: a pet released (pet, id the species when the addon knew it) or a companion
-- unlearned (companion). The new total is the next CL line.

function H.PET_JOURNAL_PET_DELETED(guid)
    Emit("CX", "pet", Str(guid) and pets[guid] or "")
    if Str(guid) then pets[guid] = nil end
    Dirty("pet")
end

function H.COMPANION_UNLEARNED()
    Emit("CX", "companion", "")
    Dirty("pet")
end

function H.COMPANION_LEARNED()
    Dirty("pet")
end

function H.PET_JOURNAL_LIST_UPDATE()
    Dirty("pet")
end

-- Summoned pet -------------------------------------------------------------------------
-- SP <state> <speciesID> <name> <level> <customName>: the companion pet that is out. state `1`
-- summoned, `0` dismissed (species and name of the one that went away), `s` already out when
-- the session started. Hunter and warlock pets are PT.

local cur, curSpecies, curName, curLevel, curCustom = nil, nil, nil, nil, nil

local function Summoned(initial)
    local guid = PJ and Str(Call(PJ.GetSummonedPetGUID))
    if guid == cur then return end
    if cur then
        Emit("SP", 0, curSpecies or "", curName or "", curLevel or "", curCustom or "")
    end
    cur = guid
    if not guid then return end
    -- PetInfo returns species, name, source text, level, type.
    local _
    curSpecies, curName, _, curLevel = PetInfo(guid)
    local d = Call(PJ.GetPetInfoTableByPetID, guid)
    curCustom = type(d) == "table" and Str(d.customName) or nil
    if curSpecies then pets[guid] = curSpecies end
    Emit("SP", initial and "s" or 1, curSpecies or "", curName or "", curLevel or "", curCustom or "")
end

local summonQueued = false
function H.COMPANION_UPDATE(kind)
    if Plain(kind) and kind == "MOUNT" then return end
    if summonQueued or not started then return end
    summonQueued = true
    C_Timer.After(1, function()
        summonQueued = false
        Summoned(false)
    end)
end

-- Transmog -----------------------------------------------------------------------------
-- TX <slot> <type> <option> <transmogID> <item> <outfitID> <cost> <discount>: the transmog
-- window saved a slot. slot, type (`0` appearance, `1` illusion) and option are the client's
-- outfit slot numbers, transmogID the appearance source (or illusion) now on it, item the
-- item behind an appearance. outfitID is the outfit being edited. cost (copper) and discount
-- (`1` when the client had a usable discount) are on the first slot of a save and empty on the
-- others; the cost is the pending cost the window last showed.
-- TO <kind> <outfitID> <name> <extra>: kind `a` the outfit now shown (extra `s` the first read
-- of the session, `c` a change), `n` an outfit created, `s` a custom set created.

local pendingCost, pendingDiscount, lastSave = nil, nil, -100

local function CacheCost()
    if not TMO then return end
    local cost = Num(Call(TMO.GetPendingTransmogCost))
    if cost then pendingCost, pendingDiscount = cost, Flag(Call(TMO.IsUsableDiscountAvailable)) end
end

H.VIEWED_TRANSMOG_OUTFIT_SLOT_REFRESH = CacheCost
H.VIEWED_TRANSMOG_OUTFIT_SITUATIONS_CHANGED = CacheCost

function H.VIEWED_TRANSMOG_OUTFIT_SLOT_SAVE_SUCCESS(slot, kind, option)
    if not Num(slot) or not Num(kind) then return end
    local info = TMO and Call(TMO.GetViewedOutfitSlotInfo, slot, kind, Num(option) or 0)
    local id = type(info) == "table" and Num(info.transmogID) or nil
    local item
    if id and kind == 0 and id > 0 then
        local d = TMC and Call(TMC.GetSourceInfo, id)
        item = type(d) == "table" and Num(d.itemID) or nil
        if item then ItemName(item) end
    end
    local first = GetTime() - lastSave > 3
    lastSave = GetTime()
    local cost, discount = "", ""
    if first then
        if pendingCost and pendingCost > 0 then cost, discount = pendingCost, pendingDiscount end
        pendingCost, pendingDiscount = nil, nil
    end
    Emit("TX", slot, kind, Num(option) or "", id or "", item or "", TMO and Num(Call(TMO.GetCurrentlyViewedOutfitID)) or "",
        cost, discount)
end

local function OutfitName(id)
    local d = TMO and Num(id) and Call(TMO.GetOutfitInfo, id)
    return type(d) == "table" and Str(d.name) or ""
end

local function Shown(initial)
    local p = Store()
    local id = TMO and Num(Call(TMO.GetActiveOutfitID))
    if not p or not id or p.outfit == id and not initial then return end
    local before = p.outfit
    p.outfit = id
    if initial and before == id then return end
    Emit("TO", "a", id, OutfitName(id), initial and "s" or "c")
end

function H.TRANSMOG_DISPLAYED_OUTFIT_CHANGED()
    if started then Shown(false) end
end

function H.TRANSMOG_OUTFITS_CHANGED(newOutfitID)
    Dirty("outfit")
    local id = Num(newOutfitID)
    if id then Emit("TO", "n", id, OutfitName(id), "") end
end

-- Custom set ids already known to this character, kept in SavedVariables (coll.sets), so
-- sets that load late or after a reload are not written as new. The very first read for a
-- character seeds the list without lines.
local setReads = 0
local function CustomSets()
    local ids = TMC and Call(TMC.GetCustomSets)
    if type(ids) ~= "table" then return end
    local p = Store()
    if not p then return end
    -- The first read of a session can come back empty while the sets still load, so an
    -- empty list seeds only on a later read: a character with no sets, whose first set
    -- made later is then written.
    local seed = p.setsSeeded ~= true
    setReads = setReads + 1
    if seed and #ids == 0 and setReads < 2 then return end
    for i = 1, min(#ids, 200) do
        local id = Num(ids[i])
        if id and not p.sets[id] then
            p.sets[id] = true
            if not seed then
                local ok, name = pcall(TMC.GetCustomSetInfo, id)
                Emit("TO", "s", id, ok and Str(name) or "", "")
            end
        end
    end
    p.setsSeeded = true
end

function H.TRANSMOG_CUSTOM_SETS_CHANGED()
    Dirty("customset")
    if started then CustomSets() end
end

-- Pet battles --------------------------------------------------------------------------
-- BT <kind> ...: a pet battle. Not yet seen in game.
--   s <wild> <npc> <yours> <theirs> <names>: it began. wild `1` for a wild pet, npc `1` for a
--     trainer. yours and theirs are `speciesID:level:quality` per pet, comma-joined; names are
--     the opposing species' names, joined with ` / `.
--   x <speciesID> <xp>: one of your pets gained experience.
--   l <speciesID> <level>: one of your pets gained a level.
--   e <seconds> <rounds> <result> <xp>: it ended. result `w` you won, `l` you lost, empty when
--     the client did not say; xp is all the experience your pets gained in it.

local battle
local ALLY, ENEMY = 1, 2

local function Team(owner)
    local n = PBT and Num(Call(PBT.GetNumPets, owner))
    local list, names = {}, {}
    if not n then return "", "" end
    for i = 1, min(n, 6) do
        local species = Num(Call(PBT.GetPetSpeciesID, owner, i))
        if species then
            list[#list + 1] = species .. ":" .. (Num(Call(PBT.GetLevel, owner, i)) or "") .. ":"
                .. (Num(Call(PBT.GetBreedQuality, owner, i)) or "")
            local r = Pack(PBT.GetName, owner, i)
            local name = r and (Str(r[3]) or Str(r[2]))
            if name then names[#names + 1] = name end
        end
    end
    return concat(list, ","), concat(names, " / ")
end

function H.PET_BATTLE_OPENING_START()
    inBattle = true
    battle = { t = GetTime(), rounds = 0, xp = 0 }
    if not PBT then return end
    local yours = Team(ALLY)
    local theirs, names = Team(ENEMY)
    Emit("BT", "s", Flag(Call(PBT.IsWildBattle)), Flag(Call(PBT.IsPlayerNPC)), yours, theirs, names)
end

function H.PET_BATTLE_XP_CHANGED(owner, index, xp)
    if not battle or Num(owner) ~= ALLY or not Num(xp) then return end
    battle.xp = battle.xp + xp
    Emit("BT", "x", PBT and Num(Call(PBT.GetPetSpeciesID, ALLY, index)) or "", xp)
end

function H.PET_BATTLE_LEVEL_CHANGED(owner, index, level)
    if not battle or Num(owner) ~= ALLY or not Num(level) then return end
    Emit("BT", "l", PBT and Num(Call(PBT.GetPetSpeciesID, ALLY, index)) or "", level)
end

function H.PET_BATTLE_PET_ROUND_PLAYBACK_COMPLETE(round)
    if battle and Num(round) then battle.rounds = round end
end

function H.PET_BATTLE_FINAL_ROUND(owner)
    if battle and Num(owner) then battle.winner = owner end
end

-- XP and level changes can arrive after PET_BATTLE_OVER, so the end line waits for
-- PET_BATTLE_CLOSE (the battle frame closing).
local function Over()
    local b = battle
    battle, inBattle = nil, false
    if b then
        local result = b.winner == ALLY and "w" or b.winner == ENEMY and "l" or ""
        Emit("BT", "e", ns.Round1((b.over or GetTime()) - b.t), b.rounds, result, b.xp)
    end
    Dirty("pet")
end

function H.PET_BATTLE_OVER()
    inBattle = false
    if battle then battle.over = GetTime() end
end
H.PET_BATTLE_CLOSE = Over

-- Lifecycle ----------------------------------------------------------------------------

local entered = false
function H.PLAYER_ENTERING_WORLD()
    if entered then return end
    entered = true
    -- The journals fill in over the first seconds of a session; the first read waits for them.
    C_Timer.After(8, function()
        started = true
        -- The toy box counts are stale until it has filtered once (Forever's ToyBox does this
        -- on load); this touches no filter.
        if TOYB and type(TOYB.ForceToyRefilter) == "function" then pcall(TOYB.ForceToyRefilter) end
        for kind in pairs(READ) do dirty[kind] = true end
        Run()
        CustomSets()
        Shown(true)
        Summoned(true)
    end)
end

ns.Listen(frame, H, "Collections")
