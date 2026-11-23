local _, ns = ...

local floor = math.floor

local function Rgb(hex)
    return { floor(hex / 65536) / 255, floor(hex / 256) % 256 / 255, hex % 256 / 255 }
end

local COPPER, SILVER, GOLD, SCARLET, DEEP, INK = Rgb(0xc58a63), Rgb(0xc3c7cf), Rgb(0xd9b25f), Rgb(0xff2d55), Rgb(0xc0102e), Rgb(0x141416)

--- Every tier's name and colours, the one place they are written. ns.Tiers[tier] for tier 0 to 5 holds:
--- name; color (text, bars, glow); rim, lead (crown and banner), glyph and field with fieldAlpha (1 is a solid field);
--- side (wings, spurs or laurels), rays and gem where the tier has them. ns.Tiers.look holds what the crest draws
--- around the tiers: its ink, the not-earned outline, the rays' ghost and the ghost's strengths.
ns.Tiers = {
    [0] = { name = "Not earned", color = Rgb(0x9d9d9d), glyph = Rgb(0x8a8a93) },
    { name = "Copper", color = COPPER, rim = COPPER, lead = COPPER, glyph = COPPER, field = COPPER, fieldAlpha = 0.16 },
    { name = "Silver", color = SILVER, rim = SILVER, lead = SILVER, glyph = SILVER, field = SILVER, fieldAlpha = 0.2 },
    { name = "Gold", color = GOLD, rim = GOLD, lead = GOLD, glyph = GOLD, field = GOLD, fieldAlpha = 0.24 },
    { name = "Scarlet", color = SCARLET, rim = SCARLET, lead = SCARLET, glyph = INK, field = SCARLET, fieldAlpha = 1,
        side = DEEP },
    { name = "Legend", color = GOLD, rim = GOLD, lead = GOLD, glyph = INK, field = SCARLET, fieldAlpha = 1, side = GOLD,
        rays = SCARLET, gem = SCARLET },
    look = {
        ink = INK,
        white = { 1, 1, 1 },
        outline = 0.22,
        glyphAlpha = 0.75,
        raysGhost = GOLD,
        ghost = 0.14,
        near = 0.34,
        nearAt = 0.9,
        unearnedFill = 0.34,
    },
}

--- A tier's name, or "" past the last.
function ns.TierName(tier)
    local t = ns.Tiers[tier]
    return t and t.name or ""
end
