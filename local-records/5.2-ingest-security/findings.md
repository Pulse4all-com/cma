# 5.2 Security of the ingest service (`ingest/`, `docs/ingest/`): raw findings

Examined on 17 October 2026 (main at `35ea3e0`, db/00..75 on main; the local PostgreSQL 16 holds db/00..75 with the dev seed) by static review of every file under `ingest/src`, `ingest/jobs`, `ingest/tools`, `ingest/verify/*-flow.mjs`, `ingest/Dockerfile`, `ingest/cloudbuild.yaml`, `ingest/.dockerignore`, `docs/ingest/*.sh`, `docs/ingest/*.mjs`, the functions `cma.ingest_connection`, `cma.ingest_claim_events`, `cma.ingest_finish_events`, `cma.ingest_sync_run_start/finish` and `cma.upsert_connection` in db/30, db/32, db/52, db/74, against README Architecture (Ingest API bullet, Database connection budget), the Decision log entries of 12, 13, 15 and 16 October 2026, `docs/ingest/README.md`, `docs/ingest/PROD_RUNBOOK.md` 9.3 and `records/ingest-front-incident-2026-10-16`; plus local runs: `npm run lint` (clean), `npm test` (14 pure verifiers, 452 checks, all PASS) and the six flow verifiers against the local database, plain and `--provoke` (12 runs, every one its expected verdict; verdict lines in "Flow verifier verdicts" below). About 70 minutes. Nothing outside this repository and the sandbox database was called.

Most important: (1) the Shopify client-credentials token cache is keyed by shop and client id only, so a connection of another tenant naming the same shop and client id reads the shop through the first tenant's token without ever reading a secret (5.2-01, High, confirmed on main, 3-line fix); (2) nothing stops two executions of a scheduled job from running at once (no advisory lock), which README already prices as a worst case of +60 connections (5.2-02, Medium, small fix); (3) in the Shopify read-back one failed CRM lookup fails every unit of the batch and every retry repeats every Shopify read and every search (5.2-03, Medium). Secret names on connection rows are not scoped to a tenant (5.2-04). Everything else is Low or Info; the request path, the three signature checks, the logging rule, SSRF surface and the deploy guard of 16 October were checked and found clean.

Note for the lead (public repository rule 7): this file holds the full text of a High finding (5.2-01). It is raw input for the report; do not commit it as it stands to the public repository unless the fix is in a PR first.

---

### 5.2-01: Shopify token cache keyed by shop and client id: another tenant's connection reuses the first tenant's token without reading any secret
- Severity: High   Confidence: High   Effort: S
- Component: `ingest/src/adapters/shopify/client.mjs` (`tokenFor`, `dropToken`), used by `read.mjs`, `reconcile.mjs` (reconcile, backfill, subscription check)
- Evidence:
  - `client.mjs:65` `const tokens = new Map(); // shop|client id → { promise, value, expiresAt }`; `:101` `const k = \`${shop}|${clientId}\`;` with `shop = connection.externalAccountId` (`:100`) and `clientId` from the connection **setting** `client_id` (`:99`, `clientIdOf`); `:103` returns the cached `hit.value` **before** the code that reads the connection's own secret (`:105-113`, `getSecret(connection.signingSecretName)` runs only on a miss). The cache value is the Admin API access token itself (`:117`).
  - `dropToken` (`:126-132`) deletes by the same key, so a 401 on tenant B's connection also forgets tenant A's token.
  - Both values of the key are public, not secrets: the shop domain is on every delivery (`X-Shopify-Shop-Domain`) and the client id is "not a secret" (`docs/ingest/README.md`, Configuration table; `client.mjs:6-7`).
  - The jobs serve every active connection of every tenant in one process (`src/core/connection.mjs:37-58`; `jobs/reconcile.mjs:26-28`), in tenant order then `order by c.id`, so in one nightly `ingest-reconcile` run connection A mints and a connection B of another tenant with the same shop and client id hits the cache deterministically (same process, within 24 h).
  - `cma.upsert_connection` (db/52) takes any `external_account_id` and any secret name under `tenant.configure`, so an admin of tenant B can create such a connection; B also needs its store row (`upsert_commerce_store`) and its pepper (`ingest-hash-pepper-<slug B>`, created by `deploy.sh --tenant`), both routine for a tenant.
  - Git: `client.mjs` unchanged since B10 (`295104e`), so this is the state on main.
