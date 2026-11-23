-- =============================================================================================
-- 225_verify_device_debt_status.sql: verifies addition 0009zl, the debt status on devices
-- =============================================================================================
-- Universal: no seed is assumed. Block S checks the addition, the tables, the grants and the functions' rights; blocks A1
-- to A12 each work on throwaway tenants (Europe/Amsterdam) inside a subtransaction that is always rolled back, so nothing
-- stays and the script runs in dev and in prod. People are synthetic (example.invalid); devices, serials and labels are
-- invented: no customer's name, address, email or phone number, and nothing of a real tenant is read or printed. The
-- maintenance reads of the _of functions are dated 23 November 2026, so their verdict never depends on the day it runs.
-- Cloud SQL Studio shows no notices: a check that fails raises "FAIL …" and stops its block; every check that passed
-- writes one row, and the last row is the verdict: "PASS | 14 PASS, 0 FAIL" (provoked: "PROVOKED, NOT A PASS"). A block
-- that stopped counts its checks as FAIL; the verdict is reached only when the client goes on after an error (psql
-- -v ON_ERROR_STOP=0, as the provoked run does). Run as your own IAM login after 224_device_debt_status.sql; then the
-- verifies its header names.
--   S1  0009zl recorded after 0009zk; the two tables with row-level security, the tenant policy and the audit trigger; the
--       application reads and writes both but deletes no debt status; the readers see neither; cma.device.debt_status_key
--       with its foreign key and partial index; the staging's and the row types' debt_status; connection_field's checks
--   S2  every new or remade function the application's only and in the caller's rights; JIT off where it was; the
--       Maintenance report's forms of 112 and 116 kept beside the new ones; cma.maintenance_due_of's 17 columns
--   A1  the file path: a label mapped trimmed and case-insensitively, an unmapped label null and counted (the load's
--       answer and the run's counts), an empty field null, an @ never stored; raw keeps a label
--   A2  an unchanged rerun changes nothing; an emptied field clears the key at the next load; an alias added later maps
--       the label at the next load
--   A3  the chunk path (the Ingest user): the key taken, a row without it loads it empty, a value too long refused; the
--       field mapped on an asset register connection
--   A4  data quality: device_debt_status_unmapped lists the unmapped label (305, after the device checks; fixed in the
--       asset register), an emptied field and an @ none
--   A5  cma.maintenance_items_of: every item kept, maintenance_paused only for a device in the field under a status that
--       pauses (one in stock under it, or under a status that does not pause, is not); its other columns 116's row for row
--   A6  the Maintenance reads' filter: null as 116's forms (cells, unknown, devices); unpaused leaving the paused device
--       out with maintenance_paused_devices 1; none, any and a key; a row marked paused; the catalog in its order
--   A7  the public reads: the page and the list with the filter as the admin; an unknown filter CMA04; the agent CMA06;
--       112's forms still answer as before
--   A8  the installed base's take: under_debt_status counts devices in the field under a debt status only; the set
--       [market, model, debt_status] adds up to the totals; the labels and their order; the definition version 0009zl
--   A9  the records: the filter debt_status (a key, none, any), the measure under_debt_status, each row's debt status
--   A10 a tenant without debt statuses: the installed base 180's row for row (the new set none alone, under_debt_status 0),
--       the Maintenance reads with the default filter as 116's
--   A11 the setters: the upserts, the default flag and order, an alias removed; every refusal (CMA04, CMA02, CMA06)
--   A12 tenant separation: a tenant sees none of another's debt statuses or aliases
-- Provoke: set provoke below to true; every block must then stop with FAIL, and the verdict says PROVOKED, NOT A PASS. The
-- row-for-row comparisons (A5, A6, A10) are provoked by a deliberate difference on the kept definitions' side (a row left
-- out, another horizon), so each fails on its own, never by the switch alone.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);   -- 'true' to make every block fail

drop table if exists pg_temp.verify_0009zl;
create temp table verify_0009zl (ord int, check_name text, result text, detail text);

-- A statement's SQLSTATE, or ok
create or replace function pg_temp.v0009zl_code(p_sql text)
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

-- The acting context: the application (or the owner), the tenant, a person
create or replace function pg_temp.v0009zl_as(x jsonb, p_who text, p_role text default 'cma_app')
returns void
language sql
as $$
  select set_config('role', p_role, true), set_config('app.tenant_id', x ->> 't', true),
         set_config('app.user_id', x ->> p_who, true), set_config('app.actor_label', '', true);
$$;

-- 116's cma.maintenance_items_of, kept for the comparison (A5, A10)
create or replace function pg_temp.v0009zl_items_0008zk(p_tenant_id uuid, p_today date)
returns table (device_id uuid, connection_id uuid, source_id text, serial text, model_key text, market text, device_status_key text,
               is_in_field boolean, is_in_stock boolean, component_key text, component_order integer, due_on date, basis text,
               action_on date, past_due boolean, exchange_key text, exchange_on date)
