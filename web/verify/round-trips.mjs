/**
 * verify/round-trips.mjs: the database cost of every page and polled route stays within its budget.
 *
 * A regression guard from the IT audit of 17 October 2026 (section 5.6): each row of round-trips.json names a
 * path, a mock subject and the highest number of transactions (tx) and statements (rt) the request may cost, and
 * optionally the statuses it accepts (status, default [200]).
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

const problems = [];
const observed = [];
for (const row of budget) {
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

if (observedOnly) {
  console.log(JSON.stringify(observed, null, 2));
  process.exit(0);
}
if (problems.length) {
  for (const p of problems) console.log("  " + p);
  console.log(`round-trips: FAIL (${problems.length} problems)`);
  process.exit(1);
}
console.log(`round-trips: PASS (${budget.length} requests within their transaction and statement budgets)`);
