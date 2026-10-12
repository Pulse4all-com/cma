-- =============================================================================================
-- 50_legacy_time_import.sql: addition 0008d, working time imported from an earlier system
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 48_alert_time_zone.sql (0008c). Rerunnable, forward-only, in one transaction. Run as your own IAM
-- login, dev first, then prod; then 51_verify_legacy_time_import.sql, then 02_seed_<customer>.sql
-- again for the customer's import status, then 07, 10, 14, 16, 27 and 47 again (unchanged). The
-- import itself follows docs/import/README.md.
--
-- What it adds (README: Data model: legacy time import; Martin's decisions of 12 October 2026)
--   the source         cma.time_event.source gains 'import'; an imported event names its batch
--                      (import_batch_id, required for 'import' and only for it). Imported events
--                      are facts like any other: append-only, effective until a correction
--                      supersedes or voids them
--   import_batch       one file from an earlier system: key, source system, file name, period,
--                      the zone its local times are in, staged | loaded | voided, the work status and
--                      the gap status it writes, and at load the snapshots of the tenant's window and
--                      close time, so a later setting change does not rewrite history; who loaded and
--                      voided it, when, the counts and the reason
--   import_session     the login and logout sessions of the file, in local time without an offset,
--                      written only by COPY into cma.import_session_staging by a person holding
--                      tenant.configure, into a staged batch; never updated or deleted
--   import_person_map  which person of the tenant an account of the file is (inactive people too);
--                      sessions of an account without a row are skipped and counted
--   import_day         one row per day a load wrote: the workday, its end event, the sessions behind
--                      it, whether it was closed by the open-session rule or clipped to the window.
--                      The summary view reads it for needs_correction, the void for what to withdraw
--   the functions      cma.stage_import_batch(), cma.load_import_batch(), cma.void_import_batch(), all
--                      for tenant.configure. The load writes per person and local date one workday:
--                      overlapping sessions merged, a session without a logout ended at the close
--                      time (dropped when it starts at or after it), every session clipped to the
--                      window, then one day from the first login to the last logout with the gaps in
--                      the gap status. A date that already has a day of its own is skipped (the CMA's
--                      own days win); a day under one minute is dropped. The work status may be
--                      inactive, as long as no effective event uses it, so it is created inactive and
--                      never offered; the load retires it if it was active. The void withdraws the batch with
--                      void corrections by the caller, so no fact is deleted; the same person-days
--                      can then be loaded by a new batch
--   reporting          workday_summary as in 0008b with two changes, same columns: needs_correction
--                      also covers an imported day closed by the open-session rule or clipped (until a
--                      correction replaces its end, as for a system end), and a day without an
--                      effective start (a withdrawn import) is no day. cma.team_day() gains
--                      import_batch_key for the day editor's history. cma_read.import_batch without
--                      names; cma_read.time_event gains import_batch_id
--
-- SQLSTATEs as before: CMA02 not found, CMA03 conflict (a batch not staged, a key in use), CMA04
-- invalid, CMA06 not permitted.
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
  if not exists (select 1 from cma.schema_migration where version = '0008c') then
    raise exception 'addition 0008c (48_alert_time_zone.sql) must run before 0008d';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The batch
-- ---------------------------------------------------------------------------------------------
create table if not exists cma.import_batch (
  id                uuid primary key default uuidv7(),
  tenant_id         uuid not null default cma.current_tenant_id() references cma.tenant (id),
  key               text not null constraint import_batch_key_format check (key ~ '^[a-z0-9_-]+$' and length(key) <= 64),
  source_system     text not null constraint import_batch_source_system_format check (source_system ~ '^[a-z][a-z0-9_]*$' and length(source_system) <= 40),
  file_name         text not null constraint import_batch_file_name_length check (length(btrim(file_name)) between 1 and 200),
  period_from       date not null,
  period_to         date not null,
  timezone          text not null check (cma.is_timezone(timezone)),
  status            text not null default 'staged' check (status in ('staged', 'loaded', 'voided')),
  work_status_key   text not null,
  gap_status_key    text not null,
  window_start      time,                -- snapshots of the tenant's settings at load
  window_end        time,
  open_session_end  time,
  loaded_by         uuid,
  loaded_at         timestamptz,
  counts            jsonb,
  voided_by         uuid,
  voided_at         timestamptz,
  void_reason       text,
  created_by        uuid default cma.current_user_id(),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, key),
  constraint import_batch_period check (period_to >= period_from),
  constraint import_batch_loaded_together check (
    (loaded_at is null) = (loaded_by is null) and (loaded_at is null) = (counts is null)
    and (loaded_at is null) = (window_start is null) and (loaded_at is null) = (window_end is null)
    and (loaded_at is null) = (open_session_end is null)),
  constraint import_batch_voided_together check (
    (voided_at is null) = (voided_by is null) and (voided_at is null) = (void_reason is null)),
  constraint import_batch_status_matches check (
    case status when 'staged' then loaded_at is null and voided_at is null
                when 'loaded' then loaded_at is not null and voided_at is null
                else voided_at is not null end),
  foreign key (tenant_id, loaded_by)  references cma.app_user (tenant_id, id),
  foreign key (tenant_id, voided_by)  references cma.app_user (tenant_id, id),
  foreign key (tenant_id, created_by) references cma.app_user (tenant_id, id)
);
comment on table cma.import_batch is 'One file of working time from an earlier system: staged, loaded once, withdrawn as a unit. The window and close time are snapshots at load';
create or replace trigger set_updated_at before update on cma.import_batch
  for each row execute function cma.set_updated_at();

