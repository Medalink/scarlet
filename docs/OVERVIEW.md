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

- **Played** time is the session's length: from `S` to `ES` (or the session's last line), plus the
  reload before the next session. The client keeps counting played time through a reload, which the
  rows would miss: about 7 seconds each. The first `TP` read of a session gives the client's counter
  at its start (the read's total less the seconds since `S`). Where that stands more than 1.5
  seconds above the counter at the end of the session before (its last read, plus the seconds
  since), the difference is added to that session, to the level and zone it ended in, up to the wall
  time between the two sessions. A logout in between adds nothing, since the counter stood still.
  Sessions without a `TP` read are not credited. A character's played total is the counter at the
  end of its last session when it was read in it, else the last `TP` total, else the sum of the rows.
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
| `lv` | `{ [level] = { p, xk, xd, xq, xe, xo, k, dd, q, g, s, r } }`, the session's share of each level (`g` and `s` copper earned and spent, `r` runs started, counted as the row's own) |
| `zn` | `{ [zone name] = { p, k, dd, x } }`, the session's share of each zone (`x` all XP) |

The addon keeps the last 120 rows in `ov.sess` (oldest first) and the open session in
`ov.cur`, the same shape, with `last`: the epoch seconds of its latest change, so a row a crash
leaves open keeps its time up to then.

## Digest.lua

Written by the companion after each export, to
`<wow>\_forever_\Interface\AddOns\Scarlet\Digest.lua`, through a `.tmp` file and a rename
(retried on the next export when the game holds the file). Each character's rows come from
`overview.json`, rebuilt from the payloads first when any payload is newer than it. It is generated, not in git, and
listed in the TOC; the addon works the same when it is missing (`ScarletDigest == nil`).

```lua
ScarletDigest = {
  v = 1, made = <epoch s>,
  chars = {
    ["Name-Surname"] = {
      through = <t of the newest session included>,
      class = "WARLOCK", race = "Troll", faction = "Horde",
      level = 41, xp = 34632, xpMax = 95800, zone = "Riverglades",
      played = <seconds: the client's counter at the end of the last session, see Played>,
      money = <copper, latest known balance>,
      first = <t of the character's first recorded session>,
      sessions = { <session rows, newest first: the last 60, or all from the last 14 days if more;
                    trimmed further when the file would pass 200 KB> },
      recent = { { t, p, x }, ... },                    -- for the level estimates, see below
      levels = { [level] = { p, xk, xd, xq, xe, xo, k, dd, q, g, s, r, at = <epoch s reached, 0 if before recording>, zone = <zone with the most time> } },
      zones = { { name, p, k, dd, x }, ... },          -- top 40 by time
      runs = { { inst, name, n, last }, ... },          -- by n, top 10; last = epoch s
      runsTotal = <n>,
      mates = { { name, class, p, n, last }, ... },     -- top 20 by time together; n sessions
      killers = { { name, n }, ... },                   -- DR pos 1 source, top 10
      deathZones = { { name, n }, ... },                -- top 10
      gold = { { t, m }, ... },                         -- balance at each session end, last 30
      cap = { level, reached, p, bosses, loot, honor, hks, skillups, ldone, ltotal, lpoints, ilvl,
              rep = { { name, n } }, runs = { { name, n, p, b } }, killers = { { name, n } }, dz = { { name, n } } },
                                                        -- present once a session reported the level cap, see Max level
      before = { kills, deaths, dungeons, bosses, quests, xp, earned, spent, loot, tracked },
                                                        -- totals over the sessions the addon did not record
                                                        -- itself (an `S` line whose version field is not a number);
                                                        -- absent when it recorded all of them
    },
  },
}
```

`recent` is a compact list for the dates of the level estimates: one `{ t, p, x }` per session
(start, played seconds, total XP: `xk + xd + xq + xe + xo`), newest first, covering every
session from the 14 days before `made` and more until their `p` add up to 36,000. It is built
from all the character's sessions before `sessions` is trimmed and is never trimmed itself, so
the dates are measured on the same history whatever the size of `sessions`. `levels` is never
trimmed either, and holds `p` and the XP sources `xk`, `xd`, `xq`, `xe`, `xo` of every level
(a source that is 0 is left out). `first` is `t` of the oldest session the companion has.

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

