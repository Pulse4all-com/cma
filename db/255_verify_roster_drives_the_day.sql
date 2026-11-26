-- =============================================================================================
-- 255_verify_roster_drives_the_day.sql: verifies addition 0010a (254_roster_drives_the_day.sql), the roster drives the
-- agent's day (brief B)
-- =============================================================================================
-- Read-only on real data: every behaviour check runs on a throwaway tenant inside a block that always rolls back; the
-- R checks read every active tenant as it is, and the one call of the all-tenant job (B9) asks for a minute in the year
-- 2000, so it finds no workday and writes nothing. Run as your own IAM login after 254: dev first (normal, then provoked),
-- then prod before the merge. Expected: the last row reads "PASS | 255_verify_roster_drives_the_day: n PASS, 0 FAIL, …".
--
-- The throwaway tenant's people live in the zone Etc/GMT±n in which it is between 12:00 and 13:00 now, so "today" and its
-- plan lie around now at any hour of the run; every instant is shown relative to Q, the quarter hour now falls in (Q-170
-- is 170 minutes before it). The plan (local times, the 15-minute grid):
--   A (Default market NL)  shift Q-180 to Q+180: MC·SE Q-180, SL·SE Q-150, SB Q-60, GO·SE Q-45, GO·DE Q, LB Q+45, GO·DE Q+75
--   B (Default market SE)  shift Q-120 to Q+120: GO (written without a market, so SE) Q-120, the absence Sick Q-30 to Q+120
--   C (Default market NL)  shift Q-180 to Q-60: GO·NL Q-180 to Q-60, so now is after C's shift
--   E (Default market DE)  shift Q-120 to Q+120 without any block (published as owner, as a week before E5 could be)
--   F (no Default market)  for E10's refusal
--
-- Checks
--   S1  the addition 0010a recorded once, after 0009zz
--   S2  the columns, constraints and trigger: time_event.assignment_type_id with its key, kind check and trigger, the source
--       roster in a validated check; roster_assignment.absence_type_id with its key, assignment_type_id nullable, the one
--       kind and the absence's missing market as checks; the readers' views end with the new columns
--   S3  the functions: the owner's, the application's only, the caller's rights except roster_switch_all (definer with a
--       fixed search path), the reads stable, set_status's five arguments (the four-argument one gone), the trigger
--       function nobody's
--   S4  the settings, the permission, and every tenant's Scheduler role holding workday.roster_switch
--   B1  Clock in late (E4): A clocks in at Q-170 inside MC·SE and starts on MC under SE, source user
--   B2  the roster job (E2): at Q-150 A goes to SL·SE (source roster), again at the same minute nothing; at Q-60 to SB
--       without a market (a pause has none); at Q-45 to GO·SE
--   B3  Switch (E6) and the deviation (E7): A switches to CC·SE at Q-40; the job at Q-30 leaves it (the agent's own Switch
--       after the boundary stands); my_day marks it "CC SE (planned GO SE)"; the boundary at Q takes over again (GO·DE)
--   B4  the notice (E3) after the roster switch at Q, gone after the agent's own Switch; Off plan now (CC·SE against GO·DE
--       since Q, next LB at Q+45); Back to plan (GO·DE) clears it, and a second click books nothing
--   B5  an absence block ends the day (E9): B clocked in at Q-115 on GO·SE (the Default market filled at writing, E10); the
--       job at Q-25 ends B's day at Q-30, source roster
--   B6  after the shift (E8): C on GO·NL; the job now writes nothing; C switches to SL·SE and stays on it
--   B7  E5's safety net: E's shift without blocks starts on roster.fallback_status (meeting here) under E's Default market,
--       no assignment; Publish of a week with E's empty shift refuses (CMA04, empty_shifts names E and the date); a shift
--       just drawn for today waits (no_assignments)
--   B8  the rules in the table (E1, E9, E10): a pause with a market refused (Switch and the table), a work event without a
--       market refused, an Other status (Training) books no market and no assignment, a market alone on a pause refused;
--       a correction keeps the event's assignment; the planner's absence block (with a work block, a market refused, both
--       kinds refused), a work block without a market takes the Default market and a person without one is refused; the
--       agent's schedule shows the absence block
--   B9  my_hours: A's week per assignment and market, the pauses apart, the split of today and the planned minutes; the
--       job for all tenants refuses a request's context (CMA06) and, outside one, serves each tenant for a minute in 2000
--       and leaves no tenant set
--   R1  per active tenant: no work block without a market whose person has an active Default market (E10's backfill)
--   R2  per active tenant: every event with an assignment keeps E1's rule (the type's status; a market on work, none on a
--       pause)
--   R3  per active tenant, this week and next: roster_published_blocks_json = 252's definition for every block that is not
--       an absence (the rewrite keeps the answers; only absenceKey is new)
--   R4  per active tenant, this week and next: roster_blocks_json = 252's for every block that is not an absence
-- Provoke: set verify.provoke to 'true' (every check) or one check's id ('B3'); a provoked check compares with a deliberate
-- difference (R1, R2: a count of one more; R3, R4: 252's side loses an element).
-- Collation: every ordering that feeds a compared text says collate "C".
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);                 -- 'true' for every check, or one check's id such as 'B3'

drop table if exists pg_temp.verify_0010a;
create temporary table verify_0010a (ord integer, check_name text, result text, detail text);
grant select, insert on pg_temp.verify_0010a to cma_app;

create or replace function pg_temp.v0010a_p(p_id text)
returns boolean
language sql stable
as $$
  select current_setting('verify.provoke') in ('true', p_id)
$$;

-- One check's row: PASS when what was found equals what is expected; provoked, the expectation carries a deliberate difference
create or replace function pg_temp.v0010a_row(p_ord integer, p_id text, p_name text, p_found text, p_expected text)
returns void
language plpgsql
as $$
declare
  v_exp text := case when pg_temp.v0010a_p(p_id) then coalesce(p_expected, '') || ' [provoked: a deliberate difference]' else p_expected end;
begin
  insert into pg_temp.verify_0010a values (p_ord, p_id || ' ' || p_name,
    case when p_found is not distinct from v_exp then 'PASS' else 'FAIL' end,
    case when p_found is not distinct from v_exp then left(coalesce(p_found, 'null'), 900)
         else left('found ' || coalesce(p_found, 'null') || ' | expected ' || coalesce(v_exp, 'null'), 3000) end);
end
$$;

-- An error's SQLSTATE for the refusal checks: the code, or 'accepted' when the call went through
create or replace function pg_temp.v0010a_try(p_sql text)
returns text
language plpgsql
as $$
begin
  execute p_sql;
  return 'accepted';
exception when others then
  return sqlstate;
