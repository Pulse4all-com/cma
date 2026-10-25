# Definitions step 1 (0008zc) in dev and prod, 25 October 2026

Addition 0008zc (`100_definitions_calls.sql`, with `101_verify_definitions_calls.sql`; `Pulse4all-com/cma#189`,
squash-merged as `7988a76`), steps 1 to 14 of `docs/definitions-2026-10/RUNBOOK.md`, run by Martin on 25 October 2026
in p4a-cma-dev (cma-dev-pg) and p4a-cma-prod (cma-prod-pg). Written down by Claude Code on 25 October 2026 at Martin's
request from his report; the values are his. Ids, counts, hashes, settings, tag names and times only: no key, no
secret and no personal data.

## Dev

### `100` three times (step 1)

`100` ran from the Terminal (`psql -f`) rather than pasted into Studio, three times: `INSERT 0 1`, then `INSERT 0 0`
twice.

| Point | Functions | `functions_md5` | Views | Tables | Settings | Additions |
|---|---|---|---|---|---|---|
| Before | 515 | `3a2fc08f…` | 126 | 85 | `attempts.reached_min_talk_seconds=30 telephony.connected_min_seconds=10` | `0008zb` |
| After `100`, and after the rerun | 519 | `b88593e0f578623451c602baadb1dc24` | 126 | 85 | `calls.conversation_min_talk_seconds=30 telephony.connected_min_seconds=0` | `0008zb 0008zc` |

The rerun left the fingerprint as the first run had. `functions_md5` before was reported by its first eight
characters, which are those of dev's md5 after `98` on 21 October 2026 (`../../funnel-2026-10/records/funnel-dev-2026-10-21.md`).

The tenants' own values: `telephony.connected_min_seconds` 0 for both Pulse4all tenants; no row for
`attempts.reached_min_talk_seconds`; no tenant has its own `calls.conversation_min_talk_seconds`, so the default 30
applies.

### `101` normal and provoked (step 2)

| Script | Result |
|---|---|
| `101_verify_definitions_calls.sql` | 18 of 18 `PASS` |
| `101` with `verify.provoke` true | 0 `PASS`, 18 `FAIL` |

### The earlier verifies (step 3)

| Script | Result |
|---|---|
| `63_verify_calls_overview.sql` | 19 `PASS` |
| `95_verify_attempts_for_sales.sql` | 36 `PASS` |
| `41_verify_lead_metrics.sql` | `PASS`: no verdict line, exit 0 |
| `75_verify_forms_reporting.sql` | 24 `PASS` |
| `83_verify_email_reports.sql` | 26 `PASS` |
| `85_verify_first_orders.sql` | 26 `PASS` |
| `93_verify_attempts_per_deal.sql` | 25 `PASS` |
| `91_verify_report_speed.sql` (Terminal) | 12 of 13 `PASS`: B8 alone `FAIL`, the email reads 1.0 to 1.5 s, the known dev-only failure on `db-g1-small`'s shared core (as on 19 October 2026, `records/perf-dev-2026-10-19`), unchanged by `100` |
| `99_verify_funnel.sql` (Terminal), in the same loop right after `91` | 32 of 33 `PASS`: C2 `FAIL`, its page reads 1001 to 1013 ms right after `91`'s fixture |
| `99` on its own | 33 of 33 `PASS`, C2 152 to 242 ms |

### The tag meanings (step 4)

Not applicable: dev has no telephony connection, so it has no tag to give a meaning, and Conversation runs on talk
time alone there.

### The data map (step 5)

Refreshed from dev at 0008zc on the branch (`eca98e7`): 85 tables, 117 views.

## The drift check before (step 6)

Dev 519 lines, prod 515. The diff listed only the functions `100` creates or replaces, plus `cma.setup_tenant_table`,
which differs by one code comment only (`-- from an earlier draft`, `db/01_foundation.sql`): prod was built from `01`
before that comment existed.

## Prod

### Point-in-time recovery and `100` twice (step 8)

- Point-in-time recovery: `True`; the recovery point written down: `2026-10-25T07:08:45Z`.
- `100` twice from the Terminal: `INSERT 0 1`, then `INSERT 0 0`.

