local _, ns = ...

local type, pcall, tostring = type, pcall, tostring
local floor, min = math.floor, math.min
local Emit, Plain = ns.Emit, ns.Plain

local LINES_PER_SESSION = 600
local BROWSE_LINES_PER_SESSION = 300
local REPEAT_SECONDS = 15 * 60
local ROWS_PER_EVENT = 50

local H = {}
local lastWritten = {}
local written, browseWritten = 0, 0

local function Num(v)
    if Plain(v) and type(v) == "number" and v == v then return v end
end

local function Copper(v)
    v = Num(v)
    if v and v >= 0 then return floor(v) end
end

local function Call(fn, ...)
    if type(fn) ~= "function" then return end
    local ok, v = pcall(fn, ...)
    if ok and Plain(v) then return v end
end

local function Write(kind, itemID, price, quantity, listings, itemLevel, suffix)
    if written >= LINES_PER_SESSION then return end
    local browse = kind == "b"
    if browse and browseWritten >= BROWSE_LINES_PER_SESSION then return end
    local key = kind .. ":" .. itemID .. ":" .. tostring(itemLevel) .. ":" .. tostring(suffix)
    local now = GetTime()
    local last = lastWritten[key]
    if last and now - last < REPEAT_SECONDS then return end
    lastWritten[key] = now
    written = written + 1
    if browse then browseWritten = browseWritten + 1 end
    ns.ItemName(itemID)
    Emit("AQ", kind, itemID, price, quantity, listings, itemLevel, suffix)
end

local function KeyParts(itemKey)
    if not Plain(itemKey) or type(itemKey) ~= "table" then return end
    local itemID = Num(itemKey.itemID)
    if not itemID or itemID <= 0 then return end
    local level, suffix = Num(itemKey.itemLevel), Num(itemKey.itemSuffix)
    return itemID, level and level > 0 and level or "", suffix and suffix > 0 and suffix or ""
end

function H.COMMODITY_SEARCH_RESULTS_UPDATED(itemID)
    local AH = C_AuctionHouse
    itemID = Num(itemID)
    if not AH or not itemID then return end
    local count = Num(Call(AH.GetNumCommoditySearchResults, itemID))
    if not count or count < 1 then return end
    local first = Call(AH.GetCommoditySearchResultInfo, itemID, 1)
    if type(first) ~= "table" then return end
    local price = Copper(first.unitPrice)
    if not price then return end
    Write("c", itemID, price, Num(Call(AH.GetCommoditySearchResultsQuantity, itemID)) or "", count, "", "")
end

function H.ITEM_SEARCH_RESULTS_UPDATED(itemKey)
    local AH = C_AuctionHouse
    local itemID, level, suffix = KeyParts(itemKey)
    if not AH or not itemID then return end
    local count = Num(Call(AH.GetNumItemSearchResults, itemKey))
    if not count or count < 1 then return end
    local lowest, items = nil, 0
    for i = 1, min(count, ROWS_PER_EVENT) do
        local row = Call(AH.GetItemSearchResultInfo, itemKey, i)
        if type(row) == "table" then
            local buyout = Copper(row.buyoutAmount)
            if buyout and buyout > 0 then
                if not lowest or buyout < lowest then lowest = buyout end
                items = items + (Num(row.quantity) or 1)
            end
        end
    end
    if not lowest then return end
    Write("i", itemID, lowest, items, count, level, suffix)
end

function H.AUCTION_HOUSE_BROWSE_RESULTS_UPDATED()
    local AH = C_AuctionHouse
    if not AH then return end
    local rows = Call(AH.GetBrowseResults)
    if type(rows) ~= "table" then return end
    for i = 1, min(#rows, ROWS_PER_EVENT) do
        local row = rows[i]
        if Plain(row) and type(row) == "table" then
            local itemID, level, suffix = KeyParts(row.itemKey)
            local price = Copper(row.minPrice)
            if itemID and price then
                Write("b", itemID, price, Num(row.totalQuantity) or "", "", level, suffix)
            end
        end
    end
end

ns.Listen(CreateFrame("Frame"), H, "Market")
