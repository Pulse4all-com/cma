# Addition 0008n in dev, 16 October 2026

Night run N16-B (CRM tasks; `Pulse4all-com/cma#142`), steps 2, 4, 5 and 7 of
`docs/night-2026-10-16/MORNING_RUNBOOK.md`, run by Martin on 16 October 2026 in p4a-cma-dev (cma-dev-pg).
Written down by Claude Code on 17 October 2026 at Martin's request from his report and the outputs he
pushed to this folder; the values are his. Ids, counts, dates and times only: no key, no secret and no
personal data.

## Database (step 2)

| Script | File | Result |
|---|---|---|
| `70_crm_tasks.sql` | `70.txt` | ends `INSERT 0 1`, `COMMIT`, `RESET` |
| `70_crm_tasks.sql` again | `70-rerun.txt` | ends `INSERT 0 0`, `COMMIT`, `RESET`; its notices name the tables and indexes already there |
| `71_verify_crm_tasks.sql` | `71.txt` | 20 rows `PASS`; verdict `PASS`, `20 PASS, 0 FAIL`, `(21 rows)` |
| `71_verify_crm_tasks.sql` with `verify.provoke` true | `71-provoked.txt` | every row `FAIL`; verdict `PROVOKED, NOT A PASS`, `0 PASS, 20 FAIL` |

`71` again after 0008o (step 3): `records/0008o-dev-2026-10-16/71-rerun.txt`, 20 PASS.

## The data map (step 4)

`docs/datamap/schema.json` refreshed from dev on the N16-B branch and pushed as `cfa6cd6`, which the squash
merge `c7a3cab` holds (`"latest_migration" : "0008o"`).

## The ingest in dev (step 5)

The service and jobs deployed from the N16-B branch, image tag `f1fc212`.

## The backfill of tasks (step 7)

`ingest-backfill` with `--object task --from 2026-09-01` on the dev HubSpot connection: 2 tasks.

## Not in the report

- The times of the runs.
- Step 7's owners, statuses, types and first task date in dev.
- Step 6 (the dev HubSpot app version): deferred until the upload route exists (backlog CMA-067).
- Step 8 (the hand check on the merge's image).
- Step 9 (`record_url_task`): not possible, because HubSpot has no record page for a task
  (`/contacts/{account}/record/0-27/{id}` is a 404; a task opens as a preview on the task list). See README,
  Open decisions.
