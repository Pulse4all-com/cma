-- =============================================================================================
-- 21_teams_skills.sql: migration 0004, teams and skills, and the admin role
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database.
-- Rerunnable, forward-only. Run as your own IAM login in Cloud SQL Studio, dev first, then prod;
-- then 22_verify_teams_skills.sql, then rerun 02_seed_<customer>.sql for the customer's teams
-- and skills (dev also reruns 03 and 06 for the fixture).
--
-- Tables (README: Users and roles, Teams and skills; Data model: teams and skills)
--   cma.team           membership groups with one or more markets and validity (Team EN, NL, ...)
--   cma.team_member    who is in which team, from when to when; never overwritten
--   cma.skill          the skill catalog per tenant in three dimensions: language, work_type,
--                      channel; each with a key, a name and an order
--   cma.skill_level    the level scale per dimension as tenant configuration (Basic, Good,
--                      Fluent, Native for languages); a dimension without levels is binary
--   cma.user_skill     a person's level per skill, from when to when; a change ends the old row
-- Functions for the application (permission checked inside, CMA06 otherwise)
--   cma.directory()            people with role, employer, teams and skills, for the Team screen
--   cma.add_person()           adds a person with a login id and a role (replaces the add-a-person
--                              template, which is retired with this migration)
--   cma.set_person_role()      one role per person; replaces the grant
--   cma.set_person_active()    deactivate and reactivate; nobody deactivates themselves
--   cma.set_person_teams()     the full list of a person's teams; ends what is not in it
--   cma.set_person_skills()    the full list of a person's skills with levels
--   cma.roles(), cma.teams(), cma.skills(), cma.team_members_now()   reads for the screens
--   cma.upsert_team(), cma.dissolve_team(), cma.upsert_skill(), cma.set_skill_levels()
--                              catalog maintenance for the configuration screens (tenant.configure)
-- The ladder (Martin, 7 October 2026)
--   admin                      a new system role: everything the manager has plus tenant.configure,
--                              connections and API keys, and user management for all roles
--   users.manage               split into users.manage_agents (manager) and users.manage_all (admin)
--   tenant.configure           leaves the manager row
-- Who may manage whom: a holder of users.manage_all may manage anyone; a holder of only
-- users.manage_agents may manage people whose roles hold none of users.manage_agents,
-- users.manage_all or tenant.configure, and may assign only such roles. Nobody changes their own
-- role or deactivates themselves; the last holder of users.manage_all in a tenant cannot lose it.
--
-- SQLSTATEs as before: CMA01 no acting user, CMA02 not found, CMA03 conflict, CMA04 invalid,
-- CMA06 not permitted.
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
-- 1. Permissions and the ladder
-- ---------------------------------------------------------------------------------------------
insert into cma.permission (key, description) values
  ('users.manage_agents', 'Add people and set roles, teams and skills for agents and supervisors'),
  ('users.manage_all',    'Add people and set roles, teams and skills for everyone, administrators included')
on conflict (key) do update set description = excluded.description;

-- The default role ladder, as in 0003b plus the admin role; the manager keeps operations and
-- manages agents and supervisors; configuration and user management for all roles move to admin
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
         'reports.view', 'users.manage_agents', 'workday.export']),
      ('admin', 'Administrator', array[
         'workday.own', 'roster.view', 'leads.accept', 'performance.own',
         'workday.team', 'performance.team', 'monitoring.live', 'messages.send',
         'roster.manage', 'skills.manage', 'leads.manage', 'quality.manage',
         'reports.view', 'users.manage_agents', 'workday.export',
         'users.manage_all', 'tenant.configure']),
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

-- Existing tenants, rerun-safe: the admin role where it is missing; the system manager loses
-- tenant.configure and users.manage and gains users.manage_agents; users.manage leaves the
-- catalog. A tenant's own changes to other rows stay as they are.
do $$
declare
  t record;
begin
  for t in select id from cma.tenant loop
    perform cma.seed_default_roles(t.id);
  end loop;

  delete from cma.role_permission rp
  using cma.app_role ar
  where ar.tenant_id = rp.tenant_id and ar.id = rp.role_id
    and ar.key = 'manager' and ar.is_system
    and rp.permission_key in ('tenant.configure', 'users.manage');

  -- Any role that still carried users.manage keeps managing agents
  insert into cma.role_permission (tenant_id, role_id, permission_key)
  select rp.tenant_id, rp.role_id, 'users.manage_agents'
  from cma.role_permission rp
  where rp.permission_key = 'users.manage'
  on conflict do nothing;

  update cma.app_link set permission_key = 'users.manage_agents' where permission_key = 'users.manage';
  delete from cma.role_permission where permission_key = 'users.manage';
  delete from cma.permission where key = 'users.manage';
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. Tables
-- ---------------------------------------------------------------------------------------------

