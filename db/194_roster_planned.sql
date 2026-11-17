-- =============================================================================================
-- 194_roster_planned.sql: addition 0009w, the roster lists only people planned on the roster (brief B39)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after 192_fleet_page.sql
-- (0009v). Rerunnable, forward-only, in one transaction with a lock timeout. Run as your own IAM login: dev first, then
-- 195_verify_roster_planned.sql there (normal, then provoked), then 25_verify_roster.sql and
-- 95_verify_attempts_for_sales.sql again (dev); then prod before the merge of its pull request: this script, 195 (normal,
-- then provoked) and 25 (95 runs in dev only: it refuses any other database).
--
-- Why (Martin, 17 November 2026, brief B39; Decision log, 17 Nov 2026): Team → Roster listed every person whose time is
-- kept (cma.time_is_kept: active and holding workday.own), so the Administrator-only people showed in the planner, since
-- the admin role holds workday.own. Surfaces follow permissions, never a role key (Decision log, 17 Oct 2026): a new
-- permission says who is planned.
--
-- Decisions (verbatim from the brief)
--   D1  New permission roster.planned ("Planned on the roster"). A person is on the roster when cma.time_is_kept(user)
--       and cma.has_permission(user, 'roster.planned'). Roles combine: a person holding admin and agent is on the roster.
--   D2  Default ladder: agent, supervisor and manager get roster.planned; admin and analytics do not. For existing
--       tenants the permission goes on the system roles agent, supervisor and manager only (is_system), as 94 did for
--       messages.withdraw. Other changes a tenant made to its roles stay as they are.
--   D3  cma.roster_in_scope adds the permission check, so roster_people, roster_set_entry (refuses a person not on the
--       roster with the existing scope error, CMA04) and roster_copy_week (skips them) follow. roster_coverage and
--       roster_entries: entries of people not on the roster are not shown and not counted in coverage.
--   D4  Existing entries of people who leave the roster stay as stored, with no deletes (history, publication log).
--   D5  Live board: a person not on the roster who clocks in gets no adherence flag (no "Not planned"):
--       cma.roster_today returns no row for them, and the web derives no flag without a row (lib/live-board shiftLine).
--   D6  The agent's own schedule (cma.my_roster, roster.view) is unchanged.
--
-- What it adds or changes
--   permission         roster.planned in the catalog; on the default ladder's agent, supervisor and manager (new tenants by
--                      cma.seed_default_roles; existing tenants' system roles here). The admin's array is 94's, unchanged
--   cma.on_roster(user)            new: the one definition of "on the roster" (D1), the caller's rights, cma_app only
--   cma.roster_in_scope(...)       on_roster instead of time_is_kept; roster_people, roster_set_entry and
--                                  roster_copy_week call it and are not re-created
--   cma.roster_entries(week, team) leaves out the entries of people not on the roster
--   cma.roster_coverage(week, team) counts and names no shift of a person not on the roster
--   cma.roster_today()             one row per person on the roster (was: whose time is kept)
--   cma.seed_default_roles(tenant) roster.planned on agent, supervisor and manager
-- Unchanged on purpose: cma.time_is_kept (the clock, Team hours, the Live board's people), cma.my_roster (D6), and the
-- stored counts of cma.roster_week (entry_count) and cma.roster_weeks (entry_count, shift_count): they count the week as
-- stored (D4). No table, view or column changes; nothing in cma_read.
--
-- Re-created functions and their bases (the line above each create names it): roster_in_scope, roster_entries,
-- roster_coverage and roster_today from 23_roster.sql; seed_default_roles from 94_attempts_for_sales.sql. None of them
-- carries a setting (no jit, no rows) in its base. Verifies that read them, run again after this script:
--   25_verify_roster.sql            reads every roster function; unchanged (its agents, supervisor and manager hold
--                                   roster.planned through the seeded roles, its analyst does not)
--   95_verify_attempts_for_sales.sql reads seed_default_roles' source (the admin array ends 'tenant.configure',
--                                   'messages.withdraw']); unchanged
-- cma.seed_default_roles also reaches the verifies that create a tenant through cma.create_tenant; none of them asserts
-- the permission arrays or counts of the agent, supervisor or manager role, so none is run again for it.
-- 131_time_all.sql's rows 'shifts today', 'roster people', 'roster entries' and 'roster coverage' read the new
-- definitions, at most one more indexed permission lookup per person or entry; their budgets are to be confirmed by
-- running 131 part a after this script (dev, then prod), against prod's 0009u evening run (shifts today 8.0 ms, roster
-- people 8.9, roster entries 2.4, roster coverage 4.1, the roster week's set 20.8).
--
-- SQLSTATEs as 0005's: CMA04 invalid (a person not on this roster), CMA06 not permitted.
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
  if not exists (select 1 from cma.schema_migration where version = '0009v') then
    raise exception 'addition 0009v (192_fleet_page.sql) has not run in this database';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The permission and the default ladder
