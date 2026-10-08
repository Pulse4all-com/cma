-- =============================================================================================
-- 18_verify_clock_in_app_links.sql: verifies addition 0003d
-- =============================================================================================
-- Both blocks are universal: A checks structure and privileges, B works on throwaway tenants,
-- users and links inside a subtransaction that is always rolled back. No seed is assumed.
-- Cloud SQL Studio shows no notices: a check that fails raises "FAIL …" and stops the script.
-- The last result is the verdict. Run as your own IAM login, dev and prod.
-- Provoke: set provoke below to true; every block must then stop with FAIL, and the verdict
-- (reached only when the run does not stop on errors) says PROVOKED instead of PASS.
-- After this script, rerun 07, 10 and 16 in dev: they create days on throwaway users and prove
-- that the guard changed nothing for people whose time is kept.
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

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_links   text := 'cma.app_links()';
  v_fn      text;
begin
  if not exists (select 1 from cma.schema_migration where version = '0003d') then
    raise exception 'FAIL A1: addition 0003d not recorded';
  end if;
  foreach v_fn in array array['cma.time_is_kept(uuid)', 'cma.assert_time_kept(uuid)', v_links,
                              'cma.open_workday(timestamptz)', 'cma.correct_workday(uuid, date, jsonb, text)',
                              'cma.team_people()'] loop
    if to_regprocedure(v_fn) is null then
      raise exception 'FAIL A2: % does not exist', v_fn;
    end if;
  end loop;
  if to_regclass('cma.app_link') is null or to_regclass('cma_read.app_link') is null then
    raise exception 'FAIL A3: cma.app_link or cma_read.app_link does not exist';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'cma.app_link'::regclass)
     or not exists (select 1 from pg_policies where schemaname = 'cma' and tablename = 'app_link' and policyname = 'tenant_app')
     or not exists (select 1 from pg_trigger where tgrelid = 'cma.app_link'::regclass and tgname = 'audit')
     or v_provoke then
    raise exception 'FAIL A4: app_link must have row-level security, the tenant_app policy and the audit trigger';
  end if;
  -- Until 0005a the app only reads links; since 0005a (the configuration functions, 8 October 2026)
  -- it inserts and updates them through cma.upsert_app_link() and cma.retire_app_link(). Delete: never.
  if not has_table_privilege('cma_app', 'cma.app_link', 'select')
     or has_table_privilege('cma_app', 'cma.app_link', 'delete')
     or (has_table_privilege('cma_app', 'cma.app_link', 'insert') or has_table_privilege('cma_app', 'cma.app_link', 'update'))
        <> exists (select 1 from cma.schema_migration where version = '0005a') then
    raise exception 'FAIL A5: cma_app must read app_link, write it only since 0005a, and never delete from it';
  end if;
  if has_table_privilege('cma_readonly', 'cma.app_link', 'select')
     or not has_table_privilege('cma_readonly', 'cma_read.app_link', 'select') then
    raise exception 'FAIL A6: readers see cma_read.app_link only';
  end if;
  if not has_function_privilege('cma_app', v_links, 'execute')
     or has_function_privilege('cma_readonly', v_links, 'execute')
     or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                where p.oid = to_regprocedure(v_links) and a.grantee = 0 and a.privilege_type = 'EXECUTE') then
    raise exception 'FAIL A7: execute on app_links must be granted to cma_app only (not to cma_readonly or public)';
  end if;
  if (select prosecdef from pg_proc where oid = to_regprocedure(v_links)) then
    raise exception 'FAIL A8: % must run with the caller''s rights, not as its owner', v_links;
  end if;
end
$$;

