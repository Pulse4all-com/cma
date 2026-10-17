# METHOD.md: how this audit was run

Full IT audit of the Contactcenter-Management-App, 17 October 2026, by Claude Code in the Claude Code cloud
environment (no secrets, no Google credentials, network to npm and GitHub only). Static review and local runs
only, per the brief's hard rules (section 1). This file is the running log; the "Where I stopped" section at
the end is kept current at every commit so a fresh session can resume.

## 1. Plan

Order of work (brief, section 9): read → plan and threat model → audit by area with subagents → consolidate
and self-review → fix and red-team the fixes → report, PERFORMANCE, UX_REVIEW, READINESS, Gemini prompt →
System health increment → acceptance checks → PRs → final message.

Branches: work-in-progress commits go to the session branch `claude/eager-volta-q3ak9i` (the harness's
designated branch). Deliverables are cut from it onto the brief's branches: `audit/2026-10-17-report`,
`audit/2026-10-17-fix-<group>`, `audit/2026-10-17-readme-cockpit`, `audit/2026-10-17-health-db`,
`audit/2026-10-17-health-web`. Nothing is merged.

Subagents, one per area, each briefed with section 1 of the brief verbatim
(`local-records/_brief/subagent-preamble.md`) and a precise task; raw findings land in
`local-records/<area>/findings.md`. The lead owns severity, deduplication, the README check and all wording.

Highest migration on `main` at start: `db/74_forms_reporting.sql` / `db/75_verify_forms_reporting.sql`
(commit `35ea3e0`). So 0008q = `db/76`/`77` and 0008r = `db/78`/`79`, as the brief assumes.

## 2. Threat model

**Assets.** (a) Staff time and performance data, pay-relevant (`time_event`, `workday_summary`,
corrections, imported days, per-person call figures). (b) The audit log (`cma.audit_log`, insert-only).
(c) The pseudonymous customer mirror: CRM ids, country, keyed phone hashes, order facts, email metadata.
(d) Vendor credentials in Secret Manager (HubSpot app tokens and signing secrets, Aircall token, Shopify
client secret, hash peppers, `bq_reader`, `postgres`). (e) The IAP trust: the signed assertion and the
audience. (f) The ingest signing secrets per connection. (g) Prod availability and responsiveness in the
tenant's workday window (07:00–22:00 Europe/Amsterdam), with a manager and 13 agents depending on it daily.

**Actors and their worst realistic outcome; the control that stops it.**

