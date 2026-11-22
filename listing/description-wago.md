Scarlet records what your character does in WoW Forever, with a timestamp on every line, and keeps it on your PC. It writes a line for each thing that happens: a step, a cast, a kill, a death, a coin looted. The in-game window shows your character overview, session and lifetime stats and a live view. The optional Windows desktop app turns the recording into an overview, timeline, maps, charts and loot tables.

## Features

- Records a timestamped line for each thing that happens, from a step to a kill to a coin looted. Every line code is documented in the repository (`docs/FORMAT.md`).
- Travel: the path you walk, ride, swim and fly on each map, flight paths, hearthstones, summons and other teleports, zones and subzones, places you discover.
- Combat: kills and who got them, deaths with the last three hits and the killing blow, time in combat, crowd control taken, damage and healing meters, boss encounters, duels and PvP kills.
- Progress: experience by source (kills, quests, exploring) and level, time per level, quests from accept to turn-in, reputation, skills, talents, achievements and Legacy points.
- Items and gold: loot by corpse and by roll, what party members looted, gear changes, crafting, vendor and auction house sales, mail, trades, repairs, every copper earned and spent.
- People: groups and how long you played with each person, players you meet, guild and friends counts.
- The world: creatures you see with their level and type, vendor stock, trainer lists, item facts.
- Other addons: data that some installed addons already hold (gathering nodes, fishing logs, guide progress, crafting lists) goes into its own table, each behind a toggle on the Addons page.
- In-game window (`/scarlet`): a character overview with time to the next level, this week's play time, who you played with and where you died; session and lifetime stats; time splits; a live view of the lines being written.
- Time to the next level, the next multiple of ten and level 60, worked out from your recent pace.
- Small footprint: events are written as they happen, compressed into chunks, and saved with your normal SavedVariables.
- The recording stays on your PC. In a group, Scarlet tells the other members' Scarlet which corpse or object you looted and what its loot window held, so drop rates count every corpse the group opened. A switch in Settings turns that off.
- Optional Windows desktop app that turns the recording into an overview, timeline, maps, charts and loot tables.

## What Scarlet never records

Scarlet does not store free text. Where a window holds someone's words, it keeps a count, a name or a price instead. This list follows `docs/FORMAT.md` and the website's "What Scarlet never records" table.

Never recorded, with what is kept instead:

- Chat text and whispers: message and word counts per channel.
- Mail subjects and bodies: who sent or received the mail, the money and the items.
- Auction notification text: the item, the count and the price.
- The text of UI errors: the error's name and how often it appeared.
- Support ticket and report text, and who a report was about: that a report was sent, and its type.
- Guild notes, the message of the day and rank names: your rank number, and whether you are an officer or the leader.
- Calendar titles, friend notes and group finder comments: counts of invites waiting, list sizes and listings found.
- Other players' GUIDs, account names and account friend tags: the character names of players you group, trade, mail or roll against.
- What is in your screenshots: only the file name and the time. Scarlet never reads a picture.

Your own chat is kept as counts too. Scarlet counts each `lol` and `rip` you type and stores the number, not the sentence.

What it does keep about other people: the character names of players in your group, players you saw on your target, mouseover or nameplates, and players you traded, mailed or rolled against. These stay in your SavedVariables file on your PC.

Screenshots at key moments are off by default. When you turn them on in Settings, Scarlet calls the game's own screenshot command, at most once every 5 seconds, and records the file name.

Scarlet makes no web requests. While you are in a group it sends one thing through the game's addon channel, to that group only: which creature or object you looted, and the items and coin in its loot window. It sends no names, positions or chat, and "Share loot sources with your group" in Settings turns it off. Your recording leaves your PC only if you copy the file yourself.

## How to use

### In game

1. Install Scarlet and log in. A small scarlet mark next to the minimap shows that it is recording. Drag it to move it.
2. Type `/scarlet` (or `/scar`), click the mark, or use Scarlet in the addon compartment menu to open the window.
3. Pages: Character, This session, Stats, Time, Combat and more, People, Live, Addons, Settings, Fonts.
4. `/scarlet pause` pauses and resumes recording. `/scarlet save` seals the current chunk. `/scarlet status` prints how much is stored.

Recordings reach disk when you log out or `/reload`. The file is `World of Warcraft\_forever_\WTF\Account\<account>\SavedVariables\Scarlet.lua`.

Settings has toggles for movement path recording, combat logging at login, the login message, pausing, the recording mark and screenshots at key moments (off by default). The Addons page has one toggle per integration with another addon, on by default.

### Desktop app (optional)

The Windows desktop app reads the recording and draws an overview, timeline, maps, charts and loot tables. It also writes a small `ScarletData` addon beside Scarlet, which lets the in-game Character page show your history from before the current session. Scarlet works without it.

Download it from https://github.com/Medalink/scarlet-app/releases

### Manual install

Copy the `Scarlet` folder into `World of Warcraft\_forever_\Interface\AddOns\`.

## Links

- Desktop app: https://github.com/Medalink/scarlet-app/releases
- Source and data format: https://github.com/Medalink/scarlet
- Website: https://medalink.github.io/scarlet-web/
