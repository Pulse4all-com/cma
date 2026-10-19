# Report speed (0008x) in prod, 19 October 2026

The report speed brief, addition 0008x (`Pulse4all-com/cma#173`, squash-merged as `de12f43`), steps 3 to 6 of
`docs/perf-2026-10-19/MORNING_RUNBOOK.md`, run by Martin on 19 October 2026 in p4a-cma-prod (cma-prod-pg and
the Workspace), after dev (`records/perf-dev-2026-10-19`). Written down by Claude Code on 19 October 2026 at
Martin's request from his report and the outputs he pushed to this folder (`e8d3087`); the values are his.
Counts and milliseconds only: no key, no secret and no personal data.

## Database (step 3)

| Script | File | Result |
|---|---|---|
| `90_report_speed.sql` | `90.txt` | three `ANALYZE`; ends `INSERT 0 1`, `COMMIT`, `RESET`; line for line dev's `90.txt` |
| `90_report_speed.sql` again | `90-rerun.txt` | ends `INSERT 0 0`, `COMMIT`, `RESET` |

## The Studio timings (step 4)

`timings.txt`: Studio (cma-prod-pg), 19 October 2026 11:55, as `cma_app`, October 2026, best of three. Every
read under 500 ms:

| Read | ms | Rows | Before 0008x (Decision log, 19 October 2026) |
|---|---|---|---|
| `first_orders_page`, by day | 208 | 143 | |
| `first_orders_page`, by level, one market | 239 | 100 | |
| `first_orders_report` | 184 | 33 | 26.8 s |
| `first_orders_amounts` | 135 | 10 | 20.1 s |
| `first_orders_list` | 126 | 100 | 21.1 s |
| `first_orders_list`, the file (500 rows) | 127 | 161 | |
| `first_orders_per_person_of` | 108 | 15 | |
| `email_report_page`, by day | 465 | 141 | |
| `email_report_page`, by week, one market | 441 | 53 | |
| `email_report` | 467 | 141 | 7.0 s |
| `email_per_person_page` | 393 | 33 | 18 to 20 s (Email per agent) |
| `email_waiting` | 45 | 100 | |
| `email_not_responding` | 169 | 66 | |

## Hand checks on `de12f43` (steps 5 and 6), from Martin's report

- First orders: 162/56/106, against 161/56/105 on `main`'s web before the merge (step 5); live data came in
  between.
- Email: 1,504/1,167/1,339/796.
- Email per agent with its total row; Enter opens a row.
- Orders per person is not in the rail.

Found on these pages: Email's period deltas compare against a previous period before `intake.start_date` and
show four-digit growth, where First orders says "No history to compare yet" (README, Open decisions).

## Not in the report

- The time of `90` in prod and of the merge, and step 6's build and revision.
- Email's figures on `main`'s web before the merge (step 5).
