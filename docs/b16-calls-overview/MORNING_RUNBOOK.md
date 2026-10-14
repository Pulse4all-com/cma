# Runbook, B16: calls overview and calls per agent (0008j)

Labels: **Browser**, **Terminal** (Cloud Shell, in `~/cma` unless stated), **Studio** (the instance named), **File** (a repository path). SQL and shell never share a block. Every step ends with what you should see. Claude Code's local outputs are in `local-records/` (its `README.md` lists them).

**What changes:** Reports → Calls (`/reports/calls`, `reports.view` or `performance.team`): calls, inbound and outbound, answered and connected, conversations, talk time and untagged conversations per day, week, market or line, with the previous period like for like (a period that is still running against the same point in the previous one), and the tag use in the same grouping. Reports → Calls per agent (`/reports/calls-per-agent`, `performance.team` only): the same figures per person, sorted by name, each row opening on that person's conversations per counted tag. Both pages filter by market (K) and line (N). Configuration → Sources, a telephony connection: the threshold of a connected call in plain words, with a link to its setting under Configuration → Exports → Other settings. Addition 0008j (`62`, `63`) holds the setting `telephony.connected_min_seconds` (default 10) and the functions; `02` sets Pulse4all's value 10 for both tenants, to be confirmed by Kira against Aircall's "x sec" (README, Data model: calls overview and calls per agent; Decision log, 14 October 2026).

**Order matters:**
- 0008i (`60`) must have run first; without it `62` stops with `addition 0008i (60_inbound_service.sql) must run before 0008j` and applies nothing. It ran in dev and prod on 14 October 2026.
- 0008j runs in dev and prod **before** the merge: the merge builds and deploys prod's web app, whose Calls and Calls per agent pages and telephony Sources page read the functions and the setting of `62`. Merged first, the two report pages answer an error until `62` runs.
- `02` is rerun after `62` in both databases (it only adds what a tenant does not have yet).
- `61` changes in this pull request: its check A3 listed every `telephony.%` setting, and `62` adds a fourth, so A3 now names its own three. `61` runs in dev only; it never ran in prod.

| Step | What | Elapsed |
|---|---|---|
| 1 | Review the pull request and build it | 15 min |
| 2 | 0008j in dev with its verify, `02` rerun | 10 min |
| 3 | 0008j in prod, `02` rerun, a read-only check | 10 min |
| 4 | Merge, watch the prod build | 10 min |
| 5 | The new image on dev, the API verifier | 15 min |
| 6 | The browser verifiers against a local mock server | 15 min |
| 7 | A hand check in prod | 10 min |

---

## Helpers (define in every new Cloud Shell)

The helpers `cma_db` and `run_migration` of `docs/night-2026-10-13/MORNING_RUNBOOK.md`, section Helpers, unchanged: paste that block first.

Expected: `type cma_db run_migration` prints both functions.

## 1. Review the pull request and build it

**Browser:** GitHub → Pulse4all-com/cma → Pull requests → "B16: calls overview and calls per agent (0008j)". Read the description and the diff.

Expected: no change to `cloudbuild.yaml`, `ingest/` or `records/`; in `db/` the new `62` and `63`, the appended block at the end of `02` and check A3 of `61`; no other script that has run in prod changes.

