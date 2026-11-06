-- =============================================================================================
-- 146_installed_base_models.sql: addition 0008zy, Installed base by model: the In the field split, the Model filter's set
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics: the models and their order are the tenant's asset register
-- (cma.device_model: key, name, sort_order, status), never code. Runs unchanged in every database, after
-- 142_reviews_all_order_kinds.sql (0008zw); 0008zx and 144/145 are left to the held-kinds fix, which may land before or
-- after this one (neither depends on the other). Rerunnable, forward-only, in one transaction with a lock timeout. Run as
-- your own IAM login, away from minute 20 (the hourly snapshot job): dev first, then 147_verify_installed_base_models.sql
-- there, then 123_verify_flash.sql, 137_verify_flash_insights.sql, 139_verify_flash_totals.sql and
-- 143_verify_reviews_all_order_kinds.sql again (137, 139 and 143 accept the new set and split since this change, the edits
-- of this PR, Decision log); then prod in the same order, before the merge. The web of main runs unchanged on it: its
-- installed base breakdown shows the subscription-status set with the model as one more column, the landing's In the
-- field card gains a split main shows under the figure, and the document's split_order key is extra. No table, view or
-- column changes and no setting: seed 02 need not run again, and the data map's schema does not change.
--
-- Why (Martin, 6 November 2026; Decision log): Reports → Flash's Installed base and Assets → Installed base split In the
-- field per model and take a Model filter that narrows every tile, bar, breakdown and record:
--   split        In the field (the installed base's headline) per model, from the rows of [market, status, model,
--                warehouse, link] summed over the other dims: every active model of the register in its order
--                (sort_order, then key), zeros included, then any other model a row holds (an inactive one, unknown)
--                only above 0, by key; each part labelled with the register's name (the landing's card has no document
--                to take the labels from). Live (cma.flash_headline), as of a date (the stored rows, cma.flash_page);
--                none for a snapshot without those rows
--   filter       the web narrows the document by a model from the rows of the sets that hold the model: every measure
--                from [market, status, model, warehouse, link] (it carries them all), the subscription-status breakdown
--                from [market, model, subscription_status], which replaces [market, subscription_status] here so it can
--                follow the filter. A snapshot stored before this change holds the subscription-status rows without the
--                model: that breakdown shows as not available with a Model filter
--   the order    cma.flash_overview answers split_order (the keys the headline's split shows first: the holding
--                statuses, the order kinds, the register's models), so the page's tile follows the database's order
-- The figures do not change: installed_base's definition version stays 0008zt (the watch compares the totals and the
-- [market] rows only, which keep their keys).
--
-- What it changes (functions only):
--   cma.flash_overviews()          installed_base's set [market, subscription_status] becomes [market, model,
--                                  subscription_status]
--   cma.flash_compute_of           the installed base's grouping set likewise; the snapshot stores it (one computation)
--   cma.flash_split_dim_of, cma.flash_split_set_of, cma.flash_split_order_of: installed_base → model, [market, status,
--                                  model, warehouse, link], the register's active models in its order
--   cma.flash_headline_split_of    a part of the installed base's split carries its model's name (label)
--   cma.flash_overview             the document answers split_order
-- SQLSTATEs as before.
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
  if not exists (select 1 from cma.schema_migration where version = '0008zw') then
    raise exception 'addition 0008zw (142_reviews_all_order_kinds.sql) must run before 0008zy';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The overviews: installed_base's subscription-status set holds the model
-- ---------------------------------------------------------------------------------------------
-- As 0008zu (138), with installed_base's set [market, subscription_status] made [market, model, subscription_status]
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
       '[[], ["market"], ["market", "status", "model", "warehouse", "link"], ["market", "model", "subscription_status"]]'::jsonb,
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

