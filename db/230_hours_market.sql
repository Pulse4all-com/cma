-- =============================================================================================
-- 230_hours_market.sql: addition 0009zo, the Hours market on every start and status event (capture first; the billing
-- statement follows, backlog CMA-137)
-- =============================================================================================
-- Universal: no customer, tenant, market or vendor specifics. Runs unchanged in every database, after 228_work_area.sql
-- (0009zn); it refuses to run before 0009zn is recorded. It needs nothing of #308's 0009zl (224/225), and 0009zl needs
-- nothing of it. Rerunnable, forward-only, in one transaction with a lock timeout. Prod gets no mapping and no default
-- market from this script: every market maps to itself until a tenant maps it in Configuration → Markets, and a
-- person's Default market is set on People.
-- Run as your own IAM login: dev first, then 231_verify_hours_market.sql there (normal, then provoked), then the verifies
-- that read what this changes (below), then 06_seed_dev_time_model.sql again in dev (its section 5 maps one dev market
-- by rule and gives two dev people a Default market), then 131_time_all.sql part a ('team now', 'own day today',
-- 'statuses', 'directory') and part b ('team status time'); then prod, before the merge: this script, 231 and the same
-- verifies (not 06). Main's web runs unchanged on it: its reads take n.* and select * and map the columns they know,
-- its 2-argument cma.set_status call reaches the new function through the defaults (the day's current market is kept),
-- cma.open_workday and cma.correct_workday keep their signatures, so the usual order holds (RUNBOOK 7: prod's migration
-- just before the merge).
--
-- Why (Martin and Kira, 23 November 2026, brief "Hours market on every status change", backlog CMA-136; Decision log,
-- 23 Nov 2026, D1 to D9): Newco invoices Pulse4all monthly for billable hours per type of work (Sales, Operations: the
-- work area, 0009zn) and per country. The CMA records the work area per status but not the country, so December 2026
-- could not be invoiced from it. An agent now books time under an Hours market (D1): a market of the tenant that maps to
-- itself; the tenant maps every other market to one (configuration, never code). Every start and status event carries
-- the hours market it was booked under (D2), the agent changes it on My day (D3), clock-in takes the person's Default
-- market, else the market of their last day, else none (D4), a manager corrects it with a reason (D5), the Live board
-- and the CSVs show it (D6), every event carries it, pauses included (D7), and no figure changes (D8).
--
-- Hardened (Martin, 23 November 2026: "make it as robust and hardened as possible"): the rules hold in the tables, not only in the
-- functions, so a direct write, an import or a later function cannot break them:
--   cma.market.hours_market_code     not null; its own code by default (trigger); a foreign key to a market of the same
--                                    tenant; trigger cma.market_hours_market_rules: a market that is no hours market
--                                    maps to an active hours market (one that maps to itself), a market that others map
--                                    to or that is a person's Default market keeps mapping to itself, and an hours market
--                                    that an active market maps to stays active; changes serialised per tenant
--   cma.app_user.default_hours_market_code
--                                    null or a foreign key to a market of the same tenant; trigger
--                                    cma.app_user_default_hours_market_ok: an active hours market when set or changed
--   cma.time_event.hours_market_code null or a foreign key to a market of the same tenant (not valid: every existing row
--                                    is null, so validation would only scan the table under the lock; it holds for every
--                                    new row); check time_event_hours_market_kind (not valid, same reason): only a start or
--                                    status event carries one; trigger cma.time_event_hours_market_ok: an hours market of
--                                    the event's tenant (inactive allowed: a correction may book a past month's market).
--                                    time_event stays append-only for the application (05, section 5): nobody rewrites
--                                    the market an event was booked under; a correction supersedes the event. The
--                                    trigger also checks an owner's update of the market or the kind
--
-- What it changes
--   cma.is_hours_market(text, boolean), cma.assert_hours_market(text, boolean)
--                               new: an hours market of the current tenant (CMA02 for an unknown market, a market of
--                               another tenant included; CMA04 for one that is no hours market or, unless allowed,
--                               inactive). Invoker, the application's
--   cma.workday_hours_market(uuid, timestamptz)
--                               new: the market of the day's effective start or status event in force at an instant
--                               (default: the latest), ordered as workday_summary_of orders current_status_id
--   cma.resolve_hours_market(text)
--                               new: the hours market a booked market books under now (itself, or the one the tenant mapped
--                               it to since); a kept market goes through it, so a remap never blocks a day booked under it
--   cma.clock_in_hours_market(uuid)
--                               new: D4's rule for a person: the Default market when it is an active hours market, else
--                               the market of their latest effective start or status event when it still is one, else null
--   cma.hours_markets()         new: the tenant's hours markets (code, name, status, sort order) for My day, People and
--                               Correct day; no permission beyond the tenant (as the status list)
--   cma.set_market_hours_market(text, text)
--                               new, tenant.configure: map a market to an hours market (its own code: itself)
--   cma.markets_all()           52's list with hours_market_code last; dropped and created
--   cma.set_person_default_hours_market(uuid, text)
--                               new, as the other People writes (cma.assert_may_manage): set or clear a Default market
--   cma.directory()             26's list with default_hours_market_code last; dropped and created
--   cma.set_status(uuid, text, timestamptz, text)
--                               05's write with p_hours_market_code last (default: keep the market in force, as it books
--                               now: cma.resolve_hours_market), and a null
--                               status key for a market change alone (D3: the same status, booked again under the new
--                               market); the 3-argument signature is dropped, and a 2- or 3-argument call reaches this one
--   cma.open_workday(timestamptz)
--                               162's clock-in, signature unchanged; every start event takes cma.clock_in_hours_market (D4)
--   cma.correct_workday(uuid, date, jsonb, text)
--                               46's corrections, signature unchanged; a start or status change takes "hoursMarket" (an
--                               hours market of the tenant, inactive allowed, or null for none); without the key a change
--                               that supersedes a start or status event keeps that event's market, an added one the market
--                               in force at its time (D5, D3)
--   cma.correct_time_event(uuid, text, timestamptz, text, uuid, text, uuid)
--                               46's single correction, signature unchanged; a start or status correction keeps the market
--                               of the start or status event it supersedes, an added one the market in force
--   cma.team_day(uuid, date)    50's event list with hours_market_code last (Correct day's Market column)
--   cma.team_status_time(date, date, uuid)
--                               228's read with hours_market_code last: the market of the event that opened each stretch,
--                               grouped by it, so a day's status splits per market; ordered as before, then by market
--   cma.team_now()              228's read with hours_market_code last, the day's current market; the current status and
--                               market from one walk of the day's events (the status as the summary's current_status_id:
--                               same filter, same order; 231 R2 compares); jit = off repeated
--   cma.export_status_changes(date, date, uuid)
--                               228's read with hours_market_code last (the status-changes CSV's last column)
--   cma.export_hours(date, date, uuid)
--                               13's read with hours_markets last: the day's hours markets with time, sorted, a null
--                               element for time without one (the Team hours CSV's last column)
--   cma_read.market, cma_read.app_user, cma_read.time_event, cma_read.time_interval
--                               the new column appended last (create or replace view adds a column only at the end)
-- Each read keeps every earlier column and their order; team_now, team_day, export_status_changes, export_hours,
-- markets_all and directory keep their rows; team_status_time splits a status's row per hours market, its sums over a
-- status equal before. 231 compares with the previous definitions, kept inside it, per active tenant (R), and proves equal
-- figures for a fixture day before and after its markets change (B).
--
-- Order, for the locks (CLAUDE.md, Performance; 132, section 10; 228): the functions first (plpgsql reads a column only
-- when it runs), the tables last. cma.app_user is read on every request and cma.time_event by every clock action and
-- every poll: their alters take ACCESS EXCLUSIVE locks held to the commit, so only the small cma.market's backfill, the
-- trigger and constraint DDL, the readers' views and the record of the addition follow them. No index: the time_event
-- reads go by workday and by person as before, and no foreign key here is ever checked from the referenced side (market
-- codes never change and a market is never deleted: delete is revoked from the application, 32).
--
-- Verifies that read what this changes, run again after this script (grep -lw 'cma\.<function>' db/*verify*.sql, the
-- tables and views):
--   04_verify.sql                        cma_read.app_user by named columns; unchanged
--   07_verify_time_model.sql             set_status, open_workday, correct_time_event, cma_read.time_event; unchanged
--   10_verify_corrections.sql            correct_workday, correct_time_event, team_day; unchanged
--   14_verify_tenant_settings.sql        export_hours, export_status_changes by named columns; unchanged
--   16_verify_team_status_time.sql       team_status_time (no market in its tenant, so no split); unchanged
--   18_verify_clock_in_app_links.sql     open_workday(timestamptz), correct_workday by signature; unchanged
--   20_verify_team_now.sql               A3 asserts team_now's columns: edited by this change to expect hours_market_code last
--   22_verify_teams_skills.sql           directory() by named columns; unchanged
--   27_verify_configuration.sql          set_status, correct_time_event, cma_read.app_user; unchanged
--   33_verify_intake_core.sql            cma.market, upsert_market, set_market_status; unchanged
--   43_verify_messaging.sql              open_workday; unchanged
--   45_verify_assignment_alerts.sql      open_workday; unchanged
--   47_verify_workday_window.sql         open_workday(timestamptz), correct_workday, correct_time_event; unchanged
--   51_verify_legacy_time_import.sql     team_day, cma_read.time_event (columns present, not last); unchanged
--   53_verify_sources_configuration.sql  markets_all by named columns; unchanged
--   67_verify_invitations.sql            directory() by named columns; unchanged
--   77_verify_audit_hardening.sql        every cma function without EXECUTE for public (each new one revokes it); unchanged
--   111_verify_import_status_reuse.sql   set_status, open_workday, correct_workday; unchanged
--   127_verify_workday_sessions.sql      open_workday's definition (its pattern kept), team_status_time; unchanged
--   135_verify_hours_reads.sql           S8 asserts cma_read.time_interval's columns: edited by this change to expect
--                                        hours_market_code last; team_now by named columns
--   163_verify_remove_day.sql            open_workday's definition (its pattern kept), team_day; unchanged
--   199_verify_roster_planned.sql        team_now by named columns; unchanged
--   201_verify_live_paid_today.sql       S2 asserts team_now's columns: edited by this change to expect hours_market_code last
--   229_verify_work_area.sql             S3 asserts the reads end with work_area, R1 compares team_status_time row for row:
--                                        edited by this change (S3: work_area after the previous columns, later ones allowed;
--                                        R1: the new read summed over its earlier columns, as a status splits per market)
-- 131_time_all.sql's row 'own day today' is edited by this change to read as the web now does, and two rows are added:
-- 'my day' 'statuses and hours markets' (My day's choices, one statement) and 'team people' 'hours markets' (People's new
-- statement; Correct day's day read takes the same one, and 131 has no Correct day row); 'statuses', 'team now', 'team status time' and 'directory' are unchanged ('statuses' as
-- Welcome reads it; the others read n.* and * and take the new column as it is).
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
select set_config('app.actor_label', 'migration:0009zo', true);   -- the audit trail names the change of section 7

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0009zn') then
    raise exception 'addition 0009zn (228_work_area.sql) must run before 0009zo';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Hours market helpers (plpgsql: they read the new columns only when they run)
-- ---------------------------------------------------------------------------------------------
-- An hours market of the current tenant: a market that maps to itself; active unless p_allow_inactive
create or replace function cma.is_hours_market(p_code text, p_allow_inactive boolean default false)
returns boolean
language plpgsql stable
as $$
begin
  return p_code is not null and exists (
    select 1 from cma.market m
    where m.tenant_id = cma.current_tenant_id() and m.code = p_code and m.hours_market_code = m.code
      and (p_allow_inactive or m.status = 'active'));
end
$$;

-- The same, refused in words: CMA02 for a market the tenant does not have (a market of another tenant included: row-level
-- security and the explicit tenant filter both hide it), CMA04 for one that is no hours market or, unless allowed, inactive.
-- Returns the code
create or replace function cma.assert_hours_market(p_code text, p_allow_inactive boolean default false)
returns text
language plpgsql stable
as $$
declare
  m cma.market;
begin
  if p_code is null or p_code !~ '^[A-Z]{2}$' then
    raise exception 'an hours market is a market code of two upper-case letters, got %', coalesce(p_code, 'none') using errcode = 'CMA04';
  end if;
  select * into m from cma.market where tenant_id = cma.current_tenant_id() and code = p_code;
  if not found then
    raise exception 'no market % in the current tenant', p_code using errcode = 'CMA02';
  end if;
  if m.hours_market_code <> m.code then
    raise exception 'market % is no hours market: its time is booked under %', p_code, m.hours_market_code using errcode = 'CMA04';
  end if;
  if m.status <> 'active' and not p_allow_inactive then
    raise exception 'hours market % is not active', p_code using errcode = 'CMA04';
  end if;
  return m.code;
end
$$;

-- The market of a day's effective start or status event in force at p_at (default: the latest), in the order
-- workday_summary_of takes current_status_id (134): occurred_at, then recorded_at, latest first
create or replace function cma.workday_hours_market(p_workday_id uuid, p_at timestamptz default null)
returns text
language plpgsql stable
as $$
declare
  v_code text;
begin
  select e.hours_market_code into v_code
  from cma.time_event e
  where e.tenant_id = cma.current_tenant_id() and e.workday_id = p_workday_id and e.kind in ('start', 'status')
    and (p_at is null or e.occurred_at <= p_at)
    and not exists (select 1 from cma.time_event c where c.tenant_id = e.tenant_id and c.supersedes_event_id = e.id)
  order by e.occurred_at desc, e.recorded_at desc
  limit 1;
  return v_code;
end
$$;

-- The hours market a booked market books under now: itself while it is an hours market, else the hours market the tenant
-- mapped it to since (an inactive one included). A kept market (a status change without one, a correction that replaces
-- an event) goes through it, so remapping a market never blocks the days booked under it (security review, 23 Nov 2026)
create or replace function cma.resolve_hours_market(p_code text)
returns text
language plpgsql stable
as $$
declare
  v_code text;
begin
  if p_code is null then
    return null;
  end if;
  select m.hours_market_code into v_code
  from cma.market m
  where m.tenant_id = cma.current_tenant_id() and m.code = p_code;
  return v_code;
end
$$;

-- D4: the market a clock-in books under. The person's Default market when it is an active hours market; else the market of
-- their latest effective start or status event (the end of their last day, or of the day's earlier session) when it still
-- is one; else none. The latest event by time_event_user_idx (tenant, person, occurred_at), read backwards
create or replace function cma.clock_in_hours_market(p_user_id uuid)
returns text
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_code   text;
begin
  select u.default_hours_market_code into v_code from cma.app_user u where u.tenant_id = v_tenant and u.id = p_user_id;
  if cma.is_hours_market(v_code) then
    return v_code;
  end if;
  select e.hours_market_code into v_code
  from cma.time_event e
  where e.tenant_id = v_tenant and e.user_id = p_user_id and e.kind in ('start', 'status')
    and not exists (select 1 from cma.time_event c where c.tenant_id = e.tenant_id and c.supersedes_event_id = e.id)
  order by e.occurred_at desc, e.recorded_at desc
  limit 1;
  if cma.is_hours_market(v_code) then
    return v_code;
  end if;
  return null;
end
$$;

revoke execute on function cma.is_hours_market(text, boolean), cma.assert_hours_market(text, boolean),
  cma.workday_hours_market(uuid, timestamptz), cma.resolve_hours_market(text), cma.clock_in_hours_market(uuid) from public, cma_readonly;
grant execute on function cma.is_hours_market(text, boolean), cma.assert_hours_market(text, boolean),
  cma.workday_hours_market(uuid, timestamptz), cma.resolve_hours_market(text), cma.clock_in_hours_market(uuid) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 2. Configuration → Markets: the mapping and the list
-- ---------------------------------------------------------------------------------------------
-- The tenant's hours markets, active and inactive, in the markets' order: My day lists the active ones (D3), People and
-- Correct day every one (a past day or a person may hold an inactive one). Codes and names of configuration only, no
-- permission beyond the tenant, as the status list
create or replace function cma.hours_markets()
returns table (code text, name text, status text, sort_order integer)
language plpgsql stable rows 20
as $$
#variable_conflict use_column
begin
  return query
    select m.code::text, m.name::text, m.status::text, m.sort_order
    from cma.market m
    where m.tenant_id = cma.current_tenant_id() and m.hours_market_code = m.code
    order by (m.status <> 'active'), m.sort_order, m.code collate "C";
end
$$;

-- Map a market to an hours market (D1): its own code makes it an hours market again. The table's trigger holds the rules
-- (section 6); they are checked here first for clearer words, under the same per-tenant lock
create or replace function cma.set_market_hours_market(p_code text, p_hours_market_code text)
returns void
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  m        cma.market;
begin
  perform cma.assert_permission('tenant.configure');
  perform pg_advisory_xact_lock(hashtext('cma.hours_market:' || v_tenant::text));
  select * into m from cma.market where tenant_id = v_tenant and code = p_code for update;
  if not found then
    raise exception 'no market % in the current tenant', p_code using errcode = 'CMA02';
  end if;
  if p_hours_market_code is null or p_hours_market_code = p_code then
    update cma.market set hours_market_code = code
     where tenant_id = v_tenant and id = m.id and hours_market_code is distinct from code;
    return;
  end if;
  perform cma.assert_hours_market(p_hours_market_code);
  update cma.market set hours_market_code = p_hours_market_code
   where tenant_id = v_tenant and id = m.id and hours_market_code is distinct from p_hours_market_code;
end
$$;

-- 52's list with the hours market last
drop function if exists cma.markets_all();
-- based on: 52_sources_configuration.sql
create function cma.markets_all()
returns table (
  code                text,
  name                text,
  time_zone           text,
  language_code       text,
  language_skill_key  text,
  min_language_level  smallint,
  currency            text,
  status              text,
  sort_order          integer,
  aliases             text[],
  hours_market_code   text           -- the hours market its time is booked under (0009zo); its own code for an hours market
)
language plpgsql stable
as $$
#variable_conflict use_column
begin
  perform cma.assert_permission('tenant.configure');
  return query
    select m.code::text, m.name::text, m.time_zone::text, m.language_code::text, m.language_skill_key::text,
           m.min_language_level, m.currency::text, m.status::text, m.sort_order,
           coalesce((select array_agg(a.alias::text order by a.alias) from cma.market_alias a
                     where a.tenant_id = m.tenant_id and a.code = m.code), '{}'::text[]),
           m.hours_market_code::text
    from cma.market m
    where m.tenant_id = cma.current_tenant_id()
    order by (m.status <> 'active'), m.sort_order, m.code;
end
$$;

revoke execute on function cma.hours_markets(), cma.set_market_hours_market(text, text), cma.markets_all() from public, cma_readonly;
grant execute on function cma.hours_markets(), cma.set_market_hours_market(text, text), cma.markets_all() to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 3. People: the Default market
-- ---------------------------------------------------------------------------------------------
-- Set (an active hours market) or clear (null) a person's Default market (D4), as the other People writes: the caller
-- manages the person (cma.assert_may_manage: users.manage_agents or users.manage_all, and the person is theirs to manage)
create or replace function cma.set_person_default_hours_market(p_user_id uuid, p_hours_market_code text)
returns text
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_may_manage(p_user_id);
  perform pg_advisory_xact_lock(hashtext('cma.hours_market:' || v_tenant::text));
  if p_hours_market_code is not null then
    perform cma.assert_hours_market(p_hours_market_code);
  end if;
  update cma.app_user set default_hours_market_code = p_hours_market_code
   where tenant_id = v_tenant and id = p_user_id and default_hours_market_code is distinct from p_hours_market_code;
  return p_hours_market_code;
end
$$;
revoke execute on function cma.set_person_default_hours_market(uuid, text) from public, cma_readonly;
grant execute on function cma.set_person_default_hours_market(uuid, text) to cma_app;

-- 26's directory with the Default market last
drop function if exists cma.directory();
-- based on: 26_configuration.sql
create function cma.directory()
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
  may_edit           boolean,
  default_hours_market_code text     -- the person's Default market (0009zo), null without one
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
           (u.id <> v_user and (v_all or not coalesce(r.is_managing, false))),
           u.default_hours_market_code::text
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
revoke execute on function cma.directory() from public, cma_readonly;
grant execute on function cma.directory() to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 4. The write path: status, clock-in, corrections
-- ---------------------------------------------------------------------------------------------
-- 05's status change with the hours market (D3). p_hours_market_code null keeps the market in force at p_occurred_at;
-- a code books the new status under that active hours market. p_status_key null keeps the status in force: a market
-- change alone, booked as a status event with the same status (which must still be active). A market change alone to
-- the market in force books nothing and answers the event in force, so a repeated pick is harmless; a status given books
-- an event as before 0009zo. A kept market books as it books now (cma.resolve_hours_market): a remap never blocks a day
drop function if exists cma.set_status(uuid, text, timestamptz);
drop function if exists cma.set_status(uuid, text, timestamptz, text);
-- based on: 05_time_model.sql
create function cma.set_status(p_workday_id uuid, p_status_key text, p_occurred_at timestamptz default now(),
                               p_hours_market_code text default null)
returns cma.time_event
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_user   uuid := cma.current_user_id();
  v_status uuid;
  v_market text;
  w        cma.workday;
  e        cma.time_event;
begin
  if v_user is null then
    raise exception 'set_status needs app.user_id, the acting user' using errcode = 'CMA01';
  end if;
  if p_status_key is null and p_hours_market_code is null then
    raise exception 'a change needs a status, a market or both' using errcode = 'CMA04';
  end if;

  select * into w from cma.workday where tenant_id = v_tenant and id = p_workday_id for update;
  if not found or w.user_id <> v_user then
    raise exception 'workday % is not a workday of the acting user', p_workday_id using errcode = 'CMA02';
  end if;
  if w.status = 'ended' then
    raise exception 'workday % is already ended; changes are corrections' , p_workday_id using errcode = 'CMA03';
  end if;
  if p_occurred_at < w.started_at or p_occurred_at > now() + interval '5 minutes' then
    raise exception 'status time must lie between the start of the workday and now' using errcode = 'CMA04';
  end if;

  -- The event in force at the instant: its status and its market are what the change keeps
  select x.* into e
  from cma.time_event x
  where x.tenant_id = v_tenant and x.workday_id = w.id and x.kind in ('start', 'status') and x.occurred_at <= p_occurred_at
    and not exists (select 1 from cma.time_event c where c.tenant_id = x.tenant_id and c.supersedes_event_id = x.id)
  order by x.occurred_at desc, x.recorded_at desc
  limit 1;

  if p_status_key is null then
    select s.id into v_status from cma.work_status s
    where s.tenant_id = v_tenant and s.id = e.status_id and s.status = 'active';
    if v_status is null then
      raise exception 'the current status is not active in this tenant; choose a status' using errcode = 'CMA02';
    end if;
  else
    select id into v_status from cma.work_status
    where tenant_id = v_tenant and key = p_status_key and status = 'active';
    if v_status is null then
      raise exception 'work status "%" is not active in this tenant', p_status_key using errcode = 'CMA02';
    end if;
  end if;

  if p_hours_market_code is null then
    v_market := cma.resolve_hours_market(e.hours_market_code);   -- the market in force, as it books now
  else
    v_market := cma.assert_hours_market(p_hours_market_code);
  end if;

  if p_status_key is null and e.id is not null and v_market is not distinct from e.hours_market_code then
    return e;
  end if;
  -- (a market change alone to the market in force books nothing; a kept market that was remapped books its new one)

  insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source, hours_market_code)
  values (v_tenant, w.id, v_user, 'status', v_status, p_occurred_at, 'user', v_market)
  returning * into e;

  perform cma.refresh_workday(w.id);
  return e;
end
$$;
revoke execute on function cma.set_status(uuid, text, timestamptz, text) from public, cma_readonly;
grant execute on function cma.set_status(uuid, text, timestamptz, text) to cma_app;

-- 162's clock-in, every start event under cma.clock_in_hours_market (D4); otherwise unchanged, so 127's and 163's pattern
-- checks of its definition still hold
-- based on: 162_remove_day.sql
create or replace function cma.open_workday(p_occurred_at timestamptz default now())
returns cma.workday
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_user   uuid := cma.current_user_id();
  v_tz     text;
  v_date   date;
  v_status uuid;
  w        cma.workday;
begin
  if v_user is null then
    raise exception 'open_workday needs app.user_id, the acting user' using errcode = 'CMA01';
  end if;
  if not exists (select 1 from cma.app_user where tenant_id = v_tenant and id = v_user and status = 'active') then
    raise exception 'user % is not an active user of the current tenant', v_user using errcode = 'CMA01';
  end if;

  v_tz   := cma.user_timezone(v_user);
  v_date := cma.business_date(p_occurred_at, v_tz);

  select * into w from cma.workday
  where tenant_id = v_tenant and user_id = v_user and business_date = v_date;
  if found then
    -- A removed day (0009g): no effective event left, so it is no day; Clock in starts it as on a date without one
    if not exists (select 1 from cma.time_event_effective e where e.tenant_id = v_tenant and e.workday_id = w.id) then
      select * into w from cma.workday where tenant_id = v_tenant and id = w.id for update;
      if not exists (select 1 from cma.time_event_effective e where e.tenant_id = v_tenant and e.workday_id = w.id) then
        perform cma.assert_time_kept(v_user);
        if p_occurred_at < cma.business_day_start(w.business_date, w.timezone) then
          raise exception 'the workday starts at %', to_char(cma.setting_of(v_tenant, 'workday.window_start')::time, 'HH24:MI')
            using errcode = 'CMA04';
        end if;
        select id into v_status from cma.work_status
        where tenant_id = v_tenant and is_default and status = 'active';
        if v_status is null then
          raise exception 'no default work status configured for this tenant' using errcode = 'CMA05';
        end if;
        insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source, hours_market_code)
        values (v_tenant, w.id, v_user, 'start', v_status, p_occurred_at, 'user', cma.clock_in_hours_market(v_user));
        perform cma.refresh_workday(w.id);
        select * into w from cma.workday where tenant_id = v_tenant and id = w.id;
      end if;
      return w;
    end if;
    -- Clock in again (0008zp): the person's own ended day, while the rule holds
    if w.status = 'ended' and cma.workday_can_clock_in_again(w.id, p_occurred_at) then
      select * into w from cma.workday where tenant_id = v_tenant and id = w.id for update;
      if cma.workday_can_clock_in_again(w.id, p_occurred_at) then
        select id into v_status from cma.work_status
        where tenant_id = v_tenant and is_default and status = 'active';
        if v_status is null then
          raise exception 'no default work status configured for this tenant' using errcode = 'CMA05';
        end if;
        insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source, hours_market_code)
        values (v_tenant, w.id, v_user, 'start', v_status, p_occurred_at, 'user', cma.clock_in_hours_market(v_user));
        perform cma.refresh_workday(w.id);
        select * into w from cma.workday where tenant_id = v_tenant and id = w.id;
      end if;
    end if;
    return w;
  end if;

  -- Nothing exists yet: only a person whose time is kept gets a day
  perform cma.assert_time_kept(v_user);

  -- and only from the window start of its date
  if p_occurred_at < cma.business_day_start(v_date, v_tz) then
    raise exception 'the workday starts at %', to_char(cma.setting_of(v_tenant, 'workday.window_start')::time, 'HH24:MI')
      using errcode = 'CMA04';
  end if;

  select id into v_status from cma.work_status
  where tenant_id = v_tenant and is_default and status = 'active';
  if v_status is null then
    raise exception 'no default work status configured for this tenant' using errcode = 'CMA05';
  end if;

  begin
    insert into cma.workday (tenant_id, user_id, business_date, timezone, status, started_at)
    values (v_tenant, v_user, v_date, v_tz, 'open', p_occurred_at)
    returning * into w;
  exception
    when unique_violation then          -- a second tab opened the same day a moment earlier
      select * into w from cma.workday
      where tenant_id = v_tenant and user_id = v_user and business_date = v_date;
      return w;
  end;

  insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source, hours_market_code)
  values (v_tenant, w.id, v_user, 'start', v_status, p_occurred_at, 'user', cma.clock_in_hours_market(v_user));

  perform cma.refresh_workday(w.id);
  select * into w from cma.workday where tenant_id = v_tenant and id = w.id;
  return w;
end
$$;

-- 46's corrections with a market per start or status change (D5): "hoursMarket" is an hours market of the tenant (an
-- inactive one allowed: a past month may be corrected after its market was retired) or null for none; without the key, a
-- change that supersedes a start or status event keeps that event's market and an added one the market in force at its
-- time (as a status change, D3), each as it books now (cma.resolve_hours_market). An end or a
-- void carries no market. The reason, the approver (the caller), the four-eyes rule and every earlier check are 46's
-- based on: 46_workday_window.sql
create or replace function cma.correct_workday(
  p_user_id       uuid,
  p_business_date date,
  p_changes       jsonb,
  p_reason        text
)
returns cma.workday
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_actor  uuid;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_exists boolean;
  v_tz     text;
  v_from   timestamptz;
  v_to     timestamptz;
  v_n      bigint;
  v_kind   text;
  v_at     timestamptz;
  v_super  uuid;
  v_status uuid;
  v_market text;
  c        jsonb;
  w        cma.workday;
begin
  v_actor := cma.assert_permission('workday.team');

  if p_user_id is null or not exists (select 1 from cma.app_user where tenant_id = v_tenant and id = p_user_id) then
    raise exception 'user % not found in the current tenant', p_user_id using errcode = 'CMA02';
  end if;
  if p_user_id = v_actor then
    raise exception 'nobody corrects their own day' using errcode = 'CMA06';
  end if;
  if length(v_reason) < 3 or length(v_reason) > 500 then
    raise exception 'a correction needs a reason of 3 to 500 characters' using errcode = 'CMA04';
  end if;
  if p_changes is null or jsonb_typeof(p_changes) <> 'array'
     or jsonb_array_length(p_changes) < 1 or jsonb_array_length(p_changes) > 100 then
    raise exception 'changes must be an array of 1 to 100 changes' using errcode = 'CMA04';
  end if;
  if p_business_date is null then
    raise exception 'a correction needs a date' using errcode = 'CMA04';
  end if;

  select * into w from cma.workday
  where tenant_id = v_tenant and user_id = p_user_id and business_date = p_business_date
  for update;
  v_exists := found;

  -- Add day: a day is created only for someone whose time is kept (0003d)
  if not v_exists then
    perform cma.assert_time_kept(p_user_id);
  end if;

  v_tz := coalesce(w.timezone, cma.user_timezone(p_user_id));
  if p_business_date > cma.business_date(now(), v_tz) then
    raise exception 'the date must be today or earlier in the person''s zone' using errcode = 'CMA04';
  end if;
  v_from := cma.business_day_start(p_business_date, v_tz);
  v_to   := cma.business_day_end(p_business_date, v_tz);

  for c, v_n in select e, n from jsonb_array_elements(p_changes) with ordinality as x(e, n) order by n loop
    if jsonb_typeof(c) <> 'object' then
      raise exception 'change % is not an object', v_n using errcode = 'CMA04';
    end if;
    v_kind := c->>'kind';
    if v_kind is null or v_kind not in ('start', 'status', 'end', 'void') then
      raise exception 'change %: kind must be start, status, end or void', v_n using errcode = 'CMA04';
    end if;

    v_at := null;
    begin
      v_super := nullif(c->>'supersedes', '')::uuid;
      if v_kind <> 'void' then
        if coalesce(c->>'at', '') !~ '(Z|[+-][0-9]{2}:?[0-9]{2})$' then
          raise exception 'change %: the time needs an offset (Z or +hh:mm)', v_n using errcode = 'CMA04';
        end if;
        v_at := (c->>'at')::timestamptz;
      end if;
    exception
      when invalid_text_representation or invalid_datetime_format or datetime_field_overflow then
        raise exception 'change %: invalid time or event id', v_n using errcode = 'CMA04';
    end;

    if v_kind <> 'void' and (v_at < v_from or v_at > v_to or v_at > now() + interval '5 minutes') then
      raise exception 'change %: the time must lie within the corrected day''s window and not in the future', v_n
        using errcode = 'CMA04';
    end if;
    if v_kind = 'void' and v_super is null then
      raise exception 'change %: void needs the event it cancels', v_n using errcode = 'CMA04';
    end if;

    v_status := null;
    if v_kind in ('start', 'status') then
      select id into v_status from cma.work_status
      where tenant_id = v_tenant and key = c->>'statusKey' and status = 'active';
      if v_status is null then
        raise exception 'change %: work status "%" is not active in this tenant', v_n, c->>'statusKey'
          using errcode = 'CMA02';
      end if;
    end if;

    -- The market of the change (0009zo), checked before anything is written
    if c ? 'hoursMarket' and jsonb_typeof(c->'hoursMarket') not in ('string', 'null') then
      raise exception 'change %: hoursMarket is a market code or null', v_n using errcode = 'CMA04';
    end if;
    if v_kind not in ('start', 'status') and nullif(c->>'hoursMarket', '') is not null then
      raise exception 'change %: only a start or a status carries an hours market', v_n using errcode = 'CMA04';
    end if;
    -- The superseded event's own market, given again (the editor sends every row's market), is kept as it books now;
    -- any other code must be an hours market of the tenant
    if v_kind in ('start', 'status') and nullif(c->>'hoursMarket', '') is not null
       and not exists (select 1 from cma.time_event x where x.tenant_id = v_tenant and x.id = v_super
                       and x.kind in ('start', 'status') and x.hours_market_code = c->>'hoursMarket') then
      begin
        perform cma.assert_hours_market(c->>'hoursMarket', true);
      exception
        when sqlstate 'CMA02' then raise exception 'change %: %', v_n, sqlerrm using errcode = 'CMA02';
        when sqlstate 'CMA04' then raise exception 'change %: %', v_n, sqlerrm using errcode = 'CMA04';
      end;
    end if;

    -- Add day: no day on this date yet, so the edit must begin with its start
    if not v_exists then
      if v_kind <> 'start' or v_super is not null then
        raise exception 'there is no day on % yet; the first change must be its start', p_business_date
          using errcode = 'CMA04';
      end if;
      begin
        insert into cma.workday (tenant_id, user_id, business_date, timezone, status, started_at)
        values (v_tenant, p_user_id, p_business_date, v_tz, 'open', v_at)
        returning * into w;
      exception
        when unique_violation then
          raise exception 'a day for % was opened meanwhile; reload it and correct that day', p_business_date
            using errcode = 'CMA04';
      end;
      v_exists := true;
    end if;

    if v_super is not null then
      if not exists (select 1 from cma.time_event
                     where tenant_id = v_tenant and id = v_super and workday_id = w.id) then
        raise exception 'change %: event % does not belong to this day', v_n, v_super using errcode = 'CMA04';
      end if;
      if exists (select 1 from cma.time_event where tenant_id = v_tenant and supersedes_event_id = v_super) then
        raise exception 'change %: event % is already superseded; correct the latest correction instead', v_n, v_super
          using errcode = 'CMA04';
      end if;
    end if;

    v_market := null;
    if v_kind in ('start', 'status') then
      if c ? 'hoursMarket' then
        v_market := cma.resolve_hours_market(nullif(c->>'hoursMarket', ''));
      elsif v_super is not null then
        select cma.resolve_hours_market(x.hours_market_code) into v_market from cma.time_event x
        where x.tenant_id = v_tenant and x.id = v_super and x.kind in ('start', 'status');
      else
        -- a row added without one keeps the market in force at its time, as a status change does (D3)
        v_market := cma.resolve_hours_market(cma.workday_hours_market(w.id, v_at));
      end if;
    end if;

    insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source,
                                supersedes_event_id, reason, approved_by, hours_market_code)
    values (v_tenant, w.id, p_user_id, v_kind, v_status,
            coalesce(v_at, now()),                 -- a void carries no time of its own
            'correction', v_super, v_reason, v_actor, v_market);
  end loop;

  perform cma.refresh_workday(w.id);
  select * into w from cma.workday where tenant_id = v_tenant and id = w.id;
  return w;
end
$$;

-- 46's single correction: a start or status correction keeps the market of the start or status event it supersedes, so
-- no path through the corrections drops a market silently
-- based on: 46_workday_window.sql
create or replace function cma.correct_time_event(
  p_workday_id           uuid,
  p_kind                 text,
  p_occurred_at          timestamptz,
  p_status_key           text,
  p_supersedes_event_id  uuid,
  p_reason               text,
  p_approved_by          uuid
)
returns cma.time_event
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_user   uuid;
  v_status uuid;
  v_market text;
  w        cma.workday;
  e        cma.time_event;
begin
  v_user := cma.assert_permission('workday.team');
  if p_approved_by is distinct from v_user then
    raise exception 'the approver is the person making the correction' using errcode = 'CMA04';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 3 then
    raise exception 'a correction needs a reason' using errcode = 'CMA04';
  end if;
  if p_kind not in ('start', 'status', 'end', 'void') then
    raise exception 'kind must be start, status, end or void' using errcode = 'CMA04';
  end if;

  select * into w from cma.workday where tenant_id = v_tenant and id = p_workday_id for update;
  if not found then
    raise exception 'workday % not found in the current tenant', p_workday_id using errcode = 'CMA02';
  end if;
  if w.user_id = v_user then
    raise exception 'nobody corrects their own day' using errcode = 'CMA06';
  end if;

  if p_supersedes_event_id is not null then
    if not exists (select 1 from cma.time_event
                   where tenant_id = v_tenant and id = p_supersedes_event_id and workday_id = w.id) then
      raise exception 'event % does not belong to workday %', p_supersedes_event_id, w.id using errcode = 'CMA04';
    end if;
    if exists (select 1 from cma.time_event
               where tenant_id = v_tenant and supersedes_event_id = p_supersedes_event_id) then
      raise exception 'event % is already superseded; correct the latest correction instead', p_supersedes_event_id
        using errcode = 'CMA04';
    end if;
  elsif p_kind = 'void' then
    raise exception 'void needs the event it cancels' using errcode = 'CMA04';
  end if;

  if p_kind in ('start', 'status') then
    select id into v_status from cma.work_status
    where tenant_id = v_tenant and key = p_status_key and status = 'active';
    if v_status is null then
      raise exception 'work status "%" is not active in this tenant', p_status_key using errcode = 'CMA02';
    end if;
    if p_supersedes_event_id is not null then
      select cma.resolve_hours_market(x.hours_market_code) into v_market from cma.time_event x
      where x.tenant_id = v_tenant and x.id = p_supersedes_event_id and x.kind in ('start', 'status');
    else
      v_market := cma.resolve_hours_market(cma.workday_hours_market(w.id, p_occurred_at));   -- the market in force
    end if;
  end if;
  if p_kind <> 'void' and (p_occurred_at is null or p_occurred_at > now() + interval '5 minutes') then
    raise exception 'a corrected time must lie in the past' using errcode = 'CMA04';
  end if;
  if p_kind <> 'void' and (p_occurred_at < cma.business_day_start(w.business_date, w.timezone)
                           or p_occurred_at > cma.business_day_end(w.business_date, w.timezone)) then
    raise exception 'a corrected time must lie within the day''s window' using errcode = 'CMA04';
  end if;

  insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source,
                              supersedes_event_id, reason, approved_by, hours_market_code)
  values (v_tenant, w.id, w.user_id, p_kind, v_status,
          coalesce(p_occurred_at, now()),          -- a void carries no time of its own
          'correction', p_supersedes_event_id, btrim(p_reason), v_user, v_market)
  returning * into e;

  perform cma.refresh_workday(w.id);
  return e;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. The reads: Correct day, the Dashboard, the Live board and the two files
-- ---------------------------------------------------------------------------------------------
-- 50's event list with the market each event was booked under last (Correct day's Market column)
drop function if exists cma.team_day(uuid, date);
-- based on: 50_legacy_time_import.sql
create function cma.team_day(p_user_id uuid, p_business_date date)
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
  import_batch_key    text,
  hours_market_code   text           -- the hours market the event was booked under (0009zo); null without one
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
           ib.key::text,
           e.hours_market_code::text
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
revoke execute on function cma.team_day(uuid, date) from public, cma_readonly;
grant execute on function cma.team_day(uuid, date) to cma_app;

-- 228's time per status with the hours market last: the market of the event that opened each stretch (D2), grouped by
-- it, so a status with time under two markets on one day reads as two rows; the earlier order holds, then the market
drop function if exists cma.team_status_time(date, date, uuid);
-- based on: 228_work_area.sql
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
  work_area          text,          -- the status's current work area (0009zn): its group and colour, never a figure
  hours_market_code  text           -- the hours market the stretches were booked under (0009zo); null: no market
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
           ws.work_area,
           e.hours_market_code::text
    from cma.time_interval i
    join cma.workday w      on w.tenant_id = i.tenant_id and w.id = i.workday_id
    join cma.work_status ws on ws.tenant_id = i.tenant_id and ws.id = i.status_id
    join cma.time_event e   on e.tenant_id = i.tenant_id and e.id = i.event_id
    join cma.app_user u     on u.tenant_id = i.tenant_id and u.id = i.user_id
    left join cma.organisation o on o.tenant_id = u.tenant_id and o.id = u.organisation_id
    where w.business_date between p_from and p_to
      and (p_user_id is null or i.user_id = p_user_id)
    group by i.user_id, u.display_name, o.key, o.name, w.business_date, w.timezone,
             ws.id, ws.key, ws.name, ws.sort_order, ws.status,
             ws.is_working, ws.is_productive, ws.is_paid, ws.is_billable, ws.work_area, e.hours_market_code
    order by w.business_date, u.display_name, i.user_id, ws.sort_order, ws.key, e.hours_market_code collate "C" nulls last;
end
$$;
revoke execute on function cma.team_status_time(date, date, uuid) from public, cma_readonly;
grant execute on function cma.team_status_time(date, date, uuid) to cma_app;

-- 228's team now with the day's current hours market last (D6): the market of the latest effective start or status event,
-- as the status is the latest event's; null without a day or without a market
drop function if exists cma.team_now();
-- based on: 228_work_area.sql
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
  work_area           text,          -- the current status's work area (0009zn), for its group and colour
  hours_market_code   text           -- the day's current (or, once ended, last) hours market (0009zo)
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
           ws.work_area,
           hm.hours_market_code::text
    from cma.app_user u
    left join cma.organisation o on o.tenant_id = u.tenant_id and o.id = u.organisation_id
    cross join lateral (select cma.user_timezone(u.id) as zone) tz
    left join lateral (select x.* from cma.workday_summary x
                       where x.user_id = u.id and x.business_date = cma.business_date(now(), tz.zone)
                       limit 1) s on true
    -- The day's latest effective start or status event, by time_event_workday_idx: its status (as the summary's
    -- current_status_id, the same filter and order) and its market, from one walk of the day, so they always agree
    left join lateral (
      select e.status_id, e.hours_market_code
      from cma.time_event e
      where e.tenant_id = u.tenant_id and e.workday_id = s.workday_id and e.kind in ('start', 'status')
        and not exists (select 1 from cma.time_event x where x.tenant_id = e.tenant_id and x.supersedes_event_id = e.id)
      order by e.occurred_at desc, e.recorded_at desc
      limit 1
    ) hm on s.workday_id is not null
    left join cma.work_status ws
           on ws.tenant_id = u.tenant_id and ws.id = hm.status_id
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
revoke execute on function cma.team_now() from public, cma_readonly;
grant execute on function cma.team_now() to cma_app;
alter function cma.team_now() set jit = off;

-- 228's status-changes export with the hours market of each stretch last (D6)
drop function if exists cma.export_status_changes(date, date, uuid);
-- based on: 228_work_area.sql
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
  work_area          text,          -- the status's current work area (0009zn)
  hours_market_code  text           -- the hours market the stretch was booked under (0009zo); null: no market
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
           ws.work_area,
           e.hours_market_code::text
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

-- 13's hours export with the day's hours markets last (D6): the distinct markets of the day's stretches, sorted, and one
-- null element when part of the day was booked under none; one row per day as before
drop function if exists cma.export_hours(date, date, uuid);
-- based on: 13_tenant_settings.sql
create function cma.export_hours(p_from date, p_to date, p_user_id uuid default null)
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
  has_correction      boolean,
  hours_markets       text[]        -- the day's hours markets (0009zo), sorted, a null element for time without one
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
           s.is_capped, s.needs_correction, s.has_correction,
           -- one stretch per effective start or status event (134's workday_stretches_of), so the day's markets are those
           -- events' markets: read from the events by time_event_workday_idx, without the stretches again
           coalesce((select array_agg(distinct (e.hours_market_code::text collate "C") order by (e.hours_market_code::text collate "C") nulls last)
                     from cma.time_event e
                     where e.tenant_id = s.tenant_id and e.workday_id = s.workday_id and e.kind in ('start', 'status')
                       and not exists (select 1 from cma.time_event x where x.tenant_id = e.tenant_id and x.supersedes_event_id = e.id)),
                    '{}'::text[])
    from cma.workday_summary s
    join cma.app_user u on u.tenant_id = s.tenant_id and u.id = s.user_id
    left join cma.organisation o on o.tenant_id = u.tenant_id and o.id = u.organisation_id
    where s.business_date between p_from and p_to
      and (p_user_id is null or s.user_id = p_user_id)
    order by s.business_date, u.display_name, s.user_id;
end
$$;
revoke execute on function cma.export_hours(date, date, uuid), cma.export_status_changes(date, date, uuid) from public, cma_readonly;
grant execute on function cma.export_hours(date, date, uuid), cma.export_status_changes(date, date, uuid) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 6. The rules in the tables: trigger functions (created here, attached in section 7)
-- ---------------------------------------------------------------------------------------------
-- cma.market: a new market is its own hours market unless it names one; a market that is no hours market maps to an active
-- hours market of the same tenant; a market that others map to, or that is a person's Default market, keeps mapping to
-- itself; an hours market that an active market maps to stays active. Serialised per tenant with the write functions
-- (one advisory lock), so two changes at once cannot cross. The caller's rights: under the application's row-level security
-- it sees its own tenant, which is the row's
create or replace function cma.market_hours_market_rules()
returns trigger
language plpgsql
as $$
declare
  t cma.market;
begin
  new.hours_market_code := coalesce(new.hours_market_code, new.code);
  if tg_op = 'UPDATE' and new.hours_market_code is not distinct from old.hours_market_code
     and new.status is not distinct from old.status and new.code is not distinct from old.code then
    return new;
  end if;
  perform pg_advisory_xact_lock(hashtext('cma.hours_market:' || new.tenant_id::text));
  if new.hours_market_code <> new.code then
    select * into t from cma.market where tenant_id = new.tenant_id and code = new.hours_market_code;
    if not found then
      raise exception 'no market % in the tenant to book % under', new.hours_market_code, new.code using errcode = 'CMA02';
    end if;
    if t.hours_market_code <> t.code then
      raise exception 'market % is no hours market (it books under %); map % to an hours market', t.code, t.hours_market_code, new.code
        using errcode = 'CMA04';
    end if;
    if t.status <> 'active' then
      raise exception 'hours market % is not active', t.code using errcode = 'CMA04';
    end if;
    if exists (select 1 from cma.market x where x.tenant_id = new.tenant_id and x.code <> new.code and x.hours_market_code = new.code) then
      raise exception 'market % is the hours market of other markets; map those first', new.code using errcode = 'CMA03';
    end if;
    if exists (select 1 from cma.app_user u where u.tenant_id = new.tenant_id and u.default_hours_market_code = new.code) then
      raise exception 'market % is a person''s Default market; change that on People first', new.code using errcode = 'CMA03';
    end if;
  elsif new.status <> 'active'
        and exists (select 1 from cma.market x where x.tenant_id = new.tenant_id and x.code <> new.code
                    and x.hours_market_code = new.code and x.status = 'active') then
    raise exception 'hours market % books the time of active markets; map those elsewhere before it goes inactive', new.code
      using errcode = 'CMA03';
  end if;
  return new;
end
$$;

-- cma.app_user: a Default market, when set or changed, is an active hours market of the person's tenant
create or replace function cma.app_user_default_hours_market_ok()
returns trigger
language plpgsql
as $$
begin
  if new.default_hours_market_code is null
     or (tg_op = 'UPDATE' and new.default_hours_market_code is not distinct from old.default_hours_market_code) then
    return new;
  end if;
  perform pg_advisory_xact_lock(hashtext('cma.hours_market:' || new.tenant_id::text));
  if not exists (select 1 from cma.market m where m.tenant_id = new.tenant_id and m.code = new.default_hours_market_code
                 and m.hours_market_code = m.code and m.status = 'active') then
    raise exception 'a Default market is an active hours market of the tenant; % is not', new.default_hours_market_code
      using errcode = 'CMA04';
  end if;
  return new;
end
$$;

-- cma.time_event: a market on an event is an hours market of the event's tenant (inactive allowed: a correction may book
-- a past month's market); only a start or status event carries one. One index probe per event with a market
create or replace function cma.time_event_hours_market_ok()
returns trigger
language plpgsql
as $$
begin
  if new.hours_market_code is null then
    return new;
  end if;
  if new.kind not in ('start', 'status') then
    raise exception 'only a start or a status event carries an hours market' using errcode = 'CMA04';
  end if;
  if not exists (select 1 from cma.market m where m.tenant_id = new.tenant_id and m.code = new.hours_market_code
                 and m.hours_market_code = m.code) then
    raise exception 'market % is no hours market of the tenant', new.hours_market_code using errcode = 'CMA04';
  end if;
  return new;
end
$$;
revoke execute on function cma.market_hours_market_rules(), cma.app_user_default_hours_market_ok(), cma.time_event_hours_market_ok()
  from public, cma_readonly, cma_app;

-- ---------------------------------------------------------------------------------------------
-- 7. The columns, their constraints and triggers, and the readers' views, last (CLAUDE.md, Performance; 132, section
--    10; 228): each alter takes an ACCESS EXCLUSIVE lock held to the commit. cma.market first (the others reference it),
--    then cma.time_event (every clock action and poll), then cma.app_user last (every request reads it), so that lock is
--    held the shortest: only DDL without a scan, the readers' views and the record of the addition follow
-- ---------------------------------------------------------------------------------------------
-- cma.market: the column, every market its own hours market, not null, the foreign key to a market of the same tenant
alter table cma.market add column if not exists hours_market_code text;
update cma.market set hours_market_code = code where hours_market_code is null;
alter table cma.market alter column hours_market_code set not null;
do $$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'cma.market'::regclass and conname = 'market_hours_market_fk') then
    alter table cma.market add constraint market_hours_market_fk
      foreign key (tenant_id, hours_market_code) references cma.market (tenant_id, code);
  end if;
end
$$;
comment on column cma.market.hours_market_code is
  'Hours market (docs/definitions.md): the market whose code the time of this market is booked and billed under; its own code for an hours market. Tenant configuration (Configuration → Markets)';
create or replace trigger market_hours_market_rules before insert or update on cma.market
  for each row execute function cma.market_hours_market_rules();

-- cma.time_event: the column without a default (no rewrite), the foreign key and the kind check not valid (no scan: every
-- existing row is null; both hold for every new row), the trigger
alter table cma.time_event add column if not exists hours_market_code text;
do $$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'cma.time_event'::regclass and conname = 'time_event_hours_market_fk') then
    alter table cma.time_event add constraint time_event_hours_market_fk
      foreign key (tenant_id, hours_market_code) references cma.market (tenant_id, code) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'cma.time_event'::regclass and conname = 'time_event_hours_market_kind') then
    alter table cma.time_event add constraint time_event_hours_market_kind
      check (hours_market_code is null or kind in ('start', 'status')) not valid;
  end if;
end
$$;
comment on column cma.time_event.hours_market_code is
  'Hours market (docs/definitions.md) the start or status event was booked under; null: no market. The stretch it opens carries it. Never rewritten: a correction supersedes the event';
create or replace trigger time_event_hours_market_ok before insert or update of hours_market_code, kind on cma.time_event
  for each row execute function cma.time_event_hours_market_ok();

-- cma.app_user: the Default market
alter table cma.app_user add column if not exists default_hours_market_code text;
do $$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'cma.app_user'::regclass and conname = 'app_user_default_hours_market_fk') then
    alter table cma.app_user add constraint app_user_default_hours_market_fk
      foreign key (tenant_id, default_hours_market_code) references cma.market (tenant_id, code);
  end if;
end
$$;
comment on column cma.app_user.default_hours_market_code is
  'Default market (docs/definitions.md): the hours market a clock-in books under; null without one (clock-in then takes the market of the person''s last day)';
create or replace trigger app_user_default_hours_market_ok before insert or update of default_hours_market_code on cma.app_user
  for each row execute function cma.app_user_default_hours_market_ok();

-- The readers' views: each column appended last
create or replace view cma_read.market as
  select id, tenant_id, code, name, time_zone, language_code, language_skill_key, min_language_level, currency,
         status, sort_order, created_at, updated_at, hours_market_code
  from cma.market
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.app_user as
  select id, tenant_id, organisation_id, email, display_name, status, created_at, updated_at, timezone, kind,
         default_hours_market_code
  from cma.app_user
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.time_event as
  select id, tenant_id, workday_id, user_id, kind, status_id, occurred_at, recorded_at, source,
         supersedes_event_id, reason, approved_by, import_batch_id, hours_market_code
  from cma.time_event
  where cma_read.reader_sees(tenant_id);

-- 134's view with the market of the event that opened the stretch (D2), read by the stretch's event id
create or replace view cma_read.time_interval as
  select w.tenant_id, w.id as workday_id, w.user_id, x.event_id, x.status_id,
         x.from_at, x.to_at, x.is_open, x.is_capped, x.seconds,
         (select e.hours_market_code from cma.time_event e where e.tenant_id = w.tenant_id and e.id = x.event_id) as hours_market_code
  from cma.workday w
  cross join lateral (
    select cma.business_day_time(w.business_date, w.timezone,
             (select coalesce(ts.value, st.default_value)::time
              from cma.setting st
              left join cma.tenant_setting ts on ts.tenant_id = w.tenant_id and ts.key = st.key
              where st.key = 'workday.window_end')) as day_end) d
  cross join lateral cma.workday_stretches_reader_of(w.tenant_id, w.id, d.day_end) x
  where cma_read.reader_sees(w.tenant_id);
grant select on cma_read.market, cma_read.app_user, cma_read.time_event, cma_read.time_interval to cma_readonly;

-- ---------------------------------------------------------------------------------------------
-- 8. The addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009zo', 'Hours market on every status change (Martin and Kira, 23 Nov 2026, D1 to D9; CMA-136): cma.market.hours_market_code (not null, its own code by default, an hours market maps to itself, trigger-held), cma.app_user.default_hours_market_code and cma.time_event.hours_market_code (an hours market of the tenant, only on a start or status event; foreign key and check not valid, trigger-held); set_status takes the market last (null keeps it; a null status books a market change alone), open_workday books under the Default market, else the last day''s, else none, correct_workday takes hoursMarket per change, correct_time_event keeps the superseded market; hours_markets, set_market_hours_market, set_person_default_hours_market new; markets_all, directory, team_day, team_status_time (split per market), team_now, export_status_changes and export_hours answer it last; cma_read.market, app_user, time_event and time_interval append it; no figure changes')
on conflict (version) do nothing;

commit;
reset role;
