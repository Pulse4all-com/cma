-- CMA migration 0003: corrections
-- Run as yourself (IAM login), after 05. Safe to rerun. Universal: no customer, tenant or vendor
-- specifics; runs unchanged in every customer database.
--
-- Adds (README: Time model; Roadmap step 2, increment c1)
--   cma.assert_permission()  the permission check the functions below share; CMA06 when missing
--   cma.correct_workday()    one edit of one person's day in one transaction: several changes, one
--                            reason, validated once at the end. Creates the day when none exists
--                            (Add day); the first change on such a date must then be the start
--   cma.team_hours()         hours per person per day, for people holding workday.team
--   cma.team_day()           one day's events with their correction history, for the day editor
-- Changes
--   cma.refresh_workday      also refuses a status or an end before the start
--   cma.correct_time_event   permission refusals are CMA06 (was CMA04); nobody corrects their own
--                            day; the approver is the person making the correction
--
-- Rules for every correction (decisions 6 October 2026)
--   - the acting user holds workday.team; the target is another user of the same tenant
--   - V1: the person making a correction is its approver (approved_by = acting user); four eyes
--     come with agent proposals for forgotten clock-outs
--   - a reason of 3 to 500 characters
--   - every time lies within the business day of the corrected date in the day's zone, not in the
--     future, and carries an explicit offset (ISO 8601 with Z or +hh:mm): during the autumn clock
--     change one local hour occurs twice, so a time without offset is ambiguous
--
-- SQLSTATEs: CMA01 to CMA05 as in 0002, plus
--   CMA06 not permitted: a missing permission, or a correction of one's own day

-- Guard: scripts run under a personal IAM login so the audit trail names a person. postgres is
-- for emergencies only; to use it deliberately, run first:  set cma.emergency = 'on';
do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;

set role cma_owner;

-- ---------------------------------------------------------------------------------------------
-- 1. The shared permission check
-- ---------------------------------------------------------------------------------------------
-- Returns the acting user. CMA01 without an acting user or for an inactive one, CMA06 without the
-- permission. Permissions are catalog keys from the application, never role names.
create or replace function cma.assert_permission(p_permission text)
returns uuid
language plpgsql stable
as $$
declare
  v_user uuid := cma.current_user_id();
begin
  if v_user is null then
    raise exception 'this needs app.user_id, the acting user' using errcode = 'CMA01';
  end if;
  if not exists (select 1 from cma.app_user
                 where tenant_id = cma.current_tenant_id() and id = v_user and status = 'active') then
    raise exception 'user % is not an active user of the current tenant', v_user using errcode = 'CMA01';
  end if;
  if not cma.has_permission(v_user, p_permission) then
    raise exception 'user % lacks permission %', v_user, p_permission using errcode = 'CMA06';
  end if;
  return v_user;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. refresh_workday: nothing before the start
-- ---------------------------------------------------------------------------------------------
-- The user paths already refuse this (set_status and end_workday check the start); corrections
-- could not until now.
create or replace function cma.refresh_workday(p_workday_id uuid)
returns void
language plpgsql
as $$
declare
  v_tenant      uuid := cma.current_tenant_id();
  v_starts      integer;
  v_ends        integer;
  v_started     timestamptz;
  v_ended       timestamptz;
  v_last_live   timestamptz;
  v_first_after timestamptz;
begin
  select count(*) filter (where kind = 'start'),
         count(*) filter (where kind = 'end'),
         min(occurred_at) filter (where kind = 'start'),
         max(occurred_at) filter (where kind = 'end'),
         max(occurred_at) filter (where kind in ('start', 'status')),
         min(occurred_at) filter (where kind in ('status', 'end'))
  into v_starts, v_ends, v_started, v_ended, v_last_live, v_first_after
  from cma.time_event_effective
  where tenant_id = v_tenant and workday_id = p_workday_id;

  if v_starts <> 1 then
    raise exception 'workday % must have exactly one effective start event, it has %', p_workday_id, v_starts
      using errcode = 'CMA04';
  end if;
  if v_ends > 1 then
    raise exception 'workday % must have at most one effective end event, it has %', p_workday_id, v_ends
      using errcode = 'CMA04';
  end if;
  if v_first_after < v_started then
    raise exception 'workday % has a status or end event before its start', p_workday_id
      using errcode = 'CMA04';
  end if;
  if v_ended is not null and v_ended < v_last_live then
    raise exception 'workday % has a status or start event after its end', p_workday_id
      using errcode = 'CMA04';
  end if;

  update cma.workday
  set started_at = v_started,
      ended_at   = v_ended,
      status     = case when v_ended is null then 'open' else 'ended' end
  where tenant_id = v_tenant and id = p_workday_id;

  if not found then
    raise exception 'workday % not found in the current tenant', p_workday_id using errcode = 'CMA02';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. correct_time_event: CMA06, not one's own day, approver is the acting user
