-- =============================================================================================
-- 46_workday_window.sql: addition 0008b, the workday window and the forgotten-day close
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 44_assignment_alerts.sql (0008a). Rerunnable, forward-only. Run as your own IAM login, dev first,
-- then prod; then 47_verify_workday_window.sql, then 02_seed_<customer>.sql again for the
-- customer's window, then 27_verify_configuration.sql, 43_verify_messaging.sql and
-- 45_verify_assignment_alerts.sql again (unchanged).
--
-- What it adds (README Features 1; Martin's decisions of 12 October 2026)
--   the window         settings workday.window_start (default 00:00) and workday.window_end (default
--                      24:00): a working day runs between them on its business date, in the day's
--                      zone. The defaults are today's behaviour, so a tenant that sets nothing sees
--                      no change. A new value type 'time' (HH:MI, 00:00 to 24:00) in the catalog
--   the day's bounds   cma.business_day_end(date, zone) now reads the current tenant's window end
--                      (24:00 is the next midnight, as before); cma.business_day_start(date, zone)
--                      is new. The time views read the window of each row's own tenant, so the
--                      readers' views follow too: the counted time of every stretch stops at the
--                      window end, an open day is capped there and flagged as before
--   clock in           cma.open_workday() refuses a new day before the window start (CMA04, "the
--                      workday starts at HH:MI"); status changes and clock-outs after the window
--                      end stay accepted (leaving is never blocked), their time is not counted
--   corrections        cma.correct_workday() and cma.correct_time_event() set times only within
--                      the corrected day's window
--   the close          cma.close_forgotten_workdays(): a day still open after the window end plus
--                      workday.auto_close_grace_minutes is ended at the person's published planned
--                      shift end for that date, else at workday.auto_close_at (default 24:00, the
--                      window end); never before the day's last effective event and never after the
--                      window end. Returns how the end was chosen (shift, default, last_event). In
--                      the same transaction: one message per closed day to that person, and per
--                      run one digest, without names, to every active person holding the setting
--                      workday.auto_close_notify_permission (default workday.team)
--
-- SQLSTATEs as before: CMA01 no acting user, CMA02 not found, CMA03 conflict, CMA04 invalid,
-- CMA05 tenant configuration missing, CMA06 not permitted.
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
set role cma_owner;

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0008a') then
    raise exception 'addition 0008a (44_assignment_alerts.sql) must run before 0008b';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Settings: the value type 'time' and the four workday settings
-- ---------------------------------------------------------------------------------------------
alter table cma.setting drop constraint if exists setting_value_type_check;
alter table cma.setting add constraint setting_value_type_check
  check (value_type in ('text', 'boolean', 'integer', 'date', 'time'));
alter table cma.setting drop constraint if exists setting_time_default_check;
alter table cma.setting add constraint setting_time_default_check
  check (value_type <> 'time' or default_value ~ '^(([01][0-9]|2[0-3]):[0-5][0-9]|24:00)$');

insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('workday.window_start',                 'time', null, '00:00',
     'Earliest clock-in of a working day, local time in the day''s zone (HH:MI)'),
  ('workday.window_end',                   'time', null, '24:00',
     'End of a working day, local time in the day''s zone (HH:MI, 24:00 is midnight): time after it is not counted, the forgotten-day close counts its grace from it'),
  ('workday.auto_close_at',                'time', null, '24:00',
     'Where the scheduler ends a forgotten day when the person has no published shift that day (HH:MI); never after the window end'),
  ('workday.auto_close_notify_permission', 'text', null, 'workday.team',
     'People holding this permission receive the digest of workdays the scheduler closed')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;
update cma.setting
set description = 'Minutes after the end of the workday window before the scheduler ends a workday that was never clocked out'
where key = 'workday.auto_close_grace_minutes';

-- As 0007, plus a time as HH:MI (24:00 allowed), a window that starts before it ends, and a
-- notification permission from the catalog
create or replace function cma.check_tenant_setting()
returns trigger
language plpgsql
as $$
declare
  s       cma.setting;
  v_other time;
begin
  select * into s from cma.setting where key = new.key;
  if not found then
    raise exception 'Unknown setting %', new.key using errcode = 'CMA02';
  end if;
  if s.value_type = 'boolean' and new.value not in ('true', 'false') then
    raise exception 'Setting % takes true or false', new.key using errcode = 'CMA04';
  end if;
  if s.value_type = 'integer' and new.value !~ '^-?[0-9]+$' then
    raise exception 'Setting % takes a whole number', new.key using errcode = 'CMA04';
  end if;
  if s.value_type = 'date' then
    if new.value !~ '^\d{4}-\d{2}-\d{2}$' then
      raise exception 'Setting % takes a date as YYYY-MM-DD', new.key using errcode = 'CMA04';
    end if;
    begin
      perform new.value::date;
    exception when others then
      raise exception 'Setting % takes a date as YYYY-MM-DD', new.key using errcode = 'CMA04';
    end;
  end if;
  if s.value_type = 'time' and new.value !~ '^(([01][0-9]|2[0-3]):[0-5][0-9]|24:00)$' then
    raise exception 'Setting % takes a time as HH:MI, 00:00 to 24:00', new.key using errcode = 'CMA04';
  end if;
  if s.allowed_values is not null and not (new.value = any (s.allowed_values)) then
    raise exception 'Setting % takes one of: %', new.key, array_to_string(s.allowed_values, ', ')
      using errcode = 'CMA04';
  end if;
  -- the window starts before it ends, against the other bound's effective value
  if new.key = 'workday.window_start' then
    v_other := cma.setting_of(new.tenant_id, 'workday.window_end')::time;
    if new.value::time >= v_other then
      raise exception 'The workday window must start before it ends (%)', to_char(v_other, 'HH24:MI') using errcode = 'CMA04';
    end if;
  elsif new.key = 'workday.window_end' then
    v_other := cma.setting_of(new.tenant_id, 'workday.window_start')::time;
    if new.value::time <= v_other then
      raise exception 'The workday window must end after it starts (%)', to_char(v_other, 'HH24:MI') using errcode = 'CMA04';
    end if;
  elsif new.key = 'workday.auto_close_notify_permission' and not exists (select 1 from cma.permission p where p.key = new.value) then
    raise exception 'Setting % takes a permission key', new.key using errcode = 'CMA04';
  end if;
  new.updated_by := cma.current_user_id();
  return new;
end
$$;
revoke execute on function cma.check_tenant_setting() from public;

-- ---------------------------------------------------------------------------------------------
-- 2. The day's bounds
-- ---------------------------------------------------------------------------------------------
-- A local time on a business date in a zone; 24:00 is the next midnight
create or replace function cma.business_day_time(p_date date, p_timezone text, p_time time)
returns timestamptz
language sql stable
as $$
  select (p_date + p_time) at time zone p_timezone
$$;

-- First instant after a working day: the current tenant's window end (default 24:00, the next
-- midnight, as in 0002). Every function that bounds a day calls this one
create or replace function cma.business_day_end(p_date date, p_timezone text)
returns timestamptz
language sql stable
as $$
  select cma.business_day_time(p_date, p_timezone, cma.setting_of(cma.current_tenant_id(), 'workday.window_end')::time)
$$;

-- First instant of a working day: the current tenant's window start (default 00:00, midnight)
create or replace function cma.business_day_start(p_date date, p_timezone text)
returns timestamptz
language sql stable
as $$
  select cma.business_day_time(p_date, p_timezone, cma.setting_of(cma.current_tenant_id(), 'workday.window_start')::time)
$$;

-- The core views as in 0002 and 0005a, with the window end of each row's own tenant (read here in
-- the owner's rights, so the readers' faces follow without access to the settings). One change in
-- the counting: every stretch stops at the window end, not only an open one; a stretch that begins
-- after it counts nothing. is_capped keeps its meaning: an open day past its end. Same columns.
create or replace view cma.time_interval_all as
  with ordered as (
    select e.tenant_id, e.workday_id, e.user_id, e.id as event_id, e.kind, e.status_id, e.occurred_at,
           lead(e.occurred_at) over (partition by e.workday_id order by e.occurred_at, e.recorded_at, e.id) as next_at,
           cma.business_day_time(w.business_date, w.timezone,
             (select coalesce(ts.value, st.default_value)::time
              from cma.setting st
              left join cma.tenant_setting ts on ts.tenant_id = w.tenant_id and ts.key = st.key
              where st.key = 'workday.window_end')) as day_end
    from cma.time_event_effective_all e
    join cma.workday w on w.tenant_id = e.tenant_id and w.id = e.workday_id
  )
  select tenant_id, workday_id, user_id, event_id, status_id,
         occurred_at as from_at,
         next_at     as to_at,
         next_at is null as is_open,
         next_at is null and now() > day_end as is_capped,
         greatest(0, floor(extract(epoch from (least(coalesce(next_at, now()), day_end) - occurred_at))))::bigint as seconds
  from ordered
  where kind in ('start', 'status');

