-- Quests.lua: the Quests-and-NPCs trackers beyond Capture and Track:
--   QI  a quest's kind when it is accepted, or found in the log at login
--   QP  quest objective progress
--   QS  a quest became complete, stopped being complete, failed, or can be turned in anywhere
--   QA  another player shared a quest with you
--   QD  a quest dialog opened: greeting, progress, or reward window
--   QR  the reward you picked at a turn-in
--   QW  a quest was added to or removed from the tracker
--   QY  a quest session (party sync) was created, joined, left or ended
--   QK  a campaign's state and current chapter
--   NW  an NPC or object window opened or closed, with its interaction type
--   GS  what a gossip window offered: quests, active quests, options
--   GO  the gossip option you picked
--   GN  gossip option name, once per session
--   GC  a gossip confirmation (with a cost) appeared or was cancelled
--   PC  a player choice popup was offered, answered or closed
--   IR  you read an item or object text (its title only)
--   CK  content tracking: an appearance, mount or achievement tracked or untracked
-- Codes are in docs/FORMAT.md. Event driven only; every client value through
-- Plain() before it is compared or indexed. Quest text, gossip text and typed
-- codes are never recorded.
local _, ns = ...

local type, pcall, pairs, ipairs, tostring, tonumber = type, pcall, pairs, ipairs, tostring, tonumber
local concat = table.concat
local Emit, Plain = ns.Emit, ns.Plain
local ItemName, Round1, NpcID = ns.ItemName, ns.Round1, ns.NpcID

local QL = C_QuestLog
local QINFO = C_QuestInfoSystem
local CAMP = C_CampaignInfo
local GOSSIP = C_GossipInfo
local PCHOICE = C_PlayerChoice
local TRACK = C_ContentTracking

local frame = CreateFrame("Frame")
local H = {}

local function Str(v)
    if Plain(v) and type(v) == "string" and v ~= "" then return v end
end

local function Num(v)
    if Plain(v) and type(v) == "number" then return v end
end

-- First return value of fn(...), or nil when it errors or comes back secret.
local function Call(fn, ...)
    if type(fn) ~= "function" then return end
    local ok, v = pcall(fn, ...)
    if ok and Plain(v) then return v end
end

-- The NPC being talked to --------------------------------------------------------------
-- NpcID turns the "npc" unit's guid into an npcID. The name goes out once per
-- session as an N line, like the kill names.

local npcNamed = {}

local function Npc()
    local guid = UnitGUID("npc")
    if not Plain(guid) or type(guid) ~= "string" then return "" end
    local id = NpcID(guid)
    if type(id) ~= "number" then return "" end -- a player, an object or a mailbox
    if not npcNamed[id] then
        local name = Str(UnitName("npc"))
        if name then
            npcNamed[id] = true
            Emit("N", id, name)
        end
    end
    return id
end

-- Windows ------------------------------------------------------------------------------
-- NW 1 <type> <npcID>, NW 0 <type> <seconds>: any NPC or object window the
-- client opens through the interaction manager. type is the client's
-- PlayerInteractionType (3 gossip, 4 quest giver, 5 merchant, 7 trainer, ...).

local windows = {}

function H.PLAYER_INTERACTION_MANAGER_FRAME_SHOW(kind)
    if not Num(kind) then return end
    -- A HIDE the client never sent: close the old window before the new one.
    if windows[kind] then Emit("NW", 0, kind, Round1(GetTime() - windows[kind])) end
    windows[kind] = GetTime()
    Emit("NW", 1, kind, Npc())
end

function H.PLAYER_INTERACTION_MANAGER_FRAME_HIDE(kind)
    if not Num(kind) or not windows[kind] then return end
    local t0 = windows[kind]
    windows[kind] = nil
    Emit("NW", 0, kind, Round1(GetTime() - t0))
end

-- Quest names --------------------------------------------------------------------------
-- QN is written by Track when a quest is accepted. This file adds it for quests
-- it sees first (login, a gossip list, a shared quest), once per session.

local questNamed = {}

local function QuestName(questID, title)
    if questNamed[questID] then return end
    local t = Str(title)
    if not t then return end
    questNamed[questID] = true
    Emit("QN", questID, t)
end

