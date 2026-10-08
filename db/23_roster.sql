-- =============================================================================================
-- 23_roster.sql: migration 0005, the roster
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 21_teams_skills.sql (0004). Rerunnable. Run as your own IAM login, dev first, then prod; then
-- 25_verify_roster.sql; in dev 24_seed_dev_roster.sql before the verify.
--
-- Model (README Features 2, Planned migrations 0005; the night build's defaults of 7 October 2026)
--   cma.absence_type          the tenant's absence types with is_paid: off (a planned day off), leave,
--                             sick, public holiday, other by default; nothing medical beyond the word,
--                             no reasons stored
--   cma.roster_week           one roster per week per team, or for the whole tenant when team_id is
--                             null; draft until first published, then published; version counts the
--                             publications; editing a published week leaves it published and makes a
--                             new publish necessary (the agent keeps seeing the last publication)
--   cma.roster_publication    every publish with its instant and person, so what agents saw at any
--                             time is reconstructable from the versioned entries
--   cma.roster_entry          one cell, versioned: a shift (start and end in the person's zone, within
--                             the business day, 00:00 to 24:00, no midnight crossing: README decision of
--                             7 October) or an absence; a change ends the row (valid_to) and inserts a
--                             new one, a clear ends it; at most one current entry per person per
--                             business date across every roster of the tenant
--   cma.coverage_target       how many people with a work type a team wants on a weekday; the planner
--                             shows planned against target and how deeply each work type is covered
--   roster.adherence_tolerance_minutes   tenant setting (default 5) for the Live board's late and
--                             left-early flags
--   functions                 the planner's reads and writes (roster.manage), the agent's own schedule
--                             (roster.view, published only), today's shift per person for the Live board
--                             (monitoring.live), coverage, the catalogs; every function checks its
--                             permission inside and runs with the caller's rights
--   views                     cma.roster_published_entry (the entries as agents see them, as of each
--                             week's latest publication) as owner-only core with a tenant face and a
--                             reader face; reporting views for every table
--
-- SQLSTATEs as before: CMA01 no acting user, CMA02 not found, CMA03 conflict (the person already has
-- an entry on that date in another roster), CMA04 invalid (the past, a date outside the week, bad
-- times), CMA06 not permitted.
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
  if not exists (select 1 from cma.schema_migration where version = '0004') then
    raise exception 'migration 0004 (21_teams_skills.sql) must run before 0005';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------------------------

create table if not exists cma.absence_type (
  id          uuid primary key default uuidv7(),
  tenant_id   uuid not null default cma.current_tenant_id() references cma.tenant (id),
  key         text not null check (key ~ '^[a-z0-9_]+$'),
  name        text not null check (length(btrim(name)) between 1 and 40),
  is_paid     boolean not null default false,
  sort_order  integer not null default 100,
  status      text not null default 'active' check (status in ('active', 'inactive')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, key)
);
comment on table cma.absence_type is 'Absence types a roster cell can hold, per tenant: a planned day off, leave, sick, public holiday, other by default. is_paid is the semantic flag for planned paid time; no reasons, nothing medical beyond the word';
create or replace trigger set_updated_at before update on cma.absence_type
  for each row execute function cma.set_updated_at();

create table if not exists cma.roster_week (
  id            uuid primary key default uuidv7(),
  tenant_id     uuid not null default cma.current_tenant_id() references cma.tenant (id),
  team_id       uuid,                                   -- null: the whole tenant
  week_start    date not null check (extract(isodow from week_start) = 1),
  status        text not null default 'draft' check (status in ('draft', 'published')),
  version       integer not null default 0 check (version >= 0),
  published_at  timestamptz,
  published_by  uuid,
  created_at    timestamptz not null default now(),
  created_by    uuid default cma.current_user_id(),
  updated_at    timestamptz not null default now(),
  unique (tenant_id, id),
  unique nulls not distinct (tenant_id, team_id, week_start),
  foreign key (tenant_id, team_id)      references cma.team (tenant_id, id),
  foreign key (tenant_id, published_by) references cma.app_user (tenant_id, id),
  foreign key (tenant_id, created_by)   references cma.app_user (tenant_id, id),
  check ((status = 'published') = (published_at is not null)),
  check ((status = 'published') = (version > 0))
);
comment on table cma.roster_week is 'One roster per week (Monday) per team, or for the whole tenant when team_id is null. Draft until first published; version counts the publications; published_at is the instant agents read the week as of';
create or replace trigger set_updated_at before update on cma.roster_week
  for each row execute function cma.set_updated_at();
create index if not exists roster_week_week_idx on cma.roster_week (tenant_id, week_start);

create table if not exists cma.roster_publication (
  id              uuid primary key default uuidv7(),
  tenant_id       uuid not null default cma.current_tenant_id() references cma.tenant (id),
  roster_week_id  uuid not null,
  version         integer not null check (version > 0),
  published_at    timestamptz not null default clock_timestamp(),   -- a real instant: a publish and an edit in one transaction still order
  published_by    uuid default cma.current_user_id(),
  unique (tenant_id, id),
  unique (tenant_id, roster_week_id, version),
  foreign key (tenant_id, roster_week_id) references cma.roster_week (tenant_id, id),
  foreign key (tenant_id, published_by)   references cma.app_user (tenant_id, id)
);
comment on table cma.roster_publication is 'Every publication of a roster week, with its instant and person. Insert-only: with the versioned entries it reconstructs what agents saw at any time';

create table if not exists cma.roster_entry (
  id               uuid primary key default uuidv7(),
  tenant_id        uuid not null default cma.current_tenant_id() references cma.tenant (id),
  roster_week_id   uuid not null,
  user_id          uuid not null,
  business_date    date not null,
  kind             text not null check (kind in ('shift', 'absence')),
  start_time       time,                               -- local time in the person's zone
  end_time         time,                               -- up to 24:00, the end of the business day
  absence_type_id  uuid,
  note             text check (note is null or length(btrim(note)) between 1 and 120),
  recorded_at      timestamptz not null default clock_timestamp(),  -- as published_at
  recorded_by      uuid default cma.current_user_id(),
  valid_to         timestamptz,                        -- when superseded or cleared; null while current
  superseded_by    uuid,                               -- the entry that replaced it; null when cleared
  unique (tenant_id, id),
  foreign key (tenant_id, roster_week_id)  references cma.roster_week (tenant_id, id),
  foreign key (tenant_id, user_id)         references cma.app_user (tenant_id, id),
  foreign key (tenant_id, absence_type_id) references cma.absence_type (tenant_id, id),
  foreign key (tenant_id, recorded_by)     references cma.app_user (tenant_id, id),
  foreign key (tenant_id, superseded_by)   references cma.roster_entry (tenant_id, id),
  check (
    (kind = 'shift' and start_time is not null and end_time is not null and end_time > start_time and absence_type_id is null)
    or
    (kind = 'absence' and absence_type_id is not null and start_time is null and end_time is null)
  ),
  check (valid_to is null or valid_to >= recorded_at)
);
comment on table cma.roster_entry is 'One roster cell, versioned: a shift (start and end as local times in the person''s zone, within the business day) or an absence. A change ends the row and inserts a new one; a clear ends it. At most one current entry per person per business date in the whole tenant';
comment on column cma.roster_entry.note is 'A short planner note on the cell (a location, a training title); never a medical or personal reason';
create unique index if not exists roster_entry_current_idx
  on cma.roster_entry (tenant_id, user_id, business_date) where valid_to is null;
create index if not exists roster_entry_week_idx on cma.roster_entry (tenant_id, roster_week_id, business_date);
create index if not exists roster_entry_user_idx on cma.roster_entry (tenant_id, user_id, business_date);

create table if not exists cma.coverage_target (
  tenant_id   uuid not null default cma.current_tenant_id() references cma.tenant (id),
  team_id     uuid not null,
  skill_id    uuid not null,
  weekday     smallint not null check (weekday between 1 and 7),   -- ISO: 1 Monday, 7 Sunday
  min_count   integer not null check (min_count >= 0),
  updated_at  timestamptz not null default now(),
  updated_by  uuid default cma.current_user_id(),
  primary key (tenant_id, team_id, skill_id, weekday),
  foreign key (tenant_id, team_id)    references cma.team (tenant_id, id),
  foreign key (tenant_id, skill_id)   references cma.skill (tenant_id, id),
  foreign key (tenant_id, updated_by) references cma.app_user (tenant_id, id)
);
comment on table cma.coverage_target is 'How many people with a skill (a work type) a team wants on shift per weekday. The planner shows planned against target';
create or replace trigger set_updated_at before update on cma.coverage_target
  for each row execute function cma.set_updated_at();

select cma.setup_tenant_table('cma.absence_type');
select cma.setup_tenant_table('cma.roster_week');
select cma.setup_tenant_table('cma.roster_publication');
select cma.setup_tenant_table('cma.roster_entry');
select cma.setup_tenant_table('cma.coverage_target');

-- Append-only where the convention says so: a current entry is ended by setting valid_to and
-- superseded_by, nothing else changes; publications are never changed; the application writes
-- only through the functions below, which run with the caller's rights, so cma_app keeps update
-- on roster_entry for exactly that column pair and no delete anywhere.
revoke update, delete on cma.absence_type, cma.roster_week, cma.roster_publication, cma.roster_entry, cma.coverage_target from cma_app;
grant update (status, version, published_at, published_by) on cma.roster_week to cma_app;
grant update (valid_to, superseded_by) on cma.roster_entry to cma_app;
grant update (min_count) on cma.coverage_target to cma_app;
grant delete on cma.coverage_target to cma_app;
grant update (name, is_paid, sort_order, status) on cma.absence_type to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 2. The tenant setting for adherence
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('roster.adherence_tolerance_minutes', 'integer', null, '5',
     'Minutes a clock-in may be after the planned start, or a clock-out before the planned end, before the Live board flags it')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- ---------------------------------------------------------------------------------------------
-- 3. Default absence types, for new tenants and existing ones
-- ---------------------------------------------------------------------------------------------
create or replace function cma.seed_default_absence_types(p_tenant_id uuid)
returns void
language plpgsql
as $$
begin
  insert into cma.absence_type (tenant_id, key, name, is_paid, sort_order)
  values
    (p_tenant_id, 'off',            'Day off',        false, 10),
    (p_tenant_id, 'leave',          'Leave',          true,  20),
    (p_tenant_id, 'sick',           'Sick',           true,  30),
    (p_tenant_id, 'public_holiday', 'Public holiday', true,  40),
    (p_tenant_id, 'other',          'Other',          false, 50)
  on conflict (tenant_id, key) do nothing;
end
$$;
revoke execute on function cma.seed_default_absence_types(uuid) from public;

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
  return v_id;
end
$$;
revoke execute on function cma.create_tenant(text, text, text) from public;

do $$
declare
  t record;
begin
  for t in select id from cma.tenant loop
    if not exists (select 1 from cma.absence_type where tenant_id = t.id) then
      perform cma.seed_default_absence_types(t.id);
    end if;
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Helpers
-- ---------------------------------------------------------------------------------------------

-- Monday on or before a date
create or replace function cma.week_start(p_date date)
returns date
language sql immutable parallel safe
as $$
  select p_date - (extract(isodow from p_date)::integer - 1)
$$;

-- The team row of a key, or null for the whole tenant; CMA02 for an unknown or dissolved team
create or replace function cma.roster_team_id(p_team_key text)
returns uuid
language plpgsql stable
as $$
declare
  v_id uuid;
begin
  if p_team_key is null or p_team_key = '' then
    return null;
  end if;
  select id into v_id from cma.team
   where tenant_id = cma.current_tenant_id() and key = p_team_key and valid_to is null;
  if v_id is null then
    raise exception 'team % does not exist in the current tenant', p_team_key using errcode = 'CMA02';
  end if;
  return v_id;
end
$$;

create or replace function cma.assert_week_start(p_week_start date)
returns void
language plpgsql immutable
as $$
begin
  if p_week_start is null or extract(isodow from p_week_start) <> 1 then
    raise exception 'a roster week starts on a Monday, % is not one', p_week_start using errcode = 'CMA04';
  end if;
end
$$;

-- Whether a person belongs on a roster: time is kept, and for a team roster the person is a
-- member at some point during the week (so a person who joins on Wednesday appears)
create or replace function cma.roster_in_scope(p_user_id uuid, p_team_id uuid, p_week_start date)
returns boolean
language sql stable
as $$
  select cma.time_is_kept(p_user_id)
     and (p_team_id is null
          or exists (select 1 from cma.team_member m
                     where m.tenant_id = cma.current_tenant_id() and m.user_id = p_user_id and m.team_id = p_team_id
                       and m.valid_from < (p_week_start + 7)::timestamp at time zone 'UTC' + interval '1 day'
                       and (m.valid_to is null or m.valid_to > p_week_start::timestamp at time zone 'UTC' - interval '1 day')))
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. Reads for the planner (roster.manage)
-- ---------------------------------------------------------------------------------------------

-- The week's header; a week that was never written has week_id null and status 'draft'
create or replace function cma.roster_week(p_week_start date, p_team_key text default null)
returns table (
  week_id               uuid,
  team_key              text,
  team_name             text,
  week_start            date,
  status                text,
  version               integer,
  published_at          timestamptz,
  published_by_name     text,
  entry_count           integer,
  changed_since_publish boolean
)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_team uuid;
begin
  perform cma.assert_permission('roster.manage');
  perform cma.assert_week_start(p_week_start);
  v_team := cma.roster_team_id(p_team_key);
  return query
    select w.id, t.key::text, t.name::text, p_week_start,
           coalesce(w.status, 'draft')::text, coalesce(w.version, 0), w.published_at, pb.display_name::text,
           coalesce((select count(*)::integer from cma.roster_entry e
                     where e.tenant_id = cma.current_tenant_id() and e.roster_week_id = w.id and e.valid_to is null), 0),
           coalesce(w.status = 'published'
                    and exists (select 1 from cma.roster_entry e
                                where e.tenant_id = cma.current_tenant_id() and e.roster_week_id = w.id
                                  and (e.recorded_at > w.published_at or e.valid_to > w.published_at)), false)
    from (select 1) one
    left join cma.team t on t.tenant_id = cma.current_tenant_id() and t.id = v_team
    left join cma.roster_week w on w.tenant_id = cma.current_tenant_id() and w.week_start = p_week_start
                               and w.team_id is not distinct from v_team
    left join cma.app_user pb on pb.tenant_id = cma.current_tenant_id() and pb.id = w.published_by;
end
$$;

-- The people on the week's grid: whose time is kept and, for a team roster, who is a member during
-- the week; with the work types they hold now (for coverage) and their other teams (for display)
create or replace function cma.roster_people(p_week_start date, p_team_key text default null)
returns table (
  user_id            uuid,
  display_name       text,
  organisation_name  text,
  timezone           text,
  team_keys          text[],
  work_type_keys     text[]
)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_team uuid;
begin
  perform cma.assert_permission('roster.manage');
  perform cma.assert_week_start(p_week_start);
  v_team := cma.roster_team_id(p_team_key);
  return query
    select u.id, u.display_name::text, coalesce(o.name, '')::text, cma.user_timezone(u.id)::text,
           coalesce((select array_agg(t.key order by t.sort_order, t.key) from cma.team_member m
                     join cma.team t on t.tenant_id = m.tenant_id and t.id = m.team_id
                     where m.tenant_id = u.tenant_id and m.user_id = u.id and m.valid_to is null and t.valid_to is null), '{}'::text[]),
           coalesce((select array_agg(s.key order by s.sort_order, s.key) from cma.user_skill us
                     join cma.skill s on s.tenant_id = us.tenant_id and s.id = us.skill_id
                     where us.tenant_id = u.tenant_id and us.user_id = u.id and us.valid_to is null
                       and s.dimension = 'work_type' and s.status = 'active'), '{}'::text[])
    from cma.app_user u
    left join cma.organisation o on o.tenant_id = u.tenant_id and o.id = u.organisation_id
    where u.tenant_id = cma.current_tenant_id()
      and cma.roster_in_scope(u.id, v_team, p_week_start)
    order by u.display_name, u.id;
end
$$;

-- The current entries of the week (what the planner edits), one per person per date
create or replace function cma.roster_entries(p_week_start date, p_team_key text default null)
returns table (
  entry_id        uuid,
  user_id         uuid,
  business_date   date,
  kind            text,
  start_time      time,
  end_time        time,
  absence_key     text,
  absence_name    text,
  note            text,
  recorded_at     timestamptz,
  recorded_by_name text
)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_team uuid;
begin
  perform cma.assert_permission('roster.manage');
  perform cma.assert_week_start(p_week_start);
  v_team := cma.roster_team_id(p_team_key);
  return query
    select e.id, e.user_id, e.business_date, e.kind::text, e.start_time, e.end_time,
           a.key::text, a.name::text, e.note::text, e.recorded_at, rb.display_name::text
    from cma.roster_entry e
    join cma.roster_week w on w.tenant_id = e.tenant_id and w.id = e.roster_week_id
    left join cma.absence_type a on a.tenant_id = e.tenant_id and a.id = e.absence_type_id
    left join cma.app_user rb on rb.tenant_id = e.tenant_id and rb.id = e.recorded_by
    where e.tenant_id = cma.current_tenant_id()
      and w.week_start = p_week_start and w.team_id is not distinct from v_team
      and e.valid_to is null
    order by e.business_date, e.user_id;
end
$$;

-- Weeks for browsing: one row per Monday in the range, with the week's state when it exists
create or replace function cma.roster_weeks(p_team_key text, p_from date, p_to date)
returns table (
  week_start    date,
  status        text,
  version       integer,
  published_at  timestamptz,
  entry_count   integer,
  shift_count   integer
)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_team uuid;
  v_first date;
  v_last  date;
begin
  perform cma.assert_permission('roster.manage');
  v_team := cma.roster_team_id(p_team_key);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 371 then
    raise exception 'the range must run forward and cover at most 53 weeks' using errcode = 'CMA04';
  end if;
  v_first := cma.week_start(p_from);
  v_last := cma.week_start(p_to);
  return query
    select d::date, coalesce(w.status, 'draft')::text, coalesce(w.version, 0), w.published_at,
           coalesce((select count(*)::integer from cma.roster_entry e where e.tenant_id = cma.current_tenant_id() and e.roster_week_id = w.id and e.valid_to is null), 0),
           coalesce((select count(*)::integer from cma.roster_entry e where e.tenant_id = cma.current_tenant_id() and e.roster_week_id = w.id and e.valid_to is null and e.kind = 'shift'), 0)
    from generate_series(v_first, v_last, interval '7 days') d
    left join cma.roster_week w on w.tenant_id = cma.current_tenant_id() and w.week_start = d::date and w.team_id is not distinct from v_team
    order by d;
end
$$;

-- Coverage per date and work type: how many planned people hold the work type that day, who they
-- are, and the team's target for that weekday when one is set. Skills as held now.
create or replace function cma.roster_coverage(p_week_start date, p_team_key text default null)
returns table (
  business_date  date,
  skill_key      text,
  skill_name     text,
  planned_people integer,
  people_names   text[],
  target         integer
)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_team uuid;
begin
  perform cma.assert_permission('roster.manage');
  perform cma.assert_week_start(p_week_start);
  v_team := cma.roster_team_id(p_team_key);
  return query
    select d::date, s.key::text, s.name::text,
           count(e.user_id)::integer,
           coalesce(array_agg(u.display_name order by u.display_name) filter (where e.user_id is not null), '{}'::text[]),
           ct.min_count
    from generate_series(p_week_start, p_week_start + 6, interval '1 day') d
    cross join cma.skill s
    left join cma.roster_week w on w.tenant_id = s.tenant_id and w.week_start = p_week_start and w.team_id is not distinct from v_team
    left join cma.roster_entry e on e.tenant_id = s.tenant_id and e.roster_week_id = w.id and e.business_date = d::date
                                and e.kind = 'shift' and e.valid_to is null
                                and exists (select 1 from cma.user_skill us
                                            where us.tenant_id = e.tenant_id and us.user_id = e.user_id and us.skill_id = s.id and us.valid_to is null)
    left join cma.app_user u on u.tenant_id = e.tenant_id and u.id = e.user_id
    left join cma.coverage_target ct on ct.tenant_id = s.tenant_id and ct.team_id = v_team and ct.skill_id = s.id
                                    and ct.weekday = extract(isodow from d)::smallint
    where s.tenant_id = cma.current_tenant_id() and s.dimension = 'work_type' and s.status = 'active'
    group by d, s.id, s.key, s.name, s.sort_order, ct.min_count
    order by d, s.sort_order, s.key;
end
$$;

create or replace function cma.coverage_targets(p_team_key text)
returns table (skill_key text, weekday smallint, min_count integer)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_team uuid;
begin
  perform cma.assert_permission('roster.manage');
  v_team := cma.roster_team_id(p_team_key);
  if v_team is null then
    raise exception 'coverage targets belong to a team' using errcode = 'CMA04';
  end if;
  return query
    select s.key::text, ct.weekday, ct.min_count
    from cma.coverage_target ct
    join cma.skill s on s.tenant_id = ct.tenant_id and s.id = ct.skill_id
    where ct.tenant_id = cma.current_tenant_id() and ct.team_id = v_team
    order by s.sort_order, s.key, ct.weekday;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. Writes for the planner (roster.manage)
-- ---------------------------------------------------------------------------------------------

-- The week row, created as a draft when it does not exist yet
create or replace function cma.roster_week_id(p_week_start date, p_team_id uuid)
returns uuid
language plpgsql
as $$
declare
  v_id uuid;
begin
  select id into v_id from cma.roster_week
   where tenant_id = cma.current_tenant_id() and week_start = p_week_start and team_id is not distinct from p_team_id
   for update;
  if v_id is null then
    insert into cma.roster_week (tenant_id, team_id, week_start)
    values (cma.current_tenant_id(), p_team_id, p_week_start)
    on conflict (tenant_id, team_id, week_start) do nothing
    returning id into v_id;
    if v_id is null then
      select id into v_id from cma.roster_week
       where tenant_id = cma.current_tenant_id() and week_start = p_week_start and team_id is not distinct from p_team_id
       for update;
    end if;
  end if;
  return v_id;
end
$$;

-- One cell: a shift (start and end), an absence (type), or nothing (p_kind null clears). The
-- person must be on the week's grid; the date in the week and not in the past in the person's
-- zone; an existing current entry of the same roster is superseded, one in another roster is a
-- conflict (CMA03). Returns the new current entry, or null when the cell was cleared.
create or replace function cma.roster_set_entry(
  p_week_start    date,
  p_team_key      text,
  p_user_id       uuid,
  p_business_date date,
  p_kind          text,
  p_start_time    time,
  p_end_time      time,
  p_absence_key   text,
  p_note          text default null
)
returns cma.roster_entry
language plpgsql
as $$
declare
  v_user    uuid;
  v_team    uuid;
  v_week    uuid;
  v_absence uuid;
  v_current cma.roster_entry;
  v_new     cma.roster_entry;
  v_other   text;
begin
  v_user := cma.assert_permission('roster.manage');
  perform cma.assert_week_start(p_week_start);
  v_team := cma.roster_team_id(p_team_key);

  if p_business_date is null or p_business_date < p_week_start or p_business_date > p_week_start + 6 then
    raise exception 'date % is not in the week of %', p_business_date, p_week_start using errcode = 'CMA04';
  end if;
  if p_user_id is null or not exists (select 1 from cma.app_user where tenant_id = cma.current_tenant_id() and id = p_user_id) then
    raise exception 'person % does not exist in the current tenant', p_user_id using errcode = 'CMA02';
  end if;
  if not cma.roster_in_scope(p_user_id, v_team, p_week_start) then
    raise exception 'person % is not on this roster (time not kept, or not a member of the team this week)', p_user_id using errcode = 'CMA04';
  end if;
  if p_business_date < cma.business_date(now(), cma.user_timezone(p_user_id)) then
    raise exception 'date % is in the past for this person; the roster plans today and ahead', p_business_date using errcode = 'CMA04';
  end if;
  if p_kind is not null and p_kind not in ('shift', 'absence') then
    raise exception 'kind must be shift, absence or null (clear)' using errcode = 'CMA04';
  end if;
  if p_kind = 'shift' and (p_start_time is null or p_end_time is null or p_end_time <= p_start_time) then
    raise exception 'a shift needs a start and a later end, within the day (00:00 to 24:00)' using errcode = 'CMA04';
  end if;
  if p_kind = 'absence' then
    select id into v_absence from cma.absence_type
     where tenant_id = cma.current_tenant_id() and key = p_absence_key and status = 'active';
    if v_absence is null then
      raise exception 'absence type % does not exist or is no longer in use', p_absence_key using errcode = 'CMA02';
    end if;
  end if;
  if p_note is not null and length(btrim(p_note)) not between 1 and 120 then
    raise exception 'a note has 1 to 120 characters' using errcode = 'CMA04';
  end if;

  v_week := cma.roster_week_id(p_week_start, v_team);

  select * into v_current from cma.roster_entry
   where tenant_id = cma.current_tenant_id() and user_id = p_user_id and business_date = p_business_date and valid_to is null
   for update;
  if v_current.id is not null and v_current.roster_week_id <> v_week then
    select coalesce(t.name, 'the whole business line') into v_other
    from cma.roster_week w left join cma.team t on t.tenant_id = w.tenant_id and t.id = w.team_id
    where w.tenant_id = cma.current_tenant_id() and w.id = v_current.roster_week_id;
    raise exception 'this person already has an entry on % in the roster of %', p_business_date, v_other using errcode = 'CMA03';
  end if;

  -- Nothing to do when the cell already holds exactly this
  if v_current.id is not null and p_kind is not null
     and v_current.kind = p_kind
     and v_current.start_time is not distinct from p_start_time
     and v_current.end_time is not distinct from p_end_time
     and v_current.absence_type_id is not distinct from v_absence
     and v_current.note is not distinct from nullif(btrim(coalesce(p_note, '')), '') then
    return v_current;
  end if;

  -- End the old version first: the unique index on current entries is checked per statement,
  -- so the old row must be ended before the new one is written
  if v_current.id is not null then
    update cma.roster_entry set valid_to = clock_timestamp()
     where tenant_id = cma.current_tenant_id() and id = v_current.id;
  end if;

  if p_kind is not null then
    insert into cma.roster_entry (tenant_id, roster_week_id, user_id, business_date, kind, start_time, end_time, absence_type_id, note)
    values (cma.current_tenant_id(), v_week, p_user_id, p_business_date, p_kind,
            case when p_kind = 'shift' then p_start_time end,
            case when p_kind = 'shift' then p_end_time end,
            v_absence, nullif(btrim(coalesce(p_note, '')), ''))
    returning * into v_new;
    if v_current.id is not null then
      update cma.roster_entry set superseded_by = v_new.id
       where tenant_id = cma.current_tenant_id() and id = v_current.id;
    end if;
  end if;
  return v_new;
end
$$;

-- Publish the week as it stands now: version + 1, the instant agents read it as of, a publication
-- row. A week that was never written is created and published empty (everyone off that week).
create or replace function cma.roster_publish(p_week_start date, p_team_key text default null)
returns cma.roster_week
language plpgsql
as $$
declare
  v_user uuid;
  v_team uuid;
  v_week uuid;
  w      cma.roster_week;
begin
  v_user := cma.assert_permission('roster.manage');
  perform cma.assert_week_start(p_week_start);
  v_team := cma.roster_team_id(p_team_key);
  v_week := cma.roster_week_id(p_week_start, v_team);

  update cma.roster_week
     set status = 'published', version = version + 1, published_at = clock_timestamp(), published_by = v_user
   where tenant_id = cma.current_tenant_id() and id = v_week
   returning * into w;

  insert into cma.roster_publication (tenant_id, roster_week_id, version, published_at, published_by)
  values (cma.current_tenant_id(), v_week, w.version, w.published_at, v_user);
  return w;
end
$$;

-- Copy the current entries of one week into another (same team scope): a source cell overwrites
-- the target cell, an empty source cell leaves the target alone; dates in the past for the person
-- and people no longer on the grid are skipped. Returns how many cells were written.
create or replace function cma.roster_copy_week(p_from_week_start date, p_to_week_start date, p_team_key text default null)
returns integer
language plpgsql
as $$
declare
  v_team uuid;
  r      record;
  n      integer := 0;
begin
  perform cma.assert_permission('roster.manage');
  perform cma.assert_week_start(p_from_week_start);
  perform cma.assert_week_start(p_to_week_start);
  if p_from_week_start = p_to_week_start then
    raise exception 'a week cannot be copied onto itself' using errcode = 'CMA04';
  end if;
  v_team := cma.roster_team_id(p_team_key);
  for r in
    select e.user_id, e.business_date, e.kind, e.start_time, e.end_time, a.key as absence_key, e.note
    from cma.roster_entry e
    join cma.roster_week w on w.tenant_id = e.tenant_id and w.id = e.roster_week_id
    left join cma.absence_type a on a.tenant_id = e.tenant_id and a.id = e.absence_type_id
    where e.tenant_id = cma.current_tenant_id() and e.valid_to is null
      and w.week_start = p_from_week_start and w.team_id is not distinct from v_team
    order by e.business_date, e.user_id
  loop
    declare
      v_date date := r.business_date + (p_to_week_start - p_from_week_start);
    begin
      if not cma.roster_in_scope(r.user_id, v_team, p_to_week_start) then continue; end if;
      if v_date < cma.business_date(now(), cma.user_timezone(r.user_id)) then continue; end if;
      if exists (select 1 from cma.roster_entry x join cma.roster_week xw on xw.tenant_id = x.tenant_id and xw.id = x.roster_week_id
                 where x.tenant_id = cma.current_tenant_id() and x.user_id = r.user_id and x.business_date = v_date and x.valid_to is null
                   and (xw.week_start <> p_to_week_start or xw.team_id is distinct from v_team)) then
        continue;   -- planned elsewhere already; the conflict is for the planner to see, not to overwrite
      end if;
      perform cma.roster_set_entry(p_to_week_start, p_team_key, r.user_id, v_date, r.kind, r.start_time, r.end_time, r.absence_key, r.note);
      n := n + 1;
    end;
  end loop;
  return n;
end
$$;

-- A team's wanted people per work type per weekday; null removes the target
create or replace function cma.set_coverage_target(p_team_key text, p_skill_key text, p_weekday smallint, p_min_count integer)
returns void
language plpgsql
as $$
declare
  v_team  uuid;
  v_skill uuid;
begin
  perform cma.assert_permission('roster.manage');
  v_team := cma.roster_team_id(p_team_key);
  if v_team is null then
    raise exception 'coverage targets belong to a team' using errcode = 'CMA04';
  end if;
  select id into v_skill from cma.skill
   where tenant_id = cma.current_tenant_id() and key = p_skill_key and dimension = 'work_type' and status = 'active';
  if v_skill is null then
    raise exception 'work type % does not exist in the current tenant', p_skill_key using errcode = 'CMA02';
  end if;
  if p_weekday is null or p_weekday not between 1 and 7 then
    raise exception 'weekday is 1 (Monday) to 7 (Sunday)' using errcode = 'CMA04';
  end if;
  if p_min_count is null then
    delete from cma.coverage_target
     where tenant_id = cma.current_tenant_id() and team_id = v_team and skill_id = v_skill and weekday = p_weekday;
  else
    if p_min_count < 0 then
      raise exception 'a target is 0 or more people' using errcode = 'CMA04';
    end if;
    insert into cma.coverage_target as ct (tenant_id, team_id, skill_id, weekday, min_count)
    values (cma.current_tenant_id(), v_team, v_skill, p_weekday, p_min_count)
    on conflict (tenant_id, team_id, skill_id, weekday) do update
      set min_count = excluded.min_count where ct.min_count <> excluded.min_count;
  end if;
end
$$;

-- The absence catalog: any active person of the tenant reads it; tenant.configure maintains it
create or replace function cma.absence_types()
returns table (key text, name text, is_paid boolean, sort_order integer, status text)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_user uuid := cma.current_user_id();
begin
  if v_user is null then
    raise exception 'absence_types needs app.user_id, the acting user' using errcode = 'CMA01';
  end if;
  if not exists (select 1 from cma.app_user where tenant_id = cma.current_tenant_id() and id = v_user and status = 'active') then
    raise exception 'user % is not an active user of the current tenant', v_user using errcode = 'CMA01';
  end if;
  return query
    select a.key::text, a.name::text, a.is_paid, a.sort_order, a.status::text
    from cma.absence_type a
    where a.tenant_id = cma.current_tenant_id()
    order by a.sort_order, a.key;
end
$$;

create or replace function cma.upsert_absence_type(p_key text, p_name text, p_is_paid boolean, p_sort_order integer default 100, p_status text default 'active')
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
  if p_status not in ('active', 'inactive') then
    raise exception 'status is active or inactive' using errcode = 'CMA04';
  end if;
  insert into cma.absence_type as a (tenant_id, key, name, is_paid, sort_order, status)
  values (cma.current_tenant_id(), p_key, btrim(p_name), p_is_paid, p_sort_order, p_status)
  on conflict (tenant_id, key) do update
    set name = excluded.name, is_paid = excluded.is_paid, sort_order = excluded.sort_order, status = excluded.status
    where (a.name, a.is_paid, a.sort_order, a.status) is distinct from (excluded.name, excluded.is_paid, excluded.sort_order, excluded.status);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. What agents and the Live board see: published entries only
-- ---------------------------------------------------------------------------------------------

-- The entries as of each week's latest publication: written before it and not ended before it.
-- Owner-only core; two faces below. A draft week contributes nothing.
create or replace view cma.roster_published_entry_all as
  select e.id, e.tenant_id, e.roster_week_id, w.team_id, w.week_start, w.version, w.published_at,
         e.user_id, e.business_date, e.kind, e.start_time, e.end_time, e.absence_type_id, e.note,
         e.recorded_at, e.recorded_by
  from cma.roster_entry e
  join cma.roster_week w on w.tenant_id = e.tenant_id and w.id = e.roster_week_id
  where w.status = 'published'
    and e.recorded_at <= w.published_at
    and (e.valid_to is null or e.valid_to > w.published_at);

-- The default privileges grant the app select on every new relation; the core is for the owner only
revoke all on cma.roster_published_entry_all from cma_app, cma_readonly, public;

create or replace view cma.roster_published_entry as
  select * from cma.roster_published_entry_all where tenant_id = cma.current_tenant_id();

-- The acting user's own published schedule: one row per date in the range; kind null when nothing
-- is planned; is_published says whether a published roster covers the person on that date at all
-- (a team roster counts when the person was a member at publication; a tenant roster always)
create or replace function cma.my_roster(p_from date, p_to date)
returns table (
  business_date  date,
  is_published   boolean,
  kind           text,
  start_time     time,
  end_time       time,
  absence_key    text,
  absence_name   text,
  note           text,
  team_name      text,
  published_at   timestamptz
)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_user uuid;
begin
  v_user := cma.assert_permission('roster.view');
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 91 then
    raise exception 'the range must run forward and cover at most 92 days' using errcode = 'CMA04';
  end if;
  return query
    select d::date,
           exists (select 1 from cma.roster_week w
                   where w.tenant_id = cma.current_tenant_id() and w.status = 'published'
                     and w.week_start <= d::date and d::date < w.week_start + 7
                     and (w.team_id is null
                          or exists (select 1 from cma.team_member m
                                     where m.tenant_id = w.tenant_id and m.user_id = v_user and m.team_id = w.team_id
                                       and m.valid_from <= w.published_at and (m.valid_to is null or m.valid_to > w.published_at)))),
           x.kind::text, x.start_time, x.end_time, x.absence_key, x.absence_name, x.note::text, x.team_name, x.published_at
    from generate_series(p_from, p_to, interval '1 day') d
    left join lateral (
      select e.kind, e.start_time, e.end_time, a.key::text as absence_key, a.name::text as absence_name, e.note,
             t.name::text as team_name, e.published_at
      from cma.roster_published_entry e
      left join cma.absence_type a on a.tenant_id = e.tenant_id and a.id = e.absence_type_id
      left join cma.team t on t.tenant_id = e.tenant_id and t.id = e.team_id
      where e.user_id = v_user and e.business_date = d::date
      order by e.published_at desc
      limit 1
    ) x on true
    order by d;
end
$$;

-- Today's published entry per person whose time is kept, in the person's zone, for the Live
-- board's shift line; monitoring.live
create or replace function cma.roster_today()
returns table (
  user_id        uuid,
  business_date  date,
  is_published   boolean,
  kind           text,
  start_time     time,
  end_time       time,
  absence_name   text
)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('monitoring.live');
  return query
    select u.id, tz.today,
           exists (select 1 from cma.roster_week w
                   where w.tenant_id = u.tenant_id and w.status = 'published'
                     and w.week_start <= tz.today and tz.today < w.week_start + 7
                     and (w.team_id is null
                          or exists (select 1 from cma.team_member m
                                     where m.tenant_id = w.tenant_id and m.user_id = u.id and m.team_id = w.team_id
                                       and m.valid_from <= w.published_at and (m.valid_to is null or m.valid_to > w.published_at)))),
           x.kind::text, x.start_time, x.end_time, x.absence_name
    from cma.app_user u
    cross join lateral (select cma.business_date(now(), cma.user_timezone(u.id)) as today) tz
    left join lateral (
      select e.kind, e.start_time, e.end_time, a.name::text as absence_name
      from cma.roster_published_entry e
      left join cma.absence_type a on a.tenant_id = e.tenant_id and a.id = e.absence_type_id
      where e.user_id = u.id and e.business_date = tz.today
      order by e.published_at desc
      limit 1
    ) x on true
    where u.tenant_id = cma.current_tenant_id()
      and cma.time_is_kept(u.id)
    order by u.display_name, u.id;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 8. Privileges on the functions: the application only
-- ---------------------------------------------------------------------------------------------
revoke execute on function
  cma.week_start(date), cma.roster_team_id(text), cma.assert_week_start(date), cma.roster_in_scope(uuid, uuid, date),
  cma.roster_week(date, text), cma.roster_people(date, text), cma.roster_entries(date, text),
  cma.roster_weeks(text, date, date), cma.roster_coverage(date, text), cma.coverage_targets(text),
  cma.roster_week_id(date, uuid),
  cma.roster_set_entry(date, text, uuid, date, text, time, time, text, text),
  cma.roster_publish(date, text), cma.roster_copy_week(date, date, text),
  cma.set_coverage_target(text, text, smallint, integer),
  cma.absence_types(), cma.upsert_absence_type(text, text, boolean, integer, text),
  cma.my_roster(date, date), cma.roster_today()
from public;
grant execute on function
  cma.week_start(date), cma.roster_team_id(text), cma.assert_week_start(date), cma.roster_in_scope(uuid, uuid, date),
  cma.roster_week(date, text), cma.roster_people(date, text), cma.roster_entries(date, text),
  cma.roster_weeks(text, date, date), cma.roster_coverage(date, text), cma.coverage_targets(text),
  cma.roster_week_id(date, uuid),
  cma.roster_set_entry(date, text, uuid, date, text, time, time, text, text),
  cma.roster_publish(date, text), cma.roster_copy_week(date, date, text),
  cma.set_coverage_target(text, text, smallint, integer),
  cma.absence_types(), cma.upsert_absence_type(text, text, boolean, integer, text),
  cma.my_roster(date, date), cma.roster_today()
to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 9. Reporting views
-- ---------------------------------------------------------------------------------------------
create or replace view cma_read.absence_type as
  select id, tenant_id, key, name, is_paid, sort_order, status, created_at, updated_at
  from cma.absence_type
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.roster_week as
  select id, tenant_id, team_id, week_start, status, version, published_at, published_by, created_at, created_by, updated_at
  from cma.roster_week
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.roster_publication as
  select id, tenant_id, roster_week_id, version, published_at, published_by
  from cma.roster_publication
  where cma_read.reader_sees(tenant_id);

-- Every version of every cell, so planned versus actual can be reported as it was planned at the time
create or replace view cma_read.roster_entry as
  select id, tenant_id, roster_week_id, user_id, business_date, kind, start_time, end_time, absence_type_id, note,
         recorded_at, recorded_by, valid_to, superseded_by
  from cma.roster_entry
  where cma_read.reader_sees(tenant_id);

-- The plan as agents saw it: the latest publication per week
create or replace view cma_read.roster_published_entry as
  select id, tenant_id, roster_week_id, team_id, week_start, version, published_at,
         user_id, business_date, kind, start_time, end_time, absence_type_id, note, recorded_at, recorded_by
  from cma.roster_published_entry_all
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.coverage_target as
  select tenant_id, team_id, skill_id, weekday, min_count, updated_at, updated_by
  from cma.coverage_target
  where cma_read.reader_sees(tenant_id);

-- ---------------------------------------------------------------------------------------------
-- 10. Record the migration
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0005', 'Roster: absence types, roster weeks with publications, versioned entries (shift or absence within the business day), coverage targets, the planner functions, the own schedule and today''s shift reads, the adherence tolerance setting')
on conflict (version) do nothing;

reset role;