create or replace view cma.workday_summary_all as
  select w.id as workday_id, w.tenant_id, w.user_id, w.business_date, w.timezone, w.status,
         w.started_at, w.ended_at,
         coalesce(sum(i.seconds) filter (where s.is_working),    0)::bigint as working_seconds,
         coalesce(sum(i.seconds) filter (where s.is_productive), 0)::bigint as productive_seconds,
         coalesce(sum(i.seconds) filter (where s.is_paid),       0)::bigint as paid_seconds,
         coalesce(sum(i.seconds) filter (where s.is_billable),   0)::bigint as billable_seconds,
         coalesce(bool_or(i.is_capped), false) as is_capped,
         ((w.status = 'open'
           and now() > cma.business_day_time(w.business_date, w.timezone,
                         (select coalesce(ts.value, st.default_value)::time
                          from cma.setting st
                          left join cma.tenant_setting ts on ts.tenant_id = w.tenant_id and ts.key = st.key
                          where st.key = 'workday.window_end')))
          or exists (select 1 from cma.time_event_effective_all e
                     where e.tenant_id = w.tenant_id and e.workday_id = w.id and e.kind = 'end' and e.source = 'system')) as needs_correction,
         exists (select 1 from cma.time_event e
                 where e.tenant_id = w.tenant_id and e.workday_id = w.id and e.source = 'correction') as has_correction,
         (select e.status_id from cma.time_event_effective_all e
          where e.tenant_id = w.tenant_id and e.workday_id = w.id and e.kind in ('start', 'status')
          order by e.occurred_at desc, e.recorded_at desc limit 1) as current_status_id
  from cma.workday w
  left join cma.time_interval_all i on i.tenant_id = w.tenant_id and i.workday_id = w.id
  left join cma.work_status s on s.tenant_id = i.tenant_id and s.id = i.status_id
  group by w.id;

