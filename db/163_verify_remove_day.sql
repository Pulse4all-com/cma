-- =============================================================================================
-- 163_verify_remove_day.sql: verifies addition 0009g, Remove day
-- =============================================================================================
-- Universal: no seed is assumed. The people are synthetic (example.invalid), the statuses are picked by flag, and every
-- instant lies on Tuesday 10 March 2026 in Europe/Amsterdam (the workday window 07:00 to 22:00, set on the throwaway
-- tenant), so the verdict never depends on the time it runs. Block S checks the addition and the grants; blocks A1 to A5
-- each work on throwaway tenants inside a subtransaction that is always rolled back, so nothing stays. Meant for dev (the
-- brief: dev only); it writes nothing that stays, so a run in prod is harmless. Cloud SQL Studio shows no notices: a
-- check that fails raises "FAIL …" and stops its block; every check that passed writes one row, and the last row is the
-- verdict: "PASS | 21 PASS, 0 FAIL" (provoked: "PROVOKED, NOT A PASS | 0 PASS, 21 FAIL"). A block that stopped counts
-- its checks as FAIL; the verdict is reached only when the client goes on after an error (psql -v ON_ERROR_STOP=0, as the
-- provoked run does; with ON_ERROR_STOP=1 the run ends at the first FAIL, which names the check). Run as your own IAM
-- login after 162_remove_day.sql; then 07, 14, 16, 18, 20, 27, 43, 45, 47, 111 and 127 again (they read
-- cma.open_workday; unchanged, still PASS).
--   S1  the addition 0009g is recorded after 0009f; cma.remove_workday(uuid, text) is a volatile plpgsql function with
--       the caller's rights (not SECURITY DEFINER, like cma.correct_workday), owned by cma_owner, executable by cma_app
--       only (not by cma_readonly, not by PUBLIC); cma.open_workday's definition holds the removed-day branch, under a
--       lock, before 0008zp's clock in again
--   A1  a second admin removes an agent's day (a pause, a status back, an end a supervisor moved): the same header comes
--       back, the day leaves the summary (it counted 4 h before); every effective event voided once, nothing deleted;
--       the trail rows carry the reason (trimmed), the approver, the person, one instant; the day's figures are 0 (0
--       worked, 0 paid, 0 sessions, no stretch); not in Team hours, the hours export, time per status or the
--       status-changes export, while the first admin's own day still is (the control); the day editor's history keeps
--       every event, none effective
--   A2  refused, each writing nothing: the caller's own day (CMA06, correct_workday's message); no reason, a blank or a
--       two-character reason, 501 characters (CMA04); an agent and an analyst without workday.team (CMA06); an open day
--       (CMA04 "end the day before removing it"); another tenant's day both ways, an unknown and no id (CMA02); a second
--       removal (CMA04 "this day has already been removed")
--   A3  an imported day may be removed: the batch keeps its record (loaded, its counts, its day); a later void of the
--       batch still works and voids nothing more on that day
--   A4  Clock in on a removed day of the date (cma.open_workday from 126): before the window start refused (CMA04),
--       nothing written; then the day starts again (open, one effective start of the person in the default status,
--       clocked in, in the summary again with one session, the voided events kept); a second Clock in adds no second
--       start; a person whose time is no longer kept is refused (CMA06); an ordinary ended day stays ended (the
--       regression 127 A1 proves in full)
--   A5  Add day on a removed date (cma.correct_workday by a supervisor) brings the day back with the new times only
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

drop table if exists pg_temp.verify_0009g;
create temp table verify_0009g (ord int, check_name text, result text, detail text);

-- An instant on the fixed date (or another) in the tenant's zone
create or replace function pg_temp.v0009g_at(p_time text, p_date date default date '2026-03-10')
returns timestamptz
language sql stable
as $$
  select (p_date + p_time::time) at time zone 'Europe/Amsterdam'
$$;

-- A throwaway tenant: two admins, a supervisor, an analyst and four agents; the window 07:00 to 22:00, 17:00 and an
-- hour's grace; workday.clock_in_again not set (the catalog's default, false); the statuses picked by flag. Its ids as
-- jsonb.
create or replace function pg_temp.v0009g_tenant(p_slug text)
returns jsonb
language plpgsql
as $$
declare
  v_t  uuid;
  v_id uuid;
  v    jsonb;
  r    record;