language sql stable
as $$
  with s as (
    select greatest(coalesce(nullif(cma.setting_of(p_tenant_id, 'assets.bundle_window_days'), '')::integer, 0), 0) as win,
           date_trunc('month', p_today)::date as month,
           (select t.timezone from cma.tenant t where t.id = p_tenant_id) as zone
  ), d as (
    select dv.id, dv.connection_id, dv.source_id, dv.serial, dv.model_key, dv.market, dv.device_status_key, st.is_in_field, st.is_in_stock,
           coalesce(dv.last_shipped_on, dv.first_shipped_on) as anchor, dv.end_of_life_on
    from cma.device dv
    join cma.device_status st on st.tenant_id = dv.tenant_id and st.key = dv.device_status_key and st.is_tracked
    where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null
  ), rp as (
    -- the devices' kinds with a closed component: their current one is a replacement; with none current, the register
    -- emptied the kind, and the item has no anchor (no due date) until the register holds the kind again
    select distinct p.device_id, p.component_key
    from cma.device_component p
    where p.tenant_id = p_tenant_id and p.replaced_at is not null
  ), it as (
    select d.id, d.connection_id, d.source_id, d.serial, d.model_key, d.market, d.device_status_key, d.is_in_field, d.is_in_stock,
           k.key as component_key, k.sort_order as component_order, c.expires_on as recorded,
           case when ru.interval_months is not null and a.anchor is not null
                then (a.anchor + make_interval(months => ru.interval_months))::date end as by_rule,
           coalesce(ru.lead_days, 0) as lead_days
    from d
    cross join s
    join cma.device_component_kind k on k.tenant_id = p_tenant_id and k.status = 'active'
    left join cma.device_component c
      on c.tenant_id = p_tenant_id and c.device_id = d.id and c.component_key = k.key and c.replaced_at is null
    left join rp on rp.device_id = d.id and rp.component_key = k.key
    left join cma.maintenance_rule ru on ru.tenant_id = p_tenant_id and ru.model_key = d.model_key and ru.component_key = k.key
    cross join lateral (select case when rp.device_id is not null then (c.first_seen_at at time zone s.zone)::date
                                    else d.anchor end as anchor) a
    where c.id is not null or rp.device_id is not null or ru.id is not null or d.model_key is null
    union all
    select d.id, d.connection_id, d.source_id, d.serial, d.model_key, d.market, d.device_status_key, d.is_in_field, d.is_in_stock,
           'device', 2147483647, d.end_of_life_on, null::date, 0
    from d
    where d.end_of_life_on is not null
  ), i as (
    select it.*, coalesce(it.recorded, it.by_rule) as due,
           case when it.recorded is not null then 'recorded' when it.by_rule is not null then 'rule' else 'unknown' end as how,
           coalesce(it.recorded, it.by_rule) - it.lead_days as act
    from it
  ), x as (
    select i.*,
           cma.maintenance_exchange_start(i.act, (select s.win from s))
             over (partition by i.id order by i.act nulls last, i.component_order, i.component_key
                   rows between unbounded preceding and current row) as xstart
    from i
  )
  select x.id, x.connection_id, x.source_id, x.serial, x.model_key, x.market, x.device_status_key, x.is_in_field, x.is_in_stock,
         x.component_key, x.component_order, x.due, x.how, x.act, coalesce(x.act < (select s.month from s), false),
         case when x.act is not null then x.id::text || ':' || to_char(x.xstart, 'YYYY-MM-DD') end,
         case when x.act is not null then x.xstart end
  from x
$$;

-- 180's installed base (cma.flash_compute_of's branch), kept for the comparison (A10)
create or replace function pg_temp.v0009zl_ib_0009p(p_tenant_id uuid)
returns table (dims jsonb, measures jsonb)
language sql stable
as $$
  select case when grouping(b.market) = 1 then '{}'::jsonb
              when grouping(b.status) = 0
              then jsonb_build_object('market', b.market, 'status', b.status, 'model', b.model, 'warehouse', b.warehouse, 'link', b.link)
              when grouping(b.subscription_status) = 0
              then jsonb_build_object('market', b.market, 'model', b.model, 'subscription_status', b.subscription_status)
              else jsonb_build_object('market', b.market) end,
         jsonb_build_object('devices', count(*), 'in_field', count(*) filter (where b.is_in_field),
                            'in_stock', count(*) filter (where b.is_in_stock), 'components_past_due', coalesce(sum(b.past_due_items), 0),
                            'items_due_3m', coalesce(sum(b.items_due_3m), 0),
                            'in_field_on_holding', count(*) filter (where b.is_in_field and b.subscription_status = any (cma.flash_holding_statuses_of(p_tenant_id))))
  from cma.flash_devices_of(p_tenant_id, cma.tenant_today_of(p_tenant_id)) b
  group by grouping sets ((), (b.market), (b.market, b.status, b.model, b.warehouse, b.link), (b.market, b.model, b.subscription_status))
$$;

-- A set of rows as one text, to compare two reads (collate "C": Cloud SQL orders text under en_US)
create or replace function pg_temp.v0009zl_set(p_rows jsonb[])
returns text
language sql immutable
as $$
  select coalesce((select string_agg(x::text, ';' order by x::text collate "C") from unnest(p_rows) x), '')
$$;

-- A throwaway tenant: an admin, an agent, the Ingest user; markets GB and NL; an asset register loaded from files and one
-- read by the ingest; model hs1; the statuses field (in the field) and stock (in stock), both tracked; the component kind
-- pads; with p_statuses the debt statuses in_debt_collection (pauses, 10) and check_first (does not pause, 20) with one
-- alias each; then six devices loaded from a file as the admin (each with pads due 1 June 2026):
--   rec-1 field GB ' in DEBT collection '   rec-2 field GB 'Check first'   rec-3 field NL 'Payment plan' (no alias)
--   rec-4 stock GB 'In debt collection'     rec-5 field GB '' (none)       rec-6 field GB 'x@y.example' (an @)
-- Its ids and the load's answer as jsonb (the role and the acting person left as the admin's)
create or replace function pg_temp.v0009zl_tenant(p_slug text, p_statuses boolean)
returns jsonb
language plpgsql
as $$
declare
  v_t  uuid;
  v_id uuid;
  v    jsonb;
  r    record;
