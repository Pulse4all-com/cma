# Local records, night of 4 to 5 November 2026 (N05)

These are the outputs of the night's local runs in Claude Code's container: PostgreSQL 16.15 from the distribution (with a local `uuidv7()` shim in `public`, since PostgreSQL 16 has none; Cloud SQL's PostgreSQL 18 has it), Node 22.23.4, the standalone build of `web/` in mock mode and in api mode against the local database, the ingest's verifiers against the fake Juo, HubSpot and Airtable of `ingest/verify/`. They are not release records; `records/` stays Martin's. No value here comes from dev, prod or Google Cloud: every id, name and count is the dev seed's, a verify script's, a fake source's or the mock's invented data; the fixtures' addresses and invented names are replaced by `<address>` and `<name>` in the copied outputs. Paths of the container's scratch folder read `<scratch>`, the repository's `<repo>`.

The database: `db/00` to `127` replayed in number order, the seeds `02` and `03` rerun after every migration, `06` and `24` in their place, the verifies with their known expected errors; then `128` and `129` by hand, so `128`'s first run shows `INSERT 0 1`.

## `db/`

| File | What |
|---|---|
| `replay-00-to-127.txt` | The replay's log: one line per script (`04`'s and `07`'s expected errors, `27`'s pre-existing A4, as N04 found them). |
| `128_sources_last_read-first-run.txt`, `-rerun.txt` | Addition 0008zq: the first run ends `INSERT 0 1`, `COMMIT`, `RESET`; the rerun `INSERT 0 0`. |
| `129_verify_sources_last_read.txt` | 9 checks, `PASS | 9 PASS, 0 FAIL`. |
| `129_verify_sources_last_read-provoked.txt` | Provoked: every one of the four blocks raises `FAIL`, `PROVOKED, NOT A PASS | 0 PASS, 9 FAIL`. |
| `02_seed_pulse4all-after-128.txt` | The Pulse4all seed after `128`: no error, no notice. |
| `<nn>_…-after-128.txt` | The earlier verifies after `128`: `53` 16 PASS (its B2 reads `cma.sources()` by column name), `79` 13 PASS, `105` 27 PASS, `115` 14 ok, `119` 23 PASS, `127` 31 PASS; `123` 32 ok, 1 FAIL, 4 skip: its block B fails with `function uuidv7() does not exist`, the shim's schema is not in the search path of its dynamic SQL (PostgreSQL 16 only; the same before `128` in the replay). `105` and `119` `set role cma_readonly`, so the local login got that membership first (Martin's has it). |
| `flash-two-stores-one-empty.sql`, `.txt` | The local check of 15.12: a throwaway tenant with two stores, GB with three subscriptions and NL with none, both with a Juo connection (15.10 (c)'s block, two handles) and a succeeded poll run; `cma.flash_sources_of` says subscriptions set up, `cma.flash_page` lists both markets and every overview set up for `NL`, `cma.flash_overview('subscriptions', 'NL')` answers `set_up` true with zero totals and no rows; the rows per market and store. Rolled back at the end. |
| `runbook-15-blocks.sql`, `runbook-15-blocks-pulse4all-subscriptions.txt`, `runbook-15-blocks-juo-….txt` | 15.10 (g) and (h) and 15.12's Studio blocks, as written, executed against the seed tenant (no Juo rows: empty results, no error) and against one of the Juo flow verifier's tenants (two fake stores of 230 subscriptions: the runs, the statuses, the events per type, the payment states, the two email counts 0, the coverage per store and market). |

## `web/`

The final build of this branch (`build.txt`, exit 0), then every check on it:

| File | What |
|---|---|
| `npm-ci.txt`, `typecheck.txt`, `lint.txt` | Exit 0; lint's two warnings are in `scripts/metrics-doc.mjs` and `verify/follow-up.mjs`, unchanged from `main`. |
| `verify-<name>.txt` | The pure verifiers CLAUDE.md names, each with its exit code: copy 3405 keys (en and nl; 3397 on `main` plus the eight of `configSources`), configuration 119 (116 plus the three of the read helpers), corrections 44, csv 22, dashboard 17, live 43, team 26, roster 36, messages 24, import 29, devices-import 13, datamap PASS (102 tables, 158 views, unchanged), signed-out 20, invitations 27, preview 18, follow-up 34, reports 215, flash 64, period 16, health 39, boundaries 345 files, jobs 28, metrics ok. |
| `reports-fixture-load.txt` | `web/verify/reports-fixture.sql` loaded into the local database (local only). |
| `verify-api-local.txt`, `-provoked.txt` | `verify/api.mjs` against this build in api mode on the local database after `128`: `ALL 324 PASS`; provoked `ALL 324 PROVOKED CHECKS FAILED, as they must`. The sources checks read the five new fields and accept every source kind (B4). |
| `verify-api-mock-sources.txt`, `-provoked.txt`, `verify-api-mock-reports.txt` | The same verifier's `--sources` (33) and `--reports` (27) against the build in mock mode; provoked all failed. |
| `verify-theme.txt` | Against the mock build: `FAIL (1 problems)`, Attempts by pipeline with an outcome filter has no table; the same one problem as on `main` (N04's note). The Sources page and the CRM connection's page pass. |
| `verify-layout.txt` | Against the mock build: `FAIL (10 problems)`, all on Reports → Funnel (its by-market and by-source tables without a scroll container, five identities), as on `main` (N04 reported them). The Sources page passes at 1280 and 1920 px with its keycap. |
| `screenshots/sources-mock-1280.png` | Configuration → Sources in mock mode at 1280 px: the Last read column with the nightly reconcile under the webhook sources, a dash for the automation connection, and the reviews connection with a dash under Last event, its read, the `1 failed` badge and `Reviews poll · 24 reads in 24 hours`. |

The browser verifiers and the screenshot needed the container's pre-installed Chromium (build 1243) under the folder name `web/`'s newer Playwright (1.58) looks for (1248): a symbolic link in `/opt/pw-browsers`, a container matter.

## `ingest/`

| File | What |
|---|---|
| `npm-ci.txt`, `npm-test.txt`, `lint.txt` | Exit 0; `npm test`'s 20 pure verifiers each `ALL n PASS`; eslint clean. |
| `juo-flow.txt`, `juo-flow-provoked.txt` | `verify/juo-flow.mjs` against the local database and the fake Juo with `CMA_DB_POOL_MAX=2`: `ALL 35 PASS` (27 as before, section H's eight for `--adapter juo`), P1 `backfill 12 runs, peak 1, work 1`; provoked all 35 failed. |
| `jobs-flow.txt`, `jobs-flow-provoked.txt` | `verify/jobs-flow.mjs`: `ALL 99 PASS` (the HubSpot backfill with `--connection` as before: the interruption, the resume, `--again`, the object list); provoked all 99 failed. |
| `assets-flow.txt`, `assets-flow-provoked.txt` | `verify/assets-flow.mjs`: `ALL 39 PASS`, unchanged; provoked all 39 failed. |

Not recorded as a file: the grep of the change for a store handle, a secret name or an id outside runbooks and docs (none: the verifiers' handles are their own `juo-<run>-…` fixtures; `db/129`'s connections are `verify-…`).

## The follow-up of 4 November 2026, the evening (`*-b.txt`)

The same container and database after the follow-up (NO taken out of the runbook, 15.10 (a) a check, `cma.source_reads` and the Reads panel; `../NIGHT_NOTES.md`, the follow-up section). The `0008zq` row was removed from `cma.schema_migration` locally before `128` ran again, so its first run shows `INSERT 0 1` as in dev and prod; the function definitions are replaced either way.

| File | What |
|---|---|
| `db/128_sources_last_read-first-run-b.txt`, `-rerun-b.txt` | `INSERT 0 1 COMMIT RESET`, then `INSERT 0 0 COMMIT RESET`; `cma.source_reads(uuid)` created. |
| `db/129_verify_sources_last_read-b.txt` | 14 checks (S1, S2, A1 to A7), `PASS | 14 PASS, 0 FAIL`. |
| `db/129_verify_sources_last_read-provoked-b.txt` | Provoked: six blocks raise `FAIL`, `PROVOKED, NOT A PASS | 0 PASS, 14 FAIL`. |
| `db/79_verify_system_health-after-128-b.txt` | 13 PASS, unchanged. |
| `db/53_verify_sources_configuration-after-128-b.txt` | `15 PASS, 1 FAIL`: its A4 ("8 connection(s) without the kind their rows imply") reads every connection of the database, and the local one now holds the Juo flow verifier's throwaway connections and the reports fixture's; it passed 16 PASS right after `128` on the clean replay (`53_verify_sources_configuration-after-128.txt`), so it is the local fixtures, not the migration. Dev and prod hold connections with their kinds. |
| `web/typecheck-b.txt`, `lint-b.txt`, `build-b.txt` | Exit 0; lint's two warnings as before. |
| `web/verify-<name>-b.txt` | The pure verifiers again: copy 3419 keys (15 new, the Reads panel's), configuration 121 (two helper checks more), the rest as before. |
| `web/verify-api-local-b.txt`, `-provoked-b.txt` | `verify/api.mjs` in api mode on the local database: `ALL 325 PASS` (the connection's reads: at most 20, newest first, each row's keys, a status of the three, counts as numbers, a code never a value); provoked all 325 failed. |
| `web/verify-api-mock-sources-b.txt`, `-provoked-b.txt` | `--sources` against the mock build: 34 PASS; provoked all failed. |
| `web/verify-theme-b.txt`, `verify-layout-b.txt` | Against the rebuilt mock build: theme `FAIL (1 problems)` and layout `FAIL (10 problems)`, the same pre-existing ones as above (Attempts by pipeline; Funnel's tables); the Sources list and the connection page pass. Two edits after these runs, the running badge's tone (`info`, as System health) and the mock run ids' shape, were covered by the typecheck, lint and the pure verifiers run again, not by a second browser run. |
| `web/screenshots/source-reads-mock-1280.png` | The reviews connection's page in mock mode: the Reads panel with twenty `Reviews poll` runs, newest first, the duration, a `Failed` badge with `rate_limited` beside it, the counts; the automation connection's page says "No read yet". |

## The follow-up sent again on 4 November 2026, the evening (`*-c.txt`)

Martin's brief of the follow-up, sent a second time the same evening, counts **twelve** secrets stored that evening (the eleven stores' and CH's), where the first pass counted eleven: 15.10 (a) now checks twelve (CH's in the versions list too, `name.basename()` so the names print as Expected says them), the morning runbook's steps 4a, 5, 6 and 7 and the Decision log row follow; the mock's polled connection takes its poll's job and stream from its kind. Run in a new container: PostgreSQL 16.15 with the same `uuidv7()` shim, Node 22.23.4, a fresh database replayed from `db/00`, between 21:00 and 21:30 UTC (22:00 to 22:30 in Amsterdam, after the workday window closed). The local logins: `cma_local` (as Martin's: `cma_owner` and `cma_app` with `set` and no `inherit`, `cma_readonly`) for the scripts, `cma_web_local` (`cma_app`) for the web in api mode. The `0008zq` row was not in the fresh database, so `128`'s first run shows `INSERT 0 1`.

| File | What |
|---|---|
| `db/replay-00-to-127-c.txt` | The replay to `127`, every migration exit 0. Against the night's log: `02`'s expected `cma.setting` error is listed after `01` too (this replay reruns the seeds after `01`), and the error lines of four verifies before `128` differ in number, `04` 3 (its refusals: row-level security on `app_user`, `audit_log`, schema `cma`), `41`, `47` and `51` 0 (the night 2, 1, 1); none of them reads what `0008zq` changes. |
| `db/128_sources_last_read-first-run-c.txt`, `-rerun-c.txt` | `INSERT 0 1 COMMIT RESET`, then `INSERT 0 0 COMMIT RESET`, exit 0 both. |
| `db/129_verify_sources_last_read-c.txt` | `PASS | 14 PASS, 0 FAIL`, exit 0. |
| `db/129_verify_sources_last_read-provoked-c.txt` | Six blocks raise `FAIL`, `PROVOKED, NOT A PASS | 0 PASS, 14 FAIL`. |
| `db/53_verify_sources_configuration-after-128-c.txt`, `db/79_verify_system_health-after-128-c.txt` | `16 PASS, 0 FAIL` and `13 PASS, 0 FAIL` (run before the reports fixture was loaded). |
| `web/npm-ci-c.txt`, `build-c.txt`, `typecheck-c.txt`, `lint-c.txt` | Exit 0; lint's two warnings as on `main`. |
| `web/verify-<name>-c.txt` | The 23 pure verifiers, each exit 0 with the night's counts: copy 3419 keys, configuration 121, corrections 44, csv 22, dashboard 17, live 43, team 26, roster 36, messages 24, import 29, devices-import 13, datamap PASS (102 tables, 158 views), signed-out 20, invitations 27, preview 18, follow-up 34, reports 215, flash 64, period 16, health 39, boundaries 345 files, jobs 28, metrics ok. |
| `web/reports-fixture-load-c.txt` | The reports fixture, loaded twice: the first load (not kept) wrote it under its own `set role cma_owner` (`fixture written`) while its guard block refused for want of `cma.local_fixture`; this second load, with the setting, says `fixture already present` (its guard block reads `cma.app_user` without the role, which `cma_local` does not inherit). |
| `web/verify-api-local-c.txt`, `-provoked-c.txt` | `verify/api.mjs` in api mode on the local database: `1 of 325 FAILED`, `status since moves to the change`; provoked `2 of 325 checks did not fail`, the same check and `the agent's own entry equals the own-day read`. Both are the clock-in window: the run started at 22:06 in Amsterdam, after the window closed at 22:00 (the verifier prints `the window closed at 2026-11-04T21:00:00.000Z`; `docs/RUNBOOK.md` runs `verify:api` inside 07:00 to 22:00), so the agent's day has no running status; the night's run, inside the window, was `ALL 325 PASS`. Two runs gave the same result. Every sources check passes, the connection's reads among them. |
| `web/verify-api-local-sources-c.txt`, `-provoked-c.txt` | `--sources` in api mode on the local database: `ALL 34 PASS`; provoked all 34 failed. |
| `web/verify-api-mock-sources-c.txt`, `-provoked-c.txt`, `verify-api-mock-reports-c.txt`, `-provoked-c.txt` | Against the build in mock mode: `--sources` 34 PASS, `--reports` 27 PASS; provoked all failed. |
| `web/verify-theme-c.txt`, `verify-layout-c.txt` | Against the mock build: theme `FAIL (1 problems)` and layout `FAIL (10 problems)`, line for line the night's (`-b`): Attempts by pipeline and Funnel's tables, as on `main`; the Sources list and the connection page pass. The layout verifier writes its screenshots into `records/layout/`; they were removed again, so `records/` is untouched. |

The standalone server needs `.next/static` and `public` copied next to it, as the `Dockerfile` does; without them the browser verifiers see unstyled pages. The container's Chromium is linked under the folder name `web/`'s Playwright looks for, as above.
