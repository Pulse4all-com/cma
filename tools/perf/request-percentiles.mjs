#!/usr/bin/env node
/**
 * tools/perf/request-percentiles.mjs: the request log line's totalMs per route as percentiles (night N06, 5 November 2026).
 *
 * Reads the JSON that `gcloud logging read` writes (an array of log entries, or one entry per line) from stdin, keeps
 * the entries whose jsonPayload.message is "request" (web/src/instrumentation.node.ts), and prints one row per route
 * pattern: requests, p50, p75, p95, p99 and the maximum of totalMs, the share over 800 ms (the line's WARNING) and the
 * 5xx count. Routes and numbers only: never a path, an id or an identity (the log line holds none, and nothing else of
 * the entry is read). Markdown by default (paste-ready for the Decision log), JSON with --json.
 *
 *   gcloud logging read 'resource.type="cloud_run_revision" resource.labels.service_name="cma-web" jsonPayload.message="request"' \
 *     --project=p4a-cma-prod --freshness=7d --limit=200000 --format=json | node tools/perf/request-percentiles.mjs
 *
 * Options: --json (rows as JSON), --min <n> (hide routes with fewer requests; default 1), --documents (page requests
 * only: rsc false), --rsc (the client router's requests only: rsc true), --api (routes under /api/ only),
 * --pages (routes outside /api/ only), --kind <document|navigation|prefetch|api> (the line's kind, brief N07, WP1:
 * lines written before it have none and are left out). Percentiles are nearest-rank on the sorted values.
 *
 * --navigation reads the navigation beacon's lines instead (jsonPayload.message "navigation", the route
 * /api/v1/telemetry/navigation, brief N07): per route pattern and kind, the beacons, p50, p75 and p95 of the time to
 * first frame and of the time to content (beacons without content counted apart), and the share of each bucket of the
 * latest interaction's delay. Query the lines with jsonPayload.message="navigation" in place of "request".
 */
import { readFileSync } from "node:fs";

const args = process.argv.slice(2);
const flag = (name) => args.includes(name);
const option = (name, fallback) => { const i = args.indexOf(name); return i >= 0 && args[i + 1] !== undefined ? args[i + 1] : fallback; };
const asJson = flag("--json");
const min = Number(option("--min", "1"));

const text = readFileSync(0, "utf8").trim();
let entries;
try {
  entries = text.startsWith("[") ? JSON.parse(text) : text.split("\n").filter(Boolean).map((l) => JSON.parse(l));
} catch (e) {
  console.error(`request-percentiles: the input is not JSON (${e.message}); pipe gcloud logging read --format=json`);
  process.exit(2);
}

function pct(sorted, p) {
  const i = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return sorted[i];
}

const KINDS = ["document", "navigation", "prefetch", "api"];
const kind = option("--kind", null);
if (kind !== null && !KINDS.includes(kind)) {
  console.error(`request-percentiles: --kind is one of ${KINDS.join(", ")}`);
  process.exit(2);
}

