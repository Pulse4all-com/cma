-- =============================================================================================
-- 116_asset_sync_load.sql: addition 0008zk, the device load set-based, the ingest's load in bounded chunks and slices, and
-- the forecast at the register's horizon of 50,000 devices
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after 114_asset_sync.sql
-- (0008zj). Rerunnable, forward-only, in one transaction. Run as your own IAM login: dev first, then
-- 117_verify_asset_sync_load.sql, then 115_verify_asset_sync.sql and 113_verify_assets.sql again (the load and the
-- forecast they prove are the ones this script makes again); then prod, with 115 and 113 (117 runs in dev and local
-- databases only: Decision log, 28 October 2026; prod's speed is PROD_RUNBOOK 14.7's first full read). The ingest of main reads
-- nothing this adds; the ingest of this change needs it (cma.ingest_load_device_chunk, cma.ingest_mark_devices_missing in
-- slices, cma.ingest_record_field_types, the run's phase times), so in prod the script runs before that ingest is deployed.
-- Edited in place after its dev run of 27 October 2026 (records/0008zk-dev-2026-10-27): CLAUDE.md forbids editing a
-- script that has run in prod, and this one has run in dev only; a rerun over that version replaces what it changed
-- (the final missing-marking's two-argument form is dropped).
--
-- Why (prod, 27 October 2026: 115's C1, a nightly full snapshot of 5,000 unchanged records staged and loaded in one
-- call as the Ingest user, took 14,844.5 ms; dev 6,821.0 ms). Prod's register of some 9,700 records would pass the
-- ingest's 15-second statement timeout. Measured locally at prod's shape (a tenant with 10,000 devices and 20,000
-- components, a second tenant, 2.1 million audit rows, the staging after a previous load), one call of 10,000
-- unchanged records spent: staging 2,549 ms, the row checks 720 ms, the per-row mapping 2,702 ms, the per-row device
-- and component lookups 701 ms, the staged rows' cleanup 700 ms; 115's C1 itself took 3,364 to 3,457 ms. The causes:
--   per-row loops     0008zi's load (112, moved unchanged into cma.device_snapshot_apply by 114) walks the batch twice
--                     in PL/pgSQL, row by row, calling the catalog lookups (model, status, market) and the value
--                     helpers once per row, and locks every device and component it reads (select … for update), so
--                     an unchanged record still takes two or three row locks
--   subtransactions   its helpers device_staged_date, device_staged_object and device_staged_object_without_at are
--                     PL/pgSQL with an exception block, which opens a subtransaction on every call: about 14 per record
--                     (staging and load), 140,000 for 10,000 records, far past the 64 a backend caches; 100,000 calls
--                     cost 107 to 283 ms locally against 40 ms for the same checks without one
--   patterns          0008zi's patterns repeat a bounded count ({0,99}, {1,100}, {0,39}), which the regular expression
--                     engine runs some eight times slower than * with the length checked beside it, for every reference
--                     of every record
--   audit             a staged row is audited twice (its insert and its delete, keys only, as 0008zi decided). Staging
--                     5,000 rows takes 1.0 to 1.2 s locally: the audit about 0.44 s, the per-row permission check about
--                     0.35 s, the trigger's own insert per row about 0.37 s; deleting them 0.2 to 0.3 s, nearly all
--                     audit. Unchanged devices and components write no audit row (nothing is updated). The staging and
--                     its audit stay as 0008zi decided (113's B15 proves the staged rows' audit): the ingest's chunks no
--                     longer stage at all
--   estimates         found while bounding the chunks: a load into a connection that is filling (a first load, or a
--                     throwaway tenant) has no statistics for its rows, so the planner takes it for one row and may scan
--                     the whole chunk once per device or component it holds; a first load of 10,000 in chunks of 1,000
--                     grew from 0.5 to 2.2 s a chunk. The load's lookups are driven by the rows (each row looks up its
--                     device and its current components by index) and its updates select their rows by id, so no plan
--                     rests on those estimates: every chunk of that first load now takes about 0.4 s
--   not the cause     row-level security: cma.current_tenant_id() is a stable SQL function, inlined, and the plans use
--                     it as an index condition (a one-time filter), never per row; indexes: every lookup of the load has
--                     its index (device on tenant, connection and record id; the current component on tenant, device and
--                     kind; the staging on tenant and batch key)
-- After this script, locally: 115's C1 1,382 to 1,709 ms (the staging insert 0.95 to 1.2 s of it); a register of
-- 10,000 records loaded in one call 12,391 ms before, 5,069 ms after; the night after it (1,000 new, 1,440 changed,
-- 1,000 gone) 5,710 ms before, 2,830 ms after, with the same counts, devices, components and audit rows; one chunk of
-- 1,000 unchanged rows 104 ms.
--
-- Why the second version (dev, 27 October 2026: the load about twice as fast, 115's C1 3,549.0 ms warm; 117 failed C3
-- and C4 inside one transaction that also held its 10,000-record scenario, and its provoked rerun lost the server's
-- connection). The register grows by thousands of devices a year, so the load and the forecast are designed and tested for
-- 50,000 devices. Measured locally on a cluster held to db-g1-small's memory (1.5 GB, shared_buffers 560 MB, work_mem
-- 4 MB) with a database in Cloud SQL's collation (en_US.UTF-8), where 113's C1 with 0008zi's forecast took 153 and 126 ms
-- against dev's 146.0 and 130.8:
--   the final step    one statement over every record id of the run grows with the register: over 49,500 ids of
--                     50,000 devices it took 190 ms locally, well within 117's budget, but dev ran the first 117's C2 at
--                     710 ms against some 40 locally, and its work grows with every device. It is cut into slices of the
--                     run's chunk size, each its own call over its own range of record ids (by a partial index in byte
--                     order): about 2 ms a slice of 1,000 at 50,000 devices, whatever the register's size
--   the forecast      0008zi's forecast walks every due item in a PL/pgSQL loop, builds an exchange key and two bucket
--                     labels as text per item, and its page and list group and sort that text (a slow comparison in
--                     en_US.UTF-8): at 50,000 devices (about 106,000 items) the page took 1,567 ms and the list 1,861 ms.
--                     Made again with the same results: the items as one statement with the bundling as a running
--                     aggregate, the buckets as dates, text written for the cells and rows answered only: 738 and 817 ms
--   an emptied kind   0008zi's load left out a component kind whose serial and expiry were both empty, so the device kept
--                     the component the register no longer holds. The register is the source of truth (Decision log,
--                     28 October 2026): a kind staged empty closes the current component (replaced_at, no new row), and
--                     its item has no due date (component_due_unknown) until the register holds the kind again: the
--                     same serial (or a missing one) reopens it, its anchor kept; another serial is a replacement
--
-- What it adds
--   the load          cma.device_rows_apply(connection, rows, is_full): 0008zi's load as a handful of set-based
--                     statements over an array of rows (types cma.device_load_row, cma.device_load_mapped,
--                     cma.device_load_component): the checks (the same refusals, naming the same line and column),
--                     the mapping (each value read once, each catalog label looked up once, not once per row), the
--                     devices (each row's device looked up by index; the changed ones updated by id, the new ones
--                     inserted), the components (each row's current ones looked up by index; the replaced ones closed by
--                     id, the new ones inserted, the changed ones updated by id, the current one of a kind staged empty
--                     closed by id with no new row), the missing ones of a full snapshot; no row lock (the per-connection
--                     advisory lock of 0008zj serialises loads) and no subtransaction (the value checks use
--                     pg_input_is_valid). The counts are 0008zi's, plus components_closed and the phase times in
--                     milliseconds: map_ms (the checks and the mapping), upsert_ms, components_ms, missing_ms. The same
--                     results as 0008zi's load for every row 0008zi's tools and 113 and 115 stage: they pass unchanged
--   the file path     cma.device_snapshot_apply(batch, connection, is_full) is made again over it, with 0008zj's
--                     refusals in their order: the staged batch read into rows (stage_ms), the load, the staged rows
--                     deleted (cleanup_ms). cma.load_device_snapshot and cma.ingest_load_device_snapshot (0008zj) call it
--                     as before: one call, one transaction
--   the staging       cma.device_import_staging_insert() is made again to call the JSON helper only for a value that
--                     holds an @ (no subtransaction per staged row otherwise); the same values are staged, the
--                     permission still checked on every row
--   the patterns      cma.device_staged_ref() is made again with * for {0,99} (the same result: cma.device_staged_text
--                     already holds 1 to 100 characters); the load writes 0008zi's other patterns the same way
--   the ingest's chunks cma.ingest_load_device_chunk(connection, rows) (ingest.write, a connection with a token secret
--                     name): one chunk of 1 to 5,000 rows as JSON, its own call and transaction, loaded without marking
--                     anything missing; the staging's columns only, each within the staging's length, the line a whole
--                     number from 2 to 10,000,000 (CMA04 otherwise); no staging, so no staged row is audited or
--                     cleaned up. A value holding an @ is kept as a bare @, as the staging keeps it
--   the final step    cma.ingest_mark_devices_missing(connection, record ids, from, before) (ingest.write): a full
--                     snapshot's last step, one slice of at most 5,000 of the run's record ids (sorted by their bytes)
--                     per call and transaction; the connection's present devices in the slice's range whose record id is
--                     not among its ids marked missing. CMA04 without an id, with an id outside the range or bounds out of
--                     order, so a run that fails before this step marks nothing. The index device_present_source_c_idx
--                     (tenant, connection, record id in collation "C", present devices only) serves the ranges
--   an index          device_component_device_idx (tenant, device): the components' foreign key to their device, so
--                     removing a tenant's devices looks each one's components up by index
--   field types       cma.ingest_record_field_types(connection, items) (ingest.write): the type the ingest first read
--                     for each mapped property of an asset register (connection_field.source_type, as 0008zb keeps a
--                     reason property's type); a type that later differs is the adapter's to refuse
--   settings          cma.assets_settings_problem() knows assets_load_chunk, the rows of a chunk (a whole number from
--                     100 to 5,000; the adapter's default 1,000). cma.set_connection_settings() refuses view_id on an
--                     asset register (CMA04): it is read whole, since a view's filter would make every device outside
--                     it look missing at night; an asset register's stored view_id is removed
--   runs              cma.ingest_sync_run_finish() takes the phase times (stage_ms, map_ms, upsert_ms, components_ms,
--                     missing_ms, cleanup_ms), components_closed, the slowest call of a run (chunk_max_ms, the slowest
--                     chunk; slice_max_ms, the slowest slice of the final step; milliseconds as the ingest measures
--                     each call) and its adaptive chunks (chunk_size_min, the smallest chunk size in force;
--                     chunk_halvings, how often the ingest halved it) among the counts
--   the forecast      cma.maintenance_items_of, cma.maintenance_bucketed_of, cma.maintenance_page_of and
--                     cma.maintenance_rows_of made again with 0008zi's results (113 passes unchanged), over the new
--                     cma.maintenance_bucket_dates_of and the aggregate cma.maintenance_exchange_start
--                     (cma.maintenance_exchange_step); a kind with a closed component and none current is a due item
--                     without a due date (basis unknown)
--
-- Everything is SECURITY INVOKER and executable by the application only, with its permission checked inside.
-- SQLSTATEs as before: CMA01 no acting user, CMA02 not found, CMA03 conflict, CMA04 invalid, CMA06 not permitted.
--
-- Guard: scripts run under a personal IAM login so the audit trail names a person. postgres is
-- for emergencies only; to use it deliberately, run first:  set cma.emergency = 'on';
do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;

begin;
set role cma_owner;

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0008zj') then
    raise exception 'addition 0008zj (114_asset_sync.sql) must run before 0008zk';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The load's row types
-- ---------------------------------------------------------------------------------------------
-- A row as the staging holds it: every value text, as staged (cma.device_import_row's columns but the keys)
do $$
begin
  if to_regtype('cma.device_load_row') is null then
    create type cma.device_load_row as (
      source_row integer, source_id text, serial text, model text, status text, country text, warehouse_ref text,
      customer_ref text, subscription_ref text, order_ref text, first_shipped_on text, stock_received_on text,
      last_shipped_on text, warranty_until text, end_of_life_on text, components text, external_refs text);
  end if;
  -- a row as the load maps it: the record id, the device's values, the components and named ids as kept, the raw,
  -- the references dropped
  if to_regtype('cma.device_load_mapped') is null then
    create type cma.device_load_mapped as (
      source_row integer, source_id text, serial text, model_key text, market text, device_status_key text,
      warehouse_ref text, customer_ref text, customer_ref_invalid boolean, subscription_ref text, order_ref text,
      first_shipped_on date, stock_received_on date, last_shipped_on date, warranty_until date, end_of_life_on date,
      external_refs jsonb, components jsonb, raw jsonb, refs_dropped integer);
  end if;
  -- a staged component against the device's current one of its kind: what the load does with it
  if to_regtype('cma.device_load_component') is null then
    create type cma.device_load_component as (
      device_id uuid, component_key text, serial text, expires_on date, current_id uuid, action text);
  end if;
end
$$;
comment on type cma.device_load_row is 'A device record as staged, every value text: the input of cma.device_rows_apply (0008zk)';
comment on type cma.device_load_mapped is 'A device record as cma.device_rows_apply maps it (0008zk)';
comment on type cma.device_load_component is 'A staged component against the device''s current one of its kind, and the load''s action (0008zk)';

-- ---------------------------------------------------------------------------------------------
-- 2. Value checks without a subtransaction
-- ---------------------------------------------------------------------------------------------
-- A staged JSON object (components, external_refs) as cma.device_staged_object reads it: {} when empty, the object,
-- or null when the text is no JSON object (where device_staged_object refuses the load); no exception block. Stable,
-- as pg_input_is_valid is, so the planner inlines it into the load's statements
create or replace function cma.device_staged_json(p_value text)
returns jsonb
language sql stable
as $$
  select case when nullif(btrim(p_value), '') is null then '{}'::jsonb
              when pg_input_is_valid(btrim(p_value), 'jsonb')
                then case when jsonb_typeof(btrim(p_value)::jsonb) = 'object' then btrim(p_value)::jsonb end
         end
$$;

-- Whether a staged date reads as cma.device_staged_date reads it: empty, or YYYY-MM-DD that is a date (stable, inlined)
create or replace function cma.device_staged_date_ok(p_value text)
returns boolean
language sql stable
as $$
  select nullif(btrim(p_value), '') is null
      or (btrim(p_value) ~ '^\d{4}-\d{2}-\d{2}$' and pg_input_is_valid(btrim(p_value), 'date'))
$$;

-- As 0008zi (112) left it, with the same result: cma.device_staged_text already holds a reference to 1 to 100
-- characters, so the bounded repetition {0,99} becomes *, which the regular expression engine runs some eight times
-- faster (it is evaluated for every reference of every record)
create or replace function cma.device_staged_ref(p_value text)
returns text
language sql immutable
as $$
  select case when cma.device_staged_text(p_value) ~ '^[A-Za-z0-9#][A-Za-z0-9 _.#:/-]*$' then cma.device_staged_text(p_value) end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. The load, set-based
-- ---------------------------------------------------------------------------------------------
-- Loads rows into the connection's devices, with 0008zi's rules and results (112, cma.load_device_snapshot):
--   checks    rows present; every row a record id and no id twice; then, for the first row by line that holds a
--             problem, its first problem in 0008zi's order: components and external_refs JSON objects, the five dates,
--             each component kind in the catalog with only serial and expires_on as text and its expiry a date (all
--             CMA04, naming the line and the column as 0008zi does)
--   mapping   model, status and market through the catalogs (each distinct label once, by 0008zi's functions), the
--             references kept only when they are ids, the customer reference only when it matches ^[A-Za-z0-9_-]{1,100}$,
--             the named ids and components as kept, raw, the references dropped
--   devices   a known device whose values differ (or that was missing) updated; a new one inserted
--   components per staged kind: none current, inserted; a current one whose serial differs from the staged one (both
--             present), closed (replaced_at) and a new one inserted; otherwise the current one updated when its serial
--             or expiry differs. A kind staged empty (an empty object, or serial and expiry both empty: the register
--             emptied the kind's fields) closes the current one (replaced_at) with no new row, so its item has no due
--             date until the register holds the kind again; then the same serial (or a missing one) reopens that
--             component (its anchor kept) and a different serial is a replacement. A kind the row does not stage is
--             left as it is (the source does not map it). A known device with any of these is updated
--   missing   a full snapshot (p_is_full) marks the connection's devices it does not hold
-- Holder of tenant.configure, or of ingest.write for a connection with a token secret name; one load per connection at
-- a time (the advisory lock of 0008zj). Answers 0008zi's counts, components_closed, and map_ms, upsert_ms, components_ms
-- and missing_ms
create or replace function cma.device_rows_apply(p_connection_id uuid, p_rows cma.device_load_row[], p_is_full boolean)
returns jsonb
language plpgsql
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_user    uuid;
  v_system  text;
  v_bad     text;
  v_m       cma.device_load_mapped[];
  v_newm    cma.device_load_mapped[];
  v_plan    cma.device_load_component[];
  v_dmap    jsonb;
  v_umap    jsonb;
  v_changed uuid[];
  v_new     uuid[];
  v_rid     uuid[];
  v_rows    integer;
  v_ins     integer;
  v_upd     integer;
  v_repl    integer;
  v_cid     uuid[];
  v_missing integer := 0;
  v_t       timestamptz;
  v_map     numeric;
  v_ups     numeric;
  v_cmp     numeric;
  v_mis     numeric := 0;
begin
  v_user := cma.assert_any_permission(array['tenant.configure', 'ingest.write']);
  v_system := cma.active_connection_adapter(p_connection_id);
  perform cma.assert_assets_connection(p_connection_id);
  if not cma.has_permission(v_user, 'tenant.configure')
     and (select ic.token_secret_name from cma.integration_connection ic where ic.tenant_id = v_tenant and ic.id = p_connection_id) is null then
    raise exception 'connection % has no token secret name: it is loaded from files (cma.load_device_snapshot), not by the ingest', p_connection_id
      using errcode = 'CMA04';
  end if;
  perform pg_advisory_xact_lock(hashtext('cma-device-load'), hashtext(p_connection_id::text));
  if p_is_full is null then
    raise exception 'is_full must be true (a full snapshot) or false (a partial one)' using errcode = 'CMA04';
  end if;
  v_rows := coalesce(cardinality(p_rows), 0);
  if v_rows = 0 then
    raise exception 'no rows to load' using errcode = 'CMA04';
  end if;
  v_t := clock_timestamp();

  -- the checks, before anything is written
  select string_agg(coalesce(x.source_row::text, '?'), ', ' order by x.source_row) into v_bad
  from (select r.source_row from unnest(p_rows) r where cma.device_staged_text(r.source_id) is null order by r.source_row limit 20) x;
  if v_bad is not null then
    raise exception 'lines %: no record id (or one that is no id)', v_bad using errcode = 'CMA04';
  end if;
  select string_agg(x.sid || ' (lines ' || x.lines || ')', '; ' order by x.sid) into v_bad
  from (select cma.device_staged_text(r.source_id) as sid, string_agg(coalesce(r.source_row::text, '?'), ', ' order by r.source_row) as lines
        from unnest(p_rows) r
        group by 1 having count(*) > 1
        order by 1 limit 20) x;
  if v_bad is not null then
    raise exception 'a record id appears twice: %', v_bad using errcode = 'CMA04';
  end if;
  -- each row's own problems (n 0) before its components' (n 1, 2, … in the object's order); the first row by line
  select x.problem into v_bad
  from (select r.source_row, 0::bigint as n,
               case when r.cj is null then format('line %s: components is not a JSON object', coalesce(r.source_row::text, '?'))
                    when r.rj is null then format('line %s: external_refs is not a JSON object', coalesce(r.source_row::text, '?'))
                    when not cma.device_staged_date_ok(r.first_shipped_on)
                      then format('line %s: first_shipped_on is not a date as YYYY-MM-DD', coalesce(r.source_row::text, '?'))
                    when not cma.device_staged_date_ok(r.stock_received_on)
                      then format('line %s: stock_received_on is not a date as YYYY-MM-DD', coalesce(r.source_row::text, '?'))
                    when not cma.device_staged_date_ok(r.last_shipped_on)
                      then format('line %s: last_shipped_on is not a date as YYYY-MM-DD', coalesce(r.source_row::text, '?'))
                    when not cma.device_staged_date_ok(r.warranty_until)
                      then format('line %s: warranty_until is not a date as YYYY-MM-DD', coalesce(r.source_row::text, '?'))
                    when not cma.device_staged_date_ok(r.end_of_life_on)
                      then format('line %s: end_of_life_on is not a date as YYYY-MM-DD', coalesce(r.source_row::text, '?'))
               end as problem
        from (select u.source_row, cma.device_staged_json(u.components) as cj, cma.device_staged_json(u.external_refs) as rj,
                     u.first_shipped_on, u.stock_received_on, u.last_shipped_on, u.warranty_until, u.end_of_life_on
              from unnest(p_rows) u offset 0) r
        union all
        select r.source_row, e.n,
               case when k.key is null then format('line %s: no component kind %s', coalesce(r.source_row::text, '?'), cma.device_staged_without_at(e.key))
                    when jsonb_typeof(e.value) <> 'object'
                      then format('line %s: component %s holds serial and expires_on only, as text', coalesce(r.source_row::text, '?'), cma.device_staged_without_at(e.key))
                    when e.value - 'serial' - 'expires_on' <> '{}'::jsonb
                         or coalesce(jsonb_typeof(e.value -> 'serial'), 'null') not in ('string', 'null')
                         or coalesce(jsonb_typeof(e.value -> 'expires_on'), 'null') not in ('string', 'null')
                      then format('line %s: component %s holds serial and expires_on only, as text', coalesce(r.source_row::text, '?'), cma.device_staged_without_at(e.key))
                    when not cma.device_staged_date_ok(e.value ->> 'expires_on')
                      then format('line %s: %s.expires_on is not a date as YYYY-MM-DD', coalesce(r.source_row::text, '?'), cma.device_staged_without_at(e.key))
               end
        from unnest(p_rows) r
        cross join lateral jsonb_each(cma.device_staged_json(r.components)) with ordinality as e(key, value, n)
        left join cma.device_component_kind k on k.tenant_id = v_tenant and k.key = e.key) x
  where x.problem is not null
  order by x.source_row, x.n
  limit 1;
  if v_bad is not null then
    raise exception '%', v_bad using errcode = 'CMA04';
  end if;

  -- the mapping: every value read once per row (r, materialized), each distinct label looked up once by 0008zi's
  -- functions, the named ids and the components of all rows grouped by record id (no per-row aggregate). The patterns
  -- are 0008zi's, a bounded repetition written as * with the length checked beside it (the same result, faster)
  with r as materialized (
         select u.source_row, cma.device_staged_text(u.source_id) as sid, u.model, u.status, cma.device_staged_text(u.model) as model_t,
                cma.device_staged_text(u.status) as status_t, cma.device_staged_text(u.country) as country,
                cma.device_staged_ref(u.serial) as serial, cma.device_staged_ref(u.warehouse_ref) as wh,
                case when btrim(coalesce(u.customer_ref, '')) ~ '^[A-Za-z0-9_-]+$' and length(btrim(u.customer_ref)) <= 100
                     then btrim(u.customer_ref) end as cust,
                nullif(btrim(coalesce(u.customer_ref, '')), '') is not null as cust_given,
                cma.device_staged_ref(u.subscription_ref) as sub, cma.device_staged_ref(u.order_ref) as ord,
                nullif(btrim(u.first_shipped_on), '')::date as first, nullif(btrim(u.stock_received_on), '')::date as recv,
                nullif(btrim(u.last_shipped_on), '')::date as last, nullif(btrim(u.warranty_until), '')::date as warr,
                nullif(btrim(u.end_of_life_on), '')::date as eol,
                -- the checks proved each empty or a JSON object: read once
                coalesce(nullif(btrim(u.components), '')::jsonb, '{}'::jsonb) as cj,
                coalesce(nullif(btrim(u.external_refs), '')::jsonb, '{}'::jsonb) as rj,
                nullif(btrim(coalesce(u.serial, '')), '') is not null as serial_given,
                nullif(btrim(coalesce(u.warehouse_ref, '')), '') is not null as wh_given,
                nullif(btrim(coalesce(u.subscription_ref, '')), '') is not null as sub_given,
                nullif(btrim(coalesce(u.order_ref, '')), '') is not null as ord_given
         from unnest(p_rows) u),
       models as (select l.label, cma.device_model_key_of(v_tenant, l.label) as key from (select distinct r.model as label from r) l),
       statuses as (select l.label, cma.device_status_key_of(v_tenant, l.label) as key from (select distinct r.status as label from r) l),
       markets as (select l.label, cma.market_code_of(v_tenant, l.label) as code from (select distinct r.country as label from r) l),
       -- the named ids: an id kept under its name, anything else dropped and counted, as is a name that is no name
       ref_items as materialized (
         select r.sid, x.key, nullif(btrim(coalesce(x.value #>> '{}', '')), '') is not null as given,
                x.key ~ '^[a-z][a-z0-9_]*$' and length(x.key) <= 40 as named,
                cma.device_staged_ref(x.value #>> '{}') as ref
         from r cross join lateral jsonb_each(r.rj) x),
       refs as (select i.sid,
                       jsonb_object_agg(i.key, i.ref) filter (where i.named and i.ref ~ '^[A-Za-z0-9#][A-Za-z0-9_.#:/-]*$') as refs,
                       (count(*) filter (where i.named and i.given and not coalesce(i.ref ~ '^[A-Za-z0-9#][A-Za-z0-9_.#:/-]*$', false))
                        + count(*) filter (where not i.named))::integer as dropped
                from ref_items i group by i.sid),
       -- the components as mapped: each kind's serial (an id, else dropped and counted) and expiry. A kind staged with
       -- neither given (emptied in the register) is kept as an empty object for the components, which close its current
       -- one, and left out of raw; a kind whose serial is given but dropped, with no expiry, is left out
       comp_items as materialized (
         select r.sid, c.key, cma.device_staged_ref(c.value ->> 'serial') as serial,
                nullif(btrim(coalesce(c.value ->> 'serial', '')), '') is not null as serial_given,
                (nullif(btrim(c.value ->> 'expires_on'), '')::date)::text as expires_on
         from r cross join lateral jsonb_each(r.cj) c),
       comp as (select i.sid,
                       jsonb_object_agg(i.key, jsonb_strip_nulls(jsonb_build_object('serial', i.serial, 'expires_on', i.expires_on)))
                         filter (where i.serial is not null or i.expires_on is not null) as comp,
                       jsonb_object_agg(i.key, jsonb_strip_nulls(jsonb_build_object('serial', i.serial, 'expires_on', i.expires_on)))
                         filter (where i.serial is not null or i.expires_on is not null or (not i.serial_given and i.expires_on is null)) as plan,
                       (count(*) filter (where i.serial_given and i.serial is null))::integer as dropped
                from comp_items i group by i.sid)
  select array_agg(row(r.source_row, r.sid, r.serial, mo.key, mk.code, st.key, r.wh, r.cust, r.cust is null and r.cust_given, r.sub, r.ord,
                       r.first, r.recv, r.last, r.warr, r.eol, coalesce(rf.refs, '{}'::jsonb), coalesce(cp.plan, '{}'::jsonb),
                       jsonb_strip_nulls(jsonb_build_object(
                         'source_id', r.sid, 'serial', r.serial, 'model', r.model_t, 'status', r.status_t, 'country', r.country,
                         'warehouse_ref', r.wh, 'customer_ref', r.cust, 'subscription_ref', r.sub, 'order_ref', r.ord,
                         'first_shipped_on', r.first::text, 'stock_received_on', r.recv::text, 'last_shipped_on', r.last::text,
                         'warranty_until', r.warr::text, 'end_of_life_on', r.eol::text,
                         'components', cp.comp, 'external_refs', rf.refs)),
                       (r.serial_given and r.serial is null)::integer + (r.wh_given and r.wh is null)::integer
                       + (r.sub_given and r.sub is null)::integer + (r.ord_given and r.ord is null)::integer
                       + coalesce(rf.dropped, 0) + coalesce(cp.dropped, 0))::cma.device_load_mapped
                   order by r.source_row)
    into v_m
  from r
  left join models mo on mo.label is not distinct from r.model
  left join statuses st on st.label is not distinct from r.status
  left join markets mk on mk.label is not distinct from r.country
  left join refs rf on rf.sid = r.sid
  left join comp cp on cp.sid = r.sid;
  v_map := round(extract(epoch from clock_timestamp() - v_t) * 1000);
  v_t := clock_timestamp();

  -- the devices. Each row looks up its device by the record id's index (the rows drive every lookup, so no plan rests on
  -- the statistics of a connection this load is filling): a known one whose values differ (or that was missing), kept
  -- with its mapped values by id, and the new rows
  select coalesce(jsonb_object_agg(x.id::text, to_jsonb(m)) filter (where x.differs), '{}'::jsonb),
         coalesce(array_agg(m order by m.source_row) filter (where x.id is null), '{}')
    into v_dmap, v_newm
  from unnest(v_m) m
  left join lateral (select d.id,
                            (d.serial, d.model_key, d.market, d.device_status_key, d.warehouse_ref, d.customer_ref, d.customer_ref_invalid,
                             d.subscription_ref, d.order_ref, d.first_shipped_on, d.stock_received_on, d.last_shipped_on, d.warranty_until,
                             d.end_of_life_on, d.external_refs, d.raw, d.source_deleted_at)
                            is distinct from
                            (m.serial, m.model_key, m.market, m.device_status_key, m.warehouse_ref, m.customer_ref, m.customer_ref_invalid,
                             m.subscription_ref, m.order_ref, m.first_shipped_on, m.stock_received_on, m.last_shipped_on, m.warranty_until,
                             m.end_of_life_on, m.external_refs, m.raw, null::timestamptz) as differs
                     from cma.device d
                     where d.tenant_id = v_tenant and d.connection_id = p_connection_id and d.source_id = m.source_id
                     limit 1) x on true;
  -- the changed ones updated by id, each from its mapped values
  with u as (update cma.device d
                set (serial, model_key, market, device_status_key, warehouse_ref, customer_ref, customer_ref_invalid, subscription_ref,
                     order_ref, first_shipped_on, stock_received_on, last_shipped_on, warranty_until, end_of_life_on, external_refs, raw)
                  = (select n.serial, n.model_key, n.market, n.device_status_key, n.warehouse_ref, n.customer_ref, n.customer_ref_invalid,
                            n.subscription_ref, n.order_ref, n.first_shipped_on, n.stock_received_on, n.last_shipped_on, n.warranty_until,
                            n.end_of_life_on, n.external_refs, n.raw
                     from jsonb_populate_record(null::cma.device_load_mapped, v_dmap -> d.id::text) n),
                    source_deleted_at = null, synced_at = now()
              where d.tenant_id = v_tenant and d.id = any (array(select k::uuid from jsonb_object_keys(v_dmap) k))
              returning d.id)
  select coalesce(array_agg(u.id), '{}') into v_changed from u;
  -- the new ones inserted, in line order
  with i as (insert into cma.device (tenant_id, connection_id, source_system, source_id, serial, model_key, market, device_status_key,
                                     warehouse_ref, customer_ref, customer_ref_invalid, subscription_ref, order_ref, first_shipped_on,
                                     stock_received_on, last_shipped_on, warranty_until, end_of_life_on, external_refs, raw)
             select v_tenant, p_connection_id, v_system, m.source_id, m.serial, m.model_key, m.market, m.device_status_key, m.warehouse_ref,
                    m.customer_ref, m.customer_ref_invalid, m.subscription_ref, m.order_ref, m.first_shipped_on, m.stock_received_on,
                    m.last_shipped_on, m.warranty_until, m.end_of_life_on, m.external_refs, m.raw
             from unnest(v_newm) m
             order by m.source_row
             returning id)
  select coalesce(array_agg(i.id), '{}') into v_new from i;
  v_ins := cardinality(v_new);
  v_ups := round(extract(epoch from clock_timestamp() - v_t) * 1000);
  v_t := clock_timestamp();

  -- the components: each staged kind against the device's current one of that kind, looked up by index from the row;
  -- a kind staged empty closes the current one, or does nothing when there is none. With none current, a kind staged
  -- again whose serial is the one the register emptied (or either serial missing: 0008zi's rule, a replacement is a
  -- serial that differs) is that component again: reopened (replaced_at cleared), its first sighting and so its anchor
  -- kept; a different serial is a replacement, inserted
  select coalesce(array_agg(row(d.id, e.key, e.value ->> 'serial', (e.value ->> 'expires_on')::date, coalesce(c.id, z.id),
                                case when e.value = '{}'::jsonb then case when c.id is null then 'none' else 'close' end
                                     when c.id is null and z.id is not null
                                          and ((e.value ->> 'serial') is null or z.serial is null or (e.value ->> 'serial') = z.serial) then 'reopen'
                                     when c.id is null then 'insert'
                                     when (e.value ->> 'serial') is not null and c.serial is not null and (e.value ->> 'serial') <> c.serial then 'replace'
                                     when (c.serial, c.expires_on) is distinct from (e.value ->> 'serial', (e.value ->> 'expires_on')::date) then 'update'
                                     else 'same' end)::cma.device_load_component), '{}')
    into v_plan
  from unnest(v_m) m
  cross join lateral (select d.id from cma.device d
                      where d.tenant_id = v_tenant and d.connection_id = p_connection_id and d.source_id = m.source_id
                      limit 1) d
  cross join lateral jsonb_each(m.components) e
  left join lateral (select c.id, c.serial, c.expires_on from cma.device_component c
                     where c.tenant_id = v_tenant and c.device_id = d.id and c.component_key = e.key and c.replaced_at is null
                     limit 1) c on true
  -- with none current and the kind staged with a value: the kind's last closed component
  left join lateral (select z.id, z.serial from cma.device_component z
                     where c.id is null and e.value <> '{}'::jsonb
                       and z.tenant_id = v_tenant and z.device_id = d.id and z.component_key = e.key and z.replaced_at is not null
                     order by z.replaced_at desc, z.first_seen_at desc, z.id desc
                     limit 1) z on true;
  -- a replaced one closed, and one whose kind the register emptied, by id
  v_rid := array(select p.current_id from unnest(v_plan) p where p.action = 'replace');
  v_cid := array(select p.current_id from unnest(v_plan) p where p.action = 'close');
  update cma.device_component c set replaced_at = now()
  where c.tenant_id = v_tenant and c.id = any (v_rid || v_cid);
  v_repl := cardinality(v_rid);
  insert into cma.device_component (tenant_id, device_id, component_key, serial, expires_on)
  select v_tenant, p.device_id, p.component_key, p.serial, p.expires_on
  from unnest(v_plan) p
  where p.action in ('insert', 'replace');
  -- a changed one updated in place, and a reopened one current again, by id, from its staged values
  select coalesce(jsonb_object_agg(p.current_id::text, jsonb_build_object('serial', p.serial, 'expires_on', p.expires_on)), '{}'::jsonb)
    into v_umap
  from unnest(v_plan) p where p.action in ('update', 'reopen');
  update cma.device_component c
     set serial = v_umap -> c.id::text ->> 'serial', expires_on = (v_umap -> c.id::text ->> 'expires_on')::date, replaced_at = null
   where c.tenant_id = v_tenant and c.id = any (array(select k::uuid from jsonb_object_keys(v_umap) k));
  -- a known device counts as updated when its values or any of its components changed
  select count(*) into v_upd
  from (select unnest(v_changed)
        union
        select p.device_id from unnest(v_plan) p where p.action not in ('same', 'none')
        except
        select unnest(v_new)) x;
  v_cmp := round(extract(epoch from clock_timestamp() - v_t) * 1000);

  -- a full snapshot: the connection's devices it does not hold are missing now (a hashed set of the rows' record ids)
  if p_is_full then
    v_t := clock_timestamp();
    update cma.device d set source_deleted_at = now(), synced_at = now()
    where d.tenant_id = v_tenant and d.connection_id = p_connection_id and d.source_deleted_at is null
      and d.source_id not in (select m.source_id from unnest(v_m) m where m.source_id is not null);
    get diagnostics v_missing = row_count;
    v_mis := round(extract(epoch from clock_timestamp() - v_t) * 1000);
  end if;

  return jsonb_build_object('rows', v_rows, 'inserted', v_ins, 'updated', v_upd, 'unchanged', v_rows - v_ins - v_upd, 'missing_now', v_missing,
    'components_replaced', v_repl, 'components_closed', cardinality(v_cid),
    'unmapped_model', (select count(*) from unnest(v_m) m where m.model_key is null),
    'unmapped_status', (select count(*) from unnest(v_m) m where m.device_status_key is null),
    'unmapped_market', (select count(*) from unnest(v_m) m where m.market is null),
    'customer_ref_invalid', (select count(*) from unnest(v_m) m where m.customer_ref_invalid),
    'refs_dropped', (select coalesce(sum(m.refs_dropped), 0) from unnest(v_m) m),
    'map_ms', v_map, 'upsert_ms', v_ups, 'components_ms', v_cmp, 'missing_ms', v_mis);
exception when check_violation or not_null_violation or foreign_key_violation then
  raise exception 'invalid device: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- A staged batch through the set-based load (0008zj's cma.device_snapshot_apply, the file path and
-- cma.ingest_load_device_snapshot): the batch's staged rows read (stage_ms), loaded, then deleted (cleanup_ms); CMA02
-- when the batch has no row. One call, one transaction, as before
create or replace function cma.device_snapshot_apply(p_batch_key text, p_connection_id uuid, p_is_full boolean)
returns jsonb
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_rows   cma.device_load_row[];
  v_counts jsonb;
  v_t      timestamptz;
  v_stage  numeric;
  v_user   uuid;
begin
  -- the refusals in 0008zj's order (the load repeats them, unchanged)
  v_user := cma.assert_any_permission(array['tenant.configure', 'ingest.write']);
  perform cma.active_connection_adapter(p_connection_id);
  perform cma.assert_assets_connection(p_connection_id);
  if not cma.has_permission(v_user, 'tenant.configure')
     and (select ic.token_secret_name from cma.integration_connection ic where ic.tenant_id = v_tenant and ic.id = p_connection_id) is null then
    raise exception 'connection % has no token secret name: it is loaded from files (cma.load_device_snapshot), not by the ingest', p_connection_id
      using errcode = 'CMA04';
  end if;
  perform pg_advisory_xact_lock(hashtext('cma-device-load'), hashtext(p_connection_id::text));
  if p_is_full is null then
    raise exception 'is_full must be true (a full snapshot) or false (a partial one)' using errcode = 'CMA04';
  end if;
  if coalesce(p_batch_key, '') !~ '^[a-z0-9_-]{1,64}$' then
    raise exception 'a batch key is 1 to 64 lower-case letters, digits, - and _' using errcode = 'CMA04';
  end if;
  v_t := clock_timestamp();
  select array_agg(row(s.source_row, s.source_id, s.serial, s.model, s.status, s.country, s.warehouse_ref, s.customer_ref, s.subscription_ref,
                       s.order_ref, s.first_shipped_on, s.stock_received_on, s.last_shipped_on, s.warranty_until, s.end_of_life_on,
                       s.components, s.external_refs)::cma.device_load_row order by s.source_row)
    into v_rows
  from cma.device_import_row s where s.tenant_id = v_tenant and s.batch_key = p_batch_key;
  if v_rows is null then
    raise exception 'no staged rows of batch % in the current tenant', p_batch_key using errcode = 'CMA02';
  end if;
  v_stage := round(extract(epoch from clock_timestamp() - v_t) * 1000);
  v_counts := cma.device_rows_apply(p_connection_id, v_rows, p_is_full);
  v_t := clock_timestamp();
  delete from cma.device_import_row s where s.tenant_id = v_tenant and s.batch_key = p_batch_key;
  return v_counts || jsonb_build_object('stage_ms', v_stage, 'cleanup_ms', round(extract(epoch from clock_timestamp() - v_t) * 1000));
end
$$;

-- As 0008zj (114) left it (the permission checked on every row), but the JSON helper, a subtransaction per call, runs
-- only for a value that holds an @; the same values are staged
create or replace function cma.device_import_staging_insert()
returns trigger
language plpgsql
as $$
begin
  perform cma.assert_any_permission(array['tenant.configure', 'ingest.write']);
  insert into cma.device_import_row (tenant_id, batch_key, source_row, source_id, serial, model, status, country, warehouse_ref,
                                     customer_ref, subscription_ref, order_ref, first_shipped_on, stock_received_on, last_shipped_on,
                                     warranty_until, end_of_life_on, components, external_refs)
  values (cma.current_tenant_id(), new.batch_key, new.source_row, cma.device_staged_without_at(new.source_id),
          cma.device_staged_without_at(new.serial), cma.device_staged_without_at(new.model), cma.device_staged_without_at(new.status),
          cma.device_staged_without_at(new.country), cma.device_staged_without_at(new.warehouse_ref),
          cma.device_staged_without_at(new.customer_ref), cma.device_staged_without_at(new.subscription_ref),
          cma.device_staged_without_at(new.order_ref), cma.device_staged_without_at(new.first_shipped_on),
          cma.device_staged_without_at(new.stock_received_on), cma.device_staged_without_at(new.last_shipped_on),
          cma.device_staged_without_at(new.warranty_until), cma.device_staged_without_at(new.end_of_life_on),
          case when strpos(coalesce(new.components, ''), '@') > 0 then cma.device_staged_object_without_at(new.components) else new.components end,
          case when strpos(coalesce(new.external_refs, ''), '@') > 0 then cma.device_staged_object_without_at(new.external_refs) else new.external_refs end);
  return new;
end
$$;
revoke execute on function cma.device_import_staging_insert() from public;

-- ---------------------------------------------------------------------------------------------
-- 4. The ingest's chunks
-- ---------------------------------------------------------------------------------------------
-- One chunk of the rows the ingest read (ingest.write, the tenant's Ingest user; an active asset register connection
-- with a token secret name): 1 to 5,000 rows as a JSON array of objects whose keys are the staging's columns
-- (source_row, a whole number from 2 to 10,000,000; source_id, serial, model, status, country, warehouse_ref,
-- customer_ref, subscription_ref, order_ref, the five dates, components and external_refs, each text), each value
-- within the staging's lengths; another key, or a value longer than the staging takes, refuses the chunk (CMA04). Loaded
-- by the set-based load without marking anything missing, in the caller's transaction. A value holding an @ is kept as
-- a bare @, as the staging keeps it. No staging, so no staged row is written, audited or deleted. Answers the load's
-- counts with stage_ms (reading the chunk)
create or replace function cma.ingest_load_device_chunk(p_connection_id uuid, p_rows jsonb)
returns jsonb
language plpgsql
as $$
declare
  v_rows  cma.device_load_row[];
  v_t     timestamptz;
  v_n     integer;
  v_bad   text;
  v_stage numeric;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  perform cma.assert_assets_connection(p_connection_id);
  if (select c.token_secret_name from cma.integration_connection c
      where c.tenant_id = cma.current_tenant_id() and c.id = p_connection_id) is null then
    raise exception 'connection % has no token secret name: it is loaded from files (cma.load_device_snapshot), not by the ingest', p_connection_id
      using errcode = 'CMA04';
  end if;
  v_t := clock_timestamp();
  v_n := case when jsonb_typeof(p_rows) = 'array' then jsonb_array_length(p_rows) end;
  if v_n is null or v_n not between 1 and 5000
     or exists (select 1 from jsonb_array_elements(p_rows) e where jsonb_typeof(e) <> 'object') then
    raise exception 'a chunk is a JSON array of 1 to 5,000 row objects' using errcode = 'CMA04';
  end if;
  -- the staging's columns only; the line a whole number from 2 to 10,000,000, as the staging takes it
  select string_agg(distinct k, ', ' order by k) into v_bad
  from jsonb_array_elements(p_rows) e, jsonb_object_keys(e) k
  where k not in ('source_row', 'source_id', 'serial', 'model', 'status', 'country', 'warehouse_ref', 'customer_ref', 'subscription_ref',
                  'order_ref', 'first_shipped_on', 'stock_received_on', 'last_shipped_on', 'warranty_until', 'end_of_life_on',
                  'components', 'external_refs');
  if v_bad is not null then
    raise exception 'a chunk''s rows hold the staging''s columns only, not %', left(v_bad, 200) using errcode = 'CMA04';
  end if;
  if exists (select 1 from jsonb_array_elements(p_rows) e
             where jsonb_typeof(e -> 'source_row') <> 'null'
               and (jsonb_typeof(e -> 'source_row') <> 'number' or (e ->> 'source_row') !~ '^\d{1,8}$'
                    or (e ->> 'source_row')::integer not between 2 and 10000000)) then
    raise exception 'a chunk''s source_row is a whole number from 2 to 10,000,000' using errcode = 'CMA04';
  end if;
  select array_agg(row(r.source_row, cma.device_staged_without_at(r.source_id), cma.device_staged_without_at(r.serial),
                       cma.device_staged_without_at(r.model), cma.device_staged_without_at(r.status), cma.device_staged_without_at(r.country),
                       cma.device_staged_without_at(r.warehouse_ref), cma.device_staged_without_at(r.customer_ref),
                       cma.device_staged_without_at(r.subscription_ref), cma.device_staged_without_at(r.order_ref),
                       cma.device_staged_without_at(r.first_shipped_on), cma.device_staged_without_at(r.stock_received_on),
                       cma.device_staged_without_at(r.last_shipped_on), cma.device_staged_without_at(r.warranty_until),
                       cma.device_staged_without_at(r.end_of_life_on),
                       case when strpos(coalesce(r.components, ''), '@') > 0 then cma.device_staged_object_without_at(r.components) else r.components end,
                       case when strpos(coalesce(r.external_refs, ''), '@') > 0 then cma.device_staged_object_without_at(r.external_refs) else r.external_refs end
                      )::cma.device_load_row order by r.source_row)
    into v_rows
  from jsonb_populate_recordset(null::cma.device_load_row, p_rows) r;
  -- the staging's lengths, before anything is read further (the first row by line, its first column)
  select format('line %s: %s is longer than the staging takes', coalesce(r.source_row::text, '?'), x.col) into v_bad
  from unnest(v_rows) r
  cross join lateral (values (1, 'source_id', length(r.source_id) > 500), (2, 'serial', length(r.serial) > 500),
                             (3, 'model', length(r.model) > 500), (4, 'status', length(r.status) > 500),
                             (5, 'country', length(r.country) > 500), (6, 'warehouse_ref', length(r.warehouse_ref) > 500),
                             (7, 'customer_ref', length(r.customer_ref) > 500), (8, 'subscription_ref', length(r.subscription_ref) > 500),
                             (9, 'order_ref', length(r.order_ref) > 500), (10, 'first_shipped_on', length(r.first_shipped_on) > 40),
                             (11, 'stock_received_on', length(r.stock_received_on) > 40), (12, 'last_shipped_on', length(r.last_shipped_on) > 40),
                             (13, 'warranty_until', length(r.warranty_until) > 40), (14, 'end_of_life_on', length(r.end_of_life_on) > 40),
                             (15, 'components', length(r.components) > 4000), (16, 'external_refs', length(r.external_refs) > 4000)) as x(n, col, too_long)
  where x.too_long
  order by r.source_row, x.n
  limit 1;
  if v_bad is not null then
    raise exception '%', v_bad using errcode = 'CMA04';
  end if;
  v_stage := round(extract(epoch from clock_timestamp() - v_t) * 1000);
  return cma.device_rows_apply(p_connection_id, v_rows, false) || jsonb_build_object('stage_ms', v_stage);
end
$$;

-- A full snapshot's final step, one slice at a time (ingest.write; an active asset register connection with a token
-- secret name). The run's record ids, sorted by their bytes (collation "C"), are cut into slices of at most 5,000 (the
-- adapter's assets_load_chunk); each slice is one call and one transaction, with its ids and its range: p_from, its
-- first id (null for the first slice), and p_before, the next slice's first id (null for the last). The connection's
-- devices in that range whose record id is not among the slice's ids are marked missing, by the range index; so the
-- slices together cover every record id once, and each call's work is bounded by its slice, not by the register.
-- Every id and both bounds are read as a chunk's row reads them (a bare @ for an address, then the record id's form).
-- CMA04 without an id, with more than 5,000, with a null or one that is no id among them, with a bound that is no id,
-- with p_from not before p_before, or with an id outside the range (the adapter's sort and the database's differ: nothing
-- is marked). A run that reads nothing, or fails before this step, marks nothing. One load of the connection at a time
-- (the advisory lock of 0008zj). Answers { missing_now, missing_ms }
drop function if exists cma.ingest_mark_devices_missing(uuid, text[]);
create or replace function cma.ingest_mark_devices_missing(p_connection_id uuid, p_source_ids text[], p_from text, p_before text)
returns jsonb
language plpgsql
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_t       timestamptz;
  v_missing integer;
  v_ids     text[];
  v_from    text;
  v_before  text;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  perform cma.assert_assets_connection(p_connection_id);
  if (select c.token_secret_name from cma.integration_connection c where c.tenant_id = v_tenant and c.id = p_connection_id) is null then
    raise exception 'connection % has no token secret name: it is loaded from files (cma.load_device_snapshot), not by the ingest', p_connection_id
      using errcode = 'CMA04';
  end if;
  -- each id read as a chunk's row reads it, so it meets the devices' stored record ids; one that is no id refuses the
  -- call, as it refuses its chunk
  if coalesce(cardinality(p_source_ids), 0) not between 1 and 5000 then
    raise exception 'a slice holds 1 to 5,000 record ids of the run' using errcode = 'CMA04';
  end if;
  v_ids := array(select cma.device_staged_text(cma.device_staged_without_at(x)) from unnest(p_source_ids) x);
  if array_position(v_ids, null) is not null then
    raise exception 'a slice''s record ids are ids (a null or one that is no id among them)' using errcode = 'CMA04';
  end if;
  v_from := cma.device_staged_text(cma.device_staged_without_at(p_from));
  v_before := cma.device_staged_text(cma.device_staged_without_at(p_before));
  if (p_from is not null and v_from is null) or (p_before is not null and v_before is null) or v_from >= v_before collate "C" then
    raise exception 'a slice''s bounds are record ids, its first before the next slice''s first' using errcode = 'CMA04';
  end if;
  if exists (select 1 from unnest(v_ids) x where x < v_from collate "C" or x >= v_before collate "C") then
    raise exception 'a record id lies outside its slice (from % before %): nothing is marked', coalesce(v_from, 'the start'), coalesce(v_before, 'the end')
      using errcode = 'CMA04';
  end if;
  perform pg_advisory_xact_lock(hashtext('cma-device-load'), hashtext(p_connection_id::text));
  v_t := clock_timestamp();
  -- the range as the index's conditions ('' is the least text in byte order; the last slice has no end)
  v_from := coalesce(v_from, '');
  if v_before is null then
    update cma.device d set source_deleted_at = now(), synced_at = now()
    where d.tenant_id = v_tenant and d.connection_id = p_connection_id and d.source_deleted_at is null
      and (d.source_id collate "C") >= v_from
      and d.source_id not in (select x from unnest(v_ids) x);
  else
    update cma.device d set source_deleted_at = now(), synced_at = now()
    where d.tenant_id = v_tenant and d.connection_id = p_connection_id and d.source_deleted_at is null
      and (d.source_id collate "C") >= v_from and (d.source_id collate "C") < v_before
      and d.source_id not in (select x from unnest(v_ids) x);
  end if;
  get diagnostics v_missing = row_count;
  return jsonb_build_object('missing_now', v_missing, 'missing_ms', round(extract(epoch from clock_timestamp() - v_t) * 1000));
end
$$;

-- The components by device: the index of their foreign key to the device. Without it, removing a tenant's devices (a
-- tenant's offboarding; 117's cleanup of its throwaway tenants) checks each device against every component of the tenant
-- (some eight minutes for 50,000 devices locally); with it, one lookup each
create index if not exists device_component_device_idx on cma.device_component (tenant_id, device_id);

-- The slices' range index: a connection's present devices by record id in byte order. Partial (source_deleted_at is
-- null), so only the missing-marking can use it: a record id's lookup by equality (the load's) keeps the unique index on
-- (tenant_id, connection_id, source_id), even while a filling connection has no statistics and both would look as cheap
create index if not exists device_present_source_c_idx on cma.device (tenant_id, connection_id, (source_id collate "C"))
  where source_deleted_at is null;

-- ---------------------------------------------------------------------------------------------
-- 5. Settings: the rows of a chunk
-- ---------------------------------------------------------------------------------------------
-- As 0008zj (114), plus assets_load_chunk: a whole number from 100 to 5,000
create or replace function cma.assets_settings_problem(p_settings jsonb)
returns text
language sql immutable
as $$
  select case
    when p_settings ? 'table_id'
         and (jsonb_typeof(p_settings -> 'table_id') <> 'string' or (p_settings ->> 'table_id') !~ '^[A-Za-z0-9_-]{1,64}$') then 'table_id'
    when p_settings ? 'view_id'
         and (jsonb_typeof(p_settings -> 'view_id') <> 'string' or (p_settings ->> 'view_id') !~ '^[A-Za-z0-9_-]{1,64}$') then 'view_id'
    when p_settings ? 'date_format'
         and (jsonb_typeof(p_settings -> 'date_format') <> 'string' or (p_settings ->> 'date_format') not in ('dmy', 'mdy', 'iso')) then 'date_format'
    when p_settings ? 'assets_poll_interval_minutes'
         and not (jsonb_typeof(p_settings -> 'assets_poll_interval_minutes') in ('number', 'string')
                  and case when (p_settings ->> 'assets_poll_interval_minutes') ~ '^\d{1,4}$'
                           then (p_settings ->> 'assets_poll_interval_minutes')::integer between 1 and 1440 else false end)
      then 'assets_poll_interval_minutes'
    when p_settings ? 'assets_load_chunk'
         and not (jsonb_typeof(p_settings -> 'assets_load_chunk') in ('number', 'string')
                  and case when (p_settings ->> 'assets_load_chunk') ~ '^\d{1,4}$'
                           then (p_settings ->> 'assets_load_chunk')::integer between 100 and 5000 else false end)
      then 'assets_load_chunk'
  end
$$;

-- As 0008zj (114), naming assets_load_chunk among the forms, and refusing view_id on an asset register connection: the
-- asset sync reads the whole table, since a view's filter would make every device outside it look missing to the nightly
-- full snapshot (CMA04). cma.assets_settings_problem still checks a view_id's form, as 0008zj's verify reads it
create or replace function cma.set_connection_settings(p_connection_id uuid, p_settings jsonb)
returns void
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_kind   text;
  v_bad    text;
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  if not cma.connection_settings_ok(coalesce(p_settings, '{}'::jsonb)) then
    raise exception 'settings must be a flat object of at most 4 kB, keys lower case, no key containing secret, token, password or key'
      using errcode = 'CMA04';
  end if;
  select c.kind into v_kind from cma.integration_connection c where c.tenant_id = v_tenant and c.id = p_connection_id;
  if v_kind = 'assets' or (v_kind is null and 'assets' = any (cma.connection_held_kinds_of(v_tenant, p_connection_id))) then
    if coalesce(p_settings, '{}'::jsonb) ? 'view_id' then
      raise exception 'an asset register is read whole: view_id is no setting of it (a view''s filter would make the devices outside it look missing)'
        using errcode = 'CMA04';
    end if;
    v_bad := cma.assets_settings_problem(coalesce(p_settings, '{}'::jsonb));
    if v_bad is not null then
      raise exception 'the setting % is out of its form: table_id is an id, date_format is dmy, mdy or iso, assets_poll_interval_minutes a whole number from 1 to 1440, assets_load_chunk one from 100 to 5,000', v_bad
        using errcode = 'CMA04';
    end if;
  end if;
  update cma.integration_connection c set settings = coalesce(p_settings, '{}'::jsonb)
  where c.tenant_id = v_tenant and c.id = p_connection_id;
end
$$;

-- An asset register connection that holds a view_id from before (0008zj took one) holds it no longer: the ingest reads
-- the whole table whatever the settings say, so the stored settings say the same. Audited as every settings change
update cma.integration_connection c set settings = c.settings - 'view_id'
where c.settings ? 'view_id'
  and (c.kind = 'assets' or (c.kind is null and 'assets' = any (cma.connection_held_kinds_of(c.tenant_id, c.id))));

-- ---------------------------------------------------------------------------------------------
-- 6. A run's counts take the phase times
-- ---------------------------------------------------------------------------------------------
-- As 0008zj (114), plus the load's phase times in milliseconds
create or replace function cma.ingest_sync_run_finish(p_run_id uuid, p_status text, p_counts jsonb, p_error text default null)
returns void
language plpgsql
as $$
declare
  v_status text;
begin
  perform cma.assert_permission('ingest.write');
  if p_status not in ('succeeded', 'failed') then
    raise exception 'status must be succeeded or failed' using errcode = 'CMA04';
  end if;
  if p_counts is not null and (jsonb_typeof(p_counts) <> 'object'
     or exists (select 1 from jsonb_each(p_counts) e
                where e.key not in ('fetched', 'upserted', 'stale', 'skipped', 'failed', 'dropped', 'ref_dropped',
                                    'rows', 'inserted', 'updated', 'unchanged', 'missing_now', 'components_replaced', 'components_closed',
                                    'unmapped_model', 'unmapped_status', 'unmapped_market', 'customer_ref_invalid', 'refs_dropped',
                                    'stage_ms', 'map_ms', 'upsert_ms', 'components_ms', 'missing_ms', 'cleanup_ms', 'chunk_max_ms', 'slice_max_ms',
                                    'chunk_size_min', 'chunk_halvings')
                   or jsonb_typeof(e.value) <> 'number' or (e.value #>> '{}') !~ '^\d+$')) then
    raise exception 'counts are whole numbers for fetched, upserted, stale, skipped, failed, dropped and ref_dropped, a device load''s counts and its phase times'
      using errcode = 'CMA04';
  end if;
  select r.status into v_status from cma.sync_run r where r.tenant_id = cma.current_tenant_id() and r.id = p_run_id for update;
  if v_status is null then
    raise exception 'no sync run % in the current tenant', p_run_id using errcode = 'CMA02';
  end if;
  if v_status <> 'running' then
    raise exception 'sync run % is already finished', p_run_id using errcode = 'CMA03';
  end if;
  update cma.sync_run r
     set status = p_status, finished_at = now(), counts = coalesce(p_counts, '{}'::jsonb), error = left(nullif(btrim(p_error), ''), 200)
   where r.tenant_id = cma.current_tenant_id() and r.id = p_run_id;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. The mapped fields' types
-- ---------------------------------------------------------------------------------------------
-- The type the ingest first read for each mapped property of an asset register connection (ingest.write; an active
-- asset register connection with a token secret name): p_items a JSON array of 1 to 200 objects { property, type },
-- the property as mapped (the source's field id) and its type as the source's schema names it, kept in lower case in
-- connection_field.source_type (checked_at: when it was first read). Only a mapped field without a type takes one: a
-- type that differs from the stored one is the adapter's to refuse before it reads a record (field_type_changed,
-- naming the field), never overwritten here. A field mapped again with another property loses its type (0008zb), so the next run reads it afresh;
-- to accept a changed type for the same property, its mapping is removed and set again in one Run (the removal deletes
-- the field's row, so the type goes with it). Answers how many fields took a type
create or replace function cma.ingest_record_field_types(p_connection_id uuid, p_items jsonb)
returns integer
language plpgsql
as $$
declare
  v_n integer;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  perform cma.assert_assets_connection(p_connection_id);
  if (select c.token_secret_name from cma.integration_connection c
      where c.tenant_id = cma.current_tenant_id() and c.id = p_connection_id) is null then
    raise exception 'connection % has no token secret name: it is loaded from files (cma.load_device_snapshot), not by the ingest', p_connection_id
      using errcode = 'CMA04';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 200
     or exists (select 1 from jsonb_array_elements(p_items) e
                where jsonb_typeof(e) <> 'object' or coalesce(btrim(e ->> 'property'), '') = '' or length(e ->> 'property') > 200
                   or coalesce(lower(e ->> 'type'), '') !~ '^[a-z][a-z0-9_]{0,39}$') then
    raise exception 'field types are a JSON array of 1 to 200 objects, each a mapped property and its type (a letter, then letters, digits or _; at most 40)'
      using errcode = 'CMA04';
  end if;
  update cma.connection_field f set source_type = lower(e.value ->> 'type'), checked_at = now()
  from jsonb_array_elements(p_items) e
  where f.tenant_id = cma.current_tenant_id() and f.connection_id = p_connection_id and f.source_type is null
    and f.source_property = btrim(e.value ->> 'property');
  get diagnostics v_n = row_count;
  return v_n;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 8. The forecast at the register's horizon (50,000 devices)
-- ---------------------------------------------------------------------------------------------
-- 0008zi's forecast (112) walks every due item of the tenant in a PL/pgSQL loop (RETURN NEXT, one row at a time) to
-- bundle the exchanges, and its list looks up each row's names and CRM contact before it cuts the page. At 50,000
-- devices (about 106,000 items) in en_US.UTF-8 the page took 1,567 ms and the list 1,861 ms locally on a db-g1-small's
-- memory settings; made again, 738 and 817 ms.
-- Made again with the same rows and results (113 passes unchanged): the items as one statement, the bundling as a
-- running aggregate over each device's items in the loop's order; the bucketing a plain statement the planner inlines;
-- the list's page cut first, its names and contacts looked up for the page's rows only.

-- One step of the bundling, as 112's loop takes it: an item without an action date leaves the exchange as it is; one
-- whose action date lies beyond the window from the exchange's first action date (or the device's first) starts a new
-- exchange on its own action date
create or replace function cma.maintenance_exchange_step(p_start date, p_action_on date, p_window integer)
returns date
language plpgsql immutable
as $$
begin
  if p_action_on is null then
    return p_start;
  end if;
  if p_start is null or p_action_on > p_start + p_window then
    return p_action_on;
  end if;
  return p_start;
end
$$;

-- The exchange's first action date, as a running aggregate over a device's items in action-date order
create or replace aggregate cma.maintenance_exchange_start(date, integer) (sfunc = cma.maintenance_exchange_step, stype = date);

-- As 0008zi (112), the same rows: the items of every tracked device as one statement, and each item's exchange the
-- running aggregate over its device's items ordered as 112's loop orders them (action date, nulls last, then the kind's
-- order and key)
create or replace function cma.maintenance_items_of(p_tenant_id uuid, p_today date)
returns table (device_id uuid, connection_id uuid, source_id text, serial text, model_key text, market text, device_status_key text,
               is_in_field boolean, is_in_stock boolean, component_key text, component_order integer, due_on date, basis text,
               action_on date, past_due boolean, exchange_key text, exchange_on date)
language sql stable
as $$
  with s as (
    select greatest(coalesce(nullif(cma.setting_of(p_tenant_id, 'assets.bundle_window_days'), '')::integer, 0), 0) as win,
           date_trunc('month', p_today)::date as month,
           (select t.timezone from cma.tenant t where t.id = p_tenant_id) as zone
  ), d as (
    select dv.id, dv.connection_id, dv.source_id, dv.serial, dv.model_key, dv.market, dv.device_status_key, st.is_in_field, st.is_in_stock,
           coalesce(dv.last_shipped_on, dv.first_shipped_on) as anchor, dv.end_of_life_on
    from cma.device dv
    join cma.device_status st on st.tenant_id = dv.tenant_id and st.key = dv.device_status_key and st.is_tracked
    where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null
  ), rp as (
    -- the devices' kinds with a closed component: their current one is a replacement; with none current, the register
    -- emptied the kind, and the item has no anchor (no due date) until the register holds the kind again
    select distinct p.device_id, p.component_key
    from cma.device_component p
    where p.tenant_id = p_tenant_id and p.replaced_at is not null
  ), it as (
    select d.id, d.connection_id, d.source_id, d.serial, d.model_key, d.market, d.device_status_key, d.is_in_field, d.is_in_stock,
           k.key as component_key, k.sort_order as component_order, c.expires_on as recorded,
           case when ru.interval_months is not null and a.anchor is not null
                then (a.anchor + make_interval(months => ru.interval_months))::date end as by_rule,
           coalesce(ru.lead_days, 0) as lead_days
    from d
    cross join s
    join cma.device_component_kind k on k.tenant_id = p_tenant_id and k.status = 'active'
    left join cma.device_component c
      on c.tenant_id = p_tenant_id and c.device_id = d.id and c.component_key = k.key and c.replaced_at is null
    left join rp on rp.device_id = d.id and rp.component_key = k.key
    left join cma.maintenance_rule ru on ru.tenant_id = p_tenant_id and ru.model_key = d.model_key and ru.component_key = k.key
    cross join lateral (select case when rp.device_id is not null then (c.first_seen_at at time zone s.zone)::date
                                    else d.anchor end as anchor) a
    where c.id is not null or rp.device_id is not null or ru.id is not null or d.model_key is null
    union all
    select d.id, d.connection_id, d.source_id, d.serial, d.model_key, d.market, d.device_status_key, d.is_in_field, d.is_in_stock,
           'device', 2147483647, d.end_of_life_on, null::date, 0
    from d
    where d.end_of_life_on is not null
  ), i as (
    select it.*, coalesce(it.recorded, it.by_rule) as due,
           case when it.recorded is not null then 'recorded' when it.by_rule is not null then 'rule' else 'unknown' end as how,
           coalesce(it.recorded, it.by_rule) - it.lead_days as act
    from it
  ), x as (
    select i.*,
           cma.maintenance_exchange_start(i.act, (select s.win from s))
             over (partition by i.id order by i.act nulls last, i.component_order, i.component_key
                   rows between unbounded preceding and current row) as xstart
    from i
  )
  select x.id, x.connection_id, x.source_id, x.serial, x.model_key, x.market, x.device_status_key, x.is_in_field, x.is_in_stock,
         x.component_key, x.component_order, x.due, x.how, x.act, coalesce(x.act < (select s.month from s), false),
         case when x.act is not null then x.id::text || ':' || to_char(x.xstart, 'YYYY-MM-DD') end,
         case when x.act is not null then x.xstart end
  from x
$$;

-- The due items of a horizon after the filters, as cma.maintenance_bucketed_of answers them, but each bucket a date:
-- -infinity for past_due, the first day of the action month within the horizon, null beyond it; the same for the
-- exchange's bucket (from the exchange's first action date). Model and market as the device holds them (null for none).
-- No text is built per item: the page and the list group and sort dates, ids and the device's own values, and write the
-- buckets and the exchange keys as text for the cells and rows they answer only. The horizon's bounds are computed once
-- (sub-selects), a month from a date without a time zone. One plain statement, inlined into them
create or replace function cma.maintenance_bucket_dates_of(p_tenant_id uuid, p_from_month date, p_months integer, p_market text,
                                                           p_model text, p_scope text, p_today date)
returns table (device_id uuid, connection_id uuid, source_id text, serial text, model_key text, market text, device_status_key text,
               component_key text, component_order integer, due_on date, basis text, action_on date, past_due boolean, exchange_key text,
               exchange_on date, bucket_on date, exchange_bucket_on date)
language sql stable
as $$
  select i.device_id, i.connection_id, i.source_id, i.serial, i.model_key, i.market, i.device_status_key, i.component_key, i.component_order,
         i.due_on, i.basis, i.action_on, i.past_due, i.exchange_key, i.exchange_on,
         case when i.past_due then '-infinity'::date
              when i.action_on >= p_from_month and i.action_on < (select (p_from_month + make_interval(months => p_months))::date)
                then date_trunc('month', i.action_on::timestamp)::date end,
         case when i.exchange_on < (select date_trunc('month', p_today::timestamp)::date) then '-infinity'::date
              when i.exchange_on >= p_from_month and i.exchange_on < (select (p_from_month + make_interval(months => p_months))::date)
                then date_trunc('month', i.exchange_on::timestamp)::date end
  from cma.maintenance_items_of(p_tenant_id, p_today) i
  where (p_scope is null or (p_scope = 'field' and i.is_in_field) or (p_scope = 'stock' and i.is_in_stock))
    and (p_market is null or coalesce(i.market, 'unknown') = p_market)
    and (p_model is null or coalesce(i.model_key, 'unknown') = p_model)
$$;

-- As 0008zi (112), the same rows: over cma.maintenance_bucket_dates_of, the buckets written as text (past_due, or the
-- month's first day as YYYY-MM-DD), model and market unknown for none. One plain statement, inlined
create or replace function cma.maintenance_bucketed_of(p_tenant_id uuid, p_from_month date, p_months integer, p_market text, p_model text,
                                                       p_scope text, p_today date)
returns table (device_id uuid, connection_id uuid, source_id text, serial text, model_key text, market text, device_status_key text,
               component_key text, component_order integer, due_on date, basis text, action_on date, past_due boolean, exchange_key text,
               exchange_on date, bucket text, exchange_bucket text)
language sql stable
as $$
  select b.device_id, b.connection_id, b.source_id, b.serial, coalesce(b.model_key, 'unknown'), coalesce(b.market, 'unknown'),
         b.device_status_key, b.component_key, b.component_order, b.due_on, b.basis, b.action_on, b.past_due, b.exchange_key, b.exchange_on,
         case when b.bucket_on = '-infinity' then 'past_due' else to_char(b.bucket_on, 'YYYY-MM-DD') end,
         case when b.exchange_bucket_on = '-infinity' then 'past_due' else to_char(b.exchange_bucket_on, 'YYYY-MM-DD') end
  from cma.maintenance_bucket_dates_of(p_tenant_id, p_from_month, p_months, p_market, p_model, p_scope, p_today) b
$$;

-- As 0008zi (112), the same page: over cma.maintenance_bucket_dates_of, grouped by the buckets as dates; a cell's
-- planned exchanges counted as its distinct devices and first action dates (an exchange key is the two as text), by
-- hashing; the buckets written as text for the cells only
create or replace function cma.maintenance_page_of(p_tenant_id uuid, p_from_month date, p_months integer, p_market text, p_model text,
                                                   p_scope text, p_today date)
returns jsonb
language sql stable
as $$
  with b as materialized (
    select x.device_id, coalesce(x.market, 'unknown') as market, coalesce(x.model_key, 'unknown') as model_key, x.component_key, x.basis,
           x.exchange_on, x.bucket_on, x.exchange_bucket_on
    from cma.maintenance_bucket_dates_of(p_tenant_id, p_from_month, p_months, p_market, p_model, p_scope, p_today) x
  ), comp as (
    select x.bucket_on, x.market, x.model_key, jsonb_object_agg(x.component_key, x.n) as components, sum(x.n)::integer as component_items
    from (select bucket_on, market, model_key, component_key, count(*)::integer as n
          from b where bucket_on is not null and component_key <> 'device' group by 1, 2, 3, 4) x
    group by 1, 2, 3
  ), eol as (
    select bucket_on, market, model_key, count(*)::integer as n from b where bucket_on is not null and component_key = 'device' group by 1, 2, 3
  ), exch as (
    select x.bucket_on, x.market, x.model_key, count(*)::integer as n
    from (select distinct exchange_bucket_on as bucket_on, market, model_key, device_id, exchange_on from b where exchange_bucket_on is not null) x
    group by 1, 2, 3
  ), cells as (
    select k.bucket_on, k.market, k.model_key, coalesce(c.components, '{}'::jsonb) as components, coalesce(c.component_items, 0) as component_items,
           coalesce(e.n, 0) as end_of_life, coalesce(x.n, 0) as exchanges
    from (select bucket_on, market, model_key from comp union select bucket_on, market, model_key from eol
          union select bucket_on, market, model_key from exch) k
    left join comp c on c.bucket_on = k.bucket_on and c.market = k.market and c.model_key = k.model_key
    left join eol e on e.bucket_on = k.bucket_on and e.market = k.market and e.model_key = k.model_key
    left join exch x on x.bucket_on = k.bucket_on and x.market = k.market and x.model_key = k.model_key
  ), unk as (
    select x.market, x.model_key, jsonb_object_agg(x.component_key, x.n) as components, sum(x.n)::integer as items
    from (select market, model_key, component_key, count(*)::integer as n from b where basis = 'unknown' group by 1, 2, 3) x
    group by 1, 2
  ), tracked as (
    select coalesce(dv.market, 'unknown') as market, coalesce(dv.model_key, 'unknown') as model_key, st.is_in_field, st.is_in_stock
    from cma.device dv
    join cma.device_status st on st.tenant_id = dv.tenant_id and st.key = dv.device_status_key and st.is_tracked
    where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null
  ), mk as (
    select m.code, m.sort_order from cma.market m where m.tenant_id = p_tenant_id
  ), md as (
    select m.key, m.name, m.sort_order from cma.device_model m where m.tenant_id = p_tenant_id
  )
  select jsonb_build_object(
    'from_month', p_from_month, 'months', p_months, 'current_month', date_trunc('month', p_today)::date,
    'bundle_window_days', greatest(coalesce(nullif(cma.setting_of(p_tenant_id, 'assets.bundle_window_days'), '')::integer, 0), 0),
    'is_set_up', cma.assets_set_up_of(p_tenant_id),
    'buckets', (select jsonb_agg(x.k order by x.o)
                from (select 'past_due' as k, 0 as o
                      union all
                      select to_char((p_from_month + make_interval(months => g))::date, 'YYYY-MM-DD'), g + 1
                      from generate_series(0, p_months - 1) g) x),
    'component_kinds', (select coalesce(jsonb_agg(jsonb_build_object('key', k.key, 'name', k.name) order by k.sort_order, k.key), '[]'::jsonb)
                        from cma.device_component_kind k where k.tenant_id = p_tenant_id and k.status = 'active'),
    'cells', (select coalesce(jsonb_agg(jsonb_build_object('bucket', case when c.bucket_on = '-infinity' then 'past_due' else to_char(c.bucket_on, 'YYYY-MM-DD') end,
                                                           'market', c.market, 'model', c.model_key,
                                                           'components', c.components, 'component_items', c.component_items,
                                                           'end_of_life', c.end_of_life, 'exchanges', c.exchanges)
                                        order by c.bucket_on, (c.market = 'unknown'), mk.sort_order, c.market,
                                                 (c.model_key = 'unknown'), md.sort_order, c.model_key), '[]'::jsonb)
              from cells c left join mk on mk.code = c.market left join md on md.key = c.model_key),
    'unknown', (select coalesce(jsonb_agg(jsonb_build_object('market', u.market, 'model', u.model_key, 'components', u.components, 'items', u.items)
                                          order by (u.market = 'unknown'), mk.sort_order, u.market, (u.model_key = 'unknown'), md.sort_order, u.model_key), '[]'::jsonb)
                from unk u left join mk on mk.code = u.market left join md on md.key = u.model_key),
    'unknown_items', (select count(*) from b where basis = 'unknown'),
    'devices', (select count(*) from tracked t
                where (p_scope is null or (p_scope = 'field' and t.is_in_field) or (p_scope = 'stock' and t.is_in_stock))
                  and (p_market is null or t.market = p_market) and (p_model is null or t.model_key = p_model)),
    'filter_markets', (select coalesce(jsonb_agg(f.market order by (f.market = 'unknown'), mk.sort_order, f.market), '[]'::jsonb)
                       from (select distinct t.market from tracked t) f left join mk on mk.code = f.market),
    'filter_models', (select coalesce(jsonb_agg(jsonb_build_object('key', f.model_key, 'name', md.name)
                                                order by (f.model_key = 'unknown'), md.sort_order, f.model_key), '[]'::jsonb)
                      from (select distinct t.model_key from tracked t) f left join md on md.key = f.model_key))
$$;

-- As 0008zi (112), the same rows in the same order: over cma.maintenance_bucket_dates_of, each row's bucket a date
-- (infinity for unknown), grouped by device, bucket and exchange (its first action date) with the device's values the
-- order needs; the page of rows cut first; then the bucket written as text, the device's references, the model's and
-- status's names and the CRM contact for the page's rows only. The order's last key, 0008zi's exchange key as text (the
-- device id, then the date), is the device id and the exchange's first action date
create or replace function cma.maintenance_rows_of(p_tenant_id uuid, p_from_month date, p_months integer, p_bucket text, p_market text,
                                                   p_model text, p_scope text, p_view text, p_limit integer, p_today date)
returns table (bucket text, device_id uuid, connection_id uuid, source_id text, serial text, model_key text, model_name text, market text,
               device_status_key text, device_status_name text, components text[], due_on date, bases text[], action_on date,
               exchange_on date, customer_ref text, subscription_ref text, crm_connection_id uuid, crm_contact_source_id text,
               total_rows bigint)
language sql stable
as $$
  with b as (
    select x.device_id, x.connection_id, x.source_id, x.serial, x.model_key, x.market, x.device_status_key, x.component_key, x.component_order,
           x.due_on, x.basis, x.action_on, x.exchange_on,
           case when x.basis = 'unknown' then 'infinity'::date when p_view = 'exchanges' then x.exchange_bucket_on else x.bucket_on end as rb
    from cma.maintenance_bucket_dates_of(p_tenant_id, p_from_month, p_months, p_market, p_model, p_scope, p_today) x
  ), g as (
    select b.device_id, b.rb, case when p_view = 'exchanges' and b.rb <> 'infinity' then b.exchange_on end as grp_on,
           b.connection_id, b.source_id, b.serial, b.model_key, b.market, b.device_status_key,
           array_agg(b.component_key order by b.component_order, b.component_key) as components,
           min(b.due_on) as due_on,
           -- the distinct bases in order (recorded, rule, unknown), as array_agg(distinct basis order by basis) gives them
           array_remove(array[case when bool_or(b.basis = 'recorded') then 'recorded' end, case when bool_or(b.basis = 'rule') then 'rule' end,
                              case when bool_or(b.basis = 'unknown') then 'unknown' end], null) as bases,
           min(b.action_on) as action_on, min(b.exchange_on) as exchange_on
    from b
    where case when p_bucket = 'unknown' then b.rb = 'infinity'
               when p_bucket = 'all' then b.rb is not null and b.rb <> 'infinity'
               when p_bucket = 'past_due' then b.rb = '-infinity'
               else b.rb = case when p_bucket ~ '^\d{4}-\d{2}-\d{2}$' and pg_input_is_valid(p_bucket, 'date') then p_bucket::date end end
    group by b.device_id, b.rb, 3, b.connection_id, b.source_id, b.serial, b.model_key, b.market, b.device_status_key
  ), r as (
    select g.*, count(*) over () as total_rows
    from g
    order by g.action_on nulls last, coalesce(g.market, 'unknown') = 'unknown', g.market, g.model_key, g.serial nulls last, g.source_id,
             case when g.grp_on is not null then g.device_id end, g.grp_on
    limit p_limit
  )
  select case r.rb when 'infinity' then 'unknown' when '-infinity' then 'past_due' else to_char(r.rb, 'YYYY-MM-DD') end, r.device_id,
         r.connection_id, r.source_id, r.serial, coalesce(r.model_key, 'unknown'), md.name, coalesce(r.market, 'unknown'), r.device_status_key,
         st.name, r.components, r.due_on, r.bases, r.action_on, r.exchange_on, dv.customer_ref, dv.subscription_ref, ct.crm_connection_id,
         ct.crm_contact_source_id, r.total_rows
  from r
  join cma.device dv on dv.tenant_id = p_tenant_id and dv.id = r.device_id
  left join cma.device_model md on md.tenant_id = p_tenant_id and md.key = r.model_key
  left join cma.device_status st on st.tenant_id = p_tenant_id and st.key = r.device_status_key
  left join lateral (
    select case when count(distinct (cu.crm_connection_id, cu.crm_contact_source_id)) = 1 then (array_agg(cu.crm_connection_id))[1] end as crm_connection_id,
           case when count(distinct (cu.crm_connection_id, cu.crm_contact_source_id)) = 1 then (array_agg(cu.crm_contact_source_id))[1] end as crm_contact_source_id
    from cma.commerce_customer cu
    where cu.tenant_id = p_tenant_id and dv.customer_ref is not null and cu.source_id = dv.customer_ref
      and cu.source_deleted_at is null and cu.crm_contact_source_id is not null
  ) ct on true
  order by r.action_on nulls last, coalesce(r.market, 'unknown') = 'unknown', r.market, r.model_key, r.serial nulls last, r.source_id,
           case when r.grp_on is not null then r.device_id end, r.grp_on
$$;

-- ---------------------------------------------------------------------------------------------
-- 9. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.device_staged_json(text)',
    'cma.device_staged_date_ok(text)',
    'cma.device_rows_apply(uuid,cma.device_load_row[],boolean)',
    'cma.device_snapshot_apply(text,uuid,boolean)',
    'cma.ingest_load_device_chunk(uuid,jsonb)',
    'cma.ingest_mark_devices_missing(uuid,text[],text,text)',
    'cma.assets_settings_problem(jsonb)',
    'cma.set_connection_settings(uuid,jsonb)',
    'cma.ingest_sync_run_finish(uuid,text,jsonb,text)',
    'cma.ingest_record_field_types(uuid,jsonb)',
    'cma.maintenance_exchange_step(date,date,integer)',
    'cma.maintenance_exchange_start(date,integer)',
    'cma.maintenance_items_of(uuid,date)',
    'cma.maintenance_bucket_dates_of(uuid,date,integer,text,text,text,date)',
    'cma.maintenance_bucketed_of(uuid,date,integer,text,text,text,date)',
    'cma.maintenance_page_of(uuid,date,integer,text,text,text,date)',
    'cma.maintenance_rows_of(uuid,date,integer,text,text,text,text,text,integer,date)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 10. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008zk', 'Asset sync load: the device load set-based (cma.device_rows_apply over the types cma.device_load_row, cma.device_load_mapped and cma.device_load_component; each row''s device and components looked up by index, updates by id; no per-row loop, row lock or subtransaction; the phase times map_ms, upsert_ms, components_ms, missing_ms), 0008zi''s results unchanged, and a kind staged empty closes its current component with no new row (components_closed; its item due unknown); cma.device_snapshot_apply made again over it (stage_ms, cleanup_ms); cma.device_staged_ref with * for {0,99} (the same result); the staging trigger calls the JSON helper only for a value with an @; the ingest''s chunks cma.ingest_load_device_chunk (1 to 5,000 rows, the staging''s columns and lengths, no staging) and the final step in slices cma.ingest_mark_devices_missing(connection, ids, from, before) over the index device_present_source_c_idx; cma.ingest_record_field_types; the setting assets_load_chunk (100 to 5,000), view_id refused on an asset register; cma.ingest_sync_run_finish takes the phase times, components_closed, chunk_max_ms, slice_max_ms, chunk_size_min and chunk_halvings; the forecast made again for 50,000 devices with 0008zi''s results (cma.maintenance_bucket_dates_of, the aggregate cma.maintenance_exchange_start), a kind with a closed component and none current due unknown')
on conflict (version) do nothing;

commit;
reset role;
