-- =============================================================================================
-- 138_flash_totals.sql: addition 0008zu, Flash: Total subscriptions and the active customers on the device-holding
-- statuses (brief B30)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics: which statuses hold devices is the tenant setting
-- flash.device_holding_statuses (Pulse4all's, active and failed, are seed 02's since 0008zt), and a status is shown in
-- the subscription app's own word. Runs unchanged in every database, after 136_flash_insights.sql (0008zt). Rerunnable,
-- forward-only, in one transaction with a lock timeout. Run as your own IAM login, away from minute 20 (the hourly
-- snapshot job): dev first, then 139_verify_flash_totals.sql there, then 123_verify_flash.sql and
-- 137_verify_flash_insights.sql again (their expected figures follow 0008zu since this change); then prod, with 139,
-- 123 and 137. No table, view or column changes, and no setting: seed 02 need not run again. The web of main runs
-- unchanged on it (the landing's and the headline's new keys are extra; the subscriptions card shows the new headline
-- under main's old caption until the web of this change is deployed): in prod the script runs before the merge.
--
-- Why (brief B30, Martin, 5 November 2026): a failed subscription still holds its devices and its customer is still a
-- customer (Bas, 0008zt), so Reports → Flash's two first figures count the device-holding statuses:
--   Subscriptions   the headline is Total subscriptions (holding_subscriptions: the subscriptions whose status is in
--                   flash.device_holding_statuses), split per holding status (a grouping set [market, status] whose rows
--                   carry holding_subscriptions only: every holding status of the setting for each market with a
--                   holding subscription, zeros included, so the split adds up to the figure per market too)
--   Customers       active_customers counts the store customers with at least one subscription in a device-holding
--                   status (one whose only subscription failed is a customer), paused_customers those with a paused
--                   subscription and none in a holding status; the segment rows follow active_customers
-- flash.active_subscription_statuses keeps meaning paying: active_subscriptions stays the active part of the total and
-- amount_per_cycle stays over the paying statuses only (a failed subscription's amount is not counted). Churn's active
-- subscriptions at the period's end are unchanged.
--
-- What it changes (functions only; live and the snapshot stay one computation, cma.flash_compute_of):
--   overviews     cma.flash_overviews(): the subscriptions' headline holding_subscriptions and the set [market, status];
--                 cma.flash_definition_version(): 0008zu for customers and subscriptions (the installed base stays
--                 0008zt), so the snapshots say which definition they were computed by. Snapshots already taken keep
--                 their stored figures and version
--   base set      cma.flash_customer_figures_of(tenant): the customers' base set with holding_subscriptions (their
--                 subscriptions in a device-holding status); cma.flash_store_customers_of(tenant) reads it with 0008zt's
--                 columns (a function never changes its columns in place, so 136 can run again before this)
--   figures       cma.flash_compute_of: the customers on the holding statuses, the subscriptions' split rows
--   lists         cma.flash_rows_of: a customer's list on the holding statuses, each customer with its holding_subscriptions
--   the cards     cma.flash_headline: the split ([{key, value}] in the setting's order, zeros included) and the definition
--                 version; cma.flash_page: As of a date, the split stored and the version the stored figure followed,
--                 and for every card the version the figure it is compared with followed, so the page marks a change of
--                 definition where it compares across one (cma.flash_split_dim_of, cma.flash_split_of,
--                 cma.flash_stored_split_of, cma.flash_stored_version_of)
--   the take      cma.flash_snapshot_ids_write_of: a month end's customer list is the active customers as now counted;
--                 cma.flash_watch_of: an overview whose definition changed between the two dates is not compared, so
--                 the first take after this is no jump of active_customers
-- The month end's subscription list stays the active (paying) subscriptions: a past month end's list answers
-- active_subscriptions, as before. SQLSTATEs as before.
--
-- Guard: scripts run under a personal IAM login so the audit trail names a person. postgres is
-- for emergencies only; to use it deliberately, run first:  set cma.emergency = 'on';
do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;

begin;
set local lock_timeout = '5s';
set role cma_owner;

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0008zt') then
    raise exception 'addition 0008zt (136_flash_insights.sql) must run before 0008zu';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The overviews: the subscriptions' headline and split, the definition version
-- ---------------------------------------------------------------------------------------------
-- As 0008zt (136), with the subscriptions' headline holding_subscriptions (Total subscriptions) and its split per
-- device-holding status, the grouping set [market, status] (its rows carry holding_subscriptions only)
create or replace function cma.flash_overviews()
returns table (key text, sort_order integer, kind text, source text, dims text[], sets jsonb, measures text[], count_measures text[],
               headline text, sorts text[])
language sql immutable
as $$
  values
    ('customers', 10, 'stock', 'commerce', array['market', 'store', 'segment'], '[[], ["market"], ["market", "store"], ["market", "segment"]]'::jsonb,
       array['customers_held', 'active_customers', 'paused_customers', 'linked_to_contact', 'with_required_refs'],
       array['customers_held', 'active_customers', 'paused_customers', 'linked_to_contact', 'with_required_refs'], 'active_customers',
       array['lifetime_orders', 'total_spent', 'customer_id', 'store', 'market', 'active_subscriptions', 'devices']),
    ('subscriptions', 20, 'stock', 'subscriptions', array['market', 'store', 'status', 'payment_state', 'device_band', 'age_band'],
       '[[], ["market"], ["market", "status"], ["market", "store", "status", "payment_state"], ["market", "device_band"], ["market", "age_band"]]'::jsonb,
       array['subscriptions', 'active_subscriptions', 'paused_subscriptions', 'amount_per_cycle', 'holding_subscriptions', 'devices_on_holding',
             'devices_per_holding_subscription'],
       array['subscriptions', 'active_subscriptions', 'paused_subscriptions', 'holding_subscriptions', 'devices_on_holding'], 'holding_subscriptions',
       array['subscription_id', 'store', 'market', 'status', 'payment_state', 'amount_per_cycle', 'next_billing_at', 'retry_since', 'devices']),
    ('installed_base', 30, 'stock', 'assets', array['market', 'status', 'model', 'warehouse', 'link', 'subscription_status'],
       '[[], ["market"], ["market", "status", "model", "warehouse", "link"], ["market", "subscription_status"]]'::jsonb,
       array['devices', 'in_field', 'in_stock', 'components_past_due', 'items_due_3m', 'in_field_on_holding'],
       array['devices', 'in_field', 'in_stock', 'components_past_due', 'items_due_3m', 'in_field_on_holding'], 'in_field',
       array['serial', 'model', 'market', 'status', 'warehouse', 'past_due_items', 'next_due_on']),
    ('churn', 40, 'flow', 'subscriptions', array['market', 'store', 'reason'], '[[], ["market"], ["market", "store", "reason"]]'::jsonb,
       array['churned'], array['churned'], 'churned',
       array['churned_at', 'subscription_id', 'store', 'market', 'reason', 'cycles']),
    ('orders', 50, 'flow', 'commerce', array['market', 'store', 'kind', 'sku'],
       '[[], ["market"], ["market", "store", "kind"], ["market", "sku"]]'::jsonb,
       array['orders', 'units', 'amount'], array['orders'], 'orders',
       array['created_at', 'order_number', 'store', 'market', 'kind', 'total']),
    ('payments', 60, 'flow', 'commerce', array['market', 'store', 'kind', 'status'],
       '[[], ["market"], ["market", "store", "kind", "status"]]'::jsonb,
       array['orders', 'amount', 'renewals', 'failed_renewals'], array['orders', 'renewals', 'failed_renewals'], 'failed_renewals',
       array['at', 'kind', 'status', 'amount', 'store', 'market']),
    ('open_deals', 70, 'stock', 'crm', array['market', 'pipeline', 'stage'], '[[], ["market"], ["market", "pipeline", "stage"]]'::jsonb,
       array['open_deals', 'median_age_days', 'oldest_age_days'], array['open_deals'], 'open_deals',
       array['age_days', 'created_at', 'record_id', 'pipeline', 'stage', 'market']),
    ('open_tickets', 80, 'stock', 'crm', array['market', 'queue', 'stage'], '[[], ["market"], ["market", "queue", "stage"]]'::jsonb,
       array['open_tickets', 'median_age_days', 'oldest_age_days'], array['open_tickets'], 'open_tickets',
       array['age_days', 'created_at', 'record_id', 'queue', 'stage', 'market']),
    ('open_tasks', 90, 'stock', 'crm', array['market', 'type', 'status'], '[[], ["market"], ["market", "type", "status"]]'::jsonb,
       array['open_tasks', 'overdue'], array['open_tasks', 'overdue'], 'open_tasks',
       array['due_at', 'task_id', 'type', 'status', 'market']),
    ('reviews', 100, 'flow', 'reviews', array['market', 'rating'], '[[], ["market"], ["market", "rating"]]'::jsonb,
       array['reviews', 'rating_sum', 'negative'], array['reviews', 'negative'], 'reviews',
       array['submitted_at', 'rating', 'market', 'review_id']),
    ('data_quality', 110, 'stock', null, array['check', 'market'], '[[], ["market"], ["check"], ["check", "market"]]'::jsonb,
       array['findings'], array['findings'], 'findings',
       array['object_id', 'check', 'market'])
$$;

-- The definition every figure of an overview follows; a later change of a definition gives a new version, so a
-- snapshot says which one it was computed by (0008zu: customers and subscriptions)
create or replace function cma.flash_definition_version(p_overview text)
returns text
language sql immutable
as $$
  select case when p_overview in ('customers', 'subscriptions') then '0008zu'
              when p_overview = 'installed_base' then '0008zt'
              when p_overview in (select o.key from cma.flash_overviews() o) then '0008zn' end
$$;

-- The dim a headline is split by (the subscriptions' Total subscriptions per device-holding status), none for another
-- overview
create or replace function cma.flash_split_dim_of(p_overview text)
returns text
language sql immutable
as $$
  select case when p_overview = 'subscriptions' then 'status' end
$$;

-- A headline's split: of the rows given, those whose dims are a market and the split dim, the market's or summed over
-- every market, as [{key, value}]: every key of p_order (the tenant's device-holding statuses, in the setting's order),
-- 0 where no row holds it, then any other key a row holds, by name
create or replace function cma.flash_split_of(p_rows jsonb, p_market text, p_dim text, p_measure text, p_order text[])
returns jsonb
language sql immutable
as $$
  with f as (
    select r -> 'dims' ->> p_dim as k, sum((r -> 'measures' ->> p_measure)::numeric) as v
    from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) r
    where r -> 'dims' ? p_dim and r -> 'dims' ? 'market' and (select count(*) from jsonb_object_keys(r -> 'dims')) = 2
      and (p_market is null or r -> 'dims' ->> 'market' = p_market)
      and jsonb_typeof(r -> 'measures' -> p_measure) = 'number'
    group by 1
  ), k as (
    select x as k from unnest(coalesce(p_order, '{}'::text[])) x
    union
    select f.k from f
  )
  select coalesce(jsonb_agg(jsonb_build_object('key', k.k, 'value', coalesce(f.v, 0)) order by array_position(p_order, k.k) nulls last, k.k),
                  '[]'::jsonb)
  from k left join f on f.k = k.k
$$;

-- A stored headline's split over a set of snapshot dates (a stock overview's one date): the split rows the snapshots
-- hold, the market's or summed over every market; null when they hold none (a snapshot taken before 0008zu, or no
-- holding subscription that day)
create or replace function cma.flash_stored_split_of(p_tenant_id uuid, p_overview text, p_market text, p_dates date[])
returns jsonb
language sql stable
as $$
  with r as (
    select jsonb_agg(jsonb_build_object('dims', s.dims, 'measures', s.measures)) as rows
    from cma.flash_snapshot s
    where s.tenant_id = p_tenant_id and s.overview = p_overview and s.snapshot_date = any (coalesce(p_dates, '{}'::date[]))
      and cma.flash_split_dim_of(p_overview) is not null and s.dims ? cma.flash_split_dim_of(p_overview)
      and (select count(*) from jsonb_object_keys(s.dims)) = 2
  )
  select case when r.rows is not null
              then cma.flash_split_of(r.rows, p_market, cma.flash_split_dim_of(p_overview), o.headline, cma.flash_holding_statuses_of(p_tenant_id)) end
  from r cross join cma.flash_overviews() o
  where o.key = p_overview
