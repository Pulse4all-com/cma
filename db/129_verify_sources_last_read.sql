-- =============================================================================================
-- 129_verify_sources_last_read.sql: verifies addition 0008zq, Configuration → Sources shows a connection's last read
-- =============================================================================================
-- Universal: no seed is assumed. Block S checks the addition, the columns and the grants; blocks A1 to A6 each work on
-- throwaway tenants inside a subtransaction that is always rolled back, so nothing stays and the script runs in dev and
-- in prod; A7 does the same for cma.source_reads (the connection page's Reads panel). The connections are invented (adapters verifypoll, verifyhook; account ids verify-…; secret names verify-…),
-- the events and runs are written straight into cma.ingest_event and cma.sync_run as the owner with chosen instants, so
-- the verdict never depends on the time it runs. Cloud SQL Studio shows no notices: a check that fails raises "FAIL …"
-- and stops its block; every check that passed writes one row, and the last row is the verdict: "PASS | 15 PASS, 0 FAIL"
-- (provoked: "PROVOKED, NOT A PASS | 0 PASS, 15 FAIL"). A block that stopped counts its checks as FAIL; the verdict is
-- reached only when the client goes on after an error (psql -v ON_ERROR_STOP=0, as the provoked run does; with
-- ON_ERROR_STOP=1 the run ends at the first FAIL, which names the check). Run as your own IAM login after
-- 128_sources_last_read.sql, dev first, then prod; then 53 (its B2) and 79 again (unchanged, still PASS).
--   S1  the addition 0008zq is recorded after 0008zp; cma.sources() is a stable function executable by cma_app only,
--       owned by cma_owner, whose 27 columns are 52's 22 in their order and then last_read_at, last_read_job, reads_24h,
--       reads_failed_24h, last_read_error; its definition reads cma.sync_run
--   A1  a connection with events and no runs (a webhook source): events_24h and last_event_at as before; last_read_at,
--       last_read_job and last_read_error null, reads_24h and reads_failed_24h 0
--   A2  a connection with runs and no events (a polled source): events 0 and last_event_at null; last_read_at the latest
--       started succeeded run's finish and last_read_job its job, not a later failed run and not a running one; reads_24h
--       counts every run started in the window, running included; a long reconcile that started before a poll and
--       finished after it is not the last read: the poll is (the latest started, served by sync_run_started_idx backward)
--   A3  a failed run in the window: reads_failed_24h 1 and last_read_error its code; two failed runs: the latest's code
--   A4  a succeeded run older than 24 hours: last_read_at still it (the latest succeeded), reads_24h 0; a failed run
--       older than 24 hours gives no reads_failed_24h and no last_read_error
--   A5  another tenant's runs and events are invisible: tenant two's connection has runs and events, tenant one's rows
--       keep their counts and tenant one's list has no row of it
--   A6  the permission: a manager (no tenant.configure) is refused with CMA06; the admin reads the list
--   S2  cma.source_reads(uuid) is a stable function executable by cma_app only, owned by cma_owner, with its eight columns
--   A7  cma.source_reads: a connection with 25 runs answers its newest 20, newest first (started_at, then id), each row
--       with its job, stream, finish, status, the counts it recorded and its error code; a running run among them; an
--       unknown or another tenant's connection id answers no rows; a manager is refused with CMA06
-- Provoke: set provoke below to true; every block must then stop with FAIL, and the verdict says PROVOKED, NOT A PASS.
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

drop table if exists pg_temp.verify_0008zq;
create temp table verify_0008zq (ord int, check_name text, result text, detail text);

-- A throwaway tenant with an admin and a manager; its ids as jsonb
create or replace function pg_temp.v0008zq_tenant(p_slug text)
returns jsonb
language plpgsql
as $$
declare
  v_t  uuid;
  v_id uuid;
  v    jsonb;
  r    record;
begin
  v_t := cma.create_tenant(p_slug, 'Verify 0008zq', 'Europe/Amsterdam');
  v := jsonb_build_object('t', v_t);
  for r in select * from (values ('admin', 'admin'), ('mgr', 'manager')) as x(name, role_key) loop
    insert into cma.app_user (tenant_id, email, display_name)
    values (v_t, format('verify-%s@example.invalid', r.name), r.name) returning id into v_id;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t, v_id, ar.id from cma.app_role ar where ar.tenant_id = v_t and ar.key = r.role_key;
    v := v || jsonb_build_object(r.name, v_id);
  end loop;
  return v;
end
$$;

-- A connection of the tenant, written as the owner (no secret value anywhere: names only)
create or replace function pg_temp.v0008zq_connection(x jsonb, p_adapter text, p_name text, p_token text)
returns uuid
language plpgsql
as $$
declare
  v_id uuid;
begin
  insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, token_secret_name)
  values ((x ->> 't')::uuid, p_adapter, p_name, 'verify-' || lower(replace(p_name, ' ', '-')), p_token)
  returning id into v_id;
  return v_id;
