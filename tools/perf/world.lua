-- world.lua: the game state the stub APIs answer from, so a handler does the work it does in the
-- client (reads units, bags, auras, the map) and not an early return on an empty answer.
-- Returned function(Env) is called by env.lua before the unknown-global fallback is installed.
--
-- Every stub goes through Def, which counts calls per API name when Env.countApi is set. The time
-- passes build the stubs without the counter so it costs nothing there.
return function(Env)
    local W = { guids = {}, units = {}, bagItems = {}, auras = { HELPFUL = {}, HARMFUL = {} } }
    Env.world = W
    Env.apiCalls = {}

    local calls = Env.apiCalls
    local function Def(name, fn)
        if Env.countApi then
            _G[name] = function(...)
                calls[name] = (calls[name] or 0) + 1
                return fn(...)
            end
        else
            _G[name] = fn
        end
    end
    local function DefIn(tbl, tname, name, fn)
        if Env.countApi then
            tbl[name] = function(...)
                local key = tname .. "." .. name
                calls[key] = (calls[key] or 0) + 1
                return fn(...)
            end
        else
            tbl[name] = fn
        end
    end

    -- The player ----------------------------------------------------------------------
    local P = { guid = "Player-1-00000001", x = 1000, y = 2000, map = 1429, mx = 0.5, my = 0.5, facing = 1.2,
        speed = 7, mounted = false, level = 60, xp = 1000, xpMax = 90000, money = 123456, flying = false,
        swimming = false, resting = false, group = 0, raid = false, dead = false }
    W.player = P

    -- Units: token -> record. Unit(token, spec) creates or replaces one.
    function W.Unit(token, spec)
        W.units[token] = spec
        if spec.guid then W.guids[spec.guid] = token end
        return spec
    end
    W.Unit("player", { guid = P.guid, name = "Tester", player = true, level = 60, class = "WARRIOR", race = "Human",
        faction = "Alliance", controlled = true, reaction = 5 })

    local function U(unit) return W.units[unit] end
    local function UUnit(unit, field, default)
        local u = W.units[unit]
        if u == nil then return default end
        return u[field]
    end

    Def("UnitGUID", function(unit) return UUnit(unit, "guid") end)
    Def("UnitName", function(unit)
        local u = U(unit)
        if u then return u.name, nil end
    end)
    Def("UnitFullName", function(unit)
        local u = U(unit)
        if u then return u.name, "Realm" end
    end)
    Def("UnitExists", function(unit) return U(unit) ~= nil end)
    Def("UnitIsPlayer", function(unit) return U(unit) and U(unit).player or false end)
    Def("UnitLevel", function(unit) return UUnit(unit, "level", 0) end)
    Def("UnitClass", function(unit)
        local u = U(unit)
        if u and u.class then return u.class, u.class, 1 end
    end)
    Def("UnitRace", function(unit)
        local u = U(unit)
        if u and u.race then return u.race, u.race, 1 end
    end)
    Def("UnitFactionGroup", function(unit)
        local u = U(unit)
        if u and u.faction then return u.faction, u.faction end
    end)
    Def("UnitIsUnit", function(a, b)
        local ua, ub = U(a), U(b)
        return ua ~= nil and ua == ub
    end)
    Def("UnitPlayerControlled", function(unit) return UUnit(unit, "controlled", false) end)
    Def("UnitClassification", function(unit) return UUnit(unit, "classification", "normal") end)
    Def("UnitCreatureType", function(unit)
        local u = U(unit)
        return u and u.ctype or "Humanoid", u and u.ctypeID or 7
    end)
    Def("UnitCreatureFamily", function() return nil end)
    Def("UnitReaction", function() return 2 end)
    Def("UnitIsDead", function(unit) return UUnit(unit, "dead", false) end)
    Def("UnitIsDeadOrGhost", function(unit) return UUnit(unit, "dead", false) end)
    Def("UnitIsGhost", function() return false end)
    Def("UnitIsTapDenied", function() return false end)
    Def("UnitIsAFK", function() return false end)
    Def("UnitOnTaxi", function() return false end)
    Def("UnitThreatSituation", function(who, unit)
        local u = U(unit)
        if u and u.threat and who == "player" then return u.threat end
    end)
    Def("UnitTokenFromGUID", function(guid) return W.guids[guid] end)
    Def("UnitXP", function() return P.xp end)
    Def("UnitXPMax", function() return P.xpMax end)
    -- The level cap: only when bench.lua gets --cap N, so a bare run has the cap unreadable.
    if Env.cap then
        Def("GetMaxPlayerLevel", function() return Env.cap end)
        Def("GetMaxLevelForPlayerExpansion", function() return Env.cap end)
    end
    Def("GetPlayerInfoByGUID", function(guid)
        local token = W.guids[guid]
        local u = token and U(token)
        if u then return "Human", u.class, "Human", "Human", 2, u.name, nil end
    end)
    Def("GetGuildInfo", function() return "Some Guild" end)
    Def("GetMoney", function() return P.money end)
    Def("GetXPExhaustion", function() return nil end)
    Def("IsResting", function() return P.resting end)
    Def("IsPlayerSpell", function() return true end)

    -- Movement and the map --------------------------------------------------------------
    Def("IsFlying", function() return P.flying end)
    Def("IsSwimming", function() return P.swimming end)
    Def("IsMounted", function() return P.mounted end)
    Def("GetUnitSpeed", function() return P.speed end)
    Def("UnitPosition", function() return P.x, P.y, 0, 0 end)
    Def("GetPlayerFacing", function() return P.facing end)
    Def("GetRealZoneText", function() return "Elwynn Forest" end)
    Def("GetSubZoneText", function() return "Goldshire" end)
    Def("GetInstanceInfo", function() return "Elwynn Forest", "none", 1, "", 0, 0, false, 0, 0 end)
    local mapApi = {}
    _G.C_Map = mapApi
    DefIn(mapApi, "C_Map", "GetBestMapForUnit", function() return P.map end)
    DefIn(mapApi, "C_Map", "GetPlayerMapPosition", function()
        -- The client builds a new vector object per call.
        local mx, my = P.mx, P.my
        return { GetXY = function() return mx, my end }
    end)

    -- Group -------------------------------------------------------------------------------
    Def("IsInGroup", function() return P.group > 0 end)
    Def("IsInRaid", function() return P.raid end)
    Def("GetNumGroupMembers", function() return P.group end)

    -- Bags: a new table per slot read, as the client returns ----------------------------------
    _G.NUM_BAG_SLOTS = 4
    local container = {}
    _G.C_Container = container
    DefIn(container, "C_Container", "GetContainerNumSlots", function(bag) return bag <= 4 and 16 or 0 end)
    DefIn(container, "C_Container", "GetContainerItemInfo", function(bag, slot)
        local item = W.bagItems[bag * 100 + slot]
        if not item then return nil end
        return { itemID = item[1], stackCount = item[2], iconFileID = 134400, isLocked = false, quality = 1,
            isReadable = false, hasLoot = false, hasNoValue = false, isBound = false, isFiltered = false,
            itemName = "Item", hyperlink = "|Hitem:" .. item[1] .. "|h[Item]|h" }
    end)
    DefIn(container, "C_Container", "CalculateTotalNumberOfFreeBagSlots", function()
        local used = 0
        for _ in pairs(W.bagItems) do used = used + 1 end
        return 80 - used
    end)

    -- Auras on the player ---------------------------------------------------------------------
    local aura = {}
    _G.C_UnitAuras = aura
    DefIn(aura, "C_UnitAuras", "GetAuraDataByIndex", function(unit, i, filter)
        local a = unit == "player" and W.auras[filter] and W.auras[filter][i]
        if not a then return nil end
        local copy = {}
        for k, v in pairs(a) do copy[k] = v end
        return copy
    end)

    -- Spells and items ---------------------------------------------------------------------------
    local spell, item = {}, {}
    _G.C_Spell, _G.C_Item = spell, item
    DefIn(spell, "C_Spell", "GetSpellName", function(id) return "Spell " .. id end)
    DefIn(spell, "C_Spell", "RequestLoadSpellData", function() end)
    DefIn(item, "C_Item", "GetItemNameByID", function(id) return "Item " .. id end)
    DefIn(item, "C_Item", "GetItemQualityByID", function(id) return id % 6 end)
    DefIn(item, "C_Item", "RequestLoadItemDataByID", function() end)
    DefIn(item, "C_Item", "GetItemInfo", function(id)
        return "Item " .. id, "|Hitem:" .. id .. "|h[Item]|h", 1, 10, 1, "Armor", "Plate", 1, "INVTYPE_CHEST", 134400, 100,
            4, 4, 1, 0
    end)

    -- Strings the client provides (enUS) ---------------------------------------------------------------
    _G.LOOT_ITEM_SELF = "You receive loot: %s."
    _G.LOOT_ITEM_SELF_MULTIPLE = "You receive loot: %sx%d."
    _G.LOOT_ITEM_PUSHED_SELF = "You receive item: %s."
    _G.LOOT_ITEM_PUSHED_SELF_MULTIPLE = "You receive item: %sx%d."
    _G.LOOT_ITEM_CREATED_SELF = "You create: %s."
    _G.LOOT_ITEM_CREATED_SELF_MULTIPLE = "You create: %sx%d."
    _G.SKILL_RANK_UP = "Your skill in %s has increased to %d."
    _G.FACTION_STANDING_INCREASED = "Your reputation with %s has increased by %d."
    _G.FACTION_STANDING_DECREASED = "Your reputation with %s has decreased by %d."
    _G.UNKNOWNOBJECT = "Unknown"
    _G.CHAT_MSG_LOOT_OTHER = "%s receives loot: %s."

    -- The encoding helpers keep the text in a table, so the map build reads chunks the way it does in the
    -- client (DecodeBase64 then DecompressString) without a Deflate implementation here. Core's Seal sees
    -- no CompressString and writes plain "txt" chunks, which is what a recorded-output diff wants.
    W.texts = {}
    _G.C_EncodingUtil = {
        DecodeBase64 = function(s) return s end,
        DecompressString = function(s) return W.texts[s] end,
    }
    _G.Enum = { CompressionMethod = { Deflate = 1 }, CompressionLevel = { OptimizeForSize = 1 } }
end
