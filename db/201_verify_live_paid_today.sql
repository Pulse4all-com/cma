-- =============================================================================================
-- 201_verify_live_paid_today.sql: verifies addition 0009z, Paid today on the Live board (cma.team_now's
-- paid_closed_seconds and paid_running_since)
-- =============================================================================================
-- Universal: no seed is assumed, so it runs in dev and in prod. Two kinds of checks:
--   on a throwaway tenant (B): invented people (example.invalid) whose days are written through the clock's own
--     functions at fixed local times, the whole step rolled back;
--   on every active tenant (R): the new definition against 134's (kept below) and the paid inputs against Team hours, as
--     the application (cma_app, row-level security on), in a step that is always rolled back.
-- Run as your own IAM login, after 200. Output: tenant slugs, counts, check names and the throwaway people's invented
-- short names; no real person's name.
-- Edited by addition 0009zn (228_work_area.sql, 23 November 2026): S2 expects work_area after the paid columns where 0009zn
-- is recorded; nothing else changed.
-- Edited by addition 0009zo (230_hours_market.sql, 23 November 2026): S2 expects hours_market_code after work_area where
-- 0009zo is recorded; nothing else changed.
-- 20_verify_team_now.sql (A3) and 135_verify_hours_reads.sql (E6) are edited by 200 and run again after it, with
-- 199_verify_roster_planned.sql (B6 reads team_now).
--
-- The throwaway tenant's clock. Its people live in two zones chosen from the hour of the run, so every event below lies
-- in the past of today's business date whatever the hour: the morning zone, where it is between 09:00 and 12:00 now, and
-- the afternoon zone, where it is between 14:00 and 16:00 now (Etc/GMT zones, whole hours). The tenant's window ends at
-- 12:00 (workday.window_end), so a day left open in the afternoon zone is capped at 12:00 and the morning zone's days
-- still run; workday.clock_in_again is on. Statuses are picked by flag from the tenant's own seeded list: the default
-- (working and paid), a paid pause (not working, paid) and an unpaid pause (not working, not paid).
--   pb   morning: clock in 07:00, a paid pause from 08:00, still in it           (a paid break running)
--   ss   morning: clock in 05:00, an unpaid pause 06:00, log out 06:30, clock in again 07:30, still working
--                                                                                  (a split shift: the gap is not paid)
--   co   morning: clock in 05:00, a paid pause 06:00, back at 06:15, log out 07:00 (clocked out)
--   up   morning: clock in 07:00, an unpaid pause from 08:00, still in it          (paid stops while unpaid runs)
--   cap  afternoon: clock in 08:00, a paid pause from 10:00, never logged out      (capped at the window end, 12:00)
--   rm   morning: clock in 05:00, log out 06:00, the day removed by the supervisor (a removed day counts 0)
--   nc   morning: no day                                                          (not clocked in counts 0)
--   sup  morning: the supervisor, no day; reads the board and Team hours
--
-- Checks
--   S1  the addition 0009z is recorded once, after 0009y
--   S2  cma.team_now: its columns in order with paid_closed_seconds and paid_running_since last; cma_owner's, the
--       application's to execute (not public's, not the readers'), the caller's rights, stable, jit = off
--   B1  per person: day status, paid closed seconds, paid running since (local time), closed seconds, running since, as
--       the definition says (the brief's cases: a paid break, a split shift, clocked out, capped at the window end)
--   B2  at one instant, each person's paid seconds from the board's inputs (closed + the running stretch to now, stopped
--       at the window end, as lib/live.ts paidSeconds counts it) equal cma.team_hours' paid_seconds for the person's
--       today (0 without a day), and the sum of whole minutes per person equals Team hours' (the figure on the board)
--   B3  the first twenty columns equal 134's definition, row for row, in order
--   R1  per active tenant: the first twenty columns equal 134's definition, row for row, in order (as the tenant's
--       first person holding monitoring.live)
--   R2  per active tenant: B2 on the tenant's own people today (the board read as that person, Team hours as the
--       first person holding workday.team, in one transaction, so now() is one instant)
-- Provoke: verify.provoke below. 'true': every check reads FAIL and the verdict says PROVOKED, NOT A PASS. A check's id:
-- that check alone fails. B3 and R1 drop the old side's first row, so the comparison itself must find the difference
-- (a compare of no rows reads FAIL under the switch).
-- Collation: every ordering that feeds a compared text says collate "C".
-- Expected verdict: "PASS | 201_verify_live_paid_today: <n> PASS, 0 FAIL, <k> skip".
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

