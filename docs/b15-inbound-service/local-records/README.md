# Local run of brief B15 (inbound service level and missed calls not called back, addition 0008i)

Claude Code's local runs on 14 October 2026. This is not a release record: `records/0008i-dev-*` and `records/0008i-prod-*` will come from Martin's real runs (`../MORNING_RUNBOOK.md`).

**Server:** PostgreSQL 18.4, the `@embedded-postgres/linux-x64` 18.4.0-beta.17 binaries from npm, as for B10 and B10.1. Each database is built fresh with the roles of `00_roles.sql`. `00` runs as `postgres`; every other script runs as the login `martin@pulse4all.com`, which is not a superuser. The web app's database login is `cma-web@local.iam`, a login with `grant cma_app`. Node 22.22. Chromium is the container's own: Playwright 1.63 is pointed at it through a browsers path in the scratchpad.

**Order:** `00` to `59` in README order with the seed reruns (B10.1's order), then `60`, `02` again and `61` (`db/order-of-the-fresh-database.txt`). The database at `59` was kept as the template for the comparison and the mutations.

## Database

| File | What | Result |
|---|---|---|
| `db/60_inbound_service-first-run.txt` | the addition on the fresh database at `59` | Clean (`ON_ERROR_STOP=1`); ends `INSERT 0 1`, `COMMIT`, `RESET`. |
| `db/60_inbound_service-rerun.txt` | the same addition run again | Clean; the existing objects give notices, and it ends `INSERT 0 0`, `COMMIT`, `RESET`. |
| `db/02_seed_pulse4all-rerun.txt` | `02` after `60` | Clean, ends `DO`. It writes six reasons per Pulse4all tenant and the three settings: `telephony.service_level_seconds` 20, `telephony.callback_lookback_days` 3, `telephony.waiting_max_minutes` 30. |
| `db/61_verify_inbound_service.txt` | block A (5 checks on the objects) and block B (14 checks on three throwaway tenants) | `19 PASS, 0 FAIL`, verdict `PASS`. |
| `db/61_verify_inbound_service-provoked.txt` | the same with `verify.provoke` true | All 19 checks `FAIL`, verdict `PROVOKED, NOT A PASS`, `0 PASS, 19 FAIL`. The file has 20 lines containing FAIL: the 19 checks and the verdict's count. |
| `db/61_verify_inbound_service-refused-not-dev.txt` | a copy with `agent.two@example.com` inactive | `REFUSED: the connected database is not dev`, verdict `REFUSED: not dev`. |
| `db/earlier-verifies/` | every verify from `04` to `59`, on a copy at `59` and on a copy at `61`, with outputs masked (ids, times, dates); see `comparison.txt` | The outputs are identical except `04`, `07`, `10` and `14`, which list the new table, the `0008i` row and the three settings. Every verdict is PASS. The brief's `35`, `41`, `53` and `55` are unchanged: 2, 2, 17 and 18 PASS rows. |
| `db/mutations.txt` | twenty-nine deliberate breakages of `60`, each on a fresh copy at `59`, then `02`, then `61` | Twenty-eight caught, each by the checks named on its line. One is equivalent (`null_reason_kept`): the ingest write already stores an empty reason as null. |

The mutation runs led to three additions to `61`:
- Caller 7 in B7 and B9: a later missed call is not a callback.
- An owner-rights read in B11.
- A connection without a kind that holds a form, in B13. With it, `cma.set_telephony_missed_reason` now refuses a connection without a kind when what it holds rules out telephony. This is the rule `cma.set_connection_kind` (52) applies.

## Web

| File | What | Result |
|---|---|---|
| `web/npm-ci.txt`, `web/typecheck.txt`, `web/lint.txt`, `web/build.txt` | `npm ci`, `npm run typecheck`, `npm run lint`, `npm run build` in `web/` | All exit 0. The build lists `/reports/inbound`, `/api/v1/reports/inbound`, `/api/v1/telephony/inbound-now` and `/api/v1/configuration/sources/[id]/missed-reasons`. |
| `web/verifiers-summary.txt`, `web/verify-<name>.txt`, `web/verify-<name>-provoked.txt` | the pure verifiers named in CLAUDE.md, plus `reports`, each normal and with `--provoke` | All PASS, and all provoked checks fail. Counts: `copy` 1153 keys in en and nl (its provoked run exits 1 with 5 problems, as designed), `corrections` 31, `csv` 16, `dashboard` 17, `live` 38 (main has 29), `team` 26, `roster` 31, `configuration` 92, `messages` 24, `import` 23, `reports` 46 (main has 28). |
| `web/verify-theme*.txt`, `web/verify-layout*.txt`, `web/verify-hints*.txt` | the browser verifiers against the standalone build in mock mode on port 8080, normal and `--provoke`; layout screenshots kept in the scratchpad, not in `records/` | `theme: PASS (36 pages, …)` and provoked `FAIL (5 problems)`. `layout: PASS (…, Inbound and the Intake row with a header hint open, Intake and Inbound inside their cards, the Live board for 6 identities, …)` and provoked `FAIL (15 problems)`. `hints: PASS (157 headers and 27 tiles on 14 pages, …)` and provoked `FAIL (1 problems)`. |
| `web/verify-api-inbound-mock*.txt`, `web/verify-api-reports-mock*.txt` | `verify/api.mjs --inbound` and `--reports` against the mock server | `ALL 16 PASS` and `ALL 17 PASS`; provoked, all fail as they must. |
| `web/verify-api-local-db*.txt` | the full `verify/api.mjs` against the standalone build with mock auth and api data, on the local database at `61` with `verify/reports-fixture.sql` (the fixture run with `set role cma_owner`, since the login is not a superuser) | `ALL 234 PASS` and `ALL 234 PROVOKED CHECKS FAILED, as they must`. That is 218 earlier checks (the call-outcome check is a note, as in the 13 October local run) plus 16 for Inbound. One of those 16, `no hash, number or name in the report or the board`, finds nothing. |

Not run here:
- Every `db/` script in dev and prod.
- `verify:api` against dev, where Martin expects 234: dev's 219 earlier checks plus 15 for Inbound, because the check of a tenant without telephony needs `invest-analyst`, which dev does not have.
- `verify:iap` and `verify:scheduler`, which this brief does not touch.
- Anything against a real Aircall.
