-- Interface.lua: what the interface layer says about the player's session:
--   CV  a cinematic or movie: start, and end with how it ended (watched, skipped, error)
--   LL  a loading screen that was watched from its start to its end
--   LK  logout: the countdown started, the client is quitting, the logout was cancelled
--   UE  a UI error message ("Out of range", "Inventory is full"), by the client's error name
--   AO  the addons loaded, written when they change, plus the client language and a too-large
--       SavedVariables warning
--   TT  a support ticket changed state, or a report was sent (never any text)
--   UW  world state widgets (zone progress, battleground scores) when their numbers change
--   TU  a tutorial hint shown, and leaving the tutorial area
--   PP  the end-of-match screen: the map and whether you won
--   RA  archaeology digs: surveys, finds, finished sites, solved artifacts
--   RM  a raid marker you set on a unit, or a world marker you placed or removed
--   SU  what you are super-tracking (a quest, a waypoint, other content)
-- Codes are in docs/FORMAT.md. Event driven only, nothing on a timer; every client value goes
-- through Plain() before it is compared or indexed. Widget changes burst, so they are read from
-- a debounced one-shot timer started by the event. Never recorded: the text of UI errors,
-- subtitles, system messages, tickets or reports, widget tooltips, or any GUID.
local _, ns = ...

local type, pcall, pairs, ipairs = type, pcall, pairs, ipairs
local min = math.min
local concat = table.concat
local GetTime = GetTime
local Emit, Plain = ns.Emit, ns.Plain
local Round1 = ns.Round1

local UWM = C_UIWidgetManager
local SUPER = C_SuperTrack
local ADDONS = C_AddOns

local frame = CreateFrame("Frame")
local H = {}

local function Str(v)
    if Plain(v) and type(v) == "string" and v ~= "" then return v end
end

local function Num(v)
    if Plain(v) and type(v) == "number" then return v end
end

-- 1 or 0 for a plain boolean, "" for nil or a secret value.
local function Flag(v)
    if not Plain(v) then return "" end
    return v and 1 or 0
end

-- First return value of fn(...), or nil when it errors or comes back secret.
local function Call(fn, ...)
    if type(fn) ~= "function" then return end
    local ok, v = pcall(fn, ...)
    if ok and Plain(v) then return v end
end

-- Every return value of fn(...) in a table, shifted by one: r[1] is pcall's flag.
-- Index it only through Str, Num and Flag.
local function Pack(fn, ...)
    if type(fn) ~= "function" then return end
    local r = { pcall(fn, ...) }
    if r[1] then return r end
end

local function HookG(name, fn)
    if type(_G[name]) == "function" then pcall(hooksecurefunc, name, fn) end
end

-- The first n bytes of s, without a UTF-8 character cut in half (the companion reads a chunk
-- as strict UTF-8, so one bad byte would lose the whole chunk).
local function Cut(s, n)
    if #s <= n then return s end
    local c = s:sub(1, n)
    local nxt = s:byte(n + 1)
    if nxt and nxt >= 128 and nxt < 192 then c = c:gsub("[\192-\255]?[\128-\191]*$", "") end
    return c
end

-- Colour codes, textures, atlases and links out of client text.
local function Clean(v)
    local s = Str(v)
    if not s then return "" end
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("|A.-|a", "")
    s = s:gsub("|H.-|h(.-)|h", "%1"):gsub("|n", " ")
    return Cut(s, 80)
end

-- Per-character state kept in SavedVariables: ao (loaded addon name -> version) and loc (the
-- client language last written).
local function Store()
    local ch = ns.char
    if not ch then return end
    local p = ch.iface
    if type(p) ~= "table" then
        p = {}
        ch.iface = p
    end
    return p
end

local started = false

-- Cinematics and movies ------------------------------------------------------------------
-- CV 1 <kind> <id> <cancellable>: it began. kind `c` an in-engine cinematic (cancellable `0`
-- for a vehicle or scene camera), `m` a movie (id is the movie id).
-- CV 0 <kind> <id> <seconds> <how>: it ended. how `w` it ran to its end, `c` you skipped it,
-- `e` the client could not play it. Skips are seen by hooks on the cancel paths, so a skip the
-- hooks do not see reads as `w`. The skip dialog's summary text is not read.

