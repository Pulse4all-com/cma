-- =============================================================================================
-- tools/perf/active-present-breakdown.sql: where the live present of Customers → Active's tiles spends its time (173's
-- E5: 258 ms at 06:54 and 717 ms at 08:10 in prod on 12 November 2026, against 400 ms), in stages, and what the same
-- answer costs when the present is read from the stored take instead
-- =============================================================================================
-- A diagnostic, not a migration: it reads only (one transaction, rolled back; its results sit in a temporary table).
-- Run by Martin in his own terminal, as his own IAM login, after 174_active_refresh_quiet.sql, at the hour to be
-- measured (the busy hour is the one that counts for E5's budget):
--
--   cd ~/cma && cma_db prod && psql "$PGCONN" -X -f tools/perf/active-present-breakdown.sql > /tmp/active-present-breakdown-prod.txt 2>&1
--
-- Another tenant: add  -v tenant_slug=<slug>  (the default is pulse4all-subscriptions).
-- The other order: add  -v first=take  (N2 before N1; the default times the live path first). The path timed first
-- warms the cache for the second: where the two orders disagree, the second run of each is the number to read.
-- Every stage runs nine times on this connection as the application's role: the first call (planned for the call),
-- and the best, the median and the worst of the seventh to ninth (the plan a pooled connection keeps; 173's E5 reads
-- the best, a busy hour shows in the worst). Stages:
--   N1  cma.active_now_of, the present read live: 173's E5, the tiles' read as the page calls it while the tenant's
--       setting active.present_source is live (the default)
--   N2  cma.active_now_of, the present read from the stored take: the tiles' read while the setting is take (addition
--       0009n): the same answer of the take's moment, the page saying "As of". The two rows of one run, at the same
--       hour, are what Martin chooses the setting from: N1 within 400 ms keeps live; else take
--   P1  cma.active_present_of alone (the live rows: the subscriptions, their store customer, its segment)
--   P2  cma.active_present_stored_of alone (the same rows from the take)
--   P3  cma.flash_subscription_stores_of (the subscriptions' connections to their stores)
--   M1  the stored month ends the tiles' sparklines and changes read (cma.active_month)
--   F1  cma.active_fx_of (the exchange rates of the amounts)
-- Without a stored take N2, P2 and M1 read nothing (the header row says when the take was computed).
-- Then the plan of the live rows (P1) with its buffers, from the function's own statement (the function is not inlined,
-- so its call shows no plan). No lock but the reads' own; nothing is written.
-- Output: the tenant's id, row counts, milliseconds and one plan (conditions and constants, never a row's content).
-- =============================================================================================
\set ON_ERROR_STOP on
\pset pager off
\if :{?tenant_slug}
\else
  \set tenant_slug pulse4all-subscriptions
\endif
\if :{?first}
\else
  \set first live
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
select :'tenant_id' as tenant_id, now() as measured_at, current_setting('server_version') as server_version,
       exists (select 1 from cma.schema_migration m where m.version = '0009m') as has_0009m,
       cma.setting_of(:'tenant_id', 'active.present_source') as present_source_now,
       (select k.computed_at from cma.active_take k where k.tenant_id = :'tenant_id') as take_computed_at;

create temporary table present_breakdown (ord integer, stage text, what text, rows bigint, first_ms numeric, kept_ms numeric,
                                          median_ms numeric, worst_ms numeric, run_order integer) on commit drop;
select set_config('tool.first', :'first', true) as timed_first;
grant select, insert on present_breakdown to cma_app;
select set_config('app.tenant_id', :'tenant_id', true) as tenant;
set local role cma_app;

do $$
declare
  v_tenant uuid := current_setting('app.tenant_id')::uuid;
  r record;
  v_t0 timestamptz; v_ms numeric; v_first numeric; v_late numeric[]; n bigint; v_run integer := 0;
