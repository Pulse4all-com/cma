-- =============================================================================================
-- 30_ingest_crm_records.sql: migration 0006, ingest and CRM records (speed-to-lead track S1)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 28_my_profile.sql (0005b). Rerunnable, forward-only. Run as your own IAM login, dev first, then
-- prod; then 31_verify_ingest_crm_records.sql, then 27_verify_configuration.sql again (adjusted
-- with this migration: a tenant now has two system users).
--
-- What it adds (README Roadmap step 6, speed-to-lead track S1; Decision log 9 October 2026)
--   connections        cma.integration_connection: one adapter instance per tenant and source
--                      account (the CRM portal), with an opaque key for its webhook address and the
--                      NAMES of its two secrets in Secret Manager (never the secrets)
--   field mapping      cma.connection_field: which source property feeds which canonical field
--                      (record: market, language; contact: country, language, ref per system), so
--                      another tenant or customer maps its own properties without a schema change
--   pipelines, stages  cma.connection_pipeline (counted, routed, work type) and cma.connection_stage
--                      (label, order, closed), refreshed from the source's pipeline definitions
--   the ingest log     cma.ingest_event: one row per received event, idempotent on the adapter's
--                      event key, the event as received (ids only), a processing state with
--                      attempts, backoff and needs_review after ingest.max_attempts
--   CRM records        cma.crm_record (deals and tickets: ids, pipeline, stage, owner, contact,
--                      market, language, open or closed, source times), cma.crm_contact (country,
--                      language) and cma.crm_contact_ref (the contact's id in other systems, for
--                      example the commerce system). A contact is held only while a record of the
--                      same connection points to it: the contact base is never mirrored
--   the ingest user    one Ingest system user per tenant (login system and id 'ingest') with the
--                      non-assignable role 'ingest' and the one permission ingest.write
--   the Dashboard read cma.crm_records_per_day(): records created per business date, type, market
--                      and pipeline, counted pipelines only, deleted records left out
--
-- The ingest API maps a vendor's payload to the canonical shapes below; nothing in the database
-- reads a vendor payload. Every write is guarded against an older read overwriting a newer one
-- (source updated time), so the order in which events arrive does not matter.
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
  if not exists (select 1 from cma.schema_migration where version = '0005b') then
    raise exception 'addition 0005b (28_my_profile.sql) must run before 0006';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Catalog rows: the permission and the setting
-- ---------------------------------------------------------------------------------------------
insert into cma.permission (key, description) values
  ('ingest.write', 'Write received events and synced records from connected systems (the ingest system user only; no default role)')
on conflict (key) do update set description = excluded.description;

insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('ingest.max_attempts', 'integer', null, '10',
     'Processing attempts for a received event before it is parked for review')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- ---------------------------------------------------------------------------------------------
-- 2. Connections and their mapping
-- ---------------------------------------------------------------------------------------------
-- One adapter instance per tenant and source account. The key is the last segment of the webhook
-- address: random, unique across tenants, not a secret (the request signature is the proof).
create table if not exists cma.integration_connection (
  id                   uuid primary key default uuidv7(),
  tenant_id            uuid not null default cma.current_tenant_id() references cma.tenant (id),
  key                  text not null default replace(gen_random_uuid()::text, '-', '')
                         check (key ~ '^[A-Za-z0-9_-]{24,64}$'),
  adapter              text not null check (adapter ~ '^[a-z0-9_]+$'),
  name                 text not null check (length(btrim(name)) between 1 and 80),
  external_account_id  text not null check (length(btrim(external_account_id)) between 1 and 100),
  signing_secret_name  text check (signing_secret_name ~ '^[A-Za-z0-9_-]{1,255}$'),
  token_secret_name    text check (token_secret_name ~ '^[A-Za-z0-9_-]{1,255}$'),
  status               text not null default 'active' check (status in ('active', 'inactive')),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (key),
  unique (tenant_id, id),
  unique (tenant_id, adapter, external_account_id)
);
comment on table cma.integration_connection is 'One adapter instance per tenant and source account (for example a CRM portal). Holds secret names, never secrets';
comment on column cma.integration_connection.adapter is 'Adapter type as a data value, for example the CRM vendor; the database never branches on it';
create or replace trigger set_updated_at before update on cma.integration_connection
  for each row execute function cma.set_updated_at();

-- Which source property feeds which canonical field. entity is the canonical record type (deal,
-- ticket, ...) or 'contact'. Records take market and language; contacts take country, language
-- and one ref per other system (ref_system, for example the commerce system's customer id).
create table if not exists cma.connection_field (
  tenant_id        uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id    uuid not null,
  entity           text not null check (entity ~ '^[a-z][a-z0-9_]*$'),
  field            text not null check (field in ('market', 'language', 'country', 'ref')),
  ref_system       text not null default '' check (ref_system ~ '^([a-z0-9_]+)?$'),
  source_property  text not null check (length(btrim(source_property)) between 1 and 100),
  updated_at       timestamptz not null default now(),
  primary key (tenant_id, connection_id, entity, field, ref_system),
  check ((field = 'ref') = (ref_system <> '')),
  check (case when entity = 'contact' then field in ('country', 'language', 'ref')
              else field in ('market', 'language') end),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.connection_field is 'Per connection: the source property behind each canonical field of a record or contact';
create or replace trigger set_updated_at before update on cma.connection_field
  for each row execute function cma.set_updated_at();

-- Pipelines of the source, per record type. is_counted leaves test pipelines out of reporting;
-- is_routed marks the pipelines the CMA assigns (S3); work_type_skill_id maps the pipeline to a
-- work type for routing (S2).
create table if not exists cma.connection_pipeline (
  id                  uuid primary key default uuidv7(),
  tenant_id           uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id       uuid not null,
  record_type         text not null check (record_type ~ '^[a-z][a-z0-9_]*$'),
  source_pipeline_id  text not null check (length(source_pipeline_id) between 1 and 100),
  label               text not null,
  is_counted          boolean not null default true,
  is_routed           boolean not null default false,
  work_type_skill_id  uuid,
  status              text not null default 'active' check (status in ('active', 'archived')),
  refreshed_at        timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, connection_id, record_type, source_pipeline_id),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id),
  foreign key (tenant_id, work_type_skill_id) references cma.skill (tenant_id, id)
);
comment on table cma.connection_pipeline is 'Source pipelines per connection and record type: counted in reporting, routed by the CMA, mapped to a work type';
create or replace trigger set_updated_at before update on cma.connection_pipeline
  for each row execute function cma.set_updated_at();

