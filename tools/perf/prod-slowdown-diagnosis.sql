-- =============================================================================================
-- tools/perf/prod-slowdown-diagnosis.sql: why prod's reads got 3 to 7 times slower since 9 November 2026 (read-only)
-- =============================================================================================
-- The evidence (131_time_all part a, pulse4all-subscriptions, prod, 8, 9, 14 and 16 November 2026; the last on ef3a304
-- at about 20:20 Amsterdam, with no agents and no other runs):
--   data quality checks            174 -> 179 -> 401 -> 1,198 ms
--   flash: landing                 145 -> 230 -> 361 ->   809 ms
--   installed base: records p.1    284 -> 296 -> 475 -> 1,059 ms
--   system health runs             258 -> 287 -> 700 -> 1,565 ms
--   welcome manager: team hours 31  28 ->  25 ->  89 ->   189 ms
-- Broad and gradual, and before #287 (0009u). Prod: Cloud SQL Enterprise, PostgreSQL 18.6, 1 vCPU, 3.75 GB, HA. The
-- hypotheses this script tells apart: the data outgrew the memory (audit_log, CMA-112; the new tables of 0009p and
-- 0009t), stale statistics or bloat, a growing fixed load of the minute jobs. It measures; it fixes nothing.
--
-- Read-only. SELECTs, EXPLAIN and DO blocks that only read, in one READ ONLY transaction that ends in ROLLBACK; no
-- temporary table, no function created. statement_timeout 60 s per statement, lock_timeout 2 s. The script takes only
-- the shared locks a read takes, held until the ROLLBACK (the size functions take one on every relation they measure):
-- a migration or an index build waits for it, so do not run it while one runs. Its last section proves it wrote
-- nothing: no transaction id was assigned. A read that would compute a missing stored result (cma.data_quality() for a
-- tenant without a snapshot) fails with 25006 instead and says so in its 8a and 8b lines. Sections 0 to 5 read as the
-- login (pg_stat_statements shows other roles' statement texts only to a login holding pg_read_all_stats); 8, 6 and 7
-- as cma_owner (prod-load-breakdown.sql's switch); section 8 runs each read as 131 does: role cma_app under row-level
-- security, app.tenant_id the tenant, app.user_id the tenant's first active person (the oldest) holding the read's
-- permission.
--
-- Order: 0 to 5 (settings and cumulative statistics only, no table read), then 8 (the reads), then 6 and 7, which read
-- sync_run and audit_log through shared_buffers: run before 8 they would warm sync_run (which three of the five reads
-- read) or push the reads' tables out, and fake or hide 8a's memory signal.
--
-- Where and when: prod (cma-prod-pg), outside office hours (after 22:00 Amsterdam), with no other run and no agents
-- working, so section 8's times compare with 131's evening run. As your own IAM login. Terminal, in ~/cma:
--
--   cd ~/cma && cma_db prod && psql "$PGCONN" -X -f tools/perf/prod-slowdown-diagnosis.sql > /tmp/prod-slowdown-diagnosis.txt 2>&1
--
-- Expected: about 30 to 90 s on prod (sections 7 and 8 are most of it), under 3 minutes in any case: section 8 starts
-- no call after budget_s seconds into the run (default 100), section 7 stops counting after audit_budget_s (default
-- 30 s), and a statement that reaches the 60 s statement_timeout in section 7 or 8 ends its own section or read, not the
-- run. Every statement is followed by psql's "Time:" line. The file ends with section 9: wrote_nothing t, an empty list
-- of written tables, and ROLLBACK. An output that ends before section 9 stopped on an error (a timeout or a lock wait in
-- sections 0 to 6): the transaction was rolled back all the same, and the error is the file's last lines.
-- Then, before it goes into records/ (CLAUDE.md, Git and release), Terminal, in ~/cma, the directory named after the
-- day of the run:
--
--   d=records/perf-prod-$(TZ=Europe/Amsterdam date +%F) && mkdir -p $d && cp /tmp/prod-slowdown-diagnosis.txt $d/
--   node tools/check-records.mjs --login "$(gcloud config get-value account 2>/dev/null)" $d
--
-- Expected: records clean: 1 files. When it names a line: replace the operator's login by <operator> (an address that
-- is not the login: leave its rows out, with one line saying why), and run it again. Read 8c's plans once before the
-- commit as well: check-records catches addresses, nothing else.
--
-- Options (psql -v name=value): tenant_slug (default pulse4all-subscriptions, the tenant of the evidence: section 8's
-- tenant), budget_s (default 100: section 8 starts no call later in the run), memory_mb (default 3840: the instance's
-- memory, section 2's comparison), nested_ms (default 10:
-- section 8c prints the plan of every statement inside the reads that takes at least this long), audit_budget_s
-- (default 30), audit_count_max (default 5000000: section 7 counts audit_log's rows per day only when the planner
-- estimates at most this many over the 14 days).
--
-- Output: settings, role and table and index names, counts, sizes (MB), milliseconds, block counts, plans. No row of a
-- table is selected. Statement texts (section 5) are pg_stat_statements' normalised texts with every quoted literal
-- replaced by '…' (a dollar-quoted body or a comment is not masked; the cut at 80 characters keeps little of either),
-- every address-like word by <address>, cut to 80 characters; a role that is a person's login reads <login>. Plans
-- show conditions with the ids, dates, codes and setting values the reads pass (the tenant's and the acting person's
-- ids among them), never a row's content. Section 8c's nested plans (auto_explain, when this login may load it) print
-- without their Query Parameters line, but a custom plan folds a function's variable values into its Index Cond and
-- Filter lines: ids, dates and settings for these five reads. A prod output is never committed before
-- node tools/check-records.mjs passes on it.
--
-- Deviations from 131, none in the statements: 131's part a refreshes the tenant's Flash current takes before its reads
-- (a write, rolled back). None of the five reads reads a take (the landing's cma.flash_page does not; 131 times the
-- takes in its own 'cards now' row), so the refresh's only effect on them is cache: it reads the device, subscription,
-- customer and deal tables just before, so 131's first calls start warmer than this script's. Compare 131 (the best of
-- two) with 8a's second call. The reads run in this script's order (131 runs team hours first, then system health,
-- data quality, the landing and the records), and each gets four calls: none reaches the generic plan a plpgsql
-- function's statements turn to after five calls on a connection (CLAUDE.md, Performance).
--
-- Reading guide, section by section (what points where)
--   0 Instance. shared_buffers against the memory (3.75 GB in prod) (Cloud SQL's default is about a third of the memory); hours since the
--     server started (a restart or an HA failover empties the cache) and since the statistics were reset (the window
--     of every cumulative count below); the oldest open transaction and replication slot (an old xmin keeps vacuum from
--     removing dead rows: bloat). work_mem small with temp files in 1: sorts and hashes spill to disk (plans).
--   1 Cache. The database's hit ratio below about 99 % and a read time per block above about 0.1 ms (read_ms_per_block,
--     with track_io_timing on) say blocks come from disk, not from the operating system's cache: MEMORY. pg_stat_io's
--     evictions close to its reads say the buffer pool is churning: MEMORY. The tables and indexes with the most blocks
--     read are the ones that no longer fit; a low hit ratio on one the five reads use (sync_run, device, flash tables,
--     data quality tables, workday tables) ties the slowdown to it. Many temp bytes: PLANS (sorts, hashes over work_mem).
--   2 Sizes. The sum of the 25 largest against shared_buffers and against the memory (memory_mb): when the hot ones of section 1 add
--     up to more than shared_buffers, and the database to more than the memory, the working set no longer fits: MEMORY.
--     audit_log's share is CMA-112's question.
--   3 Maintenance. dead_pct above about 20 % or "vacuum due": BLOAT (more pages per row read). "analyze due" or "never
--     analyzed" on a table a read uses: STATISTICS (estimates off, plans wrong; section 8 then shows estimated rows far
--     from actual ones). all_visible_pct low on a large table: index-only scans visit the heap (bloat and vacuum).
--   4 Access. A table with seq_tup_read far above n_live_tup and rows_per_seq_scan close to its size is read whole,
--     scan after scan: as it grows, every such read grows with it (PLANS, or a missing index). Large indexes never
--     scanned cost writes and memory (candidates, not proof: since the stats reset only).
--   5 Statements. When the minute jobs' statements (refresh_follow_up, refresh_data_quality, flash_current_refresh,
--     flash_snapshot_take, the ingest sweep) hold most of the total time: JOB LOAD. A statement with high shared_read
--     and read_ms: MEMORY. A mean that grew while its rows did not: PLANS or BLOAT. Absent extension: said so.
--   6 Jobs. Per job and day over 10 days: runs per day rising, or the mean and max duration rising: JOB LOAD growing
--     (and the jobs' own reads slowing with the data). Only runs that write sync_run show (a minute job's "fresh" answer
--     writes none; Cloud Run's request log has those).
--   7 audit_log. Its size, rows per day and MB per day (bytes per row from its size): how fast it grows against the
--     memory, and which tables feed it (the last 24 hours).
--   8 Plans. The five reads of the evidence, as 131 calls them. 8a gives each read's first and second call: when the
--     first reads many shared blocks from disk (shared_read, io_read_ms) and the second is much faster with hits only:
--     MEMORY (131 takes the best of two, so its slowdown means even the second call is slow). When both calls are slow
--     with hits only: CPU in the plan (PLANS, more rows, BLOAT). 8b's full plans: estimated against actual rows far
--     apart: STATISTICS; Sort Method external merge or temp blocks: work_mem; seq scans over large tables, loops
--     with many iterations: PLANS; Planning shared read high: catalog or statistics reads. 8c (auto_explain, when the
--     login may load it) gives the plans of the statements inside the reads' functions that take nested_ms or longer:
--     there the slow inner statement shows by name.
--   9 Proof: wrote nothing (no transaction id; the tables written, none), and the script's own run time.
-- =============================================================================================
\set ON_ERROR_STOP on
\pset pager off
\timing on
\if :{?tenant_slug}
\else
  \set tenant_slug pulse4all-subscriptions
\endif
\if :{?nested_ms}
\else
  \set nested_ms 10
\endif
\if :{?audit_budget_s}
\else
  \set audit_budget_s 30
\endif
\if :{?budget_s}
\else
  \set budget_s 100
\endif
\if :{?memory_mb}
\else
  \set memory_mb 3840
\endif
\if :{?audit_count_max}
\else
  \set audit_count_max 5000000
\endif

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;

begin transaction read only;
set local statement_timeout = '60s';
set local lock_timeout = '2s';
select set_config('diag.t0', clock_timestamp()::text, true) as started_at,
       set_config('diag.tenant_slug', :'tenant_slug', true) as tenant_slug,
       set_config('diag.nested_ms', :'nested_ms', true) as nested_ms,
       set_config('diag.audit_budget_s', :'audit_budget_s', true) as audit_budget_s,
       set_config('diag.audit_count_max', :'audit_count_max', true) as audit_count_max,
       set_config('diag.budget_s', :'budget_s', true) as budget_s,
       set_config('diag.memory_mb', :'memory_mb', true) as memory_mb;

\echo
\echo ==== 0. Instance ====
select current_setting('server_version') as server_version,
       round(pg_database_size(current_database()) / 1048576.0) as database_mb,
       round(extract(epoch from now() - pg_postmaster_start_time()) / 3600, 1) as hours_since_server_start,
       (select round(extract(epoch from now() - d.stats_reset) / 3600, 1) from pg_stat_database d where d.datname = current_database())
         as hours_since_stats_reset,
       (select count(*) from pg_extension where extname = 'pg_stat_statements') as pg_stat_statements,
       (select count(*) from pg_extension where extname = 'pg_buffercache') as pg_buffercache;
select s.name, s.setting, coalesce(s.unit, '') as unit,
       case when s.unit = '8kB' then round(s.setting::numeric * 8 / 1024) || ' MB'
            when s.unit = 'kB' then round(s.setting::numeric / 1024) || ' MB' else '' end as in_mb,
       s.source
from pg_settings s
where s.name in ('shared_buffers', 'effective_cache_size', 'work_mem', 'maintenance_work_mem', 'autovacuum_work_mem', 'hash_mem_multiplier',
                 'random_page_cost', 'seq_page_cost', 'effective_io_concurrency', 'jit', 'jit_above_cost', 'jit_inline_above_cost',
                 'jit_optimize_above_cost', 'max_connections', 'max_parallel_workers_per_gather', 'default_statistics_target',
                 'track_io_timing', 'shared_preload_libraries', 'pg_stat_statements.track', 'pg_stat_statements.max', 'huge_pages',
                 'autovacuum', 'autovacuum_naptime', 'autovacuum_max_workers', 'autovacuum_vacuum_threshold',
                 'autovacuum_vacuum_scale_factor', 'autovacuum_vacuum_insert_threshold', 'autovacuum_vacuum_insert_scale_factor',
                 'autovacuum_analyze_threshold', 'autovacuum_analyze_scale_factor', 'autovacuum_vacuum_cost_limit',
                 'autovacuum_vacuum_cost_delay', 'autovacuum_freeze_max_age', 'vacuum_cost_limit', 'idle_in_transaction_session_timeout')
order by s.name;
\echo -- sessions now, and what holds vacuum back (the oldest open transaction, the oldest xmin, replication slots)
select coalesce(nullif(a.application_name, ''), '(none)') as application, a.backend_type, coalesce(a.state, '') as state, count(*) as sessions,
       max(floor(extract(epoch from now() - a.xact_start)))::integer as oldest_xact_s,
       max(age(a.backend_xmin)) as oldest_xmin_age
from pg_stat_activity a
where a.pid <> pg_backend_pid() and (a.datname = current_database() or a.datname is null)
group by 1, 2, 3 order by 2, 1, 3;
select count(r.slot_name) as replication_slots, max(age(r.xmin)) as oldest_slot_xmin_age, max(age(r.catalog_xmin)) as oldest_slot_catalog_xmin_age,
       (select count(*) from pg_prepared_xacts) as prepared_xacts,
       age(d.datfrozenxid) as database_xid_age
from pg_database d left join pg_replication_slots r on true
where d.datname = current_database()
group by d.datfrozenxid;
select c.relname as vacuuming_now, p.phase, p.heap_blks_total, p.heap_blks_scanned
from pg_stat_progress_vacuum p join pg_class c on c.oid = p.relid;

\echo
\echo ==== 1. Cache ====
\echo -- 1a the database since the stats reset (read_ms_per_block: with track_io_timing on, about 0.01 ms is the cache of the operating system, 0.1 ms and more the disk)
select d.blks_hit, d.blks_read,
       round(100.0 * d.blks_hit / nullif(d.blks_hit + d.blks_read, 0), 2) as hit_pct,
       round(d.blk_read_time::numeric) as read_ms_total,
       round((d.blk_read_time / nullif(d.blks_read, 0))::numeric, 3) as read_ms_per_block,
       d.temp_files, round(d.temp_bytes / 1048576.0) as temp_mb,
       d.xact_commit, d.xact_rollback, d.deadlocks, d.conflicts
from pg_stat_database d where d.datname = current_database();
\echo -- 1b shared buffer traffic by kind of process (pg_stat_io; evictions close to reads: the pool is churning)
select i.backend_type, i.object, i.context, i.reads, i.hits,
       round(100.0 * i.hits / nullif(i.hits + i.reads, 0), 2) as hit_pct,
       i.evictions, i.writes, i.extends, round(i.read_time::numeric) as read_ms,
       round((i.read_time / nullif(i.reads, 0))::numeric, 3) as read_ms_per_op
from pg_stat_io i
where coalesce(i.reads, 0) + coalesce(i.hits, 0) + coalesce(i.evictions, 0) > 0
order by i.reads desc nulls last limit 15;
\echo -- 1c the 20 tables with the most blocks read from outside shared_buffers (heap, its indexes, its toast)
select s.schemaname as schema, s.relname as table_name,
       s.heap_blks_read, round(100.0 * s.heap_blks_hit / nullif(s.heap_blks_hit + s.heap_blks_read, 0), 2) as heap_hit_pct,
       coalesce(s.idx_blks_read, 0) as idx_blks_read, round(100.0 * s.idx_blks_hit / nullif(s.idx_blks_hit + s.idx_blks_read, 0), 2) as idx_hit_pct,
       coalesce(s.toast_blks_read, 0) + coalesce(s.tidx_blks_read, 0) as toast_blks_read,
       round(100.0 * (coalesce(s.toast_blks_hit, 0) + coalesce(s.tidx_blks_hit, 0))
             / nullif(coalesce(s.toast_blks_hit, 0) + coalesce(s.tidx_blks_hit, 0) + coalesce(s.toast_blks_read, 0) + coalesce(s.tidx_blks_read, 0), 0), 2)
         as toast_hit_pct,
       round(pg_total_relation_size(s.relid) / 1048576.0, 1) as total_mb
from pg_statio_user_tables s
order by s.heap_blks_read + coalesce(s.idx_blks_read, 0) + coalesce(s.toast_blks_read, 0) + coalesce(s.tidx_blks_read, 0) desc
limit 20;
\echo -- 1d the 20 indexes with the most blocks read from outside shared_buffers
select s.relname as table_name, s.indexrelname as index_name, s.idx_blks_read,
       round(100.0 * s.idx_blks_hit / nullif(s.idx_blks_hit + s.idx_blks_read, 0), 2) as hit_pct,
       round(pg_relation_size(s.indexrelid) / 1048576.0, 1) as index_mb
from pg_statio_user_indexes s
order by s.idx_blks_read desc limit 20;
\echo -- 1e what shared_buffers holds now, the 15 relations with the most buffers (only where pg_buffercache is installed)
do $$
declare
  r record; v_out text := '';
begin
  if not exists (select 1 from pg_extension where extname = 'pg_buffercache') then
    raise notice 'pg_buffercache is not installed: what shared_buffers holds is not shown (sections 1c and 1d give the reads instead)';
    return;
  end if;
  begin
    for r in execute format($q$
      select c.relname, c.relkind, count(*) as buffers, round(count(*) * 8 / 1024.0, 1) as mb,
             round(100.0 * count(*) / (select setting::numeric from pg_settings where name = 'shared_buffers'), 1) as pct_of_pool
      from %I.pg_buffercache b join pg_class c on b.relfilenode = pg_relation_filenode(c.oid)
        and b.reldatabase = (select oid from pg_database where datname = current_database())
      group by c.relname, c.relkind order by 3 desc limit 15$q$,
      (select n.nspname from pg_extension e join pg_namespace n on n.oid = e.extnamespace where e.extname = 'pg_buffercache')) loop
      raise notice '% (%) | % buffers | % MB | % %% of shared_buffers', r.relname, r.relkind, r.buffers, r.mb, r.pct_of_pool;
    end loop;
  exception when others then
    raise notice 'pg_buffercache could not be read by this login (%): not shown', sqlstate;
  end;
end
$$;

\echo
\echo ==== 2. Sizes ====
\echo -- 2a the 25 largest relations (tables and materialised views; their toast and indexes counted with them)
select n.nspname as schema, c.relname as relation, c.relkind as kind, c.reltuples::bigint as est_rows,
       round(pg_relation_size(c.oid) / 1048576.0, 1) as heap_mb,
       round(coalesce(pg_total_relation_size(nullif(c.reltoastrelid, 0)), 0) / 1048576.0, 1) as toast_mb,
       round(pg_indexes_size(c.oid) / 1048576.0, 1) as indexes_mb,
       round(pg_total_relation_size(c.oid) / 1048576.0, 1) as total_mb
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where c.relkind in ('r', 'm', 'p') and n.nspname not in ('pg_catalog', 'information_schema') and n.nspname not like 'pg_toast%'
order by pg_total_relation_size(c.oid) desc
limit 25;
\echo -- 2b their sum, and the database, against shared_buffers and the memory of the instance (memory_mb)
with top as (
  select pg_total_relation_size(c.oid) as total_b, pg_relation_size(c.oid) as heap_b, pg_indexes_size(c.oid) as idx_b
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where c.relkind in ('r', 'm', 'p') and n.nspname not in ('pg_catalog', 'information_schema') and n.nspname not like 'pg_toast%'
  order by pg_total_relation_size(c.oid) desc limit 25),
sb as (select setting::numeric * 8192 as b from pg_settings where name = 'shared_buffers')
select round(sum(top.total_b) / 1048576.0) as top25_total_mb, round(sum(top.heap_b) / 1048576.0) as top25_heap_mb,
       round(sum(top.idx_b) / 1048576.0) as top25_indexes_mb,
       round(pg_database_size(current_database()) / 1048576.0) as database_mb,
       round((select b from sb) / 1048576.0) as shared_buffers_mb,
       round(sum(top.total_b) / (select b from sb), 2) as top25_x_shared_buffers,
       round(pg_database_size(current_database()) / (select b from sb), 2) as database_x_shared_buffers,
       current_setting('diag.memory_mb')::numeric as memory_mb,
       round(pg_database_size(current_database()) / (current_setting('diag.memory_mb')::numeric * 1048576.0), 2) as database_x_memory
from top;

\echo
\echo ==== 3. Maintenance (tables of cma and cma_read with rows; the largest first) ====
\echo (ages in hours; vacuum due / analyze due: past the trigger point of autovacuum, per-table settings included; all_visible_pct: pages marked all-visible)
with t as (
  select s.relid, s.schemaname, s.relname, s.n_live_tup, s.n_dead_tup, s.n_mod_since_analyze, s.n_ins_since_vacuum,
         s.last_vacuum, s.last_autovacuum, s.last_analyze, s.last_autoanalyze,
         s.vacuum_count, s.autovacuum_count, s.analyze_count, s.autoanalyze_count, c.reltuples, c.relpages, c.relallvisible,
         (select o.option_value::numeric from pg_options_to_table(c.reloptions) o where o.option_name = 'autovacuum_vacuum_threshold') as o_vt,
         (select o.option_value::numeric from pg_options_to_table(c.reloptions) o where o.option_name = 'autovacuum_vacuum_scale_factor') as o_vs,
         (select o.option_value::numeric from pg_options_to_table(c.reloptions) o where o.option_name = 'autovacuum_analyze_threshold') as o_at,
         (select o.option_value::numeric from pg_options_to_table(c.reloptions) o where o.option_name = 'autovacuum_analyze_scale_factor') as o_as
  from pg_stat_user_tables s join pg_class c on c.oid = s.relid
  where s.schemaname in ('cma', 'cma_read') and s.n_live_tup + s.n_dead_tup > 0)
select t.relname as table_name, t.n_live_tup as live, t.n_dead_tup as dead,
       round(100.0 * t.n_dead_tup / nullif(t.n_live_tup + t.n_dead_tup, 0), 1) as dead_pct,
       t.n_mod_since_analyze as mod_since_analyze,
       round(100.0 * t.n_mod_since_analyze / nullif(greatest(t.reltuples, 0), 0)::numeric, 1) as mod_pct, t.n_ins_since_vacuum as ins_since_vacuum,
       round(100.0 * t.relallvisible / nullif(t.relpages, 0), 1) as all_visible_pct,
       round(extract(epoch from now() - greatest(t.last_vacuum, t.last_autovacuum)) / 3600, 1) as h_since_vacuum,
       round(extract(epoch from now() - greatest(t.last_analyze, t.last_autoanalyze)) / 3600, 1) as h_since_analyze,
       t.vacuum_count || '/' || t.autovacuum_count as vac_manual_auto, t.analyze_count || '/' || t.autoanalyze_count as an_manual_auto,
       concat_ws(', ',
         case when t.last_analyze is null and t.last_autoanalyze is null then 'never analyzed' end,
         case when t.n_mod_since_analyze > coalesce(t.o_at, current_setting('autovacuum_analyze_threshold')::numeric)
                                           + coalesce(t.o_as, current_setting('autovacuum_analyze_scale_factor')::numeric) * greatest(t.reltuples, 0)
              then 'analyze due' end,
         case when t.n_dead_tup > coalesce(t.o_vt, current_setting('autovacuum_vacuum_threshold')::numeric)
                                  + coalesce(t.o_vs, current_setting('autovacuum_vacuum_scale_factor')::numeric) * greatest(t.reltuples, 0)
              then 'vacuum due' end,
         case when t.n_dead_tup > 0.2 * (t.n_live_tup + t.n_dead_tup) and t.n_live_tup + t.n_dead_tup > 1000 then 'dead over 20 %' end,
         case when t.relpages > 1000 and t.relallvisible < 0.5 * t.relpages then 'half not all-visible' end,
         case when t.reltuples < 0 then 'reltuples unknown' end) as flags,
       round(pg_total_relation_size(t.relid) / 1048576.0, 1) as total_mb
from t
order by pg_total_relation_size(t.relid) desc;

\echo
\echo ==== 4. Access ====
\echo -- 4a the 20 tables read most by sequential scans
select s.schemaname as schema, s.relname as table_name, s.seq_scan, s.seq_tup_read,
       round(s.seq_tup_read::numeric / nullif(s.seq_scan, 0)) as rows_per_seq_scan, s.n_live_tup,
       coalesce(s.idx_scan, 0) as idx_scan, coalesce(s.idx_tup_fetch, 0) as idx_tup_fetch,
       round(extract(epoch from now() - s.last_seq_scan) / 60) as min_since_seq_scan,
       round(pg_relation_size(s.relid) / 1048576.0, 1) as heap_mb
from pg_stat_user_tables s
order by s.seq_tup_read desc limit 20;
\echo -- 4b indexes of 1 MB and more never scanned since the stats reset (unique ones serve a constraint all the same)
select s.schemaname as schema, s.relname as table_name, s.indexrelname as index_name, i.indisunique as is_unique, i.indisprimary as is_primary,
       round(pg_relation_size(s.indexrelid) / 1048576.0, 1) as index_mb
from pg_stat_user_indexes s join pg_index i on i.indexrelid = s.indexrelid
where s.idx_scan = 0 and pg_relation_size(s.indexrelid) >= 1048576
order by pg_relation_size(s.indexrelid) desc;

\echo
\echo ==== 5. Statements (pg_stat_statements, this database) ====
select exists (select 1 from pg_extension where extname = 'pg_stat_statements') as has_pgss,
       coalesce((select n.nspname from pg_extension e join pg_namespace n on n.oid = e.extnamespace where e.extname = 'pg_stat_statements'), 'public')
         as pgss_schema,
       coalesce(current_setting('pg_stat_statements.track', true), 'unknown') as pgss_track
\gset
\if :has_pgss
select has_schema_privilege(:'pgss_schema', 'USAGE') as pgss_usable, pg_has_role('pg_read_all_stats', 'USAGE') as reads_all_stats
\gset
\if :pgss_usable
\else
\echo (the extension lives in a schema this login may not use: read as cma_owner; a statement of another role then shows <insufficient privilege> as its text unless cma_owner holds pg_read_all_stats)
set local role cma_owner;
\endif
select :'pgss_schema' as pgss_schema, :'pgss_track' as pgss_track, :'reads_all_stats' as login_reads_all_stats;
select round(extract(epoch from now() - i.stats_reset) / 3600, 1) as hours_since_pgss_reset, i.dealloc as entries_evicted
from :"pgss_schema".pg_stat_statements_info i;
\echo -- 5a the 25 statements with the most total execution time (texts normalised, literals and addresses masked, cut to 80 characters; share of the total)
select row_number() over (order by p.total_exec_time desc) as n,
       case when r.rolname is null then '?' when r.rolname like '%@%' and r.rolname not like '%.iam' and r.rolname not like '%.iam.gserviceaccount.com'
            then '<login>' else r.rolname end as role,
       p.toplevel, p.calls, round(p.total_exec_time::numeric) as total_ms,
       round((100.0 * p.total_exec_time / nullif(sum(p.total_exec_time) over (), 0))::numeric, 1) as pct,
       round(p.mean_exec_time::numeric, 1) as mean_ms, p.rows,
       p.shared_blks_hit, p.shared_blks_read, round(p.shared_blk_read_time::numeric) as read_ms, p.temp_blks_written,
       left(regexp_replace(regexp_replace(regexp_replace(p.query, '''[^'']*''', '''…''', 'g'),
                                          '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+', '<address>', 'g'), '\s+', ' ', 'g'), 80) as query_80
from :"pgss_schema".pg_stat_statements p left join pg_roles r on r.oid = p.userid
where p.dbid = (select oid from pg_database where datname = current_database())
order by p.total_exec_time desc
limit 25;
reset role;
\else
\echo pg_stat_statements is not installed in this database: no statement statistics (Query insights in the Cloud console holds the same per query)
\endif

\echo
\echo ==== 8. Plans of the five reads, as 131 calls them (run before 6 and 7, which read sync_run and audit_log) ====
set local role cma_owner;
do $$
declare
  v_tenant uuid; v_today date; v_from date; v_to date; v_io text;
begin
  select x.id into v_tenant from cma.tenant x where x.slug = current_setting('diag.tenant_slug') and x.status = 'active';
  if v_tenant is null then
    perform set_config('diag.reads', '[]', true);
    raise notice 'no active tenant with the slug %: section 8 measures nothing', current_setting('diag.tenant_slug');
    return;
  end if;
  perform set_config('app.tenant_id', v_tenant::text, true);
  perform set_config('app.user_id', '', true);
  v_today := cma.tenant_today_of(v_tenant);
  v_from := (date_trunc('month', v_today) - interval '1 month')::date;
  v_to := (date_trunc('month', v_today) - interval '1 day')::date;
  -- I/O timings in the plans, where this login may switch them on for its own transaction
  -- (as the login itself: a superuser-only setting is checked against the current role, and cma_owner is none)
  begin
    perform set_config('role', 'none', true);
    perform set_config('track_io_timing', 'on', true);
    perform set_config('role', 'cma_owner', true);
    v_io := 'on';
  exception when others then
    v_io := current_setting('track_io_timing') || ' (this login may not set it: ' || sqlstate || ')';
  end;
  raise notice 'tenant % (%); today %, previous month % to %; track_io_timing %',
    current_setting('diag.tenant_slug'), v_tenant, v_today, v_from, v_to, v_io;
  -- the stored result data quality's read reads, and its age (the minute job keeps it; a missing one makes the read
  -- compute, which this read-only transaction refuses with 25006)
  raise notice 'data quality stored result, age in minutes: %',
    coalesce((select round(extract(epoch from now() - d.computed_at) / 60) || ' (computed in ' || d.duration_ms || ' ms)'
              from cma.data_quality_snapshot d where d.tenant_id = v_tenant), 'none: the data quality read will fail with 25006');
  -- the five reads: 131's statements (db/131_time_all.sql, part a) with its parameters, and the permissions it picks the acting person by
  perform set_config('diag.reads', json_build_array(
    json_build_object('name', 'data quality: data quality checks', 'perms', array['reports.view', 'tenant.configure'],
                      'sql', 'select * from cma.data_quality()'),
    json_build_object('name', 'flash: landing', 'perms', array['reports.view', 'performance.team'],
                      'sql', format('select cma.flash_page(null, null, %L, %L)', v_from, v_to)),
    json_build_object('name', 'installed base: records first page live', 'perms', array['reports.view', 'performance.team'],
                      'sql', $q$select cma.flash_rows('installed_base', '{}', 'serial', false, 500, 0, null, null, null)$q$),
    json_build_object('name', 'system health: system health runs', 'perms', array['tenant.configure'],
                      'sql', 'select * from cma.system_health_runs()'),
    json_build_object('name', 'welcome manager: team hours 31 days', 'perms', array['workday.team'],
                      'sql', format('select t.* from cma.team_hours(date %L - 31, date %L - 1, null) t order by t.business_date, t.display_name, t.user_id', v_today, v_today))
  )::text, true);
  -- each read's acting person: the tenant's first active person (the oldest) holding any of its permissions (131's t0131_user)
  perform set_config('diag.users', (
    select json_object_agg(x.value ->> 'name', (
             select u.id from cma.app_user u
             where u.tenant_id = v_tenant and u.status = 'active' and u.kind = 'person'
               and exists (select 1 from cma.user_role ur where ur.tenant_id = u.tenant_id and ur.user_id = u.id)
               and exists (select 1 from json_array_elements_text(x.value -> 'perms') p where cma.has_permission(u.id, p))
             order by u.created_at, u.id limit 1))::text
    from json_array_elements(current_setting('diag.reads')::json) x), true);
  perform set_config('app.user_id', '', true);
end
$$;
\echo -- per read, each its own statement (a statement_timeout stops one read, not the section):
\echo --   8a its first and second call: exec ms, planning ms, shared blocks hit and read, read %, temp blocks, io_read_ms (with track_io_timing on), the 4 tables it read most (rows)
\echo --   8b its third call, the full plan: EXPLAIN (ANALYZE, BUFFERS, SETTINGS)
\echo --   8c its fourth call under auto_explain: the statements inside it of nested_ms or longer, with their plans (only where this login may use auto_explain)
select replace($body$
do $do$
declare
  v_i integer := {i};
  v_read json := current_setting('diag.reads')::json -> ({i} - 1);
  v_name text := v_read ->> 'name';
  v_sql text := v_read ->> 'sql';
  v_user uuid := (current_setting('diag.users')::json ->> (v_read ->> 'name'))::uuid;
  j json; v_line text; v_ok boolean := false; v_why text; x record; v_before jsonb; v_top text;
  v_stop timestamptz := current_setting('diag.t0')::timestamptz + make_interval(secs => current_setting('diag.budget_s')::numeric);
begin
  -- a statement_timeout (60 s) ends this read, not the script: query_canceled is caught at the end
  begin
  raise notice '---- %. % (as %): %', v_i, v_name, v_user, v_sql;
  if v_user is null then
    raise notice 'no active person of the tenant holds its permission (%): not run', v_read -> 'perms';
    return;
  end if;
  -- 8a: the first and the second call (no call starts past budget_s seconds into the run)
  for v_call in 1 .. 2 loop
    if clock_timestamp() > v_stop then
      raise notice '8a call % skipped: the run is past budget_s (% s)', v_call, current_setting('diag.budget_s');
      continue;
    end if;
    begin
      select coalesce(jsonb_object_agg(t.relname, jsonb_build_array(t.seq_tup_read + coalesce(t.idx_tup_fetch, 0), t.seq_scan)), '{}'::jsonb)
        into v_before from pg_stat_xact_user_tables t where t.schemaname = 'cma';
      perform set_config('role', 'cma_app', true);
      perform set_config('app.user_id', v_user::text, true);
      execute 'explain (analyze, buffers, format json) ' || v_sql into j;
      perform set_config('role', 'cma_owner', true);
      -- the tables the call read most: rows read (sequential and index fetches) and sequential scans, this call's share
      select string_agg(d.relname || ' ' || d.rd || ' rows' || case when d.sq > 0 then ' (' || d.sq || ' seq scans)' else '' end, ', ' order by d.rd desc)
        into v_top
      from (select t.relname,
                   t.seq_tup_read + coalesce(t.idx_tup_fetch, 0) - coalesce((v_before -> t.relname ->> 0)::bigint, 0) as rd,
                   t.seq_scan - coalesce((v_before -> t.relname ->> 1)::bigint, 0) as sq
            from pg_stat_xact_user_tables t where t.schemaname = 'cma'
            order by 2 desc limit 4) d
      where d.rd > 0;
      raise notice '8a call % | exec % ms | planning % ms | shared hit % | shared read % | read % %% | temp read % | temp written % | io_read_ms % | most read: %', v_call,
        round((j -> 0 ->> 'Execution Time')::numeric, 1), round((j -> 0 ->> 'Planning Time')::numeric, 1),
        j -> 0 -> 'Plan' ->> 'Shared Hit Blocks', j -> 0 -> 'Plan' ->> 'Shared Read Blocks',
        coalesce(round(100.0 * (j -> 0 -> 'Plan' ->> 'Shared Read Blocks')::numeric
                       / nullif((j -> 0 -> 'Plan' ->> 'Shared Hit Blocks')::numeric + (j -> 0 -> 'Plan' ->> 'Shared Read Blocks')::numeric, 0), 1), 0),
        j -> 0 -> 'Plan' ->> 'Temp Read Blocks', j -> 0 -> 'Plan' ->> 'Temp Written Blocks',
        coalesce(round(coalesce(j -> 0 -> 'Plan' ->> 'Shared I/O Read Time', j -> 0 -> 'Plan' ->> 'I/O Read Time')::numeric, 1)::text, '-'),
        coalesce(v_top, '-');
    exception when others then
      perform set_config('role', 'cma_owner', true);
      raise notice '8a call % | error % %', v_call, sqlstate, left(sqlerrm, 80);
    end;
  end loop;
  -- 8b: the full plan
  if clock_timestamp() > v_stop then
    raise notice '8b and 8c skipped: the run is past budget_s (% s)', current_setting('diag.budget_s');
    return;
  end if;
  begin
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_user::text, true);
    for v_line in execute 'explain (analyze, buffers, settings) ' || v_sql loop
      raise notice '8b %', v_line;
    end loop;
    perform set_config('role', 'cma_owner', true);
  exception when others then
    perform set_config('role', 'cma_owner', true);
    raise notice '8b error % %', sqlstate, left(sqlerrm, 80);
  end;
  -- 8c: the nested statements under auto_explain (preloaded, or loaded here where the login may load it; as the login
  -- itself, its settings being superuser-only ones, checked against the current role)
  begin
    perform set_config('role', 'none', true);
    if current_setting('auto_explain.log_min_duration', true) is null then
      execute 'load ''auto_explain''';
    end if;
    perform set_config('auto_explain.log_parameter_max_length', '0', true);
    perform set_config('auto_explain.log_analyze', 'on', true);
    perform set_config('auto_explain.log_buffers', 'on', true);
    perform set_config('auto_explain.log_timing', 'on', true);
    perform set_config('auto_explain.log_nested_statements', 'on', true);
    perform set_config('auto_explain.log_format', 'text', true);
    perform set_config('auto_explain.log_level', 'notice', true);
    perform set_config('auto_explain.log_min_duration', current_setting('diag.nested_ms'), true);
    perform set_config('role', 'cma_owner', true);
    v_ok := true;
  exception when others then
    v_why := sqlstate || ' ' || left(sqlerrm, 80);
  end;
  if v_ok and clock_timestamp() > v_stop then
    raise notice '8c skipped: the run is past budget_s (% s)', current_setting('diag.budget_s');
    perform set_config('role', 'none', true);
    perform set_config('auto_explain.log_min_duration', '-1', true);
    perform set_config('role', 'cma_owner', true);
  elsif not v_ok then
    raise notice '8c auto_explain is not available to this login (%): no nested plans; section 5 names the slow statements inside the functions where pg_stat_statements.track is all (here %)',
      v_why, coalesce(current_setting('pg_stat_statements.track', true), 'unknown');
  else
    begin
      perform set_config('role', 'cma_app', true);
      perform set_config('app.user_id', v_user::text, true);
      for x in execute v_sql loop
        null;
      end loop;
      perform set_config('role', 'cma_owner', true);
    exception when others then
      perform set_config('role', 'cma_owner', true);
      raise notice '8c error % %', sqlstate, left(sqlerrm, 80);
    end;
    perform set_config('role', 'none', true);
    perform set_config('auto_explain.log_min_duration', '-1', true);
    perform set_config('role', 'cma_owner', true);
  end if;
  exception when query_canceled then
    raise notice '% stopped by statement_timeout (%): its later calls are not run', v_name, current_setting('statement_timeout');
  end;
  perform set_config('role', 'cma_owner', true);
  perform set_config('app.user_id', '', true);
end
$do$
$body$, '{i}', i::text)
from generate_series(1, json_array_length(current_setting('diag.reads')::json)) i
\gexec

