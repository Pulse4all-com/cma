-- =============================================================================================
-- 113_verify_assets.sql: verifies addition 0008zi, the asset register's devices and Reports, Maintenance
-- =============================================================================================
-- Universal: no seed is assumed. Block A checks structure and privileges; blocks B and C work on throwaway tenants
-- inside subtransactions that are always rolled back, so nothing stays (as 111) and the script runs in dev and in prod.
-- Adapters, models, statuses, devices, serials, customers and people are invented data values, and no row carries a
-- name of a customer, an address, an email or a phone number; the forecast is read as of a fixed date, so the verdict
-- does not depend on the day it runs. Every check writes one row, ok or FAIL, and the last row is the verdict (0008zi
-- verified), because Cloud SQL Studio shows no notices. Run as your own IAM login after 112_assets.sql, dev first, then
-- prod; in dev then 105, 75, 41 and 107 again.
--   A  structure and privileges: the addition row after 0008zh; the tables' columns; keys and checks (the raw's key
--      allow-list and no @, the named ids, the customer reference, one current component per kind, the reserved kind
--      device, the status flags); the connection kind assets, the job assets_import, the setting; row-level security with
--      the tenant policy, the audit trigger, no delete for the application (but on staged rows), nothing for the readers
--      on the tables; every function the application's only and in the caller's rights, the readers' function definer,
--      the owner's, pinned, theirs only; the reporting views' exact columns with no raw and no name of a person, email,
--      phone or address; the data-quality catalog; the redefinitions carry what came before (the audit image too)
--   B  behaviour, on two throwaway tenants (Europe/Amsterdam), as of Tuesday 27 October 2026 for the forecast. Tenant
--      one holds the catalogs (models hs1 and frx, kinds pads and battery, four rules with 60 lead days, four statuses), a
--      bundling window of 90 days, markets NL and GB with their aliases, a CRM connection, a store whose customer cu-1 is
--      linked to contact c-1 (0008h), and an asset register connection loaded from seven staged records. Tenant two holds
--      people and a connection of its own. Checked: the loads' counts (insert, an unchanged rerun, a serial change as a
--      replacement, a record missing from a full snapshot, a partial snapshot), the refusals, the mapping, the raw, the
--      kind, the run and the staged rows, the due basis (recorded, rule, unknown), bundling (pads and battery within the
--      window one exchange, outside it two), past due, the window setting, the page and its filters, the device list and
--      its buckets, the parameters and the permission refusal (CMA06), data quality, the reader views, tenant isolation,
--      a staged address kept as a bare @ and the audit images of staged rows holding their keys only, and a replacement
--      restarting the rule (a new serial without an expiry due from the day it was first seen)
--   C  speed: a throwaway tenant with 5,000 devices and 10,000 components; the page of 24 months and the device list of
--      all buckets as the application (row-level security on) under verify.max_ms, the best of three
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
select set_config('verify.max_ms', '1000', false);     -- the page of 24 months and the device list, as the application

drop table if exists pg_temp.verify_0008zi;
create temp table verify_0008zi (ord int, check_name text, result text, detail text);

-- The error code a statement raises, or 'ok'
create or replace function pg_temp.v0008zi_code(p_sql text)
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

-- The fastest of p_runs runs of a read, in milliseconds, every row fetched (as 91)
create or replace function pg_temp.v0008zi_best_ms(p_sql text, p_runs integer)
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

-- Stages a batch of the scenario's records for the current tenant (as the application): variant 1 the seven records;
-- 3 the same with rec-1's battery replaced (another serial and expiry) and rec-7 left out; 4 rec-7 alone. Columns as
-- the import tool writes them: text, dates as YYYY-MM-DD, components and named ids as JSON objects
create or replace function pg_temp.v0008zi_stage(p_batch text, p_variant integer)
returns integer
language sql
as $$
  insert into cma.device_import_staging (batch_key, source_row, source_id, serial, model, status, country, warehouse_ref, customer_ref,
                                         subscription_ref, order_ref, first_shipped_on, stock_received_on, last_shipped_on, warranty_until,
                                         end_of_life_on, components, external_refs)
  select p_batch, v.source_row, v.source_id, v.serial, v.model, v.status, v.country, v.warehouse_ref, v.customer_ref, v.subscription_ref,
         v.order_ref, v.first_shipped_on, v.stock_received_on, v.last_shipped_on, v.warranty_until, v.end_of_life_on,
         case when p_variant = 3 and v.source_id = 'rec-1'
              then '{"pads": {"serial": "P-1", "expires_on": "2026-12-10"}, "battery": {"serial": "B-1b", "expires_on": "2027-01-30"}}'
              else v.components end,
         v.external_refs
  from (values
    (2, 'rec-1', 'SN-1', 'HS1', 'Active/Customer', 'Netherlands', 'WH-A', 'cu-1', 'sub-1', '#NL1001', '2024-11-15', '2024-11-01', null,
        '2029-11-15', null, '{"pads": {"serial": "P-1", "expires_on": "2026-12-10"}, "battery": {"serial": "B-1", "expires_on": "2027-01-20"}}',
        '{"ns_internal_id": "9001"}'),
    (3, 'rec-2', 'SN-2', 'heartstart hs1', 'Active/Customer', 'United Kingdom', null, 'not an id!', null, null, '2024-03-01', null, '2025-02-10',
        null, null, null, null),
    (4, 'rec-3', 'SN-3', 'FRx', 'In Storage', 'Netherlands', 'WH-B', null, null, null, '2023-01-10', '2022-12-01', null, null, '2026-08-15',
        '{"pads": {"serial": "P-3", "expires_on": "2026-08-01"}}', null),
    (5, 'rec-4', 'SN-1', 'Model X', 'Internal Usage', 'Spain', null, null, null, null, null, null, null, null, null, null, null),
    (6, 'rec-5', '', 'HS1', 'Stolen/Missing', 'GB', null, 'cu-9', 'sub-5', null, '2024-05-05', null, null, null, null, null, null),
    (7, 'rec-6', 'SN-6', 'HS1', 'Unknown status', 'Netherlands', null, null, null, null, '2024-06-06', null, null, null, null, null, null),
    (8, 'rec-7', 'bad@serial', 'HS1', 'In Storage', 'nl', null, null, null, null, null, null, null, null, null, null,
        '{"ns_internal_id": "12345", "Bad key": "x", "ns_fam_id": "a b"}')
  ) as v(source_row, source_id, serial, model, status, country, warehouse_ref, customer_ref, subscription_ref, order_ref, first_shipped_on,
         stock_received_on, last_shipped_on, warranty_until, end_of_life_on, components, external_refs)
  where p_variant = 1 or (p_variant = 3 and v.source_id <> 'rec-7') or (p_variant = 4 and v.source_id = 'rec-7');
  select count(*)::integer from cma.device_import_staging s where s.batch_key = p_batch
$$;

-- A counts object as one line, in a fixed order
create or replace function pg_temp.v0008zi_counts(j jsonb)
returns text
language sql
as $$
  select concat_ws(' ', 'rows=' || (j ->> 'rows'), 'ins=' || (j ->> 'inserted'), 'upd=' || (j ->> 'updated'), 'same=' || (j ->> 'unchanged'),
                   'missing=' || (j ->> 'missing_now'), 'repl=' || (j ->> 'components_replaced'), 'um=' || (j ->> 'unmapped_model'),
                   'us=' || (j ->> 'unmapped_status'), 'uk=' || (j ->> 'unmapped_market'), 'cri=' || (j ->> 'customer_ref_invalid'),
                   'drop=' || (j ->> 'refs_dropped'))
$$;

-- A page's cells as one line: bucket/market/model/components/end of life/exchanges, a month's bucket as YYYY-MM
create or replace function pg_temp.v0008zi_cells(j jsonb)
returns text
language sql
as $$
  select coalesce(string_agg(case when c ->> 'bucket' ~ '^[0-9]' then left(c ->> 'bucket', 7) else c ->> 'bucket' end || '/' || (c ->> 'market') || '/' || (c ->> 'model') || '/'
                             || coalesce((select string_agg(k || ':' || (c -> 'components' ->> k), '+' order by k)
                                          from jsonb_object_keys(c -> 'components') k), '-')
                             || '/' || (c ->> 'end_of_life') || '/' || (c ->> 'exchanges'), ' ' order by o), '-')
  from jsonb_array_elements(j -> 'cells') with ordinality as x(c, o)
$$;

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_bad     text;
  v_fn      text;
  v_t       text;
