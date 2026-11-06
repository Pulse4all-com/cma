-- =============================================================================================
-- 149_verify_installed_base_list.sql: verifies addition 0008zz, the installed base's records list filtered first (the
-- payment state for the page alone, one source's set-up instead of every source's last read)
-- =============================================================================================
-- Blocks S check the addition and its functions (universal). Block A works on two throwaway tenants inside a
-- subtransaction that is always rolled back, so nothing stays; block D reads every active tenant's own data and writes
-- nothing. The script runs alike in dev and in prod. Every remade function is compared with its previous definition, kept
-- below as pg_temp.v0008zz_sources_0008zn (122), pg_temp.v0008zz_rows_of_0008zu (138) and pg_temp.v0008zz_rows_0008zn
-- (122), answer for answer (the same transaction, so the same now()). Every check writes one row, ok or FAIL, and the last
-- row is the verdict, because Cloud SQL Studio shows no notices: "0008zz verified | 149_verify_installed_base_list: 13 ok,
-- 0 FAIL, 0 skip" (D3 reads skip for a database without a tenant whose asset register is set up). Run as your own IAM
-- login after 148_installed_base_list.sql, dev first, then prod; then 123 again.
--   S1  the addition 0008zz is recorded after 0008zy
--   S2  privileges: the new and remade functions the application's only, in the caller's rights, nothing for the readers;
--       cma.flash_rows_of keeps JIT off
--   A1  the payment state of given subscriptions is the one-argument function's rows for them: all of a tenant's, a few,
--       none (an empty list, another tenant's ids, no list)
--   A2  one source's set-up is 0008zn's for every source, in a tenant with its sources set up and in one without; null for
--       a key that is no source
--   A3  cma.flash_sources_of is 0008zn's answer in both tenants (its adapters and last reads as before)
--   A4  the installed base's list is 0008zu's for every filter, sort, direction and page of a grid (200 lists)
--   A5  the page carries every payment state the fixture holds (in retry, paid, paused, canceled, failed, none for a
--       subscription not found), so A4 compares them
--   A6  every other overview's first page is 0008zu's (their statement is unchanged)
--   A7  cma.flash_rows (as the tenant's reader) is 0008zn's answer: the installed base, a market, a source not set up
--   A8  a tenant whose register is not set up: an empty list, as before
--   D1  every tenant: each source's set-up and cma.flash_sources_of as 0008zn's
--   D2  every tenant: the payment state of all its subscriptions, and of its first 500, is the one-argument function's
--   D3  every tenant with an asset register: the installed base's list is 0008zu's for a grid of filters, sorts and pages
-- Provoke: set provoke below to true; every check must then read FAIL, and the verdict says PROVOKED, NOT A PASS.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);   -- 'true' to make every check fail

drop table if exists pg_temp.verify_0008zz;
create temp table verify_0008zz (ord int, check_name text, result text, detail text);
grant select, insert on pg_temp.verify_0008zz to cma_app;

-- ---------------------------------------------------------------------------------------------
-- The previous definitions, word for word but for their names and the calls between them
-- ---------------------------------------------------------------------------------------------
-- cma.flash_sources_of as 0008zn (122_flash.sql) defined it
create or replace function pg_temp.v0008zz_sources_0008zn(p_tenant_id uuid)
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
           'set_up', case k.kind
                       when 'commerce' then exists (select 1 from cma.commerce_store st join c on c.id = st.connection_id where st.tenant_id = p_tenant_id)
                       when 'subscriptions' then exists (select 1 from cma.flash_subscription_stores_of(p_tenant_id) s join c on c.id = s.connection_id)
                       when 'assets' then cma.assets_set_up_of(p_tenant_id)
                       when 'reviews' then cma.reviews_set_up_of(p_tenant_id)
                       else k.adapters is not null end,
           'adapters', coalesce(to_jsonb(k.adapters), '[]'::jsonb),
           'last_read_at', k.last_read_at))
  from k
$$;

