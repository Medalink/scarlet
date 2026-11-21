# Scarlet addon stream, version 1

Scarlet also records what some other installed addons know about what you did. Those lines are kept apart from the
main recording so what users share from the main recording never mixes with them. [FORMAT.md](FORMAT.md) is the main
format and does not change; this file is the addon stream.

## SavedVariables

`ScarletAddonsDB`, listed in Scarlet.toc next to `ScarletDB`, in the same `Scarlet.lua` file. The companion reads each
table by name, so the order WoW writes them in does not matter.

```lua
ScarletAddonsDB = {
  ["v"] = 1,                    -- format version
  ["seq"] = 7,                  -- last chunk number issued; independent of ScarletDB's
  ["chunks"] = { ... },         -- oldest first; same fields and encodings as FORMAT.md (q, c, s, t, n, e, z, r)
  ["buf"] = { "...", ... },     -- lines not yet sealed; bufT, bufC and bufS are its time base, character and session
  ["gaps"] = { ... },           -- chunk numbers dropped for space
  ["totals"] = { gm = 12, ... } -- lines written per integration, kept across sessions; counted from the stored chunks once, when a store has none
  ["opt"] = { gm = false, ... } -- one flag per integration; a missing flag is on
}
```

Chunks are compressed as in FORMAT.md (`d64` or `txt`). The addon keeps up to 2 MB of payload and drops the oldest
chunks past that. A buffer left by a reload or crash is sealed with `r = 1` the next time the addon loads.

## Lines

```
<dt>\t<key>\t<code>\t<field>\t<field>...
```

`dt` counts centiseconds from the previous addon line, from the chunk's `t` for the first, as in FORMAT.md. `key` names
the integration. The same rules apply to fields: no tabs or newlines, a secret value is `?`, a missing value is empty.
Map coordinates are the map position times 10000. No chat text, mail, notes, error text or player names are read.

The companion writes these lines under `out/<Name-Surname>/addons/` (`addons.txt` and `payloads/*.scl`, whose lines are
`<epoch ms>\t<key>\t<code>\t<fields>`), never into the main payloads or tables.

## Flags

Every integration has a flag in `ScarletAddonsDB.opt[key]`, on unless it is `false`. The Addons page in the Scarlet
window shows one row per integration with its addon's name, whether it is installed and loaded, the toggle and the lines
written in all (`totals`, not only this session). Turning a flag off stops its lines at once and keeps what it already wrote. An integration starts
only when its addon is loaded and its flag is on.

## Integrations

| Key | Addon | Folder |
| --- | --- | --- |
| `gm` | GatherMate2 | `GatherMate2` |
| `fl` | The Fishing Log | `TheFishingLog` |
| `ff` | Forever Fishing | `ForeverFishing` |
| `ps` | Polestar | `Polestar` |
| `pl` | Profession Shopping List | `ProfessionShoppingList` |
| `at` | Attune | `Attune` |
| `al` | AutoLayer | `AutoLayer` |

### `gm` GatherMate2

| Code | Fields | Meaning |
| --- | --- | --- |
| `N` | uiMapID, x, y, nodeType, name | A node was added to GatherMate2's map, from your own gathering. nodeType is GatherMate2's category (`Herb Gathering`, `Mining`, `Fishing`, `Extract Gas`, `Treasure`, `Archaeology`, `Logging`); name is the node's name. Nodes in a category GatherMate2 has locked are not written. Read from a hook on `GatherMate2:AddNode`; imports do not call it |

### `fl` The Fishing Log

| Code | Fields | Meaning |
| --- | --- | --- |
| `C` | itemID, weight, flags, zone, spot, uiMapID, x, y | A catch the addon recorded. weight is its pounds. flags: `s` specimen, `j` junk, `f` frenzy, `b` heavier than your previous best of that fish. spot is the addon's name for the water. Simulated catches are skipped. Read from the addon's `TFL_CATCH` message |

### `ff` Forever Fishing

| Code | Fields | Meaning |
| --- | --- | --- |
| `C` | itemID, amount, place | Items a cast's loot window added to the addon's catch record. place is the addon's fishing location text. Read from a hook on `ForeverFishing:ShowCatchRecap`, which runs whether or not the recap panel is shown |

### `ps` Polestar

| Code | Fields | Meaning |
| --- | --- | --- |
| `G` | guideId | The guide you follow changed |
| `S` | guideId, step | The guide's current step changed. step is the step's number in the guide |
| `D` | guideId | You finished the guide |
| `K` | guideId, fromStep, toStep | The guide skipped steps, for quests it passed over |
| `R` | fromGuideId, toGuideId | You chose a route from one guide to another |

Read from Polestar's message bus (`GUIDE_CHANGED`, `STEP_CHANGED`, `GUIDE_COMPLETED`, `STEP_SKIPPED`, `ROUTE_CHOSEN`). A
repeated message for the same guide or step is written once. Polestar opens its guide at login, before this integration
starts, so the guide and step it is on then are read from `Polestar.Engine.GetGuide()` and `GetStepIndex()` and not
written; the next step change is.

### `pl` Profession Shopping List

| Code | Fields | Meaning |
| --- | --- | --- |
| `T` | recipeID, quantity | The addon's tracked recipes changed: this recipe now has this quantity (`0` when removed). Both fields are empty when the whole list was cleared. Read from the addon's `ProfessionShoppingList.OnTrackedRecipesChanged` callback |

### `at` Attune

| Code | Fields | Meaning |
| --- | --- | --- |
| `S` | attuneId, stepId | A step of an attunement was marked done for this character |
| `P` | attuneId, percent, name | An attunement's percent done changed, with the attunement's name |

Read from Attune's saved table for the character after a hook sees it finish a progress check, so steps it marks done in
bulk (after an update, for example) are written once, at most 50 lines per check. Steps already done at login are not
written.

### `al` AutoLayer

| Code | Fields | Meaning |
| --- | --- | --- |
| `R` | | You asked for a layer (the request button or command). Written when the request was attempted |
| `J` | lifetime | Someone who answered a layer request joined your group; lifetime is the addon's own count of those |

Request text and player names are never read.
