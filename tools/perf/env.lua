-- env.lua: loads the real Scarlet files under Lua 5.1 with stub WoW APIs, so a script can fire
-- events through the same OnEvent closures the client calls. Nothing here is a test: a script
-- built on it measures and prints.
--
-- Clocks: GetTime and time follow a virtual clock (Env.now, advanced by Env.advance), so a
-- recorded line never depends on how fast the machine ran. debugprofilestop is a real clock
-- (os.hires when the interpreter has it, else os.clock).
local Env = {}

-- The folder this file is in, for world.lua next to it.
Env.dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./")

Env.now = 1000        -- GetTime()
Env.epoch = 1760000000 -- time() at Env.now == 0
Env.frames = {}
Env.chat = {}
Env.missing = {}      -- globals the addon read that this file does not define
Env.errors = {}       -- errors from timers and the login events
Env.timers = {}
Env.slash = nil

local floor = math.floor
local noop = function() end

-- A value for any name this file does not define: callable, indexable, nothing in it.
local Auto = setmetatable({}, {
    __index = function(t) return t end,
    __call = function() return nil end,
})

-- Frames and regions -----------------------------------------------------------------

local Frame = {}
local FrameMeta = {
    __index = function(t, k)
        local v = Frame[k]
        if v ~= nil then return v end
        return noop
    end,
}

