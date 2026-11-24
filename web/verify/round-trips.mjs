/**
 * verify/round-trips.mjs: the database cost of every page and polled route stays within its budget.
 *
 * A regression guard from the IT audit of 17 October 2026 (section 5.6): each row of round-trips.json names a
 * path, a mock subject and the highest number of transactions (tx) and statements (rt) the request may cost, and
 * optionally the statuses it accepts (status, default [200]) and the permission it needs (permission). A row with a permission
 * is measured only when its subject holds it: no default role holds pledges.view (168, D7), so in dev the admin's Pledge
 * lists rows are a note, not a failure, and the local fixture's role (round-trips-fixture.sql) measures them in full
 * (backlog CMA-117). Whether a subject holds a permission is asked of the API itself: PROBES names a route that answers 200
 * with it and 403 not_permitted without it.
 * The server reports the cost itself when CMA_DB_TRACE=1 and sign-in is mock (never in iap mode, whatever the
 * environment says): pages render <meta name="cma-db" content="tx=…;rt=…;ms=…"> from the Shell, and a page that
 * streams reads after the Shell (System health) renders a second one after them, so the last meta counts; API
 * routes answer with an x-cma-db header (requestDbTrace() in src/lib/data, respond.ts). Nothing is read from the
 * database by this script; it needs a running app in api data mode with mock sign-in:
 *
 *   CMA_AUTH_MODE=mock CMA_DATA_MODE=api CMA_DB_TRACE=1 CMA_DB_HOST=… node .next/standalone/server.js
 *   BASE=http://localhost:8080 node verify/round-trips.mjs             expect PASS
 *   BASE=http://localhost:8080 node verify/round-trips.mjs --provoke   every budget is 0: expect FAIL
 *   BASE=http://localhost:8080 node verify/round-trips.mjs --observed  prints the observed costs as JSON rows
 *
 * A page that streams a part after its first paint (addition 0008zy: a Flash overview's records) may carry firstTx and
 * firstRt too: the Shell's meta, written before the streamed part reads, is the first paint's cost, held to those budgets,
 * and the last meta is the request's total, held to tx and rt.
 * Locally the budget is observed on the dev seed plus verify/round-trips-fixture.sql (two CRM connections, so the
 * alert-rules row proves its cost does not grow with the number of connections; 18 October 2026).
 * Against dev: CMA_DB_TRACE=1 set on cma-web for the run and removed after it (docs/RUNBOOK.md, 5. Verifiers).
 * It sits with verify:api (a server and a database), not with the pure verifiers.
 */
import { readFileSync } from "node:fs";
import path from "node:path";

const BASE = process.env.BASE ?? "http://localhost:8080";
const provoke = process.argv.includes("--provoke");
const observedOnly = process.argv.includes("--observed");
const here = path.dirname(new URL(import.meta.url).pathname);
const budget = JSON.parse(readFileSync(path.join(here, "round-trips.json"), "utf8"));

function parse(s) {
  const m = /tx=(\d+);rt=(\d+);ms=([\d.]+)/.exec(s ?? "");
  return m ? { tx: Number(m[1]), rt: Number(m[2]), ms: Number(m[3]) } : null;
}

/** A route per permission a row may name: 200 when the subject holds it, 403 not_permitted when not */
const PROBES = { "pledges.view": "/api/v1/reports/pledge-lists?limit=1" };
const held = new Map();
async function holds(subject, permission) {
  const key = `${subject} ${permission}`;
  if (!held.has(key)) {
    const probe = PROBES[permission];
    if (!probe) held.set(key, `no probe for ${permission}`);
    else {
      const res = await fetch(BASE + probe, { headers: { "x-cma-mock-subject": subject, accept: "application/json" }, redirect: "manual" });
      const body = await res.json().catch(() => null);
      held.set(key, res.status === 200 ? true : res.status === 403 && body?.error?.code === "not_permitted" ? false : `the probe ${probe} answered ${res.status}`);
    }
  }
  return held.get(key);
}

