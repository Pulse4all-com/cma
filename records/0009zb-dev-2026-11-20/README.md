# Addition 0009zb in dev, 20 November 2026

Addition 0009zb, the subscription audit and BACS direct debit (`Pulse4all-com/cma#301`, brief B39 continued, Part
B39a2): `db/204_subscription_audit.sql` and `db/205_verify_subscription_audit.sql`, run by Martin on cma-dev-pg with
`run_migration` from the Terminal on 20 November 2026, then the audit in Studio (`docs/ingest/PROD_RUNBOOK.md` 18.1 and
18.2). The output files in this folder are his run (commit `ef38bc68`); this note was written down by Claude Code on 20
November 2026 at Martin's request, from his report and those files, and the values are his. Ids, counts, codes and verdicts
only: no key, no secret and no personal data.

## The migration and its verifies (18.1)

| Step | File | Result |
|---|---|---|
| `204_subscription_audit.sql` | `204.txt` | `INSERT 0 1`: addition 0009zb recorded; `COMMIT` |
| `205_verify_subscription_audit.sql` | `205.txt` | `PASS`: 15 PASS, 0 FAIL |
| `205_verify_subscription_audit.sql`, provoked | `205-provoked.txt` | `PROVOKED, NOT A PASS`: 0 PASS, 15 FAIL |
| `203_verify_subscription_lines.sql` again | `203-rerun.txt` | `PASS`: 26 PASS, 0 FAIL |
| `119_verify_subscriptions.sql` again | `119-rerun.txt` | `PASS`: 23 PASS, 0 FAIL |

## The audit in dev (18.2)

The first try in Studio failed with `permission denied for schema cma`: the statements ran in separate tabs, and Studio
does not carry `set role cma_owner` from one tab to another. The four statements together, in one tab and one Run, worked.
On dev's sparse seed only `no_lines` and `events_by_month` read `fail`, as 18.2 expects (the seed has no lines and gaps in
its months). The audit's output is not in this folder (Decision log, 20 Nov 2026: the audit's raw output is kept outside
the repository).

The prod run of the same day is in `records/0009zb-prod-2026-11-20`.
