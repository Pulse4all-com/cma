# Local records, funnel, lost reasons and cancellations (0008za, 0008zb, 20 October 2026)

These are the outputs of local runs in Claude Code's container:
- PostgreSQL 16 from the distribution, with a local `uuidv7()` shim (PostgreSQL 16 has none; Cloud SQL's PostgreSQL 18 has it);
- Node 22;
- the build of `web/` with mock sign-in: the standalone server in mock data mode, and in api data mode on a local database through a local login role holding `cma_app`;
- Playwright with the container's own Chromium.

They are not release records; `records/` stays Martin's. No value here comes from dev, prod, HubSpot or GCP: every id, name and count is the dev seed's, a verify script's invented data or the invented data of `web/verify/reports-fixture.sql`.

## `db/`

A fresh database built from `00` to `95` in README order (the dev seeds included), `02` and `03` again, `web/verify/reports-fixture.sql`, then `96` and `98` twice each, the verifies, `03` again, all by the final versions of the scripts on this branch.

| File | What |
|---|---|
| `fresh-build.txt` | One line per script of the build after `00`, `01` to `95` (the verify scripts left out): every one `exit=0 errors=0`, with its count of notices. |
| `02_seed_pulse4all-rerun.txt`, `03_seed_dev_test_data-rerun.txt`, `reports-fixture-load.txt` | The seeds again after the build, then the fixture (`fixture written`). At 0008z `03` says `the per-person setting does not take deals yet (addition 0008zb): rerun this seed after 98_funnel.sql`. |
| `fingerprint-at-0008z.txt` | The runbook's fingerprint (step 2) before `96`: 475 functions, 120 views, 81 tables, additions `0008z`. The settings column lists the setting definitions present; the kinds column is empty before `98`. |
| `96_stage_times-first-run.txt`, `-rerun.txt` | Addition 0008za: the first run ends `INSERT 0 1`, `COMMIT`, `RESET`; the rerun skips what exists and ends `INSERT 0 0`. |
| `fingerprint-after-96.txt`, `fingerprint-after-96-rerun.txt` | Identical: 478 functions, 121 views, 82 tables, the same md5s, additions `0008z 0008za`. |
| `97_verify_stage_times.txt`, `-provoked.txt` | 17 PASS (A1 to A5, B1 to B12), verdict PASS; provoked 0 PASS, 17 FAIL, `PROVOKED, NOT A PASS`. |
| `98_funnel-first-run.txt`, `-rerun.txt` | Addition 0008zb: the first run ends `INSERT 0 1`, `COMMIT`, `RESET`; the rerun ends `INSERT 0 0`. |
| `fingerprint-after-98.txt`, `fingerprint-after-98-rerun.txt` | Identical: 515 functions, 126 views, 85 tables, the same md5s, the setting `reports.cancellation_kind` defined, no record kind (none is seeded), additions `0008z 0008za 0008zb`. |
| `99_verify_funnel.txt`, `-provoked.txt` | 33 PASS (A1 to A8, B1 to B23, C1 and C2), verdict PASS, the whole script in 11.6 seconds; provoked 0 PASS, 33 FAIL. C2 (every page read of a month as the application, best of three, on its volume tenant at about twice prod's deal volume): deal_funnel_page 205.3 ms; NL 174.5 ms; by pipeline 170.2 ms; by source 140.0 ms; lost_reasons_page by week 157.4 ms; by day for GB 144.3 ms; cancellations_page by week 104.8 ms; by day for NL 58.2 ms; deals_per_person_page 141.1 ms; deal_funnel_page over 92 days 181.3 ms. |
| `97_verify_stage_times-after-98.txt` | `97` again after `98`: 17 PASS. |
| `41_…` to `95_…-after-0008zb.txt`, `91_verify_report_speed-after-0008zb.txt` | The earlier verifies after 0008zb, unchanged: `41` both tenant rows PASS, `73` 21, `81` 19, `85` 26, `93` 25, `95` 36 and `91` 13 PASS (`91` in 96 seconds on this machine). |
| `03_seed_dev_test_data-rerun-after-98.txt`, `per-person-after-03-rerun.txt` | `03` once more after `98`: `reports.per_person` becomes `email,orders,attempts,deals` for Pulse4all Subscriptions (dev only), empty for Invest; `reports.cancellation_kind` empty for both. |
| `schema_migration.txt` | The additions 0008s to 0008zb recorded, each described. |

## `datamap-check.txt`

`tools/datamap/build.mjs` and `--check` on a snapshot of the local database at 0008zb with this branch's catalog: 85 tables, 117 views, all described. Then `verify:datamap` on this branch with `main`'s `schema.json`: the seven expected problems (four new tables, two derived views, `index.html`) until Martin refreshes the snapshot from dev (runbook, step 9).

## `ingest/`

| File | What |
|---|---|
| `checks.txt` | `npm test` (sixteen pure verifiers, `funnel-mapping` new: 576 checks), `funnel-mapping` provoked, `eslint`, then the flow verifiers `funnel-flow` (new), `jobs-flow` and `flow` on the local database at 0008zb, each normal and provoked; then `main`'s `flow` and `jobs-flow` on the same database, which pass unchanged. |

## `web/`

| File | What |
|---|---|
| `checks.txt` | The last line of each check on this branch, in one pass from `npm ci`: build, typecheck, lint (0 errors; the one warning is in `web/verify/follow-up.mjs`, unchanged from `main`), the nineteen pure verifiers (`verify:datamap` failing as expected above), `verify:reports`, `verify:csv`, `verify:boundaries` and `verify:signed-out` provoked; then against the mock server `layout`, `hints` and `theme`, each normal and provoked; against the server in api data mode on a second fresh database (`02` and `03` again, `reports-fixture.sql`) `verify:api`, ALL 311 PASS and all 311 FAIL provoked; on a third (`02` and `03` again, `round-trips-fixture.sql`) `verify:round-trips`, with six rows over budget that `main`'s build shows the same on that database (Dashboard and Follow-up, not this branch's). |
| `build.txt` | The output of that `npm run build`. |
| `layout-provoked-new-checks.txt` | The lines of the provoked layout run that the new checks give. |
| `round-trips-observed.txt` | `verify:round-trips --observed` on that database, this branch's build beside `main`'s: every row costs the same except the six new ones (the Funnel 4 transactions and 17 statements for the manager with deals per person, Cancellations and the four API routes 2 and 9) and `/configuration/sources` (5 and 21, was 4 and 17: the record kinds read). |