const problems = [];
const notes = [];
const observed = [];
// Rows of kind "prefetch" are measured in a browser below (night N07, D5); the others by a plain request
const prefetchRows = budget.filter((row) => row.kind === "prefetch");
for (const row of budget.filter((r) => r.kind !== "prefetch")) {
  if (row.permission) {
    const h = await holds(row.subject, row.permission);
    if (typeof h === "string") { problems.push(`${row.subject} ${row.path}: ${h}`); continue; }
    if (!h) { notes.push(`${row.subject} ${row.path}: not measured, ${row.subject} does not hold ${row.permission}`); continue; }
  }
  const res = await fetch(BASE + row.path, { headers: { "x-cma-mock-subject": row.subject, accept: "text/html,application/json" }, redirect: "manual" });
  const type = res.headers.get("content-type") ?? "";
  let cost = null;
  let first = null;
  if (type.includes("text/html")) {
    const html = await res.text();
    const metas = [...html.matchAll(/<meta name="cma-db" content="([^"]+)"/g)];
    cost = parse(metas.at(-1)?.[1]);
    first = parse(metas[0]?.[1]);
  } else {
    await res.arrayBuffer();
    cost = parse(res.headers.get("x-cma-db"));
  }
  if (!(row.status ?? [200]).includes(res.status)) { problems.push(`${row.subject} ${row.path}: status ${res.status}`); continue; }
  if (!cost) { problems.push(`${row.subject} ${row.path}: no database cost reported (the server needs CMA_DATA_MODE=api, CMA_AUTH_MODE=mock and CMA_DB_TRACE=1)`); continue; }
  observed.push({ path: row.path, subject: row.subject, tx: cost.tx, rt: cost.rt, ...(first && row.firstTx !== undefined ? { firstTx: first.tx, firstRt: first.rt } : {}) });
  const maxTx = provoke ? 0 : row.tx;
  const maxRt = provoke ? 0 : row.rt;
  if (cost.tx > maxTx) problems.push(`${row.subject} ${row.path}: ${cost.tx} transactions, budget ${maxTx}`);
  if (cost.rt > maxRt) problems.push(`${row.subject} ${row.path}: ${cost.rt} statements, budget ${maxRt}`);
  // the first paint (a page that streams a part after it): the Shell's meta, before the streamed part's reads
  if (row.firstTx !== undefined) {
    if (!first) problems.push(`${row.subject} ${row.path}: no first-paint cost reported`);
    else {
      const maxFirstTx = provoke ? 0 : row.firstTx;
      const maxFirstRt = provoke ? 0 : row.firstRt;
      if (first.tx > maxFirstTx) problems.push(`${row.subject} ${row.path}: first paint ${first.tx} transactions, budget ${maxFirstTx}`);
      if (first.rt > maxFirstRt) problems.push(`${row.subject} ${row.path}: first paint ${first.rt} statements, budget ${maxFirstRt}`);
    }
  }
}

