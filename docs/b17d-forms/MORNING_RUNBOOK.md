# Runbook, B17d: forms reporting (0008p)

Labels: **Browser**, **Terminal** (Martin's own Linux terminal, Chromebook Linux or his Linux machine, in `~/cma` unless stated; a step against prod, `p4a-cma-prod` or `cma-prod-pg`, from the Chromebook only), **Studio** (the instance named), **File** (a repository path). SQL and shell never share a block. Through the Auth Proxy the terminal runs only `db/` scripts and the data map's schema snapshot, whose output is schema, counts and ids; every query that reads rows runs in Studio (README, Where a command runs). Every step ends with what you should see. Claude Code's local outputs are in `local-records/` (its `README.md` lists them).

**What changes:** every form is polled apart from whether it counts in Intake, and Reports → Forms shows every polled form's submissions per form and market. Addition 0008p (`74`, `75`): `connection_form.is_polled` (existing forms polled exactly when they count), the tenant's form categories, each form's fields with their option values, kept answers of choice questions only (checked against the options), a form's market field and lead condition, the reads `cma.forms_report()`, `cma.forms_answers()` and `cma.forms_history_start()` (README, Data model: forms reporting; Decision log, 16 October 2026). The ingest's forms poll and backfill read every polled form, keep choice answers only and count the dropped ones; the backfill fills a stored submission's empty answers once. The web app: Reports → Forms (`/reports/forms`, `reports.view` or `performance.team`) with its file, and on Configuration → Sources a form's polled switch and category, and the form categories.

**Run:** in dev and prod on 17 October 2026 (`records/b17d-dev-2026-10-17`, `records/b17d-prod-2026-10-17`, written down from Martin's report). Corrected afterwards where that run went otherwise: the context block as one Run (Helpers), step 9's wait for the fields, 10b's and 10c's expected rows (the generic Quote Form has no market), 10c and 10d as a review read and then the same query calling the function, 10g's value from the field's options, the prefix pattern's single backslashes (10c), and 10c's market from the tenant's markets without a fixed list (README, Decision log, 17 October 2026).

**Order matters:**
- `Pulse4all-com/cma#142` (0008n and 0008o, `70` to `73`) is merged (`c7a3cab`) and has run in dev and prod (`records/0008n-dev-2026-10-16`, `records/0008n-prod-2026-10-16`, `records/0008o-dev-2026-10-16`, `records/0008o-prod-2026-10-16`); without 0008o `74` stops with `addition 0008o (72_follow_up.sql) must run before 0008p` and applies nothing.
- 0008p runs in dev and prod **before** the merge: the merge builds and deploys prod's web app, whose Forms page and Sources page read the functions of `74`. Merged first, Reports → Forms answers an error and a CRM connection's Sources page fails until `74` runs.
- `74` is safe under the ingest image that runs now: that image's forms poll writes the catalog without fields and the counted forms' submissions as before, and nothing reads `is_polled` until the new image runs. The new image needs 0008p (it reads `is_polled` and the fields), so it is deployed after the merge, dev first, then prod (steps 8 and 9).
- Kept fields, a market field and a lead condition are checked against the fields the source described. The new image's catalog refresh brings them at most an hour after it starts: wait for it (steps 8b and 9).
- The lead condition on the Contact forms changes Intake's form counts (existing customers no longer count as leads, from 1 October on): Kira hears the before and after figures of step 10 first (README, Open decisions).
- No seed change: `02` is untouched (it stays as `Pulse4all-com/cma#142` and `#140` leave it).
- The data map: `verify:datamap` fails on this branch until step 4 refreshes `docs/datamap/schema.json` from dev, after 0008p ran there; that is expected (CLAUDE.md, Database).
- No script that has run in prod changes in this pull request.

| Step | What | Elapsed |
|---|---|---|
| 1 | Review the pull request, build it, run the ingest checks | 15 min |
| 2 | 0008p in dev with its verify | 10 min |
| 3 | A read-only check in dev | 5 min |
| 4 | The data map: snapshot from dev, rebuild, push | 10 min |
| 5 | 0008p in prod, a read-only check | 10 min |
| 6 | Merge, watch the prod build | 10 min |
| 7 | The new web image on dev, the API verifier | 15 min |
| 8 | Dev: the ingest image and jobs, the configuration, a test form, the backfill | 40 min (the catalog refresh up to an hour) |
| 9 | Prod: the ingest jobs, the forms' fields | 10 min (the catalog refresh up to an hour) |
| 10 | Prod: categories, the 28 counted forms, the 22 support forms, kept fields, the backfill, Intake before and after the lead rule | 40 min |
| 11 | Prod: read-only counts | 5 min |
| 12 | The browser verifiers against a local mock server | 15 min |
| 13 | A hand check in prod | 10 min |

---

## Helpers

The terminal is set up as `docs/RUNBOOK.md`, Setup (once per machine), describes. Its step 8 writes the helpers `cma_db` (starts the Auth Proxy once and sets `PGCONN`) and `run_migration` (a migration and its verify, normal and provoked, into `records/`) to `~/.cma_helpers.sh`, sourced from `~/.bashrc`, so every terminal tab has them; this runbook uses them as they are there and adds none. A tab opened before that step sources the file with `. ~/.cma_helpers.sh`.

**Terminal**
```bash
cd ~/cma && node -v && bash -ic 'type -t cma_db run_migration'
```
Expected: `v22.…`, then `function` twice. Anything else: run `docs/RUNBOOK.md`, Setup, step 8 first.

**The Studio context block** (on `cma-dev-pg` in dev, on `cma-prod-pg` in prod; tenant `pulse4all-subscriptions`) is one Run: as the owner it sets the tenant, the user and the actor label through subselects, then switches to the app's role. Each Run in Studio is a fresh session (`docs/ingest/PROD_RUNBOOK.md`, The Studio context block), so the blocks that call a configuration function run "after the context block": these lines pasted above the statements, in the same Run, with `reset role;` at the end. `<your user>` is `martin@pulse4all.com` in prod and `admin@example.com` in dev (the dev seed's admin; Martin's login has no app user in dev).
```sql
set role cma_owner;
select set_config('app.tenant_id', (select t.id::text from cma.tenant t where t.slug = 'pulse4all-subscriptions'), false),
       set_config('app.user_id', (select u.id::text from cma.app_user u join cma.tenant t on t.id = u.tenant_id
                                  where t.slug = 'pulse4all-subscriptions' and u.email = '<your user>'), false),
       set_config('app.actor_label', 'studio:martin', false);
set role cma_app;
```
Expected, above the statements' own results: one row of three values, the tenant's id, the user's id and `studio:martin`. An empty value means the slug or the email matched nothing: stop, the configuration calls would fail. Every other Studio block reads as the owner and stands alone, `set role cma_owner;` … `reset role;`.

## 1. Review the pull request, build it, run the ingest checks

**Browser:** GitHub → Pulse4all-com/cma → Pull requests → "B17d: forms reporting (0008p)". Read the description and the diff.

Expected: in `db/` only the new `74_forms_reporting.sql` and `75_verify_forms_reporting.sql`; changes under `web/`, `ingest/`, `docs/` and `README.md`; none under `cloudbuild.yaml`, `hubspot/` or `records/`; no script that has run in prod changes.

**Terminal** (the pull request's number from the page)
```bash
cd ~/cma && gh pr checkout <number> && cd web && npm ci --no-audit --no-fund 2>&1 | tail -1 && npm run build 2>&1 | grep -E "forms|form-categories"; echo "build exit: ${PIPESTATUS[0]}"; cd ~/cma
```
Expected: `found 0 vulnerabilities` (or the five known high-severity advisories of README, Open decisions), then the lines `/api/v1/configuration/form-categories`, `/api/v1/configuration/sources/[id]/forms`, `/api/v1/reports/forms`, `/api/v1/reports/forms/answers`, `/api/v1/reports/forms/export` and `/reports/forms`, then `build exit: 0`.

**Terminal**
```bash
cd ~/cma/ingest && npm ci --no-audit --no-fund 2>&1 | tail -1 && npm run lint && npm test 2>&1 | grep -E "^ALL|FAILED"; cd ~/cma
```
Expected: `found 0 vulnerabilities`, no lint output after the `eslint` line, fourteen lines `ALL n PASS` (18, 48, 26, 48, 20, 49, 27, 17, 51, 21, 21, 20, 76, 10; the second is `verify/mapping.mjs` with `Pulse4all-com/cma#142`'s task checks, the fourth `verify/forms.mjs`, the last `verify/deploy-script.mjs` of `Pulse4all-com/cma#146`), no `FAILED`. **Do not merge yet.**

**Studio (cma-dev-pg)** and **Studio (cma-prod-pg)** (read only: #142's additions have run)
```sql
set role cma_owner;
select version, applied_at from cma.schema_migration where version in ('0008n', '0008o', '0008p') order by 1;
reset role;
```
Expected on both instances: `0008n` and `0008o`, no `0008p`. Without `0008o`, run #142's runbook first.

## 2. Addition 0008p in dev

**Terminal** (still on the pull request's branch; `71` and `73` are #142's verifies, on `main` since `c7a3cab` and on this branch since `main` was merged in)
```bash
run_migration dev 74_forms_reporting.sql 75_verify_forms_reporting.sql 0008p-dev-$(date +%F) 33_verify_intake_core.sql 35_verify_telephony.sql 41_verify_lead_metrics.sql 53_verify_sources_configuration.sql 69_verify_email_activity.sql 71_verify_crm_tasks.sql 73_verify_follow_up.sql
```
Expected: `connected to cma as martin@pulse4all.com`; the last lines of `74` are `INSERT 0 1`, `COMMIT`, `RESET` (no `ERROR`); `75` ends with `B19 a run's counts take dropped; another key is refused | PASS`, the verdict row `verdict | PASS | 24 PASS, 0 FAIL`, `(25 rows)`, `DROP FUNCTION` twice and `RESET`; `provoked FAIL lines: 25` (the 24 checks and the verdict's count) and the verdict `PROVOKED, NOT A PASS | 0 PASS, 24 FAIL`; `33_verify_intake_core.sql: 2 PASS rows`, `35_verify_telephony.sql: 2 PASS rows`, `41_verify_lead_metrics.sql: 2 PASS rows`, `53_verify_sources_configuration.sql: 17 PASS rows`, `69_verify_email_activity.sql: 30 PASS rows`, `71_verify_crm_tasks.sql: 21 PASS rows`, `73_verify_follow_up.sql: 22 PASS rows` (`main`'s `71` and `73` as merged with `Pulse4all-com/cma#142`: 20 and 21 checks plus the verdict, the same after `74`; a local run on 17 October 2026 at 0008p gave these counts). `53` gives 17 only once the one-off dev cleanup of `records/0008o-dev-2026-10-16/README.md` (Note: two leftover throwaway tenants in dev) has run; before it, `53_verify_sources_configuration.sql: 15 PASS rows`, because A4 counts `2 connection(s) without the kind their rows imply` (the two tenants an older `verify:email-flow` left) and the verdict fails. That A4 does not come from 0008p: run the cleanup, then `53` again (`psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/53_verify_sources_configuration.sql | grep -E "A4|verdict"`, expected A4 `PASS` and `16 PASS, 0 FAIL`). A `REFUSED` line means the session is not on dev: check `cma_db dev`. Any other `FAIL` row: send me its line.

**Terminal** (`74` again)
```bash
rec=records/0008p-dev-$(date +%F); psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/74_forms_reporting.sql > "$rec/74-rerun.txt" 2>&1; tail -3 "$rec/74-rerun.txt"
```
Expected: `INSERT 0 0`, `COMMIT`, `RESET`.

## 3. A read-only check in dev

**Studio (cma-dev-pg)** (the addition, the forms as the migration left them, the empty catalogs; ids, names and counts only)
```sql
set role cma_owner;
select version, applied_by from cma.schema_migration where version = '0008p';
select t.slug, f.is_counted, f.is_polled, count(*) as forms, count(f.category) as with_category, count(f.fields_refreshed_at) as described
from cma.connection_form f join cma.tenant t on t.id = f.tenant_id group by 1, 2, 3 order by 1, 2 desc, 3 desc;
select (select count(*) from cma.form_category) as categories, (select count(*) from cma.connection_form_field) as fields,
       (select count(*) from cma.form_submission where kept_cleared_at is not null) as cleared;
reset role;
```
Expected:
- one `0008p` row with your login;
- per tenant the forms as before: counted ones `t | t` (polled), the others `f | f`; `with_category` and `described` 0 (no category yet; the fields come with the new ingest image, step 8);
- `0 | 0 | 0`.

## 4. The data map: snapshot from dev, rebuild, push

`docs/datamap/README.md`, Refreshing the snapshot, on this branch, with the snapshot line of `docs/RUNBOOK.md`, Setup, step 8: `psql -X -qAt` (`-X` skips `~/.psqlrc`, `-q` keeps the `SET` of the query's `set role cma_owner` out of the file, `-At` prints its one line of JSON bare). The snapshot is schema only.

**Terminal** (`~/cma`, still on the pull request's branch)
```bash
cd ~/cma && cma_db dev && psql "$PGCONN" -X -qAt -v ON_ERROR_STOP=1 -f tools/datamap/schema.sql > docs/datamap/schema.json && grep -o '"latest_migration" : "[^"]*"' docs/datamap/schema.json
```
Expected: `connected to cma as martin@pulse4all.com`, then `"latest_migration" : "0008p"`.

**Terminal** (`~/cma`)
```bash
node tools/datamap/build.mjs && node tools/datamap/build.mjs --check
```
Expected: `datamap: wrote docs/datamap/index.html (77 tables, 104 views)`, then `datamap: 77 tables, 104 views, all described; index.html current`: two tables more than `main`'s snapshot at 0008o (75 tables, 101 views: `form_category`, `connection_form_field`) and three views more (their two reader views and `dq_form_answer_not_in_options`); a local snapshot at 0008p on 17 October 2026 gave exactly these. A problem list instead: send it to me.

**Terminal** (`~/cma`)
```bash
git add docs/datamap && git commit -m "Data map: snapshot after 0008p" && git push
```
Expected: the push names this pull request's branch.

## 5. Addition 0008p in prod

**Terminal** (from the Chromebook; point-in-time recovery on, as before every prod migration)
```bash
gcloud sql instances describe cma-prod-pg --project=p4a-cma-prod --format="value(settings.backupConfiguration.pointInTimeRecoveryEnabled,settings.backupConfiguration.transactionLogRetentionDays)"
```
Expected: `True	7`.

`75`, `53`, `69`, `71` and `73` refuse prod (they write throwaway tenants and run in dev only), so prod runs the migration twice and `33`, `35` and `41`, then a read-only check. `74` adds five columns to `connection_form` (setting `is_polled` on every form as it counts, an audit row each), one to `form_submission` and two tables, and replaces the forms' configuration, catalog, submission, privacy-deletion, run, intake and data-quality functions in one transaction; the ingest's writes wait for it a moment and carry on.

**Terminal** (from the Chromebook; `db/` scripts only, their output is check rows, counts and ids)
```bash
rec=records/0008p-prod-$(date +%F); mkdir -p "$rec" && cma_db prod && psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/74_forms_reporting.sql > "$rec/74.txt" 2>&1; tail -3 "$rec/74.txt"; psql "$PGCONN" -v ON_ERROR_STOP=1 -f db/74_forms_reporting.sql > "$rec/74-rerun.txt" 2>&1; tail -3 "$rec/74-rerun.txt"
for f in 33_verify_intake_core.sql 35_verify_telephony.sql 41_verify_lead_metrics.sql; do psql "$PGCONN" -v ON_ERROR_STOP=1 -f "db/$f" > "$rec/${f%%_*}-rerun.txt" 2>&1; echo "$f: $(grep -cE '\| PASS' "$rec/${f%%_*}-rerun.txt") PASS rows"; done
```
Expected: `connected to cma as martin@pulse4all.com`; `INSERT 0 1`, `COMMIT`, `RESET`; then `INSERT 0 0`, `COMMIT`, `RESET`; `33_verify_intake_core.sql: 2 PASS rows`, `35_verify_telephony.sql: 2 PASS rows`, `41_verify_lead_metrics.sql: 2 PASS rows`.

**Studio (cma-prod-pg)** (read only: the addition, the forms as they count, and Intake's form counts, which must not have moved; counts only)
```sql
set role cma_owner;
select version, applied_at, applied_by from cma.schema_migration where version = '0008p';
select t.slug, f.is_counted, f.is_polled, f.status, count(*) as forms from cma.connection_form f join cma.tenant t on t.id = f.tenant_id
group by 1, 2, 3, 4 order by 1, 2 desc, 3 desc, 4;
select r.market, sum(r.form_submissions) as forms
from cma.intake_per_day_of((select id from cma.tenant where slug = 'pulse4all-subscriptions'), timestamptz '2026-10-01 00:00 Europe/Amsterdam',
                           date_trunc('day', now() at time zone 'Europe/Amsterdam') at time zone 'Europe/Amsterdam') r
group by rollup (1) order by 1 nulls last;
reset role;
```
Expected:
- one `0008p` row with today's time and your login;
- `pulse4all-subscriptions | t | t | active | 28` and `| f | f | active | 22` (the catalog of 16 October 2026), archived forms as before;
- Intake's form submissions from 1 October to today 00:00 per market and the total (the last row, market empty). **Write the rows down: they are "Intake A".** No lead condition exists yet, so they equal the Intake report's form counts for the same dates.

## 6. Merge, watch the prod build

**Terminal** (from the Chromebook: the build runs in `p4a-cma-prod`)
```bash
cd ~/cma && gh pr merge <number> --squash --delete-branch && git switch main -q && git pull -q && git log --oneline -1
gcloud builds list --project=p4a-cma-prod --region=europe-west4 --limit=1 --format="table(status,substitutions.SHORT_SHA,createTime.date('%H:%M'))"
```
Expected: the merge commit; then a build for its short SHA, `QUEUED` or `WORKING`, then `SUCCESS` (RUNBOOK section 3). The build appears 2 to 4 minutes after the merge, so the list may still show the previous build: look again at 4 minutes before you start the trigger by hand (RUNBOOK section 3).

**Terminal** (from the Chromebook; only when the list still has no build for the merge's short SHA 4 minutes after the merge)
```bash
cd ~/cma && gcloud builds triggers run cma-web-main --project=p4a-cma-prod --region=europe-west4 --sha=$(git rev-parse HEAD)
```
Expected: the build's details; the list then shows it for the merge's short SHA.

## 7. The new web image on dev, the API verifier

**Terminal** (RUNBOOK section 4 with the merge's short SHA, then section 5; inside 07:00 to 22:00 Amsterdam)
```bash
cd ~/cma/web && node verify/api.mjs | tee ../records/0008p-dev-$(date +%F)/verify-api.txt | grep -E "^(note|ALL)"; node verify/api.mjs --provoke | tail -1
```
Expected: the same `note` lines and `ALL n PASS` as your last run of it (the Sources check that a form change with an unknown market writes nothing still passes: a form's polled switch and category are optional in that route), then `ALL n PROVOKED CHECKS FAILED, as they must`. `verify:api` has no Forms checks: the forms routes are proven by `75` in the database and by the local run in api mode (`local-records/web/api-mode-local-db.txt`).

**Terminal** (through RUNBOOK section 4's service proxy on port 8080, not the database; the report's answer holds form names, codes and counts, no submission or contact, and this prints counts only)
```bash
curl -s "localhost:8080/api/v1/reports/forms?from=2026-10-01&to=$(date +%F)&group=week" -H "x-cma-mock-subject: analyst" | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print(d["forms"], d["historyStart"], len(d["totals"]), sum(r["submissions"] for r in d["totals"]))'
curl -s -o /dev/null -w "%{http_code}\n" "localhost:8080/api/v1/reports/forms?from=2026-10-01&to=$(date +%F)" -H "x-cma-mock-subject: agent-two"
```
Expected: `True <date or None> <n> <m>`: the dev tenant's forms exist, its counted forms' submissions per form and market (the support forms' come after step 8); then `403` for an agent.

## 8. Dev: the ingest image and jobs, the configuration, a test form, the backfill

**8a. The image and the jobs.** **Terminal** (from the Chromebook: the image is built in `p4a-cma-prod`; on the merged `main`)
```bash
cd ~/cma && git log -1 --format=%h -- ingest/ && bash docs/ingest/deploy.sh dev && bash docs/ingest/deploy.sh dev --jobs
```
Expected: the image tag (the merge commit); the build in `p4a-cma-prod` ending `SUCCESS` (or `image … exists …; no build`), the service's `health: {"ok":true,"version":"<sha>"}`; then six `gcloud run jobs deploy` results and the schedules as before (`ingest-poll-forms: * * * * *`).

**8b. The fields arrive.** The forms poll refreshes the catalog at most hourly; the first refresh after the deploy brings every form's fields. **Studio (cma-dev-pg)** (repeat until `described` equals `forms`)
```sql
set role cma_owner;
select count(*) as forms, count(fields_refreshed_at) as described from cma.connection_form where status = 'active';
select f.name, ff.name as field, ff.kind, cardinality(ff.options) as options, ff.status
from cma.connection_form_field ff join cma.connection_form f using (tenant_id, connection_id, source_form_id)
where ff.kind <> 'other' order by 1, ff.sort_order;
select status, counts, error, started_at from cma.sync_run where job = 'forms_poll' order by started_at desc limit 3;
reset role;
```
Expected: `described` equal to `forms`; one row per choice field of the dev forms (kind `dropdown`, `radio`, `multiple_checkboxes` or `single_checkbox`, the number of options, `active`); `succeeded` runs. A `single_checkbox` lists 2 options (`true`, `false`). Note the HubSpot connection's id as `<conn>` (in the same block, before `reset role;`: `select c.id from cma.integration_connection c join cma.tenant t on t.id = c.tenant_id where t.slug = 'pulse4all-subscriptions' and c.adapter = 'hubspot';`) and pick one test form `<form id>` with at least one choice field.

**8c. The configuration.** **Studio (cma-dev-pg)** after the context block (the categories as in prod; the test form polled and not counted, category `support`; `<fields>` its choice fields as an array, such as `array['reason']`; the market field only when the form has a country dropdown and no market)
```sql
select cma.set_form_category('contact', 'Contact', 10);
select cma.set_form_category('info', 'Info', 20);
select cma.set_form_category('quote', 'Quote', 30);
select cma.set_form_category('cancellation', 'Cancellation', 40);
select cma.set_form_category('replacement', 'Replacement', 50);
select cma.set_form_category('iban_change', 'IBAN change', 60);
select cma.set_form_category('support', 'Support', 70);
select cma.set_form('<conn>', '<form id>', false, null, null, <fields>);
select cma.set_form_reporting('<conn>', '<form id>', true, 'support', null);
reset role;
```
Expected: nine empty results. A field that is no choice field is refused (`a kept field must be a choice field of the form …`, CMA04): take it out and run again.

**Studio (cma-dev-pg)** (read only)
```sql
set role cma_owner;
select f.source_form_id, f.name, f.is_counted, f.is_polled, f.category, f.kept_fields, f.market_field
from cma.connection_form f where f.connection_id = '<conn>' order by f.name;
reset role;
```
Expected: the forms, the test form `f | t | support` with its kept fields.

**8d. A test submission.** **Browser:** `CMA dev` → Marketing → Forms → the test form → Preview (or its share link): submit it twice with a test contact's email (VENDOR_SETUP §1.2), choosing an option in each choice field, and in the second also ticking its single checkbox if it has one. Wait two minutes (two poll runs).

**Studio (cma-dev-pg)** (ids, times and option values only)
```sql
set role cma_owner;
select source_form_id, submitted_at, contact_resolution, kept_values from cma.form_submission where source_form_id = '<form id>' order by submitted_at desc limit 2;
select status, counts from cma.sync_run where job = 'forms_poll' order by started_at desc limit 3;
reset role;
```
Expected: the two submissions, `resolved`, `kept_values` with the options you chose (a single checkbox as `"true"`, a multiple-checkboxes answer as a list); the runs `succeeded`, a `dropped` key only when an answer was left out. A `dropped` count for the single checkbox means HubSpot sends it as another value than `true` or `false`: send me the run's counts and what the HubSpot submission shows (README, Decision log, B17d's derived choices).

**8e. The backfill.** **Terminal**
```bash
gcloud run jobs execute ingest-backfill --project=p4a-cma-dev --region=europe-west4 --wait --args=--connection,<conn>,--object,form_submission,--from,2026-10-01
```
Expected: `Execution [ingest-backfill-…] has successfully completed.` A failed execution is run again with the same arguments: it continues where it stopped.

**Studio (cma-dev-pg)**
```sql
set role cma_owner;
select stream, status, counts, error from cma.sync_run where job = 'backfill' and stream = 'form_submission' order by started_at desc limit 1;
select f.name, f.is_counted, count(*) as submissions, count(*) filter (where fs.kept_values <> '{}') as with_answers
from cma.form_submission fs join cma.connection_form f using (tenant_id, connection_id, source_form_id)
where fs.submitted_at >= timestamptz '2026-10-01 00:00 Europe/Amsterdam' group by 1, 2 order by 1;
reset role;
```
Expected: `succeeded` with `fetched` and `upserted`; per form its submissions since 1 October, the test form's with answers.

## 9. Prod: the ingest jobs, the forms' fields

**Terminal** (from the Chromebook; on `main`; the forms poll and the backfill are jobs, the service's code is unchanged)
```bash
cd ~/cma && git switch -q main && git pull -q --ff-only && bash docs/ingest/deploy.sh prod --jobs
```
Expected: `image … exists (sha256:…); no build` (dev's image), six job deploys and the schedules as before.

Only the jobs are deployed in prod: the service `cma-ingest` keeps its revision. Should it ever be redeployed with this image, that is `PROD_RUNBOOK.md` 7.1's line with `--front ingest.pulse4all.app` and its `--tenant` and `--secret` flags; a bare `deploy.sh prod` stops with exit 2 since `Pulse4all-com/cma#146`.

The fields come with the forms poll's next catalog refresh, and the cursor `forms:catalog` allows one only when the last refresh is an hour old (the old image's last refresh set it). So the first refresh with fields can come up to an hour after the deploy: on 17 October 2026 it came at 14:32 UTC, about an hour after it. Until then `described` stays below `forms`.

**Studio (cma-prod-pg)** (repeat every 10 minutes until `described` is 50, up to an hour after the deploy; counts only)
```sql
set role cma_owner;
select count(*) as forms, count(fields_refreshed_at) as described from cma.connection_form f join cma.tenant t on t.id = f.tenant_id
where t.slug = 'pulse4all-subscriptions' and f.status = 'active';
select ff.name as field, ff.kind, count(*) as forms from cma.connection_form_field ff join cma.tenant t on t.id = ff.tenant_id
where t.slug = 'pulse4all-subscriptions' and ff.kind <> 'other' and ff.status = 'active' group by 1, 2 order by 1;
select status, counts, error, started_at from cma.sync_run where job = 'forms_poll' order by started_at desc limit 3;
reset role;
```
Expected: `50 | 50`; the choice fields of brief B17d's data: `are_you_already_a_customer | radio | 9`, `use_case | dropdown | 9`, `cancellation_reason | … | 10`, `exchange_reason` and `exchange_type` `| 10`, `request_channel`, `source_type`, `hs_ticket_category | multiple_checkboxes | 1`, `customer_sector`, `country_dropdown`, `ticket_country`, `deployment_outcome` (listed, never kept); `succeeded` runs. Note the connection's id as `<conn>`. Other fields or counts: send me the list.

## 10. Prod: the configuration, the backfill, Intake before and after the lead rule

Every Studio block of this step is on `cma-prod-pg`. The blocks that call a configuration function (`set_form_category`, `set_form_reporting`, `set_form`, `set_form_market_field`, `set_form_lead_condition`) run **after the context block**; the reads stand alone as the owner (`set role cma_owner;` … `reset role;`). 10c, 10d and 10g first show what they will set in a read-only review; then the same query calling the function runs after the context block.

**10a. The categories** (Martin, brief B17d), **after the context block**:
```sql
select cma.set_form_category('contact', 'Contact', 10);
select cma.set_form_category('info', 'Info', 20);
select cma.set_form_category('quote', 'Quote', 30);
select cma.set_form_category('cancellation', 'Cancellation', 40);
select cma.set_form_category('replacement', 'Replacement', 50);
select cma.set_form_category('iban_change', 'IBAN change', 60);
select cma.set_form_category('support', 'Support', 70);
reset role;
```
Expected: seven empty results.

**Studio (cma-prod-pg)** (read only)
```sql
set role cma_owner;
select c.code, c.name, c.sort_order, c.status,
       (select count(*) from cma.connection_form f where f.tenant_id = c.tenant_id and f.category = c.code) as forms
from cma.form_category c join cma.tenant t on t.id = c.tenant_id
where t.slug = 'pulse4all-subscriptions' order by c.sort_order, c.code;
reset role;
```
Expected: the seven categories in that order, `active`, `forms` 0.

**10b. The 28 counted forms: the category from their lead source.** First the catalog, **Studio (cma-prod-pg)** (read only):
```sql
set role cma_owner;
select f.is_counted, f.lead_source, count(*) as forms, count(f.market) as with_market
from cma.connection_form f where f.connection_id = '<conn>' and f.status = 'active' group by 1, 2 order by 1 desc, 2;
reset role;
```
Expected: `t | contact | 9 | 9`, `t | info | 9 | 9`, `t | quote | 10 | 9` (28 counted forms; every one but the generic Quote Form with its market: that form has no prefix, so the form rule gave it none; README, Decision log, 17 October 2026) and `f |  | 22 | n`, n the support forms whose name prefix the form rule of 12 October (`PROD_RUNBOOK.md` 7.5b) already read as their market (up to 19; 10c sets them again). Other counts for the counted forms: send me the rows before going on. The local rehearsal of steps 10 and 11 on an invented catalog of this shape is `local-records/db/runbook-step10-rehearsal.txt`.

Then **after the context block**:
```sql
select f.name, cma.set_form_reporting(f.connection_id, f.source_form_id, true, f.lead_source, f.market)
from cma.connection_form f
where f.connection_id = '<conn>' and f.status = 'active' and f.is_counted and f.lead_source in ('contact', 'info', 'quote')
order by f.name;
reset role;
```
Expected: 28 rows, each a form's name and an empty value.

**10c. The 22 support forms: polled, not counted, with category and market.** The repository does not hold prod's catalog, so one query over it gives each form its category from the name (cancellation, replacement, IBAN, support) and its market from the name's two-letter prefix, matched against the tenant's markets (`cma.market`), with no fixed list. A prefix that is not one of the tenant's markets leaves the market empty; UK maps to GB. Nothing in code knows these names. The prefix pattern `'^\s*([A-Za-z]{2})\M'` is written with single backslashes: Studio's `standard_conforming_strings` is on, so a backslash in a plain string literal stays one character, and a doubled backslash matches a literal backslash, which no form name has, so no form would get a market. First the review, **Studio (cma-prod-pg)** (read only):
```sql
set role cma_owner;
select f.source_form_id, f.name, x.category, m.code as market
from cma.connection_form f
cross join lateral (select case when f.name ~* 'iban' then 'iban_change' when f.name ~* 'cancel' then 'cancellation'
                                when f.name ~* 'replacement' then 'replacement' when f.name ~* 'support' then 'support' end as category,
                           case upper(substring(f.name from '^\s*([A-Za-z]{2})\M')) when 'UK' then 'GB'
                                else upper(substring(f.name from '^\s*([A-Za-z]{2})\M')) end as prefix) x
left join cma.market m on m.tenant_id = f.tenant_id and m.code = x.prefix
where f.connection_id = '<conn>' and f.status = 'active' and not f.is_counted
order by f.name;
reset role;
```
Expected: 22 rows, each a form's id, name, category and market: ten `cancellation` (nine with the market of their prefix, the general one empty), ten `replacement` (the same), `iban_change` with `DE` (DE change IBAN) and `support` without a market (the General support form). **Read every row against its name.** An empty category (a name the four words miss) or an empty market behind a prefix (a prefix that is not one of the tenant's markets: add the market first if it should be one) is set right afterwards, below; ask me when unsure.

Then the same query calling the function, **after the context block**:
```sql
select f.name, x.category, m.code as market, cma.set_form_reporting(f.connection_id, f.source_form_id, true, x.category, m.code)
from cma.connection_form f
cross join lateral (select case when f.name ~* 'iban' then 'iban_change' when f.name ~* 'cancel' then 'cancellation'
                                when f.name ~* 'replacement' then 'replacement' when f.name ~* 'support' then 'support' end as category,
                           case upper(substring(f.name from '^\s*([A-Za-z]{2})\M')) when 'UK' then 'GB'
                                else upper(substring(f.name from '^\s*([A-Za-z]{2})\M')) end as prefix) x
left join cma.market m on m.tenant_id = f.tenant_id and m.code = x.prefix
where f.connection_id = '<conn>' and f.status = 'active' and not f.is_counted
order by f.name;
reset role;
```
Expected: the review's 22 rows, each with an empty value in the last column. A row the review showed wrong is set again by hand, after the context block, with its id from the review: `select cma.set_form_reporting('<conn>', '<form id>', true, '<category>', '<market>');` (`null` without quotes for no market), then `reset role;`. Expected: an empty result.

**Studio (cma-prod-pg)** (read only)
```sql
set role cma_owner;
select f.category, f.market, f.is_counted, f.is_polled, count(*) as forms from cma.connection_form f
where f.connection_id = '<conn>' and f.status = 'active' group by 1, 2, 3, 4 order by 1, 2;
reset role;
```
Expected: per category and market: `cancellation` and `replacement` nine markets each `| f | t | 1` and `| (empty) | f | t | 1`, `contact`, `info` and `quote` their markets `| t | t` (and `quote | (empty) | t | t | 1`, the generic Quote Form), `iban_change | DE | f | t | 1`, `support | (empty) | f | t | 1`. The forms poll reads the support forms' submissions from 1 October within minutes (their first poll goes back to `intake.start_date`).

**10d. Kept fields and market fields** (brief B17d's amendment, item 7): per category the choice fields whose answers are kept, and for a form without a market its `country_dropdown`, else its `ticket_country`, as market field (kept too). `deployment_outcome` is never kept (Decision log, 16 October 2026). One query over the catalog gives each polled form its kept fields and, without a market, its market field; `set_form` sets counted, lead source and market too, so the form's own are passed as they are. First the review, **Studio (cma-prod-pg)** (read only):
```sql
set role cma_owner;
with wanted(category, field) as (values
  ('contact', 'are_you_already_a_customer'), ('contact', 'customer_sector'), ('info', 'use_case'),
  ('cancellation', 'cancellation_reason'), ('cancellation', 'source_type'),
  ('replacement', 'exchange_reason'), ('replacement', 'exchange_type'), ('replacement', 'request_channel'),
  ('support', 'hs_ticket_category')),
forms as (
  select f.connection_id, f.source_form_id, f.name, f.is_counted, f.lead_source, f.market, f.category, f.kept_fields,
         (select min(ff.name) from cma.connection_form_field ff
          where ff.connection_id = f.connection_id and ff.source_form_id = f.source_form_id and ff.status = 'active'
            and ff.kind in ('dropdown', 'radio') and ff.name in ('country_dropdown', 'ticket_country') and f.market is null) as market_field
  from cma.connection_form f where f.connection_id = '<conn>' and f.status = 'active' and f.is_polled),
kept as (
  select f.source_form_id, array_agg(ff.name order by ff.name) as fields
  from forms f join cma.connection_form_field ff on ff.connection_id = f.connection_id and ff.source_form_id = f.source_form_id
  where ff.status = 'active' and ff.name <> 'deployment_outcome' and ff.kind in ('dropdown', 'radio', 'multiple_checkboxes', 'single_checkbox')
    and ((f.category, ff.name) in (select category, field from wanted) or ff.name = f.market_field or ff.name = any (f.kept_fields))
  group by 1)
select f.category, f.name, coalesce(k.fields, '{}'::text[]) as kept_fields, f.market_field
from forms f left join kept k on k.source_form_id = f.source_form_id
order by f.category, f.name;
reset role;
```
Expected: 50 rows, one per form: Contact forms keep `are_you_already_a_customer` (and `customer_sector` where present), Info forms `use_case`, Quote forms and DE change IBAN nothing (`{}`), Cancellation forms `cancellation_reason` (and `source_type` where present), Replacement forms `exchange_reason`, `exchange_type` (and `request_channel` where present), the General support form `hs_ticket_category`; a choice field a form keeps already stays kept. `market_field` is filled only for a form without a market that has a `country_dropdown` or `ticket_country` field in HubSpot, and that field is then kept too; a form without a market and without such a field shows it empty (on 17 October 2026 that was all four forms without a market; README, Decision log, 17 October 2026). **Read the rows against the brief**; a form missing a field it should keep means the form lacks that field in HubSpot (send me its name).

Then the same query calling the function, **after the context block**, and in the same Run the market fields (a form's market field must be kept first, so it runs after `set_form`):
```sql
with wanted(category, field) as (values
  ('contact', 'are_you_already_a_customer'), ('contact', 'customer_sector'), ('info', 'use_case'),
  ('cancellation', 'cancellation_reason'), ('cancellation', 'source_type'),
  ('replacement', 'exchange_reason'), ('replacement', 'exchange_type'), ('replacement', 'request_channel'),
  ('support', 'hs_ticket_category')),
forms as (
  select f.connection_id, f.source_form_id, f.name, f.is_counted, f.lead_source, f.market, f.category, f.kept_fields,
         (select min(ff.name) from cma.connection_form_field ff
          where ff.connection_id = f.connection_id and ff.source_form_id = f.source_form_id and ff.status = 'active'
            and ff.kind in ('dropdown', 'radio') and ff.name in ('country_dropdown', 'ticket_country') and f.market is null) as market_field
  from cma.connection_form f where f.connection_id = '<conn>' and f.status = 'active' and f.is_polled),
kept as (
  select f.source_form_id, array_agg(ff.name order by ff.name) as fields
  from forms f join cma.connection_form_field ff on ff.connection_id = f.connection_id and ff.source_form_id = f.source_form_id
  where ff.status = 'active' and ff.name <> 'deployment_outcome' and ff.kind in ('dropdown', 'radio', 'multiple_checkboxes', 'single_checkbox')
    and ((f.category, ff.name) in (select category, field from wanted) or ff.name = f.market_field or ff.name = any (f.kept_fields))
  group by 1)
select f.category, f.name, cma.set_form(f.connection_id, f.source_form_id, f.is_counted, f.lead_source, f.market, coalesce(k.fields, '{}'::text[]))
from forms f left join kept k on k.source_form_id = f.source_form_id
order by f.category, f.name;
select f.name, mf.field, cma.set_form_market_field(f.connection_id, f.source_form_id, mf.field)
from cma.connection_form f
cross join lateral (select min(ff.name) as field from cma.connection_form_field ff
                    where ff.connection_id = f.connection_id and ff.source_form_id = f.source_form_id and ff.status = 'active'
                      and ff.kind in ('dropdown', 'radio') and ff.name in ('country_dropdown', 'ticket_country')) mf
where f.connection_id = '<conn>' and f.status = 'active' and f.is_polled and f.market is null and mf.field is not null
order by f.name;
reset role;
```
Expected: the review's 50 rows, each with an empty value in the last column; then one row per form the review showed with a `market_field`, each with an empty value (none when the review showed none).

**Studio (cma-prod-pg)** (read only)
```sql
set role cma_owner;
select f.category, count(*) as forms, count(*) filter (where f.kept_fields <> '{}') as keeping, count(f.market_field) as with_market_field,
       bool_or('deployment_outcome' = any (f.kept_fields)) as deployment_outcome_kept
from cma.connection_form f where f.connection_id = '<conn>' and f.status = 'active' group by 1 order by 1;
reset role;
```
Expected: per category the forms and those keeping answers; `with_market_field` counts the forms without a market that have a country field (`country_dropdown` or `ticket_country`) in HubSpot, so it depends on the forms, not on this step: on 17 October 2026 it was 0 on every category, because none of the four forms without a market (the general Cancellation, Replacement and support forms and the generic Quote Form) has one; `deployment_outcome_kept` false on every row.

**10e. The backfill from 1 October:** the support forms' submissions the poll has not read yet, and every stored submission's answers. **Terminal** (from the Chromebook)
```bash
gcloud run jobs execute ingest-backfill --project=p4a-cma-prod --region=europe-west4 --wait --args=--connection,<conn>,--object,form_submission,--from,2026-10-01
```
Expected: `Execution [ingest-backfill-…] has successfully completed.` A failed execution is run again with the same arguments: it continues where it stopped.

**Studio (cma-prod-pg)** (counts only)
```sql
set role cma_owner;
select status, counts, error from cma.sync_run where job = 'backfill' and stream = 'form_submission' order by started_at desc limit 1;
select f.category, count(*) as submissions, count(*) filter (where fs.kept_values <> '{}') as with_answers
from cma.form_submission fs join cma.connection_form f using (tenant_id, connection_id, source_form_id)
where f.connection_id = '<conn>' and fs.submitted_at >= timestamptz '2026-10-01 00:00 Europe/Amsterdam' group by 1 order by 1;
reset role;
```
Expected: `succeeded` with `fetched`, `upserted` (stored submissions whose answers were filled count here too) and `dropped` when answers fell outside the options (a few at most; many means an option set differs from what the catalog holds: send me the counts); per category its submissions since 1 October, most with answers (Quote and DE change IBAN keep none).

**10f. Intake before the lead rule** ("Intake B"). The block of step 5's Studio read, the Intake part only:
```sql
set role cma_owner;
select r.market, sum(r.form_submissions) as forms
from cma.intake_per_day_of((select id from cma.tenant where slug = 'pulse4all-subscriptions'), timestamptz '2026-10-01 00:00 Europe/Amsterdam',
                           date_trunc('day', now() at time zone 'Europe/Amsterdam') at time zone 'Europe/Amsterdam') r
group by rollup (1) order by 1 nulls last;
reset role;
```
Expected: **Intake B equals Intake A of step 5** for the days both cover, market by market: polling the 22 support forms and storing their submissions changed no Intake figure (brief B17d). A later run date adds the days since step 5; compare the same dates (the Intake report with a custom range shows them). A difference on an earlier date: send me both lists.

**10g. The lead rule on the nine Contact forms.** Tell Kira first that Intake's form counts drop by the existing customers from here on, with Intake B. The value is taken from each form's own options in the catalog (`connection_form_field.options`, the option that starts with "No,"), so it is spelled exactly as HubSpot holds it, apostrophe included. First the review, **Studio (cma-prod-pg)** (read only):
```sql
set role cma_owner;
select f.name, o.value
from cma.connection_form f
cross join lateral (select x as value from cma.connection_form_field ff cross join unnest(ff.options) x
                    where ff.connection_id = f.connection_id and ff.source_form_id = f.source_form_id
                      and ff.name = 'are_you_already_a_customer' and ff.status = 'active' and x like 'No,%') o
where f.connection_id = '<conn>' and f.status = 'active' and f.category = 'contact'
order by f.name;
reset role;
```
Expected: nine rows, each a Contact form's name and `No, I'm not a customer yet` as HubSpot writes it. Fewer rows (a form whose field has no option starting with "No,") or more (a form with two): send me the rows before going on.

Then the same query calling the function, **after the context block**:
```sql
select f.name, o.value, cma.set_form_lead_condition(f.connection_id, f.source_form_id, 'are_you_already_a_customer', array[o.value])
from cma.connection_form f
cross join lateral (select x as value from cma.connection_form_field ff cross join unnest(ff.options) x
                    where ff.connection_id = f.connection_id and ff.source_form_id = f.source_form_id
                      and ff.name = 'are_you_already_a_customer' and ff.status = 'active' and x like 'No,%') o
where f.connection_id = '<conn>' and f.status = 'active' and f.category = 'contact'
order by f.name;
reset role;
```
Expected: the review's nine rows, each with an empty value in the last column.

**Studio (cma-prod-pg)** (read only)
```sql
set role cma_owner;
select f.name, f.lead_condition from cma.connection_form f where f.connection_id = '<conn>' and f.lead_condition is not null order by f.name;
reset role;
```
Expected: the nine forms with `{"field": "are_you_already_a_customer", "values": ["No, I'm not a customer yet"]}`.

**10h. Intake after the lead rule** ("Intake C"): the read of 10f again, then the Contact forms' answers that explain the difference:
```sql
set role cma_owner;
select r.market, sum(r.form_submissions) as forms
from cma.intake_per_day_of((select id from cma.tenant where slug = 'pulse4all-subscriptions'), timestamptz '2026-10-01 00:00 Europe/Amsterdam',
                           date_trunc('day', now() at time zone 'Europe/Amsterdam') at time zone 'Europe/Amsterdam') r
group by rollup (1) order by 1 nulls last;
select f.market, coalesce(fs.kept_values ->> 'are_you_already_a_customer', '(no answer)') as answer, count(*) as submissions
from cma.form_submission fs join cma.connection_form f using (tenant_id, connection_id, source_form_id)
where f.connection_id = '<conn>' and f.category = 'contact'
  and fs.submitted_at >= timestamptz '2026-10-01 00:00 Europe/Amsterdam'
  and fs.submitted_at < date_trunc('day', now() at time zone 'Europe/Amsterdam') at time zone 'Europe/Amsterdam'
group by 1, 2 order by 1, 2;
reset role;
```
Expected: per market Intake C = Intake B minus that market's Contact submissions answered "Yes, I'm an existing Customer" or without an answer; the second list gives those numbers per market. Send Kira Intake B, Intake C and the second list (counts only); README, Open decisions.

## 11. Prod: read-only counts

**Studio (cma-prod-pg)** (counts only; the report's own reads for 1 October to today)
```sql
set role cma_owner;
select coalesce(r.category, 'none') as category, r.market, sum(r.submissions) as submissions, sum(r.resolved) as resolved,
       sum(r.not_found) as not_found, sum(r.ambiguous) as ambiguous, sum(r.no_email) as no_email, sum(r.pending) as pending
from cma.forms_report_of((select id from cma.tenant where slug = 'pulse4all-subscriptions'), date '2026-10-01', current_date, 'week', null, null, null, now()) r
where r.period = 'current' and r.group_key is null group by 1, 2 order by 1, 2;
select r.field, count(distinct r.value) as values_seen, sum(r.submissions) as answers
from cma.forms_answers_of((select id from cma.tenant where slug = 'pulse4all-subscriptions'), date '2026-10-01', current_date, null, null, null, null, null, now()) r
where r.period = 'current' group by 1 order by 1;
select cma.forms_history_start_of((select id from cma.tenant where slug = 'pulse4all-subscriptions')) as history_start;
select t.slug, (select count(*) from cma.data_quality_of(t.id) q where q.check_key = 'form_answer_not_in_options') as answers_not_in_options
from cma.tenant t order by 1;
select status, count(*), sum((counts ->> 'dropped')::integer) as dropped from cma.sync_run
where job = 'forms_poll' and started_at > now() - interval '1 hour' group by 1;
reset role;
```
Expected: submissions per category and market with the resolution split (`unknown` where neither the form, its market question nor the contact gives a market); per kept field the values seen and the answers (no `deployment_outcome`); the history start on or after 1 October; `answers_not_in_options` 0 for both tenants; about 60 `succeeded` runs in the last hour with few or no `dropped`.

## 12. The browser verifiers against a local mock server

**Terminal** (a second terminal tab for the server, README Code paragraph; port 8080 must be free: `pkill -f "run services proxy"` first if step 7's service proxy still runs)
```bash
cd ~/cma/web && npm run build >/dev/null && cp -r .next/static .next/standalone/.next/ && (test -d public && cp -r public .next/standalone/ || true) && CMA_AUTH_MODE=mock CMA_DATA_MODE=mock PORT=8080 npm start
```
**Terminal** (the first tab)
```bash
cd ~/cma/web && for v in theme layout hints; do BASE=http://localhost:8080 node verify/$v.mjs | tail -1; BASE=http://localhost:8080 node verify/$v.mjs --provoke | tail -1; done
```
Expected, in order (the local run's figures on this branch after `main` of 17 October 2026, with N16-B's Follow-up pages): `theme: PASS (53 pages, …, 40 tables per 7.6 and 3.3, a header hint open on 16 report pages)`, `theme: FAIL (6 problems)`, `layout: PASS (…, Calls and Calls per agent for 7 identities (…), Forms for 7 identities (the keycaps, the four tiles, the forms table and the answers inside their cards, the deltas like for like and none before the forms history), Sources with its form categories (every table inside its card), …)`, `layout: FAIL (46 problems)`, then `hints: PASS (…)` and `hints: FAIL (…)`. On `main` too, `hints` can fail on one line that depends on the date, `manager /reports/speed-to-lead?range=month&group=day: 7 headers, expected at least 12`, because the mock's month may hold too few Speed to lead rows for the full table: on 17 October 2026 the local run gave `hints: FAIL (1 problems)` with exactly that line, and `hints: FAIL (4 problems)` provoked. That line alone is not this pull request's; any other `hints` line is: send it to me. The layout verifier writes its screenshots to `records/layout/`.

## 13. A hand check in prod

**Browser:** workspace.pulse4all.app → Reports → Forms (after Calls per agent) → This month, then Group by Week (G).

Expected: four tiles: Submissions and Forms with submissions, each with its change in grey ("No history to compare yet" while the previous month starts before the first stored submission; hover it: "The forms history starts on …"), Contact found as a share, Without a market. Below: submissions per week as blue columns; the table per form, each with its category and total, its markets beneath with the previous period, the change and the contacts found; Per category (Contact, Info, Quote, Cancellation, Replacement, IBAN change, Support) and Per market; How contacts were found as bars, no donut; Answers per form and question (option values only), narrowed by Question and Answer. No email address, no contact, no free text.

**Browser:** press Y, choose Cancellation; press K, choose a market; press X.

Expected: every tile, the chart and the tables narrow to cancellation forms in that market, the date line names both; X downloads `forms_<from>_<to>.csv` in the organisation's export format, one row per form and market.

**Browser:** Configuration → Sources → the HubSpot connection → Forms, then Configuration → Sources (the list).

Expected: the forms table with Polled, Counted, Category, Lead source and Market; a counted form's dialog shows Polled ticked and greyed; the list page's Form categories card with the seven categories and their form counts (Contact 9, Info 9, Quote 10, Cancellation 10, Replacement 10, IBAN change 1, Support 1).

Send me the outputs of steps 2, 3, 5, 8, 9, 10 and 11 (ids, counts, dates and times only; Intake A, B and C); records go in a separate pull request, written from your report.
