-- 5.12 DST readiness proof (audit of 17 October 2026). Local PostgreSQL only.
-- Throwaway tenants ('dst-<random>') and synthetic people only; one transaction, rolled back at the end.
-- Run:  psql -h 127.0.0.1 -p 5432 -U auditor@local -d cma -f 01_dst_proof.sql 2>&1 | tee 01_dst_proof.out
--
-- Why two dates: the pure bound functions are proved on 2026-10-25 (the real date). The write path
-- (cma.set_status, cma.end_workday, cma.correct_workday), cma.close_forgotten_workdays() (now()-based)
-- and cma.stage_import_batch() (period before today) refuse the future, so those are proved on the
-- previous autumn change, 2025-10-26 03:00 CEST -> 02:00 CET, which follows the same zone rule
-- (section A shows both resolve identically). The 2026 interval arithmetic is proved on the views
-- with rows the owner inserts directly (section C3).
\set ON_ERROR_STOP off
\pset footer off
set role cma_owner;
begin;

\echo
\echo '=== A. PostgreSQL zone facts for Europe/Amsterdam (session TimeZone is UTC, so +00 is shown) ==='
select current_setting('TimeZone') as session_tz, version() as pg;
select '2026-10-25 02:30'::timestamp at time zone 'Europe/Amsterdam' as ambiguous_2026_resolves_to,
       ('2026-10-25 02:30'::timestamp at time zone 'Europe/Amsterdam') at time zone 'Europe/Amsterdam' as back_to_local,
       '2025-10-26 02:30'::timestamp at time zone 'Europe/Amsterdam' as ambiguous_2025_resolves_to,
       '2026-03-29 02:30'::timestamp at time zone 'Europe/Amsterdam' as nonexistent_spring_resolves_to,
       ('2026-03-29 02:30'::timestamp at time zone 'Europe/Amsterdam') at time zone 'Europe/Amsterdam' as spring_back_to_local;
select timestamptz '2026-10-25 00:59:59Z' at time zone 'Europe/Amsterdam' as last_cest_second,
       timestamptz '2026-10-25 01:00:00Z' at time zone 'Europe/Amsterdam' as first_cet_second,
       timestamptz '2025-10-26 00:59:59Z' at time zone 'Europe/Amsterdam' as last_cest_second_2025,
       timestamptz '2025-10-26 01:00:00Z' at time zone 'Europe/Amsterdam' as first_cet_second_2025;
-- cma.business_date: the calendar day of an instant in a zone, around the 25-hour day's bounds
select x.at_utc, cma.business_date(x.at_utc, 'Europe/Amsterdam') as business_date_ams
from (values (timestamptz '2026-10-24 21:59:59Z'), (timestamptz '2026-10-24 22:00:00Z'),
             (timestamptz '2026-10-25 22:59:59Z'), (timestamptz '2026-10-25 23:00:00Z')) x(at_utc);

\echo
\echo '=== Setup: two throwaway tenants (defaults; 07:00-22:00 / 17:00 / grace 60) and synthetic people ==='
create temp table ids (k text primary key, v text);
grant select on ids to cma_app;
do $$
declare
  t1 uuid; t2 uuid; u uuid; r record;
