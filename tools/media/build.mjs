#!/usr/bin/env node
// build.mjs <sc.js> [--out DIR] [--preview DIR]: renders addon/Scarlet/Media/Plates.tga, Tick.tga, Glow.tga and
// Glyphs.tga (white on alpha, 32-bit, uncompressed, bottom-left origin) from the shapes in the design's sc.js, which
// the app and the site draw with too. Node only, no packages. Run it again after a shape changes.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { deflateSync } from "node:zlib";

const here = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const flag = (name) => {
  const i = args.indexOf(name);
  return i < 0 ? null : args.splice(i, 2)[1];
};
const outDir = resolve(flag("--out") ?? join(here, "../../addon/Scarlet/Media"));
const previewDir = flag("--preview");
const scPath = args[0];
if (!scPath) {
  console.error("usage: node tools/media/build.mjs <design/final/src/shared/sc.js> [--out DIR] [--preview DIR]");
  process.exit(2);
}

const FAMILIES = ["journey", "combat", "quests", "dungeons", "world", "trade", "class", "role"];
const GLYPH_ORDER = [
  "characters", "level", "hours", "kills", "deaths", "quests", "dungeons", "gold",
  "zones", "distance", "skills", "fish", "gather", "jumps", "swim", "emote",
  "crown", "shield", "clock", "pin", "creature", "item", "talents", "spell",
  "pet", "heal", "fire", "wing", "link", "arrow", "lock", "check",
];
const PLATE_CELL = 128;
const GLYPH_CELL = 64;
const GLYPH_STROKE = 1.8;
const SUBSCANS = 8;
const CURVE_STEPS = 20;

const source = readFileSync(scPath, "utf8");
const between = (from, to) => {
  const a = source.indexOf(from);
  const b = source.indexOf(to, a);
  if (a < 0 || b < 0) throw new Error(`${scPath}: no block from "${from}" to "${to}"`);
  return source.slice(a, b);
};
const GLYPHS = new Function(`${between("const GLYPHS = {", "const METAL")}; return GLYPHS;`)();
const PLATES = new Function(`${between("const poly =", "const PLATE_SHIFT")}; return PLATES;`)();

const num = (n) => Number.parseFloat(n);

function* scanPath(d) {
  let i = 0;
  const skip = () => {
    while (i < d.length && /[\s,]/.test(d[i])) i++;
  };
  const number = () => {
    skip();
    const m = /^[-+]?(?:\d+\.?\d*|\.\d+)(?:e[-+]?\d+)?/i.exec(d.slice(i));
    if (!m) throw new Error(`bad number at ${i} in ${d}`);
    i += m[0].length;
    return num(m[0]);
  };
  const flagBit = () => {
    skip();
    const c = d[i++];
    if (c !== "0" && c !== "1") throw new Error(`bad arc flag in ${d}`);
    return c === "1" ? 1 : 0;
  };
  while (true) {
    skip();
    if (i >= d.length) return;
    const cmd = d[i++];
    const count = { M: 2, L: 2, H: 1, V: 1, C: 6, S: 4, Q: 4, T: 2, A: 7, Z: 0 }[cmd.toUpperCase()];
    if (count === undefined) throw new Error(`unknown command ${cmd} in ${d}`);
    if (count === 0) {
      yield [cmd];
      continue;
    }
    let first = true;
    while (true) {
      skip();
      if (i >= d.length || /[A-Za-z]/.test(d[i])) break;
      const params = [];
      for (let k = 0; k < count; k++) params.push(cmd.toUpperCase() === "A" && (k === 3 || k === 4) ? flagBit() : number());
      let c = cmd;
      if (!first && cmd === "M") c = "L";
      if (!first && cmd === "m") c = "l";
      yield [c, ...params];
      first = false;
    }
  }
}

