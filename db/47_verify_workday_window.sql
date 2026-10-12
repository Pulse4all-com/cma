-- =============================================================================================
-- 47_verify_workday_window.sql: verifies addition 0008b, the workday window and the forgotten-day close
-- =============================================================================================
-- Block A checks structure and privileges; blocks B and C work on throwaway tenants inside a
-- subtransaction that is always rolled back. All universal: no seed is assumed, and every time is
-- built on a date two days back in the throwaway tenants' zone, so the verdict does not depend on
-- the hour it runs. Cloud SQL Studio shows no notices: a check that fails raises "FAIL …" and stops
-- the block. The last result is the verdict. Run as your own IAM login, dev and prod, after
-- 46_workday_window.sql; then 27_verify_configuration.sql, 43_verify_messaging.sql and
-- 45_verify_assignment_alerts.sql again (unchanged).
--   A  structure and privileges: the migration row, the value type and the four settings, the
--      functions and who may execute them, the time views' columns and who may read them
--   B  the window: a tenant without settings as before; the settings' refusals; a clock-in before
--      the window start refused and at the start accepted; a status change and a clock-out after
--      the window end accepted with the counted time stopped at the end, for the application and
--      for a reader; corrections only within the window
--   C  the close: four forgotten days ended at the planned shift end, at the default time, at the
--      last event and at the window end; one notice per person, one digest for the holders of the
--      notification permission and nobody else; the days stay flagged; a second run closes and
--      sends nothing; the other tenant is untouched
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
  v_fn      text;
  v_cols    text;
begin
  -- A1. the addition is recorded
  if not exists (select 1 from cma.schema_migration where version = '0008b') or v_provoke then
    raise exception 'FAIL A1: addition 0008b not recorded';
  end if;
  -- A2. the value type time and the four settings with their universal defaults
  if not exists (select 1 from pg_constraint c where c.conrelid = 'cma.setting'::regclass and c.contype = 'c'
                   and pg_get_constraintdef(c.oid) like '%''time''%') then
    raise exception 'FAIL A2: the setting catalog does not accept the value type time';
  end if;
  if (select count(*) from cma.setting s
      where (s.key, s.value_type, s.default_value) in (('workday.window_start', 'time', '00:00'),
                                                       ('workday.window_end', 'time', '24:00'),
                                                       ('workday.auto_close_at', 'time', '24:00'),
                                                       ('workday.auto_close_notify_permission', 'text', 'workday.team'))) <> 4
     or not exists (select 1 from cma.setting where key = 'workday.auto_close_grace_minutes') then
    raise exception 'FAIL A2: the workday settings are not as expected';
  end if;
  -- A3. the functions exist; the day's bounds and the close are the application's, the arithmetic is public
  foreach v_fn in array array['cma.business_day_start(date,text)', 'cma.business_day_end(date,text)',
                              'cma.close_forgotten_workdays(integer)'] loop
    if to_regprocedure(v_fn) is null then
      raise exception 'FAIL A3: function % is missing', v_fn;
    end if;
    if not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute') then
      raise exception 'FAIL A3: function % is not executable by cma_app only', v_fn;
    end if;
  end loop;
  if to_regprocedure('cma.business_day_time(date,text,time)') is null then
    raise exception 'FAIL A3: function cma.business_day_time(date,text,time) is missing';
  end if;
  if not exists (select 1 from pg_proc p where p.oid = to_regprocedure('cma.close_forgotten_workdays(integer)')
                   and 'end_rule' = any (p.proargnames)) then
    raise exception 'FAIL A3: close_forgotten_workdays does not return end_rule';
  end if;
  foreach v_fn in array array['cma.open_workday(timestamptz)', 'cma.correct_workday(uuid,date,jsonb,text)',
                              'cma.correct_time_event(uuid,text,timestamptz,text,uuid,text,uuid)'] loop
    if not has_function_privilege('cma_app', v_fn, 'execute') then
      raise exception 'FAIL A3: the application cannot execute %', v_fn;
    end if;
  end loop;
  -- A4. the time views keep their columns; the cores are the owner's, the faces readable
  select string_agg(a.attname, ',' order by a.attnum) into v_cols
  from pg_attribute a where a.attrelid = 'cma.time_interval_all'::regclass and a.attnum > 0 and not a.attisdropped;
  if v_cols <> 'tenant_id,workday_id,user_id,event_id,status_id,from_at,to_at,is_open,is_capped,seconds' then
    raise exception 'FAIL A4: time_interval_all has the columns %', v_cols;
  end if;
  select string_agg(a.attname, ',' order by a.attnum) into v_cols
  from pg_attribute a where a.attrelid = 'cma.workday_summary_all'::regclass and a.attnum > 0 and not a.attisdropped;
  if v_cols <> 'workday_id,tenant_id,user_id,business_date,timezone,status,started_at,ended_at,working_seconds,productive_seconds,paid_seconds,billable_seconds,is_capped,needs_correction,has_correction,current_status_id' then
    raise exception 'FAIL A4: workday_summary_all has the columns %', v_cols;
  end if;
  if has_table_privilege('cma_app', 'cma.time_interval_all', 'select') or has_table_privilege('cma_app', 'cma.workday_summary_all', 'select')
     or has_table_privilege('cma_readonly', 'cma.workday_summary_all', 'select')
     or not has_table_privilege('cma_app', 'cma.workday_summary', 'select')
     or not has_table_privilege('cma_readonly', 'cma_read.workday_summary', 'select') then
    raise exception 'FAIL A4: the time views are not readable as expected';
  end if;
