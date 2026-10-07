-- =============================================================================================
-- 20_verify_team_now.sql: verifies addition 0003e
-- =============================================================================================
-- Both blocks are universal: A checks structure and privileges, B works on throwaway tenants and
-- users inside a subtransaction that is always rolled back. No seed is assumed: the statuses are
-- picked by flag from the throwaway tenant's own list.
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

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_fn      text := 'cma.team_now()';
  v_cols    text;
begin
  if not exists (select 1 from cma.schema_migration where version = '0003e') then
    raise exception 'FAIL A1: addition 0003e not recorded';
  end if;
  if to_regprocedure(v_fn) is null then
    raise exception 'FAIL A2: % does not exist', v_fn;
  end if;
  select string_agg(a.attname, ', ' order by a.n) into v_cols
  from pg_proc p
  join lateral unnest(p.proargnames, p.proargmodes) with ordinality as a(attname, attmode, n) on true
  where p.oid = to_regprocedure(v_fn) and a.attmode = 't';
  if v_cols is distinct from 'user_id, display_name, organisation_key, organisation_name, timezone, business_date, workday_id, day_status, started_at, ended_at, status_key, status_name, status_active, is_working, is_productive, is_paid, is_billable, status_since, closed_seconds, running_since'
     or v_provoke then
    raise exception 'FAIL A3: team_now returns [%]', v_cols;
  end if;
  if not has_function_privilege('cma_app', v_fn, 'execute')
     or has_function_privilege('cma_readonly', v_fn, 'execute')
     or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE') then
    raise exception 'FAIL A4: execute on team_now must be granted to cma_app only (not to cma_readonly or public)';
  end if;
  if (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
    raise exception 'FAIL A5: % must run with the caller''s rights, not as its owner', v_fn;
  end if;
  if (select provolatile from pg_proc where oid = to_regprocedure(v_fn)) <> 's' then
    raise exception 'FAIL A6: % must be stable (a read, never a write)', v_fn;
  end if;
end
$$;

-- B. Behaviour on throwaway tenants (universal, always rolled back)
--    Tenant one, zone UTC: an agent who clocked in two hours ago and paused half an hour ago,
--    a second agent who clocked in and stays in the default status, a third agent without a day,
--    a supervisor and an analyst from the default ladder, and a person without any role.
--    Tenant two: an agent with a day and a supervisor.
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_today    date := (now() at time zone 'UTC')::date;
  v_midnight timestamptz := (v_today::timestamp) at time zone 'UTC';
  v_start    timestamptz := greatest(now() - interval '2 hours', v_midnight + interval '1 second');
  v_pause    timestamptz;
  v_t1       uuid;
  v_t2       uuid;
  v_agent    uuid;
  v_agent2   uuid;
  v_agent3   uuid;
  v_super    uuid;
  v_analyst  uuid;
  v_norole   uuid;
  v_agent_t2 uuid;
  v_super_t2 uuid;
  v_default  text;
  v_pausekey text;
  v_names    text;
  v_n        int;
  v_expected bigint;
  v_wid      uuid;
  w          cma.workday;
  r          record;
begin
  v_pause := greatest(now() - interval '30 minutes', v_start + interval '1 second');
  begin
    -- Setup as owner
    v_t1 := cma.create_tenant('verify-0003e-one', 'Verify 0003e one', 'UTC');
    v_t2 := cma.create_tenant('verify-0003e-two', 'Verify 0003e two', 'UTC');
    insert into cma.app_user (tenant_id, email, display_name)
    values (v_t1, 'verify-agent@example.invalid', 'Verify agent') returning id into v_agent;
    insert into cma.app_user (tenant_id, email, display_name)
    values (v_t1, 'verify-agent-two@example.invalid', 'Verify agent two') returning id into v_agent2;
    insert into cma.app_user (tenant_id, email, display_name)
    values (v_t1, 'verify-agent-three@example.invalid', 'Verify agent three') returning id into v_agent3;
    insert into cma.app_user (tenant_id, email, display_name)
    values (v_t1, 'verify-supervisor@example.invalid', 'Verify supervisor') returning id into v_super;
    insert into cma.app_user (tenant_id, email, display_name)
    values (v_t1, 'verify-analyst@example.invalid', 'Verify analyst') returning id into v_analyst;
    insert into cma.app_user (tenant_id, email, display_name)
    values (v_t1, 'verify-norole@example.invalid', 'Verify no role') returning id into v_norole;
    insert into cma.app_user (tenant_id, email, display_name)
    values (v_t2, 'verify-agent@example.invalid', 'Verify agent of two') returning id into v_agent_t2;
    insert into cma.app_user (tenant_id, email, display_name)
    values (v_t2, 'verify-supervisor@example.invalid', 'Verify supervisor of two') returning id into v_super_t2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t1, x.uid, ar.id
    from (values (v_agent, 'agent'), (v_agent2, 'agent'), (v_agent3, 'agent'),
                 (v_super, 'supervisor'), (v_analyst, 'analytics')) as x(uid, role_key)
    join cma.app_role ar on ar.tenant_id = v_t1 and ar.key = x.role_key;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t2, x.uid, ar.id
    from (values (v_agent_t2, 'agent'), (v_super_t2, 'supervisor')) as x(uid, role_key)
    join cma.app_role ar on ar.tenant_id = v_t2 and ar.key = x.role_key;
    select key into v_default  from cma.work_status where tenant_id = v_t1 and is_default and status = 'active';
    select key into v_pausekey from cma.work_status where tenant_id = v_t1 and not is_working and status = 'active' order by sort_order limit 1;
    if v_default is null or v_pausekey is null then
      raise exception 'FAIL B0: the throwaway tenant has no default or no pause status (seed_default_work_statuses)';
    end if;

    -- From here on as the application
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);

    -- the agent: clocked in, then a pause; agent two: clocked in, default status
    perform set_config('app.user_id', v_agent::text, true);
    w := cma.open_workday(v_start);
    perform cma.set_status(w.id, v_pausekey, v_pause);
    perform set_config('app.user_id', v_agent2::text, true);
    w := cma.open_workday(v_start);
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_agent_t2::text, true);
    w := cma.open_workday(v_start);
    perform set_config('app.tenant_id', v_t1::text, true);

    -- B1. the agent (no monitoring.live) is refused
    perform set_config('app.user_id', v_agent::text, true);
    begin
      perform cma.team_now();
      raise exception 'FAIL B1: an agent read the team';
    exception when sqlstate 'CMA06' then null;
    end;

    -- B2. the supervisor reads exactly the people whose time is kept, in name order: the three
    --     agents and the supervisor; not the analyst, not the person without a role, nobody of
    --     tenant two
    perform set_config('app.user_id', v_super::text, true);
    select string_agg(p.display_name, ', ' order by p.display_name), count(*) into v_names, v_n from cma.team_now() p;
    if v_names is distinct from 'Verify agent, Verify agent three, Verify agent two, Verify supervisor' or v_provoke then
      raise exception 'FAIL B2: team_now listed [%]', v_names;
    end if;

    -- B3. the agent's row: an open day, in the pause, since the pause, nothing running, the
    --     closed seconds equal the first stretch exactly
    v_expected := floor(extract(epoch from (v_pause - v_start)))::bigint;
    select * into r from cma.team_now() p where p.user_id = v_agent;
    if r.day_status <> 'open' or r.business_date <> v_today or r.started_at <> v_start or r.ended_at is not null
       or r.status_key <> v_pausekey or r.is_working or r.status_active is not true
       or r.status_since <> v_pause or r.running_since is not null or r.closed_seconds <> v_expected then
      raise exception 'FAIL B3: the agent''s row is (day %, date %, status %, since %, running %, closed %, expected closed %)',
        r.day_status, r.business_date, r.status_key, r.status_since, r.running_since, r.closed_seconds, v_expected;
    end if;
    if r.timezone <> 'UTC' or r.organisation_key is not null or r.organisation_name <> '' then
      raise exception 'FAIL B3: the agent''s row carries zone % and employer [%]', r.timezone, r.organisation_key;
    end if;

    -- B4. agent two's row: the default status since the start, running since the start, nothing closed
    select * into r from cma.team_now() p where p.user_id = v_agent2;
    if r.day_status <> 'open' or r.status_key <> v_default or not r.is_working
       or r.status_since <> v_start or r.running_since <> v_start or r.closed_seconds <> 0 then
      raise exception 'FAIL B4: agent two''s row is (status %, since %, running %, closed %)',
        r.status_key, r.status_since, r.running_since, r.closed_seconds;
    end if;

    -- B5. agent three and the supervisor: listed without a day, every day column null, closed 0
    select count(*) into v_n from cma.team_now() p
    where p.user_id in (v_agent3, v_super)
      and p.workday_id is null and p.day_status is null and p.started_at is null and p.status_key is null
      and p.status_since is null and p.running_since is null and p.closed_seconds = 0;
    if v_n <> 2 then
      raise exception 'FAIL B5: expected two people without a day today, found %', v_n;
    end if;

    -- B6. two reads of an unchanged team are equal (stable inputs, no now() in the row)
    select count(*) into v_n from (
      select * from cma.team_now() except select * from cma.team_now()
    ) d;
    if v_n <> 0 then
      raise exception 'FAIL B6: two reads of an unchanged team differ in % rows', v_n;
    end if;

    -- B7. agent two ends the day: clocked out, the last status stays readable, nothing since or
    --     running, the closed seconds run to the end
    perform set_config('app.user_id', v_agent2::text, true);
    select id into v_wid from cma.workday where user_id = v_agent2 and business_date = v_today;
    perform cma.end_workday(v_wid, now());
    perform set_config('app.user_id', v_super::text, true);
    select * into r from cma.team_now() p where p.user_id = v_agent2;
    if r.day_status <> 'ended' or r.ended_at is null or r.status_key <> v_default
       or r.status_since is not null or r.running_since is not null
       or r.closed_seconds <> floor(extract(epoch from (r.ended_at - v_start)))::bigint then
      raise exception 'FAIL B7: agent two''s ended day reads (day %, ended %, status %, since %, running %, closed %)',
        r.day_status, r.ended_at, r.status_key, r.status_since, r.running_since, r.closed_seconds;
    end if;

    -- B8. the analyst (monitoring.live, no clock) reads the same four people and is not among them
    perform set_config('app.user_id', v_analyst::text, true);
    select string_agg(p.display_name, ', ' order by p.display_name) into v_names from cma.team_now() p;
    if v_names is distinct from 'Verify agent, Verify agent three, Verify agent two, Verify supervisor' then
      raise exception 'FAIL B8: the analyst read [%]', v_names;
    end if;

    -- B9. a person without any role is refused
    perform set_config('app.user_id', v_norole::text, true);
    begin
      perform cma.team_now();
      raise exception 'FAIL B9: a person without a role read the team';
    exception when sqlstate 'CMA06' then null;
    end;

    -- B10. tenant two sees only its own people: its agent with a day and its supervisor without
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_super_t2::text, true);
    select string_agg(p.display_name || ':' || coalesce(p.day_status, 'none'), ', ' order by p.display_name) into v_names
    from cma.team_now() p;
    if v_names is distinct from 'Verify agent of two:open, Verify supervisor of two:none' then
      raise exception 'FAIL B10: tenant two read [%]', v_names;
    end if;

    -- B11. no acting user: refused
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', '', true);
    begin
      perform cma.team_now();
      raise exception 'FAIL B11: the team was read without an acting user';
    exception when sqlstate 'CMA01' then null;
    end;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- Verdict: per tenant, the roles that may watch the Live board
select t.slug as tenant,
       coalesce((select string_agg(ar.key, ', ' order by ar.key)
                 from cma.app_role ar
                 where ar.tenant_id = t.id
                   and exists (select 1 from cma.role_permission rp
                               where rp.tenant_id = ar.tenant_id and rp.role_id = ar.id and rp.permission_key = 'monitoring.live')),
                '(none)') as roles_with_monitoring_live,
       case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS' else 'PASS' end as verdict
from cma.tenant t
where t.status = 'active'
order by t.slug;
