local _, ns = ...

local Alerts = {}
ns.Alerts = Alerts

local frame = CreateFrame("Frame")
local H = {}
local encounter, cinematic = false, false
local ICON_GAP = 6

function H.ENCOUNTER_START() encounter = true end
function H.ENCOUNTER_END() encounter = false end
function H.CINEMATIC_START() cinematic = true end
function H.CINEMATIC_STOP() cinematic = false end
function H.PLAY_MOVIE() cinematic = true end
function H.STOP_MOVIE() cinematic = false end

ns.Listen(frame, H, "Alerts")

--- True while an alert must wait: in combat, in a boss encounter or in a cinematic.
function Alerts.Quiet()
    return InCombatLockdown() or encounter or cinematic
end

--- Places f beside the recording icon, on the side of it with more room, and sizes it w by h.
function Alerts.Beside(f, w, h)
    f:SetSize(w, h)
    f:ClearAllPoints()
    local icon = ns.UI.RecordingIcon and ns.UI.RecordingIcon()
    if not (icon and icon:IsShown()) then
        f:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -260, -20)
        return
    end
    local x = icon:GetCenter()
    local right = false
    if x then
        x = x * icon:GetEffectiveScale() / UIParent:GetEffectiveScale()
        right = x < UIParent:GetWidth() / 2
    end
    if right then
        f:SetPoint("LEFT", icon, "RIGHT", ICON_GAP, 0)
    else
        f:SetPoint("RIGHT", icon, "LEFT", -ICON_GAP, 0)
    end
end

--- Fades f out after hold seconds and hides it. Show again with Alerts.Raise.
function Alerts.Fade(f, hold)
    local group = f:CreateAnimationGroup()
    local alpha = group:CreateAnimation("Alpha")
    alpha:SetFromAlpha(1)
    alpha:SetToAlpha(0)
    alpha:SetStartDelay(hold)
    alpha:SetDuration(1)
    group:SetScript("OnFinished", function() f:Hide() end)
    f.fade = group
end

function Alerts.Raise(f)
    f.fade:Stop()
    f:SetAlpha(1)
    f:Show()
    f.fade:Play()
end

function Alerts.Dismiss(f)
    if f.fade then f.fade:Stop() end
    f:Hide()
end
