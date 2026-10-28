-- =============================================================================================
-- 117_verify_asset_sync_load.sql: verifies addition 0008zk, the device load set-based, the ingest's load in chunks and
-- slices, and the forecast at 50,000 devices
-- =============================================================================================
-- Dev and local databases only (Decision log, 28 October 2026): it commits throwaway tenants and removes them with
-- their audit rows, which the 17 October 2026 rule allows in dev and local databases only, and prod's audit log stays
-- append-only. It refuses a database without the dev seed (no active agent.two@example.com, as the ingest's flow
-- verifiers refuse one): no tenant is made, none removed, every check reads FAIL and the verdict REFUSED. Prod's speed
-- is measured by PROD_RUNBOOK 14.7's first full read of the real register (the run's phase times, its slowest chunk
-- and slice). Every check writes one row, ok or FAIL, and the last row is the verdict (0008zk verified), because Cloud
-- SQL Studio shows no notices. Run as your own IAM login after 116_asset_sync_load.sql, in dev; then
-- 115_verify_asset_sync.sql and 113_verify_assets.sql again. Adapters, models, statuses, devices,
-- serials, customers, people and secret names are invented data values, and no row carries a name of a customer, an
-- address, an email or a phone number. Edited in place after its dev runs of 27 October 2026 (records/0008zk-dev-2026-10-27),
-- which ran its work in one transaction, and 28 October 2026 (records/0008zk-dev-2026-10-28): it has run in dev only, and
-- CLAUDE.md forbids editing a script that has run in prod.
--
-- The script mirrors production. Every step is its own transaction (begin; select …; commit;), as each of the ingest's
-- calls is: a chunk of 1,000 rows, a slice of the final step, the one-call load, the report. Its throwaway tenants
-- (verify-0008zk-…) are committed between steps and removed by a cleanup that runs at the start (what an interrupted run
-- left) and at the end: every row of theirs table by table (in the order the foreign keys allow), then their audit rows,
-- then the tenants, as the ingest's flow verifiers remove theirs (ingest/verify/lib.mjs, removeTenants); the audit log is
-- append-only for the application, and only these throwaway tenants' rows go. While the script runs, no ingest job
-- serves their connections (their adapters are none of the ingest's), and a reader without a tenant sees their invented
-- rows until the end. A step never raises: an error is recorded
-- and its check reads FAIL. Memory stays bounded by a step, so the script runs twice in a row (normal, then provoked) on
-- a db-g1-small. Every run of either kind writes and then removes some 70,000 devices, 140,000 components and their
-- audit rows.
--   A  structure and privileges: the addition row after 0008zj; the load's row types and the staging trigger; every
--      function the application's only and in the caller's rights, the trigger function nobody's, the load set-based in
--      one place (no row loop, no row lock, no helper with a subtransaction); the setting assets_load_chunk by form; the
--      value checks reading as 0008zi's helpers read (pure); the final step in slices by its range index; the forecast
--      without a row loop
--   C3 the one-call path (the CSV fallback, run from Studio without the ingest's timeout): 115's C1 again, a throwaway
--      tenant with 5,000 devices loaded as 115 loads them (staged in parts of 500, the statistics read after each), then
--      a nightly full snapshot of them all, unchanged, staged and loaded in one call as the Ingest user, in a fresh
--      transaction, under verify.max_one_call_ms (115's 10000 ms); its detail the staging insert and the load's phases
--   B  behaviour, on two throwaway tenants, each with its Ingest user and an asset register connection with a token
--      secret name; tenant one also holds a second such connection, one without a token secret name and a CRM
--      connection. A register of 10,000 records is loaded the same way into both of tenant one's connections; then the
--      night's full snapshot (9,000 of them, 1,440 changed, 360 with a replaced pads serial, and 1,000 new; 1,000 gone)
--      is loaded into one connection in one call (staged) and into the other in ten chunks of 1,000 and the final step's
--      ten slices: the same counts and the same devices and components. Then: a rerun of the same chunks and slices
--      changes nothing; a run that fails before its final step marks nothing missing, and its chunks already loaded are
--      unchanged on the rerun; a chunk with a bad row loads nothing; row-level security across the two tenants' Ingest
--      users; the refusals (the slices' among them); the run's phase times, components_closed and slowest calls and the
--      settings (view_id refused on an asset register); the mapped fields' types; a kind the register emptied closes
--      the device's component (no new row, its item due unknown), a kind not staged or with a dropped serial and no
--      expiry is left as it is, a rerun changes nothing; held again, another serial is inserted and the same one reopened
--   C  speed at the register's horizon, 50,000 devices, against the ingest's statement timeout (verify.max_ms, half of
--      it, for every ingest call; measured on dev's shared core, where a call of half the timeout leaves the other half
--      for a slower moment): a first load of 50,000 new records into an empty connection with no statistics read in
--      between, in chunks from 1,000 under the adapter's rule (the next chunk half the size after a call slower than a
--      third of the timeout, at least 100; C4, each call, its sizes, halvings and phases); then, the statistics read,
--      one chunk of 1,000 unchanged rows (C1); the final step over the run's 49,500 record ids in 50 slices (C2, each
--      slice); the Maintenance page of 24 months and the device list of all buckets, best of three each, under
--      verify.max_report_ms (C5)
--   Z  every step its own transaction; the throwaway tenants removed with their audit rows
-- Provoke: set provoke below to true; every check must then read FAIL, and the verdict says PROVOKED instead.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);           -- 'true' to make every check fail
-- The budgets follow the ingest's real limit, not this server's hardware (Decision log, 28 October 2026): its statement
-- timeout, CMA_DB_STATEMENT_TIMEOUT_MS (the default in ingest/src/core/db.mjs; check E7j of ingest/verify/assets-mapping.mjs
-- fails when this value differs from it), measured on dev's shared core; prod is measured by PROD_RUNBOOK 14.7's chunk_max_ms
select set_config('verify.ingest_statement_timeout_ms', '15000', false);
select set_config('verify.max_ms', (current_setting('verify.ingest_statement_timeout_ms')::integer / 2)::text, false);  -- an ingest call: a chunk, a slice
select set_config('verify.slow_ms', (current_setting('verify.ingest_statement_timeout_ms')::integer / 3)::text, false); -- the adapter halves the next chunk after a slower call
select set_config('verify.max_report_ms', '5000', false);      -- C5: the Maintenance page and the device list at 50,000 devices, on dev
select set_config('verify.max_one_call_ms', '10000', false);   -- 115's C1: 5,000 records staged and loaded in one call
-- dev or a local database only: the dev seed's agent.two@example.com active, as the ingest's flow verifiers require
select set_config('verify.dev', (select exists (select 1 from cma.app_user u where u.email = 'agent.two@example.com' and u.status = 'active'))::text, false);

drop table if exists pg_temp.verify_0008zk;
create temp table verify_0008zk (ord int, check_name text, result text, detail text);
-- Every step's record: its name and number, its transaction, its milliseconds, its answer or its error
drop table if exists pg_temp.v0008zk_step;
create temp table v0008zk_step (ord bigint generated always as identity, step text, n int, xact xid8, ms numeric, answer jsonb, error text);
-- C4's load under the adapter's rule: the next record, the chunk size in force, the halvings, the calls made
drop table if exists pg_temp.v0008zk_c4_state;
create temp table v0008zk_c4_state (next_from int, size int, min_size int, halvings int, calls int);

-- The error code a statement raises, or 'ok'
create or replace function pg_temp.v0008zk_code(p_sql text)
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

-- The error a statement raises as code: message, or 'ok'
create or replace function pg_temp.v0008zk_error(p_sql text)
returns text
language plpgsql
as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end
$$;

-- A step's record, written as the owner (the step may have acted as the application)
create or replace function pg_temp.v0008zk_log(p_step text, p_n integer, p_ms numeric, p_answer jsonb, p_error text)
returns void
language plpgsql
as $$
begin
  perform set_config('role', 'cma_owner', true);
  insert into pg_temp.v0008zk_step (step, n, xact, ms, answer, error) values (p_step, p_n, pg_current_xact_id(), p_ms, p_answer, p_error);
end
$$;

-- A throwaway tenant's id, a connection's id by its account, and the step acting as one of the tenant's people (ingest:
-- its Ingest user; admin, analytics: the person the setup made) for the rest of the step's transaction
create or replace function pg_temp.v0008zk_tenant(p_slug text)
returns uuid
language sql
as $$
  select t.id from cma.tenant t where t.slug = p_slug
$$;
create or replace function pg_temp.v0008zk_conn(p_slug text, p_account text)
returns uuid
language sql
as $$
  select c.id from cma.integration_connection c join cma.tenant t on t.id = c.tenant_id where t.slug = p_slug and c.external_account_id = p_account
$$;
create or replace function pg_temp.v0008zk_as(p_slug text, p_who text)
returns uuid
language plpgsql
as $$
declare
  v_t uuid := pg_temp.v0008zk_tenant(p_slug);
  v_u uuid;
begin
  perform set_config('role', 'cma_owner', true);
  if p_who = 'ingest' then
    select x.user_id into v_u from cma.app_user_external_id x where x.tenant_id = v_t and x.system = 'ingest' and x.external_id = 'ingest';
  else
    select u.id into v_u from cma.app_user u where u.tenant_id = v_t and u.email = 'verify-' || p_who || '-' || p_slug || '@example.invalid';
  end if;
  perform set_config('role', 'cma_app', true);
  perform set_config('app.tenant_id', v_t::text, true);
  perform set_config('app.user_id', v_u::text, true);
  return v_t;
end
$$;

-- A throwaway tenant made as the owner: the tenant (with its Ingest user), an admin and an analyst (role analytics).
-- Refused outside dev and local databases
create or replace function pg_temp.v0008zk_new_tenant(p_slug text)
returns uuid
language plpgsql
as $$
declare
  v_t uuid;
  v_u uuid;
  w text;
begin
  if not current_setting('verify.dev')::boolean then
    raise exception 'REFUSED: not dev or a local database (no active agent.two@example.com); 117 makes no tenant here';
  end if;
  v_t := cma.create_tenant(p_slug, 'Verify ' || p_slug, 'Europe/Amsterdam');
  foreach w in array array['admin', 'analytics'] loop
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-' || w || '-' || p_slug || '@example.invalid', w) returning id into v_u;
    insert into cma.user_role (tenant_id, user_id, role_id) select v_t, v_u, ar.id from cma.app_role ar where ar.tenant_id = v_t and ar.key = w;
  end loop;
  return v_t;
end
$$;

