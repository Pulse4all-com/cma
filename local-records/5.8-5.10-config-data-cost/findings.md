# Audit 17 October 2026: areas 5.8 (configurability, multi-tenancy, source of truth), 5.9 (data protection), 5.10 (cost)

Examined: `web/src`, `web/jobs`, `ingest/src`, `tools/`, `hubspot/`, `db/*.sql`, `docs/ingest/README.md`, `docs/ingest/deploy.sh`, `cloudbuild.yaml`, `docs/nocodb/service.template.yaml`, `records/` (patterns and counts only), `docs/datamap/`, against README "Guiding principles" (lines 37-49), "Business lines, databases and tenants" (66-82), the Architecture bullets on adapters and the mirror, "Environments and infrastructure" (134-167), "Source of truth" (1220-1252), the Decision log and Open decisions (2008 onward), and `local-records/readme-index/decisions-index.md`.
How: static review with grep and targeted reads (file:line below), plus observed checks on the local PostgreSQL (setting catalog, `cma_read.audit_log` columns, the raw filters fed a nested payload with an address and a phone-shaped string). No network, no cloud, nothing written outside this file and /var/tmp/5.8/. About 1 hour 30 minutes.
Most important: the code is clean of vendor and business-line specifics outside adapters, seeds, mock and copy labels (zero `hubspot`/`shopify` hits in `web/src`, zero vendor values in any migration function body, one HubSpot writer behind the outbox, a stale guard in every mirror upsert, every web and ingest query inside a tenant context). The findings are hygiene and defence in depth: the hardcoded 10-minute outbox threshold (CMA-039, four places found, diff below), the per-process pace sentence (CMA-040, corrected sentence below), `cma.telephony_raw` not stripping strings holding `@` as its two siblings do (observed), the mirror's slot-to-property mapping taking any property name, staff-domain addresses as verifier defaults in a public repository (already open), and cost figures for the lead's PERFORMANCE.md (estimates, prices stated).
Line numbers: every `file:line` refers to the committed tree, `main` at `35ea3e0` (17 October 2026). While this review ran, the working tree gained uncommitted edits by the lead in `web/src/lib/copy.ts` (+198 lines) and `web/src/lib/data/postgres.ts` (+48 lines), which shift later lines there (for example `fix_outbox_pending` sits at 666 and 2589 in the working tree, `OUTBOX_LATE_MINUTES` in postgres.ts at 20 and 1760); the CFG-01 diff hunks are against the committed lines.
Severity count: Critical 0, High 0, Medium 0, Low 4 (CFG-01, DP-01, DP-02, DP-03), Info 7 (CFG-02, CFG-03, DP-04, DP-05, COST-01, COST-02, COST-03).
Nothing here needs a fix before the report; nothing was fixed (subagent rules).

---

## 5.8 Configurability, multi-tenancy and source of truth

