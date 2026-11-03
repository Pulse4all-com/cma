-- =============================================================================================
-- 124_time_flash.sql: Flash's speed on the database's own data (addition 0008zn), read only
-- =============================================================================================
-- Times the reads Reports → Flash makes, on the data the database holds, as the application (cma_app, row-level
-- security on), per active tenant: every live overview and the landing, and the first page of every list (500 rows, by
-- the list's first sort key, descending), each the best of two runs. No addition, no write: the reads run in a read-only
-- subtransaction that the script then rolls back (its rows kept in variables, written to a temporary table after it), so
-- the script runs alike as one transaction (Cloud SQL Studio runs a script so; 3 November 2026: a read-only mode set for
-- the whole transaction refused the helper's drop at the end) and statement by statement (psql), in any database, at any
-- time, as often as wanted. Run as your own IAM login, in Cloud SQL Studio, after 122_flash.sql and 123_verify_flash.sql.
-- Prod is the proof (PROD_RUNBOOK phase 16, after 122 and 123): real data on the dedicated core, the reads under the
-- budgets below. In dev the timings are for information only: dev is a shared-core db-g1-small
-- (docs/architecture/infrastructure.md), as for 91's B8, and a dev run over budget is the tier, not Flash. 123's block C
-- (speed at a generated volume) runs in local databases only.
-- Whose user: the script picks it, per tenant: the tenant's first active person (kind person, the oldest) holding
-- reports.view, the reads' permission (performance.team alone is not looked for); its row "<tenant> acting as" names the
-- user's id, never an email. A tenant without such a person reads one skip row. Flows (the overviews of kind flow) read
-- the tenant's previous calendar month; stock overviews read now; all markets. Budgets (123's; Decision log, 3 November
-- 2026): an overview and the landing under verify.max_overview_ms (1,500 ms), a first page of a list under
-- verify.max_rows_ms (800 ms, the brief's), data quality's overview and its first page under verify.max_dq_ms (2,500 ms).
-- Data quality's budget is to be met on stored results (backlog CMA-087); until then its reads run every check of
-- cma.data_quality_of live and can exceed it under load, so a FAIL on data quality alone is a known exception: record it
-- with its milliseconds, do not rerun (PROD_RUNBOOK 16.4).
-- Within Studio's 300 seconds: the script stops starting reads after verify.time_budget_s (240 s); a read it did not reach
-- reads FAIL ("not timed"); a read already running is not cut, so one read longer than a minute would take the whole run
-- past Studio's limit (at a volume of 100,000 customers the slowest read took 1.6 s locally). A read that raises an
-- error reads FAIL with its SQLSTATE, and the others still run. Any other error in the timed part ends it with a row
-- "the timed part | FAIL | ended early: <SQLSTATE>", the rows timed before it kept; a cancel (Studio's limit, a statement
-- timeout) still ends the whole script.
-- The first row, "read only", shows that a write in the timed part is refused (25006): info, or FAIL when it was not.
-- One row per read: the tenant's slug and the read, ok or FAIL, the milliseconds against the budget; the last row is the
-- verdict, "PASS | 124_time_flash: <n> ok, 0 FAIL, <n> skip; worst <ms> ms (<read>)", because Cloud SQL Studio shows no
-- notices. Ids, codes and milliseconds only: no record, no name, no figure is shown.
-- Provoke: set verify.provoke below to true; every budget is then 0 ms, every timed read FAILs, and the verdict says
-- PROVOKED, NOT A PASS.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0008zn') then
    raise exception 'addition 0008zn (122_flash.sql) has not run in this database';
  end if;
end
$$;
select set_config('verify.provoke', 'false', false);                 -- 'true' to make every timed read fail
select set_config('verify.max_overview_ms', '1500', false);          -- an overview and the landing
select set_config('verify.max_rows_ms', '800', false);               -- a first page of a list (the brief's)
select set_config('verify.max_dq_ms', '2500', false);                -- data quality's overview and first page (on stored results: CMA-087)
select set_config('verify.time_budget_s', '240', false);             -- stop starting reads after this, inside Studio's 300 s

drop table if exists pg_temp.time_0124;
create temporary table time_0124 (ord integer, check_name text, result text, detail text, ms numeric);

-- The fastest of p_runs runs of a read, in milliseconds, every row fetched; -1 when the read raises an error, its
-- SQLSTATE then in t0124.error (a subtransaction of its own, so the run goes on)
create or replace function pg_temp.t0124_best_ms(p_sql text, p_runs integer)
returns numeric
language plpgsql
as $$
declare
  v_t0   timestamptz;
  v_ms   numeric;
  v_best numeric;
  r      record;
begin
  perform set_config('t0124.error', '', true);
  begin
    for i in 1 .. p_runs loop
      v_t0 := clock_timestamp();
      for r in execute p_sql loop
        null;
      end loop;
      v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
      v_best := least(coalesce(v_best, v_ms), v_ms);
    end loop;
  exception when others then
    perform set_config('t0124.error', sqlstate, true);
    return -1;
  end;
  return v_best;
end
$$;

do $$
declare
  v_max_o   numeric := case when current_setting('verify.provoke')::boolean then 0 else current_setting('verify.max_overview_ms')::numeric end;
  v_max_r   numeric := case when current_setting('verify.provoke')::boolean then 0 else current_setting('verify.max_rows_ms')::numeric end;
  v_max_q   numeric := case when current_setting('verify.provoke')::boolean then 0 else current_setting('verify.max_dq_ms')::numeric end;
  v_stop    timestamptz := clock_timestamp() + make_interval(secs => current_setting('verify.time_budget_s')::numeric);
  t record; o record;
  v_user uuid; v_today date; v_from date; v_to date; v_ms numeric; v_flow boolean; v_guard text;
  v_names text[]; v_sqls text[]; v_max_list numeric[]; v_note_list text[];
  -- the result rows, kept in variables: they outlive the read-only subtransaction's rollback
  r_name text[] := '{}'; r_result text[] := '{}'; r_detail text[] := '{}'; r_ms numeric[] := '{}';
begin
  -- the timed part runs in a subtransaction that is read only and then rolled back: its read-only mode, its role and its
  -- tenant end with it, so the rest of the script runs read-write whether the whole script is one transaction (Cloud SQL
  -- Studio) or each statement its own (psql)
  begin
    perform set_config('transaction_read_only', 'on', true);
    -- the guard: a write in the timed part is refused (25006), as every read's would be
    begin
      update cma.tenant set name = name where false;
      v_guard := 'no error';
    exception when others then
      v_guard := sqlstate;
    end;
    r_name := r_name || 'read only'::text;
    r_result := r_result || case when v_guard = '25006' then 'info' else 'FAIL' end;
    r_detail := r_detail || case when v_guard = '25006' then 'a write in the timed part is refused (25006)'
                                 else 'a write in the timed part did not raise 25006: ' || v_guard end;
    r_ms := r_ms || null::numeric;
    for t in select x.id, x.slug from cma.tenant x where x.status = 'active' order by x.slug collate "C" loop
      perform set_config('role', 'cma_owner', true);
      perform set_config('app.user_id', '', true);
      perform set_config('app.tenant_id', t.id::text, true);         -- cma.has_permission reads the current tenant's roles
      v_user := null;
      select u.id into v_user
      from cma.app_user u
      where u.tenant_id = t.id and u.status = 'active' and u.kind = 'person' and cma.has_permission(u.id, 'reports.view')
      order by u.created_at, u.id
      limit 1;
      if v_user is null then
        r_name := r_name || t.slug::text; r_result := r_result || 'skip'::text;
        r_detail := r_detail || 'no active person holds reports.view: nothing timed'::text; r_ms := r_ms || null::numeric;
        continue;
      end if;
      v_today := cma.tenant_today_of(t.id);
      v_from := (date_trunc('month', v_today) - interval '1 month')::date;
      v_to := (date_trunc('month', v_today) - interval '1 day')::date;
      -- the tenant's reads, in the page's order: every overview, the landing, the first page of every list
      v_names := '{}'; v_sqls := '{}'; v_max_list := '{}'; v_note_list := '{}';
      for o in select x.key, x.kind from cma.flash_overviews() x order by x.sort_order loop
        v_flow := o.kind = 'flow';
        v_names := v_names || ('overview ' || o.key);
        v_sqls := v_sqls || format('select cma.flash_overview(%L, null, null, %L, %L)', o.key,
                                   case when v_flow then v_from end, case when v_flow then v_to end);
        v_max_list := v_max_list || case when o.key = 'data_quality' then v_max_q else v_max_o end;
        v_note_list := v_note_list || case when v_flow then '; flows ' || v_from || ' to ' || v_to else '' end;
      end loop;
      v_names := v_names || 'landing'::text;
      v_sqls := v_sqls || format('select cma.flash_page(null, null, %L, %L)', v_from, v_to);
      v_max_list := v_max_list || v_max_o;
      v_note_list := v_note_list || ('; flows ' || v_from || ' to ' || v_to);
      for o in select x.key, x.kind, x.sorts from cma.flash_overviews() x order by x.sort_order loop
        v_flow := o.kind = 'flow';
        v_names := v_names || ('list ' || o.key || ' by ' || o.sorts[1] || ' desc');
        v_sqls := v_sqls || format('select cma.flash_rows(%L, ''{}'', %L, true, 500, 0, null, %L, %L)', o.key, o.sorts[1],
                                   case when v_flow then v_from end, case when v_flow then v_to end);
        v_max_list := v_max_list || case when o.key = 'data_quality' then v_max_q else v_max_r end;
        v_note_list := v_note_list || case when v_flow then '; flows ' || v_from || ' to ' || v_to else '' end;
      end loop;
      r_name := r_name || (t.slug || ' acting as'); r_result := r_result || 'info'::text;
      r_detail := r_detail || ('app_user ' || v_user || ': the first active person holding reports.view'); r_ms := r_ms || null::numeric;
      -- as the application, in the tenant, as that person; each row kept as soon as its read is timed
      perform set_config('role', 'cma_app', true);
      perform set_config('app.user_id', v_user::text, true);
      for i in 1 .. cardinality(v_names) loop
        v_ms := case when clock_timestamp() > v_stop then null else pg_temp.t0124_best_ms(v_sqls[i], 2) end;
        r_name := r_name || (t.slug || ' ' || v_names[i]);
        r_result := r_result || case when v_ms is not null and v_ms >= 0 and v_ms < v_max_list[i] then 'ok' else 'FAIL' end;
        r_detail := r_detail || case when v_ms is null then 'not timed: the run stopped starting reads at verify.time_budget_s'
                                     when v_ms = -1 then 'error ' || current_setting('t0124.error')
                                     else v_ms || ' ms (best of 2) against ' || v_max_list[i] || ' ms' || v_note_list[i] end;
        r_ms := r_ms || case when v_ms >= 0 then v_ms end;
      end loop;
    end loop;
    raise exception using errcode = 'CMAOK', message = 'the timed part ends: rolled back';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      -- any other error ends the timed part: the rows timed so far stay, with a FAIL row that names its SQLSTATE (a cancel,
      -- query_canceled, is not caught: it ends the script, as Studio's limit does)
      r_name := r_name || 'the timed part'::text; r_result := r_result || 'FAIL'::text;
      r_detail := r_detail || ('ended early: ' || sqlstate); r_ms := r_ms || null::numeric;
  end;
  -- read-write again, as the owner: the rows into the temporary table
  insert into pg_temp.time_0124 (ord, check_name, result, detail, ms)
  select i, r_name[i], r_result[i], r_detail[i], r_ms[i] from generate_series(1, cardinality(r_name)) i;
end
$$;

drop function if exists pg_temp.t0124_best_ms(text, integer);

-- One row per read, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.time_0124
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.time_0124 where result = 'FAIL') then 'FAIL'
                  when not exists (select 1 from pg_temp.time_0124 where result = 'ok') then 'FAIL'
                  else 'PASS' end,
             format('124_time_flash: %s ok, %s FAIL, %s skip; worst %s ms (%s)', (select count(*) from pg_temp.time_0124 where result = 'ok'),
                    (select count(*) from pg_temp.time_0124 where result = 'FAIL'), (select count(*) from pg_temp.time_0124 where result = 'skip'),
                    coalesce((select max(ms)::text from pg_temp.time_0124), '-'),
                    coalesce((select check_name from pg_temp.time_0124 where ms is not null order by ms desc, ord limit 1), '-'))) x
order by ord;
drop table if exists pg_temp.time_0124;
reset role;
