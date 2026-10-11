/**
 * Verifier: the ingest jobs end to end (brief B8), against a local PostgreSQL with db/00…37 and a
 * fake HubSpot API. Everything is invented: tenants, portals, ids, secrets, emails (example.com).
 *
 *   CMA_DB_HOST=/tmp CMA_DB_PORT=5432 CMA_DB_NAME=cma CMA_DB_USER=cma-ingest@local.iam \
 *   INGEST_FLOW_ADMIN_USER=martin@pulse4all.com node verify/jobs-flow.mjs [--provoke]
 *
 * Logins as in verify/flow.mjs: CMA_DB_USER is the service's (a member of cma_app), the admin login
 * creates two throwaway tenants per run (jobs-<run>-one, jobs-<run>-two) and reads as the owner.
 * The jobs run in this process with their connection filter, so other tenants of the local database
 * are left alone, except one unfiltered sweep (tenant isolation). At the end this run's connections
 * are set inactive, so a later run does not serve them.
 *
 * Proves: the sweep processes due events, respects the backoff, parks an event at
 * ingest.max_attempts and never claims it again, reads a record without a contact again (once per
 * ten minutes) and records link_calls; the forms poll refreshes the catalog keeping configuration,
 * reads counted forms only, stops at the start date and at its cursor, resolves contacts by the
 * definition's email field, keeps host, path, UTM and kept fields only, is idempotent across runs,
 * and a failed contact search leaves the cursor for the next run; the backfill starts at
 * intake.start_date by default, resumes after an interruption without reading the first page again,
 * includes deals created earlier and closed since, and paces its searches; the reconcile picks up a
 * change the webhook missed, leaves a newer row alone, reads only held contacts, honours
 * --lookback-minutes and reads nothing twice; tenant isolation; no email, token or contact id in the
 * logs, no email in the database.
 */
import http from "node:http";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { randomBytes } from "node:crypto";
import pg from "pg";
import { expect, verdict, PROVOKE } from "./lib.mjs";

