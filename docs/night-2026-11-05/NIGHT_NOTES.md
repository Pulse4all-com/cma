# Night notes, N05: every source live on Sources, Juo for every store (addition 0008zq)

Night of 4 to 5 November 2026, brief N05. Written by Claude Code while Martin was away. Everything was built and verified in the session's own container: PostgreSQL 16.15 with a local `uuidv7()` shim (Cloud SQL runs 18, which has it), `db/00` to `127` replayed in number order with the dev seeds rerun after every migration, then `128` and `129`, Node 22.23.4, the standalone build of `web/` in mock mode and in api mode against that database, the ingest's verifiers against the fake Juo, HubSpot and Airtable. Nothing touched dev, prod, Google Cloud or a vendor; `records/` is untouched. The outputs are in `local-records/` (its `README.md` lists them); what Martin runs is in `MORNING_RUNBOOK.md`; the note for the four colleagues is `TEAM_NOTE.md`.

## What changed

- `db/128_sources_last_read.sql` (addition 0008zq): `cma.sources()` dropped and created again with 52's 22 columns and then `last_read_at`, `last_read_job`, `reads_24h`, `reads_failed_24h`, `last_read_error`, read from the connection's own `cma.sync_run` rows; same permission check, same grants, the version recorded. No table, view or column changes.
- `db/129_verify_sources_last_read.sql`: S1 and A1 to A6, 9 checks (14 after the follow-up below: S2 and A7 for `cma.source_reads`), throwaway tenants rolled back, runs in dev and prod.
- `web/`: the type and both data layers carry the five fields; Configuration → Sources shows a **Last read** column after Last event (the read's time, the job's label and the reads of 24 hours under it, a warning badge with the failed reads and the latest code in its title; a dash under Last event for a connection with reads and no events); header hints on both columns; copy in en and nl (8 keys); `sources.ts` has the three pure helpers (`readState`, `jobLabel`, `readsCaption`), `verify/configuration.mjs` checks them (119), `verify/api.mjs` knows the five fields and accepts every source kind on the list (it accepted four of the seven, a pre-existing gap: the mock's reviews connection failed that check on `main` too).
- `ingest/`: `ingest-backfill --adapter <name>` (`jobs/backfill.mjs`, `src/jobs/backfill.mjs`); `verify/juo-flow.mjs` section H (8 checks, 35 in all) and `verify/juo-fake.mjs`'s `failTenant` switch (one store answers 503); the Jobs and Verifiers rows of `docs/ingest/README.md`.
- `docs/ingest/PROD_RUNBOOK.md`: 15.10 (the 11 live stores with Juo in one sitting; the follow-up below took NO out and made (a) a check), 15.11 (every store's customers from the store's start), 15.12 (Flash per market); the opening overview, phase 15's header, the 13.9 line on the review channels' markets.
- Documentation: `docs/decisions.md` (19 rows of 4 November 2026), `docs/definitions.md` (Last read; the Change line's pointer), `docs/open-decisions.md` (the three Juo and customers items point at the morning runbook; the retention line), `docs/OPERATIONS.md` (section 2's five-minute check reads the Sources page; section 7's Juo row lists the secrets, twelve with a connection plus CH's after the follow-up, and one rotation day), `README.md` (Architecture's Juo sentence; the documentation map), `CHANGELOG.md`, `docs/architecture/api.md`, `docs/architecture/data-model/0008.md`, `docs/product/features.md`.
- `docs/datamap/catalog.json` and `schema.json` are unchanged: no table, view or column changes.

## The number: 0008zq, 128 and 129, as briefed

Confirmed free on `main` at `cf35a8a` (the branch base): `db/` holds up to `127`, and `0008zq` appears in no file. No collision this time.

## Design

**Reads, not events.** `cma.sources()` (0008e, 52) derived everything it said about a connection's activity from `cma.ingest_event`: a webhook source's events. A polled source (Trusted Shops, Juo, the asset register) writes one `cma.sync_run` row per run and never an event, so prod's Sources page showed `0` and `Never` for connections read every five minutes. Reports → Flash already read the right thing per source kind (`cma.flash_sources_of`, 122). The addition gives the page the same per connection: one lateral row for the latest succeeded run (its finish and its job) and three counts over the last 24 hours (runs started, failed runs, the latest failed run's code). A running run counts among the reads and never as the last read; a failed run never moves the last read. The columns come last, so `main`'s web, which maps `select * from cma.sources()` by column name, runs unchanged on the migrated database, and the migration goes before the merge. System health keeps its own per-job rows (78), Flash its per-kind read; nothing else reads the function.

**The screen (N8).** One column, Last read, after Last event: the read's weekday, date and time in the viewer's zone (the `fmtWhen` of the page), under it the job's label in System health's words (`Subscriptions poll`, `Nightly reconcile`, `Backfill`, ...) and `n reads in 24 hours`; a warning badge `n failed` with the latest code in its `title` (a code, never a value: `rate_limited`, `http_503`); a dash with the caption `No read yet` when the connection has runs but no succeeded one, a bare dash when it has none. Under Last event, a connection with reads and no events shows a dash; `Never` stays for a connection with neither (Shopify CH before its first reconcile). Both headers get a hint that says which systems send events and which are read on a schedule. The row carries `data-read-state` (`none`, `ok`, `attention`) for the verifiers.

**`--adapter` (N9, FIND-01).** `--connection <id>` and `--adapter <name>` exclude each other (usage error, exit 2; so is neither). The walk takes every served connection of the adapter (every tenant the Ingest user serves, `servedConnections()` filtered), sorted by id, and gives each exactly what `--connection` gives: its own `sync_run` rows, its own budget (and daily floor), its own `--object` list in order; a pause stops that connection's later objects (`skipped_after_pause`); a connection whose run throws outside the run (no `intake.start_date`, a dry run the source refuses) is counted failed with its code and its later objects read `skipped_after_failure`; a connection the adapter skips (`skipReason`, Juo's `key_not_set`) is logged `backfill: connection skipped` and counted, never a usage error; the checks an adapter applies to every connection alike (an object it has not, `--from` on an object read whole, a dry run it has not, two objects with `--dry-run`) are usage errors before any connection is touched. The finished line carries `adapter`, `connections`, `served`, `skipped`, `failed` and `results` (one row per connection and object: id, object, counts, error); the process exits 1 when any connection failed. One job, one lock as before (none: the backfill runs by hand), one pool of 2: the walk is sequential, P1 holds (work 1).