local cv, failT

local function CvEnd()
    local c = cv
    if not c then return end
    cv = nil
    Emit("CV", 0, c.kind, c.id or "", Round1(GetTime() - c.t0), c.how or (c.cancel and "c" or "w"))
end

local function CvStart(kind, id, cancellable)
    if cv then CvEnd() end
    cv = { kind = kind, id = id, t0 = GetTime() }
    Emit("CV", 1, kind, id or "", cancellable)
end

function H.CINEMATIC_START(canBeCancelled)
    CvStart("c", nil, Flag(canBeCancelled))
end

function H.CINEMATIC_STOP()
    if cv and cv.kind == "c" then CvEnd() end
end

function H.PLAY_MOVIE(movieID)
    CvStart("m", Num(movieID), 1)
    if failT and failT == GetTime() then
        cv.how = "e"
        CvEnd()
    end
    failT = nil
end

function H.STOP_MOVIE()
    if cv and cv.kind == "m" then CvEnd() end
end

HookG("StopCinematic", function()
    if cv and cv.kind == "c" then cv.cancel = true end
end)

-- The client reports a movie's end (and whether you cancelled it or it failed) here. A movie
-- that cannot start reports its failure from inside PLAY_MOVIE, possibly before our handler has
-- opened the CV, so that failure is remembered for this frame and applied by the handler.
HookG("CinematicFinished", function(_, userCanceled, didError)
    if not cv or cv.kind ~= "m" then
        if Plain(didError) and didError == true then failT = GetTime() end
        return
    end
    if Plain(userCanceled) and userCanceled == true then cv.cancel = true end
    if Plain(didError) and didError == true then cv.how = "e" end
    CvEnd()
end)

-- Confirming the movie's skip dialog ends it without the client saying it was cancelled.
do
    local ok, button = pcall(function() return _G.MovieFrame.CloseDialog.Buttons.ConfirmButton end)
    if ok and type(button) == "table" and type(button.HookScript) == "function" then
        pcall(button.HookScript, button, "PreClick", function()
            if cv and cv.kind == "m" then cv.cancel = true end
        end)
    end
end

-- Loading screens and logout -------------------------------------------------------------
-- LL <seconds>: a loading screen watched from start to end. The one at login starts before
-- the addon loads, so it has no line.
-- LK <state>: `c` the logout countdown started, `q` the client is quitting, `x` it was cancelled.

local loadT

function H.LOADING_SCREEN_ENABLED()
    loadT = GetTime()
end

function H.LOADING_SCREEN_DISABLED()
    local t0 = loadT
    loadT = nil
    if not t0 then return end
    local secs = GetTime() - t0
    if secs > 0 and secs < 600 then Emit("LL", Round1(secs)) end
end

function H.PLAYER_CAMPING()
    Emit("LK", "c")
end

function H.PLAYER_QUITING()
    Emit("LK", "q")
end

function H.LOGOUT_CANCEL()
    Emit("LK", "x")
end

-- UI errors ------------------------------------------------------------------------------
-- UE <kind> <errorName> <errorType> <count>: the client showed a red UI error (kind `m`) or an
-- error popup (kind `p`). errorName is the client's own name for it (`ERR_OUT_OF_RANGE`), empty
-- when it has none; the message text is never read. At most one line per error per 10 seconds,
-- and count is how many there were since the last line for it. 400 lines a session.

local UE_GAP, UE_MAX = 10, 400
local ueAt, ueN, ueName, ueLines = {}, {}, {}, 0

local function UiError(kind, errorType)
    if not started then return end
    local t = Num(errorType)
    if not t then return end
    local key = kind .. t
    ueN[key] = (ueN[key] or 0) + 1
    local now = GetTime()
    if ueAt[key] and now - ueAt[key] < UE_GAP then return end
    if ueLines >= UE_MAX then return end
    ueLines = ueLines + 1
    ueAt[key] = now
    local name = ueName[t]
    if name == nil then
        local ok, n = pcall(GetGameMessageInfo, t)
        name = ok and Str(n) or false
        ueName[t] = name
    end
    local count = ueN[key]
    ueN[key] = 0
    Emit("UE", kind, name or "", t, count)
