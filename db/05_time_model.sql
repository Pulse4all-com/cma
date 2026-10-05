-- CMA migration 0002: time model
-- Run as yourself (IAM login), after 01_foundation.sql (0001) and 02_seed_pulse4all.sql. Safe to rerun.
-- Universal: no customer, tenant or vendor specifics; runs unchanged in dev, prod and every later
-- customer database. Dev test data follows in 06_seed_dev_time_model.sql, the proof in
-- 07_verify_time_model.sql.
--
-- What this migration adds
--   time zones   per user, with an employer (organisation) default and the tenant as last resort;
--                a workday snapshots the zone it was opened in, so a later change never moves history
--   work_status  the configurable status list per tenant (available, break, lunch, ...), each row with
--                semantic flags: is_working (the clock runs), is_productive, is_paid, is_billable.
--                Every tenant gets the same default ladder (cma.seed_default_work_statuses) and may
--                adjust it, exactly like the role ladder in 0001
--   workday      one row per user per business day in the user's zone. A header: status open or
--                ended, started_at and ended_at are DERIVED from the events by cma.refresh_workday()
--                and never set by hand. An ended day stays ended; the next day starts at the next
--                login; resuming is a correction (README decision 5 Oct 2026)
--   time_event   the facts, append-only: start, status, end. occurred_at is when it happened,
--                recorded_at when we wrote it. A correction is a new row with source 'correction',
--                a reason and an approver; it may add a missing event, replace one (supersedes_event_id)
--                or void one (kind 'void'). The database refuses update and delete for the application
--   write path   the application never inserts into these tables directly. It calls
--                cma.open_workday(), cma.set_status(), cma.end_workday() and cma.correct_time_event()
--                as cma_app with app.tenant_id and app.user_id set. The same functions serve the
--                scheduler (auto-logout, source 'system') and any later tool, so the rules live once
--   views        each computation (effective events, intervals, workday summary) is defined ONCE as an
--                unfiltered core view cma.<name>_all, owned by cma_owner and readable by nobody else.
--                It has two faces: cma.<name> for the application, filtered on the current tenant
--                (fail closed: no tenant set, no rows), and cma_read.<name> for readers, filtered with
--                reader_sees(). A view owned by cma_owner bypasses row-level security, so the core view
--                is never granted and every face carries its filter; verify block F proves it
--   identity     cma.find_tenants_for_identity(system, external_id): the one SECURITY DEFINER lookup
--                the login needs before a tenant is known; returns tenant ids only (README,
--                Authentication). cma.user_permissions() and cma.has_permission() for the API
--
-- Conventions: see the header of 01_foundation.sql. In addition, every query inside the functions
-- below filters on cma.current_tenant_id() explicitly, so they behave the same under cma_app (RLS)
-- and under cma_owner (seeds, fixes), and a forgotten tenant can never widen a write.
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

-- ---------------------------------------------------------------------------------------------
-- 1. Time zone helpers and per-user time zone
-- ---------------------------------------------------------------------------------------------

-- True for NULL and for every IANA name Postgres knows (Europe/Madrid, UTC, ...).
create or replace function cma.is_timezone(p_name text)
returns boolean
language plpgsql stable
as $$
begin
  if p_name is null then
    return true;
  end if;
  perform now() at time zone p_name;     -- raises invalid_parameter_value for an unknown name
  return true;
exception
  when invalid_parameter_value then
    return false;
end
$$;

alter table cma.tenant drop constraint if exists tenant_timezone_valid;
alter table cma.tenant add constraint tenant_timezone_valid check (cma.is_timezone(timezone));

alter table cma.organisation add column if not exists timezone text;
alter table cma.organisation drop constraint if exists organisation_timezone_valid;
alter table cma.organisation add constraint organisation_timezone_valid check (cma.is_timezone(timezone));
comment on column cma.organisation.timezone is 'IANA name. Default zone for the people this employer employs; NULL means the tenant zone';

alter table cma.app_user add column if not exists timezone text;
alter table cma.app_user drop constraint if exists app_user_timezone_valid;
alter table cma.app_user add constraint app_user_timezone_valid check (cma.is_timezone(timezone));
comment on column cma.app_user.timezone is 'IANA name. Personal zone; NULL means the employer zone, then the tenant zone (cma.user_timezone)';

