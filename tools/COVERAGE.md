# Growing what Scarlet records

`docs/api-map.html` lists every API the Forever client documents. Coverage is
measured against live data points: events and read functions that a file
the Forever client loads calls. APIs judged not worth recording go in
`tools/coverage.json` under `skip`, with a reason, and drop out of the target.

Rebuild the map after any change to the addon or to `coverage.json`:

```
python tools/apimap.py --docs "<_forever_>/BlizzardInterfaceCode/Interface/AddOns/Blizzard_APIDocumentationGenerated" --ui <Interface/AddOns export>
```

The `--ui` folder is the Forever client's own interface code (`Interface/AddOns`),
exported from your client.

## One wave

A wave covers one domain from the map: the rows that are live, data
points, not tracked and not skipped.

1. Decide each row:
   - **track**: it tells what the player did or what happened to them,
     ideally with a when (an event, or a value read when an event fires).
   - **skip**: UI state, cosmetic, account store, a duplicate of something
     already recorded, or retail-only behaviour. Write the reason.
2. Capture each track row by an event, or by reading on an event that
   already fires. Never poll on a timer. Read only out of combat when the
   value can be secret. Write a line only when the value changed. Put
   names in a once-per-session name line, like `SN` and `KN`.
3. Add each new code to `docs/FORMAT.md`, to `word()` and `details()` in
   `companion/src/events.rs`, and to its Context tag or link when it has one.
4. Check: LuaLS at Hint level on `addon/`, every event name present in the
   Forever docs, and a hand-made SavedVariables file run through
   `scarlet export`.
5. Add the skips to `coverage.json`, rebuild the map, and commit with the
   coverage before and after in the message.

Order, highest research value first: Combat, Professions, Quests and NPCs,
Economy and items, Progress, PvP, World and travel, Character, Spells,
Collections, Social.
