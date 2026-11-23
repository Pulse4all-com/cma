# Addition 0009zg in dev, 21 November 2026

Addition 0009zg, Juo's own figures beside the CMA's (`Pulse4all-com/cma#307`, brief B39 continued, Part B39b):
`db/214_source_figures.sql` and `db/215_verify_source_figures.sql`, run by Martin on cma-dev-pg with `run_migration` from
the Terminal on 21 November 2026, with the verifies that read what 214 re-creates (`docs/ingest/PROD_RUNBOOK.md` 19.2).
The output files in this folder are his run (`node tools/check-records.mjs` clean, 19 files); the data map's counts come
from his report. This note was written down by Claude Code on 22 November 2026 at Martin's request, from his report and
those files, and the values are his. Verdicts, times and dates only: no key, no secret, no personal data and no
commercial volume.

## 19.2 The migration and its verifies

| Step | File | Result |
|---|---|---|
| `214_source_figures.sql` | `214.txt` | `INSERT 0 1`: addition 0009zg recorded; `COMMIT` |
| `215_verify_source_figures.sql` | `215.txt` | `PASS`: 16 PASS, 0 FAIL |
| `215_verify_source_figures.sql`, provoked | `215-provoked.txt` | `PROVOKED, NOT A PASS`: 0 PASS, 16 FAIL |
| `41_verify_lead_metrics.sql` again | `41-rerun.txt` | `PASS` per tenant |
| `69_verify_email_activity.sql` again | `69-rerun.txt` | `PASS`: 29 PASS, 0 FAIL |
| `73_verify_follow_up.sql` again | `73-rerun.txt` | `PASS`: 21 PASS, 0 FAIL |
| `75_verify_forms_reporting.sql` again | `75-rerun.txt` | `PASS`: 24 PASS, 0 FAIL |
| `101_verify_definitions_calls.sql` again | `101-rerun.txt` | `PASS`: 18 PASS, 0 FAIL |
| `105_verify_reviews.sql` again | `105-rerun.txt` | `PASS`: 27 PASS, 0 FAIL |
| `113_verify_assets.sql` again | `113-rerun.txt` | `0008zi verified`: 25 ok, 0 FAIL |
| `121_verify_lead_cohorts.sql` again | `121-rerun.txt` | `OK`: 22 PASS, 0 FAIL |
| `123_verify_flash.sql` again (edited by 0009zg) | `123-rerun.txt` | `0008zn verified`: 40 ok, 0 FAIL, 4 skip |
| `133_verify_perf.sql` again | `133-rerun.txt` | `0008zr verified`: 20 ok, 0 FAIL, 1 skip |
| `137_verify_flash_insights.sql` again (edited by 0009zg) | `137-rerun.txt` | `0008zt verified`: 24 ok, 0 FAIL, 1 skip |
| `139_verify_flash_totals.sql` again | `139-rerun.txt` | `0008zu verified`: 16 ok, 0 FAIL, 1 skip |
| `159_verify_flash_current_take.sql` again | `159-rerun.txt` | `0009e verified`: 12 ok, 0 FAIL, 0 skip |
| `161_verify_installed_base_now.sql` again | `161-rerun.txt` | `0009f verified`: 10 ok, 0 FAIL, 0 skip |
| `179_verify_job_reads.sql` again | `179-rerun.txt` | `0009o verified`: 28 ok, 0 FAIL, 0 skip (E5 ok in dev: dev holds no finding of the checks added since 160) |
| `211_verify_subscription_facts.sql` again | `211-rerun.txt` | `PASS`: 23 PASS, 0 FAIL |

Every rerun 0 FAIL. `117_verify_asset_sync_load.sql` is not in this folder.

## 19.3 The data map

`docs/datamap/schema.json` refreshed from dev on the branch: 132 tables, 178 views (Martin's report).
