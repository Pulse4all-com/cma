-- =============================================================================================
-- 132_perf.sql: addition 0008zr, the fastest Workspace: the reads the census and the time scripts found slow,
-- rewritten to the same answers, and data quality on stored results (backlog CMA-087)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after 128_sources_last_read.sql
-- (0008zq). Rerunnable, forward-only, in one transaction with a lock timeout. Run as your own IAM login, dev first,
-- then prod (before the merge of the web that reads cma.inbound_now() and cma.data_quality_computed_at(): main's web
-- runs unchanged on it, every function it calls keeps its name, arguments and columns), then 133_verify_perf.sql, then
-- the earlier verifies of what this touches again (53, 61, 63, 73, 79, 81, 123; docs/night-2026-11-06/MORNING_RUNBOOK.md).
-- Then the refresh job (web/jobs/refresh-data-quality.mjs, docs/scheduler/deploy-data-quality.sh) with the merge's
-- image: until it runs, every tenant reads the result this migration computes once.
--
-- Measured first (night N06, 5 November 2026, on a local database three times prod's volume, verify/perf-volume-fixture.sql;
-- docs/night-2026-11-06/local-records/before): cma.sources() 2.3 s (prod: 895 ms for 19 connections), the Live board's
-- missed-callbacks poll 1.6 s and its summary 1.9 s (every 10 seconds per viewer), System health's runs 1.3 s, data
-- quality 4.5 s live (prod: 2.1 to 3.5 s), Intake 6.5 s, the Calls report's core 4.5 s per call (three per page), the
-- open tasks 2.7 s and open tickets 2.0 s (the follow-up refresh every minute and Flash's lists). Each had one cause:
--   sources            cma.connection_held_kinds_of asks "does the connection hold a row of this kind" with exists()
--                      over nine big tables; planned once for every connection, the planner expects the first row at
--                      once and scans the table from the start, so a connection that holds none reads the whole table,
--                      nine times, for every connection. Now the question is min(<leading indexed column>) is not null,
--                      which the planner answers from the index in one step whether or not a row exists
--   missed callbacks   a correlated count over the lookback's calls for every listed caller (callers × calls); now one
--                      join grouped per caller. The summary computed the list again; cma.inbound_now_of() computes the
--                      today figures, the list and the summary once, for the web's one statement
--   system health      the 30 days' runs read four times (the latest, the latest succeeded, the latest failed, the day's
--                      counts); now one grouped pass and two lookups per job and connection
--   intake, calls      cma.market_code_of() called once per call, customer, order and record (two lookups each); now
--                      a map of every distinct value once (the pattern of cma.counted_deals_of); the calls' tags read
--                      once per call; now one grouped pass joined
--   open tasks, tickets cma.owner_user_of(), cma.task_market_of() and cma.record_market_of() once per row; now joins
--                      on the same keys and the market map
--   data quality       every check of cma.data_quality_of runs live on every read; now stored per tenant by a refresh
--                      on the 0008s pattern and read from the store (below)
-- Every rewrite answers exactly what it did: 133_verify_perf.sql keeps the previous definition of each function and
-- compares the two row for row on the database it runs in (the volume fixture locally, the seeds, dev's and prod's
-- own data), provoked by a deliberate difference.
--
-- What it adds (data quality on stored results, CMA-087; Decision log, 5 November 2026)
--   setting               data_quality.refresh_minutes (5; 1 to 1440): how old a tenant's stored result may be before
--                         the job computes it again; checked by cma.check_data_quality_setting()
--   permission            data_quality.refresh: the scheduler's system user only, granted to every tenant's scheduler
--                         role here and by cma.ensure_scheduler_user() from now on
--   sync_run              the job refresh_data_quality joins the list, without a connection, through
--                         cma.job_run_start() and cma.job_run_finish()
--   cma.data_quality_snapshot  one row per tenant: computed_at ("Refreshed at", docs/definitions.md), duration_ms, findings
--   cma.data_quality_finding   the findings of the latest refresh, as cma.flash_findings_of gave them live (check, the
--                         record's connection, type and id, the value, the market, where it is fixed); ids and codes only
--   cma.flash_findings_compute_of(tenant)  the live computation (0008zn's cma.flash_findings_of under its new name)
--   cma.refresh_data_quality_of(tenant, wait)  computes the findings once and replaces the tenant's rows in the caller's
--                         transaction; a transaction-level advisory lock per tenant, so a second refresh running at the
--                         same time skips (wait: waits for it instead, for the fallback); skips while the stored result
--                         is younger than data_quality.refresh_minutes (reason fresh); the current tenant only
--   cma.refresh_data_quality()  the job's entry (data_quality.refresh): refreshes the current tenant
--   reads                 cma.data_quality() and cma.data_quality_rows() read the store (and compute it once on demand
--                         when there is none: a new tenant, a missed job); cma.flash_findings_of(tenant) reads the store,
--                         so Flash's data-quality overview, its list, the snapshot take and the watch read it too;
--                         cma.data_quality_computed_at() says when it was computed, for "Refreshed at"
-- The two tables are derived and rewritten by every refresh: row-level security and the grants of
-- cma.setup_tenant_table() but no audit trigger (as 0008s's: a row image per finding per refresh would fill the audit
-- log); each refresh leaves its sync_run row and the snapshot's computed_at.
-- The readers' function cma_read.data_quality_rows() (0007d) keeps computing live for BigQuery and NocoDB: a reader
-- outside the Workspace, unchanged by this addition.
--
-- SQLSTATEs as before: CMA01 no acting user, CMA02 not found, CMA04 invalid, CMA06 not permitted.
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
  if not exists (select 1 from cma.schema_migration where version = '0008zq') then
    raise exception 'addition 0008zq (128_sources_last_read.sql) must run before 0008zr';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Sources: the kinds a connection holds, answered from the indexes
-- ---------------------------------------------------------------------------------------------
-- As 0008zq's (the same tables, the same kinds, the same order), with min() of the first column after
-- (tenant_id, connection_id) in each big table's unique index in place of exists(): the planner answers it with one
-- index step. Every such column is not null, so min() is null exactly when the table holds no row of the connection.
-- The catalog tables (a handful of rows each) keep exists()
create or replace function cma.connection_held_kinds_of(p_tenant_id uuid, p_connection_id uuid)
returns text[]
language sql stable
as $$
  select array_remove(array[
    case when (select min(x.record_type) from cma.crm_record x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id) is not null
           or (select min(x.source_id) from cma.crm_contact x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id) is not null
           or (select min(x.source_id) from cma.crm_call x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id) is not null
           or exists (select 1 from cma.connection_pipeline x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_form x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_call_outcome x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_field x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.writeback_field x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_inbox x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_inbox_channel x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_email_rule x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or (select min(x.source_kind) from cma.email_message x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id) is not null
           or (select min(x.source_id) from cma.email_thread x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id) is not null
           or (select min(x.source_id) from cma.crm_task x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id) is not null
           or exists (select 1 from cma.connection_task_status x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_task_type x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
         then 'crm' end,
    case when (select min(x.source_id) from cma.telephony_call x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id) is not null
           or exists (select 1 from cma.telephony_tag x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.telephony_number x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
         then 'telephony' end,
    case when exists (select 1 from cma.commerce_store x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or (select min(x.source_id) from cma.commerce_customer x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id) is not null
           or (select min(x.source_id) from cma.commerce_order x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id) is not null
         then 'commerce' end], null)
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. System health: the runs of 30 days in one grouped pass
-- ---------------------------------------------------------------------------------------------
-- The same rows and columns as 0008r's, in the same order: per job and connection the latest run (started_at desc, id
-- desc), the latest succeeded finish, the latest failed finish and its code (finished_at desc, id desc), the day's
-- runs and failed runs; the 30 days' runs read once and grouped, the two rows looked up by their instant through
-- sync_run_started_idx
create or replace function cma.system_health_runs()
returns table(
  job text, connection_id uuid,
  last_started_at timestamptz, last_finished_at timestamptz, last_status text, last_error text, last_counts jsonb,
  last_succeeded_at timestamptz, last_failed_at timestamptz, last_failed_error text,
  runs_24h integer, failed_24h integer)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_tenant uuid := cma.current_tenant_id();
  v_agg    jsonb;
  v_bad    jsonb;
begin
  perform cma.assert_permission('tenant.configure');
  -- one pass over the 30 days' runs, grouped, into a variable: a select into may run in parallel, a return query (a
  -- cursor) may not (measured: 140 ms against 1,250 ms on 360,000 runs, night N06); the latest failed run's id from a
  -- second pass over the failed runs alone (an ordered aggregate sorts its whole input: over every run it cost a sort
  -- to disk, over the failed ones, one in a hundred, it costs nothing)
  select coalesce(jsonb_agg(jsonb_build_object('job', a.job, 'connection_id', a.connection_id, 'last_started', a.last_started,
                                               'ok_at', a.ok_at, 'runs', a.runs, 'failed', a.failed)), '[]'::jsonb)
    into v_agg
  from (select r.job, r.connection_id,
               max(r.started_at) as last_started,
               max(r.finished_at) filter (where r.status = 'succeeded') as ok_at,
               (count(*) filter (where r.started_at > now() - interval '24 hours'))::integer as runs,
               (count(*) filter (where r.started_at > now() - interval '24 hours' and r.status = 'failed'))::integer as failed
        from cma.sync_run r
        where r.tenant_id = v_tenant and r.started_at > now() - interval '30 days'
        group by 1, 2) a;
  select coalesce(jsonb_object_agg(coalesce(b.connection_id::text, '') || '/' || b.job, b.bad_id), '{}'::jsonb)
    into v_bad
  from (select r.job, r.connection_id, (array_agg(r.id order by r.finished_at desc, r.id desc))[1] as bad_id
        from cma.sync_run r
        where r.tenant_id = v_tenant and r.started_at > now() - interval '30 days' and r.status = 'failed'
        group by 1, 2) b;
  return query
    with agg as (
      select (x ->> 'job') as job, (x ->> 'connection_id')::uuid as connection_id, (x ->> 'last_started')::timestamptz as last_started,
             (x ->> 'ok_at')::timestamptz as ok_at, (v_bad ->> (coalesce(x ->> 'connection_id', '') || '/' || (x ->> 'job')))::uuid as bad_id,
             (x ->> 'runs')::integer as runs, (x ->> 'failed')::integer as failed
      from jsonb_array_elements(v_agg) x)
    select a.job, a.connection_id, l.started_at, l.finished_at, l.status, l.error, l.counts,
           a.ok_at, b.finished_at, b.error, a.runs, a.failed
    from agg a
    -- the latest run (started_at desc, id desc): one index lookup at its instant (sync_run_started_idx)
    cross join lateral (select r.started_at, r.finished_at, r.status, r.error, r.counts
                        from cma.sync_run r
                        where r.tenant_id = v_tenant and r.connection_id is not distinct from a.connection_id and r.job = a.job
                          and r.started_at = a.last_started
                        order by r.id desc limit 1) l
    -- the latest failed run, by its id
    left join cma.sync_run b on b.tenant_id = v_tenant and b.id = a.bad_id
    order by a.job, a.connection_id;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. The Live board's inbound poll: the missed callers in one pass, the three reads in one
-- ---------------------------------------------------------------------------------------------
-- As 0008i's (the same rows, columns and order): the missed calls per caller after the last callback counted by one
-- join grouped per listed call instead of a correlated count per row
create or replace function cma.missed_callbacks_of(p_tenant_id uuid)
returns table (
  call_id                   uuid,
  connection_id             uuid,
  source_id                 text,
  line_ref                  text,
  line_name                 text,
  market                    text,
  reason_code               text,
  reason_label              text,
  started_at                timestamptz,
  missed_count              integer,
  waiting_seconds           integer,
  waiting_business_seconds  integer
)
language sql stable
as $$
  with s as (
    select greatest(0, cma.setting_of(t.id, 'telephony.callback_lookback_days')::integer) as lookback
    from cma.tenant t where t.id = p_tenant_id
  ),
  m as materialized (
    select x.*, tc.counterpart_hash as h
    from cma.inbound_calls_of(p_tenant_id, now() - make_interval(days => (select s.lookback from s)), null) x
    join cma.telephony_call tc on tc.tenant_id = p_tenant_id and tc.id = x.call_id
    where x.reason_code is not null and tc.counterpart_hash is not null
  ),
  l as (
    select distinct on (m.h) m.*
    from m where m.needs_callback
    order by m.h, m.started_at desc, m.call_id desc
  ),
  k as (
    select l.*, cb.next_callback_at, cb.last_callback_at
    from l
    cross join lateral (
      select max(o.started_at) filter (where o.started_at > l.started_at) as next_callback_at,
             max(o.started_at) filter (where o.started_at < l.started_at) as last_callback_at
      from cma.telephony_call o
      where o.tenant_id = p_tenant_id and o.counterpart_hash = l.h and o.source_deleted_at is null
        and (o.direction = 'outbound' or (o.direction = 'inbound' and o.answered_at is not null))
    ) cb
    where cb.next_callback_at is null
  ),
  n as (
    select k.call_id, count(m.call_id)::integer as missed
    from k
    left join m on m.h = k.h and (k.last_callback_at is null or m.started_at > k.last_callback_at)
    group by k.call_id
  )
  select k.call_id, k.connection_id, k.source_id, k.line_ref, k.line_name, k.market, k.reason_code, k.reason_label,
         k.started_at,
         n.missed,
         greatest(0, floor(extract(epoch from now() - k.started_at)))::integer,
         cma.business_seconds_of(p_tenant_id, nullif(k.market, 'unknown'), k.started_at, now())
  from k
  join n on n.call_id = k.call_id
  order by k.started_at, k.source_id
$$;

-- The Live board's inbound reads in one call (monitoring.live): today's figures, the missed callers and the summary,
-- the list computed once. The web reads this in one statement (web/src/lib/data/postgres.ts getInboundNow); the three
-- functions it read before stay as they are for the API's other callers
create or replace function cma.inbound_now()
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_list   jsonb;
begin
  perform cma.assert_permission('monitoring.live');
  select coalesce(jsonb_agg(to_jsonb(m) || jsonb_build_object('record_url', cma.record_url(m.connection_id, 'call', m.source_id)) order by m.started_at, m.source_id), '[]'::jsonb)
    into v_list
  from cma.missed_callbacks_of(v_tenant) m;
  return jsonb_build_object(
    'today', (select to_jsonb(x) from cma.inbound_today_of(v_tenant) x),
    'callbacks', v_list,
    'summary', (select jsonb_build_object('listed', jsonb_array_length(v_list),
                                          'anonymous_count', (select count(*)::integer
                                                              from cma.inbound_calls_of(v_tenant, now() - make_interval(days => s.lookback), null) x
                                                              join cma.telephony_call tc on tc.tenant_id = v_tenant and tc.id = x.call_id
                                                              where x.reason_code is not null and x.needs_callback and tc.counterpart_hash is null),
                                          'lookback_days', s.lookback)
                from (select greatest(0, cma.setting_of(t.id, 'telephony.callback_lookback_days')::integer) as lookback
                      from cma.tenant t where t.id = v_tenant) s));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. The Calls report's core: the tags of the period's calls in one grouped pass
-- ---------------------------------------------------------------------------------------------
-- As 0008zc's (76): the same rows and columns; the current tags grouped per call once and joined, not read per call
create or replace function cma.calls_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz, p_market text, p_line text)
returns table(connection_id uuid, source_system text, direction text, line_key text, line_name text, market text, zone text,
              started_at timestamptz, business_date date, week_start date, local_time time, user_ref text,
              is_answered_inbound boolean, is_connected_outbound boolean, is_conversation boolean, talk_seconds integer,
              tag_refs text[], is_tagged boolean)
language sql stable
as $$
  with s as (
    select t.timezone as tenant_zone,
           greatest(0, cma.setting_of(t.id, 'telephony.connected_min_seconds')::integer) as connected_min
    from cma.tenant t where t.id = p_tenant_id
  ),
  c as (
    -- the tenant's zone and setting as scalar subqueries (evaluated once), never a joined relation: planned with
    -- parameters, a joined one-row relation ends up as the inner side of a loop run once per call (night N06)
    select tc.connection_id, tc.source_system, tc.direction, tc.source_id, tc.started_at, tc.answered_at, tc.talk_seconds,
           tc.user_ref, tc.connection_id::text || ':' || coalesce(tc.number_ref, '') as lk,
           coalesce(n.name, tc.number_ref) as ln, coalesce(m.code, 'unknown') as mk, coalesce(m.time_zone, (select s.tenant_zone from s)) as z,
           (select s.connected_min from s) as connected_min
    from cma.telephony_call tc
    left join cma.telephony_number n
      on n.tenant_id = tc.tenant_id and n.connection_id = tc.connection_id and n.number_ref = tc.number_ref
    left join cma.market m on m.tenant_id = tc.tenant_id and m.code = n.market
    where tc.tenant_id = p_tenant_id
      and tc.source_deleted_at is null
      and tc.started_at is not null
      and coalesce(n.is_counted, true)
      and tc.started_at >= coalesce(p_from, '-infinity'::timestamptz)
      and tc.started_at < coalesce(p_to, 'infinity'::timestamptz)
  ),
  tg as (
    select ct.connection_id, ct.call_source_id, array_agg(ct.tag_ref order by ct.tag_ref) as refs
    from cma.telephony_call_tag ct
    where ct.tenant_id = p_tenant_id and ct.untagged_at is null
    group by ct.connection_id, ct.call_source_id
  )
  select c.connection_id, c.source_system, c.direction, c.lk, c.ln, c.mk, c.z, c.started_at,
         (c.started_at at time zone c.z)::date,
         date_trunc('week', (c.started_at at time zone c.z)::date::timestamp)::date,
         (c.started_at at time zone c.z)::time,
         c.user_ref,
         k.answered_in, k.connected_out, k.answered_in or k.connected_out,
         c.talk_seconds,
         coalesce(tg.refs, '{}'::text[]), tg.refs is not null
  from c
  cross join lateral (
    select c.direction = 'inbound' and c.answered_at is not null as answered_in,
           c.direction = 'outbound' and coalesce(c.talk_seconds >= c.connected_min, false) as connected_out) k
  left join tg on tg.connection_id = c.connection_id and tg.call_source_id = c.source_id
  where (p_market is null or c.mk = p_market)
    and (p_line is null or c.lk = p_line)
$$;

-- As 0008zc's (76): the same rows and columns; the tenant's zone and setting as scalar subqueries, as cma.calls_of
create or replace function cma.inbound_calls_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns table(call_id uuid, connection_id uuid, source_system text, source_id text, line_key text, line_ref text, line_name text,
              market text, zone text, started_at timestamptz, business_date date, local_hour integer, is_answered boolean,
              is_waiting boolean, answer_seconds numeric, reason_code text, reason_label text, needs_callback boolean,
              in_service_level boolean)
language sql stable
as $$
  with s as (
    select t.timezone as tenant_zone,
           greatest(0, cma.setting_of(t.id, 'telephony.waiting_max_minutes')::integer) as waiting_max
    from cma.tenant t where t.id = p_tenant_id
  ),
  c as (
    select tc.*, n.name as n_name, m.code as m_code, coalesce(m.time_zone, (select s.tenant_zone from s)) as z,
           (tc.answered_at is null and tc.ended_at is null
            and tc.started_at >= now() - make_interval(mins => (select s.waiting_max from s))) as waiting
    from cma.telephony_call tc
    left join cma.telephony_number n
      on n.tenant_id = tc.tenant_id and n.connection_id = tc.connection_id and n.number_ref = tc.number_ref
    left join cma.market m on m.tenant_id = tc.tenant_id and m.code = n.market
    where tc.tenant_id = p_tenant_id
      and tc.direction = 'inbound'
      and tc.source_deleted_at is null
      and tc.started_at is not null
      and coalesce(n.is_counted, true)
      and tc.started_at >= coalesce(p_from, '-infinity'::timestamptz)
      and tc.started_at < coalesce(p_to, 'infinity'::timestamptz)
  )
  select c.id, c.connection_id, c.source_system, c.source_id,
         c.connection_id::text || ':' || coalesce(c.number_ref, ''),
         c.number_ref, coalesce(c.n_name, c.number_ref), coalesce(c.m_code, 'unknown'), c.z,
         c.started_at, (c.started_at at time zone c.z)::date, extract(hour from c.started_at at time zone c.z)::integer,
         c.answered_at is not null,
         c.waiting,
         case when c.answered_at is not null then greatest(0, extract(epoch from c.answered_at - c.started_at)) end,
         case when r.unanswered then r.code end,
         case when r.unanswered then coalesce(mr.label, r.code) end,
         case when r.unanswered then coalesce(mr.needs_callback, true) end,
         c.answered_at is not null or (r.unanswered and coalesce(mr.counts_in_service_level, true))
  from c
  cross join lateral (select c.answered_at is null and not c.waiting as unanswered,
                             coalesce(nullif(btrim(c.missed_reason), ''), 'unknown') as code) r
  left join cma.telephony_missed_reason mr
    on mr.tenant_id = c.tenant_id and mr.source_system = c.source_system and mr.code = r.code
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. Intake per day: every market value mapped to its code once
-- ---------------------------------------------------------------------------------------------
-- The tenant's map of every value a record's market, a contact's country, a line's market or a store's market
-- holds, to its catalog code (cma.market_code_of once per distinct value, never per row): the pattern of
-- cma.counted_deals_of (0008y)
create or replace function cma.market_codes_of(p_tenant_id uuid)
returns table (value text, code text)
language sql stable
as $$
  select v.value, cma.market_code_of(p_tenant_id, v.value)
  from (select r.market as value from cma.crm_record r where r.tenant_id = p_tenant_id and r.market is not null
        union
        select k.country from cma.crm_contact k where k.tenant_id = p_tenant_id and k.country is not null
        union
        select n.market from cma.telephony_number n where n.tenant_id = p_tenant_id and n.market is not null
        union
        select st.market from cma.commerce_store st where st.tenant_id = p_tenant_id and st.market is not null) v
$$;

-- As 0008p's (74): the same rows and columns; the market of a record, call, customer or order from the map
create or replace function cma.intake_per_day_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns setof cma.intake_per_day_row
language sql stable
as $$
  with s as (
    select t.timezone as zone,
           greatest(coalesce(p_from, '-infinity'::timestamptz),
                    cma.setting_of(t.id, 'intake.start_date')::date::timestamp at time zone t.timezone) as from_at,
           coalesce(p_to, 'infinity'::timestamptz) as to_at
    from cma.tenant t where t.id = p_tenant_id
  ),
  codes as materialized (
    select * from cma.market_codes_of(p_tenant_id)
  ),
  e as (
    select fs.submitted_at as at, coalesce(cma.market_code_of(p_tenant_id, f.market), 'unknown') as market, 'form' as metric
    from cma.form_submission fs
    join cma.connection_form f
      on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
    where fs.tenant_id = p_tenant_id and f.is_counted and cma.form_is_lead(f.lead_condition, fs.kept_values)
      and fs.submitted_at >= (select s.from_at from s) and fs.submitted_at < (select s.to_at from s)
    union all
    select x.at, coalesce(cr.code, cc.code, 'unknown'), x.metric
    from (select cr.*, cr.source_created_at as at, cr.record_type || '_created' as metric
          from cma.crm_record cr
          union all
          select cr.*, cr.closed_at, cr.record_type || '_closed'
          from cma.crm_record cr where cr.is_closed and cr.closed_at is not null) x
    left join cma.connection_pipeline p
      on p.tenant_id = x.tenant_id and p.connection_id = x.connection_id
     and p.record_type = x.record_type and p.source_pipeline_id = x.pipeline_id
    left join codes cr on cr.value = x.market
    left join cma.crm_contact k on k.tenant_id = x.tenant_id and k.connection_id = x.connection_id and k.source_id = x.contact_source_id
    left join codes cc on cc.value = k.country
    where x.tenant_id = p_tenant_id and x.record_type in ('deal', 'ticket') and x.source_deleted_at is null
      and coalesce(p.is_counted, true) and x.at >= (select s.from_at from s) and x.at < (select s.to_at from s)
    union all
    select tc.started_at, coalesce(nc.code, 'unknown'), m.metric
    from cma.telephony_call tc
    left join cma.telephony_number n
      on n.tenant_id = tc.tenant_id and n.connection_id = tc.connection_id and n.number_ref = tc.number_ref
    left join codes nc on nc.value = n.market
    cross join lateral (
      select case tc.direction when 'inbound' then 'call_in' else 'call_out' end as metric
      union all
      select 'call_tagged'
      where exists (select 1 from cma.telephony_call_tag ct
                    left join cma.telephony_tag tg
                      on tg.tenant_id = ct.tenant_id and tg.connection_id = ct.connection_id and tg.tag_ref = ct.tag_ref
                    where ct.tenant_id = tc.tenant_id and ct.connection_id = tc.connection_id
                      and ct.call_source_id = tc.source_id and ct.untagged_at is null and coalesce(tg.is_counted, true))) m
    where tc.tenant_id = p_tenant_id and tc.source_deleted_at is null and coalesce(n.is_counted, true)
      and tc.started_at >= (select s.from_at from s) and tc.started_at < (select s.to_at from s)
    union all
    select cu.source_created_at, coalesce(sc.code, 'unknown'), 'customer'
    from cma.commerce_customer cu
    left join cma.commerce_store st on st.tenant_id = cu.tenant_id and st.connection_id = cu.connection_id
    left join codes sc on sc.value = st.market
    where cu.tenant_id = p_tenant_id and cu.source_deleted_at is null
      and cu.source_created_at >= (select s.from_at from s) and cu.source_created_at < (select s.to_at from s)
    union all
    select co.source_created_at, coalesce(sc.code, 'unknown'), 'order_' || co.order_kind
    from cma.commerce_order co
    left join cma.commerce_store st on st.tenant_id = co.tenant_id and st.connection_id = co.connection_id
    left join codes sc on sc.value = st.market
    where co.tenant_id = p_tenant_id and co.source_deleted_at is null and not co.is_test and co.cancelled_at is null
      and co.source_created_at >= (select s.from_at from s) and co.source_created_at < (select s.to_at from s)
  )
  select p_tenant_id, (e.at at time zone (select s.zone from s))::date, e.market,
         (count(*) filter (where e.metric = 'form'))::integer,
         (count(*) filter (where e.metric = 'deal_created'))::integer,
         (count(*) filter (where e.metric = 'deal_closed'))::integer,
         (count(*) filter (where e.metric = 'ticket_created'))::integer,
         (count(*) filter (where e.metric = 'ticket_closed'))::integer,
         (count(*) filter (where e.metric = 'call_in'))::integer,
         (count(*) filter (where e.metric = 'call_out'))::integer,
         (count(*) filter (where e.metric = 'call_tagged'))::integer,
         (count(*) filter (where e.metric = 'customer'))::integer,
         (count(*) filter (where e.metric = 'order_first'))::integer,
         (count(*) filter (where e.metric = 'order_repeat'))::integer,
         (count(*) filter (where e.metric = 'order_renewal'))::integer
  from e
  group by 2, 3
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. The open tickets and tasks: owners and markets by joins
-- ---------------------------------------------------------------------------------------------
-- As 0008o's (72): the same rows, columns and order. The owner's person by a join on (system || '_owner', ref) (the
-- external id is unique per tenant and system, as cma.owner_user_of's limit 1 relied on); a ticket's market as
-- cma.record_market_of gives it (its own value, else its contact's country, else unknown), from the market map
create or replace function cma.open_tickets_of(p_tenant_id uuid)
returns setof cma.open_ticket_row
language sql stable
as $$
  with s as (
    select greatest(1, cma.setting_of(p_tenant_id, 'tickets.sla_minutes')::integer) as sla_default,
           least(100, greatest(0, cma.setting_of(p_tenant_id, 'tickets.sla_warning_pct')::integer)) as warn_pct
  ),
  codes as materialized (
    select * from cma.market_codes_of(p_tenant_id)
  ),
  k as (
    select r.id, r.connection_id, r.source_system, r.source_id, r.pipeline_id, coalesce(p.label, r.pipeline_id) as pipeline_label,
           r.stage_id, coalesce(st.label, r.stage_id) as stage_label, r.owner_ref, r.source_created_at,
           coalesce(p.sla_minutes, (select s.sla_default from s)) as sla, (select s.warn_pct from s) as warn_pct, coalesce(cr.code, cc.code, 'unknown') as market,
           ow.user_id as owner_user_id
    from cma.crm_record r
    left join cma.connection_pipeline p
      on p.tenant_id = r.tenant_id and p.connection_id = r.connection_id and p.record_type = r.record_type and p.source_pipeline_id = r.pipeline_id
    left join cma.connection_stage st
      on st.tenant_id = r.tenant_id and st.connection_id = r.connection_id and st.record_type = r.record_type
     and st.source_pipeline_id = r.pipeline_id and st.source_stage_id = r.stage_id
    left join codes cr on cr.value = r.market
    left join cma.crm_contact kc on kc.tenant_id = r.tenant_id and kc.connection_id = r.connection_id and kc.source_id = r.contact_source_id
    left join codes cc on cc.value = kc.country
    left join cma.app_user_external_id ow
      on ow.tenant_id = r.tenant_id and ow.system = r.source_system || '_owner' and ow.external_id = r.owner_ref
    where r.tenant_id = p_tenant_id and r.record_type = 'ticket' and r.source_deleted_at is null
      and not coalesce(r.is_closed, false) and coalesce(p.is_counted, true)
  ),
  m as (
    select k.*, cma.business_seconds_of(p_tenant_id, nullif(k.market, 'unknown'), k.source_created_at, now()) as open_s from k
  )
  select p_tenant_id, m.id, m.connection_id, m.source_id, m.pipeline_id, m.pipeline_label, m.stage_id, m.stage_label,
         m.owner_user_id, m.owner_ref, m.market, m.source_created_at,
         m.open_s, m.sla,
         case when m.open_s is null then 'no_hours'
              when m.open_s >= m.sla * 60 then 'breached'
              when m.open_s * 100 >= m.sla * 60 * m.warn_pct then 'at_risk'
              else 'ok' end,
         case when m.open_s is null then null else m.sla - floor(m.open_s / 60.0)::integer end
  from m
  order by case when m.open_s is null then 1 else 0 end, (m.sla * 60 - m.open_s), m.source_created_at, m.source_id
$$;

-- As 0008o's (72): the same rows, columns and order; the owner by a join, the market as cma.task_market_of gives it
-- (the deal's, else the ticket's, each its own value else its contact's country and never unknown; else the task's
-- contact's country), from the market map
create or replace function cma.open_tasks_of(p_tenant_id uuid)
returns setof cma.open_task_row
language sql stable
as $$
  with s as (
    select t.timezone as zone, (now() at time zone t.timezone)::date as today from cma.tenant t where t.id = p_tenant_id
  ),
  codes as materialized (
    select * from cma.market_codes_of(p_tenant_id)
  )
  select p_tenant_id, k.id, k.connection_id, k.source_id, k.type_ref, coalesce(y.label, k.type_ref), coalesce(y.is_callback, false),
         k.priority_ref, k.status_ref, coalesce(st.label, k.status_ref),
         ow.user_id, k.owner_ref,
         coalesce(nullif(coalesce(dm.code, dcm.code, 'unknown'), 'unknown') ,
                  nullif(coalesce(tm.code, tcm.code, 'unknown'), 'unknown'),
                  kcm.code),
         k.due_at,
         case when k.due_at is null then 'none'
              when (k.due_at at time zone (select s.zone from s))::date < (select s.today from s) then 'overdue'
              when (k.due_at at time zone (select s.zone from s))::date = (select s.today from s) then 'today'
              else 'later' end,
         case when k.deal_source_id is not null then 'deal' when k.ticket_source_id is not null then 'ticket' end,
         coalesce(k.deal_source_id, k.ticket_source_id),
         k.source_created_at
  from cma.crm_task k
  left join cma.connection_task_status st
    on st.tenant_id = k.tenant_id and st.connection_id = k.connection_id and st.status_ref = k.status_ref
  left join cma.connection_task_type y
    on y.tenant_id = k.tenant_id and y.connection_id = k.connection_id and y.type_ref = k.type_ref
  left join cma.app_user_external_id ow
    on ow.tenant_id = k.tenant_id and ow.system = k.source_system || '_owner' and ow.external_id = k.owner_ref
  -- the deal the task belongs to, its own market and its contact's country
  left join cma.crm_record d
    on d.tenant_id = k.tenant_id and d.connection_id = k.connection_id and d.record_type = 'deal' and d.source_id = k.deal_source_id
   and d.source_deleted_at is null
  left join codes dm on dm.value = d.market
  left join cma.crm_contact dc on dc.tenant_id = d.tenant_id and dc.connection_id = d.connection_id and dc.source_id = d.contact_source_id
  left join codes dcm on dcm.value = dc.country
  -- the ticket likewise
  left join cma.crm_record tk
    on tk.tenant_id = k.tenant_id and tk.connection_id = k.connection_id and tk.record_type = 'ticket' and tk.source_id = k.ticket_source_id
   and tk.source_deleted_at is null
  left join codes tm on tm.value = tk.market
  left join cma.crm_contact tc on tc.tenant_id = tk.tenant_id and tc.connection_id = tk.connection_id and tc.source_id = tk.contact_source_id
  left join codes tcm on tcm.value = tc.country
  -- the task's own contact
  left join cma.crm_contact kc on kc.tenant_id = k.tenant_id and kc.connection_id = k.connection_id and kc.source_id = k.contact_source_id
  left join codes kcm on kcm.value = kc.country
  where k.tenant_id = p_tenant_id and k.source_deleted_at is null
    and not coalesce(st.is_done, false) and coalesce(y.is_counted, true)
  order by k.due_at nulls last, k.source_created_at, k.source_id
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. Data quality on stored results (CMA-087): the setting, the permission, the job, the tables
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('data_quality.refresh_minutes', 'integer', null, '5',
     'How old a tenant''s stored data-quality result may be, in minutes (1 to 1440), before the refresh job computes it again; the pages show the result''s Refreshed at')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- Its range, checked beside cma.check_tenant_setting() (0008r's and later branches unchanged)
create or replace function cma.check_data_quality_setting()
returns trigger
language plpgsql
as $$
begin
  if new.key = 'data_quality.refresh_minutes'
     and (case when length(new.value) > 4 then true else new.value::integer not between 1 and 1440 end) then
    raise exception 'Setting % takes a whole number of minutes from 1 to 1440', new.key using errcode = 'CMA04';
  end if;
  return new;
end
$$;
drop trigger if exists check_data_quality_setting on cma.tenant_setting;
create trigger check_data_quality_setting before insert or update on cma.tenant_setting
  for each row execute function cma.check_data_quality_setting();

insert into cma.permission (key, description) values
  ('data_quality.refresh', 'Recompute the stored data-quality result (the scheduler''s system user only; no default role)')
on conflict (key) do update set description = excluded.description;

-- 0005a's scheduler user, now with its four permissions
create or replace function cma.ensure_scheduler_user(p_tenant_id uuid)
returns uuid
language plpgsql
as $$
declare
  v_role uuid;
  v_user uuid;
begin
  insert into cma.app_role (tenant_id, key, name, is_system, is_assignable)
  values (p_tenant_id, 'scheduler', 'Scheduler', true, false)
  on conflict (tenant_id, key) do update set is_assignable = false, is_system = true
  returning id into v_role;
  if v_role is null then
    select id into v_role from cma.app_role where tenant_id = p_tenant_id and key = 'scheduler';
  end if;
  insert into cma.role_permission (tenant_id, role_id, permission_key)
  values (p_tenant_id, v_role, 'workday.close_forgotten'), (p_tenant_id, v_role, 'follow_up.refresh'), (p_tenant_id, v_role, 'flash.snapshot'),
         (p_tenant_id, v_role, 'data_quality.refresh')
  on conflict do nothing;

  insert into cma.app_user (tenant_id, email, display_name, status, kind)
  values (p_tenant_id, 'scheduler@system.invalid', 'Scheduler', 'active', 'system')
  on conflict (tenant_id, email) do update set kind = 'system', status = 'active'
  returning id into v_user;
  if v_user is null then
    select id into v_user from cma.app_user where tenant_id = p_tenant_id and email = 'scheduler@system.invalid';
  end if;
  insert into cma.user_role (tenant_id, user_id, role_id)
  values (p_tenant_id, v_user, v_role)
  on conflict do nothing;
  insert into cma.app_user_external_id (tenant_id, user_id, system, external_id)
  values (p_tenant_id, v_user, 'scheduler', 'scheduler')
  on conflict do nothing;
  return v_user;
end
$$;
revoke execute on function cma.ensure_scheduler_user(uuid) from public;

do $$
declare
  t record;
begin
  for t in select id from cma.tenant loop
    perform cma.ensure_scheduler_user(t.id);
  end loop;
end
$$;

-- sync_run: the job refresh_data_quality joins the list, without a connection (as 0008s and 0008zn)
alter table cma.sync_run drop constraint if exists sync_run_job_check;
alter table cma.sync_run add constraint sync_run_job_check
  check (job in ('backfill', 'reconcile', 'forms_poll', 'subscriptions_check', 'link_calls', 'email_poll', 'close_forgotten_workdays',
                 'refresh_follow_up', 'reviews_poll', 'legacy_call_import', 'assets_import', 'assets_poll', 'subscriptions_poll',
                 'flash_snapshot', 'refresh_data_quality')) not valid;
alter table cma.sync_run validate constraint sync_run_job_check;
alter table cma.sync_run drop constraint if exists sync_run_connection_check;
alter table cma.sync_run add constraint sync_run_connection_check
  check ((connection_id is null) = (job in ('close_forgotten_workdays', 'refresh_follow_up', 'flash_snapshot', 'refresh_data_quality'))) not valid;
alter table cma.sync_run validate constraint sync_run_connection_check;

create or replace function cma.job_permission_of(p_job text)
returns text
language sql immutable
as $$
  select case p_job when 'close_forgotten_workdays' then 'workday.close_forgotten' when 'refresh_follow_up' then 'follow_up.refresh'
                    when 'flash_snapshot' then 'flash.snapshot' when 'refresh_data_quality' then 'data_quality.refresh' end
$$;

-- 0008s's start, its message naming the fourth job
create or replace function cma.job_run_start(p_job text)
returns uuid
language plpgsql
as $$
declare
  v_id uuid;
begin
  if cma.job_permission_of(p_job) is null then
    raise exception 'job must be close_forgotten_workdays, refresh_follow_up, flash_snapshot or refresh_data_quality' using errcode = 'CMA04';
  end if;
  perform cma.assert_permission(cma.job_permission_of(p_job));
  insert into cma.sync_run (tenant_id, connection_id, job, stream, from_at, to_at, started_at)
  values (cma.current_tenant_id(), null, p_job, null, clock_timestamp(), clock_timestamp(), clock_timestamp())
  returning id into v_id;
  return v_id;
end
$$;

create table if not exists cma.data_quality_snapshot (
  tenant_id    uuid not null default cma.current_tenant_id() references cma.tenant (id),
  computed_at  timestamptz not null,
  duration_ms  integer not null,
  findings     integer not null,
  primary key (tenant_id)
);
comment on table cma.data_quality_snapshot is 'When one tenant''s stored data-quality result was computed (addition 0008zr; Refreshed at), how long it took and how many findings it holds. Derived: rewritten by every refresh, not audited';

create table if not exists cma.data_quality_finding (
  tenant_id      uuid not null default cma.current_tenant_id() references cma.tenant (id),
  ord            integer not null,
  check_key      text not null,
  connection_id  uuid,
  object_type    text not null,
  object_id      text not null,
  value          text,
  market         text not null,
  fix_in         text not null,
  fix_adapter    text,
  primary key (tenant_id, ord)
);
create index if not exists data_quality_finding_check_idx on cma.data_quality_finding (tenant_id, check_key, market);
comment on table cma.data_quality_finding is 'The data-quality findings of one tenant as its latest refresh computed them (addition 0008zr): the check, the record''s connection, type and id, the value the check reports, the market, where it is fixed; ids and codes, never customer data. Derived: rewritten by every refresh, not audited';

select cma.setup_tenant_table('cma.data_quality_snapshot');
select cma.setup_tenant_table('cma.data_quality_finding');
-- Derived tables rewritten by every refresh: no audit trigger (see the header)
drop trigger if exists audit on cma.data_quality_snapshot;
drop trigger if exists audit on cma.data_quality_finding;

-- ---------------------------------------------------------------------------------------------
-- 8. The computation, the refresh, the readers
-- ---------------------------------------------------------------------------------------------
-- The live computation: 0008zn's cma.flash_findings_of under its new name, unchanged (every finding of
-- cma.data_quality_of with its market, where it is fixed and that system's adapter)
create or replace function cma.flash_findings_compute_of(p_tenant_id uuid)
returns table (check_key text, connection_id uuid, object_type text, object_id text, value text, market text, fix_in text, fix_adapter text)
language sql stable
as $$
  with f as materialized (
    select q.* from cma.data_quality_of(p_tenant_id) q
  ), c as materialized (
    select ic.id, ic.adapter, coalesce(ic.kind, (cma.connection_held_kinds_of(ic.tenant_id, ic.id))[1]) as kind, ic.status
    from cma.integration_connection ic where ic.tenant_id = p_tenant_id
  ), ka as materialized (
    select distinct on (c.kind) c.kind, c.adapter from c where c.status = 'active' and c.kind is not null order by c.kind, c.id
  ), st as materialized (
    select x.connection_id, x.market from cma.commerce_store x where x.tenant_id = p_tenant_id
  ), sm as materialized (
    select * from cma.flash_subscription_stores_of(p_tenant_id)
  )
  select f.check_key, f.connection_id, f.object_type, f.object_id, f.value,
         coalesce(case f.object_type
                    when 'commerce_customer' then st.market
                    when 'subscription' then sm.market
                    when 'market' then f.object_id
                    when 'device' then (select d.market from cma.device d
                                        where d.tenant_id = p_tenant_id and d.connection_id = f.connection_id and d.source_id = f.object_id)
                    when 'contact' then (select cma.market_code_of(p_tenant_id, k.country) from cma.crm_contact k
                                         where k.tenant_id = p_tenant_id and k.connection_id = f.connection_id and k.source_id = f.object_id)
                    when 'form' then (select cf.market from cma.connection_form cf
                                      where cf.tenant_id = p_tenant_id and cf.connection_id = f.connection_id and cf.source_form_id = f.object_id)
                    when 'review_channel' then (select ch.market from cma.review_channel ch
                                                where ch.tenant_id = p_tenant_id and ch.connection_id = f.connection_id and ch.source_id = f.object_id)
                    when 'deal' then (select coalesce(cma.market_code_of(p_tenant_id, r.market), cma.market_code_of(p_tenant_id, rk.country))
                                      from cma.crm_record r
                                      left join cma.crm_contact rk
                                        on rk.tenant_id = r.tenant_id and rk.connection_id = r.connection_id and rk.source_id = r.contact_source_id
                                      where r.tenant_id = p_tenant_id and r.connection_id = f.connection_id and r.record_type = 'deal'
                                        and r.source_id = f.object_id)
                    when 'ticket' then (select coalesce(cma.market_code_of(p_tenant_id, r.market), cma.market_code_of(p_tenant_id, rk.country))
                                        from cma.crm_record r
                                        left join cma.crm_contact rk
                                          on rk.tenant_id = r.tenant_id and rk.connection_id = r.connection_id and rk.source_id = r.contact_source_id
                                        where r.tenant_id = p_tenant_id and r.connection_id = f.connection_id and r.record_type = 'ticket'
                                          and r.source_id = f.object_id) end, 'unknown'),
         x.fix_in,
         case when x.fix_in = 'cma' then null when c1.kind = x.fix_in then c1.adapter else ka.adapter end
  from f
  cross join lateral (select cma.data_quality_fix_in(f.check_key, f.value) as fix_in) x
  left join c c1 on c1.id = f.connection_id
  left join ka on ka.kind = x.fix_in
  left join st on f.object_type = 'commerce_customer' and st.connection_id = f.connection_id
  left join sm on f.object_type = 'subscription' and sm.connection_id = f.connection_id
$$;
alter function cma.flash_findings_compute_of(uuid) set jit = off;

-- The stored findings, in the shape the live computation gave them: what Flash's overview, list, take and watch read
create or replace function cma.flash_findings_of(p_tenant_id uuid)
returns table (check_key text, connection_id uuid, object_type text, object_id text, value text, market text, fix_in text, fix_adapter text)
language sql stable
as $$
  select f.check_key, f.connection_id, f.object_type, f.object_id, f.value, f.market, f.fix_in, f.fix_adapter
  from cma.data_quality_finding f
  where f.tenant_id = p_tenant_id
  order by f.ord
$$;

-- The advisory lock key of a tenant's refresh
create or replace function cma.data_quality_lock_key(p_tenant_id uuid)
returns bigint
language sql immutable
as $$
  select hashtextextended(p_tenant_id::text || '/data_quality_snapshot', 0)
$$;

-- Computes the findings once and replaces the tenant's rows, in the caller's transaction. A second refresh of the same
-- tenant while one runs skips (refreshed false, reason running); with p_wait it waits for it and then skips when a
-- result has appeared meanwhile (reason present), which is what a read that found none wants. Without p_wait a result
-- younger than data_quality.refresh_minutes is kept (reason fresh): the job runs every minute, the tenant decides the
-- cadence. computed_at is the transaction's time. The current tenant only (CMA06).
create or replace function cma.refresh_data_quality_of(p_tenant_id uuid, p_wait boolean default false)
returns jsonb
language plpgsql
as $$
declare
  v_t0   timestamptz := clock_timestamp();
  v_rows integer;
  v_ms   integer;
  v_age  interval;
begin
  if p_tenant_id is null or p_tenant_id is distinct from cma.current_tenant_id() then
    raise exception 'the data-quality result is refreshed for the current tenant only' using errcode = 'CMA06';
  end if;
  if coalesce(p_wait, false) then
    perform pg_advisory_xact_lock(cma.data_quality_lock_key(p_tenant_id));
    if exists (select 1 from cma.data_quality_snapshot s where s.tenant_id = p_tenant_id) then
      return jsonb_build_object('refreshed', false, 'reason', 'present');
    end if;
  else
    select now() - s.computed_at into v_age from cma.data_quality_snapshot s where s.tenant_id = p_tenant_id;
    if v_age is not null and v_age < make_interval(mins => cma.setting_of(p_tenant_id, 'data_quality.refresh_minutes')::integer) then
      return jsonb_build_object('refreshed', false, 'reason', 'fresh', 'age_seconds', floor(extract(epoch from v_age))::integer);
    end if;
    if not pg_try_advisory_xact_lock(cma.data_quality_lock_key(p_tenant_id)) then
      return jsonb_build_object('refreshed', false, 'reason', 'running');
    end if;
  end if;

  delete from cma.data_quality_finding f where f.tenant_id = p_tenant_id;
  insert into cma.data_quality_finding (tenant_id, ord, check_key, connection_id, object_type, object_id, value, market, fix_in, fix_adapter)
  select p_tenant_id, x.ordinality, x.check_key, x.connection_id, x.object_type, x.object_id, x.value, x.market, x.fix_in, x.fix_adapter
  from cma.flash_findings_compute_of(p_tenant_id) with ordinality x;
  get diagnostics v_rows = row_count;
  v_ms := floor(extract(epoch from clock_timestamp() - v_t0) * 1000)::integer;
  insert into cma.data_quality_snapshot (tenant_id, computed_at, duration_ms, findings)
  values (p_tenant_id, now(), v_ms, v_rows)
  on conflict (tenant_id) do update set computed_at = excluded.computed_at, duration_ms = excluded.duration_ms, findings = excluded.findings;
  return jsonb_build_object('refreshed', true, 'rows', v_rows, 'duration_ms', v_ms);
end
$$;

-- The job's entry: the scheduler's system user (data_quality.refresh) refreshes the current tenant
create or replace function cma.refresh_data_quality()
returns jsonb
language plpgsql
as $$
begin
  perform cma.assert_permission('data_quality.refresh');
  return cma.refresh_data_quality_of(cma.current_tenant_id());
end
$$;

-- The tenant's result computed once on demand when there is none yet (a new tenant, a missed job): the snapshot row
create or replace function cma.data_quality_snapshot_of(p_tenant_id uuid)
returns cma.data_quality_snapshot
language plpgsql
as $$
declare
  s cma.data_quality_snapshot;
begin
  select * into s from cma.data_quality_snapshot x where x.tenant_id = p_tenant_id;
  if not found then
    perform cma.refresh_data_quality_of(p_tenant_id, true);
    select * into s from cma.data_quality_snapshot x where x.tenant_id = p_tenant_id;
  end if;
  return s;
end
$$;

-- When the current tenant's result was computed (Refreshed at), for the pages that show it
create or replace function cma.data_quality_computed_at()
returns timestamptz
language plpgsql
as $$
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team', 'tenant.configure']);
  return (cma.data_quality_snapshot_of(cma.current_tenant_id())).computed_at;
end
$$;

-- As 0008zn's: the same rows, the counts from the stored result (computed once on demand when there is none). No longer
-- stable: the on-demand computation writes
create or replace function cma.data_quality()
returns table (check_key text, description text, total integer)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'tenant.configure']);
  perform cma.data_quality_snapshot_of(v_tenant);
  return query
    with q as materialized (select f.check_key, count(*)::integer as n from cma.data_quality_finding f where f.tenant_id = v_tenant group by 1),
    c as (
      select dc.check_key, dc.sort_order, dc.description from cma.data_quality_checks() dc
      union all
      select ac.check_key, ac.sort_order, ac.description from cma.data_quality_added_checks() ac
      where ac.check_key = 'contact_country_fallback'
        and (exists (select 1 from cma.connection_field cf
                     where cf.tenant_id = v_tenant and cf.entity = 'contact' and cf.field = 'country' and cf.slot > 1)
             or exists (select 1 from q where q.check_key = ac.check_key))
      union all
      select fc.check_key, fc.sort_order, fc.description from cma.data_quality_follow_up_checks() fc
      where (fc.check_key in ('ticket_no_owner', 'ticket_no_market')
             and (cma.follow_up_configured_of(v_tenant) or exists (select 1 from q where q.check_key = fc.check_key)))
         or (fc.check_key = 'crm_task_owner_unlinked'
             and (exists (select 1 from cma.crm_task k where k.tenant_id = v_tenant) or exists (select 1 from q where q.check_key = fc.check_key)))
      union all
      select xc.check_key, xc.sort_order, xc.description from cma.data_quality_forms_checks() xc
      where exists (select 1 from q where q.check_key = xc.check_key)
         or exists (select 1 from cma.connection_form f
                    where f.tenant_id = v_tenant and f.fields_refreshed_at is not null and cardinality(f.kept_fields) > 0)
      union all
      select rc.check_key, rc.sort_order, rc.description from cma.data_quality_reviews_checks() rc
      where cma.reviews_set_up_of(v_tenant) or exists (select 1 from q where q.check_key = rc.check_key)
      union all
      select sc.check_key, sc.sort_order, sc.description from cma.data_quality_assets_checks() sc
      where cma.assets_set_up_of(v_tenant) or exists (select 1 from q where q.check_key = sc.check_key)
      union all
      select fc.check_key, fc.sort_order, fc.description from cma.data_quality_flash_checks() fc
      cross join (select cma.flash_sources_of(v_tenant) as src offset 0) s
      where exists (select 1 from q where q.check_key = fc.check_key)
         or (fc.check_key = 'customer_required_ref_missing' and (s.src -> 'commerce' ->> 'set_up')::boolean
             and cardinality(cma.flash_list_of(cma.setting_of(v_tenant, 'commerce.required_contact_refs'))) > 0)
         or (fc.check_key = 'device_required_ref_missing' and (s.src -> 'assets' ->> 'set_up')::boolean
             and cardinality(cma.flash_list_of(cma.setting_of(v_tenant, 'assets.required_refs'))) > 0)
         or (fc.check_key = 'subscription_customer_unmatched' and (s.src -> 'subscriptions' ->> 'set_up')::boolean)
         or (fc.check_key in ('active_subscription_without_device', 'device_subscription_ref_unknown', 'field_device_on_ended_subscription')
             and (s.src -> 'subscriptions' ->> 'set_up')::boolean and (s.src -> 'assets' ->> 'set_up')::boolean)
    )
    select c.check_key, c.description,
           case when c.check_key = 'writeback_parked' and to_regclass('cma.outbox_action') is null then null
                else coalesce((select q.n from q where q.check_key = c.check_key), 0) end
    from c
    order by c.sort_order;
end
$$;

-- As 0008zn's: the same rows, from the stored result (computed once on demand when there is none); no longer stable
create or replace function cma.data_quality_rows(p_check text, p_market text default null, p_limit integer default 500, p_offset integer default 0)
returns jsonb
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'tenant.configure']);
  if p_check is null or not exists (select 1 from cma.data_quality_catalog() c where c.check_key = p_check) then
    raise exception 'check % is no data-quality check', p_check using errcode = 'CMA04';
  end if;
  perform cma.assert_flash_params(p_market, null, null, null, cma.tenant_today_of(v_tenant));
  if p_limit is null or p_limit not between 1 and cma.setting_of(v_tenant, 'flash.file_max_rows')::integer
     or p_offset is null or p_offset not between 0 and 100000000 then
    raise exception 'a list reads 1 to % rows from an offset of 0 or more', cma.setting_of(v_tenant, 'flash.file_max_rows') using errcode = 'CMA04';
  end if;
  perform cma.data_quality_snapshot_of(v_tenant);
  return jsonb_build_object('check', p_check, 'market', p_market, 'limit', p_limit, 'offset', p_offset,
                            'description', (select c.description from cma.data_quality_catalog() c where c.check_key = p_check),
                            'computed_at', (select s.computed_at from cma.data_quality_snapshot s where s.tenant_id = v_tenant))
         || cma.flash_rows_of(v_tenant, 'data_quality', jsonb_strip_nulls(jsonb_build_object('check', p_check, 'market', p_market)),
                              'object_id', false, p_limit, p_offset, null, null);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 8a. Plan settings: the set functions planned with their actual bounds
-- ---------------------------------------------------------------------------------------------
-- A SQL function with a configuration setting is not inlined into its caller: its arguments are then planned as
-- parameters of their own statement instead of as the caller's expressions. Measured under the application role (night
-- N06, 5 November 2026, three times prod's volume): cma.inbound_calls_of inlined into cma.missed_callbacks_of scanned
-- every telephony call (1,116 ms), as a statement of its own it used telephony_call_started_idx (180 ms); cma.intake_per_day_of
-- 3,012 ms inlined, 898 ms on its own; cma.open_tasks_of 1,477 ms, 236 ms. jit off is the setting (0008zn set it on
-- Flash's reads for the same reason it gives: the plans of these reads are large, and compiling them cost more than
-- running them). A later create or replace of one of these functions drops its settings: a script that recreates one
-- repeats its alter (CLAUDE.md, Performance).
alter function cma.calls_of(uuid, timestamptz, timestamptz, text, text) set jit = off;
alter function cma.calls_figures_of(uuid, date, date, text, text, text, timestamptz) set jit = off;
alter function cma.inbound_calls_of(uuid, timestamptz, timestamptz) set jit = off;
alter function cma.intake_per_day_of(uuid, timestamptz, timestamptz) set jit = off;
alter function cma.open_tasks_of(uuid) set jit = off;
alter function cma.open_tickets_of(uuid) set jit = off;

-- ---------------------------------------------------------------------------------------------
-- 9. Grants, the first result of every tenant, the addition
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.connection_held_kinds_of(uuid,uuid)', 'cma.system_health_runs()', 'cma.missed_callbacks_of(uuid)', 'cma.inbound_now()',
    'cma.calls_of(uuid,timestamptz,timestamptz,text,text)', 'cma.market_codes_of(uuid)', 'cma.intake_per_day_of(uuid,timestamptz,timestamptz)',
    'cma.open_tickets_of(uuid)', 'cma.open_tasks_of(uuid)',
    'cma.flash_findings_compute_of(uuid)', 'cma.flash_findings_of(uuid)', 'cma.data_quality_lock_key(uuid)',
    'cma.refresh_data_quality_of(uuid,boolean)', 'cma.refresh_data_quality()', 'cma.data_quality_snapshot_of(uuid)',
    'cma.data_quality_computed_at()', 'cma.data_quality()', 'cma.data_quality_rows(text,text,integer,integer)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;
revoke execute on function cma.check_data_quality_setting() from public;

-- The first stored result of every active tenant, as the owner, so no page waits for the job's first run
do $$
declare
  t record;
  v_t0 timestamptz;
  v_rows integer;
begin
  for t in select x.id from cma.tenant x where x.status = 'active' order by x.id loop
    v_t0 := clock_timestamp();
    delete from cma.data_quality_finding f where f.tenant_id = t.id;
    insert into cma.data_quality_finding (tenant_id, ord, check_key, connection_id, object_type, object_id, value, market, fix_in, fix_adapter)
    select t.id, x.ordinality, x.check_key, x.connection_id, x.object_type, x.object_id, x.value, x.market, x.fix_in, x.fix_adapter
    from cma.flash_findings_compute_of(t.id) with ordinality x;
    get diagnostics v_rows = row_count;
    insert into cma.data_quality_snapshot (tenant_id, computed_at, duration_ms, findings)
    values (t.id, now(), floor(extract(epoch from clock_timestamp() - v_t0) * 1000)::integer, v_rows)
    on conflict (tenant_id) do update set computed_at = excluded.computed_at, duration_ms = excluded.duration_ms, findings = excluded.findings;
  end loop;
end
$$;

insert into cma.schema_migration (version, description)
values ('0008zr', 'The fastest Workspace (night N06): cma.connection_held_kinds_of answered from the indexes (Sources), cma.system_health_runs in one grouped pass, cma.missed_callbacks_of in one join and cma.inbound_now() for the Live board''s poll, cma.calls_of and cma.intake_per_day_of with the tags and the market codes read once (cma.market_codes_of), cma.open_tickets_of and cma.open_tasks_of by joins, each to the same answers (133 proves it); data quality on stored results (CMA-087): cma.data_quality_snapshot and cma.data_quality_finding refreshed by the job refresh_data_quality (data_quality.refresh, the scheduler''s) when older than data_quality.refresh_minutes, read by cma.data_quality, cma.data_quality_rows and cma.flash_findings_of, with cma.data_quality_computed_at for Refreshed at')
on conflict (version) do nothing;

commit;
reset role;
