-- =============================================================================================
-- 224_device_debt_status.sql: addition 0009zl, the asset register's debt status on devices: the Installed base's measure
-- and dimension, and the Maintenance report's pause
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. The debt statuses and their aliases are tenant configuration set
-- in Studio (docs/import/devices.md); no label is seeded. Runs unchanged in every database, after
-- 222_subscription_moves_entry.sql (0009zk). Rerunnable, forward-only, in one transaction with a lock timeout. Run as your
-- own IAM login: dev first, then 225_verify_device_debt_status.sql there (and its provoked run), then the verifies that
-- read what this changes:
--   the load, its row types and the staging (cma.device_raw_ok, cma.device_import_staging_insert, cma.device_rows_apply,
--     cma.device_snapshot_apply, cma.ingest_load_device_chunk): 113, 115, 117 and 169; 113's A2 (the device's and the
--     staging's columns), 117's A2 (the row types' attribute counts) and 169's S1 (the staging's last columns) are edited by
--     this change;
--   connection_field's checks (as text): 85, 99, 115, 137 and 169;
--   cma.maintenance_items_of (dropped and created: two more columns) and its readers (the maintenance reads of 116, cma.flash_devices_of,
--     cma.data_quality_of, cma.fleet_devices_of): 113, 117, 123, 137, 147, 149, 161, 179, 181, 189 and 193;
--   cma.data_quality_assets_checks, cma.data_quality_of and cma.data_quality_fix_in: 41, 69, 73, 75, 101, 105, 113 (its
--     B13 lists the assets checks and is edited by this change), 117, 123, 133, 137, 161, 179, 211 and 215;
--   the installed base's definition (cma.flash_overviews, cma.flash_compute_of, cma.flash_labels_of, cma.flash_rows_of,
--     cma.flash_definition_version): 123, 137, 139, 143, 147, 149, 159, 161, 173, 181 and 189 (147's set and measure lists
--     are edited by this change);
--   then the data map's schema refresh from dev on this branch; then prod: the point-in-time recovery check, 224, 225 and
--   the same verifies, before the merge. The ingest of main sends rows without debt_status, which this script's chunk load
--   still takes (a missing key is an empty value); the ingest of this change sends it, which the database before this
--   script refuses, so in prod this script runs before that ingest is deployed. The web of main calls the Maintenance
--   report's forms of 112, which this script leaves as they were; the web of this change calls the new forms.
--
-- Why (Martin, 23 November 2026; brief 0009zc, numbered 0009zl because 0009zc is 206's; Decision log, 23 Nov 2026): the
-- asset register (Airtable 2.0, Installed Base) gains the field debt_status. A device under a debt status gets no
-- maintenance until the customer pays (the register empties the field) or the device comes back (its status leaves the
-- field). The register's analysis of 22 November 2026: 522 of 7,078 Active/Customer devices carry one of four labels, none
-- on any other status, holding about 40% of the recorded past-due pads and batteries. All four pause maintenance.
--
-- What it adds
--   the catalog        cma.device_debt_status (tenant, key, name, pauses_maintenance default true, sort order) and
--                      cma.device_debt_status_alias (tenant, alias matched lower-cased and trimmed, key);
--                      cma.set_device_debt_status(key, name, pauses_maintenance, sort) and
--                      cma.set_device_debt_status_alias(alias, key) (tenant.configure; an empty key removes the alias);
--                      cma.device_debt_status_key_of(tenant, label). The keys none, any, all and unpaused are refused: they
--                      are the filters' own values. A status is never deleted by the application (the catalogs' rule, 112)
--   the device         cma.device.debt_status_key (null: no debt status, or a label no alias maps; raw keeps the label),
--                      a foreign key to the catalog as the device status's. The register owns the field; the CMA never
--                      writes it. Note: the first full read after the field is mapped updates every device whose raw gains
--                      a label (one audit row each, as any changed device)
--   the load           the row types cma.device_load_row and cma.device_load_mapped, the staging cma.device_import_row
--                      and its COPY target cma.device_import_staging gain debt_status; made again with it, each from 168:
--                      cma.device_raw_ok (the key), cma.device_import_staging_insert, cma.device_rows_apply (the answer gains
--                      unmapped_debt_status: a label given that no alias maps), cma.device_snapshot_apply and
--                      cma.ingest_load_device_chunk. An emptied field clears the key at the next load that reads the device.
--                      cma.load_device_snapshot's answer and its run's counts carry unmapped_debt_status (it passes the
--                      load's answer on); the ingest's run counts do not (as unmapped_language: docs/open-decisions.md)
--   field mapping      connection_field's checks take debt_status as a field and as an asset register's device field
--   Maintenance        cma.maintenance_items_of gains debt_status_key and maintenance_paused (its debt status pauses
--                      maintenance and its device status is in the field: a device that comes back leaves the pause); every
--                      item stays, so every other reader reads what it read before. New forms with a debt status filter:
--                      cma.maintenance_bucket_dates_of (8 arguments), cma.maintenance_page_of (8), cma.maintenance_rows_of
--                      (11), cma.maintenance_page (6) and cma.maintenance_rows (9), none with a default, so no call matches
--                      two forms; the filter is cma.maintenance_debt_matches (null every device, unpaused, none, any or a
--                      key) and cma.assert_maintenance_debt checks it (CMA04). The page's answer gains paused_devices,
--                      debt and debt_statuses; a row ends with its device's debt_status_key and maintenance_paused. 116's
--                      and 112's forms stay as they were (the web of main, 113 and 117 call them)
--   data quality       device_debt_status_unmapped (305, after the asset register's checks): a device whose register gives
--                      a debt status label that no alias maps, the value the label; fixed in the asset register
--   installed base     the measure under_debt_status (devices in the field with a debt status) in every set, the dim
--                      debt_status (a key, or none) and the set [market, model, debt_status] (cma.flash_overviews,
--                      cma.flash_compute_of); the labels debt_status and debt_status_order (cma.flash_labels_of); the
--                      records' filter debt_status (a key, none or any), the measure's records and each row's debt status
--                      (cma.flash_rows_of); its definition version moves to 0009zl (cma.flash_definition_version), so a
--                      current take of 0009ze is not read and the page reads live until the snapshot job's next refresh
--
-- No forget trigger on the catalog (160's D9): the take counts the key the device row stores at the register's read, as
-- it counts the model's and the market's, and reads no column of the catalog; names and order are labels, read live.
--
-- Measured locally on PostgreSQL 16 (dev seed; the perf volume fixture does not hold debt statuses): see the PR.
--
-- Not made: no cma_read view of the catalog; no write to the register, the subscription app or NetSuite; the cross-check
-- of the debt status with the subscription app's payment state (docs/open-decisions.md).
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
set local lock_timeout = '5s';
set role cma_owner;

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0009zk') then
    raise exception 'addition 0009zk (222_subscription_moves_entry.sql) must run before 0009zl';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The debt statuses and their aliases (tenant configuration)
-- ---------------------------------------------------------------------------------------------
-- A debt status: the register's word for a device whose maintenance waits on a debt (Debt status, docs/definitions.md).
-- pauses_maintenance: the Maintenance report leaves its devices out by default. The keys none, any, all and unpaused are
-- the filters' values, never a status's
create table if not exists cma.device_debt_status (
  id                  uuid primary key default uuidv7(),
  tenant_id           uuid not null default cma.current_tenant_id() references cma.tenant (id),
  key                 text not null check (key ~ '^[a-z0-9]+(_[a-z0-9]+)*$' and length(key) <= 40
                                           and key not in ('none', 'any', 'all', 'unpaused')),
  name                text not null check (length(btrim(name)) between 1 and 80 and name !~ '[[:cntrl:]@]'),
  pauses_maintenance  boolean not null default true,
  sort_order          integer not null default 100,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, key)
);
comment on table cma.device_debt_status is 'A tenant''s debt statuses: the asset register''s word for a device whose maintenance waits on a debt, with whether it pauses maintenance and its order. Reporting reads the key and the flag, never a name. Tenant configuration (0009zl)';
comment on column cma.device_debt_status.pauses_maintenance is 'Whether the Maintenance report leaves devices under this debt status out by default (their items stay in the forecast)';
create or replace trigger set_updated_at before update on cma.device_debt_status
  for each row execute function cma.set_updated_at();
select cma.setup_tenant_table('cma.device_debt_status');
-- The application never deletes a catalog row (112's rule): a status no device carries simply counts nothing
revoke delete on cma.device_debt_status from cma_app;

-- A register's debt status label to its key, matched lower-cased and trimmed. One key per alias; several aliases may
-- share a key
create table if not exists cma.device_debt_status_alias (
  id          uuid primary key default uuidv7(),
  tenant_id   uuid not null default cma.current_tenant_id() references cma.tenant (id),
  alias       text not null check (alias = lower(btrim(alias)) and length(alias) between 1 and 100 and alias !~ '[[:cntrl:]@]'),
  key         text not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, alias),
  foreign key (tenant_id, key) references cma.device_debt_status (tenant_id, key)
);
comment on table cma.device_debt_status_alias is 'The asset register''s debt status labels and the debt status each maps to (cma.device_debt_status_key_of): matched lower-cased and trimmed. Tenant configuration (0009zl)';
create or replace trigger set_updated_at before update on cma.device_debt_status_alias
  for each row execute function cma.set_updated_at();
select cma.setup_tenant_table('cma.device_debt_status_alias');

-- A label's key: the alias equal to the label lower-cased and trimmed; null for an empty or unmapped label
create or replace function cma.device_debt_status_key_of(p_tenant_id uuid, p_label text)
returns text
language sql stable
as $$
  select a.key from cma.device_debt_status_alias a
  where a.tenant_id = p_tenant_id and nullif(btrim(p_label), '') is not null and a.alias = lower(btrim(p_label))
$$;

-- Sets a debt status by its key (tenant.configure): the key 1 to 40 lower-case letters and digits in words joined by _
-- (none, any, all and unpaused refused), the name 1 to 80 characters without an @, pauses_maintenance (null: true, the
-- default) and the sort order (null: 100). Answers the key. A device takes a new status at its next load that reads it
create or replace function cma.set_device_debt_status(p_key text, p_name text, p_pauses_maintenance boolean, p_sort_order integer)
returns text
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_key    text := lower(btrim(coalesce(p_key, '')));
  v_name   text := btrim(coalesce(p_name, ''));
begin
  perform cma.assert_permission('tenant.configure');
  if v_key !~ '^[a-z0-9]+(_[a-z0-9]+)*$' or length(v_key) > 40 or v_key in ('none', 'any', 'all', 'unpaused') then
    raise exception 'a debt status''s key is 1 to 40 lower-case letters and digits joined by _, not none, any, all or unpaused'
      using errcode = 'CMA04';
  end if;
  if length(v_name) not between 1 and 80 or v_name ~ '[[:cntrl:]@]' then
    raise exception 'a debt status''s name is 1 to 80 characters without an @' using errcode = 'CMA04';
  end if;
  insert into cma.device_debt_status (tenant_id, key, name, pauses_maintenance, sort_order)
  values (v_tenant, v_key, v_name, coalesce(p_pauses_maintenance, true), coalesce(p_sort_order, 100))
  on conflict (tenant_id, key) do update
    set name = excluded.name, pauses_maintenance = excluded.pauses_maintenance, sort_order = excluded.sort_order;
  return v_key;
end
$$;

-- Sets an alias's debt status (tenant.configure): the alias lower-cased and trimmed (1 to 100 characters, no @), the key
-- a debt status of the catalog (CMA02 otherwise); an empty or null key removes the alias. Answers the alias as stored. A
-- device takes the new key at its next load that reads it (the nightly full read reads every device)
create or replace function cma.set_device_debt_status_alias(p_alias text, p_key text)
returns text
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_alias  text := lower(btrim(coalesce(p_alias, '')));
  v_key    text := lower(btrim(coalesce(p_key, '')));
begin
  perform cma.assert_permission('tenant.configure');
  if length(v_alias) not between 1 and 100 or v_alias ~ '[[:cntrl:]@]' then
    raise exception 'an alias is the register''s label, 1 to 100 characters without an @' using errcode = 'CMA04';
  end if;
  if v_key = '' then
    delete from cma.device_debt_status_alias a where a.tenant_id = v_tenant and a.alias = v_alias;
    return v_alias;
  end if;
  if not exists (select 1 from cma.device_debt_status s where s.tenant_id = v_tenant and s.key = v_key) then
    raise exception 'no debt status %', v_key using errcode = 'CMA02';
  end if;
  insert into cma.device_debt_status_alias (tenant_id, alias, key) values (v_tenant, v_alias, v_key)
  on conflict (tenant_id, alias) do update set key = excluded.key;
  return v_alias;
end
$$;

-- The Maintenance report's debt status filter for one device: null every device; unpaused, the report's default: none
-- whose debt status pauses maintenance (a device without a debt status, or under one that does not pause); none: without
-- a debt status; any: with one; else that debt status's key. Inlined into its callers
create or replace function cma.maintenance_debt_matches(p_debt text, p_key text, p_paused boolean)
returns boolean
language sql immutable
as $$
  select p_debt is null
      or (p_debt = 'unpaused' and not coalesce(p_paused, false))
      or (p_debt = 'none' and p_key is null)
      or (p_debt = 'any' and p_key is not null)
      or (p_debt not in ('unpaused', 'none', 'any') and p_key = p_debt)
$$;

-- The filter's value (CMA04 else): null, unpaused, none, any or a debt status of the tenant's catalog
create or replace function cma.assert_maintenance_debt(p_tenant_id uuid, p_debt text)
returns void
language plpgsql stable
as $$
begin
  if p_debt is not null and p_debt not in ('unpaused', 'none', 'any')
     and not exists (select 1 from cma.device_debt_status s where s.tenant_id = p_tenant_id and s.key = p_debt) then
    raise exception 'a debt status filter is unpaused, none, any or a debt status''s key' using errcode = 'CMA04';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. The device's debt status
-- ---------------------------------------------------------------------------------------------
alter table cma.device add column if not exists debt_status_key text;
alter table cma.device drop constraint if exists device_debt_status_fkey;
alter table cma.device add constraint device_debt_status_fkey foreign key (tenant_id, debt_status_key)
  references cma.device_debt_status (tenant_id, key);
comment on column cma.device.debt_status_key is 'The debt status the register''s label maps to (cma.device_debt_status_key_of); null without a debt status, or when the label is unmapped (raw keeps the label). The register owns it; the CMA never writes it (0009zl)';
create index if not exists device_debt_status_idx on cma.device (tenant_id, debt_status_key) where debt_status_key is not null;

-- ---------------------------------------------------------------------------------------------
-- 3. raw keeps the register's label
-- ---------------------------------------------------------------------------------------------
-- As 0009j (168), with the register's debt status label among raw's keys
-- based on: 168_pledge_lists.sql
create or replace function cma.device_raw_ok(p_raw jsonb)
returns boolean
language sql immutable
as $$
  select p_raw is not null and jsonb_typeof(p_raw) = 'object' and length(p_raw::text) <= 4096 and strpos(p_raw::text, '@') = 0
     and not exists (select 1 from jsonb_object_keys(p_raw) k
                     where k not in ('source_id', 'serial', 'model', 'status', 'country', 'warehouse_ref', 'customer_ref',
                                     'subscription_ref', 'order_ref', 'first_shipped_on', 'stock_received_on', 'last_shipped_on',
                                     'warranty_until', 'end_of_life_on', 'components', 'external_refs', 'pledge_ref', 'language', 'debt_status'))
$$;
revoke execute on function cma.device_raw_ok(jsonb) from public;
grant execute on function cma.device_raw_ok(jsonb) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 4. The staging and the load's row types
-- ---------------------------------------------------------------------------------------------
alter table cma.device_import_row add column if not exists debt_status text check (length(debt_status) <= 500);

-- 0009j's COPY target with the column at its end (a view gains columns only there)
create or replace view cma.device_import_staging as
  select r.batch_key, r.source_row, r.source_id, r.serial, r.model, r.status, r.country, r.warehouse_ref, r.customer_ref,
         r.subscription_ref, r.order_ref, r.first_shipped_on, r.stock_received_on, r.last_shipped_on, r.warranty_until,
         r.end_of_life_on, r.components, r.external_refs, r.pledge_ref, r.language, r.debt_status
  from cma.device_import_row r
  where r.tenant_id = cma.current_tenant_id();

do $$
begin
  if not exists (select 1 from pg_attribute where attrelid = (select typrelid from pg_type where oid = 'cma.device_load_row'::regtype)
                 and attname = 'debt_status' and not attisdropped) then
    alter type cma.device_load_row add attribute debt_status text;
  end if;
  if not exists (select 1 from pg_attribute where attrelid = (select typrelid from pg_type where oid = 'cma.device_load_mapped'::regtype)
                 and attname = 'debt_status' and not attisdropped) then
    alter type cma.device_load_mapped add attribute debt_status text;
  end if;
end
$$;
comment on type cma.device_load_row is 'A device record as staged, every value text: the input of cma.device_rows_apply (0008zk; pledge_ref and language 0009j; debt_status, the register''s label, 0009zl)';
comment on type cma.device_load_mapped is 'A device record as cma.device_rows_apply maps it (0008zk; pledge_ref and language 0009j; debt_status, the debt status''s key or null, 0009zl)';

-- As 0009j (168), with the staged debt status (an @ kept as a bare @)
-- based on: 168_pledge_lists.sql
create or replace function cma.device_import_staging_insert()
returns trigger
language plpgsql
as $$
begin
  perform cma.assert_any_permission(array['tenant.configure', 'ingest.write']);
  insert into cma.device_import_row (tenant_id, batch_key, source_row, source_id, serial, model, status, country, warehouse_ref,
                                     customer_ref, subscription_ref, order_ref, first_shipped_on, stock_received_on, last_shipped_on,
                                     warranty_until, end_of_life_on, components, external_refs, pledge_ref, language,
                                     debt_status)
  values (cma.current_tenant_id(), new.batch_key, new.source_row, cma.device_staged_without_at(new.source_id),
          cma.device_staged_without_at(new.serial), cma.device_staged_without_at(new.model), cma.device_staged_without_at(new.status),
          cma.device_staged_without_at(new.country), cma.device_staged_without_at(new.warehouse_ref),
          cma.device_staged_without_at(new.customer_ref), cma.device_staged_without_at(new.subscription_ref),
          cma.device_staged_without_at(new.order_ref), cma.device_staged_without_at(new.first_shipped_on),
          cma.device_staged_without_at(new.stock_received_on), cma.device_staged_without_at(new.last_shipped_on),
          cma.device_staged_without_at(new.warranty_until), cma.device_staged_without_at(new.end_of_life_on),
          case when strpos(coalesce(new.components, ''), '@') > 0 then cma.device_staged_object_without_at(new.components) else new.components end,
          case when strpos(coalesce(new.external_refs, ''), '@') > 0 then cma.device_staged_object_without_at(new.external_refs) else new.external_refs end,
          cma.device_staged_without_at(new.pledge_ref), cma.device_staged_without_at(new.language),
          cma.device_staged_without_at(new.debt_status));
  return new;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. The load with the debt status
-- ---------------------------------------------------------------------------------------------
-- As 0009j (168), with the debt status: the register's label looked up once per distinct label
-- (cma.device_debt_status_key_of), the key compared, updated and inserted with the device's other values, raw keeping the
-- label. A label that no alias maps leaves the key empty, as does an emptied field (the next load that reads the device
-- clears it). The answer gains unmapped_debt_status (a label given that no alias maps). A row that stages no debt status
-- (the ingest of main, a file of the tool before this) loads it as empty, as any column the source leaves out
-- based on: 168_pledge_lists.sql
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
                nullif(btrim(coalesce(u.order_ref, '')), '') is not null as ord_given,
                -- 0009j: the loan a device secures (an id, as subscription_ref) and its language's label
                cma.device_staged_ref(u.pledge_ref) as pledge, nullif(btrim(coalesce(u.pledge_ref, '')), '') is not null as pledge_given,
                u.language, cma.device_staged_text(u.language) as language_t,
                -- 0009zl: the register's debt status label
                u.debt_status, cma.device_staged_text(u.debt_status) as debt_status_t
         from unnest(p_rows) u),
       models as (select l.label, cma.device_model_key_of(v_tenant, l.label) as key from (select distinct r.model as label from r) l),
       statuses as (select l.label, cma.device_status_key_of(v_tenant, l.label) as key from (select distinct r.status as label from r) l),
       markets as (select l.label, cma.market_code_of(v_tenant, l.label) as code from (select distinct r.country as label from r) l),
       languages as (select l.label, cma.device_language_code_of(v_tenant, l.label) as code from (select distinct r.language as label from r) l),
       debts as (select l.label, cma.device_debt_status_key_of(v_tenant, l.label) as key from (select distinct r.debt_status as label from r) l),
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
                         'components', cp.comp, 'external_refs', rf.refs, 'pledge_ref', r.pledge, 'language', r.language_t,
                         'debt_status', r.debt_status_t)),
                       (r.serial_given and r.serial is null)::integer + (r.wh_given and r.wh is null)::integer
                       + (r.sub_given and r.sub is null)::integer + (r.ord_given and r.ord is null)::integer
                       + (r.pledge_given and r.pledge is null)::integer
                       + coalesce(rf.dropped, 0) + coalesce(cp.dropped, 0),
                       r.pledge, lg.code, ds.key)::cma.device_load_mapped
                   order by r.source_row)
    into v_m
  from r
  left join models mo on mo.label is not distinct from r.model
  left join statuses st on st.label is not distinct from r.status
  left join markets mk on mk.label is not distinct from r.country
  left join languages lg on lg.label is not distinct from r.language
  left join debts ds on ds.label is not distinct from r.debt_status
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
                             d.end_of_life_on, d.external_refs, d.raw, d.source_deleted_at, d.pledge_ref, d.language, d.debt_status_key)
                            is distinct from
                            (m.serial, m.model_key, m.market, m.device_status_key, m.warehouse_ref, m.customer_ref, m.customer_ref_invalid,
                             m.subscription_ref, m.order_ref, m.first_shipped_on, m.stock_received_on, m.last_shipped_on, m.warranty_until,
                             m.end_of_life_on, m.external_refs, m.raw, null::timestamptz, m.pledge_ref, m.language, m.debt_status) as differs
                     from cma.device d
                     where d.tenant_id = v_tenant and d.connection_id = p_connection_id and d.source_id = m.source_id
                     limit 1) x on true;
  -- the changed ones updated by id, each from its mapped values
  with u as (update cma.device d
                set (serial, model_key, market, device_status_key, warehouse_ref, customer_ref, customer_ref_invalid, subscription_ref,
                     order_ref, first_shipped_on, stock_received_on, last_shipped_on, warranty_until, end_of_life_on, external_refs, raw,
                     pledge_ref, language, debt_status_key)
                  = (select n.serial, n.model_key, n.market, n.device_status_key, n.warehouse_ref, n.customer_ref, n.customer_ref_invalid,
                            n.subscription_ref, n.order_ref, n.first_shipped_on, n.stock_received_on, n.last_shipped_on, n.warranty_until,
                            n.end_of_life_on, n.external_refs, n.raw, n.pledge_ref, n.language, n.debt_status
                     from jsonb_populate_record(null::cma.device_load_mapped, v_dmap -> d.id::text) n),
                    source_deleted_at = null, synced_at = now()
              where d.tenant_id = v_tenant and d.id = any (array(select k::uuid from jsonb_object_keys(v_dmap) k))
              returning d.id)
  select coalesce(array_agg(u.id), '{}') into v_changed from u;
  -- the new ones inserted, in line order
  with i as (insert into cma.device (tenant_id, connection_id, source_system, source_id, serial, model_key, market, device_status_key,
                                     warehouse_ref, customer_ref, customer_ref_invalid, subscription_ref, order_ref, first_shipped_on,
                                     stock_received_on, last_shipped_on, warranty_until, end_of_life_on, external_refs, raw, pledge_ref,
                                     language, debt_status_key)
             select v_tenant, p_connection_id, v_system, m.source_id, m.serial, m.model_key, m.market, m.device_status_key, m.warehouse_ref,
                    m.customer_ref, m.customer_ref_invalid, m.subscription_ref, m.order_ref, m.first_shipped_on, m.stock_received_on,
                    m.last_shipped_on, m.warranty_until, m.end_of_life_on, m.external_refs, m.raw, m.pledge_ref, m.language, m.debt_status
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
    'unmapped_language', (select count(*) from unnest(v_m) m where m.language is null and m.raw ? 'language'),
    'unmapped_debt_status', (select count(*) from unnest(v_m) m where m.debt_status is null and m.raw ? 'debt_status'),
    'customer_ref_invalid', (select count(*) from unnest(v_m) m where m.customer_ref_invalid),
    'refs_dropped', (select coalesce(sum(m.refs_dropped), 0) from unnest(v_m) m),
    'map_ms', v_map, 'upsert_ms', v_ups, 'components_ms', v_cmp, 'missing_ms', v_mis);