end
$$;

-- An event of a connection, recorded at p_at
create or replace function pg_temp.v0008zq_event(x jsonb, p_conn uuid, p_key text, p_at timestamptz, p_status text default 'processed')
returns void
language sql
as $$
  insert into cma.ingest_event (tenant_id, connection_id, event_key, source_type, kind, object_type, object_id, occurred_at, recorded_at, status)
  values ((x ->> 't')::uuid, p_conn, p_key, 'verify', 'changed', 'record', 'verify-1', p_at, p_at, p_status);
$$;

-- A run of a connection: started at p_started, finished p_minutes later with p_status (running when p_minutes is null)
create or replace function pg_temp.v0008zq_run(x jsonb, p_conn uuid, p_job text, p_started timestamptz, p_minutes integer, p_status text, p_error text default null,
                                                p_counts jsonb default '{}'::jsonb)
returns void
language sql
as $$
  insert into cma.sync_run (tenant_id, connection_id, job, stream, started_at, finished_at, status, counts, error)
  values ((x ->> 't')::uuid, p_conn, p_job, 'verify', p_started,
          case when p_minutes is null then null else p_started + make_interval(mins => p_minutes) end,
          case when p_minutes is null then 'running' else p_status end, p_counts, p_error);
$$;

-- The acting context inside a block: the application, the tenant, a person
create or replace function pg_temp.v0008zq_as(x jsonb, p_who text)
returns void
language sql
as $$
  select set_config('role', 'cma_app', true), set_config('app.tenant_id', x ->> 't', true),
         set_config('app.user_id', x ->> p_who, true), set_config('app.actor_label', '', true);
$$;

-- One connection's row of cma.sources(), as the acting person
create or replace function pg_temp.v0008zq_row(p_conn uuid)
returns jsonb
language sql stable
as $$
  select to_jsonb(s) from cma.sources() s where s.connection_id = p_conn
$$;

