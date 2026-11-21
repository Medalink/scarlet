-- Core.lua: the line buffer, chunk sealing, SavedVariables and counters.
-- The chunk format is defined in docs/FORMAT.md; keep the two in step.
local ADDON, ns = ...
_G.Scarlet = ns

local floor, select, type, tostring, concat, wipe = math.floor, select, type, tostring, table.concat, wipe
local GetTime, time = GetTime, time
local issecretvalue = issecretvalue or function(_) return false end

local FORMAT_VERSION = 1
local CHUNK_LINES = 1000      -- seal after this many lines, once out of combat
local HARD_LINES = 4000       -- seal even in combat past this many
local BUDGET_BYTES = 8000000  -- oldest chunks are dropped past this much payload
local WARN_BYTES = 6000000    -- warn in chat that an export is due
local LIVE_LINES = 40

ns.VERSION = C_AddOns.GetAddOnMetadata(ADDON, "Version") or "?"

ns.STAT_KEYS = { "kills", "blows", "casts", "deaths", "foot", "mount", "swim", "fly", "jumps", "xp",
    "earned", "spent", "loot", "quests", "dungeons", "bosses", "combat", "flights", "levels", "achievements",
    "tracked", "camps", "camptime", "buffs", "sold", "walk", "footTime", "walkTime", "mountTime", "swimTime",
    "flyTime", "taxiTime", "stillTime", "castTime", "afkTime", "restedTime", "unrestedTime", "groupTime",
    "soloTime", "emotes", "saidLol", "saidRip", "damage", "healing", "damageTaken", "absorbs", "interrupts",
    "dispels", "rezzes", "spiritRez", "duelsWon", "duelsLost", "discoveries", "restedXP", "breathTime", "repairs",
    "npcTalks", "abandoned", "spellsLearned", "recipes", "honorKills", "honor", "pvpTime", "screenshots", "rolls", "crafted", "ccTaken",
    "collected" }

local DEFAULT_OPT = { path = true, combatLog = true, chat = true, paused = false }

-- The open buffer lives in SavedVariables (db.buf) rather than a local, so
-- whatever the client writes on reload, logout or disconnect includes it,
-- whichever addon's logout handler runs last. InitDB seals a leftover
-- buffer from the last session before anything new is written.
local db, chunks
local buf, bufN = {}, 0
local parts = {}
local chunkT, lastG
local pendingSeal = false
local live, liveHead = {}, 0

ns.sess = {}
for _, k in ipairs(ns.STAT_KEYS) do ns.sess[k] = 0 end

-- Every value from the client goes through here. A secret value is never
-- compared, concatenated or indexed; it is written as "?".
local function Field(v)
    if issecretvalue(v) then return "?" end
    if v == nil then return "" end
    local t = type(v)
    if t == "string" then
        if v:find("[\t\n\r]") then v = v:gsub("[\t\n\r]", " ") end
        return v
    elseif t == "number" then
        if v == floor(v) then return tostring(v) end
        return ("%.2f"):format(v)
    elseif t == "boolean" then
        return v and "1" or "0"
    end
    return ""
end
ns.Field = Field

function ns.Plain(v)
    return not issecretvalue(v) and v ~= nil
end