exception when check_violation or not_null_violation or foreign_key_violation then
  raise exception 'invalid device: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- As 0009j (168), the staged batch read with the debt status
-- based on: 168_pledge_lists.sql
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
                       s.components, s.external_refs, s.pledge_ref, s.language, s.debt_status)::cma.device_load_row order by s.source_row)
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

-- As 0009j (168), the chunk's rows with the debt status: allowed, at most 500 characters, an @ kept as a bare @; a row
-- without it reads it as empty
-- based on: 168_pledge_lists.sql
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
                  'components', 'external_refs', 'pledge_ref', 'language', 'debt_status');
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
                       case when strpos(coalesce(r.external_refs, ''), '@') > 0 then cma.device_staged_object_without_at(r.external_refs) else r.external_refs end,
                       cma.device_staged_without_at(r.pledge_ref), cma.device_staged_without_at(r.language),
                       cma.device_staged_without_at(r.debt_status)
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
                             (15, 'components', length(r.components) > 4000), (16, 'external_refs', length(r.external_refs) > 4000),
                             (17, 'pledge_ref', length(r.pledge_ref) > 500), (18, 'language', length(r.language) > 500),
                             (19, 'debt_status', length(r.debt_status) > 500)) as x(n, col, too_long)
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

-- ---------------------------------------------------------------------------------------------
-- 6. The register's field as configuration
-- ---------------------------------------------------------------------------------------------
-- As 0009j (168), with debt_status as a field and among an asset register's device fields (each list's new entry last)
alter table cma.connection_field drop constraint if exists connection_field_field_check;
alter table cma.connection_field add constraint connection_field_field_check
  check (field = any (array['market', 'language', 'country', 'currency', 'store', 'amount', 'source_channel', 'category', 'ref', 'created_at',
                            'reason', 'serial', 'model', 'status', 'warehouse_ref', 'customer_ref', 'subscription_ref', 'order_ref',
                            'first_shipped_on', 'stock_received_on', 'last_shipped_on', 'warranty_until', 'end_of_life_on', 'expires_on',
                            'segment', 'pledge_ref', 'debt_status']));
alter table cma.connection_field drop constraint if exists connection_field_entity_field_check;
alter table cma.connection_field add constraint connection_field_entity_field_check
  check (case when entity = 'contact' then field = any (array['country', 'language', 'currency', 'store', 'ref', 'created_at', 'segment'])
              when entity = 'device' then field = any (array['serial', 'model', 'status', 'country', 'warehouse_ref', 'customer_ref',
                                                             'subscription_ref', 'order_ref', 'first_shipped_on', 'stock_received_on',
                                                             'last_shipped_on', 'warranty_until', 'end_of_life_on', 'ref', 'pledge_ref',
                                                             'language', 'debt_status'])
              when entity = 'device_component' then field = any (array['serial', 'expires_on'])
              when field = 'reason' then entity in ('deal', 'ticket')
              else field = any (array['market', 'language', 'currency', 'amount', 'source_channel', 'category']) end);

-- ---------------------------------------------------------------------------------------------
-- 7. Maintenance: the forecast keeps every item; the pause is a filter
-- ---------------------------------------------------------------------------------------------
-- As 0008zk (116), the same rows, each with its device's debt status key and maintenance_paused (its debt status pauses
-- maintenance and its device status is in the field). Every item stays: the pause is a filter of the Maintenance report's reads, never a deletion, and every
-- other reader (the installed base, data quality, fleet management) reads the rows it read before. Its columns change, so
-- it is dropped and created; its callers are SQL and plpgsql functions that name its columns (no dependency to cascade)
drop function if exists cma.maintenance_items_of(uuid, date);
-- based on: 116_asset_sync_load.sql
create or replace function cma.maintenance_items_of(p_tenant_id uuid, p_today date)
returns table (device_id uuid, connection_id uuid, source_id text, serial text, model_key text, market text, device_status_key text,
               is_in_field boolean, is_in_stock boolean, component_key text, component_order integer, due_on date, basis text,
               action_on date, past_due boolean, exchange_key text, exchange_on date, debt_status_key text, maintenance_paused boolean)
