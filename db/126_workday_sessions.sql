-- =============================================================================================
-- 126_workday_sessions.sql: addition 0008zp, split shifts: clock in again on the same day
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics: whether a tenant's people may clock in again is the tenant setting
-- workday.clock_in_again, off by default, so in a tenant that sets nothing a person's Clock in keeps today's behaviour
-- (Decision log, 12 October 2026: defaults keep today's behaviour). The day's shape is not under the setting: in every
-- tenant a supervisor's correction may now write a day of several sessions (an end, then a later start), where 0003
-- refused a second start, and a day of several sessions stays valid when a tenant switches the setting off. Runs unchanged in every database, after 122_flash.sql (0008zn).
-- Rerunnable, forward-only, in one transaction with a lock timeout. Run as your own IAM login: dev first, then
-- 127_verify_workday_sessions.sql, then 02_seed_pulse4all.sql again (Pulse4all Subscriptions' value), then 07 (block C),
-- 10, 18, 20, 47, 51 and 111 again (unchanged, still PASS); then prod, 126 before the merge (the web of this change reads
-- cma.workday_can_clock_in_again), 02, 127. The web of main runs unchanged on it: it calls cma.open_workday() and reads
-- the summary as before, and with the setting off nothing it sees changes. Numbered 0008zp, 126 and 127, not 0008zo,
-- 125 and 126 as briefed: the open pull request 216 (Flash watch cadence) holds 0008zo and 125. This addition needs
-- nothing of it and runs before or after it.
--
-- Why (Decision log, 3 November 2026; Martin): agents work split shifts. A person who logged out or pressed End
-- workday can sign in again and press Clock in on the same business day, the same process as in the morning. The workday
-- becomes one or more sessions; the time between one session's end and the next session's start has no status and counts
-- in no figure (not worked, not paid, not billable, not productive, not a pause). The original reason for "an ended day
-- stays ended" (IAP's silent re-login opening a day) fell away with the explicit Clock in of 7 October 2026: a visit
-- still opens nothing.
--
-- What it adds
--   setting            workday.clock_in_again (boolean, default false): whether a person can clock in again on the same
--                      day after their own log out, within the workday window
--   the rule, once     cma.workday_can_clock_in_again(workday, at default now()): true only when the day belongs to the
--                      current tenant and is ended; the tenant's workday.clock_in_again is true; the day's last effective
--                      event is an end of source 'user' (the person's own Log out or End workday: a day the scheduler
--                      ended (system), a correction ended or an import wrote stays a correction for a supervisor); the
--                      instant lies strictly after that end; it falls on the day's business date in the day's zone and
--                      within the day's workday window (workday.window_start to workday.window_end); and the person is
--                      active with their time kept (cma.time_is_kept, 0003d). cma.open_workday() and the web's day read
--                      both call it, so the Clock in card and the write can never disagree
--   the day's shape    cma.refresh_workday() (replacing 0003's): the effective events, in the order every time view takes
--                      them (occurred_at, recorded_at, id), read start, (status)*, end, start, (status)*, end, ...: the
--                      first is a start; a later start directly follows an end and lies strictly after it; a status never
--                      directly follows an end; two ends never follow each other; so at most the last session is open.
--                      Each violation is CMA04 with a message naming the rule. started_at is the first start; ended_at is
--                      the last end when the last effective event is an end, else null; status open or ended. A day with
--                      one start and at most one end is valid exactly when it was before, but for two events at one
--                      instant: they are taken in the views' order, so a status recorded after an end at the end's own
--                      instant is refused now (the interval view counted it as a stretch to the window end before), and
--                      so is a status or an end recorded before the start at the start's own instant (a correction that
--                      moves the start onto an existing status's time; 0003 refused only one strictly before it)
--   clock in again     cma.open_workday() (replacing 0008b's, same signature and result): on today's ended day, when
--                      cma.workday_can_clock_in_again(day, p_occurred_at) holds, the day is locked, the rule checked again
--                      under the lock (two tabs pressing at once give one start: the second waits for the first's lock
--                      and then sees an open day), and a start of source 'user' in the tenant's default status is
--                      written at p_occurred_at; the day returned is open. Every other case is unchanged: an existing day
--                      is returned as it is (an ended day outside the conditions stays ended, no new error), a new day
--                      only for a person whose time is kept and not before the window start
--
-- What does not change, and why (each checked against the function's current text)
--   cma.set_status, cma.end_workday (0002): they compare the time with started_at, the first session's start, and refuse
--                      an ended day (CMA03), so a status or an end goes into the open session; the web passes no time
--                      (now()). Not redefined
--   cma.correct_workday, cma.correct_time_event (0008b): their last step is cma.refresh_workday, so a supervisor can now
--                      also add a second session (an end, then a later start), void an end and the next start to merge two
--                      sessions, and Add day with two sessions (the first change is still the earliest start). No check
--                      in them assumes one start or one end. Not redefined
--   cma.close_forgotten_workdays (0008b): it ends an open day, that is an open last session, at the planned shift end,
--                      else workday.auto_close_at, never after the window end and never before the day's last effective
--                      event (an open later session that started after the rule's time is ended at its own start and
--                      flagged). Not redefined
--   the views          cma.time_interval_all (0008b): a stretch begins only at a start or status event and runs to the
--                      next effective event, so the stretch before a log out ends at the end, and the end begins none: the
--                      gap between sessions yields no row. cma.workday_summary_all (0008d) sums those stretches. Not
--                      redefined, no column changes (cma_read and BigQuery read them)
--   reads              cma.team_now, cma.team_day, cma.team_hours, cma.team_status_time, cma.export_hours,
--                      cma.export_status_changes and cma.is_clocked_in read the summary, the stretches, the events or
--                      the day's status: on a two-session day the first start, the last end, the worked time without
--                      the gap, one row per stretch; nobody is clocked in during the gap. Not redefined
--
-- SQLSTATEs as before: CMA01 no acting user, CMA02 not found, CMA03 conflict, CMA04 invalid, CMA05 tenant configuration
-- missing, CMA06 not permitted.
--
-- Guard: scripts run under a personal IAM login so the audit trail names a person. postgres is
-- for emergencies only; to use it deliberately, run first:  set cma.emergency = 'on';
do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;

begin;
set local lock_timeout = '5s';
set role cma_owner;

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0008zn') then
    raise exception 'addition 0008zn (122_flash.sql) must run before 0008zp';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The setting
-- ---------------------------------------------------------------------------------------------
-- A boolean: cma.check_tenant_setting() takes true or false for it without a branch of its own
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('workday.clock_in_again', 'boolean', null, 'false',
     'Whether a person can clock in again on the same day after their own log out, within the workday window')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- ---------------------------------------------------------------------------------------------
-- 2. The rule, defined once
-- ---------------------------------------------------------------------------------------------
-- True when the person of this day may clock in again at p_at (see the header). False for a day of another tenant, an
-- unknown day, an open day and every case outside the conditions. Invoker rights: under cma_app row-level security keeps
-- it to the tenant, and the explicit filter does under the owner.
create or replace function cma.workday_can_clock_in_again(p_workday_id uuid, p_at timestamptz default now())
returns boolean
language sql stable
as $$
  select coalesce((
    select w.status = 'ended'
           and cma.setting_of(w.tenant_id, 'workday.clock_in_again') = 'true'
           and l.kind = 'end' and l.source = 'user'
           and p_at > l.occurred_at
           and cma.business_date(p_at, w.timezone) = w.business_date
           and p_at >= cma.business_day_start(w.business_date, w.timezone)
           and p_at < cma.business_day_end(w.business_date, w.timezone)
           and cma.time_is_kept(w.user_id)
    from cma.workday w
    cross join lateral (
      select e.kind, e.source, e.occurred_at
      from cma.time_event_effective e
      where e.tenant_id = w.tenant_id and e.workday_id = w.id
      order by e.occurred_at desc, e.recorded_at desc, e.id desc
      limit 1
    ) l
    where w.tenant_id = cma.current_tenant_id() and w.id = p_workday_id
  ), false)
$$;
comment on function cma.workday_can_clock_in_again(uuid, timestamptz) is
  'Whether the person of an ended day may clock in again at the instant (addition 0008zp): workday.clock_in_again on, the day ended by the person''s own log out, strictly after that end, on the day''s business date within its workday window, and the person''s time kept';

-- ---------------------------------------------------------------------------------------------
-- 3. The day's shape: one or more sessions
-- ---------------------------------------------------------------------------------------------
-- Recompute the header from the effective events and validate the day. Called by every write function; harmless to call
-- again. The events are walked in the order the time views take them, so what is accepted here is what they count.
create or replace function cma.refresh_workday(p_workday_id uuid)
returns void
language plpgsql
as $$
declare
  v_tenant   uuid := cma.current_tenant_id();
  v_started  timestamptz;
  v_prev     text;           -- the kind of the previous effective event; null before the first
  v_prev_at  timestamptz;
  e          record;
begin
  for e in
    select x.kind, x.occurred_at
    from cma.time_event_effective x
    where x.tenant_id = v_tenant and x.workday_id = p_workday_id
    order by x.occurred_at, x.recorded_at, x.id
  loop
    if v_prev is null then
      if e.kind <> 'start' then
        raise exception 'workday % has a status or end event before its start', p_workday_id
          using errcode = 'CMA04';
      end if;
      v_started := e.occurred_at;
    elsif e.kind = 'start' then
      if v_prev <> 'end' then
        raise exception 'workday % has a clock-in while a session is open: a later session starts only after a clock-out', p_workday_id
          using errcode = 'CMA04';
      end if;
      if e.occurred_at <= v_prev_at then
        raise exception 'workday % has a clock-in again at or before the clock-out before it', p_workday_id
          using errcode = 'CMA04';
      end if;
    elsif e.kind = 'status' then
      if v_prev = 'end' then
        raise exception 'workday % has a status change between a clock-out and the next clock-in', p_workday_id
          using errcode = 'CMA04';
      end if;
    elsif v_prev = 'end' then      -- an end
      raise exception 'workday % has two clock-outs without a clock-in between them', p_workday_id
        using errcode = 'CMA04';
    end if;
    v_prev    := e.kind;
    v_prev_at := e.occurred_at;
  end loop;

  if v_prev is null then
    raise exception 'workday % has no effective start event', p_workday_id
      using errcode = 'CMA04';
  end if;

  update cma.workday
  set started_at = v_started,
      ended_at   = case when v_prev = 'end' then v_prev_at end,
      status     = case when v_prev = 'end' then 'ended' else 'open' end
  where tenant_id = v_tenant and id = p_workday_id;

  if not found then
    raise exception 'workday % not found in the current tenant', p_workday_id using errcode = 'CMA02';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Clock in, and clock in again
-- ---------------------------------------------------------------------------------------------
-- As in 0008b, with one branch where today's day exists: an ended day that cma.workday_can_clock_in_again allows gets a
-- new session. The rule is checked, the day locked, the rule checked again under the lock, then the start written. A
-- second tab that pressed at the same moment waits for the lock, then finds the day open and returns it unchanged.
-- Every other existing day is returned as it is (an ended day outside the conditions stays ended: no new error).
create or replace function cma.open_workday(p_occurred_at timestamptz default now())
returns cma.workday
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_user   uuid := cma.current_user_id();
  v_tz     text;
  v_date   date;
  v_status uuid;
  w        cma.workday;
begin
  if v_user is null then
    raise exception 'open_workday needs app.user_id, the acting user' using errcode = 'CMA01';
  end if;
  if not exists (select 1 from cma.app_user where tenant_id = v_tenant and id = v_user and status = 'active') then
    raise exception 'user % is not an active user of the current tenant', v_user using errcode = 'CMA01';
  end if;

  v_tz   := cma.user_timezone(v_user);
  v_date := cma.business_date(p_occurred_at, v_tz);

  select * into w from cma.workday
  where tenant_id = v_tenant and user_id = v_user and business_date = v_date;
  if found then
    -- Clock in again (0008zp): the person's own ended day, while the rule holds
    if w.status = 'ended' and cma.workday_can_clock_in_again(w.id, p_occurred_at) then
      select * into w from cma.workday where tenant_id = v_tenant and id = w.id for update;
      if cma.workday_can_clock_in_again(w.id, p_occurred_at) then
        select id into v_status from cma.work_status
        where tenant_id = v_tenant and is_default and status = 'active';
        if v_status is null then
          raise exception 'no default work status configured for this tenant' using errcode = 'CMA05';
        end if;
        insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source)
        values (v_tenant, w.id, v_user, 'start', v_status, p_occurred_at, 'user');
        perform cma.refresh_workday(w.id);
        select * into w from cma.workday where tenant_id = v_tenant and id = w.id;
      end if;
    end if;
    return w;
  end if;

  -- Nothing exists yet: only a person whose time is kept gets a day
  perform cma.assert_time_kept(v_user);

  -- and only from the window start of its date
  if p_occurred_at < cma.business_day_start(v_date, v_tz) then
    raise exception 'the workday starts at %', to_char(cma.setting_of(v_tenant, 'workday.window_start')::time, 'HH24:MI')
      using errcode = 'CMA04';
  end if;

  select id into v_status from cma.work_status
  where tenant_id = v_tenant and is_default and status = 'active';
  if v_status is null then
    raise exception 'no default work status configured for this tenant' using errcode = 'CMA05';
  end if;

  begin
    insert into cma.workday (tenant_id, user_id, business_date, timezone, status, started_at)
    values (v_tenant, v_user, v_date, v_tz, 'open', p_occurred_at)
    returning * into w;
  exception
    when unique_violation then          -- a second tab opened the same day a moment earlier
      select * into w from cma.workday
      where tenant_id = v_tenant and user_id = v_user and business_date = v_date;
      return w;
  end;

  insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source)
  values (v_tenant, w.id, v_user, 'start', v_status, p_occurred_at, 'user');

  perform cma.refresh_workday(w.id);
  select * into w from cma.workday where tenant_id = v_tenant and id = w.id;
  return w;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. Grants: the rule is the application's only
-- ---------------------------------------------------------------------------------------------
-- refresh_workday and open_workday keep their privileges (create or replace)
revoke execute on function cma.workday_can_clock_in_again(uuid, timestamptz) from public, cma_readonly;
grant execute on function cma.workday_can_clock_in_again(uuid, timestamptz) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 6. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008zp', 'Split shifts: the setting workday.clock_in_again (default false); cma.workday_can_clock_in_again, the one rule (own log out, strictly after it, the same business date within the workday window, time kept); cma.refresh_workday validates a day of one or more sessions (start, statuses, end, start, ...: a later start directly after an end and strictly after it, nothing between an end and the next start, at most the last session open; started_at the first start, ended_at the last end); cma.open_workday clocks in again on such a day under a lock with the rule checked again, every other day unchanged')
on conflict (version) do nothing;

commit;
reset role;