-- ---------------------------------------------------------------------------------------------
-- 2. The figures: the installed base's subscription-status rows per model
-- ---------------------------------------------------------------------------------------------
-- As 0008zu (138), with the installed base's grouping set (market, subscription_status) made (market, model,
-- subscription_status). The snapshot stores exactly these rows (one code path)
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
      -- market's holding_subscriptions; the setting holds the subscription app's status words alone (0008zt's check), so a
      -- split row's dim is always such a word
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
                  -- the model beside the subscription status since 0008zy, so the set follows a Model filter
                  when grouping(b.subscription_status) = 0
                  then jsonb_build_object('market', b.market, 'model', b.model, 'subscription_status', b.subscription_status)
                  else jsonb_build_object('market', b.market) end,
             jsonb_build_object('devices', count(*), 'in_field', count(*) filter (where b.is_in_field),
                                'in_stock', count(*) filter (where b.is_in_stock), 'components_past_due', coalesce(sum(b.past_due_items), 0),
                                'items_due_3m', coalesce(sum(b.items_due_3m), 0),
                                -- devices in the field on a device-holding subscription (0008zt): never one in stock, whatever its reference
                                'in_field_on_holding', count(*) filter (where b.is_in_field and b.subscription_status = any (v_holding)))
      from cma.flash_devices_of(p_tenant_id, v_on) b
      group by grouping sets ((), (b.market), (b.market, b.status, b.model, b.warehouse, b.link), (b.market, b.model, b.subscription_status));
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
-- 3. The split: In the field per model
-- ---------------------------------------------------------------------------------------------
-- The dim a headline is split by: Total subscriptions per device-holding status (0008zu), the orders per order kind
-- (0008zw), In the field per model (0008zy); none for another overview
create or replace function cma.flash_split_dim_of(p_overview text)
returns text
language sql immutable
as $$
  select case when p_overview = 'subscriptions' then 'status' when p_overview = 'orders' then 'kind'
              when p_overview = 'installed_base' then 'model' end
$$;

-- The grouping set whose rows a headline's split reads: [market, status] for the subscriptions, [market, store, kind]
-- for the orders, [market, status, model, warehouse, link] for the installed base (summed over the other dims); none for
-- another overview
create or replace function cma.flash_split_set_of(p_overview text)
returns text[]
language sql immutable
as $$
  select case when p_overview = 'subscriptions' then array['market', 'status']
              when p_overview = 'orders' then array['market', 'store', 'kind']
              when p_overview = 'installed_base' then array['market', 'status', 'model', 'warehouse', 'link'] end
$$;

-- The keys a headline's split shows first, in order, 0 where no row holds one: the tenant's device-holding statuses in the
-- setting's order (the subscriptions); the order kinds first, renewal and repeat (the orders); the register's active
-- models by its sort order, then key (the installed base). Any other key a row holds follows only above 0 (an order kind
-- unknown, an inactive model, a device without a model: unknown). None for another overview
create or replace function cma.flash_split_order_of(p_tenant_id uuid, p_overview text)
returns text[]
language sql stable
as $$
  select case when p_overview = 'subscriptions' then cma.flash_holding_statuses_of(p_tenant_id)
              when p_overview = 'orders' then array['first', 'renewal', 'repeat']
              when p_overview = 'installed_base'
              then coalesce((select array_agg(dm.key order by dm.sort_order, dm.key) from cma.device_model dm
                             where dm.tenant_id = p_tenant_id and dm.status = 'active'), '{}'::text[]) end
$$;

-- As 0008zw (142), with each part of the installed base's split labelled with its model's name in the register (none for
-- a key the register does not hold, such as unknown): the landing's card shows it without a document of labels. An
-- overview's headline split from the rows given: of the rows whose dims are exactly the split's set, the market's or
-- summed over every market (and over the set's other dims), as [{key, value}]: every key of cma.flash_split_order_of with
-- 0 where no row holds it, then any other key a row holds with a figure above 0, by name. Null for an overview without a
-- split
create or replace function cma.flash_headline_split_of(p_tenant_id uuid, p_overview text, p_rows jsonb, p_market text)
returns jsonb
language sql stable
as $$
  with s as (
    select cma.flash_split_set_of(p_overview) as dims, cma.flash_split_dim_of(p_overview) as dim, o.headline as measure,
           coalesce(cma.flash_split_order_of(p_tenant_id, p_overview), '{}'::text[]) as ord
    from cma.flash_overviews() o
    where o.key = p_overview and cma.flash_split_set_of(p_overview) is not null
  ), f as (
    select r -> 'dims' ->> s.dim as k, sum((r -> 'measures' ->> s.measure)::numeric) as v
    from s cross join jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) r
    where r -> 'dims' ?& s.dims and (select count(*) from jsonb_object_keys(r -> 'dims')) = cardinality(s.dims)
      and (p_market is null or r -> 'dims' ->> 'market' = p_market)
      and jsonb_typeof(r -> 'measures' -> s.measure) = 'number'
    group by 1
  ), k as (
    select x as k from s cross join unnest(s.ord) x
    union
    select f.k from f where f.v > 0
  ), l as (
    -- the register's names of the installed base's models (0008zy); none for another overview
    select dm.key, dm.name from cma.device_model dm where dm.tenant_id = p_tenant_id and p_overview = 'installed_base'
  )
  select case when exists (select 1 from s)
              then (select coalesce(jsonb_agg(jsonb_build_object('key', k.k, 'value', coalesce(f.v, 0))
                                              || case when l.name is not null then jsonb_build_object('label', l.name) else '{}'::jsonb end
                                              order by array_position((select s.ord from s), k.k) nulls last, k.k), '[]'::jsonb)
                    from k left join f on f.k = k.k left join l on l.key = k.k) end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. The document: the split's order
-- ---------------------------------------------------------------------------------------------
-- As 0008zn (122), with split_order: the keys the headline's split shows first (cma.flash_split_order_of; null for an
-- overview without a split), so the page's totals follow the database's order. One overview in one read (reports.view or
-- performance.team): live, or as of a snapshot's date; flows over a period
create or replace function cma.flash_overview(p_overview text, p_market text default null, p_as_of date default null,
                                              p_from date default null, p_to date default null)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.assert_flash_overview(p_overview);
  perform cma.assert_flash_params(p_market, p_as_of, p_from, p_to, cma.tenant_today_of(v_tenant));
  return cma.flash_document_of(v_tenant, p_overview, p_market, p_as_of, p_from, p_to)
         || jsonb_build_object('split_order', to_jsonb(cma.flash_split_order_of(v_tenant, p_overview)));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. Grants and JIT: the application only (a function made again keeps its grants, not its settings)
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.flash_overviews()', 'cma.flash_compute_of(uuid,text,date,date,date)', 'cma.flash_split_dim_of(text)', 'cma.flash_split_set_of(text)',
    'cma.flash_split_order_of(uuid,text)', 'cma.flash_headline_split_of(uuid,text,jsonb,text)', 'cma.flash_overview(text,text,date,date,date)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
  -- JIT off for the large read, as 0008zn (section 14 of 122) and 0008zu (138)
  execute 'alter function cma.flash_compute_of(uuid,text,date,date,date) set jit = off';
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008zy', 'Installed base by model: In the field split per model (cma.flash_split_dim_of, _set_of and _order_of: the set [market, status, model, warehouse, link], the register''s active models in its order with zeros, any other model only above 0, each part with its model''s name), live and as of a date; installed_base''s set [market, subscription_status] made [market, model, subscription_status] (cma.flash_overviews, cma.flash_compute_of) so the subscription-status breakdown follows a Model filter; cma.flash_overview answers split_order; the web''s Model filter, its two-part load and the Model select are web only; installed_base''s definition stays 0008zt')
on conflict (version) do nothing;

commit;
reset role;
