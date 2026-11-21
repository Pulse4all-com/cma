# Addition 0009zf in dev, 21 November 2026

Addition 0009zf, the subscription facts after their first day in prod (`Pulse4all-com/cma#305`, the follow-up of brief
B39c): `db/212_subscription_facts_speed.sql` and `db/213_verify_subscription_facts_speed.sql`, run by Martin on cma-dev-pg
with `run_migration` from the Terminal on 21 November 2026, after the index they need, with the verifies that read what
212 re-creates (`docs/ingest/PROD_RUNBOOK.md` 21.2 to 21.4). The output files in this folder are his run (commit
`852b5b63`; records clean); this note was written down by Claude Code on 21 November 2026 at Martin's request, from his
report and those files, and the values are his. Counts of checks, plans, times and verdicts only: no key, no secret and
no personal data.

## The index (21.2)

`subscription_event_synced_idx (tenant_id, synced_at)` on `cma.subscription_event`, built concurrently: valid.

## The migration and its verify (21.3)

| Step | File | Result |
|---|---|---|
| `212_subscription_facts_speed.sql` | `212.txt` | `INSERT 0 1`: addition 0009zf recorded; `COMMIT` |
| `213_verify_subscription_facts_speed.sql` | `213.txt` | `PASS`: 10 PASS, 0 FAIL, 2 info |
| `213_verify_subscription_facts_speed.sql`, provoked | `213-provoked.txt` | `PROVOKED, NOT A PASS`: 0 PASS, 10 FAIL, 2 info |

213's info rows read `Seq Scan` for the events' marker (I1) and for the latest renewal (I2, the index on renewal orders
not built yet): expected on dev's small tables (21.3).

## The reruns

All with 0 FAIL.

| Verify | File | Result |
|---|---|---|
| `119_verify_subscriptions.sql` | `119-rerun.txt` | `PASS`: 23 PASS |
| `123_verify_flash.sql` | `123-rerun.txt` | `0008zn verified`: 40 ok, 4 skip |
| `137_verify_flash_insights.sql` | `137-rerun.txt` | `0008zt verified`: 24 ok, 1 skip |
| `139_verify_flash_totals.sql` | `139-rerun.txt` | `0008zu verified`: 16 ok, 1 skip |
| `147_verify_installed_base_models.sql` | `147-rerun.txt` | `0008zy verified`: 12 ok |
| `149_verify_installed_base_list.sql` | `149-rerun.txt` | `0008zz verified`: 13 ok |
| `159_verify_flash_current_take.sql` | `159-rerun.txt` | `0009e verified`: 12 ok |
| `161_verify_installed_base_now.sql` | `161-rerun.txt` | `0009f verified`: 10 ok |
| `173_verify_active_customers.sql` | `173-rerun.txt` | `PASS`: 42 PASS, 2 info, 0 skip |
| `175_verify_active_refresh_quiet.sql` | `175-rerun.txt` | `PASS`: 8 PASS, 1 skip |
| `177_verify_active_attribution_present.sql` | `177-rerun.txt` | `PASS`: 8 PASS, 1 info, 1 skip |
| `181_verify_flash_stored_cards.sql` | `181-rerun.txt` | `PASS`: 10 PASS, 2 skip |
| `185_verify_active_device_bands.sql` (edited by 0009zf) | `185-rerun.txt` | `PASS`: 14 PASS, 0 skip: the complete run (`15 PASS rows` on the screen), not the skip row |
| `189_verify_fleet_management.sql` | `189-rerun.txt` | `PASS`: 22 PASS |
| `193_verify_fleet_page.sql` | `193-rerun.txt` | `PASS`: 13 PASS |
| `211_verify_subscription_facts.sql` | `211-rerun.txt` | `PASS`: 23 PASS |

The skips are the usual ones of dev, as on 21 November before 212 (`records/0009ze-dev-2026-11-21`). 173's E4 did not
skip this time (0 skip).

## The data map (21.4)

`npm run verify:datamap` on the branch: PASS. No table, view or column changes, so `docs/datamap/schema.json` was not
refreshed.

## 21.8 in dev

The index on renewal orders (21.8, dev first, then prod) was dropped again in dev and in prod after prod's measurement
showed no gain (`left_over 0`; `records/0009zf-prod-2026-11-21`, 21.8).

The prod run of the same day is in `records/0009zf-prod-2026-11-21`.
