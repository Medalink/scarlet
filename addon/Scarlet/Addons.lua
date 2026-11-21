-- Addons.lua: lines recorded from other installed addons, kept apart from the main recording.
-- They live in their own SavedVariables table (ScarletAddonsDB) with their own chunks. Nothing here
-- calls ns.Emit or touches ScarletDB.chunks or ScarletDB.buf. The line format and every integration's
-- codes are in docs/ADDONS.md; keep the two in step.
--
-- Each integration is one row of REGISTRY. It starts when its addon is loaded and its flag in
-- ScarletAddonsDB.opt is not false. Turning a flag off stops its lines at once and keeps what it wrote.
-- Integrations read the other addon through what it offers (a message bus, a callback, a saved
-- table) or a post-hook on one of its functions; they never replace another addon's function.
local ADDON, ns = ...

local floor, select, type, tostring, concat, wipe, pcall = math.floor, select, type, tostring, table.concat, wipe, pcall
local GetTime, time = GetTime, time
local issecretvalue = issecretvalue or function(_) return false end

local FORMAT_VERSION = 1
local CHUNK_LINES = 500          -- seal after this many lines, once out of combat
local HARD_LINES = 2000          -- seal even in combat past this many
local BUDGET_BYTES = 2000000     -- oldest chunks are dropped past this much payload
local START_DELAY = 1            -- seconds after login or an addon loading before its integration starts
local RETRY_SECONDS, RETRIES = 2, 5
local LINES_PER_CHECK = 50      -- most step lines one Attune check can write

local A = { lines = {} }
ns.Addons = A

-- Client and third-party values ---------------------------------------------------------

local function Num(v)
    if issecretvalue(v) or type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then return nil end
    return v
end

local function Int(v)
    local n = Num(v)
    return n and floor(n + 0.5) or nil
end

local function Str(v)
    if issecretvalue(v) or type(v) ~= "string" then return nil end
    return v
end

-- A guide or step id that is a string or a number.
local function Id(v) return Str(v) or Int(v) end

-- A map coordinate (0 to 1) as an integer times 10000.
local function Coord(v)
    local n = Num(v)
    return n and floor(n * 10000 + 0.5) or nil
end

local function Tab(v)
    if issecretvalue(v) or type(v) ~= "table" then return nil end
    return v
end

-- Calls fn, dropping any error: a failing integration must not break the other addon's call.
local function Safe(fn)
    return function(...)
        pcall(fn, ...)
    end
end

local function Hook(target, name, fn)
    hooksecurefunc(target, name, Safe(fn))
end

-- The stream ---------------------------------------------------------------------------

local db, chunks
local buf, bufN = {}, 0
local parts = {}
local chunkT, lastG
local pendingSeal = false