drop table if exists pg_temp.verify_0009z;
create temporary table verify_0009z (ord integer, check_name text, result text, detail text);
grant select, insert on pg_temp.verify_0009z to cma_app;
-- The board's paid inputs per person, read as the person holding monitoring.live, compared with Team hours read as
-- the person holding workday.team in the same transaction
drop table if exists pg_temp.v0009z_board;
create temporary table v0009z_board (user_id uuid, business_date date, name text, paid bigint);
grant select, insert, delete on pg_temp.v0009z_board to cma_app;

create or replace function pg_temp.v0009z_p(p_id text)
returns boolean
language sql stable
as $$
  select current_setting('verify.provoke') in ('true', p_id)
$$;

-- One check's row: PASS when what was found equals what is expected; provoked, the expectation carries a deliberate difference
create or replace function pg_temp.v0009z_row(p_ord integer, p_id text, p_name text, p_found text, p_expected text)
returns void
language plpgsql
as $$
declare
  v_exp text := case when pg_temp.v0009z_p(p_id) then coalesce(p_expected, '') || ' [provoked: a deliberate difference]' else p_expected end;
begin
  insert into pg_temp.verify_0009z values (p_ord, p_id || ' ' || p_name,
    case when p_found is not distinct from v_exp then 'PASS' else 'FAIL' end,
    case when p_found is not distinct from v_exp then left(coalesce(p_found, 'null'), 600)
         else left('found ' || coalesce(p_found, 'null') || ' | expected ' || coalesce(v_exp, 'null'), 2400) end);
end
$$;

-- Two reads compared row for row and in order (135's comparison); provoked for the check, the old side loses its first
-- row. Null when equal, otherwise what differs
create or replace function pg_temp.v0009z_diff(p_id text, p_new text, p_old text)
returns text
language plpgsql
as $$
declare
  v_old text := p_old;
  v_n_new bigint; v_n_old bigint; v_only_new bigint; v_only_old bigint; v_same boolean;
begin
  if pg_temp.v0009z_p(p_id) then
    v_old := format('select * from (%s) z offset 1', p_old);
  end if;
  execute format('select count(*) from (%s) a', p_new) into v_n_new;
  execute format('select count(*) from (%s) a', v_old) into v_n_old;
  if pg_temp.v0009z_p(p_id) and v_n_new = 0 then
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
grant execute on function pg_temp.v0009z_diff(text, text, text) to cma_app;

-- Seconds paid at this instant from the board's inputs: the closed paid stretches and the running one to now, stopped
-- at the workday window's end (lib/live.ts paidSeconds with the day's end)
create or replace function pg_temp.v0009z_paid(p_closed bigint, p_since timestamptz, p_date date, p_zone text)
returns bigint
language sql stable
as $$
  select p_closed + coalesce(greatest(0, floor(extract(epoch from (least(now(), cma.business_day_end(p_date, p_zone)) - p_since))))::bigint, 0)
$$;