$$;

-- The definition an overview's stored figures over a set of snapshot dates were computed by (the earliest when they
-- differ, as the document says); null when no date holds the overview
create or replace function cma.flash_stored_version_of(p_tenant_id uuid, p_overview text, p_dates date[])
returns text
language sql stable
as $$
  select min(s.definition_version) from cma.flash_snapshot s
  where s.tenant_id = p_tenant_id and s.overview = p_overview and s.snapshot_date = any (coalesce(p_dates, '{}'::date[]))
    and s.dims = '{}'::jsonb
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. The customers' base set: their subscriptions in a device-holding status
-- ---------------------------------------------------------------------------------------------
-- As 0008zt's cma.flash_store_customers_of (136), with holding_subscriptions: the customer's subscriptions (of its
-- store, not missing) whose status is in flash.device_holding_statuses (0008zu). active_subscriptions stays the paying
-- ones (flash.active_subscription_statuses), paused_subscriptions the paused ones
create or replace function cma.flash_customer_figures_of(p_tenant_id uuid)
returns table (customer_id uuid, connection_id uuid, source_id text, store text, market text, lifetime_orders integer, total_spent numeric,
               currency text, crm_connection_id uuid, contact_source_id text, contact_held boolean, refs jsonb, missing_refs text[],
               active_subscriptions integer, paused_subscriptions integer, devices integer, segment text, holding_subscriptions integer)
language sql stable
as $$
  with s as materialized (
    select cma.flash_active_statuses_of(p_tenant_id) as active, cma.flash_holding_statuses_of(p_tenant_id) as holding,
           cma.flash_list_of(cma.setting_of(p_tenant_id, 'commerce.required_contact_refs')) as refs,
           cma.flash_list_of(cma.setting_of(p_tenant_id, 'crm.customer_segments')) as segments,
           array(select lower(x) from unnest(cma.flash_list_of(cma.setting_of(p_tenant_id, 'crm.customer_segments'))) with ordinality u(x, o)
                 order by o) as segments_lower
  ), st as materialized (
    select x.connection_id, x.handle, x.market from cma.commerce_store x where x.tenant_id = p_tenant_id
  ), sm as materialized (
    select * from cma.flash_subscription_stores_of(p_tenant_id)
  ), sub as materialized (
    select sm.store_connection_id, sb.customer_source_id,
           count(*) filter (where sb.status = any (s.active))::integer as active,
           count(*) filter (where sb.status = 'paused')::integer as paused,
           count(*) filter (where sb.status = any (s.holding))::integer as holding
    from cma.subscription sb
    join sm on sm.connection_id = sb.connection_id
    cross join s
    where sb.tenant_id = p_tenant_id and sb.source_deleted_at is null and sb.customer_source_id is not null
    group by 1, 2
  ), dev as materialized (
    select d.customer_ref, d.market, count(*)::integer as n
    from cma.device d
    where d.tenant_id = p_tenant_id and d.source_deleted_at is null and d.customer_ref is not null
    group by 1, 2
  ), refs as materialized (
    select x.contact_id, jsonb_object_agg(x.system, x.external_id) as refs
    from (select distinct on (cr.contact_id, cr.system) cr.contact_id, cr.system, cr.external_id
          from cma.crm_contact_ref cr cross join s
          where cr.tenant_id = p_tenant_id and cr.system = any (s.refs)
          order by cr.contact_id, cr.system, cr.slot) x
    group by 1
  )
  select cu.id, cu.connection_id, cu.source_id, coalesce(st.handle, 'unknown'), coalesce(st.market, 'unknown'), cu.orders_count,
         cu.amount_spent, cu.amount_currency, cu.crm_connection_id, cu.crm_contact_source_id, k.id is not null,
         coalesce(r.refs, '{}'::jsonb),
         case when cu.crm_contact_source_id is null then '{}'::text[]
              else array(select x from unnest(s.refs) x where not (coalesce(r.refs, '{}'::jsonb) ? x)) end,
         coalesce(sub.active, 0), coalesce(sub.paused, 0), coalesce(dev.n, 0),
         cma.flash_segment_of(k.segment, s.segments, s.segments_lower), coalesce(sub.holding, 0)
  from cma.commerce_customer cu
  cross join s
  left join st on st.connection_id = cu.connection_id
  left join cma.crm_contact k
    on k.tenant_id = cu.tenant_id and k.connection_id = cu.crm_connection_id and k.source_id = cu.crm_contact_source_id
   and k.source_deleted_at is null
  left join refs r on r.contact_id = k.id
  left join sub on sub.store_connection_id = cu.connection_id and sub.customer_source_id = cu.source_id
  left join dev on dev.customer_ref = cu.source_id and dev.market = st.market
  where cu.tenant_id = p_tenant_id and cu.source_deleted_at is null
$$;

-- 0008zt's base set of the customers, its columns as they were: cma.flash_customer_figures_of's rows
create or replace function cma.flash_store_customers_of(p_tenant_id uuid)
returns table (customer_id uuid, connection_id uuid, source_id text, store text, market text, lifetime_orders integer, total_spent numeric,
               currency text, crm_connection_id uuid, contact_source_id text, contact_held boolean, refs jsonb, missing_refs text[],
               active_subscriptions integer, paused_subscriptions integer, devices integer, segment text)
