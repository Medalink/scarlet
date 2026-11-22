local _, ns = ...

local floor, max, min = math.floor, math.max, math.min
local format, tostring, tonumber = string.format, tostring, tonumber
local type, ipairs, pcall, strsplit, wipe = type, ipairs, pcall, strsplit, wipe
local GetTime = GetTime
local Plain = ns.Plain

local Gather = {}
ns.Gather = Gather

local ARM_WINDOW = 4
local FISH_CHANNEL_WINDOW = 35
local TAIL_WINDOW = 2
local BLOCK_TAIL = 2
local BOBBER_ID = "35591"
local FADE_DELAY = 12
local FADE_DURATION = 0.8
local GUILD_BANKER = 10

local REJECT_SOURCE = {
    fishing = { Creature = true, Vehicle = true },
    archaeology = { Creature = true, Vehicle = true },
    disenchanting = { Creature = true, Vehicle = true, GameObject = true },
}

local DEFAULT_FONT_SIZE = 13
local MIN_FONT_SIZE = 9
local MAX_FONT_SIZE = 24
local DEFAULT_SCALE = 1
local MIN_SCALE = 0.5
local MAX_SCALE = 2.5
local MIN_W = 220
local MAX_W = 720
local MIN_H = 72
local MAX_H = 600
local AUTO_MAX_H = 480

local PAD_LEFT = 14
local PAD_RIGHT = 12
local PAD_TOP = 10
local PAD_BOTTOM = 10
local HEADER_GAP = 8

local PREVIEW_ZONE = "Elwynn Forest"
local PREVIEW_BOX_H = 228
local PREVIEW_MAX_H = 200

local HEX_PROF = "ff6b8e"
local HEX_MUTED = "8a8a93"
local HEX_FG = "f0f1f3"
local HEX_TEXT = "cdced4"

local PROFS = {
    {
        key = "herbalism",
        label = "Herbalism",
        spells = { 2366, 2368, 3570, 11993, 28695, 50300, 74519, 110413, 158745, 195114 },
        fallback = "Herb Gathering",
        sample = { item = "Peacebloom", session = 6, total = 24, copper = 480 },
    },
    {
        key = "mining",
        label = "Mining",
        spells = { 2575, 2576, 3564, 10248, 29354, 50310, 74517, 102161, 158754, 195122, 32606 },
        fallback = "Mining",
        sample = { item = "Copper Ore", session = 9, total = 31, copper = 1550 },
    },
    {
        key = "skinning",
        label = "Skinning",
        spells = { 8613, 8617, 8618, 10768, 32678, 50305, 74522, 102216, 158756, 194174 },
        fallback = "Skinning",
        sample = { item = "Light Leather", session = 4, total = 18, copper = 900 },
    },
    {
        key = "fishing",
        label = "Fishing",
        spells = { 7620, 7731, 7732, 18248, 33095, 51294, 88868, 110410, 131474, 158743 },
        fallback = "Fishing",
        sample = { item = "Raw Brilliant Smallfish", session = 3, total = 11, copper = 165 },
    },
    {
        key = "archaeology",
        label = "Archaeology",
        spells = { 80451, 73979 },
        fallback = "Survey",
        sample = { item = "Dwarf Rune Stone", session = 2, total = 5, copper = 25000 },
    },
    {
        key = "disenchanting",
        label = "Disenchanting",
        spells = { 13262 },
        fallback = "Disenchant",
        sample = { item = "Strange Dust", session = 5, total = 22, copper = 8800 },
    },
}

local SPELL_PROF = {}
local PROF_LABEL = {}
for i = 1, #PROFS do
    local p = PROFS[i]
    PROF_LABEL[p.key] = p.label
    for j = 1, #p.spells do
        SPELL_PROF[p.spells[j]] = p.key
    end
end

