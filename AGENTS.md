# Scarlet addon

The WoW Forever addon that records what a character does. [README.md](README.md) says what it records and shares.
[docs/FORMAT.md](docs/FORMAT.md) is the line format that the desktop app
([scarlet-app](https://github.com/Medalink/scarlet-app)) and the website
([scarlet-web](https://github.com/Medalink/scarlet-web)) both read: change it before changing any side that reads it.

## Rules

- No unit or feature tests. `ship` runs the gates: LuaLS at Hint level over `addon/` with `.luarc.json`, and every
  `addon/Scarlet/*.lua` compiled by `luajit -bl` (Lua 5.1).
- A new line code ships in this order: FORMAT.md here first, then its row in scarlet-web's `docs/groups.tsv` at once,
  then the `scarlet-part` revision in scarlet-app. scarlet-web's `part-groups` gate reads FORMAT.md on this repo's
  GitHub main and fails both ways, on a code in no group and on a group code FORMAT.md lacks, so the row never ships
  first. This repo has no such gate: until the row lands, scarlet-web ships that touch `part/` or `docs/groups.tsv` fail.
- Change only the surface the report or design names. A piece several screens share changes for all of them: list its
  users, make the change opt-in for the screen named, and check one other user on the real surface before shipping.
- Agents cannot run the game. On medaviper the game loads `E:/Dev/scarlet/addon/Scarlet` through a junction and the owner
  plays from it: never edit that checkout or switch its branch. Work in a worktree; after a ship, `git -C E:/Dev/scarlet
  pull` brings the change to the game. A change loads on `/reload`; a new file or TOC line loads only after a full client
  restart. Until the owner's next export shows the new lines, the ship note says the change passed static checks only and
  was not seen in game.
- This repo is public. Never commit Blizzard's art. Never put a real player name in the repo, a doc, a screenshot or a
  commit message; examples use `Name-Surname`.
- Never name the owner's local game-file tooling, its folders or its paths in a file, a comment or a commit message. Do
  not name other companies' addons, apps, websites or data services, except the game and its maker (World of Warcraft,
  Blizzard), the addons whose data Scarlet records or reads prices from (`docs/ADDONS.md`, "Imported history" in
  `docs/FORMAT.md`, the Loot HUD's price sources in the README), OpenMap, and the sites it publishes to (CurseForge, Wago,
  GitHub).
- A backslash in a script passed inline through the Bash tool on medaviper can arrive changed: a doubled backslash
  arrives as one, so an escape meant as text is read by the script's language as a control character (Python reads
  `\0` as a NUL). On 2026-11-22 this put a NUL into `scripts/deploy/ring-entry.sh` in scarlet-web, which shipped and made
  git show the file as binary while `sh -n` still passed. Write any script or patch that holds a backslash with the file
  Write tool, then run it. Scan an edited script for control bytes, and read a diff with `git diff --text` when git says
  Bin.
- The beta UI rebuild is on the branch `feat/beta-ui-parity-rebuild` and stays off main until the owner says in so many
  words to ship the rebuild (held since 2026-11-23). Push that branch only: no `ship`, no merge into main, no deploy of
  it. Approval of how one part looks is not approval to ship. The ship that lands the rebuild deletes this bullet.
- Land every change with `ship`. Open no pull request and run no push to main by hand.