begin
  t1 := cma.create_tenant('dst-' || substr(md5(random()::text), 1, 8), 'DST test defaults', 'Europe/Amsterdam');
  t2 := cma.create_tenant('dst-' || substr(md5(random()::text), 1, 8), 'DST test window', 'Europe/Amsterdam');
  insert into ids values ('t1', t1::text), ('t2', t2::text);
  for r in select * from (values
      (t1, 'admin1', 'admin'), (t1, 'mgr1', 'manager'),
      (t1, 'a1a', 'agent'), (t1, 'a1b', 'agent'), (t1, 'a1c', 'agent'), (t1, 'a1d', 'agent'), (t1, 'a1e', 'agent'), (t1, 'a1f', 'agent'), (t1, 'a1g', 'agent'),
      (t2, 'admin2', 'admin'), (t2, 'mgr2', 'manager'),
      (t2, 'a2a', 'agent'), (t2, 'a2b', 'agent'), (t2, 'a2c', 'agent'), (t2, 'a2d', 'agent'), (t2, 'a2e', 'agent')
    ) as x(tid, k, role_key) loop
    insert into cma.app_user (tenant_id, email, display_name) values (r.tid, 'dst-' || r.k || '@example.invalid', r.k) returning id into u;
    insert into cma.user_role (tenant_id, user_id, role_id) select r.tid, u, ar.id from cma.app_role ar where ar.tenant_id = r.tid and ar.key = r.role_key;
    insert into ids values (r.k, u::text);
  end loop;
  insert into ids select 'sched1', id::text from cma.app_user where tenant_id = t1 and kind = 'system' and email = 'scheduler@system.invalid';
  insert into ids select 'sched2', id::text from cma.app_user where tenant_id = t2 and kind = 'system' and email = 'scheduler@system.invalid';
  -- the Pulse4all window on tenant 2 (as 02_seed_pulse4all.sql sets it); tenant 1 keeps the universal defaults
  insert into cma.tenant_setting (tenant_id, key, value) values
    (t2, 'workday.window_start', '07:00'), (t2, 'workday.window_end', '22:00'),
    (t2, 'workday.auto_close_at', '17:00'), (t2, 'workday.auto_close_grace_minutes', '60');
  -- a published roster for the week of 2025-10-26 on tenant 2: a2c planned 09:00-16:30 that Sunday
  -- (the planner cannot write the past, so the owner writes it as it would have stood, as 47_verify does)
  insert into cma.roster_week (tenant_id, team_id, week_start, status, version, published_at, published_by)
  values (t2, null, date '2025-10-20', 'published', 1, now() - interval '3 days', (select v::uuid from ids where k = 'mgr2'));
  insert into cma.roster_entry (tenant_id, roster_week_id, user_id, business_date, kind, start_time, end_time, recorded_at, recorded_by)
  select t2, w.id, (select v::uuid from ids where k = 'a2c'), date '2025-10-26', 'shift', '09:00', '16:30', now() - interval '4 days', (select v::uuid from ids where k = 'mgr2')
  from cma.roster_week w where w.tenant_id = t2 and w.week_start = date '2025-10-20';
end
$$;
select k, left(v, 8) || '…' as id from ids order by k;

-- the application's role for everything below; the owner comes back only for direct view reads
set local role cma_app;

\echo
\echo '=== Check 1. Business-day bounds for 2026-10-25 Europe/Amsterdam (tenant 1, universal defaults 00:00-24:00) ==='
select set_config('app.tenant_id', (select v from ids where k = 't1'), true), set_config('app.user_id', (select v from ids where k = 'a1a'), true);
select d as business_date,
       cma.business_day_start(d, 'Europe/Amsterdam') as start_utc,
       cma.business_day_end(d, 'Europe/Amsterdam')   as end_utc,
       cma.business_day_end(d, 'Europe/Amsterdam') - cma.business_day_start(d, 'Europe/Amsterdam') as length,
       cma.business_day_start(d, 'Europe/Amsterdam') at time zone 'Europe/Amsterdam' as start_local,
       cma.business_day_end(d, 'Europe/Amsterdam')   at time zone 'Europe/Amsterdam' as end_local
from (values (date '2026-10-24'), (date '2026-10-25'), (date '2026-10-26'), (date '2026-03-29')) v(d);
\echo 'Expected: 2026-10-25 runs 2026-10-24 22:00Z to 2026-10-25 23:00Z = 25:00:00; 2026-03-29 = 23:00:00; the others 24:00:00.'

