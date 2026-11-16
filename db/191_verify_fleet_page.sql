-- =============================================================================================
-- 191_verify_fleet_page.sql: verifies addition 0009u, Assets → Fleet management's page in one read (cma.fleet_page_of,
-- cma.fleet_page)
-- =============================================================================================
-- Universal: no seed is assumed, so it runs in dev and in prod. Two kinds of checks:
--   on two throwaway tenants (T, U): 189's register of invented devices (serials VF-1 to VF-80, invented markets GB, NL
--     and LU, the last without a postcode area; no person's data), its maintenance rule and its three readers; the whole
--     step is rolled back;
--   on every active tenant whose register is set up (R, E): the page's read against 0009t's two reads and Installed
--     base's own figure, and its budget, as the application (cma_app, row-level security on), in a step that is always
--     rolled back. Its dummy_preview is not needed: cma.fleet_page_of is read directly.
-- Run as your own IAM login, after 190 (and 188). Output: tenant slugs, market codes, model keys, counts and milliseconds
-- only. 189_verify_fleet_management.sql keeps passing unchanged after 190 (it reads none of 190's functions).
--
-- Checks (the brief's 1 to 4)
--   S1  the addition is recorded after 0009t
--   S2  the functions: cma_owner's, the application's to execute (not public's, not the readers'), in the caller's rights,
--       JIT off on both; nothing in cma_read reads them
--   A1  (1) by hand on T: cma.fleet_page_of's tiles, areas, past_due_not_in_field and list equal what cma.fleet_areas_of and
--       cma.fleet_rows_of return for the same filters (none, each market, each model, each market and model), each with
--       the page's default list (the devices that need attention), every tile's list (a state) and its first area's list
--   A2  (2) by hand on T: the tiles' Devices past due split: in the field + not in the field = Devices past due =
--       Installed base's, for every filter; and the figures counted by hand
--   A3  (3) the analyst (reports.view) and the supervisor (performance.team) read cma.fleet_page, the agent is refused
--       (CMA06); under U's context T's devices are not read (row-level security) and U's reader sees U's device alone;
--       dummy_preview false answers {"set_up": false} and nothing more, true the figures; a malformed market, model or
--       state is refused (CMA04); no key of the answer's areas or rows matches the personal-column pattern (189's S4)
--   R1  (1) per tenant: as A1, for every market × model with the page's default list, and the unfiltered page with each
--       tile's list and the largest area's
--   R2  (2) per tenant: as A2's split, for every market × model
--   E1  (4) per tenant, as cma_app: cma.fleet_page_of, no filter, within verify.max_page_ms (150, the brief's budget), the
--       best of three after six calls
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
select set_config('verify.provoke', 'false', false);                 -- 'true' for every check, or one check's id such as 'A1'
select set_config('verify.max_page_ms', '150', false);               -- the page's one read (the brief's budget, E6)

drop table if exists pg_temp.verify_0009u;
create temporary table verify_0009u (ord integer, check_name text, result text, detail text);
grant select, insert on pg_temp.verify_0009u to cma_app;

create or replace function pg_temp.v0009u_p(p_id text)
returns boolean
language sql stable
as $$
  select current_setting('verify.provoke') in ('true', p_id)
$$;

-- One check's row: PASS when what was found equals what is expected; provoked, the expectation carries a deliberate difference
create or replace function pg_temp.v0009u_row(p_ord integer, p_id text, p_name text, p_found text, p_expected text)
returns void
language plpgsql
as $$
declare
  v_exp text := case when pg_temp.v0009u_p(p_id) then coalesce(p_expected, '') || ' [provoked: a deliberate difference]' else p_expected end;
begin
  insert into pg_temp.verify_0009u values (p_ord, p_id || ' ' || p_name,
    case when p_found is not distinct from v_exp then 'PASS' else 'FAIL' end,
    case when p_found is not distinct from v_exp then left(coalesce(p_found, 'null'), 600)
         else left('found ' || coalesce(p_found, 'null') || ' | expected ' || coalesce(v_exp, 'null'), 2400) end);
end
$$;

-- The error code a statement raises, or 'ok'
create or replace function pg_temp.v0009u_code(p_sql text)
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

-- The page's answer as 0009t's two reads give it (expected): the settings and the date, the tiles summed from
-- cma.fleet_areas_of (as lib/fleet-management fleetTilesOf, with Devices past due split by the row not_in_field), the areas
-- in cma.fleet_areas's order and shape, past_due_not_in_field, and cma.fleet_rows_of's page 1 with the page's attention rule
-- in cma.fleet_rows's shape
create or replace function pg_temp.v0009u_expected(p_tenant uuid, p_market text, p_model text, p_state text, p_area uuid)
returns jsonb
language plpgsql
as $$
declare
  v_areas jsonb;
  v_tiles jsonb;
  v_pnif  bigint;
  v_rows  jsonb;
  v_total bigint;
begin
  select coalesce(jsonb_agg(to_jsonb(a) - 'kind' order by (a.area_id is null), (a.kind = 'not_in_field'), a.country collate "C", a.area_code collate "C")
                    filter (where a.kind <> 'not_in_field'), '[]'::jsonb),
         jsonb_build_object('in_field', coalesce(sum(a.in_field), 0), 'past_due', coalesce(sum(a.past_due), 0),
                            'past_due_in_field', coalesce(sum(a.past_due) filter (where a.kind <> 'not_in_field'), 0),
                            'past_due_not_in_field', coalesce(sum(a.past_due) filter (where a.kind = 'not_in_field'), 0),
                            'monitored', coalesce(sum(a.ready + a.needs_attention + a.no_connection), 0),
                            'ready', coalesce(sum(a.ready), 0), 'needs_attention', coalesce(sum(a.needs_attention), 0),
                            'no_connection', coalesce(sum(a.no_connection), 0), 'not_monitored', coalesce(sum(a.not_monitored), 0)),
         coalesce(sum(a.past_due) filter (where a.kind = 'not_in_field'), 0)
  into v_areas, v_tiles, v_pnif
  from cma.fleet_areas_of(p_tenant, p_market, p_model) a;
  select coalesce(jsonb_agg(to_jsonb(r) - 'total_rows' - 'o' order by r.o), '[]'::jsonb), coalesce(max(r.total_rows), 0)
  into v_rows, v_total
  from (select x.*, row_number() over () as o
        from cma.fleet_rows_of(p_tenant, p_market, p_model, p_state, p_area, p_state is null and p_area is null, 1) x) r;
  return jsonb_build_object('dummy_preview', (select s.dummy_preview from cma.fleet_settings_of(p_tenant) s),
                            'today', cma.tenant_today_of(p_tenant), 'tiles', v_tiles, 'areas', v_areas,
                            'past_due_not_in_field', v_pnif,
                            'list', jsonb_build_object('page', 1, 'page_size', 50, 'total', v_total, 'rows', v_rows));
end
$$;

-- Checks 1 and 2 for a tenant, every filter (none, each market, each model, each market and model of the devices the page
-- counts): the page's answer against 0009t's two reads with the page's default list, and (p_deep, or the filter none)
-- every tile's list and an area's (the filter's first, or with p_deep false its largest); the split of Devices past due
-- against Installed base's (cma.flash_rows_of, components_past_due: the list's total). Answers the filters, the answers
-- compared, those that differ and the filters whose split differs
create or replace function pg_temp.v0009u_compare(p_tenant uuid, p_deep boolean)
returns table (filters integer, compared integer, differing text, split_differing text)
language plpgsql
as $$
declare
  f      record;
  v      record;
  v_n    integer := 0;
  v_c    integer := 0;
  v_diff text := '';
  v_due  text := '';
  v_page jsonb;
  v_ib   bigint;
  v_area uuid;
begin
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
    -- the area of the deeper lists: the filter's first (p_deep) or its largest
    select a.area_id into v_area from cma.fleet_areas_of(p_tenant, f.market, f.model) a where a.kind = 'area'
    order by case when p_deep then 0 else -a.in_field end, a.country collate "C", a.area_code collate "C" limit 1;
    for v in
      select null::text as state, null::uuid as area
      union all
      select s.s, null::uuid from unnest(array['in_field', 'past_due', 'monitored', 'ready', 'needs_attention', 'no_connection', 'not_monitored']) s
      where p_deep or (f.market is null and f.model is null)
      union all
      select null::text, v_area where v_area is not null and (p_deep or (f.market is null and f.model is null))
    loop
      v_c := v_c + 1;
      v_page := cma.fleet_page_of(p_tenant, f.market, f.model, v.state, v.area);
      if v_page is distinct from pg_temp.v0009u_expected(p_tenant, f.market, f.model, v.state, v.area) then
        v_diff := v_diff || format('%s/%s/%s; ', coalesce(f.market, 'all'), coalesce(f.model, 'all'),
                                   coalesce(v.state, case when v.area is not null then 'area' else 'attention' end));
      end if;
      if v.state is null and v.area is null then
        v_ib := (cma.flash_rows_of(p_tenant, 'installed_base',
                                   jsonb_strip_nulls(jsonb_build_object('measure', 'components_past_due', 'market', f.market, 'model', f.model)),
                                   'serial', false, 1, 0, null, null) ->> 'total')::bigint;
        if (v_page -> 'tiles' ->> 'past_due_in_field')::bigint + (v_page -> 'tiles' ->> 'past_due_not_in_field')::bigint
             is distinct from (v_page -> 'tiles' ->> 'past_due')::bigint
           or (v_page -> 'tiles' ->> 'past_due')::bigint is distinct from v_ib then
          v_due := v_due || format('%s/%s %s+%s=%s<>%s; ', coalesce(f.market, 'all'), coalesce(f.model, 'all'),
                                   v_page -> 'tiles' ->> 'past_due_in_field', v_page -> 'tiles' ->> 'past_due_not_in_field',
                                   v_page -> 'tiles' ->> 'past_due', v_ib);
        end if;
      end if;
    end loop;
  end loop;
  return query select v_n, v_c, coalesce(nullif(v_diff, ''), 'none'), coalesce(nullif(v_due, ''), 'none');
end
$$;

-- ---------------------------------------------------------------------------------------------
-- S. The objects
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_bad text := '';
  f     text;
begin
  -- S1
  perform pg_temp.v0009u_row(1, 'S1', 'the addition recorded after 0009t',
    format('0009t %s, 0009u %s', exists (select 1 from cma.schema_migration where version = '0009t'),
           exists (select 1 from cma.schema_migration where version = '0009u')),
    '0009t t, 0009u t');

  -- S2
  foreach f in array array['cma.fleet_page_of(uuid,text,text,text,uuid)', 'cma.fleet_page(text,text,text,uuid)'] loop
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
    if not coalesce((select 'jit=off' = any (p.proconfig) from pg_proc p where p.oid = to_regprocedure(f)), false) then
      v_bad := v_bad || f || ' without jit=off; ';
    end if;
  end loop;
  if exists (select 1 from pg_proc p where p.pronamespace = 'cma_read'::regnamespace and p.prosrc ~ 'fleet_page') then
    v_bad := v_bad || 'a cma_read function reads it; ';
  end if;
  if exists (select 1 from pg_class c where c.relnamespace = 'cma_read'::regnamespace and c.relkind in ('v', 'm')
             and pg_get_viewdef(c.oid) ~ 'fleet_page') then
    v_bad := v_bad || 'a cma_read view reads it; ';
  end if;
  perform pg_temp.v0009u_row(2, 'S2', 'the functions: the owner''s, the application''s to execute, in the caller''s rights, JIT off; nothing in cma_read reads them',
    coalesce(nullif(v_bad, ''), 'ok'), 'ok');
end
$$;

-- ---------------------------------------------------------------------------------------------
-- A. Behaviour on two throwaway tenants (189's register), always rolled back
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_t uuid; v_u uuid; v_reg uuid; v_ureg uuid;
  v_agent uuid; v_analyst uuid; v_super uuid; v_ureader uuid;
  v_ra uuid; v_rr uuid; v_rs uuid; v_ur uuid;
  j jsonb;
  v_a1 text; v_a2 text; v_a2h text; v_a3 text; v_a3b text; v_a3c text; v_a3d text;
  v_pattern text := '(raw|email|phone|mobile|address|first_name|last_name|full_?name|customer|postcode|city|^name$)';
begin
  begin
    v_t := cma.create_tenant('verify-0009u-one', 'Verify 0009u one', 'Europe/Amsterdam');
    v_u := cma.create_tenant('verify-0009u-two', 'Verify 0009u two', 'Europe/Amsterdam');
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency, sort_order) values
      (v_t, 'GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', 10), (v_t, 'NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR', 20),
      (v_t, 'LU', 'Luxembourg', 'Europe/Luxembourg', 'fr', 'EUR', 30), (v_u, 'GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', 10);
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t, 'verifyregister', 'Verify register', 'base-1', 'assets') returning id into v_reg;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_u, 'verifyregister', 'Verify register', 'base-2', 'assets') returning id into v_ureg;
    -- 189's register: two models, a status in the field, one in stock, one neither; a rule on m1's pads of 24 months
    insert into cma.device_model (tenant_id, key, name, sort_order) values (v_t, 'm1', 'M1', 10), (v_t, 'm2', 'M2', 20), (v_u, 'm1', 'M1', 10);
    insert into cma.device_status (tenant_id, key, name, is_in_field, is_in_stock, is_tracked) values
      (v_t, 'field', 'Field', true, false, true), (v_t, 'stock', 'Stock', false, true, true), (v_t, 'gone', 'Gone', false, false, false),
      (v_u, 'field', 'Field', true, false, true);
    insert into cma.device_component_kind (tenant_id, key, name, sort_order) values (v_t, 'pads', 'Pads', 10);
    insert into cma.maintenance_rule (tenant_id, model_key, component_key, interval_months, lead_days) values (v_t, 'm1', 'pads', 24, 0);
    insert into cma.device (tenant_id, connection_id, source_system, source_id, serial, model_key, market, device_status_key, last_shipped_on)
    select v_t, v_reg, 'verifyregister', 'vf-' || g, 'VF-' || g, case when g % 2 = 0 then 'm1' else 'm2' end,
           case when g % 10 = 0 then null else (array['GB', 'GB', 'NL', 'LU'])[1 + g % 4] end,
           case when g % 19 = 0 then 'gone' when g % 7 = 0 then 'stock' else 'field' end,
           case when g % 3 = 0 then date '2019-01-15' else current_date - 30 end
    from generate_series(1, 80) g;
    insert into cma.device (tenant_id, connection_id, source_system, source_id, serial, model_key, market, device_status_key)
    values (v_u, v_ureg, 'verifyregister', 'uf-1', 'UF-1', 'm1', 'GB', 'field');
    insert into cma.app_role (tenant_id, key, name) values (v_t, 'verify_agent', 'Verify agent') returning id into v_ra;
    insert into cma.app_role (tenant_id, key, name) values (v_t, 'verify_analyst', 'Verify analyst') returning id into v_rr;
    insert into cma.app_role (tenant_id, key, name) values (v_t, 'verify_supervisor', 'Verify supervisor') returning id into v_rs;
    insert into cma.app_role (tenant_id, key, name) values (v_u, 'verify_analyst', 'Verify analyst') returning id into v_ur;
    insert into cma.role_permission (tenant_id, role_id, permission_key) values
      (v_t, v_ra, 'workday.own'), (v_t, v_rr, 'reports.view'), (v_t, v_rs, 'performance.team'), (v_u, v_ur, 'reports.view');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-agent-0009u@example.invalid', 'agent') returning id into v_agent;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-analyst-0009u@example.invalid', 'analyst') returning id into v_analyst;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-supervisor-0009u@example.invalid', 'supervisor') returning id into v_super;
    insert into cma.app_user (tenant_id, email, display_name) values (v_u, 'verify-analyst-0009u@example.invalid', 'analyst') returning id into v_ureader;
    insert into cma.user_role (tenant_id, user_id, role_id) values (v_t, v_agent, v_ra), (v_t, v_analyst, v_rr), (v_t, v_super, v_rs), (v_u, v_ureader, v_ur);

    -- A1 and A2 (1, 2): every filter, every list, against 0009t's reads and Installed base. 189's filters: none, the four
    -- markets (GB, NL, LU, unknown), the two models, the five pairs that hold devices = 12
    select format('filters %s; differing %s', x.filters, x.differing), format('filters %s; past due split differing %s', x.filters, x.split_differing)
    into v_a1, v_a2 from pg_temp.v0009u_compare(v_t, true) x;
    -- the figures by hand (189's A1: In the field 65; Devices past due 13: 12 in the field (10 on the map, 2 without an
    -- area: 30 and 60), 1 not in the field (42, in stock))
    j := cma.fleet_page_of(v_t, null, null, null, null);
    v_a2h := format('In the field %s; Devices past due %s = in the field %s + not in the field %s; past_due_not_in_field %s; the default list the devices that need attention %s',
                    j -> 'tiles' ->> 'in_field', j -> 'tiles' ->> 'past_due', j -> 'tiles' ->> 'past_due_in_field',
                    j -> 'tiles' ->> 'past_due_not_in_field', j ->> 'past_due_not_in_field',
                    (j -> 'list' ->> 'total')::bigint = (select count(*) from cma.fleet_devices_of(v_t, cma.tenant_today_of(v_t)) d
                                                         where d.state in ('needs_attention', 'no_connection') or d.past_due_items > 0));

    -- A3 (3): off first (the default), then on; the readers, the tenants apart, the refusals, the keys
    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('app.user_id', v_analyst::text, true);
    perform set_config('role', 'cma_app', true);
    v_a3 := format('off: %s', cma.fleet_page()::text);
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.user_id', '', true);
    insert into cma.tenant_setting (tenant_id, key, value) values (v_t, 'fleet_management.dummy_preview', 'true'), (v_u, 'fleet_management.dummy_preview', 'true');
    perform set_config('app.user_id', v_analyst::text, true);
    perform set_config('role', 'cma_app', true);
    j := cma.fleet_page();
    v_a3 := v_a3 || format('; on: set up %s, in the field %s, the list the devices that need attention %s, time zone %s, markets %s, models %s',
                           j ->> 'set_up', j -> 'tiles' ->> 'in_field',
                           (j -> 'list' ->> 'total')::bigint = (select count(*) from cma.fleet_devices_of(v_t, cma.tenant_today_of(v_t)) d
                                                                where d.state in ('needs_attention', 'no_connection') or d.past_due_items > 0),
                           j ->> 'time_zone',
                           (select string_agg(e ->> 'code', ',' order by o) from jsonb_array_elements(j -> 'filter_markets') with ordinality x(e, o)),
                           (select string_agg(e ->> 'key', ',' order by o) from jsonb_array_elements(j -> 'filter_models') with ordinality x(e, o)));
    v_a3d := format('area keys %s; row keys %s; an at sign %s',
                    (select count(*) from jsonb_array_elements(j -> 'areas') e cross join lateral jsonb_object_keys(e) k where k ~ v_pattern),
                    (select count(*) from jsonb_array_elements(j -> 'list' -> 'rows') e cross join lateral jsonb_object_keys(e) k where k ~ v_pattern),
                    strpos(j::text, '@') > 0);
    perform set_config('app.user_id', v_super::text, true);
    v_a3b := format('supervisor %s', pg_temp.v0009u_code('select cma.fleet_page()'));
    perform set_config('app.user_id', v_analyst::text, true);
    v_a3b := v_a3b || format('; analyst %s', pg_temp.v0009u_code('select cma.fleet_page()'));
    perform set_config('app.user_id', v_agent::text, true);
    v_a3b := v_a3b || format('; agent %s', pg_temp.v0009u_code('select cma.fleet_page()'));
    perform set_config('app.tenant_id', v_u::text, true);
    perform set_config('app.user_id', v_ureader::text, true);
    j := cma.fleet_page_of(v_t, null, null, null, null);
    v_a3b := v_a3b || format('; under the other tenant: the first''s in the field %s, past due %s, listed %s; its reader sees in the field %s',
                             j -> 'tiles' ->> 'in_field', j -> 'tiles' ->> 'past_due', j -> 'list' ->> 'total',
                             cma.fleet_page() -> 'tiles' ->> 'in_field');
    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('app.user_id', v_analyst::text, true);
    v_a3c := format('market gb %s, model M1 %s, state broken %s, an area of no device %s',
                    pg_temp.v0009u_code($q$select cma.fleet_page('gb')$q$), pg_temp.v0009u_code($q$select cma.fleet_page(null, 'M1')$q$),
                    pg_temp.v0009u_code($q$select cma.fleet_page(null, null, 'broken')$q$),
                    (cma.fleet_page(null, null, null, '00000000-0000-0000-0000-000000000000'::uuid) -> 'list' ->> 'total'));

    perform set_config('role', 'cma_owner', true);
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
  end;
  perform set_config('role', 'cma_owner', true);
  perform set_config('app.tenant_id', '', true);
  perform set_config('app.user_id', '', true);

  perform pg_temp.v0009u_row(10, 'A1', 'by hand: the page''s tiles, areas and lists equal 0009t''s two reads for every filter and list', v_a1,
    'filters 12; differing none');
  perform pg_temp.v0009u_row(11, 'A2', 'by hand: Devices past due in the field + not in the field = Devices past due = Installed base''s, every filter', v_a2,
    'filters 12; past due split differing none');
  perform pg_temp.v0009u_row(12, 'A2', 'by hand: the figures counted by hand', v_a2h,
    'In the field 65; Devices past due 13 = in the field 12 + not in the field 1; past_due_not_in_field 1; the default list the devices that need attention t');
  perform pg_temp.v0009u_row(13, 'A3', 'off: set up false and nothing more; on: the figures, the zone and the filters'' choices', v_a3,
    'off: {"set_up": false}; on: set up true, in the field 65, the list the devices that need attention t, time zone Europe/Amsterdam, markets GB,NL,LU,unknown, models m1,m2');
  perform pg_temp.v0009u_row(14, 'A3', 'the analyst and the supervisor read, the agent is refused; the tenants apart', v_a3b,
    'supervisor ok; analyst ok; agent CMA06; under the other tenant: the first''s in the field 0, past due 0, listed 0; its reader sees in the field 1');
  perform pg_temp.v0009u_row(15, 'A3', 'the refusals (CMA04); an area of no device lists none', v_a3c,
    'market gb CMA04, model M1 CMA04, state broken CMA04, an area of no device 0');
  perform pg_temp.v0009u_row(16, 'A3', 'no personal key in the areas or the rows', v_a3d, 'area keys 0; row keys 0; an at sign f');