-- Removes a throwaway tenant of this script with every row it holds (removeTenants of ingest/verify/lib.mjs). First the
-- tenant's row and its people's are locked (for update): every table with a tenant_id has a foreign key to cma.tenant,
-- so no other session can add a row for the tenant until this one ends. Dev's scheduler starts runs for every tenant
-- (refresh_follow_up, close_forgotten_workdays, a sync_run started by the tenant's Scheduler user); one committed while
-- the cleanup was deleting the devices made app_user's delete fail (dev, 28 October 2026). Then each table of cma with
-- a tenant_id but the audit log, in an order where no remaining table still points to the next (the foreign keys from
-- the catalog: every foreign key into a tenant's rows comes from a table of cma with a tenant_id), then the audit rows
-- (the deletes' own among them), then the tenant. Answers absent, removed, or the error (and then removes nothing).
-- Refused outside dev and local databases
create or replace function pg_temp.v0008zk_cleanup(p_slug text)
returns text
language plpgsql
as $$
declare
  v_t     uuid;
  v_left  text[];
  v_free  text[];
  v_order text[] := '{}';
  t       text;
begin
  if p_slug !~ '^verify-0008zk-[a-z-]+$' then
    raise exception 'not a throwaway tenant of 117: %', p_slug;
  end if;
  if not current_setting('verify.dev')::boolean then
    raise exception 'REFUSED: not dev or a local database (no active agent.two@example.com); 117 removes nothing here';
  end if;
  v_t := pg_temp.v0008zk_tenant(p_slug);
  if v_t is null then
    return 'absent';
  end if;
  perform 1 from cma.tenant t where t.id = v_t for update;
  perform 1 from cma.app_user u where u.tenant_id = v_t for update;
  select array_agg(c.relname::text order by c.relname) into v_left
  from pg_class c join pg_attribute a on a.attrelid = c.oid and a.attname = 'tenant_id' and not a.attisdropped
  where c.relnamespace = 'cma'::regnamespace and c.relkind in ('r', 'p') and not c.relispartition and c.relname <> 'audit_log';
  while cardinality(v_left) > 0 loop
    select array_agg(x order by x) into v_free from unnest(v_left) x
    where not exists (select 1 from pg_constraint k join pg_class ch on ch.oid = k.conrelid join pg_class pa on pa.oid = k.confrelid
                      where k.contype = 'f' and k.connamespace = 'cma'::regnamespace and k.conrelid <> k.confrelid
                        and pa.relname = x and ch.relname = any (v_left));
    if v_free is null then
      raise exception 'the foreign keys among % form a cycle', v_left;
    end if;
    v_order := v_order || v_free;
    v_left := array(select x from unnest(v_left) x where x <> all (v_free) order by x);
  end loop;
  foreach t in array v_order loop
    execute format('delete from cma.%I where tenant_id = $1', t) using v_t;
  end loop;
  delete from cma.audit_log a where a.tenant_id = v_t;
  delete from cma.tenant where id = v_t;
  return 'removed';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end
$$;

-- The cleanup as a step: its answer recorded
create or replace function pg_temp.v0008zk_clean(p_step text, p_slug text)
returns void
language plpgsql
as $$
declare
  v_t0 timestamptz := clock_timestamp();
  v_id uuid := pg_temp.v0008zk_tenant(p_slug);
  v_r  text := pg_temp.v0008zk_cleanup(p_slug);
begin
  perform pg_temp.v0008zk_log(p_step, null, round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1),
                              jsonb_build_object('slug', p_slug, 'tenant', v_id, 'result', v_r), case when v_r in ('absent', 'removed') then null else v_r end);
end
$$;

-- B's register: records p_from to p_to, every value text as the ingest reads it, line g + 1. The night (p_night)
-- changes a subscription reference of every record ending in 3 (outside the stock), the pads serial of every 25th from 5
-- on (a replacement) and the battery expiry of every 50th from 7 on. Every 500th model and every 400th country is
-- outside the catalogs, every 700th customer reference from 7 on is no reference, every 300th order reference from 1 on
-- and every 333rd named id from 2 on is dropped
create or replace function pg_temp.v0008zk_register(p_from integer, p_to integer, p_night boolean)
returns table (source_row integer, source_id text, serial text, model text, status text, country text, customer_ref text,
               subscription_ref text, order_ref text, first_shipped_on text, components text, external_refs text)
language sql
as $$
  select g + 1, 'rec-' || lpad(g::text, 6, '0'), 'SN-' || g,
         case when g % 500 = 0 then 'Model X' else 'HS1' end,
         case when g % 10 = 0 then 'In Storage' else 'Active/Customer' end,
         case when g % 400 = 0 then 'Spain' else 'Netherlands' end,
         case when g % 10 = 0 then null when g % 700 = 7 then 'cu ' || g else 'cu-' || g end,
         case when g % 10 = 0 then null else 'sub-' || g || case when p_night and g % 10 = 3 then 'b' else '' end end,
         case when g % 300 = 1 then '<o' || g || '>' else '#O' || g end,
         '2024-11-15',
         '{"pads": {"serial": "P-' || g || case when p_night and g % 25 = 5 then '-n' else '' end || '", "expires_on": "2026-12-10"}, '
           || '"battery": {"serial": "B-' || g || '", "expires_on": "' || case when p_night and g % 50 = 7 then '2027-02-20' else '2027-01-20' end || '"}}',
         case when g % 333 = 2 then '{"ns_internal_id": "' || g || '", "Bad Key": "x"}' else '{"ns_internal_id": "' || g || '"}' end
  from generate_series(p_from, p_to) g
$$;

-- The same records as one chunk for cma.ingest_load_device_chunk: a JSON array of objects, the staging's columns as keys
create or replace function pg_temp.v0008zk_chunk(p_from integer, p_to integer, p_night boolean)
returns jsonb
language sql
as $$
  select jsonb_agg(to_jsonb(x) order by x.source_row) from pg_temp.v0008zk_register(p_from, p_to, p_night) x
$$;

-- B's record ids over ranges of records
create or replace function pg_temp.v0008zk_ids(p_ranges int4range[])
returns text[]
language sql
as $$
  select array_agg('rec-' || lpad(g::text, 6, '0') order by g) from unnest(p_ranges) rg, generate_series(lower(rg), upper(rg) - 1) g
$$;

-- Slice p_k (from 0) of a run's record ids as the adapter cuts them: sorted by their bytes (collation "C"), p_size a
-- slice; from: the slice's first id (null for the first slice); before: the next slice's first id (null for the last)
create or replace function pg_temp.v0008zk_slice(p_ids text[], p_k integer, p_size integer)
returns table (ids text[], from_id text, before_id text)
language sql
as $$
  with s as (select x, row_number() over (order by x collate "C") - 1 as i from unnest(p_ids) x)
  select array(select s.x from s where s.i / p_size = p_k order by s.x collate "C"),
         (select s.x from s where s.i = p_k * p_size and p_k > 0),
         (select s.x from s where s.i = (p_k + 1) * p_size)
$$;

-- Counts summed over the records of the steps named (each numeric key added; n below p_below when given), and a counts
-- object as one line in a fixed order
create or replace function pg_temp.v0008zk_sum(p_steps text[], p_below integer default null)
returns jsonb
language sql
as $$
  select coalesce(jsonb_object_agg(x.k, x.v), '{}'::jsonb)
  from (select e.key as k, sum((e.value #>> '{}')::numeric) as v
        from pg_temp.v0008zk_step s, jsonb_each(s.answer) e
        where s.step = any (p_steps) and (p_below is null or s.n < p_below) and jsonb_typeof(e.value) = 'number'
        group by e.key) x
$$;
create or replace function pg_temp.v0008zk_counts(j jsonb)
returns text
language sql
as $$
  select concat_ws(' ', 'rows=' || (j ->> 'rows'), 'ins=' || (j ->> 'inserted'), 'upd=' || (j ->> 'updated'), 'same=' || (j ->> 'unchanged'),
                   'missing=' || (j ->> 'missing_now'), 'repl=' || (j ->> 'components_replaced'), 'um=' || (j ->> 'unmapped_model'),
                   'us=' || (j ->> 'unmapped_status'), 'uk=' || (j ->> 'unmapped_market'), 'cri=' || (j ->> 'customer_ref_invalid'),
                   'drop=' || (j ->> 'refs_dropped'))
$$;
-- The first error of the steps named, or null
create or replace function pg_temp.v0008zk_failed(p_steps text[])
returns text
language sql
as $$
  select s.step || coalesce(' ' || s.n, '') || ': ' || s.error from pg_temp.v0008zk_step s
  where s.step = any (p_steps) and s.error is not null order by s.ord limit 1
$$;
-- A check's row (FAIL when provoked)
create or replace function pg_temp.v0008zk_check(p_ord integer, p_name text, p_ok boolean, p_detail text)
returns void
language plpgsql
as $$
begin
  perform set_config('role', 'cma_owner', true);
  insert into pg_temp.verify_0008zk values (p_ord, p_name,
    case when coalesce(p_ok, false) and not current_setting('verify.provoke')::boolean then 'ok' else 'FAIL' end, p_detail);
end
$$;

-- A connection's devices and components as one fingerprint (no id, no time; whether missing, whether current). The
-- components are joined to their devices by hashing (the throwaway tenant has no statistics yet, so a nested loop would
-- read every component once per device)
create or replace function pg_temp.v0008zk_fingerprint(p_connection_id uuid)
returns text
language sql
set enable_nestloop = off
as $$
  select md5(coalesce((select string_agg(concat_ws('|', d.source_id, d.serial, d.model_key, d.market, d.device_status_key, d.warehouse_ref,
                                                   d.customer_ref, d.customer_ref_invalid, d.subscription_ref, d.order_ref, d.first_shipped_on,
                                                   d.stock_received_on, d.last_shipped_on, d.warranty_until, d.end_of_life_on,
                                                   d.external_refs::text, d.raw::text, d.source_deleted_at is not null), ',' order by d.source_id)
                       from cma.device d where d.connection_id = p_connection_id), '')
             || '#' ||
             coalesce((select string_agg(concat_ws('|', d.source_id, c.component_key, c.serial, c.expires_on, c.replaced_at is null), ','
                                         order by d.source_id, c.component_key, c.replaced_at nulls last, c.first_seen_at, c.serial)
                       from cma.device_component c join cma.device d on d.tenant_id = c.tenant_id and d.id = c.device_id
                       where d.connection_id = p_connection_id), ''))
$$;

-- A chunk as a step: the rows built first (the ingest builds them before its call), then one call of
-- cma.ingest_load_device_chunk as the tenant's Ingest user, timed; its answer recorded
create or replace function pg_temp.v0008zk_load(p_step text, p_n integer, p_slug text, p_account text, p_rows jsonb)
returns void
language plpgsql
as $$
declare
  v_conn uuid := pg_temp.v0008zk_conn(p_slug, p_account);
  v_t0   timestamptz;
  j      jsonb;
begin
  perform pg_temp.v0008zk_as(p_slug, 'ingest');
  v_t0 := clock_timestamp();
  j := cma.ingest_load_device_chunk(v_conn, p_rows);
  perform pg_temp.v0008zk_log(p_step, p_n, round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1), j, null);
exception when others then
  perform pg_temp.v0008zk_log(p_step, p_n, null, null, sqlstate || ': ' || sqlerrm);
end
$$;

-- A slice of the final step as a step: one call of cma.ingest_mark_devices_missing as the tenant's Ingest user with the
-- slice's ids and range, timed; its answer recorded
create or replace function pg_temp.v0008zk_mark(p_step text, p_k integer, p_slug text, p_account text, p_ids text[])
returns void
language plpgsql
as $$
declare
  v_conn uuid := pg_temp.v0008zk_conn(p_slug, p_account);
  s      record;
  v_t0   timestamptz;
  j      jsonb;
begin
  select * into s from pg_temp.v0008zk_slice(p_ids, p_k, 1000);
  perform pg_temp.v0008zk_as(p_slug, 'ingest');
  v_t0 := clock_timestamp();
  j := cma.ingest_mark_devices_missing(v_conn, s.ids, s.from_id, s.before_id);
  perform pg_temp.v0008zk_log(p_step, p_k, round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1),
                              j || jsonb_build_object('ids', cardinality(s.ids)), null);
exception when others then
  perform pg_temp.v0008zk_log(p_step, p_k, null, null, sqlstate || ': ' || sqlerrm);
end
$$;

-- B's steps: a chunk of the register (part p: records p * 1,000 + 1 to p * 1,000 + 1,000; the night's part 9 is records
-- 10,001 to 11,000) into one of tenant one's connections, and a slice of the night's final step (the night read records
-- 1 to p_upto, less 9,001 to 10,000 when p_upto is 11,000)
create or replace function pg_temp.v0008zk_b_load(p_step text, p_account text, p_part integer, p_night boolean)
returns void
language sql
as $$
  select pg_temp.v0008zk_load(p_step, p_part, 'verify-0008zk-one', p_account,
           case when p_night and p_part = 9 then pg_temp.v0008zk_chunk(10001, 11000, true)
                else pg_temp.v0008zk_chunk(p_part * 1000 + 1, p_part * 1000 + 1000, p_night) end)
$$;
create or replace function pg_temp.v0008zk_b_final(p_step text, p_k integer, p_upto integer)
returns void
language sql
as $$
  select pg_temp.v0008zk_mark(p_step, p_k, 'verify-0008zk-one', 'base-chunks',
           pg_temp.v0008zk_ids(case when p_upto = 11000 then array[int4range(1, 9001), int4range(10001, 11001)] else array[int4range(1, p_upto + 1)] end))
$$;

-- C's register at the horizon: records p_from to p_to with dates spread around 28 October 2026 (the forecast's day):
-- two models, two markets, a tenth in stock, every fifth shipped again, every seventh with an end of life, every
-- eleventh pads without an expiry (due by rule)
create or replace function pg_temp.v0008zk_volume(p_from integer, p_to integer)
returns jsonb
language sql
as $$
  select jsonb_agg(jsonb_build_object(
           'source_row', g + 1, 'source_id', 'vol-' || lpad(g::text, 6, '0'), 'serial', 'VS-' || g,
           'model', case when g % 3 = 0 then 'FRx' else 'HS1' end,
           'status', case when g % 10 = 0 then 'In Storage' else 'Active/Customer' end,
           'country', case when g % 4 = 0 then 'United Kingdom' else 'Netherlands' end,
           'customer_ref', case when g % 10 <> 0 then 'cu-' || g end, 'subscription_ref', case when g % 10 <> 0 then 'sub-' || g end,
           'first_shipped_on', (date '2026-10-28' - (g % 1400))::text,
           'last_shipped_on', case when g % 5 = 0 then (date '2026-10-28' - (g % 300))::text end,
           'end_of_life_on', case when g % 7 = 0 then (date '2026-10-28' + (g % 1200) - 100)::text end,
           'components', jsonb_build_object(
             'pads', jsonb_strip_nulls(jsonb_build_object('serial', 'VP-' || g,
                                                          'expires_on', case when g % 11 <> 0 then (date '2026-10-28' + (g * 37 % 900) - 150)::text end)),
             'battery', jsonb_build_object('serial', 'VB-' || g, 'expires_on', (date '2026-10-28' + (g * 53 % 1100) - 100)::text))::text,
           'external_refs', jsonb_build_object('ns_internal_id', g::text)::text) order by g)
  from generate_series(p_from, p_to) g
$$;
create or replace function pg_temp.v0008zk_volume_ids(p_from integer, p_to integer)
returns text[]
language sql
as $$
  select array_agg('vol-' || lpad(g::text, 6, '0') order by g) from generate_series(p_from, p_to) g
$$;

-- The best of three runs of a statement, in milliseconds
create or replace function pg_temp.v0008zk_best_ms(p_sql text)
returns numeric
language plpgsql
as $$
declare
  v_t0   timestamptz;
  v_best numeric;
  r      record;
begin
  for i in 1 .. 3 loop
    v_t0 := clock_timestamp();
    for r in execute p_sql loop
      null;
    end loop;
    v_best := least(coalesce(v_best, 1e9), round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1));
  end loop;
  return v_best;
end
$$;

-- The device tables' statistics read, as autovacuum keeps them in a database that holds the devices (before C1, the
-- register as the mirror holds it after earlier nights; before B8's reads, which would otherwise plan tenant one's
-- 20,000 devices on the statistics of a table that held none of them). Skipped outside dev and local databases
create or replace function pg_temp.v0008zk_analyze()
returns void
language plpgsql
as $$
begin
  if not current_setting('verify.dev')::boolean then
    perform pg_temp.v0008zk_log('analyze', null, null, null, 'REFUSED: not dev or a local database; no statistics read');
    return;
  end if;
  analyze cma.device;
  analyze cma.device_component;
  perform pg_temp.v0008zk_log('analyze', null, null, null, null);
end
$$;

-- -----------------------------------------------------------------------------------------------
-- The start: what an interrupted run left is removed
-- -----------------------------------------------------------------------------------------------
begin; select pg_temp.v0008zk_clean('start', 'verify-0008zk-one'); commit;
begin; select pg_temp.v0008zk_clean('start', 'verify-0008zk-two'); commit;
begin; select pg_temp.v0008zk_clean('start', 'verify-0008zk-one-call'); commit;
begin; select pg_temp.v0008zk_clean('start', 'verify-0008zk-volume'); commit;

-- -----------------------------------------------------------------------------------------------
-- A. Structure and privileges (universal; reads only)
-- -----------------------------------------------------------------------------------------------
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_bad     text;
  v_fn      text;
  v_def     text;