\echo
\echo '=== Check 2. The workday window 07:00-22:00 on 2026-10-25 (tenant 2) ==='
select set_config('app.tenant_id', (select v from ids where k = 't2'), true), set_config('app.user_id', (select v from ids where k = 'a2a'), true);
select d as business_date,
       cma.business_day_start(d, 'Europe/Amsterdam') as window_start_utc,
       cma.business_day_end(d, 'Europe/Amsterdam')   as window_end_utc,
       cma.business_day_start(d, 'Europe/Amsterdam') at time zone 'Europe/Amsterdam' as window_start_local,
       cma.business_day_end(d, 'Europe/Amsterdam')   at time zone 'Europe/Amsterdam' as window_end_local,
       cma.business_day_end(d, 'Europe/Amsterdam') - cma.business_day_start(d, 'Europe/Amsterdam') as counted_span
from (values (date '2026-10-24'), (date '2026-10-25'), (date '2026-10-26')) v(d);
\echo 'Expected: 2026-10-25 window 06:00Z (07:00 CET) to 21:00Z (22:00 CET), 15:00:00; the 24th 05:00Z to 20:00Z (CEST).'
\echo '-- 2a. clock-in at 06:59 CET on 2026-10-25 (05:59Z) is refused; at 07:00 CET (06:00Z) accepted (open_workday has no future check)'
do $$
declare w cma.workday;
begin
  begin
    w := cma.open_workday(timestamptz '2026-10-25 05:59:00Z');
    raise notice '2a FAIL: a clock-in at 06:59 CET was accepted';
  exception when others then
    raise notice '2a refusal as expected: % %', sqlstate, sqlerrm;
  end;
  w := cma.open_workday(timestamptz '2026-10-25 06:00:00Z');
  raise notice '2a accepted: business_date % started_at % (= % local)', w.business_date, w.started_at, w.started_at at time zone 'Europe/Amsterdam';
end
$$;
\echo '-- 2b. a clock-in at 01:30 CEST on 2026-10-25 (the night, 2026-10-24 23:30Z) is outside the window: refused (a2b, who has no day on that date yet)'
select set_config('app.user_id', (select v from ids where k = 'a2b'), true);
do $$
begin
  perform cma.open_workday(timestamptz '2026-10-24 23:30:00Z');
  raise notice '2b FAIL: accepted';
exception when others then
  raise notice '2b refusal as expected: % %', sqlstate, sqlerrm;
end
$$;
\echo '-- 2c. the count stops at 22:00 local on both sides of the change (2025 dates: the write path refuses the future; a2a again)'
select set_config('app.user_id', (select v from ids where k = 'a2a'), true);
do $$
declare w cma.workday;
begin
  -- Saturday 2025-10-25, CEST: 07:00 to 22:40 with a status change at 22:30
  w := cma.open_workday(timestamptz '2025-10-25 05:00:00Z');
  perform cma.set_status(w.id, 'training', timestamptz '2025-10-25 20:30:00Z');
  perform cma.end_workday(w.id, timestamptz '2025-10-25 20:40:00Z');
  -- Sunday 2025-10-26, CET from 03:00: 07:00 to 22:40 with a status change at 22:30
  w := cma.open_workday(timestamptz '2025-10-26 06:00:00Z');
  perform cma.set_status(w.id, 'training', timestamptz '2025-10-26 21:30:00Z');
  perform cma.end_workday(w.id, timestamptz '2025-10-26 21:40:00Z');
end
$$;
select business_date, started_at, ended_at, working_seconds, working_seconds / 3600.0 as hours, is_capped, needs_correction
from cma.workday_summary where user_id = (select v::uuid from ids where k = 'a2a') and business_date in ('2025-10-25', '2025-10-26') order by 1;
\echo 'Expected: both days 54000 s (15.0 h): 07:00 to 22:00 local, the 22:00-22:40 part not counted, on either side of the change.'