end
$$;
grant execute on function pg_temp.v0010a_try(text) to cma_app;

-- An instant relative to Q (verify.q), as Q-170 or Q+0
create or replace function pg_temp.v0010a_rel(p_at timestamptz)
returns text
language sql stable
as $$
  select case when p_at is null then '-' else
    'Q' || case when p_at >= current_setting('verify.q')::timestamptz then '+' else '-' end
        || abs(round(extract(epoch from (p_at - current_setting('verify.q')::timestamptz)) / 60))::integer end
$$;
grant execute on function pg_temp.v0010a_rel(timestamptz) to cma_app;

-- The day's effective start and status events in words: Q-170 MC SE user, …; an end as "end"
create or replace function pg_temp.v0010a_events(p_workday_id uuid)
returns text
language sql stable
as $$
  select coalesce(string_agg(pg_temp.v0010a_rel(e.occurred_at) || ' ' ||
           case when e.kind = 'end' then 'end' else coalesce(t.code, s.key) || ' ' || coalesce(e.hours_market_code, '-') end
           || ' ' || e.source, ', ' order by e.occurred_at, e.recorded_at), 'none')
  from cma.time_event e
  left join cma.assignment_type t on t.tenant_id = e.tenant_id and t.id = e.assignment_type_id
  left join cma.work_status s on s.tenant_id = e.tenant_id and s.id = e.status_id
  where e.tenant_id = cma.current_tenant_id() and e.workday_id = p_workday_id and e.kind in ('start', 'status', 'end')
    and not exists (select 1 from cma.time_event c where c.tenant_id = e.tenant_id and c.supersedes_event_id = e.id)
$$;
grant execute on function pg_temp.v0010a_events(uuid) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 252's definitions (252_roster_pause_no_market.sql), kept to compare with (R3, R4)
-- ---------------------------------------------------------------------------------------------
create or replace function pg_temp.v0010a_published_0009zz(p_week_id uuid, p_user_id uuid, p_date date)
returns jsonb
language sql stable
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', t.code, 'name', t.name, 'kind', t.kind, 'workArea', s.work_area, 'isExtra', t.is_extra,
           'start', to_char(a.start_time, 'HH24:MI'),
           'end', case when a.end_time = '24:00'::time then '24:00' else to_char(a.end_time, 'HH24:MI') end,
           'hoursMarket', case when t.kind = 'pause' then null else coalesce(a.hours_market_code, u.default_hours_market_code) end,
           'ownMarket', t.kind <> 'pause' and a.hours_market_code is null,
           'hoursMarketZone', case when t.kind = 'pause' then null else m.time_zone end)
           order by a.start_time), '[]'::jsonb)
  from cma.roster_published_assignment a
  join cma.assignment_type t on t.tenant_id = a.tenant_id and t.id = a.assignment_type_id
  left join cma.work_status s on s.tenant_id = t.tenant_id and s.id = t.work_status_id
  join cma.app_user u on u.tenant_id = a.tenant_id and u.id = a.user_id
  left join cma.market m on m.tenant_id = a.tenant_id and m.code = coalesce(a.hours_market_code, u.default_hours_market_code)
  where a.roster_week_id = p_week_id and a.user_id = p_user_id and a.business_date = p_date
$$;

create or replace function pg_temp.v0010a_blocks_0009zz(p_user_id uuid, p_date date)
returns jsonb
language sql stable
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'assignmentId', a.id, 'code', t.code, 'start', to_char(a.start_time, 'HH24:MI'),
           'end', case when a.end_time = '24:00'::time then '24:00' else to_char(a.end_time, 'HH24:MI') end,
           'hoursMarket', case when t.kind = 'pause' then null else a.hours_market_code end, 'note', a.note, 'recordedAt', a.recorded_at)
           order by a.start_time), '[]'::jsonb)
  from cma.roster_assignment a
  join cma.assignment_type t on t.tenant_id = a.tenant_id and t.id = a.assignment_type_id
  where a.tenant_id = cma.current_tenant_id() and a.user_id = p_user_id and a.business_date = p_date and a.valid_to is null
$$;

-- ---------------------------------------------------------------------------------------------
-- S. The addition, the columns, the functions, the settings
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_bad text := '';
  v_fn  text;
  f     regprocedure;
