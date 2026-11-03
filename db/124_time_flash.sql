-- =============================================================================================
-- 124_time_flash.sql: Flash's speed on the database's own data (addition 0008zn), read only
-- =============================================================================================
-- Times the reads Reports → Flash makes, on the data the database holds, as the application (cma_app, row-level
-- security on), per active tenant: every live overview and the landing, and the first page of every list (500 rows, by
-- the list's default sort), each the best of two runs. No addition, no write: the reads run in a read-only transaction
-- (the results go to a temporary table), so it runs in any database at any time, as often as wanted. Run as your own
-- IAM login, in Cloud SQL Studio, after 122_flash.sql and 123_verify_flash.sql.
-- Prod is the proof (PROD_RUNBOOK phase 16, after 122 and 123): real data on the dedicated core, the reads under the
-- budgets below. In dev the timings are for information only: dev is a shared-core db-g1-small (README, Dev database
-- server), as for 91's B8, and a dev run over budget is the tier, not Flash. 123's block C (speed at a generated volume)
-- runs in local databases only.
-- Each tenant acts as its first active person holding reports.view (the reads' permission); a tenant without one reads
-- skip. Flows (churn, orders, payments, reviews) read the tenant's previous calendar month; stock overviews read now; all
-- markets. Budgets (123's, docs/open-decisions.md, Flash speed at volume): an overview and the landing under
-- verify.max_overview_ms (1,500 ms, the brief's), a first page of a list under verify.max_rows_ms (1,500 ms proposed; the
-- brief's 800 ms is reported), data quality's overview and its first page under verify.max_dq_ms (2,500 ms proposed:
-- they run every check of cma.data_quality_of live). The script stops timing after verify.time_budget_s (240 s), inside
-- Studio's 300 seconds; a read it did not reach reads FAIL ("not timed").
-- One row per read: the tenant's slug and the read, ok or FAIL, the milliseconds against the budget; the last row is the
-- verdict, "PASS | 124_time_flash: <n> ok, 0 FAIL, <n> skip", because Cloud SQL Studio shows no notices. Ids, codes and
-- milliseconds only: no record, no person, no figure is shown.
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
select set_config('verify.max_overview_ms', '1500', false);          -- an overview and the landing (the brief's)
select set_config('verify.max_rows_ms', '1500', false);              -- a first page of a list (proposed; the brief's is 800)
select set_config('verify.max_dq_ms', '2500', false);                -- data quality's overview and first page (proposed)
select set_config('verify.brief_rows_ms', '800', false);             -- the brief's budget of a first page, reported
select set_config('verify.time_budget_s', '240', false);             -- stop timing after this, inside Studio's 300 s

drop table if exists time_0124;
create temporary table time_0124 (ord integer, check_name text, result text, detail text, ms numeric);

-- The fastest of p_runs runs of a read, in milliseconds, every row fetched
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
  for i in 1 .. p_runs loop
    v_t0 := clock_timestamp();
    for r in execute p_sql loop
      null;
    end loop;
    v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
    v_best := least(coalesce(v_best, v_ms), v_ms);
  end loop;
  return v_best;
end
$$;

do $$
declare
  v_max_o   numeric := case when current_setting('verify.provoke')::boolean then 0 else current_setting('verify.max_overview_ms')::numeric end;
  v_max_r   numeric := case when current_setting('verify.provoke')::boolean then 0 else current_setting('verify.max_rows_ms')::numeric end;
  v_max_q   numeric := case when current_setting('verify.provoke')::boolean then 0 else current_setting('verify.max_dq_ms')::numeric end;
  v_stop    timestamptz := clock_timestamp() + make_interval(secs => current_setting('verify.time_budget_s')::numeric);
  v_ord     integer := 0;
  t record; o record;
  v_user uuid; v_today date; v_from date; v_to date;
  v_max numeric; v_ms numeric;
  v_names text[]; v_ms_list numeric[]; v_max_list numeric[];
begin
  -- nothing the reads do may write: the transaction is read only from here (the temporary table excepted)
  perform set_config('transaction_read_only', 'on', true);
  for t in select x.id, x.slug from cma.tenant x where x.status = 'active' order by x.slug collate "C" loop
    perform set_config('app.tenant_id', t.id::text, true);         -- cma.has_permission reads the current tenant's roles
    select u.id into v_user
    from cma.app_user u
    where u.tenant_id = t.id and u.status = 'active' and cma.has_permission(u.id, 'reports.view')
    order by u.created_at, u.id
    limit 1;
    if v_user is null then
      v_ord := v_ord + 1;
      insert into time_0124 values (v_ord, t.slug, 'skip', 'no active person holds reports.view: nothing timed', null);
      continue;
    end if;
    v_today := cma.tenant_today_of(t.id);
    v_from := (date_trunc('month', v_today) - interval '1 month')::date;
    v_to := (date_trunc('month', v_today) - interval '1 day')::date;
    v_names := '{}'; v_ms_list := '{}'; v_max_list := '{}';
    -- as the application, in the tenant, as that person
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', t.id::text, true);
    perform set_config('app.user_id', v_user::text, true);
    for o in select x.key, x.kind from cma.flash_overviews() x order by x.sort_order loop
      v_names := v_names || ('overview ' || o.key);
      v_max_list := v_max_list || case when o.key = 'data_quality' then v_max_q else v_max_o end;
      if clock_timestamp() > v_stop then
        v_ms_list := v_ms_list || null::numeric;
      else
        v_ms_list := v_ms_list || pg_temp.t0124_best_ms(format('select cma.flash_overview(%L, null, null, %L, %L)', o.key,
                                                               case when o.kind = 'flow' then v_from end, case when o.kind = 'flow' then v_to end), 2);
      end if;
    end loop;
    v_names := v_names || 'landing'::text;
    v_max_list := v_max_list || v_max_o;
    v_ms_list := v_ms_list || case when clock_timestamp() > v_stop then null
                                   else pg_temp.t0124_best_ms(format('select cma.flash_page(null, null, %L, %L)', v_from, v_to), 2) end;
    for o in select x.key, x.kind, x.sorts from cma.flash_overviews() x order by x.sort_order loop
      v_names := v_names || ('list ' || o.key || ' by ' || o.sorts[1]);
      v_max_list := v_max_list || case when o.key = 'data_quality' then v_max_q else v_max_r end;
      if clock_timestamp() > v_stop then
        v_ms_list := v_ms_list || null::numeric;
      else
        v_ms_list := v_ms_list || pg_temp.t0124_best_ms(format('select cma.flash_rows(%L, ''{}'', null, true, 500, 0, null, %L, %L)', o.key,
                                                               case when o.kind = 'flow' then v_from end, case when o.kind = 'flow' then v_to end), 2);
      end if;
    end loop;
    -- back to the owner to write the rows (the temporary table is the owner's)
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.tenant_id', '', true);
    perform set_config('app.user_id', '', true);
    for i in 1 .. cardinality(v_names) loop
      v_ord := v_ord + 1;
      v_ms := v_ms_list[i]; v_max := v_max_list[i];
      insert into time_0124 values (v_ord, t.slug || ' ' || v_names[i],
        case when v_ms is not null and v_ms < v_max then 'ok' else 'FAIL' end,
        case when v_ms is null then 'not timed: the run stopped at verify.time_budget_s'
             else v_ms || ' ms (best of 2) against ' || v_max || ' ms'
                  || case when v_names[i] like 'list %' and v_names[i] not like 'list data_quality %'
                               and v_ms >= current_setting('verify.brief_rows_ms')::numeric
                          then '; over the brief''s ' || current_setting('verify.brief_rows_ms') || ' ms' else '' end
                  || case when v_names[i] like 'overview %' or v_names[i] = 'landing'
                          then case when v_names[i] in ('overview churn', 'overview orders', 'overview payments', 'overview reviews', 'landing')
                                    then '; flows ' || v_from || ' to ' || v_to else '' end
                          else '' end
        end,
        v_ms);
    end loop;
  end loop;
end
$$;

drop function if exists pg_temp.t0124_best_ms(text, integer);

-- One row per read, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from time_0124
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from time_0124 where result = 'FAIL') then 'FAIL'
                  when not exists (select 1 from time_0124 where result = 'ok') then 'FAIL'
                  else 'PASS' end,
             format('124_time_flash: %s ok, %s FAIL, %s skip; worst %s ms (%s)', (select count(*) from time_0124 where result = 'ok'),
                    (select count(*) from time_0124 where result = 'FAIL'), (select count(*) from time_0124 where result = 'skip'),
                    coalesce((select max(ms)::text from time_0124), '-'),
                    coalesce((select check_name from time_0124 where ms is not null order by ms desc, ord limit 1), '-'))) x
order by ord;
drop table if exists time_0124;
reset role;