\echo
\echo ==== 6. Jobs (sync_run, every tenant, the last 10 days by UTC day; runs that finished) ====
set local role cma_owner;
select t.slug as tenant, r.job, (r.started_at at time zone 'UTC')::date as day_utc, count(*) as runs,
       count(*) filter (where r.status = 'failed') as failed,
       round(avg(extract(epoch from r.finished_at - r.started_at) * 1000)) as mean_ms,
       round((percentile_cont(0.95) within group (order by extract(epoch from r.finished_at - r.started_at) * 1000))::numeric) as p95_ms,
       round(max(extract(epoch from r.finished_at - r.started_at) * 1000)) as max_ms,
       round(sum(extract(epoch from r.finished_at - r.started_at)) / 60, 1) as busy_min
from cma.tenant t
join lateral (select s.job, s.started_at, s.finished_at, s.status from cma.sync_run s
              where s.tenant_id = t.id and s.started_at >= date_trunc('day', now() at time zone 'UTC') at time zone 'UTC' - interval '9 days'
                and s.finished_at is not null) r on true
group by 1, 2, 3 order by 1, 2, 3;
\echo -- 6b sync_run itself (every system health read scans its last 30 days)
select c.reltuples::bigint as est_rows, round(pg_relation_size(c.oid) / 1048576.0, 1) as heap_mb, round(pg_indexes_size(c.oid) / 1048576.0, 1) as indexes_mb,
       (select sum(n) from cma.tenant t
         cross join lateral (select count(*) as n from cma.sync_run s where s.tenant_id = t.id and s.started_at > now() - interval '30 days') x)
         as runs_last_30_days
