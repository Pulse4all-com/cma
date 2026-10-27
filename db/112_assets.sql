-- =============================================================================================
-- 112_assets.sql: addition 0008zi, the asset register's devices as a read-only mirror, and Reports, Maintenance
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 110_import_status_reuse.sql (0008zh). Rerunnable, forward-only, in one transaction. Run as your own IAM login:
-- dev first, then 113_verify_assets.sql, then 105, 75, 41 and 107 again (dev; the data-quality redefinition carries the
-- first three's checks, cma.audit_row() 107's); then 02_seed_pulse4all.sql again (the catalogs of Pulse4all
-- Subscriptions); then prod, with 113 and 02.
-- The web of main reads nothing this adds; the web of this change reads it (Reports, Maintenance and its data-quality
-- checks), so in prod the script runs before that web is merged.
--
-- Why (Decision log, 27 October 2026): the tenant's asset register owns its devices (for Pulse4all Subscriptions an
-- Airtable base whose rows also carry NetSuite ids). The CMA mirrors it read-only from a snapshot import of the
-- register's CSV export, run by a person; a later adapter (the register's API or the ERP) fills the same tables. From
-- the mirror the CMA forecasts which components and devices come due, per month, market and model, and bundles a
-- device's due items into planned exchanges. Nothing is written to the register, the CRM or the commerce system. A
-- device holds ids, statuses, dates and codes only: never a customer's name, email, phone or address (the import
-- never stages them, a staged value holding an @ is kept as a bare @, the audit log keeps a staged row's keys only,
-- and raw is held to a key allow-list).
--
-- What it adds
--   connection kind    integration_connection.kind gains assets: the connection holds devices.
--                      cma.connection_held_kinds_of() and cma.set_connection_kind() know it; cma.assets_set_up_of()
--   catalogs           tenant configuration, no value in code: cma.device_model (key, name, brand, the source's labels
--                      as aliases), cma.device_component_kind (key, name, sort order), cma.maintenance_rule (a model's
--                      component: interval in months and lead days, one per tenant, model and component),
--                      cma.device_status (key, name, the flags is_in_field, is_in_stock and is_tracked, the source's
--                      labels as aliases). Reporting reads the flags, never a status name (as the work statuses, 5
--                      October 2026). An alias is held by one row of its catalog only
--   setting            assets.bundle_window_days (0: only due items with the same action date bundle)
--   devices            cma.device: one row per register record of a connection (source id), its serial (not unique:
--                      a duplicate is a data-quality finding), model, market (a catalog market through
--                      cma.market_code_of, null when unmapped), device status, warehouse, customer, subscription and
--                      order references, the shipment, stock, warranty and end-of-life dates, named ids of other
--                      systems (external_refs), the row as mapped (raw, held to a key allow-list), source_deleted_at
--                      (missing from the latest full snapshot), first_seen_at and synced_at
--   components         cma.device_component: a device's component per kind with its serial and recorded expiry;
--                      at most one current row (replaced_at null) per device and kind. A serial that differs from the
--                      stored one is an observed replacement: the old row gets replaced_at, a new row is inserted. The
--                      replacement history starts at the first load
--   import             cma.device_import_staging (the COPY target, a view writing cma.device_import_row: a batch key
--                      and the mapped columns as text, a value holding an @ as a bare @, staged by a person holding
--                      tenant.configure; cma.audit_row() keeps a staged row's keys only, as 0008zf left it plus that) and
--                      cma.load_device_snapshot(batch, connection, is_full) (tenant.configure): devices upserted, model,
--                      status and market mapped through the aliases, components rotated on a serial change, devices
--                      missing from a full snapshot marked, one sync_run (job assets_import), the staged rows deleted;
--                      answers the counts
--   forecast           cma.maintenance_items_of(tenant, today): every due item of the tracked devices: a component
--                      (due on its recorded expiry, else its anchor date plus the rule's interval for the model, else
--                      unknown; the anchor the day a replacement was first seen, in the tenant's zone, else the last
--                      shipment, else the first; action date the due date less the rule's lead days)
--                      or the device itself (end of life, its recorded date, no lead days); past due when the action date
--                      lies before the current month; the planned exchange (the device's due items whose action dates
--                      fall within assets.bundle_window_days of the earliest one, counted once in the month of that
--                      earliest action date). cma.maintenance_due_of(from month, months) reads it for the application
--   reports            cma.maintenance_page(from month, months up to 24, market, model, scope field or stock)
--                      (reports.view or performance.team): the Past due bucket and one cell per month, market and model
--                      with the items per component, the devices at end of life and the planned exchanges, and the
--                      unknown-basis items per market and model; cma.maintenance_rows(...) the device list of one cell
--                      (serial, model, market, device status, components due, due date, bases, action date, customer and
--                      subscription references, the CRM contact through the commerce customer's link of 0008h). No
--                      per-person figure exists
--   data quality       device_serial_missing, device_serial_duplicate, device_model_unmapped, device_status_unmapped,
--                      device_market_unmapped, device_customer_ref_invalid, component_due_unknown and
--                      field_device_without_subscription_ref: cma.data_quality_assets_checks(), cma.data_quality_of()
--                      and cma.data_quality() as 0008ze with the eight checks; a cma_read.dq_ view for each
--   readers            cma_read.device_model, device_component_kind, maintenance_rule, device_status, device (no raw),
--                      device_component, maintenance_due and maintenance_per_month
--   runs               sync_run.job gains assets_import
--
-- Everything is SECURITY INVOKER and executable by the application only, with its permission checked inside; the
-- cma_read functions are SECURITY DEFINER, owned by cma_owner, search path pinned, executable by readers only. The
-- application never deletes a catalog row, a device or a component; it deletes staged rows only.
--
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
  if not exists (select 1 from cma.schema_migration where version = '0008zh') then
    raise exception 'addition 0008zh (110_import_status_reuse.sql) must run before 0008zi';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The connection's kind: assets
-- ---------------------------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_constraint c where c.conrelid = 'cma.integration_connection'::regclass
             and c.conname = 'integration_connection_kind_check' and pg_get_constraintdef(c.oid) not like '%assets%') then
    alter table cma.integration_connection drop constraint integration_connection_kind_check;
  end if;
  if not exists (select 1 from pg_constraint c where c.conrelid = 'cma.integration_connection'::regclass
                 and c.conname = 'integration_connection_kind_check') then
    alter table cma.integration_connection add constraint integration_connection_kind_check
      check (kind in ('crm', 'telephony', 'commerce', 'automation', 'reviews', 'assets'));
  end if;
end
$$;
comment on column cma.integration_connection.kind is
  'The kind of source in the data model''s terms (crm, telephony, commerce, automation, reviews, assets), never a vendor; null until set (0008e; reviews 0008ze; assets 0008zi)';

-- ---------------------------------------------------------------------------------------------
-- 2. Catalogs: models, component kinds, maintenance rules, device statuses (tenant configuration)
-- ---------------------------------------------------------------------------------------------
-- A catalog row's aliases: the labels a source writes for it, lower-cased and trimmed, 1 to 100 characters each, each
-- once, at most 50
create or replace function cma.asset_aliases_ok(p_aliases text[])
returns boolean
language sql immutable
as $$
  select p_aliases is not null and cardinality(p_aliases) <= 50
     and not exists (select 1 from unnest(p_aliases) a where a is null or a <> lower(btrim(a)) or length(a) not between 1 and 100
                                                             or a ~ '[[:cntrl:]]')
     and cardinality(p_aliases) = (select count(distinct a) from unnest(p_aliases) a)
$$;
revoke execute on function cma.asset_aliases_ok(text[]) from public;
grant execute on function cma.asset_aliases_ok(text[]) to cma_app;

create table if not exists cma.device_model (
  id          uuid primary key default uuidv7(),
  tenant_id   uuid not null default cma.current_tenant_id() references cma.tenant (id),
  key         text not null check (key ~ '^[a-z0-9]+(_[a-z0-9]+)*$' and length(key) <= 40 and key <> 'unknown'),
  name        text not null check (length(btrim(name)) between 1 and 80),
  brand       text check (length(btrim(brand)) between 1 and 80),
  aliases     text[] not null default '{}' check (cma.asset_aliases_ok(aliases)),
  status      text not null default 'active' check (status in ('active', 'inactive')),
  sort_order  integer not null default 100,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, key)
);
comment on table cma.device_model is 'Device models a tenant''s asset register holds: key, name, brand and the labels the register writes for each (aliases). Tenant configuration (0008zi)';
comment on column cma.device_model.aliases is 'The labels the source writes for the model, lower-cased; a label matches its key or one alias (cma.device_model_key_of)';
create or replace trigger set_updated_at before update on cma.device_model
  for each row execute function cma.set_updated_at();

create table if not exists cma.device_component_kind (
  id          uuid primary key default uuidv7(),
  tenant_id   uuid not null default cma.current_tenant_id() references cma.tenant (id),
  key         text not null check (key ~ '^[a-z0-9]+(_[a-z0-9]+)*$' and length(key) <= 40 and key not in ('device', 'unknown')),
  name        text not null check (length(btrim(name)) between 1 and 80),
  status      text not null default 'active' check (status in ('active', 'inactive')),
  sort_order  integer not null default 100,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, key)
);
comment on table cma.device_component_kind is 'The kinds of component a device carries that come due (pads, battery): key, name, sort order. The key device is reserved for the device''s own end of life. Tenant configuration (0008zi)';
create or replace trigger set_updated_at before update on cma.device_component_kind
  for each row execute function cma.set_updated_at();

create table if not exists cma.maintenance_rule (
  id               uuid primary key default uuidv7(),
  tenant_id        uuid not null default cma.current_tenant_id() references cma.tenant (id),
  model_key        text not null,
  component_key    text not null,
  interval_months  integer not null check (interval_months between 1 and 240),
  lead_days        integer not null default 0 check (lead_days between 0 and 365),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, model_key, component_key),
  foreign key (tenant_id, model_key) references cma.device_model (tenant_id, key),
  foreign key (tenant_id, component_key) references cma.device_component_kind (tenant_id, key)
);
comment on table cma.maintenance_rule is 'How long a model''s component lasts from the device''s anchor date (interval in months) and how many days before its due date it is acted on (lead days). One per tenant, model and component. Tenant configuration (0008zi)';
comment on column cma.maintenance_rule.interval_months is 'Months from the anchor date (the last shipment, else the first) to the component''s due date, when the register records no expiry';
comment on column cma.maintenance_rule.lead_days is 'Days before the due date the component is acted on: the action date is the due date less these days';
create or replace trigger set_updated_at before update on cma.maintenance_rule
  for each row execute function cma.set_updated_at();

