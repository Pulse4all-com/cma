-- =============================================================================================
-- 189_verify_fleet_management.sql: verifies addition 0009t, Assets → Fleet management (postcode areas, dummy locations
-- and monitoring states behind fleet_management.dummy_preview)
-- =============================================================================================
-- Universal: no seed is assumed, so it runs in dev and in prod. Two kinds of checks:
--   on two throwaway tenants (T, U): a register of invented devices (serials VF-1 to VF-80, invented markets GB, NL and
--     LU, the last without a postcode area; no person's data), a maintenance rule that puts some of them past due, three
--     readers (an agent, an analyst, a supervisor); the whole step is rolled back;
--   on every active tenant whose register is set up (R, E): the page's reads against Installed base's own figures, the
--     dummy's rules computed again here, and the budgets, as the application (cma_app, row-level security on), in a step
--     that is always rolled back. Its dummy_preview is not needed: the _of functions are read directly.
-- Run as your own IAM login, after 188. Output: tenant slugs, market codes, model keys, counts and milliseconds only.
--
-- Checks (the brief's 1 to 8)
--   S1  the addition is recorded after 0009r; the setting fleet_management.dummy_preview, a boolean, default false
--   S2  cma.postcode_area: no tenant_id, no row-level security; the application reads and never writes it, the readers
--       never see it; every area code at most four letters or digits, of a two-letter country (never UK); the sample's
--       rows present
--   S3  the functions: cma_owner's, the application's to execute (not public's, not the readers'), in the caller's rights,
--       JIT off on the four reads
--   S4  (5) no result column of cma.fleet_areas_of or cma.fleet_rows_of matches the personal-column pattern (113's and
--       123's, with customer and a bare name); no cma_read view or function reads cma.postcode_area or a fleet function
--   A1  (1, 2) by hand on T: In the field per market and model from cma.fleet_areas_of (summed) equals Installed base's
--       (cma.flash_compute_of's take rows) and past_due summed its Devices past due (cma.flash_rows_of, components_past_due),
--       for every filter: none, each market, each model, each market and model; and the figures counted by hand
--   A2  (3) on T: every device In the field of GB or NL has exactly one area, of its own market, the one the weighted hash
--       picks (computed again here, one area at a time); LU's and the market-less devices have none and count in the row
--       without an area; a device not In the field has no area and no state; the state is the hash's bucket; two reads
--       give the same area and state per device; a register's reload (the device's row updated) keeps both
--   A3  (4) on T: Ready + Needs attention + No connection + Not monitored = In the field in every row
--   A4  (6) the analyst (reports.view) and the supervisor (performance.team) read both, the agent is refused (CMA06);
--       under U's context T's devices are not read (row-level security), and U's reader sees U's device alone
--   A5  (7) with dummy_preview false both reads answer {"set_up": false} and nothing more; with it true they answer
--   A6  the reads refuse a malformed market, model, state or page (CMA04); the list's pages: 50 a page, the total, the
--       order (Needs attention, No connection, past due, then serial), the attention filter, the state filters adding up
--   R1  (1) per tenant: In the field from cma.fleet_areas_of equals Installed base's, for every filter
--   R2  (2) per tenant: past_due summed equals Installed base's Devices past due, for every filter
--   R3  (3) per tenant: every device In the field of a market with areas has exactly one, of its market, the hash's pick;
--       the state the hash's bucket; two reads the same
--   R4  (4) per tenant: the states add up to In the field in every row
--   E1  (8) per tenant, as cma_app: cma.fleet_areas_of, no filter, within verify.max_list_ms (300), the best of three
--       after six calls
--   E2  (8) per tenant, as cma_app: cma.fleet_rows_of, the devices that need attention, page 1, within verify.max_list_ms
-- Provoke: verify.provoke below. 'true': every check reads FAIL and the verdict says PROVOKED, NOT A PASS. A check's id:
-- that check alone compares with a deliberate difference.
-- Collation: every ordering that feeds a compared text says collate "C".
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);                 -- 'true' for every check, or one check's id such as 'A2'
select set_config('verify.max_list_ms', '300', false);               -- the page's two reads (the brief's budget)

drop table if exists pg_temp.verify_0009t;
create temporary table verify_0009t (ord integer, check_name text, result text, detail text);
grant select, insert on pg_temp.verify_0009t to cma_app;

create or replace function pg_temp.v0009t_p(p_id text)
returns boolean
language sql stable
as $$
  select current_setting('verify.provoke') in ('true', p_id)
$$;

-- One check's row: PASS when what was found equals what is expected; provoked, the expectation carries a deliberate difference
create or replace function pg_temp.v0009t_row(p_ord integer, p_id text, p_name text, p_found text, p_expected text)
returns void
language plpgsql
as $$
declare
  v_exp text := case when pg_temp.v0009t_p(p_id) then coalesce(p_expected, '') || ' [provoked: a deliberate difference]' else p_expected end;
begin
  insert into pg_temp.verify_0009t values (p_ord, p_id || ' ' || p_name,
    case when p_found is not distinct from v_exp then 'PASS' else 'FAIL' end,
    case when p_found is not distinct from v_exp then left(coalesce(p_found, 'null'), 600)
         else left('found ' || coalesce(p_found, 'null') || ' | expected ' || coalesce(v_exp, 'null'), 2400) end);
end
$$;

-- The error code a statement raises, or 'ok'
create or replace function pg_temp.v0009t_code(p_sql text)
returns text
language plpgsql
as $$
begin
  execute p_sql;
  return 'ok';
exception
  when others then return sqlstate;
end
$$;

-- D4 computed again, one area at a time: the device's market's areas in area-code order ("C"), each taking its weight
-- of 0 to the market's total; the hash's place in that range picks the area. Null where the market has no area
create or replace function pg_temp.v0009t_pick(p_device uuid, p_market text)
returns uuid
language plpgsql stable
as $$
declare
  h     bigint := hashtextextended(p_device::text || ':fleet-area-v1', 0);
  v_tot bigint;
  v_u   bigint;
  v_acc bigint := 0;
  r     record;
begin
  select sum(pa.weight) into v_tot from cma.postcode_area pa where pa.country = p_market;
  if v_tot is null then
    return null;
  end if;
  v_u := ((h % v_tot) + v_tot) % v_tot;
  for r in select pa.id, pa.weight from cma.postcode_area pa where pa.country = p_market order by pa.area_code collate "C" loop
    v_acc := v_acc + r.weight;
    if v_u < v_acc then
      return r.id;
    end if;
  end loop;
  return null;
end
$$;

-- D5 computed again: the hash mod 1000 in its four buckets
create or replace function pg_temp.v0009t_state(p_device uuid)
returns text
language sql immutable
as $$
  select case when k < 370 then 'not_monitored' when k < 392 then 'needs_attention' when k < 424 then 'no_connection' else 'ready' end
  from (select ((hashtextextended(p_device::text || ':fleet-state-v1', 0) % 1000) + 1000) % 1000 as k) x
$$;

-- Checks 1 and 2 for a tenant, every filter: none, each market, each model, each market and model of the devices the
-- page counts. Installed base's In the field from its take's rows (cma.flash_compute_of, the set that carries market and
-- model), its Devices past due from its list (cma.flash_rows_of, components_past_due: the list's total); Fleet
-- management's from cma.fleet_areas_of summed. Answers the filters compared and those that differ (field, past due)
create or replace function pg_temp.v0009t_compare(p_tenant uuid)
returns table (filters integer, field_differs text, past_due_differs text)
language plpgsql
as $$
declare
  f        record;
  v_ib     jsonb;
  v_n      integer := 0;
  v_field  text := '';
  v_due    text := '';
  v_ib_f   bigint;
  v_ib_d   bigint;
  v_fl_f   bigint;
  v_fl_d   bigint;
begin
  -- the take's rows of the set (market, status, model, warehouse, link): each in-field device in exactly one
  select coalesce(jsonb_agg(jsonb_build_object('market', c.dims ->> 'market', 'model', c.dims ->> 'model', 'in_field', (c.measures ->> 'in_field')::bigint)), '[]'::jsonb)
  into v_ib
  from cma.flash_compute_of(p_tenant, 'installed_base') c
  where c.dims ? 'status';
  for f in
    with p as (select distinct x.market, x.model from cma.fleet_devices_of(p_tenant, cma.tenant_today_of(p_tenant)) x)
    select q.market, q.model
    from (select null::text as market, null::text as model
          union select p.market, null from p
          union select null, p.model from p
          union select p.market, p.model from p) q
    order by q.market collate "C" nulls first, q.model collate "C" nulls first
  loop
    v_n := v_n + 1;
    select coalesce(sum((e ->> 'in_field')::bigint), 0) into v_ib_f
    from jsonb_array_elements(v_ib) e
    where (f.market is null or e ->> 'market' = f.market) and (f.model is null or e ->> 'model' = f.model);
    v_ib_d := (cma.flash_rows_of(p_tenant, 'installed_base',
                                 jsonb_strip_nulls(jsonb_build_object('measure', 'components_past_due', 'market', f.market, 'model', f.model)),
                                 'serial', false, 1, 0, null, null) ->> 'total')::bigint;
    select coalesce(sum(a.in_field), 0), coalesce(sum(a.past_due), 0) into v_fl_f, v_fl_d
    from cma.fleet_areas_of(p_tenant, f.market, f.model) a;
    if v_fl_f is distinct from v_ib_f then
      v_field := v_field || format('%s/%s %s<>%s; ', coalesce(f.market, 'all'), coalesce(f.model, 'all'), v_fl_f, v_ib_f);
    end if;
    if v_fl_d is distinct from v_ib_d then
      v_due := v_due || format('%s/%s %s<>%s; ', coalesce(f.market, 'all'), coalesce(f.model, 'all'), v_fl_d, v_ib_d);
    end if;
  end loop;
  return query select v_n, coalesce(nullif(v_field, ''), 'none'), coalesce(nullif(v_due, ''), 'none');
end
$$;

-- Check 3 for a tenant: the devices In the field of a market with areas without exactly one area of their market, or not
-- the hash's pick; the devices with an area they should not have (not In the field, or a market without areas); the
-- states not the hash's bucket (or a state where none applies); and whether two reads give the same area and state
create or replace function pg_temp.v0009t_places(p_tenant uuid)
returns text
language plpgsql
as $$
declare
  v_today date := cma.tenant_today_of(p_tenant);
  v_one   text;
  v_two   text;
  v_res   text;
begin
  select format('in the field with areas %s; without one area of their market %s; not the hash''s pick %s; with an area they should not have %s; states not the hash''s bucket %s',
                count(*) filter (where d.is_in_field and exists (select 1 from cma.postcode_area pa where pa.country = d.market)),
                count(*) filter (where d.is_in_field and exists (select 1 from cma.postcode_area pa where pa.country = d.market)
                                   and (d.area_id is null or not exists (select 1 from cma.postcode_area pa where pa.id = d.area_id and pa.country = d.market))),
                count(*) filter (where d.is_in_field and d.area_id is distinct from pg_temp.v0009t_pick(d.device_id, d.market)),
                count(*) filter (where d.area_id is not null and (not d.is_in_field or not exists (select 1 from cma.postcode_area pa where pa.country = d.market))),
                count(*) filter (where d.state is distinct from case when d.is_in_field then pg_temp.v0009t_state(d.device_id) end))
  into v_res
  from cma.fleet_devices_of(p_tenant, v_today) d;
  select string_agg(d.device_id::text || ':' || coalesce(d.area_id::text, '-') || ':' || coalesce(d.state, '-'), ',' order by d.device_id::text collate "C")
  into v_one from cma.fleet_devices_of(p_tenant, v_today) d;
  select string_agg(d.device_id::text || ':' || coalesce(d.area_id::text, '-') || ':' || coalesce(d.state, '-'), ',' order by d.device_id::text collate "C")
  into v_two from cma.fleet_devices_of(p_tenant, v_today) d;
  return v_res || format('; two reads the same %s', (v_one is not distinct from v_two));
end
$$;

-- Check 4 for a tenant: the rows whose states do not add up to In the field
create or replace function pg_temp.v0009t_sums(p_tenant uuid)
returns text
language sql
as $$
  select format('rows %s; whose states do not add up to In the field %s', count(*),
                count(*) filter (where a.ready + a.needs_attention + a.no_connection + a.not_monitored <> a.in_field))
  from cma.fleet_areas_of(p_tenant, null, null) a
$$;

-- ---------------------------------------------------------------------------------------------
-- S. The objects
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_bad text := '';
  f     text;
  v_fns text[] := array['cma.fleet_settings_of(uuid)', 'cma.fleet_devices_of(uuid,date)', 'cma.fleet_areas_of(uuid,text,text)',
                        'cma.fleet_rows_of(uuid,text,text,text,uuid,boolean,integer)', 'cma.assert_fleet_filters(text,text,text,integer)',
                        'cma.fleet_areas(text,text)', 'cma.fleet_rows(text,text,text,uuid,boolean,integer)'];
  v_pattern text := '(raw|email|phone|mobile|address|first_name|last_name|full_?name|customer|postcode|city|^name )';
begin
  -- S1
  perform pg_temp.v0009t_row(1, 'S1', 'the addition recorded after 0009r; the setting a boolean, default false',
    format('0009r %s, 0009t %s; setting %s',
           exists (select 1 from cma.schema_migration where version = '0009r'), exists (select 1 from cma.schema_migration where version = '0009t'),
           (select s.value_type || ' ' || s.default_value || ' ' || coalesce(array_to_string(s.allowed_values, ','), 'any') from cma.setting s
            where s.key = 'fleet_management.dummy_preview')),
    '0009r t, 0009t t; setting boolean false any');

  -- S2
  perform pg_temp.v0009t_row(2, 'S2', 'cma.postcode_area: reference data, read by the application, written by migrations, never the readers''',
    format('tenant_id %s; row-level security %s; app select %s, insert %s, update %s, delete %s; readers select %s; codes not an area %s; countries %s; sample rows %s; UK %s',
           exists (select 1 from information_schema.columns where table_schema = 'cma' and table_name = 'postcode_area' and column_name = 'tenant_id'),
           (select c.relrowsecurity from pg_class c where c.oid = 'cma.postcode_area'::regclass),
           has_table_privilege('cma_app', 'cma.postcode_area', 'select'), has_table_privilege('cma_app', 'cma.postcode_area', 'insert'),
           has_table_privilege('cma_app', 'cma.postcode_area', 'update'), has_table_privilege('cma_app', 'cma.postcode_area', 'delete'),
           has_table_privilege('cma_readonly', 'cma.postcode_area', 'select'),
           (select count(*) from cma.postcode_area where area_code !~ '^[A-Z0-9]{1,4}$' or country !~ '^[A-Z]{2}$'),
           (select string_agg(x.country, ',' order by x.country collate "C") from (select distinct pa.country from cma.postcode_area pa
            where pa.country in ('GB', 'NL', 'DE', 'FR', 'AT', 'SE', 'IE', 'BE')) x),
           (select count(*) from cma.postcode_area where source = 'sample-2026-11' and country in ('GB', 'NL', 'DE', 'FR', 'AT', 'SE', 'IE', 'BE')),
           (select count(*) from cma.postcode_area where country = 'UK')),
    'tenant_id f; row-level security f; app select t, insert f, update f, delete f; readers select f; codes not an area 0; countries AT,BE,DE,FR,GB,IE,NL,SE; sample rows 80; UK 0');

  -- S3
  foreach f in array v_fns loop
    if to_regprocedure(f) is null then
      v_bad := v_bad || f || ' missing; ';
      continue;
    end if;
    if pg_get_userbyid((select p.proowner from pg_proc p where p.oid = to_regprocedure(f))) <> 'cma_owner' then v_bad := v_bad || f || ' owner; '; end if;
    if not has_function_privilege('cma_app', to_regprocedure(f), 'execute') then v_bad := v_bad || f || ' not the application''s; '; end if;
    if has_function_privilege('cma_readonly', to_regprocedure(f), 'execute') then v_bad := v_bad || f || ' the readers''; '; end if;
    if exists (select 1 from pg_proc p cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
               where p.oid = to_regprocedure(f) and a.grantee = 0) then v_bad := v_bad || f || ' public''s; '; end if;
    if (select p.prosecdef from pg_proc p where p.oid = to_regprocedure(f)) then v_bad := v_bad || f || ' security definer; '; end if;
  end loop;
  foreach f in array array['cma.fleet_areas_of(uuid,text,text)', 'cma.fleet_rows_of(uuid,text,text,text,uuid,boolean,integer)',
                           'cma.fleet_areas(text,text)', 'cma.fleet_rows(text,text,text,uuid,boolean,integer)'] loop
    if not coalesce((select 'jit=off' = any (p.proconfig) from pg_proc p where p.oid = to_regprocedure(f)), false) then
      v_bad := v_bad || f || ' without jit=off; ';
    end if;
  end loop;
  perform pg_temp.v0009t_row(3, 'S3', 'the functions: the owner''s, the application''s to execute, in the caller''s rights, JIT off on the reads',
    coalesce(nullif(v_bad, ''), 'ok'), 'ok');

  -- S4 (5)
  v_bad := '';
  if exists (select 1 from regexp_split_to_table(pg_get_function_result('cma.fleet_areas_of(uuid,text,text)'::regprocedure), ', ') c where c ~ v_pattern) then
    v_bad := v_bad || 'a personal column in cma.fleet_areas_of; ';
  end if;
  if exists (select 1 from regexp_split_to_table(pg_get_function_result('cma.fleet_rows_of(uuid,text,text,text,uuid,boolean,integer)'::regprocedure), ', ') c where c ~ v_pattern) then
    v_bad := v_bad || 'a personal column in cma.fleet_rows_of; ';
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'cma' and table_name = 'postcode_area' and column_name ~ v_pattern) then
    v_bad := v_bad || 'a personal column in cma.postcode_area; ';
  end if;
  if exists (select 1 from pg_class c where c.relnamespace = 'cma_read'::regnamespace and c.relkind in ('v', 'm')
             and pg_get_viewdef(c.oid) ~ '(postcode_area|fleet_)') then
    v_bad := v_bad || 'a cma_read view reads it; ';
  end if;
  if exists (select 1 from pg_proc p where p.pronamespace = 'cma_read'::regnamespace and p.prosrc ~ '(postcode_area|fleet_)') then
    v_bad := v_bad || 'a cma_read function reads it; ';
  end if;
  if exists (select 1 from pg_depend d join pg_rewrite r on r.oid = d.objid join pg_class c on c.oid = r.ev_class
             where c.relnamespace = 'cma_read'::regnamespace and d.refobjid = 'cma.postcode_area'::regclass) then
    v_bad := v_bad || 'a cma_read view depends on it; ';
  end if;
  perform pg_temp.v0009t_row(4, 'S4', 'no personal column in the reads or the table; nothing in cma_read reads the areas or the fleet functions',
    coalesce(nullif(v_bad, ''), 'ok'), 'ok');
end
$$;

-- ---------------------------------------------------------------------------------------------
-- A. Behaviour on two throwaway tenants, always rolled back
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_t uuid; v_u uuid; v_reg uuid; v_ureg uuid;
  v_agent uuid; v_analyst uuid; v_super uuid; v_ureader uuid;
  v_ra uuid; v_rr uuid; v_rs uuid; v_ur uuid;
  v_today date;
  c record;
  j jsonb; k jsonb;
  v_a1 text; v_a1h text; v_a2 text; v_a2b text; v_a3 text; v_a4 text; v_a5 text; v_a6 text; v_a6b text;
  v_before text; v_after text;
  n_all bigint; n_sum bigint;
begin
  begin
    v_t := cma.create_tenant('verify-0009t-one', 'Verify 0009t one', 'Europe/Amsterdam');
    v_u := cma.create_tenant('verify-0009t-two', 'Verify 0009t two', 'Europe/Amsterdam');
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency, sort_order) values
      (v_t, 'GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', 10), (v_t, 'NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR', 20),
      (v_t, 'LU', 'Luxembourg', 'Europe/Luxembourg', 'fr', 'EUR', 30), (v_u, 'GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', 10);
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t, 'verifyregister', 'Verify register', 'base-1', 'assets') returning id into v_reg;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_u, 'verifyregister', 'Verify register', 'base-2', 'assets') returning id into v_ureg;
    -- the register: two models, a status in the field, one in stock, one neither; a rule on m1's pads of 24 months, so an
    -- m1 device shipped in 2019 is past due and one shipped a month ago is not; m2 has no rule (no due item)
    insert into cma.device_model (tenant_id, key, name, sort_order) values (v_t, 'm1', 'M1', 10), (v_t, 'm2', 'M2', 20), (v_u, 'm1', 'M1', 10);
    insert into cma.device_status (tenant_id, key, name, is_in_field, is_in_stock, is_tracked) values
      (v_t, 'field', 'Field', true, false, true), (v_t, 'stock', 'Stock', false, true, true), (v_t, 'gone', 'Gone', false, false, false),
      (v_u, 'field', 'Field', true, false, true);
    insert into cma.device_component_kind (tenant_id, key, name, sort_order) values (v_t, 'pads', 'Pads', 10);
    insert into cma.maintenance_rule (tenant_id, model_key, component_key, interval_months, lead_days) values (v_t, 'm1', 'pads', 24, 0);
    -- VF-1 to VF-80: every tenth without a market, else GB, NL, LU, GB by g mod 4; every seventh in stock, every
    -- nineteenth gone; m1 for an even g; shipped in 2019 for g mod 3 = 0, a month ago otherwise
    insert into cma.device (tenant_id, connection_id, source_system, source_id, serial, model_key, market, device_status_key, last_shipped_on)
    select v_t, v_reg, 'verifyregister', 'vf-' || g, 'VF-' || g, case when g % 2 = 0 then 'm1' else 'm2' end,
           case when g % 10 = 0 then null else (array['GB', 'GB', 'NL', 'LU'])[1 + g % 4] end,
           case when g % 19 = 0 then 'gone' when g % 7 = 0 then 'stock' else 'field' end,
           case when g % 3 = 0 then date '2019-01-15' else current_date - 30 end
    from generate_series(1, 80) g;
    insert into cma.device (tenant_id, connection_id, source_system, source_id, serial, model_key, market, device_status_key)
    values (v_u, v_ureg, 'verifyregister', 'uf-1', 'UF-1', 'm1', 'GB', 'field');
    -- the readers: an agent (no report permission), an analyst (reports.view), a supervisor (performance.team); U's analyst
    insert into cma.app_role (tenant_id, key, name) values (v_t, 'verify_agent', 'Verify agent') returning id into v_ra;
    insert into cma.app_role (tenant_id, key, name) values (v_t, 'verify_analyst', 'Verify analyst') returning id into v_rr;
    insert into cma.app_role (tenant_id, key, name) values (v_t, 'verify_supervisor', 'Verify supervisor') returning id into v_rs;
    insert into cma.app_role (tenant_id, key, name) values (v_u, 'verify_analyst', 'Verify analyst') returning id into v_ur;
    insert into cma.role_permission (tenant_id, role_id, permission_key) values
      (v_t, v_ra, 'workday.own'), (v_t, v_rr, 'reports.view'), (v_t, v_rs, 'performance.team'), (v_u, v_ur, 'reports.view');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-agent-0009t@example.invalid', 'agent') returning id into v_agent;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-analyst-0009t@example.invalid', 'analyst') returning id into v_analyst;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-supervisor-0009t@example.invalid', 'supervisor') returning id into v_super;
    insert into cma.app_user (tenant_id, email, display_name) values (v_u, 'verify-analyst-0009t@example.invalid', 'analyst') returning id into v_ureader;
    insert into cma.user_role (tenant_id, user_id, role_id) values (v_t, v_agent, v_ra), (v_t, v_analyst, v_rr), (v_t, v_super, v_rs), (v_u, v_ureader, v_ur);
    v_today := cma.tenant_today_of(v_t);

    -- A1 (1, 2): against Installed base for every filter, and counted by hand. Gone: 19, 38, 57, 76; in stock: the other
    -- multiples of 7 (eleven); In the field 80 - 4 - 11 = 65. Without an area (LU: g mod 4 = 3; no market: g mod 10 = 0)
    -- and In the field: 16 of LU and 7 without a market = 23, so 42 on the map. Past due: m1 (even g), shipped in 2019
    -- (g mod 3 = 0), tracked (not gone): the multiples of 6, 6 to 78 = 13; 42 in stock (not In the field: the row without
    -- an area), 30 and 60 without a market (that row too), so 10 on the map and 3 in the row without an area. The filters:
    -- none, the four markets (GB, NL, LU, unknown), the two models, and the five pairs that hold devices (GB m1, GB m2,
    -- NL m1, LU m2, unknown m1) = 12
    select format('filters %s; In the field differing %s; Devices past due differing %s', x.filters, x.field_differs, x.past_due_differs)
    into v_a1 from pg_temp.v0009t_compare(v_t) x;
    select format('In the field %s; past due %s; past due on the map %s; the row without an area: in the field %s, past due %s',
                  sum(a.in_field), sum(a.past_due), sum(a.past_due) filter (where a.area_id is not null),
                  sum(a.in_field) filter (where a.area_id is null), sum(a.past_due) filter (where a.area_id is null))
    into v_a1h from cma.fleet_areas_of(v_t, null, null) a;

    -- A2 (3): each device's area and state, the hash's; LU and no market: none; a reload keeps both
    v_a2 := pg_temp.v0009t_places(v_t);
    select string_agg(d.device_id::text || ':' || coalesce(d.area_id::text, '-') || ':' || coalesce(d.state, '-'), ',' order by d.device_id::text collate "C")
    into v_before from cma.fleet_devices_of(v_t, v_today) d;
    update cma.device set synced_at = now() + interval '1 second', serial = serial where tenant_id = v_t;
    select string_agg(d.device_id::text || ':' || coalesce(d.area_id::text, '-') || ':' || coalesce(d.state, '-'), ',' order by d.device_id::text collate "C")
    into v_after from cma.fleet_devices_of(v_t, v_today) d;
    select format('LU or no market with an area %s; the row without an area holds them %s; not in the field with a state %s; a reload keeps area and state %s',
                  count(*) filter (where (d.market = 'LU' or d.market = 'unknown') and d.area_id is not null),
                  (select a.in_field from cma.fleet_areas_of(v_t, null, null) a where a.area_id is null)
                    = count(*) filter (where d.is_in_field and (d.market = 'LU' or d.market = 'unknown')),
                  count(*) filter (where not d.is_in_field and d.state is not null),
                  v_before is not distinct from v_after)
    into v_a2b from cma.fleet_devices_of(v_t, v_today) d;

    -- A3 (4)
    v_a3 := pg_temp.v0009t_sums(v_t);

    -- A5 (7) first, with the setting off (the default): both reads set up false and nothing more, for the analyst
    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('app.user_id', v_analyst::text, true);
    perform set_config('role', 'cma_app', true);
    j := cma.fleet_areas(null, null);
    k := cma.fleet_rows(null, null, null, null, false, 1);
    v_a5 := format('off: areas %s, rows %s', j::text, k::text);
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.user_id', '', true);
    insert into cma.tenant_setting (tenant_id, key, value) values (v_t, 'fleet_management.dummy_preview', 'true'), (v_u, 'fleet_management.dummy_preview', 'true');
    perform set_config('app.user_id', v_analyst::text, true);
    perform set_config('role', 'cma_app', true);
    j := cma.fleet_areas(null, null);
    k := cma.fleet_rows(null, null, null, null, false, 1);
    v_a5 := v_a5 || format('; on: areas set up %s, in the field %s; rows set up %s with total %s',
                           j ->> 'set_up', (select sum((e ->> 'in_field')::bigint) from jsonb_array_elements(j -> 'areas') e), k ->> 'set_up', k ->> 'total');

    -- A4 (6): the readers, and the tenants apart
    perform set_config('app.user_id', v_super::text, true);
    v_a4 := format('supervisor %s %s', pg_temp.v0009t_code('select cma.fleet_areas()'), pg_temp.v0009t_code('select cma.fleet_rows()'));
    perform set_config('app.user_id', v_analyst::text, true);
    v_a4 := v_a4 || format('; analyst %s %s', pg_temp.v0009t_code('select cma.fleet_areas()'), pg_temp.v0009t_code('select cma.fleet_rows()'));
    perform set_config('app.user_id', v_agent::text, true);
    v_a4 := v_a4 || format('; agent %s %s', pg_temp.v0009t_code('select cma.fleet_areas()'), pg_temp.v0009t_code('select cma.fleet_rows()'));
    perform set_config('app.tenant_id', v_u::text, true);
    perform set_config('app.user_id', v_ureader::text, true);
    v_a4 := v_a4 || format('; under the other tenant: its devices of the first %s; its reader sees in the field %s',
                           (select coalesce(sum(a.in_field), 0) + coalesce(sum(a.past_due), 0) from cma.fleet_areas_of(v_t, null, null) a),
                           (select sum((e ->> 'in_field')::bigint) from jsonb_array_elements(cma.fleet_areas() -> 'areas') e));
    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('app.user_id', v_analyst::text, true);

    -- A6: the refusals and the list's pages
    v_a6 := format('market gb %s, model M1 %s, state broken %s, page 0 %s, page null %s',
                   pg_temp.v0009t_code($q$select cma.fleet_areas('gb', null)$q$), pg_temp.v0009t_code($q$select cma.fleet_rows(null, 'M1')$q$),
                   pg_temp.v0009t_code($q$select cma.fleet_rows(null, null, 'broken')$q$),
                   pg_temp.v0009t_code($q$select cma.fleet_rows(null, null, null, null, false, 0)$q$),
                   pg_temp.v0009t_code($q$select cma.fleet_rows(null, null, null, null, false, null)$q$));
    n_all := (cma.fleet_rows(null, null, null, null, false, 1) ->> 'total')::bigint;
    n_sum := 0;
    for c in select s from unnest(array['ready', 'needs_attention', 'no_connection', 'not_monitored']) s loop
      n_sum := n_sum + (cma.fleet_rows(null, null, c.s, null, false, 1) ->> 'total')::bigint;
    end loop;
    j := cma.fleet_rows(null, null, null, null, false, 1);
    k := cma.fleet_rows(null, null, null, null, false, 2);
    v_a6b := format('total %s (in the field %s and past due not in the field %s); the states add up to in the field %s; monitored %s; page 1 rows %s, page 2 rows %s; in order %s; attention only the devices that need attention %s',
      n_all, (cma.fleet_rows(null, null, 'in_field', null, false, 1) ->> 'total'),
      (select count(*) from cma.fleet_devices_of(v_t, v_today) d where not d.is_in_field),
      n_sum = (cma.fleet_rows(null, null, 'in_field', null, false, 1) ->> 'total')::bigint,
      (cma.fleet_rows(null, null, 'monitored', null, false, 1) ->> 'total')::bigint
        = (select count(*) from cma.fleet_devices_of(v_t, v_today) d where d.state in ('ready', 'needs_attention', 'no_connection')),
      jsonb_array_length(j -> 'rows'), jsonb_array_length(k -> 'rows'),
      (select string_agg(r.v ->> 'device_id', ',' order by r.o) from (select v, o from jsonb_array_elements(j -> 'rows') with ordinality x(v, o)
                                                                       union all
                                                                       select v, o + 50 from jsonb_array_elements(k -> 'rows') with ordinality x(v, o)) r)
        = (select string_agg(d.device_id::text, ',' order by case when d.state = 'needs_attention' then 0 when d.state = 'no_connection' then 1
                                                                   when d.past_due_items > 0 then 2 else 3 end, d.serial collate "C", d.device_id)
           from cma.fleet_devices_of(v_t, v_today) d),
      (cma.fleet_rows(null, null, null, null, true, 1) ->> 'total')::bigint
        = (select count(*) from cma.fleet_devices_of(v_t, v_today) d where d.state in ('needs_attention', 'no_connection') or d.past_due_items > 0));

    perform set_config('role', 'cma_owner', true);
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
  end;
  perform set_config('role', 'cma_owner', true);
  perform set_config('app.tenant_id', '', true);
  perform set_config('app.user_id', '', true);

  perform pg_temp.v0009t_row(10, 'A1', 'by hand: In the field and Devices past due equal Installed base''s for every filter', v_a1,
    'filters 12; In the field differing none; Devices past due differing none');
  perform pg_temp.v0009t_row(11, 'A1', 'by hand: the figures counted by hand (the in-stock device past due in the row without an area)', v_a1h,
    'In the field 65; past due 13; past due on the map 10; the row without an area: in the field 23, past due 3');
  perform pg_temp.v0009t_row(12, 'A2', 'by hand: one area of the device''s market, the hash''s pick; the state the hash''s bucket; two reads the same', v_a2,
    'in the field with areas 42; without one area of their market 0; not the hash''s pick 0; with an area they should not have 0; states not the hash''s bucket 0; two reads the same t');
  perform pg_temp.v0009t_row(13, 'A2', 'by hand: no area for LU or no market (they count in the row without one), no state out of the field, a reload keeps both', v_a2b,
    'LU or no market with an area 0; the row without an area holds them t; not in the field with a state 0; a reload keeps area and state t');
  perform pg_temp.v0009t_row(14, 'A3', 'by hand: the states add up to In the field in every row', v_a3,
    regexp_replace(v_a3, 'do not add up to In the field [0-9]+$', 'do not add up to In the field 0'));
  perform pg_temp.v0009t_row(15, 'A4', 'the analyst and the supervisor read, the agent is refused; the tenants apart', v_a4,
    'supervisor ok ok; analyst ok ok; agent CMA06 CMA06; under the other tenant: its devices of the first 0; its reader sees in the field 1');
  perform pg_temp.v0009t_row(16, 'A5', 'off: set up false and nothing more; on: the figures', v_a5,
    'off: areas {"set_up": false}, rows {"set_up": false}; on: areas set up true, in the field 65; rows set up true with total 66');
  perform pg_temp.v0009t_row(17, 'A6', 'the refusals (CMA04)', v_a6, 'market gb CMA04, model M1 CMA04, state broken CMA04, page 0 CMA04, page null CMA04');
  perform pg_temp.v0009t_row(18, 'A6', 'the list''s pages, order, attention filter and state filters', v_a6b,
    'total 66 (in the field 65 and past due not in the field 1); the states add up to in the field t; monitored t; page 1 rows 50, page 2 rows 16; in order t; attention only the devices that need attention t');
