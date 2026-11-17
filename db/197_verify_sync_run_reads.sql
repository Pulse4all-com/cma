-- =============================================================================================
-- 197_verify_sync_run_reads.sql: verifies addition 0009x, prod's slowdown part 2 (the sync_run reads of Data quality, the
-- Flash landing and System health)
-- =============================================================================================
-- Universal: no seed is assumed, so it runs in dev and in prod. Reads every active tenant as the application (cma_app,
-- row-level security on, as the tenant's first active person holding tenant.configure), and writes runs on one throwaway
-- tenant in a step that is always rolled back. Run as your own IAM login, after 196. Output: tenant slugs, job names,
-- counts and milliseconds only.
-- The previous definitions are kept below as pg_temp functions, copied unchanged from 148_installed_base_list.sql
-- (cma.flash_sources_of) and 132_perf.sql (cma.system_health_runs), and every answer is compared with theirs at the
-- same instant and on the same rows: both in one statement, so one snapshot (the functions are stable), whatever the
-- jobs write meanwhile.
--
-- Checks
--   S1  the addition 0009x is recorded once, after 0009w
--   S2  cma.sync_run_hour: fillfactor 50, row-level security, the tenant policy, no audit trigger, the application reads only; the
--       readers' view cma_read.sync_run_hour; cma.sync_run_hour_count() cma_owner's, owner's rights, search path pinned
--       with pg_temp last, executable by no one but its owner; the readers read the view, not the table; the triggers sync_run_hour (after insert or delete) and
--       sync_run_hour_change (after update, with its condition) on cma.sync_run, enabled; the three indexes valid
--       and as 196's header defines them; sync_run's autovacuum scale factors 0.02
--   S3  cma.flash_sources_of and cma.system_health_runs in the caller's rights, stable, the application's to execute
--       (not public's); system_health_runs says 50 rows
--   H1  cma.sync_run_hour holds exactly cma.sync_run grouped by tenant, job, connection and UTC hour (every tenant):
--       no key missing, none extra, no count differing
--   E1  per active tenant: cma.flash_sources_of equals 148's definition
--   E2  per active tenant, as the application: cma.system_health_runs() equals 132's definition, row for row, in order
--   B1  on a throwaway tenant, rolled back: runs at the edges (just before and after the 24 hours' start, in its hour, a
--       run started 31 days ago and finished now, one without a connection, one running), finished into succeeded and
--       failed, one deleted, and two started and finished as the application (cma_app, the role the ingest and the
--       scheduler write with); the hours equal the runs grouped, and both reads equal the previous definitions
--   B2  the throwaway tenant and its rows are gone
--   T1  per active tenant, as the application: cma.flash_sources_of within verify.max_sources_ms (50), the best of three
--       after six calls (a plpgsql statement turns to its generic plan after five). Its sync_run part is one index probe
--       per connection (0.2 ms locally at 3x); most of the rest is 148's kinds of the connections (cma.connection_held_kinds_of
--       reads device per connection), unchanged here and part of the next brief (the device scans)
--   T2  per active tenant, as the application: cma.system_health_runs() within verify.max_read_ms (10), likewise
-- Provoke: verify.provoke below. 'true': every check reads FAIL and the verdict says PROVOKED, NOT A PASS. A check's id:
-- that check alone compares with a deliberate difference (the new answer with one more run, or a budget of 0).
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
select set_config('verify.provoke', 'false', false);                 -- 'true' for every check, or one check's id such as 'E2'
select set_config('verify.max_read_ms', '10', false);                -- System health's read (the brief: the sync_run part in single-digit ms)
select set_config('verify.max_sources_ms', '50', false);             -- flash_sources_of whole: its sync_run part is about 0.2 ms (36 index
                                                                     -- probes at 3x); the rest is 148's kinds (connection_held_kinds_of)

drop table if exists pg_temp.verify_0009x;
create temporary table verify_0009x (ord integer, check_name text, result text, detail text);
grant select, insert on pg_temp.verify_0009x to cma_app;

create or replace function pg_temp.v0009x_p(p_id text)
returns boolean
language sql stable
as $$
  select current_setting('verify.provoke') in ('true', p_id)
$$;

create or replace function pg_temp.v0009x_user(p_tenant uuid, p_perm text)
returns uuid
language sql
as $$
  select u.id from cma.app_user u
  where u.tenant_id = p_tenant and u.status = 'active' and u.kind = 'person' and cma.has_permission(u.id, p_perm)
  order by u.created_at, u.id limit 1
$$;

-- The hours that differ from cma.sync_run grouped, for one tenant or all (null): 'key: hours runs/failed, runs runs/failed'
create or replace function pg_temp.v0009x_hours_diff(p_tenant uuid)
returns text
language sql stable
as $$
  with g as (
    select r.tenant_id, r.job, r.connection_id, date_trunc('hour', r.started_at, 'UTC') as hour, count(*)::integer as runs,
           (count(*) filter (where r.status = 'failed'))::integer as failed
    from cma.sync_run r where p_tenant is null or r.tenant_id = p_tenant
    group by 1, 2, 3, 4
  ), h as (
    select x.tenant_id, x.job, x.connection_id, x.hour, x.runs, x.failed from cma.sync_run_hour x
    where (p_tenant is null or x.tenant_id = p_tenant) and (x.runs > 0 or x.failed > 0)
  )
  select string_agg(coalesce(g.job, h.job) || ' ' || to_char(coalesce(g.hour, h.hour) at time zone 'UTC', 'YYYY-MM-DD HH24')
                    || ': hours ' || coalesce(h.runs || '/' || h.failed, 'none') || ', runs ' || coalesce(g.runs || '/' || g.failed, 'none'),
                    '; ' order by coalesce(g.job, h.job) collate "C", coalesce(g.hour, h.hour))
  from g
  full join h on h.tenant_id = g.tenant_id and h.job = g.job and h.connection_id is not distinct from g.connection_id and h.hour = g.hour
  where g.runs is distinct from h.runs or g.failed is distinct from h.failed
$$;

-- The previous definitions, unchanged but for their names
-- from 148_installed_base_list.sql
create or replace function pg_temp.v0009x_old_sources_of(p_tenant_id uuid)
returns jsonb
language sql stable
as $$
  with c as (
    select ic.id, ic.adapter,
           case when ic.kind is not null then ic.kind
                when exists (select 1 from cma.commerce_store x where x.tenant_id = ic.tenant_id and x.connection_id = ic.id) then 'commerce'
                else (cma.connection_held_kinds_of(ic.tenant_id, ic.id))[1] end as kind
    from cma.integration_connection ic
    where ic.tenant_id = p_tenant_id and ic.status = 'active'
  ), k as (
    select x.kind, array_agg(distinct c.adapter order by c.adapter) filter (where c.id is not null) as adapters,
           (select max(r.finished_at) from cma.sync_run r
            where r.tenant_id = p_tenant_id and r.status = 'succeeded' and r.connection_id in (select c2.id from c c2 where c2.kind = x.kind)) as last_read_at
    from unnest(array['commerce', 'subscriptions', 'assets', 'crm', 'reviews']) x(kind)
    left join c on c.kind = x.kind
    group by x.kind
  )
  select jsonb_object_agg(k.kind, jsonb_build_object(
           'set_up', cma.flash_source_set_up_of(p_tenant_id, k.kind),
           'adapters', coalesce(to_jsonb(k.adapters), '[]'::jsonb),
           'last_read_at', k.last_read_at))
  from k
$$;

-- from 132_perf.sql
create or replace function pg_temp.v0009x_old_health_runs()
returns table(
  job text, connection_id uuid,
  last_started_at timestamptz, last_finished_at timestamptz, last_status text, last_error text, last_counts jsonb,
  last_succeeded_at timestamptz, last_failed_at timestamptz, last_failed_error text,
  runs_24h integer, failed_24h integer)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_tenant uuid := cma.current_tenant_id();
  v_agg    jsonb;
  v_bad    jsonb;
begin
  perform cma.assert_permission('tenant.configure');
  -- one pass over the 30 days' runs, grouped, into a variable: a select into may run in parallel, a return query (a
  -- cursor) may not (measured: 140 ms against 1,250 ms on 360,000 runs, night N06); the latest failed run's id from a
  -- second pass over the failed runs alone (an ordered aggregate sorts its whole input: over every run it cost a sort
  -- to disk, over the failed ones, one in a hundred, it costs nothing)
  select coalesce(jsonb_agg(jsonb_build_object('job', a.job, 'connection_id', a.connection_id, 'last_started', a.last_started,
                                               'ok_at', a.ok_at, 'runs', a.runs, 'failed', a.failed)), '[]'::jsonb)
    into v_agg
  from (select r.job, r.connection_id,
               max(r.started_at) as last_started,
               max(r.finished_at) filter (where r.status = 'succeeded') as ok_at,
               (count(*) filter (where r.started_at > now() - interval '24 hours'))::integer as runs,
               (count(*) filter (where r.started_at > now() - interval '24 hours' and r.status = 'failed'))::integer as failed
        from cma.sync_run r
        where r.tenant_id = v_tenant and r.started_at > now() - interval '30 days'
        group by 1, 2) a;
  select coalesce(jsonb_object_agg(coalesce(b.connection_id::text, '') || '/' || b.job, b.bad_id), '{}'::jsonb)
    into v_bad
  from (select r.job, r.connection_id, (array_agg(r.id order by r.finished_at desc, r.id desc))[1] as bad_id
        from cma.sync_run r
        where r.tenant_id = v_tenant and r.started_at > now() - interval '30 days' and r.status = 'failed'
        group by 1, 2) b;
  return query
    with agg as (
      select (x ->> 'job') as job, (x ->> 'connection_id')::uuid as connection_id, (x ->> 'last_started')::timestamptz as last_started,
             (x ->> 'ok_at')::timestamptz as ok_at, (v_bad ->> (coalesce(x ->> 'connection_id', '') || '/' || (x ->> 'job')))::uuid as bad_id,
             (x ->> 'runs')::integer as runs, (x ->> 'failed')::integer as failed
      from jsonb_array_elements(v_agg) x)
    select a.job, a.connection_id, l.started_at, l.finished_at, l.status, l.error, l.counts,
           a.ok_at, b.finished_at, b.error, a.runs, a.failed
    from agg a
    -- the latest run (started_at desc, id desc): one index lookup at its instant (sync_run_started_idx)
    cross join lateral (select r.started_at, r.finished_at, r.status, r.error, r.counts
                        from cma.sync_run r
                        where r.tenant_id = v_tenant and r.connection_id is not distinct from a.connection_id and r.job = a.job
                          and r.started_at = a.last_started
                        order by r.id desc limit 1) l
    -- the latest failed run, by its id
    left join cma.sync_run b on b.tenant_id = v_tenant and b.id = a.bad_id
    order by a.job, a.connection_id;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- S1, S2, S3, H1
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_txt text;
  v_bad text := '';
  v_cfg text;
