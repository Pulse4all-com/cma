# Addition 0009ze in prod, 21 November 2026

Addition 0009ze, the subscription facts (`Pulse4all-com/cma#303`, brief B39c): `db/210_subscription_facts.sql` and
`db/211_verify_subscription_facts.sql`, run by Martin on cma-prod-pg with `run_migration` from the Terminal on 21 November
2026, after the dev run of the same day (`records/0009ze-dev-2026-11-21`); then the merge, the deploys, the one-time fill
of purchases' store orders and the timing scripts (`docs/ingest/PROD_RUNBOOK.md` Phase 20). The six output files in this
folder are his run (commit `55549e54`; records clean); everything else below comes from his report. This note was written
down by Claude Code on 21 November 2026 at Martin's request, from his report and those files, and the values are his.
Verdicts, times, months and ids of builds only: no key, no secret and no personal data, and no commercial volume (Decision
log, 20 Nov 2026) but the first refresh's row count, which Martin let in: the outputs of 20.0, `124` and `131` are not in
this folder. A store is named by its market.

## 20.0 The stores' migration months and where their rates start

Months and kinds only. The default migration share of 5 % is kept.

| Store | Months with migrated events | Rates start |
|---|---|---|
| AT | none | 2026-06 |
| BE | 2025-06 migration; 2025-09 straggler | 2025-07 |
| DE | 2025-06 migration | 2025-07 |
| DK | none | 2026-07 |
| FR | 2025-06 migration | 2025-07 |
| GB | 2025-04 before the bulk; 2025-05 migration; 2025-08 straggler | 2025-06 |
| IE | none | 2026-07 |
| NL | 2025-05 migration; 2025-06 and 2025-08 stragglers | 2025-06 |
| SE | 2025-06 migration | 2025-07 |

## 20.3 The migration, its verifies and the seed

`124_time_flash.sql` before 210: 23 ok; overview subscriptions 20.9 ms, list subscriptions 525.9 ms; the slowest row
644.5 ms (list open_tickets).

| Step | File | Result |
|---|---|---|
| `210_subscription_facts.sql` | `210.txt` | `INSERT 0 1`: addition 0009ze recorded; `COMMIT` |
| `211_verify_subscription_facts.sql` | `211.txt` | `REFUSED`: 7 PASS, 1 FAIL. A1 to A7 PASS; block B FAIL because prod has no dev seed, as expected |
| `211_verify_subscription_facts.sql`, provoked | `211-provoked.txt` | `REFUSED`: 0 PASS, 8 FAIL |
| `119_verify_subscriptions.sql` again | `119-rerun.txt` | `REFUSED`: 7 PASS, 2 FAIL (B and Z1, no dev seed), as on 20 November (`records/0009zc-prod-2026-11-20`) |
| `173_verify_active_customers.sql` again | `173-rerun.txt` | `PASS`: 42 PASS, 0 FAIL, 2 info |
| `185_verify_active_device_bands.sql` again | `185-rerun.txt` | `FAIL`: 13 PASS, 1 FAIL (D2, below) |

A7 PASS: the payment state equals the old one (118's and 148's) row for row in every tenant, except where Charged back or
Awaiting payment applies.

185's one FAIL is D2: 21 stored below-the-fold documents of Customers → Active differ from a fresh computation and from
172's document. Martin's report: 119, 173 and 185 as expected.

What D2's FAIL is (Martin's question of 21 November 2026; worked out by Claude Code the same day from the verify and this
file, and reproduced on a local database, not in prod): neither a dev-seed expectation that cannot hold in prod, nor a
defect of 210. It is a gap in the verify. 185 forces a refresh of the take inside its rolled-back step and then reads the
stored documents, without looking at the refresh's answer. While the minute job holds the take's lock, the forced refresh
answers `running` and writes nothing, so D2 reads the committed documents: on 21 November those were stored before 210,
with four payment states, against a fresh computation with 210's six. R1 then passes on two refreshes that both did
nothing, as it does in this file.

