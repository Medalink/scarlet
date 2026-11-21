-- Track.lua: the trackers beyond movement, auras, casts and bags. Same rules
-- as Capture.lua: event driven, player only, every client value through
-- Plain() before it is compared or indexed. Codes are in docs/FORMAT.md.
local _, ns = ...

local floor, type, tonumber, pcall = math.floor, type, tonumber, pcall
local GetTime = GetTime
local Emit, Add, Plain = ns.Emit, ns.Add, ns.Plain
local SpellName, MapPoint, NpcID, Pattern = ns.SpellName, ns.MapPoint, ns.NpcID, ns.Pattern
local Round1, TimerOn, TimerOff = ns.Round1, ns.TimerOn, ns.TimerOff

local frame = CreateFrame("Frame")
local H = {}

local function Str(v) return Plain(v) and type(v) == "string" and v ~= "" and v or nil end

-- Damage meter ---------------------------------------------------------------------
-- The client's own meter replaces the combat log, which Forever blocks. After
-- each fight, out of combat (its values are secret in combat): your totals per
-- meter type (DM), your top spells for damage and healing (DS), and each other
-- group member's total (DP).

local DM = C_DamageMeter
local METERS = { -- letter, Enum.DamageMeterType field, stat key, top spells
    { "d", "DamageDone", "damage", true },
    { "h", "HealingDone", "healing", true },
    { "t", "DamageTaken", "damageTaken", false },
    { "a", "Absorbs", "absorbs", false },
    { "i", "Interrupts", "interrupts", false },
    { "x", "Dispels", "dispels", false },
}
local TOP_SPELLS, TOP_SOURCES = 5, 10
local spellRows = {}