-- The zone a user''s days are counted in: personal, then employer, then tenant.
-- Invoker rights: under cma_app row-level security applies, under cma_owner the explicit tenant filter does.
create or replace function cma.user_timezone(p_user_id uuid)
returns text
language sql stable
as $$
  select coalesce(u.timezone, o.timezone, t.timezone)
  from cma.app_user u
  join cma.tenant t on t.id = u.tenant_id
  left join cma.organisation o on o.tenant_id = u.tenant_id and o.id = u.organisation_id
  where u.id = p_user_id
    and u.tenant_id = cma.current_tenant_id()
$$;

-- The calendar day an instant falls on in a zone. Night shifts belong to the day they start.
create or replace function cma.business_date(p_at timestamptz, p_timezone text)
returns date
language sql stable
as $$
  select (p_at at time zone p_timezone)::date
$$;

-- First instant after a business day in a zone, for capping open intervals
create or replace function cma.business_day_end(p_date date, p_timezone text)
returns timestamptz
language sql stable
as $$
  select ((p_date + 1)::timestamp) at time zone p_timezone
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. Work statuses: the configurable list per tenant, with semantic flags
-- ---------------------------------------------------------------------------------------------
create table if not exists cma.work_status (
  id             uuid primary key default uuidv7(),
  tenant_id      uuid not null default cma.current_tenant_id() references cma.tenant (id),
  key            text not null check (key ~ '^[a-z0-9_]+$'),
  name           text not null,
  is_working     boolean not null,                 -- the clock runs (hours for the agent)
  is_productive  boolean not null,                 -- customer-facing work, for productivity metrics
  is_paid        boolean not null,                 -- counts towards paid hours
  is_billable    boolean not null,                 -- counts towards hours billed to or by the employer
  is_default     boolean not null default false,   -- the status a workday opens in; one per tenant
  sort_order     integer not null default 100,
  status         text not null default 'active' check (status in ('active', 'inactive')),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, key),
  check (not is_default or is_working)             -- a day cannot open in a non-working status
);
comment on table cma.work_status is 'Statuses an agent can be in during a workday. Per-tenant configuration with semantic flags; billing, adherence and reports use the flags, never the key';
create unique index if not exists work_status_one_default_idx
  on cma.work_status (tenant_id) where is_default and status = 'active';
create or replace trigger set_updated_at before update on cma.work_status
  for each row execute function cma.set_updated_at();

-- The default ladder. Changing it is a migration; a tenant can still adjust its own rows
-- (rename, flags, add, set inactive). To confirm with the call center manager per tenant.
create or replace function cma.seed_default_work_statuses(p_tenant_id uuid)
returns void
language plpgsql
as $$
begin
  insert into cma.work_status (tenant_id, key, name, is_working, is_productive, is_paid, is_billable, is_default, sort_order)
  select p_tenant_id, v.key, v.name, v.is_working, v.is_productive, v.is_paid, v.is_billable, v.is_default, v.sort_order
  from (values
    ('available', 'Available', true,  true,  true,  true,  true,  10),
    ('training',  'Training',  true,  false, true,  true,  false, 20),
    ('meeting',   'Meeting',   true,  false, true,  true,  false, 30),
    ('break',     'Break',     false, false, true,  true,  false, 40),
    ('lunch',     'Lunch',     false, false, false, false, false, 50)
  ) as v(key, name, is_working, is_productive, is_paid, is_billable, is_default, sort_order)
  on conflict (tenant_id, key) do nothing;
end
$$;

-- create_tenant now also seeds the status ladder (same signature as 0001, replaced in place)
create or replace function cma.create_tenant(p_slug text, p_name text, p_timezone text default 'UTC')
returns uuid
language plpgsql
as $$
declare
  v_id uuid;
begin
  insert into cma.tenant (slug, name, timezone)
  values (p_slug, p_name, p_timezone)
  on conflict (slug) do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id from cma.tenant where slug = p_slug;
  end if;

  perform cma.seed_default_roles(v_id);
  perform cma.seed_default_work_statuses(v_id);
  return v_id;
end
$$;

-- Tenants that already exist get the ladder now (universal: no tenant is named)
do $$
declare
  t record;
begin
  for t in select id from cma.tenant loop
    perform cma.seed_default_work_statuses(t.id);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. Workday header and time events
-- ---------------------------------------------------------------------------------------------

