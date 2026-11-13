/**
 * verify/perf.mjs: the Workspace's speed, measured (night N06, 5 November 2026).
 *
 * Two measurements against the budgets of verify/perf.json:
 *   1. Server time to first byte and time to last byte per route and subject: 30 requests after a warm-up of 3,
 *      sequential, p50 and p95 in milliseconds, each route in its class (poll, agent, report) with the class's budget.
 *      Every page route has a loading boundary since night N06, so its first byte is the skeleton and arrives in a few
 *      milliseconds whatever the reads cost; the last byte is when the streamed page is complete, and both are held to
 *      the class's budget (the first byte is the click's feedback, the last byte the page). The budgets are the targets
 *      of the Decision log of 5 November 2026 scaled by perf.json's container_factor: the container's database is on
 *      loopback and its CPU is not Cloud Run's, so a route that misses here is slow for sure, and one that passes is not
 *      yet proven in prod (the request log line's totalMs is; MORNING_RUNBOOK step 0).
 *   2. The client JavaScript per page route (first load, gzip-compressed): the chunks the route's client reference
 *      manifest names (.next/server/app/<route>/page_client-reference-manifest.js) plus the root main files of
 *      .next/build-manifest.json, each chunk read from .next/static and compressed; and the page's HTML (the RSC payload
 *      with the copy object rides in it), gzip-compressed, from the measured response. Both against perf.json's per-route
 *      budgets in kB (night N06's measured values, rounded up; a route that still carries the whole copy object has minus
 *      25 % as its next target, docs/night-2026-11-06/NIGHT_NOTES.md). A request row may carry its own html_kb, which wins
 *      over the route's: Assets → Installed base's default view and each panel (addition 0009f).
 *   3. The layers of a page that streams in parts (a row's layers; Customers → Active, addition 0009l, decisions D15 and
 *      D16): when each layer's mark first arrives in the stream, the 95th percentile against the layer's budget in
 *      milliseconds (measured on the three-times fixture and rounded up, inside the decisions' targets of 200, 400, 500,
 *      300 and 400 ms; not scaled by the container factor). They time the bytes on the wire: what the browser paints
 *      follows React's own rule (a part is shown no sooner than about 300 ms after the outline it replaces), which
 *      verify:layout sees in a browser.
 * Needs the standalone build and a running app in api data mode with mock sign-in (CMA_AUTH_MODE=mock CMA_DATA_MODE=api,
 * the local database with verify/perf-volume-fixture.sql loaded for a figure that means something):
 *
 *   BASE=http://localhost:8080 node verify/perf.mjs              expect PASS
 *   BASE=http://localhost:8080 node verify/perf.mjs --provoke    every budget is 0: expect FAIL
 *   BASE=http://localhost:8080 node verify/perf.mjs --observed   prints the observed figures as JSON (to write a baseline)
 *   REQUESTS=10 ...                                              fewer requests per route (a quick look; the verdict uses 30)
 * It sits with verify:api (a server and a database), not with the pure verifiers. Ids, routes and numbers only.
 */
import { readFileSync, existsSync } from "node:fs";
import { gzipSync } from "node:zlib";
import path from "node:path";

const BASE = process.env.BASE ?? "http://localhost:8080";
const provoke = process.argv.includes("--provoke");
const observedOnly = process.argv.includes("--observed");
const REQUESTS = Number(process.env.REQUESTS ?? 30);
const WARMUP = 3;
const here = path.dirname(new URL(import.meta.url).pathname);
const root = path.join(here, "..");
const budget = JSON.parse(readFileSync(path.join(here, "perf.json"), "utf8"));
const factor = budget.container_factor;

function percentile(sorted, p) {
  if (sorted.length === 0) return NaN;
  const i = Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1);
  return sorted[Math.max(0, i)];
}
const kb = (bytes) => Math.round((bytes / 1024) * 10) / 10;

