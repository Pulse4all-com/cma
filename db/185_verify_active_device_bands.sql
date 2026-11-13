-- =============================================================================================
-- 185_verify_active_device_bands.sql: verifies addition 0009r, Customers → Active's Devices per active customer in bands
-- =============================================================================================
-- Universal: no seed is assumed, so it runs in dev and in prod. Three kinds of checks:
--   on two throwaway tenants (G, H): a take's customer rows written by hand (invented ids a1 to a10, b1 and b2,
--     invented stores, fixed figures; no person's data), every figure of the new part counted by hand, and the
--     setting's refusals; the whole step is rolled back;
--   on every active tenant with a subscription whose sources are set up (R, D, L, E): the refresh and the document
--     against the definitions 184 replaces, kept here verbatim as pg_temp functions (133's pattern: 174's refresh and
--     172's below-the-fold document), in a step that is always rolled back: the tenant's take is left as it was.
-- Run as your own IAM login, after 184. Output: tenant slugs, counts, band keys and milliseconds only.
-- While it runs: a real tenant's step computes the take twice and holds, until it rolls back, the take's row (a
-- settings save that marks the take stale waits), the tenant's refresh lock (the job answers running) and the analyze's
-- lock on the take's tables. Run it outside the busy hours. Rows written by an ingest during a step: R1 compares two
-- refreshes of two moments and D1 the take with a fresh read; where the inputs' markers moved meanwhile they read skip
-- ("run again"). What the markers do not hold (a CRM deal or call arriving between R1's two refreshes) can still read
-- R1 FAIL: run again.
--
-- Checks
--   S1  the addition is recorded after 0009o; the setting customers.device_bands with its default; the three functions of
--       the list under their new signatures and no longer under the earlier ones, the application's alone; JIT off on
--       the refresh, the document and the list
--   G1  the setting's refusals (CMA04): a bound of 0, a list that does not increase, nine bounds, a bound above 1000, a
--       word, nothing; a list with spaces is kept without them; saving it marks the take stale
--   H1  by hand, no filter: the six bands of 1,2,3,6,11 with a customer at 0 devices and at each band's edges (0, 1, 2,
--       3, 5, 6, 10, 11, 40; a customer that is not active is left out), each band's customers, devices and shares, the
--       average, the median, the customers from the third bound on with their shares
--   H2  by hand: each band's customers and devices per segment and per acquisition channel (two of each and unknown)
--   H3  by hand, under a segment filter and under a market filter: the part of those customers alone; the comparison's
--       row and the markets' column (the share of customers from the third bound on, Devices per customer)
--   H4  by hand, the setting changed to 2,4 inside the step: the bands 0, 1, 2-3, 4+ and the count from the last bound on
--   H5  two tenants: the second tenant's customers are in its own part alone
--   R1  per tenant: a forced refresh of 184 writes the take 174's refresh writes at the same moment, but for the term:
--       the base, the spells, the month ends and the cohorts row for row; the customers' rows but their devices; the
--       documents but the parts that state devices
--   D1  per tenant: a customer's devices in the take are the devices in the field on its holding subscriptions (summed
--       from the stored base), and equal the fresh computation (cma.active_customers_of)
--   D2  per tenant: every stored below-the-fold document equals a fresh computation (T7's pattern), its bands add up to
--       the active customers and to their devices, and it equals 172's document on the same take but for the parts
--       that state devices
--   L1  per tenant: the list under each band of the tenant's setting: the totals add up to the list's total, and a
--       first page holds rows of the band alone, in the order of a plain read of that band
--   L2  per tenant, as a reader of the page (skip without one): a band of another setting is refused by
--       cma.active_rows (CMA04), a band of this one answers, and the file's audit record takes the band (written in
--       the rolled-back step)
--   E1  per tenant, timed: the below-the-fold document computed (no filter) within verify.max_rest_ms (500), the best of
--       three after six calls
--   E2  per tenant, timed: the list's first page under the band that holds the fewest customers, an empty one included
--       (under a page's size the walk cannot stop early: it reads the sort's whole index), within verify.max_list_ms
--       (300), the best of three after six calls
-- Provoke: verify.provoke below. 'true': every check reads FAIL and the verdict says PROVOKED, NOT A PASS. A check's id:
-- that check alone compares with a deliberate difference.
-- Collation: every ordering that feeds a compared text says collate "C". L1's plain read of a band is ordered under the
-- database's own collation on purpose: it must order as the list does (173's T9).
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);                 -- 'true' for every check, or one check's id such as 'H1'
select set_config('verify.max_rest_ms', '500', false);               -- below the fold computed (131's row)
select set_config('verify.max_list_ms', '300', false);               -- a list's first page

drop table if exists pg_temp.verify_0009r;
create temporary table verify_0009r (ord integer, check_name text, result text, detail text);
grant select, insert on pg_temp.verify_0009r to cma_app;

create or replace function pg_temp.v0009r_p(p_id text)
returns boolean
language sql stable
as $$
  select current_setting('verify.provoke') in ('true', p_id)
$$;

-- One check's row: PASS when what was found equals what is expected; provoked, the expectation carries a deliberate difference
create or replace function pg_temp.v0009r_row(p_ord integer, p_id text, p_name text, p_found text, p_expected text)
returns void
language plpgsql
as $$
declare
  v_exp text := case when pg_temp.v0009r_p(p_id) then coalesce(p_expected, '') || ' [provoked: a deliberate difference]' else p_expected end;
begin
  insert into pg_temp.verify_0009r values (p_ord, p_id || ' ' || p_name,
    case when p_found is not distinct from v_exp then 'PASS' else 'FAIL' end,
    case when p_found is not distinct from v_exp then left(coalesce(p_found, 'null'), 600)
         else left('found ' || coalesce(p_found, 'null') || ' | expected ' || coalesce(v_exp, 'null'), 2400) end);
end
$$;

-- The error code a statement raises, or 'ok'
create or replace function pg_temp.v0009r_code(p_sql text)
returns text
language plpgsql
as $$
begin
  execute p_sql;
  return 'ok';
exception
  when others then return sqlstate;
end
$$;

-- A take table's rows of a tenant as one digest: each row as jsonb without the columns named, the rows' digests in "C" order
create or replace function pg_temp.v0009r_digest(p_table text, p_tenant uuid, p_without text[])
returns text
language plpgsql
as $$
declare
  v text;
begin
  execute format($q$select count(*)::text || ':' || md5(coalesce(string_agg(md5((to_jsonb(x) - %L::text[])::text), '' order by md5((to_jsonb(x) - %L::text[])::text) collate "C"), ''))
                    from cma.%I x where x.tenant_id = %L$q$, p_without, p_without, p_table, p_tenant)
  into v;
  return v;
end
$$;

-- A below-the-fold document without the parts that state devices: the part device_customers, the markets' and the
-- total's devices, Devices per customer and the share from the third bound on, and the comparison's two rows of them.
-- Any other document as it is
create or replace function pg_temp.v0009r_plain(p_doc jsonb)
returns jsonb
language sql immutable
as $$
  select case when p_doc ? 'markets' and p_doc ? 'comparison' then
           (p_doc - 'device_customers')
           || jsonb_build_object(
                'markets', (select coalesce(jsonb_agg(m.v - 'devices' - 'devices_per_customer' - 'devices_from_share' order by m.o), '[]'::jsonb)
                            from jsonb_array_elements(p_doc -> 'markets') with ordinality m(v, o)),
                'markets_total', (p_doc -> 'markets_total') - 'devices' - 'devices_per_customer' - 'devices_from_share',
                'comparison', jsonb_set(p_doc -> 'comparison', '{rows}',
                                (select coalesce(jsonb_agg(r.v order by r.o), '[]'::jsonb)
                                 from jsonb_array_elements(p_doc #> '{comparison,rows}') with ordinality r(v, o)
                                 where r.v ->> 'measure' not in ('devices_per_customer', 'devices_from_share'))))
         else p_doc end
$$;

-- A tenant's stored documents as one digest, each without the parts that state devices
create or replace function pg_temp.v0009r_documents(p_tenant uuid)
returns text
language sql
as $$
  select count(*)::text || ':' || md5(coalesce(string_agg(md5(concat_ws('|', d.part, d.market, d.segment, d.channel, pg_temp.v0009r_plain(d.doc)::text)), ''
                                                         order by md5(concat_ws('|', d.part, d.market, d.segment, d.channel, pg_temp.v0009r_plain(d.doc)::text)) collate "C"), ''))
  from cma.active_document d where d.tenant_id = p_tenant
$$;

-- One band of the part device_customers as text: band customers/devices share/devices_share
create or replace function pg_temp.v0009r_bands(p_part jsonb)
returns text
language sql immutable
as $$
  select string_agg(format('%s %s/%s %s/%s', b.v ->> 'band', b.v ->> 'customers', b.v ->> 'devices', coalesce(b.v ->> 'share', '-'), coalesce(b.v ->> 'devices_share', '-')),
                    ', ' order by b.o)
  from jsonb_array_elements(p_part -> 'bands') with ordinality b(v, o)
$$;

-- A band's split as text: band: key customers/devices, in "C" order of the key
create or replace function pg_temp.v0009r_split(p_part jsonb, p_by text)
returns text
language sql immutable
as $$
  select string_agg(format('%s: %s', b.v ->> 'band',
                           coalesce((select string_agg(format('%s %s/%s', e.key, e.value ->> 'customers', e.value ->> 'devices'), ' ' order by e.key collate "C")
                                     from jsonb_each(b.v -> p_by) e), '-')), ', ' order by b.o)
  from jsonb_array_elements(p_part -> 'bands') with ordinality b(v, o)
$$;

-- The part's figures as text
create or replace function pg_temp.v0009r_figures(p_part jsonb)
returns text
language sql immutable
as $$
  select format('customers %s devices %s average %s median %s not linked %s; from %s: %s customers %s, %s devices %s',
                p_part ->> 'customers', p_part ->> 'devices', coalesce(p_part ->> 'average', '-'), coalesce(p_part ->> 'median', '-'), p_part ->> 'not_linked',
                p_part ->> 'from', p_part ->> 'from_customers', coalesce(p_part ->> 'from_share', '-'), p_part ->> 'from_devices', coalesce(p_part ->> 'from_devices_share', '-'))
$$;

-- The definitions 184 replaces, verbatim (133's pattern): 172's below-the-fold document and 174's refresh
create or replace function pg_temp.v0009r_rest_172(p_tenant_id uuid, p_market text, p_segment text, p_channel text, p_now timestamptz)
returns jsonb
language plpgsql stable
as $$
declare
  v_zone         text := (select t.timezone from cma.tenant t where t.id = p_tenant_id);
  v_today        date;
  v_month        date;
  v_first        date;
  v_bands        integer[] := cma.flash_bounds_of(cma.setting_of(p_tenant_id, 'customers.age_months'));
  v_fx           jsonb := cma.active_fx_of(p_tenant_id);
  v_segments     text[] := cma.flash_list_of(cma.setting_of(p_tenant_id, 'crm.customer_segments'));
  v_device_bands integer[] := cma.flash_bounds_of(cma.setting_of(p_tenant_id, 'flash.device_bands'));
  v_doc          jsonb;
begin
  v_today := (p_now at time zone v_zone)::date;
  v_month := date_trunc('month', v_today)::date;
  v_first := (v_month - make_interval(months => cma.setting_of(p_tenant_id, 'customers.history_months')::integer))::date;

  with b0 as (
    -- the stored base (cma.active_base, the refresh's)
    select * from cma.active_base x where x.tenant_id = p_tenant_id
  ), b as materialized (
    select * from b0 x
    where (p_market is null or x.market = p_market) and (p_segment is null or x.segment = p_segment)
      and (p_channel is null or x.channel = p_channel)
  ), c as materialized (
    -- the store customers, one row each, as the refresh stored them (the age as of the take's business date)
    select x.customer_id, x.market, x.segment, x.channel, x.unknown_reason, x.customer_start, x.is_active, x.holding, x.devices,
           x.clv, x.clv_currency, x.age_months as age
    from cma.active_customer x
    where x.tenant_id = p_tenant_id and (p_market is null or x.market = p_market) and (p_segment is null or x.segment = p_segment)
      and (p_channel is null or x.channel = p_channel)
  ), sp as materialized (
    -- their active spells, with the length in whole months as of the take
    select x.customer_id, x.market, x.segment, x.channel, x.customer_start, x.customer_start_on, x.spell_start, x.spell_end, x.len, x.ended
    from cma.active_spell x
    where x.tenant_id = p_tenant_id and (p_market is null or x.market = p_market) and (p_segment is null or x.segment = p_segment)
      and (p_channel is null or x.channel = p_channel)
  ), mcell as materialized (
    -- the stored month ends under the filters; each series below starts with its own first month, as a series computed
    -- from the filtered rows alone would
    select x.kind, x.month, x.market, x.segment, x.channel, x.currency, x.inflow, x.outflow, x.at_end
    from cma.active_month x
    where x.tenant_id = p_tenant_id and (p_market is null or x.market = p_market) and (p_segment is null or x.segment = p_segment)
      and (p_channel is null or x.channel = p_channel)
  ), mc as materialized (
    -- the customers per month end, by market, segment and channel
    select x.month, x.market, x.segment, x.channel, x.inflow, x.outflow, x.at_end
    from mcell x
    where x.kind = 'customers' and x.month >= (select min(y.month) from mcell y where y.kind = 'customers' and y.inflow <> 0)
  ), ma as materialized (
    -- the Monthly recurring amount per month end and currency
    select x.month, x.currency, sum(x.at_end) as at_end
    from mcell x
    where x.kind = 'amount' and x.month >= (select min(y.month) from mcell y where y.kind = 'amount' and (y.inflow <> 0 or y.at_end <> 0))
    group by 1, 2
  ), mt as materialized (
    select mc.month, sum(mc.at_end) as customers, sum(mc.inflow) as inflow, sum(mc.outflow) as outflow from mc group by 1
  ), mchan as (
    select q.month, jsonb_object_agg(q.channel, q.n) as j
    from (select mc.month, mc.channel, sum(mc.inflow) as n from mc group by 1, 2) q group by 1
  ), mam as (
    select ma.month, jsonb_object_agg(ma.currency, round(ma.at_end, 2)) as j,
           bool_and(ma.currency = 'EUR' or coalesce(jsonb_typeof(v_fx -> ma.currency) = 'number', false)) as fx_ok,
           round(sum(cma.active_eur_of(ma.at_end, ma.currency, v_fx)), 2) as eur
    from ma group by 1
  ), g_c as materialized (
    select case when grouping(c.market) = 0 then 'market' when grouping(c.segment) = 0 then 'segment' else 'all' end as dim,
           coalesce(c.market, c.segment, '*') as key,
           count(*) as customers, sum(c.devices) as devices, sum(c.holding) as holding,
           percentile_cont(0.5) within group (order by c.age) as median_age,
           count(*) filter (where c.channel = 'indirect') as indirect, count(*) filter (where c.channel = 'direct') as direct,
           count(*) filter (where c.channel = 'unknown') as unknown_channel,
           count(*) filter (where c.age >= v_bands[1]) as over1, count(*) filter (where c.age >= v_bands[2]) as over2,
           count(*) filter (where c.age >= v_bands[3]) as over3
    from c where c.is_active
    group by grouping sets ((c.market), (c.segment), ())
  ), g_seg as (
    select q.dim, q.key, jsonb_object_agg(q.segment, q.n) as j
    from (select case when grouping(c.market) = 0 then 'market' else 'all' end as dim, coalesce(c.market, '*') as key, c.segment, count(*) as n
          from c where c.is_active group by grouping sets ((c.market, c.segment), (c.segment))) q
    group by 1, 2
  ), g_clv as (
    select q.dim, q.key,
           jsonb_object_agg(q.currency, jsonb_build_object('average', q.average, 'median', q.median, 'per_month', q.per_month, 'customers', q.n)) as j
    from (select case when grouping(c.market) = 0 then 'market' when grouping(c.segment) = 0 then 'segment' else 'all' end as dim,
                 coalesce(c.market, c.segment, '*') as key, c.clv_currency as currency, count(*) as n, round(avg(c.clv), 2) as average,
                 round((percentile_cont(0.5) within group (order by c.clv))::numeric, 2) as median,
                 round(avg(c.clv / greatest(c.age, 1)), 2) as per_month
          from c where c.is_active and c.clv is not null and c.clv_currency is not null
          group by grouping sets ((c.market, c.clv_currency), (c.segment, c.clv_currency), (c.clv_currency))) q
    group by 1, 2
  ), g_sub as (
    select case when grouping(b.market) = 0 then 'market' when grouping(b.segment) = 0 then 'segment' else 'all' end as dim,
           coalesce(b.market, b.segment, '*') as key, count(*) as subscriptions
    from b where b.is_holding
    group by grouping sets ((b.market), (b.segment), ())
  ), g_amt0 as materialized (
    select case when grouping(b.market) = 0 then 'market' when grouping(b.segment) = 0 then 'segment' else 'all' end as dim,
           coalesce(b.market, b.segment, '*') as key, b.currency, sum(b.monthly_amount) filter (where b.is_paying) as amount,
           count(distinct b.customer_id) as customers
    from b where b.is_holding and b.currency is not null
    group by grouping sets ((b.market, b.currency), (b.segment, b.currency), (b.currency))
  ), g_amt as (
    select q.dim, q.key,
           jsonb_object_agg(q.currency, jsonb_build_object('amount', round(coalesce(q.amount, 0), 2), 'customers', q.customers,
                                                           'average', case when q.customers > 0 then round(coalesce(q.amount, 0) / q.customers, 2) end)) as j
    from g_amt0 q group by 1, 2
  ), g_km as materialized (
    select case when grouping(sp.segment) = 0 then 'segment' when grouping(sp.channel) = 0 then 'channel' else 'all' end as dim,
           coalesce(sp.segment, sp.channel, '*') as key, cma.active_km_json(array_agg(sp.len), array_agg(sp.ended)) as j
    from sp
    group by grouping sets ((sp.segment), (sp.channel), ())
  ), g_30 as (
    select case when grouping(sp.market) = 0 then 'market' else 'all' end as dim, coalesce(sp.market, '*') as key,
           count(*) filter (where sp.spell_start > p_now - interval '30 days' and sp.spell_start <= p_now)
           - count(*) filter (where sp.spell_end > p_now - interval '30 days' and sp.spell_end <= p_now) as net
    from sp group by grouping sets ((sp.market), ())
  ), ch as materialized (
    -- Flash's Churn (subscription) over the 30 business dates to the take's, as the refresh stored it per market, segment and channel
    select x.market, x.at_end as n
    from mcell x
    where x.kind = 'churned_30d'
  ), g_ch as (
    select case when grouping(ch.market) = 0 then 'market' else 'all' end as dim, coalesce(ch.market, '*') as key, sum(ch.n) as churned
    from ch group by grouping sets ((ch.market), ())
  ), g_spark as (
    select q.market, jsonb_agg(q.n order by q.month) as j
    from (select mc.market, mc.month, sum(mc.at_end) as n from mc where mc.month >= (v_month - interval '12 months')::date group by 1, 2) q
    group by 1
  ), keys as (
    -- every market of the tenant's stores, with or without a subscription (zeros, never a missing row), and unknown
    -- where a subscription has no store
    select g.key from g_c g where g.dim = 'market' union select g.key from g_sub g where g.dim = 'market'
    union select st.market from cma.commerce_store st where st.tenant_id = p_tenant_id and (p_market is null or st.market = p_market)
  ), stat as materialized (
    -- one row per market, per segment and over all: the present figures as JSON
    select k.dim, k.key,
           jsonb_build_object(
             'customers', coalesce(gc.customers, 0), 'by_segment', coalesce(gs.j, '{}'::jsonb),
             'subscriptions', coalesce(gb.subscriptions, 0), 'devices', coalesce(gc.devices, 0),
             'amounts', coalesce(ga.j, '{}'::jsonb), 'median_age', round(gc.median_age::numeric, 1), 'clv', coalesce(gv.j, '{}'::jsonb),
             'churned_30d', coalesce(gh.churned, 0), 'net_30d', coalesce(g3.net, 0),
             'indirect', coalesce(gc.indirect, 0), 'direct', coalesce(gc.direct, 0), 'unknown_channel', coalesce(gc.unknown_channel, 0),
             'indirect_share', case when coalesce(gc.indirect, 0) + coalesce(gc.direct, 0) > 0
                                    then round(gc.indirect::numeric / (gc.indirect + gc.direct), 4) end,
             'subscriptions_per_customer', case when coalesce(gc.customers, 0) > 0 then round(gc.holding::numeric / gc.customers, 2) end,
             'devices_per_customer', case when coalesce(gc.customers, 0) > 0 then round(gc.devices::numeric / gc.customers, 2) end) as j,
           coalesce(gc.customers, 0) as customers
    from (select 'market'::text as dim, keys.key from keys
          union all select 'segment', x from unnest(v_segments || array['unknown']) x
          union all select 'all', '*') k
    left join g_c gc on gc.dim = k.dim and gc.key = k.key
    left join g_seg gs on gs.dim = k.dim and gs.key = k.key
    left join g_sub gb on gb.dim = k.dim and gb.key = k.key
    left join g_amt ga on ga.dim = k.dim and ga.key = k.key
    left join g_clv gv on gv.dim = k.dim and gv.key = k.key
    left join g_ch gh on gh.dim = k.dim and gh.key = k.key
    left join g_30 g3 on g3.dim = k.dim and g3.key = k.key
  ), cmp_long as (
    select 'customers'::text as measure, null::integer as months, null::text as currency, 10 as ord, s.key, s.customers::numeric as v, null::integer as longest
    from stat s where s.dim = 'segment'
    union all
    select 'share', null, null, 20, s.key,
           case when (select t.customers from stat t where t.dim = 'all') > 0
                then round(s.customers::numeric / (select t.customers from stat t where t.dim = 'all'), 4) end, null
    from stat s where s.dim = 'segment'
    union all
    select 'lifetime_median', null, null, 30, g.key, (g.j ->> 'median')::numeric, (g.j ->> 'longest')::integer from g_km g where g.dim = 'segment'
    union all
    select 'retention', a.months, null, 40, g.key,
           (select (p ->> 'survival')::numeric from jsonb_array_elements(g.j -> 'curve') p
            where (p ->> 'age')::integer = a.months and (p ->> 'at_risk')::integer > 0), null
    from g_km g cross join unnest(v_bands[1:3]) a(months) where g.dim = 'segment'
    union all
    select 'median_age', null, null, 50, s.key, (s.j ->> 'median_age')::numeric, null from stat s where s.dim = 'segment'
    union all
    select x.measure, null, e.key, x.ord, s.key, (e.value ->> x.field)::numeric, null
    from stat s cross join jsonb_each(s.j -> 'clv') e
    cross join (values ('clv_average', 'average', 60), ('clv_median', 'median', 70), ('clv_per_month', 'per_month', 80)) x(measure, field, ord)
    where s.dim = 'segment'
    union all
    select 'average_monthly_amount', null, e.key, 90, s.key, (e.value ->> 'average')::numeric, null
    from stat s cross join jsonb_each(s.j -> 'amounts') e where s.dim = 'segment'
    union all
    select x.measure, null, null, x.ord, s.key, (s.j ->> x.measure)::numeric, null
    from stat s
    cross join (values ('subscriptions_per_customer', 100), ('devices_per_customer', 110), ('indirect_share', 120)) x(measure, ord)
    where s.dim = 'segment'
  ), cmp as (
    select l.measure, l.months, l.currency, min(l.ord) as ord,
           max(l.v) filter (where l.key = v_segments[1]) as a, max(l.v) filter (where l.key = v_segments[2]) as b,
           max(l.v) filter (where l.key = 'unknown') as u,
           max(l.longest) filter (where l.key = v_segments[1]) as a_longest, max(l.longest) filter (where l.key = v_segments[2]) as b_longest,
           max(l.longest) filter (where l.key = 'unknown') as u_longest
    from cmp_long l
    group by 1, 2, 3
  )
  select jsonb_build_object(
    'figures', true,
    'months', (select coalesce(jsonb_agg(jsonb_build_object(
                        'month', mt.month, 'is_now', mt.month = v_month,
                        'inflow', mt.inflow, 'inflow_by_channel', coalesce(mchan.j, '{}'::jsonb), 'outflow', mt.outflow, 'net', mt.inflow - mt.outflow,
                        'amounts', case when mt.month = v_month
                                        then (select coalesce(jsonb_object_agg(q.currency, round(coalesce(q.amount, 0), 2)), '{}'::jsonb)
                                              from g_amt0 q where q.dim = 'all')
                                        else coalesce(mam.j, '{}'::jsonb) end,
                        'eur', case when v_fx = '{}'::jsonb then null
                                    when mt.month = v_month
                                    then (select case when count(*) > 0 and bool_and(q.currency = 'EUR' or coalesce(jsonb_typeof(v_fx -> q.currency) = 'number', false))
                                                      then round(sum(cma.active_eur_of(q.amount, q.currency, v_fx)), 2) end
                                          from g_amt0 q where q.dim = 'all')
                                    when mam.fx_ok then mam.eur end) order by mt.month), '[]'::jsonb)
               from mt
               left join mchan on mchan.month = mt.month
               left join mam on mam.month = mt.month
               where mt.month >= v_first),
    'markets', (select coalesce(jsonb_agg(s.j || jsonb_build_object(
                         'market', s.key,
                         'share', case when (select t.customers from stat t where t.dim = 'all') > 0
                                       then round(s.customers::numeric / (select t.customers from stat t where t.dim = 'all'), 4) end,
                         'spark', coalesce(gs.j, '[]'::jsonb))
                         order by s.customers desc, s.key = 'unknown', s.key), '[]'::jsonb)
                from stat s left join g_spark gs on gs.market = s.key where s.dim = 'market'),
    'markets_total', (select s.j || jsonb_build_object('share', case when s.customers > 0 then 1 end) from stat s where s.dim = 'all'),
    'comparison', jsonb_build_object(
      'a', v_segments[1], 'b', v_segments[2],
      'rows', (select coalesce(jsonb_agg(jsonb_build_object(
                        'measure', c2.measure, 'months', c2.months, 'currency', c2.currency, 'a', c2.a, 'b', c2.b, 'unknown', c2.u,
                        'difference', c2.a - c2.b, 'ratio', case when c2.a > 0 and c2.b > 0 then round(c2.a / c2.b, 2) end,
                        'a_longest', c2.a_longest, 'b_longest', c2.b_longest, 'unknown_longest', c2.u_longest)
                        order by c2.ord, c2.months nulls first, c2.currency nulls first), '[]'::jsonb)
               from cmp c2)),
    'survival', jsonb_build_object(
      'all', (select g.j from g_km g where g.dim = 'all'),
      'segment', (select coalesce(jsonb_agg(g.j || jsonb_build_object('value', g.key)
                                            order by coalesce(array_position(v_segments, g.key), 1000), g.key), '[]'::jsonb)
                  from g_km g where g.dim = 'segment'),
      'channel', (select coalesce(jsonb_agg(g.j || jsonb_build_object('value', g.key)
                                            order by array_position(array['indirect', 'direct', 'unknown'], g.key)), '[]'::jsonb)
                  from g_km g where g.dim = 'channel')),
    'age_bands', (select coalesce(jsonb_agg(jsonb_build_object('band', w.band, 'customers', coalesce(q.n, 0)) order by w.ord), '[]'::jsonb)
                  from (select x.band, x.ord from unnest(cma.flash_age_bands_of(v_bands)) with ordinality x(band, ord)
                        union all
                        select 'unknown', 1000 where exists (select 1 from c where c.is_active and c.age is null)) w
                  left join (select cma.flash_age_band_of(c.age, v_bands) as band, count(*) as n from c where c.is_active group by 1) q
                    on q.band = w.band),
    'age_over', (select coalesce(jsonb_agg(jsonb_build_object('months', x.m, 'customers', x.n,
                                                           'share', case when g.customers > 0 then round(x.n::numeric / g.customers, 4) end)
                                         order by x.m), '[]'::jsonb)
                 from g_c g
                 cross join lateral (values (v_bands[1], g.over1), (v_bands[2], g.over2), (v_bands[3], g.over3)) x(m, n)
                 where g.dim = 'all' and x.m is not null),
    'mix', jsonb_build_object(
      'billing', (select coalesce(jsonb_agg(jsonb_build_object('key', q.billing, 'subscriptions', q.n)
                                            order by array_position(array['monthly', 'yearly', 'other', 'unknown'], q.billing)), '[]'::jsonb)
                  from (select b.billing, count(*) as n from b where b.is_holding group by 1) q),
      'device_band', (select coalesce(jsonb_agg(jsonb_build_object('key', w.band, 'subscriptions', coalesce(q.n, 0)) order by w.ord), '[]'::jsonb)
                      from unnest(cma.flash_count_bands_of(v_device_bands)) with ordinality w(band, ord)
                      left join (select cma.flash_count_band_of(b.devices_in_field, v_device_bands) as band, count(*) as n
                                 from b where b.is_holding group by 1) q on q.band = w.band),
      'model', (select coalesce(jsonb_agg(jsonb_build_object('key', q.model_key, 'name', q.name, 'devices', q.n) order by q.n desc, q.model_key), '[]'::jsonb)
                from (select e.key as model_key, (select m.name from cma.device_model m where m.tenant_id = p_tenant_id and m.key = e.key) as name,
                             sum(e.value::bigint) as n
                      from b cross join jsonb_each_text(coalesce(b.device_models, '{}'::jsonb)) e
                      where b.is_holding
                      group by 1) q),
      'payment_state', (select coalesce(jsonb_agg(jsonb_build_object('key', x.state, 'subscriptions', coalesce(q.n, 0)) order by x.ord), '[]'::jsonb)
                        from (values ('paid', 1), ('in_retry', 2), ('failed', 3), ('paused', 4)) x(state, ord)
                        left join (select b.payment_state, count(*) as n from b group by 1) q on q.payment_state = x.state)),
    'notes', jsonb_build_object(
      'no_amount', (select count(*) from b where b.is_holding and b.is_paying and (b.monthly_amount is null or b.currency is null)),
      'unknown_channel', jsonb_build_object(
        'customers', (select count(*) from c where c.is_active and c.channel = 'unknown'),
        'reasons', (select coalesce(jsonb_object_agg(q.unknown_reason, q.n), '{}'::jsonb)
                    from (select c.unknown_reason, count(*) as n from c where c.is_active and c.channel = 'unknown' and c.unknown_reason is not null
                          group by 1) q))))
  into v_doc;
  return v_doc;
end
$$;

create or replace function pg_temp.v0009r_refresh_174(p_tenant_id uuid, p_force boolean default false, p_now timestamptz default null)
returns jsonb
language plpgsql
as $$
declare
  v_now    timestamptz := coalesce(p_now, clock_timestamp());
  v_t0     timestamptz := clock_timestamp();
  v_zone   text := (select t.timezone from cma.tenant t where t.id = p_tenant_id);
  v_today  date;
  v_month  date;
  v_prev   date;
  v_year   date;
  v_ages   integer[];
  v_segments text[];
  v_every  integer := cma.setting_of(p_tenant_id, 'customers.refresh_minutes')::integer;
  v_set_up boolean;
  v_attr   date;
  v_take   cma.active_take;
  v_found  boolean;
  v_all    boolean;
  v_key    text;
  n_base   integer := 0;
  n_gone   integer := 0;
  n_cust   integer := 0;
  n_hist   integer := 0;
  n_docs   integer := 0;
  v_churn  jsonb;
  n_subs   integer;
  n_active integer;
  v_inputs text;
  n_stats  integer := 0;
begin
  if p_tenant_id is distinct from cma.current_tenant_id() then
    raise exception 'a take is refreshed for the current tenant only' using errcode = 'CMA04';
  end if;
  select * into v_take from cma.active_take t where t.tenant_id = p_tenant_id;
  v_found := found;
  -- a statement, not an expression (as the reads' heads): its plan is made again when the role changes
  select coalesce(cma.flash_source_set_up_of(p_tenant_id, 'commerce'), false) and coalesce(cma.flash_source_set_up_of(p_tenant_id, 'subscriptions'), false)
  into v_set_up;
  if not v_set_up then
    -- nothing to take: a tenant whose sources are not set up holds no rows (the page says Not set up, never zeros).
    -- Under the refresh's lock, so a refresh running beside it cannot leave rows without a take
    if v_found then
      if not pg_try_advisory_xact_lock(cma.active_take_lock_key(p_tenant_id)) then
        return jsonb_build_object('refreshed', false, 'reason', 'running');
      end if;
      delete from cma.active_document x where x.tenant_id = p_tenant_id;
      delete from cma.active_cohort x where x.tenant_id = p_tenant_id;
      delete from cma.active_month x where x.tenant_id = p_tenant_id;
      delete from cma.active_spell x where x.tenant_id = p_tenant_id;
      delete from cma.active_customer x where x.tenant_id = p_tenant_id;
      delete from cma.active_base x where x.tenant_id = p_tenant_id;
      delete from cma.active_take x where x.tenant_id = p_tenant_id;
    end if;
    return jsonb_build_object('refreshed', false, 'reason', 'not_set_up');
  end if;
  if not p_force and v_found and not v_take.stale and v_now - v_take.computed_at < make_interval(mins => v_every) then
    return jsonb_build_object('refreshed', false, 'reason', 'fresh');
  end if;
  if not pg_try_advisory_xact_lock(cma.active_take_lock_key(p_tenant_id)) then
    return jsonb_build_object('refreshed', false, 'reason', 'running');
  end if;
  -- under the lock: the take as it is now (a refresh that committed meanwhile is seen), and after it the settings the
  -- stored rows follow, so every mark counted in this take's row is of a setting read below
  select * into v_take from cma.active_take t where t.tenant_id = p_tenant_id;
  v_found := found;
  v_ages := cma.flash_bounds_of(cma.setting_of(p_tenant_id, 'customers.cohort_ages_months'));
  v_segments := cma.flash_list_of(cma.setting_of(p_tenant_id, 'crm.customer_segments'));
  v_today := (v_now at time zone v_zone)::date;
  v_month := date_trunc('month', v_today)::date;
  v_prev := (v_month - interval '1 month')::date;
  v_year := (v_month - interval '13 months')::date;
  -- everything is written again when asked, on a first take, after a settings change and on a new business date
  v_all := p_force or not v_found or v_take.stale or v_take.business_date is distinct from v_today;

  -- 0. the quiet run (0009m): the inputs' change markers, read before anything is computed (a row that changes after
  --    this read gives the next run another key). The same key as the take's, on the same business date, with no
  --    setting saved since and no force: nothing the take is computed from changed, so the take stands as it is and
  --    only its moment moves. What the markers do not hold (the CRM's deals, calls and emails behind the acquisition
  --    channel, the courtesy calls) is read again at the next change of a marker and at every new business date
  v_inputs := cma.active_inputs_key_of(p_tenant_id);
  if not v_all and v_take.inputs_key is not distinct from v_inputs then
    update cma.active_take t
    set computed_at = v_now, duration_ms = (extract(epoch from clock_timestamp() - v_t0) * 1000)::integer
    where t.tenant_id = p_tenant_id;
    return jsonb_build_object('refreshed', true, 'unchanged', true, 'tables_analyzed', 0, 'base_rows', 0, 'customer_rows', 0, 'history_rows', 0,
                              'document_rows', 0, 'rows', 0,
                              'duration_ms', (extract(epoch from clock_timestamp() - v_t0) * 1000)::integer);
  end if;
  v_attr := (select h.history_start from cma.first_orders_history_start_of(p_tenant_id) h);

  -- 1. the base, row by row: a row that reads the same is not written again; a subscription no longer in it goes
  with n as materialized (
    select * from cma.active_base_of(p_tenant_id, v_now, true, v_attr, true)
  ), chg as materialized (
    -- only the rows that read differently from the stored ones reach the upsert: an upsert locks the row it meets
    -- before it compares, so a quiet refresh would lock and dirty every row it leaves as it is
    select n.subscription_id, n.connection_id, n.source_id, n.store, n.market, n.status, n.is_holding, n.is_paying,
           n.payment_state, n.currency, n.monthly_amount, n.billing, n.devices_in_field, n.started_at, n.ended_at,
           n.in_history, n.left_out, n.customer_id, n.customer_connection_id, n.customer_source_id, n.segment,
           n.crm_connection_id, n.contact_source_id, n.customer_start, n.customer_holding, n.customer_devices, n.clv,
           n.clv_currency, n.channel, n.level, n.unknown_reason, n.first_order_at, n.device_models
    from n
    except
    select a.subscription_id, a.connection_id, a.source_id, a.store, a.market, a.status, a.is_holding, a.is_paying,
           a.payment_state, a.currency, a.monthly_amount, a.billing, a.devices_in_field, a.started_at, a.ended_at,
           a.in_history, a.left_out, a.customer_id, a.customer_connection_id, a.customer_source_id, a.segment,
           a.crm_connection_id, a.contact_source_id, a.customer_start, a.customer_holding, a.customer_devices, a.clv,
           a.clv_currency, a.channel, a.level, a.unknown_reason, a.first_order_at, a.device_models
    from cma.active_base a where a.tenant_id = p_tenant_id
  ), up as (
    insert into cma.active_base as a (tenant_id, subscription_id, connection_id, source_id, store, market, status, is_holding, is_paying,
           payment_state, currency, monthly_amount, billing, devices_in_field, started_at, ended_at,
           in_history, left_out, customer_id, customer_connection_id, customer_source_id, segment,
           crm_connection_id, contact_source_id, customer_start, customer_holding, customer_devices, clv,
           clv_currency, channel, level, unknown_reason, first_order_at, device_models)
    select p_tenant_id, n.* from chg n
    on conflict (tenant_id, subscription_id) do update
      set (connection_id, source_id, store, market, status, is_holding, is_paying, payment_state, currency,
           monthly_amount, billing, devices_in_field, started_at, ended_at, in_history, left_out, customer_id,
           customer_connection_id, customer_source_id, segment, crm_connection_id, contact_source_id, customer_start,
           customer_holding, customer_devices, clv, clv_currency, channel, level, unknown_reason, first_order_at, device_models)
        = (excluded.connection_id, excluded.source_id, excluded.store, excluded.market, excluded.status,
           excluded.is_holding, excluded.is_paying, excluded.payment_state, excluded.currency, excluded.monthly_amount,
           excluded.billing, excluded.devices_in_field, excluded.started_at, excluded.ended_at, excluded.in_history,
           excluded.left_out, excluded.customer_id, excluded.customer_connection_id, excluded.customer_source_id,
           excluded.segment, excluded.crm_connection_id, excluded.contact_source_id, excluded.customer_start,
           excluded.customer_holding, excluded.customer_devices, excluded.clv, excluded.clv_currency, excluded.channel,
           excluded.level, excluded.unknown_reason, excluded.first_order_at, excluded.device_models)
      where (a.*) is distinct from (excluded.*)
    returning 1
  ), gone as (
    delete from cma.active_base a
    where a.tenant_id = p_tenant_id and not exists (select 1 from n where n.subscription_id = a.subscription_id)
    returning 1
  )
  select (select count(*) from up), (select count(*) from gone) into n_base, n_gone;
  -- the take's tables just changed in size (a first take, a tenant's first fill): their statistics follow at once, so
  -- no plan made for a handful of rows is run over thousands (0009m; cma.active_take_analyze)
  if n_base + n_gone > 0 then n_stats := n_stats + cma.active_take_analyze(p_tenant_id); end if;

  -- 2. the customers, row by row, from the base just stored: one row per store customer with the list's columns (a
  --    customer's Monthly recurring amount in its largest currency, the others beside it)
  with b as materialized (
    select * from cma.active_base x where x.tenant_id = p_tenant_id and x.customer_id is not null
  ), amt as (
    select q.customer_id, q.currency, q.amount, row_number() over (partition by q.customer_id order by q.amount desc, q.currency) as rn
    from (select b.customer_id, b.currency, sum(b.monthly_amount) as amount
          from b where b.is_holding and b.is_paying and b.currency is not null and b.monthly_amount is not null group by 1, 2) q
  ), oth as (
    select o.customer_id, jsonb_object_agg(o.currency, round(o.amount, 2)) as j from amt o where o.rn > 1 group by 1
  ), n as materialized (
    select distinct on (b.customer_id) b.customer_id, b.customer_connection_id as connection_id, b.customer_source_id as source_id, b.store,
           b.market, b.segment, b.channel, b.level, b.unknown_reason, b.first_order_at, b.customer_start,
           cma.flash_age_months_of(b.customer_start, v_zone, v_today) as age_months,
           coalesce(b.customer_holding, 0) > 0 as is_active, coalesce(b.customer_holding, 0) as holding, coalesce(b.customer_devices, 0) as devices,
           b.clv, b.clv_currency, b.crm_connection_id, b.contact_source_id, a.currency, a.amount, coalesce(oth.j, '{}'::jsonb) as other_amounts
    from b
    left join amt a on a.customer_id = b.customer_id and a.rn = 1
    left join oth on oth.customer_id = b.customer_id
    order by b.customer_id
  ), chg as materialized (
    select n.customer_id, n.connection_id, n.source_id, n.store, n.market, n.segment, n.channel, n.level, n.unknown_reason,
           n.first_order_at, n.customer_start, n.age_months, n.is_active, n.holding, n.devices, n.clv, n.clv_currency,
           n.crm_connection_id, n.contact_source_id, n.currency, n.amount, n.other_amounts
    from n
    except
    select a.customer_id, a.connection_id, a.source_id, a.store, a.market, a.segment, a.channel, a.level, a.unknown_reason,
           a.first_order_at, a.customer_start, a.age_months, a.is_active, a.holding, a.devices, a.clv, a.clv_currency,
           a.crm_connection_id, a.contact_source_id, a.currency, a.amount, a.other_amounts
    from cma.active_customer a where a.tenant_id = p_tenant_id
  ), up as (
    insert into cma.active_customer as a (tenant_id, customer_id, connection_id, source_id, store, market, segment, channel, level, unknown_reason,
           first_order_at, customer_start, age_months, is_active, holding, devices, clv, clv_currency,
           crm_connection_id, contact_source_id, currency, amount, other_amounts)
    select p_tenant_id, n.* from chg n
    on conflict (tenant_id, customer_id) do update
      set (connection_id, source_id, store, market, segment, channel, level, unknown_reason, first_order_at,
           customer_start, age_months, is_active, holding, devices, clv, clv_currency, crm_connection_id,
           contact_source_id, currency, amount, other_amounts)
        = (excluded.connection_id, excluded.source_id, excluded.store, excluded.market, excluded.segment,
           excluded.channel, excluded.level, excluded.unknown_reason, excluded.first_order_at, excluded.customer_start,
           excluded.age_months, excluded.is_active, excluded.holding, excluded.devices, excluded.clv,
           excluded.clv_currency, excluded.crm_connection_id, excluded.contact_source_id, excluded.currency,
           excluded.amount, excluded.other_amounts)
      where (a.*) is distinct from (excluded.*)
    returning 1
  ), gone as (
    delete from cma.active_customer a
    where a.tenant_id = p_tenant_id and not exists (select 1 from n where n.customer_id = a.customer_id)
    returning 1
  )
  select (select count(*) from up) + (select count(*) from gone) into n_cust;
  if n_cust > 0 then n_stats := n_stats + cma.active_take_analyze(p_tenant_id); end if;

  -- 3. the history (the spells, the month ends, the cohorts): only when what it is computed from changed. Its key is a
  --    digest of the base's columns it reads, with the zone and the cohort ages
  select md5(coalesce(string_agg(md5(concat_ws('|', x.subscription_id, x.customer_id, x.market, x.segment, x.channel, x.started_at, x.ended_at,
                                           x.in_history, x.customer_start, x.currency, x.monthly_amount, x.is_holding, x.is_paying)),
                                 '' order by x.subscription_id), '') || '|' || v_zone || '|' || array_to_string(v_ages, ','))
  into v_key
  from cma.active_base x where x.tenant_id = p_tenant_id;
  if v_all or v_key is distinct from v_take.history_key then
    delete from cma.active_cohort x where x.tenant_id = p_tenant_id;
    delete from cma.active_month x where x.tenant_id = p_tenant_id;
    delete from cma.active_spell x where x.tenant_id = p_tenant_id;

    insert into cma.active_spell (tenant_id, customer_id, market, segment, channel, customer_start, customer_start_on, spell_start, spell_end, len, ended)
    select p_tenant_id, c.customer_id, c.market, c.segment, c.channel, c.customer_start, (c.customer_start at time zone v_zone)::date, x.spell_start, x.spell_end,
           greatest(0, cma.flash_age_months_of(x.spell_start, v_zone, coalesce((x.spell_end at time zone v_zone)::date, v_today))),
           x.spell_end is not null
    from (select array_agg(b.customer_id::text) as k, array_agg(b.started_at) as s, array_agg(b.ended_at) as e
          from cma.active_base b where b.tenant_id = p_tenant_id and b.customer_id is not null and b.in_history) a
    cross join lateral cma.active_spells_from(a.k, a.s, a.e) x
    join cma.active_customer c on c.tenant_id = p_tenant_id and c.customer_id = x.key::uuid;
    get diagnostics n_hist = row_count;

    -- the customers per month end (from the spells), the subscriptions and the amounts (from the base's intervals)
    insert into cma.active_month (tenant_id, kind, month, market, segment, channel, currency, inflow, outflow, at_end)
    select p_tenant_id, 'customers', x.month, x.d1, x.d2, x.d3, '', x.inflow, x.outflow, x.at_end
    from (select array_agg(sp.market) as a, array_agg(sp.segment) as b, array_agg(sp.channel) as c, array_agg(1::numeric) as w,
                 array_agg(sp.spell_start) as s, array_agg(sp.spell_end) as e
          from cma.active_spell sp where sp.tenant_id = p_tenant_id) a
    cross join lateral cma.active_month_cube_from(a.a, a.b, a.c, a.w, a.s, a.e, v_zone, v_now) x
    union all
    select p_tenant_id, 'subscriptions', x.month, x.d1, x.d2, x.d3, '', x.inflow, x.outflow, x.at_end
    from (select array_agg(b.market) as a, array_agg(b.segment) as b, array_agg(b.channel) as c, array_agg(1::numeric) as w,
                 array_agg(b.started_at) as s, array_agg(b.ended_at) as e
          from cma.active_base b where b.tenant_id = p_tenant_id and b.in_history) a
    cross join lateral cma.active_month_cube_from(a.a, a.b, a.c, a.w, a.s, a.e, v_zone, v_now) x
    union all
    -- the Monthly recurring amount: the subscriptions holding then at their amount today; one that holds today without
    -- paying is left out throughout. The currency rides with the channel through the cube's third dimension
    select p_tenant_id, 'amount', x.month, x.d1, x.d2, split_part(x.d3, '~', 1), split_part(x.d3, '~', 2), x.inflow, x.outflow, x.at_end
    from (select array_agg(b.market) as a, array_agg(b.segment) as b, array_agg(b.channel || '~' || b.currency) as c, array_agg(b.monthly_amount) as w,
                 array_agg(b.started_at) as s, array_agg(b.ended_at) as e
          from cma.active_base b
          where b.tenant_id = p_tenant_id and b.in_history and b.currency is not null and b.monthly_amount is not null
            and (not b.is_holding or b.is_paying)) a
    cross join lateral cma.active_month_cube_from(a.a, a.b, a.c, a.w, a.s, a.e, v_zone, v_now) x
    union all
    -- the customers with a subscription in a currency at the two month ends a change line compares with
    select p_tenant_id, 'currency_customers', q.m, q.market, q.segment, q.channel, q.currency, 0, 0, count(*)
    from (select distinct x.m, b.market, b.segment, b.channel, b.currency, b.customer_id
          from cma.active_base b
          cross join (values (v_prev, v_month::timestamp at time zone v_zone),
                             (v_year, (v_year + interval '1 month')::timestamp at time zone v_zone)) x(m, at)
          where b.tenant_id = p_tenant_id and b.customer_id is not null and b.in_history and b.currency is not null
            and b.started_at < x.at and (b.ended_at is null or b.ended_at >= x.at)) q
    group by q.m, q.market, q.segment, q.channel, q.currency
    union all
    -- Flash's Churn (subscription) over the last 30 business dates (the unit economics' one figure, the markets' column):
    -- a churned subscription under its store's market and the base's segment and channel of it
    select p_tenant_id, 'churned_30d', v_month, x.market, coalesce(b.segment, 'unknown'), coalesce(b.channel, 'unknown'), '', 0, 0, count(*)
    from cma.flash_churn_of(p_tenant_id, v_today - 29, v_today) x
    left join cma.active_base b on b.tenant_id = p_tenant_id and b.subscription_id = x.subscription_id
    group by x.market, coalesce(b.segment, 'unknown'), coalesce(b.channel, 'unknown');

    insert into cma.active_cohort (tenant_id, period, cohort, market, segment, channel, age_months, started, still_active, mature)
    select p_tenant_id, g.period, x.cohort, x.d1, x.d2, x.d3, x.age_months, x.started, x.still_active, x.mature
    from (select array_agg(sp.customer_id::text) as k, array_agg(sp.market) as a, array_agg(sp.segment) as b, array_agg(sp.channel) as c,
                 array_agg(sp.customer_start) as cs, array_agg(sp.spell_start) as s, array_agg(sp.spell_end) as e
          from cma.active_spell sp where sp.tenant_id = p_tenant_id) a
    cross join (values ('month'), ('quarter')) g(period)
    cross join lateral cma.active_cohort_cube_from(a.k, a.a, a.b, a.c, a.cs, a.s, a.e, v_ages, g.period, v_zone, v_now) x;
    -- the history's tables were written again: the documents below read them
    n_stats := n_stats + cma.active_take_analyze(p_tenant_id);
  else
    -- the history stays as it was last written: its month ends and cohorts are of that moment (no row they are computed
    -- from changed since; a cohort's maturity is of that moment too, at most a business date old). Flash's churn count
    -- reads the subscriptions' events, which the key does not hold: it is written again at every refresh, where it
    -- reads differently
    select coalesce(jsonb_agg(jsonb_build_object('market', q.market, 'segment', q.segment, 'channel', q.channel, 'n', q.n)), '[]'::jsonb)
    into v_churn
    from (select x.market, coalesce(b.segment, 'unknown') as segment, coalesce(b.channel, 'unknown') as channel, count(*) as n
          from cma.flash_churn_of(p_tenant_id, v_today - 29, v_today) x
          left join cma.active_base b on b.tenant_id = p_tenant_id and b.subscription_id = x.subscription_id
          group by 1, 2, 3) q;
    delete from cma.active_month a
    where a.tenant_id = p_tenant_id and a.kind = 'churned_30d'
      and not exists (select 1 from jsonb_to_recordset(v_churn) n(market text, segment text, channel text, n numeric)
                      where a.month = v_month and n.market = a.market and n.segment = a.segment and n.channel = a.channel);
    insert into cma.active_month as a (tenant_id, kind, month, market, segment, channel, currency, inflow, outflow, at_end)
    select p_tenant_id, 'churned_30d', v_month, n.market, n.segment, n.channel, '', 0, 0, n.n
    from jsonb_to_recordset(v_churn) n(market text, segment text, channel text, n numeric)
    where not exists (select 1 from cma.active_month o
                      where o.tenant_id = p_tenant_id and o.kind = 'churned_30d' and o.month = v_month and o.market = n.market
                        and o.segment = n.segment and o.channel = n.channel and o.currency = '' and o.at_end = n.n)
    on conflict (tenant_id, kind, month, market, segment, channel, currency) do update set at_end = excluded.at_end;
  end if;

  select count(*) filter (where b.is_holding), count(distinct b.customer_id) filter (where coalesce(b.customer_holding, 0) > 0)
  into n_subs, n_active
  from cma.active_base b where b.tenant_id = p_tenant_id;
  -- a first take: its row is there before the documents are computed (they ask whether there is a take). An existing
  -- take's row is left alone until the documents are computed, so a settings save that marks the take stale does not
  -- wait for them
  insert into cma.active_take (tenant_id, computed_at, business_date, duration_ms, history_key, customers, subscriptions, attribution_start, stale, stale_since, inputs_key)
  values (p_tenant_id, v_now, v_today, 0, v_key, n_active, n_subs, v_attr, false, null, v_inputs)
  on conflict (tenant_id) do nothing;

  -- 4. the documents (decision D16), from the rows just stored and as of this take: above the fold and below it,
  --    without a filter and under each single market, segment and acquisition channel. Computed at
  --    every refresh (they also read catalogs and the clock's month), written only where one reads differently
  with f(m, s, c) as (
    select null::text, null::text, null::text
    union all
    select q.market, null, null
    from (select st.market from cma.commerce_store st where st.tenant_id = p_tenant_id
          union select x.market from cma.active_customer x where x.tenant_id = p_tenant_id
          union select x.market from cma.active_base x where x.tenant_id = p_tenant_id) q
    where q.market is not null and q.market <> ''
    union all
    select null, x.segment, null from (select distinct u as segment from unnest(v_segments || array['unknown']) u) x where x.segment <> ''
    union all
    select null, null, x.channel from unnest(array['indirect', 'direct', 'unknown']) x(channel)
  ), n as materialized (
    select 'top'::text as part, coalesce(f.m, '') as market, coalesce(f.s, '') as segment, coalesce(f.c, '') as channel,
           cma.active_top_body_of(p_tenant_id, f.m, f.s, f.c, v_now, true) as doc
    from f
    union all
    select 'rest', coalesce(f.m, ''), coalesce(f.s, ''), coalesce(f.c, ''), cma.active_rest_body_of(p_tenant_id, f.m, f.s, f.c, v_now)
    from f
  ), chg as materialized (
    -- only a document that reads differently is written (and its row locked)
    select n.part, n.market, n.segment, n.channel, n.doc from n
    where not exists (select 1 from cma.active_document a
                      where a.tenant_id = p_tenant_id and a.part = n.part and a.market = n.market and a.segment = n.segment and a.channel = n.channel
                        and a.doc = n.doc)
  ), up as (
    insert into cma.active_document as a (tenant_id, part, market, segment, channel, doc)
    select p_tenant_id, n.part, n.market, n.segment, n.channel, n.doc from chg n
    on conflict (tenant_id, part, market, segment, channel) do update set doc = excluded.doc
    returning 1
  ), gone as (
    delete from cma.active_document a
    where a.tenant_id = p_tenant_id
      and not exists (select 1 from n where n.part = a.part and n.market = a.market and n.segment = a.segment and n.channel = a.channel)
    returning 1
  )
  select (select count(*) from up) + (select count(*) from gone) into n_docs;
  -- the documents' table too (on a first take it was empty at every analyze above)
  if n_docs > 0 then n_stats := n_stats + cma.active_take_analyze(p_tenant_id); end if;
  -- the take's row, last: its moment, and the mark cleared only when no setting was saved since this refresh read the
  -- take (the row is the one committed now: a settings transaction still open is waited for)
  update cma.active_take t
  set computed_at = v_now, business_date = v_today, duration_ms = (extract(epoch from clock_timestamp() - v_t0) * 1000)::integer,
      history_key = v_key, customers = n_active, subscriptions = n_subs, attribution_start = v_attr, inputs_key = v_inputs,
      stale = t.stale_marks is distinct from coalesce(v_take.stale_marks, 0),
      stale_since = case when t.stale_marks is distinct from coalesce(v_take.stale_marks, 0) then t.stale_since end
  where t.tenant_id = p_tenant_id;

  return jsonb_build_object('refreshed', true, 'unchanged', false, 'tables_analyzed', n_stats, 'base_rows', n_base + n_gone, 'customer_rows', n_cust, 'history_rows', n_hist,
                            'document_rows', n_docs, 'rows', n_base + n_gone + n_cust + n_hist + n_docs,
                            'duration_ms', (extract(epoch from clock_timestamp() - v_t0) * 1000)::integer);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- S. The addition, the setting, the signatures, the grants
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_txt text;
begin
  select format('versions %s | setting %s | new: %s | earlier signatures left: %s | jit off: %s',
    (select string_agg(m.version, ',' order by m.version collate "C") from cma.schema_migration m where m.version in ('0009o', '0009r')),
    (select format('%s %s', s.value_type, s.default_value) from cma.setting s where s.key = 'customers.device_bands'),
    (select string_agg(format('%s(%s) %s/%s', p.proname, p.pronargs, has_function_privilege('cma_app', p.oid, 'execute'), has_function_privilege('public', p.oid, 'execute')),
                       ', ' order by p.proname collate "C")
     from pg_proc p where p.pronamespace = 'cma'::regnamespace and p.proname in ('active_rows', 'active_rows_of', 'active_file_record')),
    (select count(*) from unnest(array['cma.active_rows(text,text,text,text,boolean,text,text,integer,boolean)',
                                       'cma.active_rows_of(uuid,text,text,text,text,boolean,text,text,integer,timestamptz)',
                                       'cma.active_file_record(text,text,text,integer)']) x where to_regprocedure(x) is not null),
    (select string_agg(format('%s %s', p.proname, coalesce(array_to_string(p.proconfig, ';'), 'none')), ', ' order by p.proname collate "C")
     from pg_proc p where p.pronamespace = 'cma'::regnamespace and p.proname in ('active_refresh_of', 'active_rest_body_of', 'active_rows_of')))
  into v_txt;
  perform pg_temp.v0009r_row(1, 'S1', 'the addition is recorded; the setting, the list''s new signatures, the grants and JIT off are in place', v_txt,
    'versions 0009o,0009r | setting text 1,2,3,6,11 | new: active_file_record(5) t/f, active_rows(10) t/f, active_rows_of(11) t/f | earlier signatures left: 0'
    || ' | jit off: active_refresh_of jit=off, active_rest_body_of jit=off, active_rows_of jit=off');
end
$$;

-- ---------------------------------------------------------------------------------------------
-- G, H. Two throwaway tenants: the setting's refusals and the part counted by hand; always rolled back
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_t1 uuid; v_t2 uuid;
  v_now timestamptz := now();
  v_err text;
  v_g text; v_h1 text; v_h2 text; v_h3 text; v_h4 text; v_h5 text;
  j jsonb; p jsonb;
begin
  begin
    v_t1 := cma.create_tenant('verify-0009r-one', 'Verify 0009r one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0009r-two', 'Verify 0009r two', 'Europe/London');
    -- a take's customer rows, by hand: nine active customers at 0 devices and at every band's edges, in two segments and
    -- three channels, in two markets, and one customer that is not active
    insert into cma.active_customer (tenant_id, customer_id, source_id, store, market, segment, channel, customer_start, age_months, is_active, holding, devices)
    select v_t1, gen_random_uuid(), x.id, 'v-' || lower(x.market), x.market, x.segment, x.channel, v_now - interval '200 days', 6, x.active, 1, x.devices
    from (values ('a1', 'NL', 'B2B', 'direct', true, 0), ('a2', 'NL', 'B2B', 'direct', true, 1), ('a3', 'NL', 'B2C', 'indirect', true, 2),
                 ('a4', 'NL', 'B2C', 'indirect', true, 3), ('a5', 'GB', 'B2B', 'indirect', true, 5), ('a6', 'GB', 'B2C', 'direct', true, 6),
                 ('a7', 'NL', 'B2B', 'direct', true, 10), ('a8', 'NL', 'B2C', 'unknown', true, 11), ('a9', 'GB', 'B2B', 'indirect', true, 40),
                 ('a10', 'NL', 'B2B', 'direct', false, 7)) x(id, market, segment, channel, active, devices);
    insert into cma.active_customer (tenant_id, customer_id, source_id, store, market, segment, channel, customer_start, age_months, is_active, holding, devices)
    select v_t2, gen_random_uuid(), x.id, 'v-gb', 'GB', 'B2C', 'direct', v_now - interval '100 days', 3, true, 1, x.devices
    from (values ('b1', 1), ('b2', 3)) x(id, devices);

    -- the two segments the comparison sets side by side, as a tenant configures them
    insert into cma.tenant_setting (tenant_id, key, value) values (v_t1, 'crm.customer_segments', 'B2B,B2C')
    on conflict (tenant_id, key) do update set value = excluded.value;

    -- H1, H2. no filter
    j := cma.active_rest_body_of(v_t1, null, null, null, v_now);
    p := j -> 'device_customers';
    v_h1 := format('bounds %s | %s | %s', p ->> 'bounds', pg_temp.v0009r_figures(p), pg_temp.v0009r_bands(p));
    v_h2 := format('segment %s | channel %s', pg_temp.v0009r_split(p, 'by_segment'), pg_temp.v0009r_split(p, 'by_channel'));
    -- H3. the comparison's rows and the markets' columns of the same document; then a segment and a market filter
    v_h3 := format('comparison %s | markets %s | total %s',
              (select string_agg(format('%s %s|%s', r.v ->> 'measure', r.v ->> 'a', r.v ->> 'b'), ', ' order by r.o)
               from jsonb_array_elements(j #> '{comparison,rows}') with ordinality r(v, o)
               where r.v ->> 'measure' in ('devices_per_customer', 'devices_from_share')),
              (select string_agg(format('%s %s/%s/%s', m.v ->> 'market', m.v ->> 'devices', m.v ->> 'devices_per_customer', m.v ->> 'devices_from_share'), ', '
                                 order by m.v ->> 'market' collate "C")
               from jsonb_array_elements(j -> 'markets') m(v)),
              format('%s/%s/%s', j #>> '{markets_total,devices}', j #>> '{markets_total,devices_per_customer}', j #>> '{markets_total,devices_from_share}'));
    p := cma.active_rest_body_of(v_t1, null, 'B2B', null, v_now) -> 'device_customers';
    v_h3 := v_h3 || format(' | B2B: %s | %s', pg_temp.v0009r_figures(p), pg_temp.v0009r_bands(p));
    p := cma.active_rest_body_of(v_t1, 'GB', null, null, v_now) -> 'device_customers';
    v_h3 := v_h3 || format(' | GB: %s', pg_temp.v0009r_figures(p));
    -- H5. the second tenant
    p := cma.active_rest_body_of(v_t2, null, null, null, v_now) -> 'device_customers';
    v_h5 := format('two: %s | %s | one still: %s customers', pg_temp.v0009r_figures(p), pg_temp.v0009r_bands(p),
                   cma.active_rest_body_of(v_t1, null, null, null, v_now) #>> '{device_customers,customers}');

    -- G1. the setting: refusals, a list with spaces kept without them, a save marks the take stale
    insert into cma.active_take (tenant_id, computed_at, business_date, duration_ms, history_key, customers, subscriptions)
    values (v_t1, v_now, (v_now at time zone 'Europe/Amsterdam')::date, 0, 'verify', 9, 9);
    select string_agg(format('%s %s', x.label, pg_temp.v0009r_code(format('insert into cma.tenant_setting (tenant_id, key, value) values (%L, %L, %L) '
                                                                          || 'on conflict (tenant_id, key) do update set value = excluded.value',
                                                                          v_t1, 'customers.device_bands', x.value))), ', ' order by x.ord)
    into v_g
    from (values (1, 'a bound of 0', '0,1'), (2, 'not increasing', '2,2'), (3, 'decreasing', '3,2'), (4, 'nine bounds', '1,2,3,4,5,6,7,8,9'),
                 (5, 'above 1000', '1,1001'), (6, 'a word', 'few,many'), (7, 'nothing', ''), (8, 'eight bounds to 1000', '1,2,3,4,5,6,7,1000'),
                 (9, 'with spaces', ' 2, 4 ')) x(ord, label, value);
    v_g := v_g || format(' | kept as %s | the take stale %s',
                         (select s.value from cma.tenant_setting s where s.tenant_id = v_t1 and s.key = 'customers.device_bands'),
                         (select k.stale::text from cma.active_take k where k.tenant_id = v_t1));
    -- H4. the bands of 2,4 (the setting saved above)
    p := cma.active_rest_body_of(v_t1, null, null, null, v_now) -> 'device_customers';
    v_h4 := format('bounds %s | %s | %s', p ->> 'bounds', pg_temp.v0009r_figures(p), pg_temp.v0009r_bands(p));
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then v_err := sqlstate || ': ' || left(sqlerrm, 300);
  end;
  if v_err is not null then
    insert into pg_temp.verify_0009r values (10, 'G1 to H5: the checks ran to their end', 'FAIL', v_err);
    return;
  end if;
  perform pg_temp.v0009r_row(10, 'G1', 'the setting: refusals (CMA04), eight bounds to 1000 and a list with spaces accepted, a save marks the take stale', v_g,
    'a bound of 0 CMA04, not increasing CMA04, decreasing CMA04, nine bounds CMA04, above 1000 CMA04, a word CMA04, nothing CMA04, eight bounds to 1000 ok, with spaces ok'
    || ' | kept as 2,4 | the take stale true');
  perform pg_temp.v0009r_row(20, 'H1', 'by hand, no filter: the bands of 1,2,3,6,11, a customer at 0 devices and at every edge, the average, the median, the customers from 3 on', v_h1,
    'bounds [1, 2, 3, 6, 11] | customers 9 devices 78 average 8.67 median 5.0 not linked 1; from 3: 6 customers 0.6667, 75 devices 0.9615'
    || ' | 0 1/0 0.1111/0.0000, 1 1/1 0.1111/0.0128, 2 1/2 0.1111/0.0256, 3-5 2/8 0.2222/0.1026, 6-10 2/16 0.2222/0.2051, 11+ 2/51 0.2222/0.6538');
  perform pg_temp.v0009r_row(21, 'H2', 'by hand: each band''s customers and devices per segment and per acquisition channel', v_h2,
    'segment 0: B2B 1/0, 1: B2B 1/1, 2: B2C 1/2, 3-5: B2B 1/5 B2C 1/3, 6-10: B2B 1/10 B2C 1/6, 11+: B2B 1/40 B2C 1/11'
    || ' | channel 0: direct 1/0, 1: direct 1/1, 2: indirect 1/2, 3-5: indirect 2/8, 6-10: direct 2/16, 11+: indirect 1/40 unknown 1/11');
  perform pg_temp.v0009r_row(22, 'H3', 'by hand: the comparison''s rows, the markets'' columns, a segment filter and a market filter', v_h3,
    'comparison devices_per_customer 11.20|5.50, devices_from_share 0.6000|0.7500 | markets GB 51/17.00/1.0000, NL 27/4.50/0.5000 | total 78/8.67/0.6667'
    || ' | B2B: customers 5 devices 56 average 11.20 median 5.0 not linked 1; from 3: 3 customers 0.6000, 55 devices 0.9821'
    || ' | 0 1/0 0.2000/0.0000, 1 1/1 0.2000/0.0179, 2 0/0 0.0000/0.0000, 3-5 1/5 0.2000/0.0893, 6-10 1/10 0.2000/0.1786, 11+ 1/40 0.2000/0.7143'
    || ' | GB: customers 3 devices 51 average 17.00 median 6.0 not linked 0; from 3: 3 customers 1.0000, 51 devices 1.0000');
  perform pg_temp.v0009r_row(23, 'H4', 'by hand, the setting at 2,4: the bands 0, 1, 2-3, 4+ and the customers from the last bound on', v_h4,
    'bounds [2, 4] | customers 9 devices 78 average 8.67 median 5.0 not linked 1; from 4: 5 customers 0.5556, 72 devices 0.9231'
    || ' | 0 1/0 0.1111/0.0000, 1 1/1 0.1111/0.0128, 2-3 2/5 0.2222/0.0641, 4+ 5/72 0.5556/0.9231');
  perform pg_temp.v0009r_row(24, 'H5', 'two tenants: the second tenant''s customers in its own part alone', v_h5,
    'two: customers 2 devices 4 average 2.00 median 2.0 not linked 0; from 3: 1 customers 0.5000, 3 devices 0.7500'
    || ' | 0 0/0 0.0000/0.0000, 1 1/1 0.5000/0.2500, 2 0/0 0.0000/0.0000, 3-5 1/3 0.5000/0.7500, 6-10 0/0 0.0000/0.0000, 11+ 0/0 0.0000/0.0000'
    || ' | one still: 9 customers');
end
$$;

-- ---------------------------------------------------------------------------------------------
-- R, D, L, E. Per tenant, inside a step that is always rolled back
-- ---------------------------------------------------------------------------------------------
do $$
declare
  t record;
  v_now timestamptz := now();
  v_tables text[] := array['active_base', 'active_spell', 'active_month', 'active_cohort'];
  v_any boolean := false;
  v_err text;
  d_old text; d_new text;
  v_d1 text; v_d2 text; v_l1 text; v_l2 text;
  v_k0 text; v_k1 text; v_k2 text; v_moved boolean;
  v_bounds integer[]; v_bands text[]; v_band text; v_few text;
  v_user uuid;
  j jsonb;
  v_t0 timestamptz; v_ms numeric; v_rest numeric; v_list numeric;
  n_total bigint; n_sum bigint; n_bad bigint; n_same integer; n_bands integer; n_few bigint;
begin
  for t in select x.id, x.slug from cma.tenant x
           where x.status = 'active' and exists (select 1 from cma.subscription s where s.tenant_id = x.id) order by x.slug collate "C" loop
    if not (coalesce(cma.flash_source_set_up_of(t.id, 'commerce'), false) and coalesce(cma.flash_source_set_up_of(t.id, 'subscriptions'), false)) then
      continue;
    end if;
    v_any := true;
    v_err := null; d_old := null; d_new := null; v_d1 := null; v_d2 := null; v_l1 := null; v_l2 := null; v_rest := null; v_list := null;
    v_k0 := null; v_k1 := null; v_k2 := null;
    v_bounds := cma.flash_bounds_of(cma.setting_of(t.id, 'customers.device_bands'));
    v_bands := cma.flash_count_bands_of(v_bounds);
    begin
      perform set_config('app.tenant_id', t.id::text, true);
      -- a reader of the page, for L2 (as 131 finds its acting person)
      select u.id into v_user
      from cma.app_user u
      where u.tenant_id = t.id and u.status = 'active' and u.kind = 'person'
        and exists (select 1 from cma.user_role ur where ur.tenant_id = u.tenant_id and ur.user_id = u.id)
        and (cma.has_permission(u.id, 'reports.view') or cma.has_permission(u.id, 'performance.team'))
      order by u.created_at, u.id limit 1;
      perform set_config('role', 'cma_app', true);
      v_k0 := cma.active_inputs_key_of(t.id);

      -- R1. the take as 174's refresh writes it, in a step of its own
      begin
        perform pg_temp.v0009r_refresh_174(t.id, true, v_now);
        perform set_config('role', 'cma_owner', true);
        d_old := (select string_agg(x || ' ' || pg_temp.v0009r_digest(x, t.id, '{}'), ' | ' order by o) from unnest(v_tables) with ordinality u(x, o))
                 || ' | customers but devices ' || pg_temp.v0009r_digest('active_customer', t.id, array['devices'])
                 || ' | documents but devices ' || pg_temp.v0009r_documents(t.id);
        raise exception using errcode = 'CMAOK', message = 'rollback';
      exception
        when sqlstate 'CMAOK' then null;
      end;
      perform set_config('role', 'cma_app', true);
      -- and as 184's writes it, at the same moment; the checks after it read this take
      j := cma.active_refresh_of(t.id, true, v_now);
      v_k1 := cma.active_inputs_key_of(t.id);
      perform set_config('role', 'cma_owner', true);
      d_new := (select string_agg(x || ' ' || pg_temp.v0009r_digest(x, t.id, '{}'), ' | ' order by o) from unnest(v_tables) with ordinality u(x, o))
               || ' | customers but devices ' || pg_temp.v0009r_digest('active_customer', t.id, array['devices'])
               || ' | documents but devices ' || pg_temp.v0009r_documents(t.id);

      -- D1. the term in the take: by the stored base, and against the fresh computation
      select format('customers whose devices differ from the devices in the field on their holding subscriptions: %s; from the fresh computation: %s',
               (select count(*) from cma.active_customer c
                where c.tenant_id = t.id
                  and c.devices is distinct from coalesce((select sum(b.devices_in_field) filter (where b.is_holding) from cma.active_base b
                                                           where b.tenant_id = t.id and b.customer_id = c.customer_id), 0)),
               (select count(*) from ((select c.customer_id, c.devices from cma.active_customer c where c.tenant_id = t.id
                                       except select f.customer_id, f.devices from cma.active_customers_of(t.id, v_now, false) f)
                                      union all
                                      (select f.customer_id, f.devices from cma.active_customers_of(t.id, v_now, false) f
                                       except select c.customer_id, c.devices from cma.active_customer c where c.tenant_id = t.id)) q))
      into v_d1;
      -- the fresh computation read the tables as they are now: the markers once more, for D1's skip
      v_k2 := cma.active_inputs_key_of(t.id);

      -- D2. the stored documents: equal to a fresh computation; the bands add up; equal to 172's document but for devices
      select format('stored below-the-fold documents %s, differing from fresh %s, whose bands do not add up %s, differing from 172''s but for devices %s',
               case when count(*) > 0 then 'some' else 'none' end,
               count(*) filter (where d.doc is distinct from cma.active_rest_body_of(t.id, nullif(d.market, ''), nullif(d.segment, ''), nullif(d.channel, ''), v_now)),
               count(*) filter (where (select sum((b ->> 'customers')::bigint) from jsonb_array_elements(d.doc #> '{device_customers,bands}') b)
                                        is distinct from (d.doc #>> '{device_customers,customers}')::bigint
                                   or (select sum((b ->> 'devices')::bigint) from jsonb_array_elements(d.doc #> '{device_customers,bands}') b)
                                        is distinct from (d.doc #>> '{device_customers,devices}')::bigint
                                   or (d.doc #>> '{device_customers,customers}')::bigint
                                        is distinct from (select count(*) from cma.active_customer c
                                                          where c.tenant_id = t.id and c.is_active and (d.market = '' or c.market = d.market)
                                                            and (d.segment = '' or c.segment = d.segment) and (d.channel = '' or c.channel = d.channel))),
               count(*) filter (where pg_temp.v0009r_plain(d.doc) is distinct from
                                      pg_temp.v0009r_plain(pg_temp.v0009r_rest_172(t.id, nullif(d.market, ''), nullif(d.segment, ''), nullif(d.channel, ''), v_now))))
      into v_d2
      from cma.active_document d where d.tenant_id = t.id and d.part = 'rest';

      -- L1. the list under each band: the totals add up, a first page holds the band's rows alone, in the list's order
      n_total := (cma.active_rows_of(t.id, null, null, null, 'devices', true, null, null, 50, v_now) ->> 'total')::bigint;
      n_sum := 0; n_bad := 0; n_same := 0; n_bands := 0; v_few := null;
      foreach v_band in array v_bands loop
        j := cma.active_rows_of(t.id, null, null, null, 'devices', true, null, null, 50, v_now, v_band);
        n_sum := n_sum + (j ->> 'total')::bigint;
        n_bands := n_bands + 1;
        n_bad := n_bad + (select count(*) from jsonb_array_elements(j -> 'rows') r where cma.flash_count_band_of((r ->> 'devices')::integer, v_bounds) <> v_band);
        if (select coalesce(string_agg(r.v ->> 'store_customer', ',' order by r.o), '') from jsonb_array_elements(j -> 'rows') with ordinality r(v, o))
           = (select coalesce(string_agg(q.source_id, ',' order by q.o), '')
              from (select c.source_id, row_number() over (order by c.devices desc, c.source_id desc, c.customer_id desc) as o
                    from cma.active_customer c
                    where c.tenant_id = t.id and c.is_active and cma.flash_count_band_of(c.devices, v_bounds) = v_band
                    order by c.devices desc, c.source_id desc, c.customer_id desc limit 50) q) then
          n_same := n_same + 1;
        end if;
        -- the band with the fewest customers, an empty one included (the last of them): under a page's size the walk
        -- cannot stop early, so it reads the sort's whole index
        if v_few is null or (j ->> 'total')::bigint <= n_few then
          v_few := v_band; n_few := (j ->> 'total')::bigint;
        end if;
      end loop;
      v_l1 := format('the bands'' totals add up to the list''s: %s; rows of another band on a first page: %s; first pages as a plain read of the band: %s of %s',
                     (n_sum = n_total)::text, n_bad, n_same, n_bands);
      -- L2. a reader: a band of another setting is refused, a band of this one answers
      if v_user is not null then
        perform set_config('role', 'cma_app', true);
        perform set_config('app.user_id', v_user::text, true);
        v_l2 := format('a band of another setting %s, a band of this one %s, the file''s record under a band %s',
                       pg_temp.v0009r_code($q$select cma.active_rows(p_band => '7-9999')$q$),
                       pg_temp.v0009r_code(format('select cma.active_rows(p_band => %L)', v_bands[1])),
                       pg_temp.v0009r_code(format('select cma.active_file_record(null, null, null, 0, %L)', v_bands[1])));
        perform set_config('app.user_id', '', true);
      end if;

      -- E1. below the fold computed, no filter: the best of three after six calls
      perform set_config('role', 'cma_app', true);
      for i in 1 .. 9 loop
        v_t0 := clock_timestamp();
        j := cma.active_rest_body_of(t.id, null, null, null, v_now);
        v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
        if i > 6 then v_rest := least(coalesce(v_rest, v_ms), v_ms); end if;
      end loop;
      -- E2. the list's first page under the band with the fewest customers
      for i in 1 .. 9 loop
        v_t0 := clock_timestamp();
        j := cma.active_rows_of(t.id, null, null, null, 'monthly_amount', true, null, null, 50, v_now, v_few);
        v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
        if i > 6 then v_list := least(coalesce(v_list, v_ms), v_ms); end if;
      end loop;
      raise exception using errcode = 'CMAOK', message = 'rollback';
    exception
      when sqlstate 'CMAOK' then null;
      when others then v_err := sqlstate || ': ' || left(sqlerrm, 300);
    end;
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.user_id', '', true);
    if v_err is not null then
      insert into pg_temp.verify_0009r values (100, 'R1 to E2 ' || t.slug || ': the checks ran to their end', 'FAIL', v_err);
      continue;
    end if;
    v_moved := v_k0 is distinct from v_k1 and current_setting('verify.provoke') = 'false';
    if v_moved then
      insert into pg_temp.verify_0009r values (30, 'R1 ' || t.slug || ': the two refreshes compared on the same rows', 'skip',
        'the inputs moved during the check (an ingest wrote a subscription, a device, a customer, an order or a contact): run again');
    else
      perform pg_temp.v0009r_row(30, 'R1', t.slug || ': a forced refresh of 184 writes the take 174''s writes at the same moment, but for the customers'' devices and the parts that state them', d_new, d_old);
    end if;
    if v_k1 is distinct from v_k2 and current_setting('verify.provoke') = 'false' then
      insert into pg_temp.verify_0009r values (40, 'D1 ' || t.slug || ': the take''s devices against the fresh computation', 'skip',
        'the inputs moved during the check (an ingest wrote a subscription, a device, a customer, an order or a contact): run again');
    else
      perform pg_temp.v0009r_row(40, 'D1', t.slug || ': a customer''s devices in the take are the devices in the field on its holding subscriptions, as the fresh computation', v_d1,
        'customers whose devices differ from the devices in the field on their holding subscriptions: 0; from the fresh computation: 0');
    end if;
    perform pg_temp.v0009r_row(41, 'D2', t.slug || ': every stored below-the-fold document equals a fresh computation, its bands add up, and it equals 172''s but for devices', v_d2,
      'stored below-the-fold documents some, differing from fresh 0, whose bands do not add up 0, differing from 172''s but for devices 0');
    perform pg_temp.v0009r_row(50, 'L1', t.slug || ': the list under each band of the setting', v_l1,
      format('the bands'' totals add up to the list''s: true; rows of another band on a first page: 0; first pages as a plain read of the band: %s of %s',
             cardinality(v_bands), cardinality(v_bands)));
    if v_user is null then
      insert into pg_temp.verify_0009r values (51, 'L2 ' || t.slug || ': a reader and the band', case when pg_temp.v0009r_p('L2') then 'FAIL' else 'skip' end,
        'no active person holds reports.view or performance.team');
    else
      perform pg_temp.v0009r_row(51, 'L2', t.slug || ': for a reader a band of another setting is refused (CMA04), a band of this one answers, the file''s record takes it', v_l2,
        'a band of another setting CMA04, a band of this one ok, the file''s record under a band ok');
    end if;
    insert into pg_temp.verify_0009r values (60, 'E1 ' || t.slug || ': below the fold computed, no filter, within its budget',
      case when v_rest <= case when pg_temp.v0009r_p('E1') then 0 else current_setting('verify.max_rest_ms')::numeric end then 'PASS' else 'FAIL' end,
      format('%s ms (best of 3, after six calls) against %s ms', v_rest, case when pg_temp.v0009r_p('E1') then '0' else current_setting('verify.max_rest_ms') end));
    insert into pg_temp.verify_0009r values (61, 'E2 ' || t.slug || ': the list''s first page under the band with the fewest customers within its budget',
      case when v_list <= case when pg_temp.v0009r_p('E2') then 0 else current_setting('verify.max_list_ms')::numeric end then 'PASS' else 'FAIL' end,
      format('%s ms (best of 3, after six calls; band %s) against %s ms', v_list, coalesce(v_few, 'none') || case when n_few = 0 then ', which holds no customer' else '' end, case when pg_temp.v0009r_p('E2') then '0' else current_setting('verify.max_list_ms') end));
  end loop;
  if not v_any then
    insert into pg_temp.verify_0009r values (30, 'R1 to E2 the refresh, the documents and the list per tenant',
      case when current_setting('verify.provoke') <> 'false' then 'FAIL' else 'skip' end, 'no active tenant with a subscription has its sources set up');
  end if;
end
$$;

drop function if exists pg_temp.v0009r_refresh_174(uuid, boolean, timestamptz);
drop function if exists pg_temp.v0009r_rest_172(uuid, text, text, text, timestamptz);
drop function if exists pg_temp.v0009r_figures(jsonb);
drop function if exists pg_temp.v0009r_split(jsonb, text);
drop function if exists pg_temp.v0009r_bands(jsonb);
drop function if exists pg_temp.v0009r_documents(uuid);
drop function if exists pg_temp.v0009r_plain(jsonb);
drop function if exists pg_temp.v0009r_digest(text, uuid, text[]);
drop function if exists pg_temp.v0009r_code(text);
drop function if exists pg_temp.v0009r_row(integer, text, text, text, text);
drop function if exists pg_temp.v0009r_p(text);

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0009r
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke') <> 'false' then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0009r where result = 'FAIL') then 'FAIL'
                  when not exists (select 1 from pg_temp.verify_0009r where result = 'PASS') then 'FAIL'
                  else 'PASS' end,
             format('185_verify_active_device_bands: %s PASS, %s FAIL, %s skip', (select count(*) from pg_temp.verify_0009r where result = 'PASS'),
                    (select count(*) from pg_temp.verify_0009r where result = 'FAIL'), (select count(*) from pg_temp.verify_0009r where result = 'skip'))) x
order by ord, check_name collate "C";
drop table if exists pg_temp.verify_0009r;
reset role;
