# Runbook, attempts per deal for sales: addition 0008z (`94`, `95`) with message withdrawal, the rail order and Welcome on open

Labels:
- **Browser**: a page or a click path.
- **Terminal**: Martin's own Linux terminal (Chromebook Linux or his Linux machine), in `~/cma` unless stated. A step against prod (`p4a-cma-prod`, `cma-prod-pg`) runs from the Chromebook only.
- **Studio**: Cloud SQL Studio, on the instance named. Check the instance in Studio's breadcrumb before every Run.
- **File**: a repository path.

SQL and shell never share a block. Studio shows no notices and one result per statement: a verify's verdict table sits in the results dropdown, before the last results (the `drop function` lines). Every Studio block here reads ids, codes, counts, links and milliseconds only (README, Where a command runs). Every step ends with what you should see. Claude Code's local outputs are in `local-records-0008z/`, and its `README.md` lists them.

**Four rules for every block below** (also in `docs/RUNBOOK.md`, section 7):
- **Whose user.** A block that acts as a person names an email next to it, with the reason. Dev blocks use the dev seed's admin, `admin@example.com`: dev's data is the seed's, and that admin holds every report permission in Pulse4all Subscriptions, while your own login need not be a user there. Prod blocks use `martin@pulse4all.com`: prod has no seed people, and your own user is the one with access.
- **Provoked runs.** Paste the verify script, press Ctrl+F, search `'verify.provoke', 'false'` and change only that `false` to `true`. Run. Result 1 in the dropdown must read `true`; if it reads `false`, the edit did not take. Never replace the editor's content with a single line.
- **Long verifies run from the Terminal.** Studio stops a statement at 300 seconds. `91` and any verify that may run longer go through the Auth Proxy:
  ```bash
  cma_db dev && time psql "$PGCONN" -X -v ON_ERROR_STOP=1 -f db/<file> > /tmp/<n>.txt 2>&1; tail -22 /tmp/<n>.txt
  ```
  `<file>` is the script, `<n>` its number. `tail -22` shows the verdict table and the timing.
- **Hash steps run outside every market's office hours** (for Pulse4all after 17:00 or before 09:00 local time, or at the weekend). `speed_to_lead_rows` holds two figures that count up to now: an open deal's waiting business seconds, and whether a deal was called before the next business noon. Both stand still outside office hours, so the block can hash every column. Identical hashes before and after prove the migration changed nothing there. A differing hash with an unchanged `newest_change` is the migration's: stop. A differing hash with a later `newest_change` means new data arrived between the runs.

**What changes** (README: Data model: attempts per deal; Decision log, 20 October 2026):
- **0008z** (`94`, `95`): Attempts per deal counts the **sales deals** only: the lead pipelines, never a pipeline of orders. The scope (`lead`, `counted`) is gone.
  - An attempt is an outbound **telephony** call on the deal or its contacts (`attempts.source` `telephony`, the default), or every outbound call logged in HubSpot (`crm`). A HubSpot call without an Aircall call is never an attempt under `telephony`; the page counts those apart.
  - The window runs from the creation (less the pre-window) to the close, the contacts' first order (a won order deal or a store order) or now. A deal ordered another way has the outcome `ordered` and is no longer open.
  - Reached: the call's outcome when it has one, else at least `attempts.reached_min_talk_seconds` (30) of talk. Talk time is ended minus answered. The speed to lead is the business time to the first attempt, as Speed to lead measures it.
  - Three settings: `attempts.source`, `attempts.reached_min_talk_seconds`, `attempts.speed_buckets_business_minutes`.
  - One deal's attempts (`cma.attempts_of_deal`, `/api/v1/reports/attempts/deals/{dealId}`).
  - The reader view `cma_read.attempts_per_deal` with the new columns.
  - Messages: `withdrawn_at` and `withdrawn_by` on the message, the permission `messages.withdraw` on the admin role of every tenant, `cma.withdraw_message`. No row is ever deleted.
