# Addition 0009za in prod, 20 November 2026

Addition 0009za, Juo as a full source, Part A (`Pulse4all-com/cma#294`, brief B39a): `db/202_subscription_lines.sql` and
`db/203_verify_subscription_lines.sql`, run by Martin on cma-prod-pg with `run_migration` from the Terminal on 20 November
2026, after the dev run of the same day (`records/0009za-dev-2026-11-20`); then the merge, the ingest deploy, the dry runs,
the backfills, the counts and `131_time_all.sql` (`docs/ingest/PROD_RUNBOOK.md` Phase 17). The four output files in this
folder are his run (commit `b9905e6`; records clean); everything else below comes from his report. This note was written
down by Claude Code on 20 November 2026 at Martin's request, from his report and those files, and the values are his. Ids,
counts, codes and times only: no key, no secret and no personal data. A store is named by its market; a connection by the
first characters of its id, as in the report.

## 17.1 A read-only key

Juo's Admin API takes one key per request in the header `X-Juo-Admin-Api-Key`, made in the admin; Juo's documentation
(api-reference/admin/introduction) names no scopes and no read-only key. Answer: there is no read-only key, so the keys
stay as they are and the client's allow-list stays the guard (Decision log, 20 Nov 2026).

## 17.4 The migration and its verify

`ingest-poll-subscriptions` was paused first.

| Step | File | Result |
|---|---|---|
| `202_subscription_lines.sql` | `202.txt` | `INSERT 0 1`: addition 0009za recorded; `COMMIT` |
| `203_verify_subscription_lines.sql` | `203.txt` | `REFUSED`: 9 PASS, 2 FAIL. A1 to A9 PASS (A9: 0 of 58,770 renewals without their store order); B and Z1 FAIL because prod has no dev seed, as expected |
| `203_verify_subscription_lines.sql`, provoked | `203-provoked.txt` | `REFUSED`: 0 PASS, 11 FAIL |
| `119_verify_subscriptions.sql` again | `119-rerun.txt` | `REFUSED`: 7 PASS, 2 FAIL (B and Z1, no dev seed), as on 12 November (`records/0009l-prod-2026-11-12`) |

Records clean. The poll was resumed; its first runs at 09:50 UTC succeeded on the old image through the two-argument
wrapper that 202 keeps.

`#294` was squash-merged as `a9a1a73`; the `cma-web-main` build: `SUCCESS`. The ingest was deployed from `main` with
`deploy.sh`: tag `a9a1a735`, revision `cma-ingest-00022-jg4`, health ok, `run.app` 404; the ten jobs on the same image,
schedules unchanged.

## 17.5 The dry runs

12 active Juo connections: AT `3f3c`, BE `3f44`, DE `3f46`, DK `3f48`, ES `3f49`, FI `3f4a`, FR `3f4b`, GB `01a18603`,
IE `3f4c`, IT `3f4e`, NL `3f4f-72fa`, SE `3f4f-7ee1`.

**subscription.** `unreadable` 0, `minCyclesSet` and `maxCyclesSet` 0 in every store; instrument types `credit-card`,
`paypal`, `sepa-direct-debit`, and `bacs` (GB only).

| Store | AT | BE | DE | DK | ES | FI | FR | GB | IE | IT | NL | SE |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| fetched | 59 | 149 | 1,174 | 13 | 0 | 0 | 226 | 4,224 | 6 | 0 | 1,487 | 193 |

| Status | GB | NL |
|---|---|---|
| active | 3,289 | 1,177 |
| canceled | 684 | 260 |
| expired | 8 | 1 |
| failed | 230 | 33 |
| merged | 8 | 14 |
| paused | 5 | 2 |

The CMA held 177 subscriptions more than Juo returned for GB and 16 more for NL; 175 and 10 of those already carry
`source_deleted_at`, and the rest left Juo after the 03:30 reconcile. Working as designed.

**subscription_product.** Products 13 to 28 and variants 13 to 43 per store; `unreadable` 0, `textDropped` 0.
`variantsOnActiveLines` 0 and `variantsNotInCatalog` 0 in every store, although after the backfill every stored line has a
variant and a product (finding 1, below).

**subscription_event.** `unreadable` 0; no `renewal:notification-sent` in any store.

| Store | fetched | mapped | duplicates | firstEventAt |
|---|---|---|---|---|
| GB | 243,444 | 158,232 | 328 | 2025-04-30 |
| NL | 79,173 | 49,798 | 517 | 2025-05-26 |
| DE | 50,849 | 34,050 | 267 | 2025-06-03 |
| FR | 6,977 | 4,761 | 13 | 2025-06-03 |
| BE | 6,932 | 4,469 | 24 | 2025-06-03 |
| SE | 6,907 | 4,604 | 36 | 2025-06-03 |
| AT | 994 | 669 | 3 | 2026-05-28 |
| DK | 122 | 92 | 0 | 2026-06-23 |
| IE | 54 | 41 | 2 | 2026-06-01 |
| ES, FI, IT | 0 | 0 | 0 | none |

