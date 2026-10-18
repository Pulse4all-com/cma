# 5.4 Infrastructure as code (static) and 5.5 Reliability and uptime: findings

Examined, read-only and locally only (no gcloud, no call to any Pulse4all host): `cloudbuild.yaml`, `ingest/cloudbuild.yaml`, both Dockerfiles and `.dockerignore` files, the seven scripts under `docs/{ingest,scheduler,nocodb,signed-out}/` plus `urlmap.py` and `service.template.yaml`, `ingest/verify/deploy-script.mjs`, the runtime code for shutdown, pooling, retries and dead letters (`web/src/lib/db/client.ts`, `web/src/lib/config.ts`, `web/src/lib/auth/iap.ts`, `web/src/proxy.ts`, `web/src/app/api/health/route.ts`, `ingest/src/server.mjs`, `ingest/src/core/{db,http,events,process,sync,budget,pace,store}.mjs`, `ingest/src/jobs/{runner,sweep}.mjs`, `web/jobs/close-forgotten-workdays.mjs`), the library behaviour they rely on (`pg-pool` 3.14.0, `jose` 6.2.12, `@google-cloud/cloud-sql-connector` 1.12.0, Next 16.3.8 `start-server.js`), README (Architecture, Environments and infrastructure incl. Database connection budget and Build and deploy, Release flow, Decision log rows 1677, 1757, 1758, 1798, 1859, 1871, 1904, 1916, 1917, 1951, 1981, Open decisions 2017 and 2138), `docs/RUNBOOK.md`, `docs/ingest/README.md` (Jobs, Deploy), `docs/a5-audits/MORNING_RUNBOOK.md`, `records/ingest-front-incident-2026-10-16/README.md`, and the `records/` tree for any restore drill. Two live local runs of the standalone web server (built by the lead) on ports 8097/8098 proved how a mis-configured revision behaves at startup. About three hours.

Most important: (1) `check-config` and Cloud Run's default TCP startup probe together let a `cma-web` revision that refuses or fails every request go live in prod (observed locally: `/api/health` 200 while every page is 401 without `IAP_AUDIENCE`; health and pages 500 with a bad `CMA_AUTH_MODE`); (2) no `statement_timeout` or `idle_in_transaction_session_timeout` exists anywhere, so five slow statements starve a web instance (pool 5, 10 s connect timeout); (3) ingest events parked as `needs_review` have no clearing path and no Data quality row, so a vendor outage of about four hours parks events for good. Counts: High 1, Medium 5, Low 6, Info 2. INFRA-01 is High and not fixed here: under hard rule 7 the lead describes it generically in anything that reaches the public repository.

Line numbers refer to commit `35ea3e0` (main as checked out at the start). While this file was written, other audit agents left uncommitted changes in the working tree to `web/.dockerignore` (adds `!documents/**`), `web/jobs/close-forgotten-workdays.mjs` (sync_run rows for 0008r), `web/package.json`, `db/78_*`, `db/79_*` and others; my citations into those files are to the committed version, and the `.dockerignore` negation should be re-read by whoever reviews INFRA-08's "clean" note on the build context (a `documents/` folder would now enter the web build context). Severity scale and "observed / expected / estimated" wording follow the preamble. Every proposed change below is a proposal (unified diff or labelled steps), nothing was applied. Changes to `cloudbuild.yaml` deploy flags, service environment variables or Cloud Run caps are marked **CONFIG CHANGE** with the connection-budget arithmetic (README line 153: cma-web 4 × 5 = 20, cma-ingest 5 × 5 = 25, ingest jobs 15, scheduler 2, NocoDB 6, BigQuery 5, team 10 = 83 of 97 usable).

---

### INFRA-01: A mis-configured `cma-web` revision passes the deploy and goes live (check-config gap plus TCP-only startup probe)
- Severity: High   Confidence: High (mechanism observed; the likelihood of the trigger is estimated)   Effort: S
- Component: `cloudbuild.yaml` (check-config and deploy steps), `web/src/lib/config.ts`, `web/src/app/api/health/route.ts`, `web/src/proxy.ts`
- Evidence:
  - `cloudbuild.yaml:33-41`: check-config tests only `_DATA_MODE=api` without `_DB_INSTANCE`/`_DB_USER` and the `_LOGOUT_TARGET` value. It does not test `_IAP_AUDIENCE` when `_AUTH_MODE=iap`, nor the values of `_AUTH_MODE`/`_DATA_MODE`, nor that `_MAX_INSTANCES`/`_DB_POOL_MAX` are numbers. The file's own defaults are `_AUTH_MODE: iap`, `_DATA_MODE: mock`, `_IAP_AUDIENCE: ""` (`cloudbuild.yaml:79-81`) and its header says it "runs by hand with `gcloud builds submit`" (`cloudbuild.yaml:3`); README line 163 documents manual builds.
  - `cloudbuild.yaml:57-69`: the deploy step passes no `--startup-probe`; Cloud Run's default startup probe is a TCP connect on the container port (expected from Cloud Run's documented default), so any container that listens is "ready" and takes 100 % of traffic.
  - `web/src/lib/config.ts:25`: `iapAudience: process.env.IAP_AUDIENCE ?? ""` (no throw). `web/src/lib/auth/iap.ts:47`: `if (!opts.audience) throw new IapVerifyError("IAP audience is not configured")`, raised per request. `web/src/proxy.ts:107`: `/api/health` is outside the gate.
  - Observed (standalone server built by the lead, `CMA_AUTH_MODE=iap`, no `IAP_AUDIENCE`, port 8098): `GET /api/health` → 200 `{"status":"ok",...,"auth":"iap"}`; `GET /` → 401 `x-cma-auth: missing`; `GET /day` with a syntactically valid token → 401 `x-cma-auth: invalid`; server log `iap: token rejected: IAP audience is not configured`. The deploy would succeed; every person would be refused.
  - Observed (`CMA_AUTH_MODE=bogus`, port 8097): the server prints `Ready in 0ms` and listens; `/api/health`, `/` and `/day` all answer 500 (`Error: CMA_AUTH_MODE must be one of iap, mock, got "bogus"` at module evaluation on the first request). `config.ts:14-19` throws, but only when the module is first imported, which Next does at the first request, not at startup, so a TCP probe passes.
  - Realistic triggers: `docs/RUNBOOK.md:336-350` changes prod configuration by exporting the trigger to YAML, editing it by hand and importing it (a dropped or mistyped `_IAP_AUDIENCE` line deploys the empty default); a manual `gcloud builds submit` on the root config without `--substitutions` deploys `mock` data and an empty audience to the service named in the file (`cma-web`, in whatever project the build runs).
