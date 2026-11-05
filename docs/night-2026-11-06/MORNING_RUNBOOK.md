# Morning runbook, N06: the fastest Workspace we can build (addition 0008zr)

Written in the night of 5 to 6 November 2026 by Claude Code. Labels: **Browser**, **Terminal** (Martin's own Linux terminal, Chromebook Linux or his Linux machine, in `~/cma` unless stated; a step against prod names it), **Studio (cma-dev-pg)** or **Studio (cma-prod-pg)** (Cloud SQL Studio, as `cma_owner` unless stated), **File** (a repository path). SQL and shell never in one block. Every step says what to expect and how long it takes. `NIGHT_NOTES.md` has the figures, the design and the remainder; `local-records/` the container's outputs.

**What changes** (Decision log, 5 November 2026):
- **0008zr** (`132`, `133`): seven reads rewritten to the same answers (`cma.sources()`'s held kinds, `cma.system_health_runs`, the missed callbacks, Calls, Intake, the open tickets and tasks), `jit = off` on six set functions, `cma.inbound_now()`; data quality stored per tenant (`cma.data_quality_snapshot`, `cma.data_quality_finding`), the setting `data_quality.refresh_minutes` (5), the permission `data_quality.refresh`, the job `refresh_data_quality` and its Cloud Run job `cma-refresh-data-quality` (pool 1, every minute). Proven row for row by `133` against the previous definitions. Also `130_census.sql` and `131_time_all.sql` (measuring scripts, read only or rolled back), `web/verify/perf-volume-fixture.sql` (local only), `verify:perf`, `tools/perf/request-percentiles.mjs`.
- **Web (N06b)**: a route skeleton per page and the rail's prefetch, Welcome streamed per block, the Live board as one read polled at `GET /api/v1/live/board`, copy slices, the tenant settings cached 30 s per instance, Montserrat as a woff2 subset, "Refreshed at" on Data quality and Flash, polls only while visible with backoff.
- **No index, no autovacuum setting, no flag, no retention tonight**: proposals in `NIGHT_NOTES.md`, each with its cost; step 3b holds the autovacuum block to run only when prod's census says so, and the concurrent index pattern for the day one is needed.

**The number.** 0008zr, `130` to `133`, as briefed: free on `main` at `8643d17` and in the open pull requests (`NIGHT_NOTES.md`, The number). Both branches are on `main` at `8643d17`; N06b is on N06a.

**Order matters:**
- `132` runs in dev and prod **before** the merge of N06a and both merges: `main`'s web keeps working on the migrated database (every function keeps its signature; `cma.data_quality()` keeps its columns and the web of `main` ignores `computed_at`; the Live board of `main` reads `cma.inbound_today`, `cma.missed_callbacks` and the summary as before, which still exist). Merged first, N06b's web would call `cma.inbound_now()` and `cma.data_quality_computed_at()` that are not there: the Live board and Data quality would fail until `132` ran.
- N06a before N06b: N06b's branch contains N06a's commit; GitHub marks N06b's base as N06a's branch, and after N06a's squash-merge N06b is rebased or retargeted to `main` (step 4).
- The job's deploy (`deploy-data-quality.sh`) comes **after** the merge of N06a: the image must hold `web/jobs/refresh-data-quality.mjs`. Until it is deployed the pages show the result `132` computed, and its "Refreshed at" does not move: fine for an hour, not for a day.
- Scripts that have run in prod: none changes.
- The two time scripts and the census read prod; `131` writes nothing that survives (rolled back, its own proof row), `130` is read only. Both run from the Terminal with psql so their output lands in `records/` and no 300 s applies.

| Step | What | Elapsed |
|---|---|---|
| 0 | The prod "before": log percentiles per route, the census, `131` parts a, b, c, `124`; the Query Insights question | 25 min, 10 of them unattended |
| 1 | Review both pull requests, build N06b locally, the pure verifiers; do not merge | 20 min |
| 2 | Dev: `132` twice, `133` normal and provoked, the earlier verifies, `131` part a and `124` again, the schema snapshot | 15 min |
| 3 | Prod, before the merge: point-in-time recovery, `132` twice, `133`, the earlier verifies, `131` part a and `124`: every read at or under its budget, or stop with the figures; the autovacuum block only if 0b says so | 20 min |
| 4 | Merge N06a, then N06b; watch the builds; deploy the job; `verify:api` against dev; the compression check | 30 min |
| 5 | Prod "after": `131` and `124` again now; the log percentiles after a working day, in a table for the decision log | 10 min now, 10 min tomorrow |
| 6 | The Gemini audit (the job, the log-based metric, the alert policy, the Cloud SQL questions) | 15 min |
| 7 | Rollback, if needed | 5 to 10 min |

---

## Helpers

The terminal is set up as `docs/RUNBOOK.md`, Setup (once per machine), step 8: `cma_db` and `run_migration` in `~/.cma_helpers.sh`. This runbook uses `cma_db` and adds none.

**Terminal**
```bash
cd ~/cma && node -v && bash -ic 'type -t cma_db run_migration'
```
Expected: `v22.…`, then `function` twice.

## 0. The prod "before"

**0a. The log percentiles per route, last 7 days** (the request log line is the truth; `tools/perf/request-percentiles.mjs` is on the N06a branch, so check it out first or run it from the pull request's files).

**Terminal** (from the Chromebook; reads prod's logs, writes routes and numbers only)
```bash
cd ~/cma && git fetch -q origin claude/youthful-meitner-ve6gtm && git checkout -q claude/youthful-meitner-ve6gtm && mkdir -p records/n06-prod-2026-11-06
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="cma-web" AND jsonPayload.message="request"' --project=p4a-cma-prod --freshness=7d --limit=200000 --format=json > /tmp/requests-before.json
node tools/perf/request-percentiles.mjs --pages --api < /tmp/requests-before.json | tee records/n06-prod-2026-11-06/percentiles-before.txt
```
Expected: one line per route with `n`, p50, p75, p95, p99, max in ms, the share over 800 ms and the 5xx count, the busiest route first; `/live/board`, `/api/v1/telephony/inbound-now`, `/configuration/sources`, `/reports/flash?o=data_quality` and `/reports/data-quality` near the top. The read takes 1 to 3 minutes for 7 days. Keep the file: step 5 compares against it. Then `git checkout main -q`.

**0b. The census** (read only; counts, sizes and index names, never a row)

**Terminal** (prod)
```bash
cd ~/cma && rec=records/n06-prod-2026-11-06 && cma_db prod
psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/130_census.sql > "$rec/130_census.txt" 2>&1; echo "130: $(grep -E ' verdict' "$rec/130_census.txt" | tr -s ' ')"
grep -E "health (ingest_event|sync_run|subscription_event)|unused index|pg_stat_statements" "$rec/130_census.txt" | tr -s ' '
```
Expected: `130:  verdict | PASS | 130_census: <n> rows; <k> table(s) of 10000 rows or more, <u> unused index(es), <f> fk(s) without index`, under a minute. Read the three `health` lines: `dead <n> (<p>% of live)` and the last autovacuum and autoanalyze. **Above 20 % dead or statistics older than a day on any of the three: step 3b runs its block; otherwise 3b is skipped.** The `unused index` lines are prod's answer to NIGHT_NOTES' proposal (listed, not dropped). The `pg_stat_statements` line says `not installed` today (step 0d).

**0c. Every read timed, before `132`** (`131` acts as the application per tenant, rolled back; `124` read only)

**Terminal** (prod; about 10 minutes unattended at prod's volume, part c the longest)
```bash
cd ~/cma && rec=records/n06-prod-2026-11-06 && cma_db prod
for part in a b c; do sed "s/select set_config('verify.part', 'all', false);/select set_config('verify.part', '$part', false);/" db/131_time_all.sql > /tmp/131-$part.sql
  psql "$PGCONN" -v ON_ERROR_STOP=0 -f /tmp/131-$part.sql > "$rec/131_time_all-$part-before.txt" 2>&1; echo "131 $part: $(grep -E ' verdict' "$rec/131_time_all-$part-before.txt" | tr -s ' ')"; done
psql "$PGCONN" -v ON_ERROR_STOP=0 -f db/124_time_flash.sql > "$rec/124_time_flash-before.txt" 2>&1; echo "124: $(grep -E ' verdict' "$rec/124_time_flash-before.txt" | tr -s ' ')"
grep -E "rolled back" "$rec/131_time_all-a-before.txt" | tr -s ' '
```
Expected: three `131` verdict lines `131_time_all (part a|b|c): <ok> ok, <fail> FAIL, <skip> skip; worst <ms> ms (<tenant> <page>: <read>)`, one `124` line, and the `rolled back | info | … 0 audit row(s) of its writes remain` proof. The FAILs are the reads over budget before the change: expected on Sources, the connection page, System health, the three missed-callback polls, the data quality reads, Intake, Calls, Attempts, Funnel, Speed to lead and Lead cohorts (NIGHT_NOTES, Before and after). A `131` run that is refused with `25006` or a lock error: send me the first `ERROR` line of the file.

**0d. `pg_stat_statements` and Query Insights: a question, not a change.** The census's top-statements block needs `pg_stat_statements`, which on Cloud SQL is the flag `shared_preload_libraries=pg_stat_statements` (a restart, a failover on HA) plus `create extension`. Query Insights needs no flag and no restart. Neither is enabled tonight; the Gemini prompt of step 6 asks for the exact flag names, the restart, the cost and whether the standard Query Insights is included in Enterprise's price, with the gcloud commands for you to run, before you decide.

## 1. Review and the local build of both pull requests

**Browser:** N06a (`claude/youthful-meitner-ve6gtm`) and N06b (`claude/youthful-meitner-ve6gtm-n06b`) on GitHub: the descriptions carry the before and after tables, the night defaults and the verifier counts; `NIGHT_NOTES.md` the rest. Do not merge yet.

**Terminal** (N06b holds N06a: one checkout builds both)
```bash
cd ~/cma && git fetch -q origin claude/youthful-meitner-ve6gtm-n06b && git checkout -q claude/youthful-meitner-ve6gtm-n06b && git log --oneline -3
cd web && npm ci --silent && npm run build 2>&1 | tail -3 && npm run typecheck 2>&1 | tail -1 && npm run lint 2>&1 | tail -2
for v in copy corrections csv dashboard live team roster configuration messages import devices-import datamap signed-out invitations preview follow-up reports flash period health boundaries jobs metrics cache; do printf "%s: " $v; npm run --silent verify:$v 2>&1 | tail -1; done; cd ..
```
Expected: three commits (N06b, N06a, N05's #227); the build's route list ending in `ƒ Proxy (Middleware)`; `✓ Types generated successfully`; lint `0 errors, 2 warnings` (both pre-existing); every verifier `PASS` or `ALL n PASS` with the counts of NIGHT_NOTES (copy 3,422 keys, configuration 121, reports 215, flash 64, live 43, jobs 31, cache 8, …). `datamap` fails here with three problems (the two new tables are not in `schema.json` yet, and `index.html` is older than the catalog): expected until step 2's snapshot and build. About 5 minutes.

## 2. Dev: `132` twice, `133` normal and provoked, the earlier verifies, the time scripts, the schema snapshot

**Terminal** (dev)
```bash
cd ~/cma && rec=records/n06-dev-2026-11-06 && mkdir -p "$rec" && cma_db dev
psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/132_perf.sql > "$rec/132.txt" 2>&1; echo "132: $(tail -3 "$rec/132.txt" | tr '\n' ' ')"
psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/132_perf.sql > "$rec/132-rerun.txt" 2>&1; echo "132 again: $(tail -3 "$rec/132-rerun.txt" | tr '\n' ' ')"
psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/133_verify_perf.sql > "$rec/133.txt" 2>&1; echo "133: $(grep -E ' verdict' "$rec/133.txt" | tr -s ' ')"
sed "s/select set_config('verify.provoke', 'false', false);/select set_config('verify.provoke', 'true', false);/" db/133_verify_perf.sql > /tmp/provoke.sql
psql "$PGCONN" -v ON_ERROR_STOP=0 -f /tmp/provoke.sql > "$rec/133-provoked.txt" 2>&1; echo "provoked: $(grep -E ' verdict' "$rec/133-provoked.txt" | tr -s ' ')"
```
Expected: `connected to cma as martin@pulse4all.com`; `132: INSERT 0 1 COMMIT RESET` (the first run also computes every active tenant's first data-quality result: 5 to 30 s); `132 again: INSERT 0 0 COMMIT RESET`; `133:  verdict | 0008zr verified | 133_verify_perf: 20 ok, 0 FAIL, 1 skip` (the skip is a tenant where no active person holds `tenant.configure`, the invest tenant locally; `0 skip` when every tenant has one); `provoked:  verdict | PROVOKED, NOT A PASS | 133_verify_perf: 0 ok, 20 FAIL, 1 skip`. Any other `133` line: send me `grep -E 'FAIL|ERROR' "$rec/133.txt"`. About 3 minutes.

**Terminal** (dev: the earlier verifies of every function `132` touches, unchanged and still passing)
```bash
cd ~/cma && rec=records/n06-dev-2026-11-06 && for f in 41_verify_lead_metrics 53_verify_sources_configuration 61_verify_inbound_service 63_verify_calls_overview 73_verify_follow_up 75_verify_forms_reporting 79_verify_system_health 81_verify_follow_up_snapshot 123_verify_flash 129_verify_sources_last_read; do
  psql "$PGCONN" -v ON_ERROR_STOP=0 -f "db/$f.sql" > "$rec/${f%%_*}-rerun.txt" 2>&1; echo "$f: $(grep -E ' verdict' "$rec/${f%%_*}-rerun.txt" | tail -1 | tr -s ' ')"
done
```
Expected: `53 … PASS | 16 PASS`, `61 … 20 PASS`, `63 … 19 PASS`, `73 … 21 PASS`, `75 … 24 PASS`, `79 … 13 PASS`, `81 … 19 PASS`, `123 … 33 ok, 0 FAIL, 4 skip` (prod's real `uuidv7`; locally one FAIL from the shim), `129 … 15 PASS`; `41` prints its tenant table and `verdict` column `ok`. About 3 minutes.

**Terminal** (dev: the time scripts after `132`; `131` part a holds the polls and the pages)
```bash
cd ~/cma && rec=records/n06-dev-2026-11-06 && sed "s/select set_config('verify.part', 'all', false);/select set_config('verify.part', 'a', false);/" db/131_time_all.sql > /tmp/131-a.sql
psql "$PGCONN" -v ON_ERROR_STOP=0 -f /tmp/131-a.sql > "$rec/131_time_all-a.txt" 2>&1; echo "131 a: $(grep -E ' verdict' "$rec/131_time_all-a.txt" | tr -s ' ')"
psql "$PGCONN" -v ON_ERROR_STOP=0 -f db/124_time_flash.sql > "$rec/124_time_flash.txt" 2>&1; echo "124: $(grep -E ' verdict' "$rec/124_time_flash.txt" | tr -s ' ')"
grep -E "sources: sources|system health runs|missed callbacks|data quality checks|calls previous month: history start" "$rec/131_time_all-a.txt" | tr -s ' '
```
Expected: at dev's volume every row `ok` except, possibly, the three missed-callback polls (over 20 ms wherever telephony has calls; NIGHT_NOTES remainder 6). The `history start` line: 28 ms locally before `132`, 265 after (NIGHT_NOTES, Open); if it is over its 50 ms here too, tell me the figure, the fix is one line in a follow-up.

**Terminal** (dev: the data map's schema snapshot, on this branch, then commit it with the catalog; `docs/RUNBOOK.md`, Setup step 9)
```bash
cd ~/cma && git checkout -q claude/youthful-meitner-ve6gtm && psql "$PGCONN" -X -qAt -v ON_ERROR_STOP=1 -f tools/datamap/schema.sql > docs/datamap/schema.json && head -c 60 docs/datamap/schema.json; echo
node tools/datamap/build.mjs && cd web && npm run --silent verify:datamap; cd .. && git add docs/datamap/schema.json docs/datamap/index.html && git commit -q -m "Data map: schema snapshot from dev after 0008zr" && git push -q origin claude/youthful-meitner-ve6gtm && git log --oneline -1
```
Expected: `{"generated_at" : "…`; the data map's build line; `datamap: PASS (104 tables, 158 views, all described; index.html current)` (on the branch before this step it fails with three problems, the two new tables not in the snapshot and the index older than the catalog: expected, CLAUDE.md Database); the commit on N06a's branch. N06b is rebased on it in step 4. After the merge: in the Claude project, say "republish the data map".

## 3. Prod, just before the merge: point-in-time recovery, `132` twice, `133`, the earlier verifies, the time scripts

**Terminal** (from the Chromebook; point-in-time recovery on, as before every prod migration)
```bash
gcloud sql instances describe cma-prod-pg --project=p4a-cma-prod --format="value(settings.backupConfiguration.pointInTimeRecoveryEnabled,settings.backupConfiguration.transactionLogRetentionDays)"
```
Expected: `True	7`.

**Terminal** (prod)
```bash
cd ~/cma && rec=records/n06-prod-2026-11-06 && cma_db prod
psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/132_perf.sql > "$rec/132.txt" 2>&1; echo "132: $(tail -3 "$rec/132.txt" | tr '\n' ' ')"
psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/132_perf.sql > "$rec/132-rerun.txt" 2>&1; echo "132 again: $(tail -3 "$rec/132-rerun.txt" | tr '\n' ' ')"
psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/133_verify_perf.sql > "$rec/133.txt" 2>&1; echo "133: $(grep -E ' verdict' "$rec/133.txt" | tr -s ' ')"
for f in 41_verify_lead_metrics 53_verify_sources_configuration 61_verify_inbound_service 63_verify_calls_overview 73_verify_follow_up 75_verify_forms_reporting 79_verify_system_health 81_verify_follow_up_snapshot 123_verify_flash 129_verify_sources_last_read; do
  psql "$PGCONN" -v ON_ERROR_STOP=0 -f "db/$f.sql" > "$rec/${f%%_*}-rerun.txt" 2>&1; echo "$f: $(grep -E ' verdict' "$rec/${f%%_*}-rerun.txt" | tail -1 | tr -s ' ')"
done
```
Expected: as in dev: `INSERT 0 1 COMMIT RESET` (the first result for the two tenants: the data-quality computation took 2.1 to 3.5 s in prod on 3 November 2026, so under a minute), `INSERT 0 0 COMMIT RESET`, `133 … 20 ok, 0 FAIL, 0 skip` (every prod tenant has a `tenant.configure` holder; `1 skip` otherwise), the earlier verifies as above. `main`'s web keeps running on it (Order matters). About 5 minutes.

**Terminal** (prod: the time scripts after `132`; the gate)
```bash
cd ~/cma && rec=records/n06-prod-2026-11-06 && for part in a b; do sed "s/select set_config('verify.part', 'all', false);/select set_config('verify.part', '$part', false);/" db/131_time_all.sql > /tmp/131-$part.sql
  psql "$PGCONN" -v ON_ERROR_STOP=0 -f /tmp/131-$part.sql > "$rec/131_time_all-$part-after.txt" 2>&1; echo "131 $part: $(grep -E ' verdict' "$rec/131_time_all-$part-after.txt" | tr -s ' ')"; done
psql "$PGCONN" -v ON_ERROR_STOP=0 -f db/124_time_flash.sql > "$rec/124_time_flash-after.txt" 2>&1; echo "124: $(grep -E ' verdict' "$rec/124_time_flash-after.txt" | tr -s ' ')"
grep -E "sources: sources|the connection |system health runs|missed callbacks|data quality|intake per day|calls previous month: overview" "$rec/131_time_all-a-after.txt" "$rec/131_time_all-b-after.txt" | tr -s ' '
```
Expected: every read `132` rewrote at or under its budget: Sources ≤ 150 ms (895 ms in prod before), the connection ≤ 150, System health ≤ 500, the data quality reads ≤ 500, the open tasks and tickets within `124`'s budgets; the missed-callback polls well under their "before" and, at prod's volume, likely 50 to 150 ms (over the 20 ms budget: remainder 6, known). **A rewritten read slower than its "before" line of 0c: stop here and send me both lines; the merge waits.** The reads `132` did not touch (Attempts, Funnel, Speed to lead, Lead cohorts) stay as in 0c. About 8 minutes.

**3b. The autovacuum block, only when 0b said so** (dead rows above 20 % or statistics older than a day on `ingest_event`, `sync_run` or `subscription_event`; night default N06-3). One statement per table, a short lock, no rewrite; the next autovacuum picks the new thresholds up.

**Studio (cma-prod-pg)** (only the tables 0b named)
```sql
set role cma_owner;
alter table cma.ingest_event set (autovacuum_vacuum_scale_factor = 0.02, autovacuum_analyze_scale_factor = 0.01);
alter table cma.sync_run set (autovacuum_vacuum_scale_factor = 0.02, autovacuum_analyze_scale_factor = 0.01);
select relname, reloptions from pg_class where relname in ('ingest_event', 'sync_run', 'subscription_event') and relnamespace = 'cma'::regnamespace;
reset role;
```
Expected: `ALTER TABLE` per statement, then the options per table. Write what you ran into `records/n06-prod-2026-11-06/README.md` and I add the decision row. Not run when 0b showed nothing.

**3c. The concurrent index pattern, for the day one is needed (none tonight).** From the Terminal, never Studio (Studio wraps a script in a transaction and `concurrently` refuses it); one statement per index with its own timeouts; `indisvalid` checked after; an invalid index is dropped and created again:

**Terminal** (the pattern, with a made-up name; nothing to run today)
```bash
cd ~/cma && cma_db prod && psql "$PGCONN" -v ON_ERROR_STOP=0 -c "set lock_timeout = '5s'; set statement_timeout = '10min'; create index concurrently if not exists <name> on cma.<table> (<columns>) where <predicate>;" \
  -c "select c.relname, i.indisvalid from pg_index i join pg_class c on c.oid = i.indexrelid where c.relname = '<name>';"
```
Expected: `CREATE INDEX`, then one row `<name> | t`. An `f`: `drop index concurrently cma.<name>;` and run it again, outside office hours or between 12:00 and 13:00; at prod's `ingest_event` size (about 500,000 rows) an index builds in under a minute.

## 4. Merge N06a, then N06b; the builds; the job; `verify:api` against dev; the compression check

**Terminal** (from the Chromebook; N06a first)
```bash
cd ~/cma && gh pr merge <N06a number> --squash --delete-branch && git switch main -q && git pull -q && git log --oneline -1
```
Expected: the merge commit of N06a. N06a touches `web/` (`package.json`, the verifiers, the job) so a build runs; it changes nothing a page reads, so prod's web after it behaves as before. Then N06b: GitHub offers to retarget it to `main` when its base branch is deleted; if it shows N06a's commit again, rebase it first:

**Terminal** (N06b onto `main`, only if the pull request shows two commits after N06a's merge)
```bash
cd ~/cma && git fetch -q origin && git checkout -q claude/youthful-meitner-ve6gtm-n06b && git rebase -q origin/main && git push -q --force-with-lease origin claude/youthful-meitner-ve6gtm-n06b && git log --oneline -2
```
Expected: N06b's one commit on top of `main`'s merge commit. Then:

**Terminal** (merge N06b, watch the prod build)
```bash
cd ~/cma && gh pr merge <N06b number> --squash --delete-branch && git switch main -q && git pull -q && git log --oneline -1
gcloud builds list --project=p4a-cma-prod --region=europe-west4 --limit=2 --format="table(status,substitutions.SHORT_SHA,createTime.date('%H:%M'))"
```
Expected: the merge commit; two builds (N06a's and N06b's short SHAs), `QUEUED` or `WORKING`, then `SUCCESS` (`docs/RUNBOOK.md` section 3; a build appears 2 to 4 minutes after its merge). No build 4 minutes after the merge: `gcloud builds triggers run cma-web-main --project=p4a-cma-prod --region=europe-west4 --branch=main`.

**4a. The job** (after N06b's build is `SUCCESS`; OPERATIONS 1 and 5; the connection budget: pool 1, 92 of 93 used)

**Terminal** (prod, then dev)
```bash
cd ~/cma && sha=$(git log --format=%h -1) && bash docs/scheduler/deploy-data-quality.sh prod $sha 2>&1 | tail -4
bash docs/scheduler/deploy-data-quality.sh dev $sha 2>&1 | tail -4
gcloud scheduler jobs list --project=p4a-cma-prod --location=europe-west4 --filter="name:cma-refresh" --format='table(name.basename(),schedule,state,lastAttemptTime)'
```
Expected: the job `cma-refresh-data-quality` created and the schedule `cma-refresh-data-quality-minutely` (`* * * * *`, `ENABLED`) in each project; two minutes later a `lastAttemptTime`. Then its log line:

**Terminal** (prod; OPERATIONS 8)
```bash
gcloud logging read 'resource.type=cloud_run_job AND resource.labels.job_name=cma-refresh-data-quality AND jsonPayload.message="refresh-data-quality"' --project=p4a-cma-prod --freshness=10m --limit=6 --format='table(timestamp, severity, jsonPayload.tenant_id, jsonPayload.refreshed, jsonPayload.reason, jsonPayload.rows, jsonPayload.duration_ms)'
```
Expected: one line per tenant per run: `INFO` with `refreshed False` and `reason fresh` while the result is younger than 5 minutes, then every fifth minute `refreshed True` with `rows <n>` and `duration_ms` (2,000 to 4,000 at prod's size); the run row's counts carry `skipped` 1 or 0. An `ERROR` line: OPERATIONS 4 and 5 (pause it; the pages keep the last result).

**4b. `verify:api` against dev on N06b's image** (`docs/RUNBOOK.md` section 4; inside 07:00 to 22:00 Amsterdam)
```bash
sha=<N06b's merge short SHA>
gcloud run services update cma-web --project=p4a-cma-dev --region=europe-west4 \
  --image=europe-west4-docker.pkg.dev/p4a-cma-prod/cma/web:$sha 2>&1 | tail -1
pkill -f "run services proxy"; gcloud run services proxy cma-web --project=p4a-cma-dev \
  --region=europe-west4 --port=8080 >/tmp/proxy.log 2>&1 & sleep 6
curl -s localhost:8080/api/health; echo
cd ~/cma/web && node verify/api.mjs | tee ../records/n06-dev-2026-11-06/verify-api.txt | grep -E "FAIL|ALL|FAILED"; echo "exit ${PIPESTATUS[0]}"
node verify/api.mjs --provoke | tail -1; echo "exit ${PIPESTATUS[0]}"; BASE=http://localhost:8080 node verify/round-trips.mjs | tail -1; cd ~/cma
```
Expected: the new revision serving 100 percent; the health answer with `version` the short SHA, auth `mock`, data `api`; `ALL n PASS` with n the count of `local-records/web/verify-api-local.txt` plus dev's own sources checks; provoked `FAILED`; `round-trips: PASS` on dev's data (the budgets are the tightened ones).

**4c. Compression behind IAP** (a header check; nothing to change tonight)

**Browser:** open the Workspace, DevTools → Network, reload Welcome, click the document request (`/`) → Response Headers: `content-encoding`. Then one `/_next/static/chunks/…js` request: `cache-control`.
Expected: `content-encoding: gzip` or `br` on the document (Cloud Run compresses an HTML answer when the browser asks; the load balancer passes it through) and `cache-control: public, max-age=31536000, immutable` on the chunk. No `content-encoding` on the document: tell me the headers you see; it means the answer is sent uncompressed behind IAP and a `compress` step in the web's middleware is the follow-up (NIGHT_NOTES, Not verified locally).

**4d. The log-based metric and the alert policy** (WP4.1; the Gemini prompt of step 6 audits them before you create them)

**File:** `/tmp/cma-web-total-ms.yaml`
```yaml
name: cma_web_total_ms
description: "cma-web request time (jsonPayload.totalMs) per route, from the request log line"
filter: 'resource.type="cloud_run_revision" AND resource.labels.service_name="cma-web" AND jsonPayload.message="request"'
valueExtractor: "EXTRACT(jsonPayload.totalMs)"
metricDescriptor:
  metricKind: DELTA
  valueType: DISTRIBUTION
  unit: ms
  labels:
    - key: route
      valueType: STRING
labelExtractors:
  route: "EXTRACT(jsonPayload.route)"
bucketOptions:
  exponentialBuckets:
    numFiniteBuckets: 32
    growthFactor: 1.4
    scale: 5
```

**Terminal** (prod)
```bash
gcloud logging metrics create cma_web_total_ms --config-from-file=/tmp/cma-web-total-ms.yaml --project=p4a-cma-prod && gcloud logging metrics describe cma_web_total_ms --project=p4a-cma-prod --format="value(name,metricDescriptor.valueType)"
```
Expected: `Created [cma_web_total_ms].`, then `cma_web_total_ms DISTRIBUTION`. The metric fills from now on (not backwards). The dashboard: Console → Monitoring → Metrics explorer → `logging/user/cma_web_total_ms`, aligner 95th percentile, group by `route`, save as the dashboard "CMA web p95 per route" (OPERATIONS 10 reads it daily). The alert policy on the agent pages' p95 (the targets: 400 ms) to "CMA ingest alerts", as OPERATIONS 9's four: condition `logging.googleapis.com/user/cma_web_total_ms`, aligner `ALIGN_PERCENTILE_95` over 10 minutes, filter `metric.label.route` one of `/`, `/day`, `/hours`, `/messages`, `/schedule`, `/live/board`, threshold 400 for 15 minutes; create it in the Console after the Gemini audit says the condition is right, and add its row to OPERATIONS 9 (I do that from your report).

## 5. Prod "after"

**Now** (after both merges and the job): `131` parts a and b and `124` once more, as in step 3's gate (the figures to keep are step 3's, taken on the same prod data minutes earlier; this run proves the deployed web did not change the database side):

**Terminal** (prod)
```bash
cd ~/cma && rec=records/n06-prod-2026-11-06 && cma_db prod && sed "s/select set_config('verify.part', 'all', false);/select set_config('verify.part', 'a', false);/" db/131_time_all.sql > /tmp/131-a.sql
psql "$PGCONN" -v ON_ERROR_STOP=0 -f /tmp/131-a.sql > "$rec/131_time_all-a-deployed.txt" 2>&1; echo "131 a: $(grep -E ' verdict' "$rec/131_time_all-a-deployed.txt" | tr -s ' ')"
```
Expected: the same verdict as step 3's part a.

**Browser:** the Live board: the tiles, the rows and the missed callers; leave it open two minutes: the "since" clocks tick, the rows refresh without a page reload (DevTools → Network shows `/api/v1/live/board` every 10 s, none while the tab is in the background). Reports → Data quality: "Refreshed at" with a time at most 5 minutes old. Reports → Flash → Data quality: the same. Configuration → Sources opens at once. Welcome: the cards appear one by one with placeholders first.

**Tomorrow, after a working day** (the "after" on real traffic, against 0a's file)

**Terminal** (from the Chromebook)
```bash
cd ~/cma && gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="cma-web" AND jsonPayload.message="request"' --project=p4a-cma-prod --freshness=1d --limit=100000 --format=json > /tmp/requests-after.json
node tools/perf/request-percentiles.mjs --pages --api < /tmp/requests-after.json | tee records/n06-prod-2026-11-06/percentiles-after.txt
```
Expected: the same table for the day. Put both into one table (route, p75 and p95 before, p75 and p95 after, target) and send it to me: it becomes the decision row that confirms or rejects N06-T's targets, and `records/n06-prod-2026-11-06/README.md` written from your report.

## 6. The Gemini audit (ready to paste; does not block the run)

**Browser:** the Gemini chat of the `p4a-cma-prod` project.

```
You audit the Google Cloud project p4a-cma-prod for the CMA (a Cloud Run service cma-web, a Cloud SQL for PostgreSQL instance cma-prod-pg, Cloud Run jobs started by Cloud Scheduler, alert policies to the email channel "CMA ingest alerts"). On 6 November 2026 the following was added or is proposed; audit each item and answer per item: correct as described, a risk, or a better way.

1. A Cloud Run job cma-refresh-data-quality on the image of cma-web, started by the Cloud Scheduler job cma-refresh-data-quality-minutely every minute, running as cma-web@p4a-cma-prod.iam (an IAM database user, member of the role cma_app), with a connection pool of 1 and one task per execution; it computes a stored data-quality result per tenant when the tenant's result is older than its setting (5 minutes by default). Check: the job exists with that account, image and schedule; the scheduler's service account may invoke it; its executions succeed; the database's connection count stays within the documented budget of 92 of 93 usable connections.
2. A log-based distribution metric cma_web_total_ms on jsonPayload.totalMs of the log lines with jsonPayload.message="request" from the Cloud Run service cma-web, with the label route from jsonPayload.route. Check: the metric exists, its value type is DISTRIBUTION, its filter matches the request lines and nothing else, and its label cardinality (about 60 routes) is acceptable.
3. A proposed alert policy on that metric: the 95th percentile over 10 minutes of the routes "/", "/day", "/hours", "/messages", "/schedule" and "/live/board" above 400 ms for 15 minutes, to the channel "CMA ingest alerts". Check: whether a distribution metric from logs supports a percentile aligner in an alert condition, how the condition must be written (one condition with a route filter, or one per route), and whether the threshold and duration are reasonable for a service with a few hundred requests an hour.
4. Two questions on the Cloud SQL instance cma-prod-pg (PostgreSQL 18, Enterprise edition, db-custom-1-3840, high availability), nothing changed: (a) which database flag enables the pg_stat_statements extension, whether changing it restarts the instance, and what a restart means with high availability; (b) whether Query Insights can be enabled on this instance without a restart, what it costs in this edition, and what it would show that the log-based metric does not.
5. A proposed retention for the table cma.sync_run (about 5,000 rows a day, deleted by a nightly job after 90 days for succeeded runs and a year for failed ones) and a tier change to db-custom-2-7680: give the monthly cost difference of the tier change at europe-west4 prices for a highly available instance and say what else changes (maintenance, failover time).

Rules: the CMA's documentation says nothing in the web app's logs holds personal data and nothing in this prompt is a secret; do not read tables of the database; name every resource by its exact name. You cannot run commands: for every check, give the gcloud command for Martin to run and leave its output empty; mark anything you did not see as unverified.
```

Write Gemini's answer down as `records/n06-prod-2026-11-06/gemini-audit.md` (the commands it gave, your outputs, its verdict per item); I take the follow-ups from it.

## 7. Rollback

**N06a (the database).** Every function keeps its signature and the previous bodies are inside `133` as `pg_temp.old_*` definitions, so there is no data to restore: a rollback is `134_rollback_0008zr.sql`, not written tonight (no rollback was needed for any migration since 0001; the verify proves the same answers). If a rewritten read misbehaves in prod: pause the job (OPERATIONS 5: `cma-refresh-data-quality-minutely`), tell me the read and its `133` line, and I write the rollback script for that function from `db/60`, `70`, `72`, `74`, `76`, `78` or `122` within the hour. The stored data-quality result stays readable meanwhile; a stale "Refreshed at" is the only visible effect of the paused job.

**N06b (the web).** Revert the merge commit on `main` through a pull request (never a push to `main`): the build redeploys `main`'s previous web in 10 minutes; nothing in the database depends on it (the web of N06a's `main` reads the migrated database, Order matters). The job of 4a keeps running and keeps the result fresh for the next deploy.

**Terminal** (the revert, if needed)
```bash
cd ~/cma && git switch main -q && git pull -q && git revert --no-edit <N06b merge sha> && git switch -c revert-n06b && git push -u origin revert-n06b && gh pr create --fill
```
Expected: a pull request with the revert; merge it; the build.