-- Campaigns ----------------------------------------------------------------------------
-- QK <campaignID> <name> <state> <chapterID>, again when the state or chapter
-- changes. state is the client's CampaignState (0 invalid, 1 complete,
-- 2 in progress, 3 stalled).

local campaigns = {}

local function Campaign(id)
    if not CAMP or not Num(id) or id <= 0 then return end
    local info = Call(CAMP.GetCampaignInfo, id)
    local name = type(info) == "table" and Str(info.name) or ""
    local state = Num(Call(CAMP.GetState, id)) or ""
    local chapter = Num(Call(CAMP.GetCurrentChapterID, id)) or ""
    local sig = name .. ":" .. tostring(state) .. ":" .. tostring(chapter)
    if campaigns[id] == sig then return end
    campaigns[id] = sig
    Emit("QK", id, name, state, chapter)
end

local function CampaignsAgain()
    for id in pairs(campaigns) do Campaign(id) end
end

-- Quests in the log --------------------------------------------------------------------
-- quests[questID] holds what was last written: whether it was complete or
-- failed, and each objective's count. QUEST_LOG_UPDATE fires constantly, so it
-- only sets a flag; one scan runs a few seconds later and writes differences.

local quests = {}
local ready = false

-- QI <questID> <level> <frequency> <classification> <tagID> <suggestedGroup>
-- <campaignID> <timeAllowed> <baseline>. frequency is the client's QuestFrequency
-- (0 once, 1 daily, 2 weekly), classification its QuestClassification (0 important,
-- 2 campaign, 3 calling, 5 recurring, 7 normal, 10 world quest, ...). timeAllowed
-- is seconds for a timed quest. baseline `s` when found in the log at login.
local function QuestInfo(questID, baseline)
    local idx = Num(Call(QL.GetLogIndexForQuestID, questID))
    local info = idx and idx > 0 and Call(QL.GetInfo, idx)
    if type(info) ~= "table" then info = {} end
    local class = Num(Call(QINFO and QINFO.GetQuestClassification, questID))
    local tag = Call(QL.GetQuestTagInfo, questID)
    local total = Num(Call(QL.GetTimeAllowed, questID))
    local campaign = Num(Call(CAMP and CAMP.GetCampaignID, questID))
    if campaign and campaign <= 0 then campaign = nil end
    if baseline then QuestName(questID, info.title) end
    Emit("QI", questID, Num(info.level) or "", Num(info.frequency) or "", class or "",
        type(tag) == "table" and Num(tag.tagID) or "", Num(info.suggestedGroup) or "",
        campaign or "", total and total > 0 and total or "", baseline and "s" or "")
    Campaign(campaign)
end

-- QP <questID> <index> <fulfilled> <required> <type> <text>: an objective's
-- count changed. text only on the first line for that objective in a session,
-- with its trailing count cut off.
-- QS <questID> <state>: c complete, u no longer complete, f failed.
local function ReadQuest(questID, silent)
    local st = quests[questID]
    if not st then
        st = { obj = {}, text = {} }
        quests[questID] = st
    end
    local list = Call(QL.GetQuestObjectives, questID)
    if type(list) == "table" then
        for i, o in ipairs(list) do
            if type(o) == "table" then
                local got, need = Num(o.numFulfilled), Num(o.numRequired)
                if got and need and st.obj[i] ~= got then
                    local first = st.obj[i] == nil
                    st.obj[i] = got
                    if not (silent or (first and got == 0)) then
                        local text = ""
                        if not st.text[i] then
                            st.text[i] = true
                            local t = Str(o.text)
                            if t then text = t:gsub("%s*[:%-]?%s*%d+%s*/%s*%d+%s*$", "") end
                        end
                        Emit("QP", questID, i, got, need, Str(o.type) or "", text)
                    end
                end
            end
        end
    end
    local done, failed = Call(QL.IsComplete, questID), Call(QL.IsFailed, questID)
    if done ~= nil and done ~= st.done then
        local was = st.done
        st.done = done
        if not silent and (was ~= nil or done) then Emit("QS", questID, done and "c" or "u") end
    end
    if failed ~= nil and failed ~= st.failed then
        st.failed = failed
        if failed and not silent then Emit("QS", questID, "f") end
    end
