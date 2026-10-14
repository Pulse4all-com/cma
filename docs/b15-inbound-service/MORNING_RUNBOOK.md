# Runbook, B15: inbound service level and missed calls not called back (0008i)

Labels: **Browser**, **Terminal** (Cloud Shell, in `~/cma` unless stated), **Studio** (the instance named), **File** (a repository path). SQL and shell never share a block. Every step ends with what you should see. Claude Code's local outputs are in `local-records/` (its `README.md` lists them).

**What changes:** Reports → Inbound (`/reports/inbound`, `reports.view` or `performance.team`): the service level, time to answer and unanswered calls per missed reason, per day, market, line or hour. The Live board opens with today's inbound tiles and the missed calls not called back (`monitoring.live`). Configuration → Sources, a telephony connection: the missed-call reasons with their label and two switches. Addition 0008i (`60`, `61`) holds the catalog, three settings and the functions; `02` adds Pulse4all's reasons and settings (README, Data model: inbound service and callbacks; Decision log, 14 October 2026).

**Order matters:**
- 0008f (`54`) must have run first; without it `60` stops with `addition 0008f (54_uncounted_lines.sql) must run before 0008i` and applies nothing. It ran in dev and prod on 13 October 2026.
- 0008i runs in dev and prod **before** the merge: the merge builds and deploys prod's web app, whose Inbound page, Live board and telephony Sources page call the functions of `60`. Merged first, those three pages answer an error until `60` runs.
- `02` is rerun after `60` in both databases (it only adds what a tenant does not have yet).

| Step | What | Elapsed |
|---|---|---|
| 1 | Review the pull request and build it | 15 min |
| 2 | 0008i in dev with its verify, `02` rerun | 10 min |
| 3 | 0008i in prod, `02` rerun, a read-only check | 10 min |
| 4 | Merge, watch the prod build | 10 min |
| 5 | The new image on dev, the API verifier | 15 min |
| 6 | The browser verifiers against a local mock server | 15 min |
| 7 | A hand check in prod | 10 min |

---

## Helpers (define in every new Cloud Shell)

The helpers `cma_db` and `run_migration` of `docs/night-2026-10-13/MORNING_RUNBOOK.md`, section Helpers, unchanged: paste that block first.

Expected: `type cma_db run_migration` prints both functions.

## 1. Review the pull request and build it

**Browser:** GitHub → Pulse4all-com/cma → Pull requests → "B15: inbound service level and missed calls not called back (0008i)". Read the description and the diff.

Expected: no change to `cloudbuild.yaml`, `ingest/` or `records/`; in `db/` the new `60` and `61` and the appended block at the end of `02`; no other script that has run in prod changes.

