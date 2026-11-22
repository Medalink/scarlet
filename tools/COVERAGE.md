# Growing what Scarlet records

`docs/api-map.html` lists every API the Forever client documents, and the globals its interface code calls that the
docs leave out. Every data point in a game domain is either recorded by the addon or left out with a written reason
in `tools/coverage.json` under `skip`. A reason names the Scarlet line code that already covers the fact, or the
client gate that excludes it. Nothing is left undecided.

A data point is an event, a function whose name reads state (Get, Is, Has, Unit, Request and the like), or a function
whose documentation gives it Returns. Actions that return nothing are listed and not counted. "Interface and other"
(window plumbing, glue screens, tutorials) is listed and not counted.

- **Recorded**: the addon registers the event or calls the function. A name in the `CONTENT_PROBES` table of
  `addon/Scarlet/Baseline.lua` only checks that the API exists, so it does not count as recorded.
- **Live** is a column: a Lua file the Forever client loads calls the API. It says the API works in Forever. It does
  not decide what needs a reason.
- **Undocumented** is a domain of its own: bare global calls in the files the Forever client loads, whose name reads
  state, that the docs do not list and the UI's own Lua does not define. It counts like a game domain.

Rebuild the map after any change to the addon or to `coverage.json`:

```
python tools/apimap.py --docs "<_forever_>/BlizzardInterfaceCode/Interface/AddOns/Blizzard_APIDocumentationGenerated" --ui <Interface/AddOns export> --strict
```

The `--ui` folder is the Forever client's own interface code (`Interface/AddOns`), exported from your client.
`--strict` exits 1 and lists every data point in a game domain or in Undocumented that is neither recorded nor
skipped. Without it the count is printed. Either way the tool also prints skip entries whose name is now recorded
(delete them) and entries that match no row.

## One wave

A wave covers one domain from the map: the data points that are not recorded and have no reason.

1. Decide each row:
   - **record**: it tells what the player did or what happened to them, ideally with a when (an event, or a value
     read when an event fires).
   - **skip**: UI state, cosmetic, account store, a duplicate of something already recorded, a system the client
     does not load in Forever, or a value that changes every moment. Write the reason: the line code that covers it
     (`docs/FORMAT.md` has every code) or the gate that excludes it. A gate is read from the addon's `.toc`
     (`AllowLoadGameType`, `ExcludeLoadGameType`); Forever's game type is `camelot`, in the `mainline` family.
2. Capture each record row by an event, or by reading on an event that already fires. Never poll on a timer. Read
   only out of combat when the value can be secret. Write a line only when the value changed. Put names in a
   once-per-session name line, like `SN` and `KN`.
3. Add each new code to `docs/FORMAT.md`, to `word()` and `details()` in `companion/src/events.rs`, and to its
   Context tag or link when it has one.
4. Check: LuaLS at Hint level on `addon/`, every event name present in the Forever docs, and a hand-made
   SavedVariables file run through `scarlet export`.
5. Add the skips to `coverage.json`, delete the entries the tool lists as now recorded, rebuild the map with
   `--strict`, and commit with the totals before and after in the message.

Order, highest research value first: Combat, Professions, Quests and NPCs, Economy and items, Progress, PvP,
World and travel, Character, Spells, Collections, Social.
