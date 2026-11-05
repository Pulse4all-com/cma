-- =============================================================================================
-- 139_verify_flash_totals.sql: verifies addition 0008zu (138_flash_totals.sql), Flash's Total subscriptions and the
-- active customers on the device-holding statuses (brief B30)
-- =============================================================================================
-- Read-only against real data: every fixture lives in throwaway tenants inside blocks that roll back; block D reads every
-- tenant's own figures. Ids, counts, statuses and codes only: the fixture holds no name, address, email or phone number.
-- The snapshot's checks read fixed business dates (30 October to 1 November 2026) taken at fixed instants, so the verdict
-- does not depend on the day it runs. Every check writes one row, ok, FAIL or skip, and the last row is the verdict,
-- because Cloud SQL Studio shows no notices. Run as your own IAM login after 138_flash_totals.sql, dev first, then prod;
-- then 123_verify_flash.sql and 137_verify_flash_insights.sql again (their expectations follow 0008zu).
-- Expected verdict in dev and in prod (block C off, the default): "0008zu verified | 139_verify_flash_totals: 16 ok,
-- 0 FAIL, 1 skip" (17 checks: A1 to A4, B1 to B10 and D1, D2 ok; C1 skip, volume off). A database whose tenants have no
-- set-up subscriptions connection or store reads D1 or D2 skip: still "0008zu verified" with those skips. A local run
-- with verify.volume 'true': C1 ok. Provoked: "PROVOKED, NOT A PASS | 139_verify_flash_totals: 0 ok, <n> FAIL, <k>
-- skip", every check that ran a FAIL.
--   A  structure: the addition after 0008zt; the overviews (the subscriptions' headline holding_subscriptions and the split
--      set [market, status]; the customers' as they were), the definitions' versions (0008zu for customers and
--      subscriptions), the split's dim; every new and remade function the application's only and in the caller's rights,
--      the take's writers the owner's, JIT off where 0008zt had it; 0008zt's customers' base set keeping its columns; the
--      split's helper on given rows (the setting's order, zeros, another key after, one market)
--   B  behaviour, on three throwaway tenants (Europe/Amsterdam) with the same data. Tenant one holds devices in active and
--      failed (flash.device_holding_statuses active,failed), tenant two in active alone (the default), tenant three only
--      a failed subscription. Store customers in GB: cu-1 active; cu-2 failed only; cu-3 paused and failed; cu-4 paused
--      only; cu-5 canceled only; cu-6 active and failed; cu-7 none; in NL ncu-1 failed only and ncu-2 paused only. A
--      failed subscription's amount (99 GBP, 77 EUR) is never an active one's (20 GBP). Checked: the customers (a failed
--      one only: active, not paused; paused and failed: active; the segment rows adding up to active_customers); their
--      lists; the subscriptions (Total subscriptions the sum of its split, per market too, zeros included; the amounts
--      over the paying statuses only); tenant one's subscriptions rows other than the split, and all of tenant two's
--      figures (holding statuses active alone), equal to 0008zt's computation row for row (kept in this script); the
--      headline's split and version, live; a take of 31 October (a month end) equal to the computation as of its date,
--      stored under 0008zu, its customer list the active customers as now counted; no jump across the change of
--      definition from 30 October (stored under 0008zt); the landing as of 31 October (the stored split, the versions of
--      the figure and of the one it is compared with) and now; a jump within one definition still found (1 November);
--      tenant isolation
--   D  every tenant's own figures, live, read only: holding_subscriptions the sum of its split (in all and per market),
--      every split status a holding one; active_customers the sum over segment and with paused_customers at most the
--      customers held (skip where no tenant has the source set up)
--   C  speed at volume, local databases only (verify.volume 'true'): 137's volume (100,000 store customers and
--      subscriptions, active, paused, canceled, expired and failed, 50,000 devices), active and failed holding devices;
--      the customers' and the subscriptions' overviews, the subscriptions' headline and the landing, as the application,
--      each the best of two, under verify.max_overview_ms (1,500 ms, the Decision log's of 3 November 2026)
-- Provoke: set provoke below to true; every check that runs must then read FAIL, and the verdict says PROVOKED, NOT A PASS.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);                 -- 'true' to make every check fail
select set_config('verify.max_overview_ms', '1500', false);          -- a live overview or the landing, as the application (Decision log, 3 Nov 2026)
select set_config('verify.volume', 'false', false);                  -- 'true' to run block C, local databases only

drop table if exists pg_temp.verify_0008zu;
create temp table verify_0008zu (ord int, check_name text, result text, detail text);

-- The error code a statement raises, or 'ok'
create or replace function pg_temp.v0008zu_code(p_sql text)
returns text
language plpgsql
as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end
$$;

-- An overview's rows as one json array (dims, measures), live or measured against a business date
create or replace function pg_temp.v0008zu_rows(p_tenant uuid, p_overview text, p_on date)
returns jsonb
language sql
as $$
  select coalesce(jsonb_agg(jsonb_build_object('dims', c.dims, 'measures', c.measures) order by c.dims::text collate "C"), '[]'::jsonb)
  from cma.flash_compute_of(p_tenant, p_overview, null, null, p_on) c
$$;

-- The rows of one breakdown set (exactly its keys) as one line: each row's dim values and measures in a fixed order
create or replace function pg_temp.v0008zu_set(p_rows jsonb, p_keys text[], p_measures text[])
returns text
language sql
as $$
  select coalesce(string_agg(coalesce((select string_agg(r -> 'dims' ->> k, '/' order by o) from unnest(p_keys) with ordinality u(k, o)), '') || ':'
                             || (select string_agg(coalesce(r -> 'measures' ->> m, '-'), ',' order by o) from unnest(p_measures) with ordinality u(m, o)),
                             ' ' order by coalesce((select string_agg(r -> 'dims' ->> k, '/' order by o) from unnest(p_keys) with ordinality u(k, o)), '') collate "C"), '-')
  from jsonb_array_elements(p_rows) r
  where coalesce((select array_agg(k order by k collate "C") from jsonb_object_keys(r -> 'dims') k), '{}')
        = coalesce((select array_agg(k order by k collate "C") from unnest(p_keys) k), '{}')
$$;

-- Where a measure of the totals ({}) and of each [market] row differs from the sum of that measure over the rows whose
-- dims are exactly the market and p_dim (of the same market); empty when every one adds up
create or replace function pg_temp.v0008zu_unbalanced(p_rows jsonb, p_measure text, p_dim text)
returns text
language sql
as $$
  with r as (
    select x -> 'dims' as dims, x -> 'measures' as measures from jsonb_array_elements(p_rows) x
  ), tops as (
    select coalesce(r.dims ->> 'market', '*') as market, coalesce((r.measures ->> p_measure)::numeric, 0) as v
    from r where r.dims = '{}'::jsonb or r.dims = jsonb_build_object('market', r.dims ->> 'market')
  ), parts as (
    select r.dims ->> 'market' as market, sum(coalesce((r.measures ->> p_measure)::numeric, 0)) as v
    from r where r.dims ? p_dim and r.dims ? 'market' and (select count(*) from jsonb_object_keys(r.dims)) = 2 group by 1
  ), cmp as (
    select t.market, t.v,
           coalesce(case when t.market = '*' then (select sum(p.v) from parts p) else (select p.v from parts p where p.market = t.market) end, 0) as s
    from tops t
  )
  select coalesce(string_agg(p_measure || '/' || p_dim || ' ' || c.market || ' ' || c.v || '<>' || c.s, '; ' order by c.market collate "C"), '')
  from cmp c where c.v <> c.s
$$;

