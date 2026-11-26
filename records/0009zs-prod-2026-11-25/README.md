# Addition 0009zs (N07c) in prod, 25 November 2026

Addition 0009zs, Reports → Email's deals not responding in one read per branch (`Pulse4all-com/cma#320`, brief N07, PR
N07c, squash-merged as `9b634e0`): `db/238_email_not_responding_speed.sql` and
`db/239_verify_email_not_responding_speed.sql`, run by Martin on cma-prod-pg on 25 November 2026 after the dev run of
the same day (`records/0009zs-dev-2026-11-25`; `docs/night-2026-11-26/MORNING_RUNBOOK.md`, step 3b). This note was
written down by Claude Code on 25 November 2026 from Martin's report, not from the run's own output; the values are his.
Verdicts and counts only: no key, no secret, no personal data. The output files of the run are not in this folder.

| Step | Result |
|---|---|
| `238_email_not_responding_speed.sql` | applied |
| `239_verify_email_not_responding_speed.sql` | `PASS 0009zs`: E2 0 rows differ over 225 deals not responding now; E3 0 rows differ over 306 deals thirty days on |
| `239_verify_email_not_responding_speed.sql`, provoked | 0 OK, 3 FAIL |
| 83, 91, 101 | REFUSED: they run in dev only (taken off the runbook's prod list) |

So the rewritten `cma.email_not_responding_of` gives prod's answers row for row as 100's definition did.
