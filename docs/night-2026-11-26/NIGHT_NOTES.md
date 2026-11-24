# Night notes, N07: the CMA blazing fast (additions 0009zr, 0009zs, 0009zt)

Night of 25 to 26 November 2026, brief N07. Written by Claude Code while Martin was away. Everything was built, measured and
verified in the session's own container. Nothing touched dev, prod, Google Cloud or a vendor.

The container:
- PostgreSQL 16 with a local `uuidv7()` shim (prod runs 18), created with Cloud SQL's collation (en_US.UTF-8).
- `db/00` to `235` replayed with the dev seeds, then `web/verify/perf-volume-fixture.sql` at multiplier 3, with two new
  blocks: the old Juo moves, bringing `subscription_event` to 806,484 rows (3 × prod's 268,828), and the CRM's email
  (12,000 threads, 51,000 messages, 27,000 thread events: 3 × prod's of 16 November).
- Postgres held to one CPU (`taskset` on the postmaster), and from WP5 on a loop that keeps every other process off that
  CPU.
- Node 22 and the standalone build.

Outputs are in `local-records/` (`before/`, `after-n07a-n07c/`, `n07a/`, `n07c/`, `n07f/`, `wp5/`). The steps Martin runs
are in `MORNING_RUNBOOK.md`.

**The numbers.** On main at the start: addition 0009zq, script 235, and no open pull request. Taken tonight:
- 0009zr (`236`/`237`)
- 0009zs (`238`/`239`)
- 0009zt (`240`/`241`)

## Pull requests, merge in this order

| PR | Branch | What | Base |
|---|---|---|---|
| N07a, Pulse4all-com/cma#319 | `claude/clever-goodall-7wnx9z` | WP6, WP5: the jobs off the vCPU, `CMA_DB_SESSION_OPTIONS` | main |
| N07b | `…-n07b` | WP2, WP3, WP4: persistent shell, optimistic writes, router cache, prefetch | main (web only) |
| N07c | `…-n07c` | WP7: Email's deals not responding | N07a |
| N07d | `…-n07d` | WP1: request log `kind`, Server-Timing, navigation beacon | main (web only) |
| N07e | `…-n07e` | WP8, D11: CSP step 2 alone | N07d |
| N07g | `…-n07g` | WP8: X-Requested-With and the session-expiry notice, npm audit, Back after Log out | N07e |
| N07f | `…-n07f` | WP10: D12 (prod waits for Yordi) and D13 | N07c |

Night default N07-3 (to confirm): the web PRs are based on main rather than on N07a, because they share no file with it. The
cma-reviewer's D11 finding split N07e in two, which added N07g. Conflicts between N07b and N07g are mechanical: the call
sites that N07b rewrites call `clientFetch` in N07g. The N07g fork confirms this in its report.

## What changed

**N07a (0009zr): the minute jobs off the vCPU.**
- **The gate.** The four web minute jobs ask `cma.job_gate_of` before their heavy step:
  - `after_timeout`: after runs cancelled by the statement timeout, the job waits 5, 10, 20, 40, at most 60 minutes.
  - `deferred`: while `cma.web_busy()` counts `jobs.defer_web_statements` (2) active web statements, at most
    `jobs.defer_max_in_a_row` (5) times in a row (D7).
  - `nothing_to_read`: the follow-up of a tenant without a CRM source or stored items.
  - A gated run's row counts its wait. `skipped` keeps its meaning.
- **`cma.web_busy()`.** SECURITY DEFINER (cma_owner, pg_read_all_stats); it answers only a count.
- **`customers.refresh_minutes`** defaults to 10 (N07-1).
- **The subscription facts' renewal outcomes are incremental.** Only the subscriptions written since the last computation
  started, less 10 minutes, plus every invoice renewal. The whole set on a forced refresh, a new business date, a chargeback,
  or hourly (N07-2).
- **Speed to lead.** Its one definition moved into `cma.speed_to_lead_rows_of` with an open-only bound, which the follow-up's
  open leads use. `cma.refresh_follow_up_of` runs without JIT.
- **Small configuration tables.** Their analyze threshold is 10 rows.
- **`CMA_DB_SESSION_OPTIONS`.** Sent by the web's pool and every job's pool. Empty by default (D6); its allowlist is jit,
  work_mem ≤ 256 MB and random_page_cost.
- **Subscriptions poll.** Its 320 → 1,009 ms (WP6.7) is explained: `cma.ingest_upsert_subscriptions` reads, for each paused
  subscription, all of that subscription's events to find its latest pause. 0009zk's backfill tripled those events. A small
  partial index takes the lookups of 2,241 paused subscriptions from 440 to 4.8 ms. It is a Terminal step outside the
  migration. The rest of the tripling is the saturated vCPU of the same hours.

**N07b (web).**
- **Persistent shell (D2).** A `(shell)` route group whose layout renders the frame once. Content-only skeletons, and no
  loading boundary above the four real-404 pages.
- **Optimistic writes (D3).** Day status, market, end of day, clock in, read and acknowledge, a roster cell and a settings
  toggle each show at once and take the write route's own answer. A status change becomes visible in 10 to 27 ms (local
  Playwright, `verify:optimistic`, p50 11 to 12 ms). Follow-up polls `GET /api/v1/reports/follow-up/updated` instead of
  re-rendering.
- **Router cache (D4).** `staleTimes` 30 s, dynamic and static.
- **Prefetch (D5).** A full prefetch on 100 ms of hover or focus and Welcome's head start per role, for agent-class routes
  only.
- **Inbox.** 0 reloads per navigation instead of 2 (`verify:round-trips`).
- **Content-visibility** was left out: paint containment broke the fixed header hints.

**N07c (0009zs).** `cma.email_not_responding_of` checks "a conversation call since the last email" as two reads, one by the
deal's contacts and one by the deal, instead of one read joined by `or`. That read scanned every call association of the
connection (111,258) once per deal: 7.0 s → 0.2 to 0.4 s.

**N07d (web, telemetry).**
- The request log line gains `kind` (document, navigation, prefetch, api).
- Pages and API answers carry Server-Timing with db and total durations.
- `POST /api/v1/telemetry/navigation`: same-origin only, at most 1 kB, answers 204, writes one log line, stores nothing (D10).
- `request-percentiles.mjs --kind` and `--navigation`.

**N07e and N07g (web, security).**
- **N07e:** CSP step 2 (a per-request nonce, `'strict-dynamic'`, the desktop fit allowed by its hash) as its own PR (D11).
- **N07g:**
  - Every client request goes through `clientFetch` with `X-Requested-With`.
  - A 401 stops the tab's requests and shows "Your sign-in to the Workspace has ended", with a "Sign in again" button that
    reloads on a click only (en, nl).
  - npm audit: 6 → 0, through a rimraf override that google-gax does not load.
  - A check that Back after Log out shows nothing of the previous person.

**N07f (0009zt).**
- **D12, in prod only after Yordi's agreement, narrowed (N07-6).**
  - The ingest's writes to nine mirrored tables leave no audit row: the subscription tables, billing events, email, order
    lines and record stages.
  - The ten mirrors that are the follow-up's inputs stay audited. The follow-up's change check reads their audit rows, and
    the email poll writes `crm_contact` and `crm_association` without an ingest event (cma-reviewer's and
    cma-db-reviewer's finding).
  - A person's writes, the jobs' writes and every configuration table stay audited.
- **D13.**
  - `sync_run.retention_days` 90 and `failed_retention_days` 365.
  - `cma.sync_run_purge` keeps a pair's 20 latest runs and a stream's latest succeeded run, and leaves the hourly counts
    as they are.
  - The nightly reconcile purges 50 batches of 2,000 per tenant.

## Before and after (local, three times prod's volume, one CPU)

| Moment | Before | Target | After |
|---|---|---|---|
| Active refresh, a computation | 6.5 s forced; the facts' refresh after it 12.9 s, 13.7 s on the second measurement | under 10 s each | Active unchanged at 6.5 s; facts 12.0 s whole, 4.8 to 5.1 s incremental (outcomes step 9.4 → 0.6 s); no streak: after a timeout the job waits 5 to 60 minutes |
| Follow-up refresh | 2.3 s | under 300 ms in a minute with few changes | 1.2 to 1.3 s per computation; a minute with nothing changed 2 ms (as before). Not reached: remainder 1 |
| Seq scans of `setting`/`tenant_setting` per follow-up refresh | 20,699 each | under 50 | 5,723 each (per deal in `cma.deal_calls_of`). Not reached: remainder 2 |
| The empty invest tenant | follow-up 2 ms, data quality 0 to 74 ms, Flash 18 to 46 ms, Active 5 ms per minute | under 50 ms per minute | the same, plus the gate's 0.9 ms; the follow-up skips with nothing to read |
| `/api/v1/me/messages` p95, prod | 164 ms | 80 ms or less | prod after the deploy (runbook step 8) |
| `/live/[org]` p95, prod | 672 ms | 400 ms or less | prod after the deploy (runbook step 8) |
| A rail click | the whole frame becomes a skeleton | content area only | content area only, header and rail unchanged (N07b, `verify:shell`) |
| A status change | POST plus a full page refresh | visible within 50 ms | 10 to 27 ms, p50 12.2 ms (`verify:optimistic`, local) |
| Back or forward within 30 s | a server round trip | 0 requests | served from the router cache (staleTimes 30 s) |
| The agent's next page | skeleton, then data | data already there | Welcome's head start and hover prefetch (N07b) |
| Reports → Email | 10.3 s for the page's five reads (not responding 7.0 s) | under 1 s | about 2.8 s (not responding 0.2 to 0.4 s; report page 2.0 s: remainder 3) |
| Lead cohorts, previous month | 5.3 s | under 2 s | 5.1 s, not addressed tonight (remainder 4) |
| Funnel page, database time | 775 ms | under 1.5 s | 568 ms |
| Calls page, database time | 3 × 0.95 s | under 1 s | 3 × 1.0 s, not addressed (remainder 5) |
| Subscriptions poll, paused lookups | 440 ms | | 4.8 ms with the Terminal index |
| `124` (Flash) | 23 ok | | 23 ok, 0 FAIL |

The "before" and "after" for Email: `131`'s email rows of the "before" ran before the email block was loaded, so the before
row is `local-records/before/email-reads.txt` (idle CPU: 2.0 s, 0.19, 0.22, 7.0, 0.92 s).

## WP5: session settings, measured

`131` parts a, b and c per configuration (`local-records/wp5/table.md`; reads of 5 ms or more; the best of each read's runs):

| Configuration | Sum of the reads' times | Reads 10 % faster | Reads 10 % slower |
|---|---|---|---|
| none | 92.8 s | | |
| jit=off | 78.7 s (−15 %) | 41 | 26 |
| work_mem=16MB | 88.7 s (−4 %) | 46 | 25 |
| random_page_cost=1.1 | 84.5 s (−9 %) | 48 | 15 |
| all three | 74.7 s (−20 %) | 62 | 17 |
| none, generic plans | 99.3 s | | |
| all three, generic plans | 94.4 s (−5 %) | 32 | 44 |

By the brief's rule (keep a setting only when no read is more than 10 % slower), none qualifies locally. Part of the
"slower" is noise on reads of a few milliseconds. `CMA_DB_SESSION_OPTIONS` stays empty. The morning runbook measures
`jit=off` first, in dev, read by read. `refresh_follow_up_of` gets `jit = off` at function level, as 132 did for other job
functions: a fresh connection compiled 444 ms of JIT for the open leads alone.

Temp spills, measured with `log_temp_files = 0`:
- The facts refresh spills: 78 MB in the whole computation's update of `renewal_outcome`, 55 MB filling the outcomes,
  50 MB in `subscription_moves_of`, 23 MB in the month take.
- Active's base read spills 12 MB.
- A function-level `work_mem` of 64 MB made the facts refresh no faster: 14.0 and 14.4 s against 13.0 and 13.3 s at 4 MB,
  alternating, on an idle CPU.

So no function-level `work_mem` (night default N07-4, to confirm). The arithmetic for any future one: 93 usable connections
× 16 MB × at most two sorts each is about 3 GB of the 3.75 GB. So a function-level setting, never a session one, and at
most 64 MB.

## Every verifier

| Script or verifier | Result | Provoked |
|---|---|---|
| `236` | ran twice locally: `INSERT 0 1 COMMIT`, then `INSERT 0 0 COMMIT` | |
| `237` | 11 OK, `PASS 0009zr` | 11 FAIL; F1, L1 and L2 see a planted difference |
| reruns for 236 | 41, 73, 75, 81, 95, 99, 151, 155, 179, 211, 213, 217, 219, 221, 223, 225 PASS; 191 and 235 (edited) PASS | |
| `238`, `239` | 3 OK, `PASS 0009zs` | 3 FAIL, E2 sees a planted difference |
| reruns for 238 | 83, 91, 101 PASS | |
| `240`, `241` | 3 OK, `PASS 0009zt` (R1; A1: ingest to `subscription_event` 0 audit rows, to `crm_contact` 1, to `market` 1, a person labelled ingest 1; P1: 32 deleted, the hourly counts 61 before and after) | 3 FAIL, P1 with a 7-day retention |
| reruns for 240 | 107, 113, 169, 197 PASS; 77 (A5: `cma.workday_stretches_reader_of` and `cma.workday_summary_reader_of` without `pg_temp` last) and 195 (P1: `pg_stat_statements` not loadable on this local server) FAIL locally, both older than tonight and not about 240 | |
| web, N07a | build, typecheck, lint (0 errors, main's 2 warnings), every pure verifier PASS, `verify:jobs` 51 | `verify:jobs` 51 FAIL |
| web, N07b | build, typecheck, lint; every pure verifier; `verify:shell` 37; `verify:optimistic`; `verify:hints`, `verify:theme` PASS; `verify:layout` 16 problems on main and branch alike; `verify:round-trips` PASS (93 requests) | the new verifiers fail when provoked |
| web, N07d | `verify:telemetry` 34 (40 with a server); `verify:round-trips` PASS | all FAIL |
| web, N07e and N07g | `verify:csp` 8 (13), `verify:security` 8 (12); `verify:theme` PASS | all FAIL |
| ingest, N07f | `npm test` PASS, lint clean, `verify:retention` 4 | 4 FAIL |

Not run here: `verify:api`, `verify:perf`, `verify:iap` and every prod or dev step (MORNING_RUNBOOK).

## Night defaults (to confirm)

| Default | What | Why |
|---|---|---|
| N07-1 | `customers.refresh_minutes` 10 | the least interval between two Active computations (WP6.1) |
| N07-2 | renewal outcomes: overlap 10 minutes, whole hourly, on a new date or a chargeback | a late commit, a deleted event and a chargeback's order are caught; the 60 minutes are proposed as a future setting |
| N07-3 | web PRs based on main | they share no file with the database PRs |
| N07-4 | no function-level work_mem | no temp blocks measured locally |
| N07-5 | `nothing_to_read` for the follow-up only, and only without stored items | Active's not_set_up branch removes a switched-off tenant's take; Flash and data quality answer for a tenant without sources |
| N07-6 | D12 narrowed to nine tables: crm_record_stage, commerce_order_line, subscription, subscription_event, subscription_line, billing_event, email_thread, email_message, email_thread_event | the other ten mirrors are the follow-up's inputs: its change check reads their audit rows, and the email poll writes two of them without an ingest event. They leave the audit with remainder 1's write-time markers |
| N07-7 | the purge keeps a pair's 20 latest and a stream's latest succeeded run; 50 × 2,000 a night | Sources' last read and the latest run's figures read them; a short nightly window |
| N07-8 | gated runs never say `skipped`; the gate's reason is `after_timeout`, not `backoff` | both words already have a meaning (definitions.md) |
| web | `staleTimes.static` 30 s; any 401 is the end of the sign-in; the beacon via `fetch` keepalive; Server-Timing's total on a page stops at the first byte; the rimraf override | the forks' reports, in their PRs |

## The ranked remainder (measured cost × use)

1. **The follow-up per changed record, with write-time markers.** This also lets D12 take the ten follow-up inputs out of
   the audit log, which holds most of its 100,000 rows a day. A computation is 1.2 s at volume, about 0.4 s at prod's volume (estimate). Office
   hours change the inputs every minute, so to reach 300 ms only the items whose deal, ticket, task or calls changed must
   be computed. A design with an equality proof; not built tonight.
2. **The settings read per deal.** `cma.deal_calls_of` reads `telephony.connected_min_seconds` and
   `calls.conversation_min_talk_seconds` per deal, 5,723 reads per refresh. Pass them as arguments from the outermost
   function, as 234 did for `attempts.source` and the cutoff. This changes signatures under the one definition, and many
   verifies read it.
3. **Email's report page** (`cma.email_of`, 2.0 s at volume). A one-row list of the connections, planned at one row, makes
   a loop that compares every message with every connection (1.28 million comparisons). The per-message market chain costs
   1.6 s. Next: drive the messages first, with a hash join on the connections, and precompute the market per contact.
4. **Lead cohorts** (5.1 s for a month at volume): not analysed tonight.
5. **Calls three times per page** (3 × 1.0 s): one call grouped three ways (grouping sets).
6. **Facts' months and survival steps** (1.9 and 0.5 s per computation): written as differences, as 0009zf did for the
   others.
7. **`cma.sales_deals_of`** computes every lead deal's window (330 ms) where the follow-up needs the open ones.
8. **The Follow-up page's poll** reads one scalar now (N07b fix). A 131 poll row for it.

## Proposals only (WP9)

- **A second vCPU** (`db-custom-2-7680`, high availability). Decide with prod's CPU per hour after N07a's deploy: the
  Gemini prompt in the runbook, step 9. The local numbers say the job load falls by the facts' 8 s per computation and by
  the retry storm; the web's share is unknown until the beacon and Server-Timing report.
- **cma-web's `--cpu`, `--memory` and second-generation execution environment.** Take the render time from Server-Timing's
  total less db after N07d.
- **audit_log in monthly partitions with BRIN on time (D9).**
  - **Retention:** the one-year rule for staff time data, agreed with Yordi, drops partitions older than the rule.
  - **Moving 11 GB without long locks:**
    1. Create the partitioned table beside the old one.
    2. Write new rows to it through the trigger function.
    3. Copy the old rows in monthly batches outside office hours.
    4. Swap the names in one short transaction.
  - **What Yordi must agree:** the retention per kind of row (staff time data, configuration, ingest before D12).
- **Runbook rule.** A manual backfill runs after 18:00 Amsterdam. A backfill that grows `subscription_event` is followed by
  a check of the Active refresh's time (`tools/perf/active-refresh-breakdown.sql`).
- **Office-hours cadences (D7, numbers, not set).** At prod's volume, about a third of tonight's local times:
  - `data_quality.refresh_minutes` 15 in office hours: one 2 s computation every 15 minutes instead of every 5.
  - `flash.current_refresh_minutes` 10: the current takes, 1.7 s each.
  - `subscriptions.take_refresh_minutes` 30: an incremental facts computation of about 1.7 s.

  Each would roughly halve its job's share of the vCPU.
