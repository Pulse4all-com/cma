-- =============================================================================================
-- 88_callbacks_kept.sql: addition 0008w, callbacks kept (KPI 5; backlog CMA-066)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 86_journeys.sql (0008v). Rerunnable, forward-only, in one transaction. Run as your own IAM login, dev
-- first, then prod; then 89_verify_callbacks_kept.sql (dev), then 73_verify_follow_up.sql and
-- 81_verify_follow_up_snapshot.sql (dev) again (unchanged).
--
-- Brief N19-A, part 4 (stretch; business case KPI 5): of the callback tasks due in a period, how many were
-- kept: a call to the task's contact started within tasks.callback_window_minutes (0008o, 240 by default)
-- before or after the due time. Addition 0008n holds the tasks with their types (is_callback and is_counted
-- as configuration) and 0007a/0008j the calls; this addition adds the definition and its reads, for the
-- Dashboard's Intake row and Reports → Follow-up. Ids, counts and times only.
--
-- What it adds
--   definition         cma.callbacks_kept_of(tenant, from, to, now): every task of a counted callback type
--                      (connection_task_type.is_callback and is_counted), not deleted, open or done, due in
--                      [from, to) (a task without a due time: created in it), one row each with its owner
--                      (and the person through the linked accounts '<adapter>_owner'), the due date, ISO
--                      week and local time in the tenant's zone, its state and the call that kept it
--   reads              cma.callbacks_kept_report() (reports.view or performance.team): per ISO week and in
--                      total, the period and the previous period like for like; cma.callbacks_kept_per_owner()
--                      (performance.team, as Follow-up's per person, 0008o): per person by name, the owners
--                      without a person as one row, the total; cma.callbacks_kept_connected(): whether the
--                      tenant has a counted callback type at all; each over a read of an explicit tenant
--   reporting view     cma_read.callbacks_kept: every callback task since intake.start_date with its state
--
-- Definitions (one place each; README, Data model: callbacks kept)
--   callback           a task of a type flagged is_callback and is_counted, not deleted, whatever its status
--   kept               a call to the task's contact (a CRM call associated with the contact, not deleted,
--                      not inbound: outbound, or a logged call without a direction) whose start (the linked
--                      telephony call's, else the CRM's time) lies within tasks.callback_window_minutes before
--                      or after the due time, both edges included; the call is the earliest such one
--   not kept           a callback with a due time and a contact, no such call, and the window closed
--   pending            the same while the window is still open (due + window after now): neither kept nor not
--   apart              a callback without a contact ('no_contact') or without a due time ('no_due', placed by
--                      its creation): counted, never in the kept share
--   kept share         kept / (kept + not kept); pending left out until its window closes
--   date, week         the due time (a task without one: its creation) in the tenant's zone; ISO weeks from Monday
--   previous period    as 0008p: the same length before; while the period runs, its last day up to the time now
--
-- Everything is SECURITY INVOKER and executable by the application only; the reader view's function is
-- SECURITY DEFINER, owned by cma_owner, search path pinned, executable by readers only (as 0008o).
--
-- SQLSTATEs as before: CMA01 no acting user, CMA02 not found, CMA03 conflict, CMA04 invalid,
-- CMA06 not permitted.
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
set role cma_owner;

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0008v') then
    raise exception 'addition 0008v (86_journeys.sql) must run before 0008w';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The definition: every callback of a period with its state