-- ---------------------------------------------------------------------------------------------
insert into cma.permission (key, description) values
  ('roster.planned', 'Planned on the roster: listed in the roster planner and given adherence flags on the Live board, with workday.own')
on conflict (key) do update set description = excluded.description;

-- The default role ladder, as 0008z left it, plus roster.planned for the agent, the supervisor and the manager
-- based on: 94_attempts_for_sales.sql
create or replace function cma.seed_default_roles(p_tenant_id uuid)
returns void
language plpgsql
as $$
declare
  r record;
begin
  for r in
    select *
    from (values
      ('agent', 'Agent', array[
         'workday.own', 'roster.view', 'leads.accept', 'performance.own', 'roster.planned']),
      ('supervisor', 'Supervisor', array[
         'workday.own', 'roster.view', 'leads.accept', 'performance.own',
         'workday.team', 'performance.team', 'monitoring.live', 'messages.send', 'roster.planned']),
      ('manager', 'Call center manager', array[
         'workday.own', 'roster.view', 'leads.accept', 'performance.own',
         'workday.team', 'performance.team', 'monitoring.live', 'messages.send',
         'roster.manage', 'skills.manage', 'leads.manage', 'quality.manage',
         'reports.view', 'users.manage_agents', 'workday.export', 'roster.planned']),
      ('admin', 'Administrator', array[
         'workday.own', 'roster.view', 'leads.accept', 'performance.own',
         'workday.team', 'performance.team', 'monitoring.live', 'messages.send',
         'roster.manage', 'skills.manage', 'leads.manage', 'quality.manage',
         'reports.view', 'users.manage_agents', 'workday.export',
         'users.manage_all', 'tenant.configure', 'messages.withdraw']),
      ('analytics', 'Analytics', array[
         'reports.view', 'performance.team', 'monitoring.live', 'quality.manage'])
    ) as v(key, name, perms)
  loop
    insert into cma.app_role (tenant_id, key, name, is_system)
    values (p_tenant_id, r.key, r.name, true)
    on conflict (tenant_id, key) do nothing;

    insert into cma.role_permission (tenant_id, role_id, permission_key)
    select p_tenant_id, ar.id, p
    from cma.app_role ar
    cross join unnest(r.perms) as p
    where ar.tenant_id = p_tenant_id and ar.key = r.key
    on conflict do nothing;
  end loop;
end
$$;
revoke execute on function cma.seed_default_roles(uuid) from public;

-- Existing tenants: only the new permission, only on the default ladder's agent, supervisor and manager (D2, as 0008z did
-- for the admin's messages.withdraw). Other changes a tenant made to its own roles stay as they are
insert into cma.role_permission (tenant_id, role_id, permission_key)
select ar.tenant_id, ar.id, 'roster.planned'
from cma.app_role ar
where ar.key in ('agent', 'supervisor', 'manager') and ar.is_system
on conflict do nothing;

