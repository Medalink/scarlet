# Listings for CurseForge and Wago

Everything needed to create the two projects is here. Neither project exists yet, so `Scarlet.toc` has the two ID
lines commented out (`# ## X-Curse-Project-ID:` and `# ## X-Wago-ID:`).

## Files

| File | Use |
| --- | --- |
| `summary.txt` | The one-line summary (137 characters). |
| `description-curseforge.md` | Description for CurseForge. Choose the Markdown editor, then paste it. |
| `description-wago.md` | Description for Wago. Same text as the CurseForge file (Markdown, no tables or inline images). |
| `features.md`, `privacy.md`, `how-to-use.md` | The parts both descriptions are built from. |
| `changelog.md` | Changelog, newest version first. `.pkgmeta` points the packager at it. |
| `images/logo-400x400.png` | CurseForge logo and the avatar for both sites. Full-bleed dark square, so a round crop loses nothing. |
| `images/logo-512x512.png`, `images/logo-1024x1024.png` | Larger copies if a form asks for more. |
| `images/banner-1500x500.png` | For a banner field if either site shows one. Neither documents one, so this may stay unused. |
| `screenshots/01` to `08` | The `/scarlet` window. |
| `screenshots/09` to `11` | The desktop app. |

The in-game icon is `addon/Scarlet/Media/Icon.tga` (64x64, 32-bit, uncompressed), set by `## IconTexture` in the TOC.

## The images are renders

None of these images is a game capture. Replace the screenshots with real captures when you have them.

- `screenshots/01` to `08` are drawn by `tools/listing/window.html` from the layout in `UI.lua` and `Overview.lua`
  (880 x 560 window, same colours, the bundled Sofia Sans files) and filled with the website's invented demo character.
  Numbers on the Live page are made up.
- `screenshots/09` to `11` are the real desktop app UI (`scarlet-app/app/ui`) with its data commands stubbed to the same
  demo character. The header shows the version string that checkout hardcodes (`v0.1.0`).
- `images/logo-*`, `images/banner-*` and `Icon.tga` come from the website's mark (`scarlet-web/assets/mark.svg`).

To redraw them: `npx -y -p playwright@1.64.0 -c "node tools/listing/render.mjs"`, the same with `app.mjs`, then
`python tools/listing/finish.py`.

Shot list for real captures (the sites accept PNG or JPG; neither documents a size limit):

1. Character page, on a character with a few levels recorded.
2. Stats page.
3. This session page after a short play session.
4. Live page during a fight.
5. Settings page.
6. The login toast ("Scarlet is recording").
7. The recording mark beside the minimap, with its tooltip.
8. The AddOn list at the character select screen, showing the Scarlet icon.

## What the sites ask for

Sources: the CurseForge project submission guide, the Wago developer docs and API data, and the BigWigs packager. Where a
limit is not documented, it says so.

| | CurseForge | Wago |
| --- | --- | --- |
| Game version | Flavor "Forever", game version 1.60.1 | Flavor `forever`, patch 1.60.1 (the only one) |
| Why | The CurseForge file pages list Forever files as 1.60.1. | `addons.wago.io/api/data/game` lists `forever: 1.60.1`, with TOC suffixes `-Camelot` and `-Forever`. |
| Interface number | 16001 | 16001. The packager maps `16???` to Forever and printed `Game version: 1.60.1` when run on this repo. |
| Logo | PNG, at least 400 x 400, 1:1, not a single colour | Not documented; use the 400 x 400 PNG. |
| Summary | One line. Limit not documented; forum sources say 250 or 256. | Not documented. |
| Description | Markdown or WYSIWYG, set when you create the project | Markdown |
| Screenshots | Images tab, after the project is created. Count and size not documented. | Not documented. |
| Categories | One main and up to 4 more | Not documented. |
| License | A list plus "Custom" | Not documented. |

Not confirmed anywhere public: Wago's summary and screenshot limits and its category list. Check the form when you reach it.

Forever has its own flavor on both sites, so no fallback to Retail or Classic is needed.

## Create the CurseForge project

1. Sign in at https://authors.curseforge.com/ and choose Create a project.
2. Game: World of Warcraft. Project class: Addons.
3. Name: `Scarlet`.
4. Logo: `images/logo-400x400.png`.
5. Summary: paste `summary.txt`.
6. Main category: Data Export. Additional categories (up to 4): Quests & Leveling, Combat.
7. Allow comments: on.
8. Text editor: Markdown. Description: paste `description-curseforge.md`.
9. License: GNU General Public License v3.0 (GPL-3.0).
10. Submit. The project goes to moderation.
11. When it is approved, copy the project ID from the About Project box on the project page. Paste it into
    `addon/Scarlet/Scarlet.toc`: remove `# ` from the `## X-Curse-Project-ID:` line and put the number after the colon.
