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
