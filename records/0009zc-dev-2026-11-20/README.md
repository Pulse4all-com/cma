# Addition 0009zc in dev, 20 November 2026

Addition 0009zc, the Juo full read's guard and the audit's fixes (`Pulse4all-com/cma#301`, brief B39a2):
`db/206_subscription_full_read_guard.sql` and `db/207_verify_subscription_full_read_guard.sql`, run by Martin on
cma-dev-pg with `run_migration` from the Terminal on 20 November 2026, with the verifies that read the re-created
functions (`docs/ingest/PROD_RUNBOOK.md` 18.8). The output files in this folder are his run (commit `ef38bc68`); this note
was written down by Claude Code on 20 November 2026 at Martin's request, from his report and those files, and the values
are his. Ids, counts, codes and verdicts only: no key, no secret and no personal data.

## The migration and its verify

| Step | File | Result |
|---|---|---|
| `206_subscription_full_read_guard.sql` | `206.txt` | `INSERT 0 1`: addition 0009zc recorded; `COMMIT` |
| `207_verify_subscription_full_read_guard.sql` | `207.txt` | `PASS`: 7 PASS, 0 FAIL |
| `207_verify_subscription_full_read_guard.sql`, provoked | `207-provoked.txt` | `PROVOKED, NOT A PASS`: 0 PASS, 7 FAIL |

## The reruns

All with 0 FAIL, except 117 (below).

| Verify | File | Result |
|---|---|---|
| `205_verify_subscription_audit.sql` (edited by 206) | `205-rerun.txt` | `PASS`: 15 PASS |
| `203_verify_subscription_lines.sql` | `203-rerun.txt` | `PASS`: 26 PASS |
| `119_verify_subscriptions.sql` | `119-rerun.txt` | `PASS`: 23 PASS |
| `33_verify_intake_core.sql` | `33-rerun.txt` | one `PASS` row per tenant (2 tenants) |
| `69_verify_email_activity.sql` | `69-rerun.txt` | 29 PASS |
| `75_verify_forms_reporting.sql` | `75-rerun.txt` | 24 PASS |
| `79_verify_system_health.sql` | `79-rerun.txt` | 13 PASS |
| `105_verify_reviews.sql` | `105-rerun.txt` | 27 PASS |
| `107_verify_review_reference_guard.sql` | `107-rerun.txt` | 10 PASS |
| `109_verify_legacy_call_outcome.sql` | `109-rerun.txt` | 18 PASS |
| `115_verify_asset_sync.sql` | `115-rerun.txt` | `0008zj verified`: 14 ok, 0 FAIL |
| `117_verify_asset_sync_load.sql` | `117-rerun.txt` | `FAIL`: 18 ok, 3 FAIL |

117 first ran in Studio (cma-dev-pg), as 18.8 said, and stopped there on Studio's 300-second limit for a statement. It then
ran as a loose `psql` call from the Terminal, as in 17.2; its whole output is in the file. Its three FAILs are all on
speed, on dev's shared core: C3 26,947.4 ms against 10,000; C4 431 calls, sizes 1,000 to 100, 4 halvings, slowest
15,428.9 ms against 7,500; C5 page 6,789.7 ms against 5,000 (list 4,261.9 ms). Every A, B and Z row is ok, so the run is
accepted, as 17.2 says. PROD_RUNBOOK 18.8 now runs 117 from the Terminal (this record's PR).

The prod run of the same day is in `records/0009zc-prod-2026-11-20`.
