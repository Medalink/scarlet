-- UI.lua: the Scarlet window. Built on first open, refreshed only while shown.
local _, ns = ...

local floor, format, max = math.floor, string.format, math.max

-- The palette of the Scarlet site: a dark survey sheet. Hairlines are white at low alpha
-- (the fourth value); scarlet marks the current page, recorded data and the main action.
local T = {
    win = { 0x10 / 255, 0x10 / 255, 0x12 / 255 },
    bg = { 0x14 / 255, 0x14 / 255, 0x16 / 255 },
    panel = { 0x1b / 255, 0x1b / 255, 0x1f / 255 },
    card = { 0x23 / 255, 0x23 / 255, 0x28 / 255 },
    line = { 1, 1, 1, 0.07 },
    line2 = { 1, 1, 1, 0.13 },
    fg = { 0xf0 / 255, 0xf1 / 255, 0xf3 / 255 },
    text = { 0xcd / 255, 0xce / 255, 0xd4 / 255 },
    muted = { 0x8a / 255, 0x8a / 255, 0x93 / 255 },
    grey = { 1, 1, 1, 0.1 },
    accent = { 0xff / 255, 0x2d / 255, 0x55 / 255 },
    accentSoft = { 0xff / 255, 0x6b / 255, 0x8e / 255 },
    accentDeep = { 0xc0 / 255, 0x10 / 255, 0x2e / 255 },
    ink = { 0x14 / 255, 0x14 / 255, 0x16 / 255 },
}

local WHITE = "Interface\\Buttons\\WHITE8X8"
local W, H = 880, 560
local HEADER_H, SIDEBAR_W, NAV_H, PAD = 40, 176, 30, 24
local CONTENT_W = W - SIDEBAR_W - 1 - 2 * PAD
local TITLE_H = 46 -- page title and the gap under it; the Character page has none
local CELL_COLS, CELL_H = 4, 84
local STRIDE_YARDS = 2.5      -- running stride
local WALK_STRIDE_YARDS = 1.4 -- walking stride
local REFRESH_SECONDS = 0.5

local window, pages, navButtons, current, refreshTicker

-- Fonts ------------------------------------------------------------------------
-- The choices are Sofia Sans (bundled in Media, the default), the game's own fonts and
-- every font other addons registered with LibSharedMedia (EllesmereUI and SharedMedia
-- bring Expressway and more). opt.font holds a name; nil means Sofia Sans.
-- Sofia Sans is three static files, one per role: display (headings and big numbers),
-- body and strong. Any other chosen font is used for every role.

local MEDIA = "Interface\\AddOns\\Scarlet\\Media\\"
local FACES = {
    display = MEDIA .. "SofiaSansExtraCondensed-ExtraBold.ttf",
    body = MEDIA .. "SofiaSans-Regular.ttf",
    strong = MEDIA .. "SofiaSans-SemiBold.ttf",
}
local BUILTIN_FONTS = {
    { "Sofia Sans", FACES.body },
    { "Arial Narrow", "Fonts\\ARIALN.TTF" },
    { "Friz Quadrata", "Fonts\\FRIZQT__.TTF" },
    { "Morpheus", "Fonts\\MORPHEUS.TTF" },
    { "Skurri", "Fonts\\SKURRI.TTF" },
}
local DEFAULT_FONT, FALLBACK_FONT = "Sofia Sans", "Arial Narrow"
local fontList, fontPaths = {}, {}
local broken = {} -- file -> true for a font this client draws nothing with (see CheckFonts)
local followers = {} -- font string -> { size, role }, for every string that follows the chosen font

local function SharedMedia()
    local stub = _G.LibStub
    return stub and stub("LibSharedMedia-3.0", true)
end

local function FileKey(path)
    return (path:lower():gsub("/", "\\"))
end