end

local function Scan()
    for questID in pairs(quests) do
        if Call(QL.IsOnQuest, questID) then
            ReadQuest(questID)
        else
            quests[questID] = nil
        end
    end
end

local scanDue = false
function H.QUEST_LOG_UPDATE()
    if scanDue or not ready then return end
    scanDue = true
    C_Timer.After(3, function()
        scanDue = false
        Scan()
    end)
end

local watchDue = {}
-- Quests under a collapsed log header are not in the login scan; their first
-- watch update adds them.
function H.QUEST_WATCH_UPDATE(questID)
    if not Num(questID) or not ready or watchDue[questID] then return end
    watchDue[questID] = true
    C_Timer.After(0.5, function()
        watchDue[questID] = nil
        if quests[questID] then
            ReadQuest(questID)
        elseif Call(QL.IsOnQuest, questID) then
            QuestInfo(questID, true)
            ReadQuest(questID)
        end
    end)
end

-- QP with index = the criteria tree id and type `criteria`, for quests whose
-- objectives are a criteria tree.
local criteria = {}
function H.QUEST_LOG_CRITERIA_UPDATE(questID, treeID, description, got, need)
    if not Num(questID) or not Num(treeID) or not Num(got) or not Num(need) then return end
    local key = questID .. ":" .. treeID
    if criteria[key] == got then return end
    local text = criteria[key] == nil and Str(description) or ""
    criteria[key] = got
    Emit("QP", questID, treeID, got, need, "criteria", text)
end

function H.QUEST_AUTOCOMPLETE(questID)
    if not Num(questID) then return end
    local st = quests[questID]
    if st then st.done = true end
    Emit("QS", questID, "a")
end

function H.QUEST_ACCEPTED(questID)
    if not Num(questID) then return end
    questNamed[questID] = true -- Track writes the QN line
    QuestInfo(questID, false)
    ReadQuest(questID)
end

function H.QUEST_REMOVED(questID)
    if not Num(questID) then return end
    quests[questID] = nil
end

function H.QUEST_TURNED_IN()
    if next(campaigns) then C_Timer.After(1, CampaignsAgain) end
end

local function Baseline()
    ready = true
    local shown = Num(Call(QL.GetNumQuestLogEntries)) or 0
    for i = 1, shown do
        local info = Call(QL.GetInfo, i)
        if type(info) == "table" and not info.isHeader and Num(info.questID) and not quests[info.questID] then
            QuestInfo(info.questID, true)
            ReadQuest(info.questID, true)
        end
    end
end

-- QW <questID> <1 added or 0 removed>: the quest tracker's watch list.
function H.QUEST_WATCH_LIST_CHANGED(questID, added)
    if not Num(questID) or not Plain(added) then return end
    Emit("QW", questID, added and 1 or 0)
end

-- QA <questID> <name>: another player shared a quest with you.
function H.QUEST_ACCEPT_CONFIRM(name, title, questID)
    if not Num(questID) then return end
    QuestName(questID, title)
    Emit("QA", questID, Str(name) or "")
end

-- Quest sessions (party sync) -----------------------------------------------------------
-- QY <c created, d destroyed, j joined, l left>.

local function Session(state) return function() Emit("QY", state) end end
H.QUEST_SESSION_CREATED = Session("c")
H.QUEST_SESSION_DESTROYED = Session("d")
H.QUEST_SESSION_JOINED = Session("j")
H.QUEST_SESSION_LEFT = Session("l")

-- Quest dialogs and rewards ------------------------------------------------------------
-- QD <stage> <questID> <npcID>: g greeting (the NPC lists its quests), p progress
-- (you hand in items, or the quest is not done), c reward window. The quest is
-- empty in a greeting.

local function Dialog(stage)
    local q = Num(Call(_G.GetQuestID))
    Emit("QD", stage, q and q > 0 and q or "", Npc())
    return q
end

H.QUEST_GREETING = function() Dialog("g") end
H.QUEST_PROGRESS = function() Dialog("p") end

-- The offered choices at a turn-in, read when the reward window opens, so the
-- GetQuestReward hook below can say which one was picked.
local offer = { quest = "", items = {} }