-- ---------------------------------------------------------------------------------------------
-- 2. The sessions, the person map and the days written
-- ---------------------------------------------------------------------------------------------
create table if not exists cma.import_session (
  id                    uuid primary key default uuidv7(),
  tenant_id             uuid not null default cma.current_tenant_id() references cma.tenant (id),
  batch_id              uuid not null,
  external_person_id    text not null check (length(btrim(external_person_id)) between 1 and 100),
  external_person_name  text check (external_person_name is null or length(external_person_name) <= 200),
  external_session_id   text not null check (length(btrim(external_session_id)) between 1 and 100),
  login_local           timestamp not null,
  logout_local          timestamp,
  role                  text check (role is null or length(role) <= 100),
  recorded_at           timestamptz not null default clock_timestamp(),
  unique (tenant_id, batch_id, external_session_id),
  constraint import_session_order check (logout_local is null or logout_local >= login_local),
  foreign key (tenant_id, batch_id) references cma.import_batch (tenant_id, id)
);
comment on table cma.import_session is 'Login and logout sessions of an import file, local time in the batch''s zone without an offset. Written by COPY into a staged batch only, never changed';
create index if not exists import_session_batch_idx on cma.import_session (tenant_id, batch_id, external_person_id, login_local);

create table if not exists cma.import_person_map (
  tenant_id           uuid not null default cma.current_tenant_id() references cma.tenant (id),
  batch_id            uuid not null,
  external_person_id  text not null check (length(btrim(external_person_id)) between 1 and 100),
  user_id             uuid not null,
  created_at          timestamptz not null default now(),
  primary key (tenant_id, batch_id, external_person_id),
  foreign key (tenant_id, batch_id) references cma.import_batch (tenant_id, id),
  foreign key (tenant_id, user_id)  references cma.app_user (tenant_id, id)
);
comment on table cma.import_person_map is 'Which person of the tenant an account of an import file is (inactive people allowed). Accounts without a row are skipped and counted';

create table if not exists cma.import_day (
  id               uuid primary key default uuidv7(),
  tenant_id        uuid not null default cma.current_tenant_id() references cma.tenant (id),
  batch_id         uuid not null,
  workday_id       uuid not null,
  user_id          uuid not null,
  business_date    date not null,
  end_event_id     uuid not null,
  sessions         integer not null check (sessions >= 1),
  sessions_merged  integer not null check (sessions_merged >= 0),
  seconds          bigint not null check (seconds >= 60),
  closed_by_rule   boolean not null,
  clipped          boolean not null,
  created_at       timestamptz not null default now(),
  unique (tenant_id, batch_id, workday_id),
  foreign key (tenant_id, batch_id)               references cma.import_batch (tenant_id, id),
  foreign key (tenant_id, workday_id, user_id)    references cma.workday (tenant_id, id, user_id),
  foreign key (tenant_id, end_event_id)           references cma.time_event (tenant_id, id)
);
comment on table cma.import_day is 'One row per day an import load wrote, with its end event and how the rules shaped it (closed by the open-session rule, clipped to the window)';
create index if not exists import_day_workday_idx on cma.import_day (tenant_id, workday_id);

-- ---------------------------------------------------------------------------------------------
-- 3. The time event names its batch
-- ---------------------------------------------------------------------------------------------
alter table cma.time_event add column if not exists import_batch_id uuid;
comment on column cma.time_event.import_batch_id is 'The import batch an event of source import came from; null for every other source';
alter table cma.time_event drop constraint if exists time_event_source_check;
alter table cma.time_event add constraint time_event_source_check
  check (source in ('user', 'system', 'correction', 'import'));
alter table cma.time_event drop constraint if exists time_event_import_needs_batch;
alter table cma.time_event add constraint time_event_import_needs_batch
  check ((source = 'import') = (import_batch_id is not null));
