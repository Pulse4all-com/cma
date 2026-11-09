# B17b in dev, 16 October 2026

Brief B17b (the email poll: HubSpot email engagements and inbox conversations, metadata only; PR #139,
squash-merged as `1146ee3`), steps 1 to 8 of `docs/b17b-email-ingest/MORNING_RUNBOOK.md`, run by Martin
in p4a-cma-dev (cma-dev-pg) and HubSpot's developer test account `CMA dev`, connected as `martin@pulse4all.com`.
Steps 1 to 3 and the merge ran on 15 October 2026 (git dates `1146ee3` 2026-10-15T16:02:39Z), step 7
on 16 October 2026 (its run at 03:00:25Z). Written down by Claude Code at Martin's request from his report
of the run, as `records/0008m-*` were (PR #138); the values below are his. Ids, counts, dates and times
only: no key, no secret and no personal data. The terminal and psql outputs of the run are
not in this folder.

## Checks (step 1)

| Check | Result |
|---|---|
| `npm ci` in `ingest/` | ran |
| `npm run lint` in `ingest/` | clean |
| `npm test` in `ingest/` | thirteen `ALL n PASS` lines, the last `ALL 76 PASS` (`verify/email-mapping.mjs`) |
| `node hubspot/verify/render.mjs` | `ALL 32 PASS` |

## The dev app (step 2)

- 2a: the contact property `country_dropdown` created in `CMA dev` with the options `United Kingdom`,
  `Netherlands`, `Germany` and `Atlantis Test`.
- 2b: build #3 of **CMA ingest dev** deployed. Build #4, which requested `crm.objects.emails.read`,
  failed to deploy: "isn't available to this app". Reverted on #139's branch (commits `3d2c6e7` and
  `41cd45f`); build #3 stays deployed.
- 2c: the test install reinstalled in `CMA dev` (149511908).
- 2d: both endpoints answer `200`.

## Configuration (step 3)

`docs/ingest/hubspot-email-check.mjs` (3a):

| Block | Result |
|---|---|
| 1. the properties | the eight present; `hs_email_direction` has `DRAFT_EMAIL` next to the three expected options; `hs_email_status` options `BOUNCED`, `FAILED`, `SCHEDULED`, `SENDING`, `SENT`, `DRAFT` |
| 2. the candidates | thread property `hs_email_thread_id`; origin property left out |
| 3. the actor id prefixes | no actors: no conversation in `CMA dev` yet |
| 4. the inboxes | `Inbox` 948000000, `Help Desk` 948000001 |

The connection (3b): `01a129a3-8635-7b25-8771-8c48e3010600`, with `email_poll` true and
`email_thread_property` `hs_email_thread_id` in its settings; the contact's country slots
1 `contact_country` and 2 `country_dropdown`.

The aliases (3c): the existing aliases already map `Germany` → `DE`, `United Kingdom` → `GB` and
`Netherlands` → `NL`; `Atlantis Test` maps to none, on purpose.

## Merge, image and jobs (step 4)

- PR #139 squash-merged as `1146ee3`.
- `deploy.sh dev`: the service at `1146ee3`, health ok. `deploy.sh dev --jobs`: six jobs, among them
  `ingest-poll-email`.
- The check after two minutes: `email_poll` runs `succeeded`, one every minute; cursors `email:accounts`,
  `email:catalogs`, `email:engagements`, `email:open-check`, `email:owners` and `email:threads`.

## Backfill (step 5)

| Object | Fetched | Upserted |
|---|---|---|
| `contact` | 2 | 2 |
| `crm_email` | 2 | 2 |
| `inbox_thread` | 0 | |

From 2026-09-30T22:00Z (00:00 on 1 October 2026 in Amsterdam).

## The overlap test (step 6)

- The test inbox `CMA test inbox`, 948001000, connected in `CMA dev` (its forwarding address is not
  written down here).
- Thread 22376276167: closed, with an owner and a contact.
- `inbox_message`: `in` (`customer`) and `out` (`agent`, with an owner).
- `crm_email`: the same two emails as engagements as well, `in` 528219191518 and `out` 528227406015.
- The `crm_email` rows' thread property (`hs_email_thread_id`) differs from the inbox thread's id.
- Both `crm_email` copies carry `hs_engagement_source` `CONVERSATIONS`. The incoming one:
  `hs_object_source` `EMAIL`, logged from `FACSIMILE`; the outgoing one: `CRM_UI` and `CRM`.
- The thread's events in order: `reopened` (`system`, at its creation), `closed`, `reopened`,
  `assigned` (agent to agent), `closed`.

## The fallback (country slot 2)

`country_dropdown` `United Kingdom` on the test contact gave it `GB` with `country_source` 2 within
seconds, by webhook; data quality's `contact_country_fallback` lists it.

## `verify:email-flow` against dev (step 7)

- `ALL 32 PASS`.
- Finding: its section G polled every dev connection, not only the run's own. It wrote one failed
  `email_poll` run (`token_unavailable`) for `pulse4all-subscriptions` at 2026-10-16T03:00:25Z, with no
  other effect. The fix is brief B17b.1, PR #143 (open when this record was written).

## Read-only counts (step 8, `pulse4all-subscriptions`)

| Source kind | Direction | Actor kind | Count |
|---|---|---|---|
| `crm_email` | `in` | `customer` | 1 |
| `crm_email` | `out` | `agent` | 1 |
| `crm_email` | `out` | `unknown` | 2 |
| `inbox_message` | `in` | `customer` | 1 |
| `inbox_message` | `out` | `agent` | 1 |

| Read | Value |
|---|---|
| Threads | `closed` 1 |
| Events | `assigned` 1, `closed` 2, `reopened` 2 |
| Inboxes | 3 |
| `email_poll` runs in the last hour | 60 `succeeded` |

## Not in the report

- Step 3d: what was set for the inboxes and channels in dev.
- Step 4: the first three `email_poll` rows with their counts, and the job's log line.
- Step 5: the backfill runs' status and the contacts by `country_source`.
- Step 6: whether the close without a new message showed in the first run after it or only after the
  ten-minute open check.
- Step 7: the run with `--provoke`.
- Step 8: the channels' count, `contacts_from_fallback`, and the threads' spam, archived and forgotten
  columns.
- The times of steps 5, 6 and 8.