local function Prune()
    local total = 0
    for i = 1, #chunks do total = total + #chunks[i].z end
    local drop = 0
    while total > BUDGET_BYTES and drop < #chunks - 1 do
        drop = drop + 1
        total = total - #chunks[drop].z
    end
    if drop > 0 then
        db.gaps = db.gaps or {}
        db.gaps[#db.gaps + 1] = { from = chunks[1].q, to = chunks[drop].q, at = time() }
        for _ = 1, drop do table.remove(chunks, 1) end
    end
end

local function Seal(force)
    if bufN == 0 or not db then return end
    if not force and InCombatLockdown() and bufN < HARD_LINES then
        pendingSeal = true
        return
    end
    pendingSeal = false
    local enc, z = ns.Encode(concat(buf, "\n", 1, bufN))
    db.seq = db.seq + 1
    chunks[#chunks + 1] = { q = db.seq, c = ns.charKey or "?", s = ns.session or 0, t = chunkT, n = bufN, e = enc, z = z }
    wipe(buf)
    bufN, chunkT = 0, nil
    db.bufT, db.bufC, db.bufS = nil, nil, nil
    Prune()
end

local function InitDB()
    local saved = _G.ScarletAddonsDB
    saved = type(saved) == "table" and saved or {}
    _G.ScarletAddonsDB = saved
    db = saved
    db.v = FORMAT_VERSION
    db.seq = db.seq or 0
    db.chunks = db.chunks or {}
    db.opt = db.opt or {}
    chunks = db.chunks
    -- A buffer left by the last session (reload, disconnect, an error at logout) becomes a chunk
    -- with its own start time and character. r = 1 marks it recovered.
    if type(db.buf) == "table" and #db.buf > 0 and db.bufT then
        local enc, z = ns.Encode(concat(db.buf, "\n", 1, #db.buf))
        db.seq = db.seq + 1
        chunks[#chunks + 1] = { q = db.seq, c = db.bufC or "?", s = db.bufS or 0, t = db.bufT, n = #db.buf,
            e = enc, z = z, r = 1 }
        Prune()
    end
    db.buf = buf
    db.bufT, db.bufC, db.bufS = nil, nil, nil
end

-- One line: <dt> <key> <code> <fields>. dt is centiseconds since the previous addon line.
local function Write(key, code, ...)
    local now = GetTime()
    if not chunkT then
        chunkT, lastG = time(), now
        db.bufT, db.bufC, db.bufS = chunkT, ns.charKey or "?", ns.session or 0
    end
    local dt = floor((now - lastG) * 100 + 0.5)
    if dt < 0 then dt = 0 end
    lastG = lastG + dt / 100
    parts[1], parts[2], parts[3] = dt, key, code
    local n = select("#", ...)
    for i = 1, n do parts[i + 3] = ns.Field((select(i, ...))) end
    bufN = bufN + 1
    buf[bufN] = concat(parts, "\t", 1, n + 3)
    if bufN >= CHUNK_LINES then Seal() end
end

local function IsOn(key)
    return db ~= nil and db.opt[key] ~= false
end

local function Emit(key, code, ...)
    if not db or ns.opt.paused or db.opt[key] == false then return end
    Write(key, code, ...)
    A.lines[key] = (A.lines[key] or 0) + 1
end

-- Integrations -------------------------------------------------------------------------
-- Each start function gets emit(code, ...) and returns true once it is in place, or false when
-- the other addon is not ready yet (the registry tries again). Hooks cannot be removed, so an
-- integration that hooks keeps the hook and relies on emit going quiet when its flag is off.

local hooked = {}

-- GatherMate2: a node added to its map.
local function StartGatherMate(emit)
    local stub = _G.LibStub
    local ace = stub and stub("AceAddon-3.0", true)
    local gm = ace and ace:GetAddon("GatherMate2", true)
    if type(gm) ~= "table" or type(gm.AddNode) ~= "function" then return false end
    if hooked.gm then return true end
    hooked.gm = true
    Hook(gm, "AddNode", function(_, zone, x, y, nodeType, name)
        local kind, label = Str(nodeType), Str(name)
        if not kind or not label then return end
        local locks = gm.db and gm.db.profile and Tab(gm.db.profile.dbLocks)
        if locks and locks[kind] then return end -- the node was not stored
        emit("N", Int(zone), Coord(x), Coord(y), kind, label)
    end)
    return true
end

-- The Fishing Log: a catch, through the addon's own message bus.
local function StartFishingLog(emit)
    local mf = _G.TheFishingLog
    if type(mf) ~= "table" or type(mf.On) ~= "function" then return false end
    if hooked.fl then return true end
    hooked.fl = true
    mf:On("TFL_CATCH", Safe(function(_, c)
        c = Tab(c)
        if not c or c.test then return end
        local spot = Tab(c.spot) or {}
        local weight = Num(c.weight)
        local flags = (c.specimen and "s" or "") .. (c.junk and "j" or "") .. (c.frenzy and "f" or "")
            .. (c.best and "b" or "")
        emit("C", Int(c.itemID), weight and floor(weight * 100 + 0.5) / 100 or nil, flags, Str(c.zone),
            Str(spot.name), Int(spot.mapID), Coord(spot.x), Coord(spot.y))
    end))
    return true
end

-- Forever Fishing: the items a cast's loot window added to its catch record.
local function StartForeverFishing(emit)
    local ff = _G.ForeverFishing
    if type(ff) ~= "table" or type(ff.ShowCatchRecap) ~= "function" then return false end
    if hooked.ff then return true end
    hooked.ff = true
    Hook(ff, "ShowCatchRecap", function(_, updates, cast)
        updates = Tab(updates)
        if not updates then return end
        local place = Tab(cast) and Str(cast.location) or nil
        for i = 1, #updates do
            local u = Tab(updates[i])
            if u and Int(u.id) and Int(u.amount) then emit("C", Int(u.id), Int(u.amount), place) end
        end
    end)
    return true
end

-- Polestar: the guide you follow, through its message bus.
local polestar = { handles = {} }

local function StartPolestar(emit)
    local ps = _G.Polestar
    if type(ps) ~= "table" or type(ps.On) ~= "function" or type(ps.Off) ~= "function" then return false end
    if #polestar.handles > 0 then return true end
    local guide, step
    local function On(msg, fn)
        polestar.handles[#polestar.handles + 1] = ps.On(msg, Safe(fn))
    end
    On("GUIDE_CHANGED", function(id)
        id = Id(id)
        if not id or id == guide then return end
        guide, step = id, nil
        emit("G", id)
    end)
    On("STEP_CHANGED", function(current)
        current = Int(current)
        if not guide or not current or current == step then return end
        step = current
        emit("S", guide, current)
    end)
    On("GUIDE_COMPLETED", function(id)
        id = Id(id)
        if id then emit("D", id) end
    end)
    On("STEP_SKIPPED", function(from, to)
        if guide then emit("K", guide, Int(from), Int(to)) end
    end)
    On("ROUTE_CHOSEN", function(from, to)
        local a, b = Id(from), Id(to)
        if a or b then emit("R", a, b) end
    end)
    return true
end

local function StopPolestar()
    local ps = _G.Polestar
    if type(ps) == "table" and type(ps.Off) == "function" then
        for _, h in ipairs(polestar.handles) do pcall(ps.Off, h) end
    end
    wipe(polestar.handles)
end

-- Profession Shopping List: a recipe added to or removed from its tracked list.
local PSL_EVENT = "ProfessionShoppingList.OnTrackedRecipesChanged"
local pslOwner = {}
local pslOn = false

local function StartShoppingList(emit)
    local reg = _G.EventRegistry
    if type(reg) ~= "table" or type(reg.RegisterCallback) ~= "function" then return false end
    if pslOn then return true end
    pslOn = true
    reg:RegisterCallback(PSL_EVENT, Safe(function(_, recipeID, quantity)
        emit("T", Int(recipeID), Int(quantity))
    end), pslOwner)
    return true
end

local function StopShoppingList()
    local reg = _G.EventRegistry
    if pslOn and type(reg) == "table" and type(reg.UnregisterCallback) == "function" then
        pcall(reg.UnregisterCallback, reg, PSL_EVENT, pslOwner)
    end
    pslOn = false
end

-- Attune: steps done and the percent of each attunement, read from its saved table when it
-- finishes a progress check.
local function AttuneToon()
    local data = Tab(_G.Attune_DB)
    local toons = data and Tab(data.toons)
    if not toons then return nil end
    local name, extra = UnitName("player")
    name, extra = Str(name), Str(extra)
    if not name then return nil end
    return Tab(toons[(extra and extra ~= "") and (name .. " " .. extra) or name])
end

local function AttuneName(attuneId)
    local data = Tab(_G.Attune_Data)
    local byId = data and Tab(data.attuneById)
    local a = byId and Tab(byId[attuneId])
    return a and Str(a.NAME) or nil
end

local function StartAttune(emit)
    if type(_G.Attune_SendPushInfo) ~= "function" then return false end
    local toon = AttuneToon()
    if not toon or type(toon.done) ~= "table" or type(toon.attuned) ~= "table" then return false end
    if hooked.at then return true end
    hooked.at = true
    local seen, percent = {}, {}
    local function Take(t)
        wipe(seen)
        wipe(percent)
        for key in pairs(t.done) do seen[key] = true end
        for id, value in pairs(t.attuned) do percent[id] = value end
    end
    Take(toon)
    local off = false
    hooksecurefunc("Attune_SendPushInfo", Safe(function(step)
        if not IsOn("at") then
            off = true
            return
        end
        if Str(step) ~= "OVER" then return end
        local t = AttuneToon()
        if not t or type(t.done) ~= "table" or type(t.attuned) ~= "table" then return end
        -- Progress made while the flag was off is not written once it is back on.
        if off then
            off = false
            Take(t)
            return
        end
        local written = 0
        for key in pairs(t.done) do
            if not seen[key] then
                seen[key] = true
                local a, s = tostring(key):match("^(%d+)%-(%d+)$")
                if a and written < LINES_PER_CHECK then
                    written = written + 1
                    emit("S", tonumber(a), tonumber(s))
                end
            end
        end
        for id, value in pairs(t.attuned) do
            if percent[id] ~= value then
                percent[id] = value
                local n = Num(value)
                if n and written < LINES_PER_CHECK then
                    written = written + 1
                    emit("P", Id(id), floor(n + 0.5), AttuneName(id))
                end
            end
        end
    end))
    return true
end

-- AutoLayer: a layer request you sent, and someone who asked for a layer joining your group.
local function LayeredCount(al)
    local ok, n = pcall(function() return al.db.profile.layered end)
    return ok and Int(n) or nil
end

local function StartAutoLayer(emit)
    local al = _G.AutoLayer
    if type(al) ~= "table" or type(al.SendLayerRequest) ~= "function" or type(al.ProcessSystemMessages) ~= "function"
        or not LayeredCount(al) then
        return false
    end
    if hooked.al then return true end
    hooked.al = true
    local last = LayeredCount(al)
    Hook(al, "SendLayerRequest", function() emit("R") end)
    -- The system message's text is never read; the addon's own lifetime counter says it counted one.
    Hook(al, "ProcessSystemMessages", function()
        if not IsOn("al") then return end
        local now = LayeredCount(al)
        if now and last and now > last then emit("J", now) end
        last = now or last
    end)
    return true
end

-- The registry -------------------------------------------------------------------------

local REGISTRY = {
    { key = "gm", folder = "GatherMate2", label = "GatherMate2", start = StartGatherMate },
    { key = "fl", folder = "TheFishingLog", label = "The Fishing Log", start = StartFishingLog },
    { key = "ff", folder = "ForeverFishing", label = "Forever Fishing", start = StartForeverFishing },
    { key = "ps", folder = "Polestar", label = "Polestar", start = StartPolestar, stop = StopPolestar },
    { key = "pl", folder = "ProfessionShoppingList", label = "Profession Shopping List",
        start = StartShoppingList, stop = StopShoppingList },
    { key = "at", folder = "Attune", label = "Attune", start = StartAttune },
    { key = "al", folder = "AutoLayer", label = "AutoLayer", start = StartAutoLayer },
}
A.REGISTRY = REGISTRY

for _, e in ipairs(REGISTRY) do
    local key = e.key
    e.emit = function(code, ...) return Emit(key, code, ...) end
end

local loggedIn = false

local function Installed(e) return C_AddOns.DoesAddOnExist(e.folder) and true or false end
local function Loaded(e) return C_AddOns.IsAddOnLoaded(e.folder) and true or false end

local function TryStart(e, attempt)
    if e.started or not loggedIn or not IsOn(e.key) or not Loaded(e) then return end
    local ok, done = pcall(e.start, e.emit)
    if ok and done then
        e.started = true
    elseif attempt < RETRIES then
        C_Timer.After(RETRY_SECONDS, function() TryStart(e, attempt + 1) end)
    end
end

-- Whether the flag is on, for the page.
function A.IsOn(key) return IsOn(key) end

-- Turning a flag off ends the integration's lines now; turning it on starts it again.
function A.SetOn(key, on)
    if not db then return end
    db.opt[key] = on and true or false
    for _, e in ipairs(REGISTRY) do
        if e.key == key then
            if on then
                TryStart(e, 1)
            elseif e.stop and e.started then
                pcall(e.stop)
                e.started = false
            end
        end
    end
end

-- One row per integration: label, installed, loaded, on and the lines written this session.
function A.Rows(out)
    wipe(out)
    for i, e in ipairs(REGISTRY) do
        local row = out[i] or {}
        out[i] = row
        row.key, row.label = e.key, e.label
        row.installed, row.loaded = Installed(e), Loaded(e)
        row.on, row.lines = IsOn(e.key), A.lines[e.key] or 0
    end
    return out
end

function A.Pending()
    return bufN
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:SetScript("OnEvent", function(_, event, name)
    if event == "ADDON_LOADED" then
        if name == ADDON then
            InitDB()
        elseif loggedIn and db and Str(name) then
            for _, e in ipairs(REGISTRY) do
                if e.folder == name then C_Timer.After(START_DELAY, function() TryStart(e, 1) end) end
            end
        end
    elseif event == "PLAYER_LOGIN" then
        loggedIn = true
        -- After Scarlet's own login handler has set the character, and the other addons have enabled.
        C_Timer.After(START_DELAY, function()
            for _, e in ipairs(REGISTRY) do TryStart(e, 1) end
        end)
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingSeal then Seal() end
    elseif event == "PLAYER_LOGOUT" then
        Seal(true)
    end
end)