do $$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'cma.time_event'::regclass
                   and conname = 'time_event_import_batch_fkey') then
    alter table cma.time_event add constraint time_event_import_batch_fkey
      foreign key (tenant_id, import_batch_id) references cma.import_batch (tenant_id, id);
  end if;
end
$$;
create index if not exists time_event_import_batch_idx on cma.time_event (tenant_id, import_batch_id)
  where import_batch_id is not null;

-- ---------------------------------------------------------------------------------------------
-- 4. Tenant separation, audit and privileges
-- ---------------------------------------------------------------------------------------------
select cma.setup_tenant_table('cma.import_batch');
select cma.setup_tenant_table('cma.import_session');
select cma.setup_tenant_table('cma.import_person_map');
select cma.setup_tenant_table('cma.import_day');

-- setup_tenant_table grants full write rights; narrow them to what the rules allow. The functions
-- below run as the caller (cma_app), so the batch keeps insert and update; the rest is append-only
revoke delete         on cma.import_batch      from cma_app;
revoke update, delete on cma.import_session    from cma_app;
revoke update, delete on cma.import_person_map from cma_app;
revoke update, delete on cma.import_day        from cma_app;

-- Sessions and map rows are written by a person holding tenant.configure, into a staged batch only;
-- whatever path writes them (COPY, insert)
create or replace function cma.check_import_row()
returns trigger
language plpgsql
as $$
declare
  v_status text;
begin
  perform cma.assert_permission('tenant.configure');
  select b.status into v_status from cma.import_batch b
  where b.tenant_id = new.tenant_id and b.id = new.batch_id;
  if v_status is null then
    raise exception 'import batch % not found in the current tenant', new.batch_id using errcode = 'CMA02';
  end if;
  if v_status <> 'staged' then
    raise exception 'import batch % is %; rows are added to a staged batch only', new.batch_id, v_status using errcode = 'CMA03';
  end if;
  if tg_table_name = 'import_person_map' then   -- nested: a session row has no user_id
    if not exists (select 1 from cma.app_user u where u.tenant_id = new.tenant_id and u.id = new.user_id and u.kind = 'person') then
      raise exception 'a map row names a person of this tenant' using errcode = 'CMA04';
    end if;
  end if;
  return new;
end
$$;
revoke execute on function cma.check_import_row() from public;
create or replace trigger check_import_row before insert on cma.import_session
  for each row execute function cma.check_import_row();
create or replace trigger check_import_row before insert on cma.import_person_map
  for each row execute function cma.check_import_row();

-- The COPY target: the staging file's columns, the batch by its key. Selecting shows the current
-- tenant's staged rows only (the owner's view would otherwise see every tenant)
create or replace view cma.import_session_staging as
  select b.key as batch_key, s.external_person_id, s.external_person_name, s.external_session_id,
         s.login_local, s.logout_local, s.role
  from cma.import_session s
  join cma.import_batch b on b.tenant_id = s.tenant_id and b.id = s.batch_id
  where s.tenant_id = cma.current_tenant_id();

create or replace function cma.import_session_staging_insert()
returns trigger
language plpgsql
as $$
declare
  v_batch uuid;
begin
  select b.id into v_batch from cma.import_batch b
  where b.tenant_id = cma.current_tenant_id() and b.key = new.batch_key;
  if v_batch is null then
    raise exception 'import batch "%" not found in the current tenant', new.batch_key using errcode = 'CMA02';
  end if;
  insert into cma.import_session (tenant_id, batch_id, external_person_id, external_person_name, external_session_id,
                                  login_local, logout_local, role)
  values (cma.current_tenant_id(), v_batch, btrim(new.external_person_id), nullif(btrim(new.external_person_name), ''),
          btrim(new.external_session_id), new.login_local, new.logout_local, nullif(btrim(new.role), ''));
  return new;
end
$$;
revoke execute on function cma.import_session_staging_insert() from public;
create or replace trigger stage_row instead of insert on cma.import_session_staging
  for each row execute function cma.import_session_staging_insert();
revoke all on cma.import_session_staging from public;
grant select, insert on cma.import_session_staging to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 5. Stage: a batch for one file
-- ---------------------------------------------------------------------------------------------
-- The statuses must exist now; whether they may be written is checked at load. The period ends
-- before today in the batch's zone: imported days are history. Called again with the same values
-- for a staged batch, it returns that batch; any other reuse of a key is refused (CMA03)
create or replace function cma.stage_import_batch(p_key text, p_source_system text, p_file_name text,
                                                  p_period_from date, p_period_to date, p_timezone text,
                                                  p_work_status_key text, p_gap_status_key text)