-- cma.flash_rows_of as 0008zu (138_flash_totals.sql) defined it, JIT off as there
create or replace function pg_temp.v0008zz_rows_of_0008zu(p_tenant_id uuid, p_overview text, p_filters jsonb, p_sort text, p_descending boolean,
                                             p_limit integer, p_offset integer, p_from date, p_to date)
returns jsonb
language plpgsql stable
set jit = off
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
  if v_src is not null and not coalesce((pg_temp.v0008zz_sources_0008zn(p_tenant_id) -> v_src ->> 'set_up')::boolean, false) then
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

-- cma.flash_rows as 0008zn (122_flash.sql) defined it
create or replace function pg_temp.v0008zz_rows_0008zn(p_overview text, p_filters jsonb default '{}'::jsonb, p_sort text default null,
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
    v_res := pg_temp.v0008zz_rows_of_0008zu(v_tenant, p_overview, v_filters, v_sort, p_descending, p_limit, p_offset,
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
                                           else coalesce((pg_temp.v0008zz_sources_0008zn(v_tenant) -> o.source ->> 'set_up')::boolean, false) end,
                            'time_zone', (select t.timezone from cma.tenant t where t.id = v_tenant))
         || v_res;
end
$$;

-- A payment state's rows as one line, in subscription order
create or replace function pg_temp.v0008zz_ps(p_rows jsonb)
returns text
language sql
as $$
  select coalesce(string_agg(x::text, ';' order by x ->> 'subscription_id'), '') from jsonb_array_elements(p_rows) x
$$;

grant execute on function pg_temp.v0008zz_sources_0008zn(uuid) to cma_app;
grant execute on function pg_temp.v0008zz_rows_of_0008zu(uuid,text,jsonb,text,boolean,integer,integer,date,date) to cma_app;
grant execute on function pg_temp.v0008zz_rows_0008zn(text,jsonb,text,boolean,integer,integer,date,date,date) to cma_app;

-- S1. The addition
do $$
begin
  insert into verify_0008zz values (1, 'S1 the addition 0008zz is recorded after 0008zy',
    case when exists (select 1 from cma.schema_migration where version = '0008zz')
              and exists (select 1 from cma.schema_migration where version = '0008zy')
              and not current_setting('verify.provoke')::boolean then 'ok' else 'FAIL' end,
    (select string_agg(version, ', ' order by version) from cma.schema_migration where version in ('0008zy', '0008zz')));
end
$$;

-- S2. Privileges and settings
do $$
declare
  v_fn text;
  v_bad text := '';
begin
  foreach v_fn in array array[
    'cma.subscription_payment_state_of(uuid,uuid[])', 'cma.flash_source_set_up_of(uuid,text)', 'cma.flash_sources_of(uuid)',
    'cma.flash_rows_of(uuid,text,jsonb,text,boolean,integer,integer,date,date)', 'cma.flash_rows(text,jsonb,text,boolean,integer,integer,date,date,date)',
    'cma.subscription_payment_state_of(uuid)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or has_function_privilege('public', v_fn, 'execute') or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      v_bad := v_bad || v_fn || '; ';
    end if;
  end loop;
  if not coalesce((select 'jit=off' = any (proconfig) from pg_proc
                   where oid = to_regprocedure('cma.flash_rows_of(uuid,text,jsonb,text,boolean,integer,integer,date,date)')), false) then
    v_bad := v_bad || 'cma.flash_rows_of without jit=off; ';
  end if;
  insert into verify_0008zz values (2, 'S2 privileges: the new and remade functions the application''s only, in the caller''s rights; cma.flash_rows_of JIT off',
    case when v_bad = '' and not current_setting('verify.provoke')::boolean then 'ok' else 'FAIL' end, nullif(v_bad, ''));
end
$$;

-- A. Behaviour on two throwaway tenants, always rolled back
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  v_t1 uuid; v_t2 uuid; v_reader uuid; v_role uuid;
  v_crm uuid; v_gb uuid; v_nl uuid; v_sgb uuid; v_snl uuid; v_reg uuid;
  v_ids uuid[]; v_few uuid[]; v_other uuid[];
  v_bad text; v_txt text; v_n integer;
  k text; f jsonb; s text; d boolean; pg integer[]; o record; v_today date;
  v_new jsonb; v_old jsonb;
begin
  begin
    v_t1 := cma.create_tenant('verify-0008zz-one', 'Verify 0008zz one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008zz-two', 'Verify 0008zz two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-reader-0008zz@example.invalid', 'reader') returning id into v_reader;
    insert into cma.app_role (tenant_id, key, name) values (v_t1, 'verify_reader', 'Verify reader') returning id into v_role;
    insert into cma.role_permission (tenant_id, role_id, permission_key) values (v_t1, v_role, 'reports.view');
    insert into cma.user_role (tenant_id, user_id, role_id) values (v_t1, v_reader, v_role);

    -- tenant one's sources: a CRM, two stores with a subscriptions connection each, a register; no reviews
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency, sort_order) values
      (v_t1, 'GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', 10), (v_t1, 'NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR', 20);
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifycrm', 'Verify CRM', 'portal-1', 'crm') returning id into v_crm;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifyshop', 'Verify shop GB', 'shop-gb.shop.example', 'commerce') returning id into v_gb;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifyshop', 'Verify shop NL', 'shop-nl.shop.example', 'commerce') returning id into v_nl;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t1, 'verifysubs', 'Verify subscriptions GB', 'shop-gb.shop.example', 'subscriptions', 'verify-subs-gb') returning id into v_sgb;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t1, 'verifysubs', 'Verify subscriptions NL', 'shop-nl.shop.example', 'subscriptions', 'verify-subs-nl') returning id into v_snl;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifyregister', 'Verify register', 'base-1', 'assets') returning id into v_reg;
    insert into cma.commerce_store (tenant_id, connection_id, handle, name, market, currency, time_zone) values
      (v_t1, v_gb, 'shop-gb', 'Shop GB', 'GB', 'GBP', 'Europe/London'), (v_t1, v_nl, 'shop-nl', 'Shop NL', 'NL', 'EUR', 'Europe/Amsterdam');
    -- subscriptions: s-1 active with an open failed renewal (in retry), s-2 active whose failed renewal a later renewal
    -- closed (paid), s-3 and s-4 active (paid), s-5 paused, s-6 canceled, s-7 failed, n-1 active in NL
    insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, amount_per_cycle, currency,
                                  billing_interval, billing_interval_count, paused_at, source_created_at) values
      (v_t1, v_sgb, 'verifysubs', 's-1', 'cu-1', 'active', 20.00, 'GBP', 'month', 1, null, '2025-10-30 09:00 Europe/Amsterdam'),
      (v_t1, v_sgb, 'verifysubs', 's-2', 'cu-2', 'active', 20.00, 'GBP', 'month', 1, null, '2025-10-31 00:30 Europe/Amsterdam'),
      (v_t1, v_sgb, 'verifysubs', 's-3', 'cu-3', 'active', 20.00, 'GBP', 'month', 1, null, null),
      (v_t1, v_sgb, 'verifysubs', 's-4', 'cu-1', 'active', 20.00, 'GBP', 'month', 1, null, '2021-09-30 12:00 Europe/Amsterdam'),
      (v_t1, v_sgb, 'verifysubs', 's-5', 'cu-4', 'paused', 20.00, 'GBP', 'month', 1, now(), '2024-01-01 12:00 Europe/Amsterdam'),
      (v_t1, v_sgb, 'verifysubs', 's-6', 'cu-5', 'canceled', 20.00, 'GBP', 'month', 1, null, '2024-01-01 12:00 Europe/Amsterdam'),
      (v_t1, v_sgb, 'verifysubs', 's-7', 'cu-1', 'failed', 20.00, 'GBP', 'month', 1, null, '2025-06-15 12:00 Europe/Amsterdam'),
      (v_t1, v_snl, 'verifysubs', 'n-1', 'ncu-1', 'active', 30.00, 'EUR', 'month', 1, null, '2024-04-30 12:00 Europe/Amsterdam');
    insert into cma.subscription_event (tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type, occurred_at,
                                        cycle_index, attempt, reason_code, status_from, status_to) values
      (v_t1, v_sgb, 'verifysubs', 'e-1', 's-1', 'renew_failed', '2026-10-28 07:00 Europe/Amsterdam', 3, 1, null, null, null),
      (v_t1, v_sgb, 'verifysubs', 'e-2', 's-1', 'renew_failed', '2026-10-30 07:00 Europe/Amsterdam', 3, 2, null, null, null),
      (v_t1, v_sgb, 'verifysubs', 'e-3', 's-2', 'renew_failed', '2026-10-20 07:00 Europe/Amsterdam', 4, 1, null, null, null),
      (v_t1, v_sgb, 'verifysubs', 'e-4', 's-2', 'renewed', '2026-10-22 07:00 Europe/Amsterdam', 4, null, null, null, null),
      (v_t1, v_sgb, 'verifysubs', 'e-5', 's-4', 'renewed', '2026-10-30 09:00 Europe/Amsterdam', 2, null, null, null, null),
      (v_t1, v_snl, 'verifysubs', 'e-6', 'n-1', 'renew_failed', '2026-10-29 07:00 Europe/Amsterdam', null, 1, null, null, null);
    -- the register: two models, devices on every subscription, one on an id no subscription has, two without a reference,
    -- an NL device on n-1 and one on s-1's id (a GB subscription: not found in NL)
    insert into cma.device_model (tenant_id, key, name, sort_order) values (v_t1, 'm1', 'M1', 10), (v_t1, 'm2', 'M2', 20);
    insert into cma.device_status (tenant_id, key, name, is_in_field, is_in_stock, is_tracked) values
      (v_t1, 'field', 'Field', true, false, true), (v_t1, 'stock', 'Stock', false, true, true);
    insert into cma.device (tenant_id, connection_id, source_system, source_id, serial, model_key, market, device_status_key, subscription_ref)
    select v_t1, v_reg, 'verifyregister', x.rec, 'SN-' || x.rec, x.model, x.market, x.st, x.ref
    from (values ('d-1', 'm1', 'GB', 'field', 's-1'), ('d-2', 'm2', 'GB', 'field', 's-1'), ('d-3', 'm1', 'GB', 'stock', 's-1'),
                 ('d-4', 'm2', 'GB', 'field', 's-2'), ('d-5', 'm1', 'GB', 'field', 's-3'), ('d-6', 'm1', 'GB', 'field', 's-4'),
                 ('d-7', 'm2', 'GB', 'field', 's-4'), ('d-8', 'm1', 'GB', 'field', 's-5'), ('d-9', 'm2', 'GB', 'field', 's-6'),
                 ('d-10', 'm1', 'GB', 'field', 'nope'), ('d-11', 'm2', 'GB', 'field', null), ('d-12', 'm1', 'GB', 'stock', null),
                 ('d-13', 'm1', 'GB', 'field', 's-7'), ('nd-1', 'm2', 'NL', 'field', 'n-1'), ('nd-2', 'm1', 'NL', 'field', 's-1')) as x(rec, model, market, st, ref);
    -- tenant two: a market and a subscription of its own, no source set up
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency, sort_order) values (v_t2, 'GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', 10);
    v_today := cma.tenant_today_of(v_t1);

    -- A1. the payment state of given subscriptions
    select array_agg(x.id order by x.source_id) into v_ids from cma.subscription x where x.tenant_id = v_t1;
    select array_agg(x.id order by x.source_id) into v_few from cma.subscription x where x.tenant_id = v_t1 and x.source_id in ('s-1', 's-5', 's-7', 'n-1');
    v_other := array[gen_random_uuid()];
    v_bad := '';
    if pg_temp.v0008zz_ps((select jsonb_agg(to_jsonb(p)) from cma.subscription_payment_state_of(v_t1, v_ids) p))
       is distinct from pg_temp.v0008zz_ps((select jsonb_agg(to_jsonb(p)) from cma.subscription_payment_state_of(v_t1) p)) then v_bad := v_bad || 'all; '; end if;
    if pg_temp.v0008zz_ps((select jsonb_agg(to_jsonb(p)) from cma.subscription_payment_state_of(v_t1, v_few) p))
       is distinct from pg_temp.v0008zz_ps((select jsonb_agg(to_jsonb(p)) from cma.subscription_payment_state_of(v_t1) p where p.subscription_id = any (v_few))) then v_bad := v_bad || 'a few; '; end if;
    select count(*) into v_n from cma.subscription_payment_state_of(v_t1, '{}'::uuid[]);
    if v_n <> 0 then v_bad := v_bad || 'empty ' || v_n || '; '; end if;
    select count(*) into v_n from cma.subscription_payment_state_of(v_t2, v_ids);
    if v_n <> 0 then v_bad := v_bad || 'another tenant''s ' || v_n || '; '; end if;
    select count(*) into v_n from cma.subscription_payment_state_of(v_t1, v_other);
    if v_n <> 0 then v_bad := v_bad || 'unknown ' || v_n || '; '; end if;
    select count(*) into v_n from cma.subscription_payment_state_of(v_t1, null::uuid[]);
    if v_n <> 0 then v_bad := v_bad || 'no list ' || v_n || '; '; end if;
    select string_agg(p.source_id || ' ' || p.payment_state, ', ' order by p.source_id) into v_txt from cma.subscription_payment_state_of(v_t1, v_few) p;
    v_rows := v_rows || array['11', 'A1 the payment state of given subscriptions is the one-argument function''s rows for them; none for an empty list, another tenant''s ids or no list',
      case when v_bad = '' and v_txt = 'n-1 in_retry, s-1 in_retry, s-5 paused, s-7 failed' and not v_provoke then 'ok' else 'FAIL' end, coalesce(nullif(v_bad, ''), v_txt)];

    -- A2. one source's set-up
    v_bad := '';
    foreach k in array array['commerce', 'subscriptions', 'assets', 'crm', 'reviews'] loop
      if cma.flash_source_set_up_of(v_t1, k) is distinct from (pg_temp.v0008zz_sources_0008zn(v_t1) -> k ->> 'set_up')::boolean
         or cma.flash_source_set_up_of(v_t2, k) is distinct from (pg_temp.v0008zz_sources_0008zn(v_t2) -> k ->> 'set_up')::boolean then
        v_bad := v_bad || k || '; ';
      end if;
    end loop;
    v_txt := (select string_agg(k2 || ' ' || coalesce(cma.flash_source_set_up_of(v_t1, k2)::text, 'null') || '/' || coalesce(cma.flash_source_set_up_of(v_t2, k2)::text, 'null'), ', ')
              from unnest(array['commerce', 'subscriptions', 'assets', 'crm', 'reviews', 'nope']) k2);
    v_rows := v_rows || array['12', 'A2 one source''s set-up is 0008zn''s for every source, in a tenant with its sources set up and in one without; null for no source',
      case when v_bad = '' and v_txt = 'commerce true/false, subscriptions true/false, assets true/false, crm true/false, reviews false/false, nope null/null'
                and not v_provoke then 'ok' else 'FAIL' end, coalesce(nullif(v_bad, ''), v_txt)];

    -- A3. cma.flash_sources_of
    v_rows := v_rows || array['13', 'A3 cma.flash_sources_of is 0008zn''s answer in both tenants',
      case when cma.flash_sources_of(v_t1) = pg_temp.v0008zz_sources_0008zn(v_t1) and cma.flash_sources_of(v_t2) = pg_temp.v0008zz_sources_0008zn(v_t2)
                and not v_provoke then 'ok' else 'FAIL' end, left(cma.flash_sources_of(v_t1)::text, 300)];

    -- A4. the installed base's list on a grid of filters, sorts, directions and pages
    v_bad := ''; v_n := 0;
    foreach f in array array['{}', '{"market": "GB"}', '{"market": "NL"}', '{"model": "m2"}', '{"link": "linked"}', '{"status": "stock"}',
                             '{"subscription_status": "active"}', '{"measure": "in_field"}', '{"measure": "in_field_on_holding"}',
                             '{"measure": "components_past_due", "market": "GB"}']::jsonb[] loop
      foreach s in array array['serial', 'model', 'status', 'next_due_on'] loop
        foreach d in array array[false, true] loop
          foreach pg slice 1 in array array[[500, 0], [3, 0], [3, 3], [5, 100]] loop
            continue when s in ('model', 'status') and pg[1] <> 500;
            v_new := cma.flash_rows_of(v_t1, 'installed_base', f, s, d, pg[1], pg[2], null, null);
            v_old := pg_temp.v0008zz_rows_of_0008zu(v_t1, 'installed_base', f, s, d, pg[1], pg[2], null, null);
            v_n := v_n + 1;
            if v_new is distinct from v_old then v_bad := v_bad || f::text || ' ' || s || ' ' || d || ' ' || pg[1] || '/' || pg[2] || '; '; end if;
          end loop;
        end loop;
      end loop;
    end loop;
    v_rows := v_rows || array['14', 'A4 the installed base''s list is 0008zu''s for every filter, sort, direction and page of a grid',
      case when v_bad = '' and v_n = 200 and not v_provoke then 'ok' else 'FAIL' end, coalesce(nullif(left(v_bad, 600), ''), v_n || ' lists equal')];

    -- A5. the page carries every payment state
    v_new := cma.flash_rows_of(v_t1, 'installed_base', '{}', 'serial', false, 500, 0, null, null);
    select string_agg((x ->> 'serial') || ' ' || coalesce(x ->> 'subscription_payment_state', '-'), ', ' order by x ->> 'serial') into v_txt
    from jsonb_array_elements(v_new -> 'rows') x;
    v_rows := v_rows || array['15', 'A5 the page carries every payment state the fixture holds (in retry, paid, paused, canceled, failed, none)',
      case when v_txt = 'SN-d-1 in_retry, SN-d-10 -, SN-d-11 -, SN-d-12 -, SN-d-13 failed, SN-d-2 in_retry, SN-d-3 in_retry, SN-d-4 paid, SN-d-5 paid, '
                        || 'SN-d-6 paid, SN-d-7 paid, SN-d-8 paused, SN-d-9 canceled, SN-nd-1 in_retry, SN-nd-2 -'
                and (v_new ->> 'total') = '15' and not v_provoke then 'ok' else 'FAIL' end, v_txt];

    -- A6. every other overview's first page
    v_bad := '';
    for o in select x.key, x.kind from cma.flash_overviews() x where x.key <> 'installed_base' order by x.sort_order loop
      v_new := cma.flash_rows_of(v_t1, o.key, '{}', (select x.sorts[1] from cma.flash_overviews() x where x.key = o.key), false, 500, 0,
                                 case when o.kind = 'flow' then v_today - 40 end, case when o.kind = 'flow' then v_today end);
      v_old := pg_temp.v0008zz_rows_of_0008zu(v_t1, o.key, '{}', (select x.sorts[1] from cma.flash_overviews() x where x.key = o.key), false, 500, 0,
                                              case when o.kind = 'flow' then v_today - 40 end, case when o.kind = 'flow' then v_today end);
      if v_new is distinct from v_old then v_bad := v_bad || o.key || '; '; end if;
    end loop;
    v_rows := v_rows || array['16', 'A6 every other overview''s first page is 0008zu''s',
      case when v_bad = '' and not v_provoke then 'ok' else 'FAIL' end, nullif(v_bad, '')];

    -- A7. cma.flash_rows as the tenant's reader
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_reader::text, true);
    v_bad := '';
    if cma.flash_rows('installed_base') is distinct from pg_temp.v0008zz_rows_0008zn('installed_base') then v_bad := v_bad || 'installed_base; '; end if;
    if cma.flash_rows('installed_base', '{"market": "GB"}', 'next_due_on', true, 4, 2) is distinct from pg_temp.v0008zz_rows_0008zn('installed_base', '{"market": "GB"}', 'next_due_on', true, 4, 2) then
      v_bad := v_bad || 'GB; ';
    end if;
    if cma.flash_rows('reviews') is distinct from pg_temp.v0008zz_rows_0008zn('reviews') then v_bad := v_bad || 'reviews; '; end if;
    v_txt := (cma.flash_rows('installed_base') ->> 'set_up') || '/' || (cma.flash_rows('reviews') ->> 'set_up');
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['17', 'A7 cma.flash_rows (as the reader) is 0008zn''s answer: the installed base, a market, a source not set up',
      case when v_bad = '' and v_txt = 'true/false' and not v_provoke then 'ok' else 'FAIL' end, coalesce(nullif(v_bad, ''), v_txt)];

    -- A8. a tenant whose register is not set up
    v_rows := v_rows || array['18', 'A8 a tenant whose register is not set up: an empty list, as before',
      case when cma.flash_rows_of(v_t2, 'installed_base', '{}', 'serial', false, 500, 0, null, null) = '{"total": 0, "rows": []}'::jsonb
                and pg_temp.v0008zz_rows_of_0008zu(v_t2, 'installed_base', '{}', 'serial', false, 500, 0, null, null) = '{"total": 0, "rows": []}'::jsonb
                and not v_provoke then 'ok' else 'FAIL' end, cma.flash_rows_of(v_t2, 'installed_base', '{}', 'serial', false, 500, 0, null, null)::text];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['29', 'A the block ran to the end', 'FAIL', sqlstate || ' ' || sqlerrm];
  end;
  perform set_config('role', 'cma_owner', true);
  insert into verify_0008zz select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if not exists (select 1 from verify_0008zz where ord between 11 and 29) then
    insert into verify_0008zz values (29, 'A the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- D. Every active tenant, read only (as the owner, the tenant named on every read)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  t record; k text; f jsonb; s text; d boolean; pg integer[];
  v_ids uuid[]; v_first uuid[]; v_markets text[]; v_models text[];
  v_bad1 text := ''; v_bad2 text := ''; v_bad3 text := '';
  v_tenants integer := 0; v_assets integer := 0; v_lists integer := 0;
begin
  for t in select x.id, x.slug from cma.tenant x where x.status = 'active' order by x.slug collate "C" loop
    v_tenants := v_tenants + 1;
    -- D1. each source's set-up and the sources
    foreach k in array array['commerce', 'subscriptions', 'assets', 'crm', 'reviews'] loop
      if cma.flash_source_set_up_of(t.id, k) is distinct from (pg_temp.v0008zz_sources_0008zn(t.id) -> k ->> 'set_up')::boolean then
        v_bad1 := v_bad1 || t.slug || ' ' || k || '; ';
      end if;
    end loop;
    if cma.flash_sources_of(t.id) is distinct from pg_temp.v0008zz_sources_0008zn(t.id) then v_bad1 := v_bad1 || t.slug || ' sources; '; end if;
    -- D2. the payment state of all its subscriptions, and of its first 500
    select array_agg(x.id order by x.id) into v_ids from cma.subscription x where x.tenant_id = t.id;
    v_first := v_ids[1:500];
    if pg_temp.v0008zz_ps((select jsonb_agg(to_jsonb(p)) from cma.subscription_payment_state_of(t.id, coalesce(v_ids, '{}')) p))
       is distinct from pg_temp.v0008zz_ps((select jsonb_agg(to_jsonb(p)) from cma.subscription_payment_state_of(t.id) p)) then
      v_bad2 := v_bad2 || t.slug || ' all; ';
    end if;
    if pg_temp.v0008zz_ps((select jsonb_agg(to_jsonb(p)) from cma.subscription_payment_state_of(t.id, coalesce(v_first, '{}')) p))
       is distinct from pg_temp.v0008zz_ps((select jsonb_agg(to_jsonb(p)) from cma.subscription_payment_state_of(t.id) p where p.subscription_id = any (v_first))) then
      v_bad2 := v_bad2 || t.slug || ' first 500; ';
    end if;
    -- D3. the installed base's list, where the register is set up
    if coalesce(cma.flash_source_set_up_of(t.id, 'assets'), false) then
      v_assets := v_assets + 1;
      select array_agg(distinct x.market order by x.market) into v_markets from cma.device x where x.tenant_id = t.id and x.source_deleted_at is null and x.market is not null;
      select array_agg(distinct x.model_key order by x.model_key) into v_models from cma.device x where x.tenant_id = t.id and x.source_deleted_at is null and x.model_key is not null;
      foreach f in array array['{}'::jsonb, '{"measure": "in_field"}'::jsonb, '{"measure": "components_past_due"}'::jsonb]
                         || case when v_markets is not null then array[jsonb_build_object('market', v_markets[1])] else '{}'::jsonb[] end
                         || case when v_models is not null then array[jsonb_build_object('model', v_models[1])] else '{}'::jsonb[] end loop
        foreach s in array array['serial', 'next_due_on'] loop
          d := s = 'next_due_on';
          foreach pg slice 1 in array array[[500, 0], [100, 500]] loop
            v_lists := v_lists + 1;
            if cma.flash_rows_of(t.id, 'installed_base', f, s, d, pg[1], pg[2], null, null)
               is distinct from pg_temp.v0008zz_rows_of_0008zu(t.id, 'installed_base', f, s, d, pg[1], pg[2], null, null) then
              v_bad3 := v_bad3 || t.slug || ' ' || f::text || ' ' || s || ' ' || pg[1] || '/' || pg[2] || '; ';
            end if;
          end loop;
        end loop;
      end loop;
    end if;
  end loop;
  insert into verify_0008zz values
    (31, 'D1 every tenant: each source''s set-up and cma.flash_sources_of as 0008zn''s',
     case when v_bad1 = '' and not v_provoke then 'ok' else 'FAIL' end, case when v_bad1 = '' then v_tenants || ' tenant(s)' else left(v_bad1, 600) end),
    (32, 'D2 every tenant: the payment state of all its subscriptions, and of its first 500, is the one-argument function''s',
     case when v_bad2 = '' and not v_provoke then 'ok' else 'FAIL' end, case when v_bad2 = '' then v_tenants || ' tenant(s)' else left(v_bad2, 600) end),
    (33, 'D3 every tenant with an asset register: the installed base''s list is 0008zu''s for a grid of filters, sorts and pages',
     case when v_provoke then 'FAIL' when v_assets = 0 then 'skip' when v_bad3 = '' then 'ok' else 'FAIL' end,
     case when v_assets = 0 then 'no tenant with an asset register set up' when v_bad3 = '' then v_assets || ' tenant(s), ' || v_lists || ' lists equal'
          else left(v_bad3, 600) end);
end
$$;

-- The helpers are dropped first, so the verdict is the last thing the script prints
drop function if exists pg_temp.v0008zz_ps(jsonb);
drop function if exists pg_temp.v0008zz_rows_0008zn(text,jsonb,text,boolean,integer,integer,date,date,date);
drop function if exists pg_temp.v0008zz_rows_of_0008zu(uuid,text,jsonb,text,boolean,integer,integer,date,date);
drop function if exists pg_temp.v0008zz_sources_0008zn(uuid);

-- Verdict: one row per check, then the verdict: no FAIL, a skip only where the check says why
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008zz
      union all
      select 99, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from verify_0008zz where result not in ('ok', 'skip')) then 'FAIL'
                  when (select count(*) from verify_0008zz where result = 'ok') >= 12 then '0008zz verified'
                  else 'FAIL' end,
             format('149_verify_installed_base_list: %s ok, %s FAIL, %s skip', (select count(*) from verify_0008zz where result = 'ok'),
                    (select count(*) from verify_0008zz where result not in ('ok', 'skip')),
                    (select count(*) from verify_0008zz where result = 'skip'))) x
order by ord;
drop table if exists pg_temp.verify_0008zz;
reset role;
