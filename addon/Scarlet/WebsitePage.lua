local _, ns = ...

local format = string.format

local DEFAULT_HOST = "scarletweb.io"

local Web = {}
ns.Web = Web

local state = { kind = "none", host = DEFAULT_HOST }

local function Str(v)
    if type(v) == "string" and v ~= "" and #v < 200 then return v end
end

local function Epoch(v)
    if type(v) == "number" and v > 0 and v < 4e9 then return v end
end

--- The link state from the app's digest: kind is none (no digest), old (a digest without a web block),
--- off, unlinked or linked; host, page (this character's address) and sync (its last upload) when known.
function Web.State()
    local d = _G.ScarletDigest
    state.page, state.sync = nil, nil
    if type(d) ~= "table" or type(d.chars) ~= "table" then
        state.kind, state.host = "none", DEFAULT_HOST
        return state
    end
    local web = type(d.web) == "table" and d.web or nil
    if not web then
        state.kind, state.host = "old", DEFAULT_HOST
        return state
    end
    state.host = Str(web.host) or DEFAULT_HOST
    state.sync = Epoch(web.sync)
    if web.upload ~= true then
        state.kind = "off"
    else
        state.kind = web.linked == true and "linked" or "unlinked"
        local c = d.chars[ns.charKey]
        local cw = type(c) == "table" and type(c.web) == "table" and c.web or nil
        if cw then
            state.page = Str(cw.page)
            state.sync = Epoch(cw.sync) or state.sync
        end
    end
    return state
end

local FOOT = { none = "Website: no app", old = "Website: not linked", off = "Website: not linked",
    unlinked = "Website: not linked", linked = "Website: linked" }

--- The sidebar foot line for the current link state.
function Web.Foot()
    return FOOT[Web.State().kind]
end

local function LastUpload(t)
    if not t then return "No upload yet." end
    return "Last upload " .. ns.Ago(t) .. "."
end

local function AddressBox(parent, ui, w)
    local T = ui.T
    local box = CreateFrame("Frame", nil, parent)
    box:SetSize(w, 30)
    ui.Fill(box, T.panel):SetAllPoints()
    ui.Border(box, T.line2)
    local edit = CreateFrame("EditBox", nil, box)
    edit:SetPoint("TOPLEFT", 10, 0)
    edit:SetPoint("BOTTOMRIGHT", -10, 0)
    edit:SetAutoFocus(false)
    ui.SetFont(edit, ui.Face("body"), 14)
    edit:SetTextColor(T.fg[1], T.fg[2], T.fg[3])
    local value = ""
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    edit:SetScript("OnMouseUp", function(self)
        self:SetFocus()
        self:HighlightText()
    end)
    edit:SetScript("OnTextChanged", function(self, userInput)
        if userInput and self:GetText() ~= value then
            self:SetText(value)
            self:HighlightText()
        end
    end)
    function box:Set(text)
        value = text
        edit:SetText(text)
        edit:SetCursorPosition(0)
    end
    function box:Release()
        edit:ClearFocus()
    end
    return box
end

function ns.WebsitePage(parent, ui)
    local T, Text = ui.T, ui.Text
    local page = CreateFrame("Frame", nil, parent)
    page:SetAllPoints()

    local sentence = Text(page, 14, T.fg)
    sentence:SetPoint("TOPLEFT", 0, -4)
    sentence:SetWidth(560)
    sentence:SetWordWrap(true)
    sentence:SetJustifyV("TOP")
    local box = AddressBox(page, ui, 360)
    box:SetPoint("TOPLEFT", sentence, "BOTTOMLEFT", 0, -12)
    local note = Text(page, 13, T.muted)
    note:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 0, -12)

    local noteHot = CreateFrame("Frame", nil, page)
    noteHot:SetAllPoints(note)
    noteHot:EnableMouse(true)
    noteHot:SetScript("OnEnter", function(self) ns.ShowExact(self, Web.State().sync, false, "ANCHOR_BOTTOM") end)
    noteHot:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local drawnKind, drawnPage, drawnSync, drawnAgo, hasAddress
    function page:Refresh()
        local s = Web.State()
        local ago = s.sync and ns.Ago(s.sync) or nil
        if s.kind == drawnKind and s.page == drawnPage and s.sync == drawnSync and ago == drawnAgo then return end
        drawnKind, drawnPage, drawnSync, drawnAgo = s.kind, s.page, s.sync, ago
        local address, line, tail
        if s.kind == "none" then
            local total = ns.FEATS and #ns.FEATS or 0
            line = total > 0 and format("The Scarlet app adds your history, all %d feats and your pages on the website.", total)
                or "The Scarlet app adds your history, all feats and your pages on the website."
            address = s.host .. "/download"
        elseif s.kind == "old" then
            line = "This Scarlet app does not report the website link. Update the app to see it here."
        elseif s.kind == "off" then
            line = "Uploading is off in the Scarlet app."
        elseif s.page then
            line = "Your page:"
            address = s.page
            tail = s.kind == "linked" and LastUpload(s.sync) or "Link in the Scarlet app: Settings, Website."
        else
            line = "Your page appears after this character's next upload."
            tail = s.kind == "linked" and LastUpload(s.sync) or "Link in the Scarlet app: Settings, Website."
        end
        sentence:SetText(line)
        hasAddress = address ~= nil
        box:SetShown(hasAddress)
        if address then box:Set(address) end
        note:SetText(tail or "")
        noteHot:SetShown(s.kind == "linked" and s.sync ~= nil)
        note:ClearAllPoints()
        note:SetPoint("TOPLEFT", address and box or sentence, "BOTTOMLEFT", 0, -12)
    end

    page:SetScript("OnHide", function() box:Release() end)
    return page
end