function H.QUEST_COMPLETE()
    local q = Dialog("c")
    offer.quest = q and q > 0 and q or ""
    offer.items = {}
    local n = Num(Call(_G.GetNumQuestChoices)) or 0
    for i = 1, n do
        local link = Call(_G.GetQuestItemLink, "choice", i)
        local id = type(link) == "string" and tonumber(link:match("item:(%d+)")) or 0
        if id and id > 0 then ItemName(id) end
        offer.items[i] = id or 0
    end
end

-- QR <questID> <choice> <itemID> <choices> <offered>: the reward you took when
-- the quest offered a choice. offered lists every itemID offered, joined by commas.
if type(_G.GetQuestReward) == "function" then
    hooksecurefunc("GetQuestReward", function(choice)
        local n = #offer.items
        if n == 0 or not Num(choice) then return end
        Emit("QR", offer.quest, choice, offer.items[choice] or 0, n, concat(offer.items, ","))
    end)
end

-- Gossip -------------------------------------------------------------------------------
-- GS <npcID> <available> <active> <options>: what a gossip window offered, as
-- lists joined by commas: questIDs the NPC can give, questIDs of yours it can
-- take (a `*` after the id when complete), and gossip option ids. Written
-- again for the same NPC only when a list changes.

local gossipSeen, optionNamed, lastOptions, lastByIndex, lastNpc = {}, {}, {}, {}, ""

