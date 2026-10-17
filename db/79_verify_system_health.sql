-- =============================================================================================
-- 79_verify_system_health.sql: verifies addition 0008r, what System health reads and the scheduler's row
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure
-- and privileges; block B works on two throwaway tenants inside a subtransaction that is always
-- rolled back. Universal otherwise: nothing of the seed is used; adapters, users and runs are invented
-- data values, and no row carries anything personal. Every check writes one row, PASS or FAIL, and the
-- last result lists them with the verdict, because Cloud SQL Studio shows no notices.
-- Run as your own IAM login in dev, after 78_system_health.sql; then 33 and 73 again.
--   A  structure and privileges: the addition row after 0008p; the two heartbeat settings with their
--      defaults and type; the three functions the application's only, in the caller's rights, the read
--      stable; sync_run's job list holding close_forgotten_workdays and the index on the tenant's runs
--   B  behaviour on two throwaway tenants: the Scheduler user starts and finishes a run (one row, the
--      count of days closed), a second finish is refused (CMA03), an unknown run (CMA02) and a bad status
--      (CMA04) too; an admin without workday.close_forgotten cannot start one (CMA06); the read sums the
--      runs per job and connection (the last run, the last success, the last failure with its error, the
--      last 24 hours' counts) and shows the ingest's link_calls row with its connection next to the
--      scheduler's row without one; an agent and the Ingest user cannot read it (CMA06), nor can a read
--      without an acting user (CMA01); tenant two sees nothing of tenant one; the settings' defaults, a
--      fresh threshold at or above the late one refused and the other way round, a non-integer refused,
--      a valid change kept
-- Provoke: set provoke below to true; every check must then read FAIL, and the verdict says
-- PROVOKED instead of PASS.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);   -- 'true' to make every check fail

-- Dev only: a verifier that writes refuses a database without the dev seed. The flag is kept for the
-- session, so every block below stops at once and the verdict says REFUSED, also where the client
-- carries on after the error
select set_config('verify.is_dev', (exists (select 1 from cma.app_user u join cma.tenant t on t.id = u.tenant_id
                                            where u.email = 'agent.two@example.com' and u.status = 'active'))::text, false) as is_dev;