**billing_event.** Connections 12, served 12, skipped 0, failed 0: Juo accepts the billing family's grouped OR (Decision
log, 20 Nov 2026). `unreadable` 0 and `returnCodeDropped` 0 in every store. Events: GB 656 (330 with a subscription), NL
519, DE 266, BE 24, SE 36, FR 14, AT 3, IE 2; DK, ES, FI and IT 0. The return codes are SEPA codes and card dispute
reasons only. `subscription:chargeback-created` and `subscription:refund-*` match the billing family's counts and are
skipped as `DUPLICATE_TYPES`.

## 17.6 The backfills

The poll was paused.

| Run | Execution | Result |
|---|---|---|
| `subscription_event,billing_event` with `--again` | `ingest-backfill-6ll8g` | 24 results, failed 0; each store's skipped count equals its dry run's fetched minus mapped |
| `subscription,subscription_product` | `ingest-backfill-c5dqm` | exit 1, failed 3: ES, FI and IT returned no subscription (`empty_snapshot`); their catalogs and every other store loaded (finding 2) |

The poll was resumed.

## 17.7 The counts per store

| Store | lines | with variant | with product | variants | billing events | events | first event | changes |
|---|---|---|---|---|---|---|---|---|
| AT | 60 | 60 | 60 | 15 | 3 | 669 | 2026-05-28 | 0 |
| BE | 155 | 155 | 155 | 26 | 24 | 4,469 | 2025-06-03 | 0 |
| DE | 1,243 | 1,243 | 1,243 | 26 | 266 | 34,052 | 2025-06-03 | 0 |
| DK | 13 | 13 | 13 | 17 | 0 | 92 | 2026-06-23 | 0 |
| ES | 0 | 0 | 0 | 13 | 0 | 0 | none | 0 |
| FI | 0 | 0 | 0 | 13 | 0 | 0 | none | 0 |
| FR | 236 | 236 | 236 | 25 | 14 | 4,761 | 2025-06-03 | 0 |
| GB | 4,500 | 4,500 | 4,500 | 25 | 656 | 158,253 | 2025-04-30 | 1 |
| IE | 6 | 6 | 6 | 13 | 2 | 41 | 2026-06-01 | 0 |
| IT | 0 | 0 | 0 | 15 | 0 | 0 | none | 0 |
| NL | 1,566 | 1,566 | 1,566 | 43 | 519 | 49,798 | 2025-05-26 | 1 |
| SE | 208 | 208 | 208 | 25 | 36 | 4,604 | 2025-06-03 | 0 |

## 131_time_all.sql, part all

Run in prod at about 13:00 Amsterdam time with agents working: verdict `FAIL`, 223 ok, 68 FAIL, 203 skip; the slowest row
15,540 ms (the active customers refresh).

Every read of `cma.subscription_event` stays within its budget, so the choice of no new index stands (Decision log, 20 Nov
2026): Flash landing 99.4 ms, churn headline 17.0 ms (6.5 ms on 19 November), payments headline 14.6 ms, Flash set
210.7 ms, installed base document 37.9 ms, active now 113.3 ms, active file 426.4 ms. Against 0009x's part a of 19
November (`records/0009x-prod-2026-11-19/131a.txt`) every part-a row is as fast or faster, for example the installed base
records' first page 970 to 511 ms and fleet management 842 to 508 ms.

Three FAILs come with the backfill:

| Row | Time | Budget | Note |
|---|---|---|---|
| active customers refresh | 15,540 ms | 15,000 ms | the once-only recompute 17.6 announced |
| current takes refresh | 7,868 ms | 5,000 ms | 5,571 to 13,683 ms on 19 November |
| active customers inputs markers | 440.7 ms | 300 ms | cma-performance's left item (b), finding 4 |

The other FAILs are previous-month and 92-day report sets (calls, email, intake, speed to lead, first orders, attempts,
lead cohorts, forms, courtesy) that read no subscription data and have no recent prod baseline. The output of this run is
not in this folder.

## Findings (not fixed by this record)

1. The product dry run's `variantsOnActiveLines` is 0 in every store, although every stored line has a variant.
2. `empty_snapshot` for a store that returns no subscription (ES, FI, IT) fails the backfill, and the nightly reconcile
   for the same reason (docs/open-decisions.md, Juo stores without subscriptions).
3. `docs/ingest/deploy.sh`'s backfill help line lacks `subscription_product` and `billing_event`.
4. `cma.active_inputs_key_of`: 440.7 ms against 300 ms after the backfill; taken into Part C.
