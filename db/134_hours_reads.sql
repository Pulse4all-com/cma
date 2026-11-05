-- =============================================================================================
-- 134_hours_reads.sql: addition 0008zs, the hours reads at volume: a day's stretches and a day's summary as functions
-- called per workday, so every reader computes the days asked and not the whole history, and each day's sessions
-- on the summary's face (N06d, 6 November 2026)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after 132_perf.sql (0008zr).
-- Rerunnable, forward-only, in one transaction with a lock timeout. Run as your own IAM login, dev first, then prod
-- (before the merge of the web that reads cma.team_hours()'s sessions column: main's web runs unchanged on it, its
-- own count of the sessions still answers), then 135_verify_hours_reads.sql, then 131_time_all.sql part a.
--
-- Measured first (N06d, on a local database with verify/hours-volume-fixture.sql at six times a generous estimate
-- of prod's time events, 30,000 events and 2,500 workdays; prod on 5 November 2026: Team hours 7 days 832 ms against
-- its 50 ms budget, a manager's Welcome 31-day read 91 ms, My hours 7 days 80 ms): Team hours 7 days 388 ms, My hours
-- 7 days 400 ms. The cause was not the sessions subquery the web added in 0008zp (0.01 ms per row on
-- time_event_workday_idx) but cma.workday_summary_all itself: it groups by w.id alone, so a caller's bound on
-- business_date or user_id cannot be pushed into the view (only a grouping column's bound can), and every read
-- computed every workday of the tenant's history (every stretch, every effective event, four subqueries per day) and
-- threw away all but the days asked. Now:
--   workday_stretches_of  new, the caller's rights (the application reads its own tenant under row-level security and
--                         nothing without a tenant set): one day's stretches (46's rules) from the day's own
--                         effective events, one window over those alone (time_event_workday_idx). A function, not a
--                         view's join, so a reader of many days computes each day on its own whatever the plan: the
--                         generic plan of a pooled connection, estimating one row per tenant, had turned the view's
--                         join into one pass over the whole history and a merge (Team hours 7 days 440 ms on the
--                         seventh call of a session, 12 on the first). The planner inlines the function into the view
--                         as a lateral subquery with its window, which it never flattens (CLAUDE.md's inlining lesson
--                         is about bounds, not shape); run as a function scan it does the same
--   time_interval_all     46's stretches, driven by the workday: the day's end once per day, the stretches from the
--                         function, so a caller's bound on the day or the date lands on cma.workday; the same columns,
--                         the same values. My day's and My hours' pauses, the Live board's team read and the
--                         Dashboard's status time read it too and gain the same way
--   workday_summary_of    new, the caller's rights: one day's figures (50's rules) from the day's stretches, for the same
--                         reason; the Live board's team read joins the summary on the person and a computed date,
--                         which a grouped view could not take at all (it read every day of the tenant, 1.6 s at volume)
--   workday_summary_all   no grouping in the view any more: the workday, the day's end once, the figures from the
--                         function; its sixteen columns as before, the same values (47 A4 and 51 A5 assert the list;
--                         135 proves both views row for row against the previous definitions, kept inside the verify)
--   workday_summary       the application's face, with sessions, the day's effective clock-ins (0008zp's count, once
--                         here for every reader of the face), as a new last column
--   cma_read.time_interval, cma_read.workday_summary  the readers' views, same columns, created again as a scan of the
--                         workdays through two wrappers with the owner's rights (a function inside a view runs with
--                         the caller's rights, and a reader holds none on the tables), the readers' alone
--   workday_summary       the face recreated so it carries the new column
--   team_hours            the same rows and order with sessions as its last column (the function is dropped and created:
--                         a returned column cannot be added in place); the web and the time script read it instead of
--                         counting per row. The My hours read takes s.sessions the same way
--   team_now              recreated, the same rows: today's summary per person from a lateral with a limit, which no
--                         plan turns into a join filter over every day of the tenant (the generic plan did: 1.2 s)
-- A set-returning function is estimated at 1,000 rows unless it says otherwise (rows 1 and rows 12 here): with the
-- default, a read of 150 days was costed in the millions, the planner turned JIT on, and the first call of a session
-- paid LLVM's load (700 ms) and every call a compile (the time script read 103 ms for 31 days); with the estimates
-- right the cost stays below jit_above_cost, and team_hours and team_now carry jit = off besides, as 0008zr's set
-- functions do.
-- Measured after, same fixture: Team hours 7 days 388 ms → 16 ms (6 ms on the generic plan), 31 days 423 ms → 22 ms,
-- My hours 7 days 400 ms → 4 ms, the Live board's team read (cma.team_now, which joins the summary on the person and
-- the day) 1.6 s → 6 ms. A lesson for the time scripts: a plpgsql function's query turns to the generic plan after
-- five calls on a connection, and the web's pool keeps its connections, so prod runs the generic plan; 131 measures the
-- first calls of a fresh session. Here both plans were measured (the seventh call of a session, after another tenant).
-- No index: time_event_workday_idx and workday_user_date_idx already serve every lookup.
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
  if not exists (select 1 from cma.schema_migration where version = '0008zr') then
    raise exception 'addition 0008zr (132_perf.sql) must run before 0008zs';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. A day's stretches and a day's summary as functions, the two core views as a workday scan with a lateral call
