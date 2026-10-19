# Morning runbook, report speed: addition 0008x (`90`, `91`)

Labels:
- **Browser**: a page or a click path.
- **Terminal**: Martin's own Linux terminal (Chromebook Linux or his Linux machine), in `~/cma` unless stated. A step against prod (`p4a-cma-prod`, `cma-prod-pg`) runs from the Chromebook only.
- **Studio**: Cloud SQL Studio, on the instance named.
- **File**: a repository path.

SQL and shell never share a block. Through the Auth Proxy the terminal runs only `db/` scripts, whose output is schema, check rows, counts and ids. The Studio timings read counts and milliseconds only (README, Where a command runs). Every step ends with what you should see. Claude Code's local outputs are in `local-records/`, and its `README.md` lists them.

**What changes** (README: Data model: report speed; Decision log, 19 October 2026):
- **0008x** (`90`, `91`): `cma.first_orders_of` reads the touches once per first order, and the CRM calls' conversation flag set-based.
- The email reads resolve the contact and the market on plain columns, which the indexes serve under row-level security.
- First orders, Email and Email per agent each read in one pass per page: `cma.first_orders_page()`, `email_report_page()` and `email_per_person_page()`.
- `cma.market`, `market_alias` and `app_user_external_id` are analyzed.
- No index, table, view or column. The same figures.
- Web: the three pages call the page reads. Nothing else changes on screen.

**Order matters:**
- `90` runs in dev and prod **before** the merge. The merge builds and deploys prod's web app, which calls the page reads. Merged first, First orders, Email and Email per agent answer an error until `90` runs.
- The web of `main` runs unchanged on `90`: the earlier reads keep their names, arguments and columns, and become fast too. Step 5 uses that for a before-and-after look at the same figures.
- No data map step: no table, view or column changes, so `docs/datamap/catalog.json` stays and `schema.json` needs no refresh. `verify:datamap` passes on this branch.
- No ingest change, no `cloudbuild.yaml` change, no record written by Claude Code.

