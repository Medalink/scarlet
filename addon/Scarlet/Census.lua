local _, ns = ...

local type, pcall, tonumber = type, pcall, tonumber
local min = math.min
local concat = table.concat
local Emit, Plain = ns.Emit, ns.Plain

local HD_SESSION_CAP = 3000
local HD_TEXT_CHARS = 400
local WH_ROWS_PER_SEARCH = 50
local WH_DAY_CAP = 1500
local BO_ROWS = 80
local BO_ROWS_PER_FRAME = 20
local GEAR_FIRST_SLOT, GEAR_LAST_SLOT = 1, 19

local function Num(v)
    if Plain(v) and type(v) == "number" and v == v then return v end
end

local function Str(v)
    if Plain(v) and type(v) == "string" and v ~= "" then return v end
end

local function Call(fn, ...)
    if type(fn) ~= "function" then return end
    local ok, v = pcall(fn, ...)
    if ok and Plain(v) then return v end
end

local function CharacterName(name)
    name = Str(name)
    if not name then return end
    return (name:gsub("%s+", "-"))
end

local H = {}

local deathLines = 0

function H.HARDCORE_DEATHS(notice)
    notice = Str(notice)
    if not notice or deathLines >= HD_SESSION_CAP then return end
    deathLines = deathLines + 1
    local who = CharacterName(notice:match("|Hplayer:([^:|]+)")) or ""
    local text = notice:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H[^|]*|h", ""):gsub("|h", "")
    local level = ""
    for digits in text:gmatch("%d+") do level = tonumber(digits) or level end
    Emit("HD", who, level, text:sub(1, HD_TEXT_CHARS))
end

local function WhoDay(ch)
    local day = date("%Y%m%d")
    local wh = ch.wh
    if type(wh) ~= "table" or wh.day ~= day then
        wh = { day = day, n = 0, set = {} }
        ch.wh = wh
    end
    return wh
end

function H.WHO_LIST_UPDATE()
    local ch = ns.char
    local list = C_FriendList
    if not ch or not list then return end
    local count = Num(Call(list.GetNumWhoResults))
    if not count then return end
    local wh = WhoDay(ch)
    for i = 1, min(count, WH_ROWS_PER_SEARCH) do
        local info = Call(list.GetWhoInfo, i)
        local name = type(info) == "table" and CharacterName(info.fullName)
        if name and not wh.set[name] and wh.n < WH_DAY_CAP then
            wh.set[name], wh.n = 1, wh.n + 1
            Emit("WH", name, Num(info.level) or "", Str(info.filename) or "", Str(info.raceStr) or "",
                Str(info.area) or "", Str(info.fullGuildName) or "")
        end
    end
end

local scoring = false

local function ScoreRowWrite(info)
    local name = type(info) == "table" and CharacterName(info.name)
    if not name then return false end
    Emit("BO", name, Num(info.faction) or "", Str(info.classToken) or "", info.killingBlows, info.honorableKills,
        info.deaths, info.honorGained, info.damageDone, info.healingDone, ns.ScoreStats(info.stats))
    return true
end

---Writes a BO line for every other player on the finished match's scoreboard, at most 80.
function ns.ScoreRows()
    local pvp = C_PvP
    local count = Num(Call(_G.GetNumBattlefieldScores))
    if scoring or not count or not pvp or type(pvp.GetScoreInfo) ~= "function" then return end
    scoring = true
    local mine = Call(UnitGUID, "player")
    local myName = CharacterName(Call(UnitName, "player"))
    local index, written = 1, 0
    local function Step()
        local last = min(index + BO_ROWS_PER_FRAME - 1, count)
        for i = index, last do
            local info = Call(pvp.GetScoreInfo, i)
            local guid = type(info) == "table" and info.guid
            local name = type(info) == "table" and CharacterName(info.name)
            local own = (mine ~= nil and Plain(guid) and guid == mine) or (name and name == myName)
            if written < BO_ROWS and not own and ScoreRowWrite(info) then written = written + 1 end
        end
        index = last + 1
        if index <= count and written < BO_ROWS then
            C_Timer.After(0, Step)
        else
            scoring = false
        end
    end
    Step()
end

local inspected
local gearWritten = {}

---Remembers the player whose inspect window just opened, so INSPECT_READY can write their gear.
function ns.Inspected(name, unit)
    if not Str(name) or not Str(unit) then return end
    inspected = { name = name, unit = unit, guid = Call(UnitGUID, unit) }
end

local function GearEntry(slot, link)
    link = Str(link)
    local id, enchant, suffix = nil, nil, nil
    if link then id, enchant, suffix = link:match("item:([^:|]*):([^:|]*):[^:|]*:[^:|]*:[^:|]*:[^:|]*:([^:|]*)") end
    id = tonumber(id)
    if not id or id == 0 then return end
    ns.ItemName(id)
    return slot .. ":" .. id .. ":" .. (tonumber(enchant) or 0) .. ":" .. (tonumber(suffix) or 0)
end

function H.INSPECT_READY(guid)
    local who = inspected
    if not who or not who.guid or not Plain(guid) or guid ~= who.guid or gearWritten[who.name] then return end
    if Call(UnitGUID, who.unit) ~= who.guid then return end
    local items = {}
    for slot = GEAR_FIRST_SLOT, GEAR_LAST_SLOT do
        local entry = GearEntry(slot, Call(_G.GetInventoryItemLink, who.unit, slot))
        if entry then items[#items + 1] = entry end
    end
    if #items == 0 then return end
    gearWritten[who.name] = true
    Emit("IG", who.name, concat(items, ","))
end

ns.Listen(CreateFrame("Frame"), H, "Census")