-- ---------------------------------------------------------------------------------------------
create or replace function cma.callbacks_kept_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz, p_now timestamptz default now())
returns table (
  connection_id      uuid,
  task_source_id     text,
  source_system      text,
  owner_ref          text,
  owner_user_id      uuid,
  contact_source_id  text,
  due_at             timestamptz,
  placed_at          timestamptz,
  business_date      date,
  week_start         date,
  local_time         time,
  state              text,
  call_at            timestamptz,
  minutes_from_due   integer
)
language sql stable
set jit = off
as $$
  with s as materialized (
    select t.timezone as zone, make_interval(mins => cma.setting_of(t.id, 'tasks.callback_window_minutes')::integer) as win
    from cma.tenant t where t.id = p_tenant_id
  ),
  k as materialized (
    select k.connection_id, k.source_id, k.source_system, k.owner_ref, k.contact_source_id, k.due_at, coalesce(k.due_at, k.source_created_at) as placed_at
    from cma.crm_task k
    join cma.connection_task_type y
      on y.tenant_id = k.tenant_id and y.connection_id = k.connection_id and y.type_ref = k.type_ref and y.is_callback and y.is_counted
    where k.tenant_id = p_tenant_id and k.source_deleted_at is null
      and ((k.due_at >= p_from and k.due_at < p_to) or (k.due_at is null and k.source_created_at >= p_from and k.source_created_at < p_to))
  ),
  c as materialized (
    -- per callback, the earliest call to its contact that starts within the window around the due time: one index
    -- lookup of the contact's calls in the callback's own row (a join back to the tasks would grow with their square)
    select k.*,
           case when k.due_at is not null and k.contact_source_id is not null then
             (select min(coalesce(tc.started_at, cl.occurred_at))
              from cma.crm_association a
              join cma.crm_call cl
                on cl.tenant_id = a.tenant_id and cl.connection_id = a.connection_id and cl.source_id = a.from_id
               and cl.source_deleted_at is null and cl.direction <> 'inbound'
              -- the call's start as cma.crm_call_connected_of's effective_at: the linked telephony call's, else the CRM's
              left join cma.call_link l on l.tenant_id = cl.tenant_id and l.crm_call_id = cl.id and l.unlinked_at is null
              left join cma.telephony_call tc on tc.tenant_id = l.tenant_id and tc.id = l.telephony_call_id and tc.source_deleted_at is null
              where a.tenant_id = p_tenant_id and a.connection_id = k.connection_id and a.from_type = 'crm_call' and a.to_type = 'contact'
                and a.to_id = k.contact_source_id and a.removed_at is null
                and coalesce(tc.started_at, cl.occurred_at) between k.due_at - s.win and k.due_at + s.win)
           end as call_at
    from k
    cross join s
  )
  select c.connection_id, c.source_id, c.source_system, c.owner_ref,
         case when c.owner_ref is not null then cma.owner_user_of(p_tenant_id, c.source_system, c.owner_ref) end,
         c.contact_source_id, c.due_at, c.placed_at,
         (c.placed_at at time zone s.zone)::date,
         date_trunc('week', (c.placed_at at time zone s.zone)::date)::date,
         (c.placed_at at time zone s.zone)::time,
         case when c.due_at is null then 'no_due'
              when c.contact_source_id is null then 'no_contact'
              when c.call_at is not null then 'kept'
              when c.due_at + s.win > p_now then 'pending'
              else 'not_kept' end,
         c.call_at,
         case when c.call_at is not null then round(extract(epoch from c.call_at - c.due_at) / 60)::integer end
  from c
  cross join s
$$;

-- Whether the tenant has a counted callback type at all: without one the screens say so in words, never 0
create or replace function cma.callbacks_kept_connected_of(p_tenant_id uuid)
returns boolean
language sql stable
as $$
  select exists (select 1 from cma.connection_task_type y where y.tenant_id = p_tenant_id and y.is_callback and y.is_counted)
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. The figures: per ISO week and in total
-- ---------------------------------------------------------------------------------------------
-- callbacks = kept + not kept + pending (a due time and a contact); no_contact and no_due apart. p_until (the
-- previous period while the period runs) keeps the last day up to that time of day
create or replace function cma.callbacks_kept_figures_of(p_tenant_id uuid, p_from date, p_to date, p_now timestamptz default now(),
                                                         p_until timestamptz default null)