create table if not exists cma.device_status (
  id           uuid primary key default uuidv7(),
  tenant_id    uuid not null default cma.current_tenant_id() references cma.tenant (id),
  key          text not null check (key ~ '^[a-z0-9]+(_[a-z0-9]+)*$' and length(key) <= 40),
  name         text not null check (length(btrim(name)) between 1 and 80),
  is_in_field  boolean not null default false,
  is_in_stock  boolean not null default false,
  is_tracked   boolean not null default false,
  aliases      text[] not null default '{}' check (cma.asset_aliases_ok(aliases)),
  status       text not null default 'active' check (status in ('active', 'inactive')),
  sort_order   integer not null default 100,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, key),
  check (not (is_in_field and is_in_stock))
);
comment on table cma.device_status is 'A tenant''s device statuses with their flags: in the field (at a customer), in stock, tracked (forecast for maintenance), and the labels the register writes for each (aliases). Reporting reads the flags, never a status name. Tenant configuration (0008zi)';
comment on column cma.device_status.is_tracked is 'Whether devices in this status are forecast for maintenance (Reports, Maintenance)';
create or replace trigger set_updated_at before update on cma.device_status
  for each row execute function cma.set_updated_at();

-- An alias is held by one row of its catalog only, and is no other row's key: a label maps to one model or status. The
-- row of the same key is the same catalog row (an insert that meets it on conflict). A trigger function: it runs whoever
-- writes the row, so nobody gets execute on it
create or replace function cma.check_asset_aliases()
returns trigger
language plpgsql
as $$
declare
  v_clash text;
begin
  execute format('select x.key from %I.%I x where x.tenant_id = $1 and x.id <> $2 and x.key <> $4 and (x.key = any ($3) or x.aliases && $3 or $4 = any (x.aliases)) limit 1',
                 tg_table_schema, tg_table_name)
    into v_clash using new.tenant_id, new.id, new.aliases, new.key;
  if v_clash is not null then
    raise exception 'an alias or key of % is held by % already', new.key, v_clash using errcode = 'CMA03';
  end if;
  return new;
end
$$;
revoke execute on function cma.check_asset_aliases() from public;
drop trigger if exists check_aliases on cma.device_model;
create trigger check_aliases before insert or update of key, aliases on cma.device_model
  for each row execute function cma.check_asset_aliases();
drop trigger if exists check_aliases on cma.device_status;
create trigger check_aliases before insert or update of key, aliases on cma.device_status
  for each row execute function cma.check_asset_aliases();

select cma.setup_tenant_table('cma.device_model');
select cma.setup_tenant_table('cma.device_component_kind');
select cma.setup_tenant_table('cma.maintenance_rule');
select cma.setup_tenant_table('cma.device_status');

-- The application never deletes a catalog row: a model, kind or status goes inactive, a rule changes
revoke delete on cma.device_model, cma.device_component_kind, cma.maintenance_rule, cma.device_status from cma_app;

-- A source's label as a catalog key: the row whose key or one of whose aliases equals the label, lower-cased and trimmed;
-- null for none or an empty label
create or replace function cma.device_model_key_of(p_tenant_id uuid, p_label text)
returns text
language sql stable
as $$
  select m.key from cma.device_model m
  where m.tenant_id = p_tenant_id and nullif(btrim(p_label), '') is not null
    and (m.key = lower(btrim(p_label)) or lower(btrim(p_label)) = any (m.aliases))
  order by m.key
  limit 1
$$;

create or replace function cma.device_status_key_of(p_tenant_id uuid, p_label text)
returns text
language sql stable
as $$
  select s.key from cma.device_status s
  where s.tenant_id = p_tenant_id and nullif(btrim(p_label), '') is not null
    and (s.key = lower(btrim(p_label)) or lower(btrim(p_label)) = any (s.aliases))
  order by s.key
  limit 1
$$;

-- The setting: how many days after a device's earliest action date its other due items still join the same planned
-- exchange
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('assets.bundle_window_days', 'integer', null, '0',
     'Days after a device''s earliest action date within which its other due items join the same planned exchange (0 to 365; 0: only items with the same action date)')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- ---------------------------------------------------------------------------------------------
-- 3. Devices and components
-- ---------------------------------------------------------------------------------------------
-- A device's named ids of other systems (such as the register's ERP ids): at most 20 names of lower-case letters,
-- digits and _, each an id of 1 to 100 characters without spaces or an @
create or replace function cma.device_external_refs_ok(p_refs jsonb)
returns boolean
language sql immutable
as $$
  select p_refs is not null and jsonb_typeof(p_refs) = 'object'
     and (select count(*) from jsonb_object_keys(p_refs)) <= 20
     and not exists (select 1 from jsonb_each(p_refs) e
                     where e.key !~ '^[a-z][a-z0-9_]{0,39}$' or jsonb_typeof(e.value) <> 'string'
                        or (e.value #>> '{}') !~ '^[A-Za-z0-9#][A-Za-z0-9_.#:/-]{0,99}$')
$$;
revoke execute on function cma.device_external_refs_ok(jsonb) from public;
grant execute on function cma.device_external_refs_ok(jsonb) to cma_app;

-- A device's raw: the staged row as mapped, under a fixed set of keys (the staging columns), at most 4 kB, never an @
-- (so never an email address); the import stages no name, email, phone or address column at all
create or replace function cma.device_raw_ok(p_raw jsonb)
returns boolean
language sql immutable
as $$
  select p_raw is not null and jsonb_typeof(p_raw) = 'object' and length(p_raw::text) <= 4096 and strpos(p_raw::text, '@') = 0
     and not exists (select 1 from jsonb_object_keys(p_raw) k
                     where k not in ('source_id', 'serial', 'model', 'status', 'country', 'warehouse_ref', 'customer_ref',
                                     'subscription_ref', 'order_ref', 'first_shipped_on', 'stock_received_on', 'last_shipped_on',
                                     'warranty_until', 'end_of_life_on', 'components', 'external_refs'))
$$;
revoke execute on function cma.device_raw_ok(jsonb) from public;
grant execute on function cma.device_raw_ok(jsonb) to cma_app;

create table if not exists cma.device (
  id                    uuid primary key default uuidv7(),
  tenant_id             uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id         uuid not null,
  source_system         text not null check (source_system ~ '^[a-z0-9_]+$'),
  source_id             text not null check (length(source_id) between 1 and 100 and source_id = btrim(source_id) and source_id !~ '[[:cntrl:]@]'),
  serial                text check (serial ~ '^[A-Za-z0-9#][A-Za-z0-9 _.#:/-]{0,99}$'),
  model_key             text,
  market                text,
  device_status_key     text,
  warehouse_ref         text check (warehouse_ref ~ '^[A-Za-z0-9#][A-Za-z0-9 _.#:/-]{0,99}$'),
  customer_ref          text check (customer_ref ~ '^[A-Za-z0-9_-]{1,100}$'),
  customer_ref_invalid  boolean not null default false,
  subscription_ref      text check (subscription_ref ~ '^[A-Za-z0-9#][A-Za-z0-9 _.#:/-]{0,99}$'),
  order_ref             text check (order_ref ~ '^[A-Za-z0-9#][A-Za-z0-9 _.#:/-]{0,99}$'),
  first_shipped_on      date,
  stock_received_on     date,
  last_shipped_on       date,
  warranty_until        date,
  end_of_life_on        date,
  external_refs         jsonb not null default '{}'::jsonb check (cma.device_external_refs_ok(external_refs)),
  raw                   jsonb not null default '{}'::jsonb check (cma.device_raw_ok(raw)),
  source_deleted_at     timestamptz,
  first_seen_at         timestamptz not null default now(),
  synced_at             timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, connection_id, source_id),
  check (not (customer_ref_invalid and customer_ref is not null)),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id),
  foreign key (tenant_id, model_key) references cma.device_model (tenant_id, key),
  foreign key (tenant_id, market) references cma.market (tenant_id, code),
  foreign key (tenant_id, device_status_key) references cma.device_status (tenant_id, key)
);
comment on table cma.device is 'The asset register''s devices per connection, mirrored read-only: serial, model, market, device status, references, dates, named ids of other systems, the row as mapped. Never a name, email, phone or address. Owned by the asset register (0008zi)';
comment on column cma.device.source_id is 'The register''s record id, unique per tenant and connection';
comment on column cma.device.serial is 'The device''s serial number as the register holds it; not unique (a duplicate is the data-quality check device_serial_duplicate); null when missing or not an id';
comment on column cma.device.model_key is 'The catalog model the register''s label maps to (cma.device_model_key_of); null when unmapped';
comment on column cma.device.market is 'The catalog market the register''s country maps to (cma.market_code_of: a market alias or a code); null when unmapped';
comment on column cma.device.device_status_key is 'The catalog device status the register''s label maps to (cma.device_status_key_of); null when unmapped';
comment on column cma.device.customer_ref is 'The register''s customer id (the commerce system''s customer id), only when it is 1 to 100 letters, digits, _ or -; else null and customer_ref_invalid';
comment on column cma.device.customer_ref_invalid is 'True when the register held a customer reference that is no id (it is never stored): the data-quality check device_customer_ref_invalid';
comment on column cma.device.external_refs is 'Named ids of other systems the register''s row carries, such as its ERP ids; the names come from the import''s map';
comment on column cma.device.raw is 'The staged row as mapped (the staging columns'' keys only, never an @), labels as the register wrote them';
comment on column cma.device.source_deleted_at is 'When the device was missing from a full snapshot of its connection; cleared when a later snapshot holds it again';
comment on column cma.device.synced_at is 'When the device''s row last changed by an import';
create index if not exists device_serial_idx on cma.device (tenant_id, serial) where serial is not null;
create index if not exists device_customer_idx on cma.device (tenant_id, customer_ref) where customer_ref is not null;

