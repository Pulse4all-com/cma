# Local records of N06d (6 November 2026): the hours reads at volume (addition 0008zs)

Outputs of runs in the session's container, not of prod or dev: the N06 local database (`db/00` to `133` with the dev
seeds and `web/verify/perf-volume-fixture.sql` at 3) plus `web/verify/hours-volume-fixture.sql` at multiplier 6 (about
30,000 time events and 2,500 workdays for the subscriptions seed's seven active people; prod held under 10,000 time
events on 5 November 2026, the census's threshold). Milliseconds are the container's.

| File | What |
|---|---|
| `db/hours-before.txt`, `db/hours-after.txt` | `explain analyze` of the four reads (Team hours 7 and 31 days as the web runs them, the function alone, My hours 7 days) before and after `134`, as the application acting as the manager |
| `db/134_hours_reads-first-run.txt`, `-rerun.txt` | `134` twice (`INSERT 0 1`, then `INSERT 0 0`) |
| `db/135_verify_hours_reads.txt`, `-provoked.txt` | `135` normal and provoked |
| `db/07-rerun.txt`, `10-`, `16-`, `47-`, `51-`, `127-rerun.txt` | the earlier verifies of what `134` touches, rerun after it |
| `db/131_time_all-a-after.txt` | `131` part a after `134` (the three hours rows) |
| `web/` | build, typecheck, lint, the pure verifiers, `round-trips` observed and checked against the api-mode server on the final build |
