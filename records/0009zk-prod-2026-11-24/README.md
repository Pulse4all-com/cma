# Addition 0009zk in prod, 23 and 24 November 2026

Addition 0009zk, Juo's legacy status moves (`Pulse4all-com/cma#311`): the adapter reads the old update shape, and
`db/222_subscription_moves_entry.sql` gives a subscription its entry status from its first status event. In prod Martin ran
`docs/ingest/PROD_RUNBOOK.md` Phase 23, from the deploy (23.4) through the events read again (23.5) to the acceptance
(23.9), on 23 and 24 November 2026. It is the Step 0 chosen on 23 November 2026
(`docs/analyses/2026-11-23-subscriptions-incomplete-months.md`).

This note was written down by Claude Code on 24 November 2026 at Martin's request, from his report, and the values are
his. No output file of his is in this folder. Counts, dates, ratios and times only: no key, no secret, no personal data, no
amount.

## 23.4 The deploy

The `cma-ingest` service and the `ingest-backfill` job run image `ed120308`.

## 23.5a The size first: GB's dry run

| What | Value |
|---|---|
| GB `status_changed` events held before the dry run | 4,635 |
| GB `status_changed` events the dry run kept | 11,104 |
| GB subscriptions before 28 January 2026 | 2,945 (about 2.2 legacy moves per subscription) |
| Read time | 1,236,565 ms |
| Failed, unreadable | 0, 0 |

## 23.5 The events again, every store

- **The execution.** `ingest-backfill-5t6sq` (`--adapter juo --object subscription_event --again`) succeeded at 2026-11-23 21:38:49Z.
- **The poll.** Paused at 22:05 and resumed at 05:40, later than planned.
- **The vacuum** of `cma.subscription_event` is done. 213's I1 still read "10 % or more" right after it, while the poll was writing; it is to be read again.

`status_changed` events held after the run, with those before 28 January 2026 in brackets:

| Store | After (before 28 Jan 2026) |
|---|---|
| AT | 9 (0) |
| BE | 132 (39) |
| DE | 1,330 (318) |
| DK | 6 (0) |
| FR | 218 (63) |
| GB | 11,105 (6,452) |
| IE | 9 (0) |
| NL | 1,587 (447) |
| SE | 102 (18) |

213 in prod:
- **Main's `213_verify_subscription_facts_speed.sql`** reads A3 FAIL `:digests`.
- **The 213 of `Pulse4all-com/cma#308`** reads A3 PASS: 5 PASS, 1 FAIL (block B refused for want of the dev seed), 2 info.

Main's FAIL is its 213 lacking 224's floor part (0009zl, #308, in prod with its seed since 23 November), not a data fault
(PROD_RUNBOOK, the note under 23.5).

## 23.6 The moves without a named previous status

| Store | `unnamed_moves` |
|---|---|
| BE | 39 |
| DE | 318 |
| FR | 63 |
| GB | 6,469 |
| NL | 448 |
| SE | 18 |
| AT, DK, IE | 0 |

`repeats_other_day` is 0 in every store except GB, which reads 2.

## 23.7 The facts refresh

There is no "before" run.

| Step | ms |
|---|---|
| Facts refresh, total | 7,983, against 10,000 (21 November 2026: 11,478) |
| months | 1,369 |
| outcomes | 4,175 |
| subscriptions | 1,646 |
| survival | 480 |
| inputs_key | 195 |
| device_units | 117 |

- **The take** was computed at 2026-11-24 04:50Z.
- **`131_time_all.sql`'s verdict:** 264 ok, 41 FAIL, 213 skip. The FAILs are outside this phase.

## 23.8 The rates' start months

- **`rate_start_month`:** 2026-06 for AT, BE, DE, FR, GB, NL and SE, and 2026-07 for DK and IE (0009zl's floor).
- **Migration months:** unchanged.

## 23.9 The acceptance (19.18 again)

**Failed:** every ratio reads 1.00, or both are 0.

**Churned before February 2026:** near 1, except:
- the migration months (BE, DE, FR, NL and SE in 2025-06);
- NL 2025-07 at 3.08;
- GB at 0.92 in October 2025, and 0.90 in December 2025 and January 2026.

**After February 2026:** the earlier high months now all read 1.00: GB September 2.79, SE September 1.67, DE September 1.64, NL September 1.39 and April 1.33, and SE May 2.00. DE May reads 0.91 and NL March 0.95.

**Accepted (Martin):** `Pulse4all-com/cma#308` can go on.

## 23.10 Finding: the churn moves still inferred

Inferred churn moves are left only in the months around the migration:
- BE, DE, FR and SE in 2025-06 (2, 6, 6 and 2);
- NL in 2025-06 (20 of 24) and 2025-07 (25 of 37).

The app ended those subscriptions around the migration without an event. They lie before the rates' floor; no action.