12. Images tab: upload `screenshots/01` first, then the rest in order.
13. Files tab: upload the zip by hand (see "Make the zip"; game version Forever 1.60.1), or let `publish-stores.ps1` do it
    (see "Publish a release to both sites").

## Create the Wago project

1. Sign in at https://addons.wago.io/developers and choose New Addon.
2. Name `Scarlet`, summary from `summary.txt`, description from `description-wago.md`, avatar
   `images/logo-400x400.png`, screenshots from `screenshots/`.
3. Game: Forever (1.60.1). License: the same as on CurseForge.
4. After it is created, the dashboard prints the project ID under the addon name (8 letters and digits, case matters).
   Paste it into `addon/Scarlet/Scarlet.toc`: remove `# ` from `## X-Wago-ID:` and put the ID after the colon.
5. New Release: upload the zip, stability stable, changelog from `changelog.md`, or let `publish-stores.ps1` do it.
6. Create an API key at https://addons.wago.io/account/apikeys for the script (see below).

## Publish a release to both sites

`scarlet-app/scripts/publish-stores.ps1` uploads the addon zip of a published `Medalink/scarlet-app` release to both
sites, and `release.ps1 -Lane release` runs it after publishing. Once the projects exist:

1. Put the IDs in `addon/Scarlet/Scarlet.toc` on `main`: remove `# ` from `## X-Curse-Project-ID:` and `## X-Wago-ID:`
   and paste the numbers. The script reads them from there; the release zip never carries them.
2. Put the tokens in one-line files, or in the environment:

   | Site | File | Environment variable | Made at |
   | --- | --- | --- | --- |
   | CurseForge | `E:\Dev\secrets\scarlet-addon-stores\curseforge-token` | `CF_API_KEY` | https://authors.curseforge.com/account/api-tokens |
   | Wago | `E:\Dev\secrets\scarlet-addon-stores\wago-token` | `WAGO_API_TOKEN` | https://addons.wago.io/account/apikeys |

3. `pwsh scripts/publish-stores.ps1 -Version 1.0.0 -DryRun` prints what each site would get. Without `-DryRun` it uploads.

The uploaded changelog is the "Addon changes" section of the release notes (commit titles); `-Changelog listing\changelog.md`
uploads that file instead. The game version comes from the TOC's `## Interface` (16001 is Forever 1.60.1) and is checked
against each site's own list. Details and options are in `scarlet-app/docs/RELEASING.md`.

## Make the zip

`.pkgmeta` makes the BigWigs packager build `Scarlet/` from `addon/Scarlet` only. Without a CI job, run it by hand
from a clean checkout, with an annotated tag on the commit:

    git tag -a v0.4.0 -m "0.4.0"
    bash release.sh -d -z

(`release.sh` is from https://github.com/BigWigsMods/packager; `-d` skips upload, `-z` skips the zip when `zip` is not
installed.) The result is in `.release/Scarlet`. Zip that folder so the zip's top-level folder is `Scarlet`. It must not
contain `Digest.lua`, `Items.lua` or a `ScarletData` folder: the desktop app writes those into its own `ScarletData`
addon folder, and Scarlet's TOC lists none of them.

Checked on 2026-11-20 against the packager's `master`: the package holds the TOC, all `.lua` files,
`Media/` and `Icon.tga`. It does not hold `docs/`, `tools/`, `listing/` or `README.md`.

## Check in game once

- The icon shows in the AddOn list. `Icon.tga` is the format the client loads for `## IconTexture`, but this client
  was not available here to confirm it. If the icon is blank, convert it to `.blp`.
- The addon compartment entry shows the same icon.
- A copy without `ScarletData` loads with no error and no LUA_WARNING about a missing file. This is how a git clone and a CurseForge install load.
- `## X-Category: Data Export` is metadata only; the client groups the AddOn list by `## Category`, which has no fitting
  name (the client's list has "Other" and "Development Tools"), so Scarlet is left ungrouped.

## Open decisions

- License: decided, GPL-3.0 (the repo's `LICENSE` file and `## X-License: GPL-3.0`). Pick GPL-3.0 on both sites.