begin
  -- S1
  perform pg_temp.v0010a_row(1, 'S1', 'the addition 0010a recorded once, after 0009zz',
    format('0010a %s; after 0009zz %s',
      (select count(*) from cma.schema_migration where version = '0010a'),
      coalesce((select a.applied_at >= b.applied_at from cma.schema_migration a, cma.schema_migration b
                where a.version = '0010a' and b.version = '0009zz'), false)),
    '0010a 1; after 0009zz t');

  -- S2
  perform pg_temp.v0010a_row(2, 'S2', 'the columns, their keys, checks and trigger; the readers'' views end with them',
    format('time_event %s, key %s, kind %s, trigger %s, source %s; roster_assignment %s, type nullable %s, key %s, one kind %s, absence no market %s; views %s',
      coalesce((select ic.data_type || ' ' || ic.is_nullable from information_schema.columns ic
                where ic.table_schema = 'cma' and ic.table_name = 'time_event' and ic.column_name = 'assignment_type_id'), 'missing'),
      exists (select 1 from pg_constraint k where k.conrelid = 'cma.time_event'::regclass and k.conname = 'time_event_assignment_fk'
              and k.contype = 'f' and k.confrelid = 'cma.assignment_type'::regclass),
      exists (select 1 from pg_constraint k where k.conrelid = 'cma.time_event'::regclass and k.conname = 'time_event_assignment_kind'
              and k.contype = 'c' and pg_get_constraintdef(k.oid) ~ 'assignment_type_id IS NULL'),
      exists (select 1 from pg_trigger g where g.tgrelid = 'cma.time_event'::regclass and g.tgname = 'time_event_assignment_ok' and g.tgenabled = 'O'),
      coalesce((select k.convalidated::text || ' ' || (pg_get_constraintdef(k.oid) ~ 'roster')::text from pg_constraint k
                where k.conrelid = 'cma.time_event'::regclass and k.conname = 'time_event_source_check'), 'missing'),
      coalesce((select ic.data_type || ' ' || ic.is_nullable from information_schema.columns ic
                where ic.table_schema = 'cma' and ic.table_name = 'roster_assignment' and ic.column_name = 'absence_type_id'), 'missing'),
      (select ic.is_nullable from information_schema.columns ic
       where ic.table_schema = 'cma' and ic.table_name = 'roster_assignment' and ic.column_name = 'assignment_type_id'),
      exists (select 1 from pg_constraint k where k.conrelid = 'cma.roster_assignment'::regclass and k.conname = 'roster_assignment_absence_fk'
              and k.contype = 'f' and k.confrelid = 'cma.absence_type'::regclass),
      exists (select 1 from pg_constraint k where k.conrelid = 'cma.roster_assignment'::regclass and k.conname = 'roster_assignment_one_kind' and k.convalidated),
      exists (select 1 from pg_constraint k where k.conrelid = 'cma.roster_assignment'::regclass and k.conname = 'roster_assignment_absence_no_market' and k.convalidated),
      (select string_agg(v.n || '=' || coalesce((select ic.column_name from information_schema.columns ic
                                                  where ic.table_schema = v.s and ic.table_name = v.n
                                                  order by ic.ordinal_position desc limit 1), 'missing'), ', ' order by v.o)
       from (values (1, 'cma_read', 'time_event'), (2, 'cma_read', 'time_interval'), (3, 'cma_read', 'roster_assignment'),
                    (4, 'cma_read', 'roster_published_assignment'), (5, 'cma', 'roster_published_assignment')) v(o, s, n))),
    'time_event uuid YES, key t, kind t, trigger t, source true true; roster_assignment uuid YES, type nullable YES, key t, one kind t, absence no market t; '
      || 'views time_event=assignment_type_id, time_interval=assignment_type_id, roster_assignment=absence_type_id, '
      || 'roster_published_assignment=absence_type_id, roster_published_assignment=absence_type_id');

  -- S3
  if to_regprocedure('cma.set_status(uuid,text,timestamptz,text)') is not null then
    v_bad := v_bad || 'the 4-argument set_status remains; ';
  end if;
  f := to_regprocedure('cma.set_status(uuid,text,timestamptz,text,text)');
  if f is null or (select p.pronargdefaults <> 3 or p.proargnames[5] <> 'p_assignment_code' from pg_proc p where p.oid = f) then
    v_bad := v_bad || 'set_status''s p_assignment_code is not fifth with its default; ';
  end if;
  foreach v_fn in array array['cma.roster_plan_of(uuid,date)', 'cma.workday_actual_of(uuid)', 'cma.clock_in_choice(uuid,date,timestamptz,text)',
      'cma.my_day(date)', 'cma.my_hours(date)', 'cma.roster_switch_due(timestamptz)', 'cma.roster_switch_all(timestamptz)',
      'cma.roster_empty_shifts(uuid)', 'cma.set_status(uuid,text,timestamptz,text,text)', 'cma.open_workday(timestamptz)',
      'cma.roster_put_assignments(uuid,uuid,date,jsonb,boolean)', 'cma.roster_blocks_json(uuid,date)',
      'cma.roster_published_blocks_json(uuid,uuid,date)', 'cma.roster_assignments(date,text)', 'cma.roster_publish(date,text)',
      'cma.roster_set_cell(date,text,uuid,date,text,time,time,text,text,boolean)'] loop
    f := to_regprocedure(v_fn);
    if f is null then v_bad := v_bad || v_fn || ' missing; '; continue; end if;
    if pg_get_userbyid((select p.proowner from pg_proc p where p.oid = f)) <> 'cma_owner' then v_bad := v_bad || v_fn || ' owner; '; end if;
    if not has_function_privilege('cma_app', f, 'execute') then v_bad := v_bad || v_fn || ' not the application''s; '; end if;
    if has_function_privilege('cma_readonly', f, 'execute') then v_bad := v_bad || v_fn || ' the readers''; '; end if;
    if exists (select 1 from pg_proc p cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
               where p.oid = f and a.grantee = 0) then v_bad := v_bad || v_fn || ' public''s; '; end if;
    if (select p.prosecdef from pg_proc p where p.oid = f) <> (v_fn = 'cma.roster_switch_all(timestamptz)') then
      v_bad := v_bad || v_fn || ' rights; ';
    end if;
    if v_fn in ('cma.roster_plan_of(uuid,date)', 'cma.workday_actual_of(uuid)', 'cma.clock_in_choice(uuid,date,timestamptz,text)',
                'cma.my_day(date)', 'cma.my_hours(date)', 'cma.roster_blocks_json(uuid,date)', 'cma.roster_published_blocks_json(uuid,uuid,date)',
                'cma.roster_assignments(date,text)', 'cma.roster_empty_shifts(uuid)')
       and (select p.provolatile from pg_proc p where p.oid = f) <> 's' then
      v_bad := v_bad || v_fn || ' not stable; ';
    end if;
  end loop;
  if not coalesce((select 'search_path=pg_catalog, public' = any (p.proconfig) from pg_proc p
                   where p.oid = to_regprocedure('cma.roster_switch_all(timestamptz)')), false) then
    v_bad := v_bad || 'roster_switch_all without its fixed search path; ';
  end if;
  f := to_regprocedure('cma.time_event_assignment_ok()');
  if f is null or has_function_privilege('cma_app', f, 'execute') or has_function_privilege('cma_readonly', f, 'execute')
     or exists (select 1 from pg_proc p cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                where p.oid = f and a.grantee = 0) then
    v_bad := v_bad || 'time_event_assignment_ok callable or missing; ';
  end if;
  perform pg_temp.v0010a_row(3, 'S3', 'the functions: the owner''s, the application''s only, the caller''s rights (the job''s all-tenant run a definer), the reads stable, set_status''s fifth argument',
    coalesce(nullif(v_bad, ''), 'ok'), 'ok');

  -- S4
  perform pg_temp.v0010a_row(4, 'S4', 'the settings, the permission, every Scheduler holding it',
    (select string_agg(s.key || '=' || s.default_value || ' ' || s.value_type, '; ' order by s.key collate "C")
     from cma.setting s where s.key in ('roster.switch_notice_minutes', 'roster.fallback_status'))
    || format('; permission %s; schedulers without it %s; settings trigger %s',
         exists (select 1 from cma.permission p where p.key = 'workday.roster_switch'),
         (select count(*) from cma.app_role r
          where r.key = 'scheduler' and not exists (select 1 from cma.role_permission rp where rp.tenant_id = r.tenant_id and rp.role_id = r.id
                                                    and rp.permission_key = 'workday.roster_switch')),
         exists (select 1 from pg_trigger g where g.tgrelid = 'cma.tenant_setting'::regclass and g.tgname = 'check_roster_setting')),
    'roster.fallback_status= text; roster.switch_notice_minutes=5 integer; permission t; schedulers without it 0; settings trigger t');
end
$$;