function arcPoints(x0, y0, rx, ry, rotation, large, sweep, x, y) {
  if (rx === 0 || ry === 0) return [[x, y]];
  const phi = (rotation * Math.PI) / 180;
  const cos = Math.cos(phi);
  const sin = Math.sin(phi);
  const dx = (x0 - x) / 2;
  const dy = (y0 - y) / 2;
  const x1 = cos * dx + sin * dy;
  const y1 = -sin * dx + cos * dy;
  rx = Math.abs(rx);
  ry = Math.abs(ry);
  const lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry);
  if (lambda > 1) {
    rx *= Math.sqrt(lambda);
    ry *= Math.sqrt(lambda);
  }
  const sign = large === sweep ? -1 : 1;
  const num2 = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1;
  const den = rx * rx * y1 * y1 + ry * ry * x1 * x1;
  const coef = sign * Math.sqrt(Math.max(0, num2 / den));
  const cxp = (coef * rx * y1) / ry;
  const cyp = (-coef * ry * x1) / rx;
  const cx = cos * cxp - sin * cyp + (x0 + x) / 2;
  const cy = sin * cxp + cos * cyp + (y0 + y) / 2;
  const angle = (ux, uy, vx, vy) => Math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
  const theta = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry);
  let delta = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry);
  if (!sweep && delta > 0) delta -= 2 * Math.PI;
  if (sweep && delta < 0) delta += 2 * Math.PI;
  const steps = Math.max(4, Math.ceil(Math.abs(delta) / (Math.PI / 24)));
  const out = [];
  for (let k = 1; k <= steps; k++) {
    const t = theta + (delta * k) / steps;
    out.push([cx + rx * Math.cos(t) * cos - ry * Math.sin(t) * sin, cy + rx * Math.cos(t) * sin + ry * Math.sin(t) * cos]);
  }
  out[out.length - 1] = [x, y];
  return out;
}

function flattenPath(d) {
  const subpaths = [];
  let cur = null;
  let x = 0;
  let y = 0;
  let sx = 0;
  let sy = 0;
  let lastCtrl = null;
  const start = (px, py) => {
    cur = { pts: [[px, py]], closed: false };
    subpaths.push(cur);
    x = sx = px;
    y = sy = py;
  };
  const cubic = (x1, y1, x2, y2, px, py) => {
    for (let k = 1; k <= CURVE_STEPS; k++) {
      const t = k / CURVE_STEPS;
      const u = 1 - t;
      cur.pts.push([
        u * u * u * x + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * px,
        u * u * u * y + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * py,
      ]);
    }
    lastCtrl = [x2, y2];
    x = px;
    y = py;
  };
  for (const [c, ...p] of scanPath(d)) {
    const rel = c === c.toLowerCase();
    const ox = rel ? x : 0;
    const oy = rel ? y : 0;
    switch (c.toUpperCase()) {
      case "M":
        start(p[0] + ox, p[1] + oy);
        lastCtrl = null;
        break;
      case "L":
        if (!cur) start(x, y);
        x = p[0] + ox;
        y = p[1] + oy;
        cur.pts.push([x, y]);
        lastCtrl = null;
        break;
      case "H":
        x = p[0] + ox;
        cur.pts.push([x, y]);
        lastCtrl = null;
        break;
      case "V":
        y = p[0] + oy;
        cur.pts.push([x, y]);
        lastCtrl = null;
        break;
      case "C":
        cubic(p[0] + ox, p[1] + oy, p[2] + ox, p[3] + oy, p[4] + ox, p[5] + oy);
        break;
      case "S": {
        const c1 = lastCtrl ? [2 * x - lastCtrl[0], 2 * y - lastCtrl[1]] : [x, y];
        cubic(c1[0], c1[1], p[0] + ox, p[1] + oy, p[2] + ox, p[3] + oy);
        break;
      }
      case "Q": {
        const x1 = p[0] + ox;
        const y1 = p[1] + oy;
        const px = p[2] + ox;
        const py = p[3] + oy;
        cubic(x + (2 / 3) * (x1 - x), y + (2 / 3) * (y1 - y), px + (2 / 3) * (x1 - px), py + (2 / 3) * (y1 - py), px, py);
        break;
      }
      case "A": {
        const pts = arcPoints(x, y, p[0], p[1], p[2], p[3], p[4], p[5] + ox, p[6] + oy);
        for (const q of pts) cur.pts.push(q);
        x = p[5] + ox;
        y = p[6] + oy;
        lastCtrl = null;
        break;
      }
      case "Z":
        cur.closed = true;
        x = sx;
        y = sy;
        lastCtrl = null;
        break;
      default:
        throw new Error(`unsupported command ${c}`);
    }
  }
  return subpaths;
}

function circlePath(cx, cy, r) {
  const pts = [];
  for (let k = 0; k < 48; k++) {
    const a = (k / 48) * Math.PI * 2;
    pts.push([cx + Math.cos(a) * r, cy + Math.sin(a) * r]);
  }
  return { pts, closed: true };
}

function rectPath(x, y, w, h, rx) {
  rx = Math.min(rx, w / 2, h / 2);
  if (!rx) return { pts: [[x, y], [x + w, y], [x + w, y + h], [x, y + h]], closed: true };
  const pts = [];
  const corner = (cx, cy, from) => {
    for (let k = 0; k <= 8; k++) {
      const a = from + (k / 8) * (Math.PI / 2);
      pts.push([cx + Math.cos(a) * rx, cy + Math.sin(a) * rx]);
    }
  };
  corner(x + w - rx, y + rx, -Math.PI / 2);
  corner(x + w - rx, y + h - rx, 0);
  corner(x + rx, y + h - rx, Math.PI / 2);
  corner(x + rx, y + rx, Math.PI);
  return { pts, closed: true };
}

