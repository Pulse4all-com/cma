-- =============================================================================================
-- 253_verify_roster_pause_no_market.sql: verifies addition 0009zz (252_roster_pause_no_market.sql), a pause has no market
-- =============================================================================================
-- Read-only on real data: every behaviour check runs on a throwaway tenant inside a block that always rolls back; the
-- R checks read every active tenant as it is. Run as your own IAM login after 252: dev first (normal, then provoked),
-- then prod before the merge. Expected: the last row reads "PASS | 253_verify_roster_pause_no_market: n PASS, 0 FAIL, ...".
--
-- Checks
--   S1  the addition 0009zz recorded once, after 0009zx
--   S2  the nine re-created functions: the owner's, the application's (the trigger's function nobody's), never the readers'
--       or public's, the caller's rights, the reads stable; each carries the pause rule
--   B   on a throwaway tenant (zone UTC; markets GB and NL as hours markets; team alpha with a1, Default market NL; a
--       manager; types SL (work) and LB (pause)), a1's shift 09:00 to 17:00 on next Monday:
--   B1  the planner's LB-GB is refused (CMA04, a text that says a pause has no hours market) and writes nothing; SL-GB and
--       LB without a market are written, LB stored without one
--   B2  the table refuses a pause with a market on its own (CMA04), a direct insert by the owner
--   B3  an older pause block that still holds a market (set by the owner, as before 0009zz): roster_assignments,
--       roster_cell, roster_slot_coverage and roster_planned_hours show it without one, the work blocks keep theirs (own
--       market under a1's Default market NL)
--   B4  published: my_roster shows the pause with no market, not own market, no market zone; the work block keeps GB
--   B5  Save as standard week saves the older pause without its market; a standard row with LB-GB (as before 0009zz) is
--       shown without it by standard_week() and applied without it, not dropped
--   B6  the planner writes the read-back blocks again: accepted, the older pause ends and LB is stored without a market
--   B7  an older pause with a market of a type retired since: the planner's write of the read-back blocks is accepted (the
--       pause counts as unchanged) and stores it without the market; a new block of the retired type is still refused
--   R1  per active tenant, this week and next, every roster: roster_planned_hours = 248's definition with a pause's market
--       taken away (the work rows equal, the pause rows under no market), both ways
--   R2  per active tenant, the same weeks and rosters: roster_assignments = 248's definition with a pause's market taken
--       away, both ways
--   R3  per active tenant, the fourteen dates of this week and next, every roster: roster_slot_coverage = 248's definition
--       with a pause regrouped under no market, both ways
--   R4  per active tenant: roster_published_blocks_json (what my_roster and roster_today show) = 248's for every published
--       shift of this week and next, a pause's hoursMarket, ownMarket and hoursMarketZone taken away (null, false, null)
-- Provoke: verify.provoke below. 'true': every check reads FAIL and the verdict says PROVOKED, NOT A PASS. A check's id:
-- that check alone compares with a deliberate difference (R1 to R4: 248's side loses a row).
-- Collation: every ordering that feeds a compared text says collate "C".
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);                 -- 'true' for every check, or one check's id such as 'B3'

drop table if exists pg_temp.verify_0009zz;
create temporary table verify_0009zz (ord integer, check_name text, result text, detail text);
grant select, insert on pg_temp.verify_0009zz to cma_app;

create or replace function pg_temp.v0009zz_p(p_id text)
returns boolean
language sql stable
as $$
  select current_setting('verify.provoke') in ('true', p_id)
$$;

-- One check's row: PASS when what was found equals what is expected; provoked, the expectation carries a deliberate difference
create or replace function pg_temp.v0009zz_row(p_ord integer, p_id text, p_name text, p_found text, p_expected text)
returns void
language plpgsql
as $$
declare
  v_exp text := case when pg_temp.v0009zz_p(p_id) then coalesce(p_expected, '') || ' [provoked: a deliberate difference]' else p_expected end;
begin
  insert into pg_temp.verify_0009zz values (p_ord, p_id || ' ' || p_name,
    case when p_found is not distinct from v_exp then 'PASS' else 'FAIL' end,
    case when p_found is not distinct from v_exp then left(coalesce(p_found, 'null'), 900)
         else left('found ' || coalesce(p_found, 'null') || ' | expected ' || coalesce(v_exp, 'null'), 3000) end);
end
$$;

-- An error's SQLSTATE in words for the refusal checks: the code, or 'accepted' when the call went through
create or replace function pg_temp.v0009zz_try(p_sql text)
returns text
language plpgsql
as $$
begin
  execute p_sql;
  return 'accepted';
exception when others then
  return sqlstate;
