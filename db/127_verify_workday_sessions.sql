-- =============================================================================================
-- 127_verify_workday_sessions.sql: verifies addition 0008zp, split shifts: clock in again on the same day
-- =============================================================================================
-- Universal: no seed is assumed. The people are synthetic (example.invalid), the statuses are picked by flag, and every
-- instant lies on Tuesday 10 March 2026 in Europe/Amsterdam (the workday window 07:00 to 22:00, set on the throwaway
-- tenant), so the verdict never depends on the time it runs. Block S checks the addition and the grants; blocks A1 to A10
-- each work on a throwaway tenant inside a subtransaction that is always rolled back, so nothing stays and the script
-- runs in dev and in prod. Cloud SQL Studio shows no notices: a check that fails raises "FAIL …" and stops its block;
-- every check that passed writes one row, and the last row is the verdict: "PASS | 30 PASS, 0 FAIL" (provoked:
-- "PROVOKED, NOT A PASS | 0 PASS, 30 FAIL"). A block that stopped
-- counts its checks as FAIL. Run as your own IAM login after 126_workday_sessions.sql, dev first, then prod; then 07
-- (block C), 10, 18, 20, 47, 51 and 111 again (unchanged, still PASS).
--   S1  the addition 0008zp is recorded after 0008zn; the setting workday.clock_in_again exists, boolean, default false;
--       cma.workday_can_clock_in_again is a stable invoker function executable by cma_app only; open_workday's definition
--       calls it under a lock; refresh_workday's names the session rules
--   A1  setting off: open 09:00, end 13:00 (the person's own), open 17:00: the day stays ended with one start
--   A2  setting on: the same opens the day again (started_at 09:00, ended_at null, two starts); an end at 21:00 ends it;
--       worked 4 h + 4 h; the gap 13:00 to 17:00 in no stretch; no pause; the status-changes export without the gap; the
--       hours export 09:00 to 21:00 with 8 h worked; time per status and the day's events; nobody clocked in during the gap
--   A3  a third session 21:30 to 21:50, counted
--   A4  after the window end (22:00 and 22:05), at the end's own instant and before it: unchanged
--   A5  not resumable: a day the scheduler closed, an end set by a correction, a day added by a correction, an imported
--       day (a one-day batch as 111 loads it), a person whose time is no longer kept, another date, another tenant: each
--       unchanged, nothing written
--   A6  cma.workday_can_clock_in_again agrees with cma.open_workday in every case of A1 to A5 (one row per block)
--   A7  corrections on a two-session day by a supervisor: the second start moved; the first end and the second start
--       voided (one session, valid); a status between an end and the next start, two ends in a row, a start at the end's
--       own instant and a start while a session is open are CMA04 with the rule named and nothing written; Add day with
--       two sessions
--   A8  the sweep: an open later session closed by the rule (the published shift end, workday.auto_close_at, the day's
--       last event: never before the session's start), flagged for review, one notice per person and one digest
--   A9  regression: a one-session day with pauses gives the summary it gave before (hand-computed); one tie changed: a
--       status recorded after an end at the end's own instant is refused now (it was counted to the window end)
--   A10 a second Clock in on a day just clocked in again (the same instant, a minute later) adds no second start; two
--       concurrent sessions need two connections and are proven outside this script (docs/night-2026-11-04)
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

drop table if exists pg_temp.verify_0008zp;
create temp table verify_0008zp (ord int, check_name text, result text, detail text);

-- An instant on the fixed date (or another) in the tenant's zone
create or replace function pg_temp.v0008zp_at(p_time text, p_date date default date '2026-03-10')
returns timestamptz
language sql stable
as $$
  select (p_date + p_time::time) at time zone 'Europe/Amsterdam'
$$;

-- A throwaway tenant: an admin, a manager, a supervisor, six agents and the tenant's scheduler; the window 07:00 to 22:00,
-- 17:00 and an hour's grace, workday.clock_in_again as asked; the statuses picked by flag. Its ids as jsonb.
create or replace function pg_temp.v0008zp_tenant(p_slug text, p_again boolean)
returns jsonb
language plpgsql
as $$
declare
  v_t  uuid;
  v_id uuid;
  v    jsonb;
  r    record;
begin
  v_t := cma.create_tenant(p_slug, 'Verify 0008zp', 'Europe/Amsterdam');
  v := jsonb_build_object('t', v_t);
  for r in select * from (values ('admin', 'admin'), ('mgr', 'manager'), ('sup', 'supervisor'), ('p1', 'agent'), ('p2', 'agent'),
                                 ('p3', 'agent'), ('p4', 'agent'), ('p5', 'agent'), ('p6', 'agent')) as x(name, role_key) loop
    insert into cma.app_user (tenant_id, email, display_name)
    values (v_t, format('verify-%s@example.invalid', r.name), r.name) returning id into v_id;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t, v_id, ar.id from cma.app_role ar where ar.tenant_id = v_t and ar.key = r.role_key;
    v := v || jsonb_build_object(r.name, v_id);
  end loop;
  v := v || jsonb_build_object('sched', (select u.id from cma.app_user u where u.tenant_id = v_t and u.kind = 'system'
                                                                          and u.email = 'scheduler@system.invalid'));
  insert into cma.tenant_setting (tenant_id, key, value)
  select v_t, s.key, s.value
  from (values (1, 'workday.window_start', '07:00'), (2, 'workday.window_end', '22:00'), (3, 'workday.auto_close_at', '17:00'),
               (4, 'workday.auto_close_grace_minutes', '60'), (5, 'workday.clock_in_again', p_again::text)) as s(ord, key, value)
  order by s.ord;
  v := v || jsonb_build_object(
    'default',      (select s.key from cma.work_status s where s.tenant_id = v_t and s.is_default and s.status = 'active'),
    'other_work',   (select s.key from cma.work_status s where s.tenant_id = v_t and s.status = 'active' and s.is_working
                       and not s.is_default order by s.sort_order, s.key limit 1),
    'pause_paid',   (select s.key from cma.work_status s where s.tenant_id = v_t and s.status = 'active' and not s.is_working
                       and s.is_paid order by s.sort_order, s.key limit 1),
    'pause_unpaid', (select s.key from cma.work_status s where s.tenant_id = v_t and s.status = 'active' and not s.is_working
                       and not s.is_paid order by s.sort_order, s.key limit 1));
  if v ->> 'sched' is null or v ->> 'default' is null or v ->> 'other_work' is null or v ->> 'pause_paid' is null
     or v ->> 'pause_unpaid' is null then
    raise exception 'FAIL setup: the throwaway tenant lacks the scheduler or a status by flag (%)', v;
  end if;
  return v;
end
$$;

-- The acting context inside a block: the application, the tenant, a person
create or replace function pg_temp.v0008zp_as(x jsonb, p_who text)
returns void
language sql
as $$
  select set_config('role', 'cma_app', true), set_config('app.tenant_id', x ->> 't', true),
         set_config('app.user_id', x ->> p_who, true), set_config('app.actor_label', '', true);
$$;

-- One person's day on the fixed date, read as the application
create or replace function pg_temp.v0008zp_day(x jsonb, p_who text, p_date date default date '2026-03-10')
returns cma.workday
language sql stable
as $$
  select w.* from cma.workday w where w.tenant_id = (x ->> 't')::uuid and w.user_id = (x ->> p_who)::uuid and w.business_date = p_date
$$;

-- The effective starts of a day
create or replace function pg_temp.v0008zp_starts(p_workday uuid)
returns bigint
language sql stable
as $$
  select count(*) from cma.time_event_effective e where e.workday_id = p_workday and e.kind = 'start'
$$;

-- S1. The addition, the setting, the function and its grants (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_fn      text := 'cma.workday_can_clock_in_again(uuid,timestamptz)';
  s         cma.setting;
begin
  select * into s from cma.setting where key = 'workday.clock_in_again';
  if not exists (select 1 from cma.schema_migration where version = '0008zp') or v_provoke
     or not exists (select 1 from cma.schema_migration where version = '0008zn') then
    raise exception 'FAIL S1: addition 0008zp not recorded after 0008zn';
  end if;
  if s.key is null or s.value_type <> 'boolean' or s.default_value <> 'false' or s.allowed_values is not null then
    raise exception 'FAIL S1: the setting workday.clock_in_again is not a boolean defaulting to false (%)', s;
  end if;
  if to_regprocedure(v_fn) is null
     or (select p.prosecdef or p.provolatile <> 's' from pg_proc p where p.oid = to_regprocedure(v_fn))
     or not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
     or exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                where p.oid = to_regprocedure(v_fn) and a.grantee = 0) then
    raise exception 'FAIL S1: % is not a stable invoker function for cma_app only', v_fn;
  end if;
  if pg_get_functiondef(to_regprocedure('cma.open_workday(timestamptz)')) not like '%workday_can_clock_in_again%for update%workday_can_clock_in_again%'
     or pg_get_functiondef(to_regprocedure('cma.refresh_workday(uuid)')) not like '%two clock-outs without a clock-in between them%'
     or pg_get_functiondef(to_regprocedure('cma.refresh_workday(uuid)')) not like '%between a clock-out and the next clock-in%' then
    raise exception 'FAIL S1: open_workday or refresh_workday is not the 0008zp definition';
  end if;
  insert into verify_0008zp values (1, 'S1 addition, setting, rule function and grants', 'PASS',
    'workday.clock_in_again boolean false; invoker, stable, cma_app only; open_workday rechecks under a lock');
end
$$;

-- A1. The setting off: today's behaviour
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  x         jsonb;
  w         cma.workday;
  v_can     boolean;
  v_n       bigint;
begin
  begin
    x := pg_temp.v0008zp_tenant('verify-0008zp-a1', false);
    perform pg_temp.v0008zp_as(x, 'p1');
    w := cma.open_workday(pg_temp.v0008zp_at('09:00'));
    w := cma.end_workday(w.id, pg_temp.v0008zp_at('13:00'));
    v_can := cma.workday_can_clock_in_again(w.id, pg_temp.v0008zp_at('17:00'));
    select count(*) into v_n from cma.time_event;
    w := cma.open_workday(pg_temp.v0008zp_at('17:00'));
    if w.status <> 'ended' or w.ended_at <> pg_temp.v0008zp_at('13:00') or pg_temp.v0008zp_starts(w.id) <> 1
       or (select count(*) from cma.time_event) <> v_n or v_provoke then
      raise exception 'FAIL A1: with the setting off a Clock in on an ended day gave % (% starts)', w.status, pg_temp.v0008zp_starts(w.id);
    end if;
    v_rows := v_rows || array['10', 'A1 setting off: an ended day stays ended', 'PASS', 'ended 13:00, one start, nothing written'];
    if v_can then
      raise exception 'FAIL A6 (A1): workday_can_clock_in_again said true where open_workday wrote nothing';
    end if;
    v_rows := v_rows || array['11', 'A6 the rule agrees with Clock in (A1)', 'PASS', 'false, nothing written'];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
  insert into verify_0008zp select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
end
$$;

-- A2 and A3. The setting on: two sessions, then a third
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  x         jsonb;
  w         cma.workday;
  s         record;
  v_can     boolean;
  v_txt     text;
begin
  begin
    x := pg_temp.v0008zp_tenant('verify-0008zp-a2', true);
    perform pg_temp.v0008zp_as(x, 'p1');
    w := cma.open_workday(pg_temp.v0008zp_at('09:00'));
    w := cma.end_workday(w.id, pg_temp.v0008zp_at('13:00'));
    -- nobody is clocked in during the gap
    if cma.is_clocked_in((x ->> 'p1')::uuid) or v_provoke then
      raise exception 'FAIL A2: the person counts as clocked in after their log out';
    end if;
    v_can := cma.workday_can_clock_in_again(w.id, pg_temp.v0008zp_at('17:00'));
    w := cma.open_workday(pg_temp.v0008zp_at('17:00'));
    if w.status <> 'open' or w.started_at <> pg_temp.v0008zp_at('09:00') or w.ended_at is not null
       or pg_temp.v0008zp_starts(w.id) <> 2 or not cma.is_clocked_in((x ->> 'p1')::uuid) then
      raise exception 'FAIL A2: Clock in again gave % from % to % with % starts', w.status, w.started_at, w.ended_at, pg_temp.v0008zp_starts(w.id);
    end if;
    v_rows := v_rows || array['20', 'A2 Clock in again opens the day', 'PASS', 'open, started 09:00, two starts; not clocked in during the gap'];
    if not v_can then
      raise exception 'FAIL A6 (A2): workday_can_clock_in_again said false where open_workday wrote a start';
    end if;
    v_rows := v_rows || array['21', 'A6 the rule agrees with Clock in (A2)', 'PASS', 'true, a start written'];
    if (select e.source || ':' || ws.key from cma.time_event_effective e join cma.work_status ws on ws.id = e.status_id
        where e.workday_id = w.id and e.kind = 'start' order by e.occurred_at desc limit 1) <> 'user:' || (x ->> 'default') then
      raise exception 'FAIL A2: the new session does not start in the default status by the person';
    end if;
    v_rows := v_rows || array['22', 'A2 the new session starts in the default status', 'PASS', 'source user, the default status'];

    w := cma.end_workday(w.id, pg_temp.v0008zp_at('21:00'));
    select * into s from cma.workday_summary where workday_id = w.id;
    if w.status <> 'ended' or w.ended_at <> pg_temp.v0008zp_at('21:00') or s.started_at <> pg_temp.v0008zp_at('09:00')
       or s.working_seconds <> 28800 or s.is_capped or s.needs_correction or s.has_correction then
      raise exception 'FAIL A2: the two-session day reads % to %, % worked', s.started_at, s.ended_at, s.working_seconds;
    end if;
    v_rows := v_rows || array['23', 'A2 the day: first start, last end, 4 h + 4 h', 'PASS', '09:00 to 21:00, 28800 s worked, not flagged'];
    if exists (select 1 from cma.time_interval i where i.workday_id = w.id
               and i.from_at < pg_temp.v0008zp_at('17:00') and coalesce(i.to_at, 'infinity') > pg_temp.v0008zp_at('13:00'))
       or (select count(*) from cma.time_interval i where i.workday_id = w.id) <> 2
       or (select coalesce(sum(i.seconds), 0) from cma.time_interval i join cma.work_status ws on ws.id = i.status_id
           where i.workday_id = w.id and not ws.is_working) <> 0 then
      raise exception 'FAIL A2: the gap 13:00 to 17:00 is counted (a stretch or a pause)';
    end if;
    v_rows := v_rows || array['24', 'A2 the gap is in no stretch and no pause', 'PASS', 'two stretches, 0 s paused'];

    perform pg_temp.v0008zp_as(x, 'mgr');
    select string_agg(to_char(r.from_at at time zone 'Europe/Amsterdam', 'HH24:MI') || '-' || to_char(r.to_at at time zone 'Europe/Amsterdam', 'HH24:MI')
                      || ':' || r.seconds || ':' || r.source, ' ' order by r.from_at) into v_txt
    from cma.export_status_changes(date '2026-03-10', date '2026-03-10', (x ->> 'p1')::uuid) r;
    if v_txt is distinct from '09:00-13:00:14400:user 17:00-21:00:14400:user' then
      raise exception 'FAIL A2: the status-changes export reads [%]', v_txt;
    end if;
    v_rows := v_rows || array['25', 'A2 the status-changes export: one row per stretch, no gap', 'PASS', v_txt];
    select string_agg(to_char(r.started_at at time zone 'Europe/Amsterdam', 'HH24:MI') || '-' || to_char(r.ended_at at time zone 'Europe/Amsterdam', 'HH24:MI')
                      || ':' || r.working_seconds || ':' || r.status, ' ') into v_txt
    from cma.export_hours(date '2026-03-10', date '2026-03-10', (x ->> 'p1')::uuid) r;
    if v_txt is distinct from '09:00-21:00:28800:ended' then
      raise exception 'FAIL A2: the hours export reads [%]', v_txt;
    end if;
    v_rows := v_rows || array['26', 'A2 the hours export: first start, last end, the gap not worked', 'PASS', v_txt];
    perform pg_temp.v0008zp_as(x, 'sup');
    select string_agg(r.status_key || ':' || r.seconds || ':' || r.stretches, ' ') into v_txt
    from cma.team_status_time(date '2026-03-10', date '2026-03-10', (x ->> 'p1')::uuid) r;
    if v_txt is distinct from (x ->> 'default') || ':28800:2'
       or (select string_agg(d.kind, ',' order by d.occurred_at, d.recorded_at) from cma.team_day((x ->> 'p1')::uuid, date '2026-03-10') d
           where d.is_effective) <> 'start,end,start,end'
       or (select h.working_seconds from cma.team_hours(date '2026-03-10', date '2026-03-10', (x ->> 'p1')::uuid) h) <> 28800 then
      raise exception 'FAIL A2: time per status, the day''s events or Team hours read [%]', v_txt;
    end if;
    v_rows := v_rows || array['27', 'A2 time per status, the day''s events, Team hours', 'PASS', v_txt || '; start,end,start,end'];

    -- A3. a third session, 21:30 to 21:50
    perform pg_temp.v0008zp_as(x, 'p1');
    w := cma.open_workday(pg_temp.v0008zp_at('21:30'));
    w := cma.end_workday(w.id, pg_temp.v0008zp_at('21:50'));
    if w.status <> 'ended' or pg_temp.v0008zp_starts(w.id) <> 3 or w.ended_at <> pg_temp.v0008zp_at('21:50')
       or (select s2.working_seconds from cma.workday_summary s2 where s2.workday_id = w.id) <> 30000 then
      raise exception 'FAIL A3: a third session gave % with % starts', w.status, pg_temp.v0008zp_starts(w.id);
    end if;
    v_rows := v_rows || array['30', 'A3 a third session, counted', 'PASS', 'three starts, 30000 s worked, ended 21:50'];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
  insert into verify_0008zp select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
end
$$;

-- A4. Outside the window, at and before the end's own instant
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  x         jsonb;
  w         cma.workday;
  r         record;
  v_n       bigint;
  v_agree   int := 0;
begin
  begin
    x := pg_temp.v0008zp_tenant('verify-0008zp-a4', true);
    perform pg_temp.v0008zp_as(x, 'p1');
    w := cma.open_workday(pg_temp.v0008zp_at('09:00'));
    w := cma.end_workday(w.id, pg_temp.v0008zp_at('13:00'));
    perform pg_temp.v0008zp_as(x, 'p2');
    w := cma.open_workday(pg_temp.v0008zp_at('09:00'));
    w := cma.end_workday(w.id, pg_temp.v0008zp_at('21:58'));
    for r in select * from (values ('p1', '13:00', 'the end''s own instant'), ('p1', '12:59', 'before the end'),
                                   ('p2', '22:00', 'the window end'), ('p2', '22:05', 'after the window end')) as c(who, at, what) loop
      perform pg_temp.v0008zp_as(x, r.who);
      w := pg_temp.v0008zp_day(x, r.who);
      select count(*) into v_n from cma.time_event;
      if cma.workday_can_clock_in_again(w.id, pg_temp.v0008zp_at(r.at)) then
        raise exception 'FAIL A6 (A4): workday_can_clock_in_again said true at % (%)', r.at, r.what;
      end if;
      v_agree := v_agree + 1;
      w := cma.open_workday(pg_temp.v0008zp_at(r.at));
      if w.status <> 'ended' or pg_temp.v0008zp_starts(w.id) <> 1 or (select count(*) from cma.time_event) <> v_n or v_provoke then
        raise exception 'FAIL A4: a Clock in at % (%) gave % with % starts', r.at, r.what, w.status, pg_temp.v0008zp_starts(w.id);
      end if;
    end loop;
    v_rows := v_rows || array['40', 'A4 outside the window, at or before the end: unchanged', 'PASS', '13:00, 12:59, 22:00, 22:05: ended, nothing written'];
    v_rows := v_rows || array['41', 'A6 the rule agrees with Clock in (A4)', 'PASS', v_agree || ' cases false, nothing written'];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
  insert into verify_0008zp select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
end
$$;

-- A5. Days that are not resumable
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  x         jsonb;
  w         cma.workday;
  w2        cma.workday;
  b         cma.import_batch;
  r         record;
  v_t2      uuid;
  v_end     uuid;
  v_n       bigint;
  v_agree   int := 0;
begin
  begin
    x := pg_temp.v0008zp_tenant('verify-0008zp-a5', true);
    v_t2 := cma.create_tenant('verify-0008zp-a5-two', 'Verify 0008zp two', 'Europe/Amsterdam');

    -- a day the scheduler closed (source system): p2 clocked in at 09:00 and never out, closed at 17:00
    perform pg_temp.v0008zp_as(x, 'p2');
    perform cma.open_workday(pg_temp.v0008zp_at('09:00'));
    perform pg_temp.v0008zp_as(x, 'sched');
    if (select count(*) from cma.close_forgotten_workdays()) <> 1 or v_provoke then
      raise exception 'FAIL A5: the scheduler did not close the one forgotten day';
    end if;
    -- an end set by a correction: p3 out at 12:00, the supervisor moved it to 12:30
    perform pg_temp.v0008zp_as(x, 'p3');
    w := cma.open_workday(pg_temp.v0008zp_at('09:00'));
    w := cma.end_workday(w.id, pg_temp.v0008zp_at('12:00'));
    select e.id into v_end from cma.time_event_effective e where e.workday_id = w.id and e.kind = 'end';
    perform pg_temp.v0008zp_as(x, 'sup');
    perform cma.correct_workday((x ->> 'p3')::uuid, date '2026-03-10', jsonb_build_array(
      jsonb_build_object('kind', 'end', 'supersedes', v_end, 'at', '2026-03-10T12:30:00+01:00')), 'verify 0008zp an end moved');
    -- a day added by a correction: p6, 09:00 to 12:00
    perform cma.correct_workday((x ->> 'p6')::uuid, date '2026-03-10', jsonb_build_array(
      jsonb_build_object('kind', 'start', 'statusKey', x ->> 'default', 'at', '2026-03-10T09:00:00+01:00'),
      jsonb_build_object('kind', 'end', 'at', '2026-03-10T12:00:00+01:00')), 'verify 0008zp Add day');
    -- an imported day: p4, 09:00 to 12:00, one batch loaded as 111 loads it
    perform pg_temp.v0008zp_as(x, 'admin');
    perform cma.upsert_work_status('verify_import', 'Verify import', true, true, true, true, 900);
    perform cma.retire_work_status('verify_import');
    b := cma.stage_import_batch('verify-0008zp', 'verify_source', 'verify.csv', date '2026-03-09', date '2026-03-13',
                                'Europe/Amsterdam', 'verify_import', x ->> 'pause_unpaid');
    insert into cma.import_session_staging (batch_key, external_person_id, external_session_id, login_local, logout_local)
    values ('verify-0008zp', 'A4', 's01', '2026-03-10 09:00:00', '2026-03-10 12:00:00');
    insert into cma.import_person_map (batch_id, external_person_id, user_id) values (b.id, 'A4', (x ->> 'p4')::uuid);
    b := cma.load_import_batch('verify-0008zp');
    if b.status <> 'loaded' or (b.counts ->> 'days_written')::int <> 1 then
      raise exception 'FAIL A5: the one-day batch gave % with %', b.status, b.counts;
    end if;
    -- a person whose time is no longer kept: p5 out at 12:00, then the role taken away
    perform pg_temp.v0008zp_as(x, 'p5');
    w := cma.open_workday(pg_temp.v0008zp_at('09:00'));
    w := cma.end_workday(w.id, pg_temp.v0008zp_at('12:00'));
    perform set_config('role', 'cma_owner', true);
    delete from cma.user_role where tenant_id = (x ->> 't')::uuid and user_id = (x ->> 'p5')::uuid;
    -- another date: p1 out at 12:00 on the 10th
    perform pg_temp.v0008zp_as(x, 'p1');
    w := cma.open_workday(pg_temp.v0008zp_at('09:00'));
    w := cma.end_workday(w.id, pg_temp.v0008zp_at('12:00'));

    for r in select * from (values ('p2', '18:00', 'the scheduler''s end'), ('p3', '14:00', 'an end set by a correction'),
                                   ('p6', '14:00', 'a day added by a correction'), ('p4', '14:00', 'an imported day'),
                                   ('p5', '14:00', 'time no longer kept')) as c(who, at, what) loop
      perform pg_temp.v0008zp_as(x, r.who);
      w := pg_temp.v0008zp_day(x, r.who);
      select count(*) into v_n from cma.time_event;
      if w.id is null or w.status <> 'ended' or cma.workday_can_clock_in_again(w.id, pg_temp.v0008zp_at(r.at)) then
        raise exception 'FAIL A6 (A5): workday_can_clock_in_again said true for % (day %)', r.what, w.status;
      end if;
      v_agree := v_agree + 1;
      w2 := cma.open_workday(pg_temp.v0008zp_at(r.at));
      if w2.id <> w.id or w2.status <> 'ended' or w2.ended_at <> w.ended_at or pg_temp.v0008zp_starts(w.id) <> 1
         or (select count(*) from cma.time_event) <> v_n then
        raise exception 'FAIL A5: a Clock in on % gave % with % starts', r.what, w2.status, pg_temp.v0008zp_starts(w.id);
      end if;
    end loop;
    v_rows := v_rows || array['50', 'A5 the scheduler''s, a correction''s, Add day''s and an import''s end: unchanged', 'PASS',
                              'each ended, one start, nothing written'];
    v_rows := v_rows || array['51', 'A5 a person whose time is no longer kept: unchanged', 'PASS', 'ended, nothing written'];

    -- another date: the 10th's day is not resumed on the 11th; a Clock in there opens the 11th's own day
    perform pg_temp.v0008zp_as(x, 'p1');
    w := pg_temp.v0008zp_day(x, 'p1');
    if cma.workday_can_clock_in_again(w.id, pg_temp.v0008zp_at('07:30', date '2026-03-11')) then
      raise exception 'FAIL A6 (A5): workday_can_clock_in_again said true on another date';
    end if;
    v_agree := v_agree + 1;
    w2 := cma.open_workday(pg_temp.v0008zp_at('07:30', date '2026-03-11'));
    if w2.id = w.id or w2.business_date <> date '2026-03-11' or w2.status <> 'open'
       or (select d.status from cma.workday d where d.id = w.id) <> 'ended' or pg_temp.v0008zp_starts(w.id) <> 1 then
      raise exception 'FAIL A5: a Clock in on the 11th touched the 10th''s day';
    end if;
    v_rows := v_rows || array['52', 'A5 another date: the earlier day unchanged', 'PASS', 'the 11th opened its own day; the 10th ended, one start'];

    -- another tenant: the day is not found there
    perform set_config('app.tenant_id', v_t2::text, true);
    if cma.workday_can_clock_in_again(w.id, pg_temp.v0008zp_at('14:00')) then
      raise exception 'FAIL A6 (A5): workday_can_clock_in_again said true for a day of another tenant';
    end if;
    v_agree := v_agree + 1;
    v_rows := v_rows || array['53', 'A5 another tenant: false', 'PASS', 'the day of tenant one is not seen from tenant two'];
    v_rows := v_rows || array['54', 'A6 the rule agrees with Clock in (A5)', 'PASS', v_agree || ' cases false, nothing written'];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
  insert into verify_0008zp select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
end
$$;

-- A7. Corrections on two-session days, by a supervisor
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  x         jsonb;
  w         cma.workday;
  r         record;
  v_end1    uuid;
  v_start2  uuid;
  v_n       bigint;
  v_txt     text;
  v_got     text := '';
begin
  begin
    x := pg_temp.v0008zp_tenant('verify-0008zp-a7', true);
    foreach v_txt in array array['p1', 'p2'] loop
      perform pg_temp.v0008zp_as(x, v_txt);
      w := cma.open_workday(pg_temp.v0008zp_at('09:00'));
      w := cma.end_workday(w.id, pg_temp.v0008zp_at('13:00'));
      w := cma.open_workday(pg_temp.v0008zp_at('17:00'));
      w := cma.end_workday(w.id, pg_temp.v0008zp_at('21:00'));
    end loop;
    perform pg_temp.v0008zp_as(x, 'sup');

    -- the second start moved to 17:30
    w := pg_temp.v0008zp_day(x, 'p1');
    select e.id into v_start2 from cma.time_event_effective e where e.workday_id = w.id and e.kind = 'start' order by e.occurred_at desc limit 1;
    w := cma.correct_workday((x ->> 'p1')::uuid, date '2026-03-10', jsonb_build_array(
      jsonb_build_object('kind', 'start', 'statusKey', x ->> 'default', 'supersedes', v_start2, 'at', '2026-03-10T17:30:00+01:00')),
      'verify 0008zp the second start moved');
    if w.status <> 'ended' or w.started_at <> pg_temp.v0008zp_at('09:00') or pg_temp.v0008zp_starts(w.id) <> 2
       or (select s.working_seconds from cma.workday_summary s where s.workday_id = w.id) <> 27000 or v_provoke then
      raise exception 'FAIL A7: moving the second start gave % from % with % starts', w.status, w.started_at, pg_temp.v0008zp_starts(w.id);
    end if;
    v_rows := v_rows || array['70', 'A7 the second start moved', 'PASS', '09:00 to 13:00 and 17:30 to 21:00, 27000 s'];

    -- the first end and the second start voided: the sessions merge into one, 09:00 to 21:00
    select e.id into v_end1 from cma.time_event_effective e where e.workday_id = w.id and e.kind = 'end' order by e.occurred_at limit 1;
    select e.id into v_start2 from cma.time_event_effective e where e.workday_id = w.id and e.kind = 'start' order by e.occurred_at desc limit 1;
    w := cma.correct_workday((x ->> 'p1')::uuid, date '2026-03-10', jsonb_build_array(
      jsonb_build_object('kind', 'void', 'supersedes', v_end1), jsonb_build_object('kind', 'void', 'supersedes', v_start2)),
      'verify 0008zp two sessions merged');
    if w.status <> 'ended' or pg_temp.v0008zp_starts(w.id) <> 1 or w.ended_at <> pg_temp.v0008zp_at('21:00')
       or (select s.working_seconds from cma.workday_summary s where s.workday_id = w.id) <> 43200 then
      raise exception 'FAIL A7: merging the sessions gave % with % starts', w.status, pg_temp.v0008zp_starts(w.id);
    end if;
    v_rows := v_rows || array['71', 'A7 the first end and the second start voided: one session', 'PASS', '09:00 to 21:00, 43200 s'];

    -- refusals on p2's two sessions: CMA04 with the rule named, nothing written
    for r in select * from (values
        ('status', '15:00', 'between a clock-out and the next clock-in'),
        ('end', '14:00', 'two clock-outs without a clock-in between them'),
        ('start', '13:00', 'at or before the clock-out before it'),
        ('start', '10:00', 'while a session is open')) as c(kind, at, rule) loop
      select count(*) into v_n from cma.time_event;
      begin
        perform cma.correct_workday((x ->> 'p2')::uuid, date '2026-03-10', jsonb_build_array(
          jsonb_build_object('kind', r.kind, 'at', '2026-03-10T' || r.at || ':00+01:00')
          || case when r.kind = 'end' then '{}'::jsonb else jsonb_build_object('statusKey', x ->> 'other_work') end),
          'verify 0008zp a refused correction');
        raise exception 'FAIL A7: a % at % was accepted', r.kind, r.at;
      exception when sqlstate 'CMA04' then
        get stacked diagnostics v_txt = message_text;
        if position(r.rule in v_txt) = 0 then
          raise exception 'FAIL A7: a % at % was refused with [%], expected [%]', r.kind, r.at, v_txt, r.rule;
        end if;
      end;
      if (select count(*) from cma.time_event) <> v_n then
        raise exception 'FAIL A7: the refused % at % wrote something', r.kind, r.at;
      end if;
      v_got := v_got || case when v_got = '' then '' else ', ' end || r.kind || ' ' || r.at;
    end loop;
    v_rows := v_rows || array['72', 'A7 a status in the gap, two ends, a start at the end, a start in a session: CMA04', 'PASS',
                              v_got || ': each refused with its rule, nothing written'];

    -- Add day with two sessions for p3
    w := cma.correct_workday((x ->> 'p3')::uuid, date '2026-03-10', jsonb_build_array(
      jsonb_build_object('kind', 'start', 'statusKey', x ->> 'default', 'at', '2026-03-10T08:00:00+01:00'),
      jsonb_build_object('kind', 'end', 'at', '2026-03-10T12:00:00+01:00'),
      jsonb_build_object('kind', 'start', 'statusKey', x ->> 'default', 'at', '2026-03-10T13:00:00+01:00'),
      jsonb_build_object('kind', 'end', 'at', '2026-03-10T16:00:00+01:00')), 'verify 0008zp Add day with two sessions');
    if w.status <> 'ended' or w.started_at <> pg_temp.v0008zp_at('08:00') or w.ended_at <> pg_temp.v0008zp_at('16:00')
       or pg_temp.v0008zp_starts(w.id) <> 2 or (select s.working_seconds from cma.workday_summary s where s.workday_id = w.id) <> 25200 then
      raise exception 'FAIL A7: Add day with two sessions gave % from % to %', w.status, w.started_at, w.ended_at;
    end if;
    v_rows := v_rows || array['73', 'A7 Add day with two sessions', 'PASS', '08:00 to 12:00 and 13:00 to 16:00, 25200 s'];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
  insert into verify_0008zp select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
end
$$;

-- A8. The sweep closes an open later session
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  x         jsonb;
  w         cma.workday;
  r         record;
  v_week    uuid;
  v_txt     text;
  v_holders uuid[];
  v_got     uuid[];
  v_digest  cma.message;
begin
  begin
    x := pg_temp.v0008zp_tenant('verify-0008zp-a8', true);
    -- p2's published shift on the date, 09:00 to 20:00 (the owner writes it as it would have stood, as 47 does)
    insert into cma.roster_week (tenant_id, team_id, week_start, status, version, published_at, published_by)
    values ((x ->> 't')::uuid, null, date_trunc('week', date '2026-03-10')::date, 'published', 1, now() - interval '3 days', (x ->> 'mgr')::uuid)
    returning id into v_week;
    insert into cma.roster_entry (tenant_id, roster_week_id, user_id, business_date, kind, start_time, end_time, recorded_at, recorded_by)
    values ((x ->> 't')::uuid, v_week, (x ->> 'p2')::uuid, date '2026-03-10', 'shift', '09:00', '20:00', now() - interval '4 days', (x ->> 'mgr')::uuid);
    -- p1 out at 13:00, in again at 18:00; p2 out at 13:00, in again at 17:00; p3 out at 12:00, in again at 12:30; all left open
    for r in select * from (values ('p1', '13:00', '18:00'), ('p2', '13:00', '17:00'), ('p3', '12:00', '12:30')) as c(who, out_at, in_at) loop
      perform pg_temp.v0008zp_as(x, r.who);
      w := cma.open_workday(pg_temp.v0008zp_at('09:00'));
      w := cma.end_workday(w.id, pg_temp.v0008zp_at(r.out_at));
      w := cma.open_workday(pg_temp.v0008zp_at(r.in_at));
      if w.status <> 'open' then
        raise exception 'FAIL A8: % could not clock in again at %', r.who, r.in_at;
      end if;
    end loop;

    perform pg_temp.v0008zp_as(x, 'sched');
    select string_agg(u.display_name || ' ' || to_char(c.ended_at at time zone 'Europe/Amsterdam', 'HH24:MI') || ' ' || c.end_rule, ', '
                      order by u.display_name) into v_txt
    from cma.close_forgotten_workdays() c join cma.app_user u on u.id = c.user_id;
    if v_txt is distinct from 'p1 18:00 last_event, p2 20:00 shift, p3 17:00 default' or v_provoke then
      raise exception 'FAIL A8: the sweep closed [%]', v_txt;
    end if;
    v_rows := v_rows || array['80', 'A8 the open later session closed by the rule, never before its start', 'PASS', v_txt];
    select string_agg(u.display_name || ':' || s.working_seconds || ':' || s.needs_correction || ':' || s.status, ' ' order by u.display_name)
    into v_txt
    from cma.workday_summary s join cma.app_user u on u.id = s.user_id;
    if v_txt is distinct from 'p1:14400:true:ended p2:25200:true:ended p3:27000:true:ended' then
      raise exception 'FAIL A8: the closed days read [%]', v_txt;
    end if;
    v_rows := v_rows || array['81', 'A8 the closed days: counted, flagged for review', 'PASS', v_txt];
    if (select count(*) from cma.message m where m.title = 'Workday closed automatically') <> 3
       or (select m.body from cma.message m where m.target -> 'users' ? (x ->> 'p2'))
          <> 'Your workday of Tue 10 Mar was closed automatically at 20:00 because you did not log out. Your supervisor will review it.'
       or exists (select 1 from cma.message m where m.title = 'Workday closed automatically'
                  and (select array_agg(d.user_id) from cma.message_delivery d where d.message_id = m.id)
                      <> array[(m.target -> 'users' ->> 0)::uuid]) then
      raise exception 'FAIL A8: the notices read [%]', (select string_agg(m.body, ' | ') from cma.message m where m.title = 'Workday closed automatically');
    end if;
    v_rows := v_rows || array['82', 'A8 one notice per closed day, to that person', 'PASS', 'three notices; p2''s at 20:00'];
    select * into v_digest from cma.message m where m.title = 'Workdays closed automatically';
    select coalesce(array_agg(u.id order by u.id), '{}') into v_holders
    from cma.app_user u where u.status = 'active' and u.kind = 'person' and cma.has_permission(u.id, 'workday.team');
    select coalesce(array_agg(d.user_id order by d.user_id), '{}') into v_got from cma.message_delivery d where d.message_id = v_digest.id;
    if (select count(*) from cma.message m where m.title = 'Workdays closed automatically') <> 1
       or v_digest.body <> '3 workday(s) of Tue 10 Mar were closed automatically. Review them on Team hours.'
       or cardinality(v_holders) < 2 or v_got <> v_holders
       or (select count(*) from cma.close_forgotten_workdays()) <> 0 then
      raise exception 'FAIL A8: the digest reads [%] for % of % holder(s), or a second run closed again', v_digest.body, cardinality(v_got), cardinality(v_holders);
    end if;
    v_rows := v_rows || array['83', 'A8 one digest to the holders of workday.team; a second run closes nothing', 'PASS', v_digest.body];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
  insert into verify_0008zp select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
end
$$;

-- A9. Regression: a one-session day reads as before
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  x         jsonb;
  w         cma.workday;
  s         record;
  v_n       bigint;
  v_txt     text;
begin
  begin
    x := pg_temp.v0008zp_tenant('verify-0008zp-a9', true);
    perform pg_temp.v0008zp_as(x, 'p1');
    w := cma.open_workday(pg_temp.v0008zp_at('09:00'));
    perform cma.set_status(w.id, x ->> 'pause_paid', pg_temp.v0008zp_at('11:00'));
    perform cma.set_status(w.id, x ->> 'default', pg_temp.v0008zp_at('11:15'));
    perform cma.set_status(w.id, x ->> 'pause_unpaid', pg_temp.v0008zp_at('13:00'));
    perform cma.set_status(w.id, x ->> 'default', pg_temp.v0008zp_at('13:30'));
    w := cma.end_workday(w.id, pg_temp.v0008zp_at('17:30'));
    -- by hand, as 0008b counted it: worked 2 h + 1 h 45 + 4 h, paid that plus the paid 15 minutes
    select * into s from cma.workday_summary where workday_id = w.id;
    if s.status <> 'ended' or s.started_at <> pg_temp.v0008zp_at('09:00') or s.ended_at <> pg_temp.v0008zp_at('17:30')
       or s.working_seconds <> 27900 or s.paid_seconds <> 28800 or s.is_capped or s.needs_correction or s.has_correction
       or s.current_status_id <> (select ws.id from cma.work_status ws where ws.key = x ->> 'default')
       or (select count(*) from cma.time_interval i where i.workday_id = w.id) <> 5 or v_provoke then
      raise exception 'FAIL A9: the one-session day reads % % to %, % worked, % paid', s.status, s.started_at, s.ended_at,
        s.working_seconds, s.paid_seconds;
    end if;
    v_rows := v_rows || array['90', 'A9 a one-session day reads as before', 'PASS', '09:00 to 17:30, 27900 s worked, 28800 s paid, five stretches'];

    -- the one tie that changed: a status at the end's own instant, recorded after the end
    perform pg_temp.v0008zp_as(x, 'sup');
    select count(*) into v_n from cma.time_event;
    begin
      perform cma.correct_workday((x ->> 'p1')::uuid, date '2026-03-10', jsonb_build_array(
        jsonb_build_object('kind', 'status', 'statusKey', x ->> 'pause_paid', 'at', '2026-03-10T17:30:00+01:00')),
        'verify 0008zp a status at the end''s instant');
      raise exception 'FAIL A9: a status recorded after the end at the end''s own instant was accepted';
    exception when sqlstate 'CMA04' then
      get stacked diagnostics v_txt = message_text;
    end;
    if position('between a clock-out and the next clock-in' in v_txt) = 0 or (select count(*) from cma.time_event) <> v_n then
      raise exception 'FAIL A9: the tie was refused with [%] or wrote something', v_txt;
    end if;
    v_rows := v_rows || array['91', 'A9 a status at the end''s instant, recorded after it: refused', 'PASS',
                              'CMA04 (before 0008zp it was accepted and counted as a stretch to the window end)'];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
  insert into verify_0008zp select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
end
$$;

-- A10. A second Clock in on a day just clocked in again adds no start
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  x         jsonb;
  w         cma.workday;
  w2        cma.workday;
  v_n       bigint;
begin
  begin
    x := pg_temp.v0008zp_tenant('verify-0008zp-a10', true);
    perform pg_temp.v0008zp_as(x, 'p1');
    w := cma.open_workday(pg_temp.v0008zp_at('09:00'));
    w := cma.end_workday(w.id, pg_temp.v0008zp_at('13:00'));
    w := cma.open_workday(pg_temp.v0008zp_at('17:00'));
    select count(*) into v_n from cma.time_event;
    w2 := cma.open_workday(pg_temp.v0008zp_at('17:00'));
    w2 := cma.open_workday(pg_temp.v0008zp_at('17:01'));
    if w2.id <> w.id or w2.status <> 'open' or pg_temp.v0008zp_starts(w.id) <> 2 or (select count(*) from cma.time_event) <> v_n
       or cma.workday_can_clock_in_again(w.id, pg_temp.v0008zp_at('17:01')) or v_provoke then
      raise exception 'FAIL A10: a second Clock in gave % with % starts', w2.status, pg_temp.v0008zp_starts(w.id);
    end if;
    v_rows := v_rows || array['100', 'A10 a second Clock in adds no second start', 'PASS', 'open, two starts, nothing written'];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
  insert into verify_0008zp select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
end
$$;

-- Verdict: one row per check that passed, then the verdict (30 checks; a block that stopped counts its checks as FAIL)
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008zp
      union all
      select 999, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008zp where result = 'PASS') = 30 then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0008zp where result = 'PASS'),
                                        30 - (select count(*) from verify_0008zp where result = 'PASS'))) x
order by ord;
drop function if exists pg_temp.v0008zp_starts(uuid);
drop function if exists pg_temp.v0008zp_day(jsonb, text, date);
drop function if exists pg_temp.v0008zp_as(jsonb, text);
drop function if exists pg_temp.v0008zp_tenant(text, boolean);
drop function if exists pg_temp.v0008zp_at(text, date);
reset role;
