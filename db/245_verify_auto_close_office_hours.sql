-- =============================================================================================
-- 245_verify_auto_close_office_hours.sql: verifies addition 0009zv, a forgotten workday closed at the end of the Default
-- market's office hours when no shift is published
-- =============================================================================================
-- Universal: no seed is assumed. S1 checks the structure on the database itself; U1 the office hours' end on a market's
-- calendar row, which reads no table; blocks O and F each build a throwaway tenant inside a subtransaction that is always
-- rolled back, so nothing stays and the script runs in dev and in prod. Synthetic data only (people v9zv-…@example.invalid,
-- markets with invented hours); a check prints times and rules, never a row of anyone. Every time is built on the Monday
-- of the week three days back, in the throwaway tenants' zone (Europe/Amsterdam), so the verdict does not depend on the
-- hour it runs and the sweep's window and grace have passed. Every check writes one row, OK or FAIL (its detail then
-- starts "FAIL <id>"), because Cloud SQL Studio shows no notices. Run as your own IAM login after
-- 244_auto_close_office_hours.sql, dev first, then prod. Expected: S1, S2, U1, O1 to O12, F1, F2 OK, then "PASS 0009zv".
-- Provoked (verify.provoke true at the top): every row FAIL and the verdict PROVOKED, NOT A PASS; F1 then also compares
-- with a deliberate difference (one closed day left out of 46's side), which its detail shows.
--
-- The throwaway tenant: window 07:00 to 22:00, workday.auto_close_at 16:00 (so the default time differs from every office
-- hours' end), an hour's grace, clocking in again on. Markets and their office hours: '*' Monday to Friday 09:00-17:00;
-- GB (Europe/London) its own, Monday to Friday 10:00-18:30; NL (Europe/Amsterdam) none of its own, so the '*' row; DE
-- (Europe/Berlin) Monday 08:00-12:00 and 13:00-17:45; FR (Europe/Paris) Tuesday to Friday only; SE (Europe/Stockholm)
-- Monday 10:00-23:30; ES (Europe/Madrid) Monday 09:00-18:00 with a holiday on the date; BE (Europe/Brussels) Monday
-- 09:00-19:00, deactivated after its person clocked in. Eleven people clock in at 08:00 and forget to clock out.
--
--   S1  0009zv recorded after 0009zu; the setting workday.auto_close_office_hours boolean with default false;
--       cma.office_hours_end_in and cma.close_forgotten_workdays the application's only (not public, not the readers');
--       the sweep returns end_rule and reads the office hours through cma.business_calendar_of only (no second reader
--       of cma.business_hours); cma.office_hours_end_in reads no table
--   S2  a value other than true or false refused (CMA04)
--   U1  cma.office_hours_end_in: the last range's end in the market's zone, 24:00 the next midnight, null on a closed
--       weekday, on a holiday and without a zone
--   O1  setting on, a shift published: the shift end (shift)
--   O2  no shift, a Default market with its own hours (GB 10:00-18:30 London): 18:30 London, 19:30 in the day's zone
--       (office_hours)
--   O3  no shift, a Default market following the default (NL): 17:00 from the '*' row (office_hours); the Default market
--       is read at sweep time (it was GB at clock-in)
--   O4  several ranges (DE): the end of the last one, 17:45 (office_hours)
--   O5  a closed weekday (FR on a Monday): workday.auto_close_at, 16:00 (default)
--   O6  no Default market: 16:00 (default)
--   O7  a deactivated Default market (BE): 16:00 (default)
--   O8  the last event (20:10) after the office hours' end (GB 19:30): the last event (last_event)
--   O9  the office hours' end after the window end (SE 23:30): the window end, 22:00 (office_hours)
--   O10 a holiday of the Default market (ES): 16:00 (default)
--   O11 split shift (0008zp): a later session started at 20:00, after the office hours' end, is ended at its own start
--       (last_event)
--   O12 unchanged around it: eleven days closed and none left open, every end a system event, every day flagged for
--       review, the person's notice with the time in the day's zone (19:30 for O2), one digest of 11, a second run closes
--       nothing
--   F1  setting off: the sweep closes the same days at the same times with the same rules and sends the same notices as
--       46's definition (kept below), row for row
--   F2  setting off: a Default market with its own hours (GB) closes at workday.auto_close_at, 16:00 (default)
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);                 -- 'true' to make every check fail