create table if not exists cma.device_component (
  id             uuid primary key default uuidv7(),
  tenant_id      uuid not null default cma.current_tenant_id() references cma.tenant (id),
  device_id      uuid not null,
  component_key  text not null,
  serial         text check (serial ~ '^[A-Za-z0-9#][A-Za-z0-9 _.#:/-]{0,99}$'),
  expires_on     date,
  first_seen_at  timestamptz not null default now(),
  replaced_at    timestamptz,
  unique (tenant_id, id),
  check (serial is not null or expires_on is not null),
  check (replaced_at is null or replaced_at >= first_seen_at),
  foreign key (tenant_id, device_id) references cma.device (tenant_id, id),
  foreign key (tenant_id, component_key) references cma.device_component_kind (tenant_id, key)
);
comment on table cma.device_component is 'A device''s components per kind with the serial and the recorded expiry; the current one has no replaced_at. A serial that differs from the stored one is an observed replacement (0008zi)';
comment on column cma.device_component.expires_on is 'The component''s expiry as the register records it; the due date when present';
comment on column cma.device_component.first_seen_at is 'When an import first saw this component (its serial) on the device';
comment on column cma.device_component.replaced_at is 'When an import saw another serial for the kind on the device: the observed replacement; null for the current component';
create unique index if not exists device_component_current_idx on cma.device_component (tenant_id, device_id, component_key)
  where replaced_at is null;

select cma.setup_tenant_table('cma.device');
select cma.setup_tenant_table('cma.device_component');

-- The application never deletes a device or a component
revoke delete on cma.device, cma.device_component from cma_app;

-- ---------------------------------------------------------------------------------------------
-- 4. The import's staging (the COPY target)
-- ---------------------------------------------------------------------------------------------
-- The audit image of a staged row is its keys only: as 0008zf (106) left cma.audit_row(), plus a branch that keeps
-- id, tenant_id, batch_key and source_row of cma.device_import_row and nothing of its staged values, so the append-only
-- audit log never holds what an export carried (the staged rows themselves are deleted by the load)
create or replace function cma.audit_row()
returns trigger
language plpgsql
as $$
declare
  v_old jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_new jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
begin
  if tg_op = 'DELETE' and tg_table_schema = 'cma'
     and tg_table_name in ('telephony_call', 'telephony_call_tag', 'call_link')
     and coalesce(current_setting('cma.audit_keys_only', true), '') = 'uncounted_line' then
    v_old := jsonb_strip_nulls(jsonb_build_object(
      'id', v_old -> 'id', 'tenant_id', v_old -> 'tenant_id', 'connection_id', v_old -> 'connection_id',
      'source_id', v_old -> 'source_id', 'call_source_id', v_old -> 'call_source_id', 'tag_ref', v_old -> 'tag_ref',
      'telephony_call_id', v_old -> 'telephony_call_id', 'crm_call_id', v_old -> 'crm_call_id',
      'reason', 'uncounted_line'));
  end if;
  if tg_table_schema = 'cma' and tg_table_name = 'invitation' then
    v_old := v_old - 'token_hash';
    v_new := v_new - 'token_hash';
  end if;
  if tg_table_schema = 'cma' and tg_table_name = 'ingest_event' then
    v_old := v_old - 'raw';
    v_new := v_new - 'raw';
  end if;
  if tg_table_schema = 'cma' and tg_table_name = 'review' then
    v_old := cma.review_image_without_at_reference(v_old);
    v_new := cma.review_image_without_at_reference(v_new);
  end if;
  if tg_table_schema = 'cma' and tg_table_name = 'device_import_row' then
    v_old := case when v_old is not null then jsonb_build_object('id', v_old -> 'id', 'tenant_id', v_old -> 'tenant_id',
                                                                 'batch_key', v_old -> 'batch_key', 'source_row', v_old -> 'source_row') end;
    v_new := case when v_new is not null then jsonb_build_object('id', v_new -> 'id', 'tenant_id', v_new -> 'tenant_id',
                                                                 'batch_key', v_new -> 'batch_key', 'source_row', v_new -> 'source_row') end;
  end if;
  insert into cma.audit_log (tenant_id, table_name, action, old_row, new_row, actor_user_id, actor_label)
  values (
    (coalesce(v_new, v_old) ->> 'tenant_id')::uuid,
    tg_table_name,
    lower(tg_op),
    v_old,
    v_new,
    cma.current_user_id(),
    cma.current_actor_label()
  );
  return null;   -- after trigger, return value is ignored
end
$$;

-- One row per register record of a staging file (tools/devices-to-staging.mjs), every column text as mapped: the batch
-- key, the export's line, the record id, serial, model, status and country labels, references, dates as YYYY-MM-DD,
-- the components as a JSON object of kinds ({"pads": {"serial": .., "expires_on": ..}}) and the named ids as a JSON
-- object. The load checks every value and deletes the batch's rows when it is done
create table if not exists cma.device_import_row (
  id                 uuid primary key default uuidv7(),
  tenant_id          uuid not null default cma.current_tenant_id() references cma.tenant (id),
  batch_key          text not null check (batch_key ~ '^[a-z0-9_-]{1,64}$'),
  source_row         integer check (source_row between 2 and 10000000),
  source_id          text check (length(source_id) <= 500),
  serial             text check (length(serial) <= 500),
  model              text check (length(model) <= 500),
  status             text check (length(status) <= 500),
  country            text check (length(country) <= 500),
  warehouse_ref      text check (length(warehouse_ref) <= 500),
  customer_ref       text check (length(customer_ref) <= 500),
  subscription_ref   text check (length(subscription_ref) <= 500),
  order_ref          text check (length(order_ref) <= 500),
  first_shipped_on   text check (length(first_shipped_on) <= 40),
  stock_received_on  text check (length(stock_received_on) <= 40),
  last_shipped_on    text check (length(last_shipped_on) <= 40),
  warranty_until     text check (length(warranty_until) <= 40),
  end_of_life_on     text check (length(end_of_life_on) <= 40),
  components         text check (length(components) <= 4000),
  external_refs      text check (length(external_refs) <= 4000),
  staged_at          timestamptz not null default now(),
  unique (tenant_id, id)
);
comment on table cma.device_import_row is 'The device import''s staged rows: a batch key and the export''s mapped columns as text, written through cma.device_import_staging, checked and deleted by cma.load_device_snapshot. No name, email, phone or address column exists (0008zi)';
create index if not exists device_import_row_batch_idx on cma.device_import_row (tenant_id, batch_key);

select cma.setup_tenant_table('cma.device_import_row');

-- The application stages, reads and deletes staged rows, never changes one
revoke update on cma.device_import_row from cma_app;

-- The COPY target (COPY does not write a table under row-level security, so it writes this view, as the legacy
-- import's staging): the staging file's columns. Selecting shows the current tenant's staged rows only (the owner's
-- view would otherwise see every tenant)
create or replace view cma.device_import_staging as
  select r.batch_key, r.source_row, r.source_id, r.serial, r.model, r.status, r.country, r.warehouse_ref, r.customer_ref,
         r.subscription_ref, r.order_ref, r.first_shipped_on, r.stock_received_on, r.last_shipped_on, r.warranty_until,
         r.end_of_life_on, r.components, r.external_refs
  from cma.device_import_row r
  where r.tenant_id = cma.current_tenant_id();
comment on view cma.device_import_staging is 'The device import''s COPY target (tools/devices-to-staging.mjs, docs/import/copy-devices-staging.psql): a row written here lands in cma.device_import_row for the current tenant, by a person holding tenant.configure (0008zi)';

-- A staged value that holds an @ (an email address where an id belongs) is kept as a bare @, so no address is ever
-- stored, not even in a staged row; the load reads the bare @ as it would the address: no id, an unmapped label, a date
-- that does not read. The import tool does the same before the file is written (tools/devices-to-staging.mjs)
create or replace function cma.device_staged_without_at(p_value text)
returns text
language sql immutable
as $$
  select case when strpos(p_value, '@') > 0 then '@' else p_value end
$$;
revoke execute on function cma.device_staged_without_at(text) from public;

-- The same for a staged JSON object (components, external_refs): each value of one or two levels that holds an @
-- becomes the text @; a key that holds one, or text that is no JSON object, makes the whole value a bare @ (the load
-- then refuses it as no JSON object, as it would have)
create or replace function cma.device_staged_object_without_at(p_value text)
returns text
language plpgsql immutable
as $$
declare
  v jsonb;
begin
  if strpos(coalesce(p_value, ''), '@') = 0 then
    return p_value;
  end if;
  v := btrim(p_value)::jsonb;
  if exists (select 1 from jsonb_each(v) e
             where strpos(e.key, '@') > 0
                or (jsonb_typeof(e.value) = 'object' and exists (select 1 from jsonb_object_keys(e.value) k where strpos(k, '@') > 0))) then
    return '@';
  end if;
  return (select jsonb_object_agg(e.key,
                   case when jsonb_typeof(e.value) = 'object'
                        then (select coalesce(jsonb_object_agg(f.key, case when strpos(f.value::text, '@') > 0 then to_jsonb('@'::text) else f.value end), '{}'::jsonb)
                              from jsonb_each(e.value) f)
                        when strpos(e.value::text, '@') > 0 then to_jsonb('@'::text)
                        else e.value end)
          from jsonb_each(v) e)::text;
exception when invalid_text_representation or invalid_parameter_value then
  return '@';
end
$$;
revoke execute on function cma.device_staged_object_without_at(text) from public;

-- Only a person holding tenant.configure stages rows (the database checks it on every row, as the legacy import's
-- staging). A trigger function: it runs whoever writes the row, so nobody gets execute on it
create or replace function cma.device_import_staging_insert()
returns trigger
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
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
create or replace trigger stage_row instead of insert on cma.device_import_staging
  for each row execute function cma.device_import_staging_insert();
revoke all on cma.device_import_staging from public;
grant select, insert on cma.device_import_staging to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 5. The kinds a connection's rows imply
-- ---------------------------------------------------------------------------------------------
-- As 0008ze (104), plus assets when it holds devices
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
           or exists (select 1 from cma.connection_field x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
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
         then 'assets' end], null)
$$;

