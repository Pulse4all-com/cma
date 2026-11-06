-- =============================================================================================
-- 148_installed_base_list.sql: addition 0008zz, the installed base's records list filtered first: the payment state for
-- the page alone, one source's set-up instead of every source's last read
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 146_installed_base_models.sql (0008zy). Rerunnable, forward-only, in one transaction with a lock timeout. Run as your own
-- IAM login, away from minute 20 (the hourly snapshot job): dev first, then 149_verify_installed_base_list.sql there, then
-- 123_verify_flash.sql again (it reads the remade functions); then prod in the same order, then 131_time_all.sql part a.
-- The web of main runs unchanged on it (every function keeps its name, arguments, columns and answer; two functions are
-- added), so the usual order applies: the database first, then the merge. No table, view, column or setting changes and
-- no seed need run again; the data map's schema does not change.
--
-- Why (Martin, 6 November 2026; Decision log): 131 part a measured the installed base's records first page live at
-- 524.5 ms in prod against verify.max_list_ms (300 ms). At three times prod's volume locally (web/verify/perf-volume-
-- fixture.sql, as the application) the read was 551 ms unfiltered and 1.3 s with a market or a model, spent in two places:
--   payment state   cma.flash_rows_of joined cma.subscription_payment_state_of (every subscription of the tenant) to every
--                   device before the filter; with a filter the planner took a nested loop over its open failures (2 s).
--                   No filter and no sort reads it: it is a column of the page's rows. It now joins the page's rows
--                   only, for the page's subscriptions (a new overload of the function, 118's derivation with its
--                   subscriptions narrowed first; 0008zl's one-argument function is unchanged)
--   sources         cma.flash_rows_of and cma.flash_rows each asked cma.flash_sources_of for the source's set-up: every
--                   source's adapters and last read (a max over cma.sync_run per source, 146 ms at that volume), twice
--                   per list. They now ask cma.flash_source_set_up_of (one source's set-up, under 2 ms), and
--                   cma.flash_sources_of takes its set_up from that same function, so the set-up has one derivation
-- The answers do not change: 149 compares every remade function with its previous definition, kept in the script, row
-- for row, in a throwaway tenant and in every tenant.
--
-- What it changes (functions only):
--   cma.subscription_payment_state_of(uuid, uuid[])  new: the payment state of the given subscriptions (118's derivation)
--   cma.flash_source_set_up_of(uuid, text)          new: whether one Flash source is set up (122's derivation)
--   cma.flash_sources_of                            set_up from cma.flash_source_set_up_of; adapters and last read as before
--   cma.flash_rows_of                               installed_base: the devices filtered, sorted and paged first, the payment
--                                                   state for the page's subscriptions; the set-up from the new function
--   cma.flash_rows                                  set_up from the new function
-- SQLSTATEs as before.
--
-- Additions after 0008zz continue as 0009a, 0009b, ... (Martin, 6 November 2026; Decision log): the same lettering one
-- level up, so the versions' text order stays the order they run in.
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
  if not exists (select 1 from cma.schema_migration where version = '0008zy') then
    raise exception 'addition 0008zy (146_installed_base_models.sql) must run before 0008zz';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The payment state of given subscriptions
-- ---------------------------------------------------------------------------------------------
-- 118's derivation (section 6 of 118_subscriptions.sql), word for word but for its subscriptions: those of the given ids
-- alone, narrowed before the failed renewals are read. Every part of it is per subscription (its events by connection and
-- source id), so a subscription's row is the one-argument function's row; 149 proves it in every tenant. For a list's page
-- (cma.flash_rows_of): at most a page of ids, read through the subscriptions' primary key
create or replace function cma.subscription_payment_state_of(p_tenant_id uuid, p_subscription_ids uuid[])
returns table (subscription_id uuid, connection_id uuid, source_id text, customer_source_id text, status text, payment_state text,
               retry_cycle integer, retry_since timestamptz, last_attempt integer)
language sql stable
as $$
  with s as (
    select s.id, s.connection_id, s.source_id, s.customer_source_id, s.status
    from cma.subscription s
    where s.tenant_id = p_tenant_id and s.source_deleted_at is null
      and s.status in ('active', 'paused', 'canceled', 'expired', 'failed')
      and s.id = any (p_subscription_ids)
  ),
  open_failure as (
    select f.connection_id, f.subscription_source_id, f.cycle_index, f.occurred_at, f.attempt
    from cma.subscription_event f
    join s on s.connection_id = f.connection_id and s.source_id = f.subscription_source_id and s.status = 'active'
    where f.tenant_id = p_tenant_id and f.event_type = 'renew_failed'
      and not exists (select 1 from cma.subscription_event r
                      where r.tenant_id = f.tenant_id and r.connection_id = f.connection_id
                        and r.subscription_source_id = f.subscription_source_id and r.event_type = 'renewed'
                        and case when f.cycle_index is not null and r.cycle_index is not null then r.cycle_index >= f.cycle_index
                                 else r.occurred_at > f.occurred_at end)
  ),
  retry as (
    select o.connection_id, o.subscription_source_id,
           (array_agg(o.cycle_index order by o.cycle_index desc nulls last, o.occurred_at desc))[1] as cycle_index
    from open_failure o
    group by 1, 2
  ),
  retry_detail as (
    select r.connection_id, r.subscription_source_id, r.cycle_index, min(o.occurred_at) as since, max(o.attempt) as last_attempt
    from retry r
    join open_failure o on o.connection_id = r.connection_id and o.subscription_source_id = r.subscription_source_id
                       and o.cycle_index is not distinct from r.cycle_index
    group by 1, 2, 3
  )
  select s.id, s.connection_id, s.source_id, s.customer_source_id, s.status,
         case when s.status = 'failed' then 'failed'
              when s.status = 'paused' then 'paused'
              when s.status in ('canceled', 'expired') then 'canceled'
              when d.subscription_source_id is not null then 'in_retry'
              else 'paid' end,
         d.cycle_index, d.since, d.last_attempt
  from s
  left join retry_detail d on d.connection_id = s.connection_id and d.subscription_source_id = s.source_id
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. One source's set-up
-- ---------------------------------------------------------------------------------------------
-- Whether one Flash source is set up, as cma.flash_sources_of (122) has derived it: commerce (a store of an active
-- connection), subscriptions (a subscriptions store of an active connection), assets (0008zi's set-up), reviews (0008ze's),
-- crm (an active connection of kind crm, or one holding CRM rows); null for any other key. It reads no sync_run: a list
-- and its file need the set-up alone, not every source's last read
create or replace function cma.flash_source_set_up_of(p_tenant_id uuid, p_source text)
returns boolean
language sql stable
as $$
  select case p_source
    when 'commerce' then exists (select 1 from cma.commerce_store st
                                 join cma.integration_connection ic on ic.id = st.connection_id and ic.tenant_id = p_tenant_id and ic.status = 'active'
                                 where st.tenant_id = p_tenant_id)
    when 'subscriptions' then exists (select 1 from cma.flash_subscription_stores_of(p_tenant_id) s
                                      join cma.integration_connection ic on ic.id = s.connection_id and ic.tenant_id = p_tenant_id
                                                                        and ic.status = 'active')
    when 'assets' then cma.assets_set_up_of(p_tenant_id)
    when 'reviews' then cma.reviews_set_up_of(p_tenant_id)
    when 'crm' then exists (select 1 from cma.integration_connection ic
                            where ic.tenant_id = p_tenant_id and ic.status = 'active'
                              and case when ic.kind is not null then ic.kind
                                       when exists (select 1 from cma.commerce_store x where x.tenant_id = ic.tenant_id and x.connection_id = ic.id)
                                       then 'commerce'
                                       else (cma.connection_held_kinds_of(ic.tenant_id, ic.id))[1] end = 'crm')
  end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. The sources: the set-up from section 2
-- ---------------------------------------------------------------------------------------------
-- As 0008zn (122), its set_up taken from cma.flash_source_set_up_of so the set-up has one derivation
create or replace function cma.flash_sources_of(p_tenant_id uuid)
returns jsonb
language sql stable
as $$
  with c as (
    select ic.id, ic.adapter,
           case when ic.kind is not null then ic.kind
                when exists (select 1 from cma.commerce_store x where x.tenant_id = ic.tenant_id and x.connection_id = ic.id) then 'commerce'
                else (cma.connection_held_kinds_of(ic.tenant_id, ic.id))[1] end as kind
    from cma.integration_connection ic
    where ic.tenant_id = p_tenant_id and ic.status = 'active'
  ), k as (
    select x.kind, array_agg(distinct c.adapter order by c.adapter) filter (where c.id is not null) as adapters,
           (select max(r.finished_at) from cma.sync_run r
            where r.tenant_id = p_tenant_id and r.status = 'succeeded' and r.connection_id in (select c2.id from c c2 where c2.kind = x.kind)) as last_read_at
    from unnest(array['commerce', 'subscriptions', 'assets', 'crm', 'reviews']) x(kind)
    left join c on c.kind = x.kind
    group by x.kind
  )
  select jsonb_object_agg(k.kind, jsonb_build_object(
           'set_up', cma.flash_source_set_up_of(p_tenant_id, k.kind),
           'adapters', coalesce(to_jsonb(k.adapters), '[]'::jsonb),
           'last_read_at', k.last_read_at))
  from k
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. A list: the installed base filtered and paged before the payment state; the set-up of its own source
-- ---------------------------------------------------------------------------------------------
-- As 0008zu (138), with two changes. The set-up asks cma.flash_source_set_up_of. The installed base's base is the devices
-- alone: the filter, the count, the sort and the page read no payment state, and the page's rows take theirs from
-- cma.subscription_payment_state_of for the page's subscriptions (v_extra and v_page, empty and the page for every other
-- overview, whose statement is as before)
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
  v_extra text := '';      -- columns the page adds after the filter and the paging (0008zz)
  v_page  text := 'p x';   -- the page and what it joins (0008zz)
begin
  if v_order is null then
    raise exception 'sort % is not a sort key of %', p_sort, p_overview using errcode = 'CMA04';
  end if;
  if v_src is not null and not coalesce(cma.flash_source_set_up_of(p_tenant_id, v_src), false) then
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
      -- the devices, filtered and paged first; the linked subscription's payment state (0008zl's derivation) only for the
      -- page's subscriptions, since no filter or sort reads it (addition 0008zz)
      v_base := 'cma.flash_devices_of($2, $7)';
      v_extra := ', ps.payment_state as subscription_payment_state';
      v_page := 'p x left join cma.subscription_payment_state_of($2, array(select y.subscription_id from p y where y.subscription_id is not null)) ps
                   on ps.subscription_id = x.subscription_id';
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
          n as (select x.*%s, row_number() over (order by %s) as ord from %s)
     select jsonb_build_object(''total'', (select count(*) from f),
                               ''rows'', coalesce((select jsonb_agg(%s order by x.ord) from n x), ''[]''::jsonb))',
    v_base, v_where, v_order, v_extra, v_order, v_page, v_obj)
    into v_res
    using p_filters, p_tenant_id, p_limit, p_offset, v_from, v_to, v_today, cma.flash_holding_statuses_of(p_tenant_id);
  return v_res;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. The list's read: the set-up of its own source