returns table (
  dimension    text,
  week_start   date,
  callbacks    integer,
  kept         integer,
  not_kept     integer,
  pending      integer,
  no_contact   integer,
  no_due       integer
)
language sql stable
as $$
  with s as (select t.timezone as zone from cma.tenant t where t.id = p_tenant_id),
  b as (select p_from::timestamp at time zone s.zone as from_at, (p_to + 1)::timestamp at time zone s.zone as to_at from s),
  x as (
    select x.* from b cross join s
    cross join lateral cma.callbacks_kept_of(p_tenant_id, b.from_at, b.to_at, p_now) x
    where x.business_date between p_from and p_to
      and (p_until is null or x.business_date < p_to or x.local_time <= (p_until at time zone s.zone)::time)
  )
  select case when grouping(x.week_start) = 1 then 'total' else 'week' end, x.week_start,
         (count(*) filter (where x.state in ('kept', 'not_kept', 'pending')))::integer,
         (count(*) filter (where x.state = 'kept'))::integer,
         (count(*) filter (where x.state = 'not_kept'))::integer,
         (count(*) filter (where x.state = 'pending'))::integer,
         (count(*) filter (where x.state = 'no_contact'))::integer,
         (count(*) filter (where x.state = 'no_due'))::integer
  from x
  group by grouping sets ((x.week_start), ())
  order by grouping(x.week_start), x.week_start
$$;

-- The report: the period per week and in total ('current'), the previous period's total ('previous'), like for
-- like. A period without callbacks still answers its totals (zeros), so the screens can tell none from none set
create or replace function cma.callbacks_kept_report_of(p_tenant_id uuid, p_from date, p_to date, p_now timestamptz default now())
returns table (
  period       text,
  dimension    text,
  week_start   date,
  callbacks    integer,
  kept         integer,
  not_kept     integer,
  pending      integer,
  no_contact   integer,
  no_due       integer
)
language sql stable
as $$
  select x.period, x.dimension, x.week_start, x.callbacks, x.kept, x.not_kept, x.pending, x.no_contact, x.no_due
  from (
    select 'current'::text as period, 1 as part, f.*
    from cma.callbacks_kept_figures_of(p_tenant_id, p_from, p_to, p_now) f
    union all
    select 'previous', 2, f.*
    from cma.forms_previous_of(p_tenant_id, p_from, p_to, p_now) v
    cross join lateral cma.callbacks_kept_figures_of(p_tenant_id, v.prev_from, v.prev_to, p_now, v.until) f
    where f.dimension = 'total'
  ) x
  order by x.part, x.dimension = 'total', x.week_start
$$;