-- As 0008ze (104), with assets among the kinds
create or replace function cma.set_connection_kind(p_connection_id uuid, p_kind text)
returns void
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_held   text[];
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  if coalesce(p_kind, '') not in ('crm', 'telephony', 'commerce', 'automation', 'reviews', 'assets') then
    raise exception 'kind must be crm, telephony, commerce, automation, reviews or assets' using errcode = 'CMA04';
  end if;
  v_held := cma.connection_held_kinds_of(v_tenant, p_connection_id);
  if cardinality(v_held) > 0 and not (p_kind = any (v_held)) then
    raise exception 'the connection holds % data; its kind cannot be %', array_to_string(v_held, ' and '), p_kind
      using errcode = 'CMA03';
  end if;
  update cma.integration_connection c set kind = p_kind
  where c.tenant_id = v_tenant and c.id = p_connection_id and c.kind is distinct from p_kind;
end
$$;

-- Whether a tenant has an asset register set up: an active connection of kind assets, or one holding devices
create or replace function cma.assets_set_up_of(p_tenant_id uuid)
returns boolean
language sql stable
as $$
  select exists (select 1 from cma.integration_connection c
                 where c.tenant_id = p_tenant_id and c.status = 'active'
                   and (c.kind = 'assets'
                        or exists (select 1 from cma.device d where d.tenant_id = c.tenant_id and d.connection_id = c.id)))
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. The load (tenant.configure)
-- ---------------------------------------------------------------------------------------------
-- A connection the devices may land in: its kind is assets, or not set yet while it holds no other kind's rows (its
-- devices then make it one); CMA04 otherwise
create or replace function cma.assert_assets_connection(p_connection_id uuid)
returns void
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_kind   text;
begin
  select c.kind into v_kind from cma.integration_connection c where c.tenant_id = v_tenant and c.id = p_connection_id;
  if (v_kind is not null and v_kind <> 'assets')
     or (v_kind is null and not (cma.connection_held_kinds_of(v_tenant, p_connection_id) <@ array['assets'])) then
    raise exception 'connection % is not an asset register connection', p_connection_id using errcode = 'CMA04';
  end if;
end
$$;

-- A staged id or label: trimmed, null when empty; a value with a control character or an @ is no id and reads as null
create or replace function cma.device_staged_text(p_value text)
returns text
language sql immutable
as $$
  select case when nullif(btrim(p_value), '') is null then null
              when btrim(p_value) ~ '[[:cntrl:]@]' or length(btrim(p_value)) > 100 then null
              else btrim(p_value) end
$$;

