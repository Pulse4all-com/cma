# Addition 0009za in dev, 20 November 2026

Addition 0009za, Juo as a full source, Part A (`Pulse4all-com/cma#294`, brief B39a): `db/202_subscription_lines.sql` and
`db/203_verify_subscription_lines.sql`, run by Martin on cma-dev-pg with `run_migration` from the Terminal on 20 November
2026 (`docs/ingest/PROD_RUNBOOK.md` 17.2 and 17.3). The output files in this folder are his run (commit `b9905e6`; records
clean); this note was written down by Claude Code on 20 November 2026 at Martin's request, from his report and those files,
and the values are his. Ids, counts, codes and times only: no key, no secret and no personal data.

## Before

`#294`'s branch was synced with `main` through `#298` (`253654a`). `cma.schema_migration` held 0009y and 0009z, not
0009za, in dev and in prod.

## The migration and its verify

| Step | File | Result |
|---|---|---|
| `202_subscription_lines.sql` | `202.txt` | `INSERT 0 1`: addition 0009za recorded; `COMMIT` |
| `203_verify_subscription_lines.sql` | `203.txt` | `PASS`: 26 PASS, 0 FAIL |
| `203_verify_subscription_lines.sql`, provoked | `203-provoked.txt` | `PROVOKED, NOT A PASS`: 0 PASS, 26 FAIL |

## The reruns

All with 0 FAIL, except 117 (below).

| Verify | File | Result |
|---|---|---|
| `119_verify_subscriptions.sql` | `119-rerun.txt` | `PASS`: 23 PASS |
| `14_verify_tenant_settings.sql` | `14-rerun.txt` | PASS per tenant |
| `27_verify_configuration.sql` | `27-rerun.txt` | PASS per tenant |
| `33_verify_intake_core.sql` | `33-rerun.txt` | PASS per tenant |
| `69_verify_email_activity.sql` | `69-rerun.txt` | 29 PASS |
| `73_verify_follow_up.sql` | `73-rerun.txt` | 21 PASS |
| `75_verify_forms_reporting.sql` | `75-rerun.txt` | 24 PASS |
| `79_verify_system_health.sql` | `79-rerun.txt` | 13 PASS |
| `101_verify_definitions_calls.sql` | `101-rerun.txt` | 18 PASS |
| `105_verify_reviews.sql` | `105-rerun.txt` | 27 PASS |
| `107_verify_review_reference_guard.sql` | `107-rerun.txt` | 10 PASS |
| `109_verify_legacy_call_outcome.sql` | `109-rerun.txt` | 18 PASS |
| `113_verify_assets.sql` | `113-rerun.txt` | 25 ok |
| `115_verify_asset_sync.sql` | `115-rerun.txt` | 14 ok |
| `121_verify_lead_cohorts.sql` | `121-rerun.txt` | 22 PASS |
| `123_verify_flash.sql` | `123-rerun.txt` | 40 ok, 4 skip |
| `137_verify_flash_insights.sql` | `137-rerun.txt` | 24 ok, 1 skip |
| `179_verify_job_reads.sql` | `179-rerun.txt` | 28 ok |
| `185_verify_active_device_bands.sql` | `185-rerun.txt` | 14 PASS |
| `117_verify_asset_sync_load.sql` | `117-rerun.txt` | `FAIL`: 20 ok, 1 FAIL, in about 15 minutes |

117's one FAIL is C4, the first load of 50,000 new records: 431 calls, sizes 1,000 to 100, 4 halvings; first call
3,953.8 ms, slowest 10,995.2 ms against its budget of 7,500 ms. It is a speed check on dev's shared core, the same row
that failed there on 9 and 11 November; C3 (3,896.1 ms against 10,000) and C5 (page 3,764.2 ms, list 4,217.5 ms against
5,000) were ok, and every A, B and Z row was ok. 117 ran as a loose `psql` call; its whole output is in the file, and its
verdict is read from the file, not from the terminal's last lines.

## The data map (17.3)

`docs/datamap/schema.json` refreshed from dev, `latest_migration` 0009za; `verify:datamap` PASS, 124 tables, 168 views;
committed on `#294`'s branch as `70f702bb`.

The prod run of the same day is in `records/0009za-prod-2026-11-20`.