function shapesOf(fragment) {
  const out = [];
  for (const m of fragment.matchAll(/<(path|circle|rect)\b([^>]*?)\/?>/g)) {
    const attr = (name, fallback) => {
      const a = new RegExp(`\\b${name}="([^"]*)"`).exec(m[2]);
      return a ? a[1] : fallback;
    };
    if (m[1] === "path") out.push(...flattenPath(attr("d")));
    else if (m[1] === "circle") out.push(circlePath(num(attr("cx", "0")), num(attr("cy", "0")), num(attr("r"))));
    else out.push(rectPath(num(attr("x", "0")), num(attr("y", "0")), num(attr("width")), num(attr("height")), num(attr("rx", "0"))));
  }
  return out;
}

function capsule(p, q, r) {
  const dx = q[0] - p[0];
  const dy = q[1] - p[1];
  const len = Math.hypot(dx, dy);
  const ux = len ? dx / len : 1;
  const uy = len ? dy / len : 0;
  const pts = [];
  const arc = (c, from) => {
    for (let k = 0; k <= 12; k++) {
      const a = from - (k / 12) * Math.PI;
      pts.push([c[0] + (Math.cos(a) * ux - Math.sin(a) * uy) * r, c[1] + (Math.cos(a) * uy + Math.sin(a) * ux) * r]);
    }
  };
  arc(q, Math.PI / 2);
  arc(p, -Math.PI / 2);
  return pts;
}

function strokePolys(subpaths, width) {
  const r = width / 2;
  const polys = [];
  for (const sp of subpaths) {
    const pts = sp.closed ? [...sp.pts, sp.pts[0]] : sp.pts;
    if (pts.length === 1) polys.push(capsule(pts[0], pts[0], r));
    for (let k = 1; k < pts.length; k++) polys.push(capsule(pts[k - 1], pts[k], r));
  }
  return polys;
}

function rasterize(polys, w, h) {
  const cov = new Float32Array(w * h);
  const edges = [];
  for (const poly of polys) {
    for (let k = 0; k < poly.length; k++) {
      const a = poly[k];
      const b = poly[(k + 1) % poly.length];
      if (a[1] === b[1]) continue;
      edges.push(a[1] < b[1] ? { x0: a[0], y0: a[1], x1: b[0], y1: b[1], dir: 1 } : { x0: b[0], y0: b[1], x1: a[0], y1: a[1], dir: -1 });
    }
  }
  edges.sort((a, b) => a.y0 - b.y0);
  for (let sy = 0; sy < h * SUBSCANS; sy++) {
    const y = (sy + 0.5) / SUBSCANS;
    const hits = [];
    for (const e of edges) {
      if (e.y0 > y) break;
      if (y < e.y1) hits.push([e.x0 + ((y - e.y0) / (e.y1 - e.y0)) * (e.x1 - e.x0), e.dir]);
    }
    if (hits.length < 2) continue;
    hits.sort((a, b) => a[0] - b[0]);
    const row = Math.floor(sy / SUBSCANS) * w;
    let wind = 0;
    for (let k = 0; k < hits.length - 1; k++) {
      wind += hits[k][1];
      if (wind === 0) continue;
      const xa = Math.max(0, hits[k][0]);
      const xb = Math.min(w, hits[k + 1][0]);
      for (let px = Math.floor(xa); px < Math.ceil(xb); px++) {
        cov[row + px] += (Math.min(xb, px + 1) - Math.max(xa, px)) / SUBSCANS;
      }
    }
  }
  for (let k = 0; k < cov.length; k++) cov[k] = Math.min(1, cov[k]);
  return cov;
}

const transform = (polys, scale, dx, dy) => polys.map((poly) => poly.map(([x, y]) => [x * scale + dx, y * scale + dy]));

function image(w, h) {
  return { w, h, a: new Float32Array(w * h) };
}

function blit(img, cov, cw, ch, ox, oy) {
  for (let y = 0; y < ch; y++) for (let x = 0; x < cw; x++) img.a[(oy + y) * img.w + ox + x] = cov[y * cw + x];
}

