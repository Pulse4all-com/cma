# Attempts per deal (0008y) in dev, 19 October 2026

Addition 0008y (`92_attempts_per_deal.sql`, `93_verify_attempts_per_deal.sql`), steps 1 to 5 of
`docs/attempts-2026-10/RUNBOOK.md`, run by Martin on 19 October 2026 from 21:15 to 21:40 Amsterdam time in p4a-cma-dev
(cma-dev-pg). Written down by Claude Code on 20 October 2026 at Martin's request from his report; the values are his.
Ids, counts, hashes and times only: no key, no secret and no personal data.

## The lead reads before and after `92` (step 1)

| Read | Rows | `rows_md5` | `newest_change` |
|---|---|---|---|
| `speed_to_lead_rows` | 2/2 | `9e0891ded84a310c500183387111b297` | `05:46:40.203888Z` |
| `lead_to_order_rows` | 2/2 | `bf3d094aa002b4b5a1aa5260dd38e720` | `05:46:40.203888Z` |

Identical before and after `92`, `newest_change` included.

## `92` twice (step 1)

The fingerprint was identical after the first and the second run: 466 functions, `functions_md5`
`f0330af792eb162994178be386e63bcd`, 120 views.

## The verifies (steps 2 and 3)

| Script | Result |
|---|---|
| `93_verify_attempts_per_deal.sql` | 25 `PASS` |
| `93` with `verify.provoke` true | 25 `FAIL` |
| `41_verify_lead_metrics.sql` | `PASS` for both tenants |
| `61_verify_inbound_service.sql` | 20 `PASS` |
| `69_verify_email_activity.sql` | 29 `PASS` |
| `73_verify_follow_up.sql` | 21 `PASS` |
| `75_verify_forms_reporting.sql` | 24 `PASS` |
| `77_verify_audit_hardening.sql` | 14 `PASS` |
| `81_verify_follow_up_snapshot.sql` | 19 `PASS` |
| `83_verify_email_reports.sql` | 26 `PASS` |
| `85_verify_first_orders.sql` | 26 `PASS` |
| `89_verify_callbacks_kept.sql` | 15 `PASS` |
| `91_verify_report_speed.sql` | 12 `PASS`, B8 alone `FAIL` |

`91` in detail:
- Studio stopped it at 300 seconds. From the Terminal it ran for 7 minutes.
- B8 failed alone, on dev's shared core: the email reads took 1,267 to 1,968 ms; `first_orders_of` 482 ms.
- B9 passed.

The runbook now runs `91` and any long verify from the Terminal (`docs/attempts-2026-10/RUNBOOK-0008z.md`; `docs/RUNBOOK.md`).

## `03` again (step 4)

`pulse4all-subscriptions | email,orders,attempts`.

## The data map (step 5)

81 tables, 111 views, latest migration `0008y`, pushed as `b0be6e6`.

## Not in the report

- The date of `newest_change`, which the report gives as a time only.
- The outputs themselves; no file was pushed with them.