**Terminal** (the pull request's number from the page)
```bash
cd ~/cma && gh pr checkout <number> && cd web && npm ci --no-audit --no-fund 2>&1 | tail -1 && npm run build 2>&1 | grep -E "reports/inbound|telephony/inbound-now|missed-reasons"; echo "build exit: ${PIPESTATUS[0]}"; cd ~/cma
```
Expected: three route lines (`/api/v1/configuration/sources/[id]/missed-reasons`, `/api/v1/reports/inbound`, `/api/v1/telephony/inbound-now`) and `/reports/inbound`, then `build exit: 0`. **Do not merge yet.**

## 2. Addition 0008i in dev

**Terminal** (still on the pull request's branch)
```bash
run_migration dev 60_inbound_service.sql 61_verify_inbound_service.sql 0008i-dev-$(date +%F) 35_verify_telephony.sql 41_verify_lead_metrics.sql 53_verify_sources_configuration.sql 55_verify_uncounted_lines.sql
```
Expected: `connected to cma as martin@pulse4all.com`; the last lines of `60` are `INSERT 0 1`, `COMMIT`, `RESET` (no `ERROR`); `61` ends with the verdict row `PASS | 19 PASS, 0 FAIL`; `provoked FAIL lines: 20` and the verdict `PROVOKED, NOT A PASS | 0 PASS, 19 FAIL`; `35_verify_telephony.sql: 2 PASS rows`, `41_verify_lead_metrics.sql: 2 PASS rows`, `53_verify_sources_configuration.sql: 17 PASS rows`, `55_verify_uncounted_lines.sql: 18 PASS rows`. A `REFUSED` line means the session is not on dev: check `cma_db dev`.

**Terminal** (`60` again, then the seed)
```bash
rec=records/0008i-dev-$(date +%F); psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/60_inbound_service.sql > "$rec/60-rerun.txt" 2>&1; tail -3 "$rec/60-rerun.txt"; psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/02_seed_pulse4all.sql > "$rec/02-rerun.txt" 2>&1; tail -2 "$rec/02-rerun.txt"
```
Expected: `INSERT 0 0`, `COMMIT`, `RESET`; then `DO` twice (no `ERROR`).

**Studio (cma-dev-pg)** (read only)
```sql
set role cma_owner;
select t.slug,
       (select count(*) from cma.telephony_missed_reason r where r.tenant_id = t.id) as reasons,
       (select count(*) from cma.telephony_missed_reason r where r.tenant_id = t.id and not r.counts_in_service_level) as out_of_service_level,
       (select string_agg(s.key || '=' || s.value, ', ' order by s.key) from cma.tenant_setting s where s.tenant_id = t.id and s.key like 'telephony.%') as settings
from cma.tenant t where t.slug like 'pulse4all-%' order by 1;
reset role;
```
Expected: two rows, `pulse4all-invest` and `pulse4all-subscriptions`, each `6 | 2 | telephony.callback_lookback_days=3, telephony.service_level_seconds=20, telephony.waiting_max_minutes=30`.

## 3. Addition 0008i in prod

**Terminal** (point-in-time recovery on, as before every prod migration)
```bash
gcloud sql instances describe cma-prod-pg --project=p4a-cma-prod --format="value(settings.backupConfiguration.pointInTimeRecoveryEnabled,settings.backupConfiguration.transactionLogRetentionDays)"
```
Expected: `True	7`.

`61`, `53` and `55` refuse prod (they write throwaway tenants and run in dev only), so prod runs the migration, the seed and `35` and `41`, then a read-only check.

**Terminal**
```bash
rec=records/0008i-prod-$(date +%F); mkdir -p "$rec" && cma_db prod && psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/60_inbound_service.sql > "$rec/60.txt" 2>&1; tail -3 "$rec/60.txt"; psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/02_seed_pulse4all.sql > "$rec/02-rerun.txt" 2>&1; tail -2 "$rec/02-rerun.txt"
for f in 35_verify_telephony.sql 41_verify_lead_metrics.sql; do psql "$PGCONN" -v ON_ERROR_STOP=1 -f "db/$f" > "$rec/${f%%_*}-rerun.txt" 2>&1; echo "$f: $(grep -cE '\| PASS' "$rec/${f%%_*}-rerun.txt") PASS rows"; done
```
Expected: `connected to cma as martin@pulse4all.com`; `INSERT 0 1`, `COMMIT`, `RESET`; `DO` twice; `35_verify_telephony.sql: 2 PASS rows`, `41_verify_lead_metrics.sql: 2 PASS rows`.

**Studio (cma-prod-pg)** (read only: the addition, the seed, and the functions on the real calls of the last seven days; counts only, no hash)
```sql
set role cma_owner;
select version, applied_at, applied_by from cma.schema_migration where version = '0008i';
select t.slug, count(*) as reasons from cma.telephony_missed_reason r join cma.tenant t on t.id = r.tenant_id group by 1 order by 1;
select group_key, offered, answered, unanswered, service_level_pct, avg_answer_seconds, unanswered_by_reason
from cma.inbound_service_of((select id from cma.tenant where slug = 'pulse4all-subscriptions'), current_date - 6, current_date, 'day');
select count(*) as callers_not_called_back from cma.missed_callbacks_of((select id from cma.tenant where slug = 'pulse4all-subscriptions'));
reset role;
```
Expected: one `0008i` row with today's time and your login; `pulse4all-invest | 6` and `pulse4all-subscriptions | 6`; one row per day with calls plus the total row (an empty group key), offered equal to answered plus unanswered on past days; a count. The real codes Aircall gives show in `unanswered_by_reason`; one without a catalog row counts with the defaults (send it to me if it should be labelled).

## 4. Merge

**Terminal**
```bash
cd ~/cma && gh pr merge <number> --squash --delete-branch && git switch main -q && git pull -q && git log --oneline -1
gcloud builds list --project=p4a-cma-prod --region=europe-west4 --limit=1 --format="table(status,substitutions.SHORT_SHA,createTime.date('%H:%M'))"
```
Expected: the merge commit; a build for its short SHA, `QUEUED` or `WORKING`, then `SUCCESS` after 2 to 4 minutes (RUNBOOK section 3).

## 5. The new image on dev, the API verifier

**Terminal** (RUNBOOK section 4 with the merge's short SHA, then section 5; inside 07:00 to 22:00 Amsterdam)
```bash
cd ~/cma/web && node verify/api.mjs | tee ../records/0008i-dev-$(date +%F)/verify-api.txt | tail -2; node verify/api.mjs --provoke | tail -1
```
Expected: `ALL 234 PASS` (219 before and 15 of Inbound; the check of a tenant without telephony needs `invest-analyst`, which dev does not have, and says `note`), then `ALL 234 PROVOKED CHECKS FAILED, as they must`. One missed-reason label of dev's Aircall connection is written and put back; with no telephony connection in dev's tenant the five catalog checks say `note` and the counts are 229.

## 6. The browser verifiers against a local mock server

**Terminal** (a second Cloud Shell tab for the server, README Code paragraph)
```bash
cd ~/cma/web && npm run build >/dev/null && cp -r .next/static .next/standalone/.next/ && (test -d public && cp -r public .next/standalone/ || true) && CMA_AUTH_MODE=mock CMA_DATA_MODE=mock PORT=8080 npm start
```
**Terminal** (the first tab)
```bash
cd ~/cma/web && for v in theme layout hints; do BASE=http://localhost:8080 node verify/$v.mjs | tail -1; BASE=http://localhost:8080 node verify/$v.mjs --provoke | tail -1; done
```
Expected, in order: `theme: PASS (36 pages, …)`, `theme: FAIL (5 problems)`, `layout: PASS (1280, 1920, gate at 1279, …, the Live board for 6 identities, …)`, `layout: FAIL (15 problems)`, `hints: PASS (157 headers and 27 tiles on 14 pages, …)`, `hints: FAIL (1 problems)`. The layout verifier writes its screenshots to `records/layout/`.

## 7. A hand check in prod

**Browser:** workspace.pulse4all.app → Reports → Inbound (key after Intake) → This week, then Group by Hour (G).

Expected: one row per day with offered, answered, unanswered, service level, average and 80th percentile, one column per missed reason with the seed's labels, a total row; by hour the evening hours show the `Outside opening hours` column. Hover an info mark: the service level's hint names 20 seconds.

**Browser:** Live → Live board.

Expected: the Inbound today tiles, then Missed, not called back with one row per caller (line, market, reason, missed at, waiting, times missed), no link icon yet (the call link template is not set: README, Open decisions), and below it the count of anonymous missed calls when there are any; the board refreshes every 10 seconds.

**Browser:** Configuration → Sources → the Aircall connection.

Expected: a Missed-call reasons section with the six seeded codes and any other code Aircall gave (marked Defaults), each with its calls and last seen. The call link template (`record_url_call`) is filled in later, once its address is verified in Aircall's dashboard.

Send me the outputs of steps 2, 3 and 5 (ids, counts and times only); records go in a separate pull request, written from your report.