begin
  if current_setting('tool.first') not in ('live', 'take') then
    raise exception 'first is live or take, not %', current_setting('tool.first');
  end if;
  for r in
    select * from (values
      (1, 'N1', 'cma.active_now_of, the present live (active.present_source = live; 173''s E5)',
          format('select cma.active_now_of(%L, null, null, null, now(), false)::text as x offset 0', v_tenant)),
      (2, 'N2', 'cma.active_now_of, the present from the stored take (active.present_source = take)',
          format('select cma.active_now_of(%L, null, null, null, now(), true)::text as x offset 0', v_tenant)),
      (3, 'P1', 'cma.active_present_of (the live rows)', format('select y.subscription_id as x from cma.active_present_of(%L) y', v_tenant)),
      (4, 'P2', 'cma.active_present_stored_of (the take''s rows)', format('select y.subscription_id as x from cma.active_present_stored_of(%L) y', v_tenant)),
      (5, 'P3', 'cma.flash_subscription_stores_of', format('select y.connection_id as x from cma.flash_subscription_stores_of(%L) y', v_tenant)),
      (6, 'M1', 'the stored month ends (cma.active_month)', format('select y.at_end as x from cma.active_month y where y.tenant_id = %L', v_tenant)),
      (7, 'F1', 'cma.active_fx_of', format('select cma.active_fx_of(%L)::text as x offset 0', v_tenant))
    ) v(ord, stage, what, q)
    order by case when current_setting('tool.first') = 'take' and v.ord in (1, 2) then 3 - v.ord else v.ord end
  loop
    v_first := null; v_late := '{}'; v_run := v_run + 1;
    for i in 1 .. 9 loop
      v_t0 := clock_timestamp();
      execute 'select count(z.x) from (' || r.q || ') z' into n;
      v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
      if i = 1 then v_first := v_ms; end if;
      if i > 6 then v_late := v_late || v_ms; end if;
    end loop;
    insert into present_breakdown
    select r.ord, r.stage, r.what, n, v_first, min(x), percentile_disc(0.5) within group (order by x), max(x), v_run
    from unnest(v_late) x;
  end loop;
end
$$;

\echo
\echo ==== The stages: rows, the first call and the best, median and worst of the seventh to ninth, in milliseconds ====
select stage, run_order, what, rows, first_ms, kept_ms as best_of_calls_7_to_9_ms, median_ms as median_of_7_to_9_ms,
       worst_ms as worst_of_7_to_9_ms
from present_breakdown order by ord;

\echo
\echo ==== The plan of the live rows (P1): the statement of cma.active_present_of as 174 holds it, with this tenant ====
explain (analyze, buffers)
with s as materialized (
  select cma.flash_holding_statuses_of(:'tenant_id') as holding, cma.flash_active_statuses_of(:'tenant_id') as paying,
         cma.flash_list_of(cma.setting_of(:'tenant_id', 'crm.customer_segments')) as segments,
         array(select lower(x) from unnest(cma.flash_list_of(cma.setting_of(:'tenant_id', 'crm.customer_segments'))) with ordinality u(x, o)
               order by o) as segments_lower
), sm as materialized (
  select * from cma.flash_subscription_stores_of(:'tenant_id')
), s0 as materialized (
  select x.id, x.connection_id, x.customer_source_id, x.status, x.currency,
         x.amount_per_cycle * cma.active_month_factor_of(x.billing_interval, x.billing_interval_count) as monthly_amount,
         x.status = any ((select s.paying from s)::text[]) as is_paying
  from cma.subscription x
  where x.tenant_id = :'tenant_id' and x.source_deleted_at is null and x.status = any ((select s.holding from s)::text[])
)
select count(x.id), count(c.id),
       count(case when c.id is null then 'unknown'
                  else coalesce(cma.flash_segment_of(k.segment, (select s.segments from s), (select s.segments_lower from s)), 'unknown') end)
from s0 x
left join sm on sm.connection_id = x.connection_id
left join cma.commerce_customer c
  on c.tenant_id = :'tenant_id' and c.connection_id = sm.store_connection_id and c.source_id = x.customer_source_id
 and c.source_deleted_at is null
left join cma.crm_contact k
  on k.tenant_id = c.tenant_id and k.connection_id = c.crm_connection_id and k.source_id = c.crm_contact_source_id
 and k.source_deleted_at is null;

rollback;