returns cma.import_batch
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  b        cma.import_batch;
begin
  perform cma.assert_permission('tenant.configure');
  if p_key is null or p_key !~ '^[a-z0-9_-]+$' or length(p_key) > 64 then
    raise exception 'a batch key is lowercase letters, digits, - and _, at most 64' using errcode = 'CMA04';
  end if;
  if p_source_system is null or p_source_system !~ '^[a-z][a-z0-9_]*$' or length(p_source_system) > 40 then
    raise exception 'a source system is lowercase letters, digits and _' using errcode = 'CMA04';
  end if;
  if p_file_name is null or length(btrim(p_file_name)) not between 1 and 200 then
    raise exception 'a file name is 1 to 200 characters' using errcode = 'CMA04';
  end if;
  if p_timezone is null or not cma.is_timezone(p_timezone) then
    raise exception 'a batch needs a time zone Postgres knows' using errcode = 'CMA04';
  end if;
  if p_period_from is null or p_period_to is null or p_period_to < p_period_from then
    raise exception 'the period must run forward' using errcode = 'CMA04';
  end if;
  if p_period_to >= cma.business_date(now(), p_timezone) then
    raise exception 'the period must end before today' using errcode = 'CMA04';
  end if;
  if not exists (select 1 from cma.work_status s where s.tenant_id = v_tenant and s.key = p_work_status_key) then
    raise exception 'work status "%" does not exist in this tenant', p_work_status_key using errcode = 'CMA02';
  end if;
  if not exists (select 1 from cma.work_status s where s.tenant_id = v_tenant and s.key = p_gap_status_key) then
    raise exception 'work status "%" does not exist in this tenant', p_gap_status_key using errcode = 'CMA02';
  end if;

  select * into b from cma.import_batch x where x.tenant_id = v_tenant and x.key = p_key;
  if found then
    if b.status = 'staged'
       and (b.source_system, b.file_name, b.period_from, b.period_to, b.timezone, b.work_status_key, b.gap_status_key)
           = (p_source_system, btrim(p_file_name), p_period_from, p_period_to, p_timezone, p_work_status_key, p_gap_status_key) then
      return b;
    end if;
    raise exception 'import batch "%" already exists (%)', p_key, b.status using errcode = 'CMA03';
  end if;

  insert into cma.import_batch (tenant_id, key, source_system, file_name, period_from, period_to, timezone,
                                work_status_key, gap_status_key)
  values (v_tenant, p_key, p_source_system, btrim(p_file_name), p_period_from, p_period_to, p_timezone,
          p_work_status_key, p_gap_status_key)
  returning * into b;
  return b;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. Load: the sessions become workdays, in one transaction
-- ---------------------------------------------------------------------------------------------
-- Refuses a batch not staged (CMA03); an unknown work or gap status (CMA02); a work status that is
-- not working, is the default, or is inactive with time behind it (an effective event of the tenant
-- in it; an inactive status nothing was ever booked on loads, as does a reload after a void, whose
-- events are no longer effective); a gap status that is working or paid; a map row outside the tenant; a
-- session in the spring gap of the batch's zone; a session outside the period; a batch without
-- sessions of a mapped account (all CMA04). Per mapped account and local login date: a session
-- without a logout ends at the close time (dropped when it starts at or after it), every session is
-- clipped to the window, overlapping or touching sessions are merged; then one day from the first
-- login to the last logout: start in the work status, a status change to the gap status at every
-- logout and back to the work status at the next login, the end at the last logout, all source
-- 'import', occurred_at the local time in the batch's zone, recorded_at now. A date that already has
-- a day with effective events is skipped; the day of a withdrawn import is used again. A day under
-- one minute is dropped. Then the work status is retired (nothing to do when it is inactive already)
-- and the batch is loaded with its counts.
create or replace function cma.load_import_batch(p_key text)
returns cma.import_batch
language plpgsql
as $$
declare
  v_tenant   uuid := cma.current_tenant_id();
  v_actor    uuid;
  b          cma.import_batch;
  v_work     cma.work_status;
  v_gap      cma.work_status;
  v_ws       time;
  v_we       time;
  v_oe       time;
  v_n        integer;
  v_txt      text;
  v_end      uuid;
  w          cma.workday;
  r          record;
  c_in       integer;
  c_unmapped integer;
  c_accounts integer;
  c_open     integer;
  c_outside  integer;
  c_merged   integer := 0;
  c_days     integer := 0;
  c_events   integer := 0;
  c_rule     integer := 0;
  c_clipped  integer := 0;
  c_dropped  integer := 0;
  c_existing integer := 0;
