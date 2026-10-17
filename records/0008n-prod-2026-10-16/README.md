# Addition 0008n in prod, 16 October 2026

Night run N16-B (CRM tasks; `Pulse4all-com/cma#142`), `docs/night-2026-10-16/MORNING_RUNBOOK.md` steps 10 to
12 with `docs/ingest/PROD_RUNBOOK.md` 11.1 to 11.3, run by Martin on 16 October 2026 in p4a-cma-prod
(cma-prod-pg). Written down by Claude Code on 17 October 2026 at Martin's request from his report and the
outputs he pushed to this folder; the values are his. Ids, counts, dates and times only: no key, no secret
and no personal data.

## Database (step 10, 11.1)

| Script | File | Result |
|---|---|---|
| `70_crm_tasks.sql` | `70.txt` | ends `INSERT 0 1`, `COMMIT`, `RESET` |
| `70_crm_tasks.sql` again | `70-rerun.txt` | ends `INSERT 0 0`, `COMMIT`, `RESET`; its notices name the tables and indexes already there |

`71` is dev only. 0008o followed: `records/0008o-prod-2026-10-16`.

## The merge (step 11)

N16-B merged into `main` as `c7a3cab` (squash of `Pulse4all-com/cma#142`).

## The ingest and the backfill of tasks (step 12, 11.2 and 11.3)

- The ingest from `main` at `c7a3cab`: its front intact, the `run.app` address refused with 404.
- The backfill of tasks from 1 September 2026: 14,689 tasks of 23 owners; the raw keys metadata only.

## Not in the report

- The times of the runs.
- The point-in-time recovery check and 11.1's read-only check.
- 11.3's statuses, types and first task date.
- 11.2's app version with the task subscriptions: deferred until the upload route exists (backlog CMA-067).
  Until then a change to a task arrives with the 02:30 reconcile, and a task deleted in HubSpot stays.
- 11.4. Its item 4 (`record_url_task`) is not possible, because HubSpot has no record page for a task (README,
  Open decisions).
- 11.5 (day one).