-- ---------------------------------------------------------------------------------------------
-- 134's definition (134_hours_reads.sql, section 4), kept to compare with: the twenty columns before 0009z
-- ---------------------------------------------------------------------------------------------
create or replace function pg_temp.old_team_now()
returns table (
  user_id            uuid,
  display_name       text,
  organisation_key   text,
  organisation_name  text,
  timezone           text,
  business_date      date,
  workday_id         uuid,
  day_status         text,
  started_at         timestamptz,
  ended_at           timestamptz,
  status_key         text,
  status_name        text,
  status_active      boolean,
  is_working         boolean,
  is_productive      boolean,
  is_paid            boolean,
  is_billable        boolean,
  status_since       timestamptz,
  closed_seconds     bigint,
  running_since      timestamptz
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
           c.running_since
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
             max(i.from_at) filter (where i.is_open and not i.is_capped)                     as status_since
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

-- The twenty columns of 134, read from the new definition
create or replace function pg_temp.v0009z_cols()
returns text
language sql immutable
as $$
  select 'user_id, display_name, organisation_key, organisation_name, timezone, business_date, workday_id, day_status, '
      || 'started_at, ended_at, status_key, status_name, status_active, is_working, is_productive, is_paid, is_billable, '
      || 'status_since, closed_seconds, running_since'
$$;

-- ---------------------------------------------------------------------------------------------
-- S. The addition and the function
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f     regprocedure := to_regprocedure('cma.team_now()');
  v_bad text := '';
  v_cols text;
  v_want text;
begin
  -- S1
  perform pg_temp.v0009z_row(1, 'S1', 'the addition 0009z recorded once, after 0009y',
    format('0009y %s; 0009z %s, after 0009y %s, paid today %s',
           (select count(*) from cma.schema_migration where version = '0009y'),
           (select count(*) from cma.schema_migration where version = '0009z'),
           coalesce((select z.applied_at > y.applied_at from cma.schema_migration z, cma.schema_migration y
                     where z.version = '0009z' and y.version = '0009y'), false),
           coalesce((select m.description like 'Paid today on the Live board%' from cma.schema_migration m where m.version = '0009z'), false)),
    '0009y 1; 0009z 1, after 0009y t, paid today t');

  -- S2
  if f is null then
    v_bad := 'cma.team_now() missing';
  else
    select string_agg(a.attname, ', ' order by a.n) into v_cols
    from pg_proc p
    join lateral unnest(p.proargnames, p.proargmodes) with ordinality as a(attname, attmode, n) on true
    where p.oid = f and a.attmode = 't';
    -- Adjusted 23 November 2026 (addition 0009zn, 228_work_area.sql): work_area follows the paid columns, last
    v_want := pg_temp.v0009z_cols() || ', paid_closed_seconds, paid_running_since';
    if exists (select 1 from cma.schema_migration where version = '0009zn') then
      v_want := v_want || ', work_area';
    end if;
    -- Adjusted 23 November 2026 (addition 0009zo, 230_hours_market.sql): the day's hours market follows, last
    if exists (select 1 from cma.schema_migration where version = '0009zo') then
      v_want := v_want || ', hours_market_code';
    end if;
    if v_cols is distinct from v_want then
      v_bad := v_bad || 'columns [' || coalesce(v_cols, '') || ']; ';
    end if;
    if (select format_type(p.prorettype, null) from pg_proc p where p.oid = f) <> 'record' or not (select p.proretset from pg_proc p where p.oid = f) then
      v_bad := v_bad || 'not a set of records; ';
    end if;
    if pg_get_userbyid((select p.proowner from pg_proc p where p.oid = f)) <> 'cma_owner' then v_bad := v_bad || 'owner; '; end if;
    if not has_function_privilege('cma_app', f, 'execute') then v_bad := v_bad || 'not the application''s; '; end if;
    if has_function_privilege('cma_readonly', f, 'execute') then v_bad := v_bad || 'the readers''; '; end if;
    if exists (select 1 from pg_proc p cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
               where p.oid = f and a.grantee = 0) then v_bad := v_bad || 'public''s; '; end if;
    if (select p.prosecdef from pg_proc p where p.oid = f) then v_bad := v_bad || 'security definer; '; end if;
    if (select p.provolatile from pg_proc p where p.oid = f) <> 's' then v_bad := v_bad || 'not stable; '; end if;
    if not coalesce((select 'jit=off' = any (p.proconfig) from pg_proc p where p.oid = f), false) then v_bad := v_bad || 'jit not off; '; end if;
    if (select p.prosrc from pg_proc p where p.oid = f) !~ 'cma\.assert_permission\(''monitoring\.live''\)' then
      v_bad := v_bad || 'monitoring.live not checked; ';
    end if;
  end if;
  perform pg_temp.v0009z_row(2, 'S2', 'cma.team_now: the paid columns last; the owner''s, the application''s, the caller''s rights, stable, jit off, monitoring.live',
    coalesce(nullif(v_bad, ''), 'ok'), 'ok');
end
$$;

-- ---------------------------------------------------------------------------------------------
-- B. A throwaway tenant (see the header), always rolled back
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_h      integer := extract(hour from now() at time zone 'UTC')::integer;
  v_k1     integer;
  v_k2     integer;
  v_z1     text;                  -- the morning zone
  v_z2     text;                  -- the afternoon zone
  v_d1     date;
  v_d2     date;
  v_t      uuid;
  v_pb uuid; v_ss uuid; v_co uuid; v_up uuid; v_cap uuid; v_rm uuid; v_nc uuid; v_sup uuid;
  v_work   text;
  v_ppause text;
  v_upause text;
  v_b0     text;
  v_b1     text;
  v_b2     text;
  v_b3     text;
  v_err    text;
  w        cma.workday;
begin
  v_k1 := greatest(-12, least(14, 9 - v_h));
  v_k2 := greatest(-12, least(14, 15 - v_h));
  v_z1 := case when v_k1 = 0 then 'Etc/GMT' when v_k1 > 0 then 'Etc/GMT-' || v_k1 else 'Etc/GMT+' || (-v_k1) end;
  v_z2 := case when v_k2 = 0 then 'Etc/GMT' when v_k2 > 0 then 'Etc/GMT-' || v_k2 else 'Etc/GMT+' || (-v_k2) end;
  v_d1 := cma.business_date(now(), v_z1);
  v_d2 := cma.business_date(now(), v_z2);
  begin
    v_t := cma.create_tenant('verify-0009z', 'Verify 0009z', 'UTC');
    insert into cma.tenant_setting (tenant_id, key, value) values (v_t, 'workday.window_end', '12:00');
    insert into cma.tenant_setting (tenant_id, key, value) values (v_t, 'workday.clock_in_again', 'true');
    insert into cma.app_user (tenant_id, email, display_name, timezone) values (v_t, 'pb@example.invalid', 'pb', v_z1) returning id into v_pb;
    insert into cma.app_user (tenant_id, email, display_name, timezone) values (v_t, 'ss@example.invalid', 'ss', v_z1) returning id into v_ss;
    insert into cma.app_user (tenant_id, email, display_name, timezone) values (v_t, 'co@example.invalid', 'co', v_z1) returning id into v_co;
    insert into cma.app_user (tenant_id, email, display_name, timezone) values (v_t, 'up@example.invalid', 'up', v_z1) returning id into v_up;
    insert into cma.app_user (tenant_id, email, display_name, timezone) values (v_t, 'cap@example.invalid', 'cap', v_z2) returning id into v_cap;
    insert into cma.app_user (tenant_id, email, display_name, timezone) values (v_t, 'rm@example.invalid', 'rm', v_z1) returning id into v_rm;
    insert into cma.app_user (tenant_id, email, display_name, timezone) values (v_t, 'nc@example.invalid', 'nc', v_z1) returning id into v_nc;
    insert into cma.app_user (tenant_id, email, display_name, timezone) values (v_t, 'sup@example.invalid', 'sup', v_z1) returning id into v_sup;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t, x.uid, ar.id
    from (values (v_pb, 'agent'), (v_ss, 'agent'), (v_co, 'agent'), (v_up, 'agent'), (v_cap, 'agent'), (v_rm, 'agent'),
                 (v_nc, 'agent'), (v_sup, 'supervisor')) as x(uid, role_key)
    join cma.app_role ar on ar.tenant_id = v_t and ar.key = x.role_key;
    select key into v_work   from cma.work_status where tenant_id = v_t and status = 'active' and is_default and is_working and is_paid;
    select key into v_ppause from cma.work_status where tenant_id = v_t and status = 'active' and not is_working and is_paid order by sort_order, key limit 1;
    select key into v_upause from cma.work_status where tenant_id = v_t and status = 'active' and not is_working and not is_paid order by sort_order, key limit 1;
    v_b0 := format('default working and paid %s, paid pause %s, unpaid pause %s', v_work is not null, v_ppause is not null, v_upause is not null);
    if v_work is null or v_ppause is null or v_upause is null then
      raise exception 'the seeded statuses lack one of the three kinds: %', v_b0;
    end if;

    -- From here on as the application, each person clocking their own day at the local times of the header
    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('role', 'cma_app', true);

    perform set_config('app.user_id', v_pb::text, true);
    w := cma.open_workday((v_d1 + time '07:00') at time zone v_z1);
    perform cma.set_status(w.id, v_ppause, (v_d1 + time '08:00') at time zone v_z1);

    perform set_config('app.user_id', v_ss::text, true);
    w := cma.open_workday((v_d1 + time '05:00') at time zone v_z1);
    perform cma.set_status(w.id, v_upause, (v_d1 + time '06:00') at time zone v_z1);
    w := cma.end_workday(w.id, (v_d1 + time '06:30') at time zone v_z1);
    w := cma.open_workday((v_d1 + time '07:30') at time zone v_z1);

    perform set_config('app.user_id', v_co::text, true);
    w := cma.open_workday((v_d1 + time '05:00') at time zone v_z1);
    perform cma.set_status(w.id, v_ppause, (v_d1 + time '06:00') at time zone v_z1);
    perform cma.set_status(w.id, v_work, (v_d1 + time '06:15') at time zone v_z1);
    w := cma.end_workday(w.id, (v_d1 + time '07:00') at time zone v_z1);

    perform set_config('app.user_id', v_up::text, true);
    w := cma.open_workday((v_d1 + time '07:00') at time zone v_z1);
    perform cma.set_status(w.id, v_upause, (v_d1 + time '08:00') at time zone v_z1);

    perform set_config('app.user_id', v_cap::text, true);
    w := cma.open_workday((v_d2 + time '08:00') at time zone v_z2);
    perform cma.set_status(w.id, v_ppause, (v_d2 + time '10:00') at time zone v_z2);

    perform set_config('app.user_id', v_rm::text, true);
    w := cma.open_workday((v_d1 + time '05:00') at time zone v_z1);
    w := cma.end_workday(w.id, (v_d1 + time '06:00') at time zone v_z1);
    perform set_config('app.user_id', v_sup::text, true);
    w := cma.remove_workday(w.id, 'verify 0009z: a removed day');

    -- B1: the board's inputs per person (local times in the person's zone)
    select string_agg(n.display_name || '=' || coalesce(n.day_status, '-')
                      || '|' || n.paid_closed_seconds
                      || '|' || coalesce(to_char(n.paid_running_since at time zone n.timezone, 'HH24:MI'), '-')
                      || '|' || n.closed_seconds
                      || '|' || coalesce(to_char(n.running_since at time zone n.timezone, 'HH24:MI'), '-'),
                      ', ' order by n.display_name collate "C")
    into v_b1 from cma.team_now() n;

    -- B2: the board's paid seconds at this instant against Team hours, per person and as whole minutes summed
    insert into pg_temp.v0009z_board
    select n.user_id, n.business_date, n.display_name,
           case when n.workday_id is null then 0
                else pg_temp.v0009z_paid(n.paid_closed_seconds, n.paid_running_since, n.business_date, n.timezone) end
    from cma.team_now() n;
    select string_agg(b.name || case when b.paid = coalesce(h.paid_seconds, 0) then ' equal'
                                     else ' board ' || b.paid || ' team hours ' || coalesce(h.paid_seconds, 0) end,
                      ', ' order by b.name collate "C")
           || '; minutes ' || case when sum(b.paid / 60) = sum(coalesce(h.paid_seconds, 0) / 60) then 'equal'
                                   else sum(b.paid / 60) || ' against team hours ' || sum(coalesce(h.paid_seconds, 0) / 60) end
    into v_b2
    from pg_temp.v0009z_board b
    left join cma.team_hours(least(v_d1, v_d2), greatest(v_d1, v_d2)) h on h.user_id = b.user_id and h.business_date = b.business_date;

    -- B3: the first twenty columns against 134's definition
    v_b3 := coalesce(pg_temp.v0009z_diff('B3', format('select %s from cma.team_now()', pg_temp.v0009z_cols()), 'select * from pg_temp.old_team_now()'),
                     'equal, ' || (select count(*) from cma.team_now()) || ' people');

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then v_err := sqlstate || ': ' || left(sqlerrm, 300);
      perform set_config('role', 'cma_owner', true);
      insert into pg_temp.verify_0009z values (10, 'B the throwaway tenant''s checks ran to their end', 'FAIL', v_err);
  end;
  perform set_config('role', 'cma_owner', true);
  perform set_config('app.tenant_id', '', true);
  perform set_config('app.user_id', '', true);
  delete from pg_temp.v0009z_board;

  perform pg_temp.v0009z_row(11, 'B1', 'per person day status | paid closed | paid running since | closed | running since',
    v_b1,
    'cap=open|14400|-|7200|-, co=ended|7200|-|6300|-, nc=-|0|-|0|-, pb=open|3600|08:00|3600|-, rm=-|0|-|0|-, '
    || 'ss=open|3600|07:30|3600|07:30, sup=-|0|-|0|-, up=open|3600|-|3600|-');
  perform pg_temp.v0009z_row(12, 'B2', 'at one instant the board''s paid seconds equal Team hours'' per person, and the whole minutes summed',
    v_b2, 'cap equal, co equal, nc equal, pb equal, rm equal, ss equal, sup equal, up equal; minutes equal');
  insert into pg_temp.verify_0009z values (13, 'B3 the first twenty columns equal 134''s definition, row for row, in order',
    case when v_b3 like 'equal, %' then 'PASS' else 'FAIL' end, coalesce(v_b3, 'null'));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- R. Per active tenant, as the application, always rolled back