-- S1. The addition, the columns, the function and its grants (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_fn      text := 'cma.sources()';
  v_cols    text;
begin
  if not exists (select 1 from cma.schema_migration where version = '0008zq') or v_provoke
     or not exists (select 1 from cma.schema_migration where version = '0008zp') then
    raise exception 'FAIL S1: addition 0008zq not recorded after 0008zp';
  end if;
  select string_agg(a.attname || ':' || format_type(a.atttypid, null), ',' order by a.ord)
  into v_cols
  from pg_proc p
  cross join lateral unnest(p.proallargtypes, p.proargmodes, p.proargnames) with ordinality as a(atttypid, mode, attname, ord)
  where p.oid = to_regprocedure(v_fn) and a.mode = 't';
  if v_cols is distinct from
     'connection_id:uuid,key:text,adapter:text,name:text,external_account_id:text,kind:text,held_kinds:text[],status:text,'
     || 'signing_secret_name:text,token_secret_name:text,settings:jsonb,events_24h:integer,events_waiting:integer,'
     || 'events_needs_review:integer,last_event_at:timestamp with time zone,pipelines:integer,forms:integer,call_outcomes:integer,'
     || 'fields:integer,lines:integer,tags:integer,store_handle:text,'
     || 'last_read_at:timestamp with time zone,last_read_job:text,reads_24h:integer,reads_failed_24h:integer,last_read_error:text' then
    raise exception 'FAIL S1: cma.sources() does not answer 52''s 22 columns and then the five of 0008zq (%)', v_cols;
  end if;
  if to_regprocedure(v_fn) is null
     or (select p.prosecdef or p.provolatile <> 's' or p.proowner <> 'cma_owner'::regrole from pg_proc p where p.oid = to_regprocedure(v_fn))
     or not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
     or exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                where p.oid = to_regprocedure(v_fn) and a.grantee = 0) then
    raise exception 'FAIL S1: % is not a stable invoker function owned by cma_owner for cma_app only', v_fn;
  end if;
  if pg_get_functiondef(to_regprocedure(v_fn)) not like '%cma.sync_run%status = ''succeeded''%'
     or pg_get_functiondef(to_regprocedure(v_fn)) not like '%assert_permission(''tenant.configure'')%' then
    raise exception 'FAIL S1: cma.sources() is not the 0008zq definition (sync_run read, tenant.configure checked)';
  end if;
  insert into verify_0008zq values (1, 'S1 addition, columns, function and grants', 'PASS',
    '27 columns, the five of 0008zq last; stable, invoker, cma_owner''s, cma_app only; reads cma.sync_run');
end
$$;

-- S2. cma.source_reads: its columns, volatility and grants (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_fn      text := 'cma.source_reads(uuid)';
  v_cols    text;
begin
  select string_agg(a.attname || ':' || format_type(a.atttypid, null), ',' order by a.ord)
  into v_cols
  from pg_proc p
  cross join lateral unnest(p.proallargtypes, p.proargmodes, p.proargnames) with ordinality as a(atttypid, mode, attname, ord)
  where p.oid = to_regprocedure(v_fn) and a.mode = 't';
  if v_cols is distinct from 'run_id:uuid,job:text,stream:text,started_at:timestamp with time zone,finished_at:timestamp with time zone,status:text,counts:jsonb,error:text'
     or v_provoke then
    raise exception 'FAIL S2: cma.source_reads(uuid) does not answer its eight columns (%)', v_cols;
  end if;
  if to_regprocedure(v_fn) is null
     or (select p.prosecdef or p.provolatile <> 's' or p.proowner <> 'cma_owner'::regrole from pg_proc p where p.oid = to_regprocedure(v_fn))
     or not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
     or exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                where p.oid = to_regprocedure(v_fn) and a.grantee = 0)
     or pg_get_functiondef(to_regprocedure(v_fn)) not like '%assert_permission(''tenant.configure'')%limit 20%' then
    raise exception 'FAIL S2: % is not a stable invoker function owned by cma_owner for cma_app only, checking tenant.configure, limited to 20', v_fn;
  end if;
  insert into verify_0008zq values (2, 'S2 cma.source_reads: columns, function and grants', 'PASS',
    'eight columns; stable, invoker, cma_owner''s, cma_app only; tenant.configure; limit 20');
end
$$;

-- A1 to A4. One tenant: a webhook connection, a polled connection, failures, old runs
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  x         jsonb;
  c_hook    uuid;
  c_poll    uuid;
  c_fail    uuid;
  c_old     uuid;
  c_long    uuid;
  v_t0      timestamptz := now();
  r         jsonb;