-- The rows of an overview other than the subscriptions' split ([market, status]), as one ordered text
create or replace function pg_temp.v0008zu_others(p_rows jsonb)
returns text
language sql
as $$
  select coalesce(jsonb_agg(r order by (r -> 'dims')::text collate "C"), '[]'::jsonb)::text
  from jsonb_array_elements(p_rows) r
  where not (r -> 'dims' ? 'status' and (select count(*) from jsonb_object_keys(r -> 'dims')) = 2)
$$;

-- 0008zt's customers and subscriptions, as 136 computed them (cma.flash_compute_of's two branches, verbatim): the figures
-- before 0008zu, which a tenant whose device-holding statuses are the active ones alone must still give
create or replace function pg_temp.v0008zu_before(p_tenant_id uuid, p_overview text, p_from date default null, p_to date default null,
                                                  p_on date default null)
returns table (dims jsonb, measures jsonb)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_src   text := (select o.source from cma.flash_overviews() o where o.key = p_overview);
  -- today once, a value (a function call passed on would be evaluated per row where the base sets inline it)
  v_today date := cma.tenant_today_of(p_tenant_id);
  v_from  date := coalesce(p_from, v_today);
  v_to    date := coalesce(p_to, p_from, v_today);
  -- the stock figures' date and instant: today and now live; the snapshot's date and its end (the next day's 00:00 in
  -- the tenant's zone) in a take
  v_on    date := coalesce(p_on, v_today);
  v_at    timestamptz := case when p_on is null then now()
                              else ((p_on + 1)::timestamp at time zone (select t.timezone from cma.tenant t where t.id = p_tenant_id)) end;
  -- with_required_refs applies only while a contact reference is required
  v_refs_required boolean := cardinality(cma.flash_list_of(cma.setting_of(p_tenant_id, 'commerce.required_contact_refs'))) > 0;
  -- the bands of the active subscriptions (0008zt): every band of the settings has its row per market, zeros included
  v_device_bands  integer[] := cma.flash_bounds_of(cma.setting_of(p_tenant_id, 'flash.device_bands'));
  v_ages          integer[] := cma.flash_bounds_of(cma.setting_of(p_tenant_id, 'flash.subscription_age_months'));
  -- a device is on a device-holding subscription when its subscription status is a holding one (0008zt)
  v_holding       text[] := cma.flash_holding_statuses_of(p_tenant_id);
begin
  if p_overview = 'customers' then
    return query
      select case when grouping(b.market) = 1 then '{}'::jsonb
                  when grouping(b.store) = 0 then jsonb_build_object('market', b.market, 'store', b.store)
                  when grouping(b.segment) = 0 then jsonb_build_object('market', b.market, 'segment', b.segment)
                  else jsonb_build_object('market', b.market) end,
             jsonb_build_object('customers_held', count(*),
                                'active_customers', count(*) filter (where b.active_subscriptions > 0),
                                'paused_customers', count(*) filter (where b.active_subscriptions = 0 and b.paused_subscriptions > 0),
                                'linked_to_contact', count(*) filter (where b.contact_source_id is not null))
             || case when v_refs_required
                     then jsonb_build_object('with_required_refs', count(*) filter (where b.contact_source_id is not null and b.contact_held
                                                                                     and cardinality(b.missing_refs) = 0))
                     else '{}'::jsonb end
      from cma.flash_store_customers_of(p_tenant_id) b
      group by grouping sets ((), (b.market), (b.market, b.store), (b.market, b.segment));
  elsif p_overview = 'subscriptions' then
    -- the base set read once (measured against v_on: the age bands), for the totals, per market, the breakdown and the
    -- bands; holding_subscriptions and devices_on_holding count the device-holding subscriptions and their devices in the
    -- field (0008zt), their ratio is left out of a row without a holding subscription (null, never 0); the device bands are
    -- the holding subscriptions', the age bands the active ones'
    return query
      with b as materialized (
        select x.market, x.store, x.status, x.payment_state, x.currency, x.is_active, x.is_holding, x.amount_per_cycle, x.devices_in_field,
               x.age_band, x.device_band
        from cma.flash_subscriptions_of(p_tenant_id, v_on) x
      ), a as (
        select case when grouping(b.market) = 1 then '{}'::jsonb
                    when grouping(b.store) = 1 then jsonb_build_object('market', b.market)
                    else jsonb_build_object('market', b.market, 'store', b.store, 'status', b.status, 'payment_state', b.payment_state) end as dims,
               b.currency, count(*) as n, count(*) filter (where b.is_active) as act, count(*) filter (where b.status = 'paused') as paused,
               -- the active subscriptions' amounts only, each for its own billing cycle (Flash overview measures)
               sum(b.amount_per_cycle) filter (where b.is_active) as amount,
               count(*) filter (where b.is_holding) as hold,
               coalesce(sum(b.devices_in_field) filter (where b.is_holding), 0) as dev
        from b
        group by grouping sets ((b.currency), (b.market, b.currency), (b.market, b.store, b.status, b.payment_state, b.currency))
      ), bands as (
        -- the holding subscriptions per market and device band with their devices in the field; the active ones per age band
        select b.market, 'device_band'::text as dim, b.device_band as band, count(*) as n, sum(b.devices_in_field) as dev
        from b where b.is_holding group by 1, 2, 3
        union all
        select b.market, 'age_band', b.age_band, count(*), null from b where b.is_active group by 1, 2, 3
      ), labels as (
        -- every band of the settings for each market with a subscription it counts (unknown only when a subscription has it)
        select m.market, 'device_band'::text as dim, x as band
        from (select distinct b.market from b where b.is_holding) m cross join unnest(cma.flash_count_bands_of(v_device_bands)) x
        union all
        select m.market, 'age_band', x
        from (select distinct b.market from b where b.is_active) m cross join unnest(cma.flash_age_bands_of(v_ages)) x
      )
      select a.dims, jsonb_build_object('subscriptions', sum(a.n), 'active_subscriptions', sum(a.act), 'paused_subscriptions', sum(a.paused),
                                        'amount_per_cycle', coalesce(jsonb_object_agg(a.currency, round(a.amount, 2))
                                                                       filter (where a.currency is not null and a.amount is not null), '{}'::jsonb),
                                        'holding_subscriptions', sum(a.hold), 'devices_on_holding', sum(a.dev))
                     || jsonb_strip_nulls(jsonb_build_object('devices_per_holding_subscription', cma.flash_ratio_of(sum(a.dev), sum(a.hold))))
      from a group by a.dims
      union all
      select jsonb_build_object('market', coalesce(n.market, l.market), coalesce(n.dim, l.dim), coalesce(n.band, l.band)),
             case when coalesce(n.dim, l.dim) = 'age_band' then jsonb_build_object('active_subscriptions', coalesce(n.n, 0))
                  else jsonb_build_object('holding_subscriptions', coalesce(n.n, 0), 'devices_on_holding', coalesce(n.dev, 0))
                       || jsonb_strip_nulls(jsonb_build_object('devices_per_holding_subscription', cma.flash_ratio_of(coalesce(n.dev, 0), coalesce(n.n, 0))))
             end
      from labels l
      full join bands n on n.market = l.market and n.dim = l.dim and n.band = l.band;
    if not found then
      return query select '{}'::jsonb, jsonb_build_object('subscriptions', 0, 'active_subscriptions', 0, 'paused_subscriptions', 0,
                                                          'amount_per_cycle', '{}'::jsonb, 'holding_subscriptions', 0, 'devices_on_holding', 0);
    end if;
  end if;
end
$$;

-- One tenant's sources and records (as the owner): GB and NL, a store and a subscriptions connection each, a CRM. Store
-- customers in GB: cu-1 active; cu-2 failed only; cu-3 paused and failed; cu-4 paused only; cu-5 canceled only; cu-6 active
-- and failed; cu-7 none; in NL: ncu-1 failed only; ncu-2 paused only. Contacts: cu-1 and cu-3 B2B, cu-2 and cu-4 B2C,
-- ncu-1 B2B, ncu-2 B2C; cu-5 to cu-7 linked to none (unknown). An active subscription's amount 20 GBP, a failed one's
-- 99 GBP (77 EUR in NL): never an active amount. The connections' ids, by role
create or replace function pg_temp.v0008zu_fixture(p_tenant uuid)
returns jsonb
language plpgsql
as $$
declare
  v_crm uuid; v_gb uuid; v_nl uuid; v_sgb uuid; v_snl uuid;
begin
  insert into cma.market (tenant_id, code, name, time_zone, language_code, currency, sort_order) values
    (p_tenant, 'GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', 10), (p_tenant, 'NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR', 20);
  insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
  values (p_tenant, 'verifycrm', 'Verify CRM', 'portal-1', 'crm') returning id into v_crm;
  insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
  values (p_tenant, 'verifyshop', 'Verify shop GB', 'shop-gb.shop.example', 'commerce') returning id into v_gb;
  insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
  values (p_tenant, 'verifyshop', 'Verify shop NL', 'shop-nl.shop.example', 'commerce') returning id into v_nl;
  insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
  values (p_tenant, 'verifysubs', 'Verify subscriptions GB', 'shop-gb.shop.example', 'subscriptions', 'verify-subs-gb') returning id into v_sgb;
  insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
  values (p_tenant, 'verifysubs', 'Verify subscriptions NL', 'shop-nl.shop.example', 'subscriptions', 'verify-subs-nl') returning id into v_snl;
  insert into cma.commerce_store (tenant_id, connection_id, handle, name, market, currency, time_zone) values
    (p_tenant, v_gb, 'shop-gb', 'Shop GB', 'GB', 'GBP', 'Europe/London'), (p_tenant, v_nl, 'shop-nl', 'Shop NL', 'NL', 'EUR', 'Europe/Amsterdam');
  insert into cma.commerce_customer (tenant_id, connection_id, source_system, source_id, orders_count, crm_connection_id, crm_contact_source_id, matched_at) values
    (p_tenant, v_gb, 'verifyshop', 'cu-1', 1, v_crm, 'c-1', now()), (p_tenant, v_gb, 'verifyshop', 'cu-2', 1, v_crm, 'c-2', now()),
    (p_tenant, v_gb, 'verifyshop', 'cu-3', 1, v_crm, 'c-3', now()), (p_tenant, v_gb, 'verifyshop', 'cu-4', 1, v_crm, 'c-4', now()),
    (p_tenant, v_gb, 'verifyshop', 'cu-5', 1, null, null, null), (p_tenant, v_gb, 'verifyshop', 'cu-6', 1, null, null, null),
    (p_tenant, v_gb, 'verifyshop', 'cu-7', 0, null, null, null),
    (p_tenant, v_nl, 'verifyshop', 'ncu-1', 1, v_crm, 'c-8', now()), (p_tenant, v_nl, 'verifyshop', 'ncu-2', 1, v_crm, 'c-9', now());
  insert into cma.crm_contact (tenant_id, connection_id, source_system, source_id, country, segment) values
    (p_tenant, v_crm, 'verifycrm', 'c-1', 'GB', 'B2B'), (p_tenant, v_crm, 'verifycrm', 'c-2', 'GB', 'B2C'), (p_tenant, v_crm, 'verifycrm', 'c-3', 'GB', 'B2B'),
    (p_tenant, v_crm, 'verifycrm', 'c-4', 'GB', 'B2C'), (p_tenant, v_crm, 'verifycrm', 'c-8', 'NL', 'B2B'), (p_tenant, v_crm, 'verifycrm', 'c-9', 'NL', 'B2C');
  insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, amount_per_cycle, currency,
                                billing_interval, billing_interval_count, paused_at) values
    (p_tenant, v_sgb, 'verifysubs', 's-1', 'cu-1', 'active', 20.00, 'GBP', 'month', 1, null),
    (p_tenant, v_sgb, 'verifysubs', 's-2', 'cu-2', 'failed', 99.00, 'GBP', 'month', 1, null),
    (p_tenant, v_sgb, 'verifysubs', 's-3', 'cu-3', 'paused', 20.00, 'GBP', 'month', 1, now()),
    (p_tenant, v_sgb, 'verifysubs', 's-4', 'cu-3', 'failed', 99.00, 'GBP', 'month', 1, null),
    (p_tenant, v_sgb, 'verifysubs', 's-5', 'cu-4', 'paused', 20.00, 'GBP', 'month', 1, now()),
    (p_tenant, v_sgb, 'verifysubs', 's-6', 'cu-5', 'canceled', 20.00, 'GBP', 'month', 1, null),
    (p_tenant, v_sgb, 'verifysubs', 's-7', 'cu-6', 'active', 20.00, 'GBP', 'month', 1, null),
    (p_tenant, v_sgb, 'verifysubs', 's-8', 'cu-6', 'failed', 99.00, 'GBP', 'month', 1, null),
    (p_tenant, v_snl, 'verifysubs', 'n-1', 'ncu-1', 'failed', 77.00, 'EUR', 'month', 1, null),
    (p_tenant, v_snl, 'verifysubs', 'n-2', 'ncu-2', 'paused', 30.00, 'EUR', 'month', 1, now());
  return jsonb_build_object('crm', v_crm, 'gb', v_gb, 'nl', v_nl, 'sgb', v_sgb, 'snl', v_snl);
