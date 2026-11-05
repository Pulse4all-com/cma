# Split shifts in prod, 4 November 2026 (addition 0008zp)

Addition 0008zp (`db/126_workday_sessions.sql`, `db/127_verify_workday_sessions.sql`, `Pulse4all-com/cma#217`), run by
Martin in p4a-cma-prod (`cma-prod-pg`) on 4 November 2026 by `docs/night-2026-11-04/MORNING_RUNBOOK.md` (step 5 before
the merge, then steps 6 and 9), as `<operator>`. Written down by Claude Code at Martin's request from his
report of the runs (4 November 2026); the values below are his. Times Europe/Amsterdam unless marked UTC. Counts, times
and verdicts only, as reported: no key, no secret, no customer data.

## (a) Before the migration

- Pre-check of the stored days against 0008zp's shape: `records/0008zp-precheck-2026-11-04` (prod 1,633 days, 0
  refused).
- Point-in-time recovery: `True`, 7 days.

## (b) The migration, the seed and the verify

- `126_workday_sessions.sql`: `INSERT 0 1 COMMIT RESET`; the rerun `INSERT 0 0`.
- `02_seed_pulse4all.sql`: exit 0, no line after it.
- `127_verify_workday_sessions.sql`: `PASS`, 31 PASS, 0 FAIL.

## (c) The merge and the build

- #217 merged as `15afa36` (squash); prod's build `15afa36` SUCCESS, created 14:10 UTC.

## (d) Hand check, on Martin's own day only

- Clock in 15:22, Log out 15:23. The log out ended on IAP's `/signed-out` page ("Je bent uitgelogd …"), not on
  `/logout/done` (follow-up F2 in `docs/open-decisions.md`).
- Signing in again: Welcome showed the ended day and the Clock in again card; after Clock in again, "Back since 15:23".
- Team hours: Martin "Still clocked in", "2 sessions".
- The End workday dialog: "Your clock stops now. You can clock in again today until 22:00." The ended day 15:22 to
  15:24, with the card below it.
- My hours: one row 15:22 to 15:24, "2 sessions", Pauses 0m, Duration 1m.
- No other person's day touched, no correction made.