| Actor | Worst realistic outcome | Control that stops it | Where this audit looks |
|---|---|---|---|
| Internet attacker at the load balancer | Reach `cma-web` or `cma-ingest` without identity; flood the ingest routes | IAP on `cma-web-backend`; ingress `internal-and-cloud-load-balancing` on both services; Cloud Armor rules 900/1000 on ingest; adapter authentication before any database touch | 5.1 (proxy, headers), 5.2 (auth per adapter, rawbody), 5.4 (Gemini checks the LB) |
| pulse4all.com account without an `app_user` row (passes IAP) | Read or write any tenant's data | `findPrincipal` → "no access yet"; RLS fails closed without `app.tenant_id`; every route goes through `forPrincipal` | 5.1 (routes), 5.3 (RLS) |
| Agent | Read colleagues' hours; alter own hours or status history; read customer data | Own-data functions filter on `cma.current_user_id()`; `workday.team` checked inside the database (CMA06); corrections only via `correct_workday` with reason and approver; no customer data on screens | 5.1, 5.3 |
| Supervisor / manager / admin | Misstate hours (correction without trail); widen own permissions through Preview; reach another tenant | Append-only events with corrections as new rows; preview narrows only; tenant from the identity match, never a parameter | 5.1 (preview), 5.3 |
| Holder of an automation connection's bearer | Send messages to anyone in the tenant; write records | Bearer compared in constant time; route scoped to its connection and adapter; `ingest.write` permission of the Ingest system user | 5.2 |
| Compromised vendor webhook sender (HubSpot, Aircall, Shopify) | Inject or replay events; poison the mirror; exhaust the database | Signature or HMAC per adapter; account/shop pinning; event keys for idempotency; `INGEST_ALLOW_REPLAY` dev only; read-back from the source, never trusting the payload | 5.2 |
| Compromised developer device | Push a malicious change to `main` (deploys prod); read prod data through the proxy | Ruleset: `main` only by PR, squash by Martin; prod terminal work only from the Chromebook; customer-row queries only in Studio | 5.4, 5.13 (CMA-024/068) |
| Reader of Cloud Logging | Learn URLs with tokens (`/invite/<token>`), personal data in log lines | The "no personal data in path or query" rule; structured logs with ids and counts only | 5.1 (invite tokens), 5.2 (log.mjs), 5.9 |
| Reader login (`bq_reader`, NocoDB) | Read base tables, raw payloads, hashes, secret names | `cma_readonly` has nothing on `cma`; `cma_read` views list columns explicitly | 5.3 |
| Malicious or buggy pull request | Deploy a broken or hostile `cma-web` to prod | PR review by Martin; `check-config`; no secrets in the build; (gap: no PR check trigger, CMA-024) | 5.4, 5.13 |
| Cloud Scheduler (not hostile, but a load actor) | Overlapping jobs exhaust connections (README's worst case 143 against 97) | Advisory locks or single-flight guards in the jobs; pool caps | 5.2, 5.5, 5.6 |

**Trust boundaries and entry points.** LB → IAP → `cma-web` (`proxy.ts` verifies the assertion; the app
trusts only the three `x-cma-identity-*` headers it sets itself). LB → Cloud Armor → `cma-ingest`
(`server.mjs` → adapter `verify.mjs` → core). Cloud Scheduler → Cloud Run jobs (OAuth token of the
scheduler service account; the job reads the database as `cma_app`). Application → Postgres as `cma_app`
under RLS, one transaction per call with `set_config(..., true)`. Readers → `cma_read` only. GitHub →
Cloud Build (`cma-build`) → Artifact Registry → `cma-web` prod.

**Priorities derived.** (1) Anything that lets a tenant read or alter another tenant's rows, or a person
alter pay data without a trail. (2) The ingest write path's authentication and its load on the shared
database. (3) The DST night of 24/25 October (first autumn change with real hours). (4) Speed on the daily
paths (a slow tool is abandoned, and an abandoned tool misstates hours by omission). (5) The deploy and
ops scripts' unsafe defaults (the incident class of 16 October 2026). (6) Hygiene.

## 3. Environment and what ran here

- Clone made full with `git fetch --unshallow` (164 commits on `main`).
- Node 22.22.0, npm 10.9.4. `npm ci` in `web/` (502 packages) and `ingest/` (246 packages): both exit 0.
- PostgreSQL 16.15 (Ubuntu package, already installed) started as a local server on 127.0.0.1:5432 with
  `max_connections=200`. Prod runs PostgreSQL 18; two sandbox shims were needed and are **not** repository
  changes: `pg_catalog.uuidv7()` (native in 18) and the team logins named in `db/00_roles.sql` as local
  roles, plus an `auditor@local` login holding `cma_owner` and `cma_app` by `SET ROLE`, and
  `cma-web@local.iam` / `cma-ingest@local.iam` as `cma_app` members with inheritance (as the service
  accounts are on Cloud SQL). Build script: `/var/tmp/build-local-db.sh` (sandbox), outputs in
  `local-records/db/`.
- The database built from `db/00` to `db/74` in README order (with the `02`, `03` and `06` reruns the
  scripts table prescribes): every script exit 0. Every verify script ran normal and provoked
  (`local-records/db/_verify-summary.txt`): all pass except four whose failures are sandbox or fixture
  artefacts to be confirmed in 5.3 (`07` block H as README documents once the fixture's day is used;
  `12` block B's acting-user lookup; `25` B3 an entry order; `39` D1 the outbox claim order, probably the
  `uuidv7()` shim's millisecond ordering).
- Playwright 1.63 is installed; the sandbox holds Chromium build 1194 at `/opt/pw-browsers/chromium`
  (Playwright 1.63 expects 1243), so the browser verifiers run with `executablePath` pointed at it where
  needed; `npx playwright install` is not run (environment rule).

## 4. Commands and outcomes (running log)

| When (UTC) | Command / step | Outcome |
|---|---|---|
| 16:42 | `git fetch --unshallow` | full history, 164 commits |
| 16:43 | `npm ci` web, ingest | exit 0, exit 0 |
| 16:45 | local PostgreSQL 16 initdb + start | running on 127.0.0.1:5432 |
| 16:46 | `/var/tmp/build-local-db.sh` (db/00…74 + seeds) | all exit 0 |
| 16:47 | all verify scripts normal + provoked | see `local-records/db/_verify-summary.txt` |
| 16:49 | `npm run build`, typecheck, lint, 16 pure verifiers, ingest lint + `npm test` | all exit 0 (one lint warning: unused `uid` in `verify/follow-up.mjs`); outputs `local-records/web-baseline/` |
| 16:52 | nine area subagents launched (5.1, 5.2, 5.3, 5.4+5.5, 5.6 static, 5.7, 5.8+5.9+5.10, 5.11, 5.12) | findings in `local-records/<area>/findings.md` |
| 16:55 | standalone server, mock mode, port 8080; `/var/tmp/measure-ttfb.sh` 50 sequential requests per route | `local-records/5.6-speed-measured/ttfb-mock.txt`: p95 ≤ 126 ms on every page (sandbox) |
| 16:57 | standalone server, api mode against the local database (`CMA_DB_HOST`), port 8081; `log_statement=all` for one request per page | `round-trips-api.txt`: Welcome 8 (agent) to 12 (admin) transactions, 20 to 34 statements; every page ≥ 3 transactions |
| 16:59 | `measure-ttfb.sh` against the api server | `ttfb-api-localdb.txt`: p95 ≤ 77 ms on every page (sandbox, dev-seed volume, loopback) |
| 17:05 | `tc`/netem for an emulated round-trip delay | not available in the sandbox; round-trip cost is estimated from the statement counts instead |
| 17:06 | Playwright screenshots of every page per mock subject at 1280 and 1600 px (`/var/tmp/screenshots.mjs`, Chromium 1194 via `executablePath`) | `local-records/ux/before/`: 82 pages, no horizontal scroll; React error #418 (hydration text mismatch) on /messages, /roster/planner, /configuration/alert-rules |
| 17:10 | `next dev` on 8082, unminified hydration errors captured | cause: `Intl.DateTimeFormat` with `weekday` renders "Sat 17 Oct" in Node's ICU and "Sat, 17 Oct" in the browser's; `fmtDate` compact/long and `Inbox.tsx:35` |
| 17:20 | 0008r written: `db/78_system_health.sql`, `db/79_verify_system_health.sql`; run locally | 78 applied and rerun (exit 0); 79 13 PASS normal, 13 FAIL provoked; `33` and `73` rerun unchanged |
| 17:40 | System health web half: `lib/health.ts` + `verify/health.mjs` (39 checks, provoked), data reads, page, route, manifest script, job run row | typecheck exit 0, lint 0 errors; `verify:copy` 1824 keys PASS; the job run locally wrote one run row per tenant |
| 17:50 | documents route probed on the dev server | traversal, manifest.json, a name outside the list, a NUL byte: 404; a manager: 403; a document in the build: 200 as an attachment, bytes identical |
| 17:55 | PRs opened: `Pulse4all-com/cma#150` (ingest security, Shopify token cache per connection, batch failures, verifier logins), `#151` (0008q `db/76`/`77`), `#152` (0008r `db/78`/`79`, then README rows and catalog `how`) | each from its own worktree under `/var/tmp/wt/`; the branch names of the brief |
| 18:00 | System health web half in its worktree: Dockerfile `documents/` copy, `cloudbuild.yaml` `copy-documents` step, `docs/system-health/documents.txt`, theme and layout entries, README paragraph and API row; `npm run typecheck`, `lint`, `build` (real `node_modules` copied in: Turbopack refuses a symlinked one for the standalone output), 16 pure verifiers | all PASS (health 39, copy 1824 keys); the copy step's script run by hand against a tree with 2 of 8 files: 2 copied, 6 reported skipped |
| 18:05 | standalone server in mock mode on 8083: the page as admin and agent, the documents route with six names | admin 200 with six cards; agent the same no-access rendering as other Configuration pages; REPORT.md 200 attachment, agent 403, unlisted, manifest.json, `..%2F`, `a%2Fb.md`, `.env` 404 |
| 18:08 | `verify:theme` and `verify:layout` against 8083 (Playwright 1.63 expects headless shell 1243: symlinked to Chromium 1194 in `/opt/pw-browsers`) | theme PASS (54 pages), layout PASS; the verifier's screenshots under `records/layout` restored (`git checkout`, `git clean`): never committed |
| 18:12 | `#153` opened (System health web half) | — |
| 18:10 | web security worktree: typecheck, lint, `verify:boundaries` (PASS 229 files; provoke FAIL 5), `verify:iap-token`, 14 pure verifiers, standalone build, mock server on 8084: headers, `/api/health`, `verify:theme` normal and provoked | all PASS; provoke FAIL 9 (the three header checks among them); `#154` opened |
| 18:18 | Cloud Build config worktree: check-config guards and three deploy flags; the check script run locally with nine substitution sets after applying Cloud Build's `$$` and `${_X}` rules by hand | good set exit 0; eight bad sets exit 1 with their message; `#155` opened |
| 18:14 | speed worktree: per-request database accounting keyed by the trace id, `instrumentation.ts` span processor (request log line), `x-cma-db` and `cma-db` meta under `CMA_DB_TRACE=1`, `verify/round-trips.mjs`; standalone build, api mode against the local database on 8085 | header and meta carry the counts (`/api/v1/me` tx=1 rt=5; Live board manager tx=7 rt=33); the log line reports tx=0: the trace id at query time differs from the request span's; debugging the span tree |
| 18:15 | subagents started for the UX fix PR (worktree `fix-ux`) and the ingest reliability and ops PRs (`fix-ingest-reliability`, `fix-ops`) | running |
| 18:24 | speed: the request log line reported tx=0 while the header carried counts; span tree logged under a debug switch | two `BaseServer.handleRequest` spans per request (an outer one without a route, the inner one with it); the queries run under the inner trace; the record was not found because Next bundles the instrumentation file apart from the server chunks (two module instances, two maps): the map moved to `globalThis`, debug switch removed; the line then read `/live/board tx=7 rt=33` |
| 18:30 | `#156` opened (README cockpit, the eight edits applied bottom-up by anchor; 2143 → 2150 lines) | — |
| 18:33 | speed, after: `measure-ttfb.sh` (50 requests per route) and the statement-log count against the build of the speed branch | `ttfb-api-localdb-after.txt`, `round-trips-api-after.txt`: every one of 44 requests one transaction and two statements lower; time to first byte unchanged within noise on loopback |
| 18:40 | the ingest subagent's cross-PR note: a checked-out pg client without an error listener ends the process on the server's FATAL (idle-in-transaction timeout); reproduced with a 10-line script against the local database (`idle-tx-check.txt`) | bare: `UNCAUGHT 25P03`, exit 3; with the listener the transaction fails and the pool serves the next query; the listener added to the web `transaction()` before the PR |
| 18:44 | `verify/round-trips.mjs` with the 44-request budget observed after the change; normal and provoked against a fresh standalone server; the 15 pure verifiers | PASS (44); provoke FAIL (88 problems); all pure verifiers PASS |
| 18:46 | PRs opened: `#157` (ingest reliability: lock, timeouts, redirects, cap, replay guard), `#158` (ops: deploy.sh main guard, reconcile 03:30, Dependabot), `#159` (speed) | — |
| 18:50 | report worktree: PERFORMANCE.md written; subagents writing FINDINGS.csv, BACKLOG_CANDIDATES.md, GEMINI_PROMPT.md, READINESS.md, OPERATIONS.md, PLAN_B.md and the README drift fixes | running |

## 5. Assumptions made explicit

- The brief's branch names are used for the PRs; work-in-progress is committed to the session branch.
- Local PostgreSQL 16 stands in for Cloud SQL PostgreSQL 18: plan shapes and index use are comparable;
  absolute timings are not (different CPU, no network, no HA). Every number from the sandbox is marked
  "sandbox observed".
- The mock subjects, dev seed and fixtures are fictional (checked in 5.9).

## 6. Self-review passes

### 6.1 False-positive hunt (after the twelve area reports, before the fixes)

Each finding was read again with the question "what would make this wrong?". Outcomes:

- **Dropped or folded into Info**: DB-12 (the statistical anomalies in the dev seed were artefacts of the seed's fixed timestamps, not a bug); five of the sixteen 5.1 items that were style preferences rather than defects; the 5.7 lint-level remarks (kept only CQ-01, CQ-05, CQ-08, CQ-10). The "sources() scans" finding (DB-05) was kept at Low after `explain` on the seed showed an index scan at seed volume; the risk is growth, which the finding now says.
- **Downgraded**: 5.6-01 (the Live board poll) from the draft's High to Medium: the board's render was measured at 46 ms p50 in the sandbox, far under the target; the finding is about cost growth and database time, not a missed target. UX-06 ("Waiting 0 min") kept at Medium rather than High because the Missed-at column and the hint sit next to the figure.
- **Confirmed by reproduction**: 5.2-01 (one token cache for every Shopify connection: read twice, then a two-tenant flow case written that fails on main and passes after); DB-01 (the audit trigger's owner path: a statement run as the owner role in the local database); INFRA-01 (a standalone build in iap mode without an audience answered `/api/health` 200 and every page 401); UX-01 (the hydration mismatch root-caused to ICU weekday patterns with an unminified dev server, not to the component suspected first); UX-02 (data-shortcut "10" to "18" observed on the manager's rail; the hook returns on `e.key.length !== 1`).
- **Kept as proposals, not fixes** (rule 10): 5.6-02 (a database change on the follow-up read), DST-02 (the import's ambiguous autumn hour: a correctness question on time, proposed with the exact SQL), DB-09 and DB-10 (historical scripts and the `cma_read` SECURITY DEFINER count: documentation, not code), UX-05 (semantic colour tokens: a style-guide decision for Mark).
- **Severity check against the brief's scale**: no Critical. Three High (5.2-01, DB-01, INFRA-01), each fixed in a PR (#150, #151, #154 with #155) before the report, as rule 7 requires. Everything else Medium, Low or Info.

### 6.2 Red team (after the fixes, against the PR branches)

- **Documents route (#153)**: tried `..%2Fpackage.json`, `a%2Fb.md`, `.env`, `manifest.json`, a name with a NUL byte, an upper-case variant of a listed name, a 65-character name and a listed name missing from the manifest: every one 404; an agent on a listed name 403; the directory is never read for listing (the manifest is the only index, written at build). The name check is a regex plus the allowlist plus the manifest, in that order, so a future allowlist entry cannot widen the path (`[A-Za-z0-9][A-Za-z0-9_.-]*`, no `..`, at most 64 characters). The download sets `nosniff` and `attachment`. Not found: a way to read a file the build did not copy.
- **CSP (#154)**: every form in the app posts to its own origin; `/logout/end` answers 303 to a same-host path (`/signed-out?gcp-iap-mode=CLEAR_LOGIN_COOKIE` or `/logout/done`), so `form-action 'self'` blocks nothing; the IAP sign-in happens before the app. No inline-script restriction yet, which the report says; the nonce step is the next PR.
- **IAP header stripping (#154)**: the headers are deleted after verification and before the identity headers are set; mock mode never carries them. Checked that nothing after the proxy reads them (the boundaries verifier's rule keeps the header list in the proxy alone).
- **`/api/health` 503 (#154 with #155)**: with `CMA_AUTH_MODE` unset the mode defaults to `iap` and the route answers 503 without an audience: fail-closed, and with the startup probe the revision never takes traffic. In mock mode it answers 200 (the sandbox servers). The deploy's smoke test reads the same route.
- **Identity in one transaction (#159)**: the `set_config(…, true)` calls are transaction-local, so the tenant context ends with the transaction; the principal query runs under the same RLS context the earlier second transaction set. Tenant isolation is exercised by the api verifier (Martin's run) and was not changed by the merge of the two steps; the 44-request statement count shows exactly one transaction and two statements fewer per request and nothing else.
- **Per-request memoisation (#159)**: `rolesOf` is React's `cache()`, scoped to one request; the database accounting map is keyed by the trace id of the request span and the entry is removed when that span ends; without a span nothing is stored. Two requests never share a trace id, so no count or time of one request can reach another. Tried to make it leak by requesting two pages concurrently (counts stayed per request).
- **The connection-lost listener (#159, #157)**: reproduced the process exit without a listener and the handled failure with it (`idle-tx-check.txt`); the pool drops the dead client (`release(err)`) and serves the next query.
- **The job lock (#157)**: session-level advisory lock on one pooled client; two concurrent runs in the verifier: exactly one ran; a crashed process ends its session and the lock with it; the two-int key cannot collide with the database's one-key `hashtextextended` locks.
- **Cloud Build guard (#155)**: the check script run with nine substitution sets after applying Cloud Build's `$$` escaping by hand; the file's own defaults (iap, empty audience) now stop the build, which is the intended consequence and is stated in the file's header and the PR.
- **Round-trips budget (#159)**: `CMA_DB_TRACE` is read once at module load and is never set in `cloudbuild.yaml`; the header and the meta exist only in a local run. Provoked, every budget is 0 and all 88 checks fail.
- **Not broken, but noted**: the health page's documents card shows a build without the report's files as "not in this build" until the report PR merges and a web build runs; the first prod deploy after #153 therefore shows an empty documents list by design.

## 7. Where I stopped / next step

- 18:50 UTC: PRs #150 to #159 open (ingest security, 0008q, 0008r db and web, web security, Cloud Build
  config, README cockpit, ingest reliability, ops, speed). In progress: the UX PR (subagent), the report set
  (two subagents on the CSV, backlog, Gemini prompt, readiness, operations, Plan B and README drift; the
  lead on REPORT.md, UX_REVIEW.md and this file). Then: the self-review and red-team passes (section 6),
  the acceptance greps (no secret, no records/ change, no db/00 to db/75 change, no model name), the README
  Decision log rows and Last updated line in the report PR, the final session message.