do $$
begin
  if not current_setting('verify.is_dev')::boolean then
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 79 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0008r;
create temp table verify_0008r (ord int, check_name text, result text, detail text);

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_fn      text;
  v_bad     text;
  v_txt     text;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  -- A1. the addition is recorded, after 0008p
  insert into verify_0008r values (1, 'A1 addition 0008r recorded',
    case when exists (select 1 from cma.schema_migration where version = '0008r')
              and exists (select 1 from cma.schema_migration where version = '0008p') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the two heartbeat settings: integers with their defaults
  select string_agg(s.key || '=' || s.default_value || ':' || s.value_type, ', ' order by s.key) into v_txt
  from cma.setting s where s.key in ('health.heartbeat_fresh_seconds', 'health.heartbeat_late_seconds');
  insert into verify_0008r values (2, 'A2 the heartbeat settings with their defaults',
    case when v_txt = 'health.heartbeat_fresh_seconds=120:integer, health.heartbeat_late_seconds=900:integer' and not v_provoke then 'PASS' else 'FAIL' end,
    coalesce(v_txt, 'none'));

  -- A3. the three functions exist, executable by the application only, in the caller's rights; the read stable
  v_bad := '';
  foreach v_fn in array array['cma.scheduler_run_start()', 'cma.scheduler_run_finish(uuid, text, integer, text)', 'cma.system_health_runs()'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' is missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                     where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      v_bad := v_bad || v_fn || ' is not the application''s only, in the caller''s rights; ';
    end if;
  end loop;
  if (select provolatile from pg_proc where oid = to_regprocedure('cma.system_health_runs()')) is distinct from 's' then
    v_bad := v_bad || 'system_health_runs is not stable; ';
  end if;
  insert into verify_0008r values (3, 'A3 the functions are the application''s only, in the caller''s rights, the read stable',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A4. sync_run takes the scheduler's job; the index on the tenant's runs by time exists
  v_bad := '';
  if not exists (select 1 from pg_constraint where conrelid = 'cma.sync_run'::regclass and conname = 'sync_run_job_check'
                 and pg_get_constraintdef(oid) like '%close_forgotten_workdays%') then
    v_bad := v_bad || 'the job check does not name close_forgotten_workdays; ';
  end if;
  if not exists (select 1 from pg_indexes where schemaname = 'cma' and tablename = 'sync_run' and indexname = 'sync_run_tenant_started_idx'
                 and indexdef like '%(tenant_id, started_at DESC)%') then
    v_bad := v_bad || 'no index on (tenant_id, started_at desc); ';
  end if;
  insert into verify_0008r values (4, 'A4 sync_run takes the scheduler''s job and has the index on the tenant''s runs',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);
end
$$;

-- B. Behaviour on two throwaway tenants (rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_rows     text[] := '{}';
  v_t1 uuid; v_t2 uuid;
  v_admin1 uuid; v_agent1 uuid; v_sched1 uuid; v_ing1 uuid;
  v_admin2 uuid; v_sched2 uuid;
  v_conn1 uuid;
  v_run uuid; v_run2 uuid; v_irun uuid;
  v_txt      text;
  v_detail   text;
  v_n        integer;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    v_t1 := cma.create_tenant('verify-0008r-one', 'Verify 0008r one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008r-two', 'Verify 0008r two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent1@example.invalid', 'agent1') returning id into v_agent1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin2') returning id into v_admin2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_agent1, 'agent'), (v_t2, v_admin2, 'admin')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    -- the system users every tenant gets: the Scheduler (0005a) and the Ingest user (0006)
    select x.user_id into v_sched1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'scheduler';
    select x.user_id into v_ing1   from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    select x.user_id into v_sched2 from cma.app_user_external_id x where x.tenant_id = v_t2 and x.system = 'scheduler';
    perform set_config('role', 'cma_app', true);

    -- tenant one: a CRM connection for the ingest's rows
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    select c.connection_id into v_conn1 from cma.upsert_connection('verifycrm', 'Verify CRM one', 'portal-1', null, null) c;

    -- B1. the Scheduler user starts a run and finishes it with the count of days closed: one row,
    --     succeeded, without a connection
    perform set_config('app.user_id', v_sched1::text, true);
    v_run := cma.scheduler_run_start();
    perform cma.scheduler_run_finish(v_run, 'succeeded', 3, null);
    perform set_config('role', 'cma_owner', true);
    select format('%s row(s): job %s, connection %s, status %s, counts %s, error %s, finished %s',
                  count(*), min(r.job), coalesce(min(r.connection_id::text), 'none'), min(r.status), min(r.counts::text),
                  coalesce(min(r.error), 'none'), bool_and(r.finished_at is not null))
      into v_txt
    from cma.sync_run r where r.tenant_id = v_t1 and r.id = v_run;
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['11', 'B1 the Scheduler user starts and finishes its run: one row, the days closed',
      case when v_txt = '1 row(s): job close_forgotten_workdays, connection none, status succeeded, counts {"closed": 3}, error none, finished t'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B2. a second finish is refused (CMA03), an unknown run (CMA02), a bad status (CMA04), a negative count (CMA04)
    v_n := 0;
    begin perform cma.scheduler_run_finish(v_run, 'failed', 0, 'x'); exception when sqlstate 'CMA03' then v_n := v_n + 1; end;
    begin perform cma.scheduler_run_finish(gen_random_uuid(), 'succeeded', 0, null); exception when sqlstate 'CMA02' then v_n := v_n + 1; end;
    v_run2 := cma.scheduler_run_start();
    begin perform cma.scheduler_run_finish(v_run2, 'done', 0, null); exception when sqlstate 'CMA04' then v_n := v_n + 1; end;
    begin perform cma.scheduler_run_finish(v_run2, 'succeeded', -1, null); exception when sqlstate 'CMA04' then v_n := v_n + 1; end;
    -- and the ingest's finish does not take the scheduler's row (it is not the ingest's: CMA06, the scheduler lacks ingest.write)
    begin perform cma.ingest_sync_run_finish(v_run2, 'succeeded', '{}'::jsonb, null); exception when sqlstate 'CMA06' then v_n := v_n + 1; end;
    perform cma.scheduler_run_finish(v_run2, 'failed', 0, 'verify_failure');
    v_rows := v_rows || array['12', 'B2 a finished run, an unknown run, a bad status and a negative count are refused',
      case when v_n = 5 and not v_provoke then 'PASS' else 'FAIL' end, format('%s of 5 refusals', v_n)];

    -- B3. an admin without workday.close_forgotten cannot start a scheduler run (CMA06); nor can the Ingest user
    v_n := 0;
    perform set_config('app.user_id', v_admin1::text, true);
    begin perform cma.scheduler_run_start(); exception when sqlstate 'CMA06' then v_n := v_n + 1; end;
    perform set_config('app.user_id', v_ing1::text, true);
    begin perform cma.scheduler_run_start(); exception when sqlstate 'CMA06' then v_n := v_n + 1; end;
    v_rows := v_rows || array['13', 'B3 only the Scheduler user starts a scheduler run',
      case when v_n = 2 and not v_provoke then 'PASS' else 'FAIL' end, format('%s of 2 refusals', v_n)];

    -- B4. the ingest's link_calls row on the connection (0007's start and finish) and the read: per job and
    --     connection, the last run, the last success, the last failure with its error, the 24-hour counts
    perform set_config('app.user_id', v_ing1::text, true);
    v_irun := cma.ingest_sync_run_start(v_conn1, 'link_calls', null, now() - interval '2 hours', now());
    perform cma.ingest_sync_run_finish(v_irun, 'succeeded', '{"upserted": 2}'::jsonb, null);
    perform set_config('app.user_id', v_admin1::text, true);
    select string_agg(format('%s/%s: last %s%s, ok %s, bad %s%s, 24h %s/%s', h.job,
                             case when h.connection_id is null then 'none' when h.connection_id = v_conn1 then 'conn1' else 'other' end,
                             h.last_status, case when h.last_error is null then '' else ' (' || h.last_error || ')' end,
                             (h.last_succeeded_at is not null), (h.last_failed_at is not null), coalesce(' ' || h.last_failed_error, ''),
                             h.runs_24h, h.failed_24h), ' | ' order by h.job)
      into v_txt
    from cma.system_health_runs() h;
    v_rows := v_rows || array['14', 'B4 the read sums the runs per job and connection',
      case when v_txt = 'close_forgotten_workdays/none: last failed (verify_failure), ok t, bad t verify_failure, 24h 2/1 | link_calls/conn1: last succeeded, ok t, bad f, 24h 1/0'
                and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no row')];

    -- B5. an agent and the Ingest user cannot read it (CMA06); a read without an acting user (CMA01)
    v_n := 0;
    foreach v_detail in array array[v_agent1::text, v_ing1::text] loop
      perform set_config('app.user_id', v_detail, true);
      begin perform * from cma.system_health_runs(); exception when sqlstate 'CMA06' then v_n := v_n + 1; end;
    end loop;
    perform set_config('app.user_id', '', true);
    begin perform * from cma.system_health_runs(); exception when sqlstate 'CMA01' then v_n := v_n + 1; end;
    perform set_config('app.user_id', v_admin1::text, true);
    v_rows := v_rows || array['15', 'B5 tenant.configure reads System health; refusals',
      case when v_n = 3 and not v_provoke then 'PASS' else 'FAIL' end, format('%s of 3 refusals', v_n)];

    -- B6. tenant isolation: tenant two's admin sees no run of tenant one; its own scheduler row appears alone
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    v_n := (select count(*) from cma.system_health_runs());
    perform set_config('app.user_id', v_sched2::text, true);
    v_run := cma.scheduler_run_start();
    perform cma.scheduler_run_finish(v_run, 'succeeded', 0, null);
    perform set_config('app.user_id', v_admin2::text, true);
    select format('%s then %s: %s', v_n, count(*), string_agg(h.job || '/' || h.runs_24h, ',')) into v_txt from cma.system_health_runs() h;
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    v_rows := v_rows || array['16', 'B6 tenant isolation',
      case when v_txt = '0 then 1: close_forgotten_workdays/1' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B7. the settings: the defaults, fresh at or above late refused, late at or below fresh refused, a
    --     non-integer refused, a valid change kept
    select string_agg(s.key || '=' || s.value || case when s.is_default then ' (default)' else '' end, ', ' order by s.key) into v_txt
    from cma.tenant_settings() s where s.key like 'health.%';
    v_n := 0;
    begin perform cma.set_tenant_setting('health.heartbeat_fresh_seconds', '900'); exception when sqlstate 'CMA04' then v_n := v_n + 1; end;
    begin perform cma.set_tenant_setting('health.heartbeat_late_seconds', '120'); exception when sqlstate 'CMA04' then v_n := v_n + 1; end;
    begin perform cma.set_tenant_setting('health.heartbeat_fresh_seconds', 'two minutes'); exception when sqlstate 'CMA04' then v_n := v_n + 1; end;
    begin perform cma.set_tenant_setting('health.heartbeat_late_seconds', '30'); exception when sqlstate 'CMA04' then v_n := v_n + 1; end;
    perform cma.set_tenant_setting('health.heartbeat_fresh_seconds', '180');
    perform cma.set_tenant_setting('health.heartbeat_late_seconds', '1200');
    select v_txt || ' | ' || string_agg(s.key || '=' || s.value, ', ' order by s.key) || format(' | %s refusals', v_n) into v_txt
    from cma.tenant_settings() s where s.key like 'health.%';
    v_rows := v_rows || array['17', 'B7 the heartbeat settings: defaults, bounds, fresh below late, a change kept',
      case when v_txt = 'health.heartbeat_fresh_seconds=120 (default), health.heartbeat_late_seconds=900 (default) | health.heartbeat_fresh_seconds=180, health.heartbeat_late_seconds=1200 | 4 refusals'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B8. a run older than 30 days is outside the read's window (the index's range), a younger one inside:
    --     two finished reconcile runs written past the functions (as 0007's rows are shaped), 31 and 29 days old
    perform set_config('role', 'cma_owner', true);
    insert into cma.sync_run (tenant_id, connection_id, job, from_at, to_at, started_at, started_by, finished_at, status, counts)
    values (v_t1, v_conn1, 'reconcile', now() - interval '32 days', now() - interval '31 days', now() - interval '31 days', v_ing1,
            now() - interval '31 days' + interval '1 minute', 'succeeded', '{"fetched": 1}');
    perform set_config('role', 'cma_app', true);
    v_n := (select count(*) from cma.system_health_runs() h where h.job = 'reconcile');
    perform set_config('role', 'cma_owner', true);
    insert into cma.sync_run (tenant_id, connection_id, job, from_at, to_at, started_at, started_by, finished_at, status, counts)
    values (v_t1, v_conn1, 'reconcile', now() - interval '30 days', now() - interval '29 days', now() - interval '29 days', v_ing1,
            now() - interval '29 days' + interval '1 minute', 'succeeded', '{"fetched": 1}');
    perform set_config('role', 'cma_app', true);
    select format('%s then %s (24h %s)', v_n, count(*), min(h.runs_24h)) into v_txt from cma.system_health_runs() h where h.job = 'reconcile';
    v_rows := v_rows || array['18', 'B8 the read covers the last 30 days only',
      case when v_txt = '0 then 1 (24h 0)' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['39', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008r (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008r values (39, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008r
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED: not dev'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008r where result = 'PASS') = 12
                       and not exists (select 1 from verify_0008r where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0008r where result = 'PASS'),
                                        (select count(*) from verify_0008r where result <> 'PASS'))) x
order by ord;
reset role;