drop table if exists pg_temp.verify_0009zv;
create temporary table verify_0009zv (ord integer, check_name text, result text, detail text);

create or replace function pg_temp.v9zv_row(p_ord integer, p_id text, p_name text, p_ok boolean, p_detail text)
returns void
language sql
as $$
  insert into pg_temp.verify_0009zv
  select p_ord, p_id || ' ' || p_name,
         case when coalesce(p_ok, false) and not current_setting('verify.provoke')::boolean then 'OK' else 'FAIL' end,
         case when coalesce(p_ok, false) and not current_setting('verify.provoke')::boolean then coalesce(p_detail, '')
              else 'FAIL ' || p_id || ': ' || case when current_setting('verify.provoke')::boolean then 'provoked; ' else '' end
                   || coalesce(p_detail, '(no detail)') end
$$;

-- The previous definition, verbatim but for its name: 46's cma.close_forgotten_workdays
create or replace function pg_temp.v9zv_close_46(p_grace_minutes integer default null)
returns table (workday_id uuid, user_id uuid, business_date date, ended_at timestamptz, end_rule text)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant    uuid := cma.current_tenant_id();
  v_actor     uuid;
  v_grace     integer;
  v_close_at  time;
  v_perm      text;
  v_end       timestamptz;
  v_rule      text;
  v_msg       uuid;
  v_n         integer := 0;
  v_first     date;
  v_last      date;
  v_users     uuid[];
  w           record;
begin
  v_actor := cma.assert_permission('workday.close_forgotten');
  if cma.current_actor_label() is null then
    perform set_config('app.actor_label', 'scheduler', true);
  end if;
  v_grace := coalesce(p_grace_minutes, cma.setting_of(v_tenant, 'workday.auto_close_grace_minutes')::integer, 120);
  if v_grace < 0 then
    raise exception 'grace is 0 minutes or more' using errcode = 'CMA04';
  end if;
  v_close_at := cma.setting_of(v_tenant, 'workday.auto_close_at')::time;

  for w in
    select d.id, d.user_id, d.business_date, d.timezone,
           cma.business_day_end(d.business_date, d.timezone) as day_end,
           (select max(e.occurred_at) from cma.time_event_effective e
            where e.tenant_id = d.tenant_id and e.workday_id = d.id) as last_at,
           (select case when r.kind = 'shift' then cma.business_day_time(d.business_date, d.timezone, r.end_time) end
            from cma.roster_published_entry r
            where r.user_id = d.user_id and r.business_date = d.business_date
            order by r.published_at desc
            limit 1) as shift_end
    from cma.workday d
    where d.tenant_id = v_tenant and d.status = 'open'
      and cma.business_day_end(d.business_date, d.timezone) + make_interval(mins => v_grace) <= now()
    order by d.business_date, d.user_id
    for update of d
  loop
    v_end  := least(coalesce(w.shift_end, cma.business_day_time(w.business_date, w.timezone, v_close_at)), w.day_end);
    v_rule := case when w.shift_end is not null then 'shift' else 'default' end;
    if w.last_at > v_end then
      v_end  := w.last_at;
      v_rule := 'last_event';
    end if;
    insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source)
    values (v_tenant, w.id, w.user_id, 'end', null, v_end, 'system');
    perform cma.refresh_workday(w.id);

    -- the person's notice: the date and the time in the day's own zone, no names
    insert into cma.message (tenant_id, kind, urgency, title, body, target, sender_user_id)
    values (v_tenant, 'announcement', 'normal', 'Workday closed automatically',
            format('Your workday of %s was closed automatically at %s because you did not log out. Your supervisor will review it.',
                   to_char(w.business_date, 'Dy DD Mon'), to_char(v_end at time zone w.timezone, 'HH24:MI')),
            jsonb_build_object('users', jsonb_build_array(w.user_id)), v_actor)
    returning id into v_msg;
    perform cma.deliver_message(v_msg, array[w.user_id]);

    v_n     := v_n + 1;
    v_first := least(v_first, w.business_date);
    v_last  := greatest(v_last, w.business_date);
    workday_id := w.id; user_id := w.user_id; business_date := w.business_date; ended_at := v_end; end_rule := v_rule;
    return next;
  end loop;

  -- management's digest: one per run, counts and dates only
  if v_n > 0 then
    v_perm := cma.setting_of(v_tenant, 'workday.auto_close_notify_permission');
    select coalesce(array_agg(u.id order by u.id), '{}') into v_users
    from cma.app_user u
    where u.tenant_id = v_tenant and u.status = 'active' and u.kind = 'person'
      and cma.has_permission(u.id, v_perm);
    insert into cma.message (tenant_id, kind, urgency, title, body, target, sender_user_id)
    values (v_tenant, 'announcement', 'normal', 'Workdays closed automatically',
            format('%s workday(s) of %s were closed automatically. Review them on Team hours.', v_n,
                   case when v_first = v_last then to_char(v_first, 'Dy DD Mon')
                        else to_char(v_first, 'Dy DD Mon') || ' to ' || to_char(v_last, 'Dy DD Mon') end),
            jsonb_build_object('permission', v_perm), v_actor)
    returning id into v_msg;
    perform cma.deliver_message(v_msg, v_users);
  end if;
