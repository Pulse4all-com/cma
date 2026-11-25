# Addition 0009zv in dev, 25 November 2026

Addition 0009zv: a forgotten workday is closed at the end of its Default market's office hours when no shift is published
(`Pulse4all-com/cma#326`). Martin ran it in dev (cma-dev-pg) on 25 November 2026, after #318 (0009zu) was in prod.
- **Before:** dev was at 0009zu.
- **What ran (19:28):** a versions check, 244, 245 normal and provoked, `02_seed_pulse4all.sql` again, 27, 47 and 127, a
  second versions check, then the records check.
- **Then (19:39):** `web/verify/scheduler.mjs`, normal and provoked, on `b694975`, with dev's cma-web behind
  `gcloud run services proxy`.
- **How:** the Terminal runners of the PR's steps 1 and 2. The versions check needed `set role cma_owner;` before its
  query: under his IAM login the first form failed with "permission denied for schema cma". He added it by hand, and the
  PR's runners now carry it.

This note was written down by Claude Code on 25 November 2026 at Martin's request, from his report, and the results are
his. His output files (the step files and the run files the runners wrote on his machine) are not in this folder.
Counts and verdicts only: no key, no secret, no personal data.

| Step | Result |
|---|---|
| versions check before | 0009zu recorded |
| `244_auto_close_office_hours.sql` | applied, no error |
| `245_verify_auto_close_office_hours.sql` | `PASS 0009zv`, 17 OK, 0 FAIL |
| 245, provoked | `PROVOKED, NOT A PASS`, 0 OK, 17 FAIL |
| `02_seed_pulse4all.sql` | applied, no error |
| `27_verify_configuration.sql` | PASS rows 2, FAIL lines 0 |
| `47_verify_workday_window.sql` | PASS rows 2, FAIL lines 0 |
| `127_verify_workday_sessions.sql` | 31 PASS, 0 FAIL |
| versions check after | 0009zu and 0009zv recorded |
| `node tools/check-records.mjs --login …` on the run's folder | records clean, 10 files |
| `verify/scheduler.mjs` on `b694975` (19:39) | `ALL 10 PASS` |
| `verify/scheduler.mjs --provoke` | `ALL 10 PROVOKED CHECKS FAILED, as they must` |
| records check after the scheduler run | records clean, 13 files |

Every line exited 0.

## The scheduler verifier's first attempt

The first attempt, at 19:29, failed before any check, normal and provoked. The verifier picked 2025-10-21
(`daysAgo(400)`) as a free date for agent-two. Agent-two already had a workday on that date, which Team hours did not
list, and the insert hit `workday_tenant_id_user_id_business_date_key`.

`b694975` makes the verifier find its free date in `cma.workday` as the owner. The rerun at 19:39 passed:
- the forgotten day ended at 2025-10-18T15:00:00Z (17:00 in Amsterdam: agent-two has no Default market, so
  `workday.auto_close_at`);
- the end is a system event and the day stays flagged;
- a second run closed nothing.

The rerun replaced the failed attempt's step files.