-- ---------------------------------------------------------------------------------------------
-- The single-change form for SQL tools. The application uses correct_workday. The signature stays,
-- so callers keep working; p_approved_by must be the acting user until four eyes exist.
create or replace function cma.correct_time_event(
  p_workday_id           uuid,
  p_kind                 text,
  p_occurred_at          timestamptz,
  p_status_key           text,
  p_supersedes_event_id  uuid,
  p_reason               text,
  p_approved_by          uuid
)
returns cma.time_event
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_user   uuid;
  v_status uuid;
  w        cma.workday;
  e        cma.time_event;
begin
  v_user := cma.assert_permission('workday.team');
  if p_approved_by is distinct from v_user then
    raise exception 'the approver is the person making the correction' using errcode = 'CMA04';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 3 then
    raise exception 'a correction needs a reason' using errcode = 'CMA04';
  end if;
  if p_kind not in ('start', 'status', 'end', 'void') then
    raise exception 'kind must be start, status, end or void' using errcode = 'CMA04';
  end if;

  select * into w from cma.workday where tenant_id = v_tenant and id = p_workday_id for update;
  if not found then
    raise exception 'workday % not found in the current tenant', p_workday_id using errcode = 'CMA02';
  end if;
  if w.user_id = v_user then
    raise exception 'nobody corrects their own day' using errcode = 'CMA06';
  end if;

  if p_supersedes_event_id is not null then
    if not exists (select 1 from cma.time_event
                   where tenant_id = v_tenant and id = p_supersedes_event_id and workday_id = w.id) then
      raise exception 'event % does not belong to workday %', p_supersedes_event_id, w.id using errcode = 'CMA04';
    end if;
    if exists (select 1 from cma.time_event
               where tenant_id = v_tenant and supersedes_event_id = p_supersedes_event_id) then
      raise exception 'event % is already superseded; correct the latest correction instead', p_supersedes_event_id
        using errcode = 'CMA04';
    end if;
  elsif p_kind = 'void' then
    raise exception 'void needs the event it cancels' using errcode = 'CMA04';
  end if;

  if p_kind in ('start', 'status') then
    select id into v_status from cma.work_status
    where tenant_id = v_tenant and key = p_status_key and status = 'active';
    if v_status is null then
      raise exception 'work status "%" is not active in this tenant', p_status_key using errcode = 'CMA02';
    end if;
  end if;
  if p_kind <> 'void' and (p_occurred_at is null or p_occurred_at > now() + interval '5 minutes') then
    raise exception 'a corrected time must lie in the past' using errcode = 'CMA04';
  end if;

  insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source,
                              supersedes_event_id, reason, approved_by)
  values (v_tenant, w.id, w.user_id, p_kind, v_status,
          coalesce(p_occurred_at, now()),          -- a void carries no time of its own
          'correction', p_supersedes_event_id, btrim(p_reason), v_user)
  returning * into e;

  perform cma.refresh_workday(w.id);
  return e;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. correct_workday: one edit of one day, also Add day
