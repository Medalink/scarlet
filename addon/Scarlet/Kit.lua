local _, ns = ...
local UI = ns.UI

local floor, max, min, sin, cos, pi, format = math.floor, math.max, math.min, math.sin, math.cos, math.pi, string.format
local T, Fill, Border, Hair, Text = UI.T, UI.Fill, UI.Border, UI.Hair, UI.Text

local MEDIA = "Interface\\AddOns\\Scarlet\\Media\\"
local PLATES, TICK, GLYPHS = MEDIA .. "Plates.tga", MEDIA .. "Tick.tga", MEDIA .. "Glyphs.tga"

local FAMILY_CELL = { journey = 1, combat = 2, quests = 3, dungeons = 4, world = 5, trade = 6, class = 7, role = 8 }
local GLYPH_NAMES = { "characters", "level", "hours", "kills", "deaths", "quests", "dungeons", "gold", "zones",
    "distance", "skills", "fish", "gather", "jumps", "swim", "emote", "crown", "shield", "clock", "pin", "creature",
    "item", "talents", "spell", "pet", "heal", "fire", "wing", "link", "arrow", "lock", "check" }
local GLYPH_CELL = {}
for i, name in ipairs(GLYPH_NAMES) do GLYPH_CELL[name] = i - 1 end

local METAL = { [0] = T.fg, T.copper, T.silver, T.gold, T.accent, T.accent }
local NEXT = { [0] = T.copper, T.silver, T.gold, T.accent, T.gold, T.gold }
local TIER_NAMES = { "Copper", "Silver", "Gold", "Scarlet", "Legend" }

UI.TierNames, UI.TierColor, UI.NextColor = TIER_NAMES, METAL, NEXT

local function Tint(t, c, a)
    t:SetVertexColor(c[1], c[2], c[3], a or c[4] or 1)
end

local function Glyph(t, name)
    local i = GLYPH_CELL[name] or GLYPH_CELL.spell
    local col, row = i % 8, floor(i / 8)
    t:SetTexture(GLYPHS)
    t:SetTexCoord(col / 8, (col + 1) / 8, row / 4, (row + 1) / 4)
end
UI.SetGlyph = Glyph

local function SetPlate(t, family)
    local i = FAMILY_CELL[family] or 1
    t:SetTexture(PLATES)
    t:SetTexCoord((i - 1) / 8, i / 8, 0, 1)
end

local function Pool(make)
    local p, used = {}, 0
    function p.Reset() used = 0 end
    function p.Get()
        local o = p[used + 1]
        if not o then
            o = make()
            if not o then return nil end
            p[used + 1] = o
        end
        used = used + 1
        o:Show()
        return o
    end
    function p.Finish()
        for i = used + 1, #p do p[i]:Hide() end
    end
    return p
end

local function Rect(parent, layer, sub)
    return function() return Fill(parent, T.fg, 1, layer or "ARTWORK", sub) end
end

local function Clock(t)
    return date("%H:%M", t)
end

function UI.Tile(parent, w, h)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(w, h)
    Hair(f, "RIGHT")
    Hair(f, "BOTTOM")
    local tall = h >= 84
    f.label = Text(f, 12, T.muted)
    f.label:SetPoint("TOPLEFT", 14, tall and -10 or -12)
    f.value = Text(f, 30, T.fg, "LEFT", "display")
    f.value:SetPoint("TOPLEFT", 14, tall and -24 or -30)
    f.note = Text(f, 11.5, T.muted)
    f.note:SetPoint("BOTTOMLEFT", 14, tall and 24 or 10)
    if tall then
        f.chip = Text(f, 11.5, T.accent)
        f.chip:SetPoint("BOTTOMLEFT", 14, 8)
        f.bar = UI.Stack(f, w - 28, 5)
        f.bar:SetPoint("BOTTOMLEFT", 14, 10)
        f.bar:Hide()
    end
    --- Set takes the label, the number, the note line and, on a tall tile, a chip line (a best) or a
    --- stack of {value, color} segments drawn in the chip's place.
    function f:Set(label, value, note, chip, stack)
        self.label:SetText(label or "")
        self.value:SetText(value or "")
        self.note:SetText(note or "")
        if not tall then return end
        self.chip:SetText(chip or "")
        if stack then self.bar:Set(stack, true) end
        self.bar:SetShown(stack ~= nil)
    end
    return f
end