| Point | Functions | `functions_md5` | Views | Tables | Settings | Additions |
|---|---|---|---|---|---|---|
| Before | 515 | `718c6b7607e9704228d6b3d3d4c1da53` | 126 | 85 | the old settings, as dev's before | `0008zb` |
| After `100`, both runs | 519 | `f17da3d69d399f3e1204bdd3fa0eca28` | 126 | 85 | the new settings, as dev's after | `0008zb 0008zc` |

The second run left the fingerprint as the first had; Martin checked it before the merge. `functions_md5` before is
prod's after `98` on 21 October 2026 (`../../funnel-2026-10/records/funnel-prod-2026-10-21.md`). The counts equal
dev's at both points; the drift check after names the one function whose definition differs.

The tenants' own values: `telephony.connected_min_seconds` 0 for both Pulse4all tenants; no row for
`attempts.reached_min_talk_seconds`; no tenant has its own `calls.conversation_min_talk_seconds`.

### Merge and deploy (step 9)

- Merged as `7988a76` (`Pulse4all-com/cma#189`); the `cma-web-main` build of `7988a76`: `SUCCESS`, created 08:12:09
  Amsterdam time; revision `cma-web-00088-66x` serving 100 % of traffic.
- Dev on `web:7988a76` (`docs/RUNBOOK.md`, section 4), health ok.

### The timings as `cma_app` (step 10)

1 to 25 October 2026, best of three, as `martin@pulse4all.com`:

| Read | ms |
|---|---|
| `calls_overview` | 565.6 |
| `calls_per_person` | 564.7 |
| `attempts_per_deal_page` | 369.7 |
| `first_orders_page` | 285.4 |
| `calls_per_person_tags` | 279.9 |
| `calls_tag_use` | 120.4 |

Every read under 1000 ms. The two Calls reads at about 565 ms are gap D31 in `docs/definitions.md` (Gaps against the
definitions), for step 2.

### The tag meanings (step 11)

On Configuration → Sources → the Aircall connection → Tags, every "… Not Reached" tag set to Not reached.
`1.4 Sales - Wrong Number*` and `1.5 Sales - Incorrect Data*` stay None until 0008zd (incorrect data).

### The check against Aircall (step 12)

Friday 23 October 2026, Europe/Amsterdam, Aircall Analytics filtered on the 46 numbers:

| Figure | Aircall | CMA |
|---|---|---|
| Calls | 199 | 200 |
| Inbound | 20 | 21 |
| Outbound | 179 | 179 |
| Answered inbound | not in the report | 6 |
| Connected | 160 | 160 |
| Not connected | 19 | not a row of step 12 |
| Connected rate | 89.4 % | 89.4 |
| Conversations | not readable here (below) | 42: 36 outbound, 6 inbound |
| Talk time, total | not in the report | 10,308 s |
| Talk time, average | 1 min 2 s | 62.1 s |
| Untagged | 12.1 % | 25 |

- Outbound, Connected and the Connected rate are identical.
- The one extra call is a missed inbound call on UK Sales at 2026-10-24 00:05 Amsterdam time (23:05 London time),
  which the CMA dates by its line's zone, so on 23 October: gap D4, not new. Untagged 25 of 200 includes it; without
  it, 24 of 199 is Aircall's 12.1 %.
- Conversation cannot be read in Aircall here: the Outbound view has no in-call-time filter on this account. It is
  covered by identical inputs (connected, answered, talk time, tags) and by `101` B1 to B6 in dev.
- The scope: Aircall's preset "Subscriptions" filters on 14 users, which drops missed calls without a user. The
  comparable scope is the 46-number filter: the account's 57 numbers less 8 Invest and 3 inactive.

### The hand checks (step 13)

Checks 1 to 6 pass.

Found outside step 1:
- Reports → First orders shows "History from Wed 30 December 2026", a date in the future; `100` does not touch the
  history start.
- Reports → Attempts per deal still shows "Attempts without an outcome": gaps W12 and W13, step 4.

## The drift check after (step 14)

519 lines on both instances. The only line that differs is `cma.setup_tenant_table`, by the comment, as before.

## Not in the report

- Step 0 (the build and the migration check) and step 7 (Kira and Arno told).
- The times of day of the dev runs; in prod only the recovery point and the build's creation are given.
- Dev's `functions_md5` before in full.
- The drift diffs' lines themselves.
- Aircall's answered inbound calls and total talk time.
- The outputs themselves; no file was pushed with them.
