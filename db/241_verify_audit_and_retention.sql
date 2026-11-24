-- =============================================================================================
-- 241_verify_audit_and_retention.sql: verifies addition 0009zt, the ingest's source writes out of the audit log (D12) and
-- the run rows' retention (D13) (brief N07, PR N07f)
-- =============================================================================================
-- Universal: no seed is assumed. R1 checks the structure; A1, F1 and P1 write throwaway rows inside subtransactions that are
-- always rolled back, so nothing stays and the script runs in dev and in prod. Synthetic data only (ids v9zt-…, counts
-- printed, never a row). Run as your own IAM login after 240_audit_and_retention.sql, dev first, then prod. Expected: R1,
-- A1, F1, P1 OK, then "PASS 0009zt". Provoked (verify.provoke true at the top): every row FAIL, the verdict PROVOKED, NOT A
-- PASS, and P1 then purges with a retention of 7 days, a deliberate difference its detail shows.
--
--   R1  0009zt recorded after 0009zs; ingest_event_processed_idx valid; cma.sync_run_purge(integer) SECURITY DEFINER of
--       cma_owner with its search path pinned, it and cma.audit_source_mirror_tables() the application's only; the settings
--       90 and 365; a value out of range refused (CMA04)
--   A1  the ingest's write to a mirrored source table (crm_contact) leaves no audit row; the ingest's write to a
--       configuration table (market) and a person's write to the same source table each leave one
--   F1  the follow-up refresh: nothing processed since its marker answers unchanged; an ingest event processed after it
--       makes it compute
--   P1  the purge of a throwaway pair: old succeeded runs and failed runs past 365 days go, a failed run of 200 days stays,
--       the pair's 20 latest stay, a stream's only (latest) succeeded run stays however old; the hourly counts of the pair
--       are the same before and after; a person is refused (CMA06)
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);                 -- 'true' to make every check fail

drop table if exists pg_temp.verify_0009zt;
create temporary table verify_0009zt (ord integer, check_name text, result text, detail text);

create or replace function pg_temp.v9zt_row(p_ord integer, p_id text, p_name text, p_ok boolean, p_detail text)
returns void
language sql
as $$
  insert into pg_temp.verify_0009zt
  select p_ord, p_id || ' ' || p_name,
         case when coalesce(p_ok, false) and not current_setting('verify.provoke')::boolean then 'OK' else 'FAIL' end,
         case when coalesce(p_ok, false) and not current_setting('verify.provoke')::boolean then coalesce(p_detail, '')
              else 'FAIL ' || p_id || ': ' || case when current_setting('verify.provoke')::boolean then 'provoked; ' else '' end
                   || coalesce(p_detail, '(no detail)') end
$$;

create or replace function pg_temp.v9zt_code(p_sql text)
returns text
language plpgsql
as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end
$$;

do $$
declare
  -- the first active tenant with a connection (the checks write a run row and an ingest event on one)
  v_t      uuid := (select t.id from cma.tenant t where t.status = 'active'
                      and (select min(ic.id::text) from cma.integration_connection ic where ic.tenant_id = t.id) is not null
                    order by t.slug collate "C" limit 1);
  v_ingest uuid;
  v_sched  uuid;
  v_person uuid;
  v_conn   uuid;
  v_job    text := 'assets_import';
  ok       boolean;
  c1       text;
  c2       text;
  a_src    integer;
  a_cfg    integer;
  a_person integer;
  f1       jsonb;
  f2       jsonb;
  h_before bigint;
  h_after  bigint;
  pr       jsonb;
  c_person text;
  n_left   integer;
  n_stream integer;
  n_f200   integer;
  n_recent integer;
  v_mark   timestamptz;