from pg_class c where c.oid = 'cma.sync_run'::regclass;

\echo
\echo ==== 7. audit_log ====
select c.reltuples::bigint as est_rows,
       round(pg_relation_size(c.oid) / 1048576.0, 1) as heap_mb,
       round(coalesce(pg_total_relation_size(nullif(c.reltoastrelid, 0)), 0) / 1048576.0, 1) as toast_mb,
       round(pg_indexes_size(c.oid) / 1048576.0, 1) as indexes_mb,
       round(pg_total_relation_size(c.oid) / 1048576.0, 1) as total_mb,
       round(pg_total_relation_size(c.oid)::numeric / nullif(c.reltuples, 0)) as bytes_per_row_with_indexes,
       round(100.0 * pg_total_relation_size(c.oid) / pg_database_size(current_database()), 1) as pct_of_database
from pg_class c where c.oid = 'cma.audit_log'::regclass;
\echo -- 7a rows per UTC day, the last 14 days, per tenant: the estimate of the planner always; counted on audit_log_time_idx (tenant_id, changed_at) when the estimate is at most audit_count_max over the 14 days and audit_budget_s allows
do $$
declare
  t record; d integer; j json; v_est numeric; v_est14 numeric; v_n bigint; v_from timestamptz; v_to timestamptz;
  v_t0 timestamptz := clock_timestamp();
  v_budget numeric := current_setting('diag.audit_budget_s')::numeric;
  v_max numeric := current_setting('diag.audit_count_max')::numeric;
  v_bpr numeric := (select pg_total_relation_size(c.oid)::numeric / nullif(c.reltuples, 0) from pg_class c where c.oid = 'cma.audit_log'::regclass);
  v_day0 timestamptz := date_trunc('day', now() at time zone 'UTC') at time zone 'UTC';
  v_count boolean; r record;