language sql stable
as $$
  select x.customer_id, x.connection_id, x.source_id, x.store, x.market, x.lifetime_orders, x.total_spent, x.currency, x.crm_connection_id,
         x.contact_source_id, x.contact_held, x.refs, x.missing_refs, x.active_subscriptions, x.paused_subscriptions, x.devices, x.segment
  from cma.flash_customer_figures_of(p_tenant_id) x
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. The figures: one computation, live and in the snapshot
-- ---------------------------------------------------------------------------------------------
-- As 0008zt (136), with the customers on the device-holding statuses (active_customers: a subscription in a holding
-- status; paused_customers: a paused subscription and none holding; the segment rows count active_customers) and the
-- subscriptions' split rows ([market, status]: every holding status per market with a holding subscription, zeros
-- included, carrying holding_subscriptions). The snapshot stores exactly these rows (one code path)
create or replace function cma.flash_compute_of(p_tenant_id uuid, p_overview text, p_from date default null, p_to date default null,
                                                p_on date default null)
returns table (dims jsonb, measures jsonb)
language plpgsql stable
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
  perform cma.assert_flash_overview(p_overview);
  if v_src is not null and not coalesce((cma.flash_sources_of(p_tenant_id) -> v_src ->> 'set_up')::boolean, false) then
    return;
  end if;
  if p_overview = 'customers' then
    return query
      select case when grouping(b.market) = 1 then '{}'::jsonb
                  when grouping(b.store) = 0 then jsonb_build_object('market', b.market, 'store', b.store)
                  when grouping(b.segment) = 0 then jsonb_build_object('market', b.market, 'segment', b.segment)
                  else jsonb_build_object('market', b.market) end,
             jsonb_build_object('customers_held', count(*),
                                -- a customer with a subscription in a device-holding status (0008zu: a failed one counts),
                                -- paused when its subscriptions are paused and none holds devices
                                'active_customers', count(*) filter (where b.holding_subscriptions > 0),
                                'paused_customers', count(*) filter (where b.holding_subscriptions = 0 and b.paused_subscriptions > 0),
                                'linked_to_contact', count(*) filter (where b.contact_source_id is not null))
             || case when v_refs_required
                     then jsonb_build_object('with_required_refs', count(*) filter (where b.contact_source_id is not null and b.contact_held
                                                                                     and cardinality(b.missing_refs) = 0))
                     else '{}'::jsonb end
      from cma.flash_customer_figures_of(p_tenant_id) b
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
      full join bands n on n.market = l.market and n.dim = l.dim and n.band = l.band
      union all
      -- Total subscriptions' split (0008zu): the device-holding subscriptions per market and status, every status of
      -- flash.device_holding_statuses for each market with a holding subscription (zeros included), so they add up to the
      -- market's holding_subscriptions
      select jsonb_build_object('market', m.market, 'status', h.status), jsonb_build_object('holding_subscriptions', coalesce(n.n, 0))
      from (select distinct b.market from b where b.is_holding) m
      cross join unnest(v_holding) h(status)
      left join (select b.market, b.status, count(*) as n from b where b.is_holding group by 1, 2) n on n.market = m.market and n.status = h.status;
    if not found then
      return query select '{}'::jsonb, jsonb_build_object('subscriptions', 0, 'active_subscriptions', 0, 'paused_subscriptions', 0,
                                                          'amount_per_cycle', '{}'::jsonb, 'holding_subscriptions', 0, 'devices_on_holding', 0);
    end if;
  elsif p_overview = 'installed_base' then
    return query
      select case when grouping(b.market) = 1 then '{}'::jsonb
                  when grouping(b.status) = 0
                  then jsonb_build_object('market', b.market, 'status', b.status, 'model', b.model, 'warehouse', b.warehouse, 'link', b.link)
                  when grouping(b.subscription_status) = 0 then jsonb_build_object('market', b.market, 'subscription_status', b.subscription_status)
                  else jsonb_build_object('market', b.market) end,
             jsonb_build_object('devices', count(*), 'in_field', count(*) filter (where b.is_in_field),
                                'in_stock', count(*) filter (where b.is_in_stock), 'components_past_due', coalesce(sum(b.past_due_items), 0),
                                'items_due_3m', coalesce(sum(b.items_due_3m), 0),
                                -- devices in the field on a device-holding subscription (0008zt): never one in stock, whatever its reference
                                'in_field_on_holding', count(*) filter (where b.is_in_field and b.subscription_status = any (v_holding)))
      from cma.flash_devices_of(p_tenant_id, v_on) b
      group by grouping sets ((), (b.market), (b.market, b.status, b.model, b.warehouse, b.link), (b.market, b.subscription_status));
  elsif p_overview = 'churn' then
    return query
      select case when grouping(b.market) = 1 then '{}'::jsonb
                  when grouping(b.store) = 1 then jsonb_build_object('market', b.market)
                  else jsonb_build_object('market', b.market, 'store', b.store, 'reason', b.reason) end,
             jsonb_build_object('churned', count(*))
      from cma.flash_churn_of(p_tenant_id, v_from, v_to) b
      group by grouping sets ((), (b.market), (b.market, b.store, b.reason));
  elsif p_overview = 'orders' then
    return query
      -- orders and amounts from the orders (their lines not read), units from the lines, read once for the units and the
      -- SKU rows alike: an order's units are the sum of its lines' quantities, so the sums per set are the same
      with ol as materialized (
        select l.order_id, l.store, l.market, l.kind, l.sku, l.units from cma.flash_order_lines_of(p_tenant_id, v_from, v_to) l
      ), a as (
        select case when grouping(b.market) = 1 then '{}'::jsonb
                    when grouping(b.store) = 1 then jsonb_build_object('market', b.market)
                    else jsonb_build_object('market', b.market, 'store', b.store, 'kind', b.kind) end as dims,
               b.currency, count(*) as n, sum(b.total) as amount
        from cma.flash_orders_of(p_tenant_id, v_from, v_to) b
        group by grouping sets ((b.currency), (b.market, b.currency), (b.market, b.store, b.kind, b.currency))
      ), u as materialized (
        select case when grouping(l.market) = 1 then '{}'::jsonb
                    when grouping(l.store) = 1 then jsonb_build_object('market', l.market)
                    else jsonb_build_object('market', l.market, 'store', l.store, 'kind', l.kind) end as dims,
               sum(l.units) as units
        from ol l
        group by grouping sets ((), (l.market), (l.market, l.store, l.kind))
      )
      select a.dims, jsonb_build_object('orders', sum(a.n), 'units', coalesce((select u.units from u where u.dims = a.dims), 0),
                                        'amount', coalesce(jsonb_object_agg(a.currency, round(a.amount, 2))
                                                             filter (where a.currency is not null and a.amount is not null), '{}'::jsonb))
      from a group by a.dims
      union all
      select jsonb_build_object('market', l.market, 'sku', l.sku), jsonb_build_object('orders', count(distinct l.order_id), 'units', sum(l.units))
      from ol l
      group by l.market, l.sku;
    if not found then
      return query select '{}'::jsonb, jsonb_build_object('orders', 0, 'units', 0, 'amount', '{}'::jsonb);
    end if;
  elsif p_overview = 'payments' then
    return query
      with a as (
        select case when grouping(b.market) = 1 then '{}'::jsonb
                    when grouping(b.store) = 1 then jsonb_build_object('market', b.market)
                    else jsonb_build_object('market', b.market, 'store', b.store, 'kind', b.kind, 'status', b.status) end as dims,
               b.currency, count(*) filter (where b.kind = 'order') as orders, sum(b.amount) filter (where b.kind = 'order') as amount,
               count(*) filter (where b.kind = 'renewal' and b.status = 'renewed') as renewals,
               count(*) filter (where b.kind = 'renewal' and b.status = 'renew_failed') as failed
        from cma.flash_payments_of(p_tenant_id, v_from, v_to) b
        group by grouping sets ((b.currency), (b.market, b.currency), (b.market, b.store, b.kind, b.status, b.currency))
      )
      select a.dims, jsonb_build_object('orders', sum(a.orders), 'renewals', sum(a.renewals), 'failed_renewals', sum(a.failed),
                                        'amount', coalesce(jsonb_object_agg(a.currency, round(a.amount, 2))
                                                             filter (where a.currency is not null and a.amount is not null), '{}'::jsonb))
      from a group by a.dims;
    if not found then
      return query select '{}'::jsonb, jsonb_build_object('orders', 0, 'renewals', 0, 'failed_renewals', 0, 'amount', '{}'::jsonb);
    end if;
  elsif p_overview = 'open_deals' then
    return query
      select case when grouping(b.market) = 1 then '{}'::jsonb
                  when grouping(b.pipeline) = 1 then jsonb_build_object('market', b.market)
                  else jsonb_build_object('market', b.market, 'pipeline', b.pipeline, 'stage', b.stage) end,
             jsonb_strip_nulls(jsonb_build_object('open_deals', count(*),
                                'median_age_days', round((percentile_cont(0.5) within group (order by b.age_days))::numeric, 1),
                                'oldest_age_days', max(b.age_days)))
      from cma.flash_deals_of(p_tenant_id, v_at) b
      group by grouping sets ((), (b.market), (b.market, b.pipeline, b.stage));
  elsif p_overview = 'open_tickets' then
    return query
      select case when grouping(b.market) = 1 then '{}'::jsonb
                  when grouping(b.queue) = 1 then jsonb_build_object('market', b.market)
                  else jsonb_build_object('market', b.market, 'queue', b.queue, 'stage', b.stage) end,
             jsonb_strip_nulls(jsonb_build_object('open_tickets', count(*),
                                'median_age_days', round((percentile_cont(0.5) within group (order by b.age_days))::numeric, 1),
                                'oldest_age_days', max(b.age_days)))
      from cma.flash_tickets_of(p_tenant_id, v_at) b
      group by grouping sets ((), (b.market), (b.market, b.queue, b.stage));
  elsif p_overview = 'open_tasks' then
    return query
      select case when grouping(b.market) = 1 then '{}'::jsonb
                  when grouping(b.type) = 1 then jsonb_build_object('market', b.market)
                  else jsonb_build_object('market', b.market, 'type', b.type, 'status', b.status) end,
             jsonb_build_object('open_tasks', count(*), 'overdue', count(*) filter (where b.overdue))
      from cma.flash_tasks_of(p_tenant_id, v_on) b
      group by grouping sets ((), (b.market), (b.market, b.type, b.status));
  elsif p_overview = 'reviews' then
    return query
      select case when grouping(b.market) = 1 then '{}'::jsonb
                  when grouping(b.stars) = 1 then jsonb_build_object('market', b.market)
                  else jsonb_build_object('market', b.market, 'rating', b.stars::text) end,
             jsonb_build_object('reviews', count(*), 'rating_sum', coalesce(sum(b.rating), 0), 'negative', count(*) filter (where b.is_negative))
      from cma.flash_reviews_of(p_tenant_id, v_from, v_to) b
      group by grouping sets ((), (b.market), (b.market, b.stars));
  elsif p_overview = 'data_quality' then
    -- counted per check and market first (a few rows), then the grouping sets over those counts
    return query
      select case when grouping(b.check_key) = 1 and grouping(b.market) = 1 then '{}'::jsonb
                  when grouping(b.check_key) = 1 then jsonb_build_object('market', b.market)
                  when grouping(b.market) = 1 then jsonb_build_object('check', b.check_key)
                  else jsonb_build_object('check', b.check_key, 'market', b.market) end,
             jsonb_build_object('findings', coalesce(sum(b.n), 0))
      from (select f.check_key, f.market, count(*) as n from cma.flash_findings_of(p_tenant_id) f group by 1, 2) b
      group by grouping sets ((), (b.market), (b.check_key), (b.check_key, b.market));
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. The lists
-- ---------------------------------------------------------------------------------------------
-- As 0008zt (136), with a customer's list on the device-holding statuses (active_customers: holding_subscriptions above
-- 0; paused_customers: none holding and one paused), each customer with its holding_subscriptions. A split cell's list
-- (market, status, measure holding_subscriptions) is the subscriptions' filters as they were
create or replace function cma.flash_rows_of(p_tenant_id uuid, p_overview text, p_filters jsonb, p_sort text, p_descending boolean,
                                             p_limit integer, p_offset integer, p_from date, p_to date)