-- B. Behaviour on throwaway tenants (universal, always rolled back)
--    Tenant one: an agent, a second agent, a supervisor and an analyst from the default ladder,
--    plus a person without any role. Tenant two: an agent. Three links in tenant one (open,
--    supervisors only, inactive) and one in tenant two.
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_today    date := (now() at time zone 'UTC')::date;
  v_d        date := (now() at time zone 'UTC')::date - 3;
  v_d2       date := (now() at time zone 'UTC')::date - 2;
  v_t1       uuid;
  v_t2       uuid;
  v_agent    uuid;
  v_agent2   uuid;
  v_super    uuid;
  v_analyst  uuid;
  v_norole   uuid;
  v_agent_t2 uuid;
  v_n        int;
  v_links    text;
  v_audit    bigint;
  w          cma.workday;
begin
  begin
    -- Setup as owner
    v_t1 := cma.create_tenant('verify-0003d-one', 'Verify 0003d one', 'UTC');
    v_t2 := cma.create_tenant('verify-0003d-two', 'Verify 0003d two', 'UTC');
    insert into cma.app_user (tenant_id, email, display_name)
    values (v_t1, 'verify-agent@example.invalid', 'Verify agent') returning id into v_agent;
    insert into cma.app_user (tenant_id, email, display_name)
    values (v_t1, 'verify-agent-two@example.invalid', 'Verify agent two') returning id into v_agent2;
    insert into cma.app_user (tenant_id, email, display_name)
    values (v_t1, 'verify-supervisor@example.invalid', 'Verify supervisor') returning id into v_super;
    insert into cma.app_user (tenant_id, email, display_name)
    values (v_t1, 'verify-analyst@example.invalid', 'Verify analyst') returning id into v_analyst;
    insert into cma.app_user (tenant_id, email, display_name)
    values (v_t1, 'verify-norole@example.invalid', 'Verify no role') returning id into v_norole;
    insert into cma.app_user (tenant_id, email, display_name)
    values (v_t2, 'verify-agent@example.invalid', 'Verify agent of two') returning id into v_agent_t2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t1, x.uid, ar.id
    from (values (v_agent, 'agent'), (v_agent2, 'agent'), (v_super, 'supervisor'), (v_analyst, 'analytics')) as x(uid, role_key)
    join cma.app_role ar on ar.tenant_id = v_t1 and ar.key = x.role_key;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t2, v_agent_t2, id from cma.app_role where tenant_id = v_t2 and key = 'agent';

    select count(*) into v_audit from cma.audit_log where tenant_id = v_t1 and table_name = 'app_link';
    insert into cma.app_link (tenant_id, key, label, address, permission_key, sort_order, status) values
      (v_t1, 'verify-crm',   'Verify CRM',        'https://example.invalid/crm',   null,           20, 'active'),
      (v_t1, 'verify-team',  'Verify team sheet', 'https://example.invalid/team',  'workday.team', 10, 'active'),
      (v_t1, 'verify-old',   'Verify retired',    'https://example.invalid/old',   null,           30, 'inactive'),
      (v_t2, 'verify-phone', 'Verify phone',      'https://example.invalid/phone', null,           10, 'active');

    -- B1. the address must be https: refused by the table, whatever path writes it
    begin
      insert into cma.app_link (tenant_id, key, label, address)
      values (v_t1, 'verify-plain', 'Verify plain', 'http://example.invalid/plain');
      raise exception 'FAIL B1: a link without https was accepted';
    exception when check_violation then null;
    end;

    -- B2. every insert left an audit row
    select count(*) - v_audit into v_n from cma.audit_log where tenant_id = v_t1 and table_name = 'app_link';
    if v_n <> 3 or v_provoke then
      raise exception 'FAIL B2: expected 3 audit rows for the links of tenant one, got %', v_n;
    end if;

    -- From here on as the application
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);

    -- B3. the analyst (performance.team, no workday.own) cannot open a day
    perform set_config('app.user_id', v_analyst::text, true);
    begin
      perform cma.open_workday();
      raise exception 'FAIL B3: a day was opened for someone whose time is not kept';
    exception when sqlstate 'CMA06' then null;
    end;
    if exists (select 1 from cma.workday where user_id = v_analyst) then
      raise exception 'FAIL B3: a day exists for the analyst after the refusal';
    end if;

    -- B4. a person without any role cannot open a day either
    perform set_config('app.user_id', v_norole::text, true);
    begin
      perform cma.open_workday();
      raise exception 'FAIL B4: a day was opened for someone without a role';
    exception when sqlstate 'CMA06' then null;
    end;

    -- B5. the agent opens today, and a second call returns that day unchanged
    perform set_config('app.user_id', v_agent::text, true);
    w := cma.open_workday();
    if w.status <> 'open' or w.business_date <> v_today then
      raise exception 'FAIL B5: the agent''s day did not open today (status %, date %)', w.status, w.business_date;
    end if;
    if (cma.open_workday()).id <> w.id then
      raise exception 'FAIL B5: a second open_workday did not return the same day';
    end if;

    -- B6. Add day: refused for the analyst, allowed for the agent
    perform set_config('app.user_id', v_super::text, true);
    begin
      perform cma.correct_workday(v_analyst, v_d, jsonb_build_array(
        jsonb_build_object('kind', 'start', 'statusKey', (select key from cma.work_status where tenant_id = v_t1 and is_default),
                           'at', to_char(v_d, 'YYYY-MM-DD') || 'T09:00:00Z')),
        'Verify 0003d: Add day for someone whose time is not kept');
      raise exception 'FAIL B6: Add day created a day for someone whose time is not kept';
    exception when sqlstate 'CMA06' then null;
    end;
    w := cma.correct_workday(v_agent, v_d, jsonb_build_array(
      jsonb_build_object('kind', 'start', 'statusKey', (select key from cma.work_status where tenant_id = v_t1 and is_default),
                         'at', to_char(v_d, 'YYYY-MM-DD') || 'T09:00:00Z'),
      jsonb_build_object('kind', 'end', 'at', to_char(v_d, 'YYYY-MM-DD') || 'T17:00:00Z')),
      'Verify 0003d: Add day for the agent');
    if w.status <> 'ended' or w.business_date <> v_d then
      raise exception 'FAIL B6: Add day for the agent did not create an ended day on %', v_d;
    end if;

    -- B7. team_people lists exactly the people whose time is kept
    select string_agg(p.display_name, ', ' order by p.display_name) into v_links from cma.team_people() p;
    if v_links <> 'Verify agent, Verify agent two, Verify supervisor' then
      raise exception 'FAIL B7: team_people listed %', v_links;
    end if;

    -- B8. a leaver: the agent's role is removed; the existing day can still be corrected,
    --     no new day can be added, and team_people no longer lists them
    perform set_config('role', 'cma_owner', true);
    delete from cma.user_role where tenant_id = v_t1 and user_id = v_agent;
    perform set_config('role', 'cma_app', true);
    w := cma.correct_workday(v_agent, v_today, jsonb_build_array(
      jsonb_build_object('kind', 'end', 'at', to_char((now() + interval '1 second') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'))),
      'Verify 0003d: closing the day of a person who left');
    if w.status <> 'ended' then
      raise exception 'FAIL B8: the existing day of a person without a role could not be corrected';
    end if;
    begin
      perform cma.correct_workday(v_agent, v_d2, jsonb_build_array(
        jsonb_build_object('kind', 'start', 'statusKey', (select key from cma.work_status where tenant_id = v_t1 and is_default),
                           'at', to_char(v_d2, 'YYYY-MM-DD') || 'T09:00:00Z')),
        'Verify 0003d: Add day for a person who left');
      raise exception 'FAIL B8: Add day created a day for a person whose time is no longer kept';
    exception when sqlstate 'CMA06' then null;
    end;
    if exists (select 1 from cma.team_people() p where p.user_id = v_agent) then
      raise exception 'FAIL B8: team_people still lists a person whose time is no longer kept';
    end if;

    -- B9. a person who lost the clock during the day: their existing day is still returned,
    --     unchanged (no new day, nothing opened)
    perform set_config('app.user_id', v_agent::text, true);
    if (cma.open_workday()).id <> w.id or (cma.open_workday()).status <> 'ended' then
      raise exception 'FAIL B9: open_workday did not return the existing ended day unchanged';
    end if;

    -- B10. app links: the open link for the second agent, the open and the supervisors-only link
    --      for the supervisor, in sort order; the inactive link for nobody
    perform set_config('app.user_id', v_agent2::text, true);
    select string_agg(l.key, ', ' order by l.sort_order, l.key) into v_links from cma.app_links() l;
    if v_links is distinct from 'verify-crm' then
      raise exception 'FAIL B10: the agent saw links [%], expected the open link only', v_links;
    end if;
    perform set_config('app.user_id', v_super::text, true);
    select string_agg(l.key, ', ' order by l.sort_order, l.key) into v_links from cma.app_links() l;
    if v_links is distinct from 'verify-team, verify-crm' then
      raise exception 'FAIL B10: the supervisor saw links [%], expected the team link first, then the open link', v_links;
    end if;
    select count(*) into v_n from cma.app_links() l where l.address !~ '^https://';
    if v_n <> 0 then
      raise exception 'FAIL B10: a link without https came back';
    end if;

    -- B11. the application cannot write links as an agent: no table right before 0005a, and since
    -- 0005a the write function refuses without tenant.configure (CMA06); a plain delete never works
    begin
      insert into cma.app_link (tenant_id, key, label, address) values (v_t1, 'verify-app', 'Verify app', 'https://example.invalid/app');
      if not exists (select 1 from cma.schema_migration where version = '0005a') then
        raise exception 'FAIL B11: cma_app inserted a link';
      end if;
    exception when insufficient_privilege then null;
    end;
    if exists (select 1 from cma.schema_migration where version = '0005a') then
      begin
        perform cma.upsert_app_link('verify-app2', 'Verify app', 'https://example.invalid/app');
        raise exception 'FAIL B11: an agent wrote a link through upsert_app_link';
      exception when sqlstate 'CMA06' then null;
      end;
    end if;
    begin
      delete from cma.app_link where key = 'verify-phone';
      raise exception 'FAIL B11: cma_app deleted a link';
    exception when insufficient_privilege then null;
    end;

    -- B12. another tenant sees only its own links, and the first tenant's people are not its people
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_agent_t2::text, true);
    select string_agg(l.key, ', ') into v_links from cma.app_links() l;
    if v_links is distinct from 'verify-phone' then
      raise exception 'FAIL B12: tenant two saw links [%]', v_links;
    end if;
    if exists (select 1 from cma.workday where user_id in (v_agent, v_agent2)) then
      raise exception 'FAIL B12: tenant one''s days are visible in tenant two';
    end if;

    -- B13. no acting user: refused
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', '', true);
    begin
      perform cma.app_links();
      raise exception 'FAIL B13: links were read without an acting user';
    exception when sqlstate 'CMA01' then null;
    end;
    begin
      perform cma.open_workday();
      raise exception 'FAIL B13: a day was opened without an acting user';
    exception when sqlstate 'CMA01' then null;
    end;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- Verdict: per tenant, the roles whose time is kept and the active app links
select t.slug as tenant,
       coalesce((select string_agg(ar.key, ', ' order by ar.key)
                 from cma.app_role ar
                 where ar.tenant_id = t.id
                   and exists (select 1 from cma.role_permission rp
                               where rp.tenant_id = ar.tenant_id and rp.role_id = ar.id and rp.permission_key = 'workday.own')),
                '(none)') as roles_with_workday_own,
       coalesce((select string_agg(l.key, ', ' order by l.sort_order, l.key)
                 from cma.app_link l where l.tenant_id = t.id and l.status = 'active'), '(none)') as active_app_links,
       case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS' else 'PASS' end as verdict
from cma.tenant t
where t.status = 'active'
order by t.slug;
