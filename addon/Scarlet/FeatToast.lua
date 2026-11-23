local _, ns = ...

if not ns.Feats then return end

local min, max, format = math.min, math.max, string.format

local Toast = {}
ns.FeatToast = Toast

local W, H = 344, 78
local TOP_OFFSET = -170
local SEAL = 64
local AFTER_COMBAT, AFTER_LEVEL = 0.6, 4
local GAP, HOLD, FADE = 1, 4.8, 0.4
local FULL_IN_ROW, FULL_PER_WINDOW, WINDOW = 2, 3, 600
local STALE = 300
local AWAY_DELAY = 9
local RETRY = 5
local MEDIA = "Interface\\AddOns\\Scarlet\\Media\\"

local frame = CreateFrame("Frame")
local Events = {}
local queue, recent = {}, {}
local active, holdUntil, fullInRow, retrying = false, 0, 0, false
local plate, token = nil, 0

local function Alerts() return ns.opt and ns.opt.featAlerts or "all" end
local function Enabled() return Alerts() ~= "off" end
local function Animated() return not ns.opt or ns.opt.featAnim ~= false end

local function Mark(key, tier)
    local ch = ns.char
    if not ch then return end
    ch.featSeen = ch.featSeen or {}
    ch.featSeen[key] = max(ch.featSeen[key] or 0, tier)
end

local function MarkNew(key, tier)
    local ch = ns.char
    if not ch then return end
    ch.featNew = ch.featNew or {}
    ch.featNew[key] = max(ch.featNew[key] or 0, tier)
end

local function Sound()
    if not ns.opt or ns.opt.featSound == false or not _G.PlaySound then return end
    local kit = _G.SOUNDKIT
    pcall(PlaySound, kit and kit.IG_QUEST_LIST_COMPLETE or 878)
end

local function Group(f)
    local g = f:CreateAnimationGroup()
    return g
end

local function Alpha(g, from, to, secs, delay)
    local a = g:CreateAnimation("Alpha")
    a:SetFromAlpha(from)
    a:SetToAlpha(to)
    a:SetDuration(secs)
    a:SetStartDelay(delay or 0)
    a:SetSmoothing("OUT")
    return a
end

local function Scale(g, from, to, secs, delay)
    local s = g:CreateAnimation("Scale")
    if s.SetScaleFrom then
        s:SetScaleFrom(from, from)
        s:SetScaleTo(to, to)
    elseif s.SetFromScale then
        s:SetFromScale(from, from)
        s:SetToScale(to, to)
    end
    s:SetDuration(secs)
    s:SetStartDelay(delay or 0)
    s:SetSmoothing("OUT")
    return s
end

local function Build()
    local ui = ns.UI
    local T = ui.T
    local f = CreateFrame("Button", "ScarletFeatToast", UIParent)
    f:SetSize(W, H)
    f:SetFrameStrata("HIGH")
    f:RegisterForClicks("LeftButtonUp")
    ui.Fill(f, T.bg, 0.96):SetAllPoints()
    ui.Border(f, T.line2)
    f.rail = ui.Fill(f, T.accent, 1, "ARTWORK")
    f.rail:SetPoint("TOPLEFT", 1, -1)
    f.rail:SetPoint("BOTTOMLEFT", 1, 1)
    f.rail:SetWidth(3)
    f.glow = f:CreateTexture(nil, "ARTWORK", nil, 2)
    f.glow:SetTexture(MEDIA .. "Glow")
    f.glow:SetBlendMode("ADD")
    f.glow:SetSize(SEAL * 1.5, SEAL * 1.5)
    f.glow:SetPoint("CENTER", f, "LEFT", 12 + SEAL / 2 + 4, 0)
    f.glow:SetAlpha(0)
    f.seal = ui.Seal(f, SEAL)
    f.seal:SetPoint("LEFT", 16, 0)
    f.plus = ui.Text(f, 30, T.fg, "CENTER", "display")
    f.plus:SetPoint("CENTER", f.seal, "CENTER")
    f.label = ui.Text(f, 12, T.muted)
    f.label:SetPoint("TOPLEFT", 92, -11)
    f.name = ui.Text(f, 22, T.fg, "LEFT", "display")
    f.name:SetPoint("TOPLEFT", 92, -25)
    f.chip = ui.Text(f, 11, T.fg, "CENTER", "strong")
    f.chip:SetPoint("LEFT", f.name, "RIGHT", 8, -1)
    f.detail = ui.Text(f, 12.5, T.text)
    f.detail:SetPoint("TOPLEFT", 92, -53)
    f.detail:SetPoint("RIGHT", -10, 0)
    f.sweep = ui.Fill(f, T.fg, 0.1, "OVERLAY")
    f.sweep:SetSize(46, H - 2)
    f.sweep:SetPoint("TOPLEFT", f, "TOPLEFT", -46, -1)
    f.sweep:SetAlpha(0)
    f.show = Group(f)
    f.hide = Group(f)
    Alpha(f.hide, 1, 0, FADE)
    f.hide:SetScript("OnFinished", function() Toast.Done() end)
    f.seal.pop = Group(f.seal)
    f.glow.burst = Group(f.glow)
    f.sweep.cross = Group(f.sweep)
    f:SetScript("OnClick", function(self)
        if InCombatLockdown() then return end
        if self.featKey then ns.OpenFeat(self.featKey) else ns.UI.Open("feats") end
    end)
    f:Hide()
    return f
