-- =============================================================================================
-- 141_verify_live_per_organisation.sql: verifies addition 0008zv, a Live board per contact-center organisation
-- =============================================================================================
-- Block S1 and S2 check the addition, the column and the readers' view (universal); S3 checks seed 02's value (Newco of
-- Pulse4all Subscriptions flagged, every other organisation of the two Pulse4all tenants not). Blocks A1 to A4 work on
-- two throwaway tenants inside a subtransaction that is always rolled back, so nothing stays and the script runs in dev
-- and in prod. Cloud SQL Studio shows no notices: a check that fails raises "FAIL …" and stops its block; every check
-- that passed writes one row, and the last row is the verdict: "PASS | 9 PASS, 0 FAIL" (provoked: "PROVOKED, NOT A PASS
-- | 0 PASS, 9 FAIL"). A block that stopped counts its checks as FAIL; the verdict is reached only when the client goes
-- on after an error (psql -v ON_ERROR_STOP=0, as the provoked run does; with ON_ERROR_STOP=1 the run ends at the first
-- FAIL, which names the check). Run as your own IAM login after 140_live_per_organisation.sql and seed 02 again, dev
-- first, then prod.
--   S1  the addition 0008zv is recorded after 0008zu; cma.organisation.is_contact_center is a boolean, not null, default
--       false, with its comment
--   S2  cma_read.organisation ends with is_contact_center (after 05's timezone); cma_app holds select and update on
--       cma.organisation and no delete (76), cma_readonly nothing on the base table (readers use cma_read)
--   S3  seed 02: Newco of Pulse4all Subscriptions is a contact center; Pulse4all of Subscriptions and both organisations
--       of Pulse4all Invest are not
--   A1  an organisation inserted without the flag reads false
--   A2  the web's read (the identity read's contact centers, web/src/lib/data/postgres.ts findPrincipal) as cma_app in a
--       tenant answers that tenant's flagged active organisations only, by name: not an unflagged one, not an inactive
--       flagged one, not another tenant's flagged one; a tenant with none answers an empty list
--   A3  tenant isolation: as cma_app in tenant two, tenant one's organisations are invisible, an update of tenant one's
--       flag changes no row (and the flag stays), and an organisation inserted with tenant one's id is refused
--   A4  a change of the flag is audited: one cma.audit_log row for the organisation with is_contact_center false before
--       and true after, in its own tenant
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

drop table if exists pg_temp.verify_0008zv;
create temp table verify_0008zv (ord int, check_name text, result text, detail text);

-- A throwaway tenant with two organisations (the first flagged) and an admin; its ids as jsonb
create or replace function pg_temp.v0008zv_tenant(p_slug text)
returns jsonb
language plpgsql
as $$
declare
  v_t  uuid;
  v_cc uuid;
  v_ot uuid;
  v_id uuid;
begin
  v_t := cma.create_tenant(p_slug, 'Verify 0008zv', 'Europe/Amsterdam');
  insert into cma.organisation (tenant_id, key, name, is_contact_center) values (v_t, 'verify-cc', 'Verify contact center', true) returning id into v_cc;
  insert into cma.organisation (tenant_id, key, name) values (v_t, 'verify-office', 'Verify office') returning id into v_ot;
  insert into cma.app_user (tenant_id, organisation_id, email, display_name)
  values (v_t, v_cc, 'verify-admin@example.invalid', 'admin') returning id into v_id;
  insert into cma.user_role (tenant_id, user_id, role_id)
  select v_t, v_id, ar.id from cma.app_role ar where ar.tenant_id = v_t and ar.key = 'admin';
  return jsonb_build_object('t', v_t, 'cc', v_cc, 'office', v_ot, 'admin', v_id);
end
$$;

-- The acting context inside a block: the application, the tenant, a person
create or replace function pg_temp.v0008zv_as(x jsonb)
returns void
language sql
as $$
  select set_config('role', 'cma_app', true), set_config('app.tenant_id', x ->> 't', true),
         set_config('app.user_id', x ->> 'admin', true), set_config('app.actor_label', '', true);
$$;

-- The web's read of the tenant's contact centers, as the identity read makes it (findPrincipal): keys by name
-- (compared as jsonb, whose array keeps its order, so the check never depends on json's spacing)
create or replace function pg_temp.v0008zv_contact_centers()
returns jsonb
language sql stable
as $$
  select coalesce((select json_agg(json_build_object('key', o.key, 'name', o.name) order by o.name, o.key)
                     from cma.organisation o
                    where o.tenant_id = cma.current_tenant_id() and o.is_contact_center and o.status = 'active'), '[]'::json)::jsonb
$$;

-- S1. The addition and the column (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  c         record;
begin
  if not exists (select 1 from cma.schema_migration where version = '0008zv') or v_provoke
     or not exists (select 1 from cma.schema_migration where version = '0008zu') then
    raise exception 'FAIL S1: addition 0008zv not recorded after 0008zu';
  end if;
  select a.atttypid::regtype::text as type, a.attnotnull as not_null, pg_get_expr(d.adbin, d.adrelid) as dflt,
         col_description(a.attrelid, a.attnum) as note
  into c
  from pg_attribute a
  left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
  where a.attrelid = 'cma.organisation'::regclass and a.attname = 'is_contact_center' and not a.attisdropped;
  if not found or c.type <> 'boolean' or not c.not_null or c.dflt is distinct from 'false' or coalesce(c.note, '') = '' then
    raise exception 'FAIL S1: cma.organisation.is_contact_center is not a boolean, not null, default false, with a comment (%)', to_jsonb(c);
  end if;
  insert into verify_0008zv values (1, 'S1 addition and column', 'PASS', 'boolean, not null, default false, commented');
end
$$;

-- S2. The readers' view and the grants (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_cols    text;
begin
  select string_agg(a.attname, ',' order by a.attnum)
  into v_cols
  from pg_attribute a
  where a.attrelid = 'cma_read.organisation'::regclass and a.attnum > 0 and not a.attisdropped;
  if v_cols is distinct from 'id,tenant_id,key,name,status,created_at,updated_at,timezone,is_contact_center' or v_provoke then
    raise exception 'FAIL S2: cma_read.organisation does not end with is_contact_center after timezone (%)', v_cols;
  end if;
  if not has_column_privilege('cma_app', 'cma.organisation', 'is_contact_center', 'select')
     or not has_column_privilege('cma_app', 'cma.organisation', 'is_contact_center', 'update')
     or has_table_privilege('cma_app', 'cma.organisation', 'delete')
     or has_table_privilege('cma_readonly', 'cma.organisation', 'select')
     or not (select c.relrowsecurity from pg_class c where c.oid = 'cma.organisation'::regclass) then
    raise exception 'FAIL S2: the grants or row-level security of cma.organisation are not 01''s and 76''s';
  end if;
  insert into verify_0008zv values (2, 'S2 readers'' view and grants', 'PASS',
    'cma_read.organisation ends with is_contact_center; cma_app select and update, no delete; cma_readonly none; RLS on');
end
$$;

-- S3. Seed 02's value: Newco of Pulse4all Subscriptions is a contact center, the other Pulse4all organisations are not
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_flags   text;
begin
  select string_agg(format('%s/%s:%s', t.slug, o.key, o.is_contact_center::text), ',' order by t.slug, o.key)
  into v_flags
  from cma.organisation o
  join cma.tenant t on t.id = o.tenant_id
  where t.slug in ('pulse4all-subscriptions', 'pulse4all-invest');
  if v_flags is distinct from 'pulse4all-invest/clubdeal:false,pulse4all-invest/pulse4all:false,'
                              || 'pulse4all-subscriptions/newco:true,pulse4all-subscriptions/pulse4all:false'
     or v_provoke then
    raise exception 'FAIL S3: the Pulse4all organisations are not flagged as seed 02 sets them; rerun 02 after 140 (%)', v_flags;
  end if;
  insert into verify_0008zv values (3, 'S3 seed 02: Newco a contact center, the others not', 'PASS', v_flags);
end
$$;

-- A1 to A4. Two throwaway tenants: the default, the web's read, tenant isolation, the audit
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  x1        jsonb;
  x2        jsonb;
  v_new     uuid;
  v_flag    boolean;
  v_n       integer;
  v_got     jsonb;
  v_refused boolean := false;
begin
  begin
    x1 := pg_temp.v0008zv_tenant('verify-0008zv-one');
    x2 := pg_temp.v0008zv_tenant('verify-0008zv-two');

    -- A1. The default: an organisation inserted without the flag (tenant one's office above too)
    insert into cma.organisation (tenant_id, key, name) values ((x1 ->> 't')::uuid, 'verify-new', 'Verify new') returning id into v_new;
    select o.is_contact_center into v_flag from cma.organisation o where o.id = v_new;
    if v_flag is distinct from false or v_provoke then
      raise exception 'FAIL A1: an organisation inserted without the flag reads % instead of false', v_flag;
    end if;
    v_rows := v_rows || array['11', 'A1 an organisation inserted without the flag reads false', 'PASS', 'false'];

    -- A2. The web's read: tenant one's flagged active organisations by name; an inactive flagged one and tenant two's
    -- flagged one stay out; tenant two with its flag taken away answers an empty list
    insert into cma.organisation (tenant_id, key, name, is_contact_center, status)
    values ((x1 ->> 't')::uuid, 'verify-closed', 'Verify closed', true, 'inactive');
    insert into cma.organisation (tenant_id, key, name, is_contact_center)
    values ((x1 ->> 't')::uuid, 'verify-alpha', 'Alpha contact center', true);
    perform pg_temp.v0008zv_as(x1);
    v_got := pg_temp.v0008zv_contact_centers();
    if v_got is distinct from '[{"key": "verify-alpha", "name": "Alpha contact center"}, {"key": "verify-cc", "name": "Verify contact center"}]'::jsonb then
      raise exception 'FAIL A2: tenant one''s contact centers read %', v_got;
    end if;
    perform set_config('role', 'cma_owner', true);
    update cma.organisation set is_contact_center = false where id = (x2 ->> 'cc')::uuid;
    perform pg_temp.v0008zv_as(x2);
    v_got := pg_temp.v0008zv_contact_centers();
    if v_got is distinct from '[]'::jsonb then
      raise exception 'FAIL A2: a tenant with no contact center reads % instead of an empty list', v_got;
    end if;
    v_rows := v_rows || array['12', 'A2 the web''s read: own flagged active organisations by name; none reads empty', 'PASS',
      'verify-alpha, verify-cc; not inactive, not unflagged, not tenant two''s; []'];

    -- A3. Tenant isolation, as cma_app in tenant two
    select count(*) into v_n from cma.organisation o where o.tenant_id = (x1 ->> 't')::uuid;
    if v_n <> 0 then
      raise exception 'FAIL A3: tenant two sees % of tenant one''s organisations', v_n;
    end if;
    v_rows := v_rows || array['13', 'A3 tenant one''s organisations are invisible from tenant two', 'PASS', '0 rows'];
    update cma.organisation set is_contact_center = false where id = (x1 ->> 'cc')::uuid;
    get diagnostics v_n = row_count;
    perform set_config('role', 'cma_owner', true);
    select o.is_contact_center into v_flag from cma.organisation o where o.id = (x1 ->> 'cc')::uuid;
    if v_n <> 0 or v_flag is distinct from true then
      raise exception 'FAIL A3: tenant two''s update of tenant one''s flag changed % rows (flag now %)', v_n, v_flag;
    end if;
    v_rows := v_rows || array['14', 'A3 tenant two cannot change tenant one''s flag', 'PASS', '0 rows changed, the flag stays true'];
    perform pg_temp.v0008zv_as(x2);
    begin
      insert into cma.organisation (tenant_id, key, name, is_contact_center) values ((x1 ->> 't')::uuid, 'verify-intruder', 'Intruder', true);
    exception when insufficient_privilege then v_refused := true;
    end;
    if not v_refused then
      raise exception 'FAIL A3: tenant two inserted an organisation into tenant one';
    end if;
    v_rows := v_rows || array['15', 'A3 an organisation with another tenant''s id is refused', 'PASS', 'row-level security (42501)'];

    -- A4. The audit: tenant one flags its office as the application; one audit row, false before and true after
    perform pg_temp.v0008zv_as(x1);
    perform set_config('app.actor_label', 'verify-0008zv', true);
    update cma.organisation set is_contact_center = true where id = (x1 ->> 'office')::uuid;
    perform set_config('role', 'cma_owner', true);
    select count(*) into v_n
    from cma.audit_log a
    where a.tenant_id = (x1 ->> 't')::uuid and a.table_name = 'organisation' and a.action = 'update'
      and a.row_id = x1 ->> 'office' and a.actor_label = 'verify-0008zv'
      and (a.old_row ->> 'is_contact_center')::boolean = false and (a.new_row ->> 'is_contact_center')::boolean = true;
    if v_n <> 1 then
      raise exception 'FAIL A4: % audit rows for the flag''s change, expected 1', v_n;
    end if;
    v_rows := v_rows || array['16', 'A4 a change of the flag is audited', 'PASS', 'one row, false before, true after'];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
  insert into verify_0008zv select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
end
$$;

-- Verdict: one row per check that passed, then the verdict (9 checks; a block that stopped counts its checks as FAIL)
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008zv
      union all
      select 999, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008zv where result = 'PASS') = 9 then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0008zv where result = 'PASS'),
                                        9 - (select count(*) from verify_0008zv where result = 'PASS'))) x
order by ord;
drop function if exists pg_temp.v0008zv_contact_centers();
drop function if exists pg_temp.v0008zv_as(jsonb);
drop function if exists pg_temp.v0008zv_tenant(text);
drop table if exists pg_temp.verify_0008zv;
reset role;
