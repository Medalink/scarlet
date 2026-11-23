local _, ns = ...

local floor, max, min = math.floor, math.max, math.min
local format, tonumber = string.format, tonumber
local type, ipairs, pairs, pcall, strsplit, wipe, sort = type, ipairs, pairs, pcall, strsplit, wipe, table.sort
local GetTime, time = GetTime, time
local Plain = ns.Plain

local Gather = {}
ns.Gather = Gather

local ARM_WINDOW = 4
local FISH_CHANNEL_WINDOW = 35
local TAIL_WINDOW = 2
local BLOCK_TAIL = 2
local BOBBER_ID = "35591"
local DEFAULT_HIDE_DELAY = 8
local MIN_HIDE_DELAY = 0
local MAX_HIDE_DELAY = 60
local SESSION_GAP = 30 * 60
local FADE_DURATION = 0.8
local GUILD_BANKER = 10

local REJECT_SOURCE = {
    fishing = { Creature = true, Vehicle = true },
    disenchanting = { Creature = true, Vehicle = true, GameObject = true },
}

local DEFAULT_FONT_SIZE = 13
local MIN_FONT_SIZE = 9
local MAX_FONT_SIZE = 24
local DEFAULT_SCALE = 1
local MIN_SCALE = 0.5
local MAX_SCALE = 2.5
local MAX_ROWS = 7
local ICON_GAP = 8
local ICON_PAIR_GAP = 6
local PANEL_GAP = 28
local QUESTION_ICON = 134400

local SECTION_KEYS = { "left", "right", "bottom" }
local SECTION_DEFAULT = { left = { x = -350, y = -23 }, right = { x = 340, y = -23 }, bottom = { x = 0, y = -147 } }
local LEFT_W, RIGHT_W, BOTTOM_W = 300, 280, 300
local LEFT_LINES = 8
local DIM = { 0.6, 0.6, 0.6 }
local SKILL_ID = { herbalism = 182, mining = 186, skinning = 393, fishing = 356 }
local SAMPLE_BEST = { itemID = 13468, name = "Black Lotus", quality = 2 }

local PREVIEW_ZONE = "Elwynn Forest"
local PREVIEW_SUBZONE = "Goldshire"
local PREVIEW_BOX_H = 200
local TAB_H, SEG_W = 28, 112
local ARC_DEPTH = 36
local ARC_ROW_PAD = 8
local ARC_LINE_PAD = 4
local OUTLINE_FLAGS = { none = "", outline = "OUTLINE", thick = "THICKOUTLINE" }
local SHADOWS = { none = { 0, 0 }, soft = { 1, 0.8 }, heavy = { 2, 1 } }
local PREVIEW_GAP = 120

local HEX_GOLD = "ffd100"
local HEX_MUTED = "8a8a93"
local HEX_FG = "f0f1f3"

local PROFS = {
    {
        key = "herbalism",
        label = "Herbalism",
        spells = { 2366, 2368, 3570, 11993, 28695, 50300, 74519, 110413, 158745, 195114 },
        fallback = "Herb Gathering",
        icon = "Interface\\Icons\\Trade_Herbalism",
        sample = { itemID = 2447, item = "Peacebloom", session = 6, total = 24, copper = 20 },
    },
    {
        key = "mining",
        label = "Mining",
        spells = { 2575, 2576, 3564, 10248, 29354, 50310, 74517, 102161, 158754, 195122, 32606 },
        fallback = "Mining",
        icon = "Interface\\Icons\\Trade_Mining",
        sample = { itemID = 2770, item = "Copper Ore", session = 9, total = 31, copper = 50 },
    },
    {
        key = "skinning",
        label = "Skinning",
        spells = { 8613, 8617, 8618, 10768, 32678, 50305, 74522, 102216, 158756, 194174 },
        fallback = "Skinning",
        icon = "Interface\\Icons\\INV_Misc_Pelt_Wolf_01",
        sample = { itemID = 2318, item = "Light Leather", session = 4, total = 18, copper = 50 },
    },
    {
        key = "fishing",
        label = "Fishing",
        spells = { 7620, 7731, 7732, 18248, 33095, 51294, 88868, 110410, 131474, 158743 },
        fallback = "Fishing",
        icon = "Interface\\Icons\\Trade_Fishing",
        sample = { itemID = 6291, item = "Raw Brilliant Smallfish", session = 3, total = 11, copper = 15 },
    },
    {
        key = "disenchanting",
        label = "Disenchanting",
        spells = { 13262 },
        fallback = "Disenchant",
        icon = "Interface\\Icons\\INV_Enchant_Disenchant",
        sample = { itemID = 10940, item = "Strange Dust", session = 5, total = 22, copper = 400 },
    },
}

