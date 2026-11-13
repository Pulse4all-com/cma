-- =============================================================================================
-- tools/perf/prod-load-breakdown.sql: what the minute jobs cost the database, job by job and tenant by tenant
-- (the prod CPU incident of 11 and 12 November 2026)
-- =============================================================================================
-- Measures, writes nothing that stays. One transaction, always rolled back. Each job step also runs in a subtransaction
-- of its own that is rolled back right after it: its writes and its locks (the refreshes' advisory locks, the rows they
-- delete) are released at once, so steps never see each other's writes. Run by Martin in his own terminal, as his own
-- IAM login, against the database to measure:
--
--   cd ~/cma && cma_db prod && psql "$PGCONN" -X -f tools/perf/prod-load-breakdown.sql > /tmp/prod-load-breakdown.txt 2>&1
--
-- It takes at most about 120 s. No new step starts after budget_s seconds (default 95, -v budget_s=<n>), and the
-- statement timeout stops everything at 118 s. A step skipped by the budget prints "skipped: budget".
--
-- Every tenant with a Scheduler user is measured. The jobs' steps run as the application, as the job runs them:
-- role cma_app, under row-level security, with app.tenant_id and app.user_id set to the tenant's Scheduler user (the
-- web jobs) or Ingest user (the sweep's reads). Each step is run once and timed in its first call on this connection.
-- Because prod is saturated while this runs, a step's milliseconds include waiting for the CPU. The rows read and
-- written are the better measure of work: they do not depend on load.
--
-- Output: tenant slugs, step names, table names, counts, milliseconds, minutes and megabytes only. No id of a record, no
-- name, no number, no hash. A prod output is never committed to records/ before node tools/check-records.mjs
-- records/<dir> passes (CLAUDE.md, Git and release).
--
-- Side effect, harmless: while a step holds a refresh's advisory lock (that step's own milliseconds only), the job's run
-- in that same minute answers "running" for that tenant and skips it. Its log line says WARNING running, and the next
-- minute refreshes.
--
-- Parts
--   0  the server: version, pg_stat_statements present or not, sessions per application now, vacuum running now
--   1  the follow-up items per tenant and kind now; the stored snapshots' age and own duration
--   2  the tables: the 15 most read since the stats reset, the 10 with the most dead rows (with the minutes since
--      their last autovacuum and autoanalyze), and the sizes of the minute jobs' own tables
--   3  the history from sync_run, per tenant and job:
--        3a per day since :since (default 2026-11-06)
--        3b per hour in the window :win_from to :win_to (default 2026-11-11 13:00 to 21:00 UTC, around the CPU step
--           at about 17:00 UTC)
--      Each row gives runs, failed runs, the run's milliseconds (average, p95, max) and the average counts the job
--      recorded: rows; for the follow-up also leads, tickets and tasks; for Flash how many runs recomputed the
--      current take
--   4  the minute jobs' database work, per section and tenant. Each line gives the step, its answer or rows out, ms,
--      rows read (sequential and index fetches), rows written (inserted, updated, deleted), the scans started
--      (sequential and index), and the three tables read most:
--        4F the follow-up refresh: cma.refresh_follow_up() as the job calls it, then its parts (the open leads,
--           tickets and tasks, the courtesy flag)
--        4D the data-quality refresh: cma.refresh_data_quality() as the job calls it (mostly "fresh"), then the
--           computation it runs when due (cma.flash_findings_compute_of)
--        4S the Flash snapshot job: cma.flash_current_refresh() as the job calls it (mostly "fresh"), then each current
--           overview's computation when due (cma.flash_compute_of), the dated take and the pledge take as called
--        4I the ingest sweep's SQL reads (as the Ingest user): cma.link_calls over 2 hours, and per HubSpot connection
--           the records without a contact, the linked contacts the CMA does not hold, and the open email threads (the
--           email poll's open check); per active connection the due events (the sweep's claim, counted, never claimed).
--           The polls' other database work is upserts of what the source sent: that is in part 3's history, not here
--      and per tenant and section, the sum
-- =============================================================================================
\set ON_ERROR_STOP on
\pset pager off
\if :{?budget_s}
\else
  \set budget_s 95
\endif
\if :{?since}
\else
  \set since 2026-11-06
\endif
\if :{?win_from}
\else
  \set win_from '2026-11-11 13:00+00'
\endif
\if :{?win_to}
\else
  \set win_to '2026-11-11 21:00+00'
\endif

