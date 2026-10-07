-- =============================================================================================
-- 13_tenant_settings.sql: migration 0003b, tenant settings and the export permission
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database.
-- Rerunnable. Run as your own IAM login in Cloud SQL Studio, dev first, then prod; then
-- 14_verify_tenant_settings.sql, then rerun 02_seed_<customer>.sql for the customer values.
--
--   cma.setting                 global catalog of settings the code may read; changed only by
--                               migrations, like cma.permission
--   cma.tenant_setting          a tenant's own value per setting; RLS and audit; validated
--   cma.tenant_settings()       the effective settings of the current tenant (default or own)
--   cma.set_tenant_setting()    writes or resets one value; needs tenant.configure
--   workday.export              new permission: download hours and status changes as files;
--                               granted to the default manager role
--   cma.export_hours()          hours per person per day for the export, needs workday.export
--   cma.export_status_changes() one row per status stretch for the export, needs workday.export
-- Increment c3 of Roadmap step 2. Numbered 0003b so the planned migrations keep 0004 to 0009.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;

-- ---------------------------------------------------------------------------------------------
-- 1. The catalog
-- ---------------------------------------------------------------------------------------------
create table if not exists cma.setting (
  key             text primary key check (key ~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$'),
  value_type      text not null check (value_type in ('text', 'boolean', 'integer')),
  allowed_values  text[],                -- null: any value of the type
  default_value   text not null,
  description     text not null,
  check (allowed_values is null or default_value = any (allowed_values)),
  check (value_type <> 'boolean' or default_value in ('true', 'false')),
  check (value_type <> 'integer' or default_value ~ '^-?[0-9]+$')
);
comment on table cma.setting is 'Settings the application reads, with type, allowed values and a universal default. Changed only by migrations; a tenant sets its own value in cma.tenant_setting';

-- Tokens rather than literal characters, so a tab or a semicolon stays readable in the audit log
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('export.csv.separator',       'text',    array['comma', 'semicolon', 'tab'],
     'comma',         'Field separator in CSV exports'),
  ('export.csv.decimal_mark',    'text',    array['point', 'comma'],
     'point',         'Decimal mark for numbers in CSV exports'),
  ('export.csv.date_format',     'text',    array['yyyy-mm-dd', 'dd-mm-yyyy', 'dd/mm/yyyy', 'mm/dd/yyyy'],
     'yyyy-mm-dd',    'Date format in CSV exports'),
  ('export.csv.duration_format', 'text',    array['decimal_hours', 'hh:mm', 'minutes'],
     'decimal_hours', 'How durations are written in CSV exports'),
  ('export.csv.utf8_bom',        'boolean', null,
     'true',          'Start CSV exports with a UTF-8 byte order mark, so spreadsheet programs read accented names correctly')
on conflict (key) do update
  set value_type     = excluded.value_type,
      allowed_values = excluded.allowed_values,
      default_value  = excluded.default_value,
      description    = excluded.description;

-- ---------------------------------------------------------------------------------------------
-- 2. A tenant's own values
-- ---------------------------------------------------------------------------------------------
create table if not exists cma.tenant_setting (
  tenant_id   uuid not null default cma.current_tenant_id() references cma.tenant (id),
  key         text not null references cma.setting (key),
  value       text not null,
  updated_at  timestamptz not null default now(),
  updated_by  uuid default cma.current_user_id(),
  primary key (tenant_id, key),
  foreign key (tenant_id, updated_by) references cma.app_user (tenant_id, id)
);
comment on table cma.tenant_setting is 'A tenant''s own value for a setting in cma.setting; no row means the catalog default';
create or replace trigger set_updated_at before update on cma.tenant_setting
  for each row execute function cma.set_updated_at();

-- Every write path is validated against the catalog, not only the function below
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
  if s.allowed_values is not null and not (new.value = any (s.allowed_values)) then
    raise exception 'Setting % takes one of: %', new.key, array_to_string(s.allowed_values, ', ')
      using errcode = 'CMA04';
  end if;
  new.updated_by := cma.current_user_id();
  return new;
end
$$;
create or replace trigger check_value before insert or update on cma.tenant_setting
  for each row execute function cma.check_tenant_setting();

select cma.setup_tenant_table('cma.tenant_setting');

-- ---------------------------------------------------------------------------------------------
-- 3. Read and write functions
-- ---------------------------------------------------------------------------------------------

-- Effective settings of the current tenant. No tenant set: no rows (fail closed).
-- No permission needed: formats are not sensitive and every export reads them.
create or replace function cma.tenant_settings()
returns table (key text, value text, is_default boolean)
language sql
stable
as $$
  select s.key, coalesce(ts.value, s.default_value), ts.value is null
  from cma.setting s
  left join cma.tenant_setting ts
         on ts.tenant_id = cma.current_tenant_id() and ts.key = s.key
  where cma.current_tenant_id() is not null
  order by s.key
$$;

-- One value for the current tenant; null resets to the catalog default.
create or replace function cma.set_tenant_setting(p_key text, p_value text)
returns table (key text, value text, is_default boolean)
language plpgsql
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('tenant.configure');
  if not exists (select 1 from cma.setting s where s.key = p_key) then
    raise exception 'Unknown setting %', p_key using errcode = 'CMA02';
  end if;

  if p_value is null then
    delete from cma.tenant_setting ts
     where ts.tenant_id = cma.current_tenant_id() and ts.key = p_key;
  else
    insert into cma.tenant_setting as ts (tenant_id, key, value)
    values (cma.current_tenant_id(), p_key, p_value)
    on conflict (tenant_id, key) do update
      set value = excluded.value
      where ts.value is distinct from excluded.value;
  end if;

  return query select e.key, e.value, e.is_default from cma.tenant_settings() e where e.key = p_key;
end
$$;

revoke execute on function cma.check_tenant_setting(), cma.tenant_settings(), cma.set_tenant_setting(text, text) from public;
grant execute on function cma.tenant_settings(), cma.set_tenant_setting(text, text) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 3b. Export reads. Same rule as the team reads: the permission is checked inside, in the same
--     transaction as the read. workday.export, not workday.team: these leave the system as files.
--     At most 92 days per call, like team_hours. Staff data only.
-- ---------------------------------------------------------------------------------------------
create or replace function cma.export_hours(p_from date, p_to date, p_user_id uuid default null)
returns table (
  user_id             uuid,
  display_name        text,
  organisation_key    text,
  organisation_name   text,
  business_date       date,
  timezone            text,
  status              text,
  started_at          timestamptz,
  ended_at            timestamptz,
  working_seconds     bigint,
  productive_seconds  bigint,
  paid_seconds        bigint,
  billable_seconds    bigint,
  is_capped           boolean,
  needs_correction    boolean,
  has_correction      boolean
)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('workday.export');
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 91 then
    raise exception 'the range must run forward and cover at most 92 days' using errcode = 'CMA04';
  end if;
  return query
    select s.user_id, u.display_name::text, o.key::text, coalesce(o.name, '')::text, s.business_date,
           s.timezone::text, s.status::text, s.started_at, s.ended_at,
           s.working_seconds, s.productive_seconds, s.paid_seconds, s.billable_seconds,
           s.is_capped, s.needs_correction, s.has_correction
    from cma.workday_summary s
    join cma.app_user u on u.tenant_id = s.tenant_id and u.id = s.user_id
    left join cma.organisation o on o.tenant_id = u.tenant_id and o.id = u.organisation_id
    where s.business_date between p_from and p_to
      and (p_user_id is null or s.user_id = p_user_id)
    order by s.business_date, u.display_name, s.user_id;
end
$$;

-- One row per effective stretch in a status (cma.time_interval): from its start or status change
-- to the next effective event of the day. An open stretch has no end; a capped one stops at the
-- end of its business day and is flagged. source is the source of the event that began it.
create or replace function cma.export_status_changes(p_from date, p_to date, p_user_id uuid default null)
returns table (
  user_id            uuid,
  display_name       text,
  organisation_key   text,
  organisation_name  text,
  business_date      date,
  timezone           text,
  status_key         text,
  status_name        text,
  is_working         boolean,
  is_productive      boolean,
  is_paid            boolean,
  is_billable        boolean,
  from_at            timestamptz,
  to_at              timestamptz,
  is_open            boolean,
  is_capped          boolean,
  seconds            bigint,
  source             text
)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('workday.export');
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 91 then
    raise exception 'the range must run forward and cover at most 92 days' using errcode = 'CMA04';
  end if;
  return query
    select i.user_id, u.display_name::text, o.key::text, coalesce(o.name, '')::text, w.business_date,
           w.timezone::text, ws.key::text, ws.name::text,
           ws.is_working, ws.is_productive, ws.is_paid, ws.is_billable,
           i.from_at, i.to_at, i.is_open, i.is_capped, i.seconds, e.source::text
    from cma.time_interval i
    join cma.workday w      on w.tenant_id = i.tenant_id and w.id = i.workday_id
    join cma.work_status ws on ws.tenant_id = i.tenant_id and ws.id = i.status_id
    join cma.time_event e   on e.tenant_id = i.tenant_id and e.id = i.event_id
    join cma.app_user u     on u.tenant_id = i.tenant_id and u.id = i.user_id
    left join cma.organisation o on o.tenant_id = u.tenant_id and o.id = u.organisation_id
    where w.business_date between p_from and p_to
      and (p_user_id is null or i.user_id = p_user_id)
    order by w.business_date, u.display_name, i.user_id, i.from_at;
end
$$;

revoke execute on function cma.export_hours(date, date, uuid), cma.export_status_changes(date, date, uuid) from public;
grant execute on function cma.export_hours(date, date, uuid), cma.export_status_changes(date, date, uuid) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 4. Reporting views
-- ---------------------------------------------------------------------------------------------
create or replace view cma_read.setting as
  select key, value_type, allowed_values, default_value, description
  from cma.setting;

create or replace view cma_read.tenant_setting as
  select tenant_id, key, value, updated_at, updated_by
  from cma.tenant_setting
  where cma_read.reader_sees(tenant_id);

-- ---------------------------------------------------------------------------------------------
-- 5. The export permission
-- ---------------------------------------------------------------------------------------------
insert into cma.permission (key, description) values
  ('workday.export', 'Download hours and status changes as files')
on conflict (key) do update set description = excluded.description;

-- The default role ladder, as in 0001 plus workday.export for the manager
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
         'reports.view', 'users.manage', 'tenant.configure', 'workday.export']),
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
revoke execute on function cma.seed_default_roles(uuid) from public;

-- Existing tenants: only the new permission, only on the default manager role. Other changes a
-- tenant made to its own ladder stay as they are.
insert into cma.role_permission (tenant_id, role_id, permission_key)
select ar.tenant_id, ar.id, 'workday.export'
from cma.app_role ar
where ar.key = 'manager' and ar.is_system
on conflict do nothing;

-- ---------------------------------------------------------------------------------------------
-- 6. Record the migration
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0003b', 'Tenant settings (catalog, tenant values, read and write functions), the workday.export permission and the export reads')
on conflict (version) do nothing;
