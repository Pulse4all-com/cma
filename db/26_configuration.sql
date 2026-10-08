-- =============================================================================================
-- 26_configuration.sql: migration 0005a, configuration functions, the scheduler user and the
-- forgotten-day close
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 23_roster.sql (0005). Rerunnable, forward-only. Run as your own IAM login, dev first, then prod;
-- then 27_verify_configuration.sql.
--
-- What it adds (README Roadmap step 5, Features 1; the night build's defaults of 8 October 2026)
--   work statuses         cma.upsert_work_status(), set_default_work_status(), retire_work_status(),
--                         work_statuses_all(): the status list with its four flags, maintained by
--                         tenant.configure. A status in use is retired, never deleted; the default
--                         must be a working status; the last working status cannot be retired; the
--                         four flags of a status that already has time behind it are frozen (retire
--                         it and add a new one), so no history is rewritten by a click
--   app links             cma.upsert_app_link(), retire_app_link(), app_links_all(): the buttons on
--                         Welcome, https only, never customer data; cma_app may now insert and update
--                         the table (through the functions), never delete
--   absence types         cma.retire_absence_type(); coverage targets: cma.clear_coverage_target(),
--                         cma.coverage_targets_all() across every team
--   the scheduler user    one system user per tenant (app_user.kind = 'system', display name
--                         "Scheduler", login system 'scheduler'), holding the system role 'scheduler'
--                         with the one permission workday.close_forgotten, which no default role has.
--                         The role is not assignable and the user cannot be edited by the app: both
--                         are maintained by migrations only (app_role.is_assignable, a protection
--                         trigger). cma.roles() hides the role, cma.directory() hides the user
--   the forgotten close   cma.close_forgotten_workdays(grace?): ends every open workday whose
--                         business day ended more than the grace ago, with an end event at the
--                         business day's end, source 'system', the scheduler as the acting user and
--                         actor label 'scheduler'; the day stays needs_correction (the summary view
--                         now flags a system end) until a manager corrects or confirms it with a
--                         correction. Setting workday.auto_close_grace_minutes (default 120)
--
-- SQLSTATEs as before: CMA01 no acting user, CMA02 not found, CMA03 conflict (a status with time
-- behind it, the last working status, the default), CMA04 invalid, CMA06 not permitted.
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
  if not exists (select 1 from cma.schema_migration where version = '0005') then
    raise exception 'migration 0005 (23_roster.sql) must run before 0005a';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Catalog rows: the permission and the setting
-- ---------------------------------------------------------------------------------------------
insert into cma.permission (key, description) values
  ('workday.close_forgotten', 'End forgotten workdays at the end of their business day (the scheduler''s system user only; no default role)')
on conflict (key) do update set description = excluded.description;

insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('workday.auto_close_grace_minutes', 'integer', null, '120',
     'Minutes after the end of a business day before the scheduler ends a workday that was never clocked out')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- ---------------------------------------------------------------------------------------------
-- 2. System users and non-assignable roles
-- ---------------------------------------------------------------------------------------------
alter table cma.app_user add column if not exists kind text not null default 'person';
alter table cma.app_user drop constraint if exists app_user_kind_check;
alter table cma.app_user add constraint app_user_kind_check check (kind in ('person', 'system'));
comment on column cma.app_user.kind is 'person: someone who logs in; system: a process the audit must name (the scheduler). Maintained by migrations only; the README''s worker kind for AI agents joins here later';

alter table cma.app_role add column if not exists is_assignable boolean not null default true;
comment on column cma.app_role.is_assignable is 'false: a role for a system user, never offered to people and never granted by the application';

-- The application never touches a system user or a non-assignable role: only the owner (a
-- migration) does. One trigger function on the four tables that attribute something to a user.
create or replace function cma.protect_system_rows()
returns trigger
language plpgsql
as $$
declare
  v_user uuid;
  v_role uuid;
begin
  if current_user = 'cma_owner' then
    return coalesce(new, old);
  end if;
  if tg_table_name = 'app_user' then
    if tg_op = 'INSERT' and new.kind <> 'person' then
      raise exception 'system users are maintained by migrations' using errcode = 'CMA06';
    end if;
    if tg_op = 'UPDATE' and (old.kind <> 'person' or new.kind <> old.kind) then
      raise exception 'system users are maintained by migrations' using errcode = 'CMA06';
    end if;
    return new;
  end if;
  v_user := coalesce(new.user_id, old.user_id);
  if exists (select 1 from cma.app_user u where u.tenant_id = coalesce(new.tenant_id, old.tenant_id) and u.id = v_user and u.kind <> 'person') then
    raise exception 'system users are maintained by migrations' using errcode = 'CMA06';
  end if;
  if tg_table_name = 'user_role' then
    v_role := coalesce(new.role_id, old.role_id);
    if exists (select 1 from cma.app_role r where r.tenant_id = coalesce(new.tenant_id, old.tenant_id) and r.id = v_role and not r.is_assignable) then
      raise exception 'role is not assignable' using errcode = 'CMA06';
    end if;
  end if;
  return coalesce(new, old);
end
$$;
revoke execute on function cma.protect_system_rows() from public;

create or replace trigger protect_system before insert or update on cma.app_user
  for each row execute function cma.protect_system_rows();
create or replace trigger protect_system before insert or update or delete on cma.user_role
  for each row execute function cma.protect_system_rows();
create or replace trigger protect_system before insert or update on cma.team_member
  for each row execute function cma.protect_system_rows();
create or replace trigger protect_system before insert or update on cma.user_skill
  for each row execute function cma.protect_system_rows();

-- The scheduler: one system user per tenant with the one permission, so every end it writes is
-- audited under a named acting user. Rerun-safe; the login id ('scheduler', 'scheduler') is the
-- same in every tenant, which is how the job finds the tenants it serves (find_tenants_for_identity).
create or replace function cma.ensure_scheduler_user(p_tenant_id uuid)
returns uuid
language plpgsql
as $$
declare
  v_role uuid;
  v_user uuid;
begin
  insert into cma.app_role (tenant_id, key, name, is_system, is_assignable)
  values (p_tenant_id, 'scheduler', 'Scheduler', true, false)
  on conflict (tenant_id, key) do update set is_assignable = false, is_system = true
  returning id into v_role;
  if v_role is null then
    select id into v_role from cma.app_role where tenant_id = p_tenant_id and key = 'scheduler';
  end if;
  insert into cma.role_permission (tenant_id, role_id, permission_key)
  values (p_tenant_id, v_role, 'workday.close_forgotten')
  on conflict do nothing;

  insert into cma.app_user (tenant_id, email, display_name, status, kind)
  values (p_tenant_id, 'scheduler@system.invalid', 'Scheduler', 'active', 'system')
  on conflict (tenant_id, email) do update set kind = 'system', status = 'active'
  returning id into v_user;
  if v_user is null then
    select id into v_user from cma.app_user where tenant_id = p_tenant_id and email = 'scheduler@system.invalid';
  end if;
  insert into cma.user_role (tenant_id, user_id, role_id)
  values (p_tenant_id, v_user, v_role)
  on conflict do nothing;
  insert into cma.app_user_external_id (tenant_id, user_id, system, external_id)
  values (p_tenant_id, v_user, 'scheduler', 'scheduler')
  on conflict do nothing;
  return v_user;
end
$$;
revoke execute on function cma.ensure_scheduler_user(uuid) from public;

-- create_tenant as in 0005, plus the scheduler user
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
  return v_id;
end
$$;
revoke execute on function cma.create_tenant(text, text, text) from public;

do $$
declare
  t record;
begin
  for t in select id from cma.tenant loop
    perform cma.ensure_scheduler_user(t.id);
  end loop;
end
$$;

-- cma.roles() as in 0004, listing assignable roles only
create or replace function cma.roles()
returns table (key text, name text, is_system boolean, is_managing boolean, assignable boolean, permissions text[])
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_all boolean;
begin
  perform cma.assert_any_permission(array['users.manage_agents', 'users.manage_all']);
  v_all := cma.has_permission(cma.current_user_id(), 'users.manage_all');
  return query
    select ar.key::text, ar.name::text, ar.is_system, cma.role_is_managing(ar.id),
           (v_all or not cma.role_is_managing(ar.id)),
           array(select rp.permission_key from cma.role_permission rp
                 where rp.tenant_id = ar.tenant_id and rp.role_id = ar.id order by rp.permission_key)
    from cma.app_role ar
    where ar.tenant_id = cma.current_tenant_id() and ar.is_assignable
    order by cardinality(array(select 1 from cma.role_permission rp where rp.tenant_id = ar.tenant_id and rp.role_id = ar.id)), ar.key;
end
$$;

-- cma.directory() as in 0004, listing people only (kind = 'person')
create or replace function cma.directory()
returns table (
  user_id            uuid,
  email              text,
  display_name       text,
  status             text,
  organisation_key   text,
  organisation_name  text,
  timezone           text,
  role_key           text,
  role_name          text,
  role_granted_at    timestamptz,
  is_managing        boolean,
  time_kept          boolean,
  teams              jsonb,
  skills             jsonb,
  may_edit           boolean
)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_user uuid := cma.assert_any_permission(array['users.manage_agents', 'users.manage_all']);
  v_all  boolean := cma.has_permission(cma.current_user_id(), 'users.manage_all');
begin
  return query
    select u.id, u.email::text, u.display_name::text, u.status::text,
           o.key::text, coalesce(o.name, '')::text, cma.user_timezone(u.id)::text,
           r.key::text, r.name::text, r.granted_at,
           coalesce(r.is_managing, false),
           cma.time_is_kept(u.id),
           coalesce((select jsonb_agg(jsonb_build_object('key', t.key, 'name', t.name) order by t.sort_order, t.key)
                     from cma.team_member m
                     join cma.team t on t.tenant_id = m.tenant_id and t.id = m.team_id
                     where m.tenant_id = u.tenant_id and m.user_id = u.id and m.valid_to is null and t.valid_to is null), '[]'::jsonb),
           coalesce((select jsonb_agg(jsonb_build_object('dimension', s.dimension, 'key', s.key, 'name', s.name,
                                                         'level', us.level, 'levelName', l.name)
                                      order by case s.dimension when 'language' then 1 when 'work_type' then 2 else 3 end, s.sort_order, s.key)
                     from cma.user_skill us
                     join cma.skill s on s.tenant_id = us.tenant_id and s.id = us.skill_id
                     left join cma.skill_level l on l.tenant_id = s.tenant_id and l.dimension = s.dimension and l.level = us.level
                     where us.tenant_id = u.tenant_id and us.user_id = u.id and us.valid_to is null), '[]'::jsonb),
           (u.id <> v_user and (v_all or not coalesce(r.is_managing, false)))
    from cma.app_user u
    left join cma.organisation o on o.tenant_id = u.tenant_id and o.id = u.organisation_id
    left join lateral (
      select ar.key, ar.name, ur.granted_at,
             exists (select 1 from cma.user_role ur2 where ur2.tenant_id = u.tenant_id and ur2.user_id = u.id
                     and cma.role_is_managing(ur2.role_id)) as is_managing
      from cma.user_role ur
      join cma.app_role ar on ar.tenant_id = ur.tenant_id and ar.id = ur.role_id
      where ur.tenant_id = u.tenant_id and ur.user_id = u.id
      order by ur.granted_at, ar.key
      limit 1
    ) r on true
    where u.tenant_id = cma.current_tenant_id()
      and u.kind = 'person'
      and (v_all or u.id = v_user or not coalesce(r.is_managing, false))
    order by (u.status <> 'active'), u.display_name, u.id;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. The forgotten-day close
-- ---------------------------------------------------------------------------------------------
-- The summary view as in 0002, with one change: a day ended by the system (the scheduler) stays
-- flagged until a correction supersedes that end. Same columns, so every face and function above
-- it keeps working.
create or replace view cma.workday_summary_all as
  select w.id as workday_id, w.tenant_id, w.user_id, w.business_date, w.timezone, w.status,
         w.started_at, w.ended_at,
         coalesce(sum(i.seconds) filter (where s.is_working),    0)::bigint as working_seconds,
         coalesce(sum(i.seconds) filter (where s.is_productive), 0)::bigint as productive_seconds,
         coalesce(sum(i.seconds) filter (where s.is_paid),       0)::bigint as paid_seconds,
         coalesce(sum(i.seconds) filter (where s.is_billable),   0)::bigint as billable_seconds,
         coalesce(bool_or(i.is_capped), false) as is_capped,
         ((w.status = 'open' and now() > cma.business_day_end(w.business_date, w.timezone))
          or exists (select 1 from cma.time_event_effective_all e
                     where e.tenant_id = w.tenant_id and e.workday_id = w.id and e.kind = 'end' and e.source = 'system')) as needs_correction,
         exists (select 1 from cma.time_event e
                 where e.tenant_id = w.tenant_id and e.workday_id = w.id and e.source = 'correction') as has_correction,
         (select e.status_id from cma.time_event_effective_all e
          where e.tenant_id = w.tenant_id and e.workday_id = w.id and e.kind in ('start', 'status')
          order by e.occurred_at desc, e.recorded_at desc limit 1) as current_status_id
  from cma.workday w
  left join cma.time_interval_all i on i.tenant_id = w.tenant_id and i.workday_id = w.id
  left join cma.work_status s on s.tenant_id = i.tenant_id and s.id = i.status_id
  group by w.id;

-- Ends every open workday of the current tenant whose business day ended more than the grace
-- ago (the parameter, else the tenant's setting, else 120 minutes). The end sits at the business
-- day's end (or at the day's last event when that is later), source 'system'; the acting user is
-- the scheduler, the actor label 'scheduler'. Returns what it closed. A normal day and a day still
-- within its grace are untouched. Idempotent: a second run finds nothing.
create or replace function cma.close_forgotten_workdays(p_grace_minutes integer default null)
returns table (workday_id uuid, user_id uuid, business_date date, ended_at timestamptz)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_grace  integer;
  v_tenant uuid := cma.current_tenant_id();
  w        record;
  v_end    timestamptz;
begin
  perform cma.assert_permission('workday.close_forgotten');
  if cma.current_actor_label() is null then
    perform set_config('app.actor_label', 'scheduler', true);
  end if;
  v_grace := coalesce(p_grace_minutes,
                      (select s.value::integer from cma.tenant_settings() s where s.key = 'workday.auto_close_grace_minutes'),
                      120);
  if v_grace < 0 then
    raise exception 'grace is 0 minutes or more' using errcode = 'CMA04';
  end if;
  for w in
    select d.id, d.user_id, d.business_date,
           cma.business_day_end(d.business_date, d.timezone) as day_end,
           (select max(e.occurred_at) from cma.time_event_effective e where e.tenant_id = d.tenant_id and e.workday_id = d.id) as last_at
    from cma.workday d
    where d.tenant_id = v_tenant and d.status = 'open'
      and cma.business_day_end(d.business_date, d.timezone) + make_interval(mins => v_grace) <= now()
    order by d.business_date, d.user_id
    for update of d
  loop
    v_end := greatest(w.day_end, w.last_at);
    insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source)
    values (v_tenant, w.id, w.user_id, 'end', null, v_end, 'system');
    perform cma.refresh_workday(w.id);
    workday_id := w.id; user_id := w.user_id; business_date := w.business_date; ended_at := v_end;
    return next;
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Work statuses: the list with its flags, for tenant.configure
-- ---------------------------------------------------------------------------------------------
-- Every status with its flags, whether it is the default and active, and how many time events
-- reference it (the usage a retired status keeps)
create or replace function cma.work_statuses_all()
returns table (key text, name text, is_working boolean, is_productive boolean, is_paid boolean, is_billable boolean,
               is_default boolean, sort_order integer, status text, usage_count bigint)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('tenant.configure');
  return query
    select s.key::text, s.name::text, s.is_working, s.is_productive, s.is_paid, s.is_billable,
           s.is_default, s.sort_order, s.status::text,
           (select count(*) from cma.time_event e where e.tenant_id = s.tenant_id and e.status_id = s.id)
    from cma.work_status s
    where s.tenant_id = cma.current_tenant_id()
    order by (s.status <> 'active'), s.sort_order, s.key;
