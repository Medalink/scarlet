# Scarlet

## 1.0.2

- New Loot HUD: while you herb, mine, skin, fish or disenchant, outlined text around your character shows the zone, this session's items and nodes, your lifetime count, what the items are worth, gold per hour, your skill, the 7 latest items and the best one this session. It fades 8 seconds after the last gather. The Loot HUD page in Scarlet's window sets its size, layout, outline and professions; drag a part to move it.
- Item values come from Auctionator, then TradeSkillMaster, then the auction prices Scarlet has seen you look up, then the vendor price.
- The world map shows only your walking trail of the last 20 minutes. Flight and teleport lines, deaths, gathering and fishing, NPC windows, quests, discovered areas and camps are no longer drawn in game; the desktop app still shows them. With OpenMap, its Scarlet menu has the one "Trail walked" switch, and the game map's Scarlet switch no longer has a list of layers.
- "Total time played" no longer prints two to four times at login. Other addons' /played requests stay out of chat for the first 15 seconds; typing /played still prints.
- A camp visit now lasts as long as you are at the camp. The Camp Benefits, Warmth and Cozy Fire buffs, which you keep for an hour after leaving, no longer start or extend a visit, so Camps and Time at camp count only the time near a campfire or tent.
- Opening the world map no longer counts as a /read emote, so it stops topping your favourite emotes.
- The addon window shows characters as first name and surname.
- A death now keeps every hit of the death recap (up to 20, was 3), says when a fall or drowning killed you, and a death the game reports twice counts once.
- A character first recorded partway through its life now gets its completed quests, titles, explored map areas and instance and world boss locks, so lifetime numbers can cover the time before Scarlet.
- Item search can find items in the warband bank, guild bank tabs you opened, your mailbox and your auctions.
- Records auction prices you look up, which boss each item came from, the name of an object you loot, recipe reagents, hardcore death notices, /who results, full battleground scoreboards and the gear of players you inspect.
- Kill and loot lines carry a corpse key, a hash that is the same on every client, so a corpse several players saw counts once. The creature's GUID itself is never stored.

## 1.0.1

- In a group, Scarlet now tells the other members' Scarlet which corpse or object you looted and what its loot window held, and records what theirs tell you. Drop rates then count the corpses your group opened, not only yours. It goes to your group only, after combat, and carries no names, position or chat. "Share loot sources with your group" on the Settings page turns it off.
- The Characters page lists every character from all your game accounts in one table, the one you are logged into first, with a Game account column when you have more than one account. "Group characters by game account" in the desktop app brings the split by account back.
- A time-to-level target now needs five complete recorded levels, so a new character no longer shows a date years away.

## 1.0.0

First release on CurseForge and Wago.

- New Characters page: every character you have, with totals, this week per character, time and date to the level cap for each character that is levelling, and how long pairs of your characters were online together. It also lists the characters on your other game accounts when the desktop app is running.
- Item search on the Characters page: type two letters of an item name, or an item id, to see which of your characters hold it in their bags and bank. Bags and bank contents are recorded per character and stay on your PC.
- At the level cap, or with experience off, Scarlet stops its levelling work, and the Character page leads with gold, dungeons and raids, deaths, reputation, Legacy and PvP, with XP and level history in a Levelling card.
- Time played now reads /played at login, at each level up and at logout. Recorded time is shown apart from lifetime time, so a character first seen at level 42 or 60 no longer shows a level duration or "time at max level" that Scarlet did not watch. Reload time counts as played.
- The Stats page includes history from before you installed Scarlet when the desktop app supplies it, and says "since install" on the cards it cannot fill.
- History imported from other auction addons shows on the Characters page as summaries, sales and purchases by day, item prices and gold balance by day, each labelled with where the numbers came from.
- Gold you send to your own characters, including those on your other game account, is counted as a transfer, not as spent and earned.
- Your own other character no longer counts as someone you played with when your two characters group together.
- Repairs at a vendor are recorded again, whichever order the game reports the cost and the money.
- Records the rested XP a levelling character logs out with, where every talent sits in the tree, and the signals the game gives about a character's ruleset.
- The Addons page counts every line written by each addon, not only the lines since your last login.
- The map's 20-minute walking trail survives /reload and fades out; fonts the client cannot draw are left out of the Fonts page.
- The window opens faster: each page is built the first time you click it. The map builds its index faster, and Scarlet no longer receives health updates while no mob is engaged.
- New /scarlet perf times every handler in game and copies the report.
- No more "Error loading Scarlet/Items.lua" warning at launch. The desktop app writes its export into its own ScarletData addon folder, and Scarlet works without it.

## 0.4.0

First tagged version.

- Records travel, combat, progress, items and gold, people and the world, with a timestamp on every line.
- `/scarlet` window restyled: Character, This session, Stats, Time, Combat and more, People, Live, Addons, Settings and Fonts pages, in the bundled Sofia Sans.
- Character page shows time to the next level, the next multiple of ten and level 60, from your recent pace.
- Records teleports by spell, item, portal and summon, killing blows with the number of hits in the death recap, auction invoices, map cells where creatures and objects are met, and the talent loadout string.
- Optional screenshots at key moments (level up, death, boss kill, epic item, new collectible, duel won, PvP kill). Off by default.
- Data from some other installed addons goes into its own table, with one toggle per addon on the Addons page.
- New icon in the AddOn list.
