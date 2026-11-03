-- =============================================================================================
-- 123_verify_flash.sql: verifies addition 0008zn, Flash (overviews, daily snapshots, data quality, the watch)
-- =============================================================================================
-- Universal: no seed is assumed. Block A checks structure and privileges; blocks B and C work on throwaway tenants
-- inside subtransactions that are always rolled back, so nothing stays and the script runs in dev and in prod. Adapters,
-- handles, ids, codes, amounts and people are invented data values, and no row carries a name of a customer, an address,
-- an email or a phone number. Flows are read on fixed business dates (28 to 31 October 2026) and the takes run at fixed
-- instants, so the verdict does not depend on the day it runs; stock figures are as of the run, and the few that depend
-- on today (a device's end of life within three months) are seeded relative to it. Every check writes one row, ok or
-- FAIL, and the last row is the verdict (0008zn verified), because Cloud SQL Studio shows no notices. Run as your own IAM
-- login after 122_flash.sql, dev first, then prod.
-- Expected verdict, in dev and in prod (block C off, the default in every database): "0008zn verified | 123_verify_flash:
-- 39 ok, 0 FAIL, 4 skip" (43 checks: A1 to A8 and the B rows ok, C1 to C4 skip with "not run: volume off"); a local run
-- with verify.volume set to 'true' at the top: "0008zn verified | 123_verify_flash: 43 ok, 0 FAIL, 0 skip"; provoked
-- "PROVOKED, NOT A PASS | 123_verify_flash: 0 ok, 39 FAIL, 4 skip" (0 ok, 43 FAIL, 0 skip with the volume on). Flash's
-- speed on real data is 124_time_flash.sql's, run in prod after this script (PROD_RUNBOOK phase 16; in dev for
-- information only). Text is compared in collate "C" (every ordered string_agg), so the verdict is the same whatever the
-- database's collation (dev's en_US sorts "renewed" before "renew_failed", C the other way).
-- Reruns after 122 (dev; their objects are made again by 122): 121_verify_lead_cohorts.sql (22 PASS),
-- 113_verify_assets.sql (25 ok), 95_verify_attempts_for_sales.sql (36 PASS), 41_verify_lead_metrics.sql (every row
-- PASS), 119_verify_subscriptions.sql (23 PASS), 105_verify_reviews.sql (27 PASS), 81_verify_follow_up_snapshot.sql
-- (19 PASS); in prod 113 and 41 (the others refuse a database without the dev seed).
--   A  structure and privileges: the addition row after 0008zm; the four tables' columns; keys and checks (a snapshot
--      row's allow-lists and no @, one succeeded or missed run per date, one open finding per key, a month end's id list,
--      the settings' types and defaults, the job flash_snapshot without a connection, a value a snapshot cannot hold
--      written as other, the due date for 00:30, 23:20 and 23:59); row-level security with the tenant policy, the audit
--      trigger (not on the id lists), read only for the application (the take writes with the owner's rights), nothing
--      for the readers on the tables; flash.snapshot on every scheduler role and no assignable role; every function the
--      application's only and in the caller's rights, the take definer, the owner's, pinned, its writers the owner's
--      alone, no expiry with a caller's date; the reader views' exact columns, readable, without a personal column; the
--      six data-quality checks in their order with their views; the redefinitions carry what came before (0008zm's
--      settings trigger included)
--   B  behaviour, on two throwaway tenants (Europe/Amsterdam). Tenant one holds two stores (GB in GBP, NL in EUR), six
--      store customers, a subscriptions connection for the GB store with seven subscriptions (one in EUR) and their
--      events, an asset register with six devices, a CRM with contacts, deals, tickets and tasks, a review platform,
--      and the settings commerce.required_contact_refs and assets.required_refs; tenant two holds no source. Checked:
--      the settings' refusals; each overview's live figures equal the hand-computed ones; a take before
--      flash.snapshot_local_time writes nothing; a take stores exactly the live computation (all eleven overviews); a
--      second take of the date writes nothing; the id lists on a month's last day only; flows summed over dates equal
--      the live period; amounts per currency; not set up: no figures, never zeros; the six checks and their rows with the
--      system where each is fixed; the watch's five kinds raised and resolved; D2's hold and forget; tenant isolation;
--      the refusals (CMA06 for an agent and for a take as the analyst, CMA04, CMA02, no change by the application, a
--      finding reopened); the lists (filters, a measure's records, sorting within currency, a month end's frozen list);
--      the file record; no @ in anything stored; the job's own path (a take as the application with the scheduler user,
--      as of now). Tenant three (no source) takes the snapshot time's rule: each date once from its due time for 00:30,
--      23:20 and 23:59, a skipped run taken late, a missed date recorded and never taken (B20); a failing watch keeps the
--      snapshot (B23); two stale connections alike are one finding (B24). Then: a month end taken after midnight measures
--      against its own date (B21); a SKU with an @ (B25); writes only through the take (B22); the expiry without a
--      caller's date (B26); the ended statuses, a deleted contact, a market without devices, a reference in its market,
--      an expired list, a file record's filters; the required references empty: with_required_refs not applicable
--      live, in the snapshot and to the watch, no records, no required-reference finding (B27)
--   C  speed at volume, in local databases only, when verify.volume is set to 'true' at the top (off by default in
--      every database, so the four rows read skip in dev and prod: dev's shared core cannot carry the volume, its run
--      lost the connection after an hour on 3 November 2026; prod's speed on real data is 124_time_flash.sql's): a
--      throwaway tenant with 100,000 customers, 100,000 subscriptions, 50,000 devices and 200,000 orders: every live
--      overview but data quality under verify.max_overview_ms (the best of two) and the landing; every first page of a
--      list by every whitelisted sort key under verify.max_rows_ms (the best of two), as the application (row-level
--      security on); a full take under half the job's statement timeout (verify.job_statement_timeout_ms, the value
--      jobs/snapshot-flash.mjs sets); the data-quality overview and its lists under verify.max_dq_ms, a budget of their
--      own: they run every check of cma.data_quality_of live, the 24 that came before 0008zn included. The list and
--      data-quality budgets are proposed, looser than the brief's (see the settings below); the timings, and what is
--      over the brief's figures, are in the rows' detail
-- Provoke: set provoke below to true; every check must then read FAIL, and the verdict says PROVOKED, NOT A PASS.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);                 -- 'true' to make every check fail
-- Speed budgets at volume. Brief B21 (4.10) asks every live overview under 1,500 ms and every first page of a list under
-- 800 ms. Proposed in this build, for Martin to decide (docs/open-decisions.md, Flash speed at volume): lists under
-- 1,500 ms (README's p95 of a report) and data quality's overview and lists under 2,500 ms (they run every check of
-- cma.data_quality_of live, the 24 before 0008zn included). Every speed row names what is over the brief's figures too
select set_config('verify.max_overview_ms', '1500', false);          -- a live overview but data quality, as the application (the brief's)
select set_config('verify.max_rows_ms', '1500', false);              -- a first page of a list but data quality's (proposed; the brief's is 800)
select set_config('verify.max_dq_ms', '2500', false);                -- data quality's overview and first pages (proposed; the brief's is 1,500 and 800)
select set_config('verify.brief_rows_ms', '800', false);             -- the brief's budget of a first page, reported in the rows' detail
select set_config('verify.job_statement_timeout_ms', '240000', false); -- jobs/snapshot-flash.mjs, STATEMENT_TIMEOUT_MS
select set_config('verify.take_max_ms', (current_setting('verify.job_statement_timeout_ms')::integer / 2)::text, false);
-- block C (speed at volume) is off in every database; 'true' only in a local run (dev's shared core cannot carry its
-- volume; Flash's speed on real data is 124_time_flash.sql's, in prod)
select set_config('verify.volume', 'false', false);                  -- 'true' to run block C, local databases only

drop table if exists pg_temp.verify_0008zn;
create temp table verify_0008zn (ord int, check_name text, result text, detail text);

-- The error code a statement raises, or 'ok'
create or replace function pg_temp.v0008zn_code(p_sql text)
returns text
language plpgsql
as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end
$$;

-- The fastest of p_runs runs of a read, in milliseconds, every row fetched
create or replace function pg_temp.v0008zn_best_ms(p_sql text, p_runs integer)
returns numeric
language plpgsql
as $$
declare
  v_t0   timestamptz;
  v_ms   numeric;
  v_best numeric;
  r      record;
begin
  for i in 1 .. p_runs loop
    v_t0 := clock_timestamp();
    for r in execute p_sql loop
      null;
    end loop;
    v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
    v_best := least(coalesce(v_best, v_ms), v_ms);
  end loop;
  return v_best;
end
$$;