language sql stable
as $$
  with s as (
    select greatest(coalesce(nullif(cma.setting_of(p_tenant_id, 'assets.bundle_window_days'), '')::integer, 0), 0) as win,
           date_trunc('month', p_today)::date as month,
           (select t.timezone from cma.tenant t where t.id = p_tenant_id) as zone
  ), d as (
    select dv.id, dv.connection_id, dv.source_id, dv.serial, dv.model_key, dv.market, dv.device_status_key, st.is_in_field, st.is_in_stock,
           coalesce(dv.last_shipped_on, dv.first_shipped_on) as anchor, dv.end_of_life_on,
           -- 0009zl: the device's debt status, and paused while its debt status pauses maintenance and its status is in the
           -- field (a device that comes back, its status leaving the field, leaves the pause)
           dv.debt_status_key, coalesce(dd.pauses_maintenance, false) and st.is_in_field as paused
    from cma.device dv
    join cma.device_status st on st.tenant_id = dv.tenant_id and st.key = dv.device_status_key and st.is_tracked
    left join cma.device_debt_status dd on dd.tenant_id = dv.tenant_id and dd.key = dv.debt_status_key
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
           coalesce(ru.lead_days, 0) as lead_days, d.debt_status_key, d.paused
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
           'device', 2147483647, d.end_of_life_on, null::date, 0, d.debt_status_key, d.paused
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
         case when x.act is not null then x.xstart end,
         x.debt_status_key, x.paused
  from x
$$;

-- As 0008zi (112), the same rows: its 17 columns named, where 112 read cma.maintenance_items_of's every column (i.*),
-- which now has two more
-- based on: 112_assets.sql
create or replace function cma.maintenance_due_of(p_from_month date, p_months integer)
returns table (device_id uuid, connection_id uuid, source_id text, serial text, model_key text, market text, device_status_key text,
               is_in_field boolean, is_in_stock boolean, component_key text, component_order integer, due_on date, basis text,
               action_on date, past_due boolean, exchange_key text, exchange_on date)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_tenant uuid := cma.current_tenant_id();
  v_today  date;
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  v_today := cma.tenant_today_of(v_tenant);
  perform cma.assert_maintenance_horizon(p_from_month, p_months, v_today);
  return query
    select i.device_id, i.connection_id, i.source_id, i.serial, i.model_key, i.market, i.device_status_key, i.is_in_field, i.is_in_stock,
           i.component_key, i.component_order, i.due_on, i.basis, i.action_on, i.past_due, i.exchange_key, i.exchange_on
    from cma.maintenance_items_of(v_tenant, v_today) i
    where i.basis = 'unknown' or i.past_due
       or (i.action_on >= p_from_month and i.action_on < (p_from_month + make_interval(months => p_months))::date)
    order by i.action_on nulls last, i.market, i.model_key, i.serial, i.component_order;
end
$$;

-- As 0008zk's (116), with the debt status filter (cma.maintenance_debt_matches) and each item's debt status key and
-- maintenance_paused. A form of its own (eight arguments): 116's seven-argument form stays as it was for the readers of
-- main and the verifies that call it (113, 117)
-- based on: 116_asset_sync_load.sql
create or replace function cma.maintenance_bucket_dates_of(p_tenant_id uuid, p_from_month date, p_months integer, p_market text,
                                                           p_model text, p_scope text, p_debt text, p_today date)
returns table (device_id uuid, connection_id uuid, source_id text, serial text, model_key text, market text, device_status_key text,
               component_key text, component_order integer, due_on date, basis text, action_on date, past_due boolean, exchange_key text,
               exchange_on date, bucket_on date, exchange_bucket_on date, debt_status_key text, maintenance_paused boolean)
language sql stable
as $$
  select i.device_id, i.connection_id, i.source_id, i.serial, i.model_key, i.market, i.device_status_key, i.component_key, i.component_order,
         i.due_on, i.basis, i.action_on, i.past_due, i.exchange_key, i.exchange_on,
         case when i.past_due then '-infinity'::date
              when i.action_on >= p_from_month and i.action_on < (select (p_from_month + make_interval(months => p_months))::date)
                then date_trunc('month', i.action_on::timestamp)::date end,
         case when i.exchange_on < (select date_trunc('month', p_today::timestamp)::date) then '-infinity'::date
              when i.exchange_on >= p_from_month and i.exchange_on < (select (p_from_month + make_interval(months => p_months))::date)
                then date_trunc('month', i.exchange_on::timestamp)::date end,
         i.debt_status_key, i.maintenance_paused
  from cma.maintenance_items_of(p_tenant_id, p_today) i
  where (p_scope is null or (p_scope = 'field' and i.is_in_field) or (p_scope = 'stock' and i.is_in_stock))
    and (p_market is null or coalesce(i.market, 'unknown') = p_market)
    and (p_model is null or coalesce(i.model_key, 'unknown') = p_model)
    and cma.maintenance_debt_matches(p_debt, i.debt_status_key, i.maintenance_paused)
$$;

-- As 0008zk's (116), with the debt status filter, and paused_devices, debt and debt_statuses in the answer. A form of its
-- own (eight arguments); 116's stays as it was
-- based on: 116_asset_sync_load.sql
create or replace function cma.maintenance_page_of(p_tenant_id uuid, p_from_month date, p_months integer, p_market text, p_model text,
                                                   p_scope text, p_debt text, p_today date)
returns jsonb
language sql stable
as $$
  with b as materialized (
    select x.device_id, coalesce(x.market, 'unknown') as market, coalesce(x.model_key, 'unknown') as model_key, x.component_key, x.basis,
           x.exchange_on, x.bucket_on, x.exchange_bucket_on
    from cma.maintenance_bucket_dates_of(p_tenant_id, p_from_month, p_months, p_market, p_model, p_scope, p_debt, p_today) x
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
    select coalesce(dv.market, 'unknown') as market, coalesce(dv.model_key, 'unknown') as model_key, st.is_in_field, st.is_in_stock,
           dv.debt_status_key, coalesce(dd.pauses_maintenance, false) and st.is_in_field as paused
    from cma.device dv
    join cma.device_status st on st.tenant_id = dv.tenant_id and st.key = dv.device_status_key and st.is_tracked
    left join cma.device_debt_status dd on dd.tenant_id = dv.tenant_id and dd.key = dv.debt_status_key
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
                  and (p_market is null or t.market = p_market) and (p_model is null or t.model_key = p_model)
                  and cma.maintenance_debt_matches(p_debt, t.debt_status_key, t.paused)),
    -- 0009zl: the tracked devices of the scope, market and model whose debt status pauses maintenance (the page says how
    -- many the default leaves out), the filter as asked, and the catalog's statuses in their order for the selector
    'paused_devices', (select count(*) from tracked t
                       where (p_scope is null or (p_scope = 'field' and t.is_in_field) or (p_scope = 'stock' and t.is_in_stock))
                         and (p_market is null or t.market = p_market) and (p_model is null or t.model_key = p_model) and t.paused),
    'debt', p_debt,
    'debt_statuses', (select coalesce(jsonb_agg(jsonb_build_object('key', ds.key, 'name', ds.name, 'pauses_maintenance', ds.pauses_maintenance)
                                                order by ds.sort_order, ds.name collate "C", ds.key collate "C"), '[]'::jsonb)
                      from cma.device_debt_status ds where ds.tenant_id = p_tenant_id),
    'filter_markets', (select coalesce(jsonb_agg(f.market order by (f.market = 'unknown'), mk.sort_order, f.market), '[]'::jsonb)
                       from (select distinct t.market from tracked t) f left join mk on mk.code = f.market),
    'filter_models', (select coalesce(jsonb_agg(jsonb_build_object('key', f.model_key, 'name', md.name)
                                                order by (f.model_key = 'unknown'), md.sort_order, f.model_key), '[]'::jsonb)
                      from (select distinct t.model_key from tracked t) f left join md on md.key = f.model_key))
$$;

-- As 0008zk's (116), with the debt status filter, each row ending with its device's debt status key and
-- maintenance_paused (the list marks a paused device). A form of its own (eleven arguments); 116's stays as it was
-- based on: 116_asset_sync_load.sql
create or replace function cma.maintenance_rows_of(p_tenant_id uuid, p_from_month date, p_months integer, p_bucket text, p_market text,
                                                   p_model text, p_scope text, p_debt text, p_view text, p_limit integer, p_today date)
returns table (bucket text, device_id uuid, connection_id uuid, source_id text, serial text, model_key text, model_name text, market text,
               device_status_key text, device_status_name text, components text[], due_on date, bases text[], action_on date,
               exchange_on date, customer_ref text, subscription_ref text, crm_connection_id uuid, crm_contact_source_id text,
               total_rows bigint, debt_status_key text, maintenance_paused boolean)