-- One row per user per business day. started_at, ended_at and status are derived from the
-- effective events by cma.refresh_workday(); the write functions are the only path that touches them.
create table if not exists cma.workday (
  id             uuid primary key default uuidv7(),
  tenant_id      uuid not null default cma.current_tenant_id() references cma.tenant (id),
  user_id        uuid not null,
  business_date  date not null,
  timezone       text not null check (cma.is_timezone(timezone)),   -- snapshot at open
  status         text not null default 'open' check (status in ('open', 'ended')),
  started_at     timestamptz not null,
  ended_at       timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, id, user_id),               -- lets time_event prove its user_id matches the day
  unique (tenant_id, user_id, business_date),
  check (ended_at is null or ended_at >= started_at),
  check ((status = 'ended') = (ended_at is not null)),
  foreign key (tenant_id, user_id) references cma.app_user (tenant_id, id)
);
comment on table cma.workday is 'One workday per user per business day in the user''s zone. Header only: times and status are derived from cma.time_event';
comment on column cma.workday.timezone is 'Zone the day was opened in. Fixed for the life of the row so a later zone change never moves history';
create index if not exists workday_user_date_idx on cma.workday (tenant_id, user_id, business_date desc);
create index if not exists workday_open_idx on cma.workday (tenant_id, business_date) where status = 'open';
create or replace trigger set_updated_at before update on cma.workday
  for each row execute function cma.set_updated_at();

-- The facts. Append-only for everyone but the owner (enforced by privileges in section 5).
--   kind      start | status | end | void      (void only as a correction that cancels another event)
--   source    user (own click) | system (scheduler, auto-logout) | correction (a person with
--             workday.team, with reason and approver)
--   effective an event is effective while no other event supersedes it. Corrections form a chain:
--             a later correction supersedes the earlier correction, never the original again
create table if not exists cma.time_event (
  id                   uuid primary key default uuidv7(),
  tenant_id            uuid not null default cma.current_tenant_id() references cma.tenant (id),
  workday_id           uuid not null,
  user_id              uuid not null,
  kind                 text not null check (kind in ('start', 'status', 'end', 'void')),
  status_id            uuid,
  occurred_at          timestamptz not null,
  recorded_at          timestamptz not null default clock_timestamp(),
  source               text not null check (source in ('user', 'system', 'correction')),
  supersedes_event_id  uuid,
  reason               text constraint time_event_reason_length check (reason is null or length(btrim(reason)) >= 3),
  approved_by          uuid,
  unique (tenant_id, id),
  constraint time_event_status_for_kind          check ((kind in ('start', 'status')) = (status_id is not null)),
  constraint time_event_void_needs_target        check (kind <> 'void' or supersedes_event_id is not null),
  constraint time_event_correction_needs_reason_and_approver
                                                 check ((source = 'correction') = (reason is not null and approved_by is not null)),
  constraint time_event_supersedes_only_by_correction
                                                 check (supersedes_event_id is null or source = 'correction'),
  constraint time_event_not_self                 check (supersedes_event_id is distinct from id),
  foreign key (tenant_id, workday_id, user_id)  references cma.workday     (tenant_id, id, user_id),
  foreign key (tenant_id, status_id)            references cma.work_status (tenant_id, id),
  foreign key (tenant_id, approved_by)          references cma.app_user    (tenant_id, id),
  foreign key (tenant_id, supersedes_event_id)  references cma.time_event  (tenant_id, id)
);
comment on table cma.time_event is 'Clock-in, status change and clock-out facts, append-only. occurred_at = when it happened, recorded_at = when we wrote it. Corrections are new rows with reason and approver';
create index if not exists time_event_workday_idx on cma.time_event (tenant_id, workday_id, occurred_at);
create index if not exists time_event_user_idx    on cma.time_event (tenant_id, user_id, occurred_at);
create unique index if not exists time_event_supersedes_idx
  on cma.time_event (tenant_id, supersedes_event_id) where supersedes_event_id is not null;   -- one correction per event

-- ---------------------------------------------------------------------------------------------
-- 4. Views: one core definition per computation, a tenant-filtered face for the application
-- ---------------------------------------------------------------------------------------------
-- The *_all views are owned by cma_owner, so they see every tenant (the owner is not subject to
-- row-level security). They are revoked from cma_app in section 5 and only ever read through a
-- filtered face: cma.<name> (current tenant, this section) or cma_read.<name> (readers, section 8).

-- Events that count: not superseded by a correction, and not the void markers themselves
create or replace view cma.time_event_effective_all as
  select e.id, e.tenant_id, e.workday_id, e.user_id, e.kind, e.status_id, e.occurred_at, e.recorded_at,
         e.source, e.supersedes_event_id, e.reason, e.approved_by
  from cma.time_event e
  where e.kind in ('start', 'status', 'end')
    and not exists (
      select 1 from cma.time_event c
      where c.tenant_id = e.tenant_id and c.supersedes_event_id = e.id
    );

