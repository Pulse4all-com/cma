-- =============================================================================================
-- 195_verify_roster_planned.sql: verifies addition 0009w, only people planned on the roster (roster.planned,
-- cma.on_roster, the roster reads and writes, cma.roster_today)
-- =============================================================================================
-- Universal: no seed is assumed, so it runs in dev and in prod. Two kinds of checks:
--   on a throwaway tenant (B): invented people (example.invalid) with the default ladder's roles, a person holding admin
--     and agent and a tenant role of its own; the whole step is rolled back;
--   on every active tenant (S3, R1 to R3, D4): the permission on the system roles, the new reads against 0005's
--     definitions (kept below) narrowed to the people on the roster, as the application (cma_app, row-level security
--     on), in a step that is always rolled back; and the stored entries of people not on the roster (D4), for
--     information.
-- Run as your own IAM login, after 194. Output: tenant slugs, counts, check names and dates only; no person's name.
-- 25_verify_roster.sql and 95_verify_attempts_for_sales.sql keep passing unchanged after 194; run both again.
--
-- Checks (the brief's verify list)
--   S1  the addition 0009w is recorded once, after 0009v
--   S2  cma.on_roster and the four re-created functions: cma_owner's, the application's to execute (not public's, not the
--       readers'), in the caller's rights, stable; the reads call cma.on_roster; cma.seed_default_roles names
--       roster.planned for agent, supervisor and manager, and its admin array still ends as 0008z's
--   S3  the permission is in the catalog; every tenant's system agent, supervisor and manager hold it, no system admin or
--       analytics role does (the count of a tenant's own roles holding it is reported)
--   B1  a new tenant's ladder: agent, supervisor and manager hold roster.planned, admin and analytics do not
--   B2  on the roster: agent, supervisor, manager and admin+agent; not admin-only, analytics-only or the tenant's own role
--       holding workday.own without roster.planned; the time of admin-only and of that role is still kept
--   B3  the planner's list (roster_people) holds exactly the people of B2
--   B4  roster_set_entry refuses admin-only and the tenant's own role with the scope error (CMA04) and plans the agent
--   B5  a person who leaves the roster (admin+agent losing agent): the stored entries stay (D4); roster_entries leaves
--       them out; roster_coverage neither counts nor names the shift; roster_copy_week skips them
--   B6  the Live board: admin-only clocked in (a day open today) is on cma.team_now but has no row in cma.roster_today,
--       so the web derives no flag; the agent's and admin+agent's rows are there with their published shift
--   B7  the own schedule is unchanged (D6): the person who left the roster still reads their published shift in
--       cma.my_roster
--   R1  per tenant: roster_people (the whole tenant and each team, this week and next) = 0005's definition narrowed to
--       people holding roster.planned
--   R2  per tenant: roster_entries (the same weeks and rosters) = 0005's definition narrowed to people on the roster
--   R3  per tenant: roster_today = 0005's definition narrowed to people on the roster
--   D4  per tenant, for information: current entries of this week and later whose person is not on the roster (kept, D4)
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

drop table if exists pg_temp.verify_0009w;
create temporary table verify_0009w (ord integer, check_name text, result text, detail text);
grant select, insert on pg_temp.verify_0009w to cma_app;

create or replace function pg_temp.v0009w_p(p_id text)
returns boolean
language sql stable
as $$
  select current_setting('verify.provoke') in ('true', p_id)
$$;

-- One check's row: PASS when what was found equals what is expected; provoked, the expectation carries a deliberate difference
create or replace function pg_temp.v0009w_row(p_ord integer, p_id text, p_name text, p_found text, p_expected text)
returns void
language plpgsql
as $$
declare
  v_exp text := case when pg_temp.v0009w_p(p_id) then coalesce(p_expected, '') || ' [provoked: a deliberate difference]' else p_expected end;
begin
  insert into pg_temp.verify_0009w values (p_ord, p_id || ' ' || p_name,
    case when p_found is not distinct from v_exp then 'PASS' else 'FAIL' end,
    case when p_found is not distinct from v_exp then left(coalesce(p_found, 'null'), 600)
         else left('found ' || coalesce(p_found, 'null') || ' | expected ' || coalesce(v_exp, 'null'), 2400) end);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 0005's definitions (23_roster.sql), kept to compare with: the scope on time kept alone
-- ---------------------------------------------------------------------------------------------
create or replace function pg_temp.v0009w_in_scope_0005(p_user_id uuid, p_team_id uuid, p_week_start date)
returns boolean
language sql stable
as $$
  select cma.time_is_kept(p_user_id)
     and (p_team_id is null
          or exists (select 1 from cma.team_member m
                     where m.tenant_id = cma.current_tenant_id() and m.user_id = p_user_id and m.team_id = p_team_id
                       and m.valid_from < (p_week_start + 7)::timestamp at time zone 'UTC' + interval '1 day'
                       and (m.valid_to is null or m.valid_to > p_week_start::timestamp at time zone 'UTC' - interval '1 day')))
$$;

create or replace function pg_temp.v0009w_people_0005(p_week_start date, p_team_key text)
returns table (user_id uuid, display_name text, organisation_name text, timezone text, team_keys text[], work_type_keys text[])
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
    select u.id, u.display_name::text, coalesce(o.name, '')::text, cma.user_timezone(u.id)::text,
           coalesce((select array_agg(t.key order by t.sort_order, t.key) from cma.team_member m
                     join cma.team t on t.tenant_id = m.tenant_id and t.id = m.team_id
                     where m.tenant_id = u.tenant_id and m.user_id = u.id and m.valid_to is null and t.valid_to is null), '{}'::text[]),
           coalesce((select array_agg(s.key order by s.sort_order, s.key) from cma.user_skill us
                     join cma.skill s on s.tenant_id = us.tenant_id and s.id = us.skill_id
                     where us.tenant_id = u.tenant_id and us.user_id = u.id and us.valid_to is null
                       and s.dimension = 'work_type' and s.status = 'active'), '{}'::text[])
    from cma.app_user u
    left join cma.organisation o on o.tenant_id = u.tenant_id and o.id = u.organisation_id
    where u.tenant_id = cma.current_tenant_id()
      and pg_temp.v0009w_in_scope_0005(u.id, v_team, p_week_start)
    order by u.display_name, u.id;
end
$$;

create or replace function pg_temp.v0009w_entries_0005(p_week_start date, p_team_key text)
returns table (entry_id uuid, user_id uuid, business_date date, kind text, start_time time, end_time time, absence_key text,
               absence_name text, note text, recorded_at timestamptz, recorded_by_name text)
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
    order by e.business_date, e.user_id;
end
$$;

create or replace function pg_temp.v0009w_today_0005()
returns table (user_id uuid, business_date date, is_published boolean, kind text, start_time time, end_time time, absence_name text)
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
      and cma.time_is_kept(u.id)
    order by u.display_name, u.id;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- S. The objects and the ladder
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_bad text := '';
  v_src text;
  f     text;
begin
  -- S1
  perform pg_temp.v0009w_row(1, 'S1', 'the addition 0009w recorded once, after 0009v',
    format('0009v %s; 0009w %s, after 0009v %s, the roster %s',
           (select count(*) from cma.schema_migration where version = '0009v'),
           (select count(*) from cma.schema_migration where version = '0009w'),
           coalesce((select w.applied_at > v.applied_at from cma.schema_migration w, cma.schema_migration v
                     where w.version = '0009w' and v.version = '0009v'), false),
           coalesce((select m.description like 'Roster: only people planned on the roster%' from cma.schema_migration m where m.version = '0009w'), false)),
    '0009v 1; 0009w 1, after 0009v t, the roster t');

  -- S2
  foreach f in array array['cma.on_roster(uuid)', 'cma.roster_in_scope(uuid,uuid,date)', 'cma.roster_entries(date,text)',
                           'cma.roster_coverage(date,text)', 'cma.roster_today()'] loop
    if to_regprocedure(f) is null then
      v_bad := v_bad || f || ' missing; ';
      continue;
    end if;
    if pg_get_userbyid((select p.proowner from pg_proc p where p.oid = to_regprocedure(f))) <> 'cma_owner' then v_bad := v_bad || f || ' owner; '; end if;
    if not has_function_privilege('cma_app', to_regprocedure(f), 'execute') then v_bad := v_bad || f || ' not the application''s; '; end if;
    if has_function_privilege('cma_readonly', to_regprocedure(f), 'execute') then v_bad := v_bad || f || ' the readers''; '; end if;
    if exists (select 1 from pg_proc p cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
               where p.oid = to_regprocedure(f) and a.grantee = 0) then v_bad := v_bad || f || ' public''s; '; end if;
    if (select p.prosecdef from pg_proc p where p.oid = to_regprocedure(f)) then v_bad := v_bad || f || ' security definer; '; end if;
    if (select p.provolatile from pg_proc p where p.oid = to_regprocedure(f)) <> 's' then v_bad := v_bad || f || ' not stable; '; end if;
    if f <> 'cma.on_roster(uuid)' and (select p.prosrc from pg_proc p where p.oid = to_regprocedure(f)) !~ 'cma\.on_roster\(' then
      v_bad := v_bad || f || ' does not call cma.on_roster; ';
    end if;
  end loop;
  if (select p.prosrc from pg_proc p where p.oid = to_regprocedure('cma.on_roster(uuid)')) !~ 'cma\.time_is_kept\(p_user_id\)\s+and\s+cma\.has_permission\(p_user_id, ''roster\.planned''\)' then
    v_bad := v_bad || 'cma.on_roster is not time kept and roster.planned; ';
  end if;
  select p.prosrc into v_src from pg_proc p where p.oid = to_regprocedure('cma.seed_default_roles(uuid)');
  if v_src !~ '''agent'', ''Agent'', array\[[^]]*''roster\.planned''\]'
     or v_src !~ '''supervisor'', ''Supervisor'', array\[[^]]*''roster\.planned''\]'
     or v_src !~ '''manager'', ''Call center manager'', array\[[^]]*''roster\.planned''\]'
     or v_src ~ '''admin'', ''Administrator'', array\[[^]]*''roster\.planned'''
     or v_src ~ '''analytics'', ''Analytics'', array\[[^]]*''roster\.planned'''
     or v_src !~ '''tenant.configure'', ''messages.withdraw''\]' then
    v_bad := v_bad || 'cma.seed_default_roles'' ladder; ';
  end if;
  perform pg_temp.v0009w_row(2, 'S2', 'the functions: the owner''s, the application''s, the caller''s rights, stable, on cma.on_roster; the ladder''s source',
    coalesce(nullif(v_bad, ''), 'ok'), 'ok');

  -- S3
  perform pg_temp.v0009w_row(3, 'S3', 'roster.planned in the catalog; on every system agent, supervisor and manager; on no system admin or analytics',
    format('catalog %s; system agent/supervisor/manager without it %s; system admin/analytics with it %s',
           (select count(*) from cma.permission where key = 'roster.planned'),
           (select count(*) from cma.app_role ar where ar.is_system and ar.key in ('agent', 'supervisor', 'manager')
              and not exists (select 1 from cma.role_permission rp where rp.tenant_id = ar.tenant_id and rp.role_id = ar.id
                              and rp.permission_key = 'roster.planned')),
           (select count(*) from cma.app_role ar where ar.is_system and ar.key in ('admin', 'analytics')
              and exists (select 1 from cma.role_permission rp where rp.tenant_id = ar.tenant_id and rp.role_id = ar.id
                          and rp.permission_key = 'roster.planned'))),
    'catalog 1; system agent/supervisor/manager without it 0; system admin/analytics with it 0');
  insert into pg_temp.verify_0009w
  select 4, 'S3 ' || t.slug || ': a tenant''s own roles holding roster.planned (information)', 'info',
         (select count(*) from cma.app_role ar join cma.role_permission rp on rp.tenant_id = ar.tenant_id and rp.role_id = ar.id
          where ar.tenant_id = t.id and not ar.is_system and rp.permission_key = 'roster.planned')::text
  from cma.tenant t where t.status = 'active';
end
$$;

-- ---------------------------------------------------------------------------------------------
-- B. Behaviour on a throwaway tenant, always rolled back
--    Zone UTC; team alpha; work type wt1 held by ag, both and adm. People: ag (agent, alpha), sup (supervisor), mgr
--    (manager), adm (admin only), ana (analytics only), both (admin and agent, alpha), own (the tenant's role 'clock',
--    workday.own alone). v_wk is next Monday, v_this this week's.
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_today date := (now() at time zone 'UTC')::date;
  v_this  date := cma.week_start((now() at time zone 'UTC')::date);
  v_wk    date := cma.week_start((now() at time zone 'UTC')::date) + 7;
  v_t     uuid;
  v_ag uuid; v_sup uuid; v_mgr uuid; v_adm uuid; v_ana uuid; v_both uuid; v_own uuid;
  v_role  uuid;
  v_text  text;
  v_b1 text; v_b2 text; v_b3 text; v_b4 text; v_b5 text; v_b6 text; v_b7 text;
  v_n     integer;
  v_err   text;
  e       cma.roster_entry;
  w       cma.roster_week;
  -- the name of a person in this step's answers, by id (names are the step's own invented ones)
  v_names jsonb;