begin
  v_t := cma.create_tenant(p_slug, 'Verify 0009g', 'Europe/Amsterdam');
  v := jsonb_build_object('t', v_t);
  for r in select * from (values ('admin', 'admin'), ('admin2', 'admin'), ('sup', 'supervisor'), ('analyst', 'analytics'),
                                 ('p1', 'agent'), ('p2', 'agent'), ('p3', 'agent'), ('p4', 'agent')) as x(name, role_key) loop
    insert into cma.app_user (tenant_id, email, display_name)
    values (v_t, format('verify-%s@example.invalid', r.name), r.name) returning id into v_id;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t, v_id, ar.id from cma.app_role ar where ar.tenant_id = v_t and ar.key = r.role_key;
    v := v || jsonb_build_object(r.name, v_id);
  end loop;
  insert into cma.tenant_setting (tenant_id, key, value)
  select v_t, s.key, s.value
  from (values (1, 'workday.window_start', '07:00'), (2, 'workday.window_end', '22:00'), (3, 'workday.auto_close_at', '17:00'),
               (4, 'workday.auto_close_grace_minutes', '60')) as s(ord, key, value)
  order by s.ord;
  v := v || jsonb_build_object(
    'default',      (select s.key from cma.work_status s where s.tenant_id = v_t and s.is_default and s.status = 'active'),
    'other_work',   (select s.key from cma.work_status s where s.tenant_id = v_t and s.status = 'active' and s.is_working
                       and not s.is_default order by s.sort_order, s.key limit 1),
    'pause_unpaid', (select s.key from cma.work_status s where s.tenant_id = v_t and s.status = 'active' and not s.is_working
                       and not s.is_paid order by s.sort_order, s.key limit 1),
    'default_works', (select s.is_working from cma.work_status s where s.tenant_id = v_t and s.is_default and s.status = 'active'));
  if v ->> 'default' is null or v ->> 'other_work' is null or v ->> 'pause_unpaid' is null then
    raise exception 'FAIL setup: the throwaway tenant lacks a status by flag (%)', v;
  end if;
  return v;
end
$$;

-- The acting context inside a block: the application, the tenant, a person
create or replace function pg_temp.v0009g_as(x jsonb, p_who text)
returns void
language sql
as $$
  select set_config('role', 'cma_app', true), set_config('app.tenant_id', x ->> 't', true),
         set_config('app.user_id', x ->> p_who, true), set_config('app.actor_label', '', true);
$$;

-- A person's day of 09:00 to p_end on the fixed date, clocked by the person (their own log out); the day as it stands
create or replace function pg_temp.v0009g_day(x jsonb, p_who text, p_end text default '12:00')
returns cma.workday
language plpgsql
as $$
declare
  w cma.workday;
begin
  perform pg_temp.v0009g_as(x, p_who);
  w := cma.open_workday(pg_temp.v0009g_at('09:00'));
  if p_end is not null then
    w := cma.end_workday(w.id, pg_temp.v0009g_at(p_end));
  end if;
  return w;
end
$$;

-- Remove day as the acting person; 'removed' when it went through, else 'SQLSTATE: message'
create or replace function pg_temp.v0009g_try(p_workday uuid, p_reason text)
returns text
language plpgsql
as $$
begin
  perform cma.remove_workday(p_workday, p_reason);
  return 'removed';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end
$$;

-- The effective events of a day, read as the application
create or replace function pg_temp.v0009g_live(p_workday uuid)
returns bigint
language sql stable
as $$
  select count(*) from cma.time_event_effective e where e.workday_id = p_workday
$$;

-- Every event of the current tenant, read as the application (row-level security)
create or replace function pg_temp.v0009g_events()
returns bigint
language sql stable
as $$
  select count(*) from cma.time_event
$$;

-- S1. The addition, the function, its rights; open_workday's new branch
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_fn      text := 'cma.remove_workday(uuid,text)';
  p         pg_proc;
