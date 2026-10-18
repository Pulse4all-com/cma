# Addition 0008p in prod, 17 October 2026

Brief B17d (forms reporting, addition 0008p; `Pulse4all-com/cma#145`, squash-merged as `964a347`), step 5 of
`docs/b17d-forms/MORNING_RUNBOOK.md`, run by Martin on 17 October 2026 in p4a-cma-prod (cma-prod-pg), after
dev (`records/0008p-dev-2026-10-17`) and before the merge. Written down by Claude Code on 18 October 2026 at
Martin's request from his report and the outputs he pushed to this folder; the values are his. Ids, counts,
dates and times only: no key, no secret and no personal data. The outputs were committed on 18 October 2026
with `Pulse4all-com/cma#167`.

The file names are the ones step 5's commands write. The rest of B17d's prod run is in
`records/b17d-prod-2026-10-17`, which gives 0008p applied in prod at 09:58 UTC and listed `74`'s and its
rerun's last lines and the counts of `33`, `35` and `41` as not in its report: they are the files below.

## Database (step 5)

| Script | File | Result |
|---|---|---|
| `74_forms_reporting.sql` | `74.txt` | ends `INSERT 0 1`, `COMMIT`, `RESET`; `UPDATE 50` (the existing forms' `is_polled` set as they count); the same notices as in dev |
| `74_forms_reporting.sql` again | `74-rerun.txt` | ends `INSERT 0 0`, `COMMIT`, `RESET`; `UPDATE 0`; line for line the same as dev's `74-rerun.txt` |
| `33_verify_intake_core.sql` again | `33-rerun.txt` | two tenant rows, each `PASS`: `pulse4all-invest` all 0; `pulse4all-subscriptions` 14 markets, 31 aliases, 5 hour ranges, 4142 CRM calls, 468 submissions, 16680 sync runs |
| `35_verify_telephony.sql` again | `35-rerun.txt` | two tenant rows, each `PASS`: `pulse4all-invest` all 0; `pulse4all-subscriptions` 57 lines, 54 tags, 4085 telephony calls, 4063 call links |
| `41_verify_lead_metrics.sql` again | `41-rerun.txt` | two tenant rows, each `PASS`: `pulse4all-invest` all 0; `pulse4all-subscriptions` 433 lead deals, 347 called, 17345 data-quality findings |

`74.txt` differs from dev's in one line: `UPDATE 50` here, `UPDATE 1` in dev.

`75_verify_forms_reporting.sql`, 0008p's verify, is dev only by its header: it refuses a database that does
not hold the dev seed's active test person, which prod never holds. So are `53`, `69`, `71` and `73`, which
dev ran again after `74`. Their runs are in `records/0008p-dev-2026-10-17`; this folder has none of them.

## Not in the report

- The times of `74`'s rerun and of `33`, `35` and `41`.
- Step 5's point-in-time recovery check and its read-only check (the addition, the forms as they count,
  Intake's form counts).