end
$$;

-- Total subscriptions' split of the rows given ([market, status]), as one line: "status value" pairs in order
create or replace function pg_temp.v0008zu_split(p_split jsonb)
returns text
language sql
as $$
  select coalesce(string_agg((x ->> 'key') || ' ' || (x ->> 'value'), ', ' order by o), case when p_split is null then 'none' else '' end)
  from jsonb_array_elements(coalesce(p_split, '[]'::jsonb)) with ordinality u(x, o)
$$;


-- =============================================================================================
-- A. Structure and privileges (universal)
-- =============================================================================================
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_bad     text;
  v_fn      text;
  v_txt     text;
  v_rows    jsonb;
begin
  insert into verify_0008zu values (1, 'A1 addition 0008zu recorded, after 0008zt',
    case when exists (select 1 from cma.schema_migration where version = '0008zu')
              and exists (select 1 from cma.schema_migration where version = '0008zt') and not v_provoke then 'ok' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the overviews: the subscriptions' headline and split set, the customers' as they were; the versions; the split dim
  v_bad := '';
  if (select string_agg(o.key || '|' || o.headline || '|' || o.sets::text || '|' || array_to_string(o.measures, ',') || '|'
                        || array_to_string(o.count_measures, ','), ' ' order by o.sort_order)
      from cma.flash_overviews() o where o.key in ('customers', 'subscriptions'))
     is distinct from
     'customers|active_customers|[[], ["market"], ["market", "store"], ["market", "segment"]]|customers_held,active_customers,paused_customers,linked_to_contact,with_required_refs|customers_held,active_customers,paused_customers,linked_to_contact,with_required_refs '
     || 'subscriptions|holding_subscriptions|[[], ["market"], ["market", "status"], ["market", "store", "status", "payment_state"], ["market", "device_band"], ["market", "age_band"]]|subscriptions,active_subscriptions,paused_subscriptions,amount_per_cycle,holding_subscriptions,devices_on_holding,devices_per_holding_subscription|subscriptions,active_subscriptions,paused_subscriptions,holding_subscriptions,devices_on_holding' then
    v_bad := v_bad || 'the catalog; ';
  end if;
  -- since addition 0008zw (142) the orders' headline is split by order kind too; its definition stays 0008zn
  if (select string_agg(o.key || ':' || cma.flash_definition_version(o.key) || ':' || coalesce(cma.flash_split_dim_of(o.key), '-'), ',' order by o.sort_order)
      from cma.flash_overviews() o)
     is distinct from 'customers:0008zu:-,subscriptions:0008zu:status,installed_base:0008zt:-,churn:0008zn:-,orders:0008zn:'
                      || (case when exists (select 1 from cma.schema_migration where version = '0008zw') then 'kind' else '-' end) || ',payments:0008zn:-,'
                      || 'open_deals:0008zn:-,open_tickets:0008zn:-,open_tasks:0008zn:-,reviews:0008zn:-,data_quality:0008zn:-' then
    v_bad := v_bad || 'versions or split; ';
  end if;
  insert into verify_0008zu values (2, 'A2 the subscriptions'' headline holding_subscriptions and its split set [market, status]; the customers'' as they were; versions 0008zu; the split dim',
    case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_bad);

  -- A3. privileges: the application's only, the caller's rights; the take's writers the owner's; JIT off as 0008zt; the
  --     customers' base sets' columns (0008zt's kept, the new one with holding_subscriptions)
  v_bad := '';
  foreach v_fn in array array[
    'cma.flash_overviews()', 'cma.flash_definition_version(text)', 'cma.flash_split_dim_of(text)', 'cma.flash_split_of(jsonb,text,text,text,text[])',
    'cma.flash_stored_split_of(uuid,text,text,date[])', 'cma.flash_stored_version_of(uuid,text,date[])',
    'cma.flash_customer_figures_of(uuid)', 'cma.flash_store_customers_of(uuid)',
    'cma.flash_compute_of(uuid,text,date,date,date)', 'cma.flash_rows_of(uuid,text,jsonb,text,boolean,integer,integer,date,date)',
    'cma.flash_headline(text,text,date,date)', 'cma.flash_page(text,date,date,date)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure(v_fn) and a.grantee = 0) then
      v_bad := v_bad || v_fn || '; ';
    end if;
  end loop;
  foreach v_fn in array array['cma.flash_snapshot_ids_write_of(uuid,date,uuid)', 'cma.flash_watch_of(uuid,date,timestamptz)'] loop
    if has_function_privilege('cma_app', v_fn, 'execute')
       or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure(v_fn) and a.grantee = 0) then
      v_bad := v_bad || v_fn || ' not the owner''s; ';
    end if;
  end loop;
  foreach v_fn in array array['cma.flash_compute_of(uuid,text,date,date,date)', 'cma.flash_rows_of(uuid,text,jsonb,text,boolean,integer,integer,date,date)',
                              'cma.flash_snapshot_ids_write_of(uuid,date,uuid)', 'cma.flash_watch_of(uuid,date,timestamptz)',
                              'cma.flash_headline(text,text,date,date)'] loop
    if not coalesce((select 'jit=off' = any (proconfig) from pg_proc where oid = to_regprocedure(v_fn)), false) then
      v_bad := v_bad || v_fn || ' jit; ';
    end if;
  end loop;
  if pg_get_function_result('cma.flash_store_customers_of(uuid)'::regprocedure) !~ 'devices integer, segment text\)$'
     or pg_get_function_result('cma.flash_customer_figures_of(uuid)'::regprocedure) !~ 'segment text, holding_subscriptions integer\)$' then
    v_bad := v_bad || 'the base sets'' columns; ';
  end if;
  insert into verify_0008zu values (3, 'A3 privileges: the application''s only, the caller''s rights; the take''s writers the owner''s; JIT off; 0008zt''s base set keeps its columns',
    case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_bad);

  -- A4. the split's helper on given rows: the setting's order, a status without rows 0, another key after them by name,
  --     one market or every market; a row of another set never counted
  v_rows := '[{"dims": {}, "measures": {"holding_subscriptions": 9}},
              {"dims": {"market": "GB"}, "measures": {"holding_subscriptions": 7}},
              {"dims": {"market": "GB", "status": "active"}, "measures": {"holding_subscriptions": 3}},
              {"dims": {"market": "GB", "status": "failed"}, "measures": {"holding_subscriptions": 1}},
              {"dims": {"market": "NL", "status": "active"}, "measures": {"holding_subscriptions": 2}},
              {"dims": {"market": "NL", "status": "zz-other"}, "measures": {"holding_subscriptions": 1}},
              {"dims": {"market": "GB", "store": "x", "status": "active", "payment_state": "paid"}, "measures": {"holding_subscriptions": 50}}]';
  v_txt := pg_temp.v0008zu_split(cma.flash_split_of(v_rows, null, 'status', 'holding_subscriptions', array['failed', 'active', 'never-subscribed']))
           || ' | ' || pg_temp.v0008zu_split(cma.flash_split_of(v_rows, 'GB', 'status', 'holding_subscriptions', array['active', 'failed']))
           || ' | ' || pg_temp.v0008zu_split(cma.flash_split_of(v_rows, 'FR', 'status', 'holding_subscriptions', array['active', 'failed']))
           || ' | ' || pg_temp.v0008zu_split(cma.flash_split_of('[]', null, 'status', 'holding_subscriptions', array['active']));
  insert into verify_0008zu values (4, 'A4 the split''s helper: the setting''s order, zeros, another key after, one market or every market, other sets never counted',
    case when v_txt = 'failed 1, active 5, never-subscribed 0, zz-other 1 | active 3, failed 1 | active 0, failed 0 | active 0' and not v_provoke then 'ok' else 'FAIL' end,
    v_txt);
end
$$;

-- =============================================================================================
-- B. Behaviour on three throwaway tenants (rolled back)
-- =============================================================================================
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  v_t1 uuid; v_t2 uuid; v_t3 uuid;
  v_analyst1 uuid; v_sched1 uuid; v_analyst3 uuid;
  v_c1 jsonb; v_c3 uuid; v_s3 uuid; v_st3 uuid;
  v_txt text; v_a text; v_b text;
  j jsonb; v_r jsonb;
  o record;
  -- the snapshot's dates and the instants of their takes (Europe/Amsterdam, after 00:30): 30 October stored by hand under
  -- 0008zt, 31 October (a month end) and 1 November taken
  v_d0      date := '2026-10-30';
  v_d       date := '2026-10-31';
  v_take_1  timestamptz := '2026-11-01 01:00:00 Europe/Amsterdam';   -- takes 31 October
  v_take_2  timestamptz := '2026-11-02 01:00:00 Europe/Amsterdam';   -- takes 1 November
begin
  begin
    -- tenants and people (as the owner); each tenant's Scheduler user comes with create_tenant
    v_t1 := cma.create_tenant('verify-0008zu-one', 'Verify 0008zu one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008zu-two', 'Verify 0008zu two', 'Europe/Amsterdam');
    v_t3 := cma.create_tenant('verify-0008zu-three', 'Verify 0008zu three', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-analyst1@example.invalid', 'analyst1') returning id into v_analyst1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t3, 'verify-analyst3@example.invalid', 'analyst3') returning id into v_analyst3;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_analyst1, 'analytics'), (v_t3, v_analyst3, 'analytics')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select u.id into v_sched1 from cma.app_user u where u.tenant_id = v_t1 and u.email = 'scheduler@system.invalid';

    -- tenants one and two: the same sources and records; tenant one holds devices in active and failed, tenant two in
    -- active alone (the default); both count B2B and B2C
    v_c1 := pg_temp.v0008zu_fixture(v_t1);
    perform pg_temp.v0008zu_fixture(v_t2);
    insert into cma.tenant_setting (tenant_id, key, value) values
      (v_t1, 'flash.device_holding_statuses', 'active,failed'), (v_t1, 'crm.customer_segments', 'B2B,B2C'), (v_t2, 'crm.customer_segments', 'B2B,B2C');
    -- tenant three: the same ids, one store customer with a failed subscription only; active and failed hold devices
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency, sort_order) values (v_t3, 'GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', 10);
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind) values (v_t3, 'verifyshop', 'Shop three', 'shop-gb.shop.example', 'commerce') returning id into v_st3;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t3, 'verifysubs', 'Subs three', 'shop-gb.shop.example', 'subscriptions', 'verify-subs-three') returning id into v_s3;
    insert into cma.commerce_store (tenant_id, connection_id, handle, name, market, currency, time_zone) values (v_t3, v_st3, 'shop-gb', 'Shop three', 'GB', 'GBP', 'Europe/London');
    insert into cma.commerce_customer (tenant_id, connection_id, source_system, source_id, orders_count) values (v_t3, v_st3, 'verifyshop', 'cu-1', 1);
    insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, amount_per_cycle, currency)
    values (v_t3, v_s3, 'verifysubs', 's-1', 'cu-1', 'failed', 99.00, 'GBP');
    insert into cma.tenant_setting (tenant_id, key, value) values (v_t3, 'flash.device_holding_statuses', 'active,failed');

    -- B1. tenant one's customers: active on the holding statuses (cu-2 failed only, cu-3 paused and failed, cu-6, ncu-1
    --     failed only: active), paused with none holding (cu-4, ncu-2); the segment rows adding up to active_customers
    v_r := pg_temp.v0008zu_rows(v_t1, 'customers', null);
    v_txt := pg_temp.v0008zu_set(v_r, '{}', array['customers_held', 'active_customers', 'paused_customers'])
             || ' ' || pg_temp.v0008zu_set(v_r, array['market'], array['customers_held', 'active_customers', 'paused_customers'])
             || ' ' || pg_temp.v0008zu_set(v_r, array['market', 'segment'], array['active_customers', 'customers_held'])
             || ' | ' || pg_temp.v0008zu_unbalanced(v_r, 'active_customers', 'segment') || pg_temp.v0008zu_unbalanced(v_r, 'customers_held', 'segment');
    v_rows := v_rows || array['11', 'B1 the customers: active on the device-holding statuses (a failed one only, paused and failed), paused with none holding; the segment rows add up to active_customers',
      case when v_txt = ':9,5,2 GB:7,4,1 NL:2,1,1 GB/B2B:2,2 GB/B2C:1,2 GB/unknown:1,3 NL/B2B:1,1 NL/B2C:0,1 | '
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B2. the lists, live, as tenant one's analyst: the active and the paused customers, a customer's holding
    --     subscriptions; a split cell's list (GB, failed); the active subscriptions; a split cell without a record
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);
    j := cma.flash_rows('customers', '{"measure": "active_customers"}', 'customer_id', false, 500, 0);
    v_txt := (select string_agg(x ->> 'customer_id', ',' order by x ->> 'customer_id' collate "C") from jsonb_array_elements(j -> 'rows') x)
             || ' | ' || (select string_agg(x ->> 'customer_id', ',' order by x ->> 'customer_id' collate "C")
                          from jsonb_array_elements(cma.flash_rows('customers', '{"measure": "paused_customers"}', 'customer_id', false, 500, 0) -> 'rows') x)
             || ' | ' || (select string_agg((x ->> 'customer_id') || ':' || (x ->> 'active_subscriptions') || '/' || (x ->> 'paused_subscriptions') || '/' || (x ->> 'holding_subscriptions'),
                                            ' ' order by x ->> 'customer_id' collate "C")
                          from jsonb_array_elements(j -> 'rows') x where x ->> 'customer_id' in ('cu-2', 'cu-3', 'cu-6'))
             || ' | ' || (select string_agg(x ->> 'subscription_id', ',' order by x ->> 'subscription_id' collate "C")
                          from jsonb_array_elements(cma.flash_rows('subscriptions', '{"market": "GB", "status": "failed", "measure": "holding_subscriptions"}',
                                                                   'subscription_id', false, 500, 0) -> 'rows') x)
             || ' ' || (cma.flash_rows('subscriptions', '{"measure": "active_subscriptions"}', 'subscription_id', false, 500, 0) ->> 'total')
             || ' ' || (cma.flash_rows('subscriptions', '{"market": "NL", "status": "active", "measure": "holding_subscriptions"}', 'subscription_id', false, 500, 0) ->> 'total');
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['12', 'B2 the lists: the active customers on the holding statuses, the paused ones, a customer''s holding subscriptions; a split cell''s list',
      case when v_txt = 'cu-1,cu-2,cu-3,cu-6,ncu-1 | cu-4,ncu-2 | cu-2:0/0/1 cu-3:0/1/1 cu-6:1/0/2 | s-2,s-4,s-8 2 0'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B3. tenant one's subscriptions: Total subscriptions (holding_subscriptions) and its split per market and status,
    --     zeros included (NL active 0), adding up per market and in all; the amounts over the paying statuses only (a
    --     failed one's 99 GBP and 77 EUR in none)
    v_r := pg_temp.v0008zu_rows(v_t1, 'subscriptions', null);
    v_txt := pg_temp.v0008zu_set(v_r, '{}', array['subscriptions', 'active_subscriptions', 'paused_subscriptions', 'holding_subscriptions', 'amount_per_cycle'])
             || ' ' || pg_temp.v0008zu_set(v_r, array['market'], array['subscriptions', 'active_subscriptions', 'paused_subscriptions', 'holding_subscriptions', 'amount_per_cycle'])
             || ' ' || pg_temp.v0008zu_set(v_r, array['market', 'status'], array['holding_subscriptions'])
             || ' | ' || pg_temp.v0008zu_unbalanced(v_r, 'holding_subscriptions', 'status')
             || (select coalesce(string_agg((x -> 'dims')::text, ' '), '') from jsonb_array_elements(v_r) x
                 where x -> 'dims' ? 'status' and (select count(*) from jsonb_object_keys(x -> 'dims')) = 2
                   and (select count(*) from jsonb_object_keys(x -> 'measures')) <> 1);
    v_rows := v_rows || array['13', 'B3 the subscriptions: Total subscriptions the sum of its split per holding status, per market too, zeros included; amount_per_cycle over the paying statuses only',
      case when v_txt = ':10,2,3,6,{"GBP": 40.00} GB:8,2,2,5,{"GBP": 40.00} NL:2,0,1,1,{} GB/active:2 GB/failed:3 NL/active:0 NL/failed:1 | '
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B4. tenant one against 0008zt's computation (kept above): the subscriptions' rows other than the split row for row;
    --     the customers' active and paused before and after (the failed ones move)
    v_a := pg_temp.v0008zu_others(pg_temp.v0008zu_rows(v_t1, 'subscriptions', null));
    v_b := (select coalesce(jsonb_agg(jsonb_build_object('dims', c.dims, 'measures', c.measures) order by c.dims::text collate "C"), '[]'::jsonb)::text
            from pg_temp.v0008zu_before(v_t1, 'subscriptions') c);
    v_txt := (v_a = v_b)::text
             || ' ' || (select (c.measures ->> 'active_customers') || '/' || (c.measures ->> 'paused_customers') from pg_temp.v0008zu_before(v_t1, 'customers') c where c.dims = '{}')
             || ' ' || (select (c.measures ->> 'active_customers') || '/' || (c.measures ->> 'paused_customers') from cma.flash_compute_of(v_t1, 'customers') c where c.dims = '{}');
    v_rows := v_rows || array['14', 'B4 tenant one against 0008zt''s computation: the subscriptions'' rows other than the split row for row; the customers'' active and paused before and after',
      case when v_txt = 'true 2/3 5/2' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B5. tenant two (holding statuses active alone, the default): the customers' and the subscriptions' figures as 0008zt
    --     gave them, row for row (the split rows aside); its split the active ones, adding up
    v_r := pg_temp.v0008zu_rows(v_t2, 'subscriptions', null);
    v_txt := (pg_temp.v0008zu_rows(v_t2, 'customers', null)::text
              = (select coalesce(jsonb_agg(jsonb_build_object('dims', c.dims, 'measures', c.measures) order by c.dims::text collate "C"), '[]'::jsonb)::text
                 from pg_temp.v0008zu_before(v_t2, 'customers') c))::text
             || ' ' || (pg_temp.v0008zu_others(v_r)
                        = (select coalesce(jsonb_agg(jsonb_build_object('dims', c.dims, 'measures', c.measures) order by c.dims::text collate "C"), '[]'::jsonb)::text
                           from pg_temp.v0008zu_before(v_t2, 'subscriptions') c))::text
             || ' ' || pg_temp.v0008zu_set(v_r, array['market', 'status'], array['holding_subscriptions'])
             || ' | ' || pg_temp.v0008zu_unbalanced(v_r, 'holding_subscriptions', 'status');
    v_rows := v_rows || array['15', 'B5 a tenant whose holding statuses are active alone: the customers'' and the subscriptions'' figures as before 0008zu, row for row; its split adding up',
      case when v_txt = 'true true GB/active:2 | ' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B6. the headline, live, as tenant one's analyst: Total subscriptions with its split in the setting's order (all, GB,
    --     NL with a zero) and its definition; the customers' headline without a split
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);
    j := cma.flash_headline('subscriptions');
    v_txt := (j ->> 'value') || ' ' || pg_temp.v0008zu_split(j -> 'split') || ' ' || (j ->> 'definition_version');
    j := cma.flash_headline('subscriptions', 'GB');
    v_txt := v_txt || ' | ' || (j ->> 'value') || ' ' || pg_temp.v0008zu_split(j -> 'split');
    j := cma.flash_headline('subscriptions', 'NL');
    v_txt := v_txt || ' | ' || (j ->> 'value') || ' ' || pg_temp.v0008zu_split(j -> 'split');
    j := cma.flash_headline('customers');
    v_txt := v_txt || ' | ' || (j ->> 'value') || ' ' || pg_temp.v0008zu_split(case when jsonb_typeof(j -> 'split') = 'array' then j -> 'split' end)
             || ' ' || (j ->> 'definition_version');
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['16', 'B6 the headline, live: Total subscriptions and its split per holding status in the setting''s order, per market with a zero; its definition; no split for the customers',
      case when v_txt = '6 active 2, failed 4 0008zu | 5 active 2, failed 3 | 1 active 0, failed 1 | 5 none 0008zu' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B7. the take of 31 October (a month end) after 30 October stored by hand under 0008zt (GB's active customers and
    --     holding subscriptions 100): the stored figures equal the computation as of the date (one code path), under
    --     0008zu; the month end's customer list the active customers as now counted, the subscriptions' the paying ones; no
    --     jump across the change of definition
    insert into cma.flash_snapshot_run (id, tenant_id, snapshot_date, due_at, started_at, finished_at, status)
    values (uuidv7(), v_t1, v_d0, cma.flash_due_at_of('Europe/Amsterdam', '00:30', v_d0), now(), now(), 'succeeded');
    insert into cma.flash_snapshot (tenant_id, snapshot_date, overview, dims, measures, definition_version, computed_at, run_id)
    select v_t1, v_d0, x.ov, x.dims::jsonb, x.measures::jsonb, '0008zt', now(),
           (select r.id from cma.flash_snapshot_run r where r.tenant_id = v_t1 and r.snapshot_date = v_d0)
    from (values ('customers', '{}', '{"customers_held": 9, "active_customers": 3, "paused_customers": 3, "linked_to_contact": 6}'),
                 ('customers', '{"market": "GB"}', '{"customers_held": 7, "active_customers": 100, "paused_customers": 2, "linked_to_contact": 4}'),
                 ('subscriptions', '{}', '{"subscriptions": 10, "active_subscriptions": 2, "paused_subscriptions": 3, "holding_subscriptions": 5, "amount_per_cycle": {"GBP": 40}}'),
                 ('subscriptions', '{"market": "GB"}', '{"subscriptions": 8, "active_subscriptions": 2, "paused_subscriptions": 2, "holding_subscriptions": 100, "amount_per_cycle": {"GBP": 40}}'))
         as x(ov, dims, measures);
    insert into cma.sync_run (tenant_id, connection_id, job, started_at, finished_at, status)
    select v_t1, (v_c1 ->> c)::uuid, 'reconcile', v_take_1 - interval '2 hours', v_take_1 - interval '1 hour', 'succeeded'
    from unnest(array['crm', 'gb', 'nl', 'sgb', 'snl']) c;
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_sched1::text, true);
    j := cma.flash_snapshot_take_at(v_t1, v_take_1);
    v_txt := (j ->> 'taken') || ' ' || (j ->> 'date') || ' |';
    for o in select x.key from cma.flash_overviews() x where x.key in ('customers', 'subscriptions') order by x.sort_order loop
      v_a := (select coalesce(jsonb_agg(jsonb_build_object('dims', s.dims, 'measures', s.measures) order by s.dims::text collate "C"), '[]'::jsonb)::text
              from cma.flash_snapshot s where s.tenant_id = v_t1 and s.snapshot_date = v_d and s.overview = o.key);
      v_b := pg_temp.v0008zu_rows(v_t1, o.key, v_d)::text;
      v_txt := v_txt || ' ' || o.key || ':' || (v_a = v_b)::text || ':'
               || (select string_agg(distinct s.definition_version, ',') from cma.flash_snapshot s where s.tenant_id = v_t1 and s.snapshot_date = v_d and s.overview = o.key);
    end loop;
    v_txt := v_txt || ' | ' || coalesce((select string_agg(i.source_id, ',' order by i.source_id collate "C") from cma.flash_snapshot_ids i
                                         where i.tenant_id = v_t1 and i.snapshot_date = v_d and i.record_kind = 'customer'), '-')
             || ' ' || coalesce((select string_agg(i.source_id, ',' order by i.source_id collate "C") from cma.flash_snapshot_ids i
                                 where i.tenant_id = v_t1 and i.snapshot_date = v_d and i.record_kind = 'subscription'), '-')
             || ' | ' || coalesce((select string_agg(f.overview || '/' || f.measure || '/' || (f.dims ->> 'market'), ' ' order by f.overview collate "C", f.measure collate "C")
                                   from cma.flash_watch_finding f
                                   where f.tenant_id = v_t1 and f.state = 'open' and f.kind = 'jump' and f.overview in ('customers', 'subscriptions')), '-');
    v_rows := v_rows || array['17', 'B7 the take: stored as computed as of its date, under 0008zu; the month end''s customer list on the holding statuses; no jump across the change of definition',
      case when v_txt = 'true 2026-10-31 | customers:true:0008zu subscriptions:true:0008zu | cu-1,cu-2,cu-3,cu-6,ncu-1 s-1,s-7 | -'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B8. the landing, as tenant one's analyst: as of 31 October the stored Total subscriptions and its split, the figure's
    --     definition and the definition of the one it is compared with (30 October, 0008zt), the customers' too; GB's; now,
    --     the definitions alike and no stored split (a live card reads its own)
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_analyst1::text, true);
    j := cma.flash_page(null, v_d);
    v_txt := (select string_agg(c ->> 'key' || ' ' || (c ->> 'value') || ' ' || pg_temp.v0008zu_split(case when jsonb_typeof(c -> 'split') = 'array' then c -> 'split' end)
                                || ' ' || (c ->> 'definition_version') || ' ' || coalesce(c ->> 'previous', '-') || ' ' || coalesce(c ->> 'previous_on', '-')
                                || ' ' || coalesce(c ->> 'previous_definition_version', '-'), ' | ' order by c ->> 'key' collate "C")
              from jsonb_array_elements(j -> 'overviews') c where c ->> 'key' in ('customers', 'subscriptions'));
    j := cma.flash_page();
    v_txt := v_txt || ' | live ' || (select (c ->> 'definition_version') || ' ' || coalesce(c ->> 'previous_definition_version', '-') || ' ' || coalesce(c ->> 'previous', '-')
                                            || ' ' || pg_temp.v0008zu_split(case when jsonb_typeof(c -> 'split') = 'array' then c -> 'split' end)
                                     from jsonb_array_elements(j -> 'overviews') c where c ->> 'key' = 'subscriptions');
    j := cma.flash_page('GB', v_d);
    v_txt := v_txt || ' | GB ' || (select (c ->> 'value') || ' ' || pg_temp.v0008zu_split(c -> 'split') || ' ' || coalesce(c ->> 'previous', '-')
                                   from jsonb_array_elements(j -> 'overviews') c where c ->> 'key' = 'subscriptions');
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['18', 'B8 the landing: as of a date the stored split and the definitions of the figure and of the one it is compared with; now the definitions alike',
      case when v_txt = 'customers 5 none 0008zu 3 2026-10-30 0008zt | subscriptions 6 active 2, failed 4 0008zu 5 2026-10-30 0008zt | live 0008zu 0008zu 6 none | GB 5 active 2, failed 3 100'
                and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B9. the watch within one definition: 31 October's GB active customers set to 100 by hand, the take of 1 November
    --     finds the jump (both dates under 0008zu)
    update cma.flash_snapshot s set measures = s.measures || '{"active_customers": 100}'
    where s.tenant_id = v_t1 and s.snapshot_date = v_d and s.overview = 'customers' and s.dims = '{"market": "GB"}';
    insert into cma.sync_run (tenant_id, connection_id, job, started_at, finished_at, status)
    select v_t1, (v_c1 ->> c)::uuid, 'reconcile', v_take_2 - interval '2 hours', v_take_2 - interval '1 hour', 'succeeded'
    from unnest(array['crm', 'gb', 'nl', 'sgb', 'snl']) c;
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_sched1::text, true);
    j := cma.flash_snapshot_take_at(v_t1, v_take_2);
    v_txt := (j ->> 'taken') || ' ' || (j ->> 'date') || ' | '
             || coalesce((select string_agg(f.overview || '/' || f.measure || '/' || (f.dims ->> 'market') || ':' || f.value || ':' || f.previous, ' '
                                            order by f.overview collate "C", f.measure collate "C")
                          from cma.flash_watch_finding f
                          where f.tenant_id = v_t1 and f.state = 'open' and f.kind = 'jump' and f.overview in ('customers', 'subscriptions')), '-');
    v_rows := v_rows || array['19', 'B9 the watch within one definition: a jump of active_customers between two dates under 0008zu is found',
      case when v_txt = 'true 2026-11-01 | customers/active_customers/GB:4:100' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- B10. tenant isolation, as the application: tenant one's Total subscriptions without tenant three's failed one;
    --      tenant three's own (its customer with a failed subscription only active, not paused)
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_txt := cma.flash_headline('subscriptions') ->> 'value';
    perform set_config('app.tenant_id', v_t3::text, true);
    perform set_config('app.user_id', v_analyst3::text, true);
    j := cma.flash_headline('subscriptions');
    v_txt := v_txt || ' | ' || (j ->> 'value') || ' ' || pg_temp.v0008zu_split(j -> 'split');
    j := cma.flash_overview('customers');
    v_txt := v_txt || ' | ' || (j -> 'totals' ->> 'active_customers') || ' ' || (j -> 'totals' ->> 'paused_customers');
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['20', 'B10 tenant isolation: each tenant''s Total subscriptions and active customers its own',
      case when v_txt = '6 | 1 active 0, failed 1 | 1 0' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['29', 'B the block ran to the end', 'FAIL', sqlstate || ' ' || sqlerrm];
  end;
  insert into verify_0008zu (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008zu values (29, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- =============================================================================================
-- D. Every tenant's own figures, live, read only: Total subscriptions and the active customers add up, in all and per
--    market
-- =============================================================================================
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  t         record;
  v_r       jsonb;
  v_bad     text;
  v_n       integer;
begin
  -- D1. the subscriptions: holding_subscriptions the sum of its split, every split status a holding one
  v_bad := ''; v_n := 0;
  for t in select x.id, x.slug from cma.tenant x where coalesce((cma.flash_sources_of(x.id) -> 'subscriptions' ->> 'set_up')::boolean, false) order by x.slug loop
    v_n := v_n + 1;
    v_r := pg_temp.v0008zu_rows(t.id, 'subscriptions', null);
    v_bad := v_bad || pg_temp.v0008zu_unbalanced(v_r, 'holding_subscriptions', 'status')
             || coalesce((select string_agg(t.slug || ' ' || (x -> 'dims' ->> 'status') || ' not holding', '; ')
                          from jsonb_array_elements(v_r) x
                          where x -> 'dims' ? 'status' and (select count(*) from jsonb_object_keys(x -> 'dims')) = 2
                            and not ((x -> 'dims' ->> 'status') = any (cma.flash_holding_statuses_of(t.id)))), '');
  end loop;
  insert into verify_0008zu values (41, 'D1 every tenant''s subscriptions: Total subscriptions the sum of its split, per market too; every split status a holding one',
    case when v_n = 0 then 'skip' when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end,
    case when v_n = 0 then 'no tenant with a subscriptions connection set up' else v_n || ' tenant(s) ' || v_bad end);

  -- D2. the customers: active_customers the sum over segment; active and paused customers at most the customers held
  v_bad := ''; v_n := 0;
  for t in select x.id, x.slug from cma.tenant x where coalesce((cma.flash_sources_of(x.id) -> 'commerce' ->> 'set_up')::boolean, false) order by x.slug loop
    v_n := v_n + 1;
    v_r := pg_temp.v0008zu_rows(t.id, 'customers', null);
    v_bad := v_bad || pg_temp.v0008zu_unbalanced(v_r, 'active_customers', 'segment')
             || coalesce((select string_agg(t.slug || ' ' || (x -> 'dims')::text || ' over the held', '; ')
                          from jsonb_array_elements(v_r) x
                          where (x -> 'measures' ->> 'active_customers')::numeric + (x -> 'measures' ->> 'paused_customers')::numeric
                                > (x -> 'measures' ->> 'customers_held')::numeric), '');
  end loop;
  insert into verify_0008zu values (42, 'D2 every tenant''s customers: active_customers the sum over segment, per market too; active and paused at most the customers held',
    case when v_n = 0 then 'skip' when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end,
    case when v_n = 0 then 'no tenant with a store set up' else v_n || ' tenant(s) ' || v_bad end);
end
$$;

-- =============================================================================================
-- C. Speed at volume (rolled back; local databases only, with verify.volume 'true' at the top): 137's volume of store
--    customers, subscriptions and devices, active and failed holding devices; the customers' and the subscriptions'
--    overviews, the subscriptions' headline and the landing live, as the application, each the best of two. The volume's
--    audit triggers are disabled inside the block (an exclusive lock on those tables until the rollback, which enables
--    them again)
-- =============================================================================================
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_max_o   numeric := current_setting('verify.max_overview_ms')::numeric;
  v_rows    text[] := '{}';
  v_t uuid; v_analyst uuid;
  v_crm uuid; v_gb uuid; v_nl uuid; v_sgb uuid; v_snl uuid; v_reg uuid;
  v_read text; v_ms numeric; v_best numeric; v_t0 timestamptz; v_txt text := ''; v_bad text := '';
  j jsonb;
begin
  if not current_setting('verify.volume')::boolean then
    insert into verify_0008zu values (51, 'C1 the customers'' and subscriptions'' overviews, the headline and the landing live at volume, under verify.max_overview_ms', 'skip', 'not run: volume off');
    return;
  end if;
  begin
    perform set_config('lock_timeout', '10s', true);
    alter table cma.commerce_customer disable trigger audit;
    alter table cma.crm_contact disable trigger audit;
    alter table cma.subscription disable trigger audit;
    alter table cma.device disable trigger audit;
    perform set_config('lock_timeout', '0', true);
    v_t := cma.create_tenant('verify-0008zu-volume', 'Verify 0008zu volume', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-analyst-volume@example.invalid', 'analyst') returning id into v_analyst;
    insert into cma.user_role (tenant_id, user_id, role_id) select v_t, v_analyst, ar.id from cma.app_role ar where ar.tenant_id = v_t and ar.key = 'analytics';
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency, sort_order) values
      (v_t, 'GB', 'GB', 'Europe/London', 'en', 'GBP', 10), (v_t, 'NL', 'NL', 'Europe/Amsterdam', 'nl', 'EUR', 20);
    insert into cma.tenant_setting (tenant_id, key, value) values (v_t, 'crm.customer_segments', 'B2B,B2C'), (v_t, 'flash.device_holding_statuses', 'active,failed');
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind) values (v_t, 'verifycrm', 'CRM', 'portal-v', 'crm') returning id into v_crm;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind) values (v_t, 'verifyshop', 'Shop GB', 'vol-gb.shop.example', 'commerce') returning id into v_gb;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind) values (v_t, 'verifyshop', 'Shop NL', 'vol-nl.shop.example', 'commerce') returning id into v_nl;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind) values (v_t, 'verifysubs', 'Subs GB', 'vol-gb.shop.example', 'subscriptions') returning id into v_sgb;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind) values (v_t, 'verifysubs', 'Subs NL', 'vol-nl.shop.example', 'subscriptions') returning id into v_snl;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind) values (v_t, 'verifyregister', 'Register', 'base-v', 'assets') returning id into v_reg;
    insert into cma.commerce_store (tenant_id, connection_id, handle, name, market, currency, time_zone) values
      (v_t, v_gb, 'vol-gb', 'GB', 'GB', 'GBP', 'Europe/London'), (v_t, v_nl, 'vol-nl', 'NL', 'NL', 'EUR', 'Europe/Amsterdam');
    -- 100,000 store customers, a third linked to a contact, half of those held with a segment (B2B, b2c, Retail or none)
    insert into cma.commerce_customer (tenant_id, connection_id, source_system, source_id, orders_count, crm_connection_id, crm_contact_source_id, matched_at)
    select v_t, case when g % 2 = 0 then v_gb else v_nl end, 'verifyshop', 'cu-' || g, g % 7,
           case when g % 3 = 0 then v_crm end, case when g % 3 = 0 then 'c-' || g end, case when g % 3 = 0 then now() end
    from generate_series(1, 100000) g;
    analyze cma.commerce_customer;
    insert into cma.crm_contact (tenant_id, connection_id, source_system, source_id, country, segment)
    select v_t, v_crm, 'verifycrm', 'c-' || g, case when g % 2 = 0 then 'GB' else 'NL' end, (array['B2B', 'b2c', 'Retail', null])[1 + (g / 6) % 4]
    from generate_series(6, 100000, 6) g;
    analyze cma.crm_contact;
    -- 100,000 subscriptions, one per customer, created over six years; a tenth failed
    insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, amount_per_cycle, currency,
                                  billing_interval, billing_interval_count, paused_at, source_created_at)
    select v_t, case when g % 2 = 0 then v_sgb else v_snl end, 'verifysubs', 's-' || g, 'cu-' || g,
           (array['active', 'active', 'active', 'active', 'active', 'active', 'paused', 'canceled', 'expired', 'failed'])[1 + g % 10],
           10 + g % 30, case when g % 2 = 0 then 'GBP' else 'EUR' end, 'month', 1, case when g % 10 = 6 then now() end,
           case when g % 50 <> 0 then now() - make_interval(days => g % 2200) end
    from generate_series(1, 100000) g;
    analyze cma.subscription;
    -- 50,000 devices in the field (with a subscription reference, some two on one subscription) or in stock
    insert into cma.device_model (tenant_id, key, name) values (v_t, 'm1', 'M1');
    insert into cma.device_status (tenant_id, key, name, is_in_field, is_in_stock, is_tracked) values
      (v_t, 'field', 'Field', true, false, true), (v_t, 'stock', 'Stock', false, true, true);
    insert into cma.device (tenant_id, connection_id, source_system, source_id, serial, model_key, market, device_status_key, customer_ref, subscription_ref, first_shipped_on)
    select v_t, v_reg, 'verifyregister', 'rec-' || g, 'SN-' || g, 'm1', case when (g % 40000) % 2 = 0 then 'GB' else 'NL' end,
           case when g % 5 = 0 then 'stock' else 'field' end, 'cu-' || (g % 40000), case when g % 7 <> 0 then 's-' || (g % 40000) end, date '2023-01-01' + (g % 1000)
    from generate_series(1, 50000) g;
    analyze cma.device;

    -- C1. the customers' and the subscriptions' overviews, the subscriptions' headline and the landing, live, as the
    --     application, each the best of two
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('app.user_id', v_analyst::text, true);
    foreach v_read in array array['customers', 'subscriptions', 'headline', 'landing'] loop
      v_best := null;
      for i in 1 .. 2 loop
        v_t0 := clock_timestamp();
        j := case v_read when 'headline' then cma.flash_headline('subscriptions') when 'landing' then cma.flash_page() else cma.flash_overview(v_read) end;
        v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
        v_best := least(coalesce(v_best, v_ms), v_ms);
      end loop;
      v_txt := v_txt || v_read || ' ' || v_best || ' ms; ';
      if v_best >= v_max_o then v_bad := v_bad || v_read || '; '; end if;
    end loop;
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['51', 'C1 the customers'' and subscriptions'' overviews, the headline and the landing live at volume, under verify.max_overview_ms',
      case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, v_txt || case when v_bad <> '' then ' | over: ' || v_bad else '' end];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['59', 'C the block ran to the end', 'FAIL', sqlstate || ' ' || sqlerrm];
  end;
  insert into verify_0008zu (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
end
$$;

-- Block C analysed its volume inside its transaction; after a run with the volume on, the tables are analysed again, so
-- their statistics are their own (nothing is analysed when block C did not run)
do $$
begin
  if current_setting('verify.volume')::boolean then
    analyze cma.commerce_customer, cma.crm_contact, cma.subscription, cma.device;
  end if;
end
$$;

-- The helpers are dropped first, so the verdict is the last thing the script prints
drop function if exists pg_temp.v0008zu_code(text);
drop function if exists pg_temp.v0008zu_rows(uuid, text, date);
drop function if exists pg_temp.v0008zu_set(jsonb, text[], text[]);
drop function if exists pg_temp.v0008zu_unbalanced(jsonb, text, text);
drop function if exists pg_temp.v0008zu_others(jsonb);
drop function if exists pg_temp.v0008zu_before(uuid, text, date, date, date);
drop function if exists pg_temp.v0008zu_fixture(uuid);
drop function if exists pg_temp.v0008zu_split(jsonb);

-- Verdict: one row per check, then the verdict: no FAIL, and a skip only where the check says why (the volume off; no
-- tenant with the source set up)
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008zu
      union all
      select 99, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from verify_0008zu where result not in ('ok', 'skip')) then 'FAIL'
                  when (select count(*) from verify_0008zu where result = 'ok') >= 14 then '0008zu verified'
                  else 'FAIL' end,
             format('139_verify_flash_totals: %s ok, %s FAIL, %s skip', (select count(*) from verify_0008zu where result = 'ok'),
                    (select count(*) from verify_0008zu where result not in ('ok', 'skip')),
                    (select count(*) from verify_0008zu where result = 'skip'))) x
order by ord;
reset role;