-- The core views stay for the owner and the faces only (as 0002)
revoke all on cma.time_interval_all, cma.workday_summary_all from cma_app, cma_readonly, public;

-- ---------------------------------------------------------------------------------------------
-- 3. Clock in: not before the window start
-- ---------------------------------------------------------------------------------------------
-- As in 0003d, with one check where a day is created: a clock-in before the window start of its
-- business date is refused (CMA04, "the workday starts at HH:MI"). An existing day, open or ended,
-- is still returned unchanged. Nothing is checked against the window end: status changes and
-- clock-outs after it are accepted and their time is not counted.
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
-- 4. Corrections: only within the corrected day's window
-- ---------------------------------------------------------------------------------------------
-- correct_time_event as in 0003, plus the window of the day for every time it sets
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
  if p_kind <> 'void' and (p_occurred_at < cma.business_day_start(w.business_date, w.timezone)
                           or p_occurred_at > cma.business_day_end(w.business_date, w.timezone)) then
    raise exception 'a corrected time must lie within the day''s window' using errcode = 'CMA04';
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

-- correct_workday as in 0003d, with the day's bounds from the window: from its start to its end
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

  -- Add day: a day is created only for someone whose time is kept (0003d)
  if not v_exists then
    perform cma.assert_time_kept(p_user_id);
  end if;

  v_tz := coalesce(w.timezone, cma.user_timezone(p_user_id));
  if p_business_date > cma.business_date(now(), v_tz) then
    raise exception 'the date must be today or earlier in the person''s zone' using errcode = 'CMA04';
  end if;
  v_from := cma.business_day_start(p_business_date, v_tz);
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
      raise exception 'change %: the time must lie within the corrected day''s window and not in the future', v_n
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
-- 5. The forgotten-day close: the end rule and the notices
-- ---------------------------------------------------------------------------------------------
-- The result gains end_rule, so the function is replaced once (its grants follow in section 6)
do $$
begin
  if to_regprocedure('cma.close_forgotten_workdays(integer)') is not null
     and not exists (select 1 from pg_proc p
                     where p.oid = to_regprocedure('cma.close_forgotten_workdays(integer)')
                       and 'end_rule' = any (p.proargnames)) then
    drop function cma.close_forgotten_workdays(integer);
  end if;
end
$$;

-- Ends every open workday of the current tenant whose window ended more than the grace ago (the
-- parameter, else workday.auto_close_grace_minutes). The end is the person's published planned
-- shift end for that date (the latest publication's entry, when it is a shift), else
-- workday.auto_close_at, never later than the window end and never earlier than the day's last
-- effective event; end_rule says which: 'shift', 'default' or 'last_event'. Source 'system', the
-- scheduler as acting user and sender, actor label 'scheduler'. Then one message per closed day to
-- that person and one digest per run to the holders of workday.auto_close_notify_permission, both
-- without names. The day stays needs_correction (0005a). Idempotent: a second run closes and sends
-- nothing.
create or replace function cma.close_forgotten_workdays(p_grace_minutes integer default null)
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

-- ---------------------------------------------------------------------------------------------
-- 6. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  -- the redefined write functions keep their privileges (create or replace); the day's bounds read
  -- the tenant's settings, so they are the application's like cma.setting_of; business_day_time is
  -- plain arithmetic and stays public like cma.business_date
  foreach f in array array[
    'cma.business_day_end(date,text)',
    'cma.business_day_start(date,text)',
    'cma.close_forgotten_workdays(integer)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

insert into cma.schema_migration (version, description)
values ('0008b', 'Workday window and forgotten-day close: window start and end per tenant (clock-in refused before the start, time counted up to the end, corrections within it), forgotten days closed at the planned shift end or the auto-close time with a notice to the person and a digest to management')
on conflict (version) do nothing;

reset role;
