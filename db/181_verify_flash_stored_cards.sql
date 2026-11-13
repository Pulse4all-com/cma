-- =============================================================================================
-- 181_verify_flash_stored_cards.sql: verifies addition 0009p, Flash's landing reads its cards from the stored current takes
-- =============================================================================================
-- Universal: no seed is assumed, so it runs in dev and in prod. Block S checks the addition, the grants and the
-- setting's default. Block A works on two throwaway tenants inside a subtransaction that is always rolled back (invented
-- takes of one overview, synthetic people at example.invalid): the card's states, the permission, the isolation. Block D
-- reads every active tenant's own data and leaves nothing behind (its refresh of the takes runs in a subtransaction that
-- is rolled back): cma.flash_compute_of against its previous definition, kept below as pg_temp.v0009p_compute_0008zy
-- (146), row for row for every overview, now, over today and over the last 31 days, and as of yesterday; and the stored
-- cards against cma.flash_headline's live answer for every market, right after a refresh. Block E times the stored
-- cards' read. Every check writes one row (PASS, FAIL, info or skip) and the last row is the verdict, because Cloud SQL
-- Studio shows no notices. Run as your own IAM login after 180_flash_stored_cards.sql; then the verifies 180's header
-- names (123 and 159 edited by 0009p; 137, 139, 143, 147, 161 and 173 unchanged).
-- Expected verdict: "PASS | 181_verify_flash_stored_cards: <n> PASS, 0 FAIL, <i> info, <k> skip".
--   S1  the addition 0009p is recorded, after 0009o
--   S2  cma.flash_cards_now the application's only, in the caller's rights; cma.flash_compute_of keeps JIT off and its grants
--   S3  flash.current_overviews defaults to every stock overview but data quality
--   A1  a tenant without a take: every card is marked not stored (the page reads it live), eleven cards in the landing's order
--   A2  a readable take is answered as stored with its Refreshed at; one older than three times
--       flash.current_refresh_minutes, one of another definition and an overview left out of the tenant's setting are not
--   A3  an agent is refused (CMA06), a market out of its form too (CMA04); the other tenant sees no card of this one
--   D1  every tenant: cma.flash_compute_of equals 0008zy's definition, row for row, for every overview and period
--   D2  every tenant with a scheduler and a report reader: after a refresh every stock overview that is set up is a stored
--       card, and each stored card equals cma.flash_headline's live answer, for no market and for each market
--   E1  every tenant with a report reader: the stored cards' read within the stored budget (verify.max_stored_ms, 50)
-- Provoke: verify.provoke below. 'true': every check reads FAIL and the verdict says PROVOKED, NOT A PASS. A check's id:
-- that check alone compares with a deliberate difference.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);                 -- 'true' for every check, or one check's id such as 'D2'
select set_config('verify.max_stored_ms', '50', false);              -- a read answered from stored rows (131's class agent)

drop table if exists pg_temp.verify_0009p;
create temporary table verify_0009p (ord integer, check_name text, result text, detail text);
grant select, insert on pg_temp.verify_0009p to cma_app;

create or replace function pg_temp.v0009p_p(p_id text)
returns boolean
language sql stable
as $$
  select current_setting('verify.provoke') in ('true', p_id)
$$;

-- One check's row: PASS when what was found equals what is expected; provoked, the expectation carries a deliberate difference
create or replace function pg_temp.v0009p_row(p_ord integer, p_id text, p_name text, p_found text, p_expected text)
returns void
language plpgsql
as $$
declare
  v_exp text := case when pg_temp.v0009p_p(p_id) then coalesce(p_expected, '') || ' [provoked: a deliberate difference]' else p_expected end;
begin
  insert into pg_temp.verify_0009p values (p_ord, p_id || ' ' || p_name,
    case when p_found is not distinct from v_exp then 'PASS' else 'FAIL' end,
    case when p_found is not distinct from v_exp then left(coalesce(p_found, 'null'), 300)
         else left('found ' || coalesce(p_found, 'null') || ' | expected ' || coalesce(v_exp, 'null'), 1500) end);
end
$$;

create or replace function pg_temp.v0009p_code(p_sql text)
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

-- The previous definition of cma.flash_compute_of (0008zy, 146_installed_base_models.sql), kept here to compare with
create or replace function pg_temp.v0009p_compute_0008zy(p_tenant_id uuid, p_overview text, p_from date default null, p_to date default null,
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
grant execute on function pg_temp.v0009p_compute_0008zy(uuid, text, date, date, date) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- S. The addition, the grants, the setting
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_bad text := '';
begin
  perform pg_temp.v0009p_row(1, 'S1', 'the addition 0009p is recorded, after 0009o',
    (select string_agg(m.version, ',' order by m.version collate "C") from cma.schema_migration m where m.version in ('0009o', '0009p')), '0009o,0009p');
  select v_bad || case when p.oid is null then 'cma.flash_cards_now(text) missing; '
                       else case when p.prosecdef then 'cma.flash_cards_now is security definer; ' else '' end
                            || case when pg_get_userbyid(p.proowner) <> 'cma_owner' then 'cma.flash_cards_now not owned by cma_owner; ' else '' end
                            || case when has_function_privilege('public', p.oid, 'execute') then 'cma.flash_cards_now executable by public; ' else '' end
                            || case when not has_function_privilege('cma_app', p.oid, 'execute') then 'cma.flash_cards_now not executable by cma_app; ' else '' end
                            || case when has_function_privilege('cma_readonly', p.oid, 'execute') then 'cma.flash_cards_now executable by cma_readonly; ' else '' end end
  into v_bad from (select 1) one left join pg_proc p on p.oid = to_regprocedure('cma.flash_cards_now(text)');
  select v_bad || case when not ('jit=off' = any (coalesce(p.proconfig, '{}'))) then 'cma.flash_compute_of without jit off; ' else '' end
               || case when p.prosecdef then 'cma.flash_compute_of is security definer; ' else '' end
               || case when has_function_privilege('public', p.oid, 'execute') then 'cma.flash_compute_of executable by public; ' else '' end
               || case when not has_function_privilege('cma_app', p.oid, 'execute') then 'cma.flash_compute_of not executable by cma_app; ' else '' end
               || case when pg_get_functiondef(p.oid) like '%cma.flash_sources_of(p_tenant_id)%' then 'cma.flash_compute_of still asks cma.flash_sources_of; ' else '' end
  into v_bad from pg_proc p where p.oid = to_regprocedure('cma.flash_compute_of(uuid,text,date,date,date)');
  perform pg_temp.v0009p_row(2, 'S2', 'cma.flash_cards_now the application''s only, in the caller''s rights; cma.flash_compute_of with jit off, its grants, one source''s set-up', v_bad, '');
  perform pg_temp.v0009p_row(3, 'S3', 'flash.current_overviews defaults to every stock overview but data quality',
    (select s.default_value from cma.setting s where s.key = 'flash.current_overviews'), array_to_string(cma.flash_current_keys(), ','));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- A. Two throwaway tenants: the card's states, the permission, the isolation
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_t1 uuid; v_t2 uuid;
  v_analyst1 uuid; v_agent1 uuid; v_admin1 uuid; v_analyst2 uuid;
  v_ver text := cma.flash_definition_version('open_deals');
  j jsonb;
  v_txt text;
  v_rows text[] := '{}';
  i integer;
begin
  begin
    v_t1 := cma.create_tenant('verify-0009p-one', 'Verify 0009p one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0009p-two', 'Verify 0009p two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-analyst1@example.invalid', 'analyst1') returning id into v_analyst1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent1@example.invalid', 'agent1') returning id into v_agent1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-analyst2@example.invalid', 'analyst2') returning id into v_analyst2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select x.t, x.u, r.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_analyst1, 'analytics'), (v_t1, v_agent1, 'agent'), (v_t2, v_analyst2, 'analytics')) x(t, u, k)
    join cma.app_role r on r.tenant_id = x.t and r.key = x.k;

    -- the additions recorded in the last day (180, just before this script) moved a day back inside this rolled-back block,
    -- as 159 does: a take backdated by minutes below (A2's "due for a refresh") is then not older than the latest
    -- migration, which cma.flash_current_state_of calls outdated (159's A4 checks that rule itself). Without this the
    -- script failed A2 when run within minutes of 180
    update cma.schema_migration set applied_at = applied_at - interval '1 day' where applied_at > now() - interval '1 day';

    -- A1. no take: eleven cards in the landing's order, none stored
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_analyst1::text, true);
    j := cma.flash_cards_now();
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['10', 'A1', 'without a take every card is marked not stored and says whether its source is set up, in the landing''s order',
      format('%s cards, %s stored, order as the overviews %s, keys %s, set up: %s', jsonb_array_length(j -> 'cards'),
             (select count(*) from jsonb_array_elements(j -> 'cards') c where (c ->> 'stored')::boolean),
             ((select string_agg(c ->> 'overview', ',' order by o) from jsonb_array_elements(j -> 'cards') with ordinality q(c, o))
              = (select string_agg(x.key, ',' order by x.sort_order) from cma.flash_overviews() x))::text,
             (select string_agg(distinct k collate "C", ',' order by k collate "C") from jsonb_array_elements(j -> 'cards') c cross join jsonb_object_keys(c) k),
             -- a tenant with no source connected: only the overview without a source (data quality) is set up
             coalesce((select string_agg(c ->> 'overview', ',' order by (c ->> 'overview') collate "C") from jsonb_array_elements(j -> 'cards') c where (c ->> 'set_up')::boolean), 'none')),
      format('%s cards, 0 stored, order as the overviews true, keys overview,set_up,stored, set up: %s', (select count(*) from cma.flash_overviews()),
             coalesce((select string_agg(x.key, ',' order by x.key collate "C") from cma.flash_overviews() x where x.source is null), 'none'))];

    -- A2. an invented take of Open deals (the totals 5, the market NL 3): readable (fresh, or due for a refresh), it is the
    -- card, with its Refreshed at; too old, of another definition, or left out of the tenant's setting, it is not
    insert into cma.flash_current_take (tenant_id, overview, dims, measures, definition_version, computed_at)
    values (v_t1, 'open_deals', '{}'::jsonb, jsonb_build_object((select o.headline from cma.flash_overviews() o where o.key = 'open_deals'), 5), v_ver, now()),
           (v_t1, 'open_deals', '{"market": "NL"}'::jsonb, jsonb_build_object((select o.headline from cma.flash_overviews() o where o.key = 'open_deals'), 3), v_ver, now());
    perform set_config('role', 'cma_app', true);
    j := cma.flash_cards_now();
    v_txt := (select format('stored %s value %s set up %s refreshed now %s keys %s', c ->> 'stored', c ->> 'value', c ->> 'set_up', ((c ->> 'refreshed_at')::timestamptz = now())::text,
                            (select string_agg(k, ',' order by k collate "C") from jsonb_object_keys(c) k))
              from jsonb_array_elements(j -> 'cards') c where c ->> 'overview' = 'open_deals')
             || format(' | others stored %s', (select count(*) from jsonb_array_elements(j -> 'cards') c where (c ->> 'stored')::boolean and c ->> 'overview' <> 'open_deals'))
             || format(' | NL %s', (select c ->> 'value' from jsonb_array_elements(cma.flash_cards_now('NL') -> 'cards') c where c ->> 'overview' = 'open_deals'))
             || format(' | a market without a row %s', (select c ->> 'value' from jsonb_array_elements(cma.flash_cards_now('GB') -> 'cards') c where c ->> 'overview' = 'open_deals'));
    perform set_config('role', 'cma_owner', true);
    -- usable: older than flash.current_refresh_minutes (the job is due), not yet three times as old: still the card
    update cma.flash_current_take c set computed_at = now() - make_interval(mins => cma.setting_of(v_t1, 'flash.current_refresh_minutes')::integer + 1)
    where c.tenant_id = v_t1;
    perform set_config('role', 'cma_app', true);
    v_txt := v_txt || format(' | due for a refresh: stored %s', (select c ->> 'stored' from jsonb_array_elements(cma.flash_cards_now() -> 'cards') c where c ->> 'overview' = 'open_deals'));
    perform set_config('role', 'cma_owner', true);
    update cma.flash_current_take c set computed_at = now() - make_interval(mins => 3 * cma.setting_of(v_t1, 'flash.current_refresh_minutes')::integer + 1)
    where c.tenant_id = v_t1;
    perform set_config('role', 'cma_app', true);
    v_txt := v_txt || format(' | too old: stored %s', (select c ->> 'stored' from jsonb_array_elements(cma.flash_cards_now() -> 'cards') c where c ->> 'overview' = 'open_deals'));
    perform set_config('role', 'cma_owner', true);
    update cma.flash_current_take c set computed_at = now(), definition_version = '0' where c.tenant_id = v_t1;
    perform set_config('role', 'cma_app', true);
    v_txt := v_txt || format(' | another definition: stored %s', (select c ->> 'stored' from jsonb_array_elements(cma.flash_cards_now() -> 'cards') c where c ->> 'overview' = 'open_deals'));
    perform set_config('role', 'cma_owner', true);
    update cma.flash_current_take c set definition_version = v_ver where c.tenant_id = v_t1;
    insert into cma.tenant_setting (tenant_id, key, value) values (v_t1, 'flash.current_overviews', 'installed_base');
    -- the setting's change removed the tenant's takes (0009e); put the invented one back to show the setting alone decides
    insert into cma.flash_current_take (tenant_id, overview, dims, measures, definition_version, computed_at)
    select v_t1, 'open_deals', '{}'::jsonb, jsonb_build_object((select o.headline from cma.flash_overviews() o where o.key = 'open_deals'), 5), v_ver, now()
    where not exists (select 1 from cma.flash_current_take c where c.tenant_id = v_t1);
    perform set_config('role', 'cma_app', true);
    v_txt := v_txt || format(' | not in the setting: stored %s', (select c ->> 'stored' from jsonb_array_elements(cma.flash_cards_now() -> 'cards') c where c ->> 'overview' = 'open_deals'));
    perform set_config('role', 'cma_owner', true);
    delete from cma.tenant_setting s where s.tenant_id = v_t1 and s.key = 'flash.current_overviews';
    delete from cma.flash_current_take c where c.tenant_id = v_t1;
    insert into cma.flash_current_take (tenant_id, overview, dims, measures, definition_version, computed_at)
    values (v_t1, 'open_deals', '{}'::jsonb, jsonb_build_object((select o.headline from cma.flash_overviews() o where o.key = 'open_deals'), 5), v_ver, now());
    v_rows := v_rows || array['11', 'A2', 'a readable take is the card with its Refreshed at; too old, of another definition or left out of the setting it is not', v_txt,
      'stored true value 5 set up true refreshed now true keys definition_version,headline,market,overview,refreshed_at,set_up,split,stored,value | others stored 0 | NL 3 | a market without a row 0'
      || ' | due for a refresh: stored true | too old: stored false | another definition: stored false | not in the setting: stored false'];

    -- A3. the permission, the parameter, the other tenant
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_agent1::text, true);
    v_txt := 'agent ' || pg_temp.v0009p_code('select cma.flash_cards_now()');
    perform set_config('app.user_id', v_analyst1::text, true);
    v_txt := v_txt || ' | market nl ' || pg_temp.v0009p_code($q$select cma.flash_cards_now('nl')$q$)
             || format(' | one sees %s stored', (select count(*) from jsonb_array_elements(cma.flash_cards_now() -> 'cards') c where (c ->> 'stored')::boolean));
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_analyst2::text, true);
    v_txt := v_txt || format(' | two sees %s stored and %s take rows', (select count(*) from jsonb_array_elements(cma.flash_cards_now() -> 'cards') c where (c ->> 'stored')::boolean),
                             (select count(*) from cma.flash_current_take));
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['12', 'A3', 'an agent is refused, a market out of its form too; the other tenant sees no card of this one', v_txt,
      'agent CMA06 | market nl CMA04 | one sees 1 stored | two sees 0 stored and 0 take rows'];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
  end;
  perform set_config('role', 'cma_owner', true);
  perform set_config('app.tenant_id', '', true);
  perform set_config('app.user_id', '', true);
  -- the rows, written after the rollback (what the step wrote is gone with it)
  for i in 1 .. coalesce(array_length(v_rows, 1), 0) / 5 loop
    perform pg_temp.v0009p_row(v_rows[5 * i - 4]::integer, v_rows[5 * i - 3], v_rows[5 * i - 2], v_rows[5 * i - 1], v_rows[5 * i]);
  end loop;
  if coalesce(array_length(v_rows, 1), 0) <> 15 then
    perform pg_temp.v0009p_row(19, 'A', 'the throwaway tenants'' checks ran', (coalesce(array_length(v_rows, 1), 0) / 5)::text, '3');
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- D. Every active tenant's own data: the computation as before, the stored cards as the live headlines
-- ---------------------------------------------------------------------------------------------
do $$
declare
  t record; o record; m record;
  v_today date;
  v_diff integer; v_cmp integer; v_bad text;
  v_sched uuid; v_reader uuid;
  v_stored integer; v_equal integer; v_expected integer; v_cards integer; v_live integer; v_live_equal integer;
  v_any1 boolean := false; v_any2 boolean := false;
  j jsonb; k text;