**Flash per market (15.12).** Verified on a local database with two stores in one throwaway tenant, GB with three subscriptions and NL with none: `cma.flash_sources_of` says subscriptions set up (a source is set up for the tenant, not per market), `cma.flash_page` lists both markets, `cma.flash_page('NL')` says every overview set up, and `cma.flash_overview('subscriptions', 'NL')` answers `set_up` true with zero totals and no rows (`local-records/db/flash-two-stores-one-empty.txt`). Nothing to fix: a market with a store and no subscriptions shows zeros, not "not set up".

## Night defaults (to confirm)

Each is a Decision log row of 4 November 2026, "Night default (to confirm)".

| | Night default | As built |
|---|---|---|
| N1 | CH is excluded until the store is live (Martin, 4 November 2026; a given, not a default) | 15.10's table has the 11 live handles with Juo (NO has no Juo yet: the follow-up below); CH joins with the same blocks, one handle, once it sells; the Decision log rows "Juo for the 11 live stores with Juo" and "The NO store has no Juo yet" |
| N2 | Events from `2024-01-01` for every store, as GB | 15.10 (f): one `--adapter juo --object subscription_event --from 2024-01-01` |
| N3 | The subscriptions dry run kept for every store, the events dry run skipped for the non-pilot stores | 15.10 (e): one `--adapter juo --object subscription --dry-run`, twelve lines read as one `gcloud logging read` |
| N4 | `ingest-poll-subscriptions` paused during the backfills, resumed after | 15.10 (d) and (h) |
| N5 | Store customers from each store's start, orders unchanged | 15.11: `--adapter shopify --object commerce_customer --from 2000-01-01`; orders stay in the 60-day window |
| N6 | Connection names `Juo <CC>`, account id `<handle>.myshopify.com`, secret `ingest-juo-<handle>-key` | 15.10's table and (c)'s `values` list |
| N7 | All the Juo keys rotate on one day every 180 days | OPERATIONS 7's row (twelve with a connection, CH's without one) |
| N8 | The Sources layout and wording | Design, The screen; the copy keys in `configSources` |
| N9 | `--adapter` semantics: id order, continue on failure, exit 1 if any failed | Design, `--adapter` |