function UI.Ring(parent, size, n)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    n = n or (size < 60 and 20 or 36)
    local small = size < 60
    local len, thick = size * (small and 0.2 or 0.09), size * (small and 0.08 or 0.04)
    local r = size / 2 - len / 2
    local ticks = {}
    for i = 1, n do
        local t = f:CreateTexture(nil, "ARTWORK")
        t:SetTexture(TICK)
        t:SetSize(thick, len * 32 / 22)
        local a = (i - 1) / n * 2 * pi
        t:SetPoint("CENTER", f, "CENTER", sin(a) * r, cos(a) * r)
        t:SetRotation(-a)
        ticks[i] = t
    end
    f.text = Text(f, max(12, floor(size * 0.3)), T.fg, "CENTER", "display")
    f.text:SetPoint("CENTER")
    function f:Set(fraction, text, color)
        local c = color or T.accent
        local lit = floor(min(1, max(0, fraction or 0)) * n + 0.5)
        for i = 1, n do
            if i <= lit then Tint(ticks[i], c, 1) else Tint(ticks[i], T.fg, 0.16) end
        end
        self.text:SetText(text or "")
    end
    return f
end

local BAR_ROW = 30

function UI.Bars(parent, w, rows, rowHeight)
    local BAR_ROW = rowHeight or BAR_ROW
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(w, BAR_ROW * rows)
    local list = {}
    for i = 1, rows do
        local row = CreateFrame("Frame", nil, f)
        row:SetHeight(BAR_ROW)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * BAR_ROW)
        row:SetPoint("TOPRIGHT", 0, -(i - 1) * BAR_ROW)
        row.label = Text(row, 13, T.text)
        row.label:SetPoint("TOPLEFT", 0, -3)
        row.label:SetPoint("TOPRIGHT", -70, -3)
        row.value = Text(row, 13, T.fg, "RIGHT", "strong")
        row.value:SetPoint("TOPRIGHT", 0, -3)
        row.track = Fill(row, T.fg, 0.07)
        row.track:SetPoint("BOTTOMLEFT", 0, 5)
        row.track:SetPoint("BOTTOMRIGHT", 0, 5)
        row.track:SetHeight(4)
        row.bar = Fill(row, T.accent, 1, "ARTWORK")
        row.bar:SetPoint("BOTTOMLEFT", 0, 5)
        row.bar:SetHeight(4)
        list[i] = row
    end
    function f:Set(items)
        local top = 0
        for i = 1, #items do top = max(top, items[i].value or 0) end
        for i = 1, rows do
            local item, row = items[i], list[i]
            row:SetShown(item ~= nil)
            if item then
                row.label:SetText(item.label or "")
                row.value:SetText(item.text or UI.Num(item.value or 0))
                local frac = top > 0 and (item.value or 0) / top or 0
                row.bar:SetWidth(max(1, w * frac))
                Tint(row.bar, item.color or T.accent)
            end
        end
    end
    return f
end

