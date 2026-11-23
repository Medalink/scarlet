local _, ns = ...
local UI = ns.UI
local TIERS = ns.Tiers
local LOOK = TIERS.look

local floor, min, max = math.floor, math.min, math.max

local CRESTS = "Interface\\AddOns\\Scarlet\\Media\\Crests.tga"

local SHIELD = { character = 1, class = 2, account = 3 }
local SIDE = { character = 9, class = 10, account = 11 }
local GLYPH_Y = { character = 45.5, class = 47, account = 47 }
local RING, CROWN, GREAT, GEM, BANNER, RAYS = 4, 5, 6, 7, 8, 12
local RAYS_BACK, CROWN_BACK, GREAT_BACK, BANNER_BACK = 13, 14, 15, 16

local BOX = {
    { 24, 25, 72, 77 }, { 24, 25, 72, 75 }, { 23, 25, 73, 75 }, { 18.2, 20.2, 77.8, 79.8 },
    { 32, 11, 64, 29 }, { 28.5, 8.5, 67.5, 29 }, { 44.4, 20.4, 51.6, 28.8 }, { 15, 66, 81, 77 },
    { 7, 10, 89, 66 }, { 6, 24, 90, 76 }, { 6, 16, 90, 88 }, { 14, 5, 82, 28 },
}
local UP, RIGHT, OUT = 1, 2, 3
local DIR = { UP, UP, UP, UP, RIGHT, RIGHT, UP, RIGHT, OUT, OUT, UP, UP }
local COL, ROW, UV = {}, {}, {}
for c = 1, 16 do
    COL[c], ROW[c] = (c - 1) % 4, floor((c - 1) / 4)
    UV[c] = { COL[c] / 4, (COL[c] + 1) / 4, ROW[c] / 4, (ROW[c] + 1) / 4 }
end

local S_SIDE, S_SIDE_FILL, S_RAYS_BACK, S_RAYS, S_RAYS_FILL, S_GAP, S_RING, S_RIM, S_INSET, S_INNER, S_FIELD, S_FILL,
    S_GLYPH, S_BANNER_BACK, S_BANNER, S_BANNER_FILL, S_BAND, S_CROWN_BACK, S_CROWN, S_CROWN_FILL, S_SETTING, S_GEM,
    S_FLASH = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23
local SLOTS = 23

local INK, WHITE, CLEAR = LOOK.ink, LOOK.white, LOOK.clear
local BAND, GEM_BOX, GEM_AT, GEM_SETTING = LOOK.band, LOOK.gemBox, LOOK.gemAt, LOOK.gemSetting
local CREST_Y = 50
local ATTACH = { "shield", "crown", "banner", "side", "rays" }
local ATTACH_AT, ATTACH_SECONDS, FLASH_AT, FLASH_SECONDS, GHOST_SECONDS = 0, 0.32, 0.28, 0.42, 0.3

local spellTex = {}

local function SpellTexture(id)
    local tex = spellTex[id]
    if tex then return tex end
    local api = _G.C_Spell
    if not (id and api and api.GetSpellTexture) then return end
    local ok, got = pcall(api.GetSpellTexture, id)
    if ok and ns.Plain(got) and got then
        spellTex[id] = got
        return got
    end
end

local function SetScale(a, x, y)
    if a.SetScaleFrom then
        a:SetScaleFrom(x, y)
        a:SetScaleTo(1, 1)
    elseif a.SetFromScale then
        a:SetFromScale(x, y)
        a:SetToScale(1, 1)
    end
end

local function Rest(r)
    if r.moved then
        r.moved = false
        r:SetPoint("CENTER", r:GetParent(), "CENTER", 0, r.ry)
    end
    if r.fin then
        r.fin = false
        r:SetAlpha(1)
    end
end

