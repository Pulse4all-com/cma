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

## The migration and its verifies (18.4)

Run by Martin on cma-prod-pg with `run_migration` from the Terminal; the output files in this folder are his run (commit
`ef38bc68`). This section and the two after it were added by Claude Code on 20 November 2026 at Martin's request, from his
report and those files; the values are his.

| Step | File | Result |
|---|---|---|
| `204_subscription_audit.sql` | `204.txt` | `INSERT 0 1`: addition 0009zb recorded; `COMMIT` |
| `205_verify_subscription_audit.sql` | `205.txt` | `REFUSED`: 5 PASS, 1 FAIL. A1 to A5 PASS; block B FAIL because prod has no dev seed, as expected |
| `205_verify_subscription_audit.sql`, provoked | `205-provoked.txt` | `REFUSED`: 0 PASS, 6 FAIL |
| `203_verify_subscription_lines.sql` again | `203-rerun.txt` | `REFUSED`: 9 PASS, 2 FAIL (B and Z1, no dev seed), as on 20 November (`records/0009za-prod-2026-11-20`) |
| `119_verify_subscriptions.sql` again | `119-rerun.txt` | `REFUSED`: 7 PASS, 2 FAIL (B and Z1, no dev seed), as on 20 November |

## The audit's output (18.5)

The audit's raw output holds commercial volumes (subscriptions per status, chargebacks per market) and the repository is
public, so it is not committed: Martin keeps it outside the repository, in `~/cma-audit` (Decision log, 20 Nov 2026). This
supersedes the first paragraph's and the last line's "once Martin adds it" above: `audit.txt` is not added to this folder.
This record gives each check's verdict and its cause, a finding as a direction or a share, and a comparison with Juo's
own count as equal or "n apart"; no count per status, per instrument or per market.

## The first audit's verdicts, every check

Verdicts as Martin reported them, per check: "ok everywhere", or ok with the stores named that read otherwise.

| Check | Verdict | Cause |
|---|---|---|
| `status_mix` | explain everywhere | Active subscriptions GB 194 apart and NL 12 apart from Juo's own active count, the CMA lower. The full read paged on `createdAt` alone and skipped the rows of a tie (finding 1 above); fixed by 0009zc |
| `no_lines` | ok everywhere | |
| `lines_histogram` | ok everywhere | |
| `line_currency` | ok everywhere | |
| `amount_vs_lines` | ok everywhere | |
| `variant_missing` | ok everywhere | |
| `events_by_month` | ok; IE fail | IE: all its subscriptions paused or ended, so no renewal is due (finding 2a). DK's July is ok: no subscription held then (finding 2b) |
| `orphan_events` | ok; GB explain | GB: events of subscriptions the CMA did not hold. Three sampled GB subscriptions "missing" in the CMA were returned active by Juo by id: the same skipped ties (finding 1); fixed by 0009zc |
| `status_chain` | ok; DE and NL explain | finding 5 above |
| `billing_kinds` | ok everywhere | Invoice events in GB, DE and NL only |
| `billing_link` | ok; DE and NL explain | finding 3 above |
| `after_chargeback` | ok everywhere | About two thirds of linked chargebacks moved to failed (NL, DE; also AT, BE and FR); some stayed active with nothing after (NL, DE, GB) |
| `migration_cycles` | ok everywhere | No migrated subscription has a store order: the CMA holds store orders from 1 October 2026 only, after the migration to Juo |
| `instruments` | ok; GB and NL fail | GB's `other` is BACS (`bacs_direct_debit` since 0009zb, applied at the next full read); NL's `other` is finding 4 above |
| `privacy` | ok everywhere | All six tables, and the three switched-off connections |
| `changes` | ok everywhere | |

The fixes are proved in prod by the full read and the second audit after 0009zc's deploy:
`records/0009zc-prod-2026-11-20`.
