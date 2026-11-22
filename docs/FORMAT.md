# Scarlet data format, version 1

The addon writes events into compressed chunks in SavedVariables. The
companion reads them, writes a readable `.txt`, and packs a small payload for
upload. Both sides follow this file. Change it before changing either side.

## SavedVariables

File: `<WoW>/_forever_/WTF/Account/<account>/SavedVariables/Scarlet.lua`.
There can be several account folders; read every one. WoW rewrites this file
only on `/reload`, logout, or disconnect.

```lua
ScarletDB = {
  ["v"] = 1,                    -- format version
  ["seq"] = 42,                 -- last chunk number issued in this file
  ["chunks"] = {                -- oldest first
    {
      ["q"] = 41,               -- chunk number, unique and increasing per file
      ["c"] = "Name-Surname",   -- the player's own character (Forever has no realms)
      ["s"] = 1763600000,       -- session id: epoch seconds when the session began
      ["t"] = 1763600123,       -- epoch seconds at the chunk's time base
      ["n"] = 512,              -- number of lines
      ["e"] = "d64",            -- encoding, see below
      ["z"] = "...",            -- payload
      ["r"] = 1,                -- present when the chunk was recovered from a saved buffer
    },
  },
  ["buf"] = { "...", ... },     -- lines not yet sealed into a chunk
  ["bufT"] = 1763600123,        -- time base of buf; bufC and bufS hold its character and session
  ["gaps"] = { { from = 3, to = 9, at = 1763600999 } },  -- chunk numbers dropped for space
  ["chars"] = { ... },          -- lifetime counters for the in-game window; the companion ignores it
  ["opt"] = { ... },            -- settings; the companion ignores it
}
```

Encodings:

- `d64`: `C_EncodingUtil.CompressString(text, Enum.CompressionMethod.Deflate)`
  then `EncodeBase64` (RFC 4648 standard alphabet, padded). Decoders try raw
  DEFLATE first and fall back to zlib.
- `txt`: the text itself, used when compression failed.

The addon drops the oldest chunks once the file passes its size budget (8 MB
of payload; it warns in chat at 6 MB), so the companion must keep its own
record of which chunks it has exported. The key is the SavedVariables file
path plus `q`. Each drop is recorded in `gaps`.

Lines not yet in a chunk live in `buf`, inside SavedVariables, so a reload,
logout or disconnect saves them whichever addon's logout handler runs last.
At the next load the addon seals a leftover `buf` into a chunk with `r = 1`,
using `bufT`, `bufC` and `bufS`, before writing anything new. A client crash
writes no SavedVariables at all; lines since the last save are then lost.

## Chunk text

Lines are separated by `\n`. Fields are separated by `\t`. No field contains
a tab or newline; the addon strips them.

```
<dt>\t<code>\t<field>\t<field>...
```

`dt` is the time since the previous line in centiseconds, as a decimal
integer. For the first line it counts from the chunk's time base `t`. A
line's absolute time is `t + (sum of dt up to and including that line) / 100`.

A field the client marked secret is written as `?`. Missing values are empty.

## Codes