begin
  if not exists (select 1 from cma.schema_migration where version = '0009g') or v_provoke
     or not exists (select 1 from cma.schema_migration where version = '0009f') then
    raise exception 'FAIL S1: addition 0009g not recorded after 0009f';
  end if;
  select * into p from pg_proc where oid = to_regprocedure(v_fn);
  if p.oid is null or p.prosecdef or p.provolatile <> 'v'
     or (select l.lanname from pg_language l where l.oid = p.prolang) <> 'plpgsql'
     or p.proowner <> 'cma_owner'::regrole::oid
     or not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
     or exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0) then
    raise exception 'FAIL S1: % is not a volatile invoker plpgsql function of cma_owner for cma_app only', v_fn;
  end if;
  if pg_get_functiondef(to_regprocedure('cma.open_workday(timestamptz)'))
       not like '%time_event_effective%for update%time_event_effective%assert_time_kept%workday_can_clock_in_again%for update%workday_can_clock_in_again%' then
    raise exception 'FAIL S1: open_workday is not the 0009g definition (the removed-day branch before the clock in again)';
  end if;
  insert into verify_0009g values (1, 'S1 addition, function and rights; open_workday', 'PASS',
    'invoker, volatile, plpgsql, cma_owner, cma_app only; open_workday starts a removed day under a lock');
end
$$;

-- A1. A second admin removes an agent's day
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  x         jsonb;
  w         cma.workday;
  w2        cma.workday;
  v_end     uuid;
  v_live    uuid[];
  v_before  bigint;
  v_worked  bigint;
  v_n       bigint;
  s         record;