| Step | What | Elapsed |
|---|---|---|
| 0 | Review the pull request, build it, check the additions in dev and prod | 10 min |
| 1 | Dev: `90` twice | 2 min |
| 2 | Dev: `91` normal and provoked, `83` and `85` again | 15 min (91 takes about five minutes on dev's shared core) |
| 3 | Prod: `90` twice | 2 min |
| 4 | Prod: the Studio timings as `cma_app` | 3 min |
| 5 | Prod, before the merge: the three pages on `main`'s web, figures written down | 5 min |
| 6 | Merge, watch the prod build, the same pages again, the request lines | 15 min |

---

## Helpers

The terminal is set up as `docs/RUNBOOK.md`, Setup (once per machine), step 8: the helper `cma_db` in `~/.cma_helpers.sh`. This runbook adds none.

**Terminal**
```bash
cd ~/cma && bash -ic 'type -t cma_db'
```
Expected: `function`. Anything else: run `docs/RUNBOOK.md`, Setup, step 8 first.

## 0. Review the pull request, build it, check the additions

**Browser:** GitHub → Pulse4all-com/cma → Pull requests → #173 "Report speed at prod volume …". Read the description and the diff.

Expected:
- in `db/`, the new `90_report_speed.sql` and `91_verify_report_speed.sql`, no other script;
- under `web/`, only `web/src/lib/data/postgres.ts`;
- `docs/perf-2026-10-19/` (the diagnosis, prod's output, this runbook, `local-records/`) and `README.md`;
- nothing under `ingest/`, `cloudbuild.yaml`, `docs/datamap/` or `records/`.

**Terminal**
```bash
cd ~/cma && gh pr checkout 173 && cd web && npm ci --no-audit --no-fund 2>&1 | tail -1 && npm run build > /tmp/build.txt 2>&1; echo "build exit: $?"; npm run typecheck 2>&1 | tail -1; npm run verify:reports 2>&1 | tail -1; cd ~/cma
```
Expected: `found 0 vulnerabilities` (or the known advisories of README, Open decisions), `build exit: 0`, `✓ Types generated successfully` (or no output from `tsc`), `ALL 129 PASS`. **Do not merge yet.**

**Studio (cma-dev-pg)** and **Studio (cma-prod-pg)** (read only)
```sql
set role cma_owner;
select version, applied_at from cma.schema_migration where version >= '0008w' order by 1;
reset role;
```
Expected on both instances: `0008w` only. Without `0008w`: run `docs/night-2026-10-19/MORNING_RUNBOOK.md` first. With `0008x` already there: stop and tell me.

## 1. Dev: `90` twice

**Terminal** (dev, on the pull request's branch): the second run adds nothing.
```bash
cd ~/cma && rec=records/perf-dev-$(date +%F) && mkdir -p "$rec" && cma_db dev
psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/90_report_speed.sql > "$rec/90.txt" 2>&1; echo "90: $(tail -3 "$rec/90.txt" | tr '\n' ' ')"
psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/90_report_speed.sql > "$rec/90-rerun.txt" 2>&1; echo "90 again: $(tail -3 "$rec/90-rerun.txt" | tr '\n' ' ')"
```
Expected:
- `connected to cma as martin@pulse4all.com`;
- `90: INSERT 0 1 COMMIT RESET`;
- `90 again: INSERT 0 0 COMMIT RESET`.

An `ERROR` line or another ending: stop and send me `tail "$rec/90.txt"`. `addition 0008w (88_callbacks_kept.sql) must run before 0008x` means step 0 was skipped.

## 2. Dev: `91` normal and provoked, `83` and `85` again

**Terminal** (dev, the same terminal as step 1, so `$rec` and `$PGCONN` hold). `91` builds a throwaway tenant at prod's counts and rolls it back; it takes about five minutes on dev's shared core (1 min 45 s locally), most of it the old first-orders pass it compares with.
```bash
cd ~/cma && psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/91_verify_report_speed.sql > "$rec/91.txt" 2>&1; echo "91: $(grep -E 'verdict' "$rec/91.txt" | tr -s ' ')"
sed "s/select set_config('verify.provoke', 'false', false);/select set_config('verify.provoke', 'true', false);/" db/91_verify_report_speed.sql > /tmp/provoke.sql
psql "$PGCONN" -v ON_ERROR_STOP=0 -f /tmp/provoke.sql > "$rec/91-provoked.txt" 2>&1; echo "  provoked: $(grep -E 'verdict' "$rec/91-provoked.txt" | tr -s ' ')"
for v in 83_verify_email_reports 85_verify_first_orders; do
  psql "$PGCONN" -v ON_ERROR_STOP=1 -f "db/$v.sql" > "$rec/${v%%_*}.txt" 2>&1; echo "$v: $(grep -E 'verdict' "$rec/${v%%_*}.txt" | tr -s ' ')"
done
grep -E "^ B8|^ B9" "$rec/91.txt" | tr -s ' '
```
Expected:
- `91: verdict | PASS | 13 PASS, 0 FAIL`;
- `provoked: verdict | PROVOKED, NOT A PASS | 0 PASS, 13 FAIL`;
- `83_verify_email_reports: verdict | PASS | 26 PASS, 0 FAIL` and `85_verify_first_orders: verdict | PASS | 26 PASS, 0 FAIL`;
- the B8 line: sixteen reads with their milliseconds, each under 1000 (locally the slowest was `email_report_page NL` at 229 ms);
- the B9 line: the email report, per person and `first_orders_of` against their 0008t and 0008u definitions, each at least five times faster (locally 250 ms against 2.4 s, 159 ms against 2.1 s, 66 ms against 39.4 s).

A `REFUSED` verdict means the session is not on dev: check `cma_db dev`. If B8 alone fails, by a little, that is dev's shared-core tier (README, Dev database server): run the first line again; prod's timings in step 4 decide. Any other `FAIL` row: send me its line (`grep FAIL "$rec/91.txt"`). B2 to B7 name the rows apart, old against new.

## 3. Prod: `90` twice

**Terminal** (prod, from the Chromebook, on the pull request's branch)
```bash
cd ~/cma && rec=records/perf-prod-$(date +%F) && mkdir -p "$rec" && cma_db prod
psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/90_report_speed.sql > "$rec/90.txt" 2>&1; echo "90: $(tail -3 "$rec/90.txt" | tr '\n' ' ')"
psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/90_report_speed.sql > "$rec/90-rerun.txt" 2>&1; echo "90 again: $(tail -3 "$rec/90-rerun.txt" | tr '\n' ' ')"
```
Expected: `connected to cma as martin@pulse4all.com`, `90: INSERT 0 1 COMMIT RESET`, `90 again: INSERT 0 0 COMMIT RESET`. Anything else: stop and send me `tail "$rec/90.txt"`. Prod's web keeps working throughout: it still calls the earlier reads, which `90` replaced in one transaction.

## 4. Prod: the Studio timings as `cma_app`

**Studio (cma-prod-pg)**: one Run of the whole block.
- Context: tenant `pulse4all-subscriptions`, as yourself, row-level security on.
- Each read of October runs three times, every row and column fetched; the best of three is kept.
- One market filter is the first active market of the catalog.

Output: names, milliseconds and row counts only.
```sql
set role cma_owner;
drop table if exists pg_temp.perf_after;
create temp table perf_after (n integer, read text, best_ms numeric, rows_read bigint);
grant select, insert on perf_after to cma_app;
select set_config('app.tenant_id', (select t.id::text from cma.tenant t where t.slug = 'pulse4all-subscriptions'), false),
       set_config('app.user_id', (select u.id::text from cma.app_user u join cma.tenant t on t.id = u.tenant_id
                                  where t.slug = 'pulse4all-subscriptions' and u.email = 'martin@pulse4all.com'), false),
       set_config('app.actor_label', 'studio:martin', false);
set role cma_app;
do $$
declare
  v_market text := (select m.code from cma.market m where m.status = 'active' order by m.sort_order, m.code limit 1);
  v_from   text := '''2026-10-01'', ''2026-10-31''';
  v_q      text;
  v_n      integer := 0;
  v_t0     timestamptz;
  v_ms     numeric;
  v_best   numeric;
  v_rows   bigint;
  r        record;
begin
  foreach v_q in array array[
    'first_orders_page, by day|select * from cma.first_orders_page(%s, ''day'', null, null)',
    'first_orders_page, by level, one market|select * from cma.first_orders_page(%s, ''level'', %L, null)',
    'first_orders_report|select * from cma.first_orders_report(%s, ''day'', null, null)',
    'first_orders_amounts|select * from cma.first_orders_amounts(%s, null, null)',
    'first_orders_list|select * from cma.first_orders_list(%s, null, null)',
    'first_orders_list, the file (500 rows)|select * from cma.first_orders_list(%s, null, null, 500)',
    'first_orders_per_person_of|select * from cma.first_orders_per_person_of(current_setting(''app.tenant_id'')::uuid, %s, null, null)',
    'email_report_page, by day|select * from cma.email_report_page(%s, ''day'', null, null, null)',
    'email_report_page, by week, one market|select * from cma.email_report_page(%s, ''week'', %L, null, null)',
    'email_report|select * from cma.email_report(%s, ''day'', null, null, null)',
    'email_per_person_page|select * from cma.email_per_person_page(%s, null, null, null)',
    'email_waiting|select * from cma.email_waiting(null, null, null)',
    'email_not_responding|select * from cma.email_not_responding(null)'] loop
    v_n := v_n + 1;
    v_best := null;
    for i in 1 .. 3 loop
      v_rows := 0;
      v_t0 := clock_timestamp();
      for r in execute format(split_part(v_q, '|', 2), v_from, v_market) loop
        v_rows := v_rows + 1;
      end loop;
      v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000);
      v_best := least(coalesce(v_best, v_ms), v_ms);
    end loop;
    insert into perf_after values (v_n, split_part(v_q, '|', 1), v_best, v_rows);
  end loop;
end
$$;
select read, best_ms, rows_read from perf_after order by n;
reset role;
```
Expected: after about half a minute, a result of thirteen rows `(read, best_ms, rows_read)`, each `best_ms` under 1000.
- Before `90`, measured the same way as `cma_app`: `first_orders_report` 26.8 s, `first_orders_amounts` 20.1 s, `first_orders_list` 21.1 s, `email_report` 7.0 s.
- The three page reads and the three First orders reads show rows (the first orders of October); `first_orders_list` 100 rows or fewer, the file up to 500.
- `email_waiting` and `email_not_responding` are not changed by `90`. Prod's diagnosis timed them at 52 ms and 110 ms as the owner; they are listed so the page's whole cost shows.

If a read is at 1000 ms or above, or the Run stops with an error:
- send me the thirteen rows, or the error;
- `CMA06` names a permission your user lacks in this tenant (`reports.view` or `performance.team`; Email per agent also needs `reports.per_person` holding `email`);
- an empty `app.user_id` in the first result means the email in the block is not your user's.

Copy the thirteen rows into `records/perf-prod-<date>/timings.txt` (**File**), as Studio shows them.

## 5. Prod, before the merge: the three pages on `main`'s web

`main`'s web now reads the earlier functions, fast since `90`. Write the figures down; step 6 compares them with the merged web.

**Browser** (prod, as yourself)
1. `https://workspace.pulse4all.app/reports/first-orders?range=custom&from=2026-10-01&to=2026-10-31`. Before `90` this page always failed. Expected: it opens in a few seconds, with:
   - the four tiles (first orders, via the call center, by self-service, with the shares);
   - the bars per level, per market with the amounts;
   - the list with the deal links.

   Write down the first orders, call center and self-service totals, and the list's "Showing n of total".
2. `https://workspace.pulse4all.app/reports/email?range=custom&from=2026-10-01&to=2026-10-31`. Expected: the tiles, the tables per inbox, mailbox, category and market. Write down received, sent and the conversations opened and closed. Then choose a market in the filter. Expected: the figures for that market, and the market list still offering every market.
3. `https://workspace.pulse4all.app/reports/email-per-agent?range=custom&from=2026-10-01&to=2026-10-31`. Expected: per person by name and the total row. Write down the total's sent and replies.

## 6. Merge, watch the prod build, the same pages again

**Terminal** (from the Chromebook)
```bash
cd ~/cma && gh pr merge 173 --squash --delete-branch && git switch main -q && git pull -q && git log --oneline -1
gcloud builds list --project=p4a-cma-prod --region=europe-west4 --limit=1 --format="table(status,substitutions.SHORT_SHA,createTime.date('%H:%M'))"
```
Expected: the merge commit, then a build for its short SHA, `QUEUED` or `WORKING`, then `SUCCESS` (RUNBOOK section 3). The build appears 2 to 4 minutes after the merge. No build for the short SHA 4 minutes after the merge: `gcloud builds triggers run cma-web-main --project=p4a-cma-prod --region=europe-west4 --sha=$(git rev-parse HEAD)`.

**Browser** (prod, as yourself, after `SUCCESS`): the three URLs of step 5 again. Expected:
- each page opens in about a second;
- the same figures as in step 5;
- the market filter on Email still offers every market.

Orders or emails that arrived in between can move a figure by that much; anything else that differs, send me.

**Terminal** (the request lines of those page loads: route, status, total and database milliseconds, transactions and statements; RUNBOOK section 6)
```bash
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="cma-web" AND jsonPayload.message="request" AND jsonPayload.route=~"^/reports/(first-orders|email)"' \
  --project=p4a-cma-prod --freshness=30m --limit=20 \
  --format='table(timestamp, severity, jsonPayload.route, jsonPayload.status, jsonPayload.totalMs, jsonPayload.dbMs, jsonPayload.tx, jsonPayload.rt)'
```
Expected:
- the loads of steps 5 and 6, each `200`;
- after the merge, `/reports/first-orders` and `/reports/email` with `dbMs` around a second or less, and severity `INFO` below 800 ms;
- step 5's loads read slower, because `main`'s web read First orders in three passes and a filtered Email page twice.

Send me the step 2 lines, the step 4 rows and the step 6 table. A record of them follows from your report (`records/`, written down from it, as in PRs #120 and #121).
