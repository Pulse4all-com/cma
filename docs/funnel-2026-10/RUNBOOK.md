# Runbook, funnel, lost reasons and cancellations: additions 0008za (`96`, `97`) and 0008zb (`98`, `99`)

Labels:
- **Browser**: a page or a click path.
- **Terminal**: Martin's own Linux terminal (Chromebook Linux or his Linux machine), in `~/cma` unless stated. A step against prod (`p4a-cma-prod`, `cma-prod-pg`) runs from the Chromebook only, and so does a build, which runs in `p4a-cma-prod`.
- **Studio**: Cloud SQL Studio, on the instance named. Check the instance in Studio's breadcrumb before every Run.
- **File**: a repository path.

SQL and shell never share a block. Studio shows no notices and one result per statement: a verify's verdict table sits in the results dropdown, before the last results (the `drop function` lines). Every Studio block here reads ids, codes, counts, labels of configuration and milliseconds only, never a customer row (README, Where a command runs). Every step ends with what you should see. Claude Code's local outputs are in `local-records/`, and its `README.md` lists them.

**The rules for every block below** (as in `docs/RUNBOOK.md`, section 7):
- **Whose user.** A block that acts as a person names the email, with the reason. Dev blocks use the dev seed's admin, `admin@example.com`; prod blocks use `martin@pulse4all.com`.
- **Provoked runs.** Paste the verify script, press Ctrl+F, search `'verify.provoke', 'false'` and change only that `false` to `true`. Run. Result 1 in the dropdown must read `true`; if it reads `false`, the edit did not take.
- **Long verifies run from the Terminal.** Studio stops a statement at 300 seconds. `99` (its volume part) and `91` go through the Auth Proxy:
  ```bash
  cma_db dev && time psql "$PGCONN" -X -v ON_ERROR_STOP=1 -f db/<file> > /tmp/<n>.txt 2>&1; tail -40 /tmp/<n>.txt
  ```
  `<file>` is the script, `<n>` its number.

**What changes** (README: Data model: stage times; Data model: reasons, kinds and the funnel; Decision log, 20 October 2026):
- **0008za** (`96`, `97`): when a deal entered and left each stage, from HubSpot's own calculated stage properties (`hs_v2_date_entered_<stage id>`, `hs_v2_date_exited_<stage id>`), mirrored in `cma.crm_record_stage`; `connection_stage.read_times` per stage (on for a counted pipeline's stages unless you switch one); the reader view `cma_read.crm_record_stage`.
- **0008zb** (`98`, `99`): the reason field for deals and tickets, read from a dropdown (enumeration) property only, with the options' catalog `cma.connection_reason` and your data-quality flag; record kinds `cma.record_kind` with rules per connection `cma.connection_record_kind`; the settings `reports.cancellation_kind` and `deals` in `reports.per_person`; the reads of Reports → Funnel (the funnel, lost reasons, deals per person) and Reports → Cancellations; the reader views `cma_read.deal_funnel_rows` and `cma_read.cancellation_rows` (and three table views); `reason` on `cma_read.crm_record_detail`.
- Ingest: the HubSpot adapter reads the stage times with the deal (the webhook within its 3-second budget, else the next sweep), the reason property's definition hourly, the option value of a dropdown reason; `ingest-backfill` takes `--object deal,ticket` and `--again` re-reads stored records once per run. No `deploy.sh` change; two optional variables with defaults in the code (`INGEST_STAGE_READ_MIN_MS`, `INGEST_STAGE_READ_MAX_PROPERTIES`), set nowhere.
- Web: Reports → Funnel and Reports → Cancellations after Attempts per agent; on Configuration → Sources a Read times column per deal stage, the Reasons card and the record kind rules on a CRM connection, the record kinds and the cancellation kind on the Sources list.
- Seeds: `02` does not change and is not run. `03` (dev) switches `deals` on in `reports.per_person`; it runs again in dev after `98` (step 5).
- No `cloudbuild.yaml` change, no environment variable of the web, no HubSpot app change: reading a property's definition needs no scope beyond the app's own (`hubspot/README.md`, Scopes).

**Order matters:**
- The database first, in dev and in prod. `main`'s web and ingest run unchanged on `96` and `98`: `98` adds keys to `cma.connection_config` and accepts more values, and changes nothing either of them reads in shape.
- Then this branch's ingest image in dev (step 6), the configuration and the backfill in dev (steps 7 and 8). The new ingest calls `cma.ingest_record_stages` and `cma.ingest_upsert_reasons`, so it needs `96` and `98` first.
- Dev runs `main`'s web image (`docs/RUNBOOK.md`, section 4), and its HubSpot connection is the developer test account `CMA dev`, not the live portal. So steps 7 and 8 configure and read dev in Studio, with two HubSpot default dropdowns standing in for the live portal's reason properties, and this branch's pages are first seen in prod after the merge (steps 15 and 17).
- The reasons are stored only once the sweep has read the mapped property and found a dropdown. So: map the property (in Studio in dev, step 7; on Sources in prod, step 15), wait for the sweep, then the backfill with `--again` (steps 8 and 16), which fills both the stage times and the reasons of the stored records.
- In prod: `96` and `98` (steps 10 and 11), the timings (step 12), then the merge (the web deploys, step 13), then the ingest from `main` (step 14), the Sources settings and the backfill (steps 15 and 16).
- The data map: `docs/datamap/catalog.json` gains the new tables, views and columns. `verify:datamap` fails on this branch until step 9 refreshes `schema.json` from dev.

| Step | What | Elapsed |
|---|---|---|
| 0 | Review the pull request, build it, check the additions | 10 min |
| 1 | HubSpot: the stage properties and the reason properties (done 21 October 2026) | – |
| 2 | Dev: `96` twice with the fingerprint, `97` normal and provoked | 5 min |
| 3 | Dev: `98` twice with the fingerprint | 3 min |
| 4 | Dev: `99` normal and provoked (Terminal), the earlier verifies again | 25 min |
| 5 | Dev: `03` again, deals per person | 2 min |
| 6 | Dev: the ingest image from the branch | 10 min |
| 7 | Dev: the configuration in Studio (stand-in reasons, data quality, the cancellation kind) | 10 min |
| 8 | Dev: the backfill with `--again`, the figures in Studio | 10 to 30 min |
| 9 | The data map: snapshot from dev, rebuild, push | 5 min |
| 10 | Prod: point-in-time recovery, the additions | 2 min |
| 11 | Prod: `96` twice, `98` twice | 5 min |
| 12 | Prod: the timings as `cma_app` | 5 min |
| 13 | Merge and watch the build | 15 min |
| 14 | Prod: the ingest from `main` | 10 min |
| 15 | Prod: Sources settings in the web UI, its first look | 10 min |
| 16 | Prod: the backfill with `--again`, the figures in Studio | 30 to 90 min |
| 17 | Prod: the hand checks and the request log | 15 min |

