# Addition 0010b in prod, 27 November 2026

Addition 0010b, the readers' wrappers of 134 end their search path in pg_temp (`Pulse4all-com/cma#339`, N07h, CMA-155),
run in prod (cma-prod-pg) by Martin on 27 November 2026 with `tools/runners/migration.sh prod` from the N07h branch,
before the merge: 256, 257 normal and provoked, and the verifies that read what 256 changes and run in prod.

This note was written down by Claude Code on 27 November 2026 at Martin's request, from his report, and the results are
his. The runner's log (`records/0010b-prod-2026-11-27/` on his machine) is not in this folder. Verdicts, durations and
role names only: no key, no secret, no personal data.

| Step | Result |
|---|---|
| The runner | `RESULT migration-0010b-prod: OK`, 42 s in all |
| 77 | refused: dev only, its expected answer in prod |
| 07 (old style, its errors expected) | seven error lines, as in 0009g's record |

The runner's OK covers 256 committed, 257 passed and provoked as designed, and the reruns 135, 47, 51 and 231 passed.

## Who could reach the path 256 closed

Martin's check in prod the same day: the logins holding cma_readonly are `bq_reader` and `cma-nocodb@p4a-cma-prod.iam`,
both with TEMPORARY on the database (through PUBLIC) and without owner rights, and three logins that hold the owner's
rights already (cloudsqladmin and two team logins). So for `bq_reader` and NocoDB's login the path was an escalation to
cma_owner's rights, open from 134 in prod (6 November 2026) until 256 ran. BigQuery's federated queries cannot run DDL;
NocoDB's exposure depends on whether it lets people run SQL. The follow-up that takes TEMPORARY from PUBLIC and makes
both readers read-only on this database is N07i.