-- One row per period in a status: from an effective start or status event to the next effective
-- event of the day. An open day runs to now(), capped at the end of its business day; is_capped
-- marks a day that was never ended and needs a correction or the scheduler.
create or replace view cma.time_interval_all as
  with ordered as (
    select e.tenant_id, e.workday_id, e.user_id, e.id as event_id, e.kind, e.status_id, e.occurred_at,
           lead(e.occurred_at) over (partition by e.workday_id order by e.occurred_at, e.recorded_at, e.id) as next_at,
           cma.business_day_end(w.business_date, w.timezone) as day_end
    from cma.time_event_effective_all e
    join cma.workday w on w.tenant_id = e.tenant_id and w.id = e.workday_id
  )
  select tenant_id, workday_id, user_id, event_id, status_id,
         occurred_at as from_at,
         next_at     as to_at,
         next_at is null as is_open,
         next_at is null and now() > day_end as is_capped,
         greatest(0, floor(extract(epoch from (coalesce(next_at, least(now(), day_end)) - occurred_at))))::bigint as seconds
  from ordered
  where kind in ('start', 'status');

-- One row per workday with the hours by flag. The application reads this for My day and My hours.
create or replace view cma.workday_summary_all as
  select w.id as workday_id, w.tenant_id, w.user_id, w.business_date, w.timezone, w.status,
         w.started_at, w.ended_at,
         coalesce(sum(i.seconds) filter (where s.is_working),    0)::bigint as working_seconds,
         coalesce(sum(i.seconds) filter (where s.is_productive), 0)::bigint as productive_seconds,
         coalesce(sum(i.seconds) filter (where s.is_paid),       0)::bigint as paid_seconds,
         coalesce(sum(i.seconds) filter (where s.is_billable),   0)::bigint as billable_seconds,
         coalesce(bool_or(i.is_capped), false) as is_capped,
         (w.status = 'open' and now() > cma.business_day_end(w.business_date, w.timezone)) as needs_correction,
         exists (select 1 from cma.time_event e
                 where e.tenant_id = w.tenant_id and e.workday_id = w.id and e.source = 'correction') as has_correction,
         (select e.status_id from cma.time_event_effective_all e
          where e.tenant_id = w.tenant_id and e.workday_id = w.id and e.kind in ('start', 'status')
          order by e.occurred_at desc, e.recorded_at desc limit 1) as current_status_id
  from cma.workday w
  left join cma.time_interval_all i on i.tenant_id = w.tenant_id and i.workday_id = w.id
  left join cma.work_status s on s.tenant_id = i.tenant_id and s.id = i.status_id
  group by w.id;

-- The application's faces: the current tenant only; nothing when no tenant is set
create or replace view cma.time_event_effective as
  select * from cma.time_event_effective_all where tenant_id = cma.current_tenant_id();

create or replace view cma.time_interval as
  select * from cma.time_interval_all where tenant_id = cma.current_tenant_id();

create or replace view cma.workday_summary as
  select * from cma.workday_summary_all where tenant_id = cma.current_tenant_id();

-- ---------------------------------------------------------------------------------------------
-- 5. Tenant separation, audit, and append-only privileges
-- ---------------------------------------------------------------------------------------------
select cma.setup_tenant_table('cma.work_status');
select cma.setup_tenant_table('cma.workday');
select cma.setup_tenant_table('cma.time_event');

-- setup_tenant_table grants full write rights; narrow them to what the rules allow
revoke update, delete on cma.time_event  from cma_app;   -- facts are append-only; corrections are new rows
revoke delete         on cma.workday     from cma_app;   -- a day is never removed; its events are the record
revoke delete         on cma.work_status from cma_app;   -- status 'inactive' instead; events reference it

-- the unfiltered core views are for the owner and the faces only
revoke all on cma.time_event_effective_all, cma.time_interval_all, cma.workday_summary_all from cma_app, public;

-- ---------------------------------------------------------------------------------------------
-- 6. Permissions for the API
-- ---------------------------------------------------------------------------------------------

-- All permission keys a user holds through role grants (scope ignored for now; scoped checks come
-- with teams and markets). Invoker rights, tenant-filtered.
create or replace function cma.user_permissions(p_user_id uuid default cma.current_user_id())
returns setof text
language sql stable
as $$
  select distinct rp.permission_key
  from cma.user_role ur
  join cma.role_permission rp on rp.tenant_id = ur.tenant_id and rp.role_id = ur.role_id
  where ur.tenant_id = cma.current_tenant_id()
    and ur.user_id = p_user_id
