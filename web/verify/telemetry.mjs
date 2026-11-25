/**
 * verify/telemetry.mjs: the telemetry of brief N07, WP1 (src/lib/telemetry.ts, src/instrumentation.node.ts,
 * src/app/api/v1/telemetry/navigation/route.ts, src/components/NavigationBeacon.tsx, tools/perf/request-percentiles.mjs).
 * Pure: no server, no database, unless BASE names a running app in mock mode, when the route and the Server-Timing header
 * are also checked over HTTP.
 *
 *   npm run verify:telemetry                  expect ALL n PASS
 *   npm run verify:telemetry -- --provoke     every check runs against a broken copy (an accepting parser, a pattern
 *                                             that keeps the path, a kind without prefetch, a log line with a path, the
 *                                             route's guards taken out of its source) and must fail
 *   BASE=http://localhost:8082 npm run verify:telemetry   the HTTP checks as well
 *
 * What it proves: a request's kind (document, navigation, prefetch, api) from the route, the RSC mark and the prefetch
 * mark; every page of the navigation model is a beacon route, a Live board is its pattern and never its key, any other
 * path (a journey, an id, a query) is "other"; the beacon's body is exact (every key, no other, routes from the list,
 * whole milliseconds within 0 to 120,000, content null or milliseconds, a known bucket) and at most 1 kB; the log line
 * holds the message "navigation" and the beacon's fields only; the Server-Timing value names db and total only; the
 * route reads the identity without a database read, refuses a cross-site request and a body over 1 kB, stores nothing
 * and answers 204; the request log line carries kind; a prefetch is marked from its request header; the browser sends the pattern, never
 * the path; request-percentiles.mjs filters by --kind and summarises --navigation.
 */
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import * as real from "../src/lib/telemetry.ts";