Once the character has been at the cap for an hour of played time, the page changes, see Max level.

In game the Stats cards count from the install (`ScarletDB.chars[key]`). When the digest has
`before` for the character, Kills, Deaths, Dungeons, Bosses, Quests, Items looted, Experience, Gold
earned, Gold spent and Time recorded add it, so they hold the whole history the app and the website
show; every other card on that page says "since install", and the Time, Combat and more and People
pages carry it in their title. Without `before` nothing is added or labelled. The session page never
adds it.

## Level estimates

Time to the next level, to the next multiple of 10 and to the level cap, from how the character has
actually gained XP at each level. The game and the app show the same numbers, so both follow
this section exactly. The pace reads the per-level history; the date reads the merged rows
`{ t, p, x }`, newest first by `t`: the digest's `recent`, the addon's own rows with `t` after
`through` (their `x` is `xk + xd + xq + xe + xo`) and the open session. Two keys within 3
seconds are one row. `sessions` is not read here. A digest without `recent` (written by an
older companion) falls back to its `sessions`, and without `first` to the oldest merged row.
The app has no addon rows or open session: it merges nothing, reads `recent` as the companion
builds it from all sessions, and takes the per-level history from its full history.

**Pace.** A character gets stronger as it levels, so the pace is a fit over levels, not an
average over the latest hours.

- Points. For each level `n <= L` (the current level), `p_n` is the played seconds at level `n`
  and `x_n` the XP gained at level `n` (`xk + xd + xq + xe + xo`). They come from the per-level
  history: the digest's `levels` table, plus the `lv` shares of the addon's own rows with `t`
  after `through`, plus the open session's `lv` unless a merged row already holds it (the same
  start within 3 seconds). A level is a point when `p_n >= 900` and `x_n > 0`; its
  `y_n = ln(x_n / p_n)`.
- Fit. A weighted least squares of `y` on `n` with weights `p_n`. With `W = sum p_n`,
  `mn = sum(p_n * n) / W` and `my = sum(p_n * y_n) / W`:
  `b = sum(p_n * (n - mn) * (y_n - my)) / sum(p_n * (n - mn)^2)` and `a = my - b * mn`.
  Clamp `b` to `[0, ln(1.05)]`; when `b` was clamped, `a = sum(p_n * (y_n - b * n)) / W`.
- Fewer than 3 points: a flat pace, `b = 0` and `a = ln(sum x / sum p)`, the sums over all levels
  `n <= L`.
- No estimate when the total `p` over levels `n <= L` is under 900 seconds (15 minutes) or the
  total `x` is 0.
- `rate(n) = exp(a + b * n)` is XP per played second at level `n`.

**Seconds to reach level T**, for a character at level `L` with `xp` of `xpMax` on the bar
(the client's numbers; the digest's `level`, `xp` and `xpMax` on the companion side):

```
time(T) = max(0, xpMax - xp) / rate(L) + sum of NEED[n] / rate(n) for n = L+1 .. T-1
```

The empty sum is 0, so the next level needs only what is left on the bar, at the pace of the
current level. `NEED[n]` is the XP that level `n` needs to reach level `n+1`:

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

**Targets**, for `L` below the cap `C`: the next level `L + 1`; the next multiple of 10 above `L`,
`(floor(L / 10) + 1) * 10`, only when it differs from `L + 1` and from `C`; and `C`. `C` is the level cap the
client reported (see Max level), at most 60 because `NEED` ends there, and 60 when no session reported one.
At the cap and above nothing is shown and nothing is fitted. One level below the cap the only target is the cap.

**Time** is `time(T)`, in played time. Written as minutes `m = max(1, round(seconds / 60))`
(halves round up): `d` days and `h` hours (`m div 1440`, `m mod 1440 div 60`) as `3d 4h` when
`d > 0`; hours and minutes as `1h 52m` when `h > 0`; otherwise `41m`.

**Date.** `rate` is the sum of `p` over the rows with `t >= now - 14 * 86400`, divided by the
days covered: `min(14, (now - first) / 86400)`, not rounded, at least 1, where `first` is the
digest's `first` (the start of the character's oldest recorded session; the oldest merged row
when the digest has none). A character recorded for 2 days is measured over 2 days, not 14.
`rate` is played seconds per calendar day. The date is `now + time / rate * 86400` seconds, in local
time, written `Fri 28 Nov` (weekday, day, month), with the year added when it is not this year.
Leave the date out when `rate` is 0 or when `time / rate` is more than 3,650 days. The page
writes "about" before it.

