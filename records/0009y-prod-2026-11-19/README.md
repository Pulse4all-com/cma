# Addition 0009y in prod, 19 November 2026

Addition 0009y, only people planned on the roster (`Pulse4all-com/cma#293`, brief B39; renumbered by B39a from 0009w,
194/195): `db/198_roster_planned.sql` and `db/199_verify_roster_planned.sql`, run by Martin on cma-prod-pg with
`run_migration` from the Terminal on 19 November 2026, after additions 0009w (`records/0009w-prod-2026-11-18`) and 0009x
(`records/0009x-prod-2026-11-19`). The output files in this folder are his run (commit `1941a83`); this note was
written down by Claude Code on 19 November 2026 at Martin's request, from his report and those files, and the values are
his. Counts, verdicts and dates only: no key, no secret and no personal data beyond the first names the README's roles
already give.

## The migration and its verify

| Step | File | Result |
|---|---|---|
| `198_roster_planned.sql` | `198.txt` | `INSERT 0 1`: addition 0009y recorded; `COMMIT` |
| `199_verify_roster_planned.sql` | `199.txt` | `PASS`: 13 PASS, 0 FAIL, 2 skip, 6 info. S1 `0009x 1; 0009y 1, after 0009x t, the roster t`. The two skips are pulse4all-invest's R1/R2 and R3 (no active person holds `roster.manage` or `monitoring.live` there) |
| `199_verify_roster_planned.sql`, provoked | `199-provoked.txt` | `PROVOKED, NOT A PASS`: 0 PASS, 15 FAIL |
| `25_verify_roster.sql` again | `25-rerun.txt` | 2 PASS (one per tenant) |

`95_verify_attempts_for_sales.sql` runs in dev only; its rerun is in `records/0009y-dev-2026-11-17`.

## Who left the roster (199's D4, for information)

| Tenant | Stored entries, this week and later, of people not on the roster (kept, no deletes) | Time kept but not on the roster |
|---|---|---|
| pulse4all-invest | 0 entries of 0 people | 0 people |
| pulse4all-subscriptions | 5 entries of 3 people | 7 people |

Per Martin's report, the 7 people all hold only the system role `admin`. Martin decided on 19 November 2026 that Arno
(call center manager in the README's Users and roles) stays Administrator, with one role per person (option 1), and is
therefore not on the roster (Decision log, 19 Nov 2026). The 5 stored entries stay hidden from the planner, as decided
(D4): Arno's 2, Bas's 2 and Joshua's 1.

## The roster reads' timings

`131_time_all.sql` part a in prod before 198, 19 November 2026 (`records/0009x-prod-2026-11-19/131a.txt`), for
pulse4all-subscriptions: shifts today 7.7 ms (the poll, against 20 ms), roster people 8.8 ms (against 50 ms), the roster
week's set 20.0 ms (against 100 ms). No run of 131 after 198 is recorded here.

No other record of 0009y's prod run exists.
