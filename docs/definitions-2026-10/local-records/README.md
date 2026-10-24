# Local records, definitions step 1: tag meanings, Connected and Conversation (addition 0008zc, 24 October 2026)

These are the outputs of local runs in Claude Code's container:
- PostgreSQL 16 from the distribution, with a local `uuidv7()` shim (PostgreSQL 16 has none; Cloud SQL's PostgreSQL 18 has it);
- Node 22;
- the build of `web/` with mock sign-in: the standalone server in mock data mode, and in api data mode on a local database through a local login role holding `cma_app`;
- Playwright with the container's own Chromium.

They are not release records; `records/` stays Martin's. No value here comes from dev, prod, HubSpot, Aircall or GCP: every id, name and count is the dev seed's, a verify script's invented data or the invented data of `web/verify/reports-fixture.sql` and `web/verify/round-trips-fixture.sql`.

## `db/`

Three local databases: **fresh** (this branch, `00` to `101` in README order with the dev seeds, the verify scripts left out, `02` and `03` again, `reports-fixture.sql`); **main** (the scripts of `main` at 0008zb the same way); **migrated** (`main`'s `00` to `99` the same way, then this branch's `100`: prod's path).

| File | What |
|---|---|
| `fresh-build.txt` | One line per script of the fresh build after `00`: every one `exit=0 errors=0`, `100` included, with its count of notices; the seeds again and the fixture (`fixture written`). |
| `fingerprint-at-0008zb.txt` | The runbook's fingerprint (step 1) on `main` at 0008zb: 515 functions, 126 views, 85 tables, `attempts.reached_min_talk_seconds=30 telephony.connected_min_seconds=10`, additions `0008zb`. |
| `100_definitions_calls-first-run.txt`, `-rerun.txt` | Addition 0008zc on that database: the first run ends `INSERT 0 1`, `COMMIT`, `RESET`; the rerun skips what exists (`column "meaning" … already exists, skipping`) and ends `INSERT 0 0`. No error in either. |
| `fingerprint-after-100.txt`, `fingerprint-after-100-rerun.txt` | Identical: 519 functions (`cma.is_connected`, `cma.is_conversation`, `cma.call_not_reached_of` and `cma.set_telephony_tag_meaning` new; the rest replaced), 126 views, 85 tables, the same md5, `calls.conversation_min_talk_seconds=30 telephony.connected_min_seconds=0`, additions `0008zb 0008zc`. |
| `tenant-settings-before-after-100.txt` | The tenants' own values: `telephony.connected_min_seconds` 10 for both Pulse4all tenants before `100`, 0 after; neither had its own `attempts.reached_min_talk_seconds`, so neither has its own Conversation threshold (the default 30 applies). |
| `101_verify_definitions_calls.txt`, `-provoked.txt`, `-migrated.txt` | 18 checks (A1 to A6, B1 to B12), each `PASS`, the verdict PASS, on the fresh and on the migrated database; provoked every row `FAIL`, the verdict `PROVOKED`. |
| `63_…`, `85_…`, `91_…`, `93_…`, `95_…` (each normal, `-provoked` and `-migrated`) | The verifies amended for 0008zc (each header names what changed and why): `63` 19 checks, `85` 26, `91` 13, `93` 25, `95` 36, every row `PASS` on the fresh and the migrated database, every row `FAIL` provoked. On `main`'s database the same amended scripts fail where 0008zc changes the figures (`verifies-main-and-branch.txt`), as they must. |
| `verifies-main-and-branch.txt` | Every `db/` verify script on `main`'s database and on the fresh one, PASS, FAIL and ERROR rows per script. They agree except the amended ones and `101`, and `25` and `39`: rerun minutes later, `25` passes on both and `39` (the outbox's claim order, which the local `uuidv7()` shim affects) errs on both. `07`, `12`, `27` and `53` err or fail the same on both. |
| `drift.txt`, `drift-functions-fresh.txt` | `tools/drift/functions.sql` on the fresh and the migrated database: 519 lines each, no line differs (the signatures and md5s of the fresh one kept). |
| `calls-reads-timing.txt` | The reads of a month as the application, best of three, on `91`'s volume tenant at prod's counts of 19 October 2026 (a scratch copy of `91` with five reads added to B8, not committed): `calls_overview` 147 ms on 0008zc against 73 ms on 0008zb, `calls_tag_use` 83 against 37, `calls_per_person` 118 against 59, `calls_per_person_tags` 204 against 89, `attempts_per_deal_page` 55 against 55. Conversation now reads each call's current tags; every read stays well under `91`'s 1000 ms. |

## `web/`

| File | What |
|---|---|
| `checks.txt` | The last line of each check on this branch: build, typecheck, lint (0 errors; the two warnings are in `web/verify/follow-up.mjs` and `web/scripts/metrics-doc.mjs`, unchanged from `main`), the twenty pure verifiers, three of them provoked; against the mock server `hints`, `theme` and `layout`, and `verify/api.mjs --reports`, `--calls` and `--attempts` normal and provoked; against the server in api data mode on a fresh database (`00` to `101`, `02` and `03` again, `reports-fixture.sql`) the full `verify/api.mjs`, 311 of 312 PASS and all 312 FAIL provoked; on another (`round-trips-fixture.sql`) `verify/round-trips.mjs`. |
| `build.txt` | The output of `npm run build`. |
| `api-full.txt` | The full `verify/api.mjs` run, among it the new check of a tag's meaning (written and put back, a key outside the six or none a 400, an agent refused) and the Calls and Attempts checks as amended for 0008zc. |

Two things in `web/` are local, not this branch's:
- **The one `verify/api.mjs` failure** ("the own day ends at the window end, 22:00") is the local run's own doing. The run started at 23:27 in Amsterdam, after the seed's workday window (07:00 to 22:00) had closed, so the two tenants' `workday.window_start` and `workday.window_end` were removed on that local database to let the clock-in checks run; that check then reads the catalog default (24:00) where it expects 22:00. In dev, within the window, it passes as before.
- **`verify/round-trips.mjs`**: six rows over budget, all on the Dashboard and Follow-up, which this branch does not touch; the funnel's local records (`docs/funnel-2026-10/local-records/web/checks.txt`) found the same six on `main`'s build. Every Calls, Calls per agent, Attempts and Configuration row is within its budget.
- **`verify:layout`** passes with `BASE=http://localhost:8080` (as `web/verify/README.md` runs it). With `http://127.0.0.1:8080` its accordion check reads the server's page without the rail's cookie (the cookie belongs to the other host name) and fails; nothing on this branch touches the rail.

## `ingest/`

| File | What |
|---|---|
| `checks.txt` | `npm test`: the sixteen pure verifiers, each `ALL n PASS`. No ingest file changes on this branch: ingest never writes a tag's meaning, and the catalog refresh (`cma.ingest_upsert_telephony_catalog`) keeps it (`101`, B10). |
