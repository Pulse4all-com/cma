# Addition 0009ze in dev, 21 November 2026

Addition 0009ze, the subscription facts (`Pulse4all-com/cma#303`, brief B39c): `db/210_subscription_facts.sql` and
`db/211_verify_subscription_facts.sql`, run by Martin on cma-dev-pg with `run_migration` from the Terminal on 21 November
2026, with the verifies that read what 210 re-creates (`docs/ingest/PROD_RUNBOOK.md` 20.1 and 20.2). The output files in
this folder are his run (commit `55549e54`; records clean, 32 files); this note was written down by Claude Code on 21
November 2026 at Martin's request, from his report and those files, and the values are his. Ids, counts of checks, codes,
times and verdicts only: no key, no secret and no personal data.

## The migration and its verify

| Step | File | Result |
|---|---|---|
| `210_subscription_facts.sql` | `210.txt` | `INSERT 0 1`: addition 0009ze recorded; `COMMIT` |
| `211_verify_subscription_facts.sql` | `211.txt` | `PASS`: 23 PASS, 0 FAIL |
| `211_verify_subscription_facts.sql`, provoked | `211-provoked.txt` | `PROVOKED, NOT A PASS`: 0 PASS, 23 FAIL |

## The reruns

All with 0 FAIL. 14, 27 and 41 print one row per tenant and no count: none holds a FAIL or an ERROR line.

| Verify | File | Result |
|---|---|---|
| `14_verify_tenant_settings.sql` | `14-rerun.txt` | `PASS` per tenant (2 tenants) |
| `27_verify_configuration.sql` | `27-rerun.txt` | `PASS` per tenant (2 tenants) |
| `41_verify_lead_metrics.sql` | `41-rerun.txt` | `PASS` per tenant (2 tenants) |
| `69_verify_email_activity.sql` | `69-rerun.txt` | `PASS`: 29 PASS |
| `73_verify_follow_up.sql` | `73-rerun.txt` | `PASS`: 21 PASS |
| `75_verify_forms_reporting.sql` | `75-rerun.txt` | `PASS`: 24 PASS |
| `101_verify_definitions_calls.sql` | `101-rerun.txt` | `PASS`: 18 PASS |
| `105_verify_reviews.sql` | `105-rerun.txt` | `PASS`: 27 PASS |
| `113_verify_assets.sql` | `113-rerun.txt` | `0008zi verified`: 25 ok |
| `117_verify_asset_sync_load.sql` | `117-rerun.txt` | `0008zk verified`: 21 ok, 0 FAIL |
| `119_verify_subscriptions.sql` | `119-rerun.txt` | `PASS`: 23 PASS |
| `121_verify_lead_cohorts.sql` | `121-rerun.txt` | `OK`: 22 PASS |
| `123_verify_flash.sql` (edited by 210's change) | `123-rerun.txt` | `0008zn verified`: 40 ok, 4 skip |
| `133_verify_perf.sql` | `133-rerun.txt` | `0008zr verified`: 20 ok, 1 skip |
| `137_verify_flash_insights.sql` (edited) | `137-rerun.txt` | `0008zt verified`: 24 ok, 1 skip |
| `139_verify_flash_totals.sql` (edited) | `139-rerun.txt` | `0008zu verified`: 16 ok, 1 skip |
| `143_verify_reviews_all_order_kinds.sql` | `143-rerun.txt` | `0008zw verified`: 13 ok |
| `147_verify_installed_base_models.sql` (edited) | `147-rerun.txt` | `0008zy verified`: 12 ok |
| `149_verify_installed_base_list.sql` | `149-rerun.txt` | `0008zz verified`: 13 ok |
| `159_verify_flash_current_take.sql` | `159-rerun.txt` | `0009e verified`: 12 ok |
| `161_verify_installed_base_now.sql` | `161-rerun.txt` | `0009f verified`: 10 ok |
| `173_verify_active_customers.sql` (edited) | `173-rerun.txt` | `PASS`: 41 PASS, 2 info, 1 skip |
| `175_verify_active_refresh_quiet.sql` | `175-rerun.txt` | `PASS`: 8 PASS, 1 skip |
| `177_verify_active_attribution_present.sql` | `177-rerun.txt` | `PASS`: 8 PASS, 1 info, 1 skip |
| `179_verify_job_reads.sql` | `179-rerun.txt` | `0009o verified`: 28 ok |
| `181_verify_flash_stored_cards.sql` | `181-rerun.txt` | `PASS`: 10 PASS, 2 skip |
| `185_verify_active_device_bands.sql` (edited) | `185-rerun.txt` | `PASS`: 14 PASS |
| `189_verify_fleet_management.sql` | `189-rerun.txt` | `PASS`: 22 PASS |
| `193_verify_fleet_page.sql` | `193-rerun.txt` | `PASS`: 13 PASS |

The skips are the usual ones of dev: the volume checks (`volume off`), a tenant without a person holding the permission,
and 173's E4 (the job holds the tenant's refresh). 117 is `21 ok` in dev this time: C3 4,404.5 ms against 10,000, C4
slowest 6,702.3 ms against 7,500, C5 page 3,983.2 ms and list 4,028.4 ms against 5,000 (on 20 November three of them
failed on speed, `records/0009zc-dev-2026-11-20`).

## The data map (20.2)

On `#303`'s branch, before the merge: the catalog's duplicate derived entry for `cma_read.subscription_store_start` was
removed (`1844dbb`, picked as `7779c5b`), then `docs/datamap/schema.json` was refreshed from dev after 0009ze
(`fa8ac74`).

The prod run of the same day is in `records/0009ze-prod-2026-11-21`.