local function Run(f, r, from, to, sx, sy, dy, secs, delay, smooth)
    local g = r.ag
    if not g then
        g = r:CreateAnimationGroup()
        g.alpha = g:CreateAnimation("Alpha")
        g.scale = g:CreateAnimation("Scale")
        g.move = g:CreateAnimation("Translation")
        g:SetScript("OnFinished", function() Rest(r) end)
        r.ag = g
    end
    g:Stop()
    f.busy = true
    local a, s, m = g.alpha, g.scale, g.move
    a:SetFromAlpha(from)
    a:SetToAlpha(to)
    SetScale(s, sx, sy)
    m:SetOffset(0, dy)
    a:SetDuration(secs)
    a:SetStartDelay(delay)
    a:SetSmoothing(smooth)
    s:SetDuration(secs)
    s:SetStartDelay(delay)
    s:SetSmoothing(smooth)
    m:SetDuration(secs)
    m:SetStartDelay(delay)
    m:SetSmoothing(smooth)
    g:Play()
end

local function Make(f, i)
    local layer, sub = "BACKGROUND", i - 9
    if i > 16 then layer, sub = "BORDER", i - 17 end
    local t = f:CreateTexture(nil, layer, nil, sub)
    if i ~= S_GLYPH then t:SetTexture(CRESTS) end
    if i == S_FLASH then t:SetBlendMode("ADD") end
    t.on, t.ag, t.moved, t.fin, t.k, t.cell, t.src, t.icon, t.gsize, t.gy, t.gen, t.ry = false, false, false, false, false,
        false, false, false, 0, 0, 0, 0
    t.grad, t.lo, t.hi, t.box, t.bk, t.bc = false, false, false, false, 0, 0
    f.tx[i] = t
    return t
end

local function Flat(t, c, a)
    if t.grad then
        t.grad, t.lo, t.hi = false, false, false
        t:SetGradient("VERTICAL", CLEAR, CLEAR)
    end
    t:SetVertexColor(c[1], c[2], c[3], a)
end

local function Grade(t, lo, hi)
    if not t.grad then
        t.grad = true
        t:SetVertexColor(1, 1, 1, 1)
    end
    if t.lo ~= lo or t.hi ~= hi then
        t.lo, t.hi = lo, hi
        t:SetGradient("VERTICAL", lo, hi)
    end
end

local function Use(f, t)
    t.gen = f.gen
    if not t.on then
        t.on = true
        t:Show()
    end
end

local function Place(f, t, k)
    local u = f.u
    t:SetSize(96 * u * k, 96 * u * k)
    t.ry = -(f.off + 2 * (1 - k) * u)
    t:SetPoint("CENTER", f, "CENTER", 0, t.ry)
    t.k = k
end

local function Put(f, i, cell, k, c, a)
    local t = f.tx[i] or Make(f, i)
    if t.cell ~= cell then
        t.cell, t.box = cell, false
        local uv = UV[cell]
        t:SetTexCoord(uv[1], uv[2], uv[3], uv[4])
    end
    if t.k ~= k then
        Place(f, t, k)
        t.box = false
    end
    Flat(t, c, a)
    Use(f, t)
    return t
end

local function Cut(f, i, cell, box, k, ay)
    local t = f.tx[i] or Make(f, i)
    if t.box ~= box or t.bk ~= k or t.bc ~= cell then
        t.box, t.bk, t.bc = box, k, cell
        local l, top, r, b = box[1], box[2], box[3], box[4]
        local col, row, u = COL[cell], ROW[cell], f.u
        t:SetTexCoord((col + l / 96) / 4, (col + r / 96) / 4, (row + top / 96) / 4, (row + b / 96) / 4)
        t:SetSize((r - l) * k * u, (b - top) * k * u)
        local y = ay + k * ((top + b) / 2 - ay)
        t.ry = -f.off - (y - 48) * u
        t:SetPoint("CENTER", f, "CENTER", (k * ((l + r) / 2 - 48)) * u, t.ry)
        t.cell, t.k = false, false
    end
    return t
end

local function Made(f, i, cell, material)
    local t = Cut(f, i, cell, BOX[cell], 1, CREST_Y)
    Grade(t, material.lo, material.hi)
    Use(f, t)
    return t
end

local function Enamel(f, i, cell, k, pair)
    local t = Cut(f, i, cell, BOX[cell], k, CREST_Y)
    Grade(t, pair.lo, pair.hi)
    Use(f, t)
    return t
end

