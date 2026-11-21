-- Economy.lua: the Economy-and-items trackers beyond Capture and Track (I, M, O, CU, RE):
--   AV  an auction house invoice in the inbox: read when shown, opened or taken from
--   VB  a vendor purchase or buyback: item, count, price, which NPC
--   AU  auction house: posted, bid, bought, cancelled, sold, expired, outbid
--   ML  mail: sent, money taken, items taken, returned
--   TR  a trade window: partner, what each side gave, whether it went through
--   BK  bank money moved, bank tabs bought
--   BG  bag space: baseline, total slots changed, bags full or free again, overflow
--   EN  an equipped item's enchant or gems changed
--   WE  a temporary weapon enchant (oil, poison) applied or gone
--   IU  you upgraded an item
--   RW  a loot roll: offered, won, lost
--   BR  a bonus roll result
--   TK  WoW Token market price and sale or purchase results
--   LP  loot specialization changed
--   DI  you deleted an item
-- Codes are in docs/FORMAT.md. Event driven only, nothing on a timer but short debounces; every client
-- value goes through Plain() before it is compared or indexed. Chat, mail text,
-- mail subjects and auction text are never read.
local _, ns = ...

local type, pcall, pairs, ipairs, tonumber = type, pcall, pairs, ipairs, tonumber
local floor = math.floor
local concat = table.concat
local Emit, Plain = ns.Emit, ns.Plain
local ItemName, NpcID = ns.ItemName, ns.NpcID

local AH = C_AuctionHouse
local ITEM = C_Item
local BANK = C_Bank
local CONT = C_Container
local MERCH = C_MerchantFrame
local UPG = C_ItemUpgrade
local LH = C_LootHistory
local TOKEN = _G.C_WowTokenPublic

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
-- Index it only through Str and Num.
local function Pack(fn, ...)
    if type(fn) ~= "function" then return end
    local r = { pcall(fn, ...) }
    if r[1] then return r end
end

local function LinkID(link)
    link = Str(link)
    return link and tonumber(link:match("item:(%d+)")) or nil
end

local function Count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Vendor -------------------------------------------------------------------------------
-- VB <b buy or r buyback> <itemID> <count> <copper> <npcID> <extended>. copper is
-- the whole price paid; extended `1` when the item also cost currency or items
-- (the CU and I lines show which). Sales to a vendor are I lines with where `v`.

local function MerchantNpc()
    local guid = UnitGUID("npc")
    if not Plain(guid) or type(guid) ~= "string" then return "" end
    local id = NpcID(guid)
    return type(id) == "number" and id or ""
end

if type(_G.BuyMerchantItem) == "function" then
    hooksecurefunc("BuyMerchantItem", function(index, quantity)
        if not Num(index) then return end
        local id = LinkID(Call(_G.GetMerchantItemLink, index))
        if not id then return end
        local info = MERCH and Call(MERCH.GetItemInfo, index)
        local price, stack, extended = 0, 1, 0
        if type(info) == "table" then
            price = Num(info.price) or 0
            stack = Num(info.stackCount) or 1
            if Plain(info.hasExtendedCost) and info.hasExtendedCost then extended = 1 end
        end
        if stack < 1 then stack = 1 end
        local count = Num(quantity) or stack
        ItemName(id)
        Emit("VB", "b", id, count, floor(price * count / stack), MerchantNpc(), extended)
    end)
end

if type(_G.BuybackItem) == "function" then
    hooksecurefunc("BuybackItem", function(slot)
        if not Num(slot) then return end
        local id = LinkID(Call(_G.GetBuybackItemLink, slot))
        local r = Pack(_G.GetBuybackItemInfo, slot)
        if not id or not r then return end
        ItemName(id)
        Emit("VB", "r", id, Num(r[5]) or 1, Num(r[4]) or 0, MerchantNpc(), 0)
    end)
end

-- Vendor stock -------------------------------------------------------------------------
-- VS <npcID> <count> <items>: everything a vendor lists, read a moment after the window opens
-- and again (debounced) when the list refreshes. items are `itemID:price:stack:limit:cost`
-- joined by commas. price is copper, stack the units one purchase gives, limit how many are
-- left (-1 for unlimited) at the time of the read, cost the extra price in items or currency as
-- `i<itemID>x<n>` or `c<currencyID>x<n>` joined by `+` (empty when none). Written once per
-- vendor per character and again when an item, its price, stack, cost or whether it is
-- limited changes (a limited item selling down is not a change). ns.char.vs keeps a checksum
-- per vendor, up to VS_CAP vendors.

local VS_CAP = 600
local VS_ITEMS = 150
local vsQueued, vsSession = false, {}

