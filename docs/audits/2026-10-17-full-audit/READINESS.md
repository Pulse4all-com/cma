# Readiness for the soft launch

Part of the full IT audit of 17 October 2026 (`REPORT.md` in this directory has the findings and the method).
This file answers one question: what stands between today and the soft launch, who closes each gap, and what
evidence closes it. Sources: README (Roadmap step 2, Open decisions, Decision log, Environments and
infrastructure), the audit's findings (areas 5.1 to 5.14 in `FINDINGS.csv`), the fix pull requests of the
audit and the two new runbooks (`docs/OPERATIONS.md`, `docs/PLAN_B.md`). Nothing in it was checked against the
Console or the Admin console; Console-only gates carry Martin's steps and their expected result.

Verdict: **Go, conditional** (REPORT.md, section 7): the soft launch can start once the fix PRs are merged in the report's order, the jobs are redeployed with the 03:30 reconcile before the night of 24 to 25 October 2026, the four Console-only steps below are done, Yordi has cleared the per-person pages named in gate B4, and the first production week of the request log line has been read against the speed targets. No Critical finding; the two High findings are closed in #150, #154 and #155, and the four CMA-037 items in #150 and #151.

## Status on 18 October 2026

Added when the report was brought up to `main` at `c3e7603`; the gate tables below keep their "Status today" of 17 October 2026. Every fix PR named in section 2 is merged (commits and where each runs: `REPORT.md`, Status on 18 October 2026). Sources: Martin's records of 17 and 18 October 2026 (`records/deploys-2026-10-18`, `records/0008q-*`, `records/0008r-*`, `records/0008s-*`, `records/speed-dev-2026-10-18`, `records/audit-2026-10-18`).

| Gate | Status on 18 October 2026 |
|---|---|
| B1 time and the clock change | **open.** #158 (`9acbacc`) is merged and the ingest jobs run `ingest:9acbacc` in dev and prod; the reconcile's 03:30 schedule in prod is to be confirmed by Martin before Saturday 24 October (`gcloud scheduler jobs describe ingest-reconcile --project=p4a-cma-prod --location=europe-west4 --format='value(schedule,timeZone)'`, expected `30 3 * * *` and `Europe/Amsterdam`) |
| B2 the manager's screens are right | #160 (`c98028c`) in prod since 13:33:27 UTC (`cma-web-00076-g6b`); the manager's walk-through is open |
| B3 the manager's screens are fast | measured on day one, the week of log lines still open: `/live/board` p50 157.7 ms, p95 328.3 ms over 46 polls (`records/0008s-prod-2026-10-18`); `/reports/follow-up` 5.7 s before 0008s, 0.2 s after. Since #165 (`1ead2c3`) every request writes its line, so the week counts from that deploy (07:54:14 UTC) |
| B4 per-person figures cleared | open, unchanged |
| B5 a bad deploy is noticed | #154, #155, #152 and #153 merged and in prod (`cma-web-00070-5rn` to `00072-42g`; 0008r's `78` in dev and prod); the alert set (S3) is open |
| B6 no Critical or High open | both fixes merged: #155 in prod; #150's token cache in the ingest jobs (`ingest:9acbacc`); the `cma-ingest` service runs a new image of 18 October whose source commit is not in the report, so Martin confirms it carries #150 |
| S1 Plan B, S2 rollback runbook | met for the documents once this report PR is merged; the agents' copy, the dry runs open |
| S3 alert set, S4 2-Step Verification | open (Console only) |
| S5 System health page | #152 and #153 merged, 0008r in dev and prod, `79` PASS in dev; the page in prod and the two `health.link_*` settings are not in the records |
| S6 database hardening 0008q | met: #151 (with #162) merged; `76` in dev and prod, `77` PASS and failing under provoke in dev (it runs in dev only) |
| S7 web security hardening | #154 in prod; "no console violation on the daily pages" is not in the records |
| S8 ingest reliability | #157 merged, in the jobs on `ingest:9acbacc` in dev and prod; no overlap observed or recorded yet |
| S9 operations hygiene | #158 merged; Dependabot's first pull request seen ([#164](https://github.com/Pulse4all-com/cma/pull/164), open); the reconcile schedule as B1 |
| S10 restore drill | open |
| S11 README current | #156 merged; this report PR's drift fixes and Decision log rows pending its merge |