begin
  begin
    x := pg_temp.v0009g_tenant('verify-0009g-a1');
    -- p1: in 09:00, a pause 11:00, back 11:30, out 13:00; the supervisor moves the end to 13:30
    w := pg_temp.v0009g_day(x, 'p1', null);
    perform cma.set_status(w.id, x ->> 'pause_unpaid', pg_temp.v0009g_at('11:00'));
    perform cma.set_status(w.id, x ->> 'default', pg_temp.v0009g_at('11:30'));
    w := cma.end_workday(w.id, pg_temp.v0009g_at('13:00'));
    select e.id into v_end from cma.time_event_effective e where e.workday_id = w.id and e.kind = 'end';
    perform pg_temp.v0009g_as(x, 'sup');
    perform cma.correct_workday((x ->> 'p1')::uuid, date '2026-03-10', jsonb_build_array(
      jsonb_build_object('kind', 'end', 'supersedes', v_end, 'at', '2026-03-10T13:30:00+01:00')), 'verify 0009g the end confirmed later');
    -- the first admin's own day, 09:00 to 12:00 (the control of the Team hours read)
    perform pg_temp.v0009g_day(x, 'admin');

    perform pg_temp.v0009g_as(x, 'admin2');
    select array_agg(e.id order by e.id) into v_live from cma.time_event_effective e where e.workday_id = w.id;
    v_before := pg_temp.v0009g_events();
    select working_seconds into v_worked from cma.workday_summary where workday_id = w.id;
    select * into w from cma.workday where id = w.id;
    w2 := cma.remove_workday(w.id, '  verify 0009g a test clock-in  ');
    if w2.id <> w.id or w2.status <> 'ended' or w2.started_at <> w.started_at or w2.ended_at <> pg_temp.v0009g_at('13:30')
       or v_worked <> (case when (x ->> 'default_works')::boolean then 14400 else 0 end)
       or exists (select 1 from cma.workday_summary where workday_id = w.id) or v_provoke then
      raise exception 'FAIL A1: the removal answered % (% to %), the day counted % s before, summary row left: %',
        w2.status, w2.started_at, w2.ended_at, v_worked, exists (select 1 from cma.workday_summary where workday_id = w.id);
    end if;
    v_rows := v_rows || array['10', 'A1 removed: the header back, the day leaves the summary', 'PASS',
      'ended 09:00 to 13:30 unchanged; counted 4 h before, no summary row after'];

    if pg_temp.v0009g_live(w.id) <> 0 or array_length(v_live, 1) <> 4 or pg_temp.v0009g_events() <> v_before + 4
       or (select array_agg(e.supersedes_event_id order by e.supersedes_event_id) from cma.time_event e
           where e.workday_id = w.id and e.kind = 'void') is distinct from v_live
       or (select count(*) from cma.time_event e where e.workday_id = w.id and e.kind <> 'void') <> 5 then
      raise exception 'FAIL A1: % effective left, % events before and % after, % voids', pg_temp.v0009g_live(w.id), v_before,
        pg_temp.v0009g_events(), (select count(*) from cma.time_event e where e.workday_id = w.id and e.kind = 'void');
    end if;
    v_rows := v_rows || array['11', 'A1 every effective event voided once, nothing deleted', 'PASS',
      '4 effective events, 4 voids, one each; the 5 earlier events kept'];

    select count(*) filter (where e.source <> 'correction' or e.reason <> 'verify 0009g a test clock-in'
                              or e.approved_by <> (x ->> 'admin2')::uuid or e.user_id <> (x ->> 'p1')::uuid
                              or e.status_id is not null or e.occurred_at <> e.recorded_at) as wrong,
           count(distinct e.recorded_at) as instants, count(*) as n
    into s
    from cma.time_event e where e.workday_id = w.id and e.kind = 'void';
    if s.wrong <> 0 or s.instants <> 1 or s.n <> 4 then
      raise exception 'FAIL A1: the trail rows: % wrong, % instants, % rows', s.wrong, s.instants, s.n;
    end if;
    v_rows := v_rows || array['12', 'A1 the trail rows carry the reason and the approver', 'PASS',
      'source correction, the reason trimmed, approved by the second admin, one instant'];

    select * into s from cma.workday_summary_of(w.tenant_id, w.id, cma.business_day_end(w.business_date, w.timezone));
    if s.working_seconds <> 0 or s.paid_seconds <> 0 or s.sessions <> 0
       or exists (select 1 from cma.time_interval i where i.workday_id = w.id) then
      raise exception 'FAIL A1: the removed day''s figures: % worked, % paid, % sessions', s.working_seconds, s.paid_seconds, s.sessions;
    end if;
    v_rows := v_rows || array['13', 'A1 the day''s figures are 0', 'PASS', '0 worked, 0 paid, 0 sessions, no stretch'];

    if exists (select 1 from cma.team_hours(date '2026-03-10', date '2026-03-10') t where t.user_id = (x ->> 'p1')::uuid)
       or not exists (select 1 from cma.team_hours(date '2026-03-10', date '2026-03-10') t where t.user_id = (x ->> 'admin')::uuid)
       or exists (select 1 from cma.export_hours(date '2026-03-10', date '2026-03-10', (x ->> 'p1')::uuid))
       or exists (select 1 from cma.team_status_time(date '2026-03-10', date '2026-03-10', (x ->> 'p1')::uuid))
       or exists (select 1 from cma.export_status_changes(date '2026-03-10', date '2026-03-10', (x ->> 'p1')::uuid)) then
      raise exception 'FAIL A1: the removed day is still read by Team hours, an export or time per status (or the control is missing)';
    end if;
    v_rows := v_rows || array['14', 'A1 not in Team hours, the exports or time per status', 'PASS',
      'no row for the removed day; the first admin''s own day still listed'];

    select count(*) as n, count(*) filter (where t.is_effective) as live,
           count(*) filter (where t.kind = 'void' and t.reason = 'verify 0009g a test clock-in' and t.approved_by_name = 'admin2') as voids
    into s from cma.team_day((x ->> 'p1')::uuid, date '2026-03-10') t;
    if s.n <> 9 or s.live <> 0 or s.voids <> 4 then
      raise exception 'FAIL A1: the day editor''s history reads % events, % effective, % voids by the second admin', s.n, s.live, s.voids;
    end if;
    v_rows := v_rows || array['15', 'A1 the history keeps every event', 'PASS', '9 events, none effective, 4 voids with reason and approver'];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
  insert into verify_0009g select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
end
$$;

-- A2. The refusals, each writing nothing
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  x         jsonb;
  y         jsonb;
  w         cma.workday;
  wo        cma.workday;
  wa        cma.workday;
  wy        cma.workday;
  v_n       bigint;
  v_got     text;
  v_all     text[];