end

function H.UI_ERROR_MESSAGE(errorType)
    UiError("m", errorType)
end

function H.UI_ERROR_POPUP(errorType)
    UiError("p", errorType)
end

-- Addons ---------------------------------------------------------------------------------
-- AO <kind> <name> <version> <old>: the addons loaded in this session against what this
-- character last wrote. Kind `s` the first list for a character (a baseline), `a` an addon
-- added, `v` its version changed (old is the version before), `x` an addon gone. Blizzard's
-- own addons are left out, and a load-on-demand addon that is not loaded this session is not
-- reported gone.
-- AO c <locale>: the client language, at the first read and when it changes.
-- AO z <name>: the client said that addon's SavedVariables are too large to save.

local AO_MAX = 400
local aoLines = 0
local tooLarge

local function Ao(...)
    if aoLines >= AO_MAX then return end
    aoLines = aoLines + 1
    Emit("AO", ...)
end

local function Version(name)
    local v = Str(Call(ADDONS.GetAddOnMetadata, name, "Version"))
    return v and Cut(v, 40) or ""
end

local function ReadAddons()
    local p = Store()
    if not p or not ADDONS then return end
    local count = Num(Call(ADDONS.GetNumAddOns))
    if not count then return end
    local now, lod = {}, {}
    for i = 1, min(count, 600) do
        local r = Pack(ADDONS.GetAddOnInfo, i)
        local name, security
        if r and type(r[2]) == "table" and Plain(r[2]) then
            name, security = Str(r[2].name), Str(r[2].security)
        elseif r then
            name, security = Str(r[2]), Str(r[7])
        end
        if name and not name:find("^Blizzard_") and not (security and security:find("^SECURE")) then
            if Call(ADDONS.IsAddOnLoaded, name) == true then
                now[name] = Version(name)
            elseif Call(ADDONS.IsAddOnLoadOnDemand, name) == true then
                lod[name] = true
            end
        end
    end
    local before = p.ao
    local saved = {}
    for name, version in pairs(now) do
        saved[name] = version
        if type(before) ~= "table" then
            Ao("s", name, version, "")
        elseif before[name] == nil then
            Ao("a", name, version, "")
        elseif before[name] ~= version then
            Ao("v", name, version, before[name])
        end
    end
    if type(before) == "table" then
        for name, version in pairs(before) do
            if now[name] == nil then
                if lod[name] then
                    saved[name] = version
                else
                    Ao("x", name, "", version)
                end
            end
        end
    end
    p.ao = saved
end

local function ReadLocale()
    local p = Store()
    local loc = Str(_G.GetLocale and _G.GetLocale())
    if not p or not loc or p.loc == loc then return end
    p.loc = loc
    Ao("c", loc)
end

function H.SAVED_VARIABLES_TOO_LARGE(addOnName)
    local name = Str(addOnName)
    if not name then return end
    if started then
        Ao("z", name)
    else
        tooLarge = tooLarge or {}
        tooLarge[#tooLarge + 1] = name
    end
end

-- Tickets and reports --------------------------------------------------------------------
-- TT t <hasTicket> <tickets> <status>: your support ticket state changed (the first state of a
-- session is written only when you have a ticket). The wait message, case title and
-- description are never bound.
-- TT r <result> <reportType>: you sent a report. result is the client's SendReportResult (0
-- sent, 1 error, 2 too many, 3 to 5 it needs a chat line, voice or screenshot) and reportType
-- its ReportType (0 chat, 1 in world, 7 group member, 8 friend, 13 PvP ...). Who or what was
-- reported, and the report text, are never read.
-- TT i: you reported the player who invited you (the player is not read).

local ticketKey

function H.UPDATE_WEB_TICKET(hasTicket, numTickets, ticketStatus)
    if not started then return end
    local key = Flag(hasTicket) .. "|" .. (Num(numTickets) or "") .. "|" .. (Num(ticketStatus) or "")
    local first = ticketKey == nil
    if key == ticketKey then return end
    ticketKey = key
    if first and not (Plain(hasTicket) and hasTicket) then return end
    Emit("TT", "t", Flag(hasTicket), Num(numTickets) or "", Num(ticketStatus) or "")
