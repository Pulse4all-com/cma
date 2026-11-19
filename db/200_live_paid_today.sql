-- =============================================================================================
-- 200_live_paid_today.sql: addition 0009z, Paid today on the Live board's Team panel: cma.team_now() answers each
-- person's paid time today beside the worked time
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after 198_roster_planned.sql
-- (0009y); it refuses to run before 0009y is recorded.
-- Rerunnable, forward-only, in one transaction with a lock timeout. Run as your own IAM login: dev first, then
-- 201_verify_live_paid_today.sql there (normal, then provoked), then 20_verify_team_now.sql (A3 edited by this change),
-- 135_verify_hours_reads.sql (E6 edited by this change) and 199_verify_roster_planned.sql (B6 reads team_now), then
-- 131_time_all.sql part a ('team now'); then prod, the same scripts in the same order. Main's web runs unchanged on it:
-- the board's read takes n.* and maps the columns it knows, so this script runs before the merge of the web that shows
-- the figure.
--
-- Why (Martin, 19 November 2026, brief "Live board, Team panel: Paid today figure"; Decision log, 19 Nov 2026,
-- "Definitions: Paid (nl: Betaald) and Paid today on the Live board"): the Team panel shows the paid time today of the
-- people the table shows, after the group tiles. The figure is the sum over the shown people of each person's Paid today
-- floored to whole minutes (the 7 Oct 2026 rule), so it equals the sum of today's Paid column on Team → Team hours for
-- the same people. The board ticks by itself between two reads (the clock's way since 0003e): the read answers stable
-- inputs, the closed paid seconds and the start of the running paid stretch, as it does for the worked time.
--
-- What it changes
--   cma.team_now()   two new output columns, last:
--                      paid_closed_seconds  seconds of the closed or capped stretches of today's day whose status is_paid
--                                           (closed_seconds' filter with is_paid for is_working)
--                      paid_running_since   start of the open, uncapped stretch while its status is_paid; null otherwise
--                                           (running_since's filter with is_paid for is_working)
--                    both from the lateral that already reads the day's stretches and their statuses (cma.time_interval
--                    joined to cma.work_status), so no new join, no new statement. Every other column, every row and the
--                    order are 134's. The returned columns change, so the function is dropped and created (a returned
--                    column cannot be added in place); its settings are repeated: stable, the caller's rights,
--                    monitoring.live checked first (CMA06), execute for cma_app only, jit = off (0008zs).
-- Paid as Team hours counts it: the stretches of the day's sessions (the time between two sessions is no stretch, so it
-- is not paid), each stopping at the workday window's end; an ended day has nothing running, so paid_closed_seconds is
-- the whole day; a removed day (0009g) has no effective event and is no day on the board, so both columns read 0 and
-- null. At one instant (one transaction's now()), paid_closed_seconds + the running stretch to now equals
-- cma.team_hours' paid_seconds for the person's day (201 proves it).
-- No table, view or column changes; nothing in cma_read; no index (the lateral's reads are 134's).
--
-- Verifies that read cma.team_now, run again after this script:
--   20_verify_team_now.sql          A3 asserts the returned columns: edited by this change to expect the two new ones last
--   135_verify_hours_reads.sql      E6 compares team_now with 19's definition: edited by this change to compare the
--                                   first twenty columns by name
--   199_verify_roster_planned.sql   B6 reads named columns; unchanged
-- 131_time_all.sql's row 'team now' reads n.* and takes the new columns as they are: two more filtered aggregates over
-- the rows the lateral reads already; its budget (verify.max_poll_ms, 20 ms) is to be confirmed by running 131 part a
-- after this script.
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
  if not exists (select 1 from cma.schema_migration where version = '0009y') then
    raise exception 'addition 0009y (198_roster_planned.sql) must run before 0009z';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The Live board's team read with the paid inputs
-- ---------------------------------------------------------------------------------------------
-- cma.team_now as 134 defined it, the same columns, rows and order, with paid_closed_seconds and paid_running_since
-- as its last columns, computed beside closed_seconds and running_since with the same arithmetic
drop function if exists cma.team_now();
-- based on: 134_hours_reads.sql
create function cma.team_now()
returns table (
  user_id             uuid,
  display_name        text,
  organisation_key    text,
  organisation_name   text,
  timezone            text,
  business_date       date,          -- today in the person's zone
  workday_id          uuid,          -- null when the person has no day today
  day_status          text,          -- 'open', 'ended', or null without a day
  started_at          timestamptz,
  ended_at            timestamptz,
  status_key          text,          -- the day's current (or, once ended, last) status
  status_name         text,
  status_active       boolean,
  is_working          boolean,
  is_productive       boolean,
  is_paid             boolean,
  is_billable         boolean,
  status_since        timestamptz,   -- start of the open stretch; null once the day ended
  closed_seconds      bigint,        -- worked seconds in the closed stretches (is_working)
  running_since       timestamptz,   -- start of the open stretch when it is a working one
  paid_closed_seconds bigint,        -- paid seconds in the closed stretches (is_paid)
  paid_running_since  timestamptz    -- start of the open stretch when it is a paid one
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
           c.running_since,
           coalesce(c.paid_closed_seconds, 0)::bigint,
           c.paid_running_since
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
             max(i.from_at) filter (where i.is_open and not i.is_capped)                     as status_since,
             sum(i.seconds) filter (where iws.is_paid and (not i.is_open or i.is_capped))    as paid_closed_seconds,
             max(i.from_at) filter (where iws.is_paid and i.is_open and not i.is_capped)     as paid_running_since
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
-- 2. The addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009z', 'Paid today on the Live board (Martin, 19 Nov 2026): cma.team_now answers paid_closed_seconds (closed or capped stretches of today''s day whose status is_paid) and paid_running_since (start of the open, uncapped stretch while its status is_paid) as its last columns, beside closed_seconds and running_since with the same arithmetic; every other column, row and the order as 0008zs; dropped and created with its grant to cma_app and jit = off')
on conflict (version) do nothing;

commit;
reset role;