-- ---------------------------------------------------------------------------------------------
-- 2. On the roster (D1)
-- ---------------------------------------------------------------------------------------------
-- One definition of "on the roster": the person's time is kept (active, workday.own) and the person holds
-- roster.planned. Permissions are catalog keys, never role names, so roles combine (admin and agent is on the roster)
-- and a tenant's own role is on the roster when it holds both.
create or replace function cma.on_roster(p_user_id uuid)
returns boolean
language sql stable
as $$
  select cma.time_is_kept(p_user_id) and cma.has_permission(p_user_id, 'roster.planned')
$$;

-- Whether a person belongs on a roster: on the roster (0009w; was: time is kept), and for a team roster the person is a
-- member at some point during the week (so a person who joins on Wednesday appears)
-- based on: 23_roster.sql
create or replace function cma.roster_in_scope(p_user_id uuid, p_team_id uuid, p_week_start date)
returns boolean
language sql stable
as $$
  select cma.on_roster(p_user_id)
     and (p_team_id is null
          or exists (select 1 from cma.team_member m
                     where m.tenant_id = cma.current_tenant_id() and m.user_id = p_user_id and m.team_id = p_team_id
                       and m.valid_from < (p_week_start + 7)::timestamp at time zone 'UTC' + interval '1 day'
                       and (m.valid_to is null or m.valid_to > p_week_start::timestamp at time zone 'UTC' - interval '1 day')))
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. The planner's reads (D3)
-- ---------------------------------------------------------------------------------------------

-- The current entries of the week (what the planner edits), one per person per date; since 0009w only of people on the
-- roster (D3). The entries of people who left the roster stay stored (D4)
-- based on: 23_roster.sql
create or replace function cma.roster_entries(p_week_start date, p_team_key text default null)
returns table (
  entry_id        uuid,
  user_id         uuid,
  business_date   date,
  kind            text,
  start_time      time,
  end_time        time,
  absence_key     text,
  absence_name    text,
  note            text,
  recorded_at     timestamptz,
  recorded_by_name text
)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_team uuid;
begin
  perform cma.assert_permission('roster.manage');
  perform cma.assert_week_start(p_week_start);
  v_team := cma.roster_team_id(p_team_key);
  return query
    select e.id, e.user_id, e.business_date, e.kind::text, e.start_time, e.end_time,
           a.key::text, a.name::text, e.note::text, e.recorded_at, rb.display_name::text
    from cma.roster_entry e
    join cma.roster_week w on w.tenant_id = e.tenant_id and w.id = e.roster_week_id
    left join cma.absence_type a on a.tenant_id = e.tenant_id and a.id = e.absence_type_id
    left join cma.app_user rb on rb.tenant_id = e.tenant_id and rb.id = e.recorded_by
    where e.tenant_id = cma.current_tenant_id()
      and w.week_start = p_week_start and w.team_id is not distinct from v_team
      and e.valid_to is null
      and cma.on_roster(e.user_id)
    order by e.business_date, e.user_id;
end
$$;