local SPELL_PROF = {}
local PROF_LABEL = {}
local PROF_ICON = {}
for i = 1, #PROFS do
    local p = PROFS[i]
    PROF_LABEL[p.key] = p.label
    PROF_ICON[p.key] = p.icon
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
    if not g.offReset then
        g.enabled = false
        g.offReset = true
    end
    local fs = tonumber(g.fontSize)
    g.fontSize = Clamp(floor((fs or DEFAULT_FONT_SIZE) + 0.5), MIN_FONT_SIZE, MAX_FONT_SIZE)
    local sc = tonumber(g.scale)
    g.scale = Clamp(Round2(sc or DEFAULT_SCALE), MIN_SCALE, MAX_SCALE)
    g.w, g.h, g.pos, g.sections = nil, nil, nil, nil
    if type(g.panels) ~= "table" then g.panels = {} end
    for key, p in pairs(g.panels) do
        if not SECTION_DEFAULT[key] or type(p) ~= "table" or type(p.x) ~= "number" or type(p.y) ~= "number" then
            g.panels[key] = nil
        end
    end
    if g.align ~= "arc" then g.align = "straight" end
    if not OUTLINE_FLAGS[g.outline] then g.outline = "outline" end
    if not SHADOWS[g.shadow] then g.shadow = "soft" end
    g.hideDelay = Clamp(floor((tonumber(g.hideDelay) or DEFAULT_HIDE_DELAY) + 0.5), MIN_HIDE_DELAY, MAX_HIDE_DELAY)
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
local touchSeq = 0
local lastGather = nil
local SessionStore
local currentZone = nil
local currentSubzone = nil
local uiRef = nil

local hud = nil
local hudView = nil
local hudFade = nil
local scaleText = nil
local settingsView = nil

local hudState = {
    mode = "hidden",
    drag = "none",
    fadeToken = 0,
}

local function ReadZone()
    local z = Str(Call(_G.GetRealZoneText)) or Str(Call(_G.GetZoneText))
    if z then currentZone = z end
    local sub = Str(Call(_G.GetSubZoneText))
    currentSubzone = sub ~= currentZone and sub or nil
end

local function BuildSampleRows()
    local out = {}
    for i = 1, #PROFS do
        local p = PROFS[i]
        if IsProfEnabled(p.key) then
            out[#out + 1] = {
                prof = p.key,
                profLabel = p.label,
                itemID = p.sample.itemID,
                name = p.sample.item,
                session = p.sample.session,
                total = p.sample.total,
                unitCopper = p.sample.copper,
                bagCopper = p.sample.copper * p.sample.session,
            }
        end
    end
    return out
end

