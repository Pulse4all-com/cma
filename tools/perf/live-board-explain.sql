-- =============================================================================================
-- tools/perf/live-board-explain.sql: where the Live board's 10-second poll spends its database time (the Live board's
-- speed review, 10 November 2026)
-- =============================================================================================
-- Measures, writes nothing that stays: one transaction that is always rolled back (not read only: the follow-up
-- summary computes a missing snapshot once as it reads, which a read-only transaction refuses, as 131 notes). Run by
-- Martin in his own terminal, as his own IAM login, against the database to measure (after 164; part 3c only after
-- 168_live_inbound_talk.sql, skipped without it):
--
--   cd ~/cma && cma_db prod && psql "$PGCONN" -X -f tools/perf/live-board-explain.sql > /tmp/live-board-explain-prod.txt 2>&1
--
-- The tenant is picked by slug (psql variable tenant_slug, default pulse4all-subscriptions; another one with
-- -v tenant_slug=<slug>); the reads run as the application (role cma_app, the tenant in app.tenant_id, acting as the
-- tenant's first active person holding monitoring.live), under row-level security, as the board's poll does
-- (web/src/lib/data/postgres.ts getLiveBoard, one transaction). Output: ids, counts, plans and milliseconds only; no
-- person's name, no call, number or hash is selected or printed (the plans show conditions and constants, never a
-- row's content).
--
-- Parts
--   0  context: the tenant and acting user (ids), the sizes that drive the poll (people on the board, today's calls,
--      the missed callers listed)
--   1  the poll's eight statements in the web's order, each with its plan and time: team now (with the day's
--      sessions), the status flags, the team members, today's roster, the settings, the calls (cma.inbound_now() and
--      cma.outbound_now() in one statement), the connections and the follow-up summary; each statement's first call on
--      this connection
--   2  team now taken apart: cma.team_now() alone against the web's statement, so the share of the sessions' columns
--      (per row: the day's end, the clock-ins, workday_can_clock_in_again) is known
--   3  inbound now taken apart: the missed callers with their record links as cma.inbound_now() builds them, the
--      anonymous count, today's figures (cma.inbound_today_live_of, 168), and outbound now
--   4  each statement run seven times more on this connection, every row and column fetched: the first of them (the
--      statement's second call, part 1 was its first), the seventh (its eighth, past a pooled connection's switch to
--      the generic plan after five calls) and the best, and their sum: the poll's database time against the 20 ms budget
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

\echo
\echo ==== 0. Context ====
-- always one row (a \gset on none stops psql): a null leaves the variable unset, and the \if below says why
select (select t.id from cma.tenant t where t.slug = :'tenant_slug') as tenant_id
\gset
\if :{?tenant_id}
\else
  \echo no tenant with this slug: nothing measured
  rollback;
  \quit
\endif
select set_config('app.tenant_id', :'tenant_id', true) as tenant;
select (select u.id
        from cma.app_user u
        where u.tenant_id = :'tenant_id' and u.status = 'active' and u.kind = 'person' and cma.has_permission(u.id, 'monitoring.live')
        order by u.created_at, u.id limit 1) as user_id
\gset
\if :{?user_id}
\else
  \echo no active person of this tenant holds monitoring.live: nothing measured
  rollback;
  \quit
\endif
select :'tenant_id' as tenant_id, :'user_id' as acting_user_id, current_setting('server_version') as server_version;
select to_regprocedure('cma.inbound_today_live_of(uuid)') is not null as has_0009j
\gset
select (select count(*) from cma.app_user u where u.tenant_id = :'tenant_id' and u.status = 'active' and u.kind = 'person') as active_people,
       (select count(*) from cma.telephony_call tc, cma.tenant t where t.id = :'tenant_id' and tc.tenant_id = t.id
          and tc.started_at >= (now() at time zone t.timezone)::date::timestamp at time zone t.timezone) as calls_since_tenant_midnight,
       (select count(*) from cma.missed_callbacks_of(:'tenant_id')) as missed_callers_listed;

-- from here on as the application, acting for the tenant
select set_config('app.user_id', :'user_id', true) as acting_user;
set local role cma_app;

\echo
\echo ==== 1. The poll's statements as the web runs them ====
\echo -- 1a team now, with the day's sessions
explain (analyze, buffers) select n.*, cma.business_day_end(n.business_date, n.timezone) as day_ends_at,
  coalesce(se.sessions, 0)::int as sessions, se.session_started_at,
  (select coalesce(cma.setting_of(cma.current_tenant_id(), 'workday.clock_in_again') = 'true', false)) as clock_in_again,
  cma.workday_can_clock_in_again(n.workday_id) as can_clock_in_again
  from cma.team_now() n left join lateral (select count(*) as sessions, max(e.occurred_at) as session_started_at
  from cma.time_event_effective e where e.workday_id = n.workday_id and e.kind = 'start') se on true;
\echo -- 1b the status flags
explain (analyze, buffers) select is_working, is_productive, is_paid from cma.work_status where status = 'active' order by sort_order, key;
\echo -- 1c the team members
explain (analyze, buffers) select * from cma.team_members_now();
\echo -- 1d today's roster
explain (analyze, buffers) select * from cma.roster_today();
\echo -- 1e the settings
explain (analyze, buffers) select * from cma.tenant_settings();
\echo -- 1f the calls, one statement
explain (analyze, buffers) select cma.inbound_now() as j, cma.outbound_now() as o;
\echo -- 1g the connections (telephony and commerce on), read after the calls as readCallsNow does
explain (analyze, buffers) select exists (select 1 from cma.telephony_number n
                      join cma.integration_connection c on c.tenant_id = n.tenant_id and c.id = n.connection_id
                     where c.status = 'active')
         or exists (select 1 from cma.telephony_call t
                      join cma.integration_connection c on c.tenant_id = t.tenant_id and c.id = t.connection_id
                     where c.status = 'active') as telephony,
            exists (select 1 from cma.commerce_store s
                      join cma.integration_connection c on c.tenant_id = s.tenant_id and c.id = s.connection_id
                     where c.status = 'active') as commerce;
\echo -- 1h the follow-up summary
explain (analyze, buffers) select * from cma.follow_up_summary();

\echo
\echo ==== 2. Team now taken apart ====
\echo -- 2a cma.team_now() alone
explain (analyze, buffers) select * from cma.team_now();

\echo
\echo ==== 3. Inbound now taken apart ====
\echo -- 3a the missed callers with their record links, as cma.inbound_now() builds the list
explain (analyze, buffers)
  select coalesce(jsonb_agg(to_jsonb(m) || jsonb_build_object('record_url', cma.record_url(m.connection_id, 'call', m.source_id)) order by m.started_at, m.source_id), '[]'::jsonb)
  from cma.missed_callbacks_of(:'tenant_id') m;
\echo -- 3b the anonymous missed calls of the lookback
explain (analyze, buffers)
  select cma.anonymous_missed_calls_of(:'tenant_id', now() - make_interval(days => greatest(0, cma.setting_of(:'tenant_id', 'telephony.callback_lookback_days')::integer)));
\if :has_0009j
\echo -- 3c today's figures (168)
explain (analyze, buffers) select * from cma.inbound_today_live_of(:'tenant_id');
\else
\echo -- 3c needs 168 (addition 0009j): skipped
\endif
\echo -- 3d outbound now
explain (analyze, buffers) select cma.outbound_now();

\echo
\echo ==== 4. Seven more calls each on this connection: the first and seventh of them, the best (ms), and the poll's sum ====
do $$
declare
  v_sql text[] := array[
    $q$select n.*, cma.business_day_end(n.business_date, n.timezone) as day_ends_at, coalesce(se.sessions, 0)::int as sessions, se.session_started_at,
       (select coalesce(cma.setting_of(cma.current_tenant_id(), 'workday.clock_in_again') = 'true', false)) as clock_in_again,
       cma.workday_can_clock_in_again(n.workday_id) as can_clock_in_again
       from cma.team_now() n left join lateral (select count(*) as sessions, max(e.occurred_at) as session_started_at
       from cma.time_event_effective e where e.workday_id = n.workday_id and e.kind = 'start') se on true$q$,
    $q$select is_working, is_productive, is_paid from cma.work_status where status = 'active' order by sort_order, key$q$,
    $q$select * from cma.team_members_now()$q$,
    $q$select * from cma.roster_today()$q$,
    $q$select * from cma.tenant_settings()$q$,
    $q$select cma.inbound_now() as j, cma.outbound_now() as o$q$,
    $q$select exists (select 1 from cma.telephony_number n join cma.integration_connection c on c.tenant_id = n.tenant_id and c.id = n.connection_id where c.status = 'active')
         or exists (select 1 from cma.telephony_call t join cma.integration_connection c on c.tenant_id = t.tenant_id and c.id = t.connection_id where c.status = 'active'),
       exists (select 1 from cma.commerce_store s join cma.integration_connection c on c.tenant_id = s.tenant_id and c.id = s.connection_id where c.status = 'active')$q$,
    $q$select * from cma.follow_up_summary()$q$];
  v_name text[] := array['team now', 'status flags', 'team members', 'roster today', 'settings', 'calls (inbound and outbound now)', 'connections', 'follow-up summary'];
  v_t0 timestamptz; v_ms numeric; v_first numeric; v_seventh numeric; v_best numeric; r record;
  v_sum_first numeric := 0; v_sum_seventh numeric := 0; v_sum_best numeric := 0;
begin
  for i in 1 .. array_length(v_sql, 1) loop
    v_best := null;
    for run in 1 .. 7 loop
      v_t0 := clock_timestamp();
      -- every row and every column fetched, as 131 times a read: a count over the statement would let the planner drop
      -- the stable columns it never reads (the calls statement's two functions) and time nothing
      for r in execute v_sql[i] loop
        null;
      end loop;
      v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 2);
      if run = 1 then v_first := v_ms; end if;
      if run = 7 then v_seventh := v_ms; end if;
      v_best := least(coalesce(v_best, v_ms), v_ms);
    end loop;
    v_sum_first := v_sum_first + v_first; v_sum_seventh := v_sum_seventh + v_seventh; v_sum_best := v_sum_best + v_best;
    raise notice '%: first % ms, seventh % ms, best % ms', rpad(v_name[i], 34), v_first, v_seventh, v_best;
  end loop;
  raise notice '%: first % ms, seventh % ms, best % ms (the budget: 20 ms of database time per poll)', rpad('the poll, summed', 34), v_sum_first, v_sum_seventh, v_sum_best;
end
$$;

rollback;