- `cma.lead_calls_of` and `cma.lead_to_order_of` are rewritten on the shared definitions (`cma.deal_calls_of`, `cma.contact_store_orders_of`), the same rows (`95` B21 proves it against 0007d's bodies). That is why `41`, `61`, `69`, `73`, `75`, `77`, `81`, `83`, `85`, `89` and `91` run again, and why the lead reads are hashed before and after `94`. `43` (messaging) runs again too, amended for the withdrawal.
- Web: the Attempts pages for sales (six tiles, won against lost, the deal's attempts on Enter); Delete on Messages for `messages.withdraw`; the Reports and Configuration order; Missed, not called back at the bottom of the Live board; Welcome on open.
- `tools/drift/functions.sql`: a read-only list of every function's signature and definition hash, to diff dev against prod (step 11).
- Seeds: none change. `94` itself grants `messages.withdraw` to the admin role of every existing tenant and to the default ladder of a new one, so `02` and `03` need no rerun.

**Order matters:**
- `94` changes the arguments of the two Attempts page reads (the scope gives way to attempted and outcome). The web of `main` calls them with a scope, so **between `94` in prod and the deploy of this merge, Reports → Attempts per deal answers an error**. Run steps 7 to 9 in one sitting outside office hours, and merge at once after the timings (step 8). The spot check against HubSpot (step 9) reads the database only, so it comes after the merge.
- Every other read of `main`'s web runs unchanged on `94` (the message reads keep their columns; the stats gain one).
- The data map: `docs/datamap/catalog.json` gains the new columns. `verify:datamap` fails on this branch until step 5 refreshes `schema.json` from dev.
- No ingest change, no `cloudbuild.yaml` change, no environment variable.

| Step | What | Elapsed |
|---|---|---|
| 0 | Review the pull request, build it, check the additions in dev and prod | 10 min |
| 1 | Dev: the lead reads before and after `94`, `94` twice with the fingerprint | 5 min |
| 2 | Dev: `95` normal and provoked | 3 min |
| 3 | Dev: `93`, `43` and the earlier verifies again (`91` from the Terminal) | 20 min |
| 4 | Dev: the permission on the admin roles | 1 min |
| 5 | The data map: snapshot from dev, rebuild, push | 5 min |
| 6 | Prod: point-in-time recovery | 1 min |
| 7 | Prod: the lead reads before and after `94`, `94` twice, `41` | 10 min (outside office hours) |
| 8 | Prod: the timings as `cma_app`, then merge and watch the build | 15 min |
| 9 | Prod: the spot check of ten sales deals against HubSpot | 15 min |
| 10 | Prod: the hand checks and the request log | 15 min |
| 11 | Dev and prod: the drift check | 3 min |

---

## 0. Review the pull request, build it, check the additions

**Browser:** GitHub → Pulse4all-com/cma → Pull requests → "Attempts per deal for sales (0008z), message withdrawal, rail and Live board order, Welcome on open, 0008y record, runbook fixes, drift check". Read the description and the diff.

Expected:
- in `db/`, the new `94_attempts_for_sales.sql` and `95_verify_attempts_for_sales.sql`, and `93_verify_attempts_per_deal.sql` amended (its header names the changed checks);
- under `web/`, the Attempts pages and components, Messages (`Inbox.tsx`, `SentMessages.tsx`, `MessageWithdraw.tsx`), the rail (`lib/nav.ts`), the Live board (`InboundLive.tsx`), Welcome on open (`proxy.ts`, `lib/session.ts`, `app/app.webmanifest`), the routes, the copy and the verifiers;
- `docs/attempts-2026-10/` (this runbook, `records/`, `local-records-0008z/`), `docs/RUNBOOK.md`, `tools/drift/`, `docs/datamap/catalog.json` and `README.md`;
- nothing under `ingest/`, `cloudbuild.yaml` or `records/`.

**Terminal** (the pull request's number from the page)
```bash
cd ~/cma && gh pr checkout <number> && cd web && npm ci --no-audit --no-fund 2>&1 | tail -1 && npm run build > /tmp/build.txt 2>&1; echo "build exit: $?"; npm run typecheck 2>&1 | tail -1; npm run verify:reports 2>&1 | tail -1; cd ~/cma
```
Expected:
- `found 0 vulnerabilities`, or the known advisories of README, Open decisions;
- `build exit: 0`;
- `✓ Types generated successfully`;
- `ALL 156 PASS`.

**Do not merge yet.**

**Studio (cma-dev-pg)** and **Studio (cma-prod-pg)** (read only)
```sql
set role cma_owner;
select version, applied_at from cma.schema_migration where version >= '0008y' order by 1;
reset role;
```
Expected on both instances: `0008y` only. Without `0008y`, run `docs/attempts-2026-10/RUNBOOK.md` first. With `0008z` already there, stop and tell me.

## 1. Dev: the lead reads before and after `94`, `94` twice

`94` rewrites `cma.lead_calls_of` and `cma.lead_to_order_of` on the shared definitions. This step proves, before prod does the same in step 7, that Speed to lead's and lead to order's reads give the same rows afterwards. The block hashes every row of `cma.speed_to_lead_rows` and `cma.lead_to_order_rows` for 1 to 20 October 2026:
- every column, ordered by tenant and deal;
- as `cma_app` (the usual route: a user, row-level security on).

Run the block before `94`, then `94`, then the block again, in one sitting outside every market's office hours (the four rules above).

**Studio (cma-dev-pg)** (read only, two temporary tables of the session: the lead reads' fingerprint. Ids, counts, hashes and a time only; each read's rows are hashed, never shown. As `admin@example.com`: dev's data is the seed's, and the seed's admin holds the report permissions in Pulse4all Subscriptions)
```sql
set time zone 'UTC';
set role cma_owner;
drop table if exists pg_temp.lead_reads;
create temp table lead_reads (tenant text, read text, rows_read bigint, rows_md5 text, newest_change timestamptz);
grant select, insert on lead_reads to cma_app;
drop table if exists pg_temp.lead_reads_context;
create temp table lead_reads_context as
  select t.slug, t.id as tenant_id, u.id as user_id
  from cma.tenant t join cma.app_user u on u.tenant_id = t.id and u.email = 'admin@example.com';
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
      from cma.speed_to_lead_rows('2026-10-01', '2026-10-20') r;
    insert into lead_reads
      select c.slug, 'lead_to_order_rows', count(*),
             md5(coalesce(string_agg(to_jsonb(r)::text, '|' order by r.tenant_id, r.deal_id), '')), v_newest
      from cma.lead_to_order_rows('2026-10-01', '2026-10-20') r;
  end loop;
end
$$;
select tenant, read, rows_read, rows_md5, newest_change from lead_reads order by tenant, read;
reset role;
```
Expected: two rows for `pulse4all-subscriptions`, `lead_to_order_rows` and `speed_to_lead_rows`, each with `rows_read`, `rows_md5` and `newest_change`. Copy them into your notes. No rows at all: `admin@example.com` is not in dev.

**File:** `db/94_attempts_for_sales.sql`: open it and copy all of it.

**Studio (cma-dev-pg):** paste the whole script and Run.

Expected:
- the run ends without an error; Studio's last result is `reset role`;
- an error shows in red with its message: stop and send it to me;
- `addition 0008y (92_attempts_per_deal.sql) must run before 0008z` means step 0 found no `0008y`.

**Studio (cma-dev-pg):** the lead reads' block above again, at once.

Expected: the same rows as before `94`, the same `rows_read` and `rows_md5` for each read, `newest_change` included. Locally, on a fresh database with the dev seed and `web/verify/reports-fixture.sql`, the two runs were identical (`local-records-0008z/db/lead-reads-before-94.txt` and `-after-94.txt`). A difference: the fourth rule above; send me both outputs.

**Studio (cma-dev-pg)** (read only: the fingerprint of what `94` defines)
```sql
set role cma_owner;
select (select count(*) from pg_proc p where p.pronamespace in ('cma'::regnamespace, 'cma_read'::regnamespace)) as functions,
       (select md5(string_agg(p.oid::regprocedure::text || pg_get_functiondef(p.oid), '' order by p.oid::regprocedure::text))
          from pg_proc p where p.pronamespace in ('cma'::regnamespace, 'cma_read'::regnamespace) and p.prokind = 'f') as functions_md5,
       (select count(*) from pg_class c where c.relkind = 'v' and c.relnamespace in ('cma'::regnamespace, 'cma_read'::regnamespace)) as views,
       (select string_agg(s.key || '=' || s.default_value, ' ' order by s.key) from cma.setting s where s.key like 'attempts.%') as attempt_settings,
       (select count(*) from cma.role_permission where permission_key = 'messages.withdraw') as withdraw_grants,
       (select m.version || ' ' || m.applied_at from cma.schema_migration m where m.version = '0008z') as addition;
reset role;
```
Expected: one row.
- `functions`: 475 (466 at 0008y, as your dev record of 19 October 2026 says; nine more).
- `views`: 120 (the reader view is replaced, not added).
- `attempt_settings`: `attempts.max_bucket=5 attempts.reached_min_talk_seconds=30 attempts.since_last_buckets_business_days=1,2,5 attempts.source=telephony attempts.speed_buckets_business_minutes=5,15,60,240,1440`.
- `withdraw_grants`: one per tenant with an admin role (2 locally).
- `addition`: `0008z` with today's time.
- Write down `functions`, `functions_md5` and `views`.

**Studio (cma-dev-pg):** paste `db/94_attempts_for_sales.sql` again and Run. Then the fingerprint block again.

Expected:
- the same row as before: the same `functions`, `functions_md5`, `views`, settings and grants;
- `addition`'s time unchanged.

The second run adds nothing (locally: `local-records-0008z/db/fingerprint-after-94.txt` and `-rerun.txt`, identical).

## 2. Dev: `95` normal and provoked

**File:** `db/95_verify_attempts_for_sales.sql`: copy all of it.

**Studio (cma-dev-pg):** paste and Run. Open the results dropdown at the result with 37 rows.

Expected: rows `A1` to `A7`, `B1` to `B22` and `C1` to `C7`, each `PASS`, and the last row `verdict | PASS | 36 PASS, 0 FAIL`.
- `REFUSED: not dev` means the instance is not dev's.
- Any `FAIL` row: send me the row (its last column names what was found).

**Studio (cma-dev-pg):** paste `95` again. Ctrl+F `'verify.provoke', 'false'`, change only that `false` to `true`, and Run. Result 1 must read `true`.

Expected: every row `FAIL`, and `verdict | PROVOKED, NOT A PASS | 0 PASS, 36 FAIL`. Nothing stays behind: blocks B and C roll back.

## 3. Dev: `93`, `43` and the earlier verifies again

`93` (0008y's verify) is amended for the sales population: its header names the checks that changed and why (A2, A3, B1, B4, B6, B7, B8, B12, B13, B14, B18, B19). Its tenant sets `attempts.source` to `crm`, so its CRM calls stay attempts.

**File:** `db/93_verify_attempts_per_deal.sql`: copy all of it.

**Studio (cma-dev-pg):** paste and Run. Expected: `verdict | PASS | 25 PASS, 0 FAIL`.

**Studio (cma-dev-pg):** paste `93` again, Ctrl+F `'verify.provoke', 'false'`, change only that `false` to `true`, Run; Result 1 reads `true`. Expected: `verdict | PROVOKED, NOT A PASS | 0 PASS, 25 FAIL`.

`43` (0008's messaging verify) is amended for the withdrawal (Martin, 20 October 2026); its header names the change and why. Once `0008z` is recorded, its check A3 asserts that a message changes only by its withdrawal (`withdrawn_at` and `withdrawn_by` set together, once, never cleared; the application may update exactly those two columns), and A5 that `cma_read.message` ends with both columns. Before `0008z` both assert what they always did, and every other check of `43` is unchanged.

**File:** `db/43_verify_messaging.sql`: copy all of it.

**Studio (cma-dev-pg):** paste and Run. Expected: no error in red; the last result one row per active tenant, each `PASS` (locally: `local-records-0008z/db/43_verify_messaging-at-0008z.txt`). A red `FAIL …` line: send it to me.

**Studio (cma-dev-pg):** paste `43` again, Ctrl+F `'verify.provoke', 'false'`, change only that `false` to `true`, Run; Result 1 reads `true`. Expected: the run stops in red at `FAIL A1: migration 0008 not recorded` (Studio stops at the first error; locally, where the run goes on, every block A to E fails and the verdict reads `PROVOKED, NOT A PASS`, `-provoked.txt`). Nothing stays behind: blocks B to E roll back.

`94` rewrote `cma.lead_calls_of` and `cma.lead_to_order_of` (the same rows), so every verify that reads them runs again. Each is one step:
- **File:** copy the script.
- **Studio (cma-dev-pg):** paste and Run.
- Expected: the verdict below (locally: `local-records-0008z/db/<script>-at-0008z.txt`).

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

`91` runs longer than Studio's 300 seconds on dev's shared core, so it runs from the Terminal (the third rule above):

**Terminal** (`~/cma`, on the pull request's branch)
```bash
cma_db dev && time psql "$PGCONN" -X -v ON_ERROR_STOP=1 -f db/91_verify_report_speed.sql > /tmp/91.txt 2>&1; tail -22 /tmp/91.txt
```
Expected: about seven minutes, then the verdict table: 12 rows `PASS` and B8 `FAIL` alone, as on 19 October 2026 (`docs/attempts-2026-10/records/attempts-dev-2026-10-19.md`): B8 times every report read on dev's shared core, and prod's timings in step 8 decide. Locally, on a dedicated core, all 13 passed in 86 seconds. Any other `FAIL` row: send me the row.

## 4. Dev: the permission on the admin roles

No seed changes, so `03` does not run again. `94` grants `messages.withdraw` itself.

**Studio (cma-dev-pg)** (read only)
```sql
set role cma_owner;
select t.slug, r.key as role, count(rp.permission_key) as withdraw
from cma.tenant t
join cma.app_role r on r.tenant_id = t.id
left join cma.role_permission rp on rp.tenant_id = t.id and rp.role_id = r.id and rp.permission_key = 'messages.withdraw'
group by t.slug, r.key
having count(rp.permission_key) > 0 or r.key = 'admin'
order by t.slug, r.key;
reset role;
```
Expected: one row per tenant, `admin | 1`, and no other role. `reports.per_person` stays as it was (`email,orders,attempts` in dev since 19 October 2026).

## 5. The data map: snapshot from dev, rebuild, push

**Terminal** (`~/cma`, still on the pull request's branch)
```bash
cd ~/cma && cma_db dev && psql "$PGCONN" -X -qAt -v ON_ERROR_STOP=1 -f tools/datamap/schema.sql > docs/datamap/schema.json && grep -o '"latest_migration" : "[^"]*"' docs/datamap/schema.json
```
Expected: `connected to cma as martin@pulse4all.com`, then `"latest_migration" : "0008z"`.

**Terminal** (`~/cma`)
```bash
node tools/datamap/build.mjs && node tools/datamap/build.mjs --check
```
Expected:
- `datamap: wrote docs/datamap/index.html (81 tables, 111 views)`;
- then `datamap: 81 tables, 111 views, all described; index.html current`.

The same tables and views as 0008y's snapshot; `cma.message` and `cma_read.attempts_per_deal` gain columns, which `catalog.json` already describes. A problem list instead: send it to me.

**Terminal** (`~/cma`)
```bash
git add docs/datamap && git commit -m "Data map: snapshot after 0008z" && git push
```
Expected: the push names this pull request's branch. `verify:datamap` passes from here on.

## 6. Prod: point-in-time recovery

**Terminal** (from the Chromebook; point-in-time recovery on, as before every prod migration)
```bash
gcloud sql instances describe cma-prod-pg --project=p4a-cma-prod --format="value(settings.backupConfiguration.pointInTimeRecoveryEnabled,settings.backupConfiguration.transactionLogRetentionDays)"
```
Expected: `True	7`. Anything else: stop.

## 7. Prod: the lead reads before and after `94`, `94` twice, `41`

Steps 7 to 9 run in one sitting outside every market's office hours: from `94` until the deploy of step 8, Attempts per deal answers an error (Order matters, above).

**Studio (cma-prod-pg)** (read only, two temporary tables of the session: the lead reads' fingerprint. Ids, counts, hashes and a time only. As `martin@pulse4all.com`: prod has no seed people, and your own user has the report permissions)
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
      from cma.speed_to_lead_rows('2026-10-01', '2026-10-20') r;
    insert into lead_reads
      select c.slug, 'lead_to_order_rows', count(*),
             md5(coalesce(string_agg(to_jsonb(r)::text, '|' order by r.tenant_id, r.deal_id), '')), v_newest
      from cma.lead_to_order_rows('2026-10-01', '2026-10-20') r;
  end loop;
end
$$;
select tenant, read, rows_read, rows_md5, newest_change from lead_reads order by tenant, read;
reset role;
```
Expected: one pair of rows per tenant where your login has a user, at least `pulse4all-subscriptions`: `lead_to_order_rows` and `speed_to_lead_rows`, each with `rows_read` (Subscriptions' lead deals of 1 to 20 October), `rows_md5` and `newest_change`. Copy the rows into your notes.

**Studio (cma-prod-pg):** paste `db/94_attempts_for_sales.sql` and Run.

Expected: the run ends without an error; the last result is `reset role`.

**Studio (cma-prod-pg):** the lead reads' block above again, at once.

Expected: the same rows as before `94`, the same `rows_read` and `rows_md5` for each tenant and read, `newest_change` included. If any `rows_read` or `rows_md5` differs while `newest_change` stayed the same: **stop, do not merge**, and send me both outputs (the fourth rule above).

**Studio (cma-prod-pg):** step 1's fingerprint block. Then `94` again, then the fingerprint block again.

Expected: the two fingerprint rows identical: 475 functions, 120 views, step 1's `attempt_settings`, `withdraw_grants` one per tenant, and `0008z` with the time of the first run. The `functions_md5` may differ from dev's only if a function differs; step 11 names which.

**Studio (cma-prod-pg):** paste `db/41_verify_lead_metrics.sql` and Run.

Expected: one row per tenant, each `PASS`, with the same `lead_deals` and `called` as before `94` (508 and 390 for Subscriptions on 20 October 2026, plus the deals since). `93`, `95` and the other verifies refuse prod (they write throwaway tenants and run in dev only). `02` does not run: `94` grants the new permission itself.

## 8. Prod: the timings as `cma_app`, then merge

**Studio (cma-prod-pg)**: one Run of the whole block.
- Context: tenant `pulse4all-subscriptions`, as `martin@pulse4all.com` (your own user: prod has no seed people), row-level security on.
- Each read of October runs three times under `EXPLAIN ANALYZE`; the best execution time is kept.
- Attempts per agent's page read refuses Pulse4all while `reports.per_person` holds `email` only. The block therefore times the read under it, `cma.attempts_per_person_of`.
- One deal's attempts: the October sales deal with the most attempts.

Output: names and milliseconds only; nothing per person or per deal is shown.
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
  v_deal uuid := (select a.deal_id from cma.attempts_per_deal_of(current_setting('app.tenant_id')::uuid, timestamptz '2026-09-30 22:00+00',
                                                                  timestamptz '2026-10-31 23:00+00') a
                  order by a.attempts desc, a.deal_id limit 1);
begin
  foreach v_q in array array[
    'attempts_per_deal_page, by day|select cma.attempts_per_deal_page(''2026-10-01'', ''2026-10-31'', ''day'', null, null)',
    'attempts_per_deal_page, by pipeline|select cma.attempts_per_deal_page(''2026-10-01'', ''2026-10-31'', ''pipeline'', null, null)',
    'attempts_per_deal_page, by week, attempted and open|select cma.attempts_per_deal_page(''2026-10-01'', ''2026-10-31'', ''week'', null, null, ''some'', ''open'')',
    'attempts_per_person_of (the per-agent page''s read)|select cma.attempts_per_person_of(current_setting(''app.tenant_id'')::uuid, date ''2026-10-01'', date ''2026-10-31'', null, null, ''all'', ''all'', now())',
    'attempts_of_deal (the deal with the most attempts)|select * from cma.attempts_of_deal(' || quote_literal(v_deal) || ')'] loop
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
Expected: after a few seconds, five rows `(read, best_ms)`:
- the three page reads each under 500 ms, and about as fast as 0008y's on 20 October 2026 (178.9, 176.7 ms): within about 1.5 times, so under about 270 ms;
- `attempts_per_person_of` under about 210 ms (0008y: 139.2 ms);
- `attempts_of_deal` under 100 ms.

Locally, at about twice prod's lead volume (`local-records-0008z/db/volume-timing.txt`): 273.9 ms by day, 268.3 ms by pipeline, 251.6 ms for one market with no attempt, 256.0 ms by week with the deals won, 123.1 ms per person, and 44.0 ms for the slowest of ten deals' attempts. 0008y's reads on the same machine and volume (`volume-timing-0008y-same-machine.txt`): 266.8 ms by day, 281.8 ms by pipeline with every counted deal, 237.2 ms for one market, 115.3 ms per person.

If a page read is at 500 ms or above, `attempts_of_deal` at 100 ms or above, or the Run stops with an error: **stop, do not merge**, and send me the rows or the error. Attempts per deal answers an error until this pull request deploys; tell me at once.
- `CMA06` names a permission your user lacks in this tenant (`reports.view` or `performance.team`).
- An empty `app.user_id` in the first result means the email in the block is not your user's.

**Terminal** (from the Chromebook: merge at once, so the Attempts pages work again)
```bash
cd ~/cma && gh pr merge <number> --squash --delete-branch && git switch main -q && git pull -q && git log --oneline -1
gcloud builds list --project=p4a-cma-prod --region=europe-west4 --limit=1 --format="table(status,substitutions.SHORT_SHA,createTime.date('%H:%M'))"
```
Expected: the merge commit, then a build for its short SHA, `QUEUED` or `WORKING`, then `SUCCESS` (RUNBOOK section 3). The build appears 2 to 4 minutes after the merge. No build for the short SHA 4 minutes after the merge:
```bash
gcloud builds triggers run cma-web-main --project=p4a-cma-prod --region=europe-west4 --sha=$(git rev-parse HEAD)
```
Expected: a build for the merge commit, then `SUCCESS`.

## 9. Prod: the spot check of ten sales deals against HubSpot

The spot check of 0008y moved here: it now checks the sales definition.

**Studio (cma-prod-pg)** (read only: ten sales deals of October by id, with their attempts and links; no name, address or phone number. As `martin@pulse4all.com`: your own user)
```sql
set role cma_owner;
select set_config('app.tenant_id', (select t.id::text from cma.tenant t where t.slug = 'pulse4all-subscriptions'), false),
       set_config('app.user_id', (select u.id::text from cma.app_user u join cma.tenant t on t.id = u.tenant_id
                                  where t.slug = 'pulse4all-subscriptions' and u.email = 'martin@pulse4all.com'), false),
       set_config('app.actor_label', 'studio:martin', false);
set role cma_app;
select a.deal_source_id, a.created_at, a.outcome, a.window_end_reason, coalesce(a.closed_at, a.ordered_at) as window_end, a.attempts,
       a.reached_attempts, a.first_reached_attempt, a.logged_without_aircall, a.last_attempt_at, a.record_url
from cma.attempts_per_deal_of(current_setting('app.tenant_id')::uuid, timestamptz '2026-09-30 22:00+00', now(), now()) a
order by md5(a.deal_source_id)
limit 10;
reset role;
```
Expected: ten rows, or fewer when October has fewer sales deals.

**Browser** (HubSpot, Pulse4all Subscriptions): open each `record_url`. On the deal's activity timeline, count the **outbound calls made through Aircall** on the deal and on its contacts: from just before the deal was created (the speed-to-lead pre-window, `speed_to_lead.pre_window_minutes`) up to `window_end` (its close, or the contacts' first order), or up to now while it is open.

Expected:
- the same number as `attempts` for each deal;
- `logged_without_aircall`: the outbound calls logged by hand in HubSpot in that window, with no Aircall call behind them; never attempts;
- `reached_attempts`: the attempts whose outcome counts as connected, or, without an outcome, with at least 30 seconds of talk;
- `last_attempt_at`: the newest attempt.

A difference has a reason; write it down per deal (id, the CMA's attempts, HubSpot's calls, the reason):
- an inbound call (never an attempt);
- a call before the pre-window, or after the close or the first order;
- a call on a contact no longer associated with the deal;
- a deleted call;
- a call on a line that does not count (Configuration → Sources → Aircall → Lines);
- a call logged in the last minutes, which the mirror has not read yet.

Anything else: send me the deal's id and both counts.

## 10. Prod: the hand checks and the request log

**Browser** (prod, as yourself, after `SUCCESS`)
1. `https://workspace.pulse4all.app/reports/attempts?range=month`. Expected:
   - the note under the title names telephony calls and 30 seconds;
   - six tiles: deals, attempted (a share), attempts per deal, reached at least once (a share), median speed to lead, open with no attempt;
   - How complete the calls are, Won against lost (deals not decided below it), and five cards of horizontal bars, no donut;
   - the table per day and the deals list with "Showing n of total" and a link per deal; no name, address or phone number;
   - a deal of step 9 shows the same attempts in the list.
2. In the deals list, Tab to a deal and press Enter. Expected: its attempts in order below it (start, answered, talk time, reached, call outcome; no agent column while `reports.per_person` holds `email` only). Press Esc: it closes, the focus stays on the deal.
3. Press G three times (by week, market, pipeline). Then choose a market (K), Attempts: No attempt yet (A) and Outcome: Open (O). Expected: the figures change with the address (`market`, `attempted`, `outcome`), and the page never scrolls sideways.
4. `https://workspace.pulse4all.app/reports/attempts-per-agent`. Expected: the not-found page, and no Attempts per agent in the rail. Pulse4all keeps `reports.per_person` at `email` until Yordi agrees (Open decisions).
5. The rail. Expected:
   - Reports: Dashboard, Speed to lead, Calls, Calls per agent, Email, Email per agent, Follow-up, Attempts per deal, (Attempts per agent,) Forms, Intake, Inbound, First orders, (Orders per person,) Data quality;
   - Configuration: Team and skills, Statuses, Absences and coverage, Markets, Sources, App links, Exports, Alert rules, System health;
   - the digit keys follow the new order.
6. `https://workspace.pulse4all.app/live/board`. Expected: Missed, not called back is the last section, under the team.
7. Messages → Send a message. Send a test message to yourself only (People: your name), titled "Test 0008z". In the sent list, click **Delete** on that row. Expected:
   - "Delete this message for everyone? Recipients will no longer see it.", with Cancel focused;
   - Delete: the row shows Deleted, and Messages (your inbox) no longer lists it.
   Delete only that test message.
8. Welcome on open. Close every window of the browser, open it again and open `https://workspace.pulse4all.app/reports/calls`. Expected: after the sign-in, if any, Welcome. Then open the same address again: Reports → Calls. An installed Workspace app opens on Welcome.

**Terminal** (the request lines of those page loads: route, status, total and database milliseconds; RUNBOOK section 6)
```bash
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="cma-web" AND jsonPayload.message="request" AND (jsonPayload.route=~"^/reports/attempts" OR jsonPayload.route=~"^/api/v1/reports/attempts" OR jsonPayload.route="/reports/speed-to-lead")' \
  --project=p4a-cma-prod --freshness=30m --limit=30 \
  --format='table(timestamp, severity, jsonPayload.route, jsonPayload.status, jsonPayload.totalMs, jsonPayload.dbMs, jsonPayload.tx, jsonPayload.rt)'
```
Expected:
- `/reports/attempts` with `200` and `dbMs` under about 500, severity `INFO`;
- `/api/v1/reports/attempts/deals/[dealId]` with `200` and `dbMs` under 100;
- `/reports/attempts-per-agent` with `404`.

Open Speed to lead once too, for a comparison of `totalMs - dbMs` with Attempts per deal: on 20 October 2026 Attempts per deal spent 519 to 933 ms in all for 203 to 244 ms in the database (the measurement in this pull request's description).

## 11. Dev and prod: the drift check

`tools/drift/functions.sql` lists every function of `cma` and `cma_read` with an md5 of its definition, one line each, sorted. Both instances ran the same scripts, so the two lists are the same. Read only; signatures and hashes, no data.

**Terminal** (from the Chromebook, `~/cma` on `main` after the merge)
```bash
cd ~/cma && cma_db dev && psql "$PGCONN" -X -qAt -v ON_ERROR_STOP=1 -f tools/drift/functions.sql > /tmp/fn-dev.txt; wc -l < /tmp/fn-dev.txt
cma_db prod && psql "$PGCONN" -X -qAt -v ON_ERROR_STOP=1 -f tools/drift/functions.sql > /tmp/fn-prod.txt; wc -l < /tmp/fn-prod.txt
diff /tmp/fn-dev.txt /tmp/fn-prod.txt && echo "no drift"
```
Expected: `475` twice, then `no drift`. A line that differs names the function: `<` is dev's, `>` prod's. Send me the lines; nothing is changed by hand. Locally, a database at 0008y against one at 0008z gave 466 and 475 lines and exactly 0008z's functions (`local-records-0008z/drift/diff-0008y-0008z.txt`).

Send me the outputs of steps 1 to 4 and 7, the rows of steps 8 and 9, the hand checks of step 10 and the table, and step 11's result. A record of them follows from your report (`docs/attempts-2026-10/records/`, written down from it, as in PRs #120 and #121).

**Naming.** 0008z is the last single letter after 0008. The next addition's version is open (README, Open decisions): `0009` for the next addition, or `0008za` keeping the series.