begin
  -- A1. the addition is recorded, after 0008zj
  insert into verify_0008zk values (1, 'A1 addition 0008zk recorded, after 0008zj',
    case when exists (select 1 from cma.schema_migration where version = '0008zk')
              and exists (select 1 from cma.schema_migration where version = '0008zj') and not v_provoke then 'ok' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the load's row types with their columns; the staging trigger still on the COPY target
  v_bad := '';
  if (select count(*) from pg_attribute where attrelid = (select typrelid from pg_type where oid = to_regtype('cma.device_load_row')) and attnum > 0) <> 17
     or (select count(*) from pg_attribute where attrelid = (select typrelid from pg_type where oid = to_regtype('cma.device_load_mapped')) and attnum > 0) <> 20
     or (select count(*) from pg_attribute where attrelid = (select typrelid from pg_type where oid = to_regtype('cma.device_load_component')) and attnum > 0) <> 6 then
    v_bad := v_bad || 'types; ';
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'cma.device_import_staging'::regclass and tgname = 'stage_row' and not tgisinternal) then
    v_bad := v_bad || 'staging trigger; ';
  end if;
  insert into verify_0008zk values (2, 'A2 the load''s row types; the staging trigger on the COPY target',
    case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_bad);

  -- A3. every function the application's only and in the caller's rights, the trigger function nobody's; the load in one
  --     place, set-based: no row loop, no row lock, no helper with a subtransaction, the advisory lock; the file path and
  --     the chunks call it, neither writes a device
  v_bad := '';
  foreach v_fn in array array[
    'cma.device_staged_json(text)', 'cma.device_staged_date_ok(text)', 'cma.device_staged_ref(text)',
    'cma.device_rows_apply(uuid,cma.device_load_row[],boolean)', 'cma.device_snapshot_apply(text,uuid,boolean)',
    'cma.ingest_load_device_chunk(uuid,jsonb)', 'cma.ingest_mark_devices_missing(uuid,text[],text,text)', 'cma.assets_settings_problem(jsonb)',
    'cma.set_connection_settings(uuid,jsonb)', 'cma.ingest_sync_run_finish(uuid,text,jsonb,text)', 'cma.ingest_record_field_types(uuid,jsonb)',
    'cma.load_device_snapshot(text,uuid,boolean)', 'cma.ingest_load_device_snapshot(uuid,text,boolean)',
    'cma.maintenance_exchange_step(date,date,integer)', 'cma.maintenance_exchange_start(date,integer)',
    'cma.maintenance_bucket_dates_of(uuid,date,integer,text,text,text,date)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure(v_fn) and a.grantee = 0) then
      v_bad := v_bad || v_fn || '; ';
    end if;
  end loop;
  if to_regprocedure('cma.device_import_staging_insert()') is null
     or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = 'cma.device_import_staging_insert()'::regprocedure and a.grantee = 0)
     or has_function_privilege('cma_readonly', 'cma.device_import_staging_insert()', 'execute') then
    v_bad := v_bad || 'cma.device_import_staging_insert(); ';
  end if;
  if to_regprocedure('cma.device_rows_apply(uuid,cma.device_load_row[],boolean)') is not null then
    v_def := lower(pg_get_functiondef('cma.device_rows_apply(uuid,cma.device_load_row[],boolean)'::regprocedure));
    if v_def ~ '\mloop\M' or v_def like '%for update%' or v_def like '%device_staged_date(%' or v_def like '%device_staged_object(%'
       or v_def not like '%pg_advisory_xact_lock%' or v_def like '%sync_run%' then
      v_bad := v_bad || 'the load set-based; ';
    end if;
    if pg_get_functiondef('cma.device_snapshot_apply(text,uuid,boolean)'::regprocedure) not like '%cma.device_rows_apply(%'
       or pg_get_functiondef('cma.ingest_load_device_chunk(uuid,jsonb)'::regprocedure) not like '%cma.device_rows_apply(%'
       or pg_get_functiondef('cma.device_snapshot_apply(text,uuid,boolean)'::regprocedure) like '%cma.device %'
       or pg_get_functiondef('cma.ingest_load_device_chunk(uuid,jsonb)'::regprocedure) like '%cma.device %'
       or pg_get_functiondef('cma.ingest_load_device_chunk(uuid,jsonb)'::regprocedure) like '%device_import_%' then
      v_bad := v_bad || 'the load in one place; ';
    end if;
  end if;
  insert into verify_0008zk values (3, 'A3 every function the application''s only and invoker, the trigger function nobody''s; the load set-based in one place',
    case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_bad);

  -- A4. the setting assets_load_chunk by form: a whole number from 100 to 5,000; 0008zj's keys as before
  v_bad := concat_ws(' ',
    coalesce(cma.assets_settings_problem('{"assets_load_chunk": 1000}'), 'ok'),
    coalesce(cma.assets_settings_problem('{"assets_load_chunk": "100"}'), 'ok'),
    coalesce(cma.assets_settings_problem('{"assets_load_chunk": 5000, "assets_poll_interval_minutes": 15}'), 'ok'),
    coalesce(cma.assets_settings_problem('{"assets_load_chunk": 99}'), 'ok'),
    coalesce(cma.assets_settings_problem('{"assets_load_chunk": 5001}'), 'ok'),
    coalesce(cma.assets_settings_problem('{"assets_load_chunk": 1000.5}'), 'ok'),
    coalesce(cma.assets_settings_problem('{"assets_load_chunk": "1k"}'), 'ok'),
    coalesce(cma.assets_settings_problem('{"assets_load_chunk": true}'), 'ok'),
    coalesce(cma.assets_settings_problem('{"table_id": "tbl abc", "assets_load_chunk": 1000}'), 'ok'));
  insert into verify_0008zk values (4, 'A4 the setting assets_load_chunk by form: a whole number from 100 to 5,000',
    case when v_bad = 'ok ok ok assets_load_chunk assets_load_chunk assets_load_chunk assets_load_chunk assets_load_chunk table_id'
              and not v_provoke then 'ok' else 'FAIL' end, v_bad);

  -- A5. the value checks read as 0008zi's helpers read: a JSON object where cma.device_staged_object takes it (null
  --     where it refuses), a date where cma.device_staged_date takes it, a reference as 0008zi's pattern keeps it
  select string_agg(v.x, ',' order by v.x) into v_bad
  from (select coalesce(t, 'null') || '=' || case when (cma.device_staged_json(t) is null)
                                                    = (pg_temp.v0008zk_code(format('select cma.device_staged_object(%L, 2, ''c'')', t)) <> 'ok')
                                                    and (cma.device_staged_json(t) is null or cma.device_staged_json(t) = cma.device_staged_object(t, 2, 'c'))
                                                  then 'same' else 'differs' end as x
        from unnest(array[null, '', '  ', '{"a": 1}', ' {"pads": {"serial": "P"}} ', '[1]', '"x"', '12', 'nope', '{"a": 1']) t
        union all
        select coalesce(t, 'null') || '=' || case when cma.device_staged_date_ok(t)
                                                    = (pg_temp.v0008zk_code(format('select cma.device_staged_date(%L, 2, ''d'')', t)) = 'ok')
                                                  then 'same' else 'differs' end
        from unnest(array[null, '', '2028-02-29', '2026-02-29', ' 2026-01-01 ', '2026-1-01', '2026-13-01', '0000-01-01', '15/11/2024']) t
        union all
        select left(coalesce(t, 'null'), 12) || '=' || case when cma.device_staged_ref(t) is not distinct from
                                                                   (case when cma.device_staged_text(t) ~ '^[A-Za-z0-9#][A-Za-z0-9 _.#:/-]{0,99}$'
                                                                         then cma.device_staged_text(t) end)
                                                             then 'same' else 'differs' end
        from unnest(array[null, '', 'SN-1', ' SN 1 ', '#O1', '-x', 'a@b', '<o1>', 'é1', repeat('a', 100), repeat('a', 101),
                          '#' || repeat('b', 99), 'a/b:c.d_e#f']) t) v;
  insert into verify_0008zk values (5, 'A5 the value checks read as 0008zi''s helpers: JSON objects, dates, references',
    case when v_bad not like '%differs%' and not v_provoke then 'ok' else 'FAIL' end,
    case when v_bad like '%differs%' then v_bad else 'every sample the same' end);

  -- A6. the final step in slices (the two-argument form gone), by the partial range index on present devices in byte
  --     order; the components indexed by device (their foreign key); the forecast without a row loop: the items one
  --     statement with the exchange as a running aggregate, the page and the list over the buckets as dates
  v_bad := '';
  if to_regprocedure('cma.ingest_mark_devices_missing(uuid,text[])') is not null then
    v_bad := v_bad || 'the two-argument final step; ';
  end if;
  if not exists (select 1 from pg_indexes where schemaname = 'cma' and tablename = 'device' and indexname = 'device_present_source_c_idx'
                   and indexdef like '%(tenant_id, connection_id, source_id COLLATE "C")%' and indexdef like '%WHERE (source_deleted_at IS NULL)%') then
    v_bad := v_bad || 'the range index; ';
  end if;
  if not exists (select 1 from pg_indexes where schemaname = 'cma' and tablename = 'device_component' and indexname = 'device_component_device_idx'
                   and indexdef like '%(tenant_id, device_id)%' and indexdef not like '%WHERE%') then
    v_bad := v_bad || 'the components'' index by device; ';
  end if;
  if (select l.lanname from pg_proc p join pg_language l on l.oid = p.prolang where p.oid = to_regprocedure('cma.maintenance_items_of(uuid,date)')) <> 'sql'
     or pg_get_functiondef('cma.maintenance_items_of(uuid,date)'::regprocedure) not like '%cma.maintenance_exchange_start(%'
     or (select prokind from pg_proc where oid = to_regprocedure('cma.maintenance_exchange_start(date,integer)')) <> 'a'
     or pg_get_functiondef('cma.maintenance_page_of(uuid,date,integer,text,text,text,date)'::regprocedure) not like '%cma.maintenance_bucket_dates_of(%'
     or pg_get_functiondef('cma.maintenance_rows_of(uuid,date,integer,text,text,text,text,text,integer,date)'::regprocedure) not like '%cma.maintenance_bucket_dates_of(%' then
    v_bad := v_bad || 'the forecast; ';
  end if;
  insert into verify_0008zk values (6, 'A6 the final step in slices by the range index on present devices; the components by device; the forecast without a row loop',
    case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_bad);
end
$$;

-- -----------------------------------------------------------------------------------------------
-- C3. The one-call path (115's C1), first and in a fresh transaction: the register of 5,000 devices loaded as 115 loads
--     it (staged in parts of 500, each loaded in one call and the statistics read), then the night's full snapshot of
--     them all, unchanged, staged and loaded in one call as the Ingest user
-- -----------------------------------------------------------------------------------------------
create or replace function pg_temp.v0008zk_c3_setup()
returns void
language plpgsql
as $$
declare
  v_t uuid;
begin
  v_t := pg_temp.v0008zk_new_tenant('verify-0008zk-one-call');
  insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
  values (v_t, 'verifyregister', 'Verify register one call', 'base-zk-c', 'assets', 'verify-register-token-zk-c');
  perform pg_temp.v0008zk_as('verify-0008zk-one-call', 'admin');
  perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR', null, null, 20);
  perform cma.set_market_alias('netherlands', 'NL');
  insert into cma.device_model (key, name, aliases) values ('hs1', 'HS1', array['hs1']);
  insert into cma.device_component_kind (key, name, sort_order) values ('pads', 'Pads', 10), ('battery', 'Battery', 20);
  insert into cma.device_status (key, name, is_in_field, is_in_stock, is_tracked, aliases) values
    ('active_customer', 'Active/Customer', true, false, true, array['active/customer']);
  perform pg_temp.v0008zk_log('c3-setup', null, null, jsonb_build_object('tenant', v_t), null);
exception when others then
  perform pg_temp.v0008zk_log('c3-setup', null, null, null, sqlstate || ': ' || sqlerrm);
end
$$;
-- Part p of the register: records p * 500 + 1 to p * 500 + 500 staged and loaded (a partial batch), then the statistics
create or replace function pg_temp.v0008zk_c3_part(p_part integer)
returns void
language plpgsql
as $$
declare
  v_reg uuid := pg_temp.v0008zk_conn('verify-0008zk-one-call', 'base-zk-c');
begin
  perform pg_temp.v0008zk_as('verify-0008zk-one-call', 'ingest');
  insert into cma.device_import_staging (batch_key, source_row, source_id, serial, model, status, country, customer_ref, subscription_ref,
                                         first_shipped_on, components, external_refs)
  select 'volume-' || p_part, g - p_part * 500 + 1, 'rec-' || g, 'SN-' || g, 'HS1', 'Active/Customer', 'Netherlands', 'cu-' || g, 'sub-' || g, '2024-11-15',
         '{"pads": {"serial": "P-' || g || '", "expires_on": "2026-12-10"}, "battery": {"serial": "B-' || g || '", "expires_on": "2027-01-20"}}',
         '{"ns_internal_id": "' || g || '"}'
  from generate_series(p_part * 500 + 1, p_part * 500 + 500) g;
  perform cma.ingest_load_device_snapshot(v_reg, 'volume-' || p_part, false);
  perform set_config('role', 'cma_owner', true);
  analyze cma.device;
  analyze cma.device_component;
  analyze cma.device_import_row;
  perform pg_temp.v0008zk_log('c3-register', p_part, null, null, null);
exception when others then
  perform pg_temp.v0008zk_log('c3-register', p_part, null, null, sqlstate || ': ' || sqlerrm);
end
$$;
-- C3. the night, timed from the staging insert to the load's answer
create or replace function pg_temp.v0008zk_c3()
returns void
language plpgsql
as $$
declare
  v_reg   uuid := pg_temp.v0008zk_conn('verify-0008zk-one-call', 'base-zk-c');
  v_max   numeric := current_setting('verify.max_one_call_ms')::numeric;
  v_t0    timestamptz;
  v_stage numeric;
  v_ms    numeric;
  v_err   text := pg_temp.v0008zk_failed(array['c3-setup', 'c3-register']);
  j       jsonb;
begin
  begin
    perform pg_temp.v0008zk_as('verify-0008zk-one-call', 'ingest');
    v_t0 := clock_timestamp();
    insert into cma.device_import_staging (batch_key, source_row, source_id, serial, model, status, country, customer_ref, subscription_ref,
                                           first_shipped_on, components, external_refs)
    select 'volume-night', g + 1, 'rec-' || g, 'SN-' || g, 'HS1', 'Active/Customer', 'Netherlands', 'cu-' || g, 'sub-' || g, '2024-11-15',
           '{"pads": {"serial": "P-' || g || '", "expires_on": "2026-12-10"}, "battery": {"serial": "B-' || g || '", "expires_on": "2027-01-20"}}',
           '{"ns_internal_id": "' || g || '"}'
    from generate_series(1, 5000) g;
    v_stage := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
    j := cma.ingest_load_device_snapshot(v_reg, 'volume-night', true);
    v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
    perform pg_temp.v0008zk_log('c3', null, v_ms, j, null);
  exception when others then
    v_err := coalesce(v_err, sqlstate || ': ' || sqlerrm);
  end;
  perform pg_temp.v0008zk_check(53, 'C3 115''s C1 again in a fresh transaction: a full snapshot of 5,000 unchanged records staged and loaded in one call, under verify.max_one_call_ms, its phases',
    v_err is null and v_ms < v_max and pg_temp.v0008zk_counts(j) = 'rows=5000 ins=0 upd=0 same=5000 missing=0 repl=0 um=0 us=0 uk=0 cri=0 drop=0',
    coalesce(v_err, format('%s ms (budget %s): staging insert %s; load: stage %s, map %s, upsert %s, components %s, missing %s, cleanup %s; %s',
                           v_ms, v_max, v_stage, j ->> 'stage_ms', j ->> 'map_ms', j ->> 'upsert_ms', j ->> 'components_ms', j ->> 'missing_ms',
                           j ->> 'cleanup_ms', pg_temp.v0008zk_counts(j))));
end
$$;

begin; select pg_temp.v0008zk_c3_setup(); commit;
begin; select pg_temp.v0008zk_c3_part(0); commit;
begin; select pg_temp.v0008zk_c3_part(1); commit;
begin; select pg_temp.v0008zk_c3_part(2); commit;
begin; select pg_temp.v0008zk_c3_part(3); commit;
begin; select pg_temp.v0008zk_c3_part(4); commit;
begin; select pg_temp.v0008zk_c3_part(5); commit;
begin; select pg_temp.v0008zk_c3_part(6); commit;
begin; select pg_temp.v0008zk_c3_part(7); commit;
begin; select pg_temp.v0008zk_c3_part(8); commit;
begin; select pg_temp.v0008zk_c3_part(9); commit;
begin; select pg_temp.v0008zk_c3(); commit;
begin; select pg_temp.v0008zk_clean('end', 'verify-0008zk-one-call'); commit;

-- -----------------------------------------------------------------------------------------------
-- B. Behaviour on two throwaway tenants
-- -----------------------------------------------------------------------------------------------
-- Tenants one and two (each with its Ingest user, admin and analyst), the connections and each tenant's catalogs
create or replace function pg_temp.v0008zk_b_setup()
returns void
language plpgsql
as $$
declare
  v_t1 uuid;
  v_t2 uuid;
begin
  v_t1 := pg_temp.v0008zk_new_tenant('verify-0008zk-one');
  v_t2 := pg_temp.v0008zk_new_tenant('verify-0008zk-two');
  insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name) values
    (v_t1, 'verifyregister', 'Verify register one call', 'base-one', 'assets', 'verify-register-token-one'),
    (v_t1, 'verifyregister', 'Verify register chunks', 'base-chunks', 'assets', 'verify-register-token-chunks'),
    (v_t1, 'verifycrm', 'Verify CRM', 'portal-1', 'crm', 'verify-crm-token-1'),
    (v_t2, 'verifyregister', 'Verify register two', 'base-two', 'assets', 'verify-register-token-two');
  insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
  values (v_t1, 'verifyregister', 'Verify register from files', 'base-csv', 'assets');
  insert into cma.device_component_kind (tenant_id, key, name, sort_order) values (v_t2, 'pads', 'Pads', 10), (v_t2, 'battery', 'Battery', 20);
  perform pg_temp.v0008zk_as('verify-0008zk-one', 'admin');
  perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR', null, null, 20);
  perform cma.set_market_alias('netherlands', 'NL');
  insert into cma.device_model (key, name, aliases) values ('hs1', 'HS1', array['hs1']);
  insert into cma.device_component_kind (key, name, sort_order) values ('pads', 'Pads', 10), ('battery', 'Battery', 20);
  insert into cma.device_status (key, name, is_in_field, is_in_stock, is_tracked, aliases, sort_order) values
    ('active_customer', 'Active/Customer', true, false, true, array['active/customer'], 10),
    ('in_storage', 'In Storage', false, true, true, array['in storage'], 20);
  perform pg_temp.v0008zk_log('b-setup', null, null, jsonb_build_object('tenants', array[v_t1, v_t2]), null);