Build choices of the night (to confirm):

| | Choice | Why |
|---|---|---|
| B1 | `129` writes its events and runs straight into `cma.ingest_event` and `cma.sync_run` as the owner, with chosen instants, in throwaway tenants rolled back | The read is a pure derivation of those rows; the writers are proven by 33 and 119; the verdict never depends on the clock, and the script runs in prod |
| B2 | The mock's polled sources (reviews, and assets or subscriptions where the fixture has them) carry runs and no events, the reviews one with a failed read (`rate_limited`) | The browser verifiers and the screenshot see every state of the column |
| B3 | PROD_RUNBOOK 15.8's email pattern already reads `\.` on `main` (one backslash before the dot); 15.10 (g) keeps that form and says so; 15.8 is not edited | The brief asked for the fix; the file holds it since the pilot's record (`records/0008zl-prod-2026-10-29`) |
| B4 | `verify/api.mjs` accepts every source kind of the data model on the Sources list (it listed four of seven) | The check failed in mock mode on `main` for the fixture's reviews connection; dev holds a reviews and a subscriptions connection too |
| B5 | A connection's failure inside the `--adapter` walk stops that connection's later objects (`skipped_after_failure`), not the walk | The same connection's next object would fail the same way (its tenant, its context); the other connections are unaffected |
| B6 | The Last read column's job label reuses System health's `configHealth.job_*` copy; a job without a label shows its own word | One word per job on both pages; a new job never breaks the page |

## Every function and verifier checked

