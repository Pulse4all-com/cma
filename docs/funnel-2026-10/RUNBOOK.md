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
- Then this branch's ingest image in dev (step 6), the Sources settings and the backfill in dev (steps 7 and 8). The new ingest calls `cma.ingest_record_stages` and `cma.ingest_upsert_reasons`, so it needs `96` and `98` first.
- The reasons are stored only once the sweep has read the mapped property and found a dropdown. So: map the property on Sources, wait for the sweep (step 7 shows the state), then the backfill with `--again` (step 8), which fills both the stage times and the reasons of the stored deals.
- In prod: `96` and `98` (steps 10 and 11), the timings (step 12), then the merge (the web deploys, step 13), then the ingest from `main` (step 14), the Sources settings and the backfill (steps 15 and 16).
- The data map: `docs/datamap/catalog.json` gains the new tables, views and columns. `verify:datamap` fails on this branch until step 9 refreshes `schema.json` from dev.

| Step | What | Elapsed |
|---|---|---|
| 0 | Review the pull request, build it, check the additions | 10 min |
| 1 | HubSpot: the stage properties and the reason properties (Browser) | 10 min |
| 2 | Dev: `96` twice with the fingerprint, `97` normal and provoked | 5 min |
| 3 | Dev: `98` twice with the fingerprint | 3 min |
| 4 | Dev: `99` normal and provoked (Terminal), the earlier verifies again | 25 min |
| 5 | Dev: `03` again, deals per person | 2 min |
| 6 | Dev: the ingest image from the branch | 10 min |
| 7 | Dev: Sources settings (read times, reasons, data quality, the cancellation kind) | 10 min |
| 8 | Dev: the backfill with `--again` | 10 to 30 min |
| 9 | The data map: snapshot from dev, rebuild, push | 5 min |
| 10 | Prod: point-in-time recovery, the additions | 2 min |
| 11 | Prod: `96` twice, `98` twice | 5 min |
| 12 | Prod: the timings as `cma_app` | 5 min |
| 13 | Merge and watch the build | 15 min |
| 14 | Prod: the ingest from `main` | 10 min |
| 15 | Prod: Sources settings | 10 min |
| 16 | Prod: the backfill with `--again` | 30 to 90 min |
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
- `ALL 177 PASS`;
- the ingest's `npm ci` line, then `16` (one `ALL n PASS` per pure verifier, `funnel-mapping` the new one).

**Do not merge yet.**

**Studio (cma-dev-pg)** and **Studio (cma-prod-pg)** (read only)
```sql
set role cma_owner;
select version, applied_at from cma.schema_migration where version >= '0008z' order by 1;
reset role;
```
Expected on both instances: `0008z` only. Without `0008z`, run `docs/attempts-2026-10/RUNBOOK-0008z.md` first. With `0008za` already there, stop and tell me.

## 1. HubSpot: the stage properties and the reason properties

**Browser:** HubSpot (the Subscriptions portal) → Settings → Data Management → Properties → Deal properties. Search `Date entered`.

Expected: per stage of every lead pipeline one property `Date entered "<stage>" (<pipeline>)`, and `Date exited "<stage>" (<pipeline>)` beside it. Open one: its internal name is `hs_v2_date_entered_<stage id>` (`hs_v2_date_exited_<stage id>`), its field type `Date picker`, and it is a calculated HubSpot property (no edit). HubSpot keeps them for every stage it knows. A stage without them (a pipeline created by an integration, say) would give that stage no times: write down which.

**Browser:** the same list (Deal properties). Look for a deal property of field type `Dropdown select` that holds the reasons a deal is lost; the field type filter narrows the list. A property of the same meaning as single-line or multi-line text does not count: the CMA refuses free text (Decision log, 20 October 2026).

