-- =============================================================================================
-- 25_verify_roster.sql: verifies migration 0005, the roster
-- =============================================================================================
-- Both blocks are universal: A checks structure and privileges, B works on throwaway tenants and
-- people inside a subtransaction that is always rolled back. No seed is assumed: teams, skills and
-- the absence types come from the throwaway tenant's own rows (the default absence types that
-- create_tenant seeds).
-- Cloud SQL Studio shows no notices: a check that fails raises "FAIL …" and stops the script.
-- The last result is the verdict. Run as your own IAM login, dev and prod.
-- Provoke: set provoke below to true; every block must then stop with FAIL, and the verdict
-- (reached only when the run does not stop on errors) says PROVOKED instead of PASS.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);   -- 'true' to make every block fail

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_t       text;
  v_fn      text;
  v_cols    text;
begin
  if not exists (select 1 from cma.schema_migration where version = '0005') then
    raise exception 'FAIL A1: migration 0005 not recorded';
  end if;

  -- A2. the tables: tenant-scoped, RLS, the app policy, the audit trigger, no delete for the app
  foreach v_t in array array['absence_type', 'roster_week', 'roster_publication', 'roster_entry', 'coverage_target'] loop
    if to_regclass('cma.' || v_t) is null then
      raise exception 'FAIL A2: cma.% does not exist', v_t;
    end if;
    if not (select relrowsecurity from pg_class where oid = to_regclass('cma.' || v_t)) then
      raise exception 'FAIL A2: row-level security is off on cma.%', v_t;
    end if;
    if not exists (select 1 from pg_policies where schemaname = 'cma' and tablename = v_t and policyname = 'tenant_app') then
      raise exception 'FAIL A2: no tenant_app policy on cma.%', v_t;
    end if;
    if not exists (select 1 from pg_trigger where tgrelid = to_regclass('cma.' || v_t) and tgname = 'audit') then
      raise exception 'FAIL A2: no audit trigger on cma.%', v_t;
    end if;
    if not has_table_privilege('cma_app', 'cma.' || v_t, 'select') or not has_table_privilege('cma_app', 'cma.' || v_t, 'insert') then
      raise exception 'FAIL A2: cma_app cannot read or insert into cma.%', v_t;
    end if;
    if v_t <> 'coverage_target' and (has_table_privilege('cma_app', 'cma.' || v_t, 'delete') or v_provoke) then
      raise exception 'FAIL A2: cma_app may delete from cma.%', v_t;
    end if;
    if has_table_privilege('cma_readonly', 'cma.' || v_t, 'select') then
      raise exception 'FAIL A2: readers may read the base table cma.%', v_t;
    end if;
    if to_regclass('cma_read.' || v_t) is null then
      raise exception 'FAIL A2: cma_read.% does not exist', v_t;
    end if;
  end loop;
  -- an entry version is ended, never rewritten: update only on the two closing columns
  if has_column_privilege('cma_app', 'cma.roster_entry', 'start_time', 'update')
     or has_column_privilege('cma_app', 'cma.roster_entry', 'kind', 'update')
     or not has_column_privilege('cma_app', 'cma.roster_entry', 'valid_to', 'update')
     or not has_column_privilege('cma_app', 'cma.roster_entry', 'superseded_by', 'update') then
    raise exception 'FAIL A2: cma_app must update roster_entry.valid_to and superseded_by and nothing else';
  end if;
  if has_table_privilege('cma_app', 'cma.roster_publication', 'update') then
    raise exception 'FAIL A2: publications must be insert-only for the app';
  end if;
  if not exists (select 1 from pg_indexes where schemaname = 'cma' and tablename = 'roster_entry' and indexname = 'roster_entry_current_idx' and indexdef like '%WHERE (valid_to IS NULL)%') then
    raise exception 'FAIL A2: the unique index on current entries is missing';
  end if;

  -- A3. the setting
  if not exists (select 1 from cma.setting where key = 'roster.adherence_tolerance_minutes' and value_type = 'integer' and default_value = '5') then
    raise exception 'FAIL A3: the setting roster.adherence_tolerance_minutes is missing or has another default';
  end if;

  -- A4. the functions: the app may execute them, readers and public may not, none runs as owner
  foreach v_fn in array array[
    'cma.roster_week(date,text)', 'cma.roster_people(date,text)', 'cma.roster_entries(date,text)',
    'cma.roster_weeks(text,date,date)', 'cma.roster_coverage(date,text)', 'cma.coverage_targets(text)',
    'cma.roster_set_entry(date,text,uuid,date,text,time,time,text,text)', 'cma.roster_publish(date,text)',
    'cma.roster_copy_week(date,date,text)', 'cma.set_coverage_target(text,text,smallint,integer)',
    'cma.absence_types()', 'cma.upsert_absence_type(text,text,boolean,integer,text)',
    'cma.my_roster(date,date)', 'cma.roster_today()'] loop
    if to_regprocedure(v_fn) is null then
      raise exception 'FAIL A4: % does not exist', v_fn;
    end if;
    if not has_function_privilege('cma_app', v_fn, 'execute')
       or has_function_privilege('cma_readonly', v_fn, 'execute')
       or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                  where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE') then
      raise exception 'FAIL A4: execute on % must be granted to cma_app only', v_fn;
    end if;
    if (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      raise exception 'FAIL A4: % must run with the caller''s rights, not as its owner', v_fn;
    end if;
  end loop;
  foreach v_fn in array array['cma.roster_week(date,text)', 'cma.roster_entries(date,text)', 'cma.my_roster(date,date)', 'cma.roster_today()', 'cma.roster_coverage(date,text)'] loop
    if (select provolatile from pg_proc where oid = to_regprocedure(v_fn)) <> 's' then
      raise exception 'FAIL A4: % must be stable (a read, never a write)', v_fn;
    end if;
  end loop;
  select string_agg(a.attname, ', ' order by a.n) into v_cols
  from pg_proc p
  join lateral unnest(p.proargnames, p.proargmodes) with ordinality as a(attname, attmode, n) on true
  where p.oid = to_regprocedure('cma.my_roster(date,date)') and a.attmode = 't';
  if v_cols is distinct from 'business_date, is_published, kind, start_time, end_time, absence_key, absence_name, note, team_name, published_at' then
    raise exception 'FAIL A4: my_roster returns [%]', v_cols;
  end if;

  -- A5. the published-entry views: the core for nobody, the faces for the app and the readers
  if to_regclass('cma.roster_published_entry_all') is null or to_regclass('cma.roster_published_entry') is null
     or to_regclass('cma_read.roster_published_entry') is null then
    raise exception 'FAIL A5: the roster_published_entry views are missing';
  end if;
  if has_table_privilege('cma_app', 'cma.roster_published_entry_all', 'select')
     or has_table_privilege('cma_readonly', 'cma.roster_published_entry_all', 'select') then
    raise exception 'FAIL A5: the core view roster_published_entry_all must be readable by the owner only';
  end if;
  if not has_table_privilege('cma_app', 'cma.roster_published_entry', 'select')
     or not has_table_privilege('cma_readonly', 'cma_read.roster_published_entry', 'select') then
    raise exception 'FAIL A5: the app or the readers cannot read their face of roster_published_entry';
  end if;
end
$$;

-- B. Behaviour on throwaway tenants (universal, always rolled back)
--    Tenant one, zone UTC: teams alpha and beta; a1 in alpha (holds work type wt1), a2 in alpha and beta
--    (wt1 and wt2), a3 in no team; a manager (roster.manage), a supervisor (monitoring.live), an
--    analyst (no roster.view) and a person without a role. Tenant two: an agent and a manager.
--    v_wk is next Monday, always in the future; v_past is a Monday two weeks back, always in the past.
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_today   date := (now() at time zone 'UTC')::date;
  v_wk         date := cma.week_start((now() at time zone 'UTC')::date) + 7;
  v_past         date := cma.week_start((now() at time zone 'UTC')::date) - 14;
  v_this         date := cma.week_start((now() at time zone 'UTC')::date);   -- this week
  v_t1      uuid;
  v_t2      uuid;
  v_a1      uuid;
  v_a2      uuid;
  v_a3      uuid;
  v_mgr     uuid;
  v_sup     uuid;
  v_ana     uuid;
  v_norole  uuid;
  v_a_t2    uuid;
  v_mgr_t2  uuid;
  v_text    text;
  v_n       int;
  v_n2      int;
  v_ts      timestamptz;
  e         cma.roster_entry;
  w         cma.roster_week;
  r         record;
begin
  begin
    -- Setup as owner
    v_t1 := cma.create_tenant('verify-0005-one', 'Verify 0005 one', 'UTC');
    v_t2 := cma.create_tenant('verify-0005-two', 'Verify 0005 two', 'UTC');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'a1@example.invalid', 'Verify A1') returning id into v_a1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'a2@example.invalid', 'Verify A2') returning id into v_a2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'a3@example.invalid', 'Verify A3') returning id into v_a3;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'mgr@example.invalid', 'Verify manager') returning id into v_mgr;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'sup@example.invalid', 'Verify supervisor') returning id into v_sup;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'ana@example.invalid', 'Verify analyst') returning id into v_ana;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'norole@example.invalid', 'Verify no role') returning id into v_norole;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'a@example.invalid', 'Verify agent of two') returning id into v_a_t2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'mgr@example.invalid', 'Verify manager of two') returning id into v_mgr_t2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t1, x.uid, ar.id
    from (values (v_a1, 'agent'), (v_a2, 'agent'), (v_a3, 'agent'), (v_mgr, 'manager'), (v_sup, 'supervisor'), (v_ana, 'analytics')) as x(uid, role_key)
    join cma.app_role ar on ar.tenant_id = v_t1 and ar.key = x.role_key;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t2, x.uid, ar.id
    from (values (v_a_t2, 'agent'), (v_mgr_t2, 'manager')) as x(uid, role_key)
    join cma.app_role ar on ar.tenant_id = v_t2 and ar.key = x.role_key;
    insert into cma.team (tenant_id, key, name, markets, sort_order) values
      (v_t1, 'alpha', 'Team Alpha', array['xa'], 10), (v_t1, 'beta', 'Team Beta', array['xb'], 20), (v_t2, 'alpha', 'Alpha of two', '{}', 10);
    insert into cma.team_member (tenant_id, user_id, team_id)
    select v_t1, x.uid, t.id from (values (v_a1, 'alpha'), (v_a2, 'alpha'), (v_a2, 'beta')) as x(uid, tk)
    join cma.team t on t.tenant_id = v_t1 and t.key = x.tk;
    insert into cma.skill (tenant_id, dimension, key, name, sort_order) values
      (v_t1, 'work_type', 'wt1', 'Work one', 10), (v_t1, 'work_type', 'wt2', 'Work two', 20), (v_t1, 'language', 'xx', 'Tongue', 10);
    insert into cma.user_skill (tenant_id, user_id, skill_id, level)
    select v_t1, x.uid, s.id, x.lvl from (values (v_a1, 'wt1', null::smallint), (v_a2, 'wt1', null), (v_a2, 'wt2', null), (v_a1, 'xx', 3::smallint)) as x(uid, sk, lvl)
    join cma.skill s on s.tenant_id = v_t1 and s.key = x.sk;

    -- From here on as the application
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);

    -- B1. an agent cannot read the planner; the manager reads an empty header
    perform set_config('app.user_id', v_a1::text, true);
    begin
      perform cma.roster_week(v_wk, 'alpha');
      raise exception 'FAIL B1: an agent read the planner';
    exception when sqlstate 'CMA06' then null;
    end;
    perform set_config('app.user_id', v_mgr::text, true);
    select * into r from cma.roster_week(v_wk, 'alpha');
    if r.week_id is not null or r.status <> 'draft' or r.version <> 0 or r.team_name <> 'Team Alpha' or r.entry_count <> 0 or r.changed_since_publish or v_provoke then
      raise exception 'FAIL B1: an unwritten week reads (%, %, %, %, %)', r.week_id, r.status, r.version, r.team_name, r.entry_count;
    end if;

    -- B2. the grid: alpha's members in the week; the whole tenant is everyone whose time is kept
    select string_agg(p.display_name || ':' || array_to_string(p.work_type_keys, '+'), ', ' order by p.display_name) into v_text from cma.roster_people(v_wk, 'alpha') p;
    if v_text is distinct from 'Verify A1:wt1, Verify A2:wt1+wt2' then
      raise exception 'FAIL B2: alpha''s grid is [%]', v_text;
    end if;
    select string_agg(p.display_name, ', ' order by p.display_name) into v_text from cma.roster_people(v_wk, null) p;
    if v_text is distinct from 'Verify A1, Verify A2, Verify A3, Verify manager, Verify supervisor' then
      raise exception 'FAIL B2: the tenant grid is [%]', v_text;
    end if;

    -- B3. a shift and an absence are written and read back; the header counts them as a draft
    e := cma.roster_set_entry(v_wk, 'alpha', v_a1, v_wk, 'shift', '09:00', '17:30', null, null);
    e := cma.roster_set_entry(v_wk, 'alpha', v_a1, v_wk + 1, 'absence', null, null, 'sick', null);
    e := cma.roster_set_entry(v_wk, 'alpha', v_a2, v_wk, 'shift', '10:00', '18:00', null, 'desk 4');
    select string_agg(x.business_date || ' ' || x.kind || ' ' || coalesce(x.start_time::text, '') || '-' || coalesce(x.end_time::text, '') || coalesce(' ' || x.absence_key, '') || coalesce(' ' || x.note, ''), '; ' order by x.business_date, x.user_id) into v_text
    from cma.roster_entries(v_wk, 'alpha') x;
    if v_text is distinct from v_wk || ' shift 09:00:00-17:30:00; ' || v_wk || ' shift 10:00:00-18:00:00 desk 4; ' || (v_wk + 1) || ' absence - sick' then
      raise exception 'FAIL B3: the entries read [%]', v_text;
    end if;
    select * into r from cma.roster_week(v_wk, 'alpha');
    if r.week_id is null or r.status <> 'draft' or r.entry_count <> 3 then
      raise exception 'FAIL B3: the header reads (%, %, %)', r.week_id, r.status, r.entry_count;
    end if;
    -- writing the same cell again changes nothing (one version)
    e := cma.roster_set_entry(v_wk, 'alpha', v_a1, v_wk, 'shift', '09:00', '17:30', null, null);
    select count(*) into v_n from cma.roster_entry where user_id = v_a1 and business_date = v_wk;
    if v_n <> 1 then
      raise exception 'FAIL B3: rewriting an unchanged cell made % versions', v_n;
    end if;

    -- B4. refusals: a date outside the week, a person not on the grid, bad times, an unknown
    --     absence type, the past, an unknown team, a week that is not a Monday
    begin
      perform cma.roster_set_entry(v_wk, 'alpha', v_a1, v_wk + 7, 'shift', '09:00', '17:00', null, null);
      raise exception 'FAIL B4: a date outside the week was accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    begin
      perform cma.roster_set_entry(v_wk, 'alpha', v_a3, v_wk, 'shift', '09:00', '17:00', null, null);
      raise exception 'FAIL B4: a person outside the team was planned on its roster';
    exception when sqlstate 'CMA04' then null;
    end;
    begin
      perform cma.roster_set_entry(v_wk, 'alpha', v_a1, v_wk + 2, 'shift', '17:00', '09:00', null, null);
      raise exception 'FAIL B4: an end before the start was accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    begin
      perform cma.roster_set_entry(v_wk, 'alpha', v_a1, v_wk + 2, 'absence', null, null, 'verify-no-such-type', null);
      raise exception 'FAIL B4: an unknown absence type was accepted';
    exception when sqlstate 'CMA02' then null;
    end;
    begin
      perform cma.roster_set_entry(v_past, 'alpha', v_a1, v_past, 'shift', '09:00', '17:00', null, null);
      raise exception 'FAIL B4: a date in the past was planned';
    exception when sqlstate 'CMA04' then null;
    end;
    begin
      perform cma.roster_set_entry(v_wk, 'verify-no-such-team', v_a1, v_wk, 'shift', '09:00', '17:00', null, null);
      raise exception 'FAIL B4: an unknown team was accepted';
    exception when sqlstate 'CMA02' then null;
    end;
    begin
      perform cma.roster_week(v_wk + 1, 'alpha');
      raise exception 'FAIL B4: a week that is not a Monday was accepted';
    exception when sqlstate 'CMA04' then null;
    end;

    -- B5. publish: version 1, a publication row; the agent sees the published cells; a person
    --     the roster does not cover sees no publication
    w := cma.roster_publish(v_wk, 'alpha');
    select count(*) into v_n from cma.roster_publication where roster_week_id = w.id;
    if w.status <> 'published' or w.version <> 1 or w.published_at is null or w.published_by <> v_mgr or v_n <> 1 then
      raise exception 'FAIL B5: publishing gave (%, %, %, % publications)', w.status, w.version, w.published_at, v_n;
    end if;
    perform set_config('app.user_id', v_a1::text, true);
    select string_agg(m.business_date || ':' || m.is_published || ':' || coalesce(m.kind, '-') || ':' || coalesce(m.start_time::text, '') || ':' || coalesce(m.absence_name, ''), '; ' order by m.business_date) into v_text
    from cma.my_roster(v_wk, v_wk + 2) m;
    if v_text is distinct from v_wk || ':true:shift:09:00:00:; ' || (v_wk + 1) || ':true:absence::Sick; ' || (v_wk + 2) || ':true:-::' then
      raise exception 'FAIL B5: a1''s schedule reads [%]', v_text;
    end if;
    perform set_config('app.user_id', v_a3::text, true);
    select bool_or(m.is_published), count(*) filter (where m.kind is not null) into r from cma.my_roster(v_wk, v_wk + 6) m;
    if r.bool_or or r.count <> 0 then
      raise exception 'FAIL B5: a3, in no team, sees alpha''s publication';
    end if;
    perform set_config('app.user_id', v_ana::text, true);
    begin
      perform cma.my_roster(v_wk, v_wk);
      raise exception 'FAIL B5: the analyst read a schedule without roster.view';
    exception when sqlstate 'CMA06' then null;
    end;

    -- B6. editing a published week: the planner sees the change, the agent keeps the publication,
    --     the header says so; the cell has two versions; publishing again shows the change
    perform set_config('app.user_id', v_mgr::text, true);
    e := cma.roster_set_entry(v_wk, 'alpha', v_a1, v_wk, 'shift', '10:00', '18:30', null, null);
    select r2.start_time::text into v_text from cma.roster_entries(v_wk, 'alpha') r2 where r2.user_id = v_a1 and r2.business_date = v_wk;
    select changed_since_publish into r from cma.roster_week(v_wk, 'alpha');
    if v_text <> '10:00:00' or not r.changed_since_publish then
      raise exception 'FAIL B6: after an edit the planner reads start % and changed %', v_text, r.changed_since_publish;
    end if;
    select count(*), count(*) filter (where valid_to is not null and superseded_by is not null) into v_n, v_n2
    from cma.roster_entry where user_id = v_a1 and business_date = v_wk;
    if v_n <> 2 or v_n2 <> 1 then
      raise exception 'FAIL B6: the cell has % versions, % ended with a successor', v_n, v_n2;
    end if;
    perform set_config('app.user_id', v_a1::text, true);
    select m.start_time::text into v_text from cma.my_roster(v_wk, v_wk) m;
    if v_text <> '09:00:00' then
      raise exception 'FAIL B6: the agent saw an unpublished change (%)', v_text;
    end if;
    perform set_config('app.user_id', v_mgr::text, true);
    w := cma.roster_publish(v_wk, 'alpha');
    perform set_config('app.user_id', v_a1::text, true);
    select m.start_time::text into v_text from cma.my_roster(v_wk, v_wk) m;
    perform set_config('app.user_id', v_mgr::text, true);
    select changed_since_publish into r from cma.roster_week(v_wk, 'alpha');
    if w.version <> 2 or v_text <> '10:00:00' or r.changed_since_publish then
      raise exception 'FAIL B6: after the second publish (version %, agent sees %, changed %)', w.version, v_text, r.changed_since_publish;
    end if;

    -- B7. one entry per person per date across rosters: a2 is planned in alpha on v_wk, so beta is
    --     refused; cleared in alpha, beta may plan a2
    begin
      perform cma.roster_set_entry(v_wk, 'beta', v_a2, v_wk, 'shift', '12:00', '20:00', null, null);
      raise exception 'FAIL B7: a2 was planned twice on the same date';
    exception when sqlstate 'CMA03' then null;
    end;
    e := cma.roster_set_entry(v_wk, 'alpha', v_a2, v_wk, null, null, null, null, null);
    if e.id is not null then
      raise exception 'FAIL B7: clearing a cell returned an entry';
    end if;
    e := cma.roster_set_entry(v_wk, 'beta', v_a2, v_wk, 'shift', '12:00', '20:00', null, null);
    if e.id is null or e.kind <> 'shift' then
      raise exception 'FAIL B7: beta could not plan a2 after alpha cleared the cell';
    end if;

    -- B8. today's shift for the board: a tenant-wide roster of this week with a3 on shift today
    --     (today is in this week), published; the supervisor reads it, an agent may not
    e := cma.roster_set_entry(v_this, null, v_a3, v_today, 'shift', '08:00', '16:00', null, null);
    w := cma.roster_publish(v_this, null);
    perform set_config('app.user_id', v_sup::text, true);
    select string_agg(x.user_id::text || ':' || x.is_published || ':' || coalesce(x.kind, '-') || ':' || coalesce(x.start_time::text, ''), '; ') into v_text
    from cma.roster_today() x where x.user_id in (v_a3, v_a1);
    if (select count(*) from cma.roster_today()) <> 5
       or v_text not like '%' || v_a3 || ':true:shift:08:00:00%' or v_text not like '%' || v_a1 || ':true:-:%' then
      raise exception 'FAIL B8: roster_today reads [%]', v_text;
    end if;
    perform set_config('app.user_id', v_a1::text, true);
    begin
      perform cma.roster_today();
      raise exception 'FAIL B8: an agent read everyone''s shift of today';
    exception when sqlstate 'CMA06' then null;
    end;

    -- B9. coverage on alpha's week: on v_wk only a1 is on shift (a2 moved to beta), holding wt1;
    --     a target of two for wt1 on Mondays shows next to it; a target needs a team
    perform set_config('app.user_id', v_mgr::text, true);
    perform cma.set_coverage_target('alpha', 'wt1', 1::smallint, 2);
    select string_agg(c.skill_key || ':' || c.planned_people || ':' || array_to_string(c.people_names, '+') || ':' || coalesce(c.target::text, '-'), '; ' order by c.skill_key) into v_text
    from cma.roster_coverage(v_wk, 'alpha') c where c.business_date = v_wk;
    if v_text is distinct from 'wt1:1:Verify A1:2; wt2:0::-' then
      raise exception 'FAIL B9: coverage on Monday reads [%]', v_text;
    end if;
    select string_agg(ct.skill_key || '/' || ct.weekday || '=' || ct.min_count, ',') into v_text from cma.coverage_targets('alpha') ct;
    if v_text is distinct from 'wt1/1=2' then
      raise exception 'FAIL B9: coverage_targets reads [%]', v_text;
    end if;
    begin
      perform cma.set_coverage_target(null, 'wt1', 1::smallint, 2);
      raise exception 'FAIL B9: a coverage target without a team was accepted';
    exception when sqlstate 'CMA04' then null;
    end;

    -- B10. copying a week: alpha's two current cells land on v_wk + 7; the week list shows the states
    v_n := cma.roster_copy_week(v_wk, v_wk + 7, 'alpha');
    select count(*) into v_n2 from cma.roster_entries(v_wk + 7, 'alpha');
    if v_n <> 2 or v_n2 <> 2 then
      raise exception 'FAIL B10: copying wrote % cells, the target week has %', v_n, v_n2;
    end if;
    select string_agg(x.week_start || ':' || x.status || ':' || x.version || ':' || x.entry_count, '; ' order by x.week_start) into v_text
    from cma.roster_weeks('alpha', v_wk, v_wk + 7) x;
    if v_text is distinct from v_wk || ':published:2:2; ' || (v_wk + 7) || ':draft:0:2' then
      raise exception 'FAIL B10: the week list reads [%]', v_text;
    end if;

    -- B11. the absence catalog: any person reads the five defaults; only tenant.configure changes it
    perform set_config('app.user_id', v_a1::text, true);
    select string_agg(a.key, ',' order by a.sort_order) into v_text from cma.absence_types() a;
    if v_text is distinct from 'off,leave,sick,public_holiday,other' then
      raise exception 'FAIL B11: the absence types read [%]', v_text;
    end if;
    begin
      perform cma.upsert_absence_type('training_day', 'Training day', true, 60);
      raise exception 'FAIL B11: an agent changed the absence catalog';
    exception when sqlstate 'CMA06' then null;
    end;
    perform set_config('app.user_id', v_mgr::text, true);
    begin
      perform cma.upsert_absence_type('training_day', 'Training day', true, 60);
      raise exception 'FAIL B11: a manager without tenant.configure changed the absence catalog';
    exception when sqlstate 'CMA06' then null;
    end;

    -- B12. tenant two sees none of it
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_mgr_t2::text, true);
    select count(*) filter (where x.entry_count > 0) into v_n from cma.roster_weeks(null, v_wk - 7, v_wk + 7) x;
    select count(*) filter (where x.kind is not null) into v_n2 from cma.roster_today() x;
    if v_n <> 0 or v_n2 <> 0 then
      raise exception 'FAIL B12: tenant two sees % weeks with entries and % shifts today', v_n, v_n2;
    end if;

    -- B13. no acting user
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', '', true);
    begin
      perform cma.absence_types();
      raise exception 'FAIL B13: the absence types were read without an acting user';
    exception when sqlstate 'CMA01' then null;
    end;
    begin
      perform cma.roster_week(v_wk, 'alpha');
      raise exception 'FAIL B13: the planner was read without an acting user';
    exception when sqlstate 'CMA01' then null;
    end;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- Verdict: per tenant, the roles that plan and the roles that read a roster, the absence types
select t.slug as tenant,
       coalesce((select string_agg(ar.key, ', ' order by ar.key) from cma.app_role ar
                 where ar.tenant_id = t.id and exists (select 1 from cma.role_permission rp
                   where rp.tenant_id = ar.tenant_id and rp.role_id = ar.id and rp.permission_key = 'roster.manage')), '(none)') as roles_with_roster_manage,
       coalesce((select string_agg(ar.key, ', ' order by ar.key) from cma.app_role ar
                 where ar.tenant_id = t.id and exists (select 1 from cma.role_permission rp
                   where rp.tenant_id = ar.tenant_id and rp.role_id = ar.id and rp.permission_key = 'roster.view')), '(none)') as roles_with_roster_view,
       (select count(*) from cma.absence_type a where a.tenant_id = t.id and a.status = 'active') as absence_types,
       (select count(*) from cma.roster_week w where w.tenant_id = t.id) as roster_weeks,
       case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS' else 'PASS' end as verdict
from cma.tenant t
where t.status = 'active'
order by t.slug;
