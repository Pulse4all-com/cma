-- =============================================================================================
-- 22_verify_teams_skills.sql: verifies migration 0004
-- =============================================================================================
-- Block A checks structure, privileges and the ladder; block B works on throwaway tenants and
-- users inside a subtransaction that is always rolled back. Both universal: no seed is assumed.
-- Cloud SQL Studio shows no notices: a check that fails raises "FAIL …" and stops the script.
-- The last result is the verdict. Run as your own IAM login, dev and prod.
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

-- A. Structure, privileges and the ladder (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_t       text;
  v_fn      text;
  v_n       int;
begin
  if not exists (select 1 from cma.schema_migration where version = '0004') then
    raise exception 'FAIL A1: migration 0004 not recorded';
  end if;

  -- A2. the five tables: RLS, the app policy, the audit trigger, no delete for the app
  foreach v_t in array array['team', 'team_member', 'skill', 'skill_level', 'user_skill'] loop
    if to_regclass('cma.' || v_t) is null then
      raise exception 'FAIL A2: table cma.% is missing', v_t;
    end if;
    if not (select relrowsecurity from pg_class where oid = to_regclass('cma.' || v_t)) then
      raise exception 'FAIL A2: cma.% has no row-level security', v_t;
    end if;
    if not exists (select 1 from pg_policies where schemaname = 'cma' and tablename = v_t and policyname = 'tenant_app') then
      raise exception 'FAIL A2: cma.% has no tenant_app policy', v_t;
    end if;
    if not exists (select 1 from pg_trigger where tgrelid = to_regclass('cma.' || v_t) and tgname = 'audit') then
      raise exception 'FAIL A2: cma.% has no audit trigger', v_t;
    end if;
    if v_t <> 'skill_level' and has_table_privilege('cma_app', 'cma.' || v_t, 'delete') then
      raise exception 'FAIL A2: cma_app may delete from cma.%', v_t;
    end if;
    if not has_table_privilege('cma_app', 'cma.' || v_t, 'insert') or v_provoke then
      raise exception 'FAIL A2: cma_app cannot insert into cma.%', v_t;
    end if;
    if to_regclass('cma_read.' || v_t) is null then
      raise exception 'FAIL A2: reporting view cma_read.% is missing', v_t;
    end if;
  end loop;

  -- A3. the functions: the app may execute them, readers and public may not, none runs as owner
  foreach v_fn in array array[
    'cma.directory()', 'cma.roles()', 'cma.teams()', 'cma.skills()', 'cma.organisations()', 'cma.team_members_now()',
    'cma.add_person(text,text,text,text,text,text,text)', 'cma.set_person_role(uuid,text)',
    'cma.set_person_active(uuid,boolean)', 'cma.set_person_teams(uuid,text[])', 'cma.set_person_skills(uuid,jsonb)',
    'cma.upsert_team(text,text,text[],integer)', 'cma.dissolve_team(text)',
    'cma.upsert_skill(text,text,text,integer,text)', 'cma.set_skill_levels(text,jsonb)'] loop
    if to_regprocedure(v_fn) is null then
      raise exception 'FAIL A3: % does not exist', v_fn;
    end if;
    if not has_function_privilege('cma_app', v_fn, 'execute')
       or has_function_privilege('cma_readonly', v_fn, 'execute')
       or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                  where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE') then
      raise exception 'FAIL A3: execute on % must be granted to cma_app only', v_fn;
    end if;
    if (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      raise exception 'FAIL A3: % must run with the caller''s rights', v_fn;
    end if;
  end loop;
  if has_function_privilege('cma_app', 'cma.seed_default_skill_levels(uuid)', 'execute') then
    raise exception 'FAIL A3: seed_default_skill_levels is for the owner only';
  end if;

  -- A4. the permission catalog: the split, users.manage gone
  if not exists (select 1 from cma.permission where key = 'users.manage_agents')
     or not exists (select 1 from cma.permission where key = 'users.manage_all')
     or exists (select 1 from cma.permission where key = 'users.manage') then
    raise exception 'FAIL A4: the permission catalog does not carry users.manage_agents and users.manage_all without users.manage';
  end if;

  -- A5. every tenant: an admin system role with tenant.configure and users.manage_all, a system
  --     manager without them but with users.manage_agents, and the language scale
  select count(*) into v_n from cma.tenant t
  where not exists (select 1 from cma.app_role ar where ar.tenant_id = t.id and ar.key = 'admin' and ar.is_system
                      and exists (select 1 from cma.role_permission rp where rp.tenant_id = ar.tenant_id and rp.role_id = ar.id and rp.permission_key = 'tenant.configure')
                      and exists (select 1 from cma.role_permission rp where rp.tenant_id = ar.tenant_id and rp.role_id = ar.id and rp.permission_key = 'users.manage_all'));
  if v_n <> 0 then
    raise exception 'FAIL A5: % tenant(s) without a complete admin role', v_n;
  end if;
  select count(*) into v_n from cma.app_role ar
  where ar.key = 'manager' and ar.is_system
    and (exists (select 1 from cma.role_permission rp where rp.tenant_id = ar.tenant_id and rp.role_id = ar.id and rp.permission_key in ('tenant.configure', 'users.manage_all'))
         or not exists (select 1 from cma.role_permission rp where rp.tenant_id = ar.tenant_id and rp.role_id = ar.id and rp.permission_key = 'users.manage_agents'));
  if v_n <> 0 then
    raise exception 'FAIL A5: % system manager role(s) still configure or lack users.manage_agents', v_n;
  end if;
  select count(*) into v_n from cma.tenant t
  where (select count(*) from cma.skill_level l where l.tenant_id = t.id and l.dimension = 'language') < 2;
  if v_n <> 0 then
    raise exception 'FAIL A5: % tenant(s) without a language scale', v_n;
  end if;
end
$$;

-- B. Behaviour on throwaway tenants (universal, always rolled back)
--    Tenant one: an admin, a manager, a supervisor, an agent and a person without a role from the
--    default ladder, two teams and three skills (two languages, one work type).
--    Tenant two: an admin, to prove separation.
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_t1      uuid;
  v_t2      uuid;
  v_admin   uuid;
  v_manager uuid;
  v_super   uuid;
  v_agent   uuid;
  v_norole  uuid;
  v_admin2  uuid;
  v_new     uuid;
  v_again   uuid;
  v_text    text;
  v_n       int;
  v_n2      int;
  r         record;
begin
  begin
    -- Setup as owner
    v_t1 := cma.create_tenant('verify-0004-one', 'Verify 0004 one', 'UTC');
    v_t2 := cma.create_tenant('verify-0004-two', 'Verify 0004 two', 'UTC');
    insert into cma.organisation (tenant_id, key, name) values (v_t1, 'own', 'Own company'), (v_t1, 'other-tenant-org', 'Partner of one'), (v_t2, 'own', 'Own company two');
    insert into cma.organisation (tenant_id, key, name, status) values (v_t1, 'gone', 'Former partner', 'inactive');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'Verify admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-manager@example.invalid', 'Verify manager') returning id into v_manager;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-supervisor@example.invalid', 'Verify supervisor') returning id into v_super;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent@example.invalid', 'Verify agent') returning id into v_agent;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-norole@example.invalid', 'Verify no role') returning id into v_norole;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin@example.invalid', 'Verify admin of two') returning id into v_admin2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t1, x.uid, ar.id
    from (values (v_admin, 'admin'), (v_manager, 'manager'), (v_super, 'supervisor'), (v_agent, 'agent')) as x(uid, role_key)
    join cma.app_role ar on ar.tenant_id = v_t1 and ar.key = x.role_key;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t2, v_admin2, ar.id from cma.app_role ar where ar.tenant_id = v_t2 and ar.key = 'admin';
    insert into cma.team (tenant_id, key, name, markets, sort_order) values
      (v_t1, 'alpha', 'Team Alpha', array['xa'], 10), (v_t1, 'beta', 'Team Beta', array['xb', 'xc'], 20), (v_t2, 'alpha', 'Alpha of two', '{}', 10);
    insert into cma.skill (tenant_id, dimension, key, name, sort_order) values
      (v_t1, 'language', 'xx', 'Language XX', 10), (v_t1, 'language', 'yy', 'Language YY', 20), (v_t1, 'work_type', 'wt', 'Work type WT', 10);

    -- From here on as the application
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);

    -- B1. the agent (no users.manage_*) is refused everywhere
    perform set_config('app.user_id', v_agent::text, true);
    begin
      perform cma.directory();
      raise exception 'FAIL B1: an agent read the directory';
    exception when sqlstate 'CMA06' then null;
    end;
    begin
      perform cma.set_person_teams(v_super, array['alpha']);
      raise exception 'FAIL B1: an agent set someone''s teams';
    exception when sqlstate 'CMA06' then null;
    end;

    -- B2. the admin adds an agent; the same call again answers the same id; a different login id
    --     for the same person, the same login id for another person, a bad address, an unknown
    --     employer, and a managing role by the manager are refused
    perform set_config('app.user_id', v_admin::text, true);
    v_new := cma.add_person('New.Person@Example.Invalid', 'New person', 'own', 'agent', 'mock', 'verify-new', 'UTC');
    v_again := cma.add_person('new.person@example.invalid', 'New person', 'own', 'agent', 'mock', 'verify-new', null);
    if v_new is null or v_new <> v_again or v_provoke then
      raise exception 'FAIL B2: add_person is not rerun-safe (% then %)', v_new, v_again;
    end if;
    select count(*) into v_n from cma.user_role where tenant_id = v_t1 and user_id = v_new;
    select count(*) into v_n2 from cma.app_user_external_id where tenant_id = v_t1 and user_id = v_new and system = 'mock' and external_id = 'verify-new';
    if v_n <> 1 or v_n2 <> 1 then
      raise exception 'FAIL B2: the new person has % role(s) and % login id(s), expected one each', v_n, v_n2;
    end if;
    begin
      perform cma.add_person('new.person@example.invalid', 'New person', 'own', 'agent', 'mock', 'verify-other-id');
      raise exception 'FAIL B2: a different login id for an existing person was accepted';
    exception when sqlstate 'CMA03' then null;
    end;
    begin
      perform cma.add_person('someone.else@example.invalid', 'Someone else', 'own', 'agent', 'mock', 'verify-new');
      raise exception 'FAIL B2: a login id of another person was accepted';
    exception when sqlstate 'CMA03' then null;
    end;
    begin
      perform cma.add_person('bad', 'Bad email', 'own', 'agent', 'mock', 'verify-bad');
      raise exception 'FAIL B2: a bad email address was accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    begin
      perform cma.add_person('no.employer@example.invalid', 'No employer', 'nope', 'agent', 'mock', 'verify-noemp');
      raise exception 'FAIL B2: an unknown employer was accepted';
    exception when sqlstate 'CMA02' then null;
    end;
    perform set_config('app.user_id', v_manager::text, true);
    begin
      perform cma.add_person('second.admin@example.invalid', 'Second admin', 'own', 'admin', 'mock', 'verify-admin2');
      raise exception 'FAIL B2: the manager added an admin';
    exception when sqlstate 'CMA06' then null;
    end;

    -- B3. the manager sees the non-managing people only, may edit them but not themselves, may
    --     move the supervisor and the agent between their roles and may not touch a managing role
    select string_agg(d.display_name, ', ' order by d.display_name) into v_text from cma.directory() d;
    if v_text is distinct from 'New person, Verify agent, Verify manager, Verify no role, Verify supervisor' then
      raise exception 'FAIL B3: the manager''s directory is [%]', v_text;
    end if;
    select count(*) filter (where d.may_edit), count(*) filter (where d.user_id = v_manager and not d.may_edit) into v_n, v_n2 from cma.directory() d;
    if v_n <> 4 or v_n2 <> 1 then
      raise exception 'FAIL B3: the manager may edit % people (expected 4) and self-edit is % (expected refused)', v_n, v_n2;
    end if;
    perform cma.set_person_role(v_super, 'agent');
    perform cma.set_person_role(v_super, 'supervisor');
    select count(*) into v_n from cma.user_role where tenant_id = v_t1 and user_id = v_super;
    if v_n <> 1 then
      raise exception 'FAIL B3: the supervisor holds % grants after two role changes, expected one', v_n;
    end if;
    begin
      perform cma.set_person_role(v_agent, 'manager');
      raise exception 'FAIL B3: the manager assigned a managing role';
    exception when sqlstate 'CMA06' then null;
    end;
    begin
      perform cma.set_person_role(v_admin, 'agent');
      raise exception 'FAIL B3: the manager changed the admin''s role';
    exception when sqlstate 'CMA06' then null;
    end;
    begin
      perform cma.set_person_role(v_manager, 'agent');
      raise exception 'FAIL B3: the manager changed their own role';
    exception when sqlstate 'CMA06' then null;
    end;
    begin
      perform cma.set_person_active(v_manager, false);
      raise exception 'FAIL B3: the manager deactivated themselves';
    exception when sqlstate 'CMA06' then null;
    end;
    begin
      perform cma.set_person_role(v_agent, 'nope');
      raise exception 'FAIL B3: an unknown role was accepted';
    exception when sqlstate 'CMA02' then null;
    end;

    -- B4. the admin sees everyone (the inactive included) and may edit everyone but themselves;
    --     deactivating and reactivating; the admin may make a manager an admin and back
    perform set_config('app.user_id', v_admin::text, true);
    select count(*), count(*) filter (where d.may_edit) into v_n, v_n2 from cma.directory() d;
    if v_n <> 6 or v_n2 <> 5 then
      raise exception 'FAIL B4: the admin''s directory has % people, % editable (expected 6 and 5)', v_n, v_n2;
    end if;
    select d.role_key, d.is_managing, d.time_kept into r from cma.directory() d where d.user_id = v_manager;
    if r.role_key <> 'manager' or not r.is_managing or not r.time_kept then
      raise exception 'FAIL B4: the manager''s row reads role %, managing %, time kept %', r.role_key, r.is_managing, r.time_kept;
    end if;
    select d.role_key, d.is_managing, d.time_kept into r from cma.directory() d where d.user_id = v_norole;
    if r.role_key is not null or r.is_managing or r.time_kept then
      raise exception 'FAIL B4: the person without a role reads role %, managing %, time kept %', r.role_key, r.is_managing, r.time_kept;
    end if;
    perform cma.set_person_active(v_new, false);
    select d.status, d.may_edit into r from cma.directory() d where d.user_id = v_new;
    if r.status <> 'inactive' or not r.may_edit then
      raise exception 'FAIL B4: the deactivated person reads status %, editable %', r.status, r.may_edit;
    end if;
    perform cma.set_person_active(v_new, true);
    perform cma.set_person_role(v_manager, 'admin');
    perform cma.set_person_role(v_manager, 'manager');
    begin
      perform cma.set_person_role(v_admin, 'manager');
      raise exception 'FAIL B4: the admin changed their own role';
    exception when sqlstate 'CMA06' then null;
    end;

    -- B5. teams: two, then one; the ended membership stays as history
    perform cma.set_person_teams(v_agent, array['alpha', 'beta']);
    select string_agg(t.key, ',' order by t.key) into v_text from cma.set_person_teams(v_agent, array['beta']) t;
    if v_text is distinct from 'beta' then
      raise exception 'FAIL B5: after setting [beta] the agent is in [%]', v_text;
    end if;
    select count(*), count(*) filter (where m.valid_to is not null) into v_n, v_n2 from cma.team_member m where m.user_id = v_agent;
    if v_n <> 2 or v_n2 <> 1 then
      raise exception 'FAIL B5: expected two membership rows with one ended, found % and %', v_n, v_n2;
    end if;
    begin
      perform cma.set_person_teams(v_agent, array['gamma']);
      raise exception 'FAIL B5: an unknown team was accepted';
    exception when sqlstate 'CMA02' then null;
    end;
    select string_agg(m.team_key, ',' order by m.team_key) into v_text from cma.team_members_now() m where m.user_id = v_agent;
    if v_text is distinct from 'beta' then
      raise exception 'FAIL B5: team_members_now lists [%] for the agent', v_text;
    end if;

    -- B6. skills: a level, a changed level (ended row plus new row), a binary work type, refusals
    perform cma.set_person_skills(v_agent, '[{"key":"xx","level":2},{"key":"wt"}]'::jsonb);
    select string_agg(s.key || ':' || coalesce(s.level::text, '-') || ':' || coalesce(s.level_name, '-'), ',' order by s.key) into v_text
    from cma.set_person_skills(v_agent, '[{"key":"xx","level":3},{"key":"wt"}]'::jsonb) s;
    if v_text is distinct from 'wt:-:-,xx:3:Fluent' then
      raise exception 'FAIL B6: the agent''s skills read [%]', v_text;
    end if;
    select count(*), count(*) filter (where us.valid_to is not null) into v_n, v_n2 from cma.user_skill us where us.user_id = v_agent;
    if v_n <> 3 or v_n2 <> 1 then
      raise exception 'FAIL B6: expected three skill rows with one ended, found % and %', v_n, v_n2;
    end if;
    begin
      perform cma.set_person_skills(v_agent, '[{"key":"xx","level":9}]'::jsonb);
      raise exception 'FAIL B6: a level outside the scale was accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    begin
      perform cma.set_person_skills(v_agent, '[{"key":"wt","level":1}]'::jsonb);
      raise exception 'FAIL B6: a level on a binary dimension was accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    begin
      perform cma.set_person_skills(v_agent, '[{"key":"xx"}]'::jsonb);
      raise exception 'FAIL B6: a language without a level was accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    begin
      perform cma.set_person_skills(v_agent, '[{"key":"zz","level":1}]'::jsonb);
      raise exception 'FAIL B6: an unknown skill was accepted';
    exception when sqlstate 'CMA02' then null;
    end;
    perform set_config('app.user_id', v_super::text, true);   -- no skills.manage, no users.manage_*
    begin
      perform cma.set_person_skills(v_agent, '[{"key":"xx","level":1}]'::jsonb);
      raise exception 'FAIL B6: a supervisor set skills';
    exception when sqlstate 'CMA06' then null;
    end;
    perform set_config('app.user_id', v_admin::text, true);

    -- B7. the catalog reads: teams with member counts, skills with the scale, roles with assignable
    select string_agg(t.key || ':' || t.member_count, ',' order by t.key) into v_text from cma.teams() t;
    if v_text is distinct from 'alpha:0,beta:1' then
      raise exception 'FAIL B7: teams() reads [%]', v_text;
    end if;
    select string_agg(s.dimension || '/' || s.key || ':' || jsonb_array_length(s.levels), ',' order by s.dimension, s.key) into v_text from cma.skills() s;
    if v_text is distinct from 'language/xx:4,language/yy:4,work_type/wt:0' then
      raise exception 'FAIL B7: skills() reads [%]', v_text;
    end if;
    select string_agg(r2.key || ':' || r2.assignable, ',' order by r2.key) into v_text from cma.roles() r2;
    if v_text is distinct from 'admin:true,agent:true,analytics:true,manager:true,supervisor:true' then
      raise exception 'FAIL B7: the admin''s roles() read [%]', v_text;
    end if;
    perform set_config('app.user_id', v_manager::text, true);
    select string_agg(r2.key || ':' || r2.assignable, ',' order by r2.key) into v_text from cma.roles() r2;
    if v_text is distinct from 'admin:false,agent:true,analytics:true,manager:false,supervisor:true' then
      raise exception 'FAIL B7: the manager''s roles() read [%]', v_text;
    end if;
    perform set_config('app.user_id', v_admin::text, true);

    -- B7b. the employer list: active employers of this tenant with the applicable zone, inactive left out
    select string_agg(o.key || ':' || o.timezone, ',' order by o.key) into v_text from cma.organisations() o;
    if v_text is distinct from 'other-tenant-org:UTC,own:UTC' or v_provoke then
      raise exception 'FAIL B7b: organisations() lists [%]', v_text;
    end if;

    -- B8. the directory carries the teams and skills as JSON
    select d.teams::text into v_text from cma.directory() d where d.user_id = v_agent;
    if v_text is distinct from '[{"key": "beta", "name": "Team Beta"}]' then
      raise exception 'FAIL B8: the agent''s teams read %', v_text;
    end if;
    select count(*) into v_n from cma.directory() d, jsonb_array_elements(d.skills) e where d.user_id = v_agent;
    if v_n <> 2 then
      raise exception 'FAIL B8: the agent''s directory row carries % skills, expected 2', v_n;
    end if;

    -- B9. the catalog functions: a team is upserted, dissolved with its memberships ended; a scale
    --     change that would orphan a held level is refused
    perform cma.upsert_team('gamma', 'Team Gamma', array['xg', 'xg', 'xa'], 30);
    perform cma.set_person_teams(v_super, array['gamma']);
    perform cma.dissolve_team('gamma');
    select count(*) into v_n from cma.team_members_now() m where m.user_id = v_super;
    if v_n <> 0 or exists (select 1 from cma.teams() t where t.key = 'gamma') then
      raise exception 'FAIL B9: the dissolved team or its membership is still current';
    end if;
    begin
      perform cma.set_skill_levels('language', '[{"level":1,"name":"Only"}]'::jsonb);
      raise exception 'FAIL B9: a scale change that orphans a held level was accepted';
    exception when sqlstate 'CMA03' then null;
    end;
    perform cma.set_skill_levels('channel', '[{"level":1,"name":"Can"},{"level":2,"name":"Expert"}]'::jsonb);
    select count(*) into v_n from cma.skill_level l where l.dimension = 'channel';
    if v_n <> 2 then
      raise exception 'FAIL B9: the channel scale has % levels, expected 2', v_n;
    end if;

    -- B10. tenant two sees none of it
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    select count(*) into v_n from cma.directory();
    select count(*) into v_n2 from cma.team_members_now();
    if v_n <> 1 or v_n2 <> 0 then
      raise exception 'FAIL B10: tenant two sees % people and % memberships', v_n, v_n2;
    end if;
    -- the employer list is the tenant's own, active rows only, with the zone that applies
    select count(*) into v_n from cma.organisations() o where o.key = 'other-tenant-org';
    if v_n <> 0 then
      raise exception 'FAIL B10: tenant two sees an employer of tenant one';
    end if;

    -- B11. no acting user
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', '', true);
    begin
      perform cma.directory();
      raise exception 'FAIL B11: the directory was read without an acting user';
    exception when sqlstate 'CMA01' then null;
    end;
    begin
      perform cma.teams();
      raise exception 'FAIL B11: teams were read without an acting user';
    exception when sqlstate 'CMA01' then null;
    end;
    begin
      perform cma.organisations();
      raise exception 'FAIL B11: organisations were read without an acting user';
    exception when sqlstate 'CMA01' then null;
    end;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- Verdict: per tenant, the roles that configure and the roles that manage everyone
select t.slug as tenant,
       coalesce((select string_agg(ar.key, ', ' order by ar.key) from cma.app_role ar
                 where ar.tenant_id = t.id and exists (select 1 from cma.role_permission rp
                   where rp.tenant_id = ar.tenant_id and rp.role_id = ar.id and rp.permission_key = 'tenant.configure')), '(none)') as roles_that_configure,
       coalesce((select string_agg(ar.key, ', ' order by ar.key) from cma.app_role ar
                 where ar.tenant_id = t.id and exists (select 1 from cma.role_permission rp
                   where rp.tenant_id = ar.tenant_id and rp.role_id = ar.id and rp.permission_key = 'users.manage_all')), '(none)') as roles_managing_everyone,
       (select count(*) from cma.team tm where tm.tenant_id = t.id and tm.valid_to is null) as teams,
       (select count(*) from cma.skill s where s.tenant_id = t.id and s.status = 'active') as skills,
       case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS' else 'PASS' end as verdict
from cma.tenant t
where t.status = 'active'
order by t.slug;