local LOOT_PREFIXES = {}
for _, key in ipairs({
    "LOOT_ITEM_SELF",
    "LOOT_ITEM_SELF_MULTIPLE",
    "LOOT_ITEM_PUSHED_SELF",
    "LOOT_ITEM_PUSHED_SELF_MULTIPLE",
}) do
    local fmt = _G[key]
    local prefix = type(fmt) == "string" and fmt:match("^(.-)%%")
    if prefix and prefix ~= "" then
        LOOT_PREFIXES[#LOOT_PREFIXES + 1] = prefix
    end
end

local function Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function Round2(v)
    return floor(v * 100 + 0.5) / 100
end

local function Str(v)
    if Plain(v) and type(v) == "string" and v ~= "" then return v end
end

local function Num(v)
    if Plain(v) and type(v) == "number" and v == v then return v end
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

local fallbackOpt
local function Opt()
    local root = ns.opt
    local g
    if type(root) == "table" then
        if type(root.gather) ~= "table" then root.gather = {} end
        g = root.gather
    else
        if not fallbackOpt then fallbackOpt = {} end
        g = fallbackOpt
    end
    if g.enabled == nil then g.enabled = true end
    local fs = tonumber(g.fontSize)
    g.fontSize = Clamp(floor((fs or DEFAULT_FONT_SIZE) + 0.5), MIN_FONT_SIZE, MAX_FONT_SIZE)
    local sc = tonumber(g.scale)
    g.scale = Clamp(Round2(sc or DEFAULT_SCALE), MIN_SCALE, MAX_SCALE)
    if g.w ~= nil then
        local w = tonumber(g.w)
        g.w = w and Clamp(floor(w + 0.5), MIN_W, MAX_W) or nil
    end
    if g.h ~= nil then
        local h = tonumber(g.h)
        g.h = h and Clamp(floor(h + 0.5), MIN_H, MAX_H) or nil
    end
    if type(g.pos) ~= "table" or type(g.pos.x) ~= "number" or type(g.pos.y) ~= "number" then
        g.pos = nil
    end
    if type(g.prof) ~= "table" then
        g.prof = {}
    end
    return g
end

local function IsProfEnabled(key)
    return Opt().prof[key] ~= false
end

local spellNames = {}
local spellNamesSeeded = false
local spellCache = {}

local function SeedSpellNames()
    local api = _G.C_Spell
    local getSpellName = api and api.GetSpellName
    local gotLocalized = false
    for i = 1, #PROFS do
        local p = PROFS[i]
        if p.fallback and not spellNames[p.fallback] then
            spellNames[p.fallback] = p.key
        end
        if type(getSpellName) == "function" then
            for j = 1, #p.spells do
                local name = Str(Call(getSpellName, p.spells[j]))
                if name then
                    spellNames[name] = p.key
                    gotLocalized = true
                end
            end
        end
    end
    if gotLocalized then
        spellNamesSeeded = true
    end
end

local function ResolveSpell(spellID)
    spellID = Num(spellID)
    if not spellID then return nil end
    local direct = SPELL_PROF[spellID]
    if direct then return direct end
    local cached = spellCache[spellID]
    if cached ~= nil then return cached or nil end
    if not spellNamesSeeded then SeedSpellNames() end
    local api = _G.C_Spell
    local name = api and Str(Call(api.GetSpellName, spellID))
    if not name then return nil end
    local matched = spellNames[name] or false
    spellCache[spellID] = matched
    return matched or nil
end

local function ItemCount(itemID)
    local fn = (_G.C_Item and _G.C_Item.GetItemCount) or _G.GetItemCount
    local n = Num(Call(fn, itemID, false))
    return n and max(0, floor(n)) or 0
end

local function UnitPrice(itemID)
    local auc = _G.Auctionator
    if Plain(auc) and type(auc) == "table" then
        local api = auc.API
        if Plain(api) and type(api) == "table" then
            local v1 = api.v1
            if Plain(v1) and type(v1) == "table" then
                local p = Num(Call(v1.GetAuctionPriceByItemID, "Scarlet", itemID))
                if p and p > 0 then return floor(p) end
            end
        end
    end
    local tsm = _G.TSM_API
    if Plain(tsm) and type(tsm) == "table" then
        local p = Num(Call(tsm.GetCustomPriceValue, "DBMarket", "i:" .. itemID))
        if p and p > 0 then return floor(p) end
    end
    if ns.MarketPrice then
        local p = Num(Call(ns.MarketPrice, itemID))
        if p and p > 0 then return floor(p) end
    end
    local r = Pack(_G.C_Item and _G.C_Item.GetItemInfo, itemID)
    if not (r and Str(r[2])) then
        Call(_G.C_Item and _G.C_Item.RequestLoadItemDataByID, itemID)
        return 0
    end
    local vendor = Num(r[12])
    if vendor and vendor > 0 then return floor(vendor) end
    return 0
end

local entries = {}
local entryByKey = {}
local currentZone = nil
local uiRef = nil

local hud = nil
local hudDisplay = nil
local hudFade = nil
local scaleBadge = nil
local scaleBadgeText = nil
local handles = {}

local settingsView = nil

local hudState = {
    mode = "hidden",
    drag = "none",
    hovered = false,
    fadeToken = 0,
}

local function ReadZone()
    local z = Str(Call(_G.GetRealZoneText)) or Str(Call(_G.GetZoneText)) or Str(Call(_G.GetSubZoneText))
    if z then currentZone = z end
end

local function BuildSampleRows()
    local out = {}
    for i = 1, #PROFS do
        local p = PROFS[i]
        if IsProfEnabled(p.key) then
            out[#out + 1] = {
                prof = p.key,
                profLabel = p.label,
                name = p.sample.item,
                session = p.sample.session,
                total = p.sample.total,
                totalCopper = p.sample.copper,
            }
        end
    end
    return out
end

local function BuildLiveRows()
    local out = {}
    for i = 1, #entries do
        local e = entries[i]
        if IsProfEnabled(e.prof) then
            out[#out + 1] = e
        end
    end
    return out
end

local function FormatRow(ui, row)
    return format(
        "|cff%s%s|r |cff%s-|r |cff%s%s|r |cff%s%d / %d|r %s",
        HEX_PROF,
        row.profLabel,
        HEX_MUTED,
        HEX_FG,
        row.name,
        HEX_TEXT,
        row.session,
        row.total,
        (row.totalCopper or 0) > 0 and ui.Money(row.totalCopper) or ("|cff" .. HEX_MUTED .. "-|r")
    )
end

local function CreateDisplay(parent, ui, scrollable)
    local T = ui.T
    local frame = CreateFrame("Frame", nil, parent)
    ui.Fill(frame, T.bg, 0.94):SetAllPoints()
    ui.Border(frame, T.line2)

    local rail = ui.Fill(frame, T.accent, 1, "ARTWORK")
    rail:SetPoint("TOPLEFT", 1, -1)
    rail:SetPoint("BOTTOMLEFT", 1, 1)
    rail:SetWidth(2)

    local header = frame:CreateFontString(nil, "OVERLAY")
    header:SetPoint("TOPLEFT", PAD_LEFT, -PAD_TOP)
    header:SetPoint("TOPRIGHT", -PAD_RIGHT, -PAD_TOP)
    header:SetJustifyH("LEFT")
    header:SetWordWrap(false)
    header:SetTextColor(T.fg[1], T.fg[2], T.fg[3])

    local rule = ui.Fill(frame, T.line2, nil, "ARTWORK")
    rule:SetHeight(1)

    local viewport
    local scrollChild
    if scrollable then
        viewport = CreateFrame("ScrollFrame", nil, frame)
        viewport:EnableMouseWheel(true)
        scrollChild = CreateFrame("Frame", nil, viewport)
        scrollChild:SetSize(1, 1)
        viewport:SetScrollChild(scrollChild)
    else
        viewport = CreateFrame("Frame", nil, frame)
        if viewport.SetClipsChildren then viewport:SetClipsChildren(true) end
        scrollChild = viewport
    end

    local display = {
        ui = ui,
        frame = frame,
        header = header,
        rule = rule,
        scroll = viewport,
        scrollChild = scrollChild,
        scrollable = scrollable and true or false,
        rows = {},
        rowH = 24,
        contentTop = 40,
        listH = 24,
        fontSize = DEFAULT_FONT_SIZE,
    }

    if scrollable then
        viewport:SetScript("OnMouseWheel", function(self, delta)
            local maxScroll = max(0, display.listH - self:GetHeight())
            local nextScroll = Clamp(self:GetVerticalScroll() - delta * display.rowH * 2, 0, maxScroll)
            self:SetVerticalScroll(nextScroll)
        end)
    end

    return display
end

local function ReflowDisplay(display, width, height)
    local innerW = max(60, width - PAD_LEFT - PAD_RIGHT)
    if display.scrollable then
        display.scrollChild:SetSize(innerW, max(1, display.listH))
    end
    for i = 1, #display.rows do
        local fs = display.rows[i]
        if fs:IsShown() then
            fs:SetWidth(innerW)
        end
    end
    if display.scrollable then
        local viewH = max(1, height - display.contentTop - PAD_BOTTOM)
        local maxScroll = max(0, display.listH - viewH)
        display.scroll:EnableMouseWheel(maxScroll > 0)
        if display.scroll:GetVerticalScroll() > maxScroll then
            display.scroll:SetVerticalScroll(maxScroll)
        end
    end
end

local function TextWidth(fs)
    local w = fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth()
    return Num(w) or 0
end

local function RenderDisplay(display, zone, list, fontSize, width, fixedHeight, emptyText, skipFrameSize)
    local ui = display.ui
    local T = ui.T
    fontSize = Clamp(floor((fontSize or DEFAULT_FONT_SIZE) + 0.5), MIN_FONT_SIZE, MAX_FONT_SIZE)
    display.fontSize = fontSize

    ui.SetFont(display.header, ui.Face("strong"), fontSize + 1)
    display.header:SetText("Zone: " .. (zone or "Unknown"))

    local headerH = floor((fontSize + 1) * 1.35 + 2)
    display.header:SetHeight(headerH)

    local ruleY = -(PAD_TOP + headerH + 4)
    display.rule:ClearAllPoints()
    display.rule:SetPoint("TOPLEFT", PAD_LEFT, ruleY)
    display.rule:SetPoint("TOPRIGHT", -PAD_RIGHT, ruleY)

    local contentTop = PAD_TOP + headerH + HEADER_GAP + 1
    display.contentTop = contentTop
    display.scroll:ClearAllPoints()
    display.scroll:SetPoint("TOPLEFT", PAD_LEFT, -contentTop)
    display.scroll:SetPoint("BOTTOMRIGHT", -PAD_RIGHT, PAD_BOTTOM)

    local rowH = floor(fontSize * 1.55 + 4)
    display.rowH = rowH

    local count = #list
    local shownCount = max(1, count)
    local listH = shownCount * rowH
    display.listH = listH

    local autoH = Clamp(contentTop + listH + PAD_BOTTOM, MIN_H, AUTO_MAX_H)
    local frameH = fixedHeight and Clamp(fixedHeight, MIN_H, MAX_H) or autoH

    local bodyFace = ui.Face("body")
    local color = count == 0 and T.muted or T.fg
    local widest = TextWidth(display.header)
    for i = 1, shownCount do
        local fs = display.rows[i]
        if not fs then
            fs = display.scrollChild:CreateFontString(nil, "OVERLAY")
            fs:SetJustifyH("LEFT")
            fs:SetJustifyV("MIDDLE")
            fs:SetWordWrap(false)
            display.rows[i] = fs
        end
        ui.SetFont(fs, bodyFace, fontSize)
        fs:SetTextColor(color[1], color[2], color[3])
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", 0, -(i - 1) * rowH)
        fs:SetSize(0, rowH)
        fs:SetText(count == 0 and (emptyText or "No professions selected") or FormatRow(ui, list[i]))
        fs:Show()
        widest = max(widest, TextWidth(fs))
    end
    for i = shownCount + 1, #display.rows do
        display.rows[i]:Hide()
    end

    local frameW = width or Clamp(floor(widest + 0.5) + PAD_LEFT + PAD_RIGHT + 4, MIN_W, MAX_W)
    if not skipFrameSize then
        display.frame:SetSize(frameW, frameH)
    end
    local innerW = max(60, frameW - PAD_LEFT - PAD_RIGHT)
    if display.scrollable then
        display.scrollChild:SetSize(innerW, max(1, listH))
    end
    for i = 1, shownCount do
        display.rows[i]:SetWidth(innerW)
    end

    if display.scrollable then
        local viewH = max(1, frameH - contentTop - PAD_BOTTOM)
        local maxScroll = max(0, listH - viewH)
        display.scroll:EnableMouseWheel(maxScroll > 0)
        if display.scroll:GetVerticalScroll() > maxScroll then
            display.scroll:SetVerticalScroll(maxScroll)
        end
    end

    return frameH, frameW
end

local function RefreshSettings()
    if settingsView and settingsView.Refresh then
        settingsView.Refresh()
    end
end

local function RefreshLayoutReadout()
    if settingsView and settingsView.RefreshReadout then
        settingsView.RefreshReadout()
    end
end

local function CancelFade()
    hudState.fadeToken = hudState.fadeToken + 1
    if hudFade then hudFade:Stop() end
end

local function IsHudHovered()
    if not hud or not hud:IsShown() then return false end
    if hud:IsMouseOver() then return true end
    for i = 1, #handles do
        if handles[i]:IsMouseOver() then return true end
    end
    return false
end

local function ScheduleFade()
    hudState.fadeToken = hudState.fadeToken + 1
    local token = hudState.fadeToken
    C_Timer.After(FADE_DELAY, function()
        if token ~= hudState.fadeToken then return end
        if hudState.mode ~= "active" then return end
        hudState.hovered = IsHudHovered()
        if hudState.hovered or hudState.drag ~= "none" then
            ScheduleFade()
            return
        end
        hudState.mode = "fading"
        if hudFade then
            hudFade:Stop()
            hudFade:Play()
        end
    end)
end

local function SaveHudPos()
    if not hud then return end
    local left, top = hud:GetLeft(), hud:GetTop()
    if not left or not top then return end
    local scale = hud:GetScale() or 1
    Opt().pos = { x = Round2(left * scale), y = Round2(top * scale) }
end

local function ApplyHudLayout()
    if not hud then return end
    local opt = Opt()
    local s = opt.scale
    hud:SetScale(s)
    hud:ClearAllPoints()
    if opt.pos then
        hud:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", opt.pos.x / s, opt.pos.y / s)
    else
        hud:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -24, -220)
    end
end

local function RefreshHud()
    if not hud or not hudDisplay then return end
    local opt = Opt()
    local list = BuildLiveRows()
    local zone = currentZone
    if hudState.mode == "pinned" and #list == 0 then
        list = BuildSampleRows()
        zone = zone or PREVIEW_ZONE
    end
    local targetH, targetW = RenderDisplay(
        hudDisplay,
        zone,
        list,
        opt.fontSize,
        opt.w,
        opt.h,
        "No professions selected",
        true
    )
    if hudState.drag ~= "resize" then
        hud:SetSize(targetW, targetH)
    end
end

local function EndDrag()
    hudState.drag = "none"
    hudState.hovered = IsHudHovered()
    if hudState.mode == "active" and not hudState.hovered then
        ScheduleFade()
    end
end

local function SyncHover()
    local nowHovered = IsHudHovered()
    if nowHovered == hudState.hovered then return end
    hudState.hovered = nowHovered
    if nowHovered then
        if hudState.mode == "fading" then
            CancelFade()
            hud:SetAlpha(1)
            hudState.mode = "active"
        end
    elseif hudState.mode == "active" and hudState.drag == "none" then
        ScheduleFade()
    end
end

local function KeepResizedSize(w, h)
    local opt = Opt()
    if hudState.resizeW and math.abs(w - hudState.startW) >= 1 then opt.w = Clamp(floor(w + 0.5), MIN_W, MAX_W) end
    if hudState.resizeH and math.abs(h - hudState.startH) >= 1 then opt.h = Clamp(floor(h + 0.5), MIN_H, MAX_H) end
end

local function CreateResizeHandle(parent, ui, point)
    local sizesW = point:find("LEFT") ~= nil or point:find("RIGHT") ~= nil
    local sizesH = point:find("TOP") ~= nil or point:find("BOTTOM") ~= nil
    local T = ui.T
    local h = CreateFrame("Frame", nil, parent)
    h:SetFrameLevel((parent:GetFrameLevel() or 0) + 3)
    h:EnableMouse(true)

    local marks = {}
    local function AddMark(a1, a2, w, ht)
        local t = ui.Fill(h, T.accent, 0.55, "OVERLAY")
        t:SetPoint(a1)
        if a2 then t:SetPoint(a2) end
        if w then t:SetWidth(w) end
        if ht then t:SetHeight(ht) end
        t:Hide()
        marks[#marks + 1] = t
    end

    if point == "TOP" then
        h:SetPoint("TOPLEFT", 10, 0)
        h:SetPoint("TOPRIGHT", -10, 0)
        h:SetHeight(6)
        AddMark("TOPLEFT", "TOPRIGHT", nil, 2)
    elseif point == "BOTTOM" then
        h:SetPoint("BOTTOMLEFT", 10, 0)
        h:SetPoint("BOTTOMRIGHT", -10, 0)
        h:SetHeight(6)
        AddMark("BOTTOMLEFT", "BOTTOMRIGHT", nil, 2)
    elseif point == "LEFT" then
        h:SetPoint("TOPLEFT", 0, -10)
        h:SetPoint("BOTTOMLEFT", 0, 10)
        h:SetWidth(6)
        AddMark("TOPLEFT", "BOTTOMLEFT", 2, nil)
    elseif point == "RIGHT" then
        h:SetPoint("TOPRIGHT", 0, -10)
        h:SetPoint("BOTTOMRIGHT", 0, 10)
        h:SetWidth(6)
        AddMark("TOPRIGHT", "BOTTOMRIGHT", 2, nil)
    elseif point == "TOPLEFT" then
        h:SetPoint("TOPLEFT")
        h:SetSize(10, 10)
        AddMark("TOPLEFT", "TOPRIGHT", nil, 2)
        AddMark("TOPLEFT", "BOTTOMLEFT", 2, nil)
    elseif point == "TOPRIGHT" then
        h:SetPoint("TOPRIGHT")
        h:SetSize(10, 10)
        AddMark("TOPLEFT", "TOPRIGHT", nil, 2)
        AddMark("TOPRIGHT", "BOTTOMRIGHT", 2, nil)
    elseif point == "BOTTOMLEFT" then
        h:SetPoint("BOTTOMLEFT")
        h:SetSize(10, 10)
        AddMark("BOTTOMLEFT", "BOTTOMRIGHT", nil, 2)
        AddMark("TOPLEFT", "BOTTOMLEFT", 2, nil)
    elseif point == "BOTTOMRIGHT" then
        h:SetPoint("BOTTOMRIGHT")
        h:SetSize(10, 10)
        AddMark("BOTTOMLEFT", "BOTTOMRIGHT", nil, 2)
        AddMark("TOPRIGHT", "BOTTOMRIGHT", 2, nil)
    end

    local function ShowMarks(show)
        for i = 1, #marks do marks[i]:SetShown(show) end
    end

    h:SetScript("OnEnter", function()
        ShowMarks(true)
        SyncHover()
    end)
    h:SetScript("OnLeave", function()
        ShowMarks(false)
        SyncHover()
    end)
    h:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        if hudState.mode == "fading" then
            CancelFade()
            hud:SetAlpha(1)
            hudState.mode = "active"
        end
        hudState.drag = "resize"
        hudState.resizeW, hudState.resizeH = sizesW, sizesH
        hudState.startW, hudState.startH = hud:GetWidth(), hud:GetHeight()
        hud:StartSizing(point)
    end)
    h:SetScript("OnMouseUp", function(_, button)
        if button ~= "LeftButton" or hudState.drag ~= "resize" then return end
        hud:StopMovingOrSizing()
        KeepResizedSize(hud:GetWidth(), hud:GetHeight())
        SaveHudPos()
        ApplyHudLayout()
        EndDrag()
        RefreshHud()
        RefreshSettings()
    end)

    return h
end

local function BuildHud()
    if hud then return end
    uiRef = uiRef or ns.UI
    if not uiRef then return end
    local ui = uiRef
    local T = ui.T

    hud = CreateFrame("Frame", "ScarletGatherPopup", UIParent)
    hud:SetFrameStrata("MEDIUM")
    hud:SetClampedToScreen(true)
    hud:SetMovable(true)
    hud:SetResizable(true)
    hud:EnableMouse(true)

    if hud.SetResizeBounds then
        hud:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
    else
        if hud.SetMinResize then hud:SetMinResize(MIN_W, MIN_H) end
        if hud.SetMaxResize then hud:SetMaxResize(MAX_W, MAX_H) end
    end

    hudDisplay = CreateDisplay(hud, ui, true)
    hudDisplay.frame:SetAllPoints(hud)

    scaleBadge = CreateFrame("Frame", nil, hud)
    scaleBadge:SetFrameLevel((hud:GetFrameLevel() or 0) + 5)
    scaleBadge:SetSize(52, 20)
    scaleBadge:SetPoint("TOPRIGHT", -6, -6)
    ui.Fill(scaleBadge, T.card, 0.96):SetAllPoints()
    ui.Border(scaleBadge, T.accent)
    scaleBadgeText = scaleBadge:CreateFontString(nil, "OVERLAY")
    scaleBadgeText:SetPoint("CENTER")
    scaleBadgeText:SetTextColor(T.fg[1], T.fg[2], T.fg[3])
    ui.SetFont(scaleBadgeText, ui.Face("strong"), 11)
    scaleBadge:Hide()

    hudFade = hud:CreateAnimationGroup()
    local alpha = hudFade:CreateAnimation("Alpha")
    alpha:SetFromAlpha(1)
    alpha:SetToAlpha(0)
    alpha:SetDuration(FADE_DURATION)
    if hudFade.SetToFinalAlpha then hudFade:SetToFinalAlpha(true) end
    hudFade:SetScript("OnFinished", function()
        if hudState.mode ~= "fading" then return end
        hudState.mode = "hidden"
        hud:Hide()
        hud:SetAlpha(1)
    end)

    local points = { "TOP", "BOTTOM", "LEFT", "RIGHT", "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT" }
    for i = 1, #points do
        handles[i] = CreateResizeHandle(hud, ui, points[i])
    end

    local scaleDrag = {}

    local function FinishScaleDrag()
        hud:SetScript("OnUpdate", nil)
        scaleBadge:Hide()
        local opt = Opt()
        opt.scale = Clamp(Round2(hud:GetScale()), MIN_SCALE, MAX_SCALE)
        SaveHudPos()
        EndDrag()
        RefreshSettings()
    end

    hud:SetScript("OnEnter", SyncHover)
    hud:SetScript("OnLeave", SyncHover)

    hud:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        if hudState.mode == "fading" then
            CancelFade()
            self:SetAlpha(1)
            hudState.mode = "active"
        end
        if IsShiftKeyDown() then
            local cx, cy = GetCursorPosition()
            local startScale = self:GetScale() or 1
            local uiScale = UIParent:GetEffectiveScale()
            if not uiScale or uiScale <= 0 then uiScale = 1 end
            local left, top = self:GetLeft() or 0, self:GetTop() or 0
            scaleDrag.startCX = cx
            scaleDrag.startCY = cy
            scaleDrag.startScale = startScale
            scaleDrag.uiScale = uiScale
            scaleDrag.anchorUX = left * startScale
            scaleDrag.anchorUY = top * startScale
            hudState.drag = "scale"
            scaleBadgeText:SetText(format("%.2fx", startScale))
            scaleBadge:Show()
            self:SetScript("OnUpdate", function(frame)
                if not IsMouseButtonDown("LeftButton") then
                    FinishScaleDrag()
                    return
                end
                local nx, ny = GetCursorPosition()
                local dx = (nx - scaleDrag.startCX) / scaleDrag.uiScale
                local dy = (scaleDrag.startCY - ny) / scaleDrag.uiScale
                local newScale = Clamp(Round2(scaleDrag.startScale + (dx + dy) / 240), MIN_SCALE, MAX_SCALE)
                frame:SetScale(newScale)
                frame:ClearAllPoints()
                frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", scaleDrag.anchorUX / newScale,
                    scaleDrag.anchorUY / newScale)
                Opt().scale = newScale
                scaleBadgeText:SetText(format("%.2fx", newScale))
                RefreshLayoutReadout()
            end)
        else
            hudState.drag = "move"
            self:StartMoving()
        end
    end)

    hud:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        if hudState.drag == "scale" then
            FinishScaleDrag()
        elseif hudState.drag == "move" then
            self:StopMovingOrSizing()
            SaveHudPos()
            ApplyHudLayout()
            EndDrag()
        end
    end)

    hud:SetScript("OnSizeChanged", function(_, w, h)
        if hudDisplay and w and h and w > 0 and h > 0 then
            ReflowDisplay(hudDisplay, w, h)
            if hudState.drag == "resize" then
                KeepResizedSize(w, h)
                RefreshLayoutReadout()
            end
        end
    end)

    hud:SetScript("OnHide", function(self)
        if hudState.drag == "scale" then
            self:SetScript("OnUpdate", nil)
            scaleBadge:Hide()
            Opt().scale = Clamp(Round2(self:GetScale()), MIN_SCALE, MAX_SCALE)
            SaveHudPos()
            hudState.drag = "none"
        elseif hudState.drag == "move" or hudState.drag == "resize" then
            self:StopMovingOrSizing()
            if hudState.drag == "resize" then KeepResizedSize(self:GetWidth(), self:GetHeight()) end
            SaveHudPos()
            ApplyHudLayout()
            hudState.drag = "none"
        end
        hudState.hovered = false
    end)

    ApplyHudLayout()
    hud:Hide()
