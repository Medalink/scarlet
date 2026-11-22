-- Map.lua: the character's own recorded places on the world map.
-- With the OpenMap addon loaded (thanks to its author; MIT code, its map art is Blizzard's), the layers are
-- switches in OpenMap's menu under "Scarlet" and are drawn on OpenMap's stitched map, above its art. Only
-- OpenMap's public API (the global OpenMapAPI, major 1, version 2 or later) is used. Without OpenMap, or while
-- it shows the game's own map, the same layers are drawn on the game's map for the map being shown, behind a
-- small "Scarlet" switch on the map (off until it is turned on). Positions come from MapData.lua, which reads what Scarlet
-- already recorded; nothing new is captured here and nothing is written but the switches in ScarletDB.opt.map.
-- opt.map.draw is the one switch for all of it (the Settings page of Scarlet's window): off, nothing is drawn and
-- the per-layer switches keep what they were set to. The trail shows only the last 20 minutes of the character's
-- walking, fading with age.
local _, ns = ...

local type, pairs, ipairs, ceil = type, pairs, ipairs, math.ceil
local GetTime, time = GetTime, time
local wipe = wipe

local M = {}
ns.Map = M

-- Layers, in the order of the app's Survey look. `on` is the default.
local LAYERS = {
    { id = "trail", label = "Trail walked", on = true },
}
local DEFAULT = {}
for _, L in ipairs(LAYERS) do DEFAULT[L.id] = L.on end
DEFAULT.blizzard = false -- the switch on the game's own map (no OpenMap): off until the player turns it on
DEFAULT.draw = true      -- the one switch over all layers

local ICON = "Interface\\AddOns\\Scarlet\\Media\\Icon"

-- Lines: colour and thickness in screen pixels.
local LINE = {
    trail = { r = 1, g = 0.18, b = 0.33, a = 0.85, th = 2 },
}

local MAX_LINES = 1300
local STEP_MIN = 3.5                  -- screen pixels between two drawn trail points, at least
local STALE_CHECK = 2                 -- seconds between looks at the open buffers while the map is open
local FADE_STEPS = 20                 -- the trail goes from full to gone in this many steps (a minute each)

-- Settings ---------------------------------------------------------------------------------

local function On(id)
    local t = ns.opt and ns.opt.map
    local v
    if type(t) == "table" then v = t[id] end
    if v == nil then return DEFAULT[id] end
    return v and true or false
end
M.On = On

-- Whether Scarlet draws on the map at all; the layers keep their own switches underneath.
local function Drawing() return On("draw") end
M.Drawing = Drawing

local function AnyOn()
    if not Drawing() then return false end
    for i = 1, #LAYERS do
        if On(LAYERS[i].id) then return true end
    end
    return false
end

-- OpenMap -----------------------------------------------------------------------------------

-- OpenMap's public API, when it is there with the calls used here: major 1, version 2 or later.
local function OM()
    local api = _G.OpenMapAPI
    if type(api) ~= "table" or api.major ~= 1 or type(api.version) ~= "number" or api.version < 2 then return end
    if type(api.IsStitched) ~= "function" or type(api.WorldFromMap) ~= "function"
        or type(api.MapFromWorld) ~= "function" or type(api.ArtTopLevel) ~= "function" then
        return
    end
    return api
end

-- Pools ---------------------------------------------------------------------------------------

local ov                      -- the overlay frame, child of the map's canvas
-- shownLines is the highest line a draw has touched since the last HideRest.
local lines, nLines, shownLines = {}, 0, 0

-- Per draw: canvas size in overlay pixels, the view in the same.
local PW, PH, X0, Y0, X1, Y1
local trailDrawn = 0                -- trail lines the last draw used; the trail fades while it is above 0
local dirty = false                 -- a redraw is due (set by the callbacks below, and by a draw that wants another)

-- q, for the trail, is how many of FADE_STEPS the line is still at: its alpha is that share of the kind's.
local function Seg(kind, x1, y1, x2, y2, q)
    if nLines >= MAX_LINES then return end
    nLines = nLines + 1
    if nLines > shownLines then shownLines = nLines end
    local ln = lines[nLines]
    if not ln then
        ln = ov:CreateLine(nil, "OVERLAY")
        lines[nLines] = ln
    end
    q = q or 0
    if ln.kind ~= kind or ln.q ~= q then
        local sp = LINE[kind]
        ln:SetColorTexture(sp.r, sp.g, sp.b, q > 0 and sp.a * q / FADE_STEPS or sp.a)
        if ln.kind ~= kind then ln:SetThickness(sp.th) end
        ln.kind, ln.q = kind, q
    end
    ln:SetStartPoint("TOPLEFT", ov, x1, -y1)
    ln:SetEndPoint("TOPLEFT", ov, x2, -y2)
    if not ln.on then
        ln:Show()
        ln.on = true
    end
end

local function HideRest()
    for i = nLines + 1, shownLines do
        lines[i]:Hide()
        lines[i].on = false
    end
    shownLines = nLines
end

-- Where a map's own 0..1 lands on the canvas -------------------------------------------------------
-- Each map the character was recorded on has an affine map to the canvas (canvas = o + p * s), worked out
-- from two calls and cached until the host map changes, so a redraw makes no API call per point. OpenMap
-- places every zone in one stitched world: WorldFromMap puts a recorded point on it and MapFromWorld puts
-- that on the map the stitched view sits on (the canvas). A map outside the stitched world has none.

-- Without OpenMap's stitched map the layers sit on the game's own map: the canvas is the shown map, and
-- C_Map.GetMapRectOnMap gives where a child map lies on it (the shown map itself is the identity). A map
-- that is not the shown map or one of its children has none.

local aff, affHost, affMode = {}, nil, nil

local function ComputeAffine(mode, api, host, mapID)
    if mode ~= "openmap" then
        if mapID == host then return { 0, 0, 1, 1 } end
        local C = _G.C_Map
        if not C or not C.GetMapRectOnMap then return end
        local ok, l, r, t, b = pcall(C.GetMapRectOnMap, mapID, host)
        if not (ok and type(l) == "number" and type(r) == "number" and type(t) == "number" and type(b) == "number") then
            return
        end
        if not (r > l and b > t) then return end
        return { l, t, r - l, b - t }
    end
    local u0, v0 = api.WorldFromMap(mapID, 0, 0)
    local u1, v1 = api.WorldFromMap(mapID, 1, 1)
    if not (u0 and v0 and u1 and v1) then return end
    local x0, y0 = api.MapFromWorld(host, u0, v0)
    local x1, y1 = api.MapFromWorld(host, u1, v1)
    if not (x0 and y0 and x1 and y1) then return end
    local sx, sy = x1 - x0, y1 - y0
    if not (sx > 0 and sy > 0) then return end
    return { x0, y0, sx, sy }
end

local function Affine(mode, api, host, mapID)
    local a = aff[mapID]
    if a == nil then
        a = ComputeAffine(mode, api, host, mapID) or false
        aff[mapID] = a
    end
    return a
end

-- The part of the canvas in view, 0..1 of the canvas, from the geometry of the canvas and the frame that
-- scrolls it (read off the screen, not from the map's own scroll values). Returns nil when it cannot tell.
local function ViewOf(map, canvas, W, H)
    local sc = map.ScrollContainer
    if not sc or not sc.GetLeft then return end
    local cl, ct = canvas:GetLeft(), canvas:GetTop()
    local sl, sr, st, sb = sc:GetLeft(), sc:GetRight(), sc:GetTop(), sc:GetBottom()
    if not (cl and ct and sl and sr and st and sb) then return end
    local ce, se = canvas:GetEffectiveScale(), sc:GetEffectiveScale()
    local cw, ch = W * ce, H * ce
    if not (cw > 0 and ch > 0) then return end
    local x0, x1 = (sl * se - cl * ce) / cw, (sr * se - cl * ce) / cw
    local y0, y1 = (ct * ce - st * se) / ch, (ct * ce - sb * se) / ch
    if not (x1 > x0 and y1 > y0) then return end -- also false for NaN
    local mx, my = (x1 - x0) * 0.05, (y1 - y0) * 0.05
    return x0 - mx, y0 - my, x1 + mx, y1 + my
end

-- Drawing ------------------------------------------------------------------------------------------

-- The walked path of the last TRAIL_SECS, from MapData.lua as x, y, t triples (x = -1 ends a stretch). It is
-- read newest first, so a pool of lines that runs out drops the oldest. Points further apart than the step
-- are joined; a line fades with the age of its newer end, one of FADE_STEPS for each minute, and none is
-- drawn once that end is TRAIL_SECS old. `nowT` is the time of this draw.
local TRAIL_SECS = ns.MapData.TRAIL_SECS
local nowT = 0
local function TrailOf(arr, a)
    if not arr then return end
    local ox, oy, sx, sy = a[1], a[2], a[3], a[4]
    local step2 = STEP_MIN * STEP_MIN
    local have, lx, ly, lq = false, 0, 0, 0
    for i = #arr - 2, 1, -3 do
        local x = arr[i]
        if x < -0.5 then
            have = false
        else
            local cx, cy = (ox + x * sx) * PW, (oy + arr[i + 1] * sy) * PH
            if not have then
                local age = nowT - arr[i + 2]
                if age >= TRAIL_SECS then return end -- everything before this point is older still
                if age < 0 then age = 0 end -- the clock ticks in whole seconds, a point may be a hair ahead of it
                have, lx, ly, lq = true, cx, cy, ceil((1 - age / TRAIL_SECS) * FADE_STEPS)
            else
                local dx, dy = cx - lx, cy - ly
                if dx * dx + dy * dy >= step2 then
                    if not ((lx < X0 and cx < X0) or (lx > X1 and cx > X1) or (ly < Y0 and cy < Y0) or (ly > Y1 and cy > Y1)) then
                        if nLines >= MAX_LINES then return end
                        Seg("trail", cx, cy, lx, ly, lq)
                    end
                    local age = nowT - arr[i + 2]
                    if age >= TRAIL_SECS then return end
                    if age < 0 then age = 0 end
                    lx, ly, lq = cx, cy, ceil((1 - age / TRAIL_SECS) * FADE_STEPS)
                end
            end
        end
    end
end

local function Hide()
    if ov then ov:Hide() end
end

-- Which map the layers go on: OpenMap's stitched map when it is up, else the game's own (OpenMap absent,
-- or loaded but showing Blizzard's map). The game's map takes them only with its switch on.
local function ModeNow()
    local api = OM()
    if api and api.IsStitched() then return "openmap", api end
    return "blizzard"
end

local function Draw()
    local map = _G.WorldMapFrame
    if not (map and map:IsShown() and AnyOn()) then return Hide() end
    local mode, api = ModeNow()
    M.mode = mode
    if mode == "blizzard" and not On("blizzard") then return Hide() end
    local canvas = map:GetCanvas()
    local host = map:GetMapID()
    if not canvas or not host then return Hide() end
    local W, H = canvas:GetWidth(), canvas:GetHeight()
    if not (W and H and W > 0 and H > 0) then return Hide() end
    local scale = map.GetCanvasScale and map:GetCanvasScale() or 1
    if not (scale and scale > 0) then scale = 1 end

    if not ov then
        ov = CreateFrame("Frame", nil, canvas)
        ov:SetSize(1, 1)
        ov:EnableMouse(false)
    end
    if ov:GetParent() ~= canvas then ov:SetParent(canvas) end
    if host ~= affHost or mode ~= affMode then
        wipe(aff)
        affHost, affMode = host, mode
    end
    ov:SetScale(1 / scale)
    ov:ClearAllPoints()
    ov:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, 0)
    local level
    if mode == "openmap" then
        level = api.ArtTopLevel()
    else
        -- above the game's exploration art, below its pins
        local fl = map.GetPinFrameLevelsManager and map:GetPinFrameLevelsManager()
        if fl then
            local ok, v = pcall(fl.GetValidFrameLevel, fl, "PIN_FRAME_LEVEL_MAP_EXPLORATION")
            if ok and type(v) == "number" then level = v end
        end
    end
    level = (level or canvas:GetFrameLevel()) + 1
    if level > 9990 then level = 9990 end
    if ov:GetFrameLevel() ~= level then ov:SetFrameLevel(level) end
    ov:Show()

    PW, PH = W * scale, H * scale
    local vx0, vy0, vx1, vy1 = ViewOf(map, canvas, W, H)
    if not vx0 then vx0, vy0, vx1, vy1 = 0, 0, 1, 1 end
    X0, Y0, X1, Y1 = vx0 * PW, vy0 * PH, vx1 * PW, vy1 * PH
    nLines = 0

    local stores = ns.MapData.stores
    nowT = time()
    for s = #stores, 1, -1 do
        for mapID, ms in pairs(stores[s].maps) do
            local a = Affine(mode, api, host, mapID)
            if a and ms.trail and a[1] + a[3] >= vx0 and a[1] <= vx1 and a[2] + a[4] >= vy0 and a[2] <= vy1 then
                TrailOf(ms.trail, a)
            end
        end
    end
    trailDrawn = nLines
    HideRest()
end
M.Draw = Draw

-- When to draw ----------------------------------------------------------------------------------------

local driver = CreateFrame("Frame")
local running, busy, acc = false, false, 0
local armed = false
local lastDraw = -10
local BUILD_REDRAW = 0.5  -- while the history is still being read, draw what is there this often
local WATCH_EVERY = 0.1   -- the game's own map says nothing when it pans or zooms: look this often
local sigS, sigL, sigT, wacc = 0, 0, 0, 0

-- Whether the game's map was panned or zoomed since the last look (its canvas scale or position moved).
local function Moved()
    local map = _G.WorldMapFrame
    local canvas = map and map:GetCanvas()
    if not canvas then return false end
    local s = map.GetCanvasScale and map:GetCanvasScale() or 1
    local l, t = canvas:GetLeft() or 0, canvas:GetTop() or 0
    if s == sigS and l == sigL and t == sigT then return false end
    sigS, sigL, sigT = s, l, t
    return true
end

local function Tick(_, elapsed)
    acc = acc + elapsed
    if M.mode == "blizzard" then
        wacc = wacc + elapsed
        if wacc >= WATCH_EVERY then
            wacc = 0
            if Moved() then dirty = true end
        end
    end
    if busy then
        local changed, more = ns.MapData.Pump(4)
        busy = more
        if changed and (not more or GetTime() - lastDraw >= BUILD_REDRAW) then dirty = true end
    elseif acc >= STALE_CHECK then
        acc = 0
        if ns.MapData.Stale() then
            local changed, more = ns.MapData.Pump(4)
            busy = more
            if changed then dirty = true end
        end
        if trailDrawn > 0 then dirty = true end -- the trail fades with time
    end
    if dirty then
        dirty = false
        lastDraw = GetTime()
        local ok, err = pcall(Draw)
        if not ok then
            M.error = err
            M.Stop()
            Hide()
            if ns.Print then ns.Print("the map layers stopped: " .. tostring(err)) end
        end
    end
end

function M.Stop()
    running = false
    driver:SetScript("OnUpdate", nil)
end

local function Start()
    dirty, busy, acc = true, true, 0
    if not running then
        running = true
        driver:SetScript("OnUpdate", ns.Perf.Fn("Map:Update", Tick))
    end
end

-- Callbacks from OpenMap, registered the first time the map opens with a layer on.
function M:OnView()
    dirty = true
end

local Refresh

function M:OnStitched()
    wipe(aff)
    Refresh()
end

local function Arm()
    if armed then return end
    local api = OM()
    if not api or type(api.RegisterCallback) ~= "function" then return end
    armed = true
    api.RegisterCallback(M, "OpenMap_ViewChanged", "OnView")
    api.RegisterCallback(M, "OpenMap_StitchedChanged", "OnStitched")
end

-- The switch on the game's own map -------------------------------------------------------------------------
-- Shown only while the game's map is the one up (never over OpenMap's stitched map, which has the menu).

local sw

-- The one switch over every layer (Settings page of Scarlet's window). Off keeps each layer's own setting.
local function SetDraw(v)
    if not ns.opt then return end
    if type(ns.opt.map) ~= "table" then ns.opt.map = {} end
    ns.opt.map.draw = v and true or false
    dirty = true
    Refresh()
end
M.SetDraw = SetDraw

-- Turning a layer or the game map's switch on while drawing is off turns drawing back on, so it shows.
local function Set(id, v)
    if not ns.opt then return end
    if type(ns.opt.map) ~= "table" then ns.opt.map = {} end
    ns.opt.map[id] = v and true or false
    if v then ns.opt.map.draw = true end
    if v and id == "blizzard" then ns.opt.map.trail = true end
    dirty = true
    Refresh()
end

local function SetMaster(v) Set("blizzard", v) end
local function SetLayer(id, v) Set(id, v) end

-- What a layer's switch shows: off while drawing is off.
local function Shown(id) return Drawing() and On(id) end

local function BuildSwitch(map)
    local anchor = map.ScrollContainer or map
    sw = CreateFrame("CheckButton", nil, map, "UICheckButtonTemplate")
    sw:SetSize(24, 24)
    sw:SetPoint("TOPLEFT", anchor, "TOPLEFT", 6, -6)
    sw:SetFrameLevel(anchor:GetFrameLevel() + 80)
    local fs = sw:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("LEFT", sw, "RIGHT", 0, 1)
    fs:SetText("Scarlet")
    sw:SetScript("OnClick", function(self) SetMaster(self:GetChecked() and true or false) end)
end

local function UpdateSwitch(map, mode)
    if mode == "blizzard" and map and map:IsShown() then
        if not sw then BuildSwitch(map) end
        sw:SetChecked(AnyOn() and On("blizzard"))
        sw:Show()
    elseif sw then
        sw:Hide()
    end
end

-- Called when the map opens, when OpenMap's map switches, and when a switch changes.
Refresh = function()
    local map = _G.WorldMapFrame
    if not (map and map:IsShown()) then
        M.Stop()
        Hide()
        UpdateSwitch(map, nil)
        return
    end
    Arm()
    local mode = ModeNow()
    UpdateSwitch(map, mode)
    if AnyOn() and (mode == "openmap" or On("blizzard")) and ns.db and ns.charKey then
        Start()
    else
        M.Stop()
        Hide()
    end
end
M.Refresh = Refresh

local function OnShow() Refresh() end
local function OnHide()
    M.Stop()
    Hide()
end
local function OnMapChanged() dirty = true end

local hooked = false
local function HookMap()
    local map = _G.WorldMapFrame
    if hooked or not map then return end
    hooked = true
    map:HookScript("OnShow", OnShow)
    map:HookScript("OnHide", OnHide)
    if type(map.OnMapChanged) == "function" then hooksecurefunc(map, "OnMapChanged", OnMapChanged) end
end

-- The menu in OpenMap -------------------------------------------------------------------------------------

local registered = false

local function Register()
    if registered then return end
    local api = OM()
    if not api or type(api.RegisterMenuToggle) ~= "function" then return end
    registered = true
    for _, L in ipairs(LAYERS) do
        local id = L.id
        local ok, err = pcall(api.RegisterMenuToggle, "Scarlet", {
            id = id,
            label = L.label,
            section = "Scarlet",
            tab = "show",
            icon = ICON,
            get = function() return Shown(id) end,
            set = function(v) SetLayer(id, v) end,
        })
        if not ok then
            geterrorhandler()(err)
            break
        end
    end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(self, event, name)
    if event == "ADDON_LOADED" then
        if name == "Blizzard_WorldMap" then HookMap() end
        if name == "OpenMap" then Register() end
        return
    end
    Register()
    HookMap()
    if hooked and registered then self:UnregisterAllEvents() end
    -- The map may be open already (a reload with it up).
    if hooked then Refresh() end
end)
