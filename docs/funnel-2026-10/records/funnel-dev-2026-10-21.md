# Funnel, lost reasons and cancellations (0008za, 0008zb) in dev, 21 October 2026

Additions 0008za (`96_stage_times.sql`) and 0008zb (`98_funnel.sql`), steps 2 to 8 of `docs/funnel-2026-10/RUNBOOK.md`,
run by Martin on 21 October 2026 in p4a-cma-dev (cma-dev-pg), with `cma-ingest` and its jobs on `ingest:41d3e05` from the
branch (step 6). Written down by Claude Code on 21 October 2026 at Martin's request from his report; the values are his.
Ids, counts, hashes and times only: no key, no secret and no personal data.

## `96` and `98`, each twice (steps 2 and 3)

| Point | Functions | Views | Tables | `functions_md5` |
|---|---|---|---|---|
| At 0008z | 475 | 120 | 81 | not in the report |
| After `96`, both runs | 478 | 121 | 82 | `eabce2602e7ee817daae5f20ebeb5fb1` |
| After `98`, both runs | 515 | 126 | 85 | `3a2fc08fe6afebcd07bd83d214fd8378` |

The second run of each script left the fingerprint as the first had. The counts are the local runs' (`../local-records/db/`).

## The verifies (steps 2 and 4)

| Script | Result |
|---|---|
| `97_verify_stage_times.sql` | 17 `PASS` |
| `97` with `verify.provoke` true | 17 `FAIL` |
| `99_verify_funnel.sql` (Terminal) | 33 `PASS` in 29 s; C2's page reads as `cma_app` 152.8 to 251.6 ms |
| `99` with `verify.provoke` true | 33 `FAIL` |
| `97`, `95`, `93`, `85`, `81` and `73` | `PASS` with the counts step 4 expects (17, 36, 25, 26, 19 and 21) |
| `41_verify_lead_metrics.sql` | `PASS` for both tenants |
| `91_verify_report_speed.sql` (Terminal) | 12 `PASS`, 1 `FAIL`: B8 only, the email reads 1264 to 2017 ms on dev's shared core, as on 19 October 2026 |

## The configuration in Studio and HubSpot (steps 7 and 8)

- The stand-ins `dealtype` and `hs_ticket_priority` read as enumerations, 6 options together.
- `existingbusiness` flagged as data quality.
- The kind `cancellation` with its rule on the test account's `Support Pipeline`.
- The backfill `ingest-backfill-dzcmr` succeeded with the `^;^` form of `--args` (`--args='^;^--connection;<id>;--object;deal,ticket;--again'`); the comma form exits with code 2, since gcloud splits `--args` on every comma.
- The test account's pipeline `Sales test` had 0 stage calculated properties. Martin switched them on in HubSpot; on the next backfill its 2 deals got stage times (2 of 2).

## Not in the report

- The times of day of the runs.
- `functions_md5` at 0008z.
- Step 5 (`03` again: `reports.per_person`).
- Step 8's Studio reads in numbers (per pipeline, the gap query, the two page reads) and the backfill's log line (counts per object, `apiCalls`).
- The outputs themselves; no file was pushed with them.