-- ---------------------------------------------------------------------------------------------
-- The stretches of one workday (46's rules: from each effective start or status event to the next effective event of
-- the day, every stretch stopping at the day's end, an open day's last stretch running to now): one window over the
-- day's own events, found by time_event_workday_idx. A function rather than a view's join, so a reader of many days
-- computes each day on its own whatever the plan: a view joined on the workday could be planned as one pass over the
-- whole history and a merge (the generic plan of a pooled connection did, estimating one row per tenant), which this
-- shape cannot be. The caller's rights: it reads cma.time_event under the application's row-level security (the
-- effective events as time_event_effective_all defines them: start, status and end events no correction supersedes),
-- so the application reads its own tenant's days and nothing without a tenant set, as the faces do, and the planner
-- inlines it into the views (a function with the owner's rights it never inlines, and the call itself cost 0.6 ms per
-- day). The readers of cma_read, who hold no right on any table, read it through the owner's-rights wrappers of
-- section 2. rows 12: the planner's default of 1,000 rows for a function costed a month of days in the millions and
-- turned JIT on (700 ms on a session's first call for LLVM's load, a compile on every call after).
create or replace function cma.workday_stretches_of(p_tenant_id uuid, p_workday_id uuid, p_day_end timestamptz)
returns table (event_id uuid, kind text, status_id uuid, from_at timestamptz, to_at timestamptz, is_open boolean, is_capped boolean, seconds bigint)
language sql stable rows 12
as $$
  with ordered as (
    select e.id, e.kind, e.status_id, e.occurred_at,
           lead(e.occurred_at) over (order by e.occurred_at, e.recorded_at, e.id) as next_at
    from cma.time_event e
    where e.tenant_id = p_tenant_id and e.workday_id = p_workday_id
      and e.kind in ('start', 'status', 'end')
      and not exists (select 1 from cma.time_event c where c.tenant_id = e.tenant_id and c.supersedes_event_id = e.id))
  select id, kind, status_id, occurred_at, next_at,
         next_at is null,
         next_at is null and now() > p_day_end,
         greatest(0, floor(extract(epoch from (least(coalesce(next_at, now()), p_day_end) - occurred_at))))::bigint
  from ordered
  where kind in ('start', 'status')
$$;
revoke execute on function cma.workday_stretches_of(uuid, uuid, timestamptz) from public, cma_readonly;
grant execute on function cma.workday_stretches_of(uuid, uuid, timestamptz) to cma_app;

-- time_interval_all as 46 defined it (the same columns in the same order, the same values), driven by the workday:
-- the day's end once per day, the day's stretches from the function. A caller's bound on the day or the date lands
-- on cma.workday, so a day's pauses (My day, My hours), the team's stretches of a day (the Live board) and a period's
-- status time (Reports → Dashboard) read the days asked, not the history.
create or replace view cma.time_interval_all as
  select w.tenant_id, w.id as workday_id, w.user_id, x.event_id, x.status_id,
         x.from_at, x.to_at, x.is_open, x.is_capped, x.seconds
  from cma.workday w
  cross join lateral (
    select cma.business_day_time(w.business_date, w.timezone,
             (select coalesce(ts.value, st.default_value)::time
              from cma.setting st
              left join cma.tenant_setting ts on ts.tenant_id = w.tenant_id and ts.key = st.key
              where st.key = 'workday.window_end')) as day_end) d
  cross join lateral cma.workday_stretches_of(w.tenant_id, w.id, d.day_end) x;