// ---- In a browser (night N07, decisions D2 and D5) -------------------------------------------------------------------
// The head start: a subject opens a page (row.from) and, once its blocks have settled and the browser is idle, the page
// prefetches the role's top destinations in full. Each prefetched destination's cost is read from the cma-db meta its
// React Server Components payload carries (the page's Shell writes it, as in the HTML) and held to the row's budget; the
// set prefetched must be exactly the subject's rows (no report, never Log out). Then the persistent frame: a click to a
// rail page and Back load no new inbox from scratch (the message centre mounts once per tab: no /api/v1/me/messages
// request without ?since= after the first, which is how a fresh mount polls).
const browserLines = [];
if (prefetchRows.length > 0) {
  const { chromium } = await import("playwright");
  const browser = await chromium.launch();
  const metaCost = (text) => {
    const all = [...text.matchAll(/"cma-db","content":"(tx=\d+;rt=\d+;ms=[\d.]+)"/g)];
    return all.length ? parse(all.at(-1)[1]) : null;
  };
  for (const group of Object.values(Object.groupBy(prefetchRows, (r) => `${r.subject} ${r.from}`))) {
    const { subject, from } = group[0];
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 }, extraHTTPHeaders: { "x-cma-mock-subject": subject } });
    const page = await ctx.newPage();
    const fetched = new Map();
    const pending = [];
    let fresh = 0;
    let loaded = false;
    page.on("response", (res) => {
      const req = res.request();
      const url = new URL(res.url());
      if (url.pathname === "/api/v1/me/messages" && !url.searchParams.has("since") && loaded) fresh += 1;
      const h = req.headers();
      if (!loaded || !(h.rsc || h["next-router-prefetch"])) return;
      pending.push(res.text().then((text) => {
        const cost = metaCost(text);
        if (!cost) return;
        const prev = fetched.get(url.pathname);
        if (!prev || cost.tx > prev.tx || cost.rt > prev.rt) fetched.set(url.pathname, cost);
      }).catch(() => undefined));
    });
    await page.goto(BASE + from, { waitUntil: "networkidle" });
    loaded = true;
    // the blocks settle, the browser goes idle, the prefetches run
    await page.waitForTimeout(5000);
    await page.waitForLoadState("networkidle");
    await Promise.all(pending);
    const want = group.map((r) => r.path).sort();
    const got = [...fetched.keys()].sort();
    if (JSON.stringify(got) !== JSON.stringify(want)) problems.push(`${subject} ${from}: prefetched ${JSON.stringify(got)}, expected ${JSON.stringify(want)}`);
    for (const row of group) {
      const cost = fetched.get(row.path);
      if (!cost) continue;
      observed.push({ kind: "prefetch", from, path: row.path, subject, tx: cost.tx, rt: cost.rt });
      const maxTx = provoke ? 0 : row.tx;
      const maxRt = provoke ? 0 : row.rt;
      if (cost.tx > maxTx) problems.push(`${subject} prefetch ${row.path}: ${cost.tx} transactions, budget ${maxTx}`);
      if (cost.rt > maxRt) problems.push(`${subject} prefetch ${row.path}: ${cost.rt} statements, budget ${maxRt}`);
      browserLines.push(`${subject} prefetch ${row.path} from ${from}: ${cost.tx} tx, ${cost.rt} rt`);
    }
    // the frame persists: a click to the first prefetched page and Back
    const target = want[0];
    const before = fresh;
    await page.locator(`nav[data-rail-nav] a[href="${target}"]`).first().click().catch(() => page.goto(BASE + target));
    await page.waitForURL(`**${target}`);
    await page.waitForLoadState("networkidle");
    await page.goBack();
    await page.waitForLoadState("networkidle");
    const extra = fresh - before;
    browserLines.push(`${subject} ${from} → ${target} → back: ${extra} inbox read from scratch`);
    if (provoke ? extra === 0 : extra > 0) problems.push(`${subject}: ${extra} inbox read${extra === 1 ? "" : "s"} from scratch on a navigation (the message centre mounted again)${provoke ? " (provoked: 0 counts as a failure)" : ""}`);
    await ctx.close();
  }
  await browser.close();
}

if (observedOnly) {
  console.log(JSON.stringify(observed, null, 2));
  process.exit(0);
}
for (const l of browserLines) console.log("  " + l);
for (const n of notes) console.log("  note: " + n);
if (problems.length) {
  for (const p of problems) console.log("  " + p);
  console.log(`round-trips: FAIL (${problems.length} problems)`);
  process.exit(1);
}
console.log(`round-trips: PASS (${budget.length - notes.length} requests within their transaction and statement budgets${notes.length ? `, ${notes.length} not measured without their permission (notes above)` : ""})`);