begin
  v_t := cma.create_tenant(p_slug, 'Verify 0009zl', 'Europe/Amsterdam');
  v := jsonb_build_object('t', v_t);
  for r in select * from (values ('admin', 'admin'), ('agent', 'agent')) as x(name, role_key) loop
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, format('verify-0009zl-%s@example.invalid', r.name), r.name) returning id into v_id;
    insert into cma.user_role (tenant_id, user_id, role_id) select v_t, v_id, ar.id from cma.app_role ar where ar.tenant_id = v_t and ar.key = r.role_key;
    v := v || jsonb_build_object(r.name, v_id);
  end loop;
  v := v || jsonb_build_object(
    'ingest', (select x.user_id from cma.app_user_external_id x where x.tenant_id = v_t and x.system = 'ingest' and x.external_id = 'ingest'));
  insert into cma.market (tenant_id, code, name, time_zone, language_code, currency, sort_order) values
    (v_t, 'GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', 10), (v_t, 'NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR', 20);
  for r in select * from (values ('register', 'verifyregister', 'base-1', 'assets', null), ('register2', 'verifyregister', 'base-2', 'assets', 'verify-reg-2'),
                                 ('crm', 'verifycrm', 'portal-1', 'crm', null)) as x(k, adapter, account, kind, secret) loop
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t, r.adapter, 'Verify ' || r.k, r.account, r.kind, r.secret) returning id into v_id;
    v := v || jsonb_build_object(r.k, v_id);
  end loop;
  insert into cma.device_model (tenant_id, key, name, aliases, sort_order) values (v_t, 'hs1', 'HS1', '{}', 10);
  insert into cma.device_status (tenant_id, key, name, is_in_field, is_in_stock, is_tracked, aliases) values
    (v_t, 'field', 'Field', true, false, true, array['field']), (v_t, 'stock', 'Stock', false, true, true, array['stock']);
  insert into cma.device_component_kind (tenant_id, key, name, sort_order) values (v_t, 'pads', 'Pads', 10);
  if p_statuses then
    insert into cma.device_debt_status (tenant_id, key, name, pauses_maintenance, sort_order) values
      (v_t, 'check_first', 'Check first', false, 20), (v_t, 'in_debt_collection', 'In debt collection', true, 10);
    insert into cma.device_debt_status_alias (tenant_id, alias, key) values
      (v_t, 'in debt collection', 'in_debt_collection'), (v_t, 'check first', 'check_first');
  end if;
  perform pg_temp.v0009zl_as(v, 'admin');
  insert into cma.device_import_staging (batch_key, source_row, source_id, serial, model, status, country, components, debt_status) values
    ('v0009zl-load', 2, 'rec-1', 'SN-D1', 'hs1', 'field', 'GB', '{"pads": {"serial": "P-1", "expires_on": "2026-06-01"}}', ' in DEBT collection '),
    ('v0009zl-load', 3, 'rec-2', 'SN-D2', 'hs1', 'field', 'GB', '{"pads": {"serial": "P-2", "expires_on": "2026-06-01"}}', 'Check first'),
    ('v0009zl-load', 4, 'rec-3', 'SN-D3', 'hs1', 'field', 'NL', '{"pads": {"serial": "P-3", "expires_on": "2026-06-01"}}', 'Payment plan'),
    ('v0009zl-load', 5, 'rec-4', 'SN-D4', 'hs1', 'stock', 'GB', '{"pads": {"serial": "P-4", "expires_on": "2026-06-01"}}', 'In debt collection'),
    ('v0009zl-load', 6, 'rec-5', 'SN-D5', 'hs1', 'field', 'GB', '{"pads": {"serial": "P-5", "expires_on": "2026-06-01"}}', ''),
    ('v0009zl-load', 7, 'rec-6', 'SN-D6', 'hs1', 'field', 'GB', '{"pads": {"serial": "P-6", "expires_on": "2026-06-01"}}', 'x@y.example');
  return v || jsonb_build_object('load', cma.load_device_snapshot('v0009zl-load', (v ->> 'register')::uuid, true));
end
$$;

-- The devices' keys and raw labels as one text (the owner's read)
create or replace function pg_temp.v0009zl_keys(x jsonb)
returns text
language sql
as $$
  select string_agg(dv.source_id || '=' || coalesce(dv.debt_status_key, '-') || '/' || coalesce(dv.raw ->> 'debt_status', '-'), ' ' order by dv.source_id collate "C")
  from cma.device dv where dv.tenant_id = (x ->> 't')::uuid and dv.connection_id = (x ->> 'register')::uuid
$$;

-- S1. The addition; the tables' security, the device's column, the staging, the types, the mapping
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_bad     text := '';
  v_tab     text;