-- Coverage per date and work type: how many planned people hold the work type that day, who they
-- are, and the team's target for that weekday when one is set. Skills as held now. Since 0009w a shift of a person not
-- on the roster is neither counted nor named (D3)
-- based on: 23_roster.sql
create or replace function cma.roster_coverage(p_week_start date, p_team_key text default null)
returns table (
  business_date  date,
  skill_key      text,
  skill_name     text,
  planned_people integer,
  people_names   text[],
  target         integer
)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_team uuid;
begin
  perform cma.assert_permission('roster.manage');
  perform cma.assert_week_start(p_week_start);
  v_team := cma.roster_team_id(p_team_key);
  return query
    select d::date, s.key::text, s.name::text,
           count(e.user_id)::integer,
           coalesce(array_agg(u.display_name order by u.display_name) filter (where e.user_id is not null), '{}'::text[]),
           ct.min_count
    from generate_series(p_week_start, p_week_start + 6, interval '1 day') d
    cross join cma.skill s
    left join cma.roster_week w on w.tenant_id = s.tenant_id and w.week_start = p_week_start and w.team_id is not distinct from v_team
    left join cma.roster_entry e on e.tenant_id = s.tenant_id and e.roster_week_id = w.id and e.business_date = d::date
                                and e.kind = 'shift' and e.valid_to is null
                                and exists (select 1 from cma.user_skill us
                                            where us.tenant_id = e.tenant_id and us.user_id = e.user_id and us.skill_id = s.id and us.valid_to is null)
                                and cma.on_roster(e.user_id)
    left join cma.app_user u on u.tenant_id = e.tenant_id and u.id = e.user_id
    left join cma.coverage_target ct on ct.tenant_id = s.tenant_id and ct.team_id = v_team and ct.skill_id = s.id
                                    and ct.weekday = extract(isodow from d)::smallint
    where s.tenant_id = cma.current_tenant_id() and s.dimension = 'work_type' and s.status = 'active'
    group by d, s.id, s.key, s.name, s.sort_order, ct.min_count
    order by d, s.sort_order, s.key;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. The Live board's shift line (D5)
-- ---------------------------------------------------------------------------------------------

-- Today's published entry per person on the roster (0009w; was: whose time is kept), in the person's zone, for the Live
-- board's shift line; monitoring.live. A person not on the roster has no row, so the board derives no adherence flag
-- (no "Not planned") when that person clocks in
-- based on: 23_roster.sql
create or replace function cma.roster_today()
returns table (
  user_id        uuid,
  business_date  date,
  is_published   boolean,
  kind           text,
  start_time     time,
  end_time       time,
  absence_name   text
)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('monitoring.live');
  return query
    select u.id, tz.today,
           exists (select 1 from cma.roster_week w
                   where w.tenant_id = u.tenant_id and w.status = 'published'
                     and w.week_start <= tz.today and tz.today < w.week_start + 7
                     and (w.team_id is null
                          or exists (select 1 from cma.team_member m
                                     where m.tenant_id = w.tenant_id and m.user_id = u.id and m.team_id = w.team_id
                                       and m.valid_from <= w.published_at and (m.valid_to is null or m.valid_to > w.published_at)))),
           x.kind::text, x.start_time, x.end_time, x.absence_name
    from cma.app_user u
    cross join lateral (select cma.business_date(now(), cma.user_timezone(u.id)) as today) tz
    left join lateral (
      select e.kind, e.start_time, e.end_time, a.name::text as absence_name
      from cma.roster_published_entry e
      left join cma.absence_type a on a.tenant_id = e.tenant_id and a.id = e.absence_type_id
      where e.user_id = u.id and e.business_date = tz.today
      order by e.published_at desc
      limit 1
    ) x on true
    where u.tenant_id = cma.current_tenant_id()
      and cma.on_roster(u.id)
    order by u.display_name, u.id;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. Privileges on the functions: the application only (as 0005's section 8)
-- ---------------------------------------------------------------------------------------------
revoke execute on function
  cma.on_roster(uuid), cma.roster_in_scope(uuid, uuid, date), cma.roster_entries(date, text),
  cma.roster_coverage(date, text), cma.roster_today()
from public;
grant execute on function
  cma.on_roster(uuid), cma.roster_in_scope(uuid, uuid, date), cma.roster_entries(date, text),
  cma.roster_coverage(date, text), cma.roster_today()
to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 6. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009w', 'Roster: only people planned on the roster (brief B39): the permission roster.planned on the default ladder''s agent, supervisor and manager (cma.seed_default_roles; existing tenants'' system roles), cma.on_roster (time kept and roster.planned), cma.roster_in_scope on it (roster_people, roster_set_entry and roster_copy_week follow), cma.roster_entries and cma.roster_coverage leaving out people not on the roster, cma.roster_today one row per person on the roster. Stored entries unchanged; no table, view or column changed; nothing in cma_read')
on conflict (version) do nothing;

commit;
reset role;
