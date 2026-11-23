-- =============================================================================================
-- 231_verify_hours_market.sql: verifies addition 0009zo, the Hours market on every start and status event (the columns,
-- their rules in the tables, the write path and the reads that answer it)
-- =============================================================================================
-- Universal: no seed is assumed, so it runs in dev and in prod. Two kinds of checks:
--   on two throwaway tenants (B): invented people (example.invalid) whose days are written through the clock's own
--     functions at fixed local times, markets configured through cma.upsert_market as the tenant's admin with invented
--     codes of the ISO form, the whole step rolled back; the second tenant holds one market the first does not have;
--   on every active tenant (R): the rebuilt reads against the previous definitions (kept below: 228, 13, 52 and 26), every
--     earlier column row for row and in order, as the application (cma_app, row-level security on), in a step that is
--     always rolled back.
-- Run as your own IAM login, after 230. Output: tenant slugs, counts, check names, the throwaway people's invented short
-- names, the throwaway tenants' market codes and labels for their statuses; no real person's name, no status key and no
-- market of a real tenant.
--
-- The throwaway tenant's clock: its people live in the zone where it is between 09:00 and 12:00 now (Etc/GMT zones, whole
-- hours, 201's way), so every event below lies in the past of today's business date whatever the hour. Statuses are
-- picked by flag from the tenant's own seeded list: the default ("default"), a working status that is not productive
-- ("other") and a pause ("pause"). Markets (codes of the ISO form, invented for the run): NL, DE, BE, AT and FR in the
-- first tenant, SE in the second. People: a1 to a4 agents, mgr, sup and admin as the default ladder gives them.
--   a1   Default market NL; clock in 05:00, other from 06:00, market DE alone at 06:30 (and again at 06:31: nothing),
--        a pause from 07:00, market NL alone at 06:45 (B6), still in the pause
--   a2   yesterday: clock in 05:00 (no default, no history: none), default status under DE from 06:00, log out 07:00;
--        today: clock in 05:00 (its last day's market: DE)
--   a3   no Default market, no history: clock in 05:00 under none; the manager corrects the start to DE (B5)
--   a4   Default market FR, then FR goes inactive: clock in 05:00 under none (an inactive default is not used, and a4 has
--        no earlier day)
--
-- Checks
--   S1  the addition 0009zo is recorded once, after 0009zn
--   S2  the three columns: market's text not null with its foreign key and trigger, app_user's and time_event's text and
--       nullable with theirs (time_event's foreign key and kind check present; not valid allowed), the readers' four views
--       end with them and the readers may read them
--   S3  the functions: the reads end with the market after their previous columns; set_status has four arguments with
--       p_hours_market_code last and two defaults, the 3-argument one gone, open_workday and correct_workday keep their
--       signatures; cma_owner's, the application's to execute (not public's, not the readers'), the caller's rights;
--       team_now jit = off; the trigger functions nobody's to call
--   B1  the mapping: a market maps to an hours market; one that others map to, or that is a person's Default market,
--       keeps mapping to itself (CMA03); a market that is no hours market or of another tenant is no target (CMA04,
--       CMA02); the table refuses a direct write (CMA04); an hours market that an active market maps to stays active
--       (CMA03); without tenant.configure refused (CMA06); markets_all and hours_markets answer it
--   B2  a status change is refused for a market of another tenant (CMA02), a market that is no hours market (CMA04), an
--       inactive hours market (CMA04) and a code that is no code (CMA04); the table refuses a direct write of a market
--       that is no hours market and of a market on an end event (CMA04)
--   B3  a status change without a market keeps the day's market; a market change alone books a status event with the
--       same status and the new market; asking again for the market in force books nothing
--   B4  the Default market: set by a manager of the person, refused for a market that is no hours market (CMA04), of
--       another tenant (CMA02), by an agent (CMA06) and by a direct write (CMA04); clock-in takes the default, else the
--       last day's market, else none, and an inactive default is not used
--   B5  a correction changes the market with the reason and the manager as approver; without hoursMarket it keeps the
--       superseded event's market, as cma.correct_time_event does; refused for a market that is no hours market (CMA04),
--       of another tenant (CMA02) and on an end (CMA04); the four-eyes rule unchanged (CMA06)
--   B6  worked, productive, paid and billable seconds for the fixture day equal before and after the markets change
--       (export_hours' sixteen earlier columns and team_hours' every column but has_correction, which the correction of a3's
--       start sets as any correction does; team_status_time's seconds per person and status)
--   B7  the reads answer the market: team_day, team_status_time (split per market), team_now, export_status_changes,
--       export_hours (a null element for time without one), directory, cma_read.time_event and cma_read.time_interval
--   B8  a market remapped while a day is booked under it never blocks that day: a status change without a market, a
--       correction without hoursMarket and one sending the event's own market again book under the market it maps to now
--       (cma.resolve_hours_market); that market on another event is refused (CMA04)
--   R1  per active tenant: team_status_time's eighteen earlier columns, summed over its markets, equal 228's definition
--       over the last 31 days
--   R2  per active tenant: team_now's twenty-three earlier columns equal 228's definition
--   R3  per active tenant: export_status_changes' nineteen earlier columns equal 228's definition over the last 31 days
--   R4  per active tenant: export_hours' sixteen earlier columns equal 13's definition over the last 31 days
--   R5  per active tenant: markets_all's ten earlier columns equal 52's definition
--   R6  per active tenant: directory's fifteen earlier columns equal 26's definition
--   R7  per active tenant: team_day's twelve earlier columns equal 50's definition for one day of the last 31 days (one
--       with a correction when there is one)
-- Each R check acts as the tenant's first active person holding the read's permission (131's choice) and reads skip
-- without one.
-- Provoke: verify.provoke below. 'true': every check reads FAIL and the verdict says PROVOKED, NOT A PASS. A check's id:
-- that check alone fails. The R checks drop the old side's first row, so the comparison itself must find the difference
-- (a compare of no rows reads FAIL under the switch).
-- Collation: every ordering that feeds a compared text says collate "C", but R1's: its new side sorts in the previous
-- definition's own order (the database's collation, as the old side's function does), so both sides sort alike.
-- Expected verdict: "PASS | 231_verify_hours_market: <n> PASS, 0 FAIL, <k> skip".
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);                 -- 'true' for every check, or one check's id such as 'B2'

drop table if exists pg_temp.verify_0009zo;
create temporary table verify_0009zo (ord integer, check_name text, result text, detail text);
grant select, insert on pg_temp.verify_0009zo to cma_app;

create or replace function pg_temp.v0009zo_p(p_id text)
returns boolean
language sql stable
as $$
  select current_setting('verify.provoke') in ('true', p_id)
$$;

-- One check's row: PASS when what was found equals what is expected; provoked, the expectation carries a deliberate difference
create or replace function pg_temp.v0009zo_row(p_ord integer, p_id text, p_name text, p_found text, p_expected text)
returns void
language plpgsql
as $$
declare
  v_exp text := case when pg_temp.v0009zo_p(p_id) then coalesce(p_expected, '') || ' [provoked: a deliberate difference]' else p_expected end;
begin
  insert into pg_temp.verify_0009zo values (p_ord, p_id || ' ' || p_name,
    case when p_found is not distinct from v_exp then 'PASS' else 'FAIL' end,
    case when p_found is not distinct from v_exp then left(coalesce(p_found, 'null'), 600)
         else left('found ' || coalesce(p_found, 'null') || ' | expected ' || coalesce(v_exp, 'null'), 2400) end);
end
$$;

-- Two reads compared row for row and in order (229's comparison); provoked for the check, the old side loses its first
-- row. Null when equal, otherwise what differs
create or replace function pg_temp.v0009zo_diff(p_id text, p_new text, p_old text)
returns text
language plpgsql
as $$
declare
  v_old text := p_old;
  v_n_new bigint; v_n_old bigint; v_only_new bigint; v_only_old bigint; v_same boolean;
begin
  if pg_temp.v0009zo_p(p_id) then
    v_old := format('select * from (%s) z offset 1', p_old);
  end if;
  execute format('select count(*) from (%s) a', p_new) into v_n_new;
  execute format('select count(*) from (%s) a', v_old) into v_n_old;
  if pg_temp.v0009zo_p(p_id) and v_n_new = 0 then
    return 'provoked, but the set is empty: nothing to differ (FAIL by the switch)';
  end if;
  execute format('select (select string_agg(a::text, ''|'' order by a.o) from (select row_number() over () as o, t from (%s) t) a) is not distinct from
                         (select string_agg(b::text, ''|'' order by b.o) from (select row_number() over () as o, t from (%s) t) b)', p_new, v_old) into v_same;
  execute format('select count(*) from ((%s) except all (%s)) a', p_new, v_old) into v_only_new;
  execute format('select count(*) from ((%s) except all (%s)) a', v_old, p_new) into v_only_old;
  if v_only_new = 0 and v_only_old = 0 and v_same then
    return null;
  end if;
  return format('new %s rows, previous %s; only in new %s, only in previous %s; same order %s', v_n_new, v_n_old, v_only_new, v_only_old, v_same);
end
$$;
grant execute on function pg_temp.v0009zo_diff(text, text, text) to cma_app;

-- The earlier columns of each read, as the previous definitions return them
create or replace function pg_temp.v0009zo_cols(p_read text)
returns text
language sql immutable
as $$
  select case p_read
    when 'team_status_time' then 'user_id, display_name, organisation_key, organisation_name, business_date, timezone, status_key, '
      || 'status_name, sort_order, status_active, is_working, is_productive, is_paid, is_billable, seconds, stretches, is_capped, work_area'
    when 'team_now' then 'user_id, display_name, organisation_key, organisation_name, timezone, business_date, workday_id, day_status, '
      || 'started_at, ended_at, status_key, status_name, status_active, is_working, is_productive, is_paid, is_billable, '
      || 'status_since, closed_seconds, running_since, paid_closed_seconds, paid_running_since, work_area'
    when 'export_status_changes' then 'user_id, display_name, organisation_key, organisation_name, business_date, timezone, status_key, '
      || 'status_name, is_working, is_productive, is_paid, is_billable, from_at, to_at, is_open, is_capped, seconds, source, work_area'
    when 'export_hours' then 'user_id, display_name, organisation_key, organisation_name, business_date, timezone, status, started_at, '
      || 'ended_at, working_seconds, productive_seconds, paid_seconds, billable_seconds, is_capped, needs_correction, has_correction'
    when 'team_day' then 'event_id, kind, status_key, status_name, occurred_at, recorded_at, source, supersedes_event_id, reason, '
      || 'approved_by_name, is_effective, import_batch_key'
    when 'markets_all' then 'code, name, time_zone, language_code, language_skill_key, min_language_level, currency, status, sort_order, aliases'
    when 'directory' then 'user_id, email, display_name, status, organisation_key, organisation_name, timezone, role_key, role_name, '
      || 'role_granted_at, is_managing, time_kept, teams, skills, may_edit'
  end
$$;

-- team_status_time summed over its earlier columns (0009zo splits a status's row per hours market), in the previous order
create or replace function pg_temp.v0009zo_tst_sum(p_from date, p_to date)
returns text
language sql immutable
as $$
  select format('select user_id, display_name, organisation_key, organisation_name, business_date, timezone, status_key, status_name, '
             || 'sort_order, status_active, is_working, is_productive, is_paid, is_billable, sum(seconds)::bigint as seconds, '
             || 'sum(stretches)::integer as stretches, bool_or(is_capped) as is_capped, work_area '
             || 'from cma.team_status_time(%L::date, %L::date) '
             || 'group by user_id, display_name, organisation_key, organisation_name, business_date, timezone, status_key, status_name, '
             || 'sort_order, status_active, is_working, is_productive, is_paid, is_billable, work_area '
             || 'order by business_date, display_name, user_id, sort_order, status_key', p_from, p_to)
$$;

-- ---------------------------------------------------------------------------------------------
-- The previous definitions, kept to compare with (R)
-- ---------------------------------------------------------------------------------------------
-- 228_work_area.sql
create or replace function pg_temp.old_team_status_time(p_from date, p_to date, p_user_id uuid default null)
returns table (
  user_id uuid, display_name text, organisation_key text, organisation_name text, business_date date, timezone text,
  status_key text, status_name text, sort_order integer, status_active boolean, is_working boolean, is_productive boolean,
  is_paid boolean, is_billable boolean, seconds bigint, stretches integer, is_capped boolean, work_area text
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
           sum(i.seconds)::bigint, count(*)::integer, bool_or(i.is_capped),
           ws.work_area
    from cma.time_interval i
    join cma.workday w      on w.tenant_id = i.tenant_id and w.id = i.workday_id
    join cma.work_status ws on ws.tenant_id = i.tenant_id and ws.id = i.status_id
    join cma.app_user u     on u.tenant_id = i.tenant_id and u.id = i.user_id
    left join cma.organisation o on o.tenant_id = u.tenant_id and o.id = u.organisation_id
    where w.business_date between p_from and p_to
      and (p_user_id is null or i.user_id = p_user_id)
    group by i.user_id, u.display_name, o.key, o.name, w.business_date, w.timezone,
             ws.id, ws.key, ws.name, ws.sort_order, ws.status,
             ws.is_working, ws.is_productive, ws.is_paid, ws.is_billable, ws.work_area
    order by w.business_date, u.display_name, i.user_id, ws.sort_order, ws.key;
end
$$;
grant execute on function pg_temp.old_team_status_time(date, date, uuid) to cma_app;

-- 228_work_area.sql
create or replace function pg_temp.old_team_now()
returns table (
  user_id uuid, display_name text, organisation_key text, organisation_name text, timezone text, business_date date,
  workday_id uuid, day_status text, started_at timestamptz, ended_at timestamptz, status_key text, status_name text,
  status_active boolean, is_working boolean, is_productive boolean, is_paid boolean, is_billable boolean,
  status_since timestamptz, closed_seconds bigint, running_since timestamptz, paid_closed_seconds bigint, paid_running_since timestamptz,
  work_area text
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
           c.paid_running_since,
           ws.work_area
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
grant execute on function pg_temp.old_team_now() to cma_app;

-- 228_work_area.sql
create or replace function pg_temp.old_export_status_changes(p_from date, p_to date, p_user_id uuid default null)
returns table (
  user_id uuid, display_name text, organisation_key text, organisation_name text, business_date date, timezone text,
  status_key text, status_name text, is_working boolean, is_productive boolean, is_paid boolean, is_billable boolean,
  from_at timestamptz, to_at timestamptz, is_open boolean, is_capped boolean, seconds bigint, source text, work_area text
)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('workday.export');
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 91 then
    raise exception 'the range must run forward and cover at most 92 days' using errcode = 'CMA04';
  end if;
  return query
    select i.user_id, u.display_name::text, o.key::text, coalesce(o.name, '')::text, w.business_date,
           w.timezone::text, ws.key::text, ws.name::text,
           ws.is_working, ws.is_productive, ws.is_paid, ws.is_billable,
           i.from_at, i.to_at, i.is_open, i.is_capped, i.seconds, e.source::text,
           ws.work_area
    from cma.time_interval i
    join cma.workday w      on w.tenant_id = i.tenant_id and w.id = i.workday_id
    join cma.work_status ws on ws.tenant_id = i.tenant_id and ws.id = i.status_id
    join cma.time_event e   on e.tenant_id = i.tenant_id and e.id = i.event_id
    join cma.app_user u     on u.tenant_id = i.tenant_id and u.id = i.user_id
    left join cma.organisation o on o.tenant_id = u.tenant_id and o.id = u.organisation_id
    where w.business_date between p_from and p_to
      and (p_user_id is null or i.user_id = p_user_id)
    order by w.business_date, u.display_name, i.user_id, i.from_at;
end
$$;
grant execute on function pg_temp.old_export_status_changes(date, date, uuid) to cma_app;

-- 13_tenant_settings.sql
create or replace function pg_temp.old_export_hours(p_from date, p_to date, p_user_id uuid default null)
returns table (
  user_id uuid, display_name text, organisation_key text, organisation_name text, business_date date, timezone text,
  status text, started_at timestamptz, ended_at timestamptz, working_seconds bigint, productive_seconds bigint,
  paid_seconds bigint, billable_seconds bigint, is_capped boolean, needs_correction boolean, has_correction boolean
)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('workday.export');
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 91 then
    raise exception 'the range must run forward and cover at most 92 days' using errcode = 'CMA04';
  end if;
  return query
    select s.user_id, u.display_name::text, o.key::text, coalesce(o.name, '')::text, s.business_date,
           s.timezone::text, s.status::text, s.started_at, s.ended_at,
           s.working_seconds, s.productive_seconds, s.paid_seconds, s.billable_seconds,
           s.is_capped, s.needs_correction, s.has_correction
    from cma.workday_summary s
    join cma.app_user u on u.tenant_id = s.tenant_id and u.id = s.user_id
    left join cma.organisation o on o.tenant_id = u.tenant_id and o.id = u.organisation_id
    where s.business_date between p_from and p_to
      and (p_user_id is null or s.user_id = p_user_id)
    order by s.business_date, u.display_name, s.user_id;
end
$$;
grant execute on function pg_temp.old_export_hours(date, date, uuid) to cma_app;

-- 50_legacy_time_import.sql
create or replace function pg_temp.old_team_day(p_user_id uuid, p_business_date date)
returns table (event_id uuid, kind text, status_key text, status_name text, occurred_at timestamptz, recorded_at timestamptz, source text,
               supersedes_event_id uuid, reason text, approved_by_name text, is_effective boolean, import_batch_key text)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('workday.team');
  return query
    select e.id, e.kind::text, ws.key::text, ws.name::text, e.occurred_at, e.recorded_at, e.source::text,
           e.supersedes_event_id, e.reason, a.display_name::text,
           exists (select 1 from cma.time_event_effective f where f.tenant_id = e.tenant_id and f.id = e.id),
           ib.key::text
    from cma.time_event e
    join cma.workday w on w.tenant_id = e.tenant_id and w.id = e.workday_id
    left join cma.work_status ws on ws.tenant_id = e.tenant_id and ws.id = e.status_id
    left join cma.app_user a on a.tenant_id = e.tenant_id and a.id = e.approved_by
    left join cma.import_batch ib on ib.tenant_id = e.tenant_id and ib.id = e.import_batch_id
    where w.tenant_id = cma.current_tenant_id()
      and w.user_id = p_user_id and w.business_date = p_business_date
    order by e.occurred_at, e.recorded_at, e.id;
end
$$;
grant execute on function pg_temp.old_team_day(uuid, date) to cma_app;

-- 52_sources_configuration.sql
create or replace function pg_temp.old_markets_all()
returns table (code text, name text, time_zone text, language_code text, language_skill_key text, min_language_level smallint,
               currency text, status text, sort_order integer, aliases text[])
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('tenant.configure');
  return query
    select m.code::text, m.name::text, m.time_zone::text, m.language_code::text, m.language_skill_key::text,
           m.min_language_level, m.currency::text, m.status::text, m.sort_order,
           coalesce((select array_agg(a.alias::text order by a.alias) from cma.market_alias a
                     where a.tenant_id = m.tenant_id and a.code = m.code), '{}'::text[])
    from cma.market m
    where m.tenant_id = cma.current_tenant_id()
    order by (m.status <> 'active'), m.sort_order, m.code;
end
$$;
grant execute on function pg_temp.old_markets_all() to cma_app;

-- 26_configuration.sql
create or replace function pg_temp.old_directory()
returns table (user_id uuid, email text, display_name text, status text, organisation_key text, organisation_name text,
               timezone text, role_key text, role_name text, role_granted_at timestamptz, is_managing boolean, time_kept boolean,
               teams jsonb, skills jsonb, may_edit boolean)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_user uuid := cma.assert_any_permission(array['users.manage_agents', 'users.manage_all']);
  v_all  boolean := cma.has_permission(cma.current_user_id(), 'users.manage_all');
begin
  return query
    select u.id, u.email::text, u.display_name::text, u.status::text,
           o.key::text, coalesce(o.name, '')::text, cma.user_timezone(u.id)::text,
           r.key::text, r.name::text, r.granted_at,
           coalesce(r.is_managing, false),
           cma.time_is_kept(u.id),
           coalesce((select jsonb_agg(jsonb_build_object('key', t.key, 'name', t.name) order by t.sort_order, t.key)
                     from cma.team_member m
                     join cma.team t on t.tenant_id = m.tenant_id and t.id = m.team_id
                     where m.tenant_id = u.tenant_id and m.user_id = u.id and m.valid_to is null and t.valid_to is null), '[]'::jsonb),
           coalesce((select jsonb_agg(jsonb_build_object('dimension', s.dimension, 'key', s.key, 'name', s.name,
                                                         'level', us.level, 'levelName', l.name)
                                      order by case s.dimension when 'language' then 1 when 'work_type' then 2 else 3 end, s.sort_order, s.key)
                     from cma.user_skill us
                     join cma.skill s on s.tenant_id = us.tenant_id and s.id = us.skill_id
                     left join cma.skill_level l on l.tenant_id = s.tenant_id and l.dimension = s.dimension and l.level = us.level
                     where us.tenant_id = u.tenant_id and us.user_id = u.id and us.valid_to is null), '[]'::jsonb),
           (u.id <> v_user and (v_all or not coalesce(r.is_managing, false)))
    from cma.app_user u
    left join cma.organisation o on o.tenant_id = u.tenant_id and o.id = u.organisation_id
    left join lateral (
      select ar.key, ar.name, ur.granted_at,
             exists (select 1 from cma.user_role ur2 where ur2.tenant_id = u.tenant_id and ur2.user_id = u.id
                     and cma.role_is_managing(ur2.role_id)) as is_managing
      from cma.user_role ur
      join cma.app_role ar on ar.tenant_id = ur.tenant_id and ar.id = ur.role_id
      where ur.tenant_id = u.tenant_id and ur.user_id = u.id
      order by ur.granted_at, ar.key
      limit 1
    ) r on true
    where u.tenant_id = cma.current_tenant_id()
      and u.kind = 'person'
      and (v_all or u.id = v_user or not coalesce(r.is_managing, false))
    order by (u.status <> 'active'), u.display_name, u.id;
end
$$;
grant execute on function pg_temp.old_directory() to cma_app;


-- One attempt: the label and ok, or the label and the error's SQLSTATE (the attempt alone is rolled back on an error)
create or replace function pg_temp.v0009zo_try(p_label text, p_sql text)
returns text
language plpgsql
as $$
begin
  execute p_sql;
  return p_label || ' ok';
exception when others then
  return p_label || ' ' || sqlstate;
end
$$;
grant execute on function pg_temp.v0009zo_try(text, text) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- S. The addition, the columns and the functions
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_bad  text := '';
  v_fn   text;
  v_read text;
  v_cols text;
  f      regprocedure;
  c      record;
begin
  -- S1
  perform pg_temp.v0009zo_row(1, 'S1', 'the addition 0009zo recorded once, after 0009zn',
    format('0009zn %s; 0009zo %s, after 0009zn %s, hours market %s',
           (select count(*) from cma.schema_migration where version = '0009zn'),
           (select count(*) from cma.schema_migration where version = '0009zo'),
           coalesce((select o.applied_at > n.applied_at from cma.schema_migration o, cma.schema_migration n
                     where o.version = '0009zo' and n.version = '0009zn'), false),
           coalesce((select m.description like 'Hours market on every status change%' from cma.schema_migration m where m.version = '0009zo'), false)),
    '0009zn 1; 0009zo 1, after 0009zn t, hours market t');

  -- S2
  perform pg_temp.v0009zo_row(2, 'S2', 'the three columns with their keys, checks and triggers; the readers'' four views end with them',
    format('market %s, key %s, rule %s; app_user %s, key %s, rule %s; time_event %s, key %s, kind %s, rule %s; views %s; readers %s',
      coalesce((select ic.data_type || ' ' || ic.is_nullable from information_schema.columns ic
                where ic.table_schema = 'cma' and ic.table_name = 'market' and ic.column_name = 'hours_market_code'), 'missing'),
      exists (select 1 from pg_constraint k where k.conrelid = 'cma.market'::regclass and k.conname = 'market_hours_market_fk' and k.contype = 'f'
              and k.confrelid = 'cma.market'::regclass),
      exists (select 1 from pg_trigger g where g.tgrelid = 'cma.market'::regclass and g.tgname = 'market_hours_market_rules' and g.tgenabled = 'O'),
      coalesce((select ic.data_type || ' ' || ic.is_nullable from information_schema.columns ic
                where ic.table_schema = 'cma' and ic.table_name = 'app_user' and ic.column_name = 'default_hours_market_code'), 'missing'),
      exists (select 1 from pg_constraint k where k.conrelid = 'cma.app_user'::regclass and k.conname = 'app_user_default_hours_market_fk' and k.contype = 'f'
              and k.confrelid = 'cma.market'::regclass),
      exists (select 1 from pg_trigger g where g.tgrelid = 'cma.app_user'::regclass and g.tgname = 'app_user_default_hours_market_ok' and g.tgenabled = 'O'),
      coalesce((select ic.data_type || ' ' || ic.is_nullable from information_schema.columns ic
                where ic.table_schema = 'cma' and ic.table_name = 'time_event' and ic.column_name = 'hours_market_code'), 'missing'),
      exists (select 1 from pg_constraint k where k.conrelid = 'cma.time_event'::regclass and k.conname = 'time_event_hours_market_fk' and k.contype = 'f'
              and k.confrelid = 'cma.market'::regclass),
      exists (select 1 from pg_constraint k where k.conrelid = 'cma.time_event'::regclass and k.conname = 'time_event_hours_market_kind' and k.contype = 'c'
              and pg_get_constraintdef(k.oid) ~ 'hours_market_code IS NULL' and pg_get_constraintdef(k.oid) ~ 'start' and pg_get_constraintdef(k.oid) ~ 'status'),
      exists (select 1 from pg_trigger g where g.tgrelid = 'cma.time_event'::regclass and g.tgname = 'time_event_hours_market_ok' and g.tgenabled = 'O'),
      (select string_agg(coalesce((select ic.column_name from information_schema.columns ic where ic.table_schema = 'cma_read' and ic.table_name = v.n
                                   order by ic.ordinal_position desc limit 1), 'missing'), ', ' order by v.o)
       from (values (1, 'market'), (2, 'app_user'), (3, 'time_event'), (4, 'time_interval')) v(o, n)),
      (select bool_and(has_table_privilege('cma_readonly', 'cma_read.' || v.n, 'select'))
       from (values ('market'), ('app_user'), ('time_event'), ('time_interval')) v(n))),
    'market text NO, key t, rule t; app_user text YES, key t, rule t; time_event text YES, key t, kind t, rule t; '
      || 'views hours_market_code, default_hours_market_code, hours_market_code, hours_market_code; readers t');

  -- S3: the reads end with the market after their previous columns
  for c in select * from (values
      ('team_status_time', 'cma.team_status_time(date,date,uuid)', 'hours_market_code'),
      ('team_now', 'cma.team_now()', 'hours_market_code'),
      ('export_status_changes', 'cma.export_status_changes(date,date,uuid)', 'hours_market_code'),
      ('export_hours', 'cma.export_hours(date,date,uuid)', 'hours_markets'),
      ('team_day', 'cma.team_day(uuid,date)', 'hours_market_code'),
      ('markets_all', 'cma.markets_all()', 'hours_market_code'),
      ('directory', 'cma.directory()', 'default_hours_market_code')) x(rd, fn, col) loop
    f := to_regprocedure(c.fn);
    if f is null then
      v_bad := v_bad || c.fn || ' missing; ';
      continue;
    end if;
    select string_agg(a.attname, ', ' order by a.n) into v_cols
    from pg_proc p
    join lateral unnest(p.proargnames, p.proargmodes) with ordinality as a(attname, attmode, n) on true
    where p.oid = f and a.attmode = 't';
    if v_cols is distinct from pg_temp.v0009zo_cols(c.rd) || ', ' || c.col then
      v_bad := v_bad || c.rd || ' columns [' || coalesce(v_cols, '') || ']; ';
    end if;
    if (select p.provolatile from pg_proc p where p.oid = f) <> 's' then v_bad := v_bad || c.rd || ' not stable; '; end if;
  end loop;
  if not coalesce((select 'jit=off' = any (p.proconfig) from pg_proc p where p.oid = to_regprocedure('cma.team_now()')), false) then
    v_bad := v_bad || 'team_now jit not off; ';
  end if;
  if to_regprocedure('cma.set_status(uuid,text,timestamptz)') is not null then
    v_bad := v_bad || 'the 3-argument set_status remains; ';
  end if;
  f := to_regprocedure('cma.set_status(uuid,text,timestamptz,text)');
  if f is null then
    v_bad := v_bad || 'the 4-argument set_status missing; ';
  elsif (select p.pronargdefaults <> 2 or p.proargnames[4] <> 'p_hours_market_code' from pg_proc p where p.oid = f) then
    v_bad := v_bad || 'set_status''s p_hours_market_code is not last with its default; ';
  end if;
  foreach v_fn in array array['cma.is_hours_market(text,boolean)', 'cma.assert_hours_market(text,boolean)',
      'cma.workday_hours_market(uuid,timestamptz)', 'cma.resolve_hours_market(text)', 'cma.clock_in_hours_market(uuid)', 'cma.hours_markets()',
      'cma.set_market_hours_market(text,text)', 'cma.set_person_default_hours_market(uuid,text)',
      'cma.set_status(uuid,text,timestamptz,text)', 'cma.open_workday(timestamptz)', 'cma.correct_workday(uuid,date,jsonb,text)',
      'cma.correct_time_event(uuid,text,timestamptz,text,uuid,text,uuid)',
      'cma.team_status_time(date,date,uuid)', 'cma.team_now()', 'cma.export_status_changes(date,date,uuid)',
      'cma.export_hours(date,date,uuid)', 'cma.team_day(uuid,date)', 'cma.markets_all()', 'cma.directory()'] loop
    f := to_regprocedure(v_fn);
    if f is null then v_bad := v_bad || v_fn || ' missing; '; continue; end if;
    if pg_get_userbyid((select p.proowner from pg_proc p where p.oid = f)) <> 'cma_owner' then v_bad := v_bad || v_fn || ' owner; '; end if;
    if not has_function_privilege('cma_app', f, 'execute') then v_bad := v_bad || v_fn || ' not the application''s; '; end if;
    if has_function_privilege('cma_readonly', f, 'execute') then v_bad := v_bad || v_fn || ' the readers''; '; end if;
    if exists (select 1 from pg_proc p cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
               where p.oid = f and a.grantee = 0) then v_bad := v_bad || v_fn || ' public''s; '; end if;
    if (select p.prosecdef from pg_proc p where p.oid = f) then v_bad := v_bad || v_fn || ' security definer; '; end if;
  end loop;
  foreach v_fn in array array['cma.market_hours_market_rules()', 'cma.app_user_default_hours_market_ok()', 'cma.time_event_hours_market_ok()'] loop
    f := to_regprocedure(v_fn);
    if f is null then v_bad := v_bad || v_fn || ' missing; '; continue; end if;
    if has_function_privilege('cma_app', f, 'execute') or has_function_privilege('cma_readonly', f, 'execute')
       or exists (select 1 from pg_proc p cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                  where p.oid = f and a.grantee = 0) then
      v_bad := v_bad || v_fn || ' callable; ';
    end if;
  end loop;
  perform pg_temp.v0009zo_row(3, 'S3', 'the functions: the market last after the previous columns, set_status''s new signature, owner, the application''s, the caller''s rights, stable, team_now jit off, trigger functions nobody''s',
    coalesce(nullif(v_bad, ''), 'ok'), 'ok');
end
$$;

-- ---------------------------------------------------------------------------------------------
-- B. Two throwaway tenants (see the header), always rolled back
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_h      integer := extract(hour from now() at time zone 'UTC')::integer;
  v_k      integer;
  v_z      text;
  v_d      date;
  v_y      date;
  v_t      uuid;
  v_t2     uuid;
  v_admin uuid; v_mgr uuid; v_sup uuid; v_a1 uuid; v_a2 uuid; v_a3 uuid; v_a4 uuid;
  v_conf   uuid;                  -- holds tenant.configure
  v_users  uuid;                  -- manages the agents (users.manage_all or users.manage_agents)
  v_perf   uuid;                  -- holds performance.team
  v_live   uuid;                  -- holds monitoring.live
  v_team   uuid;                  -- holds workday.team
  v_exp    uuid;                  -- holds workday.export
  v_work   cma.work_status;       -- the default: working, productive
  v_other  cma.work_status;       -- working, not productive
  v_pause  cma.work_status;       -- not working
  w1 cma.workday; w2 cma.workday; w2y cma.workday; w3 cma.workday; w4 cma.workday;
  v_e      uuid;
  v_n0     bigint;
  v_b0 text;
  v_b1 text := ''; v_b2 text := ''; v_b3 text := ''; v_b4 text := ''; v_b5 text := ''; v_b6 text; v_b7 text := ''; v_b8 text := '';
  v_eh0 text; v_th0 text; v_ts0 text;
  v_eh1 text; v_th1 text; v_ts1 text;
  v_err    text;
begin
  v_k := greatest(-12, least(14, 9 - v_h));
  v_z := case when v_k = 0 then 'Etc/GMT' when v_k > 0 then 'Etc/GMT-' || v_k else 'Etc/GMT+' || (-v_k) end;
  v_d := cma.business_date(now(), v_z);
  v_y := v_d - 1;
  begin
    v_t  := cma.create_tenant('verify-0009zo', 'Verify 0009zo', 'UTC');
    v_t2 := cma.create_tenant('verify-0009zo-b', 'Verify 0009zo b', 'UTC');
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency) values (v_t2, 'SE', 'Verify SE', 'UTC', 'sv', 'EUR');
    insert into cma.app_user (tenant_id, email, display_name, timezone) values (v_t, 'admin@example.invalid', 'admin', v_z) returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name, timezone) values (v_t, 'mgr@example.invalid', 'mgr', v_z) returning id into v_mgr;
    insert into cma.app_user (tenant_id, email, display_name, timezone) values (v_t, 'sup@example.invalid', 'sup', v_z) returning id into v_sup;
    insert into cma.app_user (tenant_id, email, display_name, timezone) values (v_t, 'a1@example.invalid', 'a1', v_z) returning id into v_a1;
    insert into cma.app_user (tenant_id, email, display_name, timezone) values (v_t, 'a2@example.invalid', 'a2', v_z) returning id into v_a2;
    insert into cma.app_user (tenant_id, email, display_name, timezone) values (v_t, 'a3@example.invalid', 'a3', v_z) returning id into v_a3;
    insert into cma.app_user (tenant_id, email, display_name, timezone) values (v_t, 'a4@example.invalid', 'a4', v_z) returning id into v_a4;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t, x.uid, ar.id
    from (values (v_admin, 'admin'), (v_mgr, 'manager'), (v_sup, 'supervisor'), (v_a1, 'agent'), (v_a2, 'agent'), (v_a3, 'agent'), (v_a4, 'agent')) as x(uid, role_key)
    join cma.app_role ar on ar.tenant_id = v_t and ar.key = x.role_key;
    -- The acting people by permission, never by role name (229's way)
    perform set_config('app.tenant_id', v_t::text, true);
    select x.uid into v_conf  from unnest(array[v_admin, v_mgr, v_sup]) with ordinality x(uid, n) where cma.has_permission(x.uid, 'tenant.configure') order by x.n limit 1;
    select x.uid into v_users from unnest(array[v_mgr, v_admin]) with ordinality x(uid, n)
      where cma.has_permission(x.uid, 'users.manage_all') or cma.has_permission(x.uid, 'users.manage_agents') order by x.n limit 1;
    select x.uid into v_perf  from unnest(array[v_mgr, v_sup, v_admin]) with ordinality x(uid, n) where cma.has_permission(x.uid, 'performance.team') order by x.n limit 1;
    select x.uid into v_live  from unnest(array[v_sup, v_mgr, v_admin]) with ordinality x(uid, n) where cma.has_permission(x.uid, 'monitoring.live') order by x.n limit 1;
    select x.uid into v_team  from unnest(array[v_mgr, v_sup, v_admin]) with ordinality x(uid, n) where cma.has_permission(x.uid, 'workday.team') order by x.n limit 1;
    select x.uid into v_exp   from unnest(array[v_mgr, v_sup, v_admin]) with ordinality x(uid, n) where cma.has_permission(x.uid, 'workday.export') order by x.n limit 1;
    select * into v_work  from cma.work_status where tenant_id = v_t and status = 'active' and is_default and is_working and is_productive;
    select * into v_other from cma.work_status where tenant_id = v_t and status = 'active' and is_working and not is_productive order by sort_order, key collate "C" limit 1;
    select * into v_pause from cma.work_status where tenant_id = v_t and status = 'active' and not is_working order by sort_order, key collate "C" limit 1;
    v_b0 := format('statuses: default %s, other %s, pause %s; people: configure %s, users %s, performance %s, live %s, team %s, export %s',
                   v_work.id is not null, v_other.id is not null, v_pause.id is not null, v_conf is not null, v_users is not null,
                   v_perf is not null, v_live is not null, v_team is not null, v_exp is not null);
    if v_work.id is null or v_other.id is null or v_pause.id is null or v_conf is null or v_users is null or v_perf is null
       or v_live is null or v_team is null or v_exp is null then
      raise exception 'the throwaway tenant lacks a status or a person: %', v_b0;
    end if;

    -- From here on as the application
    perform set_config('role', 'cma_app', true);

    -- The markets, as the admin; each its own hours market by default
    perform set_config('app.user_id', v_conf::text, true);
    perform cma.upsert_market('NL', 'Verify NL', 'UTC', 'nl', 'EUR', null, null, 10);
    perform cma.upsert_market('DE', 'Verify DE', 'UTC', 'de', 'EUR', null, null, 20);
    perform cma.upsert_market('BE', 'Verify BE', 'UTC', 'nl', 'EUR', null, null, 30);
    perform cma.upsert_market('AT', 'Verify AT', 'UTC', 'de', 'EUR', null, null, 40);
    perform cma.upsert_market('FR', 'Verify FR', 'UTC', 'fr', 'EUR', null, null, 50);

    -- B4 (first part): two Default markets, set by a manager of the agents
    perform set_config('app.user_id', v_users::text, true);
    v_b4 := pg_temp.v0009zo_try('a1 NL', format('select cma.set_person_default_hours_market(%L, %L)', v_a1, 'NL')) || '; '
         || pg_temp.v0009zo_try('a4 FR', format('select cma.set_person_default_hours_market(%L, %L)', v_a4, 'FR')) || '; ';

    -- B1: the mapping, as the admin
    perform set_config('app.user_id', v_conf::text, true);
    v_b1 := pg_temp.v0009zo_try('BE to NL', 'select cma.set_market_hours_market(''BE'', ''NL'')') || '; '
         || pg_temp.v0009zo_try('AT to DE', 'select cma.set_market_hours_market(''AT'', ''DE'')') || '; '
         || pg_temp.v0009zo_try('DE to NL (AT books under DE)', 'select cma.set_market_hours_market(''DE'', ''NL'')') || '; '
         || pg_temp.v0009zo_try('FR to NL (a4''s Default market)', 'select cma.set_market_hours_market(''FR'', ''NL'')') || '; '
         || pg_temp.v0009zo_try('FR to BE (no hours market)', 'select cma.set_market_hours_market(''FR'', ''BE'')') || '; '
         || pg_temp.v0009zo_try('FR to SE (another tenant''s)', 'select cma.set_market_hours_market(''FR'', ''SE'')') || '; '
         || pg_temp.v0009zo_try('NL inactive (BE books under it)', 'select cma.set_market_status(''NL'', ''inactive'')') || '; ';
    perform set_config('app.user_id', v_a1::text, true);
    v_b1 := v_b1 || pg_temp.v0009zo_try('agent maps', 'select cma.set_market_hours_market(''FR'', ''DE'')') || '; ';
    perform set_config('role', 'cma_owner', true);
    v_b1 := v_b1 || pg_temp.v0009zo_try('table FR to BE', format('update cma.market set hours_market_code = ''BE'' where tenant_id = %L and code = ''FR''', v_t)) || '; ';
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_conf::text, true);
    select v_b1 || 'markets_all ' || string_agg(m.code || '=' || m.hours_market_code, ', ' order by m.code collate "C")
    into v_b1 from cma.markets_all() m;
    select v_b1 || '; hours markets ' || string_agg(h.code || ' ' || h.status, ', ' order by h.code collate "C")
    into v_b1 from cma.hours_markets() h;

    -- B4 (second part): refusals, then FR goes inactive (allowed: nothing books under it but itself)
    perform set_config('app.user_id', v_users::text, true);
    v_b4 := v_b4 || pg_temp.v0009zo_try('a2 BE', format('select cma.set_person_default_hours_market(%L, %L)', v_a2, 'BE')) || '; '
         || pg_temp.v0009zo_try('a2 SE', format('select cma.set_person_default_hours_market(%L, %L)', v_a2, 'SE')) || '; ';
    perform set_config('app.user_id', v_a1::text, true);
    v_b4 := v_b4 || pg_temp.v0009zo_try('agent sets own', format('select cma.set_person_default_hours_market(%L, %L)', v_a1, 'DE')) || '; ';
    perform set_config('role', 'cma_owner', true);
    v_b4 := v_b4 || pg_temp.v0009zo_try('table a2 BE', format('update cma.app_user set default_hours_market_code = ''BE'' where id = %L', v_a2)) || '; ';
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_conf::text, true);
    v_b4 := v_b4 || pg_temp.v0009zo_try('FR inactive', 'select cma.set_market_status(''FR'', ''inactive'')') || '; ';

    -- The days, each person clocking their own at the local times of the header
    perform set_config('app.user_id', v_a2::text, true);
    w2y := cma.open_workday((v_y + time '05:00') at time zone v_z);
    perform cma.set_status(w2y.id, v_work.key, (v_y + time '06:00') at time zone v_z, 'DE');
    w2y := cma.end_workday(w2y.id, (v_y + time '07:00') at time zone v_z);
    perform set_config('app.user_id', v_a1::text, true);
    w1 := cma.open_workday((v_d + time '05:00') at time zone v_z);
    perform cma.set_status(w1.id, v_other.key, (v_d + time '06:00') at time zone v_z);
    perform cma.set_status(w1.id, null, (v_d + time '06:30') at time zone v_z, 'DE');
    select count(*) into v_n0 from cma.time_event where tenant_id = v_t and workday_id = w1.id;
    perform cma.set_status(w1.id, null, (v_d + time '06:31') at time zone v_z, 'DE');
    v_b3 := 'again ' || ((select count(*) from cma.time_event where tenant_id = v_t and workday_id = w1.id) - v_n0) || ' new; ';
    perform cma.set_status(w1.id, v_pause.key, (v_d + time '07:00') at time zone v_z);
    perform set_config('app.user_id', v_a2::text, true);
    w2 := cma.open_workday((v_d + time '05:00') at time zone v_z);
    perform set_config('app.user_id', v_a3::text, true);
    w3 := cma.open_workday((v_d + time '05:00') at time zone v_z);
    perform set_config('app.user_id', v_a4::text, true);
    w4 := cma.open_workday((v_d + time '05:00') at time zone v_z);

    -- B3: a1's day as booked
    select v_b3 || 'a1 ' || string_agg(
             case e.status_id when v_work.id then 'default' when v_other.id then 'other' when v_pause.id then 'pause' end
             || ':' || coalesce(e.hours_market_code, '-'), ', ' order by e.occurred_at, e.recorded_at)
    into v_b3
    from cma.time_event_effective f join cma.time_event e on e.tenant_id = f.tenant_id and e.id = f.id
    where f.workday_id = w1.id and f.kind in ('start', 'status');

    -- B4: the clock-ins' markets
    select v_b4 || 'clock-in ' || string_agg(x.who || ' ' || coalesce(e.hours_market_code, '-'), ', ' order by x.n)
    into v_b4
    from (values (1, 'a2 yesterday', w2y.id), (2, 'a1', w1.id), (3, 'a2', w2.id), (4, 'a3', w3.id), (5, 'a4', w4.id)) x(n, who, wid)
    join cma.time_event e on e.tenant_id = v_t and e.workday_id = x.wid and e.kind = 'start';

    -- B2: refusals, as a1 on a1's day
    perform set_config('app.user_id', v_a1::text, true);
    v_b2 := pg_temp.v0009zo_try('SE', format('select cma.set_status(%L, %L, now(), ''SE'')', w1.id, v_work.key)) || '; '
         || pg_temp.v0009zo_try('BE', format('select cma.set_status(%L, %L, now(), ''BE'')', w1.id, v_work.key)) || '; '
         || pg_temp.v0009zo_try('FR inactive', format('select cma.set_status(%L, null, now(), ''FR'')', w1.id)) || '; '
         || pg_temp.v0009zo_try('nl', format('select cma.set_status(%L, null, now(), ''nl'')', w1.id)) || '; '
         || pg_temp.v0009zo_try('neither', format('select cma.set_status(%L, null, now(), null)', w1.id)) || '; ';
    perform set_config('role', 'cma_owner', true);
    v_b2 := v_b2 || pg_temp.v0009zo_try('table BE', format(
              'insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source, hours_market_code) values (%L, %L, %L, ''status'', %L, now(), ''user'', ''BE'')',
              v_t, w1.id, v_a1, v_work.id)) || '; '
         || pg_temp.v0009zo_try('table SE', format(
              'insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source, hours_market_code) values (%L, %L, %L, ''status'', %L, now(), ''user'', ''SE'')',
              v_t, w1.id, v_a1, v_work.id)) || '; '
         || pg_temp.v0009zo_try('table end NL', format(
              'insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source, hours_market_code) values (%L, %L, %L, ''end'', null, now(), ''user'', ''NL'')',
              v_t, w1.id, v_a1));
    perform set_config('role', 'cma_app', true);

    -- B6, before: the day's figures
    perform set_config('app.user_id', v_exp::text, true);
    execute format('select string_agg((to_jsonb(t) - ''has_correction'')::text, ''|'' order by t.display_name collate "C") from (select %s from cma.export_hours($1, $1)) t',
                   pg_temp.v0009zo_cols('export_hours')) into v_eh0 using v_d;
    perform set_config('app.user_id', v_team::text, true);
    select string_agg((to_jsonb(h) - 'has_correction')::text, '|' order by h.user_id, h.business_date) into v_th0 from cma.team_hours(v_d, v_d) h;
    perform set_config('app.user_id', v_perf::text, true);
    select string_agg(x.user_id || ' ' || x.status_key || ' ' || x.s, '|' order by x.user_id, x.status_key collate "C") into v_ts0
    from (select t.user_id, t.status_key, sum(t.seconds) as s from cma.team_status_time(v_d, v_d) t group by t.user_id, t.status_key) x;

    -- The markets change: a1's market alone at 06:45, a3's start corrected to DE by the manager
    perform set_config('app.user_id', v_a1::text, true);
    perform cma.set_status(w1.id, null, (v_d + time '06:45') at time zone v_z, 'NL');
    perform set_config('app.user_id', v_team::text, true);
    select e.id into v_e from cma.time_event e where e.tenant_id = v_t and e.workday_id = w3.id and e.kind = 'start';
    perform cma.correct_workday(v_a3, v_d, jsonb_build_array(jsonb_build_object('kind', 'start', 'supersedes', v_e,
              'at', to_jsonb((v_d + time '05:00') at time zone v_z), 'statusKey', v_work.key, 'hoursMarket', 'DE')), 'verify market');

    -- B6, after
    perform set_config('app.user_id', v_exp::text, true);
    execute format('select string_agg((to_jsonb(t) - ''has_correction'')::text, ''|'' order by t.display_name collate "C") from (select %s from cma.export_hours($1, $1)) t',
                   pg_temp.v0009zo_cols('export_hours')) into v_eh1 using v_d;
    perform set_config('app.user_id', v_team::text, true);
    select string_agg((to_jsonb(h) - 'has_correction')::text, '|' order by h.user_id, h.business_date) into v_th1 from cma.team_hours(v_d, v_d) h;
    perform set_config('app.user_id', v_perf::text, true);
    select string_agg(x.user_id || ' ' || x.status_key || ' ' || x.s, '|' order by x.user_id, x.status_key collate "C") into v_ts1
    from (select t.user_id, t.status_key, sum(t.seconds) as s from cma.team_status_time(v_d, v_d) t group by t.user_id, t.status_key) x;
    v_b6 := format('export hours %s; team hours %s; status time %s',
                   case when v_eh0 is not null and v_eh0 = v_eh1 then 'equal' else 'differs' end,
                   case when v_th0 is not null and v_th0 = v_th1 then 'equal' else 'differs' end,
                   case when v_ts0 is not null and v_ts0 = v_ts1 then 'equal' else 'differs' end);

    -- B5: the corrections
    perform set_config('app.user_id', v_team::text, true);
    select 'a3 start ' || e.source || ', ' || e.reason || ', approver ' || (e.approved_by = v_team) || ', ' || coalesce(e.hours_market_code, '-') || '; '
    into v_b5
    from cma.time_event e where e.tenant_id = v_t and e.supersedes_event_id = v_e;
    select e.id into v_e from cma.time_event e where e.tenant_id = v_t and e.workday_id = w2.id and e.kind = 'start';
    v_b5 := v_b5
      || pg_temp.v0009zo_try('BE', format('select cma.correct_workday(%L, %L, %L::jsonb, ''verify market'')', v_a2, v_d,
           jsonb_build_array(jsonb_build_object('kind', 'start', 'supersedes', v_e, 'at', to_jsonb((v_d + time '05:00') at time zone v_z),
                                                'statusKey', v_work.key, 'hoursMarket', 'BE')))) || '; '
      || pg_temp.v0009zo_try('SE', format('select cma.correct_workday(%L, %L, %L::jsonb, ''verify market'')', v_a2, v_d,
           jsonb_build_array(jsonb_build_object('kind', 'start', 'supersedes', v_e, 'at', to_jsonb((v_d + time '05:00') at time zone v_z),
                                                'statusKey', v_work.key, 'hoursMarket', 'SE')))) || '; '
      || pg_temp.v0009zo_try('end NL', format('select cma.correct_workday(%L, %L, %L::jsonb, ''verify market'')', v_a2, v_d,
           jsonb_build_array(jsonb_build_object('kind', 'end', 'at', to_jsonb((v_d + time '06:00') at time zone v_z), 'hoursMarket', 'NL')))) || '; '
      || pg_temp.v0009zo_try('own day', format('select cma.correct_workday(%L, %L, %L::jsonb, ''verify market'')', v_team, v_d,
           jsonb_build_array(jsonb_build_object('kind', 'start', 'at', to_jsonb((v_d + time '05:00') at time zone v_z),
                                                'statusKey', v_work.key, 'hoursMarket', 'NL')))) || '; ';
    -- without hoursMarket: the superseded start's market, then cma.correct_time_event on that correction
    perform cma.correct_workday(v_a2, v_d, jsonb_build_array(jsonb_build_object('kind', 'start', 'supersedes', v_e,
              'at', to_jsonb((v_d + time '05:00') at time zone v_z), 'statusKey', v_work.key)), 'verify keep');
    select e.id into v_e from cma.time_event e where e.tenant_id = v_t and e.supersedes_event_id = v_e;
    perform cma.correct_time_event(w2.id, 'start', (v_d + time '05:00') at time zone v_z, v_work.key, v_e, 'verify keep again', v_team);
    select v_b5 || 'a2 kept ' || string_agg(coalesce(e.hours_market_code, '-'), ' > ' order by e.recorded_at)
    into v_b5
    from cma.time_event e where e.tenant_id = v_t and e.workday_id = w2.id and e.kind = 'start';
    -- a status added without hoursMarket keeps the market in force at its time
    perform cma.correct_workday(v_a2, v_d, jsonb_build_array(jsonb_build_object('kind', 'status',
              'at', to_jsonb((v_d + time '05:10') at time zone v_z), 'statusKey', v_other.key)), 'verify added');
    select v_b5 || '; added ' || coalesce(e.hours_market_code, '-') into v_b5
    from cma.time_event e where e.tenant_id = v_t and e.workday_id = w2.id and e.kind = 'status' and e.source = 'correction';

    -- B7: the reads
    perform set_config('app.user_id', v_team::text, true);
    select 'team day ' || string_agg(
             case d.status_key when v_work.key then 'default' when v_other.key then 'other' when v_pause.key then 'pause' end
             || ':' || coalesce(d.hours_market_code, '-'), ', ' order by d.occurred_at, d.recorded_at)
    into v_b7
    from cma.team_day(v_a1, v_d) d where d.is_effective and d.kind in ('start', 'status');
    perform set_config('app.user_id', v_perf::text, true);
    select v_b7 || '; status time ' || string_agg(x.l, ', ' order by x.l collate "C")
    into v_b7
    from (select case t.status_key when v_work.key then 'default' when v_other.key then 'other' when v_pause.key then 'pause' end
                 || '=' || coalesce(t.hours_market_code, '-') as l
          from cma.team_status_time(v_d, v_d, v_a1) t) x;
    perform set_config('app.user_id', v_live::text, true);
    select v_b7 || '; team now ' || string_agg(n.display_name || '=' || coalesce(n.hours_market_code, '-'), ', ' order by n.display_name collate "C")
    into v_b7
    from cma.team_now() n where n.user_id in (v_a1, v_a2, v_a3, v_a4);
    perform set_config('app.user_id', v_exp::text, true);
    select v_b7 || '; status changes ' || string_agg(coalesce(x.hours_market_code, '-'), ', ' order by x.from_at)
    into v_b7
    from cma.export_status_changes(v_d, v_d, v_a1) x;
    select v_b7 || '; hours ' || string_agg(x.display_name || '=' || x.hours_markets::text, ', ' order by x.display_name collate "C")
    into v_b7
    from cma.export_hours(v_d, v_d) x;
    perform set_config('app.user_id', v_users::text, true);
    select v_b7 || '; directory ' || string_agg(d.display_name || '=' || coalesce(d.default_hours_market_code, '-'), ', ' order by d.display_name collate "C")
    into v_b7
    from cma.directory() d where d.user_id in (v_a1, v_a2, v_a3, v_a4);
    perform set_config('role', 'cma_owner', true);
    select v_b7 || '; readers'' events ' || count(*) filter (where e.hours_market_code is not null) || ' of ' || count(*)
    into v_b7
    from cma_read.time_event e where e.tenant_id = v_t and e.workday_id = w1.id;
    select v_b7 || '; readers'' stretches ' || string_agg(coalesce(i.hours_market_code, '-'), ', ' order by i.from_at)
    into v_b7
    from cma_read.time_interval i where i.tenant_id = v_t and i.workday_id = w1.id;

    -- B8: a4 books under IT from 05:20 (a pause) and 05:30 (the default status, the market kept); the admin maps IT to DE;
    -- a4's next status change, a manager's correction of the 05:20 event without hoursMarket and one of the 05:30 event
    -- that sends IT again (Correct day sends every row's market) book under DE, never refused
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_conf::text, true);
    perform cma.upsert_market('IT', 'Verify IT', 'UTC', 'it', 'EUR', null, null, 60);
    perform set_config('app.user_id', v_a4::text, true);
    perform cma.set_status(w4.id, v_pause.key, (v_d + time '05:20') at time zone v_z, 'IT');
    perform cma.set_status(w4.id, v_work.key, (v_d + time '05:30') at time zone v_z);
    perform set_config('app.user_id', v_conf::text, true);
    v_b8 := pg_temp.v0009zo_try('IT to DE', 'select cma.set_market_hours_market(''IT'', ''DE'')') || '; ';
    perform set_config('app.user_id', v_a4::text, true);
    -- each write its own statement, and the read after it: a stable read in the same statement sees the statement's snapshot
    v_b8 := v_b8 || pg_temp.v0009zo_try('status change', format('select cma.set_status(%L, %L, %L::timestamptz)', w4.id, v_other.key, (v_d + time '05:45') at time zone v_z));
    v_b8 := v_b8 || ' ' || coalesce(cma.workday_hours_market(w4.id), '-') || '; ';
    perform set_config('app.user_id', v_team::text, true);
    select e.id into v_e from cma.time_event e where e.tenant_id = v_t and e.workday_id = w4.id and e.status_id = v_pause.id and e.hours_market_code = 'IT';
    v_b8 := v_b8 || pg_temp.v0009zo_try('correction without hoursMarket', format('select cma.correct_workday(%L, %L, %L::jsonb, ''verify remap'')', v_a4, v_d,
           jsonb_build_array(jsonb_build_object('kind', 'status', 'supersedes', v_e, 'at', to_jsonb((v_d + time '05:20') at time zone v_z),
                                                'statusKey', v_pause.key))));
    v_b8 := v_b8 || ' ' || coalesce((select e.hours_market_code from cma.time_event e where e.tenant_id = v_t and e.supersedes_event_id = v_e), '-') || '; ';
    select e.id into v_e from cma.time_event e where e.tenant_id = v_t and e.workday_id = w4.id and e.status_id = v_work.id and e.hours_market_code = 'IT';
    v_b8 := v_b8 || pg_temp.v0009zo_try('correction sending IT', format('select cma.correct_workday(%L, %L, %L::jsonb, ''verify remap'')', v_a4, v_d,
           jsonb_build_array(jsonb_build_object('kind', 'status', 'supersedes', v_e, 'at', to_jsonb((v_d + time '05:31') at time zone v_z),
                                                'statusKey', v_work.key, 'hoursMarket', 'IT'))));
    v_b8 := v_b8 || ' ' || coalesce((select e.hours_market_code from cma.time_event e where e.tenant_id = v_t and e.supersedes_event_id = v_e), '-') || '; ';
    -- but IT on an event that was not booked under it is refused: it is no hours market now
    select e.id into v_e from cma.time_event e where e.tenant_id = v_t and e.workday_id = w4.id and e.kind = 'start';
    v_b8 := v_b8 || pg_temp.v0009zo_try('IT on another event', format('select cma.correct_workday(%L, %L, %L::jsonb, ''verify remap'')', v_a4, v_d,
           jsonb_build_array(jsonb_build_object('kind', 'start', 'supersedes', v_e, 'at', to_jsonb((v_d + time '05:00') at time zone v_z),
                                                'statusKey', v_work.key, 'hoursMarket', 'IT'))));

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then v_err := sqlstate || ': ' || left(sqlerrm, 300);
      perform set_config('role', 'cma_owner', true);
      insert into pg_temp.verify_0009zo values (10, 'B the throwaway tenants'' checks ran to their end', 'FAIL', coalesce(v_b0, '') || ' | ' || v_err);
  end;
  perform set_config('role', 'cma_owner', true);
  perform set_config('app.tenant_id', '', true);
  perform set_config('app.user_id', '', true);

  perform pg_temp.v0009zo_row(11, 'B1', 'the mapping: to an hours market only, an hours market others book under or a Default market keeps itself, active while booked under, tenant.configure, the table',
    v_b1, 'BE to NL ok; AT to DE ok; DE to NL (AT books under DE) CMA03; FR to NL (a4''s Default market) CMA03; FR to BE (no hours market) CMA04; '
       || 'FR to SE (another tenant''s) CMA02; NL inactive (BE books under it) CMA03; agent maps CMA06; table FR to BE CMA04; '
       || 'markets_all AT=DE, BE=NL, DE=DE, FR=FR, NL=NL; hours markets DE active, FR active, NL active');
  perform pg_temp.v0009zo_row(12, 'B2', 'a status change is refused for a market of another tenant, no hours market, an inactive one, no code, neither; the table refuses',
    v_b2, 'SE CMA02; BE CMA04; FR inactive CMA04; nl CMA04; neither CMA04; table BE CMA04; table SE CMA04; table end NL CMA04');
  perform pg_temp.v0009zo_row(13, 'B3', 'a status change keeps the market; a market change alone books the same status under the new market; again books nothing',
    v_b3, 'again 0 new; a1 default:NL, other:NL, other:DE, pause:DE');
  perform pg_temp.v0009zo_row(14, 'B4', 'the Default market: a manager sets it, refusals; clock-in takes the default, else the last day''s, else none; an inactive default is not used',
    v_b4, 'a1 NL ok; a4 FR ok; a2 BE CMA04; a2 SE CMA02; agent sets own CMA06; table a2 BE CMA04; FR inactive ok; '
       || 'clock-in a2 yesterday -, a1 NL, a2 DE, a3 -, a4 -');
  perform pg_temp.v0009zo_row(15, 'B5', 'a correction changes the market with reason and approver, keeps it without hoursMarket; refusals; four eyes',
    v_b5, 'a3 start correction, verify market, approver true, DE; BE CMA04; SE CMA02; end NL CMA04; own day CMA06; a2 kept DE > DE > DE; added DE');
  perform pg_temp.v0009zo_row(16, 'B6', 'worked, productive, paid and billable for the day equal before and after the markets change',
    v_b6, 'export hours equal; team hours equal; status time equal');
  perform pg_temp.v0009zo_row(17, 'B7', 'the reads answer the market',
    v_b7, 'team day default:NL, other:NL, other:DE, other:NL, pause:DE; status time default=NL, other=DE, other=NL, pause=DE; '
       || 'team now a1=DE, a2=DE, a3=DE, a4=-; status changes NL, NL, DE, NL, DE; hours a1={DE,NL}, a2={DE}, a3={DE}, a4={NULL}; '
       || 'directory a1=NL, a2=-, a3=-, a4=FR; readers'' events 5 of 5; readers'' stretches NL, NL, DE, NL, DE');
  perform pg_temp.v0009zo_row(18, 'B8', 'a market remapped while a day is booked under it never blocks that day',
    v_b8, 'IT to DE ok; status change ok DE; correction without hoursMarket ok DE; correction sending IT ok DE; IT on another event CMA04');
end
$$;

-- ---------------------------------------------------------------------------------------------
-- R. Per active tenant, as the application, always rolled back
-- ---------------------------------------------------------------------------------------------
do $$
declare
  t      record;
  c      record;
  v_who  uuid;
  v_r    text;
  v_err  text;
  v_any  boolean := false;
  v_from date := current_date - 30;
  v_to   date := current_date;
  v_du   uuid;
  v_dd   date;
begin
  for t in select id, slug from cma.tenant where status = 'active' and slug not like 'verify-%' order by slug collate "C" loop
    v_any := true;
    -- R7's day: the tenant's latest day of the last 31 days with a correction, else its latest day (as the owner)
    select w.user_id, w.business_date into v_du, v_dd from cma.workday w
    where w.tenant_id = t.id and w.business_date between v_from and v_to
    order by exists (select 1 from cma.time_event e where e.tenant_id = w.tenant_id and e.workday_id = w.id and e.source = 'correction') desc,
             w.business_date desc, w.id
    limit 1;
    perform set_config('app.tenant_id', t.id::text, true);
    for c in select * from (values
        (21, 'R1', 'team_status_time', array['performance.team'],
         pg_temp.v0009zo_tst_sum(v_from, v_to),
         format('select * from pg_temp.old_team_status_time(%L::date, %L::date)', v_from, v_to), 'eighteen (summed over its markets)'),
        (22, 'R2', 'team_now', array['monitoring.live'],
         format('select %s from cma.team_now()', pg_temp.v0009zo_cols('team_now')),
         'select * from pg_temp.old_team_now()', 'twenty-three'),
        (23, 'R3', 'export_status_changes', array['workday.export'],
         format('select %s from cma.export_status_changes(%L::date, %L::date)', pg_temp.v0009zo_cols('export_status_changes'), v_from, v_to),
         format('select * from pg_temp.old_export_status_changes(%L::date, %L::date)', v_from, v_to), 'nineteen'),
        (24, 'R4', 'export_hours', array['workday.export'],
         format('select %s from cma.export_hours(%L::date, %L::date)', pg_temp.v0009zo_cols('export_hours'), v_from, v_to),
         format('select * from pg_temp.old_export_hours(%L::date, %L::date)', v_from, v_to), 'sixteen'),
        (25, 'R5', 'markets_all', array['tenant.configure'],
         format('select %s from cma.markets_all()', pg_temp.v0009zo_cols('markets_all')),
         'select * from pg_temp.old_markets_all()', 'ten'),
        (26, 'R6', 'directory', array['users.manage_all', 'users.manage_agents'],
         format('select %s from cma.directory()', pg_temp.v0009zo_cols('directory')),
         'select * from pg_temp.old_directory()', 'fifteen'),
        (27, 'R7', 'team_day', array['workday.team'],
         format('select %s from cma.team_day(%L::uuid, %L::date)', pg_temp.v0009zo_cols('team_day'), v_du, v_dd),
         format('select * from pg_temp.old_team_day(%L::uuid, %L::date)', v_du, v_dd), 'twelve (one day)')
      ) as x(ord, id, fn, perms, new_sql, old_sql, n_cols) loop
      v_who := null; v_r := null; v_err := null;
      select u.id into v_who from cma.app_user u
      where u.tenant_id = t.id and u.status = 'active' and u.kind = 'person'
        and exists (select 1 from unnest(c.perms) p where cma.has_permission(u.id, p))
      order by u.created_at, u.id limit 1;
      if v_who is null then
        insert into pg_temp.verify_0009zo values (c.ord, c.id || ' ' || t.slug || ': ' || c.fn,
          case when pg_temp.v0009zo_p(c.id) then 'FAIL' else 'skip' end, 'no active person holds ' || array_to_string(c.perms, ' or ') || ': not compared');
        continue;
      end if;
      begin
        perform set_config('role', 'cma_app', true);
        perform set_config('app.user_id', v_who::text, true);
        v_r := pg_temp.v0009zo_diff(c.id, c.new_sql, c.old_sql);
        if v_r is null then
          execute format('select ''equal, '' || count(*) || '' rows'' from (%s) z', c.new_sql) into v_r;
        end if;
        raise exception using errcode = 'CMAOK', message = 'rollback';
      exception
        when sqlstate 'CMAOK' then null;
        when others then v_err := sqlstate || ': ' || left(sqlerrm, 300);
      end;
      perform set_config('role', 'cma_owner', true);
      perform set_config('app.user_id', '', true);
      insert into pg_temp.verify_0009zo values (c.ord, c.id || ' ' || t.slug || ': ' || c.fn || '''s ' || c.n_cols || ' earlier columns equal the previous definition, row for row, in order',
        case when v_err is null and v_r like 'equal, %' then 'PASS' else 'FAIL' end, coalesce(v_err, v_r));
    end loop;
  end loop;
  perform set_config('app.tenant_id', '', true);
  if not v_any then
    insert into pg_temp.verify_0009zo values (20, 'R per tenant',
      case when current_setting('verify.provoke') <> 'false' then 'FAIL' else 'skip' end, 'no active tenant');
  end if;
end
$$;

drop function if exists pg_temp.old_directory();
drop function if exists pg_temp.old_team_day(uuid, date);
drop function if exists pg_temp.old_markets_all();
drop function if exists pg_temp.old_export_hours(date, date, uuid);
drop function if exists pg_temp.old_export_status_changes(date, date, uuid);
drop function if exists pg_temp.old_team_now();
drop function if exists pg_temp.old_team_status_time(date, date, uuid);
drop function if exists pg_temp.v0009zo_try(text, text);
drop function if exists pg_temp.v0009zo_tst_sum(date, date);
drop function if exists pg_temp.v0009zo_cols(text);
drop function if exists pg_temp.v0009zo_diff(text, text, text);
drop function if exists pg_temp.v0009zo_row(integer, text, text, text, text);
drop function if exists pg_temp.v0009zo_p(text);

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0009zo
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke') <> 'false' then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0009zo where result = 'FAIL') then 'FAIL'
                  when not exists (select 1 from pg_temp.verify_0009zo where result = 'PASS') then 'FAIL'
                  else 'PASS' end,
             format('231_verify_hours_market: %s PASS, %s FAIL, %s skip', (select count(*) from pg_temp.verify_0009zo where result = 'PASS'),
                    (select count(*) from pg_temp.verify_0009zo where result = 'FAIL'), (select count(*) from pg_temp.verify_0009zo where result = 'skip'))) x
order by ord, check_name collate "C";
drop table if exists pg_temp.verify_0009zo;
reset role;
