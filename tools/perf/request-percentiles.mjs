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
 * --pages (routes outside /api/ only). Percentiles are nearest-rank on the sorted values.
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

const byRoute = new Map();
for (const e of entries) {
  const p = e.jsonPayload ?? e;
  if (!p || p.message !== "request" || typeof p.totalMs !== "number") continue;
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

function pct(sorted, p) {
  const i = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return sorted[i];
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