-- Teams: membership, not proficiency. A team serves one or more markets (ISO 3166-1 alpha-2 in
-- lower case by convention, a tenant may use its own tokens). Validity instead of a status: a
-- team that is dissolved gets valid_to and its memberships end the same instant.
create table if not exists cma.team (
  id          uuid primary key default uuidv7(),
  tenant_id   uuid not null default cma.current_tenant_id() references cma.tenant (id),
  key         text not null check (key ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name        text not null check (length(btrim(name)) between 1 and 60),
  markets     text[] not null default '{}',
  sort_order  integer not null default 100,
  valid_from  timestamptz not null default now(),
  valid_to    timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (valid_to is null or valid_to >= valid_from),
  check (array_position(markets, null) is null),
  unique (tenant_id, id),
  unique (tenant_id, key)
);
comment on table cma.team is 'Membership groups per tenant with the markets they serve; validity instead of a status. Queue hard filter, Live board and roster grouping, message targeting, scope of a grant';
create or replace trigger set_updated_at before update on cma.team
  for each row execute function cma.set_updated_at();

create table if not exists cma.team_member (
  id          uuid primary key default uuidv7(),
  tenant_id   uuid not null default cma.current_tenant_id() references cma.tenant (id),
  user_id     uuid not null,
  team_id     uuid not null,
  valid_from  timestamptz not null default now(),
  valid_to    timestamptz,
  created_at  timestamptz not null default now(),
  created_by  uuid default cma.current_user_id(),
  check (valid_to is null or valid_to >= valid_from),
  unique (tenant_id, id),
  foreign key (tenant_id, user_id)    references cma.app_user (tenant_id, id),
  foreign key (tenant_id, team_id)    references cma.team (tenant_id, id),
  foreign key (tenant_id, created_by) references cma.app_user (tenant_id, id)
);
comment on table cma.team_member is 'Who is in which team from when to when (half-open: valid_from inclusive, valid_to exclusive). Ending a membership sets valid_to; nothing is overwritten';
create unique index if not exists team_member_current_idx on cma.team_member (tenant_id, user_id, team_id) where valid_to is null;
create index if not exists team_member_team_idx on cma.team_member (tenant_id, team_id, valid_to);

-- The skill catalog in three dimensions. Channel skills reference the channel key by convention.
create table if not exists cma.skill (
  id          uuid primary key default uuidv7(),
  tenant_id   uuid not null default cma.current_tenant_id() references cma.tenant (id),
  dimension   text not null check (dimension in ('language', 'work_type', 'channel')),
  key         text not null check (key ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name        text not null check (length(btrim(name)) between 1 and 60),
  sort_order  integer not null default 100,
  status      text not null default 'active' check (status in ('active', 'inactive')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, dimension, key)
);
comment on table cma.skill is 'Skill catalog per tenant: languages, work types and channels. A key is stable, a name may change; an inactive skill keeps its history';
create or replace trigger set_updated_at before update on cma.skill
  for each row execute function cma.set_updated_at();

-- The level scale per dimension. No rows for a dimension means binary: a person has the skill
-- or not, and user_skill.level stays null.
create table if not exists cma.skill_level (
  tenant_id   uuid not null default cma.current_tenant_id() references cma.tenant (id),
  dimension   text not null check (dimension in ('language', 'work_type', 'channel')),
  level       smallint not null check (level between 1 and 9),
  name        text not null check (length(btrim(name)) between 1 and 30),
  primary key (tenant_id, dimension, level)
);
comment on table cma.skill_level is 'Level scale per skill dimension, tenant configuration: 1 is the lowest. A dimension without rows is binary';

create table if not exists cma.user_skill (
  id          uuid primary key default uuidv7(),
  tenant_id   uuid not null default cma.current_tenant_id() references cma.tenant (id),
  user_id     uuid not null,
  skill_id    uuid not null,
  level       smallint check (level between 1 and 9),
  valid_from  timestamptz not null default now(),
  valid_to    timestamptz,
  created_at  timestamptz not null default now(),
  created_by  uuid default cma.current_user_id(),
  check (valid_to is null or valid_to >= valid_from),
  unique (tenant_id, id),
  foreign key (tenant_id, user_id)    references cma.app_user (tenant_id, id),
  foreign key (tenant_id, skill_id)   references cma.skill (tenant_id, id),
  foreign key (tenant_id, created_by) references cma.app_user (tenant_id, id)
);
comment on table cma.user_skill is 'A person''s skill with its level from when to when (half-open). A changed level ends the row and starts a new one; nothing is overwritten';
create unique index if not exists user_skill_current_idx on cma.user_skill (tenant_id, user_id, skill_id) where valid_to is null;
create index if not exists user_skill_skill_idx on cma.user_skill (tenant_id, skill_id, valid_to);

-- A level must exist in the dimension's scale; a binary dimension takes no level
create or replace function cma.check_user_skill()
returns trigger
language plpgsql
as $$
declare
  v_dimension text;
  v_scaled    boolean;
begin
  select s.dimension into v_dimension from cma.skill s where s.tenant_id = new.tenant_id and s.id = new.skill_id;
  if v_dimension is null then
    raise exception 'skill % not found in the current tenant', new.skill_id using errcode = 'CMA02';
  end if;
  v_scaled := exists (select 1 from cma.skill_level l where l.tenant_id = new.tenant_id and l.dimension = v_dimension);
  if v_scaled and (new.level is null or not exists (
       select 1 from cma.skill_level l where l.tenant_id = new.tenant_id and l.dimension = v_dimension and l.level = new.level)) then
    raise exception 'skill dimension % needs a level from its scale, got %', v_dimension, new.level using errcode = 'CMA04';
  end if;
  if not v_scaled and new.level is not null then
    raise exception 'skill dimension % has no levels; it is held or not', v_dimension using errcode = 'CMA04';
  end if;
  return new;
end
$$;
create or replace trigger check_level before insert or update on cma.user_skill
  for each row execute function cma.check_user_skill();

select cma.setup_tenant_table('cma.team');
select cma.setup_tenant_table('cma.team_member');
select cma.setup_tenant_table('cma.skill');
select cma.setup_tenant_table('cma.skill_level');
select cma.setup_tenant_table('cma.user_skill');
-- Validity and status instead of deletes (the owner removes a row only by migration); the level
-- scale is plain configuration without history and may be replaced by set_skill_levels()
revoke delete on cma.team, cma.team_member, cma.skill, cma.user_skill from cma_app;

-- The default level scale for a new tenant: languages in four steps; work types and channels
-- binary until a tenant configures a scale
create or replace function cma.seed_default_skill_levels(p_tenant_id uuid)
returns void
language sql
as $$
  insert into cma.skill_level (tenant_id, dimension, level, name)
  values (p_tenant_id, 'language', 1, 'Basic'),
         (p_tenant_id, 'language', 2, 'Good'),
         (p_tenant_id, 'language', 3, 'Fluent'),
         (p_tenant_id, 'language', 4, 'Native')
  on conflict do nothing
$$;
revoke execute on function cma.seed_default_skill_levels(uuid) from public;

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
  return v_id;
end
$$;
revoke execute on function cma.create_tenant(text, text, text) from public;

-- Tenants that already exist get the language scale now, only where the dimension has none
do $$
declare
  t record;
begin
  for t in select id from cma.tenant loop
    if not exists (select 1 from cma.skill_level where tenant_id = t.id and dimension = 'language') then
      perform cma.seed_default_skill_levels(t.id);
    end if;
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. Who may manage whom
-- ---------------------------------------------------------------------------------------------

-- Like assert_permission, with any of several permissions
create or replace function cma.assert_any_permission(p_permissions text[])
returns uuid
language plpgsql stable
as $$
declare
  v_user uuid := cma.current_user_id();
  p      text;
begin
  if v_user is null then
    raise exception 'this needs app.user_id, the acting user' using errcode = 'CMA01';
  end if;
  if not exists (select 1 from cma.app_user
                 where tenant_id = cma.current_tenant_id() and id = v_user and status = 'active') then
    raise exception 'user % is not an active user of the current tenant', v_user using errcode = 'CMA01';
  end if;
  foreach p in array p_permissions loop
    if cma.has_permission(v_user, p) then
      return v_user;
    end if;
  end loop;
  raise exception 'user % lacks every permission of %', v_user, array_to_string(p_permissions, ', ') using errcode = 'CMA06';
end
$$;

-- A role is a managing role when it holds any of these; only users.manage_all may touch such
-- people or assign such roles
create or replace function cma.role_is_managing(p_role_id uuid)
returns boolean
language sql stable
as $$
  select exists (
    select 1 from cma.role_permission rp
    where rp.tenant_id = cma.current_tenant_id() and rp.role_id = p_role_id
      and rp.permission_key in ('users.manage_agents', 'users.manage_all', 'tenant.configure'))
$$;

-- True when the acting user may manage this person: users.manage_all, or users.manage_agents and
-- the person holds no managing role. False for an unknown person.
create or replace function cma.may_manage_user(p_user_id uuid)
returns boolean
language sql stable
as $$
  select exists (select 1 from cma.app_user u where u.tenant_id = cma.current_tenant_id() and u.id = p_user_id)
     and (cma.has_permission(cma.current_user_id(), 'users.manage_all')
          or (cma.has_permission(cma.current_user_id(), 'users.manage_agents')
              and not exists (select 1 from cma.user_role ur
                              where ur.tenant_id = cma.current_tenant_id() and ur.user_id = p_user_id
                                and cma.role_is_managing(ur.role_id))))
$$;

-- The acting user, or CMA02 for an unknown person and CMA06 when the acting user may not manage them
create or replace function cma.assert_may_manage(p_user_id uuid)
returns uuid
language plpgsql stable
as $$
declare
  v_user uuid := cma.assert_any_permission(array['users.manage_agents', 'users.manage_all']);
begin
  if not exists (select 1 from cma.app_user u where u.tenant_id = cma.current_tenant_id() and u.id = p_user_id) then
    raise exception 'user % not found in the current tenant', p_user_id using errcode = 'CMA02';
  end if;
  if not cma.may_manage_user(p_user_id) then
    raise exception 'user % may not manage user %', v_user, p_user_id using errcode = 'CMA06';
  end if;
  return v_user;
end
$$;

-- A role the acting user may assign: any for users.manage_all, a non-managing one otherwise
create or replace function cma.assert_role_assignable(p_role_key text)
returns uuid
language plpgsql stable
as $$
declare
  v_role uuid;
begin
  select id into v_role from cma.app_role where tenant_id = cma.current_tenant_id() and key = p_role_key;
  if v_role is null then
    raise exception 'role % not found in the current tenant', p_role_key using errcode = 'CMA02';
  end if;
  if cma.role_is_managing(v_role) and not cma.has_permission(cma.current_user_id(), 'users.manage_all') then
    raise exception 'role % is a managing role; assigning it needs users.manage_all', p_role_key using errcode = 'CMA06';
  end if;
  return v_role;
end
$$;

-- Refuses to take users.manage_all from its last active holder in the tenant
create or replace function cma.assert_not_last_admin(p_user_id uuid)
returns void
language plpgsql stable
as $$
begin
  if cma.has_permission(p_user_id, 'users.manage_all')
     and not exists (
       select 1 from cma.user_role ur
       join cma.role_permission rp on rp.tenant_id = ur.tenant_id and rp.role_id = ur.role_id
       join cma.app_user u on u.tenant_id = ur.tenant_id and u.id = ur.user_id
       where ur.tenant_id = cma.current_tenant_id() and rp.permission_key = 'users.manage_all'
         and ur.user_id <> p_user_id and u.status = 'active') then
    raise exception 'user % is the last active holder of users.manage_all in this tenant', p_user_id using errcode = 'CMA03';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Reads
-- ---------------------------------------------------------------------------------------------

-- The ladder for the role dropdown: every role of the tenant with whether the acting user may
-- assign it. Needs users.manage_agents or users.manage_all.
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
    where ar.tenant_id = cma.current_tenant_id()
    order by cardinality(array(select 1 from cma.role_permission rp where rp.tenant_id = ar.tenant_id and rp.role_id = ar.id)), ar.key;
end
$$;

-- The current teams of the tenant with their member count; any active user of the tenant
create or replace function cma.teams()
returns table (key text, name text, markets text[], sort_order integer, member_count integer)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_user uuid := cma.current_user_id();
begin
  if v_user is null then
    raise exception 'teams needs app.user_id, the acting user' using errcode = 'CMA01';
  end if;
  if not exists (select 1 from cma.app_user where tenant_id = cma.current_tenant_id() and id = v_user and status = 'active') then
    raise exception 'user % is not an active user of the current tenant', v_user using errcode = 'CMA01';
  end if;
  return query
    select t.key::text, t.name::text, t.markets, t.sort_order,
           (select count(*)::integer from cma.team_member m
            where m.tenant_id = t.tenant_id and m.team_id = t.id and m.valid_to is null)
    from cma.team t
    where t.tenant_id = cma.current_tenant_id() and t.valid_to is null
    order by t.sort_order, t.key;
end
$$;

-- The active employers of the tenant, for the Add a person dialog; any active user of the tenant
create or replace function cma.organisations()
returns table (key text, name text, timezone text)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_user uuid := cma.current_user_id();
begin
  if v_user is null then
    raise exception 'organisations needs app.user_id, the acting user' using errcode = 'CMA01';
  end if;
  if not exists (select 1 from cma.app_user where tenant_id = cma.current_tenant_id() and id = v_user and status = 'active') then
    raise exception 'user % is not an active user of the current tenant', v_user using errcode = 'CMA01';
  end if;
  return query
    select o.key::text, o.name::text, coalesce(o.timezone, t.timezone)::text
    from cma.organisation o
    join cma.tenant t on t.id = o.tenant_id
    where o.tenant_id = cma.current_tenant_id() and o.status = 'active'
    order by o.name, o.key;
end
$$;

-- The skill catalog with the level scale per dimension; any active user of the tenant
create or replace function cma.skills()
returns table (dimension text, key text, name text, sort_order integer, status text, levels jsonb)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_user uuid := cma.current_user_id();
begin
  if v_user is null then
    raise exception 'skills needs app.user_id, the acting user' using errcode = 'CMA01';
  end if;
  if not exists (select 1 from cma.app_user where tenant_id = cma.current_tenant_id() and id = v_user and status = 'active') then
    raise exception 'user % is not an active user of the current tenant', v_user using errcode = 'CMA01';
  end if;
  return query
    select s.dimension::text, s.key::text, s.name::text, s.sort_order, s.status::text,
           coalesce((select jsonb_agg(jsonb_build_object('level', l.level, 'name', l.name) order by l.level)
                     from cma.skill_level l where l.tenant_id = s.tenant_id and l.dimension = s.dimension), '[]'::jsonb)
    from cma.skill s
    where s.tenant_id = cma.current_tenant_id()
    order by case s.dimension when 'language' then 1 when 'work_type' then 2 else 3 end, s.sort_order, s.key;
end
$$;

-- Current team memberships of everyone, for the Live board's team filter and the roster. For
-- people who watch or plan the team.
create or replace function cma.team_members_now()
returns table (user_id uuid, team_key text, team_name text)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_any_permission(array['monitoring.live', 'workday.team', 'roster.manage', 'users.manage_agents', 'users.manage_all']);
  return query
    select m.user_id, t.key::text, t.name::text
    from cma.team_member m
    join cma.team t on t.tenant_id = m.tenant_id and t.id = m.team_id
    where m.tenant_id = cma.current_tenant_id() and m.valid_to is null and t.valid_to is null
    order by t.sort_order, t.key, m.user_id;
end
$$;

-- The people the acting user may see on the Team screen: everyone for users.manage_all; for
-- users.manage_agents the people without a managing role, plus themselves (read-only). Inactive
-- people included, so they can be reactivated. One row per person with role, employer, zone, whether time is kept, teams and
-- skills as JSON, and whether the acting user may edit this person.
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
      -- the earliest grant, as the login shows it (findPrincipal); whether any grant is managing
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
      and (v_all or u.id = v_user or not coalesce(r.is_managing, false))
    order by (u.status <> 'active'), u.display_name, u.id;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. Writes
-- ---------------------------------------------------------------------------------------------

-- Adds a person with a login id and one role. Rerun-safe: the same person with the same login id
-- answers their id; a different id for an existing person, a login id of another person, or an
-- inactive person are refused (CMA03), so nothing is relinked or reactivated by accident. The
-- login id is stored as given (trimmed); which form it has (a numeric account id, a user name)
-- is the identity provider's business, checked by the caller.
create or replace function cma.add_person(
  p_email             text,
  p_display_name      text,
  p_organisation_key  text,
  p_role_key          text,
  p_login_system      text,
  p_login_id          text,
  p_timezone          text default null
)
returns uuid
language plpgsql
as $$
declare
  v_actor   uuid := cma.assert_any_permission(array['users.manage_agents', 'users.manage_all']);
  v_tenant  uuid := cma.current_tenant_id();
  v_email   text := lower(btrim(coalesce(p_email, '')));
  v_name    text := btrim(coalesce(p_display_name, ''));
  v_login   text := btrim(coalesce(p_login_id, ''));
  v_system  text := lower(btrim(coalesce(p_login_system, '')));
  v_org     uuid;
  v_role    uuid;
  v_user    uuid;
  v_status  text;
  v_owner   uuid;
  v_current text;
begin
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'email % is not an email address', p_email using errcode = 'CMA04';
  end if;
  if length(v_name) < 1 or length(v_name) > 100 then
    raise exception 'the display name must be 1 to 100 characters' using errcode = 'CMA04';
  end if;
  if v_system !~ '^[a-z0-9_]+$' then
    raise exception 'login system % must be a token such as google or mock', p_login_system using errcode = 'CMA04';
  end if;
  if v_login = '' or length(v_login) > 200 or v_login ~ '[[:space:]]' then
    raise exception 'the login id must be 1 to 200 characters without spaces' using errcode = 'CMA04';
  end if;
  if p_timezone is not null and not cma.is_timezone(p_timezone) then
    raise exception '% is not a time zone Postgres knows', p_timezone using errcode = 'CMA04';
  end if;
  select id into v_org from cma.organisation where tenant_id = v_tenant and key = p_organisation_key and status = 'active';
  if v_org is null then
    raise exception 'no active employer % in the current tenant', p_organisation_key using errcode = 'CMA02';
  end if;
  v_role := cma.assert_role_assignable(p_role_key);

  select u.id, u.status into v_user, v_status from cma.app_user u where u.tenant_id = v_tenant and u.email = v_email;
  if v_user is not null and v_status <> 'active' then
    raise exception '% exists but is inactive; reactivating is a separate step', v_email using errcode = 'CMA03';
  end if;

  select x.user_id into v_owner from cma.app_user_external_id x
  where x.tenant_id = v_tenant and x.system = v_system and x.external_id = v_login;
  if v_owner is not null and v_owner is distinct from v_user then
    raise exception 'this login id already belongs to another person in the current tenant' using errcode = 'CMA03';
  end if;

  if v_user is not null then
    select x.external_id into v_current from cma.app_user_external_id x
    where x.tenant_id = v_tenant and x.user_id = v_user and x.system = v_system;
    if v_current is not null and v_current <> v_login then
      raise exception '% already has a different % login id; changing it is a separate step', v_email, v_system using errcode = 'CMA03';
    end if;
    if v_current is null then
      insert into cma.app_user_external_id (tenant_id, user_id, system, external_id) values (v_tenant, v_user, v_system, v_login);
    end if;
    return v_user;   -- rerun: the same person, nothing else changes
  end if;

  insert into cma.app_user (tenant_id, organisation_id, email, display_name, timezone)
  values (v_tenant, v_org, v_email, v_name, p_timezone)
  returning id into v_user;
  insert into cma.app_user_external_id (tenant_id, user_id, system, external_id) values (v_tenant, v_user, v_system, v_login);
  insert into cma.user_role (tenant_id, user_id, role_id, granted_by) values (v_tenant, v_user, v_role, v_actor);
  return v_user;
end
$$;

-- One role per person: every grant of the person is replaced by this one (the history stays in
-- the audit log). Nobody changes their own role; a managing role needs users.manage_all; the last
-- holder of users.manage_all keeps it.
create or replace function cma.set_person_role(p_user_id uuid, p_role_key text)
returns text
language plpgsql
as $$
declare
  v_actor uuid := cma.assert_may_manage(p_user_id);
  v_role  uuid := cma.assert_role_assignable(p_role_key);
begin
  if p_user_id = v_actor then
    raise exception 'nobody changes their own role' using errcode = 'CMA06';
  end if;
  if not exists (select 1 from cma.role_permission rp where rp.tenant_id = cma.current_tenant_id() and rp.role_id = v_role
                 and rp.permission_key = 'users.manage_all') then
    perform cma.assert_not_last_admin(p_user_id);
  end if;
  if exists (select 1 from cma.user_role ur where ur.tenant_id = cma.current_tenant_id() and ur.user_id = p_user_id
             and ur.role_id = v_role and ur.scope_type is null)
     and (select count(*) from cma.user_role ur where ur.tenant_id = cma.current_tenant_id() and ur.user_id = p_user_id) = 1 then
    return p_role_key;   -- already exactly this role
  end if;
  delete from cma.user_role where tenant_id = cma.current_tenant_id() and user_id = p_user_id;
  insert into cma.user_role (tenant_id, user_id, role_id, granted_by) values (cma.current_tenant_id(), p_user_id, v_role, v_actor);
  return p_role_key;
end
$$;

-- Deactivate or reactivate. Nobody deactivates themselves; the last active holder of
-- users.manage_all stays active. An inactive person keeps their rows, roles, teams and skills, so
-- reactivation restores them; their time history depends on the row.
create or replace function cma.set_person_active(p_user_id uuid, p_active boolean)
returns text
language plpgsql
as $$
declare
  v_actor uuid := cma.assert_may_manage(p_user_id);
begin
  if p_user_id = v_actor and not p_active then
    raise exception 'nobody deactivates themselves' using errcode = 'CMA06';
  end if;
  if not p_active then
    perform cma.assert_not_last_admin(p_user_id);
  end if;
  update cma.app_user set status = case when p_active then 'active' else 'inactive' end
  where tenant_id = cma.current_tenant_id() and id = p_user_id
    and status is distinct from case when p_active then 'active' else 'inactive' end;
  return case when p_active then 'active' else 'inactive' end;
end
$$;

-- The full list of a person's teams. Memberships not in the list end now; new ones start now;
-- unchanged ones stay. Unknown or dissolved team: CMA02.
create or replace function cma.set_person_teams(p_user_id uuid, p_team_keys text[])
returns table (key text, name text)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_actor uuid := cma.assert_may_manage(p_user_id);
  v_keys  text[] := coalesce(p_team_keys, '{}');
  k       text;
begin
  foreach k in array v_keys loop
    if not exists (select 1 from cma.team t where t.tenant_id = cma.current_tenant_id() and t.key = k and t.valid_to is null) then
      raise exception 'team % not found in the current tenant', k using errcode = 'CMA02';
    end if;
  end loop;

  update cma.team_member m set valid_to = now()
  from cma.team t
  where t.tenant_id = m.tenant_id and t.id = m.team_id
    and m.tenant_id = cma.current_tenant_id() and m.user_id = p_user_id and m.valid_to is null
    and not (t.key = any (v_keys));

  insert into cma.team_member (tenant_id, user_id, team_id, created_by)
  select cma.current_tenant_id(), p_user_id, t.id, v_actor
  from cma.team t
  where t.tenant_id = cma.current_tenant_id() and t.key = any (v_keys) and t.valid_to is null
    and not exists (select 1 from cma.team_member m where m.tenant_id = t.tenant_id and m.team_id = t.id
                    and m.user_id = p_user_id and m.valid_to is null);

  return query
    select t.key::text, t.name::text
    from cma.team_member m
    join cma.team t on t.tenant_id = m.tenant_id and t.id = m.team_id
    where m.tenant_id = cma.current_tenant_id() and m.user_id = p_user_id and m.valid_to is null
    order by t.sort_order, t.key;
end
$$;

-- The full list of a person's skills as [{ "key": "...", "level": n }] (level null for a binary
-- dimension). Skills not in the list end now; a changed level ends the row and starts a new one;
-- unchanged ones stay. Needs skills.manage besides the right to manage the person.
create or replace function cma.set_person_skills(p_user_id uuid, p_skills jsonb)
returns table (dimension text, key text, name text, level smallint, level_name text)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_actor uuid := cma.assert_may_manage(p_user_id);
  item    jsonb;
  v_key   text;
  v_level smallint;
  v_skill uuid;
  v_cur   smallint;
  v_has   boolean;
  v_keys  text[] := '{}';
begin
  perform cma.assert_permission('skills.manage');
  if p_skills is null or jsonb_typeof(p_skills) <> 'array' then
    raise exception 'skills must be a JSON array of { key, level }' using errcode = 'CMA04';
  end if;

  for item in select * from jsonb_array_elements(p_skills) loop
    v_key := item ->> 'key';
    if item ? 'level' and jsonb_typeof(item -> 'level') = 'number' then
      v_level := (item ->> 'level')::smallint;
    else
      v_level := null;
    end if;
    select s.id into v_skill from cma.skill s
    where s.tenant_id = cma.current_tenant_id() and s.key = v_key and s.status = 'active';
    if v_skill is null then
      raise exception 'skill % not found or inactive in the current tenant', v_key using errcode = 'CMA02';
    end if;
    v_keys := v_keys || v_key;

    select us.level, true into v_cur, v_has from cma.user_skill us
    where us.tenant_id = cma.current_tenant_id() and us.user_id = p_user_id and us.skill_id = v_skill and us.valid_to is null;
    if coalesce(v_has, false) and v_cur is not distinct from v_level then
      v_has := null; v_cur := null;
      continue;   -- unchanged
    end if;
    if coalesce(v_has, false) then
      update cma.user_skill us set valid_to = now()
      where us.tenant_id = cma.current_tenant_id() and us.user_id = p_user_id and us.skill_id = v_skill and us.valid_to is null;
    end if;
    insert into cma.user_skill (tenant_id, user_id, skill_id, level, created_by)
    values (cma.current_tenant_id(), p_user_id, v_skill, v_level, v_actor);
    v_has := null; v_cur := null;
  end loop;

  -- what is not in the list ends now
  update cma.user_skill us set valid_to = now()
  from cma.skill s
  where s.tenant_id = us.tenant_id and s.id = us.skill_id
    and us.tenant_id = cma.current_tenant_id() and us.user_id = p_user_id and us.valid_to is null
    and not (s.key = any (v_keys));

  return query
    select s.dimension::text, s.key::text, s.name::text, us.level, l.name::text
    from cma.user_skill us
    join cma.skill s on s.tenant_id = us.tenant_id and s.id = us.skill_id
    left join cma.skill_level l on l.tenant_id = s.tenant_id and l.dimension = s.dimension and l.level = us.level
    where us.tenant_id = cma.current_tenant_id() and us.user_id = p_user_id and us.valid_to is null
    order by case s.dimension when 'language' then 1 when 'work_type' then 2 else 3 end, s.sort_order, s.key;
end
$$;

-- Catalog maintenance (tenant.configure), for the configuration screens of Roadmap step 5
create or replace function cma.upsert_team(p_key text, p_name text, p_markets text[], p_sort_order integer default 100)
returns uuid
language plpgsql
as $$
declare
  v_id uuid;
begin
  perform cma.assert_permission('tenant.configure');
  insert into cma.team as t (tenant_id, key, name, markets, sort_order)
  values (cma.current_tenant_id(), p_key, p_name, array(select distinct m from unnest(coalesce(p_markets, '{}')) m order by m), coalesce(p_sort_order, 100))
  on conflict (tenant_id, key) do update
    set name = excluded.name, markets = excluded.markets, sort_order = excluded.sort_order, valid_to = null
    where t.name is distinct from excluded.name or t.markets is distinct from excluded.markets
       or t.sort_order is distinct from excluded.sort_order or t.valid_to is not null
  returning id into v_id;
  if v_id is null then
    select id into v_id from cma.team where tenant_id = cma.current_tenant_id() and key = p_key;
  end if;
  return v_id;
end
$$;

create or replace function cma.dissolve_team(p_key text)
returns void
language plpgsql
as $$
declare
  v_id uuid;
begin
  perform cma.assert_permission('tenant.configure');
  select id into v_id from cma.team where tenant_id = cma.current_tenant_id() and key = p_key and valid_to is null;
  if v_id is null then
    raise exception 'team % not found in the current tenant', p_key using errcode = 'CMA02';
  end if;
  update cma.team_member set valid_to = now() where tenant_id = cma.current_tenant_id() and team_id = v_id and valid_to is null;
  update cma.team set valid_to = now() where tenant_id = cma.current_tenant_id() and id = v_id;
end
$$;

create or replace function cma.upsert_skill(p_dimension text, p_key text, p_name text, p_sort_order integer default 100, p_status text default 'active')
returns uuid
language plpgsql
as $$
declare
  v_id uuid;
begin
  perform cma.assert_permission('tenant.configure');
  insert into cma.skill as s (tenant_id, dimension, key, name, sort_order, status)
  values (cma.current_tenant_id(), p_dimension, p_key, p_name, coalesce(p_sort_order, 100), coalesce(p_status, 'active'))
  on conflict (tenant_id, dimension, key) do update
    set name = excluded.name, sort_order = excluded.sort_order, status = excluded.status
    where s.name is distinct from excluded.name or s.sort_order is distinct from excluded.sort_order
       or s.status is distinct from excluded.status
  returning id into v_id;
  if v_id is null then
    select id into v_id from cma.skill where tenant_id = cma.current_tenant_id() and dimension = p_dimension and key = p_key;
  end if;
  return v_id;
end
$$;

-- Replaces a dimension's scale with [{ "level": n, "name": "..." }]; an empty array makes the
-- dimension binary. Refused while a current user_skill holds a level that would disappear.
create or replace function cma.set_skill_levels(p_dimension text, p_levels jsonb)
returns table (level smallint, name text)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_keep smallint[];
begin
  perform cma.assert_permission('tenant.configure');
  if p_dimension not in ('language', 'work_type', 'channel') then
    raise exception 'dimension % is not language, work_type or channel', p_dimension using errcode = 'CMA04';
  end if;
  if p_levels is null or jsonb_typeof(p_levels) <> 'array' then
    raise exception 'levels must be a JSON array of { level, name }' using errcode = 'CMA04';
  end if;
  v_keep := array(select (e ->> 'level')::smallint from jsonb_array_elements(p_levels) e);
  if exists (select 1 from cma.user_skill us
             join cma.skill s on s.tenant_id = us.tenant_id and s.id = us.skill_id
             where us.tenant_id = cma.current_tenant_id() and s.dimension = p_dimension and us.valid_to is null
               and (((us.level is null) = (cardinality(v_keep) > 0))        -- binary becomes scaled or the reverse
                    or (us.level is not null and not (us.level = any (v_keep))))) then
    raise exception 'people hold levels of % that the new scale leaves out; end those skills first', p_dimension using errcode = 'CMA03';
  end if;
  delete from cma.skill_level where tenant_id = cma.current_tenant_id() and dimension = p_dimension;
  insert into cma.skill_level (tenant_id, dimension, level, name)
  select cma.current_tenant_id(), p_dimension, (e ->> 'level')::smallint, e ->> 'name'
  from jsonb_array_elements(p_levels) e;
  return query
    select l.level, l.name::text from cma.skill_level l
    where l.tenant_id = cma.current_tenant_id() and l.dimension = p_dimension order by l.level;
end
$$;
-- ---------------------------------------------------------------------------------------------
-- 6. Privileges on the functions: the application only
-- ---------------------------------------------------------------------------------------------
revoke execute on function
  cma.check_user_skill(), cma.assert_any_permission(text[]), cma.role_is_managing(uuid), cma.may_manage_user(uuid),
  cma.assert_may_manage(uuid), cma.assert_role_assignable(text), cma.assert_not_last_admin(uuid),
  cma.roles(), cma.teams(), cma.skills(), cma.organisations(), cma.team_members_now(), cma.directory(),
  cma.add_person(text, text, text, text, text, text, text), cma.set_person_role(uuid, text),
  cma.set_person_active(uuid, boolean), cma.set_person_teams(uuid, text[]), cma.set_person_skills(uuid, jsonb),
  cma.upsert_team(text, text, text[], integer), cma.dissolve_team(text),
  cma.upsert_skill(text, text, text, integer, text), cma.set_skill_levels(text, jsonb)
from public;
grant execute on function
  cma.assert_any_permission(text[]), cma.role_is_managing(uuid), cma.may_manage_user(uuid),
  cma.assert_may_manage(uuid), cma.assert_role_assignable(text), cma.assert_not_last_admin(uuid),
  cma.roles(), cma.teams(), cma.skills(), cma.organisations(), cma.team_members_now(), cma.directory(),
  cma.add_person(text, text, text, text, text, text, text), cma.set_person_role(uuid, text),
  cma.set_person_active(uuid, boolean), cma.set_person_teams(uuid, text[]), cma.set_person_skills(uuid, jsonb),
  cma.upsert_team(text, text, text[], integer), cma.dissolve_team(text),
  cma.upsert_skill(text, text, text, integer, text), cma.set_skill_levels(text, jsonb)
to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 7. Reporting views
-- ---------------------------------------------------------------------------------------------
create or replace view cma_read.team as
  select id, tenant_id, key, name, markets, sort_order, valid_from, valid_to, created_at, updated_at
  from cma.team
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.team_member as
  select id, tenant_id, user_id, team_id, valid_from, valid_to, created_at, created_by
  from cma.team_member
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.skill as
  select id, tenant_id, dimension, key, name, sort_order, status, created_at, updated_at
  from cma.skill
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.skill_level as
  select tenant_id, dimension, level, name
  from cma.skill_level
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.user_skill as
  select id, tenant_id, user_id, skill_id, level, valid_from, valid_to, created_at, created_by
  from cma.user_skill
  where cma_read.reader_sees(tenant_id);

-- ---------------------------------------------------------------------------------------------
-- 8. Record the migration
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0004', 'Teams and skills: team, team_member, skill, skill_level, user_skill; the admin role, users.manage split into users.manage_agents and users.manage_all; directory, add_person and the people and catalog functions')
on conflict (version) do nothing;

reset role;