begin
  -- S1
  select format('0009x %s time(s), after 0009w %s', count(*) filter (where m.version = '0009x'),
                coalesce((max(m.applied_at) filter (where m.version = '0009x') > max(m.applied_at) filter (where m.version = '0009w'))::text, 'no'))
    into v_txt
  from cma.schema_migration m where m.version in ('0009w', '0009x');
  insert into pg_temp.verify_0009x values (1, 'S1 the addition 0009x is recorded once, after 0009w',
    case when v_txt = '0009x 1 time(s), after 0009w true' and not pg_temp.v0009x_p('S1') then 'PASS' else 'FAIL' end, v_txt);

  -- S2
  if not (select c.relrowsecurity from pg_class c where c.oid = 'cma.sync_run_hour'::regclass) then v_bad := v_bad || 'no row-level security; '; end if;
  if not exists (select 1 from pg_policy p where p.polrelid = 'cma.sync_run_hour'::regclass and p.polname = 'tenant_app') then v_bad := v_bad || 'no tenant policy; '; end if;
  if exists (select 1 from pg_trigger g where g.tgrelid = 'cma.sync_run_hour'::regclass and not g.tgisinternal) then v_bad := v_bad || 'a trigger on the hours; '; end if;
  if not has_table_privilege('cma_app', 'cma.sync_run_hour', 'select') or has_table_privilege('cma_app', 'cma.sync_run_hour', 'insert')
     or has_table_privilege('cma_app', 'cma.sync_run_hour', 'update') or has_table_privilege('cma_app', 'cma.sync_run_hour', 'delete') then
    v_bad := v_bad || 'the application''s rights; ';
  end if;
  if (select array_to_string(array(select o from unnest(c.reloptions) o order by o collate "C"), ',') from pg_class c where c.oid = 'cma.sync_run'::regclass)
       is distinct from 'autovacuum_vacuum_insert_scale_factor=0.02,autovacuum_vacuum_scale_factor=0.02'
     or (select array_to_string(c.reloptions, ',') from pg_class c where c.oid = 'cma.sync_run_hour'::regclass) is distinct from 'fillfactor=50' then
    v_bad := v_bad || 'the storage parameters of sync_run or sync_run_hour; ';
  end if;
  if to_regclass('cma_read.sync_run_hour') is null or not has_table_privilege('cma_readonly', 'cma_read.sync_run_hour', 'select')
     or has_table_privilege('cma_readonly', 'cma.sync_run_hour', 'select') then
    v_bad := v_bad || 'the readers'' view or rights; ';
  end if;
  select array_to_string(p.proconfig, ',') into v_cfg from pg_proc p where p.oid = 'cma.sync_run_hour_count()'::regprocedure;
  if not (select p.prosecdef and pg_get_userbyid(p.proowner) = 'cma_owner' from pg_proc p where p.oid = 'cma.sync_run_hour_count()'::regprocedure)
     or coalesce(v_cfg, '') !~ '^search_path=.*pg_temp$'
     or has_function_privilege('cma_app', 'cma.sync_run_hour_count()', 'execute') or has_function_privilege('public', 'cma.sync_run_hour_count()', 'execute') then
    v_bad := v_bad || 'the trigger function''s rights or search path; ';
  end if;
  select string_agg(g.tgname || ':' || concat_ws('+', case when g.tgtype & 4 <> 0 then 'insert' end, case when g.tgtype & 16 <> 0 then 'update' end,
                                                 case when g.tgtype & 8 <> 0 then 'delete' end)
                    || case when g.tgqual is not null then ':when' else '' end || case when g.tgenabled = 'D' then ':disabled' else '' end,
                    ',' order by g.tgname collate "C")
    into v_txt
  from pg_trigger g where g.tgrelid = 'cma.sync_run'::regclass and not g.tgisinternal and g.tgfoid = 'cma.sync_run_hour_count()'::regprocedure;
  if v_txt is distinct from 'sync_run_hour:insert+delete,sync_run_hour_change:update:when' then v_bad := v_bad || 'the triggers ' || coalesce(v_txt, 'none') || '; '; end if;
  if (select count(*) from pg_index i join pg_class c on c.oid = i.indexrelid
      where i.indrelid = 'cma.sync_run'::regclass and i.indisvalid
        and pg_get_indexdef(c.oid) in (
          'CREATE INDEX sync_run_succeeded_idx ON cma.sync_run USING btree (tenant_id, connection_id, finished_at DESC) WHERE (status = ''succeeded''::text)',
          'CREATE INDEX sync_run_job_started_idx ON cma.sync_run USING btree (tenant_id, job, connection_id, started_at DESC, id DESC)',
          'CREATE INDEX sync_run_job_finished_idx ON cma.sync_run USING btree (tenant_id, job, connection_id, status, finished_at DESC, id DESC) INCLUDE (started_at) WHERE (status = ANY (ARRAY[''succeeded''::text, ''failed''::text]))')) <> 3 then
    v_bad := v_bad || 'an index missing, invalid or defined otherwise; ';
  end if;
  insert into pg_temp.verify_0009x values (2, 'S2 the hours, their trigger function, triggers and view; the three indexes valid',
    case when v_bad = '' and not pg_temp.v0009x_p('S2') then 'PASS' else 'FAIL' end, coalesce(nullif(v_bad, ''), 'as designed'));

  -- S3
  v_bad := '';
  if exists (select 1 from pg_proc p where p.oid in ('cma.flash_sources_of(uuid)'::regprocedure, 'cma.system_health_runs()'::regprocedure)
             and (p.prosecdef or p.provolatile <> 's')) then v_bad := v_bad || 'rights or volatility; '; end if;
  if not has_function_privilege('cma_app', 'cma.flash_sources_of(uuid)', 'execute') or not has_function_privilege('cma_app', 'cma.system_health_runs()', 'execute')
     or exists (select 1 from pg_proc p cross join lateral aclexplode(p.proacl) a
                where p.oid in ('cma.flash_sources_of(uuid)'::regprocedure, 'cma.system_health_runs()'::regprocedure) and a.grantee = 0) then
    v_bad := v_bad || 'grants; ';
  end if;
  if (select p.prorows from pg_proc p where p.oid = 'cma.system_health_runs()'::regprocedure) <> 50 then v_bad := v_bad || 'rows; '; end if;
  insert into pg_temp.verify_0009x values (3, 'S3 the two reads: caller''s rights, stable, the application''s; 50 rows said',
    case when v_bad = '' and not pg_temp.v0009x_p('S3') then 'PASS' else 'FAIL' end, coalesce(nullif(v_bad, ''), 'as designed'));

  -- H1
  v_txt := pg_temp.v0009x_hours_diff(null);
  insert into pg_temp.verify_0009x values (4, 'H1 cma.sync_run_hour equals cma.sync_run grouped by tenant, job, connection and UTC hour',
    case when v_txt is null and not pg_temp.v0009x_p('H1') then 'PASS' else 'FAIL' end,
    coalesce('differing: ' || left(v_txt, 500), (select count(*) from cma.sync_run_hour) || ' hours, ' || (select count(*) from cma.sync_run) || ' runs'));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- E1, E2, T1, T2 per active tenant, as the application