local function Clip(f, i, cell, c, a)
    local p = f.p
    if p <= 0 then return end
    local t = f.tx[i] or Make(f, i)
    local box, dir = BOX[cell], DIR[cell]
    local l, top, r, b = box[1], box[2], box[3], box[4]
    if dir == UP then
        top = b - (b - top) * p
    elseif dir == RIGHT then
        r = l + (r - l) * p
    else
        local d = (24 - l) * p
        l, r = 24 - d, 72 + d
    end
    local col, row, u = COL[cell], ROW[cell], f.u
    t:SetTexCoord((col + l / 96) / 4, (col + r / 96) / 4, (row + top / 96) / 4, (row + b / 96) / 4)
    t:SetSize((r - l) * u, (b - top) * u)
    t:SetPoint("CENTER", f, "CENTER", ((l + r) / 2 - 48) * u, -f.off - ((top + b) / 2 - 48) * u)
    Flat(t, c, a)
    t.cell, t.k, t.box = false, false, false
    Use(f, t)
    return t
end

local function Ghost(f, slot, fillSlot, cell, color, of)
    local n = f.gn
    local dim = f.p >= LOOK.nearAt and of.near or of.ghost
    f.ghost[n + 1] = Put(f, slot, cell, 1, color, dim)
    f.gn = n + 1
    local t = Clip(f, fillSlot, cell, color, 1)
    if t then
        f.gn = f.gn + 1
        f.ghost[f.gn] = t
    end
end

local function Backed(f, slot, cell)
    local t = Put(f, slot, cell, 1, INK, 1)
    return t
end

local function PutGlyph(f, c, a, compact, tier)
    local t = f.tx[S_GLYPH] or Make(f, S_GLYPH)
    local u = f.u
    local size = 28 * (compact and 1.12 or 1)
    local gy = GLYPH_Y[f.scope] + (compact and tier < 3 and 1.5 or 0)
    local icon = f.spell and SpellTexture(f.spell)
    if icon then
        size = size * 20 / 24
        if t.src ~= icon then
            t.src = icon
            t:SetTexture(icon)
            t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            t:SetDesaturated(true)
        end
    elseif t.src ~= f.glyph or t.icon then
        t.src = f.glyph
        UI.SetGlyph(t, f.glyph)
        t:SetDesaturated(false)
    end
    t.icon = icon ~= nil
    if t.gsize ~= size or t.gy ~= gy then
        t.gsize, t.gy = size, gy
        t:SetSize(size * u, size * u)
        t:SetPoint("CENTER", f, "CENTER", 0, -f.off - (gy - 48) * u)
    end
    t:SetVertexColor(c[1], c[2], c[3], a)
    Use(f, t)
end