begin
  begin
    v_t := cma.create_tenant('verify-0009w', 'Verify 0009w', 'UTC');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'ag@example.invalid', 'ag') returning id into v_ag;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'sup@example.invalid', 'sup') returning id into v_sup;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'mgr@example.invalid', 'mgr') returning id into v_mgr;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'adm@example.invalid', 'adm') returning id into v_adm;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'ana@example.invalid', 'ana') returning id into v_ana;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'both@example.invalid', 'both') returning id into v_both;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'own@example.invalid', 'own') returning id into v_own;
    insert into cma.app_role (tenant_id, key, name, is_system) values (v_t, 'clock', 'Clock only', false) returning id into v_role;
    insert into cma.role_permission (tenant_id, role_id, permission_key) values (v_t, v_role, 'workday.own');
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t, x.uid, ar.id
    from (values (v_ag, 'agent'), (v_sup, 'supervisor'), (v_mgr, 'manager'), (v_adm, 'admin'), (v_ana, 'analytics'),
                 (v_both, 'admin'), (v_both, 'agent'), (v_own, 'clock')) as x(uid, role_key)
    join cma.app_role ar on ar.tenant_id = v_t and ar.key = x.role_key;
    insert into cma.team (tenant_id, key, name, markets, sort_order) values (v_t, 'alpha', 'Team Alpha', array['xa'], 10);
    insert into cma.team_member (tenant_id, user_id, team_id)
    select v_t, x.uid, t.id from (values (v_ag), (v_both)) as x(uid) join cma.team t on t.tenant_id = v_t and t.key = 'alpha';
    insert into cma.skill (tenant_id, dimension, key, name, sort_order) values (v_t, 'work_type', 'wt1', 'Work one', 10);
    insert into cma.user_skill (tenant_id, user_id, skill_id, level)
    select v_t, x.uid, s.id, null from (values (v_ag), (v_both), (v_adm)) as x(uid) join cma.skill s on s.tenant_id = v_t and s.key = 'wt1';

    -- B1: the new tenant's ladder (seeded by cma.create_tenant through cma.seed_default_roles)
    select string_agg(ar.key || '=' || exists (select 1 from cma.role_permission rp where rp.tenant_id = ar.tenant_id and rp.role_id = ar.id
                                                and rp.permission_key = 'roster.planned'), ', ' order by ar.key collate "C")
    into v_b1 from cma.app_role ar where ar.tenant_id = v_t and ar.is_system and ar.key in ('agent', 'supervisor', 'manager', 'admin', 'analytics');

    -- From here on as the application
    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('role', 'cma_app', true);

    -- B2: on the roster and time kept, per person
    select string_agg(u.display_name || '=' || cma.on_roster(u.id) || '/' || cma.time_is_kept(u.id), ', ' order by u.display_name collate "C")
    into v_b2 from cma.app_user u where u.tenant_id = v_t and u.email like '%@example.invalid';

    -- B3: the planner's list, the whole tenant and team alpha
    perform set_config('app.user_id', v_mgr::text, true);
    select coalesce(string_agg(p.display_name, ', ' order by p.display_name collate "C"), '(none)') into v_b3 from cma.roster_people(v_wk, null) p;
    select v_b3 || ' | alpha: ' || coalesce(string_agg(p.display_name, ', ' order by p.display_name collate "C"), '(none)')
    into v_b3 from cma.roster_people(v_wk, 'alpha') p;

    -- B4: the writes refuse a person not on the roster with the scope error, and plan the agent
    v_b4 := '';
    foreach v_text in array array['adm', 'own', 'ana'] loop
      begin
        perform cma.roster_set_entry(v_wk, null, (select u.id from cma.app_user u where u.tenant_id = v_t and u.display_name = v_text),
                                     v_wk, 'shift', '09:00', '17:00', null, null);
        v_b4 := v_b4 || v_text || ' ok; ';
      exception when others then
        v_b4 := v_b4 || v_text || ' ' || sqlstate || '; ';
      end;
    end loop;
    e := cma.roster_set_entry(v_wk, 'alpha', v_ag, v_wk, 'shift', '09:00', '17:00', null, null);
    v_b4 := v_b4 || 'ag ' || case when e.id is not null then 'planned' else 'not planned' end;

    -- B5: both is planned (alpha, next week: a shift on Monday, an absence on Tuesday), then loses the agent role and so
    -- leaves the roster; the stored entries stay, the reads leave them out, the copy skips them
    e := cma.roster_set_entry(v_wk, 'alpha', v_both, v_wk, 'shift', '10:00', '18:00', null, null);
    e := cma.roster_set_entry(v_wk, 'alpha', v_both, v_wk + 1, 'absence', null, null, 'off', null);
    select format('before: entries %s, wt1 Monday %s [%s]',
                  (select count(*) from cma.roster_entries(v_wk, 'alpha')),
                  c.planned_people, array_to_string(c.people_names, ','))
    into v_b5 from cma.roster_coverage(v_wk, 'alpha') c where c.business_date = v_wk and c.skill_key = 'wt1';
    perform set_config('role', 'cma_owner', true);
    delete from cma.user_role ur using cma.app_role ar
     where ur.tenant_id = v_t and ur.user_id = v_both and ar.tenant_id = ur.tenant_id and ar.id = ur.role_id and ar.key = 'agent';
    select v_b5 || format('; stored %s', count(*)) into v_b5
    from cma.roster_entry x where x.tenant_id = v_t and x.user_id = v_both and x.valid_to is null;
    perform set_config('role', 'cma_app', true);
    select v_b5 || format('; after: entries %s [%s], wt1 Monday %s [%s]',
                          (select count(*) from cma.roster_entries(v_wk, 'alpha')),
                          (select string_agg(u.display_name, ',' order by x.business_date, u.display_name collate "C")
                           from cma.roster_entries(v_wk, 'alpha') x join cma.app_user u on u.tenant_id = v_t and u.id = x.user_id),
                          c.planned_people, array_to_string(c.people_names, ','))
    into v_b5 from cma.roster_coverage(v_wk, 'alpha') c where c.business_date = v_wk and c.skill_key = 'wt1';
    v_n := cma.roster_copy_week(v_wk, v_wk + 7, 'alpha');
    perform set_config('role', 'cma_owner', true);
    select v_b5 || format('; copied %s, both in the copy %s', v_n, count(*)) into v_b5
    from cma.roster_entry x join cma.roster_week xw on xw.tenant_id = x.tenant_id and xw.id = x.roster_week_id
    where x.tenant_id = v_t and x.user_id = v_both and x.valid_to is null and xw.week_start = v_wk + 7;

    -- B6 and B7: this week's tenant roster, published, with a shift today for ag and adm (adm's written while adm held the
    -- agent role, which is then taken back: an entry stored before its person left the roster, D4) and for both on alpha
    -- before both left the roster; adm clocks in
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t, v_adm, ar.id from cma.app_role ar where ar.tenant_id = v_t and ar.key = 'agent';
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t, v_both, ar.id from cma.app_role ar where ar.tenant_id = v_t and ar.key = 'agent';
    perform set_config('role', 'cma_app', true);
    e := cma.roster_set_entry(v_this, null, v_ag, v_today, 'shift', '00:00', '24:00', null, null);
    e := cma.roster_set_entry(v_this, null, v_adm, v_today, 'shift', '00:00', '24:00', null, null);
    e := cma.roster_set_entry(v_this, 'alpha', v_both, v_today, 'shift', '00:00', '24:00', null, null);
    w := cma.roster_publish(v_this, null);
    w := cma.roster_publish(v_this, 'alpha');
    perform set_config('role', 'cma_owner', true);
    delete from cma.user_role ur using cma.app_role ar
     where ur.tenant_id = v_t and ur.user_id in (v_adm, v_both) and ar.tenant_id = ur.tenant_id and ar.id = ur.role_id and ar.key = 'agent';
    perform set_config('role', 'cma_app', true);
    v_err := null;
    begin
      perform set_config('app.user_id', v_adm::text, true);
      perform cma.open_workday();
    exception when others then
      v_err := sqlstate || ': ' || left(sqlerrm, 200);
    end;
    perform set_config('app.user_id', v_sup::text, true);
    select format('adm clocked in %s, on the board %s with a day %s; roster_today: %s',
                  coalesce(v_err, 'ok'),
                  exists (select 1 from cma.team_now() n where n.user_id = v_adm),
                  exists (select 1 from cma.team_now() n where n.user_id = v_adm and n.workday_id is not null),
                  (select string_agg(u.display_name || ' ' || coalesce(x.kind, '-') || ' ' || x.is_published, ', ' order by u.display_name collate "C")
                   from cma.roster_today() x join cma.app_user u on u.tenant_id = v_t and u.id = x.user_id))
    into v_b6;
    -- B7: the own schedule of both, who left the roster, still holds the published shift (D6)
    perform set_config('app.user_id', v_both::text, true);
    select format('both today: %s %s', coalesce(x.kind, '-'), x.is_published) into v_b7
    from cma.my_roster(v_today, v_today) x;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then v_err := sqlstate || ': ' || left(sqlerrm, 300);
      perform set_config('role', 'cma_owner', true);
      insert into pg_temp.verify_0009w values (10, 'B the throwaway tenant''s checks ran to their end', 'FAIL', v_err);
  end;
  perform set_config('role', 'cma_owner', true);
  perform set_config('app.tenant_id', '', true);
  perform set_config('app.user_id', '', true);

  perform pg_temp.v0009w_row(11, 'B1', 'a new tenant''s ladder: roster.planned on agent, supervisor and manager',
    v_b1, 'admin=false, agent=true, analytics=false, manager=true, supervisor=true');
  perform pg_temp.v0009w_row(12, 'B2', 'on the roster / time kept: roles combine; admin-only and a role without roster.planned keep the clock',
    v_b2, 'adm=false/true, ag=true/true, ana=false/false, both=true/true, mgr=true/true, own=false/true, sup=true/true');
  perform pg_temp.v0009w_row(13, 'B3', 'the planner''s list: the people on the roster, a team''s members among them',
    v_b3, 'ag, both, mgr, sup | alpha: ag, both');
  perform pg_temp.v0009w_row(14, 'B4', 'roster_set_entry refuses people not on the roster (CMA04), plans the agent',
    v_b4, 'adm CMA04; own CMA04; ana CMA04; ag planned');
  perform pg_temp.v0009w_row(15, 'B5', 'a person who leaves the roster: entries stored, not shown, not counted, not copied',
    v_b5, 'before: entries 3, wt1 Monday 2 [ag,both]; stored 2; after: entries 1 [ag], wt1 Monday 1 [ag]; copied 1, both in the copy 0');
  perform pg_temp.v0009w_row(16, 'B6', 'the Live board: admin-only clocked in is on the board without a shift row (no flag)',
    v_b6, 'adm clocked in ok, on the board t with a day t; roster_today: ag shift true, mgr - true, sup - true');
  perform pg_temp.v0009w_row(17, 'B7', 'the own schedule is unchanged (D6)', v_b7, 'both today: shift t');
