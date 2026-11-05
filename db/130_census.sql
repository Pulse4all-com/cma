-- =============================================================================================
-- 130_census.sql: the database's volume and health, read only (night N06, 5 November 2026)
-- =============================================================================================
-- A census of the database the script runs in, for the speed work (docs/night-2026-11-06): no addition, no write.
-- One row per item, the verdict last, as 124_time_flash.sql: the rows are gathered inside a read-only subtransaction
-- that is rolled back, so the script runs alike as one transaction (Cloud SQL Studio) and statement by statement
-- (psql), in any database, at any time, as often as wanted; it stops starting items after verify.time_budget_s
-- (240 s) so it stays inside Studio's 300 s. Run as your own IAM login (Studio or the Terminal through the Auth Proxy),
-- after 00_roles.sql in any database; it needs nothing else. Aggregates only: table names, counts, sizes and dates,
-- never a row of a table. Where pg_stat_statements is installed, the top statements are listed by their normalised
-- text (constants are $n), cut to 100 characters, with any remaining quoted literal replaced by '?'.
--
-- What it shows
--   volume <table>      every cma table with at least verify.min_rows live rows (10,000): rows (the statistics'
--                       estimate), the table's size, its indexes' size and the total; info
--   health <table>      the same tables: sequential against index scans since the last statistics reset, dead tuples
--                       and their share of the live rows, the last autovacuum and autoanalyze; FAIL when the dead share
--                       is at or above verify.max_dead_pct (20 %) and the dead rows at least verify.min_rows, else info
--   unused index <name> an index of a cma table never scanned since the statistics reset (idx_scan 0), with its size;
--                       listed, never dropped (a proposal; prod's statistics decide): info. Primary keys and unique
--                       indexes are left out (they serve constraints, not reads)
--   invalid index <name> an index whose build was interrupted (pg_index.indisvalid false): FAIL, with the drop-and-
--                       retry note of 134_indexes_concurrently.sql
--   fk without index    one row per foreign key of a cma table whose referencing columns no index starts with (DB-11
--                       of the IT audit of 17 October 2026 counted 46), and one count row; info
--   statement <n>       the top verify.top_statements (15) by total time from pg_stat_statements when the extension
--                       is installed (pg_extension); otherwise one row saying it is not and where the step to enable
--                       it is (MORNING_RUNBOOK, step 0d); info
--   statistics reset    when the database's statistics were last reset (pg_stat_database.stats_reset): info
-- Provoke: set verify.provoke below to true; every row then reads FAIL and the verdict PROVOKED, NOT A PASS.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);                 -- 'true' to make every row FAIL
select set_config('verify.min_rows', '10000', false);                -- a table counts from this many live rows
select set_config('verify.max_dead_pct', '20', false);               -- dead tuples as a share of the live rows: FAIL from here
select set_config('verify.top_statements', '15', false);             -- the statements listed when pg_stat_statements is installed
select set_config('verify.time_budget_s', '240', false);             -- stop starting items after this, inside Studio's 300 s

drop table if exists pg_temp.census_0130;
create temporary table census_0130 (ord integer, check_name text, result text, detail text);

-- One row as three texts; in provoke mode every row reads FAIL
create or replace function pg_temp.c0130_row(p_provoke boolean, p_name text, p_result text, p_detail text)
returns text[] language sql immutable as $$ select array[p_name, case when p_provoke then 'FAIL' else p_result end, p_detail] $$;

do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_min      bigint := current_setting('verify.min_rows')::bigint;
  v_dead_pct numeric := case when v_provoke then 0 else current_setting('verify.max_dead_pct')::numeric end;
  v_top      integer := current_setting('verify.top_statements')::integer;
  v_stop     timestamptz := clock_timestamp() + make_interval(secs => current_setting('verify.time_budget_s')::numeric);
  r record;
  v_guard text; v_n integer := 0; v_fk integer := 0;
  -- the rows, three texts each (name, result, detail), kept in one array: they outlive the subtransaction's rollback
  rows_ text[] := '{}';
