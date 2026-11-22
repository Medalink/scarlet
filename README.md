# Scarlet

Scarlet is a WoW Forever addon that records what your character does, with a timestamp on every line, and keeps
it on your PC. The one thing it sends is the loot window of a corpse or object you open while grouped, to that
group only, so every member's Scarlet knows what dropped. A switch on the Settings page turns that off.

## What it records

- **Travel:** the path you walk, ride, swim and fly on each map, flight paths, hearthstones, summons and other teleports, zones and
  subzones, the places you discover.
- **Combat:** kills and who got them, deaths with the last three hits and the killing blow, time in combat, crowd
  control taken, damage and healing meters, boss encounters, duels and PvP kills.
- **Progress:** experience by source (kills, quests, exploring) and level, levels and time per level, quests from
  accept to turn-in, reputation, skills, talents, achievements and Legacy points.
- **Items and gold:** loot by corpse and by roll, what party members looted, gear changes, crafting, vendor and
  auction house sales, mail, trades, repairs, and every copper earned and spent.
- **People:** groups and how long you played with each person, the players you meet, guild and friends counts.
- **The world:** creatures you see with their level and type, vendor stock, trainer lists, item facts.

- **Other addons:** a gathering node GatherMate2 adds, fish The Fishing Log and Forever Fishing record, the Polestar
  guide and step you are on, Profession Shopping List's tracked recipes, Attune steps, AutoLayer requests. These go
  in their own table, `ScarletAddonsDB`, apart from the main recording, each behind a toggle on the Addons page
  (on by default). Their codes are in [docs/ADDONS.md](docs/ADDONS.md).

Every line code and its fields are in [docs/FORMAT.md](docs/FORMAT.md). Chat text, mail bodies, notes and
account names are never recorded.

## What it shares with your group

When you loot a creature or an object in a group, Scarlet sends the other members' Scarlet what the loot window
held: which creature or object, the items with their quantities, and coin. Their Scarlet records it as an `LW`
line, and the app's drop rates then count the corpses the whole group opened, not only yours. On recordings from
before this, a grouped character had a loot window for 255 of 531 kills.

Kill and loot lines (`K`, `LO` and `LW`) end with a corpse key: 10 hex digits hashed from the GUID of the creature or
object, the same on every client, so a corpse several members saw is counted once. The GUID itself is never stored. Because the key is the same for everyone,
the site can tell that two uploaded characters saw the same corpse, even with the Social group off.
An `ON` line records the name of an object you loot, read from the game's tooltip. The desktop app uploads `LW` lines
with the rest of the Loot group, with each sender's name replaced by a pseudonym, when you turn uploading on.

It goes through the game's addon channel to your party or raid only, and waits for the end of combat, because the
client refuses addon messages in combat. No name, position, chat or other line is sent. "Share loot sources with
your group" on the Settings page turns sending and receiving off. The message and its limits are in
[docs/FORMAT.md](docs/FORMAT.md), "What is sent to your group".

## The capture map

[docs/api-map.html](docs/api-map.html) lists every API the WoW Forever client documents, grouped by domain, and
whether Scarlet records it. Every documented data point in a game domain (an event, or a function that reads state
or returns a value) is either recorded or listed with the reason it is left out, whether or not the client's own UI
calls it. The globals the client's UI calls that the docs omit are in their own "Undocumented" domain and follow
the same rule. "Live" is a column that marks the APIs the client's UI calls; it does not change what needs a reason.
[tools/COVERAGE.md](tools/COVERAGE.md) explains how the map is built and grown.

## In game

`/scarlet` opens the window: a character overview (this week, your current level so far, who you played with,
where you died), the session's numbers, time splits, people and a live view. A minimap icon shows that it is
recording.

### Loot HUD

While you herb, mine, skin, fish or disenchant, outlined text with no background appears around your character, in
three parts:

- **Left:** zone and subzone, items gathered and nodes opened this session, your lifetime count, what the session's
  items are worth in your bags, time and gold per hour, and your skill in that profession while it is below its cap.
- **Right:** the 7 items gathered most recently, each with its profession's icon, the item's icon, its name and the
  price of one. Older items are summed up in a "+13 more items" line.
- **Below:** the last item gathered, the best one this session (green quality or better), and End Session.

Prices come from Auctionator, then TradeSkillMaster, then the auction prices Scarlet has seen, then the vendor price.
A session survives `/reload` and logging out, and a new one starts after 30 minutes without a gather. The HUD fades
8 seconds after the last gather. Left clicks pass through it to the world; a right-click hides it.

The Loot HUD page in Scarlet's window has a preview and four tabs: General (on or off, hide after 0 to 60 seconds,
where 0 never hides, and Reset session), Text (size, outline, shadow), Layout (straight, or an arc that bends each side
around your character, and Reset layout) and Professions. While the page is open the HUD is on screen with outlines:
drag a part to move it, Shift-drag to scale all three. `/scarlet gather` does the same from chat, `/scarlet gather
reset` puts the layout back, and `/scarlet gather clear` ends the session.

## On the world map

With the OpenMap addon installed (its code is MIT; its map art is Blizzard's), Scarlet adds a "Scarlet" section to
OpenMap's menu (the Show tab) with a switch for each layer, and draws them on OpenMap's stitched map above its art:
the trail walked in the last 20 minutes (older segments fade out; the full path stays in the app),
flights and teleports, deaths, gathering and fishing, NPC windows, quests accepted and turned in,
areas discovered, and camps. Flights and teleports, the trail, deaths, gathering and fishing, areas and camps are on
by default; NPC windows and quests are off. Scarlet uses only OpenMap's public `OpenMapAPI` and needs a version with
API major 1, version 2 or later; OpenMap is an optional dependency and Scarlet works without it.

Without OpenMap, or while it shows the game's own map, the same layers are drawn on the game's world map for the
map being shown (a continent shows the places recorded in its zones). A small "Scarlet" switch in the top left of
the map turns them on, off by default; the arrow next to it lists the layers.

The layers show where this character was recorded, read from the same lines in SavedVariables that the companion
reads: nothing extra is recorded, and nothing is drawn or read until the map is open with a layer on. The history is
decoded a few milliseconds per frame and kept in memory only. The switches are saved as `ScarletDB.opt.map`.
"Draw on the world map" on the Settings page of Scarlet's window turns every layer off and back on without
changing the per-layer switches.

## Install

Copy `addon/Scarlet` into `World of Warcraft\_forever_\Interface\AddOns\`. Recordings are saved with your
SavedVariables at each logout and `/reload`.

Listing text, logos and screenshots for CurseForge and Wago are in [listing/](listing/README.md); `.pkgmeta` packages `addon/Scarlet` as `Scarlet`.

The desktop app that turns recordings into an overview, timeline, maps and charts is
[scarlet-app](https://github.com/Medalink/scarlet-app).

## License

GPL-3.0. See `LICENSE`.
