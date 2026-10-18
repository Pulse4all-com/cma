# Addition 0008s in dev, 18 October 2026

Addition 0008s, the follow-up snapshot (`a6db116`, "Follow-up snapshot (addition 0008s; IT audit of
17 October 2026, 5.6 continued): figures once a minute per tenant, one data call for the page",
`Pulse4all-com/cma#166`), steps 1, 3 and 7 of `docs/RUNBOOK.md` section 7a, run by Martin on 18 October 2026
in p4a-cma-dev (cma-dev-pg). Written down by Claude Code on 18 October 2026 at Martin's request from his
report and the outputs he pushed to this folder; the values are his. Ids, counts, dates and times only: no
key, no secret and no personal data.

The database files are the ones step 1's `run_migration` writes (`80`, `81` normal and provoked, `73` and
`79` again); `refresh-job*.txt` are step 3's job verifier. Prod is in `records/0008s-prod-2026-10-18`.

## Database (step 1)

| Script | File | Result |
|---|---|---|
| `80_follow_up_snapshot.sql` | `80.txt` | ends `INSERT 0 1`, `COMMIT`, `RESET`; `setup_tenant_table` for `follow_up_snapshot` and `follow_up_item` (notices only for the policies and audit triggers that did not exist yet), then `DROP TRIGGER` twice (the two tables keep no audit trigger) |
| `81_verify_follow_up_snapshot.sql` | `81.txt` | `is_dev` true; 19 rows `PASS` (A1 to A6, B1 to B13); verdict `PASS`, `19 PASS, 0 FAIL`, `(20 rows)` |
| `81_verify_follow_up_snapshot.sql` with `verify.provoke` true | `81-provoked.txt` | every row `FAIL`; verdict `PROVOKED, NOT A PASS`, `0 PASS, 19 FAIL` |
| `73_verify_follow_up.sql` again | `73-rerun.txt` | 21 rows `PASS`; verdict `PASS`, `21 PASS, 0 FAIL` |
| `79_verify_system_health.sql` again | `79-rerun.txt` | 13 rows `PASS`; verdict `PASS`, `13 PASS, 0 FAIL` |

`81`'s A4 reads `follow_up_snapshot and follow_up_item: columns, RLS, the application's grants, indexes, no
audit trigger | PASS`. `73-rerun.txt` has the same rows as `records/0008p-dev-2026-10-17/73-rerun.txt`; only
B9's dates (one day later) and the line number in one notice differ.

`81`, `73` and `79` are dev only by their headers: each refuses a database that does not hold the dev seed's
active test person, which prod never holds.

## The job verifier (step 3)

| Run | File | Result |
|---|---|---|
| `node verify/refresh-follow-up.mjs` | `refresh-job.txt` | 10 lines `PASS`; `ALL 10 PASS` |
| `node verify/refresh-follow-up.mjs --provoke` | `refresh-job-provoked.txt` | 10 lines `FAIL`; `ALL 10 PROVOKED CHECKS FAILED, as they must` |

The checks include the job's line per tenant, a succeeded run row per tenant, a second session holding the dev
tenant's lock, the job skipping that tenant (`WARNING`, `running`) while refreshing the others, and the tenant
refreshed again once the lock is gone.

## The job (step 7)

From Martin's report: the job `cma-refresh-follow-up` on the image `web:a6db116`, every minute, created in dev
on 18 October 2026 at 09:17:59 UTC. Dev's `cma-web` service stayed on `f1cf4db` that day
(`records/deploys-2026-10-18`), so in dev the job runs a later image than the service.

## Not in the report

- The times of steps 1 and 3.
- Step 2's output; the schema snapshot it takes from dev is in `a6db116` (`docs/datamap/schema.json`).
- Step 4's read: every tenant's snapshot, its age and size.
- Step 7's first execution in dev and its output.