returns jsonb
language plpgsql stable
as $$
declare
  v_order text := cma.flash_order_by(p_overview, p_sort, p_descending);
  v_today date := cma.tenant_today_of(p_tenant_id);
  v_from  date := coalesce(p_from, v_today);
  v_to    date := coalesce(p_to, p_from, v_today);
  v_src   text := (select o.source from cma.flash_overviews() o where o.key = p_overview);
  v_base  text;
  v_where text;
  v_obj   text;
  v_res   jsonb;
begin
  if v_order is null then
    raise exception 'sort % is not a sort key of %', p_sort, p_overview using errcode = 'CMA04';
  end if;
  if v_src is not null and not coalesce((cma.flash_sources_of(p_tenant_id) -> v_src ->> 'set_up')::boolean, false) then
    return jsonb_build_object('total', 0, 'rows', '[]'::jsonb);
  end if;
  case p_overview
    when 'customers' then
      v_base := 'cma.flash_customer_figures_of($2)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''store'' is null or x.store = $1 ->> ''store'')
                  and ($1 ->> ''segment'' is null or x.segment = $1 ->> ''segment'')
                  and case $1 ->> ''measure'' when ''active_customers'' then x.holding_subscriptions > 0
                                              when ''paused_customers'' then x.holding_subscriptions = 0 and x.paused_subscriptions > 0
                                              when ''linked_to_contact'' then x.contact_source_id is not null
                                              when ''with_required_refs'' then x.contact_source_id is not null and x.contact_held and cardinality(x.missing_refs) = 0
                                              else true end';
      v_obj := 'jsonb_build_object(''customer_id'', x.source_id, ''connection_id'', x.connection_id, ''store'', x.store, ''market'', x.market,
                  ''contact_id'', x.contact_source_id, ''contact_url'', cma.record_url(x.crm_connection_id, ''contact'', x.contact_source_id),
                  ''contact_held'', x.contact_held, ''refs'', x.refs, ''missing_refs'', to_jsonb(x.missing_refs),
                  ''lifetime_orders'', x.lifetime_orders, ''total_spent'', x.total_spent, ''currency'', x.currency,
                  ''active_subscriptions'', x.active_subscriptions, ''paused_subscriptions'', x.paused_subscriptions, ''devices'', x.devices,
                  ''holding_subscriptions'', x.holding_subscriptions,
                  ''order_ids'', (select coalesce(jsonb_agg(q.n order by q.at desc, q.n), ''[]''::jsonb)
                                 from (select coalesce(o.order_name, o.source_id) as n, o.source_created_at as at from cma.commerce_order o
                                       where o.tenant_id = $2 and o.connection_id = x.connection_id and o.customer_source_id = x.source_id
                                         and o.source_deleted_at is null order by o.source_created_at desc, o.source_id limit 20) q),
                  ''orders_held'', (select count(*) from cma.commerce_order o where o.tenant_id = $2 and o.connection_id = x.connection_id
                                     and o.customer_source_id = x.source_id and o.source_deleted_at is null),
                  ''subscription_ids'', (select coalesce(jsonb_agg(q.source_id order by q.source_id), ''[]''::jsonb)
                                        from (select sb.source_id from cma.subscription sb join sm on sm.connection_id = sb.connection_id
                                              where sb.tenant_id = $2 and sm.store_connection_id = x.connection_id and sb.customer_source_id = x.source_id
                                                and sb.source_deleted_at is null order by sb.source_id limit 20) q))';
    when 'subscriptions' then
      -- measured against the tenant's today (the age bands); devices_on_holding's records are the device-holding
      -- subscriptions with a device in the field, each with its devices_in_field (they add up to the figure)
      v_base := 'cma.flash_subscriptions_of($2, $7)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''store'' is null or x.store = $1 ->> ''store'')
                  and ($1 ->> ''status'' is null or x.status = $1 ->> ''status'') and ($1 ->> ''payment_state'' is null or x.payment_state = $1 ->> ''payment_state'')
                  and ($1 ->> ''device_band'' is null or x.device_band = $1 ->> ''device_band'')
                  and ($1 ->> ''age_band'' is null or x.age_band = $1 ->> ''age_band'')
                  and case $1 ->> ''measure'' when ''active_subscriptions'' then x.is_active when ''paused_subscriptions'' then x.status = ''paused''
                                              when ''holding_subscriptions'' then x.is_holding
                                              when ''devices_on_holding'' then x.is_holding and x.devices_in_field > 0 else true end';
      v_obj := 'jsonb_build_object(''subscription_id'', x.source_id, ''connection_id'', x.connection_id, ''store'', x.store, ''market'', x.market,
                  ''customer_id'', x.customer_source_id, ''contact_id'', x.contact_source_id,
                  ''contact_url'', cma.record_url(x.crm_connection_id, ''contact'', x.contact_source_id), ''status'', x.status,
                  ''payment_state'', x.payment_state, ''amount_per_cycle'', x.amount_per_cycle, ''currency'', x.currency,
                  ''billing_interval'', x.billing_interval, ''billing_interval_count'', x.billing_interval_count, ''next_billing_at'', x.next_billing_at,
                  ''retry_since'', x.retry_since, ''last_attempt'', x.last_attempt, ''devices'', x.devices, ''devices_in_field'', x.devices_in_field)';
    when 'installed_base' then
      -- the linked subscription's payment state for the list (0008zl's derivation, once per read): the figures need none
      v_base := '(select d.*, ps.payment_state as subscription_payment_state
                  from cma.flash_devices_of($2, $7) d
                  left join cma.subscription_payment_state_of($2) ps on ps.subscription_id = d.subscription_id)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''status'' is null or x.status = $1 ->> ''status'')
                  and ($1 ->> ''model'' is null or x.model = $1 ->> ''model'') and ($1 ->> ''warehouse'' is null or x.warehouse = $1 ->> ''warehouse'')
                  and ($1 ->> ''link'' is null or x.link = $1 ->> ''link'')
                  and ($1 ->> ''subscription_status'' is null or x.subscription_status = $1 ->> ''subscription_status'')
                  and case $1 ->> ''measure'' when ''in_field'' then x.is_in_field when ''in_stock'' then x.is_in_stock
                                              when ''in_field_on_holding'' then x.is_in_field and x.subscription_status = any ($8)
                                              when ''components_past_due'' then x.past_due_items > 0 when ''items_due_3m'' then x.items_due_3m > 0
                                              else true end';
      v_obj := 'jsonb_build_object(''serial'', x.serial, ''device_id'', x.source_id, ''connection_id'', x.connection_id, ''model'', x.model,
                  ''market'', x.market, ''status'', x.status, ''in_field'', x.is_in_field, ''in_stock'', x.is_in_stock, ''warehouse'', x.warehouse,
                  ''refs'', x.refs, ''missing_refs'', to_jsonb(x.missing_refs), ''customer_id'', x.customer_ref, ''subscription_id'', x.subscription_ref,
                  ''link'', x.link, ''subscription_status'', x.subscription_status, ''subscription_payment_state'', x.subscription_payment_state,
                  ''past_due_items'', x.past_due_items, ''items_due_3m'', x.items_due_3m, ''next_due_on'', x.next_due_on,
                  ''record_url'', cma.record_url(x.connection_id, ''device'', x.source_id))';
    when 'churn' then
      v_base := 'cma.flash_churn_of($2, $5, $6)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''store'' is null or x.store = $1 ->> ''store'')
                  and ($1 ->> ''reason'' is null or x.reason = $1 ->> ''reason'')';
      v_obj := 'jsonb_build_object(''subscription_id'', x.source_id, ''connection_id'', x.connection_id, ''store'', x.store, ''market'', x.market,
                  ''customer_id'', x.customer_source_id, ''churned_at'', x.churned_at, ''business_date'', x.business_date, ''reason'', x.reason,
                  ''cycles'', x.cycles)';
    when 'orders' then
      v_base := 'cma.flash_orders_of($2, $5, $6)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''store'' is null or x.store = $1 ->> ''store'')
                  and ($1 ->> ''kind'' is null or x.kind = $1 ->> ''kind'') and ($1 ->> ''sku'' is null or ($1 ->> ''sku'') = any (x.skus))';
      v_obj := 'jsonb_build_object(''order_number'', x.order_number, ''order_id'', x.source_id, ''connection_id'', x.connection_id, ''store'', x.store,
                  ''market'', x.market, ''created_at'', x.created_at, ''business_date'', x.business_date, ''kind'', x.kind,
                  ''financial_status'', x.financial_status, ''fulfillment_status'', x.fulfillment_status, ''skus'', to_jsonb(x.skus),
                  ''units'', x.units, ''total'', x.total, ''currency'', x.currency, ''customer_id'', x.customer_source_id)';
    when 'payments' then
      v_base := 'cma.flash_payments_of($2, $5, $6)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''store'' is null or x.store = $1 ->> ''store'')
                  and ($1 ->> ''kind'' is null or x.kind = $1 ->> ''kind'') and ($1 ->> ''status'' is null or x.status = $1 ->> ''status'')
                  and case $1 ->> ''measure'' when ''orders'' then x.kind = ''order''
                                              when ''renewals'' then x.kind = ''renewal'' and x.status = ''renewed''
                                              when ''failed_renewals'' then x.kind = ''renewal'' and x.status = ''renew_failed'' else true end';
      v_obj := 'jsonb_build_object(''kind'', x.kind, ''status'', x.status, ''record_ref'', x.record_ref, ''cycle'', x.cycle, ''source_id'', x.source_id,
                  ''connection_id'', x.connection_id, ''store'', x.store, ''market'', x.market, ''at'', x.at, ''business_date'', x.business_date,
                  ''amount'', x.amount, ''currency'', x.currency)';
    when 'open_deals' then
      v_base := 'cma.flash_deals_of($2)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''pipeline'' is null or x.pipeline = $1 ->> ''pipeline'')
                  and ($1 ->> ''stage'' is null or x.stage = $1 ->> ''stage'')';
      v_obj := 'jsonb_build_object(''record_id'', x.source_id, ''record_url'', cma.record_url(x.connection_id, ''deal'', x.source_id),
                  ''connection_id'', x.connection_id, ''pipeline'', x.pipeline, ''stage'', x.stage, ''market'', x.market, ''owner_ref'', x.owner_ref,
                  ''owner_linked'', x.owner_user_id is not null, ''created_at'', x.created_at, ''age_days'', x.age_days)';
    when 'open_tickets' then
      v_base := 'cma.flash_tickets_of($2)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''queue'' is null or x.queue = $1 ->> ''queue'')
                  and ($1 ->> ''stage'' is null or x.stage = $1 ->> ''stage'')';
      v_obj := 'jsonb_build_object(''record_id'', x.source_id, ''record_url'', cma.record_url(x.connection_id, ''ticket'', x.source_id),
                  ''connection_id'', x.connection_id, ''queue'', x.queue, ''stage'', x.stage, ''market'', x.market, ''owner_ref'', x.owner_ref,
                  ''owner_linked'', x.owner_user_id is not null, ''created_at'', x.created_at, ''age_days'', x.age_days)';
    when 'open_tasks' then
      v_base := 'cma.flash_tasks_of($2)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''type'' is null or x.type = $1 ->> ''type'')
                  and ($1 ->> ''status'' is null or x.status = $1 ->> ''status'')
                  and case $1 ->> ''measure'' when ''overdue'' then x.overdue else true end';
      v_obj := 'jsonb_build_object(''task_id'', x.source_id, ''task_url'', cma.record_url(x.connection_id, ''task'', x.source_id),
                  ''connection_id'', x.connection_id, ''type'', x.type, ''status'', x.status, ''market'', x.market, ''owner_ref'', x.owner_ref,
                  ''owner_linked'', x.owner_user_id is not null, ''due_at'', x.due_at, ''overdue'', x.overdue, ''record_type'', x.record_type,
                  ''record_id'', x.record_source_id,
                  ''record_url'', case when x.record_type is not null then cma.record_url(x.connection_id, x.record_type, x.record_source_id) end)';
    when 'reviews' then
      v_base := 'cma.flash_reviews_of($2, $5, $6)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''rating'' is null or x.stars::text = $1 ->> ''rating'')
                  and case $1 ->> ''measure'' when ''negative'' then x.is_negative else true end';
      v_obj := 'jsonb_build_object(''review_id'', x.source_id, ''review_url'', cma.record_url(x.connection_id, ''review'', x.source_id),
                  ''connection_id'', x.connection_id, ''channel'', x.channel, ''market'', x.market, ''rating'', x.rating, ''stars'', x.stars,
                  ''negative'', x.is_negative, ''submitted_at'', x.submitted_at, ''business_date'', x.business_date, ''link_level'', x.link_level)';
    when 'data_quality' then
      v_base := 'cma.flash_findings_of($2)';
      v_where := '($1 ->> ''market'' is null or x.market = $1 ->> ''market'') and ($1 ->> ''check'' is null or x.check_key = $1 ->> ''check'')';
      v_obj := 'jsonb_build_object(''check'', x.check_key, ''object_type'', x.object_type, ''object_id'', x.object_id, ''connection_id'', x.connection_id,
                  ''value'', x.value, ''market'', x.market, ''fix_in'', x.fix_in, ''fix_adapter'', x.fix_adapter)
                  || cma.flash_finding_links_of($2, x.connection_id, x.object_type, x.object_id)';
  end case;
  execute format(
    'with sm as materialized (select * from cma.flash_subscription_stores_of($2)),
          f as materialized (select x.* from %s x where %s),
          p as materialized (select x.* from f x order by %s limit $3 offset $4),
          n as (select x.*, row_number() over (order by %s) as ord from p x)
     select jsonb_build_object(''total'', (select count(*) from f),
                               ''rows'', coalesce((select jsonb_agg(%s order by x.ord) from n x), ''[]''::jsonb))',
    v_base, v_where, v_order, v_order, v_obj)
    into v_res
    using p_filters, p_tenant_id, p_limit, p_offset, v_from, v_to, v_today, cma.flash_holding_statuses_of(p_tenant_id);
  return v_res;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. The cards: the split and the definition versions