end
$$;
grant execute on function pg_temp.v0009zz_try(text) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 248's definitions (248_roster_assignments.sql), kept to compare with
-- ---------------------------------------------------------------------------------------------
create or replace function pg_temp.v0009zz_planned_0009zx(p_week_start date, p_team_key text)
returns table (user_id uuid, business_date date, code text, kind text, hours_market_code text, planned_minutes integer)
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
    with raw as materialized (
      select a.user_id, a.business_date, a.start_time, a.end_time, a.hours_market_code, a.assignment_type_id
      from cma.roster_assignment a
      join cma.roster_week w on w.tenant_id = a.tenant_id and w.id = a.roster_week_id
      where a.tenant_id = cma.current_tenant_id()
        and w.week_start = p_week_start and w.team_id is not distinct from v_team
        and a.valid_to is null
    ),
    people as materialized (
      select u.id as user_id, cma.user_timezone(u.id) as zone, u.default_hours_market_code
      from (select distinct r.user_id from raw r) x
      join cma.app_user u on u.tenant_id = cma.current_tenant_id() and u.id = x.user_id
      where cma.on_roster(x.user_id)
    )
    select r.user_id, r.business_date, t.code::text, t.kind::text, coalesce(r.hours_market_code, p.default_hours_market_code)::text,
           sum((extract(epoch from ((r.business_date + r.end_time) at time zone p.zone)
                                 - ((r.business_date + r.start_time) at time zone p.zone)) / 60))::integer
    from raw r
    join people p on p.user_id = r.user_id
    join cma.assignment_type t on t.tenant_id = cma.current_tenant_id() and t.id = r.assignment_type_id
    group by r.user_id, r.business_date, t.code, t.kind, t.sort_order, coalesce(r.hours_market_code, p.default_hours_market_code)
    order by r.user_id, r.business_date, t.sort_order, t.code collate "C",
             coalesce(r.hours_market_code, p.default_hours_market_code) collate "C" nulls last;
end
$$;

create or replace function pg_temp.v0009zz_assignments_0009zx(p_week_start date, p_team_key text)
returns table (assignment_id uuid, user_id uuid, business_date date, code text, name text, kind text, work_area text,
               is_extra boolean, start_time time, end_time time, hours_market_code text, note text, recorded_at timestamptz)
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
    with blocks as materialized (
      select a.* from cma.roster_assignment a
      join cma.roster_week w on w.tenant_id = a.tenant_id and w.id = a.roster_week_id
      where a.tenant_id = cma.current_tenant_id()
        and w.week_start = p_week_start and w.team_id is not distinct from v_team
        and a.valid_to is null
    ),
    people as materialized (
      select x.user_id from (select distinct b.user_id from blocks b) x where cma.on_roster(x.user_id)
    )
    select a.id, a.user_id, a.business_date, t.code::text, t.name::text, t.kind::text, s.work_area::text, t.is_extra,
           a.start_time, a.end_time, a.hours_market_code::text, a.note::text, a.recorded_at
    from blocks a
    join people p on p.user_id = a.user_id
    join cma.assignment_type t on t.tenant_id = a.tenant_id and t.id = a.assignment_type_id
    left join cma.work_status s on s.tenant_id = t.tenant_id and s.id = t.work_status_id
    order by a.business_date, a.user_id, a.start_time;
end
$$;

create or replace function pg_temp.v0009zz_coverage_0009zx(p_date date, p_team_key text)
returns table (
  slot_start         timestamptz,
  slot_time          time,
  working            integer,
  code               text,
  hours_market_code  text,
  people             integer
)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_team uuid;
  v_zone text;
  v_slot integer;
begin
  perform cma.assert_permission('roster.manage');
  if p_date is null then
    raise exception 'a date is required' using errcode = 'CMA04';
  end if;
  v_team := cma.roster_team_id(p_team_key);
  v_zone := cma.roster_planner_zone();
  v_slot := cma.setting_of(cma.current_tenant_id(), 'roster.slot_minutes')::integer;
  return query
    with raw as materialized (
      -- the weeks that hold the business dates around the day, through roster_week_week_idx (no read of older weeks)
      select a.user_id, a.business_date, a.start_time, a.end_time, a.hours_market_code, a.assignment_type_id
      from cma.roster_week w
      join cma.roster_assignment a on a.tenant_id = w.tenant_id and a.roster_week_id = w.id
      where w.tenant_id = cma.current_tenant_id()
        and w.week_start between cma.week_start(p_date - 1) and cma.week_start(p_date + 1)
        and w.team_id is not distinct from v_team
        and a.valid_to is null and a.business_date between p_date - 1 and p_date + 1
    ),
    -- once per person: on the roster, the zone and the Default market (not once per block)
    people as materialized (
      select u.id as user_id, cma.user_timezone(u.id) as zone, u.default_hours_market_code
      from (select distinct r.user_id from raw r) x
      join cma.app_user u on u.tenant_id = cma.current_tenant_id() and u.id = x.user_id
      where cma.on_roster(x.user_id)
    ),
    blocks as materialized (
      select r.user_id, t.code, t.kind, t.sort_order, coalesce(r.hours_market_code, p.default_hours_market_code) as market,
             (r.business_date + r.start_time) at time zone p.zone as starts,
             (r.business_date + r.end_time) at time zone p.zone as ends
      from raw r
      join people p on p.user_id = r.user_id
      join cma.assignment_type t on t.tenant_id = cma.current_tenant_id() and t.id = r.assignment_type_id
    ),
    slots as (
      select s as slot_start
      from generate_series(p_date::timestamp at time zone v_zone,
                           (p_date + 1)::timestamp at time zone v_zone - make_interval(mins => v_slot),
                           make_interval(mins => v_slot)) s
    ),
    hits as materialized (
      select sl.slot_start, b.user_id, b.code, b.kind, b.sort_order, b.market
      from slots sl join blocks b on b.starts <= sl.slot_start and sl.slot_start < b.ends
    ),
    -- the people working per slot, counted once per slot
    working as (
      select h.slot_start, count(distinct h.user_id)::integer as n from hits h where h.kind = 'work' group by h.slot_start
    )
    select h.slot_start, (h.slot_start at time zone v_zone)::time, coalesce(wk.n, 0),
           h.code::text, h.market::text, count(distinct h.user_id)::integer
    from hits h
    left join working wk on wk.slot_start = h.slot_start
    group by h.slot_start, wk.n, h.code, h.sort_order, h.market
    order by h.slot_start, h.sort_order, h.code collate "C", h.market collate "C" nulls last;