local function ShownEntries()
    local out = {}
    for i = 1, #entries do
        local e = entries[i]
        if IsProfEnabled(e.prof) then out[#out + 1] = e end
    end
    return out
end

local function MostRecent(list)
    if #list <= MAX_ROWS then return list end
    local seqs = {}
    for i = 1, #list do seqs[i] = list[i].seq or 0 end
    sort(seqs, function(a, b) return a > b end)
    local cutoff = seqs[MAX_ROWS]
    local kept = {}
    for i = 1, #list do
        if (list[i].seq or 0) >= cutoff then kept[#kept + 1] = list[i] end
    end
    return kept
end

local function SessionStats(list)
    local session, total, bag, earned = 0, 0, 0, 0
    for i = 1, #list do
        local e = list[i]
        session = session + e.session
        total = total + (e.total or 0)
        bag = bag + (e.bagCopper or 0)
        earned = earned + e.session * (e.unitCopper or 0)
    end
    return session, total, bag, earned
end

local function Duration(sec)
    sec = max(0, floor(sec))
    if sec >= 3600 then return format("%dh %02dm", floor(sec / 3600), floor(sec / 60) % 60) end
    return format("%dm %02ds", floor(sec / 60), sec % 60)
end

local function SkillText(prof)
    local id = prof and SKILL_ID[prof]
    local api = _G.C_SkillInfo
    if not id or not api then return nil end
    for i = 1, Num(Call(api.GetNumSkillLines)) or 0 do
        local line = Call(api.GetSkillLineInfo, i)
        if type(line) == "table" and Num(line.skillID) == id then
            local rank, cap = Num(line.rank), Num(line.maxRank)
            if rank and cap and rank < cap then return format("%s: %d/%d", PROF_LABEL[prof], rank, cap) end
            return nil
        end
    end
    return nil
end

local function QualityHex(itemID)
    local api = _G.C_Item
    local q = itemID and Num(Call(api and api.GetItemQualityByID, itemID))
    local colors = _G.ITEM_QUALITY_COLORS
    local c = q and type(colors) == "table" and colors[q]
    return type(c) == "table" and Str(c.hex) or ("|cff" .. HEX_FG)
end

local function ItemIcon(itemID)
    if not itemID then return QUESTION_ICON end
    local api = _G.C_Item
    return Call(api and api.GetItemIconByID, itemID) or Call(_G.GetItemIcon, itemID) or QUESTION_ICON
end

local function FormatRow(ui, row)
    local value = (row.unitCopper or 0) > 0 and ui.Money(row.unitCopper) or ("|cff" .. HEX_MUTED .. "-|r")
    return format("%s%s|r %s", QualityHex(row.itemID), row.name, value)
end

local function SetHudFont(fs, role, size)
    local opt = Opt()
    local flags = OUTLINE_FLAGS[opt.outline]
    local path = uiRef and uiRef.Face(role)
    if not (path and fs:SetFont(path, size, flags)) then
        fs:SetFont((GameFontNormal:GetFont()), size, flags)
    end
    local shadow = SHADOWS[opt.shadow]
    fs:SetShadowOffset(shadow[1], -shadow[1])
    fs:SetShadowColor(0, 0, 0, shadow[2])
end

local function NewText(parent, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetJustifyH(justify)
    fs:SetWordWrap(false)
    fs:SetTextColor(1, 1, 1)
    fs:SetShadowOffset(1, -1)
    fs:SetShadowColor(0, 0, 0, 0.8)
    return fs
end

local function TextWidth(fs)
    local w = fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth()
    return Num(w) or 0
end

local function CreateView(parent, interactive)
    local view = { lines = {}, rows = {} }
    for _, key in ipairs(SECTION_KEYS) do
        local sec = CreateFrame("Frame", nil, parent)
        sec.key = key
        view[key] = sec
    end
    for i = 1, LEFT_LINES do view.lines[i] = NewText(view.left, "RIGHT") end

    view.last = NewText(view.bottom, "CENTER")
    view.last:SetPoint("TOP", view.bottom, "TOP", 0, 0)
    view.best = NewText(view.bottom, "CENTER")

    local endBtn = CreateFrame("Button", nil, view.bottom)
    endBtn.label = NewText(endBtn, "CENTER")
    endBtn.label:SetAllPoints()
    endBtn.label:SetTextColor(DIM[1], DIM[2], DIM[3])
    if interactive then
        endBtn:SetScript("OnEnter", function(self) self.label:SetTextColor(1, 1, 1) end)
        endBtn:SetScript("OnLeave", function(self) self.label:SetTextColor(DIM[1], DIM[2], DIM[3]) end)
    else
        endBtn:EnableMouse(false)
    end
    view.endBtn = endBtn
    return view
end

local function RowAt(view, i)
    local r = view.rows[i]
    if not r then
        r = {
            prof = view.right:CreateTexture(nil, "ARTWORK"),
            icon = view.right:CreateTexture(nil, "ARTWORK"),
            text = NewText(view.right, "LEFT"),
        }
        r.prof:SetTexCoord(0.11, 0.89, 0.11, 0.89)
        r.icon:SetTexCoord(0.11, 0.89, 0.11, 0.89)
        r.icon:SetPoint("LEFT", r.prof, "RIGHT", ICON_PAIR_GAP, 0)
        r.text:SetPoint("LEFT", r.icon, "RIGHT", ICON_GAP, 0)
        view.rows[i] = r
    end
    return r
end

local function ArcShift(i, n, lineH)
    if n < 3 or Opt().align ~= "arc" then return 0 end
    local half = (n + 1) / 2
    local t = (i - half) / half
    return floor(ARC_DEPTH * (lineH / 18) * t * t + 0.5)
end

local function RenderView(view, d)
    local ui = uiRef
    local list = d.list
    local size = Clamp(floor((d.fontSize or DEFAULT_FONT_SIZE) + 0.5), MIN_FONT_SIZE, MAX_FONT_SIZE)
    local lineH = max(22, floor(size * 1.7 + 0.5))
    local iconSize = max(20, size + 7)
    local arc = Opt().align == "arc"
    local rowH = iconSize + 8 + (arc and ARC_ROW_PAD or 0)
    local leftH = lineH + (arc and ARC_LINE_PAD or 0)

    local muted = "|cff" .. HEX_MUTED
    local perHour = d.earned > 0 and ui.Money(floor(d.earned * 3600 / max(d.elapsed, 60))) .. "/hr" or "-/hr"
    local texts = {
        "|cff" .. HEX_GOLD .. "Zone: " .. (d.zone or "Unknown") .. "|r",
        d.subzone and (muted .. d.subzone .. "|r") or "",
        "",
        format("Session: %d gathered | %d nodes", d.session, d.nodes),
        muted .. format("Total: %d gathered", d.total) .. "|r",
        d.bag > 0 and (muted .. "In bags:|r " .. ui.Money(d.bag)) or "",
        muted .. "Time: " .. Duration(d.elapsed) .. " | |r" .. perHour,
        d.skill and (muted .. d.skill .. "|r") or "",
    }
    local leftW = LEFT_W
    for i = 1, LEFT_LINES do
        local fs = view.lines[i]
        local header = i <= 2
        SetHudFont(fs, header and "strong" or "body", header and size + 2 or size)
        local shift = ArcShift(i, LEFT_LINES, leftH)
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", view.left, "TOPLEFT", shift, -(i - 1) * leftH)
        fs:SetPoint("TOPRIGHT", view.left, "TOPRIGHT", shift, -(i - 1) * leftH)
        fs:SetText(texts[i] or "")
        leftW = max(leftW, TextWidth(fs))
    end
    view.left:SetSize(leftW, LEFT_LINES * leftH)

    local shown = max(1, #list)
    local rightW = RIGHT_W
    local more = d.more or 0
    if more > 0 then shown = shown + 1 end
    for i = 1, shown do
        local r, row = RowAt(view, i), list[i]
        r.prof:SetSize(iconSize, iconSize)
        r.icon:SetSize(iconSize, iconSize)
        r.prof:ClearAllPoints()
        r.prof:SetPoint("LEFT", view.right, "TOPLEFT", -ArcShift(i, shown, rowH), -((i - 1) * rowH + rowH / 2))
        SetHudFont(r.text, "body", size)
        if row then
            r.prof:SetTexture(PROF_ICON[row.prof] or QUESTION_ICON)
            r.icon:SetTexture(ItemIcon(row.itemID))
            r.prof:Show()
            r.icon:Show()
            r.text:SetText(FormatRow(ui, row))
        else
            r.prof:Hide()
            r.icon:Hide()
            local summary = more > 0 and format("+%d more %s", more, more == 1 and "item" or "items")
            r.text:SetText("|cff" .. HEX_MUTED .. (summary or d.emptyText) .. "|r")
        end
        r.text:Show()
        rightW = max(rightW, 2 * iconSize + ICON_PAIR_GAP + ICON_GAP + TextWidth(r.text))
    end
    for i = shown + 1, #view.rows do
        view.rows[i].prof:Hide()
        view.rows[i].icon:Hide()
        view.rows[i].text:Hide()
    end
    view.right:SetSize(rightW, shown * rowH)

    local last, best = d.last, d.best
    local e = last and last.entry
    SetHudFont(view.last, "body", size)
    view.last:SetText(e and format("%sLast:|r +%d %s%s|r", muted, last.count, QualityHex(e.itemID), e.name) or "")
    SetHudFont(view.best, "body", size)
    view.best:ClearAllPoints()
    view.best:SetPoint("TOP", view.bottom, "TOP", 0, -lineH)
    view.best:SetText(best and format("%sBest:|r %s%s|r", muted, QualityHex(best.itemID), best.name) or "")
    local endBtn = view.endBtn
    SetHudFont(endBtn.label, "body", size)
    endBtn.label:SetText("End Session")
    endBtn:SetSize(max(80, TextWidth(endBtn.label) + 8), lineH)
    endBtn:ClearAllPoints()
    endBtn:SetPoint("TOP", view.bottom, "TOP", 0, -(2 * lineH + 8))
    view.bottom:SetSize(max(BOTTOM_W, TextWidth(view.last), TextWidth(view.best)), 3 * lineH + 8)
end

local function RefreshSettings()
    if settingsView and settingsView.Refresh then settingsView.Refresh() end
end

local function RefreshReadout()
    if settingsView and settingsView.RefreshReadout then settingsView.RefreshReadout() end
end

local function CancelFade()
    hudState.fadeToken = hudState.fadeToken + 1
    if hudFade then hudFade:Stop() end
end

local function ScheduleFade()
    hudState.fadeToken = hudState.fadeToken + 1
    local token = hudState.fadeToken
    if Opt().hideDelay <= 0 then return end
    C_Timer.After(Opt().hideDelay, function()
        if token ~= hudState.fadeToken or hudState.mode ~= "active" then return end
        if hudState.drag ~= "none" then
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

local function ApplyHudLayout()
    if not hud then return end
    local opt = Opt()
    hud:SetScale(opt.scale)
    for _, key in ipairs(SECTION_KEYS) do
        local p = opt.panels[key] or SECTION_DEFAULT[key]
        local sec = hudView[key]
        sec:ClearAllPoints()
        sec:SetPoint("CENTER", hud, "CENTER", p.x, p.y)
    end
end

local function SaveSection(sec)
    local cx, cy = hud:GetCenter()
    local sx, sy = sec:GetCenter()
    if not (cx and cy and sx and sy) then return end
    Opt().panels[sec.key] = { x = Round2(sx - cx), y = Round2(sy - cy) }
end

local function SetEditMode(on)
    if not hudView then return end
    hud:SetFrameStrata(on and "DIALOG" or "BACKGROUND")
    for _, key in ipairs(SECTION_KEYS) do
        local sec = hudView[key]
        local rightOnly = not on and sec.SetPassThroughButtons
            and pcall(sec.SetPassThroughButtons, sec, "LeftButton")
        if on and sec.SetPassThroughButtons then pcall(sec.SetPassThroughButtons, sec) end
        sec:EnableMouse(on or rightOnly or false)
        sec.outline:SetShown(on)
    end
    hudView.endBtn:EnableMouse(not on)
end

local function DismissHud()
    if hudState.mode == "pinned" then
        Gather.TogglePreview()
        return
    end
    CancelFade()
    hudState.mode = "hidden"
    hud:Hide()
    hud:SetAlpha(1)
end

local function AnyProfEnabled()
    for i = 1, #PROFS do
        if IsProfEnabled(PROFS[i].key) then return true end
    end
    return false
end

local function SampleData()
    local list = BuildSampleRows()
    return list, {
        nodes = 31,
        elapsed = 23 * 60 + 34,
        skill = "Mining: 142/150",
        best = SAMPLE_BEST,
        last = list[1] and { entry = list[1], count = 2 },
    }
end

local function ViewData(list, d, zone, subzone, emptyText)
    d.zone, d.subzone, d.emptyText = zone, subzone, emptyText
    d.list = MostRecent(list)
    d.more = #list - #d.list
    d.session, d.total, d.bag, d.earned = SessionStats(list)
    d.fontSize = Opt().fontSize
    return d
end

local function LiveData(list)
    local store = SessionStore()
    local nodes = 0
    if store and type(store.nodes) == "table" then
        for prof, n in pairs(store.nodes) do
            if type(n) == "number" and IsProfEnabled(prof) then nodes = nodes + n end
        end
    end
    local start = store and tonumber(store.start)
    local best = store and store.best
    return {
        nodes = nodes,
        elapsed = start and #list > 0 and (time() - start) or 0,
        skill = SkillText(store and store.lastProf),
        best = type(best) == "table" and Str(best.name) and best or nil,
        last = lastGather,
    }
end

local function RefreshHud()
    if not hudView then return end
    local list = ShownEntries()
    local zone, subzone = currentZone, currentSubzone
    local d
    if hudState.mode == "pinned" and #list == 0 then
        list, d = SampleData()
        if not zone then zone, subzone = PREVIEW_ZONE, PREVIEW_SUBZONE end
    else
        d = LiveData(list)
    end
    local emptyText = AnyProfEnabled() and "Nothing gathered yet" or "No professions selected"
    RenderView(hudView, ViewData(list, d, zone, subzone, emptyText))
end

local function BuildHud()
    if hud then return end
    uiRef = uiRef or ns.UI
    if not uiRef then return end
    local T = uiRef.T

    hud = CreateFrame("Frame", "ScarletGatherPopup", UIParent)
    hud:SetSize(1, 1)
    hud:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    hud:SetFrameStrata("BACKGROUND")
    hudView = CreateView(hud, true)

    scaleText = NewText(hud, "CENTER")
    scaleText:Hide()

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

    local scaleDrag = {}

    local function FinishScale()
        hud:SetScript("OnUpdate", nil)
        scaleText:Hide()
        Opt().scale = Clamp(Round2(hud:GetScale()), MIN_SCALE, MAX_SCALE)
        hudState.drag = "none"
        RefreshSettings()
    end

    local function FinishMove(sec)
        sec:StopMovingOrSizing()
        SaveSection(sec)
        ApplyHudLayout()
        hudState.drag = "none"
    end

    local function StartScale(sec)
        local cx, cy = GetCursorPosition()
        local uiScale = UIParent:GetEffectiveScale()
        if not uiScale or uiScale <= 0 then uiScale = 1 end
        scaleDrag.cx, scaleDrag.cy, scaleDrag.start, scaleDrag.ui = cx, cy, hud:GetScale() or 1, uiScale
        hudState.drag = "scale"
        SetHudFont(scaleText, "strong", 12)
        scaleText:ClearAllPoints()
        scaleText:SetPoint("BOTTOM", sec, "TOP", 0, 10)
        scaleText:SetText(format("%.2fx", scaleDrag.start))
        scaleText:Show()
        hud:SetScript("OnUpdate", function()
            if not IsMouseButtonDown("LeftButton") then
                FinishScale()
                return
            end
            local nx, ny = GetCursorPosition()
            local moved = ((nx - scaleDrag.cx) + (scaleDrag.cy - ny)) / scaleDrag.ui
            local s = Clamp(Round2(scaleDrag.start + moved / 240), MIN_SCALE, MAX_SCALE)
            hud:SetScale(s)
            Opt().scale = s
            scaleText:SetText(format("%.2fx", s))
            RefreshReadout()
        end)
    end

    for _, key in ipairs(SECTION_KEYS) do
        local sec = hudView[key]
        sec:SetMovable(true)
        sec:SetClampedToScreen(true)
        sec.outline = CreateFrame("Frame", nil, sec)
        sec.outline:SetPoint("TOPLEFT", -6, 6)
        sec.outline:SetPoint("BOTTOMRIGHT", 6, -6)
        uiRef.Border(sec.outline, T.accent, 0.45)
        sec.outline:Hide()
        sec:SetScript("OnMouseDown", function(self, button)
            if button ~= "LeftButton" or hudState.mode ~= "pinned" or hudState.drag ~= "none" then return end
            if IsShiftKeyDown() then
                StartScale(self)
            else
                hudState.drag = self.key
                self:StartMoving()
            end
        end)
        sec:SetScript("OnMouseUp", function(self, button)
            if button == "RightButton" then
                DismissHud()
                return
            end
            if button ~= "LeftButton" then return end
            if hudState.drag == "scale" then
                FinishScale()
            elseif hudState.drag == self.key then
                FinishMove(self)
            end
        end)
    end

    hud:SetScript("OnHide", function()
        if hudState.drag == "scale" then
            FinishScale()
        elseif hudView[hudState.drag] then
            FinishMove(hudView[hudState.drag])
        end
    end)

    hudView.endBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    hudView.endBtn:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            DismissHud()
        elseif hudState.mode ~= "pinned" then
            Gather.ResetSession()
        end
    end)

    SetEditMode(false)
    ApplyHudLayout()
    hud:Hide()
end

local function PokeHud()
    if hudState.mode == "pinned" then
        RefreshHud()
        return
    end
    if not Opt().enabled then return end
    if not hud then BuildHud() end
    if not hud then return end
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

local function ItemCount(itemID)
    local fn = (_G.C_Item and _G.C_Item.GetItemCount) or _G.GetItemCount
    local n = Num(Call(fn, itemID, false))
    return n and max(0, floor(n)) or 0
end

local function Price(e)
    e.unitCopper = UnitPrice(e.itemID)
    e.bagCopper = ItemCount(e.itemID) * e.unitCopper
end

function SessionStore()
    local ch = ns.char
    if type(ch) ~= "table" then return nil end
    if type(ch.gatherSession) ~= "table" then ch.gatherSession = {} end
    local store = ch.gatherSession
    if type(store.items) ~= "table" then store.items = {} end
    return store
end

local function LoadSession()
    local store = SessionStore()
    if not store then return end
    local fresh = type(store.t) == "number" and time() - store.t <= SESSION_GAP
    if not fresh then store.start, store.nodes, store.best = nil, nil, nil end
    local life = Lifetime()
    local kept = {}
    for _, e in ipairs(fresh and store.items or {}) do
        if type(e) == "table" and PROF_LABEL[e.prof] and type(e.itemID) == "number" and type(e.session) == "number" then
            e.key = e.prof .. ":" .. e.itemID
            e.profLabel = PROF_LABEL[e.prof]
            e.name = Str(e.name) or ("Item " .. e.itemID)
            e.total = life and tonumber(life[e.key]) or e.session
            e.seq = tonumber(e.seq) or 0
            touchSeq = max(touchSeq, e.seq)
            kept[#kept + 1] = e
        end
    end
    wipe(store.items)
    wipe(entryByKey)
    for i = 1, #kept do
        store.items[i] = kept[i]
        entryByKey[kept[i].key] = kept[i]
        Price(kept[i])
    end
    entries = store.items
end

local function TouchSession()
    local store = SessionStore()
    if not store then return nil end
    local now = time()
    if type(store.t) == "number" and now - store.t > SESSION_GAP then
        wipe(entries)
        wipe(entryByKey)
        lastGather = nil
        store.start, store.nodes, store.best = nil, nil, nil
    end
    store.t = now
    store.start = tonumber(store.start) or now
    if type(store.nodes) ~= "table" then store.nodes = {} end
    return store
end

local function NoteBest(store, itemID, name)
    local quality = Num(Call(_G.C_Item and _G.C_Item.GetItemQualityByID, itemID))
    if not quality or quality < 2 then return end
    local best = store.best
    if type(best) == "table" and (tonumber(best.quality) or 0) >= quality then return end
    store.best = { itemID = itemID, name = name, quality = quality }
end

local function RecordGather(prof, itemID, count, linkName)
    local store = TouchSession()
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
            unitCopper = 0,
        }
        entryByKey[key] = entry
        entries[#entries + 1] = entry
    end
    touchSeq = touchSeq + 1
    entry.seq = touchSeq
    lastGather = { entry = entry, count = count }
    if store then
        store.lastProf = prof
        NoteBest(store, itemID, entry.name)
    end
    local life = Lifetime()
    if life then
        life[key] = (tonumber(life[key]) or 0) + count
        entry.total = life[key]
    else
        entry.total = entry.session
    end
    Price(entry)
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
        if capture.phase ~= "looting" then
            local store = TouchSession()
            if store then store.nodes[resolved] = (tonumber(store.nodes[resolved]) or 0) + 1 end
        end
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
    for i = 1, #entries do Price(entries[i]) end
    if hud and hud:IsShown() then RefreshHud() end
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
            Price(e)
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
    LoadSession()
    ReadZone()
    BuildHud()
end

function Gather.OnFontChanged()
    if hud and hud:IsShown() then RefreshHud() end
    RefreshSettings()
end

function Gather.TogglePreview()
    if not hud then BuildHud() end
    if not hud then return end
    CancelFade()
    if hudState.mode == "pinned" then
        hudState.mode = "hidden"
        SetEditMode(false)
        hud:Hide()
    else
        hudState.mode = "pinned"
        hud:SetAlpha(1)
        SetEditMode(true)
        RefreshHud()
        hud:Show()
    end
    RefreshSettings()
end

function Gather.ResetLayout()
    local opt = Opt()
    opt.panels = {}
    opt.scale = DEFAULT_SCALE
    ApplyHudLayout()
    RefreshSettings()
end

function Gather.ResetSession()
    lastGather = nil
    local store = SessionStore()
    if store then store.start, store.nodes, store.best, store.t = nil, nil, nil, nil end
    wipe(entries)
    wipe(entryByKey)
    if hud and hud:IsShown() then RefreshHud() end
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
    b:SetScript("OnEnter", function() hover:Show() end)
    b:SetScript("OnLeave", function() hover:Hide() end)
    b:SetScript("OnClick", onClick)
    return b
end

local PAGE_TABS = {
    { key = "general", label = "General" },
    { key = "text", label = "Text" },
    { key = "layout", label = "Layout" },
    { key = "professions", label = "Professions" },
}

function Gather.Page(parent, ui)
    uiRef = uiRef or ui
    local T = ui.T
    local page = CreateFrame("Frame", nil, parent)
    page:SetAllPoints()

    local previewBox = CreateFrame("Frame", nil, page)
    previewBox:SetPoint("TOPLEFT", 0, 0)
    previewBox:SetPoint("TOPRIGHT", 0, 0)
    previewBox:SetHeight(PREVIEW_BOX_H)
    ui.Fill(previewBox, T.panel):SetAllPoints()
    ui.Border(previewBox, T.line2)

    local previewRoot = CreateFrame("Frame", nil, previewBox)
    previewRoot:SetPoint("TOPLEFT", 1, -1)
    previewRoot:SetPoint("BOTTOMRIGHT", -1, 1)
    if previewRoot.SetClipsChildren then previewRoot:SetClipsChildren(true) end
    local previewStage = CreateFrame("Frame", nil, previewRoot)
    previewStage:SetSize(1, 1)
    previewStage:SetPoint("TOPLEFT", previewRoot, "TOPLEFT", 0, 0)
    local previewView = CreateView(previewStage, false)

    local tabTop = -(PREVIEW_BOX_H + 12)
    local segBox = CreateFrame("Frame", nil, page)
    segBox:SetSize(SEG_W * #PAGE_TABS, TAB_H)
    segBox:SetPoint("TOPLEFT", 0, tabTop)
    ui.Border(segBox, T.line2)

    local tabButtons, tabBodies = {}, {}
    local selected = "general"
    local RefreshPage
    local pinnedByPage = false

    local function TabBody()
        local body = CreateFrame("Frame", nil, page)
        body:SetPoint("TOPLEFT", 0, tabTop - TAB_H - 12)
        body:SetPoint("BOTTOMRIGHT")
        return body
    end

    for i, def in ipairs(PAGE_TABS) do
        local b = CreateFrame("Button", nil, segBox)
        b:SetSize(SEG_W, TAB_H)
        b:SetPoint("TOPLEFT", (i - 1) * SEG_W, 0)
        local wash = ui.Fill(b, T.accent, 0.14)
        wash:SetAllPoints()
        wash:Hide()
        if i > 1 then
            local edge = ui.Fill(b, T.line2, nil, "ARTWORK")
            edge:SetPoint("TOPLEFT")
            edge:SetPoint("BOTTOMLEFT")
            edge:SetWidth(1)
        end
        local text = ui.Text(b, 14, T.text, "CENTER")
        text:SetPoint("CENTER")
        text:SetText(def.label)
        b.key, b.text, b.underline = def.key, text, wash
        b:SetScript("OnEnter", function(self)
            if self.key ~= selected then self.text:SetTextColor(T.fg[1], T.fg[2], T.fg[3]) end
        end)
        b:SetScript("OnLeave", function(self)
            if self.key ~= selected then self.text:SetTextColor(T.text[1], T.text[2], T.text[3]) end
        end)
        b:SetScript("OnClick", function(self)
            selected = self.key
            RefreshPage()
        end)
        tabButtons[#tabButtons + 1] = b
        tabBodies[def.key] = TabBody()
    end

    local function StepRow(body, y, label, lo, hi, get, set, fmt)
        local row = CreateFrame("Frame", nil, body)
        row:SetPoint("TOPLEFT", 0, y)
        row:SetPoint("TOPRIGHT", 0, y)
        row:SetHeight(32)

        local text = ui.Text(row, 14, T.fg)
        text:SetPoint("LEFT", 0, 0)
        text:SetText(label)

        local value = ui.Text(row, 13, T.text, "RIGHT")
        value:SetPoint("RIGHT", 0, 0)
        value:SetWidth(46)

        local slider = CreateFrame("Frame", nil, row)
        slider:SetSize(220, 24)
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

        local function Set(v)
            local clamped = Clamp(floor(v + 0.5), lo, hi)
            if clamped == get() then return end
            set(clamped)
            RefreshPage()
        end

        local function FromCursor()
            local left, width, eff = slider:GetLeft(), slider:GetWidth(), slider:GetEffectiveScale()
            if not left or not width or width <= 0 or not eff or eff <= 0 then return end
            local cx = GetCursorPosition()
            Set(lo + Clamp((cx / eff - left) / width, 0, 1) * (hi - lo))
        end

        slider:SetScript("OnMouseDown", function(self, button)
            if button ~= "LeftButton" then return end
            FromCursor()
            self:SetScript("OnUpdate", FromCursor)
        end)
        slider:SetScript("OnMouseUp", function(self, button)
            if button == "LeftButton" then self:SetScript("OnUpdate", nil) end
        end)
        slider:SetScript("OnHide", function(self) self:SetScript("OnUpdate", nil) end)

        local plus = SecondaryButton(row, ui, "+", 26, 26, function() Set(get() + 1) end)
        plus:SetPoint("RIGHT", value, "LEFT", -10, 0)
        slider:SetPoint("RIGHT", plus, "LEFT", -10, 0)
        local minus = SecondaryButton(row, ui, "-", 26, 26, function() Set(get() - 1) end)
        minus:SetPoint("RIGHT", slider, "LEFT", -10, 0)

        return function()
            local pos = (get() - lo) / (hi - lo) * (max(20, slider:GetWidth() or 220) - 10)
            fill:SetWidth(max(1, pos + 5))
            thumb:ClearAllPoints()
            thumb:SetPoint("LEFT", slider, "LEFT", pos, 0)
            value:SetText(type(fmt) == "function" and fmt(get()) or format(fmt, get()))
        end
    end

    local segmentRefreshers = {}

    local function Segmented(body, y, label, options, key)
        local text = ui.Text(body, 14, T.fg)
        text:SetPoint("TOPLEFT", 0, y - 8)
        text:SetText(label)
        local buttons = {}
        local offset = 0
        for i = #options, 1, -1 do
            local value, name = options[i][1], options[i][2]
            local b = SecondaryButton(body, ui, name, 96, 28, function()
                Opt()[key] = value
                if hud and hud:IsShown() then RefreshHud() end
                RefreshPage()
            end)
            b:SetPoint("TOPRIGHT", body, "TOPRIGHT", -offset, y)
            offset = offset + 96 + 8
            b.mark = ui.Fill(b, T.accent, 1, "OVERLAY")
            b.mark:SetPoint("BOTTOMLEFT", 1, 1)
            b.mark:SetPoint("BOTTOMRIGHT", -1, 1)
            b.mark:SetHeight(2)
            buttons[value] = b
        end
        segmentRefreshers[#segmentRefreshers + 1] = function()
            for value, b in pairs(buttons) do b.mark:SetShown(Opt()[key] == value) end
        end
    end

    local general = tabBodies.general
    local enabledToggle = ui.Toggle(general, 0, "Show Loot HUD",
        function() return Opt().enabled end,
        function(v)
            Opt().enabled = v
            if not v and hud and (hudState.mode == "active" or hudState.mode == "fading") then
                CancelFade()
                hudState.mode = "hidden"
                hud:Hide()
            end
        end)
    local refreshDelay = StepRow(general, -50, "Hide after", MIN_HIDE_DELAY, MAX_HIDE_DELAY,
        function() return Opt().hideDelay end,
        function(v) Opt().hideDelay = v end,
        function(v) return v <= 0 and "Never" or v .. " s" end)
    local clearBtn = SecondaryButton(general, ui, "Reset session", 124, 30, function()
        Gather.ResetSession()
        ns.Print("gathering session cleared.")
    end)
    clearBtn:SetPoint("TOPLEFT", 0, -94)

    local textTab = tabBodies.text
    local refreshFont = StepRow(textTab, 0, "Font size", MIN_FONT_SIZE, MAX_FONT_SIZE,
        function() return Opt().fontSize end,
        function(v)
            Opt().fontSize = v
            if hud and hud:IsShown() then RefreshHud() end
        end, "%d px")
    Segmented(textTab, -48, "Outline", { { "none", "None" }, { "outline", "Thin" }, { "thick", "Thick" } }, "outline")
    Segmented(textTab, -92, "Shadow", { { "none", "None" }, { "soft", "Soft" }, { "heavy", "Heavy" } }, "shadow")

    local layout = tabBodies.layout
    Segmented(layout, 0, "Alignment", { { "straight", "Straight" }, { "arc", "Arc" } }, "align")
    local previewBtn = ui.Button(layout, "Show on screen", 148, function()
        Gather.TogglePreview()
    end)
    previewBtn:SetPoint("TOPLEFT", 0, -52)
    local resetBtn = SecondaryButton(layout, ui, "Reset layout", 116, 30, function()
        Gather.ResetLayout()
    end)
    resetBtn:SetPoint("LEFT", previewBtn, "RIGHT", 10, 0)
    local scaleReadout = ui.Text(layout, 13, T.muted, "RIGHT")
    scaleReadout:SetPoint("RIGHT", layout, "TOPRIGHT", 0, -67)

    local function RefreshScaleReadout()
        scaleReadout:SetText(format("Scale %.2fx", Opt().scale))
    end

    local professions = tabBodies.professions
    local colLeft = CreateFrame("Frame", nil, professions)
    colLeft:SetPoint("TOPLEFT", 0, 0)
    colLeft:SetPoint("TOPRIGHT", professions, "TOP", -12, 0)
    colLeft:SetHeight(132)
    local colRight = CreateFrame("Frame", nil, professions)
    colRight:SetPoint("TOPLEFT", professions, "TOP", 12, 0)
    colRight:SetPoint("TOPRIGHT", 0, 0)
    colRight:SetHeight(132)

    local profToggles = {}
    for i = 1, #PROFS do
        local key = PROFS[i].key
        local col = (i % 2 == 1) and colLeft or colRight
        profToggles[i] = ui.Toggle(col, -floor((i - 1) / 2) * 44, PROFS[i].label,
            function() return IsProfEnabled(key) end,
            function(v)
                Opt().prof[key] = v
                if hud and hud:IsShown() then RefreshHud() end
                RefreshPage()
            end)
    end

    local function RefreshPreview()
        local rows, sample = SampleData()
        RenderView(previewView, ViewData(rows, sample, PREVIEW_ZONE, PREVIEW_SUBZONE, "No professions selected"))
        local boxW = previewRoot:GetWidth()
        if not boxW or boxW <= 0 then boxW = 620 end
        local boxH = PREVIEW_BOX_H - 2
        local lw, lh = previewView.left:GetWidth(), previewView.left:GetHeight()
        local rw, rh = previewView.right:GetWidth(), previewView.right:GetHeight()
        local bw, bh = previewView.bottom:GetWidth(), previewView.bottom:GetHeight()
        local pairW, topH = lw + PREVIEW_GAP + rw, max(lh, rh)
        local spanW, spanH = max(pairW, bw), topH + PANEL_GAP + bh
        local fit = min(1, (boxW - 24) / spanW, (boxH - 24) / spanH)
        previewStage:SetScale(fit)
        local midX = boxW / fit / 2
        local top = (boxH / fit - spanH) / 2
        local placements = {
            left = { midX - pairW / 2, top + (topH - lh) / 2 },
            right = { midX - pairW / 2 + lw + PREVIEW_GAP, top + (topH - rh) / 2 },
            bottom = { midX - bw / 2, top + topH + PANEL_GAP },
        }
        for key, at in pairs(placements) do
            local sec = previewView[key]
            sec:ClearAllPoints()
            sec:SetPoint("TOPLEFT", previewStage, "TOPLEFT", at[1], -at[2])
        end
    end

    RefreshPage = function()
        if hudState.mode ~= "pinned" then pinnedByPage = false end
        for _, b in ipairs(tabButtons) do
            local on = b.key == selected
            ui.SetFont(b.text, ui.Face(on and "strong" or "body"), 14)
            local c = on and T.fg or T.text
            b.text:SetTextColor(c[1], c[2], c[3])
            b.underline:SetShown(on)
            tabBodies[b.key]:SetShown(on)
        end
        enabledToggle:Refresh()
        for i = 1, #profToggles do profToggles[i]:Refresh() end
        refreshDelay()
        refreshFont()
        for i = 1, #segmentRefreshers do segmentRefreshers[i]() end
        previewBtn.label:SetText(hudState.mode == "pinned" and "Done" or "Show on screen")
        RefreshScaleReadout()
        RefreshPreview()
    end

    previewBox:SetScript("OnSizeChanged", function()
        if page:IsShown() then RefreshPreview() end
    end)

    local function PinForPage()
        if hudState.mode == "pinned" then return end
        pinnedByPage = true
        Gather.TogglePreview()
    end

    page:SetScript("OnShow", PinForPage)
    page:SetScript("OnHide", function()
        if pinnedByPage and hudState.mode == "pinned" then Gather.TogglePreview() end
        pinnedByPage = false
    end)

    function page.Refresh()
        PinForPage()
        RefreshPage()
    end
    settingsView = { Refresh = RefreshPage, RefreshReadout = RefreshScaleReadout }
    return page
end
