# Split shifts in dev, 4 November 2026 (addition 0008zp)

Addition 0008zp (`db/126_workday_sessions.sql`, `db/127_verify_workday_sessions.sql`, `Pulse4all-com/cma#217`, merged
as `15afa36`), run by Martin in p4a-cma-dev (`cma-dev-pg`) on 4 November 2026 by `docs/night-2026-11-04/MORNING_RUNBOOK.md`,
as `martin@pulse4all.com`, from #217's branch head `909e7ec` unless stated. Written down by Claude Code at Martin's
request from his report of the runs (4 November 2026); the values below are his. Times Europe/Amsterdam unless marked
UTC or Z. Counts, times and verdicts only, as reported: no key, no secret, no customer data.

## (a) Before the migration

- Pre-check of the stored days against 0008zp's shape: `records/0008zp-precheck-2026-11-04` (dev 98 days, 0 refused).
- Studio, `cma.schema_migration`: `0008zn` (2026-11-02T18:18:40Z) and `0008zo` (2026-11-03T16:33:31Z), no `0008zp`.

## (b) The migration and the seed

- `126_workday_sessions.sql`: `INSERT 0 1 COMMIT RESET`; the rerun `INSERT 0 0 COMMIT RESET`.
- `02_seed_pulse4all.sql`: exit 0, no `ERROR` or `NOTICE`.

## (c) `127_verify_workday_sessions.sql`

- Verdict `PASS`, 31 PASS, 0 FAIL.
- Provoked: 9 blocks failed, `PROVOKED, NOT A PASS`, 0 PASS, 31 FAIL.

## (d) The earlier verifies

- `07_verify_time_model.sql` block C: `ended ended`.
- `10_verify_corrections.sql`: 10 PASS lines; `18`, `20`, `47` and `51`: 2 each; `111`: 1. All exit 0.

## (e) Studio after

- `workday.clock_in_again`, the value and whether the seed set it: `pulse4all-invest` false / false,
  `pulse4all-subscriptions` true / true.
- `0008zp` recorded, `applied_by` `martin@pulse4all.com`.

## (f) The web on dev

- Image `15afa36` (prod's build of the merge, SUCCESS, 14:10 UTC); health
  `{"status":"ok","version":"15afa36","auth":"mock","data":"api"}`.
- `verify/api.mjs` on `15afa36`: branch "clock in again; workday.clock_in_again on, the window open until
  2026-11-04T21:00:00.000Z"; `3 of 309 FAILED`, exit 1. Every split-shift check passed. The three failures are Flash
  checks from #214, not #217, and this was their first run against dev (follow-up F1 in `docs/open-decisions.md`). The
  failing lines, verbatim:

```
FAIL  sources: the admin reads every connection with its kind got [200,true,false], wanted [200,true,true]
FAIL  flash: the file: its name (overview, market, as of), its first columns as_of and filters, no @ anywhere got [409,false,false,false], wanted [200,true,true,false]
FAIL  flash: a source not set up gives no figures, never zeros (Pulse4all Invest's shop) got [null,null,-1], wanted [false,null,0]
```

- Provoked: `ALL 309 PROVOKED CHECKS FAILED, as they must`, exit 0.

## (g) Hand check (agent-two, about 15:15 to 15:22)

- The Log out page: "You can clock in again today until 22:00" and "The time until you clock in again is not counted".
- The signed-out page (`/logout/done`): "Ended at 15:18. You can sign in and clock in again today until 22:00."
- Welcome after signing in: the Clocked out card with Clock in again focused. After Clock in again: "Clocked in at
  15:15", "Back since 15:19".
- The second log out ended the day at 15:21.
- Team hours as the supervisor: Agent Two 15:15 to 15:21, Worked and Paid 5m, the chip "2 sessions"; Test Supervisor
  "4 sessions", 0m (the API verifier's runs: dev data, no maximum of sessions, N2).
- Correct a day: both clock-ins carry the Clock-in badge, "Nothing has changed yet", no row problem (B3); cancelled,
  nothing saved.
- The status-changes download was not done by hand; `127`'s A2 covers it.