-- One day's summary (50's rules) from the day's stretches: the seconds by flag, the capped and correction flags, the
-- current status and the sessions. A function for the same reason as the stretches: a view that grouped the days
-- itself took a caller's bound only through its grouping columns, and a join on the person and a computed date (the
-- Live board's team read) could not reach it at all and read every day of the tenant. The caller's rights, as the
-- stretches; rows 1 for the same reason
create or replace function cma.workday_summary_of(p_tenant_id uuid, p_workday_id uuid, p_day_end timestamptz)
returns table (working_seconds bigint, productive_seconds bigint, paid_seconds bigint, billable_seconds bigint, is_capped boolean,
               system_end boolean, import_clipped boolean, has_correction boolean, current_status_id uuid, sessions integer)
language sql stable rows 1
as $$
  select coalesce(sum(i.seconds) filter (where s.is_working),    0)::bigint,
         coalesce(sum(i.seconds) filter (where s.is_productive), 0)::bigint,
         coalesce(sum(i.seconds) filter (where s.is_paid),       0)::bigint,
         coalesce(sum(i.seconds) filter (where s.is_billable),   0)::bigint,
         coalesce(bool_or(i.is_capped), false),
         exists (select 1 from cma.time_event e
                 where e.tenant_id = p_tenant_id and e.workday_id = p_workday_id and e.kind = 'end' and e.source = 'system'
                   and not exists (select 1 from cma.time_event c where c.tenant_id = e.tenant_id and c.supersedes_event_id = e.id)),
         exists (select 1 from cma.import_day d
                 join cma.time_event e on e.tenant_id = d.tenant_id and e.id = d.end_event_id
                 where d.tenant_id = p_tenant_id and d.workday_id = p_workday_id and (d.closed_by_rule or d.clipped)
                   and not exists (select 1 from cma.time_event c where c.tenant_id = e.tenant_id and c.supersedes_event_id = e.id)),
         exists (select 1 from cma.time_event e
                 where e.tenant_id = p_tenant_id and e.workday_id = p_workday_id and e.source = 'correction'),
         (select e.status_id from cma.time_event e
          where e.tenant_id = p_tenant_id and e.workday_id = p_workday_id and e.kind in ('start', 'status')
            and not exists (select 1 from cma.time_event c where c.tenant_id = e.tenant_id and c.supersedes_event_id = e.id)
          order by e.occurred_at desc, e.recorded_at desc limit 1),
         (count(*) filter (where i.kind = 'start'))::integer
  from cma.workday_stretches_of(p_tenant_id, p_workday_id, p_day_end) i
  left join cma.work_status s on s.tenant_id = p_tenant_id and s.id = i.status_id
$$;
revoke execute on function cma.workday_summary_of(uuid, uuid, timestamptz) from public, cma_readonly;
grant execute on function cma.workday_summary_of(uuid, uuid, timestamptz) to cma_app;

-- The summary as 50 defined it (its sixteen columns in the same order, the same values; 47 A4 and 51 A5 assert the
-- list): the workday, the day's end once, the day's figures from the function; a day without an effective start is no
-- day, as before. No grouping in the view: a caller's bound on the tenant, the person or the date lands on cma.workday,
-- by index, and the function runs for the days found
create or replace view cma.workday_summary_all as
  select w.id as workday_id, w.tenant_id, w.user_id, w.business_date, w.timezone, w.status,
         w.started_at, w.ended_at,
         x.working_seconds, x.productive_seconds, x.paid_seconds, x.billable_seconds, x.is_capped,
         ((w.status = 'open' and now() > d.day_end) or x.system_end or x.import_clipped) as needs_correction,
         x.has_correction,
         x.current_status_id
  from cma.workday w
  cross join lateral (
    select cma.business_day_time(w.business_date, w.timezone,
             (select coalesce(ts.value, st.default_value)::time
              from cma.setting st
              left join cma.tenant_setting ts on ts.tenant_id = w.tenant_id and ts.key = st.key
              where st.key = 'workday.window_end')) as day_end) d
  cross join lateral cma.workday_summary_of(w.tenant_id, w.id, d.day_end) x
  where x.sessions > 0;
revoke all on cma.time_interval_all, cma.workday_summary_all from cma_app, cma_readonly, public;

-- The application's face, with sessions, the day's effective clock-ins, as a new last column (0008zp's count, once
-- here for every reader of the face; an index lookup per day returned). The core view keeps its columns, so the
-- readers' cma_read.workday_summary and the earlier verifies' column assertions stand
create or replace view cma.workday_summary as
  select a.*,
         (select count(*) from cma.time_event_effective_all e
          where e.tenant_id = a.tenant_id and e.workday_id = a.workday_id and e.kind = 'start')::integer as sessions
  from cma.workday_summary_all a
  where a.tenant_id = cma.current_tenant_id();