\echo
\echo '=== Check 3. Intervals are computed on instants (tenant 1, defaults) ==='
select set_config('app.tenant_id', (select v from ids where k = 't1'), true), set_config('app.user_id', (select v from ids where k = 'a1a'), true);
\echo '-- 3a. a day opened 23:30 CEST on Sat 2025-10-25 and ended 03:30 CET on Sun 2025-10-26 (5 real hours across the change)'
do $$
declare w cma.workday;
begin
  w := cma.open_workday(timestamptz '2025-10-25 21:30:00Z');
  perform cma.end_workday(w.id, timestamptz '2025-10-26 02:30:00Z');
end
$$;
select business_date, started_at, ended_at, ended_at - started_at as real_elapsed, working_seconds, is_capped, needs_correction
from cma.workday_summary where user_id = (select v::uuid from ids where k = 'a1a');
\echo 'Expected: business_date 2025-10-25, real_elapsed 05:00:00, working_seconds 1800: the count stops at the window end (24:00 = 2025-10-25 22:00Z) by design (0008b), the clock-out after it is accepted.'
\echo '-- 3b. a day on the 25-hour Sunday 2025-10-26: 01:30 CEST, status at 02:30 CEST, status at 02:30 CET, end 03:30 CET'
select set_config('app.user_id', (select v from ids where k = 'a1b'), true);
do $$
declare w cma.workday;
begin
  w := cma.open_workday(timestamptz '2025-10-25 23:30:00Z');                          -- 01:30 CEST
  perform cma.set_status(w.id, 'training',  timestamptz '2025-10-26 00:30:00Z');       -- 02:30 CEST (first)
  perform cma.set_status(w.id, 'available', timestamptz '2025-10-26 01:30:00Z');       -- 02:30 CET (second)
  perform cma.end_workday(w.id,             timestamptz '2025-10-26 02:30:00Z');       -- 03:30 CET
end
$$;
select business_date, started_at, ended_at, working_seconds, working_seconds / 3600.0 as hours
from cma.workday_summary where user_id = (select v::uuid from ids where k = 'a1b');
select i.from_at, i.to_at, i.from_at at time zone 'Europe/Amsterdam' as from_local, i.to_at at time zone 'Europe/Amsterdam' as to_local, i.seconds
from cma.time_interval i where i.user_id = (select v::uuid from ids where k = 'a1b') order by i.from_at;
\echo 'Expected: 10800 s (3.0 h), three stretches of 3600 s; the two 02:30 local times are one hour apart. A local-time subtraction would give 7200.'
\echo '-- 3c. the same on the real date, 2026-10-25, rows written by the owner straight into the tables (the write path refuses the future)'
set local role cma_owner;
do $$
declare t uuid := (select v::uuid from ids where k = 't1'); u uuid := (select v::uuid from ids where k = 'a1b'); w uuid; s_train uuid; s_avail uuid;
begin
  select id into s_train from cma.work_status where tenant_id = t and key = 'training';
  select id into s_avail from cma.work_status where tenant_id = t and key = 'available';
  insert into cma.workday (tenant_id, user_id, business_date, timezone, status, started_at, ended_at)
  values (t, u, date '2026-10-25', 'Europe/Amsterdam', 'ended', timestamptz '2026-10-24 23:30:00Z', timestamptz '2026-10-25 02:30:00Z') returning id into w;
  insert into ids values ('w2026', w::text);
  insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source) values
    (t, w, u, 'start',  s_avail, timestamptz '2026-10-24 23:30:00Z', 'user'),   -- 01:30 CEST
    (t, w, u, 'status', s_train, timestamptz '2026-10-25 00:30:00Z', 'user'),   -- 02:30 CEST
    (t, w, u, 'status', s_avail, timestamptz '2026-10-25 01:30:00Z', 'user'),   -- 02:30 CET
    (t, w, u, 'end',    null,    timestamptz '2026-10-25 02:30:00Z', 'user');   -- 03:30 CET
