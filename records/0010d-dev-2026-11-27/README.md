# Addition 0010d in dev, 27 November 2026

Addition 0010d, TEMPORARY on the database only for cma_owner and cma_app and the reader logins read-only on it by
default (`Pulse4all-com/cma#341`, N07i), run in dev (cma-dev-pg) by Martin on 27 November 2026 with
`tools/runners/migration.sh dev` from the N07i branch at 5e11b0a, before the merge: 260, 261 normal and provoked, and 77.
That commit did not hold 256 to 259 (main's 0010b, #339, and the open 0010c), so 257 was left out of the reruns: 260
re-creates no function, and 257 had passed in dev that morning (`records/0010b-dev-2026-11-27`).

This note was written down by Claude Code on 27 November 2026 at Martin's request, from his report, and the results are
his. The runner's logs (`records/0010d-dev-2026-11-27/` on his machine) are not in this folder. Times are Amsterdam time.
Verdicts, counts, times and role names only: no key, no secret, no personal data.

| Step | Time | Result |
|---|---|---|
| The runner, first run | 07:27:50 | stopped at 260 as designed: no COMMIT, 0010d not recorded, the Studio statements printed |
| Studio as postgres on cma-dev-pg, database cma | 07:29 | the first three statements of the printed block: successful |
| Studio as postgres, the same | 07:30 | the `alter role` for NocoDB's login, on its own: successful (no ADMIN refusal under PostgreSQL 18) |
| The runner, second run | 07:30:55 | `RESULT … OK` in 11 s |
| 260 | | `INSERT 0 1`, `COMMIT` |
| 261 | | `PASS 0010d`, 8 OK; provoked 0 OK, 8 FAIL |
| 77 | | 14 PASS |

## Checks on the systems it touches

| Check | Result |
|---|---|
| BigQuery, `EXTERNAL_QUERY` on `cma_dev_read` | `default_transaction_read_only` on, 183 views in `cma_read`, 128 rows in `cma_read.workday_summary` |
| NocoDB dev, base on `cma_read` | `workday_summary` opened (128 records), `workday` opened (139) |
| `gcloud logging` in p4a-cma-dev for "permission denied", 07:30 to 08:52 | nothing |
