# Local run of brief B16 (calls overview and calls per agent, addition 0008j)

Claude Code's local runs on 14 October 2026, rerun after the review of PR #126 (the previous period like for like: `62` amended in place, `63` with three checks more). This is not a release record: `records/0008j-dev-*` and `records/0008j-prod-*` will come from Martin's real runs (`../MORNING_RUNBOOK.md`).

**Server:** PostgreSQL 18.4, the `@embedded-postgres/linux-x64` 18.4.0-beta.17 binaries from npm, as for B10 to B15. Each database is built fresh with the roles of `00_roles.sql`. `00` runs as `postgres`; every other script runs as the login `martin@pulse4all.com`, which is not a superuser. The web app's database login is `cma-web@local.iam`, a login with `grant cma_app`. Node 22.22. Chromium is the container's own: Playwright 1.63 is pointed at it through a browsers path in the scratchpad.

**Order:** `00` to `61` in B15's order (with the seed reruns), then `62`, `02` again and `63` (`db/order-of-the-fresh-database.txt`). The database at `61` was kept as the template for the comparison and the mutations.

## Database

| File | What | Result |
|---|---|---|
| `db/62_calls_overview-first-run.txt` | the addition on the fresh database at `61` | Clean (`ON_ERROR_STOP=1`); ends `INSERT 0 1`, `COMMIT`, `RESET`. |
| `db/62_calls_overview-rerun.txt` | the same addition run again | Clean; ends `INSERT 0 0`, `COMMIT`, `RESET`. |
| `db/02_seed_pulse4all-rerun.txt` | `02` after `62` | Clean, ends `DO` twice. It writes `telephony.connected_min_seconds` = 10 for both Pulse4all tenants. On the fresh build `02` also ran before `13` created the settings catalog: its new block is guarded by `to_regclass('cma.setting')` (found by this fresh build: the first version of the block stopped the build there). |
| `db/63_verify_calls_overview.txt` | block A (4 checks on the objects) and block B (15 checks on three throwaway tenants; B13 to B15 the previous period like for like) | `19 PASS, 0 FAIL`, verdict `PASS`. |
| `db/63_verify_calls_overview-provoked.txt` | the same with `verify.provoke` true | All 19 checks `FAIL`, verdict `PROVOKED, NOT A PASS`, `0 PASS, 19 FAIL`. The file has 20 lines containing FAIL: the 19 checks and the verdict's count. |
| `db/63_verify_calls_overview-refused-not-dev.txt` | a copy with `agent.two@example.com` inactive | `REFUSED: the connected database is not dev`, verdict `REFUSED: not dev`. |
| `db/earlier-verifies/` | every verify from `04` to `61`, on a copy at `61` and on a copy at `63`, with outputs masked (ids, times, dates); see `comparison.txt` | The outputs are identical except `04`, `07`, `10` and `14`. `04`: 2 more `tenant_setting` inserts (the threshold for two tenants) and 4 more updates each of `app_role` and `app_user` from the extra run of `02` (each changes only `updated_at`, as every earlier run of `02` does). `07` and `10`: the `0008j` row. `14`: the threshold in each Pulse4all tenant's settings (10), verdict PASS in both. The brief's `35`, `41`, `55` and `61` are unchanged: 2, 2, 18 and 21 PASS rows. Both columns run `61` as amended by this pull request. |
| `db/61_verify_inbound_service-main-at63.txt` | `main`'s `61` (before this pull request) at `63` | A3 `FAIL`, verdict `FAIL, 19 PASS, 1 FAIL`: A3 listed every `telephony.%` setting and `62` adds a fourth. This pull request makes A3 name its own three settings, so `61` passes again (`earlier-verifies/at63/61_verify_inbound_service.txt`, 20 PASS). |
| `db/mutations.txt` | thirty-nine deliberate breakages of `62`, each on a fresh copy at `61`, then `02`, then `63`: the first thirty, two of them rewritten for the amended code, and nine on the like-for-like previous period (the whole previous period always, never cut, cut after the period ended, cut before the time instead of at it, cut in the tenant's zone, cut on every date, today in UTC, the current period cut too, the application's read ignoring now) | All thirty-nine caught, each by the checks named on its line. Two changes to `63` came from the first round: tel-user-4's second call (so the not-linked users are counted once each) and a guarded reader read in B9 (so a refused overview fails B9 itself, not the whole block). |
| `db/reports-fixture-at63.txt` | `web/verify/reports-fixture.sql` on a copy at `63`, as the owner | `fixture written`: 10 of its 11 calls of 0008j stored, the one on the line that does not count skipped. |

## Web

| File | What | Result |
|---|---|---|
| `web/npm-ci.txt`, `web/typecheck.txt`, `web/lint.txt`, `web/build.txt` | `npm ci`, `npm run typecheck`, `npm run lint`, `npm run build` in `web/` | All exit 0. The build lists `/reports/calls`, `/reports/calls-per-agent`, `/api/v1/reports/calls`, `/api/v1/reports/calls/tag-use`, `/api/v1/reports/calls-per-agent` and `/api/v1/reports/calls-per-agent/tags`. |
| `web/verifiers-summary.txt`, `web/verify-<name>.txt`, `web/verify-<name>-provoked.txt` | the pure verifiers named in CLAUDE.md, plus `reports`, each normal and with `--provoke` | All PASS, and all provoked checks fail. Counts: `copy` 1274 keys in en and nl (its provoked run exits 1 with 5 problems, as designed), `corrections` 31, `csv` 16, `dashboard` 17, `live` 39, `team` 26, `roster` 31, `configuration` 92, `messages` 24, `import` 23, `reports` 73 (main has 48). |
| `web/verify-theme*.txt`, `web/verify-layout*.txt`, `web/verify-hints*.txt` | the browser verifiers against the standalone build in mock mode on port 8080, normal and `--provoke`; layout screenshots kept in the scratchpad, not in `records/` | `theme: PASS (40 pages, …, 11 tables per 7.6 and 3.3, a header hint open on 11 report pages)` and provoked `FAIL (6 problems)`. `layout: PASS (…, Calls and Calls per agent for 7 identities (the per-agent page for performance.team only, the opened rows and the tag table inside their cards, Enter and Down, the deltas like for like), …)` and provoked `FAIL (24 problems)`. `hints: PASS (241 headers and 59 tiles on 20 pages, …)` and provoked `FAIL (1 problems)`. |
| `web/verify-api-calls-mock*.txt`, `web/verify-api-inbound-mock*.txt`, `web/verify-api-reports-mock*.txt` | `verify/api.mjs --calls`, `--inbound` and `--reports` against the mock server | `ALL 16 PASS`, `ALL 16 PASS` and `ALL 17 PASS`; provoked, all fail as they must. |
| `web/verify-api-local-db*.txt` | the full `verify/api.mjs` against the standalone build with mock auth and api data, on the local database at `63` with `verify/reports-fixture.sql` | `ALL 250 PASS` and `ALL 250 PROVOKED CHECKS FAILED, as they must`. That is B15's 234 plus 16 for Calls (the call-outcome check stays a note, as in B15's local run). |

Not run here:
- Every `db/` script in dev and prod.
- `verify:api` against dev, where Martin expects 242: dev's 228 plus 14 for Calls, because the checks of `reports.view` alone and of a tenant without telephony need the `reader` and `invest-analyst` identities, which dev does not have. Dev's tenant has no telephony connection, so the Calls checks there read empty answers.
- `verify:iap` and `verify:scheduler`, which this brief does not touch.
- Anything against a real Aircall.