begin;
set local statement_timeout = '118s';
set local lock_timeout = '2s';
set local role cma_owner;
select set_config('cma_perf.t0', clock_timestamp()::text, true) as started,
       set_config('cma_perf.budget_s', :'budget_s', true) as budget_s;

\echo
\echo ==== 0. The server ====
select current_setting('server_version') as server_version,
       (select count(*) from pg_extension where extname = 'pg_stat_statements') as pg_stat_statements_installed,
       (select floor(extract(epoch from now() - d.stats_reset) / 3600)::integer from pg_stat_database d where d.datname = current_database())
         as hours_since_stats_reset;
select coalesce(nullif(a.application_name, ''), '(none)') as application, a.state, count(*) as sessions,
       max(floor(extract(epoch from now() - a.xact_start)))::integer as oldest_xact_seconds
from pg_stat_activity a
where a.datname = current_database() and a.pid <> pg_backend_pid()
group by 1, 2 order by 1, 2;
select c.relname as vacuuming_now, p.phase, p.heap_blks_total, p.heap_blks_scanned
from pg_stat_progress_vacuum p join pg_class c on c.oid = p.relid;

\echo
\echo ==== 1. Follow-up items per tenant and kind now; the stored snapshots ====
select t.slug as tenant, i.kind, count(*) as items
from cma.follow_up_item i join cma.tenant t on t.id = i.tenant_id
group by 1, 2 order by 1, 2;
select t.slug as tenant, 'follow_up' as snapshot, floor(extract(epoch from now() - s.computed_at))::integer as age_seconds, s.duration_ms
from cma.follow_up_snapshot s join cma.tenant t on t.id = s.tenant_id
union all
select t.slug, 'data_quality', floor(extract(epoch from now() - s.computed_at))::integer, s.duration_ms
from cma.data_quality_snapshot s join cma.tenant t on t.id = s.tenant_id
union all
select t.slug, 'flash_current ' || c.overview, floor(extract(epoch from now() - max(c.computed_at)))::integer, count(*)::integer
from cma.flash_current_take c join cma.tenant t on t.id = c.tenant_id
group by t.slug, c.overview
order by 1, 2;
\echo (for flash_current the last column is the rows of the take, not a duration)

\echo
\echo ==== 2. The tables ====
\echo -- 2a the 15 most read since the stats reset (cumulative counts)
select s.relname as table_name, s.seq_scan, s.seq_tup_read, coalesce(s.idx_scan, 0) as idx_scan, coalesce(s.idx_tup_fetch, 0) as idx_tup_fetch,
       s.n_tup_ins, s.n_tup_upd, s.n_tup_del, s.n_live_tup, s.n_dead_tup
from pg_stat_user_tables s where s.schemaname = 'cma'
order by s.seq_tup_read + coalesce(s.idx_tup_fetch, 0) desc limit 15;
\echo -- 2b the 10 with the most dead rows, and the minutes since their last vacuum and analyze
select s.relname as table_name, s.n_live_tup, s.n_dead_tup, s.n_mod_since_analyze,
       floor(extract(epoch from now() - s.last_autovacuum) / 60)::integer as min_since_autovacuum,
       floor(extract(epoch from now() - s.last_autoanalyze) / 60)::integer as min_since_autoanalyze,
       s.autovacuum_count, s.autoanalyze_count,
       round(pg_total_relation_size(s.relid) / 1048576.0, 1) as total_mb
from pg_stat_user_tables s where s.schemaname = 'cma'
order by s.n_dead_tup desc limit 10;
\echo -- 2c the tables of the minute jobs: sizes (table and its indexes)
select c.relname as table_name, round(pg_relation_size(c.oid) / 1048576.0, 1) as table_mb,
       round(pg_indexes_size(c.oid) / 1048576.0, 1) as indexes_mb, c.reltuples::bigint as est_rows
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'cma' and c.relkind = 'r'
  and c.relname in ('follow_up_item', 'follow_up_snapshot', 'data_quality_finding', 'data_quality_snapshot', 'flash_current_take',
                    'sync_run', 'ingest_event', 'audit_log', 'call_link')
order by 1;

