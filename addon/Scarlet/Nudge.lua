local _, ns = ...

if not ns.Feats then return end

local format, ceil = string.format, math.ceil

local Nudge = {}
ns.UI.Nudge = Nudge

local W, H, CREST, HOLD = 236, 38, 28, 8
local CLOSE_SECONDS, CLOSE_COUNT = 180, 5
local SPACING, BUDGET, QUIET_LOGIN, QUIET_TOAST = 900, 3, 60, 60

local plate
local lastAt, shown = nil, 0

local function Build()
    local ui = ns.UI
    local T = ui.T
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetFrameStrata("HIGH")
    f:EnableMouse(false)
    ui.Fill(f, T.bg, 0.94):SetAllPoints()
    ui.Border(f, T.line2)
    f.crest = ui.Crest(f, CREST)
    f.crest:SetPoint("LEFT", 6, 0)
    f.name = ui.Text(f, 12, T.fg, "LEFT", "strong")
    f.name:SetPoint("TOPLEFT", 42, -6)
    f.left = ui.Text(f, 12, T.muted)
    f.left:SetPoint("LEFT", f.name, "RIGHT", 8, 0)
    f.left:SetPoint("RIGHT", -8, 0)
    f.left:SetJustifyH("LEFT")
    f.track = ui.Fill(f, T.fg, 0.1)
    f.track:SetPoint("BOTTOMLEFT", 42, 7)
    f.track:SetPoint("BOTTOMRIGHT", -8, 7)
    f.track:SetHeight(3)
    f.bar = ui.Fill(f, T.accent, 1, "ARTWORK")
    f.bar:SetPoint("BOTTOMLEFT", 42, 7)
    f.bar:SetHeight(3)
    ns.Alerts.Fade(f, HOLD - 1)
    f:Hide()
    return f
end

local function Reason(f, tier, now)
    local opt = ns.opt
    if (opt.featAlerts or "all") ~= "all" then return "Feat alerts are not set to Toasts and nudges" end
    if tier == 0 then return "the first tier is a surprise" end
    local nudged = ns.char.nudged
    if nudged and (nudged[f.key] or 0) >= tier + 1 then return "this tier was nudged before" end
    if lastAt and now - lastAt < SPACING then return "the last nudge was under 15 minutes ago" end
    if shown >= BUDGET then return "3 nudges already this session" end
    if ns.Alerts.Quiet() then return "combat, an encounter or a cinematic" end
    if ns.Recap.Elapsed() < QUIET_LOGIN then return "the first minute after login" end
    if ns.UI.WindowOpen() then return "the Scarlet window is open" end
    if ns.FeatToast and now - ns.FeatToast.LastAt() < QUIET_TOAST then return "a feat toast just showed" end
    if plate and plate:IsShown() then return "a nudge is on screen" end
end

local function Close(f, left)
    local rate = ns.Feats.Pace(f)
    if rate then return left / rate <= CLOSE_SECONDS end
    return left <= CLOSE_COUNT
end

local function Show(f, info)
    local ui = ns.UI
    local nextTier = info.tier + 1
    ns.char.nudged = ns.char.nudged or {}
    ns.char.nudged[f.key] = nextTier
    lastAt, shown = GetTime(), shown + 1
    plate = plate or Build()
    local spells = ns.char.featSpell
    plate.crest:Set(f.crest, f.glyph, info.tier, 0, spells and spells[f.key], "next")
    local color = ns.Tiers[nextTier].color
    plate.bar:SetVertexColor(color[1], color[2], color[3], 1)
    plate.bar:SetWidth(math.max(0.01, (W - 50) * info.progress))
    plate.name:SetText(format("%s · %s", f.name, ns.TierName(nextTier)))
    local left = ceil(info.left - 0.0001)
    plate.left:SetText(format("%s %s to go", ui.Num(left), left == 1 and f.one or f.many))
    ns.Alerts.Beside(plate, W, H)
    ns.Alerts.Raise(plate)
end

local function OnMove(f, value, tier)
    local kind = f.live.kind
    if kind ~= "counter" and kind ~= "cast" then return end
    if tier == 0 then return end
    local nextAt = f.thresholds[tier + 1]
    if not nextAt then return end
    local nudged = ns.char.nudged
    if nudged and (nudged[f.key] or 0) >= tier + 1 then return end
    if not Close(f, nextAt - value) then return end
    if Reason(f, tier, GetTime()) then return end
    Show(f, ns.Feats.Info(f.key))
end

--- /scarlet feats near <key>: the nudge for one feat through every rule except how close it is.
function Nudge.Test(key)
    local f = key and ns.Feats.Def(key)
    if not f or not f.live then
        ns.Print("name a feat the addon counts, for example /scarlet feats near slayer")
        return
    end
    local info = ns.Feats.Info(key)
    if not info.next then
        ns.Print(f.name .. " is at its top tier")
        return
    end
    local why = Reason(f, info.tier, GetTime())
    if why then
        ns.Print("no nudge: " .. why)
        return
    end
    Show(f, info)
end

ns.Feats.OnMove(OnMove)
