# Addition 0008m in dev, 15 October 2026

Brief B17a (email activity data model, amended with B17b's database half; PR #135), steps 2 to 4 of
`docs/b17a-email-data/MORNING_RUNBOOK.md`, run by Martin on 15 October 2026 in p4a-cma-dev
(cma-dev-pg), connected as `martin@pulse4all.com`. Written down by Claude Code at Martin's request
from his report of the run, as `records/0008l-*` were (PR #131); the values below are his. Ids,
counts, dates and times only: no key, no secret and no personal data. The psql outputs of the run
are not in this folder.

## Database (step 2)

`run_migration dev 68_email_activity.sql 69_verify_email_activity.sql` with `33`, `35`, `41` and `53`:

| Script | What | Result |
|---|---|---|
| `68_email_activity.sql` | the addition, first run | rc=0; ends `INSERT 0 1`, `COMMIT`, `RESET` |
| `69_verify_email_activity.sql` | the verify | last check `B22 tenant isolation for contacts, slots and the fallback check, also against the owner's view \| PASS`; verdict `PASS`, `29 PASS, 0 FAIL`, `(30 rows)` |
| `69_verify_email_activity.sql` | the verify with `verify.provoke` true | 30 `FAIL` lines; verdict `PROVOKED, NOT A PASS`, `0 PASS, 29 FAIL` |
| `33_verify_intake_core.sql` | rerun | 2 PASS rows |
| `35_verify_telephony.sql` | rerun | 2 PASS rows |
| `41_verify_lead_metrics.sql` | rerun | 2 PASS rows |
| `53_verify_sources_configuration.sql` | rerun | 17 PASS rows |
| `68_email_activity.sql` | the addition again | ends `INSERT 0 0`, `COMMIT`, `RESET` |

## Read-only check (step 3)

Studio on cma-dev-pg, the runbook's read-only queries:

| Read | Value |
|---|---|
| `cma.schema_migration` | `0008m` applied by `martin@pulse4all.com` |
| `email.market_order` | `text`, default `contact,form,record,inbox` |
| `email.no_response_days` | `integer`, default `5` |
| `email.reply_target_minutes` | `integer`, default `240` |
| `email.start_date` | `text`, default empty |
| Inboxes, channels, rules, emails, threads, events | 0, 0, 0, 0, 0, 0 |

Connections:

| Tenant | Adapter | Kind | Status |
|---|---|---|---|
| `pulse4all-subscriptions` | `hubspot` | `crm` | `active` |

Contacts (counts only):

| `with_country` | `from_slot_1` | `from_fallback` | `fallback_slots` |
|---|---|---|---|
| 2 | 2 | 0 | 0 |

## The data map (step 4)

- `docs/datamap/schema.json` from dev: `"latest_migration" : "0008m"`.
- The data map's check: 72 tables, 89 views, all described; `index.html` current.
- Pushed as `2903f53` on the pull request's branch (squashed into `4c1520a` at the merge, step 6 in
  `records/0008m-prod-2026-10-15`).

## Not in the report

- The time `68` ran in dev (`applied_at`).
