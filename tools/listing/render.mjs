// Renders the listing images into listing/ and the in-game icon source into tools/listing/out/.
//   npx -y -p playwright@1.64.0 -c "node tools/listing/render.mjs [--web <scarlet-web checkout>] [--app <app-shots folder>]"
// then:  python tools/listing/finish.py   (resizes, optimises, writes addon/Scarlet/Media/Icon.tga)
// The window pages are drawn by window.html from the invented demo character in the website's demo.js.
import { createRequire } from "node:module";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const bin = (process.env.PATH || "").split(path.delimiter).find((p) => /_npx/.test(p) && /node_modules[\\/]\.bin[\\/]?$/.test(p));
if (!bin) throw new Error('playwright is not on PATH; run this through: npx -y -p playwright@1.64.0 -c "node tools/listing/render.mjs"');
const { chromium } = createRequire(import.meta.url)(path.join(bin, "..", "playwright"));

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "..", "..");
const arg = (name, fallback) => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : fallback; };
const web = path.resolve(arg("--web", path.join(repo, "..", "..", "..", "scarlet-web")));
const out = path.join(here, "out");
const shots = path.join(repo, "listing", "screenshots");
fs.mkdirSync(out, { recursive: true });
fs.mkdirSync(shots, { recursive: true });

const PAGES = [
  ["overview", "01-character"], ["session", "02-this-session"], ["stats", "03-stats"], ["time", "04-time"],
  ["more", "05-combat-and-more"], ["people", "06-people"], ["live", "07-live"], ["settings", "08-settings"],
];

const mark = fs.readFileSync(path.join(web, "assets", "mark.svg"), "utf8");
const fonts = `
  @font-face { font-family: "SS"; src: url("${pathToFileURL(path.join(repo, "addon/Scarlet/Media/SofiaSans-Regular.ttf"))}"); }
  @font-face { font-family: "SSD"; src: url("${pathToFileURL(path.join(repo, "addon/Scarlet/Media/SofiaSansExtraCondensed-ExtraBold.ttf"))}"); }`;
// The website's mark, scaled to 70% and centred on a full-bleed dark square (no corners to clip in a round crop).
const MARK_PATH = `<path d="M4 18.5c4.5 0 3.2-6.5 7.5-6.5s3.2-5.8 7-5.8" fill="none" stroke="#ff2d55" stroke-width="2.4" stroke-linecap="round"/><circle cx="19" cy="6" r="2.5" fill="#ff2d55"/>`;
const logoSvg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="1024" height="1024"><rect width="24" height="24" fill="#141416"/><g transform="translate(12 12) scale(0.9) translate(-12.15 -11.6)">${MARK_PATH}</g></svg>`;
const bannerHtml = `<style>${fonts} html,body{margin:0;width:1500px;height:500px;background:#141416;overflow:hidden}
  .t{position:absolute;left:330px;top:150px;font:800 150px/1 "SSD";color:#f0f1f3}
  .s{position:absolute;left:336px;top:315px;font:400 34px/1.3 "SS";color:#cdced4}
  svg.m{position:absolute;left:96px;top:120px;width:200px;height:200px}
  svg.p{position:absolute;inset:0}</style>
  <svg class="p" viewBox="0 0 1500 500" width="1500" height="500"><g fill="none" stroke="#ff2d55" stroke-linecap="round" stroke-linejoin="round">
  <path d="M760 440 C 900 440, 860 330, 1000 330 S 1100 210, 1240 210 S 1330 90, 1500 80" stroke-width="12" opacity=".05"/>
  <path d="M760 440 C 900 440, 860 330, 1000 330 S 1100 210, 1240 210 S 1330 90, 1500 80" stroke-width="2" opacity=".35"/>
  <path d="M700 470 C 860 470, 880 380, 1010 360 S 1180 250, 1300 260 S 1400 150, 1500 150" stroke-width="2" opacity=".2"/></g></svg>
  <svg class="m" viewBox="0 0 24 24">${MARK_PATH}</svg>
  <div class="t">Scarlet</div><div class="s">Records what you do in WoW Forever<br>and keeps it on your PC.</div>`;

const browser = await chromium.launch();
const failures = [];

// Window pages --------------------------------------------------------------------------------
{
  const context = await browser.newContext({ viewport: { width: 960, height: 600 }, deviceScaleFactor: 2 });
  await context.route("**/demo.js", (route) => route.fulfill({ path: path.join(web, "assets", "demo.js"), contentType: "text/javascript" }));
  for (const [key, name] of PAGES) {
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    await page.goto(pathToFileURL(path.join(here, "window.html")).href + "?page=" + key);
    const fonts = await page.evaluate(() => window.__ready);
    if (!fonts.ss || !fonts.sss || !fonts.ssd) failures.push(`${name}: a bundled font did not load ${JSON.stringify(fonts)}`);
    if (errors.length) failures.push(`${name}: ${errors.join(" | ")}`);
    await page.screenshot({ path: path.join(shots, name + ".png") });
    console.log("window", name, JSON.stringify(fonts));
    await page.close();
  }
  await context.close();
}

// Logo, banner, icon source ------------------------------------------------------------------
{
  const context = await browser.newContext({ viewport: { width: 1024, height: 1024 }, deviceScaleFactor: 1 });
  const page = await context.newPage();
  await page.setContent(`<style>html,body{margin:0;background:transparent}</style>${logoSvg}`);
  await page.screenshot({ path: path.join(out, "logo-1024.png") });
  await page.setViewportSize({ width: 256, height: 256 });
  await page.setContent(`<style>html,body{margin:0;background:transparent}svg{width:256px;height:256px;display:block}</style>${mark}`);
  await page.screenshot({ path: path.join(out, "icon-256.png"), omitBackground: true });
  await page.setViewportSize({ width: 1500, height: 500 });
  // A file page, so the file: font URLs load (setContent pages are about:blank and may not read them).
  fs.writeFileSync(path.join(out, "banner.html"), `<meta charset="utf-8">${bannerHtml}`);
  await page.goto(pathToFileURL(path.join(out, "banner.html")).href);
  const loaded = await page.evaluate(async () => { await Promise.all(['14px "SS"', '14px "SSD"'].map((f) => document.fonts.load(f))); return document.fonts.check('14px "SS"') && document.fonts.check('14px "SSD"'); });
  if (!loaded) failures.push("banner: a bundled font did not load");
  await page.screenshot({ path: path.join(out, "banner-1500x500.png") });
  await context.close();
}
await browser.close();
if (failures.length) { console.error(failures.join("\n")); process.exit(1); }
