local _, ns = ...

local ci = _G.C_ChatInfo
if not ci or not ci.SendAddonMessage or not ci.RegisterAddonMessagePrefix then return end

local floor, type, pcall = math.floor, type, pcall
local remove, wipe = table.remove, wipe
local GetTime = GetTime
local Emit, Plain = ns.Emit, ns.Plain

local PREFIX = "Scarlet"
local VERSION = "1"
local QUEUE_MAX = 40
local STALE = 300
local PACE = 1
local RETRY = 2
local PER_MINUTE = 20
local PER_SESSION = 1500
local MESSAGE_MAX = 255
local INSTANCE = LE_PARTY_CATEGORY_INSTANCE

local frame = CreateFrame("Frame")
local H = {}

local function Str(v)
    if Plain(v) and type(v) == "string" and v ~= "" then return v end
end

local function On()
    local opt = ns.opt
    return opt ~= nil and opt.shareLoot ~= false and not opt.paused
end

local function Yes(v)
    return Plain(v) and v == true
end

local function Channel()
    if INSTANCE and Yes(IsInGroup(INSTANCE)) then return "INSTANCE_CHAT" end
    if Yes(IsInRaid()) then return "RAID" end
    if Yes(IsInGroup()) then return "PARTY" end
end

local function Locked()
    if InCombatLockdown() then return true end
    if type(ci.InChatMessagingLockdown) == "function" then
        local ok, active = pcall(ci.InChatMessagingLockdown)
        if ok and Yes(active) then return true end
    end
    return false
end

local queue = {}
local draining = false

local function Drain()
    draining = false
    local channel = Channel()
    if not On() or not channel then
        wipe(queue)
        return
    end
    if Locked() then return end
    local now = GetTime()
    while queue[1] and now - queue[1].at > STALE do remove(queue, 1) end
    local entry = queue[1]
    if not entry then return end
    local message = VERSION .. ";L;" .. entry.guid .. ";" .. entry.slots .. ";" .. entry.items .. ";"
        .. entry.again .. ";" .. floor(now - entry.at)
    if #message > MESSAGE_MAX then
        remove(queue, 1)
    else
        local ok, result = pcall(ci.SendAddonMessage, PREFIX, message, channel)
        if ok and (result == true or result == 0) then
            remove(queue, 1)
        elseif ok and (result == 3 or result == 8 or result == 11) then
            draining = true
            C_Timer.After(RETRY, Drain)
            return
        else
            remove(queue, 1)
        end
    end
    if #queue > 0 then
        draining = true
        C_Timer.After(PACE, Drain)
    end
end

function ns.ShareLoot(guid, slots, items, again)
    if not On() or not Channel() then return end
    queue[#queue + 1] = { guid = guid, slots = slots, items = items, again = again, at = GetTime() }
    while #queue > QUEUE_MAX do remove(queue, 1) end
    if not draining then
        draining = true
        Drain()
    end
end

local listening = false
local prefixRegistered = false

function ns.ShareApply()
    local want = On() and Channel() ~= nil
    if want and not prefixRegistered then
        prefixRegistered = true
        pcall(ci.RegisterAddonMessagePrefix, PREFIX)
    end
    if want ~= listening then
        listening = want
        if want then
            frame:RegisterEvent("CHAT_MSG_ADDON")
        else
            frame:UnregisterEvent("CHAT_MSG_ADDON")
        end
    end
    if not want then wipe(queue) end
end

local windows = {}
local accepted = 0

local function Rate(who, now)
    if accepted >= PER_SESSION then return false end
    local w = windows[who]
    if not w or now - w.at >= 60 then
        w = { at = now, count = 0 }
        windows[who] = w
    end
    if w.count >= PER_MINUTE then return false end
    w.count = w.count + 1
    accepted = accepted + 1
    return true
end

local FAMILIES = { Creature = "c", Vehicle = "c", GameObject = "g" }

function H.CHAT_MSG_ADDON(prefix, text, channel, sender)
    if Str(prefix) ~= PREFIX or not On() then return end
    channel = Str(channel)
    if not channel or not (channel == "PARTY" or channel == "RAID" or channel == "INSTANCE_CHAT") then
        return
    end
    if not Str(text) or #text > MESSAGE_MAX or not Str(sender) then return end
    local who = ns.SenderKey(sender)
    if not who then return end
    local fields = {}
    local n = 0
    for field in (text .. ";"):gmatch("(.-);") do
        n = n + 1
        if n > 7 then return end
        fields[n] = field
    end
    if n ~= 7 then return end
    if fields[1] ~= VERSION or fields[2] ~= "L" then return end
    local guid = fields[3]
    if #guid > 80 then return end
    local family, id = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-%x+$")
    local kind = family and FAMILIES[family]
    if not kind or not fields[4]:match("^%d%d?%d?$") then return end
    if not fields[5]:match("^[%dxmc,]*$") then return end
    if not fields[6]:match("^[01]$") or not fields[7]:match("^%d%d?%d?$") then return end
    if not Rate(who, GetTime()) then return end
    local seen = ns.LootRead(guid)
    Emit("LW", who, kind, id, tonumber(fields[4]), fields[5], (fields[6] == "1" or seen == 1) and 1 or 0,
        tonumber(fields[7]), ns.CorpseKey(guid))
end

local function Restart()
    if #queue > 0 and not draining then
        draining = true
        Drain()
    end
end

function H.PLAYER_REGEN_ENABLED() Restart() end
function H.ADDON_RESTRICTION_STATE_CHANGED() Restart() end
function H.GROUP_ROSTER_UPDATE() ns.ShareApply() end
function H.PLAYER_ENTERING_WORLD() ns.ShareApply() end

ns.Listen(frame, H, "Share", { CHAT_MSG_ADDON = true })