---

## 0. Review the pull request, build it, check the additions

**Browser:** GitHub → Pulse4all-com/cma → Pull requests → "Funnel, lost reasons and cancellations (0008za, 0008zb)". Read the description and the diff.

Expected:
- in `db/`, the new `96_stage_times.sql`, `97_verify_stage_times.sql`, `98_funnel.sql`, `99_verify_funnel.sql`, and `03_seed_dev_test_data.sql` changed (`deals` in `reports.per_person`);
- under `ingest/`, the HubSpot adapter (`map.mjs`, `read.mjs`, `backfill.mjs`, `index.mjs`, the new `reasons.mjs`), `core/store.mjs`, the backfill job and its entry point, two new verifiers and `jobs-flow.mjs` amended;
- under `web/`, the Funnel and Cancellations pages, components and routes, the Sources components and routes, `lib/funnel.ts`, the data layer, the copy and the verifiers;
- `docs/funnel-2026-10/` (this runbook and `local-records/`), the data model, API, features, KPIs, decisions, open decisions, the ingest README, `docs/datamap/catalog.json` and `CHANGELOG.md`;
- `hubspot/README.md` with one row in Scopes (the property read needs no new scope); nothing under `cloudbuild.yaml`, `records/` or `hubspot/template/`.

**Terminal** (the pull request's number from the page)
```bash
cd ~/cma && gh pr checkout <number> && cd web && npm ci --no-audit --no-fund 2>&1 | tail -1 && npm run build > /tmp/build.txt 2>&1; echo "build exit: $?"; npm run typecheck 2>&1 | tail -1; npm run verify:reports 2>&1 | tail -1; cd ../ingest && npm ci --no-audit --no-fund 2>&1 | tail -1 && npm test 2>&1 | grep -c "ALL .* PASS"; cd ~/cma
```
Expected:
- `found 0 vulnerabilities`, or the known advisories of Open decisions;
- `build exit: 0`;
- `✓ Types generated successfully`;
- `ALL 178 PASS`;
- the ingest's `npm ci` line, then `16` (one `ALL n PASS` per pure verifier, `funnel-mapping` the new one).

**Do not merge yet.**

**Studio (cma-dev-pg)** and **Studio (cma-prod-pg)** (read only)
```sql
set role cma_owner;
select version, applied_at from cma.schema_migration where version >= '0008z' order by 1;
reset role;
```
Expected on both instances: `0008z` only. Without `0008z`, run `docs/attempts-2026-10/RUNBOOK-0008z.md` first. With `0008za` already there, stop and tell me.

## 1. HubSpot: the stage properties and the reason properties (done 21 October 2026)

Done by Martin on 21 October 2026 in the live portal (147946837), Settings → Data Management → Properties:
- **Stage times:** per stage a calculated HubSpot property `hs_v2_date_entered_<stage id>` with `hs_v2_date_exited_<stage id>` beside it (for example `hs_v2_date_entered_closedwon`), field type `Date and time picker`, not editable. The ticket pipeline `Cancellation` has 20 of them enabled; `Operations Pipeline` and `Incidents` have none, so their stages get no times. Which stages of the counted pipelines lack times is no longer checked by hand: the gap query of step 8 (dev) and step 16 (prod) lists them.
- **The deals' lost reason:** `closed_lost_reason__dropdown`, field type `Dropdown select`, 13 options, among them the four data-quality ones (KPIs 5): `Garbage`, `Duplicate`, `Wrong Phone` and `Accidentally Signed Up`.
- **The tickets' cancellation reason:** `cancellation_reason`, field type `Dropdown select`, 11 options.
- **The cancellation requests:** the dedicated ticket pipeline `Cancellation`.

These are the live portal's names, and steps 15 to 17 use them. Dev's HubSpot connection is the developer test account `CMA dev`, which has none of them: step 7 maps two HubSpot default dropdowns in their place.

Nothing to run in this step.

## 2. Dev: `96` twice with the fingerprint, `97` normal and provoked

**Studio (cma-dev-pg)** (read only: the fingerprint of the functions and views)
```sql
set role cma_owner;
select (select count(*) from pg_proc p where p.pronamespace in ('cma'::regnamespace, 'cma_read'::regnamespace)) as functions,
       (select md5(string_agg(p.oid::regprocedure::text || pg_get_functiondef(p.oid), '' order by p.oid::regprocedure::text))
          from pg_proc p where p.pronamespace in ('cma'::regnamespace, 'cma_read'::regnamespace) and p.prokind = 'f') as functions_md5,
       (select count(*) from pg_class c where c.relkind = 'v' and c.relnamespace in ('cma'::regnamespace, 'cma_read'::regnamespace)) as views,
       (select count(*) from pg_class c where c.relkind = 'r' and c.relnamespace = 'cma'::regnamespace) as tables,
       (select string_agg(m.version, ' ' order by m.version) from cma.schema_migration m where m.version >= '0008z') as additions;
reset role;
```
Expected: one row, `additions` `0008z`. Write down `functions`, `views` and `tables` (locally at 0008z 475, 120 and 81; dev's own counts are the reference below).

**File:** `db/96_stage_times.sql`: open it and copy all of it.

**Studio (cma-dev-pg):** paste the whole script and Run.

Expected: no error; Studio's last result is `reset role`. `addition 0008z (94_attempts_for_sales.sql) must run before 0008za` means step 0 found no `0008z`.

**Studio (cma-dev-pg):** the fingerprint block again.

Expected: `functions` 3 more, `views` 1 more (`cma_read.crm_record_stage`), `tables` 1 more (`cma.crm_record_stage`), `additions` `0008z 0008za` (locally 478, 121 and 82). Write down `functions_md5`.

**Studio (cma-dev-pg):** paste `96` again and Run; then the fingerprint block again.

Expected: the same row, `functions_md5` included: the second run adds nothing (locally `local-records/db/fingerprint-after-96.txt` and `-rerun.txt`).

**File:** `db/97_verify_stage_times.sql`: copy all of it. **Studio (cma-dev-pg):** paste and Run. Open the results dropdown at the verdict table.

Expected: rows `A1` to `A5` and `B1` to `B12`, each `PASS`, and `verdict | PASS | 17 PASS, 0 FAIL`. `REFUSED: not dev` means the instance is not dev's. Any `FAIL`: send me the row.

**Studio (cma-dev-pg):** `97` again, provoked (the rule above).

Expected: every row `FAIL`, `verdict | PROVOKED, NOT A PASS | 0 PASS, 17 FAIL`. Block B rolls back.

## 3. Dev: `98` twice with the fingerprint

**File:** `db/98_funnel.sql`: copy all of it. **Studio (cma-dev-pg):** paste and Run.

Expected: no error, the last result `reset role`. `addition 0008za (96_stage_times.sql) must run before 0008zb` means step 2 did not run `96`.

**Studio (cma-dev-pg):** the fingerprint block of step 2 again.

Expected: `functions` 37 more than after `96`, `views` 5 more (`deal_funnel_rows`, `cancellation_rows` and the three table views; `crm_record_detail` replaced), `tables` 3 more (`connection_reason`, `record_kind`, `connection_record_kind`), `additions` `0008z 0008za 0008zb` (locally 515, 126 and 85). Write down `functions_md5`.

**Studio (cma-dev-pg):** paste `98` again and Run; then the fingerprint block again.

Expected: the same row. Locally the two runs gave the same fingerprint (`local-records/db/fingerprint-after-98.txt`, `-rerun.txt`).

## 4. Dev: `99` normal and provoked, the earlier verifies again

`99` builds a throwaway tenant at about twice prod's deal volume and reads every page of a month and of 92 days, best of three, so it runs from the Terminal.

**Terminal** (in `~/cma`, on the branch)
```bash
cma_db dev && time psql "$PGCONN" -X -v ON_ERROR_STOP=1 -f db/99_verify_funnel.sql > /tmp/99.txt 2>&1; grep -E "^ *(A|B|C)[0-9]+ |verdict" /tmp/99.txt | cut -c1-160
```
Expected: rows `A1` to `A8`, `B1` to `B23` and `C1` to `C2`, each `PASS`; `verdict | PASS | 33 PASS, 0 FAIL`. C2 names every page read with its milliseconds; each must stay under 1000 (locally: deal_funnel_page 307.3 ms; NL 245.5 ms; pipeline 259.3 ms; source 245.4 ms; lost_reasons_page week 233.7 ms; day GB 223.3 ms; cancellations_page week 175.8 ms; day NL 109.4 ms; deals_per_person_page 237.2 ms; 92 days 394.4 ms; the whole script 21 seconds). Send me C2's line. A `FAIL` in C2 alone on dev's shared core: send it; prod's timings in step 12 decide.

**Terminal:** the same, provoked:
```bash
sed "s/'verify.provoke', 'false'/'verify.provoke', 'true'/" db/99_verify_funnel.sql > /tmp/99p.sql && cma_db dev && psql "$PGCONN" -X -f /tmp/99p.sql > /tmp/99p.txt 2>&1; grep -E "verdict" /tmp/99p.txt
```
Expected: `verdict | PROVOKED, NOT A PASS | 0 PASS, 33 FAIL`.

**Studio (cma-dev-pg):** `97` again (normal), then `95`, `93`, `85`, `81`, `73` and `41`, each pasted whole and Run; `91` from the Terminal as `99` above.

Expected:
- `97`: 17 PASS;
- `95`: 36 PASS; `93`: 25 PASS; `85`: 26 PASS; `81`: 19 PASS; `73`: 21 PASS; `41`: both tenant rows PASS;
- `91`: 13 PASS (dev's shared core may fail B8 on time, as on 19 October 2026: send it if so).

Locally every one of them passed after `98` (`local-records/db/*-after-0008zb.txt`).

## 5. Dev: `03` again, deals per person

**File:** `db/03_seed_dev_test_data.sql`. **Studio (cma-dev-pg):** paste and Run.

Expected: no error.

**Studio (cma-dev-pg)** (read only)
```sql
set role cma_owner;
select t.slug, cma.setting_of(t.id, 'reports.per_person') as per_person from cma.tenant t where t.slug like 'pulse4all-%' order by 1;
reset role;
```
Expected: `pulse4all-subscriptions | email,orders,attempts,deals` (dev only; prod keeps its own value), `pulse4all-invest` empty.

## 6. Dev: the ingest image from the branch

**Terminal** (from the Chromebook, on the pull request's branch, no uncommitted change under `ingest/`)
```bash
cd ~/cma && git status --short ingest/ docs/ingest/deploy.sh && bash docs/ingest/deploy.sh dev --allow-branch && bash docs/ingest/deploy.sh dev --jobs --allow-branch
```
Expected: no `git status` line; the warning naming the branch and the image tag; the build ending `SUCCESS` (or `image … exists …; no build`), `health: {"ok":true,"version":"<sha>"}`; then the jobs and their schedules as before.

**Terminal** (a minute later: the sweep's first lines with the new image)
```bash
gcloud logging read 'resource.type="cloud_run_job" AND resource.labels.job_name="ingest-sweep" AND jsonPayload.message:"reason"' --project=p4a-cma-dev --freshness=10m --limit=5 --format='value(jsonPayload.message,jsonPayload.code,jsonPayload.types)'
```
Expected: nothing yet (no reason property is mapped until step 7).

## 7. Dev: the configuration in Studio (stand-in reasons, data quality, the cancellation kind)

Dev's `cma-web` runs `main`'s image (`docs/RUNBOOK.md`, section 4), so this branch's Sources page is not in dev; prod shows it first, after the merge (step 15). Dev's HubSpot connection is the developer test account `CMA dev`, which has neither the live portal's reason properties nor its `Cancellation` pipeline. So this step sets dev in Studio, through the database functions the Sources page calls, and maps two HubSpot default properties as stand-ins:
- deals: `dealtype` (Deal Type), an enumeration with the options `newbusiness` (New Business) and `existingbusiness` (Existing Business);
- tickets: `hs_ticket_priority` (Priority), an enumeration with `LOW`, `MEDIUM`, `HIGH` and `URGENT`.

Both are HubSpot's own default properties, present in every portal. Their type and options were read from HubSpot's properties API on 21 October 2026 (the live portal): both answer `"type": "enumeration"`. HubSpot's documentation sites (`knowledge.hubspot.com`, `developers.hubspot.com`) were not reachable from Claude Code's session, so this rests on the API's answer, not on the documentation; the published API specs name both as default properties but give no field type. The test account's option lists may differ from the live portal's; that changes nothing here. The read times keep their defaults (every stage of a counted pipeline), so nothing is set for them.

**Studio (cma-dev-pg)** (writes configuration as `admin@example.com`, the dev seed's admin, who holds `tenant.configure`; the audit names `studio:martin`. Rerunnable: run it now and once more after the sweep)
```sql
set role cma_owner;
drop table if exists pg_temp.dev_ctx;
create temp table dev_ctx as
  select t.id as tenant_id,
         (select u.id from cma.app_user u where u.tenant_id = t.id and u.email = 'admin@example.com') as user_id,
         (select (array_agg(c.id))[1] from cma.integration_connection c where c.tenant_id = t.id and c.adapter = 'hubspot') as connection_id,
         (select count(*) from cma.integration_connection c where c.tenant_id = t.id and c.adapter = 'hubspot') as connections
  from cma.tenant t where t.slug = 'pulse4all-subscriptions';
drop table if exists pg_temp.dev_result;
create temp table dev_result (n int, item text, outcome text);
grant select on dev_ctx to cma_app;
grant select, insert on dev_result to cma_app;
set role cma_app;
do $$
declare
  c          record;
  v_pipeline text;
  v_label    text;
  v_option   text;
  v_type     text;
begin
  select * into c from dev_ctx;
  if c.user_id is null then
    raise exception 'no admin@example.com in pulse4all-subscriptions: run this block on cma-dev-pg';
  end if;
  if c.connections <> 1 then
    raise exception 'pulse4all-subscriptions has % HubSpot connections; this block expects one', c.connections;
  end if;
  perform set_config('app.tenant_id', c.tenant_id::text, true);
  perform set_config('app.user_id', c.user_id::text, true);
  perform set_config('app.actor_label', 'studio:martin', true);
  -- the reasons: two HubSpot default enumerations as stand-ins (dev's test account has the live portal's properties not)
  perform cma.set_connection_field(c.connection_id, 'deal', 'reason', '', 'dealtype', 1::smallint);
  perform cma.set_connection_field(c.connection_id, 'ticket', 'reason', '', 'hs_ticket_priority', 1::smallint);
  insert into dev_result values (1, 'deal reason', 'dealtype'), (2, 'ticket reason', 'hs_ticket_priority');
  -- the kind, and its rule on the test account's ticket pipeline (the first by label)
  perform cma.set_record_kind('cancellation', 'Cancellation request', 'ticket', null);
  select p.source_pipeline_id, p.label into v_pipeline, v_label
  from cma.connection_pipeline p
  where p.tenant_id = c.tenant_id and p.connection_id = c.connection_id and p.record_type = 'ticket' and p.status = 'active'
  order by p.label, p.source_pipeline_id
  limit 1;
  if v_pipeline is null then
    raise exception 'the HubSpot connection holds no active ticket pipeline';
  end if;
  perform cma.set_record_kind_rule(c.connection_id, 'cancellation', v_pipeline, null, true);
  insert into dev_result values (3, 'kind cancellation, its rule on the ticket pipeline', v_label);
  -- the kind Reports, Cancellations counts
  perform cma.set_tenant_setting('reports.cancellation_kind', 'cancellation');
  insert into dev_result values (4, 'reports.cancellation_kind', 'cancellation');
  -- one dealtype option as data quality, once the sweep has read dealtype (existingbusiness when HubSpot has it)
  select f.source_type into v_type
  from cma.connection_field f
  where f.tenant_id = c.tenant_id and f.connection_id = c.connection_id and f.entity = 'deal' and f.field = 'reason';
  select cr.value into v_option
  from cma.connection_reason cr
  where cr.tenant_id = c.tenant_id and cr.connection_id = c.connection_id and cr.record_type = 'deal' and cr.status = 'active'
  order by cr.value = 'existingbusiness' desc, cr.sort_order desc, cr.value
  limit 1;
  if v_type is null then
    insert into dev_result values (5, 'data quality', 'not yet: the sweep has not read dealtype; run this block again in two minutes');
  elsif v_type <> 'enumeration' or v_option is null then
    insert into dev_result values (5, 'data quality', 'none: dealtype is ' || v_type || ' with no option; send me this row');
  else
    perform cma.set_reason_data_quality(c.connection_id, 'deal', v_option, true);
    insert into dev_result values (5, 'data quality', v_option);
  end if;
end
$$;
select n, item, outcome from dev_result order by n;
reset role;
```
Expected: five rows: `1 | deal reason | dealtype`, `2 | ticket reason | hs_ticket_priority`, `3 | kind cancellation, its rule on the ticket pipeline | <the test account's ticket pipeline, the first by label>`, `4 | reports.cancellation_kind | cancellation` and `5 | data quality | not yet: the sweep has not read dealtype; run this block again in two minutes`. The data-quality flag waits for the sweep because a flag goes on an option the CMA has read from HubSpot. `no admin@example.com in pulse4all-subscriptions` means the instance is not dev's. `… HubSpot connections; this block expects one` or `… holds no active ticket pipeline`: send me the message.

**Terminal** (two minutes later: the sweep has read both definitions)
```bash
gcloud logging read 'resource.type="cloud_run_job" AND resource.labels.job_name="ingest-sweep" AND (jsonPayload.message="hubspot reason properties" OR jsonPayload.message="reason property not read")' --project=p4a-cma-dev --freshness=10m --limit=5 --format='value(jsonPayload.message,jsonPayload.code,jsonPayload.types,jsonPayload.options)'
```
Expected: `hubspot reason properties` with `deal:enumeration` and `ticket:enumeration`, and 6 options (2 for `dealtype`, 4 for `hs_ticket_priority`; the test account's own lists may give another count). `reason property not read` with a code instead: send me the line; the sweep reads the definition again on its next run. The read needs no scope beyond the app's own (`hubspot/README.md`, Scopes).

**Studio (cma-dev-pg):** the block above again.

Expected: rows 1 to 4 as before and `5 | data quality | existingbusiness`: that option now stands in for Never a lead. `none: dealtype is …`: send me the row.

**Studio (cma-dev-pg)** (read only: the configuration as stored; labels of options and kinds, counts)
```sql
set role cma_owner;
select f.entity, f.source_property, f.source_type, f.checked_at is not null as checked
from cma.connection_field f join cma.tenant t on t.id = f.tenant_id
where t.slug = 'pulse4all-subscriptions' and f.field = 'reason' order by 1;
select cr.record_type, count(*) filter (where cr.status = 'active') as options, count(*) filter (where cr.is_data_quality) as data_quality
from cma.connection_reason cr join cma.tenant t on t.id = cr.tenant_id where t.slug = 'pulse4all-subscriptions' group by 1 order by 1;
select k.key, k.record_type, k.status, (select count(*) from cma.connection_record_kind r where r.tenant_id = k.tenant_id and r.kind_key = k.key and r.status = 'active') as rules,
       k.key = cma.setting_of(k.tenant_id, 'reports.cancellation_kind') as counted
from cma.record_kind k join cma.tenant t on t.id = k.tenant_id where t.slug = 'pulse4all-subscriptions';
select count(*) filter (where cma.read_times_of(s.read_times, p.is_counted)) as stages_reading_times, count(*) as deal_stages
from cma.connection_stage s join cma.tenant t on t.id = s.tenant_id
left join cma.connection_pipeline p on p.tenant_id = s.tenant_id and p.connection_id = s.connection_id and p.record_type = s.record_type and p.source_pipeline_id = s.source_pipeline_id
where t.slug = 'pulse4all-subscriptions' and s.record_type = 'deal' and s.status = 'active';
reset role;
```
Expected: `deal | dealtype | enumeration | t` and `ticket | hs_ticket_priority | enumeration | t`; `deal | 2 | 1` and `ticket | 4 | 0` (the test account's option counts); `cancellation | ticket | active | 1 | t`; the stages reading times are the counted pipelines' deal stages, out of every deal stage.

## 8. Dev: the backfill with `--again`, the figures in Studio

The stored deals and tickets have no stage times and no reasons yet: a backfill with `--again` reads each of them once more (the API budget's daily floor, backlog CMA-069, stops it in time; the same command continues later).

**Studio (cma-dev-pg)** (read only: how many records the run will read; counts only)
```sql
set role cma_owner;
select r.record_type, count(*) as records
from cma.crm_record r join cma.tenant t on t.id = r.tenant_id
where t.slug = 'pulse4all-subscriptions' and r.source_deleted_at is null
  and r.source_created_at >= (cma.setting_of(t.id, 'intake.start_date')::date::timestamp at time zone t.timezone)
group by 1 order by 1;
select c.id as connection from cma.integration_connection c join cma.tenant t on t.id = c.tenant_id
where t.slug = 'pulse4all-subscriptions' and c.adapter = 'hubspot';
reset role;
```
Expected: the deals and tickets since the start date, and the connection's id (`<conn>` below). The run makes about four requests per 100 records of each type (two search pages, the batch read with the stage times and the reason, the associations read) plus the contact reads of contacts not yet held: for 1,000 deals about 40 requests. Its log line names the requests per endpoint.

**Terminal**
```bash
gcloud run jobs execute ingest-backfill --project=p4a-cma-dev --region=europe-west4 --wait --args='^;^--connection;<conn>;--object;deal,ticket;--again'
```
Expected: `Execution [ingest-backfill-…] has successfully completed.` A failed or paused execution runs again with the same arguments: it continues where it stopped. The `^;^` at the start is gcloud's alternate delimiter (`gcloud topic escaping`): gcloud splits `--args` on every comma, so `--args=--connection,<conn>,--object,deal,ticket,--again` hands the job `ticket` as a stray argument and it exits with code 2; with `^;^` the arguments are separated by `;` and `deal,ticket` stays one (21 October 2026: dev `ingest-backfill-dzcmr` and prod `ingest-backfill-j9cgv` succeeded so).

**Terminal** (the run's log line: counts and requests per endpoint)
```bash
gcloud logging read 'resource.type="cloud_run_job" AND resource.labels.job_name="ingest-backfill" AND jsonPayload.message:"backfill"' --project=p4a-cma-dev --freshness=1h --limit=4 --format=json | grep -E '"(message|object|fetched|written|apiCalls|POST [^"]*|GET [^"]*)"' | head -30
```
Expected: one `backfill` line per object (`deal`, `ticket`) with `fetched` above 0, `apiCalls` near the estimate, the endpoints with their counts, `daily` with HubSpot's remaining requests; `backfill paused` means the daily floor stopped it (run the same command later).

**Studio (cma-dev-pg)** (read only: per pipeline what the run filled; labels of pipelines, counts)
```sql
set role cma_owner;
select r.record_type, p.label as pipeline, p.is_counted as counted, count(*) as records,
       count(*) filter (where exists (select 1 from cma.crm_record_stage rs
                                      where rs.tenant_id = r.tenant_id and rs.connection_id = r.connection_id
                                        and rs.record_type = r.record_type and rs.source_id = r.source_id)) as with_stage_times,
       (select count(*) from cma.crm_record_stage rs
        where rs.tenant_id = r.tenant_id and rs.connection_id = r.connection_id and rs.record_type = r.record_type
          and rs.source_pipeline_id = r.pipeline_id) as stage_times,
       count(*) filter (where r.reason is not null) as with_reason
from cma.crm_record r
join cma.tenant t on t.id = r.tenant_id
join cma.integration_connection c on c.id = r.connection_id and c.adapter = 'hubspot'
left join cma.connection_pipeline p
  on p.tenant_id = r.tenant_id and p.connection_id = r.connection_id and p.record_type = r.record_type and p.source_pipeline_id = r.pipeline_id
where t.slug = 'pulse4all-subscriptions' and r.record_type in ('deal', 'ticket') and r.source_deleted_at is null
group by r.tenant_id, r.connection_id, r.record_type, r.pipeline_id, p.label, p.is_counted
order by 1, 2;
select s.stream, s.status, s.counts, s.error
from cma.sync_run s join cma.tenant t on t.id = s.tenant_id
where t.slug = 'pulse4all-subscriptions' and s.job = 'backfill'
order by s.started_at desc limit 2;
reset role;
```
Expected: one row per pipeline of deals and tickets that holds records: `records`; `with_stage_times`, most of a counted pipeline's records; `stage_times`; `with_reason`, the deals with a Deal type and the tickets with a Priority. Then the two backfill runs (`deal`, `ticket`), `succeeded`, no error.

**Studio (cma-dev-pg)** (read only: the stages of the counted pipelines that have no time at all; labels of pipelines and stages, counts)
```sql
set role cma_owner;
select g.record_type, g.pipeline, g.stage, g.records_now_in_stage,
       case when g.records_now_in_stage > 0 then 'gap: records sit in it, none has its entry time'
            else 'no record has entered it yet' end as verdict
from (
  select s.record_type, p.label as pipeline, s.label as stage, s.display_order,
         (select count(*) from cma.crm_record r
          where r.tenant_id = s.tenant_id and r.connection_id = s.connection_id and r.record_type = s.record_type
            and r.pipeline_id = s.source_pipeline_id and r.stage_id = s.source_stage_id and r.source_deleted_at is null) as records_now_in_stage,
         (select count(*) from cma.crm_record_stage rs
          where rs.tenant_id = s.tenant_id and rs.connection_id = s.connection_id and rs.record_type = s.record_type
            and rs.source_pipeline_id = s.source_pipeline_id and rs.source_stage_id = s.source_stage_id
            and rs.entered_at is not null) as with_entry_time
  from cma.connection_stage s
  join cma.tenant t on t.id = s.tenant_id
  join cma.integration_connection c on c.id = s.connection_id and c.adapter = 'hubspot'
  join cma.connection_pipeline p
    on p.tenant_id = s.tenant_id and p.connection_id = s.connection_id and p.record_type = s.record_type
   and p.source_pipeline_id = s.source_pipeline_id
  where t.slug = 'pulse4all-subscriptions' and s.status = 'active' and p.status = 'active' and coalesce(p.is_counted, true)
    and cma.read_times_of(s.read_times, p.is_counted)
) g
where g.with_entry_time = 0
order by g.record_type, g.pipeline, g.display_order, g.stage;
reset role;
```
Expected: a row only for a stage without a single entry time. `no record has entered it yet` is fine. `gap: records sit in it, none has its entry time` means HubSpot gives that stage no calculated property, or the backfill has not reached its records yet: if the backfill paused, run it again first; otherwise send me the rows. This query replaces checking the stages one by one in HubSpot; step 16 runs it in prod.

**Studio (cma-dev-pg)** (the two page reads as `admin@example.com`, who holds the report permissions; counts only, the answers are discarded)
```sql
set role cma_owner;
drop table if exists pg_temp.dev_ctx;
create temp table dev_ctx as
  select t.id as tenant_id, u.id as user_id, (now() at time zone t.timezone)::date as today
  from cma.tenant t join cma.app_user u on u.tenant_id = t.id
  where t.slug = 'pulse4all-subscriptions' and u.email = 'admin@example.com';
drop table if exists pg_temp.dev_pages;
create temp table dev_pages (n int, read text, figures text);
grant select on dev_ctx to cma_app;
grant select, insert on dev_pages to cma_app;
set role cma_app;
do $$
declare
  c record;
  j jsonb;
begin
  select * into c from dev_ctx;
  if c.user_id is null then
    raise exception 'the block''s user is not in pulse4all-subscriptions: check the email and the instance';
  end if;
  perform set_config('app.tenant_id', c.tenant_id::text, true);
  perform set_config('app.user_id', c.user_id::text, true);
  perform set_config('app.actor_label', 'studio:martin', true);
  j := cma.deal_funnel_page(c.today - 91, c.today);
  insert into dev_pages values (1, 'deal_funnel_page, the last 92 days',
    format('created %s, won %s, lost %s; stages on the page %s; deal stages reading times %s; entries in the period %s',
           j -> 'by_pipeline' -> 'total' -> 'current' ->> 'created', j -> 'by_pipeline' -> 'total' -> 'current' ->> 'won',
           j -> 'by_pipeline' -> 'total' -> 'current' ->> 'lost', jsonb_array_length(j -> 'stages'), j ->> 'timed_stages',
           (select coalesce(sum((x ->> 'entered')::int), 0) from jsonb_array_elements(j -> 'stages') x)));
  j := cma.cancellations_page(c.today - 91, c.today, null, 'week');
  insert into dev_pages values (2, 'cancellations_page, the last 92 days',
    format('requests %s, open %s, closed %s; markets %s', j -> 'current' ->> 'requests', j -> 'current' ->> 'open',
           j -> 'current' ->> 'closed', jsonb_array_length(j -> 'by_market')));
end
$$;
select read, figures from dev_pages order by n;
reset role;
```
Expected: two rows. `deal_funnel_page, the last 92 days`: the test account's deals created, won and lost in that time, the stages on the page, the deal stages reading times, and the stage entries in that time (above 0 once the test account's deals moved through stages). `cancellations_page, the last 92 days`: the requests (the tickets of step 7's pipeline created in that time), open and closed, and the markets they fall in. Send me the two rows. `CMA06` means the user lacks `reports.view` and `performance.team`.

## 9. The data map: snapshot from dev, rebuild, push

As `docs/datamap/README.md`, Refreshing the snapshot, on this branch: the snapshot from dev, `node tools/datamap/build.mjs && node tools/datamap/build.mjs --check`, then commit `docs/datamap/schema.json` and `docs/datamap/index.html` and push.

Expected: `datamap: wrote docs/datamap/index.html (85 tables, 117 views)`, then `datamap: 85 tables, 117 views, all described; index.html current` (the local snapshot's counts; dev's match when dev holds no table of its own); `latest_migration` `0008zb`. Locally the catalog described every table and view of a snapshot of the local database at 0008zb (`local-records/datamap-check.txt`).

## 10. Prod: point-in-time recovery, the additions

**Terminal**
```bash
gcloud sql instances describe cma-prod-pg --project=p4a-cma-prod --format='value(settings.backupConfiguration.pointInTimeRecoveryEnabled)'
```
Expected: `True`. Otherwise stop.

**Studio (cma-prod-pg):** the block of step 0 again. Expected: `0008z` only.

## 11. Prod: `96` twice, `98` twice

**Studio (cma-prod-pg):** the fingerprint block of step 2. Write down the row.

**Studio (cma-prod-pg):** `db/96_stage_times.sql`, Run; the fingerprint; `96` again; the fingerprint. Then `db/98_funnel.sql`, Run; the fingerprint; `98` again; the fingerprint.

Expected: no error; after each script the same `functions` and `views` counts as dev's in steps 2 and 3, and the same row after its second run. A `functions_md5` that differs from dev's with the same counts: `tools/drift/functions.sql` names the functions that differ (`docs/RUNBOOK.md`, 7b).

No verify runs in prod: `97` and `99` refuse a database without the dev seed.

## 12. Prod: the timings as `cma_app`

**Studio (cma-prod-pg)** (read only: the page reads of this month as `martin@pulse4all.com`, best of three each; milliseconds only, the answers are discarded)
```sql
set role cma_owner;
drop table if exists pg_temp.funnel_timing;
create temp table funnel_timing (read text, ms numeric);
grant select, insert on funnel_timing to cma_app;
drop table if exists pg_temp.funnel_ctx;
create temp table funnel_ctx as
  select t.id as tenant_id, u.id as user_id from cma.tenant t join cma.app_user u on u.tenant_id = t.id
  where t.slug = 'pulse4all-subscriptions' and u.email = 'martin@pulse4all.com';
grant select on funnel_ctx to cma_app;
set role cma_app;
do $$
declare
  c record; r record; i int; t0 timestamptz; best numeric; j jsonb;
  v_from date := date_trunc('month', now() at time zone 'Europe/Amsterdam')::date;
  v_to   date := (now() at time zone 'Europe/Amsterdam')::date;
begin
  select * into c from funnel_ctx;
  perform set_config('app.tenant_id', c.tenant_id::text, true);
  perform set_config('app.user_id', c.user_id::text, true);
  perform set_config('app.actor_label', 'studio:martin', true);
  for r in select * from (values
      ('deal_funnel_page', format('select cma.deal_funnel_page(%L, %L)', v_from, v_to)),
      ('lost_reasons_page week', format('select cma.lost_reasons_page(%L, %L, null, null, null, ''week'')', v_from, v_to)),
      ('cancellations_page week', format('select cma.cancellations_page(%L, %L, null, ''week'')', v_from, v_to)),
      ('deal_funnel_page 92 days', format('select cma.deal_funnel_page(%L, %L)', v_to - 91, v_to))) x(read, sql) loop
    best := null;
    for i in 1..3 loop
      t0 := clock_timestamp();
      execute r.sql into j;
      best := least(coalesce(best, 1e9), extract(epoch from clock_timestamp() - t0) * 1000);
    end loop;
    insert into funnel_timing values (r.read, round(best, 1));
  end loop;
end
$$;
select read, ms from funnel_timing order by read;
reset role;
```
Expected: four rows, each under 1000 ms (locally, at about twice prod's volume: deal_funnel_page 307.3 ms, lost_reasons_page week 233.7 ms, cancellations_page week 175.8 ms, deal_funnel_page 92 days 394.4 ms). Send me the rows. `CMA06` means `martin@pulse4all.com` holds neither `reports.view` nor `performance.team`. (`deals_per_person_page` is not timed: `reports.per_person` holds no `deals` in prod.)

## 13. Merge and watch the build

**Browser:** the pull request → Squash and merge. Then Cloud Build (`p4a-cma-prod`) → History: the `cma-web-main` build of the merge.

Expected: `SUCCESS`, the new `cma-web` revision serving.

## 14. Prod: the ingest from `main`

**Terminal** (from the Chromebook, on `main`)
```bash
cd ~/cma && git switch main -q && git pull -q --ff-only && git log -1 --format=%h -- ingest/ && bash docs/ingest/deploy.sh prod --front ingest.pulse4all.app --tenant pulse4all-subscriptions && bash docs/ingest/deploy.sh prod --jobs
```
Expected: the image tag (the merge commit), `image … exists …; no build` (dev built it in step 6 from the same tree) or `SUCCESS`, `health: {"ok":true,"version":"<sha>"}`, the jobs and their schedules as before.

## 15. Prod: Sources settings in the web UI, its first look

This branch's Sources page is first seen here: dev runs `main`'s image, so steps 7 and 8 went through Studio. Check the web UI first in prod, after the merge (step 13) and the ingest (step 14).

**Browser:** prod's Workspace (`martin@pulse4all.com`) → Configuration → Sources → the HubSpot connection:
1. **Stage outcomes**, column **Read times**: every stage of the counted deal pipelines ticked with `Default`, the uncounted pipelines' stages unticked.
2. **Reasons → Deals: lost reason**: `closed_lost_reason__dropdown`, **Save property**. The state reads `Not checked yet`.
3. **Reasons → Tickets: reason**: `cancellation_reason`, **Save property**.
4. Configuration → Sources (the list) → **Record kinds** → **Add kind** (K): key `cancellation`, label `Cancellation request`, record type Tickets. Save. Then, on the HubSpot connection's page, **Record kind rules → Add rule** (R): the kind `Cancellation request`, the pipeline `Cancellation`, no category value. Save.
5. The Sources list → **Cancellation requests**: choose `Cancellation request`.

Expected: each save keeps the new value on the page, with no message under the card.

**If a save fails** (a red message under the card, the input kept): do not repeat it. Write down the message, set the same configuration in Studio with the block below (it calls the database functions the page calls), and send me the message and the block's rows; the page is fixed in a separate pull request.

**Studio (cma-prod-pg)** (only after a failed save; writes configuration as `martin@pulse4all.com`, the prod user with `tenant.configure`; the audit names `studio:martin`; rerunnable)
```sql
set role cma_owner;
drop table if exists pg_temp.prod_ctx;
create temp table prod_ctx as
  select t.id as tenant_id,
         (select u.id from cma.app_user u where u.tenant_id = t.id and u.email = 'martin@pulse4all.com') as user_id,
         (select (array_agg(c.id))[1] from cma.integration_connection c where c.tenant_id = t.id and c.adapter = 'hubspot') as connection_id,
         (select count(*) from cma.integration_connection c where c.tenant_id = t.id and c.adapter = 'hubspot') as connections
  from cma.tenant t where t.slug = 'pulse4all-subscriptions';
drop table if exists pg_temp.prod_result;
create temp table prod_result (n int, item text, outcome text);
grant select on prod_ctx to cma_app;
grant select, insert on prod_result to cma_app;
set role cma_app;
do $$
declare
  c           record;
  o           record;
  v_pipeline  text;
  v_pipelines integer;
  v_type      text;
  v_flagged   integer := 0;
begin
  select * into c from prod_ctx;
  if c.user_id is null then
    raise exception 'no martin@pulse4all.com in pulse4all-subscriptions: run this block on cma-prod-pg';
  end if;
  if c.connections <> 1 then
    raise exception 'pulse4all-subscriptions has % HubSpot connections; this block expects one', c.connections;
  end if;
  perform set_config('app.tenant_id', c.tenant_id::text, true);
  perform set_config('app.user_id', c.user_id::text, true);
  perform set_config('app.actor_label', 'studio:martin', true);
  -- the reasons: the live portal's two Dropdown select properties
  perform cma.set_connection_field(c.connection_id, 'deal', 'reason', '', 'closed_lost_reason__dropdown', 1::smallint);
  perform cma.set_connection_field(c.connection_id, 'ticket', 'reason', '', 'cancellation_reason', 1::smallint);
  insert into prod_result values (1, 'deal reason', 'closed_lost_reason__dropdown'), (2, 'ticket reason', 'cancellation_reason');
  -- the kind, and its rule on the ticket pipeline Cancellation
  perform cma.set_record_kind('cancellation', 'Cancellation request', 'ticket', null);
  select count(*), (array_agg(p.source_pipeline_id))[1] into v_pipelines, v_pipeline
  from cma.connection_pipeline p
  where p.tenant_id = c.tenant_id and p.connection_id = c.connection_id and p.record_type = 'ticket' and p.status = 'active'
    and p.label = 'Cancellation';
  if v_pipelines <> 1 then
    raise exception '% active ticket pipelines labelled Cancellation; this block expects one', v_pipelines;
  end if;
  perform cma.set_record_kind_rule(c.connection_id, 'cancellation', v_pipeline, null, true);
  insert into prod_result values (3, 'kind cancellation, its rule on the ticket pipeline', 'Cancellation');
  -- the kind Reports, Cancellations counts
  perform cma.set_tenant_setting('reports.cancellation_kind', 'cancellation');
  insert into prod_result values (4, 'reports.cancellation_kind', 'cancellation');
  -- the four data-quality options, once the sweep has read closed_lost_reason__dropdown
  select f.source_type into v_type
  from cma.connection_field f
  where f.tenant_id = c.tenant_id and f.connection_id = c.connection_id and f.entity = 'deal' and f.field = 'reason';
  if v_type is null then
    insert into prod_result values (5, 'data quality', 'not yet: the sweep has not read the property; run this block again in two minutes');
  elsif v_type <> 'enumeration' then
    insert into prod_result values (5, 'data quality', 'refused: the property is ' || v_type || ', not a dropdown; send me this row');
  else
    for o in select cr.value from cma.connection_reason cr
             where cr.tenant_id = c.tenant_id and cr.connection_id = c.connection_id and cr.record_type = 'deal' and cr.status = 'active'
               and lower(btrim(cr.label)) in ('garbage', 'duplicate', 'wrong phone', 'accidentally signed up') loop
      perform cma.set_reason_data_quality(c.connection_id, 'deal', o.value, true);
      v_flagged := v_flagged + 1;
    end loop;
    insert into prod_result values (5, 'data quality, of Garbage, Duplicate, Wrong Phone, Accidentally Signed Up', v_flagged || ' of 4 flagged');
  end if;
end
$$;
select n, item, outcome from prod_result order by n;
reset role;
```
Expected: `1 | deal reason | closed_lost_reason__dropdown`, `2 | ticket reason | cancellation_reason`, `3 | kind cancellation, its rule on the ticket pipeline | Cancellation`, `4 | reports.cancellation_kind | cancellation`, and on the first run `5 | data quality | not yet: …`. Run it again after the sweep (below): `5 | … | 4 of 4 flagged`. `… active ticket pipelines labelled Cancellation; this block expects one`: send me the message.

**Terminal** (two minutes later: the sweep has read both definitions)
```bash
gcloud logging read 'resource.type="cloud_run_job" AND resource.labels.job_name="ingest-sweep" AND (jsonPayload.message="hubspot reason properties" OR jsonPayload.message="reason property not read")' --project=p4a-cma-prod --freshness=10m --limit=5 --format='value(jsonPayload.message,jsonPayload.code,jsonPayload.types,jsonPayload.options)'
```
Expected: `hubspot reason properties` with `deal:enumeration` and `ticket:enumeration`, and 24 options (13 and 11).

**Browser:** reload the connection's page. Expected: `closed_lost_reason__dropdown` as `Dropdown` with 13 options, `cancellation_reason` as `Dropdown` with 11. Under **Deals: lost reason**, tick **Never a lead** on `Garbage`, `Duplicate`, `Wrong Phone` and `Accidentally Signed Up` (after a failed save, the Studio block's second run has flagged them).

**Studio (cma-prod-pg):** step 7's read-only check query.

Expected: `deal | closed_lost_reason__dropdown | enumeration | t` and `ticket | cancellation_reason | enumeration | t`; `deal | 13 | 4` and `ticket | 11 | 0`; `cancellation | ticket | active | 1 | t`; the stages reading times are the counted pipelines' deal stages.

## 16. Prod: the backfill with `--again`, the figures in Studio

Step 8 on prod, every block on **cma-prod-pg** and every command with `--project=p4a-cma-prod`: the count block, then
```bash
gcloud run jobs execute ingest-backfill --project=p4a-cma-prod --region=europe-west4 --wait --args='^;^--connection;<conn>;--object;deal,ticket;--again'
```
(the `^;^` form, as in step 8), then the log line, the per-pipeline block, the gap query, and the page reads with `admin@example.com` changed to `martin@pulse4all.com` (Ctrl+F: the block names the email once).

Expected: as in dev, with prod's counts: about four requests per 100 records, `backfill paused` if the daily floor is reached (the same command continues the next day). In the gap query, the stages of `Operations Pipeline` and `Incidents` if they count (step 1: they have no stage properties); any other row with `gap`: send it. `cancellations_page` counts the tickets of the pipeline `Cancellation`. Send me the two `backfill` log lines' counts and `apiCalls`, the per-pipeline rows, the gap rows and the two page rows.

## 17. Prod: the hand checks and the request log

These are the first checks of this branch's pages anywhere: dev ran `main`'s image throughout.

**Browser** (as `martin@pulse4all.com`), each with what you should see:
- Reports → Funnel, This month: six tiles with their changes; Per stage with each lead pipeline's stages, the bars and the table (a stage switched off says `Times not read for this stage`); Per pipeline with `Attempts per deal` opening that pipeline's deals; Lost reasons with four tiles, the real reasons as bars with the labels of `closed_lost_reason__dropdown`'s options, `No reason` below them, Never a lead with `Garbage`, `Duplicate`, `Wrong Phone` and `Accidentally Signed Up`, per market and per source, per week, the lost deals without a reason with their links (each opens the deal in HubSpot); no Deals per person (off in prod).
- G switches week and day; K, P and S filter; X downloads the stages file.
- Reports → Cancellations, This month: four tiles counting the requests of the ticket pipeline `Cancellation`, per market, the reasons with the labels of `cancellation_reason`'s options, per week and market, the newest requests with their links.
- Configuration → Sources: the Read times column, the Reasons card (`closed_lost_reason__dropdown` and `cancellation_reason`, both `Dropdown`), the record kind rule on `Cancellation`; the list's Record kinds with `Counted as cancellations`.

**Terminal** (the request log of the two pages since the merge)
```bash
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="cma-web" AND (jsonPayload.route="/reports/funnel" OR jsonPayload.route="/reports/cancellations")' --project=p4a-cma-prod --freshness=2h --limit=10 --format='value(jsonPayload.route,jsonPayload.status,jsonPayload.totalMs,jsonPayload.dbMs,jsonPayload.tx)'
```
Expected: `200`, `totalMs` around a second at most, `dbMs` under step 12's sums, `tx` 4 for the Funnel (3 for a reader without deals per person) and 2 for Cancellations. Send me the lines; they go into the record of the run (`records/`, written down from your report).
