-- Teleport.lua: moving between places without travelling there.
--   TE  a teleport by a spell, an item, a portal or a summon: what moved you, where you left, where you arrived
-- Codes are in docs/FORMAT.md. Event driven: a cast out of combat, an item use or an accepted summon
-- starts a short watch (one-shot timers for a few seconds, never a ticker), and the watch ends with a
-- line or with nothing. Every client value goes through Plain() before it is compared or used.
local _, ns = ...

local type, pcall, sqrt = type, pcall, math.sqrt
local floor = math.floor
local GetTime = GetTime
local Emit, Plain = ns.Emit, ns.Plain

local frame = CreateFrame("Frame")
local H = {}

local function Num(v)
    if Plain(v) and type(v) == "number" then return v end
end

local JUMP_YARDS = 100   -- farther than this between two checks (1.5 s apart), in one instance, is a teleport
local ITEM_FOR = 20      -- seconds an item use stays the cause of a cast (the longest teleport cast is 10)
local SPELL_WATCH = 8    -- seconds a cast or an item is watched for a move
local SUMMON_WATCH = 24  -- seconds an accepted summon is watched
local LOAD_WATCH = 40    -- a loading screen holds the watch open this long at most
local CHECK_EVERY = 1.5
local REPEAT_SECONDS = 1.5

-- Where the player stands: map and map coordinates times 10000 (as P writes them), and the world position
-- in yards with the instance it belongs to (nil when the client gives none).
local function Snap()
    local s = {}
    local map, x, y = ns.MapPoint()
    s.map, s.x, s.y = map, x, y
    local wx, wy, _, inst = UnitPosition("player")
    if Plain(wx) and Plain(wy) and Plain(inst) and type(wx) == "number" and type(wy) == "number" then
        s.wx, s.wy, s.inst = wx, wy, inst
    end
    return s
end

local function Dead()
    local d = UnitIsDeadOrGhost("player")
    return Plain(d) and d
end

-- The item you used lately: a hearthstone, a teleport trinket, a toy. The cast it starts names the spell.
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
if type(_G.UseToy) == "function" then
    hooksecurefunc("UseToy", Used)
end

-- The watch: one at a time. kind `s` a spell you know, `i` an item, `m` a summon, `o` a spell you do not
-- know (the hidden cast a portal object puts on you).
local watch
local loading = false
local armed = false
local lastHidden, lastHiddenT = nil, 0

local Resolve

-- One timer chain at a time: a second request while one is waiting changes nothing.
local function Arm(delay)
    if armed then return end
    armed = true
    C_Timer.After(delay, function()
        armed = false
        Resolve()
    end)
end

Resolve = function()
    local w = watch
    if not w then return end
    local now = GetTime()
    if now > w.stop then
        watch = nil
        return
    end
    if loading then
        Arm(CHECK_EVERY)
        return
    end
    local onTaxi = UnitOnTaxi("player")
    if Plain(onTaxi) and onTaxi then
        watch = nil
        return
    end
    local a, o, l = Snap(), w.from, w.last
    local yards, step
    if a.wx and o.wx and a.inst == o.inst then
        local dx, dy = a.wx - o.wx, a.wy - o.wy
        yards = sqrt(dx * dx + dy * dy)
    end
    -- Riding or flying covers at most about 45 yards between checks; a teleport covers it at once.
    if a.wx and l.wx and a.inst == l.inst then
        local dx, dy = a.wx - l.wx, a.wy - l.wy
        step = sqrt(dx * dx + dy * dy)
    end
    local how
    if a.inst and o.inst and a.inst ~= o.inst then
        how = "m"
    elseif step and step > JUMP_YARDS then
        how = (a.map and o.map and a.map ~= o.map) and "m" or "d"
    elseif not yards and a.map and o.map and a.map ~= o.map then
        how = "m"
    end
    if not how then
        if a.wx then w.last = a end
        Arm(CHECK_EVERY)
        return
    end
    watch = nil
    if w.spell then ns.SpellName(w.spell) end
    if w.item then ns.ItemName(w.item) end
    Emit("TE", w.kind, w.spell or "", w.item or "", o.map or "", o.x or "", o.y or "", a.map or "", a.x or "",
        a.y or "", yards and floor(yards + 0.5) or "", ns.Round1(now - w.t0), how)
end

local function Begin(kind, spell, item, seconds)
    if Dead() then return end
    local onTaxi = UnitOnTaxi("player")
    if Plain(onTaxi) and onTaxi then return end
    local now = GetTime()
    local from = Snap()
    if watch then
        -- Another cast before the move: it is the cause when you have not moved yet.
        local w = watch
        local same = w.from.wx and from.wx and w.from.inst == from.inst
            and (from.wx - w.from.wx) ^ 2 + (from.wy - w.from.wy) ^ 2 < 25
        if not same and not (w.from.map == from.map and w.from.x == from.x and w.from.y == from.y) then return end
        if w.kind == "m" and kind ~= "m" then return end
        w.kind, w.spell, w.item, w.t0, w.stop = kind, spell, item, now, now + seconds
        return
    end
    watch = { kind = kind, spell = spell, item = item, from = from, last = from, t0 = now, stop = now + seconds }
    Arm(CHECK_EVERY)
end

-- A cast that completes out of combat. A spell you do not know that repeats within a moment of itself is
-- the client's own (Gadgetzan casts one every second) and starts no watch.
function H.UNIT_SPELLCAST_SUCCEEDED(_, _, spellID)
    if InCombatLockdown() then return end
    spellID = Num(spellID)
    if not spellID then return end
    local known = _G.IsPlayerSpell and _G.IsPlayerSpell(spellID)
    if not Plain(known) then return end
    local now = GetTime()
    if not known then
        local again = lastHidden == spellID and now - lastHiddenT < REPEAT_SECONDS
        lastHidden, lastHiddenT = spellID, now
        if again then return end
    end
    if usedT and now - usedT < ITEM_FOR then
        Begin("i", spellID, usedItem, SPELL_WATCH)
    else
        Begin(known and "s" or "o", spellID, nil, SPELL_WATCH)
    end
end

if C_SummonInfo and type(C_SummonInfo.ConfirmSummon) == "function" then
    hooksecurefunc(C_SummonInfo, "ConfirmSummon", function() Begin("m", nil, nil, SUMMON_WATCH) end)
end

function H.LOADING_SCREEN_ENABLED()
    loading = true
    if watch and watch.stop < GetTime() + LOAD_WATCH then watch.stop = GetTime() + LOAD_WATCH end
end

-- The position settles a moment after the screen goes.
function H.LOADING_SCREEN_DISABLED()
    loading = false
    if watch then
        watch.stop = GetTime() + SPELL_WATCH
        Arm(1)
    end
end

ns.Listen(frame, H)