if (flag("--navigation")) {
  const BUCKETS = ["none", "0-100", "100-200", "200-500", "500+"];
  const groups = new Map();
  for (const e of entries) {
    const p = e.jsonPayload ?? e;
    if (!p || p.message !== "navigation" || typeof p.firstFrameMs !== "number") continue;
    const key = `${typeof p.route === "string" ? p.route : "other"}|${typeof p.kind === "string" ? p.kind : "?"}`;
    let g = groups.get(key);
    if (!g) { g = { route: key.split("|")[0], kind: key.split("|")[1], frame: [], content: [], noContent: 0, buckets: Object.fromEntries(BUCKETS.map((b) => [b, 0])) }; groups.set(key, g); }
    g.frame.push(p.firstFrameMs);
    if (typeof p.contentMs === "number") g.content.push(p.contentMs); else g.noContent += 1;
    if (BUCKETS.includes(p.interaction)) g.buckets[p.interaction] += 1;
  }
  const stat = (xs, q) => (xs.length ? Math.round(pct(xs, q)) : null);
  const navRows = [...groups.values()].filter((g) => g.frame.length >= min).map((g) => {
    g.frame.sort((a, b) => a - b);
    g.content.sort((a, b) => a - b);
    const n = g.frame.length;
    return { route: g.route, kind: g.kind, beacons: n,
             frame_p50: stat(g.frame, 50), frame_p75: stat(g.frame, 75), frame_p95: stat(g.frame, 95),
             content_p50: stat(g.content, 50), content_p75: stat(g.content, 75), content_p95: stat(g.content, 95), without_content: g.noContent,
             interaction_pct: Object.fromEntries(BUCKETS.map((b) => [b, Math.round((g.buckets[b] / n) * 1000) / 10])) };
  }).sort((a, b) => b.beacons - a.beacons || a.route.localeCompare(b.route) || a.kind.localeCompare(b.kind));
  if (asJson) {
    console.log(JSON.stringify(navRows, null, 2));
  } else {
    const d = (x) => (x === null ? "-" : x);
    console.log(`| route | kind | beacons | first frame p50 / p75 / p95 ms | content p50 / p75 / p95 ms | without content | interaction ${BUCKETS.join(" / ")} % |`);
    console.log("|---|---|---|---|---|---|---|");
    for (const r of navRows) {
      console.log(`| \`${r.route}\` | ${r.kind} | ${r.beacons} | ${d(r.frame_p50)} / ${d(r.frame_p75)} / ${d(r.frame_p95)} | ${d(r.content_p50)} / ${d(r.content_p75)} / ${d(r.content_p95)} | ${r.without_content} | ${BUCKETS.map((b) => r.interaction_pct[b]).join(" / ")} |`);
    }
    console.log(`\n${navRows.reduce((n, r) => n + r.beacons, 0)} navigation line(s) over ${navRows.length} route and kind pair(s); ${entries.length} entries read.`);
  }
  process.exit(0);
}

const byRoute = new Map();
for (const e of entries) {
  const p = e.jsonPayload ?? e;
  if (!p || p.message !== "request" || typeof p.totalMs !== "number") continue;
  if (kind !== null && p.kind !== kind) continue;
  if (flag("--documents") && p.rsc === true) continue;
  if (flag("--rsc") && p.rsc !== true) continue;
  const route = typeof p.route === "string" ? p.route : "(no route)";
  if (flag("--api") && !route.startsWith("/api/")) continue;
  if (flag("--pages") && route.startsWith("/api/")) continue;
  let r = byRoute.get(route);
  if (!r) { r = { route, times: [], slow: 0, errors: 0 }; byRoute.set(route, r); }
  r.times.push(p.totalMs);
  if (p.totalMs > 800) r.slow += 1;
  if (Number(p.status) >= 500) r.errors += 1;
}

const rows = [...byRoute.values()]
  .filter((r) => r.times.length >= min)
  .map((r) => {
    const s = r.times.sort((a, b) => a - b);
    const round = (x) => Math.round(x);
    return { route: r.route, requests: s.length, p50: round(pct(s, 50)), p75: round(pct(s, 75)), p95: round(pct(s, 95)), p99: round(pct(s, 99)),
             max: round(s[s.length - 1]), over_800_pct: Math.round((r.slow / s.length) * 1000) / 10, errors_5xx: r.errors };
  })
  .sort((a, b) => b.requests - a.requests || a.route.localeCompare(b.route));

if (asJson) {
  console.log(JSON.stringify(rows, null, 2));
} else {
  console.log("| route | requests | p50 ms | p75 ms | p95 ms | p99 ms | max ms | over 800 ms | 5xx |");
  console.log("|---|---|---|---|---|---|---|---|---|");
  for (const r of rows) console.log(`| \`${r.route}\` | ${r.requests} | ${r.p50} | ${r.p75} | ${r.p95} | ${r.p99} | ${r.max} | ${r.over_800_pct} % | ${r.errors_5xx} |`);
  const total = rows.reduce((n, r) => n + r.requests, 0);
  console.log(`\n${total} request line(s) over ${rows.length} route(s)${min > 1 ? ` with at least ${min} requests` : ""}; ${entries.length} entries read.`);
}