begin
  -- R1
  c1 := pg_temp.v9zt_code(format('insert into cma.tenant_setting (tenant_id, key, value) values (%L, ''sync_run.retention_days'', ''3'')', v_t));
  c2 := pg_temp.v9zt_code(format('insert into cma.tenant_setting (tenant_id, key, value) values (%L, ''sync_run.failed_retention_days'', ''9999'')', v_t));
  ok := (select a.applied_at >= b.applied_at from cma.schema_migration a, cma.schema_migration b where a.version = '0009zt' and b.version = '0009zs')
    and exists (select 1 from pg_index i where i.indexrelid = to_regclass('cma.ingest_event_processed_idx') and i.indisvalid)
    and (select p.prosecdef and pg_get_userbyid(p.proowner) = 'cma_owner' and 'search_path=pg_catalog, pg_temp' = any (p.proconfig)
         from pg_proc p where p.oid = 'cma.sync_run_purge(integer)'::regprocedure)
    and not has_function_privilege('public', 'cma.sync_run_purge(integer)', 'execute') and has_function_privilege('cma_app', 'cma.sync_run_purge(integer)', 'execute')
    and not has_function_privilege('public', 'cma.audit_source_mirror_tables()', 'execute')
    and (select s.default_value from cma.setting s where s.key = 'sync_run.retention_days') = '90'
    and (select s.default_value from cma.setting s where s.key = 'sync_run.failed_retention_days') = '365'
    and c1 = 'CMA04' and c2 = 'CMA04';
  perform pg_temp.v9zt_row(1, 'R1', 'structure', ok, format('order, index, purge definer, grants, settings 90/365, refusals %s/%s', c1, c2));

  v_ingest := (select u.id from cma.app_user_external_id e join cma.app_user u on u.tenant_id = e.tenant_id and u.id = e.user_id
               where e.tenant_id = v_t and e.system = 'ingest' and e.external_id = 'ingest' and u.kind = 'system' limit 1);
  v_sched := (select u.id from cma.app_user_external_id e join cma.app_user u on u.tenant_id = e.tenant_id and u.id = e.user_id
              where e.tenant_id = v_t and e.system = 'scheduler' and e.external_id = 'scheduler' and u.kind = 'system' limit 1);
  v_person := (select u.id from cma.app_user u where u.tenant_id = v_t and u.kind = 'person' and u.status = 'active' order by u.id limit 1);
  v_conn := (select ic.id from cma.integration_connection ic where ic.tenant_id = v_t order by ic.id limit 1);

  -- A1: three writes, the audit rows each leaves
  begin
    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('app.user_id', v_ingest::text, true);
    perform set_config('app.actor_label', 'ingest:v9zt', true);
    v_mark := clock_timestamp();
    update cma.crm_contact k set synced_at = now() where k.id = (select x.id from cma.crm_contact x where x.tenant_id = v_t order by x.id limit 1);
    a_src := (select count(*) from cma.audit_log a where a.tenant_id = v_t and a.table_name = 'crm_contact' and a.changed_at >= v_mark);
    v_mark := clock_timestamp();
    update cma.market m set time_zone = m.time_zone where m.tenant_id = v_t and m.code = (select min(x.code) from cma.market x where x.tenant_id = v_t);
    a_cfg := (select count(*) from cma.audit_log a where a.tenant_id = v_t and a.table_name = 'market' and a.changed_at >= v_mark);
    perform set_config('app.user_id', v_person::text, true);
    perform set_config('app.actor_label', 'v9zt-person', true);
    v_mark := clock_timestamp();
    update cma.crm_contact k set synced_at = now() where k.id = (select x.id from cma.crm_contact x where x.tenant_id = v_t order by x.id limit 1);
    a_person := (select count(*) from cma.audit_log a where a.tenant_id = v_t and a.table_name = 'crm_contact' and a.changed_at >= v_mark);
    raise exception using errcode = 'V9ZT0', message = 'rolled back';
  exception when sqlstate 'V9ZT0' then
    null;
  end;
  perform pg_temp.v9zt_row(2, 'A1', 'the ingest''s source writes out, config and people in',
    v_ingest is not null and a_src = 0 and a_cfg = 1 and a_person = 1,
    format('ingest to crm_contact %s rows, ingest to market %s, a person to crm_contact %s', a_src, a_cfg, a_person));

  -- F1: the follow-up's probe
  begin
    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('app.user_id', v_sched::text, true);
    perform set_config('app.actor_label', 'scheduler', true);
    perform cma.refresh_follow_up_of(v_t);
    -- the marker as if checked five minutes from now, its clock change an hour on: nothing processed since
    update cma.follow_up_marker x set inputs_checked_at = now() + interval '5 minutes', computed_at = now(),
                                      next_change_at = now() + interval '1 hour'
    where x.tenant_id = v_t;
    f1 := cma.refresh_follow_up();
    insert into cma.ingest_event (tenant_id, connection_id, event_key, source_type, kind, object_type, object_id, occurred_at,
                                  recorded_at, status, processed_at)
    values (v_t, v_conn, 'v9zt-event-1', 'v9zt', 'changed', 'v9zt', 'v9zt-1', now(), now(), 'processed', now() + interval '10 minutes');
    f2 := cma.refresh_follow_up();
    raise exception using errcode = 'V9ZT0', message = 'rolled back';
  exception when sqlstate 'V9ZT0' then
    null;
  end;
  perform pg_temp.v9zt_row(3, 'F1', 'the follow-up sees a processed ingest event',
    f1 ->> 'reason' = 'unchanged' and (f2 ->> 'computed')::boolean,
    format('before: %s, after an event: computed %s', coalesce(f1 ->> 'reason', f1 ->> 'computed'), f2 ->> 'computed'));

  -- P1: the purge of a throwaway pair
  begin
    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('app.user_id', v_ingest::text, true);
    perform set_config('app.actor_label', 'ingest:v9zt', true);
    if current_setting('verify.provoke')::boolean then
      insert into cma.tenant_setting (tenant_id, key, value) values (v_t, 'sync_run.retention_days', '7')
      on conflict (tenant_id, key) do update set value = excluded.value;
    end if;
    delete from cma.sync_run x where x.tenant_id = v_t and x.job = v_job and x.connection_id = v_conn;
    insert into cma.sync_run (tenant_id, connection_id, job, stream, started_at, finished_at, status, counts, error)
    select v_t, v_conn, v_job, null::text, now() - make_interval(days => 100 + i), now() - make_interval(days => 100 + i), 'succeeded', '{}'::jsonb, null::text
    from generate_series(0, 29) i
    union all
    select v_t, v_conn, v_job, null, now() - make_interval(days => 1 + i), now() - make_interval(days => 1 + i), 'succeeded', '{}', null
    from generate_series(0, 24) i
    union all
    select v_t, v_conn, v_job, null, now() - make_interval(days => 200 + i), now() - make_interval(days => 200 + i), 'failed', '{}', 'v9zt'
    from generate_series(0, 2) i
    union all
    select v_t, v_conn, v_job, null, now() - make_interval(days => 400 + i), now() - make_interval(days => 400 + i), 'failed', '{}', 'v9zt'
    from generate_series(0, 1) i
    union all
    select v_t, v_conn, v_job, 'v9zt-s', now() - interval '300 days', now() - interval '300 days', 'succeeded', '{}', null;
    h_before := (select sum(h.runs) from cma.sync_run_hour h where h.tenant_id = v_t and h.job = v_job and h.connection_id = v_conn);
    pr := cma.sync_run_purge(1000);
    h_after := (select sum(h.runs) from cma.sync_run_hour h where h.tenant_id = v_t and h.job = v_job and h.connection_id = v_conn);
    n_left := (select count(*) from cma.sync_run x where x.tenant_id = v_t and x.job = v_job and x.connection_id = v_conn);
    n_stream := (select count(*) from cma.sync_run x where x.tenant_id = v_t and x.job = v_job and x.connection_id = v_conn and x.stream = 'v9zt-s');
    n_f200 := (select count(*) from cma.sync_run x where x.tenant_id = v_t and x.job = v_job and x.connection_id = v_conn and x.status = 'failed');
    n_recent := (select count(*) from cma.sync_run x where x.tenant_id = v_t and x.job = v_job and x.connection_id = v_conn
                   and x.started_at > now() - interval '30 days');
    perform set_config('app.user_id', v_person::text, true);
    c_person := pg_temp.v9zt_code('select cma.sync_run_purge(10)');
    raise exception using errcode = 'V9ZT0', message = 'rolled back';
  exception when sqlstate 'V9ZT0' then
    null;
  end;
  perform pg_temp.v9zt_row(4, 'P1', 'the purge keeps what it must and the hourly counts',
    (pr ->> 'deleted')::integer = 32 and not (pr ->> 'more')::boolean and n_left = 29 and n_stream = 1 and n_f200 = 3
    and n_recent = 25 and h_before = h_after and c_person = 'CMA06',
    format('deleted %s (more %s), left %s: %s recent, %s failed of 200 days, %s of its own stream; hourly runs %s before, %s after; a person %s',
           pr ->> 'deleted', pr ->> 'more', n_left, n_recent, n_f200, n_stream, h_before, h_after, c_person));
end
$$;

drop function if exists pg_temp.v9zt_code(text);
drop function if exists pg_temp.v9zt_row(integer, text, text, boolean, text);

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0009zt
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0009zt where result <> 'OK') then 'FAIL'
                  when (select count(*) from pg_temp.verify_0009zt where result = 'OK') <> 4 then 'FAIL'
                  else 'PASS 0009zt' end,
             format('241_verify_audit_and_retention: %s OK, %s FAIL', (select count(*) from pg_temp.verify_0009zt where result = 'OK'),
                    (select count(*) from pg_temp.verify_0009zt where result <> 'OK'))) x
order by ord;
reset role;