end
$$;

create or replace function pg_temp.v0009zz_published_0009zx(p_week_id uuid, p_user_id uuid, p_date date)
returns jsonb
language sql stable
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', t.code, 'name', t.name, 'kind', t.kind, 'workArea', s.work_area, 'isExtra', t.is_extra,
           'start', to_char(a.start_time, 'HH24:MI'),
           'end', case when a.end_time = '24:00'::time then '24:00' else to_char(a.end_time, 'HH24:MI') end,
           'hoursMarket', coalesce(a.hours_market_code, u.default_hours_market_code), 'ownMarket', a.hours_market_code is null,
           'hoursMarketZone', m.time_zone)
           order by a.start_time), '[]'::jsonb)
  from cma.roster_published_assignment a
  join cma.assignment_type t on t.tenant_id = a.tenant_id and t.id = a.assignment_type_id
  left join cma.work_status s on s.tenant_id = t.tenant_id and s.id = t.work_status_id
  join cma.app_user u on u.tenant_id = a.tenant_id and u.id = a.user_id
  left join cma.market m on m.tenant_id = a.tenant_id and m.code = coalesce(a.hours_market_code, u.default_hours_market_code)
  where a.roster_week_id = p_week_id and a.user_id = p_user_id and a.business_date = p_date
$$;

-- ---------------------------------------------------------------------------------------------
-- S. Structure
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f     text;
  v_bad text := '';
begin
  -- S1
  perform pg_temp.v0009zz_row(1, 'S1', 'the addition 0009zz recorded once, after 0009zx',
    format('0009zx %s; 0009zz %s, after 0009zx %s',
           (select count(*) from cma.schema_migration where version = '0009zx'),
           (select count(*) from cma.schema_migration where version = '0009zz'),
           coalesce((select z.applied_at >= x.applied_at from cma.schema_migration z, cma.schema_migration x
                     where z.version = '0009zz' and x.version = '0009zx'), false)),
    '0009zx 1; 0009zz 1, after 0009zx t');

  -- S2
  foreach f in array array['cma.roster_assignment_rules()', 'cma.roster_put_assignments(uuid,uuid,date,jsonb,boolean)',
                           'cma.roster_blocks_json(uuid,date)', 'cma.roster_assignments(date,text)', 'cma.roster_slot_coverage(date,text)',
                           'cma.roster_planned_hours(date,text)', 'cma.standard_week()', 'cma.roster_published_blocks_json(uuid,uuid,date)',
                           'cma.save_standard_week(date,text)'] loop
    if to_regprocedure(f) is null then v_bad := v_bad || f || ' missing; '; continue; end if;
    if pg_get_userbyid((select p.proowner from pg_proc p where p.oid = to_regprocedure(f))) <> 'cma_owner' then v_bad := v_bad || f || ' owner; '; end if;
    if f <> 'cma.roster_assignment_rules()' and not has_function_privilege('cma_app', to_regprocedure(f), 'execute') then
      v_bad := v_bad || f || ' not the application''s; ';
    end if;
    if has_function_privilege('cma_readonly', to_regprocedure(f), 'execute') then v_bad := v_bad || f || ' the readers''; '; end if;
    if exists (select 1 from pg_proc p cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
               where p.oid = to_regprocedure(f) and a.grantee = 0) then v_bad := v_bad || f || ' public''s; '; end if;
    if (select p.prosecdef from pg_proc p where p.oid = to_regprocedure(f)) then v_bad := v_bad || f || ' security definer; '; end if;
    if f in ('cma.roster_blocks_json(uuid,date)', 'cma.roster_assignments(date,text)', 'cma.roster_slot_coverage(date,text)',
             'cma.roster_planned_hours(date,text)', 'cma.standard_week()', 'cma.roster_published_blocks_json(uuid,uuid,date)')
       and (select p.provolatile from pg_proc p where p.oid = to_regprocedure(f)) <> 's' then
      v_bad := v_bad || f || ' not stable; ';
    end if;
    if (select p.prosrc from pg_proc p where p.oid = to_regprocedure(f)) !~ 'pause' then v_bad := v_bad || f || ' without the pause rule; '; end if;
  end loop;
  perform pg_temp.v0009zz_row(2, 'S2', 'the re-created functions: the owner''s, the application''s, the caller''s rights, the reads stable, the pause rule',
    coalesce(nullif(v_bad, ''), 'ok'), 'ok');