begin
  v_actor := cma.assert_permission('tenant.configure');

  select * into b from cma.import_batch x where x.tenant_id = v_tenant and x.key = p_key for update;
  if not found then
    raise exception 'import batch "%" not found in the current tenant', p_key using errcode = 'CMA02';
  end if;
  if b.status <> 'staged' then
    raise exception 'import batch "%" is %; only a staged batch loads', p_key, b.status using errcode = 'CMA03';
  end if;

  -- the two statuses
  select * into v_work from cma.work_status s where s.tenant_id = v_tenant and s.key = b.work_status_key for update;
  if not found then
    raise exception 'work status "%" does not exist in this tenant', b.work_status_key using errcode = 'CMA02';
  end if;
  if not v_work.is_working or v_work.is_default then
    raise exception 'the import''s work status must be a working status that is not the default' using errcode = 'CMA04';
  end if;
  if v_work.status <> 'active'
     and exists (select 1 from cma.time_event_effective e where e.tenant_id = v_tenant and e.status_id = v_work.id) then
    raise exception 'work status "%" is inactive and has time recorded in it; the import writes a status created for it', v_work.key
      using errcode = 'CMA04';
  end if;
  select * into v_gap from cma.work_status s where s.tenant_id = v_tenant and s.key = b.gap_status_key;
  if not found then
    raise exception 'work status "%" does not exist in this tenant', b.gap_status_key using errcode = 'CMA02';
  end if;
  if v_gap.is_working or v_gap.is_paid then
    raise exception 'the gap status must be neither working nor paid' using errcode = 'CMA04';
  end if;

  -- the map stays within the tenant (the foreign key already holds it; checked again here)
  if exists (select 1 from cma.import_person_map m
             where m.tenant_id = v_tenant and m.batch_id = b.id
               and not exists (select 1 from cma.app_user u where u.tenant_id = v_tenant and u.id = m.user_id)) then
    raise exception 'a map row of batch "%" names a person outside this tenant', p_key using errcode = 'CMA04';
  end if;

  -- every session exists in the batch's zone and lies in the period
  select count(*), min(s.external_session_id) into v_n, v_txt
  from cma.import_session s
  where s.tenant_id = v_tenant and s.batch_id = b.id
    and ((s.login_local at time zone b.timezone) at time zone b.timezone <> s.login_local
         or (s.logout_local is not null and (s.logout_local at time zone b.timezone) at time zone b.timezone <> s.logout_local));
  if v_n > 0 then
    raise exception '% session(s) fall in the spring clock change gap of %, first session %', v_n, b.timezone, v_txt using errcode = 'CMA04';
  end if;
  select count(*), min(s.external_session_id) into v_n, v_txt
  from cma.import_session s
  where s.tenant_id = v_tenant and s.batch_id = b.id
    and s.login_local::date not between b.period_from and b.period_to;
  if v_n > 0 then
    raise exception '% session(s) start outside the period % to %, first session %', v_n, b.period_from, b.period_to, v_txt
      using errcode = 'CMA04';
  end if;

  -- the snapshots
  v_ws := cma.setting_of(v_tenant, 'workday.window_start')::time;
  v_we := cma.setting_of(v_tenant, 'workday.window_end')::time;
  v_oe := cma.setting_of(v_tenant, 'workday.auto_close_at')::time;

  -- what comes in and what is skipped
  select count(*),
         count(*) filter (where m.user_id is null),
         count(distinct s.external_person_id) filter (where m.user_id is null),
         count(*) filter (where m.user_id is not null and s.logout_local is null and s.login_local::time >= v_oe)
  into c_in, c_unmapped, c_accounts, c_open
  from cma.import_session s
  left join cma.import_person_map m
    on m.tenant_id = s.tenant_id and m.batch_id = s.batch_id and m.external_person_id = s.external_person_id
  where s.tenant_id = v_tenant and s.batch_id = b.id;
  if c_in = c_unmapped then
    raise exception 'import batch "%" has no session of a mapped account', p_key using errcode = 'CMA04';
  end if;

  select count(*) into c_outside
  from cma.import_session s
  join cma.import_person_map m
    on m.tenant_id = s.tenant_id and m.batch_id = s.batch_id and m.external_person_id = s.external_person_id
  where s.tenant_id = v_tenant and s.batch_id = b.id
    and (s.logout_local is not null or s.login_local::time < v_oe)
    and least(coalesce(s.logout_local, s.login_local::date + v_oe), s.login_local::date + v_we)
        <= greatest(s.login_local, s.login_local::date + v_ws);

  -- per person and local date: the merged stretches and the flags
  for r in
    with src as (
      select m.user_id, s.login_local::date as d,
             s.logout_local is null as was_open,
             s.login_local at time zone b.timezone as login_at,
             case when s.logout_local is not null then s.logout_local at time zone b.timezone
                  when s.login_local::time < v_oe then cma.business_day_time(s.login_local::date, b.timezone, v_oe)
             end as logout_at
      from cma.import_session s
      join cma.import_person_map m
        on m.tenant_id = s.tenant_id and m.batch_id = s.batch_id and m.external_person_id = s.external_person_id
      where s.tenant_id = v_tenant and s.batch_id = b.id
    ),
    bounded as (
      select x.user_id, x.d, x.was_open and x.logout_at is not null as by_rule,
             x.logout_at is not null
               and (x.login_at < cma.business_day_time(x.d, b.timezone, v_ws)
                    or x.logout_at > cma.business_day_time(x.d, b.timezone, v_we)) as clipped,
             greatest(x.login_at, cma.business_day_time(x.d, b.timezone, v_ws)) as f,
             case when x.logout_at is not null   -- least() ignores a null: a dropped session has no end
                  then least(x.logout_at, cma.business_day_time(x.d, b.timezone, v_we)) end as t
      from src x
    ),
    live as (
      select y.user_id, y.d, y.f, y.t,
             max(y.t) over (partition by y.user_id, y.d order by y.f, y.t rows between unbounded preceding and 1 preceding) as prev_t
      from bounded y
      where y.t > y.f
    ),
    islands as (
      select z.*, sum(case when z.prev_t is null or z.f > z.prev_t then 1 else 0 end)
                    over (partition by z.user_id, z.d order by z.f, z.t rows unbounded preceding) as grp
      from live z
    ),
    merged as (
      select i.user_id, i.d, i.grp, min(i.f) as f, max(i.t) as t, count(*)::integer as n
      from islands i
      group by i.user_id, i.d, i.grp
    ),
    days as (
      select g.user_id, g.d,
             array_agg(g.f order by g.f) as fs,
             array_agg(g.t order by g.f) as ts,
             sum(g.n)::integer as sessions,
             (sum(g.n) - count(*))::integer as merged,
             sum(floor(extract(epoch from (g.t - g.f))))::bigint as seconds
      from merged g
      group by g.user_id, g.d
    ),
    flags as (
      select y.user_id, y.d, bool_or(y.by_rule) as by_rule, bool_or(y.clipped) as clipped
      from bounded y
      group by y.user_id, y.d
    )
    select fl.user_id, fl.d, fl.by_rule, fl.clipped, dy.fs, dy.ts,
           coalesce(dy.sessions, 0) as sessions, coalesce(dy.merged, 0) as merged, coalesce(dy.seconds, 0) as seconds
    from flags fl
    left join days dy on dy.user_id = fl.user_id and dy.d = fl.d
    order by fl.d, fl.user_id
  loop
    if r.seconds < 60 then
      c_dropped := c_dropped + 1;
      continue;
    end if;

    -- the CMA's own days win; the day of a withdrawn import (no effective event left) is used again
    select * into w from cma.workday x
    where x.tenant_id = v_tenant and x.user_id = r.user_id and x.business_date = r.d
    for update;
    if found then
      if w.timezone <> b.timezone
         or exists (select 1 from cma.time_event_effective e where e.tenant_id = v_tenant and e.workday_id = w.id) then
        c_existing := c_existing + 1;
        continue;
      end if;
    else
      insert into cma.workday (tenant_id, user_id, business_date, timezone, status, started_at)
      values (v_tenant, r.user_id, r.d, b.timezone, 'open', r.fs[1])
      returning * into w;
    end if;

    insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, recorded_at, source, import_batch_id)
    values (v_tenant, w.id, r.user_id, 'start', v_work.id, r.fs[1], now(), 'import', b.id);
    for v_n in 2 .. cardinality(r.fs) loop
      insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, recorded_at, source, import_batch_id)
      values (v_tenant, w.id, r.user_id, 'status', v_gap.id, r.ts[v_n - 1], now(), 'import', b.id),
             (v_tenant, w.id, r.user_id, 'status', v_work.id, r.fs[v_n], now(), 'import', b.id);
    end loop;
    insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, recorded_at, source, import_batch_id)
    values (v_tenant, w.id, r.user_id, 'end', null, r.ts[cardinality(r.ts)], now(), 'import', b.id)
    returning id into v_end;
    perform cma.refresh_workday(w.id);

    insert into cma.import_day (tenant_id, batch_id, workday_id, user_id, business_date, end_event_id, sessions,
                                sessions_merged, seconds, closed_by_rule, clipped)
    values (v_tenant, b.id, w.id, r.user_id, r.d, v_end, r.sessions, r.merged, r.seconds, r.by_rule, r.clipped);

    c_days    := c_days + 1;
    c_events  := c_events + 2 * cardinality(r.fs);
    c_merged  := c_merged + r.merged;
    c_rule    := c_rule + case when r.by_rule then 1 else 0 end;
    c_clipped := c_clipped + case when r.clipped then 1 else 0 end;
  end loop;

  -- nobody chooses the import's status afterwards (a no-op for a status seeded inactive)
  perform cma.retire_work_status(v_work.key);

  update cma.import_batch x
  set status = 'loaded', window_start = v_ws, window_end = v_we, open_session_end = v_oe,
      loaded_by = v_actor, loaded_at = now(),
      counts = jsonb_build_object(
        'sessions_in', c_in, 'sessions_unmapped', c_unmapped, 'accounts_skipped', c_accounts,
        'sessions_open_dropped', c_open, 'sessions_outside_window', c_outside, 'sessions_merged', c_merged,
        'days_written', c_days, 'events_written', c_events, 'days_closed_by_rule', c_rule,
        'days_clipped', c_clipped, 'days_dropped', c_dropped, 'days_skipped_existing', c_existing)
  where x.tenant_id = v_tenant and x.id = b.id
  returning * into b;
  return b;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. Void: the batch withdrawn as a unit, no fact deleted
