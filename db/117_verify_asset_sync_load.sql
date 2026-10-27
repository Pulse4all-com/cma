-- =============================================================================================
-- 117_verify_asset_sync_load.sql: verifies addition 0008zk, the device load set-based and the ingest's load in parts
-- =============================================================================================
-- Universal: no seed is assumed. Block A checks structure and privileges; blocks B and C work on throwaway tenants
-- inside subtransactions that are always rolled back, so nothing stays (as 113 and 115) and the script runs in dev and in
-- prod. Adapters, models, statuses, devices, serials, customers, people and secret names are invented data values, and
-- no row carries a name of a customer, an address, an email or a phone number. Every check writes one row, ok or FAIL,
-- and the last row is the verdict (0008zk verified), because Cloud SQL Studio shows no notices. Run as your own IAM
-- login after 116_asset_sync_load.sql, dev first, then prod; then 115_verify_asset_sync.sql and 113_verify_assets.sql
-- again (the load they prove is the one 116 makes again).
--   A  structure and privileges: the addition row after 0008zj; the load's row types and the staging trigger; every
--      function the application's only and in the caller's rights, the trigger function nobody's, the load set-based in
--      one place (no row loop, no row lock, no helper with a subtransaction); the setting assets_load_chunk by form; the
--      value checks reading as 0008zi's helpers read (pure)
--   B  behaviour, on two throwaway tenants, each with its Ingest user and an asset register connection with a token
--      secret name; tenant one also holds a second such connection, one without a token secret name and a CRM
--      connection. A register of 10,000 records is loaded the same way into both of tenant one's connections; then the
--      night's full snapshot (9,000 of them, 1,440 changed, 360 with a replaced pads serial, and 1,000 new; 1,000 gone)
--      is loaded into one connection in one call (staged) and into the other in ten parts of 1,000 and the final
--      missing-marking: the same counts and the same devices and components. Then: a rerun of the same parts and the
--      final call changes nothing; a run that fails before its final call marks nothing missing, and its parts already
--      loaded are unchanged on the rerun; a part with a bad row loads nothing; row-level security across the two
--      tenants' Ingest users; the refusals; the run's phase times and the setting
--   C  speed (verify.max_ms 3000 ms, a fifth of the ingest's 15-second statement timeout): on a throwaway tenant with
--      10,000 devices, one part of 1,000 unchanged rows, and the final missing-marking over the run's 9,900 record ids,
--      each under verify.max_ms. Then 115's C1 again (a full snapshot of 5,000 unchanged records staged and loaded in
--      one call as the Ingest user, the register loaded as 115 loads it) under verify.max_one_call_ms (115's 10000 ms),
--      its detail the phase times: the staging insert, then the load's stage_ms, map_ms, upsert_ms, components_ms,
--      missing_ms and cleanup_ms
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
select set_config('verify.provoke', 'false', false);           -- 'true' to make every check fail
select set_config('verify.max_ms', '3000', false);             -- one part of 1,000 rows; the final missing-marking
select set_config('verify.max_one_call_ms', '10000', false);   -- 115's C1: 5,000 records staged and loaded in one call

drop table if exists pg_temp.verify_0008zk;
create temp table verify_0008zk (ord int, check_name text, result text, detail text);

-- The error code a statement raises, or 'ok'
create or replace function pg_temp.v0008zk_code(p_sql text)
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

-- The error a statement raises as code: message, or 'ok'
create or replace function pg_temp.v0008zk_error(p_sql text)
returns text
language plpgsql
as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end
$$;

-- The scenario's register: records p_from to p_to, every value text as the ingest reads it, line g + 1. The night
-- (p_night) changes a subscription reference of every record ending in 3 (outside the stock), the pads serial of every
-- 25th from 5 on (a replacement) and the battery expiry of every 50th from 7 on. Every 500th model and every 400th
-- country is outside the catalogs, every 700th customer reference from 7 on is no reference, every 300th order
-- reference from 1 on and every 333rd named id from 2 on is dropped
create or replace function pg_temp.v0008zk_register(p_from integer, p_to integer, p_night boolean)
returns table (source_row integer, source_id text, serial text, model text, status text, country text, customer_ref text,
               subscription_ref text, order_ref text, first_shipped_on text, components text, external_refs text)
language sql
as $$
  select g + 1, 'rec-' || lpad(g::text, 6, '0'), 'SN-' || g,
         case when g % 500 = 0 then 'Model X' else 'HS1' end,
         case when g % 10 = 0 then 'In Storage' else 'Active/Customer' end,
         case when g % 400 = 0 then 'Spain' else 'Netherlands' end,
         case when g % 10 = 0 then null when g % 700 = 7 then 'cu ' || g else 'cu-' || g end,
         case when g % 10 = 0 then null else 'sub-' || g || case when p_night and g % 10 = 3 then 'b' else '' end end,
         case when g % 300 = 1 then '<o' || g || '>' else '#O' || g end,
         '2024-11-15',
         '{"pads": {"serial": "P-' || g || case when p_night and g % 25 = 5 then '-n' else '' end || '", "expires_on": "2026-12-10"}, '
           || '"battery": {"serial": "B-' || g || '", "expires_on": "' || case when p_night and g % 50 = 7 then '2027-02-20' else '2027-01-20' end || '"}}',
         case when g % 333 = 2 then '{"ns_internal_id": "' || g || '", "Bad Key": "x"}' else '{"ns_internal_id": "' || g || '"}' end
  from generate_series(p_from, p_to) g
$$;

-- The same records as one part for cma.ingest_load_device_part: a JSON array of objects, the staging's columns as keys
create or replace function pg_temp.v0008zk_part(p_from integer, p_to integer, p_night boolean)
returns jsonb
language sql
as $$
  select jsonb_agg(to_jsonb(x) order by x.source_row) from pg_temp.v0008zk_register(p_from, p_to, p_night) x
$$;

-- The same records staged for the current tenant and user, as the ingest of 0008zj staged them
create or replace function pg_temp.v0008zk_stage(p_batch text, p_ranges int4range[], p_night boolean)
returns integer
language sql
as $$
  insert into cma.device_import_staging (batch_key, source_row, source_id, serial, model, status, country, customer_ref, subscription_ref,
                                         order_ref, first_shipped_on, components, external_refs)
  select p_batch, x.source_row, x.source_id, x.serial, x.model, x.status, x.country, x.customer_ref, x.subscription_ref, x.order_ref,
         x.first_shipped_on, x.components, x.external_refs
  from unnest(p_ranges) rg, pg_temp.v0008zk_register(lower(rg), upper(rg) - 1, p_night) x;
  select count(*)::integer from cma.device_import_staging s where s.batch_key = p_batch
$$;

-- Counts summed (each key added), and a counts object as one line in a fixed order
create or replace function pg_temp.v0008zk_add(a jsonb, b jsonb)
returns jsonb
language sql
as $$
  select coalesce(jsonb_object_agg(k, coalesce((a ->> k)::numeric, 0) + coalesce((b ->> k)::numeric, 0)), '{}'::jsonb)
  from (select jsonb_object_keys(coalesce(a, '{}'::jsonb)) union select jsonb_object_keys(coalesce(b, '{}'::jsonb))) x(k)
$$;
create or replace function pg_temp.v0008zk_counts(j jsonb)
returns text
language sql
as $$
  select concat_ws(' ', 'rows=' || (j ->> 'rows'), 'ins=' || (j ->> 'inserted'), 'upd=' || (j ->> 'updated'), 'same=' || (j ->> 'unchanged'),
                   'missing=' || (j ->> 'missing_now'), 'repl=' || (j ->> 'components_replaced'), 'um=' || (j ->> 'unmapped_model'),
                   'us=' || (j ->> 'unmapped_status'), 'uk=' || (j ->> 'unmapped_market'), 'cri=' || (j ->> 'customer_ref_invalid'),
                   'drop=' || (j ->> 'refs_dropped'))
$$;

-- A connection's devices and components as one fingerprint (no id, no time; whether missing, whether current). The
-- components are joined to their devices by hashing (the throwaway tenant has no statistics yet, so a nested loop would
-- read every component once per device)
create or replace function pg_temp.v0008zk_fingerprint(p_connection_id uuid)
returns text
language sql
set enable_nestloop = off
as $$
  select md5(coalesce((select string_agg(concat_ws('|', d.source_id, d.serial, d.model_key, d.market, d.device_status_key, d.warehouse_ref,
                                                   d.customer_ref, d.customer_ref_invalid, d.subscription_ref, d.order_ref, d.first_shipped_on,
                                                   d.stock_received_on, d.last_shipped_on, d.warranty_until, d.end_of_life_on,
                                                   d.external_refs::text, d.raw::text, d.source_deleted_at is not null), ',' order by d.source_id)
                       from cma.device d where d.connection_id = p_connection_id), '')
             || '#' ||
             coalesce((select string_agg(concat_ws('|', d.source_id, c.component_key, c.serial, c.expires_on, c.replaced_at is null), ','
                                         order by d.source_id, c.component_key, c.replaced_at is null, c.serial)
                       from cma.device_component c join cma.device d on d.tenant_id = c.tenant_id and d.id = c.device_id
                       where d.connection_id = p_connection_id), ''))
$$;

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_bad     text;
  v_fn      text;
  v_def     text;
begin
  -- A1. the addition is recorded, after 0008zj
  insert into verify_0008zk values (1, 'A1 addition 0008zk recorded, after 0008zj',
    case when exists (select 1 from cma.schema_migration where version = '0008zk')
              and exists (select 1 from cma.schema_migration where version = '0008zj') and not v_provoke then 'ok' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the load's row types with their columns; the staging trigger still on the COPY target
  v_bad := '';
  if (select count(*) from pg_attribute where attrelid = (select typrelid from pg_type where oid = to_regtype('cma.device_load_row')) and attnum > 0) <> 17
     or (select count(*) from pg_attribute where attrelid = (select typrelid from pg_type where oid = to_regtype('cma.device_load_mapped')) and attnum > 0) <> 20
     or (select count(*) from pg_attribute where attrelid = (select typrelid from pg_type where oid = to_regtype('cma.device_load_component')) and attnum > 0) <> 6 then
    v_bad := v_bad || 'types; ';
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'cma.device_import_staging'::regclass and tgname = 'stage_row' and not tgisinternal) then
    v_bad := v_bad || 'staging trigger; ';
  end if;
  insert into verify_0008zk values (2, 'A2 the load''s row types; the staging trigger on the COPY target',
    case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_bad);

  -- A3. every function the application's only and in the caller's rights, the trigger function nobody's; the load in one
  --     place, set-based: no row loop, no row lock, no helper with a subtransaction, the advisory lock; the file path and
  --     the parts call it, neither writes a device
  v_bad := '';
  foreach v_fn in array array[
    'cma.device_staged_json(text)', 'cma.device_staged_date_ok(text)', 'cma.device_staged_ref(text)',
    'cma.device_rows_apply(uuid,cma.device_load_row[],boolean)', 'cma.device_snapshot_apply(text,uuid,boolean)',
    'cma.ingest_load_device_part(uuid,jsonb)', 'cma.ingest_mark_devices_missing(uuid,text[])', 'cma.assets_settings_problem(jsonb)',
    'cma.set_connection_settings(uuid,jsonb)', 'cma.ingest_sync_run_finish(uuid,text,jsonb,text)',
    'cma.load_device_snapshot(text,uuid,boolean)', 'cma.ingest_load_device_snapshot(uuid,text,boolean)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure(v_fn) and a.grantee = 0) then
      v_bad := v_bad || v_fn || '; ';
    end if;
  end loop;
  if to_regprocedure('cma.device_import_staging_insert()') is null
     or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = 'cma.device_import_staging_insert()'::regprocedure and a.grantee = 0)
     or has_function_privilege('cma_readonly', 'cma.device_import_staging_insert()', 'execute') then
    v_bad := v_bad || 'cma.device_import_staging_insert(); ';
  end if;
  if to_regprocedure('cma.device_rows_apply(uuid,cma.device_load_row[],boolean)') is not null then
    v_def := lower(pg_get_functiondef('cma.device_rows_apply(uuid,cma.device_load_row[],boolean)'::regprocedure));
    if v_def ~ '\mloop\M' or v_def like '%for update%' or v_def like '%device_staged_date(%' or v_def like '%device_staged_object(%'
       or v_def not like '%pg_advisory_xact_lock%' or v_def like '%sync_run%' then
      v_bad := v_bad || 'the load set-based; ';
    end if;
    if pg_get_functiondef('cma.device_snapshot_apply(text,uuid,boolean)'::regprocedure) not like '%cma.device_rows_apply(%'
       or pg_get_functiondef('cma.ingest_load_device_part(uuid,jsonb)'::regprocedure) not like '%cma.device_rows_apply(%'
       or pg_get_functiondef('cma.device_snapshot_apply(text,uuid,boolean)'::regprocedure) like '%cma.device %'
       or pg_get_functiondef('cma.ingest_load_device_part(uuid,jsonb)'::regprocedure) like '%cma.device %'
       or pg_get_functiondef('cma.ingest_load_device_part(uuid,jsonb)'::regprocedure) like '%device_import_%' then
      v_bad := v_bad || 'the load in one place; ';
    end if;
  end if;
  insert into verify_0008zk values (3, 'A3 every function the application''s only and invoker, the trigger function nobody''s; the load set-based in one place',
    case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_bad);

  -- A4. the setting assets_load_chunk by form: a whole number from 100 to 5,000; 0008zj's keys as before
  v_bad := concat_ws(' ',
    coalesce(cma.assets_settings_problem('{"assets_load_chunk": 1000}'), 'ok'),
    coalesce(cma.assets_settings_problem('{"assets_load_chunk": "100"}'), 'ok'),
    coalesce(cma.assets_settings_problem('{"assets_load_chunk": 5000, "assets_poll_interval_minutes": 15}'), 'ok'),
    coalesce(cma.assets_settings_problem('{"assets_load_chunk": 99}'), 'ok'),
    coalesce(cma.assets_settings_problem('{"assets_load_chunk": 5001}'), 'ok'),
    coalesce(cma.assets_settings_problem('{"assets_load_chunk": 1000.5}'), 'ok'),
    coalesce(cma.assets_settings_problem('{"assets_load_chunk": "1k"}'), 'ok'),
    coalesce(cma.assets_settings_problem('{"assets_load_chunk": true}'), 'ok'),
    coalesce(cma.assets_settings_problem('{"table_id": "tbl abc", "assets_load_chunk": 1000}'), 'ok'));
  insert into verify_0008zk values (4, 'A4 the setting assets_load_chunk by form: a whole number from 100 to 5,000',
    case when v_bad = 'ok ok ok assets_load_chunk assets_load_chunk assets_load_chunk assets_load_chunk assets_load_chunk table_id'
              and not v_provoke then 'ok' else 'FAIL' end, v_bad);

  -- A5. the value checks read as 0008zi's helpers read: a JSON object where cma.device_staged_object takes it (null
  --     where it refuses), a date where cma.device_staged_date takes it, a reference as 0008zi's pattern keeps it
  select string_agg(v.x, ',') into v_bad
  from (select coalesce(t, 'null') || '=' || case when (cma.device_staged_json(t) is null)
                                                    = (pg_temp.v0008zk_code(format('select cma.device_staged_object(%L, 2, ''c'')', t)) <> 'ok')
                                                    and (cma.device_staged_json(t) is null or cma.device_staged_json(t) = cma.device_staged_object(t, 2, 'c'))
                                                  then 'same' else 'differs' end as x
        from unnest(array[null, '', '  ', '{"a": 1}', ' {"pads": {"serial": "P"}} ', '[1]', '"x"', '12', 'nope', '{"a": 1']) t
        union all
        select coalesce(t, 'null') || '=' || case when cma.device_staged_date_ok(t)
                                                    = (pg_temp.v0008zk_code(format('select cma.device_staged_date(%L, 2, ''d'')', t)) = 'ok')
                                                  then 'same' else 'differs' end
        from unnest(array[null, '', '2028-02-29', '2026-02-29', ' 2026-01-01 ', '2026-1-01', '2026-13-01', '0000-01-01', '15/11/2024']) t
        union all
        select left(coalesce(t, 'null'), 12) || '=' || case when cma.device_staged_ref(t) is not distinct from
                                                                   (case when cma.device_staged_text(t) ~ '^[A-Za-z0-9#][A-Za-z0-9 _.#:/-]{0,99}$'
                                                                         then cma.device_staged_text(t) end)
                                                             then 'same' else 'differs' end
        from unnest(array[null, '', 'SN-1', ' SN 1 ', '#O1', '-x', 'a@b', '<o1>', 'é1', repeat('a', 100), repeat('a', 101),
                          '#' || repeat('b', 99), 'a/b:c.d_e#f']) t) v;
  insert into verify_0008zk values (5, 'A5 the value checks read as 0008zi''s helpers: JSON objects, dates, references',
    case when v_bad not like '%differs%' and not v_provoke then 'ok' else 'FAIL' end,
    case when v_bad like '%differs%' then v_bad else 'every sample the same' end);