end
$$;

-- Adds or changes a status. A retired key is reactivated. The four flags of a status that already
-- has time behind it cannot change (CMA03): retire it and add a new one, so no pay or billing
-- history is rewritten; name and order stay editable. Never touches is_default (see below).
create or replace function cma.upsert_work_status(p_key text, p_name text, p_is_working boolean, p_is_productive boolean,
                                                  p_is_paid boolean, p_is_billable boolean, p_sort_order integer default 100)
returns void
language plpgsql
as $$
declare
  s cma.work_status;
begin
  perform cma.assert_permission('tenant.configure');
  if p_key is null or p_key !~ '^[a-z0-9_]+$' then
    raise exception 'a status key is lowercase letters, digits and underscores' using errcode = 'CMA04';
  end if;
  if p_name is null or length(btrim(p_name)) not between 1 and 40 then
    raise exception 'a status name is 1 to 40 characters' using errcode = 'CMA04';
  end if;
  if p_is_working is null or p_is_productive is null or p_is_paid is null or p_is_billable is null then
    raise exception 'the four flags are required' using errcode = 'CMA04';
  end if;
  select * into s from cma.work_status where tenant_id = cma.current_tenant_id() and key = p_key for update;
  if not found then
    insert into cma.work_status (tenant_id, key, name, is_working, is_productive, is_paid, is_billable, sort_order)
    values (cma.current_tenant_id(), p_key, btrim(p_name), p_is_working, p_is_productive, p_is_paid, p_is_billable, coalesce(p_sort_order, 100));
    return;
  end if;
  if (s.is_working, s.is_productive, s.is_paid, s.is_billable) is distinct from (p_is_working, p_is_productive, p_is_paid, p_is_billable)
     and exists (select 1 from cma.time_event e where e.tenant_id = s.tenant_id and e.status_id = s.id) then
    raise exception 'status % has time recorded in it; its flags cannot change. Retire it and add a new status', p_key using errcode = 'CMA03';
  end if;
  if s.is_default and not p_is_working then
    raise exception 'the default status must be a working status; choose another default first' using errcode = 'CMA03';
  end if;
  update cma.work_status
     set name = btrim(p_name), is_working = p_is_working, is_productive = p_is_productive, is_paid = p_is_paid,
         is_billable = p_is_billable, sort_order = coalesce(p_sort_order, 100), status = 'active'
   where tenant_id = cma.current_tenant_id() and id = s.id
     and (name, is_working, is_productive, is_paid, is_billable, sort_order, status)
         is distinct from (btrim(p_name), p_is_working, p_is_productive, p_is_paid, p_is_billable, coalesce(p_sort_order, 100), 'active');