local function NewFrame(kind, name, parent)
    local f = setmetatable({ kind = kind, name = name, parent = parent, scripts = {}, events = {},
        shown = true, text = "", w = 100, h = 20 }, FrameMeta)
    Env.frames[#Env.frames + 1] = f
    if name then _G[name] = f end
    return f
end

function Frame:SetScript(k, fn) self.scripts[k] = fn end
function Frame:GetScript(k) return self.scripts[k] end
function Frame:HookScript() end
-- Env.byEvent[event] lists the frames registered for it, kept in step with Register and Unregister.
Env.byEvent = {}
function Frame:RegisterEvent(e)
    if self.events[e] then return end
    self.events[e] = true
    local list = Env.byEvent[e]
    if not list then list = {} Env.byEvent[e] = list end
    list[#list + 1] = self
end
Frame.RegisterUnitEvent = Frame.RegisterEvent
function Frame:UnregisterEvent(e)
    if not self.events[e] then return end
    self.events[e] = nil
    local list = Env.byEvent[e]
    for i = #list, 1, -1 do
        if list[i] == self then table.remove(list, i) end
    end
end
function Frame:UnregisterAllEvents()
    for e in pairs(self.events) do self:UnregisterEvent(e) end
end
function Frame:Show()
    if not self.shown then
        self.shown = true
        if self.scripts.OnShow then self.scripts.OnShow(self) end
    end
end
function Frame:Hide()
    if self.shown then
        self.shown = false
        if self.scripts.OnHide then self.scripts.OnHide(self) end
    end
end
function Frame:SetShown(v) if v then self:Show() else self:Hide() end end
function Frame:IsShown() return self.shown end
function Frame:IsVisible() return self.shown end
function Frame:SetSize(w, h) self.w, self.h = w, h end
function Frame:SetWidth(w) self.w = w end
function Frame:SetHeight(h) self.h = h end
function Frame:GetWidth() return self.w or 0 end
function Frame:GetHeight() return self.h or 0 end
function Frame:SetVerticalScroll(v) self.vscroll = v end
function Frame:GetLeft() return 0 end
function Frame:GetTop() return 0 end
function Frame:GetCenter() return 400, 300 end
function Frame:GetEffectiveScale() return 1 end
function Frame:GetFrameLevel() return 1 end
function Frame:GetScale() return 1 end
function Frame:GetStringWidth() return 10 end
function Frame:GetNumPoints() return 0 end
function Frame:GetParent() return self.parent end
function Frame:SetText(s) self.text = s end
function Frame:GetText() return self.text end
function Frame:SetFont() return true end
function Frame:GetFont() return "Fonts\\FRIZQT__.TTF", 12, "" end
function Frame:SetFontObject() end
function Frame:SetVerticalScroll(v) self.vscroll = v end
function Frame:GetVerticalScroll() return rawget(self, "vscroll") or 0 end
function Frame:IsMouseOver() return false end
function Frame:CreateTexture() return NewFrame("Texture", nil, self) end
function Frame:CreateFontString() return NewFrame("FontString", nil, self) end
function Frame:CreateLine() return NewFrame("Line", nil, self) end
function Frame:CreateAnimationGroup() return NewFrame("AnimationGroup", nil, self) end
function Frame:CreateAnimation() return NewFrame("Animation", nil, self) end
function Frame:GetCanvas() return NewFrame("Canvas", nil, self) end

-- Timers -----------------------------------------------------------------------------

local function AddTimer(sec, fn, every)
    local t = { at = Env.now + sec, fn = fn, every = every, live = true }
    function t.Cancel() t.live = false end
    t.IsCancelled = function() return not t.live end
    Env.timers[#Env.timers + 1] = t
    return t
end

-- Moves the virtual clock forward by dt seconds, running every timer that falls due in order.
function Env.advance(dt)
    local target = Env.now + dt
    while true do
        local best, bi
        for i, t in ipairs(Env.timers) do
            if t.live and t.at <= target and (not best or t.at < best.at) then best, bi = t, i end
        end
        if not best then break end
        Env.now = math.max(Env.now, best.at)
        if best.every then
            best.at = best.at + best.every
        else
            best.live = false
            table.remove(Env.timers, bi)
        end
        -- The client reports an error in a timer and carries on; so does this.
        if Env.onTimerStart then Env.onTimerStart() end
        local t0 = Env.hires and Env.hires() or 0
        local ok, err = pcall(best.fn, best)
        if Env.onTimer then Env.onTimer(best.fn, (Env.hires and Env.hires() or 0) - t0) end
        if not ok then Env.errors[#Env.errors + 1] = "timer: " .. tostring(err) end
    end
    Env.now = target
    for i = #Env.timers, 1, -1 do
        if not Env.timers[i].live then table.remove(Env.timers, i) end
    end
end

-- Events -----------------------------------------------------------------------------

-- Calls every frame registered for event when it began, the way the client does: a handler that
-- unregisters its own frame (ADDON_LOADED does) must not make the next frame's handler skipped.
function Env.fire(event, ...)
    local list = Env.byEvent[event]
    if not list then return end
    local frames = { unpack(list) }
    for i = 1, #frames do
        local f = frames[i]
        local fn = f.scripts.OnEvent
        if fn then fn(f, event, ...) end
    end
end

-- Globals ----------------------------------------------------------------------------

local function Define(version)
    local hires = os.hires or os.clock
    _G.GetTime = function() return Env.now end
    _G.time = function() return Env.epoch + floor(Env.now) end
    _G.debugprofilestop = function() return hires() * 1000 end
    _G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    _G.tinsert, _G.tremove = table.insert, table.remove
    _G.strsplit = function(sep, s, n)
        local out, pos = {}, 1
        while true do
            local a, b = s:find(sep, pos, true)
            if not a or (n and #out >= n - 1) then out[#out + 1] = s:sub(pos) break end
            out[#out + 1] = s:sub(pos, a - 1)
            pos = b + 1
        end
        return unpack(out)
    end
    _G.CreateFrame = function(kind, name, parent) return NewFrame(kind, name, parent) end
    _G.UIParent = NewFrame("Frame", "UIParent")
    _G.Minimap = NewFrame("Frame", "Minimap")
    _G.GameTooltip = NewFrame("Frame", "GameTooltip")
    _G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) Env.chat[#Env.chat + 1] = msg end }
    _G.UISpecialFrames = {}
    _G.NUM_CHAT_WINDOWS = 10
    _G.SlashCmdList = {}
    _G.C_Timer = {
        After = function(sec, fn) AddTimer(sec, fn) end,
        NewTicker = function(sec, fn) return AddTimer(sec, fn, sec) end,
        NewTimer = function(sec, fn) return AddTimer(sec, fn) end,
    }
    _G.C_AddOns = {
        GetAddOnMetadata = function(_, field) if field == "Version" then return version end end,
        IsAddOnLoaded = function() return false end,
        DoesAddOnExist = function() return false end,
        IsAddOnLoadOnDemand = function() return false end,
        GetNumAddOns = function() return 0 end,
        GetAddOnInfo = function() return nil end,
        GetAddOnEnableState = function() return 0 end,
    }
    _G.hooksecurefunc = noop
    _G.CreateColor = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end
    -- SavedVariables start empty (false, so the addon makes a new table, as on a first run).
    _G.ScarletDB, _G.ScarletAddonsDB = false, false
    _G.C_EventUtils = { IsEventValid = function() return true end }
    _G.issecretvalue = function() return false end
    _G.GetRealmName = function() return "Realm" end
    _G.InCombatLockdown = function() return Env.inCombat or false end
    _G.IsInInstance = function() return false, "none" end
    _G.GetBuildInfo = function() return "1.15.0", "99999", "Jan 1 2026", 16001 end
    _G.GetNormalizedRealmName = function() return "Realm" end
    _G.LoggingCombat = noop
    _G.tostringall = tostring
    -- The calendar day is fixed too, so a recorded output does not change with the date it ran on.
    _G.date = function(fmt) return os.date(fmt, Env.epoch) end
    _G.max, _G.min, _G.floor, _G.abs = math.max, math.min, math.floor, math.abs
    dofile(Env.dir .. "world.lua")(Env)
    -- Any other name resolves to Auto and is listed in Env.missing.
    setmetatable(_G, { __index = function(_, k)
        Env.missing[k] = true
        return Auto
    end })
end

-- Loads Scarlet.toc's Lua files in order from dir, each with the file's own (addon, ns) arguments.
function Env.load(dir)
    -- A fresh addon each time: new frames, timers, clock and saved variables.
    Env.frames, Env.timers, Env.chat, Env.errors, Env.missing, Env.byEvent = {}, {}, {}, {}, {}, {}
    Env.now, Env.inCombat = 1000, false
    local toc = assert(io.open(dir .. "/Scarlet.toc", "rb"))
    local version = "0.0.0"
    local files = {}
    for line in toc:lines() do
        line = line:gsub("\r", "")
        local v = line:match("^## Version:%s*(.-)%s*$")
        if v then version = v end
        local f = line:match("^([%w_]+%.lua)%s*$")
        if f then files[#files + 1] = f end
    end
    toc:close()
    Define(version)
    local ns = {}
    Env.ns = ns
    Env.files = files
    Env.skipped = {}
    for _, f in ipairs(files) do
        local fh = io.open(dir .. "/" .. f, "rb")
        if fh then
            fh:close()
            local chunk, err = loadfile(dir .. "/" .. f)
            if not chunk then error(err) end
            chunk("Scarlet", ns)
        else
            Env.skipped[#Env.skipped + 1] = f
        end
    end
    Env.slash = SlashCmdList.SCARLET
    return ns
end

-- Runs the login events the addon waits for, then a second of quiet.
function Env.login()
    for _, step in ipairs({ { "ADDON_LOADED", "Scarlet" }, { "PLAYER_LOGIN" }, { "PLAYER_ENTERING_WORLD", true, false } }) do
        local ok, err = pcall(Env.fire, unpack(step))
        if not ok then Env.errors[#Env.errors + 1] = step[1] .. ": " .. tostring(err) end
    end
    Env.advance(2)
end

return Env
