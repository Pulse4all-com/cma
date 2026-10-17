# Addition 0008o in prod, 16 October 2026

Night run N16-B (the follow-up layer; `Pulse4all-com/cma#142`), `docs/night-2026-10-16/MORNING_RUNBOOK.md`
step 10 with `docs/ingest/PROD_RUNBOOK.md` 11.1, run by Martin on 16 October 2026 in p4a-cma-prod
(cma-prod-pg), after 0008n (`records/0008n-prod-2026-10-16`). Written down by Claude Code on 17 October 2026
at Martin's request from his report and the outputs he pushed to this folder; the values are his. Ids,
counts, dates and times only: no key, no secret and no personal data.

## Database (step 10, 11.1)

| Script | File | Result |
|---|---|---|
| `72_follow_up.sql` | `72.txt` | ends `INSERT 0 1`, `COMMIT`, `RESET`; one notice: the check `connection_pipeline_sla_minutes_check` did not exist yet |
| `02_seed_pulse4all.sql` again | `02-rerun.txt` | no error: the two tenants' ids, `INSERT 0 0` twice, its blocks `DO` |

`73` is dev only. N16-B was merged as `c7a3cab`. The ingest and the backfill of tasks are in
`records/0008n-prod-2026-10-16`.

## Not in the report

- The times of the runs.
- 11.1's read-only check (the two migration rows, the three checks, the eight settings).
- The follow-up settings on Exports and the response times per ticket pipeline (11.4).
- Day one (11.5).
