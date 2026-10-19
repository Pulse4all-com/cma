# N19-A in prod, 19 October 2026

Night run N19-A, additions 0008t to 0008w: email reports, first orders, journeys and callbacks kept
(`Pulse4all-com/cma#170`, squash-merged as `997749c`), steps 5 to 7 of
`docs/night-2026-10-19/MORNING_RUNBOOK.md`, run by Martin on 19 October 2026 in p4a-cma-prod (cma-prod-pg, the
ingest service and its jobs, the Workspace), after dev (`records/n19a-dev-2026-10-19`). The migrations ran at
06:15 UTC, before the merge. Written down by Claude Code on 19 October 2026 at Martin's request from his report
and the outputs he pushed to this folder (`e8d3087`); the values are his. Ids, codes, counts, dates and times
only: no key, no secret and no personal data.

## Database (step 5)

| Script | File | Result |
|---|---|---|
| `82_email_reports.sql` | `82.txt` | ends `INSERT 0 1`, `COMMIT`, `RESET`; `UPDATE 0` (no stored engagement held an origin to fill: step 7's re-read brought them); notices only for the policies, triggers and checks that did not exist yet |
| `82_email_reports.sql` again | `82-rerun.txt` | ends `INSERT 0 0`, `COMMIT`, `RESET`; notices only for the objects that already exist |
| `84_first_orders.sql` | `84.txt` | `INSERT 0 5` (the five `attribution.*` settings); ends `INSERT 0 1`, `COMMIT`, `RESET` |
| `84_first_orders.sql` again | `84-rerun.txt` | ends `INSERT 0 0`, `COMMIT`, `RESET`; line for line the same as dev's `84.txt` |
| `86_journeys.sql` | `86.txt` | ends `INSERT 0 1`, `COMMIT`, `RESET` |
| `86_journeys.sql` again | `86-rerun.txt` | ends `INSERT 0 0`, `COMMIT`, `RESET` |
| `88_callbacks_kept.sql` | `88.txt` | ends `INSERT 0 1`, `COMMIT`, `RESET` |
| `88_callbacks_kept.sql` again | `88-rerun.txt` | ends `INSERT 0 0`, `COMMIT`, `RESET` |
| `02_seed_pulse4all.sql` after `86` | `02-after-86.txt` | the two tenants' `create_tenant` rows, `INSERT 0 0` twice, `DO` only; no notice, no error |
| `41_verify_lead_metrics.sql` again | `41-rerun.txt` | two tenant rows, each `PASS`: `pulse4all-invest` (0 lead deals, 0 called, 0 data-quality findings) and `pulse4all-subscriptions` (479, 347, 17,657) |

`83`, `85`, `87`, `89`, `69`, `73`, `75` and `81` are dev only; their runs are in `records/n19a-dev-2026-10-19`.

## Configuration (step 5), from Martin's report

- The HubSpot connection: `email_origin_property` `hs_engagement_source`, `email_inbox_copy_origins`
  `CONVERSATIONS`.
- The order pipeline: Self Serve (`3850599657`); its Closed Won stage (`5470463176`) `won | person`, set by hand.
- `reports.per_person` stays `email` (no `orders` in prod).

## The merge (step 6)

`997749c`. The hand checks in prod were made on `de12f43`, after the report speed merge of the same day
(`records/perf-prod-2026-10-19`).

## The ingest image and the re-reads (step 7), from Martin's report

After N19-B was live in prod: `cma-ingest` and its jobs on `ingest:509ec43`, which carries N19-A's ingest
changes too (`records/n19b-prod-2026-10-19`). The three re-reads ran with `--again`:

| Object | Fetched | Status |
|---|---|---|
| `contact` | 6,791 | succeeded |
| `crm_email` | 2,445 | succeeded |
| `inbox_thread` | 1,366 | succeeded |

What they filled:

| Read | Result |
|---|---|
| The engagements' origins | `CONVERSATIONS` 2,171 (the inbox copies, left out of the reports), none 216, `BCC_TO_CRM` 61, `EMAIL_INTEGRATION` 29 |
| Threads with a mailbox | 1,367 of 1,367 |
| Contacts with a creation time | 6,730 of 6,730 |
| Mailboxes | 34, after the hourly catalog |
| Stage outcomes from the source | Subscription Closed Won `won`, Closed Lost and Payment link expired `lost`, Self Serve Closed Lost `lost`; Self Serve's Closed Won stays `won | person` |

## The mailboxes labelled on Sources

Three shared mailboxes are named after their addresses in HubSpot, so the CMA showed their ids. Martin labelled
them on Configuration → Sources:

| Mailbox | Label | Which one |
|---|---|---|
| `3796124026` | Team | the team@ mailbox |
| `3876527388` | Service | the service@ mailbox |
| `3796125277` | Mail | mail@, Newco's address: internal traffic between Pulse4all and Newco, about 516 received in October 2026 |

Mail is still counted, so it is in Email's received figures. Whether it counts is an open decision for Martin
(README, Open decisions). The no-address rule stays: a label holds no `@` (README, Decision log, 19 October 2026).

## Outbound email in October 2026, from Martin's report

Every outbound email the CMA read in October had `actor_kind` agent:

| Source | Count |
|---|---|
| Inbox messages | 923 |
| Engagements with origin `CONVERSATIONS` (the inbox copies) | 922 |
| Engagements without an origin | 186 |
| Engagements with origin `BCC_TO_CRM` | 64 |
| Engagements with origin `EMAIL_INTEGRATION` | 9 |

HubSpot sends workflow emails as marketing emails, and the CMA does not read those (backlog CMA-072; README,
Open decisions).

## Not in the report

- Step 5's point-in-time recovery check and its Studio blocks (the additions, the per-person setting, the
  journeys).
- Step 6's build and its revision, and the hand checks on `997749c` itself.
- Step 7's execution names and times, and the `counts` beyond `fetched`.
