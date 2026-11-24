# Addition 0009zq in prod, 24 November 2026

Addition 0009zq, speed to lead in one function (`Pulse4all-com/cma#316`, brief B40a): `db/234_speed_to_lead_one.sql` and
its verify `db/235_verify_speed_to_lead_one.sql`. Martin ran them in prod (cma-prod-pg) on 24 November 2026, before the
merge, so the new web never met the old database. Then the verifies that read what 234 re-creates and runs in prod, and
`diagnose_0009zq_prod.sql` (this folder) on the two FAILs.

This note was written down by Claude Code on 24 November 2026 at Martin's request, from his report, and the values are
his. No output file of his is in this folder; `diagnose_0009zq_prod.sql` is the script he ran. Counts, keys, market codes
and times only: no key, no secret, no personal data.

## The migration and its verify

| Script | Result |
|---|---|
| `234_speed_to_lead_one.sql` | `COMMIT` |
| `235_verify_speed_to_lead_one.sql` | `PASS 0009zq`; V13: 12,064 rows, 0 differ |

## The verifies that run in prod

| Verify | Result |
|---|---|
| `41_verify_lead_metrics.sql` | PASS |
| `14_verify_tenant_settings.sql` | PASS |
| `33_verify_intake_core.sql` | PASS |
| `225_verify_subscription_rates_start.sql` | PASS, block A only |
| `179_verify_job_reads.sql` | FAIL: `E6 flash_findings_compute_of (pulse4all-subscriptions) \| FAIL \| 8230 rows now against 8230 before: 3 only now, 3 only before` |
| `191_verify_follow_up_clock_at_read.sql` | FAIL: `E4 a minute of office hours moves nothing in the stored row but the day counts and the state words (pulse4all-subscriptions) \| FAIL \| 2026-11-25 11:06 to 11:07 UTC, 1171 items: 1 with another key moved; rows a refresh writes: 1684 as 0009o stored them, 2 now (0 state changes, 0 places moved, 0 day counts)` |

Both FAILs were in prod only; dev was clean.

## The diagnostic

`diagnose_0009zq_prod.sql`, run from the Terminal for pulse4all-subscriptions: one transaction at REPEATABLE READ (one
snapshot), rolled back.

- **E4:** the same: 1,163 items, 0 moved. Under one snapshot the minute moves no other key: 191's FAIL came from data
  written between its two statements.
- **E6:** 6 rows differ, all of check `source_figure_gap`, where 214's `cma.flash_findings_compute_of` sets the market
  (DE, FR, NL) and 179's old copy (132's text) says unknown; the pairs differ in market, and in connection id and value
  where two figures pair across connections. The old copy does not map the object type `source_figure`, which 214 added.
- **Writes in the 30 minutes before the run** (the audit log, the tenant): `crm_call` 153, `telephony_call` 133,
  `commerce_customer` 217, and more.

## The conclusion

0009zq is clean: no function change. Neither FAIL follows from 0009zq: no function `cma.flash_findings_compute_of` reads
is one 234 re-creates, and the open leads' minute moves nothing under one snapshot. The verifies are edited
(`Pulse4all-com/cma#316`, after this run): 179's E6 leaves out the object types the current function maps and its old
copy does not (today `source_figure`, check `source_figure_gap`, verified by 211 and 215) and names them in its row, as
E5 does since 21 November 2026, and its comparison reads both sides in one statement; 191's E4 computes both instants in
one statement. Both are to be run again in prod from the branch.
