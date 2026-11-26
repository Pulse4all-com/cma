# Addition 0009zs (N07c) in dev, 25 November 2026

Addition 0009zs, Reports → Email's deals not responding in one read per branch (`Pulse4all-com/cma#320`, brief N07, PR
N07c): `db/238_email_not_responding_speed.sql` and `db/239_verify_email_not_responding_speed.sql`, run by Martin on
cma-dev-pg on 25 November 2026 before the merge (`docs/night-2026-11-26/MORNING_RUNBOOK.md`, step 1c). This note was
written down by Claude Code on 25 November 2026 from Martin's report, not from the run's own output; the values are his.
Verdicts and counts only: no key, no secret, no personal data. The output files of the run are not in this folder.

| Step | Result |
|---|---|
| `238_email_not_responding_speed.sql` | applied, and run again (rerunnable) |
| `239_verify_email_not_responding_speed.sql` | `PASS 0009zs`, over 0 deals not responding |
| `239_verify_email_not_responding_speed.sql`, provoked | 0 OK, 3 FAIL |
| 83, 91, 101 (the readers of `cma.email_not_responding_of`) | PASS |

Dev holds no deal not responding, so E2 and E3 compared two empty answers there, and the provoked E2 failed by the switch
alone, not by its planted difference (which needs a tenant with such a deal). Prod's run (`records/0009zs-prod-2026-11-25`)
compares 225 and 306 deals.
