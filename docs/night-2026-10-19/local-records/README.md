# Local records, night of 18 to 19 October 2026 (N19-A)

These are the outputs of the night's local runs in Claude Code's container: PostgreSQL 16.15 from the distribution (with a local `uuidv7()` shim, since PostgreSQL 16 has none; Cloud SQL's PostgreSQL 18 has it), Node 22, and the standalone build of `web/` in mock mode. They are not release records; `records/` stays Martin's. No value here comes from dev, prod or GCP: every id, name and count is the dev seed's or a verify script's or the mock's invented data.

## `db/`

A database built from `00` to `81` in README order (the dev seed `03` included), then the night's scripts in the morning runbook's order (`docs/night-2026-10-19/MORNING_RUNBOOK.md`, step 1), run by the final versions of the scripts on this branch.

| File | What |
|---|---|
| `82_email_reports-first-run.txt`, `-rerun.txt` | Addition 0008t: first run ends `INSERT 0 1`, `COMMIT`, `RESET`; the rerun `INSERT 0 0` for the migration row (the setting's catalog row is an upsert and says `INSERT 0 1` both times). |
| `84_first_orders-first-run.txt`, `-rerun.txt` | Addition 0008u, the same (the five settings' upsert says `INSERT 0 5` both times). |
| `86_journeys-first-run.txt`, `-rerun.txt` | Addition 0008v, the same. |
| `88_callbacks_kept-first-run.txt`, `-rerun.txt` | Addition 0008w, the same. |
| `02_seed_pulse4all-after-82.txt` | The Pulse4all seed after `82`: `reports.per_person` written; the journeys' block says the table does not exist yet (a notice, as designed). |
| `02_seed_pulse4all-after-86.txt`, `-rerun.txt` | The seed after `86` and again: the three journeys added once, nothing new the second time. |
| `seed-after-02.txt` | Read after the seeds: the three journeys of Pulse4all Subscriptions (placeholders; FCA's market empty, because this database's catalog has no GB market) and `reports.per_person` = `email`. |
| `83_verify_email_reports.txt`, `-provoked.txt` | 26 PASS, verdict PASS; provoked 0 PASS, 26 FAIL, `PROVOKED, NOT A PASS`. |
| `85_verify_first_orders.txt`, `-provoked.txt` | 26 PASS; provoked 0 PASS, 26 FAIL. |
| `87_verify_journeys.txt`, `-provoked.txt` | 16 PASS; provoked 0 PASS, 16 FAIL. |
| `89_verify_callbacks_kept.txt`, `-provoked.txt` | 15 PASS; provoked 0 PASS, 15 FAIL. |
| `41_…`, `69_…`, `73_…`, `75_…`, `81_…-at-0008w.txt` | The earlier verifies after all four additions: `41` both tenant rows PASS, `69` 29, `73` 21, `75` 24, `81` 19 PASS; unchanged (`69` with its in-place amendment for the views' new columns). |
| `schema_migration.txt` | The additions 0008s to 0008w recorded. |

Also measured, not recorded as a file: with 3,040 callback tasks over eight weeks in a scratch database, `cma.callbacks_kept_report_of` (the period and its previous one) read in about 50 ms and `callbacks_kept_per_owner_of` in 43 ms, after the call lookup moved into the callback's own row (a grouped join back to the tasks took minutes at that volume).

## `ingest/`

| File | What |
|---|---|
| `npm-test.txt` | `npm test` in `ingest/`: fourteen `ALL n PASS` (18, 53, 26, 48, 20, 49, 30, 17, 51, 27, 21, 20, 85, 21), exit 0. `verify/mapping.mjs` (53) holds the contact's creation time and the stage outcome; `verify/email-mapping.mjs` (85) the mailboxes, the origin and the re-read that fills a missing origin. |
| `mapping-provoked.txt`, `email-mapping-provoked.txt` | The two with `--provoke`: all checks failed, as they must. |
| `lint.txt` | `npm run lint`, exit 0. |
| `email-flow-local-db.txt` | `verify/email-flow.mjs` against the local database at 0008w and a fake HubSpot: 34 PASS. |

## `web/`

The final build of this branch (`build.txt`, exit 0), then every check on it:

| File | What |
|---|---|
| `typecheck.txt`, `lint.txt` | Exit 0 (lint's one warning is in `verify/follow-up.mjs`, unchanged from `main`). |
| `verify-<name>.txt` | The pure verifiers CLAUDE.md names, each with its exit code: copy 2261 keys, corrections 31, csv 18, dashboard 17, live 40, team 26, roster 36, configuration 104, messages 24, import 23, signed-out 16, invitations 27, preview 18, follow-up 34, reports 129, health 39, boundaries 273 files. |
| `verify-reports-provoked.txt`, `verify-csv-provoked.txt` | All checks failed when provoked. `reports` holds the email, first-orders and callbacks definitions checked on `83`'s, `85`'s and `89`'s own scenarios. |
| `verify-datamap.txt` | `datamap: FAIL` naming `connection_inbox_account`, `journey` and the derived `email_waiting`, `email_not_responding`, `first_orders`, `callbacks_kept` as not in `schema.json`, and the page as not rebuilt: expected until Martin refreshes the snapshot from dev (runbook step 4). A dry run against a local snapshot at 0008w found no problem (81 tables, 110 views). |
| `layout.log`, `theme.log`, `hints.log` | The browser verifiers against the build in mock mode on a freshly started server: PASS. `layout` adds First orders and Orders per person, Campaign monitoring and Callbacks kept to Email's checks (the rails of seven identities, the manager's 23 pages); `theme` 67 pages, 76 tables; `hints` 589 headers, 117 tiles and the 7 level bars. |
| `*-provoked.log` | The same three with `--provoke`: FAIL with 64, 10 and 3 problems, as they must. |
| `screenshots/` | The new pages at 1280 px in mock mode: Email, Email per agent, First orders (by day and by market, and for the tenant without an order pipeline), Orders per person, Campaign monitoring and the FCA journey's page, the Dashboard's Intake row, Follow-up with the callbacks, Sources with the order pipeline and the stage outcomes. |

Also checked by hand in api mode against a local database (no file kept): the email, first-orders, orders-per-person, callbacks-kept and journeys routes and pages with scratch fixtures in the dev tenant, the CSV file, the Sources writes of a stage outcome and the order pipeline (and their refusals), each answering what the mock answers in shape.