const PROVOKE = process.argv.includes("--provoke");
const BASE = process.env.BASE ?? null;
let n = 0, passed = 0;
function check(name, ok, detail = "") {
  n += 1;
  if (ok) passed += 1;
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${ok ? "" : detail ? `  (${detail})` : ""}`);
}
const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

// The implementation under test: the real one, or under --provoke a broken copy of each rule
const t = PROVOKE ? {
  ...real,
  requestKindOf: (r) => (r.route?.startsWith("/api/") ? "api" : r.rsc ? "navigation" : "document"),
  routePatternOf: () => "other",
  // accepts what it should refuse (any key, any value, any size) and refuses what it should accept (no content, a document)
  parseNavigationBeacon: (text) => {
    const o = JSON.parse(text);
    if (o.contentMs === null || o.kind === "document") return { ok: false, reason: "invalid" };
    return { ok: true, beacon: { ...o, seen: 1 } };
  },
  navigationLogLine: (b) => JSON.stringify({ severity: "INFO", message: "navigation", path: "/live/newco?x=1", ...b }),
  interactionBucketOf: () => "none",
  serverTimingOf: (db, total) => `db;dur=${db};desc="tenant", total;dur=${total}`,
} : real;
const breakSource = (s, ...needles) => (PROVOKE ? needles.reduce((x, k) => x.split(k).join("/*removed*/"), s) : s);

// 1. a request's kind
const kinds = [
  [{ route: "/api/v1/me", rsc: false, prefetch: false }, "api"],
  [{ route: "/api/v1/me", rsc: true, prefetch: true }, "api"],
  [{ route: "/day", rsc: false, prefetch: false }, "document"],
  [{ route: "/day", rsc: true, prefetch: false }, "navigation"],
  [{ route: "/day", rsc: true, prefetch: true }, "prefetch"],
  [{ route: null, rsc: false, prefetch: false }, "document"],
];
check("a request's kind: api under /api/, a prefetch when marked, a navigation for the router's RSC request, else a document",
  kinds.every(([r, k]) => t.requestKindOf(r) === k), kinds.map(([r]) => t.requestKindOf(r)).join(","));

// 2. the route patterns
const navSource = read("../src/lib/nav.ts");
const navHrefs = [...new Set([...navSource.matchAll(/href: "(\/[^"]*)"/g)].map((m) => m[1]))];
check(`every href of the navigation model (${navHrefs.length}) is a beacon route of its own`,
  navHrefs.length > 50 && navHrefs.every((h) => t.routePatternOf(h) === h), navHrefs.filter((h) => t.routePatternOf(h) !== h).join(" "));
const patterns = [
  ["/live/newco", "/live/[org]"], ["/live/pulse4all/", "/live/[org]"], ["/reports/flash?o=customers", "/reports/flash"],
  ["/day#top", "/day"], ["/", "/"], ["/reports/", "other"], ["/campaigns/welcome-flow", "other"],
  ["/configuration/sources/0190aa00-0000-7000-8000-000000000001", "other"], ["/invite/abc", "other"],
  ["/api/v1/me", "other"], ["/account", "/account"], ["/me/follow-up", "/me/follow-up"], ["/messages/send", "/messages/send"],
];
check("a Live board is its pattern, never its key; a query and a hash are never read; a journey, an id or any other path is other",
  patterns.every(([p, want]) => t.routePatternOf(p) === want), patterns.map(([p]) => t.routePatternOf(p)).join(" "));

// 3. the beacon's body
const good = { route: "/day", kind: "navigation", firstFrameMs: 42, contentMs: 180, interaction: "0-100" };
const body = (o) => JSON.stringify(o);
const accepted = (o) => t.parseNavigationBeacon(typeof o === "string" ? o : body(o)).ok === true;
check("a complete beacon is accepted as it is", accepted(good) && JSON.stringify(t.parseNavigationBeacon(body(good)).beacon) === JSON.stringify(good));
check("a beacon without content (contentMs null), a document and the route other are accepted",
  accepted({ ...good, contentMs: null }) && accepted({ ...good, kind: "document" }) && accepted({ ...good, route: "other" }));
const refused = [
  ["an extra key (a path)", { ...good, path: "/live/newco" }], ["an extra key (a person)", { ...good, user: "x" }],
  ["a missing key", { route: "/day", kind: "navigation", firstFrameMs: 1, contentMs: 1 }],
  ["a path for a route", { ...good, route: "/live/newco" }], ["a route with a query", { ...good, route: "/day?x=1" }],
  ["an unknown kind", { ...good, kind: "prefetch" }], ["negative milliseconds", { ...good, firstFrameMs: -1 }],
  ["fractional milliseconds", { ...good, firstFrameMs: 1.5 }], ["milliseconds over 120,000", { ...good, contentMs: 120_001 }],
  ["milliseconds as text", { ...good, firstFrameMs: "42" }], ["an unknown bucket", { ...good, interaction: "fast" }],
  ["an array", [good]], ["not JSON", "route=/day"],
];
for (const [what, o] of refused) {
  let ok;
  try { ok = !accepted(o); } catch { ok = !PROVOKE; }
  check(`a body with ${what} is refused`, ok);
}
const padded = body({ ...good, route: "other" }).replace("}", `${" ".repeat(1100)}}`);
const big = (() => { try { return t.parseNavigationBeacon(padded); } catch { return { ok: true }; } })();
check("a body over 1 kB is refused as too large, even when its beacon is valid", big.ok === false && big.reason === "too_large");

// 4. the log line and the buckets
const line = JSON.parse(t.navigationLogLine(good));
check("the log line holds message navigation and the beacon's fields only",
  line.message === "navigation" && JSON.stringify(Object.keys(line).sort()) === JSON.stringify(["contentMs", "firstFrameMs", "interaction", "kind", "message", "route", "severity"]),
  Object.keys(line).join(","));
const buckets = [[null, "none"], [undefined, "none"], [-5, "none"], [0, "0-100"], [99.9, "0-100"], [100, "100-200"], [199, "100-200"], [200, "200-500"], [499, "200-500"], [500, "500+"], [9000, "500+"]];
check("the latest interaction's delay falls in its bucket at every edge", buckets.every(([x, b]) => t.interactionBucketOf(x) === b));
const timing = t.serverTimingOf(12.345, 80.04);
check("the Server-Timing value is db and total with their durations, nothing else",
  /^db;dur=[\d.]+, total;dur=[\d.]+$/.test(timing) && timing === "db;dur=12.3, total;dur=80", timing);

// 5. the sources: the route, the request log, the proxy, the browser
const route = breakSource(read("../src/app/api/v1/telemetry/navigation/route.ts"), '"same-origin"', "MAX_BEACON_BYTES)", "getIdentity()", "status: 204");
check("the route refuses a request that is not same-origin (Sec-Fetch-Site)", /get\("sec-fetch-site"\) !== "same-origin"\) return fail\(403/.test(route));
check("the route reads at most 1 kB of body (the declared length and the stream)", /declared > MAX_BEACON_BYTES\)/.test(route) && /readAtMost\(request, MAX_BEACON_BYTES\)/.test(route));
check("the route needs proxy.ts's identity and reads no database (no data(), no tenant)",
  /if \(!\(await getIdentity\(\)\)\) return fail\(401/.test(route) && !/@\/lib\/data|withTenant|withoutTenant|@\/lib\/db/.test(route));
check("the route writes the beacon's log line only and answers 204", /console\.log\(navigationLogLine\(parsed\.beacon\)\)/.test(route) &&
  (route.match(/console\./g) ?? []).length === 1 && /status: 204/.test(route));
const instr = breakSource(read("../src/instrumentation.node.ts"), "kind: requestKindOf", 'setHeader("Server-Timing"');
check("the request log line carries kind from the route, the RSC mark and the prefetch mark", /kind: requestKindOf\(\{ route, rsc, prefetch \}\)/.test(instr));
check("every page and API response gets the Server-Timing header from the database's and the request's time", /setHeader\("Server-Timing", serverTimingOf\(/.test(instr));
const instrPrefetch = breakSource(instr, 'headers?.["next-router-prefetch"]');
check("a prefetch is marked from the incoming request's Next-Router-Prefetch header, in the request's own trace",
  /req\?\.headers\?\.\["next-router-prefetch"\] !== undefined\) \{\s*expire\(prefetches\);\s*prefetches\.set\(id/.test(instrPrefetch) && /const prefetch = prefetches\.delete\(traceId\)/.test(instr));
const beacon = breakSource(read("../src/components/NavigationBeacon.tsx"), "routePatternOf(pathname)");
check("the browser sends the route's pattern, never the path or the address, to the beacon's route only",
  /const route = routePatternOf\(pathname\)/.test(beacon) && !/location\.(href|pathname|search)|searchParams/.test(beacon) &&
  (beacon.match(/BEACON_PATH/g) ?? []).length >= 2 && !/fetch\(["'`]\//.test(beacon));
