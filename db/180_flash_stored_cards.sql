-- =============================================================================================
-- 180_flash_stored_cards.sql: addition 0009p, Flash's landing reads its cards from the stored current takes
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after 178_job_reads.sql
-- (0009o; renumbered on 12 November 2026 from 174 and 0009m, from 176 and 0009n, then from 178 and 0009o, when #267 took those for its refresh and attribution fixes and #274 for the minute jobs' reads). Rerunnable, forward-only, in one transaction with a lock timeout. Run as your own IAM login: dev first, then
-- 181_verify_flash_stored_cards.sql there (normal, then provoked), then the verifies that read what this script
-- re-creates:
--   cma.flash_compute_of(uuid, text, date, date, date) (from 146): 123_verify_flash.sql, 137_verify_flash_insights.sql,
--     139_verify_flash_totals.sql, 143_verify_reviews_all_order_kinds.sql, 147_verify_installed_base_models.sql,
--     159_verify_flash_current_take.sql, 161_verify_installed_base_now.sql and 173_verify_active_customers.sql
--   the default of the setting flash.current_overviews (every stock overview but data quality, was installed_base):
--     123 (edited by this change: the default it expects) and 159 (edited by this change: the same)
-- All but those two unchanged, still PASS: the function keeps every rule and asks one source's set-up where it asked
-- every source's. Then 131_time_all.sql part a, which gains the landing's reads and times the takes' refresh. Prod: this
-- script and 181 before the merge. The web of main runs on it without a change of code, and shows two differences from
-- the job's next run on (at most a minute): its landing's cards still ask cma.flash_headline, which this script leaves
-- as it is, and answer sooner; and the overview pages of Customers, Total subscriptions, Open deals, Open tickets and
-- Open tasks read their now from the stored take with its Refreshed at, as Installed base has since 0009e
-- (cma.flash_document_of reads the take of every overview of the setting, 158_flash_current_take.sql), for every tenant
-- that has not set flash.current_overviews itself. Between this script and that run every take is outdated (older than
-- the latest migration), so everything is read live.
--
-- Why (Martin, 11 November 2026: "keep a data table up to date in the background ... load the first views with the
-- current Today lightning fast from this table and, while that shows, load the rest"; Decision log): the Flash landing
-- drew its eleven cards with a read each, fired by the browser after the page was there: at three times prod's volume
-- 1.4 to 1.5 s after the page until the last card, 3.3 s of database time and 24 transactions per view. The stock
-- overviews' figures already have a stored home, the current take of addition 0009e (cma.flash_current_take, refreshed by
-- the snapshot job when older than flash.current_refresh_minutes), which only Installed base used.
--
-- What it changes
--   setting   flash.current_overviews' default becomes every stock overview but data quality (cma.flash_current_keys():
--             customers, subscriptions, installed_base, open_deals, open_tickets, open_tasks); a tenant that set its own
--             value keeps it. The snapshot job then keeps a take of each (its next run after this script takes them),
--             and every reader of a take reads them: the landing's cards (this change), each of those overviews'
--             pages and documents (cma.flash_overview, 0009e's rule, for five more overviews than before), and the
--             readers' view cma_read.flash_current_take, which holds six overviews' figures where it held one
--   compute   cma.flash_compute_of asks cma.flash_source_set_up_of for its source's set-up (under 2 ms) instead of
--             cma.flash_sources_of (every source's adapters and last read: 146 ms at three times prod's volume, on every
--             live headline, every live document and every take); the same derivation, so the same answer
--   read      cma.flash_cards_now(market): the landing's cards whose figure is stored, in one read: for each stock
--             overview with a current take that may be read (fresh or usable: cma.flash_current_state_of) its headline,
--             split, definition and Refreshed at, exactly as cma.flash_headline answers it live; every other card
--             (a flow's period, data quality, a stock overview without a readable take) is marked not stored and the
--             page reads it live, as before. reports.view or performance.team (CMA06); a market out of its form CMA04
-- No table, no index, no job: the snapshot job and its schedule are 0009e's.
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
  if not exists (select 1 from cma.schema_migration where version = '0009o') then
    raise exception 'addition 0009o (178_job_reads.sql) has not run in this database';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The setting's default: every stock overview but data quality keeps a current take
-- ---------------------------------------------------------------------------------------------
update cma.setting s
set default_value = array_to_string(cma.flash_current_keys(), ','),
    description = 'The Flash overviews whose now is read from a stored current take refreshed by the snapshot job, with its Refreshed at: stock overviews but data quality, each once, comma-separated (every one of them by default: the landing''s cards and the overviews read them); empty: every now is computed live'
where s.key = 'flash.current_overviews';

-- ---------------------------------------------------------------------------------------------
-- 2. cma.flash_compute_of: one source's set-up, not every source's last read
-- ---------------------------------------------------------------------------------------------
-- As 0008zy (146) but for its set-up guard.
-- based on: 146_installed_base_models.sql
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
  -- one source's set-up (cma.flash_source_set_up_of, 0008zz: the derivation cma.flash_sources_of takes its set_up from),
  -- not every source's adapters and last read: that was a max over cma.sync_run per source on every computation
  if v_src is not null and not coalesce(cma.flash_source_set_up_of(p_tenant_id, v_src), false) then
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
-- a function made again loses its settings: JIT off, as 146 set it
alter function cma.flash_compute_of(uuid, text, date, date, date) set jit = off;

-- ---------------------------------------------------------------------------------------------
-- 3. The landing's stored cards, in one read
-- ---------------------------------------------------------------------------------------------
-- For every overview in the landing's order: stored true with the headline as cma.flash_headline answers it (value,
-- split, set_up, definition_version, the market asked for) read from the overview's current take, with refreshed_at (the
-- take's instant); or stored false where the page reads the card live: a flow (its figure is of a period), data quality
-- (its own stored result, read by its own function), a stock overview that keeps no take (not in the tenant's
-- flash.current_overviews) or whose take may not be read (none yet, older than three times flash.current_refresh_minutes,
-- or of an earlier definition or before the latest migration): never silently old figures; such a card says only
-- whether its source is set up (set_up), so the page reads no live figure where none shows. One statement per overview
-- over the take's rows of that overview (the primary key's prefix), so a refresh committing meanwhile is seen whole or
-- not at all
create or replace function cma.flash_cards_now(p_market text default null)
returns jsonb
language plpgsql stable
set jit = off
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_now     timestamptz := now();
  v_keys    text[] := cma.flash_current_keys();
  v_cards   jsonb := '[]'::jsonb;
  o         record;
  v_set     text[];
  v_taken   timestamptz;
  v_version text;
  v_rows    jsonb;
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.assert_flash_params(p_market, null, null, null, cma.tenant_today_of(v_tenant));
  for o in select * from cma.flash_overviews() x order by x.sort_order loop
    v_taken := null; v_version := null; v_rows := null;
    if o.kind = 'stock' and o.key = any (v_keys) then
      -- the rows a headline reads (cma.flash_headline): the totals, the market's, and the split set's of that market
      v_set := cma.flash_split_set_of(o.key);
      select max(c.computed_at), min(c.definition_version),
             jsonb_agg(jsonb_build_object('dims', c.dims, 'measures', c.measures))
               filter (where c.dims = '{}'::jsonb or c.dims = jsonb_build_object('market', p_market)
                          or (v_set is not null and c.dims ?& v_set and (select count(*) from jsonb_object_keys(c.dims)) = cardinality(v_set)
                              and (p_market is null or c.dims ->> 'market' = p_market)))
      into v_taken, v_version, v_rows
      from cma.flash_current_take c
      where c.tenant_id = v_tenant and c.overview = o.key;
      if cma.flash_current_state_of(v_tenant, o.key, v_taken, v_version, v_now) not in ('fresh', 'usable') then
        v_taken := null;
      end if;
    end if;
    v_cards := v_cards || jsonb_build_array(case when v_taken is null
      -- not stored: whether its source is set up (0008zz's derivation, as cma.flash_page says it), so the page asks
      -- no live figure of a card that shows none
      then jsonb_build_object('overview', o.key, 'stored', false,
                              'set_up', o.source is null or coalesce(cma.flash_source_set_up_of(v_tenant, o.source), false))
      else jsonb_build_object(
        'overview', o.key, 'stored', true, 'headline', o.headline, 'market', p_market, 'refreshed_at', v_taken,
        'set_up', v_rows is not null,
        'value', coalesce(cma.flash_pick_of(v_rows, p_market, o.headline),
                          case when cma.flash_pick_of(v_rows, null, o.headline) is not null then '0'::jsonb end),
        'split', case when v_set is not null and v_rows is not null then cma.flash_headline_split_of(v_tenant, o.key, v_rows, p_market) end,
        'definition_version', v_version) end);
  end loop;
  return jsonb_build_object('market', p_market, 'as_of', v_now, 'cards', v_cards);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Grants: the application only (a function made again keeps its grants)
-- ---------------------------------------------------------------------------------------------
revoke execute on function cma.flash_cards_now(text) from public;
grant execute on function cma.flash_cards_now(text) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 5. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009p', 'Flash: the landing reads its stock cards from the stored current takes in one read (cma.flash_cards_now); flash.current_overviews defaults to every stock overview but data quality; cma.flash_compute_of asks one source''s set-up (cma.flash_source_set_up_of) instead of every source''s last read')
on conflict (version) do nothing;

commit;
reset role;
