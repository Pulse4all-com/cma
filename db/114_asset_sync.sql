-- =============================================================================================
-- 114_asset_sync.sql: addition 0008zj, the asset register read through its API on a schedule
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after 112_assets.sql (0008zi).
-- Rerunnable, forward-only, in one transaction. Run as your own IAM login: dev first, then 115_verify_asset_sync.sql,
-- then 113_verify_assets.sql again (the load it proves is now the shared one); then prod, with 115 and 113. The web and
-- the ingest of main read nothing this adds; the ingest of this change needs it (the job assets_poll, the run's counts,
-- cma.ingest_load_device_snapshot), so in prod the script runs before that ingest is deployed.
--
-- Why (Decision log, 27 October 2026): the asset register (for Pulse4all Subscriptions an Airtable base) is read by
-- the ingest service on a schedule: the records changed since the last run every assets_poll_interval_minutes (default
-- 15), a full snapshot nightly. Polling, not webhooks. Read only: nothing is written to the register. The register still
-- owns its devices and the CMA mirrors them; the CSV import of 0008zi stays as the fallback. The rows the adapter reads
-- take 0008zi's path: staged under a batch key in cma.device_import_staging, then loaded by the same logic
-- cma.load_device_snapshot uses, so the rules for ids, an @ and dropped references are the database's, as before.
-- Tables, the report and the data-quality checks are unchanged.
--
-- What it adds
--   runs           sync_run.job gains assets_poll (the poll; the nightly full snapshot is a reconcile run, a read on
--                  demand a backfill run); cma.ingest_sync_run_finish() takes the load's counts besides fetched and the
--                  rest: rows, inserted, updated, unchanged, missing_now, components_replaced, unmapped_model,
--                  unmapped_status, unmapped_market, customer_ref_invalid, refs_dropped
--   mapping        the register's fields as configuration (cma.set_connection_field on the asset register connection,
--                  instead of the import's map file): entity device for a staging column (serial, model, status,
--                  country, warehouse_ref, customer_ref, subscription_ref, order_ref, the five dates), entity
--                  device_component with the component kind as ref_system for its serial and expires_on, entity device
--                  with field ref and the id's name as ref_system for a named id; slot 1 only. A trigger keeps device
--                  fields on asset register connections and other fields off them, and a component's kind in the
--                  tenant's catalog (CMA04). cma.connection_held_kinds_of() counts device fields as assets
--   settings       cma.set_connection_settings() checks an asset register connection's own settings (CMA04): table_id
--                  and view_id ids, date_format dmy, mdy or iso, assets_poll_interval_minutes a whole number from 1 to
--                  1440. The adapter's own settings (its pace) are the adapter's, as for every other adapter
--   staging        cma.device_import_staging takes rows from a holder of tenant.configure (a person) or of ingest.write
--                  (the tenant's Ingest user); a value with an @ is still kept as a bare @
--   the load       cma.device_snapshot_apply(batch, connection, is_full): 0008zi's load, moved here unchanged but for
--                  the run and the permission (tenant.configure or ingest.write), one load per connection at a time
--                  (a transaction-level advisory lock), and the missing devices of a full snapshot found in linear time
--                  (a hashed set; 0008zi's nested loop took some 40 seconds for 10,000 records). cma.load_device_snapshot (tenant.configure) calls it and keeps
--                  its run of job assets_import; cma.ingest_load_device_snapshot(connection, batch, is_full)
--                  (ingest.write) calls it for a connection with a token secret name only (a connection without one is
--                  loaded from files: CMA04), and the job's own run records it
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
  if not exists (select 1 from cma.schema_migration where version = '0008zi') then
    raise exception 'addition 0008zi (112_assets.sql) must run before 0008zj';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. sync_run: the poll's job, and the load's counts
-- ---------------------------------------------------------------------------------------------
alter table cma.sync_run drop constraint if exists sync_run_job_check;
alter table cma.sync_run add constraint sync_run_job_check
  check (job in ('backfill', 'reconcile', 'forms_poll', 'subscriptions_check', 'link_calls', 'email_poll', 'close_forgotten_workdays',
                 'refresh_follow_up', 'reviews_poll', 'legacy_call_import', 'assets_import', 'assets_poll')) not valid;
alter table cma.sync_run validate constraint sync_run_job_check;

-- As 0008zf (106) left it, plus the device load's counts among the whole-number counts
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
                                    'rows', 'inserted', 'updated', 'unchanged', 'missing_now', 'components_replaced', 'unmapped_model',
                                    'unmapped_status', 'unmapped_market', 'customer_ref_invalid', 'refs_dropped')
                   or jsonb_typeof(e.value) <> 'number' or (e.value #>> '{}') !~ '^\d+$')) then
    raise exception 'counts are whole numbers for fetched, upserted, stale, skipped, failed, dropped and ref_dropped, and a device load''s counts'
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
-- 2. The register's fields as configuration
-- ---------------------------------------------------------------------------------------------
-- The canonical fields of a device (the staging columns but the record id, which is the source's own record id) and of
-- a component (its serial and expiry, per kind); a named id is the field ref with its name as ref_system, a component's
-- kind is its ref_system; one property each (slot 1)
alter table cma.connection_field drop constraint if exists connection_field_field_check;
alter table cma.connection_field add constraint connection_field_field_check
  check (field = any (array['market', 'language', 'country', 'currency', 'store', 'amount', 'source_channel', 'category', 'ref', 'created_at',
                            'reason', 'serial', 'model', 'status', 'warehouse_ref', 'customer_ref', 'subscription_ref', 'order_ref',
                            'first_shipped_on', 'stock_received_on', 'last_shipped_on', 'warranty_until', 'end_of_life_on', 'expires_on']));
alter table cma.connection_field drop constraint if exists connection_field_entity_field_check;
alter table cma.connection_field add constraint connection_field_entity_field_check
  check (case when entity = 'contact' then field = any (array['country', 'language', 'currency', 'store', 'ref', 'created_at'])
              when entity = 'device' then field = any (array['serial', 'model', 'status', 'country', 'warehouse_ref', 'customer_ref',
                                                             'subscription_ref', 'order_ref', 'first_shipped_on', 'stock_received_on',
                                                             'last_shipped_on', 'warranty_until', 'end_of_life_on', 'ref'])
              when entity = 'device_component' then field = any (array['serial', 'expires_on'])
              when field = 'reason' then entity in ('deal', 'ticket')
              else field = any (array['market', 'language', 'currency', 'amount', 'source_channel', 'category']) end);
alter table cma.connection_field drop constraint if exists connection_field_check;
alter table cma.connection_field add constraint connection_field_check
  check ((field = 'ref' or entity = 'device_component') = (ref_system <> ''));
alter table cma.connection_field drop constraint if exists connection_field_slot_check;
alter table cma.connection_field add constraint connection_field_slot_check
  check (slot between 1 and 9
         and (slot = 1 or field = 'ref' or (entity = 'contact' and field in ('country', 'created_at')))
         and (field <> 'created_at' or slot >= 2)
         and (entity not in ('device', 'device_component') or slot = 1));
comment on column cma.connection_field.ref_system is
  'For the field ref, the system (or, on an asset register connection, the name) whose ids the property holds; for a device_component field, the component kind (0008zj); empty otherwise';

-- Device fields only on an asset register connection (its kind assets, or none yet while it holds nothing else), no
-- other field on one, and a component's kind in the tenant's catalog; CMA04 otherwise. A trigger function: it runs
-- whoever writes the row, so nobody gets execute on it
create or replace function cma.check_connection_field_kind()
returns trigger
language plpgsql
as $$
declare
  v_kind text;
  v_held text[];
begin
  select c.kind into v_kind from cma.integration_connection c where c.tenant_id = new.tenant_id and c.id = new.connection_id;
  v_held := cma.connection_held_kinds_of(new.tenant_id, new.connection_id);
  if new.entity in ('device', 'device_component') then
    if (v_kind is not null and v_kind <> 'assets') or (v_kind is null and not (v_held <@ array['assets'])) then
      raise exception 'connection % is not an asset register connection: it maps no % field', new.connection_id, new.entity
        using errcode = 'CMA04';
    end if;
    if new.entity = 'device_component'
       and not exists (select 1 from cma.device_component_kind k where k.tenant_id = new.tenant_id and k.key = new.ref_system) then
      raise exception 'no component kind % in the catalog', new.ref_system using errcode = 'CMA04';
    end if;
  elsif v_kind = 'assets' or 'assets' = any (v_held) then
    raise exception 'connection % is an asset register connection: it maps device and device_component fields only', new.connection_id
      using errcode = 'CMA04';
  end if;
  return new;
end
$$;
revoke execute on function cma.check_connection_field_kind() from public;
create or replace trigger check_kind before insert or update of tenant_id, connection_id, entity, field, ref_system on cma.connection_field
  for each row execute function cma.check_connection_field_kind();

-- As 0008zi (112), with a connection's device fields counted as assets, not crm
create or replace function cma.connection_held_kinds_of(p_tenant_id uuid, p_connection_id uuid)
returns text[]
language sql stable
as $$
  select array_remove(array[
    case when exists (select 1 from cma.crm_record x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.crm_contact x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.crm_call x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_pipeline x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_form x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_call_outcome x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_field x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id
                        and x.entity not in ('device', 'device_component'))
           or exists (select 1 from cma.writeback_field x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_inbox x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_inbox_channel x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_email_rule x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.email_message x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.email_thread x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.crm_task x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_task_status x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_task_type x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
         then 'crm' end,
    case when exists (select 1 from cma.telephony_call x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.telephony_tag x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.telephony_number x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
         then 'telephony' end,
    case when exists (select 1 from cma.commerce_store x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.commerce_customer x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.commerce_order x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
         then 'commerce' end,
    case when exists (select 1 from cma.review_channel x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.review x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
         then 'reviews' end,
    case when exists (select 1 from cma.device x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_field x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id
                        and x.entity in ('device', 'device_component'))
         then 'assets' end], null)
$$;


-- ---------------------------------------------------------------------------------------------
-- 3. An asset register connection's settings
-- ---------------------------------------------------------------------------------------------
-- The first of an asset register connection's own settings that is out of its form, or null: table_id and view_id an
-- id of 1 to 64 letters, digits, _ or -; date_format dmy, mdy or iso; assets_poll_interval_minutes a whole number from 1
-- to 1440 (a number or its digits as text). Each is optional here: the adapter fails a run without table_id
-- (table_id_not_set), and without date_format a run whose mapped date arrives as text (date_format_not_set)
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
  end
$$;

-- As 0007 (32) left it, plus the asset register's own settings checked on a connection of kind assets (or one that
-- holds devices or device fields)
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
    v_bad := cma.assets_settings_problem(coalesce(p_settings, '{}'::jsonb));
    if v_bad is not null then
      raise exception 'the setting % is out of its form: table_id and view_id are ids, date_format is dmy, mdy or iso, assets_poll_interval_minutes a whole number from 1 to 1440', v_bad
        using errcode = 'CMA04';
    end if;
  end if;
  update cma.integration_connection c set settings = coalesce(p_settings, '{}'::jsonb)
  where c.tenant_id = v_tenant and c.id = p_connection_id;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. The staging takes the Ingest user's rows
-- ---------------------------------------------------------------------------------------------
-- As 0008zi (112), with ingest.write next to tenant.configure: the tenant's Ingest user stages the rows it read, a
-- person the rows of a file. Every value with an @ is kept as a bare @, as before
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
          cma.device_staged_object_without_at(new.components), cma.device_staged_object_without_at(new.external_refs));
  return new;
end
$$;
revoke execute on function cma.device_import_staging_insert() from public;

-- ---------------------------------------------------------------------------------------------
-- 5. The load, shared by the file import and the ingest
-- ---------------------------------------------------------------------------------------------
-- 0008zi's load (112, cma.load_device_snapshot) moved here unchanged, but for four things: it starts no run (its
-- callers record one), it takes a holder of tenant.configure or ingest.write, it takes a transaction-level advisory
-- lock per connection, so two loads of one connection (the poll and the nightly full snapshot) never interleave, and a
-- full snapshot finds its missing devices through a hashed set of the batch's record ids (the same devices, in linear
-- time: the nightly snapshot runs under the ingest's statement timeout).
--   checks    the batch has rows (CMA02); every row has a record id and no id appears twice; every date is YYYY-MM-DD;
--             components and external_refs are JSON objects; every component kind is in the catalog, each with only
--             serial and expires_on (all CMA04, naming the staged line)
--   devices   per row: model, status and market mapped (the catalogs' aliases, cma.market_code_of), each null when
--             unmapped; the references kept only when they are ids (the customer reference only when it matches
--             ^[A-Za-z0-9_-]{1,100}$, else customer_ref_invalid); raw the row as mapped. A new record is inserted; a
--             known one is updated when anything differs (and comes back when it was missing), else unchanged
--   components per staged kind with a serial or an expiry: none current, inserted; a current one whose serial differs
--             from the staged serial (both present), replaced (replaced_at now, the new one inserted); otherwise the
--             current one takes the staged serial and expiry. A kind the row does not stage is left as it is
--   a full    snapshot (p_is_full) marks the connection's devices it does not hold with source_deleted_at
--   the batch's staged rows are deleted
-- Answers the counts: rows, inserted, updated, unchanged, missing_now, components_replaced, unmapped_model,
-- unmapped_status, unmapped_market, customer_ref_invalid and refs_dropped (a reference, serial or named id that is no
-- id, left out)
create or replace function cma.device_snapshot_apply(p_batch_key text, p_connection_id uuid, p_is_full boolean)
returns jsonb
language plpgsql
as $$
declare
  v_tenant   uuid := cma.current_tenant_id();
  v_system   text;
  v_bad      text;
  r          record;
  c          record;
  v_old      cma.device;
  v_cur      cma.device_component;
  v_id       uuid;
  v_serial   text;
  v_model    text;
  v_status   text;
  v_market   text;
  v_wh       text;
  v_cust     text;
  v_cust_bad boolean;
  v_sub      text;
  v_ord      text;
  v_first    date;
  v_recv     date;
  v_last     date;
  v_warr     date;
  v_eol      date;
  v_comp_in  jsonb;
  v_comp     jsonb;
  v_refs_in  jsonb;
  v_refs     jsonb;
  v_raw      jsonb;
  v_cs       text;
  v_ce       date;
  v_changed  boolean;
  v_n        integer;
  v_rows     integer := 0;
  v_ins      integer := 0;
  v_upd      integer := 0;
  v_same     integer := 0;
  v_missing  integer := 0;
  v_repl     integer := 0;
  v_um       integer := 0;
  v_us       integer := 0;
  v_uk       integer := 0;
  v_ucr      integer := 0;
  v_drop     integer := 0;
  v_counts   jsonb;
begin
  perform cma.assert_any_permission(array['tenant.configure', 'ingest.write']);
  v_system := cma.active_connection_adapter(p_connection_id);
  perform cma.assert_assets_connection(p_connection_id);
  -- one load of a connection at a time: the poll and the nightly full snapshot may meet
  perform pg_advisory_xact_lock(hashtext('cma-device-load'), hashtext(p_connection_id::text));
  if p_is_full is null then
    raise exception 'is_full must be true (a full snapshot) or false (a partial one)' using errcode = 'CMA04';
  end if;
  if coalesce(p_batch_key, '') !~ '^[a-z0-9_-]{1,64}$' then
    raise exception 'a batch key is 1 to 64 lower-case letters, digits, - and _' using errcode = 'CMA04';
  end if;
  if not exists (select 1 from cma.device_import_row s where s.tenant_id = v_tenant and s.batch_key = p_batch_key) then
    raise exception 'no staged rows of batch % in the current tenant', p_batch_key using errcode = 'CMA02';
  end if;

  -- the checks, before anything is written
  select string_agg(coalesce(s.source_row::text, '?'), ', ' order by s.source_row) into v_bad
  from (select s.source_row from cma.device_import_row s
        where s.tenant_id = v_tenant and s.batch_key = p_batch_key and cma.device_staged_text(s.source_id) is null
        order by s.source_row limit 20) s;
  if v_bad is not null then
    raise exception 'lines %: no record id (or one that is no id)', v_bad using errcode = 'CMA04';
  end if;
  select string_agg(x.sid || ' (lines ' || x.lines || ')', '; ' order by x.sid) into v_bad
  from (select cma.device_staged_text(s.source_id) as sid, string_agg(coalesce(s.source_row::text, '?'), ', ' order by s.source_row) as lines
        from cma.device_import_row s
        where s.tenant_id = v_tenant and s.batch_key = p_batch_key
        group by 1 having count(*) > 1
        order by 1 limit 20) x;
  if v_bad is not null then
    raise exception 'a record id appears twice: %', v_bad using errcode = 'CMA04';
  end if;
  for r in select s.* from cma.device_import_row s where s.tenant_id = v_tenant and s.batch_key = p_batch_key order by s.source_row loop
    v_comp_in := cma.device_staged_object(r.components, r.source_row, 'components');
    perform cma.device_staged_object(r.external_refs, r.source_row, 'external_refs');
    perform cma.device_staged_date(r.first_shipped_on, r.source_row, 'first_shipped_on'),
            cma.device_staged_date(r.stock_received_on, r.source_row, 'stock_received_on'),
            cma.device_staged_date(r.last_shipped_on, r.source_row, 'last_shipped_on'),
            cma.device_staged_date(r.warranty_until, r.source_row, 'warranty_until'),
            cma.device_staged_date(r.end_of_life_on, r.source_row, 'end_of_life_on');
    for c in select e.key, e.value from jsonb_each(v_comp_in) e loop
      if not exists (select 1 from cma.device_component_kind k where k.tenant_id = v_tenant and k.key = c.key) then
        raise exception 'line %: no component kind %', coalesce(r.source_row::text, '?'), c.key using errcode = 'CMA04';
      end if;
      if jsonb_typeof(c.value) <> 'object'
         or exists (select 1 from jsonb_each(c.value) f where f.key not in ('serial', 'expires_on') or jsonb_typeof(f.value) not in ('string', 'null')) then
        raise exception 'line %: component % holds serial and expires_on only, as text', coalesce(r.source_row::text, '?'), c.key using errcode = 'CMA04';
      end if;
      perform cma.device_staged_date(c.value ->> 'expires_on', r.source_row, c.key || '.expires_on');
    end loop;
  end loop;

  for r in select s.* from cma.device_import_row s where s.tenant_id = v_tenant and s.batch_key = p_batch_key order by s.source_row loop
    v_rows := v_rows + 1;
    v_serial := cma.device_staged_ref(r.serial);
    v_model := cma.device_model_key_of(v_tenant, r.model);
    v_status := cma.device_status_key_of(v_tenant, r.status);
    v_market := cma.market_code_of(v_tenant, cma.device_staged_text(r.country));
    v_wh := cma.device_staged_ref(r.warehouse_ref);
    v_cust := case when btrim(coalesce(r.customer_ref, '')) ~ '^[A-Za-z0-9_-]{1,100}$' then btrim(r.customer_ref) end;
    v_cust_bad := v_cust is null and nullif(btrim(coalesce(r.customer_ref, '')), '') is not null;
    v_sub := cma.device_staged_ref(r.subscription_ref);
    v_ord := cma.device_staged_ref(r.order_ref);
    v_first := cma.device_staged_date(r.first_shipped_on, r.source_row, 'first_shipped_on');
    v_recv := cma.device_staged_date(r.stock_received_on, r.source_row, 'stock_received_on');
    v_last := cma.device_staged_date(r.last_shipped_on, r.source_row, 'last_shipped_on');
    v_warr := cma.device_staged_date(r.warranty_until, r.source_row, 'warranty_until');
    v_eol := cma.device_staged_date(r.end_of_life_on, r.source_row, 'end_of_life_on');
    v_drop := v_drop + (case when nullif(btrim(coalesce(r.serial, '')), '') is not null and v_serial is null then 1 else 0 end)
                     + (case when nullif(btrim(coalesce(r.warehouse_ref, '')), '') is not null and v_wh is null then 1 else 0 end)
                     + (case when nullif(btrim(coalesce(r.subscription_ref, '')), '') is not null and v_sub is null then 1 else 0 end)
                     + (case when nullif(btrim(coalesce(r.order_ref, '')), '') is not null and v_ord is null then 1 else 0 end);
    -- the named ids: an id kept under its name, anything else dropped and counted
    v_refs_in := cma.device_staged_object(r.external_refs, r.source_row, 'external_refs');
    select coalesce(jsonb_object_agg(e.key, cma.device_staged_ref(e.value #>> '{}')) filter (where cma.device_staged_ref(e.value #>> '{}') ~ '^[A-Za-z0-9#][A-Za-z0-9_.#:/-]{0,99}$'), '{}'::jsonb),
           count(*) filter (where nullif(btrim(coalesce(e.value #>> '{}', '')), '') is not null
                              and not coalesce(cma.device_staged_ref(e.value #>> '{}') ~ '^[A-Za-z0-9#][A-Za-z0-9_.#:/-]{0,99}$', false))
      into v_refs, v_n
    from jsonb_each(v_refs_in) e
    where e.key ~ '^[a-z][a-z0-9_]{0,39}$';
    v_drop := v_drop + coalesce(v_n, 0)
              + (select count(*)::integer from jsonb_object_keys(v_refs_in) k where k !~ '^[a-z][a-z0-9_]{0,39}$');
    -- the components as mapped: each kind's serial (an id, else dropped and counted) and expiry
    v_comp_in := cma.device_staged_object(r.components, r.source_row, 'components');
    select coalesce(jsonb_object_agg(e.key, jsonb_strip_nulls(jsonb_build_object(
                      'serial', cma.device_staged_ref(e.value ->> 'serial'),
                      'expires_on', cma.device_staged_date(e.value ->> 'expires_on', r.source_row, e.key || '.expires_on')::text))), '{}'::jsonb),
           count(*) filter (where nullif(btrim(coalesce(e.value ->> 'serial', '')), '') is not null and cma.device_staged_ref(e.value ->> 'serial') is null)
      into v_comp, v_n
    from jsonb_each(v_comp_in) e;
    v_drop := v_drop + coalesce(v_n, 0);
    v_comp := coalesce((select jsonb_object_agg(e.key, e.value) from jsonb_each(v_comp) e where e.value <> '{}'::jsonb), '{}'::jsonb);
    v_raw := jsonb_strip_nulls(jsonb_build_object(
      'source_id', cma.device_staged_text(r.source_id), 'serial', v_serial, 'model', cma.device_staged_text(r.model),
      'status', cma.device_staged_text(r.status), 'country', cma.device_staged_text(r.country), 'warehouse_ref', v_wh,
      'customer_ref', v_cust, 'subscription_ref', v_sub, 'order_ref', v_ord, 'first_shipped_on', v_first::text,
      'stock_received_on', v_recv::text, 'last_shipped_on', v_last::text, 'warranty_until', v_warr::text,
      'end_of_life_on', v_eol::text,
      'components', case when v_comp <> '{}'::jsonb then v_comp end,
      'external_refs', case when v_refs <> '{}'::jsonb then v_refs end));
    v_um := v_um + (case when v_model is null then 1 else 0 end);
    v_us := v_us + (case when v_status is null then 1 else 0 end);
    v_uk := v_uk + (case when v_market is null then 1 else 0 end);
    v_ucr := v_ucr + (case when v_cust_bad then 1 else 0 end);

    v_old := null;
    select * into v_old from cma.device d
    where d.tenant_id = v_tenant and d.connection_id = p_connection_id and d.source_id = cma.device_staged_text(r.source_id)
    for update;
    v_changed := false;
    if v_old.id is null then
      insert into cma.device (tenant_id, connection_id, source_system, source_id, serial, model_key, market, device_status_key,
                              warehouse_ref, customer_ref, customer_ref_invalid, subscription_ref, order_ref, first_shipped_on,
                              stock_received_on, last_shipped_on, warranty_until, end_of_life_on, external_refs, raw)
      values (v_tenant, p_connection_id, v_system, cma.device_staged_text(r.source_id), v_serial, v_model, v_market, v_status,
              v_wh, v_cust, v_cust_bad, v_sub, v_ord, v_first, v_recv, v_last, v_warr, v_eol, v_refs, v_raw)
      returning id into v_id;
      v_ins := v_ins + 1;
    else
      v_id := v_old.id;
      if (v_old.serial, v_old.model_key, v_old.market, v_old.device_status_key, v_old.warehouse_ref, v_old.customer_ref,
          v_old.customer_ref_invalid, v_old.subscription_ref, v_old.order_ref, v_old.first_shipped_on, v_old.stock_received_on,
          v_old.last_shipped_on, v_old.warranty_until, v_old.end_of_life_on, v_old.external_refs, v_old.raw, v_old.source_deleted_at)
         is distinct from
         (v_serial, v_model, v_market, v_status, v_wh, v_cust, v_cust_bad, v_sub, v_ord, v_first, v_recv, v_last, v_warr, v_eol,
          v_refs, v_raw, null::timestamptz) then
        update cma.device d
           set serial = v_serial, model_key = v_model, market = v_market, device_status_key = v_status, warehouse_ref = v_wh,
               customer_ref = v_cust, customer_ref_invalid = v_cust_bad, subscription_ref = v_sub, order_ref = v_ord,
               first_shipped_on = v_first, stock_received_on = v_recv, last_shipped_on = v_last, warranty_until = v_warr,
               end_of_life_on = v_eol, external_refs = v_refs, raw = v_raw, source_deleted_at = null, synced_at = now()
         where d.tenant_id = v_tenant and d.id = v_old.id;
        v_changed := true;
      end if;
    end if;

    -- the components
    for c in select e.key, e.value from jsonb_each(v_comp) e loop
      v_cs := c.value ->> 'serial';
      v_ce := (c.value ->> 'expires_on')::date;
      v_cur := null;
      select * into v_cur from cma.device_component dc
      where dc.tenant_id = v_tenant and dc.device_id = v_id and dc.component_key = c.key and dc.replaced_at is null
      for update;
      if v_cur.id is null then
        insert into cma.device_component (tenant_id, device_id, component_key, serial, expires_on)
        values (v_tenant, v_id, c.key, v_cs, v_ce);
        v_changed := v_changed or v_old.id is not null;
      elsif v_cs is not null and v_cur.serial is not null and v_cs <> v_cur.serial then
        update cma.device_component dc set replaced_at = now() where dc.tenant_id = v_tenant and dc.id = v_cur.id;
        insert into cma.device_component (tenant_id, device_id, component_key, serial, expires_on)
        values (v_tenant, v_id, c.key, v_cs, v_ce);
        v_repl := v_repl + 1;
        v_changed := true;
      elsif (v_cur.serial, v_cur.expires_on) is distinct from (v_cs, v_ce) then
        update cma.device_component dc set serial = v_cs, expires_on = v_ce where dc.tenant_id = v_tenant and dc.id = v_cur.id;
        v_changed := true;
      end if;
    end loop;

    if v_old.id is not null then
      if v_changed then
        v_upd := v_upd + 1;
      else
        v_same := v_same + 1;
      end if;
    end if;
  end loop;

  -- a full snapshot: the connection's devices it does not hold are missing now. The batch's record ids are read once
  -- into a hashed set (not in over a subquery whose ids the checks above proved present), not per device: 0008zi's
  -- not exists ran as a nested loop, so 10,000 records took some 40 seconds here alone
  if p_is_full then
    update cma.device d set source_deleted_at = now(), synced_at = now()
    where d.tenant_id = v_tenant and d.connection_id = p_connection_id and d.source_deleted_at is null
      and d.source_id not in (select cma.device_staged_text(s.source_id) from cma.device_import_row s
                              where s.tenant_id = v_tenant and s.batch_key = p_batch_key and cma.device_staged_text(s.source_id) is not null);
    get diagnostics v_missing = row_count;
  end if;

  delete from cma.device_import_row s where s.tenant_id = v_tenant and s.batch_key = p_batch_key;

  v_counts := jsonb_build_object('rows', v_rows, 'inserted', v_ins, 'updated', v_upd, 'unchanged', v_same, 'missing_now', v_missing,
                                 'components_replaced', v_repl, 'unmapped_model', v_um, 'unmapped_status', v_us,
                                 'unmapped_market', v_uk, 'customer_ref_invalid', v_ucr, 'refs_dropped', v_drop);
  return v_counts;
exception when check_violation or not_null_violation or foreign_key_violation then
  raise exception 'invalid device: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- A person's load of a staged file (tenant.configure), as 0008zi: the shared load, then one run of job assets_import
-- with the batch key as its stream and the counts
create or replace function cma.load_device_snapshot(p_batch_key text, p_connection_id uuid, p_is_full boolean)
returns jsonb
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_counts jsonb;
  v_run    uuid;
begin
  perform cma.assert_permission('tenant.configure');
  v_counts := cma.device_snapshot_apply(p_batch_key, p_connection_id, p_is_full);
  insert into cma.sync_run (tenant_id, connection_id, job, stream)
  values (v_tenant, p_connection_id, 'assets_import', p_batch_key)
  returning id into v_run;
  update cma.sync_run sr set status = 'succeeded', finished_at = now(), counts = v_counts
  where sr.tenant_id = v_tenant and sr.id = v_run;
  return v_counts;
end
$$;

-- The ingest's load of the rows it read and staged (ingest.write, the tenant's Ingest user): the shared load, for an
-- active asset register connection with a token secret name. A connection without one is loaded from files only
-- (decision of 27 October 2026: the poll skips it), so it is refused here (CMA04). No run of its own: the job's run
-- (assets_poll, reconcile or backfill) records the counts. p_is_full: the nightly full snapshot and a backfill (marks
-- the devices it does not hold as missing), never the poll of changed records
create or replace function cma.ingest_load_device_snapshot(p_connection_id uuid, p_batch_key text, p_is_full boolean)
returns jsonb
language plpgsql
as $$
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  if (select c.token_secret_name from cma.integration_connection c
      where c.tenant_id = cma.current_tenant_id() and c.id = p_connection_id) is null then
    raise exception 'connection % has no token secret name: it is loaded from files (cma.load_device_snapshot), not by the ingest', p_connection_id
      using errcode = 'CMA04';
  end if;
  return cma.device_snapshot_apply(p_batch_key, p_connection_id, p_is_full);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.ingest_sync_run_finish(uuid,text,jsonb,text)',
    'cma.connection_held_kinds_of(uuid,uuid)',
    'cma.assets_settings_problem(jsonb)',
    'cma.set_connection_settings(uuid,jsonb)',
    'cma.device_snapshot_apply(text,uuid,boolean)',
    'cma.load_device_snapshot(text,uuid,boolean)',
    'cma.ingest_load_device_snapshot(uuid,text,boolean)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008zj', 'Asset sync: the asset register read through its API on a schedule (the poll of changed records, the nightly full snapshot, a read on demand) through 0008zi''s load. sync_run job assets_poll; cma.ingest_sync_run_finish takes the device load''s counts; the register''s fields as connection fields (entity device, device_component with the kind as ref_system, named ids as ref), kept to asset register connections by a trigger and counted as assets by cma.connection_held_kinds_of; cma.set_connection_settings checks an asset register''s table_id, view_id, date_format and assets_poll_interval_minutes; the staging takes ingest.write; the shared load cma.device_snapshot_apply (one per connection at a time), called by cma.load_device_snapshot (tenant.configure, its run assets_import) and cma.ingest_load_device_snapshot (ingest.write, a connection with a token secret name only)')
on conflict (version) do nothing;

commit;
reset role;
