# Flash in prod, 3 November 2026 (addition 0008zn, phase 16.4)

Phase 16.4 of `docs/ingest/PROD_RUNBOOK.md` (briefs B21a and B21b, addition 0008zn, `Pulse4all-com/cma#213`; the phase
itself on `Pulse4all-com/cma#215`), run by Martin in p4a-cma-prod (`cma-prod-pg`) on 3 November 2026, before #213's
merge. Written down by Claude Code at Martin's request from his report of the runs (3 November 2026); the values below
are his. Times UTC, "about" where he gave them so. Counts, times and milliseconds only, as reported: no key, no secret,
no customer data.

## (a) Before the migrations

- The point-in-time-recovery check ran before 0008zm. Its output was not captured.

## (b) The migrations

- `120_lead_cohorts.sql` (addition 0008zm) in Cloud SQL Studio, about 08:12: 188.5 ms.
- `122_flash.sql` (addition 0008zn) in Studio, about 08:13.
- The versions recorded: `0008zm`, `0008zn`.

## (c) `123_verify_flash.sql`

- In Studio: 39 ok, 0 FAIL, 4 skip, in 6.9 s.

## (d) `124_time_flash.sql`

1. First in Studio: it failed with "cannot execute DROP FUNCTION in a read-only transaction". Studio runs a script as one
   transaction, so the read-only mode the script set for its reads lasted to the drop at its end. Fixed in `e08c001`
   (#213).
2. Through psql, on the script before that fix, about 08:15: `PASS`, 23 ok, 0 FAIL, 1 skip (`pulse4all-invest`: no
   person holds `reports.view`); worst 2,181.8 ms. That script's budgets were 1,500 ms for an overview and for a list,
   and 2,500 ms for data quality.
3. In Studio on the fixed script, about 08:26: `FAIL`, 22 ok, 1 FAIL, 1 skip. The `read only` row showed 25006 (a write
   in the timed part refused). The FAIL is the data-quality overview: 3,475.6 ms against 2,500 ms.

`pulse4all-subscriptions`, in milliseconds (best of 2):

| Read | Overview, 08:15 (psql) | First page of its list, 08:15 (psql) | Overview, 08:26 (Studio) | First page of its list, 08:26 (Studio) |
|---|---|---|---|---|
| customers | 319.5 | 241.5 | 200.7 | 261.5 |
| subscriptions | 432.4 | 263.4 | 262.5 | 267.3 |
| installed_base | 371.4 | 390.4 | 249.1 | 382.6 |
| churn | 135.4 | 122.6 | 128.1 | 126.6 |
| orders | 244.2 | 207.8 | 188.3 | 220.5 |
| payments | 170.8 | 169.0 | 165.4 | 180.1 |
| open_deals | 167.7 | 206.4 | 151.2 | 217.9 |
| open_tickets | 722.6 | 598.8 | 514.3 | 603.5 |
| open_tasks | 553.5 | 650.1 | 513.6 | 639.4 |
| reviews | 130.7 | 124.2 | 121.9 | 129.2 |
| data_quality | 2,075.6 | 2,181.8 | 3,475.6 (FAIL) | 2,141.4 |
| landing | 61.9 | — | 62.0 | — |

**The data-quality FAIL is a known exception** (Decision log, 3 November 2026). Data quality's budget, 2,500 ms, is to be
met on stored results (backlog CMA-087, a refresh job as `cma-refresh-follow-up`). Until then its live read runs every
check of `cma.data_quality_of` and can exceed the budget under load. Recorded, not rerun (PROD_RUNBOOK 16.4). Every
other read is within the budgets decided that day: 1,500 ms for an overview and the landing, 800 ms for a first page of a
list.

## (e) The reruns

- `113_verify_assets.sql`: 25 ok; C1 95.4 ms and 90.0 ms.
- `41_verify_lead_metrics.sql`: `pulse4all-invest` 0/0/0, PASS; `pulse4all-subscriptions` lead_deals 881, called 785,
  dq_findings 8,541, PASS.

## (f) The seed

- `02_seed_pulse4all.sql`: exit 0. The nine settings rows as expected; `assets.required_refs` and
  `commerce.required_contact_refs` both empty.
