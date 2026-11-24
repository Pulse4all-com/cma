-- =============================================================================================
-- 228_work_area.sql: addition 0009zn, a status's Work area: Sales and Operations apart in every hours view
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics, and no status key. Runs unchanged in every database, after
-- 222_subscription_moves_entry.sql (0009zk); it refuses to run before 0009zk is recorded. It needs neither #308's 0009zl
-- (224/225) nor #312's 0009zm (226/227), and they need nothing of it. Rerunnable, forward-only, in one
-- transaction with a lock timeout. Prod gets no work area from this script: a tenant sets one in Configuration → Statuses.
-- Run as your own IAM login: dev first, then 229_verify_work_area.sql there (normal, then provoked), then the verifies that
-- read what this changes (below), then 06_seed_dev_time_model.sql again in dev (its section 4 gives the dev tenants' statuses
-- their work areas), then 131_time_all.sql part a ('team now', 'work status flags', 'statuses') and part b ('team status
-- time'); then prod, before the merge: this script, 229 and the same verifies (not 06). Main's web runs unchanged on it:
-- its reads take n.* and select * and map the columns they know, and its 7-argument cma.upsert_work_status call reaches the
-- new function through p_work_area's default (none), so the usual order holds (RUNBOOK 7: prod's migration just before
-- the merge).
--
-- Why (Martin, 23 November 2026, brief "Work area on statuses: Sales green, Operations blue in every hours view"; Decision
-- log, 23 Nov 2026, D1 to D7, amending 7 Oct 2026): a tenant's availability for sales and its availability for operations
-- carry the same flags, so every hours view paints both Leaf Green. Colours come from a status's flags, never from its key
-- or name (5 and 7 October 2026), so a status gets an optional Work area that the views read beside the flags: working and productive with work area
-- sales is the group Sales (Leaf Green), with operations the group Operations (Deep Blue), without one Productive (Leaf
-- Green). A work area changes grouping and colour only, never a figure (worked, paid, billable, productive); it is not frozen
-- when time is booked on the status, and the change is audited like any status edit (cma.audit_log, through
-- setup_tenant_table's trigger on cma.work_status). Views show the status's current work area, history included.
--
-- What it changes
--   cma.work_status.work_area   text null; check work_status_work_area_ok: 'sales' or 'operations'; check
--                               work_status_work_area_flags: only a working and productive status carries one. Existing
--                               rows read null and pass both. The table is small and not on the busy list (CLAUDE.md,
--                               Performance), yet every Live board poll reads it: the alter goes last (section 5), so
--                               the lock it takes is held for the commit alone, under the script's lock timeout.
--   cma_read.work_status        work_area, appended last (create or replace view adds a column only at the end)
--   cma.work_statuses_all()     work_area as its last column (26's definition otherwise); dropped and created (a returned
--                               column cannot be added in place); execute for cma_app only
--   cma.upsert_work_status(text,text,boolean,boolean,boolean,boolean,integer,text)
--                               26's definition with p_work_area last, default null (none): an unknown value and a work area
--                               on a status that is not working and productive are CMA04; the frozen-flags rule (CMA03) reads
--                               the four flags only, so the work area of a status with time behind it changes; the
--                               7-argument signature is dropped, and a 7-argument call reaches this one (it sets none)
--   cma.team_status_time(date,date,uuid)
--                               15's definition with work_area as its last column (grouped by it, beside the flags)
--   cma.team_now()              200's definition with work_area as its last column, the current status's; jit = off repeated
--   cma.export_status_changes(date,date,uuid)
--                               13's definition with work_area as its last column (the status-changes CSV's last column)
-- Each read keeps its rows, order and every earlier column: work_area is a column of the status row each already joins (no
-- new join, no new statement), and a status's group by gains a column functionally dependent on its id. 229 compares the
-- earlier columns with the previous definitions, kept inside it, row for row (R), and proves equal figures before and after
-- a work area is set (B6).
--
-- Verifies that read what this changes, run again after this script (grep -lw 'cma\.<function>' db/*verify*.sql, and the
-- table and view):
--   07_verify_time_model.sql             cma_read.work_status by named columns; unchanged
--   10_verify_corrections.sql            cma.work_status; unchanged
--   14_verify_tenant_settings.sql        cma.export_status_changes by named columns; unchanged
--   16_verify_team_status_time.sql       cma.team_status_time; unchanged
--   18_verify_clock_in_app_links.sql     cma.work_status; unchanged
--   20_verify_team_now.sql               A3 asserts team_now's columns: edited by this change to expect work_area last
--   27_verify_configuration.sql          A5 names the upsert's signature: edited by this change to the 8-argument one
--   51_verify_legacy_time_import.sql     cma.upsert_work_status with 7 arguments; unchanged
--   77_verify_audit_hardening.sql        cma.work_status among the audited tables; unchanged
--   111_verify_import_status_reuse.sql   cma.upsert_work_status with 7 arguments; unchanged
--   127_verify_workday_sessions.sql      team_status_time, export_status_changes, upsert by named columns; unchanged
--   135_verify_hours_reads.sql           E6 compares team_now's named columns; unchanged
--   163_verify_remove_day.sql            team_status_time, upsert; unchanged
--   195_verify_audit_bookkeeping.sql     cma.work_status among the audited tables; unchanged
--   199_verify_roster_planned.sql        B6 reads team_now's named columns; unchanged
--   201_verify_live_paid_today.sql       S2 asserts team_now's columns: edited by this change to expect work_area last
-- 131_time_all.sql's rows 'work status flags' and 'statuses' are edited by this change to read work_area as the web now
-- does; 'team now' and 'team status time' read n.* and * and take the new column as it is. No new statement, no new row.
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
set role cma_owner;

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0009zk') then
    raise exception 'addition 0009zk (222_subscription_moves_entry.sql) must run before 0009zn';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Configuration: the list and the write
-- ---------------------------------------------------------------------------------------------
-- 26's list with the work area last
drop function if exists cma.work_statuses_all();
-- based on: 26_configuration.sql
create function cma.work_statuses_all()
returns table (key text, name text, is_working boolean, is_productive boolean, is_paid boolean, is_billable boolean,
               is_default boolean, sort_order integer, status text, usage_count bigint, work_area text)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('tenant.configure');
  return query
    select s.key::text, s.name::text, s.is_working, s.is_productive, s.is_paid, s.is_billable,
           s.is_default, s.sort_order, s.status::text,
           (select count(*) from cma.time_event e where e.tenant_id = s.tenant_id and e.status_id = s.id),
           s.work_area
    from cma.work_status s
    where s.tenant_id = cma.current_tenant_id()
    order by (s.status <> 'active'), s.sort_order, s.key;
end
$$;

-- 26's write with the work area last. The four flags of a status that already has time behind it cannot change (CMA03);
-- the work area is no flag and changes at any time (D4). A work area stands only on a working, productive status (CMA04,
-- before the table's check would answer 23514). Without p_work_area (a 7-argument call) the status has none.
drop function if exists cma.upsert_work_status(text, text, boolean, boolean, boolean, boolean, integer);
drop function if exists cma.upsert_work_status(text, text, boolean, boolean, boolean, boolean, integer, text);
-- based on: 26_configuration.sql
create function cma.upsert_work_status(p_key text, p_name text, p_is_working boolean, p_is_productive boolean,
                                       p_is_paid boolean, p_is_billable boolean, p_sort_order integer default 100,
                                       p_work_area text default null)
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
  if p_work_area is not null and p_work_area not in ('sales', 'operations') then
    raise exception 'a work area is sales, operations or none' using errcode = 'CMA04';
  end if;
  if p_work_area is not null and not (p_is_working and p_is_productive) then
    raise exception 'only a working and productive status has a work area' using errcode = 'CMA04';
  end if;
  select * into s from cma.work_status where tenant_id = cma.current_tenant_id() and key = p_key for update;
  if not found then
    insert into cma.work_status (tenant_id, key, name, is_working, is_productive, is_paid, is_billable, sort_order, work_area)
    values (cma.current_tenant_id(), p_key, btrim(p_name), p_is_working, p_is_productive, p_is_paid, p_is_billable, coalesce(p_sort_order, 100),
            p_work_area);
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
         is_billable = p_is_billable, sort_order = coalesce(p_sort_order, 100), status = 'active', work_area = p_work_area
   where tenant_id = cma.current_tenant_id() and id = s.id
     and (name, is_working, is_productive, is_paid, is_billable, sort_order, status, work_area)
         is distinct from (btrim(p_name), p_is_working, p_is_productive, p_is_paid, p_is_billable, coalesce(p_sort_order, 100), 'active', p_work_area);
end
$$;

revoke execute on function cma.work_statuses_all(), cma.upsert_work_status(text, text, boolean, boolean, boolean, boolean, integer, text) from public;
grant execute on function cma.work_statuses_all(), cma.upsert_work_status(text, text, boolean, boolean, boolean, boolean, integer, text) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 2. Time per status (the Dashboard): 15's read with the work area last
-- ---------------------------------------------------------------------------------------------
drop function if exists cma.team_status_time(date, date, uuid);
-- based on: 15_team_status_time.sql
create function cma.team_status_time(p_from date, p_to date, p_user_id uuid default null)
returns table (
  user_id            uuid,
  display_name       text,
  organisation_key   text,
  organisation_name  text,
  business_date      date,
  timezone           text,
  status_key         text,
  status_name        text,
  sort_order         integer,
  status_active      boolean,
  is_working         boolean,
  is_productive      boolean,
  is_paid            boolean,
  is_billable        boolean,
  seconds            bigint,
  stretches          integer,
  is_capped          boolean,
  work_area          text           -- the status's current work area (0009zn): its group and colour, never a figure
)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('performance.team');
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 91 then
    raise exception 'the range must run forward and cover at most 92 days' using errcode = 'CMA04';
  end if;
  return query
    select i.user_id, u.display_name::text, o.key::text, coalesce(o.name, '')::text,
           w.business_date, w.timezone::text,
           ws.key::text, ws.name::text, ws.sort_order, (ws.status = 'active'),
           ws.is_working, ws.is_productive, ws.is_paid, ws.is_billable,
           sum(i.seconds)::bigint, count(*)::integer, bool_or(i.is_capped),
           ws.work_area
    from cma.time_interval i
    join cma.workday w      on w.tenant_id = i.tenant_id and w.id = i.workday_id
    join cma.work_status ws on ws.tenant_id = i.tenant_id and ws.id = i.status_id
    join cma.app_user u     on u.tenant_id = i.tenant_id and u.id = i.user_id
    left join cma.organisation o on o.tenant_id = u.tenant_id and o.id = u.organisation_id
    where w.business_date between p_from and p_to
      and (p_user_id is null or i.user_id = p_user_id)
    group by i.user_id, u.display_name, o.key, o.name, w.business_date, w.timezone,
             ws.id, ws.key, ws.name, ws.sort_order, ws.status,
             ws.is_working, ws.is_productive, ws.is_paid, ws.is_billable, ws.work_area
    order by w.business_date, u.display_name, i.user_id, ws.sort_order, ws.key;
end
$$;
revoke execute on function cma.team_status_time(date, date, uuid) from public;
grant execute on function cma.team_status_time(date, date, uuid) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 3. The team now (the Live board): 200's read with the current status's work area last
-- ---------------------------------------------------------------------------------------------
drop function if exists cma.team_now();
-- based on: 200_live_paid_today.sql
create function cma.team_now()
returns table (
  user_id             uuid,
  display_name        text,
  organisation_key    text,
  organisation_name   text,
  timezone            text,
  business_date       date,          -- today in the person's zone
  workday_id          uuid,          -- null when the person has no day today
  day_status          text,          -- 'open', 'ended', or null without a day
  started_at          timestamptz,
  ended_at            timestamptz,
  status_key          text,          -- the day's current (or, once ended, last) status
  status_name         text,
  status_active       boolean,
  is_working          boolean,
  is_productive       boolean,
  is_paid             boolean,
  is_billable         boolean,
  status_since        timestamptz,   -- start of the open stretch; null once the day ended
  closed_seconds      bigint,        -- worked seconds in the closed stretches (is_working)
  running_since       timestamptz,   -- start of the open stretch when it is a working one
  paid_closed_seconds bigint,        -- paid seconds in the closed stretches (is_paid)
  paid_running_since  timestamptz,   -- start of the open stretch when it is a paid one
  work_area           text           -- the current status's work area (0009zn), for its group and colour
)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('monitoring.live');
  return query
    select u.id, u.display_name::text, o.key::text, coalesce(o.name, '')::text, tz.zone::text,
           cma.business_date(now(), tz.zone),
           s.workday_id, s.status::text, s.started_at, s.ended_at,
           ws.key::text, ws.name::text, (ws.status = 'active'),
           ws.is_working, ws.is_productive, ws.is_paid, ws.is_billable,
           c.status_since,
           coalesce(c.closed_seconds, 0)::bigint,
           c.running_since,
           coalesce(c.paid_closed_seconds, 0)::bigint,
           c.paid_running_since,
           ws.work_area
    from cma.app_user u
    left join cma.organisation o on o.tenant_id = u.tenant_id and o.id = u.organisation_id
    cross join lateral (select cma.user_timezone(u.id) as zone) tz
    left join lateral (select x.* from cma.workday_summary x
                       where x.user_id = u.id and x.business_date = cma.business_date(now(), tz.zone)
                       limit 1) s on true
    left join cma.work_status ws
           on ws.tenant_id = u.tenant_id and ws.id = s.current_status_id
    left join lateral (
      select sum(i.seconds) filter (where iws.is_working and (not i.is_open or i.is_capped)) as closed_seconds,
             max(i.from_at) filter (where iws.is_working and i.is_open and not i.is_capped)  as running_since,
             max(i.from_at) filter (where i.is_open and not i.is_capped)                     as status_since,
             sum(i.seconds) filter (where iws.is_paid and (not i.is_open or i.is_capped))    as paid_closed_seconds,
             max(i.from_at) filter (where iws.is_paid and i.is_open and not i.is_capped)     as paid_running_since
      from cma.time_interval i
      join cma.work_status iws on iws.tenant_id = u.tenant_id and iws.id = i.status_id
      where i.workday_id = s.workday_id
    ) c on s.workday_id is not null
    where u.tenant_id = cma.current_tenant_id()
      and cma.time_is_kept(u.id)
    order by u.display_name, u.id;
end
$$;
revoke execute on function cma.team_now() from public;
grant execute on function cma.team_now() to cma_app;
alter function cma.team_now() set jit = off;

-- ---------------------------------------------------------------------------------------------
-- 4. The status-changes export: 13's read with the work area last
-- ---------------------------------------------------------------------------------------------
drop function if exists cma.export_status_changes(date, date, uuid);
-- based on: 13_tenant_settings.sql
create function cma.export_status_changes(p_from date, p_to date, p_user_id uuid default null)
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
  source             text,
  work_area          text           -- the status's current work area (0009zn)
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
           i.from_at, i.to_at, i.is_open, i.is_capped, i.seconds, e.source::text,
           ws.work_area
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
revoke execute on function cma.export_status_changes(date, date, uuid) from public;
grant execute on function cma.export_status_changes(date, date, uuid) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 5. The column, its two checks and the readers' view, last (CLAUDE.md, Performance; 132, section 10): the alter
--    takes an ACCESS EXCLUSIVE lock on cma.work_status, which every Live board poll and clock action reads, and holds it
--    to the commit, so nothing follows it but the record of the addition. The functions above are plpgsql and read the
--    column only when they run
-- ---------------------------------------------------------------------------------------------
alter table cma.work_status add column if not exists work_area text;
comment on column cma.work_status.work_area is
  'Work area (docs/definitions.md): sales, operations or null; only on a working, productive status. Groups and colours the hours views, never a figure; not frozen by time booked on the status';

do $$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'cma.work_status'::regclass and conname = 'work_status_work_area_ok') then
    alter table cma.work_status add constraint work_status_work_area_ok check (work_area in ('sales', 'operations'));
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'cma.work_status'::regclass and conname = 'work_status_work_area_flags') then
    alter table cma.work_status add constraint work_status_work_area_flags check (work_area is null or (is_working and is_productive));
  end if;
end
$$;

-- The readers' view: 05's columns, work_area last
create or replace view cma_read.work_status as
  select id, tenant_id, key, name, is_working, is_productive, is_paid, is_billable, is_default,
         sort_order, status, created_at, updated_at, work_area
  from cma.work_status
  where cma_read.reader_sees(tenant_id);

-- ---------------------------------------------------------------------------------------------
-- 6. The addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009zn', 'Work area on statuses (Martin, 23 Nov 2026, D1 to D7): cma.work_status.work_area (sales, operations or null; only on a working, productive status; never frozen), cma_read.work_status.work_area last; work_statuses_all, team_status_time, team_now and export_status_changes answer it as their last column, every other column, row and order as before; upsert_work_status takes p_work_area last (default none) and drops its 7-argument signature; no figure changes')
on conflict (version) do nothing;

commit;
reset role;
