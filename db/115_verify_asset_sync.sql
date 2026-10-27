-- =============================================================================================
-- 115_verify_asset_sync.sql: verifies addition 0008zj, the asset register read through its API on a schedule
-- =============================================================================================
-- Universal: no seed is assumed. Block A checks structure and privileges; blocks B and C work on throwaway tenants
-- inside subtransactions that are always rolled back, so nothing stays (as 113) and the script runs in dev and in prod.
-- Adapters, models, statuses, devices, serials, customers, people and secret names are invented data values, and no
-- row carries a name of a customer, an address, an email or a phone number. Every check writes one row, ok or FAIL, and
-- the last row is the verdict (0008zj verified), because Cloud SQL Studio shows no notices. Run as your own IAM login
-- after 114_asset_sync.sql, dev first, then prod; then 113_verify_assets.sql again (the load it proves is the shared one).
--   A  structure and privileges: the addition row after 0008zi; the job assets_poll; the connection fields' checks and
--      their trigger; every function the application's only and in the caller's rights, the trigger functions nobody's;
--      the asset register's settings checked by form (pure)
--   B  behaviour, on two throwaway tenants, each with its own Ingest user (cma.create_tenant makes one) and an asset
--      register connection with a token secret name; tenant one also holds a connection without one (loaded from
--      files) and a CRM connection. Checked: the ingest load as the Ingest user (staged through the COPY target, the
--      counts, an address kept as a bare @, no run of its own, the staged rows deleted, the audit's actor); a batch of
--      changed records (is_full false) never marks a device missing; a full batch does, and a later full one brings
--      them back; the connection without a token secret name refused by the ingest load (CMA04) and still loaded from
--      files by a person, with its run assets_import; the permissions (CMA06) and the refusals (CMA04); row-level
--      security across the two tenants' Ingest users (CMA02, nothing seen); the poll's run with the load's counts;
--      the register's fields as connection fields and the kinds they imply; the settings
--   C  speed: a throwaway tenant with 5,000 devices; a nightly full snapshot of them all, unchanged, staged and loaded
--      as the Ingest user under verify.max_ms (the ingest's statement timeout is 15 seconds; the load's own guard 2
--      minutes)
-- Provoke: set provoke below to true; every check must then read FAIL, and the verdict says PROVOKED instead.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);   -- 'true' to make every check fail
select set_config('verify.max_ms', '10000', false);    -- a full snapshot of 5,000 unchanged records, staged and loaded

drop table if exists pg_temp.verify_0008zj;
create temp table verify_0008zj (ord int, check_name text, result text, detail text);

-- The error code a statement raises, or 'ok'
create or replace function pg_temp.v0008zj_code(p_sql text)
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

-- Stages a batch of the scenario's records for the current tenant and user, as the ingest stages what it read: the
-- record ids given, numbered in id order from 2, every value text, dates as YYYY-MM-DD, components and named ids as JSON
-- objects. rec-1b is rec-1 with another device serial; rec-3's customer reference holds an address
create or replace function pg_temp.v0008zj_stage(p_batch text, p_ids text[])
returns integer
language sql
as $$
  insert into cma.device_import_staging (batch_key, source_row, source_id, serial, model, status, country, customer_ref,
                                         subscription_ref, first_shipped_on, components, external_refs)
  select p_batch, (row_number() over (order by v.source_id) + 1)::integer, v.source_id, v.serial, v.model, v.status, v.country,
         v.customer_ref, v.subscription_ref, v.first_shipped_on, v.components, v.external_refs
  from (values
    ('rec-1', 'SN-1', 'HS1', 'Active/Customer', 'Netherlands', 'cu-1', 'sub-1', '2024-11-15',
        '{"pads": {"serial": "P-1", "expires_on": "2026-12-10"}}', '{"ns_internal_id": "9001"}', 'rec-1'),
    ('rec-1', 'SN-1b', 'HS1', 'Active/Customer', 'Netherlands', 'cu-1', 'sub-1', '2024-11-15',
        '{"pads": {"serial": "P-1", "expires_on": "2026-12-10"}}', '{"ns_internal_id": "9001"}', 'rec-1b'),
    ('rec-2', 'SN-2', 'HS1', 'In Storage', 'GB', null, null, null, null, null, 'rec-2'),
    ('rec-3', 'SN-3', 'HS1', 'Active/Customer', 'Netherlands', 'verify-customer@example.invalid', 'sub-3', '2025-01-10', null, null, 'rec-3'),
    ('rec-4', 'SN-4', 'HS1', 'Active/Customer', 'nl', 'cu-4', 'sub-4', '2025-02-01', null, null, 'rec-4'),
    ('rec-5', 'SN-5', 'HS1', 'In Storage', 'GB', null, null, null, null, null, 'rec-5')
  ) as v(source_id, serial, model, status, country, customer_ref, subscription_ref, first_shipped_on, components, external_refs, variant)
  where v.variant = any (p_ids);
  select count(*)::integer from cma.device_import_staging s where s.batch_key = p_batch
