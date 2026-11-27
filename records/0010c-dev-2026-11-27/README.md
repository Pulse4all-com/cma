# Addition 0010c in dev, 27 November 2026

Addition 0010c, Lead cohorts' read without JIT compilation (`cma.lead_cohort_rows_of` with `set jit = off`;
`Pulse4all-com/cma#340`), run in dev (cma-dev-pg) by Martin on 27 November 2026 with `tools/runners/migration.sh dev`
from the branch at 3179f62, before the merge: 258, 259 normal and provoked, and 121.

This note was written down by Claude Code on 27 November 2026 at Martin's request, from his report, and the results are
his. The runner's log (`records/0010c-dev-2026-11-27/` on his machine) is not in this folder. Verdicts, counts and
times only: no key, no secret, no personal data.

| Step | Result |
|---|---|
| The runner | `RESULT migration-0010c-dev: OK` in 13 s |
| 258 | `ALTER FUNCTION`, `COMMENT`, `INSERT 0 1`, `COMMIT` |
| 259 | `PASS 0010c`, 4 OK |
| 259, provoked | 0 OK, 4 FAIL |
| 121 rerun | 22 PASS, 0 FAIL |

259's rows:

| Check | Result |
|---|---|
| S1 | `jit=off` alone |
| S2 | left alone as 120 made it |
| E1 invest | 0 deals, equal; 34.6 ms now, 11.2 ms with 120's definition |
| E1 subscriptions | 2 deals, equal; 13.6 ms now, 20.3 ms with 120's definition |

A reading by Claude Code, not part of the report: at these times neither side compiled with JIT (the compilation
alone took seconds in the local measurement of 258's header), so dev's E1 proves the equal answers but says nothing
about prod's 15 s; the proof there is 259 in prod and the request log's dbMs for `/reports/lead-cohorts`.
