-- =============================================================================================
-- 254_roster_drives_the_day.sql: addition 0010a, the roster drives the agent's day (brief B)
-- =============================================================================================
-- Universal: no customer, tenant, status, market or vendor specifics. Pulse4all Subscriptions' values of the two new
-- settings and its two new absence types are seed data in 02_seed_pulse4all.sql, never code. Runs unchanged in every
-- database, after 252_roster_pause_no_market.sql (0009zz); it refuses to run before 0009zz is recorded. After 0009zz the
-- additions continue as 0010a, 0010b, … (the lettering of 6 Nov 2026, one level up). #331 holds 0009zw with 246/247 and
-- #334 0009zy with 250/251; this needs nothing of either and they need nothing of this, so the guard asks for 0009zz only
-- (two PRs on one number are renumbered in merge order, Decision log, 25 Nov 2026). Rerunnable, forward-only, in one
-- transaction with a lock timeout.
-- Run as your own IAM login: dev first, then 255_verify_roster_drives_the_day.sql there (normal, then provoked), then the
-- verifies that read what this changes (below), then 02_seed_pulse4all.sql again (the settings and the two absence
-- types), then 131_time_all.sql parts a and b (the rows 'my day' and 'my hours week' in a, 'roster switch' in b); then
-- prod, before the merge:
-- this script, 255 and the same verifies, then 02. Main's web keeps working on it until the merge (cma.set_status keeps
-- its first four arguments, a 2- to 4-argument call reaching the new one through the defaults; cma.open_workday keeps its
-- signature; cma.roster_assignments keeps every earlier column), but it meets the new rules in a tenant with assignment
-- types, so keep the gap between prod's migration and the merge short: Publish and a change to today refuse a shift
-- without blocks (main's planner says only that it failed), a work block without a market for a person without a Default
-- market is refused, a cell of today drawn without blocks waits unpublished, and main's My day market select on a pause
-- or on Training, Meeting or Coaching is refused (CMA04: they have no hours market since E1).
--
-- Why (Martin, 26 November 2026, brief B "Assignments for the agent (My day, Switch, My hours) and the roster follows the
-- day"; Decision log, 26 Nov 2026, E1 to E12; the screens Arno and Kira approved that day): briefs A (#332) and #335
-- built the planner. This makes the published plan drive the agent's day: the time events carry the assignment and its
-- market (E1), the CMA switches the agent along today's published roster (E2, E3), Clock in starts on the plan (E4, E5),
-- the agent deviates only through Switch (E6), sees when they are off plan and goes back with one click (E7), keeps the
-- assignment they are on after the shift (E8), an absence block ends the day (E9), every work block names its market
-- (E10), and My day and My hours show Scheduled against Actual, read only (E11). Brief C (Live, Team hours corrections of
-- assignment and market, month close, the invoicing export) follows and needs no schema change: it reuses
-- cma.roster_plan_of (the published blocks with their instants), cma.workday_actual_of (the stretches with their
-- assignment, market and deviation) and the off-plan rule of cma.my_day.
--
-- What it adds
--   settings            roster.switch_notice_minutes (integer, default 5; 0 to 60): how long My day shows a roster
--                       switch (E3); roster.fallback_status (text, default empty: the tenant's default status): the work
--                       status a Clock in starts on when today's shift has no blocks (E5's safety net), an active
--                       working status of the tenant (trigger check_roster_setting, CMA04)
--   permission          workday.roster_switch: the scheduler's system user only (no default role), as
--                       workday.close_forgotten; cma.ensure_scheduler_user grants it to each tenant's Scheduler
--   cma.time_event.assignment_type_id
--                       the Assignment type a start or status event books (E1); null: no assignment (Training, Meeting,
--                       Coaching, the fallback, a tenant without assignment types, and all history before 0010a).
--                       Foreign key to a type of the same tenant and check time_event_assignment_kind (only a start or a
--                       status event carries one), both not valid (every existing row is null; they hold for every new
--                       row). Trigger cma.time_event_assignment_ok (before insert, and before an owner's update of the
--                       type, status, market or kind): a work type books its work status under an hours market, a pause
--                       type its status without a market, an extra type (X) a working status under an hours market; a
--                       correction that supersedes an event and books the same status keeps that event's assignment when
--                       the market rule still holds (so a time correction never erases it; brief C corrects the
--                       assignment itself)
--   cma.time_event.source  gains 'roster': a status event or an end the roster wrote (E2, E9); the check is re-added NOT
--                       VALID (no scan under the lock; every existing row already holds it)
--   cma.roster_assignment.absence_type_id
--                       E9's absence block. A block is either an assignment or an absence, never both: assignment_type_id
--                       loses its not null and check roster_assignment_one_kind holds (assignment_type_id is null) <>
--                       (absence_type_id is null); check roster_assignment_absence_no_market: an absence block has no
--                       hours market. The overlap rule (roster_assignment_no_overlap) covers both kinds, so an absence
--                       block and an assignment never share a slot
--   functions
--     cma.roster_plan_of(user, date)    the person's published blocks of a date (the roster week of their latest
--                                       published entry, a shift), each with its kind (work, pause, absence), type or
--                                       absence, its hours market (a work block's own, else the Default market) and its
--                                       instants in the person's zone. Internal, as cma.roster_published_blocks_json
--     cma.workday_actual_of(workday)    the day's stretches with their status, assignment, market, source and whether
--                                       they deviate from the published block in force at their start. Internal
--     cma.my_day(date)                  workday.own: the plan, the Actual lane, the own switches that deviate, plan now
--                                       and next, the roster switch notice (E3), Off plan (E7) and the Switch choices
--                                       (E6), as one JSON document
--     cma.my_hours(week)                workday.own: the week per assignment and market, the pauses apart, per day the
--                                       Actual lane and the split, the planned minutes (E11: read only)
--     cma.roster_switch_due(at)         workday.roster_switch: E2, E8 and E9 for the current tenant, idempotent per
--                                       person and boundary; source 'roster'
--     cma.roster_switch_all(at)         SECURITY DEFINER (search path pg_catalog, cma, pg_temp), cma_app only, refused
--                                       inside a request (a tenant or user set): one statement for all tenants, each
--                                       served as its own Scheduler user; answers counts per tenant, no person's id
--
-- What it changes (each from its latest earlier definition, named on the line above its create)
--   cma.check_roster_setting()           the two new settings
--   cma.set_status(uuid, text, timestamptz, text) → (… , text p_assignment_code)
--                                        E1 and E6: with an assignment code, the type's status under the chosen market
--                                        (a work or extra type: the market given, else the Default market; a pause: none);
--                                        without one, a status alone as before, except in a tenant that has assignment
--                                        types, where a pause status or a working status no type books (Training,
--                                        Meeting, Coaching) books no market; a market alone re-books the assignment in
--                                        force under it (a pause or an Other status refuses it, CMA04). The 4-argument
--                                        signature is dropped; a 2- to 4-argument call reaches this one
--   cma.open_workday(timestamptz)        E4, E5: Clock in (a new day, a removed day started again, a later session)
--                                        starts on the published block running at that moment with its market; before
--                                        the first block on the first; on an absence block or a pause gap on the next
--                                        work block, else the last; a day without blocks on roster.fallback_status (else
--                                        the default status) with the D4 market, as before
--   cma.roster_assignment_rules()        an absence block: an absence type of the tenant
--   cma.roster_put_assignments(5 args)   absence blocks ({"absence": "<key>", "start", "end"}); a work block written
--                                        without a market gets the person's Default market (E10); strict, a person
--                                        without one is refused (CMA04)
--   cma.roster_blocks_json, cma.roster_published_blocks_json
--                                        absence blocks (code null, kind absence, absenceKey, absenceName)
--   cma.roster_assignments(date, text)   absence_key and absence_name appended last (dropped and created)
--   cma.roster_publish(date, text)       E5: refuses (CMA04, detail empty_shifts=<json of user and date>) while a shift of
--                                        the week dated today or later for its person has no block at all
--   cma.roster_set_cell(10 args)         D8's at-once publication waits when the person's shift today has no block yet
--                                        (answer waiting no_assignments): the planner adds the blocks, which publish it
--   cma.ensure_scheduler_user(uuid)      grants workday.roster_switch
--   views                                cma.roster_published_assignment_all and its face gain absence_type_id last;
--                                        cma_read.time_event, cma_read.time_interval gain assignment_type_id last;
--                                        cma_read.roster_assignment and cma_read.roster_published_assignment gain
--                                        absence_type_id last
--   data                                 E10's backfill: every current or ended work block without a market gets the
--                                        person's Default market on the block's date (the audit trail's value at the end
--                                        of that date, else today's); an owner's update in place, recorded in
--                                        cma.audit_log (the planner's history is otherwise insert-only, D7)
--
-- Verifies that read what this changes, run again after this script (grep -lw 'cma\.<function>' db/*verify*.sql, and the
-- functions that call them); run locally on a database at 253 plus this script, each PASS:
--   249_verify_roster_assignments.sql    edited by this change: since E5 its throwaway tenant's shifts get a block before
--                                        Publish (B4, B6), and since E10 a work block stores a market (B3, B4, B7, B10 read
--                                        GO under NL or GB where they read own market)
--   253_verify_roster_pause_no_market.sql
--                                        edited by this change: E10 stores a1's own-market SL under NL (B1, B3 to B7), and
--                                        R2 compares roster_assignments' thirteen earlier columns by name, absences aside
--   231_verify_hours_market.sql          edited by this change: S2 reads the readers' views' last column before
--                                        assignment_type_id, S3 takes set_status's 5-argument signature; its behaviour
--                                        checks (a tenant without assignment types) are unchanged and pass
--   27_verify_configuration.sql          edited by this change: verify.job_permissions gains workday.roster_switch
--   135_verify_hours_reads.sql           edited by this change: S8 expects assignment_type_id after hours_market_code in
--                                        cma_read.time_interval where 0010a is recorded
--   25_verify_roster.sql, 199_verify_roster_planned.sql, 07_verify_time_model.sql, 10_verify_corrections.sql,
--   14_verify_tenant_settings.sql, 16_verify_team_status_time.sql, 18_verify_clock_in_app_links.sql, 20_verify_team_now.sql,
--   43_verify_messaging.sql, 45_verify_assignment_alerts.sql, 47_verify_workday_window.sql, 51_verify_legacy_time_import.sql,
--   111_verify_import_status_reuse.sql, 127_verify_workday_sessions.sql, 163_verify_remove_day.sql,
--   201_verify_live_paid_today.sql, 229_verify_work_area.sql, 245_verify_auto_close_office_hours.sql,
--   123_verify_flash.sql, 169_verify_pledge_lists.sql, 173_verify_active_customers.sql, 175_verify_active_refresh_quiet.sql,
--   179_verify_job_reads.sql, 185_verify_active_device_bands.sql, 237_verify_jobs_off_the_vcpu.sql
--                                        unchanged: they read set_status or open_workday (directly or through
--                                        correct_workday, correct_time_event and remove_workday, whose events pass the new
--                                        trigger untouched without an assignment), cma_read.time_event, or the scheduler's
--                                        permissions (create_tenant calls ensure_scheduler_user); their tenants have no
--                                        assignment types, so E5 refuses nothing there and a status alone keeps 0009zo's
--                                        market rule; 127's and 163's patterns of open_workday's definition hold
-- The planner's other reads take absence blocks without a change: save_standard_week, roster_slot_coverage,
-- roster_planned_hours and roster_copy_week_report join the assignment type, so an absence block is never saved into the
-- Standard week, copied, or counted as planned or working (E9).
-- 131_time_all.sql: three rows: 'my day' and 'my hours week' in part a (class agent), 'roster switch' in part b (the minute
-- job per tenant as its scheduler, against the poll budget, beside the jobs' gate).
--
-- SQLSTATEs as 0005's: CMA01 no acting user, CMA02 not found, CMA03 conflict, CMA04 invalid, CMA05 tenant configuration
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
select set_config('app.actor_label', 'migration:0010a', true);

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0009zz') then
    raise exception 'addition 0009zz (252_roster_pause_no_market.sql) must run before 0010a';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Settings and the permission (E3, E5, E2)
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('roster.switch_notice_minutes', 'integer', null, '5',
     'Minutes My day shows the line that the roster switched the agent (0 to 60); it goes earlier at the agent''s own Switch or the next roster switch'),
  ('roster.fallback_status', 'text', null, '',
     'Work status key a Clock in starts on when today''s shift has no blocks (a week published before shifts needed assignments); empty: the tenant''s default status')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

insert into cma.permission (key, description) values
  ('workday.roster_switch', 'Switch agents along today''s published roster and end a workday at an absence block (the scheduler''s system user only; no default role)')
on conflict (key) do update set description = excluded.description;

-- 248's check with the two new settings: the notice minutes 0 to 60, the fallback an active working status or empty
-- based on: 248_roster_assignments.sql
create or replace function cma.check_roster_setting()
returns trigger
language plpgsql
as $$
begin
  if new.key = 'roster.planner_timezone' and new.value <> '' and not cma.is_timezone(new.value) then
    raise exception 'roster.planner_timezone takes an IANA zone (Area/City), or empty for the tenant''s zone; got %', new.value
      using errcode = 'CMA04';
  end if;
  if new.key = 'roster.switch_notice_minutes' and (new.value !~ '^[0-9]{1,2}$' or new.value::integer > 60) then
    raise exception 'roster.switch_notice_minutes takes 0 to 60 minutes; got %', new.value using errcode = 'CMA04';
  end if;
  if new.key = 'roster.fallback_status' and new.value <> '' and not exists (
       select 1 from cma.work_status s
       where s.tenant_id = new.tenant_id and s.key = new.value and s.status = 'active' and s.is_working) then
    raise exception 'roster.fallback_status takes the key of an active working status of the tenant, or empty for its default status; got %',
      new.value using errcode = 'CMA04';
  end if;
  return new;
end
$$;
revoke execute on function cma.check_roster_setting() from public;

-- 172's Scheduler user with the roster switch (E2): every tenant's system role holds it
-- based on: 172_active_customers.sql
create or replace function cma.ensure_scheduler_user(p_tenant_id uuid)
returns uuid
language plpgsql
as $$
declare
  v_role uuid;
  v_user uuid;
begin
  insert into cma.app_role (tenant_id, key, name, is_system, is_assignable)
  values (p_tenant_id, 'scheduler', 'Scheduler', true, false)
  on conflict (tenant_id, key) do update set is_assignable = false, is_system = true
  returning id into v_role;
  if v_role is null then
    select id into v_role from cma.app_role where tenant_id = p_tenant_id and key = 'scheduler';
  end if;
  insert into cma.role_permission (tenant_id, role_id, permission_key)
  values (p_tenant_id, v_role, 'workday.close_forgotten'), (p_tenant_id, v_role, 'follow_up.refresh'), (p_tenant_id, v_role, 'flash.snapshot'),
         (p_tenant_id, v_role, 'data_quality.refresh'), (p_tenant_id, v_role, 'pledges.snapshot'), (p_tenant_id, v_role, 'customers.refresh'),
         (p_tenant_id, v_role, 'workday.roster_switch')
  on conflict do nothing;

  insert into cma.app_user (tenant_id, email, display_name, status, kind)
  values (p_tenant_id, 'scheduler@system.invalid', 'Scheduler', 'active', 'system')
  on conflict (tenant_id, email) do update set kind = 'system', status = 'active'
  returning id into v_user;
  if v_user is null then
    select id into v_user from cma.app_user where tenant_id = p_tenant_id and email = 'scheduler@system.invalid';
  end if;
  insert into cma.user_role (tenant_id, user_id, role_id)
  values (p_tenant_id, v_user, v_role)
  on conflict do nothing;
  insert into cma.app_user_external_id (tenant_id, user_id, system, external_id)
  values (p_tenant_id, v_user, 'scheduler', 'scheduler')
  on conflict do nothing;
  return v_user;
end
$$;
revoke execute on function cma.ensure_scheduler_user(uuid) from public;

do $$
declare
  t record;
begin
  for t in select id from cma.tenant loop
    perform cma.ensure_scheduler_user(t.id);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. The rules of an event's assignment (E1), checked in the table whoever writes
-- ---------------------------------------------------------------------------------------------
-- Before insert (and an owner's update of the type, status, market or kind): an event with an assignment type books
--   a work type     its work status, under an hours market
--   a pause type    its work status, without a market
--   an extra type   a working status (the one the agent is on), under an hours market
-- A correction that supersedes an event and books the same status keeps that event's assignment when the rule above
-- still holds for it (a time correction never erases the assignment; a status or market correction that breaks the
-- rule books no assignment, and brief C corrects the assignment itself). The type is of the event's tenant (the foreign
-- key); a retired type stays on the events booked under it
create or replace function cma.time_event_assignment_ok()
returns trigger
language plpgsql
as $$
declare
  t      cma.assignment_type;
  v_old  cma.time_event;
  v_work boolean;
begin
  if tg_op = 'INSERT' and new.assignment_type_id is null and new.source = 'correction' and new.supersedes_event_id is not null
     and new.kind in ('start', 'status') then
    select * into v_old from cma.time_event x where x.tenant_id = new.tenant_id and x.id = new.supersedes_event_id;
    if v_old.assignment_type_id is not null and v_old.status_id = new.status_id then
      select * into t from cma.assignment_type x where x.tenant_id = new.tenant_id and x.id = v_old.assignment_type_id;
      if (t.kind = 'pause' and new.hours_market_code is null) or (t.kind = 'work' and new.hours_market_code is not null) then
        new.assignment_type_id := v_old.assignment_type_id;
      end if;
    end if;
  end if;
  if new.assignment_type_id is null then
    return new;
  end if;
  if new.kind not in ('start', 'status') then
    raise exception 'only a start or a status event carries an assignment' using errcode = 'CMA04';
  end if;
  select * into t from cma.assignment_type x where x.tenant_id = new.tenant_id and x.id = new.assignment_type_id;
  if t.id is null then
    raise exception 'assignment type % is no type of the tenant', new.assignment_type_id using errcode = 'CMA02';
  end if;
  if t.is_extra then
    select s.is_working into v_work from cma.work_status s where s.tenant_id = new.tenant_id and s.id = new.status_id;
    if not coalesce(v_work, false) then
      raise exception 'assignment % (extra) books a working status', t.code using errcode = 'CMA04';
    end if;
  elsif new.status_id is distinct from t.work_status_id then
    raise exception 'assignment % books its own work status', t.code using errcode = 'CMA04';
  end if;
  if t.kind = 'pause' and new.hours_market_code is not null then
    raise exception 'assignment % is a pause, and a pause has no hours market', t.code using errcode = 'CMA04';
  end if;
  if t.kind = 'work' and new.hours_market_code is null then
    raise exception 'assignment % is work, booked under an hours market', t.code using errcode = 'CMA04';
  end if;
  return new;
end
$$;
revoke execute on function cma.time_event_assignment_ok() from public, cma_readonly, cma_app;

-- 252's insert rule of a block, with E9's absence block: an absence type of the tenant (the checks of section 9 hold
-- the one kind and the absence's missing market); an assignment block as before
-- based on: 252_roster_pause_no_market.sql
create or replace function cma.roster_assignment_rules()
returns trigger
language plpgsql
as $$
declare
  v_slot integer := cma.setting_of(new.tenant_id, 'roster.slot_minutes')::integer;
  v_start integer := (extract(epoch from new.start_time) / 60)::integer;
  v_end integer := (extract(epoch from new.end_time) / 60)::integer;
begin
  if v_start % v_slot <> 0 or v_end % v_slot <> 0 then
    raise exception 'an assignment starts and ends on the % minute grid; got % to %', v_slot,
      to_char(new.start_time, 'HH24:MI'), case when v_end = 1440 then '24:00' else to_char(new.end_time, 'HH24:MI') end
      using errcode = 'CMA04';
  end if;
  if new.absence_type_id is not null then
    if new.hours_market_code is not null then
      raise exception 'an absence block has no hours market (got %)', new.hours_market_code using errcode = 'CMA04';
    end if;
    if not exists (select 1 from cma.absence_type a where a.tenant_id = new.tenant_id and a.id = new.absence_type_id) then
      raise exception 'absence type % is no absence type of the tenant', new.absence_type_id using errcode = 'CMA02';
    end if;
    return new;
  end if;
  -- A pause is no work under a market: a block of kind pause has no hours market (Martin, 26 November 2026); checked
  -- first, so a pause with any market gets this reason
  if new.hours_market_code is not null and exists (
       select 1 from cma.assignment_type t
       where t.tenant_id = new.tenant_id and t.id = new.assignment_type_id and t.kind = 'pause') then
    raise exception 'a pause has no hours market: plan it without one (got %)', new.hours_market_code using errcode = 'CMA04';
  end if;
  if new.hours_market_code is not null and not exists (
       select 1 from cma.market m
       where m.tenant_id = new.tenant_id and m.code = new.hours_market_code and m.hours_market_code = m.code) then
    raise exception 'market % is no hours market of the tenant', new.hours_market_code using errcode = 'CMA04';
  end if;
  return new;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. The plan of a person's day and the Actual of a workday (internal reads; brief C's Live reuses both)
-- ---------------------------------------------------------------------------------------------
-- The person's published blocks of a date: those of the roster week of their latest published entry for the date, when
-- that entry is a shift (a whole-day absence has none). kind is the type's (work, pause) or 'absence'; a work block's
-- hours market is its own, else the person's Default market (blocks before 0010a's backfill without one); a pause and an
-- absence have none. The instants are the local times in the person's zone, as the shift's. Internal: no permission of its
-- own; its callers pass the acting user (my_day, my_hours, open_workday) or the tenant's people under the scheduler's
-- permission (roster_switch_due). Never call it from a route with a request's person
create or replace function cma.roster_plan_of(p_user_id uuid, p_date date)
returns table (
  block_id            uuid,
  kind                text,
  assignment_type_id  uuid,
  code                text,
  name                text,
  is_extra            boolean,
  work_status_id      uuid,
  work_area           text,
  absence_type_id     uuid,
  absence_key         text,
  hours_market_code   text,
  start_time          time,
  end_time            time,
  starts_at           timestamptz,
  ends_at             timestamptz
)
language plpgsql stable rows 20
as $$
#variable_conflict use_column
declare
  v_week    uuid;
  v_kind    text;
  v_zone    text;
  v_default text;
begin
  select e.roster_week_id, e.kind into v_week, v_kind
  from cma.roster_published_entry e
  where e.user_id = p_user_id and e.business_date = p_date
  order by e.published_at desc
  limit 1;
  if v_week is null or v_kind <> 'shift' then
    return;
  end if;
  v_zone := cma.user_timezone(p_user_id);
  select u.default_hours_market_code into v_default
  from cma.app_user u where u.tenant_id = cma.current_tenant_id() and u.id = p_user_id;
  return query
    select a.id,
           case when a.absence_type_id is not null then 'absence' else t.kind end::text,
           a.assignment_type_id, t.code::text, coalesce(t.name, b.name)::text, coalesce(t.is_extra, false), t.work_status_id,
           s.work_area::text, a.absence_type_id, b.key::text,
           case when t.kind = 'work' then coalesce(a.hours_market_code, v_default) end::text,
           a.start_time, a.end_time,
           (p_date + a.start_time) at time zone v_zone,
           (p_date + a.end_time) at time zone v_zone
    from cma.roster_published_assignment a
    left join cma.assignment_type t on t.tenant_id = a.tenant_id and t.id = a.assignment_type_id
    left join cma.work_status s on s.tenant_id = a.tenant_id and s.id = t.work_status_id
    left join cma.absence_type b on b.tenant_id = a.tenant_id and b.id = a.absence_type_id
    where a.roster_week_id = v_week and a.user_id = p_user_id and a.business_date = p_date
    order by a.start_time;
end
$$;

-- The stretches of one workday of the current tenant, in order: the status, the assignment and the market the event
-- that opened each stretch booked, its source, and the published block in force at its start (not an absence) with
-- whether the stretch deviates from it (another assignment or another market). A stretch without a block in force (a
-- gap, before or after the shift, a day without a plan) never deviates. Internal: my_day and my_hours pass the acting
-- user's own day
create or replace function cma.workday_actual_of(p_workday_id uuid)
returns table (
  event_id            uuid,
  event_kind          text,
  source              text,
  from_at             timestamptz,
  to_at               timestamptz,
  is_open             boolean,
  seconds             bigint,
  status_id           uuid,
  status_key          text,
  status_name         text,
  is_working          boolean,
  work_area           text,
  assignment_type_id  uuid,
  code                text,
  name                text,
  type_kind           text,
  hours_market_code   text,
  planned_type_id     uuid,
  planned_code        text,
  planned_market      text,
  deviates            boolean
)
language plpgsql stable rows 40
as $$
#variable_conflict use_column
declare
  w cma.workday;
begin
  select * into w from cma.workday d where d.tenant_id = cma.current_tenant_id() and d.id = p_workday_id;
  if w.id is null then
    return;
  end if;
  return query
    with plan as materialized (
      select p.* from cma.roster_plan_of(w.user_id, w.business_date) p where p.kind <> 'absence'
    )
    select i.event_id, e.kind::text, e.source::text, i.from_at, i.to_at, i.is_open, i.seconds,
           i.status_id, s.key::text, s.name::text, s.is_working, s.work_area::text,
           e.assignment_type_id, t.code::text, t.name::text, t.kind::text, e.hours_market_code::text,
           p.assignment_type_id, p.code, p.hours_market_code,
           p.block_id is not null and (p.assignment_type_id is distinct from e.assignment_type_id
                                       or p.hours_market_code is distinct from e.hours_market_code)
    from cma.time_interval i
    join cma.time_event e on e.tenant_id = cma.current_tenant_id() and e.id = i.event_id
    join cma.work_status s on s.tenant_id = cma.current_tenant_id() and s.id = i.status_id
    left join cma.assignment_type t on t.tenant_id = cma.current_tenant_id() and t.id = e.assignment_type_id
    left join lateral (
      select x.* from plan x where x.starts_at <= i.from_at and i.from_at < x.ends_at order by x.starts_at limit 1
    ) p on true
    where i.workday_id = w.id
    order by i.from_at, e.recorded_at;
end
$$;

-- What a Clock in at p_at books for the person on the date (E4, E5): the published block running at that moment (not an
-- absence); before it, the next one; after the last, the last (E8). A work block books its type's status under the
-- block's market (else D4's market); an extra block the start status under the block's market; a pause its status
-- without one. Without a block, or when the block cannot be booked (its status retired, no market at all): no
-- assignment, roster.fallback_status when set (else the default status) under D4's market (p_market_again on a later
-- session of a day without a plan: the day's own market, as 0009zo). Internal: open_workday passes the acting user
create or replace function cma.clock_in_choice(p_user_id uuid, p_date date, p_at timestamptz, p_market_again text default null,
                                               out assignment_type_id uuid, out status_id uuid, out hours_market_code text)
language plpgsql stable
as $$
declare
  v_tenant   uuid := cma.current_tenant_id();
  b          record;
  v_start    uuid;
  v_status   uuid;
  v_market   text;
begin
  -- the start status: roster.fallback_status when it is an active working status, else the default status
  select s.id into v_start from cma.work_status s
  where s.tenant_id = v_tenant and s.status = 'active' and s.is_working
    and s.key = nullif(cma.setting_of(v_tenant, 'roster.fallback_status'), '');
  if v_start is null then
    select s.id into v_start from cma.work_status s where s.tenant_id = v_tenant and s.is_default and s.status = 'active';
  end if;

  select p.* into b
  from cma.roster_plan_of(p_user_id, p_date) p
  where p.kind <> 'absence'
  order by case when p.starts_at <= p_at and p_at < p.ends_at then 0 when p.starts_at > p_at then 1 else 2 end,
           case when p.starts_at > p_at then p.starts_at end nulls last,
           p.starts_at desc
  limit 1;

  if b.block_id is not null then
    if b.kind = 'pause' then
      select s.id into v_status from cma.work_status s where s.tenant_id = v_tenant and s.id = b.work_status_id and s.status = 'active';
      if v_status is not null then
        assignment_type_id := b.assignment_type_id; status_id := v_status; hours_market_code := null;
        return;
      end if;
    else
      v_market := coalesce(cma.resolve_hours_market(b.hours_market_code), cma.clock_in_hours_market(p_user_id));
      if b.is_extra then
        v_status := v_start;
      else
        select s.id into v_status from cma.work_status s where s.tenant_id = v_tenant and s.id = b.work_status_id and s.status = 'active';
      end if;
      if v_status is not null and v_market is not null then
        assignment_type_id := b.assignment_type_id; status_id := v_status; hours_market_code := v_market;
        return;
      end if;
    end if;
  end if;

  assignment_type_id := null;
  status_id := v_start;
  hours_market_code := coalesce(p_market_again, cma.clock_in_hours_market(p_user_id));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. The write path: Switch (set_status) and Clock in (open_workday)
-- ---------------------------------------------------------------------------------------------
-- 230's status change with the assignment (E1, E6). With p_assignment_code: the active type of that code; a work type books
-- its work status under p_hours_market_code (an active hours market) or, without one, the person's Default market (D4's
-- order); an extra type books the working status in force (else the start status) the same way; a pause books its status
-- without a market (a market given: CMA04). The same assignment, status and market as in force books nothing and answers
-- the event in force (a repeated click is harmless). Without an assignment: p_status_key books that status; in a tenant
-- that has assignment types a pause status or a working status no active type books (Training, Meeting, Coaching) books
-- no market (E1), otherwise the market is kept as 0009zo kept it (a tenant without assignment types sees no change). A
-- market alone: the assignment in force booked again under it (a work or extra type), or 0009zo's market change for a
-- status no type books in a tenant without types; a pause or an Other status has no market (CMA04)
drop function if exists cma.set_status(uuid, text, timestamptz, text);
drop function if exists cma.set_status(uuid, text, timestamptz, text, text);
-- based on: 230_hours_market.sql
create function cma.set_status(p_workday_id uuid, p_status_key text, p_occurred_at timestamptz default now(),
                               p_hours_market_code text default null, p_assignment_code text default null)
returns cma.time_event
language plpgsql
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_user    uuid := cma.current_user_id();
  v_types   boolean;
  v_status  uuid;
  v_market  text;
  v_type    cma.assignment_type;
  v_cur     cma.work_status;
  v_stat    cma.work_status;
  v_start   uuid;
  w         cma.workday;
  e         cma.time_event;
begin
  if v_user is null then
    raise exception 'set_status needs app.user_id, the acting user' using errcode = 'CMA01';
  end if;
  if p_status_key is null and p_hours_market_code is null and p_assignment_code is null then
    raise exception 'a change needs an assignment, a status, a market or a combination' using errcode = 'CMA04';
  end if;
  if p_assignment_code is not null and p_status_key is not null then
    raise exception 'an assignment books its own status: give the assignment or the status, not both' using errcode = 'CMA04';
  end if;

  select * into w from cma.workday where tenant_id = v_tenant and id = p_workday_id for update;
  if not found or w.user_id <> v_user then
    raise exception 'workday % is not a workday of the acting user', p_workday_id using errcode = 'CMA02';
  end if;
  if w.status = 'ended' then
    raise exception 'workday % is already ended; changes are corrections' , p_workday_id using errcode = 'CMA03';
  end if;
  if p_occurred_at < w.started_at or p_occurred_at > now() + interval '5 minutes' then
    raise exception 'status time must lie between the start of the workday and now' using errcode = 'CMA04';
  end if;

  -- The event in force at the instant: its status, assignment and market are what a change keeps
  select x.* into e
  from cma.time_event x
  where x.tenant_id = v_tenant and x.workday_id = w.id and x.kind in ('start', 'status') and x.occurred_at <= p_occurred_at
    and not exists (select 1 from cma.time_event c where c.tenant_id = x.tenant_id and c.supersedes_event_id = x.id)
  order by x.occurred_at desc, x.recorded_at desc
  limit 1;
  select * into v_cur from cma.work_status s where s.tenant_id = v_tenant and s.id = e.status_id;
  v_types := exists (select 1 from cma.assignment_type t where t.tenant_id = v_tenant and t.status = 'active');

  -- A market alone on an assignment: the assignment in force, booked again under the market
  if p_assignment_code is null and p_status_key is null and e.assignment_type_id is not null then
    select * into v_type from cma.assignment_type t where t.tenant_id = v_tenant and t.id = e.assignment_type_id;
    if v_type.kind = 'pause' then
      raise exception 'assignment % is a pause, and a pause has no hours market', v_type.code using errcode = 'CMA04';
    end if;
    if v_type.status <> 'active' then
      raise exception 'assignment % is no longer in use; switch to another', v_type.code using errcode = 'CMA02';
    end if;
    p_assignment_code := v_type.code;
  end if;

  if p_assignment_code is not null then
    select * into v_type from cma.assignment_type t
    where t.tenant_id = v_tenant and t.code = upper(btrim(p_assignment_code)) and t.status = 'active';
    if v_type.id is null then
      raise exception 'assignment type "%" is not in use in this tenant', p_assignment_code using errcode = 'CMA02';
    end if;
    if v_type.kind = 'pause' then
      if p_hours_market_code is not null then
        raise exception 'assignment % is a pause, and a pause has no hours market', v_type.code using errcode = 'CMA04';
      end if;
      v_status := v_type.work_status_id;
      v_market := null;
    else
      if v_type.is_extra then
        -- extra hours count under the working status the agent is on, else the start status (E5's)
        if coalesce(v_cur.is_working, false) and v_cur.status = 'active' then
          v_status := v_cur.id;
        else
          select s.id into v_start from cma.work_status s
          where s.tenant_id = v_tenant and s.status = 'active' and s.is_working
            and s.key = nullif(cma.setting_of(v_tenant, 'roster.fallback_status'), '');
          if v_start is null then
            select s.id into v_start from cma.work_status s where s.tenant_id = v_tenant and s.is_default and s.status = 'active';
          end if;
          v_status := v_start;
        end if;
      else
        v_status := v_type.work_status_id;
      end if;
      if p_hours_market_code is not null then
        v_market := cma.assert_hours_market(p_hours_market_code);
      else
        v_market := cma.clock_in_hours_market(v_user);
      end if;
      if v_market is null then
        raise exception 'assignment % is booked under an hours market: choose one', v_type.code using errcode = 'CMA04';
      end if;
    end if;
    if not exists (select 1 from cma.work_status s where s.tenant_id = v_tenant and s.id = v_status and s.status = 'active') then
      raise exception 'the status assignment % books is not active in this tenant', v_type.code using errcode = 'CMA05';
    end if;
    if e.id is not null and e.assignment_type_id is not distinct from v_type.id and e.status_id = v_status
       and e.hours_market_code is not distinct from v_market then
      return e;
    end if;
    insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source, hours_market_code,
                                assignment_type_id)
    values (v_tenant, w.id, v_user, 'status', v_status, p_occurred_at, 'user', v_market, v_type.id)
    returning * into e;
    perform cma.refresh_workday(w.id);
    return e;
  end if;

  -- Without an assignment: a status, a market or both (0009zo), with E1's rule for a tenant that has assignment types
  if p_status_key is null then
    v_stat := v_cur;
    if v_stat.id is null or v_stat.status <> 'active' then
      raise exception 'the current status is not active in this tenant; choose a status' using errcode = 'CMA02';
    end if;
  else
    select * into v_stat from cma.work_status
    where tenant_id = v_tenant and key = p_status_key and status = 'active';
    if v_stat.id is null then
      raise exception 'work status "%" is not active in this tenant', p_status_key using errcode = 'CMA02';
    end if;
  end if;

  if v_types and (not v_stat.is_working
                  or not exists (select 1 from cma.assignment_type t
                                 where t.tenant_id = v_tenant and t.status = 'active' and t.work_status_id = v_stat.id)) then
    -- E1: a pause or an Other status (Training, Meeting, Coaching) has no hours market
    if p_hours_market_code is not null then
      raise exception '% has no hours market', v_stat.name using errcode = 'CMA04';
    end if;
    v_market := null;
  elsif p_hours_market_code is null then
    v_market := cma.resolve_hours_market(e.hours_market_code);   -- the market in force, as it books now
  else
    v_market := cma.assert_hours_market(p_hours_market_code);
  end if;

  if p_status_key is null and e.id is not null and e.assignment_type_id is null and v_market is not distinct from e.hours_market_code then
    return e;
  end if;
  if p_status_key is not null and e.id is not null and e.assignment_type_id is null and e.status_id = v_stat.id
     and v_market is not distinct from e.hours_market_code and v_types then
    return e;   -- the same Other status again books nothing (E6's one button for every choice)
  end if;

  insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source, hours_market_code)
  values (v_tenant, w.id, v_user, 'status', v_stat.id, p_occurred_at, 'user', v_market)
  returning * into e;

  perform cma.refresh_workday(w.id);
  return e;
end
$$;
revoke execute on function cma.set_status(uuid, text, timestamptz, text, text) from public, cma_readonly;
grant execute on function cma.set_status(uuid, text, timestamptz, text, text) to cma_app;

-- 230's clock-in with E4 and E5: every start event books cma.clock_in_choice (the published block of that moment, else the
-- fallback status under D4's market; a later session of a day without a plan keeps the day's own market, as 0009zo).
-- Otherwise unchanged, so 127's and 163's pattern checks of its definition still hold
-- based on: 230_hours_market.sql
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
  c        record;
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
        select * into c from cma.clock_in_choice(v_user, w.business_date, p_occurred_at);
        if c.status_id is null then
          raise exception 'no default work status configured for this tenant' using errcode = 'CMA05';
        end if;
        insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source, hours_market_code,
                                    assignment_type_id)
        values (v_tenant, w.id, v_user, 'start', c.status_id, p_occurred_at, 'user', c.hours_market_code, c.assignment_type_id);
        perform cma.refresh_workday(w.id);
        select * into w from cma.workday where tenant_id = v_tenant and id = w.id;
      end if;
      return w;
    end if;
    -- Clock in again (0008zp): the person's own ended day, while the rule holds
    if w.status = 'ended' and cma.workday_can_clock_in_again(w.id, p_occurred_at) then
      select * into w from cma.workday where tenant_id = v_tenant and id = w.id for update;
      if cma.workday_can_clock_in_again(w.id, p_occurred_at) then
        -- A later session starts on the block of that moment too (E4); a day without a plan continues under its own
        -- market (Martin, 23 November 2026): the market in force at its last event, as it books now, else D4's order
        select * into c from cma.clock_in_choice(v_user, w.business_date, p_occurred_at,
                                                 cma.resolve_hours_market(cma.workday_hours_market(w.id)));
        if c.status_id is null then
          raise exception 'no default work status configured for this tenant' using errcode = 'CMA05';
        end if;
        insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source, hours_market_code,
                                    assignment_type_id)
        values (v_tenant, w.id, v_user, 'start', c.status_id, p_occurred_at, 'user', c.hours_market_code, c.assignment_type_id);
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

  select * into c from cma.clock_in_choice(v_user, v_date, p_occurred_at);
  v_status := c.status_id;
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

  insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source, hours_market_code,
                              assignment_type_id)
  values (v_tenant, w.id, v_user, 'start', v_status, p_occurred_at, 'user', c.hours_market_code, c.assignment_type_id);

  perform cma.refresh_workday(w.id);
  select * into w from cma.workday where tenant_id = v_tenant and id = w.id;
  return w;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. The planner: absence blocks (E9), every work block names its market (E10), Publish refuses an empty shift (E5)
-- ---------------------------------------------------------------------------------------------
-- The one writer of blocks (roster.manage), 252's, with E9 and E10; see 248 for the contract. A block is {"code", "start",
-- "end", "hoursMarket", "note"} for an assignment or {"absence": "<key>", "start", "end", "note"} for an absence, never
-- both (CMA04). An absence block lies inside the shift as every block and has no market (strict: CMA04; not strict: written
-- without it); a retired absence type stays on a block kept unchanged, a new block needs an active one. A work block
-- without a market gets the person's Default market at the time of writing (E10; a pause keeps none, 252's rule); strict,
-- a person without an active Default market is refused (CMA04, choose a market); not strict (Copy week, Apply standard
-- week), the block keeps none
-- based on: 252_roster_pause_no_market.sql
create or replace function cma.roster_put_assignments(p_week_id uuid, p_user_id uuid, p_date date, p_blocks jsonb, p_strict boolean)
returns jsonb
language plpgsql
as $$
declare
  v_shift   cma.roster_entry;
  v_slot    integer := cma.setting_of(cma.current_tenant_id(), 'roster.slot_minutes')::integer;
  b         jsonb;
  v_type    cma.assignment_type;
  v_abs     cma.absence_type;
  v_label   text;
  v_start   time;
  v_end     time;
  v_market  text;
  v_note    text;
  v_bad     text;
  v_default text;
  -- the wanted blocks, validated, as a JSON array of {type_id, absence_id, start_time, end_time, market, note} (no
  -- temporary table: a catalog write per call on the application's write path)
  v_want    jsonb := '[]'::jsonb;
  v_kept    integer := 0;
  v_ended   integer := 0;
  v_added   integer := 0;
  v_drop    integer := 0;
begin
  perform cma.assert_permission('roster.manage');
  if p_blocks is null or jsonb_typeof(p_blocks) <> 'array' then
    raise exception 'blocks must be a JSON array' using errcode = 'CMA04';
  end if;
  if jsonb_array_length(p_blocks) > 96 then
    raise exception 'at most 96 blocks per person and date' using errcode = 'CMA04';
  end if;
  -- Its own guards, whoever calls it (defence in depth: its callers check the same first): the past stays locked, and no
  -- current block of the person-date may belong to another roster week, an empty list included
  if p_date < cma.business_date(now(), cma.user_timezone(p_user_id)) then
    raise exception 'date % is in the past for this person; the roster plans today and ahead', p_date using errcode = 'CMA04';
  end if;
  if exists (select 1 from cma.roster_assignment a
             where a.tenant_id = cma.current_tenant_id() and a.user_id = p_user_id and a.business_date = p_date
               and a.valid_to is null and a.roster_week_id <> p_week_id) then
    raise exception 'this person''s assignments on % belong to another roster', p_date using errcode = 'CMA03';
  end if;
  select * into v_shift from cma.roster_entry
   where tenant_id = cma.current_tenant_id() and user_id = p_user_id and business_date = p_date and valid_to is null;
  if jsonb_array_length(p_blocks) > 0 then
    if v_shift.id is null or v_shift.kind <> 'shift' then
      raise exception 'an assignment lies inside a shift: this person has no shift on %', p_date using errcode = 'CMA04';
    end if;
    if v_shift.roster_week_id <> p_week_id then
      raise exception 'this person''s shift on % belongs to another roster', p_date using errcode = 'CMA03';
    end if;
  end if;
  -- E10: the person's Default market at the time of writing, when it is an active hours market
  select u.default_hours_market_code into v_default
  from cma.app_user u where u.tenant_id = cma.current_tenant_id() and u.id = p_user_id;
  if v_default is not null and not cma.is_hours_market(v_default) then
    v_default := null;
  end if;

  for b in select value from jsonb_array_elements(p_blocks) loop
    v_bad := null;
    v_type := null;
    v_abs := null;
    if jsonb_typeof(b) <> 'object' then
      raise exception 'each block is a JSON object' using errcode = 'CMA04';
    end if;
    if nullif(btrim(coalesce(b->>'absence', '')), '') is not null then
      -- E9: an absence block. A block is either an assignment or an absence, never both
      if nullif(btrim(coalesce(b->>'code', '')), '') is not null then
        raise exception 'a block is either an assignment or an absence, not both (got % and %)', b->>'code', b->>'absence'
          using errcode = 'CMA04';
      end if;
      select * into v_abs from cma.absence_type
       where tenant_id = cma.current_tenant_id() and key = lower(btrim(b->>'absence'));
      if v_abs.id is null then
        if p_strict then
          raise exception 'absence type % does not exist', b->>'absence' using errcode = 'CMA02';
        end if;
        v_drop := v_drop + 1;
        continue;
      end if;
      v_label := v_abs.name;
    else
      select * into v_type from cma.assignment_type
       where tenant_id = cma.current_tenant_id() and code = upper(btrim(coalesce(b->>'code', '')));
      if v_type.id is null then
        if p_strict then
          raise exception 'assignment type % does not exist', coalesce(b->>'code', 'none') using errcode = 'CMA02';
        end if;
        v_drop := v_drop + 1;
        continue;
      end if;
      v_label := v_type.code;
    end if;
    if coalesce(b->>'start', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' or coalesce(b->>'end', '') !~ '^(([01][0-9]|2[0-3]):[0-5][0-9]|24:00)$' then
      raise exception 'a block''s start and end are hh:mm, the end at the latest 24:00' using errcode = 'CMA04';
    end if;
    v_start := (b->>'start')::time;
    v_end := (b->>'end')::time;
    v_market := nullif(btrim(coalesce(b->>'hoursMarket', '')), '');
    v_note := nullif(btrim(coalesce(b->>'note', '')), '');
    if v_abs.id is not null and v_market is not null then
      if p_strict then
        raise exception 'an absence block has no hours market: plan % without one', v_abs.name using errcode = 'CMA04';
      end if;
      v_market := null;
    end if;
    -- A pause has no hours market (Martin, 26 November 2026): the planner's CODE-MARKET on a pause type is refused; Copy
    -- week and Apply standard week write the pause without the market an older block or standard row may still carry
    if v_type.kind = 'pause' and v_market is not null then
      if p_strict then
        raise exception 'assignment type % is a pause, and a pause has no hours market: plan % without one, not %-%',
          v_type.code, v_type.code, v_type.code, v_market using errcode = 'CMA04';
      end if;
      v_market := null;
    end if;
    -- E10: a work block names its market; without one it gets the person's Default market
    if v_type.kind = 'work' and v_market is null then
      v_market := v_default;
      if v_market is null and p_strict then
        raise exception 'assignment % needs an hours market: this person has no Default market, so choose one', v_type.code
          using errcode = 'CMA04';
      end if;
    end if;
    if v_end <= v_start then
      v_bad := format('the block %s ends after it starts', v_label);
    elsif cma.roster_block_minutes(v_start) % v_slot <> 0 or cma.roster_block_minutes(v_end) % v_slot <> 0 then
      v_bad := format('the block %s starts and ends on the %s minute grid', v_label, v_slot);
    elsif v_start < v_shift.start_time or v_end > v_shift.end_time then
      v_bad := format('the block %s %s to %s lies outside the shift %s to %s', v_label, b->>'start', b->>'end',
                      to_char(v_shift.start_time, 'HH24:MI'), case when v_shift.end_time = '24:00'::time then '24:00' else to_char(v_shift.end_time, 'HH24:MI') end);
    elsif v_note is not null and length(v_note) > 120 then
      v_bad := 'a block''s note has at most 120 characters';
    end if;
    -- A retired type, absence or market stays on a block that is kept unchanged; a new block needs an active one. A pause
    -- that differs only by the market an older row still holds (written before 0009zz) counts as unchanged
    if v_bad is null and not exists (
         select 1 from cma.roster_assignment a
         where a.tenant_id = cma.current_tenant_id() and a.user_id = p_user_id and a.business_date = p_date and a.valid_to is null
           and a.assignment_type_id is not distinct from v_type.id and a.absence_type_id is not distinct from v_abs.id
           and a.start_time = v_start and a.end_time = v_end
           and (v_type.kind = 'pause' or a.hours_market_code is not distinct from v_market) and a.note is not distinct from v_note) then
      if v_abs.id is not null then
        if v_abs.status <> 'active' then
          v_bad := format('absence type %s is no longer in use', v_abs.name);
        end if;
      elsif v_type.status <> 'active' then
        v_bad := format('assignment type %s is no longer in use', v_type.code);
      elsif v_market is not null then
        if p_strict then
          perform cma.assert_hours_market(v_market);
        elsif not cma.is_hours_market(v_market) then
          v_bad := format('market %s is no active hours market', v_market);
        end if;
      end if;
    end if;
    if v_bad is not null then
      if p_strict then
        raise exception '%', v_bad using errcode = 'CMA04';
      end if;
      v_drop := v_drop + 1;
      continue;
    end if;
    if exists (select 1 from jsonb_to_recordset(v_want) as x(start_time time, end_time time)
               where x.start_time < v_end and v_start < x.end_time) then
      if p_strict then
        raise exception 'the blocks overlap at % to %', b->>'start', b->>'end' using errcode = 'CMA04';
      end if;
      v_drop := v_drop + 1;
      continue;
    end if;
    v_want := v_want || jsonb_build_array(jsonb_build_object('type_id', v_type.id, 'absence_id', v_abs.id, 'start_time', v_start,
                                                             'end_time', v_end, 'market', v_market, 'note', v_note));
  end loop;

  -- End the current blocks that are not wanted any more (before the new ones: the exclusion constraint is per statement)
  with ended as (
    update cma.roster_assignment a set valid_to = clock_timestamp()
     where a.tenant_id = cma.current_tenant_id() and a.user_id = p_user_id and a.business_date = p_date and a.valid_to is null
       and not exists (select 1 from jsonb_to_recordset(v_want)
                                     as x(type_id uuid, absence_id uuid, start_time time, end_time time, market text, note text)
                       where x.type_id is not distinct from a.assignment_type_id and x.absence_id is not distinct from a.absence_type_id
                         and x.start_time = a.start_time and x.end_time = a.end_time
                         and x.market is not distinct from a.hours_market_code and x.note is not distinct from a.note)
    returning 1)
  select count(*) into v_ended from ended;

  -- Insert the new ones; the kept ones stay as they are
  with added as (
    insert into cma.roster_assignment (tenant_id, roster_week_id, user_id, business_date, assignment_type_id, absence_type_id,
                                       start_time, end_time, hours_market_code, note)
    select cma.current_tenant_id(), p_week_id, p_user_id, p_date, x.type_id, x.absence_id, x.start_time, x.end_time, x.market, x.note
    from jsonb_to_recordset(v_want) as x(type_id uuid, absence_id uuid, start_time time, end_time time, market text, note text)
    where not exists (select 1 from cma.roster_assignment a
                      where a.tenant_id = cma.current_tenant_id() and a.user_id = p_user_id and a.business_date = p_date
                        and a.valid_to is null and x.type_id is not distinct from a.assignment_type_id
                        and x.absence_id is not distinct from a.absence_type_id and x.start_time = a.start_time
                        and x.end_time = a.end_time and x.market is not distinct from a.hours_market_code
                        and x.note is not distinct from a.note)
    order by x.start_time
    returning 1)
  select count(*) into v_added from added;
  v_kept := jsonb_array_length(v_want) - v_added;

  -- Link each block this call ended to its successor: the new block with the same start, else the first new one it overlaps
  if v_added > 0 then
    update cma.roster_assignment o
       set superseded_by = coalesce(
             (select n.id from cma.roster_assignment n
              where n.tenant_id = o.tenant_id and n.user_id = o.user_id and n.business_date = o.business_date and n.valid_to is null
                and n.recorded_at >= now() and n.start_time = o.start_time limit 1),
             (select n.id from cma.roster_assignment n
              where n.tenant_id = o.tenant_id and n.user_id = o.user_id and n.business_date = o.business_date and n.valid_to is null
                and n.recorded_at >= now() and n.start_time < o.end_time and o.start_time < n.end_time
              order by n.start_time limit 1))
     where o.tenant_id = cma.current_tenant_id() and o.user_id = p_user_id and o.business_date = p_date
       and o.valid_to >= now() and o.superseded_by is null;
  end if;

  return jsonb_build_object('kept', v_kept, 'ended', v_ended, 'added', v_added, 'dropped', v_drop);
end
$$;

-- The shifts of a roster week dated today or later for their person that hold no current block at all (E5), as a JSON
-- array of {userId, date} by date and person; none in a tenant without an active assignment type, which plans no blocks
-- (configuration, not code: E5 holds where the planner can paint). Internal: roster_publish and roster_set_cell, under
-- roster.manage
create or replace function cma.roster_empty_shifts(p_week_id uuid)
returns jsonb
language sql stable
as $$
  select coalesce(jsonb_agg(jsonb_build_object('userId', e.user_id, 'date', e.business_date) order by e.business_date, e.user_id), '[]'::jsonb)
  from cma.roster_entry e
  where e.tenant_id = cma.current_tenant_id() and e.roster_week_id = p_week_id and e.valid_to is null and e.kind = 'shift'
    and exists (select 1 from cma.assignment_type t where t.tenant_id = cma.current_tenant_id() and t.status = 'active')
    and e.business_date >= cma.business_date(now(), cma.user_timezone(e.user_id))
    and not exists (select 1 from cma.roster_assignment a
                    where a.tenant_id = e.tenant_id and a.user_id = e.user_id and a.business_date = e.business_date
                      and a.valid_to is null)
$$;

-- 0005's publication with E5: a week whose shifts dated today or later all hold a block publishes as before; otherwise
-- nothing is published and CMA04 names the people and dates in its detail (empty_shifts=[{"userId","date"}, …]), so the
-- planner shows them next to its warnings. A gap inside a shift stays a warning of the plan check, not a refusal
-- based on: 23_roster.sql
create or replace function cma.roster_publish(p_week_start date, p_team_key text default null)
returns cma.roster_week
language plpgsql
as $$
declare
  v_user  uuid;
  v_team  uuid;
  v_week  uuid;
  v_empty jsonb;
  w       cma.roster_week;
begin
  v_user := cma.assert_permission('roster.manage');
  perform cma.assert_week_start(p_week_start);
  v_team := cma.roster_team_id(p_team_key);
  v_week := cma.roster_week_id(p_week_start, v_team);

  v_empty := cma.roster_empty_shifts(v_week);
  if jsonb_array_length(v_empty) > 0 then
    raise exception 'every shift needs its assignments before it is published: % shift(s) have none', jsonb_array_length(v_empty)
      using errcode = 'CMA04', detail = 'empty_shifts=' || v_empty::text;
  end if;

  update cma.roster_week
     set status = 'published', version = version + 1, published_at = clock_timestamp(), published_by = v_user
   where tenant_id = cma.current_tenant_id() and id = v_week
   returning * into w;

  insert into cma.roster_publication (tenant_id, roster_week_id, version, published_at, published_by)
  values (cma.current_tenant_id(), v_week, w.version, w.published_at, v_user);
  return w;
end
$$;

-- 248's cell write with E5: D8's at-once publication of the person's today waits while their shift today holds no block
-- (a shift just drawn: the answer says waiting no_assignments, and the planner's blocks for it publish the week at once);
-- an absence, a clear and a shift with blocks publish at once as before, and the publication refuses (CMA04, empty_shifts)
-- while another shift of the week dated today or later has none
-- based on: 248_roster_assignments.sql
create or replace function cma.roster_set_cell(
  p_week_start      date,
  p_team_key        text,
  p_user_id         uuid,
  p_business_date   date,
  p_kind            text,
  p_start_time      time,
  p_end_time        time,
  p_absence_key     text,
  p_note            text default null,
  p_publish_others  boolean default false
)
returns jsonb
language plpgsql
as $$
declare
  v_team    uuid;
  v_week    uuid;
  v_t0      timestamptz := clock_timestamp();
  v_others  integer;
  w         cma.roster_week;
begin
  perform cma.assert_permission('roster.manage');
  perform cma.assert_week_start(p_week_start);
  v_team := cma.roster_team_id(p_team_key);
  perform cma.roster_set_entry(p_week_start, p_team_key, p_user_id, p_business_date, p_kind, p_start_time, p_end_time,
                               p_absence_key, p_note);
  v_week := cma.roster_week_id(p_week_start, v_team);   -- locks the week row: one writer of a week's publication at a time
  select * into w from cma.roster_week where tenant_id = cma.current_tenant_id() and id = v_week;
  if p_business_date = cma.business_date(now(), cma.user_timezone(p_user_id)) and w.status = 'published'
     and (exists (select 1 from cma.roster_entry e
                  where e.tenant_id = cma.current_tenant_id() and e.user_id = p_user_id and e.business_date = p_business_date
                    and (e.recorded_at >= v_t0 or e.valid_to >= v_t0))
          or exists (select 1 from cma.roster_assignment a
                     where a.tenant_id = cma.current_tenant_id() and a.user_id = p_user_id and a.business_date = p_business_date
                       and a.valid_to >= v_t0)) then
    -- E5: a shift today without a block waits for its blocks (where the tenant plans blocks at all)
    if exists (select 1 from cma.assignment_type t where t.tenant_id = cma.current_tenant_id() and t.status = 'active')
       and exists (select 1 from cma.roster_entry e
               where e.tenant_id = cma.current_tenant_id() and e.user_id = p_user_id and e.business_date = p_business_date
                 and e.valid_to is null and e.kind = 'shift')
       and not exists (select 1 from cma.roster_assignment a
                       where a.tenant_id = cma.current_tenant_id() and a.user_id = p_user_id and a.business_date = p_business_date
                         and a.valid_to is null) then
      return jsonb_build_object('published', false, 'version', coalesce(w.version, 0), 'waiting', 'no_assignments');
    end if;
    v_others := cma.roster_other_changes(v_week, p_user_id, p_business_date);
    if v_others > 0 and not coalesce(p_publish_others, false) then
      raise exception 'this also publishes % other changes of the week', v_others
        using errcode = 'CMA03', detail = 'publish_others=' || v_others;
    end if;
    w := cma.roster_publish(p_week_start, p_team_key);
    return jsonb_build_object('published', true, 'version', w.version);
  end if;
  return jsonb_build_object('published', false, 'version', coalesce(w.version, 0));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. The roster drives the day (E2, E8, E9): one idempotent job, every minute
-- ---------------------------------------------------------------------------------------------
-- For every open workday of the current tenant whose business date is the date of p_at in its zone: the person's published
-- block in force at p_at, whose start is the boundary. Nothing happens when the day has any event at or after the boundary
-- (this switch was written before, the agent's own Switch came after it, a later Clock in), when the session was not open
-- at the boundary, when no block is in force (a gap inside the shift, before it, or past its last block: E8, the agent
-- stays on what they are on), or when the block equals the state in force. Otherwise a work or pause block is booked as a
-- status event at the boundary, source 'roster', with its assignment, status and market (an extra block keeps the working
-- status in force, else the start status), even during a call; an absence block ends the workday at its start, source
-- 'roster' (E9). A block that cannot be booked (its status retired, a work block without any market) is left for brief C's
-- Live board to flag. Each workday is taken with skip locked, so a click in flight is never waited for: the next minute
-- serves it. Returns what it wrote. workday.roster_switch: the scheduler's system user
create or replace function cma.roster_switch_due(p_at timestamptz default now())
returns table (workday_id uuid, user_id uuid, action text, occurred_at timestamptz, code text)
language plpgsql rows 50
as $$
#variable_conflict use_column
declare
  v_tenant uuid := cma.current_tenant_id();
  v_start  uuid;
  v_status uuid;
  v_market text;
  v_work   boolean;
  d        record;
  b        record;
  e        cma.time_event;
begin
  perform cma.assert_permission('workday.roster_switch');
  if p_at is null or p_at > now() + interval '1 minute' then
    raise exception 'the roster switches up to now' using errcode = 'CMA04';
  end if;
  if cma.current_actor_label() is null then
    perform set_config('app.actor_label', 'scheduler:roster', true);
  end if;
  select s.id into v_start from cma.work_status s
  where s.tenant_id = v_tenant and s.status = 'active' and s.is_working
    and s.key = nullif(cma.setting_of(v_tenant, 'roster.fallback_status'), '');
  if v_start is null then
    select s.id into v_start from cma.work_status s where s.tenant_id = v_tenant and s.is_default and s.status = 'active';
  end if;

  for d in
    select w.id, w.user_id, w.business_date
    from cma.workday w
    where w.tenant_id = v_tenant and w.status = 'open'
      and w.business_date = cma.business_date(p_at, w.timezone)
    order by w.user_id
    for update of w skip locked
  loop
    b := null;
    select p.* into b from cma.roster_plan_of(d.user_id, d.business_date) p
    where p.starts_at <= p_at and p_at < p.ends_at
    order by p.starts_at desc
    limit 1;
    continue when b.block_id is null;
    continue when exists (select 1 from cma.time_event x
                          where x.tenant_id = v_tenant and x.workday_id = d.id and x.occurred_at >= b.starts_at);
    -- the event in force at the boundary: the session must be open then
    e := null;
    select x.* into e from cma.time_event x
    where x.tenant_id = v_tenant and x.workday_id = d.id and x.kind in ('start', 'status', 'end') and x.occurred_at < b.starts_at
      and not exists (select 1 from cma.time_event c where c.tenant_id = x.tenant_id and c.supersedes_event_id = x.id)
    order by x.occurred_at desc, x.recorded_at desc
    limit 1;
    continue when e.id is null or e.kind = 'end';

    if b.kind = 'absence' then
      insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source)
      values (v_tenant, d.id, d.user_id, 'end', null, b.starts_at, 'roster');
      perform cma.refresh_workday(d.id);
      workday_id := d.id; user_id := d.user_id; action := 'ended'; occurred_at := b.starts_at; code := null;
      return next;
      continue;
    end if;

    v_market := null;
    if b.kind = 'pause' then
      v_status := b.work_status_id;
    else
      v_market := cma.resolve_hours_market(b.hours_market_code);
      if b.is_extra then
        select s.is_working and s.status = 'active' into v_work from cma.work_status s where s.tenant_id = v_tenant and s.id = e.status_id;
        v_status := case when coalesce(v_work, false) then e.status_id else v_start end;
      else
        v_status := b.work_status_id;
      end if;
    end if;
    continue when v_status is null
               or not exists (select 1 from cma.work_status s where s.tenant_id = v_tenant and s.id = v_status and s.status = 'active');
    continue when b.kind = 'work' and v_market is null;
    continue when e.assignment_type_id is not distinct from b.assignment_type_id and e.status_id = v_status
              and e.hours_market_code is not distinct from v_market;

    insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source, hours_market_code,
                                assignment_type_id)
    values (v_tenant, d.id, d.user_id, 'status', v_status, b.starts_at, 'roster', v_market, b.assignment_type_id);
    perform cma.refresh_workday(d.id);
    workday_id := d.id; user_id := d.user_id; action := 'switched'; occurred_at := b.starts_at; code := b.code;
    return next;
  end loop;
end
$$;

-- One statement for all tenants (E2): every tenant with an active Scheduler user, each served as that user in its own
-- context (app.tenant_id, app.user_id, actor label scheduler:roster), so the tenant filters, the permission and the audit
-- trail name the tenant's Scheduler as for the other jobs. One tenant's failure never stops the others: its row carries
-- the SQLSTATE in failed. Answers counts per tenant only (no person or workday id leaves the function). SECURITY DEFINER (the
-- owner reads every tenant's Scheduler user) with the house's search path, pg_temp last, executable by cma_app, and
-- refused inside a request: a tenant or user already set is CMA06, so only a job's connection (jobs/roster-switch.mjs)
-- runs it
drop function if exists cma.roster_switch_all(timestamptz);   -- a rerun over a draft with another result type
create function cma.roster_switch_all(p_at timestamptz default now())
returns table (tenant_id uuid, switched integer, ended integer, failed text)
language plpgsql security definer set search_path = pg_catalog, cma, pg_temp rows 10
as $$
#variable_conflict use_column
declare
  t record;
begin
  if coalesce(current_setting('app.tenant_id', true), '') <> '' or coalesce(current_setting('app.user_id', true), '') <> '' then
    raise exception 'the roster switch runs as a job, outside a request (no tenant and no user set)' using errcode = 'CMA06';
  end if;
  for t in
    select x.tenant_id, x.user_id
    from cma.app_user_external_id x
    join cma.app_user u on u.tenant_id = x.tenant_id and u.id = x.user_id
    where x.system = 'scheduler' and x.external_id = 'scheduler' and u.status = 'active'
    order by x.tenant_id
  loop
    perform set_config('app.tenant_id', t.tenant_id::text, true);
    perform set_config('app.user_id', t.user_id::text, true);
    perform set_config('app.actor_label', 'scheduler:roster', true);
    begin
      return query
        select t.tenant_id, (count(*) filter (where r.action = 'switched'))::integer, (count(*) filter (where r.action = 'ended'))::integer,
               null::text
        from cma.roster_switch_due(p_at) r
        having count(*) > 0;
    exception when others then
      tenant_id := t.tenant_id; switched := 0; ended := 0; failed := sqlstate;
      return next;
    end;
  end loop;
  perform set_config('app.tenant_id', '', true);
  perform set_config('app.user_id', '', true);
  perform set_config('app.actor_label', '', true);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. What the agent reads: My day and My hours (E3, E6, E7, E11)
-- ---------------------------------------------------------------------------------------------
-- My day of the acting user for a date (default today in their zone), as one JSON document beside the day's clock:
--   shift        the published entry's kind, times and absence name (none without a published entry)
--   plan         the published blocks (the Scheduled lane): code, name, kind, isExtra, workArea, absenceKey, market,
--                start and end (local hh:mm) and their instants (the JSON keys say hoursMarket, never market)
--   actual       the day's stretches (the Actual lane): code (none without an assignment), name, statusKey, statusName,
--                kind, isWorking, workArea, market, fromAt, toAt (none while open), source and deviates (another
--                assignment or market than the block in force at its start)
--   marks        the agent's own switches (source user, a status event) that deviate from the block in force: at, code,
--                statusName, market, plannedCode, plannedMarket (roster switches get none)
--   current      what the open day is on now: code, name, kind, statusKey, statusName, market, since
--   planNow, planNext  the block in force now (an absence included) and the next one to start
--   notice       E3: the latest event is a roster switch (a status event of source roster) of the last
--                roster.switch_notice_minutes: at, code, name, kind, market, until; gone at the agent's own Switch or the
--                next roster switch, since either is a later event
--   offPlan      E7: the open day is on another assignment or market than the work or pause block in force now: the
--                block (code, name, kind, market, since) and the next boundary (nextAt, nextCode, nextName, nextMarket);
--                none past the last block (E8), in a gap or on an absence block
--   choices      E6's Switch panel: work (the active work types in sort order: code, name, workArea, isExtra), pause (the
--                active pause types), other (the active working statuses no active type books: key, name, workArea),
--                hoursMarkets (the active hours markets: code, name) and defaultMarket (the person's, when active)
-- workday.own; the acting user's own day only
create or replace function cma.my_day(p_date date default null)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_user    uuid;
  v_zone    text;
  v_date    date;
  v_today   boolean;
  v_minutes integer;
  w         cma.workday;
  v_shift   jsonb;
  v_plan    jsonb;
  v_actual  jsonb := '[]'::jsonb;
  v_marks   jsonb := '[]'::jsonb;
  v_current jsonb;
  v_now     jsonb;
  v_next    jsonb;
  v_notice  jsonb;
  v_off     jsonb;
  v_choices jsonb;
  e         cma.time_event;
  v_et      cma.assignment_type;
  v_es      cma.work_status;
begin
  v_user := cma.assert_permission('workday.own');
  v_zone := cma.user_timezone(v_user);
  v_date := coalesce(p_date, cma.business_date(now(), v_zone));
  v_today := v_date = cma.business_date(now(), v_zone);
  v_minutes := coalesce(cma.setting_of(v_tenant, 'roster.switch_notice_minutes')::integer, 5);

  select jsonb_build_object('kind', x.kind, 'start', to_char(x.start_time, 'HH24:MI'),
                            'end', case when x.end_time = '24:00'::time then '24:00' else to_char(x.end_time, 'HH24:MI') end,
                            'startAt', case when x.kind = 'shift' then (v_date + x.start_time) at time zone v_zone end,
                            'endAt', case when x.kind = 'shift' then (v_date + x.end_time) at time zone v_zone end,
                            'absenceName', a.name)
    into v_shift
  from cma.roster_published_entry x
  left join cma.absence_type a on a.tenant_id = x.tenant_id and a.id = x.absence_type_id
  where x.user_id = v_user and x.business_date = v_date
  order by x.published_at desc
  limit 1;

  select coalesce(jsonb_agg(jsonb_build_object(
           'code', p.code, 'name', p.name, 'kind', p.kind, 'isExtra', p.is_extra, 'workArea', p.work_area,
           'absenceKey', p.absence_key, 'hoursMarket', p.hours_market_code,
           'start', to_char(p.start_time, 'HH24:MI'),
           'end', case when p.end_time = '24:00'::time then '24:00' else to_char(p.end_time, 'HH24:MI') end,
           'startAt', p.starts_at, 'endAt', p.ends_at, 'assignmentTypeId', p.assignment_type_id) order by p.starts_at), '[]'::jsonb)
    into v_plan
  from cma.roster_plan_of(v_user, v_date) p;

  if v_today then
    select x.value into v_now from jsonb_array_elements(v_plan) x
    where (x.value->>'startAt')::timestamptz <= now() and now() < (x.value->>'endAt')::timestamptz
    limit 1;
    select x.value into v_next from jsonb_array_elements(v_plan) x
    where (x.value->>'startAt')::timestamptz > now()
    order by (x.value->>'startAt')::timestamptz
    limit 1;
  end if;

  select * into w from cma.workday d where d.tenant_id = v_tenant and d.user_id = v_user and d.business_date = v_date;
  if w.id is not null then
    select coalesce(jsonb_agg(jsonb_build_object(
             'code', a.code, 'name', coalesce(a.name, a.status_name), 'statusKey', a.status_key, 'statusName', a.status_name,
             'kind', coalesce(a.type_kind, case when a.is_working then 'other' else 'pause' end),
             'isWorking', a.is_working, 'workArea', a.work_area, 'hoursMarket', a.hours_market_code,
             'fromAt', a.from_at, 'toAt', a.to_at, 'open', a.is_open,
             'source', a.source, 'deviates', a.deviates) order by a.from_at), '[]'::jsonb),
           coalesce(jsonb_agg(jsonb_build_object(
             'at', a.from_at, 'code', a.code, 'statusName', a.status_name, 'hoursMarket', a.hours_market_code,
             'plannedCode', a.planned_code, 'plannedHoursMarket', a.planned_market) order by a.from_at)
             filter (where a.source = 'user' and a.event_kind = 'status' and a.deviates), '[]'::jsonb)
      into v_actual, v_marks
    from cma.workday_actual_of(w.id) a;

    if w.status = 'open' then
      select x.* into e from cma.time_event x
      where x.tenant_id = v_tenant and x.workday_id = w.id and x.kind in ('start', 'status')
        and not exists (select 1 from cma.time_event c where c.tenant_id = x.tenant_id and c.supersedes_event_id = x.id)
      order by x.occurred_at desc, x.recorded_at desc
      limit 1;
      select * into v_et from cma.assignment_type t where t.tenant_id = v_tenant and t.id = e.assignment_type_id;
      select * into v_es from cma.work_status s where s.tenant_id = v_tenant and s.id = e.status_id;
      v_current := jsonb_build_object('code', v_et.code, 'name', coalesce(v_et.name, v_es.name),
                                      'kind', coalesce(v_et.kind, case when v_es.is_working then 'other' else 'pause' end),
                                      'statusKey', v_es.key, 'statusName', v_es.name, 'workArea', v_es.work_area,
                                      'hoursMarket', e.hours_market_code, 'since', e.occurred_at, 'source', e.source,
                                      'assignmentTypeId', e.assignment_type_id);
      -- E3: the notice of a roster switch, while it is the latest event and younger than the setting
      if e.source = 'roster' and e.kind = 'status' and e.occurred_at > now() - make_interval(mins => v_minutes) then
        v_notice := jsonb_build_object('at', e.occurred_at, 'code', v_et.code, 'name', coalesce(v_et.name, v_es.name),
                                       'kind', v_et.kind, 'hoursMarket', e.hours_market_code,
                                       'until', e.occurred_at + make_interval(mins => v_minutes));
      end if;
      -- E7: off plan against the work or pause block in force now
      if v_now is not null and v_now->>'kind' in ('work', 'pause')
         and ((v_now->>'assignmentTypeId')::uuid is distinct from e.assignment_type_id
              or (v_now->>'hoursMarket') is distinct from e.hours_market_code) then
        v_off := jsonb_build_object('code', v_now->>'code', 'name', v_now->>'name', 'kind', v_now->>'kind',
                                    'hoursMarket', v_now->>'hoursMarket', 'since', v_now->'startAt',
                                    'nextAt', v_next->'startAt', 'nextCode', v_next->>'code', 'nextName', v_next->>'name',
                                    'nextKind', v_next->>'kind', 'nextHoursMarket', v_next->>'hoursMarket');
      end if;
    end if;
  end if;

  select jsonb_build_object(
           'work', coalesce((select jsonb_agg(jsonb_build_object('code', t.code, 'name', t.name, 'workArea', s.work_area, 'isExtra', t.is_extra)
                                              order by t.sort_order, t.code collate "C")
                             from cma.assignment_type t
                             left join cma.work_status s on s.tenant_id = t.tenant_id and s.id = t.work_status_id
                             where t.tenant_id = v_tenant and t.status = 'active' and t.kind = 'work'), '[]'::jsonb),
           'pause', coalesce((select jsonb_agg(jsonb_build_object('code', t.code, 'name', t.name)
                                               order by t.sort_order, t.code collate "C")
                              from cma.assignment_type t
                              where t.tenant_id = v_tenant and t.status = 'active' and t.kind = 'pause'), '[]'::jsonb),
           'other', coalesce((select jsonb_agg(jsonb_build_object('key', s.key, 'name', s.name, 'workArea', s.work_area)
                                               order by s.sort_order, s.key collate "C")
                              from cma.work_status s
                              where s.tenant_id = v_tenant and s.status = 'active' and s.is_working
                                and not exists (select 1 from cma.assignment_type t
                                                where t.tenant_id = s.tenant_id and t.status = 'active' and t.work_status_id = s.id)), '[]'::jsonb),
           'hoursMarkets', coalesce((select jsonb_agg(jsonb_build_object('code', h.code, 'name', h.name)
                                                      order by h.sort_order, h.code collate "C")
                                     from cma.hours_markets() h where h.status = 'active'), '[]'::jsonb),
           'defaultMarket', (select u.default_hours_market_code from cma.app_user u
                             where u.tenant_id = v_tenant and u.id = v_user and cma.is_hours_market(u.default_hours_market_code)))
    into v_choices;

  return jsonb_build_object(
    'date', v_date, 'timeZone', v_zone, 'isToday', v_today, 'shift', v_shift, 'plan', v_plan, 'actual', v_actual,
    'marks', v_marks, 'current', v_current, 'planNow', v_now, 'planNext', v_next, 'notice', v_notice, 'offPlan', v_off,
    'usesAssignments', jsonb_array_length(v_choices->'work') + jsonb_array_length(v_choices->'pause') > 0,
    'choices', v_choices);
end
$$;

-- My hours of the acting user for an ISO week (Monday p_week_start), read only (E11), as one JSON document:
--   rows      the week's worked time per assignment and market (an event without an assignment under its status name):
--             code, name, workArea, market, seconds, by seconds
--   pauses    the week's time not worked per pause type or status: code, name, seconds
--   days      per date: isToday, hasTime, workedSeconds, segments (the Actual lane: code, name, statusName, kind,
--             isWorking, workArea, market, fromAt, toAt, seconds; a running stretch up to now) and split (worked time per
--             assignment and market)
--   workedSeconds, plannedMinutes (the published plan: work blocks, an extra one included; a published shift without a
--             block counts whole, as Planned (roster) counts it)
-- workday.own; the acting user's own days only
create or replace function cma.my_hours(p_week_start date)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_user   uuid;
  v_zone   text;
  v_today  date;
  v_out    jsonb;
begin
  v_user := cma.assert_permission('workday.own');
  perform cma.assert_week_start(p_week_start);
  v_zone := cma.user_timezone(v_user);
  v_today := cma.business_date(now(), v_zone);

  with days as (
    select (p_week_start + i)::date as d from generate_series(0, 6) i
  ),
  wd as (
    select dd.d, w.id as workday_id
    from days dd
    left join cma.workday w on w.tenant_id = v_tenant and w.user_id = v_user and w.business_date = dd.d
  ),
  seg as materialized (
    select wd.d, a.*,
           coalesce(a.code, a.status_name) as label
    from wd
    cross join lateral cma.workday_actual_of(wd.workday_id) a
    where wd.workday_id is not null
  ),
  -- one read of the plan per date (the blocks counted and the work minutes summed together)
  planned as (
    select coalesce(sum(
             case when x.kind = 'shift' and pl.n = 0
                  then cma.roster_block_minutes(x.end_time) - cma.roster_block_minutes(x.start_time)
                  else pl.work_minutes
             end), 0)::integer as minutes
    from days dd
    cross join lateral (
      select e.kind, e.start_time, e.end_time from cma.roster_published_entry e
      where e.user_id = v_user and e.business_date = dd.d
      order by e.published_at desc limit 1
    ) x
    cross join lateral (
      select count(*) as n,
             coalesce(sum(cma.roster_block_minutes(p.end_time) - cma.roster_block_minutes(p.start_time)) filter (where p.kind = 'work'), 0) as work_minutes
      from cma.roster_plan_of(v_user, dd.d) p
    ) pl
  ),
  per_day as (
    select dd.d,
           jsonb_build_object(
             'date', dd.d, 'isToday', dd.d = v_today,
             'hasTime', exists (select 1 from seg s where s.d = dd.d),
             'workedSeconds', coalesce((select sum(s.seconds) from seg s where s.d = dd.d and s.is_working), 0),
             'segments', coalesce((select jsonb_agg(jsonb_build_object(
                                     'code', s.code, 'name', coalesce(s.name, s.status_name), 'statusName', s.status_name,
                                     'kind', coalesce(s.type_kind, case when s.is_working then 'other' else 'pause' end),
                                     'isWorking', s.is_working, 'workArea', s.work_area, 'hoursMarket', s.hours_market_code,
                                     'fromAt', s.from_at, 'toAt', coalesce(s.to_at, s.from_at + make_interval(secs => s.seconds)),
                                     'seconds', s.seconds) order by s.from_at)
                                   from seg s where s.d = dd.d), '[]'::jsonb),
             'split', coalesce((select jsonb_agg(jsonb_build_object('code', g.code, 'name', g.label, 'hoursMarket', g.market, 'seconds', g.secs)
                                                 order by g.first_at)
                                from (select s.code, s.label, s.hours_market_code as market, sum(s.seconds) as secs, min(s.from_at) as first_at
                                      from seg s where s.d = dd.d and s.is_working
                                      group by s.code, s.label, s.hours_market_code) g), '[]'::jsonb)
           ) as day
    from days dd
  )
  select jsonb_build_object(
           'weekStart', p_week_start, 'today', v_today, 'timeZone', v_zone,
           'workedSeconds', coalesce((select sum(s.seconds) from seg s where s.is_working), 0),
           'plannedMinutes', (select minutes from planned),
           'rows', coalesce((select jsonb_agg(jsonb_build_object('code', g.code, 'name', g.name, 'workArea', g.work_area,
                                                                 'hoursMarket', g.market, 'seconds', g.secs)
                                              order by g.secs desc, g.label collate "C", g.market collate "C")
                             from (select s.code, s.label, max(coalesce(s.name, s.status_name)) as name, max(s.work_area) as work_area,
                                          s.hours_market_code as market, sum(s.seconds) as secs
                                   from seg s where s.is_working
                                   group by s.code, s.label, s.hours_market_code) g), '[]'::jsonb),
           'pauses', coalesce((select jsonb_agg(jsonb_build_object('code', g.code, 'name', g.name, 'seconds', g.secs)
                                                order by g.secs desc, g.label collate "C")
                               from (select s.code, s.label, max(coalesce(s.name, s.status_name)) as name, sum(s.seconds) as secs
                                     from seg s where not s.is_working
                                     group by s.code, s.label) g), '[]'::jsonb),
           'days', (select jsonb_agg(p.day order by p.d) from per_day p))
    into v_out;
  return v_out;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 8. Privileges on the functions: the application only (the trigger function and the internal helpers too, as 248's)
-- ---------------------------------------------------------------------------------------------
revoke execute on function
  cma.roster_plan_of(uuid, date), cma.workday_actual_of(uuid), cma.clock_in_choice(uuid, date, timestamptz, text),
  cma.my_day(date), cma.my_hours(date), cma.roster_switch_due(timestamptz), cma.roster_switch_all(timestamptz),
  cma.roster_empty_shifts(uuid), cma.roster_put_assignments(uuid, uuid, date, jsonb, boolean),
  cma.roster_publish(date, text), cma.roster_set_cell(date, text, uuid, date, text, time, time, text, text, boolean),
  cma.open_workday(timestamptz)
from public, cma_readonly;
grant execute on function
  cma.roster_plan_of(uuid, date), cma.workday_actual_of(uuid), cma.clock_in_choice(uuid, date, timestamptz, text),
  cma.my_day(date), cma.my_hours(date), cma.roster_switch_due(timestamptz), cma.roster_switch_all(timestamptz),
  cma.roster_empty_shifts(uuid), cma.roster_put_assignments(uuid, uuid, date, jsonb, boolean),
  cma.roster_publish(date, text), cma.roster_set_cell(date, text, uuid, date, text, time, time, text, text, boolean),
  cma.open_workday(timestamptz)
to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 9. E10's backfill: every work block without a market gets the person's Default market on the block's date
-- ---------------------------------------------------------------------------------------------
-- The Default market on a date is the value the audit trail holds for the person at the end of that date in their zone:
-- the new value of their last change before it, else the old value of their first change after it, else today's value.
-- When that is no hours market (none set then), today's Default market; a person without any keeps the block without a
-- market (the reads then show their Default market once they have one, as before 0010a). An owner's update in place of
-- the current and the ended rows, recorded in cma.audit_log like every change: the planner's history is otherwise
-- insert-only (D7), and a new version would count as a change waiting for Publish. Pauses keep none (0009zz), and so do
-- absence blocks (none exist yet)
do $$
declare
  r       record;
  v_end   timestamptz;
  v_found boolean;
  v_val   text;
  v_n     integer := 0;
  v_left  integer := 0;
begin
  for r in
    select a.id, a.tenant_id, a.user_id, a.business_date, u.default_hours_market_code as today_market
    from cma.roster_assignment a
    join cma.assignment_type t on t.tenant_id = a.tenant_id and t.id = a.assignment_type_id
    join cma.app_user u on u.tenant_id = a.tenant_id and u.id = a.user_id
    where a.hours_market_code is null and t.kind = 'work'
    order by a.tenant_id, a.user_id, a.business_date
  loop
    perform set_config('app.tenant_id', r.tenant_id::text, true);
    v_end := (r.business_date + 1)::timestamp at time zone cma.user_timezone(r.user_id);
    v_found := false;
    select true, l.new_row ->> 'default_hours_market_code' into v_found, v_val
    from cma.audit_log l
    where l.tenant_id = r.tenant_id and l.table_name = 'app_user' and l.row_id = r.user_id::text and l.changed_at < v_end
      and (l.old_row ->> 'default_hours_market_code') is distinct from (l.new_row ->> 'default_hours_market_code')
    order by l.changed_at desc
    limit 1;
    if not coalesce(v_found, false) then
      select true, l.old_row ->> 'default_hours_market_code' into v_found, v_val
      from cma.audit_log l
      where l.tenant_id = r.tenant_id and l.table_name = 'app_user' and l.row_id = r.user_id::text and l.changed_at >= v_end
        and l.action = 'update'
        and (l.old_row ->> 'default_hours_market_code') is distinct from (l.new_row ->> 'default_hours_market_code')
      order by l.changed_at
      limit 1;
    end if;
    if not coalesce(v_found, false) then
      v_val := r.today_market;
    end if;
    if v_val is null or not exists (select 1 from cma.market m where m.tenant_id = r.tenant_id and m.code = v_val
                                                                 and m.hours_market_code = m.code) then
      v_val := r.today_market;
    end if;
    if v_val is null or not exists (select 1 from cma.market m where m.tenant_id = r.tenant_id and m.code = v_val
                                                                 and m.hours_market_code = m.code) then
      v_left := v_left + 1;
      continue;
    end if;
    update cma.roster_assignment set hours_market_code = v_val where tenant_id = r.tenant_id and id = r.id;
    v_n := v_n + 1;
  end loop;
  perform set_config('app.tenant_id', '', true);
  raise notice '0010a backfill: % work block(s) given a market, % left without one (no Default market at all)', v_n, v_left;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 10. The columns, their constraints and triggers, the views and the reads that name them, last (CLAUDE.md,
--     Performance; 132, section 10; 230): each alter takes an ACCESS EXCLUSIVE lock held to the commit.
--     cma.roster_assignment first (the planner's), then cma.time_event (every clock action and poll), so that lock is
--     held the shortest: only DDL without a scan of it, its readers' views and the record of the addition follow
-- ---------------------------------------------------------------------------------------------
-- cma.roster_assignment: E9's absence block. A block is either an assignment or an absence, never both
alter table cma.roster_assignment add column if not exists absence_type_id uuid;
alter table cma.roster_assignment alter column assignment_type_id drop not null;
do $$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'cma.roster_assignment'::regclass and conname = 'roster_assignment_absence_fk') then
    alter table cma.roster_assignment add constraint roster_assignment_absence_fk
      foreign key (tenant_id, absence_type_id) references cma.absence_type (tenant_id, id);
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'cma.roster_assignment'::regclass and conname = 'roster_assignment_one_kind') then
    alter table cma.roster_assignment add constraint roster_assignment_one_kind
      check ((assignment_type_id is null) <> (absence_type_id is null));
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'cma.roster_assignment'::regclass and conname = 'roster_assignment_absence_no_market') then
    alter table cma.roster_assignment add constraint roster_assignment_absence_no_market
      check (absence_type_id is null or hours_market_code is null);
  end if;
end
$$;
comment on column cma.roster_assignment.absence_type_id is
  'Absence block (docs/definitions.md): the absence type of a block inside the shift (sick from 11:00, going home early); null for an assignment. A block is either an assignment or an absence, never both (check roster_assignment_one_kind); an absence block has no hours market';
comment on column cma.roster_assignment.hours_market_code is
  'The Hours market the block is planned under: a work block names one (the person''s Default market when written without one, E10); a pause and an absence block have none';

-- The published blocks with the absence last; the tenant face again, so its select * takes the new column
create or replace view cma.roster_published_assignment_all as
  select a.id, a.tenant_id, a.roster_week_id, w.team_id, w.week_start, w.version, w.published_at,
         a.user_id, a.business_date, a.assignment_type_id, a.start_time, a.end_time, a.hours_market_code, a.note,
         a.recorded_at, a.recorded_by, a.absence_type_id
  from cma.roster_assignment a
  join cma.roster_week w on w.tenant_id = a.tenant_id and w.id = a.roster_week_id
  where w.status = 'published'
    and a.recorded_at <= w.published_at
    and (a.valid_to is null or a.valid_to > w.published_at);
revoke all on cma.roster_published_assignment_all from cma_app, cma_readonly, public;

create or replace view cma.roster_published_assignment as
  select * from cma.roster_published_assignment_all where tenant_id = cma.current_tenant_id();

create or replace view cma_read.roster_assignment as
  select id, tenant_id, roster_week_id, user_id, business_date, assignment_type_id, start_time, end_time, hours_market_code,
         note, recorded_at, recorded_by, valid_to, superseded_by, absence_type_id
  from cma.roster_assignment
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.roster_published_assignment as
  select id, tenant_id, roster_week_id, team_id, week_start, version, published_at, user_id, business_date,
         assignment_type_id, start_time, end_time, hours_market_code, note, recorded_at, recorded_by, absence_type_id
  from cma.roster_published_assignment_all
  where cma_read.reader_sees(tenant_id);

-- A person-date's current blocks as JSON (the planner's answer); a pause shows no market, an absence block its key
-- based on: 252_roster_pause_no_market.sql
create or replace function cma.roster_blocks_json(p_user_id uuid, p_date date)
returns jsonb
language sql stable
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'assignmentId', a.id, 'code', t.code, 'absence', b.key, 'absenceName', b.name,
           'start', to_char(a.start_time, 'HH24:MI'),
           'end', case when a.end_time = '24:00'::time then '24:00' else to_char(a.end_time, 'HH24:MI') end,
           'hoursMarket', case when t.kind = 'pause' or a.absence_type_id is not null then null else a.hours_market_code end,
           'note', a.note, 'recordedAt', a.recorded_at)
           order by a.start_time), '[]'::jsonb)
  from cma.roster_assignment a
  left join cma.assignment_type t on t.tenant_id = a.tenant_id and t.id = a.assignment_type_id
  left join cma.absence_type b on b.tenant_id = a.tenant_id and b.id = a.absence_type_id
  where a.tenant_id = cma.current_tenant_id() and a.user_id = p_user_id and a.business_date = p_date and a.valid_to is null
$$;

-- A person-date's published blocks of one roster week as JSON for the agent's schedule and the Live board, 252's, with
-- E9's absence blocks (kind absence, code null, the absence's key and name; no market) and E10 (a work block's own market;
-- the Default market only for a block before 0010a's backfill without one). A pause shows no market
-- based on: 252_roster_pause_no_market.sql
create or replace function cma.roster_published_blocks_json(p_week_id uuid, p_user_id uuid, p_date date)
returns jsonb
language sql stable
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', t.code, 'name', coalesce(t.name, b.name),
           'kind', case when a.absence_type_id is not null then 'absence' else t.kind end,
           'workArea', s.work_area, 'isExtra', coalesce(t.is_extra, false),
           'absenceKey', b.key,
           'start', to_char(a.start_time, 'HH24:MI'),
           'end', case when a.end_time = '24:00'::time then '24:00' else to_char(a.end_time, 'HH24:MI') end,
           'hoursMarket', case when t.kind = 'pause' or a.absence_type_id is not null then null
                               else coalesce(a.hours_market_code, u.default_hours_market_code) end,
           'ownMarket', t.kind is distinct from 'pause' and a.absence_type_id is null and a.hours_market_code is null,
           'hoursMarketZone', case when t.kind = 'pause' or a.absence_type_id is not null then null else m.time_zone end)
           order by a.start_time), '[]'::jsonb)
  from cma.roster_published_assignment a
  left join cma.assignment_type t on t.tenant_id = a.tenant_id and t.id = a.assignment_type_id
  left join cma.absence_type b on b.tenant_id = a.tenant_id and b.id = a.absence_type_id
  left join cma.work_status s on s.tenant_id = t.tenant_id and s.id = t.work_status_id
  join cma.app_user u on u.tenant_id = a.tenant_id and u.id = a.user_id
  left join cma.market m on m.tenant_id = a.tenant_id and m.code = coalesce(a.hours_market_code, u.default_hours_market_code)
  where a.roster_week_id = p_week_id and a.user_id = p_user_id and a.business_date = p_date
$$;

-- The current blocks of the week (what the planner paints), 252's, with E9's absence blocks: kind absence, code and name
-- the absence's, absence_key and absence_name appended last; a pause and an absence show no market
drop function if exists cma.roster_assignments(date, text);
-- based on: 252_roster_pause_no_market.sql
create function cma.roster_assignments(p_week_start date, p_team_key text default null)
returns table (
  assignment_id      uuid,
  user_id            uuid,
  business_date      date,
  code               text,
  name               text,
  kind               text,
  work_area          text,
  is_extra           boolean,
  start_time         time,
  end_time           time,
  hours_market_code  text,
  note               text,
  recorded_at        timestamptz,
  absence_key        text,
  absence_name       text
)
language plpgsql stable rows 500
as $$
#variable_conflict use_column
declare
  v_team uuid;
begin
  perform cma.assert_permission('roster.manage');
  perform cma.assert_week_start(p_week_start);
  v_team := cma.roster_team_id(p_team_key);
  return query
    with blocks as materialized (
      select a.* from cma.roster_assignment a
      join cma.roster_week w on w.tenant_id = a.tenant_id and w.id = a.roster_week_id
      where a.tenant_id = cma.current_tenant_id()
        and w.week_start = p_week_start and w.team_id is not distinct from v_team
        and a.valid_to is null
    ),
    -- on the roster, asked once per person, not once per block (the N06 lesson on per-row calls)
    people as materialized (
      select x.user_id from (select distinct b.user_id from blocks b) x where cma.on_roster(x.user_id)
    )
    select a.id, a.user_id, a.business_date, t.code::text, coalesce(t.name, ab.name)::text,
           (case when a.absence_type_id is not null then 'absence' else t.kind end)::text, s.work_area::text, coalesce(t.is_extra, false),
           a.start_time, a.end_time, (case when t.kind = 'work' then a.hours_market_code end)::text, a.note::text, a.recorded_at,
           ab.key::text, ab.name::text
    from blocks a
    join people p on p.user_id = a.user_id
    left join cma.assignment_type t on t.tenant_id = a.tenant_id and t.id = a.assignment_type_id
    left join cma.absence_type ab on ab.tenant_id = a.tenant_id and ab.id = a.absence_type_id
    left join cma.work_status s on s.tenant_id = t.tenant_id and s.id = t.work_status_id
    where t.id is not null or ab.id is not null   -- a pause and an absence show no market
    order by a.business_date, a.user_id, a.start_time;
end
$$;
revoke execute on function cma.roster_assignments(date, text), cma.roster_blocks_json(uuid, date),
  cma.roster_published_blocks_json(uuid, uuid, date) from public, cma_readonly;
grant execute on function cma.roster_assignments(date, text), cma.roster_blocks_json(uuid, date),
  cma.roster_published_blocks_json(uuid, uuid, date) to cma_app;

-- cma.time_event: the column without a default (no rewrite), the foreign key and the kind check not valid (no scan: every
-- existing row is null; both hold for every new row), the trigger; the source 'roster'
alter table cma.time_event add column if not exists assignment_type_id uuid;
do $$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'cma.time_event'::regclass and conname = 'time_event_assignment_fk') then
    alter table cma.time_event add constraint time_event_assignment_fk
      foreign key (tenant_id, assignment_type_id) references cma.assignment_type (tenant_id, id) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'cma.time_event'::regclass and conname = 'time_event_assignment_kind') then
    alter table cma.time_event add constraint time_event_assignment_kind
      check (assignment_type_id is null or kind in ('start', 'status')) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'cma.time_event'::regclass and conname = 'time_event_source_check'
                   and pg_get_constraintdef(oid) like '%roster%') then
    alter table cma.time_event drop constraint if exists time_event_source_check;
    alter table cma.time_event add constraint time_event_source_check
      check (source in ('user', 'system', 'correction', 'import', 'roster')) not valid;
  end if;
end
$$;
comment on column cma.time_event.assignment_type_id is
  'Assignment (docs/definitions.md) the start or status event books: a work type''s status under an hours market, a pause type''s status without one, an extra type''s working status under one; null: no assignment (Training, Meeting, Coaching, the fallback, history before 0010a). Never rewritten: a correction supersedes the event';
comment on column cma.time_event.source is
  'user (own click: Clock in, Switch, End workday), system (the scheduler''s close), correction (a person with workday.team, reason and approver), import (a legacy batch), roster (the roster''s switch at a block boundary, or the end at an absence block)';
create or replace trigger time_event_assignment_ok before insert or update of assignment_type_id, status_id, hours_market_code, kind
  on cma.time_event for each row execute function cma.time_event_assignment_ok();

-- The readers' views: each column appended last
create or replace view cma_read.time_event as
  select id, tenant_id, workday_id, user_id, kind, status_id, occurred_at, recorded_at, source,
         supersedes_event_id, reason, approved_by, import_batch_id, hours_market_code, assignment_type_id
  from cma.time_event
  where cma_read.reader_sees(tenant_id);

-- 230's view with the assignment of the event that opened the stretch (E1), read by the stretch's event id
create or replace view cma_read.time_interval as
  select w.tenant_id, w.id as workday_id, w.user_id, x.event_id, x.status_id,
         x.from_at, x.to_at, x.is_open, x.is_capped, x.seconds,
         (select e.hours_market_code from cma.time_event e where e.tenant_id = w.tenant_id and e.id = x.event_id) as hours_market_code,
         (select e.assignment_type_id from cma.time_event e where e.tenant_id = w.tenant_id and e.id = x.event_id) as assignment_type_id
  from cma.workday w
  cross join lateral (
    select cma.business_day_time(w.business_date, w.timezone,
             (select coalesce(ts.value, st.default_value)::time
              from cma.setting st
              left join cma.tenant_setting ts on ts.tenant_id = w.tenant_id and ts.key = st.key
              where st.key = 'workday.window_end')) as day_end) d
  cross join lateral cma.workday_stretches_reader_of(w.tenant_id, w.id, d.day_end) x
  where cma_read.reader_sees(w.tenant_id);

-- The source check stays NOT VALID: every existing row holds it (no row had 'roster'), every new row is checked, and a
-- validation here would scan time_event while this transaction holds its ACCESS EXCLUSIVE lock (each clock action waits)

-- ---------------------------------------------------------------------------------------------
-- 11. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0010a', 'The roster drives the agent''s day (brief B, E1 to E12): cma.time_event.assignment_type_id (trigger time_event_assignment_ok: a work type''s status under an hours market, a pause''s without one, an extra type''s working status) and source roster; cma.roster_assignment.absence_type_id (check roster_assignment_one_kind: an assignment or an absence, never both; no market on an absence); settings roster.switch_notice_minutes and roster.fallback_status; permission workday.roster_switch for each Scheduler; cma.roster_plan_of, cma.workday_actual_of, cma.clock_in_choice, cma.my_day, cma.my_hours, cma.roster_switch_due, cma.roster_switch_all (definer, the minute job), cma.roster_empty_shifts; set_status with the assignment (E1, E6), open_workday on the plan (E4, E5), roster_publish refuses a shift without blocks (E5), roster_set_cell waits for blocks, roster_put_assignments with absence blocks and the Default market (E9, E10), the blocks'' reads with absences; E10''s backfill of work blocks without a market; cma_read.time_event, time_interval, roster_assignment and roster_published_assignment with the new columns')
on conflict (version) do nothing;

commit;
reset role;
