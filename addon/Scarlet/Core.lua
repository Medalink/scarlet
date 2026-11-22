-- Core.lua: the line buffer, chunk sealing, SavedVariables and counters.
-- The chunk format is defined in docs/FORMAT.md; keep the two in step.
local ADDON, ns = ...
_G.Scarlet = ns

local floor, select, type, tostring, concat, wipe = math.floor, select, type, tostring, table.concat, wipe
local min, max = math.min, math.max
local format, strbyte, find = string.format, string.byte, string.find
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

local DEFAULT_OPT = { path = true, combatLog = true, chat = true, paused = false, shots = false, shareLoot = true }

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

local KEY_PRIME_HI, KEY_MULTIPLIER_HI = 1048573, 65599
local KEY_PRIME_LO, KEY_MULTIPLIER_LO = 1048571, 1000003

--- The corpse key of a creature, vehicle or object GUID: 10 hex digits that every client computes the same
--- way (docs/FORMAT.md, "Corpse key"). nil for any other GUID, so a player's GUID is never hashed.
function ns.CorpseKey(guid)
    if issecretvalue(guid) or type(guid) ~= "string" then return nil end
    if not (find(guid, "^Creature%-") or find(guid, "^Vehicle%-") or find(guid, "^GameObject%-")) then
        return nil
    end
    local hi, lo = 0, 0
    for i = 1, #guid do
        local byte = strbyte(guid, i)
        hi = (hi * KEY_MULTIPLIER_HI + byte) % KEY_PRIME_HI
        lo = (lo * KEY_MULTIPLIER_LO + byte) % KEY_PRIME_LO
    end
    return format("%05x%05x", hi, lo)
end

function ns.DisplayName(name)
    if type(name) ~= "string" then return "" end
    return (name:gsub("%-", " ", 1))
end

-- Max level -----------------------------------------------------------------------
-- The one place that knows whether the character is still levelling. The cap comes from the
-- client (never a constant here): the effective max level Blizzard's own UI uses, else the lower of
-- the expansion's and the player's cap. A character at the cap, or with experience turned off, is not
-- levelling: the levelling-only events are unregistered (not just ignored) and levelling-only
-- functions are swapped for no-ops, both in Apply below. An unreadable cap leaves the character
-- levelling, so a bad read never stops XP recording.

local Cap = { level = nil, atCap = false, xpOff = false }
ns.Cap = Cap
local capWatch, capSwap, capHooks = {}, {}, {}
local capApplied -- levelling state last applied; nil before the first Refresh
local function Noop() end