-- ---------------------------------------------------------------------------------------------
-- 2. The readers: cma_read.time_interval and cma_read.workday_summary through the owner's rights
-- ---------------------------------------------------------------------------------------------
-- A function inside a view runs with the caller's rights, and a reader of cma_read (bq_reader, the NocoDB user, an
-- IAM login holding cma_readonly) holds none on any table: the two readers' views, which read the core views since
-- 0001 and 0002, would be refused the day functions. They are created again with the same columns, as a scan of the
-- workdays with the same laterals, through two wrappers that carry the owner's rights and what cma_read.reader_sees
-- allows (every tenant without a tenant set, one with it); the wrappers are the readers' alone. The application
-- keeps the faces.
create or replace function cma.workday_stretches_reader_of(p_tenant_id uuid, p_workday_id uuid, p_day_end timestamptz)
returns table (event_id uuid, kind text, status_id uuid, from_at timestamptz, to_at timestamptz, is_open boolean, is_capped boolean, seconds bigint)
language sql stable security definer rows 12
set search_path = pg_catalog, cma
as $$
  select * from cma.workday_stretches_of(p_tenant_id, p_workday_id, p_day_end) where cma_read.reader_sees(p_tenant_id)
$$;
create or replace function cma.workday_summary_reader_of(p_tenant_id uuid, p_workday_id uuid, p_day_end timestamptz)
returns table (working_seconds bigint, productive_seconds bigint, paid_seconds bigint, billable_seconds bigint, is_capped boolean,
               system_end boolean, import_clipped boolean, has_correction boolean, current_status_id uuid, sessions integer)
language sql stable security definer rows 1
set search_path = pg_catalog, cma
as $$
  select * from cma.workday_summary_of(p_tenant_id, p_workday_id, p_day_end) where cma_read.reader_sees(p_tenant_id)
$$;
revoke execute on function cma.workday_stretches_reader_of(uuid, uuid, timestamptz), cma.workday_summary_reader_of(uuid, uuid, timestamptz) from public, cma_app;
grant execute on function cma.workday_stretches_reader_of(uuid, uuid, timestamptz), cma.workday_summary_reader_of(uuid, uuid, timestamptz) to cma_readonly;

create or replace view cma_read.time_interval as
  select w.tenant_id, w.id as workday_id, w.user_id, x.event_id, x.status_id,
         x.from_at, x.to_at, x.is_open, x.is_capped, x.seconds
  from cma.workday w
  cross join lateral (
    select cma.business_day_time(w.business_date, w.timezone,
             (select coalesce(ts.value, st.default_value)::time
              from cma.setting st
              left join cma.tenant_setting ts on ts.tenant_id = w.tenant_id and ts.key = st.key
              where st.key = 'workday.window_end')) as day_end) d
  cross join lateral cma.workday_stretches_reader_of(w.tenant_id, w.id, d.day_end) x
  where cma_read.reader_sees(w.tenant_id);

create or replace view cma_read.workday_summary as
  select w.id as workday_id, w.tenant_id, w.user_id, w.business_date, w.timezone, w.status, w.started_at, w.ended_at,
         x.working_seconds, x.productive_seconds, x.paid_seconds, x.billable_seconds,
         x.is_capped,
         ((w.status = 'open' and now() > d.day_end) or x.system_end or x.import_clipped) as needs_correction,
         x.has_correction, x.current_status_id
  from cma.workday w
  cross join lateral (
    select cma.business_day_time(w.business_date, w.timezone,
             (select coalesce(ts.value, st.default_value)::time
              from cma.setting st
              left join cma.tenant_setting ts on ts.tenant_id = w.tenant_id and ts.key = st.key
              where st.key = 'workday.window_end')) as day_end) d
  cross join lateral cma.workday_summary_reader_of(w.tenant_id, w.id, d.day_end) x
  where x.sessions > 0 and cma_read.reader_sees(w.tenant_id);
grant select on cma_read.time_interval, cma_read.workday_summary to cma_readonly;

-- ---------------------------------------------------------------------------------------------
-- 3. Team hours with the sessions, from the summary
-- ---------------------------------------------------------------------------------------------
drop function if exists cma.team_hours(date, date, uuid);
create function cma.team_hours(p_from date, p_to date, p_user_id uuid default null)
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
  has_correction    boolean,
  sessions          integer
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
           s.is_capped, s.needs_correction, s.has_correction, s.sessions
    from cma.workday_summary s
    join cma.app_user u on u.tenant_id = s.tenant_id and u.id = s.user_id
    left join cma.organisation o on o.tenant_id = u.tenant_id and o.id = u.organisation_id
    where s.business_date between p_from and p_to
      and (p_user_id is null or s.user_id = p_user_id)
    order by s.business_date, u.display_name, s.user_id;