begin
  begin
    x := pg_temp.v0009g_tenant('verify-0009g-a2');
    y := pg_temp.v0009g_tenant('verify-0009g-a2-two');
    w  := pg_temp.v0009g_day(x, 'p1');            -- an agent's ended day
    wa := pg_temp.v0009g_day(x, 'admin');         -- the first admin's own ended day
    wo := pg_temp.v0009g_day(x, 'p2', null);      -- an open day (never ended)
    wy := pg_temp.v0009g_day(y, 'p1');            -- tenant two's agent's day

    -- the caller's own day
    perform pg_temp.v0009g_as(x, 'admin');
    v_n := pg_temp.v0009g_events();
    v_got := pg_temp.v0009g_try(wa.id, 'verify 0009g my own test day');
    if v_got <> 'CMA06: nobody corrects their own day' or pg_temp.v0009g_events() <> v_n or v_provoke then
      raise exception 'FAIL A2: the caller''s own day gave [%]', v_got;
    end if;
    v_rows := v_rows || array['20', 'A2 the caller''s own day is refused', 'PASS', 'CMA06 nobody corrects their own day; nothing written'];

    -- no reason, a blank one, two characters, 501 characters
    perform pg_temp.v0009g_as(x, 'admin2');
    select array_agg(pg_temp.v0009g_try(w.id, r) order by k) into v_all
    from (values (1, null::text), (2, ''), (3, '    '), (4, '  ab  '), (5, repeat('x', 501))) as t(k, r);
    if exists (select 1 from unnest(v_all) g where g <> 'CMA04: a correction needs a reason of 3 to 500 characters')
       or pg_temp.v0009g_events() <> v_n or pg_temp.v0009g_live(w.id) <> 2 then
      raise exception 'FAIL A2: the reasons gave %', v_all;
    end if;
    v_rows := v_rows || array['21', 'A2 no reason, a short or a long one is refused', 'PASS', 'CMA04 five times; nothing written'];

    -- without workday.team: an agent and an analyst
    perform pg_temp.v0009g_as(x, 'p2');
    v_got := pg_temp.v0009g_try(w.id, 'verify 0009g an agent tries');
    perform pg_temp.v0009g_as(x, 'analyst');
    v_got := v_got || ' | ' || pg_temp.v0009g_try(w.id, 'verify 0009g an analyst tries');
    if v_got not like 'CMA06: % lacks permission workday.team | CMA06: % lacks permission workday.team'
       or pg_temp.v0009g_events() <> v_n then
      raise exception 'FAIL A2: callers without workday.team gave [%]', v_got;
    end if;
    v_rows := v_rows || array['22', 'A2 a caller without workday.team is refused', 'PASS', 'agent and analyst CMA06; nothing written'];

    -- an open day
    perform pg_temp.v0009g_as(x, 'admin2');
    v_got := pg_temp.v0009g_try(wo.id, 'verify 0009g an open test day');
    if v_got <> 'CMA04: end the day before removing it' or pg_temp.v0009g_events() <> v_n
       or (select status from cma.workday where id = wo.id) <> 'open' or pg_temp.v0009g_live(wo.id) <> 1 then
      raise exception 'FAIL A2: an open day gave [%]', v_got;
    end if;
    v_rows := v_rows || array['23', 'A2 an open day is refused', 'PASS', 'CMA04 end the day before removing it; still open, nothing written'];

    -- another tenant's day both ways, an unknown id, no id
    v_got := pg_temp.v0009g_try(wy.id, 'verify 0009g another tenant''s day');
    perform pg_temp.v0009g_as(y, 'admin2');
    v_got := v_got || ' | ' || pg_temp.v0009g_try(w.id, 'verify 0009g another tenant''s day');
    v_got := v_got || ' | ' || pg_temp.v0009g_try('00000000-0000-7000-8000-00000000dead', 'verify 0009g an unknown day');
    v_got := v_got || ' | ' || pg_temp.v0009g_try(null, 'verify 0009g no day');
    perform set_config('role', 'cma_owner', true);
    if v_got not like 'CMA02: workday % not found in the current tenant | CMA02: workday % not found in the current tenant | CMA02: workday % not found in the current tenant | CMA02: workday % not found in the current tenant'
       or (select count(*) from cma.time_event e where e.tenant_id in ((x ->> 't')::uuid, (y ->> 't')::uuid) and e.kind = 'void') <> 0
       or (select count(*) from cma.time_event_effective_all e where e.workday_id in (w.id, wy.id)) <> 4 then
      raise exception 'FAIL A2: another tenant''s or an unknown day gave [%]', v_got;
    end if;
    v_rows := v_rows || array['24', 'A2 another tenant''s, an unknown or no day is refused', 'PASS',
      'CMA02 both ways, unknown id and null; no void in either tenant'];

    -- a second removal
    perform pg_temp.v0009g_as(x, 'admin2');
    v_got := pg_temp.v0009g_try(w.id, 'verify 0009g the first removal');
    v_n := pg_temp.v0009g_events();
    v_got := v_got || ' | ' || pg_temp.v0009g_try(w.id, 'verify 0009g the second removal');
    if v_got <> 'removed | CMA04: this day has already been removed' or pg_temp.v0009g_events() <> v_n then
      raise exception 'FAIL A2: a second removal gave [%]', v_got;
    end if;
    v_rows := v_rows || array['25', 'A2 a second removal is refused', 'PASS', 'CMA04 this day has already been removed; nothing written'];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
  insert into verify_0009g select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
