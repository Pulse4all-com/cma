# Addition 0010b in dev, 27 November 2026

Addition 0010b, the readers' wrappers of 134 end their search path in pg_temp (`Pulse4all-com/cma#339`, N07h, CMA-155),
run in dev (cma-dev-pg) by Martin on 27 November 2026 with `tools/runners/migration.sh dev` from the N07h branch: 256, 257
normal and provoked, and the verifies that read what 256 changes (77, 135, 07, 47, 51, 231).

This note was written down by Claude Code on 27 November 2026 at Martin's request, from his report, and the results are
his. The runner's log (`records/0010b-dev-2026-11-27/` on his machine) is not in this folder. Verdicts and durations only:
no key, no secret, no personal data.

| Step | Result |
|---|---|
| The runner | `RESULT migration-0010b-dev: OK`, 23 s in all |
| 07 (old style, its errors expected) | seven error lines, as in 0009g's record |

The runner's OK covers 256 committed, 257 passed and provoked as designed, and the reruns 77, 135, 47, 51 and 231
passed: each is a gating step of the runner. With 256, 77's A5 (every SECURITY DEFINER function pins its search path
with pg_temp last) is no longer the one failing row it was in dev on 25 November 2026 (`records/0009zt-dev-2026-11-25`).