end
$$;

-- ---------------------------------------------------------------------------------------------
-- R and E. Every active tenant whose register is set up, as the application, always rolled back
-- ---------------------------------------------------------------------------------------------
do $$
declare
  t record;
  v_any boolean := false;
  v_err text; v_r record; v_e1 numeric; v_ms numeric; v_t0 timestamptz;
  j jsonb;
begin
  for t in select x.id, x.slug from cma.tenant x where x.status = 'active' order by x.slug collate "C" loop
    if not coalesce(cma.flash_source_set_up_of(t.id, 'assets'), false) then
      continue;
    end if;
    v_any := true;
    v_err := null; v_r := null; v_e1 := null;
    begin
      perform set_config('app.tenant_id', t.id::text, true);
      perform set_config('role', 'cma_app', true);
      select * into v_r from pg_temp.v0009u_compare(t.id, false);
      -- E1: the best of three after six calls
      for i in 1 .. 9 loop
        v_t0 := clock_timestamp();
        j := cma.fleet_page_of(t.id, null, null, null, null);
        v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
        if i > 6 then v_e1 := least(coalesce(v_e1, v_ms), v_ms); end if;
      end loop;
      raise exception using errcode = 'CMAOK', message = 'rollback';
    exception
      when sqlstate 'CMAOK' then null;
      when others then v_err := sqlstate || ': ' || left(sqlerrm, 300);
    end;
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.tenant_id', '', true);
    if v_err is not null then
      insert into pg_temp.verify_0009u values (100, 'R1 to E1 ' || t.slug || ': the checks ran to their end', 'FAIL', v_err);
      continue;
    end if;
    perform pg_temp.v0009u_row(30, 'R1', t.slug || ': the page''s tiles, areas and lists equal 0009t''s two reads for every market × model',
      format('filters %s, answers %s; differing %s', v_r.filters, v_r.compared, v_r.differing),
      format('filters %s, answers %s; differing none', v_r.filters, v_r.compared));
    perform pg_temp.v0009u_row(31, 'R2', t.slug || ': Devices past due in the field + not in the field = Devices past due = Installed base''s',
      format('filters %s; past due split differing %s', v_r.filters, v_r.split_differing),
      format('filters %s; past due split differing none', v_r.filters));
    insert into pg_temp.verify_0009u values (40, 'E1 ' || t.slug || ': cma.fleet_page_of, no filter, within its budget',
      case when v_e1 <= case when pg_temp.v0009u_p('E1') then 0 else current_setting('verify.max_page_ms')::numeric end then 'PASS' else 'FAIL' end,
      format('%s ms (best of 3, after six calls) against %s ms', v_e1, case when pg_temp.v0009u_p('E1') then '0' else current_setting('verify.max_page_ms') end));
  end loop;
  if not v_any then
    insert into pg_temp.verify_0009u values (30, 'R1 to E1 the page''s read per tenant',
      case when current_setting('verify.provoke') <> 'false' then 'FAIL' else 'skip' end, 'no active tenant has its register set up');
  end if;
end
$$;

drop function if exists pg_temp.v0009u_compare(uuid, boolean);
drop function if exists pg_temp.v0009u_expected(uuid, text, text, text, uuid);
drop function if exists pg_temp.v0009u_code(text);
drop function if exists pg_temp.v0009u_row(integer, text, text, text, text);
drop function if exists pg_temp.v0009u_p(text);

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0009u
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke') <> 'false' then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0009u where result = 'FAIL') then 'FAIL'
                  when not exists (select 1 from pg_temp.verify_0009u where result = 'PASS') then 'FAIL'
                  else 'PASS' end,
             format('191_verify_fleet_page: %s PASS, %s FAIL, %s skip', (select count(*) from pg_temp.verify_0009u where result = 'PASS'),
                    (select count(*) from pg_temp.verify_0009u where result = 'FAIL'), (select count(*) from pg_temp.verify_0009u where result = 'skip'))) x
order by ord, check_name collate "C";
drop table if exists pg_temp.verify_0009u;
reset role;
