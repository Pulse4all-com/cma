# Local run of brief B16.1 (no change against a period before the telephony history, addition 0008k)

Claude Code's local runs on 14 October 2026. This is not a release record: `records/0008k-dev-*` and `records/0008k-prod-*` will come from Martin's real runs (`../MORNING_RUNBOOK.md`).

**Server:** PostgreSQL 18.4, the `@embedded-postgres/linux-x64` 18.4.0-beta.17 binaries from npm, as for B10 to B16. The database is built fresh with the roles of `00_roles.sql`. `00` runs as `postgres`; every other script runs as the login `martin@pulse4all.com`, which is not a superuser. The web app's database login is `cma-web@local.iam`, a login with `grant cma_app`. Node 22.22. Chromium is the container's own: Playwright 1.63 is pointed at it through a browsers path outside the repository.

**Order:** `00` to `63` in B16's order (with the seed reruns), giving the same verify results as B16's local run (`63` 19 PASS, `61` 20, `55` 17, `35` and `41` 2 PASS rows); that database was kept as the template. Then `64` twice and `65` (`db/order-of-the-fresh-database.txt`).

## Database

| File | What | Result |
|---|---|---|
| `db/64_calls_history_start-first-run.txt` | the addition on a copy of the fresh database at `63` | Clean (`ON_ERROR_STOP=1`); ends `INSERT 0 1`, `COMMIT`, `RESET`. |
| `db/64_calls_history_start-rerun.txt` | the same addition run again | Clean; ends `INSERT 0 0`, `COMMIT`, `RESET`. |
| `db/65_verify_calls_history_start.txt` | block A (2 checks on the objects) and block B (9 checks on three throwaway tenants) | `11 PASS, 0 FAIL`, verdict `PASS`. |
| `db/65_verify_calls_history_start-provoked.txt` | the same with `verify.provoke` true | All 11 checks `FAIL`, verdict `PROVOKED, NOT A PASS`, `0 PASS, 11 FAIL`. The file has 12 lines containing FAIL: the 11 checks and the verdict's count. |
| `db/65_verify_calls_history_start-refused-not-dev.txt` | a copy with `agent.two@example.com` inactive | `REFUSED: the connected database is not dev`, verdict `REFUSED: not dev`. |
| `db/63_verify_calls_overview-at65.txt`, `db/35_…`, `db/41_…`, `db/55_…`, `db/61_…` | the brief's earlier verifies after `64` and `65` | `63` 19 PASS (20 PASS rows), `61` 20 (21), `55` 17 (18), `35` and `41` 2 PASS rows each: as before `64`. |
| `db/earlier-verifies/` | every verify from `04` to `63`, on a copy at `63` and on a copy at `65`, outputs masked (ids, times, dates); see `comparison.txt` | Identical except `07` and `10`, which list the new `0008k` row. `61`'s B12 counts the characters of answers made relative to now, so it was run on both copies again back to back: identical. |
| `db/mutations.txt`, `db/mutations.py` | fourteen deliberate breakages of `64`, each on a fresh copy at `63`, then `65` | Thirteen caught, each by the checks named on its line. The fourteenth (the probe of the start index over every tenant's rows) is equivalent: `cma.calls_of` still reads the tenant's calls only, so it walks more windows to the same answer. Check B9 (lines at UTC+14 and UTC−12) was added after a first round, in which the one-day window and the window cut at its own end were not caught. |
| `db/scale.txt` | 300,000 invented calls on a copy at `64`, then 40,000 more that do not count in the 140 days before | The history start in 17 to 22 ms, against 420 to 470 ms for one unbounded read of `cma.calls_of`; 51 to 61 ms with the 40,000. For scale, 0008j's own overview of a month: 1.6 seconds (unchanged here; see the pull request). |
| `db/reports-fixture-at65.txt` | `web/verify/reports-fixture.sql` on a copy at `64`, as the owner | `fixture written`; its earliest call is 40 days back, so the tenant's history starts there. |

## Web

| File | What | Result |
|---|---|---|
| `web/npm-ci.txt`, `web/typecheck.txt`, `web/lint.txt`, `web/build.txt` | `npm ci`, `npm run typecheck`, `npm run lint`, `npm run build` in `web/` | All exit 0. |
| `web/verifiers-summary.txt`, `web/verify-<name>.txt`, `web/verify-<name>-provoked.txt` | the pure verifiers named in CLAUDE.md, plus `reports`, each normal and with `--provoke` | All PASS, and all provoked checks fail. Counts: `copy` 1276 keys in en and nl (B16: 1274; its provoked run exits 1 with 5 problems, as designed), `corrections` 31, `csv` 16, `dashboard` 17, `live` 39, `team` 26, `roster` 31, `configuration` 92, `messages` 24, `import` 23, `reports` 75 (B16: 73). |
| `web/verify-theme*.txt`, `web/verify-layout*.txt`, `web/verify-hints*.txt` | the browser verifiers against the standalone build in mock mode on port 8080, normal and `--provoke`; layout screenshots kept outside the repository | `theme: PASS (40 pages, …)` and provoked `FAIL (6 problems)`. `layout: PASS (…, the deltas like for like and none before the telephony history, …)` and provoked `FAIL (25 problems)`, B16's 24 and the third delta case. `hints: PASS (241 headers and 59 tiles on 20 pages, …)` and provoked `FAIL (1 problems)`. |
| `web/verify-api-calls-mock*.txt`, `web/verify-api-inbound-mock*.txt`, `web/verify-api-reports-mock*.txt` | `verify/api.mjs --calls`, `--inbound` and `--reports` against the mock server | `ALL 19 PASS` (B16: 16), `ALL 16 PASS` and `ALL 17 PASS` (unchanged, although the mock's calls now start at its intake start date); provoked, all fail as they must. |
| `web/verify-api-local-db*.txt` | the full `verify/api.mjs` against the standalone build with mock auth and api data, on the local database at `64` with `verify/reports-fixture.sql` | `ALL 253 PASS` and `ALL 253 PROVOKED CHECKS FAILED, as they must`: B16's 250 plus 3 on the history start (the call-outcome check stays a note, as in B16). |
| `web/verify-api-calls-no-history*.txt` | `verify/api.mjs --calls` against the local database at `64` without the fixture: no call stored, as in dev | `ALL 17 PASS` (14 and the 3 on the history start, which take the branch without one; the `reader` and `invest-analyst` checks are notes, as in dev) and all 17 fail when provoked. |

Not run here:
- Every `db/` script in dev and prod.
- `verify:api` against dev, where Martin expects 245: B16's 242 plus the 3 history checks, which run in dev too.
- `verify:iap` and `verify:scheduler`, which this brief does not touch.
- Anything against a real Aircall.
