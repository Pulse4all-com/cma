#!/usr/bin/env node
// tools/fleet/build-map.mjs: builds web/src/lib/fleet-map-outlines.ts, the country outlines of Assets → Fleet management's
// map (addition 0009t; Martin, 16 November 2026, brief B37, D7), once, from Natural Earth's 1:50m admin-0 countries.
//
// Natural Earth is public domain (https://www.naturalearthdata.com/about/terms-of-use/): no API key, no tiles, no
// request from the app; the build never downloads, only this tool does, when someone runs it.
//
//   node tools/fleet/build-map.mjs                      downloads ne_50m_admin_0_countries.geojson and writes the module
//   node tools/fleet/build-map.mjs <file.geojson>       reads a downloaded copy instead (the same output)
//
// What it does, in this order (D7):
//   1. every polygon ring of every country; a ring with no point within 30°N to 75°N and 30°W to 50°E is dropped
//   2. Lambert azimuthal equal-area, centred 10°E 52°N, on the authalic sphere (R = 6371.0072 km), in km; y grows north
//      (the page flips it for SVG)
//   3. Douglas–Peucker at 1.6 km on each projected ring (closed rings keep their first and farthest point); a ring that
//      shrinks below four points is dropped
//   4. whole kilometres; one SVG path per country (per ring an absolute M, then relative l, z; y negated: SVG's y grows
//      south), keyed by its
//      ISO 3166-1 alpha-2 code (ISO_A2_EH, which holds FR and NO where ISO_A2 says -99), else its ADM0_A3, with the
//      path's box
// The module holds every country apart, never a tenant's markets: the page fills the tenant's markets (its catalog's codes)
// Background Blue and every other country light grey, so nothing tenant-specific is built in (CLAUDE.md, principle 1).
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SOURCE_URL = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_50m_admin_0_countries.geojson";
const OUT = resolve(dirname(fileURLToPath(import.meta.url)), "../../web/src/lib/fleet-map-outlines.ts");

export const PROJECTION = { lon0: 10, lat0: 52, radiusKm: 6371.0072 };
export const WINDOW = { minLat: 30, maxLat: 75, minLon: -30, maxLon: 50 };
export const TOLERANCE_KM = 1.6;

const RAD = Math.PI / 180;

/** Lambert azimuthal equal-area (spherical), centred PROJECTION: [x, y] in km, y north */
export function project(lon, lat) {
  const l0 = PROJECTION.lon0 * RAD;
  const p0 = PROJECTION.lat0 * RAD;
  const l = lon * RAD;
  const p = lat * RAD;
  const k = Math.sqrt(2 / (1 + Math.sin(p0) * Math.sin(p) + Math.cos(p0) * Math.cos(p) * Math.cos(l - l0)));
  return [PROJECTION.radiusKm * k * Math.cos(p) * Math.sin(l - l0),
    PROJECTION.radiusKm * k * (Math.cos(p0) * Math.sin(p) - Math.sin(p0) * Math.cos(p) * Math.cos(l - l0))];
}

const inWindow = ([lon, lat]) => lat >= WINDOW.minLat && lat <= WINDOW.maxLat && lon >= WINDOW.minLon && lon <= WINDOW.maxLon;

/** The distance of p from the segment a-b */
function segmentDistance(p, a, b) {
  const dx = b[0] - a[0];
  const dy = b[1] - a[1];
  const len = dx * dx + dy * dy;
  const t = len === 0 ? 0 : Math.max(0, Math.min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len));
  return Math.hypot(p[0] - (a[0] + t * dx), p[1] - (a[1] + t * dy));
}

/** Douglas–Peucker on an open polyline, iterative */
export function simplify(points, tolerance) {
  if (points.length <= 2) return points.slice();
  const keep = new Uint8Array(points.length);
  keep[0] = 1;
  keep[points.length - 1] = 1;
  const stack = [[0, points.length - 1]];
  while (stack.length > 0) {
    const [from, to] = stack.pop();
    let worst = -1;
    let at = -1;
    for (let i = from + 1; i < to; i += 1) {
      const d = segmentDistance(points[i], points[from], points[to]);
      if (d > worst) { worst = d; at = i; }
    }
    if (worst > tolerance) {
      keep[at] = 1;
      stack.push([from, at], [at, to]);
    }
  }
  return points.filter((_, i) => keep[i] === 1);
}

/** A closed ring simplified: split at its first point and the point farthest from it, each half simplified */
export function simplifyRing(ring, tolerance) {
  const pts = ring.length > 1 && ring[0][0] === ring[ring.length - 1][0] && ring[0][1] === ring[ring.length - 1][1] ? ring.slice(0, -1) : ring.slice();
  if (pts.length < 4) return pts;
  let far = 1;
  let best = -1;
  for (let i = 1; i < pts.length; i += 1) {
    const d = Math.hypot(pts[i][0] - pts[0][0], pts[i][1] - pts[0][1]);
    if (d > best) { best = d; far = i; }
  }
  const a = simplify(pts.slice(0, far + 1), tolerance);
  const b = simplify([...pts.slice(far), pts[0]], tolerance);
  return [...a.slice(0, -1), ...b.slice(0, -1)];
}