| What | Verdict | Proven by |
|---|---|---|
| `cma.sources()` | recreated; the 22 columns of 52 unchanged in their order, five appended | `129` S1 (the column list by name and type), A1 to A6; `53` B2 still PASS (16); `79` 13 PASS |
| `cma.system_health_runs()` (78) | unchanged | `79`; the page's code untouched |
| `cma.flash_sources_of` (122), `cma.flash_page`, `cma.flash_document_of` | unchanged; a market without subscriptions answers zeros | the local two-store test; `123` 32 ok (its block B fails locally on `uuidv7()` in its own `execute`, the shim's schema; `main` alike) |
| `cma.subscription_store_connection_of` (118) | unchanged; resolves each of the 12 handles when the store rows exist | 15.10 (c)'s read-back, executed locally for two fake handles |
| `web/src/lib/data/postgres.ts` `toSource` | the five columns mapped | typecheck; `verify/api.mjs` in api mode (324 PASS: the sources checks read the five fields) |
| `web/src/lib/data/mock.ts` `mockSource` | the five fields with polled and webhook shapes | `verify/api.mjs --sources` in mock mode (33), the screenshot |
| `SourcesList.tsx` | the column, the hints, the badge, the dash rule | the screenshot (`local-records/web/screenshots`), `verify/theme.mjs` (1 problem, Attempts by pipeline, as on `main`) and `verify/layout.mjs` (10 problems, all Funnel, as on `main`; the Sources page passes) |
| `src/lib/sources.ts` helpers | pure | `verify/configuration.mjs` 119 PASS, provoked |
| `src/lib/health.ts` `connectionState` | unchanged (System health keeps its own rule on events and runs) | `verify/health.mjs` 39 |
| `ingest/src/jobs/backfill.mjs` | `--connection` exactly as before (the same function body, now `backfillConnection`); `--adapter` new | `jobs-flow.mjs` 99 PASS and provoked (the HubSpot backfill's resume, `--again`, the lists); `juo-flow.mjs` 35 PASS and provoked; `assets-flow.mjs` 39 PASS and provoked |
| `ingest/jobs/backfill.mjs` | the two arguments exclusive, one required | `juo-flow.mjs` H6 and H7 (the process's exit codes 1 and 2) |
| `docs/ingest/deploy.sh` | unchanged (eleven `--secret` flags are its normal form) | `verify/deploy-script.mjs` in `npm test` |

## Proven locally, and what was not

Proven (outputs in `local-records/`): the replay of `db/00` to `127` with the seeds; `128` twice (`INSERT 0 1`, then `INSERT 0 0`); `129` 9 PASS, provoked 0 PASS and 9 FAIL with four blocks failed; after `128`: seed `02` clean, `53` 16 PASS, `79` 13 PASS, `105` 27 PASS, `115` 14 ok, `119` 23 PASS, `123` 32 ok with its one local-only block, `127` 31 PASS; the two-store Flash test; 15.10 (c), (g), (h) and 15.12's Studio blocks executed against the seed tenant and against the Juo flow verifier's tenant (two fake stores with 230 subscriptions each; no error, the figures those fixtures give); `ingest`: `npm test` (20 verifiers), lint clean, `juo-flow.mjs` 35 PASS and 35 provoked, `jobs-flow.mjs` 99 and 99, `assets-flow.mjs` 39 and 39, each with `CMA_DB_POOL_MAX=2` and P1 green; `web`: build, typecheck (0 errors), lint (0 errors, `main`'s two warnings), every pure verifier (copy 3405 keys, configuration 119, corrections 44, csv 22, dashboard 17, live 43, team 26, roster 36, messages 24, import 29, devices-import 13, datamap PASS, signed-out 20, invitations 27, preview 18, follow-up 34, reports 215, flash 64, period 16, health 39, boundaries 345 files, jobs 28, metrics ok), `verify/api.mjs` in mock mode (`--sources` 33 and `--reports` 27, provoked) and in api mode against this database with the reports fixture (`ALL 324 PASS`, provoked all 324 failed); the grep of the change for a store handle, a secret name or an id outside runbooks and docs (none: the verifiers' handles are their own `juo-<run>-…` fixtures).

Not proven here: PostgreSQL 18 (dev and prod run it; the scripts use nothing version-specific); the eleven secrets' versions and accessors (15.10 (a), (b)); Juo's answers for the other stores (15.10 (e): the GB pilot confirmed the paths; a store's `http_<status>` is reported, the others go on); the stores' customer counts and the HubSpot search cost of 15.11 (paced and paused by the daily floor, the same command continues); the Flash figures per market in prod (15.12); `main`'s web on the migrated database (by reading: its mapper names its columns; `local-records/README.md`); the IAP sign-in of the four invitations (step 8). Juo's webhook topics were not re-read from juo.io in this container (no vendor reach): the brief's reading of 4 November 2026 is recorded as Martin's, in the Decision log row.

## Found on the way (not caused by this change)

- `verify/api.mjs`'s Sources check listed four source kinds of seven, so it failed in mock mode on `main` for the fixture's reviews connection (B4, fixed here).
- PROD_RUNBOOK 15.8's email pattern reads `\.` already (B3); nothing to fix.
- `123_verify_flash.sql`'s block B fails locally with `function uuidv7() does not exist`: its dynamic SQL runs in a search path without the shim's schema. PostgreSQL 16 only; dev and prod (18) are not affected. `105` and `119` need the login to hold `cma_readonly` (they `set role` to it), as Martin's does.
- Playwright: `web/`'s `playwright` package (1.58, browser build 1248) is newer than the container's pre-installed browser (1243); the browser verifiers and the screenshot run after pointing the newer folder at the installed one (a container matter, not the repository's).

## Risks

- **Secrets and the walk.** A store whose key was pasted at the wrong prompt fails `key_rejected` in the dry run; the others go on, and only that store is redone. A store without a secret is skipped and never stops the rest.
- **Time.** 15.10 (f) and 15.11 are unattended but long; the nightly reconcile at 03:30 reads every store too, so (c) to (f) in one sitting away from it. Nothing is lost if the tab drops: a job keeps running server-side and the same command continues every store from its cursor.
- **The daily floor.** 15.11's HubSpot searches may pause a store at the floor (`daily_floor`); the finished line says so; the same command the next day continues. Flash's Active customers are complete only after the whole walk.
- **Main's web between the migration and the merge.** Nothing changes on screen: the new columns are ignored. A minute or two, then the merge.
- **Rollback.** The migration is a superset; the connections switch off one by one; the schedule pauses; the image rolls back as OPERATIONS 3.3.

## Next steps (out of scope, nothing built)

- A Last read column on System health's Sources table (the page keeps its own per-job table today).
- A Flash change line that judges a period's completeness per connection, not per kind (the known limit of 4 November 2026).
- Shopify's `read_all_orders` or a one-time order import for the orders before 1 October 2026.
- CH's Juo once the store is live: 15.10 with one handle.

## Follow-up of 4 November 2026, the evening (same pull request)

Martin's corrections and one addition, built after the pull request opened; verified as the night was (`local-records/README.md`, the follow-up section).

1. **Store facts.** The NO store (`pulse4all-no`) has no Juo yet: no key, no secret, no connection, no `--secret` flag; Juo NO joins the day Juo is installed there, with 15.10's blocks for one handle. CH stays out, and its secret `ingest-juo-pulse4all-ch-key` exists since 4 November 2026 without a connection or an accessor. Eleven stores join GB: twelve subscriptions connections, not thirteen. Corrected in PROD_RUNBOOK 15.10 to 15.12 (the table, the loops, the deploy line, the Studio `values`, every count), `MORNING_RUNBOOK.md` (steps 5 and 7, the elapsed table), OPERATIONS 7, the Decision log rows that count the stores, Open decisions, README's Architecture row, this file. One new Decision log row: "The NO store has no Juo yet".
2. **The eleven secrets exist** since the evening of 4 November 2026 (one enabled version each, the earlier version of nine of them disabled, no accessor yet). 15.10 (a) is a check now (the secrets list and the versions list, with the expected output); the `put_secret` block stays for a store that joins later, one handle.
3. **Reads on the connection's page.** `cma.source_reads(connection_id)` in the same `128` (it had not run anywhere): the connection's last 20 `cma.sync_run` rows newest first (`started_at desc, id desc`; `run_id`, `job`, `stream`, `started_at`, `finished_at`, `status`, `counts`, `error`), `tenant.configure`, the tenant's own connection only, grants as `cma.sources()`. `129` gains S2 (columns, volatility, grants) and A7 (the newest 20 of 25 runs newest first, the counts, stream, finish and code carried, another tenant's and an unknown id answer no rows, a manager refused): 14 checks. The connection page (`SourceConfig.tsx`) shows a **Reads** panel after the Connection card, in System health's row style: the job's label with the stream under it, started, duration (`n s`, `n min`), a badge Succeeded, Failed or Running with the code beside it and in its title, the counts above 0; "No read yet" for a connection never read. `GET /api/v1/configuration/sources/{id}` carries `reads` (no new route: the page's read already carries the connection); `SourceRead` in `types.ts`, the Postgres mapping, the mock (the polled sources 20 polls with one failed, the webhook sources two nightly reconciles, the automation none), 15 copy keys en and nl, the pure helpers `readDurationSeconds` and `readCountsText` (`verify/configuration.mjs`, 121), `verify/api.mjs` (the reads' shape, order and cap on the connection; a code never a value), `docs/architecture/api.md`, `features.md`, data model 0008, the Last read definition (Used by, As built today).

Build choice of the follow-up (to confirm), B7: the reads ride on the connection's existing read (`SourceDetail.reads`, `GET /sources/{id}`) rather than a route of their own: one read for the page, one permission check, no second round trip, and the API verifier's existing connection checks cover it. Found on the way: `53_verify_sources_configuration.sql`'s A4 ("connections without the kind their rows imply") fails on the local database once the Juo flow verifier's throwaway connections and the reports fixture are in it (eight connections of those fixtures); it passed right after `128` on the clean replay (16 PASS) and reads every connection of the database, so it is the local fixtures, not the migration; dev and prod hold connections with their kinds.
