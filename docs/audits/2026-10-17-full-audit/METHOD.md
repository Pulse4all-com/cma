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
| 16:49 | `npm run build`, typecheck, lint, pure verifiers, ingest lint + test (background) | pending |

## 5. Assumptions made explicit

- The brief's branch names are used for the PRs; work-in-progress is committed to the session branch.
- Local PostgreSQL 16 stands in for Cloud SQL PostgreSQL 18: plan shapes and index use are comparable;
  absolute timings are not (different CPU, no network, no HA). Every number from the sandbox is marked
  "sandbox observed".
- The mock subjects, dev seed and fixtures are fictional (checked in 5.9).

## 6. Self-review passes

(to be written after the findings are drafted and after the fixes are made)

## 7. Where I stopped / next step

- 16:50 UTC: environment ready, database built and verified, threat model written. Next: wave 1 subagents
  (5.1, 5.2, 5.3, 5.4+5.5, 5.6 static, 5.7, 5.8+5.9+5.10, 5.11, 5.12) while the web build and baseline
  checks run; then speed measurements (5.6) on the standalone server in mock and api mode.