end
$$;

-- B. The window (universal, throwaway tenants, rolled back)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_zone    text := 'Europe/Amsterdam';
  v_d       date := (now() at time zone 'Europe/Amsterdam')::date - 2;
  v_t0      uuid;
  v_t1      uuid;
  v_admin0  uuid;
  v_agent0  uuid;
  v_admin   uuid;
  v_mgr     uuid;
  v_agent   uuid;
  v_agent2  uuid;
  v_day     uuid;
  v_end     uuid;
  v_txt     text;
  v_n       bigint;
  w         cma.workday;
begin
  begin
    v_t0 := cma.create_tenant('verify-0008b-defaults', 'Verify 0008b defaults', v_zone);
    v_t1 := cma.create_tenant('verify-0008b-window', 'Verify 0008b window', v_zone);
    insert into cma.app_user (tenant_id, email, display_name) values (v_t0, 'verify-admin0@example.invalid', 'admin0') returning id into v_admin0;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t0, 'verify-agent0@example.invalid', 'agent0') returning id into v_agent0;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-mgr@example.invalid', 'mgr') returning id into v_mgr;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent@example.invalid', 'agent') returning id into v_agent;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent2@example.invalid', 'agent2') returning id into v_agent2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t0, v_admin0, 'admin'), (v_t0, v_agent0, 'agent'), (v_t1, v_admin, 'admin'), (v_t1, v_mgr, 'manager'),
                 (v_t1, v_agent, 'agent'), (v_t1, v_agent2, 'agent')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;

    perform set_config('role', 'cma_app', true);

    -- B1. a tenant without settings: the day runs from midnight to midnight as before; a clock-in
    --     just after midnight is accepted and a late status change counts in full
    perform set_config('app.tenant_id', v_t0::text, true);
    perform set_config('app.user_id', v_agent0::text, true);
    if cma.business_day_start(v_d, v_zone) <> (v_d::timestamp at time zone v_zone)
       or cma.business_day_end(v_d, v_zone) <> ((v_d + 1)::timestamp at time zone v_zone) or v_provoke then
      raise exception 'FAIL B1: a tenant without settings has the window % to %',
        cma.business_day_start(v_d, v_zone), cma.business_day_end(v_d, v_zone);
    end if;
    w := cma.open_workday((v_d + time '00:30') at time zone v_zone);
    perform cma.set_status(w.id, 'break', (v_d + time '23:00') at time zone v_zone);
    perform cma.end_workday(w.id, (v_d + time '23:30') at time zone v_zone);
    select s.working_seconds into v_n from cma.workday_summary s where s.workday_id = w.id;
    if w.business_date <> v_d or v_n <> 22.5 * 3600 then
      raise exception 'FAIL B1: the day without settings counted % seconds', v_n;
    end if;

    -- B2. the settings: the admin sets the window; malformed and inconsistent values are refused,
    --     an agent cannot set them
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_tenant_setting('workday.window_start', '07:00');
    perform cma.set_tenant_setting('workday.window_end', '22:00');
    perform cma.set_tenant_setting('workday.auto_close_at', '17:00');
    perform cma.set_tenant_setting('workday.auto_close_grace_minutes', '60');
    foreach v_txt in array array[
      'select cma.set_tenant_setting(''workday.window_start'', ''7:00'')',
      'select cma.set_tenant_setting(''workday.window_start'', ''22:00'')',
      'select cma.set_tenant_setting(''workday.window_end'', ''06:30'')',
      'select cma.set_tenant_setting(''workday.window_end'', ''24:01'')',
      'select cma.set_tenant_setting(''workday.auto_close_at'', ''25:00'')',
      'select cma.set_tenant_setting(''workday.auto_close_notify_permission'', ''no.such.permission'')'
    ] loop
      begin
        execute v_txt;
        raise exception 'FAIL B2: % was accepted', v_txt;
      exception when sqlstate 'CMA04' then null;
      end;
    end loop;
    perform set_config('app.user_id', v_agent::text, true);
    begin
      perform cma.set_tenant_setting('workday.window_start', '06:00');
      raise exception 'FAIL B2: an agent set the window';
    exception when sqlstate 'CMA06' then null;
    end;
    if cma.business_day_start(v_d, v_zone) <> ((v_d + time '07:00') at time zone v_zone)
       or cma.business_day_end(v_d, v_zone) <> ((v_d + time '22:00') at time zone v_zone) then
      raise exception 'FAIL B2: the window reads % to %', cma.business_day_start(v_d, v_zone), cma.business_day_end(v_d, v_zone);
    end if;

    -- B3. a clock-in at 06:59 is refused with the window start in the message; at 07:00 it opens
    begin
      perform cma.open_workday((v_d + time '06:59') at time zone v_zone);
      raise exception 'FAIL B3: a clock-in at 06:59 was accepted';
    exception when sqlstate 'CMA04' then
      get stacked diagnostics v_txt = message_text;
      if v_txt <> 'the workday starts at 07:00' then
        raise exception 'FAIL B3: the refusal reads [%]', v_txt;
      end if;
    end;
    w := cma.open_workday((v_d + time '07:00') at time zone v_zone);
    v_day := w.id;
    if w.business_date <> v_d or w.status <> 'open' or w.started_at <> ((v_d + time '07:00') at time zone v_zone) then
      raise exception 'FAIL B3: the clock-in at 07:00 gave %', w;
    end if;

    -- B4. a status change at 22:30 is accepted, the counted time stops at 22:00 and the open day is
    --     capped and flagged; a clock-out at 22:40 is accepted and counts nothing more; a reader of
    --     the tenant sees the same seconds
    perform cma.set_status(v_day, 'training', (v_d + time '22:30') at time zone v_zone);
    if (select s.working_seconds from cma.workday_summary s where s.workday_id = v_day) <> 15 * 3600
       or not (select s.is_capped and s.needs_correction from cma.workday_summary s where s.workday_id = v_day) then
      raise exception 'FAIL B4: after a status change at 22:30 the day counts % seconds, capped %',
        (select s.working_seconds from cma.workday_summary s where s.workday_id = v_day),
        (select s.is_capped from cma.workday_summary s where s.workday_id = v_day);
    end if;
    w := cma.end_workday(v_day, (v_d + time '22:40') at time zone v_zone);
    if w.status <> 'ended' or (select s.working_seconds from cma.workday_summary s where s.workday_id = v_day) <> 15 * 3600
       or (select s.needs_correction from cma.workday_summary s where s.workday_id = v_day) then
      raise exception 'FAIL B4: the clock-out at 22:40 gave %, % seconds', w.status,
        (select s.working_seconds from cma.workday_summary s where s.workday_id = v_day);
    end if;
    perform set_config('role', 'cma_readonly', true);
    if (select s.working_seconds from cma_read.workday_summary s where s.workday_id = v_day) <> 15 * 3600
       or (select sum(i.seconds) from cma_read.time_interval i where i.workday_id = v_day) <> 15 * 3600 then
      raise exception 'FAIL B4: a reader sees % seconds', (select s.working_seconds from cma_read.workday_summary s where s.workday_id = v_day);
    end if;
    perform set_config('role', 'cma_app', true);

    -- B5. corrections only within the window: Add day before 07:00 or after 22:00 refused, within accepted;
    --     moving an end past 22:00 refused, in both correction paths
    perform set_config('app.user_id', v_mgr::text, true);
    foreach v_txt in array array['06:30', '22:30'] loop
      begin
        perform cma.correct_workday(v_agent2, v_d, jsonb_build_array(
          jsonb_build_object('kind', 'start', 'statusKey', 'available', 'at', to_char((v_d + v_txt::time) at time zone v_zone at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))),
          'verify outside the window');
        raise exception 'FAIL B5: a correction at % was accepted', v_txt;
      exception when sqlstate 'CMA04' then null;
      end;
    end loop;
    w := cma.correct_workday(v_agent2, v_d, jsonb_build_array(
           jsonb_build_object('kind', 'start', 'statusKey', 'available', 'at', to_char((v_d + time '07:00') at time zone v_zone at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')),
           jsonb_build_object('kind', 'end', 'at', to_char((v_d + time '22:00') at time zone v_zone at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))),
           'verify within the window');
    if w.status <> 'ended' or w.ended_at <> ((v_d + time '22:00') at time zone v_zone) then
      raise exception 'FAIL B5: the correction within the window gave %', w;
    end if;
    select e.id into v_end from cma.time_event_effective e where e.workday_id = w.id and e.kind = 'end';
    begin
      perform cma.correct_time_event(w.id, 'end', (v_d + time '22:15') at time zone v_zone, null, v_end, 'verify past the window', v_mgr);
      raise exception 'FAIL B5: correct_time_event moved an end past the window';
    exception when sqlstate 'CMA04' then null;
    end;
    begin
      perform cma.correct_workday(v_agent2, v_d, jsonb_build_array(
        jsonb_build_object('kind', 'end', 'supersedes', v_end, 'at', to_char((v_d + time '22:15') at time zone v_zone at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))),
        'verify past the window');
      raise exception 'FAIL B5: correct_workday moved an end past the window';
    exception when sqlstate 'CMA04' then null;
    end;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- C. The close (universal, throwaway tenants, rolled back)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_zone    text := 'Europe/Amsterdam';
  v_d       date := (now() at time zone 'Europe/Amsterdam')::date - 2;
  v_t1      uuid;
  v_t2      uuid;
  v_admin   uuid;
  v_mgr     uuid;
  v_sup     uuid;
  v_p1      uuid;
  v_p2      uuid;
  v_p3      uuid;
  v_p4      uuid;
  v_idle    uuid;
  v_a_t2    uuid;
  v_sched   uuid;
  v_sched2  uuid;
  v_week    uuid;
  v_day3    uuid;
  v_day_t2  uuid;
  v_holders uuid[];
  v_got     uuid[];
  v_digest  cma.message;
  v_n       int;
  v_txt     text;
  r         record;
begin
  begin
    v_t1 := cma.create_tenant('verify-0008b-close-one', 'Verify 0008b close one', v_zone);
    v_t2 := cma.create_tenant('verify-0008b-close-two', 'Verify 0008b close two', v_zone);
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-mgr@example.invalid', 'mgr') returning id into v_mgr;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-sup@example.invalid', 'sup') returning id into v_sup;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-p1@example.invalid', 'p1') returning id into v_p1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-p2@example.invalid', 'p2') returning id into v_p2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-p3@example.invalid', 'p3') returning id into v_p3;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-p4@example.invalid', 'p4') returning id into v_p4;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-idle@example.invalid', 'idle') returning id into v_idle;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-agent@example.invalid', 'agent of two') returning id into v_a_t2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin, 'admin'), (v_t1, v_mgr, 'manager'), (v_t1, v_sup, 'supervisor'),
                 (v_t1, v_p1, 'agent'), (v_t1, v_p2, 'agent'), (v_t1, v_p3, 'agent'), (v_t1, v_p4, 'agent'),
                 (v_t1, v_idle, 'agent'), (v_t2, v_a_t2, 'agent')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select id into v_sched from cma.app_user where tenant_id = v_t1 and kind = 'system' and email = 'scheduler@system.invalid';
    select id into v_sched2 from cma.app_user where tenant_id = v_t2 and kind = 'system' and email = 'scheduler@system.invalid';
    -- both tenants keep a 07:00 to 22:00 window, 17:00 and an hour's grace
    insert into cma.tenant_setting (tenant_id, key, value)
    select t.id, s.key, s.value
    from (values (1, 'workday.window_start', '07:00'), (2, 'workday.window_end', '22:00'),
                 (3, 'workday.auto_close_at', '17:00'), (4, 'workday.auto_close_grace_minutes', '60')) as s(ord, key, value)
    cross join (values (v_t1), (v_t2)) as t(id)
    order by t.id, s.ord;
    -- a roster for the week of the date, published before that date (the planner cannot write the
    -- past, so the owner writes it as it would have stood): p1 09:00 to 16:30, p4 15:00 to 23:00,
    -- p2 an absence that was replaced (nothing planned), p3 nothing
    insert into cma.roster_week (tenant_id, team_id, week_start, status, version, published_at, published_by)
    values (v_t1, null, date_trunc('week', v_d)::date, 'published', 1, now() - interval '3 days', v_mgr)
    returning id into v_week;
    insert into cma.roster_entry (tenant_id, roster_week_id, user_id, business_date, kind, start_time, end_time, recorded_at, recorded_by) values
      (v_t1, v_week, v_p1, v_d, 'shift', '09:00', '16:30', now() - interval '4 days', v_mgr),
      (v_t1, v_week, v_p4, v_d, 'shift', '15:00', '23:00', now() - interval '4 days', v_mgr);
    -- a draft change after the publication is not what the person saw: p1's later 18:00 end stays unpublished
    update cma.roster_entry set valid_to = now() - interval '1 day' where tenant_id = v_t1 and user_id = v_p1;
    insert into cma.roster_entry (tenant_id, roster_week_id, user_id, business_date, kind, start_time, end_time, recorded_at, recorded_by)
    values (v_t1, v_week, v_p1, v_d, 'shift', '09:00', '18:00', now() - interval '1 day', v_mgr);

    perform set_config('role', 'cma_app', true);
    perform set_config('app.actor_label', '', true);
    -- four forgotten days, all clocked in at 08:00; p3 changed status at 19:12
    perform set_config('app.tenant_id', v_t1::text, true);
    foreach v_txt in array array[v_p1::text, v_p2::text, v_p3::text, v_p4::text] loop
      perform set_config('app.user_id', v_txt, true);
      perform cma.open_workday((v_d + time '08:00') at time zone v_zone);
    end loop;
    perform set_config('app.user_id', v_p3::text, true);
    select w.id into v_day3 from cma.workday w where w.user_id = v_p3;
    perform cma.set_status(v_day3, 'break', (v_d + time '19:12') at time zone v_zone);
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_a_t2::text, true);
    v_day_t2 := (cma.open_workday((v_d + time '08:00') at time zone v_zone)).id;

    -- C1. the scheduler of tenant one closes exactly the four days with the end rule
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_sched::text, true);
    for r in
      select x.user_id, x.ended_at, x.end_rule, exp.ended_at as want_at, exp.end_rule as want_rule
      from cma.close_forgotten_workdays() x
      full join (values (v_p1, (v_d + time '16:30') at time zone v_zone, 'shift'),
                        (v_p2, (v_d + time '17:00') at time zone v_zone, 'default'),
                        (v_p3, (v_d + time '19:12') at time zone v_zone, 'last_event'),
                        (v_p4, (v_d + time '22:00') at time zone v_zone, 'shift')) as exp(user_id, ended_at, end_rule)
        on exp.user_id = x.user_id
    loop
      if r.ended_at is distinct from r.want_at or r.end_rule is distinct from r.want_rule or v_provoke then
        raise exception 'FAIL C1: % closed at % (%), expected % (%)', r.user_id, r.ended_at, r.end_rule, r.want_at, r.want_rule;
      end if;
    end loop;
    if exists (select 1 from cma.workday w where w.status = 'open')
       or exists (select 1 from cma.time_event_effective e where e.kind = 'end' and e.source <> 'system') then
      raise exception 'FAIL C1: a day stayed open or ended other than by the system';
    end if;

    -- C2. one notice per closed day, to that person only, from the scheduler, with the date and the time
    for r in select u.id, u.email, m.title, m.body, m.kind, m.urgency, m.sender_user_id, m.ref_id,
                    (select array_agg(d.user_id) from cma.message_delivery d where d.message_id = m.id) as recipients
             from cma.app_user u
             left join cma.message m on m.target -> 'users' ? u.id::text
             where u.id in (v_p1, v_p2, v_p3, v_p4)
    loop
      if r.title is distinct from 'Workday closed automatically' or r.kind <> 'announcement' or r.urgency <> 'normal'
         or r.sender_user_id is distinct from v_sched or r.ref_id is not null or r.recipients <> array[r.id] then
        raise exception 'FAIL C2: the notice of % is (%, %, %)', r.email, r.title, r.kind, r.recipients;
      end if;
    end loop;
    if (select count(*) from cma.message m where m.title = 'Workday closed automatically') <> 4
       or (select m.body from cma.message m where m.target -> 'users' ? v_p1::text)
          <> format('Your workday of %s was closed automatically at 16:30 because you did not log out. Your supervisor will review it.', to_char(v_d, 'Dy DD Mon')) then
      raise exception 'FAIL C2: the notices read %', (select string_agg(m.body, ' | ') from cma.message m where m.title = 'Workday closed automatically');
    end if;

    -- C3. one digest for every active person holding workday.team, nobody else; counts and dates only
    select * into v_digest from cma.message m where m.title = 'Workdays closed automatically';
    select coalesce(array_agg(u.id order by u.id), '{}') into v_holders
    from cma.app_user u where u.status = 'active' and u.kind = 'person' and cma.has_permission(u.id, 'workday.team');
    select coalesce(array_agg(d.user_id order by d.user_id), '{}') into v_got from cma.message_delivery d where d.message_id = v_digest.id;
    if (select count(*) from cma.message m where m.title = 'Workdays closed automatically') <> 1
       or v_digest.body <> format('4 workday(s) of %s were closed automatically. Review them on Team hours.', to_char(v_d, 'Dy DD Mon'))
       or v_digest.sender_user_id <> v_sched or cardinality(v_holders) < 2 or v_got <> v_holders
       or not (v_mgr = any (v_got)) or v_idle = any (v_got) or v_p1 = any (v_got) then
      raise exception 'FAIL C3: the digest reads [%] for % of % holder(s)', v_digest.body, cardinality(v_got), cardinality(v_holders);
    end if;

    -- C4. the closed days stay on the review list
    if exists (select 1 from cma.workday_summary s where not s.needs_correction) then
      raise exception 'FAIL C4: a scheduler-closed day is not flagged for review';
    end if;

    -- C5. a second run closes and sends nothing
    select count(*) into v_n from cma.close_forgotten_workdays();
    if v_n <> 0 or (select count(*) from cma.message) <> 5 or (select count(*) from cma.message_delivery) <> 4 + cardinality(v_holders) then
      raise exception 'FAIL C5: a second run closed % day(s), messages now %', v_n, (select count(*) from cma.message);
    end if;

    -- C6. tenant two is untouched: its day is open and it has no message
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_sched2::text, true);
    if (select w.status from cma.workday w where w.id = v_day_t2) <> 'open' or (select count(*) from cma.message) <> 0 then
      raise exception 'FAIL C6: tenant two was touched by tenant one''s run';
    end if;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- Verdict: per tenant, the window, the close settings and the open days past the window and its grace
-- (the next hourly run closes them)
select t.slug as tenant,
       cma.setting_of(t.id, 'workday.window_start') || ' to ' || cma.setting_of(t.id, 'workday.window_end') as window,
       cma.setting_of(t.id, 'workday.auto_close_at') as auto_close_at,
       cma.setting_of(t.id, 'workday.auto_close_grace_minutes') as grace_minutes,
       cma.setting_of(t.id, 'workday.auto_close_notify_permission') as digest_to,
       (select count(*) from cma.workday w
        where w.tenant_id = t.id and w.status = 'open'
          and cma.business_day_time(w.business_date, w.timezone, cma.setting_of(t.id, 'workday.window_end')::time)
              + make_interval(mins => cma.setting_of(t.id, 'workday.auto_close_grace_minutes')::integer) <= now()) as open_past_grace,
       case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS' else 'PASS' end as verdict
from cma.tenant t
where t.status = 'active'
order by t.slug;
