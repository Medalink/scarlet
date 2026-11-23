local _, ns = ...

local floor = math.floor

local function Rgb(hex)
    return { floor(hex / 65536) / 255, floor(hex / 256) % 256 / 255, hex % 256 / 255 }
end

local INK, LIGHT = Rgb(0x141416), Rgb(0xf0f1f3)
local POOR, UNCOMMON, RARE, EPIC, LEGENDARY, SCARLET =
    Rgb(0x9d9d9d), Rgb(0x1eff00), Rgb(0x0070dd), Rgb(0xa335ee), Rgb(0xff8000), Rgb(0xff2d55)

--- The one colour table, mirroring QUALITY in the design's crests.js. ns.Tiers[tier] for tier 0 to 5 holds:
--- name (tier 0 prints as "Not earned"); color: the field, the crown and the banner, and every bar, chip and toast
--- accent; rim: the shield's rim and the account ring; field: the field's opacity (1 is the solid field);
--- plain: the shield's opacity under 22 px; glyph: the glyph's tint; side, rays, gem: those pieces where the tier has
--- them; ghost, near: the opacity of a ghost drawn in this tier's colour, at rest and from look.nearAt; on: text on a
--- solid chip of this colour. ns.Tiers.look holds what the crest draws around the tiers.
ns.Tiers = {
    [0] = { name = "Not earned", color = POOR, rim = POOR, field = 0, plain = 0, glyph = POOR, ghost = 0, near = 0, on = INK },
    { name = "Uncommon", color = UNCOMMON, rim = UNCOMMON, field = 0.12, plain = 0.55, glyph = LIGHT, ghost = 0.12,
        near = 0.3, on = INK },
    { name = "Rare", color = RARE, rim = RARE, field = 0.3, plain = 1, glyph = LIGHT, ghost = 0.3, near = 0.55, on = LIGHT },
    { name = "Epic", color = EPIC, rim = EPIC, field = 0.3, plain = 1, glyph = LIGHT, ghost = 0.3, near = 0.55, on = LIGHT },
    { name = "Legendary", color = LEGENDARY, rim = LEGENDARY, field = 1, plain = 1, glyph = INK, side = Rgb(0xb85c00),
        ghost = 0.16, near = 0.36, on = INK },
    { name = "Scarlet", color = SCARLET, rim = LIGHT, field = 1, plain = 1, glyph = INK, side = Rgb(0xc0102e),
        rays = LIGHT, gem = LIGHT, ghost = 0.14, near = 0.34, on = INK },
    look = {
        ink = INK,
        white = { 1, 1, 1 },
        light = LIGHT,
        glyphAlpha = 0.75,
        unearnedRim = 0.5,
        unearnedFill = 0.3,
        nearAt = 0.9,
    },
}

--- A tier's name, or "" past the last.
function ns.TierName(tier)
    local t = ns.Tiers[tier]
    return t and t.name or ""
end