begin
  begin
    x := pg_temp.v0008zq_tenant('verify-0008zq-a');
    c_hook := pg_temp.v0008zq_connection(x, 'verifyhook', 'Verify hook', null);
    c_poll := pg_temp.v0008zq_connection(x, 'verifypoll', 'Verify poll', 'verify-poll-key');
    c_fail := pg_temp.v0008zq_connection(x, 'verifypoll', 'Verify fail', 'verify-fail-key');
    c_old  := pg_temp.v0008zq_connection(x, 'verifypoll', 'Verify old', 'verify-old-key');
    c_long := pg_temp.v0008zq_connection(x, 'verifypoll', 'Verify long', 'verify-long-key');
    -- the webhook connection: three events, one waiting, nothing read by a job
    perform pg_temp.v0008zq_event(x, c_hook, 'e1', v_t0 - interval '3 hours');
    perform pg_temp.v0008zq_event(x, c_hook, 'e2', v_t0 - interval '2 hours');
    perform pg_temp.v0008zq_event(x, c_hook, 'e3', v_t0 - interval '1 hour', 'received');
    -- the polled connection: a succeeded run, a later failed one, a later running one; no event
    perform pg_temp.v0008zq_run(x, c_poll, 'reviews_poll', v_t0 - interval '5 hours', 2, 'succeeded');
    perform pg_temp.v0008zq_run(x, c_poll, 'subscriptions_poll', v_t0 - interval '3 hours', 1, 'succeeded');
    perform pg_temp.v0008zq_run(x, c_poll, 'subscriptions_poll', v_t0 - interval '2 hours', 1, 'failed', 'rate_limited');
    perform pg_temp.v0008zq_run(x, c_poll, 'subscriptions_poll', v_t0 - interval '1 minute', null, 'running');
    -- the failing connection: two failed runs in the window, the latest's code wins
    perform pg_temp.v0008zq_run(x, c_fail, 'assets_poll', v_t0 - interval '4 hours', 1, 'failed', 'http_503');
    perform pg_temp.v0008zq_run(x, c_fail, 'assets_poll', v_t0 - interval '2 hours', 1, 'failed', 'token_unavailable');
    -- the old connection: a succeeded and a failed run, both older than 24 hours
    perform pg_temp.v0008zq_run(x, c_old, 'reconcile', v_t0 - interval '30 hours', 10, 'succeeded');
    perform pg_temp.v0008zq_run(x, c_old, 'reconcile', v_t0 - interval '27 hours', 1, 'failed', 'http_500');
    -- the overlap: a long reconcile started 3 hours ago and finished an hour ago; a poll started 2 hours ago and finished
    -- a minute later, inside the reconcile; the poll is the latest started, so it is the last read, shown by its finish
    perform pg_temp.v0008zq_run(x, c_long, 'reconcile', v_t0 - interval '3 hours', 120, 'succeeded');
    perform pg_temp.v0008zq_run(x, c_long, 'subscriptions_poll', v_t0 - interval '2 hours', 1, 'succeeded');

    perform pg_temp.v0008zq_as(x, 'admin');

    r := pg_temp.v0008zq_row(c_hook);
    if (r ->> 'events_24h')::int <> 3 or (r ->> 'events_waiting')::int <> 1 or (r ->> 'last_event_at')::timestamptz <> v_t0 - interval '1 hour'
       or r ->> 'last_read_at' is not null or r ->> 'last_read_job' is not null or r ->> 'last_read_error' is not null
       or (r ->> 'reads_24h')::int <> 0 or (r ->> 'reads_failed_24h')::int <> 0 or v_provoke then
      raise exception 'FAIL A1: a connection with events and no runs reads %', r;
    end if;
    v_rows := v_rows || array['10', 'A1 events and no runs: the events as before, no last read, 0 reads', 'PASS',
                              '3 events, 1 waiting, last event an hour ago; last_read_at null, reads_24h 0'];

    r := pg_temp.v0008zq_row(c_poll);
    if (r ->> 'events_24h')::int <> 0 or r ->> 'last_event_at' is not null
       or (r ->> 'last_read_at')::timestamptz <> v_t0 - interval '3 hours' + interval '1 minute' or r ->> 'last_read_job' <> 'subscriptions_poll'
       or (r ->> 'reads_24h')::int <> 4 then
      raise exception 'FAIL A2: a polled connection reads %', r;
    end if;
    v_rows := v_rows || array['20', 'A2 runs and no events: the latest succeeded run''s finish and job; every run of 24 h counted', 'PASS',
                              'events 0, last event null; last read 3 h ago by subscriptions_poll (not the failed or the running one); reads_24h 4'];
    r := pg_temp.v0008zq_row(c_long);
    if (r ->> 'last_read_at')::timestamptz <> v_t0 - interval '2 hours' + interval '1 minute' or r ->> 'last_read_job' <> 'subscriptions_poll'
       or (r ->> 'reads_24h')::int <> 2 then
      raise exception 'FAIL A2: a poll inside a long reconcile that finished later is not the last read: %', r;
    end if;
    v_rows := v_rows || array['21', 'A2 the latest started run is the last read, not an older one that finished later', 'PASS',
                              'a reconcile started 3 h ago and finished 1 h ago; the poll started 2 h ago is the last read, shown by its finish'];

    r := pg_temp.v0008zq_row(c_poll);
    if (r ->> 'reads_failed_24h')::int <> 1 or r ->> 'last_read_error' <> 'rate_limited' then
      raise exception 'FAIL A3: the polled connection''s failure reads % / %', r ->> 'reads_failed_24h', r ->> 'last_read_error';
    end if;
    r := pg_temp.v0008zq_row(c_fail);
    if (r ->> 'reads_failed_24h')::int <> 2 or r ->> 'last_read_error' <> 'token_unavailable' or r ->> 'last_read_at' is not null
       or (r ->> 'reads_24h')::int <> 2 then
      raise exception 'FAIL A3: a connection with two failed runs reads %', r;
    end if;
    v_rows := v_rows || array['30', 'A3 a failed run in the window: counted, its code; two failed: the latest''s code', 'PASS',
                              'rate_limited beside a later succeeded read; token_unavailable after http_503; no last read without a succeeded run'];

    r := pg_temp.v0008zq_row(c_old);
    if (r ->> 'last_read_at')::timestamptz <> v_t0 - interval '30 hours' + interval '10 minutes' or r ->> 'last_read_job' <> 'reconcile'
       or (r ->> 'reads_24h')::int <> 0 or (r ->> 'reads_failed_24h')::int <> 0 or r ->> 'last_read_error' is not null then
      raise exception 'FAIL A4: a connection read before the window reads %', r;
    end if;
    v_rows := v_rows || array['40', 'A4 runs older than 24 hours: the last read kept, nothing counted, no error', 'PASS',
                              'last read 30 h ago by reconcile; reads_24h 0; the old failure''s code not shown'];

    if (select count(*) from cma.sources()) <> 5 then
      raise exception 'FAIL A4: the tenant lists % connections, not 5', (select count(*) from cma.sources());
    end if;
    v_rows := v_rows || array['41', 'A4 the list holds every connection of the tenant', 'PASS', '5 rows'];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
  insert into verify_0008zq select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
