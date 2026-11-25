-- =============================================================================================
-- 247_verify_roster_assignments.sql: verifies addition 0009zw (246_roster_assignments.sql), Assignments in the roster
-- =============================================================================================
-- Read-only on real data: every behaviour check runs on a throwaway tenant inside a block that always rolls back; the
-- R checks read every active tenant as it is. Run as your own IAM login after 246: dev first (normal, then provoked),
-- then prod before the merge. Expected: the last row reads "PASS | 247_verify_roster_assignments: n PASS, 0 FAIL, ...".
--
-- Checks
--   S1  the addition 0009zw recorded once, after 0009zv
--   S2  the four new tables: row-level security with the tenant policy, the audit trigger, no delete and only the
--       versioning columns to update for the application, no base-table read for the readers, a cma_read face; the
--       exclusion constraints in place (btree_gist); absence_type.carries_over and cma_read.absence_type ending with it
--   S3  every new and re-created function: the owner's, the application's, never the readers' or public's, the caller's
--       rights; the reads stable; my_roster and roster_today end with assignments, roster_people with
--       default_hours_market_code, absence_types with carries_over
--   S4  the settings: roster.slot_minutes (5 to 60, default 15), roster.lunch_after_minutes (360), roster.planner_timezone
--       (empty), and the zone trigger on cma.tenant_setting
--   B   on a throwaway tenant (zone UTC; planner zone Africa/Lagos, UTC + 1 all year, from B9; markets GB and NL as hours markets, BE
--       mapped to NL; team alpha with a1 and a2, a1's Default market NL; an admin, a manager and an analyst):
--   B1  the type catalog (D2, D4): the admin adds SL, GO, LB and X; a code in lower case, a work type booking a pause
--       status, an extra type with a status and the manager's write are refused; an agent reads the catalog
--   B2  the refusals of roster_set_assignments (D5, D6): overlap, off the grid, outside the shift, no shift, a market that
--       is no hours market, UK (the alias lives in the parser), an unknown type, the past, a person not on the roster, an
--       agent (CMA06); the table refuses on its own: a direct overlap (23P01), an off-grid row and a BE row (CMA04), UK
--       (the market rule of the trigger, before the foreign key)
--   B3  versioning (D7): a rewrite keeps the equal blocks, ends the changed one with its successor, inserts the new one
--   B4  the published read (D7): an agent sees no block before the publication, the published blocks after it, the earlier
--       publication while a later change waits, and the header says changed since the publication for a block alone
--   B5  a shortened shift ends the blocks outside it without a successor, and roster_cell reports them; an absence ends
--       the rest
--   B6  D8: a change to today in a published week publishes at once; with another change waiting it is refused (CMA03,
--       publish_others=1) and writes nothing; confirmed, it publishes both; a future date in a published week stays draft
--   B7  Copy week (D10): the blocks come with the shift, an absence only when its type carries over, the report says why
--   B8  the Standard week (D9): save reports what it saved and skipped, apply fills empty person-dates only and never
--       overwrites, a second save keeps the replaced rows readable
--   B9  the planner zone setting refuses a name that is no zone; the grid setting refuses 7 and a 30-minute grid refuses
--       09:15
--   B10 D12 on a fixture week: coverage per slot of the planner zone's day (UTC + 1: a1's 09:00 is the planner's 10:00) and the
--       planned minutes per person, type and hours market
--   B11 an agent reads none of the planner's functions (CMA06)
--   R1  per active tenant: roster_week = 0005's definition for this week and the next on every roster, but where a block
--       changed after the publication (changed_since_publish may then be true where 0005's says false)
--   R2  per active tenant: my_roster's earlier columns = 0005's for the first person holding roster.view, this week and next
--   R3  per active tenant: absence_types' earlier columns = 0005's
-- Provoke: verify.provoke below. 'true': every check reads FAIL and the verdict says PROVOKED, NOT A PASS. A check's id:
-- that check alone compares with a deliberate difference.
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

drop table if exists pg_temp.verify_0009zw;
create temporary table verify_0009zw (ord integer, check_name text, result text, detail text);
grant select, insert on pg_temp.verify_0009zw to cma_app;

create or replace function pg_temp.v0009zw_p(p_id text)
returns boolean
language sql stable
as $$
  select current_setting('verify.provoke') in ('true', p_id)
$$;

-- One check's row: PASS when what was found equals what is expected; provoked, the expectation carries a deliberate difference
create or replace function pg_temp.v0009zw_row(p_ord integer, p_id text, p_name text, p_found text, p_expected text)
returns void
language plpgsql
as $$
declare
  v_exp text := case when pg_temp.v0009zw_p(p_id) then coalesce(p_expected, '') || ' [provoked: a deliberate difference]' else p_expected end;
begin
  insert into pg_temp.verify_0009zw values (p_ord, p_id || ' ' || p_name,
    case when p_found is not distinct from v_exp then 'PASS' else 'FAIL' end,
    case when p_found is not distinct from v_exp then left(coalesce(p_found, 'null'), 900)
         else left('found ' || coalesce(p_found, 'null') || ' | expected ' || coalesce(v_exp, 'null'), 3000) end);
end
$$;

-- An error's SQLSTATE in words for the refusal checks: the code, or 'accepted' when the call went through
create or replace function pg_temp.v0009zw_try(p_sql text)
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
grant execute on function pg_temp.v0009zw_try(text) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 0005's definitions (23_roster.sql), kept to compare with
-- ---------------------------------------------------------------------------------------------
create or replace function pg_temp.v0009zw_week_0005(p_week_start date, p_team_key text)
returns table (week_id uuid, team_key text, team_name text, week_start date, status text, version integer,
               published_at timestamptz, published_by_name text, entry_count integer, changed_since_publish boolean)
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
    select w.id, t.key::text, t.name::text, p_week_start,
           coalesce(w.status, 'draft')::text, coalesce(w.version, 0), w.published_at, pb.display_name::text,
           coalesce((select count(*)::integer from cma.roster_entry e
                     where e.tenant_id = cma.current_tenant_id() and e.roster_week_id = w.id and e.valid_to is null), 0),
           coalesce(w.status = 'published'
                    and exists (select 1 from cma.roster_entry e
                                where e.tenant_id = cma.current_tenant_id() and e.roster_week_id = w.id
                                  and (e.recorded_at > w.published_at or e.valid_to > w.published_at)), false)
    from (select 1) one
    left join cma.team t on t.tenant_id = cma.current_tenant_id() and t.id = v_team
    left join cma.roster_week w on w.tenant_id = cma.current_tenant_id() and w.week_start = p_week_start
                               and w.team_id is not distinct from v_team
    left join cma.app_user pb on pb.tenant_id = cma.current_tenant_id() and pb.id = w.published_by;
end
$$;

create or replace function pg_temp.v0009zw_my_roster_0005(p_from date, p_to date)
returns table (business_date date, is_published boolean, kind text, start_time time, end_time time, absence_key text,
               absence_name text, note text, team_name text, published_at timestamptz)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_user uuid;
begin
  v_user := cma.assert_permission('roster.view');
  return query
    select d::date,
           exists (select 1 from cma.roster_week w
                   where w.tenant_id = cma.current_tenant_id() and w.status = 'published'
                     and w.week_start <= d::date and d::date < w.week_start + 7
                     and (w.team_id is null
                          or exists (select 1 from cma.team_member m
                                     where m.tenant_id = w.tenant_id and m.user_id = v_user and m.team_id = w.team_id
                                       and m.valid_from <= w.published_at and (m.valid_to is null or m.valid_to > w.published_at)))),
           x.kind::text, x.start_time, x.end_time, x.absence_key, x.absence_name, x.note::text, x.team_name, x.published_at
    from generate_series(p_from, p_to, interval '1 day') d
    left join lateral (
      select e.kind, e.start_time, e.end_time, a.key::text as absence_key, a.name::text as absence_name, e.note,
             t.name::text as team_name, e.published_at
      from cma.roster_published_entry e
      left join cma.absence_type a on a.tenant_id = e.tenant_id and a.id = e.absence_type_id
      left join cma.team t on t.tenant_id = e.tenant_id and t.id = e.team_id
      where e.user_id = v_user and e.business_date = d::date
      order by e.published_at desc
      limit 1
    ) x on true
    order by d;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- S. The objects
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_bad text := '';
  f     text;
  t     text;
  v_cols text;
begin
  -- S1
  perform pg_temp.v0009zw_row(1, 'S1', 'the addition 0009zw recorded once, after 0009zv',
    format('0009zv %s; 0009zw %s, after 0009zv %s',
           (select count(*) from cma.schema_migration where version = '0009zv'),
           (select count(*) from cma.schema_migration where version = '0009zw'),
           coalesce((select w.applied_at >= v.applied_at from cma.schema_migration w, cma.schema_migration v
                     where w.version = '0009zw' and v.version = '0009zv'), false)),
    '0009zv 1; 0009zw 1, after 0009zv t');

  -- S2
  foreach t in array array['assignment_type', 'roster_assignment', 'standard_week_entry', 'standard_week_assignment'] loop
    if to_regclass('cma.' || t) is null then v_bad := v_bad || t || ' missing; '; continue; end if;
    if not (select c.relrowsecurity from pg_class c where c.oid = ('cma.' || t)::regclass) then v_bad := v_bad || t || ' without RLS; '; end if;
    if not exists (select 1 from pg_policy p where p.polrelid = ('cma.' || t)::regclass and p.polname = 'tenant_app') then v_bad := v_bad || t || ' without the policy; '; end if;
    if not exists (select 1 from pg_trigger g where g.tgrelid = ('cma.' || t)::regclass and g.tgname = 'audit') then v_bad := v_bad || t || ' without audit; '; end if;
    if has_table_privilege('cma_app', 'cma.' || t, 'delete') then v_bad := v_bad || t || ' deletable; '; end if;
    if has_table_privilege('cma_readonly', 'cma.' || t, 'select') then v_bad := v_bad || t || ' read by the readers; '; end if;
    if to_regclass('cma_read.' || t) is null then v_bad := v_bad || t || ' without a cma_read face; '; end if;
    if pg_get_userbyid((select c.relowner from pg_class c where c.oid = ('cma.' || t)::regclass)) <> 'cma_owner' then v_bad := v_bad || t || ' owner; '; end if;
  end loop;
  foreach t in array array['roster_assignment', 'standard_week_entry', 'standard_week_assignment'] loop
    if has_column_privilege('cma_app', 'cma.' || t, 'start_time', 'update') or not has_column_privilege('cma_app', 'cma.' || t, 'valid_to', 'update') then
      v_bad := v_bad || t || ' updates beyond the versioning columns; ';
    end if;
  end loop;
  if has_column_privilege('cma_app', 'cma.assignment_type', 'code', 'update') then v_bad := v_bad || 'assignment_type.code updatable; '; end if;
  if (select count(*) from pg_constraint c where c.contype = 'x' and c.conname in ('roster_assignment_no_overlap', 'standard_week_assignment_no_overlap')) <> 2 then
    v_bad := v_bad || 'the exclusion constraints; ';
  end if;
  if not exists (select 1 from pg_extension where extname = 'btree_gist') then v_bad := v_bad || 'btree_gist; '; end if;
  if to_regclass('cma_read.roster_published_assignment') is null or to_regclass('cma.roster_published_assignment') is null
     or has_table_privilege('cma_app', 'cma.roster_published_assignment_all', 'select') then
    v_bad := v_bad || 'the published-block views; ';
  end if;
  select string_agg(a.attname, ',' order by a.attnum desc) into v_cols
  from (select a.attname, a.attnum from pg_attribute a where a.attrelid = 'cma_read.absence_type'::regclass and a.attnum > 0 and not a.attisdropped
        order by a.attnum desc limit 1) a;
  if v_cols is distinct from 'carries_over' then v_bad := v_bad || 'cma_read.absence_type ends with ' || coalesce(v_cols, 'nothing') || '; '; end if;
  if not exists (select 1 from pg_attribute a where a.attrelid = 'cma.absence_type'::regclass and a.attname = 'carries_over'
                 and a.attnotnull and a.atttypid = 'boolean'::regtype) then
    v_bad := v_bad || 'absence_type.carries_over; ';
  end if;
  perform pg_temp.v0009zw_row(2, 'S2', 'the tables: RLS, policy, audit, insert-only for the application, readers'' faces, the exclusion constraints, carries_over',
    coalesce(nullif(v_bad, ''), 'ok'), 'ok');

  -- S3
  v_bad := '';
  foreach f in array array['cma.roster_planner_zone()', 'cma.set_absence_carries_over(text,boolean)', 'cma.absence_types()',
                           'cma.assignment_types()', 'cma.upsert_assignment_type(text,text,text,text,boolean,integer,text)',
                           'cma.roster_put_assignments(uuid,uuid,date,jsonb,boolean)', 'cma.roster_assignments(date,text)',
                           'cma.roster_cell(date,text,uuid,date)', 'cma.roster_set_assignments(date,text,uuid,date,jsonb,boolean)',
                           'cma.roster_slot_coverage(date,text)', 'cma.roster_planned_hours(date,text)', 'cma.roster_week(date,text)',
                           'cma.roster_people(date,text)', 'cma.roster_set_entry(date,text,uuid,date,text,time,time,text,text)',
                           'cma.roster_copy_week_report(date,date,text)', 'cma.roster_copy_week(date,date,text)',
                           'cma.standard_week()', 'cma.save_standard_week(date,text)', 'cma.apply_standard_week(date,text)',
                           'cma.my_roster(date,date)', 'cma.roster_today()'] loop
    if to_regprocedure(f) is null then v_bad := v_bad || f || ' missing; '; continue; end if;
    if pg_get_userbyid((select p.proowner from pg_proc p where p.oid = to_regprocedure(f))) <> 'cma_owner' then v_bad := v_bad || f || ' owner; '; end if;
    if not has_function_privilege('cma_app', to_regprocedure(f), 'execute') then v_bad := v_bad || f || ' not the application''s; '; end if;
    if has_function_privilege('cma_readonly', to_regprocedure(f), 'execute') then v_bad := v_bad || f || ' the readers''; '; end if;
    if exists (select 1 from pg_proc p cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
               where p.oid = to_regprocedure(f) and a.grantee = 0) then v_bad := v_bad || f || ' public''s; '; end if;
    if (select p.prosecdef from pg_proc p where p.oid = to_regprocedure(f)) then v_bad := v_bad || f || ' security definer; '; end if;
    if f in ('cma.roster_planner_zone()', 'cma.absence_types()', 'cma.assignment_types()', 'cma.roster_assignments(date,text)',
             'cma.roster_cell(date,text,uuid,date)', 'cma.roster_slot_coverage(date,text)', 'cma.roster_planned_hours(date,text)',
             'cma.roster_week(date,text)', 'cma.roster_people(date,text)', 'cma.standard_week()', 'cma.my_roster(date,date)', 'cma.roster_today()')
       and (select p.provolatile from pg_proc p where p.oid = to_regprocedure(f)) <> 's' then
      v_bad := v_bad || f || ' not stable; ';
    end if;
  end loop;
  foreach f in array array['cma.my_roster(date,date)=assignments', 'cma.roster_today()=assignments',
                           'cma.roster_people(date,text)=default_hours_market_code', 'cma.absence_types()=carries_over'] loop
    select a.attname into v_cols
    from pg_proc p join lateral unnest(p.proargnames, p.proargmodes) with ordinality as a(attname, attmode, n) on true
    where p.oid = to_regprocedure(split_part(f, '=', 1)) and a.attmode = 't'
    order by a.n desc limit 1;
    if v_cols is distinct from split_part(f, '=', 2) then v_bad := v_bad || split_part(f, '=', 1) || ' ends with ' || coalesce(v_cols, 'nothing') || '; '; end if;
  end loop;
  if (select p.prosrc from pg_proc p where p.oid = to_regprocedure('cma.roster_today()')) !~ 'cma\.on_roster\(' then
    v_bad := v_bad || 'roster_today without cma.on_roster; ';
  end if;
  perform pg_temp.v0009zw_row(3, 'S3', 'the functions: the owner''s, the application''s, the caller''s rights, the reads stable, the new last columns',
    coalesce(nullif(v_bad, ''), 'ok'), 'ok');

  -- S4
  perform pg_temp.v0009zw_row(4, 'S4', 'the settings and the zone trigger on cma.tenant_setting',
    (select string_agg(s.key || '=' || s.default_value || coalesce(' [' || array_to_string(s.allowed_values, ',') || ']', ''), '; ' order by s.key collate "C")
     from cma.setting s where s.key in ('roster.slot_minutes', 'roster.lunch_after_minutes', 'roster.planner_timezone'))
    || '; zone trigger ' || exists (select 1 from pg_trigger g where g.tgrelid = 'cma.tenant_setting'::regclass and g.tgname = 'zone_ok'),
    'roster.lunch_after_minutes=360; roster.planner_timezone=; roster.slot_minutes=15 [5,10,15,20,30,60]; zone trigger true');
end
$$;

-- ---------------------------------------------------------------------------------------------
-- B. Behaviour on a throwaway tenant, always rolled back
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_today date := (now() at time zone 'UTC')::date;
  v_this  date := cma.week_start((now() at time zone 'UTC')::date);
  v_wk    date := cma.week_start((now() at time zone 'UTC')::date) + 7;
  v_t     uuid;
  v_adm uuid; v_mgr uuid; v_ana uuid; v_a1 uuid; v_a2 uuid;
  v_text  text;
  v_j     jsonb;
  v_b1 text; v_b2 text; v_b3 text; v_b4 text; v_b5 text; v_b6 text; v_b7 text; v_b8 text; v_b9 text; v_b10 text; v_b11 text;
  v_err   text;
  e       cma.roster_entry;
  w       cma.roster_week;
  -- the blocks a1 holds on v_wk at the start
  v_blocks jsonb := '[{"code":"SL","start":"09:00","end":"11:00","market":"GB"},{"code":"LB","start":"12:00","end":"12:30"},{"code":"GO","start":"13:00","end":"17:00"}]';
begin
  begin
    v_t := cma.create_tenant('verify-0009zw', 'Verify 0009zw', 'UTC');
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency) values
      (v_t, 'GB', 'Verify GB', 'Europe/London', 'en', 'GBP'),
      (v_t, 'NL', 'Verify NL', 'Europe/Amsterdam', 'nl', 'EUR'),
      (v_t, 'BE', 'Verify BE', 'Europe/Brussels', 'nl', 'EUR');
    update cma.market set hours_market_code = 'NL' where tenant_id = v_t and code = 'BE';
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'adm@example.invalid', 'adm') returning id into v_adm;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'mgr@example.invalid', 'mgr') returning id into v_mgr;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'ana@example.invalid', 'ana') returning id into v_ana;
    insert into cma.app_user (tenant_id, email, display_name, default_hours_market_code) values (v_t, 'a1@example.invalid', 'a1', 'NL') returning id into v_a1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'a2@example.invalid', 'a2') returning id into v_a2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t, x.uid, ar.id
    from (values (v_adm, 'admin'), (v_mgr, 'manager'), (v_ana, 'analytics'), (v_a1, 'agent'), (v_a2, 'agent')) as x(uid, role_key)
    join cma.app_role ar on ar.tenant_id = v_t and ar.key = x.role_key;
    insert into cma.team (tenant_id, key, name, markets, sort_order) values (v_t, 'alpha', 'Team Alpha', array['xa'], 10);
    insert into cma.team_member (tenant_id, user_id, team_id)
    select v_t, x.uid, t.id from (values (v_a1), (v_a2)) as x(uid) join cma.team t on t.tenant_id = v_t and t.key = 'alpha';
    insert into cma.work_status (tenant_id, key, name, is_working, is_productive, is_paid, is_billable, is_default, sort_order, work_area) values
      (v_t, 'v_sales', 'Verify sales', true, true, true, true, false, 11, 'sales'),
      (v_t, 'v_ops', 'Verify operations', true, true, true, true, false, 12, 'operations');

    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('role', 'cma_app', true);

    -- B1: the type catalog
    perform set_config('app.user_id', v_adm::text, true);
    perform cma.upsert_assignment_type('SL', 'Sales', 'work', 'v_sales', false, 10);
    perform cma.upsert_assignment_type('GO', 'General Ops', 'work', 'v_ops', false, 20);
    perform cma.upsert_assignment_type('LB', 'Lunch break', 'pause', 'lunch', false, 90);
    perform cma.upsert_assignment_type('X', 'Extra hours', 'work', null, true, 99);
    perform cma.upsert_assignment_type('OLD', 'Retired', 'work', 'v_ops', false, 95, 'inactive');
    v_b1 := format('lower %s; work on lunch %s; extra with a status %s; ',
      pg_temp.v0009zw_try($q$select cma.upsert_assignment_type('sl', 'Sales', 'work', 'v_sales')$q$),
      pg_temp.v0009zw_try($q$select cma.upsert_assignment_type('WL', 'Work on lunch', 'work', 'lunch')$q$),
      pg_temp.v0009zw_try($q$select cma.upsert_assignment_type('XX', 'Extra', 'work', 'v_sales', true)$q$));
    perform set_config('app.user_id', v_mgr::text, true);
    v_b1 := v_b1 || format('manager %s; ', pg_temp.v0009zw_try($q$select cma.upsert_assignment_type('MG', 'Manager''s', 'work', 'v_sales')$q$));
    perform set_config('app.user_id', v_a1::text, true);
    select v_b1 || 'agent reads ' || string_agg(x.code || ':' || x.kind || ':' || coalesce(x.status_key, '-') || ':' || coalesce(x.work_area, '-') || ':' || x.is_extra || ':' || x.status, ', '
                                                 order by x.sort_order, x.code collate "C")
    into v_b1 from cma.assignment_types() x;

    -- the planner's week: shifts on v_wk for a1 (09:00 to 17:00) and a2 (08:00 to 16:00)
    perform set_config('app.user_id', v_mgr::text, true);
    e := cma.roster_set_entry(v_wk, 'alpha', v_a1, v_wk, 'shift', '09:00', '17:00', null, null);
    e := cma.roster_set_entry(v_wk, 'alpha', v_a2, v_wk, 'shift', '08:00', '16:00', null, null);

    -- B2: refusals
    v_b2 := format('overlap %s; off grid %s; outside %s; no shift %s; BE %s; UK %s; unknown type %s; retired type %s; past %s; analyst %s',
      pg_temp.v0009zw_try(format($q$select cma.roster_set_assignments(%L, 'alpha', %L, %L, '[{"code":"SL","start":"09:00","end":"11:00"},{"code":"GO","start":"10:45","end":"12:00"}]')$q$, v_wk, v_a1, v_wk)),
      pg_temp.v0009zw_try(format($q$select cma.roster_set_assignments(%L, 'alpha', %L, %L, '[{"code":"SL","start":"09:05","end":"10:00"}]')$q$, v_wk, v_a1, v_wk)),
      pg_temp.v0009zw_try(format($q$select cma.roster_set_assignments(%L, 'alpha', %L, %L, '[{"code":"SL","start":"08:00","end":"10:00"}]')$q$, v_wk, v_a1, v_wk)),
      pg_temp.v0009zw_try(format($q$select cma.roster_set_assignments(%L, 'alpha', %L, %L, '[{"code":"SL","start":"09:00","end":"10:00"}]')$q$, v_wk, v_a1, v_wk + 1)),
      pg_temp.v0009zw_try(format($q$select cma.roster_set_assignments(%L, 'alpha', %L, %L, '[{"code":"SL","start":"09:00","end":"10:00","market":"BE"}]')$q$, v_wk, v_a1, v_wk)),
      pg_temp.v0009zw_try(format($q$select cma.roster_set_assignments(%L, 'alpha', %L, %L, '[{"code":"SL","start":"09:00","end":"10:00","market":"UK"}]')$q$, v_wk, v_a1, v_wk)),
      pg_temp.v0009zw_try(format($q$select cma.roster_set_assignments(%L, 'alpha', %L, %L, '[{"code":"ZZ","start":"09:00","end":"10:00"}]')$q$, v_wk, v_a1, v_wk)),
      pg_temp.v0009zw_try(format($q$select cma.roster_set_assignments(%L, 'alpha', %L, %L, '[{"code":"OLD","start":"09:00","end":"10:00"}]')$q$, v_wk, v_a1, v_wk)),
      pg_temp.v0009zw_try(format($q$select cma.roster_set_assignments(%L, 'alpha', %L, %L, '[]')$q$, v_this - 7, v_a1, v_this - 7)),
      pg_temp.v0009zw_try(format($q$select cma.roster_set_assignments(%L, null, %L, %L, '[]')$q$, v_wk, v_ana, v_wk)));
    perform set_config('app.user_id', v_a1::text, true);
    v_b2 := v_b2 || format('; agent %s', pg_temp.v0009zw_try(format($q$select cma.roster_set_assignments(%L, 'alpha', %L, %L, '[]')$q$, v_wk, v_a1, v_wk)));
    perform set_config('app.user_id', v_mgr::text, true);
    v_j := cma.roster_set_assignments(v_wk, 'alpha', v_a1, v_wk, v_blocks);
    v_b2 := v_b2 || format('; written %s/%s/%s published %s', v_j->>'kept', v_j->>'ended', v_j->>'added', v_j->>'published');
    -- the table on its own, as the owner (no function in between)
    perform set_config('role', 'cma_owner', true);
    v_b2 := v_b2 || format('; table: overlap %s, off grid %s, BE %s, UK %s',
      pg_temp.v0009zw_try(format($q$insert into cma.roster_assignment (tenant_id, roster_week_id, user_id, business_date, assignment_type_id, start_time, end_time)
                                    select %L, e.roster_week_id, %L, %L, t.id, '10:00', '10:30' from cma.roster_entry e, cma.assignment_type t
                                    where e.tenant_id = %L and e.user_id = %L and e.business_date = %L and e.valid_to is null and t.tenant_id = %L and t.code = 'GO'$q$,
                                 v_t, v_a1, v_wk, v_t, v_a1, v_wk, v_t)),
      pg_temp.v0009zw_try(format($q$insert into cma.roster_assignment (tenant_id, roster_week_id, user_id, business_date, assignment_type_id, start_time, end_time)
                                    select %L, e.roster_week_id, %L, %L, t.id, '11:10', '11:30' from cma.roster_entry e, cma.assignment_type t
                                    where e.tenant_id = %L and e.user_id = %L and e.business_date = %L and e.valid_to is null and t.tenant_id = %L and t.code = 'GO'$q$,
                                 v_t, v_a1, v_wk, v_t, v_a1, v_wk, v_t)),
      pg_temp.v0009zw_try(format($q$insert into cma.roster_assignment (tenant_id, roster_week_id, user_id, business_date, assignment_type_id, start_time, end_time, hours_market_code)
                                    select %L, e.roster_week_id, %L, %L, t.id, '11:00', '11:30', 'BE' from cma.roster_entry e, cma.assignment_type t
                                    where e.tenant_id = %L and e.user_id = %L and e.business_date = %L and e.valid_to is null and t.tenant_id = %L and t.code = 'GO'$q$,
                                 v_t, v_a1, v_wk, v_t, v_a1, v_wk, v_t)),
      pg_temp.v0009zw_try(format($q$insert into cma.roster_assignment (tenant_id, roster_week_id, user_id, business_date, assignment_type_id, start_time, end_time, hours_market_code)
                                    select %L, e.roster_week_id, %L, %L, t.id, '11:00', '11:30', 'UK' from cma.roster_entry e, cma.assignment_type t
                                    where e.tenant_id = %L and e.user_id = %L and e.business_date = %L and e.valid_to is null and t.tenant_id = %L and t.code = 'GO'$q$,
                                 v_t, v_a1, v_wk, v_t, v_a1, v_wk, v_t)));
    perform set_config('role', 'cma_app', true);

    -- B3: versioning: GO 13:00-17:00 becomes 13:00-16:00; SL and LB are kept
    v_j := cma.roster_set_assignments(v_wk, 'alpha', v_a1, v_wk,
      '[{"code":"SL","start":"09:00","end":"11:00","market":"GB"},{"code":"LB","start":"12:00","end":"12:30"},{"code":"GO","start":"13:00","end":"16:00"}]');
    perform set_config('role', 'cma_owner', true);
    select format('kept %s ended %s added %s; rows %s, current %s; the ended GO 13:00-17:00 superseded by GO %s; current %s',
                  v_j->>'kept', v_j->>'ended', v_j->>'added',
                  (select count(*) from cma.roster_assignment a where a.tenant_id = v_t and a.user_id = v_a1 and a.business_date = v_wk),
                  (select count(*) from cma.roster_assignment a where a.tenant_id = v_t and a.user_id = v_a1 and a.business_date = v_wk and a.valid_to is null),
                  (select to_char(n.start_time, 'HH24:MI') || '-' || to_char(n.end_time, 'HH24:MI')
                   from cma.roster_assignment o join cma.roster_assignment n on n.tenant_id = o.tenant_id and n.id = o.superseded_by
                   where o.tenant_id = v_t and o.user_id = v_a1 and o.business_date = v_wk and o.valid_to is not null),
                  (select string_agg(x->>'code' || ' ' || (x->>'start') || '-' || (x->>'end') || coalesce(' ' || (x->>'hoursMarket'), ''), ', ')
                   from jsonb_array_elements(v_j->'blocks') x))
    into v_b3;
    perform set_config('role', 'cma_app', true);

    -- B4: the published read
    perform set_config('app.user_id', v_a1::text, true);
    select 'before ' || coalesce(jsonb_array_length(m.assignments)::text, 'null') into v_b4 from cma.my_roster(v_wk, v_wk) m;
    perform set_config('app.user_id', v_mgr::text, true);
    w := cma.roster_publish(v_wk, 'alpha');
    v_j := cma.roster_set_assignments(v_wk, 'alpha', v_a1, v_wk,
      '[{"code":"SL","start":"09:00","end":"11:00","market":"GB"},{"code":"LB","start":"12:00","end":"12:30"},{"code":"GO","start":"13:00","end":"15:00"}]');
    select v_b4 || format('; future change published %s; changed since publish %s', v_j->>'published', r.changed_since_publish)
    into v_b4 from cma.roster_week(v_wk, 'alpha') r;
    select v_b4 || '; planner ' || string_agg(a.code || ' ' || to_char(a.start_time, 'HH24:MI') || '-' || to_char(a.end_time, 'HH24:MI'), ', ' order by a.start_time)
    into v_b4 from cma.roster_assignments(v_wk, 'alpha') a where a.user_id = v_a1;
    perform set_config('app.user_id', v_a1::text, true);
    select v_b4 || '; agent ' || string_agg(x->>'code' || ' ' || (x->>'start') || '-' || (x->>'end') || ' ' || (x->>'kind') || ' ' || coalesce(x->>'workArea', '-')
                                              || ' ' || coalesce(x->>'hoursMarket', '-') || ' ' || (x->>'ownMarket') || ' ' || coalesce(x->>'hoursMarketZone', '-'), ', ')
    into v_b4 from cma.my_roster(v_wk, v_wk) m cross join lateral jsonb_array_elements(m.assignments) x;
    perform set_config('app.user_id', v_mgr::text, true);
    w := cma.roster_publish(v_wk, 'alpha');
    perform set_config('app.user_id', v_a1::text, true);
    select v_b4 || '; after the second publication GO ' || (x->>'start') || '-' || (x->>'end')
    into v_b4 from cma.my_roster(v_wk, v_wk) m cross join lateral jsonb_array_elements(m.assignments) x where x->>'code' = 'GO';

    -- B5: the shift shortened to 09:00-12:00 ends LB (to 12:30) and GO; an absence ends SL
    perform set_config('app.user_id', v_mgr::text, true);
    e := cma.roster_set_entry(v_wk, 'alpha', v_a1, v_wk, 'shift', '09:00', '12:00', null, null);
    select format('shortened: cell %s %s-%s, blocks %s, ended %s', c.kind, to_char(c.start_time, 'HH24:MI'), to_char(c.end_time, 'HH24:MI'),
                  (select string_agg(x->>'code', ',') from jsonb_array_elements(c.assignments) x), c.ended_assignments)
    into v_b5 from cma.roster_cell(v_wk, 'alpha', v_a1, v_wk) c;
    perform set_config('role', 'cma_owner', true);
    select v_b5 || format('; without a successor %s', count(*))
    into v_b5 from cma.roster_assignment a
    where a.tenant_id = v_t and a.user_id = v_a1 and a.business_date = v_wk and a.valid_to is not null and a.superseded_by is null
      and a.valid_to >= now();
    perform set_config('role', 'cma_app', true);
    e := cma.roster_set_entry(v_wk, 'alpha', v_a1, v_wk, 'absence', null, null, 'leave', null);
    select v_b5 || format('; absence: blocks %s', jsonb_array_length(c.assignments))
    into v_b5 from cma.roster_cell(v_wk, 'alpha', v_a1, v_wk) c;

    -- B6: D8 on today (this week): a1 and a2 work today all day; the week is published
    e := cma.roster_set_entry(v_this, 'alpha', v_a1, v_today, 'shift', '00:00', '24:00', null, null);
    e := cma.roster_set_entry(v_this, 'alpha', v_a2, v_today, 'shift', '00:00', '24:00', null, null);
    w := cma.roster_publish(v_this, 'alpha');
    v_j := cma.roster_set_assignments(v_this, 'alpha', v_a2, v_today, '[{"code":"SL","start":"10:00","end":"11:00"}]');
    v_b6 := format('a2 today: published %s version %s', v_j->>'published', v_j->>'version');
    e := cma.roster_set_entry(v_this, 'alpha', v_a1, v_today, 'shift', '00:00', '23:00', null, null);
    begin
      perform cma.roster_set_assignments(v_this, 'alpha', v_a2, v_today, '[{"code":"SL","start":"10:00","end":"12:00"}]');
      v_b6 := v_b6 || '; with another change waiting: accepted';
    exception when sqlstate 'CMA03' then
      get stacked diagnostics v_text = pg_exception_detail;
      v_b6 := v_b6 || '; with another change waiting: CMA03 ' || v_text;
    end;
    select v_b6 || '; a2 still ' || string_agg((x->>'start') || '-' || (x->>'end'), ',')
    into v_b6 from cma.roster_cell(v_this, 'alpha', v_a2, v_today) c cross join lateral jsonb_array_elements(c.assignments) x;
    v_j := cma.roster_set_assignments(v_this, 'alpha', v_a2, v_today, '[{"code":"SL","start":"10:00","end":"12:00"}]', true);
    v_b6 := v_b6 || format('; confirmed: published %s version %s', v_j->>'published', v_j->>'version');
    perform set_config('app.user_id', v_a1::text, true);
    select v_b6 || '; a1 sees ' || to_char(m.end_time, 'HH24:MI') into v_b6 from cma.my_roster(v_today, v_today) m;
    perform set_config('app.user_id', v_mgr::text, true);

    -- B7: Copy week. Source v_wk: a1 Monday leave (does not carry over), Tuesday off (carries over), Wednesday sick (does
    -- not); a2 Monday 08:00-16:00 with GO 08-12, LB 12-13 and SL 13-16 under GB
    perform set_config('app.user_id', v_adm::text, true);
    perform cma.set_absence_carries_over('off', true);
    perform set_config('app.user_id', v_mgr::text, true);
    e := cma.roster_set_entry(v_wk, 'alpha', v_a1, v_wk + 1, 'absence', null, null, 'off', null);
    e := cma.roster_set_entry(v_wk, 'alpha', v_a1, v_wk + 2, 'absence', null, null, 'sick', null);
    v_j := cma.roster_set_assignments(v_wk, 'alpha', v_a2, v_wk,
      '[{"code":"GO","start":"08:00","end":"12:00"},{"code":"LB","start":"12:00","end":"13:00"},{"code":"SL","start":"13:00","end":"16:00","market":"GB"}]');
    select string_agg(u.display_name || ' ' || (r.business_date - v_wk - 7) || ' ' || r.outcome || coalesce(' ' || r.reason, '') || ' ' || r.blocks, '; '
                      order by u.display_name collate "C", r.business_date)
    into v_b7 from cma.roster_copy_week_report(v_wk, v_wk + 7, 'alpha') r join cma.app_user u on u.tenant_id = v_t and u.id = r.user_id;
    select v_b7 || ' | target ' || string_agg(a.code || ' ' || to_char(a.start_time, 'HH24:MI') || '-' || to_char(a.end_time, 'HH24:MI') || coalesce(' ' || a.hours_market_code, ''), ', ' order by a.start_time)
    into v_b7 from cma.roster_assignments(v_wk + 7, 'alpha') a where a.user_id = v_a2;
    select v_b7 || ' | entries ' || string_agg((x.business_date - v_wk - 7) || ' ' || x.kind || coalesce(' ' || x.absence_key, ''), ', ' order by x.business_date, x.kind collate "C")
    into v_b7 from cma.roster_entries(v_wk + 7, 'alpha') x;
    v_b7 := v_b7 || ' | copy_week again ' || cma.roster_copy_week(v_wk, v_wk + 7, 'alpha');

    -- B8: the Standard week. Save from v_wk; pre-fill a2's Monday of v_wk + 14 with 10:00-14:00; apply; apply again
    select string_agg(u.display_name || ' ' || extract(isodow from r.business_date) || ' ' || r.outcome || coalesce(' ' || r.reason, '') || ' ' || r.blocks, '; '
                      order by u.display_name collate "C", r.business_date)
    into v_b8 from cma.save_standard_week(v_wk, 'alpha') r join cma.app_user u on u.tenant_id = v_t and u.id = r.user_id;
    select v_b8 || ' | standard ' || string_agg(u.display_name || ' ' || s.iso_weekday || ' ' || s.kind || coalesce(' ' || s.absence_key, '')
                                                 || coalesce(' ' || to_char(s.start_time, 'HH24:MI') || '-' || to_char(s.end_time, 'HH24:MI'), '')
                                                 || ' ' || jsonb_array_length(s.assignments), ', ' order by u.display_name collate "C", s.iso_weekday)
    into v_b8 from cma.standard_week() s join cma.app_user u on u.tenant_id = v_t and u.id = s.user_id;
    e := cma.roster_set_entry(v_wk + 14, 'alpha', v_a2, v_wk + 14, 'shift', '10:00', '14:00', null, null);
    select v_b8 || ' | apply ' || string_agg(u.display_name || ' ' || (r.business_date - v_wk - 14) || ' ' || r.outcome || coalesce(' ' || r.reason, '') || ' ' || r.blocks, '; '
                                              order by u.display_name collate "C", r.business_date)
    into v_b8 from cma.apply_standard_week(v_wk + 14, 'alpha') r join cma.app_user u on u.tenant_id = v_t and u.id = r.user_id;
    select v_b8 || ' | a2 kept ' || to_char(x.start_time, 'HH24:MI') || '-' || to_char(x.end_time, 'HH24:MI')
    into v_b8 from cma.roster_entries(v_wk + 14, 'alpha') x where x.user_id = v_a2;
    select v_b8 || ' | again ' || string_agg(r.outcome || coalesce(' ' || r.reason, ''), ', ' order by r.business_date, r.user_id)
    into v_b8 from cma.apply_standard_week(v_wk + 14, 'alpha') r;
    -- a second save from v_wk + 7 (a2's Monday as copied, a1's Tuesday off): the earlier rows stay, ended
    perform cma.save_standard_week(v_wk + 7, 'alpha');
    perform set_config('role', 'cma_owner', true);
    select v_b8 || format(' | after a second save: current %s, ended %s, ended blocks %s',
                            count(*) filter (where e2.valid_to is null), count(*) filter (where e2.valid_to is not null),
                            (select count(*) from cma.standard_week_assignment x where x.tenant_id = v_t and x.valid_to is not null))
    into v_b8 from cma.standard_week_entry e2 where e2.tenant_id = v_t;
    perform set_config('role', 'cma_app', true);

    -- B9: settings
    perform set_config('app.user_id', v_adm::text, true);
    v_b9 := format('zone Mars/Base %s; slot 7 %s',
      pg_temp.v0009zw_try($q$select cma.set_tenant_setting('roster.planner_timezone', 'Mars/Base')$q$),
      pg_temp.v0009zw_try($q$select cma.set_tenant_setting('roster.slot_minutes', '7')$q$));
    perform cma.set_tenant_setting('roster.slot_minutes', '30');
    perform set_config('app.user_id', v_mgr::text, true);
    v_b9 := v_b9 || format('; 08:15 on a 30-minute grid %s',
      pg_temp.v0009zw_try(format($q$select cma.roster_set_assignments(%L, 'alpha', %L, %L, '[{"code":"GO","start":"08:15","end":"10:00"}]')$q$, v_wk, v_a2, v_wk)));
    perform set_config('app.user_id', v_adm::text, true);
    perform cma.set_tenant_setting('roster.slot_minutes', null);
    perform cma.set_tenant_setting('roster.planner_timezone', 'Africa/Lagos');   -- UTC + 1 all year: B10 holds on any run date
    v_b9 := v_b9 || '; planner zone ' || cma.roster_planner_zone();

    -- B10: coverage and planned hours on v_wk + 7: a2 as copied (GO 08-12 own market, none; LB 12-13; SL 13-16 GB), a1
    -- 09:00-17:00 with SL 09-13 (own: NL), X 13-14 and SL 14-17 under GB
    perform set_config('app.user_id', v_mgr::text, true);
    e := cma.roster_set_entry(v_wk + 7, 'alpha', v_a1, v_wk + 7, 'shift', '09:00', '17:00', null, null);
    v_j := cma.roster_set_assignments(v_wk + 7, 'alpha', v_a1, v_wk + 7,
      '[{"code":"SL","start":"09:00","end":"13:00"},{"code":"X","start":"13:00","end":"14:00"},{"code":"SL","start":"14:00","end":"17:00","market":"GB"}]');
    select string_agg(to_char(c.slot_time, 'HH24:MI') || ' w' || c.working || ' ' || c.code || '/' || coalesce(c.hours_market_code, '-') || '=' || c.people, ', '
                      order by c.slot_start, c.code collate "C", c.hours_market_code collate "C")
    into v_b10 from cma.roster_slot_coverage(v_wk + 7, 'alpha') c
    where to_char(c.slot_time, 'HH24:MI') in ('09:00', '10:00', '13:00', '14:00', '17:45');
    select v_b10 || format(' | slots %s, first %s, last %s', count(distinct c.slot_start), to_char(min(c.slot_time), 'HH24:MI'), to_char(max(c.slot_time), 'HH24:MI'))
    into v_b10 from cma.roster_slot_coverage(v_wk + 7, 'alpha') c;
    select v_b10 || ' | planned ' || string_agg(u.display_name || ' ' || p.code || '/' || coalesce(p.hours_market_code, '-') || '=' || p.planned_minutes, ', '
                                                 order by u.display_name collate "C", p.code collate "C", p.hours_market_code collate "C")
    into v_b10 from cma.roster_planned_hours(v_wk + 7, 'alpha') p join cma.app_user u on u.tenant_id = v_t and u.id = p.user_id;

    -- B11: an agent reads none of the planner's functions
    perform set_config('app.user_id', v_a1::text, true);
    v_b11 := format('assignments %s; coverage %s; planned %s; cell %s; standard %s; save %s; apply %s; copy %s',
      pg_temp.v0009zw_try(format($q$select count(*) from cma.roster_assignments(%L, 'alpha')$q$, v_wk)),
      pg_temp.v0009zw_try(format($q$select count(*) from cma.roster_slot_coverage(%L, 'alpha')$q$, v_wk)),
      pg_temp.v0009zw_try(format($q$select count(*) from cma.roster_planned_hours(%L, 'alpha')$q$, v_wk)),
      pg_temp.v0009zw_try(format($q$select count(*) from cma.roster_cell(%L, 'alpha', %L, %L)$q$, v_wk, v_a1, v_wk)),
      pg_temp.v0009zw_try($q$select count(*) from cma.standard_week()$q$),
      pg_temp.v0009zw_try(format($q$select count(*) from cma.save_standard_week(%L, 'alpha')$q$, v_wk)),
      pg_temp.v0009zw_try(format($q$select count(*) from cma.apply_standard_week(%L, 'alpha')$q$, v_wk)),
      pg_temp.v0009zw_try(format($q$select count(*) from cma.roster_copy_week_report(%L, %L, 'alpha')$q$, v_wk, v_wk + 7)));

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then v_err := sqlstate || ': ' || left(sqlerrm, 300);
      perform set_config('role', 'cma_owner', true);
      insert into pg_temp.verify_0009zw values (10, 'B the throwaway tenant''s checks ran to their end', 'FAIL', v_err);
  end;
  perform set_config('role', 'cma_owner', true);
  perform set_config('app.tenant_id', '', true);
  perform set_config('app.user_id', '', true);

  perform pg_temp.v0009zw_row(11, 'B1', 'the type catalog: the refusals, the agent reads it with its status and work area',
    v_b1, 'lower CMA04; work on lunch CMA04; extra with a status CMA04; manager CMA06; agent reads SL:work:v_sales:sales:false:active, GO:work:v_ops:operations:false:active, LB:pause:lunch:-:false:active, OLD:work:v_ops:operations:false:inactive, X:work:-:-:true:active');
  perform pg_temp.v0009zw_row(12, 'B2', 'roster_set_assignments'' refusals, the table''s own, and the first write',
    v_b2, 'overlap CMA04; off grid CMA04; outside CMA04; no shift CMA04; BE CMA04; UK CMA02; unknown type CMA02; retired type CMA04; past CMA04; analyst CMA04; agent CMA06; written 0/0/3 published false; table: overlap 23P01, off grid CMA04, BE CMA04, UK CMA04');
  perform pg_temp.v0009zw_row(13, 'B3', 'versioning: the equal blocks kept, the changed one ended with its successor',
    v_b3, 'kept 2 ended 1 added 1; rows 4, current 3; the ended GO 13:00-17:00 superseded by GO 13:00-16:00; current SL 09:00-11:00 GB, LB 12:00-12:30, GO 13:00-16:00');
  perform pg_temp.v0009zw_row(14, 'B4', 'the published read: nothing before, the publication while a change waits, then the change',
    v_b4, 'before 0; future change published false; changed since publish t; planner SL 09:00-11:00, LB 12:00-12:30, GO 13:00-15:00; agent SL 09:00-11:00 work sales GB false Europe/London, LB 12:00-12:30 pause - NL true Europe/Amsterdam, GO 13:00-16:00 work operations NL true Europe/Amsterdam; after the second publication GO 13:00-15:00');
  perform pg_temp.v0009zw_row(15, 'B5', 'a shortened shift ends the blocks outside it (reported), an absence ends the rest',
    v_b5, 'shortened: cell shift 09:00-12:00, blocks SL, ended 2; without a successor 2; absence: blocks 0');
  perform pg_temp.v0009zw_row(16, 'B6', 'D8: today publishes at once; another change waiting asks first and writes nothing; confirmed it publishes both',
    v_b6, 'a2 today: published true version 2; with another change waiting: CMA03 publish_others=1; a2 still 10:00-11:00; confirmed: published true version 3; a1 sees 23:00');
  perform pg_temp.v0009zw_row(17, 'B7', 'Copy week: the blocks with the shift, an absence only when it carries over, the report',
    v_b7, 'a1 0 skipped absence_not_carried 0; a1 1 done 0; a1 2 skipped absence_not_carried 0; a2 0 done 3 | target GO 08:00-12:00, LB 12:00-13:00, SL 13:00-16:00 GB | entries 0 shift, 1 absence off | copy_week again 2');
  perform pg_temp.v0009zw_row(18, 'B8', 'the Standard week: save''s report, apply fills empty person-dates only, a second save keeps the replaced rows',
    v_b8, 'a1 1 skipped absence_not_carried 0; a1 2 done 0; a1 3 skipped absence_not_carried 0; a2 1 done 3 | standard a1 2 absence off 0, a2 1 shift 08:00-16:00 3 | apply a1 1 done 0; a2 0 skipped not_empty 0 | a2 kept 10:00-14:00 | again skipped not_empty, skipped not_empty | after a second save: current 2, ended 2, ended blocks 3');
  perform pg_temp.v0009zw_row(19, 'B9', 'the settings refuse a name that is no zone and a grid of 7; a 30-minute grid refuses 08:15',
    v_b9, 'zone Mars/Base CMA04; slot 7 CMA04; 08:15 on a 30-minute grid CMA04; planner zone Africa/Lagos');
  perform pg_temp.v0009zw_row(20, 'B10', 'D12: coverage per slot of the planner zone''s day and the planned minutes per type and market',
    v_b10, '09:00 w1 GO/-=1, 10:00 w2 GO/-=1, 10:00 w2 SL/NL=1, 13:00 w1 LB/-=1, 13:00 w1 SL/NL=1, 14:00 w2 SL/GB=1, 14:00 w2 X/NL=1, 17:45 w1 SL/GB=1 | slots 36, first 09:00, last 17:45 | planned a1 SL/GB=180, a1 SL/NL=240, a1 X/NL=60, a2 GO/-=240, a2 LB/-=60, a2 SL/GB=180');
  perform pg_temp.v0009zw_row(21, 'B11', 'an agent reads none of the planner''s functions',
    v_b11, 'assignments CMA06; coverage CMA06; planned CMA06; cell CMA06; standard CMA06; save CMA06; apply CMA06; copy CMA06');