end
$$;

-- ---------------------------------------------------------------------------------------------
-- R and E. Every active tenant whose register is set up, as the application, always rolled back
-- ---------------------------------------------------------------------------------------------
do $$
declare
  t record;
  v_any boolean := false;
  v_err text; v_r12 record; v_r3 text; v_r4 text; v_e1 numeric; v_e2 numeric; v_ms numeric; v_t0 timestamptz;
  n bigint;
begin
  for t in select x.id, x.slug from cma.tenant x where x.status = 'active' order by x.slug collate "C" loop
    if not coalesce(cma.flash_source_set_up_of(t.id, 'assets'), false) then
      continue;
    end if;
    v_any := true;
    v_err := null; v_r12 := null; v_r3 := null; v_r4 := null; v_e1 := null; v_e2 := null;
    begin
      perform set_config('app.tenant_id', t.id::text, true);
      perform set_config('role', 'cma_app', true);
      select * into v_r12 from pg_temp.v0009t_compare(t.id);
      v_r3 := pg_temp.v0009t_places(t.id);
      v_r4 := pg_temp.v0009t_sums(t.id);
      -- E1 and E2: the best of three after six calls
      for i in 1 .. 9 loop
        v_t0 := clock_timestamp();
        select count(*) into n from cma.fleet_areas_of(t.id, null, null);
        v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
        if i > 6 then v_e1 := least(coalesce(v_e1, v_ms), v_ms); end if;
      end loop;
      for i in 1 .. 9 loop
        v_t0 := clock_timestamp();
        select count(*) into n from cma.fleet_rows_of(t.id, null, null, null, null, true, 1);
        v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
        if i > 6 then v_e2 := least(coalesce(v_e2, v_ms), v_ms); end if;
      end loop;
      raise exception using errcode = 'CMAOK', message = 'rollback';
    exception
      when sqlstate 'CMAOK' then null;
      when others then v_err := sqlstate || ': ' || left(sqlerrm, 300);
    end;
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.tenant_id', '', true);
    if v_err is not null then
      insert into pg_temp.verify_0009t values (100, 'R1 to E2 ' || t.slug || ': the checks ran to their end', 'FAIL', v_err);
      continue;
    end if;
    perform pg_temp.v0009t_row(30, 'R1', t.slug || ': In the field equals Installed base''s for every filter',
      format('filters %s; differing %s', v_r12.filters, v_r12.field_differs), format('filters %s; differing none', v_r12.filters));
    perform pg_temp.v0009t_row(31, 'R2', t.slug || ': Devices past due equals Installed base''s for every filter',
      format('filters %s; differing %s', v_r12.filters, v_r12.past_due_differs), format('filters %s; differing none', v_r12.filters));
    perform pg_temp.v0009t_row(32, 'R3', t.slug || ': one area of the device''s market, the hash''s pick; the state the hash''s bucket; two reads the same',
      v_r3, regexp_replace(v_r3, 'without one area of their market [0-9]+; not the hash''s pick [0-9]+; with an area they should not have [0-9]+; states not the hash''s bucket [0-9]+; two reads the same [a-z]+$',
                           'without one area of their market 0; not the hash''s pick 0; with an area they should not have 0; states not the hash''s bucket 0; two reads the same t'));
    perform pg_temp.v0009t_row(33, 'R4', t.slug || ': the states add up to In the field in every row', v_r4,
      regexp_replace(v_r4, 'do not add up to In the field [0-9]+$', 'do not add up to In the field 0'));
    insert into pg_temp.verify_0009t values (40, 'E1 ' || t.slug || ': cma.fleet_areas_of, no filter, within its budget',
      case when v_e1 <= case when pg_temp.v0009t_p('E1') then 0 else current_setting('verify.max_list_ms')::numeric end then 'PASS' else 'FAIL' end,
      format('%s ms (best of 3, after six calls) against %s ms', v_e1, case when pg_temp.v0009t_p('E1') then '0' else current_setting('verify.max_list_ms') end));
    insert into pg_temp.verify_0009t values (41, 'E2 ' || t.slug || ': cma.fleet_rows_of, the devices that need attention, page 1, within its budget',
      case when v_e2 <= case when pg_temp.v0009t_p('E2') then 0 else current_setting('verify.max_list_ms')::numeric end then 'PASS' else 'FAIL' end,
      format('%s ms (best of 3, after six calls) against %s ms', v_e2, case when pg_temp.v0009t_p('E2') then '0' else current_setting('verify.max_list_ms') end));
  end loop;
  if not v_any then
    insert into pg_temp.verify_0009t values (30, 'R1 to E2 the page''s reads per tenant',
      case when current_setting('verify.provoke') <> 'false' then 'FAIL' else 'skip' end, 'no active tenant has its register set up');
  end if;
end
$$;

drop function if exists pg_temp.v0009t_sums(uuid);
drop function if exists pg_temp.v0009t_places(uuid);
drop function if exists pg_temp.v0009t_compare(uuid);
drop function if exists pg_temp.v0009t_state(uuid);
drop function if exists pg_temp.v0009t_pick(uuid, text);
drop function if exists pg_temp.v0009t_code(text);
drop function if exists pg_temp.v0009t_row(integer, text, text, text, text);
drop function if exists pg_temp.v0009t_p(text);

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0009t
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke') <> 'false' then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0009t where result = 'FAIL') then 'FAIL'
                  when not exists (select 1 from pg_temp.verify_0009t where result = 'PASS') then 'FAIL'
                  else 'PASS' end,
             format('189_verify_fleet_management: %s PASS, %s FAIL, %s skip', (select count(*) from pg_temp.verify_0009t where result = 'PASS'),
                    (select count(*) from pg_temp.verify_0009t where result = 'FAIL'), (select count(*) from pg_temp.verify_0009t where result = 'skip'))) x
order by ord, check_name collate "C";
drop table if exists pg_temp.verify_0009t;
reset role;