end
$$;

-- A5. Another tenant's runs and events are invisible
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  x1        jsonb;
  x2        jsonb;
  c1        uuid;
  c2        uuid;
  v_t0      timestamptz := now();
  r         jsonb;
begin
  begin
    x1 := pg_temp.v0008zq_tenant('verify-0008zq-a5-one');
    x2 := pg_temp.v0008zq_tenant('verify-0008zq-a5-two');
    c1 := pg_temp.v0008zq_connection(x1, 'verifypoll', 'Verify one', 'verify-one-key');
    c2 := pg_temp.v0008zq_connection(x2, 'verifypoll', 'Verify two', 'verify-two-key');
    perform pg_temp.v0008zq_run(x1, c1, 'reviews_poll', v_t0 - interval '6 hours', 1, 'succeeded');
    perform pg_temp.v0008zq_run(x2, c2, 'reviews_poll', v_t0 - interval '1 hour', 1, 'succeeded');
    perform pg_temp.v0008zq_run(x2, c2, 'reviews_poll', v_t0 - interval '30 minutes', 1, 'failed', 'http_503');
    perform pg_temp.v0008zq_event(x2, c2, 'e1', v_t0 - interval '10 minutes');

    perform pg_temp.v0008zq_as(x1, 'admin');
    r := pg_temp.v0008zq_row(c1);
    if (select count(*) from cma.sources()) <> 1 or pg_temp.v0008zq_row(c2) is not null
       or (r ->> 'last_read_at')::timestamptz <> v_t0 - interval '6 hours' + interval '1 minute'
       or (r ->> 'reads_24h')::int <> 1 or (r ->> 'reads_failed_24h')::int <> 0 or r ->> 'last_read_error' is not null
       or (r ->> 'events_24h')::int <> 0 or v_provoke then
      raise exception 'FAIL A5: tenant one sees % rows and its connection reads %', (select count(*) from cma.sources()), r;
    end if;
    v_rows := v_rows || array['50', 'A5 another tenant''s runs and events are invisible', 'PASS',
                              'tenant one: one row, its own read 6 h ago, 1 read, no failure, 0 events; tenant two''s connection absent'];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
  insert into verify_0008zq select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