begin
  -- a statement_timeout (60 s) ends this section, not the script: query_canceled is caught below
  begin
  if not exists (select 1 from pg_indexes where schemaname = 'cma' and tablename = 'audit_log' and indexname = 'audit_log_time_idx') then
    raise notice 'audit_log_time_idx does not exist: rows per day are not counted (a count would read the whole table); the estimate above stands';
    return;
  end if;
  raise notice 'tenant | day (UTC) | estimated rows | counted rows | MB a day (counted, else estimated, x bytes per row)';
  for t in select x.id, x.slug from cma.tenant x order by x.slug collate "C" loop
    execute format('explain (format json) select 1 from cma.audit_log a where a.tenant_id = %L and a.changed_at >= %L', t.id, v_day0 - interval '13 days') into j;
    v_est14 := (j -> 0 -> 'Plan' ->> 'Plan Rows')::numeric;
    v_count := v_est14 <= v_max;
    if not v_count then
      raise notice '% | 14 days | % | not counted: the estimate is above audit_count_max (%), a count would read that many index entries and their heap pages', t.slug, v_est14, v_max;
    end if;
    for d in reverse 13 .. 0 loop
      v_from := v_day0 - make_interval(days => d);
      v_to := v_from + interval '1 day';
      execute format('explain (format json) select 1 from cma.audit_log a where a.tenant_id = %L and a.changed_at >= %L and a.changed_at < %L', t.id, v_from, v_to) into j;
      v_est := (j -> 0 -> 'Plan' ->> 'Plan Rows')::numeric;
      v_n := null;
      if v_count and extract(epoch from clock_timestamp() - v_t0) < v_budget then
        execute format('select count(*) from cma.audit_log a where a.tenant_id = %L and a.changed_at >= %L and a.changed_at < %L', t.id, v_from, v_to) into v_n;
      end if;
      raise notice '% | % | % | % | %', t.slug, (v_from at time zone 'UTC')::date, v_est,
        coalesce(v_n::text, case when v_count then 'not counted: budget' else '-' end),
        round(coalesce(v_n, v_est) * coalesce(v_bpr, 0) / 1048576.0, 1);
    end loop;
  end loop;
  -- which tables fed it over the last 24 hours (table_name is not in the time index: each row's heap page is read)
  raise notice '-- 7b rows over the last 24 hours per tenant and table (counted when the estimate is at most audit_count_max / 14 and the budget allows)';
  for t in select x.id, x.slug from cma.tenant x order by x.slug collate "C" loop
    execute format('explain (format json) select 1 from cma.audit_log a where a.tenant_id = %L and a.changed_at >= %L', t.id, now() - interval '24 hours') into j;
    v_est := (j -> 0 -> 'Plan' ->> 'Plan Rows')::numeric;
    if v_est > v_max / 14 then
      raise notice '% | last 24 hours | estimated % rows: not counted per table (above audit_count_max / 14)', t.slug, v_est;
      continue;
    end if;
    if extract(epoch from clock_timestamp() - v_t0) >= v_budget then
      raise notice '% | last 24 hours | not counted: budget', t.slug;
      continue;
    end if;
    for r in execute format('select a.table_name, count(*) as n from cma.audit_log a where a.tenant_id = %L and a.changed_at >= %L
                             group by 1 order by 2 desc, 1 limit 15', t.id, now() - interval '24 hours') loop
      raise notice '% | % | % rows', t.slug, r.table_name, r.n;
    end loop;
  end loop;
  exception when query_canceled or lock_not_available then
    raise notice 'section 7 stopped (%) after % s: the rows above are complete, the rest is not counted', sqlstate, round(extract(epoch from clock_timestamp() - v_t0), 1);
  end;
  raise notice 'section 7: % s', round(extract(epoch from clock_timestamp() - v_t0), 1);
end
$$;

\echo
\echo ==== 9. Proof and run time ====
select pg_current_xact_id_if_assigned() is null as wrote_nothing,
       round(extract(epoch from clock_timestamp() - current_setting('diag.t0')::timestamptz), 1) as script_seconds;
\echo -- the tables this transaction wrote (none: it is read only; a row here would mean a write the read-only setting let through)
select x.schemaname as schema, x.relname as table_name, x.n_tup_ins as inserted, x.n_tup_upd as updated, x.n_tup_del as deleted
from pg_stat_xact_user_tables x
where x.n_tup_ins + x.n_tup_upd + x.n_tup_del > 0
order by x.n_tup_ins + x.n_tup_upd + x.n_tup_del desc, x.relname;
rollback;
