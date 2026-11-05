# Night notes, N06: the fastest Workspace we can build (addition 0008zr)

Night of 5 to 6 November 2026, brief N06. Written by Claude Code while Martin was away. Everything was built, measured and verified in the session's own container: PostgreSQL 16.15 (prod runs 18) with a local `uuidv7()` shim, `db/00` to `133` replayed with the dev seeds, `web/verify/perf-volume-fixture.sql` at multiplier 3, Node 22, the standalone build. Nothing touched dev, prod, Google Cloud or a vendor. Two stacked pull requests: **N06a** (`claude/youthful-meitner-ve6gtm`: the database, the measuring scripts, the job, the tool, the documentation) and **N06b** (`claude/youthful-meitner-ve6gtm-n06b`, on top of N06a: the web). The local outputs are in `local-records/` (its README says what each folder holds); `records/` stays for Martin's own runs.

## What changed

**N06a, the database (addition 0008zr).**
- `db/130_census.sql` (read only): volume and health per table of 10,000 rows or more, dead rows and the last autovacuum, unused indexes (listed, never dropped), invalid indexes (a FAIL), foreign keys without an index, `pg_stat_statements`' top statements when the extension is there (a row that says how to add it otherwise). Settings `verify.min_rows`, `verify.max_dead_pct`, `verify.top_statements`, provoke mode. 112 rows locally, 113 FAIL provoked.
- `db/131_time_all.sql`: every page's, poll's and report's reads timed as the application (`cma_app`, RLS on), per active tenant, acting as the tenant's first active person holding the read's permission; best of two runs against the class budgets (poll 20 ms, agent page 50, list 300, overview 500, Sources 150, Data quality 500); parts `a` (polls and pages), `b` (the report cores, previous calendar month) and `c` (92 days), `verify.part` chooses; rolled back, not read only (night default N06-5), with a proof row. Provoked: every timed row FAIL.
- `web/verify/perf-volume-fixture.sql`: a local fixture at three times prod's volume as of 5 November 2026 (the table below), on `follow-up-volume-fixture.sql`'s guards (refuses any database where `cloudsqladmin` exists and any without the dev seed), invented ids only, multiplier `cma.perf_multiplier`. Loads in 98 s at 3.
- `web/verify/perf.mjs` and `perf.json` (`npm run verify:perf`): time to first byte p50 and p95 per route and subject (30 requests after 3 warm-ups, the budgets per route class scaled by `container_factor`), the HTML size and the client JavaScript per route from the build manifests against their budgets; `--observed` prints the figures as JSON, `--provoke` sets every budget to 0.
- `tools/perf/request-percentiles.mjs`: p50, p75, p95, p99 and max of `totalMs` per route from `gcloud logging read` output on stdin, with the share over 800 ms and the 5xx count; routes and numbers only (WP4.2).
- `db/132_perf.sql` (addition 0008zr): seven reads rewritten to the same answers (`cma.connection_held_kinds_of`, `cma.system_health_runs`, `cma.missed_callbacks_of`, `cma.calls_of`, `cma.inbound_calls_of`, `cma.intake_per_day_of` with `cma.market_codes_of`, `cma.open_tickets_of`, `cma.open_tasks_of`), `jit = off` on six set functions so they are planned with their own parameters, `cma.inbound_now()` for the Live board's inbound poll in one statement, and data quality on stored results (backlog CMA-087): `cma.data_quality_snapshot` and `cma.data_quality_finding` per tenant (ids, codes and counts only, no audit trigger), the tenant setting `data_quality.refresh_minutes` (5, 1 to 1440), the permission `data_quality.refresh`, the job `refresh_data_quality` on the 0008s pattern (`cma.refresh_data_quality()`, an advisory lock per tenant, `job_run_start` and `finish`), `cma.flash_findings_of` reading the store (the live body kept as `cma.flash_findings_compute_of`), `cma.data_quality()` and `cma.data_quality_rows()` reading the store and answering `computed_at`, the first result computed for every active tenant by the migration. Twice: `INSERT 0 1`, then `INSERT 0 0`.
- `db/133_verify_perf.sql`: the previous definition of every rewritten read kept inside the script as `pg_temp.old_*` (from `db/60`, `70`, `72`, `74`, `76`, `78`, `122`) and compared row for row with the new one on the seeds and on the fixture (S1 to S6, E1 to E9 per tenant as `cma_app`, A1 to A5 on a throwaway tenant rolled back); provoke drops the old answer's first row. `0008zr verified | 20 ok, 0 FAIL, 1 skip` (the skip: a tenant without telephony); provoked `0 ok, 20 FAIL, 1 skip`.
- `web/jobs/refresh-data-quality.mjs` (pool 1, `refresh-follow-up.mjs`'s pattern), `docs/scheduler/deploy-data-quality.sh` (`cma-refresh-data-quality`, `cma-refresh-data-quality-minutely`), `web/verify/jobs.mjs` with three more checks (31).
- Documentation (N06a's documentation describes the stacked pair, so CLAUDE.md's `verify:cache` and cache references, PERFORMANCE.md's v2 rows and the web records in `local-records/web` name N06b's work; `docs/architecture/api.md` is edited in N06b): `CLAUDE.md` (a Performance section), `docs/decisions.md` (16 rows of 5 November 2026), `docs/definitions.md` (Refreshed at), `docs/architecture/infrastructure.md` (the connection budget: 92 of 93, one to spare), `docs/OPERATIONS.md` (the job: parts table, pause and resume, what it means when it stops, its log line, the weekly count), `docs/architecture/data-model/0008.md` (the addition), `docs/datamap/catalog.json` (two tables), `docs/audits/2026-10-17-full-audit/PERFORMANCE.md` (section 9, v2 done), `README.md` (the map), `CHANGELOG.md`, this folder.

**N06b, the web.**
- A `loading.tsx` for every page route (46; not for the invitation, log-out and no-access pages, nor the roster print view) rendering the page's frame with placeholder blocks (`RouteSkeleton`, the style guide's card and bars, no spinner); the rail's links prefetch their destinations (Next 16.4.3's `Link` prefetches a dynamic route's loading boundary by default; the `prefetch={false}` of 18 October 2026 removed from the rail and the account link, kept on Log out).
- Welcome streams every block in its own `Suspense` boundary with a card placeholder; its reads start together at the page level.
- The Live board as one read: `data().getLiveBoard()` in one transaction, served as `GET /api/v1/live/board`; `LiveBoardLive` polls it every 10 s while visible, never while hidden, doubling its wait after a failure up to a minute; the rows are computed on the client by `src/lib/live-board.ts`. The message centre polls only while visible and backs off the same way (up to 30 s).
- Copy slices: the client components of Welcome, My day and the Live board take `Pick<Copy, …>` instead of the whole copy object (about 90 kB serialised into every page before).
- The tenant's settings cached per instance for `CMA_CACHE_TTL_MS` (30 s by default, 0 off) keyed by tenant and invalidated by `setTenantSetting` (`src/lib/cache-core.ts`, `cache.ts`; `verify:cache`, 8 checks, provoked).
- Montserrat as a woff2 subset (108 kB in place of the 745 kB TTF), preloaded with `font-display: swap`.
- Reports → Data quality and Flash's data-quality overview show "Refreshed at"; the rows and the overview carry `computedAt` and `refreshedAt`.
- `web/verify/round-trips.json` tightened to the new costs; a `cma-db` meta after Welcome's streamed blocks so `verify:round-trips` counts them (System health's pattern).

