local _, ns = ...

if not ns.FEATS then return end

local floor, min, max, format = math.floor, math.min, math.max, string.format
local Plain = ns.Plain

local Feats = {}
ns.Feats = Feats

local FLUSH_SECONDS, CLOCK_SECONDS = 1, 60
local KEEP_SESSIONS = 30
local PACE_MIN_PLAYED = 300
local NEAR_LISTED = 3
local CAST_TRIES = 3

local byKey, visible = {}, {}
local watching, clocks, onceAt = {}, {}, {}
local exactSpells, prefixSpells = {}, {}
local castCache, castTries = {}, {}
local tier0, known, touched, changed = {}, {}, {}, {}
local dirty, hooks = {}, { tier = {}, move = {} }
local cur, myClass
local pending, clockAt = false, 0
local playedAt, playedVal = -1, 0
local indexed = false

for _, f in ipairs(ns.FEATS) do byKey[f.key] = f end

local function ClassName()
    local _, token = UnitClass("player")
    if not Plain(token) or type(token) ~= "string" or token == "" then return end
    return token:sub(1, 1) .. token:sub(2):lower()
end

local function InRole(f)
    local classes = ns.FEAT_ROLE_CLASSES and ns.FEAT_ROLE_CLASSES[f.role]
    if not classes then return false end
    for i = 1, #classes do
        if classes[i] == myClass then return true end
    end
    return false
end

local function Holder(f)
    if f.scope == "general" then return true end
    if f.scope == "role" then return InRole(f) end
    return f.class == myClass
end

local function SpecRoles(spec)
    local classRoles = ns.FEAT_SPEC_ROLES and ns.FEAT_SPEC_ROLES[myClass]
    return classRoles and spec and classRoles[spec]
end

local function GateHolds(f, spec)
    local gate = f.live and f.live.gate
    if gate == "spec" then return spec ~= nil and spec == f.tree end
    if gate == "role" then
        local roles = SpecRoles(spec)
        if not roles then return false end
        for i = 1, #roles do
            if roles[i] == f.role then return true end
        end
        return false
    end
    return true
end

local function SessionSpec()
    if cur and not cur.spec and ns.specName then cur.spec = ns.specName end
    return cur and cur.spec or ns.specName
end

local function Holds(f)
    return GateHolds(f, SessionSpec())
end

local function FileRow(key)
    local d = _G.ScarletFeats
    local c = type(d) == "table" and type(d.chars) == "table" and d.chars[ns.charKey]
    local f = type(c) == "table" and type(c.f) == "table" and c.f[key]
    return type(f) == "table" and f or nil
end

local function FileChar()
    local d = _G.ScarletFeats
    local c = type(d) == "table" and type(d.chars) == "table" and d.chars[ns.charKey]
    return type(c) == "table" and c or nil, type(d) == "table" and d or nil
end

local function Played()
    if not cur then return 0 end
    local now = GetTime()
    if now - playedAt < 1 then return playedVal end
    local row = ns.Ov and ns.Ov.Live()
    if row and type(row.p) == "number" then playedVal = row.p end
    playedAt = now
    cur.secs = playedVal
    SessionSpec()
    return playedVal
end

local function Sum(source, keys)
    local s = 0
    for i = 1, #keys do s = s + (source[keys[i]] or 0) end
    return s
end

local function ClockSeconds(f)
    local ch = ns.char
    local total = 0
    for _, e in pairs(ch.live) do
        if GateHolds(f, e.spec) then total = total + (e.secs or 0) end
    end
    for spec, secs in pairs(ch.liveBase.secs) do
        if GateHolds(f, spec ~= "?" and spec or nil) then total = total + secs end
    end
    return total
end

local function OnceCount(f)
    local ch, n = ns.char, 0
    local at = f.live.once_at
    for _, e in pairs(ch.live) do
        if (e.secs or 0) >= at and GateHolds(f, e.spec) then n = n + 1 end
    end
    return n + (ch.liveBase.once[tostring(at)] or 0)
