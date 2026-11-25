# Morning runbook, N07: the CMA blazing fast (additions 0009zr, 0009zs, 0009zt)

Written in the night of 25 to 26 November 2026 by Claude Code (brief N07). One step per section; every block is labelled
**Studio** (SQL in Cloud SQL Studio, naming the instance), **Terminal** (Martin's own Linux terminal, in `~/cma` unless
stated), **Browser** or **File**, with its expected output. Never SQL and shell in one block. Prod steps that write run
outside office hours (before 08:00 or after 18:00 Amsterdam).

**What changes** (NIGHT_NOTES.md holds the why and the numbers):
- **N07a** (`236`/`237`, addition 0009zr): the web minute jobs' gate (`cma.job_gate_of`: wait 5 to 60 minutes after a
  statement timeout, defer while the web is busy, skip a follow-up with nothing to read), `cma.web_busy()`, the subscription
  facts' renewal outcomes incremental, speed to lead's one definition with an open-only bound for the follow-up, the
  follow-up refresh without JIT, `CMA_DB_SESSION_OPTIONS` (empty), the volume fixture at today's shape.
- **N07b** (web): the persistent shell, optimistic writes, the router cache at 30 s and the prefetch policy (D2 to D5).
- **N07c** (`238`/`239`, addition 0009zs): Reports → Email's deals not responding read per branch (7.0 s → about 0.4 s at
  three times prod's volume).
- **N07d** (web): the request log's `kind`, Server-Timing, the navigation beacon (D10).
- **N07e** (web): CSP step 2 (nonce, D11), `X-Requested-With` and the session-expiry notice, npm audit at zero.
- **N07f** (`240`/`241`, addition 0009zt, ingest): the ingest's source writes out of the audit log (D12, agreed by
  Yordi on 25 November 2026), the run rows' retention (D13).

**Order.** Merge N07a, N07b, N07c, N07d, N07e, N07f in that order (each is stacked on the one before; after a
squash-merge the next one is retargeted to `main`). Each database step runs in dev first, then prod. The jobs and the
ingest check for the new functions, so an image ahead of its migration computes as before.

| Step | What | Elapsed |
|---|---|---|
| 0 | Prod "before": request percentiles with `--kind`, the job load, `prod-load-breakdown.sql`, `131`, `124` | 25 min |
| 1 | Dev: the concurrent indexes, `236` to `241` with their verifies and reruns, the schema snapshot | 40 min |
| 2 | Merges in order; watch the builds | 30 min |
| 3 | Prod, outside office hours: the indexes, `236`, `238` (and `240` after `244`, 0009zv), verifies | 30 min |
| 4 | The jobs' deploys: every minute again, with the waits in place | 10 min |
| 5 | Analyze the small configuration tables | 2 min |
| 6 | The first `sync_run` purge (after `240`) | 10 min |
| 7 | `CMA_DB_SESSION_OPTIONS`, one setting at a time, measured in dev first | per setting 20 min |
| 8 | Prod "after": the same as step 0, a working day later | 25 min |
| 9 | The Gemini prompt (WP9) | 10 min |
| 10 | The heads-up to Yordi (D12): done, agreed 25 November 2026 | 0 min |

---

## 0. Prod "before"

**0a. Terminal** (the request log, 7 days, per route and kind; after N07d is deployed `--kind` splits documents,
navigations, prefetches and API calls; before it every line counts as one kind)
```bash
cd ~/cma && gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="cma-web" AND jsonPayload.message="request"' --project=p4a-cma-prod --freshness=7d --format=json --limit=200000 > /tmp/requests-7d.json && node tools/perf/request-percentiles.mjs /tmp/requests-7d.json > /tmp/percentiles-before.txt && head -40 /tmp/percentiles-before.txt
```
Expected: one row per route with n, p50, p75, p95, p99, max; `/api/v1/me/messages` p95 near 164 ms, `/live/[org]` near 672 ms.

