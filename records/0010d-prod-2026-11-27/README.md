# Addition 0010d in prod, 27 November 2026

Addition 0010d, TEMPORARY on the database only for cma_owner and cma_app and the reader logins read-only on it by
default (`Pulse4all-com/cma#341`, N07i), run in prod (cma-prod-pg) by Martin on 27 November 2026 with
`tools/runners/migration.sh prod` from the N07i branch at 5e11b0a, before the merge: 260, 261 normal and provoked, and 77.
That commit did not hold 256 to 259, so 257 was left out of the reruns: 260 re-creates no function, and 257 had passed
in prod that morning (`records/0010b-prod-2026-11-27`).

This note was written down by Claude Code on 27 November 2026 at Martin's request, from his report, and the results are
his. The runner's logs (`records/0010d-prod-2026-11-27/` on his machine) are not in this folder. Times are Amsterdam time
unless marked UTC. Verdicts, counts, times and role names only: no key, no secret, no personal data.

| Step | Time | Result |
|---|---|---|
| The runner, first run | 08:53:26 | stopped at 260 as designed, as in dev: the Studio statements printed |
| Studio as postgres on cma-prod-pg, database cma | 08:54 | the same two parts as in dev (the first three statements, then the `alter role` for NocoDB's login): both successful |
| The runner, second run | 08:55:31 | `RESULT … OK` in 11 s |
| 260 | | 0010d recorded at 07:55:26 UTC |
| 261 | | `PASS 0010d`, 8 OK (R2: no reader session older than 0010d); provoked 0 OK, 8 FAIL |
| 77 | | refused: dev only, its expected answer in prod |

## Checks on the systems it touches

| Check | Result |
|---|---|
| `gcloud logging` in p4a-cma-prod for "permission denied", 08:55 to 09:16 | nothing |

With 0010b (`records/0010b-prod-2026-11-27`), this closes the path for `bq_reader` and `cma-nocodb@p4a-cma-prod.iam`:
neither may create a temporary object or an object in any schema of the database, and both are read-only there by
default.