-- Per person (the task's owner through the linked accounts), by name and never ranked; the owners without a
-- person as one row with how many owner ids that is (never which); the total
create or replace function cma.callbacks_kept_per_owner_of(p_tenant_id uuid, p_from date, p_to date, p_now timestamptz default now())
returns table (
  row_kind         text,
  user_id          uuid,
  display_name     text,
  unlinked_owners  integer,
  callbacks        integer,
  kept             integer,
  not_kept         integer,
  pending          integer,
  no_contact       integer
)
language sql stable
as $$
  with s as (select t.timezone as zone from cma.tenant t where t.id = p_tenant_id),
  b as (select p_from::timestamp at time zone s.zone as from_at, (p_to + 1)::timestamp at time zone s.zone as to_at from s),
  x as (
    select x.*, case when u.id is null then 'not_linked' else 'person' end as rk, u.id as uid, u.display_name as uname
    from b cross join lateral cma.callbacks_kept_of(p_tenant_id, b.from_at, b.to_at, p_now) x
    left join cma.app_user u on u.tenant_id = p_tenant_id and u.id = x.owner_user_id
    where x.business_date between p_from and p_to and x.state <> 'no_due'
  )
  select coalesce(x.rk, 'total'), x.uid, x.uname,
         case when x.rk = 'not_linked' then (count(distinct x.owner_ref))::integer end,
         (count(*) filter (where x.state in ('kept', 'not_kept', 'pending')))::integer,
         (count(*) filter (where x.state = 'kept'))::integer,
         (count(*) filter (where x.state = 'not_kept'))::integer,
         (count(*) filter (where x.state = 'pending'))::integer,
         (count(*) filter (where x.state = 'no_contact'))::integer
  from x
  group by grouping sets ((x.rk, x.uid, x.uname), ())
  order by grouping(x.rk), x.rk = 'not_linked', x.uname, x.uid
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. The application's reads (the current tenant; the permission checked again; at most 92 days)
-- ---------------------------------------------------------------------------------------------
create or replace function cma.callbacks_kept_report(p_from date, p_to date)
returns table (
  period       text,
  dimension    text,
  week_start   date,
  callbacks    integer,
  kept         integer,
  not_kept     integer,
  pending      integer,
  no_contact   integer,
  no_due       integer
)
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.report_range(v_tenant, p_from, p_to);
  return query select * from cma.callbacks_kept_report_of(v_tenant, p_from, p_to);
end
$$;

create or replace function cma.callbacks_kept_per_owner(p_from date, p_to date)
returns table (
  row_kind         text,
  user_id          uuid,
  display_name     text,
  unlinked_owners  integer,
  callbacks        integer,
  kept             integer,
  not_kept         integer,
  pending          integer,
  no_contact       integer
)
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_permission('performance.team');
  perform cma.report_range(v_tenant, p_from, p_to);
  return query select * from cma.callbacks_kept_per_owner_of(v_tenant, p_from, p_to);
end
$$;

create or replace function cma.callbacks_kept_connected()
returns boolean
language plpgsql stable
as $$
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  return cma.callbacks_kept_connected_of(cma.current_tenant_id());
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.callbacks_kept_of(uuid,timestamptz,timestamptz,timestamptz)',
    'cma.callbacks_kept_connected_of(uuid)',
    'cma.callbacks_kept_figures_of(uuid,date,date,timestamptz,timestamptz)',
    'cma.callbacks_kept_report_of(uuid,date,date,timestamptz)',
    'cma.callbacks_kept_per_owner_of(uuid,date,date,timestamptz)',
    'cma.callbacks_kept_report(date,date)',
    'cma.callbacks_kept_per_owner(date,date)',
    'cma.callbacks_kept_connected()'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. Reporting view: every callback since intake.start_date with its state; ids, codes and times
-- ---------------------------------------------------------------------------------------------
create or replace function cma_read.callbacks_kept_rows()
returns table (tenant_id uuid, connection_id uuid, task_source_id text, owner_user_id uuid, due_at timestamptz, business_date date,
               week_start date, state text, call_at timestamptz, minutes_from_due integer)
language sql stable security definer
set search_path = pg_catalog, cma, pg_temp
as $$
  select t.id, x.connection_id, x.task_source_id, x.owner_user_id, x.due_at, x.business_date, x.week_start, x.state, x.call_at, x.minutes_from_due
  from cma.tenant t
  cross join lateral cma.callbacks_kept_of(t.id, (cma.setting_of(t.id, 'intake.start_date')::date)::timestamp at time zone t.timezone,
                                           now() + interval '1 day') x
  where cma_read.reader_sees(t.id)
$$;

revoke execute on function cma_read.callbacks_kept_rows() from public;
grant execute on function cma_read.callbacks_kept_rows() to cma_readonly;

create or replace view cma_read.callbacks_kept as
  select * from cma_read.callbacks_kept_rows();

-- ---------------------------------------------------------------------------------------------
-- 6. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008w', 'Callbacks kept (KPI 5): the definition cma.callbacks_kept_of (a counted callback task kept when a call to its contact starts within tasks.callback_window_minutes of the due time; not kept, pending, no contact and no due time apart), the figures per ISO week and in total with the previous period like for like, per person for performance.team, whether a callback type is counted, the reporting view')
on conflict (version) do nothing;

commit;
reset role;