end
$$;

-- ---------------------------------------------------------------------------------------------
-- R. Every active tenant as it is: the re-created reads against 0005's
-- ---------------------------------------------------------------------------------------------
do $$
declare
  t         record;
  v_this    date := cma.week_start((now() at time zone 'UTC')::date);
  v_planner uuid;
  v_viewer  uuid;
  v_conf    uuid;
  wk        date;
  tk        text;
  v_r1 text; v_r2 text; v_r3 text;
  v_n1 integer; v_n2 integer; v_n3 integer;
  v_o1 integer := case when pg_temp.v0009zw_p('R1') then 1 else 0 end;
  v_o2 integer := case when pg_temp.v0009zw_p('R2') then 1 else 0 end;
  v_o3 integer := case when pg_temp.v0009zw_p('R3') then 1 else 0 end;
  v_any boolean := false;
  v_err text;
begin
  for t in select x.id, x.slug from cma.tenant x where x.status = 'active' order by x.slug collate "C" loop
    v_any := true;
    v_r1 := ''; v_r2 := ''; v_r3 := ''; v_n1 := 0; v_n2 := 0; v_n3 := 0; v_err := null;
    perform set_config('app.tenant_id', t.id::text, true);   -- cma.has_permission reads the current tenant
    select u.id into v_planner from cma.app_user u
    where u.tenant_id = t.id and u.status = 'active' and u.kind = 'person' and cma.has_permission(u.id, 'roster.manage')
    order by u.created_at, u.id limit 1;
    select u.id into v_viewer from cma.app_user u
    where u.tenant_id = t.id and u.status = 'active' and u.kind = 'person' and cma.has_permission(u.id, 'roster.view')
    order by u.created_at, u.id limit 1;
    begin
      perform set_config('app.tenant_id', t.id::text, true);
      perform set_config('role', 'cma_app', true);
      if v_planner is not null then
        perform set_config('app.user_id', v_planner::text, true);
        foreach wk in array array[v_this, v_this + 7] loop
          for tk in select null::text union all select x.key::text from cma.team x where x.tenant_id = t.id and x.valid_to is null loop
            v_n1 := v_n1 + 1;
            -- R1: equal but for changed_since_publish where a block changed after the publication (provoked: 0005's side
            -- loses its row)
            if exists ((select n.week_id, n.team_key, n.team_name, n.week_start, n.status, n.version, n.published_at, n.published_by_name, n.entry_count
                        from cma.roster_week(wk, tk) n)
                       except all
                       (select o.week_id, o.team_key, o.team_name, o.week_start, o.status, o.version, o.published_at, o.published_by_name, o.entry_count
                        from pg_temp.v0009zw_week_0005(wk, tk) o offset v_o1))
               or exists (select 1 from cma.roster_week(wk, tk) n, pg_temp.v0009zw_week_0005(wk, tk) o
                          where n.changed_since_publish <> o.changed_since_publish
                            and not (n.changed_since_publish and exists (
                              select 1 from cma.roster_assignment a join cma.roster_week w on w.tenant_id = a.tenant_id and w.id = a.roster_week_id
                              where a.tenant_id = t.id and a.roster_week_id = n.week_id
                                and (a.recorded_at > w.published_at or a.valid_to > w.published_at)))) then
              v_r1 := v_r1 || wk || '/' || coalesce(tk, 'tenant') || ' ';
            end if;
          end loop;
        end loop;
        -- R3: the absence catalog's earlier columns
        select count(*) into v_n3 from cma.absence_types();
        v_r3 := case when exists ((select a.key, a.name, a.is_paid, a.sort_order, a.status from cma.absence_types() a)
                                  except all
                                  (select a.key::text, a.name::text, a.is_paid, a.sort_order, a.status::text from cma.absence_type a
                                   where a.tenant_id = t.id order by a.sort_order, a.key offset v_o3))
                       then 'differs' else 'equal' end;
      end if;
      if v_viewer is not null then
        -- R2: my_roster's earlier columns, this week and next, for the first person holding roster.view
        perform set_config('app.user_id', v_viewer::text, true);
        select count(*) into v_n2 from cma.my_roster(v_this, v_this + 13);
        v_r2 := case when exists ((select m.business_date, m.is_published, m.kind, m.start_time, m.end_time, m.absence_key, m.absence_name, m.note, m.team_name, m.published_at
                                   from cma.my_roster(v_this, v_this + 13) m)
                                  except all
                                  (select * from pg_temp.v0009zw_my_roster_0005(v_this, v_this + 13) offset v_o2))
                       then 'differs' else 'equal' end;
      end if;
    exception when others then
      v_err := sqlstate || ': ' || left(sqlerrm, 300);
    end;
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.tenant_id', '', true);
    perform set_config('app.user_id', '', true);
    if v_err is not null then
      insert into pg_temp.verify_0009zw values (30, 'R1 to R3 ' || t.slug || ': the checks ran to their end', 'FAIL', v_err);
      continue;
    end if;
    if v_planner is null then
      insert into pg_temp.verify_0009zw values (31, 'R1 and R3 ' || t.slug,
        case when pg_temp.v0009zw_p('R1') or pg_temp.v0009zw_p('R3') then 'FAIL' else 'skip' end, 'no active person holds roster.manage');
    else
      insert into pg_temp.verify_0009zw values (31, 'R1 ' || t.slug || ': roster_week = 0005''s, but where a block changed after the publication',
        case when btrim(v_r1) <> '' or v_o1 = 1 then 'FAIL' else 'PASS' end,
        format('weeks compared %s; differing %s', v_n1, coalesce(nullif(btrim(v_r1), ''), 'none')));
      insert into pg_temp.verify_0009zw values (33, 'R3 ' || t.slug || ': absence_types'' earlier columns = the table''s',
        case when v_r3 <> 'equal' or (v_o3 = 1 and v_n3 = 0) then 'FAIL' else 'PASS' end, format('rows %s; %s', v_n3, v_r3));
    end if;
    if v_viewer is null then
      insert into pg_temp.verify_0009zw values (32, 'R2 ' || t.slug,
        case when pg_temp.v0009zw_p('R2') then 'FAIL' else 'skip' end, 'no active person holds roster.view');
    else
      insert into pg_temp.verify_0009zw values (32, 'R2 ' || t.slug || ': my_roster''s earlier columns = 0005''s (this week and next)',
        case when v_r2 <> 'equal' or (v_o2 = 1 and v_n2 = 0) then 'FAIL' else 'PASS' end, format('rows %s; %s', v_n2, v_r2));
    end if;
  end loop;
  if not v_any then
    insert into pg_temp.verify_0009zw values (30, 'R1 to R3 per tenant',
      case when current_setting('verify.provoke') <> 'false' then 'FAIL' else 'skip' end, 'no active tenant');
  end if;
end
$$;

drop function if exists pg_temp.v0009zw_my_roster_0005(date, date);
drop function if exists pg_temp.v0009zw_week_0005(date, text);
drop function if exists pg_temp.v0009zw_try(text);
drop function if exists pg_temp.v0009zw_row(integer, text, text, text, text);
drop function if exists pg_temp.v0009zw_p(text);

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0009zw
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke') <> 'false' then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0009zw where result = 'FAIL') then 'FAIL'
                  when not exists (select 1 from pg_temp.verify_0009zw where result = 'PASS') then 'FAIL'
                  else 'PASS' end,
             format('247_verify_roster_assignments: %s PASS, %s FAIL, %s skip', (select count(*) from pg_temp.verify_0009zw where result = 'PASS'),
                    (select count(*) from pg_temp.verify_0009zw where result = 'FAIL'), (select count(*) from pg_temp.verify_0009zw where result = 'skip'))) x
order by ord, check_name collate "C";
drop table if exists pg_temp.verify_0009zw;
reset role;