begin
  for t in select x.id, x.slug from cma.tenant x where x.status = 'active' order by x.slug collate "C" loop
    perform set_config('app.tenant_id', t.id::text, true);
    v_today := cma.tenant_today_of(t.id);
    -- D1. the computation, row for row against 0008zy's
    v_diff := 0; v_cmp := 0; v_bad := '';
    for o in select x.key, x.kind from cma.flash_overviews() x order by x.sort_order loop
      for m in select * from (values (null::date, null::date, null::date), (v_today, v_today, null), (v_today - 30, v_today, null), (null, null, v_today - 1)) p(f, u, d)
               where (o.kind = 'flow' and p.f is not null) or (o.kind = 'stock' and p.f is null) loop
        v_cmp := v_cmp + 1;
        select count(*) into v_cards from (
          (select n.dims, n.measures from cma.flash_compute_of(t.id, o.key, m.f, m.u, m.d) n
           except select p.dims, p.measures from pg_temp.v0009p_compute_0008zy(t.id, o.key, m.f, m.u, m.d) p where not (pg_temp.v0009p_p('D1') and p.dims = '{}'::jsonb))
          union all
          (select p.dims, p.measures from pg_temp.v0009p_compute_0008zy(t.id, o.key, m.f, m.u, m.d) p where not (pg_temp.v0009p_p('D1') and p.dims = '{}'::jsonb)
           except select n.dims, n.measures from cma.flash_compute_of(t.id, o.key, m.f, m.u, m.d) n)) x;
        if v_cards > 0 then v_diff := v_diff + 1; v_bad := v_bad || o.key || ' '; end if;
      end loop;
    end loop;
    v_any1 := true;
    insert into pg_temp.verify_0009p values (100, 'D1 ' || t.slug || ': cma.flash_compute_of equals 0008zy''s definition, row for row',
      case when v_diff = 0 and not pg_temp.v0009p_p('D1') then 'PASS' when pg_temp.v0009p_p('D1') and v_diff > 0 then 'FAIL' when v_diff = 0 then 'FAIL' else 'FAIL' end,
      format('%s computations compared, %s differ %s', v_cmp, v_diff, v_bad));

    -- D2. the stored cards after a refresh, against the live headlines; nothing stays (rolled back)
    select u.id into v_sched from cma.app_user u where u.tenant_id = t.id and u.kind = 'system' and u.email = 'scheduler@system.invalid' and u.status = 'active';
    select u.id into v_reader from cma.app_user u
    where u.tenant_id = t.id and u.status = 'active' and u.kind <> 'system'
      and exists (select 1 from cma.user_role ur join cma.role_permission rp on rp.tenant_id = ur.tenant_id and rp.role_id = ur.role_id
                  where ur.tenant_id = u.tenant_id and ur.user_id = u.id and rp.permission_key in ('reports.view', 'performance.team'))
    order by u.id limit 1;
    if v_sched is null or v_reader is null then
      insert into pg_temp.verify_0009p values (110, 'D2 ' || t.slug || ': the stored cards equal the live headlines',
        case when pg_temp.v0009p_p('D2') then 'FAIL' else 'skip' end, 'no active scheduler user or no person holding reports.view or performance.team');
      continue;
    end if;
    v_any2 := true;
    begin
      -- every take taken again now (forced, by the owner's writer under the scheduler's permission), then read as the
      -- application's report reader in the same transaction: the same data, so the stored card and the live headline agree
      perform set_config('app.user_id', v_sched::text, true);
      foreach k in array cma.flash_current_overviews_of(t.id) loop
        perform cma.flash_current_refresh_of(t.id, k, true);
      end loop;
      perform set_config('role', 'cma_app', true);
      perform set_config('app.user_id', v_reader::text, true);
      v_stored := 0; v_equal := 0; v_cards := 0; v_live := 0; v_live_equal := 0;
      select count(*) into v_expected from unnest(cma.flash_current_overviews_of(t.id)) x(key)
      where coalesce(cma.flash_source_set_up_of(t.id, (select o2.source from cma.flash_overviews() o2 where o2.key = x.key)), false);
      for m in select null::text as code union all select mk.code from cma.market mk where mk.tenant_id = t.id and mk.status = 'active' loop
        j := cma.flash_cards_now(m.code);
        for o in select c from jsonb_array_elements(j -> 'cards') c where (c ->> 'stored')::boolean loop
          v_cards := v_cards + 1;
          if m.code is null then v_stored := v_stored + 1; end if;
          if (o.c - 'stored' - 'refreshed_at') = (cma.flash_headline(o.c ->> 'overview', m.code) - 'as_of' - 'from' - 'to')
             and not pg_temp.v0009p_p('D2') then
            v_equal := v_equal + 1;
          end if;
        end loop;
        -- a card not stored says whether its source is set up, as its live headline does (a flow's over the tenant's today)
        if m.code is null then
          for o in select c, x.kind from jsonb_array_elements(j -> 'cards') c join cma.flash_overviews() x on x.key = c ->> 'overview'
                   where not (c ->> 'stored')::boolean loop
            v_live := v_live + 1;
            if (o.c ->> 'set_up')::boolean = (case when o.kind = 'flow'
                 then cma.flash_headline(o.c ->> 'overview', null, cma.tenant_today_of(t.id), cma.tenant_today_of(t.id))
                 else cma.flash_headline(o.c ->> 'overview', null) end ->> 'set_up')::boolean
               and not pg_temp.v0009p_p('D2') then
              v_live_equal := v_live_equal + 1;
            end if;
          end loop;
        end if;
      end loop;
      raise exception using errcode = 'CMAOK', message = 'rollback';
    exception
      when sqlstate 'CMAOK' then null;
    end;
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.user_id', '', true);
    insert into pg_temp.verify_0009p values (110, 'D2 ' || t.slug || ': after a refresh every set-up stock overview of the setting is a stored card, each equal to the live headline',
      case when pg_temp.v0009p_p('D2') then 'FAIL'
           when v_stored = v_expected and v_equal = v_cards and v_live_equal = v_live then case when v_cards = 0 then 'skip' else 'PASS' end
           else 'FAIL' end,
      format('%s stored cards of %s expected; %s of %s cards equal the live headline over no market and each market; %s of %s cards not stored say their source''s set-up as the live headline does%s',
             v_stored, v_expected, v_equal, v_cards, v_live_equal, v_live, case when v_cards = 0 then ' (no stock overview of the setting is set up: nothing stored to compare)' else '' end));
  end loop;
  perform set_config('app.tenant_id', '', true);
  if not v_any1 then
    insert into pg_temp.verify_0009p values (100, 'D1 cma.flash_compute_of equals 0008zy''s definition', case when current_setting('verify.provoke') in ('true', 'D1') then 'FAIL' else 'skip' end, 'no active tenant');
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- E. The stored cards' read, timed as the application
-- ---------------------------------------------------------------------------------------------
do $$
declare
  t record;
  v_reader uuid;
  v_t0 timestamptz; v_ms numeric; v_best numeric;
  j jsonb;
