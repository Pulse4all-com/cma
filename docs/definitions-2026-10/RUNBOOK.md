# Runbook, definitions step 1: tag meanings, Connected and Conversation (addition 0008zc, `100`, `101`)

Labels:
- **Browser**: a page or a click path.
- **Terminal**: Martin's own Linux terminal (Chromebook Linux or his Linux machine), in `~/cma` unless stated. A step against prod (`p4a-cma-prod`, `cma-prod-pg`) runs from the Chromebook only.
- **Studio**: Cloud SQL Studio, on the instance named. Check the instance in Studio's breadcrumb before every Run.
- **File**: a repository path.

SQL and shell never share a block. Studio shows no notices and one result per statement: a verify's verdict table sits in the results dropdown, before the last results. Every Studio block here reads ids, codes, counts, tag names (configuration), settings and milliseconds only, never a customer row (README, Where a command runs). Every Studio block starts with `set role cma_owner;` and ends with `reset role;`. Every step ends with what you should see. Claude Code's local outputs are in `local-records/`, and its `README.md` lists them.

**The rules for every block below** (as in `docs/RUNBOOK.md`, section 7):
- **Whose user.** A block that acts as a person names the email, with the reason. Dev blocks use the dev seed's admin, `admin@example.com`; prod blocks use `martin@pulse4all.com`.
- **Provoked runs.** Paste the verify script, press Ctrl+F, search `'verify.provoke', 'false'` and change only that `false` to `true`. Run. Result 1 in the dropdown must read `true`; if it reads `false`, the edit did not take.
- **Long verifies run from the Terminal.** Studio stops a statement at 300 seconds. `91` and `99` go through the Auth Proxy:
  ```bash
  cma_db dev && time psql "$PGCONN" -X -v ON_ERROR_STOP=1 -f db/<file> > /tmp/<n>.txt 2>&1; tail -40 /tmp/<n>.txt
  ```
  `<file>` is the script, `<n>` its number.

**What changes** (docs/definitions.md: Connected, Not connected, Connected rate, Conversation, Talk time, Tag, Untagged):
- **Connected** is Aircall's: an outbound call answered by the recipient or their voicemail, any duration. `telephony.connected_min_seconds` defaults to 0, and `100` moves a tenant value of 10 (both Pulse4all tenants) to 0; a value above 0 adds a talk condition.
- **Conversation** is one rule for every figure: a connected outbound or answered inbound call with at least `calls.conversation_min_talk_seconds` of talk (30; the setting replaces `attempts.reached_min_talk_seconds`, whose values `100` copies) and no current tag meaning **not reached**. The CRM call outcome decides nothing any more (R1); a CRM call is a conversation only through its linked telephony call.
- **Tag meanings**: each tag of a telephony connection can carry one meaning (Not reached, Call type, Courtesy attempt, Courtesy completed positive, neutral or negative), set on Configuration → Sources, Tags; ingest never writes it. Only Not reached is read now. The call outcomes' connected switch and its rule leave the Sources page (the list stays).
- **Talk time** on Reports → Calls runs over every answered call with talk time; **Untagged** counts every call without a tag, missed ones included, over all calls.
- **Names**: a CRM call's conversation is `cma.crm_call_conversation_of` (`is_conversation`), in place of `cma.crm_call_connected_of`, which `100` drops: connected is no conversation (docs/definitions.md, convention 1). Email's not-responding read calls the new one.
- **The API** (`/api/v1`, a breaking change): Calls and Calls per agent answer `connected`, `connectedRate`, `untagged` (were `connectedOutbound`, `connectedPct`, `untaggedConversations`); Attempts per deal and per agent answer `conversation*` (were `reached*`); one deal's attempts answer `connected` and `conversation` (were `answered`, `reached`, `reachedBy`). No reader outside the repository's own web app is known; anything you built on these fields (a Make scenario, a sheet) needs the new names.
- No `cloudbuild.yaml` change, no environment variable, no ingest change, no HubSpot or Aircall change.

