-- =============================================================================================
-- tools/perf/outbound-explain.sql: where the Live board's Outbound today spends its time (addition 0009h, #260)
-- =============================================================================================
-- Read-only: one read-only transaction that is rolled back; it writes nothing and creates nothing that stays (the
-- prepared statements end with the session). Run by Martin in his own terminal, as his own IAM login, against the
-- database to measure:
--
--   cd ~/cma && cma_db prod && psql "$PGCONN" -X -f tools/perf/outbound-explain.sql > /tmp/outbound-explain-prod.txt 2>&1
--
-- The tenant is picked by slug (psql variable tenant_slug, default pulse4all-subscriptions; another one with
-- -v tenant_slug=<slug>); the reads run as the application (role cma_app, the tenant in app.tenant_id, acting as the
-- tenant's first active person holding monitoring.live), under row-level security, as the Live board's poll does.
-- Output: ids, counts of rows, plans and timings only. No call, number, name or hash is selected or printed: the plans
-- show conditions and constants (the tenant's id, instants, setting values), never a row's content. The two reads'
-- answers are compared and only "same" or "differs" is printed.
--
-- Parts
--   0  context: the tenant and acting user (ids), the functions' settings, row counts that size the problem
--   1  the poll as the board runs it: cma.outbound_now(), twice (the second is the warm one)
--   2  cma.outbound_today_of's body (164) written out as a plain query, calling cma.calls_of: how much of the time is
--      inside cma.calls_of (one Function Scan node) and how much around it
--   3  cma.calls_of's body (152) written out for that window, as a prepared statement with the function's parameters,
--      once with a custom plan and once with the generic plan (a function's statements run on the generic plan after
--      five calls on a pooled connection): what cma.calls_of does inside, node by node
--   4  the direct alternative: today's outbound calls read from cma.telephony_call (counted lines, each call's date in
--      its line's zone, Connected and Conversation by cma.is_connected and cma.is_conversation, the tag meanings by
--      cma.call_not_reached_of's own exists()), without cma.calls_of; custom and generic plan
--   5  whether cma.outbound_today_of and part 4 answer the same figures (same or differs; the figures are not printed)
-- =============================================================================================
\set ON_ERROR_STOP on
-- a query that returns no row leaves its \gset variables unset; the \if blocks below then stop the run
\pset pager off
\if :{?tenant_slug}
\else
  \set tenant_slug pulse4all-subscriptions
\endif

begin transaction read only;
set local statement_timeout = '120s';
set local lock_timeout = '2s';
set local role cma_owner;

\echo
\echo ==== 0. Context ====
select t.id as tenant_id from cma.tenant t where t.slug = :'tenant_slug'
\gset
\if :{?tenant_id}
\else
  \echo no tenant with this slug: nothing measured
  rollback;
  \quit
\endif
-- the tenant in the session before any tenant table is read (row-level security), then its first active person holding
-- monitoring.live, as 131 picks its acting user
select set_config('app.tenant_id', :'tenant_id', true) as tenant;
select u.id as user_id
from cma.app_user u
where u.tenant_id = :'tenant_id' and u.status = 'active' and u.kind = 'person' and cma.has_permission(u.id, 'monitoring.live')
order by u.created_at, u.id limit 1
\gset
\if :{?user_id}
\else
  \echo no active person of this tenant holds monitoring.live: nothing measured
  rollback;
  \quit
\endif
select :'tenant_id' as tenant_id, :'user_id' as acting_user_id, current_setting('server_version') as server_version;

-- the functions as they stand: language, volatility, settings
select p.oid::regprocedure as function, l.lanname as language, p.provolatile as volatility, p.prorows as rows,
       coalesce(array_to_string(p.proconfig, ','), '') as settings
from pg_proc p join pg_language l on l.oid = p.prolang
where p.oid in ('cma.outbound_now()'::regprocedure, 'cma.outbound_today_of(uuid,timestamptz)'::regprocedure,
                'cma.calls_of(uuid,timestamptz,timestamptz,text,text)'::regprocedure,
                'cma.call_not_reached_of(uuid,uuid,text)'::regprocedure)
order by 1;

-- the sizes: the tenant's calls in all and of today's window, its current tags in all, and the planner's own figures
select (select count(*) from cma.telephony_call tc where tc.tenant_id = :'tenant_id') as calls_all,
       (select count(*) from cma.telephony_call tc where tc.tenant_id = :'tenant_id'
          and tc.started_at >= (now() at time zone t.timezone)::date::timestamp at time zone t.timezone) as calls_since_tenant_midnight,
       (select count(*) from cma.telephony_call tc where tc.tenant_id = :'tenant_id' and tc.direction = 'outbound'
          and tc.started_at >= (now() at time zone t.timezone)::date::timestamp at time zone t.timezone) as outbound_since_tenant_midnight,
       (select count(*) from cma.telephony_call_tag ct where ct.tenant_id = :'tenant_id' and ct.untagged_at is null) as current_tags_all,
       (select count(*) from cma.market m where m.tenant_id = :'tenant_id') as markets,
       (select count(distinct m.time_zone) from cma.market m where m.tenant_id = :'tenant_id') as market_zones
from cma.tenant t where t.id = :'tenant_id';
select c.relname, c.reltuples::bigint as planner_rows, c.relpages, s.last_analyze, s.last_autoanalyze
from pg_class c join pg_stat_user_tables s on s.relid = c.oid
where c.oid in ('cma.telephony_call'::regclass, 'cma.telephony_call_tag'::regclass, 'cma.telephony_tag'::regclass, 'cma.telephony_number'::regclass)
order by 1;
select i.indexrelid::regclass as index, pg_get_indexdef(i.indexrelid) as definition, i.indisvalid as valid
from pg_index i
where i.indrelid in ('cma.telephony_call'::regclass, 'cma.telephony_call_tag'::regclass)
order by 1;

-- from here on as the application, acting for the tenant
select set_config('app.user_id', :'user_id', true) as acting_user;
set local role cma_app;
-- cma.calls_of and cma.outbound_today_of run with jit off (their own setting); the written-out queries do the same
set local jit = off;

\echo
\echo ==== 1. The poll as the board runs it: cma.outbound_now(), cold then warm ====
explain (analyze, buffers, settings) select cma.outbound_now();
explain (analyze, buffers, settings) select cma.outbound_now();

\echo
\echo ==== 2. cma.outbound_today_of written out, calling cma.calls_of (164's body) ====
prepare outbound_via_calls_of(uuid, timestamptz) as
  with s as (
    select t.timezone as zone, ($2 at time zone t.timezone)::date as today
    from cma.tenant t where t.id = $1
  ),
  w as (
    select min(s.today::timestamp at time zone z.zone) as from_at, max((s.today + 1)::timestamp at time zone z.zone) as to_at
    from s
    cross join lateral (select s.zone
                        union
                        select m.time_zone from cma.market m where m.tenant_id = $1 and m.time_zone is not null) z
  )
  select (select s.today from s),
         count(*)::integer,
         (count(*) filter (where c.is_connected_outbound))::integer,
         round(100.0 * count(*) filter (where c.is_connected_outbound) / nullif(count(*), 0), 1),
         (count(*) filter (where c.is_conversation))::integer,
         coalesce(sum(c.talk_seconds) filter (where c.is_connected_outbound), 0)::bigint,
         round(avg(c.talk_seconds) filter (where c.is_connected_outbound), 1)
  from cma.calls_of($1, (select w.from_at from w), (select w.to_at from w), null, null) c
  where c.direction = 'outbound'
    and c.business_date = (select s.today from s);
set local plan_cache_mode = force_custom_plan;
explain (analyze, buffers, settings) execute outbound_via_calls_of(:'tenant_id', now());
explain (analyze, buffers, settings) execute outbound_via_calls_of(:'tenant_id', now());

\echo
\echo ==== 3. cma.calls_of written out for the same window (152's body), custom plan then generic plan ====
-- the window outbound_today_of passes, computed once here so the statement takes it as parameters, as the function does
select min(x.today::timestamp at time zone z.zone) as from_at, max((x.today + 1)::timestamp at time zone z.zone) as to_at
from (select t.timezone as zone, (now() at time zone t.timezone)::date as today from cma.tenant t where t.id = :'tenant_id') x
cross join lateral (select x.zone union select m.time_zone from cma.market m where m.tenant_id = :'tenant_id' and m.time_zone is not null) z
\gset
select :'from_at' as window_from, :'to_at' as window_to;
prepare calls_of_body(uuid, timestamptz, timestamptz, text, text) as
  with s as (
    select t.timezone as tenant_zone,
           greatest(0, cma.setting_of(t.id, 'telephony.connected_min_seconds')::integer) as connected_min,
           greatest(0, cma.setting_of(t.id, 'calls.conversation_min_talk_seconds')::integer) as conversation_min
    from cma.tenant t where t.id = $1
  ),
  c as (
    select tc.connection_id, tc.source_system, tc.direction, tc.source_id, tc.started_at, tc.answered_at, tc.talk_seconds,
           tc.user_ref, tc.connection_id::text || ':' || coalesce(tc.number_ref, '') as lk,
           coalesce(n.name, tc.number_ref) as ln, coalesce(m.code, 'unknown') as mk, coalesce(m.time_zone, (select s.tenant_zone from s)) as z,
           (select s.connected_min from s) as connected_min, (select s.conversation_min from s) as conversation_min
    from cma.telephony_call tc
    left join cma.telephony_number n
      on n.tenant_id = tc.tenant_id and n.connection_id = tc.connection_id and n.number_ref = tc.number_ref
    left join cma.market m on m.tenant_id = tc.tenant_id and m.code = n.market
    where tc.tenant_id = $1
      and tc.source_deleted_at is null
      and tc.started_at is not null
      and coalesce(n.is_counted, true)
      and tc.started_at >= coalesce($2, '-infinity'::timestamptz)
      and tc.started_at < coalesce($3, 'infinity'::timestamptz)
    offset 0
  ),
  tg as (
    select ct.connection_id, ct.call_source_id, array_agg(ct.tag_ref order by ct.tag_ref) as refs
    from cma.telephony_call_tag ct
    where ct.tenant_id = $1 and ct.untagged_at is null
    group by ct.connection_id, ct.call_source_id
  )
  select count(*) as calls_returned, count(*) filter (where q.direction = 'outbound') as outbound_returned
  from (
    select c.connection_id, c.source_system, c.direction, c.lk, c.ln, c.mk, c.z, c.started_at,
           (c.started_at at time zone c.z)::date,
           date_trunc('week', (c.started_at at time zone c.z)::date::timestamp)::date,
           (c.started_at at time zone c.z)::time,
           c.user_ref,
           k.answered_in, k.connected_out,
           cma.is_conversation(c.direction, c.answered_at is not null, c.talk_seconds, c.connected_min, c.conversation_min, nr.not_reached),
           c.talk_seconds,
           coalesce(tg.refs, '{}'::text[]), tg.refs is not null
    from c
    cross join lateral (
      select c.direction = 'inbound' and c.answered_at is not null as answered_in,
             cma.is_connected(c.direction, c.answered_at is not null, c.talk_seconds, c.connected_min) as connected_out) k
    left join tg on tg.connection_id = c.connection_id and tg.call_source_id = c.source_id
    cross join lateral (
      select case when tg.refs is null then false
                  else (select x.not_reached from cma.call_not_reached_of($1, c.connection_id, c.source_id) x) end as not_reached) nr
    where ($4 is null or c.mk = $4)
      and ($5 is null or c.lk = $5)
    offset 0
  ) q;
\echo -- custom plan
set local plan_cache_mode = force_custom_plan;
explain (analyze, buffers, settings) execute calls_of_body(:'tenant_id', :'from_at', :'to_at', null, null);
\echo -- generic plan (what a pooled connection runs from the sixth call on)
set local plan_cache_mode = force_generic_plan;
explain (analyze, buffers, settings) execute calls_of_body(:'tenant_id', :'from_at', :'to_at', null, null);

\echo
\echo ==== 4. The direct alternative: today's outbound calls from cma.telephony_call, without cma.calls_of ====
prepare outbound_direct(uuid, timestamptz) as
  with s as (
    select t.timezone as zone, ($2 at time zone t.timezone)::date as today,
           greatest(0, cma.setting_of(t.id, 'telephony.connected_min_seconds')::integer) as connected_min,
           greatest(0, cma.setting_of(t.id, 'calls.conversation_min_talk_seconds')::integer) as conversation_min
    from cma.tenant t where t.id = $1
  ),
  w as (
    select min(s.today::timestamp at time zone z.zone) as from_at, max((s.today + 1)::timestamp at time zone z.zone) as to_at
    from s
    cross join lateral (select s.zone
                        union
                        select m.time_zone from cma.market m where m.tenant_id = $1 and m.time_zone is not null) z
  ),
  c as (
    -- the calls cma.calls_of would return for the window, the outbound ones of the date only: the same counted-lines
    -- rule, the same zone per call, the settings as scalar subqueries
    select tc.connection_id, tc.source_id, tc.answered_at, tc.talk_seconds,
           (select s.connected_min from s) as connected_min, (select s.conversation_min from s) as conversation_min
    from cma.telephony_call tc
    left join cma.telephony_number n
      on n.tenant_id = tc.tenant_id and n.connection_id = tc.connection_id and n.number_ref = tc.number_ref
    left join cma.market m on m.tenant_id = tc.tenant_id and m.code = n.market
    where tc.tenant_id = $1
      and tc.direction = 'outbound'
      and tc.source_deleted_at is null
      and tc.started_at is not null
      and coalesce(n.is_counted, true)
      and tc.started_at >= (select w.from_at from w)
      and tc.started_at < (select w.to_at from w)
      and (tc.started_at at time zone coalesce(m.time_zone, (select s.zone from s)))::date = (select s.today from s)
    offset 0
  )
  select (select s.today from s) as business_date,
         count(*)::integer as attempts,
         (count(*) filter (where k.connected))::integer as connected,
         round(100.0 * count(*) filter (where k.connected) / nullif(count(*), 0), 1) as connected_rate,
         (count(*) filter (where cma.is_conversation('outbound', c.answered_at is not null, c.talk_seconds, c.connected_min,
                                                     c.conversation_min, nr.not_reached)))::integer as conversations,
         coalesce(sum(c.talk_seconds) filter (where k.connected), 0)::bigint as outbound_talk_seconds,
         round(avg(c.talk_seconds) filter (where k.connected), 1) as outbound_talk_avg
  from c
  cross join lateral (
    select cma.is_connected('outbound', c.answered_at is not null, c.talk_seconds, c.connected_min) as connected) k
  -- cma.call_not_reached_of's own exists() (102), written out so the plan shows its index probe per call
  cross join lateral (
    select exists (select 1
                   from cma.telephony_call_tag ct
                   join cma.telephony_tag tg
                     on tg.tenant_id = ct.tenant_id and tg.connection_id = ct.connection_id and tg.tag_ref = ct.tag_ref
                   where ct.tenant_id = $1 and ct.connection_id = c.connection_id and ct.call_source_id = c.source_id
                     and ct.untagged_at is null and cma.tag_meaning_excludes_conversation(tg.meaning)) as not_reached) nr;
\echo -- custom plan
set local plan_cache_mode = force_custom_plan;
explain (analyze, buffers, settings) execute outbound_direct(:'tenant_id', now());
\echo -- generic plan
set local plan_cache_mode = force_generic_plan;
explain (analyze, buffers, settings) execute outbound_direct(:'tenant_id', now());

\echo
\echo ==== 5. The same answer? (the figures themselves are not printed) ====
set local plan_cache_mode = auto;
select o.attempts, o.connected, o.connected_rate, o.conversations, o.outbound_talk_seconds, o.outbound_talk_avg
from cma.outbound_today_of(:'tenant_id', now()) o
\gset f_
execute outbound_direct(:'tenant_id', now())
\gset d_
-- a null (no attempt yet, no connected call yet) leaves its variable unset: compare it as empty
\if :{?f_connected_rate}
\else
  \set f_connected_rate ''
\endif
\if :{?d_connected_rate}
\else
  \set d_connected_rate ''
\endif
\if :{?f_outbound_talk_avg}
\else
  \set f_outbound_talk_avg ''
\endif
\if :{?d_outbound_talk_avg}
\else
  \set d_outbound_talk_avg ''
\endif
select case when :'f_attempts' = :'d_attempts' and :'f_connected' = :'d_connected' and :'f_connected_rate' = :'d_connected_rate'
                 and :'f_conversations' = :'d_conversations' and :'f_outbound_talk_seconds' = :'d_outbound_talk_seconds'
                 and :'f_outbound_talk_avg' = :'d_outbound_talk_avg'
            then 'same' else 'differs' end as direct_read_against_outbound_today_of,
       (:'f_attempts')::integer > 0 as has_attempts_today;

rollback;