/** A country's key: its alpha-2 code where Natural Earth gives one, else its ADM0_A3 */
export function keyOf(props) {
  for (const k of [props.ISO_A2_EH, props.ISO_A2]) if (typeof k === "string" && /^[A-Z]{2}$/.test(k)) return k;
  return String(props.ADM0_A3);
}

/** A ring as compact SVG: its first point absolute, the others relative (an implicit lineto after m), closed; numbers
 * joined by a space, or by nothing before a minus sign */
export function pathOfRing(ring) {
  const nums = [];
  for (let i = 1; i < ring.length; i += 1) nums.push(ring[i][0] - ring[i - 1][0], ring[i][1] - ring[i - 1][1]);
  const join = (xs) => xs.map((n, i) => (i > 0 && n >= 0 ? " " : "") + String(n)).join("");
  return `M${join(ring[0])}l${join(nums)}z`;
}

/** The countries' outlines: per key the SVG path (km, y south) and its box [minX, minY, maxX, maxY] */
export function outlinesOf(geojson) {
  const out = new Map();
  for (const f of geojson.features) {
    const g = f.geometry;
    if (!g) continue;
    const polygons = g.type === "Polygon" ? [g.coordinates] : g.type === "MultiPolygon" ? g.coordinates : [];
    const rings = [];
    for (const poly of polygons) {
      for (const ring of poly) {
        if (!ring.some(inWindow)) continue;
        const simple = simplifyRing(ring.map(([lon, lat]) => project(lon, lat)), TOLERANCE_KM)
          .map(([x, y]) => [Math.round(x), -Math.round(y)]);
        // consecutive duplicates after rounding go; a ring below four points is too small to draw at this scale
        const pts = simple.filter((p, i) => i === 0 || p[0] !== simple[i - 1][0] || p[1] !== simple[i - 1][1]);
        if (pts.length >= 4) rings.push(pts);
      }
    }
    if (rings.length === 0) continue;
    const key = keyOf(f.properties);
    const prev = out.get(key) ?? { rings: [] };
    prev.rings.push(...rings);
    out.set(key, prev);
  }
  const result = {};
  for (const key of [...out.keys()].sort()) {
    const { rings } = out.get(key);
    let minX = Infinity; let minY = Infinity; let maxX = -Infinity; let maxY = -Infinity;
    for (const r of rings) for (const [x, y] of r) { minX = Math.min(minX, x); minY = Math.min(minY, y); maxX = Math.max(maxX, x); maxY = Math.max(maxY, y); }
    const d = rings.map(pathOfRing).join("");
    result[key] = { d, box: [minX, minY, maxX, maxY] };
  }
  return result;
}

/** The module's text */
export function moduleOf(outlines, sha256) {
  const lines = Object.entries(outlines).map(([k, v]) => `  ${JSON.stringify(k)}: { d: ${JSON.stringify(v.d)}, box: [${v.box.join(", ")}] },`);
  return `// GENERATED by tools/fleet/build-map.mjs: do not edit by hand; run the tool again instead.
// Source: Natural Earth, 1:50m Cultural Vectors, Admin 0 – Countries (ne_50m_admin_0_countries.geojson,
// ${SOURCE_URL}); the file read had SHA-256 ${sha256}, so a later run can be checked against it.
// Licence: public domain (Natural Earth, https://www.naturalearthdata.com/about/terms-of-use/). Made with Natural Earth.
// Projection: Lambert azimuthal equal-area, centred ${PROJECTION.lon0}°E ${PROJECTION.lat0}°N, sphere of ${PROJECTION.radiusKm} km; kilometres,
// y growing south (SVG). Douglas–Peucker ${TOLERANCE_KM} km; rings with no point within ${WINDOW.minLat}–${WINDOW.maxLat}°N, ${-WINDOW.minLon}°W–${WINDOW.maxLon}°E dropped.
// One path per country (ISO 3166-1 alpha-2, else ADM0_A3) with its box [minX, minY, maxX, maxY]. Assets → Fleet management
// (addition 0009t, brief B37, D7): the page fills the tenant's markets and the other land from these; no tile, no request.

/** The projection the outlines are in: the page projects a postcode area's centre the same way (lib/fleet-management) */
export const FLEET_MAP_PROJECTION = { lon0: ${PROJECTION.lon0}, lat0: ${PROJECTION.lat0}, radiusKm: ${PROJECTION.radiusKm} } as const;

/** Per country: its outline as an SVG path in km (y south) and the path's box */
export const FLEET_MAP_COUNTRIES: Readonly<Record<string, { d: string; box: readonly [number, number, number, number] }>> = {
${lines.join("\n")}
};
`;
}

async function main() {
  const arg = process.argv[2];
  const text = arg ? readFileSync(arg, "utf8") : await (await fetch(SOURCE_URL)).text();
  const outlines = outlinesOf(JSON.parse(text));
  const mod = moduleOf(outlines, createHash("sha256").update(text).digest("hex"));
  writeFileSync(OUT, mod);
  console.log(`fleet-map-outlines.ts: ${Object.keys(outlines).length} countries, ${(Buffer.byteLength(mod) / 1024).toFixed(1)} kB`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((e) => { console.error(e); process.exit(1); });
}