function plates() {
  const img = image(PLATE_CELL * FAMILIES.length, PLATE_CELL);
  FAMILIES.forEach((family, i) => {
    const fill = flattenPath(PLATES[family]).map((sp) => sp.pts);
    const scale = PLATE_CELL / 64;
    blit(img, rasterize(transform(fill, scale, 0, 0), PLATE_CELL, PLATE_CELL), PLATE_CELL, PLATE_CELL, i * PLATE_CELL, 0);
  });
  return img;
}

function glyphs() {
  const columns = 8;
  const img = image(GLYPH_CELL * columns, GLYPH_CELL * (GLYPH_ORDER.length / columns));
  const scale = GLYPH_CELL / 24;
  GLYPH_ORDER.forEach((name, i) => {
    if (!GLYPHS[name]) throw new Error(`sc.js has no glyph ${name}`);
    const polys = strokePolys(shapesOf(GLYPHS[name]), GLYPH_STROKE);
    blit(img, rasterize(transform(polys, scale, 0, 0), GLYPH_CELL, GLYPH_CELL), GLYPH_CELL, GLYPH_CELL, (i % columns) * GLYPH_CELL, Math.floor(i / columns) * GLYPH_CELL);
  });
  return img;
}

function distanceToSegment(px, py, ax, ay, bx, by) {
  const dx = bx - ax;
  const dy = by - ay;
  const t = Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)));
  return Math.hypot(px - (ax + t * dx), py - (ay + t * dy));
}

function tick() {
  const img = image(8, 32);
  for (let y = 0; y < 32; y++) {
    for (let x = 0; x < 8; x++) {
      const d = distanceToSegment(x + 0.5, y + 0.5, 4, 5, 4, 27);
      img.a[y * 8 + x] = Math.max(0, Math.min(1, (2.1 - d) / 1.6));
    }
  }
  return img;
}

function glow() {
  const size = 256;
  const img = image(size, size);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const r = Math.min(1, Math.hypot(x + 0.5 - size / 2, y + 0.5 - size / 2) / (size / 2));
      const s = r * r * (3 - 2 * r);
      img.a[y * size + x] = (1 - s) ** 1.6;
    }
  }
  return img;
}

function tga(img) {
  const out = Buffer.alloc(18 + img.w * img.h * 4);
  out[2] = 2;
  out.writeUInt16LE(img.w, 12);
  out.writeUInt16LE(img.h, 14);
  out[16] = 32;
  out[17] = 8;
  let o = 18;
  for (let y = img.h - 1; y >= 0; y--) {
    for (let x = 0; x < img.w; x++) {
      out[o++] = 255;
      out[o++] = 255;
      out[o++] = 255;
      out[o++] = Math.round(img.a[y * img.w + x] * 255);
    }
  }
  return out;
}

const crcTable = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
const crc32 = (buf) => {
  let c = 0xffffffff;
  for (const b of buf) c = crcTable[(c ^ b) & 255] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
};
const chunk = (type, data) => {
  const body = Buffer.concat([Buffer.from(type), data]);
  const out = Buffer.alloc(body.length + 8);
  out.writeUInt32BE(data.length, 0);
  body.copy(out, 4);
  out.writeUInt32BE(crc32(body), body.length + 4);
  return out;
};

function png(img, scale) {
  const w = img.w * scale;
  const h = img.h * scale;
  const raw = Buffer.alloc((w * 3 + 1) * h);
  const bg = [0x14, 0x14, 0x16];
  for (let y = 0; y < h; y++) {
    raw[y * (w * 3 + 1)] = 0;
    for (let x = 0; x < w; x++) {
      const a = img.a[Math.floor(y / scale) * img.w + Math.floor(x / scale)];
      for (let c = 0; c < 3; c++) raw[y * (w * 3 + 1) + 1 + x * 3 + c] = Math.round(bg[c] + (255 - bg[c]) * a);
    }
  }
  const head = Buffer.alloc(13);
  head.writeUInt32BE(w, 0);
  head.writeUInt32BE(h, 4);
  head[8] = 8;
  head[9] = 2;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", head), chunk("IDAT", deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]);
}

const files = { Plates: plates(), Tick: tick(), Glow: glow(), Glyphs: glyphs() };
mkdirSync(outDir, { recursive: true });
if (previewDir) mkdirSync(previewDir, { recursive: true });
for (const [name, img] of Object.entries(files)) {
  const bytes = tga(img);
  writeFileSync(join(outDir, `${name}.tga`), bytes);
  console.log(`${name}.tga ${img.w}x${img.h} 32-bit uncompressed TGA, ${bytes.length} bytes`);
  if (previewDir) writeFileSync(join(previewDir, `${name}.png`), png(img, name === "Tick" ? 8 : 1));
}