-- ---------------------------------------------------------------------------------------------
-- As 0008zn (122), its set_up from cma.flash_source_set_up_of
create or replace function cma.flash_rows(p_overview text, p_filters jsonb default '{}'::jsonb, p_sort text default null,
                                          p_descending boolean default false, p_limit integer default 500, p_offset integer default 0,
                                          p_as_of date default null, p_from date default null, p_to date default null)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_today   date;
  v_filters jsonb := coalesce(p_filters, '{}'::jsonb);
  o         record;
  v_sort    text;
  v_res     jsonb;
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.assert_flash_overview(p_overview);
  v_today := cma.tenant_today_of(v_tenant);
  perform cma.assert_flash_params(null, p_as_of, p_from, p_to, v_today);
  select * into o from cma.flash_overviews() x where x.key = p_overview;
  if jsonb_typeof(v_filters) <> 'object'
     or exists (select 1 from jsonb_each(v_filters) e
                where not (e.key = any (o.dims) or e.key = 'measure') or jsonb_typeof(e.value) <> 'string'
                   or length(e.value #>> '{}') not between 1 and 100)
     or (v_filters ? 'measure' and not ((v_filters ->> 'measure') = any (o.count_measures))) then
    raise exception 'filters are the overview''s dims (%) and measure (one of %), each a text', array_to_string(o.dims, ', '),
      array_to_string(o.count_measures, ', ') using errcode = 'CMA04';
  end if;
  -- a measure that does not apply has no records: with_required_refs while no contact reference is required
  if p_overview = 'customers' and (v_filters ->> 'measure') = 'with_required_refs'
     and cardinality(cma.flash_list_of(cma.setting_of(v_tenant, 'commerce.required_contact_refs'))) = 0 then
    raise exception 'with_required_refs does not apply: commerce.required_contact_refs is empty' using errcode = 'CMA04';
  end if;
  perform cma.assert_flash_params(v_filters ->> 'market', null, null, null, v_today);
  if p_limit is null or p_limit not between 1 and cma.setting_of(v_tenant, 'flash.file_max_rows')::integer
     or p_offset is null or p_offset not between 0 and 100000000 then
    raise exception 'a list reads 1 to % rows from an offset of 0 or more', cma.setting_of(v_tenant, 'flash.file_max_rows') using errcode = 'CMA04';
  end if;
  if p_as_of is null then
    v_sort := coalesce(p_sort, o.sorts[1]);
    v_res := cma.flash_rows_of(v_tenant, p_overview, v_filters, v_sort, p_descending, p_limit, p_offset,
                               case when o.kind = 'flow' then coalesce(p_from, v_today) end, case when o.kind = 'flow' then coalesce(p_to, v_today) end);
  else
    v_sort := p_sort;
    v_res := cma.flash_id_rows_of(v_tenant, p_overview, v_filters, p_sort, p_descending, p_limit, p_offset, p_as_of);
  end if;
  return jsonb_build_object('overview', p_overview, 'mode', case when p_as_of is null then 'live' else 'snapshot' end,
                            'as_of', case when p_as_of is null then to_jsonb(now()) else to_jsonb(p_as_of) end,
                            'from', case when o.kind = 'flow' and p_as_of is null then coalesce(p_from, v_today) end,
                            'to', case when o.kind = 'flow' and p_as_of is null then coalesce(p_to, v_today) end,
                            'filters', v_filters, 'sort', v_sort, 'descending', coalesce(p_descending, false), 'limit', p_limit, 'offset', p_offset,
                            'set_up', case when o.source is null then true
                                           else coalesce(cma.flash_source_set_up_of(v_tenant, o.source), false) end,
                            'time_zone', (select t.timezone from cma.tenant t where t.id = v_tenant))
         || v_res;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. Grants and JIT: the application only (a function made again keeps its grants, not its settings)
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.subscription_payment_state_of(uuid,uuid[])', 'cma.flash_source_set_up_of(uuid,text)', 'cma.flash_sources_of(uuid)',
    'cma.flash_rows_of(uuid,text,jsonb,text,boolean,integer,integer,date,date)', 'cma.flash_rows(text,jsonb,text,boolean,integer,integer,date,date,date)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
  -- JIT off for the large read, as 0008zn (section 14 of 122) and 0008zu (138)
  execute 'alter function cma.flash_rows_of(uuid,text,jsonb,text,boolean,integer,integer,date,date) set jit = off';
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008zz', 'The installed base''s records list filtered first: cma.flash_rows_of filters, sorts and pages the devices before the linked subscription''s payment state, which it reads for the page''s subscriptions alone (cma.subscription_payment_state_of(uuid, uuid[]), 118''s derivation with its subscriptions narrowed first); cma.flash_rows_of and cma.flash_rows ask one source''s set-up (cma.flash_source_set_up_of, which cma.flash_sources_of now takes its set_up from) instead of every source''s last read; the answers unchanged; the web starts the records read with the document''s and applies As of on Enter or blur; additions after 0008zz continue as 0009a, 0009b, ...')
on conflict (version) do nothing;

commit;
reset role;