\echo
\echo ==== 3. History from sync_run ====
\echo -- 3a per day (UTC) since :since
select t.slug as tenant, r.job, (r.started_at at time zone 'UTC')::date as day_utc, count(*) as runs,
       count(*) filter (where r.status = 'failed') as failed,
       round(avg(extract(epoch from r.finished_at - r.started_at) * 1000)) as avg_ms,
       round((percentile_cont(0.95) within group (order by extract(epoch from r.finished_at - r.started_at) * 1000))::numeric) as p95_ms,
       round(max(extract(epoch from r.finished_at - r.started_at) * 1000)) as max_ms,
       round(avg(case when jsonb_typeof(r.counts -> 'rows') = 'number' then (r.counts ->> 'rows')::numeric end)) as avg_rows,
       round(avg(case when jsonb_typeof(r.counts -> 'leads') = 'number' then (r.counts ->> 'leads')::numeric end)) as avg_leads,
       round(avg(case when jsonb_typeof(r.counts -> 'tickets') = 'number' then (r.counts ->> 'tickets')::numeric end)) as avg_tickets,
       round(avg(case when jsonb_typeof(r.counts -> 'tasks') = 'number' then (r.counts ->> 'tasks')::numeric end)) as avg_tasks,
       sum(case when jsonb_typeof(r.counts -> 'current_refreshed') = 'number' then (r.counts ->> 'current_refreshed')::numeric end) as current_refreshed
from cma.tenant t
join lateral (select * from cma.sync_run s where s.tenant_id = t.id and s.started_at >= (:'since')::date and s.finished_at is not null) r on true
group by 1, 2, 3 order by 1, 2, 3;
\echo -- 3b per hour (UTC) from :win_from to :win_to
select t.slug as tenant, r.job, to_char(date_trunc('hour', r.started_at at time zone 'UTC'), 'MM-DD HH24') as hour_utc, count(*) as runs,
       count(*) filter (where r.status = 'failed') as failed,
       round(avg(extract(epoch from r.finished_at - r.started_at) * 1000)) as avg_ms,
       round(max(extract(epoch from r.finished_at - r.started_at) * 1000)) as max_ms,
       round(avg(case when jsonb_typeof(r.counts -> 'rows') = 'number' then (r.counts ->> 'rows')::numeric end)) as avg_rows,
       round(avg(case when jsonb_typeof(r.counts -> 'leads') = 'number' then (r.counts ->> 'leads')::numeric end)) as avg_leads,
       round(avg(case when jsonb_typeof(r.counts -> 'tickets') = 'number' then (r.counts ->> 'tickets')::numeric end)) as avg_tickets,
       round(avg(case when jsonb_typeof(r.counts -> 'tasks') = 'number' then (r.counts ->> 'tasks')::numeric end)) as avg_tasks,
       sum(case when jsonb_typeof(r.counts -> 'current_refreshed') = 'number' then (r.counts ->> 'current_refreshed')::numeric end) as current_refreshed
from cma.tenant t
join lateral (select * from cma.sync_run s where s.tenant_id = t.id and s.started_at >= (:'win_from')::timestamptz
                and s.started_at < (:'win_to')::timestamptz and s.finished_at is not null) r on true
group by 1, 2, 3 order by 1, 2, 3;

\echo
\echo ==== 4. The database work of the minute jobs (one call each, rolled back) ====
\echo step | answer or rows out | ms | rows read | rows written | seq scans | idx scans | most read: table rows
do $$
declare
  v_t0      timestamptz := current_setting('cma_perf.t0')::timestamptz;
  v_budget  numeric := current_setting('cma_perf.budget_s')::numeric;
  v_steps   jsonb := '[]'::jsonb;
  s         jsonb;
  t         record;
  c         record;
  ov        text;
  v_before  jsonb;
  v_after   jsonb;
  v_s0      timestamptz;
  v_ms      numeric;
  v_answer  text;
  v_n       bigint;
  v_err     text;
  r         record;
  v_try     integer;
  v_read    bigint; v_written bigint; v_seq bigint; v_idx bigint; v_top text;
  v_key     text := '';
  v_name    text;
  v_sum_ms  numeric := 0; v_sum_read bigint := 0; v_sum_written bigint := 0;
