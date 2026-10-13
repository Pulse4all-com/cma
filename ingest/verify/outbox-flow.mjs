/**
 * Verifier: the outbox worker end to end (migration 0007c; brief B10, split out in B10.1), against a
 * local PostgreSQL with db/00…58 and a fake HubSpot (contact batch read and batch update). The worker
 * is generic and, since 0008h, unused for commerce (README Decision log, 13 October 2026): nothing in
 * the CMA enqueues a write-back today, so this verifier enqueues the actions itself through the
 * ingest core's writes.writebacks (cma.enqueue_contact_writeback). Everything is invented: tenant,
 * ids, the token and the contacts' values.
 *
 *   CMA_DB_HOST=/tmp CMA_DB_PORT=5432 CMA_DB_NAME=cma CMA_DB_USER=cma-ingest@local.iam \
 *   INGEST_FLOW_ADMIN_USER=martin@pulse4all.com node verify/outbox-flow.mjs [--provoke]
 *
 * Logins as in verify/flow.mjs. One throwaway tenant per run (outbox-<run>); the job runs in this
 * process; at the end this run's connection is set inactive.
 *
 * Proves: a newer action for a contact supersedes its pending one; HubSpot answering 429 fails the
 * actions rate_limited with a backoff, and the next run sends them; if_empty keeps an agent's value;
 * slot fills 1 then 2 and stops when both are taken (slots_full); the id already in a slot is
 * present; the store and totals only with slot 1; always writes only a difference; a field disabled
 * after the enqueue is never written; only enabled write-back properties are read and written; a
 * contact gone from HubSpot fails contact_not_found; and the log holds counts and codes, no contact
 * id or value.
 */
import http from "node:http";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { randomBytes } from "node:crypto";
import pg from "pg";
import { expect, verdict, PROVOKE } from "./lib.mjs";