$$;

create or replace function cma.has_permission(p_user_id uuid, p_permission text)
returns boolean
language sql stable
as $$
  select exists (select 1 from cma.user_permissions(p_user_id) p where p = p_permission)
$$;

-- Login step 1, before a tenant is known: which tenants have an active user with this external id?
-- The one SECURITY DEFINER function, owned by cma_owner, returns tenant ids only (README, Authentication).
-- The application then sets app.tenant_id (picker when more than one) and reads app_user as usual.
create or replace function cma.find_tenants_for_identity(p_system text, p_external_id text)
returns table (tenant_id uuid)
language sql stable security definer
set search_path = pg_catalog, cma
as $$
  select x.tenant_id
  from cma.app_user_external_id x
  join cma.app_user u on u.tenant_id = x.tenant_id and u.id = x.user_id
  join cma.tenant   t on t.id = x.tenant_id
  where x.system = p_system
    and x.external_id = p_external_id
    and u.status = 'active'
    and t.status = 'active'
  order by t.slug
$$;
revoke execute on function cma.find_tenants_for_identity(text, text) from public;
grant  execute on function cma.find_tenants_for_identity(text, text) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 7. The write path: open, status, end, correct, refresh
-- ---------------------------------------------------------------------------------------------
-- Errors carry a stable SQLSTATE so the API can map them without parsing text:
--   CMA01 no acting user (app.user_id missing) or the user is not active in this tenant
--   CMA02 not found or not yours (workday of another user, another tenant, unknown status key)
--   CMA03 the workday is already ended; resuming is a correction
--   CMA04 the correction or event is invalid (order, duplicates, missing approver rights)
--   CMA05 tenant configuration missing (no default work status)

-- Recompute the header from the effective events and validate the resulting day.
-- Called by every write function; harmless to call again.
create or replace function cma.refresh_workday(p_workday_id uuid)
returns void
language plpgsql
as $$
declare
  v_tenant    uuid := cma.current_tenant_id();
  v_starts    integer;
  v_ends      integer;
  v_started   timestamptz;
  v_ended     timestamptz;
  v_last_live timestamptz;
begin
  select count(*) filter (where kind = 'start'),
         count(*) filter (where kind = 'end'),
         min(occurred_at) filter (where kind = 'start'),
         max(occurred_at) filter (where kind = 'end'),
         max(occurred_at) filter (where kind in ('start', 'status'))
  into v_starts, v_ends, v_started, v_ended, v_last_live
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

-- Opening today''s workday for the acting user. Idempotent: the existing day is returned whether it is
-- open or ended (an ended day stays ended). The business day is p_occurred_at in the user''s zone.
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

-- The acting user changes status on their own open workday.
create or replace function cma.set_status(p_workday_id uuid, p_status_key text, p_occurred_at timestamptz default now())
returns cma.time_event
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_user   uuid := cma.current_user_id();
  v_status uuid;
  w        cma.workday;
  e        cma.time_event;
begin
  if v_user is null then
    raise exception 'set_status needs app.user_id, the acting user' using errcode = 'CMA01';
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

  select id into v_status from cma.work_status
  where tenant_id = v_tenant and key = p_status_key and status = 'active';
  if v_status is null then
    raise exception 'work status "%" is not active in this tenant', p_status_key using errcode = 'CMA02';
  end if;

  insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source)
  values (v_tenant, w.id, v_user, 'status', v_status, p_occurred_at, 'user')
  returning * into e;

  perform cma.refresh_workday(w.id);
  return e;
end
$$;

-- Ending a workday. source 'user': the acting user ends their own day. source 'system': a process
-- (scheduler auto-logout) with app.actor_label set and no app.user_id ends any open day of the tenant.
-- Corrections (ending yesterday''s forgotten day, moving an end) go through correct_time_event.
create or replace function cma.end_workday(p_workday_id uuid, p_occurred_at timestamptz default now(), p_source text default 'user')
returns cma.workday
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_user   uuid := cma.current_user_id();
  w        cma.workday;