**0b. Terminal** (the database's load per job and hour, counts and times only)
```bash
cd ~/cma && cma_db prod && psql "$PGCONN" -X -f tools/perf/prod-load-breakdown.sql > /tmp/prod-load-breakdown-before.txt 2>&1; tail -5 /tmp/prod-load-breakdown-before.txt
```
Expected: the file ends with its last part and no `ERROR`.

**0c. Terminal** (`131` in three parts and `124`; each under 5 minutes)
```bash
cd ~/cma && cma_db prod && for p in a b c; do sed "s/select set_config('verify.part', 'all', false);/select set_config('verify.part', '$p', false);/" db/131_time_all.sql | psql "$PGCONN" -X > /tmp/131-$p-before.txt 2>&1; done; psql "$PGCONN" -X -f db/124_time_flash.sql > /tmp/124-before.txt 2>&1; grep -h verdict /tmp/131-?-before.txt /tmp/124-before.txt
```
Expected: four verdict lines (FAIL rows are the reads over budget, as on 24 November).

Records: `node tools/check-records.mjs records/n07-prod-2026-11-26` before any commit of these outputs.

## 1. Dev

**1a. Terminal** (the concurrent index on a busy table, dev; one statement, then the check)
```bash
cd ~/cma && cma_db dev && psql "$PGCONN" -X -c "set role cma_owner" -c "set lock_timeout = '5s'" -c "set statement_timeout = '10min'" -c "create index concurrently if not exists subscription_event_paused_idx on cma.subscription_event (tenant_id, connection_id, subscription_source_id, occurred_at desc) where status_to = 'paused'"
```
```bash
cd ~/cma && cma_db dev && psql "$PGCONN" -X -c "select indexrelid::regclass, indisvalid from pg_index where indexrelid = 'cma.subscription_event_paused_idx'::regclass"
```
Expected: `CREATE INDEX`, then `t`. An `f`: `drop index concurrently` that index and build it again (the
night's first local build came out invalid while long verify transactions held their locks).

**1b. Terminal** (N07a: `236` twice, then its verify normal and provoked, then the reruns; checkout the N07a branch)
```bash
cd ~/cma && git fetch origin && git checkout claude/clever-goodall-7wnx9z && cma_db dev && run_migration db/236_jobs_off_the_vcpu.sql && run_migration db/236_jobs_off_the_vcpu.sql && psql "$PGCONN" -X -f db/237_verify_jobs_off_the_vcpu.sql | tail -15
```
Expected: `INSERT 0 1 COMMIT`, then `INSERT 0 0 COMMIT`; 237: S1, G1 to G4, F1 to F4, L1, L2 OK and `PASS 0009zr`.
Provoked (set `verify.provoke` to `true` at the top of a copy): every row FAIL, F1, L1 and L2 saying "1 rows differ".
Then each of 41, 73, 75, 81, 95, 151, 155, 179, 191, 211, 213, 217, 219, 221, 223, 225, 235 (191 and 235 edited by
N07a): its PASS line, as before. 73, 75, 81 and 95 run in dev only.

**1c. Terminal** (N07c: `238`, `239`, the reruns 83, 91, 101)
```bash
cd ~/cma && git checkout claude/clever-goodall-7wnx9z-n07c && cma_db dev && run_migration db/238_email_not_responding_speed.sql && psql "$PGCONN" -X -f db/239_verify_email_not_responding_speed.sql | tail -6
```
Expected: `PASS 0009zs` (E1 to E3); provoked E2 "1 rows differ".

**1d. Terminal** (N07f, dev first: `240`, `241`, the reruns 77, 107, 113, 169, 195, 197)
```bash
cd ~/cma && git checkout claude/clever-goodall-7wnx9z-n07f && cma_db dev && run_migration db/240_audit_and_retention.sql && psql "$PGCONN" -X -f db/241_verify_audit_and_retention.sql | tail -7
```
Expected: `PASS 0009zt` (R1, A1, P1).

**1e. Terminal** (the schema snapshot for the data map, on each branch that changed a column: N07a)
```bash
cd ~/cma && git checkout claude/clever-goodall-7wnx9z && node tools/datamap/snapshot.mjs dev && node tools/datamap/build.mjs && git status --short docs/datamap
```
Expected: `docs/datamap/schema.json` and `index.html` changed (two columns of `cma.subscription_take_state`); commit them on the branch; `npm run verify:datamap` in `web/` PASS.

## 2. Merges

**Browser:** review and squash-merge N07a, then retarget N07b to `main`, merge, and so on to N07f. Each merge that
touches `web/**` or `cloudbuild.yaml` builds and deploys prod (Cloud Build trigger `cma-web-main`): watch each build
finish green before the next merge. N07a adds the substitution `_DB_SESSION_OPTIONS` (empty) to `cloudbuild.yaml`: add it to the
trigger as an empty value. Expected: six green builds; the Workspace opens after each.

## 3. Prod (outside office hours)

**3a. Terminal:** the index of 1a against prod (`cma_db prod`), then the `indisvalid` check. Expected: `t`.

**3b. Terminal:** `236` twice and `237` against prod as in 1b; then `238` and `239` as in 1c. Expected: `PASS 0009zr`, `PASS 0009zs`; the prod reruns of 1b and 1c (not 73, 75, 81, 95) PASS.

**3c. After `244` (0009zv) in prod:** `240` and `241` against prod as in 1d. Expected: `PASS 0009zt`.

## 4. The jobs' deploys (after the N07a merge's build)

**Terminal** (every minute again, with the waits in place)
```bash
cd ~/cma && SHA=$(git rev-parse --short origin/main) && bash docs/scheduler/deploy-active-customers.sh prod $SHA && bash docs/scheduler/deploy-follow-up.sh prod $SHA && bash docs/scheduler/deploy-data-quality.sh prod $SHA && bash docs/scheduler/deploy-flash.sh prod $SHA && gcloud scheduler jobs describe cma-refresh-active-customers-minutely --location=europe-west4 --project=p4a-cma-prod --format='value(schedule)'
```
Expected: four deploys, then `* * * * *`. After ten minutes, **Studio (cma-prod-pg)**, OPERATIONS 4.1's query: rows with
`defer_wait` only in busy minutes, no `timeout_wait` unless a timeout happened.

## 5. Analyze the small configuration tables

**Studio (cma-prod-pg)**
```sql
set role cma_owner;
analyze cma.setting; analyze cma.tenant_setting; analyze cma.market; analyze cma.market_alias; analyze cma.business_hours;
analyze cma.business_holiday; analyze cma.telephony_tag; analyze cma.app_user_external_id;
reset role;
```
Expected: `ANALYZE` eight times. From `236` on, a handful of edits analyzes them again by itself.

## 6. The first `sync_run` purge (after `240` in prod and the N07f ingest image)

**Terminal** (outside office hours; the reconcile purges at most 50 batches of 2,000 per tenant a night; the first time
by hand, watched)
```bash
cd ~/cma && gcloud run jobs execute ingest-reconcile --region=europe-west4 --project=p4a-cma-prod --wait && gcloud logging read 'resource.type="cloud_run_job" AND jsonPayload.message="reconcile: sync_run retention"' --project=p4a-cma-prod --freshness=1h --format='value(jsonPayload.tenant,jsonPayload.deleted,jsonPayload.batches,jsonPayload.more,jsonPayload.ms)'
```
Expected: one line per tenant with `deleted`, `batches`, `more` (true while more than 100,000 rows wait: the next nights
continue) and `ms`. System health's 24-hour counts unchanged (the hourly bookkeeping keeps its counts).

## 7. `CMA_DB_SESSION_OPTIONS`, one setting at a time

The local table (NIGHT_NOTES.md, WP5) proposes `jit=off` first. In dev: set the trigger's `_DB_SESSION_OPTIONS` to
`jit=off`, merge-free redeploy (**Terminal**, `gcloud builds triggers run cma-web-dev …` as RUNBOOK 10), then `131` parts a,
b, c in dev against the morning's dev run. Keep it when no read is more than 10 % slower; then prod the same way, and the
jobs' deploy scripts with `DB_SESSION_OPTIONS=jit=off` in the shell. Then `work_mem=16MB`, then `random_page_cost=1.1`,
each on its own. Expected: a table of 131's reads per setting, written to `records/`.

## 8. Prod "after" (a working day later)

Steps 0a to 0c again, into `*-after.txt`; with N07d deployed also:
```bash
cd ~/cma && node tools/perf/request-percentiles.mjs /tmp/requests-1d.json --kind document && node tools/perf/request-percentiles.mjs /tmp/requests-1d.json --kind navigation && node tools/perf/request-percentiles.mjs /tmp/navigation-1d.json --navigation
```
Expected: `/api/v1/me/messages` p95 at or under 80 ms, `/live/[org]` p95 at or under 400 ms, navigations' time to first
frame per route. The table for the decision log: NIGHT_NOTES.md, Expected results.

## 9. The Gemini prompt (WP9)

**Browser** (Gemini in the Google Cloud console, project p4a-cma-prod):

> For Cloud SQL instance cma-prod-pg (1 vCPU, 3.75 GB, Postgres 18) and Cloud Run service cma-web: from the last 7 days
> show (1) CPU utilisation per hour in office hours (07:00 to 18:00 Europe/Amsterdam) and its p95; (2) the share of time
> CPU was over 80 %; (3) the same for the hours after the N07 deploy; (4) whether db-custom-2-7680 with high availability
> would have kept p95 CPU under 60 %, and its monthly price difference; (5) cma-web's container CPU and memory p95 per
> revision, and whether --cpu=2 or the second-generation execution environment would cut request latency given the
> Server-Timing total and db durations in the request log. Answer with numbers and the queries you used.

Expected: numbers for NIGHT_NOTES' WP9 proposals; nothing is changed (D1: no tier change).

## 10. The heads-up to Yordi (D12)

**Browser** (mail or chat to Yordi; the line is in `docs/open-decisions.md`):

> From addition 0009zt the CMA no longer writes an audit row when the ingest copies a source change into nine of its
> mirror tables (subscriptions, billing events, email, order lines, record stages); `cma.ingest_event` and the polls'
> run rows keep those changes. The CRM's records, contacts, calls and tasks and the telephony calls stay audited for now. People's changes and
> every configuration change stay audited; existing audit rows stay. May we run it in prod?

Done: Yordi agreed on 25 November 2026 to D12 as narrowed in N07f (Martin), so step 3c no longer waits.