Dependencies (3.4): `npm audit` in `web/` reports 5 high on 18 October 2026, the same dev-only chain as on 17 October, 0 with `--omit=dev`; Dependabot's #164 is open. Beyond the audit, addition 0008s (#166) added the job `cma-refresh-follow-up` (every minute, pool 2): `docs/OPERATIONS.md` covers it beside the scheduler's close.

## 1. The soft launch, defined

> Arno, the call center manager, works in the Workspace every day (Team hours and corrections, People and
> linked accounts, the roster planner, the Live board, the reports he steers on, Messages); the Newco agents
> keep clocking their day in it as they have since 12 October 2026; development continues in parallel. Not
> part of it: the agent desk, Invest, the final name, the repository going private.

Blockers are anything that misstates time (the clock change included), a wrong or slow manager screen, a
per-person figure compliance has not cleared, and a bad deploy that goes unnoticed. Should-haves are Plan B,
the rollback runbook, the alert set, 2-Step Verification for the agents' unit and the System health page.

## 2. The fix pull requests this file refers to

| Pull request | What it closes | Where it lands |
|---|---|---|
| #150 ingest security | the ingest review's one High finding and two Medium ones (a token cache keyed per connection, one CRM lookup failing one customer, the flow verifiers' admin login) | `ingest/` |
| #151 database hardening (0008q, `db/76`, `db/77`) | the uncounted-line trigger asserts the acting person's right, no payload in the audit images of events, report cores on the index, source indexes, grants and search paths | `db/`, Studio: dev then prod |
| #152 and #153 System health (0008r, `db/78`, `db/79`) | Configuration → System health: version and modes, the ingest heartbeat, sources, jobs, outbox, the documents of the build; the scheduler's run row | `db/`, `web/`, `cloudbuild.yaml` |
| #154 web security | a first Content-Security-Policy, IAP's headers stripped after verification, End workday through the guarded route, `/api/health` 503 when misconfigured, verifier fixtures without staff data, a boundaries verifier | `web/` |
| #155 Cloud Build guard and startup probe | `check-config` refuses a bad mode, a missing IAP audience and non-numeric caps; `min-instances=1`, a startup probe on `/api/health` and the CPU boost in the file | `cloudbuild.yaml` |
| #156 README cockpit | the dashboard, cockpit and workspace wording | README |
| #159 speed | identity in one transaction, the pool kept warm with statement and idle-transaction ceilings, the roles read once per request, the Live poll as a timeout chain, the request log line and the round-trips budget verifier (the Live board's composite read stays a proposal) | `web/` |
| #160 UX | the hydration mismatch on Messages and the planner, keycaps 1 to 9, focus after a status change and Clock in, the error and not-found pages, the Live board's "Closed" label, no CSS all-caps, the needs-attention link to the days to correct, dialog names (the badge contrast stays a proposal for Mark) | `web/` |
| #157 ingest reliability | one execution per scheduled job, pool timeouts, no redirects on outbound calls and a response cap, a replay host guard, the connection-lost listener | `ingest/` |
| #158 ops | `deploy.sh` runs from `main` only, the reconcile at 03:30, Dependabot monthly | `docs/ingest/deploy.sh`, `.github/` |

"Met by PR #n once merged" means: merged by Martin, deployed (a merge touching `web/**` or `cloudbuild.yaml`
deploys prod; an ingest change needs `deploy.sh` dev then prod; a migration needs the Studio run dev then prod
with its verify), and the five-minute check of `docs/OPERATIONS.md` section 2 passed.

## 3. Gates

### 3.1 Blockers