local function ListFonts()
    wipe(fontList)
    wipe(fontPaths)
    local seen = {}
    local function Add(name, path)
        if type(name) ~= "string" or type(path) ~= "string" or fontPaths[name] then return end
        local file = FileKey(path)
        if seen[file] or broken[file] then return end
        seen[file] = true
        fontPaths[name] = path
        fontList[#fontList + 1] = name
    end
    for _, f in ipairs(BUILTIN_FONTS) do Add(f[1], f[2]) end
    local lsm = SharedMedia()
    if lsm then
        for name, path in pairs(lsm:HashTable("font")) do Add(name, path) end
    end
    table.sort(fontList, function(a, b) return a:lower() < b:lower() end)
    return fontList
end

-- The chosen name and its file. A chosen font that is not registered (its
-- addon is off) falls back without forgetting the choice.
local function ChosenFont()
    if not next(fontPaths) then ListFonts() end
    local name = ns.opt and ns.opt.font
    if not (name and fontPaths[name]) then
        name = fontPaths[DEFAULT_FONT] and DEFAULT_FONT or FALLBACK_FONT
    end
    return name, fontPaths[name]
end

-- SetFont fails on a file the client cannot load; the string then takes the
-- game's normal font so SetText never runs on a string without one.
local function SetFontSafe(fs, path, size)
    if not (path and fs:SetFont(path, size, "")) then
        fs:SetFont((GameFontNormal:GetFont()), size, "")
    end
end

-- The file a role draws with: Sofia Sans picks its own face per role.
local function FacePath(role)
    local name, path = ChosenFont()
    if name == DEFAULT_FONT then return FACES[role] or path end
    return path
end

-- Display sizes are set for the extra condensed face; a wider font gets them smaller so
-- a big number does not clip.
local function FaceSize(role, size)
    if role == "display" and ChosenFont() ~= DEFAULT_FONT then return floor(size * 0.68) end
    return size
end

local function ApplyFont()
    for fs, def in pairs(followers) do SetFontSafe(fs, FacePath(def[2]), FaceSize(def[2], def[1])) end
end

local function Relist()
    ListFonts()
    ApplyFont()
    if window and window:IsShown() and current == "fonts" then pages.fonts:Refresh() end
end

-- An addon can register a font whose file this client does not have (LibSharedMedia lists
-- the retail CJK fonts). SetFont still takes it and the text draws nothing, so a font that
-- measures no width twice, a second apart, leaves the list; a chosen one falls back.
local probe, checking
local function Draws(path)
    if not probe then
        probe = UIParent:CreateFontString(nil, "BACKGROUND")
        probe:SetAlpha(0)
    end
    if not probe:SetFont(path, 16, "") then return false end
    probe:SetText("Scarlet 0123")
    return probe:GetStringWidth() > 0
end

local function CheckFonts()
    if checking then return end
    local suspect = {}
    for _, name in ipairs(fontList) do
        local path = fontPaths[name]
        if not Draws(path) then suspect[#suspect + 1] = path end
    end
    if #suspect == 0 then return end
    checking = true
    C_Timer.After(1, function()
        checking = nil
        local dropped
        for _, path in ipairs(suspect) do
            if not Draws(path) then
                broken[FileKey(path)] = true
                dropped = true
            end
        end
        if dropped then Relist() end
    end)
end

-- Fonts registered after login (an addon loaded on demand) join the list.
local fontRelist
local function WatchFonts()
    ListFonts()
    CheckFonts()
    local lsm = SharedMedia()
    if not lsm or ns.fontWatch then return end
    ns.fontWatch = true
    lsm.RegisterCallback(ns, "LibSharedMedia_Registered", function(_, mediatype)
        if mediatype ~= "font" or fontRelist then return end
        fontRelist = true
        C_Timer.After(0.5, function()
            fontRelist = nil
            Relist()
            CheckFonts()
        end)
    end)
end

-- Primitives -------------------------------------------------------------------

local function Fill(parent, color, alpha, layer, sub)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND", nil, sub)
    t:SetTexture(WHITE)
    t:SetVertexColor(color[1], color[2], color[3], alpha or color[4] or 1)
    return t
end

-- A one-pixel line along one edge of f ("TOP", "BOTTOM", "LEFT" or "RIGHT").
local function Hair(f, edge, color, layer)
    local t = Fill(f, color or T.line, nil, layer or "ARTWORK")
    if edge == "TOP" or edge == "BOTTOM" then
        t:SetPoint(edge .. "LEFT")
        t:SetPoint(edge .. "RIGHT")
        t:SetHeight(1)
    else
        t:SetPoint("TOP" .. edge)
        t:SetPoint("BOTTOM" .. edge)
        t:SetWidth(1)
    end
    return t
end

local function Border(f, color, alpha)
    local function Edge(a1, a2, w, h)
        local t = Fill(f, color, alpha, "BORDER")
        t:SetPoint(a1)
        t:SetPoint(a2)
        if w then t:SetWidth(w) else t:SetHeight(h) end
    end
    Edge("TOPLEFT", "TOPRIGHT", nil, 1)
    Edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
    Edge("TOPLEFT", "BOTTOMLEFT", 1)
    Edge("TOPRIGHT", "BOTTOMRIGHT", 1)
end

-- role: "body" (default), "strong" or "display"; see FACES.
local function Text(parent, size, color, justify, role)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    role = role or "body"
    SetFontSafe(fs, FacePath(role), FaceSize(role, size))
    followers[fs] = { size, role }
    fs:SetTextColor(color[1], color[2], color[3])
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(false)
    return fs
end

-- Formatting -------------------------------------------------------------------

local function Num(n)
    n = floor(n + 0.5)
    local s = tostring(n)
    local left, digits = s:match("^(-?)(%d+)$")
    if not digits then return s end
    return left .. digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end

local function Money(copper)
    copper = floor(copper)
    local g, s, c = floor(copper / 10000), floor(copper / 100) % 100, copper % 100
    if g > 0 then return format("%s|cffd9b25fg|r %d|cffc3c7cfs|r", Num(g), s) end
    if s > 0 then return format("%d|cffc3c7cfs|r %d|cffc58a63c|r", s, c) end
    return format("%d|cffc58a63c|r", c)
end

local function Duration(secs)
    secs = floor(secs)
    local h, m = floor(secs / 3600), floor(secs / 60) % 60
    if h > 0 then return format("%dh %dm", h, m) end
    if m > 0 then return format("%dm %ds", m, secs % 60) end
    return format("%ds", secs)
end

local function Distance(yards)
    if yards < 1760 then return Num(yards) .. " yd" end
    return format("%.1f mi", yards / 1760)
end

-- What Overview.lua draws with.
ns.UI = { T = T, Fill = Fill, Border = Border, Hair = Hair, Text = Text, Num = Num, Money = Money,
    Duration = Duration }

local CARDS = {
    { "Kills", function(s) return Num(s.kills) end },
    { "Killing blows", function(s) return Num(s.blows) end },
    { "Casts", function(s) return Num(s.casts) end },
    { "Steps", function(s) return Num(s.foot / STRIDE_YARDS + s.walk / WALK_STRIDE_YARDS) end },
    { "Distance", function(s) return Distance(s.foot + s.walk + s.mount + s.swim + s.fly) end },
    { "Jumps", function(s) return Num(s.jumps) end },
    { "Deaths", function(s) return Num(s.deaths) end },
    { "Time in combat", function(s) return Duration(s.combat) end },
    { "Dungeons", function(s) return Num(s.dungeons) end },
    { "Bosses", function(s) return Num(s.bosses) end },
    { "Quests", function(s) return Num(s.quests) end },
    { "Items looted", function(s) return Num(s.loot) end },
    { "Experience", function(s) return Num(s.xp) end },
    { "Gold earned", function(s) return Money(s.earned) end },
    { "Gold spent", function(s) return Money(s.spent) end },
    { "Time recorded", function(s) return Duration(s.tracked) end },
    { "Camps", function(s) return Num(s.camps) end },
    { "Time at camp", function(s) return Duration(s.camptime) end },
    { "Buffs gained", function(s) return Num(s.buffs) end },
    { "Items sold", function(s) return Num(s.sold) end },
}

local TIME_CARDS = {
    { "Running", function(s) return Duration(s.footTime) end },
    { "Walking", function(s) return Duration(s.walkTime) end },
    { "Mounted", function(s) return Duration(s.mountTime) end },
    { "Standing still", function(s) return Duration(s.stillTime) end },
    { "Swimming", function(s) return Duration(s.swimTime) end },
    { "Flying", function(s) return Duration(s.flyTime) end },
    { "Flight paths", function(s) return Duration(s.taxiTime) end },
    { "At camp", function(s) return Duration(s.camptime) end },
    { "In combat", function(s) return Duration(s.combat) end },
    { "Out of combat", function(s) return Duration(max(0, s.tracked - s.combat)) end },
    { "Rested", function(s) return Duration(s.restedTime) end },
    { "Not rested", function(s) return Duration(s.unrestedTime) end },
    { "AFK", function(s) return Duration(s.afkTime) end },
    { "Casting", function(s) return Duration(s.castTime) end },
    { "Solo", function(s) return Duration(s.soloTime) end },
    { "In a group", function(s) return Duration(s.groupTime) end },
}

local MORE_CARDS = {
    { "Damage done", function(s) return Num(s.damage) end },
    { "Healing done", function(s) return Num(s.healing) end },
    { "Damage taken", function(s) return Num(s.damageTaken) end },
    { "Interrupts", function(s) return Num(s.interrupts) end },
    { "Duels won", function(s) return Num(s.duelsWon) end },
    { "Duels lost", function(s) return Num(s.duelsLost) end },
    { "Honorable kills", function(s) return Num(s.honorKills) end },
    { "Flagged for PvP", function(s) return Duration(s.pvpTime) end },
    { "Places discovered", function(s) return Num(s.discoveries) end },
    { "Rested bonus XP", function(s) return Num(s.restedXP) end },
    { "Spells learned", function(s) return Num(s.spellsLearned + s.recipes) end },
    { "Quests abandoned", function(s) return Num(s.abandoned) end },
    { "NPCs talked to", function(s) return Num(s.npcTalks) end },
    { "Repairs", function(s) return Money(s.repairs) end },
    { "Time underwater", function(s) return Duration(s.breathTime) end },
    { "Screenshots", function(s) return Num(s.screenshots) end },
}

local PEOPLE_CARDS = {
    { "Players grouped with", function(s) return Num(s.mateCount or 0) end },
    { "In a group", function(s) return Duration(s.groupTime) end },
    { "Solo", function(s) return Duration(s.soloTime) end },
    { "Emotes", function(s) return Num(s.emotes) end },
    { "Said \"lol\"", function(s) return Num(s.saidLol) end },
    { "Said \"rip\"", function(s) return Num(s.saidRip) end },
}

local WORDS = {
    S = "session", ES = "end", Z = "zone", SZ = "subzone", P = "path", W = "moved", T = "flight", C = "cast", K = "kill",
    N = "name", D = "died", R = "released", U = "revived", F = "combat", E = "encounter", B = "boss",
    L = "level", X = "xp", M = "money", O = "loot", Q = "quest", G = "gear", SK = "skill", RP = "rep",
    AC = "achieve", LG = "combatlog", A = "aura", CP = "camp", RS = "resting", I = "item",
    SN = "spell", IN = "itemname", CH = "channel", CI = "interrupted", AFK = "afk", RX = "rested",
    GP = "group", GM = "member", WD = "said", EM = "emote", DM = "meter", DS = "meterspell", DP = "meterparty",
    DL = "deathspot", RZ = "rezoffer", SH = "spirithealer", DU = "duelask", DW = "duel", EX = "discover",
    XR = "restedxp", MT = "timer", DB = "durability", RE = "repair", NI = "npc", QN = "questname",
    LS = "learned", LR = "recipe", TL = "talents", HB = "hearth", HK = "hk", HN = "honor", PV = "pvp",
    PT = "pet", SS = "screenshot", TP = "played", RL = "roll", ST = "stats", GR = "rules",
    DR = "deathhit", CU = "currency", CN = "currencyname", CR = "crafted", CC = "cc", NC = "collected",
}

-- Stats views ------------------------------------------------------------------

local liveStats, openTimers = {}, {}
local function Snapshot(src, addSession)
    for _, k in ipairs(ns.STAT_KEYS) do liveStats[k] = src[k] or 0 end
    if ns.sessionG and addSession then liveStats.tracked = liveStats.tracked + GetTime() - ns.sessionG end
    if addSession and ns.OpenTimers then
        for k, secs in pairs(ns.OpenTimers(openTimers)) do liveStats[k] = (liveStats[k] or 0) + secs end
    end
    local n = 0
    if ns.char and ns.char.mates then
        for _ in pairs(ns.char.mates) do n = n + 1 end
    end
    liveStats.mateCount = n
    return liveStats
end

-- Open cells split by hairlines, like the site's "This week" row: a small label over a
-- big condensed number. The first row has a stronger rule above it.
local CELL_W = floor(CONTENT_W / CELL_COLS)

local function StatsPage(parent, source, defs)
    local page = CreateFrame("Frame", nil, parent)
    page:SetAllPoints()
    local cells = {}
    for i, def in ipairs(defs or CARDS) do
        local col, row = (i - 1) % CELL_COLS, floor((i - 1) / CELL_COLS)
        local pad = col == 0 and 0 or 16
        local cell = CreateFrame("Frame", nil, page)
        cell:SetSize(CELL_W, CELL_H)
        cell:SetPoint("TOPLEFT", col * CELL_W, -row * CELL_H)
        Hair(cell, "BOTTOM")
        if row == 0 then Hair(cell, "TOP", T.line2) end
        if col > 0 then Hair(cell, "LEFT") end
        cell.label = Text(cell, 13, T.muted)
        cell.label:SetPoint("TOPLEFT", pad, -14)
        cell.label:SetText(def[1])
        cell.value = Text(cell, 34, T.fg, "LEFT", "display")
        cell.value:SetPoint("TOPLEFT", pad, -34)
        cell.value:SetPoint("RIGHT", -6, 0)
        cell.def = def
        cells[i] = cell
    end
    function page:Refresh()
        local s = source()
        for i = 1, #cells do cells[i].value:SetText(cells[i].def[2](s)) end
    end
    return page
end

local MATE_ROWS, MATE_ROW_H = 8, 24
local mateList = {}
local function PeoplePage(parent, source)
    local page = StatsPage(parent, source, PEOPLE_CARDS)
    local top = -2 * CELL_H - 22
    local heading = Text(page, 24, T.fg, "LEFT", "display")
    heading:SetPoint("TOPLEFT", 0, top)
    heading:SetText("Grouped with most")
    local rows = {}
    for i = 1, MATE_ROWS do
        local row = CreateFrame("Frame", nil, page)
        row:SetHeight(MATE_ROW_H)
        row:SetPoint("TOPLEFT", 0, top - 36 - (i - 1) * MATE_ROW_H)
        row:SetPoint("TOPRIGHT", 0, top - 36 - (i - 1) * MATE_ROW_H)
        Hair(row, "BOTTOM")
        local name = Text(row, 14, T.fg)
        name:SetPoint("LEFT")
        name:SetWidth(320)
        local value = Text(row, 13, T.text, "RIGHT")
        value:SetPoint("RIGHT")
        value:SetWidth(240)
        rows[i] = { name = name, value = value, row = row }
    end
    local empty = Text(page, 14, T.muted)
    empty:SetPoint("TOPLEFT", 0, top - 42)
    empty:SetText("No groups yet.")
    local refreshCards = page.Refresh
    function page:Refresh()
        refreshCards(self)
        wipe(mateList)
        local mates = ns.char and ns.char.mates
        if mates then
            for key in pairs(mates) do mateList[#mateList + 1] = key end
            table.sort(mateList, function(a, b) return mates[a].secs > mates[b].secs end)
        end
        empty:SetShown(#mateList == 0)
        for i = 1, MATE_ROWS do
            local key = mateList[i]
            rows[i].row:SetShown(key ~= nil)
            rows[i].name:SetText(key or "")
            if key then
                local m = mates[key]
                rows[i].value:SetText(format("%s together, %d group%s", Duration(m.secs), m.groups,
                    m.groups == 1 and "" or "s"))
            else
                rows[i].value:SetText("")
            end
        end
    end
    return page
end

-- Log lines as the companion reads them: the event word in scarlet, the fields after it.
local function LivePage(parent)
    local page = CreateFrame("Frame", nil, parent)
    page:SetAllPoints()
    local rows, lines = {}, {}
    local ROW_H = 20
    local count = floor((H - HEADER_H - PAD * 2 - TITLE_H) / ROW_H)
    for i = 1, count do
        local word = Text(page, 13, T.accent, "LEFT", "strong")
        word:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
        word:SetWidth(96)
        local rest = Text(page, 13, T.text)
        rest:SetPoint("LEFT", word, "RIGHT", 8, 0)
        rest:SetPoint("RIGHT", page, "RIGHT", 0, 0)
        rows[i] = { word = word, rest = rest }
    end
    local empty = Text(page, 14, T.muted)
    empty:SetPoint("TOPLEFT")
    empty:SetText("Nothing recorded yet this session.")
    function page:Refresh()
        ns.LiveLines(lines)
        empty:SetShown(#lines == 0)
        for i = 1, count do
            local line = lines[i]
            local row = rows[i]
            if line then
                local code, rest = line:match("^%d+\t([^\t]+)\t?(.*)$")
                row.word:SetText(WORDS[code] or code or "")
                row.rest:SetText((rest or ""):gsub("\t", "   "), nil)
            else
                row.word:SetText("")
                row.rest:SetText("")
            end
        end
    end
    return page
end

local function Toggle(parent, y, label, get, set)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(44)
    row:SetPoint("TOPLEFT", 0, y)
    row:SetPoint("TOPRIGHT", 0, y)
    local hover = Fill(row, T.fg, 0.03)
    hover:SetAllPoints()
    hover:Hide()
    Hair(row, "BOTTOM")
    local text = Text(row, 14, T.fg)
    text:SetPoint("LEFT", 0, 0)
    text:SetText(label)
    local track = CreateFrame("Frame", nil, row)
    track:SetSize(32, 14)
    track:SetPoint("RIGHT", -2, 0)
    local trackFill = Fill(track, T.grey)
    trackFill:SetAllPoints()
    local knob = Fill(track, T.fg, 1, "ARTWORK")
    knob:SetSize(10, 10)
    function row:Refresh()
        local on = get()
        local c = on and T.accent or T.grey
        trackFill:SetVertexColor(c[1], c[2], c[3], c[4] or 1)
        knob:ClearAllPoints()
        knob:SetPoint(on and "RIGHT" or "LEFT", on and -2 or 2, 0)
    end
    row:SetScript("OnClick", function(self)
        set(not get())
        self:Refresh()
        ns.RefreshStatus()
    end)
    row:SetScript("OnEnter", function() hover:Show() end)
    row:SetScript("OnLeave", function() hover:Hide() end)
    return row
end

-- The main action: scarlet with dark text, like the site's button.
local function Button(parent, label, width, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width, 30)
    Fill(b, T.accent):SetAllPoints()
    local sheen = Fill(b, T.accentSoft, 1, "BORDER")
    sheen:SetAllPoints()
    sheen:Hide()
    local text = Text(b, 14, T.ink, "CENTER", "strong")
    text:SetPoint("CENTER")
    text:SetText(label)
    b:SetScript("OnEnter", function() sheen:Show() end)
    b:SetScript("OnLeave", function() sheen:Hide() end)
    b:SetScript("OnClick", onClick)
    return b
end

local function SettingsPage(parent)
    local page = CreateFrame("Frame", nil, parent)
    page:SetAllPoints()
    local opt = ns.opt
    local toggles = {
        Toggle(page, 0, "Record movement path", function() return opt.path end, function(v) opt.path = v end),
        Toggle(page, -44, "Turn on combat logging at login", function() return opt.combatLog end,
            function(v) opt.combatLog = v end),
        Toggle(page, -88, "Show login message", function() return opt.chat end, function(v) opt.chat = v end),
        Toggle(page, -132, "Pause recording", function() return opt.paused end, function(v) opt.paused = v end),
        Toggle(page, -176, "Show recording icon", function() return opt.icon ~= false end,
            function(v) opt.icon = v end),
        Toggle(page, -220, "Take screenshots at key moments", function() return opt.shots end,
            function(v) opt.shots = v end),
    }
    local save = Button(page, "Save chunk now", 150, function()
        SlashCmdList.SCARLET("save")
        ns.RefreshStatus()
    end)
    save:SetPoint("TOPLEFT", 0, -284)
    function page:Refresh()
        for i = 1, #toggles do toggles[i]:Refresh() end
    end
    return page
end

-- One row per integration in Addons.lua: the addon's name, whether it is installed and loaded, the
-- toggle, and the lines it wrote this session. An addon that is not installed is greyed out.
local ADDON_ROW_H = 44

local function AddonsPage(parent)
    local page = CreateFrame("Frame", nil, parent)
    page:SetAllPoints()
    local registry = ns.Addons.REGISTRY
    local rows, data = {}, {}
    for i, e in ipairs(registry) do
        local key = e.key
        local row = Toggle(page, -(i - 1) * ADDON_ROW_H, e.label, function() return ns.Addons.IsOn(key) end,
            function(v) ns.Addons.SetOn(key, v) end)
        row.status = Text(row, 13, T.muted, "RIGHT")
        row.status:SetPoint("RIGHT", -230, 0)
        row.status:SetWidth(170)
        row.count = Text(row, 22, T.fg, "RIGHT", "display")
        row.count:SetPoint("RIGHT", -60, 0)
        row.count:SetWidth(90)
        rows[i] = row
    end
    function page:Refresh()
        ns.Addons.Rows(data)
        for i, row in ipairs(rows) do
            local d = data[i]
            row:Refresh()
            row.status:SetText(d.loaded and "Loaded" or d.installed and "Installed, not loaded" or "Not installed")
            row.count:SetText(Num(d.lines))
            row:SetAlpha(d.installed and 1 or 0.4)
            row:SetEnabled(d.installed)
        end
    end
    return page
end

-- Each font's name is drawn in that font; the chosen one is marked like the nav.
local FONT_ROW_H, FONT_SIZE = 34, 16

local function FontsPage(parent)
    local page = CreateFrame("Frame", nil, parent)
    page:SetAllPoints()
    local scroll = CreateFrame("ScrollFrame", nil, page)
    scroll:SetAllPoints()
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(1, 1)
    scroll:SetScrollChild(child)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local top = max(0, child:GetHeight() - self:GetHeight())
        self:SetVerticalScroll(math.min(top, max(0, self:GetVerticalScroll() - delta * FONT_ROW_H * 3)))
    end)
    scroll:SetScript("OnSizeChanged", function(_, w) child:SetWidth(w) end)

    local rows = {}
    local function Row(i)
        local row = CreateFrame("Button", nil, child)
        row:SetHeight(FONT_ROW_H)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * FONT_ROW_H)
        row:SetPoint("TOPRIGHT", 0, -(i - 1) * FONT_ROW_H)
        local hover = Fill(row, T.fg, 0.03)
        hover:SetAllPoints()
        hover:Hide()
        row.fill = Fill(row, T.accent, 0.1)
        row.fill:SetAllPoints()
        row.marker = Fill(row, T.accent, 1, "ARTWORK")
        row.marker:SetPoint("TOPLEFT")
        row.marker:SetPoint("BOTTOMLEFT")
        row.marker:SetWidth(2)
        Hair(row, "BOTTOM")
        row.label = row:CreateFontString(nil, "OVERLAY")
        row.label:SetPoint("LEFT", 14, 0)
        row.label:SetPoint("RIGHT", -12, 0)
        row.label:SetJustifyH("LEFT")
        row.label:SetWordWrap(false)
        row.label:SetTextColor(T.fg[1], T.fg[2], T.fg[3])
        row:SetScript("OnClick", function(self)
            ns.opt.font = self.font
            ApplyFont()
            page:Mark()
        end)
        row:SetScript("OnEnter", function() hover:Show() end)
        row:SetScript("OnLeave", function() hover:Hide() end)
        return row
    end

    -- Highlight only; a click must not re-set every row's font.
    function page:Mark()
        local chosen = ChosenFont()
        for i = 1, #fontList do
            local row = rows[i]
            if row then
                row.fill:SetShown(row.font == chosen)
                row.marker:SetShown(row.font == chosen)
            end
        end
    end

    function page:Refresh()
        child:SetWidth(scroll:GetWidth())
        local list = ListFonts()
        for i, name in ipairs(list) do
            local row = rows[i] or Row(i)
            rows[i] = row
            if row.font ~= name then
                row.font = name
                SetFontSafe(row.label, fontPaths[name], FONT_SIZE)
                row.label:SetText(name)
            end
            row:Show()
        end
        for i = #list + 1, #rows do rows[i]:Hide() end
        child:SetHeight(max(1, #list * FONT_ROW_H))
        self:Mark()
    end
    return page
end

-- Window -------------------------------------------------------------------------

local NAV = {
    { key = "overview", label = "Character" },
    { key = "session", label = "This session" },
    { key = "stats", label = "Stats" },
    { key = "time", label = "Time" },
    { key = "more", label = "Combat and more" },
    { key = "people", label = "People" },
    { key = "live", label = "Live" },
    { key = "addons", label = "Addons" },
    { key = "settings", label = "Settings" },
    { key = "fonts", label = "Fonts" },
}

-- Pages that change only when you click them, not on the refresh ticker.
local STATIC_PAGES = { settings = true, fonts = true }

local function Show(key)
    current = key
    for k, page in pairs(pages) do page:SetShown(k == key) end
    for _, b in ipairs(navButtons) do b:SetActive(b.key == key) end
    -- The Character page opens on the character's name; the others open on their title.
    local home = key == "overview"
    window.pageTitle:SetShown(not home)
    window.pageTitle:SetText(navButtons[key].label)
    window.body:ClearAllPoints()
    window.body:SetPoint("TOPLEFT", 0, home and 0 or -TITLE_H)
    window.body:SetPoint("BOTTOMRIGHT")
    pages[key]:Refresh()
end

-- The current page carries a scarlet marker and a faint scarlet wash, as in the site's drawing.
local function NavButton(parent, i, def)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(NAV_H)
    b:SetPoint("TOPLEFT", 0, -12 - (i - 1) * NAV_H)
    b:SetPoint("TOPRIGHT", -1, -12 - (i - 1) * NAV_H)
    b.key, b.label = def.key, def.label
    local fill = Fill(b, T.accent, 0.1)
    fill:SetAllPoints()
    local hover = Fill(b, T.fg, 0.04)
    hover:SetAllPoints()
    hover:Hide()
    local marker = Fill(b, T.accent, 1, "ARTWORK")
    marker:SetPoint("TOPLEFT")
    marker:SetPoint("BOTTOMLEFT")
    marker:SetWidth(2)
    local text = Text(b, 14, T.muted)
    text:SetPoint("LEFT", 16, 0)
    text:SetText(def.label)
    function b:SetActive(on)
        fill:SetShown(on)
        marker:SetShown(on)
        local c = on and T.fg or T.muted
        text:SetTextColor(c[1], c[2], c[3])
    end
    b:SetScript("OnClick", function() Show(def.key) end)
    b:SetScript("OnEnter", function() hover:Show() end)
    b:SetScript("OnLeave", function() hover:Hide() end)
    return b
end

local function CloseButton(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(28, 28)
    local strokes = {}
    for i, angle in ipairs({ math.pi / 4, -math.pi / 4 }) do
        local t = Fill(b, T.muted, 1, "ARTWORK")
        t:SetSize(13, 1.5)
        t:SetPoint("CENTER")
        t:SetRotation(angle)
        strokes[i] = t
    end
    local function Tint(c)
        for _, t in ipairs(strokes) do t:SetVertexColor(c[1], c[2], c[3]) end
    end
    b:SetScript("OnEnter", function() Tint(T.accent) end)
    b:SetScript("OnLeave", function() Tint(T.muted) end)
    b:SetScript("OnClick", function() window:Hide() end)
    return b
end

local RefreshIcon

function ns.RefreshStatus()
    if RefreshIcon then RefreshIcon() end
    if not window then return end
    local paused = ns.opt.paused
    local c = paused and T.muted or T.accent
    window.dot:SetVertexColor(c[1], c[2], c[3])
    window.status:SetText(paused and "Paused" or "Recording")
    local n, bytes = ns.StoredChunks()
    window.store:SetText(format("%d chunks  %.1f KB\n%d lines pending", n, bytes / 1024, ns.Pending()))
end

local function Build()
    window = CreateFrame("Frame", "ScarletWindow", UIParent)
    window:SetSize(W, H)
    window:SetPoint("CENTER")
    window:SetFrameStrata("HIGH")
    window:SetToplevel(true)
    window:SetClampedToScreen(true)
    window:SetMovable(true)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", window.StopMovingOrSizing)
    tinsert(UISpecialFrames, "ScarletWindow")

    local shadow = Fill(window, { 0, 0, 0 }, 0.5, "BACKGROUND", -8)
    shadow:SetPoint("TOPLEFT", -6, 6)
    shadow:SetPoint("BOTTOMRIGHT", 6, -6)
    Fill(window, T.win, 0.98):SetAllPoints()
    Border(window, T.line2)

    local header = CreateFrame("Frame", nil, window)
    header:SetPoint("TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", -1, -1)
    header:SetHeight(HEADER_H)
    Hair(header, "BOTTOM")

    local mark = Fill(header, T.accent, 1, "ARTWORK")
    mark:SetSize(9, 9)
    mark:SetPoint("LEFT", 20, 0)
    mark:SetRotation(math.pi / 4)
    local title = Text(header, 24, T.fg, "LEFT", "display")
    title:SetPoint("LEFT", mark, "RIGHT", 10, 0)
    title:SetText("Scarlet")
    local version = Text(header, 12, T.muted)
    version:SetPoint("BOTTOMLEFT", title, "BOTTOMRIGHT", 8, 3)
    version:SetText("v" .. ns.VERSION)

    local close = CloseButton(header)
    close:SetPoint("RIGHT", -10, 0)
    window.status = Text(header, 13, T.text, "RIGHT")
    window.status:SetPoint("RIGHT", close, "LEFT", -8, 0)
    window.dot = Fill(header, T.accent, 1, "ARTWORK")
    window.dot:SetSize(6, 6)
    window.dot:SetPoint("RIGHT", window.status, "LEFT", -7, 0)

    local sidebar = CreateFrame("Frame", nil, window)
    sidebar:SetPoint("TOPLEFT", 1, -HEADER_H - 1)
    sidebar:SetPoint("BOTTOMLEFT", 1, 1)
    sidebar:SetWidth(SIDEBAR_W)
    Hair(sidebar, "RIGHT")
    window.store = Text(sidebar, 12, T.muted)
    window.store:SetPoint("BOTTOMLEFT", 16, 14)
    window.store:SetWordWrap(true)
    window.store:SetJustifyV("BOTTOM")

    local content = CreateFrame("Frame", nil, window)
    content:SetPoint("TOPLEFT", SIDEBAR_W + 1 + PAD, -HEADER_H - PAD)
    content:SetPoint("BOTTOMRIGHT", -PAD, PAD)
    window.pageTitle = Text(content, 30, T.fg, "LEFT", "display")
    window.pageTitle:SetPoint("TOPLEFT", 0, 2)
    local body = CreateFrame("Frame", nil, content)
    window.body = body
    body:SetPoint("TOPLEFT", 0, -TITLE_H)
    body:SetPoint("BOTTOMRIGHT")

    pages = {
        overview = ns.OverviewPage(body, ns.UI),
        stats = StatsPage(body, function() return Snapshot(ns.char or ns.sess, true) end),
        session = StatsPage(body, function() return Snapshot(ns.sess, true) end),
        time = StatsPage(body, function() return Snapshot(ns.char or ns.sess, true) end, TIME_CARDS),
        more = StatsPage(body, function() return Snapshot(ns.char or ns.sess, true) end, MORE_CARDS),
        people = PeoplePage(body, function() return Snapshot(ns.char or ns.sess, true) end),
        live = LivePage(body),
        addons = AddonsPage(body),
        settings = SettingsPage(body),
        fonts = FontsPage(body),
    }
    navButtons = {}
    for i, def in ipairs(NAV) do
        local b = NavButton(sidebar, i, def)
        navButtons[i] = b
        navButtons[def.key] = b
    end

    window:SetScript("OnShow", function()
        ns.RefreshStatus()
        if not refreshTicker then
            refreshTicker = C_Timer.NewTicker(REFRESH_SECONDS, function()
                if not STATIC_PAGES[current] then pages[current]:Refresh() end
                ns.RefreshStatus()
            end)
        end
    end)
    window:SetScript("OnHide", function()
        if refreshTicker then refreshTicker:Cancel(); refreshTicker = nil end
    end)
    window:Hide()
    Show("overview")
end

function ns.Toggle()
    if not window then Build() end
    window:SetShown(not window:IsShown())
end

-- Recording icon ----------------------------------------------------------------------
-- A small mark shown while Scarlet records. Click opens the window, left-drag moves
-- it; opt.iconPos keeps where it was dropped, opt.icon false hides it.

local icon

-- Saved from the icon's center, so the anchor StopMovingOrSizing leaves (UIParent or
-- the minimap it started beside) does not matter.
local function SaveIconPos()
    local x, y = icon:GetCenter()
    if not x then return end
    local s = icon:GetEffectiveScale() / UIParent:GetEffectiveScale()
    ns.opt.iconPos = { "CENTER", "BOTTOMLEFT", floor(x * s + 0.5), floor(y * s + 0.5) }
end

local function PlaceIcon()
    icon:ClearAllPoints()
    local pos = ns.opt.iconPos
    if type(pos) == "table" and pos[1] then
        icon:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    elseif Minimap then
        icon:SetPoint("TOPRIGHT", Minimap, "TOPLEFT", -8, 0)
    else
        icon:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -220, -20)
    end
end

local function BuildIcon()
    icon = CreateFrame("Button", nil, UIParent)
    icon:SetSize(26, 26)
    icon:SetFrameStrata("MEDIUM")
    icon:SetClampedToScreen(true)
    icon:SetMovable(true)
    icon:RegisterForClicks("LeftButtonUp")
    icon:RegisterForDrag("LeftButton")
    Fill(icon, T.bg, 0.94):SetAllPoints()
    Border(icon, T.line2)
    local mark = Fill(icon, T.accent, 1, "ARTWORK")
    mark:SetSize(10, 10)
    mark:SetPoint("CENTER")
    mark:SetRotation(math.pi / 4)
    local pulse = mark:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local fade = pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0.35)
    fade:SetDuration(1.4)
    fade:SetSmoothing("IN_OUT")
    local hover = Fill(icon, T.fg, 0.08, "HIGHLIGHT")
    hover:SetAllPoints()

    -- A drag ends with a mouse-up over the icon; that release is not a click.
    local dragged = false
    icon:SetScript("OnDragStart", function(self)
        dragged = true
        GameTooltip:Hide()
        self:StartMoving()
    end)
    icon:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SaveIconPos()
        C_Timer.After(0, function() dragged = false end)
    end)
    icon:SetScript("OnClick", function()
        if not dragged then ns.Toggle() end
    end)
    icon:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Scarlet")
        local n = ns.StoredChunks()
        GameTooltip:AddLine(format("Recording, %d chunks stored", n), T.muted[1], T.muted[2], T.muted[3])
        GameTooltip:Show()
    end)
    icon:SetScript("OnLeave", function() GameTooltip:Hide() end)
    icon:SetScript("OnShow", function() pulse:Play() end)
    icon:SetScript("OnHide", function() pulse:Stop() end)
    PlaceIcon()
    icon:Hide()
end

RefreshIcon = function()
    if not icon then return end
    icon:SetShown(ns.opt.icon ~= false and not ns.opt.paused)
end

-- Login toast -------------------------------------------------------------------------

local function Toast()
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(300, 54)
    f:SetPoint("TOP", 0, -140)
    f:SetFrameStrata("HIGH")
    Fill(f, T.bg, 0.95):SetAllPoints()
    Border(f, T.line2)
    local rail = Fill(f, T.accent, 1, "ARTWORK")
    rail:SetPoint("TOPLEFT", 1, -1)
    rail:SetPoint("BOTTOMLEFT", 1, 1)
    rail:SetWidth(2)
    local title = Text(f, 22, T.fg, "LEFT", "display")
    title:SetPoint("TOPLEFT", 16, -9)
    title:SetText("Scarlet is recording")
    local sub = Text(f, 13, T.muted)
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -5)
    sub:SetText("v" .. ns.VERSION .. "   /scarlet opens the window")
    local fade = f:CreateAnimationGroup()
    local alpha = fade:CreateAnimation("Alpha")
    alpha:SetFromAlpha(1)
    alpha:SetToAlpha(0)
    alpha:SetStartDelay(6)
    alpha:SetDuration(1.2)
    fade:SetScript("OnFinished", function() f:Hide() end)
    fade:Play()