**Order matters:**
- `100` changes the columns and arguments of the Calls and Attempts reads. The web of `main` reads the old ones, so **between `100` in prod and the deploy of this merge, Reports → Calls, Calls per agent, Attempts per deal and Attempts per agent answer an error**. Run steps 8 and 9 in one sitting outside every market's office hours (before 09:00 or after 18:00 Amsterdam time), and merge right after `100` (step 9).
- Dev runs `main`'s web image (`docs/RUNBOOK.md`, section 4) until step 9 puts this merge's image there. From `100` in dev (step 1) until then, dev's Calls and Attempts pages answer an error; the verifies prove dev's database meanwhile, and step 4 sets dev's tag meanings in Studio, through the function the Sources page calls.
- The data map: `docs/datamap/catalog.json` describes `telephony_tag.meaning` and the renamed columns of `attempts_per_deal`. `verify:datamap` fails on this branch until step 5 refreshes `schema.json` from dev.
- Kira and Arno hear of the changed figures before prod (step 7).

| Step | What | Elapsed |
|---|---|---|
| 0 | Review the pull request, build it, check the additions | 10 min |
| 1 | Dev: `100` twice with the fingerprint | 5 min |
| 2 | Dev: `101` normal and provoked | 3 min |
| 3 | Dev: the earlier verifies again (`91` and `99` from the Terminal) | 25 min |
| 4 | Dev: the tag meanings in Studio | 3 min |
| 5 | The data map: snapshot from dev, rebuild, push | 5 min |
| 6 | Dev and prod: the drift check before | 3 min |
| 7 | Tell Kira and Arno | 5 min |
| 8 | Prod: point-in-time recovery, `100` twice with the fingerprint | 5 min (outside office hours) |
| 9 | Prod: merge at once, watch the build, the dev image | 15 min (outside office hours) |
| 10 | Prod: the timings as `cma_app` | 3 min |
| 11 | Prod: the tag meanings on Configuration → Sources | 5 min |
| 12 | Prod: the check against Aircall for 23 October 2026 | 15 min |
| 13 | Prod: the hand checks | 10 min |
| 14 | Dev and prod: the drift check after | 3 min |

---

## 0. Review the pull request, build it, check the additions

**Browser:** GitHub → Pulse4all-com/cma → Pull requests → "Definitions step 1: tag meanings, Connected and Conversation (0008zc)". Read the description and the diff.

Expected:
- in `db/`, the new `100_definitions_calls.sql` and `101_verify_definitions_calls.sql`; `02_seed_pulse4all.sql` (the connected threshold 0); `63`, `85`, `91`, `93` and `95` amended, each header naming what changed;
- under `web/`, the Calls, Calls per agent, Attempts and Configuration (Sources, Exports) pages and components, the data layer, `lib/reports.ts`, `lib/attempts.ts`, `lib/sources.ts`, the copy, the metric catalog and the verifiers;
- `docs/definitions-2026-10/` (this runbook and `local-records/`), `docs/definitions.md`, the metric catalog, the data model, API, features, KPIs, decisions, open decisions, `docs/datamap/catalog.json` and `CHANGELOG.md`;
- nothing under `cloudbuild.yaml`, `ingest/`, `records/` or `hubspot/`.