end
$$;
select i.from_at at time zone 'Europe/Amsterdam' as from_local, i.to_at at time zone 'Europe/Amsterdam' as to_local, i.seconds, i.is_capped
from cma.time_interval_all i where i.workday_id = (select v::uuid from ids where k = 'w2026') order by i.from_at;
select business_date, working_seconds, is_capped, needs_correction from cma.workday_summary_all where workday_id = (select v::uuid from ids where k = 'w2026');
\echo 'Expected: three stretches of 3600 s, 10800 s on 2026-10-25, not capped.'
set local role cma_app;
\echo '-- 3d. corrections: the Day editor must send an offset; both instants of 02:45 are accepted and land an hour apart (mgr1 corrects a1b''s 2025-10-26)'
select set_config('app.user_id', (select v from ids where k = 'mgr1'), true);
do $$
declare w cma.workday;
begin
  begin
    perform cma.correct_workday((select v::uuid from ids where k = 'a1b'), date '2025-10-26',
      jsonb_build_array(jsonb_build_object('kind', 'status', 'statusKey', 'training', 'at', '2025-10-26T02:45:00')), 'DST audit: no offset');
    raise notice '3d FAIL: a time without an offset was accepted';
  exception when others then
    raise notice '3d refusal as expected: % %', sqlstate, sqlerrm;
  end;
  w := cma.correct_workday((select v::uuid from ids where k = 'a1b'), date '2025-10-26',
    jsonb_build_array(jsonb_build_object('kind', 'status', 'statusKey', 'training', 'at', '2025-10-26T02:45:00+02:00')), 'DST audit: CEST');
  w := cma.correct_workday((select v::uuid from ids where k = 'a1b'), date '2025-10-26',
    jsonb_build_array(jsonb_build_object('kind', 'status', 'statusKey', 'training', 'at', '2025-10-26T02:45:00+01:00')), 'DST audit: CET');
end
$$;
select e.kind, e.occurred_at, e.occurred_at at time zone 'Europe/Amsterdam' as local_time, e.source
from cma.time_event_effective e where e.user_id = (select v::uuid from ids where k = 'a1b') and e.occurred_at < timestamptz '2026-01-01' order by e.occurred_at;
select business_date, working_seconds, paid_seconds, has_correction from cma.team_hours('2025-10-25', '2025-10-26', (select v::uuid from ids where k = 'a1b'));
\echo 'Expected: six effective events; two "02:45" at 00:45Z and 01:45Z; team_hours still 10800 working seconds (training is working).'

\echo
\echo '=== Check 4. The forgotten-day close across the change, run twice ==='
\echo '-- when would the hourly UTC runs on the night of 24/25 Oct 2026 pick up a forgotten day of Sat 24 Oct? (pure arithmetic, both tenants)'
select set_config('app.tenant_id', (select v from ids where k = 't2'), true), set_config('app.user_id', (select v from ids where k = 'sched2'), true);
select 'tenant 2 (22:00 + 60 min)' as tenant, cma.business_day_end(date '2026-10-24', 'Europe/Amsterdam') as day_end_utc,
       cma.business_day_end(date '2026-10-24', 'Europe/Amsterdam') + interval '60 minutes' as closable_from_utc,
       string_agg(to_char(r, 'HH24:MI"Z"') || case when cma.business_day_end(date '2026-10-24', 'Europe/Amsterdam') + interval '60 minutes' <= r then '=closes' else '=waits' end, ' ' order by r) as hourly_runs