local function TopSpells(letter, current, meterType, guid)
    local ok, src = pcall(DM.GetCombatSessionSourceFromType, current, meterType, guid)
    if not ok or type(src) ~= "table" or type(src.combatSpells) ~= "table" then return end
    wipe(spellRows)
    for _, sp in ipairs(src.combatSpells) do
        if Plain(sp.spellID) and Plain(sp.totalAmount) and sp.totalAmount > 0 then
            spellRows[#spellRows + 1] = sp
        end
    end
    table.sort(spellRows, function(a, b) return a.totalAmount > b.totalAmount end)
    for i = 1, math.min(TOP_SPELLS, #spellRows) do
        local sp = spellRows[i]
        SpellName(sp.spellID)
        Emit("DS", letter, sp.spellID, floor(sp.totalAmount))
    end
end

local function MeterSnapshot()
    if not DM or not DM.GetCombatSessionFromType or InCombatLockdown() then return end
    local okA, available = pcall(DM.IsDamageMeterAvailable)
    if not okA or not available then return end
    local current = Enum.DamageMeterSessionType and Enum.DamageMeterSessionType.Current
    if not current or not Enum.DamageMeterType then return end
    local guid = UnitGUID("player")
    local grouped = IsInGroup()
    grouped = Plain(grouped) and grouped or false
    for _, m in ipairs(METERS) do
        local letter, typeName, stat, top = m[1], m[2], m[3], m[4]
        local meterType = Enum.DamageMeterType[typeName]
        local ok, s = false, nil
        if meterType then ok, s = pcall(DM.GetCombatSessionFromType, current, meterType) end
        if ok and type(s) == "table" and type(s.combatSources) == "table" then
            local secs = Plain(s.durationSeconds) and s.durationSeconds or 0
            local others = 0
            for _, src in ipairs(s.combatSources) do
                local total = src.totalAmount
                if Plain(total) and total and total > 0 then
                    if src.isLocalPlayer then
                        local per = Plain(src.amountPerSecond) and src.amountPerSecond or 0
                        Emit("DM", letter, floor(total), Round1(per), Round1(secs or 0))
                        Add(stat, total)
                        if top then TopSpells(letter, current, meterType, guid) end
                    elseif grouped and others < TOP_SOURCES and Plain(src.sourceDisplayType)
                        and src.sourceDisplayType ~= 2 then -- 2 is Enum.DamageMeterSourceDisplayType.Enemy
                        local name = Str(src.name)
                        if name then
                            others = others + 1
                            Emit("DP", letter, name, Str(src.classFilename) or "", floor(total))
                        end
                    end
                end
            end
        end
    end
end

function H.PLAYER_REGEN_ENABLED()
    C_Timer.After(0.3, MeterSnapshot)
end

-- Deaths, resurrections ---------------------------------------------------------

-- The last hits before death, from the client's death recap. The list is newest first:
-- entry 1 is the killing blow (Forever's own recap marks it causedDeath). Its event table
-- is undocumented, so every field is read defensively.
local RECAP_HITS = 3

-- Who could have killed you: the units you can see when you die. Read at PLAYER_DEAD, since the recap
-- arrives a second later, and matched to the killing blow's source name. A creature keeps its level and
-- classification, a player its level, class, race and guild.
local KILLER_UNITS = { "target", "focus", "mouseover", "pettarget" }
for i = 1, 4 do KILLER_UNITS[#KILLER_UNITS + 1] = "party" .. i .. "target" end
for i = 1, 40 do
    KILLER_UNITS[#KILLER_UNITS + 1] = "nameplate" .. i
    KILLER_UNITS[#KILLER_UNITS + 1] = "raid" .. i .. "target"
end
local killers = {}

local function Look(unit)
    local exists = UnitExists(unit)
    if not Plain(exists) or not exists then return end
    local name = Str(UnitName(unit))
    if not name or killers[name] then return end
    local isPlayer = UnitIsPlayer(unit)
    if not Plain(isPlayer) then return end
    local lv = UnitLevel(unit)
    local level = Plain(lv) and type(lv) == "number" and lv or ""
    if isPlayer then
        killers[name] = { "p", level, Str(select(2, UnitClass(unit))) or "", Str(select(2, UnitRace(unit))) or "",
            Str((_G.GetGuildInfo(unit))) or "" }
    else
        killers[name] = { "c", level, Str(UnitClassification(unit)) or "", "", "" }
    end
end

local function LookAround()
    wipe(killers)
    for i = 1, #KILLER_UNITS do Look(KILLER_UNITS[i]) end
end

local function DeathRecap()
    local recap = C_DeathRecap
    if not recap or not recap.GetRecapEvents then return end
    local ok, events = pcall(recap.GetRecapEvents)
    if not ok or not Plain(events) or type(events) ~= "table" then return end
    local okMax, maxHP = pcall(recap.GetRecapMaxHealth)
    maxHP = okMax and Plain(maxHP) and type(maxHP) == "number" and maxHP or ""
    local function N(v) return Plain(v) and type(v) == "number" and v or "" end
    -- Seconds before death are counted from the killing blow's timestamp (entry 1).
    local first = events[1]
    local last = Plain(first) and type(first) == "table" and N(first.timestamp) or ""
    last = last ~= "" and last or 0
    for i = 1, math.min(#events, RECAP_HITS) do
        local e = events[i]
        if Plain(e) and type(e) == "table" then
            local spell = e.spellId or e.spellID
            local amount, src = e.amount, e.sourceName
            if Plain(spell) and spell then SpellName(spell) end
            local t = N(e.timestamp)
            local who = Str(src)
            local k = i == 1 and who and killers[who]
            local when = (t ~= "" and last > 0) and ns.Round1(last - t) or ""
            if i == 1 then
                -- The killing blow also carries who it came from, when that unit was in sight, and the
                -- number of hits the recap holds.
                Emit("DR", Plain(spell) and spell or "?", Plain(amount) and amount or "?",
                    who or "", Plain(e.isEnvironmental) and e.isEnvironmental and 1 or 0,
                    i, N(e.overkill), N(e.currentHP), maxHP, when, N(e.school),
                    k and k[1] or "", k and k[2] or "", k and k[3] or "", k and k[4] or "", k and k[5] or "", #events)
            else
                Emit("DR", Plain(spell) and spell or "?", Plain(amount) and amount or "?",
                    who or "", Plain(e.isEnvironmental) and e.isEnvironmental and 1 or 0,
                    i, N(e.overkill), N(e.currentHP), maxHP, when, N(e.school))
            end
        end
    end
end

function H.PLAYER_DEAD()
    local m, x, y = MapPoint()
    Emit("DL", m, x, y)
    LookAround()
    ns.AutoShot("de")
    C_Timer.After(1, function()
        pcall(DeathRecap)
        wipe(killers)
    end)
end

-- Currencies, with the client's reason for each change -----------------------------

local currencyNamed = {}
function H.CURRENCY_DISPLAY_UPDATE(currency, quantity, change, gainSource, destroyReason)
    if not Plain(currency) or not Plain(change) or not currency or not change or change == 0 then return end
    if not currencyNamed[currency] then
        currencyNamed[currency] = true
        local info = C_CurrencyInfo.GetCurrencyInfo(currency)
        if type(info) == "table" and Str(info.name) then Emit("CN", currency, info.name) end
    end
    Emit("CU", currency, change, Plain(quantity) and quantity or "?", Plain(gainSource) and gainSource or "",
        Plain(destroyReason) and destroyReason or "")
end

-- Crafting -------------------------------------------------------------------------
-- TS: a profession window opened (with the profession and its skill) or closed.
-- CB: a craft started. CR: what it made. CW: currency it paid. CS: the craft
-- (or a queue of them) stopped. Reagents used and items made also appear as
-- I lines with where `c`; skill gains as SK and SL lines.

local TSUI = C_TradeSkillUI
local craftRecipe, craftT, tsOpen
local tsGen = 0
local function B(v) return Plain(v) and v and 1 or 0 end
local function N(v) return Plain(v) and type(v) == "number" and v or "" end

local function Profession()
    if not TSUI then return end
    for _, get in ipairs({ TSUI.GetChildProfessionInfo, TSUI.GetBaseProfessionInfo }) do
        local ok, info = pcall(get)
        if ok and type(info) == "table" and Plain(info.professionID) and info.professionID
            and info.professionID ~= 0 then
            return info
        end
    end
end

function H.TRADE_SKILL_SHOW()
    if tsOpen then return end
    tsOpen = true
    -- The profession's details arrive a moment after the window opens.
    tsGen = tsGen + 1
    local gen = tsGen
    C_Timer.After(0.5, function()
        -- Closed or reopened meanwhile: that later open or close owns the line.
        if not tsOpen or gen ~= tsGen then return end
        local p = Profession()
        if not p then
            Emit("TS", 1)
            return
        end
        Emit("TS", 1, p.professionID, Str(p.professionName) or "", N(p.skillLevel), N(p.maxSkillLevel),
            N(p.skillModifier), N(p.parentProfessionID))
    end)
end

function H.TRADE_SKILL_CLOSE()
    if not tsOpen then return end
    tsOpen = false
    Emit("TS", 0)
end

function H.TRADE_SKILL_CRAFT_BEGIN(recipeSpellID)
    if not Plain(recipeSpellID) or not recipeSpellID then return end
    craftRecipe, craftT = recipeSpellID, GetTime()
    SpellName(recipeSpellID)
    Emit("CB", recipeSpellID)
end

function H.UPDATE_TRADESKILL_CAST_STOPPED(isScrapping)
    Emit("CS", B(isScrapping))
end

-- The payload has no recipe, so CR takes the last CB's while that craft is
-- current. Using an item on gear (a fishing lure, a weapon oil) also sends this
-- event with isEnchant and no CB: no recipe then, and it is not counted as a craft.
local CRAFT_CURRENT = 15
function H.TRADE_SKILL_ITEM_CRAFTED_RESULT(data)
    if type(data) ~= "table" or not Plain(data.itemID) or not data.itemID then return end
    local qty = Plain(data.quantity) and data.quantity or 1
    ns.ItemName(data.itemID)
    local returned = Plain(data.resourcesReturned) and type(data.resourcesReturned) == "table"
        and #data.resourcesReturned or 0
    -- Each result extends the window, so a long batch keeps its recipe while an
    -- open profession window alone does not (a lure applied there is no craft).
    local current = craftT and GetTime() - craftT < CRAFT_CURRENT
    if current then craftT = GetTime() end
    Emit("CR", data.itemID, qty, B(data.isCrit), Plain(data.multicraft) and data.multicraft or 0,
        current and craftRecipe or "", N(data.craftingQuality), B(data.bonusCraft), N(data.concentrationSpent),
        B(data.hasIngenuityProc), B(data.firstCraftReward), returned, B(data.isEnchant))
    if current then Add("crafted", qty) end
end

function H.TRADE_SKILL_CURRENCY_REWARD_RESULT(data)
    if type(data) ~= "table" or not Plain(data.currencyID) or not data.currencyID then return end
    Emit("CW", data.currencyID, N(data.quantity), B(data.firstCraftReward), craftRecipe or "")
end

-- Crowd control taken: stuns, fears, roots, silences --------------------------------

function H.LOSS_OF_CONTROL_ADDED(_, index)
    local loc = C_LossOfControl
    if not loc or not loc.GetActiveLossOfControlDataByUnit then return end
    local ok, d = pcall(loc.GetActiveLossOfControlDataByUnit, "player", index)
    if not ok or type(d) ~= "table" then return end
    local spell, dur = d.spellID, d.duration
    if Plain(spell) and spell then SpellName(spell) end
    -- Forever hides locType, spell and duration while control is restricted; priority and
    -- displayType are never secret.
    Emit("CC", Str(d.locType) or "?", Plain(spell) and spell or "?", Plain(dur) and Round1(dur or 0) or "?",
        Plain(d.priority) and d.priority or "", Plain(d.displayType) and d.displayType or "")
    Add("ccTaken")
end

-- New collectibles -----------------------------------------------------------------

local function Collected(kind, id, name)
    Emit("NC", kind, id or "", Str(name) or "")
    Add("collected")
    ns.AutoShot("nc")
end

function H.NEW_MOUNT_ADDED(mountID)
    local name
    if Plain(mountID) and C_MountJournal and C_MountJournal.GetMountInfoByID then
        name = C_MountJournal.GetMountInfoByID(mountID)
    end
    Collected("mount", Plain(mountID) and mountID, name)
end

function H.NEW_TOY_ADDED(itemID)
    if Plain(itemID) then ns.ItemName(itemID) end
    Collected("toy", Plain(itemID) and itemID)
end

function H.NEW_PET_ADDED() Collected("pet") end
function H.COMPANION_LEARNED() Collected("companion") end

-- The client also sends this while logging in, so only later ones count.
local titlesReady = false
function H.KNOWN_TITLES_UPDATE()
    if titlesReady then Collected("title") end
end

function H.RESURRECT_REQUEST(inviter)
    Emit("RZ", Str(inviter) or "?")
    Add("rezzes")
end

function H.CONFIRM_XP_LOSS()
    Emit("SH")
    Add("spiritRez")
end

-- Duels: started by request, settled by the system message --------------------

local DUEL_KO = Pattern(_G.DUEL_WINNER_KNOCKOUT)   -- "%1$s has defeated %2$s in a duel"
local DUEL_FLED = Pattern(_G.DUEL_WINNER_RETREAT)  -- "%2$s has fled from %1$s in a duel"
local EXPLORED_XP = Pattern(_G.ERR_ZONE_EXPLORED_XP) -- "Discovered %s: %d experience gained"
local EXPLORED = Pattern(_G.ERR_ZONE_EXPLORED)       -- "Discovered: %s"
local me

function H.DUEL_REQUESTED(name)
    Emit("DU", Str(name) or "?")
end

local function Duel(winner, loser)
    if winner == me then
        Emit("DW", 1, loser)
        Add("duelsWon")
        ns.AutoShot("dw")
    elseif loser == me then
        Emit("DW", 0, winner)
        Add("duelsLost")
    end
end

local lastExplore
local function Explore(text)
    if text == lastExplore then return end
    if EXPLORED_XP then
        local area, xp = text:match(EXPLORED_XP)
        if area then
            lastExplore = text
            Emit("EX", area, xp)
            ns.XPSource("e", "")
            Add("discoveries")
            return
        end
    end
    if EXPLORED then
        local area = text:match(EXPLORED)
        if area then
            lastExplore = text
            Emit("EX", area, 0)
            Add("discoveries")
        end
    end
end

function H.CHAT_MSG_SYSTEM(text)
    text = Str(text)
    if not text then return end
    if DUEL_KO then
        local w, l = text:match(DUEL_KO)
        if w then Duel(w, l) return end
    end
    if DUEL_FLED then
        local l, w = text:match(DUEL_FLED)
        if l then Duel(w, l) return end
    end
    Explore(text)
end

function H.UI_INFO_MESSAGE(_, message)
    message = Str(message)
    if message then Explore(message) end
end

-- XP detail: the rested bonus on each kill -----------------------------------------

function H.CHAT_MSG_COMBAT_XP_GAIN(text)
    text = Str(text)
    if not text then return end
    local bonus = tonumber(text:match("%+(%d+)[^%d]-[Rr]ested"))
    if bonus then
        Emit("XR", bonus)
        Add("restedXP", bonus)
    end
end

-- Breath, fatigue, feign death timers --------------------------------------------

local mirror = {}
function H.MIRROR_TIMER_START(name)
    name = Str(name)
    if not name or mirror[name] then return end
    mirror[name] = GetTime()
    Emit("MT", 1, name)
    if name == "BREATH" then TimerOn("breathTime") end
end

function H.MIRROR_TIMER_STOP(name)
    name = Str(name)
    local t0 = name and mirror[name]
    if not t0 then return end
    mirror[name] = nil
    Emit("MT", 0, name, Round1(GetTime() - t0))
    if name == "BREATH" then TimerOff("breathTime") end
end

-- Durability and repairs -----------------------------------------------------------

local GetDurability = _G.GetInventoryItemDurability
local GetRepairCost = _G.GetRepairAllCost
local lastAvg, lastBroken = nil, 0
local merchant, repairCost = false, 0

local function Durability()
    if not GetDurability then return end
    local sum, n, low, broken = 0, 0, 100, 0
    for slot = 1, 19 do
        local cur, max = GetDurability(slot)
        if Plain(cur) and Plain(max) and cur and max and max > 0 then
            local pct = cur / max * 100
            sum, n = sum + pct, n + 1
            if pct < low then low = pct end
            if cur == 0 then broken = broken + 1 end
        end
    end
    if n == 0 then return end
    local avg = floor(sum / n + 0.5)
    if not lastAvg or math.abs(avg - lastAvg) >= 5 or broken ~= lastBroken then
        lastAvg, lastBroken = avg, broken
        Emit("DB", avg, floor(low + 0.5), broken)
    end
end

local function RepairCost()
    if not GetRepairCost then return 0 end
    local cost = GetRepairCost()
    return Plain(cost) and cost or 0
end

-- A repair is seen when the cost the vendor showed drops to 0 and money moved while the vendor was
-- open. The client reports the durability change and the money change in either order (the real
-- order is durability first), so the last positive cost is kept and a 0 never replaces it.
local moneyMoved = false

local function Settle()
    if merchant and moneyMoved and repairCost > 0 and RepairCost() == 0 then
        Emit("RE", repairCost)
        Add("repairs", repairCost)
        repairCost, moneyMoved = 0, false
    end
end

function H.UPDATE_INVENTORY_DURABILITY()
    Durability()
    if not merchant then return end
    local cost = RepairCost()
    if cost > 0 then repairCost = cost end
    Settle()
end

function H.PLAYER_MONEY()
    if not merchant then return end
    moneyMoved = true
    Settle()
end

-- Talking to NPCs: gossip, vendors, flight masters, trainers, bank, mail, auction --

local function Npc(kind)
    local guid = UnitGUID("npc")
    local id = Plain(guid) and guid and NpcID(guid) or ""
    -- faction: the NPC's side (Horde or Alliance, empty for neutral); repair: whether a vendor can repair.
    local faction = Str(UnitFactionGroup("npc")) or ""
    local repair = ""
    if kind == "v" and _G.CanMerchantRepair then
        local can = _G.CanMerchantRepair()
        if Plain(can) then repair = can and 1 or 0 end
    end
    local name = Str(UnitName("npc")) or ""
    if id == "" and name == "" then return end -- a quest from an item or a popup, no NPC
    Emit("NI", kind, id, name, faction, repair)
    Add("npcTalks")
end

function H.GOSSIP_SHOW() Npc("g") end
function H.MERCHANT_SHOW()
    merchant, repairCost, moneyMoved = true, RepairCost(), false
    Npc("v")
end
function H.MERCHANT_CLOSED() merchant = false end
function H.TAXIMAP_OPENED() Npc("f") end
function H.TRAINER_SHOW() Npc("t") end
function H.BANKFRAME_OPENED() Npc("b") end
function H.AUCTION_HOUSE_SHOW() Npc("a") end
function H.QUEST_DETAIL() Npc("q") end

-- Quests: names, and quests dropped without a turn-in ------------------------------

local turnedIn, removed = {}, {}

function H.QUEST_ACCEPTED(questID)
    if not Plain(questID) then return end
    local title = C_QuestLog.GetTitleForQuestID(questID)
    if Str(title) then Emit("QN", questID, title) end
end

function H.QUEST_TURNED_IN(questID)
    if Plain(questID) then turnedIn[questID] = GetTime() end
end

local function SettleRemoved()
    local now = GetTime()
    for questID, t in pairs(removed) do
        if now - t >= 1 then
            removed[questID] = nil
            local done = turnedIn[questID]
            turnedIn[questID] = nil
            if not done or math.abs(done - t) > 3 then
                Emit("Q", 3, questID)
                Add("abandoned")
            end
        end
    end
end

function H.QUEST_REMOVED(questID)
    if not Plain(questID) then return end
    removed[questID] = GetTime()
    C_Timer.After(1.5, SettleRemoved)
end

-- Learning: spells, recipes, talent points, hearthstone ----------------------------

function H.LEARNED_SPELL_IN_SKILL_LINE(spellID)
    if not Plain(spellID) then return end
    SpellName(spellID)
    Emit("LS", spellID)
    Add("spellsLearned")
end

function H.NEW_RECIPE_LEARNED(recipeID)
    if not Plain(recipeID) then return end
    SpellName(recipeID)
    Emit("LR", recipeID)
    Add("recipes")
end

function H.CHARACTER_POINTS_CHANGED(change)
    Emit("TL", change)
end

function H.HEARTHSTONE_BOUND()
    Emit("HB", Str(GetBindLocation()) or "")
end

-- PvP: honor, honorable kills, flagged time ---------------------------------------

local lastHK
local function HonorKills()
    local hk = GetPVPLifetimeStats()
    if not Plain(hk) or type(hk) ~= "number" then return end
    if lastHK and hk > lastHK then
        Emit("HK", hk, hk - lastHK)
        Add("honorKills", hk - lastHK)
    end
    lastHK = hk
end
H.PLAYER_PVP_KILLS_CHANGED = HonorKills

-- The honorable kill messages name the victim and, with a rank system, the victim's rank:
-- "<name> dies, honorable kill Rank: <rank> (Estimated Honor Points: <n>)".
local HONOR_RANK = Pattern(_G.COMBATLOG_HONORGAIN)
local HONOR_NO_RANK = Pattern(_G.COMBATLOG_HONORGAIN_NO_RANK)

function H.CHAT_MSG_COMBAT_HONOR_GAIN(text)
    text = Str(text)
    local n = text and tonumber(text:match("(%d+)%s+[Hh]onor") or text:match("[Hh]onor[^%d]*(%d+)"))
    if n then
        local victim, rank = "", ""
        if HONOR_RANK then
            local v, r = text:match(HONOR_RANK)
            if v then victim, rank = v, r end
        end
        if victim == "" and HONOR_NO_RANK then victim = text:match(HONOR_NO_RANK) or "" end
        Emit("HN", n, victim, rank)
        Add("honor", n)
    end
end

local pvp
local function PvPFlag()
    local on = UnitIsPVP("player")
    if not Plain(on) then return end
    on = on and true or false
    if on == pvp then return end
    pvp = on
    Emit("PV", on and 1 or 0)
    if on then TimerOn("pvpTime") else TimerOff("pvpTime") end
end
H.PLAYER_FLAGS_CHANGED = PvPFlag

-- Pet, screenshots, time played ---------------------------------------------------

local lastPet
function H.UNIT_PET()
    local name = Str(UnitName("pet")) or ""
    local family = Str(UnitCreatureFamily("pet")) or ""
    local key = name .. "|" .. family
    if key == lastPet then return end
    lastPet = key
    Emit("PT", name, family)
end

-- SS <file> <trigger>: the client names the file WoWScrnShot_MMDDYY_HHMMSS.<format> (the format is
-- the screenshotFormat setting). The event does not give the name, so it is rebuilt from the
-- time and can be a second off. trigger `c` when a Screenshot() call was seen in the 10 seconds
-- before (a key, macro or another addon), empty when none was. The third field is the moment Scarlet
-- took it for (Shots.lua, only when the setting is on), empty for any other screenshot.
local shotCall = -100
if type(_G.Screenshot) == "function" then
    hooksecurefunc("Screenshot", function()
        if not ns.shooting then shotCall = GetTime() end
    end)
end

function H.SCREENSHOT_SUCCEEDED()
    local ext = _G.C_CVar and Str(_G.C_CVar.GetCVar("screenshotFormat")) or "jpg"
    local trigger = ns.shotTrigger and GetTime() - ns.shotT < 5 and ns.shotTrigger or ""
    ns.shotTrigger = nil
    Emit("SS", date("WoWScrnShot_%m%d%y_%H%M%S") .. "." .. ext, GetTime() - shotCall < 10 and "c" or "", trigger)
    Add("screenshots")
end

function H.SCREENSHOT_FAILED()
    ns.shotTrigger = nil
end

-- Other addons ask for /played too, so one login can answer three times;
-- an answer within a few seconds of the last one written is dropped.
local lastPlayed
function H.TIME_PLAYED_MSG(total, thisLevel)
    if not Plain(total) or type(total) ~= "number" then return end
    if lastPlayed and math.abs(total - lastPlayed) < 5 then return end
    lastPlayed = total
    Emit("TP", total, thisLevel)
    ns.Ov.Played(total)
    if ns.char then
        ns.char.played = total
        -- At the cap, the client's seconds on this level are the time at max level.
        if ns.Cap.atCap and type(thisLevel) == "number" and Plain(thisLevel) then ns.char.capSecs = thisLevel end
    end
end

-- Loot rolls you make: 0 pass, 1 need, 2 greed -------------------------------------

if _G.RollOnLoot and _G.GetLootRollItemLink then
    hooksecurefunc("RollOnLoot", function(rollID, rollType)
        local link = _G.GetLootRollItemLink(rollID)
        local id = Str(link) and tonumber(link:match("|Hitem:(%d+)"))
        Emit("RL", rollType, id or "")
        Add("rolls")
    end)
end

-- Character snapshot at login and each level --------------------------------------

local function Snapshot()
    local st = {}
    for i = 1, 5 do
        local _, value = UnitStat("player", i)
        st[i] = Plain(value) and value or "?"
    end
    local _, armor = UnitArmor("player")
    local avgIlvl = _G.GetAverageItemLevel and select(2, _G.GetAverageItemLevel()) or ""
    Emit("ST", UnitLevel("player"), GetMoney(), st[1], st[2], st[3], st[4], st[5], armor, UnitHealthMax("player"),
        UnitPowerMax("player"), Plain(avgIlvl) and avgIlvl or "?")
end

function H.PLAYER_LEVEL_UP()
    C_Timer.After(1, Snapshot)
end

local entered = false
function H.PLAYER_ENTERING_WORLD()
    if entered then return end
    entered = true
    local name = UnitName("player")
    me = Plain(name) and name or nil
    local rules = C_GameRules
    if rules then
        local okP, preset = pcall(rules.GetForeverExperiencePreset)
        local okH, hardcore = pcall(rules.IsHardcoreActive)
        Emit("GR", okP and preset or "", okH and (hardcore and 1 or 0) or "")
    end
    local hk = GetPVPLifetimeStats()
    if Plain(hk) then lastHK = hk end
    PvPFlag()
    H.UNIT_PET()
    Durability()
    C_Timer.After(2, Snapshot)
    C_Timer.After(10, function() titlesReady = true end)
end

function H.PLAYER_LOGOUT()
    for name, t0 in pairs(mirror) do
        mirror[name] = nil
        Emit("MT", 0, name, Round1(GetTime() - t0))
    end
end

-- The rested bonus line only exists while levelling (ns.Cap, Core.lua).
ns.Listen(frame, H, "Track", { CHAT_MSG_COMBAT_XP_GAIN = true })
ns.Cap.Watch(frame, { "CHAT_MSG_COMBAT_XP_GAIN" })