end

local function Tallied(f)
    local ch, n = ns.char, 0
    local key = f.key
    for _, e in pairs(ch.live) do n = n + (e.c[key] or 0) end
    return n + (ch.liveBase.c[key] or 0)
end

local function BeforeDeaths()
    local d = _G.ScarletDigest
    local c = type(d) == "table" and type(d.chars) == "table" and d.chars[ns.charKey]
    local before = type(c) == "table" and c.before
    return type(before) == "table" and tonumber(before.deaths) or 0
end

--- A feat's value in the units of its thresholds, from the app's file plus what the addon counted since.
function Feats.Value(key)
    local f = byKey[key]
    local ch = ns.char
    if not f or not ch or not ch.live then return 0 end
    local row = FileRow(key)
    local v = row and tonumber(row.v) or 0
    local live = f.live
    if not live then return v end
    local kind, per = live.kind, live.per or 1
    if kind == "counter" then
        if live.gate == "spec" or live.gate == "role" then return v + Tallied(f) / per end
        return v + max(0, Sum(ch, live.keys) - (row and tonumber(row.b) or 0)) / per
    elseif kind == "session" then
        return max(v, Sum(ns.sess, live.keys) / per)
    elseif kind == "level" then
        local level = UnitLevel("player")
        if f.key == "unbroken" and (ch.deaths or 0) + BeforeDeaths() > 0 then return v end
        return max(v, Plain(level) and type(level) == "number" and level or 0)
    elseif kind == "money" then
        local copper = _G.GetMoney and GetMoney()
        return max(v, Plain(copper) and type(copper) == "number" and copper / (live.per or 10000) or 0)
    elseif kind == "clock" then
        Played()
        if live.once_at then return v + OnceCount(f) end
        return v + ClockSeconds(f) / per
    elseif kind == "cast" then
        return v + Tallied(f)
    end
    return v
end

local function TierOf(f, value)
    local t, n = f.thresholds, 0
    for i = 1, #t do
        if value >= t[i] then n = i else break end
    end
    return n
end

--- Tier 0..5 and the value of a feat now.
function Feats.Tier(key)
    local f = byKey[key]
    if not f then return 0, 0 end
    local value = Feats.Value(key)
    return TierOf(f, value), value
end

function Feats.Family(key)
    local f = byKey[key]
    return f and f.family
end

function Feats.Def(key)
    return byKey[key]
end

function Feats.Visible(f)
    return visible[f.key] == true
end

--- What a count reads as in the feat's own words: "9,912 kills".
function Feats.Count(f, value)
    local whole = floor(value + 0.0001)
    local text
    if value < 100 and value ~= whole then
        text = format("%.1f", value)
    else
        text = ns.UI.Num(value)
    end
    return text .. " " .. (whole == 1 and value == whole and f.one or f.many)
end

--- Where a value stands between its last threshold and the next, 0..1.
function Feats.Progress(f, value, tier)
    local nextAt = f.thresholds[tier + 1]
    if not nextAt then return 1 end
    local from = tier > 0 and f.thresholds[tier] or 0
    return max(0, min(1, (value - from) / (nextAt - from)))
end

--- Value, tier, the next threshold, how far it is and progress for one feat; nil for an unknown key.
function Feats.Info(key)
    local f = byKey[key]
    if not f then return end
    local value = Feats.Value(key)
    local tier = TierOf(f, value)
    local nextAt = f.thresholds[tier + 1]
    return { def = f, value = value, tier = tier, next = nextAt, left = nextAt and nextAt - value or nil,
        progress = Feats.Progress(f, value, tier) }
end

