# Addition 0009zb in prod, 20 November 2026: the subscription audit's findings

Addition 0009zb, the subscription audit and BACS direct debit (`Pulse4all-com/cma#301`, brief B39 continued, Part B39a2):
`db/204_subscription_audit.sql` and `db/205_verify_subscription_audit.sql`, run by Martin in dev and prod on 20 November
2026, then `cma.subscription_audit_of` run by him in prod (`docs/ingest/PROD_RUNBOOK.md` Phase 18). This note was written
down by Claude Code on 20 November 2026 from Martin's report in the session; the values are his, except where a line says
it comes from the subscription app itself (counts and dates only, read by Claude Code through the app's read tools). The
audit's own output, `audit.txt`, is not in this folder: Martin adds it once `node tools/check-records.mjs` passes on it and
he has decided that its volumes may be public while the repository is (Phase 18, step 18.5). Counts, codes and dates only:
no key, no secret, no personal data, no subscription or customer id. A store is named by its market.

## Findings and outcomes

| # | Check | Finding (Martin's report) | Outcome |
|---|---|---|---|
| 1 | `status_mix`, `orphan_events` | GB: 128 active subscriptions with `source_deleted_at` set, and 121 subscriptions with events the CMA never held; NL: 10. Three sampled subscriptions were returned by the app by id, status active. The app's analytics: 3,498 active in GB, against the CMA's 3,304 | A defect in Part A's full read: it sent no sort, so the app paged on `createdAt` alone and its cursor held `createdAt` alone; migrated subscriptions share one `createdAt`, so a page boundary inside the tie skipped the rest of it, and the final step marked them missing. Fixed in addition 0009zc (`206`/`207` and the ingest of this PR): the list sorts on `createdAt` and `id`, and a subscription is marked missing only when the app does not return it by id either (`missing_confirmed`, `missing_reappeared`). Proved by `ingest/verify/juo-flow.mjs` C3b and E4 to E6. To be confirmed in prod by the full read after the deploy and the audit again (Phase 18) |
| 2a | `events_by_month` | IE reads `fail`: its subscriptions are all paused or ended | A rule of the audit, not a defect of the mirror: a paused or ended subscription renews nothing. 0009zc holds a month only while a subscription that renews was held, so IE has no hole |
| 2b | `events_by_month` | DK's 2026-07 with 0 events was not flagged although DK holds subscriptions | Correct as built: DK held no subscription in July 2026. From the app (its analytics, and the creation and cancellation dates of DK's oldest subscriptions; counts and dates only): 3 subscriptions purchased in June 2026, all canceled within June; the next purchases in August (4); renewals from September |
| 3 | `billing_link` | DE 17 and NL 62 unlinked chargebacks | The app's analytics show every purchase carries a store order (NL 684 of 684 purchases, DE 795 of 795), but the CMA's adapter kept a renewal's order only, so the CMA's purchases carry none. 0009zc: a purchase keeps its order in `raw` (`orderId`) from now on (held purchases stay without, the events table being append-only), and the audit links a chargeback or refund through a purchase's order (purchase order), through a store order of kind First (first order) or another store order (other store order) of a customer with a subscription. For B39c C.2: the same links |
| 4 | `instruments` | NL holds one `other` that is not BACS | Open: its type name is in the full read's log line after the backfill (`instrumentUnknownTypes`, Phase 18); a code is added in a later PR only if it is a real instrument |
| 5 | `status_chain` | DE 4 and NL 1 `active>paused` | `explain`. A pair reads the latest status event's status, then the subscription's: `active>paused` is a subscription the app now holds paused whose latest status event moved it to active, i.e. a pause that began on its date without a paused event (a pause that ended on its date without a resumed event would read `paused>active`). 0009zc's expected text says so |

The other checks' values per store are in `audit.txt` once Martin adds it.
