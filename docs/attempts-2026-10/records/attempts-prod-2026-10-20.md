# Attempts per deal (0008y) in prod, 20 October 2026

Addition 0008y (`92_attempts_per_deal.sql`), steps 6 to 10 of `docs/attempts-2026-10/RUNBOOK.md`, run by Martin on
20 October 2026 from 05:14 to 05:45 Amsterdam time in p4a-cma-prod (cma-prod-pg), after dev
(`attempts-dev-2026-10-19.md`). Written down by Claude Code on 20 October 2026 at Martin's request from his report;
the values are his. Ids, counts, hashes and times only: no key, no secret and no personal data.

## Before `92` (step 6)

- Point-in-time recovery: `True	7`.
- The deal pipelines marked both lead and order: 0 rows.

## The lead reads before and after `92` (step 6)

| Read | Rows | `rows_md5` | `newest_change` |
|---|---|---|---|
| `speed_to_lead_rows` | 505/505 | `3bff442e17fbc6888c13ddabc8a6c027` | `03:17:56.620753Z` |
| `lead_to_order_rows` | 505/505 | `7044b00af7e70b361db3188c5f5378a2` | `03:17:56.620753Z` |

Identical before and after `92`, `newest_change` included.

## `92` twice (step 6)

- `0008y` applied at `03:19:46.162231Z`.
- The fingerprint was identical after the first and the second run: 466 functions, `functions_md5`
  `223fe8bf75273aea428c65e903048d5f`, 120 views.
- `41_verify_lead_metrics.sql`: `PASS` (Subscriptions: 508 lead deals, 390 called).
- `reports.per_person`: `email`, unchanged.

## The timings as `cma_app` (step 7)

Best of three, in the block's order: 178.9 ms (`attempts_per_deal_page`, by day), 176.7 ms (by pipeline, every counted
deal), 139.2 ms (`attempts_per_person_of`).

## The spot check against HubSpot (step 8)

Moved to after 0008z: `docs/attempts-2026-10/RUNBOOK-0008z.md`, step 8, on the sales deals.

## Merge and the hand check (steps 9 and 10)

- Merged as `85abe09`; the prod build `SUCCESS` at 03:35Z.
- The hand checks 1 to 6: OK.
- The request log: `/reports/attempts` answered `200` with `dbMs` 203 to 244 and `totalMs` 519 to 933, one line
  `WARNING` at 932.6 ms; `/reports/attempts-per-agent` answered `404`.

## Not in the report

- The date of `newest_change`, which the report gives as a time only.
- The outputs themselves; no file was pushed with them.
