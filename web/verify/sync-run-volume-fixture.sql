-- =============================================================================================
-- verify/sync-run-volume-fixture.sql: cma.sync_run at three times prod's volume of 16 November 2026, for the sync_run
-- reads (addition 0009x, 196): LOCAL database only, after verify/perf-volume-fixture.sql
-- =============================================================================================
-- perf-volume-fixture.sql loads 120,000 × m runs of the CRM's, the stores' and the register's polls (360,000 at m = 3),
-- which is prod's size on 16 November 2026 (353,777 rows, records/perf-prod-2026-11-16), not three times it, and holds
-- no run of the scheduler's jobs (no connection) nor of Pulse4all Invest. This block adds, per tenant of the dev seed:
--   every minute of the last 30 days: refresh_follow_up, refresh_data_quality, refresh_active_customers and flash_snapshot
--     (no connection; Pulse4all Invest: flash_snapshot alone), and link_calls on the subscriptions tenant's CRM connection
--   every hour of the last 30 days: close_forgotten_workdays
--   1 % of them failed, every one finished (sync_run_check), 20 to 900 ms each
-- then copies the runs of the 30 days 30 days back (started_at − 30 days, new ids) until the table holds at least 3 × 353,777
-- = 1,061,331 rows: 60 days of history, as prod will hold in mid-December without retention.
-- Never for dev or prod: the perf fixture's guards (the local switch, no Cloud SQL, the dev seed). Every value is invented;
-- no row carries a name, an address or a number of a person. Rerunnable: a second run finds the table full and stops.
--
--   psql -h 127.0.0.1 -d cma -v ON_ERROR_STOP=1 -c "set cma.local_fixture = 'on'" -f verify/sync-run-volume-fixture.sql
set role cma_owner;
do $$
declare
  v_sub uuid := (select id from cma.tenant where slug = 'pulse4all-subscriptions');
  v_inv uuid := (select id from cma.tenant where slug = 'pulse4all-invest');
  v_crm uuid;
  v_n   bigint;
begin
  if coalesce(current_setting('cma.local_fixture', true), '') <> 'on' then
    raise exception 'local fixture only: run  set cma.local_fixture = ''on''  in this session first';
  end if;
  if exists (select 1 from pg_roles where rolname = 'cloudsqladmin') then
    raise exception 'this is a Cloud SQL instance (the role cloudsqladmin exists): the volume fixture is for a local database only';
  end if;
  if v_sub is null or v_inv is null or not exists (select 1 from cma.app_user where email = 'agent.two@example.com') then
    raise exception 'the dev seed is missing: this fixture needs db/02, db/03 and db/06';
  end if;
  if (select count(*) from cma.sync_run) >= 1061331 then
    raise notice 'sync_run volume fixture: % runs already, nothing added', (select count(*) from cma.sync_run);
    return;
  end if;
  select r.connection_id into v_crm from cma.sync_run r where r.tenant_id = v_sub and r.job = 'forms_poll' limit 1;
  if v_crm is null then
    raise exception 'verify/perf-volume-fixture.sql has not run: no forms_poll run of the subscriptions tenant';
  end if;

  -- the scheduler's minute jobs and link_calls, every minute of 30 days; close_forgotten_workdays every hour
  insert into cma.sync_run (tenant_id, connection_id, job, started_at, finished_at, status, error)
  select x.tenant_id, x.connection_id, x.job, g.at, g.at + make_interval(secs => (20 + (abs(hashtext(x.job || g.at::text)) % 880)) / 1000.0),
         case when abs(hashtext(x.job || g.at::text || 'f')) % 100 = 0 then 'failed' else 'succeeded' end,
         case when abs(hashtext(x.job || g.at::text || 'f')) % 100 = 0 then 'fixture failure' end
  from (values (v_sub, null::uuid, 'refresh_follow_up'), (v_sub, null::uuid, 'refresh_data_quality'),
               (v_sub, null::uuid, 'refresh_active_customers'), (v_sub, null::uuid, 'flash_snapshot'),
               (v_inv, null::uuid, 'flash_snapshot'), (v_sub, v_crm, 'link_calls')) x(tenant_id, connection_id, job)
  cross join lateral generate_series(date_trunc('minute', now()) - interval '30 days', date_trunc('minute', now()) - interval '1 minute',
                                     interval '1 minute') g(at);
  insert into cma.sync_run (tenant_id, connection_id, job, started_at, finished_at, status)
  select t.id, null, 'close_forgotten_workdays', g.at, g.at + interval '80 milliseconds', 'succeeded'
  from (values (v_sub), (v_inv)) t(id)
  cross join generate_series(date_trunc('hour', now()) - interval '30 days', date_trunc('hour', now()) - interval '1 hour', interval '1 hour') g(at);

  -- the history: the runs of the last 30 days again, 30 days earlier, until three times prod's 16 November size
  select count(*) into v_n from cma.sync_run;
  insert into cma.sync_run (tenant_id, connection_id, job, stream, from_at, to_at, started_at, started_by, finished_at, status, counts, error)
  select r.tenant_id, r.connection_id, r.job, r.stream, r.from_at - interval '30 days', r.to_at - interval '30 days',
         r.started_at - interval '30 days', r.started_by, r.finished_at - interval '30 days', r.status, r.counts, r.error
  from cma.sync_run r
  where r.started_at > now() - interval '30 days' and r.status <> 'running'
  order by r.started_at desc
  limit greatest(0, 1061331 - v_n);
  raise notice 'sync_run volume fixture: % runs', (select count(*) from cma.sync_run);
end
$$;
analyze cma.sync_run;
reset role;