/** The client JavaScript of a page route, gzip-compressed, from the build's manifests; null when the build lacks the route */
function routeJs(route) {
  const dir = path.join(root, ".next", "server", "app", route === "/" ? "" : route);
  const file = path.join(dir, "page_client-reference-manifest.js");
  if (!existsSync(file)) return null;
  const text = readFileSync(file, "utf8");
  const start = text.indexOf("= {");
  const manifest = JSON.parse(text.slice(start + 2, text.lastIndexOf("}") + 1));
  const chunks = new Set();
  for (const mod of Object.values(manifest.clientModules ?? {})) for (const c of mod.chunks ?? []) chunks.add(c.replace(/^\/_next\//, ""));
  const build = JSON.parse(readFileSync(path.join(root, ".next", "build-manifest.json"), "utf8"));
  for (const f of build.rootMainFiles ?? []) chunks.add(f);
  let bytes = 0;
  for (const c of chunks) {
    const p = path.join(root, ".next", c);
    if (!existsSync(p)) continue;
    bytes += gzipSync(readFileSync(p)).length;
  }
  return { chunks: chunks.size, gzipBytes: bytes };
}

const problems = [];
const observed = [];
for (const row of budget.requests) {
  const times = [];
  const totals = [];
  const layerTimes = {};
  let htmlGzip = null;
  let status = 0;
  for (let i = 0; i < WARMUP + REQUESTS; i++) {
    const t0 = performance.now();
    const res = await fetch(BASE + row.path, { headers: { "x-cma-mock-subject": row.subject, accept: "text/html,application/json" }, redirect: "manual" });
    // time to first byte: the headers are in; the body is then read in full so the server finishes streaming before the next request
    const ttfb = performance.now() - t0;
    // a row with layers (a page that streams in parts, Customers → Active: decisions D15 and D16) is read as it arrives,
    // and the moment each layer's mark is first in the stream is kept
    const parts = [];
    const seen = {};
    let text = "";
    const dec = new TextDecoder();
    for await (const chunk of res.body ?? []) {
      parts.push(Buffer.from(chunk));
      if (row.layers) {
        text += dec.decode(chunk, { stream: true });
        for (const [name, layer] of Object.entries(row.layers)) if (seen[name] === undefined && text.includes(layer.mark)) seen[name] = performance.now() - t0;
      }
    }
    const body = Buffer.concat(parts);
    const total = performance.now() - t0;
    status = res.status;
    if (i >= WARMUP) {
      times.push(ttfb); totals.push(total);
      if (row.layers) for (const name of Object.keys(row.layers)) (layerTimes[name] ??= []).push(seen[name] ?? Infinity);
    }
    if (htmlGzip === null && (res.headers.get("content-type") ?? "").includes("text/html")) htmlGzip = gzipSync(body).length;
  }
  if (status !== 200) { problems.push(`${row.subject} ${row.path}: status ${status}`); continue; }
  times.sort((a, b) => a - b);
  totals.sort((a, b) => a - b);
  const p50 = Math.round(percentile(times, 50) * 10) / 10;
  const p95 = Math.round(percentile(times, 95) * 10) / 10;
  const done50 = Math.round(percentile(totals, 50) * 10) / 10;
  const done95 = Math.round(percentile(totals, 95) * 10) / 10;
  const cls = budget.classes[row.class];
  const maxP50 = provoke ? 0 : cls.p50 * factor;
  const maxP95 = provoke ? 0 : cls.p95 * factor;
  // A dynamic route names its build directory in the row (route: "/live/[org]", addition 0008zv); a static one is its path
  const js = row.path.startsWith("/api/") ? null : routeJs(row.route ?? row.path.replace(/\?.*$/, ""));
  const o = { path: row.path, subject: row.subject, class: row.class, p50, p95, done_p50: done50, done_p95: done95, requests: times.length,
              html_kb: htmlGzip === null ? null : kb(htmlGzip), js_kb: js ? kb(js.gzipBytes) : null, js_chunks: js?.chunks ?? null };
  // the layers of a streamed page: the 95th percentile of each mark's arrival against the row's own budget in milliseconds
  // (the targets of the decisions that set the layers, on the local three-times fixture: not scaled by the container factor)
  if (row.layers) {
    o.layers = {};
    for (const [name, layer] of Object.entries(row.layers)) {
      const sorted = (layerTimes[name] ?? []).slice().sort((a, b) => a - b);
      const l95 = Math.round(percentile(sorted, 95) * 10) / 10;
      const l50 = Math.round(percentile(sorted, 50) * 10) / 10;
      o.layers[name] = Number.isFinite(l95) ? l95 : null;
      (o.layers_p50 ??= {})[name] = Number.isFinite(l50) ? l50 : null;
      const max = provoke ? 0 : layer.p95;
      if (!Number.isFinite(l95)) problems.push(`${row.subject} ${row.path}: layer ${name} (${layer.mark}) did not arrive in the stream`);
      else if (l95 > max) problems.push(`${row.subject} ${row.path}: layer ${name} arrives at p95 ${l95} ms, budget ${max} ms`);
    }
  }
  observed.push(o);
  if (p50 > maxP50) problems.push(`${row.subject} ${row.path}: p50 ${p50} ms, budget ${maxP50} ms (${row.class} ${cls.p50} × ${factor})`);
  if (p95 > maxP95) problems.push(`${row.subject} ${row.path}: p95 ${p95} ms, budget ${maxP95} ms (${row.class} ${cls.p95} × ${factor})`);
  // a row with layers holds each layer to its own budget (its last byte is its last layer), so the class's last-byte
  // budget is not asked of it a second time
  if (!row.layers) {
    if (done50 > maxP50) problems.push(`${row.subject} ${row.path}: last byte p50 ${done50} ms, budget ${maxP50} ms (${row.class} ${cls.p50} × ${factor})`);
    if (done95 > maxP95) problems.push(`${row.subject} ${row.path}: last byte p95 ${done95} ms, budget ${maxP95} ms (${row.class} ${cls.p95} × ${factor})`);
  }
  // a row's own HTML budget wins over the route's (addition 0009f: Assets → Installed base's default view and each of its
  // panels are rows of one route; a panel weighs more than the default view and has its own budget)
  const key = row.path.replace(/\?.*$/, "");
  const htmlBudget = row.html_kb ?? budget.html_kb[key];
  if (o.html_kb !== null && htmlBudget !== undefined) {
    const max = provoke ? 0 : htmlBudget;
    if (o.html_kb > max) problems.push(`${row.subject} ${row.path}: HTML ${o.html_kb} kB gzip, budget ${max} kB`);
  }
  if (o.js_kb !== null && budget.js_kb[key] !== undefined) {
    const max = provoke ? 0 : budget.js_kb[key];
    if (o.js_kb > max) problems.push(`${row.subject} ${row.path}: client JavaScript ${o.js_kb} kB gzip, budget ${max} kB`);
  }
}

if (observedOnly) {
  console.log(JSON.stringify(observed, null, 2));
  process.exit(0);
}
console.log(`route (subject): first byte p50 / p95 ms, last byte p50 / p95 ms, HTML kB, JS kB`);
for (const o of observed) {
  console.log(`  ${o.path} (${o.subject}): ${o.p50} / ${o.p95} ms, ${o.done_p50} / ${o.done_p95} ms, ${o.html_kb ?? "-"} kB, ${o.js_kb ?? "-"} kB`
    + (o.layers ? `; layers p50 / p95 ${Object.entries(o.layers).map(([k, v]) => `${k} ${o.layers_p50?.[k] ?? "-"} / ${v ?? "-"} ms`).join(", ")}` : ""));
}
if (problems.length) {
  for (const p of problems) console.log("  " + p);
  console.log(`perf: FAIL (${problems.length} problems, ${REQUESTS} requests per route, container factor ${factor})`);
  process.exit(1);
}
console.log(`perf: PASS (${budget.requests.length} routes within their time, HTML and JavaScript budgets; ${REQUESTS} requests per route, container factor ${factor})`);