end
$$;

-- Exactly one default: the chosen status (active and working) becomes it, the old one loses it
create or replace function cma.set_default_work_status(p_key text)
returns void
language plpgsql
as $$
declare
  s cma.work_status;
begin
  perform cma.assert_permission('tenant.configure');
  select * into s from cma.work_status where tenant_id = cma.current_tenant_id() and key = p_key for update;
  if not found then
    raise exception 'status % does not exist in the current tenant', p_key using errcode = 'CMA02';
  end if;
  if s.status <> 'active' or not s.is_working then
    raise exception 'the default status must be an active working status' using errcode = 'CMA03';
  end if;
  if s.is_default then
    return;
  end if;
  update cma.work_status set is_default = false
   where tenant_id = cma.current_tenant_id() and is_default and id <> s.id;
  update cma.work_status set is_default = true
   where tenant_id = cma.current_tenant_id() and id = s.id;
end
$$;

-- Retires a status: it keeps its history and cannot be chosen. Not the default and not the last
-- active working status (a day must be able to open)
create or replace function cma.retire_work_status(p_key text)
returns void
language plpgsql
as $$
declare
  s cma.work_status;
begin
  perform cma.assert_permission('tenant.configure');
  select * into s from cma.work_status where tenant_id = cma.current_tenant_id() and key = p_key for update;
  if not found then
    raise exception 'status % does not exist in the current tenant', p_key using errcode = 'CMA02';
  end if;
  if s.status <> 'active' then
    return;
  end if;
  if s.is_default then
    raise exception 'the default status cannot be retired; choose another default first' using errcode = 'CMA03';
  end if;
  if s.is_working and not exists (select 1 from cma.work_status o
                                  where o.tenant_id = s.tenant_id and o.id <> s.id and o.status = 'active' and o.is_working) then
    raise exception 'the last working status cannot be retired' using errcode = 'CMA03';
  end if;
  update cma.work_status set status = 'inactive' where tenant_id = cma.current_tenant_id() and id = s.id;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. App links: the buttons on Welcome, for tenant.configure