**Terminal** (the pull request's number from the page)
```bash
cd ~/cma && gh pr checkout <number> && cd web && npm ci --no-audit --no-fund 2>&1 | tail -1 && npm run build 2>&1 | grep -E "reports/calls"; echo "build exit: ${PIPESTATUS[0]}"; cd ~/cma
```
Expected: four route lines (`/api/v1/reports/calls`, `/api/v1/reports/calls-per-agent`, `/api/v1/reports/calls-per-agent/tags`, `/api/v1/reports/calls/tag-use`) and the two pages `/reports/calls` and `/reports/calls-per-agent`, then `build exit: 0`. **Do not merge yet.**

## 2. Addition 0008j in dev

**Terminal** (still on the pull request's branch)
```bash
run_migration dev 62_calls_overview.sql 63_verify_calls_overview.sql 0008j-dev-$(date +%F) 35_verify_telephony.sql 41_verify_lead_metrics.sql 55_verify_uncounted_lines.sql 61_verify_inbound_service.sql
```
Expected: `connected to cma as martin@pulse4all.com`; the last lines of `62` are `INSERT 0 1`, `COMMIT`, `RESET` (no `ERROR`); `63` ends with the verdict row `PASS | 19 PASS, 0 FAIL`; `provoked FAIL lines: 20` and the verdict `PROVOKED, NOT A PASS | 0 PASS, 19 FAIL`; `35_verify_telephony.sql: 2 PASS rows`, `41_verify_lead_metrics.sql: 2 PASS rows`, `55_verify_uncounted_lines.sql: 18 PASS rows`, `61_verify_inbound_service.sql: 21 PASS rows` (its 20 checks and the verdict). A `REFUSED` line means the session is not on dev: check `cma_db dev`.

**Terminal** (`62` again, then the seed)
```bash
rec=records/0008j-dev-$(date +%F); psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/62_calls_overview.sql > "$rec/62-rerun.txt" 2>&1; tail -3 "$rec/62-rerun.txt"; psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/02_seed_pulse4all.sql > "$rec/02-rerun.txt" 2>&1; tail -2 "$rec/02-rerun.txt"
```
Expected: `INSERT 0 0`, `COMMIT`, `RESET`; then `DO` twice (no `ERROR`).

**Studio (cma-dev-pg)** (read only)
```sql
set role cma_owner;
select key, value_type, default_value from cma.setting where key = 'telephony.connected_min_seconds';
select t.slug, s.value from cma.tenant_setting s join cma.tenant t on t.id = s.tenant_id
where s.key = 'telephony.connected_min_seconds' order by 1;
reset role;
```
Expected: one catalog row `telephony.connected_min_seconds | integer | 10`; then two rows, `pulse4all-invest | 10` and `pulse4all-subscriptions | 10`.

## 3. Addition 0008j in prod

**Terminal** (point-in-time recovery on, as before every prod migration)
```bash
gcloud sql instances describe cma-prod-pg --project=p4a-cma-prod --format="value(settings.backupConfiguration.pointInTimeRecoveryEnabled,settings.backupConfiguration.transactionLogRetentionDays)"
```
Expected: `True	7`.

`63`, `55` and `61` refuse prod (they write throwaway tenants and run in dev only), so prod runs the migration, the seed and `35` and `41`, then a read-only check.

**Terminal**
```bash
rec=records/0008j-prod-$(date +%F); mkdir -p "$rec" && cma_db prod && psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/62_calls_overview.sql > "$rec/62.txt" 2>&1; tail -3 "$rec/62.txt"; psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/02_seed_pulse4all.sql > "$rec/02-rerun.txt" 2>&1; tail -2 "$rec/02-rerun.txt"
for f in 35_verify_telephony.sql 41_verify_lead_metrics.sql; do psql "$PGCONN" -v ON_ERROR_STOP=1 -f "db/$f" > "$rec/${f%%_*}-rerun.txt" 2>&1; echo "$f: $(grep -cE '\| PASS' "$rec/${f%%_*}-rerun.txt") PASS rows"; done
```
Expected: `connected to cma as martin@pulse4all.com`; `INSERT 0 1`, `COMMIT`, `RESET`; `DO` twice; `35_verify_telephony.sql: 2 PASS rows`, `41_verify_lead_metrics.sql: 2 PASS rows`.

**Studio (cma-prod-pg)** (read only: the addition, the setting, and the functions on the real calls of the last seven days; counts and times only, no hash, no number, no name)
```sql
set role cma_owner;
select version, applied_at, applied_by from cma.schema_migration where version = '0008j';
select t.slug, s.value as connected_min_seconds from cma.tenant_setting s join cma.tenant t on t.id = s.tenant_id
where s.key = 'telephony.connected_min_seconds' order by 1;
select coalesce(group_key, 'total') as day, calls, inbound, outbound, answered_inbound, connected_outbound, connected_pct,
       conversations, talk_seconds_avg, untagged_conversations
from cma.calls_overview_of((select id from cma.tenant where slug = 'pulse4all-subscriptions'), current_date - 6, current_date, null, null, 'day')
where period = 'current';
select row_kind, count(*) as rows, sum(conversations) as conversations
from cma.calls_per_person_of((select id from cma.tenant where slug = 'pulse4all-subscriptions'), current_date - 6, current_date, null, null)
group by 1 order by 1;
select o.inbound as calls_inbound, i.offered as inbound_offered, o.inbound = i.offered and o.answered_inbound = i.answered as agrees
from cma.calls_overview_of((select id from cma.tenant where slug = 'pulse4all-subscriptions'), current_date - 6, current_date, null, null, 'day') o
cross join cma.inbound_service_of((select id from cma.tenant where slug = 'pulse4all-subscriptions'), current_date - 6, current_date, 'day') i
where o.period = 'current' and o.group_key is null and i.group_key is null;
reset role;
```
Expected:
- one `0008j` row with today's time and your login;
- `pulse4all-invest | 10` and `pulse4all-subscriptions | 10`;
- one row per day with calls, then the `total` row; on every row `calls` equals `inbound` plus `outbound`, and `conversations` equals `answered_inbound` plus `connected_outbound`;
- `person` with one row per linked agent who took or made a call, `not_linked` (only when calls came from Aircall users without a linked account) and `total` with one row; the conversations of `person` and `not_linked` add up to `total`'s, and `total`'s equal the overview's total;
- one row with `agrees` true: the overview's inbound calls are Inbound's offered calls, its answered inbound calls Inbound's answered ones (local run: `19 | 19 | t`). If it reads false, send me the row.

## 4. Merge

**Terminal**
```bash
cd ~/cma && gh pr merge <number> --squash --delete-branch && git switch main -q && git pull -q && git log --oneline -1
gcloud builds list --project=p4a-cma-prod --region=europe-west4 --limit=1 --format="table(status,substitutions.SHORT_SHA,createTime.date('%H:%M'))"
```
Expected: the merge commit; then a build for its short SHA, `QUEUED` or `WORKING`, then `SUCCESS` (RUNBOOK section 3). The build appears 2 to 4 minutes after the merge (3.5 minutes on 14 October 2026), so the list may still show the previous build. Run the list again at 4 minutes before you start the trigger by hand: a manual run next to a late automatic one deploys the same image twice (harmless, but a second deploy for nothing).

**Terminal** (only when the list still has no build for the merge's short SHA 4 minutes after the merge)
```bash
cd ~/cma && gcloud builds triggers run cma-web-main --project=p4a-cma-prod --region=europe-west4 --sha=$(git rev-parse HEAD)
```
Expected: the build's details; the list then shows it for the merge's short SHA (README, Release flow).

## 5. The new image on dev, the API verifier

**Terminal** (RUNBOOK section 4 with the merge's short SHA, then section 5; inside 07:00 to 22:00 Amsterdam)
```bash
cd ~/cma/web && node verify/api.mjs | tee ../records/0008j-dev-$(date +%F)/verify-api.txt | grep -E "^(note|ALL)"; node verify/api.mjs --provoke | tail -1
```
Expected: five `note` lines and `ALL 242 PASS`, then `ALL 242 PROVOKED CHECKS FAILED, as they must`. The verifier has 251 checks, 235 from before B16 and 16 of Calls; dev leaves out 9, one `note` per group:
- `invest-analyst has no access here: the check of a tenant without sources is left out`: 1 check from before B15; dev has no `invest-analyst`.
- `no telephony connection in this tenant: the 5 checks of the missed-reason catalog are left out`: dev's tenant has no telephony connection.
- `invest-analyst has no access here: the check of a tenant without telephony is left out`: 1 check of Inbound.
- `reader has no access here: the check of reports.view without performance.team is left out`: 1 check of Calls; dev has no identity with `reports.view` alone (the mock fixture and the local fixture have `reader`).
- `invest-analyst has no access here: the check of a tenant without telephony is left out` a second time: 1 check of Calls.

That is 228 checks from before B16, as on 14 October 2026 (`records/0008i-dev-2026-10-14`), and 14 of Calls. Dev's tenant has no telephony connection, so the Calls checks there read empty answers; the local run on a database with calls passed all 250 (`local-records/web/verify-api-local-db.txt`).

## 6. The browser verifiers against a local mock server

**Terminal** (a second Cloud Shell tab for the server, README Code paragraph)
```bash
cd ~/cma/web && npm run build >/dev/null && cp -r .next/static .next/standalone/.next/ && (test -d public && cp -r public .next/standalone/ || true) && CMA_AUTH_MODE=mock CMA_DATA_MODE=mock PORT=8080 npm start
```
**Terminal** (the first tab)
```bash
cd ~/cma/web && for v in theme layout hints; do BASE=http://localhost:8080 node verify/$v.mjs | tail -1; BASE=http://localhost:8080 node verify/$v.mjs --provoke | tail -1; done
```
Expected, in order: `theme: PASS (40 pages, …, 11 tables per 7.6 and 3.3, a header hint open on 11 report pages)`, `theme: FAIL (6 problems)`, `layout: PASS (1280, 1920, gate at 1279, …, the Live board for 6 identities, Calls and Calls per agent for 7 identities (the per-agent page for performance.team only, the opened rows and the tag table inside their cards, Enter and Down, the deltas like for like), …)`, `layout: FAIL (24 problems)`, `hints: PASS (241 headers and 59 tiles on 20 pages, …)`, `hints: FAIL (1 problems)`. The layout verifier writes its screenshots to `records/layout/`.

## 7. A hand check in prod

**Browser:** workspace.pulse4all.app → Reports → Calls (after Inbound) → This week, then Group by Week (G).

Expected: four tiles (calls, inbound, outbound, average talk time), each with the change against the previous period in grey, never green or red. This week is still running, so each change reads "vs the same point in the previous period": last week's days up to today's weekday, today's up to the current time (hover the line: its title names the dates and "the last day up to the current time"). Choose a custom week that has ended (C): the changes read "vs the previous period", the whole week before. Below: inbound and outbound per day as stacked columns (inbound Deep Blue, outbound Leaf Green), the Outbound section (connected calls, connected share, talk time on connected calls), and Tags: the share of untagged conversations, the tags of the whole period as horizontal bars (at most 12, then Other) and a table with one row per week and one column per tag, counts with the row's share. No number, no caller, no call id. Hover the info mark of Connected: its hint names 10 seconds.

**Browser:** press K, choose NL; press N, choose a line.

Expected: the date line names the market and the line, every tile, chart and table narrows to them, and the period and grouping stay.

**Browser:** Reports → Calls per agent (supervisors, managers and analysts only).

Expected: one row per agent, sorted by name (no rank), each figure with a small bar under it; the calls of Aircall users without a linked account in one row last, with a link to Data quality; the total row. Click a row, or press Enter on a name: the row opens on that agent's conversations per counted tag, then the untagged ones; Down moves to the next agent.

**Browser:** Configuration → Sources → the Aircall connection.

Expected: in the connection's card, the row Connected call: "An outbound call counts as connected from 10 seconds of talk time, from the answer to the end, without ringing." and the link "Change it on Configuration, Exports". Follow it: Configuration → Exports → Other settings shows the threshold, 10 seconds. Kira confirms 10 against Aircall's "x sec" (README, Decision log, 14 October 2026); a different value is set there, no deploy.

Send me the outputs of steps 2, 3 and 5 (ids, counts and times only); records go in a separate pull request, written from your report.
