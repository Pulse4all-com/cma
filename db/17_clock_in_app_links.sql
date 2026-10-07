-- =============================================================================================
-- 17_clock_in_app_links.sql: addition 0003d, the time-kept guard and app links
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database.
-- Rerunnable. Run as your own IAM login, dev first, then prod; then 18_verify_clock_in_app_links.sql,
-- then rerun 02_seed_<customer>.sql for the customer's app links.
--
--   cma.time_is_kept(user)      one definition of "this person's time is kept": active in the
--                               current tenant and holding workday.own. team_people() lists
--                               exactly these people since 0003a; now the writes use it too
--   cma.assert_time_kept(user)  raises CMA06 when it is not
--   cma.open_workday()          creates a day only for someone whose time is kept (the acting
--                               user); an existing day, open or ended, is still returned unchanged
--   cma.correct_workday()       Add day (a correction on a date without a day) creates a day only
--                               for someone whose time is kept; editing an existing day stays as
--                               it was, so a leaver's last days can still be corrected
--   cma.team_people()           unchanged in behaviour, now on time_is_kept()
--   cma.app_link                buttons to other applications on the Welcome page: label, address
--                               (https only), an optional permission that must be held to see it,
--                               order and status. Tenant configuration, never customer data. The
--                               application reads it; writes come with the configuration screens
--   cma.app_links()             the active links the acting user may see, in order
--   cma_read.app_link           reporting view
--
-- Increment (e) of Roadmap step 2: the Welcome page with an explicit Clock in. A visit no longer
-- opens a workday; the application calls open_workday() only from the Clock in action. The guard
-- here makes sure no path, this application's or another tool's, creates a day for a person whose
-- time is not kept (analytics in the default ladder). Numbered 0003d so the planned migrations
-- keep 0004 to 0009.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;

-- ---------------------------------------------------------------------------------------------
-- 1. One definition of "time is kept"
-- ---------------------------------------------------------------------------------------------
-- Active in the current tenant and holding workday.own. Permissions are catalog keys from the
-- application, never role names, so a tenant that gives a role of its own the clock is covered.
create or replace function cma.time_is_kept(p_user_id uuid)
returns boolean
language sql stable
as $$
  select exists (
    select 1 from cma.app_user u
    where u.tenant_id = cma.current_tenant_id() and u.id = p_user_id and u.status = 'active'
  ) and cma.has_permission(p_user_id, 'workday.own')
$$;

-- CMA06 (not permitted), the same code the team reads use for a missing permission.
create or replace function cma.assert_time_kept(p_user_id uuid)
returns void
language plpgsql stable
as $$
begin
  if p_user_id is null or not cma.time_is_kept(p_user_id) then
    raise exception 'time is not kept for user % (not active, or without workday.own)', p_user_id
      using errcode = 'CMA06';
  end if;
end
$$;

-- team_people() keeps its contract (0003a) and now reads the shared definition
create or replace function cma.team_people()
returns table (
  user_id           uuid,
  display_name      text,
  organisation_name text,
  timezone          text
)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('workday.team');
  return query
    select u.id, u.display_name::text, coalesce(o.name, '')::text, cma.user_timezone(u.id)::text
    from cma.app_user u
    left join cma.organisation o on o.tenant_id = u.tenant_id and o.id = u.organisation_id
    where u.tenant_id = cma.current_tenant_id()
      and cma.time_is_kept(u.id)
    order by u.display_name, u.id;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. open_workday: the guard sits where a day is created
-- ---------------------------------------------------------------------------------------------
-- As in 0002: idempotent, the existing day is returned whether it is open or ended (an ended day
-- stays ended). New: a day is created only for someone whose time is kept (CMA06 otherwise).
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
-- 3. correct_workday: Add day only for someone whose time is kept
-- ---------------------------------------------------------------------------------------------
-- As in 0003, with one line added where the day is created. Editing an existing day is unchanged.
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
-- 4. App links: buttons to other applications, per tenant
-- ---------------------------------------------------------------------------------------------
-- Deep links only (https), never customer data. permission_key: the link is shown only to people
-- holding it; null means everyone with a role. Which applications a tenant links to is its own
-- configuration (02_seed_<customer>.sql now, the configuration screens of step 5 later); no
-- address lives in code.
create table if not exists cma.app_link (
  id              uuid primary key default uuidv7(),
  tenant_id       uuid not null default cma.current_tenant_id() references cma.tenant (id),
  key             text not null check (key ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  label           text not null check (length(btrim(label)) between 1 and 60),
  address         text not null check (address ~ '^https://[^[:space:]]+$' and length(address) <= 2000),
  permission_key  text references cma.permission (key),
  sort_order      integer not null default 100,
  status          text not null default 'active' check (status in ('active', 'inactive')),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, key)
);
comment on table cma.app_link is 'Buttons to other applications on the Welcome page, per tenant: label, https address, optional permission needed to see it, order. Deep links only, no customer data';
comment on column cma.app_link.permission_key is 'Shown only to people holding this permission; null means everyone with a role';
create or replace trigger set_updated_at before update on cma.app_link
  for each row execute function cma.set_updated_at();

select cma.setup_tenant_table('cma.app_link');
-- The application reads links; writing them is configuration work for the screens of step 5
revoke insert, update, delete on cma.app_link from cma_app;

-- The active links the acting user may see, in the tenant's order. Needs an acting user (CMA01).
create or replace function cma.app_links()
returns table (key text, label text, address text, sort_order integer)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_user uuid := cma.current_user_id();
begin
  if v_user is null then
    raise exception 'app_links needs app.user_id, the acting user' using errcode = 'CMA01';
  end if;
  if not exists (select 1 from cma.app_user
                 where tenant_id = cma.current_tenant_id() and id = v_user and status = 'active') then
    raise exception 'user % is not an active user of the current tenant', v_user using errcode = 'CMA01';
  end if;
  return query
    select l.key::text, l.label::text, l.address::text, l.sort_order
    from cma.app_link l
    where l.tenant_id = cma.current_tenant_id()
      and l.status = 'active'
      and (l.permission_key is null or cma.has_permission(v_user, l.permission_key))
    order by l.sort_order, l.key;
end
$$;

revoke execute on function cma.app_links() from public;
grant execute on function cma.app_links() to cma_app;

create or replace view cma_read.app_link as
  select id, tenant_id, key, label, address, permission_key, sort_order, status, created_at, updated_at
  from cma.app_link
  where cma_read.reader_sees(tenant_id);

-- ---------------------------------------------------------------------------------------------
-- 5. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0003d', 'Clock in and app links: time_is_kept guard on day creation (open_workday, Add day), app_link table and app_links()')
on conflict (version) do nothing;

reset role;