-- ---------------------------------------------------------------------------------------------
-- Every effective event of every day the batch wrote (corrections made on those days since
-- included) gets a void correction by the caller, with the batch key in the reason; the days then
-- have no effective event, so the summary no longer counts them, and a new batch may load the same
-- person-days. A staged batch is simply marked voided. A voided batch is refused (CMA03).
create or replace function cma.void_import_batch(p_key text, p_reason text)
returns cma.import_batch
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_actor  uuid;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_n      integer := 0;
  b        cma.import_batch;
  e        record;
begin
  v_actor := cma.assert_permission('tenant.configure');
  if length(v_reason) < 3 or length(v_reason) > 500 then
    raise exception 'a void needs a reason of 3 to 500 characters' using errcode = 'CMA04';
  end if;
  select * into b from cma.import_batch x where x.tenant_id = v_tenant and x.key = p_key for update;
  if not found then
    raise exception 'import batch "%" not found in the current tenant', p_key using errcode = 'CMA02';
  end if;
  if b.status = 'voided' then
    raise exception 'import batch "%" is already voided', p_key using errcode = 'CMA03';
  end if;

  for e in
    select f.id, f.workday_id, f.user_id
    from cma.import_day d
    join cma.workday w on w.tenant_id = d.tenant_id and w.id = d.workday_id
    join cma.time_event_effective f on f.tenant_id = d.tenant_id and f.workday_id = d.workday_id
    where d.tenant_id = v_tenant and d.batch_id = b.id
    order by d.business_date, d.user_id, f.occurred_at, f.recorded_at, f.id
    for update of w
  loop
    insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, recorded_at, source,
                                supersedes_event_id, reason, approved_by)
    values (v_tenant, e.workday_id, e.user_id, 'void', null, now(), now(), 'correction',
            e.id, format('Import %s withdrawn: %s', b.key, v_reason), v_actor);
    v_n := v_n + 1;
  end loop;

  update cma.import_batch x
  set status = 'voided', voided_by = v_actor, voided_at = now(), void_reason = v_reason,
      counts = case when x.counts is null then null else x.counts || jsonb_build_object('events_voided', v_n) end
  where x.tenant_id = v_tenant and x.id = b.id
  returning * into b;
  return b;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 8. Reporting: the summary, the day editor's history, the readers' views