| Code | Fields | Meaning |
| --- | --- | --- |
| `S` | build, classFile, raceFile, level, faction, addonVersion, serverID, serverName, region, toc, xp, xpMax, money, levelCap | Session started (login or reload). region is the client's region id, toc its interface number, xp and xpMax the experience bar at login (empty when the client hides them, and at the level cap or with experience turned off, where the addon reads no bar), money the copper you carry (`GetMoney`), levelCap the max level the client reports for the character (`GameRulesUtil.GetEffectiveMaxLevelForPlayer`, else the lower of `GetMaxLevelForPlayerExpansion` and `GetMaxPlayerLevel`; empty when the client does not say). serverID and serverName are the client's realm ID and name; Forever has no realms and reports `0` and empty. Lines from before 2026-11-20 14:00 end at addonVersion or have one empty field after it; lines from before money was added end at xpMax; lines from before levelCap was added end at money |
| `ES` | | Session ended (logout or reload) |
| `Z` | uiMapID, instanceMapID, instanceType, difficultyID, zone, subzone | Area changed. instanceType is `none`, `party`, `raid`, `pvp`, `arena` or `scenario` |
| `P` | uiMapID, x, y, facing | Path point while moving. x and y are map coordinates times 10000, as integers. facing is the way you face as one of 16 directions (0 is north, counting counter-clockwise like the client's radians), empty when the client gives none. Older lines have no facing |
| `SZ` | uiMapID, subzone, x, y | The first time this character entered a subzone, one line per subzone per character (the set is kept in the character's SavedVariables up to 2000 subzones; past that a subzone is written once a session). subzone is the name from `GetSubZoneText`, the same one the `Z` line carries; x and y are where the player stood on the map, map coordinates times 10000 as in `P` |
| `W` | mode, yards, seconds, jumps, jumpAt | A stretch of movement ended. jumpAt is the seconds from the start of the stretch to each jump, comma-separated, at most 20. mode: `f` running, `w` walking (on foot under 4 yd/s), `m` mounted, `s` swimming, `a` flying |
| `T` | 1, uiMapID, x, y | Flight path started |
| `T` | 0, uiMapID, x, y, seconds | Flight path ended |
| `C` | spellID, castSeconds | You cast a spell (succeeded). castSeconds is empty for instant casts |
| `CH` | spellID, seconds | A channel you started ended (fishing, some crafts) |
| `CI` | spellID, seconds | Your cast was interrupted |
| `SN` | spellID, name | Spell name, written once per session the first time the spell appears |
| `IN` | itemID, name | Item name, written once per session the first time the item appears |
| `K` | npcID, by | A mob died to your group. by: `1` you or your pet, `0` a party member, `2` a mob you or your pet had on its threat list died without the client reporting the killing blow (pet, DoT or other) |
| `N` | npcID, name | Name for an npcID, written once per session the first time it is seen |
| `NS` | npcID, level, classification, creatureType, typeID, family, familyID, reaction, uiMapID, cellX, cellY | A creature you saw on your target, mouseover or a nameplate. level is `-1` when the client hides it; classification the client's (`normal`, `elite`, `rare`, `rareelite`, `worldboss`, `trivial`, `minus`); creatureType and family are the client's names with their ids (empty when it has none); reaction is the client's 1 to 8 toward you. Pets, guardians, totems and other player-controlled units are skipped. uiMapID, cellX and cellY are where YOU stood when you saw it, not where the creature was: cells are 0.015 of the map (`x * 10000 / 150`, rounded down). Written once per npc per character and again when a new level is seen for it (the character keeps up to 6000 npcs; past that an npc is written once a session), at most 1200 creatures a session. The creature's `N` line is written first |
| `D` | | You died |
| `R` | | You released your spirit |
| `U` | | You came back to life |
| `F` | 1 | Combat started |
| `F` | 0, seconds | Combat ended |
| `E` | 1, encounterID, difficultyID, groupSize, name | Boss encounter started |
| `E` | 0, encounterID, success, seconds | Boss encounter ended. success is `1` or `0` |
| `B` | encounterID, name | Boss killed |
| `L` | level | You reached a new level |
| `X` | amount, xp, xpMax, source, id | Experience gained. Not written once the character is at the level cap (the S line's levelCap) or has experience turned off; the addon unregisters the experience events then, and the last line of the final level is still written. xp and xpMax are the experience bar after the gain (a level up shows the new level's bar). source: `k` a kill (id the npcID), `q` a quest turn-in (id the questID), `e` an area discovery, `o` none found. The source is the nearest one noted within 1.5 s of the gain, used once, with a quest or discovery winning over a kill; the line is written 0.8 s after the client reports the gain (or at logout, whichever is first) so a source that arrives just after it is still found, such as a `K` with by `2`. A kill that gives no experience near a gain can be taken for its source. Older lines have the amount only |
| `M` | copper, transfer, balance | Money changed, signed. transfer is the part mailed or traded to (negative) or taken or received from (positive) one of your own characters, on any of your game accounts (the addon's own characters and every one in the companion's digest); it is neither earned nor spent. Empty for other changes and on older lines. balance is the copper you carry after the change (`GetMoney`); the transfer field is written empty when a balance follows. Older lines have one or two fields |
| `O` | itemID, count, suffixID, bonusIDs, upgrade | You received an item from a loot or push message, created items included (`LT`, the others' receipts, has no created items). suffixID is the link's random suffix (empty for none), bonusIDs its bonus IDs comma-joined, upgrade the client's upgrade level for the link (`C_Item.GetItemUpgradeInfo`, only asked for links with bonus IDs). The link's unique ID is not kept. Older lines stop after count |
| `Q` | 1, questID | Quest accepted |
| `Q` | 2, questID, xp, copper | Quest turned in |
| `G` | slot, itemID, suffixID, bonusIDs, upgrade | Equipment slot changed. itemID 0 means emptied. The last three read the equipped item's link the way `O` does |
| `II` | itemID, classID, subclassID, equipLoc, itemLevel, reqLevel, sellPrice, bindType, stack | What the client says an item is, from `C_Item.GetItemInfo`: item class and subclass, equip slot (`INVTYPE_...`), base item level, required level, vendor sell price in copper, bind type (`0` none, `1` on pickup, `2` on equip, `3` on use, `4` quest), stack size. Written once per item per character, the first time the item is named (any `IN` source: bags, loot, gear, vendors, quests). The seen set is kept in the character's SavedVariables up to 8000 items; past it an item is written once a session. An item the client has not loaded is asked for once and written when `GET_ITEM_INFO_RECEIVED` answers (at most 100 waiting) |
| `IT` | itemID, text | The item's tooltip text for items above id 270000 (Forever's own items): up to 14 lines and 700 characters, left and right text joined by ` \| `, colour and texture codes removed. Written right after the item's `II` |
| `SK` | skill, rank | A skill went up |
| `RP` | faction, amount | Reputation changed, signed |
| `AC` | achievementID | Achievement earned |
| `LG` | 0 or 1 | Combat logging to WoWCombatLog.txt turned off or on |
| `A` | 1, spellID, helpful, duration, by, initial | You gained an aura. helpful `1` buff, `0` debuff. by `1` from you or your pet, `0` from someone else, empty if unknown. initial `s` when it was already on at session start |
| `A` | 0, spellID, seconds | An aura ended, with how long it lasted |
| `CP` | 1, spellID, continued | Camp visit started: the first camp aura (Forever camp spells, or any aura named "Camp...") appeared. continued `1` after a reload at the same camp |
| `CP` | 0, seconds | Camp visit ended: the last camp aura went away, or the session ended |
| `RS` | 0 or 1 | Resting state (inn, city, camp) changed |
| `RX` | 1, xp or 0 | Rested XP started or ran out. Not written at the level cap or with experience off |
| `RO` | restedXP, xpMax, resting | The rested XP, the XP the current level needs and whether you were resting (`1` or `0`), written at logout just before `ES`. Not written at the level cap or with experience off, nor when the client gave no values |
| `AFK` | 0 or 1 | You went AFK or came back |
| `I` | itemID, delta, where, npcID, sellPrice | Bag contents changed. where: `v` vendor, `b` bank, `m` mail, `t` trade, `l` loot, `a` auction house, `c` profession window, `g` guild bank, empty otherwise. At a vendor (`v`) npcID is the vendor and, for items that left the bags, sellPrice is the item's vendor sell price per unit in copper (empty when the client had no price); both fields are not written for other places |
| `BC` | where, itemID:count,... | What your character holds, for the app's and the game's item search. where `b` is the bags (backpack and the four bag slots), written at logout or reload just before `RO` and `ES`; `k` is the character bank, written when the bank window closes, only when its list changed since the last one this session. Tabs come from `C_Bank.FetchPurchasedBankTabData(Enum.BankType.Character)`, each tab's `ID` read with `C_Container.GetContainerNumSlots` and `GetContainerItemInfo`, the way Forever's own bank window (Camelot `BankFrame.lua`) reads them. The warband bank is not read. Counts add up stacks of one item. At most 150 items a line, sorted by itemID; a list longer than that is several `BC` lines in a row with the same where and nothing between them, and a reader starts a new list at the first `BC` line of a where that follows any other line. An empty list is a line with no items. Never uploaded: the code is in no sharing group |
| `GP` | 1, size or 0, size | You joined a group or went solo |
| `GM` | 1, Name-Surname | A player was in your group (joined, or already there at session start) |
| `GM` | 0, Name-Surname, seconds | A player left your group, with time grouped together |
| `WD` | word, count | You said a tracked word (`lol`, `rip`). Only the word and count are kept |
| `EM` | token | You used an emote (`LOL`, `WAVE`, ...) |
| `DM` | meter, total, perSecond, seconds | Your total from the client damage meter after a fight. meter: `d` damage, `h` healing, `t` damage taken, `a` absorbs, `i` interrupts, `x` dispels |
| `DS` | meter, spellID, amount | One of your top 5 spells for that meter (damage and healing) |
| `DP` | meter, Name-Surname, classFile, total | A group member's total for that meter, up to 10 per fight |
| `DL` | uiMapID, x, y | Where you died (map coordinates times 10000) |
| `RZ` | name | Someone offered you a resurrection |
| `SH` | | You took the spirit healer's resurrection |
| `DU` | name | Someone asked you to duel |
| `DW` | 1 or 0, opponent | You won or lost a duel |
| `EX` | area, xp | You discovered an area |
| `XR` | amount | Rested bonus XP on a kill. Not written at the level cap or with experience off |
| `MT` | 1, timer or 0, timer, seconds | Breath, fatigue or feign death timer started or ended (`BREATH`, `EXHAUSTION`, `FEIGNDEATH`) |
| `DB` | averagePct, lowestPct, broken | Gear durability moved 5 points or an item broke |
| `RE` | copper | You repaired at a vendor |
| `NI` | kind, npcID, name, faction, canRepair | You opened an NPC window. kind: `g` gossip, `v` vendor, `f` flight master, `t` trainer, `b` bank, `a` auction, `q` quest giver. faction is the NPC's side as the client names it (`Horde`, `Alliance` or `Neutral`; empty when the client gives none); canRepair is `1` or `0` for a vendor and empty otherwise. Older lines stop after name |
| `QN` | questID, title | Quest name, when accepted |
| `Q` | 3, questID | A quest left your log without a turn-in (abandoned or failed) |
| `LS` | spellID | You learned a spell |
| `LR` | recipeID | You learned a recipe |
| `TL` | change | Talent points changed |
| `HB` | place, why | Hearthstone bound. why `s` is the bind found at login when it differs from the last one this character wrote, so a bind set while the addon was off or before it existed still has a line. Empty when you bound it |
| `HK` | lifetime, gained | Honorable kills went up |
| `HN` | amount, victim, rank | Honor gained. victim and rank (the victim's rank title) come from the honorable kill message when the client's format strings match it and are empty otherwise |
| `PK` | name, classFile, raceFile, level, by, faction | A player died to your group (the `K` line has npcID `p`). name is Name-Surname; level and faction are read from the unit when the client still has a token for it. by as in `K`, `1` you or your pet, `0` a party member |
| `PV` | 1 or 0 | PvP flag on or off |
| `PT` | name, family | Your pet changed (empty name when dismissed) |
| `SS` | file, trigger, moment | You took a screenshot. file is the name the client gives it, `WoWScrnShot_MMDDYY_HHMMSS.<screenshotFormat>`, rebuilt from the time (the event does not give it) so it can be a second off. trigger `c` when a Screenshot() call was seen in the 10 seconds before (a key, macro or another addon), empty when none was. moment is why Scarlet took it, and is empty for any other screenshot: `lv` a level up, `de` a death, `bk` a boss kill, `ep` an epic or better item received, `nc` a new collectible (`NC`), `dw` a duel won, `pk` a PvP kill by you or your pet. Scarlet takes screenshots only when "Take screenshots at key moments" is on in its Settings page (`opt.shots`, off by default), at most one in 5 seconds, by calling the client's own Screenshot(); it hides nothing and never reads a picture. Older lines have fewer fields |
| `TP` | totalSeconds, levelSeconds | Time played, whenever the client reports it (`/played`). Scarlet asks for it a few seconds after login, 1.5 seconds after each level up and when the logout countdown starts, and keeps its own requests out of the chat frames. The counter is the lifetime figure: the sessions' recorded time is checked against it to find play Scarlet did not record (docs/OVERVIEW.md, "Lifetime and observed numbers") |
| `RL` | rollType, itemID | You rolled on loot: `0` pass, `1` need, `2` greed |
| `ST` | level, copper, str, agi, sta, int, spi, armor, maxHealth, maxPower, itemLevel | Character snapshot at login and each level |
| `GR` | preset, hardcore | Forever experience preset and hardcore flag at login |
| `DR` | spellID, amount, source, environmental, pos, overkill, hp, maxHP, before, school | One of the last 3 hits before you died, from the client death recap. pos `1` is the killing blow, `2` and `3` the hits before it (lines written before pos existed read the oldest 3 and carry no pos). overkill is damage past zero health, hp your health when the hit landed, maxHP your max health, before the seconds between this hit and the killing blow, school the spell school mask. The killing blow (pos `1`) has six more fields: killerKind, killerLevel, killerClass, killerRace, killerGuild and hits. killerKind is `p` when the source was a player you could see and `c` for a creature, empty when the source was not on your target, focus, mouseover, a nameplate or a party or raid member's target when you died (or its name did not match); killerLevel is its level (empty when the client hides it); killerClass is the player's class file or the creature's classification (`normal`, `elite`, `rare`, `rareelite`, `worldboss`, `trivial`, `minus`); killerRace and killerGuild are the player's race file and guild name, empty for a creature or a player in no guild; hits is how many hits the client's recap holds in all, of which the first 3 are written. Lines before this have none of them |
| `CU` | currencyID, change, quantity, gainSource, destroyReason | A currency changed, with the client's reason codes |
| `CN` | currencyID, name | Currency name, once per session |
| `CR` | itemID, quantity, crit, multicraft | You crafted an item |
| `CC` | locType, spellID, seconds, priority, displayType | You lost control: stun, fear, root, silence, and so on. Forever hides locType, spellID and seconds while control is restricted (nearly always); they are `?` then. priority and displayType are the client's and never hidden: displayType `2` shows the large loss-of-control banner, `1` an alert, `0` nothing. Older lines stop after seconds |
| `NC` | kind, id, name | New collectible: `mount`, `toy`, `pet`, `companion` or `title` |
| `TS` | 1, professionID, name, skill, maxSkill, modifier, parentProfessionID | A profession window opened. Fields after `1` are empty when the client had no details |
| `TS` | 0 | The profession window closed |
| `CB` | recipeSpellID | A craft started |
| `CS` | scrapping | A craft, or a queue of crafts, stopped. scrapping `1` for salvage |
| `CR` | itemID, quantity, crit, multicraft, recipeSpellID, quality, bonusCraft, concentrationSpent, ingenuity, firstCraft, resourcesReturned, enchant | You crafted an item. Older lines stop after multicraft. resourcesReturned counts reagent stacks given back |
| `CW` | currencyID, quantity, firstCraft, recipeSpellID | A craft paid a currency |
| `SC` | reason, key, value | A character stat changed. reason: `s` session baseline, `g` gear, `l` level, `t` talents, `a` auras (buffs, food, camps), `o` other. Keys below |
| `SL` | skillID, rank, max, modifier, baseline | A skill line (weapon, defense, profession, language) changed. baseline `s` on the session's first scan |
| `KN` | skillID, name, categoryID | Skill line name, once per session |
| `WS` | statisticID, value | A statistic from the client's Statistics panel changed. value is the client's text: a number, or money with coin icon escapes. All values are rewritten once a day |
| `WN` | statisticID, name, categoryID | Statistic name, once per session |
| `AP` | points, completed, total | Achievement (Legacy Challenge) totals at login and after each one earned |
| `AN` | achievementID, name, points | Name of an achievement you earned |
| `AE` | achievementID, description | You completed one criterion of an achievement |
| `LV` | level | Legacy reward track renown level, at login and when it changes |
| `LB` | earned, available, spent, seasonalCap, maxAvailable, spentProfessions, spentAdventure, spentProgression, why | Legacy points balance. earned is the Legacy reward track level (the number on the shield, one per point earned). available is what you can still spend, spent what you have spent across the three Legacy trees (they share one currency), seasonalCap the client's cap for the currency and maxAvailable the most you can earn in total (`earned / max` in the challenge window). The last three are spent in the Professions, Adventure and Progression trees. Counts committed purchases only. why: `s` the first read of a session, `c` a number changed. Written when any field differs from the last `LB` of the session, a few seconds after a challenge, a purchase or a refund |
| `LA` | achievementID, points | A Legacy Challenge you just completed paid this many Legacy points. Skipped when the client re-announces an old earn, and for an achievement that pays nothing. `AD` and `AN` carry the same achievementID |
| `LN` | treeID, nodeID, entryID, rank, oldRank, ranksPurchased, maxRanks, spellID, why, name | A node of a Legacy tree changed its committed rank (a purchase, a refund or a reset), or, with why `s`, a baseline of every node that has a rank at login (oldRank empty). treeID: `1187` Professions, `1188` Adventure, `1189` Progression. rank is the node's `activeRank`, the value the tree UI reads for a purchased node; ranksPurchased counts the purchases behind it. entryID is the active entry (the first entry on a node with no rank). spellID is the entry's spell, named by `SN`; name is the definition's own name, filled only when it has no spell. Ranks you have staged in the tree window but not applied are not written; the apply writes them |
| `LO` | kind, id, slots, items, again | A loot window's source: `c` creature (npcID), `g` object such as a herb, vein, chest or bobber (objectID), `i` an item opened from your bags (its itemID, empty when the client didn't say which item; a fished clam reads `LO g 35591`, `O 7973`, then `LO i 7973` and the pearl's `O` line), `o` other. One line per source. items is what that source put in the window, comma-joined: `itemIDxquantity`, `m` coin (`mxN`, N the client's quantity), `c<currencyID>xquantity`, read from the loot window itself. again is `1` when the same corpse or object was read in the last 5 minutes (skinning it, opening it a second time, or a group member's Scarlet reported it first in an `LW` line), `0` for a first read, empty for an item. Lines before 2026-11-20 15:00 have no items |
| `PR` | name, present | Once per client build and day: whether an API Scarlet uses exists (`1`) or not (`0`). The loot code also probes the client's loot message format strings (`LOOT_ITEM`, `LOOT_ROLL_WON`, ...) |
| `TW` | slot, spellID, seconds | A totem entered one of your totem slots, with its duration. spellID 0 when the slot emptied |
| `IL` | 1, seconds, name, complete, total | You are in (or entering) an instance you are saved to: the lock's time left and bosses completed of total |
| `IL` | 0 | You left the saved instance (the lock popup closed) |
| `SKN` | hasFreeRepop | Your corpse was skinned by someone. hasFreeRepop `1` when a free repop was available |
| `SR` | optionType, id | A self-resurrect option was available while you were dead: `0` a spell, `1` an item. Once per death |
| `RD` | recipeSpellID, difficulty, skillUps, canSkillUp, recraft, salvage, enchant, firstCraft, qualities | A craft began (`CB`) and the recipe's values differ from its last `RD`. difficulty: `0` optimal, `1` medium, `2` easy, `3` trivial, empty when the client gives none. skillUps is the skill points one craft can give. The other fields are `1` or `0` |
| `RT` | recipeID, tracked, baseline, recraft | You tracked (`1`) or untracked (`0`) a recipe for its reagents. baseline `s` on the tracked list read 5 seconds into the session. recraft `1` only on the baseline list of recrafts |
| `PG` | slot, itemID, profession, skillLineID | A profession tool or accessory slot changed. itemID 0 means emptied. profession is the client's Profession enum (`0` first aid, `1` blacksmithing, `2` leatherworking, `3` alchemy, `4` herbalism, `5` cooking, `6` mining, `7` tailoring, `8` engineering, `9` enchanting, `10` fishing, `11` skinning, `12` jewelcrafting, `13` inscription, `14` archaeology). skillLineID is empty when emptied or unknown. `G` records the same change without the profession |
| `PS` | skillLineID, unspent | Specialization points available for a profession line changed. The knowledge currency itself changes in a `CU` line |
| `PU` | skillLineID, tradeSkillID | Specializations unlocked for a profession line |
| `PO` | profession, count, name | Personal crafting orders waiting for you, per profession. count `0` when that profession's orders are gone. Customers are not recorded |
| `CO` | orderType, item, quantity, tip | You fulfilled a crafting order. orderType and item are the client's text, tip is copper. The customer's name is not recorded |
| `QI` | questID, level, frequency, classification, tagID, suggestedGroup, campaignID, timeAllowed, baseline | A quest's kind, when accepted or found in the log 5 seconds into the session (baseline `s`). frequency: `0` once, `1` daily, `2` weekly. classification is the client's QuestClassification (`0` important, `2` campaign, `3` calling, `5` recurring, `7` normal, `10` world quest). timeAllowed is seconds for a timed quest. Quests under collapsed log headers are not found at baseline |
| `QP` | questID, index, fulfilled, required, type, text | A quest objective's count changed. type is the client's objective type (`monster`, `item`, `object`, `event`, ...), or `criteria` with index the criteria tree id. text only on the first line for that objective in a session, without its trailing count |
| `QS` | questID, state | `c` the quest became complete, `u` it stopped being complete, `f` it failed, `a` it can be turned in anywhere (auto-complete) |
| `QA` | questID, name | Another player shared a quest with you. name is the player, without realm |
| `QD` | stage, questID, npcID | A quest dialog opened: `g` greeting (questID empty), `p` progress, `c` reward window |
| `QR` | questID, choice, itemID, choices, offered | The reward you took when the quest offered a choice. offered lists every itemID offered, joined by commas |
| `QW` | questID, added | A quest was added (`1`) to or removed (`0`) from the tracker |
| `QY` | state | Quest session (party sync): `c` created, `d` destroyed, `j` joined, `l` left |
| `QK` | campaignID, name, state, chapterID | A campaign was seen, or its state or current chapter changed. state is the client's CampaignState (`1` complete, `2` in progress, `3` stalled) |
| `NW` | 1, type, npcID | An NPC or object window opened. type is the client's PlayerInteractionType (`3` gossip, `4` quest giver, `5` merchant, `6` flight master, `7` trainer, `8` banker, `20` binder, `21` auctioneer, `22` stable master, ...). npcID is empty for windows without an NPC |
| `NW` | 0, type, seconds | That window closed, with how long it was open |
| `GS` | npcID, available, active, options, icons | What a gossip window offered, each a comma list: questIDs the NPC can give, questIDs of yours it can take (`*` after an id when complete), gossip option ids. icons is `optionID:iconFileID` for each option that has an icon. Written again for the same NPC only when a list or an icon changes. The gossip text is not recorded |
| `GO` | npcID, optionID, icon, status, confirmed | The gossip option you picked. status is the client's GossipOptionStatus (`0` available). Text typed into a code prompt is not recorded |
| `GN` | optionID, name | Gossip option label, written once per session the first time the option is seen |
| `GC` | 1, gossipID, copper | A gossip confirmation with a cost appeared |
| `GC` | 0 | The confirmation was cancelled |
| `PC` | 1, choiceID, options | A player choice popup was offered |
| `PC` | 2, choiceID, responseID | You answered a player choice |
| `PC` | 0, choiceID, seconds | The player choice closed |
| `IR` | title | You opened an item or object text (a book, letter or plaque). Only its title is kept |
| `CK` | type, id, tracked, baseline | Content tracking changed. type is the client's ContentTrackingType (`0` appearance, `1` mount, `2` achievement, `3` decor). tracked `1` or `0`. baseline `s` on the tracked list read 5 seconds into the session |
| `VB` | kind, itemID, count, copper, npcID, extended | You bought from a vendor (kind `b`) or bought back (`r`). copper is the whole price. extended `1` when the item also cost currency or items (`CU` and `I` show which). Selling is an `I` line with where `v` |
| `VS` | npcID, count, items | Everything a vendor lists, read 0.7 s after the window opens and again (debounced) when the list refreshes. items are `itemID:price:stack:limit:cost` joined by commas: price in copper, stack the units one purchase gives, limit how many are left at the time of the read (`-1` unlimited), cost the extra price as `i<itemID>x<n>` or `c<currencyID>x<n>` joined by `+` (empty when there is none). Written once per vendor per character and again when an item, its price, stack, cost or whether it is limited changes; a limited item selling down is not a change. Up to 150 items a line and 600 vendors in the character's seen set (a checksum each), past which a vendor is written once a session. Vendors with no npcID are skipped |
| `AU` | kind, auctionID, itemID, count, copper, copper2, duration, commodity | Auction house. kind `p` you posted (copper bid, copper2 buyout; for a commodity, copper2 is the unit price and commodity `1`), `b` you bid (copper), `y` you bought (copper paid; for a commodity, copper2 is the unit price), `x` you cancelled, `s` one of yours sold, `e` expired, `o` you were outbid, `r` one of yours was removed. auctionID is empty for commodity purchases. itemID and count are empty when the addon had not seen the auction. What a sale paid is in the mail you take (`ML`, `M`). Notification text is not recorded |
| `AV` | invoiceType, itemName, count, bid, buyout, deposit, cut, why | An auction house invoice in your inbox, with the client's numbers: invoiceType `seller` (something of yours sold), `buyer`, or `seller_temp_invoice` (a sale still pending). bid is what it sold or was bought for, buyout the buyout price, deposit the deposit you paid, cut the house's consignment, all copper. why: `i` read when the inbox was shown or changed (every mail in it, up to 50, after 0.7 seconds), `o` read when you opened the mail, `t` read when you took money or items from it. An invoice is written once however it is read first: it is told apart by its numbers and the time its mail expires, kept per character (400 of them), so a mail that moves down the list when others are taken, or an inbox shown again, writes nothing new. The client may give an invoice only for a mail it has loaded, so one can first appear on `o` or `t`. The other party's name, the mail subject and the mail text are never read; Scarlet does not call GetInboxText (it would mark the mail read) and only sees the client's own calls to it. Lines written before the why field read as taken (`t`) and end at cut |
| `ML` | kind, who, copper, cod, items, postage | Mail. kind `s` you sent (who is the recipient, copper the money, cod the cash on delivery, postage the copper the post office charged, 0 or empty when not read), `m` you took money (who is the sender), `i` you took attachments (cod is what the mail asked you to pay), `r` you returned a mail. items is `itemID:count` joined by commas. A take is written when you ask for it; `M` and `I` show what arrived. Subjects and bodies are never read |
| `TR` | 1, who | A trade window opened with that player |
| `TR` | 0, who, done, gaveCopper, gotCopper, gave, got | It closed, half a second later. done `1` when the client said the trade was complete, `2` when both sides accepted but no completion message came (it can still have failed), `0` when it was cancelled (the rest is then empty). gave and got are `itemID:count` lists joined by commas |
| `BK` | kind, bankType, value | Bank money. kind `d` you deposited and `w` you withdrew (value copper), `t` tabs bought (value is the tab count). bankType is the client's BankType: `0` character, `1` guild, `2` warband. Items moved in and out are `I` lines |
| `BG` | free, total, why | Free and total bag slots. why: `s` first reading of the session, `t` the total changed (a bag was equipped or removed), `f` bags became full, `o` they were no longer full, `w` the client said an item did not fit |
| `EN` | slot, itemID, enchantID, gems, wasEnchantID, wasGems | The same item in an equipment slot got a new enchant or new gems. gems are itemIDs joined by commas. Swapping the item is a `G` line. Read from item links 6 seconds after login and on each inventory change |
| `WE` | slot, enchantID, charges, seconds | A temporary weapon enchant (oil, poison, imbue) on slot `0` main hand, `1` off hand, `2` ranged. enchantID `0` when it ended |
| `IU` | itemID, level, maxLevel, upgrades, itemLevel | You upgraded an item. The levels are from before the upgrade. The currency spent is a `CU` line |
| `RW` | kind, itemID, rollType, roll, extra | A loot roll. rollType is the client's LootRollType (`0` pass, `1` need, `2` greed, `3` disenchant, `4` transmog). kind `o` a roll was offered to you (extra: milliseconds to decide), `w` you won (roll is your number, extra the count), `l` someone else won an item you rolled on (roll is your number, extra the winner's). Who won is in the `LD` lines. What you chose is `RL` |
| `BR` | type, id, count, specID | A bonus roll paid out. type is the client's identifier (`item`, `money`, `currency`); id is the itemID or currencyID |
| `TK` | kind, value | WoW Token. kind `p` the market price changed (copper), `b` and `s` the client's result code for a buy or a sell, `a` your token sold (value empty) |
| `LP` | specID | Loot specialization changed. `0` follows your current spec |
| `DI` | itemID, count | You destroyed an item with the delete command. The item is the last one you picked up from your bags and still held |
| `YG` | source, copper | Imported history: a gold balance another addon logged (`source` is `TSM`). Written by the companion into `imports/payloads/import.scl`, never by the addon. Group `imports` |
| `YS` | source, via, itemID, count, copper | Imported history: a sale another addon booked. via is `auction`, `vendor`, `trade` or `other`; copper is the whole amount received after the house's cut. No buyer is named. Group `imports` |
| `YB` | source, via, itemID, count, copper | Imported history: a purchase another addon booked, as `YS`. Group `imports` |
| `YM` | source, kind, copper | Imported history: other income or expense another addon booked (`money-transfer`, `repair-bill`, `postage`), copper signed. Group `imports` |
| `RF` | factionID, reaction, standing, floor, ceiling, atWar, accountWide, why | A faction's standing differs from the last `RF` line for it. reaction is the client's tier (`1` hated, `2` hostile, `3` unfriendly, `4` neutral, `5` friendly, `6` honored, `7` revered, `8` exalted). standing is the client's number; floor and ceiling bound the tier. atWar and accountWide are `1` or `0`. why `s` on the first read of the session. Written from a scan 3 seconds after the client reports a change, with the standing, so a gain shows here once and `RP` keeps the amount by name. Each day starts with every faction again. Factions the player has never had expanded in the reputation list are found only after they change |
| `FN` | factionID, name | Faction name, once per session, before the first `RF` or `RV` line for it |
| `RG` | factionID, value, threshold, rewardPending, level, why | A paragon track (a faction at exalted) changed its reward-pending flag or its level. value and threshold are the progress toward the next reward. why `s` on the first read of the session |
| `RV` | kind, factionID, level, oldOrMax, earned, threshold | Major faction renown. kind `b` baseline at 8 seconds into the session for each unlocked major faction (level, max level, renown earned toward the next level, what the next level needs), `l` a level change (level, old level; empty earned and threshold; the Legacy reward track's level change is `LV`), `u` a major faction unlocked (only the faction) |
| `RR` | factionID, level, itemID, spellID, mountID, transmogSetID, titleMaskID | One reward of a renown level you reached. Fields the reward does not have are empty |
| `AD` | achievementID, alreadyEarned, guild, categoryID, rewardText | The client's details for an achievement it reported newly earned, once per achievement per character. A re-announced old earn writes no `AD`, so alreadyEarned is always `0` (kept for older logs). guild `1` for a guild achievement. rewardText is the client's reward line (a title, a mount) |
| `AT` | achievementID, criteriaID, quantity, required, done, text, duration | A tracked achievement's criterion changed its numbers. text is the criterion's own description, only on the first line for it in a session. duration is seconds for a timed criterion. Tracking and untracking an achievement is `CK` type `2` |
| `BQ` | state, index, map, teamSize, rated, queueType, role, seconds, from, baseline | A battleground queue slot changed. state: `q` you queued, `c` the match is ready, `a` you entered it, `x` the queue ended. seconds is how long the slot spent in its last state, from that last state (`q`, `c` or `a`) on `x`: `q` then `x` is leaving the queue, `c` then `x` is declining or missing the invite. rated is `1` or `0`. queueType and role are the client's text. baseline `s` for a queue already there at session start. Written once per change of status or map, read from the client's queue status; the map is the battleground's name |
| `BM` | 1, instanceMapID, zone, instanceType, matchState, baseline, rated, factional, arena, team | You are in a PvP match (a battleground or arena). matchState is the client's PvPMatchState (`0` inactive, `1` waiting, `2` start-up, `3` engaged, `4` post-round, `5` complete). team is your side, `0` Horde or `1` Alliance. baseline `s` when the match was already running at session start. rated, factional and arena are `1` or `0` |
| `BM` | 2, instanceMapID | The match started (gates open) |
| `BM` | 0, instanceMapID, winner, duration, team, result, affectsRating, arena | The match ended. winner is the client's side (`0` Horde, `1` Alliance; in an arena (arena `1`) a team index; any other value is a draw). result is `w` you won, `l` you lost, `d` a draw, empty when your side is unknown. duration is the client's number. affectsRating is `1` or `0` |
| `BM` | 3, instanceMapID, seconds | You left the match, with the time you were inside |
| `BS` | killingBlows, honorableKills, deaths, honorGained, damageDone, healingDone, rating, ratingChange, mmrChange, honorLevel, spec, role, teamSize, enemySize, stats | Your own scoreboard row, once per match, after it ends. stats are the mode's objective numbers as `id:value` joined by commas (`BN` names the ids). The client keeps the scoreboard secret while a match runs and Scarlet reads the row by GUID only afterwards, so a value can still be `?`, and a line with only `?` means the client gave no row at all. Not yet seen in game. Other players' rows are not recorded |
| `BN` | statID, name | Scoreboard stat name, once per session |
| `HL` | level, higher | Your honor level changed. higher is `1` for a gain |
| `PB` | honorLevel, warModeDesired, warModeActive, why | PvP baseline: honor level and war mode, `1` or `0` (empty when the client has none). why `s` at login, `w` when the client reported a war mode change. Written only when a value differs from the last `PB` |
| `ZP` | pvpType, subzonePvP, faction | The zone's PvP kind changed. pvpType is the client's (`sanctuary`, `friendly`, `contested`, `hostile`, `arena`, `combat`) or empty; subzonePvP `1` when the subzone has its own rule; faction is the controlling faction's name when the client names one |
| `LM` | method, threshold, master, size, why | The loot rule changed. method is `solo` when you are not in a group, else the client's loot method in lower case (`group`, `needbeforegreed`, `masterlooter`, `freeforall`, `roundrobin`, `personal`). threshold is the item quality the rule applies from (`2` uncommon, `3` rare, ...), empty when the client gives none. master is the master looter's Name-Surname when the method is `masterlooter`, else empty. size is the group size (`1` solo). why: `s` the baseline 5 seconds into the session, `c` a change. Written only when a value differs from the last `LM` line, from `PARTY_LOOT_METHOD_CHANGED`, `GROUP_ROSTER_UPDATE` and `PLAYER_ENTERING_WORLD` |
| `LT` | kind, who, itemID, quantity | Another group member received an item. who is their Name-Surname. kind: `l` looted (by the rule, a roll win or a master looter's pick), `p` the client pushed the item to them. Your own receipts are `O`. Read from the client's loot messages through its format strings; the message text is not stored |
| `LD` | kind, who, itemID, rollType, roll, src | A group roll on an item, for another player. kind: `r` rolled (roll is their number), `s` chose without a number yet, `p` passed, `w` won, `a` everyone passed (who empty). rollType is the client's LootRollType (`0` pass, `1` need, `2` greed, `3` disenchant, `4` transmog), empty when the message does not say. src: `c` the chat roll messages, `h` the client's roll history. One roll can arrive from both sources. Your own rolls are `RL` and `RW` |
| `IQ` | itemID, quality | An item's quality (`0` poor, `1` common, `2` uncommon, `3` rare, `4` epic, `5` legendary), once per session per item, for the items in `LT` and `LD` lines and in your own loot messages. `O` carries no quality; the companion joins it by itemID. It is not a name line |
| `LW` | who, kind, id, slots, items, again, late | A loot window that a group member's Scarlet read and sent to the group (see "What is sent to your group"). who is their Name-Surname as `GM` names them. kind, id, slots and items are as in `LO`, with kind only `c` or `g`; kind and id are read from the creature or object GUID in the message, never taken from the sender's word, and the GUID is not stored. again is `1` when the sender had read that corpse or object before, or when you or another member read it in the last 5 minutes, so one corpse has one line with again `0` across `LO` and `LW`. late is the seconds between their read and the send (a send waits for the end of combat). A member can add at most 20 lines a minute, and a session holds at most 1500. Written only while "Share loot sources with your group" is on |
| `TN` | nodeID, name, state, slot | A flight point seen on a flight master's map, once per session (a name line). state: `0` you are here, `1` reachable, `2` unreachable (not discovered, or no route from here). slot is the client's index on that map |
| `TF` | toNodeID, fromNodeID, copper | You picked a flight. fromNodeID is the flight point you stood at, empty when the client named none; copper is the price, empty when it gave none or the stop was not reachable. The flight itself is the `T 1` and `T 0` lines after it, and a mount you had on ends here |
| `MO` | 1, spellID, mountID, flyable, baseline | You mounted. spellID and mountID come from the client's mount journal and are empty when it named none. flyable is `1` when the area allows flying. baseline `s` for a mount already on when the session started |
| `MO` | 0, spellID, mountID, seconds | You dismounted, with how long you were on it. No line while you are on a taxi, and a mount still on when you log out has no end line: the session end closes it |
| `WP` | 1, uiMapID, x, y, baseline | The map waypoint you set (x and y are map coordinates times 10000). baseline `s` for one already set at login |
| `WP` | 0 | The waypoint was cleared |
| `SM` | `o`, reason, area, seconds, skipsStart | A summon was offered. reason is the client's summon reason, area the name of the place, seconds how long you have to answer, skipsStart `1` when it skips the start experience. The summoner is not recorded |
| `SM` | `a` or `x` | You accepted the summon (`a`), or you declined it, the summoner cancelled it or it ran out (`x`) |
| `TM` | 1, type, seconds, total, id | A countdown the client started. type: `pvp` the battleground gate timer, `challenge` a challenge start countdown, `countdown` a group pull timer, `plunder` Plunderstorm, `world` a world state timer (id is its timerID, seconds and total empty). The player who started a pull timer is not recorded. Breath and fatigue are `MT` |
| `TM` | 0, type, , , id | The countdown ended or was cancelled |
| `IB` | 1, seconds | The countdown that removes you from an instance started, with the seconds left |
| `IB` | 0 | That countdown stopped |
| `DF` | dungeon, raid, legacyRaid, why | The difficulty ids you have picked for dungeons, raids and older raids (`1` normal, `2` heroic, `14` normal, `15` heroic, `16` mythic). why `s` at login, `c` a change. Written only when a value differs from the last `DF` line |
| `VG` | kind, vignetteID, type, npcID, uiMapID, x, y, name | A vignette (a rare, a treasure, an event pin) came into range (kind `s`), or the first time it was seen dead (`d`). type is the client's VignetteType (`0` normal, `1` PvP bounty, `3` treasure). npcID is the creature behind it, empty for an object. x and y are map coordinates times 10000. Each vignette is written once per session, and the client reports a vignette only while it is on your map |
| `AI` | poiID, uiMapID, seconds, current, name | An event point of interest on your map or a map above it that you had not seen this session. seconds is what its timer has left, empty when it has none. current is `1` for the event running now |
| `MP` | types, why | The minimap tracking types switched on, comma-joined: a spellID, or the name when the type has none. why `s` at login, `c` a change. Written only when the set differs from the last `MP` line; empty types mean tracking is off |
| `SE` | `s`, scenarioID, stage, numStages, name, area | A scenario started or reached a new stage |
| `SE` | `l`, scenarioID | You left the scenario |
| `SE` | `c`, scenarioID, xp, copper | The scenario was completed |
| `SE` | `p`, scenarioID, criteriaID, quantity, total, done, text | A scenario criterion changed. text only on the first line for that criterion in a session |
| `TG` | why, group, groups, specID, spec, treeID, tabs, classPoints, specPoints, configID, loadout | The active talent group, spec and points per talent tab. Forever's talent frame (Camelot files) keeps one class tree per spec group, a trait config like the Legacy trees, with the talent tabs as node groups; it has no PvP talents, hero talents or loadout list. group is `1` or `2`, groups how many exist (`2` once dual spec is unlocked). specID and spec (its name) are empty where the client shows no spec. tabs is `groupID:spent:available` per talent tab, comma-joined (`TY` names the ids), from the client's group currency. classPoints and specPoints are the unspent counts from `HasUnspentTalentPoints`. why: `s` the first read of the session, `w` the active group changed, `r` the client reset or changed it, `c` anything else. Written when a value differs from the last `TG` of the session, a few seconds after the client reports a change. loadout is the client's loadout export string for the group's config (`C_Traits.GenerateImportString`, the format the talent window's import and export use), read with no unapplied picks only; it is part of what counts as a change, so swapping a choice node writes a new `TG` even when the points are the same. Seen in game: it is written, for example `CIdBa0K/6fjlwoPQnhZ43PxtUAAAzMjZMzMGmHAAAeA` (a warlock), and a respec step changes its last characters. Empty where the client gives none; lines before this end at configID |
| `TA` | group, nodeID, entryID, rank, oldRank, maxRanks, spellID, tab, why | A talent node's committed rank (`activeRank`) in that group's config. why `s` is a baseline of every node that has a rank, the first time the group is read in the session (oldRank empty); `c` a rank change, or a choice node swapping its entry. A tree with unapplied picks is not read until they are applied. tab is the first of the node's groups that the tree shows as a tab (a `TY` id), the rule the talent frame uses; empty when none is shown. Older versions wrote the node's first group, which is often not a `TY` id. spellID is named by `SN` |
| `TY` | groupID, name | A talent tab's name, once per session. Shown before the first `TG` or `TA` line that uses it |
| `TV` | treeID, classID, nodeCount, hash | The layout of a class talent tree, once per tree per session, after the first talent scan that read every node and before its `TD` lines. nodeCount is the `TD` lines that follow. hash is the 32-bit checksum, in hex, of their fields joined with `|`, so equal layouts have equal hashes. Not written in combat |
| `TD` | treeID, nodeID, posX, posY, type, maxRanks, tab, entries, edges | One visible node of the tree (`isVisible`), read with `GetNodeInfo` as the talent frame reads it. posX and posY are the client's raw values; the frame draws them divided by 10, with y downward. type is the client's node type, tab the node's tab as in `TA`. entries is `entryID:spellID:maxRanks`, comma-joined (a choice node has more than one); edges is `targetNode:type` from `visibleEdges`, comma-joined. spellIDs are named by `SN` |
| `TQ` | kind, a, b | `p` a respec was offered (a the cost in copper, b the client's respec type), `r` the client reset talents (a `1` for a pet's), `i` the client changed the spec (a `1` for a pet's). The ranks that change are `TA` lines |
| `TI` | titleID, title, why | The title shown with your name. title is the client's text with the name as `%s`, empty when none is chosen. why `s` the first read of the session, `c` a change. Learning a title is `NC`; this is choosing one |
| `EQ` | kind, setID, name, items, spec, ignored, result | Equipment sets (the paper doll's manager). kind `b` a set found at login, `c` a set created or changed (name, icon, item count, assigned spec or ignored slots), `x` a set deleted (id and name only), `w` a swap to a set finished (result `1` or `0`; name is empty for a set not seen this session). items counts the set's items, spec is the spec index it is assigned to (empty when none), ignored the number of slots it ignores |
| `PD` | name, level, xp, xpMax, happiness, loyalty, points, used, why | The pet's own numbers (hunter and warlock pets), written when its level, loyalty, happiness or training points change, or when a pet is summoned or found at login (why `s`, else `c`). xp is as of that line: experience alone never writes one. happiness is the client's number (`1` mad, `2` neutral, `3` happy), loyalty its text; both are empty where the client has none. points and used are training points. `PT` is the summon and dismiss |
| `XD` | off, why | Experience gain turned off (`1`) or on (`0`) for the character. why `s` the first read of the session, `c` a change. `GR` has the Forever experience preset |
| `BA` | kind, success, copper, choices | A barber shop change. kind `a` the new appearance was applied, `r` the client's result for the purchase (success `1` or `0`). copper is the price the shop last quoted. choices (on `a`) are the options on the chair, `optionID:choiceID` comma-joined, 60 at most, read while the shop is open. The window opening is `NW` type 62. Not yet seen in game |
| `GA` | mode, why | The client's active game mode number. why `s` the first read of the session, `c` a change |
| `RU` | record, warOn, warOff, warArea, desired, active, faction, flagged, server, realm, rules, why | Every client signal that might name the character's ruleset (Normal, PvP, RP, RP-PvP, Hardcore), read together once per session and again when the client reports a rules change and a value moved. The client has no call that names the ruleset, so this line only records. record is `C_GameRules.GetCurrentGameModeRecordID()`, the id the realm picker switches by (`GA` is the mode enum, which does not tell rulesets apart). warOn and warOff are whether the client allows turning war mode on and off, warArea whether this area allows a toggle (`1` or `0`, empty when the client has no answer). desired and active are the war mode state, faction `Horde` or `Alliance`, flagged the PvP flag. server is the realm id inside the player's GUID (`Player-<server>-<id>`), the one server number the client reports on Forever (the realm id of `S` and `GetRealmID` is 0 there); realm is `GetRealmID`. rules are the names of the client's game rules that are active, comma-joined, 60 at most. why `s` the first read of the session, `c` a change |
| `CD` | sex, classID, raceID, effectiveLevel, why | Character identity the `S` line leaves out. sex is the client's (`2` male, `3` female), classID and raceID its ids, effectiveLevel the level the client treats you as. why `s` the first read of the session, `c` after a level up when a value moved |
| `SX` | why, key, value | More character numbers, the same shape as `SC` but with its own baseline: the stats Forever's character panel shows that `SC` does not. Keys: `defense` (skill with its modifier), `armorpen`, `spen` (spell penetration), `dmin` and `dmax` (main hand damage), `omin` and `omax` (off hand), `rmin` and `rmax` (ranged), `ilvlall` (average item level with bags), `ilvlpvp`, `ilvlmin` (the lowest equipped item). why: `s` session baseline, `g` gear, `l` level, `t` talents, `o` other. Read 2 seconds after the client reports a change, out of combat only |
| `SB` | kind, bank, line, spells | The spellbook. kind `b` a baseline of everything the book lists (the first read for a character, then once a day), `a` spells added, `x` spells removed since this character's last read, which can include spells learned while the addon was off. bank `p` your book, `t` the current pet's. line is the skill line's name (General, the class, a specialization) or, for the pet, its name. spells is `spellID:rank` comma-joined, the rank read from the spell's subtext (`Rank 3`) and left off when it has none. Forever lists every rank, so a rank up is the new rank's spell added. Only spells count: not future spells, flyouts or pet commands. A pet's book gets a baseline when it is a different pet than the last one read, and no removals when the pet is dismissed. Read 3 seconds after `SPELLS_CHANGED`, a learned spell or a pet change, out of combat. `LS` is the learned-spell event; this is what the book then holds |
| `AB` | slot, kind, id, oldKind, oldId, low, why | An action bar slot (1 to 72: the main bar, its pages and the side bars; the stance and form bars swap with the aura and are not read) changed. kind and id are the client's action type (`spell`, `item`, `macro` with the macro's index, `companion`, `equipmentset`, ...) and what it holds; both are empty when the slot was emptied. oldKind and oldId are what it held before, empty for an empty slot. low is `1` when the spell on the bar is not its highest rank, `0` when it is, empty for anything but a spell. why `s` the first read for the character (every filled slot), `c` a change, `p` the client put a newly learned spell there. Read 4 seconds after the last bar change, out of combat |
| `TB` | npcID, trainerType, name, subText, copper, reqLevel | You asked a trainer to teach a service the client listed as available and that you could pay for. name and subText are the trainer list's own text (a spell and its rank, or a recipe), copper its price, reqLevel the level it needs, trainerType the client's (`0` general, `2` tradeskills, `3` pet). The spell or recipe it taught is the `LS` or `LR` line after it. A purchase the client refused writes nothing here |
| `TC` | npcID, trainerType, name, subText, copper, reqLevel, state, skillLine, skillReq, abilityReqs | One service on a trainer's list (the trainer window's own text, as in `TB`). state: `a` available, `u` unavailable (a requirement is missing), `k` already known. skillReq is `skill:rank`, abilityReqs the abilities it needs joined by ` / `. Written when the window opens or refreshes, once per service per trainer per character and again when its state changes; the window's own filters decide which services are listed, and Scarlet never changes them. The character keeps up to 4000 service keys; past that a service is written once a session |
| `SG` | why, slots, pets, nextCost, list | The hunter's stable as the client shows it. slots is how many stable slots are unlocked, pets how many are stabled, nextCost what the next slot costs (copper), list `slot:level:family:name` for each pet including the current one (slot 1). why `s` the first read of the session, `c` a change. Read after the stable window opens or a pet is swapped |
| `AR` | 1, spellID | Auto repeat (Auto Shot, a wand's Shoot) started. spellID is the book spell that was repeating, empty when none could be found |
| `AR` | 0, spellID, seconds | Auto repeat ended, with how long it ran. A logout while it runs writes no ending line |
| `SO` | 1 or 0, spellID | The client lit a spell's action button for a proc (`1`) or put the glow out (`0`). One line per change, not per refresh. Not yet seen in game |
| `EC` | successful, itemID | An enchant spell finished on an item. successful `1` or `0`. itemID is empty when the client did not say which item. The enchant on an equipped item is `EN` |
| `CL` | kind, owned, total, why, old, detail | A collection's total, from the journals the client keeps (the mount journal, the pet journal, the toy box, heirlooms and the wardrobe). kind: `mount`, `pet`, `toy`, `heirloom`, `appearance`, `set` (transmog sets), `illusion`, `outfit` (transmog outfits made) and `customset`. owned is what the character has, total what the client counts in all (empty for pets, which have no list of what exists; for `outfit` and `customset` the most you may make). A mount counts unless the journal hides it for the character. Toys and heirlooms are read only while their tab's filters are the defaults, since the tab counts what its filters show. why `s` the first read of the session, written when it differs from this character's last line of the day (so each character gets one full set a day), `c` a change after that, with old the owned count before it. detail: for `mount`, `dr<skyriding unlocked 1 or 0>:<skyriding mounts owned>`; for `appearance`, `<TransmogCollectionType>:<owned>` per category that has any, comma-joined. Read a few seconds after the client reports a change, out of combat and outside a pet battle. Collections are the account's, so a change that came from another character shows as `s` the next time this one logs in. Which character got an item is the `NC` and `CA` line in that character's chunk |
| `CA` | kind, id, name, sourceType, source, item, extra | One item added to a collection, with what the client says about it. `NC` is the moment; this is what it was. `mount`: id the mountID, sourceType the journal's source type, source its text (`Drop: ...`), extra the spellID. `pet`: id the speciesID, name the species, sourceType the pet type (`1` humanoid ... `10` mechanical), source its text, extra the level. `toy`: id and item the itemID, extra its quality. `heirloom`: id and item the itemID, extra `new` or `upgrade`. `appearance`: id the sourceID, name and item the item behind it, sourceType the client's source number, extra the `TransmogCollectionType`; `cosmetic` is the same for a cosmetic source. `battleslot`: a pet battle slot unlocked, nothing else. `mountequip`: id the mount equipment now applied, extra `1` or `0` for the client's result. Each item is written once per session, and at most 400 a session; `CL` has the total either way. The kinds with no `NC` line (`appearance`, `cosmetic`, `heirloom`, `battleslot`, `mountequip`) are not written in the first seconds of a session, since the client can announce collected items while logging in; the first `CL` covers them |
| `CX` | kind, id | A pet or companion left the collection. kind `pet` (a pet released; id the speciesID when this session had seen the pet, else empty) or `companion` (unlearned). The new total is the next `CL` |
| `SP` | state, speciesID, name, level, customName | The companion pet that is out (the journal's non-combat pet, not a hunter's or warlock's, which is `PT`). state `1` summoned, `0` dismissed (the one that went away), `s` already out when the session started. customName is the name you gave it |
| `TX` | slot, type, option, transmogID, item, outfitID, cost, discount | The transmog window saved a slot. slot is the client's outfit slot (`0` head, `1` right shoulder, `2` left shoulder, `3` back, `4` chest, `5` tabard, `6` shirt, `7` wrist, `8` hands, `9` waist, `10` legs, `11` feet, `12` main hand, `13` off hand, `14` ranged), type `0` appearance or `1` illusion, option the slot option. transmogID is the appearance source (or illusion) the slot now shows, empty or `0` when it was cleared; item the item behind an appearance. outfitID is the outfit being edited. cost (copper) and discount (`1` when the client had a usable discount) are on the first slot of a save and empty on the rest; the cost is the last pending cost the window showed before the save |
| `TO` | kind, outfitID, name, extra | A transmog outfit. kind `a` the outfit now shown (extra `s` the first read of the session, written when it differs from the last one this character wrote, `c` a change), `n` an outfit created, `s` a custom set created (outfitID is the custom set id) |
| `BT` | `s`, wild, npc, yours, theirs, names | A pet battle began. wild `1` for a wild pet, npc `1` for a trainer. yours and theirs are `speciesID:level:quality` per pet, comma-joined; names are the opposing species' names joined with ` / `. Not yet seen in game |
| `BT` | `x`, speciesID, xp | One of your pets gained experience in the battle |
| `BT` | `l`, speciesID, level | One of your pets reached a level |
| `BT` | `e`, seconds, rounds, result, xp | The battle ended. result `w` you won, `l` you lost, empty when the client did not say; xp is all the experience your pets gained in it. A logout in a battle writes no ending line |
| `GU` | kind, guild, rankIndex, officer, leader, who | Guild membership. kind: `s` your state at the start of the session (guild empty when you are in none), `j` you joined a guild (or it changed), `l` you left (guild is the one you left), `k` your rank, officer or leader flag changed, `i` an invite arrived (who is the inviter), `x` it was withdrawn before you answered, `a` you accepted it, `d` you declined it. rankIndex is the client's number (0 is the guild leader); the rank's name is free text and is not kept. officer and leader are `1` or `0`. Written from the guild events, a few seconds after they settle. Notes, the message of the day and the guild information text are never read |
| `GH` | members, online, onlineOrMobile, why | The guild's head count, written when the roster changes: at once when the member count moved, otherwise at most every five minutes. why is empty. Not written until the client has the roster |
| `FR` | kind, name, level, class, why | The friends list and the ignore list, compared with what this character last wrote. kind: `a` friend added, `r` friend removed, `n` a friend came online, `f` a friend went offline, `i` a player ignored, `u` an ignore removed. level and class (the client's class name) are empty for ignore lines and for removals. why `b` marks the first full list this character ever wrote; later logins write only changes. Friend notes are never read. The first scan of a session writes no removals and no online or offline changes |
| `FC` | friends, friendsOnline, ignored, bnFriends, bnOnline, bnInvites, bnBlocked | List sizes, written on the first scan of a session and then when one changes, at most every five minutes. The Battle.net numbers are counts only: no Battle.net friend, tag or account is named anywhere |
| `GI` | kind, who, roles | Party invites and the group actions you took. kind: `r` an invite reached you (who is the inviter, roles the roles they offered as `t`, `h` and `d`), `x` it was cancelled before you answered, `a` you accepted, `d` you declined, `s` you invited someone, `q` you asked to join someone's group, `k` you removed a member, `p` you gave the lead, `m` you made someone an assistant, `u` you removed an assistant, `c` you converted the group to a raid, `y` back to a party, `l` you left the group, `e` you switched "everyone is an assistant" (who is `1` or `0`). who is the name as the client gave it, which can lack the surname; for a unit such as `target` it is that unit's name. Actions are the ones you take with the client's own buttons, menus and slash commands |
| `GL` | `m`, name, role, leader, assistant, subgroup, guildMate, friend, level, class, online, race, faction, guild | A group member's state, written when the member appears or any of it changes (a role set, a promotion, a level, going offline). name is Name-Surname as `GM` writes it, and your own name for yourself. role `t`, `h`, `d` or empty; leader, assistant, guildMate, friend and online are `1` or `0`; subgroup is the raid group (empty in a party); class is the class file. guildMate and friend come from the client's guild and friend lists. race is the race file, faction `Horde` or `Alliance`, guild the member's guild name; each is empty when the client gives none, and older lines stop after online |
| `GL` | `l`, name, isYou | The group leader changed (or was first seen) |
| `GL` | `s`, raid, crossFaction, full, guildGroup | The kind of group, written when it changes: raid `1` or party `0`; crossFaction and full are `1` or `0`; guildGroup `1` when the client counts it as a guild group |
| `GL` | `j`, category / `x`, category | A group formed around you or you left it. category is the client's group category (1 home party, 2 instance group) |
| `GL` | `p`, name | A role poll started; name is who started it |
| `GL` | `c`, name, by, old, new | A member's role was changed by `by`. old and new are `t`, `h`, `d` or empty |
| `RC` | `s`, initiator, seconds | A ready check started. initiator is your name when you called it; seconds is the time the client gave to answer |
| `RC` | `r`, name, ready, seconds | A member answered, seconds after the start. ready `1` or `0`. Your own answer is written under your own name |
| `RC` | `e`, preempted, seconds, ready, notReady | It ended (preempted `1` when another check replaced it). ready and notReady count the answers seen; members who never answered are in neither |
| `LF` | `b`, groupFinder, dungeonFinder, premade, enabled, why | What the client lets you use, at the start of the session (why `s`) and when the dungeon finder is switched (why `e`). Forever's group finder is the premade list of Blizzard_GroupFinder_VanillaStyle: list a group, browse, whisper a leader. The dungeon finder (queue, proposal, role check) is not in the client; its events are written if a server sends them |
| `LF` | `l` or `u`, activityIDs, activity, autoAccept, private, minItemLevel, seconds, newPlayers | You listed a group (`l`) or changed the listing (`u`). activityIDs are comma-joined (up to 8) and activity names the first. seconds is how long the listing runs. The listing's title, comment and voice chat text are never read |
| `LF` | `r`, why | The listing ended: `x` removed (or gone), `t` it timed out, `f` the group filled |
| `LF` | `s`, category, activities, results, shown | A search finished: the category searched, how many activities were asked for, how many listings matched and how many passed the filters. Listings and their leaders are not read |
| `LF` | `f`, category, activities, reason | A search failed |
| `LF` | `o`, tank, healer, dps | The roles you picked for the finder changed (`1` or `0`) |
| `LF` | `w`, shown, total | A /who search came back with that many names shown and in total. The names are not read |
| `LF` | `d`, what, dungeonID | A dungeon finder step: `p` proposal appeared, `y` accepted by everyone, `n` failed, `r` role check, `c` ready check, `w` completion reward, `o` offered to continue (dungeonID set). Not yet seen in game |
| `IV` | name, level, class, race, faction, guild | You opened another player's inspect window. class and race are the client's file names, faction is Horde or Alliance, guild is the guild's name, empty for none. Gear scans by other addons are not recorded |
| `PM` | name, classFile, raceFile, faction, level, guild | Another player you saw on your target, mouseover, a nameplate or in your group. name is Name-Surname; faction `Horde` or `Alliance`; guild is the guild's name (empty for none). Once per player per day per character (the character keeps the day's names, at most 1500, and starts over each day) and at most 3000 lines a session. Guids, chat and notes are not read |
| `AL` | name, level, classID, raceID, type, time, place, itemID, difficultyID, difficultyLevel, pinExpires | A person in the client's recent allies list, with their latest interaction: type is the client's RolodexType, time its epoch seconds, place the location name, the rest context for that interaction. Read only (`C_RecentAllies.GetRecentAllies`; the request function is never called) when the data is ready and a few seconds after the list changes. pinExpires is the epoch seconds when the client stops pinning the ally to the top of the list, empty when not pinned. Written once per ally and again when a newer interaction appears; the character keeps up to 300 allies. The interaction's description, the note and the guid are not read |
| `CT` | type, channel, sentMessages, sentWords, receivedMessages, receivedWords, seconds | Chat activity as counts only, never the text. type: `say`, `yell`, `party`, `raid`, `raidwarning`, `guild`, `officer`, `whisper`, `bnwhisper`, `channel`, `instance`, `emote` (custom /me text), `textemote` (the standard emote messages; words are 0), `community`, `afk` and `dnd` (auto replies you received). channel is the base name of a built-in channel (General, Trade, ...) and `custom` for any other, empty for other types. One line per type with activity, written when a message arrives at least five minutes after the last write and when the world is left; seconds is the time the counts cover. A message you sent counts as sent, every other as received. `WD` and `EM` are separate and unchanged |
| `DQ` | kind, who | Duel details beyond `DU` and `DW`. kind: `d` a duel to the death was requested (who is the challenger), `f` the duel finished, `o` you left the duel boundary, `i` you came back inside it |
| `CE` | kind, a, b | The calendar. kind: `p` calendar invites waiting for you (a), `a` an event alarm went off (a hour, b minute; the title is not kept), `o` you opened an event (a is the client's calendar type), `n` you started a new event (a `1` for a copy), `i` the open event's invite list is complete (a is its size), `g` the number of guild events (a). Titles, descriptions and invitee names are never read |
| `CM` | kind, clubType, name, a, b | Communities and the community finder. clubType is the client's number: 0 Battle.net community, 1 character community, 2 guild, 3 other. name is kept for types 1 and 2 only; Battle.net communities are left unnamed, as are all member names inside them. Descriptions and messages are never read. kind: `s` one you belong to at the start of the session (a members, b your role), `a` you joined one (a members), `x` you left it, `k` you were removed (a is the client's reason: 1 banned, 2 removed, 3 community deleted), `i` an invitation arrived (a is the inviter's name, types 1 and 2 only; b is `s` for one still waiting at the start of the session), `d` an invitation went away, accepted or not, `r` your role changed (a is 1 owner, 2 leader, 3 moderator, 4 member), `j` a member joined (a is their name, types 1 and 2 only), `q` a member left, `f` you applied through the community finder, `c` you cancelled an application, `u` your applications changed (a is how many are listed), `v` a recruiter invited you (a is how many), `o` you joined one while offline. Member joins and leaves are limited to 30 a minute |
| `CV` | 1, kind, id, cancellable | A cinematic or movie started. kind `c` an in-engine cinematic (cancellable `0` for a vehicle or scene camera; id is empty), `m` a movie (id is the client's movie id). The `cinematic` context tag is on until its end. Not yet seen in game |
| `CV` | 0, kind, id, seconds, how | It ended. how `w` it ran to its end, `c` you skipped it (seen by hooks on the cancel paths and the movie's skip button; a skip they miss reads `w`), `e` the client could not play it. The skip dialog's summary and the subtitles are never read |
| `LL` | seconds | A loading screen, from its start to its end. The one at login starts before the addon loads and has no line |
| `LK` | state | Logging out. `c` the logout countdown started, `q` the client is quitting, `x` the logout was cancelled. A reload has none of them |
| `UE` | kind, errorName, errorType, count | The client showed a UI error. kind `m` the red error line, `p` an error popup. errorName is the client's own name for it (`ERR_OUT_OF_RANGE`), empty when it has none; errorType is its number. The message text is never read. One line per error per 10 seconds, count is how many there were since its last line, and a session writes at most 400 |
| `AO` | kind, name, version, old | The addons loaded this session against what this character last wrote: `s` the first list for a character (a baseline), `a` added, `v` version changed (old is the version before), `x` gone. Blizzard's own addons are left out, and a load-on-demand addon that is not loaded this session is not reported gone. Read 10 seconds after login; 400 lines a session |
| `AO` | `c`, locale | The client language (`enUS`), at the first read and when it changes |
| `AO` | `z`, name | The client said that addon's SavedVariables are too large to save |
| `AX` | type, state | The client restricts what addons can read (this is why some fields elsewhere are `?`). type is the client's AddOnRestrictionType: `1` boss encounter, `2` challenge mode, `3` PvP match, `4` map, `5` chat; combat (`0`) is the `F` line and is not written. state: `1` about to become active, `0` inactive, `2` active. One line per change of state per type, 300 a session |
| `AF` | kind, addon, function, count | An addon's call was blocked (kind `b`) or forbidden (`f`) by the client. Only the addon and function names are kept, never the error text. Written for the first block of an addon and function in a session and again when the count reaches 2, 4, 8, ...; 100 pairs a session |
| `TT` | `t`, hasTicket, tickets, status | Your support ticket changed. The first state of a session is written only when you have a ticket. The wait message, case title and description are never read |
| `TT` | `r`, result, reportType | You sent a report. result is the client's SendReportResult (`0` sent, `1` error, `2` too many reports, `3` to `5` it needs a chat line, voice or a screenshot), reportType its ReportType (`0` chat, `1` in world, `7` group member, `8` friend, `13` PvP ...). Who was reported and the report text are never read |
| `TT` | `i` | You reported the player who invited you. The player is not read |
| `UW` | setID, widgetID, type, shown, summary | A world state widget changed: zone progress, battleground scores, capture bars. Read from the top centre, below-minimap, objective tracker and power bar sets. type is the client's widget type (`StatusBar`, `DoubleStatusBar`, `CaptureBar`, `IconAndText` ...), shown `1` or `0`, summary the widget's text and numbers joined with `\|` (colour codes, textures and links removed; timers and tooltips not read). Widgets tied to a unit are ignored. A widget is written at most once per 10 seconds, only when its summary differs from the last line, and a new world clears what was last written; 150 widgets per world and 600 lines a session |
| `TU` | `t`, index, force | A tutorial hint was triggered (the client's tutorial number), once per hint per session. force `1` when the client showed it regardless of settings |
| `TU` | `l` | You left the tutorial area |
| `PP` | mapID, won | The end-of-match screen appeared for that map. won `1` for a win |
| `RM` | `t`, index, unit | A raid marker you set on a unit, `0` when you cleared it. SetRaidTarget toggles and other addons call it, so the line is written when the client's next marker update shows what the unit carries. unit is the token you used (`target`, `mouseover`, `focus`, `party1` ...), empty for any other. The unit's name is not read. Markers other players set are not recorded |
| `RM` | `w` or `x`, index | You placed (`w`) or removed (`x`) a world marker; written when the client confirms the marker is active or gone, checked 0.5 and 8 seconds after the call (placing waits for a click on the ground), so a marker placed later than that is missed |
| `RA` | kind, branch, done, total, extra | An archaeology dig. kind `s` a survey cast (done and total are the finds completed and needed at the site, extra `1` when the survey found something), `f` a find completed, `d` the dig site finished (branch is the client's research branch id), `a` an artifact solved (extra is its name). Not yet seen in game |
| `SU` | why, kind, id, type | What you are super-tracking. why `s` the first read of the session, `c` a change. kind `q` a quest (id is the questID, a `QN` name), `w` your map waypoint, `c` other tracked content (type is the client's content type, id its id), `n` nothing |
| `TE` | kind, spellID, itemID, fromMap, fromX, fromY, toMap, toX, toY, yards, seconds, how | You were moved without travelling there: a teleport spell, an item (a hearthstone, a trinket, a toy), a portal or a summon. kind: `s` a cast of a spell you know, `i` a cast started by an item you had just used (itemID set, spellID the spell it cast), `m` an accepted summon (no spell), `o` a cast of a spell you do not know, which is what a portal object puts on you. The cause is the cast or the summon acceptance; a cast counts only out of combat, a spell you do not know is skipped when it repeats within 1.5 seconds (the client casts some on its own), and the watch ends 8 seconds after a cast (24 after a summon, longer while a loading screen runs). fromMap, fromX, fromY are where you stood at the cause and toMap, toX, toY where you stood once the move showed, in the `P` units (map coordinates times 10000). how: `m` the map or the instance changed, `d` the same map and instance but more than 100 yards away. yards is the straight distance in the world when both ends are in one instance, empty otherwise. seconds is from the cause to the line. Nothing is written while dead, on a taxi, or when the cast moved you less than that. A hearthstone is spell `8690`, and the bind it returns to is the last `HB`; an accepted summon has an `SM a` line just before it. Not yet seen in game |
| `NP` | kind, id, uiMapID, cellX, cellY, how | A place where a creature or an object was met. kind `n` a creature (id its npcID, named by `N`) or `o` an object (id its objectID, from the guid; objects have no name line). how `s` seen on your target, mouseover or a nameplate (pets, guardians and other player-controlled units are skipped), `t` talked to or used (an interaction window opened with it, the same moment as `NW 1`), `l` looted (the source of a loot window, the same moment as `LO`). uiMapID, cellX and cellY are where YOU stood, not where the creature or object was: cells are 0.015 of the map (`x * 10000 / 150`, rounded down), the same as `NS`. One line per cell per npc or object per map and per character: up to 24 cells for one on one map, 4000 npc or object and map pairs kept for the character (past that a cell is written once a session), and at most 1500 lines a session. A cell already written for the thing is not written again with another `how` |

`I` lines gain where `c` while a profession window is open: reagents used
are negative, items made are positive.

`SC` keys: `str agi sta int spi` (attributes), `armor`, `hp mp` (maximum
health and power), `ap rap` (attack power, ranged), `crit rcrit scrit`
(percent; spell is the best school), `sp heal` (spell power, best school, and
bonus healing), `hit shit exp` (hit and spell hit percent, expertise),
`haste rhaste shaste` (percent), `swing` (main hand seconds), `regen` (mana
per second), `dodge parry block` (percent), `rholy rfire rnature rfrost
rshadow rarcane` (resistances), `ilvl` (equipped average). Stats are read 2
seconds after the client reports a change, and only out of combat, since some
values are hidden in combat.

Readers ignore codes they do not know, so new codes do not break old readers.
Readers also treat fields past the ones they know as absent, so new fields
are only ever appended.

## Context

Every event happens at a time, in a place and in a state. The addon writes
changes of state as their own lines rather than repeating them on every
line; the companion carries them forward and attaches them to each event.

Place: the last `Z` (uiMapID, instanceMapID, instanceType, difficultyID,
zone, subzone) and the last `P` (uiMapID, x, y) before the event. A `P`
follows every `Z`, so the position is on the current map.

State tags, each on or off at any moment:

| Tag | On from | Off at |
| --- | --- | --- |
| `combat` | `F 1` | `F 0` |
| `group` | `GP 1` | `GP 0` |
| `resting` | `RS 1` | `RS 0` |
| `afk` | `AFK 1` | `AFK 0` |
| `dead` | `D` | `U` |
| `ghost` | `R` | `U` (or the next `D`) |
| `camp` | `CP 1` | `CP 0` |
| `profession` | `TS 1` | `TS 0` |
| `crafting` | `CB` | `CR`, `CS`, or 10 s after `CB` with neither |
| `taxi` | `T 1` | `T 0` |
| `instance` | `Z` with instanceType other than `none` | the next `Z` with `none` |
| `bg` | `Z` with instanceType `pvp` (a battleground) | the next `Z` with another instanceType |
| `arena` | `Z` with instanceType `arena` | the next `Z` with another instanceType |
| `boss` | `E 1` | `E 0` |
| `saved` | `IL 1` | `IL 0` |
| `window` | `NW 1` | `NW 0` (any number of windows can be open; on while one is). Vendor, bank, guild bank, mailbox and auction house windows are windows, so `VB`, `AU`, `ML`, `BK` and the `I` lines inside them carry it |
| `trade` | `TR 1` | `TR 0` (the trade window is not an NPC window, so it has its own tag) |
| `cinematic` | `CV 1` | `CV 0` (a cinematic or movie is playing) |
| `running`, `walking`, `mounted`, `swimming`, `flying` | `W` time minus its seconds | `W` time |

A session (`S` to `ES`, or to its last line when the game stopped without
one) ends every tag.

Loot rule: the last `LM` line gives the method, threshold, master looter and
group size, and `GP` keeps the size current (`GP 0` is solo). A session
starts with the rule `unknown` and no size until a `GP` or `LM` line says
otherwise; logs from before `LM` existed stay `unknown` with the size from
`GP`. The split key everywhere is method, threshold and group size.

Links between events: `CB` to the `CR`, `CW` and `I c` lines after it (the
recipe); `CB` to the `RD` line beside it (the recipe's difficulty); `QI` to `QK` (its campaign); `BQ` to `BM 1` (the queue that became the match, by map name and time); `BM 1` to `BM 0`, `BM 3` and `BS`, and `BS` to `BN` (stat names by id); `Q 2` to the `QR` line before it (the reward taken); `QD`, `GS` and `GO` to the `NW` window they happened in; `LO` to
the `O` lines after it (the loot source); `K` and `LO` (kind `c`) to the same npcID, for drop rates, and `LW` (kind `c`) the same way; `LW` to `LT` by who and itemID (the corpse a member's receipt came from); `LT`, `LD` and `LM` (master) to other players by Name-Surname, as `GM` names them; `O`, `LT` and `LD` to `IQ` (quality) and `IN` by itemID; `II` and `IT` to `IN` and `IQ` by itemID; `RW`, `RL` and `LD` to each other by player and itemID (rolls on one item within 60 seconds are one roll); names by id (`K`, `NS` to `N`; `CB`, `C`,
`A`, `TW`, `RD`, `RT` to `SN`; `I`, `O`, `CR`, `G`, `PG` to `IN`; `SR` to `SN`
and `IN`; `CU`, `CW` to `CN`; `SL`, `PS`, `PU`, `PG` to `KN`; `WS` to `WN`;
`AC` to `AN`; `AD` to `AC` and `AN` by achievementID; `LA` to `AN` and `AD` by achievementID; `LN` to `SN` by spellID, and `LB` to `LV` (the same earned level); `AT` to `AN` and to `CK` by achievementID; `ZP` to the `Z` before it; `TF` to `TN` (flight points by nodeID) and to the `T 1` and `T 0` after it (the flight taken); `MO 1` to its `MO 0` (the mount, by spellID, and the time between them); `SM o` to its `SM a` or `SM x`, and to the `Z` line that follows an accepted summon; `TE m` to the `SM a` before it and `TE i` to `HB` (the bind) for a hearthstone; `NP` to `N` by npcID (kind `n`), `NS` and `NI` for the same npc, and `LO` and `NW` for the same source; `TE` to `SN` by spellID, to `IN` by itemID and to the `Z` and `P` lines around it; `TM 1` to its `TM 0` by type and id; `IB 1` to its `IB 0`; `SB`, `AB`, `AR`, `SO` to `SN` by spellID, `AB` and `EC` to `IN`, `SB` to `LS` (a learned spell is in the next `SB a`), `TB` to `N` and to the `LS` or `LR` after it, `TC` to `N` and to the `TB` that buys it (by npcID, name and subText), `AB` to its slot's earlier `AB`; `TG`, `TA` and `TD` to `TY` (talent tabs by id); `TG` and `TA` to each other by group; `TD` to its `TV` by treeID, to `TA` by nodeID and to `SN` by the spellIDs in entries; `TA` to `SN` by spellID; `EQ w` to the `EQ b` or `EQ c` line for the same setID; `PD` to `PT` (the same pet by name); `SX` to `SC` (the same reasons, the same stats.csv); `SE s`, `SE p` and `SE c` to one scenario by scenarioID; `MO`, `MP` to `SN` by spellID; `CA` to the `NC` line just before it (the same kind) and to `IN` by itemID; `CA mount` to `SN` by the spellID in extra; `TX` to `IN` by itemID, and to `TO` and `CL outfit` by outfitID; `SP`, `CX pet` and `CA pet` to each other by speciesID; `CV 1` to its `CV 0`; `UE` to itself by errorType (the client's name for the error is on every line); `AO v` and `AO x` to the earlier `AO s` or `AO a` for the same addon; `UW` to itself by widgetID; `SU q` to `QN` by questID; `BT x`, `BT l` and `BT e` to the `BT s` before them; `RF`, `RG`, `RV`, `RR` to `FN`; `RR` to `IN` and `SN`; `RF` to `RP` (the same gain, by faction name); `Q`, `QI`, `QP`, `QS`, `QA`, `QD`, `QR`, `QW`, `GS` to `QN`; `GO`, `GS` to `GN`; `QR` to `IN`; `QD`, `NW`, `GS`, `GO` to `N`; `VB`, `AU`, `ML`, `TR`, `EN`, `IU`, `RW`, `BR`, `DI` to `IN`; `VB` and `VS` to `N`; `VS` to `IN` by the itemIDs in its list); `VB` and `AU` to the `I` and `M` lines that follow (what you paid, what arrived); `ML` to the `I` and `M` lines after it; `TR 1` to its `TR 0`; `AU p` to `AU s`, `AU e` and `AU x` by auctionID; `AV` to `AU s` by item name, and with why `t` to the `ML` take next to it; `RW o` to `RW w`, `RW l` and `RL` by itemID; `GM`, `DP`, `ML` and `TR` to other players by Name-Surname; `GL m`, `GL l`, `GL c`, `RC r`, `GI` (from the unit tokens and the names the client gives), `IV`, `PM`, `AL`, `FR` and `CM i` and `j` to other players by name, and `GL m` to `GM` for the same member; `GL l` to the `GL m` that has the leader flag; `RC s` to its `RC r` and `RC e`; `LF l` to its `LF u` and `LF r`; `GU j` to `GU l`; every event to
its session (`S`) and character.

## What is sent to your group

Scarlet sends one kind of addon message, and only to the group you are in
(`PARTY`, `RAID` or `INSTANCE_CHAT`, prefix `Scarlet`). Each time it writes an
`LO` line of kind `c` or `g` while you are grouped, it sends:

```
1;L;<guid>;<slots>;<items>;<again>;<late>
```

`1` is the message version; a receiver ignores any other. guid is the
creature's or object's GUID: the receiver reads kind and id from it and uses it
to tell a second read of the same corpse, and never stores it. slots, items and
again are the `LO` fields. late is the whole seconds the message waited.

The client refuses addon messages in combat and while chat messaging is
restricted. A message then waits in a queue of at most 40 (the oldest is
dropped past that) and the queue is sent one message a second once the
restriction ends. A message that waited more than 5 minutes, or is longer than
255 bytes, is not sent.

A received message becomes an `LW` line when its sender is in your group, every
field has the expected shape and the sender is under the rate limit. Anything
else is dropped without a line. A member's `LW` lines are that member's claim:
they are kept in their own code and never merged into `O` or `LO`.

Nothing else is sent: no name, position, chat or any other line. "Share loot
sources with your group" on the Settings page (`ScarletDB.opt.shareLoot`, on by
default) turns sending and receiving off together, and so does pausing the
recording. Scarlet makes no web requests; the game client carries the message
to the group, as it carries its own loot messages.

## What is never recorded

Chat text, whispers, mail subjects and bodies, auction notification text, the text of UI errors, system messages, subtitles and widget tooltips, support ticket and report text, who a report was about,
other players' GUIDs, account names, and battle.net identifiers. Other players
appear only by name in `GM` lines, for the players you group with (owner's call,
2026-11-19), in `ML` lines (the recipient of mail you send, the sender of mail
you take) and in `TR` lines (your trade partner). Loot rolls and receipts name
the group members who made them, in `LT` and `LD` lines (owner's call,
2026-11-20: "track loot rules and droprates/attribution per character in the
group"); loot chat text is read only to fill those fields and is never stored.
The social lines name other players too (owner's call, 2026-11-20: "store it
all it's fine"), by character name only: the inviter in `GI` and `GU`, group
members and ready check answers in `GL` and `RC`, friends and ignored players
in `FR`, a player you inspected in `IV`, the challenger of a to-the-death duel
in `DQ`, and the names in `CM` lines of character communities and guilds.
Never recorded in them: chat text and whispers (chat is counts in `CT`, plus
the few words of `WD`), guild notes, the message of the day and rank names,
calendar titles, community descriptions and messages, group finder titles and
comments, friend notes, and anything from the Battle.net friend list or a
Battle.net community (only counts in `FC` and an unnamed `CM`).
Nobody else is named: not auction bidders, not the roll winners of other
groups. Your own chat is reduced to counts of a few words.

## Imported history

Imported history is a third kind of record beside lifetime and observed numbers (the data rule of
2026-11-21). The companion reads TradeSkillMaster's saved variables (`TradeSkillMaster.lua`: the sales,
purchases, income and expense accounting and each character's gold log) and Auctioneer's BeanCounter
(`BeanCounter.lua`: `completedAuctions` and `completedBidsBuyouts`) from every game account folder, and writes
what Scarlet did not record itself as `YG`, `YS`, `YB` and `YM` lines.

- A record is dropped when Scarlet has the same thing from its own lines or from history read in earlier: an auction
  sale or purchase that matches an `AV` invoice (item, count, amount within a copper a unit, 48 hours), a purchase that
  matches an `AU y` line, a vendor sale or purchase whose counts match `I` and `VB` lines within a minute, money that
  matches an `M` line within 90 seconds, and a gold point within 15 minutes of a balance Scarlet recorded.
- Imported records are never added to earned, spent, kills or any other observed number, and no public board reads
  them. They have their own sharing group, `imports`.
- Per character, `imports/view.json` (the pages' view of the records) and `imports/payloads/import.scl` (the upload
  payload, header `scarletimports	1	<Name-Surname>`, then `<epoch ms>	<code>	<fields...>`) replace themselves on
  every export. `overview.json` and `Digest.lua` carry the view as `imported`: `sources`, `first`, `last`, `sales`,
  `sales_copper`, `buys`, `buys_copper`, `dropped`, `gold` (one point a UTC day), `recent`, `items` and `days`.
- The BeanCounter reader follows the order BeanCounter packs a completed auction in (stack, money, deposit, fee,
  buyout, bid, buyer or seller, time, reason, house); an entry in another layout is counted and left out.

## Companion output

For each character `Name-Surname`, under the output folder:

- `Name-Surname/scarlet.txt`: every exported event, one per line, appended in
  chunk order:

  ```
  2026-11-19 19:02:13.42  kill      Defias Thug (116) by you
  ```

- `Name-Surname/payloads/<firstSeq>-<lastSeq>.scl`: the upload payload for one
  export run. zstd (level 19) of UTF-8 text: one header line
  `scarlet\t1\t<Name-Surname>`, then each event as
  `<epoch ms>\t<code>\t<fields...>`.

`state.json` in the output folder records the last exported `q` per
SavedVariables path.

- `Name-Surname/tables/`: every event in every payload as relational CSV
  (UTF-8, header row, RFC 4180 quoting), rewritten in full on each export:
  - `events.csv`: `ms, session, code, f1 .. f12, map, instance, zone,
    subzone, x, y, tags, loot_rule, loot_threshold, group_size`. tags lists
    the context tags on at that moment, joined by `|`. loot_rule,
    loot_threshold and group_size are the loot rule in force (see Context),
    group_size empty while unknown. f13 and later fields are joined into f12
    by tabs.
  - `sessions.csv`: `session, start_ms, end_ms, ended (1 when ES was seen),
    build, class, race, level_start, level_end, events`.
  - `names.csv`: `kind, id, name`. kind: `n` npc, `s` spell, `i` item,
    `c` currency, `q` quest, `k` skill, `w` statistic, `a` achievement, `o` gossip option, `f` faction, `p` PvP scoreboard stat, `t` flight point, `g` talent tab.
  - `stats.csv`: `ms, session, key, value, reason` from `SC` and `SX`.
  - `statistics.csv`: `ms, session, id, value, number` from `WS`. number is
    the value as an integer (copper for money) when it parses, else empty.
  - `talents.csv`: `ms, session, level, group, node_id, entry_id, spell_id,
    spell, tab_id, tab, rank, old_rank, max_ranks, kind, point_no` from `TA`.
    level is the last `S` or `L` before the line. tab_id is the tab the client
    shows; a line from an addon older than `TV` and `TD` has its tab taken
    from the node's `TD` line when the first group it names is not a `TY` tab.
    kind: `baseline` (the group's ranks as read at the start of a session),
    `pick`, `refund`, `swap` (another entry of a choice node), `unseen` (a
    baseline that differs from the ranks the earlier lines left). point_no is
    the points the group holds after the line, empty on a baseline.
  - `drops.csv`: `npc, npc_name, item, item_name, rule, threshold,
    group_size, kills, looted, drops, quantity, rate`. One row per creature
    and item that dropped at least once, for each loot rule (method,
    threshold, group size) the creature was killed or looted under. kills is
    `K` lines; looted is the first-read `LO` and `LW` lines of kind `c` for
    that creature with an item list (older lines have none and count nowhere;
    a second read of the same corpse, such as skinning, counts nowhere). Only
    corpses you opened, or a group member's Scarlet reported, are seen, so
    rate is drops per corpse looted, under each rule; drops is the corpses
    the item came from; quantity is the total; rate is drops divided by
    looted. A rule with no drop of the item shows drops `0`. Coin and
    currency in a window are not items.
  - `attribution.csv`: `character, rule, threshold, group_size, items,
    quantity, poor, common, uncommon, rare, epic, legendary, unknown,
    rolls_won, rolls_lost, rolls_passed`. One row per player and loot rule.
    items is receipts (`O` for you, `LT` for the others), quantity their
    stack sizes, and the quality columns split items by `IQ` (`legendary`
    includes anything above; `unknown` when no `IQ` line exists for the
    item). Rolls are one per player and item within 60 seconds, from `RL`,
    `RW` and `LD`, and a win or loss closes one, so a second copy of the same
    item is its own roll: won if they won, else lost if they rolled, else passed.