-- ---------------------------------------------------------------------------------------------
-- As 0008zn (122), with the headline's split (Total subscriptions per device-holding status: [{key, value}] in the
-- setting's order, zeros included; none for another overview) and the definition the figure follows. One overview's
-- live headline (reports.view or performance.team): the totals' (or the market's) headline figure of
-- cma.flash_compute_of, now or over a period for a flow; null when its source is not set up
create or replace function cma.flash_headline(p_overview text, p_market text default null, p_from date default null, p_to date default null)
returns jsonb
language plpgsql stable
set jit = off
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_today  date;
  o        record;
  v_rows   jsonb;
  -- the dim of the headline's split (Total subscriptions per device-holding status, 0008zu), none for another overview
  v_split  text := cma.flash_split_dim_of(p_overview);
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.assert_flash_overview(p_overview);
  v_today := cma.tenant_today_of(v_tenant);
  perform cma.assert_flash_params(p_market, null, p_from, p_to, v_today);
  select * into o from cma.flash_overviews() x where x.key = p_overview;
  select jsonb_agg(jsonb_build_object('dims', c.dims, 'measures', c.measures)) into v_rows
  from cma.flash_compute_of(v_tenant, p_overview, case when o.kind = 'flow' then coalesce(p_from, v_today) end,
                            case when o.kind = 'flow' then coalesce(p_to, v_today) end) c
  where c.dims = '{}'::jsonb or c.dims = jsonb_build_object('market', p_market)
     or (v_split is not null and c.dims ? v_split and (select count(*) from jsonb_object_keys(c.dims)) = 2
         and (p_market is null or c.dims ->> 'market' = p_market));
  return jsonb_build_object('overview', p_overview, 'headline', o.headline, 'market', p_market, 'as_of', now(),
    'from', case when o.kind = 'flow' then coalesce(p_from, v_today) end, 'to', case when o.kind = 'flow' then coalesce(p_to, v_today) end,
    'set_up', v_rows is not null,
    'value', coalesce(cma.flash_pick_of(v_rows, p_market, o.headline),
                      case when cma.flash_pick_of(v_rows, null, o.headline) is not null then '0'::jsonb end),
    'split', case when v_split is not null and v_rows is not null
                  then cma.flash_split_of(v_rows, p_market, v_split, o.headline, cma.flash_holding_statuses_of(v_tenant)) end,
    'definition_version', cma.flash_definition_version(p_overview));