begin
  begin
    perform set_config('transaction_read_only', 'on', true);
    begin
      update cma.tenant set name = name where false;
      v_guard := 'no error';
    exception when others then
      v_guard := sqlstate;
    end;
    rows_ := rows_ || pg_temp.c0130_row(v_provoke, 'read only', case when v_guard = '25006' then 'info' else 'FAIL' end,
              case when v_guard = '25006' then 'a write in the census is refused (25006)' else 'a write in the census did not raise 25006: ' || v_guard end);
    rows_ := rows_ || pg_temp.c0130_row(v_provoke, 'statistics reset', 'info',
              coalesce((select 'statistics reset at ' || to_char(d.stats_reset at time zone 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC'
                        from pg_stat_database d where d.datname = current_database()), 'statistics never reset (since the database was created)'));

    -- (a) and (b): the volume and the health of every table of verify.min_rows rows and more
    for r in
      select s.relname, s.n_live_tup, s.n_dead_tup, s.seq_scan, s.idx_scan, s.last_autovacuum, s.last_autoanalyze, s.last_vacuum, s.last_analyze,
             pg_table_size(s.relid) as table_bytes, pg_indexes_size(s.relid) as index_bytes
      from pg_stat_user_tables s
      where s.schemaname = 'cma' and s.n_live_tup >= v_min
      order by s.n_live_tup desc, s.relname
    loop
      exit when clock_timestamp() > v_stop;
      rows_ := rows_ || pg_temp.c0130_row(v_provoke, 'volume ' || r.relname, 'info',
                format('rows ~%s; table %s, indexes %s, total %s', to_char(r.n_live_tup, 'FM999G999G999G999'),
                       pg_size_pretty(r.table_bytes), pg_size_pretty(r.index_bytes), pg_size_pretty(r.table_bytes + r.index_bytes)));
      rows_ := rows_ || pg_temp.c0130_row(v_provoke, 'health ' || r.relname,
                case when r.n_live_tup > 0 and r.n_dead_tup >= v_min and r.n_dead_tup * 100.0 / r.n_live_tup >= v_dead_pct then 'FAIL' else 'info' end,
                format('seq scans %s, index scans %s; dead %s (%s%% of live); last autovacuum %s, last autoanalyze %s%s',
                       r.seq_scan, coalesce(r.idx_scan, 0), to_char(r.n_dead_tup, 'FM999G999G999G999'),
                       case when r.n_live_tup > 0 then round(r.n_dead_tup * 100.0 / r.n_live_tup, 1)::text else '-' end,
                       coalesce(to_char(coalesce(r.last_autovacuum, r.last_vacuum) at time zone 'UTC', 'YYYY-MM-DD HH24:MI'), 'never'),
                       coalesce(to_char(coalesce(r.last_autoanalyze, r.last_analyze) at time zone 'UTC', 'YYYY-MM-DD HH24:MI'), 'never'),
                       case when r.seq_scan > coalesce(r.idx_scan, 0) then '; more sequential than index scans' else '' end));
    end loop;
    if cardinality(rows_) = 6 then
      rows_ := rows_ || pg_temp.c0130_row(v_provoke, 'volume', 'info', format('no cma table holds %s rows or more', v_min));
    end if;

    -- unused indexes since the statistics reset, with their size (never dropped here)
    for r in
      select i.indexrelname as name, i.relname as tbl, pg_relation_size(i.indexrelid) as bytes
      from pg_stat_user_indexes i
      join pg_index x on x.indexrelid = i.indexrelid
      where i.schemaname = 'cma' and i.idx_scan = 0 and not x.indisunique and not x.indisprimary
      order by pg_relation_size(i.indexrelid) desc, i.indexrelname
    loop
      exit when clock_timestamp() > v_stop;
      v_n := v_n + 1;
      rows_ := rows_ || pg_temp.c0130_row(v_provoke, 'unused index ' || r.name, 'info', format('on cma.%s, %s, no scan since the statistics reset; listed, not dropped', r.tbl, pg_size_pretty(r.bytes)));
    end loop;
    rows_ := rows_ || pg_temp.c0130_row(v_provoke, 'unused indexes', 'info', format('%s index(es) of cma tables without a scan since the statistics reset (primary keys and unique indexes left out)', v_n));

    -- invalid indexes (a concurrent build that was interrupted)
    v_n := 0;
    for r in
      select c.relname as name, t.relname as tbl from pg_index x
      join pg_class c on c.oid = x.indexrelid join pg_class t on t.oid = x.indrelid join pg_namespace n on n.oid = t.relnamespace
      where n.nspname = 'cma' and not x.indisvalid order by c.relname
    loop
      v_n := v_n + 1;
      rows_ := rows_ || pg_temp.c0130_row(v_provoke, 'invalid index ' || r.name, 'FAIL', format('on cma.%s: its build was interrupted; drop it and run its create index concurrently again (134_indexes_concurrently.sql)', r.tbl));
    end loop;
    rows_ := rows_ || pg_temp.c0130_row(v_provoke, 'invalid indexes', 'info', format('%s invalid index(es)', v_n));

    -- foreign keys whose referencing columns no index starts with (DB-11)
    for r in
      select c.conname, t.relname as tbl,
             (select string_agg(a.attname, ', ' order by k.ord) from unnest(c.conkey) with ordinality k(attnum, ord)
              join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum) as cols
      from pg_constraint c
      join pg_class t on t.oid = c.conrelid join pg_namespace n on n.oid = t.relnamespace
      where c.contype = 'f' and n.nspname = 'cma'
        and not exists (select 1 from pg_index x where x.indrelid = c.conrelid and x.indisvalid
                        and (x.indkey::int2[])[0:cardinality(c.conkey) - 1] = c.conkey)
      order by t.relname, c.conname
    loop
      exit when clock_timestamp() > v_stop;
      v_fk := v_fk + 1;
      rows_ := rows_ || pg_temp.c0130_row(v_provoke, 'fk without index ' || r.conname, 'info', format('cma.%s (%s)', r.tbl, r.cols));
    end loop;
    rows_ := rows_ || pg_temp.c0130_row(v_provoke, 'fks without index', 'info', format('%s foreign key(s) of cma tables without an index starting with their columns (DB-11 counted 46 on 17 October 2026)', v_fk));

    -- the top statements by total time, when pg_stat_statements is installed
    if exists (select 1 from pg_extension where extname = 'pg_stat_statements') then
      v_n := 0;
      for r in execute format(
        $q$select s.queryid, s.calls, round(s.total_exec_time::numeric, 0) as total_ms, round(s.mean_exec_time::numeric, 1) as mean_ms,
                  regexp_replace(left(regexp_replace(s.query, '\s+', ' ', 'g'), 100), '''[^'']*''', '?', 'g') as text_
           from pg_stat_statements s join pg_database d on d.oid = s.dbid
           where d.datname = current_database() order by s.total_exec_time desc limit %s$q$, v_top)
      loop
        v_n := v_n + 1;
        rows_ := rows_ || pg_temp.c0130_row(v_provoke, format('statement %s', v_n), 'info',
                  format('queryid %s: %s calls, %s ms in all, %s ms mean: %s', r.queryid, r.calls, r.total_ms, r.mean_ms, r.text_));
      end loop;
      if v_n = 0 then
        rows_ := rows_ || pg_temp.c0130_row(v_provoke, 'statements', 'info', 'pg_stat_statements is installed and holds no statement of this database (or this login may not read other logins'' statements: pg_read_all_stats)');
      end if;
    else
      rows_ := rows_ || pg_temp.c0130_row(v_provoke, 'statements', 'info', 'pg_stat_statements is not installed (pg_extension): the top statements are not listed; MORNING_RUNBOOK step 0d says how to enable it (a database flag, Martin''s decision)');
    end if;
    raise exception using errcode = 'CMAOK', message = 'the census ends: rolled back';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      rows_ := rows_ || pg_temp.c0130_row(v_provoke, 'the census', 'FAIL', 'ended early: ' || sqlstate || ' ' || left(sqlerrm, 120));
  end;
  insert into pg_temp.census_0130 (ord, check_name, result, detail)
  select i, rows_[3 * i - 2], rows_[3 * i - 1], rows_[3 * i] from generate_series(1, cardinality(rows_) / 3) i;
end
$$;

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.census_0130
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.census_0130 where result = 'FAIL') then 'FAIL'
                  else 'PASS' end,
             format('130_census: %s rows, %s FAIL; %s table(s) of %s rows or more, %s unused index(es), %s fk(s) without index',
                    (select count(*) from pg_temp.census_0130), (select count(*) from pg_temp.census_0130 where result = 'FAIL'),
                    (select count(*) from pg_temp.census_0130 where check_name like 'volume %'),
                    current_setting('verify.min_rows'),
                    (select count(*) from pg_temp.census_0130 where check_name like 'unused index %'),
                    (select count(*) from pg_temp.census_0130 where check_name like 'fk without index %'))) x
order by ord;
drop function if exists pg_temp.c0130_row(boolean, text, text, text);
drop table if exists pg_temp.census_0130;
reset role;
