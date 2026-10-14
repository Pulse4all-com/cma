# Addition 0008i in prod, 14 October 2026

Brief B15 (inbound service level and missed calls not called back), steps 3 and 4 of
`docs/b15-inbound-service/MORNING_RUNBOOK.md`, run by Martin on 14 October 2026 in p4a-cma-prod
(cma-prod-pg), after dev (`records/0008i-dev-2026-10-14`). Written down by Claude Code at Martin's
request from his report of the run and the files in this folder; the values below are his. Ids and
counts only: no key, no secret, no hash and no personal data.

## Before the migration

- Point-in-time recovery on, 7 days of logs.

## Database (step 3)

| File | What | Verdict |
|---|---|---|
| `60.txt` | the addition | Clean; ends `INSERT 0 1`, `COMMIT`, `RESET` |
| `02-rerun.txt` | the Pulse4all seed after `60` | Clean; ends `DO` |
| `35-rerun.txt` | `35_verify_telephony.sql` | 2 PASS rows |
| `41-rerun.txt` | `41_verify_lead_metrics.sql` | 2 PASS rows |

`cma.schema_migration`: `0008i` applied at 14:44:55 UTC by `martin@pulse4all.com`. `61`, `53` and `55`
refuse prod (they write throwaway tenants) and ran in dev only.

## Read-only check (step 3)

Studio on cma-prod-pg, the functions of `60` on the real calls of `pulse4all-subscriptions`; counts only,
no hash:

| Measure | Value |
|---|---|
| Offered, last seven days | 185 |
| Answered, last seven days | 86 |
| Service level, last seven days | 60 % |
| Callers not called back | 13 |

Every code Aircall gave in `unanswered_by_reason` has a row in the missed-reason catalog.

## The web app (step 4)

| What | Build id | Time (UTC) |
|---|---|---|
| Build of `516b9e5` (the B15 merge), run by hand | `b0a5ece3` | 14:48 |
| Build of `516b9e5` by trigger `cma-web-main` | `2983e838` | 14:50 |
| `cma-web` on `516b9e5` live | | from 14:51 |

The trigger's build appeared about 3.5 minutes after the merge, so the manual run and the trigger built
and deployed the same image twice (harmless). The build check now waits 4 minutes after a merge before a
manual run (README, Decision log, 14 October 2026).

## Not in the report

- The per-day rows, the unanswered calls per reason and the time to answer of the read-only check.