local function Draw(f, pending)
    local scope, held, state = f.scope, f.tier, f.state
    local outline = state == "next"
    local tier = outline and min(5, held + 1) or held
    local compact, tiny = f.form ~= "full", f.form == "plain"
    local look = TIERS[tier]
    local coming = TIERS[tier + 1]
    local want = (tier < 5 and not tiny and not outline and not state) and ATTACH[tier + 1] or nil
    local shield, ring = SHIELD[scope], scope == "account"
    local settled = not (pending and tier == 4)
    local from = settled and look or TIERS[tier - 1]
    local mats = pending and tier == 5 and TIERS[4] or look
    f.gen, f.gn = f.gen + 1, 0

    if tier >= 4 and not compact and settled then
        Made(f, S_SIDE, SIDE[scope], look.side)
    elseif want == "side" and not compact then
        Ghost(f, S_SIDE, S_SIDE_FILL, SIDE[scope], coming.color, coming)
    end
    if tier == 5 and not compact and not pending then
        Put(f, S_RAYS_BACK, RAYS_BACK, 1, INK, 1)
        Made(f, S_RAYS, RAYS, look.rays)
    elseif want == "rays" and not compact then
        f.ghost[f.gn + 1] = Backed(f, S_RAYS_BACK, RAYS_BACK)
        f.gn = f.gn + 1
        Ghost(f, S_RAYS, S_RAYS_FILL, RAYS, coming.rays.flat, coming)
    end

    if tier == 0 then
        local k = compact and 0.88 or 0.92
        if ring then Put(f, S_RING, RING, 1, look.color, LOOK.unearnedRim) end
        Put(f, S_RIM, shield, 1, look.color, LOOK.unearnedRim)
        Put(f, S_INSET, shield, k, INK, 1)
        if not tiny then
            Put(f, S_FIELD, shield, k, coming.color, f.p >= LOOK.nearAt and coming.near or 0)
            Clip(f, S_FILL, shield, coming.color, LOOK.unearnedFill)
        end
    else
        local tinted = not tiny and from.field < 1
        if not compact then Put(f, S_GAP, shield, ring and 1.3 or 1.09, INK, 1) end
        if ring then Made(f, S_RING, RING, mats.frame) end
        Made(f, S_RIM, shield, mats.frame)
        Put(f, S_INSET, shield, compact and 0.86 or 0.9, tinted and look.color or INK, 1)
        if tinted then Put(f, S_INNER, shield, compact and 0.78 or 0.85, INK, 1) end
        if not outline then
            if tiny then
                Enamel(f, S_FIELD, shield, 0.8, look.enamel[from.plain])
            elseif from.field >= 1 then
                Enamel(f, S_FIELD, shield, compact and 0.8 or 0.84, look.enamel[1])
            else
                Enamel(f, S_FIELD, shield, compact and 0.78 or 0.85, look.enamel[from.field])
            end
        end
    end

    if not tiny then
        local c, a = TIERS[0].glyph, LOOK.glyphAlpha
        if tier > 0 then
            a = 1
            c = outline and look.color or from.glyph
        end
        PutGlyph(f, c, a, compact, tier)
    end

    if tier >= 3 and not (pending and tier == 3) then
        Backed(f, S_BANNER_BACK, BANNER_BACK)
        Made(f, S_BANNER, BANNER, look.banner)
        local band = Cut(f, S_BAND, BANNER, BAND, 1, CREST_Y)
        Flat(band, look.color, 1)
        Use(f, band)
    elseif want == "banner" then
        f.ghost[f.gn + 1] = Backed(f, S_BANNER_BACK, BANNER_BACK)
        f.gn = f.gn + 1
        Ghost(f, S_BANNER, S_BANNER_FILL, BANNER, coming.color, coming)
    end

    if tier >= 2 and not (pending and tier == 2) then
        local great = tier == 5 and not pending
        Backed(f, S_CROWN_BACK, great and GREAT_BACK or CROWN_BACK)
        Made(f, S_CROWN, great and GREAT or CROWN, mats.crown)
        local setting = Cut(f, S_SETTING, GEM, GEM_BOX, GEM_SETTING, GEM_AT)
        Flat(setting, INK, 1)
        Use(f, setting)
        Put(f, S_GEM, GEM, 1, look.gem, 1)
    elseif want == "crown" then
        f.ghost[f.gn + 1] = Backed(f, S_CROWN_BACK, CROWN_BACK)
        f.gn = f.gn + 1
        Ghost(f, S_CROWN, S_CROWN_FILL, CROWN, coming.color, coming)
    end

    local gen, tx = f.gen, f.tx
    for i = 1, SLOTS do
        local t = tx[i]
        if t and t.on and t.gen ~= gen then
            t.on = false
            t:Hide()
        end
    end
end

local function Settle(f)
    f.busy, f.fin = false, false
    for i = 1, SLOTS do
        local t = f.tx[i]
        if t and t.ag then
            t.ag:Stop()
            Rest(t)
        end
    end
    if f.ag then f.ag:Stop() end
    f:SetAlpha(1)
end

local function Flash(f, cell)
    local t = Put(f, S_FLASH, cell, 1, WHITE, 1)
    t:SetAlpha(0)
    Run(f, t, 0.85, 0, 1, 1, 0, FLASH_SECONDS, FLASH_AT, "NONE")
end

local function Slide(f, slot, dy)
    local t = f.tx[slot]
    if not t then return end
    t.moved = true
    t:SetPoint("CENTER", f, "CENTER", 0, t.ry + dy)
    Run(f, t, 0, 1, 1, 1, -dy, ATTACH_SECONDS, ATTACH_AT, "OUT")