end
$$;

-- ---------------------------------------------------------------------------------------------
-- B. On a throwaway tenant, rolled back
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_wk   date := cma.week_start((now() at time zone 'UTC')::date) + 7;
  v_t    uuid;
  v_mgr  uuid; v_a1 uuid;
  v_lb   uuid;
  v_j    jsonb;
  v_err  text;
  v_b1 text; v_b2 text; v_b3 text; v_b4 text; v_b5 text; v_b6 text; v_b7 text;
  e      cma.roster_entry;
  w      cma.roster_week;
begin
  begin
    v_t := cma.create_tenant('verify-0009zz', 'Verify 0009zz', 'UTC');
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency) values
      (v_t, 'GB', 'Verify GB', 'Europe/London', 'en', 'GBP'),
      (v_t, 'NL', 'Verify NL', 'Europe/Amsterdam', 'nl', 'EUR');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'mgr@example.invalid', 'mgr') returning id into v_mgr;
    insert into cma.app_user (tenant_id, email, display_name, default_hours_market_code) values (v_t, 'a1@example.invalid', 'a1', 'NL') returning id into v_a1;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t, x.uid, ar.id
    from (values (v_mgr, 'admin'), (v_a1, 'agent')) as x(uid, role_key)
    join cma.app_role ar on ar.tenant_id = v_t and ar.key = x.role_key;
    insert into cma.team (tenant_id, key, name, markets, sort_order) values (v_t, 'alpha', 'Team Alpha', array['xa'], 10);
    insert into cma.team_member (tenant_id, user_id, team_id)
    select v_t, v_a1, t.id from cma.team t where t.tenant_id = v_t and t.key = 'alpha';
    insert into cma.work_status (tenant_id, key, name, is_working, is_productive, is_paid, is_billable, is_default, sort_order, work_area) values
      (v_t, 'v_sales', 'Verify sales', true, true, true, true, false, 11, 'sales');

    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_mgr::text, true);
    perform cma.upsert_assignment_type('SL', 'Sales', 'work', 'v_sales', false, 10);
    perform cma.upsert_assignment_type('LB', 'Lunch break', 'pause', 'lunch', false, 90);
    e := cma.roster_set_entry(v_wk, 'alpha', v_a1, v_wk, 'shift', '09:00', '17:00', null, null);

    -- B1: the planner's LB-GB refused, with words that say why; then the plan without it
    begin
      perform cma.roster_set_assignments(v_wk, 'alpha', v_a1, v_wk,
        '[{"code":"SL","start":"09:00","end":"12:00","hoursMarket":"GB"},{"code":"LB","start":"12:00","end":"12:30","hoursMarket":"GB"}]');
      v_b1 := 'LB-GB accepted';
    exception when others then
      -- the planner's own words (the writer's), not the table's: "plan LB without one, not LB-GB"
      v_b1 := format('LB-GB %s, says %s', sqlstate, case when sqlerrm ~ 'is a pause' and sqlerrm ~ 'not LB-GB' then 'why' else sqlerrm end);
    end;
    v_b1 := v_b1 || format('; written %s', (select count(*) from cma.roster_assignment a where a.tenant_id = v_t));
    v_j := cma.roster_set_assignments(v_wk, 'alpha', v_a1, v_wk,
      '[{"code":"SL","start":"09:00","end":"12:00","hoursMarket":"GB"},{"code":"LB","start":"12:00","end":"12:30"},{"code":"SL","start":"12:30","end":"17:00"}]');
    select v_b1 || '; stored ' || string_agg(t.code || ' ' || coalesce(a.hours_market_code, '-'), ', ' order by a.start_time)
    into v_b1
    from cma.roster_assignment a join cma.assignment_type t on t.tenant_id = a.tenant_id and t.id = a.assignment_type_id
    where a.tenant_id = v_t and a.valid_to is null;

    -- B2: the table refuses on its own (the owner inserts directly)
    perform set_config('role', 'cma_owner', true);
    select t.id into v_lb from cma.assignment_type t where t.tenant_id = v_t and t.code = 'LB';
    v_b2 := 'table: LB GB ' || pg_temp.v0009zz_try(format(
      $q$insert into cma.roster_assignment (tenant_id, roster_week_id, user_id, business_date, assignment_type_id, start_time, end_time, hours_market_code)
         values (%L, %L, %L, %L, %L, '16:00', '16:30', 'GB')$q$, v_t, e.roster_week_id, v_a1, v_wk, v_lb));

    -- B3: an older pause block with a market, as before 0009zz (the insert rule does not see an update by the owner)
    update cma.roster_assignment set hours_market_code = 'GB'
     where tenant_id = v_t and assignment_type_id = v_lb and valid_to is null;
    perform set_config('role', 'cma_app', true);
    select 'assignments ' || string_agg(a.code || ' ' || coalesce(a.hours_market_code, '-'), ', ' order by a.start_time)
    into v_b3 from cma.roster_assignments(v_wk, 'alpha') a;
    select v_b3 || '; cell ' || string_agg(x->>'code' || ' ' || coalesce(x->>'hoursMarket', '-'), ', ')
    into v_b3 from cma.roster_cell(v_wk, 'alpha', v_a1, v_wk) c cross join lateral jsonb_array_elements(c.assignments) x;
    select v_b3 || '; coverage ' || string_agg(k, ', ' order by k collate "C")
    into v_b3 from (select distinct c.code || '/' || coalesce(c.hours_market_code, '-') as k from cma.roster_slot_coverage(v_wk, 'alpha') c) c;
    select v_b3 || '; planned ' || string_agg(p.code || '/' || coalesce(p.hours_market_code, '-') || '=' || p.planned_minutes, ', '
                                              order by p.code collate "C", p.hours_market_code collate "C")
    into v_b3 from cma.roster_planned_hours(v_wk, 'alpha') p;

    -- B4: published, the agent's view
    w := cma.roster_publish(v_wk, 'alpha');
    perform set_config('app.user_id', v_a1::text, true);
    select 'agent ' || string_agg(x->>'code' || ' ' || coalesce(x->>'hoursMarket', '-') || ' ' || (x->>'ownMarket') || ' ' || coalesce(x->>'hoursMarketZone', '-'), ', ')
    into v_b4 from cma.my_roster(v_wk, v_wk) m cross join lateral jsonb_array_elements(m.assignments) x;
    perform set_config('app.user_id', v_mgr::text, true);

    -- B5: Save as standard week takes the older pause without its market; a standard row with LB-GB is shown and applied
    -- without it
    perform cma.save_standard_week(v_wk, 'alpha');
    perform set_config('role', 'cma_owner', true);
    select 'saved ' || string_agg(t.code || ' ' || coalesce(x.hours_market_code, '-'), ', ' order by x.start_time)
    into v_b5
    from cma.standard_week_assignment x join cma.assignment_type t on t.tenant_id = x.tenant_id and t.id = x.assignment_type_id
    where x.tenant_id = v_t and x.valid_to is null;
    update cma.standard_week_assignment set hours_market_code = 'GB'
     where tenant_id = v_t and assignment_type_id = v_lb and valid_to is null;
    perform set_config('role', 'cma_app', true);
    select v_b5 || '; standard_week ' || string_agg(x->>'code' || ' ' || coalesce(x->>'hoursMarket', '-'), ', ')
    into v_b5 from cma.standard_week() s cross join lateral jsonb_array_elements(s.assignments) x;
    select v_b5 || '; apply ' || string_agg(r.outcome || ' ' || r.blocks || ' dropped ' || r.blocks_dropped, ', ')
    into v_b5 from cma.apply_standard_week(v_wk + 7, 'alpha') r;
    select v_b5 || '; applied ' || string_agg(a.code || ' ' || coalesce(a.hours_market_code, '-'), ', ' order by a.start_time)
    into v_b5 from cma.roster_assignments(v_wk + 7, 'alpha') a;
    perform set_config('role', 'cma_owner', true);
    select v_b5 || '; stored ' || string_agg(t.code || ' ' || coalesce(a.hours_market_code, '-'), ', ' order by a.start_time)
    into v_b5
    from cma.roster_assignment a join cma.assignment_type t on t.tenant_id = a.tenant_id and t.id = a.assignment_type_id
    where a.tenant_id = v_t and a.business_date = v_wk + 7 and a.valid_to is null;
    perform set_config('role', 'cma_app', true);

    -- B6: the planner writes back what it read: the older pause ends and LB is stored without a market
    select jsonb_agg(jsonb_build_object('code', x->>'code', 'start', x->>'start', 'end', x->>'end', 'hoursMarket', x->'hoursMarket'))
    into v_j from cma.roster_cell(v_wk, 'alpha', v_a1, v_wk) c cross join lateral jsonb_array_elements(c.assignments) x;
    v_j := cma.roster_set_assignments(v_wk, 'alpha', v_a1, v_wk, v_j);
    v_b6 := format('kept %s ended %s added %s', v_j->>'kept', v_j->>'ended', v_j->>'added');
    perform set_config('role', 'cma_owner', true);
    select v_b6 || '; stored ' || string_agg(t.code || ' ' || coalesce(a.hours_market_code, '-'), ', ' order by a.start_time)
    into v_b6
    from cma.roster_assignment a join cma.assignment_type t on t.tenant_id = a.tenant_id and t.id = a.assignment_type_id
    where a.tenant_id = v_t and a.business_date = v_wk and a.valid_to is null;

    -- B7: an older pause with a market (as before 0009zz) whose type was retired since: the planner writes back what it read
    perform set_config('role', 'cma_app', true);
    e := cma.roster_set_entry(v_wk, 'alpha', v_a1, v_wk + 1, 'shift', '09:00', '17:00', null, null);
    v_j := cma.roster_set_assignments(v_wk, 'alpha', v_a1, v_wk + 1,
      '[{"code":"SL","start":"09:00","end":"12:00"},{"code":"LB","start":"12:00","end":"12:30"}]');
    perform set_config('role', 'cma_owner', true);
    update cma.roster_assignment set hours_market_code = 'GB'
     where tenant_id = v_t and assignment_type_id = v_lb and business_date = v_wk + 1 and valid_to is null;
    perform set_config('role', 'cma_app', true);
    perform cma.upsert_assignment_type('LB', 'Lunch break', 'pause', 'lunch', false, 90, 'inactive');
    select jsonb_agg(jsonb_build_object('code', x->>'code', 'start', x->>'start', 'end', x->>'end', 'hoursMarket', x->'hoursMarket'))
    into v_j from cma.roster_cell(v_wk, 'alpha', v_a1, v_wk + 1) c cross join lateral jsonb_array_elements(c.assignments) x;
    v_b7 := 'write back ' || pg_temp.v0009zz_try(format('select cma.roster_set_assignments(%L, %L, %L, %L, %L)', v_wk, 'alpha', v_a1, v_wk + 1, v_j));
    perform set_config('role', 'cma_owner', true);
    select v_b7 || '; stored ' || string_agg(t.code || ' ' || coalesce(a.hours_market_code, '-'), ', ' order by a.start_time)
    into v_b7
    from cma.roster_assignment a join cma.assignment_type t on t.tenant_id = a.tenant_id and t.id = a.assignment_type_id
    where a.tenant_id = v_t and a.business_date = v_wk + 1 and a.valid_to is null;
    perform set_config('role', 'cma_app', true);
    v_b7 := v_b7 || '; a new LB ' || pg_temp.v0009zz_try(format('select cma.roster_set_assignments(%L, %L, %L, %L, %L)', v_wk, 'alpha', v_a1, v_wk + 1,
      '[{"code":"SL","start":"09:00","end":"12:00"},{"code":"LB","start":"12:00","end":"12:30"},{"code":"LB","start":"16:30","end":"17:00"}]'));

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then v_err := sqlstate || ': ' || left(sqlerrm, 300);
      perform set_config('role', 'cma_owner', true);
      insert into pg_temp.verify_0009zz values (10, 'B the throwaway tenant''s checks ran to their end', 'FAIL', v_err);
  end;
  perform set_config('role', 'cma_owner', true);
  perform set_config('app.tenant_id', '', true);
  perform set_config('app.user_id', '', true);

  perform pg_temp.v0009zz_row(11, 'B1', 'the planner''s CODE-MARKET on a pause is refused and says why; a pause is stored without a market',
    v_b1, 'LB-GB CMA04, says why; written 0; stored SL GB, LB -, SL -');
  perform pg_temp.v0009zz_row(12, 'B2', 'the table refuses a pause with a market on its own',
    v_b2, 'table: LB GB CMA04');
  perform pg_temp.v0009zz_row(13, 'B3', 'an older pause with a market reads without one; the work blocks keep theirs',
    v_b3, 'assignments SL GB, LB -, SL -; cell SL GB, LB -, SL -; coverage LB/-, SL/GB, SL/NL; planned LB/-=30, SL/GB=180, SL/NL=270');
  perform pg_temp.v0009zz_row(14, 'B4', 'published: the pause has no market, is not own market and has no zone',
    v_b4, 'agent SL GB false Europe/London, LB - false -, SL NL true Europe/Amsterdam');
  perform pg_temp.v0009zz_row(15, 'B5', 'the Standard week saves, shows and applies a pause without a market, never dropping it',
    v_b5, 'saved SL GB, LB -, SL -; standard_week SL GB, LB -, SL -; apply done 3 dropped 0; applied SL GB, LB -, SL -; stored SL GB, LB -, SL -');
  perform pg_temp.v0009zz_row(16, 'B6', 'the planner''s write of the read-back blocks ends the older pause and stores it without a market',
    v_b6, 'kept 2 ended 1 added 1; stored SL GB, LB -, SL -');
  perform pg_temp.v0009zz_row(17, 'B7', 'an older pause of a retired type: the write-back is accepted and stores it without a market; a new one is refused',
    v_b7, 'write back accepted; stored SL -, LB -; a new LB CMA04');