--- Calls fn(def, value, tier, from) when a feat the session moves reaches a tier.
function Feats.OnTier(fn) hooks.tier[#hooks.tier + 1] = fn end

--- Calls fn(def, value, tier) when a feat's own counter has moved, at most once a second for each.
function Feats.OnMove(fn) hooks.move[#hooks.move + 1] = fn end

local function Check(f)
    local value = Feats.Value(f.key)
    local tier = TierOf(f, value)
    local was = known[f.key] or 0
    if tier > was then
        known[f.key] = tier
        local first = changed[f.key]
        changed[f.key] = { key = f.key, from = first and first.from or was, tier = tier, at = floor(ns.Recap.Elapsed()),
            value = value }
        ns.Recap.Moment("feat", format("%s reached %s", f.name, ns.FEAT_TIER_NAMES[tier] or ""), f.key, tier)
        for i = 1, #hooks.tier do hooks.tier[i](f, value, tier, was) end
    end
    for i = 1, #hooks.move do hooks.move[i](f, value, tier) end
end

local function Flush()
    pending = false
    if not cur then return end
    for f in pairs(dirty) do
        dirty[f] = nil
        Check(f)
    end
    local now = GetTime()
    if now - clockAt >= CLOCK_SECONDS then
        clockAt = now
        for i = 1, #clocks do
            touched[clocks[i]] = true
            Check(clocks[i])
        end
    end
end

local function Schedule()
    if pending then return end
    pending = true
    C_Timer.After(FLUSH_SECONDS, Flush)
end

local function Moved(key, n)
    if not cur then return end
    local list = watching[key]
    for i = 1, #list do
        local f = list[i]
        local live = f.live
        if (live.gate == "spec" or live.gate == "role") and live.kind == "counter" and Holds(f) then
            local c = cur.c
            c[f.key] = (c[f.key] or 0) + n
        end
        touched[f] = true
        dirty[f] = true
    end
    Schedule()
end

local function Resolve(id)
    local name
    if C_Spell and C_Spell.GetSpellName then
        local ok, got = pcall(C_Spell.GetSpellName, id)
        if ok and Plain(got) and type(got) == "string" and got ~= "" then name = got end
    end
    if not name then return nil end
    local hit = exactSpells[name]
    for i = 1, #prefixSpells do
        local p = prefixSpells[i]
        if name:sub(1, #p.prefix) == p.prefix then
            hit = hit or {}
            hit[#hit + 1] = p.feat
        end
    end
    return hit or false
end

--- A cast went through (called from the cast handler): counts it toward the cast feats of this class.
function Feats.Cast(id)
    if not cur or not Plain(id) or type(id) ~= "number" then return end
    local hit = castCache[id]
    if hit == nil then
        hit = Resolve(id)
        if hit == nil then
            local tries = (castTries[id] or 0) + 1
            castTries[id] = tries
            if tries < CAST_TRIES then return end
            hit = false
        end
        castCache[id] = hit
        if hit then
            local spells = ns.char.featSpell or {}
            ns.char.featSpell = spells
            for i = 1, #hit do spells[hit[i].key] = spells[hit[i].key] or id end
        end
    end
    if not hit then return end
    local c = cur.c
    for i = 1, #hit do
        local f = hit[i]
        touched[f] = true
        if Holds(f) then c[f.key] = (c[f.key] or 0) + 1 end
        dirty[f] = true
    end
    Schedule()
end

local function Index()
    indexed = true
    local seen = {}
    for _, f in ipairs(ns.FEATS) do
        if Holder(f) then
            visible[f.key] = true
            local live = f.live
            if live then
                local kind = live.kind
                if kind == "counter" or kind == "session" then
                    for _, k in ipairs(live.keys or {}) do
                        watching[k] = watching[k] or {}
                        watching[k][#watching[k] + 1] = f
                    end
                elseif kind == "level" then
                    watching.levels = watching.levels or {}
                    watching.levels[#watching.levels + 1] = f
                elseif kind == "money" then
                    for _, k in ipairs({ "earned", "spent", "sold" }) do
                        watching[k] = watching[k] or {}
                        watching[k][#watching[k] + 1] = f
                    end
                elseif kind == "clock" then
                    clocks[#clocks + 1] = f
                    if live.once_at and not seen[live.once_at] then
                        seen[live.once_at] = true
                        onceAt[#onceAt + 1] = live.once_at
                    end
                elseif kind == "cast" then
                    for _, name in ipairs(f.spells or {}) do
                        if name:sub(-1) == "*" then
                            prefixSpells[#prefixSpells + 1] = { prefix = name:sub(1, -2), feat = f }
                        else
                            exactSpells[name] = exactSpells[name] or {}
                            exactSpells[name][#exactSpells[name] + 1] = f
                        end
                    end
                end
            end
        end
    end
    for key in pairs(watching) do
        ns.AddWatch[key] = Moved
    end
end

local function Fold(ch)
    local keys = {}
    for t in pairs(ch.live) do keys[#keys + 1] = t end
    table.sort(keys)
    local base = ch.liveBase
    while #keys > KEEP_SESSIONS - 1 do
        local t = table.remove(keys, 1)
        local e = ch.live[t]
        ch.live[t] = nil
        local spec = e.spec or "?"
        base.secs[spec] = (base.secs[spec] or 0) + (e.secs or 0)
        for key, n in pairs(e.c) do base.c[key] = (base.c[key] or 0) + n end
        for _, at in ipairs(onceAt) do
            if (e.secs or 0) >= at then base.once[tostring(at)] = (base.once[tostring(at)] or 0) + 1 end
        end
        base.t = max(base.t or 0, t)
    end
end

--- A session begins at its row's time t: the tiers it starts from, and the tallies it adds to.
function Feats.Start(t)
    local ch = ns.char
    if not ch then return end
    myClass = myClass or ClassName()
    if not indexed and myClass then Index() end
    local live = type(ch.live) == "table" and ch.live or {}
    ch.live = live
    local base = type(ch.liveBase) == "table" and ch.liveBase or {}
    ch.liveBase = base
    base.secs, base.c, base.once = base.secs or {}, base.c or {}, base.once or {}
    local file = FileChar()
    local through = file and tonumber(file.through) or 0
    if through > 0 then
        for key in pairs(live) do
            if key <= through then live[key] = nil end
        end
        if (base.t or 0) <= through then
            base.secs, base.c, base.once, base.t = {}, {}, {}, 0
        end
    end
    Fold(ch)
    live[t] = live[t] or { secs = 0, c = {} }
    cur = live[t]
    cur.c = cur.c or {}
    playedAt, pending, clockAt = -1, false, GetTime()
    for key in pairs(dirty) do dirty[key] = nil end
    for key in pairs(touched) do touched[key] = nil end
    for key in pairs(changed) do changed[key] = nil end
    for key in pairs(tier0) do tier0[key] = nil end
    for key in pairs(known) do known[key] = nil end
    for _, f in ipairs(ns.FEATS) do
        if visible[f.key] and f.live then
            local tier = TierOf(f, Feats.Value(f.key))
            tier0[f.key], known[f.key] = tier, tier
        end
    end
end

local function Delta(f, played)
    local live = f.live
    local kind, per = live.kind, live.per or 1
    if kind == "counter" then
        if live.gate == "spec" or live.gate == "role" then return (cur.c[f.key] or 0) / per end
        return Sum(ns.sess, live.keys) / per
    elseif kind == "cast" then
        return cur.c[f.key] or 0
    elseif kind == "clock" and not live.once_at and GateHolds(f, SessionSpec()) then
        return played / per
    end
end

--- The session's feats as a recap holds them: tiers reached, and the three closest to the next tier.
function Feats.Changes()
    local out = { earned = {}, near = {} }
    if not cur then return out end
    local played = Played()
    for key, c in pairs(changed) do
        out.earned[#out.earned + 1] = { key = key, from = c.from, tier = c.tier, at = c.at, value = c.value }
    end
    table.sort(out.earned, function(a, b) return a.at < b.at end)
    local near = {}
    for f in pairs(touched) do
        local delta = Delta(f, played)
        if delta and delta > 0 and (played >= PACE_MIN_PLAYED or f.live.kind ~= "clock") then
            local value = Feats.Value(f.key)
            local tier = TierOf(f, value)
            local nextAt = f.thresholds[tier + 1]
            if nextAt then
                local left = nextAt - value
                local secs
                if played >= PACE_MIN_PLAYED then secs = left / (delta / played) end
                near[#near + 1] = { key = f.key, tier = tier, value = value, next = nextAt, left = left,
                    rank = secs or (1e9 + left / nextAt * 1e6) }
            end
        end
    end
    table.sort(near, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.key < b.key
    end)
    for i = 1, min(NEAR_LISTED, #near) do
        local n = near[i]
        out.near[i] = { key = n.key, tier = n.tier, value = n.value, next = n.next, left = n.left }
    end
    return out
end

local function Row(f, tier, value, line, ghost)
    local spells = ns.char and ns.char.featSpell
    return { name = f.name, line = line, progress = Feats.Progress(f, value, tier), tier = tier, family = f.family,
        glyph = f.glyph, spell = spells and spells[f.key], ghost = ghost, key = f.key }
end

--- Rows for the Feats column of a recap: the tiers it earned, then the feats it moved closest to the next tier.
function Feats.SessionRows(recap)
    local feats = recap and recap.feats
    local rows = {}
    if type(feats) ~= "table" then return rows end
    local Num = ns.UI.Num
    for _, e in ipairs(feats.earned or {}) do
        local f = byKey[e.key]
        if f and #rows < 3 then
            rows[#rows + 1] = Row(f, e.tier, e.value or 0, format("Reached %s · %s", ns.FEAT_TIER_NAMES[e.tier] or "",
                Feats.Count(f, e.value or 0)))
        end
    end
    for _, n in ipairs(feats.near or {}) do
        local f = byKey[n.key]
        if f and #rows < 3 then
            rows[#rows + 1] = Row(f, n.tier, n.value or 0, format("%s · %s to %s", Feats.Count(f, n.value or 0),
                Num(n.left or 0), ns.FEAT_TIER_NAMES[n.tier + 1] or ""))
        end
    end
    return rows
end

--- The tiers this session started from, by feat key.
function Feats.StartTier(key)
    return tier0[key] or 0
end

--- The app's counts for this character: held, total, score, pins, source and the newest session they cover.
function Feats.File()
    local c, d = FileChar()
    if not c then return nil end
    return { held = c.held, total = c.total, score = c.score, pins = c.pins, through = c.through, spec = c.spec,
        source = d and d.source, made = d and d.made, new = c.new }
end

function Feats.Command(rest)
    local ui = ns.UI
    local live, above = 0, 0
    for _, f in ipairs(ns.FEATS) do
        if visible[f.key] and f.live then
            live = live + 1
            if Feats.Tier(f.key) > 0 then above = above + 1 end
        end
    end
    local key = rest and rest:match("^(%S+)")
    local f = key and byKey[key]
    if key and not f then
        ns.Print("no feat called " .. key)
        return
    end
    if f then
        local info = Feats.Info(f.key)
        ns.Print(format("%s: %s, %s%s", f.name, Feats.Count(f, info.value),
            info.tier > 0 and (ns.FEAT_TIER_NAMES[info.tier] .. " held") or "no tier yet",
            info.left and format(", %s to %s", ui.Num(info.left), ns.FEAT_TIER_NAMES[info.tier + 1]) or ""))
        return
    end
    ns.Print(format("%d feats move while you play; %d are at Copper or better.", live, above))
    local info = Feats.Info("slayer")
    if info then ns.Print("slayer " .. Feats.Count(info.def, info.value)) end
end