from generate_series(timestamptz '2026-10-24 20:00Z', timestamptz '2026-10-25 02:00Z', interval '1 hour') r;
select set_config('app.tenant_id', (select v from ids where k = 't1'), true), set_config('app.user_id', (select v from ids where k = 'sched1'), true);
select 'tenant 1 (24:00 + 120 min)' as tenant, cma.business_day_end(date '2026-10-24', 'Europe/Amsterdam') as day_end_utc,
       cma.business_day_end(date '2026-10-24', 'Europe/Amsterdam') + interval '120 minutes' as closable_from_utc,
       string_agg(to_char(r, 'HH24:MI"Z"') || case when cma.business_day_end(date '2026-10-24', 'Europe/Amsterdam') + interval '120 minutes' <= r then '=closes' else '=waits' end, ' ' order by r) as hourly_runs
from generate_series(timestamptz '2026-10-24 20:00Z', timestamptz '2026-10-25 02:00Z', interval '1 hour') r;
\echo 'Expected: tenant 2 closes at the 21:00Z run (23:00 CEST); tenant 1 at the 00:00Z run (02:00 CEST, the first 02:00). The repeated local hour plays no role: the condition is on instants.'
\echo '-- 4a. forgotten days (2025 dates): t2: a2b Sat 25 Oct 08:00 CEST no shift; a2c Sun 26 Oct 08:00 CET with a 09:00-16:30 shift; a2d Sun 26 Oct 08:00 CET, last event 19:12 CET. t1: a1g Sat 25 Oct 23:00 CEST, no window'
select set_config('app.tenant_id', (select v from ids where k = 't2'), true), set_config('app.actor_label', '', true);
do $$
declare w cma.workday;
begin
  perform set_config('app.user_id', (select v from ids where k = 'a2b'), true);
  w := cma.open_workday(timestamptz '2025-10-25 06:00:00Z');
  perform set_config('app.user_id', (select v from ids where k = 'a2c'), true);
  w := cma.open_workday(timestamptz '2025-10-26 07:00:00Z');
  perform set_config('app.user_id', (select v from ids where k = 'a2d'), true);
  w := cma.open_workday(timestamptz '2025-10-26 07:00:00Z');
  perform cma.set_status(w.id, 'break', timestamptz '2025-10-26 18:12:00Z');
end
$$;
select set_config('app.user_id', (select v from ids where k = 'sched2'), true);
select (select display_name from cma.app_user where id = x.user_id) as who, x.business_date, x.ended_at, x.ended_at at time zone 'Europe/Amsterdam' as ended_local, x.end_rule
from cma.close_forgotten_workdays() x order by business_date, who;
\echo 'Expected: a2b 2025-10-25 15:00Z = 17:00 CEST default; a2c 2025-10-26 15:30Z = 16:30 CET shift; a2d 2025-10-26 18:12Z = 19:12 CET last_event. Never an hour off.'
select count(*) as second_run_closes from cma.close_forgotten_workdays();
select title, count(*) as messages from cma.message where sender_user_id = (select v::uuid from ids where k = 'sched2') group by title order by title;
\echo 'Expected: second run 0; messages: 3 x "Workday closed automatically", 1 x "Workdays closed automatically".'
select set_config('app.tenant_id', (select v from ids where k = 't1'), true), set_config('app.user_id', (select v from ids where k = 'a1g'), true);
do $$
begin
  perform cma.open_workday(timestamptz '2025-10-25 21:00:00Z');   -- 23:00 CEST, left open
end
$$;
select set_config('app.user_id', (select v from ids where k = 'sched1'), true);
select x.business_date, x.ended_at, x.ended_at at time zone 'Europe/Amsterdam' as ended_local, x.end_rule from cma.close_forgotten_workdays() x;
select count(*) as second_run_closes from cma.close_forgotten_workdays();
\echo 'Expected: a1g 2025-10-25 ended 2025-10-25 22:00Z = 2025-10-26 00:00 CEST (the default 24:00 of the 25th, in CEST, not 23:00 Z); second run 0.'

