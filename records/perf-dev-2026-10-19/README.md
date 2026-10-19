# Report speed (0008x) in dev, 19 October 2026

The report speed brief, addition 0008x (`Pulse4all-com/cma#173`, squash-merged as `de12f43`), steps 1 and 2 of
`docs/perf-2026-10-19/MORNING_RUNBOOK.md`, run by Martin on 19 October 2026 in p4a-cma-dev (cma-dev-pg), after
N19-A (`records/n19a-dev-2026-10-19`). Written down by Claude Code on 19 October 2026 at Martin's request from
his report and the outputs he pushed to this folder (`e8d3087`); the values are his. Ids, counts, dates and
times only: no key, no secret and no personal data.

## Database (steps 1 and 2)

| Script | File | Result |
|---|---|---|
| `90_report_speed.sql` | `90.txt` | three `ANALYZE`; ends `INSERT 0 1`, `COMMIT`, `RESET` |
| `90_report_speed.sql` again | `90-rerun.txt` | ends `INSERT 0 0`, `COMMIT`, `RESET`; otherwise line for line `90.txt` |
| `91_verify_report_speed.sql` | `91.txt` | `is_dev` true; 12 rows `PASS`, B8 `FAIL`; verdict `FAIL`, `12 PASS, 1 FAIL` |
| `91` with `verify.provoke` true | `91-provoked.txt` | every row `FAIL`; verdict `PROVOKED, NOT A PASS`, `0 PASS, 13 FAIL` |
| `83_verify_email_reports.sql` again | `83.txt` | verdict `PASS`, `26 PASS, 0 FAIL` |
| `85_verify_first_orders.sql` again | `85.txt` | verdict `PASS`, `26 PASS, 0 FAIL` |

## `91` in detail

- B1 built a throwaway tenant at prod's counts of 19 October 2026 (among them 5,257 contacts, 1,486 won order
  deals in the window, 5,263 emails and 1,362 threads).
- B2 to B7: the new reads give 0008t's and 0008u's rows, 0 apart.
- **B8 failed, alone**, on dev's shared core (`db-g1-small`): every report read of a month under 1,000 ms,
  best of three. The email reads took 1,230 to 1,727 ms (`email_report_page` NL 1,519 ms, `email_report_of`
  1,727 ms, `email_overview_of` 1,466 ms, `email_by_dimension_of` 1,298 ms, `email_per_person_page` 1,498 ms,
  `email_per_person_of` 1,230 ms). The first orders reads are not in its list.
- B9 passed: at least five times faster than the 0008t and 0008u definitions. `email_report_of` 3,504 ms
  against 21,782 ms, `email_per_person_of` 1,235 ms against 20,249 ms, `first_orders_of` 507 ms against
  206,736 ms (206.7 s to 0.5 s).

Prod's timings, on its dedicated core, are in `records/perf-prod-2026-10-19`: every read under 500 ms.

`91`, `83` and `85` are dev only. Prod ran `90` twice and the Studio timings.

## Not in the report

- The times of the runs.
