local _, ns = ...

local format = string.format

local Summary = {}
ns.Summary = Summary

local CHIP_W, CHIP_H, CHIP_HOLD = 240, 36, 8
local CHIP_MIN_PLAYED, CHIP_MIN_KILLS, CHIP_MIN_QUESTS = 1200, 5, 1
local CARD_W, CARD_PAD, CARD_STRIP_H, CARD_MIN_PLAYED = 430, 19, 66, 600
local CARD_CANCEL_HOLD = 2
local LOGIN_MIN_PLAYED = 60

local frame = CreateFrame("Frame")
local H = {}
local chip, card
local chipFor, cardFor
local waitingForRest = false
local byKey

local function Enabled()
    return ns.opt and ns.opt.summary ~= false
end

local function LevelText(recap)
    local level = recap.level
    local from, to = level and level[1], level and level[2]
    if not (from and to) then return nil end
    if from == to then return "level " .. to end
    return format("level %d to %d", from, to)
end

--- "2h 24m, level 41 to 42": the login line's text after "Last session: ".
function Summary.Brief(recap)
    local text = ns.UI.Duration(recap.played or 0)
    local level = LevelText(recap)
    return level and (text .. ", " .. level) or text
end

--- The login line for the last closed session, or nil when there is none or the option is off.
function Summary.LoginLine()
    if not Enabled() then return end
    local recap = ns.Recap.Last()
    if not recap or (recap.played or 0) < LOGIN_MIN_PLAYED then return end
    return "Last session: " .. Summary.Brief(recap)
end

local function Feat(key)
    if not byKey then
        byKey = {}
        for _, f in ipairs(ns.FEATS or {}) do byKey[f.key] = f end
    end
    return byKey[key]
end

local function TierName(tier)
    return ns.FEAT_TIER_NAMES and ns.FEAT_TIER_NAMES[tier] or ""
end