**The page.** Under the level bar: one row per target, `Level T`, the time and the date, and one
muted line with the basis, `Based on 38 levels played: 11,278 XP an hour at level 41, rising
2.1% a level`. The number of levels is the points of the fit (`1 level` for one); the rate is
`round(rate(L) * 3600)` with thousands separators and the rise is `(exp(b) - 1) * 100` to one
decimal. A flat pace says `Based on 2 levels played: 6,120 XP an hour`, the number being the
levels with played time. With no estimate the rows are empty and the muted line says what is
missing.

## Max level

A character at the level cap has no levels to estimate, so nothing levelling-related is worked out for
it, and the page leads with what it does at the cap.

**The cap** is the client's, never a constant. The addon reads it at login (`ns.Cap` in Core.lua:
`GameRulesUtil.GetEffectiveMaxLevelForPlayer`, else the lower of `GetMaxLevelForPlayerExpansion` and
`GetMaxPlayerLevel`) and writes it as field 14 of `S`. The companion keeps the latest one it saw as the
character's cap and writes it as `cap.level`; sessions from older addons have none, and a character
without one is never treated as capped. A character is *at the cap* when its level is at least the cap.
The level changes into the cap at `L` while playing.

**What stops at the cap.** In the addon, once a character is at the cap, or has experience turned off
(`IsXPUserDisabled`, the `ExperienceBarDisabled` game rule): `PLAYER_XP_UPDATE`, `UPDATE_EXHAUSTION` and
`CHAT_MSG_COMBAT_XP_GAIN` are unregistered, the XP source tracking is a no-op, the rested timers
are off, and the Character page runs no pace fit or estimate. The events come back if experience is
turned on again. The `X`, `RX` and `XR` lines are therefore not written there, and `S` carries no bar. The
companion reports no bar (`xp` and `xpMax` 0) and no estimates for a character at the cap.

**Played time at the cap** is the largest of: the cap level's `p` summed over the rows, the digest's
`cap.p`, and the addon's last `TP` levelSeconds read while at the cap (`ScarletDB.chars[key].capSecs`).
The companion's `cap.p` is the larger of the cap level's share and its latest `TP` levelSeconds read at
the cap. The last of the three covers time played before Scarlet was installed.

**The switch.** With one hour (3,600 s) of played time at the cap, the page leads with max level data
and moves the levelling content down. Below the cap, and in the first hour at it, the page is the one
described above. The app, the game and the companion apply the same rule.

**Level shares.** Each level's share also holds `g` and `s` (copper earned and spent, the same net of
transfers as the row's) and `r` (runs started). The cap level's share therefore holds time, gold, runs,
kills, deaths and quests at the cap.

**The `cap` block** holds what the shares do not, all counted while at the cap except where noted:
`reached` (when the `L` line into the cap was written), `bosses` (`B`), `loot` (`O` counts), `honor` (`HN`
amounts), `hks` (`HK` gained), `skillups` (`SK` lines), `rep` (positive `RP` amounts by faction, top 5),
`runs` (per dungeon or raid: runs started, seconds inside and boss kills, top 5 by runs), `killers` and `dz`
(killing blow sources and death zones, top 5). `ldone`, `ltotal` and `lpoints` are the latest `AP` line and
`ilvl` the latest `SX` `ilvlall` or `ST` item level, at any level.

**The page at the cap, after the hour.** Header without a bar. A strip: time at max level, gold an hour,
dungeons and raids, deaths, item level, items looted. Then Gold (balance, earned and spent at the cap,
net an hour), Dungeons and raids (runs with time and bosses), Deaths, Reputation and professions,
Legacy and PvP, Played with, play time by day and by zone. Then a Levelling section (XP by source, time per
level) and the play history. The game's page shows the same figures in cards: At max level, Gold,
Dungeons and raids, Deaths, Reputation and professions, Legacy and PvP, Levelling (time to reach the
cap and XP by source), Played with. The `cap` block is as of the last export; the cap level's share
adds the addon's own rows and the open session.