-- ---------------------------------------------------------------------------------------------
-- The summary as in 0008b with two changes, same columns: needs_correction also covers an imported
-- day closed by the open-session rule or clipped to the window, while the import's end is effective
-- (a correction that replaces the end clears it, as for a system end); and a day without an
-- effective start is no day (only a withdrawn import leaves one: refresh_workday refuses it otherwise)
create or replace view cma.workday_summary_all as
  select w.id as workday_id, w.tenant_id, w.user_id, w.business_date, w.timezone, w.status,
         w.started_at, w.ended_at,
         coalesce(sum(i.seconds) filter (where s.is_working),    0)::bigint as working_seconds,
         coalesce(sum(i.seconds) filter (where s.is_productive), 0)::bigint as productive_seconds,
         coalesce(sum(i.seconds) filter (where s.is_paid),       0)::bigint as paid_seconds,
         coalesce(sum(i.seconds) filter (where s.is_billable),   0)::bigint as billable_seconds,
         coalesce(bool_or(i.is_capped), false) as is_capped,
         ((w.status = 'open'
           and now() > cma.business_day_time(w.business_date, w.timezone,
                         (select coalesce(ts.value, st.default_value)::time
                          from cma.setting st
                          left join cma.tenant_setting ts on ts.tenant_id = w.tenant_id and ts.key = st.key
                          where st.key = 'workday.window_end')))
          or exists (select 1 from cma.time_event_effective_all e
                     where e.tenant_id = w.tenant_id and e.workday_id = w.id and e.kind = 'end' and e.source = 'system')
          or exists (select 1 from cma.import_day d
                     join cma.time_event_effective_all e on e.tenant_id = d.tenant_id and e.id = d.end_event_id
                     where d.tenant_id = w.tenant_id and d.workday_id = w.id and (d.closed_by_rule or d.clipped))) as needs_correction,
         exists (select 1 from cma.time_event e
                 where e.tenant_id = w.tenant_id and e.workday_id = w.id and e.source = 'correction') as has_correction,
         (select e.status_id from cma.time_event_effective_all e
          where e.tenant_id = w.tenant_id and e.workday_id = w.id and e.kind in ('start', 'status')
          order by e.occurred_at desc, e.recorded_at desc limit 1) as current_status_id
  from cma.workday w
  left join cma.time_interval_all i on i.tenant_id = w.tenant_id and i.workday_id = w.id
  left join cma.work_status s on s.tenant_id = i.tenant_id and s.id = i.status_id
  where exists (select 1 from cma.time_event_effective_all e
                where e.tenant_id = w.tenant_id and e.workday_id = w.id and e.kind = 'start')
  group by w.id;