local function FeatLine(recap)
    local feats = recap.feats
    if not feats then return end
    local parts, seal = {}, nil
    local earned = feats.earned and feats.earned[1]
    local def = earned and Feat(earned.key)
    if def then
        parts[#parts + 1] = format("|cfff0f1f3%s|r reached %s", def.name, TierName(earned.tier))
        seal = { family = def.family, glyph = def.glyph, tier = earned.tier, spell = def.spells and def.spells[1] }
    end
    local near = feats.near and feats.near[1]
    local nearDef = near and Feat(near.key)
    if nearDef then
        local left = near.left or 0
        parts[#parts + 1] = format("%s is %s %s from %s", nearDef.name, ns.UI.Num(left),
            left == 1 and nearDef.one or nearDef.many, TierName(near.tier + 1))
        seal = seal or { family = nearDef.family, glyph = nearDef.glyph, tier = near.tier, ghost = near.tier + 1,
            progress = near.next and near.next > 0 and near.value / near.next or 0 }
    end
    if #parts == 0 then return end
    return table.concat(parts, " · "), seal
end

local function BuildChip()
    local ui = ns.UI
    local T = ui.T
    local f = CreateFrame("Button", nil, UIParent)
    f:SetFrameStrata("HIGH")
    f:RegisterForClicks("LeftButtonUp")
    ui.Fill(f, T.bg, 0.94):SetAllPoints()
    ui.Border(f, T.line2)
    local rail = ui.Fill(f, T.accent, 1, "ARTWORK")
    rail:SetPoint("TOPLEFT", 1, -1)
    rail:SetPoint("BOTTOMLEFT", 1, 1)
    rail:SetWidth(3)
    f.head = ui.Text(f, 12, T.fg, "LEFT", "strong")
    f.head:SetPoint("TOPLEFT", 12, -5)
    f.head:SetText("This session")
    f.line = ui.Text(f, 12, T.text)
    f.line:SetPoint("TOPLEFT", 12, -19)
    f.line:SetPoint("RIGHT", -8, 0)
    f:SetScript("OnClick", function(self)
        ns.Alerts.Dismiss(self)
        ns.UI.Open("recap")
    end)
    ns.Alerts.Fade(f, CHIP_HOLD - 1)
    f:Hide()
    return f
end

function Summary.ChipText(recap)
    local c = recap.counters or {}
    local parts = { ns.UI.Duration(recap.played or 0) }
    local level = LevelText(recap)
    if level then parts[#parts + 1] = level end
    parts[#parts + 1] = format("%s kill%s", ns.UI.Num(c.kills or 0), (c.kills or 0) == 1 and "" or "s")
    return table.concat(parts, " · ")
end

local function ShowChip()
    local row = ns.Ov and ns.Ov.Live()
    if not row or chipFor == row.t then return end
    if (row.p or 0) < CHIP_MIN_PLAYED or ((row.k or 0) < CHIP_MIN_KILLS and (row.q or 0) < CHIP_MIN_QUESTS) then return end
    local recap = ns.Recap.View()
    if not recap then return end
    chipFor = row.t
    chip = chip or BuildChip()
    chip.line:SetText(Summary.ChipText(recap))
    ns.Alerts.Beside(chip, CHIP_W, CHIP_H)
    ns.Alerts.Raise(chip)
end

local function BuildCard()
    local ui = ns.UI
    local T = ui.T
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetFrameStrata("HIGH")
    f:SetWidth(CARD_W)
    f:SetPoint("TOP", UIParent, "TOP", 0, -120)
    ui.Fill(f, T.bg, 0.96):SetAllPoints()
    ui.Border(f, T.line2)
    local rail = ui.Fill(f, T.accent, 1, "ARTWORK")
    rail:SetPoint("TOPLEFT", 1, -1)
    rail:SetPoint("BOTTOMLEFT", 1, 1)
    rail:SetWidth(3)
    local mark = ui.Fill(f, T.accent, 1, "ARTWORK")
    mark:SetSize(7, 7)
    mark:SetPoint("TOPLEFT", CARD_PAD, -15)
    mark:SetRotation(math.pi / 4)
    f.label = ui.Text(f, 12, T.text)
    f.label:SetPoint("TOPLEFT", CARD_PAD + 14, -12)
    f.title = ui.Text(f, 25, T.fg, "LEFT", "display")
    f.title:SetPoint("TOPLEFT", CARD_PAD, -29)
    f.title:SetWidth(CARD_W - CARD_PAD * 2)
    f.totals = ui.Text(f, 13, T.fg)
    f.totals:SetPoint("TOPLEFT", CARD_PAD, -62)
    f.strip = ui.Strip(f, CARD_W - CARD_PAD - 16, CARD_STRIP_H, true)
    f.strip:SetPoint("TOPLEFT", CARD_PAD, -88)
    f.seal = ui.Seal(f, 22)
    f.seal:SetPoint("TOPLEFT", CARD_PAD, -88 - CARD_STRIP_H - 6)
    f.feats = ui.Text(f, 12.5, T.text)
    f.feats:SetPoint("LEFT", f.seal, "RIGHT", 8, 0)
    f.feats:SetWidth(CARD_W - CARD_PAD - 16 - 30)
    f:Hide()
    return f
end

function Summary.CardTotals(recap)
    local ui = ns.UI
    local c, g = recap.counters or {}, recap.gold or {}
    local xp = 0
    for _, v in pairs(recap.xp or {}) do xp = xp + v end
    local net = (g.earned or 0) - (g.spent or 0)
    local yards = (c.foot or 0) + (c.walk or 0) + (c.mount or 0) + (c.swim or 0) + (c.fly or 0)
    return format("%s XP  ·  %s kill%s  ·  %s%s  ·  %s", ui.Num(xp), ui.Num(c.kills or 0), (c.kills or 0) == 1 and "" or "s",
        net < 0 and "-" or "+", ui.Money(math.abs(net)), ui.Distance(yards))
end

local function ShowCard()
    local row = ns.Ov and ns.Ov.Live()
    if not row or cardFor == row.t or (row.p or 0) < CARD_MIN_PLAYED then return end
    local recap = ns.Recap.View()
    if not recap then return end
    cardFor = row.t
    card = card or BuildCard()
    card.label:SetText("This session · " .. ns.UI.Duration(recap.played or 0))
    card.title:SetText(recap.title and recap.title.text or "")
    card.totals:SetText(Summary.CardTotals(recap))
    card.strip:Set(recap)
    local line, seal = FeatLine(recap)
    card.seal:SetShown(line ~= nil)
    card.feats:SetShown(line ~= nil)
    local height = 88 + CARD_STRIP_H + 14
    if line then
        card.feats:SetText(line)
        card.seal:Set(seal or { family = "journey", tier = 0 })
        height = height + 28
    end
    card:SetHeight(height)
    card:SetAlpha(1)
    card:Show()
end

local function HideCard()
    if card then card:Hide() end
end

function H.PLAYER_UPDATE_RESTING()
    if not Enabled() or chipFor then return end
    local rest = IsResting()
    if not ns.Plain(rest) or not rest then
        waitingForRest = false
        frame:UnregisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    if ns.Alerts.Quiet() then
        waitingForRest = true
        frame:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    ShowChip()
end

function H.PLAYER_REGEN_ENABLED()
    if not waitingForRest then return end
    waitingForRest = false
    frame:UnregisterEvent("PLAYER_REGEN_ENABLED")
    local rest = IsResting()
    if Enabled() and ns.Plain(rest) and rest and not ns.Alerts.Quiet() then ShowChip() end
end

function H.PLAYER_CAMPING()
    if Enabled() then ShowCard() end
end

function H.LOGOUT_CANCEL()
    if card and card:IsShown() then C_Timer.After(CARD_CANCEL_HOLD, HideCard) end
end

function H.PLAYER_LOGOUT()
    HideCard()
end

ns.Listen(frame, H, "Summary", { PLAYER_REGEN_ENABLED = true })