$$;

-- A counts object as one line, in a fixed order
create or replace function pg_temp.v0008zj_counts(j jsonb)
returns text
language sql
as $$
  select concat_ws(' ', 'rows=' || (j ->> 'rows'), 'ins=' || (j ->> 'inserted'), 'upd=' || (j ->> 'updated'), 'same=' || (j ->> 'unchanged'),
                   'missing=' || (j ->> 'missing_now'), 'repl=' || (j ->> 'components_replaced'), 'um=' || (j ->> 'unmapped_model'),
                   'us=' || (j ->> 'unmapped_status'), 'uk=' || (j ->> 'unmapped_market'), 'cri=' || (j ->> 'customer_ref_invalid'),
                   'drop=' || (j ->> 'refs_dropped'))
$$;

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_bad     text;
  v_fn      text;
begin
  -- A1. the addition is recorded, after 0008zi
  insert into verify_0008zj values (1, 'A1 addition 0008zj recorded, after 0008zi',
    case when exists (select 1 from cma.schema_migration where version = '0008zj')
              and exists (select 1 from cma.schema_migration where version = '0008zi') and not v_provoke then 'ok' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the job assets_poll beside the earlier ones; the connection fields' checks (device and device_component
  --     fields, a component's kind in ref_system, slot 1) and their trigger; the comment on ref_system
  v_bad := '';
  if (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.sync_run'::regclass and conname = 'sync_run_job_check')
     not like '%''legacy_call_import''%''assets_import''%''assets_poll''%' then
    v_bad := v_bad || 'job; ';
  end if;
  if (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.connection_field'::regclass and conname = 'connection_field_entity_field_check')
     not like '%''device''%''end_of_life_on''%''ref''%''device_component''%''serial''%''expires_on''%''reason''%'
     or (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.connection_field'::regclass and conname = 'connection_field_check')
        not like '%device_component%'
     or (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.connection_field'::regclass and conname = 'connection_field_slot_check')
        not like '%device_component%slot = 1%'
     or (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.connection_field'::regclass and conname = 'connection_field_field_check')
        not like '%''created_at''%''reason''%''serial''%''expires_on''%' then
    v_bad := v_bad || 'connection field checks; ';
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'cma.connection_field'::regclass and tgname = 'check_kind' and not tgisinternal)
     or not exists (select 1 from pg_trigger where tgrelid = 'cma.device_import_staging'::regclass and tgname = 'stage_row' and not tgisinternal) then
    v_bad := v_bad || 'triggers; ';
  end if;
  insert into verify_0008zj values (2, 'A2 the job assets_poll; the connection fields'' checks and their trigger; the staging trigger',
    case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_bad);

  -- A3. every function the application's only and in the caller's rights; the trigger functions nobody's
  v_bad := '';
  foreach v_fn in array array[
    'cma.ingest_sync_run_finish(uuid,text,jsonb,text)', 'cma.connection_held_kinds_of(uuid,uuid)', 'cma.assets_settings_problem(jsonb)',
    'cma.set_connection_settings(uuid,jsonb)', 'cma.device_snapshot_apply(text,uuid,boolean)', 'cma.load_device_snapshot(text,uuid,boolean)',
    'cma.ingest_load_device_snapshot(uuid,text,boolean)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure(v_fn) and a.grantee = 0) then
      v_bad := v_bad || v_fn || '; ';
    end if;
  end loop;
  foreach v_fn in array array['cma.check_connection_field_kind()', 'cma.device_import_staging_insert()'] loop
    if to_regprocedure(v_fn) is null
       or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure(v_fn) and a.grantee = 0)
       or has_function_privilege('cma_readonly', v_fn, 'execute') or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      v_bad := v_bad || v_fn || '; ';
    end if;
  end loop;
  -- the shared load is the only place the load lives: the person's and the ingest's call it, neither writes a device
  if pg_get_functiondef('cma.load_device_snapshot(text,uuid,boolean)'::regprocedure) not like '%cma.device_snapshot_apply(%'
     or pg_get_functiondef('cma.ingest_load_device_snapshot(uuid,text,boolean)'::regprocedure) not like '%cma.device_snapshot_apply(%'
     or pg_get_functiondef('cma.load_device_snapshot(text,uuid,boolean)'::regprocedure) like '%cma.device %'
     or pg_get_functiondef('cma.ingest_load_device_snapshot(uuid,text,boolean)'::regprocedure) like '%cma.device %'
     or pg_get_functiondef('cma.device_snapshot_apply(text,uuid,boolean)'::regprocedure) not like '%pg_advisory_xact_lock%'
     or pg_get_functiondef('cma.device_snapshot_apply(text,uuid,boolean)'::regprocedure) like '%sync_run%' then
    v_bad := v_bad || 'the shared load; ';
  end if;
  insert into verify_0008zj values (3, 'A3 every function the application''s only and invoker, the trigger functions nobody''s; one shared load',
    case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_bad);

  -- A4. the asset register's settings by form: each key's first fault named, the rest accepted
  v_bad := concat_ws(' ',
    coalesce(cma.assets_settings_problem('{}'), 'ok'),
    coalesce(cma.assets_settings_problem('{"table_id": "tblAbc123", "view_id": "viwAbc123", "date_format": "dmy", "assets_poll_interval_minutes": 15}'), 'ok'),
    coalesce(cma.assets_settings_problem('{"assets_poll_interval_minutes": "1440", "date_format": "iso"}'), 'ok'),
    coalesce(cma.assets_settings_problem('{"table_id": "tbl abc"}'), 'ok'),
    coalesce(cma.assets_settings_problem('{"table_id": 12}'), 'ok'),
    coalesce(cma.assets_settings_problem('{"view_id": ""}'), 'ok'),
    coalesce(cma.assets_settings_problem('{"date_format": "ymd"}'), 'ok'),
    coalesce(cma.assets_settings_problem('{"assets_poll_interval_minutes": 0}'), 'ok'),
    coalesce(cma.assets_settings_problem('{"assets_poll_interval_minutes": 1441}'), 'ok'),
    coalesce(cma.assets_settings_problem('{"assets_poll_interval_minutes": "15m"}'), 'ok'),
    coalesce(cma.assets_settings_problem('{"assets_poll_interval_minutes": 7.5}'), 'ok'),
    coalesce(cma.assets_settings_problem('{"airtable_max_per_second": 9}'), 'ok'));
  insert into verify_0008zj values (4, 'A4 the asset register''s settings by form: ids, the date format, the poll interval from 1 to 1440',
    case when v_bad = 'ok ok ok table_id table_id view_id date_format assets_poll_interval_minutes assets_poll_interval_minutes '
                      || 'assets_poll_interval_minutes assets_poll_interval_minutes ok'
              and not v_provoke then 'ok' else 'FAIL' end, v_bad);
end
$$;

-- B. Behaviour on two throwaway tenants (rolled back)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  v_t1 uuid; v_t2 uuid;
  v_admin1 uuid; v_agent1 uuid; v_ing1 uuid; v_ing2 uuid;
  v_reg uuid; v_csv uuid; v_crm uuid; v_reg2 uuid;
  v_run uuid;
  v_txt text;
  v_n integer;
  j jsonb;
begin
  begin
    -- tenants (each with its Ingest user), people and connections (as the owner)
    v_t1 := cma.create_tenant('verify-0008zj-one', 'Verify 0008zj one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008zj-two', 'Verify 0008zj two', 'Europe/Amsterdam');
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest' and x.external_id = 'ingest';
    select x.user_id into v_ing2 from cma.app_user_external_id x where x.tenant_id = v_t2 and x.system = 'ingest' and x.external_id = 'ingest';
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent1@example.invalid', 'agent1') returning id into v_agent1;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_admin1, 'admin'), (v_agent1, 'agent')) as x(uid, role_key)
    join cma.app_role ar on ar.tenant_id = v_t1 and ar.key = x.role_key;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t1, 'verifyregister', 'Verify register', 'base-1', 'assets', 'verify-register-token-1') returning id into v_reg;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifyregister', 'Verify register from files', 'base-csv', 'assets') returning id into v_csv;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t1, 'verifycrm', 'Verify CRM', 'portal-1', 'crm', 'verify-crm-token-1') returning id into v_crm;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t2, 'verifyregister', 'Verify register two', 'base-2', 'assets', 'verify-register-token-2') returning id into v_reg2;
    perform set_config('role', 'cma_app', true);

    -- tenant one's catalogs (its admin): the market NL with its alias, a model, a kind, two statuses
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR', null, null, 20);
    perform cma.set_market_alias('netherlands', 'NL');
    insert into cma.device_model (key, name, aliases) values ('hs1', 'HS1', array['hs1']);
    insert into cma.device_component_kind (key, name, sort_order) values ('pads', 'Pads', 10);
    insert into cma.device_status (key, name, is_in_field, is_in_stock, is_tracked, aliases, sort_order) values
      ('active_customer', 'Active/Customer', true, false, true, array['active/customer'], 10),
      ('in_storage', 'In Storage', false, true, true, array['in storage'], 20);

    -- B1. the ingest load as tenant one's Ingest user: four records staged through the COPY target (an address as a
    --     bare @) and loaded as a full snapshot; the counts; no run of its own; the staged rows deleted; the devices'
    --     audit rows name the Ingest user; the address stored nowhere
    perform set_config('app.user_id', v_ing1::text, true);
    v_n := pg_temp.v0008zj_stage('ingest-b1', array['rec-1', 'rec-2', 'rec-3', 'rec-4']);
    v_txt := v_n || ' ' || (select s.customer_ref from cma.device_import_staging s where s.batch_key = 'ingest-b1' and s.source_id = 'rec-3');
    j := cma.ingest_load_device_snapshot(v_reg, 'ingest-b1', true);
    v_txt := v_txt || ' ' || pg_temp.v0008zj_counts(j);
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || ' | ' || (select count(*) from cma.sync_run r where r.tenant_id = v_t1)
             || ' ' || (select count(*) from cma.device_import_row s where s.tenant_id = v_t1)
             || ' ' || (select string_agg(d.source_id || ':' || coalesce(d.customer_ref, '-') || ':' || d.customer_ref_invalid::text, ' ' order by d.source_id)
                        from cma.device d where d.tenant_id = v_t1)
             || ' ' || (select string_agg(distinct a.actor_user_id::text, ',') = v_ing1::text from cma.audit_log a
                        where a.tenant_id = v_t1 and a.table_name = 'device')
             || ' ' || (select count(*) from cma.device d where d.tenant_id = v_t1 and (d.raw::text like '%@%' or d.raw::text like '%example.invalid%'))
             || ' ' || (select count(*) from cma.audit_log a where a.tenant_id = v_t1 and a.table_name in ('device', 'device_import_row')
                          and (coalesce(a.new_row::text, '') || coalesce(a.old_row::text, '')) like '%example.invalid%');
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['11', 'B1 the ingest load as the Ingest user: counts, an address a bare @, no run of its own, the staged rows gone',
      case when v_txt = '4 @ rows=4 ins=4 upd=0 same=0 missing=0 repl=0 um=0 us=0 uk=1 cri=1 drop=0 | 0 0 '
                        || 'rec-1:cu-1:false rec-2:-:false rec-3:-:true rec-4:cu-4:false true 0 0'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B2. a batch of changed records (is_full false: the poll): rec-1 under another serial and the new rec-5; nothing
    --     marked missing, though rec-2 to rec-4 are not in it
    v_n := pg_temp.v0008zj_stage('ingest-b2', array['rec-1b', 'rec-5']);
    j := cma.ingest_load_device_snapshot(v_reg, 'ingest-b2', false);
    v_txt := pg_temp.v0008zj_counts(j) || ' | '
             || (select count(*) filter (where d.source_deleted_at is not null) || '/' || count(*) from cma.device d where d.connection_id = v_reg)
             || ' ' || (select d.serial from cma.device d where d.connection_id = v_reg and d.source_id = 'rec-1');
    v_rows := v_rows || array['12', 'B2 a batch of changed records (is_full false) never marks a device missing',
      case when v_txt = 'rows=2 ins=1 upd=1 same=0 missing=0 repl=0 um=0 us=0 uk=1 cri=0 drop=0 | 0/5 SN-1b' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B3. a full batch of rec-1 and rec-2 marks rec-3 to rec-5 missing; a full batch of all five brings them back
    v_n := pg_temp.v0008zj_stage('ingest-b3', array['rec-1b', 'rec-2']);
    j := cma.ingest_load_device_snapshot(v_reg, 'ingest-b3', true);
    v_txt := pg_temp.v0008zj_counts(j) || ' | '
             || (select string_agg(d.source_id, ',' order by d.source_id) from cma.device d where d.connection_id = v_reg and d.source_deleted_at is not null);
    v_n := pg_temp.v0008zj_stage('ingest-b3b', array['rec-1b', 'rec-2', 'rec-3', 'rec-4', 'rec-5']);
    j := cma.ingest_load_device_snapshot(v_reg, 'ingest-b3b', true);
    v_txt := v_txt || ' | ' || pg_temp.v0008zj_counts(j) || ' | '
             || (select count(*) from cma.device d where d.connection_id = v_reg and d.source_deleted_at is not null);
    v_rows := v_rows || array['13', 'B3 a full batch marks the devices it does not hold missing; a later full one brings them back',
      case when v_txt = 'rows=2 ins=0 upd=0 same=2 missing=3 repl=0 um=0 us=0 uk=1 cri=0 drop=0 | rec-3,rec-4,rec-5 | '
                        || 'rows=5 ins=0 upd=3 same=2 missing=0 repl=0 um=0 us=0 uk=2 cri=1 drop=0 | 0'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B4. the connection without a token secret name: the Ingest user's load refused (CMA04), the batch left staged;
    --     a person loads the same batch from files (its run assets_import), so the connection stays valid
    v_n := pg_temp.v0008zj_stage('files-b4', array['rec-1', 'rec-2']);
    v_txt := pg_temp.v0008zj_code(format('select cma.ingest_load_device_snapshot(%L, %L, true)', v_csv, 'files-b4'))
             || ' ' || (select count(*) from cma.device_import_staging s where s.batch_key = 'files-b4');
    perform set_config('app.user_id', v_admin1::text, true);
    j := cma.load_device_snapshot('files-b4', v_csv, true);
    v_txt := v_txt || ' ' || pg_temp.v0008zj_counts(j) || ' '
             || (select string_agg(r.job || '/' || r.stream || '/' || r.status, ',') from cma.sync_run r where r.connection_id = v_csv)
             || ' ' || (select count(*) from cma.sync_run r where r.connection_id = v_reg);
    v_rows := v_rows || array['14', 'B4 a connection without a token secret name: the ingest load refused, a person''s load from files works',
      case when v_txt = 'CMA04 2 rows=2 ins=2 upd=0 same=0 missing=0 repl=0 um=0 us=0 uk=1 cri=0 drop=0 assets_import/files-b4/succeeded 0'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B5. the permissions and the refusals: the Ingest user may not load as a person (CMA06), a person may not load as
    --     the ingest (CMA06), an agent may not stage (CMA06); the ingest load refuses an is_full of null, a batch with
    --     no rows (CMA02) and a CRM connection (CMA04)
    v_n := pg_temp.v0008zj_stage('ingest-b5', array['rec-1']);
    v_txt := pg_temp.v0008zj_code(format('select cma.ingest_load_device_snapshot(%L, %L, true)', v_reg, 'ingest-b5'));
    perform set_config('app.user_id', v_ing1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008zj_code(format('select cma.load_device_snapshot(%L, %L, true)', 'ingest-b5', v_reg))
             || ' ' || pg_temp.v0008zj_code(format('select cma.ingest_load_device_snapshot(%L, %L, null)', v_reg, 'ingest-b5'))
             || ' ' || pg_temp.v0008zj_code(format('select cma.ingest_load_device_snapshot(%L, %L, true)', v_reg, 'ingest-none'))
             || ' ' || pg_temp.v0008zj_code(format('select cma.ingest_load_device_snapshot(%L, %L, true)', v_crm, 'ingest-b5'));
    perform set_config('app.user_id', v_agent1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008zj_code('select pg_temp.v0008zj_stage(''agent-b5'', array[''rec-1''])');
    perform set_config('app.user_id', v_ing1::text, true);
    delete from cma.device_import_row s where s.batch_key = 'ingest-b5';
    v_rows := v_rows || array['15', 'B5 permissions: person and ingest each their own load, no agent stages; is_full, no rows, a CRM connection refused',
      case when v_txt = 'CMA06 CMA06 CMA04 CMA02 CMA04 CMA06' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B6. row-level security: tenant two's Ingest user loads its own connection, never tenant one's (CMA02), and sees
    --     none of tenant one's devices or staged rows; tenant one's Ingest user sees none of tenant two's
    v_n := pg_temp.v0008zj_stage('ingest-b6-one', array['rec-4']);
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_ing2::text, true);
    v_n := pg_temp.v0008zj_stage('ingest-b6', array['rec-2']);
    j := cma.ingest_load_device_snapshot(v_reg2, 'ingest-b6', true);
    v_n := pg_temp.v0008zj_stage('ingest-b6b', array['rec-2']);
    v_txt := pg_temp.v0008zj_counts(j)
             || ' ' || pg_temp.v0008zj_code(format('select cma.ingest_load_device_snapshot(%L, %L, true)', v_reg, 'ingest-b6b'))
             || ' ' || (select count(*) from cma.device) || ' ' || (select count(*) from cma.device_import_staging);
    delete from cma.device_import_row s where s.batch_key = 'ingest-b6b';
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_ing1::text, true);
    v_txt := v_txt || ' ' || (select count(*) from cma.device where connection_id = v_reg2) || ' ' || (select count(*) from cma.device)
             || ' ' || (select string_agg(distinct s.batch_key, ',') from cma.device_import_staging s);
    delete from cma.device_import_row s where s.batch_key = 'ingest-b6-one';
    v_rows := v_rows || array['16', 'B6 row-level security: each Ingest user loads and sees its own tenant only',
      case when v_txt = 'rows=1 ins=1 upd=0 same=0 missing=0 repl=0 um=1 us=1 uk=1 cri=0 drop=0 CMA02 1 1 0 7 ingest-b6-one' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B7. the poll's run: job assets_poll, stream devices, finished with the load's counts and fetched; a key outside
    --     the list is still refused (CMA04)
    v_run := cma.ingest_sync_run_start(v_reg, 'assets_poll', 'devices', null, null);
    v_txt := pg_temp.v0008zj_code(format('select cma.ingest_sync_run_finish(%L, ''succeeded'', %L)', v_run,
               '{"fetched": 2, "upserted": 0, "stale": 0, "skipped": 0, "failed": 0, "rows": 2, "inserted": 1, "updated": 1, "unchanged": 0, '
               || '"missing_now": 0, "components_replaced": 0, "unmapped_model": 0, "unmapped_status": 0, "unmapped_market": 0, '
               || '"customer_ref_invalid": 0, "refs_dropped": 0}'));
    v_txt := v_txt || ' ' || (select r.job || '/' || r.stream || '/' || r.status || '/' || (r.counts ->> 'fetched') || '/' || (r.counts ->> 'inserted')
                              from cma.sync_run r where r.id = v_run)
             || ' ' || pg_temp.v0008zj_code(format('select cma.ingest_sync_run_finish(cma.ingest_sync_run_start(%L, ''assets_poll'', ''devices'', null, null), '
                                                   || '''succeeded'', ''{"fetched": 1, "mapped": 1}'')', v_reg));
    v_rows := v_rows || array['17', 'B7 the poll''s run: job assets_poll with the load''s counts and fetched; another key refused',
      case when v_txt = 'ok assets_poll/devices/succeeded/2/1 CMA04' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B8. the register's fields as connection fields (the admin): a device field, a component's serial and expiry under
    --     a kind of the catalog, a named id; a kind outside the catalog, a second slot, a device field on the CRM
    --     connection and a CRM field on the register refused (CMA04); a connection holding only device fields implies
    --     assets; the Ingest user reads them in the connection's configuration
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_connection_field(v_reg, 'device', 'serial', '', 'aed_sn');
    perform cma.set_connection_field(v_reg, 'device_component', 'serial', 'pads', 'pads_sn');
    perform cma.set_connection_field(v_reg, 'device_component', 'expires_on', 'pads', 'pads_expiry');
    perform cma.set_connection_field(v_reg, 'device', 'ref', 'ns_internal_id', 'ns_internal_id');
    v_txt := pg_temp.v0008zj_code(format('select cma.set_connection_field(%L, ''device_component'', ''serial'', ''battery'', ''battery_sn'')', v_reg))
             || ' ' || pg_temp.v0008zj_code(format('select cma.set_connection_field(%L, ''device'', ''ref'', ''ns_fam_id'', ''ns_fam_id'', 2::smallint)', v_reg))
             || ' ' || pg_temp.v0008zj_code(format('select cma.set_connection_field(%L, ''device'', ''serial'', '''', ''aed_sn'')', v_crm))
             || ' ' || pg_temp.v0008zj_code(format('select cma.set_connection_field(%L, ''contact'', ''country'', '''', ''country'')', v_reg))
             || ' ' || pg_temp.v0008zj_code(format('select cma.set_connection_field(%L, ''device'', ''reason'', '''', ''x'')', v_reg))
             || ' ' || pg_temp.v0008zj_code(format('select cma.set_connection_field(%L, ''device_component'', ''serial'', '''', ''x'')', v_reg));
    perform set_config('role', 'cma_owner', true);
    update cma.integration_connection c set kind = null where c.id = v_csv;
    delete from cma.sync_run r where r.connection_id = v_csv;
    perform set_config('role', 'cma_app', true);
    v_txt := v_txt || ' ' || array_to_string(cma.connection_held_kinds_of(v_t1, v_reg), ',')
             || ' ' || coalesce(nullif(array_to_string(cma.connection_held_kinds_of(v_t1, v_crm), ','), ''), '-');
    perform set_config('app.user_id', v_ing1::text, true);
    v_txt := v_txt || ' ' || (select string_agg(f ->> 'entity' || ':' || (f ->> 'field') || ':' || coalesce(f ->> 'refSystem', '-') || ':' || (f ->> 'property'), ' '
                                                order by f ->> 'entity', f ->> 'field', f ->> 'refSystem')
                              from jsonb_array_elements(cma.connection_config(v_reg) -> 'fields') f);
    v_rows := v_rows || array['18', 'B8 the register''s fields: device, component by kind, named id; the refusals; the kind they imply',
      case when v_txt = 'CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 assets - '
                        || 'device:ref:ns_internal_id:ns_internal_id device:serial:-:aed_sn device_component:expires_on:pads:pads_expiry '
                        || 'device_component:serial:pads:pads_sn'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B9. the settings (the admin): the register's own checked by form, a CRM connection's not; a connection without a
    --     kind that holds devices checked as a register
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := pg_temp.v0008zj_code(format('select cma.set_connection_settings(%L, %L)', v_reg,
               '{"table_id": "tblVerify0001", "date_format": "dmy", "assets_poll_interval_minutes": "15", "airtable_max_per_second": 2}'))
             || ' ' || pg_temp.v0008zj_code(format('select cma.set_connection_settings(%L, %L)', v_reg, '{"table_id": "tbl verify"}'))
             || ' ' || pg_temp.v0008zj_code(format('select cma.set_connection_settings(%L, %L)', v_reg, '{"date_format": "ymd"}'))
             || ' ' || pg_temp.v0008zj_code(format('select cma.set_connection_settings(%L, %L)', v_reg, '{"assets_poll_interval_minutes": 0}'))
             || ' ' || pg_temp.v0008zj_code(format('select cma.set_connection_settings(%L, %L)', v_crm, '{"date_format": "ymd"}'))
             || ' ' || pg_temp.v0008zj_code(format('select cma.set_connection_settings(%L, %L)', v_csv, '{"date_format": "ymd"}'));
    -- the settings read in a statement of their own (the one that wrote them sees the row as it was before)
    v_txt := v_txt || ' ' || coalesce((select c.settings ->> 'table_id' from cma.integration_connection c where c.id = v_reg), '-');
    v_rows := v_rows || array['19', 'B9 the register''s settings checked by form; a CRM connection''s not',
      case when v_txt = 'ok CMA04 CMA04 CMA04 ok CMA04 tblVerify0001' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['59', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008zj (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008zj values (59, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- C. Speed: a nightly full snapshot of 5,000 unchanged records as the Ingest user (rolled back)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_max     numeric := current_setting('verify.max_ms')::numeric;
  v_rows    text[] := '{}';
  v_t uuid; v_admin uuid; v_ing uuid; v_reg uuid;
  v_t0 timestamptz;
  v_ms numeric;
  j jsonb;
begin
  begin
    v_t := cma.create_tenant('verify-0008zj-volume', 'Verify 0008zj volume', 'Europe/Amsterdam');
    select x.user_id into v_ing from cma.app_user_external_id x where x.tenant_id = v_t and x.system = 'ingest' and x.external_id = 'ingest';
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-admin-volume@example.invalid', 'admin') returning id into v_admin;
    insert into cma.user_role (tenant_id, user_id, role_id) select v_t, v_admin, ar.id from cma.app_role ar where ar.tenant_id = v_t and ar.key = 'admin';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t, 'verifyregister', 'Verify register volume', 'base-v', 'assets', 'verify-register-token-v') returning id into v_reg;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR', null, null, 20);
    perform cma.set_market_alias('netherlands', 'NL');
    insert into cma.device_model (key, name, aliases) values ('hs1', 'HS1', array['hs1']);
    insert into cma.device_component_kind (key, name, sort_order) values ('pads', 'Pads', 10), ('battery', 'Battery', 20);
    insert into cma.device_status (key, name, is_in_field, is_in_stock, is_tracked, aliases) values
      ('active_customer', 'Active/Customer', true, false, true, array['active/customer']);
    perform set_config('app.user_id', v_ing::text, true);
    -- the register as the mirror holds it after earlier nights: loaded in parts of 500, the tables' statistics read
    -- after each (as autovacuum keeps them in a database that holds the devices)
    for p in 0 .. 9 loop
      insert into cma.device_import_staging (batch_key, source_row, source_id, serial, model, status, country, customer_ref, subscription_ref,
                                             first_shipped_on, components, external_refs)
      select 'volume-' || p, g - p * 500 + 1, 'rec-' || g, 'SN-' || g, 'HS1', 'Active/Customer', 'Netherlands', 'cu-' || g, 'sub-' || g, '2024-11-15',
             '{"pads": {"serial": "P-' || g || '", "expires_on": "2026-12-10"}, "battery": {"serial": "B-' || g || '", "expires_on": "2027-01-20"}}',
             '{"ns_internal_id": "' || g || '"}'
      from generate_series(p * 500 + 1, p * 500 + 500) g;
      perform cma.ingest_load_device_snapshot(v_reg, 'volume-' || p, false);
      perform set_config('role', 'cma_owner', true);
      analyze cma.device;
      analyze cma.device_component;
      analyze cma.device_import_row;
      perform set_config('role', 'cma_app', true);
    end loop;
    -- the night: every record again, unchanged, staged and loaded as one full snapshot
    v_t0 := clock_timestamp();
    insert into cma.device_import_staging (batch_key, source_row, source_id, serial, model, status, country, customer_ref, subscription_ref,
                                           first_shipped_on, components, external_refs)
    select 'volume-night', g + 1, 'rec-' || g, 'SN-' || g, 'HS1', 'Active/Customer', 'Netherlands', 'cu-' || g, 'sub-' || g, '2024-11-15',
           '{"pads": {"serial": "P-' || g || '", "expires_on": "2026-12-10"}, "battery": {"serial": "B-' || g || '", "expires_on": "2027-01-20"}}',
           '{"ns_internal_id": "' || g || '"}'
    from generate_series(1, 5000) g;
    j := cma.ingest_load_device_snapshot(v_reg, 'volume-night', true);
    v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
    v_rows := v_rows || array['41', 'C1 a nightly full snapshot of 5,000 unchanged records, staged and loaded as the Ingest user, under verify.max_ms',
      case when v_ms < v_max and pg_temp.v0008zj_counts(j) = 'rows=5000 ins=0 upd=0 same=5000 missing=0 repl=0 um=0 us=0 uk=0 cri=0 drop=0'
                and not v_provoke then 'ok' else 'FAIL' end, v_ms || ' ms, ' || pg_temp.v0008zj_counts(j)];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['79', 'C the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008zj (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008zj values (79, 'C the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- The helpers are dropped first, so the verdict is the last thing the script prints
drop function if exists pg_temp.v0008zj_code(text);
drop function if exists pg_temp.v0008zj_stage(text, text[]);
drop function if exists pg_temp.v0008zj_counts(jsonb);

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008zj
      union all
      select 99, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008zj where result = 'ok') = 14
                       and not exists (select 1 from verify_0008zj where result <> 'ok') then '0008zj verified'
                  else 'FAIL' end,
             format('115_verify_asset_sync: %s ok, %s FAIL', (select count(*) from verify_0008zj where result = 'ok'),
                                                            (select count(*) from verify_0008zj where result <> 'ok'))) x
order by ord;
reset role;