exception when others then
  perform pg_temp.v0008zk_log('b-setup', null, null, null, sqlstate || ': ' || sqlerrm);
end
$$;

-- The two connections' fingerprints compared, the second's kept, and its devices marked missing counted
create or replace function pg_temp.v0008zk_b_fp(p_step text)
returns void
language plpgsql
as $$
begin
  perform pg_temp.v0008zk_log(p_step, null, null, jsonb_build_object(
    'equal', pg_temp.v0008zk_fingerprint(pg_temp.v0008zk_conn('verify-0008zk-one', 'base-one'))
             = pg_temp.v0008zk_fingerprint(pg_temp.v0008zk_conn('verify-0008zk-one', 'base-chunks')),
    'fp', pg_temp.v0008zk_fingerprint(pg_temp.v0008zk_conn('verify-0008zk-one', 'base-chunks')),
    'missing', (select count(*) from cma.device d where d.connection_id = pg_temp.v0008zk_conn('verify-0008zk-one', 'base-chunks')
                                                    and d.source_deleted_at is not null)), null);
exception when others then
  perform pg_temp.v0008zk_log(p_step, null, null, null, sqlstate || ': ' || sqlerrm);
end
$$;

-- B1's one call: the night staged (records 1 to 9,000 and 10,001 to 11,000) and loaded into the first connection
create or replace function pg_temp.v0008zk_b1_one_call()
returns void
language plpgsql
as $$
declare
  v_one uuid := pg_temp.v0008zk_conn('verify-0008zk-one', 'base-one');
  v_n   integer;
  j     jsonb;
begin
  perform pg_temp.v0008zk_as('verify-0008zk-one', 'ingest');
  insert into cma.device_import_staging (batch_key, source_row, source_id, serial, model, status, country, customer_ref, subscription_ref,
                                         order_ref, first_shipped_on, components, external_refs)
  select 'night-one', x.source_row, x.source_id, x.serial, x.model, x.status, x.country, x.customer_ref, x.subscription_ref, x.order_ref,
         x.first_shipped_on, x.components, x.external_refs
  from unnest(array[int4range(1, 9001), int4range(10001, 11001)]) rg, pg_temp.v0008zk_register(lower(rg), upper(rg) - 1, true) x;
  select count(*) into v_n from cma.device_import_staging s where s.batch_key = 'night-one';
  j := cma.ingest_load_device_snapshot(v_one, 'night-one', true);
  perform pg_temp.v0008zk_log('b1-one-call', null, null, j || jsonb_build_object('staged', v_n), null);
exception when others then
  perform pg_temp.v0008zk_log('b1-one-call', null, null, null, sqlstate || ': ' || sqlerrm);
end
$$;

-- B1. the night's full snapshot of 10,000 in ten chunks and the final step's ten slices: the same counts, devices and
--     components as one call; nothing left staged
create or replace function pg_temp.v0008zk_b1()
returns void
language plpgsql
as $$
declare
  v_expect constant text := 'rows=10000 ins=1000 upd=1440 same=7560 missing=1000 repl=360 um=20 us=0 uk=24 cri=14 drop=64';
  v_err text := pg_temp.v0008zk_failed(array['b-setup', 'b1-register', 'b1-register-fp', 'b1-one-call', 'b1-night', 'b1-final']);
  v_txt text;
  j     jsonb := (select s.answer from pg_temp.v0008zk_step s where s.step = 'b1-one-call');
begin
  v_txt := (select s.answer ->> 'equal' from pg_temp.v0008zk_step s where s.step = 'b1-register-fp') || ' ' || (j ->> 'staged') || ' '
           || pg_temp.v0008zk_counts(j) || ' | ' || pg_temp.v0008zk_counts(pg_temp.v0008zk_sum(array['b1-night', 'b1-final'])) || ' '
           || (pg_temp.v0008zk_fingerprint(pg_temp.v0008zk_conn('verify-0008zk-one', 'base-one'))
               = pg_temp.v0008zk_fingerprint(pg_temp.v0008zk_conn('verify-0008zk-one', 'base-chunks')))::text
           || ' ' || (select count(*) from cma.device_import_row s where s.tenant_id = pg_temp.v0008zk_tenant('verify-0008zk-one'))
           || ' ' || (select count(*) from pg_temp.v0008zk_step s where s.step in ('b1-register', 'b1-night', 'b1-final'));
  perform pg_temp.v0008zk_check(11, 'B1 the night''s full snapshot of 10,000 in ten chunks and the final step''s ten slices: the same counts, devices and components as one call',
    v_err is null and v_txt = 'true 10000 ' || v_expect || ' | ' || v_expect || ' true 0 40', coalesce(v_err, v_txt));
exception when others then
  perform pg_temp.v0008zk_check(11, 'B1 the night''s full snapshot', false, sqlstate || ': ' || sqlerrm);
end
$$;

-- B2. a rerun of the same chunks and slices: every row unchanged, nothing marked, the devices as they were
create or replace function pg_temp.v0008zk_b2()
returns void
language plpgsql
as $$
declare
  v_err text := pg_temp.v0008zk_failed(array['b2-fp', 'b2', 'b2-final']);
  v_txt text;
begin
  v_txt := pg_temp.v0008zk_counts(pg_temp.v0008zk_sum(array['b2', 'b2-final'])) || ' '
           || (pg_temp.v0008zk_fingerprint(pg_temp.v0008zk_conn('verify-0008zk-one', 'base-chunks'))
               = (select s.answer ->> 'fp' from pg_temp.v0008zk_step s where s.step = 'b2-fp'))::text;
  perform pg_temp.v0008zk_check(12, 'B2 a rerun of the same chunks and slices changes nothing',
    v_err is null and v_txt = 'rows=10000 ins=0 upd=0 same=10000 missing=0 repl=0 um=20 us=0 uk=24 cri=14 drop=64 true', coalesce(v_err, v_txt));
exception when others then
  perform pg_temp.v0008zk_check(12, 'B2 a rerun changes nothing', false, sqlstate || ': ' || sqlerrm);
end
$$;

-- B3. a run that fails before its final step (records 1 to 8,000 read, four chunks loaded, then the failure) marks
--     nothing missing; the rerun reloads those four chunks unchanged and its final step's eight slices mark the 2,000 it
--     did not read (8,001 to 9,000 and 10,001 to 11,000); a chunk with a bad row loads nothing of the chunk
create or replace function pg_temp.v0008zk_b3()
returns void
language plpgsql
as $$
declare
  v_parts uuid := pg_temp.v0008zk_conn('verify-0008zk-one', 'base-chunks');
  v_err   text := pg_temp.v0008zk_failed(array['b3-fp', 'b3-failed', 'b3-failed-fp', 'b3-rerun', 'b3-final']);
  v_fp    text;
  v_txt   text;
begin
  v_txt := (select s.answer ->> 'missing' from pg_temp.v0008zk_step s where s.step = 'b3-fp') || ' '
           || (select s.answer ->> 'missing' from pg_temp.v0008zk_step s where s.step = 'b3-failed-fp') || ' '
           || pg_temp.v0008zk_counts(pg_temp.v0008zk_sum(array['b3-rerun'], 4)) || ' '
           || (pg_temp.v0008zk_sum(array['b3-final']) ->> 'missing_now') || ' '
           || (select count(*) from cma.device d where d.connection_id = v_parts and d.source_deleted_at is not null);
  -- a chunk whose 500th row holds no date: refused, naming the line, and nothing of the chunk written
  v_fp := pg_temp.v0008zk_fingerprint(v_parts);
  perform pg_temp.v0008zk_as('verify-0008zk-one', 'ingest');
  v_txt := v_txt || ' | ' || pg_temp.v0008zk_error(format('select cma.ingest_load_device_chunk(%L, %L)', v_parts,
             (select jsonb_agg(case when (e ->> 'source_row')::integer = 501 then e || '{"first_shipped_on": "15/11/2024"}'::jsonb
                                    else e || '{"subscription_ref": "sub-changed"}'::jsonb end order by n)
              from jsonb_array_elements(pg_temp.v0008zk_chunk(1, 1000, true)) with ordinality x(e, n))));
  perform set_config('role', 'cma_owner', true);
  v_txt := v_txt || ' ' || (pg_temp.v0008zk_fingerprint(v_parts) = v_fp)::text;
  perform pg_temp.v0008zk_check(13, 'B3 a run that fails before its final step marks nothing missing; the rerun''s chunks unchanged; a chunk with a bad row loads nothing',
    v_err is null and v_txt = '1000 1000 rows=4000 ins=0 upd=0 same=4000 missing=0 repl=0 um=8 us=0 uk=10 cri=6 drop=27 2000 3000 '
                              || '| CMA04: line 501: first_shipped_on is not a date as YYYY-MM-DD true', coalesce(v_err, v_txt));
exception when others then
  perform pg_temp.v0008zk_check(13, 'B3 a run that fails before its final step marks nothing missing', false, sqlstate || ': ' || sqlerrm);
end
$$;

-- B4. row-level security: tenant two's Ingest user finds neither of tenant one's connections (CMA02) and loads its own;
--     each tenant sees its own devices only; tenant two's final step leaves tenant one's devices as they were
create or replace function pg_temp.v0008zk_b4()
returns void
language plpgsql
as $$
declare
  v_parts uuid := pg_temp.v0008zk_conn('verify-0008zk-one', 'base-chunks');
  v_reg2  uuid := pg_temp.v0008zk_conn('verify-0008zk-two', 'base-two');
  v_fp    text := pg_temp.v0008zk_fingerprint(v_parts);
  v_txt   text;
  j jsonb;
  k jsonb;
begin
  perform pg_temp.v0008zk_as('verify-0008zk-two', 'ingest');
  v_txt := pg_temp.v0008zk_code(format('select cma.ingest_load_device_chunk(%L, %L)', v_parts, pg_temp.v0008zk_chunk(1, 3, false)))
           || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_mark_devices_missing(%L, %L, null, null)', v_parts, array['rec-000001']));
  j := cma.ingest_load_device_chunk(v_reg2, pg_temp.v0008zk_chunk(1, 3, false));
  k := cma.ingest_mark_devices_missing(v_reg2, array['rec-000001', 'rec-000002'], null, null);
  v_txt := v_txt || ' ' || pg_temp.v0008zk_counts(j) || ' ' || (k ->> 'missing_now')
           || ' ' || (select count(*) from cma.device) || '/' || (select count(*) from cma.device_component)
           || ' ' || (select count(*) from cma.device d where d.connection_id = v_parts);
  perform pg_temp.v0008zk_as('verify-0008zk-one', 'ingest');
  v_txt := v_txt || ' ' || (select count(*) from cma.device d where d.connection_id = v_reg2);
  perform set_config('role', 'cma_owner', true);
  v_txt := v_txt || ' ' || (pg_temp.v0008zk_fingerprint(v_parts) = v_fp)::text;
  perform pg_temp.v0008zk_check(14, 'B4 row-level security: each Ingest user loads, marks and sees its own tenant only',
    v_txt = 'CMA02 CMA02 rows=3 ins=3 upd=0 same=0 missing=0 repl=0 um=3 us=3 uk=3 cri=0 drop=2 1 3/6 0 0 true', v_txt);
exception when others then
  perform pg_temp.v0008zk_check(14, 'B4 row-level security', false, sqlstate || ': ' || sqlerrm);
end
$$;