begin
  -- A1. the addition is recorded, after 0008zh
  insert into verify_0008zi values (1, 'A1 addition 0008zi recorded, after 0008zh',
    case when exists (select 1 from cma.schema_migration where version = '0008zi')
              and exists (select 1 from cma.schema_migration where version = '0008zh') and not v_provoke then 'ok' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the tables: columns with types and nullability
  v_bad := '';
  foreach v_t in array array[
    'device_model=id:uuid:NO,tenant_id:uuid:NO,key:text:NO,name:text:NO,brand:text:YES,aliases:_text:NO,status:text:NO,sort_order:int4:NO,created_at:timestamptz:NO,updated_at:timestamptz:NO',
    'device_component_kind=id:uuid:NO,tenant_id:uuid:NO,key:text:NO,name:text:NO,status:text:NO,sort_order:int4:NO,created_at:timestamptz:NO,updated_at:timestamptz:NO',
    'maintenance_rule=id:uuid:NO,tenant_id:uuid:NO,model_key:text:NO,component_key:text:NO,interval_months:int4:NO,lead_days:int4:NO,created_at:timestamptz:NO,updated_at:timestamptz:NO',
    'device_status=id:uuid:NO,tenant_id:uuid:NO,key:text:NO,name:text:NO,is_in_field:bool:NO,is_in_stock:bool:NO,is_tracked:bool:NO,aliases:_text:NO,status:text:NO,sort_order:int4:NO,created_at:timestamptz:NO,updated_at:timestamptz:NO',
    'device=id:uuid:NO,tenant_id:uuid:NO,connection_id:uuid:NO,source_system:text:NO,source_id:text:NO,serial:text:YES,model_key:text:YES,market:text:YES,'
      || 'device_status_key:text:YES,warehouse_ref:text:YES,customer_ref:text:YES,customer_ref_invalid:bool:NO,subscription_ref:text:YES,order_ref:text:YES,'
      || 'first_shipped_on:date:YES,stock_received_on:date:YES,last_shipped_on:date:YES,warranty_until:date:YES,end_of_life_on:date:YES,'
      || 'external_refs:jsonb:NO,raw:jsonb:NO,source_deleted_at:timestamptz:YES,first_seen_at:timestamptz:NO,synced_at:timestamptz:NO',
    'device_component=id:uuid:NO,tenant_id:uuid:NO,device_id:uuid:NO,component_key:text:NO,serial:text:YES,expires_on:date:YES,first_seen_at:timestamptz:NO,replaced_at:timestamptz:YES',
    'device_import_row=id:uuid:NO,tenant_id:uuid:NO,batch_key:text:NO,source_row:int4:YES,source_id:text:YES,serial:text:YES,model:text:YES,status:text:YES,'
      || 'country:text:YES,warehouse_ref:text:YES,customer_ref:text:YES,subscription_ref:text:YES,order_ref:text:YES,first_shipped_on:text:YES,'
      || 'stock_received_on:text:YES,last_shipped_on:text:YES,warranty_until:text:YES,end_of_life_on:text:YES,components:text:YES,external_refs:text:YES,'
      || 'staged_at:timestamptz:NO'] loop
    if (select string_agg(column_name || ':' || udt_name || ':' || is_nullable, ',' order by ordinal_position)
        from information_schema.columns where table_schema = 'cma' and table_name = split_part(v_t, '=', 1))
       is distinct from split_part(v_t, '=', 2) then
      v_bad := v_bad || split_part(v_t, '=', 1) || ' columns; ';
    end if;
  end loop;
  insert into verify_0008zi values (2, 'A2 the seven tables'' columns, types and nullability',
    case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_bad);

  -- A3. keys and checks: one device per connection and record id; one current component per device and kind; the raw's
  --     key allow-list and no @; the named ids; the customer reference; the reserved kind device; a status in the field
  --     and in stock at once; an alias held twice; the kind assets; the job assets_import; the setting (0, integer)
  v_bad := '';
  if not exists (select 1 from pg_constraint where conrelid = 'cma.device'::regclass and contype = 'u'
                 and pg_get_constraintdef(oid) = 'UNIQUE (tenant_id, connection_id, source_id)') then
    v_bad := v_bad || 'device key; ';
  end if;
  if (select pg_get_indexdef('cma.device_component_current_idx'::regclass)) not like '%UNIQUE%(tenant_id, device_id, component_key) WHERE (replaced_at IS NULL)' then
    v_bad := v_bad || 'one current component; ';
  end if;
  if cma.device_raw_ok('{"source_id": "r", "email": "x"}') or cma.device_raw_ok('{"serial": "a@b"}') or not cma.device_raw_ok('{"source_id": "r", "model": "HS1"}')
     or cma.device_external_refs_ok('{"Bad": "1"}') or cma.device_external_refs_ok('{"ns_id": "a b"}') or not cma.device_external_refs_ok('{"ns_id": "123"}')
     or cma.asset_aliases_ok(array['HS1']) or cma.asset_aliases_ok(array['a', 'a']) or not cma.asset_aliases_ok(array['heartstart hs1']) then
    v_bad := v_bad || 'raw, named ids or aliases; ';
  end if;
  if (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.device'::regclass and conname = 'device_customer_ref_check')
     not like '%[A-Za-z0-9_-]{1,100}$%'
     or (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.device_component_kind'::regclass and conname = 'device_component_kind_key_check')
        not like '%device%'
     or (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.device_status'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%is_in_field%is_in_stock%') is null then
    v_bad := v_bad || 'customer reference, reserved kind or status flags; ';
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'cma.device_model'::regclass and tgname = 'check_aliases' and not tgisinternal)
     or not exists (select 1 from pg_trigger where tgrelid = 'cma.device_status'::regclass and tgname = 'check_aliases' and not tgisinternal) then
    v_bad := v_bad || 'alias triggers; ';
  end if;
  if (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.integration_connection'::regclass and conname = 'integration_connection_kind_check')
     not like '%''reviews''%''assets''%'
     or (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.sync_run'::regclass and conname = 'sync_run_job_check')
        not like '%''legacy_call_import''%''assets_import''%'
     or (select s.value_type || ':' || s.default_value from cma.setting s where s.key = 'assets.bundle_window_days') is distinct from 'integer:0' then
    v_bad := v_bad || 'kind, job or setting; ';
  end if;
  insert into verify_0008zi values (3, 'A3 keys and checks: the raw''s allow-list, named ids, customer reference, current component, kind, job, setting',
    case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_bad);

  -- A4. tenant-aware as every table: row-level security with the tenant policy, the audit trigger; the application may
  --     read, add and change, never delete (but staged rows, which it never changes); the readers nothing on the tables
  v_bad := '';
  foreach v_t in array array['cma.device_model', 'cma.device_component_kind', 'cma.maintenance_rule', 'cma.device_status', 'cma.device',
                             'cma.device_component', 'cma.device_import_row'] loop
    if not (select relrowsecurity from pg_class where oid = v_t::regclass)
       or not exists (select 1 from pg_policy where polrelid = v_t::regclass and polname = 'tenant_app')
       or not exists (select 1 from pg_trigger where tgrelid = v_t::regclass and tgname = 'audit' and not tgisinternal)
       or not has_table_privilege('cma_app', v_t, 'select') or not has_table_privilege('cma_app', v_t, 'insert')
       or has_table_privilege('cma_app', v_t, 'update') = (v_t = 'cma.device_import_row')
       or has_table_privilege('cma_app', v_t, 'delete') <> (v_t = 'cma.device_import_row')
       or has_table_privilege('cma_readonly', v_t, 'select') then
      v_bad := v_bad || v_t || '; ';
    end if;
  end loop;
  -- the COPY target: a view the application selects from and inserts into (an instead-of trigger), nothing else
  if not has_table_privilege('cma_app', 'cma.device_import_staging', 'select') or not has_table_privilege('cma_app', 'cma.device_import_staging', 'insert')
     or has_table_privilege('cma_app', 'cma.device_import_staging', 'update') or has_table_privilege('cma_app', 'cma.device_import_staging', 'delete')
     or has_table_privilege('cma_readonly', 'cma.device_import_staging', 'select')
     or not exists (select 1 from pg_trigger where tgrelid = 'cma.device_import_staging'::regclass and tgname = 'stage_row' and not tgisinternal) then
    v_bad := v_bad || 'cma.device_import_staging; ';
  end if;
  insert into verify_0008zi values (4, 'A4 row-level security, the audit trigger, no delete but staged rows, nothing for the readers; the COPY target',
    case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_bad);

  -- A5. every function the application's only and in the caller's rights; the readers' function definer, the owner's,
  --     search path pinned with pg_temp last, the readers' only
  v_bad := '';
  foreach v_fn in array array[
    'cma.connection_held_kinds_of(uuid,uuid)', 'cma.set_connection_kind(uuid,text)', 'cma.asset_aliases_ok(text[])',
    'cma.device_model_key_of(uuid,text)', 'cma.device_status_key_of(uuid,text)', 'cma.device_external_refs_ok(jsonb)', 'cma.device_raw_ok(jsonb)',
    'cma.assets_set_up_of(uuid)', 'cma.assert_assets_connection(uuid)', 'cma.device_staged_text(text)', 'cma.device_staged_ref(text)',
    'cma.device_staged_date(text,integer,text)', 'cma.device_staged_object(text,integer,text)', 'cma.device_staged_without_at(text)',
    'cma.device_staged_object_without_at(text)', 'cma.load_device_snapshot(text,uuid,boolean)',
    'cma.maintenance_items_of(uuid,date)', 'cma.tenant_today_of(uuid)', 'cma.assert_maintenance_horizon(date,integer,date)',
    'cma.maintenance_due_of(date,integer)', 'cma.assert_maintenance_filters(text,text,text)',
    'cma.maintenance_bucketed_of(uuid,date,integer,text,text,text,date)', 'cma.maintenance_page_of(uuid,date,integer,text,text,text,date)',
    'cma.maintenance_page(date,integer,text,text,text)', 'cma.maintenance_rows_of(uuid,date,integer,text,text,text,text,text,integer,date)',
    'cma.maintenance_rows(date,integer,text,text,text,text,text,integer)', 'cma.data_quality_assets_checks()', 'cma.data_quality_of(uuid)',
    'cma.data_quality()'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure(v_fn) and a.grantee = 0) then
      v_bad := v_bad || v_fn || '; ';
    end if;
  end loop;
  foreach v_fn in array array['cma.check_asset_aliases()', 'cma.device_import_staging_insert()'] loop
    if exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure(v_fn) and a.grantee = 0)
       or has_function_privilege('cma_readonly', v_fn, 'execute') then
      v_bad := v_bad || v_fn || '; ';
    end if;
  end loop;
  v_fn := 'cma_read.maintenance_due_rows()';
  if to_regprocedure(v_fn) is null then
    v_bad := v_bad || v_fn || ' missing; ';
  elsif not (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
        or (select pg_get_userbyid(proowner) from pg_proc where oid = to_regprocedure(v_fn)) <> 'cma_owner'
        or (select array_to_string(proconfig, ',') from pg_proc where oid = to_regprocedure(v_fn)) is distinct from 'search_path=pg_catalog, cma, pg_temp'
        or not has_function_privilege('cma_readonly', v_fn, 'execute') or has_function_privilege('cma_app', v_fn, 'execute')
        or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure(v_fn) and a.grantee = 0) then
    v_bad := v_bad || v_fn || '; ';
  end if;
  insert into verify_0008zi values (5, 'A5 every function the application''s only and invoker; the readers'' function definer, the owner''s, pinned, theirs only',
    case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_bad);

  -- A6. the reporting views' exact columns, readable by the readers; no raw, name of a person, email, phone or address
  v_bad := '';
  foreach v_t in array array[
    'device_model=id,tenant_id,key,name,brand,aliases,status,sort_order,created_at,updated_at',
    'device_component_kind=id,tenant_id,key,name,status,sort_order,created_at,updated_at',
    'maintenance_rule=id,tenant_id,model_key,component_key,interval_months,lead_days,created_at,updated_at',
    'device_status=id,tenant_id,key,name,is_in_field,is_in_stock,is_tracked,aliases,status,sort_order,created_at,updated_at',
    'device=id,tenant_id,connection_id,source_system,source_id,serial,model_key,market,device_status_key,warehouse_ref,customer_ref,customer_ref_invalid,'
      || 'subscription_ref,order_ref,first_shipped_on,stock_received_on,last_shipped_on,warranty_until,end_of_life_on,external_refs,source_deleted_at,first_seen_at,synced_at',
    'device_component=id,tenant_id,device_id,component_key,serial,expires_on,first_seen_at,replaced_at',
    'maintenance_due=tenant_id,device_id,connection_id,source_id,serial,model_key,market,device_status_key,is_in_field,is_in_stock,component_key,due_on,basis,'
      || 'action_on,action_month,past_due,exchange_key,exchange_on',
    'maintenance_per_month=tenant_id,month,market,model_key,items,component_items,end_of_life,exchanges,past_due',
    'dq_device_serial_missing=tenant_id,connection_id,object_type,object_id,value', 'dq_device_serial_duplicate=tenant_id,connection_id,object_type,object_id,value',
    'dq_device_model_unmapped=tenant_id,connection_id,object_type,object_id,value', 'dq_device_status_unmapped=tenant_id,connection_id,object_type,object_id,value',
    'dq_device_market_unmapped=tenant_id,connection_id,object_type,object_id,value', 'dq_device_customer_ref_invalid=tenant_id,connection_id,object_type,object_id,value',
    'dq_component_due_unknown=tenant_id,connection_id,object_type,object_id,value',
    'dq_field_device_without_subscription_ref=tenant_id,connection_id,object_type,object_id,value'] loop
    if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
        where table_schema = 'cma_read' and table_name = split_part(v_t, '=', 1)) is distinct from split_part(v_t, '=', 2) then
      v_bad := v_bad || split_part(v_t, '=', 1) || '; ';
    end if;
    if not has_table_privilege('cma_readonly', 'cma_read.' || split_part(v_t, '=', 1), 'select') then
      v_bad := v_bad || split_part(v_t, '=', 1) || ' not readable; ';
    end if;
  end loop;
  if exists (select 1 from information_schema.columns
             where table_schema = 'cma_read' and (table_name like 'device%' or table_name like 'maintenance%' or table_name like 'dq_device%'
                                                  or table_name like 'dq_component%' or table_name like 'dq_field_device%')
               and column_name ~ '(raw|email|phone|mobile|address|first_name|last_name|full_?name|customer_name|postcode|city)') then
    v_bad := v_bad || 'a personal or raw column; ';
  end if;
  if exists (select 1 from regexp_split_to_table(pg_get_function_result('cma.maintenance_rows(date,integer,text,text,text,text,text,integer)'::regprocedure), ', ') c
             where c ~ '(email|phone|address|first_name|last_name|customer_name|postcode|city|^name )') then
    v_bad := v_bad || 'a personal column in the device list; ';
  end if;
  insert into verify_0008zi values (6, 'A6 the reporting views'' exact columns, readable; no raw, person''s name, email, phone or address; nor in the device list',
    case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_bad);

  -- A7. the data-quality catalog (230 to 300), nothing twice
  v_bad := '';
  if (select string_agg(check_key || ':' || sort_order, ',' order by sort_order) from cma.data_quality_assets_checks())
     is distinct from 'device_serial_missing:230,device_serial_duplicate:240,device_model_unmapped:250,device_status_unmapped:260,'
                      || 'device_market_unmapped:270,device_customer_ref_invalid:280,component_due_unknown:290,field_device_without_subscription_ref:300'
     or (select count(*) from cma.schema_migration where version = '0008zi') <> 1 then
    v_bad := v_bad || 'the data-quality catalog or something twice; ';
  end if;
  insert into verify_0008zi values (7, 'A7 the eight data-quality checks in their order, nothing twice',
    case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_bad);

  -- A8. the redefinitions carry what came before: 0008ze's held kinds (reviews, tasks, email) with assets; 0008ze's data
  --     quality (the reviews' checks, the forms', the unlinked rule) with the asset register's; the settings' checks;
  --     0008zf's audit image (the uncounted lines, the invitation's hash, the ingest event's raw, the review's
  --     reference) with the staged row's keys only
  v_bad := '';
  if (select prosrc from pg_proc where oid = 'cma.connection_held_kinds_of(uuid,uuid)'::regprocedure) !~ 'cma\.crm_task x'
     or (select prosrc from pg_proc where oid = 'cma.connection_held_kinds_of(uuid,uuid)'::regprocedure) !~ 'cma\.review_channel x'
     or (select prosrc from pg_proc where oid = 'cma.connection_held_kinds_of(uuid,uuid)'::regprocedure) !~ 'cma\.device x' then
    v_bad := v_bad || 'held kinds; ';
  end if;
  if (select prosrc from pg_proc where oid = 'cma.data_quality_of(uuid)'::regprocedure) !~ 'outbound_unanswered_untagged'
     or (select prosrc from pg_proc where oid = 'cma.data_quality_of(uuid)'::regprocedure) !~ 'form_answer_not_in_options'
     or (select prosrc from pg_proc where oid = 'cma.data_quality_of(uuid)'::regprocedure) !~ 'market_without_review_channel'
     or (select prosrc from pg_proc where oid = 'cma.data_quality_of(uuid)'::regprocedure) !~ 'field_device_without_subscription_ref'
     or (select prosrc from pg_proc where oid = 'cma.data_quality()'::regprocedure) !~ 'data_quality_reviews_checks\(\)'
     or (select prosrc from pg_proc where oid = 'cma.data_quality()'::regprocedure) !~ 'data_quality_assets_checks\(\)' then
    v_bad := v_bad || 'data quality; ';
  end if;
  if (select prosrc from pg_proc where oid = 'cma.check_tenant_setting()'::regprocedure) !~ 'reviews\.negative_max_rating'
     or (select prosrc from pg_proc where oid = 'cma.check_tenant_setting()'::regprocedure) !~ 'calls\.conversation_min_talk_seconds'
     or (select prosrc from pg_proc where oid = 'cma.check_tenant_setting()'::regprocedure) !~ 'assets\.bundle_window_days' then
    v_bad := v_bad || 'settings; ';
  end if;
  if (select prosrc from pg_proc where oid = 'cma.audit_row()'::regprocedure) !~ 'uncounted_line'
     or (select prosrc from pg_proc where oid = 'cma.audit_row()'::regprocedure) !~ 'token_hash'
     or (select prosrc from pg_proc where oid = 'cma.audit_row()'::regprocedure) !~ 'ingest_event'
     or (select prosrc from pg_proc where oid = 'cma.audit_row()'::regprocedure) !~ 'review_image_without_at_reference'
     or (select prosrc from pg_proc where oid = 'cma.audit_row()'::regprocedure) !~ 'device_import_row' then
    v_bad := v_bad || 'audit image; ';
  end if;
  insert into verify_0008zi values (8, 'A8 the redefinitions carry 0008ze''s kinds, data quality and settings, 0008zf''s audit image',
    case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_bad);
end
$$;

-- B. Behaviour on two throwaway tenants (rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_rows     text[] := '{}';
  v_t1 uuid; v_t2 uuid;
  v_admin1 uuid; v_analyst1 uuid; v_reader1 uuid; v_agent1 uuid; v_admin2 uuid;
  v_crm uuid; v_shop uuid; v_reg uuid; v_reg2 uuid;
  v_role uuid;
  v_txt text; v_a text; v_b text;
  v_n integer;
  j jsonb;
  v_today    date := '2026-10-27';   -- Tuesday 27 October 2026: the current month is October
  v_from     date := '2026-10-01';
  v_cur      date;
begin
  begin
    -- tenants, people and roles (as the owner)
    v_t1 := cma.create_tenant('verify-0008zi-one', 'Verify 0008zi one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008zi-two', 'Verify 0008zi two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-analyst1@example.invalid', 'analyst1') returning id into v_analyst1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-reader1@example.invalid', 'reader1') returning id into v_reader1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent1@example.invalid', 'agent1') returning id into v_agent1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin2') returning id into v_admin2;
    insert into cma.app_role (tenant_id, key, name) values (v_t1, 'verify_reader', 'Verify reader') returning id into v_role;
    insert into cma.role_permission (tenant_id, role_id, permission_key) values (v_t1, v_role, 'reports.view');
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_analyst1, 'analytics'), (v_t1, v_reader1, 'verify_reader'), (v_t1, v_agent1, 'agent'),
                 (v_t2, v_admin2, 'admin')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifycrm', 'Verify assets CRM', 'portal-1', 'crm') returning id into v_crm;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifyshop', 'Verify assets shop', 'shop-1', 'commerce') returning id into v_shop;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t1, 'verifyregister', 'Verify asset register', 'base-1') returning id into v_reg;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t2, 'verifyregister', 'Verify asset register two', 'base-2') returning id into v_reg2;
    -- the store's customer cu-1, linked to the CRM contact c-1 (0008h; as the owner: 0007b's upserts are not under test)
    insert into cma.commerce_customer (tenant_id, connection_id, source_system, source_id, crm_connection_id, crm_contact_source_id, matched_at)
    values (v_t1, v_shop, 'verifyshop', 'cu-1', v_crm, 'c-1', '2026-09-01 10:00:00+00');
    perform set_config('role', 'cma_app', true);

    -- tenant one's configuration (the admin): markets and aliases, the catalogs, the bundling window
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', null, null, 10);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR', null, null, 20);
    perform cma.set_market_alias('united kingdom', 'GB');
    perform cma.set_market_alias('netherlands', 'NL');
    insert into cma.device_model (key, name, brand, aliases, sort_order) values
      ('hs1', 'HS1', 'Verify brand', array['hs1', 'heartstart hs1'], 10), ('frx', 'FRx', 'Verify brand', array['frx'], 20);
    insert into cma.device_component_kind (key, name, sort_order) values ('pads', 'Pads', 10), ('battery', 'Battery', 20);
    insert into cma.maintenance_rule (model_key, component_key, interval_months, lead_days) values
      ('hs1', 'pads', 24, 60), ('hs1', 'battery', 54, 60), ('frx', 'pads', 24, 60), ('frx', 'battery', 54, 60);
    insert into cma.device_status (key, name, is_in_field, is_in_stock, is_tracked, aliases, sort_order) values
      ('active_customer', 'Active/Customer', true, false, true, array['active/customer'], 10),
      ('in_storage', 'In Storage', false, true, true, array['in storage'], 20),
      ('internal_usage', 'Internal Usage', false, false, true, array['internal usage'], 30),
      ('stolen_missing', 'Stolen/Missing', false, false, false, array['stolen/missing'], 40);
    perform cma.set_tenant_setting('assets.bundle_window_days', '90');

    -- B1. the catalogs' guards: an alias another model holds or another model's key (CMA03), while a seed's rerun of the
    --     same model meets it on conflict (ok); a kind keyed device and a
    --     status in the field and in stock (check, 23514); a rule for a model the catalog lacks (23503); a setting of 366,
    --     -1 or a word (CMA04); tenant one cannot write a row for tenant two (row-level security, 42501)
    v_txt := pg_temp.v0008zi_code('insert into cma.device_model (key, name, aliases) values (''other'', ''Other'', array[''heartstart hs1''])')
             || ' ' || pg_temp.v0008zi_code('insert into cma.device_model (key, name, aliases) values (''other'', ''Other'', array[''frx''])')
             || ' ' || pg_temp.v0008zi_code('insert into cma.device_model (key, name, aliases) values (''hs1'', ''HS1'', array[''hs1'', ''heartstart hs1'']) on conflict (tenant_id, key) do nothing')
             || ' ' || pg_temp.v0008zi_code('insert into cma.device_component_kind (key, name) values (''device'', ''Device'')')
             || ' ' || pg_temp.v0008zi_code('insert into cma.device_status (key, name, is_in_field, is_in_stock) values (''both'', ''Both'', true, true)')
             || ' ' || pg_temp.v0008zi_code('insert into cma.maintenance_rule (model_key, component_key, interval_months) values (''nope'', ''pads'', 12)')
             || ' ' || pg_temp.v0008zi_code('select cma.set_tenant_setting(''assets.bundle_window_days'', ''366'')')
             || ' ' || pg_temp.v0008zi_code('select cma.set_tenant_setting(''assets.bundle_window_days'', ''-1'')')
             || ' ' || pg_temp.v0008zi_code('select cma.set_tenant_setting(''assets.bundle_window_days'', ''ninety'')')
             || ' ' || pg_temp.v0008zi_code(format('insert into cma.device_model (tenant_id, key, name) values (%L, ''x'', ''X'')', v_t2))
             || ' ' || cma.setting_of(v_t1, 'assets.bundle_window_days');
    v_rows := v_rows || array['11', 'B1 the catalogs'' guards: aliases held once, the reserved kind, the status flags, the rule''s model, the window, the tenant',
      case when v_txt = 'CMA03 CMA03 ok 23514 23514 23503 CMA04 CMA04 CMA04 42501 90' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B2. the first load (the admin, a full snapshot of seven records): counts; the mapping of model (an alias), status,
    --     market (an alias, a code, a country the catalog lacks); the invalid customer reference never stored; the
    --     dropped serial and named ids; the components; the raw without the dropped values; the staged rows deleted; one
    --     run of job assets_import with the counts; the connection's kind now implied by its devices
    v_n := pg_temp.v0008zi_stage('b1', 1);
    j := cma.load_device_snapshot('b1', v_reg, true);
    v_txt := v_n || ' ' || pg_temp.v0008zi_counts(j);
    perform set_config('role', 'cma_owner', true);
    select v_txt || ' | ' || string_agg(d.source_id || ':' || coalesce(d.serial, '-') || ':' || coalesce(d.model_key, '-') || ':' || coalesce(d.device_status_key, '-')
                                        || ':' || coalesce(d.market, '-') || ':' || coalesce(d.customer_ref, '-') || ':' || d.customer_ref_invalid::text
                                        || ':' || (select count(*) from cma.device_component c where c.tenant_id = d.tenant_id and c.device_id = d.id),
                                        ' ' order by d.source_id)
      into v_txt
    from cma.device d where d.tenant_id = v_t1;
    select v_txt || ' | ' || (d.external_refs::text) || ' ' || (d.raw ? 'serial')::text || ' ' || (d.raw ->> 'country')
           || ' ' || (select (x.raw ? 'customer_ref')::text || '/' || (x.raw ->> 'model') from cma.device x where x.tenant_id = v_t1 and x.source_id = 'rec-2')
           || ' ' || (select count(*) from cma.device_import_row s where s.tenant_id = v_t1)
           || ' ' || (select r.job || '/' || r.stream || '/' || r.status || '/' || (r.counts = j)::text from cma.sync_run r
                      where r.tenant_id = v_t1 and r.connection_id = v_reg)
           || ' ' || array_to_string(cma.connection_held_kinds_of(v_t1, v_reg), ',')
           || ' ' || (select string_agg(a.action, ',' order by a.action) from (select distinct al.action from cma.audit_log al
                      where al.tenant_id = v_t1 and al.table_name = 'device' and al.actor_user_id = v_admin1) a)
      into v_txt
    from cma.device d where d.tenant_id = v_t1 and d.source_id = 'rec-7';
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['12', 'B2 the first load: counts, mapping, the invalid reference and dropped values never stored, the run, the kind',
      case when v_txt = '7 rows=7 ins=7 upd=0 same=0 missing=0 repl=0 um=1 us=1 uk=1 cri=1 drop=3 | '
                        || 'rec-1:SN-1:hs1:active_customer:NL:cu-1:false:2 rec-2:SN-2:hs1:active_customer:GB:-:true:0 rec-3:SN-3:frx:in_storage:NL:-:false:1 '
                        || 'rec-4:SN-1:-:internal_usage:-:-:false:0 rec-5:-:hs1:stolen_missing:GB:cu-9:false:0 rec-6:SN-6:hs1:-:NL:-:false:0 '
                        || 'rec-7:-:hs1:in_storage:NL:-:false:0 | {"ns_internal_id": "12345"} false nl false/heartstart hs1 0 '
                        || 'assets_import/b1/succeeded/true assets insert'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B3. the kind: the devices make the connection assets; another kind is refused (CMA03), assets accepted; a load
    --     into a CRM connection is refused (CMA04)
    v_txt := pg_temp.v0008zi_code(format('select cma.set_connection_kind(%L, %L)', v_reg, 'crm'))
             || ' ' || pg_temp.v0008zi_code(format('select cma.set_connection_kind(%L, %L)', v_reg, 'assets'));
    v_n := pg_temp.v0008zi_stage('b-crm', 4);
    v_txt := v_txt || ' ' || pg_temp.v0008zi_code(format('select cma.load_device_snapshot(%L, %L, true)', 'b-crm', v_crm))
             || ' ' || (select c.kind from cma.integration_connection c where c.id = v_reg);
    delete from cma.device_import_row s where s.batch_key = 'b-crm';
    v_rows := v_rows || array['13', 'B3 the kind: implied by the devices, another refused, assets set; a load into a CRM connection refused',
      case when v_txt = 'CMA03 ok CMA04 assets' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B4. the same file again: every record unchanged, nothing replaced or missing; components unchanged
    v_n := pg_temp.v0008zi_stage('b2', 1);
    j := cma.load_device_snapshot('b2', v_reg, true);
    v_txt := pg_temp.v0008zi_counts(j) || ' ' || (select count(*) from cma.device_component c where c.tenant_id = v_t1)
             || ' ' || (select count(*) from cma.sync_run r where r.tenant_id = v_t1 and r.job = 'assets_import');
    v_rows := v_rows || array['14', 'B4 a rerun of the same file: every record unchanged',
      case when v_txt = 'rows=7 ins=0 upd=0 same=7 missing=0 repl=0 um=1 us=1 uk=1 cri=1 drop=3 3 2' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B5. a full snapshot with rec-1's battery under another serial and rec-7 missing: the battery replaced (the old row
    --     keeps its serial with replaced_at, the new one current), rec-7 missing (source_deleted_at); then a partial
    --     snapshot of rec-7 alone brings it back and marks nothing missing
    v_n := pg_temp.v0008zi_stage('b3', 3);
    j := cma.load_device_snapshot('b3', v_reg, true);
    v_txt := pg_temp.v0008zi_counts(j);
    select v_txt || ' | ' || string_agg(c.serial || ':' || c.expires_on || ':' || (c.replaced_at is null)::text, ' ' order by c.first_seen_at, c.serial)
      into v_txt
    from cma.device_component c join cma.device d on d.id = c.device_id
    where c.tenant_id = v_t1 and d.source_id = 'rec-1' and c.component_key = 'battery';
    v_txt := v_txt || ' | ' || (select (d.source_deleted_at is not null)::text from cma.device d where d.tenant_id = v_t1 and d.source_id = 'rec-7');
    v_n := pg_temp.v0008zi_stage('b4', 4);
    j := cma.load_device_snapshot('b4', v_reg, false);
    v_txt := v_txt || ' | ' || pg_temp.v0008zi_counts(j) || ' | '
             || (select count(*) filter (where d.source_deleted_at is not null) from cma.device d where d.tenant_id = v_t1);
    v_rows := v_rows || array['15', 'B5 a serial change is a replacement, a record missing from a full snapshot; a partial snapshot brings it back',
      case when v_txt = 'rows=6 ins=0 upd=1 same=5 missing=1 repl=1 um=1 us=1 uk=1 cri=1 drop=0 | B-1:2027-01-20:false B-1b:2027-01-30:true | true | '
                        || 'rows=1 ins=0 upd=1 same=0 missing=0 repl=0 um=0 us=0 uk=0 cri=0 drop=3 | 0'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B6. the refusals, nothing written: no staged rows (CMA02); a record id twice, a line without one, a date that is no
    --     YYYY-MM-DD, a component kind the catalog lacks, a component with another field, is_full null, a batch key with
    --     capitals (CMA04); the analyst can neither load nor stage (CMA06); tenant two loading into tenant one's
    --     connection (CMA02)
    v_txt := pg_temp.v0008zi_code(format('select cma.load_device_snapshot(%L, %L, true)', 'none', v_reg));
    insert into cma.device_import_staging (batch_key, source_row, source_id) values ('bad1', 2, 'rec-1'), ('bad1', 3, 'rec-1');
    insert into cma.device_import_staging (batch_key, source_row, source_id) values ('bad2', 2, ' ');
    insert into cma.device_import_staging (batch_key, source_row, source_id, first_shipped_on) values ('bad3', 2, 'rec-1', '27-10-2026');
    insert into cma.device_import_staging (batch_key, source_row, source_id, components) values ('bad4', 2, 'rec-1', '{"filter": {"serial": "F-1"}}');
    insert into cma.device_import_staging (batch_key, source_row, source_id, components) values ('bad5', 2, 'rec-1', '{"pads": {"lot": "L-1"}}');
    v_txt := v_txt || ' ' || pg_temp.v0008zi_code(format('select cma.load_device_snapshot(%L, %L, true)', 'bad1', v_reg))
             || ' ' || pg_temp.v0008zi_code(format('select cma.load_device_snapshot(%L, %L, true)', 'bad2', v_reg))
             || ' ' || pg_temp.v0008zi_code(format('select cma.load_device_snapshot(%L, %L, true)', 'bad3', v_reg))
             || ' ' || pg_temp.v0008zi_code(format('select cma.load_device_snapshot(%L, %L, true)', 'bad4', v_reg))
             || ' ' || pg_temp.v0008zi_code(format('select cma.load_device_snapshot(%L, %L, true)', 'bad5', v_reg))
             || ' ' || pg_temp.v0008zi_code(format('select cma.load_device_snapshot(%L, %L, null)', 'bad1', v_reg))
             || ' ' || pg_temp.v0008zi_code(format('select cma.load_device_snapshot(%L, %L, true)', 'Bad1', v_reg));
    perform set_config('app.user_id', v_analyst1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008zi_code(format('select cma.load_device_snapshot(%L, %L, true)', 'bad1', v_reg))
             || ' ' || pg_temp.v0008zi_code('insert into cma.device_import_staging (batch_key, source_row, source_id) values (''bad6'', 2, ''rec-9'')');
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    insert into cma.device_import_staging (batch_key, source_row, source_id) values ('t2', 2, 'rec-x');
    v_txt := v_txt || ' ' || pg_temp.v0008zi_code(format('select cma.load_device_snapshot(%L, %L, true)', 't2', v_reg));
    delete from cma.device_import_row s where s.batch_key = 't2';
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    delete from cma.device_import_row s where s.batch_key like 'bad%';
    v_txt := v_txt || ' ' || (select count(*) from cma.sync_run r where r.tenant_id = v_t1 and r.job = 'assets_import')
             || ' ' || (select count(*) from cma.device d where d.tenant_id = v_t1);
    v_rows := v_rows || array['16', 'B6 the refusals: no rows, an id twice, no id, a date, a kind, a field, is_full, the key; the analyst; another tenant',
      case when v_txt = 'CMA02 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA06 CMA06 CMA02 4 7' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B7. the due basis and the action dates as of 27 October 2026: rec-1's pads recorded (10 December, acted on 11
    --     October), rec-2's pads by rule (the last shipment 10 February 2025 plus 24 months, acted on 60 days before),
    --     rec-7's pads unknown (no expiry, no shipment); rec-3's end of life recorded with no lead days; the untracked and
    --     unmapped statuses (rec-5, rec-6) give no item
    v_txt := (select string_agg(i.source_id || ':' || i.component_key || ':' || i.basis || ':' || coalesce(i.due_on::text, '-') || ':'
                                || coalesce(i.action_on::text, '-'), ' ' order by i.source_id, i.component_order)
              from cma.maintenance_items_of(v_t1, v_today) i);
    v_rows := v_rows || array['17', 'B7 the due basis (recorded, rule, unknown), the action dates, end of life, tracked statuses only',
      case when v_txt = 'rec-1:pads:recorded:2026-12-10:2026-10-11 rec-1:battery:recorded:2027-01-30:2026-12-01 '
                        || 'rec-2:pads:rule:2027-02-10:2026-12-12 rec-2:battery:rule:2029-08-10:2029-06-11 '
                        || 'rec-3:pads:recorded:2026-08-01:2026-06-02 rec-3:battery:rule:2027-07-10:2027-05-11 rec-3:device:recorded:2026-08-15:2026-08-15 '
                        || 'rec-4:pads:unknown:-:- rec-4:battery:unknown:-:- rec-7:pads:unknown:-:- rec-7:battery:unknown:-:-'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B8. bundling and past due: rec-1's pads and battery (51 days apart, within 90) one exchange from 11 October; rec-2's
    --     (more than 90 days apart) two; rec-3's pads and end of life (74 days) one, past due (acted on before October), its
    --     battery another; rec-1's pads acted on in October not past due. With a window of 0 every item is its own exchange
    v_txt := (select string_agg(i.source_id || ':' || i.component_key || ':' || coalesce(i.exchange_on::text, '-') || ':' || i.past_due::text, ' '
                                order by i.source_id, i.component_order)
              from cma.maintenance_items_of(v_t1, v_today) i where i.basis <> 'unknown')
             || ' | ' || (select count(distinct i.exchange_key) from cma.maintenance_items_of(v_t1, v_today) i);
    perform cma.set_tenant_setting('assets.bundle_window_days', '0');
    v_txt := v_txt || ' ' || (select count(distinct i.exchange_key) from cma.maintenance_items_of(v_t1, v_today) i);
    perform cma.set_tenant_setting('assets.bundle_window_days', '90');
    v_rows := v_rows || array['18', 'B8 bundling within the window one exchange, outside it two; past due before the current month; window 0',
      case when v_txt = 'rec-1:pads:2026-10-11:false rec-1:battery:2026-10-11:false rec-2:pads:2026-12-12:false rec-2:battery:2029-06-11:false '
                        || 'rec-3:pads:2026-06-02:true rec-3:battery:2027-05-11:false rec-3:device:2026-06-02:true | 5 7'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B9. the page from October 2026 for 12 months (the analyst): the buckets, the cells (past due first; rec-1's exchange
    --     counted in October, its battery in December; rec-2's pads and exchange in December; rec-3's past-due exchange with
    --     its end of life, its battery in May 2027), the unknown items per market and model (unknown last), the tracked
    --     devices, the filters, the window, set up
    perform set_config('app.user_id', v_analyst1::text, true);
    j := cma.maintenance_page_of(v_t1, v_from, 12, null, null, null, v_today);
    v_txt := (select string_agg(case when x ~ '^[0-9]' then left(x, 7) else x end, ',') from jsonb_array_elements_text(j -> 'buckets') x) || ' | ' || pg_temp.v0008zi_cells(j) || ' | '
             || (select string_agg((u ->> 'market') || '/' || (u ->> 'model') || '/' || (u ->> 'items'), ' ') from jsonb_array_elements(j -> 'unknown') u)
             || ' | ' || (j ->> 'unknown_items') || ' ' || (j ->> 'devices') || ' ' || (j -> 'filter_markets')::text || ' '
             || (select string_agg(m ->> 'key', ',') from jsonb_array_elements(j -> 'filter_models') m) || ' '
             || (select string_agg(k ->> 'key', ',') from jsonb_array_elements(j -> 'component_kinds') k) || ' '
             || (j ->> 'bundle_window_days') || ' ' || (j ->> 'is_set_up') || ' ' || (j ->> 'current_month');
    v_rows := v_rows || array['19', 'B9 the page: buckets, cells, the unknown items, tracked devices, filters, window, set up',
      case when v_txt = 'past_due,2026-10,2026-11,2026-12,2027-01,2027-02,2027-03,2027-04,2027-05,2027-06,2027-07,2027-08,2027-09 | '
                        || 'past_due/NL/frx/pads:1/1/1 2026-10/NL/hs1/pads:1/0/1 2026-12/GB/hs1/pads:1/0/1 2026-12/NL/hs1/battery:1/0/0 '
                        || '2027-05/NL/frx/battery:1/0/1 | NL/hs1/2 unknown/unknown/2 | 4 5 ["GB", "NL", "unknown"] hs1,frx,unknown pads,battery 90 true 2026-10-01'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B10. the filters: the field (rec-1, rec-2), the stock (rec-3, rec-7), GB, the model frx, the model unknown (rec-4);
    --      a horizon of 6 months from December leaves out October and May
    v_txt := 'field ' || pg_temp.v0008zi_cells(cma.maintenance_page_of(v_t1, v_from, 12, null, null, 'field', v_today))
             || ' ' || (cma.maintenance_page_of(v_t1, v_from, 12, null, null, 'field', v_today) ->> 'devices')
             || ' | stock ' || pg_temp.v0008zi_cells(cma.maintenance_page_of(v_t1, v_from, 12, null, null, 'stock', v_today))
             || ' ' || (cma.maintenance_page_of(v_t1, v_from, 12, null, null, 'stock', v_today) ->> 'unknown_items')
             || ' | GB ' || pg_temp.v0008zi_cells(cma.maintenance_page_of(v_t1, v_from, 12, 'GB', null, null, v_today))
             || ' | frx ' || pg_temp.v0008zi_cells(cma.maintenance_page_of(v_t1, v_from, 12, null, 'frx', null, v_today))
             || ' | unknown ' || pg_temp.v0008zi_cells(cma.maintenance_page_of(v_t1, v_from, 12, null, 'unknown', null, v_today))
             || ' ' || (cma.maintenance_page_of(v_t1, v_from, 12, null, 'unknown', null, v_today) ->> 'unknown_items')
             || ' | dec ' || pg_temp.v0008zi_cells(cma.maintenance_page_of(v_t1, '2026-12-01', 6, null, null, null, v_today));
    v_rows := v_rows || array['20', 'B10 the filters: field, stock, a market, a model, the model unknown; another horizon',
      case when v_txt = 'field 2026-10/NL/hs1/pads:1/0/1 2026-12/GB/hs1/pads:1/0/1 2026-12/NL/hs1/battery:1/0/0 2 | '
                        || 'stock past_due/NL/frx/pads:1/1/1 2027-05/NL/frx/battery:1/0/1 2 | GB 2026-12/GB/hs1/pads:1/0/1 | '
                        || 'frx past_due/NL/frx/pads:1/1/1 2027-05/NL/frx/battery:1/0/1 | unknown - 2 | '
                        || 'dec past_due/NL/frx/pads:1/1/1 2026-12/GB/hs1/pads:1/0/1 2026-12/NL/hs1/battery:1/0/0 2027-05/NL/frx/battery:1/0/1'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B11. the device list: the past-due exchange (rec-3, pads and its end of life); the components of December (rec-1's
    --      battery, rec-2's pads, by action date); October's exchange (rec-1 with both, its customer's CRM contact c-1); the
    --      unknown items (rec-7, then rec-4 of the unknown market); all buckets by exchange and the limit with the total
    v_txt := (select string_agg(r.serial || ':' || array_to_string(r.components, '+') || ':' || r.due_on || ':' || array_to_string(r.bases, '+') || ':'
                                || r.action_on || ':' || r.exchange_on || ':' || r.device_status_name || ':' || r.model_name, ' ')
              from cma.maintenance_rows_of(v_t1, v_from, 12, 'past_due', null, null, null, 'exchanges', 500, v_today) r)
             || ' | ' || (select string_agg(r.serial || ':' || array_to_string(r.components, '+') || ':' || r.action_on, ' ')
                          from cma.maintenance_rows_of(v_t1, v_from, 12, '2026-12-01', null, null, null, 'components', 500, v_today) r)
             || ' | ' || (select string_agg(r.serial || ':' || array_to_string(r.components, '+') || ':' || coalesce(r.customer_ref, '-') || ':'
                                            || coalesce(r.subscription_ref, '-') || ':' || coalesce(r.crm_contact_source_id, '-') || ':'
                                            || (r.crm_connection_id = v_crm)::text, ' ')
                          from cma.maintenance_rows_of(v_t1, v_from, 12, '2026-10-01', null, null, null, 'exchanges', 500, v_today) r)
             || ' | ' || (select string_agg(r.source_id || ':' || r.market || ':' || array_to_string(r.components, '+') || ':' || array_to_string(r.bases, '+'), ' ')
                          from cma.maintenance_rows_of(v_t1, v_from, 12, 'unknown', null, null, null, 'exchanges', 500, v_today) r)
             || ' | ' || (select string_agg(r.bucket || ':' || r.source_id, ' ')
                          from cma.maintenance_rows_of(v_t1, v_from, 12, 'all', null, null, null, 'exchanges', 500, v_today) r)
             || ' | ' || (select string_agg(r.source_id || ':' || r.total_rows, ' ')
                          from cma.maintenance_rows_of(v_t1, v_from, 12, 'all', null, null, null, 'exchanges', 1, v_today) r);
    v_rows := v_rows || array['21', 'B11 the device list: past due, a month''s components, a month''s exchange with the CRM contact, unknown, all, the limit',
      case when v_txt = 'SN-3:pads+device:2026-08-01:recorded:2026-06-02:2026-06-02:In Storage:FRx | SN-1:battery:2026-12-01 SN-2:pads:2026-12-12 | '
                        || 'SN-1:pads+battery:cu-1:sub-1:c-1:true | rec-7:NL:pads+battery:unknown rec-4:unknown:pads+battery:unknown | '
                        || 'past_due:rec-3 2026-10-01:rec-1 2026-12-01:rec-2 2027-05-01:rec-3 | rec-3:4'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B12. the parameters and the permission (the public reads, today's month): a horizon not on the first of a month, of
    --      25 months, before the current month; a market of three letters; a model with capitals; a scope of all; a bucket
    --      outside the horizon; a view of devices; a limit of 0 (CMA04); the reader and the analyst read; the agent is
    --      refused the page, the device list and the due items (CMA06)
    v_cur := date_trunc('month', cma.tenant_today_of(v_t1))::date;
    v_txt := pg_temp.v0008zi_code(format('select cma.maintenance_page(%L)', v_cur + 14))
             || ' ' || pg_temp.v0008zi_code(format('select cma.maintenance_page(%L, 25)', v_cur))
             || ' ' || pg_temp.v0008zi_code(format('select cma.maintenance_page(%L)', (v_cur - interval '1 month')::date))
             || ' ' || pg_temp.v0008zi_code(format('select cma.maintenance_page(%L, 12, ''NLD'')', v_cur))
             || ' ' || pg_temp.v0008zi_code(format('select cma.maintenance_page(%L, 12, null, ''HS1'')', v_cur))
             || ' ' || pg_temp.v0008zi_code(format('select cma.maintenance_page(%L, 12, null, null, ''all'')', v_cur))
             || ' ' || pg_temp.v0008zi_code(format('select * from cma.maintenance_rows(%L, 6, %L)', v_cur, (v_cur + interval '6 months')::date::text))
             || ' ' || pg_temp.v0008zi_code(format('select * from cma.maintenance_rows(%L, 6, ''past_due'', null, null, null, ''devices'')', v_cur))
             || ' ' || pg_temp.v0008zi_code(format('select * from cma.maintenance_rows(%L, 6, ''past_due'', null, null, null, ''exchanges'', 0)', v_cur))
             || ' ' || pg_temp.v0008zi_code(format('select cma.maintenance_page(%L, 12, ''unknown'', ''unknown'', ''field'')', v_cur))
             || ' ' || pg_temp.v0008zi_code(format('select * from cma.maintenance_due_of(%L, 24)', v_cur));
    perform set_config('app.user_id', v_reader1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008zi_code(format('select * from cma.maintenance_rows(%L, 12, ''all'')', v_cur));
    perform set_config('app.user_id', v_agent1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008zi_code(format('select cma.maintenance_page(%L)', v_cur))
             || ' ' || pg_temp.v0008zi_code(format('select * from cma.maintenance_rows(%L, 12, ''all'')', v_cur))
             || ' ' || pg_temp.v0008zi_code(format('select * from cma.maintenance_due_of(%L, 12)', v_cur));
    v_rows := v_rows || array['22', 'B12 the parameters (CMA04); the reader and the analyst read; the agent refused (CMA06)',
      case when v_txt = 'CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 ok ok ok CMA06 CMA06 CMA06' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B13. data quality (the admin): the eight checks listed with their totals (two without a serial, two holding SN-1,
    --      Model X, the unknown status, Spain, the invalid reference, four items without a due date, the field device
    --      without a subscription); the rows' values (labels, the serial, the components; never the reference); tenant
    --      two, without an asset register, lists none of them
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := (select string_agg(q.check_key || '=' || q.total, ',' order by q.check_key) from cma.data_quality() q
              where q.check_key in (select check_key from cma.data_quality_assets_checks()))
             || ' | ' || (select string_agg(f.check_key || ':' || f.object_id || ':' || coalesce(f.value, '-'), ' ' order by f.check_key, f.object_id, f.value)
                          from cma.data_quality_of(v_t1) f
                          where f.check_key in (select check_key from cma.data_quality_assets_checks()));
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    v_txt := v_txt || ' | two ' || (select count(*) from cma.data_quality() q where q.check_key in (select check_key from cma.data_quality_assets_checks()));
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    v_rows := v_rows || array['23', 'B13 data quality: the eight checks with their totals and values; tenant two without an asset register lists none',
      case when v_txt = 'component_due_unknown=4,device_customer_ref_invalid=1,device_market_unmapped=1,device_model_unmapped=1,device_serial_duplicate=2,'
                        || 'device_serial_missing=2,device_status_unmapped=1,field_device_without_subscription_ref=1 | '
                        || 'component_due_unknown:rec-4:battery component_due_unknown:rec-4:pads component_due_unknown:rec-7:battery component_due_unknown:rec-7:pads '
                        || 'device_customer_ref_invalid:rec-2:- device_market_unmapped:rec-4:Spain device_model_unmapped:rec-4:Model X '
                        || 'device_serial_duplicate:rec-1:SN-1 device_serial_duplicate:rec-4:SN-1 device_serial_missing:rec-5:- device_serial_missing:rec-7:- '
                        || 'device_status_unmapped:rec-6:Unknown status field_device_without_subscription_ref:rec-2:- | two 0'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B14. the reader views (as a reader, tenant one): the devices without raw, the components with the replaced one, the
    --      eleven due items, the month of October (rec-1's exchange; its pads), the eight dq_ views; tenant two sees none
    perform set_config('role', 'cma_readonly', true);
    v_txt := (select count(*) from cma_read.device d where d.tenant_id = v_t1)
             || ' ' || (select count(*) || '/' || count(*) filter (where c.replaced_at is not null) from cma_read.device_component c where c.tenant_id = v_t1)
             || ' ' || (select count(*) from cma_read.maintenance_due m where m.tenant_id = v_t1)
             || ' ' || (select m.items || '/' || m.component_items || '/' || m.end_of_life || '/' || m.exchanges from cma_read.maintenance_per_month m
                        where m.tenant_id = v_t1 and m.month = '2026-10-01' and m.market = 'NL' and m.model_key = 'hs1')
             || ' ' || (select count(*) from cma_read.dq_device_serial_missing q where q.tenant_id = v_t1)
             || (select count(*) from cma_read.dq_device_serial_duplicate q where q.tenant_id = v_t1)
             || (select count(*) from cma_read.dq_device_model_unmapped q where q.tenant_id = v_t1)
             || (select count(*) from cma_read.dq_device_status_unmapped q where q.tenant_id = v_t1)
             || (select count(*) from cma_read.dq_device_market_unmapped q where q.tenant_id = v_t1)
             || (select count(*) from cma_read.dq_device_customer_ref_invalid q where q.tenant_id = v_t1)
             || (select count(*) from cma_read.dq_component_due_unknown q where q.tenant_id = v_t1)
             || (select count(*) from cma_read.dq_field_device_without_subscription_ref q where q.tenant_id = v_t1)
             || ' ' || (select count(*) from cma_read.device_model m where m.tenant_id = v_t1) || '/'
             || (select count(*) from cma_read.device_status s where s.tenant_id = v_t1 and s.is_tracked);
    perform set_config('app.tenant_id', v_t2::text, true);
    v_txt := v_txt || ' two ' || (select count(*) from cma_read.device d where d.tenant_id = v_t1)
             || '/' || (select count(*) from cma_read.maintenance_due m where m.tenant_id = v_t1);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['24', 'B14 the reader views: devices, components, due items, a month, the dq_ views; tenant two sees none',
      case when v_txt = '7 4/1 11 1/1/0/1 22111141 2/3 two 0/0' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B15. tenant isolation (the application): tenant two sees none of tenant one's devices, components, catalogs or
    --      staged rows, and its page holds nothing; the raw guard refuses an email key and an @ (23514); a staged
    --      address is kept as a bare @ (a column, a component's serial, a named id, a key), and the audit images of every
    --      staged row of the run hold its keys only, never an @
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    v_txt := (select count(*) from cma.device) || '/' || (select count(*) from cma.device_component) || '/' || (select count(*) from cma.device_model)
             || '/' || (select count(*) from cma.device_import_staging) || (select count(*) from cma.device_import_row)
             || ' ' || pg_temp.v0008zi_cells(cma.maintenance_page_of(v_t2, v_from, 12, null, null, null, v_today))
             || ' ' || (cma.maintenance_page_of(v_t2, v_from, 12, null, null, null, v_today) ->> 'is_set_up');
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008zi_code('update cma.device set raw = raw || ''{"email": "x"}'' where source_id = ''rec-1''')
             || ' ' || pg_temp.v0008zi_code('update cma.device set raw = raw || ''{"model": "a@b"}'' where source_id = ''rec-1''');
    insert into cma.device_import_staging (batch_key, source_row, source_id, serial, customer_ref, components, external_refs)
    values ('b15', 2, 'rec-b15', 'sn@x.invalid', 'person@example.invalid', '{"pads": {"serial": "p@x.invalid", "expires_on": "2027-01-01"}}',
            '{"ns_internal_id": "a@x.invalid", "ns_fam_id": "F-1"}'),
           ('b15', 3, 'rec-b16', null, null, null, '{"a@x.invalid": "1"}');
    v_txt := v_txt || ' ' || (select string_agg(concat_ws('/', r.serial, r.customer_ref, r.components, r.external_refs), ' ' order by r.source_row)
                              from cma.device_import_row r where r.batch_key = 'b15');
    delete from cma.device_import_row r where r.batch_key = 'b15';
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || ' ' || (select count(*) > 0 from cma.audit_log a where a.tenant_id = v_t1 and a.table_name = 'device_import_row')
             || '/' || (select count(*) from cma.audit_log a, jsonb_object_keys(coalesce(a.new_row, a.old_row)) k
                        where a.tenant_id = v_t1 and a.table_name = 'device_import_row' and k not in ('id', 'tenant_id', 'batch_key', 'source_row'))
             || '/' || (select count(*) from cma.audit_log a
                        where a.tenant_id = v_t1 and a.table_name = 'device_import_row'
                          and (coalesce(a.new_row::text, '') || coalesce(a.old_row::text, '')) like '%@%');
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['25', 'B15 tenant isolation: tenant two sees nothing of tenant one; the raw guard refuses an email key and an @; a staged address a bare @, the audit keys only',
      case when v_txt = '0/0/0/00 - false 23514 23514 @/@/{"pads": {"serial": "@", "expires_on": "2027-01-01"}}/{"ns_fam_id": "F-1", "ns_internal_id": "@"} @ true/0/0'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B16. a replacement restarts the rule: a second, partial snapshot gives rec-3 a new pads serial without an expiry and
    --      rec-2 a battery without one. rec-3's new pads are dated first seen at 23:30 UTC on 11 November 2026, already 12
    --      November in the tenant's zone (Europe/Amsterdam), so they are due on 12 November 2028 (the rule's 24 months),
    --      basis rule, not past due; rec-2's battery (no predecessor) keeps the shipment anchor, the last shipment of 10
    --      February 2025 plus 54 months
    insert into cma.device_import_staging (batch_key, source_row, source_id, serial, model, status, country, warehouse_ref, customer_ref,
                                           first_shipped_on, stock_received_on, last_shipped_on, end_of_life_on, components)
    values ('b16', 2, 'rec-3', 'SN-3', 'FRx', 'In Storage', 'Netherlands', 'WH-B', null, '2023-01-10', '2022-12-01', null, '2026-08-15',
            '{"pads": {"serial": "P-3c"}}'),
           ('b16', 3, 'rec-2', 'SN-2', 'heartstart hs1', 'Active/Customer', 'United Kingdom', null, 'not an id!', '2024-03-01', null,
            '2025-02-10', null, '{"battery": {"serial": "B-2"}}');
    j := cma.load_device_snapshot('b16', v_reg, false);
    update cma.device_component c set first_seen_at = '2026-11-11 23:30:00+00'
    where c.tenant_id = v_t1 and c.serial = 'P-3c' and c.replaced_at is null;
    v_txt := pg_temp.v0008zi_counts(j) || ' | '
             || (select string_agg(i.source_id || ':' || i.component_key || ':' || i.basis || ':' || coalesce(i.due_on::text, '-')
                                   || ':' || i.past_due::text, ' ' order by i.source_id)
                 from cma.maintenance_items_of(v_t1, v_today) i
                 where (i.source_id, i.component_key) in (('rec-3', 'pads'), ('rec-2', 'battery')))
             || ' | ' || (select count(*) from cma.device_component c join cma.device d on d.id = c.device_id
                          where d.tenant_id = v_t1 and d.source_id = 'rec-3' and c.component_key = 'pads' and c.replaced_at is not null);
    v_rows := v_rows || array['26', 'B16 a replacement restarts the rule: a new serial without an expiry due from its first day, not past due; no predecessor, the shipment',
      case when v_txt = 'rows=2 ins=0 upd=2 same=0 missing=0 repl=1 um=0 us=0 uk=0 cri=1 drop=0 | rec-2:battery:rule:2029-08-10:false rec-3:pads:rule:2028-11-12:false | 1'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['59', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008zi (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008zi values (59, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- C. Speed: 5,000 devices with 10,000 components (rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_max      numeric := current_setting('verify.max_ms')::numeric;
  v_rows     text[] := '{}';
  v_t uuid; v_admin uuid; v_reg uuid;
  v_ms numeric; v_ms2 numeric;
begin
  begin
    v_t := cma.create_tenant('verify-0008zi-volume', 'Verify 0008zi volume', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-admin-volume@example.invalid', 'admin') returning id into v_admin;
    insert into cma.user_role (tenant_id, user_id, role_id) select v_t, v_admin, ar.id from cma.app_role ar where ar.tenant_id = v_t and ar.key = 'admin';
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency)
    select v_t, c, c, 'Europe/Amsterdam', 'en', 'EUR' from unnest(array['NL', 'GB', 'DE', 'FR', 'BE', 'IE', 'DK', 'SE']) c;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t, 'verifyregister', 'Verify register volume', 'base-v', 'assets') returning id into v_reg;
    insert into cma.device_model (tenant_id, key, name) values (v_t, 'm1', 'M1'), (v_t, 'm2', 'M2');
    insert into cma.device_component_kind (tenant_id, key, name, sort_order) values (v_t, 'pads', 'Pads', 10), (v_t, 'battery', 'Battery', 20);
    insert into cma.maintenance_rule (tenant_id, model_key, component_key, interval_months, lead_days)
    values (v_t, 'm1', 'pads', 24, 60), (v_t, 'm1', 'battery', 54, 60), (v_t, 'm2', 'pads', 24, 60), (v_t, 'm2', 'battery', 54, 60);
    insert into cma.device_status (tenant_id, key, name, is_in_field, is_in_stock, is_tracked)
    values (v_t, 'field', 'Field', true, false, true), (v_t, 'stock', 'Stock', false, true, true), (v_t, 'gone', 'Gone', false, false, false);
    insert into cma.tenant_setting (tenant_id, key, value) values (v_t, 'assets.bundle_window_days', '90');
    insert into cma.device (tenant_id, connection_id, source_system, source_id, serial, model_key, market, device_status_key, first_shipped_on,
                            last_shipped_on, end_of_life_on)
    select v_t, v_reg, 'verifyregister', 'rec-' || g, 'SN-' || g, case when g % 2 = 0 then 'm1' else 'm2' end,
           (array['NL', 'GB', 'DE', 'FR', 'BE', 'IE', 'DK', 'SE'])[1 + g % 8],
           case when g % 10 = 0 then 'gone' when g % 4 = 0 then 'stock' else 'field' end,
           '2022-01-01'::date + (g % 1200), case when g % 3 = 0 then '2023-06-01'::date + (g % 700) end,
           case when g % 7 = 0 then '2027-01-01'::date + (g % 900) end
    from generate_series(1, 5000) g;
    insert into cma.device_component (tenant_id, device_id, component_key, serial, expires_on)
    select d.tenant_id, d.id, k.key, k.key || '-' || d.source_id,
           case when (hashtext(d.source_id || k.key) % 3) <> 0 then '2026-06-01'::date + (abs(hashtext(d.source_id || k.key)) % 1400) end
    from cma.device d cross join (values ('pads'), ('battery')) k(key)
    where d.tenant_id = v_t;
    analyze cma.device;
    analyze cma.device_component;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    v_ms := pg_temp.v0008zi_best_ms(format('select cma.maintenance_page_of(%L, %L, 24, null, null, null, %L)', v_t, '2026-10-01', '2026-10-27'), 3);
    v_ms2 := pg_temp.v0008zi_best_ms(format('select * from cma.maintenance_rows_of(%L, %L, 24, ''all'', null, null, null, ''exchanges'', 500, %L)',
                                            v_t, '2026-10-01', '2026-10-27'), 3);
    v_rows := v_rows || array['41', 'C1 the page of 24 months and the device list of all buckets over 5,000 devices, as the application, under verify.max_ms',
      case when v_ms < v_max and v_ms2 < v_max and not v_provoke then 'ok' else 'FAIL' end, v_ms || ' ms, ' || v_ms2 || ' ms'];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['79', 'C the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008zi (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008zi values (79, 'C the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- The helpers are dropped first, so the verdict is the last thing the script prints
drop function if exists pg_temp.v0008zi_code(text);
drop function if exists pg_temp.v0008zi_best_ms(text, integer);
drop function if exists pg_temp.v0008zi_stage(text, integer);
drop function if exists pg_temp.v0008zi_counts(jsonb);
drop function if exists pg_temp.v0008zi_cells(jsonb);

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008zi
      union all
      select 99, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008zi where result = 'ok') = 25
                       and not exists (select 1 from verify_0008zi where result <> 'ok') then '0008zi verified'
                  else 'FAIL' end,
             format('113_verify_assets: %s ok, %s FAIL', (select count(*) from verify_0008zi where result = 'ok'),
                                                        (select count(*) from verify_0008zi where result <> 'ok'))) x
order by ord;
reset role;