begin
  if not exists (select 1 from cma.schema_migration where version = '0009zl') or v_provoke
     or not exists (select 1 from cma.schema_migration where version = '0009zk') then
    raise exception 'FAIL S1: addition 0009zl not recorded after 0009zk';
  end if;
  foreach v_tab in array array['device_debt_status', 'device_debt_status_alias'] loop
    if to_regclass('cma.' || v_tab) is null then
      v_bad := v_bad || v_tab || ' missing; ';
      continue;
    end if;
    if not (select c.relrowsecurity from pg_class c where c.oid = ('cma.' || v_tab)::regclass)
       or not exists (select 1 from pg_policy p where p.polrelid = ('cma.' || v_tab)::regclass and p.polname = 'tenant_app')
       or not exists (select 1 from pg_trigger g where g.tgrelid = ('cma.' || v_tab)::regclass and g.tgname = 'audit' and not g.tgisinternal)
       or not has_table_privilege('cma_app', 'cma.' || v_tab, 'select') or not has_table_privilege('cma_app', 'cma.' || v_tab, 'insert')
       or not has_table_privilege('cma_app', 'cma.' || v_tab, 'update')
       or has_table_privilege('cma_app', 'cma.' || v_tab, 'delete') <> (v_tab = 'device_debt_status_alias')
       or has_table_privilege('cma_readonly', 'cma.' || v_tab, 'select') then
      v_bad := v_bad || v_tab || ' security, audit or grants; ';
    end if;
  end loop;
  if (select string_agg(column_name || ':' || udt_name || ':' || is_nullable, ',') from information_schema.columns
      where table_schema = 'cma' and table_name = 'device' and column_name = 'debt_status_key') is distinct from 'debt_status_key:text:YES'
     or (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.device'::regclass and conname = 'device_debt_status_fkey')
        not like 'FOREIGN KEY (tenant_id, debt_status_key) REFERENCES %device_debt_status(tenant_id, key)'
     or pg_get_indexdef('cma.device_debt_status_idx'::regclass) not like '%(tenant_id, debt_status_key) WHERE (debt_status_key IS NOT NULL)' then
    v_bad := v_bad || 'the device''s column, key or index; ';
  end if;
  if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma' and table_name = 'device_import_staging') not like '%,external_refs,pledge_ref,language,debt_status'
     or (select column_name || ':' || udt_name from information_schema.columns
         where table_schema = 'cma' and table_name = 'device_import_row' and column_name = 'debt_status') is distinct from 'debt_status:text'
     or not exists (select 1 from pg_attribute where attrelid = (select typrelid from pg_type where oid = 'cma.device_load_row'::regtype) and attname = 'debt_status')
     or not exists (select 1 from pg_attribute where attrelid = (select typrelid from pg_type where oid = 'cma.device_load_mapped'::regtype) and attname = 'debt_status') then
    v_bad := v_bad || 'the staging or the types; ';
  end if;
  if (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.connection_field'::regclass and conname = 'connection_field_entity_field_check')
       !~ '''device''.*''language''::text, ''debt_status''::text.*device_component'
     or (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.connection_field'::regclass and conname = 'connection_field_field_check')
       !~ '''pledge_ref''::text, ''debt_status''::text' then
    v_bad := v_bad || 'mapping; ';
  end if;
  if v_bad <> '' then
    raise exception 'FAIL S1: %', v_bad;
  end if;
  insert into verify_0009zl values (1, 'S1 0009zl after 0009zk; two tables with RLS and audit, no delete of a status; the device''s key; staging, types, mapping', 'PASS',
    'device_debt_status, device_debt_status_alias; device_debt_status_fkey, device_debt_status_idx; staging ends with debt_status');
end
$$;

-- S2. The functions' rights and settings; the forms kept
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_bad     text := '';
  v_fn      text;
begin
  foreach v_fn in array array[
    'cma.device_debt_status_key_of(uuid,text)', 'cma.set_device_debt_status(text,text,boolean,integer)', 'cma.set_device_debt_status_alias(text,text)',
    'cma.maintenance_debt_matches(text,text,boolean)', 'cma.assert_maintenance_debt(uuid,text)', 'cma.device_raw_ok(jsonb)',
    'cma.device_rows_apply(uuid,cma.device_load_row[],boolean)', 'cma.device_snapshot_apply(text,uuid,boolean)', 'cma.ingest_load_device_chunk(uuid,jsonb)',
    'cma.maintenance_items_of(uuid,date)', 'cma.maintenance_due_of(date,integer)',
    'cma.maintenance_bucket_dates_of(uuid,date,integer,text,text,text,text,date)', 'cma.maintenance_page_of(uuid,date,integer,text,text,text,text,date)',
    'cma.maintenance_rows_of(uuid,date,integer,text,text,text,text,text,text,integer,date)', 'cma.maintenance_page(date,integer,text,text,text,text)',
    'cma.maintenance_rows(date,integer,text,text,text,text,text,text,integer)',
    'cma.maintenance_bucket_dates_of(uuid,date,integer,text,text,text,date)', 'cma.maintenance_page_of(uuid,date,integer,text,text,text,date)',
    'cma.maintenance_rows_of(uuid,date,integer,text,text,text,text,text,integer,date)', 'cma.maintenance_page(date,integer,text,text,text)',
    'cma.maintenance_rows(date,integer,text,text,text,text,text,integer)',
    'cma.data_quality_assets_checks()', 'cma.data_quality_of(uuid)', 'cma.data_quality_fix_in(text,text)', 'cma.flash_overviews()',
    'cma.flash_compute_of(uuid,text,date,date,date)', 'cma.flash_definition_version(text)', 'cma.flash_labels_of(uuid,text)',
    'cma.flash_rows_of(uuid,text,jsonb,text,boolean,integer,integer,date,date)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure(v_fn) and a.grantee = 0) then
      v_bad := v_bad || v_fn || '; ';
    end if;
  end loop;
  foreach v_fn in array array['cma.data_quality_of(uuid)', 'cma.flash_compute_of(uuid,text,date,date,date)',
                              'cma.flash_rows_of(uuid,text,jsonb,text,boolean,integer,integer,date,date)'] loop
    if array_position((select proconfig from pg_proc where oid = to_regprocedure(v_fn)), 'jit=off') is null then
      v_bad := v_bad || v_fn || ' without jit = off; ';
    end if;
  end loop;
  if (select pronargdefaults from pg_proc where oid = 'cma.maintenance_page(date,integer,text,text,text,text)'::regprocedure) <> 0
     or (select pronargdefaults from pg_proc where oid = 'cma.maintenance_rows(date,integer,text,text,text,text,text,text,integer)'::regprocedure) <> 0 then
    v_bad := v_bad || 'a new public form with a default; ';
  end if;
  if (select count(*) from information_schema.routines r join information_schema.columns c on false where false) <> 0
     or (select array_length(proallargtypes, 1) from pg_proc where oid = 'cma.maintenance_due_of(date,integer)'::regprocedure) <> 2 + 17 then
    v_bad := v_bad || 'maintenance_due_of''s columns; ';
  end if;
  if v_bad <> '' or v_provoke then
    raise exception 'FAIL S2: %', coalesce(nullif(v_bad, ''), 'provoked');
  end if;
  insert into verify_0009zl values (2, 'S2 every function the application''s, the caller''s rights; JIT off kept; 112''s and 116''s forms kept; maintenance_due_of 17 columns', 'PASS',
    '29 functions; data_quality_of, flash_compute_of, flash_rows_of jit = off; the new public forms without defaults');
end
$$;

-- A1 to A4. The load and data quality
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  x         jsonb;
  j         jsonb;
  v_bad     text;
begin
  begin
    x := pg_temp.v0009zl_tenant('verify-0009zl-a1', true);
    perform set_config('role', 'cma_owner', true);
    -- A1. mapped, unmapped and counted, empty, an @ never stored
    v_bad := pg_temp.v0009zl_keys(x);
    if v_bad is distinct from 'rec-1=in_debt_collection/in DEBT collection rec-2=check_first/Check first rec-3=-/Payment plan rec-4=in_debt_collection/In debt collection rec-5=-/- rec-6=-/-'
       or (x -> 'load' ->> 'inserted')::int <> 6 or (x -> 'load' ->> 'unmapped_debt_status')::int <> 1
       or (select (r.counts ->> 'unmapped_debt_status')::int from cma.sync_run r
           where r.tenant_id = (x ->> 't')::uuid and r.job = 'assets_import' and r.stream = 'v0009zl-load') is distinct from 1
       or v_provoke then
      raise exception 'FAIL A1: % (%)', v_bad, x -> 'load';
    end if;
    v_rows := v_rows || array['10', 'A1 the file path: a label mapped trimmed and case-insensitively, one unmapped and counted, an empty field and an @ null', 'PASS',
      v_bad || '; inserted 6, unmapped_debt_status 1 (the answer and the run''s counts)'];

    -- A2. an unchanged rerun; an emptied field clears the key; an alias added later maps the label
    perform pg_temp.v0009zl_as(x, 'admin');
    insert into cma.device_import_staging (batch_key, source_row, source_id, serial, model, status, country, components, debt_status)
    select 'v0009zl-rerun', s.source_row, s.source_id, s.serial, s.model, s.status, s.country, s.components, s.debt_status
    from (values (2, 'rec-1', 'SN-D1', 'hs1', 'field', 'GB', '{"pads": {"serial": "P-1", "expires_on": "2026-06-01"}}', ' in DEBT collection '),
                 (3, 'rec-2', 'SN-D2', 'hs1', 'field', 'GB', '{"pads": {"serial": "P-2", "expires_on": "2026-06-01"}}', 'Check first'),
                 (4, 'rec-3', 'SN-D3', 'hs1', 'field', 'NL', '{"pads": {"serial": "P-3", "expires_on": "2026-06-01"}}', 'Payment plan'),
                 (5, 'rec-4', 'SN-D4', 'hs1', 'stock', 'GB', '{"pads": {"serial": "P-4", "expires_on": "2026-06-01"}}', 'In debt collection'),
                 (6, 'rec-5', 'SN-D5', 'hs1', 'field', 'GB', '{"pads": {"serial": "P-5", "expires_on": "2026-06-01"}}', ''),
                 (7, 'rec-6', 'SN-D6', 'hs1', 'field', 'GB', '{"pads": {"serial": "P-6", "expires_on": "2026-06-01"}}', 'x@y.example'))
         as s(source_row, source_id, serial, model, status, country, components, debt_status);
    j := cma.load_device_snapshot('v0009zl-rerun', (x ->> 'register')::uuid, true);
    if (j ->> 'unchanged')::int <> 6 or (j ->> 'updated')::int <> 0 then
      raise exception 'FAIL A2: the rerun %', j;
    end if;
    insert into cma.device_import_staging (batch_key, source_row, source_id, serial, model, status, country, components, debt_status) values
      ('v0009zl-empty', 2, 'rec-1', 'SN-D1', 'hs1', 'field', 'GB', '{"pads": {"serial": "P-1", "expires_on": "2026-06-01"}}', '');
    j := cma.load_device_snapshot('v0009zl-empty', (x ->> 'register')::uuid, false);
    if (j ->> 'updated')::int <> 1 then
      raise exception 'FAIL A2: the emptied field %', j;
    end if;
    perform cma.set_device_debt_status('to_be_submitted', 'To be submitted', true, 30);
    perform cma.set_device_debt_status_alias(' Payment PLAN ', 'to_be_submitted');
    insert into cma.device_import_staging (batch_key, source_row, source_id, serial, model, status, country, components, debt_status) values
      ('v0009zl-alias', 4, 'rec-3', 'SN-D3', 'hs1', 'field', 'NL', '{"pads": {"serial": "P-3", "expires_on": "2026-06-01"}}', 'Payment plan');
    j := cma.load_device_snapshot('v0009zl-alias', (x ->> 'register')::uuid, false);
    perform set_config('role', 'cma_owner', true);
    v_bad := pg_temp.v0009zl_keys(x);
    if v_bad is distinct from 'rec-1=-/- rec-2=check_first/Check first rec-3=to_be_submitted/Payment plan rec-4=in_debt_collection/In debt collection rec-5=-/- rec-6=-/-'
       or (j ->> 'updated')::int <> 1 or (j ->> 'unmapped_debt_status')::int <> 0 then
      raise exception 'FAIL A2: % (%)', v_bad, j;
    end if;
    v_rows := v_rows || array['11', 'A2 an unchanged rerun changes nothing; an emptied field clears the key; an alias added later maps the label', 'PASS',
      'rerun 6 unchanged; then ' || v_bad];

    -- A3. the chunk path as the Ingest user; the field mapped on an asset register only
    perform pg_temp.v0009zl_as(x, 'ingest');
    j := cma.ingest_load_device_chunk((x ->> 'register2')::uuid,
      '[{"source_row": 2, "source_id": "rec-c1", "serial": "SN-C1", "model": "hs1", "status": "field", "country": "GB", "debt_status": "Check FIRST"},
        {"source_row": 3, "source_id": "rec-c2", "serial": "SN-C2", "model": "hs1", "status": "field", "country": "GB"}]'::jsonb);
    perform set_config('role', 'cma_owner', true);
    select string_agg(dv.source_id || '=' || coalesce(dv.debt_status_key, '-'), ' ' order by dv.source_id collate "C") into v_bad
    from cma.device dv where dv.tenant_id = (x ->> 't')::uuid and dv.connection_id = (x ->> 'register2')::uuid;
    perform pg_temp.v0009zl_as(x, 'ingest');
    v_bad := v_bad || ' ' || pg_temp.v0009zl_code(format('select cma.ingest_load_device_chunk(%L, %L::jsonb)', x ->> 'register2',
                                jsonb_build_array(jsonb_build_object('source_row', 2, 'source_id', 'rec-c3', 'debt_status', repeat('x', 501)))));
    perform pg_temp.v0009zl_as(x, 'admin');
    v_bad := v_bad || ' ' || pg_temp.v0009zl_code(format('select cma.set_connection_field(%L, ''device'', ''debt_status'', '''', ''debt_status'', 1::smallint)', x ->> 'register'))
             || ' ' || pg_temp.v0009zl_code(format('select cma.set_connection_field(%L, ''device'', ''debt_status'', '''', ''debt_status'', 1::smallint)', x ->> 'crm'));
    if v_bad is distinct from 'rec-c1=check_first rec-c2=- CMA04 ok CMA04' or (j ->> 'inserted')::int <> 2 then
      raise exception 'FAIL A3: % (%)', v_bad, j;
    end if;
    v_rows := v_rows || array['12', 'A3 the chunk path: the key taken, a row without it empty, a value too long refused; the field mapped on an asset register only', 'PASS', v_bad];

    -- A4. data quality: the unmapped label alone (rec-3 is mapped now: a label of its own)
    perform set_config('role', 'cma_owner', true);
    update cma.device dv set raw = dv.raw || '{"debt_status": "Promise to pay"}', debt_status_key = null
    where dv.tenant_id = (x ->> 't')::uuid and dv.source_id = 'rec-5';
    v_bad := (select string_agg(f.object_id || ':' || f.value, ' ' order by f.object_id collate "C") from cma.data_quality_of((x ->> 't')::uuid) f
              where f.check_key = 'device_debt_status_unmapped')
             || ' ' || (select c.sort_order || ':' || cma.data_quality_fix_in(c.check_key, null) from cma.data_quality_assets_checks() c
                        where c.check_key = 'device_debt_status_unmapped')
             || ' ' || (select f.market from cma.flash_findings_compute_of((x ->> 't')::uuid) f where f.check_key = 'device_debt_status_unmapped');
    if v_bad is distinct from 'rec-5:Promise to pay 305:assets GB' then
      raise exception 'FAIL A4: %', v_bad;
    end if;
    v_rows := v_rows || array['13', 'A4 data quality: device_debt_status_unmapped lists the unmapped label with the device''s market; 305, fixed in the asset register', 'PASS', v_bad];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
  insert into verify_0009zl select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
end
$$;

-- A5 to A9. Maintenance and the installed base
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  x         jsonb;
  j         jsonb;
  v_t       uuid;
  v_bad     text;
  v_txt     text;
  v_d       text;
begin
  begin
    x := pg_temp.v0009zl_tenant('verify-0009zl-a5', true);
    v_t := (x ->> 't')::uuid;
    perform set_config('role', 'cma_owner', true);
    -- A5. every item kept; paused only in the field under a pausing status; the other columns 116's
    v_bad := (select string_agg(i.source_id || ':' || i.component_key || ':' || coalesce(i.debt_status_key, '-') || ':' || i.maintenance_paused, ' '
                                order by i.source_id collate "C", i.component_key collate "C")
              from cma.maintenance_items_of(v_t, '2026-11-23') i);
    v_txt := (select pg_temp.v0009zl_set(array_agg(to_jsonb(i) - 'debt_status_key' - 'maintenance_paused'))
              from cma.maintenance_items_of(v_t, '2026-11-23') i);
    if v_bad is distinct from 'rec-1:pads:in_debt_collection:true rec-2:pads:check_first:false rec-3:pads:-:false rec-4:pads:in_debt_collection:false rec-5:pads:-:false rec-6:pads:-:false'
       -- provoked: 116's side without rec-1's item, a deliberate difference the comparison must catch
       or v_txt is distinct from (select pg_temp.v0009zl_set(array_agg(to_jsonb(i))) from pg_temp.v0009zl_items_0008zk(v_t, '2026-11-23') i
                                  where not (v_provoke and i.source_id = 'rec-1')) then
      raise exception 'FAIL A5: % (or the comparison with 116''s)', v_bad;
    end if;
    v_rows := v_rows || array['20', 'A5 every item kept; paused only in the field under a status that pauses; the other columns 116''s row for row', 'PASS', v_bad];

    -- A6. the filter: null as 116's forms; unpaused, none, any, a key; a row marked paused; the catalog's order
    j := cma.maintenance_page_of(v_t, '2026-11-01', 12, null, null, null, null, '2026-11-23');
    -- provoked: 116's page of a horizon of 6 months, a deliberate difference the comparison must catch
    if j - 'maintenance_paused_devices' - 'debt' - 'debt_statuses'
       is distinct from cma.maintenance_page_of(v_t, '2026-11-01', case when v_provoke then 6 else 12 end, null, null, null, '2026-11-23')
       or (select pg_temp.v0009zl_set(array_agg(to_jsonb(r) - 'debt_status_key' - 'maintenance_paused'))
           from cma.maintenance_rows_of(v_t, '2026-11-01', 12, 'all', null, null, null, null, 'exchanges', 500, '2026-11-23') r)
          is distinct from (select pg_temp.v0009zl_set(array_agg(to_jsonb(r)))
                            from cma.maintenance_rows_of(v_t, '2026-11-01', 12, 'all', null, null, null, 'exchanges', 500, '2026-11-23') r) then
      raise exception 'FAIL A6: null is not 116''s';
    end if;
    v_bad := '';
    foreach v_d in array array['unpaused', 'none', 'any', 'in_debt_collection', 'check_first'] loop
      j := cma.maintenance_page_of(v_t, '2026-11-01', 12, null, null, null, v_d, '2026-11-23');
      v_bad := v_bad || v_d || '=' || (j ->> 'devices') || '/' || (j ->> 'maintenance_paused_devices') || '/'
               || (select string_agg(r.source_id || case when r.maintenance_paused then '!' else '' end, ',' order by r.source_id collate "C")
                   from cma.maintenance_rows_of(v_t, '2026-11-01', 12, 'past_due', null, null, null, v_d, 'components', 500, '2026-11-23') r) || ' ';
    end loop;
    v_bad := v_bad || (select string_agg(e ->> 'key' || ':' || (e ->> 'pauses_maintenance'), ',' order by o)
                       from jsonb_array_elements(j -> 'debt_statuses') with ordinality q(e, o));
    if v_bad is distinct from 'unpaused=5/1/rec-2,rec-3,rec-4,rec-5,rec-6 none=3/1/rec-3,rec-5,rec-6 any=3/1/rec-1!,rec-2,rec-4 '
                               || 'in_debt_collection=2/1/rec-1!,rec-4 check_first=1/1/rec-2 in_debt_collection:true,check_first:false' then
      raise exception 'FAIL A6: %', v_bad;
    end if;
    v_rows := v_rows || array['21', 'A6 the Maintenance filter: null as 116''s; unpaused, none, any, a key (devices/paused_devices/rows, ! paused); the catalog''s order', 'PASS', v_bad];

    -- A7. the public reads (the tenant's today), as the admin; refusals; 112's forms as before
    perform pg_temp.v0009zl_as(x, 'admin');
    v_d := date_trunc('month', cma.tenant_today_of(v_t))::date::text;
    j := cma.maintenance_page(v_d::date, 12, null, null, null, 'unpaused');
    v_bad := (j ->> 'devices') || '/' || (j ->> 'maintenance_paused_devices') || '/' || (j ->> 'debt')
             || ' ' || (select count(*) from cma.maintenance_rows(v_d::date, 12, 'all', null, null, null, 'in_debt_collection', 'components', 500))
             || ' ' || (cma.maintenance_page(v_d::date) ->> 'devices')
             || ' ' || pg_temp.v0009zl_code(format('select cma.maintenance_page(%L, 12, null, null, null, ''paused'')', v_d))
             || ' ' || pg_temp.v0009zl_code(format('select * from cma.maintenance_rows(%L, 12, ''all'', null, null, null, ''In debt collection'', ''exchanges'', 10)', v_d));
    perform pg_temp.v0009zl_as(x, 'agent');
    v_bad := v_bad || ' ' || pg_temp.v0009zl_code(format('select cma.maintenance_page(%L, 12, null, null, null, ''unpaused'')', v_d))
             || ' ' || pg_temp.v0009zl_code(format('select * from cma.maintenance_rows(%L, 12, ''all'', null, null, null, null, ''exchanges'', 10)', v_d));
    perform set_config('role', 'cma_owner', true);
    if v_bad is distinct from '5/1/unpaused 2 6 CMA04 CMA04 CMA06 CMA06' then
      raise exception 'FAIL A7: %', v_bad;
    end if;
    v_rows := v_rows || array['22', 'A7 the public page and list with the filter; an unknown filter CMA04; the agent CMA06; 112''s page every device', 'PASS', v_bad];

    -- A8. the take: under_debt_status in the field only; the set adds up; labels, order, version
    select string_agg(coalesce(c.dims ->> 'market', '*') || '/' || coalesce(c.dims ->> 'model', '*') || '/' || (c.dims ->> 'debt_status') || ':'
                      || (c.measures ->> 'devices') || ',' || (c.measures ->> 'in_field') || ',' || (c.measures ->> 'under_debt_status'),
                      ' ' order by c.dims::text collate "C") into v_bad
    from cma.flash_compute_of(v_t, 'installed_base') c where c.dims ? 'debt_status';
    v_bad := v_bad || ' | ' || (select c.measures ->> 'under_debt_status' from cma.flash_compute_of(v_t, 'installed_base') c where c.dims = '{}'::jsonb)
             || ' ' || (select string_agg(c.dims ->> 'market' || ':' || (c.measures ->> 'under_debt_status'), ',' order by c.dims ->> 'market' collate "C")
                        from cma.flash_compute_of(v_t, 'installed_base') c where c.dims - 'market' = '{}'::jsonb and c.dims ? 'market')
             || ' | ' || (cma.flash_labels_of(v_t, 'installed_base') -> 'debt_status')::text
             || ' ' || (cma.flash_labels_of(v_t, 'installed_base') -> 'debt_status_order')::text
             || ' ' || cma.flash_definition_version('installed_base') || ' ' || cma.flash_definition_version('subscriptions');
    -- every measure of the set adds up to its market's row
    if exists (select 1 from cma.flash_compute_of(v_t, 'installed_base') m cross join lateral jsonb_each(m.measures) e
               where m.dims - 'market' = '{}'::jsonb and m.dims ? 'market'
                 and (e.value #>> '{}')::numeric <> (select sum((s.measures ->> e.key)::numeric) from cma.flash_compute_of(v_t, 'installed_base') s
                                                     where s.dims ? 'debt_status' and s.dims ->> 'market' = m.dims ->> 'market')) then
      v_bad := v_bad || ' the set does not add up';
    end if;
    if v_bad is distinct from 'GB/hs1/check_first:1,1,1 GB/hs1/in_debt_collection:2,1,1 GB/hs1/none:2,2,0 NL/hs1/none:1,1,0 | 2 GB:2,NL:0 | '
                              || '{"check_first": "Check first", "in_debt_collection": "In debt collection"} {"check_first": "20", "in_debt_collection": "10"} 0009zl 0009ze' then
      raise exception 'FAIL A8: %', v_bad;
    end if;
    v_rows := v_rows || array['23', 'A8 the take: under_debt_status in the field only, the set [market, model, debt_status] adding up; labels, order, version 0009zl', 'PASS', v_bad];

    -- A9. the records: the filter, the measure, each row's debt status (as the admin)
    perform pg_temp.v0009zl_as(x, 'admin');
    v_bad := '';
    foreach v_d in array array['{"debt_status": "in_debt_collection"}', '{"debt_status": "none"}', '{"debt_status": "any"}',
                               '{"measure": "under_debt_status"}', '{"debt_status": "check_first", "measure": "in_field"}'] loop
      j := cma.flash_rows('installed_base', v_d::jsonb, 'serial', false, 500, 0);
      v_bad := v_bad || (j ->> 'total') || ':' || coalesce((select string_agg(r ->> 'device_id' || '=' || coalesce(r ->> 'debt_status', '-'), ',' order by o)
                                                           from jsonb_array_elements(j -> 'rows') with ordinality q(r, o)), '') || ' ';
    end loop;
    perform set_config('role', 'cma_owner', true);
    if v_bad is distinct from '2:rec-1=in_debt_collection,rec-4=in_debt_collection 3:rec-3=-,rec-5=-,rec-6=- 3:rec-1=in_debt_collection,rec-2=check_first,rec-4=in_debt_collection '
                              || '2:rec-1=in_debt_collection,rec-2=check_first 1:rec-2=check_first ' then
      raise exception 'FAIL A9: %', v_bad;
    end if;
    v_rows := v_rows || array['24', 'A9 the records: debt_status a key, none, any; the measure under_debt_status; each row''s debt status', 'PASS', v_bad];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
  insert into verify_0009zl select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
end
$$;

-- A10 to A12. A tenant without debt statuses; the setters; tenant separation
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  x         jsonb;
  y         jsonb;
  v_t       uuid;
  v_bad     text;
begin
  begin
    -- A10. without debt statuses: the installed base 180's, the new set none alone; Maintenance's default as 116's
    x := pg_temp.v0009zl_tenant('verify-0009zl-a10', false);
    v_t := (x ->> 't')::uuid;
    perform set_config('role', 'cma_owner', true);
    v_bad := (select string_agg(distinct c.dims ->> 'debt_status', ',') from cma.flash_compute_of(v_t, 'installed_base') c where c.dims ? 'debt_status')
             || ' ' || (select sum((c.measures ->> 'under_debt_status')::int) from cma.flash_compute_of(v_t, 'installed_base') c)
             || ' ' || (x -> 'load' ->> 'unmapped_debt_status');
    if (select pg_temp.v0009zl_set(array_agg(jsonb_build_object('d', c.dims, 'm', c.measures - 'under_debt_status')))
        from cma.flash_compute_of(v_t, 'installed_base') c where not (c.dims ? 'debt_status'))
       -- provoked: 180's side without its totals row, a deliberate difference the comparison must catch
       is distinct from (select pg_temp.v0009zl_set(array_agg(jsonb_build_object('d', o.dims, 'm', o.measures))) from pg_temp.v0009zl_ib_0009p(v_t) o
                         where not (v_provoke and o.dims = '{}'::jsonb))
       or cma.maintenance_page_of(v_t, '2026-11-01', 12, null, null, null, 'unpaused', '2026-11-23') - 'maintenance_paused_devices' - 'debt' - 'debt_statuses'
          is distinct from cma.maintenance_page_of(v_t, '2026-11-01', 12, null, null, null, '2026-11-23')
       or (select pg_temp.v0009zl_set(array_agg(to_jsonb(r) - 'debt_status_key' - 'maintenance_paused'))
           from cma.maintenance_rows_of(v_t, '2026-11-01', 12, 'all', null, null, null, 'unpaused', 'components', 500, '2026-11-23') r)
          is distinct from (select pg_temp.v0009zl_set(array_agg(to_jsonb(r)))
                            from cma.maintenance_rows_of(v_t, '2026-11-01', 12, 'all', null, null, null, 'components', 500, '2026-11-23') r)
       or (select pg_temp.v0009zl_set(array_agg(to_jsonb(i) - 'debt_status_key' - 'maintenance_paused')) from cma.maintenance_items_of(v_t, '2026-11-23') i)
          is distinct from (select pg_temp.v0009zl_set(array_agg(to_jsonb(i))) from pg_temp.v0009zl_items_0008zk(v_t, '2026-11-23') i)
       or v_bad is distinct from 'none 0 4' then
      raise exception 'FAIL A10: % (the comparisons or the counts)', v_bad;
    end if;
    v_rows := v_rows || array['30', 'A10 a tenant without debt statuses: the installed base 180''s row for row, the new set none alone; Maintenance''s default 116''s', 'PASS',
      v_bad || ' (debt_status values, under_debt_status summed, unmapped labels counted)'];

    -- A11. the setters
    perform pg_temp.v0009zl_as(x, 'admin');
    -- each read in a statement of its own (a statement's snapshot does not see the writes of the calls within it)
    v_bad := cma.set_device_debt_status(' Write_Off_Restart ', ' Write off + restart ', null, null);
    v_bad := v_bad || ' ' || (select s.pauses_maintenance || ':' || s.sort_order from cma.device_debt_status s where s.key = 'write_off_restart');
    v_bad := v_bad || ' ' || cma.set_device_debt_status('write_off_restart', 'Write off + restart', false, 40);
    v_bad := v_bad || ' ' || cma.set_device_debt_status_alias(' Write off + RESTART ', 'write_off_restart');
    v_bad := v_bad || ' ' || coalesce(cma.device_debt_status_key_of(v_t, 'write off + restart'), '-');
    v_bad := v_bad || ' ' || cma.set_device_debt_status_alias('write off + restart', '');
    v_bad := v_bad || ' ' || coalesce(cma.device_debt_status_key_of(v_t, 'write off + restart'), '-')
             || ' ' || (select s.name || ':' || s.pauses_maintenance || ':' || s.sort_order from cma.device_debt_status s where s.key = 'write_off_restart')
             || ' ' || pg_temp.v0009zl_code('select cma.set_device_debt_status(''none'', ''None'', true, 1)')
             || ' ' || pg_temp.v0009zl_code('select cma.set_device_debt_status(''bad key'', ''Bad'', true, 1)')
             || ' ' || pg_temp.v0009zl_code('select cma.set_device_debt_status(''ok_key'', '' '', true, 1)')
             || ' ' || pg_temp.v0009zl_code('select cma.set_device_debt_status(''ok_key'', ''a@b'', true, 1)')
             || ' ' || pg_temp.v0009zl_code('select cma.set_device_debt_status_alias(''Some label'', ''nope'')')
             || ' ' || pg_temp.v0009zl_code('select cma.set_device_debt_status_alias('' '', ''write_off_restart'')')
             || ' ' || pg_temp.v0009zl_code('delete from cma.device_debt_status');
    perform pg_temp.v0009zl_as(x, 'agent');
    v_bad := v_bad || ' ' || pg_temp.v0009zl_code('select cma.set_device_debt_status(''ok_key'', ''Ok'', true, 1)')
             || ' ' || pg_temp.v0009zl_code('select cma.set_device_debt_status_alias(''label'', '''')');
    perform set_config('role', 'cma_owner', true);
    if v_bad is distinct from 'write_off_restart true:100 write_off_restart write off + restart write_off_restart write off + restart - Write off + restart:false:40 '
                              || 'CMA04 CMA04 CMA04 CMA04 CMA02 CMA04 42501 CMA06 CMA06' then
      raise exception 'FAIL A11: %', v_bad;
    end if;
    v_rows := v_rows || array['31', 'A11 the setters: upserts, the default flag and order, an alias removed; CMA04, CMA02, no delete for the application, CMA06', 'PASS', v_bad];

    -- A12. tenant separation: tenant two sees none of tenant one's statuses or aliases
    y := pg_temp.v0009zl_tenant('verify-0009zl-a12', true);
    perform pg_temp.v0009zl_as(x, 'admin');
    v_bad := (select count(*) from cma.device_debt_status)::text || '/' || (select count(*) from cma.device_debt_status_alias)
             || ' ' || coalesce(cma.device_debt_status_key_of((x ->> 't')::uuid, 'in debt collection'), '-');
    perform pg_temp.v0009zl_as(y, 'admin');
    v_bad := v_bad || ' ' || (select count(*) from cma.device_debt_status)::text || '/' || (select count(*) from cma.device_debt_status_alias)
             || ' ' || (select string_agg(s.key, ',' order by s.key collate "C") from cma.device_debt_status s);
    perform set_config('role', 'cma_owner', true);
    if v_bad is distinct from '1/0 - 2/2 check_first,in_debt_collection' then
      raise exception 'FAIL A12: %', v_bad;
    end if;
    v_rows := v_rows || array['32', 'A12 tenant separation: each tenant sees its own debt statuses and aliases only', 'PASS', v_bad];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
  insert into verify_0009zl select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
end
$$;

-- Verdict: one row per check that passed, then the verdict (14 checks; a block that stopped counts its checks as FAIL)
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0009zl
      union all
      select 999, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0009zl where result = 'PASS') = 14 then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0009zl where result = 'PASS'),
                                        14 - (select count(*) from verify_0009zl where result = 'PASS'))) x
order by ord;
drop function if exists pg_temp.v0009zl_keys(jsonb);
drop function if exists pg_temp.v0009zl_tenant(text, boolean);
drop function if exists pg_temp.v0009zl_set(jsonb[]);
drop function if exists pg_temp.v0009zl_ib_0009p(uuid);
drop function if exists pg_temp.v0009zl_items_0008zk(uuid, date);
drop function if exists pg_temp.v0009zl_as(jsonb, text, text);
drop function if exists pg_temp.v0009zl_code(text);
drop table if exists pg_temp.verify_0009zl;
reset role;