Expected: one such property, or none. Open it and write down its internal name (shown in the property's details) and its options' labels. The data-quality flags in step 7 go on the options that say the lead was never a lead (KPIs 5 names Garbage, Duplicate, Wrong Phone and Accidentally Signed Up).

**Browser:** Settings → Properties → Ticket properties. Look for a ticket property of field type `Dropdown select` that holds the cancellation reason.

Expected: one such property, or none. Write down its internal name. Write down also which ticket pipeline (and, if any, which category value) holds the cancellation requests: that is the kind's rule in step 7, with Arno (Open decisions).

**Where none exists:** Funnel's lost-reasons section and Cancellations' reason column stay empty until Kira or Joshua create one (Open decisions). Nothing else in this runbook waits for it: carry on, and leave out the matching item in steps 7 and 15.

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

## 7. Dev: Sources settings

**Browser:** dev's Workspace → Configuration → Sources → the HubSpot connection.

1. **Stage outcomes**, column **Read times**: every stage of the counted pipelines ticked with `Default`; the uncounted pipelines' stages unticked. Untick a stage whose times say nothing (step 1's notes); it then shows `Set here`.
2. **Reasons → Deals: lost reason**: type the internal name of the deal property you wrote down in step 1 (the `Dropdown select` property holding the lost reasons) and **Save property**. The state reads `Not checked yet`.
3. **Reasons → Tickets: reason**: the internal name of the ticket property from step 1 (the `Dropdown select` property holding the cancellation reason), **Save property**.

Where none exists, Funnel's lost-reasons section and Cancellations' reason column stay empty until Kira or Joshua create one; nothing else in this runbook waits for it.

**Terminal** (two minutes later: the sweep has read the mapped definitions)
```bash
gcloud logging read 'resource.type="cloud_run_job" AND resource.labels.job_name="ingest-sweep" AND (jsonPayload.message="hubspot reason properties" OR jsonPayload.message="reason property not read")' --project=p4a-cma-dev --freshness=10m --limit=5 --format='value(jsonPayload.message,jsonPayload.code,jsonPayload.types)'
```
Expected: `hubspot reason properties` with `deal:enumeration` and `ticket:enumeration` (only the record types you mapped). `reason property not read` with a code instead: send me the line; the sweep reads the definition again on its next run. The read needs no scope beyond the app's own (`hubspot/README.md`, Scopes).

**Browser:** reload the connection's page.

Expected: each mapped reason `Dropdown` with its options listed (labels and values from HubSpot). Under **Deals: lost reason**, tick **Never a lead** on the data-quality options you noted in step 1. A text property instead shows `Refused` with the reason: map the `Dropdown select` property from step 1.

4. **Record kind rules** need a kind first. **Browser:** Configuration → Sources (the list) → **Record kinds** → **Add kind** (K): key `cancellation`, label `Cancellation request`, record type Tickets. Save. Then, on the HubSpot connection's page, **Record kind rules → Add rule** (R): the kind, the pipeline from step 1 (and the category value, if Arno names one). Save.
5. **Browser:** the Sources list → **Cancellation requests**: choose `Cancellation request`.

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
Expected: `deal | <the deal property from step 1> | enumeration | t` and `ticket | <the ticket property from step 1> | enumeration | t`, a row only for a property you mapped; the options per record type, with your data-quality flags on deals; `cancellation | ticket | active | 1 | t`; the stages reading times out of the deal stages.

## 8. Dev: the backfill with `--again`

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
gcloud run jobs execute ingest-backfill --project=p4a-cma-dev --region=europe-west4 --wait --args=--connection,<conn>,--object,deal,ticket,--again
```
Expected: `Execution [ingest-backfill-…] has successfully completed.` A failed or paused execution runs again with the same arguments: it continues where it stopped.

**Terminal** (the run's log line: counts and requests per endpoint)
```bash
gcloud logging read 'resource.type="cloud_run_job" AND resource.labels.job_name="ingest-backfill" AND jsonPayload.message:"backfill"' --project=p4a-cma-dev --freshness=1h --limit=4 --format=json | grep -E '"(message|object|fetched|written|apiCalls|POST [^"]*|GET [^"]*)"' | head -30
```
Expected: one `backfill` line per object (`deal`, `ticket`) with `fetched` above 0, `apiCalls` near the estimate, the endpoints with their counts, `daily` with HubSpot's remaining requests; `backfill paused` means the daily floor stopped it (run the same command later).

**Studio (cma-dev-pg)** (read only: what it filled; counts only)
```sql
set role cma_owner;
select (select count(distinct (rs.connection_id, rs.source_id)) from cma.crm_record_stage rs join cma.tenant t on t.id = rs.tenant_id where t.slug = 'pulse4all-subscriptions') as deals_with_stage_times,
       (select count(*) from cma.crm_record_stage rs join cma.tenant t on t.id = rs.tenant_id where t.slug = 'pulse4all-subscriptions') as stage_times,
       (select count(*) from cma.crm_record r join cma.tenant t on t.id = r.tenant_id where t.slug = 'pulse4all-subscriptions' and r.record_type = 'deal' and r.reason is not null) as deals_with_reason,
       (select count(*) from cma.crm_record r join cma.tenant t on t.id = r.tenant_id where t.slug = 'pulse4all-subscriptions' and r.record_type = 'ticket' and r.reason is not null) as tickets_with_reason;