function UI.Stack(parent, w, h)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(w, h + 24)
    local segs = Pool(Rect(f))
    local keys = Pool(function()
        local k = CreateFrame("Frame", nil, f)
        k:SetSize(10, 14)
        k.swatch = UI.Dot(k, T.fg, 1, "ARTWORK")
        k.swatch:SetSize(8, 8)
        k.swatch:SetPoint("LEFT")
        k.text = Text(k, 12, T.muted)
        k.text:SetPoint("LEFT", 14, 0)
        return k
    end)
    function f:Set(rows, noKey)
        local sum = 0
        for i = 1, #rows do sum = sum + max(0, rows[i].value or 0) end
        segs.Reset()
        keys.Reset()
        local x, kx, keyY = 0, 0, h + 10
        local gap = 2
        local usable = w - gap * max(0, #rows - 1)
        for i = 1, #rows do
            local r = rows[i]
            local share = sum > 0 and max(0, r.value or 0) / sum or 0
            local sw = max(share > 0 and 1 or 0, floor(usable * share + 0.5))
            local seg = segs.Get()
            seg:ClearAllPoints()
            seg:SetPoint("TOPLEFT", f, "TOPLEFT", x, 0)
            seg:SetSize(max(0.01, sw), h)
            Tint(seg, r.color or T.rest)
            x = x + sw + gap
            if not noKey then
                local k = keys.Get()
                k:ClearAllPoints()
                Tint(k.swatch, r.color or T.rest)
                k.text:SetText(format("%s |cfff0f1f3%s|r", r.label or "", r.text or UI.Num(r.value or 0)))
                local kw = 14 + (k.text:GetStringWidth() or 60)
                if kx > 0 and kx + kw > w then
                    kx = 0
                    keyY = keyY + 16
                end
                k:SetPoint("TOPLEFT", f, "TOPLEFT", kx, -keyY)
                kx = kx + kw + 14
            end
        end
        f:SetHeight(noKey and h or keyY + 14)
        segs.Finish()
        keys.Finish()
    end
    return f
end

local function SpellTexture(id)
    local api = _G.C_Spell
    if not (id and api and api.GetSpellTexture) then return end
    local ok, tex = pcall(api.GetSpellTexture, id)
    if ok and ns.Plain(tex) and tex then return tex end
end

--- A feat seal. Set takes family, glyph, tier 0..5, progress 0..1, spell (an id whose icon is engraved), ghost (a tier,
--- drawn as an outline toward it) and bg (the colour behind the plate, T.panel by default).
function UI.Seal(parent, size)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    local full, tiny = size >= 44, size < 22
    local k = size / 64
    local layers = {}
    for i = 1, 6 do
        local t = f:CreateTexture(nil, "ARTWORK", nil, i - 1)
        t:SetPoint("CENTER")
        layers[i] = t
    end
    local glyph = f:CreateTexture(nil, "OVERLAY", nil, 1)
    glyph:SetPoint("CENTER")
    local ticks, pips = {}, {}
    if full then
        for i = 0, 19 do
            local a = (222 + 276 / 19 * i) * pi / 180
            local t = f:CreateTexture(nil, "ARTWORK")
            t:SetTexture(TICK)
            t:SetPoint("CENTER", f, "CENTER", sin(a) * 29.2 * k, cos(a) * 29.2 * k)
            t:SetRotation(-a)
            ticks[i + 1] = t
        end
        for i = 0, 4 do
            local a = (201 - 10.5 * i) * pi / 180
            local t = Fill(f, T.fg, 1, "ARTWORK")
            t:SetSize(3.6 * k + 1, 3.6 * k + 1)
            t:SetPoint("CENTER", f, "CENTER", sin(a) * 29.4 * k, cos(a) * 29.4 * k)
            t:SetRotation(pi / 4)
            pips[i + 1] = t
        end
    end

    local function Layer(i, family, scale, color, alpha)
        local t = layers[i]
        SetPlate(t, family)
        local d = size * scale * (full and 1 or 1.36)
        t:SetSize(d, d)
        Tint(t, color, alpha)
        t:Show()
    end

    function f:Set(spec)
        local tier, p, ghost = spec.tier or 0, spec.progress or 0, spec.ghost
        local family, bg = spec.family or "journey", spec.bg or T.panel
        for i = 1, 6 do layers[i]:Hide() end
        local s = full and 0.9 or 1
        local w = full and 0.07 or 0.09
        local metal = METAL[ghost or tier]
        if tiny then
            if tier == 0 and not ghost then
                Layer(1, family, 1, T.fg, 0.3)
                Layer(2, family, 1 - 0.14, bg)
            elseif tier == 5 then
                Layer(1, family, 1, T.gold)
                Layer(2, family, 0.86, T.accent)
            else
                Layer(1, family, 1, metal and (tier >= 4 and T.accent or metal) or T.fg)
            end
            glyph:Hide()
        else
            if ghost then
                Layer(1, family, s, metal, 0.9)
                Layer(2, family, s - w, bg)
            elseif tier == 0 then
                Layer(1, family, s, T.fg, 0.22)
                Layer(2, family, s - w, bg)
            elseif tier < 4 then
                Layer(1, family, s, metal)
                Layer(2, family, s - w, bg)
                Layer(3, family, s - w, metal, tier == 1 and 0.14 or tier == 2 and 0.18 or 0.22)
                if tier == 3 then
                    Layer(4, family, s * 0.85, metal, 0.75)
                    Layer(5, family, s * 0.85 - 0.05, bg)
                    Layer(6, family, s * 0.85 - 0.05, metal, 0.22)
                end
            else
                Layer(1, family, s, tier == 5 and T.gold or T.accent)
                Layer(2, family, s - w, bg)
                Layer(3, family, s * 0.84, T.accent)
            end
            local ink = ghost and metal or tier >= 4 and T.ink or tier > 0 and metal or T.muted
            local g = size * 24 * (full and 0.9 or 1.2) / 64
            local tex = spec.spell and SpellTexture(spec.spell)
            glyph:SetSize(g, g)
            if tex then
                glyph:SetTexture(tex)
                glyph:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                glyph:SetDesaturated(true)
                glyph:SetSize(g * 0.9, g * 0.9)
            else
                Glyph(glyph, spec.glyph or "spell")
                glyph:SetDesaturated(false)
            end
            Tint(glyph, ink, (tier > 0 or ghost) and 1 or 0.75)
            glyph:Show()
        end
        if full then
            local lit = tier == 5 and 20 or floor(p * 20 + 0.5)
            local c = NEXT[tier]
            for i = 1, 20 do
                local t = ticks[i]
                if i <= lit then
                    t:SetSize(5.4 * k, 5.2 * k)
                    Tint(t, c, 1)
                else
                    t:SetSize(3.3 * k, 5.2 * k)
                    Tint(t, T.fg, 0.16)
                end
            end
            for i = 1, 5 do
                if i <= tier then Tint(pips[i], tier == 5 and T.gold or METAL[tier], 1) else Tint(pips[i], T.fg, 0.22) end
            end
        end
    end
    return f
end

function UI.FeatRow(parent, w)
    local f = CreateFrame("Button", nil, parent)
    f:SetSize(w, 44)
    local hover = Fill(f, T.fg, 0.03)
    hover:SetAllPoints()
    hover:Hide()
    Hair(f, "BOTTOM")
    f.seal = UI.Seal(f, 28)
    f.seal:SetPoint("LEFT", 0, 2)
    f.name = Text(f, 14, T.fg, "LEFT", "strong")
    f.name:SetPoint("TOPLEFT", 38, -5)
    f.name:SetPoint("RIGHT", -4, 0)
    f.line = Text(f, 12, T.muted)
    f.line:SetPoint("TOPLEFT", 38, -22)
    f.line:SetPoint("RIGHT", -4, 0)
    f.track = Fill(f, T.fg, 0.08)
    f.track:SetPoint("BOTTOMLEFT", 38, 3)
    f.track:SetPoint("BOTTOMRIGHT", -4, 3)
    f.track:SetHeight(3)
    f.bar = Fill(f, T.accent, 1, "ARTWORK")
    f.bar:SetPoint("BOTTOMLEFT", 38, 3)
    f.bar:SetHeight(3)
    f:SetScript("OnEnter", function() hover:Show() end)
    f:SetScript("OnLeave", function() hover:Hide() end)
    function f:Set(feat)
        self.feat = feat
        self.seal:Set(feat)
        self.name:SetText(feat.name or "")
        self.line:SetText(feat.line or "")
        self.bar:SetWidth(max(0.01, (w - 42) * min(1, max(0, feat.progress or 0))))
        Tint(self.bar, NEXT[feat.tier or 0])
        local c = (feat.tier or 0) > 0 and T.fg or T.text
        self.name:SetTextColor(c[1], c[2], c[3])
    end
    return f
end

--- A seal that opens its feat on the Feats page. Set takes the feat definition, its tier, progress and whether the addon
--- moves it while the player plays (the scarlet mark), and the colour behind the plate.
function UI.FeatSeal(parent, size)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size, size)
    b.seal = UI.Seal(b, size)
    b.seal:SetAllPoints()
    b.dot = Fill(b, T.accent, 1, "OVERLAY")
    b.dot:SetSize(5, 5)
    b.dot:SetRotation(pi / 4)
    b.dot:SetPoint("CENTER", b, "TOPRIGHT", -2, -2)
    b:SetScript("OnClick", function(self)
        if self.featKey and ns.OpenFeat then ns.OpenFeat(self.featKey) end
    end)
    b:SetScript("OnEnter", function(self)
        if not self.featKey then return end
        local info = ns.Feats.Info(self.featKey)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(info.def.name)
        GameTooltip:AddLine(ns.Feats.Count(info.def, info.value), T.muted[1], T.muted[2], T.muted[3])
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    function b:Set(def, info, moves, bg)
        self.featKey = def.key
        local spells = ns.char and ns.char.featSpell
        self.seal:Set({ family = def.family, glyph = def.glyph, tier = info.tier, progress = info.progress,
            spell = spells and spells[def.key], bg = bg })
        self.dot:SetShown(moves)
    end
    return b
end

--- A compare strip. Set takes a label, a spread of p10, p25, p50, p75, p90 and you, and the value text.
function UI.Compare(parent, w)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(w, 26)
    local left, right = 150, 64
    f.label = Text(f, 13, T.text)
    f.label:SetPoint("LEFT", 0, 0)
    f.label:SetWidth(left - 8)
    f.value = Text(f, 14, T.fg, "RIGHT", "strong")
    f.value:SetPoint("RIGHT", 0, 0)
    f.value:SetWidth(right)
    local span = w - left - right - 8
    local axis = Fill(f, T.line2, 1, "ARTWORK")
    axis:SetPoint("LEFT", left, 0)
    axis:SetSize(span, 1)
    local wide = Fill(f, T.dim, 0.5, "ARTWORK", 1)
    wide:SetHeight(2)
    local mid = Fill(f, T.rest, 1, "ARTWORK", 2)
    mid:SetHeight(8)
    local med = Fill(f, T.text, 1, "ARTWORK", 3)
    med:SetSize(2, 12)
    local you = Fill(f, T.accent, 1, "OVERLAY")
    you:SetSize(9, 9)
    you:SetRotation(pi / 4)
    function f:Set(label, spread, valueText)
        self.label:SetText(label or "")
        self.value:SetText(valueText or "")
        local ok = type(spread) == "table" and spread.p50 ~= nil
        wide:SetShown(ok)
        mid:SetShown(ok)
        med:SetShown(ok)
        axis:SetShown(ok)
        you:SetShown(type(spread) == "table" and spread.you ~= nil)
        if not (type(spread) == "table" and spread.you) then return end
        local lo, hi = spread.you, spread.you
        if ok then
            lo, hi = min(spread.p10, spread.you), max(spread.p90, spread.you)
        end
        local pad = (hi - lo) * 0.06 + 1e-9
        lo, hi = lo - pad, hi + pad
        local function X(v) return left + (v - lo) / (hi - lo) * span end
        if ok then
            wide:ClearAllPoints()
            wide:SetPoint("LEFT", f, "LEFT", X(spread.p10), 0)
            wide:SetWidth(max(1, X(spread.p90) - X(spread.p10)))
            mid:ClearAllPoints()
            mid:SetPoint("LEFT", f, "LEFT", X(spread.p25), 0)
            mid:SetWidth(max(1, X(spread.p75) - X(spread.p25)))
            med:ClearAllPoints()
            med:SetPoint("CENTER", f, "LEFT", X(spread.p50), 0)
        end
        you:ClearAllPoints()
        you:SetPoint("CENTER", f, "LEFT", X(spread.you), 0)
    end
    return f
end

function UI.Tabs(parent, defs, onSelect)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(28)
    Hair(f, "BOTTOM")
    local tabs, x = {}, 0
    for i, def in ipairs(defs) do
        local b = CreateFrame("Button", nil, f)
        local text = Text(b, 14, T.muted, "CENTER", "strong")
        text:SetPoint("CENTER")
        text:SetText(def.label)
        local width = max(40, (text:GetStringWidth() or 60) + 22)
        b:SetSize(width, 28)
        b:SetPoint("TOPLEFT", x, 0)
        x = x + width
        local line = Fill(b, T.accent, 1, "ARTWORK")
        line:SetPoint("BOTTOMLEFT", 8, 0)
        line:SetPoint("BOTTOMRIGHT", -8, 0)
        line:SetHeight(2)
        line:Hide()
        b.key, b.text, b.line = def.key, text, line
        b:SetScript("OnClick", function() f:Select(def.key) end)
        tabs[i] = b
    end
    f:SetWidth(x)
    function f:Select(key, silent)
        self.active = key
        for _, b in ipairs(tabs) do
            local on = b.key == key
            b.line:SetShown(on)
            local c = on and T.fg or T.muted
            b.text:SetTextColor(c[1], c[2], c[3])
        end
        if onSelect and not silent then onSelect(key) end
    end
    f:Select(defs[1].key, true)
    return f
end

local function FeatFamily(key)
    return ns.Feats and ns.Feats.Family and ns.Feats.Family(key) or "combat"
end

--- The session strip of a recap (CONTRACTS.md, SessionRecap): zones, buckets, levels and moments. Compact drops the clock; by default it is compact under 70 px high.
function UI.Strip(parent, w, h, compact)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(w, h)
    if compact == nil then compact = h < 70 end
    local zh, ph = compact and 14 or 20, compact and 24 or 46
    local py = zh + 6
    local cy, ey = py + ph + 3, py + ph + 10
    local rects = Pool(Rect(f))
    local texts = Pool(function()
        local t = Text(f, 11, T.muted, "LEFT", "strong")
        return t
    end)
    local marks = Pool(function() return f:CreateTexture(nil, "OVERLAY") end)

    local function R(x, y, rw, rh, c, a, rot)
        local t = rects.Get()
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", f, "TOPLEFT", x, -y)
        t:SetSize(max(0.01, rw), rh)
        Tint(t, c, a)
        t:SetRotation(rot or 0)
        return t
    end
    local function Label(x, y, str, anchor, c)
        local t = texts.Get()
        t:ClearAllPoints()
        t:SetPoint(anchor or "TOPLEFT", f, "TOPLEFT", x, -y)
        t:SetText(str)
        local col = c or T.muted
        t:SetTextColor(col[1], col[2], col[3])
        return t
    end

    function f:Set(recap, span)
        rects.Reset()
        texts.Reset()
        marks.Reset()
        span = max(60, span or ((recap["end"] or recap.start) - recap.start))
        local function X(sec) return min(w, max(0, sec / span * w)) end
        local zones = recap.zones or {}
        for i = 1, #zones do
            local z = zones[i]
            local x0, x1 = X(z.at), X(z.at + z.secs)
            R(x0 + (i > 1 and 1 or 0), 0, x1 - x0 - (i > 1 and 1 or 0), zh, T.fg, i % 2 == 0 and 0.07 or 0.12)
            if x1 - x0 > #z.name * 6.4 + 12 then Label(x0 + 7, 2, z.name, "TOPLEFT", T.fg) end
        end
        local b = recap.buckets
        if b and b.xp and #b.xp > 0 then
            local top = 1
            for i = 1, #b.xp do top = max(top, b.xp[i]) end
            local bw = X(b.secs)
            for i = 1, #b.xp do
                local v = b.xp[i]
                if v > 0 then
                    local bh = max(1, v / top * ph)
                    R(X((i - 1) * b.secs) + 1, py + ph - bh, max(1, bw - 2), bh, T.accent, v == top and 1 or 0.62)
                end
                local c = b.combat and b.combat[i] or 0
                if c > 0 then R(X((i - 1) * b.secs), cy, max(1.5, bw * min(1, c / b.secs)), 3, T.accentDeep) end
            end
        end
        R(0, py + ph, w, 1, T.line2)
        local levels = recap.levels or {}
        for i = 1, #levels do
            local at = X(levels[i].at)
            R(at - 0.5, 0, 1, ey + 4, T.fg, 0.45)
            R(at - 4, ey + 3, 8, 8, T.fg, 1, pi / 4)
            Label(at + 8, ey + 3, tostring(levels[i].level), "TOPLEFT", T.fg)
        end
        local moments = recap.moments or {}
        for i = 1, #moments do
            local m = moments[i]
            local at = X(m.at)
            if m.kind == "death" then
                local g = marks.Get()
                Glyph(g, "deaths")
                g:SetSize(11, 11)
                g:ClearAllPoints()
                g:SetPoint("TOP", f, "TOPLEFT", at, -(ey + 1))
                Tint(g, T.fg, 1)
            elseif m.kind == "feat" then
                local g = marks.Get()
                SetPlate(g, FeatFamily(m.feat))
                g:SetSize(16, 16)
                g:ClearAllPoints()
                g:SetPoint("TOP", f, "TOPLEFT", at, -(ey - 2))
                Tint(g, METAL[max(1, min(5, m.tier or 1))])
            elseif m.kind == "boss" or m.kind == "discovery" then
                R(at - 1.5, ey + 6, 3, 3, T.muted)
            end
        end
        if not compact then
            Label(0, h - 13, Clock(recap.start))
            local t1 = Label(w, h - 13, Clock(recap.start + span), "TOPRIGHT")
            t1:SetJustifyH("RIGHT")
            local hour = 3600
            local first = recap.start + (hour - recap.start % hour) % hour
            for t = first, recap.start + span - 480, hour do
                if t - recap.start > 840 then Label(X(t - recap.start) - 14, h - 13, date("%H", t) .. ":00") end
            end
        end
        rects.Finish()
        texts.Finish()
        marks.Finish()
    end
    return f
end

local ROUTE_PAD = 16
local VIOLET = T.s4

--- The route card. Set takes a sheet: aspect (width over height, 0.4 to 2.5), points (x, y pairs with the long side at
--- 1000, y up), breaks (the 1-based index of the first point of each leg after the first), air (true at a point reached
--- by a teleport or flight) and marks ({ point index, "level" or "death" }, only the addon's own recap has them).
function UI.Route(parent, w, h)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(w, h)
    Fill(f, T.panel, 1, "BACKGROUND")
    if f.SetClipsChildren then f:SetClipsChildren(true) end
    for gx = 40, w - 1, 40 do
        local t = Fill(f, T.fg, 0.035, "BACKGROUND", 1)
        t:SetPoint("TOPLEFT", gx, 0)
        t:SetSize(1, h)
    end
    for gy = 40, h - 1, 40 do
        local t = Fill(f, T.fg, 0.035, "BACKGROUND", 1)
        t:SetPoint("TOPLEFT", 0, -gy)
        t:SetSize(w, 1)
    end
    Border(f, T.line)
    local lines = Pool(function()
        if not f.CreateLine then return nil end
        local ln = f:CreateLine(nil, "ARTWORK")
        if not ln then return nil end
        ln:SetThickness(2)
        return ln
    end)
    local dots = Pool(function() return Fill(f, T.fg, 1, "OVERLAY") end)
    f.empty = Text(f, 13, T.muted, "CENTER")
    f.empty:SetPoint("CENTER")
    f.empty:SetText("No path recorded")

    local function Seg(x1, y1, x2, y2, c, a)
        local ln = lines.Get()
        if not ln then return end
        ln:SetColorTexture(c[1], c[2], c[3], a)
        ln:SetStartPoint("BOTTOMLEFT", f, x1, y1)
        ln:SetEndPoint("BOTTOMLEFT", f, x2, y2)
    end
    local function Dashes(x1, y1, x2, y2)
        local dx, dy = x2 - x1, y2 - y1
        local count = min(30, max(1, floor(math.sqrt(dx * dx + dy * dy) / 10)))
        for k = 0, count - 1 do
            local a, b = (k + 0.1) / count, (k + 0.6) / count
            Seg(x1 + dx * a, y1 + dy * a, x1 + dx * b, y1 + dy * b, VIOLET, 0.8)
        end
    end
    local function Dot(x, y, size, c, rot)
        local t = dots.Get()
        t:ClearAllPoints()
        t:SetPoint("CENTER", f, "BOTTOMLEFT", x, y)
        t:SetSize(size, size)
        t:SetRotation(rot or 0)
        Tint(t, c)
    end

    function f:Set(sheet)
        lines.Reset()
        dots.Reset()
        local pts = sheet and sheet.points
        local n = pts and floor(#pts / 2) or 0
        self.empty:SetShown(n < 2)
        if n >= 2 then
            local aw, ah = w - 2 * ROUTE_PAD, h - 2 * ROUTE_PAD
            local aspect = max(0.4, min(2.5, tonumber(sheet.aspect) or 1))
            local sw, sh = aw, aw / aspect
            if sh > ah then sw, sh = ah * aspect, ah end
            local ox, oy = (w - sw) / 2, (h - sh) / 2
            local long = 1000
            local sx, sy = sw / (aspect >= 1 and long or long * aspect), sh / (aspect >= 1 and long / aspect or long)
            local function P(i) return ox + pts[2 * i - 1] * sx, oy + pts[2 * i] * sy end
            local bi, breaks, air = 1, sheet.breaks or {}, sheet.air
            local chunk = max(1, floor(n / 6))
            for i = 2, n do
                if breaks[bi] == i then
                    bi = bi + 1
                else
                    local x1, y1 = P(i - 1)
                    local x2, y2 = P(i)
                    if air and air[i] then
                        Dashes(x1, y1, x2, y2)
                    else
                        Seg(x1, y1, x2, y2, T.accent, 0.38 + 0.62 * min(5, floor((i - 1) / chunk)) / 5)
                    end
                end
            end
            local x0, y0 = P(1)
            Dot(x0, y0, 9, T.fg)
            Dot(x0, y0, 5, T.panel)
            local m = sheet.marks
            if m then
                for i = 1, #m do
                    local px, py = P(m[i][1])
                    if m[i][2] == "level" then Dot(px, py, 8, T.fg, pi / 4) else Dot(px, py, 7, T.fg) Dot(px, py, 3, T.panel) end
                end
            end
            local xe, ye = P(n)
            Dot(xe, ye, 11, T.panel, pi / 4)
            Dot(xe, ye, 8, T.accent, pi / 4)
        end
        lines.Finish()
        dots.Finish()
    end
    return f
end

local sheet

local function SampleRecap()
    local xp, combat = {}, {}
    for i = 1, 29 do
        xp[i] = floor(900 + 700 * sin(i / 3) + (i % 5) * 160)
        combat[i] = (i % 4 == 0) and 0 or floor(120 + 80 * sin(i))
    end
    return {
        start = 1760000000, ["end"] = 1760000000 + 8700,
        zones = { { name = "Duskwood", at = 0, secs = 1800 }, { name = "Redridge Mountains", at = 1800, secs = 4200 },
            { name = "Elwynn Forest", at = 6000, secs = 2700 } },
        buckets = { secs = 300, xp = xp, combat = combat },
        levels = { { level = 41, at = 2600 }, { level = 42, at = 7300 } },
        moments = { { at = 3500, kind = "death" }, { at = 5000, kind = "boss" }, { at = 6400, kind = "feat", feat = "slayer", tier = 2 } },
    }
end

local function SampleRoute()
    local pts, n = {}, 120
    for i = 1, n do
        local a = i / n
        pts[2 * i - 1] = 80 + 840 * a
        pts[2 * i] = 500 + 300 * sin(a * 9) * (1 - a * 0.4)
    end
    return { aspect = 1.6, points = pts, breaks = {}, air = { [100] = true }, marks = { { 30, "level" }, { 60, "death" } } }
end

local function BuildSheet()
    local f = CreateFrame("Frame", "ScarletSheet", UIParent)
    f:SetSize(880, 560)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    tinsert(UISpecialFrames, "ScarletSheet")
    Fill(f, T.win, 0.98):SetAllPoints()
    Border(f, T.line2)
    local title = Text(f, 24, T.fg, "LEFT", "display")
    title:SetPoint("TOPLEFT", 24, -12)
    title:SetText("Design sheet")
    UI.CloseButton(f, f):SetPoint("TOPRIGHT", -10, -10)

    local scroll = CreateFrame("ScrollFrame", nil, f)
    scroll:SetPoint("TOPLEFT", 24, -52)
    scroll:SetPoint("BOTTOMRIGHT", -24, 16)
    local body = CreateFrame("Frame", nil, scroll)
    body:SetSize(832, 1000)
    scroll:SetScrollChild(body)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        self:SetVerticalScroll(min(max(0, body:GetHeight() - self:GetHeight()), max(0, self:GetVerticalScroll() - delta * 60)))
    end)

    local y = 0
    local function Heading(text)
        local h = Text(body, 19, T.fg, "LEFT", "display")
        h:SetPoint("TOPLEFT", 0, -y)
        h:SetText(text)
        y = y + 30
    end
    local function Place(obj, h, x)
        obj:SetPoint("TOPLEFT", body, "TOPLEFT", x or 0, -y)
        y = y + h
    end

    Heading("Numbers")
    local tiles = {
        { "Kills", "9,912", "63 an hour" }, { "Played since Monday", "16h 20m", "" },
        { "Hours recorded", "1,284", "" }, { "Distance", "9.4 mi", "on foot 6.1" },
    }
    for i, d in ipairs(tiles) do
        local t = UI.Tile(body, 160, 74)
        t:SetPoint("TOPLEFT", body, "TOPLEFT", (i - 1) * 160, -y)
        t:Set(d[1], d[2], d[3])
    end
    local ring = UI.Ring(body, 74)
    ring:SetPoint("TOPLEFT", body, "TOPLEFT", 680, -y)
    ring:Set(72 / 92, "72")
    y = y + 94

    Heading("Stacks and bar list")
    local stack = UI.Stack(body, 400, 12)
    Place(stack, 48)
    stack:Set({ { label = "Kills", value = 41200, color = T.accent }, { label = "Exploring", value = 2100, color = T.s2 },
        { label = "Quests", value = 38900, color = T.s3 }, { label = "Dungeons", value = 12400, color = T.s4 },
        { label = "Other", value = 4200, color = T.rest } })
    local travel = UI.Stack(body, 400, 12)
    Place(travel, 52)
    travel:Set({ { label = "Swimming", value = 540, color = T.s2, text = "9m" }, { label = "On foot", value = 3900, color = T.accent, text = "1h 05m" },
        { label = "Mounted", value = 1080, color = T.s3, text = "18m" }, { label = "Standing still", value = 3840, color = T.rest, text = "1h 04m" } })
    local bars = UI.Bars(body, 300, 5)
    bars:SetPoint("TOPLEFT", body, "TOPLEFT", 520, -(y - 100))
    bars:Set({ { label = "Wastewander Bandit", value = 58 }, { label = "Dunemaul Ogre", value = 44 }, { label = "Scorpid Hunter", value = 41 },
        { label = "Steeljaw Snapper", value = 29 }, { label = "Stonetusk Boar", value = 12 } })
    y = y + 10

    Heading("Session strip, full and compact")
    local recap = SampleRecap()
    local strip = UI.Strip(body, 832, 112)
    Place(strip, 122)
    strip:Set(recap)
    local compact = UI.Strip(body, 400, 60)
    Place(compact, 70)
    compact:Set(recap)
    local route = UI.Route(body, 236, 154)
    route:SetPoint("TOPLEFT", body, "TOPLEFT", 460, -(y - 70))
    route:Set(SampleRoute())
    y = y + 100

    Heading("Feat seals: six tiers in every family")
    local order = { "journey", "combat", "quests", "dungeons", "world", "trade", "class", "role" }
    local glyphOf = { journey = "hours", combat = "kills", quests = "quests", dungeons = "dungeons", world = "zones",
        trade = "fish", class = "spell", role = "heal" }
    for row, fam in ipairs(order) do
        for tier = 0, 5 do
            local s = UI.Seal(body, 48)
            s:SetPoint("TOPLEFT", body, "TOPLEFT", tier * 56 + ((row - 1) % 2) * 380, -(y + floor((row - 1) / 2) * 56))
            s:Set({ family = fam, glyph = glyphOf[fam], tier = tier, progress = 0.55, bg = T.win })
        end
    end
    y = y + 4 * 56 + 12
    local x = 0
    for _, size in ipairs({ 104, 64, 48, 28, 18 }) do
        local s = UI.Seal(body, size)
        s:SetPoint("TOPLEFT", body, "TOPLEFT", x, -y)
        s:Set({ family = "combat", glyph = "kills", tier = 3, progress = 0.5, bg = T.win })
        x = x + size + 24
    end
    y = y + 116

    Heading("Feat rows")
    local rows = {
        { name = "Slayer", line = "9,912 kills  -  88 to Gold", tier = 2, progress = 0.82, family = "combat", glyph = "kills" },
        { name = "Rampage", line = "312 kills this session  -  268 to Gold", tier = 2, progress = 0.3, family = "combat", glyph = "kills" },
        { name = "Soloist", line = "1 run alone  -  1 to Copper", tier = 0, progress = 0, family = "dungeons", glyph = "dungeons" },
    }
    for _, d in ipairs(rows) do
        local r = UI.FeatRow(body, 380)
        Place(r, 46)
        d.bg = T.win
        r:Set(d)
    end

    Heading("Compare strips and tabs")
    local cmp = {
        { "Kills an hour", { p10 = 40, p25 = 62, p50 = 80, p75 = 96, p90 = 118, you = 104 }, "104" },
        { "Deaths an hour", { p10 = 0, p25 = 0.1, p50 = 0.2, p75 = 0.4, p90 = 0.7, you = 0.21 }, "0.21" },
        { "Jumps an hour", { p10 = 200, p25 = 600, p50 = 1200, p75 = 1900, p90 = 2500, you = 2770 }, "2,770" },
    }
    for _, d in ipairs(cmp) do
        local c = UI.Compare(body, 420)
        Place(c, 28)
        c:Set(d[1], d[2], d[3])
    end
    local tabs = UI.Tabs(body, { { key = "a", label = "Overview" }, { key = "b", label = "Feats" }, { key = "c", label = "Sessions" } })
    Place(tabs, 40)
    body:SetHeight(y)
    f:Hide()
    return f
end

function UI.ToggleSheet()
    if not sheet then sheet = BuildSheet() end
    sheet:SetShown(not sheet:IsShown())
end