-- ---------------------------------------------------------------------------------------------
-- B. Behaviour on a throwaway tenant, always rolled back
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_h     integer := 12 - extract(hour from now() at time zone 'UTC')::integer;   -- -11 to 12: noon in that zone now
  v_zone  text;
  v_local timestamp;
  v_q     timestamp;          -- Q, local: the quarter hour now falls in
  v_qtz   timestamptz;
  v_day   date;
  v_ws    date;
  v_t     uuid;
  v_week  uuid;
  v_next  uuid;
  v_mgr uuid; v_sch uuid; v_a uuid; v_b uuid; v_c uuid; v_e uuid; v_f uuid; v_adm uuid;
  wa uuid; wb uuid; wc uuid; we uuid;
  v_j     jsonb;
  v_text  text;
  v_err   text;
  v_t1    timestamptz;
  v_t2    timestamptz;
  v_b1 text; v_b2 text; v_b3 text; v_b4 text; v_b5 text; v_b6 text; v_b7 text; v_b8 text; v_b9 text;
  ev      cma.time_event;
begin
  v_zone  := case when v_h = 0 then 'Etc/GMT' when v_h > 0 then 'Etc/GMT-' || v_h else 'Etc/GMT+' || (-v_h) end;
  v_local := now() at time zone v_zone;
  v_q     := date_trunc('hour', v_local) + (floor(extract(minute from v_local) / 15) * 15)::integer * interval '1 minute';
  v_qtz   := v_q at time zone v_zone;
  v_day   := v_local::date;
  v_ws    := cma.week_start(v_day);
  perform set_config('verify.q', v_qtz::text, false);
  begin
    v_t := cma.create_tenant('verify-0010a', 'Verify 0010a', v_zone);
    v_sch := cma.ensure_scheduler_user(v_t);
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency) values
      (v_t, 'NL', 'Verify NL', 'Europe/Amsterdam', 'nl', 'EUR'),
      (v_t, 'SE', 'Verify SE', 'Europe/Stockholm', 'sv', 'SEK'),
      (v_t, 'DE', 'Verify DE', 'Europe/Berlin', 'de', 'EUR');
    insert into cma.app_user (tenant_id, email, display_name, timezone) values (v_t, 'adm@example.invalid', 'adm', v_zone) returning id into v_adm;
    insert into cma.app_user (tenant_id, email, display_name, timezone) values (v_t, 'mgr@example.invalid', 'mgr', v_zone) returning id into v_mgr;
    insert into cma.app_user (tenant_id, email, display_name, timezone, default_hours_market_code) values (v_t, 'a@example.invalid', 'a', v_zone, 'NL') returning id into v_a;
    insert into cma.app_user (tenant_id, email, display_name, timezone, default_hours_market_code) values (v_t, 'b@example.invalid', 'b', v_zone, 'SE') returning id into v_b;
    insert into cma.app_user (tenant_id, email, display_name, timezone, default_hours_market_code) values (v_t, 'c@example.invalid', 'c', v_zone, 'NL') returning id into v_c;
    insert into cma.app_user (tenant_id, email, display_name, timezone, default_hours_market_code) values (v_t, 'e@example.invalid', 'e', v_zone, 'DE') returning id into v_e;
    insert into cma.app_user (tenant_id, email, display_name, timezone) values (v_t, 'f@example.invalid', 'f', v_zone) returning id into v_f;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t, x.uid, ar.id
    from (values (v_adm, 'admin'), (v_mgr, 'manager'), (v_a, 'agent'), (v_b, 'agent'), (v_c, 'agent'), (v_e, 'agent'), (v_f, 'agent')) as x(uid, role_key)
    join cma.app_role ar on ar.tenant_id = v_t and ar.key = x.role_key;
    insert into cma.work_status (tenant_id, key, name, is_working, is_productive, is_paid, is_billable, is_default, sort_order, work_area) values
      (v_t, 'v_sales', 'Verify sales', true, true, true, true, false, 11, 'sales'),
      (v_t, 'v_ops', 'Verify operations', true, true, true, true, false, 12, 'operations');
    insert into cma.tenant_setting (tenant_id, key, value) values
      (v_t, 'roster.switch_notice_minutes', '20'), (v_t, 'roster.fallback_status', 'meeting');

    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('app.user_id', v_adm::text, true);
    perform set_config('role', 'cma_app', true);
    perform cma.upsert_assignment_type('SL', 'Sales', 'work', 'v_sales', false, 10);
    perform cma.upsert_assignment_type('MC', 'Missed calls', 'work', 'v_ops', false, 20);
    perform cma.upsert_assignment_type('CC', 'Courtesy calls', 'work', 'v_ops', false, 30);
    perform cma.upsert_assignment_type('GO', 'General Ops', 'work', 'v_ops', false, 40);
    perform cma.upsert_assignment_type('SB', 'Short break', 'pause', 'break', false, 90);
    perform cma.upsert_assignment_type('LB', 'Lunch break', 'pause', 'lunch', false, 95);
    perform cma.upsert_assignment_type('X', 'Extra hours', 'work', null, true, 99);

    -- Today's published plan, written as the owner (the planner refuses no date of today, but B's and C's blocks start
    -- before now, and E's shift has no block, as a week published before E5 could hold)
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.user_id', v_mgr::text, true);
    insert into cma.roster_week (tenant_id, team_id, week_start) values (v_t, null, v_ws) returning id into v_week;
    insert into cma.roster_entry (tenant_id, roster_week_id, user_id, business_date, kind, start_time, end_time)
    select v_t, v_week, x.u, v_day, 'shift', (v_q + x.s * interval '1 minute')::time, (v_q + x.e * interval '1 minute')::time
    from (values (v_a, -180, 180), (v_b, -120, 120), (v_c, -180, -60), (v_e, -120, 120)) x(u, s, e);
    insert into cma.roster_assignment (tenant_id, roster_week_id, user_id, business_date, assignment_type_id, absence_type_id,
                                       start_time, end_time, hours_market_code)
    select v_t, v_week, x.u, v_day, t.id, ab.id, (v_q + x.s * interval '1 minute')::time, (v_q + x.e * interval '1 minute')::time, x.m
    from (values (v_a, 'MC', null, -180, -150, 'SE'), (v_a, 'SL', null, -150, -60, 'SE'), (v_a, 'SB', null, -60, -45, null),
                 (v_a, 'GO', null, -45, 0, 'SE'), (v_a, 'GO', null, 0, 45, 'DE'), (v_a, 'LB', null, 45, 75, null),
                 (v_a, 'GO', null, 75, 180, 'DE'),
                 (v_b, 'GO', null, -120, -30, 'SE'), (v_b, null, 'sick', -30, 120, null),
                 (v_c, 'GO', null, -180, -60, 'NL')) x(u, code, absence, s, e, m)
    left join cma.assignment_type t on t.tenant_id = v_t and t.code = x.code
    left join cma.absence_type ab on ab.tenant_id = v_t and ab.key = x.absence;
    update cma.roster_week set status = 'published', version = 1, published_at = clock_timestamp(), published_by = v_mgr
     where tenant_id = v_t and id = v_week;
    perform set_config('role', 'cma_app', true);

    -- B1: a late Clock in at Q-170 starts on MC under SE
    perform set_config('app.user_id', v_a::text, true);
    wa := (cma.open_workday(v_qtz - interval '170 minutes')).id;
    v_b1 := pg_temp.v0010a_events(wa);

    -- B2: the roster job, as the tenant's Scheduler
    perform set_config('app.user_id', v_sch::text, true);
    select string_agg(r.action || ' ' || coalesce(r.code, '-') || ' ' || pg_temp.v0010a_rel(r.occurred_at), ', ') into v_text
    from cma.roster_switch_due(v_qtz - interval '149 minutes') r;
    v_b2 := 'Q-149 ' || coalesce(v_text, 'nothing');
    select string_agg(r.action, ', ') into v_text from cma.roster_switch_due(v_qtz - interval '148 minutes') r;
    v_b2 := v_b2 || '; again ' || coalesce(v_text, 'nothing');
    select string_agg(r.action || ' ' || coalesce(r.code, '-') || ' ' || pg_temp.v0010a_rel(r.occurred_at), ', ') into v_text
    from cma.roster_switch_due(v_qtz - interval '59 minutes') r;
    v_b2 := v_b2 || '; Q-59 ' || coalesce(v_text, 'nothing');
    select string_agg(r.action || ' ' || coalesce(r.code, '-') || ' ' || pg_temp.v0010a_rel(r.occurred_at), ', ') into v_text
    from cma.roster_switch_due(v_qtz - interval '44 minutes') r;
    v_b2 := v_b2 || '; Q-44 ' || coalesce(v_text, 'nothing') || '; ' || pg_temp.v0010a_events(wa);

    -- B3: A's own Switch to CC under SE at Q-40; the job at Q-30 leaves it; the boundary at Q takes over
    perform set_config('app.user_id', v_a::text, true);
    perform cma.set_status(wa, null, v_qtz - interval '40 minutes', 'SE', 'CC');
    perform set_config('app.user_id', v_sch::text, true);
    select string_agg(r.action, ', ') into v_text from cma.roster_switch_due(v_qtz - interval '30 minutes') r;
    v_b3 := 'Q-30 ' || coalesce(v_text, 'nothing');
    perform set_config('app.user_id', v_a::text, true);
    v_j := cma.my_day(null);
    select v_b3 || '; marks ' || coalesce(string_agg(pg_temp.v0010a_rel((m->>'at')::timestamptz) || ' ' || (m->>'code') || ' ' || (m->>'market')
                                                     || ' (planned ' || (m->>'plannedCode') || ' ' || (m->>'plannedMarket') || ')', ', '), 'none')
      into v_b3 from jsonb_array_elements(v_j->'marks') m;
    select v_b3 || '; deviating stretches ' || string_agg(x->>'code', ',') into v_b3
    from jsonb_array_elements(v_j->'actual') x where (x->>'deviates')::boolean;
    perform set_config('app.user_id', v_sch::text, true);
    select string_agg(r.action || ' ' || coalesce(r.code, '-') || ' ' || pg_temp.v0010a_rel(r.occurred_at), ', ') into v_text
    from cma.roster_switch_due(now()) r;
    v_b3 := v_b3 || '; now ' || coalesce(v_text, 'nothing');

    -- B4: the notice of the switch at Q (20 minutes here), then Off plan, then Back to plan
    perform set_config('app.user_id', v_a::text, true);
    v_j := cma.my_day(null);
    v_b4 := format('notice %s %s %s %s; current %s %s %s; off plan %s',
      pg_temp.v0010a_rel((v_j->'notice'->>'at')::timestamptz), v_j->'notice'->>'code', v_j->'notice'->>'market',
      pg_temp.v0010a_rel((v_j->'notice'->>'until')::timestamptz),
      v_j->'current'->>'code', v_j->'current'->>'market', v_j->'current'->>'source', coalesce(v_j->>'offPlan', 'none'));
    v_t1 := v_qtz + (now() - v_qtz) / 3;
    v_t2 := v_qtz + (now() - v_qtz) * 2 / 3;
    perform cma.set_status(wa, null, v_t1, 'SE', 'CC');
    v_j := cma.my_day(null);
    v_b4 := v_b4 || format('; after Switch: notice %s; off plan %s %s %s since %s, next %s %s at %s',
      coalesce(v_j->>'notice', 'none'), v_j->'offPlan'->>'code', v_j->'offPlan'->>'market', v_j->'offPlan'->>'name',
      pg_temp.v0010a_rel((v_j->'offPlan'->>'since')::timestamptz), v_j->'offPlan'->>'nextCode', coalesce(v_j->'offPlan'->>'nextMarket', '-'),
      pg_temp.v0010a_rel((v_j->'offPlan'->>'nextAt')::timestamptz));
    perform cma.set_status(wa, null, v_t2, v_j->'offPlan'->>'market', v_j->'offPlan'->>'code');
    v_j := cma.my_day(null);
    v_b4 := v_b4 || format('; Back to plan: off plan %s, current %s %s', coalesce(v_j->>'offPlan', 'none'), v_j->'current'->>'code', v_j->'current'->>'market');
    ev := cma.set_status(wa, null, now(), 'DE', 'GO');
    v_b4 := v_b4 || format('; again books nothing %s', pg_temp.v0010a_rel(ev.occurred_at) = pg_temp.v0010a_rel(v_t2));

    -- B5: B on GO under SE (the Default market), the absence block at Q-30 ends the day
    perform set_config('app.user_id', v_b::text, true);
    wb := (cma.open_workday(v_qtz - interval '115 minutes')).id;
    perform set_config('app.user_id', v_sch::text, true);
    select string_agg(r.action || ' ' || pg_temp.v0010a_rel(r.occurred_at), ', ') into v_text
    from cma.roster_switch_due(v_qtz - interval '25 minutes') r where r.workday_id = wb;
    perform set_config('role', 'cma_owner', true);
    v_b5 := format('job %s; %s; day %s', coalesce(v_text, 'nothing'), pg_temp.v0010a_events(wb),
                   (select w.status || ' ' || pg_temp.v0010a_rel(w.ended_at) from cma.workday w where w.tenant_id = v_t and w.id = wb));
    perform set_config('role', 'cma_app', true);

    -- B6: C after the shift: the job writes nothing; C's own Switch stays
    perform set_config('app.user_id', v_c::text, true);
    wc := (cma.open_workday(v_qtz - interval '175 minutes')).id;
    perform set_config('app.user_id', v_sch::text, true);
    select string_agg(r.action, ', ') into v_text from cma.roster_switch_due(now()) r where r.workday_id = wc;
    v_b6 := 'job ' || coalesce(v_text, 'nothing');
    perform set_config('app.user_id', v_c::text, true);
    perform cma.set_status(wc, null, v_qtz - interval '30 minutes', 'SE', 'SL');
    perform set_config('app.user_id', v_sch::text, true);
    select string_agg(r.action, ', ') into v_text from cma.roster_switch_due(now()) r where r.workday_id = wc;
    perform set_config('app.user_id', v_c::text, true);
    v_j := cma.my_day(null);
    v_b6 := v_b6 || '; after Switch job ' || coalesce(v_text, 'nothing') || '; ' || pg_temp.v0010a_events(wc)
         || format('; off plan %s; plan now %s', coalesce(v_j->>'offPlan', 'none'), coalesce(v_j->>'planNow', 'none'));

    -- B7: E5's safety net, the refusal of Publish and the wait of a shift just drawn for today
    perform set_config('app.user_id', v_e::text, true);
    we := (cma.open_workday(v_qtz - interval '100 minutes')).id;
    v_b7 := 'fallback ' || pg_temp.v0010a_events(we);
    perform set_config('app.user_id', v_mgr::text, true);
    begin
      perform cma.roster_publish(v_ws, null);
      v_b7 := v_b7 || '; publish accepted';
    exception when sqlstate 'CMA04' then
      get stacked diagnostics v_text = pg_exception_detail;
      select v_b7 || '; publish CMA04 ' || string_agg(case (x->>'userId')::uuid when v_e then 'e' else 'other' end || ' '
                                                      || case when (x->>'date')::date = v_day then 'today' else x->>'date' end, ', ')
        into v_b7 from jsonb_array_elements(substr(v_text, length('empty_shifts=') + 1)::jsonb) x;
    end;
    v_j := cma.roster_set_cell(v_ws, null, v_f, v_day, 'shift', (v_q + interval '60 minutes')::time, (v_q + interval '120 minutes')::time, null);
    v_b7 := v_b7 || format('; a shift just drawn for today: published %s, waiting %s', v_j->>'published', coalesce(v_j->>'waiting', '-'));

    -- B8: the rules (E1, E9, E10)
    perform set_config('app.user_id', v_a::text, true);
    v_b8 := format('SB with a market %s; a market alone on SB %s; ',
      pg_temp.v0010a_try(format('select cma.set_status(%L, null, now(), ''SE'', ''SB'')', wa)),
      (select pg_temp.v0010a_try(format('select cma.set_status(%L, null, now(), null, ''SB''); select cma.set_status(%L, null, now(), ''SE'')', wa, wa))));
    ev := cma.set_status(wa, 'training', now());
    v_b8 := v_b8 || format('Training %s %s; market alone on Training %s; ',
      coalesce((select t.code from cma.assignment_type t where t.id = ev.assignment_type_id), 'no assignment'), coalesce(ev.hours_market_code, 'no market'),
      pg_temp.v0010a_try(format('select cma.set_status(%L, null, now(), ''SE'')', wa)));
    perform cma.set_status(wa, null, now(), 'DE', 'GO');
    perform set_config('role', 'cma_owner', true);
    v_b8 := v_b8 || format('table: SB with a market %s, GO without one %s, an assignment on an end %s; ',
      pg_temp.v0010a_try(format($q$insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source, hours_market_code, assignment_type_id)
                                   select %L, %L, %L, 'status', t.work_status_id, now(), 'user', 'SE', t.id from cma.assignment_type t where t.tenant_id = %L and t.code = 'SB'$q$, v_t, wa, v_a, v_t)),
      pg_temp.v0010a_try(format($q$insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source, hours_market_code, assignment_type_id)
                                   select %L, %L, %L, 'status', t.work_status_id, now(), 'user', null, t.id from cma.assignment_type t where t.tenant_id = %L and t.code = 'GO'$q$, v_t, wa, v_a, v_t)),
      pg_temp.v0010a_try(format($q$insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source, assignment_type_id)
                                   select %L, %L, %L, 'end', null, now(), 'user', t.id from cma.assignment_type t where t.tenant_id = %L and t.code = 'GO'$q$, v_t, wa, v_a, v_t)));
    -- a correction that moves the switch to SL at Q-150 by a minute keeps its assignment
    insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source, supersedes_event_id, reason, approved_by, hours_market_code)
    select v_t, wa, v_a, 'status', x.status_id, x.occurred_at + interval '1 minute', 'correction', x.id, 'verify 0010a', v_mgr, x.hours_market_code
    from cma.time_event x join cma.assignment_type t on t.tenant_id = x.tenant_id and t.id = x.assignment_type_id
    where x.tenant_id = v_t and x.workday_id = wa and t.code = 'SL' and x.source = 'roster'
    returning * into ev;
    v_b8 := v_b8 || format('correction keeps %s %s; ', (select t.code from cma.assignment_type t where t.id = ev.assignment_type_id), ev.hours_market_code);
    perform set_config('role', 'cma_app', true);
    -- the planner, next week: an absence block beside a work block; refusals; E10's market
    perform set_config('app.user_id', v_mgr::text, true);
    perform cma.roster_set_entry(v_ws + 7, null, v_a, v_ws + 7, 'shift', '09:00', '17:00', null, null);
    perform cma.roster_set_entry(v_ws + 7, null, v_f, v_ws + 7, 'shift', '09:00', '17:00', null, null);
    v_b8 := v_b8 || format('planner: absence with a market %s, both kinds %s, unknown absence %s, F without a Default market %s; ',
      pg_temp.v0010a_try(format($q$select cma.roster_set_assignments(%L, null, %L, %L, '[{"absence":"sick","start":"13:00","end":"17:00","hoursMarket":"NL"}]')$q$, v_ws + 7, v_a, v_ws + 7)),
      pg_temp.v0010a_try(format($q$select cma.roster_set_assignments(%L, null, %L, %L, '[{"code":"GO","absence":"sick","start":"13:00","end":"17:00"}]')$q$, v_ws + 7, v_a, v_ws + 7)),
      pg_temp.v0010a_try(format($q$select cma.roster_set_assignments(%L, null, %L, %L, '[{"absence":"nope","start":"13:00","end":"17:00"}]')$q$, v_ws + 7, v_a, v_ws + 7)),
      pg_temp.v0010a_try(format($q$select cma.roster_set_assignments(%L, null, %L, %L, '[{"code":"GO","start":"09:00","end":"17:00"}]')$q$, v_ws + 7, v_f, v_ws + 7)));
    v_j := cma.roster_set_assignments(v_ws + 7, null, v_a, v_ws + 7, '[{"code":"GO","start":"09:00","end":"13:00"},{"absence":"sick","start":"13:00","end":"17:00"}]');
    select v_b8 || 'stored ' || string_agg(coalesce(x->>'code', x->>'absence') || ' ' || (x->>'start') || '-' || (x->>'end') || ' ' || coalesce(x->>'hoursMarket', '-'), ', ')
      into v_b8 from jsonb_array_elements(v_j->'blocks') x;
    perform cma.roster_set_assignments(v_ws + 7, null, v_f, v_ws + 7, '[{"code":"GO","start":"09:00","end":"17:00","hoursMarket":"SE"}]');
    select v_b8 || '; planner reads ' || string_agg(a.kind || ' ' || coalesce(a.code, '-') || ' ' || coalesce(a.absence_key, '-'), ', ' order by a.start_time)
      into v_b8 from cma.roster_assignments(v_ws + 7, null) a where a.user_id = v_a;
    select v_b8 || '; coverage at 14:00 ' || coalesce(string_agg(c.code || '=' || c.people, ', '), 'none')
      into v_b8 from cma.roster_slot_coverage(v_ws + 7, null) c where c.slot_time = '14:00' and c.working > 0;
    perform cma.roster_publish(v_ws + 7, null);
    perform set_config('app.user_id', v_a::text, true);
    select v_b8 || '; the agent sees ' || string_agg((x->>'kind') || ' ' || coalesce(x->>'code', x->>'absenceKey') || ' ' || coalesce(x->>'hoursMarket', '-'), ', ')
      into v_b8 from cma.my_roster(v_ws + 7, v_ws + 7) m cross join lateral jsonb_array_elements(m.assignments) x;

    -- B9: my_hours and the job for all tenants
    v_j := cma.my_hours(v_ws);
    select format('rows %s; pauses %s; today split %s; planned %s; worked = rows %s',
      (select string_agg(coalesce(r->>'code', r->>'name') || ' ' || coalesce(r->>'market', '-'), ', '
                         order by coalesce(r->>'code', r->>'name') collate "C", r->>'market' collate "C")
       from jsonb_array_elements(v_j->'rows') r),
      (select string_agg(coalesce(r->>'code', r->>'name'), ', ' order by coalesce(r->>'code', r->>'name') collate "C") from jsonb_array_elements(v_j->'pauses') r),
      (select string_agg(coalesce(s->>'code', s->>'name') || ' ' || coalesce(s->>'market', '-'), ', ')
       from jsonb_array_elements(v_j->'days') d cross join lateral jsonb_array_elements(d->'split') s where (d->>'isToday')::boolean),
      v_j->>'plannedMinutes',
      (v_j->>'workedSeconds')::bigint = (select sum((r->>'seconds')::bigint) from jsonb_array_elements(v_j->'rows') r))
      into v_b9;
    v_b9 := v_b9 || format('; all tenants inside a request %s', pg_temp.v0010a_try('select count(*) from cma.roster_switch_all(now())'));

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then v_err := sqlstate || ': ' || left(sqlerrm, 300);
      perform set_config('role', 'cma_owner', true);
      insert into pg_temp.verify_0010a values (10, 'B the throwaway tenant''s checks ran to their end', 'FAIL', v_err);
  end;
  perform set_config('role', 'cma_owner', true);
  perform set_config('app.tenant_id', '', true);
  perform set_config('app.user_id', '', true);
  -- the job for all tenants, outside a request, for a minute in 2000: no workday is due, nothing is written
  begin
    select coalesce(string_agg(distinct r.action, ', '), 'nothing') into v_text
    from cma.roster_switch_all('2000-01-03 12:00+00') r;
    v_b9 := v_b9 || format('; outside a request %s, tenant left %s', v_text, coalesce(nullif(current_setting('app.tenant_id', true), ''), 'none'));
  exception when others then
    v_b9 := v_b9 || '; outside a request ' || sqlstate;
  end;
  perform set_config('app.tenant_id', '', true);
  perform set_config('app.user_id', '', true);
  perform set_config('app.actor_label', '', true);

  perform pg_temp.v0010a_row(11, 'B1', 'a late Clock in starts on the block of that moment with its market (E4)',
    v_b1, 'Q-170 MC SE user');
  perform pg_temp.v0010a_row(12, 'B2', 'the roster switches at each boundary, once, a pause without a market (E2)',
    v_b2, 'Q-149 switched SL Q-150; again nothing; Q-59 switched SB Q-60; Q-44 switched GO Q-45; '
          || 'Q-170 MC SE user, Q-150 SL SE roster, Q-60 SB - roster, Q-45 GO SE roster');
  perform pg_temp.v0010a_row(13, 'B3', 'an own Switch stands until the next boundary and is marked as a deviation (E6, E7)',
    v_b3, 'Q-30 nothing; marks Q-40 CC SE (planned GO SE); deviating stretches CC; now switched GO Q+0');
  perform pg_temp.v0010a_row(14, 'B4', 'the notice of a roster switch, Off plan and Back to plan (E3, E7)',
    v_b4, 'notice Q+0 GO DE Q+20; current GO DE roster; off plan none; after Switch: notice none; off plan GO DE General Ops since Q+0, next LB - at Q+45; '
          || 'Back to plan: off plan none, current GO DE; again books nothing t');
  perform pg_temp.v0010a_row(15, 'B5', 'an absence block ends the workday at its start, source roster (E9)',
    v_b5, 'job ended Q-30; Q-115 GO SE user, Q-30 end roster; day ended Q-30');
  perform pg_temp.v0010a_row(16, 'B6', 'after the shift nothing switches; the agent stays on what they chose (E8)',
    v_b6, 'job nothing; after Switch job nothing; Q-175 GO NL user, Q-30 SL SE user; off plan none; plan now none');
  perform pg_temp.v0010a_row(17, 'B7', 'the safety net, the refusal of Publish, a shift of today waits for its blocks (E5)',
    v_b7, 'fallback Q-100 meeting DE user; publish CMA04 e today; a shift just drawn for today: published false, waiting no_assignments');
  perform pg_temp.v0010a_row(18, 'B8', 'the rules of the events and of the blocks (E1, E9, E10)',
    v_b8, 'SB with a market CMA04; a market alone on SB CMA04; Training no assignment no market; market alone on Training CMA04; '
          || 'table: SB with a market CMA04, GO without one CMA04, an assignment on an end CMA04; correction keeps SL SE; '
          || 'planner: absence with a market CMA04, both kinds CMA04, unknown absence CMA02, F without a Default market CMA04; '
          || 'stored GO 09:00-13:00 NL, sick 13:00-17:00 -; planner reads work GO -, absence - sick; coverage at 14:00 GO=1; '
          || 'the agent sees work GO NL, absence sick -');
  perform pg_temp.v0010a_row(19, 'B9', 'My hours per assignment and market; the job for all tenants only outside a request',
    v_b9, 'rows CC SE, GO DE, GO SE, MC SE, SL SE, Training -; pauses SB; today split MC SE, SL SE, GO SE, CC SE, GO DE, Training -; planned 315; worked = rows t; '
          || 'all tenants inside a request CMA06; outside a request nothing, tenant left none');