-- B5. the refusals: a person (CMA06); a connection without a token secret name, a CRM connection (CMA04); a chunk that
--     is no array, empty, over 5,000 rows, a row no object, a key outside the staging's columns, a line outside 2 to
--     10,000,000 or no number, a value longer than the staging takes, a record id twice, a row without one; a slice
--     without ids, with a null, with more than 5,000 ids, with a bound that is no id, with bounds out of order, with an
--     id outside its range (CMA04, nothing marked). An address is kept nowhere: a bare @
create or replace function pg_temp.v0008zk_b5()
returns void
language plpgsql
as $$
declare
  v_t1    uuid := pg_temp.v0008zk_tenant('verify-0008zk-one');
  v_parts uuid := pg_temp.v0008zk_conn('verify-0008zk-one', 'base-chunks');
  v_csv   uuid := pg_temp.v0008zk_conn('verify-0008zk-one', 'base-csv');
  v_crm   uuid := pg_temp.v0008zk_conn('verify-0008zk-one', 'portal-1');
  v_n     bigint;
  v_txt   text;
  j       jsonb;
begin
  perform pg_temp.v0008zk_as('verify-0008zk-one', 'ingest');
  v_n := (select count(*) from cma.device d where d.connection_id = v_parts and d.source_deleted_at is not null);
  v_txt := pg_temp.v0008zk_code(format('select cma.ingest_load_device_chunk(%L, %L)', v_csv, pg_temp.v0008zk_chunk(1, 2, false)))
    || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_mark_devices_missing(%L, %L, null, null)', v_csv, array['rec-000001']))
    || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_load_device_chunk(%L, %L)', v_crm, pg_temp.v0008zk_chunk(1, 2, false)))
    || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_mark_devices_missing(%L, %L, null, null)', v_crm, array['rec-000001']))
    || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_load_device_chunk(%L, %L)', v_parts, '{"source_id": "rec-1"}'))
    || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_load_device_chunk(%L, %L)', v_parts, '[]'))
    || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_load_device_chunk(%L, %L)', v_parts,
                (select jsonb_agg(jsonb_build_object('source_id', 'rec-' || g)) from generate_series(1, 5001) g)))
    || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_load_device_chunk(%L, %L)', v_parts, '[{"source_id": "rec-1"}, "rec-2"]'))
    || ' ' || pg_temp.v0008zk_error(format('select cma.ingest_load_device_chunk(%L, %L)', v_parts, '[{"source_id": "rec-1", "serial_number": "SN-1"}]'))
    || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_load_device_chunk(%L, %L)', v_parts, '[{"source_row": 1, "source_id": "rec-1"}]'))
    || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_load_device_chunk(%L, %L)', v_parts, '[{"source_row": "3", "source_id": "rec-1"}]'))
    || ' ' || pg_temp.v0008zk_error(format('select cma.ingest_load_device_chunk(%L, %L)', v_parts,
                jsonb_build_array(jsonb_build_object('source_row', 4, 'source_id', 'rec-1', 'serial', repeat('s', 501)))))
    || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_load_device_chunk(%L, %L)', v_parts,
                '[{"source_row": 2, "source_id": "rec-1"}, {"source_row": 3, "source_id": "rec-1"}]'))
    || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_load_device_chunk(%L, %L)', v_parts, '[{"source_row": 2, "serial": "SN-1"}]'))
    || ' |';
  -- the slices
  v_txt := v_txt
    || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_mark_devices_missing(%L, %L, null, null)', v_parts, '{}'::text[]))
    || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_mark_devices_missing(%L, %L, null, null)', v_parts, array['rec-000001', null]))
    || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_mark_devices_missing(%L, %L, null, null)', v_parts,
                array(select 'rec-' || lpad(g::text, 6, '0') from generate_series(1, 5001) g)))
    || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_mark_devices_missing(%L, %L, %L, null)', v_parts, array['rec-000002'], 'rec@x'))
    || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_mark_devices_missing(%L, %L, %L, %L)', v_parts, array['rec-000002'], 'rec-000003', 'rec-000003'))
    || ' ' || pg_temp.v0008zk_error(format('select cma.ingest_mark_devices_missing(%L, %L, %L, %L)', v_parts, array['rec-000002', 'rec-000500'],
                                           'rec-000001', 'rec-000100'))
    || ' ' || ((select count(*) from cma.device d where d.connection_id = v_parts and d.source_deleted_at is not null) = v_n)::text;
  perform pg_temp.v0008zk_as('verify-0008zk-one', 'admin');
  v_txt := v_txt
    || ' | ' || pg_temp.v0008zk_code(format('select cma.ingest_load_device_chunk(%L, %L)', v_parts, pg_temp.v0008zk_chunk(1, 2, false)))
    || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_mark_devices_missing(%L, %L, null, null)', v_parts, array['rec-000001']));
  perform pg_temp.v0008zk_as('verify-0008zk-one', 'ingest');
  j := cma.ingest_load_device_chunk(v_parts, jsonb_build_array(jsonb_build_object(
         'source_row', 2, 'source_id', 'rec-at', 'serial', 'verify-serial@example.invalid', 'customer_ref', 'verify-customer@example.invalid',
         'components', '{"pads": {"serial": "verify-pads@example.invalid", "expires_on": "2027-01-01"}}',
         'external_refs', '{"ns_internal_id": "verify-ref@example.invalid"}')));
  perform set_config('role', 'cma_owner', true);
  v_txt := v_txt || ' | ' || pg_temp.v0008zk_counts(j)
           || ' ' || (select count(*) from cma.device d where d.tenant_id = v_t1 and (d::text like '%example%' or d.raw::text like '%example%'))
           || '/' || (select count(*) from cma.device_component c where c.tenant_id = v_t1 and c::text like '%example%')
           || '/' || (select count(*) from cma.device_import_row s where s.tenant_id = v_t1)
           || ' ' || (select coalesce(d.serial, '-') || ':' || coalesce(d.customer_ref, '-') || ':' || d.customer_ref_invalid::text
                      from cma.device d where d.tenant_id = v_t1 and d.source_id = 'rec-at');
  perform pg_temp.v0008zk_check(15, 'B5 the refusals: a person, a file-only and a CRM connection, a chunk out of its form, a slice out of its form; an address a bare @',
    v_txt = 'CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 '
            || 'CMA04: a chunk''s rows hold the staging''s columns only, not serial_number CMA04 CMA04 '
            || 'CMA04: line 4: serial is longer than the staging takes CMA04 CMA04 | '
            || 'CMA04 CMA04 CMA04 CMA04 CMA04 CMA04: a record id lies outside its slice (from rec-000001 before rec-000100): nothing is marked true | '
            || 'CMA06 CMA06 | rows=1 ins=1 upd=0 same=0 missing=0 repl=0 um=1 us=1 uk=1 cri=1 drop=3 0/0/0 -:-:true', v_txt);
exception when others then
  perform pg_temp.v0008zk_check(15, 'B5 the refusals', false, sqlstate || ': ' || sqlerrm);
end
$$;

-- B6. the run's counts take the phase times, components_closed, chunk_max_ms, slice_max_ms, chunk_size_min and
--     chunk_halvings; another key is still refused (CMA04); the setting assets_load_chunk set
--     by form on the register (CMA04 out of it), not checked on a CRM connection; view_id refused on an asset register
--     (CMA04, its settings as they were), still taken by a CRM connection
create or replace function pg_temp.v0008zk_b6()
returns void
language plpgsql
as $$
declare
  v_parts uuid := pg_temp.v0008zk_conn('verify-0008zk-one', 'base-chunks');
  v_crm   uuid := pg_temp.v0008zk_conn('verify-0008zk-one', 'portal-1');
  v_run   uuid;
  v_txt   text;