revoke all on cma.time_interval_all, cma.workday_summary_all from cma_app, cma_readonly, public;

-- team_day as in 0003, plus the batch key of an imported event; the result changes, so the function
-- is replaced once
do $$
begin
  if to_regprocedure('cma.team_day(uuid,date)') is not null
     and not exists (select 1 from pg_proc p
                     where p.oid = to_regprocedure('cma.team_day(uuid,date)')
                       and 'import_batch_key' = any (p.proargnames)) then
    drop function cma.team_day(uuid, date);
  end if;
end
$$;

create or replace function cma.team_day(p_user_id uuid, p_business_date date)
returns table (
  event_id            uuid,
  kind                text,
  status_key          text,
  status_name         text,
  occurred_at         timestamptz,
  recorded_at         timestamptz,
  source              text,
  supersedes_event_id uuid,
  reason              text,
  approved_by_name    text,
  is_effective        boolean,
  import_batch_key    text
)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('workday.team');
  return query
    select e.id, e.kind::text, ws.key::text, ws.name::text, e.occurred_at, e.recorded_at, e.source::text,
           e.supersedes_event_id, e.reason, a.display_name::text,
           exists (select 1 from cma.time_event_effective f where f.tenant_id = e.tenant_id and f.id = e.id),
           ib.key::text
    from cma.time_event e
    join cma.workday w on w.tenant_id = e.tenant_id and w.id = e.workday_id
    left join cma.work_status ws on ws.tenant_id = e.tenant_id and ws.id = e.status_id
    left join cma.app_user a on a.tenant_id = e.tenant_id and a.id = e.approved_by
    left join cma.import_batch ib on ib.tenant_id = e.tenant_id and ib.id = e.import_batch_id
    where w.tenant_id = cma.current_tenant_id()
      and w.user_id = p_user_id and w.business_date = p_business_date
    order by e.occurred_at, e.recorded_at, e.id;
end
$$;

-- Readers: the batch without names (no file name, no free-text reason); the events with their batch
create or replace view cma_read.import_batch as
  select id, tenant_id, key, source_system, period_from, period_to, timezone, status, work_status_key,
         gap_status_key, window_start, window_end, open_session_end, loaded_by, loaded_at, counts,
         voided_by, voided_at, created_at, updated_at
  from cma.import_batch
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.time_event as
  select id, tenant_id, workday_id, user_id, kind, status_id, occurred_at, recorded_at, source,
         supersedes_event_id, reason, approved_by, import_batch_id
  from cma.time_event
  where cma_read.reader_sees(tenant_id);

-- ---------------------------------------------------------------------------------------------
-- 9. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.stage_import_batch(text,text,text,date,date,text,text,text)',
    'cma.load_import_batch(text)',
    'cma.void_import_batch(text,text)',
    'cma.team_day(uuid,date)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

insert into cma.schema_migration (version, description)
values ('0008d', 'Legacy time import: time_event source import with its batch, import batches staged, loaded and withdrawn as a unit, sessions, the person map and the days written; stage, load and void for tenant.configure; imported days closed by rule or clipped need a correction, a withdrawn day is no day; the batch key in the day history')
on conflict (version) do nothing;

commit;
reset role;
