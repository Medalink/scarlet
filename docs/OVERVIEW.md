# Character overview: the shared data shape

The overview page exists twice: in the desktop app and in game (`/scarlet`, Character page).
Both read the same rows. Three places produce them:

- **The companion** builds them from every recorded line of a character
  (`companion/src/overview.rs`). The app shows them, and each export writes
  them to `Digest.lua` in the addon folder for the game to read.
- **The addon** keeps a ring of the same session rows in SavedVariables
  (`ScarletDB.chars[<Name-Surname>].ov`), summed live as events happen.
- **The game** merges the two: the digest covers every session up to
  `through`, the addon's rows cover the sessions after it, plus the open one.

Rows are keyed by the session's start, `t`, in epoch seconds: the `S` line's time on the
companion side, `time()` when the addon writes `S`. Two keys within 3 seconds are the same
session.

## Counting rules

These hold on both sides, so the companion can check the addon's rows against its own.

- **Played** time is the session's length: from `S` to `ES` (or the session's last line).
- **Level and zone splits.** Time, XP, kills, deaths and quests go to the level and the zone
  current when they happen. Level changes at `L`, zone at `Z` (the `zone` field, the zone's
  name).
- **XP source**, from the `X` line's source: `k` a kill, counted as `xd` when the current
  `Z` instanceType is `party` or `raid` and as `xk` otherwise; `q` -> `xq`; `e` -> `xe`;
  anything else, or an `X` without a source, -> `xo`. The amount is the first `X` field.
- **Kills** are `K` lines (any `by`). **Deaths** are `D` lines. **Quests** are `Q 2` lines
  (turned in).
- **Money.** `M` copper minus its transfer field: positive is earned (`g`), negative is spent
  (`s`, stored positive). Transfers between your own characters count as neither.
- **Balance** (`m`, copper). The addon writes it on `S` (field 13, `money`) and `M` (field 3,
  `balance`), see FORMAT.md. For lines from before those fields, the companion walks back
  from the first known balance by subtracting the `M` deltas.
- **Dungeon runs.** A `Z` whose instanceType is `party` or `raid` starts a run of that
  instanceMapID, unless the last run was the same instanceMapID and you left it less than
  30 minutes ago (then it is the same run). `r` counts the runs started.
- **Zones** (`z`) counts distinct zone names seen in the session.
- **Week** runs from Monday 00:00 local time to now.

## Session row

Short keys, so the SavedVariables stay small. All numbers; missing means 0.

| Key | Meaning |
| --- | --- |
| `t` | start, epoch seconds (the key) |
| `p` | played seconds |
| `l0`, `l1` | level at the start and at the end |
| `xk`, `xd`, `xq`, `xe`, `xo` | XP from kills outside instances, kills in dungeons and raids, quests, exploring, other |
| `k` | kills |
| `dd` | deaths |
| `q` | quests turned in |
| `r` | dungeon and raid runs started |
| `g`, `s` | copper earned, copper spent (both positive) |
| `m` | balance at the end, copper (absent when unknown) |
| `z` | distinct zones |
| `lv` | `{ [level] = { p, xk, xd, xq, xe, xo, k, dd, q } }`, the session's share of each level |
| `zn` | `{ [zone name] = { p, k, dd, x } }`, the session's share of each zone (`x` all XP) |

The addon keeps the last 30 rows in `ov.sess` (oldest first) and the open session in
`ov.cur`, the same shape.

## Digest.lua

Written by the companion after each export, to
`<wow>\_forever_\Interface\AddOns\Scarlet\Digest.lua`, through a `.tmp` file and a rename
(retried on the next export when the game holds the file). It is generated, not in git, and
listed in the TOC; the addon works the same when it is missing (`ScarletDigest == nil`).

```lua
ScarletDigest = {
  v = 1, made = <epoch s>,
  chars = {
    ["Name-Surname"] = {
      through = <t of the newest session included>,
      class = "WARLOCK", race = "Troll", faction = "Horde",
      level = 41, xp = 34632, xpMax = 95800, zone = "Riverglades",
      played = <seconds, from the newest TP total, else the sum of sessions>,
      money = <copper, latest known balance>,
      sessions = { <session rows, newest first: the last 60, or all from the last 14 days if more> },
      levels = { [level] = { p, xk, xd, xq, xe, xo, k, dd, q, at = <epoch s reached, 0 if before recording>, zone = <zone with the most time> } },
      zones = { { name, p, k, dd, x }, ... },          -- top 40 by time
      runs = { { inst, name, n, last }, ... },          -- by n, top 10; last = epoch s
      runsTotal = <n>,
      mates = { { name, class, p, n, last }, ... },     -- top 20 by time together; n sessions
      killers = { { name, n }, ... },                   -- DR pos 1 source, top 10
      deathZones = { { name, n }, ... },                -- top 10
      gold = { { t, m }, ... },                         -- balance at each session end, last 30
    },
  },
}
```

Every string is escaped (`\\`, `\"`, newlines as `\n`); no long brackets, no NaN or inf. The
file stays under 200 KB.

## The page

Header: name in class colour, `Level N Race Class · Faction · in Zone · played`, and a bar to
the next level. Cards: Gold (balance, change over the last 7 sessions, sparkline), Dungeons
and raids (top 5 by runs, total), Played with (top 3 by time together, sessions), Deaths (top
zones, most frequent killer). This week: played, dungeons, quests, gold, zones. Experience by
level: stacked XP sources per level, or time per level. Play history: sessions, days or levels
with played, levels, quests, gold, zones. In game the page is shorter: header, This week, the
current level so far, Played with, Deaths. Empty cards say what is missing in plain words
("No deaths recorded"), no slogans.

The old stat grids stay, renamed "Stats".
