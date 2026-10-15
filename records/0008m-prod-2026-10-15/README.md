# Addition 0008m in prod, 15 October 2026

Brief B17a (email activity data model, amended with B17b's database half; PR #135), steps 5 and 6
of `docs/b17a-email-data/MORNING_RUNBOOK.md`, run by Martin on 15 October 2026 in p4a-cma-prod
(cma-prod-pg), connected as `martin@pulse4all.com`, after dev (`records/0008m-dev-2026-10-15`).
Written down by Claude Code at Martin's request from his report of the run, as `records/0008l-*`
were (PR #131); the values below are his. Ids, counts, dates and times only: no key, no secret, no
hash and no personal data. The psql outputs of the run are not in this folder.

## Before the migration

- Point-in-time recovery on (`True`), 7 days of logs.

## Database (step 5)

| Script | What | Result |
|---|---|---|
| `68_email_activity.sql` | the addition | ends `INSERT 0 1`, `COMMIT`, `RESET` |
| `68_email_activity.sql` | the addition again | ends `INSERT 0 0`, `COMMIT`, `RESET` |
| `33_verify_intake_core.sql` | rerun | 2 PASS rows |
| `35_verify_telephony.sql` | rerun | 2 PASS rows |
| `41_verify_lead_metrics.sql` | rerun | 2 PASS rows |

`cma.schema_migration`: `0008m` applied at 2026-10-15T12:42:01Z. `69` and `53` refuse prod (they
write throwaway tenants) and ran in dev only.

## Read-only check (step 5)

Studio on cma-prod-pg, the runbook's read-only queries:

| Read | Value |
|---|---|
| The four `email.%` settings | as in dev: `email.market_order` `text` `contact,form,record,inbox`, `email.no_response_days` `integer` `5`, `email.reply_target_minutes` `integer` `240`, `email.start_date` `text` empty |
| Emails, threads, inboxes | 0, 0, 0 |

Connections of `pulse4all-subscriptions`, unchanged by 0008m, all `active`: `aircall` `telephony`,
`hubspot` `crm` and 14 `shopify` `commerce`.

The email start per tenant (`email.start_date` empty, so it follows `intake.start_date`):

| Tenant | `email_start` | `intake_start` |
|---|---|---|
| `pulse4all-invest` | 2026-10-01 | 2026-10-01 |
| `pulse4all-subscriptions` | 2026-10-01 | 2026-10-01 |

Contacts (counts only):

| `with_country` | `from_slot_1` | `from_fallback` |
|---|---|---|
| 1 | 1 | 0 |

Data-quality check `contact_country_fallback`: 0 findings for `pulse4all-invest` and 0 for
`pulse4all-subscriptions`.

## Merge (step 6)

- PR #135 squash-merged as `4c1520a`.
- No build: nothing under `web/` or `cloudbuild.yaml` changed.

## Not in the report

- `applied_by` of the `0008m` row in prod.
- The connections of `pulse4all-invest`.
