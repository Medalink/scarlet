// Renders four pages of the Scarlet desktop app into listing/screenshots/ from a scarlet-app checkout, with the
// Tauri bridge stubbed and the website's invented demo character as the data. No real recording is read.
//   npx -y -p playwright@1.64.0 -c "node tools/listing/app.mjs [--web <scarlet-web>] [--app <scarlet-app>]"
// then:  python tools/listing/finish.py
import { createRequire } from "node:module";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const bin = (process.env.PATH || "").split(path.delimiter).find((p) => /_npx/.test(p) && /node_modules[\\/]\.bin[\\/]?$/.test(p));
if (!bin) throw new Error('playwright is not on PATH; run this through: npx -y -p playwright@1.64.0 -c "node tools/listing/app.mjs"');
const { chromium } = createRequire(import.meta.url)(path.join(bin, "..", "playwright"));

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "..", "..");
const arg = (name, fallback) => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : fallback; };
const web = path.resolve(arg("--web", path.join(repo, "..", "..", "..", "scarlet-web")));
const ui = path.resolve(arg("--app", path.join(repo, "..", "..", "..", "scarlet-app")), "app", "ui");
const shots = path.join(repo, "listing", "screenshots");
fs.mkdirSync(shots, { recursive: true });
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".woff2": "font/woff2", ".woff": "font/woff", ".ttf": "font/ttf", ".svg": "image/svg+xml", ".png": "image/png" };

const browser = await chromium.launch();

