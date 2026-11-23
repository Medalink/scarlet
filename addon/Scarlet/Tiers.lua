local _, ns = ...
local KIT = ns.CrestKit

local floor = math.floor

local colors = {}

local function Rgb(hex)
    local c = colors[hex]
    if not c then
        c = { floor(hex / 65536) / 255, floor(hex / 256) % 256 / 255, hex % 256 / 255 }
        colors[hex] = c
    end
    return c
end

local function Shade(c, a)
    return CreateColor(c[1], c[2], c[3], a)
end

local MATERIAL = {}
for name, m in pairs(KIT.material) do
    local t, b = Rgb(m.top), Rgb(m.bottom)
    MATERIAL[name] = { top = t, bottom = b, flat = Rgb(m.flat), hi = Shade(t, 1), lo = Shade(b, 1) }
end

--- The one colour table, built from QUALITY and MATERIAL in the crest kit (ns.CrestKit). ns.Tiers[tier] for tier 0 to 5
--- holds: name (tier 0 prints as "Not earned"); color: the accent (the enamel field's top, the inlay, the band, and
--- every bar, chip and toast accent); deep: the field's foot; frame, crown, banner, side, rays: the material of that
--- piece, where the tier has it (top and bottom colours, hi and lo as colour objects for SetGradient, flat for a
--- ghost); field: the field's opacity (1 is the solid field); plain: the shield's opacity under 22 px; glyph: the
--- glyph's tint; gem: the gem's tint; ghost, near: the opacity of a ghost drawn in this tier's colour, at rest and
--- from look.nearAt; on: text on a solid chip of this colour; enamel[opacity]: lo and hi colour objects of the field
--- at that opacity. ns.Tiers.look holds what the crest draws around the tiers.
ns.Tiers = {}

for tier = 0, 5 do
    local src = KIT.quality[tier]
    local q = { name = KIT.tierNames[tier] }
    for _, key in ipairs({ "color", "deep", "glyph", "gem", "on" }) do
        if src[key] then q[key] = Rgb(src[key]) end
    end
    for _, key in ipairs({ "field", "plain", "ghost", "near" }) do
        q[key] = src[key]
    end
    for _, key in ipairs({ "frame", "crown", "banner", "side", "rays" }) do
        if src[key] then q[key] = MATERIAL[src[key]] end
    end
    ns.Tiers[tier] = q
end

local unearned = KIT.unearned
ns.Tiers.look = {
    ink = Rgb(KIT.ink),
    white = { 1, 1, 1 },
    light = Rgb(KIT.light),
    clear = CreateColor(1, 1, 1, 1),
    glyphAlpha = unearned.glyph,
    unearnedRim = unearned.rim,
    unearnedFill = unearned.fill,
    nearAt = KIT.nearAt,
    band = KIT.band,
    gemBox = KIT.pieces.gem.box,
    gemAt = KIT.gem.at[2],
    gemSetting = KIT.gem.setting,
}

for tier = 1, 5 do
    local q = ns.Tiers[tier]
    q.enamel = {}
    local before = ns.Tiers[tier - 1]
    for _, a in ipairs({ 1, q.field, q.plain, before.field, before.plain }) do
        if a > 0 and not q.enamel[a] then q.enamel[a] = { lo = Shade(q.deep, a), hi = Shade(q.color, a) } end
    end
end

--- A tier's name, or "" past the last.
function ns.TierName(tier)
    local t = ns.Tiers[tier]
    return t and t.name or ""
end
