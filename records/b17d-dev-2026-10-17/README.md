# B17d in dev, 17 October 2026

Brief B17d (forms reporting, addition 0008p; `Pulse4all-com/cma#145`, squash-merged as `964a347`), the dev
steps of `docs/b17d-forms/MORNING_RUNBOOK.md`, run by Martin on 17 October 2026 in p4a-cma-dev (cma-dev-pg)
and HubSpot's developer test account `CMA dev`. Steps 5 and 6 (0008p in prod, the merge) are in
`records/b17d-prod-2026-10-17`. Written down by Claude Code at Martin's request from his report of the run,
as `records/b17b-*` were (`Pulse4all-com/cma#144`); the values below are his. Ids, counts, dates and times
only: no key, no secret and no personal data. The terminal and psql outputs of the run are not in this
folder.

## Steps 1 to 4: the pull request, 0008p, the data map

| Step | Result |
|---|---|
| 1. The pull request built, the ingest checks | run |
| 2. Addition 0008p (`74`) with its verify | 0008p applied in dev |
| 3. The read-only check | run |
| 4. The data map from dev | 77 tables, 104 views (committed on #145's branch as "Data map: snapshot after 0008p", in `964a347`) |

## Step 7: the web image on dev

- `cma-web` in dev on the image `964a347`.
- `verify:api`: 271 PASS.

## Step 8: the ingest, the configuration, a test form, the backfill

- 8a: the ingest image `964a347` in dev, its service and jobs.
- 8c: the configuration ran in Studio as `admin@example.com`, the dev seed's admin
  (`db/03_seed_dev_test_data.sql`): Martin's login has no app user in dev. The runbook's context block names
  it for dev since this record's pull request.
- The test form `CMA test – support` (`a2a28a27-fd5f-4206-8346-c7dd2ac32c8a`): polled, category `support`,
  kept field `cma_test_reason`.
- 8d: two test submissions; their kept values were stored.
- 8e: the backfill of the form submissions from 1 October: OK.

## Not in the report

- Step 1: the build's route lines and the ingest's `npm test` counts.
- Step 2: `75`'s counts and its provoked run, `74`'s rerun, and the counts of the earlier verifies.
- Step 3: the rows of the read-only check.
- Step 7: `verify:api --provoke` and the two `curl` checks of the Forms report.
- Step 8: the deploy and health lines and the schedules (8a); the dev forms' choice fields and the time the
  fields arrived (8b); the categories' rows (8c); the test submissions' resolution and option values, and
  the `forms_poll` runs' counts (8d); the backfill's execution id and counts (8e).
- The times of the steps.
