-- CMA migration 0001: foundation
-- Run as yourself (IAM login), after 00_roles.sql. Safe to rerun. Universal: this file holds no
-- customer, tenant or vendor specifics and runs unchanged in every customer database (dev, prod,
-- later every customer). Customer configuration follows in 02_seed_<customer>.sql, dev test data
-- in 03_seed_dev_test_data.sql.
--
-- The first statement switches to cma_owner so every object is owned by the shared owner role,
-- not by your personal login. Keep this line at the top of every migration script.
--
-- Conventions for this and every later migration
--   tenant     every tenant-scoped table has tenant_id (default: current tenant), composite foreign
--              keys on (tenant_id, id), and is registered with cma.setup_tenant_table(): RLS,
--              grants and audit trigger in one call
--   context    the application sets app.tenant_id and app.user_id once per transaction; the
--              ingest API sets only the tenant (system actor). Unset means fail closed
--   history    every insert, update and delete on a tenant-scoped table lands in cma.audit_log
--              with actor and timestamp. Facts such as time entries, lead assignments and
--              notifications are append-only, with occurred_at (when it happened) and
--              recorded_at (when we wrote it); a correction is a new row with reason and approver
--   time       timestamptz everywhere; the business day is derived from the configured time zone
--   validity   facts that affect pay, billing or reporting over time (employment, team
--              membership, skills, rates, targets) carry valid_from and valid_to, never overwritten
--   catalogs   configurable lists carry semantic flags (paid, billable, synchronous), never names only
--   channels   customer contact channels (phone, email, sms, whatsapp, chat, ...) are tenant
--              configuration in cma.channel; nothing assumes phone
--   mirrors    synced data carries source_system, source_id and synced_at; ingest is idempotent on them
--   reporting  readers (BigQuery, NocoDB, analytics) use the views in schema cma_read and never the
--              base tables; a table that reporting needs gets its view there in the same
--              migration, with its columns listed explicitly
--   actors     writes arrive as technical database users (ingest API, later other tools), so
--              attribution comes from the application: app.user_id for a CMA user, app.actor_label
--              for a process ("ingest-api:hubspot"); the database user is recorded as well
--   ids        uuidv7() primary keys; status columns instead of hard deletes
--   login      every script runs under a personal IAM login (guard below); postgres only for a
--              declared emergency, so audit rows always name a person
--   neutral    system names (hubspot, aircall, zoho, ...) appear only as data values, never in
--              table, column, function, role or constraint names; tenants, organisations and
--              channels are customer configuration and live in seed scripts, not in migrations
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

-- ---------------------------------------------------------------------------------------------
-- 1. Schema and default privileges
-- ---------------------------------------------------------------------------------------------
create schema if not exists cma authorization cma_owner;
comment on schema cma is 'Callcenter-Management-App operational data. Separation per tenant by tenant_id and row-level security';

grant usage on schema cma to cma_app;
-- cma_readonly gets nothing here on purpose: readers use the views in cma_read (section 8)

-- Applies to every table cma_owner creates from here on, so this must come before the tables.
-- Default is read-only for the application; cma.setup_tenant_table() adds write rights per
-- tenant-scoped table. Catalog tables therefore stay read-only for the app without extra work.
alter default privileges in schema cma grant select on tables to cma_app;
alter default privileges in schema cma grant usage, select on sequences to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 2. Transaction context and small helpers
-- ---------------------------------------------------------------------------------------------

-- Tenant of the current transaction. The application sets it once per transaction:
--   begin;
--   select set_config('app.tenant_id', $1, true);   -- true = transaction-scoped, resets on commit
--   select set_config('app.user_id',   $2, true);   -- the CMA user acting; omit for system processes
--   ... queries ...
--   commit;
-- Unset or empty means NULL, so every policy matches nothing and every insert fails: fail closed.
create or replace function cma.current_tenant_id()
returns uuid
language sql stable parallel safe
as $$
  select nullif(current_setting('app.tenant_id', true), '')::uuid
$$;

-- User of the current transaction. NULL for system processes such as the ingest API.
-- Used for the audit trail now, and later for policies of the kind "own rows" or "own team".
create or replace function cma.current_user_id()
returns uuid
language sql stable parallel safe
as $$
  select nullif(current_setting('app.user_id', true), '')::uuid
$$;

