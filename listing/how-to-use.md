## In game

1. Install Scarlet and log in. A small scarlet mark next to the minimap shows that it is recording. Drag it to move it.
2. Type `/scarlet` (or `/scar`), click the mark, or use Scarlet in the addon compartment menu to open the window.
3. Pages: Character, This session, Stats, Time, Combat and more, People, Live, Addons, Settings, Fonts.
4. `/scarlet pause` pauses and resumes recording. `/scarlet save` seals the current chunk. `/scarlet status` prints how much is stored.

Recordings reach disk when you log out or `/reload`. The file is `World of Warcraft\_forever_\WTF\Account\<account>\SavedVariables\Scarlet.lua`.

Settings has toggles for movement path recording, combat logging at login, the login message, pausing, the recording mark and screenshots at key moments (off by default). The Addons page has one toggle per integration with another addon, on by default.

## Desktop app (optional)

The Windows desktop app reads the recording and draws an overview, timeline, maps, charts and loot tables. It also writes `Digest.lua` into the addon folder, which lets the in-game Character page show your history from before the current session. Scarlet works without it.

Download it from https://github.com/Medalink/scarlet-app/releases

## Manual install

Copy the `Scarlet` folder into `World of Warcraft\_forever_\Interface\AddOns\`.