const layout = breakSource(read("../src/app/layout.tsx"), "<NavigationBeacon />");
check("the root layout mounts the beacon once, so it survives every navigation", (layout.match(/<NavigationBeacon \/>/g) ?? []).length === 1);

// 6. request-percentiles.mjs: --kind and --navigation
const tool = new URL("../../tools/perf/request-percentiles.mjs", import.meta.url).pathname;
const lines = [
  { message: "request", route: "/day", totalMs: 10, status: 200, kind: "document" },
  { message: "request", route: "/day", totalMs: 20, status: 200, kind: "prefetch" },
  { message: "request", route: "/day", totalMs: 30, status: 200, kind: "navigation" },
  { message: "request", route: "/day", totalMs: 40, status: 200 },
  { message: "navigation", route: "/day", kind: "navigation", firstFrameMs: 30, contentMs: 200, interaction: "0-100" },
  { message: "navigation", route: "/day", kind: "navigation", firstFrameMs: 50, contentMs: null, interaction: "500+" },
].map((l) => JSON.stringify({ jsonPayload: l })).join("\n");
const run = (...a) => spawnSync(process.execPath, [tool, "--json", ...a], { input: lines, encoding: "utf8" });
const byKind = (() => { try { return JSON.parse(run("--kind", PROVOKE ? "navigation" : "prefetch").stdout); } catch { return []; } })();
check("request-percentiles.mjs --kind prefetch keeps the prefetch lines alone", byKind.length === 1 && byKind[0].requests === 1 && byKind[0].p50 === 20, JSON.stringify(byKind));
const nav = (() => { try { return JSON.parse(run(PROVOKE ? "--rsc" : "--navigation").stdout); } catch { return []; } })();
check("request-percentiles.mjs --navigation summarises the beacons per route and kind, those without content apart",
  nav.length === 1 && nav[0].beacons === 2 && nav[0].frame_p95 === 50 && nav[0].content_p50 === 200 && nav[0].without_content === 1 && nav[0].interaction_pct["500+"] === 50,
  JSON.stringify(nav));
check("request-percentiles.mjs refuses an unknown --kind", run("--kind", PROVOKE ? "api" : "other").status === 2);

// 7. over HTTP, when BASE names the app in mock mode
if (BASE) {
  const post = (b, h = {}) => fetch(`${BASE}/api/v1/telemetry/navigation`, { method: "POST", body: b, headers: { "content-type": "application/json", ...h }, redirect: "manual" });
  const same = { "sec-fetch-site": PROVOKE ? "cross-site" : "same-origin" };
  check("HTTP: a same-origin beacon answers 204 with no body", (await post(body(good), same)).status === 204);
  check("HTTP: a cross-site beacon answers 403", (await post(body(good), { "sec-fetch-site": PROVOKE ? "same-origin" : "cross-site" })).status === 403);
  check("HTTP: a beacon without Sec-Fetch-Site answers 403", (await post(body(good), PROVOKE ? same : {})).status === 403);
  check("HTTP: a body over 1 kB answers 413", (await post(PROVOKE ? body(good) : padded, same)).status === 413);
  check("HTTP: a beacon with a path for a route answers 400", (await post(body({ ...good, route: PROVOKE ? "/day" : "/live/newco" }), same)).status === 400);
  const api = await fetch(`${BASE}/api/v1/me`, { redirect: "manual" });
  const page = await fetch(`${BASE}/day`, { redirect: "manual", headers: { cookie: "cma-session=1" } });
  const st = (r) => r.headers.get("server-timing") ?? "";
  const re = PROVOKE ? /^$/ : /^db;dur=[\d.]+, total;dur=[\d.]+$/;
  check("HTTP: an API answer and a page carry Server-Timing with db and total only", re.test(st(api)) && re.test(st(page)), `${st(api)} | ${st(page)}`);
}

if (PROVOKE) {
  console.log(`\n${passed === 0 ? `ALL ${n} PROVOKED CHECKS FAILED, as they must` : `${passed} of ${n} checks did not fail when provoked`}`);
  process.exit(passed === 0 ? 0 : 1);
}
console.log(`\n${passed === n ? `ALL ${n} PASS` : `${n - passed} of ${n} FAILED`}`);
process.exit(passed === n ? 0 : 1);