// 1. The invented data, shaped like the app's commands (see app/ui/views/*.js).
const scratch = await (await browser.newContext()).newPage();
await scratch.addScriptTag({ path: path.join(web, "assets", "demo.js") });
const data = await scratch.evaluate(() => {
  const D = window.ScarletDemo, ch = D.character(), sec = (ms) => Math.round(ms / 1000);
  const rows = ch.sessions.slice().reverse();
  const ov = {
    class: "WARRIOR", race: "Orc", faction: "Horde", zone: ch.zone, level: ch.level, played: ch.played, xp: ch.xp, xpMax: ch.xpMax,
    through: sec(rows[0].t), money: ch.money,
    sessions: rows.map((s) => ({ t: sec(s.t), p: s.p, l0: s.l0, l1: s.l1, q: s.q, g: s.g, s: s.s, r: s.r, z: s.zn.length, zn: Object.fromEntries(s.zn.map((z) => [z, {}])) })),
    levels: Object.fromEntries(ch.levels.map((l) => [l.level, { p: l.p, xk: l.xp.xk, xd: l.xp.xd, xq: l.xp.xq, xe: l.xp.xe, xo: l.xp.xo, k: Math.round(l.k), dd: l.dd, q: Math.round(l.q), at: sec(l.at), zone: l.zone }])),
    gold: ch.sessions.map((s) => ({ t: sec(s.t + s.p * 1000), m: s.m })),
    runs: ch.runs.map(([name, n]) => ({ name, n })), runsTotal: ch.runs.reduce((a, r) => a + r[1], 0),
    mates: ch.mates.map(([name, p, n]) => ({ name, class: "", p, n })),
    deathZones: ch.deathZones.map(([name, n]) => ({ name, n })), killers: ch.killers.map(([name, n]) => ({ name, n })),
  };
  const zp = {};
  for (const s of ch.sessions) for (const z of s.zn) { const e = (zp[z] = zp[z] || { name: z, p: 0, k: 0 }); e.p += s.p / s.zn.length; e.k += s.k / s.zn.length; }
  ov.zones = Object.values(zp).map((z) => ({ ...z, p: Math.round(z.p), k: Math.round(z.k) }));
  // Time to the next level, the next tens level and level 60, as the companion words them.
  const full = ch.levels.slice(ch.level - 3, ch.level - 1), perSec = full.reduce((a, l) => a + l.xp.total, 0) / full.reduce((a, l) => a + l.p, 0);
  const rate = ch.days.filter((d) => !d.future).slice(-14).reduce((a, d) => a + d.p, 0) / 14, now = Date.UTC(2026, 10, 20, 12);
  const span = (s) => { const m = Math.max(1, Math.round(s / 60)), d = Math.floor(m / 1440), h = Math.floor((m % 1440) / 60); return d ? `${d}d ${h}h` : h ? `${h}h ${m % 60}m` : `${m}m`; };
  const left = (t) => { let x = ch.xpMax - ch.xp; for (let n = ch.level + 1; n < t; n++) x += D.xpMax(n); return x; };
  const eta = { targets: [ch.level + 1, 40, 60].map((t) => ({ level: t, time: span(left(t) / perSec), date: "about " + D.day(now + (left(t) / perSec / rate) * 86400000) })), basis: `At your pace over the last ${span(full.reduce((a, l) => a + l.p, 0))} played: ${Math.round(perSec * 3600).toLocaleString("en-US")} XP an hour` };

  // Activity: events per weekday x hour (Monday first) and per day, from the session times.
  const week = Array(168).fill(0), days = {};
  for (const s of ch.sessions) for (let t = s.t; t < s.t + s.p * 1000; t += 600000) {
    const d = new Date(t), idx = ((d.getUTCDay() + 6) % 7) * 24 + d.getUTCHours();
    week[idx] += 190 + (idx % 7) * 11; const k = d.toISOString().slice(0, 10); days[k] = (days[k] || 0) + 190;
  }
  const dayList = Object.entries(days).sort().slice(-60);
  const heat = { week, max_week: Math.max(...week), days: dayList, max_day: Math.max(...dayList.map((d) => d[1])) };

  const coin = (c) => { c = Math.round(c); return `${Math.floor(c / 10000)}g ${Math.floor(c / 100) % 100}s ${c % 100}c`; };
  const total = ch.played, f = (x) => Math.round(total * x);
  const stats = {
    sections: [
      { title: "Combat", cards: [["Kills", "3946"], ["Killing blows", "3670"], ["Casts", "25254"], ["Deaths", "23"], ["Time in combat", "11h 37m"], ["Damage done", "9482310"], ["Healing done", "412760"], ["Interrupts", "1286"]] },
      { title: "Travel", cards: [["Steps", "1204880"], ["Distance", "386.3 mi"], ["Jumps", "18420"], ["Flight paths", "46"], ["Places discovered", "118"], ["Camps", "214"]] },
      { title: "Items and gold", cards: [["Items looted", "2447"], ["Items sold", "1432"], ["Gold earned", coin(ch.sessions.reduce((a, s) => a + s.g, 0))], ["Gold spent", coin(ch.sessions.reduce((a, s) => a + s.s, 0))], ["Repairs", "38g 12s 40c"], ["Quests", "353"]] },
    ],
    time: [["Running", f(0.218)], ["Mounted", f(0.141)], ["Standing still", f(0.402)], ["Walking", f(0.012)], ["Swimming", f(0.013)], ["Flight paths", f(0.026)], ["At camp", f(0.04)], ["Other", f(0.148)]].map(([label, seconds]) => ({ label, seconds })),
    splits: [[{ label: "In combat", seconds: f(0.121) }, { label: "Out of combat", seconds: f(0.879) }], [{ label: "In a group", seconds: 80920 }, { label: "Solo", seconds: total - 80920 }], [{ label: "Rested", seconds: f(0.183) }, { label: "Not rested", seconds: f(0.817) }], [{ label: "AFK", seconds: f(0.021) }, { label: "Active", seconds: f(0.979) }]],
  };

  const ramp = (n, max, curve) => ch.sessions.filter((_, i) => i % Math.ceil(ch.sessions.length / n) === 0).map((s, i, a) => [s.t, Math.round(max * Math.pow((i + 1) / a.length, curve))]);
  const charts = {
    xp: ramp(40, 1085926, 1.9), money: ramp(40, 1320140, 1.5),
    spells: [["Charge", 3120], ["Rend", 2874], ["Heroic Strike", 2610], ["Cleave", 2241], ["Hamstring", 1933], ["Battle Shout", 1402]],
    buffs: [["Battle Shout", 211400], ["Well Fed", 168200], ["Rested", 131800], ["Camp Fire", 28900]],
    zones: ch.levels.slice(-5).map((l) => l.zone).filter((z, i, a) => a.indexOf(z) === i).map((z, i) => [z, 98000 - i * 21000]).concat([["Hollowmere", 61200]]),
    people: ch.mates.map(([n, s]) => [n, s]),
    damage_spells: [["Heroic Strike", 2911400], ["Cleave", 2260800], ["Rend", 1604300], ["Charge", 612900]],
    healing_spells: [["Second Wind", 211300], ["Bandage", 140800], ["Healing Potion", 60660]],
    kills: [["Reed Stalker", 412], ["Rootgnaw Boar", 366], ["Vale Poacher", 301], ["Tidecaller", 244], ["Causeway Lurker", 198]],
    killers: ch.killers.slice(0, 5), cast_time: [["Hearthstone", 3600], ["Bandage", 2410], ["Mount", 1790]],
    emotes: [["LOL", 61], ["WAVE", 48], ["CHEER", 37], ["THANK", 29]],
    items_in: [["Stalker Hide", 312], ["Cracked Fang", 244], ["Boar Meat", 198], ["Linen Cloth", 161]], items_out: [["Cracked Fang", 244], ["Stalker Hide", 120], ["Rough Whetstone", 38]],
  };
  const trends = { stats: [{ key: "Armor", series: ramp(30, 1820, 1.2) }, { key: "Max health", series: ramp(30, 2410, 1.3) }], statistics: [{ key: "1", name: "Creatures killed", series: ramp(30, 3946, 1.4) }] };
  const store = { events: 18482211, chars: [ch.name], first_ms: ch.sessions[0].t, last_ms: ch.sessions[ch.sessions.length - 1].t };
  return { ov, eta, name: ch.name, heat, stats, charts, trends, store };
});
await scratch.context().close();

