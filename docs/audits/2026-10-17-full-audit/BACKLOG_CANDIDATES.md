# Backlog candidates from the full IT audit of 17 October 2026

What is left after the fix PRs (Pulse4all-com/cma#150 to #159 and the pending Pulse4all-com/cma#160): every item below is a
finding of `FINDINGS.csv` whose status is `proposed`, `already-open` or `fixed (partly)` with a remaining part,
and that is worth a backlog row. Lint nits, header comments and observations without an action are left out
(they stay in the CSV). "Placement" is an existing backlog id where the area file named one, otherwise `new`.
Severity and effort are the area files' (effort S, M, L). Nothing here reopens a README decision; the
dated items come from `local-records/5.13-readiness/dated-items.md` and the README's Open decisions.

## Before the soft launch

| AUD | Title | Severity | Effort | Placement | Why now |
|---|---|---|---|---|---|
| AUD-022 | Alert policies: 5xx share, p95 latency, failed job executions, Cloud SQL capacity, uptime checks and certificate expiry (INFRA-06) | Medium | M | new (next to CMA-031 and CMA-034) | Today one policy exists (ingest 429); every other outage is found by an agent who cannot clock in or by someone reading logs. Console-only steps, dry-run first, then folded into `docs/ingest/alert.sh`. |
| AUD-023 | A rehearsed restore: quarterly PITR clone drill, dev first, recorded from Martin's run (INFRA-07) | Medium | S | new | Real staff time data is already in prod and no restore has ever been done; HA does not cover a bad migration or an update without a where. One hour. |
| AUD-036 | Badge text tones and the focus ring below WCAG AA contrast (UX-05) | Medium | S + a decision | new (a D-series style decision with the brand owner) | The chips a supervisor scans all day are the least legible text on the screen; the fix is three token values once the brand owner agrees. |
| AUD-019 | Pin the remaining `cma-web` runtime settings in `cloudbuild.yaml` (service account, ingress, CPU, memory, concurrency, timeout) after reading the live values (INFRA-02, follow-up of #155) | Medium | S | new | #155 pinned `--min-instances=1` and `--cpu-boost`; a recreate still falls back to Cloud Run defaults (ingress `all`, the default compute account) for the rest. CONFIG CHANGE section. |
| AUD-106 | Move CMA-024 (PR check trigger) and CMA-068 (dev-only web build) up (INFRA-14) | Info (pointer) | – | CMA-024; CMA-068 | Nothing between a reviewer's eyes and the agents' browsers executes a web change; the startup probe of #155 is only the compensating control. |
| AUD-044 | Ignore-file gaps: `.env*` at the root and under `ingest/`, `.gcloudignore` includes, `ingest/.dockerignore` (WEB-11) | Low | S | new (related to CMA-038) | Three small edits close the two paths by which a filled people template or an `ingest/.env` could leave a laptop; nothing has leaked yet. |
| AUD-123 | Dated check: the DST night of 24 to 25 October 2026 and the reconcile's run (DST-01 moved it to 03:30 in #158; confirm the night's `sync_run` rows on 26 October) | Info | S | new (dated) | Within the week; a Browser and Studio check only. |

## In the first month

| AUD | Title | Severity | Effort | Placement | Why in the first month |
|---|---|---|---|---|---|
| AUD-008 | Secret names on connection rows scoped to the tenant: an allow-list table or a naming rule enforced in `upsert_connection` and joined by the ingest's lookups (5.2-04) | Medium | M | new | Today only Studio writes these names; before any admin screen for connections exists, the schema should hold the tenant boundary that `tenant.configure` holds now. |
| AUD-021 | Parked ingest events: a resolve action (retry or drop) with a route and a button, and a Data quality row (INFRA-05, remainder) | Medium | M | CMA-031 | System health (#152, #153) shows parked events per connection; nobody can clear them in-app, and the first vendor outage longer than four hours will park a window for good. |
| AUD-024 | Live board: one composite read behind `GET /api/v1/live/board`, the poll updating a client island instead of `router.refresh()` (5.6-01) | Medium | M | new | The steady-state load driver (8 transactions per viewer every 10 s); measure after #159 has landed, then redesign. The 10-second interval itself is settled. |
| AUD-025 | `follow_up_summary` bounded by a tenant setting `follow_up.lead_lookback_days` plus partial indexes on open tickets and not-done tasks (5.6-02) | Medium | M | new | Recomputes the whole lead history on every board tick and every supervisor's Welcome; grows for ever with the mirror. An EXPLAIN on the largest tenant decides the variant. |
| AUD-028 | `cma.calls_filter_values(from, to)` so the Calls pages aggregate once, not three to five times (5.6-07) | Medium | S / M | new | The month view of Reports → Calls; pairs with the next migration pair. |
| AUD-029 | One `fill()` helper for copy placeholders and a verifier rule against inline `replace` (CQ-01) | Medium | M | new | A name holding `$` renders wrong text on confirmations and labels; a mechanical codemod over 167 sites. |
| AUD-030 | Test posture: a two-connection concurrency check for the double clock-in branch, a pure `proxy.ts` test, a mock/postgres parity check, a parser fuzz (CQ-08) | Medium | M | new | The time model's one race is handled by code nobody has run; the gate every request passes has no test without a deploy. |
| AUD-017 | Migration conventions: "one transaction with `set local lock_timeout`" in README's Conventions for every migration; long jobs set their own statement ceiling (DB-03 remainder, DB-09) | Low | S | new | #151 already follows it; the rule should be written where the next migration author looks. |
| AUD-071 | Refuse a personal property name in the slot-to-property mapping (DP-02) | Low | S + a migration pair | new | The field-mapping screen exists; a slip maps `email` to a slot and mirrors addresses into `raw` and the audit images. |
| AUD-047 | Refuse an empty `INGEST_PUBLIC_URLS` on Cloud Run instead of trusting `Host` (5.2-09) | Low | S | new | The knob the 16 October incident turned on; one guard. |
| AUD-050 | Pin builder and base images by digest (INFRA-08, 5.2-13) | Low | S | new | Reproducible rebuilds; costs nothing; the NocoDB template already does it. |
| AUD-051 | Refuse a non-integer `CMA_DB_POOL_MAX` in both database clients (INFRA-09, remainder) | Low | S | new (follow-up of #155) | A typo turns 20 connections into 40; #155 guards the build, not a hand deploy. |
| AUD-052 | Extend `ingest/verify/deploy-script.mjs` to the caps, timeouts, schedules and the pepper path (INFRA-11) | Low | S | new | The caps are the next flags that could fall back to a default unnoticed. |
| AUD-053 | `docs/scheduler/deploy.sh`: a dry run, a dedicated invoker account, and the job's image refreshed after a web merge (INFRA-12) | Low | S | new | The hourly job can run a stale image for weeks; a standing extra permission on the web service's identity. |
| AUD-054 | Do not `pool.end()` at SIGTERM in the web client; let Next drain (INFRA-04) | Low | S | new | A few "database unavailable" answers to people mid-action on every deploy during a shift. |
| AUD-055 | Decide: accept the fail-closed key-set fetch and document it, or a bounded stale fallback (INFRA-10) | Low | S | new (a decision) | A transient egress failure at the 10-minute refresh costs signed-in people a 401; the authentication path, so Martin decides. |
| AUD-058 | Pass copy slices to client components instead of the whole dictionary (5.6-08) | Low | S | new | About 90 KB per page and per board refresh; mechanical. |
| AUD-059 | An Open decision on `ingest_event` retention (5.6-09) | Low | M | new (next to CMA-003) | The indexes are done (#151); how long processed and ignored events stay is a decision, not code. |
| AUD-062 | Copy verifier: placeholder parity between languages and an unused-key check; remove the ten dead keys (CQ-02) | Low | S | new | Protects the Dutch copy from a dropped `{n}`. |
| AUD-087 | One line in `docs/import/README.md` on the ambiguous autumn hour (DST-02) | Low | S | new | Before the next historical import; the migration-side check can wait. |
| AUD-038 | A request-log exclusion for `/invite/` (WEB-02) | Low | S | already open (Open decisions, the invitation token in request logs) | Cheaper than the fragment approach; a Console step with a stated trade-off. |
| AUD-098 | Check in prod which header carries the public host (`Host` or `x-forwarded-host`) and read it in the two form-post routes or document the fallback (WEB-15) | Info | S | new | A prod observation only Martin can make. |
| AUD-123 | Dated items: the first monthly bill on the dedicated core (about 1 to 5 November 2026, raise the budget alert), the Cloud Armor rate-limit review (about 12 to 13 November 2026), email deletions (about 16 November 2026) | Info | – | CMA-034 and the Open decisions bullets | The dates are the README's own. |

## Later

| AUD | Title | Severity | Effort | Placement | Why later |
|---|---|---|---|---|---|
| AUD-006 | CSP step 2: a per-request nonce with `script-src 'nonce' 'strict-dynamic'`, report-only first (WEB-01) | Medium (step 2) | M | new | Step 1 ships in #154; step 2 is work on `proxy.ts` and the layout, to do once step 1 has run in prod. |
| AUD-035 | Move `Shell` into a route layout so a `loading.tsx` skeleton per route group can match the final layout (UX-04, the PROPOSAL part) | Medium | M | new | The SAFE part (RailLink feedback, error and not-found pages) ships in the Pulse4all-com/cma#160; the structural move is a larger web change. |
| AUD-056 | In-page `Suspense` around the tiles of Welcome, the Live board and the reports (5.6-05) | Low | M | new | After measurements at prod volume show where TTFB goes. |
| AUD-060 | A composite `getMyDay` read (day plus statuses in one transaction) (5.6-10) | Low | S | new | Folds into the Live board and Welcome redesign. |
| AUD-070 | A tenant setting `outbox.late_minutes` replacing the hardcoded 10 minutes in four places (CFG-01) | Low | M | CMA-039 | Principle 1; no tenant needs another value yet. |
| AUD-091 | The line switch-off dialog asks for the count of stored calls it removes (UX-10) | Low | M | CMA-020 | A read column and a migration pair. |
| AUD-012 | `cma_app` deletes on master data: validity columns function by function (DB-06 part 2) | Low | M | CMA-060 | Part 1 (five revokes) is in #151; the verify block measures the rest. |
| AUD-010 | Retention and monthly partitioning of `cma.audit_log` (DB-02 remainder) | Medium | M / L | CMA-003; CMA-026 | With the aggregation of agent data older than a year, due before 2 January 2027. |
| AUD-100 | `sync_run`: a version column and a lost-run reaper (5.2-11 remainder) | Info | M | new | When System health needs them; today the page derives staleness from age. |
| AUD-101 | An account-wide Aircall pace or a lower per-process default (5.2-12, CFG-02) | Info | M | CMA-040 | After a backfill shows 429s; the documentation sentence is corrected meanwhile. |
| AUD-063 | Code hygiene in one tidy PR: dead exports, the duplicated `dateKeyInZone` and `DIMENSIONS`, the `[cma-auth]` prefix on the IAP line, three header comments (CQ-03, CQ-04, CQ-06, CQ-07) | Low | S | new | Do it while touching the files. |
| AUD-092 | Seven more `iap-token.mjs` cases (alg=none, HS256, nbf, unknown kid, missing iat or email, duplicate header) (WEB-05) | Info | S | new | With the next jose bump; the library already refuses them. |
| AUD-096 | `_DATA_MODE: api` as the `cloudbuild.yaml` default (WEB-13) | Info | S | new (a CONFIG CHANGE decision) | #155's guard refuses a mock mode without `_ALLOW_MOCK=1`; the one-word default change needs Martin's confirmation that the trigger sets the mode. |
| AUD-123 | Dated items: the Shopify `read_all_orders` scope and the 60-day order window (about 30 November 2026); the aggregation of agent data older than a year (CMA-026) before 2 January 2027, with the retention job (CMA-003) riding on it | Info | – | CMA-026; CMA-003 and the Open decisions bullets | The dates are the README's own. |
