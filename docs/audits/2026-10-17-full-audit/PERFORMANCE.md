# Performance: what was measured, what was fixed, what is estimated

Part of the full IT audit of 17 October 2026 (area 5.6). Every number below is marked **observed** (measured in the audit's sandbox), **expected** (follows from code that was read) or **estimated** (a judgement about production, which this audit never touched). The sandbox is a container with the repository, a local PostgreSQL 16 built from `db/00` to `db/75` with the dev seeds, and the standalone Next.js build on loopback; production runs PostgreSQL 18 on Cloud SQL behind the Cloud SQL connector from Cloud Run in `europe-west4`. Absolute times from the sandbox therefore say nothing about production; counts of transactions and statements do.

## 1. Targets (proposals, Martin confirms in READINESS.md)

From the brief, at today's volume and 13 to 20 concurrent users: server time to first byte **p75 ≤ 300 ms and p95 ≤ 800 ms** on the agent pages (Welcome, My day, My hours, Messages, My schedule) and on the Live board; **p75 ≤ 600 ms and p95 ≤ 1.5 s** on report pages; a cold instance serves its first request within 2 s; the two polls (Live board, unread count) cost under 20 ms of database time each. The request log line shipped in [Pulse4all-com/cma#159](https://github.com/Pulse4all-com/cma/pull/159) is what makes these measurable in production (section 6).

## 2. Baseline, sandbox observed (before any change)

Method: `curl` time to first byte, 50 sequential requests per route and mock subject after a warm-up, standalone build, `CMA_DATA_MODE=api` against the local database (`local-records/5.6-speed-measured/ttfb-api-localdb.txt`; the mock data mode in `ttfb-mock.txt`). Transactions and statements per request counted from the PostgreSQL statement log (`round-trips-api.txt`).

| Route (subject) | p50 ms | p95 ms | Transactions | Statements |
|---|---|---|---|---|
| `/` Welcome (agent) | 53 | 77 | 8 | 20 |
| `/day` (agent) | 35 | 59 | 4 | 9 |
| `/hours` (agent) | 26 | 39 | 3 | 6 |
| `/` Welcome (manager) | 57 | 73 | 11 | 31 |
| `/live/board` (manager) | 45 | 63 | 8 | 26 |
| `/team/people` (manager) | 36 | 52 | 9 | 26 |
| `/reports/follow-up` (manager) | 42 | 66 | 7 | 19 |
| `/` Welcome (admin) | 51 | 64 | 12 | 34 |
| `GET /api/v1/me` (poll) | 11 | 18 | 2 | 4 |
| `GET /api/v1/me/messages?unread=1` (poll) | 14 | 22 | 3 | 7 |
| `GET /api/v1/team/now` (poll) | 22 | 30 | 3 | 8 |

Observed on loopback every page answers in under 110 ms at p95, so the sandbox cannot show the targets being missed; what it shows is the **shape** of the cost: every request paid two transactions (seven statements) for identity before reading anything, every page runs its reads in parallel transactions (one pool slot each), and the Live board's 10-second poll is a full page render of eight transactions per viewer.

## 3. What the static review found (5.6-01 to 5.6-11)

| Id | Finding | Severity | Status |
|---|---|---|---|
| 5.6-01 | The Live board's poll is a full render: 8 transactions and 26 statements per viewer every 10 s | Medium | proposed: one composite read `getLiveBoard()` in one transaction, also served as `GET /api/v1/live/board` |
| 5.6-02 | `cma.follow_up_summary()` re-derives the whole lead history on every call, on the board poll and every supervisor's Welcome | Medium | proposed: a tenant setting `follow_up.lead_lookback_days` applied as the lower bound in `open_leads_of()` and a partial index; a database change (new pair) |
| 5.6-03 | Identity costs two transactions (seven statements) per request | Medium | **fixed in #159** (one transaction) |
| 5.6-04 | The pool starts cold after every quiet half minute: no minimum, idle timeout 30 s, no statement ceiling | Medium | **fixed in #159** (min 1, idle 300 s, warm at start, `statement_timeout` 15 s, idle-in-transaction 30 s) |
| 5.6-05 | No Suspense boundary on any page: the slowest read gates the whole response | Low | proposed (streaming per card, as the System health page does in #153) |
| 5.6-06 | The roles list read two or three times on an admin's page | Low | **fixed in #159** (`rolesOf`, once per request) |
| 5.6-07 | `cma.calls_overview()` called three times on the Calls report with the same bounds | Low | proposed (one call, three projections) |
| 5.6-08 | The copy object (about 90 KB) serialised into every page's RSC payload | Low | proposed (per-page copy slices) |
| 5.6-11 | `setInterval` poll can overlap a slow render | Low | **fixed in #159** (timeout chain) |
| DB-03 / INFRA-03 | No `statement_timeout` or `idle_in_transaction_session_timeout` anywhere | Medium | **fixed** for the web pool in #159 and the ingest pools in [#157](https://github.com/Pulse4all-com/cma/pull/157); the scheduler job's pool is next |
| DB-04 | Non-sargable date bounds in `calls_of`, `inbound_calls_of`, `lead_deals_of` | Medium | **fixed in [#151](https://github.com/Pulse4all-com/cma/pull/151)** (coalesced bounds) |
| DB-05 | `cma.sources()` scans `ingest_event` per connection | Low | partly: the two indexes of #151; the counts stay per request |
| DB-11 | 46 foreign keys without an index | Low | two added in #151 (`ingest_event`); the rest listed in the report |

## 4. After the speed PR, sandbox observed

Same method, same database, the build of #159 (`ttfb-api-localdb-after.txt`, `round-trips-api-after.txt`).

| Route (subject) | p50 ms | p95 ms | Transactions | Statements | Change |
|---|---|---|---|---|---|
| `/` Welcome (agent) | 49 | 63 | 7 | 18 | −1 tx, −2 statements |
| `/day` (agent) | 29 | 40 | 3 | 7 | −1, −2 |
| `/hours` (agent) | 30 | 54 | 2 | 4 | −1, −2 |
| `/` Welcome (manager) | 47 | 70 | 10 | 29 | −1, −2 |
| `/live/board` (manager) | 46 | 62 | 7 | 24 | −1, −2 |
| `/team/people` (manager) | 46 | 65 | 8 | 24 | −1, −2 |
| `/reports/follow-up` (manager) | 36 | 51 | 6 | 17 | −1, −2 |
| `/` Welcome (admin) | 50 | 74 | 11 | 32 | −1, −2 |
| `GET /api/v1/me` (poll) | 10 | 20 | 1 | 2 | −1, −2 (half) |
| `GET /api/v1/me/messages?unread=1` (poll) | 14 | 22 | 2 | 5 | −1, −2 |
| `GET /api/v1/team/now` (poll) | 22 | 30 | 2 | 6 | −1, −2 |

Observed: **every one of the 44 counted requests costs exactly one transaction and two statements less**; the time to first byte on loopback is unchanged within noise (the loopback hides what a round trip costs). The request log line, observed on the same server: `/` as agent `tx=7 rt=30 dbMs≈311` (`rt` counts `begin`, the `set_config` calls and `commit` too; `dbMs` sums the time each transaction held a connection, so parallel reads make it exceed the total), `/day` `tx=3 rt=13`, `GET /api/v1/me` `tx=1 rt=5`.

## 5. What this is worth in production (estimated)

- **Per request**: one pool checkout and two statements across the Cloud SQL connector. With a round trip of about 1 ms between Cloud Run and Cloud SQL in the same region (estimated; not measured here), that is 2 to 5 ms per request and, more important, one pool slot freed for the page's parallel reads: a page with six reads and a pool of five no longer queues on identity.
- **After idle**: before #159 a quiet half minute closed every connection, and the next page paid the connector's handshake (a TLS connection plus the IAM token exchange, estimated 100 to 300 ms) for each parallel read; now one connection stays open per instance for five minutes and is opened at server start, so the handshake is paid once per instance, not once per quiet minute per read. For a 13-person team this is the difference people notice after a break, not under load.
- **The polls**: `GET /api/v1/me/messages?unread=1` at two transactions and five statements per tick is within the 20 ms database budget on the sandbox (observed) and expected to be in production; the Live board's poll at seven transactions is not (5.6-01, proposed).
- **Ceilings**: a report whose plan regresses can no longer hold a connection for Cloud Run's five-minute request timeout; it is cancelled at 15 s and the page shows the error card. This caps the blast radius of 5.6-02 until it is fixed.

Risk of the change: the statement ceiling cancels any statement over 15 s. No page or export in the repository runs a statement expected to take that long at today's volume (the exports stream rows; the reports aggregate at most a few months); if one appears in the request log line as `status: 500` with `dbMs` near 15000, raise `CMA_DB_STATEMENT_TIMEOUT_MS` on the service through `cloudbuild.yaml` (a CONFIG CHANGE) rather than removing the ceiling.

## 6. Instrumentation left in place

- **Request log line** (every request, production): `{"severity","message":"request","route","method","status","rsc","totalMs","dbMs","tx","rt"}`, written when Next's request span ends, so streaming is included. `route` is the pattern (`/configuration/sources/[id]`), never the path. WARNING above 800 ms, ERROR on 5xx. Cloud Logging: `jsonPayload.message="request" resource.labels.service_name="cma-web"`; a log-based metric on `jsonPayload.totalMs` per `jsonPayload.route` gives the p95 per page (Martin's step in READINESS.md).
- **Round-trips budget** (local verification): `CMA_DB_TRACE=1` makes the API routes answer `x-cma-db: tx=…;rt=…;ms=…` and the Shell render a `cma-db` meta; `npm run verify:round-trips` compares 44 requests with `verify/round-trips.json`. A page that gains a read fails it, which is the point: the budget is the review's question "why one more transaction?".
- **System health** ([#153](https://github.com/Pulse4all-com/cma/pull/153)): the storage round trip card times one trivial read per visit, the first place a slow database becomes visible without the Console.

## 7. Baseline in production (Martin's steps; expected outputs, nothing run from here)

1. **Browser**: Cloud Run → `cma-web` → Metrics: request latency p50/p95/p99, instance count and container startup latency over the last 7 days, by hour. Expected: the daytime p95 under the targets of section 1 on a normal day; startup latency under 2 s with the CPU boost of [#155](https://github.com/Pulse4all-com/cma/pull/155).
2. **Browser**: the same for `cma-ingest`; Cloud SQL → `cma-prod-pg` → System insights: CPU, memory, connections and the top queries by total time. Expected: `cma.follow_up_summary` and `cma.sources` among the top queries if 5.6-02 and DB-05 are as estimated; the connection count up to one per running `cma-web` instance in idle hours after #159.
3. **Browser**, after a week with #159 live: Logs Explorer, the query of section 6, grouped by `jsonPayload.route`. Expected: a p95 per page that confirms or corrects the targets; the result goes into READINESS.md as the first production baseline.
4. Optional **Studio** (`cma-prod-pg`, read-only, no customer rows): `explain (analyze, buffers)` of `select * from cma.follow_up_summary_of('<tenant id>')` as `cma_owner`. Expected: a sequential pass over the lead deals since the intake start date (the shape 5.6-02 describes); the row count and the time are the inputs for the lookback bound's default.

## 8. What v2 of the speed work would do, in order

1. The Live board's composite read in one transaction with a shared `GET /api/v1/live/board` (5.6-01); then the poll fetches that route and updates the board client-side instead of re-rendering the page.
2. The lookback bound for the follow-up summary as a tenant setting with its index (5.6-02, a database pair).
3. Suspense per card on Welcome and the Live board, as the System health page does (5.6-05).
4. One `calls_overview()` call on the Calls report (5.6-07) and per-page copy slices (5.6-08).
5. A statement ceiling on the scheduler job's pool (`web/jobs/close-forgotten-workdays.mjs`) to complete INFRA-03.