## The number: 0008zr, 130 to 133

Confirmed free on `main` at `8643d17` (N05 merged as #227, which took `0008zq`, `128` and `129`) and against the open pull requests at the start of the night: none holds `0008zr` or a `db/` number above `129`. Addition `0008zr`, scripts `130` to `133`; the next free is `134` (night default N06-2: no `134_indexes_concurrently.sql` tonight).

## The fixture, three times prod

| Table | Prod fact, 5 November 2026 | Fixture at multiplier 3 |
|---|---|---|
| `integration_connection` | 19 (12 Juo, 14 Shopify stores, HubSpot, Aircall, the register, Trusted Shops) | 4 + 14 shops + 12 subscriptions in the subscriptions tenant |
| `ingest_event` | about 13,000 (HubSpot) + 1,100 (Aircall) + 3,000 (stores) a day since mid October | 1,080,000 |
| `sync_run` | about 5,000 a day (HubSpot 4,300, Juo 288 each, the others hourly or nightly) | 360,000 |
| `subscription`, `subscription_event` | 7,380 and about 100,000 | 22,140 and 300,000 |
| `device` (+ components) | about 6,800 | 20,400 (+ 40,800) |
| deals, tickets, tasks | 700, 1,200, 2,500 open | 10,500 deals (2,100 open), 10,800 tickets (3,600 open), 22,500 tasks |
| `crm_contact`, `commerce_customer`, `commerce_order` | estimated | 60,000, 120,000, 60,000 |
| `telephony_call`, `crm_call` | estimated from Aircall's 1,100 a day | 198,000, 150,000 |
| `review`, `message` | estimated | 15,000, 900 |

The census verdict before any change: `130_census: 112 rows; 20 table(s) of 10000 rows or more, 5 unused index(es), 63 fk(s) without index`, 0 % dead rows everywhere (a fresh load), `pg_stat_statements` not installed locally.

## Before and after, the database reads (local, at volume, the subscriptions tenant; best of two)

Every read with a cost above 100 ms before, from `131_time_all.sql` and `124_time_flash.sql`. The full outputs are in `local-records/before` and `after`. A poll's budget is 20 ms, an agent page's read 50, a list 300, an overview or report core 500, Sources 150.

| Read | Before | After | Budget | Met |
|---|---|---|---|---|
| Sources (`cma.sources`) | 2,291 ms | 78 ms | 150 | yes |
| a connection's page (the connection) | 2,266 | 80 | 150 | yes |
| System health runs | 1,324 | 281 | 500 | yes |
| Live board poll: missed callbacks | 1,617 | 216 | 20 | no (remainder 6) |
| Live board poll: missed callbacks summary | 1,902 | 150 | 20 | no (remainder 6) |
| Live board poll: inbound today | 107 | 88 | 20 | no (remainder 6) |
| Data quality: the checks | 4,500 | 321 | 500 | yes |
| Flash data quality overview | 4,236 | 410 | 500 | yes |
| Flash data quality first page | 4,164 | 313 | 500 | yes |
| Flash: `124`'s overview data_quality / list | 4,110 / 3,856 | 291 / 272 | 2,500 | yes |
| Flash: `124`'s overview open_tasks / list | 3,824 / 3,898 | 684 / 726 | 1,500 / 800 | yes |
| Flash: `124`'s overview open_tickets / list | 1,724 / 1,757 | 1,739 / 1,880 | 1,500 / 800 | no (remainder 7) |
| Flash: `124`'s overview subscriptions / list | 1,743 / 1,791 | 1,876 / 1,716 | 1,500 / 800 | no (remainder 7) |
| Flash: `124`'s list customers / orders | 844 / 691 | 859 / 824 | 800 | no (remainder 7) |
| Dashboard: intake per day (previous month / 92 days) | 6,503 / not timed | 867 / 1,457 | 500 | no (remainder 5) |
| Intake report (previous month / 92 days) | 6,238 / not timed | 790 / 1,330 | 500 | no (remainder 5) |
| Calls: overview by day / market / line (previous month) | 9,521 / 8,695 / 8,876 | 1,152 / 1,096 / 1,107 | 500 | no (remainder 3) |
| Calls: tag use | 3,987 | 582 | 500 | no (remainder 3) |
| Calls per agent: per person / tags per person | 4,377 / 6,496 | 612 / 921 | 500 | no (remainder 3) |
| Calls: history start | 28 | 265 | 50 | no (Open, below) |
| Speed to lead: rows / summary by day | 1,468 / 1,227 | 1,554 / 1,182 | 300 / 500 | no (remainder 4) |
| Attempts: per deal / per person | 4,292 / 2,704 | 4,440 / 2,808 | 500 | no (remainder 2) |
| Funnel: deal funnel / lost reasons / deals per person | 3,878 / 3,797 / 3,774 | 3,908 / 3,760 / 3,744 | 500 | no (remainder 2) |
| Lead cohorts (previous month / 92 days) | 53,967 / not timed | 52,310 / 116,625 | 500 | no (remainder 1) |
| Follow-up page with callbacks | 343 | 350 | 500 | yes (unchanged) |
| Inbound service (previous month / 92 days) | 229 / not timed | 244 / 414 | 500 | yes (unchanged) |
| Flash landing | 188 | 215 | 500 | yes (unchanged) |

Every agent page read (Welcome's blocks, My day, My hours, My schedule, Messages, My account), the Live board's team read, Team, Roster, the Follow-up page, the email, forms, first orders, cancellations, reviews and maintenance reports and the small polls (identity, messages, team now, work status flags, shifts today) were within budget before and stayed there (0 to 16 ms). The "before" run of `131` was one run of every part under its 240 s budget: it stopped starting reads after lead cohorts, so the forms, maintenance and 92-day rows of the "before" file say `not timed`; the "after" ran as three parts, and part c still stops at the forms rows after lead cohorts' 117 s (remainder 1). The verdicts: before `145 ok, 95 FAIL, 111 skip` (two tenants; the invest tenant skips what no one there may read); after part a `99 ok, 4 FAIL, 45 skip`, part b `43 ok, 26 FAIL, 33 skip`, part c `37 ok, 32 FAIL, 33 skip`. `124`: before `14 ok, 9 FAIL, 1 skip`, after `17 ok, 6 FAIL, 1 skip`.

## Before and after, the web (local, the same database)

**Transactions and statements per request** (`verify:round-trips --observed`, the request log's `tx` and `rt`; before: `main`'s build, after: N06b's).

| Request | Before | After |
|---|---|---|
| `/live/board` (manager, supervisor) | 7 tx, 33 rt per page view and per poll | 2 tx, 16 rt per page view and per poll (`/api/v1/live/board`: the identity read, then the board in one transaction) |
| `/api/v1/telephony/inbound-now` | 2 tx, 12 rt | 2 tx, 10 rt |
| `/configuration/health` | 7 tx, 30 rt | 6 tx, 26 rt |
| `/configuration/exports` | 3 tx, 13 rt | 2 tx, 9 rt |
| `/` Welcome (agent / manager / admin) | 7 / 10 / 11 tx | unchanged (the blocks stream, the reads are the same; remainder 9) |
| every other page and route | | unchanged |

`verify:round-trips` reports one pre-existing problem on `main` and on this branch: `GET /api/v1/reports/flash/rows?overview=orders` makes 3 transactions and 13 statements against a budget of 2 and 9 (the audit record of a file read is its own transaction since addition 0008zo). The budget is raised to what the route does (3, 13) with a note; lowering the cost is remainder 9.

**Time to first byte and payload** (`verify:perf --observed`; 30 requests after 3 warm-ups; `container_factor` 0.5 doubles the targets for the container: the milliseconds are local, the ratios carry).

<<PERF_TABLE>>

## Design

**Measure first, then the plan, not the index.** Every slow read's cause was a plan, none a missing index (night default N06-2). The lessons, now in CLAUDE.md (Performance) and backlog CMA-084's rule: under the application role a function's statements are planned with parameters, so a one-row settings relation joined with `cross join s` ends up inside a per-row nested loop (scalar subqueries `(select s.x from s)` fix it: `cma.calls_of`, `cma.inbound_calls_of`, `cma.intake_per_day_of`, `cma.open_tickets_of`, `cma.open_tasks_of`); `exists()` over a big table is planned as a scan expected to stop at once and reads the whole table when there is no matching row (`min(<leading indexed column>) is not null`: `cma.connection_held_kinds_of`, 2.3 s → 78 ms on Sources); a SQL function inlined into its caller takes the caller's expressions as bounds and loses the index (`alter function … set jit = off` stops the inlining, and a later `create or replace` drops the setting, so `132` repeats it after each recreate); an aggregate in a plpgsql `select into` may run in parallel, a `return query` may not (`cma.system_health_runs`: 1,324 → 281 ms); an ordered aggregate sorts its whole input (the failed runs are aggregated alone). `plan_cache_mode = force_custom_plan` was tried on the functions and made speed to lead and the missed callbacks slower: reverted.

**Data quality stored, not rewritten.** The thirty checks were measured one by one: no one or two of them carry the cost, the union does, so a rewrite could not reach 500 ms at volume (4.5 s live). The store follows 0008s: a refresh job every minute with pool 1 that does nothing while the tenant's result is younger than `data_quality.refresh_minutes`; the result rows are ids, codes, markets and the fix location, never a name; the page shows "Refreshed at". A tenant without a result computes one on demand (the migration computes the first for every active tenant). The rule of night default N06-6 keeps the verifies 41, 73 and 75 unchanged. `cma_read.data_quality_rows()` (the readers' view) keeps computing live, as the data map describes it.

**The Live board.** One transaction reads the team now with the status flags, the memberships, today's shifts, the three settings the board uses, the inbound part (`cma.inbound_now()`, one statement for today, the callbacks with their record urls and the summary) and the follow-up counts. The client keeps the board's rows in state and recomputes them from each poll's answer; the filters survive a poll; "since" and "worked so far" tick from the read's instant (`readAt`). The missed callbacks poll fell from 3.5 s of database time to about 450 ms per poll at volume, still over the 20 ms budget: remainder 6 says how to reach it.

**Skeletons and streaming.** `RouteSkeleton` renders the page's frame (title bar, a card or three, placeholder bars) in the style guide's tokens; the layout verifier's screenshots include it. Welcome's reads start together at the top of the page and each block awaits its own, so the slowest no longer gates the page; the trace meta for `verify:round-trips` is written after the last block settles (verification only, never in prod).

**Caching.** Within a request identity, roles and settings are read once (the request scope); across requests only the tenant's settings (no personal data, keyed by tenant, 30 s, invalidated by its write path). `verify:cache` proves two tenants and two roles never see each other's entry and that a failed read is not kept. Next's own cache facilities key on the URL and the request, not the tenant, and are not used (decision row). Nothing under a per-user permission check is cached.

**Fonts.** The variable TTF (745 kB) is gone; a woff2 subset of the Latin ranges every Workspace language and market uses (108 kB) is preloaded with swap. A glyph outside the subset falls back to the system font (night default N06-7).

## Night defaults (to confirm)

All in `docs/decisions.md` dated 5 November 2026.

| Default | What | Reason |
|---|---|---|
| N06-T | the speed targets (the brief's table) as the targets of record; `124`'s budgets stay for Flash's own verify | the floor is the IT audit's; four colleagues from today |
| N06-1 | the follow-up lead lookback is not added | the stored refresh makes it moot: no page waits for it |
| N06-2 | no index tonight, no `134_indexes_concurrently.sql`; the concurrent pattern is in CLAUDE.md and the runbook | every cause was a plan; the census lists the 63 foreign keys without an index and the 5 unused indexes for prod's statistics |
| N06-3 | no per-table autovacuum setting tonight; a ready Studio block in the runbook, to run only when prod's census shows it | a measured reason, which a fresh local load cannot give |
| N06-4 | `sync_run` keeps every row; the retention is a proposal below | a retention decision is Martin's |
| N06-5 | `131`'s timed part is rolled back, not read only, in three parts | polls must be timed as the web runs them; Studio's 300 s |
| N06-6 | `cma.data_quality_snapshot_of` computes again inside a transaction that stored the result earlier | the earlier verifies stay as they ran in prod |
| N06-7 | Montserrat as a woff2 Latin subset | 640 kB less on the first view |
| N06-8 | polls only while visible, backing off; optimistic writes not built | the writes' feel is the next increment |

## Build choices (to confirm)

- B1: `verify:perf` measures the client JavaScript per route from `.next/server/app/<route>/page_client-reference-manifest.js` and the build manifest's root files (gzip sizes), not from Next's build summary, which the standalone build does not print per route.
- B2: `container_factor` 0.5 in `perf.json` doubles the brief's targets for the container's measurements; in prod the factor is 1 (the log percentiles are the truth).
- B3: `131`'s "agent" set budget is 100 ms for a named agent page's reads together and 500 ms for every other set; a single read's budget is its class's.
- B4: `cma.data_quality_snapshot_of(tenant, recompute)` replaces the one-argument form; the readers' `cma_read` view keeps the live computation.
- B5: the scheduler user (`cma.ensure_scheduler_user`) gains `data_quality.refresh`; the job's log line is `refresh-data-quality` with `tenant_id`, `refreshed`, `reason`, `rows` and `duration_ms`; the run row's counts hold `skipped` (OPERATIONS 8).
- B6: the `x-cma-db` trace and the `cma-db` meta stay verification-only (mock sign-in and `CMA_DB_TRACE=1`); Welcome's trailing meta renders nothing otherwise.
- B7: the Live board's client keeps its own `BoardRow` model (`src/lib/live-board.ts`), a pure function of a poll's answer and the viewer's clock, so `verify:live` keeps covering the grouping and the board can be verified without a browser.
- B8: `round-trips.json` is tightened to the observed cost of every changed page (one more transaction anywhere fails it), and the pre-existing flash rows budget is set to its observed cost with a note.

## Every function and verifier checked

| Script or verifier | Result | Provoked |
|---|---|---|
| `db/132_perf.sql` | `INSERT 0 1 COMMIT`, again `INSERT 0 0 COMMIT` | |
| `db/133_verify_perf.sql` | `0008zr verified: 20 ok, 0 FAIL, 1 skip` | `0 ok, 20 FAIL, 1 skip` |
| `db/130_census.sql` | 112 rows, PASS | 113 FAIL |
| `db/131_time_all.sql` | parts a, b, c as above (the FAILs are the reads over budget, the remainder) | part a: `0 ok, 103 FAIL, 45 skip` |
| `db/124_time_flash.sql` | `17 ok, 6 FAIL, 1 skip` (the FAILs are remainder 7) | |
| 41, 53, 61, 63, 73, 75, 79, 81, 129 after `132` | PASS (`lead_metrics` ok; 16, 20, 19, 21, 24, 13, 19, 15 PASS) | |
| 123 after `132` | `32 ok, 1 FAIL, 4 skip`: the local `uuidv7` shim, as before the night | |
| web build, typecheck, lint | clean; lint 0 errors, 2 pre-existing warnings (`scripts/metrics-doc.mjs`, `verify/follow-up.mjs`) | |
| `verify:copy` | 3,422 keys, en and nl | |
| `verify:configuration` 121, `verify:reports` 215, `verify:flash` 64, `verify:live` 43, `verify:health` 39, `verify:corrections` 44, `verify:roster` 36, `verify:follow-up` 34, `verify:jobs` 31, `verify:import` 29, `verify:invitations` 27, `verify:team` 26, `verify:messages` 24, `verify:csv` 22, `verify:signed-out` 20, `verify:preview` 18, `verify:dashboard` 17, `verify:period` 16, `verify:devices-import` 13, `verify:cache` 8, `verify:boundaries` 397 files, `verify:datamap`, `verify:metrics` | all PASS | `verify:cache` and `verify:jobs` provoked: every check fails |
| `verify:round-trips` | <<ROUND_TRIPS_RESULT>> | |
| `verify:perf` | <<PERF_RESULT>> | every budget 0: every row fails |
| `verify:api` (api mode, local database) | <<API_RESULT>> | <<API_PROVOKED>> |
| `verify:layout`, `verify:theme`, `verify:hints`, `verify:api --sources` (mock mode) | <<BROWSER_RESULT>> | |

The `api` verifier ran against the local server, outside the 07:00 to 22:00 Amsterdam window the dev run keeps; against dev it is the runbook's step 4b.

## The ranked remainder (measured cost times use), with the gain expected

1. **Lead cohorts** (`cma.lead_cohorts`): 52 s for a month, 117 s for 92 days at volume; read by analytics now and then, but a two-minute report is unusable. Not analysed tonight (it was timed, not planned); its shape suggests the cohorts are derived one by one, and one pass over the deals with a window per cohort is the first thing to try. Expected: under 2 s, under 500 ms with the stage history pre-aggregated; to be measured. Its own migration and equivalence check (the `133` pattern).
2. **Attempts and funnel** (`cma.attempts_per_deal`, `attempts_per_person`, `deal_funnel`, `lost_reasons`, `deals_per_person`): 2.7 to 4.4 s each; the funnel page calls three of them (4 transactions, 17 statements) that share one core: compute the core once per page (one function returning the three parts) and the page falls from about 12 s of database time to 4; then the core's own pass (the per-deal attempts are counted per row today). Expected: under 1 s per page.
3. **Calls three times per page** (the IT audit's 5.6-07): the core is 1.1 s at volume after `132` (was 9.5 s) and the page calls it three times (by day, by market, by line): one call that groups three ways (`grouping sets`) halves the page; then the core's own remainder (the tag join) to reach 500 ms.
4. **Speed to lead** rows 1.5 s and summary 1.2 s: not planned tonight; the first-call lookup per deal is the suspect (a lateral on `call_link`'s index per deal), or the 0008s store for the summary. Expected: under 300 ms; to be measured.
5. **Intake per day** 790 to 870 ms (budget 500): the remaining cost after `132` is in the per-day, per-market expansion (the plan after the rewrite shows the day series joined per market); a calendar table per tenant and market, or the 0008s store, should bring it under 200 ms; to be measured.
6. **The Live board's inbound poll** about 450 ms per poll at volume (budget 20): the missed callbacks are derived from `telephony_call` on every poll. Either a partial index on `(tenant_id, started_at desc) where direction = 'inbound' and outcome = 'missed'` created concurrently (the pattern is in CLAUDE.md; measure first in prod with `131` part a), or the 0008s store refreshed every 30 s by the follow-up job. Expected: under 20 ms with the store, under 100 ms with the index.
7. **Flash's lists over 800 ms**: open tickets 1.9 s (the business-hours age computed per row, seen in its plan; a set-based age over the market's hours table should bring it under 500 ms), subscriptions 1.7 s (not planned tonight), customers 859 and orders 824 (within 10 % of the budget; an ordered list sorts its whole input, so an index on each list's sort key is the first thing to try).
8. **Optimistic writes** (the brief's WP3.6): status change, clock in and out, read and acknowledge, a roster cell, a settings toggle. The pattern: `useOptimistic` on the client component with the server action's answer replacing the optimistic state and the error shown in place; `verify:live` and `verify:messages` cover the pure parts. Not built tonight; no measurement needed, a click feels immediate by design.
9. **Welcome's reads** (7, 10 or 11 transactions per view): one function per role's page returning the blocks as JSON would make it 2 transactions; the blocks stream already, so the gain is pool slots, not time to first byte. The flash rows route's third transaction (the audit record of a file read) could join the read's transaction.
10. **Team people** (8 transactions, 34 statements) and **System health** (6, 26): the same batching.

## Proposals with their costs (not done tonight; the Gemini prompt in the runbook covers each)

- **Cloud SQL tier.** `cma-prod-pg` is `db-custom-1-3840` with high availability. The reads that stay over budget are single-threaded plans; a second vCPU helps parallel reads (the dashboards' several cores at once, the per-minute jobs beside the pages) more than any one read. `db-custom-2-7680` would add about one vCPU and 3.75 GB, doubled by the standby: roughly US$95 to 110 a month more at europe-west4's Enterprise prices (to verify in the pricing calculator; not verified tonight). Decide after the prod "before" percentiles: if the agent pages' p95 is within target and only reports are over, keep the tier and finish the remainder instead.
- **CPU always allocated and min-instances for `cma-web`.** A cold start costs the first visitor of the morning 2 to 4 s; one min-instance with CPU always allocated is about US$15 to 20 a month (to verify). Alternative without cost: the first agent's Welcome at 08:00 warms it (the scheduler's `cma-refresh-follow-up` already keeps the database warm). Decide on the log percentiles' first requests of the day.
- **Database flags.** None tonight. `pg_stat_statements`: Cloud SQL for PostgreSQL supports it as a flag (`shared_preload_libraries`) and the extension, and the flag change restarts the instance (a few minutes of downtime on HA, a failover); it would give the census's top-statements block prod's truth. Query Insights (console, no restart, no charge in the standard form) gives per-query latency and tags without a flag: the better first step. Both as the runbook's step 0d; what I could not verify tonight: the current edition's exact flag names and whether Query Insights' standard form is included in the Enterprise edition's price.
- **`sync_run` retention** (night default N06-4): an ops setting `sync_run.retention_days`, 90 by default, applied by the nightly reconcile to succeeded runs older than it, failed runs kept a year. At 5,000 rows a day it saves about 450,000 rows a quarter (about 180 MB with indexes at prod's row size); System health reads 30 days and the Reads panel the last 20 runs, so nothing on a page changes. Decide in the morning; a migration of its own.
- **Unused indexes** (5 locally, from a fresh load): `crm_task_contact_idx`, `email_message_account_idx`, `follow_up_item_market_idx`, `review_order_idx`, `time_event_import_batch_idx`. Prod's statistics decide (the census in prod, step 0c); none is dropped tonight.
- **Cloud CDN.** Not proposed: Google documents that Cloud CDN and IAP cannot be enabled on the same backend service, and `/_next/static` already carries Next's immutable cache header (`public, max-age=31536000, immutable`), so the browser caches the hashed assets across visits without a CDN.

## Not verified locally

- Prod's figures: every millisecond here is the container's; the runbook's step 0 takes the prod "before" (the log percentiles, the census and `131` in Studio) and step 5 the "after".
- PostgreSQL 18's planner: the plans were read on 16 with `auto_explain`; the fixes are plan-shape fixes (scalar subqueries, `min()` over an index, no inlining) that hold on 18, but `131` in prod is the proof.
- Whether `131`'s parts fit Studio's 300 s at prod's volume: locally at three times prod part b ran about 3 minutes and part c about 5 (lead cohorts alone 117 s), so the runbook runs them from the Terminal with psql, where no 300 s applies, and keeps Studio for the census.
- Compression behind IAP (a header check in the runbook, step 4c) and the real first-load JavaScript in the browser (the verifier reads the manifests).
- The job's deploy (`deploy-data-quality.sh` follows `deploy-follow-up.sh` line for line; the service account's permission is the same).
- The font subset against every market's names and labels (the Latin blocks cover the Nordic, German, Spanish, French and Dutch characters; a Polish or Turkish name would fall back).

## Open

- **"Calls: history start" 28 → 265 ms.** The read `cma.calls_history_start` was within budget before `132` and over it after, in both parts b and c. `132` does not touch it; the likely cause is the `jit = off` setting on `cma.calls_of`, which the history read may inline. Not understood tonight: re-time it in the morning's step 2 (dev) and, if it holds, `alter function cma.calls_history_start set jit = off` is the one-line fix for a follow-up.
- The `datamap` verifier passes on the catalog with the two new tables but compares against `schema.json` from before `132`; Martin refreshes it from dev after step 2.