-- ---------------------------------------------------------------------------------------------
do $$
declare
  t      record;
  v_user uuid;
  v_ord  integer := 10;
  v_new  text;
  v_old  text;
  v_n    integer;
  v_t0   timestamptz;
  v_best numeric;
  v_ms   numeric;
  i      integer;
  v_sum  text;
begin
  for t in select x.id, x.slug from cma.tenant x where x.status = 'active' order by x.slug collate "C" loop
    v_ord := v_ord + 10;
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.tenant_id', t.id::text, true);
    perform set_config('app.user_id', '', true);
    v_user := pg_temp.v0009x_user(t.id, 'tenant.configure');
    if v_user is null then
      insert into pg_temp.verify_0009x values (v_ord, 'E ' || t.slug, case when current_setting('verify.provoke') <> 'false' then 'FAIL' else 'skip' end,
        'no active person holds tenant.configure: nothing compared');
      continue;
    end if;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_user::text, true);

    -- E1
    -- both in one statement: one snapshot, so a run written meanwhile (prod's jobs write every minute) is seen by both or
    -- neither (the functions are stable: they take the calling statement's snapshot)
    select cma.flash_sources_of(t.id)::text, pg_temp.v0009x_old_sources_of(t.id)::text into v_new, v_old;
    if pg_temp.v0009x_p('E1') then v_new := v_new || ' '; end if;
    insert into pg_temp.verify_0009x values (v_ord + 1, 'E1 ' || t.slug || ': cma.flash_sources_of equals 148''s',
      case when v_new = v_old then 'PASS' else 'FAIL' end,
      (select string_agg(k || ' ' || coalesce(v_old::jsonb -> k ->> 'last_read_at', 'none'), '; ' order by k collate "C") from jsonb_object_keys(v_old::jsonb) k));

    -- E2
    -- both in one statement, as E1
    select (select count(*) from cma.system_health_runs()),
           (select string_agg(x::text, E'\n' order by x.n) from (select row_number() over () as n, s.* from cma.system_health_runs() s) x),
           (select string_agg(x::text, E'\n' order by x.n) from (select row_number() over () as n, s.* from pg_temp.v0009x_old_health_runs() s) x)
      into v_n, v_new, v_old;
    if pg_temp.v0009x_p('E2') then v_new := coalesce(v_new, '') || E'\nprovoked'; end if;
    select string_agg(s.job || ' ' || s.runs_24h || '/' || s.failed_24h, ', ' order by s.job collate "C", s.connection_id) into v_sum
    from cma.system_health_runs() s;
    insert into pg_temp.verify_0009x values (v_ord + 2, 'E2 ' || t.slug || ': cma.system_health_runs() equals 132''s, row for row, in order',
      case when v_new is not distinct from v_old then 'PASS' else 'FAIL' end,
      format('%s rows; runs/failed in 24 hours: %s', v_n, coalesce(v_sum, 'none')));

    -- T1: nine calls, the best of the last three (calls 7 to 9)
    v_best := null;
    for i in 1..9 loop
      v_t0 := clock_timestamp();
      perform cma.flash_sources_of(t.id)::text;
      v_ms := round(extract(epoch from clock_timestamp() - v_t0)::numeric * 1000, 1);
      if i > 6 then v_best := least(coalesce(v_best, v_ms), v_ms); end if;
    end loop;
    insert into pg_temp.verify_0009x values (v_ord + 3, 'T1 ' || t.slug || ': cma.flash_sources_of within its budget',
      case when v_best <= case when pg_temp.v0009x_p('T1') then 0 else current_setting('verify.max_sources_ms')::numeric end then 'PASS' else 'FAIL' end,
      format('%s ms (best of 3, after six calls) against %s ms', v_best, case when pg_temp.v0009x_p('T1') then '0' else current_setting('verify.max_sources_ms') end));

    -- T2
    v_best := null;
    for i in 1..9 loop
      v_t0 := clock_timestamp();
      perform count(*) from cma.system_health_runs();
      v_ms := round(extract(epoch from clock_timestamp() - v_t0)::numeric * 1000, 1);
      if i > 6 then v_best := least(coalesce(v_best, v_ms), v_ms); end if;
    end loop;
    insert into pg_temp.verify_0009x values (v_ord + 4, 'T2 ' || t.slug || ': cma.system_health_runs() within its budget',
      case when v_best <= case when pg_temp.v0009x_p('T2') then 0 else current_setting('verify.max_read_ms')::numeric end then 'PASS' else 'FAIL' end,
      format('%s ms (best of 3, after six calls) against %s ms', v_best, case when pg_temp.v0009x_p('T2') then '0' else current_setting('verify.max_read_ms') end));
  end loop;
  perform set_config('role', 'cma_owner', true);
  perform set_config('app.user_id', '', true);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- B1, B2: the edges, on a throwaway tenant, rolled back
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_t     uuid;
  v_c     uuid;
  v_d     uuid;
  v_user  uuid;
  v_run   uuid;
  v_gone  uuid;
  v_res   text;
  v_txt   text;
  v_hours text;
  v_new   text;
  v_old   text;
  v_snew  text;
  v_sold  text;
  v_edge  timestamptz := now() - interval '24 hours';
begin
  begin
    v_t := cma.create_tenant('verify-0009x', 'Verify 0009x', 'Europe/Amsterdam');
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t, 'verifycrm', 'Verify CRM', 'portal-0009x', 'crm') returning id into v_c;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t, 'verifyshop', 'Verify shop', 'shop-0009x', 'commerce') returning id into v_d;
    -- runs at the 24 hours' start and in its hour, either side; finished ones straight away, as a load does
    insert into cma.sync_run (tenant_id, connection_id, job, started_at, finished_at, status, error) values
      (v_t, v_c, 'forms_poll', v_edge - interval '1 second', v_edge, 'succeeded', null),
      (v_t, v_c, 'forms_poll', v_edge + interval '1 second', v_edge + interval '2 seconds', 'failed', 'verify'),
      (v_t, v_c, 'forms_poll', v_edge + interval '20 minutes', v_edge + interval '21 minutes', 'succeeded', null),
      (v_t, v_c, 'forms_poll', v_edge + interval '70 minutes', v_edge + interval '71 minutes', 'failed', 'verify'),
      (v_t, v_c, 'forms_poll', now() - interval '1 hour', now() - interval '59 minutes', 'succeeded', null),
      -- a run started 31 days ago that finished now: the latest finish of its pair, but not one of the 30 days
      (v_t, v_c, 'reconcile', now() - interval '31 days', now(), 'succeeded', null),
      (v_t, v_c, 'reconcile', now() - interval '29 days', now() - interval '29 days' + interval '1 minute', 'succeeded', null),
      (v_t, v_c, 'reconcile', now() - interval '28 days', now() - interval '28 days' + interval '1 minute', 'failed', 'verify'),
      -- a pair whose runs are all older than the 30 days: not listed
      (v_t, v_d, 'reconcile', now() - interval '40 days', now() - interval '40 days' + interval '1 minute', 'succeeded', null),
      -- no connection: the scheduler's
      (v_t, null, 'refresh_follow_up', now() - interval '2 hours', now() - interval '2 hours' + interval '1 second', 'succeeded', null),
      (v_t, null, 'refresh_follow_up', now() - interval '3 hours', now() - interval '3 hours' + interval '1 second', 'failed', 'verify'),
      -- two runs without a connection in the hour of the 24 hours' start, either side of it (one hour row, counted twice)
      (v_t, null, 'refresh_data_quality', v_edge - interval '1 second', v_edge, 'succeeded', null),
      (v_t, null, 'refresh_data_quality', v_edge + interval '1 second', v_edge + interval '2 seconds', 'failed', 'verify');
    -- the shop's newest succeeded finish older than its others' starts: last_read_at is the latest finish, not the latest start
    insert into cma.sync_run (tenant_id, connection_id, job, started_at, finished_at, status) values
      (v_t, v_d, 'subscriptions_poll', now() - interval '5 hours', now() - interval '1 hour', 'succeeded'),
      (v_t, v_d, 'subscriptions_poll', now() - interval '3 hours', now() - interval '170 minutes', 'succeeded');
    -- started, then finished: into failed (counted), into succeeded (nothing to count); one still running; one deleted
    insert into cma.sync_run (tenant_id, connection_id, job, started_at) values (v_t, v_c, 'email_poll', now() - interval '10 minutes') returning id into v_run;
    update cma.sync_run set status = 'failed', finished_at = now(), error = 'verify' where tenant_id = v_t and id = v_run;
    insert into cma.sync_run (tenant_id, connection_id, job, started_at) values (v_t, v_c, 'email_poll', now() - interval '5 minutes') returning id into v_run;
    update cma.sync_run set status = 'succeeded', finished_at = now() where tenant_id = v_t and id = v_run;
    insert into cma.sync_run (tenant_id, connection_id, job, started_at) values (v_t, v_c, 'email_poll', now() - interval '1 minute');
    insert into cma.sync_run (tenant_id, connection_id, job, started_at, finished_at, status) values
      (v_t, v_c, 'email_poll', now() - interval '2 minutes', now(), 'failed') returning id into v_gone;
    delete from cma.sync_run where tenant_id = v_t and id = v_gone;

    perform set_config('app.tenant_id', v_t::text, true);
    v_user := (select u.id from cma.app_user u where u.tenant_id = v_t and u.kind = 'person' order by u.created_at limit 1);
    if v_user is null then
      -- create_tenant makes no person: the step makes one admin to write and read as (rolled back)
      insert into cma.app_user (tenant_id, email, display_name, kind, status) values (v_t, 'verify.0009x@example.invalid', 'Verify 0009x', 'person', 'active')
      returning id into v_user;
      insert into cma.user_role (tenant_id, user_id, role_id)
      select v_t, v_user, r.id from cma.app_role r where r.tenant_id = v_t and r.key = 'admin';
    end if;
    -- runs written as the application, the role the ingest and the scheduler write with: the trigger function's owner's
    -- rights are what let their counts reach cma.sync_run_hour, which the application may not write
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_user::text, true);
    insert into cma.sync_run (connection_id, job, started_at) values (v_c, 'link_calls', now() - interval '40 seconds') returning id into v_run;
    update cma.sync_run set status = 'failed', finished_at = now(), error = 'verify' where id = v_run;
    insert into cma.sync_run (connection_id, job, started_at) values (v_c, 'link_calls', now() - interval '20 seconds') returning id into v_run;
    update cma.sync_run set status = 'succeeded', finished_at = now() where id = v_run;
    perform set_config('role', 'cma_owner', true);
    v_hours := pg_temp.v0009x_hours_diff(v_t);
    perform set_config('role', 'cma_app', true);
    select cma.flash_sources_of(v_t)::text, pg_temp.v0009x_old_sources_of(v_t)::text,
           (select string_agg(x::text, E'\n' order by x.n) from (select row_number() over () as n, s.* from cma.system_health_runs() s) x),
           (select string_agg(x::text, E'\n' order by x.n) from (select row_number() over () as n, s.* from pg_temp.v0009x_old_health_runs() s) x)
      into v_new, v_old, v_snew, v_sold;
    select string_agg(s.job || coalesce(' ' || case when s.connection_id = v_c then 'crm' when s.connection_id = v_d then 'shop' end, '') || ' ' || s.runs_24h || '/' || s.failed_24h
                      || ' ok ' || (s.last_succeeded_at is not null) || ' bad ' || (s.last_failed_at is not null),
                      ', ' order by s.job collate "C", s.connection_id)
      into v_txt
    from cma.system_health_runs() s;
    perform set_config('role', 'cma_owner', true);
    if pg_temp.v0009x_p('B1') then v_snew := v_snew || ' '; end if;
    v_res := case when v_hours is null and v_new = v_old and v_snew is not distinct from v_sold then 'PASS' else 'FAIL' end;
    v_txt := coalesce(v_txt, 'no row') || case when v_hours is not null then '; hours differing: ' || v_hours else '' end
             || case when v_new <> v_old then '; sources differ' else '' end
             || case when v_snew is distinct from v_sold then '; health runs differ' else '' end;
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_res := 'FAIL';
      v_txt := 'the step stopped: ' || sqlstate || ' ' || sqlerrm;
  end;
  perform set_config('role', 'cma_owner', true);
  perform set_config('app.user_id', '', true);
  insert into pg_temp.verify_0009x values (900, 'B1 the edges: the hours, the sources and the health runs equal the runs and the previous definitions',
    coalesce(v_res, 'FAIL'), coalesce(v_txt, 'no result'));
  insert into pg_temp.verify_0009x values (901, 'B2 the throwaway tenant and its rows are gone',
    case when not exists (select 1 from cma.tenant where slug = 'verify-0009x') and not exists (select 1 from cma.sync_run_hour h where not exists (select 1 from cma.tenant x where x.id = h.tenant_id))
              and not pg_temp.v0009x_p('B2') then 'PASS' else 'FAIL' end,
    (select count(*) from cma.tenant where slug = 'verify-0009x') || ' tenant(s) verify-0009x');
end
$$;

drop function if exists pg_temp.v0009x_old_health_runs();
drop function if exists pg_temp.v0009x_old_sources_of(uuid);
drop function if exists pg_temp.v0009x_hours_diff(uuid);
drop function if exists pg_temp.v0009x_user(uuid, text);
drop function if exists pg_temp.v0009x_p(text);

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0009x
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke') <> 'false' then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0009x where result = 'FAIL') then 'FAIL'
                  when not exists (select 1 from pg_temp.verify_0009x where result = 'PASS') then 'FAIL'
                  else 'PASS' end,
             format('197_verify_sync_run_reads: %s PASS, %s FAIL, %s skip', (select count(*) from pg_temp.verify_0009x where result = 'PASS'),
                    (select count(*) from pg_temp.verify_0009x where result = 'FAIL'), (select count(*) from pg_temp.verify_0009x where result = 'skip'))) x
order by ord, check_name collate "C";
drop table if exists pg_temp.verify_0009x;
reset role;
