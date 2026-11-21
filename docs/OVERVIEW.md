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

The addon keeps the last 120 rows in `ov.sess` (oldest first) and the open session in
`ov.cur`, the same shape, with `last`: the epoch seconds of its latest change, so a row a crash
leaves open keeps its time up to then.

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
      sessions = { <session rows, newest first: the last 60, or all from the last 14 days if more; and
                    more, if needed, until their `p` add up to 36,000, for the level estimates> },
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

Header: name in class colour, `Level N Race Class · Faction · in Zone · played`, a bar to
the next level and the level estimates under it. Cards: Gold (balance, change over the last 7 sessions, sparkline), Dungeons
and raids (top 5 by runs, total), Played with (top 3 by time together, sessions), Deaths (top
zones, most frequent killer). This week: played, dungeons, quests, gold, zones. Experience by
level: stacked XP sources per level, or time per level. Play history: sessions, days or levels
with played, levels, quests, gold, zones. In game the page is shorter: header, This week (played, quests, gold, dungeons), the
current level so far, Played with, Deaths by zone (the digest's top 10 plus newer sessions). It has no
zones tile and no killer. Empty cards say what is missing in plain words
("No deaths recorded"), no slogans.

The old stat grids stay, renamed "Stats".

## Level estimates

Time to the next level, to the next multiple of 10 and to level 60, from how the character has
actually gained XP. The game and the app show the same numbers, so both follow this section
exactly. All sums use the merged session rows (digest rows, the addon's own rows, the open
session), newest first by `t`; two keys within 3 seconds are one row.

**Pace.** Take rows newest first, the open session included, and stop after the row that brings
the running total of `p` to 36,000 seconds (10 hours) or more; use all rows when they add up to
less. `played` is the sum of `p` over the rows taken and `xp` the sum of `xk + xd + xq + xe + xo`.
There is no estimate when `played` is under 900 seconds (15 minutes) or `xp` is 0. Otherwise
`pace = xp / played` (XP per played second); the page shows `round(pace * 3600)` as XP an hour.

**XP left to reach level T**, for a character at level `L` with `xp` of `xpMax` on the bar
(the client's numbers; the digest's `level`, `xp` and `xpMax` on the companion side):

```
left(T) = max(0, xpMax - xp) + sum of NEED[n] for n = L+1 .. T-1
```

The empty sum is 0, so the next level needs only what is left on the bar. `NEED[n]` is the XP
that level `n` needs to reach level `n+1`:

| Level | XP | Level | XP | Level | XP | Level | XP |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 400 | 16 | 16,000 | 31 | 50,800 | 46 | 123,200 |
| 2 | 900 | 17 | 17,700 | 32 | 54,500 | 47 | 129,100 |
| 3 | 1,400 | 18 | 19,400 | 33 | 58,600 | 48 | 135,100 |
| 4 | 2,100 | 19 | 21,300 | 34 | 62,800 | 49 | 141,200 |
| 5 | 2,800 | 20 | 23,200 | 35 | 67,100 | 50 | 147,500 |
| 6 | 3,600 | 21 | 25,200 | 36 | 71,600 | 51 | 153,900 |
| 7 | 4,500 | 22 | 27,300 | 37 | 76,100 | 52 | 160,400 |
| 8 | 5,400 | 23 | 29,400 | 38 | 80,800 | 53 | 167,100 |
| 9 | 6,500 | 24 | 31,700 | 39 | 85,700 | 54 | 173,900 |
| 10 | 7,600 | 25 | 34,000 | 40 | 90,700 | 55 | 180,800 |
| 11 | 8,800 | 26 | 36,400 | 41 | 95,800 | 56 | 187,900 |
| 12 | 10,100 | 27 | 38,900 | 42 | 101,000 | 57 | 195,000 |
| 13 | 11,400 | 28 | 41,400 | 43 | 106,300 | 58 | 202,300 |
| 14 | 12,900 | 29 | 44,300 | 44 | 111,800 | 59 | 209,800 |
| 15 | 14,400 | 30 | 47,400 | 45 | 117,500 | | |

The current level uses the client's `xpMax` instead of its table value. Observed `xpMax` values
(level 41: 95,800 in 131 `X` and `S` lines; level 7: 4,500 on the digest) match the table. If a
level is ever seen to differ, the observed value replaces that table entry.

**Targets**, for `L` below 60: the next level `L + 1`; the next multiple of 10 above `L`,
`(floor(L / 10) + 1) * 10`, only when it differs from `L + 1` and from 60; and 60. At level 60
and above nothing is shown. At 59 the only target is 60.

**Time** is `left(T) / pace`, in played time. Written as minutes `m = max(1, round(seconds / 60))`
(halves round up): `d` days and `h` hours (`m div 1440`, `m mod 1440 div 60`) as `3d 4h` when
`d > 0`; hours and minutes as `1h 52m` when `h > 0`; otherwise `41m`.

**Date.** `rate` is the sum of `p` over the rows with `t >= now - 14 * 86400`, divided by 14
(played seconds per calendar day). The date is `now + time / rate * 86400` seconds, in local
time, written `Fri 28 Nov` (weekday, day, month), with the year added when it is not this year.
Leave the date out when `rate` is 0 or when `time / rate` is more than 3,650 days. The page
writes "about" before it.

**The page.** Under the level bar: one row per target, `Level T`, the time and the date, and one
muted line with the basis, `At your pace over the last 5h 35m played: 12,564 XP an hour`, where
the duration is `played` in the time format above. With no estimate the rows are empty and the
muted line says what is missing.
