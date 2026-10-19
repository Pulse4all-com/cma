# Morning runbook, N19-A: email reports, first orders, Campaign monitoring, callbacks kept (0008t to 0008w)

Labels: **Browser**, **Terminal** (Martin's own Linux terminal, Chromebook Linux or his Linux machine, in `~/cma` unless stated; a step against prod, `p4a-cma-prod` or `cma-prod-pg`, from the Chromebook only), **Studio** (the instance named), **File** (a repository path). SQL and shell never share a block. Through the Auth Proxy the terminal runs only `db/` scripts and the data map's schema snapshot, whose output is schema, check rows, counts and ids; every query that reads rows runs in Studio (README, Where a command runs). Every step ends with what you should see. Claude Code's local outputs are in `local-records/` (its `README.md` lists them).

**What changes** (README, Data model: email reports, first orders, journeys, callbacks kept; Decision log, 18 October 2026):
- **0008t** (`82`, `83`): the mailboxes (an inbox's channel accounts) with label, counted and market; account refs on emails and conversations; an engagement's origin, with inbox copies and automations named by connection settings; the setting `reports.per_person`; the email reports' reads. Web: Reports → Email and Email per agent, the Sources email section.
- **0008u** (`84`, `85`): the order pipeline switch, a deal stage's outcome (from the source's probability, or set by a person), a contact's creation time in the source, the five `attribution.*` settings, the first orders and their reads. Web: Reports → First orders and Orders per person, the Sources order pipeline and stage outcomes.
- **0008v** (`86`, `87`): journeys as configuration; `02` seeds Pulse4all Subscriptions' three. Web: the rail group Campaigns with Campaign monitoring.
- **0008w** (`88`, `89`): callbacks kept. Web: the Dashboard's Callbacks kept tile, the weeks and the per-person table on Reports → Follow-up.
- Ingest: the mailbox catalog, a message's and a thread's mailbox, an engagement's origin (a re-read fills the engagements stored without one), a contact's `createdAt`, a deal stage's outcome from its probability. Nothing is written to HubSpot.

**Order matters:**
- The four migrations run in dev and prod **before** the merge: the merge builds and deploys prod's web app, whose new pages and the Dashboard read the new functions. Merged first, those pages answer an error until the migrations run.
- The migrations are safe under the ingest image that runs now: every changed ingest function takes the new keys as optional and keeps what it stores when a read leaves them out.
- The new ingest image goes to dev from this branch (step 3, `--allow-branch`) and to prod only after the merge **and only after N19-B is live in prod** (HubSpot API budget, backlog CMA-069). Until prod's re-reads have run, prod's figures that need them are provisional: Email counts an inbox copy twice where the engagement holds no origin yet, per mailbox shows "No mailbox" for older conversations, First orders sees no known contact (no creation time yet), and a stage's outcome stays empty until the new image reads the pipelines (step 5 sets the order pipeline's won stage by hand, so First orders works from the merge).
- `reports.per_person`: `02` sets `email` for Pulse4all Subscriptions (Yordi agreed, Decision log, 18 October 2026); dev gets `email,orders` by hand in step 2; prod never gets `orders` in this runbook.
- The data map: `verify:datamap` fails on this branch until step 4 refreshes `docs/datamap/schema.json` from dev after the migrations ran there; that is expected (CLAUDE.md, Database).
- Scripts that have run in prod: none changes. `69_verify_email_activity.sql` was amended in place (it runs in dev only; its view checks accept the columns 0008t and 0008u add at the end of 0008m's views).
- N19-B (the HubSpot polling change, no migrations) may merge first: this branch merged `origin/main` before the pull request opened; if `main` moved after that, GitHub shows it and the merge in step 6 is a squash of both.

| Step | What | Elapsed |
|---|---|---|
| 0 | Review the pull request, build it, run the ingest checks | 15 min |
| 1 | Dev: the four migrations twice, `02`, the verifies normal and provoked, the earlier verifies | 15 min |
| 2 | Dev: the configuration (email origins, the order pipeline, the stage outcomes, `reports.per_person`) | 10 min |
| 3 | Dev: the ingest image from the branch, the re-reads, read-only counts | 30 min (the pipelines catalog up to an hour) |
| 4 | The data map: snapshot from dev, rebuild, push | 10 min |
| 5 | Prod: the four migrations twice, `02`, the configuration without `orders`, read-only checks | 20 min |
| 6 | Merge, watch the prod build, hand checks in prod | 20 min |
| 7 | Prod after N19-B is live: the ingest image and the re-reads | 30 min |

---

## Helpers

The terminal is set up as `docs/RUNBOOK.md`, Setup (once per machine), step 8: the helpers `cma_db` and `run_migration` in `~/.cma_helpers.sh`. This runbook uses `cma_db` and adds none.

**Terminal**
```bash
cd ~/cma && node -v && bash -ic 'type -t cma_db run_migration'
```
Expected: `v22.…`, then `function` twice. Anything else: run `docs/RUNBOOK.md`, Setup, step 8 first.

**The Studio context block** (on `cma-dev-pg` in dev, on `cma-prod-pg` in prod; tenant `pulse4all-subscriptions`) is one Run, as in `docs/b17d-forms/MORNING_RUNBOOK.md`: the blocks below that call a configuration function run "after the context block": these lines pasted above the statements, in the same Run, with `reset role;` at the end. `<your user>` is `martin@pulse4all.com` in prod and `admin@example.com` in dev.
```sql
set role cma_owner;
select set_config('app.tenant_id', (select t.id::text from cma.tenant t where t.slug = 'pulse4all-subscriptions'), false),
       set_config('app.user_id', (select u.id::text from cma.app_user u join cma.tenant t on t.id = u.tenant_id
                                  where t.slug = 'pulse4all-subscriptions' and u.email = '<your user>'), false),
       set_config('app.actor_label', 'studio:martin', false);
set role cma_app;
```
Expected, above the statements' own results: one row of three values, the tenant's id, the user's id and `studio:martin`. An empty value: stop, the configuration calls would fail. Every other Studio block reads as the owner and stands alone.

## 0. Review the pull request, build it, run the ingest checks

**Browser:** GitHub → Pulse4all-com/cma → Pull requests → "N19-A". Read the description and the diff.

Expected: in `db/` the new `82` to `89`, `02_seed_pulse4all.sql` (two blocks added: `reports.per_person`, the journeys), `03_seed_dev_test_data.sql` (`reports.per_person`) and `69_verify_email_activity.sql` (dev-only verify, amended); changes under `web/`, `ingest/`, `docs/` and `README.md`; none under `cloudbuild.yaml`, `hubspot/` or `records/`.

**Terminal** (the pull request's number from the page)
```bash
cd ~/cma && gh pr checkout <number> && cd web && npm ci --no-audit --no-fund 2>&1 | tail -1 && npm run build 2>&1 | grep -E "reports/(email|first-orders|orders-per-person|callbacks-kept)|campaigns|journeys|sources/\[id\]/(stages|mailboxes)"; echo "build exit: ${PIPESTATUS[0]}"; cd ~/cma
```
Expected: `found 0 vulnerabilities` (or the known advisories of README, Open decisions), then the routes `/api/v1/configuration/sources/[id]/mailboxes`, `…/stages`, `/api/v1/journeys`, `/api/v1/journeys/[code]`, `/api/v1/reports/callbacks-kept`, `…/callbacks-kept/by-owner`, `/api/v1/reports/email`, `/api/v1/reports/email-per-agent`, `/api/v1/reports/first-orders`, `…/first-orders/export`, `/api/v1/reports/orders-per-person`, `/campaigns`, `/campaigns/[code]`, `/reports/email`, `/reports/email-per-agent`, `/reports/first-orders`, `/reports/orders-per-person`, then `build exit: 0`.

**Terminal**
```bash
cd ~/cma/ingest && npm ci --no-audit --no-fund 2>&1 | tail -1 && npm run lint && npm test 2>&1 | grep -E "^ALL|FAILED"; cd ~/cma
```
Expected: `found 0 vulnerabilities`, no lint output after the `eslint` line, fourteen lines `ALL n PASS` (18, 53, 26, 48, 20, 49, 30, 17, 51, 27, 21, 20, 85, 21; the second is `verify/mapping.mjs` with the contact's creation time and the stage outcome, the thirteenth `verify/email-mapping.mjs` with the mailboxes, the origin and the re-read), no `FAILED`. **Do not merge yet.**

**Studio (cma-dev-pg)** and **Studio (cma-prod-pg)** (read only)
```sql
set role cma_owner;
select version, applied_at from cma.schema_migration where version >= '0008s' order by 1;
reset role;
```
Expected on both instances: `0008s` only. Without it, run `docs/RUNBOOK.md`, 7a first; with `0008t` or later, stop and tell me.

## 1. Dev: the four migrations, `02`, the verifies

**Terminal** (dev, on the pull request's branch): each migration twice, in order; the second run adds nothing.
```bash
cd ~/cma && rec=records/n19a-dev-$(date +%F) && mkdir -p "$rec" && cma_db dev
for m in 82_email_reports 84_first_orders 86_journeys 88_callbacks_kept; do
  psql "$PGCONN" -v ON_ERROR_STOP=1 -f "db/$m.sql" > "$rec/${m%%_*}.txt" 2>&1; echo "$m: $(tail -3 "$rec/${m%%_*}.txt" | tr '\n' ' ')"
  psql "$PGCONN" -v ON_ERROR_STOP=1 -f "db/$m.sql" > "$rec/${m%%_*}-rerun.txt" 2>&1; echo "$m again: $(tail -3 "$rec/${m%%_*}-rerun.txt" | tr '\n' ' ')"
done
```
Expected: `connected to cma as martin@pulse4all.com`; then per migration `INSERT 0 1 COMMIT RESET` and, again, `INSERT 0 0 COMMIT RESET`. An `ERROR` line or another first line: stop and send me the file's last ten lines (`tail "$rec/82.txt"`, and so on). `84` stops with `addition 0008t (82_email_reports.sql) must run before 0008u` when `82` did not run, and so on down the chain.

**Terminal** (dev): the Pulse4all seed, after `86` (the journeys and `reports.per_person`)
```bash
cd ~/cma && psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/02_seed_pulse4all.sql > "$rec/02-after-86.txt" 2>&1; echo "exit $?"; grep -E "ERROR|NOTICE" "$rec/02-after-86.txt"
```
Expected: `exit 0` and no line after it (no notice: every catalog exists).

**Terminal** (dev): the four verifies, normal and provoked, then the earlier ones
```bash
cd ~/cma && for v in 83_verify_email_reports 85_verify_first_orders 87_verify_journeys 89_verify_callbacks_kept; do
  psql "$PGCONN" -v ON_ERROR_STOP=1 -f "db/$v.sql" > "$rec/${v%%_*}.txt" 2>&1; echo "$v: $(grep -E 'verdict' "$rec/${v%%_*}.txt" | tr -s ' ')"
  sed "s/select set_config('verify.provoke', 'false', false);/select set_config('verify.provoke', 'true', false);/" "db/$v.sql" > /tmp/provoke.sql
  psql "$PGCONN" -v ON_ERROR_STOP=0 -f /tmp/provoke.sql > "$rec/${v%%_*}-provoked.txt" 2>&1; echo "  provoked: $(grep -E 'verdict' "$rec/${v%%_*}-provoked.txt" | tr -s ' ')"
done
for f in 41_verify_lead_metrics 69_verify_email_activity 73_verify_follow_up 75_verify_forms_reporting 81_verify_follow_up_snapshot; do
  psql "$PGCONN" -v ON_ERROR_STOP=1 -f "db/$f.sql" > "$rec/${f%%_*}-rerun.txt" 2>&1; echo "$f: $(grep -cE '\| PASS' "$rec/${f%%_*}-rerun.txt") PASS rows"
done
```
Expected:
- `83_verify_email_reports:  verdict | PASS | 26 PASS, 0 FAIL`, provoked ` verdict | PROVOKED, NOT A PASS | 0 PASS, 26 FAIL`;
- `85_verify_first_orders:` `26 PASS, 0 FAIL`, provoked `0 PASS, 26 FAIL`;
- `87_verify_journeys:` `16 PASS, 0 FAIL`, provoked `0 PASS, 16 FAIL`;
- `89_verify_callbacks_kept:` `15 PASS, 0 FAIL`, provoked `0 PASS, 15 FAIL`;
- `41_verify_lead_metrics: 2 PASS rows`, `69_verify_email_activity: 30 PASS rows`, `73_verify_follow_up: 22 PASS rows`, `75_verify_forms_reporting: 25 PASS rows`, `81_verify_follow_up_snapshot: 20 PASS rows` (each verify's checks and its verdict, as before).

A `REFUSED` verdict means the session is not on dev: check `cma_db dev`. Any `FAIL` row: send me its line (`grep FAIL "$rec/83.txt"`, and so on).

**Studio (cma-dev-pg)** (read only: the additions, the journeys and the setting `02` wrote; codes and counts)
```sql
set role cma_owner;
select version, applied_by from cma.schema_migration where version in ('0008t', '0008u', '0008v', '0008w') order by 1;
select j.code, j.status, j.market, cardinality(j.prerequisites) as prerequisites from cma.journey j join cma.tenant t on t.id = j.tenant_id
where t.slug = 'pulse4all-subscriptions' order by j.sort_order;
select t.slug, s.value from cma.tenant_setting s join cma.tenant t on t.id = s.tenant_id where s.key = 'reports.per_person' order by 1;
reset role;
```
Expected: four rows with your login; `fca-uk-consumers | placeholder | GB | 7` (the market empty when dev's catalog has no GB), `opc | placeholder | | 1`, `exchange | placeholder | | 1`; `pulse4all-subscriptions | email`.

## 2. Dev: the configuration

**Studio (cma-dev-pg)** after the context block: the HubSpot connection's origin property and the inbox-copy origins (kept with its other settings), and `reports.per_person` with both keys (dev only)
```sql
select cma.set_connection_settings(c.id, c.settings || '{"email_origin_property": "hs_engagement_source", "email_inbox_copy_origins": "CONVERSATIONS"}'::jsonb)
from cma.integration_connection c where c.adapter = 'hubspot' and c.status = 'active';
select cma.set_tenant_setting('reports.per_person', 'email,orders');
reset role;
```
Expected: one empty row per active HubSpot connection of the tenant (one), then one empty row. A `CMA04` on the first: the settings would pass 4 kB or hold a forbidden key; send me the message.

The Order pipeline column and the stage outcomes are on Configuration → Sources once this branch's web runs (after step 6); until then the functions do it. **Studio (cma-dev-pg)** (read only: the HubSpot connection and its deal pipelines; ids and labels are configuration, not customer data)
```sql
set role cma_owner;
select c.id as connection, p.source_pipeline_id, p.label, p.is_counted, p.is_lead, p.is_order
from cma.connection_pipeline p join cma.integration_connection c on c.tenant_id = p.tenant_id and c.id = p.connection_id
join cma.tenant t on t.id = p.tenant_id
where t.slug = 'pulse4all-subscriptions' and c.adapter = 'hubspot' and p.record_type = 'deal' and p.status = 'active' order by p.label;
reset role;
```
Expected: the deal pipelines with `is_order` false. Note the connection as `<conn>` and the Self Serve pipeline's id as `<self serve>`. It must be counted (`is_counted` true): an uncounted pipeline's deals are no orders.

Dev's test account has no Self Serve, so dev uses Sales test (`4209185980`), the pipeline that holds the test deals: in dev, `<self serve>` is `4209185980` here and in step 3c; prod keeps Self Serve (step 5).

**Studio (cma-dev-pg)** after the context block
```sql
select cma.set_pipeline_order('<conn>', 'deal', '<self serve>', true);
reset role;
```
Expected: one empty row. `CMA04` means the id is a ticket pipeline's.

**Studio (cma-dev-pg)** (read only: the order pipeline's stages and their outcomes)
```sql
set role cma_owner;
select s.source_stage_id, s.label as stage, s.is_closed, s.outcome, s.outcome_source
from cma.connection_stage s join cma.tenant t on t.id = s.tenant_id
where t.slug = 'pulse4all-subscriptions' and s.record_type = 'deal' and s.source_pipeline_id = '<self serve>' order by s.display_order;
reset role;
```
Expected: its stages. Before step 3's image has read the pipelines, `outcome` is empty on every stage (the image that runs now does not send it); step 3c reads them again.

## 3. Dev: the ingest image from the branch, the re-reads

**3a. The image and the jobs.** **Terminal** (from the Chromebook, on the pull request's branch, no uncommitted change under `ingest/`)
```bash
cd ~/cma && git status --short ingest/ docs/ingest/deploy.sh && bash docs/ingest/deploy.sh dev --allow-branch && bash docs/ingest/deploy.sh dev --jobs --allow-branch
```
Expected: no `git status` line; the warning naming the branch and the image tag; the build ending `SUCCESS` (or `image … exists …; no build`), the service's `health: {"ok":true,"version":"<sha>"}`; then the jobs and their schedules as before. If N19-B has deployed its own branch image to dev meanwhile, this replaces it in dev until main carries both: say so to the N19-B session.

**3b. The re-reads**, from `email.start_date` for the email objects and the held contacts again. **Terminal** (`<conn>`: the HubSpot connection's id, `select c.id from cma.integration_connection c join cma.tenant t on t.id = c.tenant_id where t.slug = 'pulse4all-subscriptions' and c.adapter = 'hubspot';` in Studio as the owner)
```bash
for o in contact crm_email inbox_thread; do gcloud run jobs execute ingest-backfill --project=p4a-cma-dev --region=europe-west4 --wait --args=--connection,<conn>,--object,$o,--again; done
```
`--again` because all three were backfilled before from the same start, and a finished backfill with the same start reads nothing (it fetched 0 in dev on 19 October 2026); `--again` walks it from that start once more, never before it.

Expected: three times `Execution [ingest-backfill-…] has successfully completed.` A failed execution is run again with the same arguments: it continues where it stopped. (Dev ran this step on 19 October 2026 with `--from,2026-09-30` instead, before the image knew `--again`: nothing to repeat there; `docs/night-2026-10-19/local-records/README.md`.)

**Studio (cma-dev-pg)** (read only: the runs and what they filled; codes and counts only)
```sql
set role cma_owner;
select stream, status, counts, error from cma.sync_run where job = 'backfill' order by started_at desc limit 3;
select origin, count(*) from cma.email_message where source_kind = 'crm_email' group by 1 order by 2 desc;
select (select count(*) from cma.connection_inbox_account) as mailboxes,
       (select count(*) from cma.email_thread where account_ref is not null) as threads_with_mailbox,
       (select count(*) from cma.email_thread) as threads,
       (select count(*) from cma.crm_contact where source_created_at is not null) as contacts_with_created,
       (select count(*) from cma.crm_contact where source_deleted_at is null) as contacts;
reset role;
```
Expected:
- `inbox_thread`, `crm_email`, `contact`, each `succeeded`, their counts (fetched, written, skipped) with `fetched` above 0, no error (`fetched` 0 means the run found its finished backfill: `--again` was left out);
- the origin codes with their counts: `CONVERSATIONS` (the inbox copies, left out of the reports), `CRM_UI` and the others HubSpot gives; an empty origin only on engagements HubSpot gives none;
- the mailboxes the catalog brought (the poll refreshes the catalog hourly, so 0 until the new image's first refresh), most threads with a mailbox, most contacts with a creation time.

**3c. The stage outcomes**, once the new image has read the pipelines (the catalog refreshes at most hourly). **Studio (cma-dev-pg)**: step 2's stages block again.

Expected: the won stage of Self Serve `won | source`, a closed lost one `lost | source`, open ones empty. A stage whose outcome is wrong (a HubSpot stage whose probability is not 1.0 although it means won): after the context block `select cma.set_stage_outcome('<conn>', 'deal', '<self serve>', '<stage id>', 'won');` (or, after step 6, Configuration → Sources → Stage outcomes); it is then the person's and kept over every later read.

**3d. The pages in dev** wait for the dev web image of step 6 (the web deploys with the merge).

## 4. The data map: snapshot from dev, rebuild, push

**Terminal** (`~/cma`, still on the pull request's branch)
```bash
cd ~/cma && cma_db dev && psql "$PGCONN" -X -qAt -v ON_ERROR_STOP=1 -f tools/datamap/schema.sql > docs/datamap/schema.json && grep -o '"latest_migration" : "[^"]*"' docs/datamap/schema.json
```
Expected: `connected to cma as martin@pulse4all.com`, then `"latest_migration" : "0008w"`.

**Terminal** (`~/cma`)
```bash
node tools/datamap/build.mjs && node tools/datamap/build.mjs --check
```
Expected: `datamap: wrote docs/datamap/index.html (81 tables, 110 views)`, then `datamap: 81 tables, 110 views, all described; index.html current`: two tables more than `main`'s snapshot at 0008s (79 tables, 104 views: `connection_inbox_account`, `journey`) and six views more (their two reader views, `email_waiting`, `email_not_responding`, `first_orders`, `callbacks_kept`); a local snapshot at 0008w gave exactly these. A problem list instead: send it to me.

**Terminal** (`~/cma`)
```bash
git add docs/datamap && git commit -m "Data map: snapshot after 0008w" && git push
```
Expected: the push names this pull request's branch.

## 5. Prod: the migrations, `02`, the configuration

**Terminal** (from the Chromebook; point-in-time recovery on, as before every prod migration)
```bash
gcloud sql instances describe cma-prod-pg --project=p4a-cma-prod --format="value(settings.backupConfiguration.pointInTimeRecoveryEnabled,settings.backupConfiguration.transactionLogRetentionDays)"
```
Expected: `True	7`.

`83`, `85`, `87`, `89`, `69`, `73`, `75` and `81` refuse prod (they write throwaway tenants and run in dev only), so prod runs each migration twice, `02` and `41`, then read-only checks. `82` fills `email_message.origin` once for the engagements whose raw payload holds it (one update each, audited); the others add columns, tables and functions in one transaction each; the ingest's writes wait for them a moment and carry on.

**Terminal** (from the Chromebook; `db/` scripts only)
```bash
cd ~/cma && rec=records/n19a-prod-$(date +%F) && mkdir -p "$rec" && cma_db prod
for m in 82_email_reports 84_first_orders 86_journeys 88_callbacks_kept; do
  psql "$PGCONN" -v ON_ERROR_STOP=1 -f "db/$m.sql" > "$rec/${m%%_*}.txt" 2>&1; echo "$m: $(tail -3 "$rec/${m%%_*}.txt" | tr '\n' ' ')"
  psql "$PGCONN" -v ON_ERROR_STOP=1 -f "db/$m.sql" > "$rec/${m%%_*}-rerun.txt" 2>&1; echo "$m again: $(tail -3 "$rec/${m%%_*}-rerun.txt" | tr '\n' ' ')"
done
psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/02_seed_pulse4all.sql > "$rec/02-after-86.txt" 2>&1; echo "02 exit $?"
psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/41_verify_lead_metrics.sql > "$rec/41-rerun.txt" 2>&1; echo "41: $(grep -cE '\| PASS' "$rec/41-rerun.txt") PASS rows"
```
Expected: `connected to cma as martin@pulse4all.com`; per migration `INSERT 0 1 COMMIT RESET`, then `INSERT 0 0 COMMIT RESET`; `02 exit 0`; `41: 2 PASS rows`.

**Studio (cma-prod-pg)** (read only: the additions, the per-person setting, the journeys)
```sql
set role cma_owner;
select version, applied_at, applied_by from cma.schema_migration where version in ('0008t', '0008u', '0008v', '0008w') order by 1;
select t.slug, s.value from cma.tenant_setting s join cma.tenant t on t.id = s.tenant_id where s.key = 'reports.per_person' order by 1;
select j.code, j.status, j.market, cardinality(j.prerequisites) as prerequisites from cma.journey j join cma.tenant t on t.id = j.tenant_id
where t.slug = 'pulse4all-subscriptions' order by j.sort_order;
reset role;
```
Expected: four rows with today's time and your login; **`pulse4all-subscriptions | email`** and no row for `pulse4all-invest` (its default, empty: no per-person page); `fca-uk-consumers | placeholder | GB | 7`, `opc | placeholder | | 1`, `exchange | placeholder | | 1`.

**Studio (cma-prod-pg)** after the context block: step 2's settings on the HubSpot connection, **without** `reports.per_person`
```sql
select cma.set_connection_settings(c.id, c.settings || '{"email_origin_property": "hs_engagement_source", "email_inbox_copy_origins": "CONVERSATIONS"}'::jsonb)
from cma.integration_connection c where c.adapter = 'hubspot' and c.status = 'active';
reset role;
```
Expected: one empty row.

**Studio (cma-prod-pg)** (read only: Pulse4all's Self Serve pipeline and its stages, as in step 2)
```sql
set role cma_owner;
select c.id as connection, p.source_pipeline_id, p.label, p.is_counted, s.source_stage_id, s.label as stage, s.is_closed, s.outcome
from cma.connection_pipeline p join cma.integration_connection c on c.tenant_id = p.tenant_id and c.id = p.connection_id
join cma.connection_stage s on s.tenant_id = p.tenant_id and s.connection_id = p.connection_id and s.record_type = p.record_type
 and s.source_pipeline_id = p.source_pipeline_id
join cma.tenant t on t.id = p.tenant_id
where t.slug = 'pulse4all-subscriptions' and c.adapter = 'hubspot' and p.record_type = 'deal' and p.status = 'active' order by p.label, s.display_order;
reset role;
```
Expected: the deal pipelines with their stages, `outcome` empty everywhere. Note `<conn>`, the Self Serve pipeline as `<self serve>` (counted) and the stage its deals are won in (closed won on creation) as `<won stage>`.

**Studio (cma-prod-pg)** after the context block: the order pipeline, and the won stage by hand (needed until step 7's image reads the outcomes itself; your choice stays after that)
```sql
select cma.set_pipeline_order('<conn>', 'deal', '<self serve>', true);
select cma.set_stage_outcome('<conn>', 'deal', '<self serve>', '<won stage>', 'won');
reset role;
```
Expected: two empty rows.

**Studio (cma-prod-pg)** (read only)
```sql
set role cma_owner;
select p.source_pipeline_id, p.label, p.is_counted, p.is_order, s.label as stage, s.outcome, s.outcome_source
from cma.connection_pipeline p join cma.connection_stage s using (tenant_id, connection_id, record_type, source_pipeline_id)
join cma.tenant t on t.id = p.tenant_id
where t.slug = 'pulse4all-subscriptions' and p.record_type = 'deal' and p.is_order order by s.display_order;
select key, value from cma.tenant_setting s join cma.tenant t on t.id = s.tenant_id where t.slug = 'pulse4all-subscriptions' and s.key like 'attribution.%';
reset role;
```
Expected: Self Serve `t | t`, its won stage `won | person`; no `attribution.*` row (the defaults hold until Kira changes them on Configuration).

## 6. Merge, watch the prod build, hand checks

**Terminal** (from the Chromebook)
```bash
cd ~/cma && gh pr merge <number> --squash --delete-branch && git switch main -q && git pull -q && git log --oneline -1
gcloud builds list --project=p4a-cma-prod --region=europe-west4 --limit=1 --format="table(status,substitutions.SHORT_SHA,createTime.date('%H:%M'))"
```
Expected: the merge commit; then a build for its short SHA, `QUEUED` or `WORKING`, then `SUCCESS` (RUNBOOK section 3; the build appears 2 to 4 minutes after the merge). No build for the short SHA 4 minutes after the merge: `gcloud builds triggers run cma-web-main --project=p4a-cma-prod --region=europe-west4 --sha=$(git rev-parse HEAD)`.

**Browser** (prod, as yourself): Configuration → Sources → the HubSpot connection: the Pipelines card's Order pipeline column with Self Serve ticked, and Stage outcomes with Self Serve's won stage `Won`, "Set here".

**Browser** (prod, as yourself, a manager with `performance.team`):
1. Reports → **Email** (`/reports/email`, This month): five tiles, received per inbox and per mailbox, sent, the tables per inbox, mailbox, category and market, Waiting now and Not responding; no address anywhere. Expected: figures, not "No email connected". Until step 7 the per-mailbox figures put older conversations under "No mailbox".
2. Reports → **Email per agent** is in the rail and opens: per person by name, a row opens with Enter.
3. Reports → **Orders per person** is **not** in the rail, and `https://workspace.pulse4all.app/reports/orders-per-person` answers Not found.
4. Reports → **First orders** (This month): four tiles, call center and self-service columns, the bars per level, per market with amounts, the list with the deal links (opening HubSpot); "History from …" and "Phone matching from …" in Muted under the dates. With `intake.start_date` 1 October 2026 the history reads Wed 30 December 2026 (the 90-day window reaches past the data before it), so the deltas say "No history to compare yet". Until step 7 no contact counts as known.
5. **Campaigns** → Campaign monitoring: three cards (FCA · UK consumers with market GB and 7 prerequisites, OPC, Exchange), each "Placeholder"; FCA's page shows the Muted banner, seven dashed placeholders with the drill-down locked, and the seven prerequisites unticked; breadcrumbs Welcome › Campaigns › FCA · UK consumers.
6. Reports → **Dashboard**: the Intake row's seventh tile Callbacks kept (or "No callback type set" while no task type is marked a callback on Sources); Reports → **Follow-up** below the lists: Callbacks kept, per week (eight weeks) and per person.

Write down what differs and send it to me.

**Terminal** (dev web, RUNBOOK section 4 with the merge's short SHA; optional, for the same pages in dev with `email,orders`): Orders per person is then in dev's rail for the manager.

## 7. Prod after N19-B is live: the ingest image and the re-reads

Only when N19-B's image runs in prod (its runbook's last step) and its API budget allows (backlog CMA-069). **Terminal** (from the Chromebook, on `main`)
```bash
cd ~/cma && git switch main -q && git pull -q && git log -1 --format=%h -- ingest/ && bash docs/ingest/deploy.sh prod --front <host> && bash docs/ingest/deploy.sh prod --jobs
```
Expected: the image tag (the merge commit or later); the build `SUCCESS` (or the image exists), `health: {"ok":true,"version":"<sha>"}`; the jobs and their schedules as before. `<host>` as in `docs/ingest/PROD_RUNBOOK.md`.

**Terminal** (`<conn>`: prod's HubSpot connection id, from Studio as in step 3b)
```bash
for o in contact crm_email inbox_thread; do gcloud run jobs execute ingest-backfill --project=p4a-cma-prod --region=europe-west4 --wait --args=--connection,<conn>,--object,$o,--again; done
```
`--again` as in step 3b: where an earlier backfill of the object from the same start has finished, a run without it reads nothing.

Expected: three times `… has successfully completed.`

**Studio (cma-prod-pg)**: step 3b's read-only block and, an hour later, step 5's last block. Expected: the three runs `succeeded`, each with `fetched` above 0 in `counts`; the origin codes with `CONVERSATIONS` among them; most threads with a mailbox; most contacts with a creation time; the Self Serve won stage still `won | person`, the other stages `won`, `lost` or empty from the source.

**Browser** (prod): Configuration → Sources → the HubSpot connection → the email section: the mailboxes (an address-like name shows its id: label it); Reports → Email per mailbox: older conversations now under their mailbox.