-- A staged reference (serial, warehouse, subscription, order, a named id, a component's serial): the staged text when it
-- is an id (letters, digits, space, _ . # : / -, starting with a letter, a digit or #, at most 100), else null
create or replace function cma.device_staged_ref(p_value text)
returns text
language sql immutable
as $$
  select case when cma.device_staged_text(p_value) ~ '^[A-Za-z0-9#][A-Za-z0-9 _.#:/-]{0,99}$' then cma.device_staged_text(p_value) end
$$;

-- A staged date: YYYY-MM-DD (the import tool writes every date so), null when empty; anything else refuses the load
-- (CMA04) naming the export's line and the column
create or replace function cma.device_staged_date(p_value text, p_row integer, p_column text)
returns date
language plpgsql immutable
as $$
begin
  if nullif(btrim(p_value), '') is null then
    return null;
  end if;
  if btrim(p_value) !~ '^\d{4}-\d{2}-\d{2}$' then
    raise exception 'line %: % is not a date as YYYY-MM-DD', coalesce(p_row::text, '?'), p_column using errcode = 'CMA04';
  end if;
  return btrim(p_value)::date;
exception when invalid_datetime_format or datetime_field_overflow then
  raise exception 'line %: % is not a date as YYYY-MM-DD', coalesce(p_row::text, '?'), p_column using errcode = 'CMA04';
end
$$;

-- A staged JSON object (components, external_refs): an object, {} when empty; anything else refuses the load (CMA04)
create or replace function cma.device_staged_object(p_value text, p_row integer, p_column text)
returns jsonb
language plpgsql immutable
as $$
declare
  v jsonb;
begin
  if nullif(btrim(p_value), '') is null then
    return '{}'::jsonb;
  end if;
  v := btrim(p_value)::jsonb;
  if jsonb_typeof(v) <> 'object' then
    raise exception 'line %: % is not a JSON object', coalesce(p_row::text, '?'), p_column using errcode = 'CMA04';
  end if;
  return v;
exception when invalid_text_representation then
  raise exception 'line %: % is not a JSON object', coalesce(p_row::text, '?'), p_column using errcode = 'CMA04';
end
$$;

-- Loads one staged batch into the connection's devices (tenant.configure), in the caller's transaction:
--   checks    the batch has rows (CMA02); every row has a record id and no id appears twice; every date is YYYY-MM-DD;
--             components and external_refs are JSON objects; every component kind is in the catalog, each with only
--             serial and expires_on (all CMA04, naming the export's line)
--   devices   per row: model, status and market mapped (the catalogs' aliases, cma.market_code_of), each null when
--             unmapped; the references kept only when they are ids (the customer reference only when it matches
--             ^[A-Za-z0-9_-]{1,100}$, else customer_ref_invalid); raw the row as mapped. A new record is inserted; a
--             known one is updated when anything differs (and comes back when it was missing), else unchanged
--   components per staged kind with a serial or an expiry: none current, inserted; a current one whose serial differs
--             from the staged serial (both present), replaced (replaced_at now, the new one inserted); otherwise the
--             current one takes the staged serial and expiry. A kind the row does not stage is left as it is
--   a full    snapshot (p_is_full) marks the connection's devices it does not hold with source_deleted_at
--   a run     one sync_run of job assets_import with the batch key as its stream and the counts; the batch's staged
--             rows are deleted
-- Answers the counts: rows, inserted, updated, unchanged, missing_now, components_replaced, unmapped_model,
-- unmapped_status, unmapped_market, customer_ref_invalid and refs_dropped (a reference, serial or named id that is no
-- id, left out)
create or replace function cma.load_device_snapshot(p_batch_key text, p_connection_id uuid, p_is_full boolean)
returns jsonb
language plpgsql
as $$
declare
  v_tenant   uuid := cma.current_tenant_id();
  v_system   text;
  v_run      uuid;
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
  perform cma.assert_permission('tenant.configure');
  v_system := cma.active_connection_adapter(p_connection_id);
  perform cma.assert_assets_connection(p_connection_id);
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

  insert into cma.sync_run (tenant_id, connection_id, job, stream)
  values (v_tenant, p_connection_id, 'assets_import', p_batch_key)
  returning id into v_run;

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

  -- a full snapshot: the connection's devices it does not hold are missing now
  if p_is_full then
    update cma.device d set source_deleted_at = now(), synced_at = now()
    where d.tenant_id = v_tenant and d.connection_id = p_connection_id and d.source_deleted_at is null
      and not exists (select 1 from cma.device_import_row s
                      where s.tenant_id = v_tenant and s.batch_key = p_batch_key and cma.device_staged_text(s.source_id) = d.source_id);
    get diagnostics v_missing = row_count;
  end if;

  delete from cma.device_import_row s where s.tenant_id = v_tenant and s.batch_key = p_batch_key;

  v_counts := jsonb_build_object('rows', v_rows, 'inserted', v_ins, 'updated', v_upd, 'unchanged', v_same, 'missing_now', v_missing,
                                 'components_replaced', v_repl, 'unmapped_model', v_um, 'unmapped_status', v_us,
                                 'unmapped_market', v_uk, 'customer_ref_invalid', v_ucr, 'refs_dropped', v_drop);
  update cma.sync_run sr set status = 'succeeded', finished_at = now(), counts = v_counts
  where sr.tenant_id = v_tenant and sr.id = v_run;
  return v_counts;
exception when check_violation or not_null_violation or foreign_key_violation then
  raise exception 'invalid device: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. The forecast: due items, action dates, planned exchanges
-- ---------------------------------------------------------------------------------------------
-- Every due item of a tenant's tracked devices (a device status with is_tracked, not missing from the latest full
-- snapshot) as of p_today (the tenant's date; a verifier gives a fixed one):
--   a component  for every active component kind the device carries (a current component), its model has a rule for,
--                or of every kind while the model is unknown. Due date: the recorded expiry (basis recorded), else the
--                anchor date plus the rule's interval in months (basis rule), else none (basis unknown). The anchor:
--                the day the current component was first seen, in the tenant's zone, when it replaced another of its
--                kind on the device (a replacement restarts the rule); else the last shipment, else the first. Action
--                date: the due date less the rule's lead days (none without a rule)
--   the device   at its end of life (component device): the recorded end-of-life date, basis recorded, no lead days;
--                no item without one
--   past due     the action date lies before p_today's month
--   exchange     the planned exchange: per device, ordered by action date, an item joins the exchange of the earliest
--                item before it when its action date lies within assets.bundle_window_days of that exchange's first
--                action date; else it starts a new one. exchange_on is the exchange's first action date, exchange_key the
--                device and that date. An item of basis unknown has no action date and no exchange
create or replace function cma.maintenance_items_of(p_tenant_id uuid, p_today date)
returns table (device_id uuid, connection_id uuid, source_id text, serial text, model_key text, market text, device_status_key text,
               is_in_field boolean, is_in_stock boolean, component_key text, component_order integer, due_on date, basis text,
               action_on date, past_due boolean, exchange_key text, exchange_on date)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_win    integer := greatest(coalesce(nullif(cma.setting_of(p_tenant_id, 'assets.bundle_window_days'), '')::integer, 0), 0);
  v_month  date := date_trunc('month', p_today)::date;
  v_zone   text := (select t.timezone from cma.tenant t where t.id = p_tenant_id);
  v_device uuid;
  v_start  date;
  r        record;
begin
  -- one pass over the items in device and action-date order: the exchange starts again at a new device, and at an item
  -- whose action date lies beyond the window from the exchange's first action date
  for r in
    with d as (
      select dv.id, dv.connection_id, dv.source_id, dv.serial, dv.model_key, dv.market, dv.device_status_key, st.is_in_field, st.is_in_stock,
             coalesce(dv.last_shipped_on, dv.first_shipped_on) as anchor, dv.end_of_life_on
      from cma.device dv
      join cma.device_status st on st.tenant_id = dv.tenant_id and st.key = dv.device_status_key and st.is_tracked
      where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null
    ), rp as (
      -- the devices' kinds with a replaced component: their current component is a replacement
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
      join cma.device_component_kind k on k.tenant_id = p_tenant_id and k.status = 'active'
      left join cma.device_component c
        on c.tenant_id = p_tenant_id and c.device_id = d.id and c.component_key = k.key and c.replaced_at is null
      left join rp on rp.device_id = c.device_id and rp.component_key = c.component_key
      left join cma.maintenance_rule ru on ru.tenant_id = p_tenant_id and ru.model_key = d.model_key and ru.component_key = k.key
      cross join lateral (select case when rp.device_id is not null then (c.first_seen_at at time zone v_zone)::date
                                      else d.anchor end as anchor) a
      where c.id is not null or ru.id is not null or d.model_key is null
      union all
      select d.id, d.connection_id, d.source_id, d.serial, d.model_key, d.market, d.device_status_key, d.is_in_field, d.is_in_stock,
             'device', 2147483647, d.end_of_life_on, null::date, 0
      from d
      where d.end_of_life_on is not null
    )
    select it.*, coalesce(it.recorded, it.by_rule) as due,
           case when it.recorded is not null then 'recorded' when it.by_rule is not null then 'rule' else 'unknown' end as how,
           coalesce(it.recorded, it.by_rule) - it.lead_days as act
    from it
    order by it.id, coalesce(it.recorded, it.by_rule) - it.lead_days nulls last, it.component_order, it.component_key
  loop
    device_id := r.id; connection_id := r.connection_id; source_id := r.source_id; serial := r.serial; model_key := r.model_key;
    market := r.market; device_status_key := r.device_status_key; is_in_field := r.is_in_field; is_in_stock := r.is_in_stock;
    component_key := r.component_key; component_order := r.component_order; due_on := r.due; basis := r.how; action_on := r.act;
    past_due := coalesce(r.act < v_month, false);
    if r.act is null then
      exchange_on := null;
      exchange_key := null;
    else
      if v_device is distinct from r.id or v_start is null or r.act > v_start + v_win then
        v_start := r.act;
      end if;
      v_device := r.id;
      exchange_on := v_start;
      exchange_key := r.id::text || ':' || to_char(v_start, 'YYYY-MM-DD');
    end if;
    return next;
  end loop;
end
$$;

-- The tenant's date now, in its zone
create or replace function cma.tenant_today_of(p_tenant_id uuid)
returns date
language sql stable
as $$
  select (now() at time zone t.timezone)::date from cma.tenant t where t.id = p_tenant_id
$$;

-- A forecast's horizon: from the first day of a month, the current month or later, for 1 to 24 months (CMA04 otherwise)
create or replace function cma.assert_maintenance_horizon(p_from_month date, p_months integer, p_today date)
returns void
language plpgsql immutable
as $$
begin
  if p_from_month is null or p_from_month <> date_trunc('month', p_from_month)::date then
    raise exception 'the horizon starts on the first day of a month' using errcode = 'CMA04';
  end if;
  if p_from_month < date_trunc('month', p_today)::date then
    raise exception 'the horizon starts in the current month or later (the months before are past due)' using errcode = 'CMA04';
  end if;
  if p_months is null or p_months not between 1 and 24 then
    raise exception 'the horizon is 1 to 24 months' using errcode = 'CMA04';
  end if;
end
$$;

-- The due items of the horizon for the application (reports.view or performance.team): every past-due item, every item
-- whose action date falls in the horizon, and every item of basis unknown
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
    select i.* from cma.maintenance_items_of(v_tenant, v_today) i
    where i.basis = 'unknown' or i.past_due
       or (i.action_on >= p_from_month and i.action_on < (p_from_month + make_interval(months => p_months))::date)
    order by i.action_on nulls last, i.market, i.model_key, i.serial, i.component_order;
end
$$;

-- The checks every Maintenance read makes on its filters (CMA04): a market's code or unknown; a model's key or unknown;
-- the scope field or stock (null: every tracked device)
create or replace function cma.assert_maintenance_filters(p_market text, p_model text, p_scope text)
returns void
language plpgsql immutable
as $$
begin
  if p_market is not null and p_market !~ '^([A-Z]{2}|unknown)$' then
    raise exception 'a market filter is a two-letter code or unknown' using errcode = 'CMA04';
  end if;
  if p_model is not null and (p_model !~ '^[a-z0-9]+(_[a-z0-9]+)*$' or length(p_model) > 40) then
    raise exception 'a model filter is a model''s key or unknown' using errcode = 'CMA04';
  end if;
  if p_scope is not null and p_scope not in ('field', 'stock') then
    raise exception 'the scope is field or stock' using errcode = 'CMA04';
  end if;
end
$$;

-- The due items of a horizon after the filters, each with its bucket (past_due, or the first day of its action month
-- within the horizon, as text; null beyond it) and its exchange's bucket (the same for the exchange's first action date)
create or replace function cma.maintenance_bucketed_of(p_tenant_id uuid, p_from_month date, p_months integer, p_market text, p_model text,
                                                       p_scope text, p_today date)
returns table (device_id uuid, connection_id uuid, source_id text, serial text, model_key text, market text, device_status_key text,
               component_key text, component_order integer, due_on date, basis text, action_on date, past_due boolean, exchange_key text,
               exchange_on date, bucket text, exchange_bucket text)
language sql stable
as $$
  with h as (
    select date_trunc('month', p_today)::date as month_start, (p_from_month + make_interval(months => p_months))::date as until
  )
  select i.device_id, i.connection_id, i.source_id, i.serial, coalesce(i.model_key, 'unknown'), coalesce(i.market, 'unknown'),
         i.device_status_key, i.component_key, i.component_order, i.due_on, i.basis, i.action_on, i.past_due, i.exchange_key, i.exchange_on,
         case when i.past_due then 'past_due'
              when i.action_on >= p_from_month and i.action_on < h.until then to_char(date_trunc('month', i.action_on), 'YYYY-MM-DD') end,
         case when i.exchange_on < h.month_start then 'past_due'
              when i.exchange_on >= p_from_month and i.exchange_on < h.until then to_char(date_trunc('month', i.exchange_on), 'YYYY-MM-DD') end
  from cma.maintenance_items_of(p_tenant_id, p_today) i
  cross join h
  where (p_scope is null or (p_scope = 'field' and i.is_in_field) or (p_scope = 'stock' and i.is_in_stock))
    and (p_market is null or coalesce(i.market, 'unknown') = p_market)
    and (p_model is null or coalesce(i.model_key, 'unknown') = p_model)
$$;

-- ---------------------------------------------------------------------------------------------
-- 8. Reports, Maintenance (reports.view or performance.team)
-- ---------------------------------------------------------------------------------------------
-- The page for an explicit tenant as of p_today: the buckets (past_due, then every month of the horizon), the active
-- component kinds, one cell per bucket, market and model holding items (the components' items per kind, the devices at
-- end of life, the planned exchanges counted in the bucket of their first action date), the unknown-basis items per
-- market and model, the tracked devices after the filters, the bundling window, whether an asset register is set up,
-- and the markets and models the filters offer (of every tracked device)
create or replace function cma.maintenance_page_of(p_tenant_id uuid, p_from_month date, p_months integer, p_market text, p_model text,
                                                   p_scope text, p_today date)
returns jsonb
language sql stable
as $$
  with b as materialized (
    select * from cma.maintenance_bucketed_of(p_tenant_id, p_from_month, p_months, p_market, p_model, p_scope, p_today)
  ), comp as (
    select x.bucket, x.market, x.model_key, jsonb_object_agg(x.component_key, x.n) as components, sum(x.n)::integer as component_items
    from (select bucket, market, model_key, component_key, count(*)::integer as n
          from b where bucket is not null and component_key <> 'device' group by 1, 2, 3, 4) x
    group by 1, 2, 3
  ), eol as (
    select bucket, market, model_key, count(*)::integer as n from b where bucket is not null and component_key = 'device' group by 1, 2, 3
  ), exch as (
    select exchange_bucket as bucket, market, model_key, count(distinct exchange_key)::integer as n
    from b where exchange_bucket is not null group by 1, 2, 3
  ), cells as (
    select k.bucket, k.market, k.model_key, coalesce(c.components, '{}'::jsonb) as components, coalesce(c.component_items, 0) as component_items,
           coalesce(e.n, 0) as end_of_life, coalesce(x.n, 0) as exchanges
    from (select bucket, market, model_key from comp union select bucket, market, model_key from eol
          union select bucket, market, model_key from exch) k
    left join comp c on c.bucket = k.bucket and c.market = k.market and c.model_key = k.model_key
    left join eol e on e.bucket = k.bucket and e.market = k.market and e.model_key = k.model_key
    left join exch x on x.bucket = k.bucket and x.market = k.market and x.model_key = k.model_key
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
    'cells', (select coalesce(jsonb_agg(jsonb_build_object('bucket', c.bucket, 'market', c.market, 'model', c.model_key,
                                                           'components', c.components, 'component_items', c.component_items,
                                                           'end_of_life', c.end_of_life, 'exchanges', c.exchanges)
                                        order by (c.bucket <> 'past_due'), c.bucket, (c.market = 'unknown'), mk.sort_order, c.market,
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

-- Reports, Maintenance in one read (reports.view or performance.team): a horizon from the first day of the current month
-- or a later one, 1 to 24 months; a market's code or unknown; a model's key or unknown; the scope field or stock (null:
-- every tracked device). Team figures only: no figure per person exists
create or replace function cma.maintenance_page(p_from_month date, p_months integer default 12, p_market text default null,
                                                p_model text default null, p_scope text default null)
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
  return cma.maintenance_page_of(v_tenant, p_from_month, p_months, p_market, p_model, p_scope, v_today);
end
$$;

-- The device list of one cell for an explicit tenant as of p_today. p_bucket: past_due, the first day of a month of the
-- horizon (YYYY-MM-DD), unknown (the unknown-basis items) or all (past_due and every month); p_view exchanges (one row per
-- planned exchange of the bucket, with all its items) or components (one row per device and bucket, the items whose
-- action month is the bucket). Each row: the device's ids and serial, model, market, device status, the components due
-- (device for its end of life), the earliest due date, the bases, the earliest action date, the exchange's first action
-- date, the customer and subscription references, and the CRM contact of the customer reference: the one contact the
-- tenant's commerce customers with that id are linked to (0008h), else none. Ordered by action date, market, model and
-- serial; at most p_limit rows, total_rows the count before the limit
create or replace function cma.maintenance_rows_of(p_tenant_id uuid, p_from_month date, p_months integer, p_bucket text, p_market text,
                                                   p_model text, p_scope text, p_view text, p_limit integer, p_today date)
returns table (bucket text, device_id uuid, connection_id uuid, source_id text, serial text, model_key text, model_name text, market text,
               device_status_key text, device_status_name text, components text[], due_on date, bases text[], action_on date,
               exchange_on date, customer_ref text, subscription_ref text, crm_connection_id uuid, crm_contact_source_id text,
               total_rows bigint)
language sql stable
as $$
  with b as (
    select x.*,
           case when x.basis = 'unknown' then 'unknown' when p_view = 'exchanges' then x.exchange_bucket else x.bucket end as row_bucket
    from cma.maintenance_bucketed_of(p_tenant_id, p_from_month, p_months, p_market, p_model, p_scope, p_today) x
  ), g as (
    select b.row_bucket, b.device_id,
           case when p_view = 'exchanges' and b.row_bucket <> 'unknown' then b.exchange_key else '' end as grp,
           array_agg(b.component_key order by b.component_order, b.component_key) as components,
           min(b.due_on) as due_on, array_agg(distinct b.basis order by b.basis) as bases, min(b.action_on) as action_on,
           min(b.exchange_on) as exchange_on
    from b
    where case when p_bucket = 'unknown' then b.row_bucket = 'unknown'
               when p_bucket = 'all' then b.row_bucket is not null and b.row_bucket <> 'unknown'
               else b.row_bucket = p_bucket end
    group by 1, 2, 3
  )
  select g.row_bucket, dv.id, dv.connection_id, dv.source_id, dv.serial, coalesce(dv.model_key, 'unknown'), md.name,
         coalesce(dv.market, 'unknown'), dv.device_status_key, st.name, g.components, g.due_on, g.bases, g.action_on, g.exchange_on,
         dv.customer_ref, dv.subscription_ref, ct.crm_connection_id, ct.crm_contact_source_id, count(*) over ()
  from g
  join cma.device dv on dv.tenant_id = p_tenant_id and dv.id = g.device_id
  left join cma.device_model md on md.tenant_id = dv.tenant_id and md.key = dv.model_key
  left join cma.device_status st on st.tenant_id = dv.tenant_id and st.key = dv.device_status_key
  left join lateral (
    select case when count(distinct (cu.crm_connection_id, cu.crm_contact_source_id)) = 1 then (array_agg(cu.crm_connection_id))[1] end as crm_connection_id,
           case when count(distinct (cu.crm_connection_id, cu.crm_contact_source_id)) = 1 then (array_agg(cu.crm_contact_source_id))[1] end as crm_contact_source_id
    from cma.commerce_customer cu
    where cu.tenant_id = dv.tenant_id and dv.customer_ref is not null and cu.source_id = dv.customer_ref
      and cu.source_deleted_at is null and cu.crm_contact_source_id is not null
  ) ct on true
  order by g.action_on nulls last, coalesce(dv.market, 'unknown') = 'unknown', dv.market, dv.model_key, dv.serial nulls last, dv.source_id, g.grp
  limit p_limit
$$;

-- The device list of one cell (reports.view or performance.team): the page's horizon and filters, a bucket (past_due, a
-- month of the horizon as YYYY-MM-DD, unknown or all), the view exchanges or components, at most p_limit rows (1 to 5000)
create or replace function cma.maintenance_rows(p_from_month date, p_months integer, p_bucket text, p_market text default null,
                                                p_model text default null, p_scope text default null, p_view text default 'exchanges',
                                                p_limit integer default 500)
returns table (bucket text, device_id uuid, connection_id uuid, source_id text, serial text, model_key text, model_name text, market text,
               device_status_key text, device_status_name text, components text[], due_on date, bases text[], action_on date,
               exchange_on date, customer_ref text, subscription_ref text, crm_connection_id uuid, crm_contact_source_id text,
               total_rows bigint)
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
    select * from cma.maintenance_rows_of(v_tenant, p_from_month, p_months, p_bucket, p_market, p_model, p_scope, p_view, p_limit, v_today);
exception when invalid_datetime_format or datetime_field_overflow then
  raise exception 'the bucket is past_due, unknown, all or the first day of a month of the horizon' using errcode = 'CMA04';
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 9. The setting's check
-- ---------------------------------------------------------------------------------------------
-- As 0008ze (104), with assets.bundle_window_days (0 to 365)
create or replace function cma.check_tenant_setting()
returns trigger
language plpgsql
as $$
declare
  s       cma.setting;
  v_other time;
begin
  select * into s from cma.setting where key = new.key;
  if not found then
    raise exception 'Unknown setting %', new.key using errcode = 'CMA02';
  end if;
  if new.key = 'auth.invitation_email_domains' then
    new.value := lower(regexp_replace(new.value, '[[:space:]]+', '', 'g'));
  end if;
  if new.key in ('email.start_date', 'reviews.history_start_date') then
    new.value := btrim(new.value);
  end if;
  if new.key in ('leads.age_buckets_business_days', 'attempts.since_last_buckets_business_days', 'attempts.speed_buckets_business_minutes') then
    new.value := regexp_replace(new.value, '[[:space:]]+', '', 'g');
  end if;
  if s.value_type = 'boolean' and new.value not in ('true', 'false') then
    raise exception 'Setting % takes true or false', new.key using errcode = 'CMA04';
  end if;
  if s.value_type = 'integer' and new.value !~ '^-?[0-9]+$' then
    raise exception 'Setting % takes a whole number', new.key using errcode = 'CMA04';
  end if;
  if s.value_type = 'date' or (new.key in ('email.start_date', 'reviews.history_start_date') and new.value <> '') then
    if new.value !~ '^\d{4}-\d{2}-\d{2}$' then
      raise exception 'Setting % takes a date as YYYY-MM-DD', new.key using errcode = 'CMA04';
    end if;
    begin
      perform new.value::date;
    exception when others then
      raise exception 'Setting % takes a date as YYYY-MM-DD', new.key using errcode = 'CMA04';
    end;
  end if;
  if s.value_type = 'time' and new.value !~ '^(([01][0-9]|2[0-3]):[0-5][0-9]|24:00)$' then
    raise exception 'Setting % takes a time as HH:MI, 00:00 to 24:00', new.key using errcode = 'CMA04';
  end if;
  if s.allowed_values is not null and not (new.value = any (s.allowed_values)) then
    raise exception 'Setting % takes one of: %', new.key, array_to_string(s.allowed_values, ', ')
      using errcode = 'CMA04';
  end if;
  -- the window starts before it ends, against the other bound's effective value
  if new.key = 'workday.window_start' then
    v_other := cma.setting_of(new.tenant_id, 'workday.window_end')::time;
    if new.value::time >= v_other then
      raise exception 'The workday window must start before it ends (%)', to_char(v_other, 'HH24:MI') using errcode = 'CMA04';
    end if;
  elsif new.key = 'workday.window_end' then
    v_other := cma.setting_of(new.tenant_id, 'workday.window_start')::time;
    if new.value::time <= v_other then
      raise exception 'The workday window must end after it starts (%)', to_char(v_other, 'HH24:MI') using errcode = 'CMA04';
    end if;
  elsif new.key = 'workday.auto_close_notify_permission' and not exists (select 1 from cma.permission p where p.key = new.value) then
    raise exception 'Setting % takes a permission key', new.key using errcode = 'CMA04';
  elsif new.key = 'auth.invitation_valid_days'
        and (case when length(new.value) > 3 then true else new.value::integer not between 1 and 30 end) then
    raise exception 'Setting % takes a whole number of days from 1 to 30', new.key using errcode = 'CMA04';
  elsif new.key = 'auth.invitation_email_domains' and not cma.is_domain_list(new.value) then
    raise exception 'Setting % takes domain names separated by commas, such as example.com,example.org', new.key using errcode = 'CMA04';
  elsif new.key = 'email.reply_target_minutes'
        and (case when length(new.value) > 5 then true else new.value::integer not between 1 and 10080 end) then
    raise exception 'Setting % takes a whole number of minutes from 1 to 10080', new.key using errcode = 'CMA04';
  elsif new.key = 'email.no_response_days'
        and (case when length(new.value) > 2 then true else new.value::integer not between 1 and 90 end) then
    raise exception 'Setting % takes a whole number of days from 1 to 90', new.key using errcode = 'CMA04';
  elsif new.key = 'email.market_order' and not cma.is_email_market_order(new.value) then
    raise exception 'Setting % takes contact, form, record and inbox in the order wanted, lower case, comma-separated without spaces, each at most once, such as contact,form,record,inbox', new.key
      using errcode = 'CMA04';
  -- the follow-up layer (0008o)
  elsif new.key = 'tickets.sla_minutes'
        and (case when length(new.value) > 6 then true else new.value::integer not between 1 and 100000 end) then
    raise exception 'Setting % takes a whole number of business minutes from 1 to 100000', new.key using errcode = 'CMA04';
  elsif new.key = 'tickets.sla_warning_pct'
        and (case when length(new.value) > 3 then true else new.value::integer not between 1 and 100 end) then
    raise exception 'Setting % takes a share from 1 to 100', new.key using errcode = 'CMA04';
  elsif new.key = 'leads.age_buckets_business_days' and not cma.is_bucket_list(new.value) then
    raise exception 'Setting % takes one to five increasing whole numbers of business days, comma-separated, such as 1,2,5', new.key using errcode = 'CMA04';
  elsif new.key = 'tasks.callback_window_minutes'
        and (case when length(new.value) > 5 then true else new.value::integer not between 0 and 10080 end) then
    raise exception 'Setting % takes a whole number of minutes from 0 to 10080', new.key using errcode = 'CMA04';
  -- the System health page (0008r): the ingest heartbeat's thresholds, fresh below the first, silent
  -- from the second, late in between
  elsif new.key = 'health.heartbeat_fresh_seconds' then
    if (case when length(new.value) > 4 then true else new.value::integer not between 10 and 3600 end) then
      raise exception 'Setting % takes a whole number of seconds from 10 to 3600', new.key using errcode = 'CMA04';
    end if;
    if new.value::integer >= cma.setting_of(new.tenant_id, 'health.heartbeat_late_seconds')::integer then
      raise exception 'The heartbeat counts as fresh for fewer seconds than it takes to count as silent (%)',
        cma.setting_of(new.tenant_id, 'health.heartbeat_late_seconds') using errcode = 'CMA04';
    end if;
  elsif new.key = 'health.heartbeat_late_seconds' then
    if (case when length(new.value) > 5 then true else new.value::integer not between 60 and 86400 end) then
      raise exception 'Setting % takes a whole number of seconds from 60 to 86400', new.key using errcode = 'CMA04';
    end if;
    if new.value::integer <= cma.setting_of(new.tenant_id, 'health.heartbeat_fresh_seconds')::integer then
      raise exception 'The heartbeat counts as silent after more seconds than it counts as fresh (%)',
        cma.setting_of(new.tenant_id, 'health.heartbeat_fresh_seconds') using errcode = 'CMA04';
    end if;
  -- the two links System health shows: an https address of at most 500 characters without spaces, or empty
  elsif new.key in ('health.link_gemini_doc', 'health.link_datamap') then
    new.value := btrim(new.value);
    if new.value <> '' and (length(new.value) > 500 or new.value !~ '^https://[^[:space:]"''<>]+$') then
      raise exception 'Setting % takes an https address, or nothing', new.key using errcode = 'CMA04';
    end if;
  -- the follow-up snapshot (0008s): the rows each list of Reports → Follow-up shows
  elsif new.key = 'follow_up.list_rows'
        and (case when length(new.value) > 3 then true else new.value::integer not between 1 and 500 end) then
    raise exception 'Setting % takes a whole number of rows from 1 to 500', new.key using errcode = 'CMA04';
  -- the per-person report pages (0008t; attempts since 0008y): from the fixed list email, orders, attempts
  elsif new.key = 'reports.per_person' and not cma.is_per_person_list(new.value) then
    raise exception 'Setting % takes email, orders, attempts and deals, each at most once, lower case, comma-separated without spaces, or nothing', new.key
      using errcode = 'CMA04';
  -- first orders (0008u)
  elsif new.key = 'attribution.window_days'
        and (case when length(new.value) > 3 then true else new.value::integer not between 1 and 365 end) then
    raise exception 'Setting % takes a whole number of days from 1 to 365', new.key using errcode = 'CMA04';
  elsif new.key = 'attribution.level_order' and not cma.is_attribution_levels(new.value, false) then
    raise exception 'Setting % takes one to six of lead_deal, conversation, email, phone_match, attempt and known_contact in the order wanted, each once, lower case, comma-separated without spaces', new.key
      using errcode = 'CMA04';
  elsif new.key = 'attribution.assisted_levels' and not cma.is_attribution_levels(new.value, true) then
    raise exception 'Setting % takes levels from lead_deal, conversation, email, phone_match, attempt and known_contact, each once, lower case, comma-separated without spaces, or nothing', new.key
      using errcode = 'CMA04';
  elsif new.key = 'attribution.known_contact_minutes'
        and (case when length(new.value) > 5 then true else new.value::integer not between 0 and 10080 end) then
    raise exception 'Setting % takes a whole number of minutes from 0 to 10080', new.key using errcode = 'CMA04';
  elsif new.key = 'attribution.order_match_minutes'
        and (case when length(new.value) > 5 then true else new.value::integer not between 1 and 10080 end) then
    raise exception 'Setting % takes a whole number of minutes from 1 to 10080', new.key using errcode = 'CMA04';
  -- attempts per deal (0008y)
  elsif new.key = 'attempts.max_bucket'
        and (case when length(new.value) > 2 then true else new.value::integer not between 2 and 20 end) then
    raise exception 'Setting % takes a whole number of attempts from 2 to 20', new.key using errcode = 'CMA04';
  elsif new.key = 'attempts.since_last_buckets_business_days' and not cma.is_bucket_list(new.value, 6) then
    raise exception 'Setting % takes one to six increasing whole numbers of business days, comma-separated, such as 1,2,5', new.key using errcode = 'CMA04';
  -- attempts per deal for sales (0008z); attempts.source is held to its two values by the catalog
  elsif new.key = 'attempts.speed_buckets_business_minutes' and not cma.is_bucket_list(new.value, 6) then
    raise exception 'Setting % takes one to six increasing whole numbers of business minutes, comma-separated, such as 5,15,60,240,1440', new.key using errcode = 'CMA04';
  -- Conversation (0008zc): the talk time a connected or answered call needs
  elsif new.key = 'calls.conversation_min_talk_seconds'
        and (case when length(new.value) > 3 then true else new.value::integer not between 0 and 600 end) then
    raise exception 'Setting % takes a whole number of seconds from 0 to 600', new.key using errcode = 'CMA04';
  -- the funnel reports (0008zb): the record kind Reports, Cancellations counts, an active kind of the tenant, or nothing
  elsif new.key = 'reports.cancellation_kind' then
    new.value := btrim(new.value);
    if new.value <> '' and not exists (select 1 from cma.record_kind k
                                       where k.tenant_id = new.tenant_id and k.key = new.value and k.status = 'active') then
      raise exception 'Setting % takes the key of an active record kind, or nothing', new.key using errcode = 'CMA04';
    end if;
  -- reviews (0008ze): the highest rating that is a negative review, a whole star from 1 to 4
  elsif new.key = 'reviews.negative_max_rating'
        and (case when length(new.value) > 1 then true else new.value::integer not between 1 and 4 end) then
    raise exception 'Setting % takes a whole number of stars from 1 to 4', new.key using errcode = 'CMA04';
  -- assets (0008zi): the bundling window, a whole number of days from 0 to 365
  elsif new.key = 'assets.bundle_window_days'
        and (case when length(new.value) > 3 then true else new.value::integer not between 0 and 365 end) then
    raise exception 'Setting % takes a whole number of days from 0 to 365', new.key using errcode = 'CMA04';
  end if;
  new.updated_by := cma.current_user_id();
  return new;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 10. Data quality: the asset register's checks
-- ---------------------------------------------------------------------------------------------
-- The asset register's checks, listed apart and shown after 0008ze's, as each addition lists its own: shown once the
-- tenant has an asset register set up, or while one finds something
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
    ('field_device_without_subscription_ref', 300, 'Devices in the field without a subscription reference')
$$;

-- As 0008ze (104), plus the asset register's eight checks: devices without a serial, a serial two devices hold,
-- unmapped models, statuses and countries (the value the register's label), an invalid customer reference, due items
-- without a due date (the value the component) and devices in the field without a subscription reference
create or replace function cma.data_quality_of(p_tenant_id uuid)
returns table (check_key text, connection_id uuid, object_type text, object_id text, value text)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_start timestamptz;
begin
  select cma.setting_of(t.id, 'intake.start_date')::date::timestamp at time zone t.timezone into v_start
  from cma.tenant t where t.id = p_tenant_id;

  return query
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
    and nullif(btrim(cr.market), '') is not null and cma.market_code_of(p_tenant_id, cr.market) is null
  union all
  select 'market_not_in_catalog', k.connection_id, 'contact', k.source_id, k.country
  from cma.crm_contact k
  where k.tenant_id = p_tenant_id and k.source_deleted_at is null
    and nullif(btrim(k.country), '') is not null and cma.market_code_of(p_tenant_id, k.country) is null
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
  select case when h.contacts = 0 then 'commerce_unmatched' else 'commerce_ambiguous' end,
         cu.connection_id, 'commerce_customer', cu.source_id, null
  from cma.commerce_customer cu
  cross join lateral (select count(distinct r.contact_id) as contacts
                      from cma.crm_contact_ref r
                      where r.tenant_id = cu.tenant_id and r.system = cu.source_system and r.external_id = cu.source_id) h
  where cu.tenant_id = p_tenant_id and cu.source_deleted_at is null and h.contacts <> 1
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
         cma.market_code_of(p_tenant_id, k.country) || '/' || st.market
  from cma.crm_contact k
  join cma.crm_contact_ref r on r.tenant_id = k.tenant_id and r.contact_id = k.id
  join cma.commerce_customer cu
    on cu.tenant_id = r.tenant_id and cu.source_system = r.system and cu.source_id = r.external_id and cu.source_deleted_at is null
  join cma.commerce_store st on st.tenant_id = cu.tenant_id and st.connection_id = cu.connection_id
  where k.tenant_id = p_tenant_id and k.source_deleted_at is null
    and cma.market_code_of(p_tenant_id, k.country) is distinct from st.market
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
  from cma.open_tickets_of(p_tenant_id) t
  where t.owner_ref is null and cma.follow_up_configured_of(p_tenant_id)
  union all
  select 'ticket_no_market', t.connection_id, 'ticket', t.ticket_source_id, t.pipeline_id
  from cma.open_tickets_of(p_tenant_id) t
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
  -- devices in a status in the field without a subscription reference (0008zi)
  select 'field_device_without_subscription_ref', dv.connection_id, 'device', dv.source_id, null::text
  from cma.device dv
  join cma.device_status st on st.tenant_id = dv.tenant_id and st.key = dv.device_status_key and st.is_in_field
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.subscription_ref is null;

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

-- As 0008ze (104), plus the asset register's checks: listed once the tenant has an asset register set up, or while one
-- finds something. A tenant without either keeps every earlier row exactly
create or replace function cma.data_quality()
returns table (check_key text, description text, total integer)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'tenant.configure']);
  return query
    with q as materialized (select f.check_key from cma.data_quality_of(v_tenant) f),
    c as (
      select dc.check_key, dc.sort_order, dc.description from cma.data_quality_checks() dc
      union all
      select ac.check_key, ac.sort_order, ac.description from cma.data_quality_added_checks() ac
      where ac.check_key = 'contact_country_fallback'
        and (exists (select 1 from cma.connection_field cf
                     where cf.tenant_id = v_tenant and cf.entity = 'contact' and cf.field = 'country' and cf.slot > 1)
             or exists (select 1 from q where q.check_key = ac.check_key))
      union all
      select fc.check_key, fc.sort_order, fc.description from cma.data_quality_follow_up_checks() fc
      where (fc.check_key in ('ticket_no_owner', 'ticket_no_market')
             and (cma.follow_up_configured_of(v_tenant) or exists (select 1 from q where q.check_key = fc.check_key)))
         or (fc.check_key = 'crm_task_owner_unlinked'
             and (exists (select 1 from cma.crm_task k where k.tenant_id = v_tenant) or exists (select 1 from q where q.check_key = fc.check_key)))
      union all
      select xc.check_key, xc.sort_order, xc.description from cma.data_quality_forms_checks() xc
      where exists (select 1 from q where q.check_key = xc.check_key)
         or exists (select 1 from cma.connection_form f
                    where f.tenant_id = v_tenant and f.fields_refreshed_at is not null and cardinality(f.kept_fields) > 0)
      union all
      select rc.check_key, rc.sort_order, rc.description from cma.data_quality_reviews_checks() rc
      where cma.reviews_set_up_of(v_tenant) or exists (select 1 from q where q.check_key = rc.check_key)
      union all
      select sc.check_key, sc.sort_order, sc.description from cma.data_quality_assets_checks() sc
      where cma.assets_set_up_of(v_tenant) or exists (select 1 from q where q.check_key = sc.check_key)
    )
    select c.check_key, c.description,
           case when c.check_key = 'writeback_parked' and to_regclass('cma.outbox_action') is null then null
                else (select count(*) from q where q.check_key = c.check_key)::integer end
    from c
    order by c.sort_order;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 11. sync_run: the device import
-- ---------------------------------------------------------------------------------------------
alter table cma.sync_run drop constraint if exists sync_run_job_check;
alter table cma.sync_run add constraint sync_run_job_check
  check (job in ('backfill', 'reconcile', 'forms_poll', 'subscriptions_check', 'link_calls', 'email_poll', 'close_forgotten_workdays',
                 'refresh_follow_up', 'reviews_poll', 'legacy_call_import', 'assets_import')) not valid;
alter table cma.sync_run validate constraint sync_run_job_check;

-- ---------------------------------------------------------------------------------------------
-- 12. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.connection_held_kinds_of(uuid,uuid)',
    'cma.set_connection_kind(uuid,text)',
    'cma.device_model_key_of(uuid,text)',
    'cma.device_status_key_of(uuid,text)',
    'cma.assets_set_up_of(uuid)',
    'cma.assert_assets_connection(uuid)',
    'cma.device_staged_text(text)',
    'cma.device_staged_ref(text)',
    'cma.device_staged_date(text,integer,text)',
    'cma.device_staged_object(text,integer,text)',
    'cma.device_staged_without_at(text)',
    'cma.device_staged_object_without_at(text)',
    'cma.load_device_snapshot(text,uuid,boolean)',
    'cma.maintenance_items_of(uuid,date)',
    'cma.tenant_today_of(uuid)',
    'cma.assert_maintenance_horizon(date,integer,date)',
    'cma.maintenance_due_of(date,integer)',
    'cma.assert_maintenance_filters(text,text,text)',
    'cma.maintenance_bucketed_of(uuid,date,integer,text,text,text,date)',
    'cma.maintenance_page_of(uuid,date,integer,text,text,text,date)',
    'cma.maintenance_page(date,integer,text,text,text)',
    'cma.maintenance_rows_of(uuid,date,integer,text,text,text,text,text,integer,date)',
    'cma.maintenance_rows(date,integer,text,text,text,text,text,integer)',
    'cma.data_quality_assets_checks()',
    'cma.data_quality_of(uuid)',
    'cma.data_quality()'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 13. Reporting views
-- ---------------------------------------------------------------------------------------------
-- The catalogs: every column (configuration, no personal data)
create or replace view cma_read.device_model as
  select id, tenant_id, key, name, brand, aliases, status, sort_order, created_at, updated_at
  from cma.device_model
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.device_component_kind as
  select id, tenant_id, key, name, status, sort_order, created_at, updated_at
  from cma.device_component_kind
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.maintenance_rule as
  select id, tenant_id, model_key, component_key, interval_months, lead_days, created_at, updated_at
  from cma.maintenance_rule
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.device_status as
  select id, tenant_id, key, name, is_in_field, is_in_stock, is_tracked, aliases, status, sort_order, created_at, updated_at
  from cma.device_status
  where cma_read.reader_sees(tenant_id);

-- Every column but raw: ids, codes, references and dates
create or replace view cma_read.device as
  select id, tenant_id, connection_id, source_system, source_id, serial, model_key, market, device_status_key, warehouse_ref,
         customer_ref, customer_ref_invalid, subscription_ref, order_ref, first_shipped_on, stock_received_on, last_shipped_on,
         warranty_until, end_of_life_on, external_refs, source_deleted_at, first_seen_at, synced_at
  from cma.device
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.device_component as
  select id, tenant_id, device_id, component_key, serial, expires_on, first_seen_at, replaced_at
  from cma.device_component
  where cma_read.reader_sees(tenant_id);

-- The due items of every tenant the reader sees (cma.maintenance_items_of as of each tenant's date): SECURITY DEFINER
-- in cma_read, owned by cma_owner, search path pinned, executable by readers only. Ids, codes and dates only
create or replace function cma_read.maintenance_due_rows()
returns table (tenant_id uuid, device_id uuid, connection_id uuid, source_id text, serial text, model_key text, market text,
               device_status_key text, is_in_field boolean, is_in_stock boolean, component_key text, due_on date, basis text,
               action_on date, action_month date, past_due boolean, exchange_key text, exchange_on date)
language sql stable security definer
set search_path = pg_catalog, cma, pg_temp
as $$
  select t.id, i.device_id, i.connection_id, i.source_id, i.serial, i.model_key, i.market, i.device_status_key, i.is_in_field,
         i.is_in_stock, i.component_key, i.due_on, i.basis, i.action_on, date_trunc('month', i.action_on)::date, i.past_due,
         i.exchange_key, i.exchange_on
  from cma.tenant t
  cross join lateral cma.maintenance_items_of(t.id, cma.tenant_today_of(t.id)) i
  where cma_read.reader_sees(t.id)
$$;
revoke execute on function cma_read.maintenance_due_rows() from public;
grant execute on function cma_read.maintenance_due_rows() to cma_readonly;

create or replace view cma_read.maintenance_due as
  select * from cma_read.maintenance_due_rows();

-- Per action month, market and model (unknown for none): the due items, the components' items, the devices at end of
-- life, the planned exchanges whose first action date falls in the month (always the month of one of its items), and
-- whether the month lies before the tenant's current one (past due). Items of basis unknown have no month and are left out
create or replace view cma_read.maintenance_per_month as
  with i as (
    select r.tenant_id, r.action_month, coalesce(r.market, 'unknown') as market, coalesce(r.model_key, 'unknown') as model_key,
           r.component_key, r.past_due, r.exchange_key, date_trunc('month', r.exchange_on)::date as exchange_month
    from cma_read.maintenance_due_rows() r
    where r.action_on is not null
  ), items as (
    select tenant_id, action_month as month, market, model_key, count(*)::integer as items,
           count(*) filter (where component_key <> 'device')::integer as component_items,
           count(*) filter (where component_key = 'device')::integer as end_of_life, bool_or(past_due) as past_due
    from i group by 1, 2, 3, 4
  ), ex as (
    select tenant_id, exchange_month as month, market, model_key, count(distinct exchange_key)::integer as exchanges
    from i group by 1, 2, 3, 4
  )
  select a.tenant_id, a.month, a.market, a.model_key, a.items, a.component_items, a.end_of_life, coalesce(e.exchanges, 0) as exchanges, a.past_due
  from items a
  left join ex e on e.tenant_id = a.tenant_id and e.month = a.month and e.market = a.market and e.model_key = a.model_key;

-- The eight data-quality checks' views, as 0007d's dq_ views (ids and codes only)
create or replace view cma_read.dq_device_serial_missing as
  select tenant_id, connection_id, object_type, object_id, value
  from cma_read.data_quality_rows() where check_key = 'device_serial_missing';

create or replace view cma_read.dq_device_serial_duplicate as
  select tenant_id, connection_id, object_type, object_id, value
  from cma_read.data_quality_rows() where check_key = 'device_serial_duplicate';

create or replace view cma_read.dq_device_model_unmapped as
  select tenant_id, connection_id, object_type, object_id, value
  from cma_read.data_quality_rows() where check_key = 'device_model_unmapped';

create or replace view cma_read.dq_device_status_unmapped as
  select tenant_id, connection_id, object_type, object_id, value
  from cma_read.data_quality_rows() where check_key = 'device_status_unmapped';

create or replace view cma_read.dq_device_market_unmapped as
  select tenant_id, connection_id, object_type, object_id, value
  from cma_read.data_quality_rows() where check_key = 'device_market_unmapped';

create or replace view cma_read.dq_device_customer_ref_invalid as
  select tenant_id, connection_id, object_type, object_id, value
  from cma_read.data_quality_rows() where check_key = 'device_customer_ref_invalid';

create or replace view cma_read.dq_component_due_unknown as
  select tenant_id, connection_id, object_type, object_id, value
  from cma_read.data_quality_rows() where check_key = 'component_due_unknown';

create or replace view cma_read.dq_field_device_without_subscription_ref as
  select tenant_id, connection_id, object_type, object_id, value
  from cma_read.data_quality_rows() where check_key = 'field_device_without_subscription_ref';

-- ---------------------------------------------------------------------------------------------
-- 14. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008zi', 'Asset register: the connection kind assets; the catalogs cma.device_model, cma.device_component_kind, cma.maintenance_rule and cma.device_status (flags is_in_field, is_in_stock, is_tracked; the source''s labels as aliases); the setting assets.bundle_window_days; cma.device (record id, serial, model, market, status, references, dates, named ids, raw held to a key allow-list, missing from a full snapshot) and cma.device_component (serial and recorded expiry, one current per kind, an observed replacement on a serial change); the import cma.device_import_staging (the COPY target, a view over cma.device_import_row) and cma.load_device_snapshot (tenant.configure); the forecast cma.maintenance_items_of and cma.maintenance_due_of (due date recorded, by rule or unknown, action date, past due, planned exchanges within the bundling window); Reports, Maintenance (cma.maintenance_page, cma.maintenance_rows); eight data-quality checks; the reader views; sync_run job assets_import')
on conflict (version) do nothing;

commit;
reset role;
