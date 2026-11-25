# Addition 0009zv in prod, 25 November 2026

Addition 0009zv: a forgotten workday is closed at the end of its Default market's office hours when no shift is published
(`Pulse4all-com/cma#326`). Martin ran it in prod (cma-prod-pg) on 25 November 2026 at 19:34, after the dev run and
before the merge.
- **Before:** prod was at 0009zu. 0009zt (#321, 240) has not run, so 244 runs before 240 in prod.
- **What ran:** a versions check, 244, 245 normal and provoked, `02_seed_pulse4all.sql` again, 27, 47 and 127, a second
  versions check, then the records check with his login.
- **How:** the Terminal runner of the PR's step 3, with the versions check under `set role cma_owner;`.
- **What was left out:** `web/verify/scheduler.mjs`, which is dev only.

This note was written down by Claude Code on 25 November 2026 at Martin's request, from his report, and the results are
his. His output files (the step files and the run file the runner wrote on his machine) are not in this folder. Counts,
verdicts and times only: no key, no secret, no personal data.

| Step | Result |
|---|---|
| versions check before | 0009zu recorded |
| `244_auto_close_office_hours.sql` | applied, no error |
| `245_verify_auto_close_office_hours.sql` | `PASS 0009zv`, 17 OK, 0 FAIL |
| 245, provoked | `PROVOKED, NOT A PASS`, 0 OK, 17 FAIL |
| `02_seed_pulse4all.sql` | applied, no error |
| `27_verify_configuration.sql` | PASS rows 2, FAIL lines 0 (pulse4all-subscriptions: 1 scheduler user, 7 active statuses, 2 active links) |
| `47_verify_workday_window.sql` | PASS rows 2, FAIL lines 0 |
| `127_verify_workday_sessions.sql` | 31 PASS, 0 FAIL |
| versions check after | 0009zu (17:05:01 UTC) and 0009zv (18:34:14 UTC) recorded |
| `node tools/check-records.mjs --login …` on the run's folder | records clean, 10 files |

Every line exited 0. 245's S1 (0009zv recorded after 0009zu) holds: 18:34:14 UTC is after 17:05:01 UTC.