language sql stable
as $$
  with b as (
    select x.device_id, x.connection_id, x.source_id, x.serial, x.model_key, x.market, x.device_status_key, x.component_key, x.component_order,
           x.due_on, x.basis, x.action_on, x.exchange_on,
           case when x.basis = 'unknown' then 'infinity'::date when p_view = 'exchanges' then x.exchange_bucket_on else x.bucket_on end as rb
    from cma.maintenance_bucket_dates_of(p_tenant_id, p_from_month, p_months, p_market, p_model, p_scope, p_debt, p_today) x
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
         ct.crm_contact_source_id, r.total_rows, dv.debt_status_key, coalesce(dd.pauses_maintenance and st.is_in_field, false)
  from r
  join cma.device dv on dv.tenant_id = p_tenant_id and dv.id = r.device_id
  left join cma.device_debt_status dd on dd.tenant_id = p_tenant_id and dd.key = dv.debt_status_key
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

-- Reports, Maintenance in one read with the debt status filter (0009zl): 0008zi's (112) with p_debt (null: every
-- device; unpaused, the report's default: no debt status that pauses maintenance; none: no debt status; any: a debt
-- status; else a debt status's key). Six arguments, none defaulted, so a call never matches both forms: 112's form (one
-- to five arguments, every device) stays for the web of main until this change deploys
-- based on: 112_assets.sql
create or replace function cma.maintenance_page(p_from_month date, p_months integer, p_market text, p_model text, p_scope text,
                                                p_debt text)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_today  date;
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  v_today := cma.tenant_today_of(v_tenant);
  perform cma.assert_maintenance_horizon(p_from_month, p_months, v_today);
  perform cma.assert_maintenance_filters(p_market, p_model, p_scope);
  perform cma.assert_maintenance_debt(v_tenant, p_debt);
  return cma.maintenance_page_of(v_tenant, p_from_month, p_months, p_market, p_model, p_scope, p_debt, v_today);
end
$$;

-- The device list of one cell with the debt status filter (0009zl): 0008zi's (112) with p_debt as the page's. Nine
-- arguments, none defaulted; 112's form (three to eight) stays for the web of main
-- based on: 112_assets.sql
create or replace function cma.maintenance_rows(p_from_month date, p_months integer, p_bucket text, p_market text, p_model text,
                                                p_scope text, p_debt text, p_view text, p_limit integer)
returns table (bucket text, device_id uuid, connection_id uuid, source_id text, serial text, model_key text, model_name text, market text,
               device_status_key text, device_status_name text, components text[], due_on date, bases text[], action_on date,
               exchange_on date, customer_ref text, subscription_ref text, crm_connection_id uuid, crm_contact_source_id text,
               total_rows bigint, debt_status_key text, maintenance_paused boolean)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_tenant uuid := cma.current_tenant_id();
  v_today  date;
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  v_today := cma.tenant_today_of(v_tenant);
  perform cma.assert_maintenance_horizon(p_from_month, p_months, v_today);
  perform cma.assert_maintenance_filters(p_market, p_model, p_scope);
  perform cma.assert_maintenance_debt(v_tenant, p_debt);
  if p_view is null or p_view not in ('exchanges', 'components') then
    raise exception 'the view is exchanges or components' using errcode = 'CMA04';
  end if;
  if p_limit is null or p_limit not between 1 and 5000 then
    raise exception 'the limit is 1 to 5000 rows' using errcode = 'CMA04';
  end if;
  if p_bucket is null
     or not (p_bucket in ('past_due', 'unknown', 'all')
             or (p_bucket ~ '^\d{4}-\d{2}-01$'
                 and p_bucket::date >= p_from_month and p_bucket::date < (p_from_month + make_interval(months => p_months))::date)) then
    raise exception 'the bucket is past_due, unknown, all or the first day of a month of the horizon' using errcode = 'CMA04';
  end if;
  return query
    select * from cma.maintenance_rows_of(v_tenant, p_from_month, p_months, p_bucket, p_market, p_model, p_scope, p_debt, p_view, p_limit, v_today);
exception when invalid_datetime_format or datetime_field_overflow then
  raise exception 'the bucket is past_due, unknown, all or the first day of a month of the horizon' using errcode = 'CMA04';
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 8. Data quality: device_debt_status_unmapped
-- ---------------------------------------------------------------------------------------------
-- As 0008zi (112), plus device_debt_status_unmapped after the device checks (305: the asset register's checks end at 300,
-- the cross-source checks begin at 310), shown as they are: once the tenant has an asset register set up, or while one
-- finds something
-- based on: 112_assets.sql
create or replace function cma.data_quality_assets_checks()
returns table (check_key text, sort_order integer, description text)
language sql immutable
as $$
  values
    ('device_serial_missing',                 230, 'Devices without a serial number'),
    ('device_serial_duplicate',               240, 'Devices whose serial number another device holds too, with the serial'),
    ('device_model_unmapped',                 250, 'Devices whose model maps to no catalog model, with the register''s label'),
    ('device_status_unmapped',                260, 'Devices whose status maps to no device status, with the register''s label'),
    ('device_market_unmapped',                270, 'Devices whose country maps to no catalog market, with the register''s label'),
    ('device_customer_ref_invalid',           280, 'Devices whose customer reference is no customer id'),
    ('component_due_unknown',                 290, 'Due items of tracked devices without a due date, with the component'),
    ('field_device_without_subscription_ref', 300, 'Devices in the field without a subscription reference'),
    ('device_debt_status_unmapped',           305, 'Devices whose debt status maps to no debt status of the catalog, with the register''s label')
$$;

-- As 0009zg's (214), with the check of 0009zl
-- based on: 214_source_figures.sql
create or replace function cma.data_quality_of(p_tenant_id uuid)
returns table (check_key text, connection_id uuid, object_type text, object_id text, value text)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_start   timestamptz;
  -- 0009o: read once per call, not per row: the market map (every value a record, contact, line or store writes, with
  -- the code the market rule gives it, cma.market_codes_of), the device-holding and the ended statuses
  v_codes   jsonb := (select coalesce(jsonb_object_agg(c.value, c.code), '{}'::jsonb) from cma.market_codes_of(p_tenant_id) c);
  v_holding text[] := cma.flash_holding_statuses_of(p_tenant_id);
  v_ended   text[] := cma.flash_ended_statuses_of(p_tenant_id);
  -- 0009zg: the tenant's today once, for the source figures' check (a function that reads a table, never inlined: a
  -- filter on it would call it once per row)
  v_today   date := cma.tenant_today_of(p_tenant_id);
begin
  select cma.setting_of(t.id, 'intake.start_date')::date::timestamp at time zone t.timezone into v_start
  from cma.tenant t where t.id = p_tenant_id;

  return query
  -- 0009o: the open tickets once (two checks read them)
  with ot as materialized (select * from cma.open_tickets_of(p_tenant_id))
  -- lead deals without any contact
  select 'deal_without_contact'::text, d.connection_id, d.record_type, d.source_id, null::text
  from cma.lead_deals_of(p_tenant_id, null, null) d
  where cardinality(d.contacts) = 0
  union all
  -- primary contacts of lead deals without country or language
  select 'deal_contact_incomplete', k.connection_id, 'contact', k.source_id, null
  from cma.crm_contact k
  where k.tenant_id = p_tenant_id and k.source_deleted_at is null
    and (k.country is null or k.language is null)
    and exists (select 1 from cma.lead_deals_of(p_tenant_id, null, null) d
                where d.connection_id = k.connection_id and d.contact_source_id = k.source_id)
  union all
  -- markets and countries written by a source that are no catalog market
  select 'market_not_in_catalog', cr.connection_id, cr.record_type, cr.source_id, cr.market
  from cma.crm_record cr
  where cr.tenant_id = p_tenant_id and cr.source_deleted_at is null and cr.source_created_at >= v_start
    and nullif(btrim(cr.market), '') is not null and (v_codes ->> cr.market) is null
  union all
  select 'market_not_in_catalog', k.connection_id, 'contact', k.source_id, k.country
  from cma.crm_contact k
  where k.tenant_id = p_tenant_id and k.source_deleted_at is null
    and nullif(btrim(k.country), '') is not null and (v_codes ->> k.country) is null
  union all
  -- CRM owners (of records since the start and of calls since the start) without a person
  select 'owner_without_person', o.connection_id, 'owner', o.owner_ref, null
  from (select cr.connection_id, cr.source_system, cr.owner_ref
        from cma.crm_record cr
        where cr.tenant_id = p_tenant_id and cr.source_deleted_at is null and cr.source_created_at >= v_start
          and cr.owner_ref is not null
        union
        select c.connection_id, c.source_system, c.owner_ref
        from cma.crm_call c
        where c.tenant_id = p_tenant_id and c.source_deleted_at is null and c.occurred_at >= v_start
          and c.owner_ref is not null) o
  where not exists (select 1 from cma.app_user_external_id x
                    where x.tenant_id = p_tenant_id and x.system = o.source_system || '_owner' and x.external_id = o.owner_ref)
  union all
  -- telephony users without a person
  select 'telephony_user_without_person', u.connection_id, 'telephony_user', u.user_ref, null
  from (select distinct tc.connection_id, tc.source_system, tc.user_ref
        from cma.telephony_call tc
        where tc.tenant_id = p_tenant_id and tc.source_deleted_at is null and tc.started_at >= v_start
          and tc.user_ref is not null) u
  where not exists (select 1 from cma.app_user_external_id x
                    where x.tenant_id = p_tenant_id and x.system = u.source_system || '_user' and x.external_id = u.user_ref)
  union all
  -- CRM calls without a current contact association
  select 'crm_call_without_contact', c.connection_id, 'crm_call', c.source_id, null
  from cma.crm_call c
  where c.tenant_id = p_tenant_id and c.source_deleted_at is null and c.occurred_at >= v_start
    and not exists (select 1 from cma.crm_association a
                    where a.tenant_id = c.tenant_id and a.connection_id = c.connection_id and a.from_type = 'crm_call'
                      and a.from_id = c.source_id and a.to_type = 'contact' and a.removed_at is null)
  union all
  -- telephony calls older than 24 hours without a current link, once the tenant has CRM calls; an
  -- outbound call not connected (no answer) and without a current tag is skipped when the connection says so
  -- (dq_unlinked_skip = outbound_unanswered_untagged, the default for a telephony connection; 0008o; 0008zc)
  select 'telephony_call_unlinked', tc.connection_id, 'telephony_call', tc.source_id, null
  from cma.telephony_call tc
  join cma.integration_connection ic on ic.tenant_id = tc.tenant_id and ic.id = tc.connection_id
  where tc.tenant_id = p_tenant_id and tc.source_deleted_at is null
    and tc.started_at >= v_start and tc.started_at < now() - interval '24 hours'
    and exists (select 1 from cma.crm_call c where c.tenant_id = p_tenant_id and c.source_deleted_at is null)
    and not exists (select 1 from cma.call_link l
                    where l.tenant_id = tc.tenant_id and l.telephony_call_id = tc.id and l.unlinked_at is null)
    and not (coalesce(ic.settings ->> 'dq_unlinked_skip', case when ic.kind = 'telephony' then 'outbound_unanswered_untagged' end) = 'outbound_unanswered_untagged'
             and tc.direction = 'outbound'
             and tc.answered_at is null
             and not exists (select 1 from cma.telephony_call_tag g
                             where g.tenant_id = tc.tenant_id and g.connection_id = tc.connection_id
                               and g.call_source_id = tc.source_id and g.untagged_at is null))
  union all
  -- commerce customers whose id no contact holds, or several contacts hold
  -- (since 0008zn the contacts per id counted once by a join, no read per customer; the same rows)
  select case when coalesce(h.contacts, 0) = 0 then 'commerce_unmatched' else 'commerce_ambiguous' end,
         cu.connection_id, 'commerce_customer', cu.source_id, null
  from cma.commerce_customer cu
  left join (select r.system, r.external_id, count(distinct r.contact_id) as contacts
             from cma.crm_contact_ref r where r.tenant_id = p_tenant_id group by 1, 2) h
    on h.system = cu.source_system and h.external_id = cu.source_id
  where cu.tenant_id = p_tenant_id and cu.source_deleted_at is null and coalesce(h.contacts, 0) <> 1
  union all
  -- contacts with both first slots of a ref system taken
  select 'contact_slots_full', k.connection_id, 'contact', k.source_id, r.system
  from cma.crm_contact k
  join cma.crm_contact_ref r on r.tenant_id = k.tenant_id and r.contact_id = k.id and r.slot in (1, 2)
  where k.tenant_id = p_tenant_id and k.source_deleted_at is null
  group by k.connection_id, k.source_id, r.system
  having count(distinct r.slot) = 2
  union all
  -- contacts whose country differs from the market of a store their commerce id belongs to
  select distinct 'contact_country_differs', k.connection_id, 'contact', k.source_id,
         (v_codes ->> k.country) || '/' || st.market
  from cma.crm_contact k
  join cma.crm_contact_ref r on r.tenant_id = k.tenant_id and r.contact_id = k.id
  join cma.commerce_customer cu
    on cu.tenant_id = r.tenant_id and cu.source_system = r.system and cu.source_id = r.external_id and cu.source_deleted_at is null
  join cma.commerce_store st on st.tenant_id = cu.tenant_id and st.connection_id = cu.connection_id
  where k.tenant_id = p_tenant_id and k.source_deleted_at is null
    and (v_codes ->> k.country) is distinct from st.market
    and nullif(btrim(k.country), '') is not null
  union all
  -- one commerce customer id in two or more stores
  select 'customer_in_two_stores', null::uuid, 'commerce_customer', cu.source_id, cu.source_system
  from cma.commerce_customer cu
  where cu.tenant_id = p_tenant_id and cu.source_deleted_at is null
  group by cu.source_system, cu.source_id
  having count(distinct cu.connection_id) > 1
  union all
  -- active pipelines no person has ever written (only the source's refresh)
  select 'pipeline_unreviewed', p.connection_id, 'pipeline', p.source_pipeline_id, p.record_type
  from cma.connection_pipeline p
  where p.tenant_id = p_tenant_id and p.status = 'active'
    and not exists (select 1 from cma.audit_log al
                    join cma.app_user u on u.tenant_id = al.tenant_id and u.id = al.actor_user_id and u.kind = 'person'
                    where al.tenant_id = p.tenant_id and al.table_name = 'connection_pipeline' and al.row_id = p.id::text)
  union all
  -- counted active forms without a market
  select 'form_without_market', f.connection_id, 'form', f.source_form_id, null
  from cma.connection_form f
  where f.tenant_id = p_tenant_id and f.status = 'active' and f.is_counted and f.market is null
  union all
  -- held contacts whose country came from a fallback slot (0008m)
  select 'contact_country_fallback', k.connection_id, 'contact', k.source_id, k.country_source::text
  from cma.crm_contact k
  where k.tenant_id = p_tenant_id and k.source_deleted_at is null and k.country_source > 1
  union all
  -- open tickets without an owner, and without a market, per pipeline, once ticket SLAs are configured (0008o)
  select 'ticket_no_owner', t.connection_id, 'ticket', t.ticket_source_id, t.pipeline_id
  from ot t
  where t.owner_ref is null and cma.follow_up_configured_of(p_tenant_id)
  union all
  select 'ticket_no_market', t.connection_id, 'ticket', t.ticket_source_id, t.pipeline_id
  from ot t
  where t.market = 'unknown' and cma.follow_up_configured_of(p_tenant_id)
  union all
  -- open tasks whose owner is not linked to a person (0008o)
  select 'crm_task_owner_unlinked', k.connection_id, 'task', k.task_source_id, k.owner_ref
  from cma.open_tasks_of(p_tenant_id) k
  where k.owner_ref is not null and k.owner_user_id is null
  union all
  -- kept form answers no option of their field accounts for, current or retired (0008p): one row per
  -- submission and field of a form the source has described, the field's name as the code
  select 'form_answer_not_in_options', fs.connection_id, 'form_submission', fs.source_id, e.key
  from cma.form_submission fs
  join cma.connection_form f
    on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
   and f.fields_refreshed_at is not null
  cross join lateral jsonb_each(fs.kept_values) e
  left join cma.connection_form_field ff
    on ff.tenant_id = fs.tenant_id and ff.connection_id = fs.connection_id and ff.source_form_id = fs.source_form_id
   and ff.name = e.key
  where fs.tenant_id = p_tenant_id and fs.kept_values <> '{}'::jsonb
    and (ff.name is null or not cma.form_choice_kind(ff.kind)
         or exists (select 1
                    from (select e.value #>> '{}' as v where jsonb_typeof(e.value) = 'string'
                          union all
                          select x from jsonb_array_elements_text(case when jsonb_typeof(e.value) = 'array' then e.value
                                                                       else '[]'::jsonb end) x) a
                    where not (a.v = any (ff.options || ff.retired_options))))
  union all
  -- review channels the source holds without a market (0008ze), with how many reviews the CMA holds of each
  select 'review_channel_unmapped', ch.connection_id, 'review_channel', ch.source_id,
         (select count(*) from cma.review r where r.tenant_id = ch.tenant_id and r.review_channel_id = ch.id)::text
  from cma.review_channel ch
  where ch.tenant_id = p_tenant_id and ch.source_deleted_at is null and ch.market is null
  union all
  -- active markets without a counted review channel, once the tenant has a reviews connection (0008ze)
  select 'market_without_review_channel', null::uuid, 'market', m.code, null::text
  from cma.market m
  where m.tenant_id = p_tenant_id and m.status = 'active' and cma.reviews_set_up_of(p_tenant_id)
    and not exists (select 1 from cma.review_channel ch
                    where ch.tenant_id = m.tenant_id and ch.market = m.code and ch.is_counted and ch.source_deleted_at is null)
  union all
  -- devices without a serial number (0008zi), of devices the register still holds
  select 'device_serial_missing', dv.connection_id, 'device', dv.source_id, null::text
  from cma.device dv
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.serial is null
  union all
  -- devices whose serial number another device of the tenant holds too (0008zi); the value is the serial
  select 'device_serial_duplicate', dv.connection_id, 'device', dv.source_id, dv.serial
  from cma.device dv
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.serial is not null
    and exists (select 1 from cma.device o
                where o.tenant_id = dv.tenant_id and o.serial = dv.serial and o.id <> dv.id and o.source_deleted_at is null)
  union all
  -- devices whose model, status or country maps to no catalog row (0008zi); the value is the register's label
  select 'device_model_unmapped', dv.connection_id, 'device', dv.source_id, dv.raw ->> 'model'
  from cma.device dv
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.model_key is null
  union all
  select 'device_status_unmapped', dv.connection_id, 'device', dv.source_id, dv.raw ->> 'status'
  from cma.device dv
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.device_status_key is null
  union all
  select 'device_market_unmapped', dv.connection_id, 'device', dv.source_id, dv.raw ->> 'country'
  from cma.device dv
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.market is null
  union all
  -- devices whose debt status label maps to no debt status of the catalog (0009zl): raw keeps a label only when the
  -- register gives one, so an empty field is never a finding; the value is the register's label
  select 'device_debt_status_unmapped', dv.connection_id, 'device', dv.source_id, dv.raw ->> 'debt_status'
  from cma.device dv
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.debt_status_key is null and dv.raw ? 'debt_status'
  union all
  -- devices whose register customer reference is no id (0008zi): the reference is never stored, so no value
  select 'device_customer_ref_invalid', dv.connection_id, 'device', dv.source_id, null::text
  from cma.device dv
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.customer_ref_invalid
  union all
  -- due items of tracked devices without a due date (basis unknown, 0008zi); the value is the component kind
  select 'component_due_unknown', i.connection_id, 'device', i.source_id, i.component_key
  from cma.maintenance_items_of(p_tenant_id, cma.tenant_today_of(p_tenant_id)) i
  where i.basis = 'unknown'
  union all
  -- devices in a status in the field without a subscription reference (0008zi): the rule's one implementation, which
  -- the Installed base's list reads too (0009f)
  select 'field_device_without_subscription_ref', u.connection_id, 'device', u.source_id, null::text
  from cma.field_devices_without_subscription_ref_of(p_tenant_id) u
  union all
  -- store customers with an order linked to a CRM contact that lacks a reference of commerce.required_contact_refs in
  -- every slot (0008zn); the value the references missing, comma-separated; contact_deleted when the CRM deleted the
  -- contact the link names (fixed in the CRM: the link or the contact); contact_not_held while the CMA does not hold the
  -- contact (its references are unknown until the contact is read)
  select 'customer_required_ref_missing', cu.connection_id, 'commerce_customer', cu.source_id,
         case when k.id is null then 'contact_not_held'
              when k.source_deleted_at is not null then 'contact_deleted'
              else array_to_string(array(select x from unnest(rq.refs) x
                                         where not exists (select 1 from cma.crm_contact_ref cr
                                                           where cr.tenant_id = k.tenant_id and cr.contact_id = k.id and cr.system = x)), ',') end
  from cma.commerce_customer cu
  cross join (select cma.flash_list_of(cma.setting_of(p_tenant_id, 'commerce.required_contact_refs')) as refs offset 0) rq
  left join cma.crm_contact k
    on k.tenant_id = cu.tenant_id and k.connection_id = cu.crm_connection_id and k.source_id = cu.crm_contact_source_id
  where cu.tenant_id = p_tenant_id and cu.source_deleted_at is null and cu.crm_contact_source_id is not null
    and coalesce(cu.orders_count, 0) >= 1 and cardinality(rq.refs) > 0
    and (k.id is null or k.source_deleted_at is not null
         or exists (select 1 from unnest(rq.refs) x
                    where not exists (select 1 from cma.crm_contact_ref cr
                                      where cr.tenant_id = k.tenant_id and cr.contact_id = k.id and cr.system = x)))
  union all
  -- devices the register still holds lacking a named id of assets.required_refs (0008zn); the value the ids missing
  select 'device_required_ref_missing', dv.connection_id, 'device', dv.source_id,
         array_to_string(array(select x from unnest(rq.refs) x where not (dv.external_refs ? x)), ',')
  from cma.device dv
  cross join (select cma.flash_list_of(cma.setting_of(p_tenant_id, 'assets.required_refs')) as refs offset 0) rq
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and cardinality(rq.refs) > 0
    and exists (select 1 from unnest(rq.refs) x where not (dv.external_refs ? x))
  union all
  -- subscriptions the latest full read still returns whose customer id no customer of their store holds (0008zn)
  select 'subscription_customer_unmatched', sb.connection_id, 'subscription', sb.source_id, null::text
  from cma.subscription sb
  -- the mapping fenced (offset 0): inlined, the planner guesses its few rows wrong and probes the customers per row
  join (select x.connection_id, x.store_connection_id from cma.flash_subscription_stores_of(p_tenant_id) x offset 0) sm
    on sm.connection_id = sb.connection_id
  left join (select cu.connection_id, cu.source_id from cma.commerce_customer cu
             where cu.tenant_id = p_tenant_id and cu.source_deleted_at is null) cu
    on cu.connection_id = sm.store_connection_id and cu.source_id = sb.customer_source_id
  where sb.tenant_id = p_tenant_id and sb.source_deleted_at is null and sb.customer_source_id is not null and cu.source_id is null
  union all
  -- subscriptions in a device-holding status (flash.device_holding_statuses since 0008zt; the key keeps 0008zn's word) of
  -- a store whose market the register holds devices of, that no device of that market the register still holds names by
  -- its subscription reference, once the tenant has an asset register set up; the value the status. A market without any
  -- device in the register (one it does not cover yet) gives no finding
  select 'active_subscription_without_device', sb.connection_id, 'subscription', sb.source_id, sb.status
  from cma.subscription sb
  join (select x.connection_id, x.market from cma.flash_subscription_stores_of(p_tenant_id) x offset 0) sm on sm.connection_id = sb.connection_id
  left join (select distinct d.market, d.subscription_ref from cma.device d
             where d.tenant_id = p_tenant_id and d.source_deleted_at is null and d.subscription_ref is not null) dr
    on dr.subscription_ref = sb.source_id and dr.market = sm.market
  where sb.tenant_id = p_tenant_id and sb.source_deleted_at is null and dr.subscription_ref is null
    and sb.status = any (v_holding) and cma.assets_set_up_of(p_tenant_id)
    -- the register's markets, once (a set, never a read per subscription)
    and sm.market in (select distinct d.market from cma.device d where d.tenant_id = p_tenant_id and d.source_deleted_at is null and d.market is not null)
  union all
  -- devices in a status in the field, of a market whose store's subscriptions the CMA reads, whose subscription
  -- reference names no subscription the CMA holds of that market (0008zn)
  select 'device_subscription_ref_unknown', dv.connection_id, 'device', dv.source_id, null::text
  from cma.device dv
  join cma.device_status st on st.tenant_id = dv.tenant_id and st.key = dv.device_status_key and st.is_in_field
  -- the subscriptions the CMA holds per market of their store, once (a set joined, never a read per device)
  left join (select distinct sm.market, sb.source_id
             from cma.subscription sb
             join (select y.connection_id, y.market from cma.flash_subscription_stores_of(p_tenant_id) y offset 0) sm on sm.connection_id = sb.connection_id
             where sb.tenant_id = p_tenant_id and sb.source_deleted_at is null) held
    on held.market = dv.market and held.source_id = dv.subscription_ref
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.subscription_ref is not null
    and dv.market in (select sm.market from cma.flash_subscription_stores_of(p_tenant_id) sm)
    and held.source_id is null
  union all
  -- devices in a status in the field linked to a subscription of their market in a status of
  -- flash.ended_subscription_statuses (0008zn); the value the subscription's status (the first by status when two
  -- subscriptions of the market share the id)
  select 'field_device_on_ended_subscription', dv.connection_id, 'device', dv.source_id, sb.status
  from cma.device dv
  join cma.device_status st on st.tenant_id = dv.tenant_id and st.key = dv.device_status_key and st.is_in_field
  join (select sm.market, x.source_id, min(x.status) as status
        from cma.subscription x
        join (select y.connection_id, y.market from cma.flash_subscription_stores_of(p_tenant_id) y offset 0) sm on sm.connection_id = x.connection_id
        where x.tenant_id = p_tenant_id and x.source_deleted_at is null and x.status = any (v_ended)
        group by 1, 2) sb on sb.source_id = dv.subscription_ref and sb.market = dv.market
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.subscription_ref is not null
  union all
  -- devices in a status in the field linked to a subscription of their market whose status is neither a device-holding
  -- one nor an ended one (0008zt: for Pulse4all paused, merged and never-subscribed; an ended one is the check above, so
  -- no device is listed twice); the value the subscription's status (the device's own subscription, as the installed base
  -- links it: the first by id when two subscriptions of the market share the id)
  select 'field_device_on_non_holding_subscription', dv.connection_id, 'device', dv.source_id, sb.status
  from cma.device dv
  join cma.device_status st on st.tenant_id = dv.tenant_id and st.key = dv.device_status_key and st.is_in_field
  join (select distinct on (sm.market, x.source_id) sm.market, x.source_id, x.status
        from cma.subscription x
        join (select y.connection_id, y.market from cma.flash_subscription_stores_of(p_tenant_id) y offset 0) sm on sm.connection_id = x.connection_id
        where x.tenant_id = p_tenant_id and x.source_deleted_at is null
        order by sm.market, x.source_id, x.id) sb on sb.source_id = dv.subscription_ref and sb.market = dv.market
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.subscription_ref is not null
    and not (sb.status = any (v_holding)) and not (sb.status = any (v_ended));

  -- variants on an active line without a mapping (0009ze): per variant the active lines (not canceled, still held, of a
  -- present subscription in a device-holding status); fixed in the CMA (the variant mapping)
  return query
  select 'subscription_variant_unmapped'::text, l.connection_id, 'variant'::text, l.variant_source_id, count(*)::text
  from cma.subscription_line l
  join cma.subscription s on s.tenant_id = l.tenant_id and s.connection_id = l.connection_id and s.source_id = l.subscription_source_id
  where l.tenant_id = p_tenant_id and l.canceled_at is null and l.source_deleted_at is null and l.variant_source_id is not null
    and s.source_deleted_at is null and s.status = any (v_holding)
    and not exists (select 1 from cma.subscription_variant_mapping m
                    where m.tenant_id = l.tenant_id and m.connection_id = l.connection_id and m.variant_source_id = l.variant_source_id)
  group by l.connection_id, l.variant_source_id;

  -- device units against the devices in the field (0009ze): a subscription in a device-holding status whose device units
  -- (known: no unmapped line) differ from the devices in the field linked to it as the installed base links them (its
  -- market and the device's subscription reference). One without any such device is active_subscription_without_device's,
  -- so none is listed twice. The value more_paid or more_placed; fixed in the asset register
  return query
  select 'subscription_device_units_mismatch'::text, sb.connection_id, 'subscription'::text, sb.source_id,
         case when sb.device_units > d.n then 'more_paid' else 'more_placed' end
  from (select x.connection_id, x.source_id, x.device_units, sm.market
        from cma.subscription x
        join (select y.connection_id, y.market from cma.flash_subscription_stores_of(p_tenant_id) y offset 0) sm on sm.connection_id = x.connection_id
        where x.tenant_id = p_tenant_id and x.source_deleted_at is null and x.device_units is not null and x.status = any (v_holding)) sb
  join (select dv.market, dv.subscription_ref, count(*) as n
        from cma.device dv
        join cma.device_status st on st.tenant_id = dv.tenant_id and st.key = dv.device_status_key and st.is_in_field
        where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.subscription_ref is not null
        group by 1, 2) d on d.market = sb.market and d.subscription_ref = sb.source_id
  where d.n <> sb.device_units;

  -- the subscription app's own figures against the CMA's (0009zg): per connection, figure and dims the latest date read
  -- in the last seven days (a stock figure's latest read, a flow's latest complete day, before today in the tenant's
  -- zone), listed when its gap exceeds both tolerances (cma.source_figure_rows_of). The id the figure and its status; the
  -- value the date and both values. Fixed in the subscriptions source (a missed read or a rule shows here first)
  return query
  select 'source_figure_gap'::text, g.connection_id, 'source_figure'::text,
         g.figure_key || coalesce(':' || (g.dims ->> 'status'), ''),
         g.business_date::text || ' source ' || trim_scale(g.source_value)::text || ' cma ' || trim_scale(g.cma_value)::text
  from (select distinct on (r.connection_id, r.figure_key, r.dims) r.connection_id, r.figure_key, r.dims, r.business_date,
               r.source_value, r.cma_value, r.state
        from cma.source_figure_rows_of(p_tenant_id, v_today - 7, v_today) r
        where r.kind = 'stock' or (r.kind = 'flow' and r.business_date < v_today)
        order by r.connection_id, r.figure_key, r.dims, r.business_date desc) g
  where g.state = 'gap';

  -- parked write-backs: the outbox arrives with migration 0007c (DESIGN §4.3a); until then the check
  -- finds nothing. Only the columns every outbox row has by design are read: id, connection, status
  if to_regclass('cma.outbox_action') is not null then
    return query execute
      'select ''writeback_parked''::text, o.connection_id, ''outbox_action''::text, o.id::text, null::text
       from cma.outbox_action o
       where o.tenant_id = $1 and o.status = ''needs_review'''
      using p_tenant_id;
  end if;
end
$$;

alter function cma.data_quality_of(uuid) set jit = off;

-- As 0009zg's (214): device_debt_status_unmapped is fixed in the asset register (an alias in the CMA's catalog, or the
-- label in the register: the register's own words)
-- based on: 214_source_figures.sql
create or replace function cma.data_quality_fix_in(p_check_key text, p_value text)
returns text
language sql immutable
as $$
  select case
    -- a contact not held yet is the CMA's to read; a deleted contact or a missing reference is the CRM's to fix
    when p_check_key = 'customer_required_ref_missing' then case when p_value = 'contact_not_held' then 'cma' else 'crm' end
    when p_check_key in ('deal_without_contact', 'deal_contact_incomplete', 'crm_call_without_contact', 'commerce_unmatched',
                         'commerce_ambiguous', 'contact_slots_full', 'contact_country_differs', 'contact_country_fallback',
                         'ticket_no_owner', 'ticket_no_market', 'telephony_call_unlinked') then 'crm'
    when p_check_key in ('customer_in_two_stores', 'subscription_customer_unmatched') then 'commerce'
    when p_check_key in ('device_serial_missing', 'device_serial_duplicate', 'device_model_unmapped', 'device_status_unmapped',
                         'device_market_unmapped', 'device_customer_ref_invalid', 'component_due_unknown',
                         'field_device_without_subscription_ref', 'device_required_ref_missing', 'active_subscription_without_device',
                         'device_subscription_ref_unknown', 'field_device_on_ended_subscription', 'field_device_on_non_holding_subscription',
                         'subscription_device_units_mismatch', 'device_debt_status_unmapped') then 'assets'
    -- the subscription app's own figures (0009zg): a missed read or a rule of the subscriptions source
    when p_check_key = 'source_figure_gap' then 'subscriptions'
    else 'cma' end
$$;

-- ---------------------------------------------------------------------------------------------
-- 9. The installed base: under_debt_status and the debt status
-- ---------------------------------------------------------------------------------------------
-- As 0008zy (146), with the installed base's dim debt_status (a debt status's key, none without one), its set
-- [market, model, debt_status] and the measure under_debt_status (devices in the field with a debt status)
-- based on: 146_installed_base_models.sql
create or replace function cma.flash_overviews()
returns table (key text, sort_order integer, kind text, source text, dims text[], sets jsonb, measures text[], count_measures text[],
               headline text, sorts text[])
language sql immutable
as $$
  values
    ('customers', 10, 'stock', 'commerce', array['market', 'store', 'segment'], '[[], ["market"], ["market", "store"], ["market", "segment"]]'::jsonb,
       array['customers_held', 'active_customers', 'paused_customers', 'linked_to_contact', 'with_required_refs'],
       array['customers_held', 'active_customers', 'paused_customers', 'linked_to_contact', 'with_required_refs'], 'active_customers',
       array['lifetime_orders', 'total_spent', 'customer_id', 'store', 'market', 'active_subscriptions', 'devices']),
    ('subscriptions', 20, 'stock', 'subscriptions', array['market', 'store', 'status', 'payment_state', 'device_band', 'age_band'],
       '[[], ["market"], ["market", "status"], ["market", "store", "status", "payment_state"], ["market", "device_band"], ["market", "age_band"]]'::jsonb,
       array['subscriptions', 'active_subscriptions', 'paused_subscriptions', 'amount_per_cycle', 'holding_subscriptions', 'devices_on_holding',
             'devices_per_holding_subscription'],
       array['subscriptions', 'active_subscriptions', 'paused_subscriptions', 'holding_subscriptions', 'devices_on_holding'], 'holding_subscriptions',
       array['subscription_id', 'store', 'market', 'status', 'payment_state', 'amount_per_cycle', 'next_billing_at', 'retry_since', 'devices']),
    ('installed_base', 30, 'stock', 'assets', array['market', 'status', 'model', 'warehouse', 'link', 'subscription_status', 'debt_status'],
       '[[], ["market"], ["market", "status", "model", "warehouse", "link"], ["market", "model", "subscription_status"], ["market", "model", "debt_status"]]'::jsonb,
       array['devices', 'in_field', 'in_stock', 'components_past_due', 'items_due_3m', 'in_field_on_holding', 'under_debt_status'],
       array['devices', 'in_field', 'in_stock', 'components_past_due', 'items_due_3m', 'in_field_on_holding', 'under_debt_status'], 'in_field',
       array['serial', 'model', 'market', 'status', 'warehouse', 'past_due_items', 'next_due_on']),
    ('churn', 40, 'flow', 'subscriptions', array['market', 'store', 'reason'], '[[], ["market"], ["market", "store", "reason"]]'::jsonb,
       array['churned'], array['churned'], 'churned',
       array['churned_at', 'subscription_id', 'store', 'market', 'reason', 'cycles']),
    ('orders', 50, 'flow', 'commerce', array['market', 'store', 'kind', 'sku'],
       '[[], ["market"], ["market", "store", "kind"], ["market", "sku"]]'::jsonb,
       array['orders', 'units', 'amount'], array['orders'], 'orders',
       array['created_at', 'order_number', 'store', 'market', 'kind', 'total']),
    ('payments', 60, 'flow', 'commerce', array['market', 'store', 'kind', 'status'],
       '[[], ["market"], ["market", "store", "kind", "status"]]'::jsonb,
       array['orders', 'amount', 'renewals', 'failed_renewals'], array['orders', 'renewals', 'failed_renewals'], 'failed_renewals',
       array['at', 'kind', 'status', 'amount', 'store', 'market']),
    ('open_deals', 70, 'stock', 'crm', array['market', 'pipeline', 'stage'], '[[], ["market"], ["market", "pipeline", "stage"]]'::jsonb,
       array['open_deals', 'median_age_days', 'oldest_age_days'], array['open_deals'], 'open_deals',
       array['age_days', 'created_at', 'record_id', 'pipeline', 'stage', 'market']),
    ('open_tickets', 80, 'stock', 'crm', array['market', 'queue', 'stage'], '[[], ["market"], ["market", "queue", "stage"]]'::jsonb,
       array['open_tickets', 'median_age_days', 'oldest_age_days'], array['open_tickets'], 'open_tickets',
       array['age_days', 'created_at', 'record_id', 'queue', 'stage', 'market']),
    ('open_tasks', 90, 'stock', 'crm', array['market', 'type', 'status'], '[[], ["market"], ["market", "type", "status"]]'::jsonb,
       array['open_tasks', 'overdue'], array['open_tasks', 'overdue'], 'open_tasks',
       array['due_at', 'task_id', 'type', 'status', 'market']),
    ('reviews', 100, 'flow', 'reviews', array['market', 'rating'], '[[], ["market"], ["market", "rating"]]'::jsonb,
       array['reviews', 'rating_sum', 'negative'], array['reviews', 'negative'], 'reviews',
       array['submitted_at', 'rating', 'market', 'review_id']),
    ('data_quality', 110, 'stock', null, array['check', 'market'], '[[], ["market"], ["check"], ["check", "market"]]'::jsonb,
       array['findings'], array['findings'], 'findings',
       array['object_id', 'check', 'market'])
$$;

-- As 0009p (180), with the installed base's measure under_debt_status in every set and the set
-- [market, model, debt_status]; every other overview's statement is unchanged
-- based on: 180_flash_stored_cards.sql
create or replace function cma.flash_compute_of(p_tenant_id uuid, p_overview text, p_from date default null, p_to date default null,
                                                p_on date default null)
returns table (dims jsonb, measures jsonb)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_src   text := (select o.source from cma.flash_overviews() o where o.key = p_overview);
  -- today once, a value (a function call passed on would be evaluated per row where the base sets inline it)
  v_today date := cma.tenant_today_of(p_tenant_id);
  v_from  date := coalesce(p_from, v_today);
  v_to    date := coalesce(p_to, p_from, v_today);
  -- the stock figures' date and instant: today and now live; the snapshot's date and its end (the next day's 00:00 in
  -- the tenant's zone) in a take
  v_on    date := coalesce(p_on, v_today);
  v_at    timestamptz := case when p_on is null then now()
                              else ((p_on + 1)::timestamp at time zone (select t.timezone from cma.tenant t where t.id = p_tenant_id)) end;
  -- with_required_refs applies only while a contact reference is required
  v_refs_required boolean := cardinality(cma.flash_list_of(cma.setting_of(p_tenant_id, 'commerce.required_contact_refs'))) > 0;
  -- the bands of the active subscriptions (0008zt): every band of the settings has its row per market, zeros included
  v_device_bands  integer[] := cma.flash_bounds_of(cma.setting_of(p_tenant_id, 'flash.device_bands'));
  v_ages          integer[] := cma.flash_bounds_of(cma.setting_of(p_tenant_id, 'flash.subscription_age_months'));
  -- a device is on a device-holding subscription when its subscription status is a holding one (0008zt)
  v_holding       text[] := cma.flash_holding_statuses_of(p_tenant_id);
begin
  perform cma.assert_flash_overview(p_overview);
  -- one source's set-up (cma.flash_source_set_up_of, 0008zz: the derivation cma.flash_sources_of takes its set_up from),
  -- not every source's adapters and last read: that was a max over cma.sync_run per source on every computation
  if v_src is not null and not coalesce(cma.flash_source_set_up_of(p_tenant_id, v_src), false) then
    return;
  end if;
  if p_overview = 'customers' then
    return query
      select case when grouping(b.market) = 1 then '{}'::jsonb
                  when grouping(b.store) = 0 then jsonb_build_object('market', b.market, 'store', b.store)
                  when grouping(b.segment) = 0 then jsonb_build_object('market', b.market, 'segment', b.segment)
                  else jsonb_build_object('market', b.market) end,
             jsonb_build_object('customers_held', count(*),
                                -- a customer with a subscription in a device-holding status (0008zu: a failed one counts),
                                -- paused when its subscriptions are paused and none holds devices
                                'active_customers', count(*) filter (where b.holding_subscriptions > 0),
                                'paused_customers', count(*) filter (where b.holding_subscriptions = 0 and b.paused_subscriptions > 0),
                                'linked_to_contact', count(*) filter (where b.contact_source_id is not null))
             || case when v_refs_required
                     then jsonb_build_object('with_required_refs', count(*) filter (where b.contact_source_id is not null and b.contact_held
                                                                                     and cardinality(b.missing_refs) = 0))
                     else '{}'::jsonb end
      from cma.flash_customer_figures_of(p_tenant_id) b
      group by grouping sets ((), (b.market), (b.market, b.store), (b.market, b.segment));
  elsif p_overview = 'subscriptions' then
    -- the base set read once (measured against v_on: the age bands), for the totals, per market, the breakdown and the
    -- bands; holding_subscriptions and devices_on_holding count the device-holding subscriptions and their devices in the
    -- field (0008zt), their ratio is left out of a row without a holding subscription (null, never 0); the device bands are
    -- the holding subscriptions', the age bands the active ones'
    return query
      with b as materialized (
        select x.market, x.store, x.status, x.payment_state, x.currency, x.is_active, x.is_holding, x.amount_per_cycle, x.devices_in_field,
               x.age_band, x.device_band
        from cma.flash_subscriptions_of(p_tenant_id, v_on) x
      ), a as (
        select case when grouping(b.market) = 1 then '{}'::jsonb
                    when grouping(b.store) = 1 then jsonb_build_object('market', b.market)
                    else jsonb_build_object('market', b.market, 'store', b.store, 'status', b.status, 'payment_state', b.payment_state) end as dims,
               b.currency, count(*) as n, count(*) filter (where b.is_active) as act, count(*) filter (where b.status = 'paused') as paused,
               -- the active subscriptions' amounts only, each for its own billing cycle (Flash overview measures)
               sum(b.amount_per_cycle) filter (where b.is_active) as amount,
               count(*) filter (where b.is_holding) as hold,
               coalesce(sum(b.devices_in_field) filter (where b.is_holding), 0) as dev
        from b
        group by grouping sets ((b.currency), (b.market, b.currency), (b.market, b.store, b.status, b.payment_state, b.currency))
      ), bands as (
        -- the holding subscriptions per market and device band with their devices in the field; the active ones per age band
        select b.market, 'device_band'::text as dim, b.device_band as band, count(*) as n, sum(b.devices_in_field) as dev
        from b where b.is_holding group by 1, 2, 3
        union all
        select b.market, 'age_band', b.age_band, count(*), null from b where b.is_active group by 1, 2, 3
      ), labels as (
        -- every band of the settings for each market with a subscription it counts (unknown only when a subscription has it)
        select m.market, 'device_band'::text as dim, x as band
        from (select distinct b.market from b where b.is_holding) m cross join unnest(cma.flash_count_bands_of(v_device_bands)) x
        union all
        select m.market, 'age_band', x
        from (select distinct b.market from b where b.is_active) m cross join unnest(cma.flash_age_bands_of(v_ages)) x
      )
      select a.dims, jsonb_build_object('subscriptions', sum(a.n), 'active_subscriptions', sum(a.act), 'paused_subscriptions', sum(a.paused),
                                        'amount_per_cycle', coalesce(jsonb_object_agg(a.currency, round(a.amount, 2))
                                                                       filter (where a.currency is not null and a.amount is not null), '{}'::jsonb),
                                        'holding_subscriptions', sum(a.hold), 'devices_on_holding', sum(a.dev))
                     || jsonb_strip_nulls(jsonb_build_object('devices_per_holding_subscription', cma.flash_ratio_of(sum(a.dev), sum(a.hold))))
      from a group by a.dims
      union all
      select jsonb_build_object('market', coalesce(n.market, l.market), coalesce(n.dim, l.dim), coalesce(n.band, l.band)),
             case when coalesce(n.dim, l.dim) = 'age_band' then jsonb_build_object('active_subscriptions', coalesce(n.n, 0))
                  else jsonb_build_object('holding_subscriptions', coalesce(n.n, 0), 'devices_on_holding', coalesce(n.dev, 0))
                       || jsonb_strip_nulls(jsonb_build_object('devices_per_holding_subscription', cma.flash_ratio_of(coalesce(n.dev, 0), coalesce(n.n, 0))))
             end
      from labels l
      full join bands n on n.market = l.market and n.dim = l.dim and n.band = l.band
      union all
      -- Total subscriptions' split (0008zu): the device-holding subscriptions per market and status, every status of
      -- flash.device_holding_statuses for each market with a holding subscription (zeros included), so they add up to the
      -- market's holding_subscriptions; the setting holds the subscription app's status words alone (0008zt's check), so a
      -- split row's dim is always such a word
      select jsonb_build_object('market', m.market, 'status', h.status), jsonb_build_object('holding_subscriptions', coalesce(n.n, 0))
      from (select distinct b.market from b where b.is_holding) m
      cross join unnest(v_holding) h(status)
      left join (select b.market, b.status, count(*) as n from b where b.is_holding group by 1, 2) n on n.market = m.market and n.status = h.status;
    if not found then
      return query select '{}'::jsonb, jsonb_build_object('subscriptions', 0, 'active_subscriptions', 0, 'paused_subscriptions', 0,
                                                          'amount_per_cycle', '{}'::jsonb, 'holding_subscriptions', 0, 'devices_on_holding', 0);
    end if;
  elsif p_overview = 'installed_base' then
    return query
      select case when grouping(b.market) = 1 then '{}'::jsonb
                  when grouping(b.status) = 0
                  then jsonb_build_object('market', b.market, 'status', b.status, 'model', b.model, 'warehouse', b.warehouse, 'link', b.link)
                  -- the model beside the subscription status since 0008zy, so the set follows a Model filter
                  when grouping(b.subscription_status) = 0
                  then jsonb_build_object('market', b.market, 'model', b.model, 'subscription_status', b.subscription_status)
                  -- 0009zl: the debt status beside the model, so the set follows a Model filter
                  when grouping(b.debt_status) = 0
                  then jsonb_build_object('market', b.market, 'model', b.model, 'debt_status', b.debt_status)
                  else jsonb_build_object('market', b.market) end,
             jsonb_build_object('devices', count(*), 'in_field', count(*) filter (where b.is_in_field),
                                'in_stock', count(*) filter (where b.is_in_stock), 'components_past_due', coalesce(sum(b.past_due_items), 0),
                                'items_due_3m', coalesce(sum(b.items_due_3m), 0),
                                -- devices in the field on a device-holding subscription (0008zt): never one in stock, whatever its reference
                                'in_field_on_holding', count(*) filter (where b.is_in_field and b.subscription_status = any (v_holding)),
                                -- devices in the field under a debt status (0009zl): the register's field, whatever it pauses
                                'under_debt_status', count(*) filter (where b.is_in_field and b.debt_status <> 'none'))
      -- the device's debt status key as the register's last read stored it (none without one), by the primary key
      from (select f.*, coalesce(dv.debt_status_key, 'none') as debt_status
            from cma.flash_devices_of(p_tenant_id, v_on) f
            left join cma.device dv on dv.tenant_id = p_tenant_id and dv.id = f.device_id) b
      group by grouping sets ((), (b.market), (b.market, b.status, b.model, b.warehouse, b.link), (b.market, b.model, b.subscription_status),
                              (b.market, b.model, b.debt_status));
  elsif p_overview = 'churn' then
    return query
      select case when grouping(b.market) = 1 then '{}'::jsonb
                  when grouping(b.store) = 1 then jsonb_build_object('market', b.market)
                  else jsonb_build_object('market', b.market, 'store', b.store, 'reason', b.reason) end,
             jsonb_build_object('churned', count(*))
      from cma.flash_churn_of(p_tenant_id, v_from, v_to) b
      group by grouping sets ((), (b.market), (b.market, b.store, b.reason));
  elsif p_overview = 'orders' then
    return query
      -- orders and amounts from the orders (their lines not read), units from the lines, read once for the units and the
      -- SKU rows alike: an order's units are the sum of its lines' quantities, so the sums per set are the same
      with ol as materialized (
        select l.order_id, l.store, l.market, l.kind, l.sku, l.units from cma.flash_order_lines_of(p_tenant_id, v_from, v_to) l
      ), a as (
        select case when grouping(b.market) = 1 then '{}'::jsonb
                    when grouping(b.store) = 1 then jsonb_build_object('market', b.market)
                    else jsonb_build_object('market', b.market, 'store', b.store, 'kind', b.kind) end as dims,
               b.currency, count(*) as n, sum(b.total) as amount
        from cma.flash_orders_of(p_tenant_id, v_from, v_to) b
        group by grouping sets ((b.currency), (b.market, b.currency), (b.market, b.store, b.kind, b.currency))
      ), u as materialized (
        select case when grouping(l.market) = 1 then '{}'::jsonb
                    when grouping(l.store) = 1 then jsonb_build_object('market', l.market)
                    else jsonb_build_object('market', l.market, 'store', l.store, 'kind', l.kind) end as dims,
               sum(l.units) as units
        from ol l
        group by grouping sets ((), (l.market), (l.market, l.store, l.kind))
      )
      select a.dims, jsonb_build_object('orders', sum(a.n), 'units', coalesce((select u.units from u where u.dims = a.dims), 0),
                                        'amount', coalesce(jsonb_object_agg(a.currency, round(a.amount, 2))
                                                             filter (where a.currency is not null and a.amount is not null), '{}'::jsonb))
      from a group by a.dims
      union all
      select jsonb_build_object('market', l.market, 'sku', l.sku), jsonb_build_object('orders', count(distinct l.order_id), 'units', sum(l.units))
      from ol l
      group by l.market, l.sku;
    if not found then
      return query select '{}'::jsonb, jsonb_build_object('orders', 0, 'units', 0, 'amount', '{}'::jsonb);
    end if;
  elsif p_overview = 'payments' then
    return query
      with a as (
        select case when grouping(b.market) = 1 then '{}'::jsonb
                    when grouping(b.store) = 1 then jsonb_build_object('market', b.market)
                    else jsonb_build_object('market', b.market, 'store', b.store, 'kind', b.kind, 'status', b.status) end as dims,
               b.currency, count(*) filter (where b.kind = 'order') as orders, sum(b.amount) filter (where b.kind = 'order') as amount,
               count(*) filter (where b.kind = 'renewal' and b.status = 'renewed') as renewals,
               count(*) filter (where b.kind = 'renewal' and b.status = 'renew_failed') as failed
        from cma.flash_payments_of(p_tenant_id, v_from, v_to) b
        group by grouping sets ((b.currency), (b.market, b.currency), (b.market, b.store, b.kind, b.status, b.currency))
      )
      select a.dims, jsonb_build_object('orders', sum(a.orders), 'renewals', sum(a.renewals), 'failed_renewals', sum(a.failed),
                                        'amount', coalesce(jsonb_object_agg(a.currency, round(a.amount, 2))
                                                             filter (where a.currency is not null and a.amount is not null), '{}'::jsonb))
      from a group by a.dims;
    if not found then
      return query select '{}'::jsonb, jsonb_build_object('orders', 0, 'renewals', 0, 'failed_renewals', 0, 'amount', '{}'::jsonb);
    end if;
  elsif p_overview = 'open_deals' then
    return query
      select case when grouping(b.market) = 1 then '{}'::jsonb
                  when grouping(b.pipeline) = 1 then jsonb_build_object('market', b.market)
                  else jsonb_build_object('market', b.market, 'pipeline', b.pipeline, 'stage', b.stage) end,
             jsonb_strip_nulls(jsonb_build_object('open_deals', count(*),
                                'median_age_days', round((percentile_cont(0.5) within group (order by b.age_days))::numeric, 1),
                                'oldest_age_days', max(b.age_days)))
      from cma.flash_deals_of(p_tenant_id, v_at) b
      group by grouping sets ((), (b.market), (b.market, b.pipeline, b.stage));
  elsif p_overview = 'open_tickets' then
    return query
      select case when grouping(b.market) = 1 then '{}'::jsonb
                  when grouping(b.queue) = 1 then jsonb_build_object('market', b.market)
                  else jsonb_build_object('market', b.market, 'queue', b.queue, 'stage', b.stage) end,
             jsonb_strip_nulls(jsonb_build_object('open_tickets', count(*),
                                'median_age_days', round((percentile_cont(0.5) within group (order by b.age_days))::numeric, 1),
                                'oldest_age_days', max(b.age_days)))
      from cma.flash_tickets_of(p_tenant_id, v_at) b
      group by grouping sets ((), (b.market), (b.market, b.queue, b.stage));
  elsif p_overview = 'open_tasks' then
    return query
      select case when grouping(b.market) = 1 then '{}'::jsonb
                  when grouping(b.type) = 1 then jsonb_build_object('market', b.market)
                  else jsonb_build_object('market', b.market, 'type', b.type, 'status', b.status) end,
             jsonb_build_object('open_tasks', count(*), 'overdue', count(*) filter (where b.overdue))
      from cma.flash_tasks_of(p_tenant_id, v_on) b
      group by grouping sets ((), (b.market), (b.market, b.type, b.status));
  elsif p_overview = 'reviews' then
    return query
      select case when grouping(b.market) = 1 then '{}'::jsonb
                  when grouping(b.stars) = 1 then jsonb_build_object('market', b.market)
                  else jsonb_build_object('market', b.market, 'rating', b.stars::text) end,
             jsonb_build_object('reviews', count(*), 'rating_sum', coalesce(sum(b.rating), 0), 'negative', count(*) filter (where b.is_negative))
      from cma.flash_reviews_of(p_tenant_id, v_from, v_to) b
      group by grouping sets ((), (b.market), (b.market, b.stars));
  elsif p_overview = 'data_quality' then
    -- counted per check and market first (a few rows), then the grouping sets over those counts
    return query
      select case when grouping(b.check_key) = 1 and grouping(b.market) = 1 then '{}'::jsonb
                  when grouping(b.check_key) = 1 then jsonb_build_object('market', b.market)
                  when grouping(b.market) = 1 then jsonb_build_object('check', b.check_key)
                  else jsonb_build_object('check', b.check_key, 'market', b.market) end,
             jsonb_build_object('findings', coalesce(sum(b.n), 0))
      from (select f.check_key, f.market, count(*) as n from cma.flash_findings_of(p_tenant_id) f group by 1, 2) b
      group by grouping sets ((), (b.market), (b.check_key), (b.check_key, b.market));
  end if;
end
$$;

-- a function made again loses its settings: JIT off, as 146 and 180 set it
alter function cma.flash_compute_of(uuid, text, date, date, date) set jit = off;

-- The installed base gains a measure and a set from this addition on: its definition version moves, so the watch
-- compares no installed base across the change and a current take of 0009ze is not read (the page reads live until the
-- next refresh); the subscriptions keep 0009ze's
-- based on: 210_subscription_facts.sql
create or replace function cma.flash_definition_version(p_overview text)
returns text
language sql immutable
as $$
  select case when p_overview = 'installed_base' then '0009zl'
              when p_overview = 'subscriptions' then '0009ze'
              when p_overview = 'customers' then '0008zu'
              when p_overview in (select o.key from cma.flash_overviews() o) then '0008zn' end
$$;

-- As 0008zn (122), with the installed base's debt statuses (names, and the sort order the selector follows)
-- based on: 122_flash.sql
create or replace function cma.flash_labels_of(p_tenant_id uuid, p_overview text)
returns jsonb
language sql stable
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'market', (select jsonb_object_agg(m.code, m.name) from cma.market m where m.tenant_id = p_tenant_id),
    'store', case when p_overview in ('customers', 'subscriptions', 'churn', 'orders', 'payments')
                  then (select jsonb_object_agg(st.handle, st.name) from cma.commerce_store st where st.tenant_id = p_tenant_id) end,
    'status', case p_overview
                when 'installed_base' then (select jsonb_object_agg(ds.key, ds.name) from cma.device_status ds where ds.tenant_id = p_tenant_id)
                when 'open_tasks' then (select jsonb_object_agg(ts.status_ref, ts.label) from cma.connection_task_status ts where ts.tenant_id = p_tenant_id) end,
    'model', case when p_overview = 'installed_base'
                  then (select jsonb_object_agg(dm.key, dm.name) from cma.device_model dm where dm.tenant_id = p_tenant_id) end,
    -- 0009zl: the debt statuses' names, and their sort order as text (an object holds no order) for the page's selector
    'debt_status', case when p_overview = 'installed_base'
                        then (select jsonb_object_agg(dd.key, dd.name) from cma.device_debt_status dd where dd.tenant_id = p_tenant_id) end,
    'debt_status_order', case when p_overview = 'installed_base'
                              then (select jsonb_object_agg(dd.key, dd.sort_order::text) from cma.device_debt_status dd where dd.tenant_id = p_tenant_id) end,
    'pipeline', case when p_overview = 'open_deals'
                     then (select jsonb_object_agg(p.source_pipeline_id, p.label) from cma.connection_pipeline p
                           where p.tenant_id = p_tenant_id and p.record_type = 'deal') end,
    'queue', case when p_overview = 'open_tickets'
                  then (select jsonb_object_agg(p.source_pipeline_id, p.label) from cma.connection_pipeline p
                        where p.tenant_id = p_tenant_id and p.record_type = 'ticket') end,
    'stage', case when p_overview in ('open_deals', 'open_tickets')
                  then (select jsonb_object_agg(cs.source_pipeline_id || ':' || cs.source_stage_id, cs.label) from cma.connection_stage cs
                        where cs.tenant_id = p_tenant_id and cs.record_type = case p_overview when 'open_deals' then 'deal' else 'ticket' end) end,
    'type', case when p_overview = 'open_tasks'
                 then (select jsonb_object_agg(tt.type_ref, tt.label) from cma.connection_task_type tt where tt.tenant_id = p_tenant_id) end,
    'check', case when p_overview = 'data_quality'
                  then (select jsonb_object_agg(c.check_key, c.description) from cma.data_quality_catalog() c) end))
$$;

-- As 0009f (160), with the installed base's debt status: the filter debt_status (a key, none or any), the measure
-- under_debt_status, and each row's debt status key (the page's rows only); every other overview's statement is unchanged
-- based on: 160_installed_base_now.sql
create or replace function cma.flash_rows_of(p_tenant_id uuid, p_overview text, p_filters jsonb, p_sort text, p_descending boolean,
                                             p_limit integer, p_offset integer, p_from date, p_to date)
returns jsonb
language plpgsql stable
as $$
declare
  v_order text := cma.flash_order_by(p_overview, p_sort, p_descending);
  v_today date := cma.tenant_today_of(p_tenant_id);
  v_from  date := coalesce(p_from, v_today);
  v_to    date := coalesce(p_to, p_from, v_today);
  v_src   text := (select o.source from cma.flash_overviews() o where o.key = p_overview);
  v_base  text;
  v_where text;
  v_obj   text;
  v_res   jsonb;
  v_extra text := '';      -- columns the page adds after the filter and the paging (0008zz)
  v_page  text := 'p x';   -- the page and what it joins (0008zz)
begin
  if v_order is null then
    raise exception 'sort % is not a sort key of %', p_sort, p_overview using errcode = 'CMA04';
  end if;
  if v_src is not null and not coalesce(cma.flash_source_set_up_of(p_tenant_id, v_src), false) then
    return jsonb_build_object('total', 0, 'rows', '[]'::jsonb);
  end if;
  case p_overview
    when 'customers' then
      v_base := 'cma.flash_customer_figures_of($2)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''store'' is null or x.store = $1 ->> ''store'')
                  and ($1 ->> ''segment'' is null or x.segment = $1 ->> ''segment'')
                  and case $1 ->> ''measure'' when ''active_customers'' then x.holding_subscriptions > 0
                                              when ''paused_customers'' then x.holding_subscriptions = 0 and x.paused_subscriptions > 0
                                              when ''linked_to_contact'' then x.contact_source_id is not null
                                              when ''with_required_refs'' then x.contact_source_id is not null and x.contact_held and cardinality(x.missing_refs) = 0
                                              else true end';
      v_obj := 'jsonb_build_object(''customer_id'', x.source_id, ''connection_id'', x.connection_id, ''store'', x.store, ''market'', x.market,
                  ''contact_id'', x.contact_source_id, ''contact_url'', cma.record_url(x.crm_connection_id, ''contact'', x.contact_source_id),
                  ''contact_held'', x.contact_held, ''refs'', x.refs, ''missing_refs'', to_jsonb(x.missing_refs),
                  ''lifetime_orders'', x.lifetime_orders, ''total_spent'', x.total_spent, ''currency'', x.currency,
                  ''active_subscriptions'', x.active_subscriptions, ''paused_subscriptions'', x.paused_subscriptions, ''devices'', x.devices,
                  ''holding_subscriptions'', x.holding_subscriptions,
                  ''order_ids'', (select coalesce(jsonb_agg(q.n order by q.at desc, q.n), ''[]''::jsonb)
                                 from (select coalesce(o.order_name, o.source_id) as n, o.source_created_at as at from cma.commerce_order o
                                       where o.tenant_id = $2 and o.connection_id = x.connection_id and o.customer_source_id = x.source_id
                                         and o.source_deleted_at is null order by o.source_created_at desc, o.source_id limit 20) q),
                  ''orders_held'', (select count(*) from cma.commerce_order o where o.tenant_id = $2 and o.connection_id = x.connection_id
                                     and o.customer_source_id = x.source_id and o.source_deleted_at is null),
                  ''subscription_ids'', (select coalesce(jsonb_agg(q.source_id order by q.source_id), ''[]''::jsonb)
                                        from (select sb.source_id from cma.subscription sb join sm on sm.connection_id = sb.connection_id
                                              where sb.tenant_id = $2 and sm.store_connection_id = x.connection_id and sb.customer_source_id = x.source_id
                                                and sb.source_deleted_at is null order by sb.source_id limit 20) q))';
    when 'subscriptions' then
      -- measured against the tenant's today (the age bands); devices_on_holding's records are the device-holding
      -- subscriptions with a device in the field, each with its devices_in_field (they add up to the figure)
      v_base := 'cma.flash_subscriptions_of($2, $7)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''store'' is null or x.store = $1 ->> ''store'')
                  and ($1 ->> ''status'' is null or x.status = $1 ->> ''status'') and ($1 ->> ''payment_state'' is null or x.payment_state = $1 ->> ''payment_state'')
                  and ($1 ->> ''device_band'' is null or x.device_band = $1 ->> ''device_band'')
                  and ($1 ->> ''age_band'' is null or x.age_band = $1 ->> ''age_band'')
                  and case $1 ->> ''measure'' when ''active_subscriptions'' then x.is_active when ''paused_subscriptions'' then x.status = ''paused''
                                              when ''holding_subscriptions'' then x.is_holding
                                              when ''devices_on_holding'' then x.is_holding and x.devices_in_field > 0 else true end';
      v_obj := 'jsonb_build_object(''subscription_id'', x.source_id, ''connection_id'', x.connection_id, ''store'', x.store, ''market'', x.market,
                  ''customer_id'', x.customer_source_id, ''contact_id'', x.contact_source_id,
                  ''contact_url'', cma.record_url(x.crm_connection_id, ''contact'', x.contact_source_id), ''status'', x.status,
                  ''payment_state'', x.payment_state, ''amount_per_cycle'', x.amount_per_cycle, ''currency'', x.currency,
                  ''billing_interval'', x.billing_interval, ''billing_interval_count'', x.billing_interval_count, ''next_billing_at'', x.next_billing_at,
                  ''retry_since'', x.retry_since, ''last_attempt'', x.last_attempt, ''devices'', x.devices, ''devices_in_field'', x.devices_in_field)';
    when 'installed_base' then
      -- the devices, filtered and paged first; the linked subscription's payment state (0008zl's derivation) only for the
      -- page's subscriptions, since no filter or sort reads it (addition 0008zz). The list's own filters (0009f,
      -- cma.flash_list_filters_of): serial, an exact match trimmed and case-insensitive (every device with it: a duplicate
      -- serial is a data-quality finding), and without_subscription_ref, the devices the data-quality check
      -- field_device_without_subscription_ref finds (one implementation, cma.field_devices_without_subscription_ref_of)
      v_base := 'cma.flash_devices_of($2, $7)';
      v_extra := ', ps.payment_state as subscription_payment_state';
      v_page := 'p x left join cma.subscription_payment_state_of($2, array(select y.subscription_id from p y where y.subscription_id is not null)) ps
                   on ps.subscription_id = x.subscription_id';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''status'' is null or x.status = $1 ->> ''status'')
                  and ($1 ->> ''model'' is null or x.model = $1 ->> ''model'') and ($1 ->> ''warehouse'' is null or x.warehouse = $1 ->> ''warehouse'')
                  and ($1 ->> ''link'' is null or x.link = $1 ->> ''link'')
                  and ($1 ->> ''subscription_status'' is null or x.subscription_status = $1 ->> ''subscription_status'')
                  and ($1 ->> ''debt_status'' is null
                       or x.device_id in (select dv.id from cma.device dv
                                          where dv.tenant_id = $2 and dv.source_deleted_at is null
                                            and case $1 ->> ''debt_status'' when ''none'' then dv.debt_status_key is null
                                                                            when ''any'' then dv.debt_status_key is not null
                                                                            else dv.debt_status_key = $1 ->> ''debt_status'' end))
                  and ($1 ->> ''serial'' is null or lower(x.serial) = lower(btrim($1 ->> ''serial'')))
                  and ($1 ->> ''without_subscription_ref'' is null
                       or x.device_id in (select u.device_id from cma.field_devices_without_subscription_ref_of($2) u))
                  and case $1 ->> ''measure'' when ''in_field'' then x.is_in_field when ''in_stock'' then x.is_in_stock
                                              when ''in_field_on_holding'' then x.is_in_field and x.subscription_status = any ($8)
                                              when ''components_past_due'' then x.past_due_items > 0 when ''items_due_3m'' then x.items_due_3m > 0
                                              when ''under_debt_status'' then x.is_in_field
                                                and x.device_id in (select dv.id from cma.device dv
                                                                    where dv.tenant_id = $2 and dv.debt_status_key is not null)
                                              else true end';
      v_obj := 'jsonb_build_object(''serial'', x.serial, ''device_id'', x.source_id, ''connection_id'', x.connection_id, ''model'', x.model,
                  ''market'', x.market, ''status'', x.status, ''in_field'', x.is_in_field, ''in_stock'', x.is_in_stock, ''warehouse'', x.warehouse,
                  ''refs'', x.refs, ''missing_refs'', to_jsonb(x.missing_refs), ''customer_id'', x.customer_ref, ''subscription_id'', x.subscription_ref,
                  ''link'', x.link, ''subscription_status'', x.subscription_status, ''subscription_payment_state'', x.subscription_payment_state,
                  ''past_due_items'', x.past_due_items, ''items_due_3m'', x.items_due_3m, ''next_due_on'', x.next_due_on,
                  ''debt_status'', (select dv.debt_status_key from cma.device dv where dv.tenant_id = $2 and dv.id = x.device_id),
                  ''record_url'', cma.record_url(x.connection_id, ''device'', x.source_id))';
    when 'churn' then
      v_base := 'cma.flash_churn_of($2, $5, $6)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''store'' is null or x.store = $1 ->> ''store'')
                  and ($1 ->> ''reason'' is null or x.reason = $1 ->> ''reason'')';
      v_obj := 'jsonb_build_object(''subscription_id'', x.source_id, ''connection_id'', x.connection_id, ''store'', x.store, ''market'', x.market,
                  ''customer_id'', x.customer_source_id, ''churned_at'', x.churned_at, ''business_date'', x.business_date, ''reason'', x.reason,
                  ''cycles'', x.cycles)';
    when 'orders' then
      v_base := 'cma.flash_orders_of($2, $5, $6)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''store'' is null or x.store = $1 ->> ''store'')
                  and ($1 ->> ''kind'' is null or x.kind = $1 ->> ''kind'') and ($1 ->> ''sku'' is null or ($1 ->> ''sku'') = any (x.skus))';
      v_obj := 'jsonb_build_object(''order_number'', x.order_number, ''order_id'', x.source_id, ''connection_id'', x.connection_id, ''store'', x.store,
                  ''market'', x.market, ''created_at'', x.created_at, ''business_date'', x.business_date, ''kind'', x.kind,
                  ''financial_status'', x.financial_status, ''fulfillment_status'', x.fulfillment_status, ''skus'', to_jsonb(x.skus),
                  ''units'', x.units, ''total'', x.total, ''currency'', x.currency, ''customer_id'', x.customer_source_id)';
    when 'payments' then
      v_base := 'cma.flash_payments_of($2, $5, $6)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''store'' is null or x.store = $1 ->> ''store'')
                  and ($1 ->> ''kind'' is null or x.kind = $1 ->> ''kind'') and ($1 ->> ''status'' is null or x.status = $1 ->> ''status'')
                  and case $1 ->> ''measure'' when ''orders'' then x.kind = ''order''
                                              when ''renewals'' then x.kind = ''renewal'' and x.status = ''renewed''
                                              when ''failed_renewals'' then x.kind = ''renewal'' and x.status = ''renew_failed'' else true end';
      v_obj := 'jsonb_build_object(''kind'', x.kind, ''status'', x.status, ''record_ref'', x.record_ref, ''cycle'', x.cycle, ''source_id'', x.source_id,
                  ''connection_id'', x.connection_id, ''store'', x.store, ''market'', x.market, ''at'', x.at, ''business_date'', x.business_date,
                  ''amount'', x.amount, ''currency'', x.currency)';
    when 'open_deals' then
      v_base := 'cma.flash_deals_of($2)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''pipeline'' is null or x.pipeline = $1 ->> ''pipeline'')
                  and ($1 ->> ''stage'' is null or x.stage = $1 ->> ''stage'')';
      v_obj := 'jsonb_build_object(''record_id'', x.source_id, ''record_url'', cma.record_url(x.connection_id, ''deal'', x.source_id),
                  ''connection_id'', x.connection_id, ''pipeline'', x.pipeline, ''stage'', x.stage, ''market'', x.market, ''owner_ref'', x.owner_ref,
                  ''owner_linked'', x.owner_user_id is not null, ''created_at'', x.created_at, ''age_days'', x.age_days)';
    when 'open_tickets' then
      v_base := 'cma.flash_tickets_of($2)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''queue'' is null or x.queue = $1 ->> ''queue'')
                  and ($1 ->> ''stage'' is null or x.stage = $1 ->> ''stage'')';
      v_obj := 'jsonb_build_object(''record_id'', x.source_id, ''record_url'', cma.record_url(x.connection_id, ''ticket'', x.source_id),
                  ''connection_id'', x.connection_id, ''queue'', x.queue, ''stage'', x.stage, ''market'', x.market, ''owner_ref'', x.owner_ref,
                  ''owner_linked'', x.owner_user_id is not null, ''created_at'', x.created_at, ''age_days'', x.age_days)';
    when 'open_tasks' then
      v_base := 'cma.flash_tasks_of($2)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''type'' is null or x.type = $1 ->> ''type'')
                  and ($1 ->> ''status'' is null or x.status = $1 ->> ''status'')
                  and case $1 ->> ''measure'' when ''overdue'' then x.overdue else true end';
      v_obj := 'jsonb_build_object(''task_id'', x.source_id, ''task_url'', cma.record_url(x.connection_id, ''task'', x.source_id),
                  ''connection_id'', x.connection_id, ''type'', x.type, ''status'', x.status, ''market'', x.market, ''owner_ref'', x.owner_ref,
                  ''owner_linked'', x.owner_user_id is not null, ''due_at'', x.due_at, ''overdue'', x.overdue, ''record_type'', x.record_type,
                  ''record_id'', x.record_source_id,
                  ''record_url'', case when x.record_type is not null then cma.record_url(x.connection_id, x.record_type, x.record_source_id) end)';
    when 'reviews' then
      v_base := 'cma.flash_reviews_of($2, $5, $6)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''rating'' is null or x.stars::text = $1 ->> ''rating'')
                  and case $1 ->> ''measure'' when ''negative'' then x.is_negative else true end';
      v_obj := 'jsonb_build_object(''review_id'', x.source_id, ''review_url'', cma.record_url(x.connection_id, ''review'', x.source_id),
                  ''connection_id'', x.connection_id, ''channel'', x.channel, ''market'', x.market, ''rating'', x.rating, ''stars'', x.stars,
                  ''negative'', x.is_negative, ''submitted_at'', x.submitted_at, ''business_date'', x.business_date, ''link_level'', x.link_level)';
    when 'data_quality' then
      v_base := 'cma.flash_findings_of($2)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''check'' is null or x.check_key = $1 ->> ''check'')';
      v_obj := 'jsonb_build_object(''check'', x.check_key, ''object_type'', x.object_type, ''object_id'', x.object_id, ''connection_id'', x.connection_id,
                  ''value'', x.value, ''market'', x.market, ''fix_in'', x.fix_in, ''fix_adapter'', x.fix_adapter)
                  || cma.flash_finding_links_of($2, x.connection_id, x.object_type, x.object_id)';
  end case;
  execute format(
    'with sm as materialized (select * from cma.flash_subscription_stores_of($2)),
          f as materialized (select x.* from %s x where %s),
          p as materialized (select x.* from f x order by %s limit $3 offset $4),
          n as (select x.*%s, row_number() over (order by %s) as ord from %s)
     select jsonb_build_object(''total'', (select count(*) from f),
                               ''rows'', coalesce((select jsonb_agg(%s order by x.ord) from n x), ''[]''::jsonb))',
    v_base, v_where, v_order, v_extra, v_order, v_page, v_obj)
    into v_res
    using p_filters, p_tenant_id, p_limit, p_offset, v_from, v_to, v_today, cma.flash_holding_statuses_of(p_tenant_id);
  return v_res;
end
$$;

alter function cma.flash_rows_of(uuid, text, jsonb, text, boolean, integer, integer, date, date) set jit = off;

-- ---------------------------------------------------------------------------------------------
-- 10. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.device_debt_status_key_of(uuid,text)',
    'cma.set_device_debt_status(text,text,boolean,integer)',
    'cma.set_device_debt_status_alias(text,text)',
    'cma.maintenance_debt_matches(text,text,boolean)',
    'cma.assert_maintenance_debt(uuid,text)',
    'cma.device_rows_apply(uuid,cma.device_load_row[],boolean)',
    'cma.device_snapshot_apply(text,uuid,boolean)',
    'cma.ingest_load_device_chunk(uuid,jsonb)',
    'cma.maintenance_items_of(uuid,date)',
    'cma.maintenance_due_of(date,integer)',
    'cma.maintenance_bucket_dates_of(uuid,date,integer,text,text,text,text,date)',
    'cma.maintenance_page_of(uuid,date,integer,text,text,text,text,date)',
    'cma.maintenance_rows_of(uuid,date,integer,text,text,text,text,text,text,integer,date)',
    'cma.maintenance_page(date,integer,text,text,text,text)',
    'cma.maintenance_rows(date,integer,text,text,text,text,text,text,integer)',
    'cma.data_quality_assets_checks()',
    'cma.data_quality_of(uuid)',
    'cma.data_quality_fix_in(text,text)',
    'cma.flash_overviews()',
    'cma.flash_compute_of(uuid,text,date,date,date)',
    'cma.flash_definition_version(text)',
    'cma.flash_labels_of(uuid,text)',
    'cma.flash_rows_of(uuid,text,jsonb,text,boolean,integer,integer,date,date)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;
-- The staging's trigger function runs whoever writes the view: nobody gets execute on it (as 112)
revoke execute on function cma.device_import_staging_insert() from public;

-- ---------------------------------------------------------------------------------------------
-- 11. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009zl', 'Debt status on devices (brief 0009zc): the catalog cma.device_debt_status (key, name, pauses_maintenance, sort order) and cma.device_debt_status_alias with cma.set_device_debt_status, cma.set_device_debt_status_alias and cma.device_debt_status_key_of; cma.device.debt_status_key (null without one or when unmapped; raw keeps the label); the load''s row types, the staging and the load (cma.device_rows_apply''s answer gains unmapped_debt_status) with debt_status; connection_field takes debt_status; cma.maintenance_items_of gains debt_status_key and maintenance_paused (every item kept) and the Maintenance report''s new forms take a debt status filter (null, unpaused, none, any or a key; 112''s and 116''s forms kept); data quality device_debt_status_unmapped (305, fixed in the asset register); the installed base''s measure under_debt_status, dim debt_status and set [market, model, debt_status], its labels and records'' filter, definition version 0009zl')
on conflict (version) do nothing;

commit;
reset role;
