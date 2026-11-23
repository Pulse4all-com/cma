-- =============================================================================================
-- 225_verify_work_area.sql: verifies addition 0009zl, a status's Work area (cma.work_status.work_area and the reads that
-- answer it)
-- =============================================================================================
-- Universal: no seed is assumed, so it runs in dev and in prod. Two kinds of checks:
--   on a throwaway tenant (B): invented people (example.invalid) whose days are written through the clock's own functions
--     at fixed local times, the statuses configured through cma.upsert_work_status as the tenant's admin, the whole step
--     rolled back;
--   on every active tenant (R): the new reads against the previous definitions (kept below: 15, 200, 13 and 26), every
--     earlier column row for row and in order, as the application (cma_app, row-level security on), in a step that is
--     always rolled back.
-- Run as your own IAM login, after 224. Output: tenant slugs, counts, check names, the throwaway people's invented short
-- names and labels for the throwaway tenant's statuses; no real person's name and no status key.
--
-- The throwaway tenant's clock: its people live in the zone where it is between 09:00 and 12:00 now (Etc/GMT zones, whole
-- hours, 201's way), so every event below lies in the past of today's business date whatever the hour. Statuses are
-- picked by flag from the tenant's own seeded list: the default (working, productive, paid; label "default"), a working
-- status that is not productive ("other") and a paid pause ("pause"); the admin adds a second working, productive status
-- ("ops") and one without time ("free").
--   a1   clock in 05:00 (default), other from 06:00, default from 06:30, a pause from 07:00, still in it
--   a2   clock in 05:00 (default), ops from 06:00, log out 07:00
--   a3   clock in 05:00 (default), still working
--
-- Checks
--   S1  the addition 0009zl is recorded once, after 0009zk
--   S2  cma.work_status.work_area: text, nullable, its two checks; cma_read.work_status ends with work_area and the
--       readers may read it
--   S3  the five functions: work_area as the last returned column after the previous ones; the 7-argument upsert gone, the
--       8-argument one with p_work_area last and two defaults; cma_owner's, the application's to execute (not public's,
--       not the readers'), the caller's rights; the reads stable, team_now jit = off
--   B1  a work area on a status that is not working and productive is refused: the upsert on a status that is not
--       productive (CMA04), a flag change that would leave a work area on a status no longer productive (CMA04), and the
--       table's check on a direct write (23514)
--   B2  an unknown value is refused: the upsert (CMA04, also for 'Sales', the label) and the table's check (23514)
--   B3  the upsert and the list without tenant.configure are refused (CMA06), for an agent and for the manager
--   B4  the work area of a status with time behind it changes (not frozen), the change is in cma.audit_log as the admin's,
--       its flags stay frozen (CMA03), and a call without p_work_area (7 arguments) sets none
--   B5  the reads answer the stored work area: cma.team_status_time, cma.team_now, cma.export_status_changes,
--       cma.work_statuses_all and cma_read.work_status
--   B6  figures for the day are equal before and after the work areas are set: team_status_time and
--       export_status_changes without work_area, cma.team_hours (every column) and team_now without work_area
--   R1  per active tenant: team_status_time's seventeen earlier columns equal 15's definition over the last 31 days
--   R2  per active tenant: team_now's twenty-two earlier columns equal 200's definition
--   R3  per active tenant: export_status_changes' eighteen earlier columns equal 13's definition over the last 31 days
--   R4  per active tenant: work_statuses_all's ten earlier columns equal 26's definition
-- Each R check acts as the tenant's first active person holding the read's permission (131's choice) and reads skip
-- without one.
-- Provoke: verify.provoke below. 'true': every check reads FAIL and the verdict says PROVOKED, NOT A PASS. A check's id:
-- that check alone fails. The R checks drop the old side's first row, so the comparison itself must find the difference
-- (a compare of no rows reads FAIL under the switch).
-- Collation: every ordering that feeds a compared text says collate "C".
-- Expected verdict: "PASS | 225_verify_work_area: <n> PASS, 0 FAIL, <k> skip".
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);                 -- 'true' for every check, or one check's id such as 'B2'

drop table if exists pg_temp.verify_0009zl;
create temporary table verify_0009zl (ord integer, check_name text, result text, detail text);
grant select, insert on pg_temp.verify_0009zl to cma_app;

create or replace function pg_temp.v0009zl_p(p_id text)
returns boolean
language sql stable
as $$
  select current_setting('verify.provoke') in ('true', p_id)
$$;

-- One check's row: PASS when what was found equals what is expected; provoked, the expectation carries a deliberate difference
create or replace function pg_temp.v0009zl_row(p_ord integer, p_id text, p_name text, p_found text, p_expected text)
returns void
language plpgsql
as $$
declare
  v_exp text := case when pg_temp.v0009zl_p(p_id) then coalesce(p_expected, '') || ' [provoked: a deliberate difference]' else p_expected end;
begin
  insert into pg_temp.verify_0009zl values (p_ord, p_id || ' ' || p_name,
    case when p_found is not distinct from v_exp then 'PASS' else 'FAIL' end,
    case when p_found is not distinct from v_exp then left(coalesce(p_found, 'null'), 600)
         else left('found ' || coalesce(p_found, 'null') || ' | expected ' || coalesce(v_exp, 'null'), 2400) end);
end
$$;

-- Two reads compared row for row and in order (201's comparison); provoked for the check, the old side loses its first
-- row. Null when equal, otherwise what differs
create or replace function pg_temp.v0009zl_diff(p_id text, p_new text, p_old text)
returns text
language plpgsql
as $$
declare
  v_old text := p_old;
  v_n_new bigint; v_n_old bigint; v_only_new bigint; v_only_old bigint; v_same boolean;
begin
  if pg_temp.v0009zl_p(p_id) then
    v_old := format('select * from (%s) z offset 1', p_old);
  end if;
  execute format('select count(*) from (%s) a', p_new) into v_n_new;
  execute format('select count(*) from (%s) a', v_old) into v_n_old;
  if pg_temp.v0009zl_p(p_id) and v_n_new = 0 then
    return 'provoked, but the set is empty: nothing to differ (FAIL by the switch)';
  end if;
  execute format('select (select string_agg(a::text, ''|'' order by a.o) from (select row_number() over () as o, t from (%s) t) a) is not distinct from
                         (select string_agg(b::text, ''|'' order by b.o) from (select row_number() over () as o, t from (%s) t) b)', p_new, v_old) into v_same;
  execute format('select count(*) from ((%s) except all (%s)) a', p_new, v_old) into v_only_new;
  execute format('select count(*) from ((%s) except all (%s)) a', v_old, p_new) into v_only_old;
  if v_only_new = 0 and v_only_old = 0 and v_same then
    return null;
  end if;
  return format('new %s rows, previous %s; only in new %s, only in previous %s; same order %s', v_n_new, v_n_old, v_only_new, v_only_old, v_same);
end
$$;
grant execute on function pg_temp.v0009zl_diff(text, text, text) to cma_app;

-- The earlier columns of each read, as the previous definitions return them
create or replace function pg_temp.v0009zl_cols(p_read text)
returns text
language sql immutable
as $$
  select case p_read
    when 'team_status_time' then 'user_id, display_name, organisation_key, organisation_name, business_date, timezone, status_key, '
      || 'status_name, sort_order, status_active, is_working, is_productive, is_paid, is_billable, seconds, stretches, is_capped'
    when 'team_now' then 'user_id, display_name, organisation_key, organisation_name, timezone, business_date, workday_id, day_status, '
      || 'started_at, ended_at, status_key, status_name, status_active, is_working, is_productive, is_paid, is_billable, '
      || 'status_since, closed_seconds, running_since, paid_closed_seconds, paid_running_since'
    when 'export_status_changes' then 'user_id, display_name, organisation_key, organisation_name, business_date, timezone, status_key, '
      || 'status_name, is_working, is_productive, is_paid, is_billable, from_at, to_at, is_open, is_capped, seconds, source'
    when 'work_statuses_all' then 'key, name, is_working, is_productive, is_paid, is_billable, is_default, sort_order, status, usage_count'
  end
$$;

-- ---------------------------------------------------------------------------------------------
-- The previous definitions, kept to compare with (R)
-- ---------------------------------------------------------------------------------------------
-- 15_team_status_time.sql
create or replace function pg_temp.old_team_status_time(p_from date, p_to date, p_user_id uuid default null)
returns table (
  user_id uuid, display_name text, organisation_key text, organisation_name text, business_date date, timezone text,
  status_key text, status_name text, sort_order integer, status_active boolean, is_working boolean, is_productive boolean,
  is_paid boolean, is_billable boolean, seconds bigint, stretches integer, is_capped boolean
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
           sum(i.seconds)::bigint, count(*)::integer, bool_or(i.is_capped)
    from cma.time_interval i
    join cma.workday w      on w.tenant_id = i.tenant_id and w.id = i.workday_id
    join cma.work_status ws on ws.tenant_id = i.tenant_id and ws.id = i.status_id
    join cma.app_user u     on u.tenant_id = i.tenant_id and u.id = i.user_id
    left join cma.organisation o on o.tenant_id = u.tenant_id and o.id = u.organisation_id
    where w.business_date between p_from and p_to
      and (p_user_id is null or i.user_id = p_user_id)
    group by i.user_id, u.display_name, o.key, o.name, w.business_date, w.timezone,
             ws.id, ws.key, ws.name, ws.sort_order, ws.status,
             ws.is_working, ws.is_productive, ws.is_paid, ws.is_billable
    order by w.business_date, u.display_name, i.user_id, ws.sort_order, ws.key;
end
$$;
grant execute on function pg_temp.old_team_status_time(date, date, uuid) to cma_app;

-- 200_live_paid_today.sql
create or replace function pg_temp.old_team_now()
returns table (
  user_id uuid, display_name text, organisation_key text, organisation_name text, timezone text, business_date date,
  workday_id uuid, day_status text, started_at timestamptz, ended_at timestamptz, status_key text, status_name text,
  status_active boolean, is_working boolean, is_productive boolean, is_paid boolean, is_billable boolean,
  status_since timestamptz, closed_seconds bigint, running_since timestamptz, paid_closed_seconds bigint, paid_running_since timestamptz
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
           c.paid_running_since
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
grant execute on function pg_temp.old_team_now() to cma_app;

-- 13_tenant_settings.sql
create or replace function pg_temp.old_export_status_changes(p_from date, p_to date, p_user_id uuid default null)
returns table (
  user_id uuid, display_name text, organisation_key text, organisation_name text, business_date date, timezone text,
  status_key text, status_name text, is_working boolean, is_productive boolean, is_paid boolean, is_billable boolean,
  from_at timestamptz, to_at timestamptz, is_open boolean, is_capped boolean, seconds bigint, source text
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
grant execute on function pg_temp.old_export_status_changes(date, date, uuid) to cma_app;

-- 26_configuration.sql
create or replace function pg_temp.old_work_statuses_all()
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
grant execute on function pg_temp.old_work_statuses_all() to cma_app;

-- ---------------------------------------------------------------------------------------------
-- S. The addition, the column and the functions
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_bad  text := '';
  v_fn   text;
  v_read text;
  v_cols text;
  f      regprocedure;
begin
  -- S1
  perform pg_temp.v0009zl_row(1, 'S1', 'the addition 0009zl recorded once, after 0009zk',
    format('0009zk %s; 0009zl %s, after 0009zk %s, work area %s',
           (select count(*) from cma.schema_migration where version = '0009zk'),
           (select count(*) from cma.schema_migration where version = '0009zl'),
           coalesce((select l.applied_at > k.applied_at from cma.schema_migration l, cma.schema_migration k
                     where l.version = '0009zl' and k.version = '0009zk'), false),
           coalesce((select m.description like 'Work area on statuses%' from cma.schema_migration m where m.version = '0009zl'), false)),
    '0009zk 1; 0009zl 1, after 0009zk t, work area t');

  -- S2
  perform pg_temp.v0009zl_row(2, 'S2', 'work_status.work_area text and nullable, its two checks; cma_read.work_status ends with it, readable by the readers',
    format('column %s; area check %s; flags check %s; view last %s; readers %s',
      coalesce((select c.data_type || ' ' || c.is_nullable from information_schema.columns c
                where c.table_schema = 'cma' and c.table_name = 'work_status' and c.column_name = 'work_area'), 'missing'),
      coalesce((select pg_get_constraintdef(k.oid) ~ 'sales' and pg_get_constraintdef(k.oid) ~ 'operations' from pg_constraint k
                where k.conrelid = 'cma.work_status'::regclass and k.conname = 'work_status_work_area_ok'), false),
      coalesce((select pg_get_constraintdef(k.oid) ~ 'work_area IS NULL' and pg_get_constraintdef(k.oid) ~ 'is_working' and pg_get_constraintdef(k.oid) ~ 'is_productive'
                from pg_constraint k where k.conrelid = 'cma.work_status'::regclass and k.conname = 'work_status_work_area_flags'), false),
      coalesce((select c.column_name from information_schema.columns c where c.table_schema = 'cma_read' and c.table_name = 'work_status'
                order by c.ordinal_position desc limit 1), 'missing'),
      has_table_privilege('cma_readonly', 'cma_read.work_status', 'select')),
    'column text YES; area check t; flags check t; view last work_area; readers t');

  -- S3
  foreach v_read in array array['team_status_time', 'team_now', 'export_status_changes', 'work_statuses_all'] loop
    v_fn := case v_read when 'team_status_time' then 'cma.team_status_time(date,date,uuid)'
                        when 'team_now' then 'cma.team_now()'
                        when 'export_status_changes' then 'cma.export_status_changes(date,date,uuid)'
                        else 'cma.work_statuses_all()' end;
    f := to_regprocedure(v_fn);
    if f is null then
      v_bad := v_bad || v_fn || ' missing; ';
      continue;
    end if;
    select string_agg(a.attname, ', ' order by a.n) into v_cols
    from pg_proc p
    join lateral unnest(p.proargnames, p.proargmodes) with ordinality as a(attname, attmode, n) on true
    where p.oid = f and a.attmode = 't';
    if v_cols is distinct from pg_temp.v0009zl_cols(v_read) || ', work_area' then
      v_bad := v_bad || v_read || ' columns [' || coalesce(v_cols, '') || ']; ';
    end if;
    if (select p.provolatile from pg_proc p where p.oid = f) <> 's' then v_bad := v_bad || v_read || ' not stable; '; end if;
  end loop;
  if not coalesce((select 'jit=off' = any (p.proconfig) from pg_proc p where p.oid = to_regprocedure('cma.team_now()')), false) then
    v_bad := v_bad || 'team_now jit not off; ';
  end if;
  if to_regprocedure('cma.upsert_work_status(text,text,boolean,boolean,boolean,boolean,integer)') is not null then
    v_bad := v_bad || 'the 7-argument upsert remains; ';
  end if;
  f := to_regprocedure('cma.upsert_work_status(text,text,boolean,boolean,boolean,boolean,integer,text)');
  if f is null then
    v_bad := v_bad || 'the 8-argument upsert missing; ';
  elsif (select p.pronargdefaults <> 2 or p.proargnames[8] <> 'p_work_area' from pg_proc p where p.oid = f) then
    v_bad := v_bad || 'the upsert''s p_work_area is not last with its default; ';
  end if;
  foreach v_fn in array array['cma.team_status_time(date,date,uuid)', 'cma.team_now()', 'cma.export_status_changes(date,date,uuid)',
                              'cma.work_statuses_all()', 'cma.upsert_work_status(text,text,boolean,boolean,boolean,boolean,integer,text)'] loop
    f := to_regprocedure(v_fn);
    continue when f is null;
    if pg_get_userbyid((select p.proowner from pg_proc p where p.oid = f)) <> 'cma_owner' then v_bad := v_bad || v_fn || ' owner; '; end if;
    if not has_function_privilege('cma_app', f, 'execute') then v_bad := v_bad || v_fn || ' not the application''s; '; end if;
    if has_function_privilege('cma_readonly', f, 'execute') then v_bad := v_bad || v_fn || ' the readers''; '; end if;
    if exists (select 1 from pg_proc p cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
               where p.oid = f and a.grantee = 0) then v_bad := v_bad || v_fn || ' public''s; '; end if;
    if (select p.prosecdef from pg_proc p where p.oid = f) then v_bad := v_bad || v_fn || ' security definer; '; end if;
  end loop;
  perform pg_temp.v0009zl_row(3, 'S3', 'the five functions: work_area last, the upsert''s new signature, owner, the application''s, the caller''s rights, stable, team_now jit off',
    coalesce(nullif(v_bad, ''), 'ok'), 'ok');
end
$$;

-- ---------------------------------------------------------------------------------------------
-- B. A throwaway tenant (see the header), always rolled back
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_h      integer := extract(hour from now() at time zone 'UTC')::integer;
  v_k      integer;
  v_z      text;
  v_d      date;
  v_t      uuid;
  v_admin uuid; v_mgr uuid; v_sup uuid; v_a1 uuid; v_a2 uuid; v_a3 uuid;
  v_conf   uuid;                  -- holds tenant.configure
  v_perf   uuid;                  -- holds performance.team
  v_live   uuid;                  -- holds monitoring.live
  v_team   uuid;                  -- holds workday.team (Team hours)
  v_exp    uuid;                  -- holds workday.export
  v_work   cma.work_status;       -- the default: working, productive, paid
  v_other  cma.work_status;       -- working, not productive
  v_pause  cma.work_status;       -- not working, paid
  v_free   cma.work_status;
  v_id_ops uuid;
  v_b0     text;
  v_b1     text := '';
  v_b2     text := '';
  v_b3     text := '';
  v_b4     text := '';
  v_b5     text := '';
  v_b6     text;
  v_tst0 text; v_esc0 text; v_hrs0 text; v_now0 text;
  v_tst1 text; v_esc1 text; v_hrs1 text; v_now1 text;
  v_err    text;
  v_i      integer;
  w        cma.workday;
begin
  v_k := greatest(-12, least(14, 9 - v_h));
  v_z := case when v_k = 0 then 'Etc/GMT' when v_k > 0 then 'Etc/GMT-' || v_k else 'Etc/GMT+' || (-v_k) end;
  v_d := cma.business_date(now(), v_z);
  begin
    v_t := cma.create_tenant('verify-0009zl', 'Verify 0009zl', 'UTC');
    insert into cma.app_user (tenant_id, email, display_name, timezone) values (v_t, 'admin@example.invalid', 'admin', v_z) returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name, timezone) values (v_t, 'mgr@example.invalid', 'mgr', v_z) returning id into v_mgr;
    insert into cma.app_user (tenant_id, email, display_name, timezone) values (v_t, 'sup@example.invalid', 'sup', v_z) returning id into v_sup;
    insert into cma.app_user (tenant_id, email, display_name, timezone) values (v_t, 'a1@example.invalid', 'a1', v_z) returning id into v_a1;
    insert into cma.app_user (tenant_id, email, display_name, timezone) values (v_t, 'a2@example.invalid', 'a2', v_z) returning id into v_a2;
    insert into cma.app_user (tenant_id, email, display_name, timezone) values (v_t, 'a3@example.invalid', 'a3', v_z) returning id into v_a3;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t, x.uid, ar.id
    from (values (v_admin, 'admin'), (v_mgr, 'manager'), (v_sup, 'supervisor'), (v_a1, 'agent'), (v_a2, 'agent'), (v_a3, 'agent')) as x(uid, role_key)
    join cma.app_role ar on ar.tenant_id = v_t and ar.key = x.role_key;
    -- The acting people by permission, never by role name: the first of admin, manager, supervisor holding it (read in
    -- the tenant, as cma.has_permission reads it)
    perform set_config('app.tenant_id', v_t::text, true);
    select x.uid into v_conf from unnest(array[v_admin, v_mgr, v_sup]) with ordinality x(uid, n) where cma.has_permission(x.uid, 'tenant.configure') order by x.n limit 1;
    select x.uid into v_perf from unnest(array[v_mgr, v_sup, v_admin]) with ordinality x(uid, n) where cma.has_permission(x.uid, 'performance.team') order by x.n limit 1;
    select x.uid into v_live from unnest(array[v_sup, v_mgr, v_admin]) with ordinality x(uid, n) where cma.has_permission(x.uid, 'monitoring.live') order by x.n limit 1;
    select x.uid into v_team from unnest(array[v_mgr, v_sup, v_admin]) with ordinality x(uid, n) where cma.has_permission(x.uid, 'workday.team') order by x.n limit 1;
    select x.uid into v_exp  from unnest(array[v_mgr, v_sup, v_admin]) with ordinality x(uid, n) where cma.has_permission(x.uid, 'workday.export') order by x.n limit 1;
    select * into v_work  from cma.work_status where tenant_id = v_t and status = 'active' and is_default and is_working and is_productive and is_paid;
    select * into v_other from cma.work_status where tenant_id = v_t and status = 'active' and is_working and not is_productive order by sort_order, key collate "C" limit 1;
    select * into v_pause from cma.work_status where tenant_id = v_t and status = 'active' and not is_working and is_paid order by sort_order, key collate "C" limit 1;
    v_b0 := format('statuses: default %s, other %s, pause %s; people: configure %s, performance %s, live %s, team %s, export %s',
                   v_work.id is not null, v_other.id is not null, v_pause.id is not null, v_conf is not null, v_perf is not null,
                   v_live is not null, v_team is not null, v_exp is not null);
    if v_work.id is null or v_other.id is null or v_pause.id is null or v_conf is null or v_perf is null or v_live is null
       or v_team is null or v_exp is null then
      raise exception 'the throwaway tenant lacks a status or a person: %', v_b0;
    end if;

    -- From here on as the application
    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('role', 'cma_app', true);

    -- The admin adds the second working, productive status (7 arguments: no work area) and one without time
    perform set_config('app.user_id', v_conf::text, true);
    perform cma.upsert_work_status('verify_ops', 'Verify ops', true, true, true, true, 15);
    perform cma.upsert_work_status('verify_free', 'Verify free', true, true, true, true, 16, 'operations');
    select id into v_id_ops from cma.work_status where tenant_id = v_t and key = 'verify_ops';

    -- The days, each person clocking their own at the local times of the header
    perform set_config('app.user_id', v_a1::text, true);
    w := cma.open_workday((v_d + time '05:00') at time zone v_z);
    perform cma.set_status(w.id, v_other.key, (v_d + time '06:00') at time zone v_z);
    perform cma.set_status(w.id, v_work.key, (v_d + time '06:30') at time zone v_z);
    perform cma.set_status(w.id, v_pause.key, (v_d + time '07:00') at time zone v_z);
    perform set_config('app.user_id', v_a2::text, true);
    w := cma.open_workday((v_d + time '05:00') at time zone v_z);
    perform cma.set_status(w.id, 'verify_ops', (v_d + time '06:00') at time zone v_z);
    w := cma.end_workday(w.id, (v_d + time '07:00') at time zone v_z);
    perform set_config('app.user_id', v_a3::text, true);
    w := cma.open_workday((v_d + time '05:00') at time zone v_z);

    -- B6, before: the figures without work_area
    perform set_config('app.user_id', v_perf::text, true);
    execute format('select string_agg(t::text, ''|'' order by t.business_date, t.display_name collate "C", t.user_id, t.sort_order, t.status_key collate "C")
                    from (select %s from cma.team_status_time($1, $1)) t', pg_temp.v0009zl_cols('team_status_time')) into v_tst0 using v_d;
    perform set_config('app.user_id', v_exp::text, true);
    execute format('select string_agg(t::text, ''|'' order by t.business_date, t.display_name collate "C", t.user_id, t.from_at)
                    from (select %s from cma.export_status_changes($1, $1)) t', pg_temp.v0009zl_cols('export_status_changes')) into v_esc0 using v_d;
    perform set_config('app.user_id', v_team::text, true);
    select string_agg(h::text, '|' order by h.user_id, h.business_date) into v_hrs0 from cma.team_hours(v_d, v_d) h;
    perform set_config('app.user_id', v_live::text, true);
    execute format('select string_agg(t::text, ''|'' order by t.display_name collate "C", t.user_id) from (select %s from cma.team_now()) t',
                   pg_temp.v0009zl_cols('team_now')) into v_now0;

    -- B1: a work area only on a working, productive status
    perform set_config('app.user_id', v_conf::text, true);
    begin
      perform cma.upsert_work_status(v_other.key, v_other.name, v_other.is_working, v_other.is_productive, v_other.is_paid, v_other.is_billable, v_other.sort_order, 'sales');
      v_b1 := v_b1 || 'not productive accepted; ';
    exception when others then v_b1 := v_b1 || 'not productive ' || sqlstate || '; ';
    end;
    begin
      perform cma.upsert_work_status('verify_free', 'Verify free', true, false, true, true, 16, 'operations');
      v_b1 := v_b1 || 'flag change accepted; ';
    exception when others then v_b1 := v_b1 || 'flag change ' || sqlstate || '; ';
    end;
    -- the table's own check, as the owner (a direct write, past the function)
    begin
      perform set_config('role', 'cma_owner', true);
      update cma.work_status set work_area = 'sales' where tenant_id = v_t and id = v_pause.id;
      v_b1 := v_b1 || 'table accepted';
    exception when others then v_b1 := v_b1 || 'table ' || sqlstate;
    end;
    perform set_config('role', 'cma_app', true);

    -- B2: an unknown value
    begin
      perform cma.upsert_work_status(v_work.key, v_work.name, true, true, v_work.is_paid, v_work.is_billable, v_work.sort_order, 'support');
      v_b2 := v_b2 || 'support accepted; ';
    exception when others then v_b2 := v_b2 || 'support ' || sqlstate || '; ';
    end;
    begin
      perform cma.upsert_work_status(v_work.key, v_work.name, true, true, v_work.is_paid, v_work.is_billable, v_work.sort_order, 'Sales');
      v_b2 := v_b2 || 'Sales accepted; ';
    exception when others then v_b2 := v_b2 || 'Sales ' || sqlstate || '; ';
    end;
    begin
      perform set_config('role', 'cma_owner', true);
      update cma.work_status set work_area = 'marketing' where tenant_id = v_t and id = v_work.id;
      v_b2 := v_b2 || 'table accepted';
    exception when others then v_b2 := v_b2 || 'table ' || sqlstate;
    end;
    perform set_config('role', 'cma_app', true);

    -- B3: without tenant.configure
    foreach v_i in array array[1, 2] loop
      perform set_config('app.user_id', (case v_i when 1 then v_a1 else v_mgr end)::text, true);
      continue when v_i = 2 and cma.has_permission(v_mgr, 'tenant.configure');
      begin
        perform cma.upsert_work_status(v_work.key, v_work.name, true, true, v_work.is_paid, v_work.is_billable, v_work.sort_order, 'sales');
        v_b3 := v_b3 || case v_i when 1 then 'agent' else 'manager' end || ' upsert accepted; ';
      exception when others then v_b3 := v_b3 || case v_i when 1 then 'agent' else 'manager' end || ' upsert ' || sqlstate || '; ';
      end;
      begin
        perform cma.work_statuses_all();
        v_b3 := v_b3 || case v_i when 1 then 'agent' else 'manager' end || ' list accepted; ';
      exception when others then v_b3 := v_b3 || case v_i when 1 then 'agent' else 'manager' end || ' list ' || sqlstate || '; ';
      end;
    end loop;

    -- B4: set the work areas as the admin; the default has time behind it
    perform set_config('app.user_id', v_conf::text, true);
    begin
      perform cma.upsert_work_status(v_work.key, v_work.name, true, true, v_work.is_paid, v_work.is_billable, v_work.sort_order, 'sales');
      perform cma.upsert_work_status('verify_ops', 'Verify ops', true, true, true, true, 15, 'operations');
      v_b4 := v_b4 || 'set with time behind it ok; ';
    exception when others then v_b4 := v_b4 || 'set with time behind it ' || sqlstate || '; ';
    end;
    begin
      perform cma.upsert_work_status(v_work.key, v_work.name, true, true, not v_work.is_paid, v_work.is_billable, v_work.sort_order, 'sales');
      v_b4 := v_b4 || 'flags changed; ';
    exception when others then v_b4 := v_b4 || 'flags ' || sqlstate || '; ';
    end;
    perform cma.upsert_work_status('verify_free', 'Verify free', true, true, true, true, 16);
    select * into v_free from cma.work_status where tenant_id = v_t and key = 'verify_free';
    v_b4 := v_b4 || 'without p_work_area ' || coalesce(v_free.work_area, 'none') || '; ';

    -- B6, after: the same reads
    perform set_config('app.user_id', v_perf::text, true);
    execute format('select string_agg(t::text, ''|'' order by t.business_date, t.display_name collate "C", t.user_id, t.sort_order, t.status_key collate "C")
                    from (select %s from cma.team_status_time($1, $1)) t', pg_temp.v0009zl_cols('team_status_time')) into v_tst1 using v_d;
    -- B5: team_status_time answers the stored work area, per status (labels, not keys)
    select 'status time ' || string_agg(distinct (x.label || '=' || coalesce(x.work_area, '-')) collate "C", ', ' order by (x.label || '=' || coalesce(x.work_area, '-')) collate "C")
    into v_b5
    from (select case t.status_key when v_work.key then 'default' when 'verify_ops' then 'ops' when v_other.key then 'other' when v_pause.key then 'pause' else t.status_key end as label,
                 t.work_area
          from cma.team_status_time(v_d, v_d) t) x;
    perform set_config('app.user_id', v_exp::text, true);
    execute format('select string_agg(t::text, ''|'' order by t.business_date, t.display_name collate "C", t.user_id, t.from_at)
                    from (select %s from cma.export_status_changes($1, $1)) t', pg_temp.v0009zl_cols('export_status_changes')) into v_esc1 using v_d;
    select v_b5 || '; export ' || string_agg(distinct (x.label || '=' || coalesce(x.work_area, '-')) collate "C", ', ' order by (x.label || '=' || coalesce(x.work_area, '-')) collate "C")
    into v_b5
    from (select case t.status_key when v_work.key then 'default' when 'verify_ops' then 'ops' when v_other.key then 'other' when v_pause.key then 'pause' else t.status_key end as label,
                 t.work_area
          from cma.export_status_changes(v_d, v_d) t) x;
    perform set_config('app.user_id', v_team::text, true);
    select string_agg(h::text, '|' order by h.user_id, h.business_date) into v_hrs1 from cma.team_hours(v_d, v_d) h;
    perform set_config('app.user_id', v_live::text, true);
    execute format('select string_agg(t::text, ''|'' order by t.display_name collate "C", t.user_id) from (select %s from cma.team_now()) t',
                   pg_temp.v0009zl_cols('team_now')) into v_now1;
    select v_b5 || '; team now ' || string_agg(n.display_name || '=' || coalesce(n.work_area, '-'), ', ' order by n.display_name collate "C")
    into v_b5
    from cma.team_now() n where n.user_id in (v_a1, v_a3);
    perform set_config('app.user_id', v_conf::text, true);
    select v_b5 || '; configuration ' || string_agg(x.label || '=' || coalesce(x.work_area, '-'), ', ' order by x.label collate "C")
    into v_b5
    from (select case s.key when v_work.key then 'default' when 'verify_ops' then 'ops' when 'verify_free' then 'free' when v_other.key then 'other' when v_pause.key then 'pause' end as label,
                 s.work_area
          from cma.work_statuses_all() s) x
    where x.label is not null;

    -- As the owner: the audit trail and the readers' view
    perform set_config('role', 'cma_owner', true);
    v_b4 := v_b4 || 'audited ' || (select count(*) from cma.audit_log a
                                    where a.tenant_id = v_t and a.table_name = 'work_status' and a.action = 'update' and a.row_id = v_work.id::text
                                      and a.old_row ->> 'work_area' is null and a.new_row ->> 'work_area' = 'sales' and a.actor_user_id = v_conf);
    select v_b5 || '; readers'' view ' || string_agg(x.label || '=' || coalesce(x.work_area, '-'), ', ' order by x.label collate "C")
    into v_b5
    from (select case s.key when v_work.key then 'default' when 'verify_ops' then 'ops' when v_other.key then 'other' when v_pause.key then 'pause' end as label,
                 s.work_area
          from cma_read.work_status s where s.tenant_id = v_t) x
    where x.label is not null;

    v_b6 := format('status time %s; export %s; team hours %s; team now %s',
                   case when v_tst0 is not null and v_tst0 = v_tst1 then 'equal' else 'differs' end,
                   case when v_esc0 is not null and v_esc0 = v_esc1 then 'equal' else 'differs' end,
                   case when v_hrs0 is not null and v_hrs0 = v_hrs1 then 'equal' else 'differs' end,
                   case when v_now0 is not null and v_now0 = v_now1 then 'equal' else 'differs' end);

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then v_err := sqlstate || ': ' || left(sqlerrm, 300);
      perform set_config('role', 'cma_owner', true);
      insert into pg_temp.verify_0009zl values (10, 'B the throwaway tenant''s checks ran to their end', 'FAIL', coalesce(v_b0, '') || ' | ' || v_err);
  end;
  perform set_config('role', 'cma_owner', true);
  perform set_config('app.tenant_id', '', true);
  perform set_config('app.user_id', '', true);

  perform pg_temp.v0009zl_row(11, 'B1', 'a work area on a status that is not working and productive is refused (upsert, flag change, table)',
    v_b1, 'not productive CMA04; flag change CMA04; table 23514');
  perform pg_temp.v0009zl_row(12, 'B2', 'an unknown work area is refused (upsert, the label, table)',
    v_b2, 'support CMA04; Sales CMA04; table 23514');
  perform pg_temp.v0009zl_row(13, 'B3', 'the upsert and the list without tenant.configure are refused',
    v_b3, 'agent upsert CMA06; agent list CMA06; manager upsert CMA06; manager list CMA06; ');
  perform pg_temp.v0009zl_row(14, 'B4', 'not frozen by time, audited as the admin''s, flags still frozen, 7 arguments set none',
    v_b4, 'set with time behind it ok; flags CMA03; without p_work_area none; audited 1');
  perform pg_temp.v0009zl_row(15, 'B5', 'the reads answer the stored work area',
    v_b5, 'status time default=sales, ops=operations, other=-, pause=-; export default=sales, ops=operations, other=-, pause=-; '
       || 'team now a1=-, a3=sales; configuration default=sales, free=-, ops=operations, other=-, pause=-; '
       || 'readers'' view default=sales, ops=operations, other=-, pause=-');
  perform pg_temp.v0009zl_row(16, 'B6', 'figures for the day are equal before and after the work areas are set',
    v_b6, 'status time equal; export equal; team hours equal; team now equal');
end
$$;

-- ---------------------------------------------------------------------------------------------
-- R. Per active tenant, as the application, always rolled back
-- ---------------------------------------------------------------------------------------------
do $$
declare
  t      record;
  c      record;
  v_who  uuid;
  v_r    text;
  v_err  text;
  v_any  boolean := false;
  v_from date := current_date - 30;
  v_to   date := current_date;
begin
  for t in select id, slug from cma.tenant where status = 'active' and slug not like 'verify-%' order by slug collate "C" loop
    v_any := true;
    perform set_config('app.tenant_id', t.id::text, true);
    for c in select * from (values
        (21, 'R1', 'team_status_time', 'performance.team',
         format('select %s from cma.team_status_time(%L::date, %L::date)', pg_temp.v0009zl_cols('team_status_time'), v_from, v_to),
         format('select * from pg_temp.old_team_status_time(%L::date, %L::date)', v_from, v_to), 'seventeen'),
        (22, 'R2', 'team_now', 'monitoring.live',
         format('select %s from cma.team_now()', pg_temp.v0009zl_cols('team_now')),
         'select * from pg_temp.old_team_now()', 'twenty-two'),
        (23, 'R3', 'export_status_changes', 'workday.export',
         format('select %s from cma.export_status_changes(%L::date, %L::date)', pg_temp.v0009zl_cols('export_status_changes'), v_from, v_to),
         format('select * from pg_temp.old_export_status_changes(%L::date, %L::date)', v_from, v_to), 'eighteen'),
        (24, 'R4', 'work_statuses_all', 'tenant.configure',
         format('select %s from cma.work_statuses_all()', pg_temp.v0009zl_cols('work_statuses_all')),
         'select * from pg_temp.old_work_statuses_all()', 'ten')
      ) as x(ord, id, fn, perm, new_sql, old_sql, n_cols) loop
      v_who := null; v_r := null; v_err := null;
      select u.id into v_who from cma.app_user u
      where u.tenant_id = t.id and u.status = 'active' and u.kind = 'person' and cma.has_permission(u.id, c.perm)
      order by u.created_at, u.id limit 1;
      if v_who is null then
        insert into pg_temp.verify_0009zl values (c.ord, c.id || ' ' || t.slug || ': ' || c.fn,
          case when pg_temp.v0009zl_p(c.id) then 'FAIL' else 'skip' end, 'no active person holds ' || c.perm || ': not compared');
        continue;
      end if;
      begin
        perform set_config('role', 'cma_app', true);
        perform set_config('app.user_id', v_who::text, true);
        v_r := pg_temp.v0009zl_diff(c.id, c.new_sql, c.old_sql);
        if v_r is null then
          execute format('select ''equal, '' || count(*) || '' rows'' from (%s) z', c.new_sql) into v_r;
        end if;
        raise exception using errcode = 'CMAOK', message = 'rollback';
      exception
        when sqlstate 'CMAOK' then null;
        when others then v_err := sqlstate || ': ' || left(sqlerrm, 300);
      end;
      perform set_config('role', 'cma_owner', true);
      perform set_config('app.user_id', '', true);
      insert into pg_temp.verify_0009zl values (c.ord, c.id || ' ' || t.slug || ': ' || c.fn || '''s ' || c.n_cols || ' earlier columns equal the previous definition, row for row, in order',
        case when v_err is null and v_r like 'equal, %' then 'PASS' else 'FAIL' end, coalesce(v_err, v_r));
    end loop;
  end loop;
  perform set_config('app.tenant_id', '', true);
  if not v_any then
    insert into pg_temp.verify_0009zl values (20, 'R per tenant',
      case when current_setting('verify.provoke') <> 'false' then 'FAIL' else 'skip' end, 'no active tenant');
  end if;
end
$$;

drop function if exists pg_temp.old_work_statuses_all();
drop function if exists pg_temp.old_export_status_changes(date, date, uuid);
drop function if exists pg_temp.old_team_now();
drop function if exists pg_temp.old_team_status_time(date, date, uuid);
drop function if exists pg_temp.v0009zl_cols(text);
drop function if exists pg_temp.v0009zl_diff(text, text, text);
drop function if exists pg_temp.v0009zl_row(integer, text, text, text, text);
drop function if exists pg_temp.v0009zl_p(text);

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0009zl
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke') <> 'false' then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0009zl where result = 'FAIL') then 'FAIL'
                  when not exists (select 1 from pg_temp.verify_0009zl where result = 'PASS') then 'FAIL'
                  else 'PASS' end,
             format('225_verify_work_area: %s PASS, %s FAIL, %s skip', (select count(*) from pg_temp.verify_0009zl where result = 'PASS'),
                    (select count(*) from pg_temp.verify_0009zl where result = 'FAIL'), (select count(*) from pg_temp.verify_0009zl where result = 'skip'))) x
order by ord, check_name collate "C";
drop table if exists pg_temp.verify_0009zl;
reset role;