begin
  select * into w from cma.workday where tenant_id = v_tenant and id = p_workday_id for update;
  if not found then
    raise exception 'workday % not found in the current tenant', p_workday_id using errcode = 'CMA02';
  end if;

  if p_source = 'user' then
    if v_user is null or w.user_id <> v_user then
      raise exception 'a user can only end their own workday' using errcode = 'CMA02';
    end if;
  elsif p_source = 'system' then
    if v_user is not null or cma.current_actor_label() is null then
      raise exception 'a system end needs app.actor_label and no app.user_id' using errcode = 'CMA04';
    end if;
  else
    raise exception 'source must be user or system; corrections go through correct_time_event' using errcode = 'CMA04';
  end if;

  if w.status = 'ended' then
    raise exception 'workday % is already ended; resuming is a correction', p_workday_id using errcode = 'CMA03';
  end if;
  if p_occurred_at < w.started_at or p_occurred_at > now() + interval '5 minutes' then
    raise exception 'end time must lie between the start of the workday and now' using errcode = 'CMA04';
  end if;

  insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source)
  values (v_tenant, w.id, w.user_id, 'end', null, p_occurred_at, p_source);

  perform cma.refresh_workday(w.id);
  select * into w from cma.workday where tenant_id = v_tenant and id = w.id;
  return w;
end
$$;

-- A correction: a new row with reason and approver, made by a person holding workday.team.
--   add an event        p_kind start|status|end, p_supersedes_event_id NULL
--   replace an event    p_kind start|status|end, p_supersedes_event_id = the event it replaces
--   cancel an event     p_kind 'void', p_supersedes_event_id = the event that did not happen
-- The resulting day is validated by refresh_workday; an impossible correction fails as a whole.
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
  v_user   uuid := cma.current_user_id();
  v_status uuid;
  w        cma.workday;
  e        cma.time_event;
begin
  if v_user is null then
    raise exception 'a correction needs app.user_id, the person making it' using errcode = 'CMA01';
  end if;
  if not cma.has_permission(v_user, 'workday.team') then
    raise exception 'user % may not correct time (needs workday.team)', v_user using errcode = 'CMA04';
  end if;
  if p_approved_by is null or not cma.has_permission(p_approved_by, 'workday.team') then
    raise exception 'the approver must be an active user holding workday.team' using errcode = 'CMA04';
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
          'correction', p_supersedes_event_id, btrim(p_reason), p_approved_by)
  returning * into e;

  perform cma.refresh_workday(w.id);
  return e;
end
$$;

-- Owner-only helper
revoke execute on function cma.seed_default_work_statuses(uuid) from public;

-- ---------------------------------------------------------------------------------------------
-- 8. Reporting views (owner views, readers see all tenants unless limited by app.tenant_id)
-- ---------------------------------------------------------------------------------------------
create or replace view cma_read.work_status as
  select id, tenant_id, key, name, is_working, is_productive, is_paid, is_billable, is_default,
         sort_order, status, created_at, updated_at
  from cma.work_status
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.workday as
  select id, tenant_id, user_id, business_date, timezone, status, started_at, ended_at, created_at, updated_at
  from cma.workday
  where cma_read.reader_sees(tenant_id);

-- All events including superseded ones and corrections: the full history for disputes and pay
create or replace view cma_read.time_event as
  select id, tenant_id, workday_id, user_id, kind, status_id, occurred_at, recorded_at, source,
         supersedes_event_id, reason, approved_by
  from cma.time_event
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.time_interval as
  select tenant_id, workday_id, user_id, event_id, status_id, from_at, to_at, is_open, is_capped, seconds
  from cma.time_interval_all
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.workday_summary as
  select workday_id, tenant_id, user_id, business_date, timezone, status, started_at, ended_at,
         working_seconds, productive_seconds, paid_seconds, billable_seconds,
         is_capped, needs_correction, has_correction, current_status_id
  from cma.workday_summary_all
  where cma_read.reader_sees(tenant_id);

-- Columns added to tables that already had a view in 0001. CREATE OR REPLACE VIEW only accepts new
-- columns at the end of the list, so timezone comes last here.
create or replace view cma_read.organisation as
  select id, tenant_id, key, name, status, created_at, updated_at, timezone
  from cma.organisation
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.app_user as
  select id, tenant_id, organisation_id, email, display_name, status, created_at, updated_at, timezone
  from cma.app_user
  where cma_read.reader_sees(tenant_id);

-- ---------------------------------------------------------------------------------------------
-- 9. Record the migration
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0002', 'Time model: work statuses, workdays, append-only time events with corrections, per-user time zones, identity lookup, reporting views')
on conflict (version) do nothing;
