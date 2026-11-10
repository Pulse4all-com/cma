-- =============================================================================================
-- 169_verify_pledge_lists.sql: verifies addition 0009j, Assets → Pledge lists
-- =============================================================================================
-- Universal: no seed is assumed. Block S checks the addition, the tables, the triggers, the grants and the functions'
-- rights; blocks A1 to A7 each work on throwaway tenants (Europe/Amsterdam) inside a subtransaction that is always
-- rolled back, so nothing stays and the script runs in dev and in prod. Lenders are fake labels (Lender A, B, C), people
-- are synthetic (example.invalid), devices, serials, customers and subscriptions invented ids: no investor's name, no
-- customer's name, address, email or phone number, and nothing of a real tenant is read or printed. Fixed instants and
-- valuation dates, so the verdict never depends on the day it runs (take_current's quarter is computed from today and
-- checked against it). Cloud SQL Studio shows no notices: a check that fails raises "FAIL …" and stops its block; every
-- check that passed writes one row, and the last row is the verdict: "PASS | 23 PASS, 0 FAIL" (provoked: "PROVOKED, NOT
-- A PASS"). A block that stopped counts its checks as FAIL; the verdict is reached only when the client goes on after an
-- error (psql -v ON_ERROR_STOP=0, as the provoked run does). Run as your own IAM login after 168_pledge_lists.sql; then
-- 27, 113, 115, 117 (dev and local only), 123, 85, 99, 137 and 161 again.
--   S1  0009j recorded after 0009i; the five tables with row-level security and the tenant policy, the audit trigger on
--       all but the quarter files' rows, the frozen triggers (update, delete, truncate) on both quarter-file tables; the
--       application reads the quarter files and writes neither; the readers see none of the five
--   S2  cma.device's two columns with their checks and the partial index; the staging's two columns; the load's row types'
--       attributes; connection_field's checks with pledge_ref and language for a device; the two settings with their
--       defaults; the permissions pledges.view and pledges.snapshot; every tenant's scheduler role holds pledges.snapshot
--   S3  every function the application's only and in the caller's rights, but the two takes (SECURITY DEFINER, cma_owner,
--       search path pinned) and their bodies (the owner's alone); the load functions carry the two fields
--   A1  the load: the file path (staged as a person, an @ kept as a bare @) and the chunk path (as the Ingest user): the
--       loan reference trimmed, kept as an id or dropped and counted, the language's label mapped, unmapped and counted,
--       raw keeping both; an unchanged rerun; an alias added later maps the label on the next load; a chunk without the
--       keys loads both empty; an unknown key and a value too long refused
--   A2  language aliases: trimmed and lower-cased, matched case-insensitively, an unmapped or empty label null, a code
--       of two letters, an empty code removes the alias, refusals
--   A3  the month and value rules: 14, 12 and 32 months at 9 October 2026; 0 without a shipment or after the date;
--       845 / 5.03 over 14 months 774.58; never below 0; empty without values
--   A4  the rows at 1 October 2026: per device of two active loans (one of layout 2), In Storage, the Start date by the
--       link in the tenant's zone (the first by id when two stores of the market share a reference), an unknown loan and an
--       inactive loan left out, a missing device left out, a model without values empty, a reference that is no id; the
--       link equal to the installed base's (cma.flash_devices_of) for every device
--   A5  the take: not due before 00:05 local and on any other day, taken at 00:05 local once (already_taken after, also
--       by an instant in UTC), the winter quarter by its local day, the setting moved, no_pledges; the frozen copy (the
--       labels kept after the catalog changes, the rows equal to the rows of the day); immutable (update, delete,
--       truncate refused for the owner, any write refused for the application); one audit row for the file, none per
--       row; take_current; the job's entry
--   A6  the reads (pledges.view): the page (files, today per loan with its sums, the checks, the unmapped labels, the
--       quarter), a check's serials, a stored file, today's file; every refusal: without pledges.view, the setters
--       without tenant.configure, the takes without their permission or for another tenant, the bodies not the
--       application's; no assignable role of a new tenant holds either permission
--   A7  the catalogs' setters and the settings: every refusal of set_pledge_loan and set_pledge_model_value, the upserts,
--       the settings' forms; the register's two fields mapped on an asset register connection only; the loan's audit
--       images without the lender label (cma.audit_row(), D8)
-- Provoke: set provoke below to true; every block must then stop with FAIL, and the verdict says PROVOKED, NOT A PASS.
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

drop table if exists pg_temp.verify_0009j;
create temp table verify_0009j (ord int, check_name text, result text, detail text);

-- An instant in the tenant's zone
create or replace function pg_temp.v0009j_at(p_local text)
returns timestamptz
language sql stable
as $$
  select p_local::timestamp at time zone 'Europe/Amsterdam'
$$;

-- A statement's SQLSTATE, or ok
create or replace function pg_temp.v0009j_code(p_sql text)
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

-- The acting context: the application (or the owner, for the take's body), the tenant, a person
create or replace function pg_temp.v0009j_as(x jsonb, p_who text, p_role text default 'cma_app')
returns void
language sql
as $$
  select set_config('role', p_role, true), set_config('app.tenant_id', x ->> 't', true),
         set_config('app.user_id', x ->> p_who, true), set_config('app.actor_label', '', true);
$$;

-- A throwaway tenant: an admin, an agent, a viewer (a role holding pledges.view alone), the scheduler and the Ingest
-- user; markets GB and NL; an asset register loaded from files and one read by the ingest (a token secret name); two
-- stores of GB and one of NL, each with a subscriptions connection; models hs1, g5 and frx; the statuses field and
-- stock. Its ids as jsonb
create or replace function pg_temp.v0009j_tenant(p_slug text)
returns jsonb
language plpgsql
as $$
declare
  v_t  uuid;
  v_id uuid;
  v    jsonb;
  r    record;
begin
  v_t := cma.create_tenant(p_slug, 'Verify 0009j', 'Europe/Amsterdam');
  v := jsonb_build_object('t', v_t);
  for r in select * from (values ('admin', 'admin'), ('agent', 'agent')) as x(name, role_key) loop
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, format('verify-0009j-%s@example.invalid', r.name), r.name) returning id into v_id;
    insert into cma.user_role (tenant_id, user_id, role_id) select v_t, v_id, ar.id from cma.app_role ar where ar.tenant_id = v_t and ar.key = r.role_key;
    v := v || jsonb_build_object(r.name, v_id);
  end loop;
  insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-0009j-viewer@example.invalid', 'viewer') returning id into v_id;
  v := v || jsonb_build_object('viewer', v_id);
  insert into cma.app_role (tenant_id, key, name) values (v_t, 'verify_pledges', 'Verify pledges') returning id into v_id;
  insert into cma.role_permission (tenant_id, role_id, permission_key) values (v_t, v_id, 'pledges.view');
  insert into cma.user_role (tenant_id, user_id, role_id) values (v_t, (v ->> 'viewer')::uuid, v_id);
  v := v || jsonb_build_object(
    'scheduler', (select u.id from cma.app_user u where u.tenant_id = v_t and u.email = 'scheduler@system.invalid'),
    'ingest', (select x.user_id from cma.app_user_external_id x where x.tenant_id = v_t and x.system = 'ingest' and x.external_id = 'ingest'));
  insert into cma.market (tenant_id, code, name, time_zone, language_code, currency, sort_order) values
    (v_t, 'GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', 10), (v_t, 'NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR', 20);
  for r in select * from (values ('register', 'verifyregister', 'base-1', 'assets', null), ('register2', 'verifyregister', 'base-2', 'assets', 'verify-reg-2'),
                                 ('crm', 'verifycrm', 'portal-1', 'crm', null),
                                 ('gb1', 'verifyshop', 'shop-gb1.shop.example', 'commerce', null), ('gb2', 'verifyshop', 'shop-gb2.shop.example', 'commerce', null),
                                 ('nl', 'verifyshop', 'shop-nl.shop.example', 'commerce', null),
                                 ('sgb1', 'verifysubs', 'shop-gb1.shop.example', 'subscriptions', 'verify-subs-gb1'),
                                 ('sgb2', 'verifysubs', 'shop-gb2.shop.example', 'subscriptions', 'verify-subs-gb2'),
                                 ('snl', 'verifysubs', 'shop-nl.shop.example', 'subscriptions', 'verify-subs-nl')) as x(k, adapter, account, kind, secret) loop
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t, r.adapter, 'Verify ' || r.k, r.account, r.kind, r.secret) returning id into v_id;
    v := v || jsonb_build_object(r.k, v_id);
  end loop;
  insert into cma.commerce_store (tenant_id, connection_id, handle, name, market, currency, time_zone) values
    (v_t, (v ->> 'gb1')::uuid, 'shop-gb1', 'Shop GB1', 'GB', 'GBP', 'Europe/London'),
    (v_t, (v ->> 'gb2')::uuid, 'shop-gb2', 'Shop GB2', 'GB', 'GBP', 'Europe/London'),
    (v_t, (v ->> 'nl')::uuid, 'shop-nl', 'Shop NL', 'NL', 'EUR', 'Europe/Amsterdam');
  insert into cma.device_model (tenant_id, key, name, aliases, sort_order) values
    (v_t, 'hs1', 'HS1', array['heartstart hs1'], 10), (v_t, 'g5', 'G5', '{}', 20), (v_t, 'frx', 'FRx', '{}', 30);
  insert into cma.device_status (tenant_id, key, name, is_in_field, is_in_stock, is_tracked, aliases) values
    (v_t, 'field', 'Field', true, false, true, array['field']), (v_t, 'stock', 'Stock', false, true, true, array['stock']);
  return v;
end
$$;

-- The pledge fixture on a tenant (as the owner): three loans (2 and 3 active, 3 of layout 2; 6 inactive), the values of
-- hs1 and g5 (frx none), two aliases, four subscriptions (s-dup in both GB stores), thirteen
-- devices (see A4)
create or replace function pg_temp.v0009j_pledges(x jsonb)
returns void
language plpgsql
as $$
declare
  v_t uuid := (x ->> 't')::uuid;
begin
  insert into cma.pledge_loan (tenant_id, key, number, lender_label, area_label, name_suffix, layout, is_active) values
    (v_t, '2', 2, 'Lender A', 'UK', 'EUR', 1, true), (v_t, '3', 3, 'Lender B', 'NL', 'EUR LTD', 2, true),
    (v_t, '6', 6, 'Lender C', 'UK', 'EUR', 1, false);
  insert into cma.pledge_model_value (tenant_id, model_key, type_label, acquisition_value, depreciation_per_month, receipts) values
    (v_t, 'hs1', 'HS1', 845.00, 5.03, 120.00), (v_t, 'g5', 'G5', 1000.00, 10.00, 99.50);
  insert into cma.device_language_alias (tenant_id, alias, code) values (v_t, 'english', 'en'), (v_t, 'nederlands', 'nl');
  insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, source_created_at) values
    (v_t, (x ->> 'sgb1')::uuid, 'verifysubs', 's-1', 'cu-1', 'active', '2025-08-09 23:30:00+00'),
    (v_t, (x ->> 'sgb2')::uuid, 'verifysubs', 's-dup', 'cu-2', 'active', '2024-03-01 12:00:00+00'),
    (v_t, (x ->> 'snl')::uuid, 'verifysubs', 'n-1', 'cu-3', 'active', '2024-06-30 22:30:00+00');
  insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, source_created_at) values
    (v_t, (x ->> 'sgb1')::uuid, 'verifysubs', 's-dup', 'cu-4', 'active', '2024-05-01 12:00:00+00');
  insert into cma.device (tenant_id, connection_id, source_system, source_id, serial, model_key, market, device_status_key, pledge_ref, language,
                          customer_ref, customer_ref_invalid, subscription_ref, first_shipped_on, raw, source_deleted_at)
  select v_t, (x ->> 'register')::uuid, 'verifyregister', d.rec, d.sn, d.model, d.market, 'field', d.pledge, d.lang, d.cust, d.invalid, d.sub,
         d.shipped::date, jsonb_strip_nulls(jsonb_build_object('source_id', d.rec, 'pledge_ref', d.pledge, 'language', d.label)),
         case when d.gone then now() end
  from (values
    ('d-1',  'SN-0001', 'hs1', 'GB', '2', 'en', 'English',    'C1001', false, 's-1',   '2025-08-09', false),
    ('d-2',  'SN-0002', 'hs1', 'GB', '2', 'en', 'English',    null,    false, 's-1',   '2024-01-22', false),
    ('d-3',  'SN-0003', 'hs1', 'GB', '2', 'en', 'English',    'C1003', false, 'nope',  '2025-09-17', false),
    ('d-4',  'SN-0004', 'hs1', 'GB', '6', 'en', 'English',    'C1004', false, 's-1',   '2025-01-01', false),
    ('d-5',  'SN-0005', 'hs1', 'GB', '9', 'en', 'English',    'C1005', false, 's-1',   '2025-01-01', false),
    ('d-6',  'SN-0006', 'frx', 'GB', '2', 'en', 'English',    'C1006', false, 's-dup', '2025-01-01', false),
    ('d-7',  'SN-0007', 'hs1', 'GB', '2', 'en', 'English',    null,    false, null,    null,         false),
    ('d-8',  'SN-0008', 'g5',  'GB', '2', null, 'Klingon',    null,    false, null,    '2026-10-01', false),
    ('d-9',  'SN-0009', 'hs1', 'GB', '2', 'en', 'English',    'C1009', false, 's-1',   '2025-01-01', true),
    ('d-10', 'SN-0010', 'hs1', 'GB', '2', 'en', 'English',    null,    true,  null,    '2026-11-05', false),
    ('d-11', 'SN-0011', 'g5',  'NL', '3', 'nl', 'Nederlands', '123456789012345', false, 'n-1', '2016-01-01', false),
    ('d-12', 'SN-0012', 'hs1', 'NL', '3', 'nl', 'Nederlands', 'C1012', false, 's-1',   '2025-10-02', false),
    ('d-13', 'SN-0013', 'hs1', 'GB', null, 'en', 'English',   'C1013', false, 's-1',   '2025-01-01', false)
  ) as d(rec, sn, model, market, pledge, lang, label, cust, invalid, sub, shipped, gone);