end
$$;

-- ---------------------------------------------------------------------------------------------
-- R. Every active tenant as it is: the re-created reads against 248's, a pause's market taken away
-- ---------------------------------------------------------------------------------------------
do $$
declare
  t         record;
  v_this    date := cma.week_start((now() at time zone 'UTC')::date);
  v_planner uuid;
  wk        date;
  tk        text;
  v_r1 text; v_r2 text; v_r3 text; v_r4 text;
  v_n1 integer; v_n2 integer; v_n3 integer; v_n4 integer;
  v_o1 integer := case when pg_temp.v0009zz_p('R1') then 1 else 0 end;
  v_o2 integer := case when pg_temp.v0009zz_p('R2') then 1 else 0 end;
  v_o3 integer := case when pg_temp.v0009zz_p('R3') then 1 else 0 end;
  v_o4 integer := case when pg_temp.v0009zz_p('R4') then 1 else 0 end;
  d         date;
  pe        record;
  v_any boolean := false;
  v_err text;
begin
  for t in select x.id, x.slug from cma.tenant x where x.status = 'active' order by x.slug collate "C" loop
    v_any := true;
    v_r1 := ''; v_r2 := ''; v_r3 := ''; v_r4 := ''; v_n1 := 0; v_n2 := 0; v_n3 := 0; v_n4 := 0; v_err := null;
    perform set_config('app.tenant_id', t.id::text, true);   -- cma.has_permission reads the current tenant
    select u.id into v_planner from cma.app_user u
    where u.tenant_id = t.id and u.status = 'active' and u.kind = 'person' and cma.has_permission(u.id, 'roster.manage')
    order by u.created_at, u.id limit 1;
    begin
      perform set_config('role', 'cma_app', true);
      if v_planner is not null then
        perform set_config('app.user_id', v_planner::text, true);
        foreach wk in array array[v_this, v_this + 7] loop
          for tk in select null::text union all select x.key::text from cma.team x where x.tenant_id = t.id and x.valid_to is null loop
            -- R1: 248's planned minutes, a pause regrouped under no market (provoked: 248's side loses a row)
            v_n1 := v_n1 + (select count(*) from cma.roster_planned_hours(wk, tk));
            if exists ((select n.user_id, n.business_date, n.code, n.kind, n.hours_market_code, n.planned_minutes from cma.roster_planned_hours(wk, tk) n)
                       except all
                       (select o.user_id, o.business_date, o.code, o.kind, case when o.kind = 'pause' then null else o.hours_market_code end,
                               sum(o.planned_minutes)::integer
                        from (select * from pg_temp.v0009zz_planned_0009zx(wk, tk) offset v_o1) o
                        group by o.user_id, o.business_date, o.code, o.kind, case when o.kind = 'pause' then null else o.hours_market_code end))
               or exists ((select o.user_id, o.business_date, o.code, o.kind, case when o.kind = 'pause' then null else o.hours_market_code end,
                                  sum(o.planned_minutes)::integer
                           from (select * from pg_temp.v0009zz_planned_0009zx(wk, tk) offset v_o1) o
                           group by o.user_id, o.business_date, o.code, o.kind, case when o.kind = 'pause' then null else o.hours_market_code end)
                          except all
                          (select n.user_id, n.business_date, n.code, n.kind, n.hours_market_code, n.planned_minutes from cma.roster_planned_hours(wk, tk) n))
               or (v_o1 = 1 and not exists (select 1 from cma.roster_planned_hours(wk, tk))) then
              v_r1 := v_r1 || wk || '/' || coalesce(tk, 'tenant') || ' ';
            end if;
            -- R2: 248's blocks, a pause's market taken away
            v_n2 := v_n2 + (select count(*) from cma.roster_assignments(wk, tk));
            if exists ((select n.* from cma.roster_assignments(wk, tk) n)
                       except all
                       (select o.assignment_id, o.user_id, o.business_date, o.code, o.name, o.kind, o.work_area, o.is_extra, o.start_time,
                               o.end_time, case when o.kind = 'pause' then null else o.hours_market_code end, o.note, o.recorded_at
                        from pg_temp.v0009zz_assignments_0009zx(wk, tk) o offset v_o2))
               or exists ((select o.assignment_id, o.user_id, o.business_date, o.code, o.name, o.kind, o.work_area, o.is_extra, o.start_time,
                                  o.end_time, case when o.kind = 'pause' then null else o.hours_market_code end, o.note, o.recorded_at
                           from pg_temp.v0009zz_assignments_0009zx(wk, tk) o offset v_o2)
                          except all
                          (select n.* from cma.roster_assignments(wk, tk) n))
               or (v_o2 = 1 and not exists (select 1 from cma.roster_assignments(wk, tk))) then
              v_r2 := v_r2 || wk || '/' || coalesce(tk, 'tenant') || ' ';
            end if;
          end loop;
        end loop;
        -- R3: 248's slot coverage, a pause regrouped under no market (a person holds one block per slot, so the people of
        -- the merged rows add up); fourteen dates, every roster
        for d in select generate_series(v_this, v_this + 13, interval '1 day')::date loop
          for tk in select null::text union all select x.key::text from cma.team x where x.tenant_id = t.id and x.valid_to is null loop
            v_n3 := v_n3 + (select count(*) from cma.roster_slot_coverage(d, tk));
            if exists ((select n.slot_start, n.slot_time, n.working, n.code, n.hours_market_code, n.people from cma.roster_slot_coverage(d, tk) n)
                       except all
                       (select o.slot_start, o.slot_time, o.working, o.code, case when ty.kind = 'pause' then null else o.hours_market_code end,
                               sum(o.people)::integer
                        from (select * from pg_temp.v0009zz_coverage_0009zx(d, tk) offset v_o3) o
                        left join cma.assignment_type ty on ty.tenant_id = t.id and ty.code = o.code
                        group by o.slot_start, o.slot_time, o.working, o.code, case when ty.kind = 'pause' then null else o.hours_market_code end))
               or exists ((select o.slot_start, o.slot_time, o.working, o.code, case when ty.kind = 'pause' then null else o.hours_market_code end,
                                  sum(o.people)::integer
                           from (select * from pg_temp.v0009zz_coverage_0009zx(d, tk) offset v_o3) o
                           left join cma.assignment_type ty on ty.tenant_id = t.id and ty.code = o.code
                           group by o.slot_start, o.slot_time, o.working, o.code, case when ty.kind = 'pause' then null else o.hours_market_code end)
                          except all
                          (select n.slot_start, n.slot_time, n.working, n.code, n.hours_market_code, n.people from cma.roster_slot_coverage(d, tk) n))
               or (v_o3 = 1 and not exists (select 1 from cma.roster_slot_coverage(d, tk))) then
              v_r3 := v_r3 || d || '/' || coalesce(tk, 'tenant') || ' ';
            end if;
          end loop;
        end loop;
      end if;
      -- R4: the published blocks of every published shift this week and next, against 248's with a pause's market taken away
      for pe in select e.roster_week_id, e.user_id, e.business_date from cma.roster_published_entry e
                where e.kind = 'shift' and e.business_date between v_this and v_this + 13 loop
        v_n4 := v_n4 + 1;
        if cma.roster_published_blocks_json(pe.roster_week_id, pe.user_id, pe.business_date) is distinct from
           (select coalesce(jsonb_agg(case when x->>'kind' = 'pause'
                                           then x || '{"hoursMarket": null, "ownMarket": false, "hoursMarketZone": null}'::jsonb else x end
                                      order by n), '[]'::jsonb)
            from jsonb_array_elements(pg_temp.v0009zz_published_0009zx(pe.roster_week_id, pe.user_id, pe.business_date)) with ordinality as a(x, n)
            where n > v_o4) then
          v_r4 := v_r4 || pe.business_date || ' ';
        end if;
      end loop;
      if v_o4 = 1 and v_n4 = 0 then v_r4 := 'none to compare'; end if;
    exception when others then
      v_err := sqlstate || ': ' || left(sqlerrm, 300);
    end;
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.tenant_id', '', true);
    perform set_config('app.user_id', '', true);
    if v_err is not null then
      insert into pg_temp.verify_0009zz values (30, 'R1 and R2 ' || t.slug || ': the checks ran to their end', 'FAIL', v_err);
      continue;
    end if;
    if v_planner is null then
      insert into pg_temp.verify_0009zz values (31, 'R1 and R2 ' || t.slug,
        case when pg_temp.v0009zz_p('R1') or pg_temp.v0009zz_p('R2') then 'FAIL' else 'skip' end, 'no active person holds roster.manage');
    else
      insert into pg_temp.verify_0009zz values (31, 'R1 ' || t.slug || ': roster_planned_hours = 248''s, a pause under no market',
        case when btrim(v_r1) <> '' then 'FAIL' else 'PASS' end,
        format('rows %s; differing %s', v_n1, coalesce(nullif(btrim(v_r1), ''), 'none')));
      insert into pg_temp.verify_0009zz values (32, 'R2 ' || t.slug || ': roster_assignments = 248''s, a pause without its market',
        case when btrim(v_r2) <> '' then 'FAIL' else 'PASS' end,
        format('rows %s; differing %s', v_n2, coalesce(nullif(btrim(v_r2), ''), 'none')));
      insert into pg_temp.verify_0009zz values (33, 'R3 ' || t.slug || ': roster_slot_coverage = 248''s, a pause under no market',
        case when btrim(v_r3) <> '' then 'FAIL' else 'PASS' end,
        format('rows %s; differing %s', v_n3, coalesce(nullif(btrim(v_r3), ''), 'none')));
    end if;
    insert into pg_temp.verify_0009zz values (34, 'R4 ' || t.slug || ': the published blocks = 248''s, a pause without market, own market or zone',
      case when btrim(v_r4) <> '' then 'FAIL' else 'PASS' end,
      format('published shifts %s; differing %s', v_n4, coalesce(nullif(btrim(v_r4), ''), 'none')));
  end loop;
  if not v_any then
    insert into pg_temp.verify_0009zz values (30, 'R1 and R2 per tenant',
      case when current_setting('verify.provoke') <> 'false' then 'FAIL' else 'skip' end, 'no active tenant');
  end if;
end
$$;

drop function if exists pg_temp.v0009zz_published_0009zx(uuid, uuid, date);
drop function if exists pg_temp.v0009zz_coverage_0009zx(date, text);
drop function if exists pg_temp.v0009zz_assignments_0009zx(date, text);
drop function if exists pg_temp.v0009zz_planned_0009zx(date, text);
drop function if exists pg_temp.v0009zz_try(text);
drop function if exists pg_temp.v0009zz_row(integer, text, text, text, text);
drop function if exists pg_temp.v0009zz_p(text);

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0009zz
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke') <> 'false' then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0009zz where result = 'FAIL') then 'FAIL'
                  when not exists (select 1 from pg_temp.verify_0009zz where result = 'PASS') then 'FAIL'
                  else 'PASS' end,
             format('253_verify_roster_pause_no_market: %s PASS, %s FAIL, %s skip', (select count(*) from pg_temp.verify_0009zz where result = 'PASS'),
                    (select count(*) from pg_temp.verify_0009zz where result = 'FAIL'), (select count(*) from pg_temp.verify_0009zz where result = 'skip'))) x
order by ord, check_name collate "C";
drop table if exists pg_temp.verify_0009zz;
reset role;
