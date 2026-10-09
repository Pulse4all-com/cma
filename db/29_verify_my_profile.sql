-- =============================================================================================
-- 29_verify_my_profile.sql: verifies addition 0005b, cma.my_profile()
-- =============================================================================================
-- Block A checks structure and privileges; block B works on two throwaway tenants inside a
-- subtransaction that is always rolled back. Both universal: no seed is assumed. Cloud SQL Studio
-- shows no notices: a check that fails raises "FAIL …" and stops the script. The last result is
-- the verdict. Run as your own IAM login, dev and prod, after 28_my_profile.sql.
-- Provoke: set provoke below to true; every block must then stop with FAIL, and the verdict
-- (reached only when the run does not stop on errors) says PROVOKED instead of PASS.
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
  v_fn      text := 'cma.my_profile()';
  v_cols    text;
begin
  if not exists (select 1 from cma.schema_migration where version = '0005b') then
    raise exception 'FAIL A1: addition 0005b not recorded';
  end if;
  if to_regprocedure(v_fn) is null then
    raise exception 'FAIL A2: % does not exist', v_fn;
  end if;
  select string_agg(a.attname, ', ' order by a.n) into v_cols
  from pg_proc p
  join lateral unnest(p.proargnames, p.proargmodes) with ordinality as a(attname, attmode, n) on true
  where p.oid = to_regprocedure(v_fn) and a.attmode = 't';
  if v_cols is distinct from 'user_id, email, display_name, organisation_key, organisation_name, timezone, role_key, role_name, time_kept, teams, skills'
     or v_provoke then
    raise exception 'FAIL A3: my_profile returns [%]', v_cols;
  end if;
  if not has_function_privilege('cma_app', v_fn, 'execute')
     or has_function_privilege('cma_readonly', v_fn, 'execute')
     or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE') then
    raise exception 'FAIL A4: execute on my_profile must be granted to cma_app only (not to cma_readonly or public)';
  end if;
  if (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
    raise exception 'FAIL A5: % must run with the caller''s rights, not as its owner', v_fn;
  end if;
  if (select provolatile from pg_proc where oid = to_regprocedure(v_fn)) <> 's' then
    raise exception 'FAIL A6: % must be stable (a read, never a write)', v_fn;
  end if;
  if (select pronargs from pg_proc where oid = to_regprocedure(v_fn)) <> 0 then
    raise exception 'FAIL A7: % must take no argument (the acting user only, never a chosen one)', v_fn;
  end if;
end
$$;

-- B. Behaviour (universal, throwaway tenants, rolled back)
--    Tenant one, zone UTC: an agent at an employer in Europe/Madrid with two current teams, one
--    ended membership and one membership of a dissolved team; a language with a level, a work type,
--    and a skill that ended. A supervisor, a person without a role, an inactive agent, and the
--    tenant's scheduler. Tenant two: an agent with the same email.
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_t1       uuid;
  v_t2       uuid;
  v_org      uuid;
  v_agent    uuid;
  v_super    uuid;
  v_norole   uuid;
  v_gone     uuid;
  v_sched    uuid;
  v_agent_t2 uuid;
  v_ta       uuid;
  v_tb       uuid;
  v_tc       uuid;
  v_tdis     uuid;
  v_lang     uuid;
  v_lang2    uuid;
  v_work     uuid;
  v_n        int;
  r          record;
begin
  begin
    -- Setup as owner
    v_t1 := cma.create_tenant('verify-0005b-one', 'Verify 0005b one', 'UTC');
    v_t2 := cma.create_tenant('verify-0005b-two', 'Verify 0005b two', 'UTC');
    insert into cma.organisation (tenant_id, key, name, timezone)
    values (v_t1, 'verify-employer', 'Verify employer', 'Europe/Madrid') returning id into v_org;
    insert into cma.app_user (tenant_id, organisation_id, email, display_name)
    values (v_t1, v_org, 'verify-agent@example.invalid', 'Verify agent') returning id into v_agent;
    insert into cma.app_user (tenant_id, email, display_name)
    values (v_t1, 'verify-supervisor@example.invalid', 'Verify supervisor') returning id into v_super;
    insert into cma.app_user (tenant_id, email, display_name)
    values (v_t1, 'verify-norole@example.invalid', 'Verify no role') returning id into v_norole;
    insert into cma.app_user (tenant_id, email, display_name, status)
    values (v_t1, 'verify-gone@example.invalid', 'Verify gone', 'inactive') returning id into v_gone;
    insert into cma.app_user (tenant_id, email, display_name)
    values (v_t2, 'verify-agent@example.invalid', 'Verify agent of two') returning id into v_agent_t2;
    select id into v_sched from cma.app_user where tenant_id = v_t1 and kind = 'system';
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t1, x.uid, ar.id
    from (values (v_agent, 'agent'), (v_super, 'supervisor'), (v_gone, 'agent')) as x(uid, role_key)
    join cma.app_role ar on ar.tenant_id = v_t1 and ar.key = x.role_key;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t2, v_agent_t2, ar.id from cma.app_role ar where ar.tenant_id = v_t2 and ar.key = 'agent';

    insert into cma.team (tenant_id, key, name, sort_order) values (v_t1, 'verify-b', 'Verify team B', 20) returning id into v_tb;
    insert into cma.team (tenant_id, key, name, sort_order) values (v_t1, 'verify-a', 'Verify team A', 10) returning id into v_ta;
    insert into cma.team (tenant_id, key, name, sort_order) values (v_t1, 'verify-c', 'Verify team C', 30) returning id into v_tc;
    insert into cma.team (tenant_id, key, name, sort_order, valid_to)
    values (v_t1, 'verify-dissolved', 'Verify dissolved', 5, now()) returning id into v_tdis;
    insert into cma.team_member (tenant_id, user_id, team_id) values (v_t1, v_agent, v_tb), (v_t1, v_agent, v_ta), (v_t1, v_agent, v_tdis);
    insert into cma.team_member (tenant_id, user_id, team_id, valid_from, valid_to)
    values (v_t1, v_agent, v_tc, now() - interval '30 days', now() - interval '1 day');
    insert into cma.team_member (tenant_id, user_id, team_id) values (v_t1, v_super, v_tc);

    insert into cma.skill (tenant_id, dimension, key, name, sort_order) values (v_t1, 'language', 'verify-l1', 'Verify language', 10) returning id into v_lang;
    insert into cma.skill (tenant_id, dimension, key, name, sort_order) values (v_t1, 'language', 'verify-l2', 'Verify language two', 20) returning id into v_lang2;
    insert into cma.skill (tenant_id, dimension, key, name, sort_order) values (v_t1, 'work_type', 'verify-w1', 'Verify work type', 10) returning id into v_work;
    insert into cma.user_skill (tenant_id, user_id, skill_id, level) values (v_t1, v_agent, v_work, null), (v_t1, v_agent, v_lang, 3);
    insert into cma.user_skill (tenant_id, user_id, skill_id, level, valid_from, valid_to)
    values (v_t1, v_agent, v_lang2, 1, now() - interval '30 days', now() - interval '1 day');

    -- From here on as the application
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);

    -- B1. the agent reads exactly one row: their own, with employer, the employer's zone, the role
    --     and a kept clock
    perform set_config('app.user_id', v_agent::text, true);
    select count(*) into v_n from cma.my_profile();
    select * into r from cma.my_profile();
    if v_n <> 1 or r.user_id <> v_agent or r.email <> 'verify-agent@example.invalid' or r.display_name <> 'Verify agent'
       or r.organisation_key <> 'verify-employer' or r.organisation_name <> 'Verify employer' or r.timezone <> 'Europe/Madrid'
       or r.role_key <> 'agent' or r.time_kept is not true or v_provoke then
      raise exception 'FAIL B1: the agent read % rows: (%, %, %, %, %, kept %)',
        v_n, r.display_name, r.organisation_key, r.timezone, r.role_key, r.role_name, r.time_kept;
    end if;

    -- B2. current teams only, in team order: not the ended membership, not the dissolved team
    if r.teams is distinct from '[{"key": "verify-a", "name": "Verify team A"}, {"key": "verify-b", "name": "Verify team B"}]'::jsonb then
      raise exception 'FAIL B2: the agent''s teams are %', r.teams;
    end if;

    -- B3. current skills only, language before work type, the level with its name; a binary
    --     dimension without a level
    if r.skills is distinct from
       '[{"dimension": "language", "key": "verify-l1", "name": "Verify language", "level": 3, "levelName": "Fluent"},
         {"dimension": "work_type", "key": "verify-w1", "name": "Verify work type", "level": null, "levelName": null}]'::jsonb then
      raise exception 'FAIL B3: the agent''s skills are %', r.skills;
    end if;

    -- B4. the supervisor reads their own row, never the agent's
    perform set_config('app.user_id', v_super::text, true);
    select count(*) into v_n from cma.my_profile() p where p.user_id = v_super;
    if v_n <> 1 or (select count(*) from cma.my_profile()) <> 1
       or (select p.teams from cma.my_profile() p) is distinct from '[{"key": "verify-c", "name": "Verify team C"}]'::jsonb then
      raise exception 'FAIL B4: the supervisor read another row or the wrong teams';
    end if;

    -- B5. a person without a role reads their row: no role, no clock, no teams, no skills
    perform set_config('app.user_id', v_norole::text, true);
    select * into r from cma.my_profile();
    if r.user_id <> v_norole or r.role_key is not null or r.role_name is not null or r.time_kept
       or r.teams <> '[]'::jsonb or r.skills <> '[]'::jsonb or r.organisation_name <> '' or r.timezone <> 'UTC' then
      raise exception 'FAIL B5: the person without a role read (role %, kept %, teams %, skills %, employer [%], zone %)',
        r.role_key, r.time_kept, r.teams, r.skills, r.organisation_name, r.timezone;
    end if;

    -- B6. an inactive person is refused
    perform set_config('app.user_id', v_gone::text, true);
    begin
      perform cma.my_profile();
      raise exception 'FAIL B6: an inactive person read a profile';
    exception when sqlstate 'CMA01' then null;
    end;

    -- B7. the tenant's scheduler, a system user, is refused
    if v_sched is null then
      raise exception 'FAIL B7: the throwaway tenant has no scheduler (0005a create_tenant)';
    end if;
    perform set_config('app.user_id', v_sched::text, true);
    begin
      perform cma.my_profile();
      raise exception 'FAIL B7: the scheduler read a profile';
    exception when sqlstate 'CMA01' then null;
    end;

    -- B8. tenant isolation: tenant one's agent in tenant two's context is refused; tenant two's
    --     agent reads their own row, without tenant one's teams
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_agent::text, true);
    begin
      perform cma.my_profile();
      raise exception 'FAIL B8: a person read a profile in another tenant';
    exception when sqlstate 'CMA01' then null;
    end;
    perform set_config('app.user_id', v_agent_t2::text, true);
    select * into r from cma.my_profile();
    if r.user_id <> v_agent_t2 or r.display_name <> 'Verify agent of two' or r.teams <> '[]'::jsonb or r.skills <> '[]'::jsonb then
      raise exception 'FAIL B8: tenant two''s agent read (%, teams %)', r.display_name, r.teams;
    end if;

    -- B9. no acting user: refused
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', '', true);
    begin
      perform cma.my_profile();
      raise exception 'FAIL B9: a profile was read without an acting user';
    exception when sqlstate 'CMA01' then null;
    end;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- Verdict: per tenant, the active people (system users excluded) who can open My account
select t.slug as tenant,
       (select count(*) from cma.app_user u where u.tenant_id = t.id and u.status = 'active' and u.kind = 'person') as people,
       case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS' else 'PASS' end as verdict
from cma.tenant t
where t.status = 'active'
order by t.slug;