begin
  perform pg_temp.v0008zk_as('verify-0008zk-one', 'ingest');
  v_run := cma.ingest_sync_run_start(v_parts, 'assets_poll', 'devices', null, null);
  v_txt := pg_temp.v0008zk_code(format('select cma.ingest_sync_run_finish(%L, ''succeeded'', %L)', v_run,
             '{"fetched": 2, "rows": 2, "inserted": 1, "updated": 1, "unchanged": 0, "missing_now": 0, "components_closed": 1, "stage_ms": 3, "map_ms": 12, '
             || '"upsert_ms": 4, "components_ms": 5, "missing_ms": 6, "cleanup_ms": 0, "chunk_max_ms": 140, "slice_max_ms": 7, '
             || '"chunk_size_min": 500, "chunk_halvings": 1}'));
  v_txt := v_txt || ' ' || (select concat_ws('/', r.counts ->> 'map_ms', r.counts ->> 'missing_ms', r.counts ->> 'components_closed',
                                             r.counts ->> 'chunk_max_ms', r.counts ->> 'slice_max_ms', r.counts ->> 'chunk_size_min',
                                             r.counts ->> 'chunk_halvings') from cma.sync_run r where r.id = v_run)
           || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_sync_run_finish(cma.ingest_sync_run_start(%L, ''assets_poll'', ''devices'', null, null), '
                                                 || '''succeeded'', ''{"fetched": 1, "load_ms": 1}'')', v_parts));
  perform pg_temp.v0008zk_as('verify-0008zk-one', 'admin');
  v_txt := v_txt
    || ' ' || pg_temp.v0008zk_code(format('select cma.set_connection_settings(%L, %L)', v_parts, '{"table_id": "tblVerify0001", "assets_load_chunk": 1000}'))
    || ' ' || pg_temp.v0008zk_code(format('select cma.set_connection_settings(%L, %L)', v_parts, '{"assets_load_chunk": 50}'))
    || ' ' || pg_temp.v0008zk_code(format('select cma.set_connection_settings(%L, %L)', v_crm, '{"assets_load_chunk": 50}'))
    || ' ' || pg_temp.v0008zk_error(format('select cma.set_connection_settings(%L, %L)', v_parts, '{"table_id": "tblVerify0001", "view_id": "viwVerify0001"}'))
    || ' ' || pg_temp.v0008zk_code(format('select cma.set_connection_settings(%L, %L)', v_crm, '{"view_id": "viwVerify0001"}'));
  v_txt := v_txt || ' ' || (select c.settings::text from cma.integration_connection c where c.id = v_parts);
  perform pg_temp.v0008zk_check(16, 'B6 the run''s counts take the phase times, components_closed, the slowest chunk and slice and the adaptive chunks, another key refused; the setting assets_load_chunk by form; view_id refused on an asset register',
    v_txt = 'ok 12/6/1/140/7/500/1 CMA04 ok CMA04 ok CMA04: an asset register is read whole: view_id is no setting of it (a view''s filter would make the devices '
            || 'outside it look missing) ok {"table_id": "tblVerify0001", "assets_load_chunk": 1000}', v_txt);
exception when others then
  perform pg_temp.v0008zk_check(16, 'B6 the run''s counts and the settings', false, sqlstate || ': ' || sqlerrm);
end
$$;

-- B7. the mapped fields' types: the Ingest user records the type it first read for each mapped property (in lower
--     case; a property the connection does not map left alone); a later, different type is kept out (the stored one
--     stays, for the adapter to refuse); a field mapped again with another property loses its type and takes the next
--     one read; a field removed and set again with the same id (accepting a changed type) too; the refusals (a file-only
--     connection among them)
create or replace function pg_temp.v0008zk_b7()
returns void
language plpgsql
as $$
declare
  v_parts uuid := pg_temp.v0008zk_conn('verify-0008zk-one', 'base-chunks');
  v_crm   uuid := pg_temp.v0008zk_conn('verify-0008zk-one', 'portal-1');
  v_csv   uuid := pg_temp.v0008zk_conn('verify-0008zk-one', 'base-csv');
  v_txt   text;
begin
  perform pg_temp.v0008zk_as('verify-0008zk-one', 'admin');
  perform cma.set_connection_field(v_parts, 'device', 'serial', '', 'fldVerify0000001');
  perform cma.set_connection_field(v_parts, 'device_component', 'expires_on', 'pads', 'fldVerify0000002');
  perform pg_temp.v0008zk_as('verify-0008zk-one', 'ingest');
  v_txt := cma.ingest_record_field_types(v_parts, '[{"property": "fldVerify0000001", "type": "singleLineText"},
                                                   {"property": "fldVerify0000002", "type": "date"},
                                                   {"property": "fldVerify0000009", "type": "email"}]')::text;
  v_txt := v_txt || ' ' || cma.ingest_record_field_types(v_parts, '[{"property": "fldVerify0000002", "type": "singleLineText"}]')::text;
  v_txt := v_txt || ' ' || (select string_agg(f.source_property || ':' || coalesce(f.source_type, '-') || ':' || (f.checked_at is not null)::text, ' '
                                        order by f.source_property, f.entity, f.field, f.ref_system)
                      from cma.connection_field f where f.connection_id = v_parts);
  perform pg_temp.v0008zk_as('verify-0008zk-one', 'admin');
  perform cma.set_connection_field(v_parts, 'device', 'serial', '', 'fldVerify0000003');
  perform pg_temp.v0008zk_as('verify-0008zk-one', 'ingest');
  -- one statement each: a statement's sub-select reads as of its start, so it would not see the function's update
  v_txt := v_txt || ' | ' || (select string_agg(f.source_property || ':' || coalesce(f.source_type, '-'), ' '
                                              order by f.source_property, f.entity, f.field, f.ref_system)
                              from cma.connection_field f where f.connection_id = v_parts);
  v_txt := v_txt || ' ' || cma.ingest_record_field_types(v_parts, '[{"property": "fldVerify0000003", "type": "number"}]')::text;
  v_txt := v_txt || ' ' || (select f.source_type from cma.connection_field f where f.connection_id = v_parts and f.source_property = 'fldVerify0000003');
  -- a changed type accepted: the field's mapping removed and set again with the same id in one transaction; its type
  -- goes with the removed row, and the next read records the new one
  perform pg_temp.v0008zk_as('verify-0008zk-one', 'admin');
  perform cma.set_connection_field(v_parts, 'device_component', 'expires_on', 'pads', '');
  perform cma.set_connection_field(v_parts, 'device_component', 'expires_on', 'pads', 'fldVerify0000002');
  perform pg_temp.v0008zk_as('verify-0008zk-one', 'ingest');
  v_txt := v_txt || ' ' || coalesce((select f.source_type from cma.connection_field f where f.connection_id = v_parts and f.source_property = 'fldVerify0000002'), '-');
  v_txt := v_txt || ' ' || cma.ingest_record_field_types(v_parts, '[{"property": "fldVerify0000002", "type": "singleLineText"}]')::text;
  v_txt := v_txt || ' ' || (select f.source_type from cma.connection_field f where f.connection_id = v_parts and f.source_property = 'fldVerify0000002')
           || ' | ' || pg_temp.v0008zk_code(format('select cma.ingest_record_field_types(%L, %L)', v_parts, '{"property": "fldVerify0000001"}'))
           || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_record_field_types(%L, %L)', v_parts, '[]'))
           || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_record_field_types(%L, %L)', v_parts, '[{"property": "fldVerify0000001", "type": "single line"}]'))
           || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_record_field_types(%L, %L)', v_parts, '[{"property": "", "type": "date"}]'))
           || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_record_field_types(%L, %L)', v_crm, '[{"property": "fldVerify0000001", "type": "date"}]'))
           || ' ' || (select case when e like 'CMA04: connection % has no token secret name%' then 'CMA04' else e end
                      from pg_temp.v0008zk_error(format('select cma.ingest_record_field_types(%L, %L)', v_csv, '[{"property": "fldVerify0000001", "type": "date"}]')) e);
  perform pg_temp.v0008zk_as('verify-0008zk-one', 'admin');
  v_txt := v_txt || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_record_field_types(%L, %L)', v_parts, '[{"property": "fldVerify0000001", "type": "date"}]'));
  perform pg_temp.v0008zk_as('verify-0008zk-two', 'ingest');
  v_txt := v_txt || ' ' || pg_temp.v0008zk_code(format('select cma.ingest_record_field_types(%L, %L)', v_parts, '[{"property": "fldVerify0000001", "type": "date"}]'));
  perform pg_temp.v0008zk_check(17, 'B7 the mapped fields'' types: the first read recorded, a later one kept out, mapped again (another id, or the same id removed and set) read afresh; the refusals, a file-only connection''s by its message',
    v_txt = '2 0 fldVerify0000001:singlelinetext:true fldVerify0000002:date:true | fldVerify0000002:date fldVerify0000003:- 1 number '
            || '- 1 singlelinetext | CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA06 CMA02', v_txt);
exception when others then
  perform pg_temp.v0008zk_check(17, 'B7 the mapped fields'' types', false, sqlstate || ': ' || sqlerrm);
end
$$;

-- B8. a kind the register emptied (Decision log, 28 October 2026): three records of tenant one's chunk connection
--     loaded again in one chunk: rec-000101 with its pads staged empty ({}), rec-000102 with no components staged (the
--     source maps no kind), rec-000104 with a pads serial that is no id and no expiry and its battery staged empty.
--     The pads of rec-000101 and the battery of rec-000104 closed (replaced_at, no new row, counted
--     components_closed), rec-000101's pads due unknown in the forecast and among the data quality's
--     component_due_unknown, its battery as it was; rec-000102 and rec-000104's pads as they were. The same chunk
--     again changes nothing. Then the register holds both again: rec-000101's pads with another serial, inserted (a
--     replacement: the closed one stays closed); rec-000104's battery with its own serial, reopened (the same row
--     current again, so its first sighting and its anchor are kept)
create or replace function pg_temp.v0008zk_b8_rows(p_variant text)
returns jsonb
language sql
as $$
  select jsonb_agg(to_jsonb(x) || jsonb_build_object('components',
           case x.source_id
             when 'rec-000101' then jsonb_set(x.components::jsonb, '{pads}',
                                              case when p_variant = 'refill' then '{"serial": "P-101-r", "expires_on": "2028-06-30"}'::jsonb
                                                   else '{}'::jsonb end)::text
             when 'rec-000102' then null
             else jsonb_set(jsonb_set(x.components::jsonb, '{pads}', '{"serial": "not an id!"}'::jsonb), '{battery}',
                            case when p_variant = 'refill' then x.components::jsonb -> 'battery' else '{}'::jsonb end)::text end)
         order by x.source_row)
  from pg_temp.v0008zk_register(101, 104, true) x
  where x.source_id <> 'rec-000103'
$$;

-- The three records' components and rec-000101's due items, as a step's answer: the components by record, kind, the
-- closed ones before the current one (replaced_at nulls last), then first seen and serial; the items by kind
create or replace function pg_temp.v0008zk_b8_state(p_step text)
returns void
language plpgsql
as $$
declare
  v_t    uuid := pg_temp.v0008zk_tenant('verify-0008zk-one');
  v_conn uuid := pg_temp.v0008zk_conn('verify-0008zk-one', 'base-chunks');
begin
  perform pg_temp.v0008zk_log(p_step, null, null, jsonb_build_object(
    'components', (select string_agg(concat_ws(':', d.source_id, c.component_key, coalesce(c.serial, '-'), coalesce(c.expires_on::text, '-'),
                                               case when c.replaced_at is null then 'current' else 'closed' end), ' '
                                     order by d.source_id, c.component_key, c.replaced_at nulls last, c.first_seen_at, c.serial)
                   from cma.device d join cma.device_component c on c.tenant_id = d.tenant_id and c.device_id = d.id
                   where d.tenant_id = v_t and d.connection_id = v_conn and d.source_id in ('rec-000101', 'rec-000102', 'rec-000104')),
    'items', (select string_agg(i.component_key || ':' || i.basis || ':' || coalesce(i.due_on::text, '-'), ' ' order by i.component_key)
              from cma.maintenance_items_of(v_t, '2026-10-28') i where i.connection_id = v_conn and i.source_id = 'rec-000101'),
    'unknown', (select count(*) from cma.data_quality_of(v_t) q
                where q.check_key = 'component_due_unknown' and q.connection_id = v_conn and q.object_id = 'rec-000101' and q.value = 'pads')), null);
exception when others then
  perform pg_temp.v0008zk_log(p_step, null, null, null, sqlstate || ': ' || sqlerrm);
end
$$;

create or replace function pg_temp.v0008zk_b8()
returns void
language plpgsql
as $$
declare
  v_txt text;
  v_err text := pg_temp.v0008zk_failed(array['b8-close', 'b8-closed', 'b8-again', 'b8-refill', 'b8-refilled']);
begin
  v_txt := concat_ws(' | ',
    (select concat_ws(' ', 'closed=' || (s.answer ->> 'components_closed'), 'repl=' || (s.answer ->> 'components_replaced'),
                      'ins=' || (s.answer ->> 'inserted'), 'drop=' || (s.answer ->> 'refs_dropped'))
     from pg_temp.v0008zk_step s where s.step = 'b8-close'),
    (select concat_ws(' ', s.answer ->> 'components', s.answer ->> 'items', 'unknown=' || (s.answer ->> 'unknown'))
     from pg_temp.v0008zk_step s where s.step = 'b8-closed'),
    (select concat_ws(' ', 'closed=' || (s.answer ->> 'components_closed'), 'upd=' || (s.answer ->> 'updated'), 'same=' || (s.answer ->> 'unchanged'))
     from pg_temp.v0008zk_step s where s.step = 'b8-again'),
    (select concat_ws(' ', 'closed=' || (s.answer ->> 'components_closed'), 'repl=' || (s.answer ->> 'components_replaced'))
     from pg_temp.v0008zk_step s where s.step = 'b8-refill'),
    (select concat_ws(' ', s.answer ->> 'components', s.answer ->> 'items', 'unknown=' || (s.answer ->> 'unknown'))
     from pg_temp.v0008zk_step s where s.step = 'b8-refilled'));
  perform pg_temp.v0008zk_check(18, 'B8 a kind the register emptied closes the component (no new row, its item due unknown); a kind not staged, or a dropped serial without an expiry, left as it is; a rerun changes nothing; held again: another serial inserted, the same serial reopened',
    v_err is null and v_txt =
      'closed=2 repl=0 ins=0 drop=1'
      || ' | rec-000101:battery:B-101:2027-01-20:current rec-000101:pads:P-101:2026-12-10:closed rec-000102:battery:B-102:2027-01-20:current '
      || 'rec-000102:pads:P-102:2026-12-10:current rec-000104:battery:B-104:2027-01-20:closed rec-000104:pads:P-104:2026-12-10:current '
      || 'battery:recorded:2027-01-20 pads:unknown:- unknown=1'
      || ' | closed=0 upd=0 same=3'
      || ' | closed=0 repl=0'
      || ' | rec-000101:battery:B-101:2027-01-20:current rec-000101:pads:P-101:2026-12-10:closed rec-000101:pads:P-101-r:2028-06-30:current '
      || 'rec-000102:battery:B-102:2027-01-20:current rec-000102:pads:P-102:2026-12-10:current rec-000104:battery:B-104:2027-01-20:current '
      || 'rec-000104:pads:P-104:2026-12-10:current battery:recorded:2027-01-20 pads:recorded:2028-06-30 unknown=0',
    coalesce(v_err, v_txt));
exception when others then
  perform pg_temp.v0008zk_check(18, 'B8 a kind the register emptied', false, sqlstate || ': ' || sqlerrm);
end
$$;

begin; select pg_temp.v0008zk_b_setup(); commit;
-- B1: the register into both connections, a chunk at a time
begin; select pg_temp.v0008zk_b_load('b1-register', 'base-one', 0, false); commit;
begin; select pg_temp.v0008zk_b_load('b1-register', 'base-chunks', 0, false); commit;
begin; select pg_temp.v0008zk_b_load('b1-register', 'base-one', 1, false); commit;
begin; select pg_temp.v0008zk_b_load('b1-register', 'base-chunks', 1, false); commit;
begin; select pg_temp.v0008zk_b_load('b1-register', 'base-one', 2, false); commit;
begin; select pg_temp.v0008zk_b_load('b1-register', 'base-chunks', 2, false); commit;
begin; select pg_temp.v0008zk_b_load('b1-register', 'base-one', 3, false); commit;
begin; select pg_temp.v0008zk_b_load('b1-register', 'base-chunks', 3, false); commit;
begin; select pg_temp.v0008zk_b_load('b1-register', 'base-one', 4, false); commit;
begin; select pg_temp.v0008zk_b_load('b1-register', 'base-chunks', 4, false); commit;
begin; select pg_temp.v0008zk_b_load('b1-register', 'base-one', 5, false); commit;
begin; select pg_temp.v0008zk_b_load('b1-register', 'base-chunks', 5, false); commit;
begin; select pg_temp.v0008zk_b_load('b1-register', 'base-one', 6, false); commit;
begin; select pg_temp.v0008zk_b_load('b1-register', 'base-chunks', 6, false); commit;
begin; select pg_temp.v0008zk_b_load('b1-register', 'base-one', 7, false); commit;
begin; select pg_temp.v0008zk_b_load('b1-register', 'base-chunks', 7, false); commit;
begin; select pg_temp.v0008zk_b_load('b1-register', 'base-one', 8, false); commit;
begin; select pg_temp.v0008zk_b_load('b1-register', 'base-chunks', 8, false); commit;
begin; select pg_temp.v0008zk_b_load('b1-register', 'base-one', 9, false); commit;
begin; select pg_temp.v0008zk_b_load('b1-register', 'base-chunks', 9, false); commit;
begin; select pg_temp.v0008zk_b_fp('b1-register-fp'); commit;
-- B1: the night, in one call into the first connection, and in chunks and slices into the second
begin; select pg_temp.v0008zk_b1_one_call(); commit;
begin; select pg_temp.v0008zk_b_load('b1-night', 'base-chunks', 0, true); commit;
begin; select pg_temp.v0008zk_b_load('b1-night', 'base-chunks', 1, true); commit;
begin; select pg_temp.v0008zk_b_load('b1-night', 'base-chunks', 2, true); commit;
begin; select pg_temp.v0008zk_b_load('b1-night', 'base-chunks', 3, true); commit;
begin; select pg_temp.v0008zk_b_load('b1-night', 'base-chunks', 4, true); commit;
begin; select pg_temp.v0008zk_b_load('b1-night', 'base-chunks', 5, true); commit;
begin; select pg_temp.v0008zk_b_load('b1-night', 'base-chunks', 6, true); commit;
begin; select pg_temp.v0008zk_b_load('b1-night', 'base-chunks', 7, true); commit;
begin; select pg_temp.v0008zk_b_load('b1-night', 'base-chunks', 8, true); commit;
begin; select pg_temp.v0008zk_b_load('b1-night', 'base-chunks', 9, true); commit;
begin; select pg_temp.v0008zk_b_final('b1-final', 0, 11000); commit;
begin; select pg_temp.v0008zk_b_final('b1-final', 1, 11000); commit;
begin; select pg_temp.v0008zk_b_final('b1-final', 2, 11000); commit;
begin; select pg_temp.v0008zk_b_final('b1-final', 3, 11000); commit;
begin; select pg_temp.v0008zk_b_final('b1-final', 4, 11000); commit;
begin; select pg_temp.v0008zk_b_final('b1-final', 5, 11000); commit;
begin; select pg_temp.v0008zk_b_final('b1-final', 6, 11000); commit;
begin; select pg_temp.v0008zk_b_final('b1-final', 7, 11000); commit;
begin; select pg_temp.v0008zk_b_final('b1-final', 8, 11000); commit;
begin; select pg_temp.v0008zk_b_final('b1-final', 9, 11000); commit;
begin; select pg_temp.v0008zk_b1(); commit;
-- B2: the same run again
begin; select pg_temp.v0008zk_b_fp('b2-fp'); commit;
begin; select pg_temp.v0008zk_b_load('b2', 'base-chunks', 0, true); commit;
begin; select pg_temp.v0008zk_b_load('b2', 'base-chunks', 1, true); commit;
begin; select pg_temp.v0008zk_b_load('b2', 'base-chunks', 2, true); commit;
begin; select pg_temp.v0008zk_b_load('b2', 'base-chunks', 3, true); commit;
begin; select pg_temp.v0008zk_b_load('b2', 'base-chunks', 4, true); commit;
begin; select pg_temp.v0008zk_b_load('b2', 'base-chunks', 5, true); commit;
begin; select pg_temp.v0008zk_b_load('b2', 'base-chunks', 6, true); commit;
begin; select pg_temp.v0008zk_b_load('b2', 'base-chunks', 7, true); commit;
begin; select pg_temp.v0008zk_b_load('b2', 'base-chunks', 8, true); commit;
begin; select pg_temp.v0008zk_b_load('b2', 'base-chunks', 9, true); commit;
begin; select pg_temp.v0008zk_b_final('b2-final', 0, 11000); commit;
begin; select pg_temp.v0008zk_b_final('b2-final', 1, 11000); commit;
begin; select pg_temp.v0008zk_b_final('b2-final', 2, 11000); commit;
begin; select pg_temp.v0008zk_b_final('b2-final', 3, 11000); commit;
begin; select pg_temp.v0008zk_b_final('b2-final', 4, 11000); commit;
begin; select pg_temp.v0008zk_b_final('b2-final', 5, 11000); commit;
begin; select pg_temp.v0008zk_b_final('b2-final', 6, 11000); commit;
begin; select pg_temp.v0008zk_b_final('b2-final', 7, 11000); commit;
begin; select pg_temp.v0008zk_b_final('b2-final', 8, 11000); commit;
begin; select pg_temp.v0008zk_b_final('b2-final', 9, 11000); commit;
begin; select pg_temp.v0008zk_b2(); commit;
-- B3: a run that reads records 1 to 8,000, loads four chunks and fails; then its rerun
begin; select pg_temp.v0008zk_b_fp('b3-fp'); commit;
begin; select pg_temp.v0008zk_b_load('b3-failed', 'base-chunks', 0, true); commit;
begin; select pg_temp.v0008zk_b_load('b3-failed', 'base-chunks', 1, true); commit;
begin; select pg_temp.v0008zk_b_load('b3-failed', 'base-chunks', 2, true); commit;
begin; select pg_temp.v0008zk_b_load('b3-failed', 'base-chunks', 3, true); commit;
begin; select pg_temp.v0008zk_b_fp('b3-failed-fp'); commit;
begin; select pg_temp.v0008zk_b_load('b3-rerun', 'base-chunks', 0, true); commit;
begin; select pg_temp.v0008zk_b_load('b3-rerun', 'base-chunks', 1, true); commit;
begin; select pg_temp.v0008zk_b_load('b3-rerun', 'base-chunks', 2, true); commit;
begin; select pg_temp.v0008zk_b_load('b3-rerun', 'base-chunks', 3, true); commit;
begin; select pg_temp.v0008zk_b_load('b3-rerun', 'base-chunks', 4, true); commit;
begin; select pg_temp.v0008zk_b_load('b3-rerun', 'base-chunks', 5, true); commit;
begin; select pg_temp.v0008zk_b_load('b3-rerun', 'base-chunks', 6, true); commit;
begin; select pg_temp.v0008zk_b_load('b3-rerun', 'base-chunks', 7, true); commit;
begin; select pg_temp.v0008zk_b_final('b3-final', 0, 8000); commit;
begin; select pg_temp.v0008zk_b_final('b3-final', 1, 8000); commit;
begin; select pg_temp.v0008zk_b_final('b3-final', 2, 8000); commit;
begin; select pg_temp.v0008zk_b_final('b3-final', 3, 8000); commit;
begin; select pg_temp.v0008zk_b_final('b3-final', 4, 8000); commit;
begin; select pg_temp.v0008zk_b_final('b3-final', 5, 8000); commit;
begin; select pg_temp.v0008zk_b_final('b3-final', 6, 8000); commit;
begin; select pg_temp.v0008zk_b_final('b3-final', 7, 8000); commit;
begin; select pg_temp.v0008zk_b3(); commit;
begin; select pg_temp.v0008zk_b4(); commit;
begin; select pg_temp.v0008zk_b5(); commit;
begin; select pg_temp.v0008zk_b6(); commit;
begin; select pg_temp.v0008zk_b7(); commit;
-- B8: a kind the register emptied, each load its own transaction
begin; select pg_temp.v0008zk_load('b8-close', null, 'verify-0008zk-one', 'base-chunks', pg_temp.v0008zk_b8_rows('close')); commit;
begin; select pg_temp.v0008zk_analyze(); commit;
begin; select pg_temp.v0008zk_b8_state('b8-closed'); commit;
begin; select pg_temp.v0008zk_load('b8-again', null, 'verify-0008zk-one', 'base-chunks', pg_temp.v0008zk_b8_rows('close')); commit;
begin; select pg_temp.v0008zk_load('b8-refill', null, 'verify-0008zk-one', 'base-chunks', pg_temp.v0008zk_b8_rows('refill')); commit;
begin; select pg_temp.v0008zk_b8_state('b8-refilled'); commit;
begin; select pg_temp.v0008zk_b8(); commit;
begin; select pg_temp.v0008zk_clean('end', 'verify-0008zk-one'); commit;
begin; select pg_temp.v0008zk_clean('end', 'verify-0008zk-two'); commit;

-- -----------------------------------------------------------------------------------------------
-- C. Speed at the register's horizon: 50,000 devices
-- -----------------------------------------------------------------------------------------------
-- The volume tenant: its catalogs (two models, two markets, a field and a stock status), rules for HS1 (pads 24 months,
-- battery 54, each 60 days ahead) and a bundling window of 60 days
create or replace function pg_temp.v0008zk_c_setup()
returns void
language plpgsql
as $$
declare
  v_t uuid;
begin
  v_t := pg_temp.v0008zk_new_tenant('verify-0008zk-volume');
  insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
  values (v_t, 'verifyregister', 'Verify register volume', 'base-zk-v', 'assets', 'verify-register-token-zk-v');
  perform pg_temp.v0008zk_as('verify-0008zk-volume', 'admin');
  perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR', null, null, 10);
  perform cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', null, null, 20);
  perform cma.set_market_alias('netherlands', 'NL');
  perform cma.set_market_alias('united kingdom', 'GB');
  insert into cma.device_model (key, name, aliases) values ('hs1', 'HS1', array['hs1']), ('frx', 'FRx', array['frx']);
  insert into cma.device_component_kind (key, name, sort_order) values ('pads', 'Pads', 10), ('battery', 'Battery', 20);
  insert into cma.maintenance_rule (model_key, component_key, interval_months, lead_days) values ('hs1', 'pads', 24, 60), ('hs1', 'battery', 54, 60);
  insert into cma.device_status (key, name, is_in_field, is_in_stock, is_tracked, aliases, sort_order) values
    ('active_customer', 'Active/Customer', true, false, true, array['active/customer'], 10),
    ('in_storage', 'In Storage', false, true, true, array['in storage'], 20);
  perform cma.set_tenant_setting('assets.bundle_window_days', '60');
  perform set_config('role', 'cma_owner', true);
  delete from pg_temp.v0008zk_c4_state;
  insert into pg_temp.v0008zk_c4_state values (1, 1000, 1000, 0, 0);
  perform pg_temp.v0008zk_log('c-setup', null, null, jsonb_build_object('tenant', v_t), null);
exception when others then
  perform pg_temp.v0008zk_log('c-setup', null, null, null, sqlstate || ': ' || sqlerrm);
end
$$;

-- C4's next call under the adapter's rule (ingest/src/adapters/airtable/index.mjs, loadInChunks): the next records, as
-- many as the chunk size in force (1,000 to start, the setting's default), new, into the filling connection; a call
-- slower than verify.slow_ms (a third of the timeout) halves the next chunk, at least 100. Each call its own step and
-- transaction; once the 50,000 are loaded, or a call failed, the rest of C4's steps do nothing
create or replace function pg_temp.v0008zk_c4_next()
returns void
language plpgsql
as $$
declare
  st   record;
  v_to integer;
  v_ms numeric;
  v_ok boolean;
begin
  select * into st from pg_temp.v0008zk_c4_state;
  if not found or st.next_from > 50000 then
    return;
  end if;
  v_to := least(st.next_from + st.size - 1, 50000);
  perform pg_temp.v0008zk_load('c4', st.calls, 'verify-0008zk-volume', 'base-zk-v', pg_temp.v0008zk_volume(st.next_from, v_to));
  select s.ms, s.error is null into v_ms, v_ok from pg_temp.v0008zk_step s where s.step = 'c4' and s.n = st.calls;
  update pg_temp.v0008zk_step s set answer = coalesce(s.answer, '{}'::jsonb) || jsonb_build_object('size', st.size, 'rows_sent', v_to - st.next_from + 1)
  where s.step = 'c4' and s.n = st.calls;
  update pg_temp.v0008zk_c4_state c
     set next_from = case when v_ok then v_to + 1 else 50001 end,
         calls = c.calls + 1,
         size = case when v_ms > current_setting('verify.slow_ms')::numeric then greatest(100, c.size / 2) else c.size end,
         halvings = c.halvings + (v_ms > current_setting('verify.slow_ms')::numeric and c.size > 100)::integer,
         min_size = least(c.min_size, case when v_ms > current_setting('verify.slow_ms')::numeric then greatest(100, c.size / 2) else c.size end);
end
$$;
-- C2's slice k (from 0) of the run's 49,500 record ids
create or replace function pg_temp.v0008zk_c2(p_k integer)
returns void
language sql
as $$
  select pg_temp.v0008zk_mark('c2', p_k, 'verify-0008zk-volume', 'base-zk-v', pg_temp.v0008zk_volume_ids(1, 49500))
$$;

-- C4. a first load: 50,000 new records into the empty connection in chunks under the adapter's rule (from 1,000; the next
--     half the size after a call slower than a third of the timeout, at least 100), each call its own transaction,
--     without reading the tables' statistics in between: all 50,000 loaded, each call under verify.max_ms; the detail
--     the calls, the sizes and halvings, the first, the last and the slowest call, the first five and the last five on
--     average, the phases of the first and the last
create or replace function pg_temp.v0008zk_c4_check()
returns void
language plpgsql
as $$
declare
  v_max  numeric := current_setting('verify.max_ms')::numeric;
  v_err  text := pg_temp.v0008zk_failed(array['c-setup', 'c4']);
  v_n    bigint := (select count(*) from cma.device d where d.connection_id = pg_temp.v0008zk_conn('verify-0008zk-volume', 'base-zk-v'));
  st     record;
  v_last integer := (select max(s.n) from pg_temp.v0008zk_step s where s.step = 'c4');
  v_txt  text;
  f jsonb := (select s.answer from pg_temp.v0008zk_step s where s.step = 'c4' and s.n = 0);
  l jsonb := (select s.answer from pg_temp.v0008zk_step s where s.step = 'c4' and s.n = v_last);
begin
  select * into st from pg_temp.v0008zk_c4_state;
  v_txt := format('%s calls, sizes 1000 to %s, %s halvings (slower than %s ms); first %s ms, last %s, slowest %s (budget %s); '
                  || 'first five %s on average, last five %s; phases first: map %s, upsert %s, components %s; last: map %s, upsert %s, '
                  || 'components %s; %s devices',
                  (select count(*) from pg_temp.v0008zk_step s where s.step = 'c4' and s.error is null), st.min_size, st.halvings,
                  current_setting('verify.slow_ms'),
                  (select s.ms from pg_temp.v0008zk_step s where s.step = 'c4' and s.n = 0),
                  (select s.ms from pg_temp.v0008zk_step s where s.step = 'c4' and s.n = v_last),
                  (select max(s.ms) from pg_temp.v0008zk_step s where s.step = 'c4'), v_max,
                  (select round(avg(s.ms)) from pg_temp.v0008zk_step s where s.step = 'c4' and s.n < 5),
                  (select round(avg(s.ms)) from pg_temp.v0008zk_step s where s.step = 'c4' and s.n > v_last - 5),
                  f ->> 'map_ms', f ->> 'upsert_ms', f ->> 'components_ms', l ->> 'map_ms', l ->> 'upsert_ms', l ->> 'components_ms', v_n);
  perform pg_temp.v0008zk_check(54, 'C4 a first load of 50,000 new records into an empty connection in chunks under the adapter''s rule (from 1,000, halved after a call slower than a third of the timeout, at least 100), each call its own transaction, no statistics read: all loaded, each call under verify.max_ms',
    v_err is null and v_n = 50000 and st.next_from > 50000
    and not exists (select 1 from pg_temp.v0008zk_step s where s.step = 'c4' and (s.ms is null or s.ms >= v_max)),
    coalesce(v_err || '; ', '') || case when st.next_from <= 50000 then format('not finished: %s of 50,000 records in %s calls; ', st.next_from - 1, st.calls) else '' end || v_txt);
exception when others then
  perform pg_temp.v0008zk_check(54, 'C4 a first load of 50,000 new records', false, sqlstate || ': ' || sqlerrm);
end
$$;


-- C1. one chunk of 1,000 unchanged rows (records 24,001 to 25,000) at 50,000 devices, its phases in the detail
create or replace function pg_temp.v0008zk_c1()
returns void
language plpgsql
as $$
declare
  v_max numeric := current_setting('verify.max_ms')::numeric;
  j     jsonb;
  v_ms  numeric;
  v_err text;
begin
  perform pg_temp.v0008zk_load('c1', null, 'verify-0008zk-volume', 'base-zk-v', pg_temp.v0008zk_volume(24001, 25000));
  select s.answer, s.ms, s.error into j, v_ms, v_err from pg_temp.v0008zk_step s where s.step = 'c1';
  perform pg_temp.v0008zk_check(51, 'C1 one chunk of 1,000 unchanged rows at 50,000 devices as the Ingest user, under verify.max_ms',
    v_err is null and v_ms < v_max and pg_temp.v0008zk_counts(j) = 'rows=1000 ins=0 upd=0 same=1000 missing=0 repl=0 um=0 us=0 uk=0 cri=0 drop=0',
    coalesce(v_err, format('%s ms (budget %s), stage %s, map %s, upsert %s, components %s; %s', v_ms, v_max, j ->> 'stage_ms', j ->> 'map_ms',
                           j ->> 'upsert_ms', j ->> 'components_ms', pg_temp.v0008zk_counts(j))));
end
$$;

-- C2. the final step over the run's 49,500 record ids of 50,000 devices in 50 slices of at most 1,000, each its own
--     transaction: each slice under verify.max_ms, the other 500 marked
create or replace function pg_temp.v0008zk_c2_check()
returns void
language plpgsql
as $$
declare
  v_max numeric := current_setting('verify.max_ms')::numeric;
  v_err text := pg_temp.v0008zk_failed(array['c2']);
  v_txt text;
begin
  v_txt := format('%s slices, %s ids; slowest %s ms (budget %s), all %s ms; missing_now=%s',
                  (select count(*) from pg_temp.v0008zk_step s where s.step = 'c2' and s.error is null),
                  pg_temp.v0008zk_sum(array['c2']) ->> 'ids', (select max(s.ms) from pg_temp.v0008zk_step s where s.step = 'c2'), v_max,
                  (select sum(s.ms) from pg_temp.v0008zk_step s where s.step = 'c2'), pg_temp.v0008zk_sum(array['c2']) ->> 'missing_now');
  perform pg_temp.v0008zk_check(52, 'C2 the final step over 49,500 record ids of 50,000 devices in 50 slices as the Ingest user: each slice under verify.max_ms',
    v_err is null and (select count(*) from pg_temp.v0008zk_step s where s.step = 'c2' and s.ms < v_max) = 50
    and pg_temp.v0008zk_sum(array['c2']) ->> 'missing_now' = '500' and pg_temp.v0008zk_sum(array['c2']) ->> 'ids' = '49500',
    coalesce(v_err || '; ', '') || v_txt);
exception when others then
  perform pg_temp.v0008zk_check(52, 'C2 the final step in slices', false, sqlstate || ': ' || sqlerrm);
end
$$;

-- C5. the Maintenance page of 24 months (from October 2026, as of 28 October 2026) and the device list of all buckets
--     (exchanges, 500 rows) at 50,000 devices, as the application, best of three each, its own transaction each
create or replace function pg_temp.v0008zk_c5(p_what text)
returns void
language plpgsql
as $$
declare
  v_t  uuid := pg_temp.v0008zk_tenant('verify-0008zk-volume');
  v_ms numeric;
  j    jsonb;
begin
  perform pg_temp.v0008zk_as('verify-0008zk-volume', 'analytics');
  if p_what = 'page' then
    v_ms := pg_temp.v0008zk_best_ms(format('select cma.maintenance_page_of(%L, %L, 24, null, null, null, %L)', v_t, '2026-10-01', '2026-10-28'));
    j := cma.maintenance_page_of(v_t, '2026-10-01', 24, null, null, null, '2026-10-28');
    j := jsonb_build_object('devices', j -> 'devices', 'cells', jsonb_array_length(j -> 'cells'), 'unknown_items', j -> 'unknown_items');
  else
    v_ms := pg_temp.v0008zk_best_ms(format('select * from cma.maintenance_rows_of(%L, %L, 24, ''all'', null, null, null, ''exchanges'', 500, %L)',
                                           v_t, '2026-10-01', '2026-10-28'));
    j := (select jsonb_build_object('rows', count(*), 'total_rows', max(r.total_rows))
          from cma.maintenance_rows_of(v_t, '2026-10-01', 24, 'all', null, null, null, 'exchanges', 500, '2026-10-28') r);
  end if;
  perform pg_temp.v0008zk_log('c5-' || p_what, null, v_ms, j, null);
exception when others then
  perform pg_temp.v0008zk_log('c5-' || p_what, null, null, null, sqlstate || ': ' || sqlerrm);
end
$$;
create or replace function pg_temp.v0008zk_c5_check()
returns void
language plpgsql
as $$
declare
  v_max numeric := current_setting('verify.max_report_ms')::numeric;
  v_err text := pg_temp.v0008zk_failed(array['c5-page', 'c5-list']);
  p     record;
  l     record;
begin
  select s.ms, s.answer into p from pg_temp.v0008zk_step s where s.step = 'c5-page';
  select s.ms, s.answer into l from pg_temp.v0008zk_step s where s.step = 'c5-list';
  perform pg_temp.v0008zk_check(55, 'C5 the Maintenance page of 24 months and the device list of all buckets over 50,000 devices, as the application, under verify.max_report_ms',
    v_err is null and p.ms < v_max and l.ms < v_max and (p.answer ->> 'devices')::integer = 49500 and (l.answer ->> 'rows')::integer = 500,
    coalesce(v_err, format('page %s ms, list %s ms (budget %s, best of three each); the page: %s devices, %s cells; the list: %s of %s rows',
                           p.ms, l.ms, v_max, p.answer ->> 'devices', p.answer ->> 'cells', l.answer ->> 'rows', l.answer ->> 'total_rows')));
end
$$;

begin; select pg_temp.v0008zk_c_setup(); commit;
-- C4: up to 500 calls under the adapter's rule (enough for 50,000 records in chunks of 100, the floor); the calls after
-- the last do nothing
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_next(); commit;
begin; select pg_temp.v0008zk_c4_check(); commit;
begin; select pg_temp.v0008zk_analyze(); commit;
begin; select pg_temp.v0008zk_c1(); commit;
begin; select pg_temp.v0008zk_c2(0); commit;
begin; select pg_temp.v0008zk_c2(1); commit;
begin; select pg_temp.v0008zk_c2(2); commit;
begin; select pg_temp.v0008zk_c2(3); commit;
begin; select pg_temp.v0008zk_c2(4); commit;
begin; select pg_temp.v0008zk_c2(5); commit;
begin; select pg_temp.v0008zk_c2(6); commit;
begin; select pg_temp.v0008zk_c2(7); commit;
begin; select pg_temp.v0008zk_c2(8); commit;
begin; select pg_temp.v0008zk_c2(9); commit;
begin; select pg_temp.v0008zk_c2(10); commit;
begin; select pg_temp.v0008zk_c2(11); commit;
begin; select pg_temp.v0008zk_c2(12); commit;
begin; select pg_temp.v0008zk_c2(13); commit;
begin; select pg_temp.v0008zk_c2(14); commit;
begin; select pg_temp.v0008zk_c2(15); commit;
begin; select pg_temp.v0008zk_c2(16); commit;
begin; select pg_temp.v0008zk_c2(17); commit;
begin; select pg_temp.v0008zk_c2(18); commit;
begin; select pg_temp.v0008zk_c2(19); commit;
begin; select pg_temp.v0008zk_c2(20); commit;
begin; select pg_temp.v0008zk_c2(21); commit;
begin; select pg_temp.v0008zk_c2(22); commit;
begin; select pg_temp.v0008zk_c2(23); commit;
begin; select pg_temp.v0008zk_c2(24); commit;
begin; select pg_temp.v0008zk_c2(25); commit;
begin; select pg_temp.v0008zk_c2(26); commit;
begin; select pg_temp.v0008zk_c2(27); commit;
begin; select pg_temp.v0008zk_c2(28); commit;
begin; select pg_temp.v0008zk_c2(29); commit;
begin; select pg_temp.v0008zk_c2(30); commit;
begin; select pg_temp.v0008zk_c2(31); commit;
begin; select pg_temp.v0008zk_c2(32); commit;
begin; select pg_temp.v0008zk_c2(33); commit;
begin; select pg_temp.v0008zk_c2(34); commit;
begin; select pg_temp.v0008zk_c2(35); commit;
begin; select pg_temp.v0008zk_c2(36); commit;
begin; select pg_temp.v0008zk_c2(37); commit;
begin; select pg_temp.v0008zk_c2(38); commit;
begin; select pg_temp.v0008zk_c2(39); commit;
begin; select pg_temp.v0008zk_c2(40); commit;
begin; select pg_temp.v0008zk_c2(41); commit;
begin; select pg_temp.v0008zk_c2(42); commit;
begin; select pg_temp.v0008zk_c2(43); commit;
begin; select pg_temp.v0008zk_c2(44); commit;
begin; select pg_temp.v0008zk_c2(45); commit;
begin; select pg_temp.v0008zk_c2(46); commit;
begin; select pg_temp.v0008zk_c2(47); commit;
begin; select pg_temp.v0008zk_c2(48); commit;
begin; select pg_temp.v0008zk_c2(49); commit;
begin; select pg_temp.v0008zk_c2_check(); commit;
begin; select pg_temp.v0008zk_c5('page'); commit;
begin; select pg_temp.v0008zk_c5('list'); commit;
begin; select pg_temp.v0008zk_c5_check(); commit;
begin; select pg_temp.v0008zk_clean('end', 'verify-0008zk-volume'); commit;

-- -----------------------------------------------------------------------------------------------
-- Z. Every step its own transaction; the throwaway tenants removed
-- -----------------------------------------------------------------------------------------------
-- Z1. every step ran in a transaction of its own (no two steps share a transaction id); the server's version and the
--     settings the speed depends on in the detail
-- Z2. the throwaway tenants removed with every row and audit row of theirs, at the start (what an interrupted run left)
--     and at the end; every foreign key into a tenant's rows (into cma.tenant or a table with a tenant_id) comes from a
--     table of cma and pairs tenant_id with the tenant's id, which is what lets the cleanup remove a tenant table by
--     table (dev, 28 October 2026)
do $$
declare
  v_steps bigint := (select count(*) from pg_temp.v0008zk_step);
  v_xacts bigint := (select count(distinct s.xact) from pg_temp.v0008zk_step s);
  v_ids   uuid[] := array(select (s.answer ->> 'tenant')::uuid from pg_temp.v0008zk_step s where s.step = 'end' and s.answer ->> 'tenant' is not null);
  v_left  text;
  v_fks   bigint;
  v_stray text;
begin
  select count(*),
         string_agg(k.conrelid::regclass || ' ' || k.conname, ', ' order by k.conrelid::regclass::text, k.conname)
           filter (where k.connamespace <> 'cma'::regnamespace
                      or not exists (select 1 from unnest(k.conkey, k.confkey) as p(ch, pk)
                                     join pg_attribute ca on ca.attrelid = k.conrelid and ca.attnum = p.ch
                                     join pg_attribute fa on fa.attrelid = k.confrelid and fa.attnum = p.pk
                                     where ca.attname = 'tenant_id'
                                       and fa.attname = case when pa.relname = 'tenant' then 'id' else 'tenant_id' end))
    into v_fks, v_stray
  from pg_constraint k join pg_class pa on pa.oid = k.confrelid
  where k.contype = 'f' and k.conparentid = 0 and pa.relnamespace = 'cma'::regnamespace
    and (pa.relname = 'tenant'
         or exists (select 1 from pg_attribute a where a.attrelid = pa.oid and a.attname = 'tenant_id' and not a.attisdropped));
  perform pg_temp.v0008zk_check(90, 'Z1 every step its own transaction, as each of the ingest''s calls is',
    v_steps > 200 and v_xacts = v_steps,
    format('%s steps, %s transactions; %s; shared_buffers %s, work_mem %s, jit %s', v_steps, v_xacts,
           split_part(version(), ' on ', 1), current_setting('shared_buffers'), current_setting('work_mem'), current_setting('jit')));
  v_left := concat_ws(', ',
    nullif((select count(*) from cma.tenant t where t.slug like 'verify-0008zk-%')::text, '0') || ' tenants',
    nullif((select count(*) from cma.audit_log a where a.tenant_id = any (v_ids))::text, '0') || ' audit rows',
    nullif((select count(*) from cma.device d where d.tenant_id = any (v_ids))::text, '0') || ' devices',
    (select string_agg(s.answer ->> 'slug' || ' ' || coalesce(s.error, s.answer ->> 'result'), '; ' order by s.ord) from pg_temp.v0008zk_step s
     where s.step in ('start', 'end') and (s.error is not null or s.answer ->> 'result' not in ('absent', 'removed'))),
    'foreign keys the cleanup does not cover: ' || v_stray);
  perform pg_temp.v0008zk_check(91, 'Z2 the throwaway tenants removed with their rows and audit rows, at the start and at the end; every foreign key into a tenant''s rows from a table of cma, paired on tenant_id',
    v_left = '' and (select count(*) from pg_temp.v0008zk_step s where s.step = 'end' and s.answer ->> 'result' = 'removed') = 4,
    coalesce(nullif(v_left, ''), format('start: %s; end: %s removed in %s ms; %s foreign keys into a tenant''s rows, all from cma and paired on tenant_id',
      (select string_agg(s.answer ->> 'slug' || ' ' || (s.answer ->> 'result'), ', ' order by s.ord) from pg_temp.v0008zk_step s where s.step = 'start'),
      (select count(*) from pg_temp.v0008zk_step s where s.step = 'end' and s.answer ->> 'result' = 'removed'),
      (select sum(s.ms) from pg_temp.v0008zk_step s where s.step = 'end'), v_fks)));
end
$$;

-- The helpers are dropped first, so the verdict is the last thing the script prints
drop function if exists pg_temp.v0008zk_code(text);
drop function if exists pg_temp.v0008zk_error(text);
drop function if exists pg_temp.v0008zk_log(text, integer, numeric, jsonb, text);
drop function if exists pg_temp.v0008zk_tenant(text);
drop function if exists pg_temp.v0008zk_conn(text, text);
drop function if exists pg_temp.v0008zk_as(text, text);
drop function if exists pg_temp.v0008zk_new_tenant(text);
drop function if exists pg_temp.v0008zk_cleanup(text);
drop function if exists pg_temp.v0008zk_clean(text, text);
drop function if exists pg_temp.v0008zk_register(integer, integer, boolean);
drop function if exists pg_temp.v0008zk_chunk(integer, integer, boolean);
drop function if exists pg_temp.v0008zk_ids(int4range[]);
drop function if exists pg_temp.v0008zk_slice(text[], integer, integer);
drop function if exists pg_temp.v0008zk_sum(text[], integer);
drop function if exists pg_temp.v0008zk_counts(jsonb);
drop function if exists pg_temp.v0008zk_failed(text[]);
drop function if exists pg_temp.v0008zk_check(integer, text, boolean, text);
drop function if exists pg_temp.v0008zk_fingerprint(uuid);
drop function if exists pg_temp.v0008zk_load(text, integer, text, text, jsonb);
drop function if exists pg_temp.v0008zk_mark(text, integer, text, text, text[]);
drop function if exists pg_temp.v0008zk_b_load(text, text, integer, boolean);
drop function if exists pg_temp.v0008zk_b_final(text, integer, integer);
drop function if exists pg_temp.v0008zk_volume(integer, integer);
drop function if exists pg_temp.v0008zk_volume_ids(integer, integer);
drop function if exists pg_temp.v0008zk_best_ms(text);
drop function if exists pg_temp.v0008zk_c3_setup();
drop function if exists pg_temp.v0008zk_c3_part(integer);
drop function if exists pg_temp.v0008zk_c3();
drop function if exists pg_temp.v0008zk_b_setup();
drop function if exists pg_temp.v0008zk_b_fp(text);
drop function if exists pg_temp.v0008zk_b1_one_call();
drop function if exists pg_temp.v0008zk_b1();
drop function if exists pg_temp.v0008zk_b2();
drop function if exists pg_temp.v0008zk_b3();
drop function if exists pg_temp.v0008zk_b4();
drop function if exists pg_temp.v0008zk_b5();
drop function if exists pg_temp.v0008zk_b6();
drop function if exists pg_temp.v0008zk_b7();
drop function if exists pg_temp.v0008zk_b8_rows(text);
drop function if exists pg_temp.v0008zk_b8_state(text);
drop function if exists pg_temp.v0008zk_b8();
drop function if exists pg_temp.v0008zk_c_setup();
drop function if exists pg_temp.v0008zk_c4_next();
drop function if exists pg_temp.v0008zk_c2(integer);
drop function if exists pg_temp.v0008zk_c4_check();
drop function if exists pg_temp.v0008zk_analyze();
drop function if exists pg_temp.v0008zk_c1();
drop function if exists pg_temp.v0008zk_c2_check();
drop function if exists pg_temp.v0008zk_c5(text);
drop function if exists pg_temp.v0008zk_c5_check();

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008zk
      union all
      select 99, 'verdict',
             case when not current_setting('verify.dev')::boolean then 'REFUSED: not dev or a local database'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008zk where result = 'ok') = 21
                       and not exists (select 1 from verify_0008zk where result <> 'ok') then '0008zk verified'
                  else 'FAIL' end,
             format('117_verify_asset_sync_load: %s ok, %s FAIL', (select count(*) from verify_0008zk where result = 'ok'),
                                                                (select count(*) from verify_0008zk where result <> 'ok'))) x
order by ord;
reset role;