| Gate | Owner role | Evidence required | Status today |
|---|---|---|---|
| B1 Nothing misstates time, the clock change of 25 October 2026 included | CMA owner | the DST review (area 5.12): every hours figure on instants, the 25-hour business day bounded, verifies 33, 61, 63 and 75 passing; the reconcile schedule outside the repeated hour; the first Monday after the change checked on Team hours and the Dashboard | met for the application (observed locally in the 5.12 proof: no finding above Low); the one schedule finding (DST-01) is met by #158 (ops) once merged and `deploy.sh prod --jobs` has run before Saturday 24 October; if not, the manual run of OPERATIONS section 5 on Sunday morning |
| B2 The manager's screens are right | call center manager (accepts), CMA owner | the UX review (area 5.14, `UX_REVIEW.md`): the hydration mismatch, the Live board's "waiting 0 min", the needs-attention link, focus and loading states fixed; the manager's own walk through Team hours, People, the planner, the Live board and the reports on the new build | open: met by #160 (UX) once merged; the manager's walk-through is the acceptance |
| B3 The manager's screens are fast (p95 under 2 seconds on the daily pages) | CMA owner | the measured half of area 5.6 (`PERFORMANCE.md`): p95 per page on the production build against a local database; in prod the request timing log metric of #159 (speed) and the SLOs S3 and S4 below | met locally (observed: every manager page under 80 ms at p95 on the production build against a local database, before and after the speed fixes); open in prod until #159 (speed) is merged and one week of the log metric exists |
| B4 Per-person figures compliance has cleared | compliance and data protection (answers), CMA owner (asks and records) | one confirmation per figure in the Decision log: Calls per agent (settled 14 October 2026), the Live board's live per-person status, the Dashboard's per-person time, Follow-up per person; Email per agent before it is built | open: one of four confirmed; the other three are one message to compliance, recorded by Martin; nothing in code changes |
| B5 A bad deploy is noticed, or never takes traffic | CMA owner | `/api/health` 503 on a misconfigured revision (#154); the startup probe and the stricter `check-config` (#155); the System health page (#152, #153); the five-minute check after every deploy (OPERATIONS 2); the alert set (OPERATIONS 9) | met by #152 to #155 once merged and deployed; the alert set is a Console step (3.3 below) and stays open until Martin has created it |
| B6 No Critical or High finding open | CMA owner | the two High findings of the audit fixed and in prod | met by #150 (ingest) and #155 (infrastructure) once merged and deployed; no Critical finding |

### 3.2 Should-haves

| Gate | Owner role | Evidence required | Status today |
|---|---|---|---|
| S1 Plan B for the agents | call center manager (content), CMA owner | `docs/PLAN_B.md`; the agents' short copy in their language; one dry run of the sheet on a quiet day | met by this report PR for the document; the agents' copy and the dry run open |
| S2 Rollback runbook | CMA owner | `docs/RUNBOOK.md` section 10 (web) and `docs/OPERATIONS.md` section 3 (ingest, jobs, scheduler job); the ingest commands run once in dev as the dry run | met by this report PR for the document; the dev dry run open |
| S3 Alert set | CMA owner | the policies of OPERATIONS section 9 listed by `gcloud monitoring policies list` in `p4a-cma-prod`; one test incident closed | open (Console only; steps in 3.3) |
| S4 2-Step Verification enforced for the agents' unit | Workspace administrator (CMA owner) | the Admin console shows enforcement on for the unit; a Decision log row with the date | open (Console only; steps in 3.3) |
| S5 System health page | CMA owner | #152 and #153 merged; 0008r run in dev and prod with `79` passing; the page green in prod; the two `health.link_*` settings filled | met by #152 and #153 once merged and run |
| S6 Database hardening 0008q | CMA owner | #151 merged; `76` and `77` run in dev and prod, `77` passing and failing under provoke; the records | met by #151 once merged and run |
| S7 Web security hardening | CMA owner | #154 merged and deployed; the Workspace works with the Content-Security-Policy on every page (no console violation on the daily pages) | met by #154 once merged and deployed |
| S8 Ingest reliability | CMA owner | #157 (ingest reliability) merged and deployed dev then prod; two executions of a scheduled job no longer overlap (one exits at once) | open: pending PR |
| S9 Operations hygiene | CMA owner | #158 (ops) merged; `deploy.sh prod --jobs` rerun (the reconcile at 03:30); Dependabot's first pull request seen | open: pending PR |
| S10 Restore drill | CMA owner | one dev drill recorded in `records/restore-drill-<date>` (OPERATIONS 11) | open |
| S11 README current | CMA owner | #156 merged; the drift fixes of this report PR merged; the Decision log rows of the audit | met by #156 and this report PR once merged |

### 3.3 Console-only gates: Martin's steps

**S3, the alert set.** Owner of `cma-ingest 429`: `docs/ingest/alert.sh`.

Status: four policies since 18 October 2026, `cma-ingest 429` and the three `docs/OPERATIONS.md` section 9 lists beside it, each enabled, each to the channel "CMA ingest alerts" (`records/console-2026-10-18`); steps 2 and 3 done, step 4 open.

1. **Terminal**
   ```bash
   gcloud monitoring policies list --project=p4a-cma-prod --format='table(displayName,enabled)'
   ```
   Expected: four rows, each `True`: `cma-ingest 429`, `cma-prod-pg connections above 75 of 93`,
   `cma-web more than 5 server errors in 5 minutes` and `Cloud Run job failed (any job)`.
2. **Browser:** Console → Monitoring → Alerting → Create policy, one policy at a time from the table in
   `docs/OPERATIONS.md` section 9 (metric, filter, condition, documentation text, the channel "CMA ingest
   alerts"). Expected after each Save: the policy listed and enabled; no incident open.
3. **Terminal:** the `list` of step 1 again. Expected: one row per policy of section 9, all `True`.
4. **File:** once each policy exists, a change to `docs/ingest/alert.sh` (a table of policies, `--only <name>`,
   the existing `--dry-run`) so a rerun updates them; proposed in `BACKLOG_CANDIDATES.md`.

**S4, 2-Step Verification.** No script owns it.

1. **Browser:** Admin console → Security → Authentication → 2-Step Verification → select the agents'
   organisational unit in the left pane. Expected: the unit's own setting is shown (inherited or overridden).
2. **Browser:** Enforcement on for that unit, with the enrollment period Pulse4all chooses; Save. Expected:
   the unit shows "Enforcement: On" (the exact label follows the Workspace edition) and the agents are asked to
   enroll at their next sign-in within the period.
3. **File:** a Decision log row in README with the date and the unit; the Open decisions bullet on 2SV closed.

**Cloud Armor review (about 13 November 2026).** Owner: `docs/ingest/front.sh` (`--rate-per-minute`,
`--shopify-rate-per-minute`, `--dry-run`).

1. **Terminal**
   ```bash
   gcloud compute security-policies describe cma-ingest-armor --project=p4a-cma-prod --format='value(rules[].priority,rules[].rateLimitOptions.rateLimitThreshold.count)'
   ```
   Expected: rules 900 and 1000 with 2400 and 600.
2. **Browser:** Console → Monitoring → Alerting → the policy `cma-ingest 429` → Incidents, the last 30 days.
   Expected: none on a healthy month; each incident with its time, to compare with the prod records' webhook
   volumes.
3. **Terminal** (only when the limits change): `bash docs/ingest/front.sh prod --host ingest.pulse4all.app
   --rate-per-minute <n> --shopify-rate-per-minute <n> --dry-run`, read the rules it prints, then the same
   without `--dry-run`. Expected: the two rules updated to the new values; a Decision log row.

**Logging retention and the invitation token in request logs.** No script owns it (audit finding WEB-02,
already open in README).

Status: the retention is met, 30 days decided with Yordi (Decision log, 12 October 2026). The buckets' location, `global`, is open (Open decisions, Cloud Logging location in `p4a-cma-prod`). Steps 2 and 3 (WEB-02) are unchanged.

1. **Terminal**
   ```bash
   gcloud logging buckets describe _Default --location=global --project=p4a-cma-prod --format='value(retentionDays)'
   ```
   Expected: `30`.
2. **Terminal** (dry run: what the sink excludes today)
   ```bash
   gcloud logging sinks describe _Default --project=p4a-cma-prod --format='value(exclusions)'
   ```
   Expected: the existing exclusions, possibly empty.
3. **Terminal** (the exclusion the web security review proposes, WEB-02; **untested here**)
   ```bash
   gcloud logging sinks update _Default --project=p4a-cma-prod --add-exclusion='name=cma-web-invite-path,filter=httpRequest.requestUrl:"/invite/" AND (resource.type="cloud_run_revision" OR resource.type="http_load_balancer")'
   ```
   Expected: `Updated [_Default].` From then on a visit to `/invite/<token>` leaves no request log line; the
   app's own lines still do. Trade-off: the status codes of `/invite/*` requests leave the request log too; to
   keep the accept POST, narrow the filter with `AND NOT httpRequest.requestUrl:"/invite/accept"`. A Decision
   log row records the choice and closes the Open decisions bullet on the invitation token.

### 3.4 Roadmap step 2's own conditions and the follow-ups

Not gates by the definition above, kept so nothing is lost (README, Roadmap step 2 and Open decisions):

| Item | Owner role | Status today |
|---|---|---|
| The heads-up of Roadmap step 2 to compliance: confirm it was sent | CMA owner | README says "to be confirmed"; the Newco conditions themselves were confirmed on 12 October 2026 |
| The two remaining people changes of step 2 (the second builder as admin in prod; one team member's role to agent) | CMA owner | "remaining" in the Roadmap text; a screen action (RUNBOOK 8), no code |
| The web dependency review (five high advisories under a devDependency, nothing shipped) | CMA owner | open by decision; Dependabot of #158 (ops) makes it monthly |
| KPI baselines and the ten targets | head of call center, KPI owners | open; outside the soft launch |
| App links' portal addresses; the hours columns the agent sees | CMA owner, call center manager | open; cosmetic for the soft launch |
| The 108 imported days flagged for review | call center manager | open on Team hours |
| Repository private at launch; the final name | CMA owner | by definition after the soft launch |
| Retention job and the aggregation of agent data older than a year | CMA owner, compliance | needed before 2 January 2027 (section 5) |
| Container scanning, a PR check trigger, a dev-only build path | CMA owner | open decisions on cost and timing; the audit's INFRA-14 moves the PR check up |
| Tenant picker, NocoDB columns, notifications and quiet hours | CMA owner, compliance | open; not needed while one tenant is live |

## 4. Service level objectives (proposed; measured in Cloud Monitoring, 28-day rolling, inside the workday window 07:00 to 22:00 Europe/Amsterdam)

| SLO | Indicator | Target | Metric | Today |
|---|---|---|---|---|
| S1 Sign-in and landing available | share of non-5xx answers of `cma-web-backend` | 99.5 % or more | `loadbalancing.googleapis.com/https/request_count` by `response_code_class`, `backend_target_name="cma-web-backend"` | not measured; the 5xx ratio alert of OPERATIONS 9 is the first signal |
| S2 Clock-in, status change and clock-out succeed fast | `POST /api/v1/me/day/start`, `/api/v1/me/status`, `/api/v1/me/day/end`: non-5xx share and p95 | 99.9 % or more; p95 at most 800 ms | the request timing log metric of #159 (speed) (`route` label); until then a log-based distribution on the Cloud Run request log (`httpRequest.latency`, never the URL kept) | not measured in prod; locally My day answers under 60 ms at p95 (observed) |
| S3 The manager's main pages | `/live/board`, `/team/hours`, `/reports/dashboard`, `/roster/planner`: non-5xx share and p95 | 99.5 % or more; p95 at most 2000 ms | the same metric, `route` label | not measured in prod; locally under 80 ms at p95 (observed) |
| S4 Backend latency overall | p95 of `cma-web-backend` | at most 1500 ms | `loadbalancing.googleapis.com/https/backend_latencies` | not measured; the p95 alert of OPERATIONS 9 fires at 2000 ms |
| S5 Ingest webhook acceptance | share of `POST` answers of `cma-ingest` that are not 5xx (200, 400, 401, 404 and 413 count as accepted: the source got a definite answer); no 429 at the load balancer | 99.9 % or more per day; 429 = 0 | `run.googleapis.com/request_count` (`service_name="cma-ingest"`, `response_code_class`); the existing `cma-ingest 429` policy | the 429 half is measured today (one policy); the 5xx half is not |
| S6 Ingest acceptance latency | p95 of the `webhook` log line's `ms` | at most 3500 ms (the 3-second budget plus the commit) | a log-based distribution on `jsonPayload.message="webhook"`, value `jsonPayload.ms` | not measured; the lines exist |
| S7 Job freshness | successful executions per hour: `ingest-sweep` and `ingest-poll-forms` at least 55 of 60; `ingest-poll-email` at least 55 of 60 where on; `ingest-reconcile` once a night; `cma-close-forgotten-workdays` 24 a day | as stated | `run.googleapis.com/job/completed_execution_count` with `result="succeeded"` by `job_name`; cross-check: `cma.sync_run` in Studio, counts and times only | visible on the System health page (#152, #153) and in Studio; the jobs-failing alert of OPERATIONS 9 is the signal |
| S8 Data freshness as people see it | the Sources screen's last event per active connection within 10 minutes during the window | 95 % of 5-minute samples | today the `cma.sources()` read; tomorrow a stored sample (backlog CMA-031) | the System health page shows the state; no sampled series exists yet |

The first month's actuals and the error budget used belong in the next readiness pass; nothing here needs
code beyond the timing log line of #159 (speed).

## 5. Dated items (to 16 December 2026, plus the one that must start inside the window)

| # | Item | Due | Owner role |
|---|---|---|---|
| 1 | The clock change: 03:00 CEST becomes 02:00 CET on Sunday 25 October 2026. #158 (ops) (the reconcile at 03:30) merged and `deploy.sh prod --jobs` run before it, or the reconcile run by hand on Sunday morning (OPERATIONS 5); Team hours and the Dashboard checked on Monday 26 October for the people who worked Saturday evening | Saturday 24 to Monday 26 October 2026 | CMA owner |
| 2 | Cloud SQL maintenance windows: dev week 1, prod week 2, Sunday 02:00 UTC, applied only when Google has an update | Sun 1 November (dev), Sun 8 November (prod), Sun 6 December (dev), Sun 13 December 2026 (prod) | CMA owner (watch) |
| 3 | The first monthly bill on the dedicated core: raise prod's €150 budget alert when the October bill shows the level | about 1 to 5 November 2026 | CMA owner |
| 4 | Cloud Armor rate limits (600 per minute per IP; 2400 on `/shopify/`) reviewed after the first month of real webhook volume and the `cma-ingest 429` incidents (steps in 3.3) | about 13 November 2026 | CMA owner |
| 5 | Email deletions: decide after a month in prod whether a deletion subscription or a nightly comparison is worth it (the email poll ran in prod from 16 October 2026) | about 16 November 2026 | CMA owner, head of call center |
| 6 | Shopify `read_all_orders`: without the scope the API serves the last 60 days of orders, enough for the backfill from 1 October 2026 until about 30 November 2026; an older backfill after that needs the scope, and how to get it is open | about 30 November 2026 | CMA owner, head of call center |
| 7 | Aggregation of agent data older than a year and the retention job that rides on it: the first imported days (batch `steam-2026`, from 2 January 2026) pass twelve months on 2 January 2027, so the build starts inside this window | before 2 January 2027 | CMA owner, compliance; the call center manager for the imported days |
| 8 | The `_Default` log bucket keeps 30 days: anything older than a month is gone from Logging, records included | rolling | CMA owner (awareness) |
| 9 | The first restore drill (OPERATIONS 11), dev then prod | within the quarter | CMA owner |

Outside the window, for awareness: the pinned Shopify API version `2026-10` is supported until 16 October
2027 (`docs/ingest/README.md`, Shopify).

## 6. What Martin records when a gate closes

- The five-minute check after each fix PR's deploy: shas, times and counts in the release record.
- The alert policies: the `list` output of 3.3 (names and `True` only) in the Decision log row.
- 2SV: the date and the unit in the Decision log; no screenshot of the Admin console in the repository.
- The restore drill: `records/restore-drill-<date>/README.md` from his own run.
- Compliance's confirmations of B4: one Decision log row per figure, with the date of the answer.
