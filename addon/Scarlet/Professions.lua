-- Professions.lua: the Professions-domain trackers beyond Track's crafting block:
--   RD  how hard a recipe was when a craft began (skill-up odds, recraft, salvage)
--   RT  recipes you track for their reagents
--   PG  profession tools and accessories equipped or removed
--   PS  specialization points available for a profession
--   PU  a profession specialization unlocked
--   PO  personal crafting orders waiting for you
--   CO  you fulfilled a crafting order
-- Codes are in docs/FORMAT.md. Event driven only; every client value through
-- Plain() before it is compared or indexed.
local _, ns = ...

local type, pcall, pairs, ipairs, tostring = type, pcall, pairs, ipairs, tostring
local Emit, Plain = ns.Emit, ns.Plain
local SpellName, ItemName = ns.SpellName, ns.ItemName

local TSUI = C_TradeSkillUI
local SPECS = C_ProfSpecs
local ORDERS = C_CraftingOrders

local frame = CreateFrame("Frame")
local H = {}

local function Str(v)
    if Plain(v) and type(v) == "string" and v ~= "" then return v end
end

local function Num(v)
    if Plain(v) and type(v) == "number" then return v end
end

local function B(v) return Plain(v) and v and 1 or 0 end

-- First return value of fn(...), or nil when it errors or comes back secret.
local function Call(fn, ...)
    if type(fn) ~= "function" then return end
    local ok, v = pcall(fn, ...)
    if ok and Plain(v) then return v end
end

-- Skill line names ---------------------------------------------------------------------
-- KN <skillLineID> <name>, once per session, for the profession lines that PS,
-- PU and PG point at. Metrics writes KN for the lines in the skills list.

local skillNamed = {}

local function SkillName(id)
    if not Num(id) or skillNamed[id] or not TSUI then return end
    local info = Call(TSUI.GetProfessionInfoBySkillLineID, id)
    if type(info) == "table" and Str(info.professionName) then
        skillNamed[id] = true
        Emit("KN", id, info.professionName, "")
    end
end

-- Recipe difficulty at the start of a craft ----------------------------------------------
-- RD <recipeSpellID> <difficulty> <skillUps> <canSkillUp> <recraft> <salvage>
-- <enchant> <firstCraft> <qualities>. difficulty 0 optimal, 1 medium, 2 easy,
-- 3 trivial. Written when a recipe's values differ from the last RD for it, so a
-- long craft queue is one line until the recipe turns easier.

local recipeSeen = {}

function H.TRADE_SKILL_CRAFT_BEGIN(recipeSpellID)
    if not Num(recipeSpellID) or not TSUI then return end
    local info = Call(TSUI.GetRecipeInfo, recipeSpellID)
    if type(info) ~= "table" then return end
    local diff, ups = Num(info.relativeDifficulty), Num(info.numSkillUps)
    local line = { recipeSpellID, diff or "", ups or "", B(info.canSkillUp), B(info.isRecraft),
        B(info.isSalvageRecipe), B(info.isEnchantingRecipe), B(info.firstCraft), B(info.supportsQualities) }
    local key = ""
    for i = 2, #line do key = key .. tostring(line[i]) .. ":" end
    if recipeSeen[recipeSpellID] == key then return end
    recipeSeen[recipeSpellID] = key
    SpellName(recipeSpellID)
    Emit("RD", line[1], line[2], line[3], line[4], line[5], line[6], line[7], line[8], line[9])
end

-- Tracked recipes ------------------------------------------------------------------------
-- RT <recipeID> <1 tracked or 0 untracked> <s on the session baseline>
-- <1 for a recraft list>. The event does not say whether a recipe is a recraft.

local tracked = {}

function H.TRACKED_RECIPE_UPDATE(recipeID, isTracked)
    if not Num(recipeID) or not Plain(isTracked) then return end
    local on = isTracked and true or false
    if tracked[recipeID] == on then return end
    tracked[recipeID] = on
    SpellName(recipeID)
    Emit("RT", recipeID, on and 1 or 0, "", "")
end