-- A client value through pcall; a secret or failed call reads as nil.
local function Probe(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, v = pcall(fn, ...)
    if ok and not issecretvalue(v) then return v end
    return nil
end

local function PlainNum(v)
    if type(v) == "number" and v == v and not issecretvalue(v) then return v end
    return nil
end

-- The level cap this character levels to, nil when the client does not say.
function Cap.Read()
    local rules = _G.GameRulesUtil
    local cap = rules and PlainNum(Probe(rules.GetEffectiveMaxLevelForPlayer))
    if not cap then
        local a, b = PlainNum(Probe(_G.GetMaxLevelForPlayerExpansion)), PlainNum(Probe(_G.GetMaxPlayerLevel))
        cap = (a and b and math.min(a, b)) or a or b
    end
    if cap and cap > 0 then return cap end
    return nil
end

-- True while levelling work should run.
function Cap.Levelling()
    return not (Cap.atCap or Cap.xpOff)
end

local function ValidEvent(event)
    local valid = C_EventUtils and C_EventUtils.IsEventValid
    return not valid or valid(event)
end

local function Apply()
    local levelling = Cap.Levelling()
    if capApplied == levelling then return end
    capApplied = levelling
    for _, w in ipairs(capWatch) do
        for _, event in ipairs(w.events) do
            if levelling then
                if ValidEvent(event) then w.frame:RegisterEvent(event) end
            else
                w.frame:UnregisterEvent(event)
            end
        end
    end
    for _, s in ipairs(capSwap) do s.tbl[s.key] = levelling and s.real or Noop end
    for _, fn in ipairs(capHooks) do fn(levelling) end
end

-- Reads the cap and the experience switches and applies the result. level is the level the
-- client just reported (PLAYER_LEVEL_UP carries it before UnitLevel does). grace, in seconds,
-- keeps the events registered a little longer when levelling just ended, so the last
-- experience line of the final level is still written.
function Cap.Refresh(level, grace)
    local lv = PlainNum(level) or PlainNum(UnitLevel("player"))
    Cap.level = Cap.Read() or Cap.level
    Cap.atCap = Cap.level ~= nil and lv ~= nil and lv >= Cap.level
    local off = Probe(_G.IsXPUserDisabled) == true
    if not off then
        local rules, enum = _G.C_GameRules, _G.Enum and _G.Enum.GameRule
        if rules and enum and enum.ExperienceBarDisabled then
            off = Probe(rules.IsGameRuleActive, enum.ExperienceBarDisabled) == true
        end
    end
    Cap.xpOff = off
    if capApplied ~= nil and not Cap.Levelling() and grace then
        C_Timer.After(grace, function() if not Cap.Levelling() then Apply() end end)
    else
        Apply()
    end
end

-- Events only a levelling character needs: registered while levelling, unregistered otherwise.
-- The handlers stay in the file's table; Listen's lazy set keeps them unregistered at load.
function Cap.Watch(frame, events)
    capWatch[#capWatch + 1] = { frame = frame, events = events }
    if capApplied then
        for _, event in ipairs(events) do
            if ValidEvent(event) then frame:RegisterEvent(event) end
        end
    end
end

-- tbl[key] runs while levelling and is a no-op otherwise.
function Cap.Swap(tbl, key)
    capSwap[#capSwap + 1] = { tbl = tbl, key = key, real = tbl[key] }
    if capApplied == false then tbl[key] = Noop end
end

-- fn(levelling) runs each time the state is applied.
function Cap.OnChange(fn)
    capHooks[#capHooks + 1] = fn
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

-- Shared with Addons.lua, whose chunks are compressed the same way.
ns.Encode = Encode

function ns.Seal(force)
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
local readAt, readTotal, credited       -- the latest /played read of the open session (epoch s, total), whether its start was credited
local holed
local GAP_SECS, XP_GAP_DIV, DING_READ = 120, 50, 1800

local function Bump(t, k, n) t[k] = (t[k] or 0) + n end

local function MarkHole(from, to)
    local lo, hi = min(from, to), max(from, to)
    for l = lo, min(hi, lo + 120) do ov.hole[l] = true end
end

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
function Ov.Start(t, lv, money, xp, xpMax)
    local ch = ns.char
    if not ch then return end
    if type(ch.ov) ~= "table" then ch.ov = {} end
    ov = ch.ov
    if type(ov.sess) ~= "table" then ov.sess = {} end
    if type(ov.ding) ~= "table" then ov.ding = {} end
    if type(ov.hole) ~= "table" then ov.hole = {} end
    ov.dl = nil
    local stale = ov.cur
    if type(stale) == "table" and type(stale.t) == "number" then
        -- Left open by a disconnect or an error at logout: its time runs to the last change seen.
        local last = type(stale.last) == "number" and stale.last or stale.t
        if type(stale.p) == "number" and last - stale.t > stale.p then stale.p = last - stale.t end
        if type(ov.run) == "table" and ov.run.left == nil then ov.run.left = last end
    end
    if stale ~= nil then Push(stale) end
    local prev = ov.sess[#ov.sess]
    if not ov.f0 then
        local oldest = ov.sess[1]
        ov.f0 = type(oldest) == "table" and tonumber(oldest.l0) or lv
    end
    local ahead = false
    if type(prev) == "table" and type(lv) == "number" and type(prev.l1) == "number" then
        if lv ~= prev.l1 then
            ahead = lv > prev.l1
        elseif xp and xpMax and xpMax == ov.xm and type(ov.xe) == "number" then
            ahead = xp > ov.xe + max(1, floor(xpMax / XP_GAP_DIV))
        end
        if ahead then MarkHole(prev.l1, lv) end
    end
    cur = { t = t, p = 0, l0 = lv, l1 = lv, m = money, z = 0, lv = {}, zn = {} }
    holed = ahead
    ov.cur = cur
    readAt, readTotal, credited = nil, nil, false
    mark, level, zone, instType, zoneN = GetTime(), lv, nil, nil, 0
    wipe(seen)
end

-- The session ends (logout or reload).
function Ov.End(xp, xpMax)
    if not cur then return end
    Tick()
    cur.l1 = level or cur.l1
    ov.xe, ov.xm = xp, xpMax
    -- Where the client's played counter stood now, for the next session to credit the reload between.
    local now = time()
    if readAt and readTotal then
        ov.pe, ov.pw, ov.pt, ov.pl, ov.pz = readTotal + (now - readAt), now, cur.t, cur.l1, zone
    else
        ov.pe = nil
    end
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

-- A /played read (TP): the client keeps counting through a reload, which the rows do not cover. The
-- first read of a session gives the counter at its start; what it stands above where the session before
-- ended is that gap, added to that session, its last level and zone, up to the wall time between the two.
function Ov.Played(total)
    if not cur or type(total) ~= "number" then return end
    local now = time()
    readAt, readTotal = now, total
    local dl, ding = ov.dl, ov.dl and ov.ding[ov.dl]
    if dl and type(ding) == "table" and dl == level and now - ding.t <= DING_READ then
        ding.p = total - (now - ding.t)
        ov.dl = nil
    end
    if credited then return end
    credited = true
    local pe, row = ov.pe, ov.sess[#ov.sess]
    ov.pe = nil
    if not pe or type(row) ~= "table" or row.t ~= ov.pt then return end
    -- Both sides are whole seconds: under 2 is rounding.
    local gap = total - (now - cur.t) - pe
    if gap > GAP_SECS then
        if not holed then MarkHole(tonumber(ov.pl) or level or 0, level or tonumber(ov.pl) or 0) end
        holed = true
        return
    end
    if gap < 2 then return end
    local credit = floor(math.min(gap, cur.t - (tonumber(ov.pw) or cur.t) + 2) + 0.5)
    if credit <= 0 then return end
    row.p = row.p + credit
    local l = type(row.lv) == "table" and row.lv[ov.pl]
    if type(l) == "table" then l.p = (l.p or 0) + credit end
    local z = type(row.zn) == "table" and ov.pz and row.zn[ov.pz]
    if type(z) == "table" then z.p = (z.p or 0) + credit end
end

function Ov.Level(lv)
    if not cur or type(lv) ~= "number" then return end
    Tick()
    if lv ~= level then
        ov.ding[lv] = { t = time(), p = 0 }
        ov.dl = lv
    end
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
        if not same then
            Bump(cur, "r", 1)
            local l = Slots()
            if l then Bump(l, "r", 1) end
        end
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
    cur.last = time()
    local l = Slots()
    if net > 0 then
        Bump(cur, "g", net)
        if l then Bump(l, "g", net) end
    elseif net < 0 then
        Bump(cur, "s", -net)
        if l then Bump(l, "s", -net) end
    end
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

-- Profiler -----------------------------------------------------------------------
-- /scarlet perf times every handler that ns.Listen routes, and the probes below, with
-- debugprofilestop. Off, the default, it installs nothing: each frame keeps the plain OnEvent
-- closure Listen made and Perf.Fn hands back the function it was given. Start swaps timing
-- closures in and wraps the probes; Stop swaps the plain ones back. The numbers stay in memory
-- for /scarlet perf report. Nothing here is written to ScarletDB.

local Perf = { on = false }
ns.Perf = Perf

local profilestop = _G.debugprofilestop
local SPIKES, MAX_ROWS = 10, 60
local listeners, probes = {}, {}  -- every ns.Listen call; functions wrapped while on
local rows, extra = {}, {}        -- rows with calls this run; label -> row for probes and Perf.Fn
local spikes, spikeMin = {}, 0    -- the slowest single calls, slowest first
local startedAt, stoppedAt, skipped = 0, nil, 0
local combatTime, combatAt, instTime, instAt, instKind = 0, nil, 0, nil, nil
local startKB, startHeap

local function NewRow(name, nested)
    local row = { name = name, calls = 0, total = 0, max = 0, nested = nested }
    rows[#rows + 1] = row
    return row
end

local function ByTime(a, b) return a.dt > b.dt end

local function Spike(name, dt)
    spikes[#spikes + 1] = { name = name, dt = dt, at = GetTime() - startedAt }
    table.sort(spikes, ByTime)
    if #spikes > SPIKES then spikes[#spikes] = nil end
    if #spikes == SPIKES then spikeMin = spikes[SPIKES].dt end
end

local function Note(row, dt)
    -- Another addon calling debugprofilestart in between makes dt negative: not a measurement.
    if dt < 0 then skipped = skipped + 1 return end
    row.calls = row.calls + 1
    row.total = row.total + dt
    if dt > row.max then row.max = dt end
    if dt > spikeMin then Spike(row.name, dt) end
end

local function ReadInstance(now)
    local inside, kind = IsInInstance()
    if inside and ns.Plain(inside) then
        instAt = instAt or now
        if ns.Plain(kind) and type(kind) == "string" then instKind = kind end
    elseif instAt then
        instTime, instAt = instTime + now - instAt, nil
    end
end

-- Combat and instance time for the report header; the handlers are the only clock needed.
local function Context(event)
    local now = GetTime()
    if event == "PLAYER_REGEN_DISABLED" then
        combatAt = combatAt or now
    elseif event == "PLAYER_REGEN_ENABLED" then
        if combatAt then combatTime, combatAt = combatTime + now - combatAt, nil end
    else
        ReadInstance(now)
    end
end

-- The OnEvent closure that times each call of listener l, one row per event.
local function Timed(l)
    local handlers, byEvent, label = l.handlers, l.rows, l.label
    return function(_, event, ...)
        local t0 = profilestop()
        handlers[event](...)
        local dt = profilestop() - t0
        local row = byEvent[event]
        if not row then
            row = NewRow(label .. ":" .. event)
            byEvent[event] = row
        end
        Note(row, dt)
        if event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED"
            or event == "PLAYER_ENTERING_WORLD" then
            Context(event)
        end
    end
end

local function Done(row, t0, ...)
    Note(row, profilestop() - t0)
    return ...
end

-- fn with every call timed under label. A nested row is already inside a handler's time.
local function Wrap(label, fn, nested)
    return function(...)
        if not Perf.on then return fn(...) end
        local row = extra[label]
        if not row then
            row = NewRow(label, nested)
            extra[label] = row
        end
        return Done(row, profilestop(), fn(...))
    end
end

-- A function that runs outside the handlers (a ticker, an OnUpdate): timed when profiling is
-- on at the moment it is handed out, the plain function otherwise.
function Perf.Fn(label, fn)
    if not Perf.on then return fn end
    return Wrap(label, fn)
end

-- tbl[key] is wrapped while profiling. Callers must reach it through the table, not a local.
function Perf.Probe(tbl, key, label, nested)
    probes[#probes + 1] = { tbl = tbl, key = key, label = label, nested = nested }
end

Perf.Probe(ns, "Seal", "Core:Seal", true)
Perf.Probe(ns, "Encode", "Core:Encode", true)
Perf.Probe(ns, "Toggle", "UI:Toggle")

local function AddonKB()
    local api = _G.C_AddOns
    local update = api and api.UpdateAddOnMemoryUsage or _G.UpdateAddOnMemoryUsage
    local get = api and api.GetAddOnMemoryUsage or _G.GetAddOnMemoryUsage
    if type(update) ~= "function" or type(get) ~= "function" then return end
    local ok, kb = pcall(function()
        update()
        return get(ADDON)
    end)
    if ok and type(kb) == "number" then return kb end
end

function Perf.Start()
    if Perf.on then return true end
    if type(profilestop) ~= "function" then return false end
    wipe(rows)
    wipe(extra)
    wipe(spikes)
    spikeMin, skipped, combatTime, instTime, instKind = 0, 0, 0, 0, nil
    for _, l in ipairs(listeners) do
        l.rows = {}
        l.frame:SetScript("OnEvent", Timed(l))
    end
    for _, p in ipairs(probes) do
        local fn = p.tbl[p.key]
        if type(fn) == "function" then
            p.orig, p.wrapped = fn, Wrap(p.label, fn, p.nested)
            p.tbl[p.key] = p.wrapped
        end
    end
    startedAt, stoppedAt = GetTime(), nil
    combatAt = InCombatLockdown() and startedAt or nil
    instAt = nil
    ReadInstance(startedAt)
    startKB, startHeap = AddonKB(), collectgarbage("count")
    Perf.on = true
    return true
end

function Perf.Stop()
    if not Perf.on then return end
    Perf.on = false
    stoppedAt = GetTime()
    if combatAt then combatTime, combatAt = combatTime + stoppedAt - combatAt, nil end
    if instAt then instTime, instAt = instTime + stoppedAt - instAt, nil end
    for _, l in ipairs(listeners) do l.frame:SetScript("OnEvent", l.plain) end
    for _, p in ipairs(probes) do
        -- Leave it alone if another addon replaced our wrapper meanwhile.
        if p.wrapped and p.tbl[p.key] == p.wrapped then p.tbl[p.key] = p.orig end
        p.orig, p.wrapped = nil, nil
    end
end

-- Seconds the last run covered, nil before the first.
function Perf.Seconds()
    if not (stoppedAt or Perf.on) then return nil end
    return (stoppedAt or GetTime()) - startedAt
end

local function ClientMetrics()
    local prof, enum = _G.C_AddOnProfiler, _G.Enum and _G.Enum.AddOnProfilerMetric
    if not (prof and prof.GetAddOnMetric and type(enum) == "table") then return end
    local names = {}
    for name in pairs(enum) do names[#names + 1] = name end
    table.sort(names)
    local out = {}
    for _, name in ipairs(names) do
        local ok, v = pcall(prof.GetAddOnMetric, ADDON, enum[name])
        if ok and type(v) == "number" then out[#out + 1] = format("%s %.2f", name, v) end
    end
    return #out > 0 and concat(out, ", ") or nil
end

local function ByTotal(a, b)
    if a.total ~= b.total then return a.total > b.total end
    return a.name < b.name
end

-- The report as plain text for pasting into a chat. It holds counts and times and names of
-- handlers, never a player, guild, chat or item name.
function Perf.Report()
    local secs = Perf.Seconds()
    if not secs then return nil end
    local now = stoppedAt or GetTime()
    local out = {}
    local version, build, _, toc = GetBuildInfo()
    out[#out + 1] = format("Scarlet %s profile, client %s build %s, interface %s", ns.VERSION, tostring(version),
        tostring(build), tostring(toc))
    local combat = combatTime + (combatAt and now - combatAt or 0)
    local inst = instTime + (instAt and now - instAt or 0)
    out[#out + 1] = format("ran %.1f s%s, combat %.1f s, instance %.1f s%s", secs, Perf.on and " (still running)" or "",
        combat, inst, instKind and (" (" .. instKind .. ")") or "")

    local list, handlerMs, calls = {}, 0, 0
    for _, row in ipairs(rows) do
        if row.calls > 0 then
            list[#list + 1] = row
            calls = calls + row.calls
            if not row.nested then handlerMs = handlerMs + row.total end
        end
    end
    table.sort(list, ByTotal)
    out[#out + 1] = format("timed %d calls, %.1f ms in total, %.2f ms per second of play", calls, handlerMs,
        secs > 0 and handlerMs / secs or 0)
    if skipped > 0 then out[#out + 1] = format("skipped %d calls (another addon reset the timer)", skipped) end

    out[#out + 1] = ""
    out[#out + 1] = "handlers by total time:"
    local shown = math.min(#list, MAX_ROWS)
    for i = 1, shown do
        local r = list[i]
        out[#out + 1] = format("%s  calls %d  total %.2f ms  avg %.1f us  max %.2f ms", r.name, r.calls, r.total,
            r.total / r.calls * 1000, r.max)
    end
    if #list > shown then
        local rest = 0
        for i = shown + 1, #list do rest = rest + list[i].total end
        out[#out + 1] = format("%d more handlers, %.2f ms in total", #list - shown, rest)
    end

    out[#out + 1] = ""
    out[#out + 1] = "slowest single calls:"
    for i, s in ipairs(spikes) do
        out[#out + 1] = format("%d. %.2f ms  %s  at %.1f s", i, s.dt, s.name, s.at)
    end

    out[#out + 1] = ""
    out[#out + 1] = "memory:"
    local kb, heap = AddonKB(), collectgarbage("count")
    if kb and startKB then
        out[#out + 1] = format("Scarlet: %.0f KB at start, %.0f KB now (%+.0f KB)", startKB, kb, kb - startKB)
    elseif kb then
        out[#out + 1] = format("Scarlet: %.0f KB now", kb)
    else
        out[#out + 1] = "Scarlet: this client has no GetAddOnMemoryUsage"
    end
    out[#out + 1] = format("Lua heap, all addons: %.0f KB at start, %.0f KB now (%+.0f KB)", startHeap, heap,
        heap - startHeap)
    local client = ClientMetrics()
    if client then
        out[#out + 1] = ""
        out[#out + 1] = "client profiler, Scarlet: " .. client
    end

    out[#out + 1] = ""
    out[#out + 1] = "not timed: C_Timer callbacks, hooks on game functions, the Addons and Map event frames. "
        .. "Core:Seal and Core:Encode are inside the handler that sealed and are left out of the total. "
        .. "Tickers and the map update are timed only when they started after profiling did."
    return concat(out, "\n")
end

-- Route each event to handlers[event] and register every event the client
-- knows. Unknown events are skipped, so one bad name never breaks loading.
-- label names the file in the profiler's rows. lazy is a set of events left unregistered here:
-- the file registers them itself while it has a use for them.
function ns.Listen(frame, handlers, label, lazy)
    local plain = function(_, event, ...) handlers[event](...) end
    frame:SetScript("OnEvent", plain)
    listeners[#listeners + 1] = { label = label or "?", frame = frame, handlers = handlers, plain = plain }
    local valid = C_EventUtils and C_EventUtils.IsEventValid
    for event in pairs(handlers) do
        if (not lazy or not lazy[event]) and (not valid or valid(event)) then
            if UNIT_EVENTS[event] then
                frame:RegisterUnitEvent(event, "player")
            else
                frame:RegisterEvent(event)
            end
        end
    end
end

local MAIL_INFO = Enum.PlayerInteractionType and Enum.PlayerInteractionType.MailInfo or 17

local function DispatchMailClosed(_, _, kind)
    if not (ns.Plain(kind) and kind == MAIL_INFO) then return end
    for _, l in ipairs(listeners) do
        if l.handlers.MAIL_CLOSED then l.frame:GetScript("OnEvent")(l.frame, "MAIL_CLOSED") end
    end
end

local mailCloser = CreateFrame("Frame")
mailCloser:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
mailCloser:SetScript("OnEvent", DispatchMailClosed)

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffff2d55Scarlet|r " .. msg)
end
