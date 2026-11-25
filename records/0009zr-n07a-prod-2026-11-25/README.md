# Addition 0009zr (N07a) in prod, 25 November 2026

Addition 0009zr, the minute jobs off the vCPU (`Pulse4all-com/cma#319`, brief N07, PR N07a): `db/236_jobs_off_the_vcpu.sql`
and `db/237_verify_jobs_off_the_vcpu.sql`, run by Martin on cma-prod-pg on 25 November 2026 after the dev run of the same
day (the dev record is on #318's branch, commit `81adea7`, "records: 0009zr (N07a) in dev on 25 November 2026"), then the merge and the jobs'
deploys (`docs/night-2026-11-26/MORNING_RUNBOOK.md`, steps 3 to 5). This note was written down by Claude Code on 25
November 2026 from Martin's report, not from the run's own output; the values are his. Verdicts, counts and times only:
no key, no secret, no personal data. The output files of the run are not in this folder.

## P1 The concurrent index

`subscription_event_paused_idx` (the subscriptions poll's paused lookup), built concurrently from the Terminal: valid
(`indisvalid` t).

## P2 The migration and its verifies

| Step | Result |
|---|---|
| `236_jobs_off_the_vcpu.sql`, twice | applied |
| `237_verify_jobs_off_the_vcpu.sql` | `PASS 0009zr`, 11 OK |
| `237_verify_jobs_off_the_vcpu.sql`, provoked | 0 OK, 11 FAIL |
| 41, 179, 191, 219, 221, 223, 225, 235 | PASS or verified |
| 211, 213, 217 | PASS on block A; block B refused (prod has no dev seed), as expected |
| 151, 155 | refused: dev only (taken off the runbook's prod list) |

## P3 The database during the run

CPU at 100 % from 05:44 to about 06:05 (Query Insights: UTILITY COMMAND, the run itself, then `refresh_follow_up`), back
to about 25 % from 06:06.

## P4 to P7 The snapshot, the merge, the jobs, the analyze

| Step | Result |
|---|---|
| P4 the data map's schema snapshot from dev | commit `24622f6` |
| P5 the squash-merge of #319 | `f4dd9d8`, build SUCCESS |
| P6 the four job deploys (Active, follow-up, data quality, Flash) on `f4dd9d8` | every minute again. The first attempt failed with "image not found": the runbook's `git rev-parse --short` gave 8 characters (`f4dd9d89`) and the image tag has 7; the runbook now says `--short=7` |
| P7 `analyze` of the eight small configuration tables | `ANALYZE` eight times |

## After the deploy (OPERATIONS 4.1's query)

Each job 4 runs; Flash deferred 2 (`defer_wait`); the follow-up `nothing_to_read` 2; 0 `after_timeout` (`timeout_wait`);
0 statement timeouts.