select stream, status, counts, error from cma.sync_run where job = 'backfill' order by started_at desc limit 2;
reset role;
```
Expected: most deals with stage times; the deals with a lost reason and the tickets with a cancellation reason; both runs `succeeded`, no error.

**Browser:** dev's Workspace → Reports → Funnel and Reports → Cancellations, This month. Expected: figures (dev's data), no error; Deals per person under the lost reasons for the manager.

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

## 15. Prod: Sources settings

**Browser:** prod's Workspace (`martin@pulse4all.com`) → Configuration → Sources → the HubSpot connection: step 7's items 1 to 3 (items 2 and 3 for the properties step 1 found), the sweep's log line (with `--project=p4a-cma-prod`), the data-quality flags, and items 4 and 5 once Arno has named the rule (Open decisions; until then Reports → Cancellations says no kind is chosen). Then step 7's Studio block on **cma-prod-pg**.

Expected: as in dev.

## 16. Prod: the backfill with `--again`

Step 8 on prod: the count block on **cma-prod-pg**, then
```bash
gcloud run jobs execute ingest-backfill --project=p4a-cma-prod --region=europe-west4 --wait --args=--connection,<conn>,--object,deal,ticket,--again
```
then the log line with `--project=p4a-cma-prod` and the filled block on **cma-prod-pg**.

Expected: as in dev, with prod's counts: about four requests per 100 records, `backfill paused` if the daily floor is reached (the same command continues the next day). Send me the two `backfill` log lines' counts and `apiCalls`, and the filled block's row.

## 17. Prod: the hand checks and the request log

**Browser** (as `martin@pulse4all.com`), each with what you should see:
- Reports → Funnel, This month: six tiles with their changes; Per stage with each lead pipeline's stages, the bars and the table (a stage switched off says `Times not read for this stage`); Per pipeline with `Attempts per deal` opening that pipeline's deals; Lost reasons with four tiles, the reasons as bars (none while no deal reason property is mapped: the notice says so), `No reason` below them, Never a lead with the flagged reasons, per market and per source, per week, the lost deals without a reason with their links (each opens the deal in HubSpot); no Deals per person (off in prod).
- G switches week and day; K, P and S filter; X downloads the stages file.
- Reports → Cancellations, This month: four tiles, per market, reasons, per week and market, the newest requests with their links; without a kind, the notice with the link to Sources.
- Configuration → Sources: the Read times column, the Reasons card (`Dropdown` for each property mapped), the record kind rules; the list's Record kinds with `Counted as cancellations`.

**Terminal** (the request log of the two pages since the merge)
```bash
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="cma-web" AND (jsonPayload.route="/reports/funnel" OR jsonPayload.route="/reports/cancellations")' --project=p4a-cma-prod --freshness=2h --limit=10 --format='value(jsonPayload.route,jsonPayload.status,jsonPayload.totalMs,jsonPayload.dbMs,jsonPayload.tx)'
```
Expected: `200`, `totalMs` around a second at most, `dbMs` under step 12's sums, `tx` 4 for the Funnel (3 for a reader without deals per person) and 2 for Cancellations. Send me the lines; they go into the record of the run (`records/`, written down from your report).
