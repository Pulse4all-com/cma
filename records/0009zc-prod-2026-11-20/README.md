# Addition 0009zc in prod, 20 November 2026

Addition 0009zc, the Juo full read's guard and the audit's fixes (`Pulse4all-com/cma#301`, brief B39a2):
`db/206_subscription_full_read_guard.sql` and `db/207_verify_subscription_full_read_guard.sql`, run by Martin on
cma-prod-pg with `run_migration` from the Terminal on 20 November 2026, after the dev run of the same day
(`records/0009zc-dev-2026-11-20`); then the merge, the ingest deploy, a full read of every active store and the audit again
(`docs/ingest/PROD_RUNBOOK.md` 18.10 to 18.13). The output files in this folder are his run (commit `ef38bc68`); everything
else below comes from his report. This note was written down by Claude Code on 20 November 2026 at Martin's request, from
his report and those files, and the values are his. Ids, counts, codes and verdicts only: no key, no secret and no personal
data. A store is named by its market.

## 18.10 The migration and its verifies

| Step | File | Result |
|---|---|---|
| `206_subscription_full_read_guard.sql` | `206.txt` | `INSERT 0 1`: addition 0009zc recorded; `COMMIT` |
| `207_verify_subscription_full_read_guard.sql` | `207.txt` | `REFUSED`: 2 PASS, 1 FAIL. A1 and A2 PASS; block B FAIL because prod has no dev seed, as expected |
| `207_verify_subscription_full_read_guard.sql`, provoked | `207-provoked.txt` | `REFUSED`: 0 PASS, 3 FAIL |
| `205_verify_subscription_audit.sql` again | `205-rerun.txt` | `REFUSED`: 5 PASS, 1 FAIL (block B, no dev seed), as on 20 November (`records/0009zb-prod-2026-11-20`) |
| `203_verify_subscription_lines.sql` again | `203-rerun.txt` | `REFUSED`: 9 PASS, 2 FAIL (B and Z1, no dev seed), as on 20 November |
| `119_verify_subscriptions.sql` again | `119-rerun.txt` | `REFUSED`: 7 PASS, 2 FAIL (B and Z1, no dev seed), as on 20 November |

The command was pasted twice on one line, so 206 and 207 ran a second time:

| Step | File | Result |
|---|---|---|
| `206_subscription_full_read_guard.sql`, second time | `206-rerun.txt` | `INSERT 0 0` (0009zc already recorded); `COMMIT`, no error |
| `207_verify_subscription_full_read_guard.sql`, second time | `207-rerun.txt` | `REFUSED`: 2 PASS, 1 FAIL, as the first |

The second paste's three arguments named no script and produced two error files, which Martin deleted before the commit.

## 18.11 The merge and the ingest deploy

`#301` was squash-merged as `1c6e651a`. The ingest was deployed from `main`: revision `cma-ingest-00024-nzd`, health ok;
the ten jobs on the same image, schedules unchanged.

## 18.12 The full read of every active store

One execution, `ingest-backfill-kpgfs` (`--adapter juo --object subscription`).

| Store | GB | NL | FR | DE | BE | SE | AT | DK | IE |
|---|---|---|---|---|---|---|---|---|---|
| `subscriptionsRead` | 4,537 | 1,504 | 227 | 1,174 | 149 | 193 | 59 | 13 | 6 |
| the dry run of 20 November (`fetched`, `records/0009za-prod-2026-11-20`) | 4,224 | 1,487 | 226 | 1,174 | 149 | 193 | 59 | 13 | 6 |

`rereadById` 0 in every store: the list sorted on `createdAt` and `id` left out no present subscription.
`instrumentUnknownTypes` empty in every store but NL, `{manual: 1}`: one NL subscription pays by an instrument Juo calls
`manual`, stored as other (docs/open-decisions.md).

## 18.13 The audit again

The audit's raw output is not committed: Martin keeps it outside the repository, in `~/cma-audit` (Decision log, 20 Nov
2026). Verdicts and causes only.

| Check | Result | Cause |
|---|---|---|
| `status_mix` | missing 0 in every store | The skipped ties of the first audit are read (`records/0009zb-prod-2026-11-20`, finding 1) |
| `status_mix` against Juo's own counts of 20 November (active plus failed) | GB equal; NL 2 apart; DE 4 apart | Juo's snapshot is from earlier in the day; the difference is that day's renewal run |
| `orphan_events` | 0 in every store | as `status_mix` |
| `instruments` | GB: BACS (`bacs_direct_debit`) on 306 subscriptions | 0009zb's code, applied by the full read |
| `billing_link` | still unlinked: DE 17 and NL 52; NL 10 more on another store order | Older chargebacks on first orders, from before the CMA's order history; purchases stored before 0009zc carry no order id (docs/open-decisions.md) |

The undercount of GB and NL is closed: the full read of 20 November 2026 brought both to Juo's own count within the day's
movement (docs/open-decisions.md).