end
$$;

-- The throwaway tenant (see the header): its markets, office hours, holiday, settings, roster, people and their forgotten
-- days. Written as the owner; the days opened as the application, by each person. Leaves the role at cma_owner and the
-- tenant context on the new tenant. Returns the tenant
create or replace function pg_temp.v9zv_setup(p_slug text, p_office boolean, p_d date)
returns uuid
language plpgsql
as $$
declare
  v_zone text := 'Europe/Amsterdam';
  v_t    uuid;
  v_mgr  uuid;
  v_week uuid;
  v_day  uuid;
  r      record;
begin
  v_t := cma.create_tenant(p_slug, 'Verify 0009zv ' || p_slug, v_zone);
  insert into cma.app_user (tenant_id, email, display_name)
  select v_t, 'v9zv-' || n || '@example.invalid', n
  from unnest(array['mgr', 'shift', 'gb', 'nl', 'de', 'closed', 'none', 'inactive', 'late', 'window', 'holiday', 'split']) n;
  insert into cma.user_role (tenant_id, user_id, role_id)
  select u.tenant_id, u.id, ar.id
  from cma.app_user u
  join cma.app_role ar on ar.tenant_id = u.tenant_id and ar.key = case when u.display_name = 'mgr' then 'manager' else 'agent' end
  where u.tenant_id = v_t and u.email like 'v9zv-%';
  select id into v_mgr from cma.app_user where tenant_id = v_t and display_name = 'mgr';

  insert into cma.tenant_setting (tenant_id, key, value) values
    (v_t, 'workday.window_start', '07:00'), (v_t, 'workday.window_end', '22:00'), (v_t, 'workday.auto_close_at', '16:00'),
    (v_t, 'workday.auto_close_grace_minutes', '60'), (v_t, 'workday.clock_in_again', 'true'),
    (v_t, 'workday.auto_close_office_hours', p_office::text);

  insert into cma.market (tenant_id, code, name, time_zone, language_code, currency) values
    (v_t, 'GB', 'Verify GB', 'Europe/London',    'en', 'GBP'),
    (v_t, 'NL', 'Verify NL', 'Europe/Amsterdam', 'nl', 'EUR'),
    (v_t, 'DE', 'Verify DE', 'Europe/Berlin',    'de', 'EUR'),
    (v_t, 'FR', 'Verify FR', 'Europe/Paris',     'fr', 'EUR'),
    (v_t, 'SE', 'Verify SE', 'Europe/Stockholm', 'sv', 'SEK'),
    (v_t, 'ES', 'Verify ES', 'Europe/Madrid',    'es', 'EUR'),
    (v_t, 'BE', 'Verify BE', 'Europe/Brussels',  'nl', 'EUR');
  insert into cma.business_hours (tenant_id, market, weekday, opens_at, closes_at)
  select v_t, '*', g, time '09:00', time '17:00' from generate_series(1, 5) g;
  insert into cma.business_hours (tenant_id, market, weekday, opens_at, closes_at)
  select v_t, 'GB', g, time '10:00', time '18:30' from generate_series(1, 5) g;
  insert into cma.business_hours (tenant_id, market, weekday, opens_at, closes_at)
  select v_t, 'FR', g, time '09:00', time '18:00' from generate_series(2, 5) g;
  insert into cma.business_hours (tenant_id, market, weekday, opens_at, closes_at) values
    (v_t, 'DE', 1, '08:00', '12:00'), (v_t, 'DE', 1, '13:00', '17:45'),
    (v_t, 'SE', 1, '10:00', '23:30'), (v_t, 'ES', 1, '09:00', '18:00'), (v_t, 'BE', 1, '09:00', '19:00');
  insert into cma.business_holiday (tenant_id, market, day, name) values (v_t, 'ES', p_d, 'Verify holiday');

  -- the Default markets at clock-in; nl's is GB until after the clock-in (read at sweep time), none has none
  update cma.app_user u
  set default_hours_market_code = case u.display_name
        when 'shift' then 'GB' when 'gb' then 'GB' when 'nl' then 'GB' when 'de' then 'DE' when 'closed' then 'FR'
        when 'inactive' then 'BE' when 'late' then 'GB' when 'window' then 'SE' when 'holiday' then 'ES' when 'split' then 'GB' end
  where u.tenant_id = v_t and u.email like 'v9zv-%' and u.display_name not in ('mgr', 'none');

  -- shift's published shift 09:00 to 16:30 (the planner cannot write the past, so the owner writes it as it stood)
  insert into cma.roster_week (tenant_id, team_id, week_start, status, version, published_at, published_by)
  values (v_t, null, date_trunc('week', p_d)::date, 'published', 1, now() - interval '1 day', v_mgr)
  returning id into v_week;
  insert into cma.roster_entry (tenant_id, roster_week_id, user_id, business_date, kind, start_time, end_time, recorded_at, recorded_by)
  select v_t, v_week, u.id, p_d, 'shift', '09:00', '16:30', now() - interval '2 days', v_mgr
  from cma.app_user u where u.tenant_id = v_t and u.display_name = 'shift';

  -- the forgotten days, each opened by its person at 08:00; late changes status at 20:10; split logs out at 12:00 and
  -- clocks in again at 20:00
  perform set_config('role', 'cma_app', true);
  perform set_config('app.actor_label', '', true);
  perform set_config('app.tenant_id', v_t::text, true);
  for r in select u.id, u.display_name from cma.app_user u
           where u.tenant_id = v_t and u.email like 'v9zv-%' and u.display_name <> 'mgr' order by u.display_name collate "C" loop
    perform set_config('app.user_id', r.id::text, true);
    v_day := (cma.open_workday((p_d + time '08:00') at time zone v_zone)).id;
    if r.display_name = 'late' then
      perform cma.set_status(v_day, 'break', (p_d + time '20:10') at time zone v_zone);
    elsif r.display_name = 'split' then
      perform cma.end_workday(v_day, (p_d + time '12:00') at time zone v_zone, 'user');
      perform cma.open_workday((p_d + time '20:00') at time zone v_zone);
    end if;
  end loop;
  perform set_config('role', 'cma_owner', true);

  -- after the clock-ins: nl's Default market becomes NL, BE goes inactive
  update cma.app_user set default_hours_market_code = 'NL' where tenant_id = v_t and display_name = 'nl';
  update cma.market set status = 'inactive' where tenant_id = v_t and code = 'BE';
  return v_t;
