# N19-A in dev, 19 October 2026

Night run N19-A, additions 0008t to 0008w: email reports, first orders, journeys and callbacks kept
(`Pulse4all-com/cma#170`, squash-merged as `997749c`), steps 1 to 3 of
`docs/night-2026-10-19/MORNING_RUNBOOK.md`, run by Martin on 19 October 2026 in p4a-cma-dev (cma-dev-pg). The
migrations ran at about 03:55 UTC. Written down by Claude Code on 19 October 2026 at Martin's request from his
report and the outputs he pushed to this folder (`e8d3087`); the values are his. Ids, counts, dates and times
only: no key, no secret and no personal data.

## Database (step 1)

Martin's note (`NOTE.txt`): `82.txt`, `84.txt`, `86.txt` and `88.txt` hold a third run, made by accident, not
the first. The first run showed `INSERT 0 1` for each, and `cma.schema_migration`'s `applied_at` keeps its
time. So each pair of files holds the second and the third run, both adding nothing.

| Script | Files | Result |
|---|---|---|
| `82_email_reports.sql` | `82.txt`, `82-rerun.txt` | both end `INSERT 0 0`, `COMMIT`, `RESET`, line for line the same; `UPDATE 0` (no origin left to fill); notices only for the objects that already exist and the policy `tenant_readonly` that does not |
| `84_first_orders.sql` | `84.txt`, `84-rerun.txt` | both end `INSERT 0 0`, `COMMIT`, `RESET`, line for line the same; `INSERT 0 5` at the start (the five `attribution.*` settings) |
| `86_journeys.sql` | `86.txt`, `86-rerun.txt` | both end `INSERT 0 0`, `COMMIT`, `RESET`, line for line the same |
| `88_callbacks_kept.sql` | `88.txt`, `88-rerun.txt` | both end `INSERT 0 0`, `COMMIT`, `RESET`, line for line the same |
| `02_seed_pulse4all.sql` after `86` | `02-after-86.txt` | the two tenants' `create_tenant` rows, `INSERT 0 0` twice, `DO` only; no notice, no error |
| `83_verify_email_reports.sql` | `83.txt` | `is_dev` true; 26 rows `PASS` (A1 to A6, B1 to B20); verdict `PASS`, `26 PASS, 0 FAIL` |
| `83` with `verify.provoke` true | `83-provoked.txt` | every row `FAIL`; verdict `PROVOKED, NOT A PASS`, `0 PASS, 26 FAIL` |
| `85_verify_first_orders.sql` | `85.txt` | `is_dev` true; 26 rows `PASS` (A1 to A6, B1 to B20); verdict `PASS`, `26 PASS, 0 FAIL` |
| `85` with `verify.provoke` true | `85-provoked.txt` | every row `FAIL`; verdict `PROVOKED, NOT A PASS`, `0 PASS, 26 FAIL` |
| `87_verify_journeys.sql` | `87.txt` | 16 rows `PASS` (A1 to A6, B1 to B10); verdict `PASS`, `16 PASS, 0 FAIL` |
| `87` with `verify.provoke` true | `87-provoked.txt` | every row `FAIL`; verdict `PROVOKED, NOT A PASS`, `0 PASS, 16 FAIL` |
| `89_verify_callbacks_kept.sql` | `89.txt` | 15 rows `PASS` (A1 to A3, B1 to B12); verdict `PASS`, `15 PASS, 0 FAIL` |
| `89` with `verify.provoke` true | `89-provoked.txt` | every row `FAIL`; verdict `PROVOKED, NOT A PASS`, `0 PASS, 15 FAIL` |
| `41_verify_lead_metrics.sql` again | `41-rerun.txt` | two tenant rows, each `PASS`: `pulse4all-invest` (0 lead deals, 0 called, 0 data-quality findings) and `pulse4all-subscriptions` (2, 1, 4) |
| `69_verify_email_activity.sql` again | `69-rerun.txt` | verdict `PASS`, `29 PASS, 0 FAIL` |
| `73_verify_follow_up.sql` again | `73-rerun.txt` | verdict `PASS`, `21 PASS, 0 FAIL` |
| `75_verify_forms_reporting.sql` again | `75-rerun.txt` | verdict `PASS`, `24 PASS, 0 FAIL` |
| `81_verify_follow_up_snapshot.sql` again | `81-rerun.txt` | verdict `PASS`, `19 PASS, 0 FAIL` |

Every count is the one the runbook expected. `83` to `89`, `69`, `73`, `75` and `81` are dev only: each
refuses a database without the dev seed's test person. Prod ran the migrations twice, `02` and `41`
(`records/n19a-prod-2026-10-19`).

## Configuration (step 2) and the stage outcomes (step 3c), from Martin's report

- Dev's HubSpot test account has no Self Serve pipeline, so dev's order pipeline is Sales test (`4209185980`),
  the pipeline that holds the test deals (the runbook says so in step 2 since this record).
- The stage outcomes there come from HubSpot: Won `won | source`, Lost `lost | source`.
- Found: the pipeline catalog, and so the stage outcomes, refreshes only when the ingest service processes a
  deal or a ticket, at most once an hour. A backfill of unchanged deals (every one skipped) does not trigger
  it. Step 3c of the runbook says so since this record.

## Not in the report

- The time of the first run of each migration (in `cma.schema_migration`, not in a file here).
- Step 1's Studio block (the four additions, the journeys, `reports.per_person`).
- Step 2's other outputs: the connection's origin settings and `reports.per_person` `email,orders`.
- Step 3: the image tag and the build of 3a, and 3b's counts. The runbook notes that dev ran 3b with
  `--from,2026-09-30` before the image knew `--again` (`docs/night-2026-10-19/local-records/README.md`).
- Step 4's data map snapshot went into `Pulse4all-com/cma#170` before its merge; no file of it is here.