-- An overview's figures as one line: each grouping set's dims values and measures, in a fixed order
create or replace function pg_temp.v0008zn_figs(p_tenant uuid, p_overview text, p_from date, p_to date, p_on date default null)
returns text
language sql
as $$
  select coalesce(string_agg(
           coalesce(nullif((select string_agg(d.value #>> '{}', '/' order by d.key collate "C") from jsonb_each(c.dims) d), ''), '*') || ':'
           || (select string_agg(m.key || '=' || (m.value #>> '{}'), ',' order by m.key collate "C") from jsonb_each(c.measures) m),
           ' ' order by (select count(*) from jsonb_object_keys(c.dims)), c.dims::text collate "C"), '-')
  from cma.flash_compute_of(p_tenant, p_overview, p_from, p_to, p_on) c
$$;

-- The same for stored rows of a snapshot date (or summed dates)
create or replace function pg_temp.v0008zn_stored(p_tenant uuid, p_overview text, p_dates date[])
returns text
language sql
as $$
  select coalesce(string_agg(
           coalesce(nullif((select string_agg(d.value #>> '{}', '/' order by d.key collate "C") from jsonb_each(c.dims) d), ''), '*') || ':'
           || (select string_agg(m.key || '=' || (m.value #>> '{}'), ',' order by m.key collate "C") from jsonb_each(c.measures) m),
           ' ' order by (select count(*) from jsonb_object_keys(c.dims)), c.dims::text collate "C"), '-')
  from cma.flash_snapshot_sum_of(p_tenant, p_overview, p_dates) c
$$;

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_bad     text;
  v_fn      text;
  v_t       text;
begin
  -- A1. the addition is recorded, after 0008zm
  insert into verify_0008zn values (1, 'A1 addition 0008zn recorded, after 0008zm',
    case when exists (select 1 from cma.schema_migration where version = '0008zn')
              and exists (select 1 from cma.schema_migration where version = '0008zm') and not v_provoke then 'ok' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the four tables: columns with types and nullability
  v_bad := '';
  foreach v_t in array array[
    'flash_snapshot_run=id:uuid:NO,tenant_id:uuid:NO,snapshot_date:date:NO,due_at:timestamptz:NO,started_at:timestamptz:NO,finished_at:timestamptz:NO,'
      || 'status:text:NO,late:bool:NO,counts:jsonb:NO,sources:jsonb:NO,settings:jsonb:NO,missed_before:int4:NO,error:text:YES,watch_error:text:YES',
    'flash_snapshot=id:uuid:NO,tenant_id:uuid:NO,snapshot_date:date:NO,overview:text:NO,dims:jsonb:NO,measures:jsonb:NO,definition_version:text:NO,'
      || 'computed_at:timestamptz:NO,run_id:uuid:NO',
    'flash_snapshot_ids=tenant_id:uuid:NO,snapshot_date:date:NO,record_kind:text:NO,source_id:text:NO,connection_id:uuid:NO,market:text:NO,state:text:NO,run_id:uuid:NO',
    'flash_watch_finding=id:uuid:NO,tenant_id:uuid:NO,snapshot_date:date:NO,kind:text:NO,overview:text:YES,dims:jsonb:NO,measure:text:YES,value:numeric:YES,'
      || 'previous:numeric:YES,threshold:numeric:YES,detail:jsonb:NO,state:text:NO,resolved_on:date:YES,created_at:timestamptz:NO'] loop
    if (select string_agg(column_name || ':' || udt_name || ':' || is_nullable, ',' order by ordinal_position)
        from information_schema.columns where table_schema = 'cma' and table_name = split_part(v_t, '=', 1))
       is distinct from split_part(v_t, '=', 2) then
      v_bad := v_bad || split_part(v_t, '=', 1) || ' columns; ';
    end if;
  end loop;
  insert into verify_0008zn values (2, 'A2 the four tables'' columns, types and nullability',
    case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_bad);

  -- A3. keys and checks: a snapshot row's allow-lists, no @, an amount per currency; one row per date, overview and dims;
  --     one succeeded or missed run per date; one open finding per key; a month end's list; the job without a connection;
  --     the settings' types and defaults; a value a snapshot cannot hold written as other; the due date of every allowed
  --     snapshot time
  v_bad := '';
  if not cma.flash_row_ok('customers', '{"market": "GB"}', '{"active_customers": 3}')
     or cma.flash_row_ok('customers', '{"customer_id": "c1"}', '{"active_customers": 3}')
     or cma.flash_row_ok('customers', '{"market": "GB"}', '{"email": 1}')
     or cma.flash_row_ok('customers', '{"market": "a@b"}', '{"active_customers": 3}')
     or cma.flash_row_ok('customers', '{"market": "GB"}', '{"active_customers": "3"}')
     or not cma.flash_row_ok('orders', '{}', '{"orders": 1, "amount": {"EUR": 1.5, "GBP": 2}}')
     or cma.flash_row_ok('orders', '{}', '{"amount": {"eur": 1}}')
     or cma.flash_row_ok('nope', '{}', '{}') then
    v_bad := v_bad || 'row allow-lists; ';
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'cma.flash_snapshot'::regclass and contype = 'u'
                 and pg_get_constraintdef(oid) = 'UNIQUE (tenant_id, snapshot_date, overview, dims)')
     or to_regclass('cma.flash_snapshot_run_final_idx') is null
     or pg_get_indexdef(to_regclass('cma.flash_snapshot_run_final_idx')) not like '%UNIQUE%(tenant_id, snapshot_date) WHERE (status = ANY (ARRAY[''succeeded''::text, ''missed''::text]))'
     or to_regclass('cma.flash_snapshot_run_succeeded_idx') is not null
     or pg_get_indexdef('cma.flash_watch_finding_open_idx'::regclass) not like '%UNIQUE%WHERE (state = ''open''::text)'
     or (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.flash_snapshot_ids'::regclass and conname = 'flash_snapshot_ids_snapshot_date_check')
        not like '%1 mon -1 days%' then
    v_bad := v_bad || 'keys; ';
  end if;
  if (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.sync_run'::regclass and conname = 'sync_run_job_check') not like '%''flash_snapshot''%'
     or (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.sync_run'::regclass and conname = 'sync_run_connection_check')
        not like '%''refresh_follow_up''%''flash_snapshot''%'
     or cma.job_permission_of('flash_snapshot') is distinct from 'flash.snapshot' then
    v_bad := v_bad || 'the job; ';
  end if;
  if (select string_agg(s.key || ':' || s.value_type || ':' || s.default_value, ',' order by s.key collate "C") from cma.setting s
      where s.key like 'flash.%' or s.key in ('assets.required_refs', 'commerce.required_contact_refs'))
     is distinct from 'assets.required_refs:text:,commerce.required_contact_refs:text:,flash.active_subscription_statuses:text:active,'
                      || 'flash.ended_subscription_statuses:text:canceled,expired,'
                      || 'flash.file_max_rows:integer:50000,flash.id_list_retention_months:integer:84,flash.snapshot_local_time:time:00:30,'
                      || 'flash.watch_jump_min:integer:10,flash.watch_jump_pct:integer:20' then
    v_bad := v_bad || 'settings; ';
  end if;
  if cma.flash_dim_of('AED@PRO', 'none') <> 'other' or cma.flash_dim_of(repeat('x', 101), 'none') <> 'other' or cma.flash_dim_of('  ', 'none') <> 'none'
     or cma.flash_dim_of(null, 'unknown') <> 'unknown' or cma.flash_dim_of(' SKU-1 ', 'none') <> 'SKU-1' then
    v_bad := v_bad || 'dim values; ';
  end if;
  -- the due date: D is due at D + 1 at the snapshot time; the latest due date at an instant, for 00:30, 23:20 and 23:59
  if cma.flash_due_date_of('Europe/Amsterdam', '00:30', '2026-10-29 01:20 Europe/Amsterdam') <> '2026-10-28'
     or cma.flash_due_date_of('Europe/Amsterdam', '00:30', '2026-10-29 00:20 Europe/Amsterdam') <> '2026-10-27'
     or cma.flash_due_date_of('Europe/Amsterdam', '23:20', '2026-10-29 23:20 Europe/Amsterdam') <> '2026-10-28'
     or cma.flash_due_date_of('Europe/Amsterdam', '23:20', '2026-10-29 22:20 Europe/Amsterdam') <> '2026-10-27'
     or cma.flash_due_date_of('Europe/Amsterdam', '23:59', '2026-10-30 00:20 Europe/Amsterdam') <> '2026-10-28'
     or cma.flash_due_date_of('Europe/Amsterdam', '23:59', '2026-10-29 23:20 Europe/Amsterdam') <> '2026-10-27'
     or cma.flash_due_at_of('Europe/Amsterdam', '23:59', '2026-10-28') <> '2026-10-29 23:59 Europe/Amsterdam'::timestamptz then
    v_bad := v_bad || 'due dates; ';
  end if;
  if not cma.flash_keys_ok('{"market": "GB"}', array['market']) or cma.flash_keys_ok('{"id": "x"}', array['market'])
     or cma.flash_keys_ok('{"market": "a@b"}', array['market']) then
    v_bad := v_bad || 'finding keys; ';
  end if;
  insert into verify_0008zn values (3, 'A3 keys and checks: allow-lists, no @, per currency; one row, one succeeded run, one open finding; month end; job; settings',
    case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_bad);

  -- A4. tenant-aware: row-level security with the tenant policy; the audit trigger but on the id lists; read only for the
  --     application (no insert, update or delete: the take writes with the owner's rights; a finding's state guarded);
  --     nothing for the readers on the tables
  v_bad := '';
  foreach v_t in array array['cma.flash_snapshot_run', 'cma.flash_snapshot', 'cma.flash_snapshot_ids', 'cma.flash_watch_finding'] loop
    if not (select relrowsecurity from pg_class where oid = v_t::regclass)
       or not exists (select 1 from pg_policy where polrelid = v_t::regclass and polname = 'tenant_app')
       or exists (select 1 from pg_trigger where tgrelid = v_t::regclass and tgname = 'audit' and not tgisinternal) = (v_t = 'cma.flash_snapshot_ids')
       or not has_table_privilege('cma_app', v_t, 'select') or has_table_privilege('cma_app', v_t, 'insert')
       or has_table_privilege('cma_app', v_t, 'update') or has_table_privilege('cma_app', v_t, 'delete')
       or has_table_privilege('cma_readonly', v_t, 'select') then
      v_bad := v_bad || v_t || '; ';
    end if;
  end loop;
  if has_column_privilege('cma_app', 'cma.flash_watch_finding', 'state', 'update')
     or has_column_privilege('cma_app', 'cma.flash_watch_finding', 'resolved_on', 'update')
     or has_column_privilege('cma_app', 'cma.flash_watch_finding', 'value', 'update')
     or has_column_privilege('cma_app', 'cma.flash_snapshot', 'measures', 'update')
     or not exists (select 1 from pg_trigger where tgrelid = 'cma.flash_watch_finding'::regclass and tgname = 'guard_state' and not tgisinternal) then
    v_bad := v_bad || 'the finding''s state; ';
  end if;
  insert into verify_0008zn values (4, 'A4 row-level security, the audit trigger (not on the id lists), read only for the application, a finding''s state guarded, nothing for readers',
    case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_bad);

  -- A5. flash.snapshot: on every tenant's scheduler role, on no assignable role
  v_bad := '';
  if exists (select 1 from cma.tenant t
             where not exists (select 1 from cma.role_permission rp join cma.app_role r on r.tenant_id = rp.tenant_id and r.id = rp.role_id
                               where rp.tenant_id = t.id and r.key = 'scheduler' and rp.permission_key = 'flash.snapshot')) then
    v_bad := v_bad || 'a scheduler without it; ';
  end if;
  if exists (select 1 from cma.role_permission rp join cma.app_role r on r.tenant_id = rp.tenant_id and r.id = rp.role_id
             where rp.permission_key = 'flash.snapshot' and (r.is_assignable or r.key <> 'scheduler')) then
    v_bad := v_bad || 'an assignable role holds it; ';
  end if;
  if (select prosrc from pg_proc where oid = 'cma.ensure_scheduler_user(uuid)'::regprocedure) !~ 'workday\.close_forgotten.*follow_up\.refresh.*flash\.snapshot' then
    v_bad := v_bad || 'ensure_scheduler_user; ';
  end if;
  insert into verify_0008zn values (5, 'A5 flash.snapshot on every scheduler role, on no assignable role; ensure_scheduler_user grants it',
    case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_bad);

  -- A6. every function the application's only and in the caller's rights; the take definer, the owner's, pinned; its
  --     writers (the id lists, the expiry, the watch, the take at an instant) the owner's alone
  v_bad := '';
  foreach v_fn in array array[
    'cma.flash_list_of(text)', 'cma.flash_list_ok(text,text,integer,boolean)', 'cma.job_permission_of(text)', 'cma.job_run_start(text)',
    'cma.flash_overviews()', 'cma.flash_definition_version(text)', 'cma.flash_keys_ok(jsonb,text[])', 'cma.assert_flash_overview(text)',
    'cma.flash_row_ok(text,jsonb,jsonb)', 'cma.flash_active_statuses_of(uuid)', 'cma.flash_ended_statuses_of(uuid)', 'cma.flash_dim_of(text,text)',
    'cma.flash_subscription_stores_of(uuid)', 'cma.flash_sources_of(uuid)',
    'cma.flash_period_of(uuid,date,date)', 'cma.flash_customers_of(uuid)', 'cma.flash_subscriptions_of(uuid)', 'cma.flash_devices_of(uuid,date)',
    'cma.flash_churn_of(uuid,date,date)', 'cma.flash_orders_of(uuid,date,date)', 'cma.flash_order_lines_of(uuid,date,date)',
    'cma.flash_payments_of(uuid,date,date)', 'cma.flash_deals_of(uuid,timestamptz)', 'cma.flash_tickets_of(uuid,timestamptz)', 'cma.flash_tasks_of(uuid,date)',
    'cma.flash_reviews_of(uuid,date,date)', 'cma.data_quality_flash_checks()', 'cma.data_quality_of(uuid)', 'cma.data_quality()',
    'cma.data_quality_catalog()', 'cma.data_quality_fix_in(text,text)', 'cma.flash_findings_of(uuid)', 'cma.flash_finding_links_of(uuid,uuid,text,text)',
    'cma.flash_compute_of(uuid,text,date,date,date)', 'cma.flash_due_date_of(text,time,timestamptz)', 'cma.flash_due_at_of(text,time,date)',
    'cma.flash_id_ok(text,text,text)', 'cma.assert_flash_params(text,date,date,date,date)', 'cma.flash_labels_of(uuid,text)',
    'cma.flash_snapshot_sum_of(uuid,text,date[])', 'cma.flash_document_of(uuid,text,text,date,date,date)', 'cma.flash_overview(text,text,date,date,date)',
    'cma.flash_order_by(text,text,boolean)', 'cma.flash_rows_of(uuid,text,jsonb,text,boolean,integer,integer,date,date)',
    'cma.flash_id_rows_of(uuid,text,jsonb,text,boolean,integer,integer,date)', 'cma.flash_rows(text,jsonb,text,boolean,integer,integer,date,date,date)',
    'cma.flash_pick_of(jsonb,text,text)', 'cma.flash_stored_headline_of(uuid,text,text,date[])', 'cma.flash_headline(text,text,date,date)',
    'cma.flash_page(text,date,date,date)', 'cma.flash_snapshots(date,date)',
    'cma.data_quality_rows(text,text,integer,integer)', 'cma.flash_file_record(text,text,jsonb,text,date,date,date,integer)',
    'cma.ingest_upsert_contacts(uuid,jsonb)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure(v_fn) and a.grantee = 0) then
      v_bad := v_bad || v_fn || '; ';
    end if;
  end loop;
  v_fn := 'cma.flash_snapshot_take(uuid)';
  if to_regprocedure(v_fn) is null then
    v_bad := v_bad || v_fn || ' missing; ';
  elsif not (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
        or (select pg_get_userbyid(proowner) from pg_proc where oid = to_regprocedure(v_fn)) <> 'cma_owner'
        or not (select 'search_path=pg_catalog, cma, pg_temp' = any (proconfig) from pg_proc where oid = to_regprocedure(v_fn))
        or not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
        or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure(v_fn) and a.grantee = 0) then
    v_bad := v_bad || v_fn || '; ';
  end if;
  -- the writers: the owner's alone, in the caller's rights (the take's), and no expiry that takes a caller's date
  foreach v_fn in array array['cma.flash_snapshot_ids_write_of(uuid,date,uuid)', 'cma.flash_snapshot_ids_expire_of(uuid)',
                              'cma.flash_watch_of(uuid,date,timestamptz)', 'cma.flash_snapshot_take_at(uuid,timestamptz)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
          or (select pg_get_userbyid(proowner) from pg_proc where oid = to_regprocedure(v_fn)) <> 'cma_owner'
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure(v_fn) and a.grantee = 0) then
      v_bad := v_bad || v_fn || '; ';
    end if;
  end loop;
  if to_regprocedure('cma.flash_snapshot_ids_expire_of(uuid,date)') is not null then
    v_bad := v_bad || 'an expiry with a caller''s date; ';
  end if;
  if exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = 'cma.flash_watch_finding_guard()'::regprocedure and a.grantee = 0) then
    v_bad := v_bad || 'the guard; ';
  end if;
  insert into verify_0008zn values (6, 'A6 every function the application''s only and invoker; the take definer, pinned; its writers the owner''s alone',
    case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_bad);

  -- A7. the reporting views' exact columns, readable by the readers; no raw or personal column
  v_bad := '';
  foreach v_t in array array[
    'flash_snapshot=id,tenant_id,snapshot_date,overview,dims,measures,definition_version,computed_at,run_id',
    'flash_snapshot_run=id,tenant_id,snapshot_date,started_at,finished_at,status,counts,sources,settings,missed_before,error,due_at,late,watch_error',
    'flash_snapshot_ids=tenant_id,snapshot_date,record_kind,source_id,connection_id,market,state,run_id',
    'flash_watch_finding=id,tenant_id,snapshot_date,kind,overview,dims,measure,value,previous,threshold,detail,state,resolved_on,created_at',
    'dq_customer_required_ref_missing=tenant_id,connection_id,object_type,object_id,value',
    'dq_device_required_ref_missing=tenant_id,connection_id,object_type,object_id,value',
    'dq_subscription_customer_unmatched=tenant_id,connection_id,object_type,object_id,value',
    'dq_active_subscription_without_device=tenant_id,connection_id,object_type,object_id,value',
    'dq_device_subscription_ref_unknown=tenant_id,connection_id,object_type,object_id,value',
    'dq_field_device_on_ended_subscription=tenant_id,connection_id,object_type,object_id,value'] loop
    if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
        where table_schema = 'cma_read' and table_name = split_part(v_t, '=', 1)) is distinct from split_part(v_t, '=', 2) then
      v_bad := v_bad || split_part(v_t, '=', 1) || '; ';
    end if;
    if not has_table_privilege('cma_readonly', 'cma_read.' || split_part(v_t, '=', 1), 'select') then
      v_bad := v_bad || split_part(v_t, '=', 1) || ' not readable; ';
    end if;
  end loop;
  if exists (select 1 from information_schema.columns
             where table_schema = 'cma_read' and table_name like 'flash%'
               and column_name ~ '(raw|email|phone|mobile|address|first_name|last_name|full_?name|customer_name|postcode|city)') then
    v_bad := v_bad || 'a personal or raw column; ';
  end if;
  insert into verify_0008zn values (7, 'A7 the reporting views'' exact columns, readable; no raw or personal column',
    case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_bad);

  -- A8. the six data-quality checks (310 to 360) in the catalog, nothing twice; the redefinitions carry what came before
  v_bad := '';
  if (select string_agg(check_key || ':' || sort_order, ',' order by sort_order) from cma.data_quality_flash_checks())
     is distinct from 'customer_required_ref_missing:310,device_required_ref_missing:320,subscription_customer_unmatched:330,'
                      || 'active_subscription_without_device:340,device_subscription_ref_unknown:350,field_device_on_ended_subscription:360'
     or (select count(*) from cma.data_quality_catalog()) <> (select count(distinct check_key) from cma.data_quality_catalog())
     or (select count(*) from cma.schema_migration where version = '0008zn') <> 1 then
    v_bad := v_bad || 'the catalog or something twice; ';
  end if;
  if (select prosrc from pg_proc where oid = 'cma.data_quality_of(uuid)'::regprocedure) !~ 'outbound_unanswered_untagged'
     or (select prosrc from pg_proc where oid = 'cma.data_quality_of(uuid)'::regprocedure) !~ 'form_answer_not_in_options'
     or (select prosrc from pg_proc where oid = 'cma.data_quality_of(uuid)'::regprocedure) !~ 'market_without_review_channel'
     or (select prosrc from pg_proc where oid = 'cma.data_quality_of(uuid)'::regprocedure) !~ 'field_device_without_subscription_ref'
     or (select prosrc from pg_proc where oid = 'cma.data_quality_of(uuid)'::regprocedure) !~ 'field_device_on_ended_subscription'
     or (select prosrc from pg_proc where oid = 'cma.data_quality()'::regprocedure) !~ 'data_quality_assets_checks\(\)'
     or (select prosrc from pg_proc where oid = 'cma.data_quality()'::regprocedure) !~ 'data_quality_flash_checks\(\)' then
    v_bad := v_bad || 'data quality; ';
  end if;
  if (select prosrc from pg_proc where oid = 'cma.check_tenant_setting()'::regprocedure) !~ 'assets\.bundle_window_days'
     or (select prosrc from pg_proc where oid = 'cma.check_tenant_setting()'::regprocedure) !~ 'reviews\.negative_max_rating'
     or (select prosrc from pg_proc where oid = 'cma.check_tenant_setting()'::regprocedure) !~ 'cohorts\.lead_ages_days'
     or (select prosrc from pg_proc where oid = 'cma.check_tenant_setting()'::regprocedure) !~ 'lead_to_order\.max_days'
     or (select prosrc from pg_proc where oid = 'cma.check_tenant_setting()'::regprocedure) !~ 'flash\.ended_subscription_statuses'
     or (select prosrc from pg_proc where oid = 'cma.check_tenant_setting()'::regprocedure) !~ 'flash\.file_max_rows' then
    v_bad := v_bad || 'settings; ';
  end if;
  if (select prosrc from pg_proc where oid = 'cma.ingest_upsert_contacts(uuid,jsonb)'::regprocedure) !~ 'cma\.crm_task tk'
     or (select prosrc from pg_proc where oid = 'cma.ingest_upsert_contacts(uuid,jsonb)'::regprocedure) !~ 'cma\.commerce_customer cu'
     or (select prosrc from pg_proc where oid = 'cma.ingest_upsert_contacts(uuid,jsonb)'::regprocedure) !~ 'createdAts'
     or (select prosrc from pg_proc where oid = 'cma.ingest_contact_forget(uuid,text)'::regprocedure) !~ 'legacy_call_outcome'
     or (select prosrc from pg_proc where oid = 'cma.ingest_contact_forget(uuid,text)'::regprocedure) ~ 'commerce_customer' then
    v_bad := v_bad || 'contacts held and forgotten; ';
  end if;
  insert into verify_0008zn values (8, 'A8 the six checks in their order, nothing twice; the redefinitions carry what came before',
    case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_bad);
end
$$;

-- B. Behaviour on two throwaway tenants (rolled back)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  v_t1 uuid; v_t2 uuid; v_t3 uuid;
  v_admin1 uuid; v_analyst1 uuid; v_agent1 uuid; v_sched1 uuid; v_ingest1 uuid; v_admin2 uuid; v_sched2 uuid; v_sched3 uuid;
  v_crm uuid; v_shop_gb uuid; v_shop_nl uuid; v_subs uuid; v_reg uuid; v_rev uuid; v_chan uuid; v_conn uuid;
  v_txt text; v_a text; v_b text; v_c text;
  v_n integer;
  j jsonb;
  o record;
  v_today date;
  -- the takes' instants (Europe/Amsterdam): 00:10 is before flash.snapshot_local_time (00:30), so 28 October is not due
  -- yet then; 01:00 after it
  v_early   timestamptz := '2026-10-29 00:10:00 Europe/Amsterdam';
  v_take_a  timestamptz := '2026-10-29 01:00:00 Europe/Amsterdam';   -- business date 28 October
  v_take_b  timestamptz := '2026-10-31 01:00:00 Europe/Amsterdam';   -- 30 October (29 October missed)
  v_take_c  timestamptz := '2026-11-01 01:00:00 Europe/Amsterdam';   -- 31 October, a month end
begin
  begin
    -- tenants and people (as the owner); each tenant's Scheduler and Ingest users come with create_tenant
    v_t1 := cma.create_tenant('verify-0008zn-one', 'Verify 0008zn one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008zn-two', 'Verify 0008zn two', 'Europe/Amsterdam');
    -- tenant three: no source, for the snapshot time's rule and the watch's own failures (its takes are quick)
    v_t3 := cma.create_tenant('verify-0008zn-three', 'Verify 0008zn three', 'Europe/Amsterdam');
    v_today := cma.tenant_today_of(v_t1);
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-analyst1@example.invalid', 'analyst1') returning id into v_analyst1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent1@example.invalid', 'agent1') returning id into v_agent1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin2') returning id into v_admin2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_analyst1, 'analytics'), (v_t1, v_agent1, 'agent'), (v_t2, v_admin2, 'admin')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select u.id into v_sched1 from cma.app_user u where u.tenant_id = v_t1 and u.email = 'scheduler@system.invalid';
    select u.id into v_sched2 from cma.app_user u where u.tenant_id = v_t2 and u.email = 'scheduler@system.invalid';
    select u.id into v_sched3 from cma.app_user u where u.tenant_id = v_t3 and u.email = 'scheduler@system.invalid';
    select x.user_id into v_ingest1 from cma.app_user_external_id x
    join cma.app_user u on u.tenant_id = x.tenant_id and u.id = x.user_id
    where x.tenant_id = v_t1 and u.kind = 'system' and u.id <> v_sched1 limit 1;

    -- tenant one's sources (as the owner: the ingest's writes are not under test here, 113 and 119 test them)
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency, sort_order) values
      (v_t1, 'GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', 10), (v_t1, 'NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR', 20);
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, settings)
    values (v_t1, 'verifycrm', 'Verify CRM', 'portal-1', 'crm',
            '{"record_url_contact": "https://crm.example/{account}/contact/{id}", "record_url_deal": "https://crm.example/{account}/deal/{id}", "record_url_ticket": "https://crm.example/{account}/ticket/{id}"}')
    returning id into v_crm;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifyshop', 'Verify shop GB', 'shop-gb.shop.example', 'commerce') returning id into v_shop_gb;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifyshop', 'Verify shop NL', 'shop-nl.shop.example', 'commerce') returning id into v_shop_nl;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t1, 'verifysubs', 'Verify subscriptions GB', 'shop-gb.shop.example', 'subscriptions', 'verify-subs-token') returning id into v_subs;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifyregister', 'Verify register', 'base-1', 'assets') returning id into v_reg;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifyreviews', 'Verify reviews', 'reviews-1', 'reviews') returning id into v_rev;
    insert into cma.commerce_store (tenant_id, connection_id, handle, name, market, currency, time_zone) values
      (v_t1, v_shop_gb, 'shop-gb', 'Shop GB', 'GB', 'GBP', 'Europe/London'), (v_t1, v_shop_nl, 'shop-nl', 'Shop NL', 'NL', 'EUR', 'Europe/Amsterdam');
    -- store customers: lifetime orders, total spent, the contact link (0008h)
    insert into cma.commerce_customer (tenant_id, connection_id, source_system, source_id, orders_count, amount_spent, amount_currency,
                                       crm_connection_id, crm_contact_source_id, matched_at) values
      (v_t1, v_shop_gb, 'verifyshop', 'cu-1', 3, 300.00, 'GBP', v_crm, 'c-1', now()),
      (v_t1, v_shop_gb, 'verifyshop', 'cu-2', 1, 20.00, 'GBP', v_crm, 'c-2', now()),
      (v_t1, v_shop_gb, 'verifyshop', 'cu-3', 0, null, null, null, null, null),
      (v_t1, v_shop_gb, 'verifyshop', 'cu-4', 2, 50.00, 'GBP', v_crm, 'c-9', now()),
      (v_t1, v_shop_nl, 'verifyshop', 'cu-5', 1, 40.00, 'EUR', null, null, null),
      (v_t1, v_shop_gb, 'verifyshop', 'cu-6', 0, null, null, null, null, null);
    insert into cma.crm_contact (tenant_id, connection_id, source_system, source_id, country) values
      (v_t1, v_crm, 'verifycrm', 'c-1', 'GB'), (v_t1, v_crm, 'verifycrm', 'c-2', 'GB');
    insert into cma.crm_contact_ref (tenant_id, contact_id, system, slot, external_id)
    select v_t1, k.id, 'netsuite', 1, 'NS-1' from cma.crm_contact k where k.tenant_id = v_t1 and k.source_id = 'c-1';
    -- subscriptions of the GB store: s-1 active (a failed renewal open: in retry), s-2 paused, s-3 canceled, s-4 active of a
    -- customer the store does not hold, s-5 active in EUR, s-6 expired, s-7 paused
    insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, current_cycle, amount_per_cycle,
                                  currency, billing_interval, billing_interval_count, paused_at) values
      (v_t1, v_subs, 'verifysubs', 's-1', 'cu-1', 'active', 3, 20.00, 'GBP', 'month', 1, null),
      (v_t1, v_subs, 'verifysubs', 's-2', 'cu-2', 'paused', 2, 10.00, 'GBP', 'month', 1, now()),
      (v_t1, v_subs, 'verifysubs', 's-3', 'cu-1', 'canceled', 5, 20.00, 'GBP', 'month', 1, null),
      (v_t1, v_subs, 'verifysubs', 's-4', 'cu-9', 'active', 2, 15.00, 'GBP', 'month', 1, null),
      (v_t1, v_subs, 'verifysubs', 's-5', 'cu-2', 'active', 1, 30.00, 'EUR', 'year', 1, null),
      (v_t1, v_subs, 'verifysubs', 's-6', 'cu-3', 'expired', 12, 5.00, 'GBP', 'month', 1, null),
      (v_t1, v_subs, 'verifysubs', 's-7', 'cu-6', 'paused', 1, 10.00, 'GBP', 'month', 1, now());
    insert into cma.subscription_event (tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type, occurred_at,
                                        cycle_index, attempt, reason_code, status_from, status_to) values
      (v_t1, v_subs, 'verifysubs', 'e-1', 's-1', 'renew_failed', '2026-10-30 07:00 Europe/Amsterdam', 3, 1, null, null, null),
      (v_t1, v_subs, 'verifysubs', 'e-2', 's-4', 'renewed', '2026-10-30 09:00 Europe/Amsterdam', 2, null, null, null, null),
      (v_t1, v_subs, 'verifysubs', 'e-3', 's-3', 'canceled', '2026-10-30 12:00 Europe/Amsterdam', null, null, 'too-expensive', 'active', 'canceled'),
      (v_t1, v_subs, 'verifysubs', 'e-4', 's-3', 'status_changed', '2026-10-30 12:01 Europe/Amsterdam', null, null, null, 'active', 'canceled'),
      (v_t1, v_subs, 'verifysubs', 'e-5', 's-6', 'status_changed', '2026-10-31 08:00 Europe/Amsterdam', null, null, null, 'active', 'expired'),
      (v_t1, v_subs, 'verifysubs', 'e-6', 's-5', 'renewed', '2026-10-31 10:00 Europe/Amsterdam', 1, null, null, null, null);
    -- orders: two on 30 October in the GB store and a test order, one each on 31 October in NL and GB
    insert into cma.commerce_order (tenant_id, connection_id, source_system, source_id, order_name, customer_source_id, source_created_at, is_test,
                                    currency, total_amount, refunded_amount, financial_status, fulfillment_status, order_kind) values
      (v_t1, v_shop_gb, 'verifyshop', 'o-1', '#1001', 'cu-1', '2026-10-30 10:00 Europe/Amsterdam', false, 'GBP', 50.00, null, 'PAID', 'fulfilled', 'first'),
      (v_t1, v_shop_gb, 'verifyshop', 'o-2', '#1002', 'cu-2', '2026-10-30 15:00 Europe/Amsterdam', false, 'GBP', 20.00, 5.00, 'PENDING', null, 'repeat'),
      (v_t1, v_shop_gb, 'verifyshop', 'o-3', '#1003', null, '2026-10-30 11:00 Europe/Amsterdam', true, 'GBP', 99.00, null, 'PAID', null, 'first'),
      (v_t1, v_shop_nl, 'verifyshop', 'o-4', '#2001', 'cu-5', '2026-10-31 09:00 Europe/Amsterdam', false, 'EUR', 40.00, null, 'PAID', null, 'first'),
      (v_t1, v_shop_gb, 'verifyshop', 'o-5', '#1005', 'cu-1', '2026-10-31 20:00 Europe/Amsterdam', false, 'GBP', 10.00, null, 'PAID', null, 'renewal');
    insert into cma.commerce_order_line (tenant_id, connection_id, order_source_id, line_source_id, sku, quantity, unit_price, currency) values
      (v_t1, v_shop_gb, 'o-1', 'l-1', 'A', 2, 20.00, 'GBP'), (v_t1, v_shop_gb, 'o-1', 'l-2', 'B', 1, 10.00, 'GBP'),
      (v_t1, v_shop_gb, 'o-2', 'l-3', 'A', 1, 20.00, 'GBP'), (v_t1, v_shop_gb, 'o-3', 'l-4', 'A', 5, 20.00, 'GBP'),
      (v_t1, v_shop_nl, 'o-4', 'l-5', 'C', 1, 40.00, 'EUR'), (v_t1, v_shop_gb, 'o-5', 'l-6', 'A', 1, 10.00, 'GBP');
    -- the asset register: no component kind, so a device's due items are its end of life only
    insert into cma.device_model (tenant_id, key, name) values (v_t1, 'm1', 'M1');
    insert into cma.device_status (tenant_id, key, name, is_in_field, is_in_stock, is_tracked) values
      (v_t1, 'field', 'Field', true, false, true), (v_t1, 'stock', 'Stock', false, true, true);
    insert into cma.device (tenant_id, connection_id, source_system, source_id, serial, model_key, market, device_status_key, warehouse_ref, customer_ref,
                            subscription_ref, end_of_life_on, external_refs, source_deleted_at) values
      (v_t1, v_reg, 'verifyregister', 'rec-1', 'SN-1', 'm1', 'GB', 'field', null, 'cu-1', 's-1', null, '{"ns_internal_id": "1001"}', null),
      (v_t1, v_reg, 'verifyregister', 'rec-2', 'SN-2', 'm1', 'GB', 'field', null, 'cu-1', 's-3', null, '{}', null),
      (v_t1, v_reg, 'verifyregister', 'rec-3', 'SN-3', 'm1', 'GB', 'stock', 'WH-A', null, null, '2020-01-01', '{"ns_internal_id": "1003"}', null),
      (v_t1, v_reg, 'verifyregister', 'rec-4', 'SN-4', 'm1', 'GB', 'field', null, null, 'sub-x', v_today + 30, '{"ns_internal_id": "1004"}', null),
      (v_t1, v_reg, 'verifyregister', 'rec-5', 'SN-5', 'm1', 'NL', 'field', null, null, 'sub-y', null, '{"ns_internal_id": "1005"}', null),
      (v_t1, v_reg, 'verifyregister', 'rec-6', 'SN-6', 'm1', 'GB', 'stock', null, null, null, null, '{}', now());
    -- the CRM: a counted deal pipeline and one not counted, a ticket pipeline; two open deals, a closed one, one in the
    -- pipeline not counted; an open and a closed ticket; tasks open (one overdue) and done
    insert into cma.connection_pipeline (tenant_id, connection_id, record_type, source_pipeline_id, label, is_counted) values
      (v_t1, v_crm, 'deal', 'p1', 'Sales', true), (v_t1, v_crm, 'deal', 'p2', 'Other', false), (v_t1, v_crm, 'ticket', 'tp1', 'Service', true);
    insert into cma.connection_stage (tenant_id, connection_id, record_type, source_pipeline_id, source_stage_id, label, is_closed) values
      (v_t1, v_crm, 'deal', 'p1', 's1', 'Open stage', false), (v_t1, v_crm, 'deal', 'p1', 'won', 'Won', true),
      (v_t1, v_crm, 'ticket', 'tp1', 'new', 'New', false), (v_t1, v_crm, 'ticket', 'tp1', 'done', 'Done', true);
    insert into cma.crm_record (tenant_id, connection_id, source_system, record_type, source_id, pipeline_id, stage_id, owner_ref, contact_source_id, market,
                                is_closed, source_created_at) values
      (v_t1, v_crm, 'verifycrm', 'deal', 'deal-1', 'p1', 's1', 'own-1', 'c-1', 'GB', false, now() - interval '10 days'),
      (v_t1, v_crm, 'verifycrm', 'deal', 'deal-2', 'p1', 'won', 'own-1', 'c-2', 'GB', true, now() - interval '20 days'),
      (v_t1, v_crm, 'verifycrm', 'deal', 'deal-3', 'p2', 's1', null, null, 'GB', false, now() - interval '5 days'),
      (v_t1, v_crm, 'verifycrm', 'deal', 'deal-4', 'p1', 's1', null, null, 'NL', false, now() - interval '2 days'),
      (v_t1, v_crm, 'verifycrm', 'ticket', 't-1', 'tp1', 'new', null, 'c-1', 'GB', false, now() - interval '3 days'),
      (v_t1, v_crm, 'verifycrm', 'ticket', 't-2', 'tp1', 'done', null, 'c-2', 'GB', true, now() - interval '9 days');
    insert into cma.connection_task_status (tenant_id, connection_id, status_ref, label, is_done) values
      (v_t1, v_crm, 'NOT_STARTED', 'Not started', false), (v_t1, v_crm, 'COMPLETED', 'Completed', true);
    insert into cma.connection_task_type (tenant_id, connection_id, type_ref, label) values (v_t1, v_crm, 'CALL', 'Call'), (v_t1, v_crm, 'EMAIL', 'Email');
    insert into cma.crm_task (tenant_id, connection_id, source_system, source_id, owner_ref, status_ref, type_ref, due_at, deal_source_id, ticket_source_id,
                              source_created_at) values
      (v_t1, v_crm, 'verifycrm', 'k-1', 'own-1', 'NOT_STARTED', 'CALL', now() - interval '2 days', 'deal-1', null, now() - interval '4 days'),
      (v_t1, v_crm, 'verifycrm', 'k-2', 'own-1', 'COMPLETED', 'CALL', now() - interval '2 days', 'deal-1', null, now() - interval '4 days'),
      (v_t1, v_crm, 'verifycrm', 'k-3', null, 'NOT_STARTED', 'EMAIL', now() + interval '1 day', null, 't-1', now() - interval '1 day');
    -- the review platform: a counted GB channel; two reviews on 30 October (one negative), one on 31 October, one unpublished
    insert into cma.review_channel (tenant_id, connection_id, source_id, name, market, is_counted)
    values (v_t1, v_rev, 'chl-gb', 'Channel GB', 'GB', true) returning id into v_chan;
    insert into cma.review (tenant_id, connection_id, review_channel_id, source_system, source_id, review_type, state, is_published, rating, submitted_at,
                            link_level) values
      (v_t1, v_rev, v_chan, 'verifyreviews', 'rv-1', 'SERVICE_REVIEW', 'APPROVED', true, 5, '2026-10-30 10:00 Europe/Amsterdam', 'none'),
      (v_t1, v_rev, v_chan, 'verifyreviews', 'rv-2', 'SERVICE_REVIEW', 'APPROVED', true, 1, '2026-10-30 11:00 Europe/Amsterdam', 'none'),
      (v_t1, v_rev, v_chan, 'verifyreviews', 'rv-3', 'SERVICE_REVIEW', 'APPROVED', true, 4.5, '2026-10-31 11:00 Europe/Amsterdam', 'none'),
      (v_t1, v_rev, v_chan, 'verifyreviews', 'rv-4', 'SERVICE_REVIEW', 'MODERATION', false, 2, '2026-10-30 12:00 Europe/Amsterdam', 'none');

    -- B1. the settings, as the admin: refusals (CMA04) and the normalised list; then tenant one's values
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := pg_temp.v0008zn_code('select cma.set_tenant_setting(''flash.active_subscription_statuses'', ''active,bogus'')')
             || ' ' || pg_temp.v0008zn_code('select cma.set_tenant_setting(''flash.active_subscription_statuses'', ''active,active'')')
             || ' ' || pg_temp.v0008zn_code('select cma.set_tenant_setting(''flash.active_subscription_statuses'', '''')')
             || ' ' || pg_temp.v0008zn_code('select cma.set_tenant_setting(''flash.snapshot_local_time'', ''24:00'')')
             || ' ' || pg_temp.v0008zn_code('select cma.set_tenant_setting(''flash.id_list_retention_months'', ''0'')')
             || ' ' || pg_temp.v0008zn_code('select cma.set_tenant_setting(''flash.watch_jump_pct'', ''0'')')
             || ' ' || pg_temp.v0008zn_code('select cma.set_tenant_setting(''flash.watch_jump_min'', ''-1'')')
             || ' ' || pg_temp.v0008zn_code('select cma.set_tenant_setting(''flash.file_max_rows'', ''50001'')')
             || ' ' || pg_temp.v0008zn_code('select cma.set_tenant_setting(''assets.required_refs'', ''Bad Key'')')
             || ' ' || pg_temp.v0008zn_code('select cma.set_tenant_setting(''commerce.required_contact_refs'', ''netsuite,netsuite'')')
             -- paused is never active nor ended (its own measure), and no status is both
             || ' ' || pg_temp.v0008zn_code('select cma.set_tenant_setting(''flash.active_subscription_statuses'', ''active,paused'')')
             || ' ' || pg_temp.v0008zn_code('select cma.set_tenant_setting(''flash.ended_subscription_statuses'', ''paused'')')
             || ' ' || pg_temp.v0008zn_code('select cma.set_tenant_setting(''flash.ended_subscription_statuses'', ''canceled,active'')')
             || ' ' || pg_temp.v0008zn_code('select cma.set_tenant_setting(''flash.active_subscription_statuses'', ''active,expired'')')
             || ' ' || pg_temp.v0008zn_code('select cma.set_tenant_setting(''flash.active_subscription_statuses'', '' active , failed '')');
    v_txt := v_txt || ' ' || cma.setting_of(v_t1, 'flash.active_subscription_statuses');
    perform cma.set_tenant_setting('flash.active_subscription_statuses', 'active');
    perform cma.set_tenant_setting('commerce.required_contact_refs', 'netsuite');
    perform cma.set_tenant_setting('assets.required_refs', 'ns_internal_id');
    perform cma.set_tenant_setting('flash.watch_jump_min', '1');
    perform cma.set_tenant_setting('intake.start_date', '2026-01-01');
    v_rows := v_rows || array['11', 'B1 the settings'' refusals (paused neither active nor ended, no status in both); a list without spaces',
      case when v_txt = 'CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 ok active,failed' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B2. each stock overview's live figures, as the analyst, equal the hand-computed ones
    perform set_config('app.user_id', v_analyst1::text, true);
    v_txt := pg_temp.v0008zn_figs(v_t1, 'customers', null, null);
    v_rows := v_rows || array['12', 'B2 customers: held, active, paused, linked, with every required reference, per market and store',
      case when v_txt = '*:active_customers=2,customers_held=6,linked_to_contact=3,paused_customers=1,with_required_refs=1 '
                        || 'GB:active_customers=2,customers_held=5,linked_to_contact=3,paused_customers=1,with_required_refs=1 '
                        || 'NL:active_customers=0,customers_held=1,linked_to_contact=0,paused_customers=0,with_required_refs=0 '
                        || 'GB/shop-gb:active_customers=2,customers_held=5,linked_to_contact=3,paused_customers=1,with_required_refs=1 '
                        || 'NL/shop-nl:active_customers=0,customers_held=1,linked_to_contact=0,paused_customers=0,with_required_refs=0'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];
    v_txt := pg_temp.v0008zn_figs(v_t1, 'subscriptions', null, null);
    v_rows := v_rows || array['13', 'B2 subscriptions: per market, store, status and payment state; the active subscriptions'' amounts per currency',
      case when v_txt = '*:active_subscriptions=3,amount_per_cycle={"EUR": 30.00, "GBP": 35.00},paused_subscriptions=2,subscriptions=7 '
                        || 'GB:active_subscriptions=3,amount_per_cycle={"EUR": 30.00, "GBP": 35.00},paused_subscriptions=2,subscriptions=7 '
                        || 'GB/in_retry/active/shop-gb:active_subscriptions=1,amount_per_cycle={"GBP": 20.00},paused_subscriptions=0,subscriptions=1 '
                        || 'GB/paid/active/shop-gb:active_subscriptions=2,amount_per_cycle={"EUR": 30.00, "GBP": 15.00},paused_subscriptions=0,subscriptions=2 '
                        || 'GB/canceled/canceled/shop-gb:active_subscriptions=0,amount_per_cycle={},paused_subscriptions=0,subscriptions=1 '
                        || 'GB/canceled/expired/shop-gb:active_subscriptions=0,amount_per_cycle={},paused_subscriptions=0,subscriptions=1 '
                        || 'GB/paused/paused/shop-gb:active_subscriptions=0,amount_per_cycle={},paused_subscriptions=2,subscriptions=2'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];
    v_txt := pg_temp.v0008zn_figs(v_t1, 'installed_base', null, null);
    v_rows := v_rows || array['14', 'B2 installed base: devices, in the field, in stock, past due, due within three months; the subscription link',
      case when v_txt = '*:components_past_due=1,devices=5,in_field=4,in_stock=1,items_due_3m=1 '
                        || 'GB:components_past_due=1,devices=4,in_field=3,in_stock=1,items_due_3m=1 '
                        || 'NL:components_past_due=0,devices=1,in_field=1,in_stock=0,items_due_3m=0 '
                        || 'linked/GB/m1/field/none:components_past_due=0,devices=2,in_field=2,in_stock=0,items_due_3m=0 '
                        || 'none/GB/m1/stock/WH-A:components_past_due=1,devices=1,in_field=0,in_stock=1,items_due_3m=0 '
                        || 'not_found/GB/m1/field/none:components_past_due=0,devices=1,in_field=1,in_stock=0,items_due_3m=1 '
                        || 'not_found/NL/m1/field/none:components_past_due=0,devices=1,in_field=1,in_stock=0,items_due_3m=0'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];
    v_txt := pg_temp.v0008zn_figs(v_t1, 'open_deals', null, null) || ' | ' || pg_temp.v0008zn_figs(v_t1, 'open_tickets', null, null)
             || ' | ' || pg_temp.v0008zn_figs(v_t1, 'open_tasks', null, null);
    v_rows := v_rows || array['15', 'B2 open deals (counted pipelines), open tickets and open tasks: counts, ages, overdue',
      case when v_txt = '*:median_age_days=6.0,oldest_age_days=10,open_deals=2 GB:median_age_days=10.0,oldest_age_days=10,open_deals=1 '
                        || 'NL:median_age_days=2.0,oldest_age_days=2,open_deals=1 GB/p1/s1:median_age_days=10.0,oldest_age_days=10,open_deals=1 '
                        || 'NL/p1/s1:median_age_days=2.0,oldest_age_days=2,open_deals=1 | '
                        || '*:median_age_days=3.0,oldest_age_days=3,open_tickets=1 GB:median_age_days=3.0,oldest_age_days=3,open_tickets=1 '
                        || 'GB/tp1/new:median_age_days=3.0,oldest_age_days=3,open_tickets=1 | '
                        || '*:open_tasks=2,overdue=1 GB:open_tasks=2,overdue=1 GB/NOT_STARTED/CALL:open_tasks=1,overdue=1 GB/NOT_STARTED/EMAIL:open_tasks=1,overdue=0'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B3. each flow overview on 30 October: churn (once per subscription and date, the canceled event's reason), orders
    --     (test orders out, total less refunded, per SKU), payments (orders by status, renewals and failed renewals),
    --     reviews (published, counted channel)
    v_txt := pg_temp.v0008zn_figs(v_t1, 'churn', '2026-10-30', '2026-10-30') || ' | ' || pg_temp.v0008zn_figs(v_t1, 'orders', '2026-10-30', '2026-10-30')
             || ' | ' || pg_temp.v0008zn_figs(v_t1, 'payments', '2026-10-30', '2026-10-30') || ' | ' || pg_temp.v0008zn_figs(v_t1, 'reviews', '2026-10-30', '2026-10-30');
    v_rows := v_rows || array['16', 'B3 flows of 30 October: churn, orders, payments, reviews',
      case when v_txt = '*:churned=1 GB:churned=1 GB/too-expensive/shop-gb:churned=1 | '
                        || '*:amount={"GBP": 65.00},orders=2,units=4 GB:amount={"GBP": 65.00},orders=2,units=4 GB/A:orders=2,units=3 GB/B:orders=1,units=1 '
                        || 'first/GB/shop-gb:amount={"GBP": 50.00},orders=1,units=3 repeat/GB/shop-gb:amount={"GBP": 15.00},orders=1,units=1 | '
                        || '*:amount={"GBP": 65.00},failed_renewals=1,orders=2,renewals=1 GB:amount={"GBP": 65.00},failed_renewals=1,orders=2,renewals=1 '
                        || 'order/GB/paid/shop-gb:amount={"GBP": 50.00},failed_renewals=0,orders=1,renewals=0 '
                        || 'order/GB/pending/shop-gb:amount={"GBP": 15.00},failed_renewals=0,orders=1,renewals=0 '
                        || 'renewal/GB/renew_failed/shop-gb:amount={},failed_renewals=1,orders=0,renewals=0 '
                        || 'renewal/GB/renewed/shop-gb:amount={},failed_renewals=0,orders=0,renewals=1 | '
                        || '*:negative=1,rating_sum=6.00,reviews=2 GB:negative=1,rating_sum=6.00,reviews=2 GB/1:negative=1,rating_sum=1.00,reviews=1 '
                        || 'GB/5:negative=0,rating_sum=5.00,reviews=1'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B4. the six data-quality checks find exactly their seeded rows
    perform set_config('role', 'cma_owner', true);
    select string_agg(q.check_key || ':' || q.object_id || coalesce(':' || q.value, ''), ' ' order by q.check_key collate "C", q.object_id collate "C") into v_txt
    from cma.data_quality_of(v_t1) q
    where q.check_key in (select c.check_key from cma.data_quality_flash_checks() c);
    v_rows := v_rows || array['17', 'B4 the six checks: required contact references (and a contact not held), required device ids, unmatched customer, active without device, unknown reference, ended subscription',
      case when v_txt = 'active_subscription_without_device:s-4:active active_subscription_without_device:s-5:active '
                        || 'customer_required_ref_missing:cu-2:netsuite customer_required_ref_missing:cu-4:contact_not_held '
                        || 'device_required_ref_missing:rec-2:ns_internal_id device_subscription_ref_unknown:rec-4 '
                        || 'field_device_on_ended_subscription:rec-2:canceled subscription_customer_unmatched:s-4'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B5. their rows for the application: the market, where each is fixed (kind and adapter), the record's and the related
    --     contact's links; data_quality() lists the six with their counts
    perform set_config('role', 'cma_app', true);
    j := cma.data_quality_rows('customer_required_ref_missing');
    v_txt := (j ->> 'total') || ' ' || (select string_agg(r ->> 'object_id' || '/' || (r ->> 'market') || '/' || (r ->> 'fix_in') || '/' || coalesce(r ->> 'fix_adapter', '-')
                                                          || '/' || coalesce(r ->> 'related_url', '-'), ' ' order by (r ->> 'object_id') collate "C")
                                        from jsonb_array_elements(j -> 'rows') r);
    j := cma.data_quality_rows('field_device_on_ended_subscription', 'GB');
    v_txt := v_txt || ' | ' || (j ->> 'total') || ' ' || (j -> 'rows' -> 0 ->> 'fix_in') || '/' || (j -> 'rows' -> 0 ->> 'fix_adapter') || '/'
             || (j -> 'rows' -> 0 ->> 'related_type') || ':' || (j -> 'rows' -> 0 ->> 'related_id')
             || ' | ' || (select string_agg(d.check_key || '=' || d.total, ' ' order by d.check_key collate "C") from cma.data_quality() d
                          where d.check_key in (select c.check_key from cma.data_quality_flash_checks() c))
             || ' | ' || pg_temp.v0008zn_code('select cma.data_quality_rows(''no_such_check'')');
    v_rows := v_rows || array['18', 'B5 the checks'' rows: market, the system where fixed, links; data_quality() lists the six; an unknown check refused',
      case when v_txt = '2 cu-2/GB/crm/verifycrm/https://crm.example/portal-1/contact/c-2 cu-4/GB/cma/-/https://crm.example/portal-1/contact/c-9 | '
                        || '1 assets/verifyregister/subscription:s-3 | active_subscription_without_device=2 customer_required_ref_missing=2 '
                        || 'device_required_ref_missing=1 device_subscription_ref_unknown=1 field_device_on_ended_subscription=1 '
                        || 'subscription_customer_unmatched=1 | CMA04'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    perform set_config('role', 'cma_owner', true);
    -- the history before the first take: 21 to 27 October as succeeded runs (as the owner), the live figures as of each
    -- date stored for each, the GB store's orders 5 a day, and on 27 October 100 active customers in GB and no row for the check
    -- active_subscription_without_device; the register's runs every 5 minutes until 20:00 on 28 October
    for v_n in 0 .. 6 loop
      insert into cma.flash_snapshot_run (id, tenant_id, snapshot_date, due_at, started_at, finished_at, status)
      values (uuidv7(), v_t1, date '2026-10-21' + v_n, cma.flash_due_at_of('Europe/Amsterdam', '00:30', date '2026-10-21' + v_n), now(), now(), 'succeeded');
      insert into cma.flash_snapshot (tenant_id, snapshot_date, overview, dims, measures, definition_version, computed_at, run_id)
      select v_t1, date '2026-10-21' + v_n, x.key, c.dims, c.measures, '0008zn', now(),
             (select r.id from cma.flash_snapshot_run r where r.tenant_id = v_t1 and r.snapshot_date = date '2026-10-21' + v_n)
      from cma.flash_overviews() x
      cross join lateral cma.flash_compute_of(v_t1, x.key, date '2026-10-21' + v_n, date '2026-10-21' + v_n, date '2026-10-21' + v_n) c;
      insert into cma.flash_snapshot (tenant_id, snapshot_date, overview, dims, measures, definition_version, computed_at, run_id)
      values (v_t1, date '2026-10-21' + v_n, 'orders', '{"market": "GB"}', '{"orders": 5, "units": 5, "amount": {"GBP": 50}}', '0008zn', now(),
              (select r.id from cma.flash_snapshot_run r where r.tenant_id = v_t1 and r.snapshot_date = date '2026-10-21' + v_n));
    end loop;
    update cma.flash_snapshot s set measures = s.measures || '{"active_customers": 100}'
    where s.tenant_id = v_t1 and s.snapshot_date = '2026-10-27' and s.overview = 'customers' and s.dims = '{"market": "GB"}';
    delete from cma.flash_snapshot s
    where s.tenant_id = v_t1 and s.snapshot_date = '2026-10-27' and s.overview = 'data_quality' and s.dims = '{"check": "active_subscription_without_device"}';
    insert into cma.sync_run (tenant_id, connection_id, job, started_at, finished_at, status)
    select v_t1, v_reg, 'assets_poll', t - interval '1 minute', t, 'succeeded'
    from generate_series(timestamptz '2026-10-28 18:00 Europe/Amsterdam', timestamptz '2026-10-28 20:00 Europe/Amsterdam', interval '5 minutes') t;

    -- B6. a take before flash.snapshot_local_time on 29 October writes nothing: the latest due date then is 27 October,
    --     which the history holds (as the owner: an instant other than now is the owner's alone, so the scheduler user's
    --     permissions are read from app.user_id)
    perform set_config('app.user_id', v_sched1::text, true);
    v_n := (select count(*) from cma.flash_snapshot s where s.tenant_id = v_t1);
    j := cma.flash_snapshot_take_at(v_t1, v_early);
    v_txt := (j ->> 'taken') || ' ' || (j ->> 'reason') || ' ' || (j ->> 'date')
             || ' ' || (select count(*) from cma.flash_snapshot_run r where r.tenant_id = v_t1)
             || ' ' || ((select count(*) from cma.flash_snapshot s where s.tenant_id = v_t1) = v_n)::text;
    v_rows := v_rows || array['21', 'B6 a take before the snapshot time writes nothing: the date before is the latest due one, and it is taken',
      case when v_txt = 'false taken 2026-10-27 7 true' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B7. take A (28 October): stored; the watch opens a jump (GB's active customers from 100 to 2), a flow_zero (GB's
    --     orders, above 0 on each of the 7 dates before), a dq_rise (active subscriptions without a device from none to
    --     2) and a source_stale (the register's last run 300 minutes old against a cadence of 5 minutes)
    j := cma.flash_snapshot_take_at(v_t1, v_take_a);
    v_txt := (j ->> 'taken') || ' ' || (j ->> 'date') || ' ' || (j ->> 'watch_opened') || ' ' || (j ->> 'watch_resolved')
             || ' | ' || (select string_agg(f.kind || ':' || coalesce(f.overview, '-') || ':' || f.dims::text || ':' || coalesce(f.measure, '-')
                                             || ':' || coalesce(f.value::text, '-') || ':' || coalesce(f.previous::text, '-') || ':' || coalesce(f.threshold::text, '-'),
                                             ' ' order by f.kind collate "C")
                          from cma.flash_watch_finding f where f.tenant_id = v_t1 and f.state = 'open');
    v_rows := v_rows || array['22', 'B7 take A: stored; the watch opens jump, flow_zero, dq_rise and source_stale',
      case when v_txt = 'true 2026-10-28 4 0 | dq_rise:data_quality:{"check": "active_subscription_without_device"}:findings:2:0:1.00 '
                        || 'flow_zero:orders:{"market": "GB"}:orders:0:-:0 jump:customers:{"market": "GB"}:active_customers:2:100:20.00 '
                        || 'source_stale:-:{"source": "assets", "adapter": "verifyregister"}:-:300:-:15'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B8. take B (30 October; 29 October missed): 29 October recorded as missed (a run row of its own, no figures), the
    --     take stored with missed_before 1; snapshot_missing opens, the other four resolve (no date before to compare, a
    --     fresh run of the register); the stored rows equal the computation as of 30 October for all eleven overviews (stock
    --     measured against that date, flows of that date): one code path
    insert into cma.sync_run (tenant_id, connection_id, job, started_at, finished_at, status)
    values (v_t1, v_reg, 'assets_poll', v_take_b - interval '6 minutes', v_take_b - interval '5 minutes', 'succeeded');
    j := cma.flash_snapshot_take_at(v_t1, v_take_b);
    v_txt := (j ->> 'taken') || ' ' || (j ->> 'date') || ' ' || (j ->> 'missed_before') || ' ' || (j ->> 'watch_opened') || ' ' || (j ->> 'watch_resolved')
             || ' ' || (j ->> 'missed_recorded') || ' ' || (j ->> 'late')
             || ' ' || (select string_agg(r.status, ',' order by r.started_at, r.status collate "C") from cma.flash_snapshot_run r where r.tenant_id = v_t1 and r.snapshot_date = '2026-10-29')
             || ' ' || (select count(*) from cma.flash_snapshot s where s.tenant_id = v_t1 and s.snapshot_date = '2026-10-29')
             || ' | ' || (select string_agg(f.kind || ':' || f.detail::text, ' ' order by f.kind collate "C", f.detail::text collate "C") from cma.flash_watch_finding f where f.tenant_id = v_t1 and f.state = 'open')
             || ' | ' || (select string_agg(f.kind || ':' || f.resolved_on, ' ' order by f.kind collate "C") from cma.flash_watch_finding f
                          where f.tenant_id = v_t1 and f.state = 'resolved');
    v_rows := v_rows || array['23', 'B8 take B after a missed date: the date recorded as missed, missed_before, snapshot_missing opened, the four resolved',
      case when v_txt = 'true 2026-10-30 1 1 4 1 false missed 0 | snapshot_missing:{"days": 1, "missing_to": "2026-10-29", "missing_from": "2026-10-29"} | '
                        || 'dq_rise:2026-10-30 flow_zero:2026-10-30 jump:2026-10-30 source_stale:2026-10-30'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];
    v_txt := '';
    for o in select x.key, x.kind from cma.flash_overviews() x order by x.sort_order loop
      v_a := pg_temp.v0008zn_stored(v_t1, o.key, array[date '2026-10-30']);
      v_b := pg_temp.v0008zn_figs(v_t1, o.key, '2026-10-30', '2026-10-30', '2026-10-30');
      if v_a is distinct from v_b or v_a = '-' then
        v_txt := v_txt || o.key || ' differs; ';
      end if;
    end loop;
    v_txt := v_txt || (select count(distinct s.overview) from cma.flash_snapshot s where s.tenant_id = v_t1 and s.snapshot_date = '2026-10-30')::text
             || ' ' || (select string_agg(distinct s.definition_version collate "C", ',') from cma.flash_snapshot s where s.tenant_id = v_t1 and s.snapshot_date = '2026-10-30');
    v_rows := v_rows || array['24', 'B8 the snapshot equals the computation as of its date, all eleven overviews',
      case when v_txt = '11 0008zn' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B9. a second take of the same date writes nothing; no id list on a date that is no month end
    v_n := (select count(*) from cma.flash_snapshot s where s.tenant_id = v_t1);
    j := cma.flash_snapshot_take_at(v_t1, v_take_b + interval '3 hours');
    v_txt := (j ->> 'taken') || ' ' || (j ->> 'reason') || ' ' || ((select count(*) from cma.flash_snapshot s where s.tenant_id = v_t1) = v_n)::text
             || ' ' || (select count(*) from cma.flash_snapshot_run r where r.tenant_id = v_t1 and r.snapshot_date = '2026-10-30')
             || ' ' || (select count(*) from cma.flash_snapshot_ids x where x.tenant_id = v_t1);
    v_rows := v_rows || array['25', 'B9 a second take of the date writes nothing; no id list but at a month end',
      case when v_txt = 'false taken true 1 0' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B10. take C (31 October, a month end): the id lists (active customers, active subscriptions, every device the
    --      register holds), one audit row per kind; snapshot_missing resolved
    insert into cma.sync_run (tenant_id, connection_id, job, started_at, finished_at, status)
    values (v_t1, v_reg, 'assets_poll', v_take_c - interval '6 minutes', v_take_c - interval '5 minutes', 'succeeded');
    -- for B21 and B25: until after the take, SN-4's end of life on 31 October itself, an open task due on 31 October (k-4,
    -- an email of deal-1) and an open deal created on 30 October at noon alone in its stage (deal-5, GB, p1, s2); and a
    -- line of o-5 (31 October) whose SKU holds an @, kept (the flows of B11 read it live and stored alike)
    update cma.device set end_of_life_on = '2026-10-31' where tenant_id = v_t1 and source_id = 'rec-4';
    insert into cma.connection_stage (tenant_id, connection_id, record_type, source_pipeline_id, source_stage_id, label, is_closed)
    values (v_t1, v_crm, 'deal', 'p1', 's2', 'Second stage', false);
    insert into cma.crm_record (tenant_id, connection_id, source_system, record_type, source_id, pipeline_id, stage_id, owner_ref, contact_source_id, market,
                                is_closed, source_created_at)
    values (v_t1, v_crm, 'verifycrm', 'deal', 'deal-5', 'p1', 's2', null, null, 'GB', false, '2026-10-30 12:00 Europe/Amsterdam');
    insert into cma.crm_task (tenant_id, connection_id, source_system, source_id, owner_ref, status_ref, type_ref, due_at, deal_source_id, ticket_source_id,
                              source_created_at)
    values (v_t1, v_crm, 'verifycrm', 'k-4', null, 'NOT_STARTED', 'EMAIL', '2026-10-31 15:00 Europe/Amsterdam', 'deal-1', null, '2026-10-30 09:00 Europe/Amsterdam');
    insert into cma.commerce_order_line (tenant_id, connection_id, order_source_id, line_source_id, sku, quantity, unit_price, currency)
    values (v_t1, v_shop_gb, 'o-5', 'l-7', 'AED@PRO', 1, 0.00, 'GBP');
    j := cma.flash_snapshot_take_at(v_t1, v_take_c);
    v_txt := (j ->> 'taken') || ' ' || (j ->> 'ids_customer') || ' ' || (j ->> 'ids_subscription') || ' ' || (j ->> 'ids_device')
             || ' | ' || (select string_agg(x.record_kind || ':' || x.source_id || ':' || x.market || ':' || x.state, ' '
                                            order by x.record_kind collate "C", x.source_id collate "C")
                          from cma.flash_snapshot_ids x where x.tenant_id = v_t1)
             || ' | ' || (select count(*) from cma.audit_log al where al.tenant_id = v_t1 and al.table_name = 'flash_snapshot_ids')
             || ' ' || (select count(*) from cma.flash_watch_finding f where f.tenant_id = v_t1 and f.state = 'open');
    v_c := (j ->> 'taken') || ' ' || coalesce(j ->> 'ids_skipped', '-');
    v_rows := v_rows || array['26', 'B10 a month end''s id lists, one audit row per kind; snapshot_missing resolved',
      case when v_txt = 'true 2 3 5 | customer:cu-1:GB:active customer:cu-2:GB:active device:rec-1:GB:field device:rec-2:GB:field '
                        || 'device:rec-3:GB:stock device:rec-4:GB:field device:rec-5:NL:field subscription:s-1:GB:active '
                        || 'subscription:s-4:GB:active subscription:s-5:GB:active | 3 0'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B21. a month end's snapshot taken after midnight (1 November, 01:00) measures its stock figures against 31 October,
    --      not the day of the take: SN-4's item due on 31 October is due within three months and not past due (past due is
    --      an action date before the first of the date's month), the task due on 31 October is not overdue, deal-5's age is
    --      1 day at the end of 31 October; the same figures read today are past due, overdue and older
    v_txt := (select s.measures ->> 'components_past_due' || '/' || (s.measures ->> 'items_due_3m') from cma.flash_snapshot s
              where s.tenant_id = v_t1 and s.snapshot_date = '2026-10-31' and s.overview = 'installed_base' and s.dims = '{}')
             || ' ' || (select c.measures ->> 'components_past_due' || '/' || (c.measures ->> 'items_due_3m') from cma.flash_compute_of(v_t1, 'installed_base') c
                        where c.dims = '{}')
             || ' | ' || (select s.measures ->> 'overdue' from cma.flash_snapshot s
                          where s.tenant_id = v_t1 and s.snapshot_date = '2026-10-31' and s.overview = 'open_tasks'
                            and s.dims = '{"market": "GB", "type": "EMAIL", "status": "NOT_STARTED"}')
             || ' ' || (select c.measures ->> 'overdue' from cma.flash_compute_of(v_t1, 'open_tasks') c
                        where c.dims = '{"market": "GB", "type": "EMAIL", "status": "NOT_STARTED"}')
             || ' | ' || (select s.measures ->> 'oldest_age_days' from cma.flash_snapshot s
                          where s.tenant_id = v_t1 and s.snapshot_date = '2026-10-31' and s.overview = 'open_deals'
                            and s.dims = '{"market": "GB", "pipeline": "p1", "stage": "s2"}')
             || ' ' || (select ((c.measures ->> 'oldest_age_days')::integer > 1)::text from cma.flash_compute_of(v_t1, 'open_deals') c
                        where c.dims = '{"market": "GB", "pipeline": "p1", "stage": "s2"}');
    v_rows := v_rows || array['37', 'B21 a month end''s snapshot taken after midnight measures against its own date: due on the last day is not past due, not overdue; ages of that date',
      case when v_txt = '1/1 2/0 | 0 1 | 1 true' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B25. a SKU holding an @ is stored as other (a snapshot holds no @), the take succeeds, the list behind the cell
    --      finds the order by it; no id left out of the lists
    v_txt := v_c || ' ' || (select string_agg(s.dims ->> 'sku' || '=' || (s.measures ->> 'units'), ',' order by (s.dims ->> 'sku') collate "C") from cma.flash_snapshot s
                            where s.tenant_id = v_t1 and s.snapshot_date = '2026-10-31' and s.overview = 'orders' and s.dims ? 'sku' and s.dims ->> 'market' = 'GB')
             || ' ' || (select count(*) from cma.flash_snapshot s where s.tenant_id = v_t1 and strpos(s.dims::text, '@') > 0)
             || ' ' || (cma.flash_rows_of(v_t1, 'orders', '{"sku": "other"}', 'created_at', false, 10, 0, '2026-10-31', '2026-10-31') -> 'rows' -> 0 ->> 'order_number');
    v_rows := v_rows || array['41', 'B25 a SKU with an @ is stored as other: the take succeeds and its list finds the order',
      case when v_txt = 'true 0 A=1,other=1 0 #1005' and not v_provoke then 'ok' else 'FAIL' end, v_txt];
    update cma.device set end_of_life_on = v_today + 30 where tenant_id = v_t1 and source_id = 'rec-4';
    delete from cma.crm_task where tenant_id = v_t1 and source_id = 'k-4';
    delete from cma.crm_record where tenant_id = v_t1 and source_id = 'deal-5';

    -- B11. flows summed over the stored dates equal the live period (30 and 31 October), amounts per currency
    v_txt := '';
    for o in select x.key from cma.flash_overviews() x where x.kind = 'flow' order by x.sort_order loop
      if pg_temp.v0008zn_stored(v_t1, o.key, array[date '2026-10-30', date '2026-10-31'])
         is distinct from pg_temp.v0008zn_figs(v_t1, o.key, '2026-10-30', '2026-10-31') then
        v_txt := v_txt || o.key || ' differs; ';
      end if;
    end loop;
    v_txt := v_txt || (select c.measures ->> 'amount' from cma.flash_compute_of(v_t1, 'orders', '2026-10-30', '2026-10-31') c where c.dims = '{}');
    v_rows := v_rows || array['27', 'B11 flows summed over dates equal the live period; amounts never summed across currencies',
      case when v_txt = '{"EUR": 40.00, "GBP": 75.00}' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B12. a source the tenant has not set up gives no figures, never zeros: tenant two's overviews, its document and its
    --      landing (data quality alone, which needs no source)
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    v_txt := (select string_agg(x.key || '=' || (select count(*) from cma.flash_compute_of(v_t2, x.key, '2026-10-30', '2026-10-30')), ' ' order by x.sort_order)
              from cma.flash_overviews() x);
    j := cma.flash_overview('customers');
    v_txt := v_txt || ' | ' || (j ->> 'set_up') || ' ' || coalesce(j ->> 'totals', 'null') || ' ' || (j -> 'rows')::text;
    j := cma.flash_page();
    v_txt := v_txt || ' | ' || (select string_agg(c ->> 'key' || ':' || (c ->> 'set_up') || ':' || coalesce(c ->> 'value', 'null'), ' ' order by (c ->> 'key') collate "C")
                                from jsonb_array_elements(j -> 'overviews') c where c ->> 'key' in ('customers', 'installed_base', 'data_quality'))
             || ' | ' || (select string_agg(x || ':' || (cma.flash_headline(x) ->> 'set_up') || ':' || coalesce(cma.flash_headline(x) ->> 'value', 'null'), ' ' order by x collate "C")
                          from unnest(array['customers', 'data_quality', 'orders']) x)
             || ' | ' || (cma.flash_rows('customers') ->> 'set_up') || ' ' || (cma.flash_rows('data_quality') ->> 'set_up')
             || ' ' || ((j ->> 'today')::date = cma.tenant_today_of(v_t2))::text || ' ' || (j ->> 'time_zone');
    v_rows := v_rows || array['28', 'B12 not set up: no figures and no rows, never zeros; data quality alone; the landing''s cards and headlines; the rows say so; the tenant''s today and zone',
      case when v_txt = 'customers=0 subscriptions=0 installed_base=0 churn=0 orders=0 payments=0 open_deals=0 open_tickets=0 open_tasks=0 reviews=0 data_quality=1 | '
                        || 'false null [] | customers:false:null data_quality:true:null installed_base:false:null | '
                        || 'customers:false:null data_quality:true:0 orders:false:null | false true true Europe/Amsterdam'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B13. tenant isolation: tenant two's admin sees none of tenant one's snapshots, runs, lists or findings, reads none
    --      of its figures, writes none of its rows (42501)
    v_txt := (select count(*) from cma.flash_snapshot)::text || ' ' || (select count(*) from cma.flash_snapshot_run)::text
             || ' ' || (select count(*) from cma.flash_snapshot_ids)::text || ' ' || (select count(*) from cma.flash_watch_finding)::text
             || ' ' || (select count(*) from cma.flash_compute_of(v_t1, 'customers'))::text
             || ' ' || (cma.flash_rows_of(v_t1, 'customers', '{}', 'lifetime_orders', false, 10, 0, null, null) ->> 'total')
             || ' ' || pg_temp.v0008zn_code(format('insert into cma.flash_snapshot (tenant_id, snapshot_date, overview, dims, measures, definition_version, computed_at, run_id) '
                                                   || 'values (%L, ''2026-10-01'', ''customers'', ''{}'', ''{}'', ''0008zn'', now(), uuidv7())', v_t1));
    v_rows := v_rows || array['29', 'B13 tenant isolation: nothing of tenant one seen, read or written by tenant two',
      case when v_txt = '0 0 0 0 0 0 42501' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B14. the refusals: an agent (CMA06) for every read and the file record; the analyst's take (no flash.snapshot, CMA06)
    --      and a take at another instant than now by the application (no execute, 42501); filters, sort, limit, overview,
    --      market and dates out of form, a period past today (CMA04); a date without a snapshot (CMA02); no change by the
    --      application (42501), a finding resolved by a person included; reopened by the owner (CMA03)
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_agent1::text, true);
    v_txt := pg_temp.v0008zn_code('select cma.flash_overview(''customers'')')
             || ' ' || pg_temp.v0008zn_code('select cma.flash_rows(''customers'')')
             || ' ' || pg_temp.v0008zn_code('select cma.flash_page()')
             || ' ' || pg_temp.v0008zn_code('select cma.flash_snapshots()')
             || ' ' || pg_temp.v0008zn_code('select cma.data_quality_rows(''customer_required_ref_missing'')')
             || ' ' || pg_temp.v0008zn_code('select cma.flash_file_record(''customers'', ''rows'', ''{}'', null, null, null, null, 1)');
    perform set_config('app.user_id', v_analyst1::text, true);
    v_txt := v_txt || ' | ' || pg_temp.v0008zn_code(format('select cma.flash_snapshot_take(%L)', v_t1))
             || ' ' || pg_temp.v0008zn_code(format('select cma.flash_snapshot_take_at(%L, now() - interval ''1 day'')', v_t1))
             || ' ' || pg_temp.v0008zn_code('select cma.flash_rows(''customers'', ''{"email": "x"}'')')
             || ' ' || pg_temp.v0008zn_code('select cma.flash_rows(''customers'', ''{"measure": "devices"}'')')
             || ' ' || pg_temp.v0008zn_code('select cma.flash_rows(''customers'', ''{}'', ''email'')')
             || ' ' || pg_temp.v0008zn_code('select cma.flash_rows(''customers'', ''{}'', null, false, 50001)')
             || ' ' || pg_temp.v0008zn_code('select cma.flash_overview(''nope'')')
             || ' ' || pg_temp.v0008zn_code('select cma.flash_overview(''customers'', ''gb'')')
             || ' ' || pg_temp.v0008zn_code(format('select cma.flash_overview(''customers'', null, %L)', v_today))
             || ' ' || pg_temp.v0008zn_code('select cma.flash_overview(''orders'', null, null, ''2026-10-31'', ''2026-10-30'')')
             || ' ' || pg_temp.v0008zn_code('select cma.flash_overview(''orders'', null, null, ''2025-10-01'', ''2026-10-30'')')
             || ' ' || pg_temp.v0008zn_code(format('select cma.flash_overview(''orders'', null, null, %L, %L)', v_today, v_today + 1))
             || ' ' || pg_temp.v0008zn_code('select cma.flash_overview(''customers'', null, ''2026-10-29'')')
             || ' ' || pg_temp.v0008zn_code('select cma.flash_rows(''customers'', ''{}'', null, false, 500, 0, ''2026-10-30'')');
    -- an open finding for the moment of the checks, so a person's move from open to resolved is really tried
    perform set_config('role', 'cma_owner', true);
    insert into cma.flash_watch_finding (tenant_id, snapshot_date, kind, overview, dims, measure, value, previous, threshold)
    values (v_t1, '2026-10-31', 'jump', 'subscriptions', '{"market": "NL"}', 'active_subscriptions', 30, 10, 10);
    perform set_config('role', 'cma_app', true);
    v_txt := v_txt || ' | ' || pg_temp.v0008zn_code('update cma.flash_snapshot set measures = ''{}''')
             || ' ' || pg_temp.v0008zn_code('delete from cma.flash_snapshot_run')
             || ' ' || pg_temp.v0008zn_code('delete from cma.flash_snapshot_ids')
             || ' ' || pg_temp.v0008zn_code('delete from cma.flash_watch_finding')
             || ' ' || pg_temp.v0008zn_code('update cma.flash_watch_finding set state = ''resolved'', resolved_on = ''2026-11-30'' where state = ''open''')
             || ' ' || pg_temp.v0008zn_code('update cma.flash_watch_finding set state = ''resolved'', resolved_on = ''2026-11-30''');
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || ' ' || pg_temp.v0008zn_code(format('update cma.flash_watch_finding set state = ''open'', resolved_on = null where tenant_id = %L', v_t1));
    delete from cma.flash_watch_finding f where f.tenant_id = v_t1 and f.kind = 'jump' and f.overview = 'subscriptions' and f.state = 'open';
    v_rows := v_rows || array['31', 'B14 the refusals: an agent, a take by a person or at another instant, forms, dates, insert only, a finding''s state',
      case when v_txt = 'CMA06 CMA06 CMA06 CMA06 CMA06 CMA06 | CMA06 42501 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA02 CMA02 | '
                        || '42501 42501 42501 42501 42501 42501 CMA03'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B15. the lists, as the analyst: a measure's records are its figure's; customers by total spent, sorted within
    --      currency (currency first); a customer's row (references, contact link, orders, subscriptions); the field devices;
    --      orders of a SKU over a period; a past month end's frozen list, and none for another date
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_analyst1::text, true);
    j := cma.flash_rows('customers', '{"measure": "active_customers"}');
    v_txt := (j ->> 'total');
    j := cma.flash_rows('customers', '{}', 'total_spent', true);
    v_txt := v_txt || ' ' || (select string_agg(r ->> 'customer_id', ',' order by o2) from jsonb_array_elements(j -> 'rows') with ordinality x(r, o2));
    select r::text into v_a from jsonb_array_elements(j -> 'rows') r where r ->> 'customer_id' = 'cu-1';
    v_txt := v_txt || ' | ' || (v_a::jsonb ->> 'refs') || ' ' || (v_a::jsonb ->> 'contact_url') || ' ' || (v_a::jsonb ->> 'order_ids')
             || ' ' || (v_a::jsonb ->> 'orders_held') || ' ' || (v_a::jsonb ->> 'subscription_ids') || ' ' || (v_a::jsonb ->> 'devices');
    v_txt := v_txt || ' | ' || (cma.flash_rows('installed_base', '{"measure": "in_field"}') ->> 'total')
             || ' ' || (cma.flash_rows('installed_base', '{"link": "not_found", "market": "GB"}') -> 'rows' -> 0 ->> 'serial')
             || ' ' || (cma.flash_rows('orders', '{"sku": "A"}', 'created_at', false, 500, 0, null, '2026-10-30', '2026-10-31') ->> 'total')
             || ' ' || (cma.flash_rows('payments', '{"measure": "failed_renewals"}', 'at', false, 500, 0, null, '2026-10-30', '2026-10-31') -> 'rows' -> 0 ->> 'record_ref');
    j := cma.flash_rows('subscriptions', '{}', 'subscription_id', true, 500, 0, '2026-10-31');
    v_txt := v_txt || ' | ' || (j ->> 'total') || ' ' || (select string_agg(r ->> 'source_id' || ':' || (r ->> 'state'), ',' order by o2)
                                                         from jsonb_array_elements(j -> 'rows') with ordinality x(r, o2))
             || ' ' || pg_temp.v0008zn_code('select cma.flash_rows(''subscriptions'', ''{}'', null, false, 500, 0, ''2026-10-30'')')
             || ' ' || pg_temp.v0008zn_code('select cma.flash_rows(''orders'', ''{}'', null, false, 500, 0, ''2026-10-31'')');
    v_rows := v_rows || array['32', 'B15 the lists: a measure''s records, sorting within currency, a customer''s row, devices, a SKU, a month end''s frozen list',
      case when v_txt = '2 cu-5,cu-1,cu-4,cu-2,cu-3,cu-6 | {"netsuite": "NS-1"} https://crm.example/portal-1/contact/c-1 ["#1005", "#1001"] 2 ["s-1", "s-3"] 2 | '
                        || '4 SN-4 3 s-1 | 3 s-5:active,s-4:active,s-1:active CMA02 CMA02'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B16. the overview's document: totals of a market, labels, settings, a flow from snapshots with its missing dates,
    --      churn's active subscriptions at the period's end, data quality's history (a check per stored date: 10 dates, the
    --      check without a row on 27 October), a file read in the audit log
    j := cma.flash_overview('subscriptions', 'GB');
    v_txt := (j -> 'totals' ->> 'active_subscriptions') || ' ' || (j -> 'labels' -> 'store' ->> 'shop-gb') || ' ' || (j -> 'settings' ->> 'active_subscription_statuses');
    j := cma.flash_overview('orders', null, '2026-10-31', '2026-10-28', '2026-10-31');
    v_txt := v_txt || ' | ' || (j ->> 'mode') || ' ' || (j -> 'totals' ->> 'orders') || ' ' || (j -> 'days')::text;
    j := cma.flash_overview('churn', null, null, '2026-10-30', '2026-10-31');
    v_txt := v_txt || ' | ' || (j -> 'totals' ->> 'churned') || ' ' || (j ->> 'active_at_end');
    j := cma.flash_overview('data_quality', null, '2026-10-31');
    v_txt := v_txt || ' | ' || (select count(*) from jsonb_array_elements(j -> 'history') h where h ->> 'check' = 'active_subscription_without_device')
             || ' ' || (j -> 'labels' -> 'check' ->> 'device_required_ref_missing');
    -- the landing: as of 31 October the stored headlines and the snapshot before; now the latest snapshot to compare with,
    --      the live headline per card (cma.flash_headline) equal to the overview's own totals
    j := cma.flash_page(null, '2026-10-31');
    v_txt := v_txt || ' | ' || (select string_agg(c ->> 'key' || '=' || coalesce(c ->> 'value', '-') || '/' || coalesce(c ->> 'previous', '-'), ' ' order by (c ->> 'key') collate "C")
                                from jsonb_array_elements(j -> 'overviews') c where c ->> 'key' in ('customers', 'orders', 'churn'));
    j := cma.flash_page();
    v_txt := v_txt || ' | ' || (select string_agg(c ->> 'key' || '=' || coalesce(c ->> 'value', '-') || '/' || coalesce(c ->> 'previous', '-')
                                                  || '@' || coalesce(c ->> 'previous_on', '-'), ' ' order by (c ->> 'key') collate "C")
                                from jsonb_array_elements(j -> 'overviews') c where c ->> 'key' in ('customers', 'installed_base'))
             || ' ' || (cma.flash_headline('customers') ->> 'value') || ' ' || (cma.flash_headline('orders', null, '2026-10-30', '2026-10-31') ->> 'value')
             || ' ' || (cma.flash_headline('customers', 'NL') ->> 'value') || ' ' || jsonb_array_length(j -> 'watch')
             || ' ' || (j ->> 'first_snapshot_date') || ' ' || (cma.flash_page(null, '2026-10-29') ->> 'snapshot_missing')
             || ' ' || (cma.flash_page(null, '2026-10-29') ->> 'nearest_before') || '/' || (cma.flash_page(null, '2026-10-29') ->> 'nearest_after');
    perform cma.flash_file_record('customers', 'rows', '{"market": "GB", "measure": "active_customers"}', 'GB', null, null, null, 2);
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || ' | ' || (select al.new_row::text || ':' || (al.actor_user_id = v_analyst1)::text from cma.audit_log al
                                where al.tenant_id = v_t1 and al.table_name = 'flash_file');
    v_rows := v_rows || array['33', 'B16 the document: a market''s totals, labels, settings; a flow from snapshots; churn at the end; history; the landing; the file read audited',
      case when v_txt = '3 Shop GB ["active"] | snapshot 4 {"covered": 3, "missing": ["2026-10-29"]} | 2 3 | 9 Devices lacking a required named id, with the ids missing | '
                        || 'churn=1/1 customers=2/2 orders=2/2 | customers=-/2@2026-10-31 installed_base=-/4@2026-10-31 2 4 0 0 2026-10-21 true 2026-10-28/2026-10-30 | '
                        || '{"part": "rows", "rows": 2, "market": "GB", "filters": {"market": "GB", "measure": "active_customers"}, "overview": "customers"}:true'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B17. D2: a contact linked to a store customer is held (inserted, with its references), one linked to nothing is
    --      not; its customer's finding goes; the privacy deletion (the ingest's two calls) clears the link
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_ingest1::text, true);
    select string_agg(x.source_id || ':' || x.outcome, ' ' order by x.source_id collate "C") into v_txt
    from cma.ingest_upsert_contacts(v_crm, '[{"sourceId": "c-9", "country": "GB", "refs": {"netsuite": "NS-9"}}, {"sourceId": "c-77", "country": "GB"}]') x;
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || ' ' || (select count(*) from cma.data_quality_of(v_t1) q where q.check_key = 'customer_required_ref_missing' and q.object_id = 'cu-4');
    perform set_config('role', 'cma_app', true);
    -- the ingest's forget: the contact, then the store customers' link (0008h), as ingest/src/core/store.mjs calls them
    perform cma.ingest_contact_forget(v_crm, 'c-9');
    v_txt := v_txt || ' ' || cma.forget_commerce_contact_links(v_crm, 'c-9');
    -- read in a statement of its own, so its snapshot sees the cleared link
    v_txt := v_txt || ' '
             || coalesce((select cu.crm_contact_source_id from cma.commerce_customer cu where cu.tenant_id = v_t1 and cu.source_id = 'cu-4'), 'none');
    v_rows := v_rows || array['34', 'B17 D2: a contact linked to a store customer held, another not; the finding goes; the deletion clears the link',
      case when v_txt = 'c-77:not_held c-9:inserted 0 1 none' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B18. nothing stored holds an @: tenant one's snapshot rows, runs, id lists and findings
    perform set_config('role', 'cma_owner', true);
    v_txt := (select count(*) from cma.flash_snapshot s where s.tenant_id = v_t1 and (s.dims::text || s.measures::text) like '%@%')::text
             || ' ' || (select count(*) from cma.flash_snapshot_run r where r.tenant_id = v_t1 and (r.counts::text || r.sources::text || r.settings::text) like '%@%')
             || ' ' || (select count(*) from cma.flash_snapshot_ids x where x.tenant_id = v_t1 and x.source_id like '%@%')
             || ' ' || (select count(*) from cma.flash_watch_finding f where f.tenant_id = v_t1 and (f.dims::text || f.detail::text) like '%@%');
    v_rows := v_rows || array['35', 'B18 nothing stored holds an @',
      case when v_txt = '0 0 0 0' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B19. the job's own path, as the job runs it: the application (cma_app, row-level security on, no write on the Flash
    --      tables) with tenant two's scheduler user (flash.snapshot) takes yesterday through cma.flash_snapshot_take (the
    --      definer) as of now (snapshot time 00:00, so it is due): the rows stored, its run succeeded, the audit rows naming
    --      the scheduler user, an open finding resolved through the guard; a second take of the date writes nothing; none
    --      of tenant one's records reaches tenant two's snapshot
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    perform cma.set_tenant_setting('flash.snapshot_local_time', '00:00');
    perform set_config('role', 'cma_owner', true);
    v_today := (now() at time zone 'Europe/Amsterdam')::date;
    insert into cma.flash_watch_finding (tenant_id, snapshot_date, kind, overview, dims, measure, value, previous, threshold)
    values (v_t2, v_today - 2, 'jump', 'customers', '{"market": "GB"}', 'active_customers', 30, 10, 10);
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_sched2::text, true);
    j := cma.flash_snapshot_take(v_t2);
    v_txt := coalesce(j ->> 'taken', '-') || ' ' || ((j ->> 'date')::date = v_today - 1) || ' ' || coalesce(j ->> 'data_quality', '-') || ' '
             || coalesce(j ->> 'watch_resolved', '-');
    j := cma.flash_snapshot_take(v_t2);
    v_txt := v_txt || ' ' || coalesce(j ->> 'taken', '-') || ':' || coalesce(j ->> 'reason', '-');
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || ' | ' || (select count(*) from cma.flash_snapshot_run r where r.tenant_id = v_t2 and r.status = 'succeeded' and r.snapshot_date = v_today - 1)
             || ' ' || (select count(*) from cma.flash_snapshot s where s.tenant_id = v_t2 and s.snapshot_date = v_today - 1)
             || ' ' || (select f.state || ':' || (f.resolved_on = v_today - 1) from cma.flash_watch_finding f where f.tenant_id = v_t2 and f.kind = 'jump')
             || ' ' || (select count(*) > 0 from cma.audit_log a where a.tenant_id = v_t2 and a.table_name = 'flash_snapshot_run' and a.action = 'insert'
                                                                 and a.actor_user_id = v_sched2)
             || ' ' || (select count(*) > 0 from cma.audit_log a where a.tenant_id = v_t2 and a.table_name = 'flash_watch_finding' and a.action = 'update'
                                                                 and a.actor_user_id = v_sched2);
    v_rows := v_rows || array['36', 'B19 the job''s own path: a take as the application with the scheduler user, its rows, run, audit and a finding resolved; a second writes nothing',
      case when v_txt = 'true true 1 1 false:taken | 1 1 resolved:true true true' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B20. the snapshot time's rule (Decision log, 2 November 2026), on tenant three with the job's hourly instants at
    --      minute 20 (Europe/Amsterdam, as of the owner with its scheduler user): every date taken exactly once, by the
    --      first run after its due time (the day after it at flash.snapshot_local_time), for 00:30, 23:20 and 23:59; one
    --      skipped run: the date taken by the next run, marked late; a date that stopped being the latest due one without a
    --      take (the job down a day): recorded as missed by the next take, never taken afterwards
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.tenant_id', v_t3::text, true);
    perform set_config('app.user_id', v_sched3::text, true);
    v_txt := '';
    -- 00:30 (the default): 3 October is due at 4 October 00:30; the 4 October 00:20 run finds 2 October (taken by the 3
    -- October 01:20 run) the latest due date, the 01:20 run takes 3 October, the 02:20 run finds it taken, and so does the
    -- 5 October 00:20 run
    foreach v_a in array array['2026-10-03 01:20', '2026-10-04 00:20', '2026-10-04 01:20', '2026-10-04 02:20', '2026-10-05 00:20', '2026-10-05 01:20',
                               -- one skipped run: 6 October 01:20 does not run, 02:20 takes 5 October, late
                               '2026-10-06 02:20'] loop
      j := cma.flash_snapshot_take_at(v_t3, (v_a || ' Europe/Amsterdam')::timestamptz);
      v_txt := v_txt || case when (j ->> 'taken')::boolean then 'took' else j ->> 'reason' end || ':' || right(j ->> 'date', 2) || ' ';
    end loop;
    -- 23:20: 6 October is due at 7 October 23:20 and taken by that run (on time), not by 22:20
    insert into cma.tenant_setting (tenant_id, key, value) values (v_t3, 'flash.snapshot_local_time', '23:20');
    foreach v_a in array array['2026-10-06 23:20', '2026-10-07 22:20', '2026-10-07 23:20'] loop
      j := cma.flash_snapshot_take_at(v_t3, (v_a || ' Europe/Amsterdam')::timestamptz);
      v_txt := v_txt || case when (j ->> 'taken')::boolean then 'took' else j ->> 'reason' end || ':' || right(j ->> 'date', 2) || ' ';
    end loop;
    -- 23:59: 7 October is due at 8 October 23:59, so the 23:20 run finds 6 October and the next day's 00:20 run takes 7
    -- October (21 minutes after, on time)
    update cma.tenant_setting set value = '23:59' where tenant_id = v_t3 and key = 'flash.snapshot_local_time';
    foreach v_a in array array['2026-10-08 23:20', '2026-10-09 00:20',
                               -- the job down from 9 October 01:20 to 11 October 00:00: 8 October is never the latest due date
                               -- at a run, so the 11 October 00:20 run records it missed and takes 9 October
                               '2026-10-11 00:20'] loop
      j := cma.flash_snapshot_take_at(v_t3, (v_a || ' Europe/Amsterdam')::timestamptz);
      v_txt := v_txt || case when (j ->> 'taken')::boolean then 'took' else j ->> 'reason' end || ':' || right(j ->> 'date', 2) || ' ';
    end loop;
    -- the missed date is never taken afterwards, whatever the snapshot time
    update cma.tenant_setting set value = '00:30' where tenant_id = v_t3 and key = 'flash.snapshot_local_time';
    j := cma.flash_snapshot_take_at(v_t3, '2026-10-09 01:20 Europe/Amsterdam');
    v_txt := v_txt || case when (j ->> 'taken')::boolean then 'took' else j ->> 'reason' end || ':' || right(j ->> 'date', 2)
             || ' | ' || (select string_agg(right(r.snapshot_date::text, 2) || ':' || r.status || case when r.late then ':late' else '' end, ' '
                                            order by r.snapshot_date, r.started_at)
                          from cma.flash_snapshot_run r where r.tenant_id = v_t3)
             || ' | ' || (select string_agg(distinct right(s.snapshot_date::text, 2) collate "C", ',') from cma.flash_snapshot s where s.tenant_id = v_t3)
             || ' | ' || (select count(*) from cma.flash_watch_finding f where f.tenant_id = v_t3 and f.state = 'open' and f.kind = 'snapshot_missing');
    v_rows := v_rows || array['38', 'B20 the snapshot time: each date once from its due time for 00:30, 23:20 and 23:59; a skipped run taken late; a missed date recorded, never taken',
      case when v_txt = 'took:02 taken:02 took:03 taken:03 taken:03 took:04 took:05 taken:05 taken:05 took:06 taken:06 took:07 took:09 missed:08 | '
                        || '02:succeeded 03:succeeded 04:succeeded 05:succeeded:late 06:succeeded 07:succeeded 08:missed 09:succeeded | 02,03,04,05,06,07,09 | 1'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B23. a watch that fails never costs the snapshot: with every write of a finding refused (a throwaway trigger,
    --      rolled back with the block), the take of 10 October stores its figures and its run says succeeded with the
    --      watch's error code; the open finding stays open, and the next take resolves it
    create function cma.v0008zn_refuse() returns trigger language plpgsql as $f$ begin raise exception 'refused'; end $f$;
    create trigger v0008zn_refuse before insert or update on cma.flash_watch_finding for each row execute function cma.v0008zn_refuse();
    update cma.tenant_setting set value = '23:59' where tenant_id = v_t3 and key = 'flash.snapshot_local_time';
    j := cma.flash_snapshot_take_at(v_t3, '2026-10-12 00:20 Europe/Amsterdam');
    v_txt := (j ->> 'taken') || ' ' || (j ->> 'date') || ' ' || coalesce(j ->> 'watch_error', '-')
             || ' ' || (select r.status || ':' || coalesce(r.watch_error, '-') from cma.flash_snapshot_run r where r.tenant_id = v_t3 and r.snapshot_date = '2026-10-10')
             || ' ' || (select count(*) from cma.flash_snapshot s where s.tenant_id = v_t3 and s.snapshot_date = '2026-10-10')
             || ' ' || (select f.state from cma.flash_watch_finding f where f.tenant_id = v_t3 and f.kind = 'snapshot_missing');
    drop trigger v0008zn_refuse on cma.flash_watch_finding;
    drop function cma.v0008zn_refuse();
    j := cma.flash_snapshot_take_at(v_t3, '2026-10-13 00:20 Europe/Amsterdam');
    v_txt := v_txt || ' | ' || (j ->> 'taken') || ' ' || (j ->> 'date') || ' ' || coalesce(j ->> 'watch_error', '-')
             || ' ' || (select f.state || ':' || f.resolved_on from cma.flash_watch_finding f where f.tenant_id = v_t3 and f.kind = 'snapshot_missing');
    v_rows := v_rows || array['39', 'B23 a watch that fails keeps the snapshot: the run succeeded with the watch''s error, the finding resolved by the next take',
      case when v_txt = 'true 2026-10-10 P0001 succeeded:P0001 1 open | true 2026-10-11 - resolved:2026-10-11' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B24. two stale connections alike (the same kind and adapter, no store) are one source_stale finding with both
    --      counted, not a failed take; the next take keeps it open, once
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t3, 'verifycrm', 'Verify CRM A', 'portal-a', 'crm') returning id into v_conn;
    insert into cma.sync_run (tenant_id, connection_id, job, started_at, finished_at, status)
    select v_t3, v_conn, 'reconcile', t - interval '1 minute', t, 'succeeded'
    from generate_series(timestamptz '2026-10-13 06:00 Europe/Amsterdam', timestamptz '2026-10-13 08:00 Europe/Amsterdam', interval '10 minutes') t;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t3, 'verifycrm', 'Verify CRM B', 'portal-b', 'crm') returning id into v_conn;
    insert into cma.sync_run (tenant_id, connection_id, job, started_at, finished_at, status)
    select v_t3, v_conn, 'reconcile', t - interval '1 minute', t, 'succeeded'
    from generate_series(timestamptz '2026-10-13 06:00 Europe/Amsterdam', timestamptz '2026-10-13 09:00 Europe/Amsterdam', interval '10 minutes') t;
    j := cma.flash_snapshot_take_at(v_t3, '2026-10-14 00:20 Europe/Amsterdam');
    v_txt := (j ->> 'taken') || ' ' || (j ->> 'date') || ' ' || (j ->> 'watch_opened')
             || ' ' || (select string_agg(f.dims::text || ':' || f.value || ':' || (f.detail ->> 'connections'), ' ' order by f.dims::text collate "C") from cma.flash_watch_finding f
                        where f.tenant_id = v_t3 and f.kind = 'source_stale' and f.state = 'open');
    j := cma.flash_snapshot_take_at(v_t3, '2026-10-15 00:20 Europe/Amsterdam');
    v_txt := v_txt || ' | ' || (j ->> 'taken') || ' ' || coalesce(j ->> 'watch_error', '-') || ' ' || (j ->> 'watch_opened')
             || ' ' || (select count(*) from cma.flash_watch_finding f where f.tenant_id = v_t3 and f.kind = 'source_stale');
    v_rows := v_rows || array['40', 'B24 two stale connections alike are one finding, counted; the take succeeds, and again the next day',
      case when v_txt = 'true 2026-10-12 1 {"source": "crm", "adapter": "verifycrm"}:980:2 | true - 0 1' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B22. writes only through the take: the application inserts no row into any of the four tables (42501), runs none of
    --      the take's writers (42501), and a writer run as the owner for a person without flash.snapshot is refused (CMA06)
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_sched1::text, true);
    v_txt := pg_temp.v0008zn_code(format('insert into cma.flash_snapshot_run (tenant_id, snapshot_date, due_at, started_at, finished_at, status) '
                                         || 'values (%L, ''2026-10-29'', now(), now(), now(), ''succeeded'')', v_t1))
             || ' ' || pg_temp.v0008zn_code(format('insert into cma.flash_snapshot (tenant_id, snapshot_date, overview, dims, measures, definition_version, computed_at, run_id) '
                                                   || 'values (%L, ''2026-10-29'', ''customers'', ''{}'', ''{}'', ''0008zn'', now(), uuidv7())', v_t1))
             || ' ' || pg_temp.v0008zn_code(format('insert into cma.flash_snapshot_ids (tenant_id, snapshot_date, record_kind, source_id, connection_id, market, state, run_id) '
                                                   || 'values (%L, ''2026-09-30'', ''customer'', ''cu-1'', %L, ''GB'', ''active'', uuidv7())', v_t1, v_shop_gb))
             || ' ' || pg_temp.v0008zn_code(format('insert into cma.flash_watch_finding (tenant_id, snapshot_date, kind) values (%L, ''2026-10-29'', ''snapshot_missing'')', v_t1))
             || ' | ' || pg_temp.v0008zn_code(format('select cma.flash_snapshot_ids_write_of(%L, ''2026-09-30'', uuidv7())', v_t1))
             || ' ' || pg_temp.v0008zn_code(format('select cma.flash_snapshot_ids_expire_of(%L)', v_t1))
             || ' ' || pg_temp.v0008zn_code(format('select cma.flash_watch_of(%L, ''2026-10-29'', now())', v_t1))
             || ' ' || pg_temp.v0008zn_code(format('select cma.flash_snapshot_take_at(%L, now())', v_t1));
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_txt := v_txt || ' | ' || pg_temp.v0008zn_code(format('select cma.flash_snapshot_ids_write_of(%L, ''2026-09-30'', uuidv7())', v_t1))
             || ' ' || pg_temp.v0008zn_code(format('select cma.flash_snapshot_ids_expire_of(%L)', v_t1))
             || ' ' || pg_temp.v0008zn_code(format('select cma.flash_watch_of(%L, ''2026-10-29'', now())', v_t1))
             || ' ' || pg_temp.v0008zn_code(format('select cma.flash_snapshot_take_at(%L, ''2026-11-02 01:00 Europe/Amsterdam'')', v_t1))
             || ' ' || (select count(*) from cma.flash_snapshot_run r where r.tenant_id = v_t1 and r.snapshot_date in ('2026-09-30', '2026-11-01'));
    v_rows := v_rows || array['42', 'B22 writes only through the take: no insert by the application, no writer for it, none for a person without flash.snapshot',
      case when v_txt = '42501 42501 42501 42501 | 42501 42501 42501 42501 | CMA06 CMA06 CMA06 CMA06 0' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B26. the id lists' expiry takes no caller's date: its cutoff is the tenant's today less flash.id_list_retention_months.
    --      On tenant two, a take as of 30 December 2999 (the owner's) removes the list of January 2010 and keeps the one of
    --      September 2026, one audit row for the removal
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_sched2::text, true);
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t2, 'verifyphone', 'Verify phone', 'phone-1', 'telephony') returning id into v_conn;
    insert into cma.flash_snapshot_run (id, tenant_id, snapshot_date, due_at, started_at, finished_at, status)
    select uuidv7(), v_t2, d, cma.flash_due_at_of('Europe/Amsterdam', '00:00', d), now(), now(), 'succeeded'
    from unnest(array[date '2010-01-31', date '2026-09-30', date '2999-12-28']) d;
    insert into cma.flash_snapshot_ids (tenant_id, snapshot_date, record_kind, source_id, connection_id, market, state, run_id)
    select v_t2, r.snapshot_date, 'device', 'rec-x', v_conn, 'GB', 'field', r.id
    from cma.flash_snapshot_run r where r.tenant_id = v_t2 and r.snapshot_date in ('2010-01-31', '2026-09-30');
    j := cma.flash_snapshot_take_at(v_t2, '2999-12-30 12:00 Europe/Amsterdam');
    v_txt := (j ->> 'taken') || ' ' || (j ->> 'date') || ' ' || (j ->> 'ids_expired')
             || ' ' || (select string_agg(x.snapshot_date::text, ',' order by x.snapshot_date) from cma.flash_snapshot_ids x where x.tenant_id = v_t2)
             || ' ' || (select (a.old_row ->> 'before')::date = (cma.tenant_today_of(v_t2) - interval '84 months')::date from cma.audit_log a
                        where a.tenant_id = v_t2 and a.table_name = 'flash_snapshot_ids' and a.action = 'delete');
    v_rows := v_rows || array['43', 'B26 a far-future take removes only the lists past the retention from the tenant''s today: the expiry takes no caller''s date',
      case when v_txt = 'true 2999-12-29 1 2026-09-30 true' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B27. the statuses and joins from configuration: the ended statuses set to expired alone (churn of 30 October none, of
    --      31 October one; the device on a canceled subscription no finding); a contact deleted in the CRM is contact_deleted,
    --      fixed in the CRM; a market the register holds no device of gives no active subscription without a device; a
    --      device's subscription reference is matched in its own market; a frozen list that expired says so (CMA02); a
    --      file record's filters are the overview's own and its date has ended (CMA04); the required references empty
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    perform set_config('role', 'cma_app', true);
    perform cma.set_tenant_setting('flash.ended_subscription_statuses', 'expired');
    perform set_config('role', 'cma_owner', true);
    v_txt := pg_temp.v0008zn_figs(v_t1, 'churn', '2026-10-30', '2026-10-30') || ' ' || pg_temp.v0008zn_figs(v_t1, 'churn', '2026-10-31', '2026-10-31')
             || ' ' || (select count(*) from cma.data_quality_of(v_t1) q where q.check_key = 'field_device_on_ended_subscription');
    update cma.crm_contact set source_deleted_at = now() where tenant_id = v_t1 and source_id = 'c-2';
    v_txt := v_txt || ' | ' || (select q.value || '/' || cma.data_quality_fix_in(q.check_key, q.value) from cma.data_quality_of(v_t1) q
                                where q.check_key = 'customer_required_ref_missing' and q.object_id = 'cu-2');
    update cma.crm_contact set source_deleted_at = null where tenant_id = v_t1 and source_id = 'c-2';
    update cma.device set market = 'NL' where tenant_id = v_t1;
    v_txt := v_txt || ' | ' || (select count(*) from cma.data_quality_of(v_t1) q where q.check_key = 'active_subscription_without_device')
             || ' ' || (select string_agg(d.source_id || ':' || d.link, ',' order by d.source_id collate "C") from cma.flash_devices_of(v_t1, v_today) d
                        where d.subscription_ref is not null);
    update cma.device set market = case when source_id = 'rec-5' then 'NL' else 'GB' end where tenant_id = v_t1;
    delete from cma.flash_snapshot_ids x where x.tenant_id = v_t1 and x.snapshot_date = '2026-10-31' and x.record_kind = 'subscription';
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_analyst1::text, true);
    begin
      perform cma.flash_rows('subscriptions', '{}', null, false, 500, 0, '2026-10-31');
      v_txt := v_txt || ' | ok';
    exception when others then
      v_txt := v_txt || ' | ' || sqlstate || ':' || (sqlerrm like '%expired%')::text;
    end;
    v_txt := v_txt || ' ' || pg_temp.v0008zn_code('select cma.flash_file_record(''customers'', ''rows'', ''{"email": "x"}'', null, null, null, null, 1)')
             || ' ' || pg_temp.v0008zn_code(format('select cma.flash_file_record(''customers'', ''rows'', ''{}'', null, %L, null, null, 1)', cma.tenant_today_of(v_t1)))
             || ' ' || pg_temp.v0008zn_code('select cma.flash_file_record(''orders'', ''rows'', ''{"sku": "A", "measure": "orders"}'', null, null, null, null, 1)');
    --      The required references empty (Pulse4all's until NetSuite holds its customers and devices; Decision log, 3 Nov
    --      2026): with_required_refs does not apply, so it is left out of the live figures and of the snapshot of 1 November,
    --      the watch does not compare it with 31 October's (thresholds at their lowest here), and it has no records (CMA04);
    --      neither required-reference check finds anything or is listed
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('commerce.required_contact_refs', '');
    perform cma.set_tenant_setting('assets.required_refs', '');
    perform cma.set_tenant_setting('flash.watch_jump_min', '0');
    perform cma.set_tenant_setting('flash.watch_jump_pct', '1');
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || ' | ' || (strpos(pg_temp.v0008zn_figs(v_t1, 'customers', null, null), 'with_required_refs') = 0)::text
             || ' ' || (select count(*) from cma.data_quality_of(v_t1) q
                        where q.check_key in ('customer_required_ref_missing', 'device_required_ref_missing'));
    perform set_config('app.user_id', v_sched1::text, true);
    j := cma.flash_snapshot_take_at(v_t1, '2026-11-02 01:00:00 Europe/Amsterdam');
    v_txt := v_txt || ' ' || (j ->> 'taken') || ' ' || (j ->> 'date')
             || ' ' || (select count(*) > 0 and bool_and(not (s.measures ? 'with_required_refs')) from cma.flash_snapshot s
                        where s.tenant_id = v_t1 and s.snapshot_date = '2026-11-01' and s.overview = 'customers')::text
             || ' ' || (select count(*) from cma.flash_watch_finding f where f.tenant_id = v_t1 and f.measure = 'with_required_refs');
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008zn_code('select cma.flash_rows(''customers'', ''{"measure": "with_required_refs"}'')')
             || ' ' || (select count(*) from cma.data_quality() d where d.check_key in ('customer_required_ref_missing', 'device_required_ref_missing'));
    v_rows := v_rows || array['44', 'B27 statuses and joins from configuration: ended statuses, contact deleted, a market not in the register, a reference in its market; an expired list; a file record''s filters and date; the required references empty: with_required_refs not applicable, no required-reference finding',
      case when v_txt = '*:churned=0 *:churned=1 GB:churned=1 GB/none/shop-gb:churned=1 0 | contact_deleted/crm | 0 rec-1:not_found,rec-2:not_found,rec-4:not_found,rec-5:not_found | '
                        || 'CMA02:true CMA04 CMA04 ok | true 0 true 2026-11-01 true 0 CMA04 0'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['59', 'B the block ran to the end', 'FAIL', sqlstate || ' ' || sqlerrm];
  end;
  insert into verify_0008zn (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008zn values (59, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- C. Speed at volume (rolled back; local databases only, with verify.volume 'true' at the top): 100,000 customers, 100,000 subscriptions, 50,000 devices,
--    200,000 orders. The volume's audit triggers are disabled inside the block (an exclusive lock on those tables until
--    the rollback, which also enables them again): the audit image of every generated row (some 1.2 million) would make
--    the setup itself take half an hour and fill the audit log of a database that keeps it
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_max_o   numeric := current_setting('verify.max_overview_ms')::numeric;
  v_max_r   numeric := current_setting('verify.max_rows_ms')::numeric;
  v_max_t   numeric := current_setting('verify.take_max_ms')::numeric;
  v_max_q   numeric := current_setting('verify.max_dq_ms')::numeric;
  v_brief_r numeric := current_setting('verify.brief_rows_ms')::numeric;
  v_over    text := '';
  v_rows    text[] := '{}';
  v_t uuid; v_analyst uuid; v_sched uuid;
  v_crm uuid; v_gb uuid; v_nl uuid; v_sgb uuid; v_snl uuid; v_reg uuid; v_rev uuid; v_chan uuid;
  o record; s text;
  v_ms numeric; v_worst numeric := 0; v_txt text := ''; v_bad text := '';
  v_t0 timestamptz;
  j jsonb;
begin
  if not current_setting('verify.volume')::boolean then
    insert into verify_0008zn values (61, 'C1 every live overview but data quality, and the landing, under verify.max_overview_ms at volume', 'skip', 'not run: volume off'),
                                     (62, 'C2 every first page of a list but data quality''s, by every sort key, under verify.max_rows_ms at volume', 'skip', 'not run: volume off'),
                                     (63, 'C3 a full take under half the job''s statement timeout at volume', 'skip', 'not run: volume off'),
                                     (64, 'C4 the data-quality overview and its lists under verify.max_dq_ms at volume', 'skip', 'not run: volume off');
    return;
  end if;
  begin
    perform set_config('lock_timeout', '10s', true);
    alter table cma.commerce_customer disable trigger audit;
    alter table cma.crm_contact disable trigger audit;
    alter table cma.crm_contact_ref disable trigger audit;
    alter table cma.subscription disable trigger audit;
    alter table cma.subscription_event disable trigger audit;
    alter table cma.device disable trigger audit;
    alter table cma.device_component disable trigger audit;
    alter table cma.commerce_order disable trigger audit;
    alter table cma.commerce_order_line disable trigger audit;
    alter table cma.crm_record disable trigger audit;
    alter table cma.crm_task disable trigger audit;
    alter table cma.review disable trigger audit;
    perform set_config('lock_timeout', '0', true);
    v_t := cma.create_tenant('verify-0008zn-volume', 'Verify 0008zn volume', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-analyst-volume@example.invalid', 'analyst') returning id into v_analyst;
    insert into cma.user_role (tenant_id, user_id, role_id) select v_t, v_analyst, ar.id from cma.app_role ar where ar.tenant_id = v_t and ar.key = 'analytics';
    select u.id into v_sched from cma.app_user u where u.tenant_id = v_t and u.email = 'scheduler@system.invalid';
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency, sort_order) values
      (v_t, 'GB', 'GB', 'Europe/London', 'en', 'GBP', 10), (v_t, 'NL', 'NL', 'Europe/Amsterdam', 'nl', 'EUR', 20);
    insert into cma.tenant_setting (tenant_id, key, value) values
      (v_t, 'commerce.required_contact_refs', 'netsuite'), (v_t, 'assets.required_refs', 'ns_internal_id'), (v_t, 'intake.start_date', '2026-01-01');
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind) values
      (v_t, 'verifycrm', 'CRM', 'portal-v', 'crm') returning id into v_crm;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind) values
      (v_t, 'verifyshop', 'Shop GB', 'vol-gb.shop.example', 'commerce') returning id into v_gb;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind) values
      (v_t, 'verifyshop', 'Shop NL', 'vol-nl.shop.example', 'commerce') returning id into v_nl;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind) values
      (v_t, 'verifysubs', 'Subs GB', 'vol-gb.shop.example', 'subscriptions') returning id into v_sgb;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind) values
      (v_t, 'verifysubs', 'Subs NL', 'vol-nl.shop.example', 'subscriptions') returning id into v_snl;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind) values
      (v_t, 'verifyregister', 'Register', 'base-v', 'assets') returning id into v_reg;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind) values
      (v_t, 'verifyreviews', 'Reviews', 'rev-v', 'reviews') returning id into v_rev;
    insert into cma.commerce_store (tenant_id, connection_id, handle, name, market, currency, time_zone) values
      (v_t, v_gb, 'vol-gb', 'GB', 'GB', 'GBP', 'Europe/London'), (v_t, v_nl, 'vol-nl', 'NL', 'NL', 'EUR', 'Europe/Amsterdam');
    -- 100,000 store customers, a third linked to a contact, half of those held, half of those with the required reference
    insert into cma.commerce_customer (tenant_id, connection_id, source_system, source_id, orders_count, amount_spent, amount_currency,
                                       crm_connection_id, crm_contact_source_id, matched_at)
    select v_t, case when g % 2 = 0 then v_gb else v_nl end, 'verifyshop', 'cu-' || g, g % 7, (g % 500) + 0.5, case when g % 2 = 0 then 'GBP' else 'EUR' end,
           case when g % 3 = 0 then v_crm end, case when g % 3 = 0 then 'c-' || g end, case when g % 3 = 0 then now() end
    from generate_series(1, 100000) g;
    -- each bulk insert's table analysed before the next one, inside the transaction (ANALYZE sees its own rows): the next
    -- insert's foreign-key checks are planned for the rows now there, not for the few the table held before (without it,
    -- the 300,000 order lines' checks could scan the 200,000 orders each, for hours); after the block the tables are
    -- analysed again, so their statistics are the database's own once more
    analyze cma.commerce_customer;
    insert into cma.crm_contact (tenant_id, connection_id, source_system, source_id, country)
    select v_t, v_crm, 'verifycrm', 'c-' || g, case when g % 2 = 0 then 'GB' else 'NL' end from generate_series(6, 100000, 6) g;
    analyze cma.crm_contact;
    insert into cma.crm_contact_ref (tenant_id, contact_id, system, slot, external_id)
    select v_t, k.id, 'netsuite', 1, 'NS-' || k.source_id from cma.crm_contact k where k.tenant_id = v_t and (substr(k.source_id, 3)::integer % 12) = 0;
    -- 100,000 subscriptions, one per customer, in its store; 230,000 events over 61 days
    analyze cma.crm_contact_ref;
    insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, current_cycle, amount_per_cycle, currency,
                                  billing_interval, billing_interval_count, paused_at)
    select v_t, case when g % 2 = 0 then v_sgb else v_snl end, 'verifysubs', 's-' || g, 'cu-' || g,
           (array['active', 'active', 'active', 'active', 'active', 'active', 'paused', 'canceled', 'expired', 'failed'])[1 + g % 10], g % 24,
           10 + g % 30, case when g % 2 = 0 then 'GBP' else 'EUR' end, 'month', 1, case when g % 10 = 6 then now() end
    from generate_series(1, 100000) g;
    insert into cma.subscription_event (tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type, occurred_at, cycle_index,
                                        status_from, status_to, reason_code)
    select v_t, case when g % 2 = 0 then v_sgb else v_snl end, 'verifysubs', 'e-' || g || '-' || k, 's-' || g,
           case k when 1 then 'renewed' when 2 then case when g % 10 = 1 then 'renew_failed' else 'renewed' end
                  else case when g % 10 = 7 then 'canceled' else 'status_changed' end end,
           timestamptz '2026-09-01 00:00 Europe/Amsterdam' + make_interval(mins => (g * 37 + k * 1013) % (61 * 1440)), g % 24,
           case when k = 3 then 'active' end, case when k = 3 then case when g % 10 = 8 then 'expired' else 'canceled' end end,
           case when k = 3 and g % 10 = 7 then 'too-expensive' end
    from generate_series(1, 100000) g cross join generate_series(1, 3) k
    where k < 3 or g % 10 in (7, 8);
    -- 50,000 devices with two components each, in the field (with a subscription reference) or in stock
    analyze cma.subscription, cma.subscription_event;
    insert into cma.device_model (tenant_id, key, name) values (v_t, 'm1', 'M1');
    insert into cma.device_component_kind (tenant_id, key, name, sort_order) values (v_t, 'pads', 'Pads', 10), (v_t, 'battery', 'Battery', 20);
    insert into cma.maintenance_rule (tenant_id, model_key, component_key, interval_months, lead_days) values (v_t, 'm1', 'pads', 24, 60), (v_t, 'm1', 'battery', 54, 60);
    insert into cma.device_status (tenant_id, key, name, is_in_field, is_in_stock, is_tracked) values
      (v_t, 'field', 'Field', true, false, true), (v_t, 'stock', 'Stock', false, true, true);
    insert into cma.device (tenant_id, connection_id, source_system, source_id, serial, model_key, market, device_status_key, warehouse_ref, customer_ref,
                            subscription_ref, first_shipped_on, external_refs)
    select v_t, v_reg, 'verifyregister', 'rec-' || g, 'SN-' || g, 'm1', case when g % 2 = 0 then 'GB' else 'NL' end,
           case when g % 5 = 0 then 'stock' else 'field' end, 'WH-' || (g % 4), 'cu-' || g, case when g % 5 <> 0 then 's-' || g end,
           date '2023-01-01' + (g % 1000), case when g % 10 = 0 then '{}'::jsonb else jsonb_build_object('ns_internal_id', (100000 + g)::text) end
    from generate_series(1, 50000) g;
    analyze cma.device;
    insert into cma.device_component (tenant_id, device_id, component_key, serial, expires_on)
    select d.tenant_id, d.id, k.key, k.key || '-' || d.source_id, case when (hashtext(d.source_id || k.key) % 3) <> 0 then date '2026-06-01' + (abs(hashtext(d.source_id || k.key)) % 1400) end
    from cma.device d cross join (values ('pads'), ('battery')) k(key) where d.tenant_id = v_t;
    -- 200,000 orders over 61 days, one or two lines each
    analyze cma.device_component;
    insert into cma.commerce_order (tenant_id, connection_id, source_system, source_id, order_name, customer_source_id, source_created_at, is_test, currency,
                                    total_amount, refunded_amount, financial_status, fulfillment_status, order_kind)
    select v_t, case when g % 2 = 0 then v_gb else v_nl end, 'verifyshop', 'o-' || g, '#' || g, 'cu-' || (1 + g % 100000),
           timestamptz '2026-09-01 00:00 Europe/Amsterdam' + make_interval(mins => (g * 7) % (61 * 1440)), g % 500 = 0,
           case when g % 2 = 0 then 'GBP' else 'EUR' end, 20 + g % 80, case when g % 50 = 0 then 5 end,
           (array['paid', 'pending', 'refunded', 'partially_refunded'])[1 + g % 4], 'fulfilled', (array['first', 'repeat', 'renewal'])[1 + g % 3]
    from generate_series(1, 200000) g;
    analyze cma.commerce_order;
    insert into cma.commerce_order_line (tenant_id, connection_id, order_source_id, line_source_id, sku, quantity, unit_price, currency)
    select co.tenant_id, co.connection_id, co.source_id, 'l-' || k || '-' || co.source_id, 'SKU-' || ((hashtext(co.source_id) & 7) + k), k, 10, co.currency
    from cma.commerce_order co cross join generate_series(1, 2) k
    where co.tenant_id = v_t and (k = 1 or (hashtext(co.source_id) & 1) = 0);
    -- the CRM: 5,000 deals, 2,000 tickets, 5,000 tasks; the reviews: 5,000
    insert into cma.connection_pipeline (tenant_id, connection_id, record_type, source_pipeline_id, label, is_counted) values
      (v_t, v_crm, 'deal', 'p1', 'Sales', true), (v_t, v_crm, 'ticket', 'tp1', 'Service', true);
    insert into cma.connection_stage (tenant_id, connection_id, record_type, source_pipeline_id, source_stage_id, label, is_closed) values
      (v_t, v_crm, 'deal', 'p1', 's1', 'Open', false), (v_t, v_crm, 'deal', 'p1', 'won', 'Won', true),
      (v_t, v_crm, 'ticket', 'tp1', 'new', 'New', false), (v_t, v_crm, 'ticket', 'tp1', 'done', 'Done', true);
    insert into cma.crm_record (tenant_id, connection_id, source_system, record_type, source_id, pipeline_id, stage_id, owner_ref, contact_source_id, market,
                                is_closed, source_created_at)
    select v_t, v_crm, 'verifycrm', 'deal', 'deal-' || g, 'p1', case when g % 5 < 3 then 's1' else 'won' end, 'own-' || (g % 20), 'c-' || (6 * (1 + g % 16000)),
           case when g % 2 = 0 then 'GB' else 'NL' end, g % 5 >= 3, now() - make_interval(hours => g % 2000)
    from generate_series(1, 5000) g;
    insert into cma.crm_record (tenant_id, connection_id, source_system, record_type, source_id, pipeline_id, stage_id, contact_source_id, market,
                                is_closed, source_created_at)
    select v_t, v_crm, 'verifycrm', 'ticket', 't-' || g, 'tp1', case when g % 2 = 0 then 'new' else 'done' end, 'c-' || (6 * (1 + g % 16000)),
           case when g % 2 = 0 then 'GB' else 'NL' end, g % 2 = 1, now() - make_interval(hours => g % 900)
    from generate_series(1, 2000) g;
    insert into cma.connection_task_status (tenant_id, connection_id, status_ref, label, is_done) values
      (v_t, v_crm, 'NOT_STARTED', 'Not started', false), (v_t, v_crm, 'COMPLETED', 'Completed', true);
    insert into cma.crm_task (tenant_id, connection_id, source_system, source_id, owner_ref, status_ref, type_ref, due_at, deal_source_id, source_created_at)
    select v_t, v_crm, 'verifycrm', 'k-' || g, 'own-' || (g % 20), case when g % 5 < 3 then 'NOT_STARTED' else 'COMPLETED' end, 'CALL',
           now() + make_interval(hours => (g % 200) - 100), 'deal-' || (1 + g % 5000), now() - interval '5 days'
    from generate_series(1, 5000) g;
    insert into cma.review_channel (tenant_id, connection_id, source_id, name, market, is_counted) values (v_t, v_rev, 'chl', 'Channel', 'GB', true)
    returning id into v_chan;
    insert into cma.review (tenant_id, connection_id, review_channel_id, source_system, source_id, review_type, state, is_published, rating, submitted_at, link_level)
    select v_t, v_rev, v_chan, 'verifyreviews', 'rv-' || g, 'SERVICE_REVIEW', 'APPROVED', true, 1 + g % 5,
           timestamptz '2026-09-01 00:00 Europe/Amsterdam' + make_interval(mins => (g * 17) % (61 * 1440)), 'none'
    from generate_series(1, 5000) g;
    analyze cma.commerce_customer; analyze cma.crm_contact; analyze cma.crm_contact_ref; analyze cma.subscription; analyze cma.subscription_event;
    analyze cma.device; analyze cma.device_component; analyze cma.commerce_order; analyze cma.commerce_order_line; analyze cma.crm_record;
    analyze cma.crm_task; analyze cma.review;

    -- C1. every live overview (the document), as the application; flows over October
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('app.user_id', v_analyst::text, true);
    for o in select x.key, x.kind, x.sorts from cma.flash_overviews() x where x.key <> 'data_quality' order by x.sort_order loop
      v_ms := pg_temp.v0008zn_best_ms(format('select cma.flash_overview(%L, null, null, %L, %L)', o.key,
                                             case when o.kind = 'flow' then '2026-10-01' end, case when o.kind = 'flow' then '2026-10-31' end), 2);
      v_txt := v_txt || o.key || ' ' || v_ms || ' ms; ';
      if v_ms >= v_max_o then v_bad := v_bad || o.key || '; '; end if;
    end loop;
    v_ms := pg_temp.v0008zn_best_ms('select cma.flash_page(null, null, ''2026-10-01'', ''2026-10-31'')', 2);
    v_txt := v_txt || 'landing ' || v_ms || ' ms';
    if v_ms >= v_max_o then v_bad := v_bad || 'landing; '; end if;
    v_rows := v_rows || array['61', 'C1 every live overview but data quality, and the landing, under verify.max_overview_ms at volume',
      case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_txt || case when v_bad <> '' then ' | over: ' || v_bad else '' end];

    -- C2. every first page of a list (500 rows) by every whitelisted sort key, as the application, the best of two
    v_txt := ''; v_bad := '';
    for o in select x.key, x.kind, x.sorts from cma.flash_overviews() x where x.key <> 'data_quality' order by x.sort_order loop
      foreach s in array o.sorts loop
        v_ms := pg_temp.v0008zn_best_ms(format('select cma.flash_rows(%L, ''{}'', %L, true, 500, 0, null, %L, %L)', o.key, s,
                                               case when o.kind = 'flow' then '2026-10-01' end, case when o.kind = 'flow' then '2026-10-31' end), 2);
        v_worst := greatest(v_worst, v_ms);
        v_txt := v_txt || o.key || ':' || s || ' ' || v_ms || '; ';
        if v_ms >= v_max_r then v_bad := v_bad || o.key || ':' || s || '; '; end if;
        if v_ms >= v_brief_r then v_over := v_over || o.key || ':' || s || '; '; end if;
      end loop;
    end loop;
    v_rows := v_rows || array['62', 'C2 every first page of a list but data quality''s, by every sort key, under verify.max_rows_ms at volume',
      case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end,
      'worst ' || v_worst || ' ms | over the brief''s ' || v_brief_r || ' ms: ' || case when v_over = '' then 'none' else v_over end || ' | ' || v_txt
      || case when v_bad <> '' then ' | over: ' || v_bad else '' end];

    -- C4. the data-quality overview (the best of two) and every first page of its list (the best of one)
    v_txt := ''; v_bad := ''; v_over := '';
    v_ms := pg_temp.v0008zn_best_ms('select cma.flash_overview(''data_quality'')', 2);
    v_txt := 'overview ' || v_ms || ' ms; ';
    if v_ms >= v_max_q then v_bad := 'overview; '; end if;
    if v_ms >= v_max_o then v_over := 'overview; '; end if;
    foreach s in array (select x.sorts from cma.flash_overviews() x where x.key = 'data_quality') loop
      v_ms := pg_temp.v0008zn_best_ms(format('select cma.flash_rows(''data_quality'', ''{}'', %L, true, 500, 0)', s), 1);
      v_txt := v_txt || 'list:' || s || ' ' || v_ms || ' ms; ';
      if v_ms >= v_max_q then v_bad := v_bad || 'list:' || s || '; '; end if;
      if v_ms >= v_brief_r then v_over := v_over || 'list:' || s || '; '; end if;
    end loop;
    v_rows := v_rows || array['64', 'C4 the data-quality overview and its lists under verify.max_dq_ms at volume',
      case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end,
      'over the brief''s ' || v_max_o || ' and ' || v_brief_r || ' ms: ' || case when v_over = '' then 'none' else v_over end || ' | ' || v_txt
      || case when v_bad <> '' then ' | over: ' || v_bad else '' end];

    -- C3. a full take at a month end (every overview, the id lists), as the owner with the scheduler user
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.user_id', v_sched::text, true);
    v_t0 := clock_timestamp();
    j := cma.flash_snapshot_take_at(v_t, '2026-11-01 01:00:00 Europe/Amsterdam');
    v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
    v_rows := v_rows || array['63', 'C3 a full take under half the job''s statement timeout at volume',
      case when (j ->> 'taken')::boolean and v_ms < v_max_t and not v_provoke then 'ok' else 'FAIL' end,
      v_ms || ' ms against ' || v_max_t || ' ms; ids ' || coalesce(j ->> 'ids_customer', '-') || '/' || coalesce(j ->> 'ids_subscription', '-') || '/'
      || coalesce(j ->> 'ids_device', '-') || coalesce('; ' || (j ->> 'error'), '')];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['69', 'C the block ran to the end', 'FAIL', sqlstate || ' ' || sqlerrm];
  end;
  insert into verify_0008zn (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008zn values (69, 'C the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Block C analysed its volume inside its transaction; the rollback took the rows and the statistics' details, but a
-- table's row count is kept outside the transaction: after a run with the volume on, the tables are analysed again, so
-- their statistics are their own (nothing is analysed when block C did not run)
do $$
begin
  if current_setting('verify.volume')::boolean then
    analyze cma.commerce_customer, cma.crm_contact, cma.crm_contact_ref, cma.subscription, cma.subscription_event, cma.device,
            cma.device_component, cma.commerce_order, cma.commerce_order_line, cma.crm_record, cma.crm_task, cma.review;
  end if;
end
$$;

-- The helpers are dropped first, so the verdict is the last thing the script prints
drop function if exists pg_temp.v0008zn_code(text);
drop function if exists pg_temp.v0008zn_best_ms(text, integer);
drop function if exists pg_temp.v0008zn_figs(uuid, text, date, date, date);
drop function if exists pg_temp.v0008zn_stored(uuid, text, date[]);

-- Verdict: one row per check, then the verdict. 43 checks: with the volume off (dev, prod) block C's four read skip and
-- the 39 others must be ok; with the volume on (a local run) all 43
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008zn
      union all
      select 99, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from verify_0008zn where result not in ('ok', 'skip')) then 'FAIL'
                  when current_setting('verify.volume')::boolean and (select count(*) from verify_0008zn where result = 'ok') = 43 then '0008zn verified'
                  when not current_setting('verify.volume')::boolean and (select count(*) from verify_0008zn where result = 'ok') = 39
                       and (select count(*) from verify_0008zn where result = 'skip') = 4 then '0008zn verified'
                  else 'FAIL' end,
             format('123_verify_flash: %s ok, %s FAIL, %s skip', (select count(*) from verify_0008zn where result = 'ok'),
                    (select count(*) from verify_0008zn where result not in ('ok', 'skip')),
                    (select count(*) from verify_0008zn where result = 'skip'))) x
order by ord;
reset role;