end
$$;

-- A6. The permission: a manager refused, the admin served
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  x         jsonb;
  c         uuid;
  v_ok      boolean := false;
begin
  begin
    x := pg_temp.v0008zq_tenant('verify-0008zq-a6');
    c := pg_temp.v0008zq_connection(x, 'verifypoll', 'Verify perm', 'verify-perm-key');
    perform pg_temp.v0008zq_as(x, 'mgr');
    begin
      perform cma.sources();
    exception when sqlstate 'CMA06' then v_ok := true;
    end;
    if not v_ok or v_provoke then
      raise exception 'FAIL A6: a manager without tenant.configure was not refused with CMA06';
    end if;
    v_rows := v_rows || array['60', 'A6 without tenant.configure the read is refused (CMA06)', 'PASS', 'a manager'];
    perform pg_temp.v0008zq_as(x, 'admin');
    if (select count(*) from cma.sources() s where s.connection_id = c) <> 1 then
      raise exception 'FAIL A6: the admin does not see the connection';
    end if;
    v_rows := v_rows || array['61', 'A6 with tenant.configure the list is served', 'PASS', 'the admin, one row'];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
  insert into verify_0008zq select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
end
$$;

-- A7. cma.source_reads: the newest 20 of 25 runs, newest first, with their counts and codes; another tenant; the permission
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  x1        jsonb;
  x2        jsonb;
  c1        uuid;
  c2        uuid;
  v_t0      timestamptz := now();
  v_txt     text;
  v_n       integer;
  v_ok      boolean := false;
  k         integer;