end

local function SetSeal(item, tier, progress)
    plate.seal:Set({ family = item.family, glyph = item.glyph, tier = tier, progress = progress or 0,
        spell = item.spell, bg = ns.UI.T.bg })
end

local function Paint(item)
    local ui = ns.UI
    local T = ui.T
    local color = item.tier > 0 and ui.TierColor[item.tier] or T.accent
    plate.featKey = item.key or false
    plate.rail:SetVertexColor(color[1], color[2], color[3], 1)
    plate.label:SetText(item.label or "")
    plate.name:SetText(item.name or "")
    plate.plus:SetText(item.plus or "")
    plate.plus:SetShown(item.plus ~= nil)
    plate.seal:SetShown(item.plus == nil)
    plate.chip:SetText(item.chip or "")
    plate.chip:SetTextColor(color[1], color[2], color[3])
    plate.detail:SetText(item.detail or "")
end

local function Play(item)
    token = token + 1
    local mine = token
    plate:ClearAllPoints()
    plate:SetPoint("TOP", UIParent, "TOP", 0, TOP_OFFSET)
    plate:SetAlpha(1)
    Paint(item)
    local animate = Animated()
    plate.show:Stop()
    plate.show = Group(plate)
    Alpha(plate.show, 0, 1, 0.2)
    if animate then
        plate:SetPoint("TOP", UIParent, "TOP", 0, TOP_OFFSET - 12)
        local rise = plate.show:CreateAnimation("Translation")
        rise:SetOffset(0, 12)
        rise:SetDuration(0.2)
        plate.show:SetScript("OnFinished", function()
            if mine ~= token then return end
            plate:ClearAllPoints()
            plate:SetPoint("TOP", UIParent, "TOP", 0, TOP_OFFSET)
        end)
    else
        plate.show:SetScript("OnFinished", nil)
    end
    plate:Show()
    plate.show:Play()
    Sound()
    local from = item.from or 0
    if item.plus then
        C_Timer.After(HOLD, function() if mine == token then plate.hide:Play() end end)
        return
    end
    if not animate then
        SetSeal(item, item.tier, item.progress)
        C_Timer.After(HOLD, function() if mine == token then plate.hide:Play() end end)
        return
    end
    plate.seal:SetAlpha(0)
    SetSeal(item, from > 0 and from or item.tier, 0)
    C_Timer.After(0.12, function()
        if mine ~= token then return end
        plate.seal:SetAlpha(1)
        plate.seal.pop = Group(plate.seal)
        Scale(plate.seal.pop, 1.35, 1, 0.32)
        plate.seal.pop:Play()
        plate.glow.burst:Stop()
        plate.glow.burst = Group(plate.glow)
        Alpha(plate.glow.burst, 1, 0, 0.62)
        Scale(plate.glow.burst, 0.6, 1.5, 0.62)
        plate.glow:SetAlpha(1)
        plate.glow.burst:SetScript("OnFinished", function() plate.glow:SetAlpha(0) end)
        plate.glow.burst:Play()
        if item.tier == 5 then
            C_Timer.After(0.26, function()
                if mine ~= token then return end
                plate.glow:SetAlpha(1)
                plate.glow.burst:Play()
            end)
        end
    end)
    C_Timer.After(0.28, function()
        if mine == token and from > 0 then SetSeal(item, item.tier, 0) end
    end)
    C_Timer.After(0.5, function()
        if mine ~= token then return end
        plate.sweep:SetAlpha(1)
        plate.sweep:ClearAllPoints()
        plate.sweep:SetPoint("TOPLEFT", plate, "TOPLEFT", -46, -1)
        plate.sweep.cross = Group(plate.sweep)
        local t = plate.sweep.cross:CreateAnimation("Translation")
        t:SetOffset(W + 46, 0)
        t:SetDuration(0.6)
        plate.sweep.cross:SetScript("OnFinished", function() plate.sweep:SetAlpha(0) end)
        plate.sweep.cross:Play()
    end)
    C_Timer.After(0.9, function()
        if mine == token then SetSeal(item, item.tier, 1) end
    end)
    C_Timer.After(1.2, function()
        if mine == token then SetSeal(item, item.tier, item.progress) end
    end)
    C_Timer.After(HOLD, function() if mine == token then plate.hide:Play() end end)
end