local function TrackedBaseline()
    if not TSUI then return end
    for _, recraft in ipairs({ false, true }) do
        local list = Call(TSUI.GetRecipesTracked, recraft)
        if type(list) == "table" then
            for _, id in ipairs(list) do
                if Num(id) and not tracked[id] then
                    tracked[id] = true
                    SpellName(id)
                    Emit("RT", id, 1, "s", recraft and 1 or "")
                end
            end
        end
    end
end

-- Profession gear ------------------------------------------------------------------------
-- PG <slot> <itemID or 0> <profession> <skillLineID>: a tool or accessory slot
-- changed. profession is the client's Profession enum. G records the same
-- change without the profession.

function H.PLAYER_EQUIPMENT_CHANGED(slot)
    if not Num(slot) or not TSUI then return end
    local prof = Num(Call(TSUI.GetProfessionByInventorySlot, slot))
    if not prof then return end
    local id = _G.GetInventoryItemID and _G.GetInventoryItemID("player", slot)
    local itemID = Num(id) or 0
    local line = ""
    if itemID > 0 then
        ItemName(itemID)
        line = Num(Call(TSUI.GetSkillLineForGear, itemID)) or ""
        SkillName(line)
    end
    Emit("PG", slot, itemID, prof, line)
end

-- Specializations ------------------------------------------------------------------------
-- PS <skillLineID> <unspent>: the specialization points available for a
-- profession line. The change itself is also a CU line for the knowledge
-- currency. PU <skillLineID> <tradeSkillID>: the line's specializations unlocked.

local specLast = {}
local specPending = false

local function SpecScan()
    specPending = false
    if not SPECS then return end
    local line = Num(Call(SPECS.GetDefaultSpecSkillLine))
    if not line then return end -- no profession line is current
    local cur = Call(SPECS.GetCurrencyInfoForSkillLine, line)
    local unspent = type(cur) == "table" and Num(cur.numAvailable)
    if not unspent or specLast[line] == unspent then return end
    specLast[line] = unspent
    SkillName(line)
    Emit("PS", line, unspent)
end

function H.SKILL_LINE_SPECS_RANKS_CHANGED()
    if specPending then return end
    specPending = true
    -- The currency count settles a moment after the ranks change.
    C_Timer.After(1, SpecScan)
end

function H.SKILL_LINE_SPECS_UNLOCKED(skillLineID, tradeSkillID)
    if not Num(skillLineID) then return end
    SkillName(skillLineID)
    Emit("PU", skillLineID, Num(tradeSkillID) or "")
end

-- Crafting orders ------------------------------------------------------------------------
-- PO <profession> <count> <name>: personal orders waiting for you, per
-- profession; count 0 when a profession's orders are gone. CO <orderType>
-- <item> <quantity> <tip>: you fulfilled an order. The customer's name is
-- never recorded.

local orderCount, orderName = {}, {}

local function Orders()
    if not ORDERS then return end
    local infos = Call(ORDERS.GetPersonalOrdersInfo)
    if type(infos) ~= "table" then return end
    local now = {}
    for _, info in ipairs(infos) do
        if type(info) == "table" and Num(info.profession) and Num(info.numPersonalOrders) then
            local prof, n = info.profession, info.numPersonalOrders
            now[prof] = true
            orderName[prof] = Str(info.professionName) or orderName[prof]
            if orderCount[prof] ~= n then
                orderCount[prof] = n
                Emit("PO", prof, n, orderName[prof] or "")
            end
        end
    end
    for prof, n in pairs(orderCount) do
        if not now[prof] and n ~= 0 then
            orderCount[prof] = 0
            Emit("PO", prof, 0, orderName[prof] or "")
        end
    end
end

H.CRAFTINGORDERS_UPDATE_PERSONAL_ORDER_COUNTS = Orders

function H.CRAFTINGORDERS_DISPLAY_CRAFTER_FULFILLED_MSG(orderType, itemName, _, tip, quantity)
    Emit("CO", Str(orderType) or "", Str(itemName) or "", Num(quantity) or 1, Num(tip) or 0)
end

-- Session start --------------------------------------------------------------------------

local entered = false
function H.PLAYER_ENTERING_WORLD()
    if entered then return end
    entered = true
    C_Timer.After(5, function()
        TrackedBaseline()
        Orders()
    end)
end

ns.Listen(frame, H, "Professions")