- Locally, with Charged back and Awaiting payment subscriptions present and the refresh running: 185 reads 14 PASS, D2
  0, 0, 0. So the new payment states do not break D2.
- Locally, with the documents as before 210 and another session holding the take's lock: 185 reads this file's rows
  exactly (R1 PASS, D1 PASS, D2 21, 0, 21; 13 PASS, 1 FAIL).
- The file does not print the refresh's answer, so this is the reading that fits every row, not an observation in prod.
  The rerun of 185 in prod with the next addition confirms it by reading PASS. D2 passed in prod on 14 November
  (`records/0009r-prod-2026-11-14`).

Proposed follow-up: 185 reads `skip` when its refresh did not run, as 173's E4 does.

Pulse4all's propositions (the last block of `db/02_seed_pulse4all.sql`), in Studio on cma-prod-pg: refused without
`set role cma_owner` (`permission denied for schema cma`); with it, `subscriptions.propositions` reads
`hs1,frx,buurt_aed,outdoor`.

## 20.4 The merge and the deploys

The first ingest deploy ran before the merge, with `HEAD` at `8876e222`: a redeploy of the image `1c6e651a`, harmless.
`#303` was squash-merged as `fb704e3d`. The deploy after the merge put the service on `fb704e3d`, but the jobs stayed on
`1c6e651a`, so the first purchase-order backfill (20.5) exited 2 with `backfill usage`. A second deploy put the service
(revision `cma-ingest-00027-gvj`) and the ten jobs on `fb704e3d`.

The web image is tagged with Cloud Build's `SHORT_SHA`, seven characters (`fb704e3`), not eight;
`cma-refresh-active-customers` runs on `web:fb704e3`.

The first facts refresh, at 05:58 UTC: `facts_refreshed` true, 74,283 fact rows, 8,973 ms. Later runs: `reason=fresh`. In the database log
the refresh runs about every 15 minutes, and its insert into `cma.renewal_outcome` takes about 3 s.

## 20.5 The one-time fill of purchases' store orders

After the second deploy every store's purchases were filled (DE all but one, a purchase bought after the deploy).

## 20.8 The timing scripts after 210

`124_time_flash.sql` after: overview subscriptions 21.9 ms (20.9 before); list subscriptions 684.5 ms (525.9 before;
budget 800); the slowest row 793.8 ms (list open_tickets, 644.5 before). 210 does not touch open_tickets: the database
was busier during the second run.

`131_time_all.sql`: the first run lost its connection at line 806; Cloud SQL's log shows no crash and no restart, so the
loss was on the client's side. The second run took 2 min 13 s: 254 ok, 40 FAIL.

| Row | Time | Budget | Note |
|---|---|---|---|
| current takes refresh | 2,124.6 ms | 5,000 ms | 7,868 ms on 20 November (`records/0009za-prod-2026-11-20`) |
| active customers refresh | 13,434 ms | 15,000 ms | |
| active customers inputs markers | 964.9 ms | 300 ms | FAIL; 440.7 ms on 20 November; new with 210 |
| subscription facts refresh | 10,156 ms | 3,000 ms (proposed) | FAIL; new with 210 |
| subscription variants list | 69.7 ms | | |
| active customers (set) | 830.1 ms | | FAIL; to be checked |
| active rest | 56.7 ms | 50 ms | FAIL; to be checked |

The 40 FAILs: 2 new with 210 (the inputs markers and the facts refresh), 2 to check (active customers (set) and active
rest), 1 known (the poll `team now`, which failed on 6 November too) and the 35 report reads of backlog items CMA-101,
CMA-114 and CMA-115.

## Open

- 20.6, the hand check of the original start, and 20.7, the variant mapping per store, are still open with Martin.
- `cma.active_inputs_key_of` at 964.9 ms against 300, the facts refresh at 10,156 ms against the proposed 3,000, Flash's
  subscriptions list at 684.5 ms against 525.9 before 210, and the two Customers → Active rows above go into the next
  addition (0009zf, the follow-up of brief B39c).