end
$$;

-- A3. An imported day may be removed; the batch keeps its record
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  x         jsonb;
  b         cma.import_batch;
  b2        cma.import_batch;
  w         cma.workday;
  v_got     text;
begin
  begin
    x := pg_temp.v0009g_tenant('verify-0009g-a3');
    -- p3: 09:00 to 12:00 from a one-day batch, loaded as 111 and 127 load it
    perform pg_temp.v0009g_as(x, 'admin');
    perform cma.upsert_work_status('verify_import', 'Verify import', true, true, true, true, 900);
    perform cma.retire_work_status('verify_import');
    b := cma.stage_import_batch('verify-0009g', 'verify_source', 'verify.csv', date '2026-03-09', date '2026-03-13',
                                'Europe/Amsterdam', 'verify_import', x ->> 'pause_unpaid');
    insert into cma.import_session_staging (batch_key, external_person_id, external_session_id, login_local, logout_local)
    values ('verify-0009g', 'A3', 's01', '2026-03-10 09:00:00', '2026-03-10 12:00:00');
    insert into cma.import_person_map (batch_id, external_person_id, user_id) values (b.id, 'A3', (x ->> 'p3')::uuid);
    b := cma.load_import_batch('verify-0009g');
    select * into w from cma.workday where user_id = (x ->> 'p3')::uuid and business_date = date '2026-03-10';
    if b.status <> 'loaded' or (b.counts ->> 'days_written')::int <> 1 or w.id is null or v_provoke then
      raise exception 'FAIL A3: the one-day batch gave % with %', b.status, b.counts;
    end if;

    perform pg_temp.v0009g_as(x, 'admin2');
    v_got := pg_temp.v0009g_try(w.id, 'verify 0009g an imported test day');
    select * into b2 from cma.import_batch where id = b.id;
    if v_got <> 'removed' or pg_temp.v0009g_live(w.id) <> 0 or exists (select 1 from cma.workday_summary where workday_id = w.id)
       or b2.status <> 'loaded' or b2.counts is distinct from b.counts
       or not exists (select 1 from cma.import_day d where d.batch_id = b.id and d.workday_id = w.id) then
      raise exception 'FAIL A3: removing the imported day gave [%], batch % %', v_got, b2.status, b2.counts;
    end if;
    v_rows := v_rows || array['30', 'A3 an imported day may be removed', 'PASS', 'removed; the batch still loaded with its counts and its day'];

    perform pg_temp.v0009g_as(x, 'admin');
    b2 := cma.void_import_batch('verify-0009g', 'verify 0009g the batch withdrawn after the removal');
    if b2.status <> 'voided' or (b2.counts ->> 'events_voided')::int <> 0
       or (select count(*) from cma.time_event e where e.workday_id = w.id and e.kind = 'void') <> 2 then
      raise exception 'FAIL A3: the batch void after the removal gave % with %', b2.status, b2.counts;
    end if;
    v_rows := v_rows || array['31', 'A3 the batch can still be withdrawn', 'PASS', 'voided, 0 events voided: nothing was left on the day'];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
  insert into verify_0009g select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