-- ---------------------------------------------------------------------------------------------
-- p_changes is a JSON array, applied in order, validated once at the end:
--   {"kind": "start" | "status" | "end" | "void",
--    "at": "2026-10-05T09:00:00+02:00",   -- not for void
--    "statusKey": "<work_status.key>",     -- start and status only
--    "supersedes": "<time_event.id>"}      -- replaces that event; required for void
-- Validating at the end lets an edit pass through states that are invalid on their own, such as
-- moving the end before a status that the same edit removes.
create or replace function cma.correct_workday(
  p_user_id       uuid,
  p_business_date date,
  p_changes       jsonb,
  p_reason        text
)
returns cma.workday
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_actor  uuid;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_exists boolean;
  v_tz     text;
  v_from   timestamptz;
  v_to     timestamptz;
  v_n      bigint;
  v_kind   text;
  v_at     timestamptz;
  v_super  uuid;
  v_status uuid;
  c        jsonb;
  w        cma.workday;
begin
  v_actor := cma.assert_permission('workday.team');

  if p_user_id is null or not exists (select 1 from cma.app_user where tenant_id = v_tenant and id = p_user_id) then
    raise exception 'user % not found in the current tenant', p_user_id using errcode = 'CMA02';
  end if;
  if p_user_id = v_actor then
    raise exception 'nobody corrects their own day' using errcode = 'CMA06';
  end if;
  if length(v_reason) < 3 or length(v_reason) > 500 then
    raise exception 'a correction needs a reason of 3 to 500 characters' using errcode = 'CMA04';
  end if;
  if p_changes is null or jsonb_typeof(p_changes) <> 'array'
     or jsonb_array_length(p_changes) < 1 or jsonb_array_length(p_changes) > 100 then
    raise exception 'changes must be an array of 1 to 100 changes' using errcode = 'CMA04';
  end if;
  if p_business_date is null then
    raise exception 'a correction needs a date' using errcode = 'CMA04';
  end if;

  select * into w from cma.workday
  where tenant_id = v_tenant and user_id = p_user_id and business_date = p_business_date
  for update;
  v_exists := found;

  v_tz := coalesce(w.timezone, cma.user_timezone(p_user_id));
  if p_business_date > cma.business_date(now(), v_tz) then
    raise exception 'the date must be today or earlier in the person''s zone' using errcode = 'CMA04';
  end if;
  v_from := p_business_date::timestamp at time zone v_tz;
  v_to   := cma.business_day_end(p_business_date, v_tz);

  for c, v_n in select e, n from jsonb_array_elements(p_changes) with ordinality as x(e, n) order by n loop
    if jsonb_typeof(c) <> 'object' then
      raise exception 'change % is not an object', v_n using errcode = 'CMA04';
    end if;
    v_kind := c->>'kind';
    if v_kind is null or v_kind not in ('start', 'status', 'end', 'void') then
      raise exception 'change %: kind must be start, status, end or void', v_n using errcode = 'CMA04';
    end if;

    v_at := null;
    begin
      v_super := nullif(c->>'supersedes', '')::uuid;
      if v_kind <> 'void' then
        if coalesce(c->>'at', '') !~ '(Z|[+-][0-9]{2}:?[0-9]{2})$' then
          raise exception 'change %: the time needs an offset (Z or +hh:mm)', v_n using errcode = 'CMA04';
        end if;
        v_at := (c->>'at')::timestamptz;
      end if;
    exception
      when invalid_text_representation or invalid_datetime_format or datetime_field_overflow then
        raise exception 'change %: invalid time or event id', v_n using errcode = 'CMA04';
    end;

    if v_kind <> 'void' and (v_at < v_from or v_at > v_to or v_at > now() + interval '5 minutes') then
      raise exception 'change %: the time must lie within the corrected day and not in the future', v_n
        using errcode = 'CMA04';
    end if;
    if v_kind = 'void' and v_super is null then
      raise exception 'change %: void needs the event it cancels', v_n using errcode = 'CMA04';
    end if;

    v_status := null;
    if v_kind in ('start', 'status') then
      select id into v_status from cma.work_status
      where tenant_id = v_tenant and key = c->>'statusKey' and status = 'active';
      if v_status is null then
        raise exception 'change %: work status "%" is not active in this tenant', v_n, c->>'statusKey'
          using errcode = 'CMA02';
      end if;
    end if;

    -- Add day: no day on this date yet, so the edit must begin with its start
    if not v_exists then
      if v_kind <> 'start' or v_super is not null then
        raise exception 'there is no day on % yet; the first change must be its start', p_business_date
          using errcode = 'CMA04';
      end if;
      begin
        insert into cma.workday (tenant_id, user_id, business_date, timezone, status, started_at)
        values (v_tenant, p_user_id, p_business_date, v_tz, 'open', v_at)
        returning * into w;
      exception
        when unique_violation then
          raise exception 'a day for % was opened meanwhile; reload it and correct that day', p_business_date
            using errcode = 'CMA04';
      end;
      v_exists := true;
    end if;

    if v_super is not null then
      if not exists (select 1 from cma.time_event
                     where tenant_id = v_tenant and id = v_super and workday_id = w.id) then
        raise exception 'change %: event % does not belong to this day', v_n, v_super using errcode = 'CMA04';
      end if;
      if exists (select 1 from cma.time_event where tenant_id = v_tenant and supersedes_event_id = v_super) then
        raise exception 'change %: event % is already superseded; correct the latest correction instead', v_n, v_super
          using errcode = 'CMA04';
      end if;
    end if;

    insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source,
                                supersedes_event_id, reason, approved_by)
    values (v_tenant, w.id, p_user_id, v_kind, v_status,
            coalesce(v_at, now()),                 -- a void carries no time of its own
            'correction', v_super, v_reason, v_actor);
  end loop;

  perform cma.refresh_workday(w.id);
  select * into w from cma.workday where tenant_id = v_tenant and id = w.id;
  return w;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. Team reads, checked in the database
