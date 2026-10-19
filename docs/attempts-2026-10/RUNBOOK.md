# Runbook, attempts per deal: addition 0008y (`92`, `93`) with the shell polish

Labels:
- **Browser**: a page or a click path.
- **Terminal**: Martin's own Linux terminal (Chromebook Linux or his Linux machine), in `~/cma` unless stated. A step against prod (`p4a-cma-prod`, `cma-prod-pg`) runs from the Chromebook only.
- **Studio**: Cloud SQL Studio, on the instance named. Check the instance in Studio's breadcrumb before every Run.
- **File**: a repository path.

SQL and shell never share a block. Studio shows no notices and one result per statement: a verify's verdict table sits in the results dropdown, before the last results (the `drop function` lines). Every Studio block here reads ids, codes, counts, links and milliseconds only (README, Where a command runs). Every step ends with what you should see. Claude Code's local outputs are in `local-records/`, and its `README.md` lists them. A script can also run from the Terminal through the Auth Proxy (README, Where a command runs), which writes its output into `records/`; the expected results are the same.

**What changes** (README: Data model: attempts per deal; Decision log, 19 October 2026):
- **0008y** (`92`, `93`): Reports → Attempts per deal and Attempts per agent, with the time since the last attempt on open deals (backlog CMA-046, the rest).
  - Two settings: `attempts.max_bucket` (5) and `attempts.since_last_buckets_business_days` (`1,2,5`).
  - `reports.per_person` also takes `attempts`. Pulse4all Subscriptions keeps `email` (Open decisions, Yordi).
  - The definition, the two page reads, a line's stored calls (backlog CMA-020) and the reader view `cma_read.attempts_per_deal`.
  - No table, no index.