begin
  for t in select x.id, x.slug from cma.tenant x where x.status = 'active' order by x.slug collate "C" loop
    select u.id into v_reader from cma.app_user u
    where u.tenant_id = t.id and u.status = 'active' and u.kind <> 'system'
      and exists (select 1 from cma.user_role ur join cma.role_permission rp on rp.tenant_id = ur.tenant_id and rp.role_id = ur.role_id
                  where ur.tenant_id = u.tenant_id and ur.user_id = u.id and rp.permission_key in ('reports.view', 'performance.team'))
    order by u.id limit 1;
    if v_reader is null then
      insert into pg_temp.verify_0009p values (200, 'E1 ' || t.slug || ': the stored cards'' read within the stored budget',
        case when pg_temp.v0009p_p('E1') then 'FAIL' else 'skip' end, 'no person holding reports.view or performance.team');
      continue;
    end if;
    perform set_config('app.tenant_id', t.id::text, true);
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_reader::text, true);
    v_best := null;
    for i in 1 .. 9 loop
      v_t0 := clock_timestamp();
      j := cma.flash_cards_now();
      v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
      if i > 6 then v_best := least(coalesce(v_best, v_ms), v_ms); end if;
    end loop;
    perform set_config('role', 'cma_owner', true);
    insert into pg_temp.verify_0009p values (200, 'E1 ' || t.slug || ': the stored cards'' read within the stored budget',
      case when v_best <= case when pg_temp.v0009p_p('E1') then 0 else current_setting('verify.max_stored_ms')::numeric end then 'PASS' else 'FAIL' end,
      format('%s ms (best of 3, after six calls) against %s ms; %s cards stored now', v_best, case when pg_temp.v0009p_p('E1') then '0' else current_setting('verify.max_stored_ms') end,
             (select count(*) from jsonb_array_elements(j -> 'cards') c where (c ->> 'stored')::boolean)));
  end loop;
  perform set_config('app.tenant_id', '', true);
  perform set_config('app.user_id', '', true);
end
$$;

drop function if exists pg_temp.v0009p_compute_0008zy(uuid, text, date, date, date);

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0009p
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke') <> 'false' then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0009p where result = 'FAIL') then 'FAIL'
                  when not exists (select 1 from pg_temp.verify_0009p where result = 'PASS') then 'FAIL'
                  else 'PASS' end,
             format('181_verify_flash_stored_cards: %s PASS, %s FAIL, %s info, %s skip',
                    (select count(*) from pg_temp.verify_0009p where result = 'PASS'), (select count(*) from pg_temp.verify_0009p where result = 'FAIL'),
                    (select count(*) from pg_temp.verify_0009p where result = 'info'), (select count(*) from pg_temp.verify_0009p where result = 'skip'))) x
order by ord, check_name;
drop table if exists pg_temp.verify_0009p;
reset role;