- Impact (in this system's context): a successful-looking build (SUCCESS in `gcloud builds list`, a new revision with 100 % traffic) that locks every agent and manager out of `workspace.pulse4all.app` mid-shift, or serves mock data in prod, until someone notices and rolls traffic back by hand (`docs/RUNBOOK.md:352-366`). Nothing alerts on it (INFRA-06). The 16 October ingest incident (`records/ingest-front-incident-2026-10-16/README.md:10-17`) was the same class: a deploy whose flags fell back to defaults, caught by people, not by the pipeline.
- Recommendation: three small parts; (a) is a plain guard, (b) and (c) are a **CONFIG CHANGE** (deploy flags and one new substitution with a safe default; no environment variable value, cap or pool changes; connection budget unchanged at 4 × 5 = 20).

  (a) check-config validates the audience and the numbers (`cloudbuild.yaml`, inside the `bash -c` block after line 40):
  ```diff
           esac
  +        if [ "${_AUTH_MODE}" = "iap" ] && ! [[ "${_IAP_AUDIENCE}" =~ ^/projects/[0-9]+/global/backendServices/[0-9]+$ ]]; then
  +          echo "_AUTH_MODE=iap needs _IAP_AUDIENCE as /projects/<number>/global/backendServices/<id>, got '${_IAP_AUDIENCE}'; nothing deployed"
  +          exit 1
  +        fi
  +        case "${_AUTH_MODE}/${_DATA_MODE}" in
  +          iap/api) ;;
  +          *) [ "${_ALLOW_MOCK}" = "1" ] || { echo "a mock mode (_AUTH_MODE=${_AUTH_MODE}, _DATA_MODE=${_DATA_MODE}) needs _ALLOW_MOCK=1 on this build; nothing deployed"; exit 1; } ;;
  +        esac
  +        [[ "${_MAX_INSTANCES}" =~ ^[1-9][0-9]{0,2}$ ]] && [[ "${_DB_POOL_MAX}" =~ ^[1-9][0-9]?$ ]] || { echo "_MAX_INSTANCES and _DB_POOL_MAX must be positive integers; nothing deployed"; exit 1; }
           echo "config: auth=${_AUTH_MODE} data=${_DATA_MODE} db=${_DB_INSTANCE} max-instances=${_MAX_INSTANCES} pool=${_DB_POOL_MAX} logout=${_LOGOUT_TARGET}"
  ```
  with, under `substitutions:`, `_ALLOW_MOCK: "0"` (CONFIG CHANGE: a new substitution; the prod trigger needs no change because it runs iap/api). Alternative without a new substitution: refuse a mock mode when `$PROJECT_ID` is the prod project; it hardcodes the project id in the build file, as `docs/ingest/deploy.sh:97-98` already does.

  (b) The deploy waits for a health check that fails on an unusable configuration (CONFIG CHANGE, deploy flag only; untested here, dry-run in dev first with `gcloud run services update cma-web --project=p4a-cma-dev ... --startup-probe=...`):
  ```diff
         - --max-instances=${_MAX_INSTANCES}
  +      - --startup-probe=httpGet.path=/api/health,initialDelaySeconds=1,periodSeconds=3,timeoutSeconds=3,failureThreshold=10
         - --set-env-vars=...
  ```
  Expected after the change: a revision whose `/api/health` answers 503 or 500 never becomes Ready; `gcloud run deploy` fails after about 30 s and the previous revision keeps all traffic.

  (c) `/api/health` says so when the configuration cannot work, without a database round trip (so a database outage never stops instances from starting), `web/src/app/api/health/route.ts`:
  ```diff
   import { config } from "@/lib/config";

  -// Liveness for Cloud Run and for the deploy step's smoke test. No user data.
  +const AUDIENCE_RE = /^\/projects\/\d+\/global\/backendServices\/\d+$/;
  +
  +// Startup and liveness check for Cloud Run (the deploy's startup probe) and the deploy step's smoke
  +// test. No user data and no database round trip: a 503 keeps a mis-configured revision from taking
  +// traffic, a database outage never keeps an instance from starting. Variable names only, no values.
   export function GET() {
  +  const problems: string[] = [];
  +  if (config.authMode === "iap" && !AUDIENCE_RE.test(config.iapAudience)) problems.push("IAP_AUDIENCE");
  +  const dbConfigured = Boolean(process.env.CMA_DB_HOST || (process.env.CMA_DB_INSTANCE && process.env.CMA_DB_USER));
  +  if (config.dataMode === "api" && !dbConfigured) problems.push("CMA_DB_INSTANCE, CMA_DB_USER");
     return Response.json(
  -    { status: "ok", version: config.version, auth: config.authMode, data: config.dataMode },
  -    { headers: { "cache-control": "no-store" } },
  +    { status: problems.length ? "misconfigured" : "ok", version: config.version, auth: config.authMode, data: config.dataMode,
  +      ...(problems.length ? { problems } : {}) },
  +    { status: problems.length ? 503 : 200, headers: { "cache-control": "no-store" } },
     );
   }
  ```
  A bad `CMA_AUTH_MODE` value already makes this route 500 (observed), which the probe also refuses. `CMA_DB_HOST` is honoured so the local API verifier (`client.ts:111-128`) still sees 200.
- README check: new. Decision 1677 (5 Oct) and line 165 describe check-config as stopping a build when api mode lacks its database variables; nothing covers the audience, the mode values or readiness. Open decision 2017 (a build-only trigger so dev verifies before prod) and CMA-068 (2138) would reduce how often an untested build reaches prod but do not catch a bad substitution on the prod trigger itself; INFRA-14 notes they move up.
- Disproof attempt: I looked for anything that evaluates `config.ts` at process start (an `instrumentation.ts`, a custom `server.js`): none (`web/src/instrumentation*.ts` absent; `next.config.ts` only sets `output: "standalone"`); the observed `Ready in 0ms` followed by 500s confirms lazy evaluation. I checked whether Cloud Run's deploy could fail on a 401/500 health: it cannot, the default probe is TCP. I checked whether `_IAP_AUDIENCE` could be empty on the prod trigger today: README line 149 records the value set on 5 October, so the gap is in the guard, not the current state.

### INFRA-02: `cma-web`'s runtime settings live in the console, not in `cloudbuild.yaml`; no startup CPU boost on the web service
- Severity: Medium   Confidence: High   Effort: S
- Component: `cloudbuild.yaml:57-69` (deploy step)
- Evidence: the deploy passes `--region`, `--image`, `--port=8080`, `--max-instances`, `--set-env-vars`, `--quiet` and nothing else. `gcloud run deploy` keeps an existing service's other settings as they are (expected, documented gcloud behaviour), so `min-instances=1` (README line 149, "Since 12 October 2026", decision 1859), the service account `cma-web@…` and the ingress `internal-and-cloud-load-balancing` (README line 147), and whatever CPU, memory, concurrency, request timeout, CPU boost and invoker setting the service holds were set by hand and are nowhere in the repository. README 1677 and `cloudbuild.yaml:5-8` call the file "the one place the service is configured", which is true for the environment variables and `--max-instances` only. The ingest side pins every cap in `docs/ingest/deploy.sh:300-313` (`--concurrency=20 --min-instances --max-instances --cpu=1 --memory=512Mi --cpu-boost --timeout=30s --ingress --service-account`), and `--cpu-boost` was added there on 13 October (decision 1917, `MORNING_RUNBOOK.md:5`) but not to `cma-web`, although every web deploy (several a day during build-out) starts the new revision's first instance cold while `min-instances=1` only keeps the old revision warm.
- Impact: drift between what the team believes (README) and what runs; a recreate of the service (new project, a deleted service, a disaster-recovery rebuild) from `cloudbuild.yaml` would silently get Cloud Run's defaults: ingress `all` (the `run.app` address open next to IAP), the default compute service account (no `cma_app` membership, so the app would fail, but also an identity with whatever roles that account holds), `min-instances=0`, concurrency 80, timeout 300 s, no boost. Without boost every deploy adds a cold start of a few seconds for the first users of the new revision (estimated; not measured here).
- Recommendation (**CONFIG CHANGE**: deploy flags; the connection budget is unchanged at 4 × 5 = 20 because `--max-instances` and `CMA_DB_POOL_MAX` stay as they are). First record the live values, then pin exactly those, so the first run changes nothing but makes the configuration reproducible:
  **Terminal** (read-only)
  ```bash
  gcloud run services describe cma-web --project=p4a-cma-prod --region=europe-west4 --format='yaml(spec.template.metadata.annotations,spec.template.spec.containerConcurrency,spec.template.spec.timeoutSeconds,spec.template.spec.serviceAccountName,spec.template.spec.containers[0].resources,metadata.annotations)'
  ```
  Expected: the annotations `autoscaling.knative.dev/minScale: "1"`, `run.googleapis.com/ingress: internal-and-cloud-load-balancing`, `run.googleapis.com/startup-cpu-boost` (present or absent), `containerConcurrency`, `timeoutSeconds`, `serviceAccountName: cma-web@p4a-cma-prod.iam.gserviceaccount.com`, `resources.limits` (cpu, memory). Then, with those values filled in:
  ```diff
         - --port=8080
         - --max-instances=${_MAX_INSTANCES}
  +      - --min-instances=1
  +      - --service-account=cma-web@${PROJECT_ID}.iam.gserviceaccount.com
  +      - --ingress=internal-and-cloud-load-balancing
  +      - --cpu=<as observed>
  +      - --memory=<as observed>
  +      - --concurrency=<as observed>
  +      - --timeout=<as observed>
  +      - --cpu-boost
  ```
  `--cpu-boost` is the one deliberate change (the 13 October reasoning for `cma-ingest` applies to the web service's deploys and scale-outs the same way). Do not add `--allow-unauthenticated`/`--no-allow-unauthenticated` without reading the current invoker policy first (`gcloud run services get-iam-policy cma-web …`); the load balancer path depends on it. README: Environments and infrastructure (the `cma-web` paragraph, line 149) and a Decision log row.
- README check: decision 1859 (min-instances=1, 12 Oct) and line 147 (service account, ingress) describe the intended state; putting them in code is implementing, not reopening. CPU boost for `cma-web` is new (1917 covers `cma-ingest` only).
- Disproof attempt: I checked whether a Cloud Run service YAML or a second deploy script for `cma-web` exists in the repository: none (`docs/scheduler/deploy.sh` deploys the job only; `docs/signed-out`, `docs/ingest/front.sh` touch the load balancer). I checked whether `min-instances` might be a trigger substitution: it is not (`cloudbuild.yaml:75-87`).

### INFRA-03: No `statement_timeout` or `idle_in_transaction_session_timeout` anywhere; a few slow statements starve an instance
- Severity: Medium   Confidence: High   Effort: S
- Component: `web/src/lib/db/client.ts:137-145`, `ingest/src/core/db.mjs:59-60`, `web/jobs/close-forgotten-workdays.mjs:46`, `db/*.sql`
- Evidence: `grep -rn 'statement_timeout\|idle_in_transaction' README.md db/*.sql web/src ingest/src docs/*.md` → nothing. The pools are `max` 5 (web, ingest service), 3 (ingest jobs), 2 (scheduler) with `connectionTimeoutMillis: 10_000`. `pg` 8.23.1 supports `statement_timeout`, `lock_timeout` and `idle_in_transaction_session_timeout` as client configuration sent as session parameters at connect (`web/node_modules/pg/lib/client.js:558-565`, `connection-parameters.js:121-123`), so no migration is needed. The web app's request timeout is Cloud Run's default 300 s (INFRA-02), so a request can hold a connection for five minutes. Reports and exports (`/reports/*`, `/configuration/exports`, `/api/v1/reports/*`) run tenant-wide aggregations over months; a lock wait or a plan regression on one of them is the plausible trigger.
- Impact: expected from the code: five slow statements on one `cma-web` instance hold all five connections; every other request on that instance waits up to 10 s in `pool.connect()` and then fails with `DB_UNAVAILABLE` ("database unavailable", `client.ts:188`), including clock-ins and status changes; with 4 instances the load balancer spreads it, so it shows as intermittent errors. On the instance side, long idle transactions would also pin RLS context and locks. The connection budget (README 153) counts connections, not their duration; a bounded statement time is what keeps the count meaningful.
- Recommendation (proposed, not applied: it touches the write paths of time, pay and ingest; rule 10). Web and ingest, the same shape, with a per-process ceiling read from the environment so jobs can run longer:
  ```diff
  --- a/web/src/lib/db/client.ts
  @@ dbConfig()
  +    statementTimeoutMs: Number(process.env.CMA_DB_STATEMENT_TIMEOUT_MS ?? 30_000),
  @@ open(), both pg.Pool({...}) blocks
       connectionTimeoutMillis: 10_000,
  +    // A statement that runs longer is cancelled (SQLSTATE 57014 → DB_ERROR), so one slow report
  +    // never holds the pool; a transaction left idle is closed after 30 s
  +    statement_timeout: cfg.statementTimeoutMs,
  +    idle_in_transaction_session_timeout: 30_000,
  ```
  and the same two keys in `ingest/src/core/db.mjs:46-60` (`CMA_DB_STATEMENT_TIMEOUT_MS`, default 15 000 for the service whose request timeout is 30 s) and `web/jobs/close-forgotten-workdays.mjs:36,46` (120 000). **CONFIG CHANGE** for the jobs: `docs/ingest/deploy.sh:220` adds `"CMA_DB_STATEMENT_TIMEOUT_MS=120000"` to `JOB_ENV` (reconcile and backfill batches of 500 may legitimately run longer than a webhook's statement); no change to pools or instances, budget unchanged. Add `57014` (query_canceled) to the SQLSTATEs `translateDbError` maps (`client.ts:72-77`) so the UI says "took too long" rather than "database error", via `src/lib/copy.ts`. Verify locally against the sandbox database: `select pg_sleep(40)` through `withTenant` must fail with 57014 after 30 s.
- README check: new (the connection budget paragraph, line 153, counts ceilings and says "normal runs take seconds"; nothing bounds a statement). Decision 1951 (15 Oct, `max_connections` stays 100) is untouched: this proposal uses fewer connection-seconds, not more connections.
- Disproof attempt: I checked `cma_app`'s role settings in the migrations for an `alter role … set statement_timeout` (none in `db/00`–`75`) and Cloud SQL flags in README (none named). I checked that no transaction spans an HTTP call in the ingest read-back, so an idle-in-transaction limit of 30 s cannot cut a legitimate wait: `process.mjs:36-53` claims in one transaction, calls the adapter outside any transaction, writes in another (`store.mjs` header: "short transactions").

### INFRA-04: On SIGTERM the web app ends its pool while Next is still draining requests
- Severity: Low   Confidence: Medium   Effort: S
- Component: `web/src/lib/db/client.ts:125-127, 147-151`; Next `start-server.js:321-347, 387-389`
- Evidence: `client.ts` registers `process.once('SIGTERM', shutdown)` with `shutdown = async () => { try { await pool.end(); } finally { connector.close(); } }`. Next's standalone server registers its own SIGTERM handler (`node_modules/next/dist/server/lib/start-server.js:387-389`) that first `server.close()`s (stop accepting, let in-flight requests finish), then closes the Next server and exits 143. Both handlers run at the signal, so the pool ends while requests are still in flight. `pg-pool` 3.14.0 refuses any new checkout after `end()` (`web/node_modules/pg-pool/index.js:191-192`: `Cannot use a pool after calling end on the pool`) and only lets already-checked-out clients finish. A page render runs several `withTenant` transactions in sequence (layout and page data), so a request in flight at SIGTERM fails at its next transaction with `DB_UNAVAILABLE`. Cloud Run gives 10 s after SIGTERM and stops routing new requests to the instance first (expected), so the window is the in-flight requests of the moment. The ingest service orders it correctly: `server.mjs:219-222` closes the server, then `closeDb()`, then exits, with a 9 s fallback exit inside Cloud Run's 10 s.
- Impact: a handful of "database unavailable" answers per deploy and per scale-in, to people mid-action (a clock-in or status POST that fails and must be repeated). Frequency estimated low (sub-second render times against a short window), but every prod deploy during a shift is an occasion.
- Recommendation: let Next drain and exit; the process exit closes the sockets and PostgreSQL rolls back whatever was open. Unified diff for the connector path (and the same for the local path at 125-127):
  ```diff
  -  const shutdown = async () => {
  -    try { await pool.end(); } finally { connector.close(); }
  -  };
  -  process.once('SIGTERM', shutdown);
  -  process.once('SIGINT', shutdown);
  +  // No pool.end() at SIGTERM: Next's own handler drains the HTTP server first and then exits the
  +  // process (node_modules/next/dist/server/lib/start-server.js), which closes every socket. Ending
  +  // the pool at the signal would refuse the next transaction of a request still in flight
  +  // ("Cannot use a pool after calling end on the pool"). Cloud Run allows 10 s after SIGTERM.
     return { connector, pool };
  ```
  and update the header comment at `client.ts:8` ("closed on SIGTERM"). The job (`web/jobs/close-forgotten-workdays.mjs:101-105`) and the ingest service keep their explicit `pool.end()`, which is right for them.
- README check: new.
- Disproof attempt: I checked whether Next sets `NEXT_MANUAL_SIG_HANDLE` in standalone output (it does not; the handler is installed unless that variable is set, `start-server.js:387`) and whether `pool.end()` waits for pending `connect()` calls (it does not: `_pulseQueue` on `ending` ends idle clients and rejects new ones, `index.js:133-134, 191-192`). I did not reproduce the race under load, hence Medium confidence.

### INFRA-05: Parked ingest events (`needs_review`) have no clearing path and no Data quality row
- Severity: Medium   Confidence: High   Effort: M
- Component: `db/30_ingest_crm_records.sql:503-504, 530-532`, `ingest/src/jobs/sweep.mjs:1-5`, `web/src/components/configuration/SourcesList.tsx:50`, `web/src/lib/data/postgres.ts:640-648, 1748-1762`, `web/src/lib/copy.ts:662-664`
- Evidence: an event that fails is retried by the sweep after `2^attempts` minutes capped at 60 (`db/30:504`) and parked as `needs_review` at `ingest.max_attempts` = 10 (`db/30:65-66, 532`): 1+2+4+8+16+32+60+60+60 minutes, about 4 hours of a source answering 5xx, timing out or rate-limiting (`http.mjs:34-67` classifies; `process.mjs:41-52` fails every claimed event when the adapter throws). Parked events are "never claimed again" (`sweep.mjs:5`). Where they show: Configuration → Sources lists `eventsParked` as a warning badge per connection (`SourcesList.tsx:50`, copy `parked: "For review"`), nothing else: Reports → Data quality (`cma.data_quality()` plus the outbox guard, `postgres.ts:1748-1762`; the check keys at `copy.ts:644-674`) has rows for the *outbox* (`check_writeback_parked`, `check_outbox_pending`) but none for parked *events*. How they are cleared: no function exists (`grep -n "needs_review" db/*.sql` finds a resolve function only for `cma.outbox_action`, `db/38_outbox.sql:254-290` `outbox_resolve` retry/drop; and even that has no web route: `grep -rn outbox_resolve web/src ingest/src` → nothing), so the only way is a Studio `update cma.ingest_event set status='received', attempts=0 …` by hand, outside the audit's actor model.
- Impact: after a source outage longer than about four hours (HubSpot, Aircall or Shopify; a wrong secret after a rotation; a Cloud Armor block of HubSpot's egress IPs) every event of that window is parked permanently: the nightly reconcile (26 h look-back, `docs/ingest/README.md` Jobs) re-reads objects *modified* in the look-back and so repairs most data, but deletions and any object not modified again stay missing, the badge never clears, and nobody is told to look. Dead letters without an owner action are the "needs a named person" state README promises for the outbox (Architecture, Outbox worker) but not for events.
- Recommendation: (1) a Data quality row "Source events waiting for review" (count of `ingest_event` with `status='needs_review'` per tenant), the same way the outbox guard was added (`postgres.ts:1748-1762`); (2) a resolve function in a new migration pair (`db/76_ingest_resolve_events.sql` + `db/77_verify_…`, numbering per the preamble; conventions of README Data model: `tenant.configure` permission, `needs_review → received` with `attempts = 0, next_attempt_at = now()` for retry or `→ ignored` with `error = 'dropped'` for drop, audited through the existing audit trigger, provoke switch in the verify), plus `catalog.json`; (3) a route `POST /api/v1/configuration/sources/[id]/events/resolve` with `{ action: 'retry'|'drop' }` next to the existing per-source routes, and a button on the Sources detail screen (style 7.x components, copy in `copy.ts` EN/NL); (4) an alert when the parked count rises (INFRA-06 can read it once CMA-031's in-app source health exists; until then the Data quality row is the signal). CMA-031 (in-app source health) is where the live state of each connection belongs; this finding only asks for the dead-letter action and its visibility, not the health design.
- README check: decision 1798 (9 Oct: "sweeper retries with backoff, parks after 10") settles the parking; the clearing path and its visibility are new. The outbox's resolve (0007c) is the precedent.
- Disproof attempt: I searched for any job or function that resets `needs_review` events (`ingest_requeue|ingest_reset|ingest_retry|status = 'received'` in `db/*.sql` and `ingest/src`): none. I checked whether reconcile would re-record the same events: it records new `sync:` keys, so the parked rows stay parked (`sync.mjs:22-37`).

### INFRA-06: One alert policy exists (`cma-ingest 429`); nothing watches errors, latency, job failures, the database or the certificates
- Severity: Medium   Confidence: High   Effort: M
- Component: `docs/ingest/alert.sh` (the one policy, `alert.sh:56-99`), Cloud Monitoring in `p4a-cma-prod`
- Evidence: `alert.sh:13-18` creates exactly one policy on `loadbalancing.googleapis.com/https/request_count` with `response_code = 429` for `cma-ingest-backend`. `grep -rn -i 'uptime' README.md` → nothing; no other `gcloud monitoring` call in `docs/`. The daily review of 14 October noted the policy's creation once failed; `MORNING_RUNBOOK.md:128` documents the rerun path ("A rerun after a failed policy create … says `a. email channel exists`, then `b. policy created`"), so whether the policy exists in prod today is a Browser check (console → Monitoring → Alerting → Policies). The 16 October incident was found by people seeing 401s in the request log (`records/ingest-front-incident-2026-10-16/README.md:14-17`); INFRA-01's failure mode would be found the same way.
- Impact: for a one-region, three-person team every outage is discovered by an agent who cannot clock in or by Martin reading logs; mean time to detect is a human's attention span. Cloud SQL at `max_connections` (README 153: 83 of 97 budgeted, overlap could add 60) would show as scattered "database unavailable" pages with no signal.
- Recommendation: the minimum set, as policies in the shape `alert.sh` already uses (JSON passed to `gcloud monitoring policies create`, one notification channel), to be folded into `alert.sh` as a table of policies with `--only <name>` and the existing `--dry-run` once Martin has run them once by hand. Every command below is **untested here; dry-run first** (review the JSON, run `gcloud monitoring policies list --project=p4a-cma-prod --format='value(displayName)'` before and after; each `create` must add exactly one row). `CHANNEL` is the email channel `alert.sh` creates (`projects/p4a-cma-prod/notificationChannels/<id>`, from `gcloud beta monitoring channels list --project=p4a-cma-prod --format='value(name,displayName)'`).

  **Terminal** (1) 5xx share of the web and ingest backends, from the load balancer (counts Cloud Armor and backend answers alike; logging on the backend is not needed for metrics):
  ```bash
  for B in cma-web-backend cma-ingest-backend; do cat > /tmp/p-5xx-$B.json <<JSON
  {"displayName":"$B 5xx ratio","combiner":"OR","enabled":true,"notificationChannels":["$CHANNEL"],
   "alertStrategy":{"autoClose":"1800s"},"userLabels":{"service":"$B"},
   "documentation":{"mimeType":"text/markdown","content":"More than 2 % of the requests to $B answered 5xx over 5 minutes (load balancer request_count). Check the Cloud Run revision (gcloud run revisions list), its logs, and Cloud SQL connections; roll traffic back with docs/RUNBOOK.md section 10 when a deploy caused it."},
   "conditions":[{"displayName":"5xx share above 2 % over 5 minutes","conditionThreshold":{
     "filter":"resource.type = \"https_lb_rule\" AND metric.type = \"loadbalancing.googleapis.com/https/request_count\" AND resource.labels.backend_target_name = \"$B\" AND metric.labels.response_code_class = 500",
     "aggregations":[{"alignmentPeriod":"300s","perSeriesAligner":"ALIGN_SUM","crossSeriesReducer":"REDUCE_SUM"}],
     "denominatorFilter":"resource.type = \"https_lb_rule\" AND metric.type = \"loadbalancing.googleapis.com/https/request_count\" AND resource.labels.backend_target_name = \"$B\"",
     "denominatorAggregations":[{"alignmentPeriod":"300s","perSeriesAligner":"ALIGN_SUM","crossSeriesReducer":"REDUCE_SUM"}],
     "comparison":"COMPARISON_GT","thresholdValue":0.02,"duration":"300s","trigger":{"count":1},"evaluationMissingData":"EVALUATION_MISSING_DATA_INACTIVE"}}]}
  JSON
  gcloud monitoring policies create --project=p4a-cma-prod --policy-from-file=/tmp/p-5xx-$B.json --format='value(name)'; done
  ```
  Expected: two lines `projects/p4a-cma-prod/alertPolicies/<id>`.

  **Terminal** (2) p95 backend latency (`backend_latencies` is a distribution; `ALIGN_DELTA` then `REDUCE_PERCENTILE_95`): web above 2 000 ms for 10 minutes, ingest above 5 000 ms (its budget is 3 s plus the commit; its request timeout 30 s):
  ```bash
  for B in cma-web-backend:2000 cma-ingest-backend:5000; do N=${B%%:*}; T=${B##*:}; cat > /tmp/p-p95-$N.json <<JSON
  {"displayName":"$N p95 latency","combiner":"OR","enabled":true,"notificationChannels":["$CHANNEL"],"alertStrategy":{"autoClose":"1800s"},
   "documentation":{"mimeType":"text/markdown","content":"The 95th percentile of $N's backend latency stayed above $T ms for 10 minutes (loadbalancing backend_latencies). Look at Cloud SQL CPU and connections first, then the slow routes in the Cloud Run request log (httpRequest.latency)."},
   "conditions":[{"displayName":"p95 above $T ms for 10 minutes","conditionThreshold":{
     "filter":"resource.type = \"https_lb_rule\" AND metric.type = \"loadbalancing.googleapis.com/https/backend_latencies\" AND resource.labels.backend_target_name = \"$N\"",
     "aggregations":[{"alignmentPeriod":"300s","perSeriesAligner":"ALIGN_DELTA","crossSeriesReducer":"REDUCE_PERCENTILE_95"}],
     "comparison":"COMPARISON_GT","thresholdValue":$T,"duration":"600s","trigger":{"count":1},"evaluationMissingData":"EVALUATION_MISSING_DATA_INACTIVE"}}]}
  JSON
  gcloud monitoring policies create --project=p4a-cma-prod --policy-from-file=/tmp/p-p95-$N.json --format='value(name)'; done
  ```
  Expected: two policy names.

  **Terminal** (3) Cloud Run job executions that fail (`run.googleapis.com/job/completed_execution_count`, `result = failed`; the runner exits 1 when any connection failed, `ingest/src/jobs/runner.mjs:85`, so one failed sweep can be a vendor blip): the every-minute jobs when 3 or more fail in 15 minutes, the daily and hourly ones on a single failure:
  ```bash
  cat > /tmp/p-jobs.json <<JSON
  {"displayName":"cma jobs failing","combiner":"OR","enabled":true,"notificationChannels":["$CHANNEL"],"alertStrategy":{"autoClose":"3600s"},
   "documentation":{"mimeType":"text/markdown","content":"A Cloud Run job of the CMA failed (ingest-sweep, ingest-poll-forms or ingest-poll-email three times in 15 minutes; ingest-reconcile or cma-close-forgotten-workdays once). Logs: gcloud logging read 'resource.type=cloud_run_job AND resource.labels.job_name=<job> AND severity>=WARNING' --project=p4a-cma-prod --freshness=1h --format='value(timestamp,jsonPayload.message,jsonPayload.code)'. Codes, never ids: docs/ingest/README.md, Jobs."},
   "conditions":[
    {"displayName":"every-minute job: 3 or more failed executions in 15 minutes","conditionThreshold":{
     "filter":"resource.type = \"cloud_run_job\" AND metric.type = \"run.googleapis.com/job/completed_execution_count\" AND metric.labels.result = \"failed\" AND resource.labels.job_name = monitoring.regex.full_match(\"ingest-sweep|ingest-poll-forms|ingest-poll-email\")",
     "aggregations":[{"alignmentPeriod":"900s","perSeriesAligner":"ALIGN_SUM","crossSeriesReducer":"REDUCE_SUM","groupByFields":["resource.labels.job_name"]}],
     "comparison":"COMPARISON_GT","thresholdValue":2,"duration":"0s","trigger":{"count":1},"evaluationMissingData":"EVALUATION_MISSING_DATA_INACTIVE"}},
    {"displayName":"daily or hourly job: a failed execution","conditionThreshold":{
     "filter":"resource.type = \"cloud_run_job\" AND metric.type = \"run.googleapis.com/job/completed_execution_count\" AND metric.labels.result = \"failed\" AND resource.labels.job_name = monitoring.regex.full_match(\"ingest-reconcile|cma-close-forgotten-workdays\")",
     "aggregations":[{"alignmentPeriod":"3600s","perSeriesAligner":"ALIGN_SUM","crossSeriesReducer":"REDUCE_SUM","groupByFields":["resource.labels.job_name"]}],
     "comparison":"COMPARISON_GT","thresholdValue":0,"duration":"0s","trigger":{"count":1},"evaluationMissingData":"EVALUATION_MISSING_DATA_INACTIVE"}}]}
  JSON
  gcloud monitoring policies create --project=p4a-cma-prod --policy-from-file=/tmp/p-jobs.json --format='value(name)'
  ```
  Expected: one policy name. If the API refuses `"duration":"0s"` with `evaluationMissingData` set (the reason `alert.sh:60` uses 60s), use `"duration":"60s"`.

  **Terminal** (4) Cloud SQL `cma-prod-pg`: CPU above 80 % for 10 minutes, memory above 90 %, disk above 80 % for an hour, connections above 80 (the budget's ceiling is 83 of 97 usable; README 153):
  ```bash
  cat > /tmp/p-sql.json <<JSON
  {"displayName":"cma-prod-pg capacity","combiner":"OR","enabled":true,"notificationChannels":["$CHANNEL"],"alertStrategy":{"autoClose":"3600s"},
   "documentation":{"mimeType":"text/markdown","content":"cma-prod-pg is near a limit: CPU, memory, disk or connections (README, Database connection budget: 83 budgeted of 97 usable; raising max_connections is rejected, 15 October 2026). Studio: select application_name, state, count(*) from pg_stat_activity group by 1,2 order by 3 desc; (no customer rows)."},
   "conditions":[
    {"displayName":"CPU above 80 % for 10 minutes","conditionThreshold":{"filter":"resource.type = \"cloudsql_database\" AND resource.labels.database_id = \"p4a-cma-prod:cma-prod-pg\" AND metric.type = \"cloudsql.googleapis.com/database/cpu/utilization\"","aggregations":[{"alignmentPeriod":"300s","perSeriesAligner":"ALIGN_MEAN"}],"comparison":"COMPARISON_GT","thresholdValue":0.8,"duration":"600s","trigger":{"count":1}}},
    {"displayName":"memory above 90 % for 10 minutes","conditionThreshold":{"filter":"resource.type = \"cloudsql_database\" AND resource.labels.database_id = \"p4a-cma-prod:cma-prod-pg\" AND metric.type = \"cloudsql.googleapis.com/database/memory/utilization\"","aggregations":[{"alignmentPeriod":"300s","perSeriesAligner":"ALIGN_MEAN"}],"comparison":"COMPARISON_GT","thresholdValue":0.9,"duration":"600s","trigger":{"count":1}}},
    {"displayName":"disk above 80 % for 1 hour","conditionThreshold":{"filter":"resource.type = \"cloudsql_database\" AND resource.labels.database_id = \"p4a-cma-prod:cma-prod-pg\" AND metric.type = \"cloudsql.googleapis.com/database/disk/utilization\"","aggregations":[{"alignmentPeriod":"300s","perSeriesAligner":"ALIGN_MEAN"}],"comparison":"COMPARISON_GT","thresholdValue":0.8,"duration":"3600s","trigger":{"count":1}}},
    {"displayName":"connections above 80 for 5 minutes","conditionThreshold":{"filter":"resource.type = \"cloudsql_database\" AND resource.labels.database_id = \"p4a-cma-prod:cma-prod-pg\" AND metric.type = \"cloudsql.googleapis.com/database/network/connections\"","aggregations":[{"alignmentPeriod":"300s","perSeriesAligner":"ALIGN_MAX"}],"comparison":"COMPARISON_GT","thresholdValue":80,"duration":"300s","trigger":{"count":1}}}]}
  JSON
  gcloud monitoring policies create --project=p4a-cma-prod --policy-from-file=/tmp/p-sql.json --format='value(name)'
  ```
  Expected: one policy name. Whether storage auto-increase is on for `cma-prod-pg` is not in README (see Not checked); if it is, the disk condition is a cost signal rather than an outage signal.

  **Terminal** (5) Reachability and certificate expiry from outside, with uptime checks (the ingest front has no IAP and answers `/health` without a database, `server.mjs:196-199`; six checker regions once a minute stay far under Cloud Armor's 600 per minute per IP). The Workspace host answers IAP's 302 to an anonymous checker, which is the right "alive" signal there:
  ```bash
  gcloud monitoring uptime create cma-ingest-health --project=p4a-cma-prod --resource-type=uptime-url --resource-labels=host=ingest.pulse4all.app,project_id=p4a-cma-prod --protocol=https --port=443 --path=/health --period=5 --timeout=10 --validate-ssl --status-classes=2xx
  gcloud monitoring uptime create cma-web-front --project=p4a-cma-prod --resource-type=uptime-url --resource-labels=host=workspace.pulse4all.app,project_id=p4a-cma-prod --protocol=https --port=443 --path=/ --period=5 --timeout=10 --validate-ssl --status-classes=2xx,3xx
  gcloud monitoring uptime list-configs --project=p4a-cma-prod --format='value(name,displayName)'
  ```
  Expected: two configs; their ids (`…/uptimeCheckConfigs/<id>`) go into the two conditions below (`check_id`). Then one policy, two conditions: the check failing in two or more regions for 10 minutes (`check_passed` counted false) and the certificate under 15 days from expiry (`time_until_ssl_cert_expires`, days):
  ```bash
  cat > /tmp/p-uptime.json <<JSON
  {"displayName":"cma front reachability and certificates","combiner":"OR","enabled":true,"notificationChannels":["$CHANNEL"],"alertStrategy":{"autoClose":"3600s"},
   "documentation":{"mimeType":"text/markdown","content":"An uptime check of workspace.pulse4all.app or ingest.pulse4all.app fails from two or more regions, or a Google-managed certificate is under 15 days from expiry (it renews itself only while the A record points at cma-web-ip: gcloud compute ssl-certificates describe cma-web-cert|cma-ingest-cert --global --format='value(managed.status,managed.domainStatus)')."},
   "conditions":[
    {"displayName":"uptime check failing","conditionThreshold":{"filter":"resource.type = \"uptime_url\" AND metric.type = \"monitoring.googleapis.com/uptime_check/check_passed\"","aggregations":[{"alignmentPeriod":"1200s","perSeriesAligner":"ALIGN_NEXT_OLDER","crossSeriesReducer":"REDUCE_COUNT_FALSE","groupByFields":["resource.label.host"]}],"comparison":"COMPARISON_GT","thresholdValue":1,"duration":"600s","trigger":{"count":1}}},
    {"displayName":"certificate under 15 days","conditionThreshold":{"filter":"resource.type = \"uptime_url\" AND metric.type = \"monitoring.googleapis.com/uptime_check/time_until_ssl_cert_expires\"","aggregations":[{"alignmentPeriod":"1200s","perSeriesAligner":"ALIGN_NEXT_OLDER","crossSeriesReducer":"REDUCE_MEAN","groupByFields":["resource.label.host"]}],"comparison":"COMPARISON_LT","thresholdValue":15,"duration":"600s","trigger":{"count":1}}}]}
  JSON
  gcloud monitoring policies create --project=p4a-cma-prod --policy-from-file=/tmp/p-uptime.json --format='value(name)'
  ```
  Expected: one policy name. If `uptime create` refuses `--status-classes`, create the two checks in the console (Monitoring → Uptime checks) with "Response status: 2xx" (ingest) and "2xx, 3xx" (web), SSL validation on.

  **Terminal** (6) A log-based distribution metric for the request timing line the lead adds (one JSON line per request with `kind`, `route`, `status`, `ms`; until it exists, the same metric works on the Cloud Run request log with `httpRequest.latency` as the value and a filter on `httpRequest.requestUrl`):
  ```bash
  cat > /tmp/m-request-ms.yaml <<'YAML'
  name: cma_web_request_ms
  description: cma-web request duration in ms by route and status (the request timing log line)
  filter: resource.type="cloud_run_revision" AND resource.labels.service_name="cma-web" AND jsonPayload.kind="request"
  valueExtractor: EXTRACT(jsonPayload.ms)
  labelExtractors:
    route: EXTRACT(jsonPayload.route)
    status: EXTRACT(jsonPayload.status)
  metricDescriptor:
    metricKind: DELTA
    valueType: DISTRIBUTION
    unit: ms
    labels:
      - key: route
        valueType: STRING
      - key: status
        valueType: STRING
  bucketOptions:
    exponentialBuckets:
      numFiniteBuckets: 24
      growthFactor: 1.5
      scale: 5
  YAML
  gcloud logging metrics create cma_web_request_ms --project=p4a-cma-prod --config-from-file=/tmp/m-request-ms.yaml
  ```
  Expected: `Created [cma_web_request_ms].`; the metric appears as `logging.googleapis.com/user/cma_web_request_ms` after the first matching line, and the SLO section below reads p95 per route from it (`ALIGN_DELTA` + `REDUCE_PERCENTILE_95`, `groupByFields: metric.labels.route`). The ingest service already logs `ms` on its `webhook` line (`server.mjs:128-131`); the same metric shape with `service_name="cma-ingest" AND jsonPayload.message="webhook"` gives the ingest acceptance latency.

  Budgets: both projects already have a budget alert (README 143: dev €75; 145: prod €150, "raise it when the first monthly bill shows the level"); CMA-034 (the lead's backlog) is where that lives: already open, nothing to add here. In-app source health is CMA-031: not designed here; the alerts above are the outside-in signals until it exists.

  Folding into `alert.sh`: keep one `policy_json` per policy name in a `case`, a `--only <name>` flag defaulting to all, the existing channel lookup and the "update when a policy with this display name exists, stop on two" logic (`alert.sh:130-145`) unchanged; `--dry-run` prints every JSON. The uptime checks need their own `exists` test (`gcloud monitoring uptime list-configs --filter=displayName=…`).
- README check: decision 1871 (429 alert) settled and kept; the rest is new. Line 145's budget alert and CMA-034 already cover cost. FIND-08 of the fifth audit (container scanning, 1916) is open on cost and unrelated.
- Disproof attempt: I looked for alert policies or uptime checks created elsewhere (`docs/`, `records/`, README "uptime", "alert polic"): only `alert.sh`. Thresholds are starting points, stated as such; they are not the finding.

### INFRA-07: Backups, PITR and HA are documented; no restore has ever been rehearsed or recorded
- Severity: Medium   Confidence: High   Effort: S (one hour of Martin's time, a few cents of instance time)
- Component: Cloud SQL `cma-dev-pg`, `cma-prod-pg`; `records/`
- Evidence: README 143 (dev: daily backups 01:00 UTC with point-in-time recovery, deletion protection) and 145 (prod: regional HA since 7 October); Release flow line 169 ("confirm point-in-time recovery is on (or take an on-demand backup)" before a migration); line 141 records "after point-in-time recovery was confirmed" before several prod migrations: confirmed means the setting was checked, not that a restore was performed. `grep -rn -i 'restore\|clone\|drill' records/ docs/RUNBOOK.md docs/ingest/PROD_RUNBOOK.md` → only an API-verifier line about settings being "restored" and `gh repo clone`; `ls records/` shows no `restore-*` or `drill-*` folder. HA covers a zone failure; it does not cover a bad migration, an accidental `update` without a `where`, or a deleted table, which is what PITR is for, and PITR has never been exercised.
- Impact: the recovery time for the one scenario HA does not cover is unknown: the first restore would be done under pressure, with real staff time data, by someone who has never done it (which IAM users and flags come along, how the app is pointed at the restored instance, how long a clone of a 3.75 GB HA instance takes). The Release flow's own rule (every verification is made to fail on purpose) is not applied to recovery.
- Recommendation: a quarterly drill, dev first (procedure), then prod (the data that matters; the clone holds real staff data, so Martin alone, deleted the same hour). All **untested here; dry-run first** (Cloud SQL has no dry run for clone; the dev run is the dry run).
  **Terminal** (1) clone dev to ten minutes ago
  ```bash
  ts=$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ); echo "$ts"
  gcloud sql instances clone cma-dev-pg cma-dev-pg-drill --project=p4a-cma-dev --point-in-time="$ts"
  ```
  Expected: the timestamp, then an operation that takes 5 to 15 minutes (estimated) and ends with `cma-dev-pg-drill` listed `RUNNABLE` by `gcloud sql instances list --project=p4a-cma-dev`. The clone carries the source's flags, databases and users (IAM users included; expected from Cloud SQL's clone semantics), so Martin's personal IAM login works in Studio.
  **Studio (cma-dev-pg-drill)**, read-only first:
  ```sql
  select (select count(*) from cma.tenant) as tenants, (select count(*) from cma.app_user) as users, (select max(recorded_at) from cma.ingest_event) as last_event;
  ```
  Expected: the same counts as `cma-dev-pg` had at `ts`, and `last_event` at or before `ts`. Then run `db/04_verify.sql` as it is (personal login, `set role cma_owner` inside the script) and, if time allows, the latest verify (`db/75_verify_forms_reporting.sql`).
  Expected: the `PASS` lines the dev records show (`records/*-dev-*`), no `FAIL`.
  **Terminal** (3) delete the clone the same hour (deletion protection comes along with the clone, expected; the first command removes it on the clone only):
  ```bash
  gcloud sql instances patch cma-dev-pg-drill --project=p4a-cma-dev --no-deletion-protection --quiet
  gcloud sql instances delete cma-dev-pg-drill --project=p4a-cma-dev --quiet
  gcloud sql instances list --project=p4a-cma-dev --format='value(name)'
  ```
  Expected: `Deleted [...cma-dev-pg-drill]`, and the list shows `cma-dev-pg` only. Cost: `db-g1-small` for about an hour, a few cents (estimated); a prod clone (`db-custom-1-3840`, HA) for an hour, under €0.30 (estimated).
  **File** `records/restore-drill-<YYYY-MM-DD>/README.md`, written from Martin's report only (no invented value):
  ```markdown
  # Restore drill, <environment>, <date>

  Written down by Claude Code from Martin's report; the times, counts and ids are his. No secret, no personal data.

  | Step | Command or statement (labelled) | Started (UTC) | Finished (UTC) | Result |
  |---|---|---|---|---|
  | clone to point in time | Terminal: gcloud sql instances clone <source> <drill> --point-in-time=<ts> | | | RUNNABLE after <m> minutes |
  | counts on the clone | Studio (<drill>): tenants, users, last_event | | | <n>, <n>, <ts> (matched the source at <ts>: yes/no) |
  | verify | Studio (<drill>): db/04_verify.sql (and db/<nn>_verify_*.sql) | | | PASS lines <n>, FAIL <n> |
  | delete | Terminal: gcloud sql instances delete <drill> | | | Deleted; instances list shows <source> only |

  Recovery time observed: <minutes> from the clone command to a verified database. What was learned, what to change in the runbook: <text>. Next drill: <quarter>.
  ```
  README: a Decision log row ("restore drill every quarter, dev then prod; recorded in records/restore-drill-<date>") and a sentence in Release flow next to "confirm point-in-time recovery is on".
- README check: Release flow 169 settles "confirm PITR"; a rehearsed restore is new.
- Disproof attempt: I searched README for "restore" in every form (eight hits, all about the URL map export or data re-reads), the records tree and both runbooks. Nothing records a restore.

### INFRA-08: Builder and base images float on tags (`node:22-alpine`, `cloud-builders/docker`, `cloud-sdk:slim`) while the NocoDB template pins digests
- Severity: Low   Confidence: High   Effort: S
- Component: `web/Dockerfile:5,10,19`, `ingest/Dockerfile:5,10`, `cloudbuild.yaml:28,44,54,58`, `ingest/cloudbuild.yaml:12,21`
- Evidence: all `FROM node:22-alpine` by tag; the Cloud Build steps use `gcr.io/cloud-builders/docker` (implicit `latest`) and `gcr.io/google.com/cloudsdktool/cloud-sdk:slim` (a moving tag). `docs/nocodb/service.template.yaml:27,76` pins both of its images by digest with the date reasoning in its header (1-4). `docs/signed-out/deploy.sh:254-257` documents that gcloud's URL-map import behaviour changed between SDK versions, i.e. a floating gcloud in the deploy step can change what a deploy does without a commit. README's "prod runs exactly the bytes dev tested" holds (the image is built once and deployed by tag, `deploy.sh:187-197`), but a rebuild of the same commit on another day is not reproducible, and a compromised upstream tag would reach prod on the next build without any diff.
- Impact: supply-chain and reproducibility hygiene; the practical risk is a surprise behaviour change in a build step rather than an exploit.
- Recommendation: pin by digest and bump on purpose (monthly, or when Node 22 publishes a security release), in the style the NocoDB template already uses:
  **Terminal** (read-only)
  ```bash
  docker buildx imagetools inspect node:22-alpine --format '{{json .Manifest.Digest}}'
  gcloud container images describe gcr.io/google.com/cloudsdktool/cloud-sdk:slim --format='value(image_summary.digest)'
  gcloud container images describe gcr.io/cloud-builders/docker:latest --format='value(image_summary.digest)'
  ```
  Expected: three `sha256:…` values; then `FROM node:22-alpine@sha256:<digest>` in both Dockerfiles (a comment with the tag and date, as the NocoDB template does) and `name: gcr.io/google.com/cloudsdktool/cloud-sdk:slim@sha256:<digest>` in both build files (a `cloudbuild.yaml` change deploys prod on merge; no CONFIG CHANGE because no flag or variable changes). Artifact Registry's vulnerability scanning (fifth audit FIND-08, README 1916) is the complementary control and stays an open cost decision.
- README check: FIND-08 (container scanning) is already open on cost (1916); digest pinning is new and costs nothing.
- Disproof attempt: I checked whether Cloud Build's own image cache would make the floating tags effectively stable: it does not (each build pulls the tag).

### INFRA-09: A non-numeric `CMA_DB_POOL_MAX` silently becomes a pool of 10 (the budget's 20 becomes 40)
- Severity: Low   Confidence: High (observed)   Effort: S
- Component: `web/src/lib/db/client.ts:100,119,141`, `ingest/src/core/db.mjs:40`, `cloudbuild.yaml:33-41`
- Evidence: `poolMax: Number(process.env.CMA_DB_POOL_MAX ?? 5)` and `max: Number(...)` with no check; `pg-pool` 3.14.0 applies `this.options.max = this.options.max || this.options.poolSize || 10` (`web/node_modules/pg-pool/index.js:89`). Observed: `new Pool({ max: Number("abc") }).options.max` → `10`; `Number("5")` → `5`. check-config does not validate `_DB_POOL_MAX` or `_MAX_INSTANCES` (`cloudbuild.yaml:33-41`); a typo in the trigger's YAML (RUNBOOK 9) is the trigger.
- Impact: expected: 4 instances × 10 = 40 web connections instead of 20, the budget of 83 becomes 103 and the instance's 97 usable connections can be exceeded under load, with "database unavailable" as the symptom and nothing in the logs naming the cause.
- Recommendation: the check-config regex in INFRA-01(a) plus a guard in both clients (proposed diff for `client.ts`, the same for `db.mjs:40`):
  ```diff
  -    poolMax: Number(process.env.CMA_DB_POOL_MAX ?? 5),
  +    poolMax: poolMax(),
  @@
  +function poolMax(): number {
  +  const raw = process.env.CMA_DB_POOL_MAX ?? '5';
  +  const n = Number(raw);
  +  if (!Number.isInteger(n) || n < 1 || n > 20) throw new CmaDbError('DB_UNAVAILABLE', `CMA_DB_POOL_MAX must be an integer from 1 to 20, got "${raw}"`);
  +  return n;
  +}
  ```
  (and the local path at `client.ts:119` uses it too). With INFRA-01(c) in place the health route can also report a bad pool value as `misconfigured`.
- README check: new; the connection budget (153) assumes the configured values.
- Disproof attempt: I looked for a pg-pool validation of `max`: none; the observed default confirms it.

### INFRA-10: A key-set fetch outage after the 10-minute cache locks everyone out until it recovers; jose offers no stale-while-error, a bounded fallback is possible
- Severity: Low   Confidence: Medium   Effort: S
- Component: `web/src/lib/auth/iap.ts:27-34`, jose 6.2.12 `dist/webapi/jwks/remote.js:64-73`
- Evidence: `createRemoteJWKSet(url, { cooldownDuration: 30_000, cacheMaxAge: 600_000 })`. jose's resolver: `(!local || !isFreshFor(jwksTimestamp, cacheMaxAge)) && await reload()` (`remote.js:66`): once the cache is older than 10 minutes, every verification first awaits a fetch of `https://www.gstatic.com/iap/verify/public_key-jwk`; if that fetch fails or times out (`timeoutDuration` default 5 s), `reload()` rejects and `jwtVerify` throws although `local` still holds the last good keys; `proxy.ts:54-60` answers 401 `invalid`. The next request tries again, so the lock-out lasts exactly as long as the fetch failures. `RemoteJWKSetOptions` (`remote.d.ts`) has `cacheMaxAge: Infinity` (no expiry; refetch only on an unknown `kid`, after the cooldown) and a `jwksCache` object whose `uat` is updated on every successful fetch, but no "serve stale on error" option.
- Impact: fail closed is the right default for a token check, and gstatic.com is Google's own CDN, so a gstatic outage likely comes with an IAP outage anyway; the realistic cases are a transient egress failure or a slow DNS answer at the refresh moment, costing one or a few 401s to people who are in fact signed in. Acceptable today; the fallback below removes the self-inflicted part without weakening the verification (signature, issuer, audience, expiry and issue time are still checked against keys Google served, at most 24 hours ago).
- Recommendation (proposed, not applied: authentication path, rule 10): keep the remote set as the primary and, when its *fetch* fails and a last good set exists that is less than 24 hours old, verify against that set with `createLocalJWKSet`; a `JWKSNoMatchingKey` (a rotated key the cache does not hold) is never served from the stale set. Sketch for `iap.ts`:
  ```ts
  import { createLocalJWKSet, createRemoteJWKSet, jwksCache, jwtVerify, type ExportedJWKSCache } from "jose";
  const STALE_MAX_MS = 24 * 60 * 60_000;
  const caches = new Map<string, Partial<ExportedJWKSCache>>();   // jose writes jwks and uat (last successful fetch) into it
  function keySet(url: string) { /* … createRemoteJWKSet(new URL(url), { cooldownDuration: 30_000, cacheMaxAge: 600_000, [jwksCache]: cache }) … */ }
  // in verifyIapJwt: on a fetch failure (e.name === "JWKSTimeout" || e instanceof TypeError) and
  // cache.jwks && Date.now() - cache.uat < STALE_MAX_MS → retry jwtVerify with createLocalJWKSet(cache.jwks),
  // same issuer/audience/algorithms/clockTolerance; log "iap: key set served stale (<age> s)"; otherwise rethrow.
  ```
  `web/verify/iap-token.mjs` gets a case: a key-set URL that answers 500 after one good fetch still verifies a valid token within the window and refuses one after it. Decision for Martin: accept the fail-closed behaviour as is (document it in Authentication) or take the bounded fallback.
- README check: new (Authentication describes the verification, not the key cache).
- Disproof attempt: I read jose's resolver to see whether a failed reload falls back to `local`: it does not (`remote.js:66-73`: the `await reload()` is outside the try that catches `JWKSNoMatchingKey`). I considered `cacheMaxAge: Infinity` alone: it removes the 10-minute refetch but keeps a revoked key trusted indefinitely per instance, so the bounded variant is the better trade.

### INFRA-11: `ingest/verify/deploy-script.mjs` proves the `--front` guard and the ingress/URL shape, not the caps, timeouts or schedules
- Severity: Low   Confidence: High   Effort: S
- Component: `ingest/verify/deploy-script.mjs:101-124`, `docs/ingest/deploy.sh`
- Evidence: covered: prod without `--front` refused before any gcloud call (A), `--jobs --front` refused, prod `--jobs` deploys six jobs and no service, dev deploys with `--ingress=all` and the `run.app` URLs and `INGEST_ALLOW_REPLAY=1`, prod `--front` deploys with `--ingress=internal-and-cloud-load-balancing`, `INGEST_PUBLIC_URLS` starting with the front, no replay variable, `run.app: 404 (refused)`. Not covered: the service's caps (`--concurrency=20`, `--min-instances`/`--max-instances` per environment, `--cpu-boost`, `--timeout=30s`, `--cpu=1 --memory=512Mi`, `--no-invoker-iam-check`), the jobs' `--task-timeout` values and `CMA_DB_POOL_MAX=3`, the schedules' cron strings and `--time-zone=Europe/Amsterdam`, the scheduler account's `run.invoker` binding per job, the pepper-creation path (the fake gcloud answers that every secret exists, so `openssl rand … | gcloud secrets versions add` never runs), `env_list`'s delimiter refusal (`deploy.sh:203-212`), the first-deploy URL update (`deploy.sh:316-321`), the Artifact Registry grant-missing stop (`deploy.sh:179-183`) and the `images describe` error path (`deploy.sh:195-196`). The 16 October incident was a flag falling back to a default; the caps are the next flags that could.
- Impact: a regression in any uncovered flag (a lost `--cpu-boost`, a `--timeout` typo, a schedule in UTC) passes `npm test` and reaches prod at the next deploy.
- Recommendation: extend the verifier with assertions on the `gcloud run deploy cma-ingest` and `gcloud run jobs deploy` lines it already captures (`serviceDeploy()` at 93-99 parses flags; add `concurrency`, `min-instances`, `max-instances`, `cpu-boost`, `timeout` and, for the jobs, `task-timeout` per job and `CMA_DB_POOL_MAX`), on the `gcloud scheduler jobs create http` lines (`--schedule`, `--time-zone`, `--oauth-service-account-email`), and a case with a fake gcloud whose `secrets describe` fails for the pepper so the generation path runs (assert the log holds `secrets versions add … --data-file=-` and that stdout never holds a 64-hex string). Expected effort: an hour; `--provoke` must flip every new check.
- README check: new; decision 1981/16 Oct introduced the verifier for the guard only.
- Disproof attempt: I read the whole verifier for implicit coverage (e.g. a regex over the full deploy line): there is none beyond ingress and env vars.

### INFRA-12: `docs/scheduler/deploy.sh`: no dry run, the web service's own account also invokes the job, and the job's image is not refreshed by the pipeline
- Severity: Low   Confidence: High   Effort: S
- Component: `docs/scheduler/deploy.sh:33-61`, `cloudbuild.yaml`
- Evidence: `set -euo pipefail` (15), `--project` on every call, create-or-update for the schedule (49-61), `--tasks=1 --max-retries=0 --task-timeout=10m` (40): fine. But: no `--dry-run` (every other script in `docs/` has one or is a dry run by default); `cma-web@<project>` is the job's runtime identity, the Scheduler's OAuth identity and the holder of `roles/run.invoker` on the job (44-46, 54, 60), while the ingest side separates them (`deploy.sh:216-219, 243-253`: `cma-ingest-scheduler@` holds `run.invoker` only); and the image is `web:<sha>` passed by hand (18, 25), so a web merge updates the service's image and not the job's until someone reruns this script (README 1204 says "dev first" but names no trigger to rerun it). `--set-cloudsql-instances` (38) is unnecessary with the connector (the job uses `@google-cloud/cloud-sql-connector`, `close-forgotten-workdays.mjs:39-46`) and harmless. No `--cpu`/`--memory`: Cloud Run's defaults (1 vCPU, 512 MiB) apply, adequate for a job that runs one function per tenant.
- Impact: a compromised web instance could start the job (idempotent, so harmless today, but a standing extra permission on the service's identity); the job can run a stale image for weeks, so a change to `jobs/close-forgotten-workdays.mjs` or to the connector version in `package.json` reaches prod only when someone remembers (the function it calls, `cma.close_forgotten_workdays`, changes by migration, which is forward-compatible by design, so the drift is a latent, not an active, failure).
- Recommendation: (1) a `--dry-run` flag printing the `gcloud` lines; (2) a `cma-web-scheduler@<project>` account with `run.invoker` on the job only, as the ingest side does (least privilege; the job keeps running as `cma-web@`, whose IAM database user is the `cma_app` member, README 1204); (3) a line in `docs/RUNBOOK.md` section 3 ("after a web build that touches `jobs/` or `package.json`, run `docs/scheduler/deploy.sh prod <sha>`") or, cleaner, a `gcloud run jobs update cma-close-forgotten-workdays --image=…` step in `cloudbuild.yaml` after the service deploy (CONFIG CHANGE to the pipeline; the job's pool 2 is unchanged, budget 83 unchanged; the build account's Cloud Run admin role, README 163, already covers jobs).
- README check: 1204 describes the current identity arrangement as the design; (2) is a refinement, new. (3) is new.
- Disproof attempt: I checked whether `cloudbuild.yaml` updates the job (no: lines 57-69 deploy the service only) and whether README names a reminder to rerun the scheduler deploy after web merges (no).

### INFRA-13 (Info): no `unhandledRejection`/`uncaughtException` handlers; Node 22's default (crash, exit 1) is the right one for the jobs and acceptable for the services
- Severity: Info   Confidence: High   Effort: S
- Component: `ingest/src/server.mjs`, `web/` (Next standalone), `ingest/src/jobs/runner.mjs`, `web/jobs/close-forgotten-workdays.mjs`
- Evidence: `grep -rn 'unhandledRejection\|uncaughtException' ingest/src web/src web/jobs ingest/jobs` → nothing. Expected behaviour: a stray rejection crashes the process with exit code 1, so a job execution is marked failed (good: `runner.mjs:68-86` already exits 1 on any failure, 2 on usage; `close-forgotten-workdays.mjs:105` exits 1 when any tenant failed) and a service instance is restarted by Cloud Run with its in-flight requests lost (acceptable at this scale; every request handler in `server.mjs:207-210` catches its own errors, and `pool.on("error")` swallows idle-client errors, `db.mjs:64`, `client.ts:124,146`).
- Recommendation: optional: a handler in `server.mjs` that logs `{ message: "unhandled", code }` (never the error message, which may hold data) and then `process.exit(1)`, so the crash reason is in the log; never keep running after an uncaught exception.
- README check: new, informational.

### INFRA-14 (Info): release safety: a web change reaches prod before dev verifies it, with no PR check and a TCP-only readiness test; CMA-024 and CMA-068 move up
- Severity: Info   Confidence: High   Effort: –
- Component: `cloudbuild.yaml`, README Release flow (line 171: "the merge to `main` (which builds and deploys prod), then the same image on dev"), Open decisions 2017 (PR check trigger; a build-only trigger for branch images) and 2138 (CMA-068, a dev-only web build path)
- Evidence: the order is settled (decision 1706, 6 Oct) and the two gaps are already open; not re-argued here. What this audit adds: the three facts compound. A PR is merged on review alone (no PR check trigger), the merge deploys prod before any environment has run the image (CMA-068), and the deploy's readiness test is TCP (INFRA-01), so nothing between a reviewer's eyes and the agents' browsers executes the code. Rollback exists and is documented (`docs/RUNBOOK.md:352-366`, `update-traffic` to the previous revision, seconds); nothing makes a bad deploy worse except that nothing announces it (INFRA-06).
- Recommendation: INFRA-01(b) is the cheapest compensating control and does not depend on either backlog item; with it in place, CMA-024 and CMA-068 remain the real fix and move up in priority. Already open; pointer only.
- README check: already open (2017, 2138).

---

## Cloud Run settings: observed flag vs Cloud Run default when absent vs README

"Observed" is what the repository's deploy step passes (static). For an existing service, `gcloud run deploy` keeps any setting whose flag is absent (expected gcloud behaviour); the "default" column is what a *new* service would get, i.e. what a recreate from the repository would produce.

| Setting | `cma-web` (`cloudbuild.yaml:57-69`) | Default if absent (new service) | README says | `cma-ingest` (`docs/ingest/deploy.sh:300-313`) |
|---|---|---|---|---|
| region | `europe-west4` | – | europe-west4 | `europe-west4` |
| port | `8080` | 8080 | – | `8080` |
| max instances | `_MAX_INSTANCES` = 4 | 100 | 4 (149, 153) | 5 prod / 2 dev (97-98) |
| min instances | absent | 0 | 1 since 12 Oct (149, 1859) | 1 prod / 0 dev |
| CPU | absent | 1 vCPU | – | `--cpu=1` |
| memory | absent | 512 MiB | – | `--memory=512Mi` |
| concurrency | absent | 80 | – | `--concurrency=20` (123) |
| request timeout | absent | 300 s | – | `--timeout=30s` (123) |
| startup CPU boost | absent | off (gcloud) | not claimed for web; ingest since 13 Oct (1917) | `--cpu-boost` |
| ingress | absent | `all` | internal-and-cloud-load-balancing (147) | `--ingress=internal-and-cloud-load-balancing` with `--front`, else `all` (dev) |
| service account | absent | project's default compute SA | `cma-web@<project>` (147) | `--service-account=cma-ingest@…` |
| invoker check | absent | IAM required (gcloud asks; `--quiet` keeps "no") | – | `--no-invoker-iam-check` (1798) |
| startup probe | absent | TCP on the port | – | TCP (absent) |
| environment | `--set-env-vars` (9 variables, replaces all) | – | 149, 165 | `--set-env-vars=^|^…` (10-11 variables, replaces all) |
| execution environment | absent | gen2 | – | gen2 |
| Cloud SQL attachment | absent (connector) | – | connector (147) | absent (connector) |

Jobs: ingest jobs `--cpu=1 --memory=512Mi --tasks=1 --max-retries=0`, `--task-timeout` 10m (sweep, poll-forms, poll-email, outbox), 60m (reconcile), 24h (backfill), pool 3 (`deploy.sh:220-240`); scheduler job `cma-close-forgotten-workdays`: default CPU/memory, `--tasks=1 --max-retries=0 --task-timeout=10m`, pool 2 (`docs/scheduler/deploy.sh:33-41`, `close-forgotten-workdays.mjs:36,46`). Cloud Scheduler entries: no `--attempt-deadline` (default 180 s) and no `--max-retry-attempts` (default 0), both adequate because the `:run` endpoint answers at once and the next minute or hour runs anyway (and Scheduler starts a run whether or not the previous finished: README 153; the job-lock question is 5.2's finding, referenced, not repeated).

`cloudbuild.yaml` otherwise: `check-config` covers `_DATA_MODE=api` without DB variables and the `_LOGOUT_TARGET` value only (INFRA-01); builder images by tag (INFRA-08); `--set-env-vars` holds identifiers only (modes, audience, instance name, IAM user, database name, pool size, logout target, version), no secret can land there because no substitution is one, and no value may hold a comma (none does; the ingest script uses the `^|^` form for that reason, `deploy.sh:199-212`); `machineType: E2_HIGHCPU_8` and `timeout: 1200s` (a build takes about two minutes, README 163); `logging: CLOUD_LOGGING_ONLY` is required by the user-managed build account (README 163); `images:` pushes `:latest` as well as `:<sha>`, a floating tag nothing deploys (harmless).

## SLOs proposed for READINESS (measurable today, no new tooling)

Window: the tenant's workday window (`workday.window_start`/`window_end`, Pulse4all 07:00–22:00 Europe/Amsterdam, README 1863); 28-day rolling; measured in Cloud Monitoring from the metrics named. The p95 targets are the ones area 5.6 uses; the figures here are starting points for Martin.

| SLO | Indicator | Target | Metric (existing) |
|---|---|---|---|
| S1 Sign-in and landing available | share of non-5xx answers of `cma-web-backend` | ≥ 99.5 % | `loadbalancing.googleapis.com/https/request_count` by `response_code_class`, `backend_target_name="cma-web-backend"` |
| S2 Clock-in, status change, clock-out succeed fast | `POST /api/v1/me/day/start`, `/api/v1/me/status`, `/api/v1/me/day/end`: non-5xx share and p95 | ≥ 99.9 %; p95 ≤ 800 ms | the request timing log metric (INFRA-06 (6), `route` label); until it exists, a log-based distribution on the Cloud Run request log: `httpRequest.requestUrl` matching those paths, value `httpRequest.latency`, label `httpRequest.status` |
| S3 Manager's main pages | `/live/board`, `/team/hours`, `/reports/dashboard`, `/roster/planner`: non-5xx share and p95 | ≥ 99.5 %; p95 ≤ 2 000 ms | same metric, `route` label |
| S4 Backend latency overall | p95 of `cma-web-backend` | ≤ 1 500 ms | `loadbalancing.googleapis.com/https/backend_latencies` |
| S5 Ingest webhook acceptance | share of `POST` answers of `cma-ingest` that are not 5xx (200, 400, 401, 404, 413 count as accepted: the source got a definite answer) and no 429 at the load balancer | ≥ 99.9 % per day; 429 = 0 | `run.googleapis.com/request_count` (`cloud_run_revision`, `service_name="cma-ingest"`, `response_code_class`); the existing `cma-ingest 429` policy |
| S6 Ingest acceptance latency | p95 of the `webhook` log line's `ms` (`server.mjs:128-131`) | ≤ 3 500 ms (budget 3 s + commit) | log-based distribution on `jsonPayload.message="webhook"`, value `jsonPayload.ms` |
| S7 Job freshness | successful executions per hour: `ingest-sweep` and `ingest-poll-forms` ≥ 55 of 60; `ingest-poll-email` ≥ 55 of 60 where on; `ingest-reconcile` 1 per day between 02:30 and 04:00; `cma-close-forgotten-workdays` 24 per day | as stated | `run.googleapis.com/job/completed_execution_count` with `result="succeeded"` by `job_name`; cross-check in Studio: `select job, max(finished_at) from cma.sync_run where status='succeeded' group by 1` (counts and times only) |
| S8 Data freshness seen by people | Sources screen `lastEventAt` per active connection within 10 minutes during the window | 95 % of 5-minute samples | today: `cma.sources` view (`postgres.ts:640-648`); tomorrow: CMA-031 |

Error budget use and the first month's actuals belong in the readiness report; nothing here needs code beyond the timing log line the lead adds.

---

## Checked and found clean

- `cloudbuild.yaml:68` `--set-env-vars`: identifiers only, no secret among the substitutions; `_IAP_AUDIENCE` and `_DB_INSTANCE` hold no comma; `dynamicSubstitutions` true; `logging: CLOUD_LOGGING_ONLY` required for the named build account (README 163); `machineType: E2_HIGHCPU_8`, `timeout: 1200s`.
- `web/Dockerfile`: three stages; `npm ci` with devDependencies only in `deps`/`build`, the runtime copies `.next/standalone` (traced production modules), `.next/static`, `public`, `jobs` only (28-32); non-root `app` (27, 33); `.dockerignore` excludes `node_modules`, `.next`, `.git`, `verify`, `records`, `*.md`, `.env*` (1-7); `web/.env.example` holds no secret (observed: placeholders and comments). Image size, estimated: `node:22-alpine` (about 160 MB uncompressed) + 116 MB standalone (observed `du` of the lead's build) + 2.2 MB static + public and jobs < 0.1 MB ≈ 280 MB uncompressed. `HEALTHCHECK` absent, correctly (Cloud Run ignores it).
- `ingest/Dockerfile`: two stages; `npm ci --omit=dev` (8); runtime copies `node_modules` (production), `package.json`, `src`, `jobs` (17-20); non-root (16, 21); `.dockerignore` excludes `node_modules`, `verify`, `tools`, `.gitignore`, `eslint.config.mjs`; no `.env*` exists under `ingest/` and the build context is `ingest/` so `.git`, `records/`, `local-records/` are outside it. Size, estimated: base + 71.6 MB of 166 production packages (observed via `npm ls --omit=dev`) + 0.3 MB source ≈ 235 MB uncompressed. Cloud Build staging uploads `ingest/` minus `.gitignore`'s `node_modules/` (no `.gcloudignore` there), i.e. `verify/` and `tools/` reach the staging bucket but not the image.
- `ingest/src/server.mjs:214-224`: shutdown order server.close → `closeDb()` → exit 0, fallback exit at 9 s inside Cloud Run's 10 s; `server.requestTimeout = 30_000` equals `--timeout=30s`; `/health` touches no database (196-199).
- Job exit codes: `runner.mjs:68-86` (0 / 1 on any failed connection / 2 on usage, pool closed first); `close-forgotten-workdays.mjs:101-105` (pool ended, exit 1 on any tenant failure); a top-level throw before the pool opens exits 1 (Node default). `--max-retries=0` on every job; the next schedule is the retry (README 153, 1204).
- Task timeouts set on every job (table above); `sweep.mjs:38,54` bounds its claim loop at 45 s; every outbound call carries an abort signal (`budget.mjs:56-58` ≤ 10 s in a webhook, `70-72` 30 s, `81-88` 20 s for jobs); the Shopify route has its own 1.5 s budget (`deploy.sh:299`, 1912). A vendor outage therefore costs at most a few seconds per webhook and leaves events to the sweep; it cannot hold ingest instances (concurrency 20 × 5 instances, each request ≤ ~3.5 s plus commit).
- Retry policy per call class (no in-process retry loops anywhere, decision 1904): webhook read-back: one attempt within the budget, failure → event `failed` with code (`http.mjs:34-67`: `rate_limited`, `timeout`, `unreachable`, `http_<status>`, `bad_response`); sweep: database-side backoff `2^attempts` min capped at 60, `ingest.max_attempts` 10 → `needs_review` (`db/30:503-504, 532`); jobs: paced at half the documented rate (`pace.mjs`, `budget.mjs:81-92`), a 429 holds the pace until the source's reset (`aircall/read.mjs:117-127`, `pace.mjs:26-28`) or empties the cost bucket (`shopify/client.mjs:213-226`), the batch stops and the sweep continues later; outbox: backoff same shape, `outbox.max_attempts` 8 → `needs_review`, `outbox_resolve` retry/drop (`db/38:75-76, 254-290, 530-532`). Idempotency: event keys per source (`ac:`, `sh:<webhook id>`, `sync:<type>:<id>:<version>`, `reread:`), `ingest_record_events` answers `is_new`, writes guarded by the source's updated time (stale counter). Cloud SQL connector: a refresh failure after the first connection is retried immediately and never surfaced to the pool (`cloud-sql-instance.js:160-172`), before the first connection it throws and `db()` resets for a retry (`client.ts:157-160`, `db.mjs:70-76`).
- `docs/ingest/deploy.sh`: `set -euo pipefail` (74); `--project` explicit on every call except `gcloud artifacts docker images describe "$IMAGE"` (188), which resolves the project from the image path (fine; a note-level item); dev/prod guard with exit 2 before any gcloud call for a prod service deploy without `--front` (128-130, proven by the verifier); rerun-safe (describe-then-create everywhere); roles least-privilege: `roles/cloudsql.client` + `roles/cloudsql.instanceUser` at project level (144-147, the minimum for IAM database authentication), `secretmanager.secretAccessor` per named secret (153-156), `run.invoker` per scheduled job to a dedicated scheduler account (243-245); the pepper is generated and piped, never printed (160-166); `--set-env-vars` replaces every variable by design and the header says so (29-31); `env_list` refuses a value holding the delimiter (203-212). Scheduler entries without `--attempt-deadline`/`--max-retry-attempts`: defaults adequate for a `:run` endpoint (above).
- `docs/ingest/front.sh`: `set -euo pipefail` (33); `--dry-run` with no gcloud call (91-108); every step skips what exists; backend logging off on purpose (133-139, README 1871 keeps the Cloud Run request log as the record); no IAP on the ingest backend and a stop if IAP is found on (141-145); certificates added next to, never replacing, `cma-web-cert` (187-196); prints nothing secret.
- `docs/ingest/alert.sh`: `set -euo pipefail` (28); `--dry-run` (103-108); idempotent by display name, stops on duplicates (130-145); the email address is a flag, stored only in the channel; nothing secret printed.
- `docs/nocodb/deploy.sh` + `service.template.yaml`: `set -euo pipefail` (10); `--dry-run` prints the rendered YAML (48-51); placeholder check (42-46); `gcloud run services replace` is idempotent; both images pinned by digest with dates (template 3-4, 27, 76); `maxScale 1`, `cpu-throttling true`, startup probes on both containers (18-21, 34-38, 88-91); secrets via `secretKeyRef` (48-57); `NC_DB_JSON` holds an empty password with IAM authentication through the proxy sidecar (45); IAP via annotation (13) and the README's IAM steps grant `run.invoker` to the IAP service agent and `iap.httpsResourceAccessor` to the group only (`docs/nocodb/README.md:128-143`).
- `docs/signed-out/deploy.sh` + `urlmap.py`: `set -euo pipefail` (54); dry run by default, `--apply` to change, every change printed with `+` (103-106); stops before anything is created when the org policy or the bucket's public-access prevention forbids a public bucket (112-119, 162-165); public read is `roles/storage.legacyObjectReader` for `allUsers` only, any other `allUsers` role stops the script (157-186); the bucket must hold exactly the three objects (218-228); the URL map is exported first, the restore command printed with the live fingerprint written in (132-143), the plan is computed locally and must differ from the export only in the three route rules (`urlmap.py:162-164`), validated with tests, and imported only while the fingerprint matches, with a 412 treated as "changed since" (258-281); the planned map must carry a fingerprint (`urlmap.py:207-208`). `--billing-project=p4a-cma-dev` on the org-policy read is as README documents (line 136).
- `docs/scheduler/deploy.sh`: `set -euo pipefail`, `--project` everywhere, create-or-update, `--task-timeout=10m`, `--max-retries=0`, `--set-env-vars` with the three database variables (33-41); the rest is INFRA-12.
- HA, PITR, deletion protection, SSL required, IAM authentication: documented (README 143, 145); rollback procedure documented (`docs/RUNBOOK.md:352-366`); build failure leaves prod untouched (`RUNBOOK.md:250`).
- The 16 October incident's fix is in place and tested: `deploy.sh:128-130` + `verify/deploy-script.mjs` (A), `records/ingest-front-incident-2026-10-16/README.md:38-39`.

## Not checked / could not check

- The live Cloud Run settings of `cma-web` and `cma-ingest` in prod (CPU, memory, concurrency, timeout, boost, invoker policy, ingress): no gcloud by the audit's rule 1; INFRA-02 gives the read-only command. The table's "observed" column is therefore the repository's flags.
- Whether the `cma-ingest 429` policy exists in prod today (the 14 October note that its creation once failed): a Browser check for Martin (Monitoring → Alerting → Policies, project `p4a-cma-prod`).
- Cloud SQL storage auto-increase, log retention per bucket (decision 1858 names 30 days for `_Default`) and the load balancer's logging state on `cma-web-backend`: not in the repository.
- Image sizes: estimated from the lead's local standalone build and `npm ls`, not from Artifact Registry.
- The SIGTERM race (INFRA-04) was reasoned from `pg-pool` and Next's source, not reproduced under load.
- 5.2's job-lock/overlap finding: its findings file was not present when I checked (`local-records/5.2-ingest-security/` empty); referenced generically.
- CMA-024, CMA-034 and CMA-031 as backlog items: their text is in the lead's backlog, not in README (`grep` finds CMA-024/CMA-068 in `docs/audits/2026-10-17-full-audit/METHOD.md` and the night notes only); treated as "already open" as instructed.

## Commands run

- `git log --oneline -1; git branch --show-current; ls db/ | sort -V | tail -3` → `35ea3e0`, branch `claude/eager-volta-q3ak9i`, highest migration `75_verify_forms_reporting.sql` (numbering 76/77 free, as the preamble says).
- `cat -n` of every file named above; `grep -n '^## \|^### ' README.md`; `sed -n` / `cut` reads of README lines 82-179, 1757-1758, 1829, 1916-1917, 1951, 2008-2142; `grep -n -o` searches of README for `cpu-boost`, `min-instances`, `concurrency`, `max_connections`, `statement_timeout`, `high availability`, `restore`, `uptime`, `p95`, `CMA-0xx`.
- `grep -rn 'statement_timeout\|idle_in_transaction' README.md db/*.sql web/src ingest/src docs/*.md` → nothing.
- `grep -rn 'unhandledRejection\|uncaughtException\|SIGTERM\|SIGINT' ingest/src web/src web/jobs ingest/jobs` → the two SIGTERM sites only.
- `grep -rn -i 'restore\|clone\|drill' records/ docs/RUNBOOK.md docs/ingest/PROD_RUNBOOK.md` → no restore drill.
- `grep -rn 'needs_review' web/src db/*.sql ingest/src` and `grep -rn 'outbox_resolve|...' web/src ingest/src` → badge on Sources only; no resolve route; no event resolve function.
- `grep -n ... web/node_modules/pg/lib/{client,connection-parameters,defaults}.js` → `statement_timeout`, `lock_timeout`, `idle_in_transaction_session_timeout` supported as client config (pg 8.23.1).
- `node -e 'new (require("pg-pool"))({max:Number("abc")}).options.max'` in `web/` → `10` (observed); with `"5"` → `5`.
- `sed -n` reads of `web/node_modules/jose/dist/webapi/jwks/remote.js:40-95`, `.../types/jwks/remote.d.ts`, `web/node_modules/@google-cloud/cloud-sql-connector/dist/mjs/cloud-sql-instance.js:140-185,268-285`, `web/node_modules/next/dist/server/lib/start-server.js:315-392`.
- `du -sh web/.next/standalone web/.next/static web/public web/jobs` → 116M, 2.2M, 44K, 12K (the lead's build; I ran no build). `npm ls --omit=dev --all --parseable` in `ingest/` with a byte count → 166 packages, 71.6 MB; `src`+`jobs` 0.33 MB.
- Live local runs of the standalone server (no 8080): `CMA_AUTH_MODE=bogus … PORT=8097 node .next/standalone/server.js` → `Ready`, then 500 on `/api/health`, `/`, `/day` with `CMA_AUTH_MODE must be one of iap, mock` in the log; `CMA_AUTH_MODE=iap CMA_DATA_MODE=mock PORT=8098` (no `IAP_AUDIENCE`) → `/api/health` 200, `/` 401 `missing`, `/day` with a token 401 `invalid`, log `iap: token rejected: IAP audience is not configured`. Logs in `/var/tmp/5.4/server-bogus.log`, `/var/tmp/5.4/server-noaud.log`. Both servers stopped afterwards.