-- ---------------------------------------------------------------------------------------------
do $$
declare
  t      record;
  v_live uuid;
  v_team uuid;
  v_r1   text;
  v_r2   text;
  v_err  text;
  v_n    bigint;
  v_off  bigint;
  v_any  boolean := false;
begin
  for t in select id, slug from cma.tenant where status = 'active' and slug not like 'verify-%' order by slug collate "C" loop
    v_any := true;
    v_r1 := null; v_r2 := null; v_err := null;
    -- the acting people (131's choice: the oldest active person holding the read's permission)
    perform set_config('app.tenant_id', t.id::text, true);
    select u.id into v_live from cma.app_user u
    where u.tenant_id = t.id and u.status = 'active' and u.kind = 'person' and cma.has_permission(u.id, 'monitoring.live')
    order by u.created_at, u.id limit 1;
    select u.id into v_team from cma.app_user u
    where u.tenant_id = t.id and u.status = 'active' and u.kind = 'person' and cma.has_permission(u.id, 'workday.team')
    order by u.created_at, u.id limit 1;
    if v_live is null then
      insert into pg_temp.verify_0009z values (20, 'R1 ' || t.slug || ': team_now',
        case when pg_temp.v0009z_p('R1') then 'FAIL' else 'skip' end, 'no active person holds monitoring.live: not compared');
      insert into pg_temp.verify_0009z values (21, 'R2 ' || t.slug || ': the board''s paid against Team hours',
        case when pg_temp.v0009z_p('R2') then 'FAIL' else 'skip' end, 'no active person holds monitoring.live: not compared');
      continue;
    end if;
    begin
      perform set_config('role', 'cma_app', true);
      perform set_config('app.user_id', v_live::text, true);
      v_r1 := coalesce(pg_temp.v0009z_diff('R1', format('select %s from cma.team_now()', pg_temp.v0009z_cols()), 'select * from pg_temp.old_team_now()'),
                       'equal, ' || (select count(*) from cma.team_now()) || ' people');
      if v_team is not null then
        insert into pg_temp.v0009z_board
        select n.user_id, n.business_date, null,
               case when n.workday_id is null then 0
                    else pg_temp.v0009z_paid(n.paid_closed_seconds, n.paid_running_since, n.business_date, n.timezone) end
        from cma.team_now() n;
        perform set_config('app.user_id', v_team::text, true);
        if not exists (select 1 from pg_temp.v0009z_board) then
          v_r2 := 'nobody on the board';
        else
        select count(*), count(*) filter (where b.paid <> coalesce(h.paid_seconds, 0))
               + case when pg_temp.v0009z_p('R2') then 1 else 0 end
        into v_n, v_off
        from pg_temp.v0009z_board b
        left join cma.team_hours((select min(x.business_date) from pg_temp.v0009z_board x),
                                 (select max(x.business_date) from pg_temp.v0009z_board x)) h
               on h.user_id = b.user_id and h.business_date = b.business_date;
        v_r2 := format('people %s, paid differs for %s; minutes %s', v_n, v_off,
          (select case when sum(b.paid / 60) = sum(coalesce(h.paid_seconds, 0) / 60) then 'equal'
                       else sum(b.paid / 60) || ' against team hours ' || sum(coalesce(h.paid_seconds, 0) / 60) end
           from pg_temp.v0009z_board b
           left join cma.team_hours((select min(x.business_date) from pg_temp.v0009z_board x),
                                    (select max(x.business_date) from pg_temp.v0009z_board x)) h
                  on h.user_id = b.user_id and h.business_date = b.business_date));
        end if;
        delete from pg_temp.v0009z_board;
      end if;
      raise exception using errcode = 'CMAOK', message = 'rollback';
    exception
      when sqlstate 'CMAOK' then null;
      when others then v_err := sqlstate || ': ' || left(sqlerrm, 300);
    end;
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.user_id', '', true);
    if v_err is not null then
      insert into pg_temp.verify_0009z values (20, 'R ' || t.slug || ': the reads ran to their end', 'FAIL', v_err);
      continue;
    end if;
    insert into pg_temp.verify_0009z values (20, 'R1 ' || t.slug || ': the first twenty columns equal 134''s definition, row for row, in order',
      case when v_r1 like 'equal, %' then 'PASS' else 'FAIL' end, v_r1);
    if v_team is null or v_r2 = 'nobody on the board' then
      insert into pg_temp.verify_0009z values (21, 'R2 ' || t.slug || ': the board''s paid against Team hours',
        case when pg_temp.v0009z_p('R2') then 'FAIL' else 'skip' end,
        case when v_team is null then 'no active person holds workday.team: not compared' else 'nobody on the board: not compared' end);
    else
      insert into pg_temp.verify_0009z values (21, 'R2 ' || t.slug || ': at one instant the board''s paid seconds equal Team hours'' per person today, and the whole minutes summed',
        case when v_r2 like '%, paid differs for 0; minutes equal' then 'PASS' else 'FAIL' end, v_r2);
    end if;
  end loop;
  perform set_config('app.tenant_id', '', true);
  if not v_any then
    insert into pg_temp.verify_0009z values (20, 'R per tenant',
      case when current_setting('verify.provoke') <> 'false' then 'FAIL' else 'skip' end, 'no active tenant');
  end if;
end
$$;

drop function if exists pg_temp.v0009z_cols();
drop function if exists pg_temp.old_team_now();
drop function if exists pg_temp.v0009z_paid(bigint, timestamptz, date, text);
drop function if exists pg_temp.v0009z_diff(text, text, text);
drop function if exists pg_temp.v0009z_row(integer, text, text, text, text);
drop function if exists pg_temp.v0009z_p(text);
drop table if exists pg_temp.v0009z_board;

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0009z
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke') <> 'false' then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0009z where result = 'FAIL') then 'FAIL'
                  when not exists (select 1 from pg_temp.verify_0009z where result = 'PASS') then 'FAIL'
                  else 'PASS' end,
             format('201_verify_live_paid_today: %s PASS, %s FAIL, %s skip', (select count(*) from pg_temp.verify_0009z where result = 'PASS'),
                    (select count(*) from pg_temp.verify_0009z where result = 'FAIL'), (select count(*) from pg_temp.verify_0009z where result = 'skip'))) x
order by ord, check_name collate "C";
drop table if exists pg_temp.verify_0009z;
reset role;