-- Label of the process acting when there is no CMA user, for example 'ingest-api:hubspot' or
-- 'make:aircall-sync'. Set with set_config('app.actor_label', $1, true).
create or replace function cma.current_actor_label()
returns text
language sql stable parallel safe
as $$
  select nullif(current_setting('app.actor_label', true), '')
$$;

create or replace function cma.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. Core tables: migrations, tenants, audit log
-- ---------------------------------------------------------------------------------------------

create table if not exists cma.schema_migration (
  version      text primary key,
  description  text not null,
  applied_at   timestamptz not null default now(),
  applied_by   text not null default session_user
);
comment on table cma.schema_migration is 'Migration scripts applied to this database';

-- A tenant is one isolated environment with its own people, configuration and data.
-- Today: one per business line. This table is the list of tenants and is not tenant-scoped itself.
create table if not exists cma.tenant (
  id          uuid primary key default uuidv7(),
  slug        text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name        text not null,
  timezone    text not null default 'UTC',
  status      text not null default 'active' check (status in ('active', 'inactive')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
comment on table cma.tenant is 'Isolation unit, one row per business line. Every tenant-scoped table references it';
comment on column cma.tenant.timezone is 'IANA name, for example Europe/Amsterdam. Defines day boundaries for workdays and reports';
create or replace trigger set_updated_at before update on cma.tenant
  for each row execute function cma.set_updated_at();

-- Every insert, update and delete on every tenant-scoped table, with actor and timestamp.
-- Insert-only: the application can read its tenant's history and add to it, never change it.
-- Rows contain the full before and after image, so this table holds the same personal data as
-- the tables it covers and follows the same retention rules (to agree with Yordi).
create table if not exists cma.audit_log (
  id             uuid primary key default uuidv7(),
  tenant_id      uuid not null references cma.tenant (id),
  table_name     text not null,
  action         text not null check (action in ('insert', 'update', 'delete')),
  row_id         text generated always as (coalesce(new_row ->> 'id', old_row ->> 'id')) stored,
  old_row        jsonb,
  new_row        jsonb,
  changed_at     timestamptz not null default clock_timestamp(),
  actor_user_id  uuid,                                      -- cma.current_user_id(); NULL for system processes
  actor_label    text,                                      -- cma.current_actor_label(); the process when there is no user
  actor_db_role  text not null default current_user,        -- cma_app, cma_owner
  actor_login    text not null default session_user         -- IAM login or service account behind it
);
comment on table cma.audit_log is 'Change history of all tenant-scoped tables. Append-only';
create index if not exists audit_log_row_idx  on cma.audit_log (tenant_id, table_name, row_id, changed_at);
create index if not exists audit_log_time_idx on cma.audit_log (tenant_id, changed_at);

alter table cma.audit_log enable row level security;
grant select, insert on cma.audit_log to cma_app;          -- no update, no delete, for anyone but the owner
drop policy if exists tenant_app on cma.audit_log;
create policy tenant_app on cma.audit_log to cma_app
  using      (tenant_id = cma.current_tenant_id())
  with check (tenant_id = cma.current_tenant_id());
drop policy if exists tenant_readonly on cma.audit_log;   -- readers use cma_read.audit_log

-- ---------------------------------------------------------------------------------------------
-- 4. Audit trigger and the one-call setup for tenant-scoped tables
-- ---------------------------------------------------------------------------------------------

create or replace function cma.audit_row()
returns trigger
language plpgsql
as $$
declare
  v_old jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_new jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
begin
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

-- Standard setup for one tenant-scoped table, in one call:
--   RLS on; the app reads and writes its own tenant only; every change goes to cma.audit_log.
--   Readers never touch base tables, so no reader policy here: give the table a view in cma_read.
-- Call it for every tenant-scoped table, now and in every future migration.
create or replace function cma.setup_tenant_table(p_table regclass)
returns void
language plpgsql
as $$
begin
  execute format('alter table %s enable row level security', p_table);
  execute format('grant select, insert, update, delete on %s to cma_app', p_table);

  execute format('drop policy if exists tenant_app on %s', p_table);
  execute format(
    'create policy tenant_app on %s to cma_app
       using      (tenant_id = cma.current_tenant_id())
       with check (tenant_id = cma.current_tenant_id())', p_table);

  execute format('drop policy if exists tenant_readonly on %s', p_table);   -- from an earlier draft

  execute format('drop trigger if exists audit on %s', p_table);
  execute format(
    'create trigger audit after insert or update or delete on %s
       for each row execute function cma.audit_row()', p_table);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. Catalogs, people, roles
-- ---------------------------------------------------------------------------------------------

-- What the application can check. Defined by the code, identical for all tenants,
-- changed only through migrations.
create table if not exists cma.permission (
  key          text primary key check (key ~ '^[a-z_]+\.[a-z_]+$'),
  description  text not null
);
comment on table cma.permission is 'Permission catalog. Keys are referenced by application code';

-- Who employs the people in a tenant: the tenant's own company or a partner such as the
-- call center. Per-tenant configuration; hours and productivity can be reported per organisation.
create table if not exists cma.organisation (
  id          uuid primary key default uuidv7(),
  tenant_id   uuid not null default cma.current_tenant_id() references cma.tenant (id),
  key         text not null check (key ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name        text not null,
  status      text not null default 'active' check (status in ('active', 'inactive')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, key)
);
comment on table cma.organisation is 'Employers of CMA users within a tenant, for example the company itself and a call center partner';
create or replace trigger set_updated_at before update on cma.organisation
  for each row execute function cma.set_updated_at();

-- Customer contact channels a tenant works: phone and email today, sms, whatsapp, chat and
-- others as they go live. Configuration, so skills, routing rules, SLAs and metrics reference a
-- channel key and never assume phone. Not to be confused with the channels the CMA uses to
-- reach its own users (in-app push, email, mobile); those belong to the messaging module.
create table if not exists cma.channel (
  id              uuid primary key default uuidv7(),
  tenant_id       uuid not null default cma.current_tenant_id() references cma.tenant (id),
  key             text not null check (key ~ '^[a-z0-9_]+$'),
  name            text not null,
  is_synchronous  boolean not null,   -- true: live conversation (phone, chat); false: messaging (email, sms, whatsapp)
  status          text not null default 'active' check (status in ('active', 'inactive')),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, key)
);
comment on table cma.channel is 'Customer contact channels per tenant. Referenced by skills, routing, SLAs and metrics';
create or replace trigger set_updated_at before update on cma.channel
  for each row execute function cma.set_updated_at();

-- People who use the CMA: agents, supervisors, managers, analysts. One row per person per tenant;
-- the same person in two business lines has two rows.
create table if not exists cma.app_user (
  id               uuid primary key default uuidv7(),
  tenant_id        uuid not null default cma.current_tenant_id() references cma.tenant (id),
  organisation_id  uuid,
  email            text not null check (email = lower(email)),
  display_name     text not null,
  status           text not null default 'active' check (status in ('active', 'inactive')),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (tenant_id, id),       -- lets child tables reference (tenant_id, id) together
  unique (tenant_id, email),
  foreign key (tenant_id, organisation_id) references cma.organisation (tenant_id, id)
);
comment on table cma.app_user is 'People who use the CMA, employed by the tenant''s company or by a partner such as the call center; never customers. Any email domain. Not hard-deleted: set status inactive, time history depends on the row';
comment on column cma.app_user.organisation_id is 'Employer. Optional, so a user can exist before the employer list is maintained';
create or replace trigger set_updated_at before update on cma.app_user
  for each row execute function cma.set_updated_at();
create index if not exists app_user_organisation_idx on cma.app_user (tenant_id, organisation_id);

-- The same person in another system: the CRM user id (login), the CRM owner id (lead
-- assignment), the telephony user id (call matching). Which systems a tenant uses is
-- configuration, so system is free text with a vocabulary agreed per customer.
create table if not exists cma.app_user_external_id (
  tenant_id    uuid not null default cma.current_tenant_id() references cma.tenant (id),
  user_id      uuid not null,
  system       text not null check (system ~ '^[a-z0-9_]+$'),
  external_id  text not null,
  created_at   timestamptz not null default now(),
  primary key (tenant_id, user_id, system),
  unique (tenant_id, system, external_id),
  foreign key (tenant_id, user_id) references cma.app_user (tenant_id, id)
);
comment on table cma.app_user_external_id is 'Ids of a user in other systems. Key vocabulary per customer, for example <crm>_user, <crm>_owner, <telephony>_user';

-- Roles per tenant. Every tenant is seeded with the same default ladder and may adjust it.
create table if not exists cma.app_role (
  id          uuid primary key default uuidv7(),
  tenant_id   uuid not null default cma.current_tenant_id() references cma.tenant (id),
  key         text not null check (key ~ '^[a-z_]+$'),
  name        text not null,
  is_system   boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, key)
);
comment on column cma.app_role.is_system is 'Part of the default ladder; the application does not allow deleting it';
create or replace trigger set_updated_at before update on cma.app_role
  for each row execute function cma.set_updated_at();

create table if not exists cma.role_permission (
  tenant_id       uuid not null default cma.current_tenant_id() references cma.tenant (id),
  role_id         uuid not null,
  permission_key  text not null references cma.permission (key),
  primary key (tenant_id, role_id, permission_key),
  foreign key (tenant_id, role_id) references cma.app_role (tenant_id, id) on delete cascade
);

-- A role grant, optionally limited to a scope: a supervisor for one team, a manager for one
-- market. scope_type names the kind (team, market, ...), scope_id the row; both NULL means the
-- whole tenant. The same role can be granted several times with different scopes.
create table if not exists cma.user_role (
  id          uuid primary key default uuidv7(),
  tenant_id   uuid not null default cma.current_tenant_id() references cma.tenant (id),
  user_id     uuid not null,
  role_id     uuid not null,
  scope_type  text check (scope_type ~ '^[a-z_]+$'),
  scope_id    uuid,
  granted_at  timestamptz not null default now(),
  granted_by  uuid,
  check ((scope_type is null) = (scope_id is null)),
  unique nulls not distinct (tenant_id, user_id, role_id, scope_type, scope_id),
  foreign key (tenant_id, user_id)    references cma.app_user (tenant_id, id),
  foreign key (tenant_id, role_id)    references cma.app_role (tenant_id, id),
  foreign key (tenant_id, granted_by) references cma.app_user (tenant_id, id)
);
comment on table cma.user_role is 'Role grants per user, optionally scoped. NULL scope = whole tenant';
create index if not exists user_role_role_idx  on cma.user_role (tenant_id, role_id);
create index if not exists user_role_scope_idx on cma.user_role (tenant_id, scope_type, scope_id);

-- ---------------------------------------------------------------------------------------------
-- 6. Tenant separation and audit on every tenant-scoped table
-- ---------------------------------------------------------------------------------------------
select cma.setup_tenant_table('cma.organisation');
select cma.setup_tenant_table('cma.channel');
select cma.setup_tenant_table('cma.app_user');
select cma.setup_tenant_table('cma.app_user_external_id');
select cma.setup_tenant_table('cma.app_role');
select cma.setup_tenant_table('cma.role_permission');
select cma.setup_tenant_table('cma.user_role');

-- ---------------------------------------------------------------------------------------------
-- 7. Tenant creation, reusable for the next business line
-- ---------------------------------------------------------------------------------------------

-- The default role ladder. Changing it is a migration; a tenant can still adjust its own copy.
create or replace function cma.seed_default_roles(p_tenant_id uuid)
returns void
language plpgsql
as $$
declare
  r record;
begin
  for r in
    select *
    from (values
      ('agent', 'Agent', array[
         'workday.own', 'roster.view', 'leads.accept', 'performance.own']),
      ('supervisor', 'Supervisor', array[
         'workday.own', 'roster.view', 'leads.accept', 'performance.own',
         'workday.team', 'performance.team', 'monitoring.live', 'messages.send']),
      ('manager', 'Call center manager', array[
         'workday.own', 'roster.view', 'leads.accept', 'performance.own',
         'workday.team', 'performance.team', 'monitoring.live', 'messages.send',
         'roster.manage', 'skills.manage', 'leads.manage', 'quality.manage',
         'reports.view', 'users.manage', 'tenant.configure']),
      ('analytics', 'Analytics', array[
         'reports.view', 'performance.team', 'monitoring.live', 'quality.manage'])
    ) as v(key, name, perms)
  loop
    insert into cma.app_role (tenant_id, key, name, is_system)
    values (p_tenant_id, r.key, r.name, true)
    on conflict (tenant_id, key) do nothing;

    insert into cma.role_permission (tenant_id, role_id, permission_key)
    select p_tenant_id, ar.id, p
    from cma.app_role ar
    cross join unnest(r.perms) as p
    where ar.tenant_id = p_tenant_id and ar.key = r.key
    on conflict do nothing;
  end loop;
end
$$;

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
  return v_id;
end
$$;

-- Owner-only helpers
revoke execute on function
  cma.setup_tenant_table(regclass),
  cma.seed_default_roles(uuid),
  cma.create_tenant(text, text, text)
from public;

-- ---------------------------------------------------------------------------------------------
-- 8. Reporting schema: the only thing readers see
-- ---------------------------------------------------------------------------------------------
-- Views owned by cma_owner, so a reader needs no rights on the base tables and the base tables
-- can change without breaking BigQuery or NocoDB. Columns are listed explicitly: a new column
-- is exposed when someone decides so, not by default. A reader sees all tenants unless its
-- session or login user carries app.tenant_id (00_roles.sql shows how).
create schema if not exists cma_read authorization cma_owner;
comment on schema cma_read is 'Read-only reporting views over cma for BigQuery, NocoDB and analytics. Readers never access schema cma';

grant usage on schema cma_read to cma_readonly;
alter default privileges in schema cma_read grant select on tables to cma_readonly;

-- Only pg_catalog functions inside, so a reader can call it without any rights on schema cma
create or replace function cma_read.reader_sees(p_tenant_id uuid)
returns boolean
language sql stable parallel safe
as $$
  select nullif(current_setting('app.tenant_id', true), '') is null
      or p_tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid
$$;

create or replace view cma_read.tenant as
  select id, slug, name, timezone, status, created_at, updated_at
  from cma.tenant
  where cma_read.reader_sees(id);

create or replace view cma_read.organisation as
  select id, tenant_id, key, name, status, created_at, updated_at
  from cma.organisation
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.channel as
  select id, tenant_id, key, name, is_synchronous, status, created_at, updated_at
  from cma.channel
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.app_user as
  select id, tenant_id, organisation_id, email, display_name, status, created_at, updated_at
  from cma.app_user
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.app_user_external_id as
  select tenant_id, user_id, system, external_id, created_at
  from cma.app_user_external_id
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.app_role as
  select id, tenant_id, key, name, is_system, created_at, updated_at
  from cma.app_role
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.permission as
  select key, description
  from cma.permission;

create or replace view cma_read.role_permission as
  select tenant_id, role_id, permission_key
  from cma.role_permission
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.user_role as
  select id, tenant_id, user_id, role_id, scope_type, scope_id, granted_at, granted_by
  from cma.user_role
  where cma_read.reader_sees(tenant_id);

-- Who changed what and when, without the row images: history for reporting, content stays in cma
create or replace view cma_read.audit_log as
  select id, tenant_id, table_name, action, row_id, changed_at,
         actor_user_id, actor_label, actor_db_role, actor_login
  from cma.audit_log
  where cma_read.reader_sees(tenant_id);

-- ---------------------------------------------------------------------------------------------
-- 9. Seed: permission catalog
-- ---------------------------------------------------------------------------------------------
insert into cma.permission (key, description) values
  ('workday.own',      'Start and end the own workday, change own status'),
  ('workday.team',     'See and correct time and status of the team'),
  ('roster.view',      'See published rosters'),
  ('roster.manage',    'Create and publish rosters, see skill coverage'),
  ('skills.manage',    'Maintain skills per agent'),
  ('leads.accept',     'Receive assigned leads and accept them'),
  ('leads.manage',     'Reassign leads and configure assignment rules'),
  ('performance.own',  'Own scores, goals and streaks'),
  ('performance.team', 'Productivity and effectiveness per agent'),
  ('monitoring.live',  'Live team view and alerts'),
  ('quality.manage',   'Quality scorecards and coaching notes'),
  ('messages.send',    'Push messages to agents'),
  ('reports.view',     'KPI dashboards and reports'),
  ('users.manage',     'Add people and assign roles'),
  ('tenant.configure', 'Statuses, skill lists, channels, markets, thresholds and other settings')
on conflict (key) do update set description = excluded.description;

-- ---------------------------------------------------------------------------------------------
-- 10. Record the migration
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0001', 'Foundation: tenants, users, roles, permissions, channels, tenant separation, audit log, reporting views')
on conflict (version) do nothing;