end

local function PokeHud()
    if not Opt().enabled then return end
    if not hud then BuildHud() end
    if not hud then return end
    if hudState.mode == "pinned" then
        RefreshHud()
        return
    end
    CancelFade()
    hud:SetAlpha(1)
    RefreshHud()
    hud:Show()
    hudState.mode = "active"
    ScheduleFade()
end

local function Lifetime()
    local ch = ns.char
    if type(ch) ~= "table" then return nil end
    if type(ch.gather) ~= "table" then ch.gather = {} end
    return ch.gather
end

local function PriceBags(e)
    e.totalCopper = ItemCount(e.itemID) * UnitPrice(e.itemID)
end

local function RecordGather(prof, itemID, count, linkName)
    local key = prof .. ":" .. itemID
    local entry = entryByKey[key]
    local resolvedName = Str(Call(_G.C_Item and _G.C_Item.GetItemNameByID, itemID))
    if entry then
        entry.session = entry.session + count
        if resolvedName then entry.name = resolvedName end
    else
        local name = resolvedName or Str(linkName) or ("Item " .. itemID)
        entry = {
            key = key,
            prof = prof,
            profLabel = PROF_LABEL[prof] or prof,
            itemID = itemID,
            name = name,
            session = count,
            total = 0,
            totalCopper = 0,
        }
        entryByKey[key] = entry
        entries[#entries + 1] = entry
    end
    local life = Lifetime()
    if life then
        life[key] = (tonumber(life[key]) or 0) + count
        entry.total = life[key]
    else
        entry.total = entry.session
    end
    PriceBags(entry)
    if not currentZone then ReadZone() end
    if IsProfEnabled(prof) then PokeHud() end
end

local capture = {
    phase = "idle",
    prof = nil,
    at = 0,
}

local blocks = {}
local blockedUntil = 0

local function IsBlocked(now)
    return next(blocks) ~= nil or now <= blockedUntil
end

local function LootSourceKind()
    local slots = Num(Call(_G.GetNumLootItems)) or 1
    for slot = 1, max(1, slots) do
        local r = Pack(_G.GetLootSourceInfo, slot)
        local guid = r and Str(r[2])
        if guid then
            local kind, _, _, _, _, id = strsplit("-", guid)
            return kind, kind == "GameObject" and id == BOBBER_ID
        end
    end
    return nil, false
end

local H = {}

local function OnCastStart(_, _, spellID)
    local prof = ResolveSpell(spellID)
    if prof then
        capture.phase = "casting"
        capture.prof = prof
        capture.at = GetTime()
    end
end

H.UNIT_SPELLCAST_START = OnCastStart
H.UNIT_SPELLCAST_CHANNEL_START = OnCastStart

function H.UNIT_SPELLCAST_SUCCEEDED(_, _, spellID)
    local prof = ResolveSpell(spellID)
    if prof then
        capture.phase = prof == "fishing" and "casting" or "armed"
        capture.prof = prof
        capture.at = GetTime()
    end
end

function H.UNIT_SPELLCAST_CHANNEL_STOP()
    if capture.phase == "casting" and capture.prof == "fishing" then
        capture.phase = "armed"
        capture.at = GetTime()
    end
end

function H.UNIT_SPELLCAST_INTERRUPTED()
    if capture.phase == "casting" then
        capture.phase = "idle"
        capture.prof = nil
    end
end

local function OpenBlock(name)
    blocks[name] = true
    capture.phase = "idle"
    capture.prof = nil
end

local function CloseBlock(name)
    if blocks[name] then
        blocks[name] = nil
        blockedUntil = GetTime() + BLOCK_TAIL
    end
end

for name, pair in pairs({
    merchant = { "MERCHANT_SHOW", "MERCHANT_CLOSED" },
    bank = { "BANKFRAME_OPENED", "BANKFRAME_CLOSED" },
    mail = { "MAIL_SHOW", "MAIL_CLOSED" },
    trade = { "TRADE_SHOW", "TRADE_CLOSED" },
    auction = { "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED" },
}) do
    H[pair[1]] = function() OpenBlock(name) end
    H[pair[2]] = function() CloseBlock(name) end
end

function H.PLAYER_INTERACTION_MANAGER_FRAME_SHOW(kind)
    if Plain(kind) and kind == GUILD_BANKER then OpenBlock("guildbank") end
end

function H.PLAYER_INTERACTION_MANAGER_FRAME_HIDE(kind)
    if Plain(kind) and kind == GUILD_BANKER then CloseBlock("guildbank") end
end

local function OnLootOpen()
    local now = GetTime()
    local resolved = nil
    if Call(_G.IsFishingLoot) == true then
        resolved = "fishing"
    else
        local sourceKind, isBobber = LootSourceKind()
        local window = (capture.phase == "casting" and capture.prof == "fishing") and FISH_CHANNEL_WINDOW or ARM_WINDOW
        if isBobber then
            resolved = "fishing"
        elseif (capture.phase == "armed" or capture.phase == "casting" or capture.phase == "looting")
            and capture.prof and (now - capture.at <= window) then
            local rejects = REJECT_SOURCE[capture.prof]
            if not (rejects and sourceKind and rejects[sourceKind]) then
                resolved = capture.prof
            end
        end
    end
    if resolved then
        capture.phase = "looting"
        capture.prof = resolved
        capture.at = now
    else
        capture.phase = "idle"
        capture.prof = nil
    end
end

H.LOOT_READY = OnLootOpen
H.LOOT_OPENED = OnLootOpen

function H.LOOT_CLOSED()
    if capture.phase == "looting" then
        capture.phase = "tail"
        capture.at = GetTime()
    end
end

function H.CHAT_MSG_LOOT(text)
    if not Plain(text) or type(text) ~= "string" then return end
    local now = GetTime()
    if IsBlocked(now) then return end
    local matchedPrefix = false
    for i = 1, #LOOT_PREFIXES do
        local prefix = LOOT_PREFIXES[i]
        if text:sub(1, #prefix) == prefix then
            matchedPrefix = true
            break
        end
    end
    if not matchedPrefix then return end
    local itemID = tonumber(text:match("|Hitem:(%d+)"))
    if not itemID then return end
    local count = tonumber(text:match("|h|rx(%d+)")) or 1
    local linkName = text:match("|h%[(.-)%]|h")
    local activeProf = nil
    if capture.phase == "looting" then
        activeProf = capture.prof
    elseif capture.phase == "tail" and (now - capture.at <= TAIL_WINDOW) then
        activeProf = capture.prof
    end
    if activeProf then
        RecordGather(activeProf, itemID, count, linkName)
    end
end

local function OnZoneChanged()
    ReadZone()
    if hud and hud:IsShown() then
        RefreshHud()
    end
end

H.ZONE_CHANGED = OnZoneChanged
H.ZONE_CHANGED_NEW_AREA = OnZoneChanged
H.ZONE_CHANGED_INDOORS = OnZoneChanged

function H.PLAYER_ENTERING_WORLD()
    wipe(blocks)
    OnZoneChanged()
end

function H.BAG_UPDATE_DELAYED()
    if #entries == 0 then return end
    for i = 1, #entries do
        PriceBags(entries[i])
    end
    if hud and hud:IsShown() then
        RefreshHud()
    end
end

function H.GET_ITEM_INFO_RECEIVED(itemID, success)
    itemID = Num(itemID)
    if not itemID or not (Plain(success) and success) then return end
    local dirty = false
    local name = Str(Call(_G.C_Item and _G.C_Item.GetItemNameByID, itemID))
    for i = 1, #entries do
        local e = entries[i]
        if e.itemID == itemID then
            if name then e.name = name end
            PriceBags(e)
            dirty = true
        end
    end
    if dirty and hud and hud:IsShown() then
        RefreshHud()
    end
end

ns.Listen(CreateFrame("Frame"), H, "Gather")

function Gather.Init(ui)
    uiRef = ui
    Opt()
    ReadZone()
    BuildHud()
end

function Gather.OnFontChanged()
    if scaleBadgeText and uiRef then
        uiRef.SetFont(scaleBadgeText, uiRef.Face("strong"), 11)
    end
    if hud and hud:IsShown() then
        RefreshHud()
    end
    RefreshSettings()
end

function Gather.TogglePreview()
    if not hud then BuildHud() end
    if not hud then return end
    if hudState.mode == "pinned" then
        CancelFade()
        hudState.mode = "hidden"
        hud:Hide()
    else
        CancelFade()
        hudState.mode = "pinned"
        hud:SetAlpha(1)
        RefreshHud()
        hud:Show()
    end
    RefreshSettings()
end

function Gather.ResetLayout()
    local opt = Opt()
    opt.pos = nil
    opt.scale = DEFAULT_SCALE
    opt.w = nil
    opt.h = nil
    if hud then
        ApplyHudLayout()
        RefreshHud()
    end
    RefreshSettings()
end

function Gather.ResetSession()
    wipe(entries)
    wipe(entryByKey)
    if hud and hud:IsShown() then
        RefreshHud()
    end
end

local function SecondaryButton(parent, ui, label, width, height, onClick)
    local T = ui.T
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width, height)
    ui.Fill(b, T.card):SetAllPoints()
    ui.Border(b, T.line2)
    local hover = ui.Fill(b, T.fg, 0.06, "BORDER")
    hover:SetAllPoints()
    hover:Hide()
    local text = ui.Text(b, 13, T.fg, "CENTER", "strong")
    text:SetPoint("CENTER")
    text:SetText(label)
    b.label = text
    b:SetScript("OnEnter", function() hover:Show() end)
    b:SetScript("OnLeave", function() hover:Hide() end)
    b:SetScript("OnClick", onClick)
    return b
end

function Gather.BuildSection(parent, ui, startY)
    uiRef = uiRef or ui
    local T = ui.T
    local section = CreateFrame("Frame", nil, parent)
    section:SetPoint("TOPLEFT", 0, startY)
    section:SetPoint("TOPRIGHT", 0, startY)

    local heading = ui.Text(section, 24, T.fg, "LEFT", "display")
    heading:SetPoint("TOPLEFT", 0, 0)
    heading:SetText("Gathering popup")

    local topRule = ui.Fill(section, T.line, nil, "ARTWORK")
    topRule:SetPoint("TOPLEFT", 0, -34)
    topRule:SetPoint("TOPRIGHT", 0, -34)
    topRule:SetHeight(1)

    local enabledToggle = ui.Toggle(section, -34, "Show gathering popup",
        function() return Opt().enabled end,
        function(v)
            Opt().enabled = v
            if not v and hud and (hudState.mode == "active" or hudState.mode == "fading") then
                CancelFade()
                hudState.mode = "hidden"
                hud:Hide()
            end
        end)

    local previewBox = CreateFrame("Frame", nil, section)
    previewBox:SetPoint("TOPLEFT", 0, -92)
    previewBox:SetPoint("TOPRIGHT", 0, -92)
    previewBox:SetHeight(PREVIEW_BOX_H)
    ui.Fill(previewBox, T.panel):SetAllPoints()
    ui.Border(previewBox, T.line2)

    local previewDisplay = CreateDisplay(previewBox, ui, false)
    previewDisplay.frame:SetPoint("CENTER")

    local fontRow = CreateFrame("Frame", nil, section)
    fontRow:SetPoint("TOPLEFT", 0, -336)
    fontRow:SetPoint("TOPRIGHT", 0, -336)
    fontRow:SetHeight(32)

    local fontLabel = ui.Text(fontRow, 14, T.fg)
    fontLabel:SetPoint("LEFT", 0, 0)
    fontLabel:SetText("Font size")

    local fontValue = ui.Text(fontRow, 13, T.text, "RIGHT")
    fontValue:SetPoint("RIGHT", 0, 0)
    fontValue:SetWidth(46)

    local sliderW = 220
    local minusBtn, plusBtn
    local slider = CreateFrame("Frame", nil, fontRow)
    slider:SetSize(sliderW, 24)
    slider:EnableMouse(true)

    local track = ui.Fill(slider, T.grey, nil, "BACKGROUND")
    track:SetPoint("LEFT", 0, 0)
    track:SetPoint("RIGHT", 0, 0)
    track:SetHeight(4)

    local fill = ui.Fill(slider, T.accent, 1, "ARTWORK")
    fill:SetPoint("LEFT", track, "LEFT", 0, 0)
    fill:SetHeight(4)

    local thumb = ui.Fill(slider, T.fg, 1, "OVERLAY")
    thumb:SetSize(10, 16)

    local RefreshSection

    local function SetFontSize(size)
        local opt = Opt()
        local clamped = Clamp(floor(size + 0.5), MIN_FONT_SIZE, MAX_FONT_SIZE)
        if clamped == opt.fontSize then return end
        opt.fontSize = clamped
        if hud and hud:IsShown() then RefreshHud() end
        RefreshSection()
    end

    local function UpdateSliderFromCursor()
        local left = slider:GetLeft()
        local width = slider:GetWidth()
        local eff = slider:GetEffectiveScale()
        if not left or not width or width <= 0 or not eff or eff <= 0 then return end
        local cx = GetCursorPosition()
        local ratio = Clamp((cx / eff - left) / width, 0, 1)
        SetFontSize(MIN_FONT_SIZE + ratio * (MAX_FONT_SIZE - MIN_FONT_SIZE))
    end

    slider:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        UpdateSliderFromCursor()
        self:SetScript("OnUpdate", UpdateSliderFromCursor)
    end)
    slider:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        self:SetScript("OnUpdate", nil)
    end)
    slider:SetScript("OnHide", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    plusBtn = SecondaryButton(fontRow, ui, "+", 26, 26, function()
        SetFontSize(Opt().fontSize + 1)
    end)
    plusBtn:SetPoint("RIGHT", fontValue, "LEFT", -10, 0)

    slider:SetPoint("RIGHT", plusBtn, "LEFT", -10, 0)

    minusBtn = SecondaryButton(fontRow, ui, "-", 26, 26, function()
        SetFontSize(Opt().fontSize - 1)
    end)
    minusBtn:SetPoint("RIGHT", slider, "LEFT", -10, 0)

    local profLabel = ui.Text(section, 14, T.muted)
    profLabel:SetPoint("TOPLEFT", 0, -384)
    profLabel:SetText("Professions")

    local colLeft = CreateFrame("Frame", nil, section)
    colLeft:SetPoint("TOPLEFT", 0, -408)
    colLeft:SetPoint("TOPRIGHT", section, "TOP", -12, -408)
    colLeft:SetHeight(132)

    local colRight = CreateFrame("Frame", nil, section)
    colRight:SetPoint("TOPLEFT", section, "TOP", 12, -408)
    colRight:SetPoint("TOPRIGHT", 0, -408)
    colRight:SetHeight(132)

    local profToggles = {}
    for i = 1, #PROFS do
        local p = PROFS[i]
        local key = p.key
        local col = (i % 2 == 1) and colLeft or colRight
        local rowIdx = floor((i - 1) / 2)
        profToggles[i] = ui.Toggle(col, -rowIdx * 44, p.label,
            function() return IsProfEnabled(key) end,
            function(v)
                Opt().prof[key] = v
                if hud and hud:IsShown() then RefreshHud() end
                RefreshSection()
            end)
    end

    local ctrlRow = CreateFrame("Frame", nil, section)
    ctrlRow:SetPoint("TOPLEFT", 0, -558)
    ctrlRow:SetPoint("TOPRIGHT", 0, -558)
    ctrlRow:SetHeight(32)

    local previewBtn = ui.Button(ctrlRow, "Show on screen", 148, function()
        Gather.TogglePreview()
    end)
    previewBtn:SetPoint("LEFT", 0, 0)

    local resetBtn = SecondaryButton(ctrlRow, ui, "Reset layout", 116, 30, function()
        Gather.ResetLayout()
    end)
    resetBtn:SetPoint("LEFT", previewBtn, "RIGHT", 10, 0)

    local layoutReadout = ui.Text(ctrlRow, 13, T.muted, "RIGHT")
    layoutReadout:SetPoint("RIGHT", 0, 0)

    local function RefreshReadout()
        local opt = Opt()
        layoutReadout:SetText(format("Scale %.2fx   %s x %s", opt.scale, opt.w and tostring(opt.w) or "auto",
            opt.h and tostring(opt.h) or "auto"))
    end

    RefreshSection = function()
        local opt = Opt()
        enabledToggle:Refresh()
        for i = 1, #profToggles do profToggles[i]:Refresh() end

        local ratio = (opt.fontSize - MIN_FONT_SIZE) / (MAX_FONT_SIZE - MIN_FONT_SIZE)
        local trackW = slider:GetWidth()
        if not trackW or trackW <= 0 then trackW = sliderW end
        local thumbX = ratio * (trackW - 10)
        fill:SetWidth(max(1, thumbX + 5))
        thumb:ClearAllPoints()
        thumb:SetPoint("LEFT", slider, "LEFT", thumbX, 0)
        fontValue:SetText(format("%d px", opt.fontSize))

        local boxW = previewBox:GetWidth()
        if not boxW or boxW <= 0 then boxW = 620 end
        local fitW = max(MIN_W, boxW - 28)
        local autoH, previewW = RenderDisplay(
            previewDisplay,
            PREVIEW_ZONE,
            BuildSampleRows(),
            opt.fontSize,
            opt.w and min(opt.w, fitW),
            nil,
            "No professions selected",
            true
        )
        previewW = min(previewW, fitW)
        local displayH = min(autoH, PREVIEW_MAX_H)
        previewDisplay.frame:SetSize(previewW, displayH)
        ReflowDisplay(previewDisplay, previewW, displayH)

        if previewBtn.label then
            previewBtn.label:SetText(hudState.mode == "pinned" and "Hide on screen" or "Show on screen")
        end
        RefreshReadout()
    end

    previewBox:SetScript("OnSizeChanged", function()
        if section:IsShown() then RefreshSection() end
    end)

    local sectionH = 614
    section:SetHeight(sectionH)

    settingsView = {
        frame = section,
        height = sectionH,
        Refresh = RefreshSection,
        RefreshReadout = RefreshReadout,
    }
    return settingsView
end