end

local function Grow(f, slot, sx, sy, secs)
    local t = f.tx[slot]
    if not t then return end
    local dy = (sy - 1) * (t.ry + f.off)
    if dy ~= 0 then
        t.moved = true
        t:SetPoint("CENTER", f, "CENTER", 0, t.ry + dy)
    end
    Run(f, t, 0, 1, sx, sy, -dy, secs, ATTACH_AT, "OUT")
end

local Crest = {}

--- Draws the crest. scope is character, class or account; progress 0..1 is the share of the way to the next tier.
--- state "next" draws the next tier with an empty field, "earning" draws the tier without its new piece until Attach.
function Crest.Set(f, scope, glyph, tier, progress, spell, state)
    if f.busy then Settle(f) end
    if state == "earning" and f.form ~= "full" then state = false end
    f.scope = SHIELD[scope] and scope or "character"
    f.glyph, f.tier, f.spell, f.state = glyph or "spell", tier or 0, spell or false, state or false
    f.p = max(0, min(1, progress or 0))
    f.pending = state == "earning"
    Draw(f, f.pending)
    local hidden = f.pending and f.tier == 1
    if hidden or f.hidden then f:SetAlpha(hidden and 0 or 1) end
    f.hidden = hidden
end

--- Plays the attach of the tier's new piece on a crest set as "earning", then its flash.
function Crest.Attach(f)
    if not f.pending then return end
    f.pending = false
    Draw(f, false)
    local tier, u = f.tier, f.u
    local piece = ATTACH[tier]
    f.hidden = false
    if piece ~= "shield" then f:SetAlpha(1) end
    if piece == "shield" then
        f.fin = true
        Run(f, f, 0, 1, 1.35, 1.35, 0, ATTACH_SECONDS, ATTACH_AT, "OUT")
        Flash(f, SHIELD[f.scope])
    elseif piece == "crown" then
        Slide(f, S_CROWN_BACK, 14 * u)
        Slide(f, S_CROWN, 14 * u)
        Slide(f, S_SETTING, 14 * u)
        Slide(f, S_GEM, 14 * u)
        Flash(f, CROWN)
    elseif piece == "banner" then
        Slide(f, S_BANNER_BACK, -12 * u)
        Slide(f, S_BANNER, -12 * u)
        Slide(f, S_BAND, -12 * u)
        Flash(f, BANNER)
    elseif piece == "side" then
        Grow(f, S_SIDE, 0.35, 1, ATTACH_SECONDS)
        Flash(f, SIDE[f.scope])
    elseif piece == "rays" then
        Grow(f, S_RAYS_BACK, 0.55, 0.55, 0.52)
        Grow(f, S_RAYS, 0.55, 0.55, 0.52)
        Flash(f, RAYS)
    end
end

--- Fades in the ghost of the next piece at the real progress, on a crest set as "earning".
function Crest.Reveal(f)
    if f.state ~= "earning" then return end
    f.state = false
    if f.pending then Crest.Attach(f) end
    Draw(f, false)
    for i = 1, f.gn do Run(f, f.ghost[i], 0, 1, 1, 1, 0, GHOST_SECONDS, 0, "OUT") end
end

--- A feat crest of size px. See Crest.Set, Crest.Attach and Crest.Reveal.
function UI.Crest(parent, size)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    f.size = size
    if size >= 44 then
        f.form, f.u, f.off = "full", size / 84, size / 84
    else
        f.form, f.u, f.off = size >= 22 and "compact" or "plain", size / 70, size * 4.5 / 70
    end
    f.tx, f.ghost, f.gen, f.gn = {}, {}, 0, 0
    f.scope, f.glyph, f.tier, f.p, f.spell, f.state = "character", "spell", 0, 0, false, false
    f.busy, f.pending, f.hidden, f.ag, f.fin, f.moved, f.ry = false, false, false, false, false, false, 0
    f.Set, f.Attach, f.Reveal = Crest.Set, Crest.Attach, Crest.Reveal
    return f
end
