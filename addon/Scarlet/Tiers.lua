local _, ns = ...

local floor = math.floor

local function Rgb(hex)
    return { floor(hex / 65536) / 255, floor(hex / 256) % 256 / 255, hex % 256 / 255 }
end

local function Shade(c, a)
    return CreateColor(c[1], c[2], c[3], a)
end

local function Material(top, bottom, flat)
    local t, b = Rgb(top), Rgb(bottom)
    return { top = t, bottom = b, flat = Rgb(flat), hi = Shade(t, 1), lo = Shade(b, 1) }
end

local INK, LIGHT = Rgb(0x141416), Rgb(0xf0f1f3)
local POOR, UNCOMMON, RARE, EPIC, LEGENDARY, SCARLET =
    Rgb(0x9d9d9d), Rgb(0x1eff00), Rgb(0x0070dd), Rgb(0xa335ee), Rgb(0xff8000), Rgb(0xff2d55)

local MATERIAL = {
    steel = Material(0xe6e9ef, 0x767c88, 0xaeb4bf),
    pewter = Material(0xa9aeb9, 0x4b4f58, 0x787d89),
    parchment = Material(0xf3ead6, 0xc2b391, 0xddd0b3),
    gold = Material(0xffeaa6, 0xb8872a, 0xe8c060),
}

--- The one colour table, mirroring QUALITY and MATERIAL in the design's crests.js. ns.Tiers[tier] for tier 0 to 5 holds:
--- name (tier 0 prints as "Not earned"); color: the accent (the enamel field's top, the inlay, the band, and every
--- bar, chip and toast accent); deep: the field's foot; frame, crown, banner, side, rays: the material of that piece,
--- where the tier has it (top and bottom colours, hi and lo as colour objects for SetGradient, flat for a ghost);
--- field: the field's opacity (1 is the solid field); plain: the shield's opacity under 22 px; glyph: the glyph's
--- tint; gem: the gem's tint; ghost, near: the opacity of a ghost drawn in this tier's colour, at rest and from
--- look.nearAt; on: text on a solid chip of this colour; enamel[opacity]: lo and hi colour objects of the field at
--- that opacity. ns.Tiers.look holds what the crest draws around the tiers.
ns.Tiers = {
    [0] = { name = "Not earned", color = POOR, field = 0, plain = 0, glyph = POOR, ghost = 0, near = 0, on = INK },
    { name = "Uncommon", color = UNCOMMON, deep = Rgb(0x14b800), frame = "steel", field = 0.22, plain = 0.55,
        glyph = LIGHT, ghost = 0.12, near = 0.3, on = INK },
    { name = "Rare", color = RARE, deep = Rgb(0x004f9e), frame = "steel", crown = "steel", field = 0.45, plain = 1,
        glyph = LIGHT, gem = RARE, ghost = 0.3, near = 0.55, on = LIGHT },
    { name = "Epic", color = EPIC, deep = Rgb(0x7220b0), frame = "steel", crown = "steel", banner = "parchment",
        field = 0.45, plain = 1, glyph = LIGHT, gem = EPIC, ghost = 0.3, near = 0.55, on = LIGHT },
    { name = "Legendary", color = LEGENDARY, deep = Rgb(0xc75a00), frame = "steel", crown = "steel",
        banner = "parchment", side = "pewter", field = 1, plain = 1, glyph = INK, gem = LEGENDARY, ghost = 0.16,
        near = 0.36, on = INK },
    { name = "Scarlet", color = SCARLET, deep = Rgb(0xc4123a), frame = "gold", crown = "gold", banner = "parchment",
        side = "pewter", rays = "gold", field = 1, plain = 1, glyph = INK, gem = SCARLET, ghost = 0.14, near = 0.34,
        on = INK },
    look = {
        ink = INK,
        white = { 1, 1, 1 },
        light = LIGHT,
        clear = CreateColor(1, 1, 1, 1),
        glyphAlpha = 0.75,
        unearnedRim = 0.5,
        unearnedFill = 0.3,
        nearAt = 0.9,
        band = { 15, 69.9, 81, 73.1 },
        gemBox = { 44.4, 20.4, 51.6, 28.8 },
        gemAt = 24.6,
        gemSetting = 1.5,
    },
}

for tier = 1, 5 do
    local q = ns.Tiers[tier]
    for _, name in ipairs({ "frame", "crown", "banner", "side", "rays" }) do
        if q[name] then q[name] = MATERIAL[q[name]] end
    end
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