**Terminal** (the pull request's number from the page)
```bash
cd ~/cma && gh pr checkout <number> && cd web && npm ci --no-audit --no-fund 2>&1 | tail -1 && npm run build > /tmp/build.txt 2>&1; echo "build exit: $?"; npm run typecheck 2>&1 | tail -1; npm run verify:reports 2>&1 | tail -1; npm run verify:metrics 2>&1 | tail -1; cd ~/cma
```
Expected:
- `found 0 vulnerabilities`, or the known advisories of Open decisions;
- `build exit: 0`;
- `✓ Types generated successfully`;
- `ALL 183 PASS`;
- `ok`.

**Do not merge yet.**

**Studio (cma-dev-pg)** and **Studio (cma-prod-pg)** (read only)
```sql
set role cma_owner;
select version, applied_at from cma.schema_migration where version >= '0008zb' order by 1;
reset role;
```
Expected on both instances: `0008zb` only. Without `0008zb`, run `docs/funnel-2026-10/RUNBOOK.md` first. With `0008zc` already there, stop and tell me.

## 1. Dev: `100` twice with the fingerprint

**Studio (cma-dev-pg)** (read only: the fingerprint of the functions, views, tables and the settings)
```sql
set role cma_owner;
select (select count(*) from pg_proc p where p.pronamespace in ('cma'::regnamespace, 'cma_read'::regnamespace)) as functions,
       (select md5(string_agg(p.oid::regprocedure::text || pg_get_functiondef(p.oid), '' order by p.oid::regprocedure::text))
          from pg_proc p where p.pronamespace in ('cma'::regnamespace, 'cma_read'::regnamespace) and p.prokind = 'f') as functions_md5,
       (select count(*) from pg_class c where c.relkind = 'v' and c.relnamespace in ('cma'::regnamespace, 'cma_read'::regnamespace)) as views,
       (select count(*) from pg_class c where c.relkind = 'r' and c.relnamespace = 'cma'::regnamespace) as tables,
       (select string_agg(s.key || '=' || s.default_value, ' ' order by s.key) from cma.setting s
         where s.key in ('telephony.connected_min_seconds', 'calls.conversation_min_talk_seconds', 'attempts.reached_min_talk_seconds')) as settings,
       (select string_agg(m.version, ' ' order by m.version) from cma.schema_migration m where m.version >= '0008zb') as additions;
reset role;
```
Expected: one row, `settings` `attempts.reached_min_talk_seconds=30 telephony.connected_min_seconds=10`, `additions` `0008zb`. Write down `functions`, `views` and `tables` (locally 515, 126 and 85; dev's own counts are the reference below).

**File:** `db/100_definitions_calls.sql`: open it and copy all of it.

**Studio (cma-dev-pg):** paste the whole script and Run.

Expected: no error; Studio's last result is `reset role`. `addition 0008zb (98_funnel.sql) must run before 0008zc` means step 0 found no `0008zb`.

**Studio (cma-dev-pg):** the fingerprint block again.

Expected: `functions` 4 more (`cma.is_connected`, `cma.is_conversation`, `cma.call_not_reached_of` and `cma.set_telephony_tag_meaning` new; `cma.crm_call_conversation_of` in place of `cma.crm_call_connected_of`, which `100` drops), `views` and `tables` the same, `settings` `calls.conversation_min_talk_seconds=30 telephony.connected_min_seconds=0`, `additions` `0008zb 0008zc` (locally 519, 126 and 85). Write down `functions_md5`.

**Studio (cma-dev-pg):** paste `100` again and Run; then the fingerprint block again.

Expected: the same row, `functions_md5` included: the second run adds nothing (locally `local-records/db/fingerprint-after-100.txt` and `-rerun.txt`).

**Studio (cma-dev-pg)** (read only: the tenants' own values of the two thresholds)
```sql
set role cma_owner;
select t.slug, s.key, s.value
from cma.tenant_setting s join cma.tenant t on t.id = s.tenant_id
where s.key in ('telephony.connected_min_seconds', 'calls.conversation_min_talk_seconds', 'attempts.reached_min_talk_seconds')
order by 1, 2;
reset role;
```
Expected: `telephony.connected_min_seconds` 0 for both Pulse4all tenants (was 10); no row for `attempts.reached_min_talk_seconds`; a `calls.conversation_min_talk_seconds` row only where a tenant had its own reached threshold (locally none: the default 30 applies).

## 2. Dev: `101` normal and provoked

**File:** `db/101_verify_definitions_calls.sql`: copy all of it. **Studio (cma-dev-pg):** paste and Run. Open the results dropdown at the verdict table.

Expected: rows `A1` to `A6` and `B1` to `B12`, each `PASS`, and the verdict `PASS`, 18 PASS. `REFUSED: not dev` means the instance is not dev's. Any `FAIL`: send me the row.

**Studio (cma-dev-pg):** `101` again, provoked (the rule above).

Expected: every row `FAIL`, the verdict `PROVOKED`, 0 PASS, 18 FAIL. Block B rolls back.

## 3. Dev: the earlier verifies again (`91` and `99` from the Terminal)

**Studio (cma-dev-pg):** each of these files, copied whole, pasted and Run, one at a time: `db/63_verify_calls_overview.sql`, `db/95_verify_attempts_for_sales.sql`, `db/41_verify_lead_metrics.sql`, `db/75_verify_forms_reporting.sql`, `db/83_verify_email_reports.sql`, `db/85_verify_first_orders.sql`, `db/93_verify_attempts_per_deal.sql`.

Expected, in the verdict table of each: every row `PASS` (`63` 19, `95` 36, `83` 26, `85` 26, `93` 25; `41` and `75` as before). `63`, `83`, `85`, `93` and `95` are amended for 0008zc: their headers say which checks changed and why (connected at any talk time, conversations at 30 seconds, untagged over every call, conversations from the telephony call only, and `83` the CRM call's conversation under its new name).

**Terminal** (from `~/cma` on the branch)
```bash
cma_db dev && time psql "$PGCONN" -X -v ON_ERROR_STOP=1 -f db/91_verify_report_speed.sql > /tmp/91.txt 2>&1; tail -40 /tmp/91.txt
```
Expected: 13 rows `PASS` and the verdict PASS (locally in about 100 seconds; `91` is amended too: the first orders' evidence as 0008zc defines it).

**Terminal**
```bash
cma_db dev && time psql "$PGCONN" -X -v ON_ERROR_STOP=1 -f db/99_verify_funnel.sql > /tmp/99.txt 2>&1; tail -40 /tmp/99.txt
```
Expected: 33 PASS, as at 0008zb (`99` checks the settings `100` also changes and passes unchanged).

## 4. Dev: the tag meanings in Studio

Dev's `cma-web` runs `main`'s image until step 9, so this branch's Meaning column on Configuration → Sources, Tags is not in dev yet. This block sets dev through `cma.set_telephony_tag_meaning`, the function the Sources page calls: every tag whose name starts with "Not Reached" (any case, so also "Not Reached - Voicemail") gets the meaning not reached; nothing else is set.

**Studio (cma-dev-pg)** (writes configuration as `admin@example.com`, the dev seed's admin, who holds `tenant.configure`; the audit names `studio:martin`. Rerunnable)
```sql
set role cma_owner;
drop table if exists pg_temp.dev_ctx;
create temp table dev_ctx as
  select t.id as tenant_id,
         (select u.id from cma.app_user u where u.tenant_id = t.id and u.email = 'admin@example.com') as user_id
  from cma.tenant t where t.slug = 'pulse4all-subscriptions';
drop table if exists pg_temp.dev_result;
create temp table dev_result (connection text, tag text, is_counted boolean, meaning text);
grant select on dev_ctx to cma_app;
grant select, insert on dev_result to cma_app;
set role cma_app;
do $$
declare
  c record;
  g record;
begin
  select * into c from dev_ctx;
  if c.user_id is null then
    raise exception 'no admin@example.com in pulse4all-subscriptions: run this block on cma-dev-pg';
  end if;
  perform set_config('app.tenant_id', c.tenant_id::text, true);
  perform set_config('app.user_id', c.user_id::text, true);
  perform set_config('app.actor_label', 'studio:martin', true);
  -- a tag named "Not Reached" (any case, also "Not Reached - Voicemail") means not reached; nothing else is set
  for g in select tg.connection_id, tg.tag_ref from cma.telephony_tag tg
           where tg.tenant_id = c.tenant_id and lower(tg.name) like 'not reached%' loop
    perform cma.set_telephony_tag_meaning(g.connection_id, g.tag_ref, 'not_reached');
  end loop;
  insert into dev_result
  select ic.name, tg.name, tg.is_counted, coalesce(tg.meaning, '-')
  from cma.telephony_tag tg join cma.integration_connection ic on ic.tenant_id = tg.tenant_id and ic.id = tg.connection_id
  where tg.tenant_id = c.tenant_id;
end
$$;
select connection, tag, is_counted, meaning from dev_result order by connection, tag;
reset role;
```
Expected: one row per tag of dev's telephony connections; the "Not Reached" ones read `not_reached`, every other `-`. No row at all: dev has no telephony tag, and Conversation counts on talk time alone there (which the Sources page will say, step 9). Locally, on the fixture's three tags with one renamed "Not Reached", that one read `not_reached`.

## 5. The data map: snapshot from dev, rebuild, push

As `docs/datamap/README.md`, Refreshing the snapshot, on this branch: the snapshot from dev, `node tools/datamap/build.mjs && node tools/datamap/build.mjs --check`, then commit `docs/datamap/schema.json` and `docs/datamap/index.html` and push.

Expected: `datamap: 85 tables, 117 views, all described; index.html current` (dev's counts when dev holds no table of its own); `latest_migration` `0008zc`; then `npm run verify:datamap` in `web/` passes on the branch.

## 6. Dev and prod: the drift check before

**Terminal**
```bash
cma_db dev && psql "$PGCONN" -X -qAt -f tools/drift/functions.sql > /tmp/drift-dev.txt; cma_db prod && psql "$PGCONN" -X -qAt -f tools/drift/functions.sql > /tmp/drift-prod.txt; diff /tmp/drift-dev.txt /tmp/drift-prod.txt | head -20; wc -l /tmp/drift-dev.txt /tmp/drift-prod.txt
```
Expected: dev now has the 0008zc functions and prod not yet, so the diff lists exactly the functions `100` creates or replaces (the calls, attempts, first orders, data-quality and settings functions) and nothing else. A line outside those is drift from before: send it to me before step 8.

## 7. Tell Kira and Arno

Before prod, send Kira and Arno (Slack or email, your words) what changes in their figures from the merge on, and why:
- **Connected rate goes up.** A call a voicemail box answers is connected, as in Aircall: Connected is Aircall's connected now (was: at least 10 seconds of talk). Reports → Calls and Calls per agent match Aircall's connected and Connected rate.
- **Conversations change.** One rule everywhere: a connected or answered call with at least 30 seconds of talk and no tag meaning Not reached. Outbound calls of 10 to 29 seconds stop counting; inbound calls under 30 seconds stop counting; a call tagged "Not Reached" stops counting once its tag has that meaning (step 11). On Attempts per deal the call outcome logged in HubSpot no longer decides anything: a call tagged "Not Reached" is no conversation, a 45-second call logged as "Left voicemail" without that tag is one. First orders and Email's not-responding deals follow the same rule.
- **Untagged** on Reports → Calls is now a share of all calls (missed ones included), as in Aircall, and **talk time** averages over every answered call.
- **Performance did not change.** Nobody's calls changed; only the definitions did, so the history moves with them (every period is recomputed with the new rules).

Nothing to run in this step.

## 8. Prod: point-in-time recovery, `100` twice with the fingerprint

**Outside every market's office hours: before 09:00 or after 18:00 Amsterdam time.** Steps 8 and 9 run in one sitting: from `100` until the deploy of step 9, Reports → Calls, Calls per agent, Attempts per deal and Attempts per agent answer an error (Order matters, above).

**Terminal**
```bash
gcloud sql instances describe cma-prod-pg --project=p4a-cma-prod --format='value(settings.backupConfiguration.pointInTimeRecoveryEnabled)'
```
Expected: `True`. Otherwise stop. Write down the time: it is the point to recover to if `100` must be undone.

**Studio (cma-prod-pg):** the block of step 0 again. Expected: `0008zb` only.

**Studio (cma-prod-pg):** the fingerprint block of step 1. Write down the row.

**Studio (cma-prod-pg):** `db/100_definitions_calls.sql`, Run; the fingerprint; `100` again; the fingerprint; then the tenants' values block of step 1.

Expected: no error; the same `functions`, `views` and `tables` counts as dev's in step 1, the same row after the second run; both Pulse4all tenants at `telephony.connected_min_seconds` 0. A `functions_md5` that differs from dev's with the same counts: `tools/drift/functions.sql` names the functions that differ (`docs/RUNBOOK.md`, 7b).

No verify runs in prod: `101` and the amended verifies refuse a database without the dev seed.

## 9. Prod: merge at once, watch the build, the dev image

**Browser:** the pull request → Squash and merge. Then Cloud Build (`p4a-cma-prod`) → History: the `cma-web-main` build of the merge.

Expected: `SUCCESS`, the new `cma-web` revision serving (`docs/RUNBOOK.md`, section 3). From here the Calls and Attempts pages answer again.

Then put the merge's image on dev, as `docs/RUNBOOK.md`, section 4, with the short SHA of this build. Expected: `curl -s localhost:8080/api/health` names that SHA; in dev Configuration → Sources, the telephony connection's Tags card shows a Meaning column with the "Not Reached" tags at Not reached (step 4).

## 10. Prod: the timings as `cma_app`

**Studio (cma-prod-pg)** (read only: the page reads of this month as `martin@pulse4all.com`, best of three each; milliseconds only, the answers are discarded)
```sql
set role cma_owner;
drop table if exists pg_temp.def_timing;
create temp table def_timing (read text, ms numeric);
grant select, insert on def_timing to cma_app;
drop table if exists pg_temp.def_ctx;
create temp table def_ctx as
  select t.id as tenant_id, u.id as user_id from cma.tenant t join cma.app_user u on u.tenant_id = t.id
  where t.slug = 'pulse4all-subscriptions' and u.email = 'martin@pulse4all.com';
grant select on def_ctx to cma_app;
set role cma_app;
do $$
declare
  c record; r record; i int; t0 timestamptz; best numeric;
  v_from date := date_trunc('month', now() at time zone 'Europe/Amsterdam')::date;
  v_to   date := (now() at time zone 'Europe/Amsterdam')::date;
begin
  select * into c from def_ctx;
  if c.user_id is null then
    raise exception 'no martin@pulse4all.com in pulse4all-subscriptions';
  end if;
  perform set_config('app.tenant_id', c.tenant_id::text, true);
  perform set_config('app.user_id', c.user_id::text, true);
  for r in select * from (values
      ('calls_overview', format('select count(*) from cma.calls_overview(%L, %L, null, null, ''day'')', v_from, v_to)),
      ('calls_tag_use', format('select count(*) from cma.calls_tag_use(%L, %L, null, null, ''day'')', v_from, v_to)),
      ('calls_per_person', format('select count(*) from cma.calls_per_person(%L, %L, null, null)', v_from, v_to)),
      ('calls_per_person_tags', format('select count(*) from cma.calls_per_person_tags(%L, %L, null, null)', v_from, v_to)),
      ('attempts_per_deal_page', format('select count(*) from cma.attempts_per_deal_page(%L, %L, ''day'', null, null)', v_from, v_to)),
      ('first_orders_page', format('select count(*) from cma.first_orders_page(%L, %L, ''day'', null, null)', v_from, v_to))) x(read, sql) loop
    best := null;
    for i in 1..3 loop
      t0 := clock_timestamp();
      execute r.sql;
      best := least(coalesce(best, 1e9), extract(epoch from clock_timestamp() - t0) * 1000);
    end loop;
    insert into def_timing values (r.read, round(best, 1));
  end loop;
end
$$;
select read, ms from def_timing order by read;
reset role;
```
Expected: six rows, each under 1000 ms. Locally, on `91`'s tenant at prod's volume of 19 October 2026, the Calls reads take about twice what they took at 0008zb (`calls_overview` 147 ms against 73, `calls_per_person_tags` 204 against 89: Conversation now reads each call's tags) and the Attempts read the same (55 ms); `local-records/db/calls-reads-timing.txt`. Send me the rows. `CMA06` means `martin@pulse4all.com` holds neither `reports.view` nor `performance.team`.

## 11. Prod: the tag meanings on Configuration → Sources

**Browser:** Configuration → Sources → the Aircall connection → Tags. Before any meaning is set, the card says "No tag means not reached yet, so Conversation counts on talk time alone."

Set **Meaning** to **Not reached** on every "Not Reached" tag (each saves on its own). Give the other tags a meaning only where you know it (Call type, Courtesy attempt, Courtesy completed positive, neutral or negative); None is fine: only Not reached is read today.

Expected: the notice is gone; a tag's Counted switch stays as it was (it has no effect on Conversation); reloading the page shows the meanings kept. The next catalog refresh (hourly) keeps them.

## 12. Prod: the check against Aircall for 23 October 2026

The reconciliation of 23 October 2026 (R2) found Calls, Talk time and Untagged identical to Aircall. Now Connected and Conversation are Aircall's too, so the same day is checked again.

**Studio (cma-prod-pg)** (read only: the figures of Friday 23 October 2026 as `martin@pulse4all.com`; counts and seconds only)
```sql
set role cma_owner;
drop table if exists pg_temp.def_ctx;
create temp table def_ctx as
  select t.id as tenant_id, u.id as user_id from cma.tenant t join cma.app_user u on u.tenant_id = t.id
  where t.slug = 'pulse4all-subscriptions' and u.email = 'martin@pulse4all.com';
drop table if exists pg_temp.def_check;
create temp table def_check (n int, figure text, value text);
grant select on def_ctx to cma_app;
grant select, insert on def_check to cma_app;
set role cma_app;
do $$
declare
  c record;
  o record;
begin
  select * into c from def_ctx;
  if c.user_id is null then
    raise exception 'no martin@pulse4all.com in pulse4all-subscriptions';
  end if;
  perform set_config('app.tenant_id', c.tenant_id::text, true);
  perform set_config('app.user_id', c.user_id::text, true);
  select * into o from cma.calls_overview(date '2026-10-23', date '2026-10-23', null, null, 'day')
  where period = 'current' and group_key is null;
  insert into def_check values
    (1, 'calls', o.calls), (2, 'inbound', o.inbound), (3, 'outbound', o.outbound), (4, 'answered inbound', o.answered_inbound),
    (5, 'connected', o.connected), (6, 'connected rate', o.connected_rate), (7, 'conversations', o.conversations),
    (8, 'talk time, seconds', o.talk_seconds_total), (9, 'talk time, average seconds', o.talk_seconds_avg), (10, 'untagged', o.untagged);
  insert into def_check
  select 11, 'conversations, outbound', count(*) filter (where k.direction = 'outbound' and k.is_conversation)
  from cma.calls_of(c.tenant_id, timestamptz '2026-10-22 00:00+00', timestamptz '2026-10-25 00:00+00', null, null) k
  where k.business_date = date '2026-10-23';
  insert into def_check
  select 12, 'conversations, inbound', count(*) filter (where k.direction = 'inbound' and k.is_conversation)
  from cma.calls_of(c.tenant_id, timestamptz '2026-10-22 00:00+00', timestamptz '2026-10-25 00:00+00', null, null) k
  where k.business_date = date '2026-10-23';
end
$$;
select n, figure, value from def_check order by n;
reset role;
```
Expected: twelve rows. Locally, on the dev seed with the fixture, 6, 4, 2, 1, 1, 50.0, 2, 225, 112.5, 6, 1 and 1.

**Browser** (Aircall Analytics, the Subscriptions preset, Friday 23 October 2026, the Amsterdam time zone):
- **Overview:** calls, inbound, outbound, answered inbound, connected outbound and the Connected rate, the talk time and its average, the untagged calls. Expected: rows 1 to 6 and 8 to 10 equal Aircall's figures.
- **Outbound+**, the minimum connected in-call time at 29 seconds and a tag filter that leaves out the "Not Reached" tags (untagged calls kept). Expected: the connected outbound calls it counts equal row 11. The inbound view of the same filter, where Aircall offers one: row 12.

Rows 11 and 12 equal Aircall only once step 11 has set the meanings. A difference is a bug, never a choice (docs/definitions.md, convention 2): send me the figure, Aircall's value and ours. Then write the result down in `records/` yourself, or send me the values and I write the record from your report.

## 13. Prod: the hand checks

**Browser** (prod, as yourself):
1. Reports → Calls, This month: the tiles say Connected and Connected rate; the Conversations hint names 30 seconds and the Not reached tags; Untagged reads "{n} of {calls} calls"; the tags card counts conversations per tag, with no untagged bar; the table's Untagged column a share of each row's calls.
2. Reports → Calls per agent: Connected, Untagged (the person's calls without a tag); an opened row shows counted tags only, no untagged bar.
3. Reports → Attempts per deal: the tiles and columns say Conversation; a deal's row opened shows Connected and Conversation per attempt, no "reached by".
4. Reports → First orders: the levels Conversation and Attempt.
5. Configuration → Exports: "Conversation: talk time of at least (seconds)" with 30, beside the connected threshold at 0.
6. Configuration → Sources → the HubSpot connection → Call outcomes: the list without a Connected column and without the rule button (O).

Expected: each as described; nothing reads "reached", "bereikt", "Connected share" or "in contact".

## 14. Dev and prod: the drift check after

**Terminal:** the block of step 6 again.

Expected: no line differs (`docs/RUNBOOK.md`, 7b). Locally a database built fresh to `101` and one migrated from `main` with `100` gave the same 519 lines (`local-records/db/drift.txt`).
