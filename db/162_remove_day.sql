-- =============================================================================================
-- 162_remove_day.sql: addition 0009g, Remove day: a person holding workday.team voids a whole workday in one correction
-- with a reason
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics: who may remove a day is the permission workday.team, the one
-- cma.correct_workday requires, held by whichever roles a tenant gives it. Runs unchanged in every database, after
-- 160_installed_base_now.sql (0009f). Rerunnable, forward-only, in one transaction with a lock timeout. Run as your own
-- IAM login: dev first, then 163_verify_remove_day.sql there (dev only, as briefed), then the verifies that read
-- cma.open_workday again (unchanged, still PASS): 07, 14, 16, 18, 20, 27, 43, 45, 47, 111 and 127; then the merge; then
-- prod right after the merge: 162, then the same eleven verifies, without 163. main's web runs unchanged on it (no function it calls changes its name, arguments or answers;
-- cma.open_workday answers differently only on a removed day, which main cannot make). This branch's web on a database
-- without it: Remove day answers "not removed" (the function does not exist) and nothing else changes. No table, view,
-- column or setting changes: the data map's schema does not change.
--
-- Why (Martin, 9 November 2026; brief 0009g; Decision log, 9 Nov 2026, Remove day): time data is append-only (Decision
-- log, 5 October 2026): a correction is a new row with a reason and an approver, and nobody corrects their own day. The
-- day editor refuses an empty day, so a day that should not exist (a test clock-in) could not be removed. Remove day
-- voids every effective event of the day in one correction, as cma.void_import_batch (0008d) withdraws an import's days:
-- no fact is deleted, the day then has no effective event, and every reader already treats such a day as no day.
--
-- What it adds
--   cma.remove_workday(p_workday_id, p_reason)  one transaction under the caller's tenant: every effective event of the
--                      day (start, status and end events no correction supersedes) gets a void correction, source
--                      'correction', the reason, approved_by the caller, all at one instant (occurred_at and recorded_at
--                      the transaction's now(), so the rows read as one correction, as the import void writes them).
--                      The caller's rights, like cma.correct_workday (an invoker function: under cma_app row-level
--                      security keeps it to the tenant, and every query filters on cma.current_tenant_id() as well).
--                      Refusals, in this order:
--                        CMA06  without workday.team (cma.assert_permission, the right correct_workday requires);
--                               CMA01 without an acting user or for an inactive one
--                        CMA02  no day with this id in the caller's tenant (another tenant's day, an unknown or no id)
--                        CMA06  the caller's own day: "nobody corrects their own day", correct_workday's message
--                        CMA04  a reason shorter than 3 or longer than 500 characters after trimming,
--                               correct_workday's message
--                        CMA04  "this day has already been removed": the day has no effective event
--                        CMA04  "end the day before removing it": the day is open, today's or an earlier date's (an
--                               open day's header would stay open with nothing behind it, and the person would read
--                               as clocked in on the Live board and in cma.is_clocked_in)
--                      A day of an import batch may be removed too: the batch keeps its record (status, counts, the
--                      days it wrote); a later void of the batch voids what is still effective, so nothing on that day.
--                      Answers the day's header, unchanged: cma.refresh_workday is not called (it refuses a day without
--                      a start), so the header keeps its last status, start and end, as a withdrawn batch's days do
--   cma.open_workday   (based on 126): on a removed day of the date (a day with no effective event: a removed day or a
--                      withdrawn import's), Clock in starts the day again as on a date without one: the same conditions
--                      (the person's time kept, CMA06; not before the window start, CMA04 "the workday starts at
--                      HH:MI"), a start of source 'user' in the tenant's default status at p_occurred_at, under the
--                      day's lock (two tabs give one start: the second waits for the first's lock and then finds the
--                      start). Before, Clock in returned such a day as it was, ended, so a person whose day of today was
--                      removed could not clock in again that day and My day, which reads the summary, found no day.
--                      Every other case is unchanged: the clock in again of 0008zp, an existing day returned as it is, a
--                      new day
--
-- How the readers treat a removed day (checked against each one's current text; nothing is redefined for it)
--   cma.workday_summary_all, cma.workday_summary (134) and cma_read.workday_summary (134): a day without an effective
--                      start is no day (sessions > 0): no row. So 0 worked and 0 paid in every total, and not listed in
--                      Team hours (cma.team_hours), My hours, My day, the hours export (cma.export_hours) or the Live
--                      board (cma.team_now: no day today), exactly as a withdrawn batch's days (0008d)
--   cma.time_interval_all and its faces (134): no effective start or status event, so no stretch: Reports → Dashboard's
--                      time per status (cma.team_status_time) and the status-changes export read nothing for the day
--   cma.team_day (50): every event of the day with is_effective false, the voids with the reason and the approver's name:
--                      the day editor's history; Add day on the date shows that history and writes a new start
--                      (cma.correct_workday finds the day and takes the start; the day counts again)
--   cma_read.workday and cma_read.time_event (05): the header and every event as stored, as for a withdrawn batch's days
--
-- SQLSTATEs as before: CMA01 no acting user, CMA02 not found, CMA04 invalid, CMA05 tenant configuration missing, CMA06
-- not permitted.
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
  if not exists (select 1 from cma.schema_migration where version = '0009f') then
    raise exception 'addition 0009f (160_installed_base_now.sql) must run before 0009g';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Remove day
-- ---------------------------------------------------------------------------------------------
-- Every effective event of one day voided by one correction of the caller (see the header). The day's row is locked
-- first, as cma.correct_workday locks it, so a correction or a removal of the same day waits for this one and then finds
-- the day as this one left it (already removed: CMA04).
create or replace function cma.remove_workday(p_workday_id uuid, p_reason text)
returns cma.workday
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_actor  uuid;
  v_reason text := btrim(coalesce(p_reason, ''));
  w        cma.workday;
begin
  v_actor := cma.assert_permission('workday.team');

  select * into w from cma.workday where tenant_id = v_tenant and id = p_workday_id for update;
  if not found then
    raise exception 'workday % not found in the current tenant', p_workday_id using errcode = 'CMA02';
  end if;
  if w.user_id = v_actor then
    raise exception 'nobody corrects their own day' using errcode = 'CMA06';
  end if;
  if length(v_reason) < 3 or length(v_reason) > 500 then
    raise exception 'a correction needs a reason of 3 to 500 characters' using errcode = 'CMA04';
  end if;
  if not exists (select 1 from cma.time_event_effective e where e.tenant_id = v_tenant and e.workday_id = w.id) then
    raise exception 'this day has already been removed' using errcode = 'CMA04';
  end if;
  if w.status = 'open' then
    raise exception 'end the day before removing it' using errcode = 'CMA04';
  end if;

  -- One void per effective event, all at the transaction's instant: one correction, one reason, one approver
  insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, recorded_at, source,
                              supersedes_event_id, reason, approved_by)
  select v_tenant, w.id, w.user_id, 'void', null, now(), now(), 'correction', e.id, v_reason, v_actor
  from cma.time_event_effective e
  where e.tenant_id = v_tenant and e.workday_id = w.id
  order by e.occurred_at, e.recorded_at, e.id;

  return w;
end
$$;
alter function cma.remove_workday(uuid, text) owner to cma_owner;
revoke execute on function cma.remove_workday(uuid, text) from public;
grant execute on function cma.remove_workday(uuid, text) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 2. Clock in on a removed day of the date
-- ---------------------------------------------------------------------------------------------
-- open_workday as 0008zp defined it, with one branch before its clock in again: a day of the date with no effective
-- event (a removed day, or a withdrawn import's) is no day, so Clock in starts it as on a date without one (see the
-- header). The checks run again under the day's lock. The same signature and result; its rights stay as they are.
-- based on: 126_workday_sessions.sql
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
    -- A removed day (0009g): no effective event left, so it is no day; Clock in starts it as on a date without one
    if not exists (select 1 from cma.time_event_effective e where e.tenant_id = v_tenant and e.workday_id = w.id) then
      select * into w from cma.workday where tenant_id = v_tenant and id = w.id for update;
      if not exists (select 1 from cma.time_event_effective e where e.tenant_id = v_tenant and e.workday_id = w.id) then
        perform cma.assert_time_kept(v_user);
        if p_occurred_at < cma.business_day_start(w.business_date, w.timezone) then
          raise exception 'the workday starts at %', to_char(cma.setting_of(v_tenant, 'workday.window_start')::time, 'HH24:MI')
            using errcode = 'CMA04';
        end if;
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
      return w;
    end if;
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
-- 3. The addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009g', 'Remove day: cma.remove_workday(workday, reason) voids every effective event of a day in one correction (source correction, the reason, approved_by the caller, one instant), for workday.team, never the caller''s own day, never an open day, never twice; invoker rights like cma.correct_workday; the day then has no effective event, so the summary, Team hours, the exports and the Live board treat it as no day, as a withdrawn import''s days; cma.open_workday (from 126) starts a removed day of the date again on Clock in, as on a date without a day')
on conflict (version) do nothing;

commit;
reset role;