end
$$;
revoke execute on function cma.team_hours(date, date, uuid) from public;
grant execute on function cma.team_hours(date, date, uuid) to cma_app;
alter function cma.team_hours(date, date, uuid) set jit = off;

-- ---------------------------------------------------------------------------------------------
-- 4. The Live board's team read: today's day looked up per person
-- ---------------------------------------------------------------------------------------------
-- cma.team_now as 19 defined it, same columns, same rows and order, with one change: today's summary row per person
-- comes from a lateral with a limit (a person has one day per date, the unique key says so). As a plain join on the
-- person and a computed date, the generic plan a pooled connection reaches after five calls estimated one day for the
-- tenant, read every day of the tenant and filtered after (1.2 s at volume for five people, 6 ms as a lateral). A
-- lateral subquery with a limit is never pulled up, so the day is looked up by workday_user_date_idx on every plan.
create or replace function cma.team_now()
returns table (
  user_id            uuid,
  display_name       text,
  organisation_key   text,
  organisation_name  text,
  timezone           text,
  business_date      date,          -- today in the person's zone
  workday_id         uuid,          -- null when the person has no day today
  day_status         text,          -- 'open', 'ended', or null without a day
  started_at         timestamptz,
  ended_at           timestamptz,
  status_key         text,          -- the day's current (or, once ended, last) status
  status_name        text,
  status_active      boolean,
  is_working         boolean,
  is_productive      boolean,
  is_paid            boolean,
  is_billable        boolean,
  status_since       timestamptz,   -- start of the open stretch; null once the day ended
  closed_seconds     bigint,        -- worked seconds in the closed stretches (is_working)
  running_since      timestamptz    -- start of the open stretch when it is a working one
)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('monitoring.live');
  return query
    select u.id, u.display_name::text, o.key::text, coalesce(o.name, '')::text, tz.zone::text,
           cma.business_date(now(), tz.zone),
           s.workday_id, s.status::text, s.started_at, s.ended_at,
           ws.key::text, ws.name::text, (ws.status = 'active'),
           ws.is_working, ws.is_productive, ws.is_paid, ws.is_billable,
           c.status_since,
           coalesce(c.closed_seconds, 0)::bigint,
           c.running_since
    from cma.app_user u
    left join cma.organisation o on o.tenant_id = u.tenant_id and o.id = u.organisation_id
    cross join lateral (select cma.user_timezone(u.id) as zone) tz
    left join lateral (select x.* from cma.workday_summary x
                       where x.user_id = u.id and x.business_date = cma.business_date(now(), tz.zone)
                       limit 1) s on true
    left join cma.work_status ws
           on ws.tenant_id = u.tenant_id and ws.id = s.current_status_id
    left join lateral (
      select sum(i.seconds) filter (where iws.is_working and (not i.is_open or i.is_capped)) as closed_seconds,
             max(i.from_at) filter (where iws.is_working and i.is_open and not i.is_capped)  as running_since,
             max(i.from_at) filter (where i.is_open and not i.is_capped)                     as status_since
      from cma.time_interval i
      join cma.work_status iws on iws.tenant_id = u.tenant_id and iws.id = i.status_id
      where i.workday_id = s.workday_id
    ) c on s.workday_id is not null
    where u.tenant_id = cma.current_tenant_id()
      and cma.time_is_kept(u.id)
    order by u.display_name, u.id;
end
$$;
revoke execute on function cma.team_now() from public;
grant execute on function cma.team_now() to cma_app;
alter function cma.team_now() set jit = off;

-- ---------------------------------------------------------------------------------------------
-- 5. The addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008zs', 'The hours reads at volume (N06d): a day''s stretches and summary as functions (cma.workday_stretches_of, cma.workday_summary_of), cma.time_interval_all and cma.workday_summary_all a scan of the workdays with a lateral call, the readers'' cma_read.time_interval and cma_read.workday_summary through owner''s-rights wrappers, sessions (the day''s effective clock-ins) on the face cma.workday_summary; cma.team_hours answers sessions as its last column; cma.team_now looks today''s day up per person; same values, 135 proves it row for row')
on conflict (version) do nothing;

commit;