end
$$;

-- As 0008zt (136), with each card's definition (live: today's; As of a date: the version its stored figure was computed
-- by), the version the figure it is compared with was computed by (previous_definition_version: none without one), so
-- the page marks a change of definition where it compares across one, and As of a date the stored split (none for a
-- snapshot taken before 0008zu). Live, a card's split is its own read's (cma.flash_headline)
create or replace function cma.flash_page(p_market text default null, p_as_of date default null, p_from date default null, p_to date default null)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant   uuid := cma.current_tenant_id();
  v_today    date;
  v_from     date;
  v_to       date;
  v_len      integer;
  v_sources  jsonb;
  v_cards    jsonb := '[]'::jsonb;
  o          record;
  v_value    jsonb;
  v_prev     jsonb;
  v_prev_on  date;
  v_dates    date[];
  v_set_up   boolean;
  v_split    jsonb;
  v_version  text;
  v_prev_ver text;
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  v_today := cma.tenant_today_of(v_tenant);
  perform cma.assert_flash_params(p_market, p_as_of, p_from, p_to, v_today);
  v_from := coalesce(p_from, p_as_of, v_today);
  v_to := coalesce(p_to, p_as_of, v_today);
  v_len := v_to - v_from + 1;
  if p_as_of is null then
    v_sources := cma.flash_sources_of(v_tenant);
  else
    select r.sources into v_sources from cma.flash_snapshot_run r
    where r.tenant_id = v_tenant and r.snapshot_date = p_as_of and r.status = 'succeeded';
    if v_sources is null then
      return jsonb_build_object('mode', 'snapshot', 'as_of', p_as_of, 'market', p_market, 'snapshot_missing', true,
        'nearest_before', (select max(r.snapshot_date) from cma.flash_snapshot_run r
                           where r.tenant_id = v_tenant and r.status = 'succeeded' and r.snapshot_date < p_as_of),
        'nearest_after', (select min(r.snapshot_date) from cma.flash_snapshot_run r
                          where r.tenant_id = v_tenant and r.status = 'succeeded' and r.snapshot_date > p_as_of),
        'first_snapshot_date', (select min(r.snapshot_date) from cma.flash_snapshot_run r where r.tenant_id = v_tenant and r.status = 'succeeded'),
        'overviews', '[]'::jsonb, 'watch', '[]'::jsonb, 'markets', '[]'::jsonb,
        'today', cma.tenant_today_of(v_tenant), 'time_zone', (select t.timezone from cma.tenant t where t.id = v_tenant),
        'settings', cma.flash_status_settings_of(v_tenant));
    end if;
  end if;
  for o in select * from cma.flash_overviews() x order by x.sort_order loop
    v_set_up := o.source is null or coalesce((v_sources -> o.source ->> 'set_up')::boolean, false);
    v_value := null; v_prev := null; v_prev_on := null; v_split := null; v_version := null; v_prev_ver := null;
    if v_set_up then
      if p_as_of is not null then
        select array_agg(r.snapshot_date) into v_dates from cma.flash_snapshot_run r
        where r.tenant_id = v_tenant and r.status = 'succeeded'
          and r.snapshot_date between case when o.kind = 'flow' then v_from else p_as_of end and case when o.kind = 'flow' then v_to else p_as_of end;
        v_value := cma.flash_stored_headline_of(v_tenant, o.key, p_market, v_dates);
        -- the definition the stored figure was computed by, and its split where it has one (0008zu)
        v_version := cma.flash_stored_version_of(v_tenant, o.key, v_dates);
        if cma.flash_split_dim_of(o.key) is not null then
          v_split := cma.flash_stored_split_of(v_tenant, o.key, p_market, v_dates);
        end if;
      end if;
      if o.kind = 'stock' then
        select max(r.snapshot_date) into v_prev_on from cma.flash_snapshot_run r
        where r.tenant_id = v_tenant and r.status = 'succeeded' and r.snapshot_date < coalesce(p_as_of, v_today);
        if v_prev_on is not null then
          v_prev := cma.flash_stored_headline_of(v_tenant, o.key, p_market, array[v_prev_on]);
          v_prev_ver := cma.flash_stored_version_of(v_tenant, o.key, array[v_prev_on]);
        end if;
      else
        select array_agg(r.snapshot_date) into v_dates from cma.flash_snapshot_run r
        where r.tenant_id = v_tenant and r.status = 'succeeded' and r.snapshot_date between v_from - v_len and v_from - 1;
        if coalesce(cardinality(v_dates), 0) = v_len then
          v_prev_on := v_from - 1;
          v_prev := cma.flash_stored_headline_of(v_tenant, o.key, p_market, v_dates);
          v_prev_ver := cma.flash_stored_version_of(v_tenant, o.key, v_dates);
        end if;
      end if;
    end if;
    v_cards := v_cards || jsonb_build_array(jsonb_build_object(
      'key', o.key, 'kind', o.kind, 'source', o.source, 'set_up', v_set_up, 'headline', o.headline, 'value', v_value,
      'previous', v_prev, 'previous_on', v_prev_on,
      -- the definition the figure follows (live: today's; as of a date: the snapshot's) and the one the figure it is
      -- compared with followed, so the page marks a change of definition between the two (0008zu)
      'definition_version', coalesce(v_version, cma.flash_definition_version(o.key)), 'previous_definition_version', v_prev_ver,
      'split', v_split));
  end loop;
  return jsonb_build_object(
    'mode', case when p_as_of is null then 'live' else 'snapshot' end,
    'as_of', case when p_as_of is null then to_jsonb(now()) else to_jsonb(p_as_of) end,
    'from', v_from, 'to', v_to, 'market', p_market, 'snapshot_missing', false,
    'sources', v_sources, 'overviews', v_cards,
    'markets', (select coalesce(jsonb_agg(jsonb_build_object('code', m.code, 'name', m.name) order by m.sort_order, m.code), '[]'::jsonb)
                from cma.market m where m.tenant_id = v_tenant and m.status = 'active'),
    'watch', (select coalesce(jsonb_agg(jsonb_build_object('kind', f.kind, 'overview', f.overview, 'dims', f.dims, 'measure', f.measure,
                                                           'value', f.value, 'previous', f.previous, 'threshold', f.threshold, 'detail', f.detail,
                                                           'snapshot_date', f.snapshot_date)
                                        order by f.snapshot_date desc, f.kind, f.overview, f.dims::text), '[]'::jsonb)
              from cma.flash_watch_finding f where f.tenant_id = v_tenant and f.state = 'open'),
    'first_snapshot_date', (select min(r.snapshot_date) from cma.flash_snapshot_run r where r.tenant_id = v_tenant and r.status = 'succeeded'),
    'last_snapshot_date', (select max(r.snapshot_date) from cma.flash_snapshot_run r where r.tenant_id = v_tenant and r.status = 'succeeded'),
    'today', cma.tenant_today_of(v_tenant), 'time_zone', (select t.timezone from cma.tenant t where t.id = v_tenant),
    'settings', cma.flash_status_settings_of(v_tenant));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. The take: a month end's customer list and the watch
-- ---------------------------------------------------------------------------------------------
-- As 0008zn (122), with a month end's customer list the active customers as Flash now counts them (a subscription in a
-- device-holding status); the subscriptions' list stays the active (paying) ones and the devices' every device
create or replace function cma.flash_snapshot_ids_write_of(p_tenant_id uuid, p_date date, p_run_id uuid)
returns jsonb
language plpgsql
as $$
declare
  v_c  integer;
  v_s  integer;
  v_d  integer;
  v_nc integer;
  v_ns integer;
  v_nd integer;
