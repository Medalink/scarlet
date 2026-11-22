local _, ns = ...

local type, tonumber, pcall, ipairs, pairs, wipe = type, tonumber, pcall, ipairs, pairs, wipe
local Emit, Plain = ns.Emit, ns.Plain

local READ_DELAY = 0.6
local MONEY_DELAY = 8
local MAIL_SLOTS = 16
local MAIL_STEP = 10
local GUILD_BANKER = 10
local BANK_ACCOUNT, BANK_GUILD = 2, 1

local function Num(v)
    if Plain(v) and type(v) == "number" then return v end
end

local function Call(fn, ...)
    if type(fn) ~= "function" then return end
    local ok, v = pcall(fn, ...)
    if ok and Plain(v) then return v end
end

local function Pack(fn, ...)
    if type(fn) ~= "function" then return end
    local r = { pcall(fn, ...) }
    if r[1] then return r end
end

local function LinkItemID(link)
    if not Plain(link) or type(link) ~= "string" then return nil end
    return tonumber(link:match("item:(%d+)"))
end

local function Add(counts, id, n)
    counts[id] = (counts[id] or 0) + (n or 1)
end

local written = {}

local function WriteStorage(code, counts)
    local sig = ns.ListSig(counts)
    if written[code] == sig then return end
    written[code] = sig
    ns.WriteCounts(code, counts)
end

local H = {}

local warband, warbandRead, warbandScratch = {}, false, {}
local warbandOpen, warbandDue = false, false

local function ReadWarband()
    warbandDue = false
    local bank = C_Bank
    local kind = Enum and Enum.BankType
    if not (bank and bank.FetchPurchasedBankTabData and kind and kind.Account) then return end
    local tabs = Call(bank.FetchPurchasedBankTabData, kind.Account)
    if type(tabs) ~= "table" then return end
    local seen = 0
    wipe(warbandScratch)
    for _, tab in ipairs(tabs) do
        local id = type(tab) == "table" and Num(tab.ID)
        if id then
            local slots = Num(Call(C_Container.GetContainerNumSlots, id)) or 0
            seen = seen + slots
            for slot = 1, slots do
                local info = Call(C_Container.GetContainerItemInfo, id, slot)
                local item = type(info) == "table" and Num(info.itemID)
                if item then Add(warbandScratch, item, Num(info.stackCount)) end
            end
        end
    end
    if seen == 0 then return end
    warband, warbandScratch = warbandScratch, warband
    warbandRead = true
end

local function WarbandSoon()
    if warbandDue or not warbandOpen then return end
    warbandDue = true
    C_Timer.After(READ_DELAY, function()
        if warbandOpen then ReadWarband() else warbandDue = false end
    end)
end

function H.BANKFRAME_OPENED()
    warbandOpen = true
    warbandRead = false
    WarbandSoon()
end

H.PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED = WarbandSoon

function H.BANKFRAME_CLOSED()
    if warbandOpen then ReadWarband() end
    warbandOpen = false
    if warbandRead then WriteStorage("w", warband) end
end

local guildTabs, guildOpen, guildDue, guildTouched = {}, false, false, false
local guildScratch = {}

local function ReadGuildTab(tab)
    local counts = {}
    for slot = 1, 98 do
        local id = LinkItemID(Call(_G.GetGuildBankItemLink, tab, slot))
        if id then
            local r = Pack(_G.GetGuildBankItemInfo, tab, slot)
            Add(counts, id, r and Num(r[3]))
        end
    end
    guildTabs[tab] = counts
end

local function ReadGuildMoney()
    local copper = Num(Call(_G.GetGuildBankMoney))
    if not copper or written.guildMoney == copper then return end
    written.guildMoney = copper
    Emit("BK", "a", BANK_GUILD, copper)
end

local function ReadGuild()
    guildDue = false
    if not guildOpen then return end
    local numTabs = Num(Call(_G.GetNumGuildBankTabs)) or 0
    local current = Num(Call(_G.GetCurrentGuildBankTab))
    if current and current >= 1 and current <= numTabs then
        local r = Pack(_G.GetGuildBankTabInfo, current)
        if r and Plain(r[4]) and r[4] then
            ReadGuildTab(current)
            guildTouched = true
        end
    end
    ReadGuildMoney()
end

local function GuildSoon()
    if guildDue or not guildOpen then return end
    guildDue = true
    C_Timer.After(READ_DELAY, ReadGuild)