end
$$;

-- ---------------------------------------------------------------------------------------------
-- R. Every active tenant as it is
-- ---------------------------------------------------------------------------------------------
do $$
declare
  t      record;
  r      record;
  v_any  boolean := false;
  v_o    integer;
  v_n1   integer; v_n2 integer; v_n3 integer; v_n4 integer;
  v_d3   text; v_d4 text;
begin
  for t in select id, slug from cma.tenant where status = 'active' order by slug collate "C" loop
    v_any := true;
    perform set_config('app.tenant_id', t.id::text, true);
    -- R1
    select count(*) into v_n1
    from cma.roster_assignment a
    join cma.assignment_type ty on ty.tenant_id = a.tenant_id and ty.id = a.assignment_type_id
    join cma.app_user u on u.tenant_id = a.tenant_id and u.id = a.user_id
    where a.tenant_id = t.id and ty.kind = 'work' and a.hours_market_code is null and cma.is_hours_market(u.default_hours_market_code);
    perform pg_temp.v0010a_row(30, 'R1', t.slug || ': no work block without a market whose person has a Default market',
      v_n1::text, case when pg_temp.v0010a_p('R1') then (v_n1 + 1)::text else '0' end);
    -- R2
    select count(*) into v_n2
    from cma.time_event e
    join cma.assignment_type ty on ty.tenant_id = e.tenant_id and ty.id = e.assignment_type_id
    left join cma.work_status s on s.tenant_id = e.tenant_id and s.id = e.status_id
    where e.tenant_id = t.id
      and (e.kind not in ('start', 'status')
           or (not ty.is_extra and e.status_id is distinct from ty.work_status_id)
           or (ty.is_extra and not coalesce(s.is_working, false))
           or (ty.kind = 'pause' and e.hours_market_code is not null)
           or (ty.kind = 'work' and e.hours_market_code is null));
    perform pg_temp.v0010a_row(31, 'R2', t.slug || ': every event with an assignment keeps E1''s rule',
      v_n2::text, case when pg_temp.v0010a_p('R2') then (v_n2 + 1)::text else '0' end);
    -- R3 and R4: this week and next, every person-date with a published or a current block
    v_o := case when pg_temp.v0010a_p('R3') then 1 else 0 end;
    v_n3 := 0; v_d3 := '';
    for r in
      select distinct a.roster_week_id, a.user_id, a.business_date
      from cma.roster_published_assignment a
      where a.business_date between cma.week_start(current_date) and cma.week_start(current_date) + 13
    loop
      v_n3 := v_n3 + 1;
      if (select coalesce(jsonb_agg(x - 'absenceKey'), '[]'::jsonb) from jsonb_array_elements(cma.roster_published_blocks_json(r.roster_week_id, r.user_id, r.business_date)) x
          where x->>'kind' <> 'absence')
         is distinct from
         (select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_array_elements(pg_temp.v0010a_published_0009zz(r.roster_week_id, r.user_id, r.business_date)) with ordinality o(x, n)
          where n > v_o) then
        v_d3 := v_d3 || r.business_date || ' ';
      end if;
    end loop;
    insert into pg_temp.verify_0010a values (32, 'R3 ' || t.slug || ': roster_published_blocks_json = 252''s for every block not an absence',
      case when btrim(v_d3) <> '' or (v_o = 1 and v_n3 = 0) then 'FAIL' else 'PASS' end,
      format('person-dates %s; differing %s', v_n3, coalesce(nullif(btrim(v_d3), ''), 'none')));
    v_o := case when pg_temp.v0010a_p('R4') then 1 else 0 end;
    v_n4 := 0; v_d4 := '';
    for r in
      select distinct a.user_id, a.business_date
      from cma.roster_assignment a
      where a.tenant_id = t.id and a.valid_to is null
        and a.business_date between cma.week_start(current_date) and cma.week_start(current_date) + 13
    loop
      v_n4 := v_n4 + 1;
      if (select coalesce(jsonb_agg(x - 'absence' - 'absenceName'), '[]'::jsonb) from jsonb_array_elements(cma.roster_blocks_json(r.user_id, r.business_date)) x
          where x->>'absence' is null)
         is distinct from
         (select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_array_elements(pg_temp.v0010a_blocks_0009zz(r.user_id, r.business_date)) with ordinality o(x, n)
          where n > v_o) then
        v_d4 := v_d4 || r.business_date || ' ';
      end if;
    end loop;
    insert into pg_temp.verify_0010a values (33, 'R4 ' || t.slug || ': roster_blocks_json = 252''s for every block not an absence',
      case when btrim(v_d4) <> '' or (v_o = 1 and v_n4 = 0) then 'FAIL' else 'PASS' end,
      format('person-dates %s; differing %s', v_n4, coalesce(nullif(btrim(v_d4), ''), 'none')));
  end loop;
  perform set_config('app.tenant_id', '', true);
  if not v_any then
    insert into pg_temp.verify_0010a values (30, 'R1 to R4 per tenant',
      case when current_setting('verify.provoke') <> 'false' then 'FAIL' else 'skip' end, 'no active tenant');
  end if;
end
$$;

drop function if exists pg_temp.v0010a_published_0009zz(uuid, uuid, date);
drop function if exists pg_temp.v0010a_blocks_0009zz(uuid, date);
drop function if exists pg_temp.v0010a_events(uuid);
drop function if exists pg_temp.v0010a_rel(timestamptz);
drop function if exists pg_temp.v0010a_try(text);
drop function if exists pg_temp.v0010a_row(integer, text, text, text, text);
drop function if exists pg_temp.v0010a_p(text);

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0010a
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke') <> 'false' then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0010a where result = 'FAIL') then 'FAIL'
                  when not exists (select 1 from pg_temp.verify_0010a where result = 'PASS') then 'FAIL'
                  else 'PASS' end,
             format('255_verify_roster_drives_the_day: %s PASS, %s FAIL, %s skip', (select count(*) from pg_temp.verify_0010a where result = 'PASS'),
                    (select count(*) from pg_temp.verify_0010a where result = 'FAIL'), (select count(*) from pg_temp.verify_0010a where result = 'skip'))) x
order by ord, check_name collate "C";
drop table if exists pg_temp.verify_0010a;
reset role;