// 2. The app's own files, served from the checkout under a throwaway origin, with the bridge stubbed.
const context = await browser.newContext({ viewport: { width: 1600, height: 900 }, deviceScaleFactor: 1.2 });
await context.route("https://scarlet-app.invalid/**", async (route) => {
  const url = new URL(route.request().url());
  const file = path.join(ui, decodeURIComponent(url.pathname === "/" ? "/index.html" : url.pathname));
  if (!file.startsWith(ui) || !fs.existsSync(file)) return route.fulfill({ status: 404, body: "" });
  await route.fulfill({ body: fs.readFileSync(file), contentType: TYPES[path.extname(file)] || "application/octet-stream" });
});
await context.addInitScript((d) => {
  const answers = {
    app_state: d.store, get_settings: { last_view: "overview", wow: "", data: "" }, save_view: null,
    overview: { name: d.name, ov: d.ov, eta: d.eta }, stats: d.stats, heatmap: d.heat, charts: d.charts, trends: d.trends,
  };
  window.__TAURI__ = { core: { invoke: async (cmd) => { if (!(cmd in answers)) throw new Error("not stubbed: " + cmd); return answers[cmd]; } }, event: { listen: async () => () => {} } };
}, data);

const PAGES = [["overview", "09-app-overview"], ["stats", "10-app-stats"], ["charts", "11-app-charts"]];
const failures = [];
for (const [view, name] of PAGES) {
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto("https://scarlet-app.invalid/index.html#" + view);
  await page.waitForFunction((t) => document.querySelector("#pagetitle")?.textContent === t && document.querySelector("#body")?.children.length, { overview: "Overview", stats: "Stats", charts: "Charts", heatmap: "Activity" }[view], { timeout: 10000 });
  await page.evaluate(() => document.fonts.ready);
  await page.waitForTimeout(400);
  if (errors.length) failures.push(`${name}: ${errors.join(" | ")}`);
  await page.screenshot({ path: path.join(shots, name + ".png") });
  console.log("app", name);
  await page.close();
}
await browser.close();
if (failures.length) { console.error(failures.join("\n")); process.exit(1); }
