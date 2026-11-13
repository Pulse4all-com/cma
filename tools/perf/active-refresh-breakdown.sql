-- =============================================================================================
-- tools/perf/active-refresh-breakdown.sql: where the refresh of Customers → Active's stored take spends its time
-- (addition 0009l; Martin's prod run of 173 on 12 November 2026: E4 56 s against 15 s)
-- =============================================================================================
-- A diagnostic, not a migration: it measures and writes nothing that stays. Everything runs inside a subtransaction that
-- is always rolled back (the refreshes it times write the take's tables; none of that is kept), and the transaction
-- around it is rolled back too. Run by Martin in his own terminal, as his own IAM login, after 172:
--
--   cd ~/cma && cma_db prod && psql "$PGCONN" -X -f tools/perf/active-refresh-breakdown.sql > /tmp/active-refresh-breakdown-prod.txt 2>&1
--
-- The tenant is picked by slug (psql variable tenant_slug, default pulse4all-subscriptions; another one with
-- -v tenant_slug=<slug>). The reads and the refreshes run as the application (role cma_app, the tenant in
-- app.tenant_id, acting as the tenant's scheduler, the system user the job runs as), under row-level security.
-- Output: ids of the tenant and the acting user, stage names, counts and milliseconds only; no customer's row, id,
-- amount or name is selected into the output. A prod output is never committed to records/ before
-- node tools/check-records.mjs records/<dir> passes (CLAUDE.md, Git and release).
--
-- It holds the refresh's advisory lock while it runs, as a refresh does: the job's run in that time answers "running"
-- and takes the next minute (the job is not deployed in prod yet). The whole run stops itself at 240 s
-- (statement_timeout); a stage is timed twice (the best of two) while the run is younger than 110 s, once after that,
-- and not at all once the run is past 200 s (the runs column says which: 2, 1 or 0 with "skipped"). The documents come
-- last (no filter first, then the markets, the segments, the channels), so a long run names the stages it did not reach.
--
-- Parts, in the order of the output
--   V  the volumes, counts only: subscriptions, store customers, order deals and first orders in the attribution's
--      window, the stored take's rows after the first refresh (base, customers, spells, month ends, cohorts, documents)
--   R  the refresh as a whole, as cma.active_refresh_of runs it: forced (everything written again: 173's E4), forced
--      once more (the same again on warm caches), and due but quiet (a take six minutes old, nothing changed: what the
--      job does every five minutes), each with the rows it reports
--   B  the base read taken apart, each a count over the function as the refresh calls it: without channel and payment
--      state, with the payment state, with the channel (cma.first_orders_of inside), with both (the refresh's own
--      call); beside them cma.first_orders_history_start_of, cma.first_orders_of over the attribution's window,
--      cma.subscription_payment_state_of and cma.flash_customer_figures_of alone
--   H  the history from the stored rows: the spells (cma.active_spells_from), the three month cubes (customers,
--      subscriptions, amounts), the customers per currency at two month ends, Flash's churn of 30 days, the two cohort
--      cubes (month, quarter), and the history key's digest
--   C  the per-customer rows: the statement that turns the stored base into one row per store customer, and two of its
--      parts alone (the Customer age per customer, the amounts per currency)
--   K  Kaplan–Meier from the stored spells: all spells, per segment and per channel (cma.active_km_json), and the
--      cohort part of a document (month and quarter, no filter)
--   D  each stored document computed once more: above the fold (cma.active_top_body_of) and below it
--      (cma.active_rest_body_of), without a filter and under each market, segment and acquisition channel the refresh
--      stores (the filter's value in the stage's name: a market code, a segment code, a channel), and their sum
--   W  what the writes cost: the forced refresh less the sum of its reads above (an estimate, said as such)
-- =============================================================================================
\set ON_ERROR_STOP on
\pset pager off
\if :{?tenant_slug}
\else
  \set tenant_slug pulse4all-subscriptions
\endif

begin;
set local statement_timeout = '240s';
set local lock_timeout = '2s';
set local role cma_owner;

\echo
\echo ==== Context ====
select (select t.id from cma.tenant t where t.slug = :'tenant_slug') as tenant_id
\gset
\if :{?tenant_id}
\else
  \echo no tenant with this slug: nothing measured
  rollback;
  \quit
\endif
select (select m.version from cma.schema_migration m where m.version = '0009l') as has_0009l
\gset
\if :{?has_0009l}
\else
  \echo addition 0009l (172_active_customers.sql) has not run in this database: nothing measured
  rollback;
  \quit
\endif
select set_config('app.tenant_id', :'tenant_id', true) as tenant;
select (select u.id from cma.app_user u
        where u.tenant_id = :'tenant_id' and u.kind = 'system' and u.email = 'scheduler@system.invalid' and u.status = 'active'
        order by u.created_at, u.id limit 1) as user_id
\gset
\if :{?user_id}
\else
  \echo the tenant has no scheduler user (cma.ensure_scheduler_user): nothing measured
  rollback;
  \quit
\endif
select :'tenant_id' as tenant_id, :'user_id' as acting_user_id, current_setting('server_version') as server_version,
       (select d.datcollate from pg_database d where d.datname = current_database()) as collation,
       (select to_char(t.computed_at, 'YYYY-MM-DD HH24:MI') from cma.active_take t where t.tenant_id = :'tenant_id') as stored_take_of;

drop table if exists pg_temp.active_refresh_breakdown;
create temporary table active_refresh_breakdown (ord integer, part text, stage text, runs integer, best_ms numeric, rows bigint, note text);
grant select, insert on pg_temp.active_refresh_breakdown to cma_app;
select set_config('breakdown.tenant', :'tenant_id', true) as measured_tenant;

-- from here on as the application, acting as the tenant's scheduler
select set_config('app.user_id', :'user_id', true) as acting_user;
set local role cma_app;

do $$
declare
  v_t      uuid := current_setting('breakdown.tenant')::uuid;
  v_start  timestamptz := clock_timestamp();
  v_now    timestamptz := now();
  v_zone   text := (select t.timezone from cma.tenant t where t.id = v_t);
  v_today  date;
  v_month  date;
  v_prev   date;
  v_year   date;
  v_first  date;
  v_attr   date;
  v_ages   integer[] := cma.flash_bounds_of(cma.setting_of(v_t, 'customers.cohort_ages_months'));
  v_segs   text[] := cma.flash_list_of(cma.setting_of(v_t, 'crm.customer_segments'));
  v_out    text[] := '{}';          -- the rows of the result, written after the rollback: ord, part, stage, runs, ms, rows, note
  v_ord    integer := 0;
  t0       timestamptz;
  ms       numeric;
  best     numeric;
  n        bigint;
  j        jsonb;
  r        record;
  f        record;
  v_runs   integer;
  v_reads  numeric := 0;
  v_forced numeric;
  v_docs   numeric := 0;
begin
  v_today := (v_now at time zone v_zone)::date;
  v_month := date_trunc('month', v_today)::date;
  v_prev := (v_month - interval '1 month')::date;
  v_year := (v_month - interval '13 months')::date;
  v_first := (v_month - make_interval(months => cma.setting_of(v_t, 'customers.history_months')::integer))::date;
  v_attr := (select h.history_start from cma.first_orders_history_start_of(v_t) h);
  begin
    -- ---- V. the volumes behind the stages (counts only) ----
    for r in
      select * from (values
        (1, 'subscriptions (not deleted)', format('select count(*) from cma.subscription x where x.tenant_id = %L and x.source_deleted_at is null', v_t)),
        (2, 'subscription events', format('select count(*) from cma.subscription_event x where x.tenant_id = %L', v_t)),
        (3, 'store customers (not deleted)', format('select count(*) from cma.commerce_customer x where x.tenant_id = %L and x.source_deleted_at is null', v_t)),
        (4, 'store orders', format('select count(*) from cma.commerce_order x where x.tenant_id = %L', v_t)),
        (5, 'devices in the asset register', format('select count(*) from cma.device x where x.tenant_id = %L and x.source_deleted_at is null', v_t)),
        (6, 'days in the attribution''s window', format('select %L::date - %L::date', v_today, coalesce(v_attr, v_today)))) v(o, stage, q)
      order by o
    loop
      execute r.q into n;
      v_ord := v_ord + 1;
      v_out := v_out || array[v_ord::text, 'V', r.stage, null, null, n::text, null];
    end loop;

    -- ---- R. the refresh as a whole ----
    t0 := clock_timestamp();
    j := cma.active_refresh_of(v_t, true, v_now);
    v_forced := round(extract(epoch from clock_timestamp() - t0) * 1000, 1);
    v_ord := v_ord + 1;
    v_out := v_out || array[v_ord::text, 'R', 'refresh, forced: everything written again (173''s E4)', '1', v_forced::text, (j ->> 'rows'),
                            format('refreshed %s%s; base %s, customers %s, history %s, documents %s', j ->> 'refreshed', coalesce(' (' || (j ->> 'reason') || ')', ''),
                                   j ->> 'base_rows', j ->> 'customer_rows', j ->> 'history_rows', j ->> 'document_rows')];
    if coalesce((j ->> 'refreshed')::boolean, false) then
      -- once more on warm caches, unless the first took so long that a second would eat the run's 240 s
      if v_forced < 30000 then
        t0 := clock_timestamp();
        j := cma.active_refresh_of(v_t, true, v_now);
        ms := round(extract(epoch from clock_timestamp() - t0) * 1000, 1);
        v_forced := least(v_forced, ms);
        v_ord := v_ord + 1;
        v_out := v_out || array[v_ord::text, 'R', 'refresh, forced once more (warm)', '1', ms::text, (j ->> 'rows'),
                                format('base %s, customers %s, history %s, documents %s', j ->> 'base_rows', j ->> 'customer_rows', j ->> 'history_rows', j ->> 'document_rows')];
      else
        v_ord := v_ord + 1;
        v_out := v_out || array[v_ord::text, 'R', 'refresh, forced once more (warm)', '0', null, null, 'skipped: the first took over 30 s'];
      end if;
      -- a take six minutes old with nothing changed: what the job's run every five minutes does
      execute format('update cma.active_take t set computed_at = %L::timestamptz - interval ''6 minutes'' where t.tenant_id = %L', v_now, v_t);
      t0 := clock_timestamp();
      j := cma.active_refresh_of(v_t, false, v_now);
      ms := round(extract(epoch from clock_timestamp() - t0) * 1000, 1);
      v_ord := v_ord + 1;
      v_out := v_out || array[v_ord::text, 'R', 'refresh, due and quiet: a take six minutes old, nothing changed (the job''s run)', '1', ms::text, (j ->> 'rows'),
                              format('refreshed %s%s; base %s, customers %s, history %s, documents %s', j ->> 'refreshed', coalesce(' (' || (j ->> 'reason') || ')', ''),
                                     j ->> 'base_rows', j ->> 'customer_rows', j ->> 'history_rows', j ->> 'document_rows')];
    end if;

    -- ---- the stored take's volumes, now that a take is there (inside this subtransaction) ----
    for r in
      select * from (values
        (1, 'take: base rows (subscriptions)', format('select count(*) from cma.active_base x where x.tenant_id = %L', v_t)),
        (2, 'take: customers', format('select count(*) from cma.active_customer x where x.tenant_id = %L', v_t)),
        (3, 'take: active customers', format('select count(*) from cma.active_customer x where x.tenant_id = %L and x.is_active', v_t)),
        (4, 'take: customers with a known acquisition channel', format('select count(*) from cma.active_customer x where x.tenant_id = %L and x.channel <> ''unknown''', v_t)),
        (5, 'take: spells', format('select count(*) from cma.active_spell x where x.tenant_id = %L', v_t)),
        (6, 'take: month-end rows', format('select count(*) from cma.active_month x where x.tenant_id = %L', v_t)),
        (7, 'take: cohort rows', format('select count(*) from cma.active_cohort x where x.tenant_id = %L', v_t)),
        (8, 'take: documents', format('select count(*) from cma.active_document x where x.tenant_id = %L', v_t)),
        (9, 'take: documents'' size in kB', format('select coalesce(sum(pg_column_size(x.doc)), 0) / 1024 from cma.active_document x where x.tenant_id = %L', v_t))) v(o, stage, q)
      order by o
    loop
      execute r.q into n;
      v_ord := v_ord + 1;
      v_out := v_out || array[v_ord::text, 'V', r.stage, null, null, n::text, null];
    end loop;

    -- ---- B, H, C, K: the stages, each a statement that answers one count; the best of two while the run is young ----
    for r in
      select * from (values
        ('B', 10, true, 'base read, no channel, no payment state', format('select count(*) from cma.active_base_of(%L, %L, false, null, false)', v_t, v_now)),
        ('B', 11, false, 'base read with the payment state', format('select count(*) from cma.active_base_of(%L, %L, false, null, true)', v_t, v_now)),
        ('B', 12, false, 'base read with the channel (cma.first_orders_of inside)', format('select count(*) from cma.active_base_of(%L, %L, true, %L, false)', v_t, v_now, v_attr)),
        ('B', 13, false, 'base read with both: the refresh''s own call', format('select count(*) from cma.active_base_of(%L, %L, true, %L, true)', v_t, v_now, v_attr)),
        ('B', 14, false, 'cma.first_orders_history_start_of', format('select count(*) from cma.first_orders_history_start_of(%L)', v_t)),
        ('B', 15, false, 'cma.first_orders_of over every order deal (the refresh''s read since 0009n): order deals', format('select count(*) from cma.first_orders_of(%L, ''-infinity''::timestamptz, %L)', v_t, v_now)),
        ('B', 16, false, 'of them first orders', format('select count(*) from cma.first_orders_of(%L, ''-infinity''::timestamptz, %L) o where o.kind = ''first''', v_t, v_now)),
        ('B', 17, false, 'cma.subscription_payment_state_of', format('select count(*) from cma.subscription_payment_state_of(%L)', v_t)),
        ('B', 18, false, 'cma.flash_customer_figures_of (every customer)', format('select count(*) from cma.flash_customer_figures_of(%L)', v_t)),
        ('H', 20, true, 'history key: the digest of the stored base', format($q$select length(md5(coalesce(string_agg(md5(concat_ws('|', x.subscription_id, x.customer_id, x.market, x.segment, x.channel, x.started_at, x.ended_at, x.in_history, x.customer_start, x.currency, x.monthly_amount, x.is_holding, x.is_paying)), '' order by x.subscription_id), ''))) from cma.active_base x where x.tenant_id = %L$q$, v_t)),
        ('H', 21, true, 'spells (cma.active_spells_from) joined to their customers', format($q$select count(*) from (select array_agg(b.customer_id::text) as k, array_agg(b.started_at) as s, array_agg(b.ended_at) as e from cma.active_base b where b.tenant_id = %1$L and b.customer_id is not null and b.in_history) a cross join lateral cma.active_spells_from(a.k, a.s, a.e) x join cma.active_customer c on c.tenant_id = %1$L and c.customer_id = x.key::uuid$q$, v_t)),
        ('H', 22, true, 'month cube: customers (from the spells)', format($q$select count(*) from (select array_agg(sp.market) as a, array_agg(sp.segment) as b, array_agg(sp.channel) as c, array_agg(1::numeric) as w, array_agg(sp.spell_start) as s, array_agg(sp.spell_end) as e from cma.active_spell sp where sp.tenant_id = %L) a cross join lateral cma.active_month_cube_from(a.a, a.b, a.c, a.w, a.s, a.e, %L, %L) x$q$, v_t, v_zone, v_now)),
        ('H', 23, true, 'month cube: subscriptions (from the base)', format($q$select count(*) from (select array_agg(b.market) as a, array_agg(b.segment) as b, array_agg(b.channel) as c, array_agg(1::numeric) as w, array_agg(b.started_at) as s, array_agg(b.ended_at) as e from cma.active_base b where b.tenant_id = %L and b.in_history) a cross join lateral cma.active_month_cube_from(a.a, a.b, a.c, a.w, a.s, a.e, %L, %L) x$q$, v_t, v_zone, v_now)),
        ('H', 24, true, 'month cube: amounts (from the base)', format($q$select count(*) from (select array_agg(b.market) as a, array_agg(b.segment) as b, array_agg(b.channel || '~' || b.currency) as c, array_agg(b.monthly_amount) as w, array_agg(b.started_at) as s, array_agg(b.ended_at) as e from cma.active_base b where b.tenant_id = %L and b.in_history and b.currency is not null and b.monthly_amount is not null and (not b.is_holding or b.is_paying)) a cross join lateral cma.active_month_cube_from(a.a, a.b, a.c, a.w, a.s, a.e, %L, %L) x$q$, v_t, v_zone, v_now)),
        ('H', 25, true, 'customers per currency at two month ends', format($q$select count(*) from (select distinct x.m, b.market, b.segment, b.channel, b.currency, b.customer_id from cma.active_base b cross join (values (%2$L::date, %3$L::date::timestamp at time zone %5$L), (%4$L::date, (%4$L::date + interval '1 month')::timestamp at time zone %5$L)) x(m, at) where b.tenant_id = %1$L and b.customer_id is not null and b.in_history and b.currency is not null and b.started_at < x.at and (b.ended_at is null or b.ended_at >= x.at)) q$q$, v_t, v_prev, v_month, v_year, v_zone)),
        ('H', 26, true, 'Flash''s churn of the last 30 business dates (cma.flash_churn_of) with the base', format($q$select count(*) from cma.flash_churn_of(%1$L, %2$L::date - 29, %2$L::date) x left join cma.active_base b on b.tenant_id = %1$L and b.subscription_id = x.subscription_id$q$, v_t, v_today)),
        ('H', 27, true, 'cohort cube: by month', format($q$select count(*) from (select array_agg(sp.customer_id::text) as k, array_agg(sp.market) as a, array_agg(sp.segment) as b, array_agg(sp.channel) as c, array_agg(sp.customer_start) as cs, array_agg(sp.spell_start) as s, array_agg(sp.spell_end) as e from cma.active_spell sp where sp.tenant_id = %L) a cross join lateral cma.active_cohort_cube_from(a.k, a.a, a.b, a.c, a.cs, a.s, a.e, %L::integer[], 'month', %L, %L) x$q$, v_t, v_ages, v_zone, v_now)),
        ('H', 28, true, 'cohort cube: by quarter', format($q$select count(*) from (select array_agg(sp.customer_id::text) as k, array_agg(sp.market) as a, array_agg(sp.segment) as b, array_agg(sp.channel) as c, array_agg(sp.customer_start) as cs, array_agg(sp.spell_start) as s, array_agg(sp.spell_end) as e from cma.active_spell sp where sp.tenant_id = %L) a cross join lateral cma.active_cohort_cube_from(a.k, a.a, a.b, a.c, a.cs, a.s, a.e, %L::integer[], 'quarter', %L, %L) x$q$, v_t, v_ages, v_zone, v_now)),
        ('C', 30, true, 'per-customer rows: the stored base into one row per store customer', format($q$with b as materialized (select * from cma.active_base x where x.tenant_id = %1$L and x.customer_id is not null), amt as (select q.customer_id, q.currency, q.amount, row_number() over (partition by q.customer_id order by q.amount desc, q.currency) as rn from (select b.customer_id, b.currency, sum(b.monthly_amount) as amount from b where b.is_holding and b.is_paying and b.currency is not null and b.monthly_amount is not null group by 1, 2) q), oth as (select o.customer_id, jsonb_object_agg(o.currency, round(o.amount, 2)) as j from amt o where o.rn > 1 group by 1), n as materialized (select distinct on (b.customer_id) b.customer_id, cma.flash_age_months_of(b.customer_start, %2$L, %3$L::date) as age_months, a.currency, a.amount, coalesce(oth.j, '{}'::jsonb) as other_amounts from b left join amt a on a.customer_id = b.customer_id and a.rn = 1 left join oth on oth.customer_id = b.customer_id order by b.customer_id) select count(*) from n$q$, v_t, v_zone, v_today)),
        ('C', 31, false, 'of it: the Customer age in whole months per customer (cma.flash_age_months_of)', format($q$select count(cma.flash_age_months_of(c.customer_start, %2$L, %3$L::date)) from cma.active_customer c where c.tenant_id = %1$L$q$, v_t, v_zone, v_today)),
        ('C', 32, false, 'of it: a customer''s amounts per currency, ranked', format($q$select count(*) from (select q.customer_id, row_number() over (partition by q.customer_id order by q.amount desc, q.currency) from (select b2.customer_id, b2.currency, sum(b2.monthly_amount) as amount from cma.active_base b2 where b2.tenant_id = %1$L and b2.customer_id is not null and b2.is_holding and b2.is_paying and b2.currency is not null and b2.monthly_amount is not null group by 1, 2) q) a$q$, v_t)),
        ('K', 40, false, 'Kaplan–Meier: all stored spells (cma.active_km_json)', format($q$select count(*) from (select cma.active_km_json(array_agg(sp.len), array_agg(sp.ended)) from cma.active_spell sp where sp.tenant_id = %L) q$q$, v_t)),
        ('K', 41, false, 'Kaplan–Meier: per segment', format($q$select count(*) from (select sp.segment, cma.active_km_json(array_agg(sp.len), array_agg(sp.ended)) from cma.active_spell sp where sp.tenant_id = %L group by 1) q$q$, v_t)),
        ('K', 42, false, 'Kaplan–Meier: per acquisition channel', format($q$select count(*) from (select sp.channel, cma.active_km_json(array_agg(sp.len), array_agg(sp.ended)) from cma.active_spell sp where sp.tenant_id = %L group by 1) q$q$, v_t)),
        ('K', 43, false, 'a document''s cohort part, by month, no filter', format($q$select count(cma.active_cohort_part_of(%L, %L::date, null, null, null, 'month'))$q$, v_t, v_first)),
        ('K', 44, false, 'a document''s cohort part, by quarter, no filter', format($q$select count(cma.active_cohort_part_of(%L, %L::date, null, null, null, 'quarter'))$q$, v_t, v_first))
      ) v(part, o, in_refresh, stage, q)
      order by o
    loop
      -- past 200 s nothing more is started: the run stays under its 240 s
      if clock_timestamp() - v_start > interval '200 seconds' then
        v_ord := v_ord + 1;
        v_out := v_out || array[v_ord::text, r.part, r.stage, '0', null, null, 'skipped: the run is past 200 s'];
        continue;
      end if;
      v_runs := case when clock_timestamp() - v_start < interval '110 seconds' then 2 else 1 end;
      best := null;
      for i in 1 .. v_runs loop
        t0 := clock_timestamp();
        execute r.q into n;
        ms := round(extract(epoch from clock_timestamp() - t0) * 1000, 1);
        best := least(coalesce(best, ms), ms);
      end loop;
      -- what a forced refresh reads once: the base's own call, the history's statements, the customers' statement
      if r.in_refresh or r.o = 13 then v_reads := v_reads + best; end if;
      v_ord := v_ord + 1;
      v_out := v_out || array[v_ord::text, r.part, r.stage, v_runs::text, best::text, n::text, null];
    end loop;

    -- ---- D. each document the refresh stores, computed once more (the stored rows are this subtransaction's) ----
    for f in
      select q.part, q.kind, q.m, q.s, q.c, row_number() over (order by q.kind_ord, q.part desc, coalesce(q.m, q.s, q.c) collate "C") as o
      from (
        select p.part, 'no filter'::text as kind, 0 as kind_ord, null::text as m, null::text as s, null::text as c from (values ('top'), ('rest')) p(part)
        union all
        select p.part, 'market', 1, x.market, null, null
        from (values ('top'), ('rest')) p(part)
        cross join (select distinct d.market from cma.active_document d where d.tenant_id = v_t and d.market <> '') x
        union all
        select p.part, 'segment', 2, null, x.segment, null
        from (values ('top'), ('rest')) p(part)
        cross join (select distinct d.segment from cma.active_document d where d.tenant_id = v_t and d.segment <> '') x
        union all
        select p.part, 'channel', 3, null, null, x.channel
        from (values ('top'), ('rest')) p(part)
        cross join (select distinct d.channel from cma.active_document d where d.tenant_id = v_t and d.channel <> '') x) q
      order by o
    loop
      if clock_timestamp() - v_start > interval '200 seconds' then
        v_ord := v_ord + 1;
        v_out := v_out || array[v_ord::text, 'D', format('document %s: %s%s', case f.part when 'top' then 'above the fold' else 'below the fold' end, f.kind, coalesce(' ' || coalesce(f.m, f.s, f.c), '')),
                                '0', null, null, 'skipped: the run is past 200 s'];
        continue;
      end if;
      v_runs := case when clock_timestamp() - v_start < interval '110 seconds' then 2 else 1 end;
      best := null;
      for i in 1 .. v_runs loop
        t0 := clock_timestamp();
        if f.part = 'top' then j := cma.active_top_body_of(v_t, f.m, f.s, f.c, v_now, true);
        else j := cma.active_rest_body_of(v_t, f.m, f.s, f.c, v_now); end if;
        ms := round(extract(epoch from clock_timestamp() - t0) * 1000, 1);
        best := least(coalesce(best, ms), ms);
      end loop;
      v_docs := v_docs + best;
      v_ord := v_ord + 1;
      v_out := v_out || array[v_ord::text, 'D', format('document %s: %s%s', case f.part when 'top' then 'above the fold' else 'below the fold' end, f.kind,
                                                       coalesce(' ' || coalesce(f.m, f.s, f.c), '')),
                              v_runs::text, best::text, (pg_column_size(j) / 1024)::text, 'rows: the document''s size in kB'];
    end loop;
    v_ord := v_ord + 1;
    v_out := v_out || array[v_ord::text, 'D', 'documents: the sum of the above', null, round(v_docs, 1)::text, null, null];
    v_ord := v_ord + 1;
    v_out := v_out || array[v_ord::text, 'W', 'writes, estimated: the best forced refresh less its reads (base, history, customers, documents)', null,
                            round(v_forced - v_reads - v_docs, 1)::text, null,
                            format('forced %s ms, reads %s ms, documents %s ms; an estimate: a stage alone is not the stage inside the refresh', v_forced, round(v_reads, 1), round(v_docs, 1))];
    v_ord := v_ord + 1;
    v_out := v_out || array[v_ord::text, 'W', 'this script''s own run', null, round(extract(epoch from clock_timestamp() - v_start) * 1000, 1)::text, null, null];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then
      v_ord := v_ord + 1;
      v_out := v_out || array[v_ord::text, '-', 'ran to the end; everything it wrote is rolled back', null, null, null, null];
    when others then
      v_ord := v_ord + 1;
      v_out := v_out || array[v_ord::text, '-', 'stopped early; everything it wrote is rolled back', null, null, null, sqlstate || ': ' || left(sqlerrm, 200)];
  end;
  insert into pg_temp.active_refresh_breakdown (ord, part, stage, runs, best_ms, rows, note)
  select v_out[i]::integer, v_out[i + 1], v_out[i + 2], v_out[i + 3]::integer, v_out[i + 4]::numeric, v_out[i + 5]::bigint, v_out[i + 6]
  from generate_series(1, coalesce(array_length(v_out, 1), 0), 7) as i;
end
$$;

\echo
\echo ==== The breakdown (part: V volumes, R the refresh, B the base read, H the history, C customers, K Kaplan-Meier and cohorts, D documents, W writes) ====
select part, stage, runs, best_ms, rows, note from pg_temp.active_refresh_breakdown order by ord;

\echo
\echo ==== Nothing is left behind: the take as it was before this script ====
select (select count(*) from cma.active_base x where x.tenant_id = current_setting('breakdown.tenant')::uuid) as base_rows,
       (select count(*) from cma.active_document x where x.tenant_id = current_setting('breakdown.tenant')::uuid) as documents,
       (select to_char(t.computed_at, 'YYYY-MM-DD HH24:MI') from cma.active_take t where t.tenant_id = current_setting('breakdown.tenant')::uuid) as stored_take_of;
rollback;
