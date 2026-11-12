-- =============================================================================================
-- tools/perf/active-refresh-stale-plan.sql: why 173's E4 timed the refresh of Customers → Active's take at 56 s where the
-- refresh alone takes 6 s (prod, 12 November 2026): a plan made while the take's tables were empty, run after they filled
-- =============================================================================================
-- A diagnostic, not a migration: it writes nothing that stays (one transaction, always rolled back; the refresh it runs
-- to fill the take's tables is rolled back with it). Run by Martin in his own terminal, as his own IAM login, while the
-- tenant has no stored take yet (after 172, before the first take by hand): with a take stored the tables are not empty
-- and there is nothing to show, which the script says before it stops.
--
--   cd ~/cma && cma_db prod && psql "$PGCONN" -X -f tools/perf/active-refresh-stale-plan.sql > /tmp/active-refresh-stale-plan-prod.txt 2>&1
--
-- What it shows, with the refresh's own second statement (the stored base into one row per store customer), read as a
-- count: (1) its plan as made on the empty tables, every estimate one row, joined by nested loops; (2) the same kept plan
-- run after a forced refresh filled the tables: the nested loops now run over every customer times every amount (173's
-- fixture block makes a connection keep such a plan: it runs the refresh more than five times on a handful of rows);
-- (3) the statement planned again on the filled tables: hash joins, milliseconds. Before 174 (2) is the slow one. After
-- 174_active_refresh_quiet.sql the refresh analyzes the tables it filled, which makes every connection plan again: (2)
-- then reads like (3), which is the fix.
-- Output: the tenant's id, plans (conditions and constants, never a row's content), counts and milliseconds.
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
select (select count(*) from cma.active_base) = 0 as take_empty, (select t.timezone from cma.tenant t where t.id = :'tenant_id') as zone,
       (select c.reltuples from pg_class c where c.oid = 'cma.active_base'::regclass) as planner_rows_of_the_base,
       to_regprocedure('cma.active_take_analyze(uuid)') is not null as has_0009m
\gset
select :'tenant_id' as tenant_id, :'take_empty' as take_tables_empty, :'planner_rows_of_the_base' as planner_rows_of_the_base, :'has_0009m' as has_0009m;
\if :take_empty
\else
  \echo the take's tables hold rows (a take is stored): a plan made now is made for their real size, so there is nothing to show
  rollback;
  \quit
\endif
select set_config('app.tenant_id', :'tenant_id', true) as tenant;
set local role cma_app;

-- the kept plan: the generic one, as a connection holds it after the statement ran more than five times
set local plan_cache_mode = force_generic_plan;
prepare customers_of_the_base (uuid, text) as
  with b as materialized (
    select * from cma.active_base x where x.tenant_id = $1 and x.customer_id is not null
  ), amt as (
    select q.customer_id, q.currency, q.amount, row_number() over (partition by q.customer_id order by q.amount desc, q.currency) as rn
    from (select b.customer_id, b.currency, sum(b.monthly_amount) as amount
          from b where b.is_holding and b.is_paying and b.currency is not null and b.monthly_amount is not null group by 1, 2) q
  ), oth as (
    select o.customer_id, jsonb_object_agg(o.currency, round(o.amount, 2)) as j from amt o where o.rn > 1 group by 1
  ), n as materialized (
    select distinct on (b.customer_id) b.customer_id, cma.flash_age_months_of(b.customer_start, $2, current_date) as age_months,
           a.currency, a.amount, coalesce(oth.j, '{}'::jsonb) as other_amounts
    from b
    left join amt a on a.customer_id = b.customer_id and a.rn = 1
    left join oth on oth.customer_id = b.customer_id
    order by b.customer_id
  )
  select count(*) from n;

\echo
\echo ==== 1. The plan as made on the empty tables (kept from here on) ====
execute customers_of_the_base (:'tenant_id', :'zone');
explain execute customers_of_the_base (:'tenant_id', :'zone');

\echo
\echo ==== The take filled by a forced refresh (rolled back at the end) ====
select r ->> 'refreshed' as refreshed, r ->> 'base_rows' as base_rows, r ->> 'customer_rows' as customer_rows, r ->> 'duration_ms' as refresh_ms,
       coalesce(r ->> 'tables_analyzed', 'none: the refresh of 172') as tables_analyzed
from (select cma.active_refresh_of(:'tenant_id', true) as r) q;

\echo
\echo ==== 2. The kept plan over the filled tables (before 174: nested loops over every row; after 174: planned again) ====
explain (analyze, buffers) execute customers_of_the_base (:'tenant_id', :'zone');

\echo
\echo ==== 3. The statement planned again on the filled tables ====
set local plan_cache_mode = force_custom_plan;
explain (analyze, buffers) execute customers_of_the_base (:'tenant_id', :'zone');

rollback;
