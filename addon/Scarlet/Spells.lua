-- Spells.lua: the spellbook and how spells are learned and used, beyond Capture's casts (C, CH, CI, SN) and
-- Track's learned-spell line (LS):
--   SB  the spellbook: a baseline once a day, then spells added and removed, with ranks, for the
--       player and for the current pet
--   AB  an action bar slot changed: what is on the bars, with a flag for a spell that is not its highest rank
--   TB  a trainer purchase the client accepted: the service, its rank and its cost
--   SG  the stable: slots, pets in the stable and the cost of the next slot
--   AR  auto repeat (Auto Shot, wand) switched on or off, with how long it ran
--   SO  a spell proc glow (an ability the client lit up) started or ended
--   EC  an enchant spell finished on an item
-- Codes are in docs/FORMAT.md. Event driven only, nothing on a timer; every client value goes
-- through Plain() before it is compared or used. The spellbook and the bars are read after a
-- debounce, out of combat, and written only when they differ from what this character last
-- wrote (kept in ns.char, so a login does not repeat it). Forever lists every rank in the book
-- (the book window hides the low ranks in Lua), so the diff keys on the spell id alone. No
-- other player's spells, no retail-only systems (assisted combat, spell flyouts, the spell
-- diminish tracker) and no cooldown or range polling.
local _, ns = ...

local type, pcall, pairs = type, pcall, pairs
local concat, sort = table.concat, table.sort
local Emit, Plain = ns.Emit, ns.Plain
local SpellName, ItemName, Round1, NpcID = ns.SpellName, ns.ItemName, ns.Round1, ns.NpcID

local SB = C_SpellBook
local SPELL = C_Spell
local ACTION = C_ActionBar
local STABLE = C_StableInfo

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
-- Index it only through Str, Num and Flag.
local function Pack(fn, ...)
    if type(fn) ~= "function" then return end
    local r = { pcall(fn, ...) }
    if r[1] then return r end
end

-- Per-character state kept in SavedVariables: sb (the spells last seen, id -> "rank|line", the
-- count, the pet they belong to and the day of the last baseline) and bar (what each action
-- slot held).
local function Store()
    local ch = ns.char
    if not ch then return end
    local s = ch.sb
    if type(s) ~= "table" then
        s = {}
        ch.sb = s
    end
    if type(ch.bar) ~= "table" then ch.bar = { slots = {} } end
    return s
end

local started = false
local tries = 0
local MAX_TRIES = 4

-- Spellbook ----------------------------------------------------------------------------
-- SB <kind> <bank> <line> <spells>. kind `b` a baseline (the first read for a character, then
-- once a day), `a` spells added, `x` spells removed. bank `p` the player's book, `t` the
-- current pet's. line is the skill line's name (General, the class, a specialization) or, for
-- the pet, its name. spells is `spellID:rank` comma-joined, the rank (from the spell's
-- subtext, "Rank 3") left off when the spell has none. Names go out as SN. A spell learned
-- from a trainer or a level also writes LS; this line is what the book then holds. A hunter's
-- pet only gets a baseline when it is a different pet than the last one read, so a dismissed
-- pet writes no removals.

local SPELL_TYPE = _G.Enum and _G.Enum.SpellBookItemType and _G.Enum.SpellBookItemType.Spell or 1
local PLAYER_BANK = _G.Enum and _G.Enum.SpellBookSpellBank and _G.Enum.SpellBookSpellBank.Player or 0
local PET_BANK = _G.Enum and _G.Enum.SpellBookSpellBank and _G.Enum.SpellBookSpellBank.Pet or 1
local MAX_SPELLS = 800

local function Rank(sub)
    local s = Str(sub)
    local n = s and s:match("(%d+)")
    return n and tonumber(n) or ""
end