local function Pump()
    if active or #queue == 0 or not Enabled() then return end
    local now = GetTime()
    if now < holdUntil then return end
    if ns.Alerts.Quiet() then
        if not InCombatLockdown() and not retrying then
            retrying = true
            C_Timer.After(RETRY, function()
                retrying = false
                Pump()
            end)
        end
        return
    end
    for i = #queue, 1, -1 do
        local it = queue[i]
        if now - it.at > STALE then
            if it.key and not it.test then
                Mark(it.key, it.tier)
                MarkNew(it.key, it.tier)
            end
            table.remove(queue, i)
        end
    end
    if #queue == 0 then return end
    while #recent > 0 and now - recent[1] > WINDOW do table.remove(recent, 1) end
    local item
    if fullInRow >= FULL_IN_ROW or #recent >= FULL_PER_WINDOW then
        local n = #queue
        for i = 1, n do
            local it = queue[i]
            if it.key and not it.test then Mark(it.key, it.tier) end
        end
        item = { plus = "+" .. n, tier = 2, label = "Earned this session",
            name = format("%d more feat%s", n, n == 1 and "" or "s"), detail = "Open the Feats page to see them" }
        queue = {}
    else
        item = table.remove(queue, 1)
        if item.key and not item.test then Mark(item.key, item.tier) end
        recent[#recent + 1] = now
        fullInRow = fullInRow + 1
    end
    active = true
    plate = plate or Build()
    Play(item)
end

--- The plate has faded: after a second the next one may show.
function Toast.Done()
    active = false
    plate:Hide()
    if #queue == 0 then
        fullInRow = 0
        return
    end
    C_Timer.After(GAP, Pump)
end

local function Describe(f, tier, from, value)
    local spells = ns.char and ns.char.featSpell
    local names = ns.FEAT_TIER_NAMES
    return { key = f.key, name = f.name, tier = tier, from = from, value = value, family = f.family, glyph = f.glyph,
        spell = spells and spells[f.key], chip = names[tier],
        label = from > 0 and ("Upgraded from " .. names[from]) or "Feat earned",
        detail = ns.Feats.Count(f, value), progress = ns.Feats.Progress(f, value, tier), at = GetTime() }
end

function Toast.Queue(item)
    queue[#queue + 1] = item
    Pump()
end

local function OnTier(f, value, tier, from)
    if not Enabled() then return end
    local seen = ns.char and ns.char.featSeen and ns.char.featSeen[f.key] or 0
    if tier <= seen then return end
    Toast.Queue(Describe(f, tier, from, value))
end

local function AwaySummary()
    if not Enabled() then return end
    local file = ns.Feats.File()
    local list = file and file.new
    if type(list) ~= "table" then return end
    local fresh, collections, seen = {}, {}, ns.char and ns.char.featSeen or {}
    for _, e in ipairs(list) do
        local f = ns.Feats.Def(e.k)
        if f and (e.to or 0) > (seen[e.k] or 0) then
            fresh[#fresh + 1] = { f = f, to = e.to, from = e.from or 0 }
            local name = f.tree or f.collection or f.name
            local dup = false
            for _, c in ipairs(collections) do dup = dup or c == name end
            if not dup then collections[#collections + 1] = name end
        end
    end
    if #fresh == 0 then return end
    local top = fresh[1]
    for _, e in ipairs(fresh) do
        if e.to > top.to then top = e end
        Mark(e.f.key, e.to)
    end
    local detail = collections[1]
    if #collections > 1 then detail = detail .. ", " .. collections[2] end
    if #collections > 2 then detail = format("%s, and %d more", detail, #collections - 2) end
    local item = Describe(top.f, top.to, 0, 0)
    item.name = format("%d feat%s", #fresh, #fresh == 1 and "" or "s")
    item.label = "Counted on the website while you were away"
    item.chip = nil
    item.detail = detail
    item.progress = 0
    Toast.Queue(item)
end

--- Called at login, after the login message: feats the app counted while the player was away show as one plate.
function Toast.Login()
    C_Timer.After(AWAY_DELAY, AwaySummary)
end

--- /scarlet feats test: two full plates and the folded line.
function Toast.Test()
    local picked = {}
    for _, f in ipairs(ns.FEATS) do
        if ns.Feats.Visible(f) and f.live and #picked < 4 then picked[#picked + 1] = f end
    end
    local now = GetTime()
    for i, f in ipairs(picked) do
        local tier = min(i + 1, 5)
        local item = Describe(f, tier, i == 2 and 1 or 0, f.thresholds[tier])
        item.test, item.at = true, now
        queue[#queue + 1] = item
    end
    Pump()
end

function Events.PLAYER_REGEN_ENABLED()
    if #queue == 0 then return end
    holdUntil = max(holdUntil, GetTime() + AFTER_COMBAT)
    C_Timer.After(AFTER_COMBAT + 0.05, Pump)
end

function Events.PLAYER_LEVEL_UP()
    holdUntil = max(holdUntil, GetTime() + AFTER_LEVEL)
    C_Timer.After(AFTER_LEVEL + 0.05, Pump)
end

ns.Listen(frame, Events, "FeatToast")
ns.Feats.OnTier(OnTier)