create table if not exists cma.connection_stage (
  tenant_id           uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id       uuid not null,
  record_type         text not null,
  source_pipeline_id  text not null,
  source_stage_id     text not null check (length(source_stage_id) between 1 and 100),
  label               text not null,
  display_order       integer not null default 0,
  is_closed           boolean not null,
  status              text not null default 'active' check (status in ('active', 'archived')),
  refreshed_at        timestamptz not null default now(),
  primary key (tenant_id, connection_id, record_type, source_pipeline_id, source_stage_id),
  foreign key (tenant_id, connection_id, record_type, source_pipeline_id)
    references cma.connection_pipeline (tenant_id, connection_id, record_type, source_pipeline_id)
);
comment on table cma.connection_stage is 'Stages of each source pipeline with the source''s own closed flag; refreshed from the source, never typed in';

-- ---------------------------------------------------------------------------------------------
-- 3. The ingest log
-- ---------------------------------------------------------------------------------------------
-- One row per event received. event_key is the adapter's idempotency key (a hash of the fields
-- that make the event unique at its source); a resend of the same event is ignored. raw is the
-- event as received, which for a change notification holds ids and timestamps only.
create table if not exists cma.ingest_event (
  id               uuid primary key default uuidv7(),
  tenant_id        uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id    uuid not null,
  event_key        text not null check (length(event_key) between 1 and 200),
  source_type      text not null check (length(source_type) between 1 and 100),
  kind             text not null check (kind in ('created', 'changed', 'deleted', 'merged', 'restored', 'associated')),
  object_type      text not null check (object_type ~ '^[a-z][a-z0-9_]*$'),
  object_id        text not null check (length(object_id) between 1 and 100),
  property_name    text,
  occurred_at      timestamptz not null,
  recorded_at      timestamptz not null default now(),
  delivery_attempt integer not null default 1,
  raw              jsonb not null default '{}'::jsonb,
  status           text not null default 'received'
                     check (status in ('received', 'processed', 'ignored', 'failed', 'needs_review')),
  attempts         integer not null default 0,
  next_attempt_at  timestamptz not null default now(),
  error            text check (length(error) <= 200),
  processed_at     timestamptz,
  unique (tenant_id, id),
  unique (tenant_id, connection_id, event_key),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.ingest_event is 'Every event received from a connected system, idempotent on the adapter''s event key, with its processing state';
create index if not exists ingest_event_due_idx on cma.ingest_event (tenant_id, connection_id, next_attempt_at)
  where status in ('received', 'failed');
create index if not exists ingest_event_object_idx on cma.ingest_event (tenant_id, connection_id, object_type, object_id);

-- ---------------------------------------------------------------------------------------------
-- 4. CRM records and contacts
-- ---------------------------------------------------------------------------------------------
-- Thin canonical records: ids and the few fields routing and reporting need, never names or
-- contact details. The CRM owns them; this is a mirror, updated only from what the CRM answers.
create table if not exists cma.crm_record (
  id                  uuid primary key default uuidv7(),
  tenant_id           uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id       uuid not null,
  source_system       text not null check (source_system ~ '^[a-z0-9_]+$'),
  record_type         text not null check (record_type ~ '^[a-z][a-z0-9_]*$'),
  source_id           text not null check (length(source_id) between 1 and 100),
  pipeline_id         text,
  stage_id            text,
  owner_ref           text,                 -- the source's owner id; mapped to a person through app_user_external_id
  contact_source_id   text,                 -- the associated contact's source id, null until associated
  market              text,
  language            text,
  is_closed           boolean,              -- from the stage's closed flag; null while the stage is unknown
  closed_at           timestamptz,
  source_created_at   timestamptz not null,
  source_updated_at   timestamptz,
  source_deleted_at   timestamptz,
  synced_at           timestamptz not null default now(),
  raw                 jsonb not null default '{}'::jsonb,
  unique (tenant_id, id),
  unique (tenant_id, connection_id, record_type, source_id),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.crm_record is 'Thin mirror of CRM records (deals, tickets): ids, pipeline, stage, owner, contact, market, language, open or closed. Owned by the CRM';
create index if not exists crm_record_created_idx on cma.crm_record (tenant_id, source_created_at);
create index if not exists crm_record_contact_idx on cma.crm_record (tenant_id, connection_id, contact_source_id);

create table if not exists cma.crm_contact (
  id                  uuid primary key default uuidv7(),
  tenant_id           uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id       uuid not null,
  source_system       text not null check (source_system ~ '^[a-z0-9_]+$'),
  source_id           text not null check (length(source_id) between 1 and 100),
  country             text,
  language            text,
  source_updated_at   timestamptz,
  source_deleted_at   timestamptz,
  synced_at           timestamptz not null default now(),
  raw                 jsonb not null default '{}'::jsonb,
  unique (tenant_id, id),
  unique (tenant_id, connection_id, source_id),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.crm_contact is 'Thin mirror of the contacts that CRM records point to: country and language only. A deleted contact keeps its id and loses its attributes';

create table if not exists cma.crm_contact_ref (
  tenant_id    uuid not null default cma.current_tenant_id() references cma.tenant (id),
  contact_id   uuid not null,
  system       text not null check (system ~ '^[a-z0-9_]+$'),
  external_id  text not null check (length(external_id) between 1 and 100),
  synced_at    timestamptz not null default now(),
  primary key (tenant_id, contact_id, system),
  foreign key (tenant_id, contact_id) references cma.crm_contact (tenant_id, id) on delete cascade
);
comment on table cma.crm_contact_ref is 'The id of a CRM contact in another system (for example the commerce system''s customer id), as the CRM holds it';
create index if not exists crm_contact_ref_external_idx on cma.crm_contact_ref (tenant_id, system, external_id);

select cma.setup_tenant_table('cma.integration_connection');
select cma.setup_tenant_table('cma.connection_field');
select cma.setup_tenant_table('cma.connection_pipeline');
select cma.setup_tenant_table('cma.connection_stage');
select cma.setup_tenant_table('cma.ingest_event');
select cma.setup_tenant_table('cma.crm_record');
select cma.setup_tenant_table('cma.crm_contact');
select cma.setup_tenant_table('cma.crm_contact_ref');

-- The application writes these tables through the functions below only, and never deletes
-- (connection_field rows are removed by set_connection_field; contact refs by the contact write).
revoke delete on cma.integration_connection, cma.connection_pipeline, cma.connection_stage,
                 cma.ingest_event, cma.crm_record, cma.crm_contact from cma_app;

-- ---------------------------------------------------------------------------------------------
-- 5. The ingest system user
-- ---------------------------------------------------------------------------------------------
-- As the scheduler (0005a): one system user per tenant, so every write the ingest API makes is
-- audited under a named acting user. The login id ('ingest', 'ingest') is the same in every tenant,
-- which is how the sweeper finds the tenants it serves (find_tenants_for_identity).
create or replace function cma.ensure_ingest_user(p_tenant_id uuid)
returns uuid
language plpgsql
as $$
declare
  v_role uuid;
  v_user uuid;
begin
  insert into cma.app_role (tenant_id, key, name, is_system, is_assignable)
  values (p_tenant_id, 'ingest', 'Ingest', true, false)
  on conflict (tenant_id, key) do update set is_assignable = false, is_system = true
  returning id into v_role;
  insert into cma.role_permission (tenant_id, role_id, permission_key)
  values (p_tenant_id, v_role, 'ingest.write')
  on conflict do nothing;

  insert into cma.app_user (tenant_id, email, display_name, status, kind)
  values (p_tenant_id, 'ingest@system.invalid', 'Ingest', 'active', 'system')
  on conflict (tenant_id, email) do update set kind = 'system', status = 'active'
  returning id into v_user;
  insert into cma.user_role (tenant_id, user_id, role_id)
  values (p_tenant_id, v_user, v_role)
  on conflict do nothing;
  insert into cma.app_user_external_id (tenant_id, user_id, system, external_id)
  values (p_tenant_id, v_user, 'ingest', 'ingest')
  on conflict do nothing;
  return v_user;
end
$$;
revoke execute on function cma.ensure_ingest_user(uuid) from public;

-- create_tenant as in 0005a, plus the ingest user
create or replace function cma.create_tenant(p_slug text, p_name text, p_timezone text default 'UTC')
returns uuid
language plpgsql
as $$
declare
  v_id uuid;
begin
  insert into cma.tenant (slug, name, timezone)
  values (p_slug, p_name, p_timezone)
  on conflict (slug) do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id from cma.tenant where slug = p_slug;
  end if;

  perform cma.seed_default_roles(v_id);
  perform cma.seed_default_work_statuses(v_id);
  perform cma.seed_default_skill_levels(v_id);
  perform cma.seed_default_absence_types(v_id);
  perform cma.ensure_scheduler_user(v_id);
  perform cma.ensure_ingest_user(v_id);
  return v_id;
end
$$;
revoke execute on function cma.create_tenant(text, text, text) from public;

do $$
declare
  t record;
begin
  for t in select id from cma.tenant loop
    perform cma.ensure_ingest_user(t.id);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. Internal helpers
-- ---------------------------------------------------------------------------------------------
-- The connection of the current tenant, active; CMA02 otherwise. Returns the adapter, which is
-- copied into source_system on every record.
create or replace function cma.active_connection_adapter(p_connection_id uuid)
returns text
language plpgsql stable
as $$
declare
  v_adapter text;
begin
  select c.adapter into v_adapter
  from cma.integration_connection c
  where c.tenant_id = cma.current_tenant_id() and c.id = p_connection_id and c.status = 'active';
  if v_adapter is null then
    raise exception 'no active connection % in the current tenant', p_connection_id using errcode = 'CMA02';
  end if;
  return v_adapter;
end
$$;
revoke execute on function cma.active_connection_adapter(uuid) from public;
grant execute on function cma.active_connection_adapter(uuid) to cma_app;

-- Parses an ISO 8601 text into timestamptz; null stays null, anything else is CMA04
create or replace function cma.json_time(p_value jsonb, p_what text)
returns timestamptz
language plpgsql immutable
as $$
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    return null;
  end if;
  if jsonb_typeof(p_value) <> 'string' or (p_value #>> '{}') !~ '^\d{4}-\d{2}-\d{2}T' then
    raise exception '% must be an ISO 8601 time, got %', p_what, p_value using errcode = 'CMA04';
  end if;
  return (p_value #>> '{}')::timestamptz;
exception when invalid_datetime_format or datetime_field_overflow then
  raise exception '% must be an ISO 8601 time, got %', p_what, p_value using errcode = 'CMA04';
end
$$;
revoke execute on function cma.json_time(jsonb, text) from public;
grant execute on function cma.json_time(jsonb, text) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 7. Finding the connection before the tenant is known
-- ---------------------------------------------------------------------------------------------
-- The ingest API's first call for a request: the key from the address gives the tenant, the
-- connection and the names of its secrets. SECURITY DEFINER like find_tenants_for_identity, owned
-- by cma_owner; an inactive connection, tenant or ingest user gives no row.
create or replace function cma.ingest_connection(p_key text)
returns table (
  tenant_id            uuid,
  connection_id        uuid,
  adapter              text,
  external_account_id  text,
  signing_secret_name  text,
  token_secret_name    text,
  ingest_user_id       uuid
)
language sql stable security definer
set search_path = pg_catalog, cma
as $$
  select c.tenant_id, c.id, c.adapter, c.external_account_id, c.signing_secret_name, c.token_secret_name, u.id
  from cma.integration_connection c
  join cma.tenant t on t.id = c.tenant_id
  join cma.app_user_external_id x on x.tenant_id = c.tenant_id and x.system = 'ingest' and x.external_id = 'ingest'
  join cma.app_user u on u.tenant_id = x.tenant_id and u.id = x.user_id
  where c.key = p_key
    and c.status = 'active'
    and t.status = 'active'
    and u.status = 'active'
$$;
revoke execute on function cma.ingest_connection(text) from public;
grant  execute on function cma.ingest_connection(text) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 8. The ingest write path (ingest.write)
-- ---------------------------------------------------------------------------------------------
-- Records a batch of canonical events: [{key, sourceType, kind, objectType, objectId,
-- propertyName?, occurredAt, attempt?, raw?}], at most 500. A known key is not written again.
-- Answers every key with its event id, whether it was new, and its current status.
create or replace function cma.ingest_record_events(p_connection_id uuid, p_events jsonb)
returns table (event_id uuid, event_key text, is_new boolean, status text)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant uuid := cma.current_tenant_id();
  e        jsonb;
  v_id     uuid;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  if p_events is null or jsonb_typeof(p_events) <> 'array' or jsonb_array_length(p_events) > 500 then
    raise exception 'events must be an array of at most 500' using errcode = 'CMA04';
  end if;
  for e in select value from jsonb_array_elements(p_events) loop
    if coalesce(e ->> 'key', '') = '' or coalesce(e ->> 'objectId', '') = '' or coalesce(e ->> 'sourceType', '') = '' then
      raise exception 'every event needs key, sourceType and objectId' using errcode = 'CMA04';
    end if;
    v_id := null;
    insert into cma.ingest_event (tenant_id, connection_id, event_key, source_type, kind, object_type, object_id,
                                  property_name, occurred_at, delivery_attempt, raw)
    values (v_tenant, p_connection_id, e ->> 'key', e ->> 'sourceType', e ->> 'kind', e ->> 'objectType', e ->> 'objectId',
            nullif(e ->> 'propertyName', ''),
            coalesce(cma.json_time(e -> 'occurredAt', 'occurredAt'), now()),
            coalesce((e ->> 'attempt')::integer, 1),
            coalesce(e -> 'raw', '{}'::jsonb))
    on conflict (tenant_id, connection_id, event_key) do nothing
    returning id into v_id;
    if v_id is not null then
      return query select v_id, e ->> 'key', true, 'received'::text;
    else
      return query select ie.id, ie.event_key, false, ie.status
                   from cma.ingest_event ie
                   where ie.tenant_id = v_tenant and ie.connection_id = p_connection_id and ie.event_key = e ->> 'key';
    end if;
  end loop;
exception
  when check_violation or not_null_violation or invalid_text_representation then
    raise exception 'invalid event: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- Claims events that are due (received, or failed with the backoff passed), at most p_limit, or
-- exactly the given ids when they are due. A claim counts an attempt and moves next_attempt_at
-- forward (1, 2, 4, ... minutes, at most 60), so an event whose worker dies is picked up again
-- later. SKIP LOCKED: two workers never claim the same event.
create or replace function cma.ingest_claim_events(p_connection_id uuid, p_ids uuid[] default null, p_limit integer default 100)
returns table (event_id uuid, kind text, object_type text, object_id text, property_name text, attempts integer)
language plpgsql
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  if p_limit is null or p_limit < 1 or p_limit > 500 then
    raise exception 'limit must be between 1 and 500' using errcode = 'CMA04';
  end if;
  return query
    with due as (
      select ie.id
      from cma.ingest_event ie
      where ie.tenant_id = cma.current_tenant_id()
        and ie.connection_id = p_connection_id
        and ie.status in ('received', 'failed')
        and ie.next_attempt_at <= now()
        and (p_ids is null or ie.id = any (p_ids))
      order by ie.next_attempt_at, ie.id
      limit p_limit
      for update skip locked
    )
    update cma.ingest_event ie
       set attempts = ie.attempts + 1,
           next_attempt_at = now() + make_interval(mins => least(power(2, ie.attempts)::integer, 60))
      from due
     where ie.tenant_id = cma.current_tenant_id() and ie.id = due.id
    returning ie.id, ie.kind, ie.object_type, ie.object_id, ie.property_name, ie.attempts;
end
$$;

-- Finishes claimed events: processed, ignored (nothing to do, for example a contact we do not
-- hold), or failed with a short error code. A failure at ingest.max_attempts parks the event as
-- needs_review. Only events still open (received or failed) change; answers how many did.
create or replace function cma.ingest_finish_events(p_connection_id uuid, p_ids uuid[], p_outcome text, p_error text default null)
returns integer
language plpgsql
as $$
declare
  v_max integer;
  v_n   integer;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  if p_outcome not in ('processed', 'ignored', 'failed') then
    raise exception 'outcome must be processed, ignored or failed' using errcode = 'CMA04';
  end if;
  if p_outcome = 'failed' and coalesce(btrim(p_error), '') = '' then
    raise exception 'a failure needs an error code' using errcode = 'CMA04';
  end if;
  select s.value::integer into v_max from cma.tenant_settings() s where s.key = 'ingest.max_attempts';
  update cma.ingest_event ie
     set status = case when p_outcome = 'failed' and ie.attempts >= v_max then 'needs_review' else p_outcome end,
         error = case when p_outcome = 'failed' then left(p_error, 200) end,
         processed_at = case when p_outcome = 'failed' then null else now() end
   where ie.tenant_id = cma.current_tenant_id()
     and ie.connection_id = p_connection_id
     and ie.id = any (coalesce(p_ids, '{}'))
     and ie.status in ('received', 'failed');
  get diagnostics v_n = row_count;
  return v_n;
end
$$;

-- Upserts records as the source answered them: [{recordType, sourceId, pipelineId, stageId,
-- ownerRef, contactId, market, language, createdAt, updatedAt, closedAt?, deletedAt?, raw?}], at
-- most 500. A read older than the one held is ignored (stale). A record with deletedAt only marks
-- the record deleted (unknown when never held). is_closed comes from the stage; closed_at is the
-- source's close time when given, else the first time the CMA saw the record closed.
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
                                  source_created_at, source_updated_at, raw)
      values (v_tenant, p_connection_id, v_system, v_type, v_src, nullif(r ->> 'pipelineId', ''), nullif(r ->> 'stageId', ''),
              nullif(r ->> 'ownerRef', ''), nullif(r ->> 'contactId', ''), nullif(btrim(r ->> 'market'), ''),
              nullif(btrim(r ->> 'language'), ''), v_closed,
              case when v_closed then coalesce(cma.json_time(r -> 'closedAt', 'closedAt'), now()) end,
              coalesce(cma.json_time(r -> 'createdAt', 'createdAt'), now()), v_updated, coalesce(r -> 'raw', '{}'::jsonb))
      returning id into v_new_id;
      return query select v_type, v_src, 'inserted'::text, v_closed;
    else
      update cma.crm_record cr
         set pipeline_id = nullif(r ->> 'pipelineId', ''),
             stage_id = nullif(r ->> 'stageId', ''),
             owner_ref = nullif(r ->> 'ownerRef', ''),
             contact_source_id = coalesce(nullif(r ->> 'contactId', ''), cr.contact_source_id),
             market = nullif(btrim(r ->> 'market'), ''),
             language = nullif(btrim(r ->> 'language'), ''),
             is_closed = v_closed,
             closed_at = case when v_closed then coalesce(cma.json_time(r -> 'closedAt', 'closedAt'),
                                                          case when cr.is_closed then cr.closed_at end, now()) end,
             source_created_at = coalesce(cma.json_time(r -> 'createdAt', 'createdAt'), cr.source_created_at),
             source_updated_at = v_updated,
             source_deleted_at = null,
             synced_at = now(),
             raw = coalesce(r -> 'raw', '{}'::jsonb)
       where cr.tenant_id = v_tenant and cr.id = v_old.id;
      return query select v_type, v_src, 'updated'::text, v_closed;
    end if;
  end loop;
end
$$;

-- Upserts contacts: [{sourceId, country, language, refs: {system: id|null}, updatedAt, deletedAt?,
-- raw?}], at most 500. Only a contact a record of the same connection points to is taken in
-- (not_held otherwise), so the contact base is never mirrored. Older reads are stale. A deleted
-- contact keeps its id and loses country, language, refs and raw.
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
           set country = null, language = null, raw = '{}'::jsonb, source_deleted_at = v_deleted, synced_at = now()
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

    if v_old.id is null then
      insert into cma.crm_contact (tenant_id, connection_id, source_system, source_id, country, language, source_updated_at, raw)
      values (v_tenant, p_connection_id, v_system, v_src, nullif(btrim(c ->> 'country'), ''), nullif(btrim(c ->> 'language'), ''),
              v_updated, coalesce(c -> 'raw', '{}'::jsonb))
      returning id into v_id;
    else
      v_id := v_old.id;
      update cma.crm_contact cc
         set country = nullif(btrim(c ->> 'country'), ''), language = nullif(btrim(c ->> 'language'), ''),
             source_updated_at = v_updated, source_deleted_at = null, synced_at = now(),
             raw = coalesce(c -> 'raw', '{}'::jsonb)
       where cc.tenant_id = v_tenant and cc.id = v_id;
    end if;

    for k, v in select key, value from jsonb_each(coalesce(c -> 'refs', '{}'::jsonb)) loop
      if k !~ '^[a-z0-9_]+$' then
        raise exception 'ref system % must be lowercase letters, digits or underscores', k using errcode = 'CMA04';
      end if;
      if jsonb_typeof(v) = 'null' or btrim(v #>> '{}') = '' then
        delete from cma.crm_contact_ref cr where cr.tenant_id = v_tenant and cr.contact_id = v_id and cr.system = k;
      else
        insert into cma.crm_contact_ref (tenant_id, contact_id, system, external_id)
        values (v_tenant, v_id, k, btrim(v #>> '{}'))
        on conflict (tenant_id, contact_id, system)
          do update set external_id = excluded.external_id, synced_at = now()
          where cma.crm_contact_ref.external_id is distinct from excluded.external_id;
      end if;
    end loop;
    return query select v_src, case when v_old.id is null then 'inserted' else 'updated' end;
  end loop;
end
$$;

-- Refreshes pipelines and stages from the source: [{recordType, pipelineId, label, stages:
-- [{stageId, label, order, isClosed}]}]. Settings on a pipeline (counted, routed, work type) stay;
-- a stage missing from its pipeline's list is archived. Records of this connection then take their
-- stage's closed flag. Answers the number of records whose closed flag changed.
create or replace function cma.ingest_upsert_pipelines(p_connection_id uuid, p_pipelines jsonb)
returns integer
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  p        jsonb;
  s        jsonb;
  v_n      integer;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  if p_pipelines is null or jsonb_typeof(p_pipelines) <> 'array' then
    raise exception 'pipelines must be an array' using errcode = 'CMA04';
  end if;
  for p in select value from jsonb_array_elements(p_pipelines) loop
    if coalesce(p ->> 'recordType', '') !~ '^[a-z][a-z0-9_]*$' or coalesce(p ->> 'pipelineId', '') = ''
       or jsonb_typeof(p -> 'stages') is distinct from 'array' then
      raise exception 'every pipeline needs recordType, pipelineId and a stages array' using errcode = 'CMA04';
    end if;
    insert into cma.connection_pipeline (tenant_id, connection_id, record_type, source_pipeline_id, label, status, refreshed_at)
    values (v_tenant, p_connection_id, p ->> 'recordType', p ->> 'pipelineId',
            coalesce(nullif(btrim(p ->> 'label'), ''), p ->> 'pipelineId'), 'active', now())
    on conflict (tenant_id, connection_id, record_type, source_pipeline_id)
      do update set label = excluded.label, status = 'active', refreshed_at = now();
    for s in select value from jsonb_array_elements(p -> 'stages') loop
      if coalesce(s ->> 'stageId', '') = '' or jsonb_typeof(s -> 'isClosed') is distinct from 'boolean' then
        raise exception 'every stage needs stageId and isClosed' using errcode = 'CMA04';
      end if;
      insert into cma.connection_stage (tenant_id, connection_id, record_type, source_pipeline_id, source_stage_id,
                                        label, display_order, is_closed, status, refreshed_at)
      values (v_tenant, p_connection_id, p ->> 'recordType', p ->> 'pipelineId', s ->> 'stageId',
              coalesce(nullif(btrim(s ->> 'label'), ''), s ->> 'stageId'), coalesce((s ->> 'order')::integer, 0),
              (s ->> 'isClosed')::boolean, 'active', now())
      on conflict (tenant_id, connection_id, record_type, source_pipeline_id, source_stage_id)
        do update set label = excluded.label, display_order = excluded.display_order,
                      is_closed = excluded.is_closed, status = 'active', refreshed_at = now();
    end loop;
    update cma.connection_stage cs
       set status = 'archived'
     where cs.tenant_id = v_tenant and cs.connection_id = p_connection_id
       and cs.record_type = p ->> 'recordType' and cs.source_pipeline_id = p ->> 'pipelineId'
       and cs.status = 'active'
       and not exists (select 1 from jsonb_array_elements(p -> 'stages') x where x ->> 'stageId' = cs.source_stage_id);
  end loop;

  update cma.crm_record cr
     set is_closed = cs.is_closed,
         closed_at = case when cs.is_closed then coalesce(cr.closed_at, now()) end
    from cma.connection_stage cs
   where cr.tenant_id = v_tenant and cr.connection_id = p_connection_id
     and cs.tenant_id = cr.tenant_id and cs.connection_id = cr.connection_id and cs.record_type = cr.record_type
     and cs.source_pipeline_id = cr.pipeline_id and cs.source_stage_id = cr.stage_id
     and cr.is_closed is distinct from cs.is_closed;
  get diagnostics v_n = row_count;
  return v_n;
end
$$;

-- Records still without a contact, created within p_max_age: the sweeper reads them again, because
-- the source may associate the contact after the record was created.
create or replace function cma.ingest_records_without_contact(p_connection_id uuid, p_max_age interval default interval '1 hour')
returns table (record_type text, source_id text)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  return query
    select cr.record_type, cr.source_id
    from cma.crm_record cr
    where cr.tenant_id = cma.current_tenant_id() and cr.connection_id = p_connection_id
      and cr.contact_source_id is null and cr.source_deleted_at is null
      and cr.source_created_at > now() - p_max_age
    order by cr.source_created_at
    limit 500;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 9. Configuration (tenant.configure) and the mapping read
-- ---------------------------------------------------------------------------------------------
-- Adds or updates a connection, identified by adapter and account; answers its id and key.
create or replace function cma.upsert_connection(p_adapter text, p_name text, p_external_account_id text,
                                                 p_signing_secret_name text, p_token_secret_name text)
returns table (connection_id uuid, key text)
language plpgsql
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('tenant.configure');
  return query
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, signing_secret_name, token_secret_name)
    values (cma.current_tenant_id(), p_adapter, btrim(p_name), btrim(p_external_account_id),
            nullif(btrim(p_signing_secret_name), ''), nullif(btrim(p_token_secret_name), ''))
    on conflict (tenant_id, adapter, external_account_id)
      do update set name = excluded.name, signing_secret_name = excluded.signing_secret_name,
                    token_secret_name = excluded.token_secret_name
    returning id, integration_connection.key;
exception when check_violation or not_null_violation then
  raise exception 'invalid connection: %', sqlerrm using errcode = 'CMA04';
end
$$;

create or replace function cma.set_connection_status(p_connection_id uuid, p_status text)
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
  if p_status not in ('active', 'inactive') then
    raise exception 'status must be active or inactive' using errcode = 'CMA04';
  end if;
  update cma.integration_connection c set status = p_status
  where c.tenant_id = cma.current_tenant_id() and c.id = p_connection_id;
  if not found then
    raise exception 'no connection % in the current tenant', p_connection_id using errcode = 'CMA02';
  end if;
end
$$;

-- Sets the source property behind one canonical field; an empty property removes the mapping.
create or replace function cma.set_connection_field(p_connection_id uuid, p_entity text, p_field text,
                                                    p_ref_system text, p_source_property text)
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
  if not exists (select 1 from cma.integration_connection c
                 where c.tenant_id = cma.current_tenant_id() and c.id = p_connection_id) then
    raise exception 'no connection % in the current tenant', p_connection_id using errcode = 'CMA02';
  end if;
  if coalesce(btrim(p_source_property), '') = '' then
    delete from cma.connection_field f
    where f.tenant_id = cma.current_tenant_id() and f.connection_id = p_connection_id
      and f.entity = p_entity and f.field = p_field and f.ref_system = coalesce(p_ref_system, '');
    return;
  end if;
  insert into cma.connection_field (tenant_id, connection_id, entity, field, ref_system, source_property)
  values (cma.current_tenant_id(), p_connection_id, p_entity, p_field, coalesce(p_ref_system, ''), btrim(p_source_property))
  on conflict (tenant_id, connection_id, entity, field, ref_system)
    do update set source_property = excluded.source_property;
exception when check_violation or not_null_violation then
  raise exception 'invalid field mapping (%, %, %): %', p_entity, p_field, p_ref_system, sqlerrm using errcode = 'CMA04';
end
$$;

-- Counted, routed and the work type of one pipeline. A pipeline not yet refreshed from the
-- source is added with its id as label. The work type is a skill key of dimension work_type.
create or replace function cma.set_connection_pipeline(p_connection_id uuid, p_record_type text, p_pipeline_id text,
                                                       p_is_counted boolean, p_is_routed boolean, p_work_type_key text)
returns void
language plpgsql
as $$
declare
  v_skill uuid;
begin
  perform cma.assert_permission('tenant.configure');
  if not exists (select 1 from cma.integration_connection c
                 where c.tenant_id = cma.current_tenant_id() and c.id = p_connection_id) then
    raise exception 'no connection % in the current tenant', p_connection_id using errcode = 'CMA02';
  end if;
  if p_is_counted is null or p_is_routed is null then
    raise exception 'counted and routed must be true or false' using errcode = 'CMA04';
  end if;
  if coalesce(p_work_type_key, '') <> '' then
    select s.id into v_skill from cma.skill s
    where s.tenant_id = cma.current_tenant_id() and s.dimension = 'work_type' and s.key = p_work_type_key and s.status = 'active';
    if v_skill is null then
      raise exception 'no active work type %', p_work_type_key using errcode = 'CMA02';
    end if;
  end if;
  insert into cma.connection_pipeline (tenant_id, connection_id, record_type, source_pipeline_id, label,
                                       is_counted, is_routed, work_type_skill_id)
  values (cma.current_tenant_id(), p_connection_id, p_record_type, p_pipeline_id, p_pipeline_id,
          p_is_counted, p_is_routed, v_skill)
  on conflict (tenant_id, connection_id, record_type, source_pipeline_id)
    do update set is_counted = excluded.is_counted, is_routed = excluded.is_routed,
                  work_type_skill_id = excluded.work_type_skill_id;
exception when check_violation or not_null_violation then
  raise exception 'invalid pipeline: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- The mapping the adapter needs for one connection, for the ingest user or a configuring person:
-- {fields: [{entity, field, refSystem, property}], pipelines: [{recordType, pipelineId, label,
-- isCounted, isRouted, workType}]}
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
                                                             'refSystem', nullif(f.ref_system, ''), 'property', f.source_property)
                                         order by f.entity, f.field, f.ref_system)
                        from cma.connection_field f where f.tenant_id = v_tenant and f.connection_id = p_connection_id), '[]'::jsonb),
    'pipelines', coalesce((select jsonb_agg(jsonb_build_object('recordType', p.record_type, 'pipelineId', p.source_pipeline_id,
                                                                'label', p.label, 'isCounted', p.is_counted, 'isRouted', p.is_routed,
                                                                'workType', s.key, 'status', p.status)
                                            order by p.record_type, p.label, p.source_pipeline_id)
                           from cma.connection_pipeline p
                           left join cma.skill s on s.tenant_id = p.tenant_id and s.id = p.work_type_skill_id
                           where p.tenant_id = v_tenant and p.connection_id = p_connection_id), '[]'::jsonb));
end
$$;

-- Every connection of the tenant with its health, for the configuration screen and the morning
-- check: events in the last 24 hours, events waiting, events parked for review, the last event.
create or replace function cma.connections_all()
returns table (
  connection_id        uuid,
  key                  text,
  adapter              text,
  name                 text,
  external_account_id  text,
  signing_secret_name  text,
  token_secret_name    text,
  status               text,
  events_24h           integer,
  events_waiting       integer,
  events_needs_review  integer,
  last_event_at        timestamptz
)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('tenant.configure');
  return query
    select c.id, c.key, c.adapter, c.name, c.external_account_id, c.signing_secret_name, c.token_secret_name, c.status,
           (select count(*)::integer from cma.ingest_event e where e.tenant_id = c.tenant_id and e.connection_id = c.id and e.recorded_at > now() - interval '24 hours'),
           (select count(*)::integer from cma.ingest_event e where e.tenant_id = c.tenant_id and e.connection_id = c.id and e.status in ('received', 'failed')),
           (select count(*)::integer from cma.ingest_event e where e.tenant_id = c.tenant_id and e.connection_id = c.id and e.status = 'needs_review'),
           (select max(e.recorded_at) from cma.ingest_event e where e.tenant_id = c.tenant_id and e.connection_id = c.id)
    from cma.integration_connection c
    where c.tenant_id = cma.current_tenant_id()
    order by c.name, c.id;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 10. The Dashboard read (performance.team)
-- ---------------------------------------------------------------------------------------------
-- Records created per business date (the tenant's zone), record type, market and pipeline.
-- Counted pipelines only (a pipeline the CMA has not seen yet counts); deleted records left out;
-- a record without a market has market null, which the screen shows as "No market".
create or replace function cma.crm_records_per_day(p_from date, p_to date)
returns table (
  business_date   date,
  record_type     text,
  market          text,
  pipeline_id     text,
  pipeline_label  text,
  records         integer,
  closed_now      integer
)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_zone text;
begin
  perform cma.assert_permission('performance.team');
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 91 then
    raise exception 'the range must run forward and cover at most 92 days' using errcode = 'CMA04';
  end if;
  select t.timezone into v_zone from cma.tenant t where t.id = cma.current_tenant_id();
  return query
    select (cr.source_created_at at time zone v_zone)::date, cr.record_type, cr.market, cr.pipeline_id,
           coalesce(p.label, cr.pipeline_id), count(*)::integer, (count(*) filter (where cr.is_closed))::integer
    from cma.crm_record cr
    left join cma.connection_pipeline p
      on p.tenant_id = cr.tenant_id and p.connection_id = cr.connection_id
     and p.record_type = cr.record_type and p.source_pipeline_id = cr.pipeline_id
    where cr.tenant_id = cma.current_tenant_id()
      and cr.source_deleted_at is null
      and coalesce(p.is_counted, true)
      and cr.source_created_at >= (p_from::timestamp at time zone v_zone)
      and cr.source_created_at <  ((p_to + 1)::timestamp at time zone v_zone)
    group by 1, 2, 3, 4, 5
    order by 1, 2, 3 nulls last, 5;
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
    'cma.ingest_record_events(uuid,jsonb)',
    'cma.ingest_claim_events(uuid,uuid[],integer)',
    'cma.ingest_finish_events(uuid,uuid[],text,text)',
    'cma.ingest_upsert_records(uuid,jsonb)',
    'cma.ingest_upsert_contacts(uuid,jsonb)',
    'cma.ingest_upsert_pipelines(uuid,jsonb)',
    'cma.ingest_records_without_contact(uuid,interval)',
    'cma.upsert_connection(text,text,text,text,text)',
    'cma.set_connection_status(uuid,text)',
    'cma.set_connection_field(uuid,text,text,text,text)',
    'cma.set_connection_pipeline(uuid,text,text,boolean,boolean,text)',
    'cma.connection_config(uuid)',
    'cma.connections_all()',
    'cma.crm_records_per_day(date,date)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 12. Reporting views (no raw payloads, no secret names)
-- ---------------------------------------------------------------------------------------------
create or replace view cma_read.integration_connection as
  select id, tenant_id, adapter, name, external_account_id, status, created_at, updated_at
  from cma.integration_connection
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.connection_pipeline as
  select id, tenant_id, connection_id, record_type, source_pipeline_id, label, is_counted, is_routed,
         work_type_skill_id, status, refreshed_at
  from cma.connection_pipeline
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.connection_stage as
  select tenant_id, connection_id, record_type, source_pipeline_id, source_stage_id, label, display_order,
         is_closed, status, refreshed_at
  from cma.connection_stage
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.ingest_event as
  select id, tenant_id, connection_id, source_type, kind, object_type, object_id, property_name,
         occurred_at, recorded_at, delivery_attempt, status, attempts, error, processed_at
  from cma.ingest_event
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.crm_record as
  select id, tenant_id, connection_id, source_system, record_type, source_id, pipeline_id, stage_id, owner_ref,
         contact_source_id, market, language, is_closed, closed_at, source_created_at, source_updated_at,
         source_deleted_at, synced_at
  from cma.crm_record
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.crm_contact as
  select id, tenant_id, connection_id, source_system, source_id, country, language,
         source_updated_at, source_deleted_at, synced_at
  from cma.crm_contact
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.crm_contact_ref as
  select tenant_id, contact_id, system, external_id, synced_at
  from cma.crm_contact_ref
  where cma_read.reader_sees(tenant_id);

-- ---------------------------------------------------------------------------------------------
-- 13. Record the migration
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0006', 'Ingest and CRM records: connections with field mapping, pipelines and stages, the ingest log, thin CRM records and contacts with refs, the Ingest system user, crm_records_per_day')
on conflict (version) do nothing;

reset role;
