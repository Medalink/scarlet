local _, ns = ...

local type, pcall, tostring, select = type, pcall, tostring, select
local concat = table.concat
local min = math.min
local Emit, Plain = ns.Emit, ns.Plain

local SPELL_INFO_CAP = 4000
local SPELL_TEXT_CAP = 1500
local SPELL_TEXT_CHARS = 300
local RECIPE_CAP = 3000
local RECIPES_PER_FRAME = 20
local SPELLS_PER_FRAME = 8
local WALK_DELAY = 1
local BASIC_REAGENT = 1

local function Num(v)
    if Plain(v) and type(v) == "number" and v == v then return v end
end

local function Str(v)
    if Plain(v) and type(v) == "string" then return v end
end

local function IsTable(v)
    return Plain(v) and type(v) == "table"
end

local function Call(fn, ...)
    if type(fn) ~= "function" then return end
    local ok, v = pcall(fn, ...)
    if ok then return v end
end

local build

local function CharSet(key, countKey)
    local ch = ns.char
    if not ch then return end
    build = build or tostring(select(2, GetBuildInfo()))
    if ch.refBuild ~= build then
        ch.refBuild, ch.si, ch.sd, ch.rq = build, nil, nil, nil
    end
    local set = ch[key]
    if type(set) ~= "table" then
        set = {}
        ch[key], ch[countKey] = set, 0
    end
    return set, ch
end