### CFG-01: The outbox "late" threshold of 10 minutes is hardcoded in four places (CMA-039)
- Severity: Low   Confidence: High   Effort: M (a setting row needs a migration pair; the code changes are S)
- Component: `ingest/src/jobs/sweep.mjs`, `web/src/lib/reports.ts`, `web/src/lib/data/postgres.ts`, `web/src/lib/copy.ts`
- Evidence (all four places, as the task asked):
  1. `ingest/src/jobs/sweep.mjs:36` `export const OUTBOX_LATE = "10 minutes";` used at `:107` (`outboxLate(OUTBOX_LATE, connectionId)`; the store's query at `ingest/src/core/store.mjs:329-338` takes it as an interval).
  2. `web/src/lib/reports.ts:238` `export const OUTBOX_LATE_MINUTES = 10;`, interpolated into the check's English description at `:244`; consumed by `web/src/lib/data/postgres.ts:19` (import) and `:1753-1760` (`make_interval(mins => $1)` with `[OUTBOX_LATE_MINUTES]`).
  3. `web/src/lib/copy.ts:665` (EN) `fix_outbox_pending: "Updates still waiting 10 minutes after they were due: ..."`.
  4. `web/src/lib/copy.ts:2486` (NL) `fix_outbox_pending: "Updates die 10 minuten na hun tijd nog wachten: ..."`.
  Rendered by `web/src/app/reports/data-quality/page.tsx:15` (`t[\`fix_${c.key}\`]`, no substitution). The database holds no such setting: observed on the local database, `select key from cma.setting where key like 'outbox%'` returns only `outbox.max_attempts` (added by `db/38_outbox.sql:75`, read by its functions at `:487` and `:561` through `cma.tenant_settings()`; the pattern to follow).
- Impact (in this system's context): a tenant whose outbox runs on a slower cadence (ingest-outbox has no schedule since 0008h; a scheduled run every 15 minutes would make every action "late" for 5 minutes) cannot change the threshold without a deploy, and the sweep and the Data quality page can drift apart if one place is edited and not the other. Guiding principle 1 ("thresholds are tenant configuration").
- Recommendation: the tenant setting `outbox.late_minutes` (integer, default 10), read by the sweep through the store's `settings()` and by the web through `cma.tenant_settings()`; the copy drops the number. Exact proposal (not applied: the setting row is a migration, rule 4; the code is otherwise trivial):

  **File** `db/76_outbox_late_setting.sql` (0008q, with `db/77_verify_outbox_late_setting.sql`; the personal-login guard, `set role cma_owner`, the `schema_migration` row, all per README "Conventions for every migration"; `docs/datamap/catalog.json` untouched since no table changes):
  ```sql
  insert into cma.setting (key, value_type, allowed_values, default_value, description) values
    ('outbox.late_minutes', 'integer', null, '10',
       'Minutes after an outbox action fell due before the sweep and Data quality count it as not delivered')
  on conflict (key) do update
    set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
        default_value = excluded.default_value, description = excluded.description;
  ```
  ```diff
  --- a/ingest/src/jobs/sweep.mjs
  +++ b/ingest/src/jobs/sweep.mjs
  @@ -35,2 +35,9 @@
   const REREAD_EVERY_MS = 10 * 60_000;
  -export const OUTBOX_LATE = "10 minutes";
  +export const OUTBOX_LATE_DEFAULT_MINUTES = 10;
  +/** The tenant's outbox.late_minutes (integer setting, default 10) as the interval the store's query takes */
  +export function outboxLateOf(settings) {
  +  const n = Number(settings?.["outbox.late_minutes"]);
  +  return `${Number.isInteger(n) && n > 0 ? n : OUTBOX_LATE_DEFAULT_MINUTES} minutes`;
  +}
  @@ -106,3 +113,4 @@
       try {
  -      const late = await storeFor(contextOf(c), c.connectionId).outboxLate(OUTBOX_LATE, connectionId);
  +      const store = storeFor(contextOf(c), c.connectionId);
  +      const late = await store.outboxLate(outboxLateOf(await store.settings()), connectionId);
  ```
  ```diff
  --- a/web/src/lib/reports.ts
  +++ b/web/src/lib/reports.ts
  @@ -237,5 +237,6 @@
   export const OUTBOX_PENDING_CHECK = "outbox_pending";
  -export const OUTBOX_LATE_MINUTES = 10;
  +export const OUTBOX_LATE_SETTING = "outbox.late_minutes";
  +export const OUTBOX_LATE_DEFAULT_MINUTES = 10;

  -export function withOutboxPending(checks: DataQualityCheck[], pending: number): DataQualityCheck[] {
  +export function withOutboxPending(checks: DataQualityCheck[], pending: number, lateMinutes = OUTBOX_LATE_DEFAULT_MINUTES): DataQualityCheck[] {
  @@ -244 +245 @@
  -    description: `Outbox actions not delivered ${OUTBOX_LATE_MINUTES} minutes after they fell due (ingest-outbox unscheduled or not running)`,
  +    description: `Outbox actions not delivered ${lateMinutes} minutes after they fell due (ingest-outbox unscheduled or not running)`,
  ```
  ```diff
  --- a/web/src/lib/data/postgres.ts
  +++ b/web/src/lib/data/postgres.ts
  @@ -19 +19 @@
  -import { OUTBOX_LATE_MINUTES, applyConnections, previousPeriod, rangeProblem, withOutboxPending, type IntakeCounts } from "@/lib/reports";
  +import { OUTBOX_LATE_DEFAULT_MINUTES, OUTBOX_LATE_SETTING, applyConnections, previousPeriod, rangeProblem, withOutboxPending, type IntakeCounts } from "@/lib/reports";
  @@ -1751,4 +1751,7 @@
         // The outbox guard (brief A5), read after cma.data_quality() checked the permission; the same
  -      // definition as the sweep's (ingest store, outboxLate)
  +      // definition as the sweep's (ingest store, outboxLate), with the tenant's outbox.late_minutes
  +      const late = await q.query<{ value: string | null }>(`select value from cma.tenant_settings() where key = $1`, [OUTBOX_LATE_SETTING]);
  +      const lateMinutes = Number(late.rows[0]?.value) > 0 ? Number(late.rows[0]?.value) : OUTBOX_LATE_DEFAULT_MINUTES;
         const o = await q.query<{ n: number }>(
  @@ -1759,2 +1762,2 @@
  -        [OUTBOX_LATE_MINUTES]);
  -      return withOutboxPending(r.rows.map((x) => ({ key: x.check_key, description: x.description, total: x.total })), o.rows[0]?.n ?? 0);
  +        [lateMinutes]);
  +      return withOutboxPending(r.rows.map((x) => ({ key: x.check_key, description: x.description, total: x.total })), o.rows[0]?.n ?? 0, lateMinutes);
  ```
  ```diff
  --- a/web/src/lib/copy.ts
  +++ b/web/src/lib/copy.ts
  @@ -665 +665 @@
  -    fix_outbox_pending: "Updates still waiting 10 minutes after they were due: the job that sends them (ingest-outbox) has no schedule or is not running; an admin checks it",
  +    fix_outbox_pending: "Updates still waiting past the tenant's outbox delay after they were due: the job that sends them (ingest-outbox) has no schedule or is not running; an admin checks it",
  @@ -2486 +2486 @@
  -    fix_outbox_pending: "Updates die 10 minuten na hun tijd nog wachten: de taak die ze verstuurt (ingest-outbox) heeft geen schema of draait niet; een beheerder controleert hem",
  +    fix_outbox_pending: "Updates die na de wachttijd van de organisatie nog niet verstuurd zijn: de taak die ze verstuurt (ingest-outbox) heeft geen schema of draait niet; een beheerder controleert hem",
  ```
  The wording follows the style's tone (plain, no number that can go stale); the lead or Martin may prefer the number in the description row (already dynamic above) and a shorter fix line. `verify:dashboard`/`verify:copy` and `ingest/verify/jobs-flow.mjs` need a run after the change (the sweep's guard is exercised there, "outbox_pending"). Importers of the old constants: `web/src/lib/data/postgres.ts:19,1759` and `sweep.mjs:107` only (`web/verify`, `mock.ts`, `ingest/verify` do not reference them).
- README check: already open (backlog CMA-039; Open decisions, the bullet "the sweep's outbox guard (13 October 2026) warns, and Data quality shows the count, when an action waits ten minutes past its due time").
- Disproof attempt: looked for an existing setting (`cma.setting` on the local database: none), for a shared constant between web and ingest (none: two services, two constants and two copy strings), and whether the number in copy is substituted at render time (`data-quality/page.tsx:15`: it is not). Stands.

### CFG-02: `docs/ingest/README.md` promises the Aircall pace "stays under 120 a minute", which holds only for two processes (CMA-040)
- Severity: Info (5.2 assesses the mechanism; this is the wording)   Confidence: High   Effort: S
- Component: `docs/ingest/README.md:240` (last sentence of the Aircall rate-limit paragraph)
- Evidence: the sentence reads "The pace is per process: the service and a job running at the same time can each use the limit, which stays under Aircall's 120 while the setting is 60 or less." The pace is created per connection per process at `ingest/src/adapters/aircall/read.mjs:66-75` (`paces` Map, `new Pace(60_000 / perMinute)`), the setting `aircall_max_per_minute` read at `:61`. In prod the service runs up to 5 instances (`docs/ingest/deploy.sh:98` `MAX=5`), and the sweep (every minute, `deploy.sh:48`), the reconcile (`:53`) and a backfill (`:60`) are separate Cloud Run job executions, each its own process: up to 8 processes, each pacing itself to 60 a minute. The paragraph's own words earlier say the limit is per API key, and that three other integrations share the key.
- Impact: a reader sizes the setting on the promise "under 120" and is surprised by a 429 during a backfill while the service is busy; nothing breaks (the 429 handling and `holdUntil` are in place, `pace.mjs:28-30`), but the documentation overstates the guarantee.
- Recommendation: replace the sentence with: "The pace is per connection and per process, not per account: the service (up to five instances in prod) and each job that runs at the same time (sweep, reconcile, backfill) keep their own pace, so the account can see several times the setting in a minute while they overlap. Aircall's 429 then holds every process until `X-AircallApi-Reset`; set `aircall_max_per_minute` for the key's whole use (the other integrations included) divided by the processes that may run at once, or keep the default 60 and accept a short hold during a backfill."
- README check: already open (backlog CMA-040).
- Disproof attempt: checked whether the pace is shared through the database or a cache (no: an in-memory Map per process, `read.mjs:66`), and whether `--max-instances` for the service is 1 in prod (no: 5).

### CFG-03: Second-CRM touch points and what would stop a copy from running on configuration alone (observation)
- Severity: Info   Confidence: High   Effort: n/a
- Component: `ingest/src/adapters/index.mjs`, `ingest/src/adapters/*/index.mjs`, `ingest/src/core/*`, `web/src/proxy.ts`
- Evidence:
  - Adapter interface, from `ingest/src/adapters/hubspot/index.mjs:30-61`, `aircall/index.mjs:17-39`, `shopify/index.mjs:32-55`, `automation/index.mjs:56-75`: `name`, `authenticate`, `mapRequest`, `readBack`, `holdsRecords`, `rates`, optional `pollForms`/`pollEmail`/`emailPollEnabled`, `reconcileObjects`/`reconcileObjectsOf`/`reconcile`, `backfillObjects`/`backfill`/`backfillFrom`, `crm.{findContactsByEmail, findContactsByProperties, existingContacts}` (used by the Shopify match), `writeContacts` (the outbox), `readbackBudgetMs` (Shopify), `refreshCatalogs` (Aircall), `kind: "messages"` + `parseMessages`/`send` (automation). Registration is one line, `adapters/index.mjs:11`.
  - Core and jobs treat adapters generically: `jobs/outbox.mjs:32` `if (!adapter?.writeContacts) continue;`, `jobs/poll-forms.mjs`, `jobs/poll-email.mjs`, `server.mjs:121` (`adapter.readbackBudgetMs ? ... : readbackBudgetMs()`). Grep for `hubspot|aircall|shopify|hs_|dealstage|hubspot_owner_id|X-Shopify|hubapi` in `ingest/src/core`, `ingest/src/jobs`, `ingest/src/server.mjs` outside comments: zero hits. The HubSpot property names live only in `adapters/hubspot/map.mjs` (`CALL_PROPERTIES :155`, `TASK_PROPERTIES :161`, `RECORD_KEYS :164`).
  - Two small vendor shapes in shared code: `ingest/src/core/http.mjs:59-60` treats HTTP 207 as success for every source ("HubSpot's multi-status"); harmless for Aircall and Shopify today, but a non-HubSpot source answering 207 with an error body would pass as success. `ingest/src/server.mjs:22` names `INGEST_SHOPIFY_READBACK_BUDGET_MS` in a comment only; the value is resolved through the adapter hook.
  - Database: grep for `'hubspot'|'aircall'|'shopify'|hubspot_owner_id|hs_|dealstage|'google'` in `db/*.sql` outside `02/03/06/24` seeds, verify scripts and comments: zero hits. Record links are built per connection from a template (`cma.record_url(connection_id, type, source_id)`, used at `web/src/lib/data/postgres.ts:1708` and `:1791`; the `record_url_call` setting is an Open decision).
  - Web: zero `hubspot`/`shopify` hits in `web/src`; `aircall` only in three doc comments; the adapter name shown as data (`SourceConfig.tsx:216` `<dd>{conn.adapter}</dd>`); `nav.ts` and `copy.ts` hold no vendor logic (copy names "CRM", "telephony system", "customer records").
  - What a copy on configuration alone still cannot change: (a) the login provider, `web/src/proxy.ts:32` `IAP_PROVIDER = "google"` and `web/src/app/team/people/page.tsx:73` (settled: Decision log 4 October 2026, Google Workspace through IAP); (b) the brand: `web/src/components/Shell.tsx:77` logo alt "Pulse4all", `web/src/app/roster/planner/print/page.tsx:69`, `web/src/lib/copy.ts:15,1836` tagline, `:1784,3605` "Your Pulse4all account is recognised" (per-tenant theme and copy are an Open decision); (c) a CRM other than HubSpot needs a new adapter type (code), which is principle 1 by design, not a finding. A second Pulse4all business line on HubSpot plus Aircall runs on configuration alone (connection rows, secrets by name, field slots, settings), as README promises.
- Impact: none today; the interface is small and the leak points are two lines.
- Recommendation: (optional, S) move the 207 acceptance into the HubSpot adapter's `call` wrapper (`adapters/hubspot/read.mjs`) or pass an `acceptStatuses` option to `requestJson`, so `http.mjs` stays vendor-neutral. No other action.
- README check: settled (Guiding principles 1 and 6; Architecture "Adapters and the canonical model"; Decision log 4 October 2026 for IAP).
- Disproof attempt: searched for pipeline names, portal ids (8-9 digit literals), `Self Serve`, `Subscriptions`, `Invest`, `Newco`, market codes and currency codes in logic across `web/src`, `web/jobs`, `ingest/src`, `tools/`: hits only in mock data (`web/src/lib/data/mock.ts`, `web/src/lib/auth/identity.ts:90-99`), copy examples, verifiers and the Shopify adapter's `.myshopify.com` host check (`shopify/client.mjs:30`, adapter-internal and correct).

---

## 5.9 Data protection

### DP-01: `cma.telephony_raw` keeps string values that hold an `@`, unlike `cma.email_raw` and `cma.task_raw`
- Severity: Low   Confidence: High (observed)   Effort: S (code), but a new migration pair (0008q)
- Component: `db/34_telephony.sql:254-273` (`cma.telephony_raw`)
- Evidence: observed on the local database: `select cma.telephony_raw('{"status":"done","duration":12,"user":{"email":"a@b.c"},"tags":["x"],"login":"someone@example.com","ref":"+44 20 0000 0001","started_at":1700000000}')` returns `{"login": "someone@example.com", "status": "done", "duration": 12, "started_at": 1700000000}`: nested objects and arrays dropped (good), the phone-shaped string dropped (good), the address kept because the key `login` matches no denied name and the function has no `@` test. The same payload shape through `cma.email_raw` (`db/68_email_activity.sql:475-495`, `strpos(e.value #>> '{}', '@') = 0`) and `cma.task_raw` (`db/70_crm_tasks.sql:83-108`, `!~ '@'`) drops it (observed for `email_raw`: `{"hs_timestamp": ..., "hs_email_status": "SENT"}`). The first line of defence holds: the Aircall adapter sends an allowlist of eight keys (`ingest/src/adapters/aircall/map.mjs:33` `RAW_KEYS`, `:108-114` `rawOf`), none of which carries an address.
- Impact: defence in depth only. A future adapter change or a replayed payload with a new key could land an email address in `cma.telephony_call.raw` and in the audit log's images, which the retention job (CMA-003) does not yet clear. No path does so today.
- Recommendation: new pair `db/76_telephony_raw_at.sql` / `db/77_verify_telephony_raw_at.sql` (0008q; or folded into the same 0008q as CFG-01 if both go) that `create or replace function cma.telephony_raw(jsonb)` with one added condition after the length test:
  ```sql
                       and length(e.value #>> '{}') <= 200
  +                    and strpos(e.value #>> '{}', '@') = 0
                       and not ((e.value #>> '{}') ~ '^\+?[0-9 ().-]{7,20}$' and (e.value #>> '{}') !~ '^\d{4}-\d{2}-\d{2}')))
  ```
  The verify script feeds the payload above with and without `verify.provoke` and expects no key whose value holds `@`.
- README check: new (the 0007a comment at `db/34_telephony.sql:248-253` describes the deny list without the `@` rule; the 0008m and 0008n filters added it).
- Disproof attempt: checked whether the adapter could send such a key (no: fixed allowlist), whether the ingest upsert filters before the function (no: `db/34_telephony.sql:296` passes `raw` to `cma.telephony_raw` as the only filter), and whether `telephony_call.raw` reaches readers (`cma_read.telephony_call` is the explicit-column view of 0007a; not checked column by column, see "Not checked"). Stands as defence in depth.

### DP-02: The mirror's slot-to-property mapping takes any CRM property name; no second line refuses a personal one
- Severity: Low   Confidence: High   Effort: S
- Component: `db/32_intake_core.sql:251-258` (`cma.connection_field` slot check), `ingest/src/adapters/hubspot/map.mjs:173-179, 195-199, 220, 246`, `web/src/lib/api/configuration.ts`, `db/52_sources_configuration.sql`
- Evidence: the mirror's `raw` for deals, tickets and contacts is `pick(properties, propertiesFor(entity, config))` (`map.mjs:220`, `:246`): the standard properties plus every property an admin mapped to a slot on Configuration → Sources. The slots are a fixed, non-personal set (`market, language, country, currency, store, amount, source_channel, category, ref`; `db/32:251-256`, tightened in `db/68:452-453`), but the property mapped to a slot is free text: grep for `email|firstname|lastname|phone|personal|deny` in `web/src/lib/api/configuration.ts` and `db/52_sources_configuration.sql` finds no screen on the property name. `cma.ingest_upsert_records` (`db/32:1056-1157`) and `cma.ingest_upsert_contacts` (`db/70:450-580`) store `r -> 'raw'` as given, with no filter function like the three later ones.
- Impact: an admin who maps, say, slot `ref` to the property `email` (a plausible slip when looking for "the Shopify customer id") would mirror addresses into `cma.crm_record.raw`/`cma.crm_contact.raw` and the audit log, against README "Mirror of customer data" and the one-year retention that has no job yet (CMA-003). The UI never shows `raw`, so exposure would be in the database and its images only. Configuration misuse, not a bug; but the database is the place that cannot be bypassed.
- Recommendation: a check in the function that writes `cma.connection_field` (db/52's set-fields function) refusing a property whose name matches `(^|_)(email|e_mail|phone|mobile|firstname|lastname|first_name|last_name|address|street|zip|postal|ip_address)` with `CMA04`, mirrored as a 400 in `web/src/lib/api/configuration.ts` with a copy string, so the refusal is explained on the screen. A new migration pair (0008q) and one web PR. Alternative or in addition: a `cma.record_raw(jsonb)` filter on the 0007 path like the three later ones.
- README check: new; related to Open decisions on retention of the customer-field mirror ("Retention of staff data, the audit log and the customer-field mirror").
- Disproof attempt: checked whether the HubSpot adapter restricts properties to a catalog (no: `fieldsOf(config, entity)` is the admin's list) and whether `connection_field.property` carries a check constraint on its content (none found in `db/32`). Stands.

### DP-03: Verifiers default to a real staff address, and the roles bootstrap grants to personal logins, in a public repository
- Severity: Low   Confidence: High   Effort: S
- Component: `ingest/verify/flow.mjs:7,42` (default of `INGEST_FLOW_ADMIN_USER`), `ingest/verify/{aircall,email,jobs,outbox,shopify}-flow.mjs` (same pattern, lines 7-10 and 39-54), `web/verify/iap-token.mjs:30,51,64,65` (a staff address with `hd: "pulse4all.com"` in the mock IAP token and the assertions), `db/00_roles.sql:62-64` and the comment at `:72-74` (IAM login names), `db/12_verify_team_people.sql:72`
- Evidence: 18 occurrences of `@pulse4all.com` across `web/verify`, `ingest/verify` and `db/`, all one person's work address by shape (first-name local part; the value is not written here). Fixtures, mock and seeds otherwise use `example.com/.net/.org/.invalid` (176 + 12 + 7 + 10 occurrences) and phone numbers in `+44 20 0000 xxxx` (the reserved drama range) and `+31 20 000 xxxx`; `tools/fixtures/*.csv` hold "Test Account A/B" with `example.com` addresses.
- Impact: a staff member's work address is personal data in a public repository (Decision log 8 October 2026 accepts the repository being public until launch; Open decisions already lists that the README and `records/` name staff and asks Yordi). The `db/00_roles.sql` grants are the Cloud SQL IAM login names and are by design (README "Three group roles, SET ROLE"); the verifier defaults are not needed as real addresses: the verifier only needs an address whose domain passes the `hd` check or matches a seeded person.
- Recommendation: in the six ingest verifiers, default `INGEST_FLOW_ADMIN_USER` to `admin@example.com` (the dev seed's admin, `web/src/lib/data/mock.ts:1063`) or `verify-admin@example.invalid` if the flow only needs any value; in `web/verify/iap-token.mjs`, use a fictional local part (the check is on `hd`, not on the local part) and change fixture and assertions together. Leave `db/00_roles.sql` as decided, or fold it into CMA-038 (make the repository private now).
- README check: already open (Open decisions "While it is public, the README and records/ name staff"; backlog CMA-038).
- Disproof attempt: checked that the addresses are not role accounts (`cma@`, `ingest@`: none of the 18) and not needed by the tests' logic (the IAP verifier asserts on `hd` and on the body containing the email string, so any fictional address works once the fixture and the assertion change together).

### DP-04: `records/` holds one staff-domain address in 11 of 417 files, no 20- or 21-digit identifiers, and the screenshots show mock or console data (observation)
- Severity: Info   Confidence: High   Effort: n/a
- Component: `records/`
- Evidence (counts only): files total 417; files matching `@pulse4all.com` 11 (folders `account-2026-10-09` 2, `0003d-dev-2026-10-07` 2, `status-list-dev-2026-10-07`, `nocodb-pools-prod-2026-10-15`, `b17b-dev-2026-10-16`, `api-prod-2026-10-05`, `0008m-prod-2026-10-15`, `0008m-dev-2026-10-15`, `0008i-prod-2026-10-14` 1 each); distinct local parts 1 (the owner's own address, by shape); files with a 21-digit number 0, with a 20-digit number 0 (the one 21-digit literal in the repository is a synthetic fixture in `db/67_verify_invitations.sql:348`, starting `8000…`). PNGs: `records/layout` 40 (written by `web/verify/layout.mjs:58,105` in mock mode, `x-cma-mock-subject` headers), `records/0002-dev-2026-10-05` 27, `records/0002-prod-2026-10-05` 14, `records/web-prod-2026-10-05` 4, `records/0003-prod-2026-10-06` 1. Viewed two: `web-prod-2026-10-05/1280x800.png` shows the mock Workspace ("Agent One · Newco", "Test data: nothing you do here is saved"); `0002-prod-2026-10-05/Screenshot 2026-10-05 11.09.20.png` shows Cloud SQL Studio on `cma-prod-pg` with a verification query and table names, no personal data beyond the console's avatar.
- Impact: as Open decisions already states, the public repository names staff in `records/` (one address, first names in verify outputs); customer data and Google ids are absent.
- Recommendation: none beyond CMA-038 and the Yordi question already open. The data map (`docs/datamap/index.html`) fetches `schema.json` (keys `generated_at`, `latest_migration`, `columns`: names only) and `catalog.json`; no values, no addresses (grep: none).
- README check: already open (Open decisions; Decision log 8 October 2026; CMA-038).
- Disproof attempt: grep for `@pulse4all.com` and for 20/21-digit runs across `records/`, `docs/`, `README.md`, `db/`, `web/src`, `ingest/src`; only the synthetic fixture surfaced outside `records/`.

### DP-05: Web logging and client errors carry no personal data; one 5xx log line echoes the driver's message (observation)
- Severity: Info   Confidence: High   Effort: S
- Component: `web/src/lib/api/respond.ts:60-67`, `web/src/proxy.ts:58`, `web/src/lib/auth/identity.ts:138`, `web/src/lib/data/postgres.ts:796`, `web/jobs/close-forgotten-workdays.mjs:74,92,96`
- Evidence: eleven `console.*` calls in `web/src` and `web/jobs`; each logs a code, a count, a tenant id, a slug, a business date or an error message. `respond.ts:63` logs `e.detail ?? e.message` for 5xx `CmaDbError`s, where `detail` is the PostgreSQL driver message (`web/src/lib/db/client.ts:68,75,77`): a message such as `invalid input syntax for type …: "<value>"` can echo an input literal into Cloud Logging (30-day `_Default` bucket, Decision log 12 October 2026). The client receives `e.message`, the stable CMA text (`CMA_SQLSTATE` map), never `detail`. All 107 `new ApiError(` messages interpolate field names and limits only (`team/directory/route.ts:21`, `configuration.ts:23,124,134,167,312`, `respond.ts:103,112,157`), never a value. Query parameters read anywhere in `web/src`: `group, userId, from, to, market, value, team, since, line, limit, form, field, category` (and the mock-only `?as=`); `value` on `/api/v1/reports/forms/answers` is a choice option, enforced in the database (`db/74_forms_reporting.sql:20-23,104-106`: "Never free text"). Dynamic segments: ids, keys, dates, `[token]` on `/invite` (5.1 assesses). `cma_read.audit_log` exposes no row images (observed: columns `id, tenant_id, table_name, action, row_id, changed_at, actor_user_id, actor_label, actor_db_role, actor_login`). The exports return `display_name, organisation_name, status_name` (`db/13_tenant_settings.sql:164-216`), no login id or address.
- Impact: none observed; the one echo path needs a malformed literal that passed the API's own validation, which the UUID, date and range parsers (`respond.ts:103-157`) make unlikely.
- Recommendation: optional: log `e.detail` only for `DB_UNAVAILABLE` (connection errors, no literals) and the message for `DB_ERROR`; or truncate `detail` at the first quote. Not worth a PR on its own.
- README check: settled (Decision log 12 October 2026 on log retention; the CMA UI shows ids, statuses and links only).
- Disproof attempt: looked for `console.log(` of request bodies, identities or `sub` values (none), for error responses built from input (none), and for a route with an email or a name in a path or query (none).

---

## 5.10 Cost and efficiency (estimates; public list prices assumed and stated; budget review itself is CMA-034)

Assumed prices (europe-west4, Tier 1 region, list prices as I know them; estimates, to be read from the pricing calculator by Martin): Cloud Run request-based billing: CPU $0.000024 per vCPU-second and memory $0.0000025 per GiB-second while a request is served; an idle instance kept by `min-instances` is billed at the idle rate, CPU $0.0000025 per vCPU-second and memory $0.0000025 per GiB-second; a Cloud Run job bills CPU and memory for the task's wall time at the active rate; free tier 180,000 vCPU-seconds and 360,000 GiB-seconds a month per billing account. Cloud SQL Enterprise: about $0.0413 per vCPU-hour and $0.0070 per GiB-hour, doubled for high availability, plus SSD storage about $0.187 per GB-month (doubled with HA). Global external Application Load Balancer: $0.025 per forwarding-rule hour (first five rules) plus $0.008 per GB processed. One month taken as 730 hours = 2,628,000 seconds.

### COST-01: Prod runs close to its €150 budget alert on the current shape; no clear waste, no clear under-provisioning
- Severity: Info   Confidence: Medium (estimates)   Effort: n/a
- Component: README "Environments and infrastructure"; `docs/ingest/deploy.sh:98,230,307-310`; `cloudbuild.yaml:57-69`; `docs/nocodb/service.template.yaml:18-20,31-33,86-87`
- Evidence and estimate per item (monthly):
  - Cloud SQL `cma-prod-pg`, `db-custom-1-3840` with HA (README, Decision log 7 October 2026): 1 vCPU × 730 × $0.0413 = $30.1; 3.75 GiB × 730 × $0.0070 = $19.2; × 2 for HA = $98.6; storage 10 GB × $0.187 × 2 ≈ $3.7: about **$102**, matching README's "roughly $100 for the pair".
  - Load balancer for `workspace.pulse4all.app`: 730 × $0.025 = $18.25 plus a few cents of data: about **€18**, as README says.
  - `cma-web` `min-instances=1` (set 12 October 2026; `cloudbuild.yaml` passes no `--min-instances`, `--cpu` or `--memory`, so the deploy keeps the service's existing values; defaults 1 vCPU, 512 MiB): idle 2,628,000 × (1 × $0.0000025 + 0.5 × $0.0000025) = **about $9.9**, plus request time (small at today's volume).
  - `cma-ingest` `MIN=1, MAX=5`, 1 vCPU, 512 MiB, `--cpu-boost` (`deploy.sh:98,307-310`): idle **about $9.9**, plus request time.
  - The three per-minute jobs (`ingest-sweep`, `ingest-poll-forms`, `ingest-poll-email`, `deploy.sh:48-52`), 1 vCPU and 512 MiB each (`deploy.sh:230`): see COST-02, **about $9 to $13**.
  - NocoDB (`service.template.yaml`): `minScale 0`, `maxScale 1`, `cpu-throttling true`, 1 vCPU/2 GiB plus the proxy sidecar 0.5 vCPU/256 MiB: **no idle cost**; billed only while someone uses it. The scheduler job hourly and Cloud Scheduler's five schedules (three free per billing account, then $0.10 each): **under $1**.
  - Sum, prod: about $102 + €18 + $20 + $11 + logging and Artifact Registry (within free allowances at this size) ≈ **€135 to €150 a month**: at the €150 alert README already expects ("which the new tier brings within reach; raise it when the first monthly bill shows the level"). Dev (`db-g1-small`, no HA, `min-instances 0` for both services, `deploy.sh:97`): about $25 to $35: well inside €75.
- Impact: nothing to cut without a decision: HA and the dedicated core are settled (7 October 2026), `min-instances=1` on both services is settled (11 and 12 October 2026, two Gemini audits), NocoDB scales to zero already.
- Recommendation: none beyond CMA-034 (read the first full monthly bill, raise the alert to the observed level plus headroom). The lead's PERFORMANCE.md should treat COST-03 as the price list for any speed proposal.
- README check: already open (CMA-034); the tier and `min-instances` are settled (Decision log 7, 11 and 12 October 2026).
- Disproof attempt: checked the service templates and deploy scripts for a forgotten always-on instance (NocoDB is `minScale 0`; the signed-out page is a bucket, `docs/signed-out/deploy.sh:19`), and for a second region or instance (none).

### COST-02: Three Cloud Run jobs cold-start a Node process every minute; estimate $9 to $13 a month for work an always-on instance already idles for (observation; design settled)
- Severity: Info   Confidence: Medium (estimated; durations not measured here)   Effort: L (architecture)
- Component: `docs/ingest/deploy.sh:48-52,229-230`; `ingest/src/jobs/{sweep,poll-forms,poll-email}.mjs`
- Evidence: each minute three job executions start (Cloud Scheduler, `deploy.sh:45-52`), each a fresh container with Node 22, the Cloud SQL connector handshake and a pool of 3 (`deploy.sh:220`). README says "normal runs take seconds" (Database connection budget). Estimate at 4 seconds wall time per execution: 3 × 43,800 × 4 = 525,600 vCPU-seconds × $0.000024 = $12.6, memory 0.5 GiB × 525,600 × $0.0000025 = $0.7; minus the free tier if the services leave it (180,000 vCPU-seconds, about $4.3): **about $9 to $13 a month**. The always-on `cma-ingest` instance (COST-01) idles for about $9.9 a month at the same time.
- Impact: small money; the larger effect is on the connection budget README already documents (overlapping executions, "in the worst case ten of each at once", Database connection budget) and on cold-start latency of each run. A timer inside the service instance would remove both at the price of the service doing job work (one process, one pool) and losing the job's own logs and `--task-timeout` isolation.
- Recommendation: no change; input for CMA-034 and for a later look at the job cadence (every two minutes would halve the figure). The design "one ingest service, four jobs" is settled (Decision log 10 October 2026); the cost here is not new information that changes it.
- README check: settled (Decision log 10 October 2026, "One ingest service, four jobs"); already open for the connection side (Database connection budget, Decision log 15 October 2026 on `max_connections`).
- Disproof attempt: looked for recorded durations in `records/` (none in a greppable form) and for a `--min-instances` on the jobs (not applicable to jobs). The figure is an estimate and labelled so.

### COST-03: Price of the speed options the lead may weigh (input for PERFORMANCE.md; estimates)
- Severity: Info   Confidence: Medium (estimates)   Effort: n/a
- Component: `cloudbuild.yaml:57-69` (cma-web), Cloud SQL tier (README)
- Evidence and estimate:
  - **2 vCPU on `cma-web`** (request-based billing kept): active CPU cost doubles while requests are served (at today's volume a few dollars); the idle `min-instances=1` CPU doubles, +2,628,000 × $0.0000025 = **+$6.6 a month**. Expected gain: Next.js server rendering is one thread per request, so a single page's latency does not halve; two vCPUs help when requests queue on one instance (default concurrency 80 for the service; 5.6 measures whether CPU is the bottleneck). Cheaper first steps: `--cpu-boost` (already on `cma-ingest`, `deploy.sh:310`, not on `cma-web`: it raises CPU during start-up only and costs nothing while idle) and query work in 5.3/5.6.
  - **`db-custom-2-7680` with HA** instead of `db-custom-1-3840`: 2 × $30.1 + 7.5 GiB × 730 × $0.0070 ($38.3) = $98.5, × 2 for HA = $197 against $98.6 today: **about +$97 a month** (+€90), which takes prod past the €150 alert and makes CMA-034 a precondition. Expected gain: only if the instance is CPU- or memory-bound (5.3 checks plans and statistics; README's connection budget suggests connections, not CPU, are the tight resource); a tier change restarts the instance (README, 7 October 2026: planned window).
  - **`max-instances` or pool changes**: not a cost item; a connection budget item (rule 3 of the brief: CONFIG CHANGE section).
- Impact: gives the lead the delta next to the gain; no recommendation of its own.
- README check: already open (CMA-034); the tier decision of 7 October 2026 stands unless 5.3/5.6 show the database CPU-bound.
- Disproof attempt: none applicable; prices are stated as assumptions.

---

## Hardcoded specifics table (file:line | literal | class)

Scope: `web/src`, `web/jobs`, `ingest/src` (outside `adapters/<vendor>/`), `tools/`, `hubspot/`, non-seed `db/`. Classes: adapter (fine) / seed (fine) / mock-test (fine) / copy label (judged) / logic (finding or noted) / settled (README decision).

| file:line | literal | class |
|---|---|---|
| ingest/src/jobs/sweep.mjs:36 | `OUTBOX_LATE = "10 minutes"` | logic: CFG-01 |
| web/src/lib/reports.ts:238, :244 | `OUTBOX_LATE_MINUTES = 10` and its description | logic: CFG-01 |
| web/src/lib/data/postgres.ts:19, :1759 | import and use of `OUTBOX_LATE_MINUTES` | logic: CFG-01 |
| web/src/lib/copy.ts:665, :2486 | "10 minutes" / "10 minuten" in `fix_outbox_pending` | copy carrying logic: CFG-01 |
| ingest/src/core/http.mjs:59-60 | `res.status !== 207` (HubSpot multi-status) in the shared helper | logic: vendor shape in core, CFG-03 (Info) |
| ingest/src/server.mjs:22 | `INGEST_SHOPIFY_READBACK_BUDGET_MS` named in a comment; resolved via `adapter.readbackBudgetMs` at :121 | fine (hook) |
| web/src/proxy.ts:32; web/src/app/team/people/page.tsx:73 | provider `"google"` | settled (Decision log 4 Oct 2026) |
| web/src/components/Shell.tsx:77; web/src/app/roster/planner/print/page.tsx:69 | logo alt "Pulse4all" | copy label (brand; per-tenant theme is an Open decision) |
| web/src/lib/copy.ts:15, :1836 | tagline "Pulse4all contact center / contactcenter" | copy label (brand) |
| web/src/lib/copy.ts:1784, :3605 | "Your Pulse4all account is recognised…" | copy label (judge: fine while Pulse4all operates; the tenant's organisation name would be cleaner) |
| web/src/lib/copy.ts:1515, :1589, :1639, :3336, :3410, :3460 | "Europe/Amsterdam" as an example in hints | copy label (example text; fine) |
| web/src/lib/copy.ts:1623, :3444; web/src/lib/api/configuration.ts:286 | "09:00-17:00" in a hint and a 400 message | copy label (example; fine) |
| web/src/components/configuration/SourceConfig.tsx:34 | `EXAMPLE_ID = "123456789"` placeholder | copy label (fine) |
| ingest/src/jobs/sweep.mjs:34-35 | `LINK_LOOKBACK_MS` 2 h, `REREAD_EVERY_MS` 10 min | logic: operational constants (Info, no finding) |
| ingest/src/jobs/reconcile.mjs:22 | `DEFAULT_LOOKBACK_MINUTES = 26 * 60` | logic: deploy-time override `--reconcile-lookback` (fine) |
| ingest/src/jobs/outbox.mjs:24; ingest/src/core/store.mjs:325 | claim batch 50 | logic: batch size (fine) |
| ingest/src/core/budget.mjs:60 | default read-back budget 3000 ms | logic: env-overridable (fine) |
| ingest/src/core/secrets.mjs:18 | secret cache 5 minutes | logic: documented in README (fine) |
| web/src/lib/reports.ts:24; web/src/lib/messages.ts:9-17; web/src/lib/auth/preview.ts:21; web/src/lib/auth/iap.ts:16 | API limits (92 days, 50/200 rows, 12 h preview, 30 s clock tolerance) | logic: API and auth limits, not business rules (fine) |
| ingest/src/adapters/hubspot/read.mjs:51 | `RATES` 200/400 ms | adapter (fine) |
| ingest/src/adapters/shopify/client.mjs:30 | `.myshopify.com` host regex | adapter (fine) |
| ingest/src/adapters/hubspot/map.mjs:155-165 | `hs_*`, `hubspot_owner_id` property lists | adapter (fine) |
| web/src/lib/auth/identity.ts:93-99 | "Pulse4all subscriptions", "Newco", Europe/Madrid | mock-test (dev only; fine) |
| web/src/lib/data/mock.ts (many) | Pulse4all, Europe/Amsterdam, +44 20 0000 xxxx, example.com | mock-test (fine) |
| tools/verify-legacy-sessions.mjs:39, :101, :113 | Europe/Amsterdam, "Steam 2026", 17:00 | mock-test (the tool takes `--zone`; fine) |
| web/verify/iap-token.mjs:30, :51, :64-65; ingest/verify/*-flow.mjs | a staff address as fixture/default | test: DP-03 |
| db/00_roles.sql:62-64 | personal IAM login names | seed/bootstrap by design; named in Open decisions (DP-03) |
| db/67_verify_invitations.sql:348 | a synthetic 21-digit id `8000…` | test (fine) |
| web/src: `hubspot` 0 hits, `shopify` 0 hits, `aircall` 3 comment hits; web/src/lib/nav.ts and copy.ts: no vendor logic | | clean |
| db/*.sql function bodies outside seeds: `'hubspot'|'aircall'|'shopify'|hs_|dealstage|'google'` 0 hits | | clean |

---

## Checked and found clean

- Tenant context, web: `web/src/lib/data/postgres.ts` has 109 `withTenant(`/`withoutTenant(` uses; the three `withoutTenant` uses are justified: `findPrincipal` → `cma.find_tenants_for_identity` (`:786`, the SECURITY DEFINER lookup, tenant ids only), `previewInvitation` → `cma.invitation_preview` (`:1178`) and `acceptInvitation` → `cma.accept_invitation` (`:1192`), both owner functions that find the invitation by the token's hash and act on its tenant only (comment `:1174-1175`), plus `ping()` in `web/src/lib/db/client.ts:238` for `/api/health`. No other file reaches the pool: `transaction(`, `pool.query`, `new Pool` outside `client.ts`: zero; the four other importers of `lib/db/client` import `CmaDbError` only.
- Tenant context, scheduler job: `web/jobs/close-forgotten-workdays.mjs:70` lists tenants through `cma.find_tenants_for_identity('scheduler', …)`, then per tenant `set_config('app.tenant_id' …, true)` inside `begin…commit` (`:78-90`), resolving the tenant's own scheduler user under RLS (`:81-88`).
- Tenant context, ingest: `ingest/src/core/db.mjs:97-120` offers `withoutTenant` (used only by `connection.mjs:14` for `cma.ingest_connection(key)` and `:38` for `cma.find_tenants_for_identity('ingest','ingest')`), `withTenant(ctx)` (tenant, the connection's Ingest user, `ingest:<adapter>` label; `connection.mjs:26-28`) and `withTenantOnly` (tenant alone, `app.user_id = ''`) used once to list a tenant's active connections under RLS (`connection.mjs:42-49`). Every store method (`core/store.mjs`) runs inside `withTenant(ctx, …)`.
- No cross-tenant read outside `cma_read`: grep `cma_read` in `web/src`, `web/jobs`, `ingest/src`: zero. `cma.connections_all()` (`db/30_ingest_crm_records.sql:959`) is "every connection of the tenant", not cross-tenant.
- One writer towards HubSpot: the only non-read call is `batchUpdate` (`ingest/src/adapters/hubspot/read.mjs:94-97`, `POST …/batch/update`), called once, from the outbox writer `ingest/src/adapters/hubspot/write.mjs:187`, which the outbox job alone invokes (`ingest/src/jobs/outbox.mjs:32,44` through `adapter.writeContacts`). `match.mjs`, `search.mjs`, `read.mjs`, `email-poll.mjs`, `conversations.mjs` issue `GET` and `POST …/search`, `…/batch/read`, `…/associations/…/batch/read` only. `email.mjs:133 writeContacts` writes to the CMA store after a `batchRead`, not to HubSpot (name aside). Shopify: `POST /admin/oauth/access_token` (`client.mjs:72`), GraphQL queries (`:209`) and the webhook-subscription mutation (`reconcile.mjs:40`): no customer data written. Aircall: no write.
- Mirror never overruled: stale guards in `cma.ingest_upsert_records` (`db/32:1101-1103`, `v_updated < v_old.source_updated_at` → `'stale'`), `cma.ingest_upsert_contacts` (`db/70:532-535`), `cma.ingest_upsert_tasks` (`db/70:234-237`), `cma.ingest_upsert_telephony_calls` (`db/34:346`, `source_version_at`), the 0008m threads/emails (`db/68:680-682`). The web app updates no mirror column: grep `update cma.(crm_|telephony_|commerce_|email|inbox)` in `web/src`, `web/jobs`: zero; every `update cma.crm_*` in `db/` sits inside `ingest_*` functions or the forget path.
- Mirror from the source's answer: `ingest/src/core/events.mjs:3` "nothing here reads a vendor payload", `raw` holds ids and timestamps (`:6`); the read-back fetches objects (`process.mjs:42` → `adapter.readBack`). The only `inline` use is the Aircall adapter (`aircall/map.mjs:82`, `read.mjs:206-273`) and only with `INGEST_ALLOW_REPLAY` or the reconcile's own API read (`aircall/reconcile.mjs:62`, `source: "api"`): telephony facts are webhook-owned by README's Source of truth table, and HubSpot and Shopify never pass `inline`.
- Raw filters for 0008m and 0008n: `cma.email_raw` and `cma.task_raw` drop nested values, arrays, content keys, `@` strings and long strings (observed for `email_raw`); `cma.task_raw_ok` doubles as a table-level guard (`db/70:71-78`). The HubSpot task and call property lists exclude body and subject (`map.mjs:158-162`).
- Audit images: `cma.audit_row()` of `db/66_invitations.sql:216-248` strips `token_hash` from invitation images and keeps keys only for uncounted-line deletes; `cma_read.audit_log` exposes no images (observed). The images still hold invitation addresses and keyed hashes: already open (Open decisions, retention of invitations and of the keyed hashes).
- Exports: `cma.export_hours` and `cma.export_status_changes` return `display_name`, `organisation_name`, `status_name`, times and durations (`db/13:164-216`); no login id, address or external id.
- Request URLs: query parameters and dynamic segments as listed in DP-05; no route with an address or a name in a path or query; the ingest path rule (Decision log 12 October 2026) is 5.2's.
- Fixtures: `tools/fixtures/*.csv` ("Test Account A/B", `example.com`), `ingest/verify/fixtures`, `web/verify`, `mock.ts`: addresses on `example.*`/`.invalid` and the drama range `+44 20 0000 xxxx`; the one exception is the staff address of DP-03.
- Data map: `docs/datamap/index.html` fetches `schema.json` (column names) and `catalog.json` (what/how texts); no values, no addresses.
- Configuration → Sources: adapters are data (`integration_connection.adapter`, shown as-is), connections carry secret names not values (`signing_secret_name`, `token_secret_name`; `connection.mjs:14-23`).
- NocoDB: `minScale 0`, `maxScale 1`, CPU throttled; no idle cost (COST-01). Note for 5.11: README's dev connection budget line counts "NocoDB 2 × 3 = 6" where the template allows one instance (`maxScale: "1"`); harmless (over-counting), doc drift only.
- `min-instances=1` on `cma-web` survives deploys: `cloudbuild.yaml:57-69` passes no `--min-instances`, and `gcloud run deploy` keeps unspecified settings; the GO_LIVE_RUNBOOK's check (`docs/night-2026-10-11/GO_LIVE_RUNBOOK.md:177`) is the right one for Martin to have run after the first merge (**Terminal**: `gcloud run services describe cma-web --project=p4a-cma-prod --region=europe-west4 --format='value(spec.template.metadata.annotations)'`; expected: `autoscaling.knative.dev/minScale: 1` present).

## Not checked / could not check

- Live cost figures, bills and the pricing calculator (rule 1: no cloud access); all 5.10 numbers are estimates from assumed list prices.
- Job execution durations in prod (no recorded figure in a greppable form; COST-02 assumes 4 s per run).
- Column-by-column review of every `cma_read.*` view for `raw` columns (0007a onward): the task scoped `cma_read` to the grep for cross-tenant reads; 5.3 owns the views.
- The `hubspot/` project template's scopes and the `env/` files beyond confirming they hold names, not values (5.1/5.2 scope).
- Ingest log lines in depth (5.2, per the task's coordination note).

## Commands run (all read-only; local database only)

- `grep -rn -i 'pulse4all' web/src web/jobs ingest/src tools hubspot` (excluding adapters): comments, mock data, brand strings only.
- `grep -rn -i 'hubspot|aircall|shopify|hs_|dealstage|hubspot_owner_id|X-Shopify|hubapi' ingest/src` excluding `adapters/`: zero non-comment hits; `web/src`: 0 / 3 (comments) / 0.
- `grep -rn 'Europe/Amsterdam|07:00|22:00|17:00|pulse4all\.app|pulse4all\.com|myshopify|\b1[0-9]{7,8}\b|"Newco"|"Subs"|"Invest"|"GB"|"NL"|"EUR"|"GBP"'` over app code: results in the table above.
- Threshold literal grep over `ingest/src/core`, `ingest/src/jobs`, `ingest/src/server.mjs` and `^(export )?const [A-Z_]+ = [0-9]+` over `web/src/lib`: results in the table.
- `grep -n 'withoutTenant|withTenant' web/src/lib/data/postgres.ts` (109 uses, 3 `withoutTenant`); `grep -rn 'transaction(|pool.query|getPool()|new Pool' web/src` outside `client.ts`: none.
- `grep -rn -i "method: *['\"](PATCH|POST|PUT|DELETE)|batch/update|batch/create" ingest/src/adapters/hubspot`: one writer (`read.mjs:96`), one caller (`write.mjs:187`).
- `grep -rn 'inline' ingest/src/adapters`: Aircall only.
- `grep -rn 'console\.' web/src web/jobs`: 11 lines, listed in DP-05; `grep -rn 'new ApiError(' web/src | grep '\${'`: 17 lines, field names and limits only.
- `grep -rhno 'sp\.get("…")|searchParams\.get("…")' web/src`: 13 parameter names, listed in DP-05; `find web/src/app -type d -name '\[*\]'`: 15 segments.
- Fixture survey: email domains and masked phone patterns across `mock.ts`, `web/verify`, `ingest/verify`, `tools/fixtures`, seeds; staff-domain hits classified by shape without printing values.
- `records/`: `find | wc -l` (417); `grep -rlE '@pulse4all\.com' records | wc -l` (11); 20- and 21-digit grep (0 and 0); PNG folders listed; two PNGs viewed.
- `psql -h 127.0.0.1 -U postgres -d cma`: `select key from cma.setting where key like 'outbox%'` → `outbox.max_attempts`; `information_schema.columns` for `cma_read.audit_log` → 10 columns, no images; `set role cma_owner; select cma.telephony_raw(…), cma.email_raw(…)` with a nested payload → `telephony_raw` kept `"login": "someone@example.com"`, `email_raw` dropped every address and nested value.
- Reads: `ingest/src/core/{db,connection,events,process,pace,http,store}.mjs` (parts), `ingest/src/adapters/*/index.mjs`, `ingest/src/adapters/hubspot/{read,write,email,map}.mjs` (parts), `ingest/src/jobs/{sweep,outbox,reconcile}.mjs` (parts), `web/src/lib/db/client.ts:207-241`, `web/src/lib/api/{respond,forms}.ts` (parts), `web/src/app/reports/data-quality/page.tsx:1-30`, `db/01:173-193`, `db/66:215-248`, `db/32:118-140,251-258,1056-1157`, `db/34:240-300,346`, `db/68:460-520`, `db/70:62-110,190-335,450-580`, `db/74:1-110` (header), `db/13:32-64,164-216`, `db/38:75,487,561`, `docs/ingest/README.md:40,240,272`, `docs/ingest/deploy.sh` (sizing and schedules), `cloudbuild.yaml:55-90`, `docs/nocodb/service.template.yaml`, `docs/night-2026-10-11/GO_LIVE_RUNBOOK.md:175-177`, README sections named in the summary, `local-records/readme-index/decisions-index.md` (grep).