console.log(`verify/jobs-flow.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

for (const v of ["CMA_DB_HOST", "CMA_DB_USER"]) {
  if (!process.env[v]) {
    console.error(`${v} is required (a local PostgreSQL with db/00…37; see the header)`);
    process.exit(2);
  }
}
const ADMIN = process.env.INGEST_FLOW_ADMIN_USER ?? "martin@pulse4all.com";
const RUN = randomBytes(4).toString("hex");
const SLUG1 = `jobs-${RUN}-one`;
const SLUG2 = `jobs-${RUN}-two`;
const TOKEN1 = "fixture-jobs-token-one";
const TOKEN2 = "fixture-jobs-token-two";

const secretsDir = mkdtempSync(path.join(tmpdir(), "ingest-jobs-"));
const putSecret = (name, value) => writeFileSync(path.join(secretsDir, name), value);
putSecret(`ingest-hubspot-jobs${RUN}-signing`, "fixture-jobs-client-secret");
putSecret(`ingest-hubspot-jobs${RUN}-token1`, TOKEN1);
putSecret(`ingest-hubspot-jobs${RUN}-token2`, TOKEN2);
putSecret(`ingest-hash-pepper-${SLUG1}`, "fixture-pepper-jobs-one-0000000000");
putSecret(`ingest-hash-pepper-${SLUG2}`, "fixture-pepper-jobs-two-0000000000");

// ---- The fake HubSpot API ------------------------------------------------------------------------
const now = Date.now();
const isoAgo = (min) => new Date(now - min * 60_000).toISOString();
const OLD = "2026-10-02T10:00:00.000Z";
const FORM_A = "aaaaaaaa-0000-4000-8000-000000000001";
const FORM_B = "bbbbbbbb-0000-4000-8000-000000000002";
const at = (iso) => Date.parse(iso);
const sub = (id, iso, email, extra = {}) => ({
  conversionId: id, submittedAt: at(iso), pageUrl: "https://www.example.com/nl/kopen?utm_source=google&utm_campaign=autumn&gclid=x1",
  values: [{ name: "firstname", value: "Invented" }, ...(email ? [{ name: "work_email", value: email }] : []), { name: "product_interest", value: "AED Plus" }], ...extra,
});
const fake = {
  failIds: new Set(), searchFailAt: null, contactSearch: "ok", requests: [],
  objects: {
    deals: {
      4120000001: { createdate: isoAgo(10), pipeline: "p-sales", dealstage: "s-new", hs_lastmodifieddate: OLD },
      4120000009: { createdate: isoAgo(20), pipeline: "p-sales", dealstage: "s-new", hs_lastmodifieddate: OLD },
      4130000001: { createdate: "2026-10-02T09:00:00.000Z", pipeline: "p-sales", dealstage: "s-new", amount: "100", hs_lastmodifieddate: OLD },
      4130000002: { createdate: "2026-10-03T09:00:00.000Z", pipeline: "p-sales", dealstage: "s-new", amount: "200", hs_lastmodifieddate: OLD },
      4130000003: { createdate: "2026-10-04T09:00:00.000Z", pipeline: "p-sales", dealstage: "s-new", amount: "300", hs_lastmodifieddate: OLD },
      4130000004: { createdate: "2026-10-05T09:00:00.000Z", pipeline: "p-sales", dealstage: "s-new", hs_lastmodifieddate: OLD },
      4130000005: { createdate: "2026-10-06T09:00:00.000Z", pipeline: "p-sales", dealstage: "s-new", hs_lastmodifieddate: OLD },
      4130000009: { createdate: "2026-09-25T09:00:00.000Z", closedate: "2026-10-03T12:00:00.000Z", pipeline: "p-sales", dealstage: "s-won", hs_lastmodifieddate: OLD },
      4140000001: { createdate: isoAgo(5), pipeline: "p-sales", dealstage: "s-new", hs_lastmodifieddate: OLD },
    },
    contacts: {
      4300000001: { contact_country: "uk", lastmodifieddate: isoAgo(120), email: "one@example.com" },
      4399999999: { contact_country: "nl", lastmodifieddate: isoAgo(120) },
    },
    calls: {},
    tickets: {},
  },
  assoc: { "deals>contacts": {} },
  forms: [
    { id: FORM_A, name: "Quote test", archived: false, fieldGroups: [{ fields: [{ name: "firstname", fieldType: "single_line_text", objectTypeId: "0-1" },
      { name: "work_email", fieldType: "email", objectTypeId: "0-1" }, { name: "product_interest", fieldType: "dropdown", objectTypeId: "0-1" }] }] },
    { id: FORM_B, name: "Not counted test", archived: false, fieldGroups: [{ fields: [{ name: "email", fieldType: "email", objectTypeId: "0-1" }] }] },
  ],
  submissions: {
    [FORM_A]: [
      sub("c-0005", "2026-10-10T10:05:00.000Z", "one@example.com"),
      sub("c-0004", "2026-10-10T10:04:00.000Z", "nobody@example.com"),
      sub("c-0003", "2026-10-10T10:03:00.000Z", "shared@example.com"),
      sub("c-0002", "2026-10-10T10:02:00.000Z", null),
      sub("c-0001", "2026-09-20T10:01:00.000Z", "one@example.com"),
    ],
    [FORM_B]: [sub("c-b001", "2026-10-10T10:00:00.000Z", "one@example.com")],
  },
  emails: { "one@example.com": ["4300000001"], "shared@example.com": ["4300000002", "4300000003"] },
};
const MODIFIED = { deals: "hs_lastmodifieddate", tickets: "hs_lastmodifieddate", calls: "hs_lastmodifieddate", contacts: "lastmodifieddate" };
const PAGE = 2;

function json(res, status, body) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}
const fakeServer = http.createServer((req, res) => {
  let data = "";
  req.on("data", (c) => { data += c; });
  req.on("end", () => {
    const body = data ? JSON.parse(data) : null;
    const url = new URL(req.url, "http://x");
    const r = { method: req.method, path: url.pathname, query: Object.fromEntries(url.searchParams), auth: req.headers.authorization, body, t: Date.now() };
    fake.requests.push(r);
    let m;
    if ((m = /^\/crm\/v3\/objects\/(\w+)\/batch\/read$/.exec(url.pathname))) {
      const store = fake.objects[m[1]] ?? {};
      if (body.inputs.some((i) => fake.failIds.has(String(i.id)))) return json(res, 503, { status: "error" });
      const results = body.inputs.filter((i) => store[i.id]).map((i) => ({
        id: String(i.id), createdAt: store[i.id].createdate ?? OLD, updatedAt: store[i.id][MODIFIED[m[1]]] ?? OLD, archived: false,
        properties: Object.fromEntries(body.properties.filter((p) => store[i.id][p] !== undefined).map((p) => [p, store[i.id][p]])),
      }));
      return json(res, results.length === body.inputs.length ? 200 : 207, { status: "COMPLETE", results });
    }
    if ((m = /^\/crm\/v3\/objects\/(\w+)\/search$/.exec(url.pathname))) {
      const filters = body.filterGroups?.[0]?.filters ?? [];
      if (filters[0]?.operator === "EQ") {
        if (fake.contactSearch === "429") return json(res, 429, { status: "error", category: "RATE_LIMITS" });
        if (filters[0].propertyName !== "work_email") return json(res, 200, { total: 0, results: [] });
        const ids = fake.emails[String(filters[0].value).toLowerCase()] ?? [];
        return json(res, 200, { total: ids.length, results: ids.map((id) => ({ id, properties: { hs_object_id: id } })) });
      }
      r.search = true;
      const nth = fake.requests.filter((x) => x.search && x.path === url.pathname).length;
      if (fake.searchFailAt !== null && nth === fake.searchFailAt) {
        fake.searchFailAt = null;
        return json(res, 503, { status: "error" });
      }
      const prop = filters[0].propertyName;
      const gte = Number(filters[0].value);
      const lte = filters[1] ? Number(filters[1].value) : Infinity;
      const store = fake.objects[m[1]] ?? {};
      const all = Object.entries(store).filter(([, o]) => o[prop] && at(o[prop]) >= gte && at(o[prop]) <= lte)
        .sort((a, b) => at(a[1][prop]) - at(b[1][prop]) || a[0].localeCompare(b[0]));
      const offset = Number(body.after ?? 0);
      const part = all.slice(offset, offset + PAGE);
      return json(res, 200, {
        total: all.length,
        results: part.map(([id, o]) => ({ id, updatedAt: o[MODIFIED[m[1]]] ?? OLD, properties: Object.fromEntries(body.properties.filter((p) => o[p] !== undefined).map((p) => [p, o[p]])) })),
        ...(offset + PAGE < all.length ? { paging: { next: { after: String(offset + PAGE) } } } : {}),
      });
    }
    if ((m = /^\/crm\/v4\/associations\/(\w+)\/(\w+)\/batch\/read$/.exec(url.pathname))) {
      const map = fake.assoc[`${m[1]}>${m[2]}`] ?? {};
      const results = body.inputs.filter((i) => map[i.id]?.length).map((i) => ({ from: { id: String(i.id) }, to: map[i.id].map((t) => ({ toObjectId: t, associationTypes: [] })) }));
      return json(res, 200, { status: "COMPLETE", results });
    }
    if (url.pathname === "/crm/v3/pipelines/deals") {
      return json(res, 200, { results: [{ id: "p-sales", label: "Sales test", stages: [{ id: "s-new", label: "New", displayOrder: 0, metadata: { isClosed: "false" } },
        { id: "s-won", label: "Won", displayOrder: 1, metadata: { isClosed: "true" } }] }] });
    }
    if (url.pathname === "/crm/v3/pipelines/tickets") return json(res, 200, { results: [] });
    if (url.pathname === "/calling/v1/dispositions") return json(res, 200, []);
    if (url.pathname === "/marketing/v3/forms") return json(res, 200, { results: fake.forms });
    if ((m = /^\/marketing\/v3\/forms\/([\w-]+)$/.exec(url.pathname))) {
      const f = fake.forms.find((x) => x.id === m[1]);
      return f ? json(res, 200, f) : json(res, 404, { status: "error" });
    }
    if ((m = /^\/form-integrations\/v1\/submissions\/forms\/([\w-]+)$/.exec(url.pathname))) {
      const list = [...(fake.submissions[m[1]] ?? [])].sort((a, b) => b.submittedAt - a.submittedAt);
      const offset = Number(url.searchParams.get("after") ?? 0);
      return json(res, 200, { results: list.slice(offset, offset + PAGE), ...(offset + PAGE < list.length ? { paging: { next: { after: String(offset + PAGE) } } } : {}) });
    }
    json(res, 404, { status: "error" });
  });
});
await new Promise((r) => fakeServer.listen(0, "127.0.0.1", r));

// ---- The jobs, in this process -------------------------------------------------------------------
process.env.INGEST_SECRETS_DIR = secretsDir;
process.env.INGEST_HUBSPOT_API_BASE = `http://127.0.0.1:${fakeServer.address().port}`;
process.env.INGEST_PACE_FACTOR = "0.1";
const logs = [];
const { setLogSink } = await import("../src/core/log.mjs");
setLogSink((line) => logs.push(line));
const { runSweep } = await import("../src/jobs/sweep.mjs");
const { runPollForms } = await import("../src/jobs/poll-forms.mjs");
const { runReconcile } = await import("../src/jobs/reconcile.mjs");
const { runBackfill } = await import("../src/jobs/backfill.mjs");
const { UsageError } = await import("../src/jobs/runner.mjs");
const { recordEvents } = await import("../src/core/events.mjs");
const { closeDb } = await import("../src/core/db.mjs");

// ---- Setup as the admin login --------------------------------------------------------------------
const admin = new pg.Client({ host: process.env.CMA_DB_HOST, port: Number(process.env.CMA_DB_PORT ?? 5432), database: process.env.CMA_DB_NAME ?? "cma",
  user: ADMIN, password: process.env.CMA_DB_PASSWORD || undefined });
await admin.connect();
const q = async (text, values) => (await admin.query(text, values)).rows;
await q("set role cma_owner");
const [{ t1 }] = await q("select cma.create_tenant($1, $2, 'Europe/Amsterdam') as t1", [SLUG1, "Jobs one"]);
const [{ t2 }] = await q("select cma.create_tenant($1, $2, 'Europe/Amsterdam') as t2", [SLUG2, "Jobs two"]);
const adminOf = {};
const ingestOf = {};
for (const t of [t1, t2]) {
  const [{ id }] = await q("insert into cma.app_user (tenant_id, email, display_name) values ($1, 'jobs-admin@example.invalid', 'Jobs admin') returning id", [t]);
  await q("insert into cma.user_role (tenant_id, user_id, role_id) select $1, $2, id from cma.app_role where tenant_id = $1 and key = 'admin'", [t, id]);
  adminOf[t] = id;
  ingestOf[t] = (await q("select user_id from cma.app_user_external_id where tenant_id = $1 and system = 'ingest' and external_id = 'ingest'", [t]))[0].user_id;
}
async function asAdmin(tenant, fn) {
  await q("begin");
  await q("set local role cma_app");
  await q("select set_config('app.tenant_id', $1, true), set_config('app.user_id', $2, true), set_config('app.actor_label', 'verify:jobs', true)", [tenant, adminOf[tenant]]);
  try {
    const r = await fn();
    await q("commit");
    return r;
  } catch (e) {
    await q("rollback");
    throw e;
  }
}
const conn1 = await asAdmin(t1, async () => {
  const [c] = await q("select * from cma.upsert_connection('hubspot', 'HubSpot jobs one', '9000101', $1, $2)", [`ingest-hubspot-jobs${RUN}-signing`, `ingest-hubspot-jobs${RUN}-token1`]);
  await q("select cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP')");
  await q("select cma.set_market_alias('uk', 'GB')");
  await q("select cma.set_connection_field($1, 'contact', 'country', '', 'contact_country', 1::smallint)", [c.connection_id]);
  await q("select cma.set_connection_field($1, 'deal', 'amount', '', 'amount', 1::smallint)", [c.connection_id]);
  await q("select cma.set_form($1, $2, true, 'website', 'GB', array['product_interest', 'work_email'])", [c.connection_id, FORM_A]);
  await q("select cma.set_form($1, $2, false, null, null, '{}')", [c.connection_id, FORM_B]);
  await q("select cma.set_tenant_setting('ingest.max_attempts', '3')");
  return c.connection_id;
});
const conn2 = await asAdmin(t2, async () => (await q("select * from cma.upsert_connection('hubspot', 'HubSpot jobs two', '9000102', $1, $2)",
  [`ingest-hubspot-jobs${RUN}-signing`, `ingest-hubspot-jobs${RUN}-token2`]))[0].connection_id);

// ---- Helpers -------------------------------------------------------------------------------------
const ctx1 = { tenantId: t1, userId: ingestOf[t1], actorLabel: "verify:jobs" };
const ctx2 = { tenantId: t2, userId: ingestOf[t2], actorLabel: "verify:jobs" };
let seq = 0;
const created = (objectId, portal = "9000101") => ({ key: `hs:jobs-${RUN}-${++seq}`, sourceType: "object.creation", kind: "created", objectType: "deal",
  objectId: String(objectId), occurredAt: new Date().toISOString(), raw: { portalId: portal } });
const eventOf = async (objectId, conn = conn1) => (await q(
  "select status, attempts, error from cma.ingest_event where connection_id = $1 and object_id = $2 and event_key like 'hs:%' order by recorded_at desc limit 1", [conn, String(objectId)]))[0] ?? null;
const forceDue = (objectId) => q("update cma.ingest_event set next_attempt_at = now() where connection_id = $1 and object_id = $2", [conn1, String(objectId)]);
const deal = async (id, conn = conn1) => (await q("select contact_source_id, amount::text as amount, source_updated_at from cma.crm_record where connection_id = $1 and source_id = $2", [conn, String(id)]))[0] ?? null;
const runs = (job, conn = conn1) => q("select stream, status, counts, error, from_at, to_at from cma.sync_run where connection_id = $1 and job = $2 order by started_at", [conn, job]);
const requests = (pred) => fake.requests.filter(pred);
const mark = () => fake.requests.length;
const since = (n) => fake.requests.slice(n);
const sweep = (opts = {}) => runSweep({ connectionId: conn1, ...opts });

// ---- A. The sweep --------------------------------------------------------------------------------
await recordEvents(ctx1, conn1, [created(4120000001)]);
const s1 = await sweep();
expect("sweep: a due event processed", (await eventOf(4120000001))?.status, "processed", "received");
expect("sweep: the deal read back, still without a contact", [Boolean(await deal(4120000001)), (await deal(4120000001))?.contact_source_id], [true, null], [true, "4300000001"]);
expect("sweep: a record without a contact read again (one reread event)", Number((await q("select count(*) as n from cma.ingest_event where connection_id = $1 and event_key like 'reread:deal:4120000001:%'", [conn1]))[0].n), 1, 0);
await sweep();
expect("sweep: within ten minutes it is not read again", Number((await q("select count(*) as n from cma.ingest_event where connection_id = $1 and event_key like 'reread:%'", [conn1]))[0].n), 1, 2);
fake.assoc["deals>contacts"][4120000001] = [4300000001];
await sweep({ now: () => Date.now() + 10 * 60_000 });
expect("sweep: ten minutes later the second read finds the contact", (await deal(4120000001))?.contact_source_id, "4300000001", null);
expect("sweep: the contact taken in with its country through the alias", (await q("select country from cma.crm_contact where connection_id = $1 and source_id = '4300000001'", [conn1]))[0]?.country, "GB", "uk");
expect("sweep: link_calls recorded once per run, succeeded", (await runs("link_calls")).map((r) => r.status), ["succeeded", "succeeded", "succeeded"], ["succeeded"]);
expect("sweep: the run's totals count the processed event", s1.processed >= 1 && s1.failed === 0, true, false);

fake.failIds.add("4120000009");
await recordEvents(ctx1, conn1, [created(4120000009)]);
await sweep();
const f1 = await eventOf(4120000009);
expect("sweep: HubSpot failing → the event failed, attempt 1", [f1?.status, f1?.attempts, f1?.error], ["failed", 1, "http_503"], ["processed", 1, null]);
await sweep();
expect("sweep: the backoff is respected (not claimed again at once)", (await eventOf(4120000009))?.attempts, 1, 2);
await forceDue(4120000009);
await sweep();
expect("sweep: due again → attempt 2, still failed", [(await eventOf(4120000009))?.status, (await eventOf(4120000009))?.attempts], ["failed", 2], ["failed", 1]);
await forceDue(4120000009);
await sweep();
expect("sweep: at ingest.max_attempts (3) the event is parked as needs_review", [(await eventOf(4120000009))?.status, (await eventOf(4120000009))?.attempts], ["needs_review", 3], ["failed", 3]);
await forceDue(4120000009);
await sweep();
expect("sweep: a parked event is never claimed again", (await eventOf(4120000009))?.attempts, 3, 4);
fake.failIds.clear();

// ---- B. The forms poll ---------------------------------------------------------------------------
let n0 = mark();
const p1 = await runPollForms({ connectionId: conn1 });
const forms = await q("select source_form_id, name, is_counted, market, kept_fields, status from cma.connection_form where connection_id = $1 order by 1", [conn1]);
expect("forms: the catalog refreshed, names from HubSpot", forms.map((f) => f.name), ["Quote test", "Not counted test"], [FORM_A, FORM_B]);
expect("forms: the refresh kept the configuration (counted, market, kept fields)", forms.map((f) => [f.is_counted, f.market, f.kept_fields]),
  [[true, "GB", ["product_interest", "work_email"]], [false, null, []]], [[true, null, []], [true, null, []]]);
const subs = await q("select source_id, contact_source_id, contact_resolution, page_host, page_path, utm, kept_values from cma.form_submission where connection_id = $1 order by source_id", [conn1]);
expect("forms: four submissions since the start date, not the older one", subs.map((s) => s.source_id), ["c-0002", "c-0003", "c-0004", "c-0005"], ["c-0001", "c-0002", "c-0003", "c-0004", "c-0005"]);
expect("forms: contacts resolved (no email, several, none, one)", subs.map((s) => [s.contact_resolution, s.contact_source_id]),
  [["no_email", null], ["ambiguous", null], ["not_found", null], ["resolved", "4300000001"]], []);
expect("forms: host and path only, UTM parsed", [subs[3]?.page_host, subs[3]?.page_path, subs[3]?.utm], ["www.example.com", "/nl/kopen", { source: "google", campaign: "autumn" }], ["www.example.com", "/nl/kopen?utm_source=google", {}]);
expect("forms: kept values only the kept field, never the email field", subs[3]?.kept_values, { product_interest: "AED Plus" }, { product_interest: "AED Plus", work_email: "one@example.com" });
const searches1 = since(n0).filter((r) => r.path === "/crm/v3/objects/contacts/search");
expect("forms: one contact search per distinct email, on the definition's email field", [searches1.length, searches1.every((r) => r.body.filterGroups[0].filters[0].propertyName === "work_email")], [3, true], [4, false]);
expect("forms: a form not counted is never read", since(n0).filter((r) => r.path.endsWith(FORM_B)).length, 0, 1);
expect("forms: the run recorded, fetched and upserted four", (await runs("forms_poll")).map((r) => [r.stream, r.status, r.counts.fetched, r.counts.upserted]), [["forms", "succeeded", 4, 4]], [["forms", "failed", 0, 0]]);
expect("forms: the run's totals", [p1.upserted, p1.failed], [4, 0], [0, 1]);

n0 = mark();
await runPollForms({ connectionId: conn1 });
expect("forms: a second run writes nothing new", Number((await q("select count(*) as n from cma.form_submission where connection_id = $1", [conn1]))[0].n), 4, 8);
expect("forms: …reads one page (stops at the cursor), no catalog, no search", [since(n0).filter((r) => r.path.startsWith("/form-integrations")).length,
  since(n0).filter((r) => r.path === "/marketing/v3/forms").length, since(n0).filter((r) => r.path === "/crm/v3/objects/contacts/search").length], [1, 0, 0], [3, 1, 3]);

fake.submissions[FORM_A].unshift(sub("c-0006", "2026-10-10T10:06:00.000Z", "one@example.com"));
await runPollForms({ connectionId: conn1 });
expect("forms: a new submission arrives on the next run", (await q("select contact_resolution from cma.form_submission where connection_id = $1 and source_id = 'c-0006'", [conn1]))[0]?.contact_resolution, "resolved", null);

fake.submissions[FORM_A].unshift(sub("c-0007", "2026-10-10T10:07:00.000Z", "someone.new@example.com"));
fake.contactSearch = "429";
const cursorBefore = (await q("select cursor from cma.sync_cursor where connection_id = $1 and stream = $2", [conn1, `forms:${FORM_A}`]))[0]?.cursor;
await runPollForms({ connectionId: conn1 });
const failedRun = (await runs("forms_poll")).at(-1);
expect("forms: a rate-limited contact search fails the run (rate_limited)", [failedRun?.status, failedRun?.error], ["failed", "rate_limited"], ["succeeded", null]);
expect("forms: …the submission is not written without its contact", (await q("select count(*) as n from cma.form_submission where connection_id = $1 and source_id = 'c-0007'", [conn1]))[0].n, 0, 1);
expect("forms: …and the cursor did not move", (await q("select cursor from cma.sync_cursor where connection_id = $1 and stream = $2", [conn1, `forms:${FORM_A}`]))[0]?.cursor, cursorBefore, null);
fake.contactSearch = "ok";
await runPollForms({ connectionId: conn1 });
expect("forms: the next run writes it", (await q("select contact_resolution from cma.form_submission where connection_id = $1 and source_id = 'c-0007'", [conn1]))[0]?.contact_resolution, "not_found", null);

// ---- C. The backfill -----------------------------------------------------------------------------
fake.searchFailAt = 2;
n0 = mark();
const b1 = await runBackfill({ connectionId: conn1, object: "deal" });
const bRuns1 = await runs("backfill");
expect("backfill: an interruption fails the run with its code", [bRuns1.at(-1)?.status, bRuns1.at(-1)?.error, b1.failed], ["failed", "http_503", 1], ["succeeded", null, 0]);
expect("backfill: without --from it starts at intake.start_date (00:00 in the tenant's zone)", bRuns1.at(-1)?.from_at?.toISOString(), "2026-09-30T22:00:00.000Z", "2026-10-01T00:00:00.000Z");
expect("backfill: the first page was written before the interruption", [Boolean(await deal(4130000001)), Boolean(await deal(4130000002)), Boolean(await deal(4130000003))], [true, true, false], [true, true, true]);
const cur1 = (await q("select cursor from cma.sync_cursor where connection_id = $1 and stream = 'backfill:deal:createdate'", [conn1]))[0]?.cursor;
expect("backfill: the cursor stands at the first page's last created time", [cur1?.value, cur1?.done], [at("2026-10-03T09:00:00.000Z"), false], [null, true]);
n0 = mark();
const b2 = await runBackfill({ connectionId: conn1, object: "deal" });
expect("backfill: the rerun succeeds", [(await runs("backfill")).at(-1)?.status, b2.failed], ["succeeded", 0], ["failed", 1]);
expect("backfill: it resumed at the cursor, not at the start", since(n0).find((r) => r.search)?.body.filterGroups[0].filters[0].value, String(at("2026-10-03T09:00:00.000Z")), String(at("2026-09-30T22:00:00.000Z")));
const readIds = since(n0).filter((r) => r.path === "/crm/v3/objects/deals/batch/read").flatMap((r) => r.body.inputs.map((i) => String(i.id)));
expect("backfill: the first page's deals were not read again", readIds.includes("4130000001") || readIds.includes("4130000002"), false, true);
expect("backfill: every deal since the start date, and the one created earlier and closed since", [Boolean(await deal(4130000004)), Boolean(await deal(4130000005)), Boolean(await deal(4130000009))], [true, true, true], [true, true, false]);
expect("backfill: both streams' cursors done", (await q("select stream, cursor->>'done' as done from cma.sync_cursor where connection_id = $1 and stream like 'backfill:deal:%' order by 1", [conn1])).map((r) => [r.stream, r.done]),
  [["backfill:deal:closedate", "true"], ["backfill:deal:createdate", "true"]], [["backfill:deal:createdate", "false"]]);
const times = since(n0).filter((r) => r.search).map((r) => r.t);
const gaps = times.slice(1).map((t, i) => t - times[i]);
expect("backfill: searches within a run paced (at least 40 ms apart at a pace factor of 0.1)", gaps.length >= 2 && gaps.every((g) => g >= 35), true, false);
n0 = mark();
await runBackfill({ connectionId: conn1, object: "deal" });
expect("backfill: a finished backfill with the same start reads nothing again", since(n0).length, 0, 2);
await runBackfill({ connectionId: conn1, object: "form_submission", from: "2026-09-15" });
expect("backfill: form submissions from an earlier date fill the older one", (await q("select contact_resolution from cma.form_submission where connection_id = $1 and source_id = 'c-0001'", [conn1]))[0]?.contact_resolution, "resolved", null);
let usage = null;
try {
  await runBackfill({ connectionId: conn1, object: "commerce_order" });
} catch (err) {
  usage = err instanceof UsageError;
}
expect("backfill: an object the adapter does not backfill is refused", usage, true, null);

// ---- D. The reconcile ----------------------------------------------------------------------------
fake.objects.deals[4130000001] = { ...fake.objects.deals[4130000001], amount: "250", hs_lastmodifieddate: isoAgo(60) };
fake.objects.deals[4130000003] = { ...fake.objects.deals[4130000003], amount: "333", hs_lastmodifieddate: isoAgo(30) };
await recordEvents(ctx1, conn1, [{ ...created(4130000003), kind: "changed", sourceType: "object.propertyChange" }]);
await sweep();
expect("reconcile: setup, the webhook's newer read of a deal stored", (await deal(4130000003))?.amount, "333.00", "300.00");
fake.objects.deals[4130000003] = { ...fake.objects.deals[4130000003], amount: "999", hs_lastmodifieddate: isoAgo(40) };
fake.objects.contacts[4300000001].contact_country = "uk";
n0 = mark();
const r1 = await runReconcile({ connectionId: conn1 });
expect("reconcile: the change the webhook missed arrives", (await deal(4130000001))?.amount, "250.00", "100.00");
expect("reconcile: a newer row is left alone (stale)", (await deal(4130000003))?.amount, "333.00", "999.00");
const recRuns = await runs("reconcile");
expect("reconcile: one run per object type, all succeeded", recRuns.map((r) => [r.stream, r.status]), [["deal", "succeeded"], ["ticket", "succeeded"], ["crm_call", "succeeded"], ["contact", "succeeded"]], []);
expect("reconcile: the stale read counted", (recRuns.find((r) => r.stream === "deal")?.counts.stale ?? 0) >= 1, true, false);
const lookback = since(n0).find((r) => r.search)?.body.filterGroups[0].filters[0].value;
expect("reconcile: the default look-back is 26 hours", Math.abs(Number(lookback) - (Date.now() - 26 * 3600_000)) < 120_000, true, false);
const contactReads = since(n0).filter((r) => r.path === "/crm/v3/objects/contacts/batch/read").flatMap((r) => r.body.inputs.map((i) => String(i.id)));
expect("reconcile: only held contacts are read", [contactReads.includes("4300000001"), contactReads.includes("4399999999")], [true, false], [true, true]);
expect("reconcile: the unheld contact counted as skipped", recRuns.find((r) => r.stream === "contact")?.counts.skipped >= 1, true, false);
expect("reconcile: the run's totals", [r1.runs, r1.failed], [4, 0], [3, 1]);
n0 = mark();
const r2 = await runReconcile({ connectionId: conn1 });
expect("reconcile: a second run lists the same and reads nothing again", [r2.fetched > 0, r2.upserted, since(n0).filter((r) => r.path.endsWith("/batch/read")).length], [true, 0, 0], [true, 1, 1]);
n0 = mark();
await runReconcile({ connectionId: conn1, lookbackMinutes: 10, object: "deal" });
const short = since(n0).find((r) => r.search)?.body.filterGroups[0].filters[0].value;
expect("reconcile: --lookback-minutes 10 asks the last ten minutes, one object type", [Math.abs(Number(short) - (Date.now() - 10 * 60_000)) < 60_000, (await runs("reconcile")).length], [true, 9], [false, 8]);

// ---- E. Tenant isolation -------------------------------------------------------------------------
await recordEvents(ctx2, conn2, [created(4140000001, "9000102")]);
n0 = mark();
await runSweep({});
expect("isolation: an unfiltered sweep serves tenant two's due event", (await eventOf(4140000001, conn2))?.status, "processed", "received");
expect("isolation: …read with tenant two's token", since(n0).filter((r) => r.path === "/crm/v3/objects/deals/batch/read" && r.body.inputs.some((i) => String(i.id) === "4140000001")).every((r) => r.auth === `Bearer ${TOKEN2}`), true, false);
expect("isolation: tenant two's record and run rows live in tenant two", [(await q("select tenant_id from cma.crm_record where connection_id = $1", [conn2])).map((r) => r.tenant_id),
  [...new Set((await q("select tenant_id from cma.sync_run where connection_id = $1", [conn2])).map((r) => r.tenant_id))]], [[t2], [t2]], [[t1], [t1]]);
expect("isolation: tenant one sees none of tenant two's runs or cursors", await asAdmin(t1, async () => [
  Number((await q("select count(*) as n from cma.sync_run where connection_id = $1", [conn2]))[0].n),
  Number((await q("select count(*) as n from cma.ingest_event where connection_id = $1", [conn2]))[0].n)]), [0, 0], [1, 1]);
expect("isolation: the tenant one's requests all carried tenant one's token", fake.requests.filter((r) => r.auth !== `Bearer ${TOKEN2}`).every((r) => r.auth === `Bearer ${TOKEN1}`), true, false);

// ---- F. What was written and logged ----------------------------------------------------------------
const dbText = JSON.stringify(await q(`select row_to_json(x)::text as r from cma.form_submission x where connection_id = $1
  union all select row_to_json(x)::text from cma.sync_cursor x where connection_id = $1
  union all select row_to_json(x)::text from cma.sync_run x where connection_id = $1
  union all select row_to_json(x)::text from cma.ingest_event x where connection_id = $1
  union all select row_to_json(x)::text from cma.crm_contact x where connection_id = $1
  union all select row_to_json(x)::text from cma.connection_form x where connection_id = $1`, [conn1]));
expect("no email in the submissions, cursors, runs, events, contacts or forms", /@example\.com/.test(dbText), false, true);
const logText = logs.join("\n");
expect("the logs hold no email, token or contact id", [/@example\.com/.test(logText), logText.includes("fixture-jobs-token"), logText.includes("4300000001")], [false, false, false], [true, true, true]);
expect("the logs hold the jobs' counts", logs.some((l) => JSON.parse(l).message === "reconcile") && logs.some((l) => JSON.parse(l).message === "sweep"), true, false);

// This run's connections stop being served (a later run's unfiltered sweep leaves them alone)
await asAdmin(t1, () => q("select cma.set_connection_status($1, 'inactive')", [conn1]));
await asAdmin(t2, () => q("select cma.set_connection_status($1, 'inactive')", [conn2]));
await admin.end();
await new Promise((r) => fakeServer.close(r));
await closeDb();
rmSync(secretsDir, { recursive: true, force: true });
verdict();