-- Reads `count` items of a bank starting after `offset` into vals (id -> "rank|line") and ids.
local function ReadItems(bank, offset, count, line, ids, vals)
    for i = 1, count do
        if #ids >= MAX_SPELLS then return end
        local info = Call(SB.GetSpellBookItemInfo, offset + i, bank)
        if type(info) == "table" and Num(info.itemType) == SPELL_TYPE
            and not (Plain(info.isOffSpec) and info.isOffSpec) then
            local id = Num(info.spellID) or Num(info.actionID)
            if id and not vals[id] then
                vals[id] = Rank(info.subName) .. "|" .. line
                ids[#ids + 1] = id
            end
        end
    end
end

local function ReadPlayer()
    local n = Num(Call(SB.GetNumSpellBookSkillLines))
    if not n or n < 1 then return end
    local ids, vals = {}, {}
    for li = 1, n do
        local info = Call(SB.GetSpellBookSkillLineInfo, li)
        if type(info) == "table" and not (Plain(info.shouldHide) and info.shouldHide) then
            local offset, count = Num(info.itemIndexOffset), Num(info.numSpellBookItems)
            if offset and count then
                ReadItems(PLAYER_BANK, offset, count, Str(info.name) or ("line" .. li), ids, vals)
            end
        end
    end
    if #ids == 0 then return end
    return ids, vals
end

local function ReadPet()
    local r = Pack(SB.HasPetSpells)
    local count = r and Num(r[2])
    if not count or count < 1 then return end
    local name = Str(Call(_G.UnitName, "pet"))
    if not name then return end
    local ids, vals = {}, {}
    ReadItems(PET_BANK, 0, count, name, ids, vals)
    if #ids == 0 then return end
    return ids, vals, name
end

-- One SB line per skill line in `ids`, which are keyed in `vals`.
local function Put(kind, bank, ids, vals)
    local order, by = {}, {}
    for i = 1, #ids do
        local id = ids[i]
        local rank, line = vals[id]:match("^(%d*)|(.*)$")
        local g = by[line]
        if not g then
            g = {}
            by[line] = g
            order[#order + 1] = line
        end
        g[#g + 1] = rank ~= "" and (id .. ":" .. rank) or tostring(id)
        SpellName(id)
    end
    for i = 1, #order do
        Emit("SB", kind, bank, order[i], concat(by[order[i]], ","))
    end
end

-- The ids in `a` that `b` does not hold, in id order.
local function Missing(a, b)
    local ids = {}
    for id in pairs(a) do
        if not b[id] then ids[#ids + 1] = id end
    end
    sort(ids)
    return ids
end

local queued, due = false, false
local Scan

local function Soon(delay)
    if queued or not started then return end
    queued = true
    C_Timer.After(delay or 3, function()
        queued = false
        Scan()
    end)
end

local function Retry()
    if tries < MAX_TRIES then
        tries = tries + 1
        Soon(10)
    end
end

-- Compares one bank against what was last written and writes the changes. `old` is the saved
-- id -> value table (nil when there is none), `vals` what the client lists now.
local function Compare(bank, old, ids, vals, baseline)
    if old and next(old) ~= nil then
        local gone = Missing(old, vals)
        local added = Missing(vals, old)
        if #added > 0 then Put("a", bank, added, vals) end
        if #gone > 0 then Put("x", bank, gone, old) end
    end
    if baseline or not old then Put("b", bank, ids, vals) end
end

function Scan()
    local s = Store()
    if not s or not SB then return end
    if InCombatLockdown() then
        due = true
        return
    end
    due = false
    local ids, vals = ReadPlayer()
    if not ids then return Retry() end
    -- A book that comes back smaller than the last one, or with ranks the last read had now
    -- blank (subName is empty until the spell's data loads), is a partial read, not an unlearn.
    if (s.n or 0) >= 20 and #ids < s.n * 0.9 and tries < MAX_TRIES then return Retry() end
    if type(s.ids) == "table" and type(vals) == "table" and tries < MAX_TRIES then
        for id, v in pairs(vals) do
            local was = s.ids[id]
            if type(was) == "string" and was:sub(1, 1) ~= "|" and v:sub(1, 1) == "|" then return Retry() end
        end
    end
    tries = 0
    local today = date("%Y%m%d")
    local baseline = s.day ~= today
    Compare("p", s.ids, ids, vals, baseline)
    s.ids, s.n = vals, #ids
    local pids, pvals, pname = ReadPet()
    if pids then
        if s.pet == pname then
            Compare("t", s.pids, pids, pvals, baseline)
        else
            Put("b", "t", pids, pvals)
        end
        s.pet, s.pids = pname, pvals
    end
    s.day = today
end

H.SPELLS_CHANGED = function() Soon(3) end
local TrainerAnswered

H.LEARNED_SPELL_IN_SKILL_LINE = function()
    Soon(3)
    TrainerAnswered(false)
end
H.NEW_RECIPE_LEARNED = function() TrainerAnswered(false) end
H.PLAYER_MONEY = function() TrainerAnswered(true) end
H.UNIT_PET = function() Soon(3) end

-- Action bars --------------------------------------------------------------------------
-- AB <slot> <kind> <id> <oldKind> <oldId> <low> <why>: what an action slot (1 to 72: the
-- main bar, its pages and the side bars; the stance and form bars swap with the aura and are
-- not read) held after a change. kind and id are the client's action type (`spell`, `item`,
-- `macro` with the macro's index, `companion`, `equipmentset`, ...) and id; both are empty
-- when the slot was emptied. low is `1` when the spell on the bar is not its highest rank, `0`
-- when it is. why `s` the first read for the character (every filled slot), `c` a change, `p`
-- the client put a newly learned spell there. Read 4 seconds after the last change, out of
-- combat.

local BAR_SLOTS = 72
local barQueued, barDue = false, false
local pushed = {}

local function Action(slot)
    if not Call(ACTION.HasAction, slot) then return end
    local r = Pack(_G.GetActionInfo, slot)
    local kind = r and Str(r[2])
    local id = r and r[3]
    if not kind or not Plain(id) or (type(id) ~= "number" and type(id) ~= "string") then return end
    return kind, id
end

local function BarScan()
    barQueued = false
    local s = Store()
    if not s or not ACTION then return end
    if InCombatLockdown() then
        barDue = true
        return
    end
    barDue = false
    local bar = ns.char.bar
    local first = not bar.done
    local slots = bar.slots
    for slot = 1, BAR_SLOTS do
        local kind, id = Action(slot)
        local key = kind and (kind .. ":" .. id) or nil
        local was = slots[slot]
        if key ~= was then
            slots[slot] = key
            local oldKind, oldId = "", ""
            if was then oldKind, oldId = was:match("^([^:]*):(.*)$") end
            local low = ""
            if kind == "spell" and type(id) == "number" then
                local hi = Call(ACTION.IsHighestSpellRank, id)
                low = hi == false and 1 or (hi and 0 or "")
                SpellName(id)
            elseif kind == "item" and type(id) == "number" then
                ItemName(id)
            end
            local why = first and "s" or (pushed[slot] and pushed[slot] == id and "p" or "c")
            Emit("AB", slot, kind or "", id or "", oldKind or "", oldId or "", low, why)
        end
    end
    bar.done = true
    for k in pairs(pushed) do pushed[k] = nil end
end

local function BarSoon()
    if barQueued or not started then return end
    barQueued = true
    C_Timer.After(4, BarScan)
end

function H.PLAYER_REGEN_ENABLED()
    if due then Soon(3) end
    if barDue then BarSoon() end
end

function H.ACTIONBAR_SLOT_CHANGED(slot)
    local n = Num(slot)
    -- Slot 0 means every slot changed (Forever's ActionButton.lua reads it that way).
    if n and n >= 0 and n <= BAR_SLOTS then BarSoon() end
end

function H.SPELL_PUSHED_TO_ACTIONBAR(spellID, slot)
    local id, n = Num(spellID), Num(slot)
    if id and n then pushed[n] = id end
    BarSoon()
end

-- Trainer ------------------------------------------------------------------------------
-- TB <npcID> <trainerType> <name> <subText> <copper> <reqLevel>: you asked a trainer to teach
-- a service the client listed as available and you could pay for. name and subText are the
-- trainer list's own text (a spell and its rank, or a recipe); copper is its price; trainerType
-- is the client's (class, tradeskill, pet). The spell or recipe it taught is the LS or LR line
-- after it. The purchase is answered by the server, so the line waits for it: it is written
-- when money drops or a spell or recipe is learned within 5 s, and dropped otherwise.

local bought = {}

local function TrainerNpc()
    local guid = Call(_G.UnitGUID, "npc")
    if type(guid) ~= "string" then return "" end
    local id = NpcID(guid)
    return type(id) == "number" and id or ""
end

if type(_G.BuyTrainerService) == "function" then
    hooksecurefunc("BuyTrainerService", function(index)
        if not Num(index) then return end
        local r = Pack(_G.GetTrainerServiceInfo, index)
        local name = r and Str(r[2])
        if not name or not r or Str(r[3]) ~= "available" then return end
        local cost = Num(Call(_G.GetTrainerServiceCost, index)) or 0
        local have = Num(Call(_G.GetMoney))
        if have and have < cost then return end
        local ttype = C_Trainer and Num(Call(C_Trainer.GetTrainerType)) or ""
        local row = { GetTime(), TrainerNpc(), ttype, name, Str(r[6]) or "", cost, Num(r[5]) or "", have }
        if #bought < 10 then bought[#bought + 1] = row end
    end)
end

-- A money drop confirms the oldest paid purchase still waiting, a spell or recipe learned
-- the oldest free one (a paid one also teaches, but its money line already answered it).
-- Purchases older than 5 s were refused and are dropped.
TrainerAnswered = function(money)
    local now = GetTime()
    while bought[1] and now - bought[1][1] > 5 do table.remove(bought, 1) end
    -- A money answer counts only when the money is now at least the price below what it was
    -- at the purchase (loot, sales and repairs also fire PLAYER_MONEY).
    local now_money = money and Num(Call(_G.GetMoney))
    for i = 1, #bought do
        local row = bought[i]
        local paid = row[6] > 0
        local fits = not money or (now_money and row[8] and now_money <= row[8] - row[6])
        if paid == money and fits then
            Emit("TB", unpack(table.remove(bought, i), 2, 7))
            return
        end
    end
end

-- Trainer catalogue ----------------------------------------------------------------------
-- TC <npcID> <trainerType> <name> <subText> <copper> <reqLevel> <state> <skillLine> <skillReq>
-- <abilityReqs>: every service the trainer lists, read when the window opens or refreshes. state
-- is a available, u unavailable (a requirement is missing) or k already known. The trainer
-- window's own filters decide what is listed; they are never changed. A service is written once
-- per trainer per character and again when its state changes (ns.char.tc, up to TC_CAP keys;
-- past it a service is written once a session). skillReq is `skill:rank`, abilityReqs the
-- abilities it needs joined by " / ".

local TC_CAP = 4000
local TC_SERVICES = 300
local TC_STATE = { available = "a", unavailable = "u", used = "k" }
local tcQueued = false
local tcSession = {}

local function TrainerScan()
    tcQueued = false
    local ch = ns.char
    if not ch or type(_G.GetNumTrainerServices) ~= "function" then return end
    local n = Num(Call(_G.GetNumTrainerServices))
    if not n or n < 1 then return end
    if type(ch.tc) ~= "table" then ch.tc, ch.tcN = {}, 0 end
    local seen = ch.tc
    local npc = TrainerNpc()
    if npc == "" then return end -- the window closed before the scan
    local ttype = C_Trainer and Num(Call(C_Trainer.GetTrainerType)) or ""
    for i = 1, math.min(n, TC_SERVICES) do
        local r = Pack(_G.GetTrainerServiceInfo, i)
        local name = r and Str(r[2])
        local state = r and TC_STATE[Str(r[3]) or ""]
        if name and state then
            local sub = Str(r[6]) or ""
            local key = npc .. "|" .. name .. "|" .. sub
            if seen[key] ~= state and tcSession[key] ~= state then
                tcSession[key] = state
                if seen[key] or (ch.tcN or 0) < TC_CAP then
                    if not seen[key] then ch.tcN = (ch.tcN or 0) + 1 end
                    seen[key] = state
                end
                local skill = Pack(_G.GetTrainerServiceSkillReq, i)
                local req = skill and Str(skill[2]) and (skill[2] .. ":" .. (Num(skill[3]) or "")) or ""
                local abilities = {}
                for j = 1, math.min(Num(Call(_G.GetTrainerServiceNumAbilityReq, i)) or 0, 4) do
                    local a = Str(Call(_G.GetTrainerServiceAbilityReq, i, j))
                    if a then abilities[#abilities + 1] = a end
                end
                Emit("TC", npc, ttype, name, sub, Num(Call(_G.GetTrainerServiceCost, i)) or 0, Num(r[5]) or "",
                    state, Str(Call(_G.GetTrainerServiceSkillLine, i)) or "", req, concat(abilities, " / "))
            end
        end
    end
end

local function TrainerSoon()
    if tcQueued or not started then return end
    tcQueued = true
    C_Timer.After(1, TrainerScan)
end

H.TRAINER_SHOW = TrainerSoon
H.TRAINER_UPDATE = TrainerSoon
H.TRAINER_SERVICE_INFO_NAME_UPDATE = TrainerSoon

-- Stable -------------------------------------------------------------------------------
-- SG <why> <slots> <pets> <nextCost> <list>: the hunter's stable as the client shows it.
-- slots is how many stable slots are unlocked, pets how many pets are stabled, nextCost the
-- copper the next slot costs, list `slot:level:family:name` for each pet including the current
-- one (slot 1). why `s` the first read of the session, `c` a change. Read after the stable
-- window opens or a pet is swapped, and written when the list or the numbers differ from the
-- last SG of the session.

local stableLast, stableQueued = nil, false

local function StableScan()
    stableQueued = false
    if not STABLE then return end
    local slots = Num(Call(STABLE.GetNumStableSlots))
    local pets = Num(Call(STABLE.GetNumStablePets))
    if not slots or not pets then return end
    local cost = Num(Call(STABLE.GetNextStableSlotCost)) or ""
    local const = _G.Constants and _G.Constants.PetConsts
    local last = const and Num(const.NUM_PET_SLOTS_HUNTER) or 5
    local list = {}
    for i = 1, last do
        local info = Call(STABLE.GetStablePetInfo, i)
        if type(info) == "table" and Str(info.name) then
            list[#list + 1] = i .. ":" .. (Num(info.level) or "") .. ":" .. (Str(info.familyName) or "")
                .. ":" .. info.name
        end
    end
    local text = concat(list, ",")
    local sig = slots .. "|" .. pets .. "|" .. cost .. "|" .. text
    if sig == stableLast then return end
    Emit("SG", stableLast and "c" or "s", slots, pets, cost, text)
    stableLast = sig
end

local function StableSoon()
    if stableQueued then return end
    stableQueued = true
    C_Timer.After(1.5, StableScan)
end

H.PET_STABLE_SHOW = StableSoon
H.PET_STABLE_UPDATE = StableSoon

-- Auto repeat, procs, enchants --------------------------------------------------------
-- AR <1 or 0> <spellID> <seconds>: auto repeat (Auto Shot, a wand's Shoot) started or ended.
-- spellID is the book spell that is repeating, found when it starts; seconds is on the
-- ending line. A logout while it runs writes no ending line.
-- SO <1 or 0> <spellID>: the client lit a spell's action button for a proc (1), or put the
-- glow out (0). One line per change, not per refresh.
-- EC <successful> <itemID>: an enchant spell finished on an item; itemID is empty when the
-- client did not say which item. The enchant on an equipped item is EN.

local auto = { on = false, t0 = 0, id = nil }

-- Auto Shot (75) and Shoot (5019) first; the book is searched once and the answer kept.
local autoFound

local function AutoSpell()
    if autoFound then return autoFound end
    if Call(SPELL.IsAutoRepeatSpell, 75) then autoFound = 75 return 75 end
    if Call(SPELL.IsAutoRepeatSpell, 5019) then autoFound = 5019 return 5019 end
    local s = ns.char and ns.char.sb
    if not s or type(s.ids) ~= "table" then return end
    for id in pairs(s.ids) do
        if Call(SPELL.IsAutoRepeatSpell, id) then
            autoFound = id
            return id
        end
    end
end

function H.START_AUTOREPEAT_SPELL()
    if auto.on then return end
    auto.on, auto.t0, auto.id = true, GetTime(), AutoSpell()
    if auto.id then SpellName(auto.id) end
    Emit("AR", 1, auto.id or "")
end

function H.STOP_AUTOREPEAT_SPELL()
    if not auto.on then return end
    auto.on = false
    Emit("AR", 0, auto.id or "", Round1(GetTime() - auto.t0))
end

local glow = {}

function H.SPELL_ACTIVATION_OVERLAY_GLOW_SHOW(spellID)
    local id = Num(spellID)
    if not id or glow[id] then return end
    glow[id] = true
    SpellName(id)
    Emit("SO", 1, id)
end

function H.SPELL_ACTIVATION_OVERLAY_GLOW_HIDE(spellID)
    local id = Num(spellID)
    if not id or not glow[id] then return end
    glow[id] = nil
    Emit("SO", 0, id)
end

function H.ENCHANT_SPELL_COMPLETED(successful, location)
    if not Plain(successful) then return end
    local item = ""
    if type(location) == "table" and C_Item then
        local id = Num(Call(C_Item.GetItemID, location))
        if id then
            item = id
            ItemName(id)
        end
    end
    Emit("EC", successful and 1 or 0, item)
end

-- Lifecycle ----------------------------------------------------------------------------

local entered = false
function H.PLAYER_ENTERING_WORLD()
    -- A loading screen can swallow a GLOW_HIDE; start every load with no glow known.
    -- Close the ones still lit, so a SHOW the client sends again starts a clean pair.
    for id in pairs(glow) do Emit("SO", 0, id) end
    glow = {}
    if entered then return end
    entered = true
    -- SPELLS_CHANGED and ACTIONBAR_SLOT_CHANGED fire for everything at login; the first reads
    -- wait for them to settle.
    C_Timer.After(8, function()
        started = true
        Scan()
        BarSoon()
    end)
end

ns.Listen(frame, H, "Spells")