end
$$;

-- S1. The addition; the tables' security, triggers and grants
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_bad     text := '';
  v_tab     text;
begin
  if not exists (select 1 from cma.schema_migration where version = '0009j') or v_provoke
     or not exists (select 1 from cma.schema_migration where version = '0009i') then
    raise exception 'FAIL S1: addition 0009j not recorded after 0009i';
  end if;
  foreach v_tab in array array['device_language_alias', 'pledge_loan', 'pledge_model_value', 'pledge_snapshot', 'pledge_snapshot_row'] loop
    if to_regclass('cma.' || v_tab) is null then
      v_bad := v_bad || v_tab || ' missing; ';
      continue;
    end if;
    if not (select c.relrowsecurity from pg_class c where c.oid = ('cma.' || v_tab)::regclass)
       or not exists (select 1 from pg_policy p where p.polrelid = ('cma.' || v_tab)::regclass and p.polname = 'tenant_app')
       or exists (select 1 from pg_trigger g where g.tgrelid = ('cma.' || v_tab)::regclass and g.tgname = 'audit' and not g.tgisinternal)
          = (v_tab = 'pledge_snapshot_row')
       or not has_table_privilege('cma_app', 'cma.' || v_tab, 'select')
       or has_table_privilege('cma_readonly', 'cma.' || v_tab, 'select') then
      v_bad := v_bad || v_tab || ' security, audit or reads; ';
    end if;
    if (v_tab like 'pledge_snapshot%') <> not (has_table_privilege('cma_app', 'cma.' || v_tab, 'insert')
                                             or has_table_privilege('cma_app', 'cma.' || v_tab, 'update')
                                             or has_table_privilege('cma_app', 'cma.' || v_tab, 'delete')) then
      v_bad := v_bad || v_tab || ' writes; ';
    end if;
    if v_tab like 'pledge_snapshot%'
       and (select count(*) from pg_trigger g where g.tgrelid = ('cma.' || v_tab)::regclass and g.tgname in ('frozen', 'frozen_truncate')
              and not g.tgisinternal and g.tgfoid = 'cma.pledge_snapshot_frozen()'::regprocedure) <> 2 then
      v_bad := v_bad || v_tab || ' frozen triggers; ';
    end if;
  end loop;
  if has_function_privilege('cma_app', 'cma.pledge_snapshot_frozen()', 'execute') then
    v_bad := v_bad || 'the frozen trigger''s function executable; ';
  end if;
  if v_bad <> '' then
    raise exception 'FAIL S1: %', v_bad;
  end if;
  insert into verify_0009j values (1, 'S1 0009j after 0009i; five tables with RLS, audit (not per file row), frozen triggers, the app reading the files only', 'PASS',
    'pledge_snapshot and pledge_snapshot_row: no insert, update or delete for cma_app; nothing for cma_readonly');
end
$$;