local function PowerCosts(spellID)
    local list = C_Spell and Call(C_Spell.GetSpellPowerCost, spellID)
    local out = {}
    if IsTable(list) then
        for i = 1, #list do
            local entry = list[i]
            local kind, cost = IsTable(entry) and Num(entry.type), IsTable(entry) and Num(entry.cost)
            if kind and cost then out[#out + 1] = kind .. ":" .. cost end
        end
    end
    return concat(out, ",")
end

local infoSession, textSession = {}, {}

local function SpellInfoWrite(spellID, set, ch)
    if set[spellID] or (ch.siN or 0) >= SPELL_INFO_CAP then return end
    local info = Call(C_Spell.GetSpellInfo, spellID)
    if not IsTable(info) then return end
    set[spellID] = 1
    ch.siN = (ch.siN or 0) + 1
    local passive = Call(C_Spell.IsSpellPassive, spellID)
    Emit("SI", spellID, Num(info.iconID) or "", Num(info.castTime) or "", Num(info.minRange) or "",
        Num(info.maxRange) or "", PowerCosts(spellID), Plain(passive) and type(passive) == "boolean" and (passive and 1 or 0) or "")
end

local function SpellTextWrite(spellID, set, ch)
    if set[spellID] or (ch.sdN or 0) >= SPELL_TEXT_CAP then return end
    local text = Str(Call(C_Spell.GetSpellDescription, spellID))
    if not text or text == "" then return end
    set[spellID] = 1
    ch.sdN = (ch.sdN or 0) + 1
    Emit("SD", spellID, text:sub(1, SPELL_TEXT_CHARS))
end

local function SpellFactWrite(spellID)
    local infoSet, ch = CharSet("si", "siN")
    if not infoSet then return end
    local textSet = CharSet("sd", "sdN")
    if not infoSet[spellID] and not infoSession[spellID] then
        infoSession[spellID] = true
        SpellInfoWrite(spellID, infoSet, ch)
    end
    if not textSet[spellID] and not textSession[spellID] then
        textSession[spellID] = true
        SpellTextWrite(spellID, textSet, ch)
    end
end

local spellQueue, spellQueued, spellNext, spellDraining = {}, {}, 1, false

local function SpellQueueDrain()
    local last = min(spellNext + SPELLS_PER_FRAME - 1, #spellQueue)
    for i = spellNext, last do SpellFactWrite(spellQueue[i]) end
    spellNext = last + 1
    if spellNext <= #spellQueue then
        C_Timer.After(0, SpellQueueDrain)
        return
    end
    spellQueue, spellNext, spellDraining = {}, 1, false
end

--- Called by Capture.lua right after it writes the SN line of a spell.
function ns.SpellFact(spellID)
    if not C_Spell or not Plain(spellID) or type(spellID) ~= "number" or spellQueued[spellID] then return end
    spellQueued[spellID] = true
    spellQueue[#spellQueue + 1] = spellID
    if spellDraining then return end
    spellDraining = true
    C_Timer.After(0, SpellQueueDrain)
end

local function ReagentList(schematic)
    local slots = schematic.reagentSlotSchematics
    local reagents, optional = {}, 0
    if not IsTable(slots) then return "", 0 end
    for i = 1, #slots do
        local slot = slots[i]
        if IsTable(slot) then
            local first = IsTable(slot.reagents) and slot.reagents[1]
            local itemID = IsTable(first) and Num(first.itemID)
            local count = Num(slot.quantityRequired)
            if Plain(slot.required) and slot.required == true and Num(slot.reagentType) == BASIC_REAGENT then
                if itemID and count then
                    ns.ItemName(itemID)
                    reagents[#reagents + 1] = itemID .. ":" .. count
                end
            else
                optional = optional + 1
            end
        end
    end
    return concat(reagents, ","), optional
end

local function RecipeWrite(recipeID)
    local set, ch = CharSet("rq", "rqN")
    if not set or set[recipeID] or (ch.rqN or 0) >= RECIPE_CAP then return end
    local schematic = Call(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    if not IsTable(schematic) then return end
    set[recipeID] = 1
    ch.rqN = (ch.rqN or 0) + 1
    local output = Num(schematic.outputItemID)
    if output then ns.ItemName(output) end
    ns.SpellName(recipeID)
    local reagents, optional = ReagentList(schematic)
    Emit("RQ", recipeID, output or "", Num(schematic.quantityMin) or "", Num(schematic.quantityMax) or "",
        reagents, optional, Num(schematic.recipeType) or "")
end

local function IsTrue(v)
    return Plain(v) and v == true
end

local function IsLearned(recipeID)
    local info = Call(C_TradeSkillUI.GetRecipeInfo, recipeID)
    return IsTable(info) and IsTrue(info.learned)
end

local function OwnProfession()
    return not IsTrue(Call(C_TradeSkillUI.IsTradeSkillLinked)) and not IsTrue(Call(C_TradeSkillUI.IsTradeSkillGuild))
end

local windowOpen = false
local walkGen = 0

local function RecipeIDs()
    local list = Call(C_TradeSkillUI.GetAllRecipeIDs) or Call(C_TradeSkillUI.GetFilteredRecipeIDs)
    if IsTable(list) then return list end
end

local function RecipesWalk(gen)
    if not C_TradeSkillUI or not windowOpen or gen ~= walkGen or not OwnProfession() then return end
    local ids = RecipeIDs()
    local set = CharSet("rq", "rqN")
    if not ids or not set then return end
    local nextIndex = 1
    local function Step()
        if not windowOpen or gen ~= walkGen then return end
        local last = min(nextIndex + RECIPES_PER_FRAME - 1, #ids)
        for i = nextIndex, last do
            local id = Num(ids[i])
            if id and not set[id] and IsLearned(id) then RecipeWrite(id) end
        end
        nextIndex = last + 1
        if nextIndex <= #ids then C_Timer.After(0, Step) end
    end
    Step()
end

local H = {}

function H.TRADE_SKILL_SHOW()
    if not C_TradeSkillUI then return end
    windowOpen = true
    walkGen = walkGen + 1
    local gen = walkGen
    C_Timer.After(WALK_DELAY, function() RecipesWalk(gen) end)
end

function H.TRADE_SKILL_CLOSE()
    windowOpen = false
end

function H.TRADE_SKILL_CRAFT_BEGIN(recipeSpellID)
    if not C_TradeSkillUI or not Plain(recipeSpellID) or type(recipeSpellID) ~= "number" then return end
    RecipeWrite(recipeSpellID)
end

ns.Listen(CreateFrame("Frame"), H, "Reference")