\echo
\echo '=== Check 5. Legacy import: local times on a DST day (tenant 1, defaults, so nothing is clipped) ==='
select set_config('app.tenant_id', (select v from ids where k = 't1'), true), set_config('app.user_id', (select v from ids where k = 'admin1'), true);
select cma.upsert_work_status('legacy_a', 'Legacy A', true, true, true, true, 900);
select cma.upsert_work_status('legacy_b', 'Legacy B', true, true, true, true, 901);
select key, is_working, is_default, status from cma.work_status where key like 'legacy_%' order by key;
\echo '-- 5a. autumn 2025: A1 01:30-02:30 (ambiguous logout), A2 02:30-03:30 (ambiguous login), A3 01:00-04:00 (spans the change)'
select key, status, period_from, period_to, timezone from cma.stage_import_batch('dst-autumn-2025', 'audit', 'dst.csv', '2025-10-25', '2025-10-26', 'Europe/Amsterdam', 'legacy_a', 'lunch');
insert into cma.import_session_staging (batch_key, external_person_id, external_person_name, external_session_id, login_local, logout_local, role) values
  ('dst-autumn-2025', 'A1', null, 's1', '2025-10-26 01:30', '2025-10-26 02:30', null),
  ('dst-autumn-2025', 'A2', null, 's2', '2025-10-26 02:30', '2025-10-26 03:30', null),
  ('dst-autumn-2025', 'A3', null, 's3', '2025-10-26 01:00', '2025-10-26 04:00', null);
insert into cma.import_person_map (batch_id, external_person_id, user_id)
select b.id, x.acct, (select v::uuid from ids where k = x.who)
from cma.import_batch b, (values ('A1', 'a1c'), ('A2', 'a1d'), ('A3', 'a1e')) x(acct, who) where b.key = 'dst-autumn-2025';
select status, counts from cma.load_import_batch('dst-autumn-2025');
select m.external_person_id as acct, d.business_date, d.seconds, d.seconds / 3600.0 as hours,
       (select string_agg(to_char(e.occurred_at, 'HH24:MI"Z"') || '=' || to_char(e.occurred_at at time zone 'Europe/Amsterdam', 'HH24:MI"local"'), ' ' order by e.occurred_at)
        from cma.time_event e where e.workday_id = d.workday_id) as events
from cma.import_day d join cma.import_person_map m on m.batch_id = d.batch_id and m.user_id = d.user_id order by acct;
\echo 'Expected (PostgreSQL reads an ambiguous local time as standard time, CET, the later instant): A1 7200 s (02:30 -> CET = 01:30Z), A2 3600 s, A3 14400 s (4 real hours; the wall clock says 3). A Steam logout really at 02:30 CEST would count one hour too long: documented behaviour (README 0008d), outside Pulse4all''s imported period.'
\echo '-- 5b. spring 2026: a session in the skipped hour is refused as a whole; one spanning the gap counts real time'
select key, status from cma.stage_import_batch('dst-spring-gap', 'audit', 'dst.csv', '2026-03-28', '2026-03-29', 'Europe/Amsterdam', 'legacy_b', 'lunch');
insert into cma.import_session_staging (batch_key, external_person_id, external_person_name, external_session_id, login_local, logout_local, role) values
  ('dst-spring-gap', 'B1', null, 'g1', '2026-03-29 02:30', '2026-03-29 04:00', null);
insert into cma.import_person_map (batch_id, external_person_id, user_id) select b.id, 'B1', (select v::uuid from ids where k = 'a1f') from cma.import_batch b where b.key = 'dst-spring-gap';
do $$
begin
  perform cma.load_import_batch('dst-spring-gap');
  raise notice '5b FAIL: a session in the spring gap loaded';
exception when others then
  raise notice '5b refusal as expected: % %', sqlstate, sqlerrm;
end
$$;
select key, status from cma.stage_import_batch('dst-spring-span', 'audit', 'dst.csv', '2026-03-28', '2026-03-29', 'Europe/Amsterdam', 'legacy_b', 'lunch');
insert into cma.import_session_staging (batch_key, external_person_id, external_person_name, external_session_id, login_local, logout_local, role) values
  ('dst-spring-span', 'B2', null, 'g2', '2026-03-29 01:30', '2026-03-29 03:30', null);