end
$$;

-- ---------------------------------------------------------------------------------------------
-- R and D4. Per active tenant, as the application, always rolled back
-- ---------------------------------------------------------------------------------------------
do $$
declare
  t         record;
  v_this    date := cma.week_start((now() at time zone 'UTC')::date);
  v_planner uuid;
  v_live    uuid;
  v_err     text;
  v_cmp     integer;
  v_r1      text; v_r2 text; v_r3 text; v_d4 text;
  wk        date;
  tk        text;
  v_any     boolean := false;
begin
  for t in select id, slug from cma.tenant where status = 'active' and slug not like 'verify-%' order by slug collate "C" loop
    v_any := true;
    v_err := null; v_r1 := ''; v_r2 := ''; v_r3 := null; v_d4 := null; v_cmp := 0;
    -- the acting people (131's choice: the oldest active person holding the read's permission), in the tenant's context
    perform set_config('app.tenant_id', t.id::text, true);
    select u.id into v_planner from cma.app_user u
    where u.tenant_id = t.id and u.status = 'active' and u.kind = 'person' and cma.has_permission(u.id, 'roster.manage')
    order by u.created_at, u.id limit 1;
    select u.id into v_live from cma.app_user u
    where u.tenant_id = t.id and u.status = 'active' and u.kind = 'person' and cma.has_permission(u.id, 'monitoring.live')
    order by u.created_at, u.id limit 1;
    begin
      perform set_config('app.tenant_id', t.id::text, true);
      perform set_config('role', 'cma_app', true);
      if v_planner is not null then
        perform set_config('app.user_id', v_planner::text, true);
        foreach wk in array array[v_this, v_this + 7] loop
          for tk in select null::text union all select x.key::text from cma.team x where x.tenant_id = t.id and x.valid_to is null loop
            v_cmp := v_cmp + 1;
            -- R1: the people, against 0005's narrowed to roster.planned
            if exists ((select * from cma.roster_people(wk, tk))
                       except all
                       (select * from pg_temp.v0009w_people_0005(wk, tk) p where cma.has_permission(p.user_id, 'roster.planned')))
               or exists ((select * from pg_temp.v0009w_people_0005(wk, tk) p where cma.has_permission(p.user_id, 'roster.planned'))
                          except all
                          (select * from cma.roster_people(wk, tk))) then
              v_r1 := v_r1 || wk || '/' || coalesce(tk, 'tenant') || ' ';
            end if;
            -- R2: the entries, against 0005's narrowed to the people on the roster
            if exists ((select * from cma.roster_entries(wk, tk))
                       except all
                       (select * from pg_temp.v0009w_entries_0005(wk, tk) x where cma.on_roster(x.user_id)))
               or exists ((select * from pg_temp.v0009w_entries_0005(wk, tk) x where cma.on_roster(x.user_id))
                          except all
                          (select * from cma.roster_entries(wk, tk))) then
              v_r2 := v_r2 || wk || '/' || coalesce(tk, 'tenant') || ' ';
            end if;
          end loop;
        end loop;
      end if;
      if v_live is not null then
        perform set_config('app.user_id', v_live::text, true);
        v_r3 := case when exists ((select * from cma.roster_today())
                                  except all (select * from pg_temp.v0009w_today_0005() x where cma.on_roster(x.user_id)))
                       or exists ((select * from pg_temp.v0009w_today_0005() x where cma.on_roster(x.user_id))
                                  except all (select * from cma.roster_today()))
                     then 'differs' else 'equal' end;
      end if;
      -- D4: current entries of this week and later whose person is not on the roster (kept as stored)
      select format('%s entries of %s people', count(*), count(distinct x.user_id)) into v_d4
      from cma.roster_entry x
      where x.tenant_id = t.id and x.valid_to is null and x.business_date >= v_this and not cma.on_roster(x.user_id);
      raise exception using errcode = 'CMAOK', message = 'rollback';
    exception
      when sqlstate 'CMAOK' then null;
      when others then v_err := sqlstate || ': ' || left(sqlerrm, 300);
    end;
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.tenant_id', '', true);
    perform set_config('app.user_id', '', true);
    if v_err is not null then
      insert into pg_temp.verify_0009w values (20, 'R1 to D4 ' || t.slug || ': the checks ran to their end', 'FAIL', v_err);
      continue;
    end if;
    if v_planner is null then
      insert into pg_temp.verify_0009w values (21, 'R1 and R2 ' || t.slug || ': the planner''s reads',
        case when pg_temp.v0009w_p('R1') or pg_temp.v0009w_p('R2') then 'FAIL' else 'skip' end, 'no active person holds roster.manage');
    else
      perform pg_temp.v0009w_row(21, 'R1', t.slug || ': roster_people = 0005''s narrowed to roster.planned (this week and next, every roster)',
        format('rosters compared %s; differing %s', v_cmp, coalesce(nullif(btrim(v_r1), ''), 'none')),
        format('rosters compared %s; differing none', v_cmp));
      perform pg_temp.v0009w_row(22, 'R2', t.slug || ': roster_entries = 0005''s narrowed to the people on the roster',
        format('rosters compared %s; differing %s', v_cmp, coalesce(nullif(btrim(v_r2), ''), 'none')),
        format('rosters compared %s; differing none', v_cmp));
    end if;
    if v_live is null then
      insert into pg_temp.verify_0009w values (23, 'R3 ' || t.slug || ': roster_today',
        case when pg_temp.v0009w_p('R3') then 'FAIL' else 'skip' end, 'no active person holds monitoring.live');
    else
      perform pg_temp.v0009w_row(23, 'R3', t.slug || ': roster_today = 0005''s narrowed to the people on the roster', v_r3, 'equal');
    end if;
    insert into pg_temp.verify_0009w values (24, 'D4 ' || t.slug || ': stored entries, this week and later, of people not on the roster (information, kept)',
      'info', v_d4);
  end loop;
  if not v_any then
    insert into pg_temp.verify_0009w values (20, 'R1 to D4 per tenant',
      case when current_setting('verify.provoke') <> 'false' then 'FAIL' else 'skip' end, 'no active tenant');
  end if;
end
$$;

drop function if exists pg_temp.v0009w_today_0005();
drop function if exists pg_temp.v0009w_entries_0005(date, text);
drop function if exists pg_temp.v0009w_people_0005(date, text);
drop function if exists pg_temp.v0009w_in_scope_0005(uuid, uuid, date);
drop function if exists pg_temp.v0009w_row(integer, text, text, text, text);
drop function if exists pg_temp.v0009w_p(text);

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0009w
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke') <> 'false' then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0009w where result = 'FAIL') then 'FAIL'
                  when not exists (select 1 from pg_temp.verify_0009w where result = 'PASS') then 'FAIL'
                  else 'PASS' end,
             format('195_verify_roster_planned: %s PASS, %s FAIL, %s skip, %s info', (select count(*) from pg_temp.verify_0009w where result = 'PASS'),
                    (select count(*) from pg_temp.verify_0009w where result = 'FAIL'), (select count(*) from pg_temp.verify_0009w where result = 'skip'),
                    (select count(*) from pg_temp.verify_0009w where result = 'info'))) x
order by ord, check_name collate "C";
drop table if exists pg_temp.verify_0009w;
reset role;