begin
  -- The steps, in the order they run: the sections first (F, D, S, I), each across the tenants
  for t in
    select te.id as tenant_id, te.slug,
           (select u.id from cma.app_user_external_id x join cma.app_user u on u.tenant_id = x.tenant_id and u.id = x.user_id
             where x.tenant_id = te.id and x.system = 'scheduler' and x.external_id = 'scheduler' and u.status = 'active' limit 1) as sched,
           (select u.id from cma.app_user_external_id x join cma.app_user u on u.tenant_id = x.tenant_id and u.id = x.user_id
             where x.tenant_id = te.id and x.system = 'ingest' and x.external_id = 'ingest' and u.status = 'active' limit 1) as ingest
    from cma.tenant te order by te.slug
  loop
    continue when t.sched is null;
    v_steps := v_steps
      || jsonb_build_object('sec', '1F', 'slug', t.slug, 'tenant', t.tenant_id, 'user', t.sched, 'kind', 'value', 'retry', true,
           'label', 'follow-up: cma.refresh_follow_up() as the job calls it',
           'sql', $q$select concat_ws(' ', case when (r ->> 'refreshed')::boolean then 'refreshed' else 'not refreshed' end, r ->> 'reason',
                     'rows ' || (r ->> 'rows'), 'leads ' || (r ->> 'leads'), 'tickets ' || (r ->> 'tickets'), 'tasks ' || (r ->> 'tasks'),
                     'own ms ' || (r ->> 'duration_ms')) from (select cma.refresh_follow_up() as r) x$q$)
      || jsonb_build_object('sec', '1F', 'slug', t.slug, 'tenant', t.tenant_id, 'user', t.sched, 'kind', 'rows',
           'label', 'follow-up part: cma.open_leads_of', 'sql', 'select * from cma.open_leads_of(cma.current_tenant_id())')
      || jsonb_build_object('sec', '1F', 'slug', t.slug, 'tenant', t.tenant_id, 'user', t.sched, 'kind', 'rows',
           'label', 'follow-up part: cma.open_tickets_of', 'sql', 'select * from cma.open_tickets_of(cma.current_tenant_id())')
      || jsonb_build_object('sec', '1F', 'slug', t.slug, 'tenant', t.tenant_id, 'user', t.sched, 'kind', 'rows',
           'label', 'follow-up part: cma.open_tasks_of', 'sql', 'select * from cma.open_tasks_of(cma.current_tenant_id())')
      || jsonb_build_object('sec', '1F', 'slug', t.slug, 'tenant', t.tenant_id, 'user', t.sched, 'kind', 'value',
           'label', 'follow-up part: cma.courtesy_unreachable_of',
           'sql', $q$select coalesce(cma.courtesy_unreachable_of(cma.current_tenant_id(), now())::text, 'null: courtesy not set up')$q$)
      || jsonb_build_object('sec', '2D', 'slug', t.slug, 'tenant', t.tenant_id, 'user', t.sched, 'kind', 'value', 'retry', true,
           'label', 'data quality: cma.refresh_data_quality() as the job calls it',
           'sql', $q$select concat_ws(' ', case when (r ->> 'refreshed')::boolean then 'refreshed' else 'not refreshed' end, r ->> 'reason',
                     'rows ' || (r ->> 'rows'), 'age s ' || (r ->> 'age_seconds'), 'own ms ' || (r ->> 'duration_ms'))
                     from (select cma.refresh_data_quality() as r) x$q$)
      || jsonb_build_object('sec', '2D', 'slug', t.slug, 'tenant', t.tenant_id, 'user', t.sched, 'kind', 'rows',
           'label', 'data quality when due: cma.flash_findings_compute_of', 'sql', 'select * from cma.flash_findings_compute_of(cma.current_tenant_id())')
      || jsonb_build_object('sec', '3S', 'slug', t.slug, 'tenant', t.tenant_id, 'user', t.sched, 'kind', 'value',
           'label', 'flash: cma.flash_current_refresh() as the job calls it',
           'sql', $q$select (select string_agg(e.key || ' ' || e.value, ', ' order by e.key) from jsonb_each_text(r) e where e.value <> '0')
                     from (select cma.flash_current_refresh(cma.current_tenant_id()) as r) x$q$);
    for ov in select unnest(cma.flash_current_overviews_of(t.tenant_id)) loop
      v_steps := v_steps || jsonb_build_object('sec', '3S', 'slug', t.slug, 'tenant', t.tenant_id, 'user', t.sched, 'kind', 'rows',
           'label', 'flash current take when due: cma.flash_compute_of ' || ov,
           'sql', format('select * from cma.flash_compute_of(cma.current_tenant_id(), %L)', ov));
    end loop;
    v_steps := v_steps
      || jsonb_build_object('sec', '3S', 'slug', t.slug, 'tenant', t.tenant_id, 'user', t.sched, 'kind', 'value',
           'label', 'flash: cma.flash_snapshot_take() as the job calls it',
           'sql', $q$select concat_ws(' ', case when (r ->> 'taken')::boolean then 'taken' else 'not taken' end, r ->> 'reason')
                     from (select cma.flash_snapshot_take(cma.current_tenant_id()) as r) x$q$)
      || jsonb_build_object('sec', '3S', 'slug', t.slug, 'tenant', t.tenant_id, 'user', t.sched, 'kind', 'value',
           'label', 'flash: cma.pledge_snapshot_take() as the job calls it',
           'sql', $q$select r ->> 'answer' from (select cma.pledge_snapshot_take(cma.current_tenant_id()) as r) x$q$);
    if t.ingest is not null then
      v_steps := v_steps || jsonb_build_object('sec', '4I', 'slug', t.slug, 'tenant', t.tenant_id, 'user', t.ingest, 'kind', 'value',
           'label', 'sweep: cma.link_calls over 2 hours (links made)', 'sql', $q$select cma.link_calls(now() - interval '2 hours')::text$q$);
      for c in select ic.id, ic.adapter from cma.integration_connection ic
               where ic.tenant_id = t.tenant_id and ic.status = 'active' order by ic.adapter, ic.id loop
        if c.adapter = 'hubspot' then
          v_steps := v_steps
            || jsonb_build_object('sec', '4I', 'slug', t.slug, 'tenant', t.tenant_id, 'user', t.ingest, 'kind', 'rows',
                 'label', 'sweep hubspot: records without a contact, 1 hour',
                 'sql', format('select * from cma.ingest_records_without_contact(%L::uuid, interval %L)', c.id, '1 hour'))
            || jsonb_build_object('sec', '4I', 'slug', t.slug, 'tenant', t.tenant_id, 'user', t.ingest, 'kind', 'rows',
                 'label', 'sweep hubspot: linked contacts not held, 1 hour',
                 'sql', format($q$with m as (
                         select cu.crm_contact_source_id as id, max(cu.matched_at) as at from cma.commerce_customer cu
                          where cu.tenant_id = cma.current_tenant_id() and cu.crm_connection_id = %1$L::uuid and cu.crm_contact_source_id is not null
                            and cu.source_deleted_at is null and cu.matched_at > now() - interval '1 hour'
                          group by cu.crm_contact_source_id)
                       select m.at from m
                        where not exists (select 1 from cma.crm_contact k where k.tenant_id = cma.current_tenant_id() and k.connection_id = %1$L::uuid
                                            and k.source_id = m.id and k.source_deleted_at is null)
                        order by m.at desc, m.id limit 100$q$, c.id))
            || jsonb_build_object('sec', '4I', 'slug', t.slug, 'tenant', t.tenant_id, 'user', t.ingest, 'kind', 'rows',
                 'label', 'email poll hubspot: open threads (the open check)',
                 'sql', format($q$select 1 from cma.email_thread where tenant_id = cma.current_tenant_id() and connection_id = %L::uuid
                                   and status = 'open' and forgotten_at is null order by source_id limit 2000$q$, c.id));
        end if;
        v_steps := v_steps || jsonb_build_object('sec', '4I', 'slug', t.slug, 'tenant', t.tenant_id, 'user', t.ingest, 'kind', 'value',
             'label', 'sweep ' || c.adapter || ': due events (counted to 10,000, not claimed)',
             'sql', format($q$select count(*)::text from (select 1 from cma.ingest_event ie where ie.tenant_id = cma.current_tenant_id()
                               and ie.connection_id = %L::uuid and ie.status in ('received', 'failed') and ie.next_attempt_at <= now() limit 10000) x$q$, c.id));
      end loop;
    end if;
  end loop;

  -- Run them: sorted by section, then as built (tenant by tenant)
  for s in select e.value from jsonb_array_elements(v_steps) with ordinality e order by e.value ->> 'sec', e.ordinality loop
    if v_key <> (s ->> 'sec') || (s ->> 'slug') then
      if v_key <> '' then
        raise notice '% | sum | % ms | % read | % written', v_name, round(v_sum_ms, 1), v_sum_read, v_sum_written;
      end if;
      v_key := (s ->> 'sec') || (s ->> 'slug');
      v_name := substr(s ->> 'sec', 2) || ' ' || (s ->> 'slug');
      v_sum_ms := 0; v_sum_read := 0; v_sum_written := 0;
      raise notice '---- %', v_name;
    end if;
    if extract(epoch from clock_timestamp() - v_t0) > v_budget then
      raise notice '% | skipped: budget (% s)', s ->> 'label', v_budget;
      continue;
    end if;
    v_try := 0;
    loop
      v_try := v_try + 1;
      select coalesce(jsonb_object_agg(x.relname, jsonb_build_array(x.seq_tup_read, coalesce(x.idx_tup_fetch, 0),
                                       x.n_tup_ins + x.n_tup_upd + x.n_tup_del, x.seq_scan, coalesce(x.idx_scan, 0))), '{}'::jsonb)
        into v_before from pg_stat_xact_user_tables x where x.schemaname = 'cma';
      v_answer := null; v_err := null; v_n := 0;
      begin
        perform set_config('app.tenant_id', s ->> 'tenant', true);
        perform set_config('app.user_id', s ->> 'user', true);
        perform set_config('app.actor_label', 'perf:load-breakdown', true);
        perform set_config('role', 'cma_app', true);
        v_s0 := clock_timestamp();
        if s ->> 'kind' = 'rows' then
          -- every row and every column fetched, as 131 times a read: a count would let the planner drop columns it never reads
          for r in execute s ->> 'sql' loop
            v_n := v_n + 1;
          end loop;
          v_answer := v_n || ' rows';
        else
          execute s ->> 'sql' into v_answer;
        end if;
        v_ms := round(extract(epoch from clock_timestamp() - v_s0) * 1000, 1);
        raise exception 'perf step rolled back' using errcode = 'ZZ001';
      exception
        when sqlstate 'ZZ001' then null;   -- the step's own rollback: its writes and locks released, the role back to cma_owner
        when others then
          v_ms := round(extract(epoch from clock_timestamp() - v_s0) * 1000, 1);
          v_err := sqlstate;
      end;
      exit when v_err is not null or not coalesce((s ->> 'retry')::boolean, false) or v_answer not like '%running%' or v_try >= 3;
      perform pg_sleep(1.5);   -- the job holds this tenant's lock: try again
    end loop;
    select coalesce(jsonb_object_agg(y.relname, jsonb_build_array(y.seq_tup_read, coalesce(y.idx_tup_fetch, 0),
                                     y.n_tup_ins + y.n_tup_upd + y.n_tup_del, y.seq_scan, coalesce(y.idx_scan, 0))), '{}'::jsonb)
      into v_after from pg_stat_xact_user_tables y where y.schemaname = 'cma';
    -- per table, the step's share: after minus before (0: rows read, 1: index fetches, 2: written, 3: seq scans, 4: idx scans)
    with d as (
      select a.key as relname,
             (a.value ->> 0)::bigint - coalesce((v_before -> a.key ->> 0)::bigint, 0)
               + (a.value ->> 1)::bigint - coalesce((v_before -> a.key ->> 1)::bigint, 0) as rd,
             (a.value ->> 2)::bigint - coalesce((v_before -> a.key ->> 2)::bigint, 0) as wr,
             (a.value ->> 3)::bigint - coalesce((v_before -> a.key ->> 3)::bigint, 0) as sq,
             (a.value ->> 4)::bigint - coalesce((v_before -> a.key ->> 4)::bigint, 0) as ix
      from jsonb_each(v_after) a)
    select coalesce(sum(d.rd), 0), coalesce(sum(d.wr), 0), coalesce(sum(d.sq), 0), coalesce(sum(d.ix), 0),
           (select string_agg(e.relname || ' ' || e.rd, ', ' order by e.rd desc) from (select * from d where d.rd > 0 order by d.rd desc limit 3) e)
      into v_read, v_written, v_seq, v_idx, v_top
    from d;
    raise notice '% | % | % ms | % read | % written | % seq | % idx | %',
      s ->> 'label', coalesce('error ' || v_err, left(coalesce(v_answer, 'null'), 120)) || case when v_try > 1 then ' (try ' || v_try || ')' else '' end,
      v_ms, v_read, v_written, v_seq, v_idx, coalesce(v_top, '-');
    v_sum_ms := v_sum_ms + coalesce(v_ms, 0); v_sum_read := v_sum_read + v_read; v_sum_written := v_sum_written + v_written;
  end loop;
  if v_key <> '' then
    raise notice '% | sum | % ms | % read | % written', v_name, round(v_sum_ms, 1), v_sum_read, v_sum_written;
  end if;
  raise notice 'whole script: % s', round(extract(epoch from clock_timestamp() - v_t0), 1);
end
$$;

rollback;
