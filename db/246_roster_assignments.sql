-- =============================================================================================
-- 246_roster_assignments.sql: addition 0009zw, Assignments in the roster: the planner side (brief A)
-- =============================================================================================
-- Universal: no customer, tenant, status, market or vendor specifics. The assignment types, the absences that carry over
-- and the planner settings of Pulse4all Subscriptions are seed data in 02_seed_pulse4all.sql, never code. Runs unchanged in
-- every database, after 244_auto_close_office_hours.sql (0009zv); it refuses to run before 0009zv is recorded. The brief
-- named addition 0009zt with 240 and 241; #321 took those, so this is the next free addition and number pair (0009zw,
-- 246/247). Rerunnable, forward-only, in one transaction with a lock timeout.
-- Run as your own IAM login: dev first, then 247_verify_roster_assignments.sql there (normal, then provoked), then the
-- verifies that read what this changes (below), then 02_seed_pulse4all.sql again (Pulse4all's assignment types, its
-- absences that carry over and its planner settings), then 131_time_all.sql part a (the roster rows, new and old); then
-- prod, before the merge: this script, 247 and the same verifies, then 02.
--
-- Needs the extension btree_gist (the overlap rule of D6 is an exclusion constraint over a person, a date and a time range):
-- section 0 creates it under your own login when the database lacks it (Cloud SQL lets cloudsqlsuperuser create it; it is
-- a trusted extension). Where your login may not, the script stops and says so: then run, once, in Cloud SQL Studio as
-- postgres:  create extension if not exists btree_gist with schema public;  and run this script again.
--
-- Why (Martin, 25 November 2026, brief A "Assignments in the roster (the planner side)"; Decision log, 25 Nov 2026, D1 to
-- D13): Arno and Kira plan agents within the day per 15-minute slot, today in Excel. The unit within a shift is an
-- Assignment (nl Inzet, D1): one block of one Assignment type with a start and an end inside the person's shift on one
-- business date, and an optional Hours market (empty: the person's Default market at booking, "own market"). Brief B (the
-- assignment on the time events, Clock in on the plan, Back to plan, replanning from the Live board) and brief C (Plan at
-- day start against actual) follow; the model here needs no schema change for them: every version of every block is kept
-- with its instants (D7), a block carries its type and the status that type books, and the published plan is readable as
-- of every publication.
--
-- What it adds
--   btree_gist                  extension, schema public (section 0)
--   settings                    roster.slot_minutes (5, 10, 15, 20, 30, 60; default 15: the planner's grid, D6),
--                               roster.lunch_after_minutes (default 360: the plan check's long shift without a lunch block),
--                               roster.lunch_type_code (default empty: any pause block is the lunch block; the code the plan
--                               check takes as lunch, so no code names a tenant's type),
--                               roster.planner_timezone (text, default empty: the tenant's zone; the zone of the planner's
--                               Day view and of cma.roster_slot_coverage). A trigger on cma.tenant_setting refuses a
--                               planner zone that is no IANA zone (CMA04)
--   cma.assignment_type         D2: code (1 to 6 of A-Z and 0-9, unique per tenant, never changed), name, sort order,
--                               status, kind work or pause, the work status it books (a tenant-scoped foreign key; null
--                               only for an extra type, D4) and is_extra; its colour and Work area follow from the status
--                               (D13). Trigger cma.assignment_type_rules: kind work books a working status, kind pause a
--                               status that is not working, an extra type is of kind work and books none
--   cma.roster_assignment       D1, D6, D7: tenant, roster week (the shift's), person, business date, type, start and end
--                               (local times in the person's zone, as the shift's), hours market (null: own market), note,
--                               recorded_at and recorded_by, valid_to and superseded_by. Exclusion constraint
--                               roster_assignment_no_overlap: two current blocks of one person and date never overlap.
--                               Trigger cma.roster_assignment_rules (insert): start and end on the tenant's slot grid,
--                               the hours market an hours market of the tenant. Inside the shift: the write functions
--                               (CMA04), as the shift is another row
--   cma.standard_week_entry, cma.standard_week_assignment
--                               D9: one Standard week per tenant, per person and ISO weekday the shift or a carrying
--                               absence and the blocks, without dates; versioned as the roster (valid_to, superseded_by),
--                               so a replaced standard week stays readable; the blocks under the same overlap rule
--   cma.absence_type.carries_over  D10: whether Copy week and Save as standard week take an absence of this type (default
--                               false); cma.set_absence_carries_over(key, value), tenant.configure
--   views                       cma.roster_published_assignment_all (owner only) with its tenant face
--                               cma.roster_published_assignment: the blocks as of each week's latest publication, as
--                               cma.roster_published_entry does for the entries (D7); cma_read faces for the new tables and
--                               the published blocks; cma_read.absence_type with carries_over appended last
--   functions (the roster's security pattern: the caller's rights, a permission checked inside, cma_app only)
--     cma.assignment_types()                     the catalog; any active person of the tenant (the planner and My schedule)
--     cma.upsert_assignment_type(...)            tenant.configure
--     cma.roster_assignments(week, team)         the planner's current blocks of the week; roster.manage
--     cma.roster_cell(week, team, user, date)    one person-date: the current entry, its blocks, and the blocks the
--                                                transaction ended without a successor (the planner's answer to a write)
--     cma.roster_set_assignments(week, team, user, date, blocks, publish_others)
--                                                replaces a person-date's current blocks in one call (D1, D6, D7); a
--                                                change to the person's today in a published week publishes the week at
--                                                once, and refuses (CMA03, detail publish_others=<n>) while the week holds
--                                                n other unpublished changes and publish_others is not true (D8)
--     cma.roster_slot_coverage(date, team)       D12: per slot of the planner zone's day, the people working and the
--                                                people per type and hours market
--     cma.roster_planned_hours(week, team)       D12: per person, date, type and hours market, the planned minutes
--     cma.standard_week(), cma.save_standard_week(week, team), cma.apply_standard_week(week, team)   D9, with reports
--     cma.roster_copy_week_report(from, to, team)  D10's copy with its report: what it did, what it skipped and why
--     cma.roster_planner_zone()                  the planner zone (setting, else the tenant's zone)
--   internal                    cma.roster_put_assignments (the one writer of blocks; roster.manage), cma.roster_block_minutes,
--                               cma.roster_other_changes, cma.roster_blocks_json
--
-- What it changes (each from its latest earlier definition, named on the line above its create)
--   cma.roster_week(date, text)              changed_since_publish also reads the week's blocks (signature and columns kept)
--   cma.roster_set_entry(9 arguments)        when a shift is cleared, changed to an absence or shortened, the
--                                            person-date's current blocks outside the new shift end with it (valid_to, no
--                                            superseded_by); cma.roster_cell reports them; signature and result kept
--   cma.roster_copy_week(date, date, text)   now cma.roster_copy_week_report's count of days copied: the blocks come with
--                                            the shifts, an absence only when its type carries over (D10); signature kept
--   cma.roster_people(date, text)            default_hours_market_code appended last (the Day view's Default market)
--   cma.my_roster(date, date)                assignments appended last: the date's published blocks (code, name, kind,
--                                            work area, is_extra, start, end, hours market and its zone)
--   cma.roster_today()                       assignments appended last, as my_roster's, for brief B's Live board
--   cma.absence_types()                      carries_over appended last
-- The four reads that gain a last column are dropped and created (a returned column cannot be added in place); every
-- earlier column keeps its name, type, order and value, and their rows are unchanged.
--
-- Verifies that read what this changes, run again after this script (grep -lw 'cma\.<function>' db/*verify*.sql):
--   25_verify_roster.sql            every roster function; A4 lists my_roster's columns: edited by this change to expect
--                                   assignments last; B10 copies alpha's week (two shifts, copied as before)
--   199_verify_roster_planned.sql   R1 and R3 compare roster_people and roster_today with 0005's definitions over select *:
--                                   edited by this change to compare the earlier columns by name
--   27_verify_configuration.sql     cma.absence_types() by named columns, retire_absence_type; unchanged
--   47_verify_workday_window.sql, 127_verify_workday_sessions.sql, 245_verify_auto_close_office_hours.sql
--                                   cma.roster_week and roster_entry as tables, the published entries; unchanged
-- 131_time_all.sql: rows added for the planner's new reads ('roster assignments', 'roster cell', 'roster slot coverage',
-- 'roster planned hours', 'assignment types', 'standard week') and for My schedule's read with its new column; 'shifts
-- today' reads cma.roster_today as before (one lateral read of the person's published blocks per row).
--
-- SQLSTATEs as 0005's: CMA02 not found, CMA03 conflict (another roster's day; D8's confirmation), CMA04 invalid, CMA06 not
-- permitted.
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

-- ---------------------------------------------------------------------------------------------
-- 0. btree_gist, under your own login (before set role: cma_owner may create no extension)
-- ---------------------------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'btree_gist') then
    begin
      create extension if not exists btree_gist with schema public;
      raise notice 'btree_gist: created';
    exception when insufficient_privilege or feature_not_supported or object_not_in_prerequisite_state then
      raise exception 'btree_gist is missing and this login may not create it (%: %): run in Cloud SQL Studio as postgres: create extension if not exists btree_gist with schema public; then run this script again', sqlstate, sqlerrm;
    end;
  end if;
end
$$;

set role cma_owner;
select set_config('app.actor_label', 'migration:0009zw', true);

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0009zv') then
    raise exception 'addition 0009zv (244_auto_close_office_hours.sql) must run before 0009zw';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Settings (D6, the plan check, the planner zone)
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('roster.slot_minutes', 'integer', array['5', '10', '15', '20', '30', '60'], '15',
     'Minutes per slot of the roster planner''s grid: an assignment starts and ends on it'),
  ('roster.lunch_after_minutes', 'integer', null, '360',
     'Minutes of shift from which the planner''s plan check expects a lunch block (an assignment of a pause type booking lunch)'),
  ('roster.lunch_type_code', 'text', null, '',
     'The assignment type code the planner''s plan check takes as the lunch block; empty: any block of a pause type'),
  ('roster.planner_timezone', 'text', null, '',
     'IANA zone of the roster planner''s Day view and its coverage per slot; empty: the tenant''s zone')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- The planner zone is an IANA zone or empty (the catalog's generic check knows no zones)
create or replace function cma.tenant_setting_zone_ok()
returns trigger
language plpgsql
as $$
begin
  if new.key = 'roster.planner_timezone' and new.value <> '' and not cma.is_timezone(new.value) then
    raise exception 'roster.planner_timezone takes an IANA zone such as Europe/Madrid, or empty for the tenant''s zone; got %', new.value
      using errcode = 'CMA04';
  end if;
  return new;
end
$$;
revoke execute on function cma.tenant_setting_zone_ok() from public;
create or replace trigger zone_ok before insert or update on cma.tenant_setting
  for each row execute function cma.tenant_setting_zone_ok();

-- The planner zone of the current tenant: its setting when that is a zone, else the tenant's zone
create or replace function cma.roster_planner_zone()
returns text
language sql stable
as $$
  select coalesce(
    (select ts.value from cma.tenant_setting ts
     where ts.tenant_id = cma.current_tenant_id() and ts.key = 'roster.planner_timezone' and ts.value <> '' and cma.is_timezone(ts.value)),
    (select t.timezone from cma.tenant t where t.id = cma.current_tenant_id()))
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. Tables
-- ---------------------------------------------------------------------------------------------
create table if not exists cma.assignment_type (
  id              uuid primary key default uuidv7(),
  tenant_id       uuid not null default cma.current_tenant_id() references cma.tenant (id),
  code            text not null check (code ~ '^[A-Z0-9]{1,6}$'),
  name            text not null check (length(btrim(name)) between 1 and 40),
  sort_order      integer not null default 100,
  status          text not null default 'active' check (status in ('active', 'inactive')),
  kind            text not null check (kind in ('work', 'pause')),
  work_status_id  uuid,
  is_extra        boolean not null default false,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, code),
  foreign key (tenant_id, work_status_id) references cma.work_status (tenant_id, id),
  constraint assignment_type_status_ok check (is_extra = (work_status_id is null)),
  constraint assignment_type_extra_work check (not is_extra or kind = 'work')
);
comment on table cma.assignment_type is 'Assignment types (nl Inzettypen) a planner paints in the roster, per tenant: a code, a name, kind work or pause and the work status a block of it books (none for an extra type, which counts under the status the agent is on). Its colour and Work area follow from the status. Tenant configuration';
comment on column cma.assignment_type.code is 'What the planner types: 1 to 6 of A-Z and 0-9, unique per tenant, never changed once made';
comment on column cma.assignment_type.is_extra is 'Extra hours (X): books no status of its own; time in such a block counts under the status, Work area and Hours market the agent is on';
create or replace trigger set_updated_at before update on cma.assignment_type
  for each row execute function cma.set_updated_at();

create table if not exists cma.roster_assignment (
  id                  uuid primary key default uuidv7(),
  tenant_id           uuid not null default cma.current_tenant_id() references cma.tenant (id),
  roster_week_id      uuid not null,
  user_id             uuid not null,
  business_date       date not null,
  assignment_type_id  uuid not null,
  start_time          time not null,                  -- local time in the person's zone, as the shift's
  end_time            time not null,                  -- up to 24:00, the end of the business day
  hours_market_code   text,                           -- null: own market (the person's Default market at booking)
  note                text check (note is null or length(btrim(note)) between 1 and 120),
  recorded_at         timestamptz not null default clock_timestamp(),
  recorded_by         uuid default cma.current_user_id(),
  valid_to            timestamptz,                    -- when superseded or ended; null while current
  superseded_by       uuid,                           -- the block that took its place; null when ended without one
  unique (tenant_id, id),
  foreign key (tenant_id, roster_week_id)      references cma.roster_week (tenant_id, id),
  foreign key (tenant_id, user_id)             references cma.app_user (tenant_id, id),
  foreign key (tenant_id, assignment_type_id)  references cma.assignment_type (tenant_id, id),
  foreign key (tenant_id, hours_market_code)   references cma.market (tenant_id, code),
  foreign key (tenant_id, recorded_by)         references cma.app_user (tenant_id, id),
  foreign key (tenant_id, superseded_by)       references cma.roster_assignment (tenant_id, id),
  constraint roster_assignment_times_ok check (end_time > start_time and extract(second from start_time) = 0 and extract(second from end_time) = 0),
  check (valid_to is null or valid_to >= recorded_at),
  constraint roster_assignment_no_overlap exclude using gist (
    tenant_id with =, user_id with =, business_date with =,
    int4range((extract(epoch from start_time) / 60)::integer, (extract(epoch from end_time) / 60)::integer) with &&
  ) where (valid_to is null)
);
comment on table cma.roster_assignment is 'Assignments (nl Inzet): blocks of one assignment type inside a person''s shift on one business date, versioned as roster entries (a change ends the row and inserts a new one). Two current blocks of one person and date never overlap; start and end lie on the tenant''s slot grid';
comment on column cma.roster_assignment.hours_market_code is 'The Hours market the block is planned under; null is own market, the person''s Default market at booking';
create index if not exists roster_assignment_week_idx on cma.roster_assignment (tenant_id, roster_week_id, business_date);
create index if not exists roster_assignment_user_idx on cma.roster_assignment (tenant_id, user_id, business_date);

create table if not exists cma.standard_week_entry (
  id               uuid primary key default uuidv7(),
  tenant_id        uuid not null default cma.current_tenant_id() references cma.tenant (id),
  user_id          uuid not null,
  iso_weekday      smallint not null check (iso_weekday between 1 and 7),   -- 1 Monday, 7 Sunday
  kind             text not null check (kind in ('shift', 'absence')),
  start_time       time,
  end_time         time,
  absence_type_id  uuid,
  note             text check (note is null or length(btrim(note)) between 1 and 120),
  recorded_at      timestamptz not null default clock_timestamp(),
  recorded_by      uuid default cma.current_user_id(),
  valid_to         timestamptz,
  superseded_by    uuid,
  unique (tenant_id, id),
  foreign key (tenant_id, user_id)         references cma.app_user (tenant_id, id),
  foreign key (tenant_id, absence_type_id) references cma.absence_type (tenant_id, id),
  foreign key (tenant_id, recorded_by)     references cma.app_user (tenant_id, id),
  foreign key (tenant_id, superseded_by)   references cma.standard_week_entry (tenant_id, id),
  check (
    (kind = 'shift' and start_time is not null and end_time is not null and end_time > start_time and absence_type_id is null)
    or
    (kind = 'absence' and absence_type_id is not null and start_time is null and end_time is null)
  ),
  check (valid_to is null or valid_to >= recorded_at)
);
comment on table cma.standard_week_entry is 'The Standard week (nl Standaardweek): per person and ISO weekday a shift or an absence that carries over, without dates. One current set per tenant; Save as standard week ends the rows of the people it saves and inserts new ones, so a replaced standard week stays readable';
create unique index if not exists standard_week_entry_current_idx
  on cma.standard_week_entry (tenant_id, user_id, iso_weekday) where valid_to is null;

create table if not exists cma.standard_week_assignment (
  id                      uuid primary key default uuidv7(),
  tenant_id               uuid not null default cma.current_tenant_id() references cma.tenant (id),
  standard_week_entry_id  uuid not null,
  user_id                 uuid not null,
  iso_weekday             smallint not null check (iso_weekday between 1 and 7),
  assignment_type_id      uuid not null,
  start_time              time not null,
  end_time                time not null,
  hours_market_code       text,
  note                    text check (note is null or length(btrim(note)) between 1 and 120),
  recorded_at             timestamptz not null default clock_timestamp(),
  recorded_by             uuid default cma.current_user_id(),
  valid_to                timestamptz,
  superseded_by           uuid,
  unique (tenant_id, id),
  foreign key (tenant_id, standard_week_entry_id) references cma.standard_week_entry (tenant_id, id),
  foreign key (tenant_id, user_id)                references cma.app_user (tenant_id, id),
  foreign key (tenant_id, assignment_type_id)     references cma.assignment_type (tenant_id, id),
  foreign key (tenant_id, hours_market_code)      references cma.market (tenant_id, code),
  foreign key (tenant_id, recorded_by)            references cma.app_user (tenant_id, id),
  foreign key (tenant_id, superseded_by)          references cma.standard_week_assignment (tenant_id, id),
  check (end_time > start_time),
  check (valid_to is null or valid_to >= recorded_at),
  constraint standard_week_assignment_no_overlap exclude using gist (
    tenant_id with =, user_id with =, iso_weekday with =,
    int4range((extract(epoch from start_time) / 60)::integer, (extract(epoch from end_time) / 60)::integer) with &&
  ) where (valid_to is null)
);
comment on table cma.standard_week_assignment is 'The blocks of the Standard week''s shifts, per person and ISO weekday, versioned with their entry';
create index if not exists standard_week_assignment_entry_idx on cma.standard_week_assignment (tenant_id, standard_week_entry_id);

select cma.setup_tenant_table('cma.assignment_type');
select cma.setup_tenant_table('cma.roster_assignment');
select cma.setup_tenant_table('cma.standard_week_entry');
select cma.setup_tenant_table('cma.standard_week_assignment');

-- Insert-only history (D7): a block or a standard row is ended by valid_to and superseded_by, nothing else changes; the
-- application writes only through the functions below, which run with the caller's rights
revoke update, delete on cma.assignment_type, cma.roster_assignment, cma.standard_week_entry, cma.standard_week_assignment from cma_app;
grant update (name, sort_order, status, kind, work_status_id, is_extra) on cma.assignment_type to cma_app;
grant update (valid_to, superseded_by) on cma.roster_assignment to cma_app;
grant update (valid_to, superseded_by) on cma.standard_week_entry to cma_app;
grant update (valid_to, superseded_by) on cma.standard_week_assignment to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 3. Rules in the tables
-- ---------------------------------------------------------------------------------------------
-- An assignment type books what its kind says (D2): work a working status, pause a status that is not working; an extra
-- type books none (the table's checks). The status is the tenant's own (the foreign key)
create or replace function cma.assignment_type_rules()
returns trigger
language plpgsql
as $$
declare
  v_working boolean;
begin
  if new.work_status_id is not null then
    select s.is_working into v_working from cma.work_status s where s.tenant_id = new.tenant_id and s.id = new.work_status_id;
    if v_working is null then
      raise exception 'the work status of assignment type % is not the tenant''s', new.code using errcode = 'CMA02';
    end if;
    if new.kind = 'work' and not v_working then
      raise exception 'assignment type % is of kind work and must book a working status', new.code using errcode = 'CMA04';
    end if;
    if new.kind = 'pause' and v_working then
      raise exception 'assignment type % is a pause and must book a status that is not working', new.code using errcode = 'CMA04';
    end if;
  end if;
  if tg_op = 'UPDATE' and new.code <> old.code then
    raise exception 'an assignment type''s code never changes (% to %)', old.code, new.code using errcode = 'CMA04';
  end if;
  return new;
end
$$;
revoke execute on function cma.assignment_type_rules() from public;
create or replace trigger rules before insert or update on cma.assignment_type
  for each row execute function cma.assignment_type_rules();

-- A block's start and end lie on the tenant's slot grid (D6) and its market is an hours market of the tenant (D5): a
-- market that maps to itself, inactive allowed (a later write function refuses an inactive one for a new block)
create or replace function cma.roster_assignment_rules()
returns trigger
language plpgsql
as $$
declare
  v_slot integer := cma.setting_of(new.tenant_id, 'roster.slot_minutes')::integer;
  v_start integer := (extract(epoch from new.start_time) / 60)::integer;
  v_end integer := (extract(epoch from new.end_time) / 60)::integer;
begin
  if v_start % v_slot <> 0 or v_end % v_slot <> 0 then
    raise exception 'an assignment starts and ends on the % minute grid; got % to %', v_slot,
      to_char(new.start_time, 'HH24:MI'), case when v_end = 1440 then '24:00' else to_char(new.end_time, 'HH24:MI') end
      using errcode = 'CMA04';
  end if;
  if new.hours_market_code is not null and not exists (
       select 1 from cma.market m
       where m.tenant_id = new.tenant_id and m.code = new.hours_market_code and m.hours_market_code = m.code) then
    raise exception 'market % is no hours market of the tenant', new.hours_market_code using errcode = 'CMA04';
  end if;
  return new;
end
$$;
revoke execute on function cma.roster_assignment_rules() from public;
create or replace trigger rules before insert on cma.roster_assignment
  for each row execute function cma.roster_assignment_rules();

-- ---------------------------------------------------------------------------------------------
-- 4. Absence types carry over (D10)
-- ---------------------------------------------------------------------------------------------
-- (the column is added in section 13, last, with the views that read it: the table is read by every roster read)

-- tenant.configure: whether Copy week and Save as standard week take an absence of this type
create or replace function cma.set_absence_carries_over(p_key text, p_carries_over boolean)
returns void
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
  if p_carries_over is null then
    raise exception 'carries over is true or false' using errcode = 'CMA04';
  end if;
  update cma.absence_type set carries_over = p_carries_over
   where tenant_id = cma.current_tenant_id() and key = p_key and carries_over is distinct from p_carries_over;
  if not found and not exists (select 1 from cma.absence_type where tenant_id = cma.current_tenant_id() and key = p_key) then
    raise exception 'absence type % does not exist', p_key using errcode = 'CMA02';
  end if;
end
$$;

-- The absence catalog with carries_over last (23's definition otherwise): any active person of the tenant reads it
drop function if exists cma.absence_types();
-- based on: 23_roster.sql
create function cma.absence_types()
returns table (key text, name text, is_paid boolean, sort_order integer, status text, carries_over boolean)
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
    select a.key::text, a.name::text, a.is_paid, a.sort_order, a.status::text, a.carries_over
    from cma.absence_type a
    where a.tenant_id = cma.current_tenant_id()
    order by a.sort_order, a.key;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. The assignment type catalog (D2)
-- ---------------------------------------------------------------------------------------------
-- Any active person of the tenant reads it (the planner, My schedule), as the absence catalog. The work area and the flags
-- of the status a type books give its colour (D13)
create or replace function cma.assignment_types()
returns table (code text, name text, sort_order integer, status text, kind text, status_key text, status_name text,
               work_area text, is_extra boolean, status_is_productive boolean)
language plpgsql stable rows 20
as $$
#variable_conflict use_column
declare
  v_user uuid := cma.current_user_id();
begin
  if v_user is null then
    raise exception 'assignment_types needs app.user_id, the acting user' using errcode = 'CMA01';
  end if;
  if not exists (select 1 from cma.app_user where tenant_id = cma.current_tenant_id() and id = v_user and status = 'active') then
    raise exception 'user % is not an active user of the current tenant', v_user using errcode = 'CMA01';
  end if;
  return query
    select t.code::text, t.name::text, t.sort_order, t.status::text, t.kind::text, s.key::text, s.name::text,
           s.work_area::text, t.is_extra, s.is_productive
    from cma.assignment_type t
    left join cma.work_status s on s.tenant_id = t.tenant_id and s.id = t.work_status_id
    where t.tenant_id = cma.current_tenant_id()
    order by (t.status <> 'active'), t.sort_order, t.code collate "C";
end
$$;

-- tenant.configure: add or change a type by its code (the code itself never changes). An extra type books no status (D4)
create or replace function cma.upsert_assignment_type(p_code text, p_name text, p_kind text, p_status_key text,
                                                      p_is_extra boolean default false, p_sort_order integer default 100,
                                                      p_status text default 'active')
returns void
language plpgsql
as $$
declare
  v_status uuid;
begin
  perform cma.assert_permission('tenant.configure');
  if p_code is null or p_code !~ '^[A-Z0-9]{1,6}$' then
    raise exception 'an assignment code is 1 to 6 of A-Z and 0-9' using errcode = 'CMA04';
  end if;
  if p_name is null or length(btrim(p_name)) not between 1 and 40 then
    raise exception 'an assignment type''s name is 1 to 40 characters' using errcode = 'CMA04';
  end if;
  if p_kind is null or p_kind not in ('work', 'pause') then
    raise exception 'an assignment type is of kind work or pause' using errcode = 'CMA04';
  end if;
  if p_status is null or p_status not in ('active', 'inactive') then
    raise exception 'status is active or inactive' using errcode = 'CMA04';
  end if;
  if coalesce(p_is_extra, false) then
    if p_status_key is not null then
      raise exception 'an extra type books no status of its own' using errcode = 'CMA04';
    end if;
    if p_kind <> 'work' then
      raise exception 'an extra type is of kind work' using errcode = 'CMA04';
    end if;
  else
    select s.id into v_status from cma.work_status s
     where s.tenant_id = cma.current_tenant_id() and s.key = p_status_key and s.status = 'active';
    if v_status is null then
      raise exception 'work status % does not exist or is no longer in use', coalesce(p_status_key, 'none') using errcode = 'CMA02';
    end if;
  end if;
  insert into cma.assignment_type as t (tenant_id, code, name, kind, work_status_id, is_extra, sort_order, status)
  values (cma.current_tenant_id(), p_code, btrim(p_name), p_kind, v_status, coalesce(p_is_extra, false), coalesce(p_sort_order, 100), p_status)
  on conflict (tenant_id, code) do update
    set name = excluded.name, kind = excluded.kind, work_status_id = excluded.work_status_id, is_extra = excluded.is_extra,
        sort_order = excluded.sort_order, status = excluded.status
    where (t.name, t.kind, t.work_status_id, t.is_extra, t.sort_order, t.status)
          is distinct from (excluded.name, excluded.kind, excluded.work_status_id, excluded.is_extra, excluded.sort_order, excluded.status);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. Helpers
-- ---------------------------------------------------------------------------------------------
-- Minutes from midnight of a local time; 24:00 is 1440
create or replace function cma.roster_block_minutes(p_time time)
returns integer
language sql immutable parallel safe
as $$
  select (extract(epoch from p_time) / 60)::integer
$$;

-- A person-date's current blocks as JSON, in start order, with their type (the shape of the planner's answer)
create or replace function cma.roster_blocks_json(p_user_id uuid, p_date date)
returns jsonb
language sql stable
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'assignmentId', a.id, 'code', t.code, 'start', to_char(a.start_time, 'HH24:MI'),
           'end', case when a.end_time = '24:00'::time then '24:00' else to_char(a.end_time, 'HH24:MI') end,
           'hoursMarket', a.hours_market_code, 'note', a.note, 'recordedAt', a.recorded_at)
           order by a.start_time), '[]'::jsonb)
  from cma.roster_assignment a
  join cma.assignment_type t on t.tenant_id = a.tenant_id and t.id = a.assignment_type_id
  where a.tenant_id = cma.current_tenant_id() and a.user_id = p_user_id and a.business_date = p_date and a.valid_to is null
$$;

-- How many person-dates of a roster week other than the one given changed since the week's latest publication: an entry
-- or a block recorded or ended after it (D8's "{n} other changes"). 0 for a draft week
create or replace function cma.roster_other_changes(p_week_id uuid, p_user_id uuid, p_date date)
returns integer
language sql stable
as $$
  select count(*)::integer
  from (
    select e.user_id, e.business_date
    from cma.roster_entry e
    join cma.roster_week w on w.tenant_id = e.tenant_id and w.id = e.roster_week_id
    where e.tenant_id = cma.current_tenant_id() and e.roster_week_id = p_week_id and w.status = 'published'
      and (e.recorded_at > w.published_at or e.valid_to > w.published_at)
    union
    select a.user_id, a.business_date
    from cma.roster_assignment a
    join cma.roster_week w on w.tenant_id = a.tenant_id and w.id = a.roster_week_id
    where a.tenant_id = cma.current_tenant_id() and a.roster_week_id = p_week_id and w.status = 'published'
      and (a.recorded_at > w.published_at or a.valid_to > w.published_at)
  ) x
  where (x.user_id, x.business_date) is distinct from (p_user_id, p_date)
$$;

-- The one writer of blocks (roster.manage): replaces a person-date's current blocks with p_blocks in its roster week.
-- p_blocks: a JSON array of {"code", "start" (hh:mm), "end" (hh:mm, 24:00 allowed), "market" (an hours market code or
-- null: own market), "note"}. The person's current entry that day must be a shift of this roster week (CMA04), every
-- block inside it, on the grid (D6), of an active type, under an active hours market, and the blocks must not overlap.
-- Strict (the planner): a block that breaks a rule refuses the call. Not strict (Copy week, Apply standard week): such a
-- block is dropped and counted. A block equal to a current one (type, start, end, market, note) is kept as it is; the
-- others end (valid_to; superseded_by: the new block with the same start, else the first new one it overlaps, else none)
-- and the new ones are inserted. Answers {"kept", "ended", "added", "dropped"}
create or replace function cma.roster_put_assignments(p_week_id uuid, p_user_id uuid, p_date date, p_blocks jsonb, p_strict boolean)
returns jsonb
language plpgsql
as $$
declare
  v_shift  cma.roster_entry;
  v_slot   integer := cma.setting_of(cma.current_tenant_id(), 'roster.slot_minutes')::integer;
  b        jsonb;
  v_type   cma.assignment_type;
  v_start  time;
  v_end    time;
  v_market text;
  v_note   text;
  v_bad    text;
  v_kept   integer := 0;
  v_ended  integer := 0;
  v_added  integer := 0;
  v_drop   integer := 0;
  r        record;
begin
  perform cma.assert_permission('roster.manage');
  if p_blocks is null or jsonb_typeof(p_blocks) <> 'array' then
    raise exception 'blocks must be a JSON array' using errcode = 'CMA04';
  end if;
  if jsonb_array_length(p_blocks) > 96 then
    raise exception 'at most 96 blocks per person and date' using errcode = 'CMA04';
  end if;

  select * into v_shift from cma.roster_entry
   where tenant_id = cma.current_tenant_id() and user_id = p_user_id and business_date = p_date and valid_to is null;
  if jsonb_array_length(p_blocks) > 0 then
    if v_shift.id is null or v_shift.kind <> 'shift' then
      raise exception 'an assignment lies inside a shift: this person has no shift on %', p_date using errcode = 'CMA04';
    end if;
    if v_shift.roster_week_id <> p_week_id then
      raise exception 'this person''s shift on % belongs to another roster', p_date using errcode = 'CMA03';
    end if;
  end if;

  create temporary table if not exists pg_temp.roster_put_block (
    ord integer, type_id uuid, start_time time, end_time time, market text, note text) on commit drop;
  delete from pg_temp.roster_put_block;

  for b in select value from jsonb_array_elements(p_blocks) loop
    v_bad := null;
    if jsonb_typeof(b) <> 'object' then
      raise exception 'each block is a JSON object' using errcode = 'CMA04';
    end if;
    select * into v_type from cma.assignment_type
     where tenant_id = cma.current_tenant_id() and code = upper(btrim(coalesce(b->>'code', '')));
    if v_type.id is null then
      if p_strict then
        raise exception 'assignment type % does not exist', coalesce(b->>'code', 'none') using errcode = 'CMA02';
      end if;
      v_drop := v_drop + 1;
      continue;
    end if;
    if coalesce(b->>'start', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' or coalesce(b->>'end', '') !~ '^(([01][0-9]|2[0-3]):[0-5][0-9]|24:00)$' then
      raise exception 'a block''s start and end are hh:mm, the end at the latest 24:00' using errcode = 'CMA04';
    end if;
    v_start := (b->>'start')::time;
    v_end := (b->>'end')::time;
    v_market := nullif(btrim(coalesce(b->>'market', '')), '');
    v_note := nullif(btrim(coalesce(b->>'note', '')), '');
    if v_end <= v_start then
      v_bad := format('the block %s ends after it starts', v_type.code);
    elsif cma.roster_block_minutes(v_start) % v_slot <> 0 or cma.roster_block_minutes(v_end) % v_slot <> 0 then
      v_bad := format('the block %s starts and ends on the %s minute grid', v_type.code, v_slot);
    elsif v_start < v_shift.start_time or v_end > v_shift.end_time then
      v_bad := format('the block %s %s to %s lies outside the shift %s to %s', v_type.code, b->>'start', b->>'end',
                      to_char(v_shift.start_time, 'HH24:MI'), case when v_shift.end_time = '24:00'::time then '24:00' else to_char(v_shift.end_time, 'HH24:MI') end);
    elsif v_note is not null and length(v_note) > 120 then
      v_bad := 'a block''s note has at most 120 characters';
    end if;
    -- A retired type or market stays on a block that is kept unchanged; a new block needs an active one
    if v_bad is null and not exists (
         select 1 from cma.roster_assignment a
         where a.tenant_id = cma.current_tenant_id() and a.user_id = p_user_id and a.business_date = p_date and a.valid_to is null
           and a.assignment_type_id = v_type.id and a.start_time = v_start and a.end_time = v_end
           and a.hours_market_code is not distinct from v_market and a.note is not distinct from v_note) then
      if v_type.status <> 'active' then
        v_bad := format('assignment type %s is no longer in use', v_type.code);
      elsif v_market is not null then
        if p_strict then
          perform cma.assert_hours_market(v_market);
        elsif not cma.is_hours_market(v_market) then
          v_bad := format('market %s is no active hours market', v_market);
        end if;
      end if;
    end if;
    if v_bad is not null then
      if p_strict then
        raise exception '%', v_bad using errcode = 'CMA04';
      end if;
      v_drop := v_drop + 1;
      continue;
    end if;
    if exists (select 1 from pg_temp.roster_put_block x where x.start_time < v_end and v_start < x.end_time) then
      if p_strict then
        raise exception 'the blocks overlap at % to %', b->>'start', b->>'end' using errcode = 'CMA04';
      end if;
      v_drop := v_drop + 1;
      continue;
    end if;
    insert into pg_temp.roster_put_block values (v_added + v_drop, v_type.id, v_start, v_end, v_market, v_note);
  end loop;

  -- End the current blocks that are not wanted any more (before the new ones: the exclusion constraint is per statement)
  for r in
    select a.id from cma.roster_assignment a
    where a.tenant_id = cma.current_tenant_id() and a.user_id = p_user_id and a.business_date = p_date and a.valid_to is null
      and not exists (select 1 from pg_temp.roster_put_block x
                      where x.type_id = a.assignment_type_id and x.start_time = a.start_time and x.end_time = a.end_time
                        and x.market is not distinct from a.hours_market_code and x.note is not distinct from a.note)
    for update
  loop
    update cma.roster_assignment set valid_to = clock_timestamp() where tenant_id = cma.current_tenant_id() and id = r.id;
    v_ended := v_ended + 1;
  end loop;

  -- Insert the new ones; the kept ones stay as they are
  for r in
    select x.* from pg_temp.roster_put_block x
    where not exists (select 1 from cma.roster_assignment a
                      where a.tenant_id = cma.current_tenant_id() and a.user_id = p_user_id and a.business_date = p_date
                        and a.valid_to is null and x.type_id = a.assignment_type_id and x.start_time = a.start_time
                        and x.end_time = a.end_time and x.market is not distinct from a.hours_market_code
                        and x.note is not distinct from a.note)
    order by x.start_time
  loop
    insert into cma.roster_assignment (tenant_id, roster_week_id, user_id, business_date, assignment_type_id, start_time, end_time,
                                       hours_market_code, note)
    values (cma.current_tenant_id(), p_week_id, p_user_id, p_date, r.type_id, r.start_time, r.end_time, r.market, r.note);
    v_added := v_added + 1;
  end loop;
  v_kept := (select count(*) from pg_temp.roster_put_block) - v_added;

  -- Link each block this call ended to its successor: the new block with the same start, else the first new one it overlaps
  update cma.roster_assignment o
     set superseded_by = coalesce(
           (select n.id from cma.roster_assignment n
            where n.tenant_id = o.tenant_id and n.user_id = o.user_id and n.business_date = o.business_date and n.valid_to is null
              and n.recorded_at >= now() and n.start_time = o.start_time limit 1),
           (select n.id from cma.roster_assignment n
            where n.tenant_id = o.tenant_id and n.user_id = o.user_id and n.business_date = o.business_date and n.valid_to is null
              and n.recorded_at >= now() and n.start_time < o.end_time and o.start_time < n.end_time
            order by n.start_time limit 1))
   where o.tenant_id = cma.current_tenant_id() and o.user_id = p_user_id and o.business_date = p_date
     and o.valid_to >= now() and o.superseded_by is null and v_added > 0;

  delete from pg_temp.roster_put_block;
  return jsonb_build_object('kept', v_kept, 'ended', v_ended, 'added', v_added, 'dropped', v_drop);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. The planner's reads and writes of blocks (roster.manage)
-- ---------------------------------------------------------------------------------------------
-- The current blocks of the week (what the planner paints), of the people on the roster, with their type and the status
-- the type books (its Work area gives the colour, D13)
create or replace function cma.roster_assignments(p_week_start date, p_team_key text default null)
returns table (
  assignment_id      uuid,
  user_id            uuid,
  business_date      date,
  code               text,
  name               text,
  kind               text,
  work_area          text,
  is_extra           boolean,
  start_time         time,
  end_time           time,
  hours_market_code  text,
  note               text,
  recorded_at        timestamptz
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
    select a.id, a.user_id, a.business_date, t.code::text, t.name::text, t.kind::text, s.work_area::text, t.is_extra,
           a.start_time, a.end_time, a.hours_market_code::text, a.note::text, a.recorded_at
    from cma.roster_assignment a
    join cma.roster_week w on w.tenant_id = a.tenant_id and w.id = a.roster_week_id
    join cma.assignment_type t on t.tenant_id = a.tenant_id and t.id = a.assignment_type_id
    left join cma.work_status s on s.tenant_id = t.tenant_id and s.id = t.work_status_id
    where a.tenant_id = cma.current_tenant_id()
      and w.week_start = p_week_start and w.team_id is not distinct from v_team
      and a.valid_to is null
      and cma.on_roster(a.user_id)
    order by a.business_date, a.user_id, a.start_time;
end
$$;

-- One person-date of a roster after a write in the same transaction: the current entry (null columns when none), its
-- current blocks, and how many blocks the transaction ended without a successor (cma.roster_set_entry's shortened,
-- cleared or absent shift)
create or replace function cma.roster_cell(p_week_start date, p_team_key text, p_user_id uuid, p_date date)
returns table (
  entry_id           uuid,
  kind               text,
  start_time         time,
  end_time           time,
  absence_key        text,
  absence_name       text,
  note               text,
  recorded_at        timestamptz,
  recorded_by_name   text,
  assignments        jsonb,
  ended_assignments  integer
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
    select e.id, e.kind::text, e.start_time, e.end_time, ab.key::text, ab.name::text, e.note::text, e.recorded_at, rb.display_name::text,
           cma.roster_blocks_json(p_user_id, p_date),
           (select count(*)::integer from cma.roster_assignment a
            where a.tenant_id = cma.current_tenant_id() and a.user_id = p_user_id and a.business_date = p_date
              and a.valid_to >= now() and a.superseded_by is null)
    from (select 1) one
    left join (cma.roster_entry e
               join cma.roster_week w on w.tenant_id = e.tenant_id and w.id = e.roster_week_id
                                      and w.week_start = p_week_start and w.team_id is not distinct from v_team)
           on e.tenant_id = cma.current_tenant_id() and e.user_id = p_user_id and e.business_date = p_date and e.valid_to is null
    left join cma.absence_type ab on ab.tenant_id = e.tenant_id and ab.id = e.absence_type_id
    left join cma.app_user rb on rb.tenant_id = e.tenant_id and rb.id = e.recorded_by;
end
$$;

-- Replaces a person-date's current blocks in one call (D1, D6, D7), strictly: a block that breaks a rule refuses the call.
-- The person must be on this roster, the date in the week and not in the past in the person's zone. D8: a change to the
-- person's today in a published week publishes the week at once; while the week holds other unpublished changes the call
-- is refused with CMA03 and the detail publish_others=<n> unless p_publish_others is true (the planner asks first: "This
-- also publishes {n} other changes"). A future date stays draft until Publish. Answers {"kept", "ended", "added",
-- "dropped", "published", "version", "blocks"}
create or replace function cma.roster_set_assignments(
  p_week_start      date,
  p_team_key        text,
  p_user_id         uuid,
  p_date            date,
  p_blocks          jsonb,
  p_publish_others  boolean default false
)
returns jsonb
language plpgsql
as $$
declare
  v_team    uuid;
  v_week    uuid;
  v_today   date;
  v_result  jsonb;
  v_others  integer;
  w         cma.roster_week;
begin
  perform cma.assert_permission('roster.manage');
  perform cma.assert_week_start(p_week_start);
  v_team := cma.roster_team_id(p_team_key);
  if p_date is null or p_date < p_week_start or p_date > p_week_start + 6 then
    raise exception 'date % is not in the week of %', p_date, p_week_start using errcode = 'CMA04';
  end if;
  if p_user_id is null or not exists (select 1 from cma.app_user where tenant_id = cma.current_tenant_id() and id = p_user_id) then
    raise exception 'person % does not exist in the current tenant', p_user_id using errcode = 'CMA02';
  end if;
  if not cma.roster_in_scope(p_user_id, v_team, p_week_start) then
    raise exception 'person % is not on this roster (not on the roster, or not a member of the team this week)', p_user_id using errcode = 'CMA04';
  end if;
  v_today := cma.business_date(now(), cma.user_timezone(p_user_id));
  if p_date < v_today then
    raise exception 'date % is in the past for this person; the roster plans today and ahead', p_date using errcode = 'CMA04';
  end if;

  v_week := cma.roster_week_id(p_week_start, v_team);   -- locks the week row: one writer of a week's publication at a time
  v_result := cma.roster_put_assignments(v_week, p_user_id, p_date, p_blocks, true);

  select * into w from cma.roster_week where tenant_id = cma.current_tenant_id() and id = v_week;
  if p_date = v_today and w.status = 'published'
     and ((v_result->>'ended')::integer > 0 or (v_result->>'added')::integer > 0) then
    v_others := cma.roster_other_changes(v_week, p_user_id, p_date);
    if v_others > 0 and not coalesce(p_publish_others, false) then
      raise exception 'this also publishes % other changes of the week', v_others
        using errcode = 'CMA03', detail = 'publish_others=' || v_others;
    end if;
    w := cma.roster_publish(p_week_start, p_team_key);
    v_result := v_result || jsonb_build_object('published', true, 'version', w.version);
  else
    v_result := v_result || jsonb_build_object('published', false, 'version', w.version);
  end if;
  return v_result || jsonb_build_object('blocks', cma.roster_blocks_json(p_user_id, p_date));
end
$$;

-- D12: per slot of the planner zone's day (the tenant's slot grid), the people working (a block of kind work, so on the
-- inbound queue) and the people per assignment type and hours market (a block without a market counts under the person's
-- Default market, null without one). Blocks of the roster on the business dates around the day, placed in each person's
-- zone; current rows (the planner's). One row per slot and type and market; a slot without a block has no row
create or replace function cma.roster_slot_coverage(p_date date, p_team_key text default null)
returns table (
  slot_start         timestamptz,
  slot_time          time,
  working            integer,
  code               text,
  hours_market_code  text,
  people             integer
)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_team uuid;
  v_zone text;
  v_slot integer;
begin
  perform cma.assert_permission('roster.manage');
  if p_date is null then
    raise exception 'a date is required' using errcode = 'CMA04';
  end if;
  v_team := cma.roster_team_id(p_team_key);
  v_zone := cma.roster_planner_zone();
  v_slot := cma.setting_of(cma.current_tenant_id(), 'roster.slot_minutes')::integer;
  return query
    with blocks as (
      select a.user_id, t.code, t.kind, t.sort_order,
             coalesce(a.hours_market_code, u.default_hours_market_code) as market,
             (a.business_date + a.start_time) at time zone cma.user_timezone(a.user_id) as starts,
             (a.business_date + a.end_time) at time zone cma.user_timezone(a.user_id) as ends
      from cma.roster_assignment a
      join cma.roster_week w on w.tenant_id = a.tenant_id and w.id = a.roster_week_id
      join cma.assignment_type t on t.tenant_id = a.tenant_id and t.id = a.assignment_type_id
      join cma.app_user u on u.tenant_id = a.tenant_id and u.id = a.user_id
      where a.tenant_id = cma.current_tenant_id() and a.valid_to is null
        and a.business_date between p_date - 1 and p_date + 1
        and w.team_id is not distinct from v_team
        and cma.on_roster(a.user_id)
    ),
    slots as (
      select s as slot_start
      from generate_series(p_date::timestamp at time zone v_zone,
                           (p_date + 1)::timestamp at time zone v_zone - make_interval(mins => v_slot),
                           make_interval(mins => v_slot)) s
    ),
    hits as (
      select sl.slot_start, b.user_id, b.code, b.kind, b.sort_order, b.market
      from slots sl join blocks b on b.starts <= sl.slot_start and sl.slot_start < b.ends
    )
    select h.slot_start, (h.slot_start at time zone v_zone)::time,
           (select count(distinct h2.user_id)::integer from hits h2 where h2.slot_start = h.slot_start and h2.kind = 'work'),
           h.code::text, h.market::text, count(distinct h.user_id)::integer
    from hits h
    group by h.slot_start, h.code, h.sort_order, h.market
    order by h.slot_start, h.sort_order, h.code collate "C", h.market collate "C" nulls last;
end
$$;

-- D12: the planned minutes per person, date, assignment type and hours market of the week's current blocks (a block
-- without a market under the person's Default market), measured between the block's instants in the person's zone
create or replace function cma.roster_planned_hours(p_week_start date, p_team_key text default null)
returns table (
  user_id            uuid,
  business_date      date,
  code               text,
  kind               text,
  hours_market_code  text,
  planned_minutes    integer
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
    select a.user_id, a.business_date, t.code::text, t.kind::text, coalesce(a.hours_market_code, u.default_hours_market_code)::text,
           sum((extract(epoch from ((a.business_date + a.end_time) at time zone cma.user_timezone(a.user_id))
                                 - ((a.business_date + a.start_time) at time zone cma.user_timezone(a.user_id))) / 60))::integer
    from cma.roster_assignment a
    join cma.roster_week w on w.tenant_id = a.tenant_id and w.id = a.roster_week_id
    join cma.assignment_type t on t.tenant_id = a.tenant_id and t.id = a.assignment_type_id
    join cma.app_user u on u.tenant_id = a.tenant_id and u.id = a.user_id
    where a.tenant_id = cma.current_tenant_id()
      and w.week_start = p_week_start and w.team_id is not distinct from v_team
      and a.valid_to is null
      and cma.on_roster(a.user_id)
    group by a.user_id, a.business_date, t.code, t.kind, t.sort_order, coalesce(a.hours_market_code, u.default_hours_market_code)
    order by a.user_id, a.business_date, t.sort_order, t.code collate "C",
             coalesce(a.hours_market_code, u.default_hours_market_code) collate "C" nulls last;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 8. The roster's earlier functions, with the blocks
-- ---------------------------------------------------------------------------------------------
-- The week's header: changed_since_publish also reads the week's blocks (an assignment recorded or ended after the
-- publication). Signature and columns as 0005's
-- based on: 23_roster.sql
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
                    and (exists (select 1 from cma.roster_entry e
                                 where e.tenant_id = cma.current_tenant_id() and e.roster_week_id = w.id
                                   and (e.recorded_at > w.published_at or e.valid_to > w.published_at))
                         or exists (select 1 from cma.roster_assignment a
                                    where a.tenant_id = cma.current_tenant_id() and a.roster_week_id = w.id
                                      and (a.recorded_at > w.published_at or a.valid_to > w.published_at))), false)
    from (select 1) one
    left join cma.team t on t.tenant_id = cma.current_tenant_id() and t.id = v_team
    left join cma.roster_week w on w.tenant_id = cma.current_tenant_id() and w.week_start = p_week_start
                               and w.team_id is not distinct from v_team
    left join cma.app_user pb on pb.tenant_id = cma.current_tenant_id() and pb.id = w.published_by;
end
$$;

-- The people on the week's grid, 0009y's, with their Default market last (the Day view shows it, and a block without a
-- market is planned under it)
drop function if exists cma.roster_people(date, text);
-- based on: 23_roster.sql
create function cma.roster_people(p_week_start date, p_team_key text default null)
returns table (
  user_id                    uuid,
  display_name               text,
  organisation_name          text,
  timezone                   text,
  team_keys                  text[],
  work_type_keys             text[],
  default_hours_market_code  text
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
                       and s.dimension = 'work_type' and s.status = 'active'), '{}'::text[]),
           u.default_hours_market_code::text
    from cma.app_user u
    left join cma.organisation o on o.tenant_id = u.tenant_id and o.id = u.organisation_id
    where u.tenant_id = cma.current_tenant_id()
      and cma.roster_in_scope(u.id, v_team, p_week_start)
    order by u.display_name, u.id;
end
$$;

-- One cell, 0005's: a shift, an absence or nothing. New (D1, brief A): when the shift is cleared, changed to an absence or
-- shortened, the person-date's current blocks that do not lie inside the new shift end with it (valid_to, no
-- superseded_by); cma.roster_cell reports them in the planner's answer. Signature and result as 0005's
-- based on: 23_roster.sql
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

  -- The blocks that do not lie inside the new shift end with it (brief A): all of them when the cell is cleared or holds
  -- an absence now
  update cma.roster_assignment a
     set valid_to = clock_timestamp()
   where a.tenant_id = cma.current_tenant_id() and a.user_id = p_user_id and a.business_date = p_business_date
     and a.valid_to is null
     and (p_kind is distinct from 'shift' or a.start_time < p_start_time or a.end_time > p_end_time);
  return v_new;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 9. Copy week with its report (D10)
-- ---------------------------------------------------------------------------------------------
-- 0005's copy with what it did and skipped: a source shift overwrites the target cell and brings its blocks (the target's
-- blocks become the source's; a block that breaks a rule now, such as a retired type or market or the grid, is dropped
-- and counted); a source absence is copied only when its type carries over (D10), else skipped and the target left alone;
-- an empty source cell leaves the target alone. Skipped, with the reason: a person no longer on the roster
-- (not_on_roster), a date in the person's past (past), a person planned elsewhere that day (other_roster), an absence that
-- does not carry over (absence_not_carried). One row per source cell
create or replace function cma.roster_copy_week_report(p_from_week_start date, p_to_week_start date, p_team_key text default null)
returns table (user_id uuid, business_date date, outcome text, reason text, blocks integer, blocks_dropped integer)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_team uuid;
  v_week uuid;
  r      record;
  v_date date;
  v_put  jsonb;
begin
  perform cma.assert_permission('roster.manage');
  perform cma.assert_week_start(p_from_week_start);
  perform cma.assert_week_start(p_to_week_start);
  if p_from_week_start = p_to_week_start then
    raise exception 'a week cannot be copied onto itself' using errcode = 'CMA04';
  end if;
  v_team := cma.roster_team_id(p_team_key);
  for r in
    select e.user_id, e.business_date, e.kind, e.start_time, e.end_time, a.key as absence_key, a.carries_over, e.note,
           coalesce((select jsonb_agg(jsonb_build_object('code', t.code, 'start', to_char(x.start_time, 'HH24:MI'),
                                                         'end', case when x.end_time = '24:00'::time then '24:00' else to_char(x.end_time, 'HH24:MI') end,
                                                         'market', x.hours_market_code, 'note', x.note) order by x.start_time)
                     from cma.roster_assignment x
                     join cma.assignment_type t on t.tenant_id = x.tenant_id and t.id = x.assignment_type_id
                     where x.tenant_id = e.tenant_id and x.user_id = e.user_id and x.business_date = e.business_date
                       and x.valid_to is null and x.roster_week_id = e.roster_week_id), '[]'::jsonb) as blocks
    from cma.roster_entry e
    join cma.roster_week w on w.tenant_id = e.tenant_id and w.id = e.roster_week_id
    left join cma.absence_type a on a.tenant_id = e.tenant_id and a.id = e.absence_type_id
    where e.tenant_id = cma.current_tenant_id() and e.valid_to is null
      and w.week_start = p_from_week_start and w.team_id is not distinct from v_team
    order by e.business_date, e.user_id
  loop
    v_date := r.business_date + (p_to_week_start - p_from_week_start);
    user_id := r.user_id; business_date := v_date; blocks := 0; blocks_dropped := 0;
    if not cma.roster_in_scope(r.user_id, v_team, p_to_week_start) then
      outcome := 'skipped'; reason := 'not_on_roster'; return next; continue;
    end if;
    if v_date < cma.business_date(now(), cma.user_timezone(r.user_id)) then
      outcome := 'skipped'; reason := 'past'; return next; continue;
    end if;
    if exists (select 1 from cma.roster_entry x join cma.roster_week xw on xw.tenant_id = x.tenant_id and xw.id = x.roster_week_id
               where x.tenant_id = cma.current_tenant_id() and x.user_id = r.user_id and x.business_date = v_date and x.valid_to is null
                 and (xw.week_start <> p_to_week_start or xw.team_id is distinct from v_team)) then
      outcome := 'skipped'; reason := 'other_roster'; return next; continue;   -- the conflict is for the planner to see
    end if;
    if r.kind = 'absence' and not r.carries_over then
      outcome := 'skipped'; reason := 'absence_not_carried'; return next; continue;
    end if;
    perform cma.roster_set_entry(p_to_week_start, p_team_key, r.user_id, v_date, r.kind, r.start_time, r.end_time, r.absence_key, r.note);
    if r.kind = 'shift' then
      v_week := cma.roster_week_id(p_to_week_start, v_team);
      v_put := cma.roster_put_assignments(v_week, r.user_id, v_date, r.blocks, false);
      blocks := (v_put->>'kept')::integer + (v_put->>'added')::integer;
      blocks_dropped := (v_put->>'dropped')::integer;
    end if;
    outcome := 'done'; reason := case when blocks_dropped > 0 then 'blocks_dropped' end;
    return next;
  end loop;
end
$$;

-- 0005's signature and answer (the cells written), now through the report: the blocks come with the shifts, an absence
-- only when its type carries over (D10)
-- based on: 23_roster.sql
create or replace function cma.roster_copy_week(p_from_week_start date, p_to_week_start date, p_team_key text default null)
returns integer
language sql
as $$
  select count(*)::integer from cma.roster_copy_week_report(p_from_week_start, p_to_week_start, p_team_key) r where r.outcome = 'done'
$$;

-- ---------------------------------------------------------------------------------------------
-- 10. The Standard week (D9)
-- ---------------------------------------------------------------------------------------------
-- The tenant's current Standard week of the people on the roster: per person and weekday the shift or absence and the
-- blocks; roster.manage
create or replace function cma.standard_week()
returns table (
  user_id       uuid,
  iso_weekday   smallint,
  kind          text,
  start_time    time,
  end_time      time,
  absence_key   text,
  absence_name  text,
  note          text,
  assignments   jsonb,
  recorded_at   timestamptz
)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('roster.manage');
  return query
    select e.user_id, e.iso_weekday, e.kind::text, e.start_time, e.end_time, a.key::text, a.name::text, e.note::text,
           coalesce((select jsonb_agg(jsonb_build_object('code', t.code, 'start', to_char(x.start_time, 'HH24:MI'),
                                                         'end', case when x.end_time = '24:00'::time then '24:00' else to_char(x.end_time, 'HH24:MI') end,
                                                         'hoursMarket', x.hours_market_code, 'note', x.note) order by x.start_time)
                     from cma.standard_week_assignment x
                     join cma.assignment_type t on t.tenant_id = x.tenant_id and t.id = x.assignment_type_id
                     where x.tenant_id = e.tenant_id and x.standard_week_entry_id = e.id and x.valid_to is null), '[]'::jsonb),
           e.recorded_at
    from cma.standard_week_entry e
    left join cma.absence_type a on a.tenant_id = e.tenant_id and a.id = e.absence_type_id
    where e.tenant_id = cma.current_tenant_id() and e.valid_to is null
      and cma.on_roster(e.user_id)
    order by e.user_id, e.iso_weekday;
end
$$;

-- Save as standard week (D9): the chosen week of this roster replaces the Standard week of the people on its grid (the
-- rows of other people stay). Per person and weekday: a shift with its blocks, or an absence whose type carries over (D10);
-- an absence that does not carry over is skipped (absence_not_carried) and that weekday stays empty; an empty cell stays
-- empty. The replaced rows end (valid_to; superseded_by: the new row of the same weekday), so they stay readable
create or replace function cma.save_standard_week(p_week_start date, p_team_key text default null)
returns table (user_id uuid, business_date date, outcome text, reason text, blocks integer, blocks_dropped integer)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_team uuid;
  p      record;
  r      record;
  v_new  uuid;
  v_n    integer;
begin
  perform cma.assert_permission('roster.manage');
  perform cma.assert_week_start(p_week_start);
  v_team := cma.roster_team_id(p_team_key);
  for p in
    select u.id from cma.app_user u
    where u.tenant_id = cma.current_tenant_id() and cma.roster_in_scope(u.id, v_team, p_week_start)
    order by u.id
  loop
    -- End this person's current standard rows (blocks first, then the days)
    update cma.standard_week_assignment set valid_to = clock_timestamp()
     where tenant_id = cma.current_tenant_id() and standard_week_assignment.user_id = p.id and valid_to is null;
    update cma.standard_week_entry set valid_to = clock_timestamp()
     where tenant_id = cma.current_tenant_id() and standard_week_entry.user_id = p.id and valid_to is null;

    for r in
      select e.id, e.business_date, e.kind, e.start_time, e.end_time, e.absence_type_id, a.carries_over, e.note
      from cma.roster_entry e
      join cma.roster_week w on w.tenant_id = e.tenant_id and w.id = e.roster_week_id
      left join cma.absence_type a on a.tenant_id = e.tenant_id and a.id = e.absence_type_id
      where e.tenant_id = cma.current_tenant_id() and e.user_id = p.id and e.valid_to is null
        and w.week_start = p_week_start and w.team_id is not distinct from v_team
      order by e.business_date
    loop
      user_id := p.id; business_date := r.business_date; blocks := 0; blocks_dropped := 0;
      if r.kind = 'absence' and not r.carries_over then
        outcome := 'skipped'; reason := 'absence_not_carried'; return next; continue;
      end if;
      insert into cma.standard_week_entry (tenant_id, user_id, iso_weekday, kind, start_time, end_time, absence_type_id, note)
      values (cma.current_tenant_id(), p.id, extract(isodow from r.business_date)::smallint, r.kind, r.start_time, r.end_time,
              r.absence_type_id, r.note)
      returning id into v_new;
      update cma.standard_week_entry o set superseded_by = v_new
       where o.tenant_id = cma.current_tenant_id() and o.user_id = p.id and o.iso_weekday = extract(isodow from r.business_date)
         and o.valid_to >= now() and o.superseded_by is null and o.id <> v_new;
      if r.kind = 'shift' then
        insert into cma.standard_week_assignment (tenant_id, standard_week_entry_id, user_id, iso_weekday, assignment_type_id,
                                                  start_time, end_time, hours_market_code, note)
        select cma.current_tenant_id(), v_new, p.id, extract(isodow from r.business_date)::smallint, x.assignment_type_id,
               x.start_time, x.end_time, x.hours_market_code, x.note
        from cma.roster_assignment x
        where x.tenant_id = cma.current_tenant_id() and x.user_id = p.id and x.business_date = r.business_date and x.valid_to is null;
        get diagnostics v_n = row_count;
        blocks := v_n;
      end if;
      outcome := 'done'; reason := null;
      return next;
    end loop;
  end loop;
end
$$;

-- Apply standard week (D9): fills the week's empty person-dates of this roster from the Standard week and never
-- overwrites. Skipped, with the reason: a date in the person's past (past), a person-date with an entry in this roster
-- (not_empty) or in another (other_roster), an absence whose type is retired or no longer carries over
-- (absence_not_carried). A block that breaks a rule now (a retired type or market, the grid) is dropped and counted
create or replace function cma.apply_standard_week(p_week_start date, p_team_key text default null)
returns table (user_id uuid, business_date date, outcome text, reason text, blocks integer, blocks_dropped integer)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_team uuid;
  v_week uuid;
  r      record;
  v_date date;
  v_put  jsonb;
begin
  perform cma.assert_permission('roster.manage');
  perform cma.assert_week_start(p_week_start);
  v_team := cma.roster_team_id(p_team_key);
  for r in
    select e.user_id, e.iso_weekday, e.kind, e.start_time, e.end_time, a.key as absence_key, a.status as absence_status,
           a.carries_over, e.note,
           coalesce((select jsonb_agg(jsonb_build_object('code', t.code, 'start', to_char(x.start_time, 'HH24:MI'),
                                                         'end', case when x.end_time = '24:00'::time then '24:00' else to_char(x.end_time, 'HH24:MI') end,
                                                         'market', x.hours_market_code, 'note', x.note) order by x.start_time)
                     from cma.standard_week_assignment x
                     join cma.assignment_type t on t.tenant_id = x.tenant_id and t.id = x.assignment_type_id
                     where x.tenant_id = e.tenant_id and x.standard_week_entry_id = e.id and x.valid_to is null), '[]'::jsonb) as blocks
    from cma.standard_week_entry e
    left join cma.absence_type a on a.tenant_id = e.tenant_id and a.id = e.absence_type_id
    where e.tenant_id = cma.current_tenant_id() and e.valid_to is null
      and cma.roster_in_scope(e.user_id, v_team, p_week_start)
    order by e.iso_weekday, e.user_id
  loop
    v_date := p_week_start + (r.iso_weekday - 1);
    user_id := r.user_id; business_date := v_date; blocks := 0; blocks_dropped := 0;
    if v_date < cma.business_date(now(), cma.user_timezone(r.user_id)) then
      outcome := 'skipped'; reason := 'past'; return next; continue;
    end if;
    if exists (select 1 from cma.roster_entry x join cma.roster_week xw on xw.tenant_id = x.tenant_id and xw.id = x.roster_week_id
               where x.tenant_id = cma.current_tenant_id() and x.user_id = r.user_id and x.business_date = v_date and x.valid_to is null
                 and (xw.week_start <> p_week_start or xw.team_id is distinct from v_team)) then
      outcome := 'skipped'; reason := 'other_roster'; return next; continue;
    end if;
    if exists (select 1 from cma.roster_entry x
               where x.tenant_id = cma.current_tenant_id() and x.user_id = r.user_id and x.business_date = v_date and x.valid_to is null) then
      outcome := 'skipped'; reason := 'not_empty'; return next; continue;
    end if;
    if r.kind = 'absence' and (r.absence_status <> 'active' or not r.carries_over) then
      outcome := 'skipped'; reason := 'absence_not_carried'; return next; continue;
    end if;
    perform cma.roster_set_entry(p_week_start, p_team_key, r.user_id, v_date, r.kind, r.start_time, r.end_time, r.absence_key, r.note);
    if r.kind = 'shift' then
      v_week := cma.roster_week_id(p_week_start, v_team);
      v_put := cma.roster_put_assignments(v_week, r.user_id, v_date, r.blocks, false);
      blocks := (v_put->>'added')::integer + (v_put->>'kept')::integer;
      blocks_dropped := (v_put->>'dropped')::integer;
    end if;
    outcome := 'done'; reason := case when blocks_dropped > 0 then 'blocks_dropped' end;
    return next;
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 11. What agents and the Live board see: published blocks only (D7)
-- ---------------------------------------------------------------------------------------------
-- The blocks as of each week's latest publication, as cma.roster_published_entry_all does for the entries: written before
-- it and not ended before it. Owner-only core; two faces
create or replace view cma.roster_published_assignment_all as
  select a.id, a.tenant_id, a.roster_week_id, w.team_id, w.week_start, w.version, w.published_at,
         a.user_id, a.business_date, a.assignment_type_id, a.start_time, a.end_time, a.hours_market_code, a.note,
         a.recorded_at, a.recorded_by
  from cma.roster_assignment a
  join cma.roster_week w on w.tenant_id = a.tenant_id and w.id = a.roster_week_id
  where w.status = 'published'
    and a.recorded_at <= w.published_at
    and (a.valid_to is null or a.valid_to > w.published_at);
revoke all on cma.roster_published_assignment_all from cma_app, cma_readonly, public;

create or replace view cma.roster_published_assignment as
  select * from cma.roster_published_assignment_all where tenant_id = cma.current_tenant_id();

-- A person-date's published blocks of one roster week as JSON for the agent's schedule and the Live board: code, name,
-- kind, work area, is_extra, start, end, the hours market (own market: the person's Default market) and its zone
create or replace function cma.roster_published_blocks_json(p_week_id uuid, p_user_id uuid, p_date date)
returns jsonb
language sql stable
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', t.code, 'name', t.name, 'kind', t.kind, 'workArea', s.work_area, 'isExtra', t.is_extra,
           'start', to_char(a.start_time, 'HH24:MI'),
           'end', case when a.end_time = '24:00'::time then '24:00' else to_char(a.end_time, 'HH24:MI') end,
           'hoursMarket', coalesce(a.hours_market_code, u.default_hours_market_code), 'ownMarket', a.hours_market_code is null,
           'hoursMarketZone', m.time_zone)
           order by a.start_time), '[]'::jsonb)
  from cma.roster_published_assignment a
  join cma.assignment_type t on t.tenant_id = a.tenant_id and t.id = a.assignment_type_id
  left join cma.work_status s on s.tenant_id = t.tenant_id and s.id = t.work_status_id
  join cma.app_user u on u.tenant_id = a.tenant_id and u.id = a.user_id
  left join cma.market m on m.tenant_id = a.tenant_id and m.code = coalesce(a.hours_market_code, u.default_hours_market_code)
  where a.roster_week_id = p_week_id and a.user_id = p_user_id and a.business_date = p_date
$$;

-- The acting user's own published schedule, 0005's, with the date's published blocks last
drop function if exists cma.my_roster(date, date);
-- based on: 23_roster.sql
create function cma.my_roster(p_from date, p_to date)
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
  published_at   timestamptz,
  assignments    jsonb
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
           x.kind::text, x.start_time, x.end_time, x.absence_key, x.absence_name, x.note::text, x.team_name, x.published_at,
           case when x.kind = 'shift' then cma.roster_published_blocks_json(x.roster_week_id, v_user, d::date) else '[]'::jsonb end
    from generate_series(p_from, p_to, interval '1 day') d
    left join lateral (
      select e.kind, e.start_time, e.end_time, a.key::text as absence_key, a.name::text as absence_name, e.note,
             t.name::text as team_name, e.published_at, e.roster_week_id
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

-- Today's published entry per person on the roster, 0009y's, with today's published blocks last (brief B's Live board)
drop function if exists cma.roster_today();
-- based on: 198_roster_planned.sql
create function cma.roster_today()
returns table (
  user_id        uuid,
  business_date  date,
  is_published   boolean,
  kind           text,
  start_time     time,
  end_time       time,
  absence_name   text,
  assignments    jsonb
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
           x.kind::text, x.start_time, x.end_time, x.absence_name,
           case when x.kind = 'shift' then cma.roster_published_blocks_json(x.roster_week_id, u.id, tz.today) else '[]'::jsonb end
    from cma.app_user u
    cross join lateral (select cma.business_date(now(), cma.user_timezone(u.id)) as today) tz
    left join lateral (
      select e.kind, e.start_time, e.end_time, a.name::text as absence_name, e.roster_week_id
      from cma.roster_published_entry e
      left join cma.absence_type a on a.tenant_id = e.tenant_id and a.id = e.absence_type_id
      where e.user_id = u.id and e.business_date = tz.today
      order by e.published_at desc
      limit 1
    ) x on true
    where u.tenant_id = cma.current_tenant_id()
      and cma.on_roster(u.id)
    order by u.display_name, u.id;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 12. Privileges on the functions: the application only
-- ---------------------------------------------------------------------------------------------
revoke execute on function
  cma.roster_planner_zone(), cma.set_absence_carries_over(text, boolean), cma.absence_types(),
  cma.assignment_types(), cma.upsert_assignment_type(text, text, text, text, boolean, integer, text),
  cma.roster_block_minutes(time), cma.roster_blocks_json(uuid, date), cma.roster_other_changes(uuid, uuid, date),
  cma.roster_put_assignments(uuid, uuid, date, jsonb, boolean),
  cma.roster_assignments(date, text), cma.roster_cell(date, text, uuid, date),
  cma.roster_set_assignments(date, text, uuid, date, jsonb, boolean),
  cma.roster_slot_coverage(date, text), cma.roster_planned_hours(date, text),
  cma.roster_week(date, text), cma.roster_people(date, text),
  cma.roster_set_entry(date, text, uuid, date, text, time, time, text, text),
  cma.roster_copy_week_report(date, date, text), cma.roster_copy_week(date, date, text),
  cma.standard_week(), cma.save_standard_week(date, text), cma.apply_standard_week(date, text),
  cma.roster_published_blocks_json(uuid, uuid, date), cma.my_roster(date, date), cma.roster_today()
from public;
grant execute on function
  cma.roster_planner_zone(), cma.set_absence_carries_over(text, boolean), cma.absence_types(),
  cma.assignment_types(), cma.upsert_assignment_type(text, text, text, text, boolean, integer, text),
  cma.roster_block_minutes(time), cma.roster_blocks_json(uuid, date), cma.roster_other_changes(uuid, uuid, date),
  cma.roster_put_assignments(uuid, uuid, date, jsonb, boolean),
  cma.roster_assignments(date, text), cma.roster_cell(date, text, uuid, date),
  cma.roster_set_assignments(date, text, uuid, date, jsonb, boolean),
  cma.roster_slot_coverage(date, text), cma.roster_planned_hours(date, text),
  cma.roster_week(date, text), cma.roster_people(date, text),
  cma.roster_set_entry(date, text, uuid, date, text, time, time, text, text),
  cma.roster_copy_week_report(date, date, text), cma.roster_copy_week(date, date, text),
  cma.standard_week(), cma.save_standard_week(date, text), cma.apply_standard_week(date, text),
  cma.roster_published_blocks_json(uuid, uuid, date), cma.my_roster(date, date), cma.roster_today()
to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 13. absence_type.carries_over and the reporting views (last: the alter's lock is held for the commit alone)
-- ---------------------------------------------------------------------------------------------
alter table cma.absence_type add column if not exists carries_over boolean not null default false;
comment on column cma.absence_type.carries_over is 'Carries over (nl Gaat mee bij kopiëren): Copy week and Save as standard week take an absence of this type';
grant update (carries_over) on cma.absence_type to cma_app;

create or replace view cma_read.absence_type as
  select id, tenant_id, key, name, is_paid, sort_order, status, created_at, updated_at, carries_over
  from cma.absence_type
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.assignment_type as
  select id, tenant_id, code, name, sort_order, status, kind, work_status_id, is_extra, created_at, updated_at
  from cma.assignment_type
  where cma_read.reader_sees(tenant_id);

-- Every version of every block, so plan against actual can be reported as it was planned at the time (brief C)
create or replace view cma_read.roster_assignment as
  select id, tenant_id, roster_week_id, user_id, business_date, assignment_type_id, start_time, end_time, hours_market_code,
         note, recorded_at, recorded_by, valid_to, superseded_by
  from cma.roster_assignment
  where cma_read.reader_sees(tenant_id);

-- The blocks as agents saw them: the latest publication per week
create or replace view cma_read.roster_published_assignment as
  select id, tenant_id, roster_week_id, team_id, week_start, version, published_at, user_id, business_date,
         assignment_type_id, start_time, end_time, hours_market_code, note, recorded_at, recorded_by
  from cma.roster_published_assignment_all
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.standard_week_entry as
  select id, tenant_id, user_id, iso_weekday, kind, start_time, end_time, absence_type_id, note, recorded_at, recorded_by,
         valid_to, superseded_by
  from cma.standard_week_entry
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.standard_week_assignment as
  select id, tenant_id, standard_week_entry_id, user_id, iso_weekday, assignment_type_id, start_time, end_time,
         hours_market_code, note, recorded_at, recorded_by, valid_to, superseded_by
  from cma.standard_week_assignment
  where cma_read.reader_sees(tenant_id);

-- ---------------------------------------------------------------------------------------------
-- 14. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009zw', 'Assignments in the roster, the planner side (brief A): assignment types (tenant configuration, D2), versioned roster assignments inside a shift on the slot grid without overlap (D1, D6, D7), today''s change publishing the week (D8), the Standard week with save and apply (D9), absence types that carry over with Copy week''s report (D10), the planned figures per slot and per person (D12), the published blocks on My schedule and roster_today, the settings roster.slot_minutes, roster.lunch_after_minutes, roster.lunch_type_code and roster.planner_timezone')
on conflict (version) do nothing;

commit;
reset role;
