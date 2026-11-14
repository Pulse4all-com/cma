-- =============================================================================================
-- tools/perf/live-poll-breakdown.sql: what the Live board's polls cost the database, in stages (read-only)
-- =============================================================================================
-- Why (Martin, 14 November 2026): in prod 131 part a read team now 61 ms, inbound now 36 ms and live board calls 31 ms
-- against the poll's 20 ms, on a Saturday with few calls; and 183's E3 read the first twenty missed callers 5 ms slower
-- than every caller where the list holds about twenty. This tool says where the milliseconds go and how long the
-- missed callers' list is on a working day. Run it in office hours, while the Live board is in use:
--
--   cd ~/cma && cma_db prod && psql "$PGCONN" -X -f tools/perf/live-poll-breakdown.sql > /tmp/live-poll-breakdown-prod.txt 2>&1
--
-- Another tenant: add  -v tenant_slug=<slug>  (the default is pulse4all-subscriptions).
--
-- What it shows
--   1. Sizes: the lookback, the missed inbound calls of known callers in it, their distinct callers, the callers the
--      list holds now, the anonymous missed calls, today's inbound calls, the people of Team now.
--   2. Per day of the last 28 days: the missed inbound calls of known callers and their distinct callers (counts only).
--      The list is a backlog over the lookback, not a day's count: the day's distinct callers bound what a day adds.
--   3. Each read's time, as the application's role and as a person holding monitoring.live. Every stage runs nine times
--      as a fresh statement (planned at each call, as a request's unprepared statement is) and nine times as a prepared
--      statement (the plan a connection keeps): the first call, and the best, median and worst of calls seven to nine.
--      Where "planned each call" is far above "prepared", the time is planning, not reading. Every column of every row
--      is read and its text's length summed (chars), so no read is skipped; that costs the same in every stage.
--        I1  cma.inbound_today_live_of        today's counts and the service level
--        I2  cma.missed_callbacks_of          the callers' derivation with a record link per caller
--        I2n the same without the record links
--        I3  cma.anonymous_missed_calls_of    the summary's anonymous count
--        I4  cma.inbound_now()                the three together, as main's web polls it
--        N1  cma.inbound_now_first(20)        where addition 0009q has run: the first twenty and the whole count
--        N2  cma.inbound_now_first(null)      where addition 0009q has run: every caller
--        O1  cma.outbound_now()
--        L1  inbound and outbound in one statement, as the board's poll sends it
--        T1  cma.team_now() alone
--        T2  Team now as the page reads it (the day's end, the sessions, clock-in-again per person)
--        T3  cma.team_now() with the day's end only
--        T4  cma.team_now() with the sessions only
--        T5  cma.team_now() with clock-in-again only
--        R1  cma.roster_today()
--   4. The plans, with planning and execution time and buffers: the callers' derivation (inlined, so its plan shows),
--      cma.inbound_now() and Team now as the page reads it (functions that are not inlined show as one node with their
--      time; the sub-plans per person show theirs).
-- Nothing is written: one transaction, rolled back; its temporary table and prepared statements end with it. Locks: the
-- reads' own. Output: the tenant's id, counts, milliseconds and plans (conditions and constants, never a row's content,
-- no caller, no number, no name).
-- =============================================================================================
\set ON_ERROR_STOP on
\pset pager off
\if :{?tenant_slug}
\else
  \set tenant_slug pulse4all-subscriptions
\endif

begin;
set local statement_timeout = '120s';
set local lock_timeout = '2s';
set local role cma_owner;
select (select t.id from cma.tenant t where t.slug = :'tenant_slug') as tenant_id
\gset
\if :{?tenant_id}
\else
  \echo no tenant with this slug: nothing shown
  rollback;
  \quit
\endif
-- the tenant's first active person (the oldest) holding monitoring.live, as 183 picks its reader
select set_config('app.tenant_id', :'tenant_id', true) is not null as tenant_set;
select (select u.id
        from cma.app_user u
        where u.tenant_id = :'tenant_id' and u.status = 'active' and u.kind = 'person'
          and cma.has_permission(u.id, 'monitoring.live')
        order by u.created_at, u.id
        limit 1) as reader_id
\gset
\if :{?reader_id}
\else
  \echo no active person of this tenant holds monitoring.live: nothing shown
  rollback;
  \quit
\endif
select exists (select 1 from cma.schema_migration m where m.version = '0009q') as has_0009q
\gset

\echo
\echo ==== 1. Sizes ====
select :'tenant_id' as tenant_id, now() as measured_at, current_setting('server_version') as server_version,
       :'has_0009q'::boolean as has_0009q,
       s.lookback_days,
       (select count(*) from cma.telephony_call tc
        where tc.tenant_id = :'tenant_id' and tc.direction = 'inbound' and tc.answered_at is null and tc.source_deleted_at is null
          and tc.counterpart_hash is not null and tc.started_at >= now() - make_interval(days => s.lookback_days)) as missed_known_calls_in_lookback,
       (select count(distinct tc.counterpart_hash) from cma.telephony_call tc
        where tc.tenant_id = :'tenant_id' and tc.direction = 'inbound' and tc.answered_at is null and tc.source_deleted_at is null
          and tc.counterpart_hash is not null and tc.started_at >= now() - make_interval(days => s.lookback_days)) as distinct_callers_in_lookback,
       (select count(*) from cma.missed_callbacks_of(:'tenant_id')) as callers_listed_now,
       cma.anonymous_missed_calls_of(:'tenant_id', now() - make_interval(days => s.lookback_days)) as anonymous_missed_calls,
       (select count(*) from cma.telephony_call tc
        where tc.tenant_id = :'tenant_id' and tc.direction = 'inbound' and tc.source_deleted_at is null
          and tc.started_at >= (now() at time zone t.timezone)::date::timestamp at time zone t.timezone) as inbound_calls_today,
       (select count(*) from cma.telephony_call tc
        where tc.tenant_id = :'tenant_id' and tc.source_deleted_at is null
          and tc.started_at >= now() - make_interval(days => s.lookback_days)) as calls_in_lookback
from cma.tenant t
cross join lateral (select greatest(0, cma.setting_of(t.id, 'telephony.callback_lookback_days')::integer) as lookback_days) s
where t.id = :'tenant_id';

\echo
\echo ==== 2. Missed inbound calls of known callers per day, the last 28 days (days of the tenant; counts only) ====
select (tc.started_at at time zone t.timezone)::date as day,
       to_char((tc.started_at at time zone t.timezone)::date, 'Dy') as weekday,
       count(*) as missed_known_calls,
       count(distinct tc.counterpart_hash) as distinct_callers
from cma.telephony_call tc
join cma.tenant t on t.id = tc.tenant_id
where tc.tenant_id = :'tenant_id' and tc.direction = 'inbound' and tc.answered_at is null and tc.source_deleted_at is null
  and tc.counterpart_hash is not null
  and tc.started_at >= ((now() at time zone t.timezone)::date - 27)::timestamp at time zone t.timezone
group by 1, 2
order by 1;

create temporary table poll_breakdown (ord integer, stage text, what text, rows bigint, chars bigint,
                                       planned_first_ms numeric, planned_best_ms numeric, planned_median_ms numeric, planned_worst_ms numeric,
                                       prepared_first_ms numeric, prepared_best_ms numeric, prepared_median_ms numeric, prepared_worst_ms numeric)
  on commit drop;
grant select, insert on poll_breakdown to cma_app;
create temporary table poll_stage (ord integer, stage text, what text, q text) on commit drop;
grant select on poll_stage to cma_app;
insert into poll_stage values
  (1, 'I1', 'cma.inbound_today_live_of', format('select * from cma.inbound_today_live_of(%L)', :'tenant_id')),
  (2, 'I2', 'cma.missed_callbacks_of with a record link per caller',
      format('select m.*, cma.record_url(m.connection_id, ''call'', m.source_id) as record_url from cma.missed_callbacks_of(%L) m', :'tenant_id')),
  (3, 'I2n', 'cma.missed_callbacks_of without the record links', format('select m.* from cma.missed_callbacks_of(%L) m', :'tenant_id')),
  (4, 'I3', 'cma.anonymous_missed_calls_of (the lookback)',
      format('select cma.anonymous_missed_calls_of(%L, now() - make_interval(days => greatest(0, cma.setting_of(%L, ''telephony.callback_lookback_days'')::integer))) as n offset 0',
             :'tenant_id', :'tenant_id')),
  (5, 'I4', 'cma.inbound_now() (main''s poll)', 'select cma.inbound_now()::text as j offset 0'),
  (8, 'O1', 'cma.outbound_now()', 'select cma.outbound_now()::text as o offset 0'),
  (9, 'L1', 'inbound and outbound in one statement (main''s board poll)', 'select cma.inbound_now()::text as j, cma.outbound_now()::text as o offset 0'),
  (10, 'T1', 'cma.team_now() alone', 'select n.* from cma.team_now() n'),
  (11, 'T2', 'Team now as the page reads it',
      'select n.*, cma.business_day_end(n.business_date, n.timezone) as day_ends_at, coalesce(se.sessions, 0)::int as sessions, se.session_started_at, '
      || '(select coalesce(cma.setting_of(cma.current_tenant_id(), ''workday.clock_in_again'') = ''true'', false)) as clock_in_again, '
      || 'cma.workday_can_clock_in_again(n.workday_id) as can_clock_in_again '
      || 'from cma.team_now() n left join lateral (select count(*) as sessions, max(e.occurred_at) as session_started_at '
      || 'from cma.time_event_effective e where e.workday_id = n.workday_id and e.kind = ''start'') se on true'),
  (12, 'T3', 'cma.team_now() with the day''s end only', 'select n.*, cma.business_day_end(n.business_date, n.timezone) as day_ends_at from cma.team_now() n'),
  (13, 'T4', 'cma.team_now() with the sessions only',
      'select n.*, se.sessions from cma.team_now() n left join lateral (select count(*) as sessions, max(e.occurred_at) as session_started_at '
      || 'from cma.time_event_effective e where e.workday_id = n.workday_id and e.kind = ''start'') se on true'),
  (14, 'T5', 'cma.team_now() with clock-in-again only', 'select n.*, cma.workday_can_clock_in_again(n.workday_id) as can_clock_in_again from cma.team_now() n'),
  (15, 'R1', 'cma.roster_today()', 'select r.* from cma.roster_today() r');
\if :has_0009q
insert into poll_stage values
  (6, 'N1', 'cma.inbound_now_first(20) (addition 0009q)', 'select cma.inbound_now_first(20)::text as j offset 0'),
  (7, 'N2', 'cma.inbound_now_first(null) (addition 0009q: every caller)', 'select cma.inbound_now_first(null)::text as j offset 0');
\endif

select set_config('app.user_id', :'reader_id', true) is not null as reader_set;
set local role cma_app;

do $$
declare
  r record;
  v_t0 timestamptz; n bigint; v_len bigint;
  a_plan numeric[]; a_prep numeric[];
begin
  for r in select * from poll_stage order by ord loop
    a_plan := '{}'; a_prep := '{}';
    -- planned at each call: a fresh statement, as a request's unprepared statement
    for i in 1 .. 9 loop
      v_t0 := clock_timestamp();
      execute 'select count(*), sum(length(z::text)) from (' || r.q || ') z' into n, v_len;
      a_plan := a_plan || round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
    end loop;
    -- prepared: the plan the connection keeps (a custom plan for the first five executions, then the generic one where
    -- it is no dearer)
    execute 'prepare poll_p as select count(*), sum(length(z::text)) from (' || r.q || ') z';
    for i in 1 .. 9 loop
      v_t0 := clock_timestamp();
      execute 'execute poll_p';
      a_prep := a_prep || round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
    end loop;
    execute 'deallocate poll_p';
    insert into poll_breakdown
    select r.ord, r.stage, r.what, n, v_len,
           a_plan[1], (select min(x) from unnest(a_plan[7:9]) x), (select percentile_disc(0.5) within group (order by x) from unnest(a_plan[7:9]) x),
           (select max(x) from unnest(a_plan[7:9]) x),
           a_prep[1], (select min(x) from unnest(a_prep[7:9]) x), (select percentile_disc(0.5) within group (order by x) from unnest(a_prep[7:9]) x),
           (select max(x) from unnest(a_prep[7:9]) x);
  end loop;
end
$$;

\echo
\echo ==== 3. The stages, in milliseconds: planned at each call, and prepared (first call; best, median, worst of calls 7 to 9) ====
select stage, what, rows, chars,
       planned_first_ms as plan_first, planned_best_ms as plan_best, planned_median_ms as plan_median, planned_worst_ms as plan_worst,
       prepared_first_ms as prep_first, prepared_best_ms as prep_best, prepared_median_ms as prep_median, prepared_worst_ms as prep_worst
from poll_breakdown order by ord;

\echo
\echo ==== 4a. The plan of the derivation of the callers (cma.missed_callbacks_of, inlined) ====
explain (analyze, buffers)
select count(*) from cma.missed_callbacks_of(:'tenant_id') m;

\echo
\echo ==== 4b. The plan of cma.inbound_now() (one node: the function is not inlined; its planning and execution time) ====
explain (analyze, buffers)
select cma.inbound_now();

\echo
\echo ==== 4c. The plan of Team now as the page reads it ====
explain (analyze, buffers)
select n.*, cma.business_day_end(n.business_date, n.timezone) as day_ends_at,
       coalesce(se.sessions, 0)::int as sessions, se.session_started_at,
       (select coalesce(cma.setting_of(cma.current_tenant_id(), 'workday.clock_in_again') = 'true', false)) as clock_in_again,
       cma.workday_can_clock_in_again(n.workday_id) as can_clock_in_again
from cma.team_now() n
left join lateral (select count(*) as sessions, max(e.occurred_at) as session_started_at
                   from cma.time_event_effective e where e.workday_id = n.workday_id and e.kind = 'start') se on true;

rollback;
