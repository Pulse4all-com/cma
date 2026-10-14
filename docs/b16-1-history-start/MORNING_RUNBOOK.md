# Runbook, B16.1: no change against a period before the telephony history (0008k)

Labels: **Browser**, **Terminal** (Cloud Shell, in `~/cma` unless stated), **Studio** (the instance named), **File** (a repository path). SQL and shell never share a block. Every step ends with what you should see. Claude Code's local outputs are in `local-records/` (its `README.md` lists them).

**What changes:** Reports → Calls (`/reports/calls`). Prod's calls start on 1 October 2026, so This month (1 to 14 October) compared with 31 August to 13 September and its tiles read "↑ 358,900 %" and "↑ from none". A tenant's telephony history now starts at the business date of its earliest stored call (as `cma.calls_of` defines a call: not deleted, with a start, on a counted line; any connection; tenant-wide, whatever the market and line filters; in the call's line zone). When the previous span the deltas compare with starts before that date, every tile says "No history to compare yet" in grey, the date the history starts in its title on hover, with no percentage and no "from none". A span that starts on that date or later shows the change as before; a tenant without calls too. Addition 0008k (`64`, `65`) adds `cma.telephony_history_start()` and its read of an explicit tenant; 0008j's functions are unchanged (README, Data model: telephony history start; Decision log, 14 October 2026).

**Order matters:**
- 0008j (`62`) must have run first; without it `64` stops with `addition 0008j (62_calls_overview.sql) must run before 0008k` and applies nothing. It runs in prod (B16, live at `70354b1`).
- 0008k runs in dev and prod **before** the merge: the merge builds and deploys prod's web app, whose Calls page reads `cma.telephony_history_start()`. Merged first, Reports → Calls answers an error until `64` runs.
- No seed rerun: `64` adds no setting and no seed data.
- No script that has run in prod changes in this pull request; `63` is unchanged.

| Step | What | Elapsed |
|---|---|---|
| 1 | Review the pull request and build it | 10 min |
| 2 | 0008k in dev with its verify | 10 min |
| 3 | 0008k in prod, a read-only check | 10 min |
| 4 | Merge, watch the prod build | 10 min |
| 5 | The new image on dev, the API verifier | 15 min |
| 6 | The browser verifiers against a local mock server | 15 min |
| 7 | A hand check in prod | 5 min |

---

## Helpers (define in every new Cloud Shell)

The helpers `cma_db` and `run_migration` of `docs/night-2026-10-13/MORNING_RUNBOOK.md`, section Helpers, unchanged: paste that block first.

Expected: `type cma_db run_migration` prints both functions.

## 1. Review the pull request and build it

**Browser:** GitHub → Pulse4all-com/cma → Pull requests → "B16.1: no change against a period before the telephony history (0008k)". Read the description and the diff.

Expected: no change to `cloudbuild.yaml`, `ingest/` or `records/`; in `db/` only the new `64` and `65`; no script that has run in prod changes.

**Terminal** (the pull request's number from the page)
```bash
cd ~/cma && gh pr checkout <number> && cd web && npm ci --no-audit --no-fund 2>&1 | tail -1 && npm run build 2>&1 | grep -E "reports/calls"; echo "build exit: ${PIPESTATUS[0]}"; cd ~/cma
```
Expected: the four Calls routes (`/api/v1/reports/calls`, `/api/v1/reports/calls-per-agent`, `/api/v1/reports/calls-per-agent/tags`, `/api/v1/reports/calls/tag-use`) and the two pages `/reports/calls` and `/reports/calls-per-agent`, then `build exit: 0`. **Do not merge yet.**

## 2. Addition 0008k in dev

**Terminal** (still on the pull request's branch)
```bash
run_migration dev 64_calls_history_start.sql 65_verify_calls_history_start.sql 0008k-dev-$(date +%F) 63_verify_calls_overview.sql 35_verify_telephony.sql 41_verify_lead_metrics.sql 55_verify_uncounted_lines.sql 61_verify_inbound_service.sql
```
Expected: `connected to cma as martin@pulse4all.com`; the last lines of `64` are `INSERT 0 1`, `COMMIT`, `RESET` (no `ERROR`); `65` ends with the verdict row `PASS | 11 PASS, 0 FAIL`; `provoked FAIL lines: 12` and the verdict `PROVOKED, NOT A PASS | 0 PASS, 11 FAIL`; `63_verify_calls_overview.sql: 20 PASS rows` (its 19 checks and the verdict), `35_verify_telephony.sql: 2 PASS rows`, `41_verify_lead_metrics.sql: 2 PASS rows`, `55_verify_uncounted_lines.sql: 18 PASS rows`, `61_verify_inbound_service.sql: 21 PASS rows`. A `REFUSED` line means the session is not on dev: check `cma_db dev`.

**Terminal** (`64` again)
```bash
rec=records/0008k-dev-$(date +%F); psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/64_calls_history_start.sql > "$rec/64-rerun.txt" 2>&1; tail -3 "$rec/64-rerun.txt"
```
Expected: `INSERT 0 0`, `COMMIT`, `RESET`.

**Studio (cma-dev-pg)** (read only)
```sql
set role cma_owner;
select version, applied_by from cma.schema_migration where version = '0008k';
select t.slug, cma.telephony_history_start_of(t.id) as history_start from cma.tenant t order by 1;
reset role;
```
Expected: one `0008k` row with your login; then one row per tenant, `history_start` empty for both Pulse4all tenants (dev holds no calls). A date there means dev holds calls: then step 5's three history checks take the branch with a history start, and the count is the same.

## 3. Addition 0008k in prod

**Terminal** (point-in-time recovery on, as before every prod migration)
```bash
gcloud sql instances describe cma-prod-pg --project=p4a-cma-prod --format="value(settings.backupConfiguration.pointInTimeRecoveryEnabled,settings.backupConfiguration.transactionLogRetentionDays)"
```
Expected: `True	7`.

`65`, `63`, `55` and `61` refuse prod (they write throwaway tenants and run in dev only), so prod runs the migration twice and `35` and `41`, then a read-only check.

**Terminal**
```bash
rec=records/0008k-prod-$(date +%F); mkdir -p "$rec" && cma_db prod && psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/64_calls_history_start.sql > "$rec/64.txt" 2>&1; tail -3 "$rec/64.txt"; psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/64_calls_history_start.sql > "$rec/64-rerun.txt" 2>&1; tail -3 "$rec/64-rerun.txt"
for f in 35_verify_telephony.sql 41_verify_lead_metrics.sql; do psql "$PGCONN" -v ON_ERROR_STOP=1 -f "db/$f" > "$rec/${f%%_*}-rerun.txt" 2>&1; echo "$f: $(grep -cE '\| PASS' "$rec/${f%%_*}-rerun.txt") PASS rows"; done
```
Expected: `connected to cma as martin@pulse4all.com`; `INSERT 0 1`, `COMMIT`, `RESET`; then `INSERT 0 0`, `COMMIT`, `RESET`; `35_verify_telephony.sql: 2 PASS rows`, `41_verify_lead_metrics.sql: 2 PASS rows`.

**Studio (cma-prod-pg)** (read only: the addition, the history start per tenant, and the first day's calls as the overview counts them; dates and counts only, no hash, no number, no name)
```sql
set role cma_owner;
select version, applied_at, applied_by from cma.schema_migration where version = '0008k';
select t.slug, cma.telephony_history_start_of(t.id) as history_start from cma.tenant t order by 1;
select coalesce(group_key, 'total') as day, calls
from cma.calls_overview_of((select id from cma.tenant where slug = 'pulse4all-subscriptions'),
                           cma.telephony_history_start_of((select id from cma.tenant where slug = 'pulse4all-subscriptions')) - 3,
                           cma.telephony_history_start_of((select id from cma.tenant where slug = 'pulse4all-subscriptions')), null, null, 'day')
where period = 'current';
reset role;
```
Expected:
- one `0008k` row with today's time and your login;
- `pulse4all-subscriptions | 2026-10-01` (the first calls, as the brief reports); `pulse4all-invest` empty unless Invest has a telephony connection of its own with calls;
- the three days before the history start hold no row, its own date one row with its calls, then the `total` row with the same number. If the date or the rows differ, send me the rows.

## 4. Merge

**Terminal**
```bash
cd ~/cma && gh pr merge <number> --squash --delete-branch && git switch main -q && git pull -q && git log --oneline -1
gcloud builds list --project=p4a-cma-prod --region=europe-west4 --limit=1 --format="table(status,substitutions.SHORT_SHA,createTime.date('%H:%M'))"
```
Expected: the merge commit; then a build for its short SHA, `QUEUED` or `WORKING`, then `SUCCESS` (RUNBOOK section 3). The build appears 2 to 4 minutes after the merge, so the list may still show the previous build. Run the list again at 4 minutes before you start the trigger by hand.

**Terminal** (only when the list still has no build for the merge's short SHA 4 minutes after the merge)
```bash
cd ~/cma && gcloud builds triggers run cma-web-main --project=p4a-cma-prod --region=europe-west4 --sha=$(git rev-parse HEAD)
```
Expected: the build's details; the list then shows it for the merge's short SHA (README, Release flow).

## 5. The new image on dev, the API verifier

**Terminal** (RUNBOOK section 4 with the merge's short SHA, then section 5; inside 07:00 to 22:00 Amsterdam)
```bash
cd ~/cma/web && node verify/api.mjs | tee ../records/0008k-dev-$(date +%F)/verify-api.txt | grep -E "^(note|ALL)"; node verify/api.mjs --provoke | tail -1
```
Expected: five `note` lines, the same as after B16, and `ALL 245 PASS`, then `ALL 245 PROVOKED CHECKS FAILED, as they must`. That is B16's 242 in dev plus 3 on the telephony history start, which run in dev too: dev's tenant has no call, so they check that the history start is none for every range, grouping and filter, that no call is counted, and that every previous span compares as before. If B16's run in dev gave another count than 242, expect that count plus 3. The local run on a database with calls, whose earliest call is 40 days back, passed all 253 (`local-records/web/verify-api-local-db.txt`), and the three checks on a local database without calls, as dev, passed (`local-records/web/verify-api-calls-no-history.txt`).

## 6. The browser verifiers against a local mock server

**Terminal** (a second Cloud Shell tab for the server, README Code paragraph)
```bash
cd ~/cma/web && npm run build >/dev/null && cp -r .next/static .next/standalone/.next/ && (test -d public && cp -r public .next/standalone/ || true) && CMA_AUTH_MODE=mock CMA_DATA_MODE=mock PORT=8080 npm start
```
**Terminal** (the first tab; inside 07:00 to 22:00 Amsterdam, the mock's workday window)
```bash
cd ~/cma/web && for v in theme layout hints; do BASE=http://localhost:8080 node verify/$v.mjs | tail -1; BASE=http://localhost:8080 node verify/$v.mjs --provoke | tail -1; done
```
Expected, in order: `theme: PASS (40 pages, …, 11 tables per 7.6 and 3.3, a header hint open on 11 report pages)`, `theme: FAIL (6 problems)`, `layout: PASS (…, Calls and Calls per agent for 7 identities (…, the deltas like for like and none before the telephony history), …)`, `layout: FAIL (25 problems)` (B16's 24 and the third delta case), `hints: PASS (241 headers and 59 tiles on 20 pages, …)`, `hints: FAIL (1 problems)`. The layout verifier writes its screenshots to `records/layout/`.

## 7. A hand check in prod

**Browser:** workspace.pulse4all.app → Reports → Calls → This month (M).

Expected: the four tiles (calls, inbound, outbound, average talk time) each say "No history to compare yet" in grey under the figure, no arrow, no percentage, no "from none". Hover that line: its title reads "The telephony history starts on Thu, 1 October 2026". Press K and choose a market: still "No history to compare yet" (the history start is the tenant's, whatever the filter).

**Browser:** This week (W).

Expected: each tile shows its change as before, like for like: an arrow, a percentage and "vs the same point in the previous period" (5 to 7 October on 14 October, the last day up to the current time, in the line's title). The previous week starts after 1 October, so it compares.

Send me the outputs of steps 2, 3 and 5 (ids, counts, dates and times only); records go in a separate pull request, written from your report.
