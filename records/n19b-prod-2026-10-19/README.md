# N19-B in prod, 19 October 2026

Night run N19-B, the CMA's HubSpot API use and the daily-limit guard (backlog CMA-069; `Pulse4all-com/cma#169`,
squash-merged as `509ec43`), steps 12.1 and 12.2 of `docs/ingest/PROD_RUNBOOK.md`, run by Martin on
19 October 2026 in p4a-cma-prod, with the same reading in p4a-cma-dev. Written down by Claude Code on
19 October 2026 at Martin's request from his report; the values are his. No output file of his is in this
folder: the figures are the ones he reported from 12.2's command. Counts, endpoint names, ids and times only:
no key, no secret and no personal data.

## The deploy (12.1)

- Prod: `cma-ingest` and its jobs on `ingest:509ec43`, the service deployed with `--front ingest.pulse4all.app`.
- Dev: N19-B's branch image first, then `cma-ingest` and its jobs on `ingest:509ec43`.

The same image carries N19-A's ingest changes (`997749c`, merged before it), so it is also the image of step 7
of `docs/night-2026-10-19/MORNING_RUNBOOK.md` (`records/n19a-prod-2026-10-19`).

## After one hour: the calls per endpoint (12.2)

| Figure | Prod |
|---|---|
| Log lines with `apiCalls` | 119 |
| HubSpot calls in the hour | 2,417 |
| Per minute | 40.3, including 197 calls of the backfill job |
| The polls alone | about 37 a minute (2,220 calls without the backfill's) |

The endpoints that led the table:

| Endpoint | Calls in the hour |
|---|---|
| forms submissions (`GET /form-integrations/v1/submissions/forms/{id}`) | 1,898 |
| conversations threads | 163 |
| emails search | 83 |
| contacts batch read | 82 |

12.2 expected about 34 calls a minute when idle plus the sweep's read-backs, and the threads call near 60 in
the hour; the hour Martin read included the backfill job's 197 calls.

## HubSpot's daily-limit headers

They arrive, in dev and in prod: the newest line's `daily` holds the limit, 1,000,000, and in prod 967,340
remaining at the reading. So the floor guard on backfill and reconcile can pause when the remaining calls fall
below its floor. This settles the open decision on the headers (README, Open decisions).

## Not yet run

12.3 (HubSpot's own count of the last 24 hours in the portal's Monitoring) and 12.4 (the first night's
reconcile against the polls) run on 20 October 2026; their results go into a record of that day.

## Not in the report

- The time of the deploy, the revision names and the `health` line of 12.1, and the Sources settings check
  in the Browser.
- 12.2's raw output: the per-job split (`poll-forms`, `poll-email`, `sweep`, `backfill`), the rest of the
  endpoint table and the newest line's `daily` in full.
- Which backfill runs the 197 calls belong to.
- Dev's figures besides the headers and the limit.