end
$$;

-- A4. Clock in on a removed day of the date
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  x         jsonb;
  w         cma.workday;
  w2        cma.workday;
  w4        cma.workday;
  wn        cma.workday;
  v_n       bigint;
  v_got     text;
begin
  begin
    x := pg_temp.v0009g_tenant('verify-0009g-a4');
    w  := pg_temp.v0009g_day(x, 'p1', '10:00');   -- a test clock-in, 09:00 to 10:00, the person's own log out
    w4 := pg_temp.v0009g_day(x, 'p4', '10:00');
    wn := pg_temp.v0009g_day(x, 'p2', '10:00');   -- an ordinary ended day, not removed
    perform pg_temp.v0009g_as(x, 'admin2');
    if pg_temp.v0009g_try(w.id, 'verify 0009g a test clock-in') <> 'removed'
       or pg_temp.v0009g_try(w4.id, 'verify 0009g a test clock-in') <> 'removed' then
      raise exception 'FAIL A4: the setup removals did not go through';
    end if;

    -- before the window start
    perform pg_temp.v0009g_as(x, 'p1');
    v_n := pg_temp.v0009g_events();
    begin
      perform cma.open_workday(pg_temp.v0009g_at('06:30'));
      v_got := 'opened';
    exception when others then
      v_got := sqlstate || ': ' || sqlerrm;
    end;
    if v_got <> 'CMA04: the workday starts at 07:00' or pg_temp.v0009g_events() <> v_n or v_provoke then
      raise exception 'FAIL A4: Clock in before the window start on a removed day gave [%]', v_got;
    end if;
    v_rows := v_rows || array['40', 'A4 a removed day: Clock in before the window start refused', 'PASS', 'CMA04 the workday starts at 07:00; nothing written'];

    w2 := cma.open_workday(pg_temp.v0009g_at('11:00'));
    if w2.id <> w.id or w2.status <> 'open' or w2.started_at <> pg_temp.v0009g_at('11:00') or w2.ended_at is not null
       or pg_temp.v0009g_live(w.id) <> 1 or pg_temp.v0009g_events() <> v_n + 1
       or (select e.source || ':' || ws.key from cma.time_event_effective e join cma.work_status ws on ws.id = e.status_id
           where e.workday_id = w.id and e.kind = 'start') <> 'user:' || (x ->> 'default')
       or not cma.is_clocked_in((x ->> 'p1')::uuid)
       or (select s.sessions from cma.workday_summary s where s.workday_id = w.id) is distinct from 1
       or (select count(*) from cma.time_event e where e.workday_id = w.id and e.kind = 'void') <> 2 then
      raise exception 'FAIL A4: Clock in on the removed day gave % from % (% effective)', w2.status, w2.started_at, pg_temp.v0009g_live(w.id);
    end if;
    v_rows := v_rows || array['41', 'A4 Clock in starts a removed day again', 'PASS',
      'open from 11:00, one start by the person in the default status, clocked in, one session; the voids kept'];

    v_n := pg_temp.v0009g_events();
    w2 := cma.open_workday(pg_temp.v0009g_at('11:00'));
    w2 := cma.open_workday(pg_temp.v0009g_at('11:01'));
    if w2.id <> w.id or w2.status <> 'open' or pg_temp.v0009g_live(w.id) <> 1 or pg_temp.v0009g_events() <> v_n then
      raise exception 'FAIL A4: a second Clock in on the started day wrote % events', pg_temp.v0009g_events() - v_n;
    end if;
    v_rows := v_rows || array['42', 'A4 a second Clock in adds no second start', 'PASS', 'open, one start, nothing written'];

    -- a person whose time is no longer kept
    perform set_config('role', 'cma_owner', true);
    delete from cma.user_role where tenant_id = (x ->> 't')::uuid and user_id = (x ->> 'p4')::uuid;
    perform pg_temp.v0009g_as(x, 'p4');
    v_n := pg_temp.v0009g_events();
    begin
      perform cma.open_workday(pg_temp.v0009g_at('11:00'));
      v_got := 'opened';
    exception when others then
      v_got := sqlstate;
    end;
    if v_got <> 'CMA06' or pg_temp.v0009g_events() <> v_n or pg_temp.v0009g_live(w4.id) <> 0 then
      raise exception 'FAIL A4: Clock in on a removed day by a person whose time is not kept gave [%]', v_got;
    end if;
    v_rows := v_rows || array['43', 'A4 a person whose time is not kept is refused', 'PASS', 'CMA06; nothing written'];

    -- an ordinary ended day with the setting off stays ended (127 A1 in full)
    perform pg_temp.v0009g_as(x, 'p2');
    v_n := pg_temp.v0009g_events();
    w2 := cma.open_workday(pg_temp.v0009g_at('11:00'));
    if w2.id <> wn.id or w2.status <> 'ended' or w2.ended_at <> pg_temp.v0009g_at('10:00') or pg_temp.v0009g_live(wn.id) <> 2
       or pg_temp.v0009g_events() <> v_n then
      raise exception 'FAIL A4: an ordinary ended day gave % (% events written)', w2.status, pg_temp.v0009g_events() - v_n;
    end if;
    v_rows := v_rows || array['44', 'A4 an ordinary ended day stays ended', 'PASS', 'ended 10:00, nothing written'];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
  insert into verify_0009g select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
