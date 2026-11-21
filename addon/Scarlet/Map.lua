-- Map.lua: the character's own recorded places on the world map.
-- With the OpenMap addon loaded (thanks to its author; MIT code, its map art is Blizzard's), the layers are
-- switches in OpenMap's menu under "Scarlet" and are drawn on OpenMap's stitched map, above its art. Only
-- OpenMap's public API (the global OpenMapAPI, major 1, version 2 or later) is used. Without OpenMap, or while
-- it shows the game's own map, the same layers are drawn on the game's map for the map being shown, behind a
-- small "Scarlet" switch on the map (off until it is turned on). Positions come from MapData.lua, which reads what Scarlet
-- already recorded; nothing new is captured here and nothing is written but the switches in ScarletDB.opt.map.
--
-- Cost while off: after login this file does nothing but wait for the world map to open. Once it opens
-- with a layer on, one OnUpdate on Scarlet's own frame reads the history within a few milliseconds a
-- frame, redraws when the view moves, and stops when the map closes. A redraw allocates nothing: pins,
-- lines and labels come from pools. No protected frame is touched; the only hooks on Blizzard's map are
-- HookScript OnShow and OnHide and a post-hook on OnMapChanged, which only set flags.
local _, ns = ...

local type, pairs, ipairs, floor, max = type, pairs, ipairs, math.floor, math.max
local GetTime = GetTime
local wipe = wipe

local M = {}
ns.Map = M

-- Layers, in the order of the app's Survey look. `on` is the default.
local LAYERS = {
    { id = "trips", label = "Flights and teleports", on = true },
    { id = "trail", label = "Trail walked", on = true },
    { id = "deaths", label = "Deaths", on = true },
    { id = "gather", label = "Gathering and fishing", on = true },
    { id = "npcs", label = "NPC windows", on = false },
    { id = "quests", label = "Quests accepted and turned in", on = false },
    { id = "found", label = "Areas discovered", on = true },
    { id = "camps", label = "Camps", on = true },
}
local DEFAULT = {}
for _, L in ipairs(LAYERS) do DEFAULT[L.id] = L.on end
DEFAULT.blizzard = false -- the switch on the game's own map (no OpenMap): off until the player turns it on

local ICON = "Interface\\AddOns\\Scarlet\\Media\\Icon"
local SKULLS = "Interface\\TargetingFrame\\UI-RaidTargetingIcons"

-- Pins: size in screen pixels, a colour or a texture with its coordinates.
local PIN = {
    death = { size = 15, tex = SKULLS, l = 0.75, r = 1, t = 0.25, b = 0.5 },
    gather = { size = 7, r = 0.94, g = 0.95, b = 0.96, a = 0.9 },
    fishing = { size = 7, r = 0.18, g = 0.62, b = 0.77, a = 1 },
    npc = { size = 5, r = 0.78, g = 0.78, b = 0.85, a = 0.85 },
    qacc = { size = 7, r = 1, g = 0.85, b = 0.2, a = 1 },
    qdone = { size = 7, r = 0.35, g = 0.85, b = 0.4, a = 1 },
    found = { size = 8, r = 0.4, g = 0.9, b = 1, a = 0.95 },
    camp = { size = 9, r = 1, g = 0.55, b = 0.15, a = 1 },
}
local SLOT = { death = 1, gather = 2, fishing = 3, npc = 4, qacc = 5, qdone = 6, found = 7, camp = 8 }
-- Lines: colour and thickness in screen pixels.
local LINE = {
    trail = { r = 1, g = 0.18, b = 0.33, a = 0.85, th = 2 },
    flights = { r = 0.35, g = 0.7, b = 1, a = 0.9, th = 2 },
    teleports = { r = 0.75, g = 0.5, b = 1, a = 0.9, th = 2 },
}

local MAX_PINS, MAX_LINES, MAX_LABELS = 700, 1600, 30
local TRAIL_LINES = MAX_LINES - 300   -- the rest is for flights and teleports
local STEP_MIN = 3.5                  -- screen pixels between two drawn trail points, at least
local GRID_N = 96                     -- the view is cut into GRID_N x GRID_N cells, one pin of a kind each
local STALE_CHECK = 2                 -- seconds between looks at the open buffers while the map is open

-- Settings ---------------------------------------------------------------------------------

local function On(id)
    local t = ns.opt and ns.opt.map
    local v
    if type(t) == "table" then v = t[id] end
    if v == nil then return DEFAULT[id] end
    return v and true or false
end
M.On = On

local function AnyOn()
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
local pins, nPins, shownPins = {}, 0, 0
-- shownLines is the highest line a draw has touched since the last HideRest: the trail is drawn in up to four
-- passes that each start again at line 1, so it can be higher than the lines the final pass leaves in use.
local lines, nLines, shownLines = {}, 0, 0
local labels, nLabels, shownLabels = {}, 0, 0
local occ = {}                -- GRID_N * GRID_N cells, each holding the stamp of the last pin put in it
for i = 0, GRID_N * GRID_N - 1 do occ[i] = 0 end
local serial = 0

-- Per draw: canvas size in overlay pixels, the view in the same, the step between trail points.
local PW, PH, X0, Y0, X1, Y1, cellX, cellY, stamp, inv
local trailStep = STEP_MIN
local trailHost, trailPW, trailPH   -- the map and size the step was worked out for; it starts over when they change
local capped = false
local dirty = false                 -- a redraw is due (set by the callbacks below, and by a draw that wants another)

local function NewPin()
    return ov:CreateTexture(nil, "OVERLAY")
end

local function Pin(kind, cx, cy)
    if nPins >= MAX_PINS then return end
    nPins = nPins + 1
    local p = pins[nPins]
    if not p then
        p = NewPin()
        pins[nPins] = p
    end
    local sp = PIN[kind]
    if p.kind ~= kind then
        if sp.tex then
            p:SetTexture(sp.tex)
            p:SetTexCoord(sp.l, sp.r, sp.t, sp.b)
            p:SetVertexColor(1, 1, 1, 1)
        else
            p:SetColorTexture(sp.r, sp.g, sp.b, sp.a)
            p:SetTexCoord(0, 1, 0, 1)
        end
        p:SetSize(sp.size, sp.size)
        p.kind = kind
    end
    p:ClearAllPoints()
    p:SetPoint("CENTER", ov, "TOPLEFT", cx, -cy)
    if not p.on then
        p:Show()
        p.on = true
    end
    return p
end

local function Seg(kind, x1, y1, x2, y2)
    if nLines >= MAX_LINES then return end
    nLines = nLines + 1
    if nLines > shownLines then shownLines = nLines end
    local ln = lines[nLines]
    if not ln then
        ln = ov:CreateLine(nil, "OVERLAY")
        lines[nLines] = ln
    end
    if ln.kind ~= kind then
        local sp = LINE[kind]
        ln:SetColorTexture(sp.r, sp.g, sp.b, sp.a)
        ln:SetThickness(sp.th)
        ln.kind = kind
    end
    ln:SetStartPoint("TOPLEFT", ov, x1, -y1)
    ln:SetEndPoint("TOPLEFT", ov, x2, -y2)
    if not ln.on then
        ln:Show()
        ln.on = true
    end
end

local function Label(text, cx, cy)
    if nLabels >= MAX_LABELS then return end
    nLabels = nLabels + 1
    local fs = labels[nLabels]
    if not fs then
        fs = ov:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetJustifyH("LEFT")
        fs:SetTextColor(0.85, 0.97, 1, 1)
        labels[nLabels] = fs
    end
    if fs.text ~= text then
        fs:SetText(text)
        fs.text = text
    end
    fs:ClearAllPoints()
    fs:SetPoint("LEFT", ov, "TOPLEFT", cx + 7, -cy)
    if not fs.on then
        fs:Show()
        fs.on = true
    end
end

local function HideRest()
    for i = nPins + 1, shownPins do
        pins[i]:Hide()
        pins[i].on = false
    end
    for i = nLines + 1, shownLines do
        lines[i]:Hide()
        lines[i].on = false
    end
    for i = nLabels + 1, shownLabels do
        labels[i]:Hide()
        labels[i].on = false
    end
    shownPins, shownLines, shownLabels = nPins, nLines, nLabels -- from here on, only these are on
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

-- One kind of pins from a flat array of positions on one map.
local function PinsOf(arr, kind, a)
    if not arr then return end
    local ox, oy, sx, sy = a[1], a[2], a[3], a[4]
    local slot = stamp + SLOT[kind]
    for i = 1, #arr, 2 do
        local cx, cy = (ox + arr[i] * sx) * PW, (oy + arr[i + 1] * sy) * PH
        if cx >= X0 and cx <= X1 and cy >= Y0 and cy <= Y1 then
            local gx, gy = floor((cx - X0) * cellX), floor((cy - Y0) * cellY)
            if gx >= GRID_N then gx = GRID_N - 1 end
            if gy >= GRID_N then gy = GRID_N - 1 end
            local cell = gy * GRID_N + gx
            if occ[cell] ~= slot then
                occ[cell] = slot
                Pin(kind, cx, cy)
            end
        end
    end
end

local function LabelsOf(ms, a)
    local arr, names = ms.found, ms.foundName
    if not arr or not names then return end
    local ox, oy, sx, sy = a[1], a[2], a[3], a[4]
    for i = 1, #names do
        local cx, cy = (ox + arr[i * 2 - 1] * sx) * PW, (oy + arr[i * 2] * sy) * PH
        if cx >= X0 and cx <= X1 and cy >= Y0 and cy <= Y1 then Label(names[i], cx, cy) end
    end
end

-- Straight lines (flights, teleports): x1, y1, x2, y2 on the map.
local function SegsOf(arr, kind, a)
    if not arr then return end
    local ox, oy, sx, sy = a[1], a[2], a[3], a[4]
    for i = 1, #arr, 4 do
        local x1, y1 = (ox + arr[i] * sx) * PW, (oy + arr[i + 1] * sy) * PH
        local x2, y2 = (ox + arr[i + 2] * sx) * PW, (oy + arr[i + 3] * sy) * PH
        if not ((x1 < X0 and x2 < X0) or (x1 > X1 and x2 > X1) or (y1 < Y0 and y2 < Y0) or (y1 > Y1 and y2 > Y1)) then
            Seg(kind, x1, y1, x2, y2)
        end
    end
end

-- The coarsest tier of a map's trail whose own step, at the size the map is drawn now, is still below the
-- step between drawn points, so a map drawn small does not walk every point it has.
local TRAIL_KEYS, TRAIL_STEPS = ns.MapData.TRAIL_KEYS, ns.MapData.TRAIL_STEPS
local BOX_KEYS, BLOCK2 = ns.MapData.BOX_KEYS, ns.MapData.TRAIL_BLOCK * 2
local function TrailTier(ms, a)
    local unit = max(a[3] * PW, a[4] * PH) / 10000   -- screen pixels per recorded unit
    for i = 3, 2, -1 do
        local arr = ms[TRAIL_KEYS[i]]
        if arr and TRAIL_STEPS[i] * unit <= trailStep then return arr, ms[BOX_KEYS[i]] end
    end
    return ms[TRAIL_KEYS[1]], ms[BOX_KEYS[1]]
end

-- The walked path: points further apart than the step, broken where a stretch ended (x = -1). The points
-- come in blocks with a bounding box each (MapData.lua); a block outside the view is not read, and the
-- stretch goes on from the point before the next block that is in view.
-- Sets `capped` when the pool of lines ran out, so the caller can draw again with a coarser step.
local function TrailOf(arr, box, a)
    if not (arr and box) then return end
    local ox, oy, sx, sy = a[1], a[2], a[3], a[4]
    local step2 = trailStep * trailStep
    local have, lx, ly = false, 0, 0
    local n = #arr
    for b = 0, #box / 4 - 1 do
        local k = b * 4
        if (ox + box[k + 3] * sx) * PW < X0 or (ox + box[k + 1] * sx) * PW > X1
            or (oy + box[k + 4] * sy) * PH < Y0 or (oy + box[k + 2] * sy) * PH > Y1 then
            have = false
        else
            local s = b * BLOCK2 + 1
            if not have and s > 1 and arr[s - 2] > -0.5 then
                have, lx, ly = true, (ox + arr[s - 2] * sx) * PW, (oy + arr[s - 1] * sy) * PH
            end
            local e = s + BLOCK2 - 1
            if e > n then e = n end
            for i = s, e, 2 do
                local x = arr[i]
                if x < -0.5 then
                    have = false
                else
                    local cx, cy = (ox + x * sx) * PW, (oy + arr[i + 1] * sy) * PH
                    if not have then
                        have, lx, ly = true, cx, cy
                    else
                        local dx, dy = cx - lx, cy - ly
                        if dx * dx + dy * dy >= step2 then
                            if not ((lx < X0 and cx < X0) or (lx > X1 and cx > X1) or (ly < Y0 and cy < Y0) or (ly > Y1 and cy > Y1)) then
                                if nLines >= TRAIL_LINES then
                                    capped = true
                                    return
                                end
                                Seg("trail", lx, ly, cx, cy)
                            end
                            lx, ly = cx, cy
                        end
                    end
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
    -- The overlay is scaled against the canvas, so pins, lines and text keep their size on screen.
    inv = 1 / scale
    ov:SetScale(inv)
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
    if host ~= trailHost or PW ~= trailPW or PH ~= trailPH then
        -- another map or another zoom: the step worked out for the last view says nothing about this one
        trailHost, trailPW, trailPH = host, PW, PH
        trailStep = STEP_MIN
    end
    local vx0, vy0, vx1, vy1 = ViewOf(map, canvas, W, H)
    if not vx0 then vx0, vy0, vx1, vy1 = 0, 0, 1, 1 end
    X0, Y0, X1, Y1 = vx0 * PW, vy0 * PH, vx1 * PW, vy1 * PH
    cellX, cellY = GRID_N / (X1 - X0), GRID_N / (Y1 - Y0)
    serial = serial + 1
    stamp = serial * 16
    nPins, nLabels, nLines = 0, 0, 0

    local stores = ns.MapData.stores
    -- The trail first, coarser until it fits the pool of lines.
    if On("trail") then
        for _ = 1, 4 do
            nLines, capped = 0, false
            for s = 1, #stores do
                for mapID, ms in pairs(stores[s].maps) do
                    local a = Affine(mode, api, host, mapID)
                    if a and ms.trail and a[1] + a[3] >= vx0 and a[1] <= vx1 and a[2] + a[4] >= vy0 and a[2] <= vy1 then
                        local arr, box = TrailTier(ms, a)
                        TrailOf(arr, box, a)
                    end
                end
            end
            if not capped then break end
            trailStep = trailStep * 1.7
        end
        if not capped and nLines < TRAIL_LINES * 0.4 and trailStep > STEP_MIN then
            trailStep = max(STEP_MIN, trailStep / 1.3)
            dirty = true -- one more draw with the finer step, until it is back at the least
        end
    end
    local trips, deaths, gather = On("trips"), On("deaths"), On("gather")
    local npcs, quests, found, camps = On("npcs"), On("quests"), On("found"), On("camps")
    for s = 1, #stores do
        for mapID, ms in pairs(stores[s].maps) do
            local a = Affine(mode, api, host, mapID)
            if a and a[1] + a[3] >= vx0 and a[1] <= vx1 and a[2] + a[4] >= vy0 and a[2] <= vy1 then
                if trips then
                    SegsOf(ms.flights, "flights", a)
                    SegsOf(ms.teleports, "teleports", a)
                end
                if deaths then PinsOf(ms.deaths, "death", a) end
                if gather then
                    PinsOf(ms.gather, "gather", a)
                    PinsOf(ms.fishing, "fishing", a)
                end
                if npcs then PinsOf(ms.npcs, "npc", a) end
                if quests then
                    PinsOf(ms.qacc, "qacc", a)
                    PinsOf(ms.qdone, "qdone", a)
                end
                if found then
                    PinsOf(ms.found, "found", a)
                    LabelsOf(ms, a)
                end
                if camps then PinsOf(ms.camps, "camp", a) end
            end
        end
    end
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
        driver:SetScript("OnUpdate", Tick)
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
-- All of it is Scarlet's own frames: a check button for the whole set, and a short list of the layers behind
-- a small arrow. No dropdown template, which would taint.

local sw, pop, popRows

local function SetMaster(v)
    if not ns.opt then return end
    if type(ns.opt.map) ~= "table" then ns.opt.map = {} end
    ns.opt.map.blizzard = v and true or false
    dirty = true
    Refresh()
end

local function SetLayer(id, v)
    if not ns.opt then return end
    if type(ns.opt.map) ~= "table" then ns.opt.map = {} end
    ns.opt.map[id] = v and true or false
    dirty = true
    Refresh()
end

local function SyncPop()
    if not popRows then return end
    for i = 1, #popRows do popRows[i]:SetChecked(On(popRows[i].layer)) end
end

local function BuildPop(map)
    pop = CreateFrame("Frame", nil, map)
    pop:SetSize(200, 8 + #LAYERS * 22)
    pop:SetPoint("TOPLEFT", sw, "BOTTOMLEFT", 0, -2)
    pop:SetFrameLevel(sw:GetFrameLevel() + 5)
    local bg = pop:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.06, 0.06, 0.08, 0.92)
    popRows = {}
    for i, L in ipairs(LAYERS) do
        local cb = CreateFrame("CheckButton", nil, pop, "UICheckButtonTemplate")
        cb:SetSize(22, 22)
        cb:SetPoint("TOPLEFT", pop, "TOPLEFT", 6, -4 - (i - 1) * 22)
        local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("LEFT", cb, "RIGHT", 2, 1)
        fs:SetText(L.label)
        cb.layer = L.id
        cb:SetScript("OnClick", function(self) SetLayer(self.layer, self:GetChecked() and true or false) end)
        popRows[i] = cb
    end
    pop:Hide()
end

local function TogglePop()
    local map = _G.WorldMapFrame
    if not (sw and map) then return end
    if not pop then BuildPop(map) end
    if pop:IsShown() then
        pop:Hide()
    else
        SyncPop()
        pop:Show()
    end
end

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
    local more = CreateFrame("Button", nil, sw)
    more:SetSize(16, 20)
    more:SetPoint("LEFT", fs, "RIGHT", 4, 0)
    local mt = more:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    mt:SetAllPoints()
    mt:SetText("v")
    more:SetScript("OnClick", TogglePop)
end

local function UpdateSwitch(map, mode)
    if mode == "blizzard" and map and map:IsShown() then
        if not sw then BuildSwitch(map) end
        sw:SetChecked(On("blizzard"))
        sw:Show()
        if pop and pop:IsShown() then SyncPop() end
    elseif sw then
        sw:Hide()
        if pop then pop:Hide() end
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
            get = function() return On(id) end,
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
