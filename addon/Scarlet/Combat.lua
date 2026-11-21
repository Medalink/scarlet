-- Combat.lua: the Combat-domain trackers beyond Capture, Track and Metrics:
--   TW  totems placed in the player's totem slots
--   IL  instance locks: inside an instance you are saved to, with its bosses
--   SKN your corpse was skinned by someone
--   SR  self-resurrect options available while dead
-- Codes are in docs/FORMAT.md. Event driven only; every client value through
-- Plain() before it is compared or indexed.
local _, ns = ...

local type, pcall = type, pcall
local Emit, Plain = ns.Emit, ns.Plain
local SpellName, ItemName, Round1 = ns.SpellName, ns.ItemName, ns.Round1

local frame = CreateFrame("Frame")
local H = {}

-- Totems -----------------------------------------------------------------------------
-- TW <slot> <spellID> <seconds>: a totem entered a slot, with its duration;
-- spellID 0 when the slot emptied. GetTotemInfo can return secret values
-- (SecretWhenTotemSlotSecret), so a read during combat is retried after it.

local totemState, totemPending = {}, {}

local function ReadTotem(slot)
    local n
    if _G.GetNumTotemSlots then
        local okN, v = pcall(_G.GetNumTotemSlots)
        n = okN and v or nil
    end
    if not Plain(n) or type(n) ~= "number" or slot > n then return end
    if not _G.GetTotemInfo then return end
    -- haveTotem is false for an empty slot; keep it apart from nil (no answer).
    local ok, have, _, _, dur, _, _, spellID = pcall(_G.GetTotemInfo, slot)
    if not ok then return end
    if not Plain(have) then
        -- Field writes a secret as "?": secret during combat, read it after.
        if ns.Field(have) == "?" then totemPending[slot] = true end
        return
    end
    if have and (not Plain(spellID) or not Plain(dur)) then
        totemPending[slot] = true
        return
    end
    local key = have and tostring(spellID) or "0"
    if totemState[slot] == key then return end
    totemState[slot] = key
    if have then
        SpellName(spellID)
        Emit("TW", slot, spellID, Round1(dur))
    else
        Emit("TW", slot, 0)
    end
end

function H.PLAYER_TOTEM_UPDATE(slot)
    if not Plain(slot) or type(slot) ~= "number" then return end
    ReadTotem(slot)
end

-- Instance lock ----------------------------------------------------------------------
-- IL 1 <seconds> <name> <complete> <total>: the client's lock popup is up, so
-- you are in (or entering) an instance you are saved to. IL 0 when it closes.
-- The bosses left come from GetInstanceLockTimeRemaining.

-- The last IL written: nil before any, "0" after a stop. A stop is written only
-- for a lock this load saw open; a session's end closes the saved tag anyway.
local lockKey

local function InstanceName()
    if not _G.GetInstanceInfo then return "" end
    local ok, name = pcall(_G.GetInstanceInfo)
    if ok and Plain(name) and type(name) == "string" then return name end
    return ""
end

function H.INSTANCE_LOCK_START()
    local left, done, total = 0, "", ""
    if _G.GetInstanceLockTimeRemaining then
        local ok, tl, _, tot, comp = pcall(_G.GetInstanceLockTimeRemaining)
        if ok and Plain(tl) then
            left, total, done = Round1(tl), Plain(tot) and tot or "", Plain(comp) and comp or ""
        end
    end
    local name = InstanceName()
    local key = name .. ":" .. done .. ":" .. total
    if key == lockKey then return end
    lockKey = key
    Emit("IL", 1, left, name, done, total)
end

-- The client sends a stop at every logout; only a lock this load saw open is closed.
function H.INSTANCE_LOCK_STOP()
    if lockKey == nil or lockKey == "0" then return end
    lockKey = "0"
    Emit("IL", 0)
end

-- Leaving the instance closes its lock even if the client sent no stop.
function H.PLAYER_ENTERING_WORLD()
    if lockKey == nil or lockKey == "0" then return end
    local inside = IsInInstance()
    if Plain(inside) and not inside then
        lockKey = "0"
        Emit("IL", 0)
    end
end

-- Corpse skinned ---------------------------------------------------------------------

function H.PLAYER_SKINNED(freeRepop)
    Emit("SKN", Plain(freeRepop) and freeRepop or 0)
end

-- Self-resurrect options while dead ----------------------------------------------------
-- SR <optionType> <id> for each option that can be used (soulstone, Reincarnation):
-- optionType 0 is a spell, 1 an item. Once per death.

local selfResSeen = {}

local function SelfRes()
    local dead = UnitIsDeadOrGhost("player")
    if not Plain(dead) or not dead then return end
    local DI = C_DeathInfo
    if not DI or not DI.GetSelfResurrectOptions then return end
    local ok, options = pcall(DI.GetSelfResurrectOptions)
    if not ok or type(options) ~= "table" then return end
    for _, opt in ipairs(options) do
        if type(opt) == "table" and Plain(opt.canUse) and opt.canUse then
            local t = Plain(opt.optionType) and opt.optionType or -1
            local id = Plain(opt.id) and opt.id or nil
            if id then
                local key = t .. ":" .. id
                if not selfResSeen[key] then
                    selfResSeen[key] = true
                    if t == 0 then
                        SpellName(id)
                    elseif t == 1 then
                        ItemName(id)
                    end
                    Emit("SR", t, id)
                end
            end
        end
    end
end

H.SELF_RES_SPELL_CHANGED = SelfRes

function H.PLAYER_DEAD()
    selfResSeen = {}
    -- The option list is filled a moment after the death.
    C_Timer.After(1, SelfRes)
end

-- PLAYER_ALIVE also fires on release to a ghost, which is the same death.
function H.PLAYER_ALIVE()
    local ghost = UnitIsGhost("player")
    if Plain(ghost) and ghost then return end
    selfResSeen = {}
end

function H.PLAYER_UNGHOST()
    selfResSeen = {}
end

function H.PLAYER_REGEN_ENABLED()
    for slot in pairs(totemPending) do
        totemPending[slot] = nil
        ReadTotem(slot)
    end
end

ns.Listen(frame, H)