local function Ids(list, key, mark)
    local out = {}
    if type(list) == "table" then
        for _, q in ipairs(list) do
            local id = type(q) == "table" and Num(q[key])
            if id then
                out[#out + 1] = (mark and Plain(q.isComplete) and q.isComplete) and id .. "*" or tostring(id)
                if key == "questID" then QuestName(id, q.title) end
            end
        end
    end
    return concat(out, ",")
end

-- GN <optionID> <name>: a gossip option's label, once per session.
function H.GOSSIP_SHOW()
    if not GOSSIP then return end
    local npc = Npc()
    lastNpc = npc
    local options = Call(GOSSIP.GetOptions)
    lastOptions, lastByIndex = {}, {}
    local ids, icons = {}, {}
    if type(options) == "table" then
        for _, o in ipairs(options) do
            local id = type(o) == "table" and Num(o.gossipOptionID)
            if id then
                ids[#ids + 1] = id
                local icon = Num(o.icon)
                if icon then icons[#icons + 1] = id .. ":" .. icon end
                lastOptions[id] = o
                local order = Num(o.orderIndex)
                if order then lastByIndex[order] = id end
                local name = Str(o.name)
                if name and not optionNamed[id] then
                    optionNamed[id] = true
                    Emit("GN", id, name)
                end
            end
        end
    end
    local avail = Ids(Call(GOSSIP.GetAvailableQuests), "questID")
    local active = Ids(Call(GOSSIP.GetActiveQuests), "questID", true)
    local opts = concat(ids, ",")
    local key = tostring(npc)
    local iconList = concat(icons, ",")
    local sig = avail .. "|" .. active .. "|" .. opts .. "|" .. iconList
    if key == "" or gossipSeen[key] == sig then return end
    gossipSeen[key] = sig
    Emit("GS", npc, avail, active, opts, iconList)
end

-- GO <npcID> <optionID> <icon> <status> <confirmed>: the gossip option you
-- picked. status is the client's GossipOptionStatus. Anything typed into a code
-- prompt is never recorded. The gossip window's own buttons call
-- SelectOptionByIndex with the option's orderIndex; the confirm and code
-- prompts call SelectOption with the option id.
-- A gossip confirmation (GC 1) is up until it is accepted, cancelled or closed.
local confirming = false

local function Picked(optionID, confirmed)
    local o = lastOptions[optionID]
    local icon, status = "", ""
    if type(o) == "table" then
        icon, status = Num(o.icon) or "", Num(o.status) or ""
    end
    Emit("GO", lastNpc, optionID, icon, status, Plain(confirmed) and confirmed and 1 or 0)
end

if GOSSIP and type(GOSSIP.SelectOption) == "function" then
    hooksecurefunc(GOSSIP, "SelectOption", function(optionID, _, confirmed)
        -- Accepting a confirmation sends it again with confirmed true.
        if Plain(confirmed) and confirmed then confirming = false end
        if Num(optionID) then Picked(optionID, confirmed) end
    end)
end

if GOSSIP and type(GOSSIP.SelectOptionByIndex) == "function" then
    hooksecurefunc(GOSSIP, "SelectOptionByIndex", function(index, _, confirmed)
        local id = Num(index) and lastByIndex[index]
        if id then Picked(id, confirmed) end
    end)
end

-- GC 1 <gossipID> <copper>: a confirmation with a cost appeared. GC 0: it was
-- cancelled. The prompt text is not recorded.
function H.GOSSIP_CONFIRM(gossipID, _, cost)
    confirming = true
    Emit("GC", 1, Num(gossipID) or "", Num(cost) or "")
end

-- Closing the gossip window also drops its confirmation.
local function ConfirmGone()
    if not confirming then return end
    confirming = false
    Emit("GC", 0, "", "")
end
H.GOSSIP_CONFIRM_CANCEL = ConfirmGone
H.GOSSIP_CLOSED = ConfirmGone

-- Player choices -----------------------------------------------------------------------
-- PC <state> <choiceID> <value>: 1 offered (value: number of options), 2 you
-- answered (value: responseID), 0 closed (value: seconds open).

local choiceID, choiceT

function H.PLAYER_CHOICE_UPDATE()
    if not PCHOICE then return end
    local info = Call(PCHOICE.GetCurrentPlayerChoiceInfo)
    local id = type(info) == "table" and Num(info.choiceID)
    if not id or choiceID == id then return end
    choiceID, choiceT = id, GetTime()
    Emit("PC", 1, id, type(info.options) == "table" and #info.options or "")
end

function H.PLAYER_CHOICE_CLOSE()
    if not choiceID then return end
    Emit("PC", 0, choiceID, Round1(GetTime() - choiceT))
    choiceID = nil
end

if PCHOICE and type(PCHOICE.SendPlayerChoiceResponse) == "function" then
    hooksecurefunc(PCHOICE, "SendPlayerChoiceResponse", function(responseID)
        if Num(responseID) then Emit("PC", 2, choiceID or "", responseID) end
    end)
end

-- Reading ------------------------------------------------------------------------------
-- IR <title>: an item or object text opened (a book, letter or plaque). The
-- text and its author are not recorded.

local reading = false

function H.ITEM_TEXT_BEGIN() reading = true end
function H.ITEM_TEXT_CLOSED() reading = false end

function H.ITEM_TEXT_READY()
    if not reading then return end
    reading = false
    Emit("IR", Str(Call(_G.ItemTextGetItem)) or "")
end

-- Content tracking ---------------------------------------------------------------------
-- CK <type> <id> <1 tracked or 0 untracked> <baseline>: type is the client's
-- ContentTrackingType (0 appearance, 1 mount, 2 achievement, 3 decor).
-- baseline `s` for the tracked list read 5 seconds into the session.

local trackedNow = {}

function H.CONTENT_TRACKING_UPDATE(kind, id, isTracked)
    if not Num(kind) or not Num(id) or not Plain(isTracked) then return end
    local key = kind .. ":" .. id
    local on = isTracked and true or false
    if (trackedNow[key] or false) == on then return end
    trackedNow[key] = on
    Emit("CK", kind, id, on and 1 or 0, "")
end

local function TrackedBaseline()
    if not TRACK then return end
    for kind = 0, 3 do
        local list = Call(TRACK.GetTrackedIDs, kind)
        if type(list) == "table" then
            for _, id in ipairs(list) do
                local key = Num(id) and kind .. ":" .. id
                if key and not trackedNow[key] then
                    trackedNow[key] = true
                    Emit("CK", kind, id, 1, "s")
                end
            end
        end
    end
end

-- Session start ------------------------------------------------------------------------

local entered = false
function H.PLAYER_ENTERING_WORLD()
    -- A loading screen closes every window without a HIDE.
    for kind, t0 in pairs(windows) do Emit("NW", 0, kind, Round1(GetTime() - t0)) end
    wipe(windows)
    if entered then return end
    entered = true
    C_Timer.After(5, function()
        Baseline()
        TrackedBaseline()
    end)
end

ns.Listen(frame, H)
