# Scarlet

Scarlet is a WoW Forever addon that records what your character does, with a timestamp on every line, and keeps
it on your PC. It never sends anything anywhere.

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

## The capture map

[docs/api-map.html](docs/api-map.html) lists every API the WoW Forever client documents, grouped by domain, and
whether Scarlet records it. Each data point the client actually calls is either recorded or listed with the reason
it is not worth recording. [tools/COVERAGE.md](tools/COVERAGE.md) explains how the map is built and grown.

## In game

`/scarlet` opens the window: a character overview (this week, your current level so far, who you played with,
where you died), the session's numbers, time splits, people and a live view. A minimap icon shows that it is
recording.

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