begin
  begin
    x1 := pg_temp.v0008zq_tenant('verify-0008zq-a7-one');
    x2 := pg_temp.v0008zq_tenant('verify-0008zq-a7-two');
    c1 := pg_temp.v0008zq_connection(x1, 'verifypoll', 'Verify reads', 'verify-reads-key');
    c2 := pg_temp.v0008zq_connection(x2, 'verifypoll', 'Verify reads two', 'verify-reads-two-key');
    -- 25 runs an hour apart, the oldest first; the 3rd newest failed, the newest still running (a run's counts are set
    -- when it finishes, so they are written with the row: a finished run is never updated, 32's trigger)
    for k in 1..25 loop
      perform pg_temp.v0008zq_run(x1, c1, case when k % 5 = 0 then 'reconcile' else 'subscriptions_poll' end,
                                  v_t0 - make_interval(hours => 26 - k), case when k = 25 then null else 1 end,
                                  case when k = 23 then 'failed' else 'succeeded' end, case when k = 23 then 'rate_limited' else null end,
                                  case when k = 24 then '{"fetched": 7, "events_new": 2}'::jsonb else '{}'::jsonb end);
    end loop;
    perform pg_temp.v0008zq_run(x2, c2, 'reviews_poll', v_t0 - interval '1 hour', 1, 'succeeded');

    perform pg_temp.v0008zq_as(x1, 'admin');
    select count(*), string_agg(r.status || ':' || coalesce(r.error, '-') || ':' || r.job, ' ' order by r.started_at desc)
    into v_n, v_txt from cma.source_reads(c1) r;
    if v_n <> 20 or v_txt not like 'running:-:reconcile succeeded:-:subscriptions_poll failed:rate_limited:subscriptions_poll %'
       or (select min(r.started_at) from cma.source_reads(c1) r) <> v_t0 - make_interval(hours => 26 - 6)
       or (select bool_and(a.started_at >= b.started_at) from (select r.started_at, row_number() over () as n from cma.source_reads(c1) r) a
           join (select r.started_at, row_number() over () as n from cma.source_reads(c1) r) b on b.n = a.n + 1) is distinct from true
       or v_provoke then
      raise exception 'FAIL A7: source_reads answers % rows, [%]', v_n, v_txt;
    end if;
    v_rows := v_rows || array['70', 'A7 the newest 20 of 25 runs, newest first', 'PASS', 'the running one first, then a succeeded and the failed one; the five oldest left out'];
    if (select r.counts from cma.source_reads(c1) r offset 1 limit 1) <> '{"fetched": 7, "events_new": 2}'::jsonb
       or (select r.stream || ':' || coalesce(r.finished_at::text, 'null') from cma.source_reads(c1) r limit 1) <> 'verify:null'
       or (select r.error from cma.source_reads(c1) r offset 2 limit 1) <> 'rate_limited' then
      raise exception 'FAIL A7: a run''s counts, stream, finish or error are not carried';
    end if;
    v_rows := v_rows || array['71', 'A7 each row carries its stream, finish, counts and error code', 'PASS', 'counts {fetched 7, events_new 2}; the running run without a finish; rate_limited'];
    if (select count(*) from cma.source_reads(c2)) <> 0 or (select count(*) from cma.source_reads('00000000-0000-7000-8000-00000000dead'::uuid)) <> 0 then
      raise exception 'FAIL A7: another tenant''s connection or an unknown id answers rows';
    end if;
    v_rows := v_rows || array['72', 'A7 another tenant''s connection and an unknown id answer no rows', 'PASS', '0 and 0'];
    perform pg_temp.v0008zq_as(x1, 'mgr');
    begin
      perform cma.source_reads(c1);
    exception when sqlstate 'CMA06' then v_ok := true;
    end;
    if not v_ok then
      raise exception 'FAIL A7: a manager without tenant.configure was not refused with CMA06';
    end if;
    v_rows := v_rows || array['73', 'A7 without tenant.configure the reads are refused (CMA06)', 'PASS', 'a manager'];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
  insert into verify_0008zq select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
end
$$;

-- Verdict: one row per check that passed, then the verdict (15 checks; a block that stopped counts its checks as FAIL)
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008zq
      union all
      select 999, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008zq where result = 'PASS') = 15 then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0008zq where result = 'PASS'),
                                        15 - (select count(*) from verify_0008zq where result = 'PASS'))) x
order by ord;
drop function if exists pg_temp.v0008zq_row(uuid);
drop function if exists pg_temp.v0008zq_as(jsonb, text);
drop function if exists pg_temp.v0008zq_run(jsonb, uuid, text, timestamptz, integer, text, text, jsonb);
drop function if exists pg_temp.v0008zq_event(jsonb, uuid, text, timestamptz, text);
drop function if exists pg_temp.v0008zq_connection(jsonb, text, text, text);
drop function if exists pg_temp.v0008zq_tenant(text);
drop table if exists pg_temp.verify_0008zq;
reset role;