end
$$;

-- S1. Structure and privileges
do $$
declare
  v_ok  boolean;
  v_fn  text;
  v_bad text := '';
begin
  v_ok := (select z.applied_at >= u.applied_at from cma.schema_migration z, cma.schema_migration u
           where z.version = '0009zv' and u.version = '0009zu');
  if not coalesce(v_ok, false) then v_bad := v_bad || ' 0009zv not recorded after 0009zu;'; end if;
  if not exists (select 1 from cma.setting where key = 'workday.auto_close_office_hours' and value_type = 'boolean' and default_value = 'false') then
    v_bad := v_bad || ' the setting is not boolean with default false;';
  end if;
  foreach v_fn in array array['cma.office_hours_end_in(text,integer[],time without time zone[],date[],date)',
                              'cma.close_forgotten_workdays(integer)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || format(' %s missing;', v_fn);
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                     where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE') then
      v_bad := v_bad || format(' %s is not the application''s only;', v_fn);
    end if;
  end loop;
  if not exists (select 1 from pg_proc p where p.oid = to_regprocedure('cma.close_forgotten_workdays(integer)')
                   and 'end_rule' = any (p.proargnames)
                   and p.prosrc like '%cma.business_calendar_of(%' and p.prosrc like '%cma.office_hours_end_in(%'
                   and p.prosrc not like '%business_hours%') then
    v_bad := v_bad || ' the sweep does not return end_rule or does not read the office hours through cma.business_calendar_of only;';
  end if;
  if exists (select 1 from pg_proc p where p.oid = to_regprocedure('cma.office_hours_end_in(text,integer[],time without time zone[],date[],date)')
               and p.prosrc like '%cma.%') then
    v_bad := v_bad || ' cma.office_hours_end_in reads a table;';
  end if;
  perform pg_temp.v9zv_row(10, 'S1', 'structure and privileges', v_bad = '',
    case when v_bad = '' then '0009zv after 0009zu; setting boolean, default false; both functions cma_app only; one reader of the office hours'
         else 'FAIL S1:' || v_bad end);
end
$$;

-- U1. The office hours' end on a calendar row (reads no table)
do $$
declare
  v_d   date := date_trunc('week', current_date - 3)::date;   -- a Monday
  v_got text;
  v_want text;
begin
  v_got := concat_ws(' | ',
    cma.office_hours_end_in('Europe/London', array[1, 1, 2], array[time '10:00', time '18:30', time '17:00'], '{}', v_d)
      = (v_d + time '18:30') at time zone 'Europe/London',
    cma.office_hours_end_in('Europe/Amsterdam', array[1], array[time '24:00'], '{}', v_d) = (v_d + 1)::timestamp at time zone 'Europe/Amsterdam',
    cma.office_hours_end_in('Europe/London', array[2], array[time '18:30'], '{}', v_d) is null,
    cma.office_hours_end_in('Europe/London', '{}', '{}', '{}', v_d) is null,
    cma.office_hours_end_in('Europe/London', array[1], array[time '18:30'], array[v_d], v_d) is null,
    cma.office_hours_end_in(null, array[1], array[time '18:30'], '{}', v_d) is null);
  v_want := 't | t | t | t | t | t';
  perform pg_temp.v9zv_row(20, 'U1', 'the end of the last range, in the market''s zone', v_got = v_want,
    case when v_got = v_want then 'last range 18:30 London; 24:00 next midnight; closed weekday, no ranges, holiday, no zone: none'
         else 'got ' || v_got end);
end
$$;

-- O. Setting on: every case of the rule, then everything around it unchanged
do $$
declare
  v_zone  text := 'Europe/Amsterdam';
  v_d     date := date_trunc('week', current_date - 3)::date;   -- a Monday
  v_t     uuid;
  v_sched uuid;
  v_res   jsonb;
  v_ids   text[] := '{}';
  v_names text[] := '{}';
  v_oks   boolean[] := '{}';
  v_dets  text[] := '{}';
  v_s2    text;
  v_n     int;
  v_body  text;
  v_dig   text;
  v_open  int;
  v_flag  int;
  v_sys   int;
  v_err   text;
  c       record;
begin
  begin
    v_t := pg_temp.v9zv_setup('verify-0009zv-on', true, v_d);
    -- S2: a value other than true or false is refused
    begin
      update cma.tenant_setting set value = 'maybe' where tenant_id = v_t and key = 'workday.auto_close_office_hours';
      v_s2 := 'accepted';
    exception when others then
      v_s2 := sqlstate;
    end;

    select id into v_sched from cma.app_user where tenant_id = v_t and kind = 'system' and email = 'scheduler@system.invalid';
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('app.user_id', v_sched::text, true);
    select jsonb_object_agg(u.display_name, jsonb_build_object('at', x.ended_at, 'rule', x.end_rule)) into v_res
    from cma.close_forgotten_workdays() x
    join cma.app_user u on u.id = x.user_id;

    for c in
      select * from (values
        (1,  'O1',  'shift published: the shift end',                              'shift',    (v_d + time '16:30') at time zone v_zone, 'shift'),
        (2,  'O2',  'own office hours (GB 10:00-18:30 London): 18:30 London',     'gb',       (v_d + time '18:30') at time zone 'Europe/London', 'office_hours'),
        (3,  'O3',  'following the default row (NL): 17:00, read at sweep time',  'nl',       (v_d + time '17:00') at time zone v_zone, 'office_hours'),
        (4,  'O4',  'several ranges (DE): the end of the last one',               'de',       (v_d + time '17:45') at time zone 'Europe/Berlin', 'office_hours'),
        (5,  'O5',  'closed weekday (FR on Monday): workday.auto_close_at',       'closed',   (v_d + time '16:00') at time zone v_zone, 'default'),
        (6,  'O6',  'no Default market: workday.auto_close_at',                   'none',     (v_d + time '16:00') at time zone v_zone, 'default'),
        (7,  'O7',  'deactivated Default market (BE): workday.auto_close_at',     'inactive', (v_d + time '16:00') at time zone v_zone, 'default'),
        (8,  'O8',  'last event after the office hours'' end: the last event',    'late',     (v_d + time '20:10') at time zone v_zone, 'last_event'),
        (9,  'O9',  'office hours'' end after the window end: the window end',    'window',   (v_d + time '22:00') at time zone v_zone, 'office_hours'),
        (10, 'O10', 'holiday of the Default market (ES): workday.auto_close_at',  'holiday',  (v_d + time '16:00') at time zone v_zone, 'default'),
        (11, 'O11', 'later session after the office hours'' end: its own start',  'split',    (v_d + time '20:00') at time zone v_zone, 'last_event')
      ) as e(n, id, name, person, want_at, want_rule)
      order by n
    loop
      v_ids   := v_ids || c.id;
      v_names := v_names || c.name;
      v_oks   := v_oks || ((v_res -> c.person ->> 'at')::timestamptz = c.want_at and v_res -> c.person ->> 'rule' = c.want_rule);
      v_dets  := v_dets || format('%s at %s (%s), expected %s (%s)', c.person,
                                  to_char((v_res -> c.person ->> 'at')::timestamptz at time zone v_zone, 'HH24:MI'), v_res -> c.person ->> 'rule',
                                  to_char(c.want_at at time zone v_zone, 'HH24:MI'), c.want_rule);
    end loop;

    -- O12: unchanged around the rule
    select count(*) filter (where w.status = 'open'), count(*) filter (where s.needs_correction)
    into v_open, v_flag
    from cma.workday w join cma.workday_summary s on s.workday_id = w.id;
    select count(*) into v_sys from cma.time_event_effective e where e.kind = 'end' and e.source = 'system';
    select m.body into v_body from cma.message m join cma.app_user u on m.target -> 'users' ? u.id::text where u.display_name = 'gb';
    select string_agg(m.body, ' | ') into v_dig from cma.message m where m.title = 'Workdays closed automatically';
    select count(*) into v_n from cma.close_forgotten_workdays();
    v_ids   := v_ids || 'O12'::text;
    v_names := v_names || 'notices, digest, flags and a second run as before'::text;
    v_oks   := v_oks || (jsonb_typeof(v_res) = 'object' and (select count(*) from jsonb_object_keys(v_res)) = 11 and v_open = 0
                         and v_flag = 11 and v_sys = 11 and v_n = 0
                         and v_body = format('Your workday of %s was closed automatically at 19:30 because you did not log out. Your supervisor will review it.', to_char(v_d, 'Dy DD Mon'))
                         and v_dig = format('11 workday(s) of %s were closed automatically. Review them on Team hours.', to_char(v_d, 'Dy DD Mon'))
                         and (select count(*) from cma.message where title = 'Workday closed automatically') = 11);
    v_dets  := v_dets || format('%s closed, %s open, %s flagged, %s system ends; notice: %s; digest: %s; second run closed %s',
                                (select count(*) from jsonb_object_keys(coalesce(v_res, '{}'))), v_open, v_flag, v_sys,
                                coalesce(v_body, 'none'), coalesce(v_dig, 'none'), v_n);

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then v_err := sqlstate || ' ' || sqlerrm;
  end;

  perform pg_temp.v9zv_row(30, 'S2', 'a value other than true or false refused', v_s2 = 'CMA04', 'got ' || coalesce(v_s2, v_err, 'nothing'));
  if v_err is not null then
    perform pg_temp.v9zv_row(40, 'O0', 'the block ran', false, v_err);
  end if;
  for i in 1 .. coalesce(array_length(v_ids, 1), 0) loop
    perform pg_temp.v9zv_row(40 + i, v_ids[i], v_names[i], v_oks[i], v_dets[i]);
  end loop;
end
$$;

-- F. Setting off: today's behaviour, against 46's definition row for row
do $$
declare
  v_zone  text := 'Europe/Amsterdam';
  v_d     date := date_trunc('week', current_date - 3)::date;   -- a Monday
  v_t     uuid;
  v_sched uuid;
  v_old   text;
  v_new   text;
  v_oldm  text;
  v_newm  text;
  v_gb    text;
  v_err   text;
  v_f1    boolean;
  v_f2    boolean;
  v_det1  text;
begin
  begin
    v_t := pg_temp.v9zv_setup('verify-0009zv-off', false, v_d);
    select id into v_sched from cma.app_user where tenant_id = v_t and kind = 'system' and email = 'scheduler@system.invalid';
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('app.user_id', v_sched::text, true);

    -- 46's definition first, rolled back, then this addition's on the same days
    begin
      select string_agg(format('%s %s %s', u.display_name, to_char(x.ended_at at time zone v_zone, 'HH24:MI'), x.end_rule), ', '
                        order by u.display_name collate "C")
      into v_old
      from pg_temp.v9zv_close_46() x join cma.app_user u on u.id = x.user_id
      -- provoked: 46's side without its first person, a deliberate difference the comparison must see
      where not (current_setting('verify.provoke')::boolean and u.display_name = 'closed');
      select string_agg(m.title || ': ' || m.body, ' | ' order by m.title collate "C", m.body collate "C") into v_oldm from cma.message m;
      raise exception using errcode = 'CMAOK', message = 'rollback';
    exception when sqlstate 'CMAOK' then null;
    end;
    select string_agg(format('%s %s %s', u.display_name, to_char(x.ended_at at time zone v_zone, 'HH24:MI'), x.end_rule), ', '
                      order by u.display_name collate "C")
    into v_new
    from cma.close_forgotten_workdays() x join cma.app_user u on u.id = x.user_id;
    select string_agg(m.title || ': ' || m.body, ' | ' order by m.title collate "C", m.body collate "C") into v_newm from cma.message m;
    v_gb := (regexp_match(v_new, 'gb [0-9:]+ [a-z_]+'))[1];

    v_f1   := v_old = v_new and v_oldm = v_newm;
    v_det1 := case when v_old = v_new and v_oldm = v_newm then '11 days and 12 messages as 46: ' || v_new
                   else format('46: %s; 0009zv: %s; messages %s', v_old, v_new, case when v_oldm = v_newm then 'equal' else 'differ' end) end;
    v_f2   := v_gb = 'gb 16:00 default' and v_new not like '%office_hours%';

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then v_err := sqlstate || ' ' || sqlerrm;
  end;

  perform pg_temp.v9zv_row(60, 'F1', 'setting off: the same closes and notices as 46, row for row', v_f1, coalesce(v_err, v_det1));
  perform pg_temp.v9zv_row(61, 'F2', 'setting off: own office hours (GB) close at workday.auto_close_at', v_f2, coalesce(v_err, v_gb));
end
$$;

drop function if exists pg_temp.v9zv_setup(text, boolean, date);
drop function if exists pg_temp.v9zv_close_46(integer);
drop function if exists pg_temp.v9zv_row(integer, text, text, boolean, text);

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0009zv
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0009zv where result <> 'OK') then 'FAIL'
                  when (select count(*) from pg_temp.verify_0009zv where result = 'OK') <> 17 then 'FAIL'
                  else 'PASS 0009zv' end,
             format('245_verify_auto_close_office_hours: %s OK, %s FAIL', (select count(*) from pg_temp.verify_0009zv where result = 'OK'),
                    (select count(*) from pg_temp.verify_0009zv where result <> 'OK'))) x
order by ord;
reset role;