begin
  perform cma.assert_permission('flash.snapshot');
  if p_tenant_id is null or p_tenant_id is distinct from cma.current_tenant_id() or p_date is null or p_run_id is null then
    raise exception 'a month end''s id lists are written for the current tenant only' using errcode = 'CMA06';
  end if;
  with src as materialized (
    -- the active customers as Flash counts them (0008zu: a subscription in a device-holding status)
    select c.source_id, c.connection_id, c.market from cma.flash_customer_figures_of(p_tenant_id) c where c.holding_subscriptions > 0
  ), ins as (
    insert into cma.flash_snapshot_ids (tenant_id, snapshot_date, record_kind, source_id, connection_id, market, state, run_id)
    select p_tenant_id, p_date, 'customer', src.source_id, src.connection_id, src.market, 'active', p_run_id
    from src where cma.flash_id_ok(src.source_id, src.market, 'active')
    returning 1
  )
  select (select count(*) from ins), (select count(*) from src) into v_c, v_nc;
  with src as materialized (
    select s.source_id, s.connection_id, s.market, s.status from cma.flash_subscriptions_of(p_tenant_id) s where s.is_active
  ), ins as (
    insert into cma.flash_snapshot_ids (tenant_id, snapshot_date, record_kind, source_id, connection_id, market, state, run_id)
    select p_tenant_id, p_date, 'subscription', src.source_id, src.connection_id, src.market, src.status, p_run_id
    from src where cma.flash_id_ok(src.source_id, src.market, src.status)
    returning 1
  )
  select (select count(*) from ins), (select count(*) from src) into v_s, v_ns;
  with src as materialized (
    select d.source_id, d.connection_id, d.market, d.status from cma.flash_devices_of(p_tenant_id, p_date) d
  ), ins as (
    insert into cma.flash_snapshot_ids (tenant_id, snapshot_date, record_kind, source_id, connection_id, market, state, run_id)
    select p_tenant_id, p_date, 'device', src.source_id, src.connection_id, src.market, src.status, p_run_id
    from src where cma.flash_id_ok(src.source_id, src.market, src.status)
    returning 1
  )
  select (select count(*) from ins), (select count(*) from src) into v_d, v_nd;
  insert into cma.audit_log (tenant_id, table_name, action, old_row, new_row, actor_user_id, actor_label)
  select p_tenant_id, 'flash_snapshot_ids', 'insert', null,
         jsonb_build_object('snapshot_date', p_date, 'record_kind', k.kind, 'rows', k.n, 'run_id', p_run_id),
         cma.current_user_id(), cma.current_actor_label()
  from (values ('customer', v_c), ('subscription', v_s), ('device', v_d)) k(kind, n);
  return jsonb_build_object('ids_customer', v_c, 'ids_subscription', v_s, 'ids_device', v_d,
                            'ids_skipped', (v_nc - v_c) + (v_ns - v_s) + (v_nd - v_d));
end
$$;

-- As 0008zo (125), with an overview whose definition changed between the two dates left out of the jump: its totals
-- stored under two versions (the first take after 0008zu: active_customers then counts the device-holding statuses), so
-- a change of what a figure counts is never a finding
--                     thresholds
create or replace function cma.flash_watch_of(p_tenant_id uuid, p_date date, p_now timestamptz)
returns jsonb
language plpgsql
as $$
declare
  v_pct      numeric := cma.setting_of(p_tenant_id, 'flash.watch_jump_pct')::numeric;
  v_min      numeric := cma.setting_of(p_tenant_id, 'flash.watch_jump_min')::numeric;
  v_floor    numeric := cma.setting_of(p_tenant_id, 'flash.watch_stale_min_minutes')::numeric;
  v_prev_ok  boolean;
  v_flow_ok  boolean;
  v_opened   integer;
  v_resolved integer;