local function Prune()
    local total = 0
    for i = 1, #chunks do total = total + #chunks[i].z end
    local drop = 0
    while total > BUDGET_BYTES and drop < #chunks - 1 do
        drop = drop + 1
        total = total - #chunks[drop].z
    end
    if drop > 0 then
        -- Record the hole so the companion can tell a gap from a quiet time.
        db.gaps = db.gaps or {}
        db.gaps[#db.gaps + 1] = { from = chunks[1].q, to = chunks[drop].q, at = time() }
        for _ = 1, drop do table.remove(chunks, 1) end
    end
    if total > WARN_BYTES and not db.warned then
        db.warned = true
        if ns.Print then ns.Print("storage is nearly full; run the companion export soon.") end
    elseif total <= WARN_BYTES then
        db.warned = nil
    end
end

local function Encode(text)
    local util = C_EncodingUtil
    if not util or not util.CompressString then return "txt", text end
    local ok, packed = pcall(util.CompressString, text, Enum.CompressionMethod.Deflate,
        Enum.CompressionLevel.OptimizeForSize)
    if not ok or type(packed) ~= "string" then return "txt", text end
    local ok2, b64 = pcall(util.EncodeBase64, packed)
    if not ok2 or type(b64) ~= "string" then return "txt", text end
    return "d64", b64
end

function ns.Seal(force)
    if bufN == 0 or not db then return end
    if not force and InCombatLockdown() and bufN < HARD_LINES then
        pendingSeal = true
        return
    end
    pendingSeal = false
    local enc, z = Encode(concat(buf, "\n", 1, bufN))
    db.seq = db.seq + 1
    chunks[#chunks + 1] = { q = db.seq, c = ns.charKey or "?", s = ns.session or 0, t = chunkT, n = bufN, e = enc, z = z }
    wipe(buf)
    bufN, chunkT = 0, nil
    db.bufT, db.bufC, db.bufS = nil, nil, nil
    Prune()
end

function ns.SealIfPending()
    if pendingSeal then ns.Seal() end
end

function ns.Emit(code, ...)
    if not db or db.opt.paused then return end
    local now = GetTime()
    if not chunkT then
        chunkT, lastG = time(), now
        -- Saved with the buffer: every dt in it counts from this time.
        db.bufT, db.bufC, db.bufS = chunkT, ns.charKey or "?", ns.session or 0
    end
    local dt = floor((now - lastG) * 100 + 0.5)
    if dt < 0 then dt = 0 end
    lastG = lastG + dt / 100
    parts[1], parts[2] = dt, code
    local n = select("#", ...)
    for i = 1, n do parts[i + 2] = Field((select(i, ...))) end
    local line = concat(parts, "\t", 1, n + 2)
    bufN = bufN + 1
    buf[bufN] = line
    liveHead = liveHead % LIVE_LINES + 1
    live[liveHead] = line
    if bufN >= CHUNK_LINES then ns.Seal() end
end

-- Newest first, for the Live page.
function ns.LiveLines(out)
    wipe(out)
    for i = 0, LIVE_LINES - 1 do
        local line = live[(liveHead - 1 - i) % LIVE_LINES + 1]
        if not line then break end
        out[#out + 1] = line
    end
    return out
end

function ns.Add(key, n)
    n = n or 1
    ns.sess[key] = ns.sess[key] + n
    if ns.char then ns.char[key] = (ns.char[key] or 0) + n end
end

function ns.Pending()
    return bufN
end

function ns.StoredChunks()
    local bytes = 0
    for i = 1, #chunks do bytes = bytes + #chunks[i].z end
    return #chunks, bytes
end

function ns.InitDB()
    ScarletDB = type(ScarletDB) == "table" and ScarletDB or {}
    db = ScarletDB
    db.v = FORMAT_VERSION
    db.seq = db.seq or 0
    db.chunks = db.chunks or {}
    db.chars = db.chars or {}
    db.opt = db.opt or {}
    for k, v in pairs(DEFAULT_OPT) do
        if db.opt[k] == nil then db.opt[k] = v end
    end
    chunks = db.chunks
    ns.db = db
    ns.opt = db.opt
    -- A buffer left by the last session (reload, disconnect, or an addon
    -- that errored in its logout handler) becomes a chunk with its own
    -- start time and character. r = 1 marks it recovered.
    if type(db.buf) == "table" and #db.buf > 0 and db.bufT then
        local enc, z = Encode(concat(db.buf, "\n", 1, #db.buf))
        db.seq = db.seq + 1
        chunks[#chunks + 1] = { q = db.seq, c = db.bufC or "?", s = db.bufS or 0, t = db.bufT, n = #db.buf,
            e = enc, z = z, r = 1 }
        Prune()
    end
    db.buf = buf
    db.bufT, db.bufC, db.bufS = nil, nil, nil
end

function ns.InitChar(key)
    ns.charKey = key
    local ch = db.chars[key] or {}
    db.chars[key] = ch
    for _, k in ipairs(ns.STAT_KEYS) do ch[k] = ch[k] or 0 end
    ns.char = ch
end

-- Session rows -------------------------------------------------------------------
-- ScarletDB.chars[key].ov = { sess = { rows, oldest first }, cur = the open row, run = last dungeon run }.
-- A row sums one session as events happen; its shape and counting rules are in docs/OVERVIEW.md.
-- Capture.lua calls these where it already sees each event. Nothing here runs on a timer.

local OV_ROWS = 120  -- closed rows kept
local OV_ZONES = 40  -- zones with their own split in one row
local RUN_GAP = 1800 -- leaving a dungeon and coming back within this is the same run

local Ov = {}
ns.Ov = Ov
Ov.ROWS = OV_ROWS
local ov, cur                          -- the character's ov table and its open row
local mark, level, zone, instType      -- clock, level, zone name and instance type now
local zoneN                            -- zones with a split in the open row
local seen = {}                        -- distinct zone names in the open row

local function Bump(t, k, n) t[k] = (t[k] or 0) + n end

-- The open row's share of the current level and of the current zone.
local function Slots()
    local lvS, znS
    if level then
        lvS = cur.lv[level]
        if not lvS then lvS = {}; cur.lv[level] = lvS end
    end
    if zone then
        znS = cur.zn[zone]
        if not znS and zoneN < OV_ZONES then
            znS = {}
            cur.zn[zone] = znS
            zoneN = zoneN + 1
        end
    end
    return lvS, znS
end

-- Adds the time since the last mark to the row, the level and the zone it was spent in.
local function Tick()
    local now = GetTime()
    local dt = now - mark
    mark = now
    cur.last = time()
    if dt <= 0 then return end
    cur.p = cur.p + dt
    local l, z = Slots()
    if l then Bump(l, "p", dt) end
    if z then Bump(z, "p", dt) end
end

local function Round(row)
    row.p = floor(row.p + 0.5)
    for _, s in pairs(row.lv) do
        if s.p then s.p = floor(s.p + 0.5) end
    end
    for _, s in pairs(row.zn) do
        if s.p then s.p = floor(s.p + 0.5) end
    end
end

-- Closes a row into ov.sess. A row from an older version, or one a crash left damaged, is dropped.
local function Push(row)
    if type(row) ~= "table" or type(row.t) ~= "number" then return end
    row.p = type(row.p) == "number" and row.p or 0
    row.lv = type(row.lv) == "table" and row.lv or {}
    row.zn = type(row.zn) == "table" and row.zn or {}
    Round(row)
    local sess = ov.sess
    sess[#sess + 1] = row
    while #sess > OV_ROWS do table.remove(sess, 1) end
end

local function Active() return cur ~= nil and not ns.opt.paused end

-- The session starts: t is the S line's time. A row left open by a session that never closed
-- (an error in the logout handler) is closed first, with what it has.
function Ov.Start(t, lv, money)
    local ch = ns.char
    if not ch then return end
    if type(ch.ov) ~= "table" then ch.ov = {} end
    ov = ch.ov
    if type(ov.sess) ~= "table" then ov.sess = {} end
    local stale = ov.cur
    if type(stale) == "table" and type(stale.t) == "number" then
        -- Left open by a disconnect or an error at logout: its time runs to the last change seen.
        local last = type(stale.last) == "number" and stale.last or stale.t
        if type(stale.p) == "number" and last - stale.t > stale.p then stale.p = last - stale.t end
        if type(ov.run) == "table" and ov.run.left == nil then ov.run.left = last end
    end
    if stale ~= nil then Push(stale) end
    cur = { t = t, p = 0, l0 = lv, l1 = lv, m = money, z = 0, lv = {}, zn = {} }
    ov.cur = cur
    mark, level, zone, instType, zoneN = GetTime(), lv, nil, nil, 0
    wipe(seen)
end

-- The session ends (logout or reload).
function Ov.End()
    if not cur then return end
    Tick()
    cur.l1 = level or cur.l1
    Push(cur)
    ov.cur, cur = nil, nil
    -- Logging out inside a dungeon leaves it; coming back within RUN_GAP is the same run.
    if type(ov.run) == "table" and ov.run.left == nil then ov.run.left = time() end
end

-- The open row after adding the time up to now, for the window. nil before login.
function Ov.Live()
    if cur then Tick() end
    return cur
end

function Ov.Level(lv)
    if not cur or type(lv) ~= "number" then return end
    Tick()
    level = lv
    cur.l1 = lv
end

-- Z: name is the zone's name, kind its instanceType, inst its instanceMapID (any may be nil).
function Ov.Zone(name, kind, inst)
    if not cur then return end
    Tick()
    zone, instType = name, kind
    if name and not seen[name] then
        seen[name] = true
        cur.z = cur.z + 1
    end
    local run = ov.run
    if kind == "party" or kind == "raid" then
        local same = type(run) == "table" and run.inst == inst and (run.left == nil or time() - run.left < RUN_GAP)
        if not same then Bump(cur, "r", 1) end
        if type(run) ~= "table" then run = {}; ov.run = run end
        run.inst, run.left = inst, nil
    elseif type(run) == "table" and run.left == nil then
        run.left = time()
    end
end

-- X: the amount once its source is known. kind is the X line's source: k, q, e or o.
function Ov.XP(kind, amount)
    if not Active() or type(amount) ~= "number" then return end
    local key = "xo"
    if kind == "k" then
        key = (instType == "party" or instType == "raid") and "xd" or "xk"
    elseif kind == "q" then
        key = "xq"
    elseif kind == "e" then
        key = "xe"
    end
    cur.last = time()
    local l, z = Slots()
    Bump(cur, key, amount)
    if l then Bump(l, key, amount) end
    if z then Bump(z, "x", amount) end
end

local function Count(key, zoneKey)
    if not Active() then return end
    cur.last = time()
    local l, z = Slots()
    Bump(cur, key, 1)
    if l then Bump(l, key, 1) end
    if z and zoneKey then Bump(z, zoneKey, 1) end
end

function Ov.Kill() Count("k", "k") end    -- K, any by
function Ov.Death() Count("dd", "dd") end -- D
function Ov.Quest() Count("q") end        -- Q 2

-- M: net is the change minus the part transferred between your own characters; balance what you carry now.
function Ov.Money(net, balance)
    if not Active() then return end
    if net > 0 then Bump(cur, "g", net) elseif net < 0 then Bump(cur, "s", -net) end
    if type(balance) == "number" then cur.m = balance end
end

-- Events about the player that are unit events: registered for "player" only.
local UNIT_EVENTS = {
    UNIT_SPELLCAST_SUCCEEDED = true, UNIT_SPELLCAST_START = true, UNIT_SPELLCAST_CHANNEL_START = true,
    UNIT_SPELLCAST_CHANNEL_STOP = true, UNIT_SPELLCAST_INTERRUPTED = true, UNIT_AURA = true,
    PLAYER_FLAGS_CHANGED = true, UNIT_PET = true, PLAYER_PVP_KILLS_CHANGED = true,
    LOSS_OF_CONTROL_ADDED = true, UNIT_STATS = true, UNIT_RESISTANCES = true, UNIT_ATTACK_POWER = true,
    UNIT_RANGED_ATTACK_POWER = true, UNIT_MAXHEALTH = true, UNIT_MAXPOWER = true, UNIT_ATTACK_SPEED = true,
    UNIT_SPELL_HASTE = true, UNIT_DEFENSE = true, PLAYER_DAMAGE_DONE_MODS = true,
}

-- Route each event to handlers[event] and register every event the client
-- knows. Unknown events are skipped, so one bad name never breaks loading.
function ns.Listen(frame, handlers)
    frame:SetScript("OnEvent", function(_, event, ...) handlers[event](...) end)
    local valid = C_EventUtils and C_EventUtils.IsEventValid
    for event in pairs(handlers) do
        if not valid or valid(event) then
            if UNIT_EVENTS[event] then
                frame:RegisterUnitEvent(event, "player")
            else
                frame:RegisterEvent(event)
            end
        end
    end
end

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffff2d55Scarlet|r " .. msg)
end