end
$$;

-- A5. Add day on a removed date
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  x         jsonb;
  w         cma.workday;
  w2        cma.workday;
  s         record;
begin
  begin
    x := pg_temp.v0009g_tenant('verify-0009g-a5');
    w := pg_temp.v0009g_day(x, 'p1');
    perform pg_temp.v0009g_as(x, 'admin2');
    if pg_temp.v0009g_try(w.id, 'verify 0009g a test clock-in') <> 'removed' then
      raise exception 'FAIL A5: the setup removal did not go through';
    end if;
    perform pg_temp.v0009g_as(x, 'sup');
    w2 := cma.correct_workday((x ->> 'p1')::uuid, date '2026-03-10', jsonb_build_array(
      jsonb_build_object('kind', 'start', 'statusKey', x ->> 'other_work', 'at', '2026-03-10T14:00:00+01:00'),
      jsonb_build_object('kind', 'end', 'at', '2026-03-10T15:00:00+01:00')), 'verify 0009g the real day entered');
    select * into s from cma.workday_summary where workday_id = w.id;
    if w2.id <> w.id or w2.status <> 'ended' or w2.started_at <> pg_temp.v0009g_at('14:00') or w2.ended_at <> pg_temp.v0009g_at('15:00')
       or s.working_seconds is distinct from 3600::bigint or s.sessions is distinct from 1 or not s.has_correction
       or pg_temp.v0009g_live(w.id) <> 2 or v_provoke then
      raise exception 'FAIL A5: Add day on the removed date gave % from % to %, % worked', w2.status, w2.started_at, w2.ended_at, s.working_seconds;
    end if;
    v_rows := v_rows || array['50', 'A5 Add day on a removed date brings the day back', 'PASS', '14:00 to 15:00, 3600 s worked, one session, corrected'];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
  insert into verify_0009g select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
end
$$;

-- Verdict: one row per check that passed, then the verdict (21 checks; a block that stopped counts its checks as FAIL)
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0009g
      union all
      select 999, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0009g where result = 'PASS') = 21 then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0009g where result = 'PASS'),
                                        21 - (select count(*) from verify_0009g where result = 'PASS'))) x
order by ord;
drop function if exists pg_temp.v0009g_events();
drop function if exists pg_temp.v0009g_live(uuid);
drop function if exists pg_temp.v0009g_try(uuid, text);
drop function if exists pg_temp.v0009g_day(jsonb, text, text);
drop function if exists pg_temp.v0009g_as(jsonb, text);
drop function if exists pg_temp.v0009g_tenant(text);
drop function if exists pg_temp.v0009g_at(text, date);
drop table if exists pg_temp.verify_0009g;
reset role;
