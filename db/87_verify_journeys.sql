-- =============================================================================================
-- 87_verify_journeys.sql: verifies addition 0008v, journeys as placeholders (Campaign monitoring)
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure
-- and privileges; block B works on two throwaway tenants inside a subtransaction that is always
-- rolled back. Universal otherwise: nothing of the seed is used; the journeys' codes, names, summaries,
-- links and prerequisites are invented values, and no row carries customer data.
-- Every check writes one row, PASS or FAIL, and the last result lists them with the verdict, because
-- Cloud SQL Studio shows no notices. Run as your own IAM login in dev, after 86_journeys.sql.
--   A  structure and privileges: the addition row after 0008u; the table's columns, defaults, checks,
--      unique code per tenant and the market's foreign key; row-level security with the tenant policy, the
--      audit trigger and no delete for the application; the reader view's exact columns; no column named
--      like an address, an email, a phone, a contact or a customer; every function the application's
--      only and in the caller's rights
--   B  behaviour. Tenant one (NL and GB markets) and tenant two (NL only). Checked: a new journey as a
--      placeholder with the defaults and trimmed texts, a change keeping its status and sort order; every
--      refusal of set_journey (code, name, summary, link, prerequisites, sort order: CMA04; an unknown
--      market: CMA02); the statuses, an unknown status and an unknown journey refused; archived hidden
--      from the read and kept in the table, shown again when placed back; no delete for the application;
--      the read's order; an audit row naming the person; the permissions; tenant isolation (the same code
--      in both, no status change across, a market of the other tenant refused); a reader scoped to one
--      tenant
-- Provoke: set provoke below to true; every check must then read FAIL, and the verdict says
-- PROVOKED instead of PASS.
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

-- Dev only: a verifier that writes refuses a database without the dev seed. The flag is kept for the
-- session, so every block below stops at once and the verdict says REFUSED, also where the client
-- carries on after the error
select set_config('verify.is_dev', (exists (select 1 from cma.app_user u join cma.tenant t on t.id = u.tenant_id
                                            where u.email = 'agent.two@example.com' and u.status = 'active'))::text, false) as is_dev;
do $$
begin
  if not current_setting('verify.is_dev')::boolean then
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 87 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0008v;
create temp table verify_0008v (ord int, check_name text, result text, detail text);