begin
  perform cma.assert_permission('flash.snapshot');
  if p_tenant_id is null or p_tenant_id is distinct from cma.current_tenant_id() or p_date is null or p_now is null then
    raise exception 'the watch runs for the current tenant only' using errcode = 'CMA06';
  end if;
  v_prev_ok := exists (select 1 from cma.flash_snapshot_run r where r.tenant_id = p_tenant_id and r.snapshot_date = p_date - 1 and r.status = 'succeeded');
  v_flow_ok := (select count(*) from cma.flash_snapshot_run r
                where r.tenant_id = p_tenant_id and r.status = 'succeeded' and r.snapshot_date between p_date - 7 and p_date - 1) = 7;
  with sm as materialized (
    select * from cma.flash_subscription_stores_of(p_tenant_id)
  ), m as (
    select o.key as overview, unnest(o.count_measures) as measure, o.kind from cma.flash_overviews() o
  ), day_rows as (
    -- the [market] rows of the stock overviews and the [check] rows of data quality, on p_date and the date before
    select s.snapshot_date, s.overview, s.dims, e.key as measure, (e.value #>> '{}')::numeric as v
    from cma.flash_snapshot s
    cross join lateral jsonb_each(s.measures) e
    join m on m.overview = s.overview and m.measure = e.key and m.kind = 'stock'
    where s.tenant_id = p_tenant_id and s.snapshot_date in (p_date, p_date - 1) and jsonb_typeof(e.value) = 'number'
      and ((s.overview <> 'data_quality' and s.dims ? 'market' and (select count(*) from jsonb_object_keys(s.dims)) = 1)
           or (s.overview = 'data_quality' and s.dims ? 'check' and (select count(*) from jsonb_object_keys(s.dims)) = 1))
  ), na as (
    -- a count measure left out of an overview's totals row on either date does not apply that day (with_required_refs
    -- while no contact reference is required): it is not compared, so switching a requirement on or off is no jump
    select distinct s.overview, m.measure
    from cma.flash_snapshot s
    join m on m.overview = s.overview and m.kind = 'stock'
    where s.tenant_id = p_tenant_id and s.snapshot_date in (p_date, p_date - 1) and s.dims = '{}'::jsonb and not (s.measures ? m.measure)
    union
    -- an overview whose definition changed between the two dates (its totals stored under two versions, 0008zu): none of
    -- its measures is compared, so a change of what a figure counts is no jump
    select x.overview, m.measure
    from (select s.overview from cma.flash_snapshot s
          where s.tenant_id = p_tenant_id and s.snapshot_date in (p_date, p_date - 1) and s.dims = '{}'::jsonb
          group by s.overview having count(distinct s.definition_version) > 1) x
    join m on m.overview = x.overview and m.kind = 'stock'
  ), j as (
    select coalesce(t.overview, y.overview) as overview, coalesce(t.dims, y.dims) as dims, coalesce(t.measure, y.measure) as measure,
           coalesce(t.v, 0) as v, coalesce(y.v, 0) as p
    from (select * from day_rows where snapshot_date = p_date) t
    full join (select * from day_rows where snapshot_date = p_date - 1) y on y.overview = t.overview and y.dims = t.dims and y.measure = t.measure
    where not exists (select 1 from na where na.overview = coalesce(t.overview, y.overview) and na.measure = coalesce(t.measure, y.measure))
  ), prev as (
    -- a flow overview's [market] rows above 0 on each of the 7 dates before p_date
    select s.overview, s.dims, e.key as measure
    from cma.flash_snapshot s
    cross join lateral jsonb_each(s.measures) e
    join m on m.overview = s.overview and m.measure = e.key and m.kind = 'flow'
    where s.tenant_id = p_tenant_id and s.snapshot_date between p_date - 7 and p_date - 1
      and s.dims ? 'market' and (select count(*) from jsonb_object_keys(s.dims)) = 1
      and jsonb_typeof(e.value) = 'number' and (e.value #>> '{}')::numeric > 0
    group by 1, 2, 3
    having count(*) = 7
  ), c as (
    select ic.id, ic.adapter, ic.settings,
           case when ic.kind is not null then ic.kind
                when exists (select 1 from cma.commerce_store x where x.tenant_id = ic.tenant_id and x.connection_id = ic.id) then 'commerce'
                else (cma.connection_held_kinds_of(ic.tenant_id, ic.id))[1] end as kind,
           coalesce((select st.handle from cma.commerce_store st where st.tenant_id = ic.tenant_id and st.connection_id = ic.id),
                    (select sm.handle from sm where sm.connection_id = ic.id)) as store
    from cma.integration_connection ic
    where ic.tenant_id = p_tenant_id and ic.status = 'active'
  ), win as (
    -- the succeeded runs of the 7 days before p_now of the active connections of a source Flash reads, backfills aside
    -- (started by hand: no cadence), each with the gap since the run before of the same job and stream in those days
    select x.connection_id, x.job, x.stream, x.finished_at,
           extract(epoch from x.finished_at - lag(x.finished_at) over (partition by x.connection_id, x.job, x.stream order by x.finished_at)) / 60 as gap
    from cma.sync_run x
    where x.tenant_id = p_tenant_id and x.status = 'succeeded' and x.job <> 'backfill'
      and x.finished_at > p_now - interval '7 days' and x.finished_at <= p_now
      and x.connection_id in (select c.id from c where c.kind in ('commerce', 'subscriptions', 'assets', 'crm', 'reviews'))
  ), sets as (
    -- a connection's poll interval settings: <job>_interval_minutes is the cadence of that job (assets_poll_interval_minutes
    -- of assets_poll), the smallest when two name one job
    select c.id as connection_id, left(e.key, length(e.key) - length('_interval_minutes')) as job,
           min((e.value #>> '{}')::numeric) as minutes
    from c
    cross join lateral jsonb_each(c.settings) e
    where c.kind in ('commerce', 'subscriptions', 'assets', 'crm', 'reviews')
      and e.key like '%\_poll\_interval\_minutes'
      and case when (e.value #>> '{}') ~ '^[0-9]{1,5}$' then (e.value #>> '{}')::numeric > 0 else false end
    group by 1, 2
  ), cand as (
    -- every job and stream with a cadence: its setting (its age from its last succeeded run of any time), else the median
    -- gap of its runs of the 7 days (raw), at least flash.watch_stale_min_minutes (cadence)
    select s.connection_id, x.job, x.stream, max(x.finished_at) as last_at, s.minutes as raw, s.minutes as cadence, 'setting'::text as basis
    from sets s
    join cma.sync_run x on x.tenant_id = p_tenant_id and x.connection_id = s.connection_id and x.job = s.job
                       and x.status = 'succeeded' and x.finished_at <= p_now
    group by s.connection_id, x.job, x.stream, s.minutes
    union all
    select w.connection_id, w.job, w.stream, max(w.finished_at),
           (percentile_cont(0.5) within group (order by w.gap) filter (where w.gap > 0))::numeric,
           greatest((percentile_cont(0.5) within group (order by w.gap) filter (where w.gap > 0))::numeric, v_floor), 'runs'
    from win w
    where not exists (select 1 from sets s where s.connection_id = w.connection_id and s.job = w.job)
    group by w.connection_id, w.job, w.stream
    having count(*) filter (where w.gap > 0) > 0
  ), gov as (
    -- a connection's most frequent job and stream: the smallest cadence before the floor (on a tie the latest read, then
    -- the names), so a job measured at 1 minute governs one set at 5 even though the floor makes both 5
    select distinct on (k.connection_id) k.connection_id, k.job, k.stream, k.last_at, k.cadence, k.basis, c.kind, c.adapter, c.store
    from cand k
    join c on c.id = k.connection_id
    order by k.connection_id, k.raw, k.last_at desc, k.job collate "C", k.stream collate "C" nulls first
  ), cur as (
    -- jump and dq_rise
    select case when j.overview = 'data_quality' then 'dq_rise' else 'jump' end as kind, j.overview, j.dims, j.measure, j.v as value,
           j.p as previous, round(greatest(v_min, v_pct * j.p / 100), 2) as threshold, jsonb_build_object('jump_pct', v_pct, 'jump_min', v_min) as detail
    from j
    where v_prev_ok and abs(j.v - j.p) > v_min and abs(j.v - j.p) * 100 > v_pct * j.p
      and (j.overview <> 'data_quality' or j.v > j.p)
    union all
    -- flow_zero
    select 'flow_zero', prev.overview, prev.dims, prev.measure, coalesce((s.measures ->> prev.measure)::numeric, 0), null::numeric, 0::numeric,
           jsonb_build_object('previous_days', 7)
    from prev
    left join cma.flash_snapshot s
      on s.tenant_id = p_tenant_id and s.snapshot_date = p_date and s.overview = prev.overview and s.dims = prev.dims
    where v_flow_ok and coalesce((s.measures ->> prev.measure)::numeric, 0) = 0
    union all
    -- source_stale: per source, adapter and store, the stale connection with the oldest read of its most frequent job and
    -- stream, and how many are stale
    select 'source_stale', null::text, z.dims, null::text, z.value, null::numeric, z.threshold,
           z.detail || jsonb_build_object('connections', z.n)
    from (select distinct on (st.dims) st.dims, st.value, st.threshold, st.detail, count(*) over (partition by st.dims) as n
          from (select jsonb_strip_nulls(jsonb_build_object('source', g.kind, 'adapter', g.adapter, 'store', g.store)) as dims,
                       round(extract(epoch from p_now - g.last_at) / 60) as value, round(3 * g.cadence) as threshold,
                       jsonb_build_object('cadence_minutes', round(g.cadence, 1), 'cadence_basis', g.basis,
                                          'age_minutes', round(extract(epoch from p_now - g.last_at) / 60), 'last_read_at', g.last_at)
                       || jsonb_strip_nulls(jsonb_build_object('job', g.job, 'stream', g.stream)) as detail,
                       g.last_at
                from gov g
                where extract(epoch from p_now - g.last_at) / 60 > 3 * g.cadence) st
          order by st.dims, st.last_at, st.value desc) z
    union all
    -- snapshot_missing
    select 'snapshot_missing', null::text, '{}'::jsonb, null::text, ((p_date - 1) - x.last_before)::numeric, null::numeric, null::numeric,
           jsonb_build_object('missing_from', x.last_before + 1, 'missing_to', p_date - 1, 'days', (p_date - 1) - x.last_before)
    from (select max(r.snapshot_date) as last_before from cma.flash_snapshot_run r
          where r.tenant_id = p_tenant_id and r.status = 'succeeded' and r.snapshot_date < p_date - 1) x
    where x.last_before is not null and not v_prev_ok
  ), res as (
    -- every open finding whose condition no longer holds
    update cma.flash_watch_finding f set state = 'resolved', resolved_on = p_date
    where f.tenant_id = p_tenant_id and f.state = 'open'
      and not exists (select 1 from cur n
                      where n.kind = f.kind and coalesce(n.overview, '') = coalesce(f.overview, '') and n.dims = f.dims
                        and coalesce(n.measure, '') = coalesce(f.measure, ''))
    returning 1
  ), ins as (
    -- every condition that holds without an open finding, once per key (a condition that holds twice is one finding, so
    -- a take never fails on the open findings' unique index)
    insert into cma.flash_watch_finding (tenant_id, snapshot_date, kind, overview, dims, measure, value, previous, threshold, detail)
    select distinct on (n.kind, coalesce(n.overview, ''), n.dims, coalesce(n.measure, ''))
           p_tenant_id, p_date, n.kind, n.overview, n.dims, n.measure, n.value, n.previous, n.threshold, n.detail
    from cur n
    where not exists (select 1 from cma.flash_watch_finding f
                      where f.tenant_id = p_tenant_id and f.state = 'open' and f.kind = n.kind
                        and coalesce(f.overview, '') = coalesce(n.overview, '') and f.dims = n.dims
                        and coalesce(f.measure, '') = coalesce(n.measure, ''))
    returning 1
  )
  select (select count(*) from res), (select count(*) from ins) into v_resolved, v_opened;
  return jsonb_build_object('watch_opened', v_opened, 'watch_resolved', v_resolved,
                            'watch_open', (select count(*) from cma.flash_watch_finding f where f.tenant_id = p_tenant_id and f.state = 'open'));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. Grants and JIT: as 0008zt's (a function made again keeps its grants, not its settings)
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.flash_overviews()', 'cma.flash_definition_version(text)', 'cma.flash_split_dim_of(text)', 'cma.flash_split_of(jsonb,text,text,text,text[])',
    'cma.flash_stored_split_of(uuid,text,text,date[])', 'cma.flash_stored_version_of(uuid,text,date[])',
    'cma.flash_customer_figures_of(uuid)', 'cma.flash_store_customers_of(uuid)',
    'cma.flash_compute_of(uuid,text,date,date,date)', 'cma.flash_rows_of(uuid,text,jsonb,text,boolean,integer,integer,date,date)',
    'cma.flash_headline(text,text,date,date)', 'cma.flash_page(text,date,date,date)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
  -- the take's writers: the owner's alone (the take runs them with the owner's rights)
  foreach f in array array['cma.flash_snapshot_ids_write_of(uuid,date,uuid)', 'cma.flash_watch_of(uuid,date,timestamptz)'] loop
    execute format('revoke execute on function %s from public, cma_app', f);
  end loop;
  -- JIT off for the large reads and the take's writers, as 0008zn (section 14 of 122); cma.flash_headline sets its own
  foreach f in array array[
    'cma.flash_compute_of(uuid,text,date,date,date)', 'cma.flash_rows_of(uuid,text,jsonb,text,boolean,integer,integer,date,date)',
    'cma.flash_snapshot_ids_write_of(uuid,date,uuid)', 'cma.flash_watch_of(uuid,date,timestamptz)'
  ] loop
    execute format('alter function %s set jit = off', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 8. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008zu', 'Flash totals (brief B30): the subscriptions'' headline Total subscriptions (holding_subscriptions: the subscriptions in flash.device_holding_statuses), split per holding status (the set [market, status], every holding status per market with a holding subscription, zeros included); active_customers on the device-holding statuses (paused_customers: a paused subscription and none holding; the segment rows follow); active_subscriptions and amount_per_cycle stay over the paying statuses; the cards'' split and definition versions (the page marks a change of definition where it compares across one); a month end''s customer list on the holding statuses; the watch compares no overview across a change of its definition; customers'' and subscriptions'' definition 0008zu, live and in the snapshot one computation')
on conflict (version) do nothing;

commit;
reset role;
