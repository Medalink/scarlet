# Scarlet

Scarlet is a WoW Forever addon that records what your character does, with a timestamp on every line, and keeps
it on your PC. It never sends anything anywhere.

## What it records

- **Travel:** the path you walk, ride, swim and fly on each map, flight paths, hearthstones and summons, zones and
  subzones, the places you discover.
- **Combat:** kills and who got them, deaths with the last three hits and the killing blow, time in combat, crowd
  control taken, damage and healing meters, boss encounters, duels and PvP kills.
- **Progress:** experience by source (kills, quests, exploring) and level, levels and time per level, quests from
  accept to turn-in, reputation, skills, talents, achievements and Legacy points.
- **Items and gold:** loot by corpse and by roll, what party members looted, gear changes, crafting, vendor and
  auction house sales, mail, trades, repairs, and every copper earned and spent.
- **People:** groups and how long you played with each person, the players you meet, guild and friends counts.
- **The world:** creatures you see with their level and type, vendor stock, trainer lists, item facts.

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

## Install

Copy `addon/Scarlet` into `World of Warcraft\_forever_\Interface\AddOns\`. Recordings are saved with your
SavedVariables at each logout and `/reload`.

The desktop app that turns recordings into an overview, timeline, maps and charts is
[scarlet-app](https://github.com/Medalink/scarlet-app).