-- The error code a statement raises, or 'ok'
create or replace function pg_temp.v0008v_code(p_sql text)
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

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_bad     text;
  v_fn      text;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  -- A1. the addition is recorded, after 0008u
  insert into verify_0008v values (1, 'A1 addition 0008v recorded, after 0008u',
    case when exists (select 1 from cma.schema_migration where version = '0008v')
              and exists (select 1 from cma.schema_migration where version = '0008u') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the table: its columns with types, nullability and defaults; the checks; the unique code per
  --     tenant; the market's foreign key to the catalog
  v_bad := '';
  if (select string_agg(column_name || ':' || udt_name || ':' || is_nullable, ',' order by ordinal_position)
      from information_schema.columns where table_schema = 'cma' and table_name = 'journey')
     is distinct from 'id:uuid:NO,tenant_id:uuid:NO,code:text:NO,name:text:NO,summary:text:YES,market:text:YES,status:text:NO,'
                      || 'design_url:text:YES,prerequisites:_text:NO,sort_order:int4:NO,created_at:timestamptz:NO,updated_at:timestamptz:NO' then
    v_bad := v_bad || 'columns; ';
  end if;
  if (select column_default from information_schema.columns where table_schema = 'cma' and table_name = 'journey' and column_name = 'status')
       is distinct from '''placeholder''::text'
     or (select column_default from information_schema.columns where table_schema = 'cma' and table_name = 'journey' and column_name = 'prerequisites')
       is distinct from '''{}''::text[]' then
    v_bad := v_bad || 'defaults; ';
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'cma.journey'::regclass and contype = 'c'
                 and pg_get_constraintdef(oid) like '%placeholder%building%live%archived%')
     or not exists (select 1 from pg_constraint where conrelid = 'cma.journey'::regclass and contype = 'c'
                    and pg_get_constraintdef(oid) like '%^[a-z][a-z0-9-]{1,40}$%')
     or not exists (select 1 from pg_constraint where conrelid = 'cma.journey'::regclass and contype = 'c'
                    and pg_get_constraintdef(oid) like '%https://%')
     or not exists (select 1 from pg_constraint where conrelid = 'cma.journey'::regclass and contype = 'c'
                    and pg_get_constraintdef(oid) like '%is_journey_prerequisites%') then
    v_bad := v_bad || 'checks; ';
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'cma.journey'::regclass and contype = 'u'
                 and pg_get_constraintdef(oid) = 'UNIQUE (tenant_id, code)')
     or not exists (select 1 from pg_constraint where conrelid = 'cma.journey'::regclass and contype = 'f'
                    and confrelid = 'cma.market'::regclass and pg_get_constraintdef(oid) like 'FOREIGN KEY (tenant_id, market)%') then
    v_bad := v_bad || 'the unique code or the market''s key; ';
  end if;
  insert into verify_0008v values (2, 'A2 the journey table: columns, defaults, checks, the unique code and the market''s key',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A3. tenant-aware as every table: row-level security with the tenant policy, the audit trigger; the
  --     application may read, add and change, never delete
  v_bad := '';
  if not (select relrowsecurity from pg_class where oid = 'cma.journey'::regclass)
     or not exists (select 1 from pg_policy where polrelid = 'cma.journey'::regclass and polname = 'tenant_app') then
    v_bad := v_bad || 'row-level security; ';
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'cma.journey'::regclass and tgname = 'audit' and not tgisinternal) then
    v_bad := v_bad || 'audit trigger; ';
  end if;
  if not has_table_privilege('cma_app', 'cma.journey', 'select') or not has_table_privilege('cma_app', 'cma.journey', 'insert')
     or not has_table_privilege('cma_app', 'cma.journey', 'update') or has_table_privilege('cma_app', 'cma.journey', 'delete')
     or has_table_privilege('cma_readonly', 'cma.journey', 'select') then
    v_bad := v_bad || 'privileges; ';
  end if;
  insert into verify_0008v values (3, 'A3 row-level security, the audit trigger, no delete for the application',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A4. the reader view's exact columns, readable by the readers
  v_bad := '';
  if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'journey')
     is distinct from 'id,tenant_id,code,name,summary,market,status,design_url,prerequisites,sort_order,created_at,updated_at'
     or not has_table_privilege('cma_readonly', 'cma_read.journey', 'select') then
    v_bad := 'cma_read.journey';
  end if;
  insert into verify_0008v values (4, 'A4 the reader view with its exact columns',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A5. no column or argument named like an address, an email, a phone, a contact or a customer (a
  --     journey's name is the journey's, set by a person)
  select string_agg(table_schema || '.' || table_name || '.' || column_name, ', ') into v_bad
  from information_schema.columns
  where table_schema in ('cma', 'cma_read') and table_name = 'journey'
    and column_name ~* '(address|email|phone|contact|customer|first_name|last_name|_hash$)';
  select coalesce(v_bad || ', ', '') || coalesce(string_agg(p.proname || '.' || a, ', '), '') into v_bad
  from pg_proc p
  cross join lateral unnest(p.proargnames) a
  where p.pronamespace = 'cma'::regnamespace and p.proname in ('journeys', 'set_journey', 'set_journey_status')
    and a ~* '(address|email|phone|contact|customer|first_name|last_name|_hash$)';
  insert into verify_0008v values (5, 'A5 no address, email, phone, contact or customer in the table, the view and the functions',
    case when coalesce(v_bad, '') = '' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_bad, ''));

  -- A6. every function of the addition the application's only and in the caller's rights
  v_bad := '';
  foreach v_fn in array array['cma.is_journey_prerequisites(text[])', 'cma.journeys()',
                              'cma.set_journey(text,text,text,text,text,text[],integer)', 'cma.set_journey_status(text,text)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or has_function_privilege('public', v_fn, 'execute')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      v_bad := v_bad || v_fn || ' not the application''s only or not in the caller''s rights; ';
    end if;
  end loop;
  insert into verify_0008v values (6, 'A6 every function the application''s only and in the caller''s rights',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);
end
$$;

-- B. Behaviour on two throwaway tenants (rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_rows     text[] := '{}';
  v_t1 uuid; v_t2 uuid;
  v_admin1 uuid; v_analyst1 uuid; v_reader1 uuid; v_super1 uuid; v_agent1 uuid; v_ing1 uuid;
  v_admin2 uuid; v_analyst2 uuid;
  v_role uuid;
  v_txt text; v_detail text;
  v_lines text[];
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    -- tenants, people and roles (as the owner, as 0008u's verify)
    v_t1 := cma.create_tenant('verify-0008v-one', 'Verify 0008v one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008v-two', 'Verify 0008v two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-analyst1@example.invalid', 'analyst1') returning id into v_analyst1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-reader1@example.invalid', 'reader1') returning id into v_reader1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-super1@example.invalid', 'super1') returning id into v_super1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent1@example.invalid', 'agent1') returning id into v_agent1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin2') returning id into v_admin2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-analyst2@example.invalid', 'analyst2') returning id into v_analyst2;
    insert into cma.app_role (tenant_id, key, name) values (v_t1, 'verify_reader', 'Verify reader') returning id into v_role;
    insert into cma.role_permission (tenant_id, role_id, permission_key) values (v_t1, v_role, 'reports.view');
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_analyst1, 'analytics'), (v_t1, v_reader1, 'verify_reader'), (v_t1, v_super1, 'supervisor'),
                 (v_t1, v_agent1, 'agent'), (v_t2, v_admin2, 'admin'), (v_t2, v_analyst2, 'analytics')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    perform set_config('role', 'cma_app', true);

    -- the markets (the admins): NL and GB in tenant one, NL in tenant two
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP');

    -- B1. a new journey: a placeholder, its texts trimmed, an empty summary and link none, sort order 100,
    --     no prerequisites
    perform cma.set_journey('verify-one', '  Verify one  ', '', 'GB', '  ', null, null);
    select format('%s|%s|%s|%s|%s|%s|%s', j.name, coalesce(j.summary, '-'), j.market, j.status, coalesce(j.design_url, '-'), cardinality(j.prerequisites), j.sort_order)
      into v_txt from cma.journey j where j.tenant_id = v_t1 and j.code = 'verify-one';
    v_rows := v_rows || array['11', 'B1 a new journey: a placeholder with the defaults and its texts trimmed',
      case when v_txt = 'Verify one|-|GB|placeholder|-|0|100' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B2. a change keeps the status (building) and, without one, the sort order; texts, market, link and
    --     prerequisites replaced
    perform cma.set_journey('verify-one', 'Verify one', 'A summary', 'GB', null, null, 20);
    perform cma.set_journey_status('verify-one', 'building');
    perform cma.set_journey('verify-one', 'Verify one, renamed', 'Another summary', null, 'https://design.example.invalid/one',
                            array['First line', 'Second line'], null);
    select format('%s|%s|%s|%s|%s|%s|%s', j.name, j.summary, coalesce(j.market, '-'), j.status, j.design_url, array_to_string(j.prerequisites, '+'), j.sort_order)
      into v_txt from cma.journey j where j.tenant_id = v_t1 and j.code = 'verify-one';
    v_rows := v_rows || array['12', 'B2 a change keeps the status and the sort order; the rest replaced',
      case when v_txt = 'Verify one, renamed|Another summary|-|building|https://design.example.invalid/one|First line+Second line|20'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B3. set_journey's refusals: an upper-case, a one-character, a digit-first and a 42-character code; an
    --     empty and an 81-character name; a 501-character summary; an http link and one with a space; 21
    --     prerequisites, an empty one, a 201-character one, a padded one and a null; a sort order of -1;
    --     all CMA04; an unknown market CMA02
    select array_agg('line ' || g) into v_lines from generate_series(1, 21) g;
    v_txt := '';
    foreach v_detail in array array[
      format('select cma.set_journey(%L, ''N'', null, null, null, null, null)', 'Verify'),
      format('select cma.set_journey(%L, ''N'', null, null, null, null, null)', 'v'),
      format('select cma.set_journey(%L, ''N'', null, null, null, null, null)', '1verify'),
      format('select cma.set_journey(%L, ''N'', null, null, null, null, null)', 'v' || repeat('x', 41)),
      'select cma.set_journey(''verify-two'', ''  '', null, null, null, null, null)',
      format('select cma.set_journey(''verify-two'', %L, null, null, null, null, null)', repeat('n', 81)),
      format('select cma.set_journey(''verify-two'', ''N'', %L, null, null, null, null)', repeat('s', 501)),
      'select cma.set_journey(''verify-two'', ''N'', null, null, ''http://design.example.invalid'', null, null)',
      'select cma.set_journey(''verify-two'', ''N'', null, null, ''https://design.example.invalid/a b'', null, null)',
      format('select cma.set_journey(''verify-two'', ''N'', null, null, null, %L::text[], null)', v_lines),
      'select cma.set_journey(''verify-two'', ''N'', null, null, null, array[''''], null)',
      format('select cma.set_journey(''verify-two'', ''N'', null, null, null, array[%L], null)', repeat('p', 201)),
      'select cma.set_journey(''verify-two'', ''N'', null, null, null, array['' padded''], null)',
      'select cma.set_journey(''verify-two'', ''N'', null, null, null, array[''one'', null], null)',
      'select cma.set_journey(''verify-two'', ''N'', null, null, null, null, -1)',
      'select cma.set_journey(''verify-two'', ''N'', null, ''DE'', null, null, null)'] loop
      v_txt := v_txt || pg_temp.v0008v_code(v_detail) || ' ';
    end loop;
    v_txt := v_txt || (select count(*) from cma.journey j where j.tenant_id = v_t1 and j.code = 'verify-two');
    v_rows := v_rows || array['13', 'B3 set_journey''s refusals: code, name, summary, link, prerequisites, sort order; an unknown market',
      case when v_txt = repeat('CMA04 ', 15) || 'CMA02 0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B4. the statuses: live, archived and back to placeholder taken; another status and an unknown journey
    --     refused
    v_txt := pg_temp.v0008v_code('select cma.set_journey_status(''verify-one'', ''live'')')
      || ' ' || pg_temp.v0008v_code('select cma.set_journey_status(''verify-one'', ''done'')')
      || ' ' || pg_temp.v0008v_code('select cma.set_journey_status(''verify-one'', null)')
      || ' ' || pg_temp.v0008v_code('select cma.set_journey_status(''verify-nothing'', ''live'')');
    -- read in a statement of its own: one that also changes would see the rows as they were when it began
    select v_txt || ' ' || j.status into v_txt from cma.journey j where j.tenant_id = v_t1 and j.code = 'verify-one';
    v_rows := v_rows || array['14', 'B4 the statuses: a status taken; another status, none and an unknown journey refused',
      case when v_txt = 'ok CMA04 CMA04 CMA02 live' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B5. the read's order (sort order, then name, then code) and archived hidden but kept: three journeys,
    --     verify-three archived; placed back it shows again
    perform cma.set_journey('verify-two', 'Beta', null, null, null, null, 20);
    perform cma.set_journey('verify-three', 'Alpha', null, null, null, null, 20);
    perform cma.set_journey('verify-four', 'Alpha', null, null, null, null, 5);
    perform cma.set_journey_status('verify-three', 'archived');
    select string_agg(j.code || ':' || j.status, ' ') into v_txt from cma.journeys() j;
    select v_txt || ' | ' || count(*) into v_txt from cma.journey j where j.tenant_id = v_t1;
    perform cma.set_journey_status('verify-three', 'placeholder');
    select v_txt || ' | ' || string_agg(j.code, ' ') into v_txt from cma.journeys() j;
    v_rows := v_rows || array['15', 'B5 the read''s order; archived hidden from it and kept in the table; placed back shown',
      case when v_txt = 'verify-four:placeholder verify-two:placeholder verify-one:live | 4 | verify-four verify-three verify-two verify-one'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B6. never deleted: the application cannot delete a journey (not even its own tenant's)
    v_txt := pg_temp.v0008v_code('delete from cma.journey where code = ''verify-four''')
      || ' ' || (select count(*) from cma.journey j where j.tenant_id = v_t1 and j.code = 'verify-four');
    v_rows := v_rows || array['16', 'B6 no delete for the application',
      case when v_txt = '42501 1' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B7. the audit: verify-one's insert, its two changes and its two statuses, each naming the admin
    select format('%s/%s/%s', count(*) filter (where a.action = 'insert'), count(*) filter (where a.action = 'update'),
                  bool_and(a.actor_user_id = v_admin1))
      into v_txt from cma.audit_log a where a.tenant_id = v_t1 and a.table_name = 'journey' and a.new_row ->> 'code' = 'verify-one';
    v_rows := v_rows || array['17', 'B7 an audit row for every change, naming the person',
      case when v_txt = '1/4/t' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B8. the permissions: the read for reports.view (the reader), performance.team (the supervisor) and the
    --     analyst, not the agent or the Ingest user; the configuration for tenant.configure only (the analyst
    --     and the supervisor refused); no acting user CMA01
    v_txt := '';
    foreach v_detail in array array[v_reader1::text, v_super1::text, v_analyst1::text, v_agent1::text, v_ing1::text] loop
      perform set_config('app.user_id', v_detail, true);
      v_txt := v_txt || pg_temp.v0008v_code('select * from cma.journeys()')
        || '/' || pg_temp.v0008v_code('select cma.set_journey(''verify-five'', ''Five'', null, null, null, null, null)')
        || '/' || pg_temp.v0008v_code('select cma.set_journey_status(''verify-one'', ''building'')') || ' ';
    end loop;
    perform set_config('app.user_id', '', true);
    v_txt := v_txt || pg_temp.v0008v_code('select * from cma.journeys()');
    perform set_config('app.user_id', v_admin1::text, true);
    v_rows := v_rows || array['18', 'B8 the permissions: the read for reports.view or performance.team; configuration for tenant.configure',
      case when v_txt = 'ok/CMA06/CMA06 ok/CMA06/CMA06 ok/CMA06/CMA06 CMA06/CMA06/CMA06 CMA06/CMA06/CMA06 CMA01' and not v_provoke
           then 'PASS' else 'FAIL' end, v_txt];

    -- B9. tenant isolation: tenant two sees none of tenant one's journeys, keeps the same code apart, cannot
    --     change tenant one's status, and cannot use a market only tenant one holds
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    v_txt := (select count(*)::text from cma.journeys())
      || ' ' || pg_temp.v0008v_code('select cma.set_journey_status(''verify-two'', ''live'')')
      || ' ' || pg_temp.v0008v_code('select cma.set_journey(''verify-one'', ''Two''''s one'', null, ''NL'', null, null, null)')
      || ' ' || pg_temp.v0008v_code('select cma.set_journey(''verify-six'', ''Six'', null, ''GB'', null, null, null)');
    select v_txt || ' ' || string_agg(j.code || ':' || j.name, ' ') into v_txt from cma.journeys() j;
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    select v_txt || ' | ' || string_agg(j.name || ':' || j.status, ' ' order by j.code) into v_txt from cma.journeys() j where j.code in ('verify-one', 'verify-two');
    v_rows := v_rows || array['19', 'B9 tenant isolation: the reads, the same code apart, no change across, the other''s market refused',
      case when v_txt = '0 CMA02 ok CMA02 verify-one:Two''s one | Verify one, renamed:live Beta:placeholder' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B10. a reader scoped to tenant one sees its four journeys (the archived ones too: a reporting view) and
    --      none of tenant two's; scoped to tenant two, none of tenant one's
    perform cma.set_journey_status('verify-three', 'archived');
    perform set_config('role', 'cma_readonly', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    select format('%s/%s/%s', (select count(*) from cma_read.journey where tenant_id = v_t1),
                  (select count(*) from cma_read.journey where tenant_id = v_t1 and status = 'archived'),
                  (select count(*) from cma_read.journey where tenant_id = v_t2)) into v_txt;
    perform set_config('app.tenant_id', v_t2::text, true);
    select v_txt || format(' %s/%s', (select count(*) from cma_read.journey where tenant_id = v_t1),
                           (select count(*) from cma_read.journey where tenant_id = v_t2)) into v_txt;
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['20', 'B10 a reader scoped to one tenant sees its own journeys only',
      case when v_txt = '4/1/0 0/1' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['39', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008v (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008v values (39, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008v
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED: not dev'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008v where result = 'PASS') = 16
                       and not exists (select 1 from verify_0008v where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0008v where result = 'PASS'),
                                        (select count(*) from verify_0008v where result <> 'PASS'))) x
order by ord;
drop function if exists pg_temp.v0008v_code(text);
