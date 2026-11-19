-- =============================================================================================
-- tools/perf/team-now-ab.sql: an A/B timing of cma.team_now(), 134's definition (A) against 200's (B, addition 0009z,
-- the two paid columns), on one connection, in one transaction (Martin's brief, 19 November 2026, PR #297)
-- =============================================================================================
-- Why: on 19 Nov 2026 (16:25 to 16:35 CET) 131 part a and tools/perf/live-board-explain.sql read team now at 20 to 64 ms
-- in prod, against 4 to 9 ms on 16 Nov; reads 200 does not touch were slower too (calls 16 to 17 ms), so the instance was
-- busy. This script measures what the two paid aggregates of 200 add on their own: both definitions on the same
-- connection, the same data and the same now(), interleaved, so contention falls on both alike.
--
-- Measures, writes nothing that stays: one transaction that is always rolled back. Run by Martin in his own terminal, as
-- his own IAM login, against a database where 200_live_paid_today.sql has run:
--
--   cd ~/cma && cma_db prod && psql "$PGCONN" -X -f tools/perf/team-now-ab.sql
--
-- (another tenant with -v tenant_slug=<slug>; the default is pulse4all-subscriptions). The reads run as the application
-- (role cma_app, the tenant in app.tenant_id, acting as the tenant's first active person holding monitoring.live), under
-- row-level security, as the Live board's poll does and as live-board-explain.sql sets up.
--
--   A  pg_temp.team_now_134(): 134's definition of cma.team_now() (134_hours_reads.sql, section 4), as 201 and 135 keep
--      it, with its jit = off
--   B  cma.team_now(): 200's definition, the twenty columns of 134 and the two paid columns last
-- Each is called 6 times untimed (a plpgsql function's statements turn to the generic plan after five calls on a
-- connection, as a pooled connection runs them), then 20 rounds timed, interleaved: A then B in odd rounds, B then A in
-- even ones. Each call fetches every row and every column (the length of each row as text is summed).
--
-- Output: ids, counts and milliseconds only; no person's name is selected or printed (the equality check compares the
-- rows inside the database and prints true or false). The output holds the tenant's and the acting person's ids: a prod
-- output is never committed to records/ before node tools/check-records.mjs records/<dir> passes (CLAUDE.md).
--
-- Reading
--   the twenty columns equal: must be true (B answers what A did, plus two columns)
--   median difference (B - A) <= 3 ms: the paid columns cost little, contention explains the rest of the slow reads of
--     19 Nov; keep 200
--   median difference above 3 ms: propose a cheaper paid computation (for example both sums in one pass over the
--     stretches) as a follow-up in PR #297, with its own A/B
-- =============================================================================================
\set ON_ERROR_STOP on
\pset pager off
\if :{?tenant_slug}
\else
  \set tenant_slug pulse4all-subscriptions
\endif

begin;
set local statement_timeout = '300s';
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
select coalesce((select 'paid_running_since' = any (p.proargnames) from pg_proc p where p.oid = to_regprocedure('cma.team_now()')), false) as has_0009z
\gset
\if :has_0009z
\else
  \echo cma.team_now has no paid columns: 200_live_paid_today.sql has not run here, nothing to compare
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
select :'tenant_id' as tenant_id, :'user_id' as acting_user_id, current_setting('server_version') as server_version,
       (select count(*) from cma.app_user u where u.tenant_id = :'tenant_id' and u.status = 'active' and u.kind = 'person') as active_people,
       (select count(*) from cma.workday w where w.tenant_id = :'tenant_id') as workdays,
       (select count(*) from cma.time_event e where e.tenant_id = :'tenant_id') as time_events;

-- A: 134's definition (134_hours_reads.sql, section 4), kept as 201 and 135 keep it, with 134's setting
create or replace function pg_temp.team_now_134()
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
alter function pg_temp.team_now_134() set jit = off;
grant execute on function pg_temp.team_now_134() to cma_app;

-- One call, every row and column fetched: the number of rows and the summed length of each row as text
create or replace function pg_temp.team_now_ab_call(p_variant text, out n bigint, out ms numeric)
language plpgsql
as $$
declare
  t0 timestamptz;
  v_len bigint;
begin
  t0 := clock_timestamp();
  if p_variant = 'A' then
    select count(*), sum(length(t::text)) into n, v_len from pg_temp.team_now_134() t;
  else
    select count(*), sum(length(t::text)) into n, v_len from cma.team_now() t;
  end if;
  ms := round((extract(epoch from (clock_timestamp() - t0)) * 1000)::numeric, 3);
end
$$;
grant execute on function pg_temp.team_now_ab_call(text) to cma_app;

drop table if exists pg_temp.team_now_ab;
create temporary table team_now_ab (variant text, round integer, ms numeric, n bigint);
grant select, insert on pg_temp.team_now_ab to cma_app;

-- from here on as the application, acting for the tenant
select set_config('app.user_id', :'user_id', true) as acting_user;
set local role cma_app;

\echo
\echo ==== 1. The first twenty columns of B against A, row for row (one instant: the same now()) ====
select (select string_agg(a::text, '|' order by a.o) from (select row_number() over () as o, t.* from pg_temp.team_now_134() t) a)
       is not distinct from
       (select string_agg(b::text, '|' order by b.o)
        from (select row_number() over () as o, t.user_id, t.display_name, t.organisation_key, t.organisation_name, t.timezone,
                     t.business_date, t.workday_id, t.day_status, t.started_at, t.ended_at, t.status_key, t.status_name,
                     t.status_active, t.is_working, t.is_productive, t.is_paid, t.is_billable, t.status_since,
                     t.closed_seconds, t.running_since
              from cma.team_now() t) b) as twenty_columns_equal,
       (select count(*) from pg_temp.team_now_134()) as rows_a,
       (select count(*) from cma.team_now()) as rows_b;

\echo
\echo ==== 2. Warm-up: 6 untimed calls of each, then 20 timed rounds, A B in odd rounds and B A in even ones ====
do $$
declare
  i integer;
  r record;
begin
  for i in 1..6 loop
    perform pg_temp.team_now_ab_call('A');
    perform pg_temp.team_now_ab_call('B');
  end loop;
  for i in 1..20 loop
    if i % 2 = 1 then
      select * into r from pg_temp.team_now_ab_call('A'); insert into pg_temp.team_now_ab values ('A', i, r.ms, r.n);
      select * into r from pg_temp.team_now_ab_call('B'); insert into pg_temp.team_now_ab values ('B', i, r.ms, r.n);
    else
      select * into r from pg_temp.team_now_ab_call('B'); insert into pg_temp.team_now_ab values ('B', i, r.ms, r.n);
      select * into r from pg_temp.team_now_ab_call('A'); insert into pg_temp.team_now_ab values ('A', i, r.ms, r.n);
    end if;
  end loop;
end
$$;

\echo
\echo ==== 3. Per variant (ms): A is 134, B is 200 ====
select variant,
       case variant when 'A' then '134 (without the paid columns)' else '200 (with the paid columns)' end as definition,
       count(*) as calls,
       round(percentile_cont(0.5) within group (order by ms)::numeric, 3) as median_ms,
       round(percentile_cont(0.9) within group (order by ms)::numeric, 3) as p90_ms,
       min(ms) as best_ms,
       max(n) as row_count
from pg_temp.team_now_ab
group by variant
order by variant;

\echo
\echo ==== 4. The median difference, B minus A ====
with m as (
  select percentile_cont(0.5) within group (order by ms) filter (where variant = 'A') as a,
         percentile_cont(0.5) within group (order by ms) filter (where variant = 'B') as b
  from pg_temp.team_now_ab
)
select round((b - a)::numeric, 3) as median_difference_ms,
       round(((b - a) / nullif(a, 0) * 100)::numeric, 1) as median_difference_pct,
       case when b - a <= 3 then 'at most 3 ms: the paid columns cost little, keep 200'
            else 'above 3 ms: propose a cheaper paid computation with its own A/B' end as reading
from m;

\echo
\echo ==== 5. The rounds (ms), for the record ====
select round, max(ms) filter (where variant = 'A') as a_ms, max(ms) filter (where variant = 'B') as b_ms,
       case when round % 2 = 1 then 'A B' else 'B A' end as order_in_round
from pg_temp.team_now_ab
group by round
order by round;

rollback;
