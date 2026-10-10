-- =============================================================================================
-- 32_intake_core.sql: migration 0007, intake core (intake track I1)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 30_ingest_crm_records.sql (0006). Rerunnable, forward-only. Run as your own IAM login, dev
-- first, then prod; then 33_verify_intake_core.sql, then 31_verify_ingest_crm_records.sql again
-- (unchanged: every 0006 call shape keeps working).
--
-- Specification: docs/night-2026-10-10/DESIGN.md §3 and §4.1 (README Roadmap step 6, intake track;
-- Decision log 10 October 2026).
--
-- What it adds
--   settings           intake.start_date, speed_to_lead.pre_window_minutes, speed_to_lead.target_minutes,
--                      lead_to_order.max_days, forms.deal_window_hours, commerce.renewal_source_names,
--                      commerce.renewal_app_ids, alerts.max_age_minutes; the setting catalog learns the
--                      value type 'date'
--   markets            cma.market (ISO country code, name, IANA zone, language, language skill and
--                      minimum level, currency), cma.market_alias (how sources write a market),
--                      cma.normalize_market()
--   business time      cma.business_hours and cma.business_holiday per market ('*' = default),
--                      cma.business_seconds() and cma.next_business_noon()
--   0006, extended     integration_connection.settings (non-secret, flat), connection_field with more
--                      fields and a slot, crm_contact_ref with a slot, crm_contact currency and store,
--                      crm_record amount, currency, source channel and category,
--                      connection_pipeline.is_lead; the two upserts take the new keys and normalise
--                      the market
--   CRM calls          cma.crm_call (call engagements on the CRM: time, direction, outcome, duration,
--                      owner, the app that logged it, a keyed hash of the other party's number),
--                      cma.connection_call_outcome (which outcome counts as connected)
--   associations       cma.crm_association: call or record to contact, call to record, with removal
--   forms              cma.connection_form (counted, lead source, market, the non-personal fields
--                      that may be kept), cma.form_submission (ids, form, time, page, UTM, the
--                      contact id; field values only for kept fields)
--   sync audit         cma.sync_cursor (where a poll or backfill stands), cma.sync_run (every job
--                      run, finished once)
--   privacy deletion   cma.ingest_contact_forget()
--   people's ids       cma.set_user_external_id() and cma.remove_user_external_id() for the CRM owner
--                      and telephony user ids (vocabulary <system>_owner or <system>_user, data)
--
-- Nothing personal is stored (DESIGN §2.1): no names, email addresses, phone numbers, addresses or
-- free text. A phone number exists here only as a keyed hash (counterpart_hash), made by the ingest
-- service; reporting views never show it.
--
-- SQLSTATEs as before: CMA01 no acting user, CMA02 not found, CMA03 conflict, CMA04 invalid,
-- CMA06 not permitted.
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
set role cma_owner;

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0006') then
    raise exception 'migration 0006 (30_ingest_crm_records.sql) must run before 0007';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Settings: the value type 'date' and the intake settings
-- ---------------------------------------------------------------------------------------------
alter table cma.setting drop constraint if exists setting_value_type_check;
alter table cma.setting add constraint setting_value_type_check
  check (value_type in ('text', 'boolean', 'integer', 'date'));
alter table cma.setting drop constraint if exists setting_date_default_check;
alter table cma.setting add constraint setting_date_default_check
  check (value_type <> 'date' or default_value ~ '^\d{4}-\d{2}-\d{2}$');

-- As 0003b, plus a date as YYYY-MM-DD that Postgres reads as a date
create or replace function cma.check_tenant_setting()
returns trigger
language plpgsql
as $$
declare
  s cma.setting;
begin
  select * into s from cma.setting where key = new.key;
  if not found then
    raise exception 'Unknown setting %', new.key using errcode = 'CMA02';
  end if;
  if s.value_type = 'boolean' and new.value not in ('true', 'false') then
    raise exception 'Setting % takes true or false', new.key using errcode = 'CMA04';
  end if;
  if s.value_type = 'integer' and new.value !~ '^-?[0-9]+$' then
    raise exception 'Setting % takes a whole number', new.key using errcode = 'CMA04';
  end if;
  if s.value_type = 'date' then
    if new.value !~ '^\d{4}-\d{2}-\d{2}$' then
      raise exception 'Setting % takes a date as YYYY-MM-DD', new.key using errcode = 'CMA04';
    end if;
    begin
      perform new.value::date;
    exception when others then
      raise exception 'Setting % takes a date as YYYY-MM-DD', new.key using errcode = 'CMA04';
    end;
  end if;
  if s.allowed_values is not null and not (new.value = any (s.allowed_values)) then
    raise exception 'Setting % takes one of: %', new.key, array_to_string(s.allowed_values, ', ')
      using errcode = 'CMA04';
  end if;
  new.updated_by := cma.current_user_id();
  return new;
end
$$;
revoke execute on function cma.check_tenant_setting() from public;

insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('intake.start_date',                  'date',    null, '2026-10-01',
     'First business date of intake reporting and of backfills (the insights start)'),
  ('speed_to_lead.pre_window_minutes',   'integer', null, '0',
     'Minutes before a deal''s creation in which a call still counts as its first call'),
  ('speed_to_lead.target_minutes',       'integer', null, '60',
     'Speed-to-lead target in business minutes'),
  ('lead_to_order.max_days',             'integer', null, '90',
     'Days after a deal''s creation within which an order counts as its order'),
  ('forms.deal_window_hours',            'integer', null, '72',
     'Hours after a form submission within which a deal of the same contact counts as coming from it'),
  ('commerce.renewal_source_names',      'text',    null, '',
     'Comma-separated order source names that mark a renewal order (empty: none)'),
  ('commerce.renewal_app_ids',           'text',    null, '',
     'Comma-separated app ids that mark a renewal order (empty: none)'),
  ('alerts.max_age_minutes',             'integer', null, '60',
     'A record older than this at ingest never raises an alert')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- ---------------------------------------------------------------------------------------------
-- 2. Markets, aliases, business hours and holidays
-- ---------------------------------------------------------------------------------------------
-- A market is a country the tenant serves, with its zone, language and currency. The code is
-- ISO 3166-1 alpha-2 in upper case: GB, never UK (aliases absorb sources that write UK).
create table if not exists cma.market (
  id                  uuid primary key default uuidv7(),
  tenant_id           uuid not null default cma.current_tenant_id() references cma.tenant (id),
  code                text not null check (code ~ '^[A-Z]{2}$' and code <> 'UK'),
  name                text not null check (length(btrim(name)) between 1 and 80),
  time_zone           text not null check (length(time_zone) between 1 and 64),
  language_code       text not null check (language_code ~ '^[a-z]{2}$'),
  language_skill_key  text check (language_skill_key ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  min_language_level  smallint check (min_language_level between 1 and 9),
  currency            text not null check (currency ~ '^[A-Z]{3}$'),
  status              text not null default 'active' check (status in ('active', 'inactive')),
  sort_order          integer not null default 100,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, code),
  check (min_language_level is null or language_skill_key is not null)
);
comment on table cma.market is 'Markets (countries) a tenant serves: ISO code (GB, not UK), zone, language with its skill and minimum level, currency. Tenant configuration';
create or replace trigger set_updated_at before update on cma.market
  for each row execute function cma.set_updated_at();

create table if not exists cma.market_alias (
  tenant_id   uuid not null default cma.current_tenant_id() references cma.tenant (id),
  alias       text not null check (alias = lower(btrim(alias)) and length(alias) between 1 and 100),
  code        text not null,
  updated_at  timestamptz not null default now(),
  primary key (tenant_id, alias),
  foreign key (tenant_id, code) references cma.market (tenant_id, code)
);
comment on table cma.market_alias is 'How sources write a market (uk, United Kingdom, nederland), lower-cased, mapped to its code';
create or replace trigger set_updated_at before update on cma.market_alias
  for each row execute function cma.set_updated_at();

-- Office hours per market and weekday (1 = Monday ... 7 = Sunday). '*' is the tenant default; a
-- market with any rows of its own uses only its own (a weekday without rows is then closed).
create table if not exists cma.business_hours (
  tenant_id   uuid not null default cma.current_tenant_id() references cma.tenant (id),
  market      text not null check (market = '*' or market ~ '^[A-Z]{2}$'),
  weekday     smallint not null check (weekday between 1 and 7),
  opens_at    time not null,
  closes_at   time not null,
  updated_at  timestamptz not null default now(),
  primary key (tenant_id, market, weekday, opens_at),
  check (closes_at > opens_at)
);
comment on table cma.business_hours is 'Office hours per market and weekday in the market''s local time; * is the default for markets without hours of their own';

-- Ranges of one day never overlap, whoever writes
create or replace function cma.check_business_hours()
returns trigger
language plpgsql
as $$
begin
  if exists (select 1 from cma.business_hours h
             where h.tenant_id = new.tenant_id and h.market = new.market and h.weekday = new.weekday
               and h.opens_at <> new.opens_at
               and h.opens_at < new.closes_at and new.opens_at < h.closes_at) then
    raise exception 'office hours % to % overlap another range of weekday % in %',
      new.opens_at, new.closes_at, new.weekday, new.market using errcode = 'CMA04';
  end if;
  return new;
end
$$;
revoke execute on function cma.check_business_hours() from public;
create or replace trigger check_overlap before insert or update on cma.business_hours
  for each row execute function cma.check_business_hours();

create table if not exists cma.business_holiday (
  tenant_id   uuid not null default cma.current_tenant_id() references cma.tenant (id),
  market      text not null check (market = '*' or market ~ '^[A-Z]{2}$'),
  day         date not null,
  name        text not null check (length(btrim(name)) between 1 and 100),
  updated_at  timestamptz not null default now(),
  primary key (tenant_id, market, day)
);
comment on table cma.business_holiday is 'Days without office hours per market; * holidays apply to every market';
create or replace trigger set_updated_at before update on cma.business_holiday
  for each row execute function cma.set_updated_at();

-- ---------------------------------------------------------------------------------------------
-- 3. Changes to 0006 objects (additive; every 0006 call keeps working)
-- ---------------------------------------------------------------------------------------------
-- Per-connection settings the adapters need that are not secret (a link host, an API version, a
-- client id, a store handle, the CRM connection a store's customers are matched to). Flat: values
-- are text, numbers or booleans; a key that looks like a secret is refused.
create or replace function cma.connection_settings_ok(p_settings jsonb)
returns boolean
language sql immutable
as $$
  select p_settings is not null
     and jsonb_typeof(p_settings) = 'object'
     and length(p_settings::text) <= 4096
     and not exists (select 1 from jsonb_each(p_settings) e
                     where e.key !~ '^[a-z][a-z0-9_]{0,59}$'
                        or e.key ~* '(secret|token|password|key)'
                        or jsonb_typeof(e.value) not in ('string', 'number', 'boolean'))
$$;
revoke execute on function cma.connection_settings_ok(jsonb) from public;

alter table cma.integration_connection add column if not exists settings jsonb not null default '{}'::jsonb;
alter table cma.integration_connection drop constraint if exists integration_connection_settings_check;
alter table cma.integration_connection add constraint integration_connection_settings_check
  check (cma.connection_settings_ok(settings));
comment on column cma.integration_connection.settings is 'Non-secret per-connection settings, flat; keys containing secret, token, password or key are refused';

-- connection_field: more canonical fields, and a slot for refs (a contact can hold two ids of one
-- system, for example two commerce customer ids)
alter table cma.connection_field add column if not exists slot smallint not null default 1;
alter table cma.connection_field drop constraint if exists connection_field_field_check;
alter table cma.connection_field add constraint connection_field_field_check
  check (field in ('market', 'language', 'country', 'currency', 'store', 'amount', 'source_channel', 'category', 'ref'));
alter table cma.connection_field drop constraint if exists connection_field_check1;
alter table cma.connection_field drop constraint if exists connection_field_entity_field_check;
alter table cma.connection_field add constraint connection_field_entity_field_check
  check (case when entity = 'contact' then field in ('country', 'language', 'currency', 'store', 'ref')
              else field in ('market', 'language', 'currency', 'amount', 'source_channel', 'category') end);
alter table cma.connection_field drop constraint if exists connection_field_slot_check;
alter table cma.connection_field add constraint connection_field_slot_check
  check (slot between 1 and 9 and (slot = 1 or field = 'ref'));
do $$
begin
  if pg_get_constraintdef((select oid from pg_constraint where conrelid = 'cma.connection_field'::regclass and conname = 'connection_field_pkey'))
     not like '%slot%' then
    alter table cma.connection_field drop constraint connection_field_pkey;
    alter table cma.connection_field add constraint connection_field_pkey
      primary key (tenant_id, connection_id, entity, field, ref_system, slot);
  end if;
end
$$;

-- crm_contact_ref: the slot joins the key
alter table cma.crm_contact_ref add column if not exists slot smallint not null default 1;
alter table cma.crm_contact_ref drop constraint if exists crm_contact_ref_slot_check;
alter table cma.crm_contact_ref add constraint crm_contact_ref_slot_check check (slot between 1 and 9);
do $$
begin
  if pg_get_constraintdef((select oid from pg_constraint where conrelid = 'cma.crm_contact_ref'::regclass and conname = 'crm_contact_ref_pkey'))
     not like '%slot%' then
    alter table cma.crm_contact_ref drop constraint crm_contact_ref_pkey;
    alter table cma.crm_contact_ref add constraint crm_contact_ref_pkey primary key (tenant_id, contact_id, system, slot);
  end if;
end
$$;

alter table cma.crm_contact add column if not exists currency text;
alter table cma.crm_contact add column if not exists store text;
alter table cma.crm_contact drop constraint if exists crm_contact_currency_check;
alter table cma.crm_contact add constraint crm_contact_currency_check check (currency ~ '^[A-Z]{3}$');
alter table cma.crm_contact drop constraint if exists crm_contact_store_check;
alter table cma.crm_contact add constraint crm_contact_store_check check (store ~ '^[a-z0-9-]{1,60}$');

alter table cma.crm_record add column if not exists amount numeric(14,2);
alter table cma.crm_record add column if not exists currency text;
alter table cma.crm_record add column if not exists source_channel text;
alter table cma.crm_record add column if not exists category text;
alter table cma.crm_record drop constraint if exists crm_record_currency_check;
alter table cma.crm_record add constraint crm_record_currency_check check (currency ~ '^[A-Z]{3}$');
alter table cma.crm_record drop constraint if exists crm_record_source_channel_check;
alter table cma.crm_record add constraint crm_record_source_channel_check check (length(source_channel) <= 100);
alter table cma.crm_record drop constraint if exists crm_record_category_check;
alter table cma.crm_record add constraint crm_record_category_check check (length(category) <= 100);

alter table cma.connection_pipeline add column if not exists is_lead boolean not null default true;
comment on column cma.connection_pipeline.is_lead is 'Records of this pipeline count for speed to lead';

-- ---------------------------------------------------------------------------------------------
-- 4. CRM calls, call outcomes and associations
-- ---------------------------------------------------------------------------------------------
-- Call engagements on the CRM, logged there by the telephony integration or by hand. The other
-- party's number is never stored; counterpart_hash is HMAC-SHA256(pepper, E.164) in hex, made by
-- the ingest service, and only links a CRM call to a telephony call (0007a).
create table if not exists cma.crm_call (
  id                  uuid primary key default uuidv7(),
  tenant_id           uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id       uuid not null,
  source_system       text not null check (source_system ~ '^[a-z0-9_]+$'),
  source_id           text not null check (length(source_id) between 1 and 100),
  occurred_at         timestamptz,
  direction           text not null default 'unknown' check (direction in ('inbound', 'outbound', 'unknown')),
  status              text check (length(status) <= 40),
  outcome_ref         text check (length(outcome_ref) <= 100),
  duration_seconds    integer check (duration_seconds >= 0),
  owner_ref           text check (length(owner_ref) <= 100),
  source_app          text check (length(source_app) <= 60),
  counterpart_hash    text check (counterpart_hash ~ '^[0-9a-f]{64}$'),
  source_created_at   timestamptz,
  source_updated_at   timestamptz,
  source_deleted_at   timestamptz,
  synced_at           timestamptz not null default now(),
  raw                 jsonb not null default '{}'::jsonb,
  unique (tenant_id, id),
  unique (tenant_id, connection_id, source_id),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.crm_call is 'Call engagements held by the CRM: time, direction, outcome, duration, owner, the logging app; the other party only as a keyed hash. Owned by the CRM';
create index if not exists crm_call_occurred_idx on cma.crm_call (tenant_id, occurred_at);
create index if not exists crm_call_hash_idx on cma.crm_call (tenant_id, counterpart_hash) where counterpart_hash is not null;

create table if not exists cma.connection_call_outcome (
  tenant_id      uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id  uuid not null,
  outcome_ref    text not null check (length(outcome_ref) between 1 and 100),
  label          text not null check (length(label) between 1 and 100),
  is_connected   boolean not null default false,
  status         text not null default 'active' check (status in ('active', 'archived')),
  refreshed_at   timestamptz,
  updated_at     timestamptz not null default now(),
  primary key (tenant_id, connection_id, outcome_ref),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.connection_call_outcome is 'Call outcomes of the source per connection; is_connected (configuration) says which count as a conversation';
create or replace trigger set_updated_at before update on cma.connection_call_outcome
  for each row execute function cma.set_updated_at();

-- Associations as the source reports them, in one stored direction: an activity or a record points
-- to a contact, an activity points to a record. A removal keeps the row (removed_at); a re-add
-- clears it. source_changed_at guards against an older change arriving after a newer one.
create table if not exists cma.crm_association (
  tenant_id          uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id      uuid not null,
  from_type          text not null check (from_type ~ '^[a-z][a-z0-9_]*$'),
  from_id            text not null check (length(from_id) between 1 and 100),
  to_type            text not null check (to_type ~ '^[a-z][a-z0-9_]*$'),
  to_id              text not null check (length(to_id) between 1 and 100),
  first_seen_at      timestamptz not null default now(),
  removed_at         timestamptz,
  source_changed_at  timestamptz not null,
  primary key (tenant_id, connection_id, from_type, from_id, to_type, to_id),
  check (from_type <> 'contact' and to_type <> 'crm_call' and from_type <> to_type
         and (to_type = 'contact' or from_type = 'crm_call')),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.crm_association is 'Associations between CRM objects, stored as activity or record to contact and activity to record; removed_at while removed';
create index if not exists crm_association_to_idx on cma.crm_association (tenant_id, connection_id, to_type, to_id);

-- ---------------------------------------------------------------------------------------------
-- 5. Forms and submissions
-- ---------------------------------------------------------------------------------------------
create table if not exists cma.connection_form (
  tenant_id       uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id   uuid not null,
  source_form_id  text not null check (length(source_form_id) between 1 and 100),
  name            text not null check (length(name) between 1 and 200),
  is_counted      boolean not null default true,
  lead_source     text check (length(btrim(lead_source)) between 1 and 60),
  market          text check (market ~ '^[A-Z]{2}$'),
  kept_fields     text[] not null default '{}' check (cardinality(kept_fields) <= 30),
  status          text not null default 'active' check (status in ('active', 'archived')),
  refreshed_at    timestamptz,
  updated_at      timestamptz not null default now(),
  primary key (tenant_id, connection_id, source_form_id),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.connection_form is 'Forms of the source per connection: counted, lead source, market and the non-personal fields whose values may be kept (configuration); name and status from the source';
comment on column cma.connection_form.kept_fields is 'Names of form fields whose values are not personal (for example a product interest); only these are stored on a submission';
create or replace trigger set_updated_at before update on cma.connection_form
  for each row execute function cma.set_updated_at();

create table if not exists cma.form_submission (
  id                  uuid primary key default uuidv7(),
  tenant_id           uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id       uuid not null,
  source_id           text not null check (length(source_id) between 1 and 100),
  source_form_id      text not null,
  submitted_at        timestamptz not null,
  page_host           text check (page_host ~ '^[a-z0-9.-]{1,255}$'),
  page_path           text check (length(page_path) <= 1000 and page_path !~ '[?#]'),
  utm                 jsonb not null default '{}'::jsonb check (jsonb_typeof(utm) = 'object'),
  contact_source_id   text check (length(contact_source_id) between 1 and 100),
  contact_resolution  text not null default 'pending'
                        check (contact_resolution in ('resolved', 'no_email', 'not_found', 'ambiguous', 'pending')),
  kept_values         jsonb not null default '{}'::jsonb check (jsonb_typeof(kept_values) = 'object'),
  synced_at           timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, connection_id, source_id),
  check ((contact_resolution = 'resolved') = (contact_source_id is not null)),
  foreign key (tenant_id, connection_id, source_form_id)
    references cma.connection_form (tenant_id, connection_id, source_form_id)
);
comment on table cma.form_submission is 'Form submissions: ids, form, time, page without query string, UTM tags, the resolved contact id; field values only for the form''s kept fields. Insert-only apart from the contact resolution';
create index if not exists form_submission_submitted_idx on cma.form_submission (tenant_id, submitted_at);
create index if not exists form_submission_contact_idx on cma.form_submission (tenant_id, connection_id, contact_source_id);

-- ---------------------------------------------------------------------------------------------
-- 6. Sync audit: cursors and runs
-- ---------------------------------------------------------------------------------------------
create table if not exists cma.sync_cursor (
  tenant_id      uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id  uuid not null,
  stream         text not null check (stream ~ '^[A-Za-z0-9_:.-]{1,100}$'),
  cursor         jsonb not null check (length(cursor::text) <= 2048),
  updated_at     timestamptz not null default now(),
  primary key (tenant_id, connection_id, stream),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.sync_cursor is 'Where a poll or backfill stream of a connection stands (opaque to the database)';
create or replace trigger set_updated_at before update on cma.sync_cursor
  for each row execute function cma.set_updated_at();

create table if not exists cma.sync_run (
  id             uuid primary key default uuidv7(),
  tenant_id      uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id  uuid not null,
  job            text not null check (job in ('backfill', 'reconcile', 'forms_poll', 'subscriptions_check', 'link_calls')),
  stream         text check (stream ~ '^[A-Za-z0-9_:.-]{1,100}$'),
  from_at        timestamptz,
  to_at          timestamptz,
  started_at     timestamptz not null default now(),
  started_by     uuid default cma.current_user_id(),
  finished_at    timestamptz,
  status         text not null default 'running' check (status in ('running', 'succeeded', 'failed')),
  counts         jsonb not null default '{}'::jsonb check (jsonb_typeof(counts) = 'object'),
  error          text check (length(error) <= 200),
  unique (tenant_id, id),
  check ((status = 'running') = (finished_at is null)),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id),
  foreign key (tenant_id, started_by) references cma.app_user (tenant_id, id)
);
comment on table cma.sync_run is 'Every backfill, reconcile, poll, subscription check or link run of a connection: range, counts, outcome. Append-only; a run finishes once';
create index if not exists sync_run_started_idx on cma.sync_run (tenant_id, connection_id, started_at);

-- A run changes only from running to finished, once, and only its outcome columns
create or replace function cma.check_sync_run()
returns trigger
language plpgsql
as $$
begin
  if old.status <> 'running' then
    raise exception 'sync run % is already finished', old.id using errcode = 'CMA03';
  end if;
  if (new.tenant_id, new.connection_id, new.job, new.stream, new.from_at, new.to_at, new.started_at, new.started_by)
     is distinct from (old.tenant_id, old.connection_id, old.job, old.stream, old.from_at, old.to_at, old.started_at, old.started_by) then
    raise exception 'only the outcome of a sync run changes' using errcode = 'CMA04';
  end if;
  return new;
end
$$;
revoke execute on function cma.check_sync_run() from public;
create or replace trigger check_finish_once before update on cma.sync_run
  for each row execute function cma.check_sync_run();

-- ---------------------------------------------------------------------------------------------
-- 7. Row-level security, audit and privileges
-- ---------------------------------------------------------------------------------------------
select cma.setup_tenant_table('cma.market');
select cma.setup_tenant_table('cma.market_alias');
select cma.setup_tenant_table('cma.business_hours');
select cma.setup_tenant_table('cma.business_holiday');
select cma.setup_tenant_table('cma.crm_call');
select cma.setup_tenant_table('cma.connection_call_outcome');
select cma.setup_tenant_table('cma.crm_association');
select cma.setup_tenant_table('cma.connection_form');
select cma.setup_tenant_table('cma.form_submission');
select cma.setup_tenant_table('cma.sync_cursor');
select cma.setup_tenant_table('cma.sync_run');

-- The application never deletes, except the mapping rows (aliases, office hours, holidays; contact
-- refs as in 0006). A submission changes only in its resolution and kept values (the privacy
-- deletion); a run only in its outcome.
revoke delete on cma.market, cma.crm_call, cma.connection_call_outcome, cma.crm_association,
                 cma.connection_form, cma.form_submission, cma.sync_cursor, cma.sync_run from cma_app;
revoke update on cma.form_submission from cma_app;
grant update (contact_source_id, contact_resolution, kept_values, synced_at) on cma.form_submission to cma_app;
revoke update on cma.sync_run from cma_app;
grant update (finished_at, status, counts, error) on cma.sync_run to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 8. Internal helpers
-- ---------------------------------------------------------------------------------------------
-- An amount from JSON: a number or a decimal string; anything else, or out of range, is null
create or replace function cma.json_amount(p_value jsonb)
returns numeric
language plpgsql immutable
as $$
declare
  v text;
begin
  if p_value is null or jsonb_typeof(p_value) not in ('number', 'string') then
    return null;
  end if;
  v := btrim(p_value #>> '{}');
  if v !~ '^-?\d{1,12}(\.\d+)?$' then
    return null;
  end if;
  return round(v::numeric, 2);
end
$$;
revoke execute on function cma.json_amount(jsonb) from public;

-- A currency code from JSON: three letters, upper-cased; anything else is null (the raw payload keeps
-- what the source wrote)
create or replace function cma.json_currency(p_value text)
returns text
language sql immutable
as $$
  select case when upper(btrim(p_value)) ~ '^[A-Z]{3}$' then upper(btrim(p_value)) end
$$;
revoke execute on function cma.json_currency(text) from public;

-- The market code a source value stands for: an alias, else a known code in upper case, else the
-- trimmed value as written (the data-quality view shows values that are not in the catalog)
create or replace function cma.normalize_market(p_value text)
returns text
language sql stable
as $$
  select case
           when nullif(btrim(p_value), '') is null then null
           else coalesce(
             (select a.code from cma.market_alias a
              where a.tenant_id = cma.current_tenant_id() and a.alias = lower(btrim(p_value))),
             (select m.code from cma.market m
              where m.tenant_id = cma.current_tenant_id() and m.code = upper(btrim(p_value))),
             btrim(p_value))
         end
$$;

-- The weekly schedule a market uses: its own rows when it has any, else the default '*'
create or replace function cma.business_schedule_of(p_market text)
returns text
language sql stable
as $$
  select case when exists (select 1 from cma.business_hours h
                           where h.tenant_id = cma.current_tenant_id() and h.market = p_market)
              then p_market else '*' end
$$;
revoke execute on function cma.business_schedule_of(text) from public;

-- Office seconds between two instants, in the market's zone: its own hours (else '*'), holidays of
-- the market and of '*' excluded. Each day's ranges are placed in the zone separately, so a range
-- across a daylight-saving change counts the real elapsed time. 0 when p_to <= p_from; null for a
-- market that is not in the catalog.
create or replace function cma.business_seconds(p_market text, p_from timestamptz, p_to timestamptz)
returns integer
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_zone   text;
  v_sched  text;
begin
  if p_market is null or p_from is null or p_to is null then
    return null;
  end if;
  select m.time_zone into v_zone from cma.market m where m.tenant_id = v_tenant and m.code = p_market;
  if v_zone is null then
    return null;
  end if;
  if p_to <= p_from then
    return 0;
  end if;
  v_sched := cma.business_schedule_of(p_market);
  return (
    select coalesce(sum(greatest(0, extract(epoch from least(w.closes, p_to) - greatest(w.opens, p_from)))), 0)::integer
    from (
      select (d.day + h.opens_at) at time zone v_zone as opens,
             (d.day + h.closes_at) at time zone v_zone as closes
      from generate_series((p_from at time zone v_zone)::date, (p_to at time zone v_zone)::date, interval '1 day') g(ts)
      cross join lateral (select g.ts::date as day) d
      join cma.business_hours h
        on h.tenant_id = v_tenant and h.market = v_sched and h.weekday = extract(isodow from d.day)
      where not exists (select 1 from cma.business_holiday b
                        where b.tenant_id = v_tenant and b.market in (p_market, '*') and b.day = d.day)
    ) w
  );
end
$$;

-- 12:00 local on the first working day (office hours, no holiday) after p_at's local date; null for
-- an unknown market or when no working day comes within 31 days
create or replace function cma.next_business_noon(p_market text, p_at timestamptz)
returns timestamptz
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_zone   text;
  v_sched  text;
  v_day    date;
begin
  if p_market is null or p_at is null then
    return null;
  end if;
  select m.time_zone into v_zone from cma.market m where m.tenant_id = v_tenant and m.code = p_market;
  if v_zone is null then
    return null;
  end if;
  v_sched := cma.business_schedule_of(p_market);
  for i in 1 .. 31 loop
    v_day := (p_at at time zone v_zone)::date + i;
    if exists (select 1 from cma.business_hours h
               where h.tenant_id = v_tenant and h.market = v_sched and h.weekday = extract(isodow from v_day))
       and not exists (select 1 from cma.business_holiday b
                       where b.tenant_id = v_tenant and b.market in (p_market, '*') and b.day = v_day) then
      return (v_day + time '12:00') at time zone v_zone;
    end if;
  end loop;
  return null;
end
$$;

-- The current tenant's connection, whatever its status (configuration may touch an inactive one)
create or replace function cma.assert_connection(p_connection_id uuid)
returns void
language plpgsql stable
as $$
begin
  if not exists (select 1 from cma.integration_connection c
                 where c.tenant_id = cma.current_tenant_id() and c.id = p_connection_id) then
    raise exception 'no connection % in the current tenant', p_connection_id using errcode = 'CMA02';
  end if;
end
$$;
revoke execute on function cma.assert_connection(uuid) from public;

-- A market code of the current tenant's catalog, or '*' when allowed; CMA02 otherwise
create or replace function cma.assert_market(p_market text, p_allow_default boolean)
returns void
language plpgsql stable
as $$
begin
  if p_allow_default and p_market = '*' then
    return;
  end if;
  if not exists (select 1 from cma.market m where m.tenant_id = cma.current_tenant_id() and m.code = p_market) then
    raise exception 'no market % in the current tenant%', p_market,
      case when p_allow_default then ' (use a market code or *)' else '' end using errcode = 'CMA02';
  end if;
end
$$;
revoke execute on function cma.assert_market(text, boolean) from public;

-- ---------------------------------------------------------------------------------------------
-- 9. Configuration (tenant.configure)
-- ---------------------------------------------------------------------------------------------
create or replace function cma.upsert_market(p_code text, p_name text, p_time_zone text, p_language_code text,
                                             p_currency text, p_language_skill_key text default null,
                                             p_min_language_level smallint default null, p_sort_order integer default 100)
returns void
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_permission('tenant.configure');
  if p_code = 'UK' then
    raise exception 'UK is not an ISO 3166-1 code: use GB (and an alias uk for sources that write UK)' using errcode = 'CMA04';
  end if;
  if coalesce(p_code, '') !~ '^[A-Z]{2}$' then
    raise exception 'a market code is two upper-case letters (ISO 3166-1 alpha-2), got %', p_code using errcode = 'CMA04';
  end if;
  if p_time_zone is null or not exists (select 1 from pg_timezone_names z where z.name = p_time_zone) then
    raise exception '% is not a time zone Postgres knows', p_time_zone using errcode = 'CMA04';
  end if;
  if coalesce(p_language_code, '') !~ '^[a-z]{2}$' then
    raise exception 'a language is two lower-case letters (ISO 639-1), got %', p_language_code using errcode = 'CMA04';
  end if;
  if coalesce(p_currency, '') !~ '^[A-Z]{3}$' then
    raise exception 'a currency is three upper-case letters (ISO 4217), got %', p_currency using errcode = 'CMA04';
  end if;
  if p_language_skill_key is not null
     and not exists (select 1 from cma.skill s where s.tenant_id = v_tenant and s.dimension = 'language'
                     and s.key = p_language_skill_key and s.status = 'active') then
    raise exception 'no active language skill %', p_language_skill_key using errcode = 'CMA02';
  end if;
  if p_min_language_level is not null and p_language_skill_key is null then
    raise exception 'a minimum language level needs a language skill' using errcode = 'CMA04';
  end if;
  if p_min_language_level is not null
     and exists (select 1 from cma.skill_level l where l.tenant_id = v_tenant and l.dimension = 'language')
     and not exists (select 1 from cma.skill_level l where l.tenant_id = v_tenant and l.dimension = 'language'
                     and l.level = p_min_language_level) then
    raise exception 'language level % is not on the tenant''s scale', p_min_language_level using errcode = 'CMA04';
  end if;
  insert into cma.market (tenant_id, code, name, time_zone, language_code, language_skill_key, min_language_level,
                          currency, sort_order)
  values (v_tenant, p_code, btrim(p_name), p_time_zone, p_language_code, p_language_skill_key, p_min_language_level,
          p_currency, coalesce(p_sort_order, 100))
  on conflict (tenant_id, code) do update
    set name = excluded.name, time_zone = excluded.time_zone, language_code = excluded.language_code,
        language_skill_key = excluded.language_skill_key, min_language_level = excluded.min_language_level,
        currency = excluded.currency, sort_order = excluded.sort_order;
exception when check_violation or not_null_violation then
  raise exception 'invalid market: %', sqlerrm using errcode = 'CMA04';
end
$$;

create or replace function cma.set_market_status(p_code text, p_status text)
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
  if p_status not in ('active', 'inactive') then
    raise exception 'status must be active or inactive' using errcode = 'CMA04';
  end if;
  update cma.market m set status = p_status where m.tenant_id = cma.current_tenant_id() and m.code = p_code;
  if not found then
    raise exception 'no market % in the current tenant', p_code using errcode = 'CMA02';
  end if;
end
$$;

create or replace function cma.set_market_alias(p_alias text, p_code text)
returns void
language plpgsql
as $$
declare
  v_alias text := lower(btrim(coalesce(p_alias, '')));
begin
  perform cma.assert_permission('tenant.configure');
  if length(v_alias) not between 1 and 100 then
    raise exception 'an alias is 1 to 100 characters' using errcode = 'CMA04';
  end if;
  perform cma.assert_market(p_code, false);
  insert into cma.market_alias (tenant_id, alias, code)
  values (cma.current_tenant_id(), v_alias, p_code)
  on conflict (tenant_id, alias) do update set code = excluded.code
  where cma.market_alias.code is distinct from excluded.code;
end
$$;

create or replace function cma.remove_market_alias(p_alias text)
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
  delete from cma.market_alias a
  where a.tenant_id = cma.current_tenant_id() and a.alias = lower(btrim(coalesce(p_alias, '')));
  if not found then
    raise exception 'no alias % in the current tenant', p_alias using errcode = 'CMA02';
  end if;
end
$$;

-- Replaces one weekday's ranges of a market ('*' = default) from '09:00-12:30,13:00-17:00';
-- '' closes the day. 24:00 is allowed as a closing time.
create or replace function cma.set_business_hours(p_market text, p_weekday smallint, p_hours text)
returns void
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_range  text;
  v_open   time;
  v_close  time;
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_market(p_market, true);
  if p_weekday is null or p_weekday not between 1 and 7 then
    raise exception 'weekday is 1 (Monday) to 7 (Sunday)' using errcode = 'CMA04';
  end if;
  if p_hours is null then
    raise exception 'hours are ranges like 09:00-17:00, or empty for closed' using errcode = 'CMA04';
  end if;
  delete from cma.business_hours h where h.tenant_id = v_tenant and h.market = p_market and h.weekday = p_weekday;
  foreach v_range in array coalesce(nullif(regexp_split_to_array(regexp_replace(p_hours, '\s', '', 'g'), ','), '{""}'), '{}') loop
    if v_range !~ '^([01]\d|2[0-3]):[0-5]\d-(([01]\d|2[0-3]):[0-5]\d|24:00)$' then
      raise exception 'office hours % are not a range like 09:00-17:00', v_range using errcode = 'CMA04';
    end if;
    v_open := split_part(v_range, '-', 1)::time;
    v_close := split_part(v_range, '-', 2)::time;
    if v_close <= v_open then
      raise exception 'office hours % close before they open', v_range using errcode = 'CMA04';
    end if;
    insert into cma.business_hours (tenant_id, market, weekday, opens_at, closes_at)
    values (v_tenant, p_market, p_weekday, v_open, v_close);
  end loop;
exception when unique_violation then
  raise exception 'office hours % open twice at the same time', p_hours using errcode = 'CMA04';
end
$$;

create or replace function cma.set_business_holiday(p_market text, p_day date, p_name text)
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_market(p_market, true);
  if p_day is null or coalesce(length(btrim(p_name)), 0) not between 1 and 100 then
    raise exception 'a holiday needs a day and a name of 1 to 100 characters' using errcode = 'CMA04';
  end if;
  insert into cma.business_holiday (tenant_id, market, day, name)
  values (cma.current_tenant_id(), p_market, p_day, btrim(p_name))
  on conflict (tenant_id, market, day) do update set name = excluded.name;
end
$$;

create or replace function cma.remove_business_holiday(p_market text, p_day date)
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
  delete from cma.business_holiday b
  where b.tenant_id = cma.current_tenant_id() and b.market = p_market and b.day = p_day;
  if not found then
    raise exception 'no holiday % in %', p_day, p_market using errcode = 'CMA02';
  end if;
end
$$;

create or replace function cma.set_connection_settings(p_connection_id uuid, p_settings jsonb)
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  if not cma.connection_settings_ok(coalesce(p_settings, '{}'::jsonb)) then
    raise exception 'settings must be a flat object of at most 4 kB, keys lower case, no key containing secret, token, password or key'
      using errcode = 'CMA04';
  end if;
  update cma.integration_connection c set settings = coalesce(p_settings, '{}'::jsonb)
  where c.tenant_id = cma.current_tenant_id() and c.id = p_connection_id;
end
$$;

-- Sets the source property behind one canonical field and slot; an empty property removes the
-- mapping. Slot > 1 only for refs.
create or replace function cma.set_connection_field(p_connection_id uuid, p_entity text, p_field text,
                                                    p_ref_system text, p_source_property text, p_slot smallint)
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  if coalesce(btrim(p_source_property), '') = '' then
    delete from cma.connection_field f
    where f.tenant_id = cma.current_tenant_id() and f.connection_id = p_connection_id
      and f.entity = p_entity and f.field = p_field and f.ref_system = coalesce(p_ref_system, '')
      and f.slot = coalesce(p_slot, 1);
    return;
  end if;
  insert into cma.connection_field (tenant_id, connection_id, entity, field, ref_system, slot, source_property)
  values (cma.current_tenant_id(), p_connection_id, p_entity, p_field, coalesce(p_ref_system, ''), coalesce(p_slot, 1),
          btrim(p_source_property))
  on conflict (tenant_id, connection_id, entity, field, ref_system, slot)
    do update set source_property = excluded.source_property;
exception when check_violation or not_null_violation then
  raise exception 'invalid field mapping (%, %, %, slot %): %', p_entity, p_field, p_ref_system, p_slot, sqlerrm using errcode = 'CMA04';
end
$$;

-- The 0006 call shape: slot 1
create or replace function cma.set_connection_field(p_connection_id uuid, p_entity text, p_field text,
                                                    p_ref_system text, p_source_property text)
returns void
language sql
as $$
  select cma.set_connection_field(p_connection_id, p_entity, p_field, p_ref_system, p_source_property, 1::smallint)
$$;

-- Whether a pipeline counts for speed to lead. A pipeline not yet refreshed from the source is
-- added with its id as label.
create or replace function cma.set_pipeline_lead(p_connection_id uuid, p_record_type text, p_pipeline_id text, p_is_lead boolean)
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  if p_is_lead is null then
    raise exception 'is_lead must be true or false' using errcode = 'CMA04';
  end if;
  insert into cma.connection_pipeline (tenant_id, connection_id, record_type, source_pipeline_id, label, is_lead)
  values (cma.current_tenant_id(), p_connection_id, p_record_type, p_pipeline_id, p_pipeline_id, p_is_lead)
  on conflict (tenant_id, connection_id, record_type, source_pipeline_id) do update set is_lead = excluded.is_lead;
exception when check_violation or not_null_violation then
  raise exception 'invalid pipeline: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- A form's configuration: counted, lead source label, market and the non-personal fields kept. A
-- form not yet read from the source is added with its id as name.
create or replace function cma.set_form(p_connection_id uuid, p_form_id text, p_is_counted boolean, p_lead_source text,
                                        p_market text, p_kept_fields text[])
returns void
language plpgsql
as $$
declare
  v_fields text[];
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  if p_is_counted is null then
    raise exception 'is_counted must be true or false' using errcode = 'CMA04';
  end if;
  if p_market is not null then
    perform cma.assert_market(p_market, false);
  end if;
  select coalesce(array_agg(distinct btrim(f) order by btrim(f)), '{}') into v_fields
  from unnest(coalesce(p_kept_fields, '{}')) f;
  if exists (select 1 from unnest(v_fields) f where f !~ '^[A-Za-z0-9_.-]{1,100}$') or cardinality(v_fields) > 30 then
    raise exception 'kept fields are at most 30 field names of letters, digits, _ . -' using errcode = 'CMA04';
  end if;
  insert into cma.connection_form (tenant_id, connection_id, source_form_id, name, is_counted, lead_source, market, kept_fields)
  values (cma.current_tenant_id(), p_connection_id, p_form_id, p_form_id, p_is_counted, nullif(btrim(p_lead_source), ''),
          p_market, v_fields)
  on conflict (tenant_id, connection_id, source_form_id) do update
    set is_counted = excluded.is_counted, lead_source = excluded.lead_source, market = excluded.market,
        kept_fields = excluded.kept_fields;
exception when check_violation or not_null_violation then
  raise exception 'invalid form: %', sqlerrm using errcode = 'CMA04';
end
$$;

create or replace function cma.set_call_outcome(p_connection_id uuid, p_outcome_ref text, p_is_connected boolean)
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  if p_is_connected is null then
    raise exception 'is_connected must be true or false' using errcode = 'CMA04';
  end if;
  insert into cma.connection_call_outcome (tenant_id, connection_id, outcome_ref, label, is_connected)
  values (cma.current_tenant_id(), p_connection_id, p_outcome_ref, p_outcome_ref, p_is_connected)
  on conflict (tenant_id, connection_id, outcome_ref) do update set is_connected = excluded.is_connected;
exception when check_violation or not_null_violation then
  raise exception 'invalid call outcome: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- A person's id in another system (users.manage_all), for attribution: the CRM owner id, the
-- telephony user id. The system is data but must read <system>_owner or <system>_user, so a sign-in
-- id (google, mock) or a system user's id can never be set or removed here.
create or replace function cma.set_user_external_id(p_user_id uuid, p_system text, p_external_id text)
returns void
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_ext    text := btrim(coalesce(p_external_id, ''));
  v_owner  uuid;
begin
  perform cma.assert_permission('users.manage_all');
  if coalesce(p_system, '') !~ '^[a-z0-9]+_(owner|user)$' then
    raise exception 'system % must read <system>_owner or <system>_user', p_system using errcode = 'CMA04';
  end if;
  if v_ext = '' or length(v_ext) > 100 or v_ext ~ '[[:space:]]' then
    raise exception 'the id must be 1 to 100 characters without spaces' using errcode = 'CMA04';
  end if;
  if not exists (select 1 from cma.app_user u where u.tenant_id = v_tenant and u.id = p_user_id and u.kind = 'person') then
    raise exception 'no person % in the current tenant', p_user_id using errcode = 'CMA02';
  end if;
  select x.user_id into v_owner from cma.app_user_external_id x
  where x.tenant_id = v_tenant and x.system = p_system and x.external_id = v_ext;
  if v_owner is not null and v_owner <> p_user_id then
    raise exception 'this % id already belongs to another person in the current tenant', p_system using errcode = 'CMA03';
  end if;
  insert into cma.app_user_external_id (tenant_id, user_id, system, external_id)
  values (v_tenant, p_user_id, p_system, v_ext)
  on conflict (tenant_id, user_id, system) do update set external_id = excluded.external_id
  where cma.app_user_external_id.external_id is distinct from excluded.external_id;
end
$$;

create or replace function cma.remove_user_external_id(p_user_id uuid, p_system text)
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('users.manage_all');
  if coalesce(p_system, '') !~ '^[a-z0-9]+_(owner|user)$' then
    raise exception 'system % must read <system>_owner or <system>_user', p_system using errcode = 'CMA04';
  end if;
  delete from cma.app_user_external_id x
  where x.tenant_id = cma.current_tenant_id() and x.user_id = p_user_id and x.system = p_system
    and exists (select 1 from cma.app_user u where u.tenant_id = x.tenant_id and u.id = x.user_id and u.kind = 'person');
  if not found then
    raise exception 'person % has no % id', p_user_id, p_system using errcode = 'CMA02';
  end if;
end
$$;

-- The mapping and settings the adapter needs for one connection (0006, plus slots, lead pipelines
-- and the settings): {fields: [{entity, field, refSystem, slot, property}], pipelines: [{...,
-- isLead}], settings: {...}}
create or replace function cma.connection_config(p_connection_id uuid)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['ingest.write', 'tenant.configure']);
  if not exists (select 1 from cma.integration_connection c where c.tenant_id = v_tenant and c.id = p_connection_id) then
    raise exception 'no connection % in the current tenant', p_connection_id using errcode = 'CMA02';
  end if;
  return jsonb_build_object(
    'fields', coalesce((select jsonb_agg(jsonb_build_object('entity', f.entity, 'field', f.field,
                                                             'refSystem', nullif(f.ref_system, ''), 'slot', f.slot,
                                                             'property', f.source_property)
                                         order by f.entity, f.field, f.ref_system, f.slot)
                        from cma.connection_field f where f.tenant_id = v_tenant and f.connection_id = p_connection_id), '[]'::jsonb),
    'pipelines', coalesce((select jsonb_agg(jsonb_build_object('recordType', p.record_type, 'pipelineId', p.source_pipeline_id,
                                                                'label', p.label, 'isCounted', p.is_counted, 'isRouted', p.is_routed,
                                                                'isLead', p.is_lead, 'workType', s.key, 'status', p.status)
                                            order by p.record_type, p.label, p.source_pipeline_id)
                           from cma.connection_pipeline p
                           left join cma.skill s on s.tenant_id = p.tenant_id and s.id = p.work_type_skill_id
                           where p.tenant_id = v_tenant and p.connection_id = p_connection_id), '[]'::jsonb),
    'settings', (select c.settings from cma.integration_connection c where c.tenant_id = v_tenant and c.id = p_connection_id));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 10. The ingest write path (ingest.write)
-- ---------------------------------------------------------------------------------------------
-- 0006's record upsert with the new keys: amount, currency, sourceChannel, category. The market
-- passes through normalize_market. Everything else as in 0006.
create or replace function cma.ingest_upsert_records(p_connection_id uuid, p_records jsonb)
returns table (record_type text, source_id text, outcome text, is_closed boolean)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant   uuid := cma.current_tenant_id();
  v_system   text;
  r          jsonb;
  v_type     text;
  v_src      text;
  v_updated  timestamptz;
  v_deleted  timestamptz;
  v_closed   boolean;
  v_old      cma.crm_record;
  v_new_id   uuid;
begin
  perform cma.assert_permission('ingest.write');
  v_system := cma.active_connection_adapter(p_connection_id);
  if p_records is null or jsonb_typeof(p_records) <> 'array' or jsonb_array_length(p_records) > 500 then
    raise exception 'records must be an array of at most 500' using errcode = 'CMA04';
  end if;
  for r in select value from jsonb_array_elements(p_records) loop
    v_type := r ->> 'recordType';
    v_src  := r ->> 'sourceId';
    if coalesce(v_type, '') !~ '^[a-z][a-z0-9_]*$' or v_type = 'contact' or coalesce(v_src, '') = '' then
      raise exception 'every record needs a recordType and a sourceId' using errcode = 'CMA04';
    end if;
    v_updated := cma.json_time(r -> 'updatedAt', 'updatedAt');
    v_deleted := cma.json_time(r -> 'deletedAt', 'deletedAt');
    select * into v_old from cma.crm_record cr
    where cr.tenant_id = v_tenant and cr.connection_id = p_connection_id and cr.record_type = v_type and cr.source_id = v_src
    for update;

    if v_deleted is not null then
      if v_old.id is null then
        return query select v_type, v_src, 'unknown'::text, null::boolean;
      else
        update cma.crm_record cr set source_deleted_at = v_deleted, synced_at = now()
        where cr.tenant_id = v_tenant and cr.id = v_old.id and cr.source_deleted_at is distinct from v_deleted;
        return query select v_type, v_src, 'deleted'::text, v_old.is_closed;
      end if;
      continue;
    end if;

    if v_old.id is not null and v_old.source_updated_at is not null
       and (v_updated is null or v_updated < v_old.source_updated_at) then
      return query select v_type, v_src, 'stale'::text, v_old.is_closed;
      continue;
    end if;

    select s.is_closed into v_closed
    from cma.connection_stage s
    where s.tenant_id = v_tenant and s.connection_id = p_connection_id and s.record_type = v_type
      and s.source_pipeline_id = r ->> 'pipelineId' and s.source_stage_id = r ->> 'stageId';

    if v_old.id is null then
      insert into cma.crm_record (tenant_id, connection_id, source_system, record_type, source_id, pipeline_id, stage_id,
                                  owner_ref, contact_source_id, market, language, is_closed, closed_at,
                                  source_created_at, source_updated_at, raw,
                                  amount, currency, source_channel, category)
      values (v_tenant, p_connection_id, v_system, v_type, v_src, nullif(r ->> 'pipelineId', ''), nullif(r ->> 'stageId', ''),
              nullif(r ->> 'ownerRef', ''), nullif(r ->> 'contactId', ''), cma.normalize_market(r ->> 'market'),
              nullif(btrim(r ->> 'language'), ''), v_closed,
              case when v_closed then coalesce(cma.json_time(r -> 'closedAt', 'closedAt'), now()) end,
              coalesce(cma.json_time(r -> 'createdAt', 'createdAt'), now()), v_updated, coalesce(r -> 'raw', '{}'::jsonb),
              cma.json_amount(r -> 'amount'), cma.json_currency(r ->> 'currency'),
              left(nullif(btrim(r ->> 'sourceChannel'), ''), 100), left(nullif(btrim(r ->> 'category'), ''), 100))
      returning id into v_new_id;
      return query select v_type, v_src, 'inserted'::text, v_closed;
    else
      update cma.crm_record cr
         set pipeline_id = nullif(r ->> 'pipelineId', ''),
             stage_id = nullif(r ->> 'stageId', ''),
             owner_ref = nullif(r ->> 'ownerRef', ''),
             contact_source_id = coalesce(nullif(r ->> 'contactId', ''), cr.contact_source_id),
             market = cma.normalize_market(r ->> 'market'),
             language = nullif(btrim(r ->> 'language'), ''),
             is_closed = v_closed,
             closed_at = case when v_closed then coalesce(cma.json_time(r -> 'closedAt', 'closedAt'),
                                                          case when cr.is_closed then cr.closed_at end, now()) end,
             source_created_at = coalesce(cma.json_time(r -> 'createdAt', 'createdAt'), cr.source_created_at),
             source_updated_at = v_updated,
             source_deleted_at = null,
             synced_at = now(),
             raw = coalesce(r -> 'raw', '{}'::jsonb),
             amount = cma.json_amount(r -> 'amount'),
             currency = cma.json_currency(r ->> 'currency'),
             source_channel = left(nullif(btrim(r ->> 'sourceChannel'), ''), 100),
             category = left(nullif(btrim(r ->> 'category'), ''), 100)
       where cr.tenant_id = v_tenant and cr.id = v_old.id;
      return query select v_type, v_src, 'updated'::text, v_closed;
    end if;
  end loop;
end
$$;

-- 0006's contact upsert with currency and store, the country through normalize_market, and refs
-- with slots. refs: {system: id | null | [id1, id2, ...]}: a list replaces the system's refs (slot
-- n is the n-th element; null or empty leaves that slot empty, slots beyond the list are removed);
-- a single id or null is a list of one. A deleted contact also loses currency and store.
create or replace function cma.ingest_upsert_contacts(p_connection_id uuid, p_contacts jsonb)
returns table (source_id text, outcome text)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant   uuid := cma.current_tenant_id();
  v_system   text;
  c          jsonb;
  v_src      text;
  v_updated  timestamptz;
  v_deleted  timestamptz;
  v_old      cma.crm_contact;
  v_id       uuid;
  k          text;
  v          jsonb;
  v_list     jsonb;
  v_slot     integer;
  v_store    text;
begin
  perform cma.assert_permission('ingest.write');
  v_system := cma.active_connection_adapter(p_connection_id);
  if p_contacts is null or jsonb_typeof(p_contacts) <> 'array' or jsonb_array_length(p_contacts) > 500 then
    raise exception 'contacts must be an array of at most 500' using errcode = 'CMA04';
  end if;
  for c in select value from jsonb_array_elements(p_contacts) loop
    v_src := c ->> 'sourceId';
    if coalesce(v_src, '') = '' then
      raise exception 'every contact needs a sourceId' using errcode = 'CMA04';
    end if;
    if c ? 'refs' and jsonb_typeof(c -> 'refs') <> 'object' then
      raise exception 'refs must be an object of system to id' using errcode = 'CMA04';
    end if;
    v_updated := cma.json_time(c -> 'updatedAt', 'updatedAt');
    v_deleted := cma.json_time(c -> 'deletedAt', 'deletedAt');
    select * into v_old from cma.crm_contact cc
    where cc.tenant_id = v_tenant and cc.connection_id = p_connection_id and cc.source_id = v_src
    for update;

    if v_old.id is null and not exists (select 1 from cma.crm_record cr
                                        where cr.tenant_id = v_tenant and cr.connection_id = p_connection_id
                                          and cr.contact_source_id = v_src) then
      return query select v_src, 'not_held'::text;
      continue;
    end if;

    if v_deleted is not null then
      if v_old.id is null then
        return query select v_src, 'not_held'::text;
      else
        update cma.crm_contact cc
           set country = null, language = null, currency = null, store = null, raw = '{}'::jsonb,
               source_deleted_at = v_deleted, synced_at = now()
         where cc.tenant_id = v_tenant and cc.id = v_old.id;
        delete from cma.crm_contact_ref cr where cr.tenant_id = v_tenant and cr.contact_id = v_old.id;
        return query select v_src, 'deleted'::text;
      end if;
      continue;
    end if;

    if v_old.id is not null and v_old.source_updated_at is not null
       and (v_updated is null or v_updated < v_old.source_updated_at) then
      return query select v_src, 'stale'::text;
      continue;
    end if;

    v_store := lower(nullif(btrim(c ->> 'store'), ''));
    if v_store !~ '^[a-z0-9-]{1,60}$' then
      v_store := null;
    end if;
    if v_old.id is null then
      insert into cma.crm_contact (tenant_id, connection_id, source_system, source_id, country, language, currency, store,
                                   source_updated_at, raw)
      values (v_tenant, p_connection_id, v_system, v_src, cma.normalize_market(c ->> 'country'), nullif(btrim(c ->> 'language'), ''),
              cma.json_currency(c ->> 'currency'), v_store, v_updated, coalesce(c -> 'raw', '{}'::jsonb))
      returning id into v_id;
    else
      v_id := v_old.id;
      update cma.crm_contact cc
         set country = cma.normalize_market(c ->> 'country'), language = nullif(btrim(c ->> 'language'), ''),
             currency = cma.json_currency(c ->> 'currency'), store = v_store,
             source_updated_at = v_updated, source_deleted_at = null, synced_at = now(),
             raw = coalesce(c -> 'raw', '{}'::jsonb)
       where cc.tenant_id = v_tenant and cc.id = v_id;
    end if;

    for k, v in select key, value from jsonb_each(coalesce(c -> 'refs', '{}'::jsonb)) loop
      if k !~ '^[a-z0-9_]+$' then
        raise exception 'ref system % must be lowercase letters, digits or underscores', k using errcode = 'CMA04';
      end if;
      v_list := case when jsonb_typeof(v) = 'array' then v else jsonb_build_array(v) end;
      if jsonb_array_length(v_list) > 9 then
        raise exception 'at most 9 refs per system' using errcode = 'CMA04';
      end if;
      delete from cma.crm_contact_ref cr
      where cr.tenant_id = v_tenant and cr.contact_id = v_id and cr.system = k and cr.slot > jsonb_array_length(v_list);
      for v_slot in 1 .. jsonb_array_length(v_list) loop
        v := v_list -> (v_slot - 1);
        if jsonb_typeof(v) = 'null' or btrim(v #>> '{}') = '' then
          delete from cma.crm_contact_ref cr
          where cr.tenant_id = v_tenant and cr.contact_id = v_id and cr.system = k and cr.slot = v_slot;
        else
          insert into cma.crm_contact_ref (tenant_id, contact_id, system, slot, external_id)
          values (v_tenant, v_id, k, v_slot, btrim(v #>> '{}'))
          on conflict (tenant_id, contact_id, system, slot)
            do update set external_id = excluded.external_id, synced_at = now()
            where cma.crm_contact_ref.external_id is distinct from excluded.external_id;
        end if;
      end loop;
    end loop;
    return query select v_src, case when v_old.id is null then 'inserted' else 'updated' end;
  end loop;
exception
  when check_violation or invalid_text_representation then
    raise exception 'invalid contact: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- Upserts CRM calls as the source answered them: [{sourceId, occurredAt, direction, status,
-- outcomeRef, durationSeconds, ownerRef, sourceApp, counterpartHash, createdAt, updatedAt,
-- deletedAt?, raw?}], at most 500. Older reads are stale; a deleted call keeps its id and times and
-- loses its hash and raw payload.
create or replace function cma.ingest_upsert_calls(p_connection_id uuid, p_calls jsonb)
returns table (source_id text, outcome text)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant   uuid := cma.current_tenant_id();
  v_system   text;
  c          jsonb;
  v_src      text;
  v_updated  timestamptz;
  v_deleted  timestamptz;
  v_old      cma.crm_call;
  v_dir      text;
begin
  perform cma.assert_permission('ingest.write');
  v_system := cma.active_connection_adapter(p_connection_id);
  if p_calls is null or jsonb_typeof(p_calls) <> 'array' or jsonb_array_length(p_calls) > 500 then
    raise exception 'calls must be an array of at most 500' using errcode = 'CMA04';
  end if;
  for c in select value from jsonb_array_elements(p_calls) loop
    v_src := c ->> 'sourceId';
    if coalesce(v_src, '') = '' then
      raise exception 'every call needs a sourceId' using errcode = 'CMA04';
    end if;
    v_updated := cma.json_time(c -> 'updatedAt', 'updatedAt');
    v_deleted := cma.json_time(c -> 'deletedAt', 'deletedAt');
    select * into v_old from cma.crm_call cc
    where cc.tenant_id = v_tenant and cc.connection_id = p_connection_id and cc.source_id = v_src
    for update;

    if v_deleted is not null then
      if v_old.id is null then
        return query select v_src, 'unknown'::text;
      else
        update cma.crm_call cc set source_deleted_at = v_deleted, counterpart_hash = null, raw = '{}'::jsonb, synced_at = now()
        where cc.tenant_id = v_tenant and cc.id = v_old.id;
        return query select v_src, 'deleted'::text;
      end if;
      continue;
    end if;

    if v_old.id is not null and v_old.source_updated_at is not null
       and (v_updated is null or v_updated < v_old.source_updated_at) then
      return query select v_src, 'stale'::text;
      continue;
    end if;

    v_dir := coalesce(nullif(lower(btrim(c ->> 'direction')), ''), 'unknown');
    if v_dir not in ('inbound', 'outbound', 'unknown') then
      raise exception 'direction must be inbound, outbound or unknown, got %', c ->> 'direction' using errcode = 'CMA04';
    end if;
    if v_old.id is null then
      insert into cma.crm_call (tenant_id, connection_id, source_system, source_id, occurred_at, direction, status, outcome_ref,
                                duration_seconds, owner_ref, source_app, counterpart_hash, source_created_at,
                                source_updated_at, raw)
      values (v_tenant, p_connection_id, v_system, v_src, cma.json_time(c -> 'occurredAt', 'occurredAt'), v_dir,
              nullif(btrim(c ->> 'status'), ''), nullif(btrim(c ->> 'outcomeRef'), ''),
              (c ->> 'durationSeconds')::integer, nullif(btrim(c ->> 'ownerRef'), ''),
              nullif(lower(btrim(c ->> 'sourceApp')), ''), nullif(lower(btrim(c ->> 'counterpartHash')), ''),
              cma.json_time(c -> 'createdAt', 'createdAt'), v_updated, coalesce(c -> 'raw', '{}'::jsonb));
      return query select v_src, 'inserted'::text;
    else
      update cma.crm_call cc
         set occurred_at = cma.json_time(c -> 'occurredAt', 'occurredAt'),
             direction = v_dir,
             status = nullif(btrim(c ->> 'status'), ''),
             outcome_ref = nullif(btrim(c ->> 'outcomeRef'), ''),
             duration_seconds = (c ->> 'durationSeconds')::integer,
             owner_ref = nullif(btrim(c ->> 'ownerRef'), ''),
             source_app = nullif(lower(btrim(c ->> 'sourceApp')), ''),
             counterpart_hash = nullif(lower(btrim(c ->> 'counterpartHash')), ''),
             source_created_at = coalesce(cma.json_time(c -> 'createdAt', 'createdAt'), cc.source_created_at),
             source_updated_at = v_updated,
             source_deleted_at = null,
             synced_at = now(),
             raw = coalesce(c -> 'raw', '{}'::jsonb)
       where cc.tenant_id = v_tenant and cc.id = v_old.id;
      return query select v_src, 'updated'::text;
    end if;
  end loop;
exception
  when check_violation or not_null_violation or invalid_text_representation or numeric_value_out_of_range then
    raise exception 'invalid call: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- Records association changes: [{fromType, fromId, toType, toId, removed, changedAt}], at most 500.
-- The pair is stored in its fixed direction (activity or record to contact, activity to record);
-- the other direction is turned round. A change older than the stored one is stale. Outcomes:
-- added, removed, readded, unchanged, stale.
create or replace function cma.ingest_upsert_associations(p_connection_id uuid, p_items jsonb)
returns table (from_type text, from_id text, to_type text, to_id text, outcome text)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant   uuid := cma.current_tenant_id();
  i          jsonb;
  v_ft       text;
  v_fi       text;
  v_tt       text;
  v_ti       text;
  v_tmp      text;
  v_removed  boolean;
  v_changed  timestamptz;
  v_old      cma.crm_association;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then
    raise exception 'associations must be an array of at most 500' using errcode = 'CMA04';
  end if;
  for i in select value from jsonb_array_elements(p_items) loop
    v_ft := i ->> 'fromType'; v_fi := i ->> 'fromId'; v_tt := i ->> 'toType'; v_ti := i ->> 'toId';
    if coalesce(v_ft, '') = '' or coalesce(v_fi, '') = '' or coalesce(v_tt, '') = '' or coalesce(v_ti, '') = ''
       or jsonb_typeof(i -> 'removed') is distinct from 'boolean' then
      raise exception 'every association needs fromType, fromId, toType, toId and removed' using errcode = 'CMA04';
    end if;
    v_removed := (i ->> 'removed')::boolean;
    v_changed := cma.json_time(i -> 'changedAt', 'changedAt');
    if v_changed is null then
      raise exception 'every association needs changedAt' using errcode = 'CMA04';
    end if;
    if v_ft = 'contact' or v_tt = 'crm_call' then
      v_tmp := v_ft; v_ft := v_tt; v_tt := v_tmp;
      v_tmp := v_fi; v_fi := v_ti; v_ti := v_tmp;
    end if;
    select * into v_old from cma.crm_association a
    where a.tenant_id = v_tenant and a.connection_id = p_connection_id
      and a.from_type = v_ft and a.from_id = v_fi and a.to_type = v_tt and a.to_id = v_ti
    for update;
    if v_old.tenant_id is null then
      insert into cma.crm_association (tenant_id, connection_id, from_type, from_id, to_type, to_id, removed_at, source_changed_at)
      values (v_tenant, p_connection_id, v_ft, v_fi, v_tt, v_ti, case when v_removed then v_changed end, v_changed);
      return query select v_ft, v_fi, v_tt, v_ti, case when v_removed then 'removed' else 'added' end;
    elsif v_changed < v_old.source_changed_at then
      return query select v_ft, v_fi, v_tt, v_ti, 'stale'::text;
    else
      update cma.crm_association a
         set removed_at = case when v_removed then coalesce(a.removed_at, v_changed) end,
             source_changed_at = v_changed
       where a.tenant_id = v_tenant and a.connection_id = p_connection_id
         and a.from_type = v_ft and a.from_id = v_fi and a.to_type = v_tt and a.to_id = v_ti;
      return query select v_ft, v_fi, v_tt, v_ti,
        case when v_removed and v_old.removed_at is null then 'removed'
             when not v_removed and v_old.removed_at is not null then 'readded'
             else 'unchanged' end;
    end if;
  end loop;
exception
  when check_violation or not_null_violation then
    raise exception 'invalid association: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- Refreshes the call outcome catalog: [{outcomeRef, label}]. is_connected stays; an outcome missing
-- from the list is archived. Answers the number of active outcomes.
create or replace function cma.ingest_upsert_call_outcomes(p_connection_id uuid, p_items jsonb)
returns integer
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  i        jsonb;
  v_n      integer;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then
    raise exception 'outcomes must be an array of at most 500' using errcode = 'CMA04';
  end if;
  for i in select value from jsonb_array_elements(p_items) loop
    if coalesce(i ->> 'outcomeRef', '') = '' then
      raise exception 'every outcome needs an outcomeRef' using errcode = 'CMA04';
    end if;
    insert into cma.connection_call_outcome (tenant_id, connection_id, outcome_ref, label, status, refreshed_at)
    values (v_tenant, p_connection_id, i ->> 'outcomeRef', left(coalesce(nullif(btrim(i ->> 'label'), ''), i ->> 'outcomeRef'), 100),
            'active', now())
    on conflict (tenant_id, connection_id, outcome_ref)
      do update set label = excluded.label, status = 'active', refreshed_at = now();
  end loop;
  update cma.connection_call_outcome o set status = 'archived'
  where o.tenant_id = v_tenant and o.connection_id = p_connection_id and o.status = 'active'
    and not exists (select 1 from jsonb_array_elements(p_items) x where x ->> 'outcomeRef' = o.outcome_ref);
  select count(*)::integer into v_n from cma.connection_call_outcome o
  where o.tenant_id = v_tenant and o.connection_id = p_connection_id and o.status = 'active';
  return v_n;
exception
  when check_violation or not_null_violation then
    raise exception 'invalid outcome: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- Refreshes the form catalog: [{formId, name}]. Counted, lead source, market and kept fields stay;
-- a form missing from the list is archived. Answers the number of active forms.
create or replace function cma.ingest_upsert_forms(p_connection_id uuid, p_items jsonb)
returns integer
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  i        jsonb;
  v_n      integer;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then
    raise exception 'forms must be an array of at most 500' using errcode = 'CMA04';
  end if;
  for i in select value from jsonb_array_elements(p_items) loop
    if coalesce(i ->> 'formId', '') = '' then
      raise exception 'every form needs a formId' using errcode = 'CMA04';
    end if;
    insert into cma.connection_form (tenant_id, connection_id, source_form_id, name, status, refreshed_at)
    values (v_tenant, p_connection_id, i ->> 'formId', left(coalesce(nullif(btrim(i ->> 'name'), ''), i ->> 'formId'), 200),
            'active', now())
    on conflict (tenant_id, connection_id, source_form_id)
      do update set name = excluded.name, status = 'active', refreshed_at = now();
  end loop;
  update cma.connection_form f set status = 'archived'
  where f.tenant_id = v_tenant and f.connection_id = p_connection_id and f.status = 'active'
    and not exists (select 1 from jsonb_array_elements(p_items) x where x ->> 'formId' = f.source_form_id);
  select count(*)::integer into v_n from cma.connection_form f
  where f.tenant_id = v_tenant and f.connection_id = p_connection_id and f.status = 'active';
  return v_n;
exception
  when check_violation or not_null_violation then
    raise exception 'invalid form: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- Records form submissions: [{sourceId, formId, submittedAt, pageHost, pagePath, utm, contactId,
-- contactResolution, keptValues}], at most 500. Insert-only: a known submission only moves its
-- contact resolution forward (never away from resolved). The query string is cut off the page,
-- UTM keeps source, medium, campaign, term and content, and keptValues are filtered again against
-- the form's kept fields (defence in depth: the service sends only those). A form not yet in the
-- catalog is added, counted, with its id as name. Outcomes: inserted, known, resolved.
create or replace function cma.ingest_upsert_form_submissions(p_connection_id uuid, p_items jsonb)
returns table (source_id text, outcome text)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant   uuid := cma.current_tenant_id();
  i          jsonb;
  v_src      text;
  v_form     text;
  v_contact  text;
  v_res      text;
  v_kept     text[];
  v_old      cma.form_submission;
  v_path     text;
  v_host     text;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then
    raise exception 'submissions must be an array of at most 500' using errcode = 'CMA04';
  end if;
  for i in select value from jsonb_array_elements(p_items) loop
    v_src := i ->> 'sourceId';
    v_form := i ->> 'formId';
    if coalesce(v_src, '') = '' or coalesce(v_form, '') = '' then
      raise exception 'every submission needs a sourceId and a formId' using errcode = 'CMA04';
    end if;
    if (i -> 'utm') is not null and jsonb_typeof(i -> 'utm') not in ('object', 'null') then
      raise exception 'utm must be an object' using errcode = 'CMA04';
    end if;
    if (i -> 'keptValues') is not null and jsonb_typeof(i -> 'keptValues') not in ('object', 'null') then
      raise exception 'keptValues must be an object' using errcode = 'CMA04';
    end if;
    v_contact := nullif(btrim(i ->> 'contactId'), '');
    v_res := case when v_contact is not null then 'resolved'
                  else coalesce(nullif(i ->> 'contactResolution', ''), 'pending') end;
    if v_res not in ('resolved', 'no_email', 'not_found', 'ambiguous', 'pending') or (v_res = 'resolved' and v_contact is null) then
      raise exception 'contactResolution must be no_email, not_found, ambiguous or pending without a contactId, got %', v_res
        using errcode = 'CMA04';
    end if;

    select * into v_old from cma.form_submission s
    where s.tenant_id = v_tenant and s.connection_id = p_connection_id and s.source_id = v_src
    for update;
    if v_old.id is not null then
      if v_old.contact_resolution <> 'resolved' and v_res <> v_old.contact_resolution then
        update cma.form_submission s set contact_source_id = v_contact, contact_resolution = v_res, synced_at = now()
        where s.tenant_id = v_tenant and s.id = v_old.id;
        return query select v_src, 'resolved'::text;
      else
        return query select v_src, 'known'::text;
      end if;
      continue;
    end if;

    insert into cma.connection_form (tenant_id, connection_id, source_form_id, name)
    values (v_tenant, p_connection_id, v_form, left(v_form, 200))
    on conflict (tenant_id, connection_id, source_form_id) do nothing;
    select f.kept_fields into v_kept from cma.connection_form f
    where f.tenant_id = v_tenant and f.connection_id = p_connection_id and f.source_form_id = v_form;

    v_path := split_part(split_part(btrim(i ->> 'pagePath'), '?', 1), '#', 1);
    v_host := lower(nullif(btrim(i ->> 'pageHost'), ''));
    if v_host !~ '^[a-z0-9.-]{1,255}$' then
      v_host := null;
    end if;
    insert into cma.form_submission (tenant_id, connection_id, source_id, source_form_id, submitted_at, page_host, page_path,
                                     utm, contact_source_id, contact_resolution, kept_values)
    values (v_tenant, p_connection_id, v_src, v_form,
            coalesce(cma.json_time(i -> 'submittedAt', 'submittedAt'), now()),
            v_host, left(nullif(v_path, ''), 1000),
            coalesce((select jsonb_object_agg(e.key, left(e.value #>> '{}', 200))
                      from jsonb_each(case when jsonb_typeof(i -> 'utm') = 'object' then i -> 'utm' else '{}'::jsonb end) e
                      where e.key in ('source', 'medium', 'campaign', 'term', 'content')
                        and jsonb_typeof(e.value) in ('string', 'number')), '{}'::jsonb),
            v_contact, v_res,
            coalesce((select jsonb_object_agg(e.key, left(e.value #>> '{}', 200))
                      from jsonb_each(case when jsonb_typeof(i -> 'keptValues') = 'object' then i -> 'keptValues' else '{}'::jsonb end) e
                      where e.key = any (v_kept)
                        and jsonb_typeof(e.value) in ('string', 'number', 'boolean')), '{}'::jsonb));
    return query select v_src, 'inserted'::text;
  end loop;
exception
  when check_violation or not_null_violation then
    raise exception 'invalid submission: %', sqlerrm using errcode = 'CMA04';
end
$$;

create or replace function cma.ingest_cursor_get(p_connection_id uuid, p_stream text)
returns jsonb
language plpgsql stable
as $$
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  return (select s.cursor from cma.sync_cursor s
          where s.tenant_id = cma.current_tenant_id() and s.connection_id = p_connection_id and s.stream = p_stream);
end
$$;

create or replace function cma.ingest_cursor_set(p_connection_id uuid, p_stream text, p_cursor jsonb)
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  if p_cursor is null then
    raise exception 'a cursor is needed' using errcode = 'CMA04';
  end if;
  insert into cma.sync_cursor (tenant_id, connection_id, stream, cursor)
  values (cma.current_tenant_id(), p_connection_id, p_stream, p_cursor)
  on conflict (tenant_id, connection_id, stream) do update set cursor = excluded.cursor;
exception when check_violation or not_null_violation then
  raise exception 'invalid cursor: %', sqlerrm using errcode = 'CMA04';
end
$$;

create or replace function cma.ingest_sync_run_start(p_connection_id uuid, p_job text, p_stream text,
                                                     p_from timestamptz, p_to timestamptz)
returns uuid
language plpgsql
as $$
declare
  v_id uuid;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  insert into cma.sync_run (tenant_id, connection_id, job, stream, from_at, to_at)
  values (cma.current_tenant_id(), p_connection_id, p_job, nullif(btrim(p_stream), ''), p_from, p_to)
  returning id into v_id;
  return v_id;
exception when check_violation or not_null_violation then
  raise exception 'invalid sync run: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- Finishes a run once: succeeded or failed, with counts {fetched, upserted, stale, skipped, failed}
-- (whole numbers, each optional) and a short error
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
                where e.key not in ('fetched', 'upserted', 'stale', 'skipped', 'failed')
                   or jsonb_typeof(e.value) <> 'number' or (e.value #>> '{}') !~ '^\d+$')) then
    raise exception 'counts are whole numbers for fetched, upserted, stale, skipped and failed' using errcode = 'CMA04';
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

-- Privacy deletion of a contact at the source: its attributes and refs are cleared (the id stays,
-- marked deleted), the hash on its calls is cleared, its form submissions keep the id and lose
-- their kept values. Answers what was cleared: {contacts, refs, calls, submissions}.
create or replace function cma.ingest_contact_forget(p_connection_id uuid, p_contact_source_id text)
returns jsonb
language plpgsql
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_contact uuid;
  v_c       integer := 0;
  v_r       integer := 0;
  v_k       integer := 0;
  v_s       integer := 0;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  if coalesce(p_contact_source_id, '') = '' then
    raise exception 'a contact id is needed' using errcode = 'CMA04';
  end if;
  update cma.crm_contact cc
     set country = null, language = null, currency = null, store = null, raw = '{}'::jsonb,
         source_deleted_at = coalesce(cc.source_deleted_at, now()), synced_at = now()
   where cc.tenant_id = v_tenant and cc.connection_id = p_connection_id and cc.source_id = p_contact_source_id
  returning cc.id into v_contact;
  get diagnostics v_c = row_count;
  if v_contact is not null then
    delete from cma.crm_contact_ref r where r.tenant_id = v_tenant and r.contact_id = v_contact;
    get diagnostics v_r = row_count;
  end if;
  update cma.crm_call k set counterpart_hash = null, synced_at = now()
  where k.tenant_id = v_tenant and k.connection_id = p_connection_id and k.counterpart_hash is not null
    and exists (select 1 from cma.crm_association a
                where a.tenant_id = k.tenant_id and a.connection_id = k.connection_id
                  and a.from_type = 'crm_call' and a.from_id = k.source_id
                  and a.to_type = 'contact' and a.to_id = p_contact_source_id);
  get diagnostics v_k = row_count;
  update cma.form_submission s set kept_values = '{}'::jsonb, synced_at = now()
  where s.tenant_id = v_tenant and s.connection_id = p_connection_id and s.contact_source_id = p_contact_source_id
    and s.kept_values <> '{}'::jsonb;
  get diagnostics v_s = row_count;
  return jsonb_build_object('contacts', v_c, 'refs', v_r, 'calls', v_k, 'submissions', v_s);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 11. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.normalize_market(text)',
    'cma.business_seconds(text,timestamptz,timestamptz)',
    'cma.next_business_noon(text,timestamptz)',
    'cma.upsert_market(text,text,text,text,text,text,smallint,integer)',
    'cma.set_market_status(text,text)',
    'cma.set_market_alias(text,text)',
    'cma.remove_market_alias(text)',
    'cma.set_business_hours(text,smallint,text)',
    'cma.set_business_holiday(text,date,text)',
    'cma.remove_business_holiday(text,date)',
    'cma.set_connection_settings(uuid,jsonb)',
    'cma.set_connection_field(uuid,text,text,text,text)',
    'cma.set_connection_field(uuid,text,text,text,text,smallint)',
    'cma.set_pipeline_lead(uuid,text,text,boolean)',
    'cma.set_form(uuid,text,boolean,text,text,text[])',
    'cma.set_call_outcome(uuid,text,boolean)',
    'cma.set_user_external_id(uuid,text,text)',
    'cma.remove_user_external_id(uuid,text)',
    'cma.connection_config(uuid)',
    'cma.ingest_upsert_records(uuid,jsonb)',
    'cma.ingest_upsert_contacts(uuid,jsonb)',
    'cma.ingest_upsert_calls(uuid,jsonb)',
    'cma.ingest_upsert_associations(uuid,jsonb)',
    'cma.ingest_upsert_call_outcomes(uuid,jsonb)',
    'cma.ingest_upsert_forms(uuid,jsonb)',
    'cma.ingest_upsert_form_submissions(uuid,jsonb)',
    'cma.ingest_cursor_get(uuid,text)',
    'cma.ingest_cursor_set(uuid,text,jsonb)',
    'cma.ingest_sync_run_start(uuid,text,text,timestamptz,timestamptz)',
    'cma.ingest_sync_run_finish(uuid,text,jsonb,text)',
    'cma.ingest_contact_forget(uuid,text)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
  -- helpers the functions above call in the caller's rights
  foreach f in array array[
    'cma.connection_settings_ok(jsonb)', 'cma.json_amount(jsonb)', 'cma.json_currency(text)',
    'cma.business_schedule_of(text)', 'cma.assert_connection(uuid)', 'cma.assert_market(text,boolean)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 12. Reporting views (no raw payloads, no hashes, no keys or secret names)
-- ---------------------------------------------------------------------------------------------
create or replace view cma_read.market as
  select id, tenant_id, code, name, time_zone, language_code, language_skill_key, min_language_level, currency,
         status, sort_order, created_at, updated_at
  from cma.market
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.market_alias as
  select tenant_id, alias, code, updated_at
  from cma.market_alias
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.business_hours as
  select tenant_id, market, weekday, opens_at, closes_at, updated_at
  from cma.business_hours
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.business_holiday as
  select tenant_id, market, day, name, updated_at
  from cma.business_holiday
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.crm_call as
  select id, tenant_id, connection_id, source_system, source_id, occurred_at, direction, status, outcome_ref,
         duration_seconds, owner_ref, source_app, source_created_at, source_updated_at, source_deleted_at, synced_at
  from cma.crm_call
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.connection_call_outcome as
  select tenant_id, connection_id, outcome_ref, label, is_connected, status, refreshed_at
  from cma.connection_call_outcome
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.crm_association as
  select tenant_id, connection_id, from_type, from_id, to_type, to_id, first_seen_at, removed_at, source_changed_at
  from cma.crm_association
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.connection_form as
  select tenant_id, connection_id, source_form_id, name, is_counted, lead_source, market, kept_fields, status, refreshed_at
  from cma.connection_form
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.form_submission as
  select id, tenant_id, connection_id, source_id, source_form_id, submitted_at, page_host, page_path, utm,
         contact_source_id, contact_resolution, kept_values, synced_at
  from cma.form_submission
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.sync_run as
  select id, tenant_id, connection_id, job, stream, from_at, to_at, started_at, finished_at, status, counts, error
  from cma.sync_run
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.connection_pipeline as
  select id, tenant_id, connection_id, record_type, source_pipeline_id, label, is_counted, is_routed,
         work_type_skill_id, status, refreshed_at, is_lead
  from cma.connection_pipeline
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.crm_contact as
  select id, tenant_id, connection_id, source_system, source_id, country, language,
         source_updated_at, source_deleted_at, synced_at, currency, store
  from cma.crm_contact
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.crm_contact_ref as
  select tenant_id, contact_id, system, external_id, synced_at, slot
  from cma.crm_contact_ref
  where cma_read.reader_sees(tenant_id);

-- The record's new columns sit in a companion view: 31_verify_ingest_crm_records.sql pins the exact
-- column list of cma_read.crm_record, and it must keep passing unchanged. Join on id.
create or replace view cma_read.crm_record_detail as
  select id, tenant_id, connection_id, record_type, source_id, amount, currency, source_channel, category
  from cma.crm_record
  where cma_read.reader_sees(tenant_id);

-- ---------------------------------------------------------------------------------------------
-- 13. Record the migration
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0007', 'Intake core: markets with aliases, office hours and holidays, business time, connection settings and slots, CRM calls, call outcomes, associations, forms and submissions, sync cursors and runs, contact forget, people''s ids in other systems')
on conflict (version) do nothing;

reset role;
