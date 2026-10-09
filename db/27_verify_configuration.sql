-- =============================================================================================
-- 27_verify_configuration.sql: verifies migration 0005a, configuration functions, the scheduler
-- user and the forgotten-day close
-- =============================================================================================
-- Block A checks structure, privileges and the scheduler user per tenant; block B works on
-- throwaway tenants and people inside a subtransaction that is always rolled back. Both universal:
-- no seed is assumed. Cloud SQL Studio shows no notices: a check that fails raises "FAIL …" and
-- stops the script. The last result is the verdict. Run as your own IAM login, dev and prod.
-- Provoke: set provoke below to true; every block must then stop with FAIL, and the verdict
-- (reached only when the run does not stop on errors) says PROVOKED instead of PASS.
-- Adjusted with migration 0006 (9 October 2026): a tenant now has two system users (Scheduler
-- and Ingest), so the scheduler is found by its address, scheduler@system.invalid.
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
  v_fn      text;
  v_t       text;
  v_n       int;
begin
  if not exists (select 1 from cma.schema_migration where version = '0005a') then
    raise exception 'FAIL A1: migration 0005a not recorded';
  end if;

  -- A2. the columns, the permission, the setting
  if not exists (select 1 from information_schema.columns where table_schema = 'cma' and table_name = 'app_user' and column_name = 'kind')
     or not exists (select 1 from information_schema.columns where table_schema = 'cma' and table_name = 'app_role' and column_name = 'is_assignable')
     or not exists (select 1 from information_schema.columns where table_schema = 'cma_read' and table_name = 'app_user' and column_name = 'kind')
     or v_provoke then
    raise exception 'FAIL A2: app_user.kind, app_role.is_assignable or cma_read.app_user.kind is missing';
  end if;
  if not exists (select 1 from cma.permission where key = 'workday.close_forgotten') then
    raise exception 'FAIL A2: the permission workday.close_forgotten is missing';
  end if;
  if exists (select 1 from cma.role_permission rp join cma.app_role r on r.tenant_id = rp.tenant_id and r.id = rp.role_id
             where rp.permission_key = 'workday.close_forgotten' and r.is_assignable) then
    raise exception 'FAIL A2: an assignable role holds workday.close_forgotten';
  end if;
  if not exists (select 1 from cma.setting where key = 'workday.auto_close_grace_minutes' and value_type = 'integer' and default_value = '120') then
    raise exception 'FAIL A2: the setting workday.auto_close_grace_minutes is missing or has another default';
  end if;

  -- A3. the protection trigger on the four tables
  foreach v_t in array array['app_user', 'user_role', 'team_member', 'user_skill'] loop
    if not exists (select 1 from pg_trigger where tgrelid = to_regclass('cma.' || v_t) and tgname = 'protect_system') then
      raise exception 'FAIL A3: no protect_system trigger on cma.%', v_t;
    end if;
  end loop;

  -- A4. every active tenant has exactly one scheduler: a system user, active, with the system
  --     role scheduler (not assignable) holding only workday.close_forgotten, the login id
  --     (scheduler, scheduler), no clock (time_is_kept false). Since migration 0006 a tenant has
  --     a second system user (Ingest), so the scheduler is found by its address
  select count(*) into v_n from cma.tenant t
  where t.status = 'active'
    and 1 <> (select count(*) from cma.app_user u where u.tenant_id = t.id and u.kind = 'system' and u.status = 'active'
                and u.email = 'scheduler@system.invalid');
  if v_n <> 0 then
    raise exception 'FAIL A4: % tenant(s) without exactly one active system user', v_n;
  end if;
  select count(*) into v_n from cma.app_user u
  where u.kind = 'system' and u.email = 'scheduler@system.invalid'
    and not exists (select 1 from cma.user_role ur join cma.app_role r on r.tenant_id = ur.tenant_id and r.id = ur.role_id
                    where ur.tenant_id = u.tenant_id and ur.user_id = u.id and r.key = 'scheduler' and r.is_system and not r.is_assignable);
  if v_n <> 0 then
    raise exception 'FAIL A4: % system user(s) without the scheduler role', v_n;
  end if;
  select count(*) into v_n from cma.app_role r
  where r.key = 'scheduler'
    and (select string_agg(rp.permission_key, ',') from cma.role_permission rp where rp.tenant_id = r.tenant_id and rp.role_id = r.id) is distinct from 'workday.close_forgotten';
  if v_n <> 0 then
    raise exception 'FAIL A4: % scheduler role(s) with other permissions than workday.close_forgotten', v_n;
  end if;
  select count(*) into v_n from cma.app_user u
  where u.kind = 'system' and u.email = 'scheduler@system.invalid'
    and (not exists (select 1 from cma.app_user_external_id x where x.tenant_id = u.tenant_id and x.user_id = u.id and x.system = 'scheduler' and x.external_id = 'scheduler')
         or cma.time_is_kept(u.id));
  if v_n <> 0 then
    raise exception 'FAIL A4: % system user(s) without the scheduler login or with a clock', v_n;
  end if;

  -- A5. the functions: the app may execute them, readers and public may not, none runs as owner
  foreach v_fn in array array[
    'cma.close_forgotten_workdays(integer)',
    'cma.work_statuses_all()', 'cma.upsert_work_status(text,text,boolean,boolean,boolean,boolean,integer)',
    'cma.set_default_work_status(text)', 'cma.retire_work_status(text)',
    'cma.app_links_all()', 'cma.upsert_app_link(text,text,text,text,integer)', 'cma.retire_app_link(text)',
    'cma.retire_absence_type(text)', 'cma.clear_coverage_target(text,text,smallint)', 'cma.coverage_targets_all()',
    'cma.roles()', 'cma.directory()'] loop
    if to_regprocedure(v_fn) is null then
      raise exception 'FAIL A5: % does not exist', v_fn;
    end if;
    if not has_function_privilege('cma_app', v_fn, 'execute')
       or has_function_privilege('cma_readonly', v_fn, 'execute')
       or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                  where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE') then
      raise exception 'FAIL A5: execute on % must be granted to cma_app only', v_fn;
    end if;
    if (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      raise exception 'FAIL A5: % must run with the caller''s rights, not as its owner', v_fn;
    end if;
  end loop;
  foreach v_fn in array array['cma.ensure_scheduler_user(uuid)', 'cma.protect_system_rows()'] loop
    if has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute') then
      raise exception 'FAIL A5: % is for the owner only', v_fn;
    end if;
  end loop;
  foreach v_fn in array array['cma.work_statuses_all()', 'cma.app_links_all()', 'cma.coverage_targets_all()'] loop
    if (select provolatile from pg_proc where oid = to_regprocedure(v_fn)) <> 's' then
      raise exception 'FAIL A5: % must be stable (a read, never a write)', v_fn;
    end if;
  end loop;

  -- A6. table rights: the app writes statuses and links but deletes neither
  if not has_table_privilege('cma_app', 'cma.work_status', 'insert') or not has_table_privilege('cma_app', 'cma.work_status', 'update')
     or has_table_privilege('cma_app', 'cma.work_status', 'delete')
     or not has_table_privilege('cma_app', 'cma.app_link', 'insert') or not has_table_privilege('cma_app', 'cma.app_link', 'update')
     or has_table_privilege('cma_app', 'cma.app_link', 'delete') then
    raise exception 'FAIL A6: cma_app must insert and update work_status and app_link, never delete';
  end if;

  -- A7. the summary view still has its columns, so every face above it works
  if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma' and table_name = 'workday_summary_all')
     <> 'workday_id,tenant_id,user_id,business_date,timezone,status,started_at,ended_at,working_seconds,productive_seconds,paid_seconds,billable_seconds,is_capped,needs_correction,has_correction,current_status_id' then
    raise exception 'FAIL A7: workday_summary_all lost or reordered a column';
  end if;
end
$$;

-- B. Behaviour on throwaway tenants (universal, always rolled back)
--    Tenant one, zone Europe/Amsterdam: an admin (tenant.configure), a manager (workday.team, no
--    configure), an agent; the tenant's scheduler user. Tenant two, zone Pacific/Auckland: one agent,
--    its scheduler. The forgotten day is an agent's day three days back, opened as the owner.
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_t1      uuid;
  v_t2      uuid;
  v_admin   uuid;
  v_mgr     uuid;
  v_agent   uuid;
  v_agent2  uuid;
  v_sched1  uuid;
  v_sched2  uuid;
  v_a_t2    uuid;
  v_sched_t2 uuid;
  v_day_old uuid;
  v_day_new uuid;
  v_day_t2  uuid;
  v_default uuid;
  v_text    text;
  v_n       int;
  v_n2      int;
  r         record;
begin
  begin
    -- Setup as owner
    v_t1 := cma.create_tenant('verify-0005a-one', 'Verify 0005a one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0005a-two', 'Verify 0005a two', 'Pacific/Auckland');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'admin@example.invalid', 'Verify admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'mgr@example.invalid', 'Verify manager') returning id into v_mgr;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'agent@example.invalid', 'Verify agent') returning id into v_agent;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'agent2@example.invalid', 'Verify agent two') returning id into v_agent2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'agent@example.invalid', 'Verify agent of two') returning id into v_a_t2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t1, x.uid, ar.id
    from (values (v_admin, 'admin'), (v_mgr, 'manager'), (v_agent, 'agent'), (v_agent2, 'agent')) as x(uid, role_key)
    join cma.app_role ar on ar.tenant_id = v_t1 and ar.key = x.role_key;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t2, v_a_t2, ar.id from cma.app_role ar where ar.tenant_id = v_t2 and ar.key = 'agent';
    select id into v_sched1 from cma.app_user where tenant_id = v_t1 and kind = 'system' and email = 'scheduler@system.invalid';
    select id into v_sched_t2 from cma.app_user where tenant_id = v_t2 and kind = 'system' and email = 'scheduler@system.invalid';
    select id into v_default from cma.work_status where tenant_id = v_t1 and is_default;
    if v_sched1 is null or v_sched_t2 is null or v_default is null then
      raise exception 'FAIL B0: create_tenant did not seed the scheduler user or the default status';
    end if;
    -- three days: the agent's forgotten day three days back and a normal day yesterday (ended) in
    -- tenant one; the agent of two's forgotten day; all written as the owner with the setting
    -- context of the tenant, as the fixtures do
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_agent::text, true);
    insert into cma.workday (tenant_id, user_id, business_date, timezone, started_at)
    values (v_t1, v_agent, (now() at time zone 'Europe/Amsterdam')::date - 3, 'Europe/Amsterdam',
            (((now() at time zone 'Europe/Amsterdam')::date - 3)::timestamp + interval '9 hours') at time zone 'Europe/Amsterdam')
    returning id into v_day_old;
    insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source)
    values (v_t1, v_day_old, v_agent, 'start', v_default,
            (((now() at time zone 'Europe/Amsterdam')::date - 3)::timestamp + interval '9 hours') at time zone 'Europe/Amsterdam', 'user');
    insert into cma.workday (tenant_id, user_id, business_date, timezone, started_at, ended_at, status)
    values (v_t1, v_agent, (now() at time zone 'Europe/Amsterdam')::date - 1, 'Europe/Amsterdam',
            (((now() at time zone 'Europe/Amsterdam')::date - 1)::timestamp + interval '9 hours') at time zone 'Europe/Amsterdam',
            (((now() at time zone 'Europe/Amsterdam')::date - 1)::timestamp + interval '17 hours') at time zone 'Europe/Amsterdam', 'ended')
    returning id into v_day_new;
    insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source) values
      (v_t1, v_day_new, v_agent, 'start', v_default, (((now() at time zone 'Europe/Amsterdam')::date - 1)::timestamp + interval '9 hours') at time zone 'Europe/Amsterdam', 'user'),
      (v_t1, v_day_new, v_agent, 'end', null, (((now() at time zone 'Europe/Amsterdam')::date - 1)::timestamp + interval '17 hours') at time zone 'Europe/Amsterdam', 'user');
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_a_t2::text, true);
    insert into cma.workday (tenant_id, user_id, business_date, timezone, started_at)
    values (v_t2, v_a_t2, (now() at time zone 'Pacific/Auckland')::date - 3, 'Pacific/Auckland',
            (((now() at time zone 'Pacific/Auckland')::date - 3)::timestamp + interval '9 hours') at time zone 'Pacific/Auckland')
    returning id into v_day_t2;
    insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source)
    select v_t2, v_day_t2, v_a_t2, 'start', s.id,
           (((now() at time zone 'Pacific/Auckland')::date - 3)::timestamp + interval '9 hours') at time zone 'Pacific/Auckland', 'user'
    from cma.work_status s where s.tenant_id = v_t2 and s.is_default;

    -- From here on as the application
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.actor_label', '', true);

    -- B1. the scheduler user is invisible on the directory and its role absent from the ladder;
    --     the manager cannot edit, role, team or deactivate it, nor grant the scheduler role
    perform set_config('app.user_id', v_admin::text, true);
    if exists (select 1 from cma.directory() d where d.user_id = v_sched1) or v_provoke then
      raise exception 'FAIL B1: the scheduler is listed on the directory';
    end if;
    if exists (select 1 from cma.roles() x where x.key = 'scheduler') then
      raise exception 'FAIL B1: the scheduler role is offered in the ladder';
    end if;
    begin
      perform cma.set_person_role(v_sched1, 'agent');
      raise exception 'FAIL B1: the admin gave the scheduler a role';
    exception when sqlstate 'CMA06' then null;
    end;
    begin
      perform cma.set_person_active(v_sched1, false);
      raise exception 'FAIL B1: the admin deactivated the scheduler';
    exception when sqlstate 'CMA06' then null;
    end;
    begin
      perform cma.set_person_role(v_agent, 'scheduler');
      raise exception 'FAIL B1: the admin assigned the scheduler role to a person';
    exception when sqlstate 'CMA06' or sqlstate 'CMA02' then null;
    end;
    begin
      update cma.app_user set display_name = 'x' where id = v_sched1;
      raise exception 'FAIL B1: the app renamed the scheduler';
    exception when sqlstate 'CMA06' then null;
    end;
    begin
      insert into cma.app_user (tenant_id, email, display_name, kind) values (v_t1, 'sys2@example.invalid', 'Second system', 'system');
      raise exception 'FAIL B1: the app created a system user';
    exception when sqlstate 'CMA06' then null;
    end;

    -- B2. the close: refused for the admin, the manager and the agent; the scheduler closes the
    --     forgotten day only, at the business day's end, source system, actor scheduler, and the
    --     day stays flagged; a second run finds nothing
    foreach v_n in array array[1, 2, 3] loop
      perform set_config('app.user_id', (case v_n when 1 then v_admin when 2 then v_mgr else v_agent end)::text, true);
      begin
        perform cma.close_forgotten_workdays();
        raise exception 'FAIL B2: a person closed forgotten days';
      exception when sqlstate 'CMA06' then null;
      end;
    end loop;
    perform set_config('app.user_id', v_sched1::text, true);
    select count(*), count(*) filter (where x.workday_id = v_day_old) into v_n, v_n2 from cma.close_forgotten_workdays() x;
    if v_n <> 1 or v_n2 <> 1 then
      raise exception 'FAIL B2: the scheduler closed % day(s), the forgotten one % time(s)', v_n, v_n2;
    end if;
    select * into r from cma.workday where id = v_day_old;
    if r.status <> 'ended' or r.ended_at <> cma.business_day_end(r.business_date, r.timezone) then
      raise exception 'FAIL B2: the forgotten day is % and ends at %, expected ended at its business day''s end', r.status, r.ended_at;
    end if;
    select e.source, e.kind into r from cma.time_event_effective e where e.workday_id = v_day_old and e.kind = 'end';
    if r.source <> 'system' then
      raise exception 'FAIL B2: the end event has source %', r.source;
    end if;
    if not (select s.needs_correction from cma.workday_summary s where s.workday_id = v_day_old) then
      raise exception 'FAIL B2: the closed day lost its needs_correction flag';
    end if;
    if (select s.needs_correction from cma.workday_summary s where s.workday_id = v_day_new) then
      raise exception 'FAIL B2: the normal day is flagged';
    end if;
    if (select w.status from cma.workday w where w.id = v_day_new) <> 'ended'
       or (select w.ended_at from cma.workday w where w.id = v_day_new) <> (((now() at time zone 'Europe/Amsterdam')::date - 1)::timestamp + interval '17 hours') at time zone 'Europe/Amsterdam' then
      raise exception 'FAIL B2: the normal day was touched';
    end if;
    select count(*) into v_n from cma.close_forgotten_workdays();
    if v_n <> 0 then
      raise exception 'FAIL B2: a second run closed % day(s)', v_n;
    end if;
    if cma.current_actor_label() is distinct from 'scheduler' then
      raise exception 'FAIL B2: the actor label is [%]', cma.current_actor_label();
    end if;
    select a.actor_user_id, a.actor_label into r from cma.audit_log a
    where a.tenant_id = v_t1 and a.table_name = 'time_event' and a.action = 'insert' and (a.new_row ->> 'workday_id') = v_day_old::text and (a.new_row ->> 'kind') = 'end';
    if r.actor_user_id is distinct from v_sched1 or r.actor_label is distinct from 'scheduler' then
      raise exception 'FAIL B2: the audit names (%, %), expected the scheduler', r.actor_user_id, r.actor_label;
    end if;
    -- a correction by the manager supersedes the system end and clears the flag
    perform set_config('app.user_id', v_mgr::text, true);
    perform cma.correct_time_event(v_day_old, 'end', (select e.occurred_at from cma.time_event_effective e where e.workday_id = v_day_old and e.kind = 'end'),
                                   null, (select e.id from cma.time_event_effective e where e.workday_id = v_day_old and e.kind = 'end'),
                                   'confirmed as the business day''s end', v_mgr);
    if (select s.needs_correction from cma.workday_summary s where s.workday_id = v_day_old) then
      raise exception 'FAIL B2: the confirmed day is still flagged';
    end if;

    -- B3. the grace: a day of today is never closed, however the grace is set
    perform set_config('app.user_id', v_agent2::text, true);
    perform cma.open_workday();
    perform set_config('app.user_id', v_sched1::text, true);
    select count(*) into v_n from cma.close_forgotten_workdays(0);
    if v_n <> 0 then
      raise exception 'FAIL B3: today''s open day was closed';
    end if;
    begin
      perform cma.close_forgotten_workdays(-1);
      raise exception 'FAIL B3: a negative grace was accepted';
    exception when sqlstate 'CMA04' then null;
    end;

    -- B4. the scheduler of tenant one does not reach tenant two; tenant two's own scheduler
    --     closes its day in its zone
    if exists (select 1 from cma.workday where id = v_day_t2) then
      raise exception 'FAIL B4: tenant two''s day is visible in tenant one';
    end if;
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_sched1::text, true);
    begin
      perform cma.close_forgotten_workdays();
      raise exception 'FAIL B4: tenant one''s scheduler acted in tenant two';
    exception when sqlstate 'CMA01' then null;
    end;
    perform set_config('app.user_id', v_sched_t2::text, true);
    select count(*) into v_n from cma.close_forgotten_workdays();
    select * into r from cma.workday where id = v_day_t2;
    if v_n <> 1 or r.status <> 'ended' or r.ended_at <> cma.business_day_end(r.business_date, 'Pacific/Auckland') then
      raise exception 'FAIL B4: tenant two''s day: % closed, status %, ended %', v_n, r.status, r.ended_at;
    end if;
    perform set_config('app.tenant_id', v_t1::text, true);

    -- B5. work statuses: the agent and the manager cannot configure; the admin reads the list with
    --     usage, adds, edits, reorders, changes the default, retires; the rules
    perform set_config('app.user_id', v_mgr::text, true);
    begin
      perform cma.work_statuses_all();
      raise exception 'FAIL B5: the manager read the status configuration';
    exception when sqlstate 'CMA06' then null;
    end;
    begin
      perform cma.upsert_work_status('x', 'X', true, true, true, true);
      raise exception 'FAIL B5: the manager wrote a status';
    exception when sqlstate 'CMA06' then null;
    end;
    perform set_config('app.user_id', v_admin::text, true);
    select count(*), count(*) filter (where x.is_default), sum(x.usage_count) into v_n, v_n2, v_text from cma.work_statuses_all() x;
    if v_n < 2 or v_n2 <> 1 or v_text::int < 3 then
      raise exception 'FAIL B5: the list has % statuses, % default, usage %', v_n, v_n2, v_text;
    end if;
    perform cma.upsert_work_status('focus', 'Focus work', true, false, true, true, 15);
    perform cma.upsert_work_status('focus', 'Focus time', true, false, true, true, 16);   -- rename and reorder, no time behind it
    select x.name, x.sort_order, x.status into r from cma.work_statuses_all() x where x.key = 'focus';
    if r.name <> 'Focus time' or r.sort_order <> 16 or r.status <> 'active' then
      raise exception 'FAIL B5: focus reads (%, %, %)', r.name, r.sort_order, r.status;
    end if;
    begin
      perform cma.upsert_work_status('bad key', 'Bad', true, true, true, true);
      raise exception 'FAIL B5: a bad key was accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    -- the default's flags cannot change: it has time behind it (the fixture days)
    select x.key into v_text from cma.work_statuses_all() x where x.is_default;
    begin
      perform cma.upsert_work_status(v_text, 'Renamed default', false, false, false, false);
      raise exception 'FAIL B5: the flags of a status with time behind it were changed';
    exception when sqlstate 'CMA03' then null;
    end;
    perform cma.upsert_work_status(v_text, 'Renamed default', (select x.is_working from cma.work_statuses_all() x where x.key = v_text),
                                   (select x.is_productive from cma.work_statuses_all() x where x.key = v_text),
                                   (select x.is_paid from cma.work_statuses_all() x where x.key = v_text),
                                   (select x.is_billable from cma.work_statuses_all() x where x.key = v_text), 1);
    if (select x.name from cma.work_statuses_all() x where x.key = v_text) <> 'Renamed default' then
      raise exception 'FAIL B5: the default could not be renamed';
    end if;
    -- the default cannot be retired, a non-working status cannot become the default
    begin
      perform cma.retire_work_status(v_text);
      raise exception 'FAIL B5: the default was retired';
    exception when sqlstate 'CMA03' then null;
    end;
    perform cma.upsert_work_status('pause_x', 'Pause X', false, false, false, false, 90);
    begin
      perform cma.set_default_work_status('pause_x');
      raise exception 'FAIL B5: a non-working status became the default';
    exception when sqlstate 'CMA03' then null;
    end;
    begin
      perform cma.set_default_work_status('nope');
      raise exception 'FAIL B5: an unknown status became the default';
    exception when sqlstate 'CMA02' then null;
    end;
    perform cma.set_default_work_status('focus');
    select count(*) filter (where x.is_default), string_agg(x.key, ',') filter (where x.is_default) into v_n, v_text from cma.work_statuses_all() x;
    if v_n <> 1 or v_text <> 'focus' then
      raise exception 'FAIL B5: after set_default % default(s): %', v_n, v_text;
    end if;
    -- retire: the old default is retirable now; it keeps its usage; it is not choosable; upsert reactivates
    select x.key into v_text from cma.work_statuses_all() x where x.name = 'Renamed default';
    perform cma.retire_work_status(v_text);
    select x.status, x.usage_count into r from cma.work_statuses_all() x where x.key = v_text;
    if r.status <> 'inactive' or r.usage_count < 1 then
      raise exception 'FAIL B5: the retired status reads (%, %)', r.status, r.usage_count;
    end if;
    perform set_config('app.user_id', v_agent2::text, true);
    begin
      perform cma.set_status((select id from cma.workday where user_id = v_agent2 and status = 'open'), v_text);
      raise exception 'FAIL B5: a retired status was chosen';
    exception when sqlstate 'CMA02' then null;
    end;
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.upsert_work_status(v_text, 'Back again', (select x.is_working from cma.work_statuses_all() x where x.key = v_text),
                                   (select x.is_productive from cma.work_statuses_all() x where x.key = v_text),
                                   (select x.is_paid from cma.work_statuses_all() x where x.key = v_text),
                                   (select x.is_billable from cma.work_statuses_all() x where x.key = v_text), 2);
    if (select x.status from cma.work_statuses_all() x where x.key = v_text) <> 'active' then
      raise exception 'FAIL B5: the retired status was not reactivated';
    end if;
    -- the last working status: retire every working status but the default, then the default's
    -- only companion
    for r in select x.key from cma.work_statuses_all() x where x.is_working and x.status = 'active' and not x.is_default and x.key <> v_text loop
      perform cma.retire_work_status(r.key);
    end loop;
    perform cma.retire_work_status(v_text);
    select count(*) into v_n from cma.work_statuses_all() x where x.is_working and x.status = 'active';
    if v_n <> 1 then
      raise exception 'FAIL B5: % working status(es) left, expected the default alone', v_n;
    end if;
    begin
      perform cma.retire_work_status('focus');
      raise exception 'FAIL B5: the last working status was retired';
    exception when sqlstate 'CMA03' then null;
    end;
    begin
      perform cma.retire_work_status('nope');
      raise exception 'FAIL B5: an unknown status was retired';
    exception when sqlstate 'CMA02' then null;
    end;

    -- B6. app links: add, change, retire, reactivate, the rules; the agent sees active ones only
    perform cma.upsert_app_link('crm', 'CRM', 'https://crm.example.invalid/', null, 10);
    perform cma.upsert_app_link('sheet', 'Team sheet', 'https://sheet.example.invalid/', 'workday.team', 20);
    begin
      perform cma.upsert_app_link('bad', 'Bad', 'http://plain.example.invalid/');
      raise exception 'FAIL B6: a plain http address was accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    begin
      perform cma.upsert_app_link('bad', 'Bad', 'https://x.example.invalid/', 'no.such_permission');
      raise exception 'FAIL B6: an unknown permission was accepted';
    exception when sqlstate 'CMA02' then null;
    end;
    perform cma.retire_app_link('sheet');
    select string_agg(x.key || ':' || x.status, ',' order by x.status <> 'active', x.sort_order) into v_text from cma.app_links_all() x;
    if v_text <> 'crm:active,sheet:inactive' then
      raise exception 'FAIL B6: links read [%]', v_text;
    end if;
    perform set_config('app.user_id', v_agent::text, true);
    select string_agg(x.key, ',') into v_text from cma.app_links() x;
    if v_text <> 'crm' then
      raise exception 'FAIL B6: the agent sees [%]', v_text;
    end if;
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.upsert_app_link('sheet', 'Team sheet', 'https://sheet.example.invalid/', 'workday.team', 20);
    if (select x.status from cma.app_links_all() x where x.key = 'sheet') <> 'active' then
      raise exception 'FAIL B6: the retired link was not reactivated';
    end if;
    begin
      perform cma.retire_app_link('nope');
      raise exception 'FAIL B6: an unknown link was retired';
    exception when sqlstate 'CMA02' then null;
    end;

    -- B7. absence types and coverage targets
    perform cma.retire_absence_type('other');
    if (select x.status from cma.absence_types() x where x.key = 'other') <> 'inactive' then
      raise exception 'FAIL B7: other was not retired';
    end if;
    begin
      perform cma.retire_absence_type('nope');
      raise exception 'FAIL B7: an unknown absence type was retired';
    exception when sqlstate 'CMA02' then null;
    end;
    perform cma.upsert_team('alpha', 'Team Alpha', array['xa'], 10);
    perform cma.upsert_skill('work_type', 'wt1', 'Work one', 10);
    perform cma.set_coverage_target('alpha', 'wt1', 2::smallint, 3);
    perform cma.set_coverage_target('alpha', 'wt1', 5::smallint, 1);
    select string_agg(x.team_key || '/' || x.skill_key || '/' || x.weekday || '=' || x.min_count, ',' order by x.weekday) into v_text from cma.coverage_targets_all() x;
    if v_text <> 'alpha/wt1/2=3,alpha/wt1/5=1' then
      raise exception 'FAIL B7: targets read [%]', v_text;
    end if;
    perform cma.clear_coverage_target('alpha', 'wt1', 2::smallint);
    select count(*) into v_n from cma.coverage_targets_all();
    if v_n <> 1 then
      raise exception 'FAIL B7: % target(s) after the clear', v_n;
    end if;
    perform set_config('app.user_id', v_mgr::text, true);
    begin
      perform cma.coverage_targets_all();
      raise exception 'FAIL B7: the manager read the configuration grid';
    exception when sqlstate 'CMA06' then null;
    end;

    -- B8. no acting user
    perform set_config('app.user_id', '', true);
    begin
      perform cma.close_forgotten_workdays();
      raise exception 'FAIL B8: the close ran without an acting user';
    exception when sqlstate 'CMA01' then null;
    end;
    begin
      perform cma.work_statuses_all();
      raise exception 'FAIL B8: the status list was read without an acting user';
    exception when sqlstate 'CMA01' then null;
    end;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- Verdict: per tenant, the scheduler user, the roles that configure, the grace, the statuses and links
select t.slug as tenant,
       (select count(*) from cma.app_user u where u.tenant_id = t.id and u.kind = 'system' and u.status = 'active' and u.email = 'scheduler@system.invalid') as scheduler_users,
       coalesce((select string_agg(ar.key, ', ' order by ar.key) from cma.app_role ar
                 where ar.tenant_id = t.id and exists (select 1 from cma.role_permission rp
                   where rp.tenant_id = ar.tenant_id and rp.role_id = ar.id and rp.permission_key = 'workday.close_forgotten')), '(none)') as roles_with_close_forgotten,
       coalesce((select ts.value from cma.tenant_setting ts where ts.tenant_id = t.id and ts.key = 'workday.auto_close_grace_minutes'), '120 (default)') as grace_minutes,
       (select count(*) from cma.work_status s where s.tenant_id = t.id and s.status = 'active') as active_statuses,
       (select count(*) from cma.app_link l where l.tenant_id = t.id and l.status = 'active') as active_links,
       case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS' else 'PASS' end as verdict
from cma.tenant t
where t.status = 'active'
order by t.slug;