end

function ns.OnLogin()
    WatchFonts()
    BuildIcon()
    RefreshIcon()
    if ns.db.seenVersion ~= ns.VERSION then
        ns.db.seenVersion = ns.VERSION
        Toast()
    end
    if ns.opt.chat then
        ns.Print((ns.opt.paused and "is paused" or "is recording") .. ". |cffff6b8e/scarlet|r opens the window.")
    end
end

-- Commands ----------------------------------------------------------------------------

function Scarlet_OnCompartmentClick()
    ns.Toggle()
end

SLASH_SCARLET1, SLASH_SCARLET2 = "/scarlet", "/scar"
SlashCmdList.SCARLET = function(msg)
    msg = (msg or ""):lower():match("^%s*(%S*)")
    if msg == "pause" then
        ns.opt.paused = not ns.opt.paused
        ns.Print(ns.opt.paused and "paused." or "recording.")
        ns.RefreshStatus()
    elseif msg == "save" then
        ns.Seal(true)
        ns.Print("saved the current chunk. It reaches disk on /reload or logout.")
    elseif msg == "status" then
        local n, bytes = ns.StoredChunks()
        ns.Print(format("%d chunks stored (%.1f KB), %d lines pending, %s.", n, bytes / 1024, ns.Pending(),
            ns.opt.paused and "paused" or "recording"))
    else
        ns.Toggle()
    end
end
