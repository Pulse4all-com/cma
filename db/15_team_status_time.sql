-- =============================================================================================
-- 15_team_status_time.sql: addition 0003c, time per status for the Dashboard
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database.
-- Rerunnable. Run as your own IAM login, dev first, then prod; then 16_verify_team_status_time.sql.
--
--   cma.team_status_time()  seconds per person per business date per status, with the status's
--                           key, name, order and four flags; needs performance.team
--
-- Increment d of Roadmap step 2 (the Dashboard, first page of the Reports group). No new table and
-- no new permission: performance.team is on the default supervisor, manager and analytics roles
-- since 0001. Numbered 0003c so the planned migrations keep 0004 to 0009.
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
-- 1. Time per status, checked in the database
-- ---------------------------------------------------------------------------------------------
-- One row per person per business date per status, summed from cma.time_interval: the same
-- stretches as workday_summary, so the working seconds of a day equal Team hours by construction.
-- An open stretch runs to now, capped at the end of its business day (is_capped). A status that is
-- inactive today still shows in history (status_active false). Flags are returned as stored, so
-- grouping and colours are derived from them, never from a key or a name.
-- performance.team, not workday.team: analytics may read it without correcting anything.
-- Tenant-wide until teams exist (migration 0004); then scoped to the grant, like the team reads.
create or replace function cma.team_status_time(p_from date, p_to date, p_user_id uuid default null)
returns table (
  user_id            uuid,
  display_name       text,
  organisation_key   text,
  organisation_name  text,
  business_date      date,
  timezone           text,
  status_key         text,
  status_name        text,
  sort_order         integer,
  status_active      boolean,
  is_working         boolean,
  is_productive      boolean,
  is_paid            boolean,
  is_billable        boolean,
  seconds            bigint,
  stretches          integer,
  is_capped          boolean
)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('performance.team');
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 91 then
    raise exception 'the range must run forward and cover at most 92 days' using errcode = 'CMA04';
  end if;
  return query
    select i.user_id, u.display_name::text, o.key::text, coalesce(o.name, '')::text,
           w.business_date, w.timezone::text,
           ws.key::text, ws.name::text, ws.sort_order, (ws.status = 'active'),
           ws.is_working, ws.is_productive, ws.is_paid, ws.is_billable,
           sum(i.seconds)::bigint, count(*)::integer, bool_or(i.is_capped)
    from cma.time_interval i
    join cma.workday w      on w.tenant_id = i.tenant_id and w.id = i.workday_id
    join cma.work_status ws on ws.tenant_id = i.tenant_id and ws.id = i.status_id
    join cma.app_user u     on u.tenant_id = i.tenant_id and u.id = i.user_id
    left join cma.organisation o on o.tenant_id = u.tenant_id and o.id = u.organisation_id
    where w.business_date between p_from and p_to
      and (p_user_id is null or i.user_id = p_user_id)
    group by i.user_id, u.display_name, o.key, o.name, w.business_date, w.timezone,
             ws.id, ws.key, ws.name, ws.sort_order, ws.status,
             ws.is_working, ws.is_productive, ws.is_paid, ws.is_billable
    order by w.business_date, u.display_name, i.user_id, ws.sort_order, ws.key;
end
$$;

revoke execute on function cma.team_status_time(date, date, uuid) from public;
grant execute on function cma.team_status_time(date, date, uuid) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 2. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0003c', 'Team status time: seconds per person per day per status for the Dashboard, needs performance.team')
on conflict (version) do nothing;

reset role;