- `cma.lead_deals_of` now reads `cma.counted_deals_of`: the same rows (`93` B20 proves it against 0008q's body), a faster market. That is why `41`, `61`, `69`, `73`, `75`, `77`, `81`, `83`, `85`, `89` and `91` run again.
- Web:
  - the two Attempts pages and their routes;
  - the rail as an accordion with one cookie `cma-nav-open`;
  - a top bar that never moves on the hints toggle;
  - header marks that never wrap apart from their label;
  - the line switch-off dialog with the stored-calls count;
  - Calls per agent without the total talk time columns.
- Seeds: the guards of `02` and `03` are safe before `13`. `03` (dev) sets `reports.per_person` to `email,orders,attempts` once `92` ran.

**Order matters:**
- `92` runs in dev and prod **before** the merge. The merge builds and deploys prod's web app, which calls the page reads. Merged first, Reports → Attempts per deal answers an error until `92` runs.
- The web of `main` runs unchanged on `92`: no read it uses changes its name, arguments or columns.
- `92` rewrites `cma.lead_deals_of`, which Speed to lead and lead to order read. Steps 1 and 6 prove those reads give the same rows before and after it: a hash of every row for 1 to 19 October, before and after. In prod they run outside office hours. If the hashes differ, stop and do not merge.
- The data map: `docs/datamap/catalog.json` gains `cma_read.attempts_per_deal`. `verify:datamap` fails on this branch until step 5 refreshes `schema.json` from dev.
- No ingest change, no `cloudbuild.yaml` change, no record written by Claude Code.

| Step | What | Elapsed |
|---|---|---|
| 0 | Review the pull request, build it, check the additions in dev and prod | 10 min |
| 1 | Dev: the lead reads before and after `92`, `92` twice | 5 min |
| 2 | Dev: `93` normal and provoked | 3 min |
| 3 | Dev: the earlier verifies again | 15 min (`91` takes about five minutes on dev's shared core) |
| 4 | Dev: `03` again | 2 min |
| 5 | The data map: snapshot from dev, rebuild, push | 5 min |
| 6 | Prod: point-in-time recovery, the order pipelines marked lead, the lead reads before and after `92`, `92` twice, `41` | 10 min (outside office hours) |
| 7 | Prod: the timings as `cma_app` | 3 min |
| 8 | Prod: the spot check against HubSpot | 15 min |
| 9 | Merge, watch the prod build | 10 min |
| 10 | Prod: the hand check | 10 min |

---

## 0. Review the pull request, build it, check the additions

**Browser:** GitHub → Pulse4all-com/cma → Pull requests → "Attempts per deal (0008y), rail accordion, stable top bar, line switch-off count, seed guard". Read the description and the diff.

Expected:
- in `db/`, the new `92_attempts_per_deal.sql` and `93_verify_attempts_per_deal.sql`, and the guards in `02` and `03`;
- under `web/`, the Attempts pages, routes and components, the shell (`Shell.tsx`, `NavGroup.tsx`, `globals.css`, `lib/nav.ts`), `HintLabel.tsx` across the report tables, `SourceConfig.tsx`, the copy and the verifiers;
- `docs/attempts-2026-10/` (this runbook, `local-records/`), `docs/datamap/catalog.json` and `README.md`;
- nothing under `ingest/`, `cloudbuild.yaml` or `records/`.

**Terminal** (the pull request's number from the page)
```bash
cd ~/cma && gh pr checkout <number> && cd web && npm ci --no-audit --no-fund 2>&1 | tail -1 && npm run build > /tmp/build.txt 2>&1; echo "build exit: $?"; npm run typecheck 2>&1 | tail -1; npm run verify:reports 2>&1 | tail -1; cd ~/cma
```
Expected:
- `found 0 vulnerabilities`, or the known advisories of README, Open decisions;
- `build exit: 0`;
- `✓ Types generated successfully`, or no output from `tsc`;
- `ALL 151 PASS`.

**Do not merge yet.**

**Studio (cma-dev-pg)** and **Studio (cma-prod-pg)** (read only)
```sql
set role cma_owner;
select version, applied_at from cma.schema_migration where version >= '0008x' order by 1;
reset role;
```
Expected on both instances: `0008x` only. Without `0008x`, run `docs/perf-2026-10-19/MORNING_RUNBOOK.md` first. With `0008y` already there, stop and tell me.

## 1. Dev: the lead reads before and after `92`, `92` twice

`92` rewrites `cma.lead_deals_of` on `cma.counted_deals_of`. This step proves, before prod does the same in step 6, that Speed to lead's and lead to order's reads give the same rows afterwards. The block hashes every row of `cma.speed_to_lead_rows` and `cma.lead_to_order_rows` for 1 to 19 October 2026:
- every column, ordered by tenant and deal;
- per tenant where your login has a user;
- as `cma_app` (the usual route: your user, row-level security on).

Run the block before `92`, then `92`, then the block again, in one sitting outside every market's office hours (for Pulse4all after 17:00 or before 09:00 local time, or at the weekend). `speed_to_lead_rows` holds two figures that count up to now: an open deal's waiting business seconds, and whether a deal was called before the next business noon. Both stand still outside office hours, so the block can hash every column of both reads.

**Studio (cma-dev-pg)** (read only, two temporary tables of the session: the lead reads' fingerprint. Ids, counts, hashes and a time only; each read's rows are hashed, never shown)
```sql
set time zone 'UTC';
set role cma_owner;
drop table if exists pg_temp.lead_reads;
create temp table lead_reads (tenant text, read text, rows_read bigint, rows_md5 text, newest_change timestamptz);
grant select, insert on lead_reads to cma_app;
drop table if exists pg_temp.lead_reads_context;
create temp table lead_reads_context as
  select t.slug, t.id as tenant_id, u.id as user_id
  from cma.tenant t join cma.app_user u on u.tenant_id = t.id and u.email = 'martin@pulse4all.com';
grant select on lead_reads_context to cma_app;
set role cma_app;
do $$
declare
  c        record;
  v_newest timestamptz;
begin
  for c in select * from lead_reads_context order by slug loop
    perform set_config('app.tenant_id', c.tenant_id::text, true);
    perform set_config('app.user_id', c.user_id::text, true);
    perform set_config('app.actor_label', 'studio:martin', true);
    -- the newest change these reads can see, so a difference between two runs can be told apart from new data
    select greatest((select max(synced_at) from cma.crm_record), (select max(synced_at) from cma.crm_contact),
                    (select max(synced_at) from cma.crm_call),
                    (select max(greatest(first_seen_at, removed_at, source_changed_at)) from cma.crm_association),
                    (select max(synced_at) from cma.telephony_call), (select max(greatest(linked_at, unlinked_at)) from cma.call_link),
                    (select max(synced_at) from cma.commerce_customer), (select max(synced_at) from cma.commerce_order))
      into v_newest;
    insert into lead_reads
      select c.slug, 'speed_to_lead_rows', count(*),
             md5(coalesce(string_agg(to_jsonb(r)::text, '|' order by r.tenant_id, r.deal_id), '')), v_newest
      from cma.speed_to_lead_rows('2026-10-01', '2026-10-19') r;
    insert into lead_reads
      select c.slug, 'lead_to_order_rows', count(*),
             md5(coalesce(string_agg(to_jsonb(r)::text, '|' order by r.tenant_id, r.deal_id), '')), v_newest
      from cma.lead_to_order_rows('2026-10-01', '2026-10-19') r;
  end loop;
end
$$;
select tenant, read, rows_read, rows_md5, newest_change from lead_reads order by tenant, read;
reset role;
```
Expected: one pair of rows per tenant where your login has a user, at least `pulse4all-subscriptions`, for `lead_to_order_rows` and `speed_to_lead_rows`. Each row has:
- `rows_read`: the lead deals of 1 to 19 October;
- `rows_md5`;
- `newest_change`: the newest change these reads can see in the CRM, telephony and shop mirror.

Copy the rows into your notes. A tenant without a lead deal in the range shows `0` and `d41d8cd98f00b204e9800998ecf8427e`, the md5 of nothing; there the check proves nothing. No rows at all: your login has no user in dev.

**File:** `db/92_attempts_per_deal.sql`: open it and copy all of it.

**Studio (cma-dev-pg):** paste the whole script and Run.

Expected:
- the run ends without an error; Studio's last result is `reset role`;
- an error shows in red with its message: stop and send it to me;
- `addition 0008x (90_report_speed.sql) must run before 0008y` means step 0 found no `0008x`.

**Studio (cma-dev-pg):** the lead reads' block above again, at once.

Expected: the same rows as before `92`, the same `rows_read` and `rows_md5` for each tenant and read, `newest_change` included. Locally, on a database at 0008x with `reports-fixture.sql`, as the dev seed's two admins, the two runs were identical (`local-records/db/lead-reads-before-92.txt` and `-after-92.txt`). A difference while `newest_change` stayed the same: stop and send me both outputs. A difference with a later `newest_change`: new data arrived between the runs; send me both outputs.

**Studio (cma-dev-pg)** (read only: the fingerprint of what `92` defines)
```sql
set role cma_owner;
select (select count(*) from pg_proc p where p.pronamespace in ('cma'::regnamespace, 'cma_read'::regnamespace)) as functions,
       (select md5(string_agg(p.oid::regprocedure::text || pg_get_functiondef(p.oid), '' order by p.oid::regprocedure::text))
          from pg_proc p where p.pronamespace in ('cma'::regnamespace, 'cma_read'::regnamespace) and p.prokind = 'f') as functions_md5,
       (select count(*) from pg_class c where c.relkind = 'v' and c.relnamespace in ('cma'::regnamespace, 'cma_read'::regnamespace)) as views,
       (select string_agg(s.key || '=' || s.default_value, ' ' order by s.key) from cma.setting s where s.key like 'attempts.%') as attempt_settings,
       (select m.version || ' ' || m.applied_at from cma.schema_migration m where m.version = '0008y') as addition;
reset role;
```
Expected: one row.
- `attempt_settings`: `attempts.max_bucket=5 attempts.since_last_buckets_business_days=1,2,5`.
- `addition`: `0008y` with today's time.
- Write down `functions`, `functions_md5` and `views`.

**Studio (cma-dev-pg):** paste `db/92_attempts_per_deal.sql` again and Run. Then the fingerprint block again.

Expected:
- the same row as before: the same `functions`, `functions_md5`, `views` and settings;
- `addition`'s time unchanged.

The second run adds nothing (locally: `local-records/db/fingerprint-after-92.txt` and `-rerun.txt`, identical).

## 2. Dev: `93` normal and provoked

**File:** `db/93_verify_attempts_per_deal.sql`: copy all of it.

**Studio (cma-dev-pg):** paste and Run. Open the results dropdown at the result with 26 rows.

Expected: rows `A1` to `A5` and `B1` to `B20`, each `PASS`, and the last row `verdict | PASS | 25 PASS, 0 FAIL`.
- `REFUSED: not dev` means the instance is not dev's.
- Any `FAIL` row: send me the row (its third column names what was found).

**Studio (cma-dev-pg):** paste `93` again. In the editor, change the line `select set_config('verify.provoke', 'false', false);` to `'true'`, and Run.

Expected: every row `FAIL`, and `verdict | PROVOKED, NOT A PASS | 0 PASS, 25 FAIL`. Nothing stays behind: block B rolls back.

## 3. Dev: the earlier verifies again

`92` rewrote `cma.lead_deals_of` on `cma.counted_deals_of` (the same rows), so every verify that reads it runs again. Each is one step:
- **File:** copy the script.
- **Studio (cma-dev-pg):** paste and Run.
- Expected: the verdict below (locally: `local-records/db/<script>-at-0008y.txt`).

| Script | Expected verdict |
|---|---|
| `db/41_verify_lead_metrics.sql` | one row per tenant, each `PASS` (the last result) |
| `db/61_verify_inbound_service.sql` | `verdict \| PASS \| 20 PASS, 0 FAIL` |
| `db/69_verify_email_activity.sql` | `verdict \| PASS \| 29 PASS, 0 FAIL` |
| `db/73_verify_follow_up.sql` | `verdict \| PASS \| 21 PASS, 0 FAIL` |
| `db/75_verify_forms_reporting.sql` | `verdict \| PASS \| 24 PASS, 0 FAIL` |
| `db/77_verify_audit_hardening.sql` | `verdict \| PASS \| 14 PASS, 0 FAIL` |
| `db/81_verify_follow_up_snapshot.sql` | `verdict \| PASS \| 19 PASS, 0 FAIL` |
| `db/83_verify_email_reports.sql` | `verdict \| PASS \| 26 PASS, 0 FAIL` |
| `db/85_verify_first_orders.sql` | `verdict \| PASS \| 26 PASS, 0 FAIL` |
| `db/89_verify_callbacks_kept.sql` | `verdict \| PASS \| 15 PASS, 0 FAIL` |
| `db/91_verify_report_speed.sql` | `verdict \| PASS \| 13 PASS, 0 FAIL`, after about five minutes |

`91`'s B8 times every report read on dev's shared core. If B8 alone fails, by a little, as on 19 October 2026 (`records/perf-dev-2026-10-19`), that is dev's tier; prod's timings in step 7 decide. Any other `FAIL` row: send me the row.

## 4. Dev: `03` again

**File:** `db/03_seed_dev_test_data.sql`: copy all of it.

**Studio (cma-dev-pg):** paste and Run. Expected: the run ends without an error.

**Studio (cma-dev-pg)** (read only)
```sql
set role cma_owner;
select t.slug, s.value as reports_per_person
from cma.tenant t left join cma.tenant_setting s on s.tenant_id = t.id and s.key = 'reports.per_person'
order by t.slug;
reset role;
```
Expected: `pulse4all-subscriptions | email,orders,attempts`. Attempts per agent then shows in dev's rail for the manager once dev runs the merged image (step 9).

## 5. The data map: snapshot from dev, rebuild, push

**Terminal** (`~/cma`, still on the pull request's branch)
```bash
cd ~/cma && cma_db dev && psql "$PGCONN" -X -qAt -v ON_ERROR_STOP=1 -f tools/datamap/schema.sql > docs/datamap/schema.json && grep -o '"latest_migration" : "[^"]*"' docs/datamap/schema.json
```
Expected: `connected to cma as martin@pulse4all.com`, then `"latest_migration" : "0008y"`.

**Terminal** (`~/cma`)
```bash
node tools/datamap/build.mjs && node tools/datamap/build.mjs --check
```
Expected:
- `datamap: wrote docs/datamap/index.html (81 tables, 111 views)`;
- then `datamap: 81 tables, 111 views, all described; index.html current`.

That is the same tables as `main`'s snapshot (81 tables, 110 views) and one view more, `cma_read.attempts_per_deal`; a local snapshot at 0008y gave exactly these. A problem list instead: send it to me.

**Terminal** (`~/cma`)
```bash
git add docs/datamap && git commit -m "Data map: snapshot after 0008y" && git push
```
Expected: the push names this pull request's branch. `verify:datamap` passes from here on.

## 6. Prod: point-in-time recovery, the order pipelines marked lead, the lead reads before and after `92`, `92` twice, `41`

**Terminal** (from the Chromebook; point-in-time recovery on, as before every prod migration)
```bash
gcloud sql instances describe cma-prod-pg --project=p4a-cma-prod --format="value(settings.backupConfiguration.pointInTimeRecoveryEnabled,settings.backupConfiguration.transactionLogRetentionDays)"
```
Expected: `True	7`. Anything else: stop.

**Studio (cma-prod-pg)** (read only, before `92`: every deal pipeline that is both a lead and an order pipeline, per tenant. Speed to lead (0007d) still counts such a pipeline, while Attempts per deal leaves it out; README Open decisions)
```sql
set role cma_owner;
select t.slug as tenant, c.name as connection, p.connection_id, p.source_pipeline_id as pipeline_id, p.label, p.is_counted
from cma.connection_pipeline p
join cma.tenant t on t.id = p.tenant_id
join cma.integration_connection c on c.tenant_id = p.tenant_id and c.id = p.connection_id
where p.record_type = 'deal' and p.is_lead and p.is_order
order by t.slug, c.name, p.source_pipeline_id;
reset role;
```
Expected: `(0 rows)`.
- Rows come back: copy them into `records/attempts-prod-<date>/order-pipelines-marked-lead.txt` (**File**) and go on.
- Nothing changes here: Speed to lead stays as it is, and Open decisions keeps the point with the count you found.
- Locally, on the dev seed with `reports-fixture.sql`: no rows. A Sales pipeline marked order in a rolled-back transaction came back as one row.

The lead reads before and after `92`, as in step 1, now in prod. Run the block before `92`, then `92`, then the block again, in one sitting outside every market's office hours (for Pulse4all after 17:00 or before 09:00 local time, or at the weekend). `speed_to_lead_rows` holds two figures that count up to now: an open deal's waiting business seconds, and whether a deal was called before the next business noon. Both stand still outside office hours, so the block can hash every column of both reads.

**Studio (cma-prod-pg)** (read only, two temporary tables of the session: the lead reads' fingerprint. Ids, counts, hashes and a time only; each read's rows are hashed, never shown)
```sql
set time zone 'UTC';
set role cma_owner;
drop table if exists pg_temp.lead_reads;
create temp table lead_reads (tenant text, read text, rows_read bigint, rows_md5 text, newest_change timestamptz);
grant select, insert on lead_reads to cma_app;
drop table if exists pg_temp.lead_reads_context;
create temp table lead_reads_context as
  select t.slug, t.id as tenant_id, u.id as user_id
  from cma.tenant t join cma.app_user u on u.tenant_id = t.id and u.email = 'martin@pulse4all.com';
grant select on lead_reads_context to cma_app;
set role cma_app;
do $$
declare
  c        record;
  v_newest timestamptz;
begin
  for c in select * from lead_reads_context order by slug loop
    perform set_config('app.tenant_id', c.tenant_id::text, true);
    perform set_config('app.user_id', c.user_id::text, true);
    perform set_config('app.actor_label', 'studio:martin', true);
    -- the newest change these reads can see, so a difference between two runs can be told apart from new data
    select greatest((select max(synced_at) from cma.crm_record), (select max(synced_at) from cma.crm_contact),
                    (select max(synced_at) from cma.crm_call),
                    (select max(greatest(first_seen_at, removed_at, source_changed_at)) from cma.crm_association),
                    (select max(synced_at) from cma.telephony_call), (select max(greatest(linked_at, unlinked_at)) from cma.call_link),
                    (select max(synced_at) from cma.commerce_customer), (select max(synced_at) from cma.commerce_order))
      into v_newest;
    insert into lead_reads
      select c.slug, 'speed_to_lead_rows', count(*),
             md5(coalesce(string_agg(to_jsonb(r)::text, '|' order by r.tenant_id, r.deal_id), '')), v_newest
      from cma.speed_to_lead_rows('2026-10-01', '2026-10-19') r;
    insert into lead_reads
      select c.slug, 'lead_to_order_rows', count(*),
             md5(coalesce(string_agg(to_jsonb(r)::text, '|' order by r.tenant_id, r.deal_id), '')), v_newest
      from cma.lead_to_order_rows('2026-10-01', '2026-10-19') r;
  end loop;
end
$$;
select tenant, read, rows_read, rows_md5, newest_change from lead_reads order by tenant, read;
reset role;
```
Expected: one pair of rows per tenant where your login has a user, at least `pulse4all-subscriptions`: `lead_to_order_rows` and `speed_to_lead_rows`, each with `rows_read` (Subscriptions' lead deals of 1 to 19 October), `rows_md5` and `newest_change`. Copy the rows into `records/attempts-prod-<date>/lead-reads-before-92.txt` (**File**), as Studio shows them.

**Studio (cma-prod-pg):** paste `db/92_attempts_per_deal.sql` and Run.

Expected: the run ends without an error; the last result is `reset role`. Prod's web keeps working throughout: it reads nothing `92` renames.

**Studio (cma-prod-pg):** the lead reads' block above again, at once.

Expected: the same rows as before `92`, the same `rows_read` and `rows_md5` for each tenant and read, `newest_change` included. Copy them into `records/attempts-prod-<date>/lead-reads-after-92.txt` (**File**).

If any `rows_read` or `rows_md5` differs: **stop, do not merge**, and send me both outputs. `newest_change` tells whether new data arrived between the runs (a later time in the second); without a later time the difference is `92`'s.

**Studio (cma-prod-pg):** step 1's fingerprint block. Then `92` again, then the fingerprint block again.

Expected: the two fingerprint rows identical, with `attempts.max_bucket=5 attempts.since_last_buckets_business_days=1,2,5` and `0008y` with the time of the first run.

**Studio (cma-prod-pg):** paste `db/41_verify_lead_metrics.sql` and Run.

Expected: one row per tenant, each `PASS`. `93` and the other verifies refuse prod (they write throwaway tenants and run in dev only).

**Studio (cma-prod-pg)** (read only)
```sql
set role cma_owner;
select t.slug, s.value as reports_per_person
from cma.tenant t left join cma.tenant_setting s on s.tenant_id = t.id and s.key = 'reports.per_person'
order by t.slug;
reset role;
```
Expected: `pulse4all-subscriptions | email`, unchanged. Prod never runs `03`.

## 7. Prod: the timings as `cma_app`

**Studio (cma-prod-pg)**: one Run of the whole block.
- Context: tenant `pulse4all-subscriptions`, as yourself, row-level security on.
- Each read of October runs three times under `EXPLAIN ANALYZE`; the best execution time is kept.
- Attempts per agent's page read refuses Pulse4all while `reports.per_person` holds `email` only. The block therefore times the read under it, `cma.attempts_per_person_of`.

Output: names and milliseconds only; nothing per person is shown.
```sql
set role cma_owner;
drop table if exists pg_temp.attempts_timing;
create temp table attempts_timing (n integer, read text, best_ms numeric);
grant select, insert on attempts_timing to cma_app;
select set_config('app.tenant_id', (select t.id::text from cma.tenant t where t.slug = 'pulse4all-subscriptions'), false),
       set_config('app.user_id', (select u.id::text from cma.app_user u join cma.tenant t on t.id = u.tenant_id
                                  where t.slug = 'pulse4all-subscriptions' and u.email = 'martin@pulse4all.com'), false),
       set_config('app.actor_label', 'studio:martin', false);
set role cma_app;
do $$
declare
  v_q    text;
  v_n    integer := 0;
  v_best numeric;
  v_ms   numeric;
  v_plan json;
begin
  foreach v_q in array array[
    'attempts_per_deal_page, by day|select cma.attempts_per_deal_page(''2026-10-01'', ''2026-10-31'', ''day'', null, null, ''lead'')',
    'attempts_per_deal_page, by pipeline, every counted deal|select cma.attempts_per_deal_page(''2026-10-01'', ''2026-10-31'', ''pipeline'', null, null, ''counted'')',
    'attempts_per_person_of (the per-agent page''s read)|select cma.attempts_per_person_of(current_setting(''app.tenant_id'')::uuid, date ''2026-10-01'', date ''2026-10-31'', null, null, ''lead'', now())'] loop
    v_n := v_n + 1;
    v_best := null;
    for i in 1 .. 3 loop
      execute 'explain (analyze, format json) ' || split_part(v_q, '|', 2) into v_plan;
      v_ms := round((v_plan -> 0 ->> 'Execution Time')::numeric, 1);
      v_best := least(coalesce(v_best, v_ms), v_ms);
    end loop;
    insert into attempts_timing values (v_n, split_part(v_q, '|', 1), v_best);
  end loop;
end
$$;
select read, best_ms from attempts_timing order by n;
reset role;
```
Expected: after a few seconds, three rows `(read, best_ms)`, each `best_ms` under 500. Locally, at about twice prod's lead volume (`local-records/db/volume-timing.txt`): 286 ms by day, 325 ms by pipeline with every counted deal, 146 ms per agent.

If a read is at 500 ms or above, or the Run stops with an error: **stop, do not merge**, and send me the three rows or the error.
- `CMA06` names a permission your user lacks in this tenant (`reports.view` or `performance.team`).
- An empty `app.user_id` in the first result means the email in the block is not your user's.

## 8. Prod: the spot check against HubSpot

**Studio (cma-prod-pg)** (read only: ten open lead deals of October by id, with their attempts and links; no name, address or phone number)
```sql
set role cma_owner;
select set_config('app.tenant_id', (select t.id::text from cma.tenant t where t.slug = 'pulse4all-subscriptions'), false),
       set_config('app.user_id', (select u.id::text from cma.app_user u join cma.tenant t on t.id = u.tenant_id
                                  where t.slug = 'pulse4all-subscriptions' and u.email = 'martin@pulse4all.com'), false),
       set_config('app.actor_label', 'studio:martin', false);
set role cma_app;
select a.deal_source_id, a.created_at, a.attempts, a.connected, a.first_connected_attempt, a.last_attempt_at,
       a.business_days_since_last, a.record_url
from cma.attempts_per_deal_of(current_setting('app.tenant_id')::uuid, timestamptz '2026-09-30 22:00+00', now(), 'lead', now()) a
where not a.is_closed
order by md5(a.deal_source_id)
limit 10;
reset role;
```
Expected: ten rows, or fewer when October has fewer open lead deals.

**Browser** (HubSpot, Pulse4all Subscriptions): open each `record_url`. On the deal's activity timeline, count the logged **outbound** calls on the deal and on its contacts, from just before the deal was created up to now. "Just before" is the speed-to-lead pre-window, `speed_to_lead.pre_window_minutes`.

Expected:
- the same number as `attempts` for each deal;
- `connected`: the calls whose outcome counts as connected, or whose Aircall call was answered;
- `last_attempt_at`: the newest of those calls.

A difference has a reason; write it down per deal (id, the CMA's attempts, HubSpot's calls, the reason):
- an inbound call (never an attempt);
- a call before the pre-window;
- a call on a contact no longer associated with the deal;
- a deleted call;
- a call logged in the last minutes, which the mirror has not read yet.

Anything else: send me the deal's id and both counts.

## 9. Merge, watch the prod build

**Terminal** (from the Chromebook)
```bash
cd ~/cma && gh pr merge <number> --squash --delete-branch && git switch main -q && git pull -q && git log --oneline -1
gcloud builds list --project=p4a-cma-prod --region=europe-west4 --limit=1 --format="table(status,substitutions.SHORT_SHA,createTime.date('%H:%M'))"
```
Expected: the merge commit, then a build for its short SHA, `QUEUED` or `WORKING`, then `SUCCESS` (RUNBOOK section 3). The build appears 2 to 4 minutes after the merge. No build for the short SHA 4 minutes after the merge:
```bash
gcloud builds triggers run cma-web-main --project=p4a-cma-prod --region=europe-west4 --sha=$(git rev-parse HEAD)
```
Expected: a build for the merge commit, then `SUCCESS`.

## 10. Prod: the hand check

**Browser** (prod, as yourself, after `SUCCESS`)
1. `https://workspace.pulse4all.app/reports/attempts?range=month`. Expected:
   - five tiles: deals, deals attempted, attempts per deal, reached on the first attempt, open never attempted;
   - four cards of bars;
   - the table per day and the deals list with "Showing n of total" and a link per deal;
   - no name, address or phone number;
   - a deal of step 8 shows the same attempts in the list.
2. Press G three times (by week, market, pipeline). Then choose a market (K) and Deals: every counted pipeline (S). Expected: the figures change with the address, and the page never scrolls sideways.
3. `https://workspace.pulse4all.app/reports/attempts-per-agent`. Expected: the not-found page, and no Attempts per agent in the rail. Pulse4all keeps `reports.per_person` at `email` until Yordi agrees (Open decisions).
4. The rail. Open Time, then Reports. Expected: Time closes when Reports opens. Reload: Reports is still the open group. Click Reports: no group is open, and your current page's group keeps its white pill.
5. Press `?` twice. Expected: the keycaps hide and return, and nothing in the top bar moves; Log out keeps its width.
6. Configuration → Sources → the Aircall connection → Lines. Untick a counted line. Expected:
   - the confirmation opens on Cancel;
   - Stop counting is disabled for a moment ("Counting the stored calls of …");
   - then: "Stop counting <line>? This removes its <n> stored calls, the first from <date>. …".

   Click **Cancel**. **Never confirm**: confirming deletes that line's stored calls. Expected: the box stays ticked.

**Terminal** (the request lines of those page loads: route, status, total and database milliseconds; RUNBOOK section 6)
```bash
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="cma-web" AND jsonPayload.message="request" AND jsonPayload.route=~"^/reports/attempts"' \
  --project=p4a-cma-prod --freshness=30m --limit=20 \
  --format='table(timestamp, severity, jsonPayload.route, jsonPayload.status, jsonPayload.totalMs, jsonPayload.dbMs, jsonPayload.tx, jsonPayload.rt)'
```
Expected:
- `/reports/attempts` with `200` and `dbMs` under about 500, severity `INFO`;
- `/reports/attempts-per-agent` with `404`.

Send me the outputs of steps 1 to 4, the rows of steps 7 and 8, and this table. A record of them follows from your report (`records/`, written down from it, as in PRs #120 and #121).