local function CostOf(index, ids)
    local n = Num(Call(_G.GetMerchantItemCostInfo, index)) or 0
    local out = {}
    for j = 1, math.min(n, 4) do
        local r = Pack(_G.GetMerchantItemCostItem, index, j)
        local value = r and Num(r[3])
        local link = r and Str(r[4])
        if value then
            local kind, id = "", nil
            if link then
                id = tonumber(link:match("item:(%d+)"))
                kind = "i"
                if not id then
                    id = tonumber(link:match("currency:(%d+)"))
                    kind = "c"
                end
            end
            if id then
                if kind == "i" then ids[#ids + 1] = id end
                out[#out + 1] = kind .. id .. "x" .. value
            else
                out[#out + 1] = "?x" .. value
            end
        end
    end
    return concat(out, "+")
end

local function Checksum(text)
    local h = 5381
    for i = 1, #text do h = (h * 33 + text:byte(i)) % 2147483647 end
    return h
end

local function StockRead()
    vsQueued = false
    local ch = ns.char
    local n = Num(Call(_G.GetMerchantNumItems))
    if not ch or not n or n < 1 then return end
    local npc = MerchantNpc()
    if npc == "" then return end
    local rows, sigs, ids = {}, {}, {}
    for i = 1, math.min(n, VS_ITEMS) do
        local id = Num(Call(_G.GetMerchantItemID, i))
        local r = Pack(_G.GetMerchantItemInfo, i)
        local price, stack, left
        if r then
            price, stack, left = Num(r[4]), Num(r[5]), Num(r[6])
        else
            local info = MERCH and Call(MERCH.GetItemInfo, i)
            if type(info) == "table" then
                price, stack, left = Num(info.price), Num(info.stackCount), Num(info.numAvailable)
            end
        end
        if id and price and stack then
            local cost = CostOf(i, ids)
            local limit = left or -1
            ids[#ids + 1] = id
            rows[#rows + 1] = id .. ":" .. price .. ":" .. stack .. ":" .. limit .. ":" .. cost
            sigs[#sigs + 1] = id .. ":" .. price .. ":" .. stack .. ":" .. (limit >= 0 and 1 or 0) .. ":" .. cost
        end
    end
    if #rows == 0 then return end
    local sum = Checksum(concat(sigs, ","))
    if type(ch.vs) ~= "table" then ch.vs, ch.vsN = {}, 0 end
    if ch.vs[npc] == sum or vsSession[npc] == sum then return end
    vsSession[npc] = sum
    if ch.vs[npc] or (ch.vsN or 0) < VS_CAP then
        if not ch.vs[npc] then ch.vsN = (ch.vsN or 0) + 1 end
        ch.vs[npc] = sum
    end
    -- Names (IN) and item facts (II) only for a stock that is written, not on every visit.
    for i = 1, #ids do ItemName(ids[i]) end
    Emit("VS", npc, #rows, concat(rows, ","))
end

local function StockSoon(delay)
    if vsQueued then return end
    vsQueued = true
    C_Timer.After(delay, StockRead)
end

function H.MERCHANT_SHOW() StockSoon(0.7) end
function H.MERCHANT_UPDATE() StockSoon(1.5) end

-- Auction house ------------------------------------------------------------------------
-- AU <kind> <auctionID> <itemID> <count> <copper> <copper2> <duration> <commodity>.
-- kind: p you posted (copper bid, copper2 buyout, or the unit price of a commodity),
-- b you bid (copper), y you bought (copper paid, copper2 unit price of a commodity),
-- x you cancelled, s sold, e expired, o you were outbid, r an auction of yours was
-- removed. What an item sold for is in the mail you take (ML, M). Notification
-- text is not recorded.
--
-- The client's sell frames call PostItem or PostCommodity, and ConfirmPost... when it
-- asks first. Both hooks stage the same post, and AUCTION_HOUSE_AUCTION_CREATED
-- writes it; a multi-sell fires that event once per auction from one staged post.

local ownedItems, bidItems = {}, {}
local post, bid, buying

local function AuctionItem(auctionID)
    local rec = auctionID and (ownedItems[auctionID] or bidItems[auctionID])
    if rec then
        ItemName(rec[1])
        return rec[1], rec[2]
    end
    return "", ""
end

local function Stage(item, duration, quantity, bidPrice, buyout, commodity)
    local id = Num(Call(ITEM.GetItemID, item))
    if not id then return end
    post = { id = id, count = Num(quantity) or "", bid = Num(bidPrice) or "", buyout = Num(buyout) or "",
        duration = Num(duration) or "", commodity = commodity and 1 or 0, t = GetTime() }
end

if AH then
    for name, commodity in pairs({ PostItem = false, ConfirmPostItem = false, PostCommodity = true,
        ConfirmPostCommodity = true }) do
        if type(AH[name]) == "function" then
            hooksecurefunc(AH, name, function(item, duration, quantity, a, b)
                if commodity then
                    Stage(item, duration, quantity, nil, a, true)
                else
                    Stage(item, duration, quantity, a, b, false)
                end
            end)
        end
    end

    if type(AH.PlaceBid) == "function" then
        hooksecurefunc(AH, "PlaceBid", function(auctionID, amount)
            if not Num(auctionID) then return end
            local info = Call(AH.GetAuctionInfoByID, auctionID)
            local id = type(info) == "table" and type(info.itemKey) == "table" and Num(info.itemKey.itemID) or nil
            if id then
                if Count(bidItems) > 200 then bidItems = {} end
                bidItems[auctionID] = { id, "" }
            end
            bid = { auction = auctionID, amount = Num(amount) or "", t = GetTime() }
        end)
    end

    if type(AH.StartCommoditiesPurchase) == "function" then
        hooksecurefunc(AH, "StartCommoditiesPurchase", function(itemID, quantity, unitPrice)
            if not Num(itemID) then return end
            buying = { id = itemID, count = Num(quantity) or "", unit = Num(unitPrice) or "", total = "" }
        end)
    end

    if type(AH.ConfirmCommoditiesPurchase) == "function" then
        hooksecurefunc(AH, "ConfirmCommoditiesPurchase", function(itemID, quantity)
            if not Num(itemID) then return end
            buying = buying or { unit = "", total = "" }
            buying.id, buying.count, buying.confirmed = itemID, Num(quantity) or buying.count or "", true
        end)
    end
end

function H.AUCTION_HOUSE_AUCTION_CREATED(auctionID)
    local p = post
    if p and GetTime() - p.t > 120 then p = nil end
    local id = Num(auctionID)
    Emit("AU", "p", id or "", p and p.id or "", p and p.count or "", p and p.bid or "", p and p.buyout or "",
        p and p.duration or "", p and p.commodity or "")
    if p then
        p.t = GetTime()
        ItemName(p.id)
        if id then
            if Count(ownedItems) > 400 then ownedItems = {} end
            ownedItems[id] = { p.id, p.count }
        end
    end
end

function H.AUCTION_HOUSE_POST_ERROR() post = nil end

local ownedDue = false
function H.OWNED_AUCTIONS_UPDATED()
    if ownedDue or not AH then return end
    ownedDue = true
    C_Timer.After(1, function()
        ownedDue = false
        local n = Num(Call(AH.GetNumOwnedAuctions)) or 0
        if Count(ownedItems) > 400 then ownedItems = {} end
        for i = 1, n do
            local a = Call(AH.GetOwnedAuctionInfo, i)
            if type(a) == "table" and type(a.itemKey) == "table" then
                local id, item = Num(a.auctionID), Num(a.itemKey.itemID)
                if id and item then ownedItems[id] = { item, Num(a.quantity) or "" } end
            end
        end
    end)
end

function H.BID_ADDED(bidID)
    local b = bid
    if b and GetTime() - b.t > 30 then b = nil end
    local auction = b and b.auction or Num(bidID)
    local id = AuctionItem(auction)
    Emit("AU", "b", auction or "", id, "", b and b.amount or "", "", "", 0)
end

function H.AUCTION_HOUSE_PURCHASE_COMPLETED(auctionID)
    local auction = Num(auctionID)
    local b = bid
    if b and (GetTime() - b.t > 30 or b.auction ~= auction) then b = nil end
    local id = AuctionItem(auction)
    Emit("AU", "y", auction or "", id, "", b and b.amount or "", "", "", 0)
end

function H.COMMODITY_PRICE_UPDATED(unitPrice, totalPrice)
    if not buying then return end
    buying.unit, buying.total = Num(unitPrice) or buying.unit, Num(totalPrice) or buying.total
end

function H.COMMODITY_PURCHASE_SUCCEEDED()
    local b = buying
    buying = nil
    if not b or not b.confirmed or not b.id then return end
    ItemName(b.id)
    Emit("AU", "y", "", b.id, b.count or "", b.total or "", b.unit or "", "", 1)
end

function H.COMMODITY_PURCHASE_FAILED() buying = nil end

-- The client also fires AUCTION_CANCELED when one of your auctions sells or expires
-- (13 of 13 sales on 2026-11-20 were followed by one). A cancel for an auction with a
-- sold or expired notice within a few seconds either side is that removal, not a cancel.
local NOTED_FOR = 5
local notedAt = {}

function H.AUCTION_CANCELED(auctionID)
    local id = Num(auctionID)
    local item, count = AuctionItem(id)
    local t = GetTime()
    -- 2 s, so a sold notice that arrives after the cancel still suppresses it.
    C_Timer.After(2, function()
        if id and notedAt[id] and math.abs(notedAt[id] - t) < NOTED_FOR then return end
        Emit("AU", "x", id or "", item, count, "", "", "", "")
    end)
end

-- The client names the event (bid placed 0, removed 1, won 2, outbid 3, sold 4,
-- expired 5). Placing a bid and winning are the b and y lines. Both notification
-- events can fire for one thing; the one with an auction id wins. Removed (1)
-- is the notice for your own cancel, already an AU x line, so it is not written.
local NOTE = { [3] = "o", [4] = "s", [5] = "e" }
local formattedAt = {}

local function Note(n, auctionID)
    if auctionID and (n == 4 or n == 5) then
        if Count(notedAt) > 200 then notedAt = {} end
        notedAt[auctionID] = GetTime()
    end
    local item, count = AuctionItem(auctionID)
    Emit("AU", NOTE[n], auctionID or "", item, count, "", "", "", "")
end

function H.AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION(n, _, auctionID)
    if not Num(n) or not NOTE[n] then return end
    formattedAt[n] = GetTime()
    Note(n, Num(auctionID))
end

function H.AUCTION_HOUSE_SHOW_NOTIFICATION(n)
    if not Num(n) or not NOTE[n] then return end
    local t = GetTime()
    if formattedAt[n] and t - formattedAt[n] < 1 then return end
    C_Timer.After(0.3, function()
        if formattedAt[n] and formattedAt[n] >= t then return end
        Note(n)
    end)
end

-- Mail ---------------------------------------------------------------------------------
-- ML <kind> <who> <copper> <cod> <items>. items is a list of itemID:count joined by
-- commas. kind: s you sent mail (who is the recipient, copper the money, cod the
-- cash on delivery), m you took money from a mail (who is the sender), i you took
-- attachments (cod is what the mail asked you to pay), r you returned a mail. Mail
-- subjects and bodies are never read. A take is written when you ask for it; the M
-- and I lines show what arrived.

local draft = { money = 0, cod = 0, items = "", postage = 0 }
local sending

local function ReadDraft()
    local money = Num(Call(_G.GetSendMailMoney)) or 0
    local cod = Num(Call(_G.GetSendMailCOD)) or 0
    local out = {}
    for i = 1, Num(_G.ATTACHMENTS_MAX_SEND) or 12 do
        local r = Pack(_G.GetSendMailItem, i)
        local id = r and Num(r[3])
        if id then
            ItemName(id)
            out[#out + 1] = id .. ":" .. (Num(r[5]) or 1)
        end
    end
    draft.money, draft.cod, draft.items = money, cod, concat(out, ",")
    draft.postage = Num(Call(_G.GetSendMailPrice)) or 0
end

H.MAIL_SEND_INFO_UPDATE = ReadDraft
H.SEND_MAIL_MONEY_CHANGED = ReadDraft
H.SEND_MAIL_COD_CHANGED = ReadDraft

if type(_G.SendMail) == "function" then
    hooksecurefunc("SendMail", function(recipient)
        -- The client may already have emptied the form; keep what the form held.
        local money, cod, items, postage = draft.money, draft.cod, draft.items, draft.postage
        ReadDraft()
        if draft.postage == 0 then draft.postage = postage end
        if draft.money == 0 then draft.money = money end
        if draft.cod == 0 then draft.cod = cod end
        if draft.items == "" then draft.items = items end
        sending = { who = Str(recipient) or "", money = draft.money, cod = draft.cod, items = draft.items, postage = draft.postage }
    end)
end

function H.MAIL_SEND_SUCCESS()
    local s = sending
    sending = nil
    draft.money, draft.cod, draft.items, draft.postage = 0, 0, "", 0
    if s then Emit("ML", "s", s.who, s.money, s.cod, s.items, s.postage) end
end

function H.MAIL_FAILED() sending = nil end

-- sender, money, COD amount and attachment count of an inbox mail. GetInboxHeaderInfo
-- also returns the subject; it is not read.
local function Inbox(index)
    local r = Pack(_G.GetInboxHeaderInfo, index)
    if not r then return "", 0, 0, 0 end
    return Str(r[4]) or "", Num(r[6]) or 0, Num(r[7]) or 0, Num(r[9]) or 0
end

-- AV <invoiceType> <itemName> <count> <bid> <buyout> <deposit> <cut> <why>: an auction house invoice in
-- your inbox, with the numbers the client gives (invoiceType `seller` when something of yours sold,
-- `buyer` when you won one, `seller_temp_invoice` while the sale is pending). bid is what it sold or was
-- bought for, buyout the buyout price, deposit the deposit you paid and cut the auction house's
-- consignment. why: `i` read when the inbox was shown, `o` read when you opened the mail, `t` read when
-- you took from it. The buyer's or seller's name and the mail's subject are never read, and neither is
-- the mail's text: GetInboxText is not called, only watched when the client's own mail window calls it.
-- A mail's index changes as mail is taken, so an invoice is told apart by its numbers and the time its
-- mail expires (daysLeft turned into a clock time, in one hour steps; the steps either side count as the
-- same), kept per character (AV_CAP of them). One invoice is written once, whichever way it is read first.

local AV_CAP = 400

local function InvoiceSeen(base, hour)
    local ch = ns.char
    if not ch then return false end
    local av = ch.av
    if type(av) ~= "table" or type(av.set) ~= "table" or type(av.order) ~= "table" then
        av = { set = {}, order = {} }
        ch.av = av
    end
    for d = -1, 1 do
        if av.set[base .. "@" .. (hour + d)] then return true end
    end
    local key = base .. "@" .. hour
    av.set[key] = true
    av.order[#av.order + 1] = key
    if #av.order > AV_CAP then av.set[table.remove(av.order, 1)] = nil end
    return false
end

local function Invoice(index, why)
    if type(_G.GetInboxInvoiceInfo) ~= "function" then return end
    local r = Pack(_G.GetInboxInvoiceInfo, index)
    local kind = r and Str(r[2])
    if not kind then return end
    local item, count = Str(r[3]) or "", Num(r[12]) or ""
    local bid, buyout, deposit, cut = Num(r[5]) or "", Num(r[6]) or "", Num(r[7]) or "", Num(r[8]) or ""
    local head = Pack(_G.GetInboxHeaderInfo, index)
    local days = head and Num(head[8])
    local hour = floor(((days and (time() + days * 86400)) or time()) / 3600)
    local base = concat({ kind, item, count, bid, buyout, deposit, cut }, "|")
    if InvoiceSeen(base, hour) then return end
    Emit("AV", kind, item, count, bid, buyout, deposit, cut, why)
end

-- Every invoice in the inbox, once it is shown or changes. The client may hand out an invoice only for
-- a mail it has loaded, so the ones it holds back are read when you open them.
local mailOpen, scanDue = false, false

local function InboxScan()
    scanDue = false
    if not mailOpen then return end
    local n = Num(Call(_G.GetInboxNumItems))
    if not n then return end
    for i = 1, math.min(n, 50) do Invoice(i, "i") end
end

local function ScanSoon()
    if scanDue then return end
    scanDue = true
    C_Timer.After(0.7, InboxScan)
end

function H.MAIL_SHOW()
    mailOpen = true
    ScanSoon()
end

function H.MAIL_CLOSED() mailOpen = false end
H.MAIL_INBOX_UPDATE = ScanSoon

if type(_G.GetInboxText) == "function" then
    hooksecurefunc("GetInboxText", function(index)
        if mailOpen and Num(index) then Invoice(index, "o") end
    end)
end

-- itemID and count of one attachment, nil for an empty slot or a currency.
local function Attachment(index, slot)
    local r = Pack(_G.GetInboxItem, index, slot)
    if not r or (Plain(r[8]) and r[8]) then return end
    local id = Num(r[3])
    if id then return id, Num(r[5]) or 1 end
end

local function TakeItems(index, from, to)
    local who, _, cod = Inbox(index)
    local out = {}
    for slot = from, to do
        local id, count = Attachment(index, slot)
        if id then
            ItemName(id)
            out[#out + 1] = id .. ":" .. count
        end
    end
    if #out > 0 then Emit("ML", "i", who, "", cod, concat(out, ",")) end
end

if type(_G.TakeInboxMoney) == "function" then
    hooksecurefunc("TakeInboxMoney", function(index)
        if not Num(index) then return end
        Invoice(index, "t")
        local who, money = Inbox(index)
        if money > 0 then Emit("ML", "m", who, money, "", "") end
    end)
end

if type(_G.TakeInboxItem) == "function" then
    hooksecurefunc("TakeInboxItem", function(index, slot)
        if Num(index) and Num(slot) then
            Invoice(index, "t")
            TakeItems(index, slot, slot)
        end
    end)
end

if type(_G.AutoLootMailItem) == "function" then
    hooksecurefunc("AutoLootMailItem", function(index)
        if not Num(index) then return end
        Invoice(index, "t")
        local who, money = Inbox(index)
        if money > 0 then Emit("ML", "m", who, money, "", "") end
        TakeItems(index, 1, Num(_G.ATTACHMENTS_MAX_RECEIVE) or 16)
    end)
end

if type(_G.ReturnInboxItem) == "function" then
    hooksecurefunc("ReturnInboxItem", function(index)
        if not Num(index) then return end
        Emit("ML", "r", (Inbox(index)), "", "", "")
    end)
end

-- Trade --------------------------------------------------------------------------------
-- TR 1 <who>: a trade window opened with that player. TR 0 <who> <done> <you gave
-- copper> <you got copper> <you gave> <you got>: it closed, written half a second
-- later so the client's "trade complete" message can arrive first. done `1` when the
-- client said it was complete or both sides had accepted, `0` when it was cancelled.
-- The lists are what both sides offered at the last accept, as itemID:count joined by
-- commas, and are empty when it was cancelled.

local trade, lastTrade

local function Side(link, info)
    local out = {}
    for i = 1, 6 do -- slot 7 is the one that is not traded
        local id = LinkID(Call(link, i))
        if id then
            local r = Pack(info, i)
            ItemName(id)
            out[#out + 1] = id .. ":" .. ((r and Num(r[4])) or 1)
        end
    end
    return concat(out, ",")
end

local function TradeSnapshot()
    trade.gaveMoney = Num(Call(_G.GetPlayerTradeMoney)) or 0
    trade.gotMoney = Num(Call(_G.GetTargetTradeMoney)) or 0
    trade.gave = Side(_G.GetTradePlayerItemLink, _G.GetTradePlayerItemInfo)
    trade.got = Side(_G.GetTradeTargetItemLink, _G.GetTradeTargetItemInfo)
end

function H.TRADE_SHOW()
    trade = { who = Str(_G.GetUnitName("npc", true)) or "", gaveMoney = 0, gotMoney = 0, gave = "", got = "" }
    Emit("TR", 1, trade.who)
end

-- Any change to either offer clears both accepts, so the last snapshot is the final one.
function H.TRADE_ACCEPT_UPDATE(player, target)
    if not trade then return end
    if Num(player) == 1 or Num(target) == 1 then TradeSnapshot() end
    if Num(player) == 1 and Num(target) == 1 then trade.both = true end
end

function H.UI_INFO_MESSAGE(_, message)
    local t = trade or lastTrade
    local complete = _G.ERR_TRADE_COMPLETE
    if t and complete and Str(message) == complete then t.complete = true end
end

function H.TRADE_CLOSED()
    local t = trade
    trade, lastTrade = nil, t
    if not t then return end
    -- done 1: the client said the trade completed. done 2: both sides accepted
    -- but no completion message came (it can still fail, e.g. full bags).
    C_Timer.After(0.5, function()
        if t.complete or t.both then
            Emit("TR", 0, t.who, t.complete and 1 or 2, t.gaveMoney, t.gotMoney, t.gave, t.got)
        else
            Emit("TR", 0, t.who, 0, "", "", "", "")
        end
    end)
end

-- Bank ---------------------------------------------------------------------------------
-- BK d <bankType> <copper>: you deposited money; BK w: you withdrew money; BK t
-- <bankType> <tabs>: tabs bought. bankType is the client's BankType: 0 character,
-- 1 guild, 2 warband. Items moved in and out are I lines.

if type(_G.DepositGuildBankMoney) == "function" then
    hooksecurefunc("DepositGuildBankMoney", function(amount)
        if Num(amount) then Emit("BK", "d", 1, amount) end
    end)
end

if type(_G.WithdrawGuildBankMoney) == "function" then
    hooksecurefunc("WithdrawGuildBankMoney", function(amount)
        if Num(amount) then Emit("BK", "w", 1, amount) end
    end)
end

if BANK and type(BANK.DepositMoney) == "function" then
    hooksecurefunc(BANK, "DepositMoney", function(bankType, amount)
        if Num(bankType) and Num(amount) then Emit("BK", "d", bankType, amount) end
    end)
end

if BANK and type(BANK.WithdrawMoney) == "function" then
    hooksecurefunc(BANK, "WithdrawMoney", function(bankType, amount)
        if Num(bankType) and Num(amount) then Emit("BK", "w", bankType, amount) end
    end)
end

local tabs = {}

local function Tabs(bankType)
    return Num(Call(BANK and BANK.FetchNumPurchasedBankTabs, bankType))
end

function H.BANK_TABS_CHANGED(bankType)
    if not Num(bankType) then return end
    local n = Tabs(bankType)
    if not n or tabs[bankType] == n then return end
    local first = tabs[bankType] == nil
    tabs[bankType] = n
    if not first then Emit("BK", "t", bankType, n) end
end

-- Bag space ----------------------------------------------------------------------------
-- BG <free> <total> <why>: free slots and total slots in your bags. why: `s` the
-- session's first reading, `t` the total changed (a bag was equipped or removed),
-- `f` the bags became full, `o` they were no longer full, `w` the client said an
-- item could not be received because they were full. Nothing is written for other
-- changes.

local bagFree, bagTotal

local function BagSpace(why)
    if not CONT then return end
    local total = 0
    for bag = 0, _G.NUM_BAG_SLOTS or 4 do
        total = total + (Num(Call(CONT.GetContainerNumSlots, bag)) or 0)
    end
    local free = Num(Call(CONT.CalculateTotalNumberOfFreeBagSlots))
    if not free then return end
    local reason = why
    if bagTotal == nil then
        reason = reason or "s"
    elseif not reason then
        if total ~= bagTotal then
            reason = "t"
        elseif free == 0 and bagFree > 0 then
            reason = "f"
        elseif free > 0 and bagFree == 0 then
            reason = "o"
        end
    end
    bagFree, bagTotal = free, total
    if reason then Emit("BG", free, total, reason) end
end

function H.BAG_UPDATE_DELAYED() BagSpace() end
-- Fires once per item that did not fit: one line per burst.
local OVERFLOW_QUIET = 10
local lastOverflow = 0
function H.BAG_OVERFLOW_WITH_FULL_INVENTORY()
    local now = GetTime()
    if now - lastOverflow < OVERFLOW_QUIET then return end
    lastOverflow = now
    BagSpace("w")
end

-- Enchants, gems and upgrades on what you wear -----------------------------------------
-- EN <slot> <itemID> <enchantID> <gems> <was enchantID> <was gems>: the same item in
-- a slot has a new enchant or new gems. gems are itemIDs joined by commas. Swapping
-- the item itself is a G line.

local gear, gearReady, gearDue = {}, false, false

local function Parse(link)
    link = Str(link)
    local payload = link and link:match("item:([^|]*)")
    if not payload then return end
    local p = {}
    for v in (payload .. ":"):gmatch("([^:]*):") do p[#p + 1] = v end
    local id = tonumber(p[1])
    if not id then return end
    local gems = {}
    for i = 3, 6 do
        local g = tonumber(p[i])
        if g and g > 0 then gems[#gems + 1] = g end
    end
    return id, tonumber(p[2]) or 0, concat(gems, ",")
end

local function GearScan(silent)
    for slot = 1, 19 do
        local id, ench, gems = Parse(Call(_G.GetInventoryItemLink, "player", slot))
        local was = gear[slot]
        if id and was and was.id == id and not silent and (was.ench ~= ench or was.gems ~= gems) then
            ItemName(id)
            for g in gems:gmatch("%d+") do ItemName(tonumber(g)) end
            Emit("EN", slot, id, ench, gems, was.ench, was.gems)
        end
        gear[slot] = id and { id = id, ench = ench, gems = gems } or nil
    end
end

local function GearSoon()
    if gearDue or not gearReady then return end
    gearDue = true
    C_Timer.After(0.5, function()
        gearDue = false
        GearScan(false)
    end)
end

H.PLAYER_EQUIPMENT_CHANGED = GearSoon

function H.UNIT_INVENTORY_CHANGED(unit)
    if Plain(unit) and unit == "player" then GearSoon() end
end

-- WE <slot> <enchantID> <charges> <seconds>: a temporary weapon enchant (oil, poison,
-- shaman imbue) on slot 0 main hand, 1 off hand, 2 ranged. enchantID 0 when it ended.
local weaponEnchant = {}

function H.WEAPON_ENCHANT_CHANGED()
    if type(Enum) ~= "table" or type(Enum.WeaponSlot) ~= "table" then return end
    for _, slot in pairs(Enum.WeaponSlot) do
        local list = Call(ITEM.GetWeaponEnchantInfo, slot)
        local found
        if type(list) == "table" then
            for _, e in pairs(list) do
                if type(e) == "table" and Plain(e.hasEnchant) and e.hasEnchant and Num(e.enchantID) then
                    found = e
                    break
                end
            end
        end
        local id = found and Num(found.enchantID) or 0
        if id ~= (weaponEnchant[slot] or 0) then
            weaponEnchant[slot] = id
            local left = found and Num(found.timeLeft)
            Emit("WE", slot, id, found and Num(found.charges) or "", left and floor(left / 1000) or "")
        end
    end
end

-- IU <itemID> <upgrade level> <max level> <upgrades> <item level>: you upgraded an
-- item. The levels are from before the upgrade. The currency spent is a CU line.
if UPG and type(UPG.UpgradeItem) == "function" then
    hooksecurefunc(UPG, "UpgradeItem", function(numUpgrades)
        local id = LinkID(Call(UPG.GetItemHyperlink))
        if not id then return end
        local info = Call(UPG.GetItemUpgradeItemInfo)
        local r = Pack(UPG.GetItemUpgradeCurrentLevel)
        ItemName(id)
        Emit("IU", id, type(info) == "table" and Num(info.currUpgrade) or "",
            type(info) == "table" and Num(info.maxUpgrade) or "", Num(numUpgrades) or 1, r and Num(r[2]) or "")
    end)
end

-- Loot rolls ---------------------------------------------------------------------------
-- RW <kind> <itemID> <roll type> <roll> <extra>. roll type is the client's LootRollType
-- (0 pass, 1 need, 2 greed, 3 disenchant, 4 transmog). kind: o a roll was offered to
-- you (extra: milliseconds to decide), w you won (roll is your number, extra the
-- count), l someone else won an item you rolled on (roll is your number, extra the
-- winner's). Who won is not recorded. What you rolled is the RL line.

if type(_G.GetLootRollItemLink) == "function" then
    function H.START_LOOT_ROLL(rollID, rollTime)
        if not Num(rollID) then return end
        local id = LinkID(Call(_G.GetLootRollItemLink, rollID))
        if not id then return end
        ItemName(id)
        Emit("RW", "o", id, "", "", Num(rollTime) or "")
    end
end

function H.LOOT_ITEM_ROLL_WON(link, quantity, rollType, roll)
    local id = LinkID(link)
    if not id then return end
    ItemName(id)
    Emit("RW", "w", id, Num(rollType) or "", Num(roll) or "", Num(quantity) or "")
end

-- EncounterLootDropRollState -> LootRollType
local ROLL_OF = { [0] = 1, [1] = 1, [2] = 4, [3] = 2 }
local lootSettled = {}

function H.LOOT_HISTORY_UPDATE_DROP(encounterID, lootListKey)
    if not LH or not Num(encounterID) or not Num(lootListKey) then return end
    local key = encounterID .. ":" .. lootListKey
    if lootSettled[key] then return end
    local drop = Call(LH.GetSortedInfoForDrop, encounterID, lootListKey)
    if type(drop) ~= "table" or type(drop.winner) ~= "table" then return end
    if Count(lootSettled) > 200 then lootSettled = {} end
    lootSettled[key] = true
    if Plain(drop.winner.isSelf) and drop.winner.isSelf then return end -- LOOT_ITEM_ROLL_WON
    local how = ROLL_OF[Num(drop.playerRollState)]
    local id = LinkID(drop.itemHyperlink)
    if not how or not id then return end
    local mine
    if type(drop.rollInfos) == "table" then
        for _, r in ipairs(drop.rollInfos) do
            if type(r) == "table" and Plain(r.isSelf) and r.isSelf then
                mine = r
                break
            end
        end
    end
    ItemName(id)
    Emit("RW", "l", id, how, mine and Num(mine.roll) or "", Num(drop.winner.roll) or "")
end

-- BR <type> <id> <count> <specID>: a bonus roll paid out. type is the client's
-- identifier (`item`, `money`, `currency`, ...); id is the itemID or currencyID.
function H.BONUS_ROLL_RESULT(kind, link, quantity, specID)
    if not Str(kind) then return end
    local link2 = Str(link)
    local id = LinkID(link2) or (link2 and tonumber(link2:match("currency:(%d+)"))) or ""
    if type(id) == "number" and LinkID(link2) then ItemName(id) end
    Emit("BR", kind, id, Num(quantity) or "", Num(specID) or "")
end

-- LP <specID>: loot specialization, 0 when it follows your current spec.
local lootSpec
function H.PLAYER_LOOT_SPEC_UPDATED()
    local spec = Num(Call(_G.GetLootSpecialization))
    if not spec or spec == lootSpec then return end
    lootSpec = spec
    Emit("LP", spec)
end

-- WoW Token ----------------------------------------------------------------------------
-- TK p <copper>: the market price changed. TK b <result> and TK s <result>: the
-- client's result code for a buy or a sell. TK a: your token sold.

local tokenPrice

function H.TOKEN_MARKET_PRICE_UPDATED()
    local price = TOKEN and Num(Call(TOKEN.GetCurrentMarketPrice))
    if not price or price == tokenPrice then return end
    tokenPrice = price
    Emit("TK", "p", price)
end

function H.TOKEN_BUY_RESULT(result)
    if Num(result) then Emit("TK", "b", result) end
end

function H.TOKEN_SELL_RESULT(result)
    if Num(result) then Emit("TK", "s", result) end
end

function H.TOKEN_AUCTION_SOLD() Emit("TK", "a", "") end

-- Deleted items ------------------------------------------------------------------------
-- DI <itemID> <count>: you destroyed an item with the delete command. The item is the
-- last one you picked up from your bags and still hold on the cursor.

local held

if CONT and type(CONT.PickupContainerItem) == "function" then
    hooksecurefunc(CONT, "PickupContainerItem", function(bag, slot)
        local kind, id = GetCursorInfo()
        if not Plain(kind) or kind ~= "item" or not Num(id) then return end
        local info = Call(CONT.GetContainerItemInfo, bag, slot)
        held = { id = id, count = type(info) == "table" and Num(info.stackCount) or 1 }
    end)
end

function H.CURSOR_CHANGED()
    if not held then return end
    local kind, id = GetCursorInfo()
    if not Plain(kind) or kind ~= "item" or not Num(id) or id ~= held.id then held = nil end
end

if type(_G.DeleteCursorItem) == "function" then
    hooksecurefunc("DeleteCursorItem", function()
        local h = held
        held = nil
        if not h then return end
        ItemName(h.id)
        Emit("DI", h.id, h.count)
    end)
end

-- Session start ------------------------------------------------------------------------

local entered = false
function H.PLAYER_ENTERING_WORLD()
    if entered then return end
    entered = true
    C_Timer.After(6, function()
        GearScan(true)
        gearReady = true
        for bankType = 0, 2 do tabs[bankType] = Tabs(bankType) end
    end)
end

ns.Listen(frame, H)