-- ---------------------------------------------------------------------------------------------
grant insert, update on cma.app_link to cma_app;   -- through the functions below; delete stays revoked

create or replace function cma.app_links_all()
returns table (key text, label text, address text, permission_key text, sort_order integer, status text)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('tenant.configure');
  return query
    select l.key::text, l.label::text, l.address::text, l.permission_key::text, l.sort_order, l.status::text
    from cma.app_link l
    where l.tenant_id = cma.current_tenant_id()
    order by (l.status <> 'active'), l.sort_order, l.key;
end
$$;

-- Adds or changes a link; a retired key is reactivated. https only (the table's constraint), the
-- permission from the catalog or null for everyone with a role
create or replace function cma.upsert_app_link(p_key text, p_label text, p_address text, p_permission_key text default null, p_sort_order integer default 100)
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
  if p_key is null or p_key !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then
    raise exception 'a link key is lowercase letters and digits, with single hyphens' using errcode = 'CMA04';
  end if;
  if p_label is null or length(btrim(p_label)) not between 1 and 60 then
    raise exception 'a label is 1 to 60 characters' using errcode = 'CMA04';
  end if;
  if p_address is null or p_address !~ '^https://[^[:space:]]+$' or length(p_address) > 2000 then
    raise exception 'an address starts with https:// and has no spaces' using errcode = 'CMA04';
  end if;
  if p_permission_key is not null and not exists (select 1 from cma.permission p where p.key = p_permission_key) then
    raise exception 'permission % does not exist', p_permission_key using errcode = 'CMA02';
  end if;
  insert into cma.app_link as l (tenant_id, key, label, address, permission_key, sort_order, status)
  values (cma.current_tenant_id(), p_key, btrim(p_label), p_address, p_permission_key, coalesce(p_sort_order, 100), 'active')
  on conflict (tenant_id, key) do update
    set label = excluded.label, address = excluded.address, permission_key = excluded.permission_key,
        sort_order = excluded.sort_order, status = 'active'
    where (l.label, l.address, l.permission_key, l.sort_order, l.status)
          is distinct from (excluded.label, excluded.address, excluded.permission_key, excluded.sort_order, 'active');
end
$$;

create or replace function cma.retire_app_link(p_key text)
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
  update cma.app_link set status = 'inactive'
   where tenant_id = cma.current_tenant_id() and key = p_key and status = 'active';
  if not found and not exists (select 1 from cma.app_link where tenant_id = cma.current_tenant_id() and key = p_key) then
    raise exception 'link % does not exist in the current tenant', p_key using errcode = 'CMA02';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. Absence types and coverage targets: the missing halves
-- ---------------------------------------------------------------------------------------------
create or replace function cma.retire_absence_type(p_key text)
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
  update cma.absence_type set status = 'inactive'
   where tenant_id = cma.current_tenant_id() and key = p_key and status = 'active';
  if not found and not exists (select 1 from cma.absence_type where tenant_id = cma.current_tenant_id() and key = p_key) then
    raise exception 'absence type % does not exist in the current tenant', p_key using errcode = 'CMA02';
  end if;
end
$$;

create or replace function cma.clear_coverage_target(p_team_key text, p_skill_key text, p_weekday smallint)
returns void
language plpgsql
as $$
begin
  perform cma.set_coverage_target(p_team_key, p_skill_key, p_weekday, null);
end
$$;

-- Every target of the tenant across teams, for the configuration grid
create or replace function cma.coverage_targets_all()
returns table (team_key text, skill_key text, weekday smallint, min_count integer)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('tenant.configure');
  return query
    select t.key::text, s.key::text, ct.weekday, ct.min_count
    from cma.coverage_target ct
    join cma.team t on t.tenant_id = ct.tenant_id and t.id = ct.team_id
    join cma.skill s on s.tenant_id = ct.tenant_id and s.id = ct.skill_id
    where ct.tenant_id = cma.current_tenant_id() and t.valid_to is null
    order by t.sort_order, t.key, s.sort_order, s.key, ct.weekday;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. Privileges on the functions: the application only
-- ---------------------------------------------------------------------------------------------
revoke execute on function
  cma.close_forgotten_workdays(integer),
  cma.work_statuses_all(), cma.upsert_work_status(text, text, boolean, boolean, boolean, boolean, integer),
  cma.set_default_work_status(text), cma.retire_work_status(text),
  cma.app_links_all(), cma.upsert_app_link(text, text, text, text, integer), cma.retire_app_link(text),
  cma.retire_absence_type(text), cma.clear_coverage_target(text, text, smallint), cma.coverage_targets_all(),
  cma.roles(), cma.directory()
from public;
grant execute on function
  cma.close_forgotten_workdays(integer),
  cma.work_statuses_all(), cma.upsert_work_status(text, text, boolean, boolean, boolean, boolean, integer),
  cma.set_default_work_status(text), cma.retire_work_status(text),
  cma.app_links_all(), cma.upsert_app_link(text, text, text, text, integer), cma.retire_app_link(text),
  cma.retire_absence_type(text), cma.clear_coverage_target(text, text, smallint), cma.coverage_targets_all(),
  cma.roles(), cma.directory()
to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 8. Reporting views that gained a column
-- ---------------------------------------------------------------------------------------------
-- The readers' view of people as in 0002, plus kind, so a reader can leave system users out
create or replace view cma_read.app_user as
  select id, tenant_id, organisation_id, email, display_name, status, created_at, updated_at, timezone, kind
  from cma.app_user
  where cma_read.reader_sees(tenant_id);

-- ---------------------------------------------------------------------------------------------
-- 9. Record the migration
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0005a', 'Configuration: work status, app link, absence type and coverage target functions for tenant.configure; the scheduler system user and role per tenant with workday.close_forgotten; cma.close_forgotten_workdays() and the auto-close grace setting; a system end keeps a day flagged')
on conflict (version) do nothing;

reset role;
