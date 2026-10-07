-- =============================================================================================
-- 19_team_now.sql: addition 0003e, the team now (the Live board's read)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database.
-- Rerunnable. Run as your own IAM login, dev first, then prod; then 20_verify_team_now.sql.
--
--   cma.team_now()   one row per person whose time is kept (cma.time_is_kept, the same people as
--                    team_people), with employer and zone, and today's day in the person's zone if
--                    there is one: the day's status (open, ended), its start and end, the current
--                    status with its flags, and the clock's inputs exactly as the own-day read
--                    gives them (closed seconds, running since, status since). Needs
--                    monitoring.live, checked in the function; runs with the caller's rights;
--                    the application only.
--
-- Increment (b) of Roadmap step 2: the Live board. Postgres only, today only: a day of an
-- earlier date that is still open belongs to the forgotten-clock-out line on Welcome and to
-- Team hours, not to the board. Today's day is never past its business-day end (the business
-- day ends at the next midnight in the person's zone), so the board carries no stale flag; the
-- open decision on shifts past midnight may change what "today" means, not this function.
-- Stable inputs, no computed figure: the function returns closed seconds and running since,
-- never "worked so far", so two reads of an unchanged team are equal and the screen ticks on
-- its own. Tenant-wide until teams exist (migration 0004); then scoped to the grant, like the
-- team reads. Numbered 0003e so the planned migrations keep 0004 to 0009.
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
-- 1. The team now
-- ---------------------------------------------------------------------------------------------
-- The day part mirrors the application's own-day read (readDay in the data layer): the summary
-- view for the header and the current status, the interval view for the clock. A capped interval
-- (an earlier day that was never ended) cannot occur on today's day, so running_since is the open
-- stretch in a working status, or null while the person pauses or after the day ended. The flags
-- are returned as stored, so the grouping and the colours are derived from them, never from a key
-- or a name; an inactive status that a day still runs in is returned with status_active false.
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
    left join cma.workday_summary s
           on s.user_id = u.id and s.business_date = cma.business_date(now(), tz.zone)
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

-- ---------------------------------------------------------------------------------------------
-- 2. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0003e', 'Team now: today''s day and current status per person whose time is kept, for the Live board, needs monitoring.live')
on conflict (version) do nothing;

reset role;