end

function H.REPORT_PLAYER_RESULT(result, reportType)
    Emit("TT", "r", Num(result) or "", Num(reportType) or "")
end

function H.PLAYER_REPORT_SUBMITTED()
    Emit("TT", "i")
end

-- Tutorial and match end -----------------------------------------------------------------
-- TU t <index> <force>: a tutorial hint was triggered (the client's tutorial number), once per
-- hint per session. TU l: you left the tutorial area.
-- PP <mapID> <won>: the end-of-match screen appeared for that map, `1` for a win.

local tuSeen, tuN = {}, 0

function H.TUTORIAL_TRIGGER(tutorialIndex, forceShow)
    local i = Num(tutorialIndex)
    if not i or tuSeen[i] or tuN >= 60 then return end
    tuSeen[i] = true
    tuN = tuN + 1
    Emit("TU", "t", i, Flag(forceShow))
end

function H.LEAVING_TUTORIAL_AREA()
    Emit("TU", "l")
end

function H.SHOW_PARTY_POSE_UI(mapID, won)
    Emit("PP", Num(mapID) or "", Flag(won))
end

-- Raid markers ---------------------------------------------------------------------------
-- RM t <index> <unit>: a marker you set on a unit (index 0 when it was cleared). SetRaidTarget
-- toggles and other addons call it, so a request is only written once the client's next marker
-- update shows what the unit carries. unit is the token you used (`target`, `mouseover`, ...)
-- and empty for anything else. The unit's name is not read.
-- RM w <index>: you placed a world marker; RM x <index>: you removed one. Both are written
-- only when the client confirms the state, checked 0.5 and 8 seconds after the call (placing
-- waits for a click on the ground), so a marker placed later than that is missed.

local UNITS = { player = true, target = true, mouseover = true, focus = true, softtarget = true, pet = true,
    party1 = true, party2 = true, party3 = true, party4 = true }
local rmUnit, rmAt

function H.RAID_TARGET_UPDATE()
    local unit = rmUnit
    if not unit then return end
    rmUnit = nil
    if rmAt and GetTime() - rmAt > 2 then return end
    local ok, idx = pcall(GetRaidTargetIndex, unit)
    idx = ok and Num(idx) or 0
    Emit("RM", "t", idx, UNITS[unit] and unit or "")
end

HookG("SetRaidTarget", function(unit)
    local u = Str(unit)
    if not u then return end
    local ok, can = pcall(CanBeRaidTarget, u)
    if ok and Plain(can) and not can then return end
    rmUnit, rmAt = u, GetTime()
end)

local function WorldMarker(index, want, kind)
    local i = Num(index)
    if not i then return end
    local done = false
    local function Check()
        if done then return end
        local ok, active = pcall(IsRaidMarkerActive, i)
        if ok and Plain(active) and (active and true or false) == want then
            done = true
            Emit("RM", kind, i)
        end
    end
    -- Placing a marker waits for a click on the ground, so it is checked again later.
    C_Timer.After(0.5, Check)
    C_Timer.After(8, Check)
end

HookG("PlaceRaidMarker", function(index) WorldMarker(index, true, "w") end)
HookG("ClearRaidMarker", function(index) WorldMarker(index, false, "x") end)

-- Archaeology ----------------------------------------------------------------------------
-- RA <kind> <branch> <done> <total> <extra>: a dig. kind `s` a survey cast (done and total are
-- the finds completed and needed at the site, extra `1` when the survey found something), `f` a
-- find completed, `d` the dig site finished (branch is the client's research branch id), `a` an
-- artifact solved (extra is its name). Not yet seen in game.

function H.ARCHAEOLOGY_SURVEY_CAST(done, total, branch, success)
    Emit("RA", "s", Num(branch) or "", Num(done) or "", Num(total) or "", Flag(success))
end

function H.ARCHAEOLOGY_FIND_COMPLETE(done, total, branch)
    Emit("RA", "f", Num(branch) or "", Num(done) or "", Num(total) or "", "")
end

function H.ARTIFACT_DIGSITE_COMPLETE(branch)
    Emit("RA", "d", Num(branch) or "", "", "", "")
end

function H.RESEARCH_ARTIFACT_COMPLETE(name)
    Emit("RA", "a", "", "", "", Str(name) or "")
end

-- Super tracking -------------------------------------------------------------------------
-- SU <why> <kind> <id> <type>: what you are super-tracking. why `s` the first read of the
-- session, `c` a change. kind `q` a quest (id its questID), `w` your map waypoint, `c` other
-- tracked content (type the client's content type, id its id), `n` nothing.

local suKey

local function SuperRead(initial)
    if not SUPER then return end
    local kind, id, ctype = "n", "", ""
    if Call(SUPER.IsSuperTrackingAnything) then
        local quest = Num(Call(SUPER.GetSuperTrackedQuestID))
        if Call(SUPER.IsSuperTrackingUserWaypoint) then
            kind = "w"
        elseif quest and quest > 0 then
            kind, id = "q", quest
        else
            local r = Pack(SUPER.GetSuperTrackedContent)
            local t, cid = r and Num(r[2]), r and Num(r[3])
            if t and cid then kind, id, ctype = "c", cid, t end
        end
    end
    local key = kind .. "|" .. id .. "|" .. ctype
    if key == suKey then return end
    local first = suKey == nil
    suKey = key
    if first and not initial then return end
    Emit("SU", initial and first and "s" or "c", kind, id, ctype)
end

function H.SUPER_TRACKING_CHANGED()
    if started then SuperRead(false) end
end

-- World state widgets --------------------------------------------------------------------
-- UW <setID> <widgetID> <type> <shown> <summary>: a widget in the top centre, below-minimap,
-- objective tracker or power bar sets changed. type is the client's widget type name
-- (`StatusBar`, `DoubleStatusBar`, `CaptureBar`, `IconAndText` ...), shown `1` or `0`, and
-- summary the widget's plain text and numbers joined with `|` (colour codes, textures and
-- links removed, 80 characters a text). Timers and tooltips are not read. Widgets tied to a
-- unit are ignored. A widget is written at most once per 10 seconds and only when its summary
-- differs from the last one written; 150 widgets and 600 lines a session. A new world clears
-- what was last written, so each match or zone starts with its own lines.

local UW_GAP, UW_MAX, UW_WIDGETS = 10, 600, 150

local TYPE_NAME = {}
if type(Enum) == "table" and type(Enum.UIWidgetVisualizationType) == "table" then
    for name, v in pairs(Enum.UIWidgetVisualizationType) do
        if Num(v) then TYPE_NAME[v] = name end
    end
end

-- Written out one by one so each getter is a visible call, not a name built at runtime.
local GET = UWM and {
    IconAndText = UWM.GetIconAndTextWidgetVisualizationInfo,
    CaptureBar = UWM.GetCaptureBarWidgetVisualizationInfo,
    StatusBar = UWM.GetStatusBarWidgetVisualizationInfo,
    DoubleStatusBar = UWM.GetDoubleStatusBarWidgetVisualizationInfo,
    IconTextAndBackground = UWM.GetIconTextAndBackgroundWidgetVisualizationInfo,
    DoubleIconAndText = UWM.GetDoubleIconAndTextWidgetVisualizationInfo,
    StackedResourceTracker = UWM.GetStackedResourceTrackerWidgetVisualizationInfo,
    IconTextAndCurrencies = UWM.GetIconTextAndCurrenciesWidgetVisualizationInfo,
    TextWithState = UWM.GetTextWithStateWidgetVisualizationInfo,
    HorizontalCurrencies = UWM.GetHorizontalCurrenciesWidgetVisualizationInfo,
    BulletTextList = UWM.GetBulletTextListWidgetVisualizationInfo,
    ScenarioHeaderCurrenciesAndBackground = UWM.GetScenarioHeaderCurrenciesAndBackgroundWidgetVisualizationInfo,
    TextureAndText = UWM.GetTextureAndTextVisualizationInfo,
    SpellDisplay = UWM.GetSpellDisplayVisualizationInfo,
    DoubleStateIconRow = UWM.GetDoubleStateIconRowVisualizationInfo,
    TextureAndTextRow = UWM.GetTextureAndTextRowVisualizationInfo,
    ZoneControl = UWM.GetZoneControlVisualizationInfo,
    CaptureZone = UWM.GetCaptureZoneVisualizationInfo,
    TextureWithAnimation = UWM.GetTextureWithAnimationVisualizationInfo,
    DiscreteProgressSteps = UWM.GetDiscreteProgressStepsVisualizationInfo,
    ScenarioHeaderTimer = UWM.GetScenarioHeaderTimerWidgetVisualizationInfo,
    TextColumnRow = UWM.GetTextColumnRowVisualizationInfo,
    Spacer = UWM.GetSpacerVisualizationInfo,
    UnitPowerBar = UWM.GetUnitPowerBarWidgetVisualizationInfo,
    FillUpFrames = UWM.GetFillUpFramesWidgetVisualizationInfo,
    TextWithSubtext = UWM.GetTextWithSubtextWidgetVisualizationInfo,
    MapPinAnimation = UWM.GetMapPinAnimationWidgetVisualizationInfo,
    ItemDisplay = UWM.GetItemDisplayVisualizationInfo,
    TugOfWar = UWM.GetTugOfWarWidgetVisualizationInfo,
    ScenarioHeaderDelves = UWM.GetScenarioHeaderDelvesWidgetVisualizationInfo,
    ButtonHeader = UWM.GetButtonHeaderWidgetVisualizationInfo,
    PreyHuntProgress = UWM.GetPreyHuntProgressWidgetVisualizationInfo,
} or {}

local SETS = UWM and {
    UWM.GetTopCenterWidgetSetID,
    UWM.GetBelowMinimapWidgetSetID,
    UWM.GetObjectiveTrackerWidgetSetID,
    UWM.GetPowerBarWidgetSetID,
} or {}

local TEXT_KEYS = { "text", "headerText", "label", "leftText", "rightText", "subText", "tierText" }
local NUM_KEYS = { "barValue", "barMax", "leftBarValue", "rightBarValue", "progressVal", "numSteps",
    "currentValue", "fillValue", "numFullFrames" }

local pendSet, pendType = {}, {}
local lastKey, lastAt = {}, {}
local armed = false
local uwLines, uwWidgets = 0, 0

local function UwWrite(id, set, wtype)
    local name = TYPE_NAME[wtype]
    local get = name and GET[name]
    if not get then return end
    local ok, info = pcall(get, id)
    if not ok or type(info) ~= "table" or not Plain(info) then return end
    if Str(info.unitToken) or Str(info.unit) then return end
    local state = Num(info.shownState) or Num(info.state)
    local shown = state == nil and 1 or (state ~= 0 and 1 or 0)
    local parts = {}
    for _, k in ipairs(TEXT_KEYS) do
        local s = Clean(info[k])
        if s ~= "" then parts[#parts + 1] = s end
    end
    for _, k in ipairs(NUM_KEYS) do
        local n = Num(info[k])
        if n then parts[#parts + 1] = k .. "=" .. ns.Field(n) end
    end
    local summary = concat(parts, "|")
    local key = shown .. "#" .. summary
    if lastKey[id] == key then return end
    if lastKey[id] == nil then
        if shown == 0 or uwWidgets >= UW_WIDGETS then return end
        uwWidgets = uwWidgets + 1
    end
    if uwLines >= UW_MAX then return end
    uwLines = uwLines + 1
    lastKey[id], lastAt[id] = key, GetTime()
    Emit("UW", set or "", id, name, shown, summary)
end

local Arm

local function Flush()
    armed = false
    local now = GetTime()
    local wait
    for id, wtype in pairs(pendType) do
        local gap = lastAt[id] and (UW_GAP - (now - lastAt[id])) or 0
        if gap > 0 then
            wait = wait and min(wait, gap) or gap
        else
            local set = pendSet[id]
            pendType[id], pendSet[id] = nil, nil
            UwWrite(id, set, wtype)
        end
    end
    if wait then Arm(wait + 0.1) end
end

Arm = function(delay)
    if armed then return end
    armed = true
    C_Timer.After(delay, Flush)
end

local function Queue(id, set, wtype)
    if not id or not wtype then return end
    if lastKey[id] == nil and uwWidgets >= UW_WIDGETS then return end
    pendSet[id], pendType[id] = set or false, wtype
end

function H.UPDATE_UI_WIDGET(info)
    if not started or type(info) ~= "table" or not Plain(info) then return end
    if Str(info.unitToken) or Str(info.unit) then return end
    Queue(Num(info.widgetID), Num(info.widgetSetID), Num(info.widgetType))
    Arm(2)
end

local scanQueued = false

local function Scan()
    scanQueued = false
    if not UWM then return end
    for _, getSet in ipairs(SETS) do
        local setID = Num(Call(getSet))
        local list = setID and Call(UWM.GetAllWidgetsBySetID, setID)
        if type(list) == "table" then
            for i = 1, min(#list, 60) do
                local w = list[i]
                if type(w) == "table" and Plain(w) and not Str(w.unitToken) and not Str(w.unit) then
                    Queue(Num(w.widgetID), setID, Num(w.widgetType))
                end
            end
        end
    end
    Arm(1)
end

function H.UPDATE_ALL_UI_WIDGETS()
    if not started or scanQueued then return end
    scanQueued = true
    C_Timer.After(2, Scan)
end

-- Addon restrictions and blocked actions ---------------------------------------------------
-- AX <type> <state>: the client restricts what addons can read (a boss encounter, a keystone run,
-- a PvP match, some maps, chat), which is why some fields elsewhere are `?`. type is the client's
-- AddOnRestrictionType (1 encounter, 2 challenge mode, 3 PvP match, 4 map, 5 chat; combat, 0, is
-- the `F` line and not written). state: 1 about to become active, 0 inactive, 2 active. One line
-- per change of state per type, 300 a session.
-- AF <kind> <addon> <function> <count>: an addon's call was blocked (kind b) or forbidden (f) by
-- the client. Only the two names are kept, never the error text. Written for the first block of
-- an addon and function in a session and again when its count reaches 2, 4, 8, ...; 100
-- addon-and-function pairs a session.

local AX_SESSION_CAP, AF_PAIR_CAP = 300, 100
local axLast, axN = {}, 0
local afCount, afPairs = {}, 0

function H.ADDON_RESTRICTION_STATE_CHANGED(restriction, state)
    local t, s = Num(restriction), Num(state)
    if not t or not s or t == 0 or axLast[t] == s or axN >= AX_SESSION_CAP then return end
    axLast[t], axN = s, axN + 1
    Emit("AX", t, s)
end

local function IsPowerOfTwo(n)
    while n > 1 and n % 2 == 0 do n = n / 2 end
    return n == 1
end

local function Blocked(kind)
    return function(addon, fn)
        local a, f = Str(addon) or "", Str(fn) or ""
        local key = kind .. "\t" .. a .. "\t" .. f
        local n = afCount[key]
        if not n then
            if afPairs >= AF_PAIR_CAP then return end
            afPairs, n = afPairs + 1, 0
        end
        n = n + 1
        afCount[key] = n
        if IsPowerOfTwo(n) then Emit("AF", kind, a, f, n) end
    end
end

H.ADDON_ACTION_BLOCKED = Blocked("b")
H.ADDON_ACTION_FORBIDDEN = Blocked("f")

-- Lifecycle ------------------------------------------------------------------------------

local entered = false
function H.PLAYER_ENTERING_WORLD()
    for id in pairs(lastKey) do lastKey[id], lastAt[id] = nil, nil end
    uwWidgets = 0
    if entered then
        if started and not scanQueued then
            scanQueued = true
            C_Timer.After(3, Scan)
        end
        return
    end
    entered = true
    -- Addon lists and widgets settle over the first seconds of a session.
    C_Timer.After(10, function()
        started = true
        ReadLocale()
        ReadAddons()
        if tooLarge then
            for i = 1, min(#tooLarge, 10) do Ao("z", tooLarge[i]) end
            tooLarge = nil
        end
        SuperRead(true)
        Scan()
    end)
end

ns.Listen(frame, H)