end

H.GUILDBANKBAGSLOTS_CHANGED = GuildSoon

function H.GUILDBANK_UPDATE_MONEY()
    if guildOpen then ReadGuildMoney() end
end

local function GuildOpened()
    if guildOpen then return end
    guildOpen = true
    guildTouched = false
    wipe(guildTabs)
    GuildSoon()
end

local function GuildClosed()
    if not guildOpen then return end
    guildOpen = false
    if not guildTouched then return end
    wipe(guildScratch)
    for _, counts in pairs(guildTabs) do
        for id, n in pairs(counts) do Add(guildScratch, id, n) end
    end
    WriteStorage("g", guildScratch)
end

H.GUILDBANKFRAME_CLOSED = GuildClosed

function H.PLAYER_INTERACTION_MANAGER_FRAME_SHOW(kind)
    if Plain(kind) and kind == GUILD_BANKER then GuildOpened() end
end

function H.PLAYER_INTERACTION_MANAGER_FRAME_HIDE(kind)
    if Plain(kind) and kind == GUILD_BANKER then GuildClosed() end
end

local mail, mailScratch = {}, {}
local mailOpen, mailDue, mailRead, mailRun = false, false, false, 0

local function ReadMail()
    mailDue = false
    if not mailOpen then return end
    local shown = Num(Call(_G.GetInboxNumItems))
    if not shown then return end
    mailRun = mailRun + 1
    local run = mailRun
    wipe(mailScratch)
    local function Step(first)
        if run ~= mailRun or not mailOpen then return end
        local last = first + MAIL_STEP - 1
        if last > shown then last = shown end
        for index = first, last do
            local r = Pack(_G.GetInboxHeaderInfo, index)
            if r and (Num(r[9]) or 0) > 0 then
                for slot = 1, MAIL_SLOTS do
                    local a = Pack(_G.GetInboxItem, index, slot)
                    if a and not (Plain(a[8]) and a[8]) then
                        local id = Num(a[3])
                        if id then Add(mailScratch, id, Num(a[5])) end
                    end
                end
            end
        end
        if last < shown then
            C_Timer.After(0, function() Step(last + 1) end)
            return
        end
        mail, mailScratch = mailScratch, mail
        mailRead = true
    end
    Step(1)
end

local function MailSoon()
    if mailDue or not mailOpen then return end
    mailDue = true
    C_Timer.After(READ_DELAY + 0.1, ReadMail)
end

function H.MAIL_SHOW()
    mailOpen = true
    mailRead = false
    MailSoon()
end

H.MAIL_INBOX_UPDATE = MailSoon

function H.MAIL_CLOSED()
    mailOpen = false
    mailRun = mailRun + 1
    if mailRead then WriteStorage("m", mail) end
end

local auctions, auctionsScratch, auctionsRead = {}, {}, false

function H.OWNED_AUCTIONS_UPDATED()
    local ah = C_AuctionHouse
    local list = ah and Call(ah.GetOwnedAuctions)
    if type(list) ~= "table" then return end
    local enum = _G.Enum and _G.Enum.AuctionStatus
    wipe(auctionsScratch)
    for _, a in ipairs(list) do
        if type(a) == "table" then
            local status = Num(a.status)
            local key = a.itemKey
            local id = type(key) == "table" and Num(key.itemID)
            if id and not (enum and status == enum.Sold) then Add(auctionsScratch, id, Num(a.quantity)) end
        end
    end
    auctions, auctionsScratch = auctionsScratch, auctions
    auctionsRead = true
end

function H.AUCTION_HOUSE_CLOSED()
    if auctionsRead then WriteStorage("a", auctions) end
    auctionsRead = false
end

local function ReadWarbandMoney()
    local bank = C_Bank
    local kind = Enum and Enum.BankType
    if not (bank and bank.FetchDepositedMoney and kind and kind.Account) then return end
    local copper = Num(Call(bank.FetchDepositedMoney, kind.Account))
    if not copper or written.warbandMoney == copper then return end
    written.warbandMoney = copper
    Emit("BK", "a", BANK_ACCOUNT, copper)
end

H.ACCOUNT_MONEY = ReadWarbandMoney

local entered = false

function H.PLAYER_ENTERING_WORLD()
    if entered then return end
    entered = true
    C_Timer.After(MONEY_DELAY, ReadWarbandMoney)
end

ns.Listen(CreateFrame("Frame"), H, "Storage")