insert into cma.import_person_map (batch_id, external_person_id, user_id) select b.id, 'B2', (select v::uuid from ids where k = 'a1f') from cma.import_batch b where b.key = 'dst-spring-span';
select status, counts->>'days_written' as days_written, counts->>'events_written' as events_written from cma.load_import_batch('dst-spring-span');
select d.business_date, d.seconds, (select string_agg(to_char(e.occurred_at, 'HH24:MI"Z"') || '=' || to_char(e.occurred_at at time zone 'Europe/Amsterdam', 'HH24:MI"local"'), ' ' order by e.occurred_at)
        from cma.time_event e where e.workday_id = d.workday_id) as events
from cma.import_day d where d.user_id = (select v::uuid from ids where k = 'a1f');
\echo 'Expected: the gap batch refused with CMA04 "fall in the spring clock change gap"; the spanning session 3600 s (01:30 CET = 00:30Z to 03:30 CEST = 01:30Z), not 7200.'

\echo
\echo '=== Check 6. Roster: local times, the shift line of 2026-10-25 (tenant 2) ==='
select set_config('app.tenant_id', (select v from ids where k = 't2'), true), set_config('app.user_id', (select v from ids where k = 'mgr2'), true);
select kind, start_time, end_time from cma.roster_set_entry(date '2026-10-19', null, (select v::uuid from ids where k = 'a2e'), date '2026-10-25', 'shift', '07:00', '22:00', null, null);
select status, version from cma.roster_publish(date '2026-10-19', null);
select set_config('app.user_id', (select v from ids where k = 'a2e'), true);
select business_date, is_published, kind, start_time, end_time from cma.my_roster('2026-10-25', '2026-10-25');
select cma.business_day_time(date '2026-10-25', 'Europe/Amsterdam', time '07:00') as planned_start_utc,
       cma.business_day_time(date '2026-10-25', 'Europe/Amsterdam', time '22:00') as planned_end_utc,
       cma.business_day_time(date '2026-10-25', 'Europe/Amsterdam', time '22:00') - cma.business_day_time(date '2026-10-25', 'Europe/Amsterdam', time '07:00') as planned_span,
       cma.business_day_time(date '2026-10-25', 'Europe/Amsterdam', time '24:00') as end_of_day_utc,
       cma.business_day_time(date '2026-10-25', 'Europe/Amsterdam', time '02:30') as ambiguous_window_time_utc;
\echo 'Expected: my_roster gives 07:00/22:00 as local times (no instants); the close''s shift end for the 25th is 21:00Z = 22:00 CET; span 15:00:00; 24:00 is 23:00Z; a 02:30 window time would be read as CET (01:30Z).'

\echo
\echo '=== Check 7. Exports group on the day''s business date; stretches carry instants (tenant 1, mgr1 holds workday.export) ==='
select set_config('app.tenant_id', (select v from ids where k = 't1'), true), set_config('app.user_id', (select v from ids where k = 'mgr1'), true);
select display_name, business_date, timezone, status_key, from_at, to_at, seconds, source
from cma.export_status_changes('2025-10-25', '2025-10-26', (select v::uuid from ids where k = 'a1b')) order by from_at;
select display_name, business_date, started_at, ended_at, working_seconds, is_capped, needs_correction from cma.export_hours('2025-10-25', '2025-10-26') order by business_date, display_name;
\echo 'Expected: every row dated by the workday''s business_date (set at open from the instant in the zone), from/to as instants, seconds as the view counts them.'

\echo
\echo '=== Rollback: nothing of this stays ==='
rollback;
set role cma_owner;
select count(*) as dst_tenants_left from cma.tenant where slug like 'dst-%';
