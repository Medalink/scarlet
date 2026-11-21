-- Shots.lua: screenshots at key moments, off until the setting is turned on (Settings page).
-- Callers (Capture, Track) name the moment with ns.AutoShot(trigger) where they already see it:
--   lv level up, de death, bk boss kill, ep epic or better item, nc new collectible,
--   dw duel won, pk PvP kill.
-- One screenshot per COOLDOWN seconds at most, by comparing GetTime (no timer). The client's own
-- Screenshot() is called and nothing is hidden. The trigger goes to the SS line through
-- ns.shotTrigger, which Track reads when the client reports the file. Event driven only.
local _, ns = ...

local type, pcall = type, pcall
local GetTime = GetTime

local COOLDOWN = 5
local last = -100

ns.shotTrigger, ns.shotT, ns.shooting = nil, 0, false

function ns.AutoShot(trigger)
    local opt = ns.opt
    if not opt or not opt.shots or opt.paused then return end
    local shoot = _G.Screenshot
    if type(shoot) ~= "function" then return end
    local now = GetTime()
    if now - last < COOLDOWN then return end
    last = now
    ns.shotTrigger, ns.shotT = trigger, now
    -- Track's hook on Screenshot marks calls made by a key or another addon; this one is Scarlet's own.
    ns.shooting = true
    local ok = pcall(shoot)
    ns.shooting = false
    if not ok then ns.shotTrigger = nil end
end
