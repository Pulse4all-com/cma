# Funnel, lost reasons and cancellations (0008za, 0008zb) in prod, 21 October 2026

Additions 0008za (`96_stage_times.sql`) and 0008zb (`98_funnel.sql`), steps 10 to 17 of `docs/funnel-2026-10/RUNBOOK.md`,
run by Martin on 21 October 2026 in p4a-cma-prod (cma-prod-pg), after dev (`funnel-dev-2026-10-21.md`). Written down by
Claude Code on 21 October 2026 at Martin's request from his report; the values are his. Ids, counts, hashes and times
only: no key, no secret and no personal data.

## Before `96` (step 10)

- Point-in-time recovery: `True`.
- The fingerprint at 0008z: 475 functions, 120 views, 81 tables, `functions_md5` `f384b7583468c79b9c79d1856e9a1df8`.

## `96` and `98`, each twice (step 11)

| Point | Functions | Views | Tables | `functions_md5` |
|---|---|---|---|---|
| At 0008z | 475 | 120 | 81 | `f384b7583468c79b9c79d1856e9a1df8` |
| After `96`, both runs | 478 | 121 | 82 | `3e1669b1b924844fccf9537241046d68` |
| After `98`, both runs | 515 | 126 | 85 | `718c6b7607e9704228d6b3d3d4c1da53` |

The second run of each script left the fingerprint as the first had. The counts equal dev's at every point; the md5s
differ from dev's (`eabce2602e7ee817daae5f20ebeb5fb1` after `96`, `3a2fc08fe6afebcd07bd83d214fd8378` after `98`).

## The timings as `cma_app` (step 12)

This month, best of three, as `martin@pulse4all.com`: `cancellations_page` by week 7.0 ms, `deal_funnel_page` 110.7 ms,
`deal_funnel_page` over 92 days 96.1 ms, `lost_reasons_page` by week 102.9 ms.

## Merge and deploy (steps 13 and 14)

- Merged as `5bfcc76` (`Pulse4all-com/cma#180`); the `cma-web-main` build of `5bfcc76`: `SUCCESS`.
- `cma-ingest` revision `cma-ingest-00013-nnm` on `ingest:5bfcc76`, health ok; the jobs on `5bfcc76`.

## The configuration through the web UI (step 15)

No save failed, so the Studio fallback was not needed:
- the deals' reason `closed_lost_reason__dropdown`: 13 options, 4 of them flagged as data quality;
- the tickets' reason `cancellation_reason`: 11 options;
- the kind `cancellation` with its rule on the ticket pipeline `Cancellation`;
- `reports.cancellation_kind` set.

## The backfill and the figures in Studio (step 16)

`ingest-backfill-j9cgv`, with the `^;^` form of `--args` (`--args='^;^--connection;<id>;--object;deal,ticket;--again'`),
succeeded:

| Object | Fetched | Upserted | Failed |
|---|---|---|---|
| `deal` | 4074 | 2409 | 0 |
| `ticket` | 4906 | 3703 | 0 |

Per pipeline:

| Pipeline | Records | With stage times | With a reason |
|---|---|---|---|
| `Sales Pipeline - Subscription` | 1430 | 813 | 314 |
| `Sales Pipeline - Self Serve` | 1930 | 1596 | not in the report |
| `Cancellation` | 66 | 53 | 48 |

The gap query (stages of the counted pipelines without a single entry time):

| Pipeline | Stage | Records in the stage |
|---|---|---|
| `Cancellation` | `Waiting on Us` | 7 |
| `CCL re-permission` | `CCL stopped (15 Oct)` | 1,628 |
| `Sales Pipeline - Self Serve` | `Deals created` | 1 |

`Operations Pipeline` and `Incidents` have no stage calculated properties, switched off on purpose (0 enabled).
`Sales Pipeline - Subscription` has no gap. The stages found wait on a HubSpot setting (Open decisions, Stage calculated
properties in HubSpot).

## The hand check (step 17)

October:
- Reports → Funnel: 553 created, 4 won, 65 lost, win rate 6%.
- Reports → Cancellations: 39 requests, 32 open, 7 closed, median 11.9 days to close, 2 without a reason.

## Not in the report

- The times of day of the runs.
- Which functions make dev's and prod's `functions_md5` differ at equal counts: `tools/drift/functions.sql` names them (`docs/RUNBOOK.md`, 7b); it was not run in this report.
- The backfill's log line (`apiCalls`, the requests per endpoint), the Self Serve deals with a reason, and step 16's two page reads.
- Step 17's request log lines.
- The outputs themselves; no file was pushed with them.