- Impact (in this system's context): a tenant admin (today the builders; README Users and roles plans "a business line's own administrator") can configure a Shopify connection in tenant B that names tenant A's shop and the app's client id with a nonsense secret name, and B's reconcile and backfill (`recordAndProcess` → `readBack` → `shopifyClient(B)` → cache hit) read the shop's customers and orders into tenant B's `commerce_customer`/`commerce_order` under B's RLS context. B never held the client secret. A webhook for B is still refused (its HMAC is checked against B's own secret), so the path is the jobs, not the route. Cross-tenant exposure of commerce data (ids, amounts, keyed phone hashes with B's pepper, order lines). Today both tenants are Pulse4all's own business lines and the admins are the same two people, which lowers the likelihood but not the class.
- Recommendation (exact diff, `ingest/src/adapters/shopify/client.mjs`):
  ```diff
  -const tokens = new Map(); // shop|client id → { promise, value, expiresAt }
  +// Keyed by the connection and the secret it mints with, never by the shop alone: a connection of another
  +// tenant naming the same shop and client id must read its own secret (CMA-037, 17 October 2026)
  +const tokens = new Map(); // connection id|signing secret name|client id → { promise, value, expiresAt }
  +const tokenKey = (connection, clientId) => `${connection.connectionId}|${connection.signingSecretName ?? ""}|${clientId}`;
  @@ export async function tokenFor(connection, settings, signal, now = Date.now()) {
     const clientId = clientIdOf(settings);
     const shop = connection.externalAccountId;
  -  const k = `${shop}|${clientId}`;
  +  const k = tokenKey(connection, clientId);
  @@ export function dropToken(connection, settings) {
     try {
  -    tokens.delete(`${connection.externalAccountId}|${clientIdOf(settings)}`);
  +    tokens.delete(tokenKey(connection, clientIdOf(settings)));
  ```
  Within one tenant a shop has one connection (unique `(tenant_id, adapter, external_account_id)`), so "one token per connection" is "one token per tenant and shop": the renewal-burst behaviour (one mint for 200 deliveries, `shopify-flow` section H) is unchanged. The cost bucket stays per shop (`buckets`, `:135`): Shopify's limit is per app and store, so sharing the estimate across tenants is right. README to update in the same PR: Architecture bullet "a token of the client credentials grant cached per shop" and Decision log 13 October 2026 "one client credentials token per shop and app is cached" → "per connection (tenant and shop)".
  `shopify-flow` case (new section, after F): in tenant two, as its admin, `upsert_connection('shopify', 'Shopify flow B', SHOP_A, 'ingest-shopify-<run>-b-missing', null)` (no such file in `INGEST_SECRETS_DIR`), settings `{client_id: CLIENT_A, api_version: '2026-10', shop_handle: HANDLE_A}`, a store row and a pepper file for tenant two; then `runReconcile({ connectionId: <tenant two's>, lookbackMinutes: 60 })`. Expected: the run's `commerce_customer` stream fails `client_secret_unavailable`, `fake.mints[SHOP_A]` unchanged, no `commerce_customer` or `commerce_order` row in tenant two, and no GraphQL request of the fake carried tenant one's token after the run started (the fake already keeps `requests`). Provoked (today's behaviour): rows appear in tenant two and the fake's requests show tenant one's `shpat_fixture_…` token used by the run.
  `shopify-client.mjs` case: two connections `{connectionId: "c1"}` and `{connectionId: "c2", signingSecretName: "ingest-shopify-missing"}` with the same shop and settings → `tokenFor(c2)` is `client_secret_unavailable` after `tokenFor(c1)` succeeded; `fake.mints` stays 1.
- README check: already open as backlog CMA-037 item 1 (per the audit brief); not in the Decision log or Open decisions; verified still present on main.
- Disproof attempt: looked for a tenant check between the cache and the caller (none: `tokenFor` takes `connection` but reads only `externalAccountId`); checked whether `servedConnections` or `reconcile` filter connections by secret readability (no: the secret is read lazily, after the cache lookup); checked whether `upsert_connection` refuses a shop another tenant holds (no: the unique key includes `tenant_id`); checked whether B's missing pepper or store row blocks the read (they do, but both are a tenant's own routine setup). Stands.

### 5.2-02: No single-flight guard on the scheduled jobs: overlapping executions double the connections and the work
- Severity: Medium   Confidence: High   Effort: S
- Component: `ingest/src/jobs/runner.mjs` (`main`), `ingest/src/jobs/sweep.mjs`, `poll-forms.mjs`, `poll-email.mjs`; `docs/ingest/deploy.sh:229, 256-258`
- Evidence:
  - `runner.mjs:68-86` `main()` has no lock; none of `runSweep`, `runPollForms`, `runPollEmail`, `runReconcile` takes one; no `pg_try_advisory_lock` or `pg_advisory_lock` anywhere in `ingest/` or `db/` (grep).
  - `deploy.sh:229` `--tasks=1 --max-retries=0 --task-timeout="$3"` with `10m` for sweep, poll-forms, poll-email (`:235-237`); `:256-258` Cloud Scheduler `* * * * *` for all three, no attempt deadline; Cloud Run jobs allow concurrent executions, and Scheduler fires `:run` every minute whatever runs.
  - A sweep can exceed a minute: `sweep.mjs:48-55` loops `processEvents` until a part claims under 100 or `maxMs` 45 s passed, but one part of 100 events can itself take many 20-second per-call timeouts (`JobBudget` `:45`), then the reread, catalogs, `link_calls` per tenant and the outbox guard follow outside `maxMs`; `poll-email.mjs` stops starting new pages after 40 s (docs) but finishes the page in flight; `poll-forms` has no time cap in the job (the adapter's).
  - What overlap costs: each execution opens its own pool of 3 (`CMA_DB_POOL_MAX=3`); README Architecture, Database connection budget (line 153): "Cloud Scheduler starts the sweep and the form poll every minute whether or not the previous execution has finished (task timeout 10 minutes), so a run longer than a minute overlaps the next one: in the worst case ten of each at once, 2 × 10 × 3 = 60 more, which would pass the limit (83 + 60 = 143); normal runs take seconds."
  - What stays safe: the claim is `for update skip locked` (db/30 `cma.ingest_claim_events`, lines 490-501), so two sweeps never read the same event twice; `outboxClaim` the same (docs). Not protected: the reread (`recordsWithoutContact` → `recordAndProcess` with a 10-minute version: the second run sees the same keys as already recorded, so mostly `skipped`, but both runs do the `store.recordsWithoutContact` query and claim), the hourly catalog refresh (two reads of lines and tags), `link_calls` per tenant (two `sync_run` rows, two scans), the forms poll (cursor moves at the run's end, so two concurrent polls read the same submissions and do the same CRM searches: idempotent on the conversion id, but double HubSpot search traffic against the account-wide 5/s limit shared with the Shopify match and the email poll), the email poll (same shape: double page reads and searches).
- Impact: a slow vendor night (a HubSpot 5xx streak, a Shopify outage) stretches the sweep past a minute and the executions pile up to the task timeout: up to 10 sweeps and 10 form polls at once, 60 extra connections on an instance with 97 usable (README budget), so `cma-web` requests start failing on `connection refused`. Normal operation is fine (observed in README: seconds). This is the one reliability scenario the budget paragraph names without a guard.
- Recommendation (exact diff): a session-level advisory lock per job name, held on a dedicated pooled client for the run and released at exit, applied to the scheduled jobs (sweep, poll-forms, poll-email, reconcile); backfill and outbox are manual and keep running unlocked.
  `ingest/src/core/db.mjs` (after `withTenantOnly`):
  ```diff
  +/**
  + * A session-level advisory lock named for a job, held on one pooled client until release(); null when
  + * another process holds it (Cloud Scheduler starts an execution every minute whether or not the previous
  + * one finished: README, Database connection budget). The key is hashtext of the name, so every ingest
  + * process of the project shares it.
  + */
  +export async function jobLock(name) {
  +  const { pool } = await db();
  +  const client = await pool.connect();
  +  let ok = false;
  +  try {
  +    ok = (await client.query("select pg_try_advisory_lock(hashtext($1)) as ok", [`cma-ingest:${name}`])).rows[0].ok === true;
  +  } finally {
  +    if (!ok) client.release();
  +  }
  +  if (!ok) return null;
  +  return {
  +    async release() {
  +      await client.query("select pg_advisory_unlock(hashtext($1))", [`cma-ingest:${name}`]).catch(() => undefined);
  +      client.release();
  +    },
  +  };
  +}
  ```
  `ingest/src/jobs/runner.mjs`:
  ```diff
  -import { closeDb, dbErrorCode } from "../core/db.mjs";
  +import { closeDb, dbErrorCode, jobLock } from "../core/db.mjs";
  @@
  -export async function main(job, fn) {
  +export async function main(job, fn, { lock = false } = {}) {
     const started = Date.now();
     let failed = 1;
  +  let held = null;
     try {
  +    if (lock) {
  +      held = await jobLock(job);
  +      if (!held) {
  +        info(`${job} skipped`, { job, code: "locked" });   // another execution is still running
  +        await closeDb();
  +        process.exitCode = 0;
  +        return;
  +      }
  +    }
       const r = await fn(process.argv.slice(2));
  @@
  +  } finally {
  +    await held?.release();
     }
     await closeDb();
  ```
  (the `finally` goes on the existing try/catch; `closeDb()` after it as today). `ingest/jobs/sweep.mjs`, `poll-forms.mjs`, `poll-email.mjs`, `reconcile.mjs`: `await main("sweep", (argv) => …, { lock: true });`. The lock takes one of the job's three connections for the run, within the budget paragraph (no change of pools or schedules; README's budget paragraph gets the sentence "a second execution of a scheduled job exits at once while the first runs (advisory lock), so the worst case is one of each").
  `jobs-flow` case (section A, before the sweep): `const { jobLock } = await import("../src/core/db.mjs"); const a = await jobLock("verify-lock"); const b = await jobLock("verify-lock"); expect("a second holder of a job's lock gets none while the first holds it", [Boolean(a), b], [true, null], [true, {}]); await a.release(); const c = await jobLock("verify-lock"); expect("…and gets it once released", Boolean(c), true, false); await c.release();`. The two calls use two clients of the same pool, so the second really is another session.
- README check: already noted as a worst case without a guard (Architecture, Database connection budget, 15 October 2026); the guard itself is new. Not in Open decisions.
- Disproof attempt: checked whether Cloud Run jobs refuse a second execution (they do not; `--parallelism` governs tasks inside one execution) and whether Scheduler has a "skip if running" (it has not; `--attempt-deadline` only bounds the `:run` call, which returns at once); checked that the claim's `skip locked` makes overlap at least correct (it does: the finding is cost, not duplication); checked the sweep's own time cap (45 s applies only between parts). Stands as Medium: no data effect, a plausible resource effect README itself computes.

### 5.2-03: Shopify read-back: one failed CRM lookup fails every unit of the batch, and every retry repeats every Shopify read and every search
- Severity: Medium   Confidence: High   Effort: M
- Component: `ingest/src/adapters/shopify/read.mjs:222-259`, `ingest/src/adapters/shopify/match.mjs:48-98`
- Evidence:
  - `match.mjs:87-93`: the per-customer search is in `try { … } finally { email = null; }`, no `catch`: a `SourceError` from `findContactsByEmail`/`findContactsByProperties` (`rate_limited` on 429, `paced` when the search slot does not fit the budget, `timeout`, `http_5xx`, `token_unavailable`) propagates out of the `for` loop (`:71`), so the customers after it are not tried either.
  - `read.mjs:233-240`: `matchCustomers` is wrapped once; the exception becomes `matchError = \`crm_${code}\`` for the whole batch; `:256-259` every pending unit whose customer was in `toMatch` is finished `failed` with that code, including the customers already matched in the same loop (their `out` entries are lost with the throw) and those `known` by the batch read (`:60-69`).
  - The same holds for `existingContacts` (`:62-64`) throwing: nothing is matched.
  - On the sweep's retry the batch is claimed again (backoff `2^attempts` minutes, db/30:498) and `readBack` starts from scratch: orders five a call, counts, lines, customers, then the searches again (`read.mjs:140-220`). After `ingest.max_attempts` (10, db/30:65) the events park as `needs_review` with `crm_rate_limited`.
  - Scale: the sweep claims 100 events per part (`process.mjs:36`); a renewal run of 200 orders is 200 customers; HubSpot's search limit (five a second per account, `match.mjs:10-11`) is shared by the forms poll, the email poll and the match across all processes (CMA-040), so one 429 in a 100-search batch is plausible, and it costs the whole batch.
  - Git: `read.mjs` and `match.mjs` unchanged since B10.1 (`b702495`), so this is the state on main.
- Impact: lost matches (links not set for a whole batch), ten times the Shopify cost and HubSpot searches for the same objects before they park, and parked events Martin has to resolve by hand; in a renewal night the match of every order of the run can end `needs_review` because of one 429.
- Recommendation: catch per customer in `matchCustomers`, keep the rate-limit short-circuit (stop searching, but fail only the unmatched customers), and in `read.mjs` fail only the units whose customer carries an error:
  `match.mjs` (`:84-95` replaced):
  ```diff
  -    const node = nodes.get(id);
  -    let email = …;
  -    let found;
  -    try {
  -      found = email ? … : …;
  -    } finally {
  -      email = null;
  -    }
  -    if (found.length === 1) out.set(id, { outcome: "one", link: set(found[0]) });
  -    else out.set(id, { outcome: found.length ? "several" : "none", link: clear });
  +    if (stopped) { out.set(id, { outcome: "error", link: null, code: stopped }); continue; }
  +    const node = nodes.get(id);
  +    let email = typeof node?.defaultEmailAddress?.emailAddress === "string" ? node.defaultEmailAddress.emailAddress : null;
  +    let found;
  +    try {
  +      found = email
  +        ? await side.adapter.crm.findContactsByEmail({ connection: side.crm, email, budget })
  +        : await side.adapter.crm.findContactsByProperties({ connection: side.crm, properties: side.refProperties, value: id, budget });
  +    } catch (err) {
  +      // One customer's lookup failing fails that customer only; a 429 or a missed slot stops the rest of the searches (the sweep reads them)
  +      const code = err instanceof SourceError ? err.code : "crm_error";
  +      if (code === "rate_limited" || code === "paced" || code === "timeout") stopped = code;
  +      out.set(id, { outcome: "error", link: null, code });
  +      continue;
  +    } finally {
  +      email = null;
  +    }
  +    if (found.length === 1) out.set(id, { outcome: "one", link: set(found[0]) });
  +    else out.set(id, { outcome: found.length ? "several" : "none", link: clear });
  ```
  with `let stopped = null;` declared before the loop and `import { SourceError } from "../../core/http.mjs";`; the `existingContacts` call (`:62-64`) in its own try/catch that, on failure, marks the linked customers `{ outcome: "error", code }` and lets the others continue. `read.mjs:256-259`:
  ```diff
  -    if (cid && toMatch.has(cid) && matchError) {
  -      units.push(unit(g.events, "failed", matchError));
  -      continue;
  -    }
       const m = cid ? matches.get(cid) : null;
  +    if ((cid && toMatch.has(cid) && matchError) || m?.outcome === "error") {
  +      units.push(unit(g.events, "failed", matchError ?? `crm_${m.code}`.slice(0, 60)));
  +      continue;
  +    }
  ```
  keeping `matchError` only for `crmOf`/`customerLinks` (database) failures. The retried units then cost one customer read and one search each. (A further step, not needed now: keep the Shopify nodes of a failed-match unit as `inline` for the sweep so the GraphQL read is not repeated; the core's `inline` map already carries objects between record and read-back.)
  `shopify-flow` case (new, after E): five customers delivered and left for the sweep (`fake.throttled` so the route's 1.5 s budget leaves them), the fake HubSpot answering 429 to the search for the third customer's email only; `runSweep({ connectionId: conn.a })` → expected: four events `processed` with `match_one` 4 in the processed log, one `failed` `crm_rate_limited`; the fake's GraphQL customer reads for the batch counted once; `fake.hs.searches` 5 then, on a second `runSweep` after the backoff is cleared in the row, 1 more. Provoked (today): five `failed` `crm_rate_limited`, searches 3 then 3.
- README check: already open as backlog CMA-037 item 3 (per the brief); `docs/ingest/README.md` Shopify section documents today's behaviour ("A CRM that cannot answer fails the event with `crm_<code>` and the sweep tries again") and would change with the fix. New otherwise.
- Disproof attempt: checked whether the sweep's part size limits the blast radius (100, not smaller); whether `paced` can happen in a job (no: `JobBudget.remaining()` is infinite so `slot` waits; in the webhook path it does, failing the delivery's customer for the sweep, which is the designed path); whether HubSpot's 429 is implausible (the five-a-second search limit is account-wide and three pollers share it). Stands.

### 5.2-04: Secret names on connection rows are not scoped to the tenant: any tenant admin can point a connection at any secret the service can read
- Severity: Medium   Confidence: Medium   Effort: M (a migration pair) / S (a service-side guard)
- Component: `cma.upsert_connection` (db/30, db/52), `ingest/src/core/secrets.mjs`, `ingest/src/core/connection.mjs`
- Evidence:
  - `upsert_connection` (db/52) checks `tenant.configure` and the adapter name only; `signing_secret_name` and `token_secret_name` are free text per connection row; `cma.ingest_connection(key)` and `servedConnections` hand those names to the service, which reads them from the one project-wide Secret Manager (`secrets.mjs:38-48`), as the one service account with `secretAccessor` on every granted secret (`deploy.sh:153-168`, grants per named secret for all tenants). Nothing joins a secret name to a tenant.
  - The pepper is the exception by construction: `ingest-hash-pepper-${await store.tenantSlug()}` (`shopify/read.mjs:131`, the same in HubSpot and Aircall), derived from the tenant's own slug, never from a row.
  - Today the web passes the stored names back unchanged (`web/src/lib/data/postgres.ts:1527`, `setSourceConnection`) and no API route takes a secret name, so the only writers of these names are the runbooks in Studio and the verifiers; README Users and roles plans "a business line's own administrator" with "connections and API keys".
- Impact: an admin of tenant B who can run `upsert_connection` (Studio today; an admin screen for connections later) can name tenant A's HubSpot token secret with A's portal id and have B's reconcile and backfill read A's CRM records into B, or name `ingest-shopify-app-signing` for a Shopify connection in B and both authenticate webhooks to B's route and mint tokens for A's shops without the cache of 5.2-01. The principle "multi-tenant and role-based from the first line" (CLAUDE.md, 2) is not held by the schema for this one column pair; it is held today by who holds `tenant.configure` and by the absence of a UI.
- Recommendation: (a) a migration pair 0008q (`db/76`/`db/77`): a naming rule enforced in `upsert_connection`, `signing_secret_name` and `token_secret_name` must match `^ingest-<slug>-` for the tenant's slug **or** be listed in a small owner-maintained allow-list table `cma.tenant_secret_name (tenant_id, secret_name)` (RLS, `setup_tenant_table`), seeded by Martin in Studio with the names prod uses now (`ingest-hubspot-…`, `ingest-shopify-app-signing`, the Aircall pair), so nothing is renamed in Secret Manager; `cma.ingest_connection(key)` and the jobs' connection query join it, so a row naming a secret outside its tenant's list is simply not served; verify script with a provoked row. (b) Until then, as defence in depth in the service, `lookupConnection`/`servedConnections` refuse (log `secret_not_allowed`, 404 / skip) a secret name that neither starts with `ingest-${tenantSlug}-` nor is in a `INGEST_SHARED_SECRET_NAMES` list set by `deploy.sh` (today `ingest-shopify-app-signing` and the HubSpot pair); that is a `deploy.sh` env change and needs the CONFIG CHANGE section. Catalog: `docs/datamap/catalog.json` gets the new table.
- README check: new. Not in the Decision log, Open decisions or the backlog as described to this audit. Related settled points: secrets per named grant (15 October 2026), peppers per tenant slug (Architecture).
- Disproof attempt: looked for a check in `set_connection_settings`, `ingest_connection`, `find_tenants_for_identity` or the service (none); checked whether the pepper could be borrowed the same way (no: derived from the slug); checked whether the UI exposes the field (no: names are passed back unchanged), which is why this is Medium and not High.

### 5.2-05: `deploy.sh` does not check the checkout is `main`: a prod deploy from a branch ships bytes no one reviewed, tagged by a branch commit
- Severity: Medium   Confidence: High   Effort: S
- Component: `docs/ingest/deploy.sh:112-119`
- Evidence: the header says "Runs … on a clean checkout of main" (`:33`), and the only checks are `git status --porcelain -- ingest` (`:115`) and that a commit touches `ingest/` (`:118`); `SHA="$(git log -1 --format=%h -- ingest/)"` (`:114`) is the branch's last ingest commit, so on a feature branch the image `ingest:<branch sha>` is built (`:191-194`) and deployed to prod (`:300-313`) without a PR, a dev run or `verify/deploy-script.mjs` having seen it; `git switch -q main && git pull -q --ff-only` is in the runbook text (`docs/ingest/README.md`, Deploy), not in the script. Same class as the 16 October incident: a by-hand omission the script lets through silently.
- Impact: prod runs code outside main (CLAUDE.md, Git and release: main only accepts pull requests; the image is meant to be "the bytes dev tested"); a later main deploy with the same `ingest/` sha would say `image … exists; no build` and reuse the branch image if the shas coincide (they would not, unless the branch was merged with a fast-forward, in which case the bytes are the same).
- Recommendation (exact diff, after `:118`, before any gcloud call):
  ```diff
   [ -n "$SHA" ] || { echo "no commit touches ingest/"; exit 2; }
  +BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  +if [ "$ENV" = prod ] && [ "$BRANCH" != main ]; then
  +  echo "prod deploys from main only (this checkout is on ${BRANCH}): git switch main && git pull --ff-only, then rerun"; exit 2
  +fi
  +[ "$BRANCH" = main ] || echo "note: deploying ${ENV} from branch ${BRANCH}, not main"
  ```
  `verify/deploy-script.mjs`: the throwaway tree is created with `git init -q`, whose default branch here is `master` (no `init.defaultBranch`), so the fix adds `-b main` to that `init` and two cases: `git switch -c other` → `run(["prod","--front",FRONT])` exits 2 with the message and `r.calls.length === 0`; `run(["dev"])` on the branch exits 0 with the note in `r.out`. An `origin/main` equality check is left out on purpose (the verifier's tree has no origin; the runbook's `git pull --ff-only` covers it).
- README check: new; the Decision log of 16 October 2026 ("A flag whose absence silently breaks prod is not optional") is the precedent.
- Disproof attempt: checked whether `gcloud builds submit` builds from a commit (no: from the working tree `ingest/`, so the clean check matters but the branch does not); whether the image-exists check could refuse a branch sha (no). Stands.

### 5.2-06: The flow verifiers default `INGEST_FLOW_ADMIN_USER` to a real team member's address, in six files and their headers
- Severity: Low   Confidence: High   Effort: S
- Component: `ingest/verify/flow.mjs:42`, `jobs-flow.mjs:48`, `aircall-flow.mjs:47`, `shopify-flow.mjs:51`, `outbox-flow.mjs:39`, `email-flow.mjs:54` (and the usage lines in each header, `email-flow.mjs:7` also as `CMA_DB_USER`)
- Evidence: each file has `const ADMIN = process.env.INGEST_FLOW_ADMIN_USER ?? "<real address>";` (the repository owner's work address; not repeated here per the audit's rule 2). A run without the variable connects as that login; locally it fails to connect (no such role) with a confusing error instead of a usage message.
- Impact: a real person's address in a public repository as a code default (CMA-037 item 4); a run against dev through the proxy picks the owner's login silently.
- Recommendation (the same diff in all six files; the usage line in each header changes to `INGEST_FLOW_ADMIN_USER=<team login> …`):
  ```diff
  -const ADMIN = process.env.INGEST_FLOW_ADMIN_USER ?? "<real address>";
  +const ADMIN = process.env.INGEST_FLOW_ADMIN_USER;
  +if (!ADMIN) {
  +  console.error("INGEST_FLOW_ADMIN_USER is required: a team login that holds cma_owner and cma_app by SET ROLE (locally auditor@local)");
  +  process.exit(2);
  +}
  ```
  For `flow.mjs`, `jobs-flow.mjs`, `aircall-flow.mjs`, `shopify-flow.mjs`, `outbox-flow.mjs` the check goes into the existing `for (const v of ["CMA_DB_HOST", "CMA_DB_USER"])` loop by adding `"INGEST_FLOW_ADMIN_USER"` to the list (one-line change) and dropping the `??` default. `docs/ingest/README.md` Verifiers table: "set `INGEST_FLOW_ADMIN_USER`".
- README check: already open as backlog CMA-037 item 4 (per the brief).
- Disproof attempt: searched for the address elsewhere in `ingest/` and `docs/ingest/` (only these files); confirmed the local runs here used `INGEST_FLOW_ADMIN_USER=auditor@local` and passed, so no code depends on the default.

### 5.2-07: No `statement_timeout` or `idle_in_transaction_session_timeout` on the ingest pools; the 30-second request timeout does not cancel a query
- Severity: Low   Confidence: High   Effort: S
- Component: `ingest/src/core/db.mjs:46-60`
- Evidence: the `pg.Pool` options are `max`, `idleTimeoutMillis: 30_000`, `connectionTimeoutMillis: 10_000`, `application_name`; no `statement_timeout`, `query_timeout`, `lock_timeout` or `idle_in_transaction_session_timeout`; no role-level setting in `db/` (grep for `statement_timeout` empty) and none in `web/src/lib/db/client.ts` either. `server.requestTimeout = 30_000` (`server.mjs:217`) and Cloud Run's `--timeout=30s` end the HTTP exchange, not the query on the pooled client.
- Impact: a long query (`cma.link_calls` over two hours per tenant each minute, an `ingest_upsert_*` waiting on a row lock, `ingest_record_events` of 500 rows) holds one of five connections (service) or three (job) for as long as it runs; with concurrency 20 the other requests wait `connectionTimeoutMillis` 10 s and then fail `db_unavailable` (500, the source retries). Defence in depth; no observed case.
- Recommendation (exact diff, both `new pg.Pool({...})` calls in `db.mjs`):
  ```diff
  -      connectionTimeoutMillis: 10_000, application_name: "cma-ingest-local",
  +      connectionTimeoutMillis: 10_000, application_name: "cma-ingest-local",
  +      statement_timeout: statementTimeoutMs(), idle_in_transaction_session_timeout: 60_000,
  ```
  with `function statementTimeoutMs() { const v = Number(process.env.CMA_DB_STATEMENT_TIMEOUT_MS ?? 25_000); return Number.isFinite(v) && v >= 1000 && v <= 3_600_000 ? v : 25_000; }` (pg sends both as startup parameters). The jobs need longer than the service (a backfill's `ingest_record_events` of 500, `link_calls`): `deploy.sh` sets `CMA_DB_STATEMENT_TIMEOUT_MS=300000` in `JOB_ENV` (`:220`) and leaves the service at the default 25 s (a request's budget is 3 s of read-back plus the writes). That is a new environment variable: CONFIG CHANGE section in the PR, README Database connection budget untouched (no pool or instance change). A `jobs-flow`/`flow` case: `select pg_sleep(…)` through `withTenant` fails `db_57014` within the timeout.
- README check: new; not settled.
- Disproof attempt: looked for a database-side default (`alter role cma_app set statement_timeout`: none in db/); checked that the web app sets none either (it does not; that side belongs to 5.1/5.3).

### 5.2-08: Outbound `fetch` follows redirects and reads any response size; the Shopify token header would follow a cross-origin redirect
- Severity: Low   Confidence: Medium   Effort: S
- Component: `ingest/src/core/http.mjs:37-42`, `ingest/src/adapters/shopify/client.mjs:71-76` (`mintToken`)
- Evidence: `fetch(url, { method, headers, body, signal })` without `redirect`, so Node's default `follow` applies (up to 20 hops); undici drops `authorization` on a cross-origin redirect but not custom headers such as `x-shopify-access-token` (`client.mjs:209`); `res.text()` (`http.mjs:54`) buffers the whole body with no cap on a 512 MiB instance. No vendor API the ingest calls answers with a redirect in normal use; the hosts are pinned (`checkedBase`, the `.myshopify.com` regex).
- Impact: defence in depth only: a redirect at the vendor's edge (a misconfigured shop domain, an interception) would carry the shop token to the redirect's host; an unexpectedly huge answer would take the instance down (`http_` error paths never see it).
- Recommendation: `redirect: "error"` in both `fetch` calls (two one-line changes; `requestJson` then maps the thrown `TypeError` to `SourceError("unreachable")` through its existing catch), and a size cap by reading `res.body` with a counter and `SourceError("bad_response")` above, say, 16 MB (about 20 lines in `requestJson`). `verify/shopify-client.mjs`/`signature.mjs` have fake servers that can answer a 302 for one case.
- README check: new.
- Disproof attempt: confirmed undici strips `Authorization` cross-origin (so HubSpot/Aircall tokens are safe) and that no code path passes user-controlled URLs (5.2 SSRF check below), which keeps this Low.

### 5.2-09: With `INGEST_PUBLIC_URLS` empty the service trusts the request's `Host` header as the signed URI
- Severity: Low   Confidence: High   Effort: S
- Component: `ingest/src/server.mjs:51-55`
- Evidence: `requestUris` falls back to `` [`https://${req.headers.host}${req.url}`] `` when the variable is empty. `deploy.sh` leaves it empty only between a first deploy and the `services update` that follows in the same run (`:315-321`); the incident of 16 October shows the variable is the one knob whose wrong value silently breaks or weakens signature checking. With the fallback, a client chooses the URI it signs for, which still needs the client secret, so it is not an authentication bypass; it does remove the "signed URI equals what the server sees" guarantee (Decision log, 12 October 2026).
- Recommendation (exact diff): refuse on Cloud Run, keep the fallback for local runs (the flow verifier sets the variable, `verify/flow.mjs:153`, so it needs nothing):
  ```diff
   export function requestUris(req) {
     const bases = (process.env.INGEST_PUBLIC_URLS ?? "").split(",").map((s) => s.trim().replace(/\/+$/, "")).filter(Boolean);
     if (bases.length) return bases.map((b) => `${b}${req.url}`);
  +  // On Cloud Run the public URLs are configuration (deploy.sh); never the Host header the client sends
  +  if (process.env.K_SERVICE) throw Object.assign(new Error("INGEST_PUBLIC_URLS is not set"), { code: "public_urls_not_set" });
     return [`https://${req.headers.host}${req.url}`];
   }
  ```
  `handleWebhook` already turns an `authenticate` throw into a 500 with `authentication_error` (`:86-90`); `K_SERVICE` is set on every Cloud Run service. A `signature.mjs` case with `K_SERVICE=1` and no variable → the code.
- README check: new; the 12 October decision is the rationale.
- Disproof attempt: checked whether Cloud Run's load balancer or Cloud Armor pins `Host` (the URL map does by host rule in prod, but the `run.app` ingress path in dev does not); the exposure is small and the fix is a guard, hence Low.

### 5.2-10: `tools/replay.mjs` accepts any `--url`, prod included
- Severity: Low   Confidence: High   Effort: S
- Component: `ingest/tools/replay.mjs:40-48`
- Evidence: the header says "never point it at prod with real ids" (`:3`), but `url` is taken as given; the tool prints status and at most 200 characters of the service's answer (`{"received":n,"new":m}`) and never the secret (`:68, :84` null it; checked). Pointing it at prod needs the prod signing secret, which the runbook keeps in Secret Manager.
- Recommendation (exact diff after `:44`): refuse hosts other than the local machine or a `run.app` address (prod's `run.app` address refuses everyone by ingress, so `run.app` means dev in practice), with an explicit override:
  ```diff
  +const host = (() => { try { return new URL(url).hostname; } catch { return ""; } })();
  +if (!(host === "localhost" || host === "127.0.0.1" || host.endsWith(".run.app")) && !flag("allow-host")) {
  +  fail(`replay goes to a local service or a dev run.app address, not ${host || url}; add --allow-host to insist`);
  +}
  ```
- README check: new (docs/ingest/README.md Replay section says "dev and local only").
- Disproof attempt: looked for a secret or token in the printed output (none: `text.slice(0, 200)` of a counts-only answer; a 401 answer is empty).

### 5.2-11: What the jobs leave for a System health page: the gaps in `sync_run`
- Severity: Info   Confidence: High   Effort: M (design input for 0008r)
- Component: `cma.sync_run` (db/32:440-470), `cma.ingest_sync_run_start/finish` (db/32:1636-1680; finish redefined db/74:787 to accept `dropped`), `ingest/src/jobs/runner.mjs:52-65` (`withRun`), `sweep.mjs`, `outbox.mjs`
- Evidence (what the row holds): `connection_id`, `job` (check constraint: `backfill`, `reconcile`, `forms_poll`, `subscriptions_check`, `link_calls`, `email_poll` since db/68), `stream`, `from_at`, `to_at`, `started_at`, `started_by` (the tenant's Ingest user), `finished_at`, `status` (`running`/`succeeded`/`failed`), `counts` (`fetched`, `upserted`, `stale`, `skipped`, `failed`, `dropped`, whole numbers only), `error` (≤200 chars, a code: `codeOf` never a message). Who writes: `withRun` in poll-forms (`forms_poll`/`forms`), poll-email (`email_poll`/`email`), reconcile (`reconcile`/<object>, plus `subscriptions_check`/`webhooks` for Shopify), backfill (`backfill`/<object>), and the sweep's link step only (`link_calls` on the tenant's first HubSpot connection, `sweep.mjs:79-100`, confirmed).
  Gaps a health page hits:
  1. No row for the sweep's claim, reread, catalog and outbox-guard steps (`sweep.mjs:21-22` by design: "sync_run has no job value for the sweep"), nor for `ingest-outbox` (`outbox.mjs:15`). "Did the sweep run in the last two minutes?" is answerable only from Cloud Logging or from `ingest_event.attempts/next_attempt_at` movement; a tenant without a HubSpot connection (Aircall only) gets no `link_calls` row either (`crmOfTenant` needs `holdsRecords`).
  2. A run that dies before `finish` (task timeout 10 m/60 m/24 h, OOM, SIGKILL) stays `running` forever: `check_sync_run` allows only running → finished and nothing reaps; a page must treat `running` older than the job's task timeout as `lost`.
  3. No image version (`INGEST_VERSION`) anywhere in the database; `/health` shows it per instance only. No execution id, instance id or project.
  4. `started_by` is the Ingest user (always the same per tenant), `error` is the first part's code only (`email-poll.mjs:28`), `counts` has no per-kind detail (that goes to the log line as `outcomes`), and the webhook path writes no row (its audit is the event log: `status`, `attempts`, `error`, `next_attempt_at` per event).
  5. The schema is append-only per run, so a page cannot store a "seen" or "acknowledged" flag on it.
- Recommendation: for 0008r (`db/78`/`79`), add `sweep` and `outbox` to the job vocabulary (the sweep writes one row per run with counts claimed/processed/failed as `fetched/upserted/failed` and the connection count in `stream`), add `version text` to `sync_run` filled by `ingest_sync_run_start` from a session setting the jobs set (`set_config('app.ingest_version', INGEST_VERSION, true)` in `withTenant`) or a parameter, and a view `cma_read.ingest_health` that marks `running` rows past the job's timeout as `lost` and gives per job the last start, last success, last failure and its code. Catalog entries for both.
- README check: new as design input; the sweep's "events are its own audit" is settled (Architecture bullet).
- Disproof attempt: none needed (observation).

### 5.2-12: Aircall pacing is per process; the documentation's "stays under 120" holds for two processes, not for eight (CMA-040)
- Severity: Info   Confidence: High   Effort: M
- Component: `ingest/src/adapters/aircall/read.mjs:66-76` (`paces` per connection and process), `docs/ingest/README.md` Aircall, Pacing
- Evidence: `paceOf` keeps one `Pace` per connection **per process**; `docs/ingest/README.md:240` says "The pace is per process: the service and a job running at the same time can each use the limit, which stays under Aircall's 120 while the setting is 60 or less." In prod the processes are up to 5 service instances (`deploy.sh` `MAX=5`) plus `ingest-sweep` every minute, `ingest-reconcile` nightly and `ingest-backfill` by hand, so 6 to 8 processes × 60 = 360 to 480 requests a minute are allowed by the code against Aircall's 120 per company (shared with three other integrations' keys, same section). Mitigations in place: a 429 holds that connection in that process until `X-AircallApi-Reset` (`read.mjs:120-131`), events fail `rate_limited` and the sweep retries; each webhook reads one call. Observed volumes (README, 13 October: about 2.5 requests a second at peak on the load balancer, all sources) make the limit rarely reached.
- Recommendation: already open as CMA-040 (per the brief): an account-wide bucket in the database (a row per connection with the last slot time, taken `for update`, or a `pg_advisory_xact_lock` per connection around the pace), or a lower default (`120 / 8 = 15` per process) and the doc sentence corrected either way.
- README check: already open (CMA-040); the Pacing paragraph's claim is the doc drift to fix.
- Disproof attempt: checked whether the sweep and the service share a process (no: Cloud Run jobs are separate containers) and whether `INGEST_PACE_FACTOR` is set in prod (no: never set on Cloud Run).

### 5.2-13: The image base is pinned by tag, not digest
- Severity: Info   Confidence: High   Effort: S
- Component: `ingest/Dockerfile:5, 10` (`FROM node:22-alpine`)
- Evidence: the base is a moving tag; the image is built once per `ingest/` sha and reused by tag (`deploy.sh:187-197`), so prod and dev run the same bytes, but a rebuild of the same sha on another day (the tag deleted, a new repository) pulls a different base. Non-root user, `npm ci --omit=dev --no-audit --no-fund`, `.dockerignore` excludes `verify`, `tools`, `node_modules` and the lint config: all fine. `cloudbuild.yaml` also pushes `:latest`, which nothing deploys (harmless).
- Recommendation: `FROM node:22-alpine@sha256:<digest>` in both stages, refreshed deliberately (a PR), and drop the `latest` tag from `cloudbuild.yaml` so the registry holds only deployed shas.
- README check: new (hygiene).
- Disproof attempt: n/a.

---

## Flow verifier verdicts (observed, local PostgreSQL 16, `CMA_DB_USER=cma-ingest@local.iam`, `INGEST_FLOW_ADMIN_USER=auditor@local`; outputs in `/var/tmp/5.2/<name>.txt`)

| Verifier | Plain | `--provoke` | Runtime (observed) |
|---|---|---|---|
| `verify/flow.mjs` | `ALL 80 PASS` | `ALL 80 PROVOKED CHECKS FAILED, as they must` | 3 s / 4 s |
| `verify/jobs-flow.mjs` | `ALL 75 PASS` | `ALL 75 PROVOKED CHECKS FAILED, as they must` | 3 s / 4 s |
| `verify/aircall-flow.mjs` | `ALL 88 PASS` | `ALL 88 PROVOKED CHECKS FAILED, as they must` | 7 s / 7 s |
| `verify/shopify-flow.mjs` | `ALL 86 PASS` | `ALL 86 PROVOKED CHECKS FAILED, as they must` | 32 s / 31 s |
| `verify/outbox-flow.mjs` | `ALL 11 PASS` | `ALL 11 PROVOKED CHECKS FAILED, as they must` | 1 s / 1 s |
| `verify/email-flow.mjs` | `ALL 34 PASS` | `ALL 34 PROVOKED CHECKS FAILED, as they must` | 3 s / 4 s |

All twelve runs exit 0. No sandbox artefact appeared (no `uuidv7` or PostgreSQL-version failure); the headers' migration requirements (00…33, 00…74, 00…55, 00…58, 00…58, 00…69) are all within the local 00…75. `email-flow` found the dev seed's test user and ran. `npm run lint`: clean (exit 0). `npm test`: 14 pure verifiers, `ALL n PASS` each (18, 48, 26, 48, 20, 49, 27, 17, 51, 21, 21, 20, 76, 10 = 452 checks), exit 0.

## Checked and found clean

- **Request handling** (`rawbody.mjs`, `server.mjs`): body capped at 1 MB by declared length and by bytes read (`rawbody.mjs:16-33`), 413; a chunked body that never ends is cut by `server.requestTimeout = 30_000` (`server.mjs:217`, Node's whole-request timeout) and by Cloud Run's 30 s; route regex `^/([a-z0-9_]+)/([^/?#]+)/?$` with `Object.hasOwn(adapters, …)` (`:37, :201`), method other than POST → 404 with the body drained (`:202-205`); every error path logs a code only (`:208 err?.code ?? "error"`); the key is validated (`connection.mjs:10` `KEY` regex) before the one parameterised lookup; content type is not checked (JSON parsed after authentication; acceptable). Prototype pollution: payloads are read with `?.` and lookup tables with `Object.hasOwn`; no `Object.assign`/deep merge of a payload into a shared object (`events.mjs:23` spreads the adapter's own `raw`).
- **The order "authenticate before anything else touches the database"**: the key lookup `cma.ingest_connection(key)` (SECURITY DEFINER, `withoutTenant`) runs before `authenticate` (`server.mjs:70-96`); `docs/ingest/README.md` names exactly this exception ("Authenticate before anything but the key lookup touches the database") and README's Architecture bullet ("anything else") is consistent with it. The lookup is one indexed read with no tenant context; for the HubSpot adapter a cold secret cache also costs one Secret Manager read before the header check (once per 5 minutes). Acceptable; in prod Cloud Armor throttles per IP first.
- **404 versus 401 leaks connection existence**: accepted by README (Decision log, 12 October 2026: the key is an identifier, not a secret; the signature is the proof).
- **Signature checks**: HubSpot v3 (`hubspot/verify.mjs`): method + URI + body + timestamp, timestamp `^\d{10,16}$` within ±5 minutes, every configured public base computed and compared (`:52-55`), `timingSafeEqual` on equal-length buffers; Aircall token (`aircall/verify.mjs`) and Shopify HMAC (`shopify/verify.mjs`) the same compare; the automation bearer hashes both sides before `timingSafeEqual` (`automation/index.mjs:19-23`), so even the length does not leak. An empty secret in Secret Manager (the Aircall runbook creates it empty first) is `SecretUnavailable("empty")` → 500, fail closed (`secrets.mjs:70`).
- **Duplicate headers** (Node joins duplicates with `, `): `x-hubspot-signature-v3` twice → a 89-character string → length mismatch → `bad_signature`; `x-hubspot-request-timestamp` twice → fails the digit regex → `bad_timestamp`; `x-shopify-hmac-sha256` twice → fails `^[A-Za-z0-9+/]{43}=$` → `missing_header`; `x-shopify-shop-domain` twice → not the connection's account → `portal_mismatch`, ignored; `x-shopify-webhook-id` twice → fails `DELIVERY_ID` → falls back to the event id or a body digest (`shopify/map.mjs:84-86`). All fail closed.
- **Pinning**: HubSpot `portalId` against `external_account_id` (`hubspot/map.mjs:132`), Shopify shop domain (`shopify/map.mjs:95`), Aircall by one webhook token per connection (documented; `aircall-webhook.mjs` refuses a key of another company).
- **Replay** (`INGEST_ALLOW_REPLAY`): read from the environment only (`aircall/read.mjs:50-52`) and needs the connection setting too (`:55-57`); `deploy.sh` sets it in dev only (`:97-98`) and `--set-env-vars` replaces every variable, so a Console-added value does not survive a deploy; `verify/deploy-script.mjs:124` proves prod gets none. Idempotency keys per adapter: `hs:<eventId>`, `ac:<event>:<call id>:<timestamp>`, `sh:<webhook id>` (fallbacks), `sync:<type>:<id>:<version>` and `reread:` (`events.mjs`, `sync.mjs:27`), known keys never written again (`ingest_record_events`).
- **Secrets** (`secrets.mjs`): names only in the database, `^[A-Za-z0-9_-]{1,255}$` before the URL, 5-minute cache per name, value never in a message or log (the `SecretUnavailable` message holds the name, and only its code is logged), Secret Manager 403/404/other → `secret_unavailable`; rotation: a vendor 401 does not clear the cache (HubSpot events fail `http_401` and the sweep retries; the Shopify client drops its minted token on 401, `client.mjs:212`) and the new version is read within five minutes, as `PROD_RUNBOOK.md` 9.3 states. Acceptable.
- **SSRF and URL templates**: no `record_url_*` is used by the ingest (web only); outbound hosts are `https://api.hubapi.com`, `https://api.aircall.io` (overridable only through `checkedBase`: https, or http to `localhost`/`127.0.0.1`, `http.mjs:21-31`), `https://<handle>.myshopify.com` pinned by regex with the same rule for `INGEST_SHOPIFY_API_BASE` (`client.mjs:30, 40-49`), the metadata server and `secretmanager.googleapis.com` with the project `encodeURIComponent`ed; `page.mjs` parses landing pages only to reduce them to host, path and UTM. No credential in any URL (tokens travel in headers or form bodies).
- **Logging**: every `info/warn/error` call in `ingest/src` carries connection ids, adapter names, counts, durations and codes (listing in "Commands run"); `headerNames` only with `INGEST_LOG_HEADER_NAMES=1`; `detail`/`outcomes` in the email poll are tallies per kind (`email.mjs:116-120`); `dbErrorCode` reduces pg errors to `db_<SQLSTATE>`; `SourceError` carries a code and, for 429, rate-limit header names and values only (`http.mjs:48`); the one `err.message` logged is a `UsageError` built from argument names (`runner.mjs:77`). The flow verifiers grep every row and log line for the fixture emails and numbers and passed here.
- **Concurrency and connections**: no database connection is held while waiting on a vendor: `claimEvents`, each `store.*` read and `applyUnits` are separate transactions (`process.mjs:36-53`; `store.mjs` has no `fetch`); the per-call signal is 10 s on the route, 20 s in jobs (`budget.mjs`); pool 5 per instance with `connectionTimeoutMillis` 10 s under concurrency 20 is the documented budget (README line 153); the automation route sends each message in its own short transaction.
- **Deploy and ops scripts**: `set -euo pipefail` in all three; arguments validated by regex (tenant slug, secret name, cron, host, numbers); `env_list` refuses a value holding the delimiter; the `--front` guard runs before any gcloud call (`deploy.sh:128-130`, verified by `verify/deploy-script.mjs`, 10 checks PASS here); the dry runs of `front.sh` and `alert.sh` make no call; `--no-invoker-iam-check` plus `--ingress=all` in dev is the decided state (dev keeps its `run.app` address, 12 October 2026); peppers generated with `openssl rand -hex 32` straight into `versions add` (never printed); accessor grants per named secret. The helpers never print a token or secret: `aircall-webhook.mjs` pipes the webhook token into `gcloud secrets versions add --data-file=-` and prints "(not shown)" (`:143-148`); `shopify-subscribe.mjs`, `hubspot-owners.mjs`, `hubspot-email-check.mjs` and `aircall-users.mjs` read the secret with the caller's own `gcloud`, hold it in memory and null it; `hubspot-owners.mjs`/`aircall-users.mjs` print SQL statements with owner ids and emails to the operator's terminal by design (they are pasted into Studio).
- **Dockerfile**: two stages, `npm ci --omit=dev`, non-root `app` user, only `package.json`, `src` and `jobs` copied; `.dockerignore` excludes `verify`, `tools`, `node_modules`.
- **`verify/deploy-script.mjs`**: covers the 16 October guard (prod without `--front`, with `--tenant`/`--secret`, `--jobs --front` refused, prod `--jobs` six jobs, dev's ingress and replay, prod `--front`'s ingress, URLs and no replay variable). It does not cover the branch (5.2-05).

## Not checked / could not check

- Anything live: Cloud Run revisions, Scheduler entries, Cloud Armor, Secret Manager grants, the prod `sync_run` table (rule 1). The claims about prod configuration are read from `deploy.sh`, `front.sh` and README.
- The HubSpot adapter's read-back failure isolation in depth (`hubspot/read.mjs` 600 lines; its structure uses per-step try/catch with `failAll` and catalog refresh isolated at `:165-180`), the forms and conversations modules, and `store.mjs` beyond the transaction boundaries and the SQL of interest: out of this area's scope (the task named the Shopify path).
- A load test of concurrency 20 against pool 5 (would need a running service; port 8080 reserved).
- Whether undici's redirect handling in this Node 22 build strips `Authorization` (asserted from the fetch specification and undici's implementation, not run).

## Commands run

| Command | Outcome |
|---|---|
| `cd ingest && npm run lint` | exit 0, no output (clean) |
| `cd ingest && npm test` | exit 0; 14 verifiers, `ALL n PASS` each, 452 checks in all (`/var/tmp/5.2/test.txt`) |
| `/var/tmp/5.2/run-flows.sh` (the six flow verifiers, plain and `--provoke`, `timeout 900` each, env as in the table above) | 12 runs, each its expected verdict, exit 0 (`/var/tmp/5.2/flows-summary.txt`, per-run outputs alongside) |
| `pg_isready -h 127.0.0.1 -p 5432`; `psql -U postgres -d cma` version and roles | PostgreSQL 16.15, 2 tenants in the seed, the four audit logins present |
| `grep -rn -E '\b(info\|warn\|error)\(' ingest/src` | 52 log calls listed and read; all fields are ids, codes, counts, names of headers |
| `grep -rn -E 'record_url\|new URL\(\|fetch\(\|https://\|http://\|API_BASE' ingest/src` | 16 sites listed and read (SSRF check above) |
| `grep -n 'pg_try_advisory\|advisory' ingest/ db/ docs/ingest/` | none |
| `grep -n -i 'statement_timeout' db/*.sql web/src/lib/db/client.ts README.md` | none |
| `git log --oneline -3 -- ingest/src/adapters/shopify/{client,read,match}.mjs` | unchanged since B10 / B10.1 |
| README reads: line 123 (Architecture, Ingest API), 153 (Database connection budget), Decision log lines 1868-1871, 1878, 1902, 1912, 1916-1917, 1946, 1974, 1981, 1999-2000; Open decisions 2015, 2064, 2078, 2088; `docs/ingest/README.md` 1-64, 65-185, 226-287, 371-460; `docs/ingest/PROD_RUNBOOK.md` 629-654; the incident record | read in full for the sections named |
