# Addition 0009zf in prod, 21 November 2026

Addition 0009zf, the subscription facts after their first day in prod (`Pulse4all-com/cma#305`, the follow-up of brief
B39c): `db/212_subscription_facts_speed.sql` and `db/213_verify_subscription_facts_speed.sql`, run by Martin on
cma-prod-pg with `run_migration` from the Terminal on 21 November 2026, after the dev run of the same day
(`records/0009zf-dev-2026-11-21`); then the timing scripts, the optional index on renewal orders and the merge
(`docs/ingest/PROD_RUNBOOK.md` Phase 21). The six output files in this folder are his run (commit `852b5b63`; records
clean); everything else below comes from his report. This note was written down by Claude Code on 21 November 2026 at
Martin's request, from his report and those files, and the values are his. Times and verdicts only: no key, no secret,
no personal data and no commercial volume (Decision log, 20 Nov 2026). The outputs of `124` and `131` are not in this
folder (`~/cma-audit`, PROD_RUNBOOK 20.8).

## 21.5 The index on the events' write time

`subscription_event_synced_idx (tenant_id, synced_at)`, built concurrently: valid.

## 21.6 The migration and its verifies

| Step | File | Result |
|---|---|---|
| `212_subscription_facts_speed.sql` | `212.txt` | `INSERT 0 1`: addition 0009zf recorded; `COMMIT` |
| `213_verify_subscription_facts_speed.sql` | `213.txt` | `REFUSED`: 5 PASS, 1 FAIL, 2 info. A1 to A5 PASS; block B FAIL because prod has no dev seed, as expected |
| `213_verify_subscription_facts_speed.sql`, provoked | `213-provoked.txt` | `REFUSED`: 0 PASS, 6 FAIL, 2 info |
| `119_verify_subscriptions.sql` again | `119-rerun.txt` | `REFUSED`: 7 PASS, 2 FAIL (B and Z1, no dev seed), as on 21 November before 212 |
| `173_verify_active_customers.sql` again | `173-rerun.txt` | `PASS`: 42 PASS, 0 FAIL, 2 info, 0 skip |
| `185_verify_active_device_bands.sql` again (edited by 0009zf) | `185-rerun.txt` | `PASS`: 14 PASS, 0 FAIL, 0 skip; the complete run (`15 PASS rows`), no skip row |

A3 and A4 PASS on prod's own data: every part of the inputs' markers and both digests equal to 210's in every tenant,
and the payment state equal to 210's row for row (`0/0/0`: every subscription, the first 500 by id and every seventh).
So 212 changes no answer in prod.

185's D2 PASS: the stored below-the-fold documents equal a fresh computation. On 21 November before 212 it read FAIL
(`records/0009ze-prod-2026-11-21`), and that record said a PASS in this rerun would confirm the reading given there (the
minute job held the take's lock, so D2 read documents stored before 210; a gap in the verify, no defect of 210).

I1, the plan of the events' marker as the application: the first read (in `213.txt`) said `Index Only Scan using
subscription_event_synced_idx …, heap fetches 10 % of the rows read or more`. After `vacuum (analyze)
cma.subscription_event` (21.6's block for that case), 213 read again: `heap fetches none` (Martin's report; that second
read is not in this folder). I2: the index on renewal orders did not exist yet.

## 21.7 The times after 212

`124_time_flash.sql` and `131_time_all.sql` with `psql`, the connection held to the end. Against 21 November after 210
(`records/0009ze-prod-2026-11-21`).

| Row | After 212 | 21 Nov after 210 | Budget | Verdict |
|---|---|---|---|---|
| active customers inputs markers | 208.2 ms | 964.9 ms | 300 ms | ok |
| active rest (stored document) | 12.3 ms | 56.7 ms | 50 ms | ok |
| active customers (set) | 556.0 ms | 830.1 ms | 500 ms | FAIL |
| the other Customers → Active rows | | | | ok |
| subscription facts refresh | 11,478 ms | 10,156 ms | 10,000 ms | FAIL |
| `124` list subscriptions | 738.5 ms | 684.5 ms (525.9 before 210) | | |
| `124` list open_tickets | 835.0 ms | 793.8 ms | | FAIL |

The facts refresh's `steps_ms`, the milliseconds per step: outcomes 6,123, months 2,545, subscriptions 2,039, survival
499, inputs_key 167, device_units 104. The renewal outcomes are 53 % of the run.

`131` in total: 248 ok, 46 FAIL; the slowest row 12,969 ms.

The database was about twice as slow as that morning on rows 212 does not touch:

| `131` row | 21 Nov morning | After 212 |
|---|---|---|
| follow-up lists open tickets | 336.5 ms | 639.4 ms |
| installed base records, first page | 263.9 ms | 479.5 ms |
| installed base records, page of 50 | 223.7 ms | 373.9 ms |

New FAILs against the morning: those three rows, the follow-up lists (set), intake previous month (set and per day),
the connection page's catalogs and welcome manager team hours 31 days, none of which 212 touches. The inputs markers and
active rest no longer fail. Prod's database has one vCPU, and the minute job's Active refresh (about 13 s) and facts
refresh (about 11 s) overlap the page reads (docs/open-decisions.md, Database load): this run's facts refresh and Flash's
subscriptions list are read on that slower database, so they neither show 212's gain nor a loss.

## 21.8 The index on renewal orders

`subscription_event_renewal_order_idx`, built concurrently in prod: valid. 213's I2 read `Index Only Scan using
subscription_event_renewal_order_idx`, so the planner took it.

`124` after the index: 23 ok, PASS.

| `124` row | After 212 (21.7) | After the index |
|---|---|---|
| list subscriptions | 738.5 ms | 654.8 ms |
| list open_tickets (no subscription read) | 835.0 ms | 592.3 ms |

The untouched list fell more than the subscriptions list (29 % against 11 %), so the difference is the database's load,
not the index: no gain. The index was dropped in prod and in dev (`left_over 0`), as 21.8 and the Decision log of
21 Nov 2026 say for an index that brings nothing.

## The merge

`#305` was squash-merged as `00e30d43`. The merge started no Cloud Build run: under `web/` it touched only
`web/verify/perf-volume-fixture.sql`, and the trigger `cma-web-main` ignores `web/verify/**`. `cma-web` and the job
`cma-refresh-active-customers` stay on `web:fb704e3`, which is right, since 212 changed only the database. `#305`'s
deploy note said the merge would build and deploy prod; it is corrected (PROD_RUNBOOK Phase 21, RUNBOOK 2).

## Open

- 21.9, the job's real runs over 24 hours, runs on 22 November 2026: it sets the facts refresh budget from its p95 and
  sizes the database load.
- Three open decisions, recorded and not built (docs/open-decisions.md): the facts refresh (renewal outcomes first, as
  an incremental refresh), the database load on one vCPU, and Flash's subscriptions list (the payment state).
