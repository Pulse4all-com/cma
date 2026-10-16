# B17b in prod, 16 October 2026

Brief B17b (the email poll: HubSpot email engagements and inbox conversations, metadata only; PR #139,
squash-merged as `1146ee3`), `docs/ingest/PROD_RUNBOOK.md` phase 10, run by Martin on 16 October 2026
in p4a-cma-prod (cma-prod-pg) and the live portal, after dev (`records/b17b-dev-2026-10-16`). Written
down by Claude Code at Martin's request from his report of the run, as `records/0008m-*` were
(PR #138); the values below are his. Ids, counts, dates and times only: no key, no secret
and no personal data. The terminal and psql outputs of the run are not in this folder.

## Before the start

- Kira told about the market shift (phase 10, Before you start).

## The service, the jobs and the app (10.1, 10.5)

- The service and the jobs deployed at `1146ee3`: no build, health ok, `ingest-poll-email` created.
- That service deploy ran without `--front` and became revision `cma-ingest-00008`: ingress `all`, and
  `INGEST_PUBLIC_URLS` without `https://ingest.pulse4all.app`, so HubSpot's webhooks failed with 401
  until 08:15 CEST. Fixed by hand in the Console: the ingress at about 08:08 CEST, revision
  `cma-ingest-00009` at 08:15 CEST
  ([`records/ingest-front-incident-2026-10-16`](../ingest-front-incident-2026-10-16/README.md)).
- 10.1: build #2 of **CMA ingest prod** deployed; the install reinstalled through the Reinstall URL; the
  token unchanged; both endpoints answer `200`.

## What the live portal holds (10.2)

`docs/ingest/hubspot-email-check.mjs` against the live portal:

| Block | Result |
|---|---|
| 1 and 2. the properties and the candidates | the same properties as in dev |
| 3. the actor id prefixes, in 200 threads of the last 30 days | `A` `AGENT` 11, `S` `SYSTEM` 1, `V` `VISITOR` 66 |
| 4. the inboxes | `Inbox` 948000000, `Help Desk` 948000001, `Social Workspace` 948000002, `Support` 948001000 |

## Configuration (10.3, 10.4)

- The connection `01a12f17-4fcb-7406-b0ff-b335c54f828a`: `email_poll` true and `email_thread_property`
  `hs_email_thread_id` in its settings; the contact's country slots 1 `contact_country` and
  2 `country_dropdown`.
- The aliases: all 14 `country_dropdown` values map to a market; no alias added.
- 10.4: the inboxes left at the default (all counted).

## The first poll

2026-10-16T03:25Z: 429 fetched, 1,046 upserted.

## Backfill (10.5)

| Object | Execution | Took | Status |
|---|---|---|---|
| `contact` | `lr897` | 35 s | succeeded |
| `crm_email` | `sbxdp` | 40 s | succeeded |
| `inbox_thread` | `crkzq` | 37 min | succeeded |

## Read-only counts (10.6)

| Source kind | Direction | Actor kind | Count |
|---|---|---|---|
| `crm_email` | `in` | `customer` | 1,166 |
| `crm_email` | `out` | `agent` | 1,063 |
| `inbox_message` | `in` | `customer` | 1,589 |
| `inbox_message` | `out` | `agent` | 948 |

| Inbox | Threads |
|---|---|
| `Help Desk` | 614 closed, 568 open, 24 open spam |
| `Social Workspace` | 3 open |
| `Inbox` | 0 |
| `Support` | 0 |

| Read | Value |
|---|---|
| Events | `assigned` 663, `closed` 758, `reopened` 1,455 |
| Contacts by `country_source` | 1: 1; 2: 4,569; none: 176 |
| `contact_country_fallback` | 4,569 for `pulse4all-subscriptions`, 0 for `pulse4all-invest` |
| `contact_not_in_catalog` | 0 |
| `email_poll` runs in the last hour | 42 `succeeded`, 1 `running`, 0 `failed` |

## Not in the report

- 10.5: the Studio read of the `email_poll` runs and the `email:` cursors two minutes after the deploy
  (the first poll's counts are above).
- The times of the deploys, the reinstall and the backfill.
- 10.7, day one: not in this report; its run gets a section or a record of its own.