-- S2. Columns, checks, the index, types, mapping, settings, permissions, the scheduler role
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_bad     text := '';
begin
  if (select string_agg(column_name || ':' || udt_name, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma' and table_name = 'device' and column_name in ('pledge_ref', 'language')) is distinct from 'pledge_ref:text,language:text'
     or (select string_agg(column_name || ':' || udt_name, ',' order by ordinal_position) from information_schema.columns
         where table_schema = 'cma' and table_name = 'device_import_row' and column_name in ('pledge_ref', 'language')) is distinct from 'pledge_ref:text,language:text'
     or (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
         where table_schema = 'cma' and table_name = 'device_import_staging') not like '%,external_refs,pledge_ref,language' then
    v_bad := v_bad || 'columns; ';
  end if;
  if (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.device'::regclass and conname = 'device_pledge_ref_check')
       not like '%A-Za-z0-9#%{0,99}%'
     or (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.device'::regclass and conname = 'device_language_check')
       not like '%^[a-z]{2}$%'
     or pg_get_indexdef('cma.device_pledge_idx'::regclass) not like '%(tenant_id, pledge_ref) WHERE (pledge_ref IS NOT NULL)' then
    v_bad := v_bad || 'checks or index; ';
  end if;
  if not exists (select 1 from pg_attribute where attrelid = (select typrelid from pg_type where oid = 'cma.device_load_row'::regtype) and attname = 'language')
     or not exists (select 1 from pg_attribute where attrelid = (select typrelid from pg_type where oid = 'cma.device_load_mapped'::regtype) and attname = 'pledge_ref') then
    v_bad := v_bad || 'types; ';
  end if;
  if (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.connection_field'::regclass and conname = 'connection_field_entity_field_check')
       !~ '''device''.*''pledge_ref''::text, ''language''::text.*device_component'
     or (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.connection_field'::regclass and conname = 'connection_field_field_check')
       !~ '''segment''::text, ''pledge_ref''::text' then
    v_bad := v_bad || 'mapping; ';
  end if;
  if (select default_value || '/' || value_type from cma.setting where key = 'pledges.snapshot_local_time') is distinct from '00:05/time'
     or (select default_value || '/' || value_type from cma.setting where key = 'pledges.file_name_prefix') is distinct from 'Pledge_Lists/text'
     or not exists (select 1 from pg_trigger where tgrelid = 'cma.tenant_setting'::regclass and tgname = 'check_pledges_setting' and not tgisinternal) then
    v_bad := v_bad || 'settings; ';
  end if;
  if (select count(*) from cma.permission where key in ('pledges.view', 'pledges.snapshot')) <> 2 then
    v_bad := v_bad || 'permissions; ';
  end if;
  if exists (select 1 from cma.tenant t
             where not exists (select 1 from cma.app_role r join cma.role_permission rp on rp.tenant_id = r.tenant_id and rp.role_id = r.id
                               where r.tenant_id = t.id and r.key = 'scheduler' and not r.is_assignable and rp.permission_key = 'pledges.snapshot'))
     or exists (select 1 from cma.role_permission rp join cma.app_role r on r.tenant_id = rp.tenant_id and r.id = rp.role_id
                where rp.permission_key = 'pledges.snapshot' and r.key <> 'scheduler') then
    v_bad := v_bad || 'the scheduler role; ';
  end if;
  if v_bad <> '' or v_provoke then
    raise exception 'FAIL S2: %', coalesce(nullif(v_bad, ''), 'provoked');
  end if;
  insert into verify_0009j values (2, 'S2 the two device fields, the staging, the types, the mapping, the settings, the permissions, the scheduler', 'PASS',
    'pledges.snapshot held by every tenant''s scheduler role and by no other role');
end
$$;

-- S3. Every function's rights
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_bad     text := '';
  v_fn      text;
  p         pg_proc;
begin
  foreach v_fn in array array[
    'cma.device_language_code_of(uuid,text)', 'cma.set_device_language_alias(text,text)',
    'cma.device_rows_apply(uuid,cma.device_load_row[],boolean)', 'cma.device_snapshot_apply(text,uuid,boolean)',
    'cma.ingest_load_device_chunk(uuid,jsonb)', 'cma.pledge_label_ok(text,integer,boolean)',
    'cma.set_pledge_loan(text,integer,text,text,text,integer,boolean)', 'cma.set_pledge_model_value(text,text,numeric,numeric,numeric)',
    'cma.linkable_subscriptions_of(uuid)', 'cma.pledge_months_of(date,date)', 'cma.pledge_current_value_of(numeric,numeric,integer)',
    'cma.pledge_rows_of(uuid,date)', 'cma.pledge_unknown_loans_of(uuid)', 'cma.pledge_findings_of(uuid,date)', 'cma.pledge_check_keys()',
    'cma.pledge_page()', 'cma.pledge_finding_rows(text,integer)', 'cma.pledge_file(date)'] loop
    select * into p from pg_proc where oid = to_regprocedure(v_fn);
    if p.oid is null or p.prosecdef or p.proowner <> 'cma_owner'::regrole::oid
       or not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
       or exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0) then
      v_bad := v_bad || v_fn || '; ';
    end if;
  end loop;
  foreach v_fn in array array['cma.pledge_snapshot_take(uuid)', 'cma.pledge_snapshot_take_current()'] loop
    select * into p from pg_proc where oid = to_regprocedure(v_fn);
    if p.oid is null or not p.prosecdef or p.proowner <> 'cma_owner'::regrole::oid
       or not coalesce('search_path=pg_catalog, cma, pg_temp' = any (p.proconfig), false)
       or not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
       or exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0) then
      v_bad := v_bad || v_fn || ' (definer); ';
    end if;
  end loop;
  foreach v_fn in array array['cma.pledge_snapshot_take_at(uuid,timestamptz)', 'cma.pledge_snapshot_write(uuid,date)'] loop
    if to_regprocedure(v_fn) is null or has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
       or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      v_bad := v_bad || v_fn || ' (the owner''s); ';
    end if;
  end loop;
  if pg_get_functiondef('cma.device_rows_apply(uuid,cma.device_load_row[],boolean)'::regprocedure) not like '%cma.device_language_code_of(%unmapped_language%'
     or pg_get_functiondef('cma.ingest_load_device_chunk(uuid,jsonb)'::regprocedure) not like '%''pledge_ref'', ''language''%'
     or pg_get_functiondef('cma.device_snapshot_apply(text,uuid,boolean)'::regprocedure) not like '%s.pledge_ref, s.language%'
     or pg_get_functiondef('cma.device_import_staging_insert()'::regprocedure) not like '%device_staged_without_at(new.language)%'
     or pg_get_functiondef('cma.ensure_scheduler_user(uuid)'::regprocedure) not like '%''pledges.snapshot''%' then
    v_bad := v_bad || 'the load or the scheduler not 0009j''s; ';
  end if;
  if v_bad <> '' or v_provoke then
    raise exception 'FAIL S3: %', coalesce(nullif(v_bad, ''), 'provoked');
  end if;
  insert into verify_0009j values (3, 'S3 every function the application''s and invoker; the takes definer and pinned; their bodies the owner''s', 'PASS',
    '18 invoker functions, 2 definer takes, 2 bodies; the load and the scheduler user 0009j''s');
end
$$;

-- A1. The load with the two fields: the file path and the chunk path
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  x         jsonb;
  j         jsonb;
  d         record;
  v_bad     text;
begin
  begin
    x := pg_temp.v0009j_tenant('verify-0009j-a1');
    insert into cma.device_language_alias (tenant_id, alias, code) values ((x ->> 't')::uuid, 'english', 'en');
    perform pg_temp.v0009j_as(x, 'admin');
    insert into cma.device_import_staging (batch_key, source_row, source_id, serial, model, status, country, pledge_ref, language) values
      ('v0009j-a1', 2, 'rec-1', 'SN-L1', 'hs1', 'field', 'GB', ' 2 ', ' ENGLISH '),
      ('v0009j-a1', 3, 'rec-2', 'SN-L2', 'hs1', 'field', 'GB', '', ''),
      ('v0009j-a1', 4, 'rec-3', 'SN-L3', 'hs1', 'field', 'GB', '2, 6', 'Klingon'),
      ('v0009j-a1', 5, 'rec-4', 'SN-L4', 'hs1', 'field', 'GB', 'a@b.example', 'x@y.example');
    insert into cma.device_import_staging (batch_key, source_row, source_id, serial, model, status, country) values
      ('v0009j-a1', 6, 'rec-5', 'SN-L5', 'hs1', 'field', 'GB');
    -- staged as given (an @ kept as a bare @), checked and mapped by the load
    v_bad := (select array_agg(coalesce(s.pledge_ref, '-') order by s.source_row)::text || ' ' || array_agg(coalesce(s.language, '-') order by s.source_row)::text
              from cma.device_import_staging s where s.batch_key = 'v0009j-a1');
    if v_bad is distinct from '{" 2 ","","2, 6",@,-} {" ENGLISH ","",Klingon,@,-}' or v_provoke then
      raise exception 'FAIL A1: staged %', v_bad;
    end if;
    j := cma.load_device_snapshot('v0009j-a1', (x ->> 'register')::uuid, true);
    perform set_config('role', 'cma_owner', true);
    select string_agg(dv.source_id || '=' || coalesce(dv.pledge_ref, '-') || '/' || coalesce(dv.language, '-') || '/' || coalesce(dv.raw ->> 'pledge_ref', '-')
                      || '/' || coalesce(dv.raw ->> 'language', '-'), ' ' order by dv.source_id) into v_bad
    from cma.device dv where dv.tenant_id = (x ->> 't')::uuid;
    if v_bad is distinct from 'rec-1=2/en/2/ENGLISH rec-2=-/-/-/- rec-3=-/-/-/Klingon rec-4=-/-/-/- rec-5=-/-/-/-'
       or (j ->> 'inserted')::int <> 5 or (j ->> 'unmapped_language')::int <> 1 or (j ->> 'refs_dropped')::int <> 2 then
      raise exception 'FAIL A1: loaded %, counts %', v_bad, j;
    end if;
    v_rows := v_rows || array['10', 'A1 the file path: the reference trimmed and kept as an id, the label mapped, raw keeping both', 'PASS',
      v_bad || '; inserted 5, unmapped_language 1, refs_dropped 2 (a comma, an @)'];

    -- an unchanged rerun; then an alias added later maps the label on the next load
    perform pg_temp.v0009j_as(x, 'admin');
    insert into cma.device_import_staging (batch_key, source_row, source_id, serial, model, status, country, pledge_ref, language) values
      ('v0009j-a1b', 2, 'rec-1', 'SN-L1', 'hs1', 'field', 'GB', ' 2 ', ' ENGLISH '),
      ('v0009j-a1b', 3, 'rec-2', 'SN-L2', 'hs1', 'field', 'GB', '', ''),
      ('v0009j-a1b', 4, 'rec-3', 'SN-L3', 'hs1', 'field', 'GB', '2, 6', 'Klingon'),
      ('v0009j-a1b', 5, 'rec-4', 'SN-L4', 'hs1', 'field', 'GB', 'a@b.example', 'x@y.example'),
      ('v0009j-a1b', 6, 'rec-5', 'SN-L5', 'hs1', 'field', 'GB', null, null);
    j := cma.load_device_snapshot('v0009j-a1b', (x ->> 'register')::uuid, true);
    if (j ->> 'unchanged')::int <> 5 or (j ->> 'updated')::int <> 0 then
      raise exception 'FAIL A1: the rerun %', j;
    end if;
    perform cma.set_device_language_alias('Klingon', 'kl');
    insert into cma.device_import_staging (batch_key, source_row, source_id, serial, model, status, country, pledge_ref, language) values
      ('v0009j-a1c', 4, 'rec-3', 'SN-L3', 'hs1', 'field', 'GB', '6', 'Klingon');
    j := cma.load_device_snapshot('v0009j-a1c', (x ->> 'register')::uuid, false);
    perform set_config('role', 'cma_owner', true);
    select dv.pledge_ref, dv.language into d from cma.device dv where dv.tenant_id = (x ->> 't')::uuid and dv.source_id = 'rec-3';
    if (j ->> 'updated')::int <> 1 or (j ->> 'unmapped_language')::int <> 0 or d.pledge_ref is distinct from '6' or d.language is distinct from 'kl' then
      raise exception 'FAIL A1: an alias added later: % (%/%)', j, d.pledge_ref, d.language;
    end if;
    v_rows := v_rows || array['11', 'A1 an unchanged rerun changes nothing; an alias added later maps the label at the next load', 'PASS',
      'rerun: 5 unchanged; then rec-3 6/kl, updated 1'];

    -- the chunk path as the Ingest user: with the keys, without them (main's ingest), refusals
    perform pg_temp.v0009j_as(x, 'ingest');
    j := cma.ingest_load_device_chunk((x ->> 'register2')::uuid,
      '[{"source_row": 2, "source_id": "rec-c1", "serial": "SN-C1", "model": "hs1", "status": "field", "country": "GB", "pledge_ref": "3", "language": "English"},
        {"source_row": 3, "source_id": "rec-c2", "serial": "SN-C2", "model": "hs1", "status": "field", "country": "GB"}]'::jsonb);
    perform set_config('role', 'cma_owner', true);
    select string_agg(dv.source_id || '=' || coalesce(dv.pledge_ref, '-') || '/' || coalesce(dv.language, '-'), ' ' order by dv.source_id) into v_bad
    from cma.device dv where dv.tenant_id = (x ->> 't')::uuid and dv.connection_id = (x ->> 'register2')::uuid;
    if v_bad is distinct from 'rec-c1=3/en rec-c2=-/-' or (j ->> 'inserted')::int <> 2 then
      raise exception 'FAIL A1: the chunk %, %', v_bad, j;
    end if;
    perform pg_temp.v0009j_as(x, 'ingest');
    j := cma.ingest_load_device_chunk((x ->> 'register2')::uuid,
      '[{"source_row": 2, "source_id": "rec-c1", "serial": "SN-C1", "model": "hs1", "status": "field", "country": "GB"}]'::jsonb);
    v_bad := concat_ws(' ',
      pg_temp.v0009j_code(format('select cma.ingest_load_device_chunk(%L, %L)', x ->> 'register2',
        '[{"source_row": 2, "source_id": "rec-c3", "maatje_id": "2"}]')),
      pg_temp.v0009j_code(format('select cma.ingest_load_device_chunk(%L, %L)', x ->> 'register2',
        jsonb_build_array(jsonb_build_object('source_row', 2, 'source_id', 'rec-c3', 'pledge_ref', repeat('9', 501)))::text)),
      pg_temp.v0009j_code(format('select cma.ingest_load_device_chunk(%L, %L)', x ->> 'register2',
        jsonb_build_array(jsonb_build_object('source_row', 2, 'source_id', 'rec-c3', 'language', repeat('e', 501)))::text)));
    perform set_config('role', 'cma_owner', true);
    if v_bad <> 'CMA04 CMA04 CMA04'
       or (select dv.pledge_ref is not null or dv.language is not null from cma.device dv where dv.tenant_id = (x ->> 't')::uuid and dv.source_id = 'rec-c1')
       or (j ->> 'updated')::int <> 1 then
      raise exception 'FAIL A1: the chunk without the keys or the refusals: %, %', v_bad, j;
    end if;
    v_rows := v_rows || array['12', 'A1 the chunk path: both keys loaded; a chunk without them loads both empty; another key or 501 characters refused', 'PASS',
      'rec-c1 3/en then -/- (updated 1); CMA04 CMA04 CMA04'];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
  insert into verify_0009j select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
end
$$;

-- A2. Language aliases
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  x         jsonb;
  v_t       uuid;
  v_bad     text;
begin
  begin
    x := pg_temp.v0009j_tenant('verify-0009j-a2');
    v_t := (x ->> 't')::uuid;
    perform pg_temp.v0009j_as(x, 'admin');
    perform cma.set_device_language_alias('  English ', 'EN'), cma.set_device_language_alias('Deutsch', 'de');
    v_bad := concat_ws(' ', cma.device_language_code_of(v_t, ' ENGLISH '), cma.device_language_code_of(v_t, 'english'),
                       coalesce(cma.device_language_code_of(v_t, 'Engels'), 'null'), coalesce(cma.device_language_code_of(v_t, '  '), 'null'),
                       coalesce(cma.device_language_code_of(v_t, null), 'null'),
                       (select string_agg(a.alias || '=' || a.code, ',' order by a.alias) from cma.device_language_alias a));
    if v_bad is distinct from 'en en null null null deutsch=de,english=en' or v_provoke then
      raise exception 'FAIL A2: %', v_bad;
    end if;
    perform cma.set_device_language_alias('deutsch', '');
    v_bad := concat_ws(' ',
      pg_temp.v0009j_code('select cma.set_device_language_alias(''English'', ''eng'')'),
      pg_temp.v0009j_code('select cma.set_device_language_alias(''English'', ''e1'')'),
      pg_temp.v0009j_code('select cma.set_device_language_alias(''  '', ''en'')'),
      pg_temp.v0009j_code('select cma.set_device_language_alias(''a@b'', ''en'')'),
      pg_temp.v0009j_code(format('select cma.set_device_language_alias(%L, ''en'')', repeat('x', 101))),
      (select count(*)::text from cma.device_language_alias));
    perform pg_temp.v0009j_as(x, 'viewer');
    v_bad := v_bad || ' ' || pg_temp.v0009j_code('select cma.set_device_language_alias(''Dansk'', ''da'')');
    if v_bad is distinct from 'CMA04 CMA04 CMA04 CMA04 CMA04 1 CMA06' then
      raise exception 'FAIL A2: refusals %', v_bad;
    end if;
    v_rows := v_rows || array['20', 'A2 aliases trimmed and lower-cased, matched case-insensitively; unmapped or empty null; an empty code removes; refusals', 'PASS',
      'en en null null null; CMA04 ×5 (eng, e1, empty, @, 101 characters); one alias left; CMA06 without tenant.configure'];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
  insert into verify_0009j select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
end
$$;

-- A3. The month and value rules (pure)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_bad     text;
begin
  v_bad := concat_ws(' ', cma.pledge_months_of('2025-08-09', '2026-10-09'), cma.pledge_months_of('2025-09-17', '2026-10-09'),
                     cma.pledge_months_of('2024-01-22', '2026-10-09'), cma.pledge_months_of(null, '2026-10-09'),
                     cma.pledge_months_of('2026-10-10', '2026-10-09'), cma.pledge_months_of('2026-10-09', '2026-10-09'),
                     cma.pledge_months_of('2026-08-31', '2026-09-30'), cma.pledge_months_of('2026-01-31', '2026-02-28'));
  if v_bad is distinct from '14 12 32 0 0 0 0 0' or v_provoke then
    raise exception 'FAIL A3: months %', v_bad;
  end if;
  v_bad := concat_ws(' ', cma.pledge_current_value_of(845, 5.03, 14), cma.pledge_current_value_of(845.00, 5.03, 0),
                     cma.pledge_current_value_of(100, 10, 11), coalesce(cma.pledge_current_value_of(null, 5.03, 14)::text, 'null'),
                     cma.pledge_current_value_of(845, 7.76, 14));
  if v_bad is distinct from '774.58 845.00 0.00 null 736.36' then
    raise exception 'FAIL A3: values %', v_bad;
  end if;
  insert into verify_0009j values (30, 'A3 months at 9 October 2026: 14, 12, 32; 0 without a shipment or after; 774.58; never below 0; empty without values', 'PASS',
    'months 14 12 32 0 0 0 0 0 (age''s whole months); values 774.58 845.00 0.00 null 736.36');
end
$$;

-- A4. The rows at 1 October 2026 and the link
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  x         jsonb;
  v_t       uuid;
  v_bad     text;
  v_today   date;
  v_dup     date;
begin
  begin
    x := pg_temp.v0009j_tenant('verify-0009j-a4');
    v_t := (x ->> 't')::uuid;
    perform pg_temp.v0009j_pledges(x);
    -- s-dup is held by both GB stores: the first by id is linked (whichever the inserts gave the lower id)
    v_dup := (select (s.source_created_at at time zone 'Europe/Amsterdam')::date from cma.subscription s
              where s.tenant_id = v_t and s.source_id = 's-dup' order by s.id limit 1);
    perform pg_temp.v0009j_as(x, 'admin');
    select string_agg(concat_ws('|', r.loan_number, r.serial, coalesce(r.type_label, '-'), r.market, coalesce(r.language, '-'), coalesce(r.customer_id, '-'),
                                coalesce(r.start_date::text, '-'), coalesce(r.first_shipped_on::text, '-'), r.months_depreciating,
                                coalesce(r.depreciation_per_month::text, '-'), coalesce(r.acquisition_value::text, '-'), coalesce(r.receipts::text, '-'),
                                coalesce(r.current_value::text, '-')), E'\n' order by r.loan_number, r.serial) into v_bad
    from cma.pledge_rows_of(v_t, '2026-10-01') r;
    if v_bad is distinct from concat_ws(E'\n',
         '2|SN-0001|HS1|GB|EN|C1001|2025-08-10|2025-08-09|13|5.03|845.00|120.00|779.61',
         '2|SN-0002|HS1|GB|EN|In Storage|-|2024-01-22|32|5.03|845.00|120.00|684.04',
         '2|SN-0003|HS1|GB|EN|C1003|-|2025-09-17|12|5.03|845.00|120.00|784.64',
         format('2|SN-0006|-|GB|EN|C1006|%s|2025-01-01|21|-|-|-|-', v_dup),
         '2|SN-0007|HS1|GB|EN|In Storage|-|-|0|5.03|845.00|120.00|845.00',
         '2|SN-0008|G5|GB|-|In Storage|-|2026-10-01|0|10.00|1000.00|99.50|1000.00',
         '2|SN-0010|HS1|GB|EN|-|-|2026-11-05|0|5.03|845.00|120.00|845.00',
         '3|SN-0011|G5|NL|NL|123456789012345|2024-07-01|2016-01-01|129|10.00|1000.00|99.50|0.00',
         '3|SN-0012|HS1|NL|NL|C1012|-|2025-10-02|11|5.03|845.00|120.00|789.67') or v_provoke then
      raise exception 'FAIL A4: the rows%', E'\n' || coalesce(v_bad, '(none)');
    end if;
    v_rows := v_rows || array['40', 'A4 the rows: two active loans, In Storage, Start date in the tenant''s zone, months and values, an empty model', 'PASS',
      '9 rows of loans 2 and 3; d-4 (inactive loan), d-5 (unknown loan), d-9 (missing), d-13 (no loan) left out; s-dup by the first id'];

    -- the link: for every device the register holds, the subscription the rows link is the installed base's
    -- (cma.flash_devices_of)
    v_today := cma.tenant_today_of(v_t);
    select string_agg(f.source_id, ' ' order by f.source_id) into v_bad
    from cma.flash_devices_of(v_t, v_today) f
    join cma.device dv on dv.id = f.device_id
    where f.subscription_id is distinct from (select l.subscription_id from cma.linkable_subscriptions_of(v_t) l
                                              where l.market = dv.market and l.source_id = dv.subscription_ref);
    if v_bad is not null or (select count(*) from cma.flash_devices_of(v_t, v_today) f where f.subscription_id is not null) <> 7 then
      raise exception 'FAIL A4: the link differs from the installed base''s for %', coalesce(v_bad, 'the count of linked devices');
    end if;
    v_rows := v_rows || array['41', 'A4 the link equals the installed base''s for every device', 'PASS',
      '12 devices held, 7 linked; d-3 (nope) and d-12 (s-1 in NL) unlinked'];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
  insert into verify_0009j select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
end
$$;

-- A5. The take: the time gate, the answers, the frozen copy, immutability, take_current, the job's entry
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  x         jsonb;
  x2        jsonb;
  v_t       uuid;
  v_bad     text;
  v_q       date;
  j         jsonb;
begin
  begin
    x := pg_temp.v0009j_tenant('verify-0009j-a5');
    x2 := pg_temp.v0009j_tenant('verify-0009j-a5-empty');
    v_t := (x ->> 't')::uuid;
    perform pg_temp.v0009j_pledges(x);
    -- as the scheduler, with the owner's rights (the body takes an instant other than now for the owner only)
    perform pg_temp.v0009j_as(x, 'scheduler', 'cma_owner');
    v_bad := concat_ws(' ',
      cma.pledge_snapshot_take_at(v_t, pg_temp.v0009j_at('2026-09-30 23:59')) ->> 'answer',
      cma.pledge_snapshot_take_at(v_t, pg_temp.v0009j_at('2026-10-01 00:04:59')) ->> 'answer',
      cma.pledge_snapshot_take_at(v_t, '2026-09-30 22:04:00+00') ->> 'answer');
    j := cma.pledge_snapshot_take_at(v_t, pg_temp.v0009j_at('2026-10-01 00:05'));
    v_bad := concat_ws(' ', v_bad, j ->> 'answer', j ->> 'valuation_date', j ->> 'loans', j ->> 'devices',
      cma.pledge_snapshot_take_at(v_t, pg_temp.v0009j_at('2026-10-01 12:00')) ->> 'answer',
      cma.pledge_snapshot_take_at(v_t, '2026-09-30 22:05:00+00') ->> 'answer',
      cma.pledge_snapshot_take_at(v_t, pg_temp.v0009j_at('2026-10-02 00:05')) ->> 'answer',
      cma.pledge_snapshot_take_at(v_t, pg_temp.v0009j_at('2026-11-01 00:05')) ->> 'answer');
    if v_bad is distinct from 'not_due not_due not_due taken 2026-10-01 2 9 already_taken already_taken not_due not_due' or v_provoke then
      raise exception 'FAIL A5: the gate %', v_bad;
    end if;
    v_rows := v_rows || array['50', 'A5 not due before 00:05 local (also by an instant in UTC) or on another day; taken at 00:05 local once', 'PASS', v_bad];

    -- the winter quarter by its local day; the setting moved; no_pledges
    j := cma.pledge_snapshot_take_at(v_t, '2026-12-31 23:05:00+00');
    v_bad := concat_ws(' ', j ->> 'answer', j ->> 'valuation_date',
      (select x.months_depreciating::text from cma.pledge_snapshot_row x join cma.pledge_snapshot s on s.id = x.snapshot_id
       where s.tenant_id = v_t and s.valuation_date = '2027-01-01' and x.serial = 'SN-0001'));
    insert into cma.tenant_setting (tenant_id, key, value) values (v_t, 'pledges.snapshot_local_time', '06:00');
    v_bad := concat_ws(' ', v_bad, cma.pledge_snapshot_take_at(v_t, pg_temp.v0009j_at('2027-04-01 05:59')) ->> 'answer',
                       cma.pledge_snapshot_take_at(v_t, pg_temp.v0009j_at('2027-04-01 06:00')) ->> 'answer');
    perform pg_temp.v0009j_as(x2, 'scheduler', 'cma_owner');
    v_bad := concat_ws(' ', v_bad, cma.pledge_snapshot_take_at((x2 ->> 't')::uuid, pg_temp.v0009j_at('2026-10-01 01:00')) ->> 'answer',
                       (select count(*)::text from cma.pledge_snapshot s where s.tenant_id = (x2 ->> 't')::uuid));
    if v_bad is distinct from 'taken 2027-01-01 16 not_due taken no_pledges 0' then
      raise exception 'FAIL A5: winter, the setting, no pledges: %', v_bad;
    end if;
    v_rows := v_rows || array['51', 'A5 the winter quarter by its local day; pledges.snapshot_local_time moved; no_pledges takes nothing', 'PASS', v_bad];

    -- the frozen copy: the rows of the day, the labels kept after the catalog changes; the header
    perform pg_temp.v0009j_as(x, 'admin');
    perform cma.set_pledge_loan('2', 2, 'Lender A2', 'UK', 'EUR', 2, true);
    update cma.device set customer_ref = 'C9999' where tenant_id = v_t and source_id = 'd-1';
    perform set_config('role', 'cma_owner', true);
    select string_agg(concat_ws('|', x.loan_number, x.lender_label, x.area_label, x.name_suffix, x.layout, x.serial, x.customer_id, x.current_value), ' '
                      order by x.loan_number, x.serial) into v_bad
    from cma.pledge_snapshot_row x join cma.pledge_snapshot s on s.tenant_id = x.tenant_id and s.id = x.snapshot_id
    where s.tenant_id = v_t and s.valuation_date = '2026-10-01' and x.serial in ('SN-0001', 'SN-0011');
    if v_bad is distinct from '2|Lender A|UK|EUR|1|SN-0001|C1001|779.61 3|Lender B|NL|EUR LTD|2|SN-0011|123456789012345|0.00'
       or exists (select r.serial, r.type_label, r.market, r.language, r.start_date, r.first_shipped_on, r.months_depreciating, r.depreciation_per_month,
                         r.acquisition_value, r.receipts, r.current_value, r.loan_number
                  from cma.pledge_rows_of(v_t, '2026-10-01') r where r.serial <> 'SN-0001'
                  except
                  select x.serial, x.type_label, x.market, x.language, x.start_date, x.first_shipped_on, x.months_depreciating, x.depreciation_per_month,
                         x.acquisition_value, x.receipts, x.current_value, x.loan_number
                  from cma.pledge_snapshot_row x join cma.pledge_snapshot s on s.tenant_id = x.tenant_id and s.id = x.snapshot_id
                  where s.tenant_id = v_t and s.valuation_date = '2026-10-01')
       or (select s.taken_by from cma.pledge_snapshot s where s.tenant_id = v_t and s.valuation_date = '2026-10-01') <> (x ->> 'scheduler')::uuid
       or (select jsonb_typeof(s.sources) from cma.pledge_snapshot s where s.tenant_id = v_t and s.valuation_date = '2026-10-01') <> 'object' then
      raise exception 'FAIL A5: the frozen copy %', v_bad;
    end if;
    v_rows := v_rows || array['52', 'A5 the file keeps its rows and labels after the catalog and the register change; taken by the scheduler', 'PASS', v_bad];

    -- immutable for the owner (update, delete, truncate: CMA03) and the application (no write: 42501); the audit. The
    -- rows' deferred key checks run first (a truncate refuses a table with pending trigger events)
    set constraints all immediate;
    v_bad := concat_ws(' ',
      pg_temp.v0009j_code(format('update cma.pledge_snapshot set loans = 0 where tenant_id = %L', v_t)),
      pg_temp.v0009j_code(format('delete from cma.pledge_snapshot where tenant_id = %L', v_t)),
      pg_temp.v0009j_code(format('update cma.pledge_snapshot_row set lender_label = ''x'' where tenant_id = %L', v_t)),
      pg_temp.v0009j_code(format('delete from cma.pledge_snapshot_row where tenant_id = %L', v_t)),
      pg_temp.v0009j_code('truncate cma.pledge_snapshot_row'));
    perform pg_temp.v0009j_as(x, 'admin');
    v_bad := concat_ws(' ', v_bad,
      pg_temp.v0009j_code(format('update cma.pledge_snapshot set loans = 0 where tenant_id = %L', v_t)),
      pg_temp.v0009j_code(format('delete from cma.pledge_snapshot_row where tenant_id = %L', v_t)),
      pg_temp.v0009j_code(format('insert into cma.pledge_snapshot (tenant_id, valuation_date, taken_by, loans, devices) values (%L, ''2025-01-01'', %L, 0, 0)',
                                 v_t, x ->> 'admin')));
    perform set_config('role', 'cma_owner', true);
    v_bad := concat_ws(' ', v_bad,
      (select count(*)::text from cma.audit_log a where a.tenant_id = v_t and a.table_name = 'pledge_snapshot'),
      (select count(*)::text from cma.audit_log a where a.tenant_id = v_t and a.table_name = 'pledge_snapshot_row'),
      (select count(*)::text from cma.pledge_snapshot_row x where x.tenant_id = v_t));
    if v_bad is distinct from 'CMA03 CMA03 CMA03 CMA03 CMA03 42501 42501 42501 3 0 27' then
      raise exception 'FAIL A5: immutability or audit %', v_bad;
    end if;
    v_rows := v_rows || array['53', 'A5 frozen: update, delete, truncate refused to the owner (CMA03), every write to the application; one audit row per file, none per row', 'PASS', v_bad];

    -- take_current (tenant.configure): the current quarter's first day once; the job's entry as the scheduler
    v_q := date_trunc('quarter', cma.tenant_today_of(v_t))::date;
    perform pg_temp.v0009j_as(x, 'admin');
    j := cma.pledge_snapshot_take_current();
    v_bad := concat_ws(' ', (j ->> 'answer') = case when v_q in ('2026-10-01', '2027-01-01', '2027-04-01') then 'already_taken' else 'taken' end,
                       j ->> 'valuation_date' = v_q::text, cma.pledge_snapshot_take_current() ->> 'answer');
    perform pg_temp.v0009j_as(x2, 'admin');
    v_bad := concat_ws(' ', v_bad, cma.pledge_snapshot_take_current() ->> 'answer');
    perform pg_temp.v0009j_as(x, 'scheduler');
    j := cma.pledge_snapshot_take(v_t);
    v_bad := concat_ws(' ', v_bad, (j ->> 'answer') in ('not_due', 'already_taken', 'taken'));
    if v_bad is distinct from 't t already_taken no_pledges t' then
      raise exception 'FAIL A5: take_current or the job''s entry: % (quarter %)', v_bad, v_q;
    end if;
    v_rows := v_rows || array['54', 'A5 take_current: the quarter''s first day once, already_taken after, no_pledges without; the job''s entry answers', 'PASS',
      format('quarter %s; %s', v_q, v_bad)];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
  insert into verify_0009j select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
end
$$;

-- A6. The reads and every refusal
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  x         jsonb;
  x2        jsonb;
  v_t       uuid;
  v_bad     text;
  v_today   date;
  j         jsonb;
begin
  begin
    x := pg_temp.v0009j_tenant('verify-0009j-a6');
    x2 := pg_temp.v0009j_tenant('verify-0009j-a6-other');
    v_t := (x ->> 't')::uuid;
    perform pg_temp.v0009j_pledges(x);
    perform pg_temp.v0009j_as(x, 'scheduler', 'cma_owner');
    perform cma.pledge_snapshot_take_at(v_t, pg_temp.v0009j_at('2026-10-01 00:05'));
    v_today := cma.tenant_today_of(v_t);
    perform pg_temp.v0009j_as(x, 'viewer');
    j := cma.pledge_page();
    v_bad := concat_ws(' ', j -> 'files' -> 0 ->> 'valuation_date', j -> 'files' -> 0 ->> 'loans', j -> 'files' -> 0 ->> 'devices',
                       j -> 'checks', j -> 'unmapped_languages', j ->> 'file_name_prefix', j ->> 'is_set_up');
    if v_bad is distinct from '2026-10-01 2 9 {"no_language": 1, "unknown_loan": 1, "no_start_date": 2, "no_model_values": 1, "no_first_shipped": 1, "customer_ref_invalid": 1} [{"label": "Klingon", "devices": 1}] Pledge_Lists true'
       or v_provoke then
      raise exception 'FAIL A6: the page %', v_bad;
    end if;
    -- today's sums per loan equal the rows' at today; In Storage counted; the quarter's state
    if (select jsonb_agg(jsonb_build_object('number', y.number, 'devices', y.devices, 'in_storage', y.in_storage, 'acquisition_value', y.acq,
                                            'current_value', y.cur, 'receipts', y.rec) order by y.number)
        from (select r.loan_number as number, count(*) as devices, count(*) filter (where r.customer_id = 'In Storage') as in_storage,
                     coalesce(sum(r.acquisition_value), 0)::numeric(14,2)::text as acq, coalesce(sum(r.current_value), 0)::numeric(14,2)::text as cur,
                     coalesce(sum(r.receipts), 0)::numeric(14,2)::text as rec
              from cma.pledge_rows_of(v_t, v_today) r group by 1) y)
       is distinct from (select jsonb_agg(l - 'lender_label' order by (l ->> 'number')::int) from jsonb_array_elements(j -> 'today' -> 'loans') l)
       or (select string_agg(l ->> 'lender_label' || ':' || (l ->> 'in_storage'), ' ' order by (l ->> 'number')::int) from jsonb_array_elements(j -> 'today' -> 'loans') l)
          is distinct from 'Lender A:3 Lender B:0'
       or (j -> 'quarter' ->> 'start') <> date_trunc('quarter', v_today)::date::text
       or (j -> 'quarter' ->> 'taken')::boolean <> (date_trunc('quarter', v_today)::date = '2026-10-01')
       or (j -> 'today' ->> 'valuation_date') <> v_today::text then
      raise exception 'FAIL A6: today % or the quarter %', j -> 'today', j -> 'quarter';
    end if;
    v_rows := v_rows || array['60', 'A6 the page: the files, today''s sums per loan, In Storage, the checks, the unmapped labels, the quarter', 'PASS', v_bad];

    v_bad := concat_ws(' ', (select string_agg(f.serial || ':' || f.total_rows, ',' order by f.serial) from cma.pledge_finding_rows('no_start_date', 500) f),
                       (select string_agg(f.serial || '=' || f.value, ',') from cma.pledge_finding_rows('unknown_loan', 500) f),
                       (select string_agg(f.serial || '=' || f.value, ',') from cma.pledge_finding_rows('no_model_values', 500) f),
                       (select count(*)::text from cma.pledge_finding_rows('no_start_date', 1)),
                       pg_temp.v0009j_code('select * from cma.pledge_finding_rows(''unknown'', 10)'),
                       pg_temp.v0009j_code('select * from cma.pledge_finding_rows(''no_language'', 0)'),
                       pg_temp.v0009j_code('select * from cma.pledge_finding_rows(''no_language'', 1001)'));
    if v_bad is distinct from 'SN-0003:2,SN-0012:2 SN-0005=9 SN-0006=frx 1 CMA04 CMA04 CMA04' then
      raise exception 'FAIL A6: a check''s serials %', v_bad;
    end if;
    v_rows := v_rows || array['61', 'A6 a check''s serials with their values and total; an unknown check or a limit outside 1 to 1,000 refused', 'PASS', v_bad];

    perform set_config('role', 'cma_owner', true);
    insert into cma.tenant_setting (tenant_id, key, value) values (v_t, 'pledges.file_name_prefix', 'P4A_Pledge_Lists_Maatjes');
    perform pg_temp.v0009j_as(x, 'viewer');
    v_bad := concat_ws(' ', (select count(*)::text from cma.pledge_file('2026-10-01')),
                       (select min(f.file_name_prefix) || '/' || max(f.file_name_prefix) from cma.pledge_file('2026-10-01') f),
                       (select min(f.file_name_prefix) from cma.pledge_file(null) f),
                       (select string_agg(f.loan_number || ':' || f.serial, ',' order by f.loan_number, f.serial) from cma.pledge_file('2026-10-01') f where f.serial in ('SN-0001', 'SN-0012')),
                       (select f.lender_label || '/' || f.layout from cma.pledge_file('2026-10-01') f where f.serial = 'SN-0011'),
                       (select count(*) from cma.pledge_file(null)) = (select count(*) from cma.pledge_rows_of(v_t, v_today)),
                       (select bool_and(f.valuation_date = v_today and f.taken_at is null) from cma.pledge_file(null) f),
                       pg_temp.v0009j_code('select * from cma.pledge_file(''2026-07-01'')'));
    if v_bad is distinct from '9 Pledge_Lists/Pledge_Lists P4A_Pledge_Lists_Maatjes 2:SN-0001,3:SN-0012 Lender B/2 t t CMA02' then
      raise exception 'FAIL A6: the files %', v_bad;
    end if;
    v_rows := v_rows || array['62', 'A6 a stored file by loan and serial with its labels, layout and the name prefix it was taken with; today''s valued today with today''s prefix; no file of a date: CMA02', 'PASS', v_bad];

    -- every refusal
    perform pg_temp.v0009j_as(x, 'admin');
    v_bad := concat_ws(' ', pg_temp.v0009j_code('select cma.pledge_page()'), pg_temp.v0009j_code('select * from cma.pledge_finding_rows(''no_language'', 10)'),
                       pg_temp.v0009j_code('select * from cma.pledge_file(null)'),
                       pg_temp.v0009j_code(format('select cma.pledge_snapshot_take(%L)', v_t)),
                       pg_temp.v0009j_code(format('select cma.pledge_snapshot_take_at(%L, now())', v_t)),
                       pg_temp.v0009j_code(format('select cma.pledge_snapshot_write(%L, ''2026-10-01'')', v_t)));
    perform pg_temp.v0009j_as(x, 'agent');
    v_bad := concat_ws(' ', v_bad, pg_temp.v0009j_code('select cma.pledge_page()'),
                       pg_temp.v0009j_code('select cma.set_pledge_loan(''7'', 7, ''Lender D'', ''UK'', ''EUR'', 1, true)'),
                       pg_temp.v0009j_code('select cma.pledge_snapshot_take_current()'));
    perform pg_temp.v0009j_as(x, 'viewer');
    v_bad := concat_ws(' ', v_bad, pg_temp.v0009j_code('select cma.set_pledge_model_value(''frx'', ''FRx'', 900, 5, 100)'),
                       pg_temp.v0009j_code('select cma.pledge_snapshot_take_current()'));
    perform pg_temp.v0009j_as(x, 'scheduler');
    v_bad := concat_ws(' ', v_bad, pg_temp.v0009j_code(format('select cma.pledge_snapshot_take(%L)', x2 ->> 't')),
                       pg_temp.v0009j_code('select cma.pledge_page()'));
    if v_bad is distinct from 'CMA06 CMA06 CMA06 CMA06 42501 42501 CMA06 CMA06 CMA06 CMA06 CMA06 CMA06 CMA06' then
      raise exception 'FAIL A6: refusals %', v_bad;
    end if;
    perform set_config('role', 'cma_owner', true);
    if exists (select 1 from cma.role_permission rp join cma.app_role r on r.tenant_id = rp.tenant_id and r.id = rp.role_id
               where rp.tenant_id = (x2 ->> 't')::uuid and rp.permission_key in ('pledges.view', 'pledges.snapshot')
                 and r.key not in ('scheduler', 'verify_pledges'))
       or not exists (select 1 from cma.role_permission rp join cma.app_role r on r.tenant_id = rp.tenant_id and r.id = rp.role_id
                      where rp.tenant_id = (x2 ->> 't')::uuid and rp.permission_key = 'pledges.snapshot' and r.key = 'scheduler' and not r.is_assignable) then
      raise exception 'FAIL A6: a new tenant''s roles hold a pledge permission besides the scheduler''s pledges.snapshot';
    end if;
    v_rows := v_rows || array['63', 'A6 every refusal; a new tenant''s default roles hold neither permission, its scheduler pledges.snapshot', 'PASS', v_bad];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
  insert into verify_0009j select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
end
$$;

-- A7. The catalogs' setters, the settings, the field mapping
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  x         jsonb;
  v_t       uuid;
  v_bad     text;
  v_id      uuid;
begin
  begin
    x := pg_temp.v0009j_tenant('verify-0009j-a7');
    v_t := (x ->> 't')::uuid;
    perform pg_temp.v0009j_as(x, 'admin');
    v_id := cma.set_pledge_loan(' 2 ', 2, ' Lender A ', 'UK', 'EUR', 1, true);
    v_bad := concat_ws(' ',
      pg_temp.v0009j_code('select cma.set_pledge_loan(''4'', 0, ''Lender D'', ''UK'', ''EUR'', 1, true)'),
      pg_temp.v0009j_code('select cma.set_pledge_loan(''4'', 1000, ''Lender D'', ''UK'', ''EUR'', 1, true)'),
      pg_temp.v0009j_code('select cma.set_pledge_loan(''4'', 4, ''lender@d.example'', ''UK'', ''EUR'', 1, true)'),
      pg_temp.v0009j_code('select cma.set_pledge_loan(''4'', 4, ''Lender/D'', ''UK'', ''EUR'', 1, true)'),
      pg_temp.v0009j_code(format('select cma.set_pledge_loan(''4'', 4, %L, ''UK'', ''EUR'', 1, true)', repeat('L', 61))),
      pg_temp.v0009j_code('select cma.set_pledge_loan(''4'', 4, ''Lender D'', ''UNITEDKINGD'', ''EUR'', 1, true)'),
      pg_temp.v0009j_code('select cma.set_pledge_loan(''4'', 4, ''Lender D'', ''UK'', ''EUR''''S'', 1, true)'),
      pg_temp.v0009j_code('select cma.set_pledge_loan(''4'', 4, ''Lender D'', ''UK'', ''EUR'', 3, true)'),
      pg_temp.v0009j_code('select cma.set_pledge_loan(''4, 5'', 4, ''Lender D'', ''UK'', ''EUR'', 1, true)'),
      pg_temp.v0009j_code('select cma.set_pledge_loan(''4'', 2, ''Lender D'', ''UK'', ''EUR'', 1, true)'));
    perform cma.set_pledge_loan('2', 2, 'Lender A', 'UK', 'EUR LTD', 2, false);
    perform set_config('role', 'cma_owner', true);
    v_bad := concat_ws(' ', v_bad, (select string_agg(concat_ws('|', l.id = v_id, l.key, l.number, l.lender_label, l.name_suffix, l.layout, l.is_active), ',')
                                    from cma.pledge_loan l where l.tenant_id = v_t));
    if v_bad is distinct from 'CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA03 t|2|2|Lender A|EUR LTD|2|f' or v_provoke then
      raise exception 'FAIL A7: set_pledge_loan %', v_bad;
    end if;
    v_rows := v_rows || array['70', 'A7 set_pledge_loan: trimmed, upserted by key; number, labels, characters, layout and key refused (CMA04), a number held (CMA03)', 'PASS', v_bad];

    perform pg_temp.v0009j_as(x, 'admin');
    perform cma.set_pledge_model_value('hs1', ' HS1 ', 845, 5.03, 120), cma.set_pledge_model_value('hs1', 'HS1', 845.00, 7.76, 120);
    v_bad := concat_ws(' ',
      pg_temp.v0009j_code('select cma.set_pledge_model_value(''nope'', ''X'', 1, 1, 1)'),
      pg_temp.v0009j_code('select cma.set_pledge_model_value(''g5'', ''G5'', 1000.001, 1, 1)'),
      pg_temp.v0009j_code('select cma.set_pledge_model_value(''g5'', ''G5'', -1, 1, 1)'),
      pg_temp.v0009j_code('select cma.set_pledge_model_value(''g5'', ''G5'', 1000, null, 1)'),
      pg_temp.v0009j_code(format('select cma.set_pledge_model_value(''g5'', %L, 1, 1, 1)', repeat('T', 21))),
      (select string_agg(concat_ws('|', v.model_key, v.type_label, v.acquisition_value, v.depreciation_per_month, v.receipts), ',') from cma.pledge_model_value v));
    if v_bad is distinct from 'CMA02 CMA04 CMA04 CMA04 CMA04 hs1|HS1|845.00|7.76|120.00' then
      raise exception 'FAIL A7: set_pledge_model_value %', v_bad;
    end if;
    v_rows := v_rows || array['71', 'A7 set_pledge_model_value: upserted per model; an unknown model (CMA02), three decimals, below 0, none, 21 characters (CMA04)', 'PASS', v_bad];

    v_bad := concat_ws(' ',
      pg_temp.v0009j_code('select * from cma.set_tenant_setting(''pledges.snapshot_local_time'', ''24:00'')'),
      pg_temp.v0009j_code('select * from cma.set_tenant_setting(''pledges.snapshot_local_time'', ''06:30'')'),
      pg_temp.v0009j_code('select * from cma.set_tenant_setting(''pledges.file_name_prefix'', ''P4A Pledge'')'),
      pg_temp.v0009j_code('select * from cma.set_tenant_setting(''pledges.file_name_prefix'', ''P4A_Pledge_Lists_Maatjes'')'));
    -- read in a statement of its own (a statement's snapshot does not see the writes of the calls within it)
    v_bad := concat_ws(' ', v_bad, cma.setting_of(v_t, 'pledges.snapshot_local_time'), cma.setting_of(v_t, 'pledges.file_name_prefix'),
      pg_temp.v0009j_code(format('select cma.set_connection_field(%L, ''device'', ''pledge_ref'', '''', ''fldPledge0000001'', 1::smallint)', x ->> 'register')),
      pg_temp.v0009j_code(format('select cma.set_connection_field(%L, ''device'', ''language'', '''', ''fldLanguage00001'', 1::smallint)', x ->> 'register')),
      pg_temp.v0009j_code(format('select cma.set_connection_field(%L, ''device'', ''pledge_ref'', '''', ''maatje_id'', 1::smallint)', x ->> 'crm')),
      pg_temp.v0009j_code(format('select cma.set_connection_field(%L, ''contact'', ''pledge_ref'', '''', ''maatje_id'', 1::smallint)', x ->> 'crm')));
    if v_bad is distinct from 'CMA04 ok CMA04 ok 06:30 P4A_Pledge_Lists_Maatjes ok ok CMA04 CMA04' then
      raise exception 'FAIL A7: the settings or the mapping %', v_bad;
    end if;
    v_rows := v_rows || array['72', 'A7 the settings'' forms (24:00 and a space refused); the two fields mapped on an asset register only', 'PASS', v_bad];

    -- the loan's audit images keep no lender label (D8): the insert, the updates (one changing the label, one not) and
    -- no image anywhere in the tenant's audit holding a label this block wrote
    perform set_config('role', 'cma_owner', true);
    v_bad := concat_ws(' ',
      (select count(*)::text from cma.audit_log a where a.tenant_id = v_t and a.table_name = 'pledge_loan'),
      (select count(*)::text from cma.audit_log a where a.tenant_id = v_t and a.table_name = 'pledge_loan'
         and ((a.old_row ? 'lender_label') or (a.new_row ? 'lender_label'))),
      (select count(*)::text from cma.audit_log a where a.tenant_id = v_t and strpos(coalesce(a.old_row::text, '') || coalesce(a.new_row::text, ''), 'Lender A') > 0),
      (select string_agg(coalesce(a.new_row ->> 'lender_label_changed', '-'), ',' order by a.id) from cma.audit_log a
       where a.tenant_id = v_t and a.table_name = 'pledge_loan'));
    if v_bad is distinct from '2 0 0 -,false' then
      raise exception 'FAIL A7: the loan''s audit images %', v_bad;
    end if;
    perform pg_temp.v0009j_as(x, 'admin');
    perform cma.set_pledge_loan('2', 2, 'Lender Z', 'UK', 'EUR LTD', 2, false);
    perform set_config('role', 'cma_owner', true);
    v_bad := concat_ws(' ',
      (select string_agg(coalesce(a.new_row ->> 'lender_label_changed', '-'), ',' order by a.id) from cma.audit_log a
       where a.tenant_id = v_t and a.table_name = 'pledge_loan'),
      (select count(*)::text from cma.audit_log a where a.tenant_id = v_t and strpos(coalesce(a.old_row::text, '') || coalesce(a.new_row::text, ''), 'Lender') > 0),
      (select l.lender_label from cma.pledge_loan l where l.tenant_id = v_t));
    if v_bad is distinct from '-,false,true 0 Lender Z' then
      raise exception 'FAIL A7: a label''s change in the audit %', v_bad;
    end if;
    v_rows := v_rows || array['73', 'A7 the loan''s audit images keep no lender label (D8): lender_label_changed on an update instead', 'PASS',
      '3 audit rows, none with a label; changed: -, false, true'];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
  insert into verify_0009j select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
end
$$;

-- Verdict: one row per check that passed, then the verdict (23 checks; a block that stopped counts its checks as FAIL)
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0009j
      union all
      select 999, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0009j where result = 'PASS') = 23 then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0009j where result = 'PASS'),
                                        23 - (select count(*) from verify_0009j where result = 'PASS'))) x
order by ord;
drop function if exists pg_temp.v0009j_pledges(jsonb);
drop function if exists pg_temp.v0009j_tenant(text);
drop function if exists pg_temp.v0009j_as(jsonb, text, text);
drop function if exists pg_temp.v0009j_code(text);
drop function if exists pg_temp.v0009j_at(text);
drop table if exists pg_temp.verify_0009j;
reset role;
