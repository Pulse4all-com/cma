# The speed work in dev, 18 October 2026

The speed work of the IT audit of 17 October 2026: `f1cf4db`, "Speed (IT audit, 17 October 2026): identity in
one transaction, a warm pool with statement ceilings, roles once per request, a request log line with the
database cost, a round-trips budget verifier" (`Pulse4all-com/cma#159`), and `1ead2c3`, "Speed follow-up (IT
audit of 17 October 2026, 5.6; prod and dev on f1cf4db): a request line for every request, alert rules in one
statement, no prefetch from the frame's links" (`Pulse4all-com/cma#165`). `verify:api` and
`verify:round-trips` against dev's `cma-web`, normal and provoked, run by Martin on 18 October 2026, and the
prod baseline of Reports → Follow-up before addition 0008s. Written down by Claude Code on 18 October 2026 at
Martin's request from his report and the outputs he pushed to this folder; the values are his. Ids, counts,
dates and times only: no key, no secret and no personal data.

## The verifiers against dev

| Run | File | Result |
|---|---|---|
| `node verify/api.mjs` (against `http://localhost:8080`) | `verify-api.txt` | 271 lines `PASS`, none `FAIL`; `ALL 271 PASS`; six `note` lines (checks left out) |
| `node verify/api.mjs --provoke` | `verify-api-provoke.txt` | 271 lines `FAIL`, none `PASS`; `ALL 271 PROVOKED CHECKS FAILED, as they must` |
| `node verify/round-trips.mjs` | `round-trips.txt` | **FAIL**: `round-trips: FAIL (1 problems)`, the one problem `admin /configuration/alert-rules: 21 statements, budget 20` |
| `node verify/round-trips.mjs --provoke` | `round-trips-provoke.txt` | `round-trips: FAIL (92 problems)`: every budget is 0, so each of the 46 requests fails on its transactions and on its statements, as it must |

`verify-api.txt` and `verify-api-provoke.txt` are byte for byte the same files as
`records/audit-2026-10-18/api-dev.txt` and `api-dev-provoked.txt`; that record lists the six notes.

## The round-trips FAIL

`round-trips.txt` shows a FAIL. Its one problem is the admin's Configuration → Alert rules page: 21 statements
against a budget of 20. On a FAIL the verifier prints the problems only, so every other request it checked
answered and stayed within its budgets. No Live route is among the problems.

Per Martin's report, this FAIL was recorded before `1ead2c3` (`Pulse4all-com/cma#165`), which cut a Live
poll from 7 to 2 requests. The file does not show when it ran, and it cannot show requests per Live poll:
round-trips counts the transactions and statements of each request, not the requests a poll makes. The page it
does show is the one part B of that pull request's commit message addresses: `getAlertRules` reads the CRM
connections' pipelines in one statement instead of one per connection, so alert-rules costs 20 statements with
0, 1 or 2 connections. Dev never ran `1ead2c3` (`records/deploys-2026-10-18`), and this folder holds no
round-trips run against it.

In `round-trips-provoke.txt` the Live board reads `manager /live/board: 7 transactions` and `33 statements`
(the supervisor's the same): those are the transactions of one request, not the requests of a poll.

## Reports → Follow-up in prod before 0008s

`prod-follow-up-baseline.txt` holds 20 request lines of `/reports/follow-up`, each with RSC `True`, in the
columns of the request lines (`docs/RUNBOOK.md` section 6). Its times carry no date and no zone.

| Lines | Times | Total ms | Database ms | Transactions, statements |
|---|---|---|---|---|
| 17 `WARNING` | 07:56:49 to 07:59:37 | 5216 to 6637.5, median 5708.4 | 7808.3 to 9699.8, median 8180 | 7 and 29 each |
| 3 `INFO` | 07:55:29 to 07:55:30 | 2.5, 12.8 and 73.7 | 0 | 0 and 0 |

`WARNING` marks a request above 800 ms (`docs/RUNBOOK.md` section 6). The same page after 0008s is in
`records/0008s-prod-2026-10-18`.

## Not in the report

- The times of the `verify:api` and round-trips runs, and the `cma-web` revision each ran against. Dev ran
  `f1cf4db` from 07:17:19 UTC (revisions `cma-web-00036-w89` and `cma-web-00037-kwj`,
  `records/deploys-2026-10-18`); the files do not show the version.
- The `CMA_DB_TRACE` update on dev's `cma-web` for the round-trips run and its removal after it
  (`docs/RUNBOOK.md` section 5).
- A round-trips run against `1ead2c3` or later.
- The measurement behind "a Live poll from 7 to 2 requests"; no file here shows requests per poll.
- The baseline's date, zone, revision and command, and what the three `INFO` lines without database time were.
- Whether `verify-api*.txt` and the audit record's files are one run filed in both folders or two runs with
  the same output.