end
$$;

-- B. Behaviour on two throwaway tenants (rolled back)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  v_t1 uuid; v_t2 uuid;
  v_admin1 uuid; v_ing1 uuid; v_ing2 uuid;
  v_one uuid; v_parts uuid; v_csv uuid; v_crm uuid; v_reg2 uuid;
  v_run uuid;
  v_txt text;
  v_fp text;
  v_n integer;
  v_ids text[];
  j jsonb;
  k jsonb;
  v_expect constant text := 'rows=10000 ins=1000 upd=1440 same=7560 missing=1000 repl=360 um=20 us=0 uk=24 cri=14 drop=64';
begin
  begin
    -- tenants (each with its Ingest user), a person and connections (as the owner)
    v_t1 := cma.create_tenant('verify-0008zk-one', 'Verify 0008zk one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008zk-two', 'Verify 0008zk two', 'Europe/Amsterdam');
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest' and x.external_id = 'ingest';
    select x.user_id into v_ing2 from cma.app_user_external_id x where x.tenant_id = v_t2 and x.system = 'ingest' and x.external_id = 'ingest';
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin-zk1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.user_role (tenant_id, user_id, role_id) select v_t1, v_admin1, ar.id from cma.app_role ar where ar.tenant_id = v_t1 and ar.key = 'admin';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t1, 'verifyregister', 'Verify register one call', 'base-one', 'assets', 'verify-register-token-one') returning id into v_one;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t1, 'verifyregister', 'Verify register parts', 'base-parts', 'assets', 'verify-register-token-parts') returning id into v_parts;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifyregister', 'Verify register from files', 'base-csv', 'assets') returning id into v_csv;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t1, 'verifycrm', 'Verify CRM', 'portal-1', 'crm', 'verify-crm-token-1') returning id into v_crm;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t2, 'verifyregister', 'Verify register two', 'base-two', 'assets', 'verify-register-token-two') returning id into v_reg2;
    perform set_config('role', 'cma_app', true);

    -- each tenant's catalogs (its admin, or for tenant two its Ingest user's tenant as the owner wrote them)
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR', null, null, 20);
    perform cma.set_market_alias('netherlands', 'NL');
    insert into cma.device_model (key, name, aliases) values ('hs1', 'HS1', array['hs1']);
    insert into cma.device_component_kind (key, name, sort_order) values ('pads', 'Pads', 10), ('battery', 'Battery', 20);
    insert into cma.device_status (key, name, is_in_field, is_in_stock, is_tracked, aliases, sort_order) values
      ('active_customer', 'Active/Customer', true, false, true, array['active/customer'], 10),
      ('in_storage', 'In Storage', false, true, true, array['in storage'], 20);
    perform set_config('role', 'cma_owner', true);
    insert into cma.device_component_kind (tenant_id, key, name, sort_order) values (v_t2, 'pads', 'Pads', 10), (v_t2, 'battery', 'Battery', 20);
    perform set_config('role', 'cma_app', true);

    -- B1. tenant one's Ingest user loads the register's 10,000 records into both connections the same way (parts of
    --     1,000); then the night's full snapshot into one connection in one call (staged) and into the other in ten
    --     parts of 1,000 and the final missing-marking: the same counts, the same devices and components
    perform set_config('app.user_id', v_ing1::text, true);
    for p in 0 .. 9 loop
      perform cma.ingest_load_device_part(v_one, pg_temp.v0008zk_part(p * 1000 + 1, p * 1000 + 1000, false));
      perform cma.ingest_load_device_part(v_parts, pg_temp.v0008zk_part(p * 1000 + 1, p * 1000 + 1000, false));
    end loop;
    v_txt := (pg_temp.v0008zk_fingerprint(v_one) = pg_temp.v0008zk_fingerprint(v_parts))::text;
    v_n := pg_temp.v0008zk_stage('night-one', array[int4range(1, 9001), int4range(10001, 11001)], true);
    j := cma.ingest_load_device_snapshot(v_one, 'night-one', true);
    k := '{}'::jsonb;
    v_ids := '{}';
    for p in 0 .. 9 loop
      -- the night's rows in id order, a thousand a part: records 1 to 9,000, then 10,001 to 11,000
      k := pg_temp.v0008zk_add(k, cma.ingest_load_device_part(v_parts,
             case when p < 9 then pg_temp.v0008zk_part(p * 1000 + 1, p * 1000 + 1000, true) else pg_temp.v0008zk_part(10001, 11000, true) end));
    end loop;
    select array_agg(x.source_id) into v_ids
    from (select r.source_id from pg_temp.v0008zk_register(1, 9000, true) r union all select r.source_id from pg_temp.v0008zk_register(10001, 11000, true) r) x;
    k := pg_temp.v0008zk_add(k, cma.ingest_mark_devices_missing(v_parts, v_ids));
    v_txt := v_txt || ' ' || v_n || ' ' || pg_temp.v0008zk_counts(j) || ' | ' || pg_temp.v0008zk_counts(k)
             || ' ' || (pg_temp.v0008zk_fingerprint(v_one) = pg_temp.v0008zk_fingerprint(v_parts))::text
             || ' ' || (select count(*) from cma.device_import_staging);
    v_rows := v_rows || array['11', 'B1 the night''s full snapshot of 10,000 in ten parts and the final call: the same counts, devices and components as one call',
      case when v_txt = 'true 10000 ' || v_expect || ' | ' || v_expect || ' true 0' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B2. a rerun of the same parts and the final call: every row unchanged, nothing marked, the devices as they were
    v_fp := pg_temp.v0008zk_fingerprint(v_parts);
    k := '{}'::jsonb;
    for p in 0 .. 9 loop
      k := pg_temp.v0008zk_add(k, cma.ingest_load_device_part(v_parts,
             case when p < 9 then pg_temp.v0008zk_part(p * 1000 + 1, p * 1000 + 1000, true) else pg_temp.v0008zk_part(10001, 11000, true) end));
    end loop;
    k := pg_temp.v0008zk_add(k, cma.ingest_mark_devices_missing(v_parts, v_ids));
    v_txt := pg_temp.v0008zk_counts(k) || ' ' || (pg_temp.v0008zk_fingerprint(v_parts) = v_fp)::text;
    v_rows := v_rows || array['12', 'B2 a rerun of the same parts and the final call changes nothing',
      case when v_txt = 'rows=10000 ins=0 upd=0 same=10000 missing=0 repl=0 um=20 us=0 uk=24 cri=14 drop=64 true' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B3. a run that fails before its final call (records 1 to 8,000 read, four parts loaded, then the failure) marks
    --     nothing missing; the rerun reloads those four parts unchanged and its final call marks the 2,000 it did not read
    --     (8,001 to 9,000 and 10,001 to 11,000); a part with a bad row loads nothing of the part
    v_n := (select count(*) from cma.device d where d.connection_id = v_parts and d.source_deleted_at is not null);
    for p in 0 .. 3 loop
      perform cma.ingest_load_device_part(v_parts, pg_temp.v0008zk_part(p * 1000 + 1, p * 1000 + 1000, true));
    end loop;
    v_txt := v_n || ' ' || (select count(*) from cma.device d where d.connection_id = v_parts and d.source_deleted_at is not null);
    k := '{}'::jsonb;
    for p in 0 .. 7 loop
      j := cma.ingest_load_device_part(v_parts, pg_temp.v0008zk_part(p * 1000 + 1, p * 1000 + 1000, true));
      if p < 4 then
        k := pg_temp.v0008zk_add(k, j);
      end if;
    end loop;
    v_txt := v_txt || ' ' || pg_temp.v0008zk_counts(k);
    j := cma.ingest_mark_devices_missing(v_parts, (select array_agg(r.source_id) from pg_temp.v0008zk_register(1, 8000, true) r));
    v_txt := v_txt || ' ' || (j ->> 'missing_now') || ' ' || (select count(*) from cma.device d where d.connection_id = v_parts and d.source_deleted_at is not null);
    -- a part whose 500th row holds no date: refused, naming the line, and nothing of the part written
    v_fp := pg_temp.v0008zk_fingerprint(v_parts);
    v_txt := v_txt || ' | ' || pg_temp.v0008zk_error(format('select cma.ingest_load_device_part(%L, %L)', v_parts,
               (select jsonb_agg(case when (e ->> 'source_row')::integer = 501 then e || '{"first_shipped_on": "15/11/2024"}'::jsonb
                                      else e || '{"subscription_ref": "sub-changed"}'::jsonb end)
                from jsonb_array_elements(pg_temp.v0008zk_part(1, 1000, true)) e)))
             || ' ' || (pg_temp.v0008zk_fingerprint(v_parts) = v_fp)::text;
    v_rows := v_rows || array['13', 'B3 a run that fails before its final call marks nothing missing; the rerun''s parts unchanged; a part with a bad row loads nothing',
      case when v_txt = '1000 1000 rows=4000 ins=0 upd=0 same=4000 missing=0 repl=0 um=8 us=0 uk=10 cri=6 drop=27 2000 3000 '
                        || '| CMA04: line 501: first_shipped_on is not a date as YYYY-MM-DD true'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B4. row-level security: tenant two's Ingest user finds neither of tenant one's connections (CMA02) and loads its
    --     own; each tenant sees its own devices only; tenant two's final call leaves tenant one's devices as they were
    v_fp := pg_temp.v0008zk_fingerprint(v_parts);
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_ing2::text, true);
    v_txt := pg_temp.v0008zk_code(format('select cma.ingest_load_device_part(%L, %L)', v_parts, pg_temp.v0008zk_part(1, 3, false)))
             || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_mark_devices_missing(%L, %L)', v_parts, array['rec-000001']));
    j := cma.ingest_load_device_part(v_reg2, pg_temp.v0008zk_part(1, 3, false));
    k := cma.ingest_mark_devices_missing(v_reg2, array['rec-000001', 'rec-000002']);
    v_txt := v_txt || ' ' || pg_temp.v0008zk_counts(j) || ' ' || (k ->> 'missing_now')
             || ' ' || (select count(*) from cma.device) || '/' || (select count(*) from cma.device_component)
             || ' ' || (select count(*) from cma.device d where d.connection_id = v_parts);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_ing1::text, true);
    v_txt := v_txt || ' ' || (select count(*) from cma.device d where d.connection_id = v_reg2)
             || ' ' || (pg_temp.v0008zk_fingerprint(v_parts) = v_fp)::text;
    v_rows := v_rows || array['14', 'B4 row-level security: each Ingest user loads, marks and sees its own tenant only',
      case when v_txt = 'CMA02 CMA02 rows=3 ins=3 upd=0 same=0 missing=0 repl=0 um=3 us=3 uk=3 cri=0 drop=2 1 3/6 0 0 true'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B5. the refusals: a person (CMA06); a connection without a token secret name, a CRM connection (CMA04); a part
    --     that is no array, empty, over 5,000 rows, a row no object, a key outside the staging's columns, a line outside
    --     2 to 10,000,000 or no number, a value longer than the staging takes, a record id twice, a row without one;
    --     the final call without record ids or with a null among them (CMA04). An address is kept nowhere: a bare @
    v_txt := pg_temp.v0008zk_code(format('select cma.ingest_load_device_part(%L, %L)', v_csv, pg_temp.v0008zk_part(1, 2, false)))
      || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_mark_devices_missing(%L, %L)', v_csv, array['rec-000001']))
      || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_load_device_part(%L, %L)', v_crm, pg_temp.v0008zk_part(1, 2, false)))
      || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_mark_devices_missing(%L, %L)', v_crm, array['rec-000001']))
      || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_load_device_part(%L, %L)', v_parts, '{"source_id": "rec-1"}'))
      || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_load_device_part(%L, %L)', v_parts, '[]'))
      || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_load_device_part(%L, %L)', v_parts,
                  (select jsonb_agg(jsonb_build_object('source_id', 'rec-' || g)) from generate_series(1, 5001) g)))
      || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_load_device_part(%L, %L)', v_parts, '[{"source_id": "rec-1"}, "rec-2"]'))
      || ' ' || pg_temp.v0008zk_error(format('select cma.ingest_load_device_part(%L, %L)', v_parts, '[{"source_id": "rec-1", "serial_number": "SN-1"}]'))
      || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_load_device_part(%L, %L)', v_parts, '[{"source_row": 1, "source_id": "rec-1"}]'))
      || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_load_device_part(%L, %L)', v_parts, '[{"source_row": "3", "source_id": "rec-1"}]'))
      || ' ' || pg_temp.v0008zk_error(format('select cma.ingest_load_device_part(%L, %L)', v_parts,
                  jsonb_build_array(jsonb_build_object('source_row', 4, 'source_id', 'rec-1', 'serial', repeat('s', 501)))))
      || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_load_device_part(%L, %L)', v_parts,
                  '[{"source_row": 2, "source_id": "rec-1"}, {"source_row": 3, "source_id": "rec-1"}]'))
      || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_load_device_part(%L, %L)', v_parts, '[{"source_row": 2, "serial": "SN-1"}]'))
      || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_mark_devices_missing(%L, %L)', v_parts, '{}'::text[]))
      || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_mark_devices_missing(%L, %L)', v_parts, array['rec-000001', null]));
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := v_txt
      || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_load_device_part(%L, %L)', v_parts, pg_temp.v0008zk_part(1, 2, false)))
      || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_mark_devices_missing(%L, %L)', v_parts, array['rec-000001']));
    perform set_config('app.user_id', v_ing1::text, true);
    j := cma.ingest_load_device_part(v_parts, jsonb_build_array(jsonb_build_object(
           'source_row', 2, 'source_id', 'rec-at', 'serial', 'verify-serial@example.invalid', 'customer_ref', 'verify-customer@example.invalid',
           'components', '{"pads": {"serial": "verify-pads@example.invalid", "expires_on": "2027-01-01"}}',
           'external_refs', '{"ns_internal_id": "verify-ref@example.invalid"}')));
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || ' | ' || pg_temp.v0008zk_counts(j)
             || ' ' || (select count(*) from cma.device d where d.tenant_id = v_t1 and (d::text like '%example%' or d.raw::text like '%example%'))
             || '/' || (select count(*) from cma.device_component c where c.tenant_id = v_t1 and c::text like '%example%')
             || '/' || (select count(*) from cma.device_import_row s where s.tenant_id = v_t1)
             || ' ' || (select coalesce(d.serial, '-') || ':' || coalesce(d.customer_ref, '-') || ':' || d.customer_ref_invalid::text
                        from cma.device d where d.tenant_id = v_t1 and d.source_id = 'rec-at');
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['15', 'B5 the refusals: a person, a file-only and a CRM connection, a part out of its form, a final call without ids; an address a bare @',
      case when v_txt = 'CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 '
                        || 'CMA04: a part''s rows hold the staging''s columns only, not serial_number CMA04 CMA04 '
                        || 'CMA04: line 4: serial is longer than the staging takes CMA04 CMA04 CMA04 CMA04 CMA06 CMA06 '
                        || '| rows=1 ins=1 upd=0 same=0 missing=0 repl=0 um=1 us=1 uk=1 cri=1 drop=3 0/0/0 -:-:true'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B6. the run's counts take the phase times; another key is still refused (CMA04); the setting assets_load_chunk set
    --     by form on the register (CMA04 out of it), not checked on a CRM connection
    v_run := cma.ingest_sync_run_start(v_parts, 'assets_poll', 'devices', null, null);
    v_txt := pg_temp.v0008zk_code(format('select cma.ingest_sync_run_finish(%L, ''succeeded'', %L)', v_run,
               '{"fetched": 2, "rows": 2, "inserted": 1, "updated": 1, "unchanged": 0, "missing_now": 0, "stage_ms": 3, "map_ms": 12, '
               || '"upsert_ms": 4, "components_ms": 5, "missing_ms": 6, "cleanup_ms": 0}'));
    v_txt := v_txt || ' ' || (select (r.counts ->> 'map_ms') || '/' || (r.counts ->> 'missing_ms') from cma.sync_run r where r.id = v_run)
             || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_sync_run_finish(cma.ingest_sync_run_start(%L, ''assets_poll'', ''devices'', null, null), '
                                                   || '''succeeded'', ''{"fetched": 1, "load_ms": 1}'')', v_parts));
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := v_txt
      || ' ' || pg_temp.v0008zk_code(format('select cma.set_connection_settings(%L, %L)', v_parts, '{"table_id": "tblVerify0001", "assets_load_chunk": 1000}'))
      || ' ' || pg_temp.v0008zk_code(format('select cma.set_connection_settings(%L, %L)', v_parts, '{"assets_load_chunk": 50}'))
      || ' ' || pg_temp.v0008zk_code(format('select cma.set_connection_settings(%L, %L)', v_crm, '{"assets_load_chunk": 50}'));
    v_txt := v_txt || ' ' || (select c.settings ->> 'assets_load_chunk' from cma.integration_connection c where c.id = v_parts);
    v_rows := v_rows || array['16', 'B6 the run''s counts take the phase times, another key refused; the setting assets_load_chunk by form',
      case when v_txt = 'ok 12/6 CMA04 ok CMA04 ok 1000' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['49', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008zk (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008zk values (49, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- C. Speed: one part of 1,000 unchanged rows and the final missing-marking over 10,000 devices (rolled back)
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
    v_t := cma.create_tenant('verify-0008zk-volume', 'Verify 0008zk volume', 'Europe/Amsterdam');
    select x.user_id into v_ing from cma.app_user_external_id x where x.tenant_id = v_t and x.system = 'ingest' and x.external_id = 'ingest';
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-admin-zk-volume@example.invalid', 'admin') returning id into v_admin;
    insert into cma.user_role (tenant_id, user_id, role_id) select v_t, v_admin, ar.id from cma.app_role ar where ar.tenant_id = v_t and ar.key = 'admin';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t, 'verifyregister', 'Verify register volume', 'base-zk-v', 'assets', 'verify-register-token-zk-v') returning id into v_reg;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR', null, null, 20);
    perform cma.set_market_alias('netherlands', 'NL');
    insert into cma.device_model (key, name, aliases) values ('hs1', 'HS1', array['hs1']);
    insert into cma.device_component_kind (key, name, sort_order) values ('pads', 'Pads', 10), ('battery', 'Battery', 20);
    insert into cma.device_status (key, name, is_in_field, is_in_stock, is_tracked, aliases, sort_order) values
      ('active_customer', 'Active/Customer', true, false, true, array['active/customer'], 10),
      ('in_storage', 'In Storage', false, true, true, array['in storage'], 20);
    perform set_config('app.user_id', v_ing::text, true);
    -- the register as the mirror holds it after earlier nights: 10,000 records loaded in parts of 1,000, the tables'
    -- statistics read after each (as autovacuum keeps them in a database that holds the devices)
    for p in 0 .. 9 loop
      perform cma.ingest_load_device_part(v_reg, pg_temp.v0008zk_part(p * 1000 + 1, p * 1000 + 1000, false));
      perform set_config('role', 'cma_owner', true);
      analyze cma.device;
      analyze cma.device_component;
      perform set_config('role', 'cma_app', true);
    end loop;

    -- C1. one part of 1,000 unchanged rows (records 4,001 to 5,000), its phase times in the detail
    v_t0 := clock_timestamp();
    j := cma.ingest_load_device_part(v_reg, pg_temp.v0008zk_part(4001, 5000, false));
    v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
    v_rows := v_rows || array['51', 'C1 one part of 1,000 unchanged rows as the Ingest user, under verify.max_ms',
      case when v_ms < v_max and pg_temp.v0008zk_counts(j) = 'rows=1000 ins=0 upd=0 same=1000 missing=0 repl=0 um=2 us=0 uk=2 cri=2 drop=6'
                and not v_provoke then 'ok' else 'FAIL' end,
      format('%s ms (budget %s), stage %s, map %s, upsert %s, components %s; %s', v_ms, v_max, j ->> 'stage_ms', j ->> 'map_ms',
             j ->> 'upsert_ms', j ->> 'components_ms', pg_temp.v0008zk_counts(j))];

    -- C2. the final missing-marking over the run's 9,900 record ids: the other 100 marked
    v_t0 := clock_timestamp();
    j := cma.ingest_mark_devices_missing(v_reg, (select array_agg(r.source_id) from pg_temp.v0008zk_register(1, 9900, false) r));
    v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
    v_rows := v_rows || array['52', 'C2 the final missing-marking over 9,900 record ids of 10,000 devices as the Ingest user, under verify.max_ms',
      case when v_ms < v_max and j ->> 'missing_now' = '100' and not v_provoke then 'ok' else 'FAIL' end,
      format('%s ms (budget %s), missing %s ms; missing_now=%s', v_ms, v_max, j ->> 'missing_ms', j ->> 'missing_now')];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['78', 'C the parts'' block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008zk (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008zk values (78, 'C the parts'' block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- C3. 115's C1 again, with its phases: a throwaway tenant with 5,000 devices loaded as 115 loads them (staged in parts
--     of 500, the statistics read after each), then a nightly full snapshot of them all, unchanged, staged and loaded in
--     one call as the Ingest user (rolled back)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_max     numeric := current_setting('verify.max_one_call_ms')::numeric;
  v_rows    text[] := '{}';
  v_t uuid; v_admin uuid; v_ing uuid; v_reg uuid;
  v_t0 timestamptz;
  v_stage numeric;
  v_ms numeric;
  j jsonb;
begin
  begin
    v_t := cma.create_tenant('verify-0008zk-one-call', 'Verify 0008zk one call', 'Europe/Amsterdam');
    select x.user_id into v_ing from cma.app_user_external_id x where x.tenant_id = v_t and x.system = 'ingest' and x.external_id = 'ingest';
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-admin-zk-one-call@example.invalid', 'admin') returning id into v_admin;
    insert into cma.user_role (tenant_id, user_id, role_id) select v_t, v_admin, ar.id from cma.app_role ar where ar.tenant_id = v_t and ar.key = 'admin';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t, 'verifyregister', 'Verify register one call', 'base-zk-c', 'assets', 'verify-register-token-zk-c') returning id into v_reg;
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
    v_t0 := clock_timestamp();
    insert into cma.device_import_staging (batch_key, source_row, source_id, serial, model, status, country, customer_ref, subscription_ref,
                                           first_shipped_on, components, external_refs)
    select 'volume-night', g + 1, 'rec-' || g, 'SN-' || g, 'HS1', 'Active/Customer', 'Netherlands', 'cu-' || g, 'sub-' || g, '2024-11-15',
           '{"pads": {"serial": "P-' || g || '", "expires_on": "2026-12-10"}, "battery": {"serial": "B-' || g || '", "expires_on": "2027-01-20"}}',
           '{"ns_internal_id": "' || g || '"}'
    from generate_series(1, 5000) g;
    v_stage := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
    j := cma.ingest_load_device_snapshot(v_reg, 'volume-night', true);
    v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
    v_rows := v_rows || array['53', 'C3 115''s C1 again: a full snapshot of 5,000 unchanged records staged and loaded in one call, under verify.max_one_call_ms, its phases',
      case when v_ms < v_max and pg_temp.v0008zk_counts(j) = 'rows=5000 ins=0 upd=0 same=5000 missing=0 repl=0 um=0 us=0 uk=0 cri=0 drop=0'
                and not v_provoke then 'ok' else 'FAIL' end,
      format('%s ms (budget %s): staging insert %s; load: stage %s, map %s, upsert %s, components %s, missing %s, cleanup %s; %s',
             v_ms, v_max, v_stage, j ->> 'stage_ms', j ->> 'map_ms', j ->> 'upsert_ms', j ->> 'components_ms', j ->> 'missing_ms',
             j ->> 'cleanup_ms', pg_temp.v0008zk_counts(j))];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['79', 'C the one call''s block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008zk (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008zk values (79, 'C the one call''s block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- The helpers are dropped first, so the verdict is the last thing the script prints
drop function if exists pg_temp.v0008zk_code(text);
drop function if exists pg_temp.v0008zk_error(text);
drop function if exists pg_temp.v0008zk_stage(text, int4range[], boolean);
drop function if exists pg_temp.v0008zk_part(integer, integer, boolean);
drop function if exists pg_temp.v0008zk_register(integer, integer, boolean);
drop function if exists pg_temp.v0008zk_add(jsonb, jsonb);
drop function if exists pg_temp.v0008zk_counts(jsonb);
drop function if exists pg_temp.v0008zk_fingerprint(uuid);

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008zk
      union all
      select 99, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008zk where result = 'ok') = 14
                       and not exists (select 1 from verify_0008zk where result <> 'ok') then '0008zk verified'
                  else 'FAIL' end,
             format('117_verify_asset_sync_load: %s ok, %s FAIL', (select count(*) from verify_0008zk where result = 'ok'),
                                                                (select count(*) from verify_0008zk where result <> 'ok'))) x
order by ord;
reset role;