-- ---------------------------------------------------------------------------------------------
-- Tenant-wide until teams exist (migration for teams and skills); then scoped to the grant.
create or replace function cma.team_hours(p_from date, p_to date, p_user_id uuid default null)
returns table (
  user_id           uuid,
  display_name      text,
  organisation_name text,
  business_date     date,
  timezone          text,
  status            text,
  started_at        timestamptz,
  ended_at          timestamptz,
  working_seconds   bigint,
  paid_seconds      bigint,
  is_capped         boolean,
  needs_correction  boolean,
  has_correction    boolean
)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('workday.team');
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 91 then
    raise exception 'the range must run forward and cover at most 92 days' using errcode = 'CMA04';
  end if;
  return query
    select s.user_id, u.display_name::text, coalesce(o.name, '')::text, s.business_date, s.timezone::text,
           s.status::text, s.started_at, s.ended_at, s.working_seconds, s.paid_seconds,
           s.is_capped, s.needs_correction, s.has_correction
    from cma.workday_summary s
    join cma.app_user u on u.tenant_id = s.tenant_id and u.id = s.user_id
    left join cma.organisation o on o.tenant_id = u.tenant_id and o.id = u.organisation_id
    where s.business_date between p_from and p_to
      and (p_user_id is null or s.user_id = p_user_id)
    order by s.business_date, u.display_name, s.user_id;
end
$$;

-- Every event of one day, effective or not, with who approved a correction
create or replace function cma.team_day(p_user_id uuid, p_business_date date)
returns table (
  event_id            uuid,
  kind                text,
  status_key          text,
  status_name         text,
  occurred_at         timestamptz,
  recorded_at         timestamptz,
  source              text,
  supersedes_event_id uuid,
  reason              text,
  approved_by_name    text,
  is_effective        boolean
)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('workday.team');
  return query
    select e.id, e.kind::text, ws.key::text, ws.name::text, e.occurred_at, e.recorded_at, e.source::text,
           e.supersedes_event_id, e.reason, a.display_name::text,
           exists (select 1 from cma.time_event_effective f where f.tenant_id = e.tenant_id and f.id = e.id)
    from cma.time_event e
    join cma.workday w on w.tenant_id = e.tenant_id and w.id = e.workday_id
    left join cma.work_status ws on ws.tenant_id = e.tenant_id and ws.id = e.status_id
    left join cma.app_user a on a.tenant_id = e.tenant_id and a.id = e.approved_by
    where w.tenant_id = cma.current_tenant_id()
      and w.user_id = p_user_id and w.business_date = p_business_date
    order by e.occurred_at, e.recorded_at, e.id;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. Record the migration
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0003', 'Corrections: correct_workday (also Add day), team_hours, team_day, CMA06, nothing before the start')
on conflict (version) do nothing;

reset role;