console.log(`verify/outbox-flow.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

for (const v of ["CMA_DB_HOST", "CMA_DB_USER"]) {
  if (!process.env[v]) {
    console.error(`${v} is required (a local PostgreSQL with db/00…58; see the header)`);
    process.exit(2);
  }
}
const ADMIN = process.env.INGEST_FLOW_ADMIN_USER ?? "martin@pulse4all.com";
const RUN = randomBytes(4).toString("hex");
const SLUG = `outbox-${RUN}`;
const HS_TOKEN = "fixture-hubspot-token-0002";
const STORE = "flow-store";
const REF = { r1: "7100000001", r2: "7100000002", r3: "7100000003", r6: "7100000006", r8: "7100000008" };

const secretsDir = mkdtempSync(path.join(tmpdir(), "outbox-flow-"));
writeFileSync(path.join(secretsDir, `ingest-hubspot-${RUN}-token`), HS_TOKEN);

// ---- The fake HubSpot ---------------------------------------------------------------------------------
// 5200000001 empty; 5200000002 an agent's country and another customer in slot 1; 5200000003 its id in
// slot 1 already; 5200000006 both slots taken; 5200000008 deleted before the run
const hs = {
  contacts: {
    "5200000001": { contact_netsuite_id: "NS-1" },
    "5200000002": { contact_country: "NL", contact_shopify_id_1: "7199999999" },
    "5200000003": { contact_shopify_id_1: REF.r3 },
    "5200000006": { contact_shopify_id_1: "7199999997", contact_shopify_id_2: "7199999998", contact_country: "GB" },
    "5200000008": {},
  },
  reads: [], updates: [], update429: false,
};
const fakeServer = http.createServer((req, res) => {
  let data = "";
  req.on("data", (c) => { data += c; });
  req.on("end", () => {
    const json = (status, b) => { res.writeHead(status, { "content-type": "application/json" }); res.end(JSON.stringify(b)); };
    if (req.headers.authorization !== `Bearer ${HS_TOKEN}`) return json(401, { message: "unauthorized" });
    const body = data ? JSON.parse(data) : {};
    const url = new URL(req.url, "http://x");
    const notFound = (ids) => (ids.length ? { errors: [{ status: "error", category: "OBJECT_NOT_FOUND", context: { ids } }] } : {});
    if (url.pathname === "/crm/v3/objects/contacts/batch/read") {
      hs.reads.push({ properties: body.properties, ids: body.inputs.map((i) => i.id) });
      const found = body.inputs.filter((i) => hs.contacts[i.id] && !hs.contacts[i.id].deleted);
      const missing = body.inputs.filter((i) => !found.includes(i)).map((i) => i.id);
      const results = found.map((i) => ({ id: i.id, properties: Object.fromEntries(body.properties.map((p) => [p, hs.contacts[i.id][p] ?? null])) }));
      return json(missing.length ? 207 : 200, { status: "COMPLETE", results, ...notFound(missing) });
    }
    if (url.pathname === "/crm/v3/objects/contacts/batch/update") {
      if (hs.update429) return json(429, { status: "error", message: "rate limited" });
      hs.updates.push({ inputs: body.inputs });
      const results = [];
      const missing = [];
      for (const i of body.inputs) {
        if (!hs.contacts[i.id] || hs.contacts[i.id].deleted) {
          missing.push(i.id);
          continue;
        }
        Object.assign(hs.contacts[i.id], i.properties);
        results.push({ id: i.id, properties: i.properties });
      }
      return json(missing.length ? 207 : 200, { status: "COMPLETE", results, ...notFound(missing) });
    }
    return json(404, { message: "not found" });
  });
});
await new Promise((r) => fakeServer.listen(0, "127.0.0.1", r));

process.env.INGEST_SECRETS_DIR = secretsDir;
process.env.INGEST_HUBSPOT_API_BASE = `http://127.0.0.1:${fakeServer.address().port}`;
process.env.INGEST_PACE_FACTOR = "0.01";
const logs = [];
const { setLogSink } = await import("../src/core/log.mjs");
setLogSink((line) => logs.push(line));
const { runOutbox } = await import("../src/jobs/outbox.mjs");
const { servedConnections, contextOf } = await import("../src/core/connection.mjs");
const { applyUnits } = await import("../src/core/store.mjs");
const { closeDb } = await import("../src/core/db.mjs");

// ---- Setup as the admin login ----------------------------------------------------------------------
const admin = new pg.Client({ host: process.env.CMA_DB_HOST, port: Number(process.env.CMA_DB_PORT ?? 5432), database: process.env.CMA_DB_NAME ?? "cma",
  user: ADMIN, password: process.env.CMA_DB_PASSWORD || undefined });
await admin.connect();
const q = async (text, values) => (await admin.query(text, values)).rows;
await q("set role cma_owner");
const [{ t1 }] = await q("select cma.create_tenant($1, 'Outbox flow', 'Europe/Amsterdam') as t1", [SLUG]);
const [{ id: adminId }] = await q("insert into cma.app_user (tenant_id, email, display_name) values ($1, 'flow-admin@example.invalid', 'Flow admin') returning id", [t1]);
await q("insert into cma.user_role (tenant_id, user_id, role_id) select $1, $2, id from cma.app_role where tenant_id = $1 and key = 'admin'", [t1, adminId]);
async function asAdmin(fn) {
  await q("begin");
  await q("set local role cma_app");
  await q("select set_config('app.tenant_id', $1, true), set_config('app.user_id', $2, true), set_config('app.actor_label', 'verify:outbox-flow', true)", [t1, adminId]);
  try {
    const r = await fn();
    await q("commit");
    return r;
  } catch (e) {
    await q("rollback");
    throw e;
  }
}
const H = await asAdmin(async () => {
  const [h] = await q("select * from cma.upsert_connection('hubspot', 'HubSpot outbox flow', $1, null, $2)", [`8${RUN.replace(/\D/g, "1").slice(0, 6)}`, `ingest-hubspot-${RUN}-token`]);
  const wb = [["commerce_ref", "contact_shopify_id_1", "slot", 1], ["commerce_ref", "contact_shopify_id_2", "slot", 2],
    ["commerce_store", "contact_shopify_store", "always", 1], ["commerce_orders", "contact_shopify_total_orders", "always", 1],
    ["commerce_spent", "contact_shopify_total_spent", "always", 1], ["country", "contact_country", "if_empty", 1],
    ["currency", "contact_currency", "if_empty", 1], ["language", "contact_language", "if_empty", 1]];
  for (const [field, prop, mode, slot] of wb) await q("select cma.set_writeback_field($1, $2, $3, $4, true, $5::smallint)", [h.connection_id, field, prop, mode, slot]);
  return h.connection_id;
});
const [hConn] = await servedConnections({ connectionId: H });
const enqueue = (list) => applyUnits(contextOf(hConn), H, [{ eventIds: [], status: "processed",
  writes: { writebacks: list.map(([contactId, values, reason]) => ({ connectionId: H, contactId, values, reason })) } }]);
const outbox = async () => q("select target_id, payload, status, error, result from cma.outbox_action where connection_id = $1 order by id", [H]);
const values = (ref, orders, spent, o = {}) => ({ commerce_ref: ref, commerce_store: STORE, commerce_orders: orders, commerce_spent: spent, country: "GB", currency: "GBP", language: "en", ...o });

// ---- A. Enqueue: a newer action supersedes the pending one ------------------------------------------
await enqueue([["5200000001", values(REF.r1, 1, 120), "verify:r1"]]);
const e = await enqueue([["5200000001", values(REF.r1, 2, 240), "verify:r1"], ["5200000002", values(REF.r2, 1, 60), "verify:r2"],
  ["5200000003", values(REF.r3, 1, 60), "verify:r3"], ["5200000006", values(REF.r6, 1, 60), "verify:r6"]]);
let ob = await outbox();
expect("five enqueues → the first action of 5200000001 superseded by its newer one, four pending", [e.counts.writebacks, ob.map((a) => a.status)],
  [4, ["superseded", "pending", "pending", "pending", "pending"]], [5, ["pending", "pending", "pending", "pending", "pending"]]);

// ---- B. 429, then sent ------------------------------------------------------------------------------
await asAdmin(() => q("select cma.set_writeback_field($1, 'currency', 'contact_currency', 'if_empty', false)", [H]));
hs.update429 = true;
const o1 = await runOutbox({ connectionId: H });
ob = await outbox();
expect("HubSpot answering 429 on the batch update → the actions failed rate_limited, attempted again later", [o1.sent, ob.filter((a) => a.status === "failed").every((a) => a.error === "rate_limited"),
  (await q("select bool_and(next_attempt_at > now()) as later from cma.outbox_action where connection_id = $1 and status = 'failed'", [H]))[0].later], [0, true, true], [4, false, false]);
hs.update429 = false;
await q("update cma.outbox_action set next_attempt_at = now() where connection_id = $1 and status = 'failed'", [H]);
const o2 = await runOutbox({ connectionId: H });
expect("…then sent", [o2.actionsFailed, (await outbox()).filter((a) => a.status === "sent").length], [0, 4], [4, 0]);
const c = hs.contacts;
expect("an empty contact: id in slot 1, store, totals, country and language; currency disabled after the enqueue never written",
  [c["5200000001"].contact_shopify_id_1, c["5200000001"].contact_shopify_store, c["5200000001"].contact_shopify_total_orders, c["5200000001"].contact_shopify_total_spent,
    c["5200000001"].contact_country, c["5200000001"].contact_language, c["5200000001"].contact_currency],
  [REF.r1, STORE, "2", "240", "GB", "en", undefined], [null, null, null, null, null, null, "GBP"]);
expect("an agent's country kept (if_empty), the id in slot 2, no store or totals (not slot 1)",
  [c["5200000002"].contact_country, c["5200000002"].contact_shopify_id_1, c["5200000002"].contact_shopify_id_2, c["5200000002"].contact_shopify_store, c["5200000002"].contact_shopify_total_orders],
  ["NL", "7199999999", REF.r2, undefined, undefined], ["GB", REF.r2, null, STORE, "1"]);
expect("both slots taken → no id, no totals; the result says slots_full",
  [c["5200000006"].contact_shopify_id_1, c["5200000006"].contact_shopify_id_2, c["5200000006"].contact_shopify_total_orders, (await outbox()).find((a) => a.target_id === "5200000006")?.result?.ref],
  ["7199999997", "7199999998", undefined, "slots_full"], [REF.r6, null, "1", "written"]);
expect("the id already in slot 1 → present, the store and totals written", [(await outbox()).find((a) => a.target_id === "5200000003")?.result?.ref, c["5200000003"].contact_shopify_store],
  ["present", STORE], ["written", undefined]);
const allowed = ["contact_shopify_id_1", "contact_shopify_id_2", "contact_shopify_store", "contact_shopify_total_orders", "contact_shopify_total_spent", "contact_country", "contact_language"];
expect("only the enabled write-back properties read and written (never contact_netsuite_id)", [
  hs.reads.every((r) => r.properties.every((p) => allowed.includes(p))),
  hs.updates.every((u) => u.inputs.every((i) => Object.keys(i.properties).every((p) => allowed.includes(p)))),
  c["5200000001"].contact_netsuite_id], [true, true, "NS-1"], [false, false, null]);

// ---- C. always writes a difference only; a contact gone ---------------------------------------------
const writesBefore = hs.updates.length;
await enqueue([["5200000001", values(REF.r1, 3, 360), "verify:r1"]]);
await runOutbox({ connectionId: H });
const lastWrite = hs.updates.slice(writesBefore).flatMap((u) => u.inputs).find((i) => i.id === "5200000001");
expect("a newer total for the same customer: always writes only the difference (totals), not what is unchanged", Object.keys(lastWrite?.properties ?? {}).sort(),
  ["contact_shopify_total_orders", "contact_shopify_total_spent"], ["contact_shopify_store"]);
c["5200000008"].deleted = true;
await enqueue([["5200000008", values(REF.r8, 1, 60), "verify:r8"]]);
await runOutbox({ connectionId: H });
expect("a contact gone from HubSpot → failed contact_not_found", (await outbox()).findLast((a) => a.target_id === "5200000008")?.error, "contact_not_found", null);

// ---- D. What was logged -------------------------------------------------------------------------------
const outboxLines = logs.map((l) => JSON.parse(l)).filter((l) => l.message === "outbox");
expect("the outbox log lines hold counts and codes only: no contact id, ref or value", [outboxLines.length > 0, /5200000|7100000|flow-store|NS-1/.test(JSON.stringify(outboxLines))],
  [true, false], [false, true]);

await asAdmin(() => q("select cma.set_connection_status($1, 'inactive')", [H]));
await admin.end();
await new Promise((r) => fakeServer.close(r));
await closeDb();
rmSync(secretsDir, { recursive: true, force: true });
verdict();
