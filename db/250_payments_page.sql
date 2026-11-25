-- =============================================================================================
-- 250_payments_page.sql: addition 0009zy, Customers → Payments: the placeholder becomes the page for the payment state
-- of the subscription base over months, read from the subscription facts' stored takes as Customers → Subscriptions
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 244_auto_close_office_hours.sql (0009zv) and so after 216_subscriptions_page.sql (0009zh) and
-- 224_subscription_rates_start.sql (0009zl), whose functions it calls and never re-creates. Numbered after the open pull requests
-- #331 (246/247, 0009zw) and #332 (248/249, 0009zx), whose additions it neither needs nor touches: it runs before or
-- after them alike. Rerunnable, forward-only, in
-- one transaction with a lock timeout. Run as your own IAM login: dev first, then 251_verify_payments_page.sql there
-- (normal, then provoked). No other verify reads what this script adds; no verify is edited. 131_time_all.sql is edited
-- by this change (the page's rows). Prod: this script and 251 before the merge of its pull request (block B refuses
-- prod's data; the verdict reads PASS, A ONLY), and 131 part a after it (the web that calls these functions comes with
-- the merge; main's web calls none of them).
--
-- Why (Martin, 25 November 2026, in English): Customers → Subscriptions already holds a part about payments, and he wants
-- it as the basis of the Payments view under Customers. His choices of the same day: Customers → Subscriptions keeps its
-- payment parts (the Failed rate, the mix by payment instrument and payment state, the list's Payment state column) and
-- Payments reuses them and goes deeper; the first version holds the subscriptions alone (an order's Financial status
-- stays on Flash's Payments overview); renewals, failed renewals, chargebacks and refunds per month stand as a Pending
-- part until the facts' incremental refresh (as Subscriptions' Changes in the period). Flash's Payments overview is the
-- flow per market and day; Customers → Payments is the payment state of the subscription base over months and what is
-- at risk (closing "Placeholder pages to build: Payments" in docs/open-decisions.md).
--
-- Every figure is read from what 210, 212 and 224 store, as 216's page (no read of cma.subscription_event, a busy table):
--   cma.subscription_take          per present subscription: status, payment state with since, overdue, the
--                                  chargeback's return code and the amount at risk in its currency
--   cma.subscription_month_take    per store and month: start (the base) and moved_to_failed, complete (counts for the
--                                  Failed rate, from the store's rate start and subscriptions.rates_start_month)
--   cma.subscription_store_start   per store: its first event's month and the month its rates start
--   cma.subscription_take_state    when the take was computed
-- The base of the tiles, the cross table and the list is every present subscription in one of the five payment states
-- of a subscription that is billed: Paid, In retry, Charged back, Awaiting payment and Failed (Paused, Canceled and a
-- status without a payment state are not on this page). It is not the Total subscriptions (flash.device_holding_statuses,
-- active alone by default), so a tenant whose holding statuses leave failed out still sees its Failed subscriptions; for
-- Pulse4all (active and failed) the two are the same subscriptions and the page agrees with Subscriptions' mix. The list's
-- page (and the file's rows) adds three codes the take does not carry, from the mirror's row by its key, as 216's list:
-- the app's subscription number, the payment instrument's type and the CRM contact's id with its record link.
-- The filters are Customers → Subscriptions' own (cma.assert_subscriptions_filter, cma.subscriptions_scope_of): the
-- proposition and interval filters narrow what is per subscription (the tiles, the cross table, the list); the month take
-- is per store, so the Failed rate by month follows the market and store filters only, and the page says so.
--
-- What it adds (functions only; no table, view or column changes; nothing in cma_read)
--   cma.assert_payment_list      the list's state, sort and direction (CMA04)
--   cma.payment_rows_of          the list: a page of 50 (or the file's rows) of a state, a sort from a fixed list
--   cma.payments_page_of         the page in one read: take state, settings, filters' choices, tiles, months, rates,
--                                stores' starts, the cross table by payment state and payment instrument, the list's page
--   cma.payments_page, cma.payment_rows   reports.view or performance.team (CMA06), filters (CMA04); set_up false while
--                                no subscriptions connection is set up
--   cma.payment_file_record      the audit row of a file or an API read of the list, written before it is sent
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
  if not exists (select 1 from cma.schema_migration where version = '0009zv') then
    raise exception 'addition 0009zv (244_auto_close_office_hours.sql) has not run in this database';
  end if;
  if not exists (select 1 from cma.schema_migration where version = '0009zl') then
    raise exception 'addition 0009zl (224_subscription_rates_start.sql) has not run in this database';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The list's state, sort and direction
-- ---------------------------------------------------------------------------------------------
-- state: at_risk (an amount at risk: In retry, Failed, Charged back or an overdue Awaiting payment; the default),
-- in_retry, charged_back, awaiting_payment, failed, paid or all (every subscription of the five states); sort: amount_at_risk (within
-- its currency; the default), state_since, subscription, market or payment_state. Anything else, a null too, CMA04
create or replace function cma.assert_payment_list(p_state text, p_sort text, p_descending boolean)
returns void
language plpgsql immutable
as $$
begin
  if p_state is null or p_state not in ('at_risk', 'in_retry', 'charged_back', 'awaiting_payment', 'failed', 'paid', 'all') then
    raise exception 'state is at_risk, in_retry, charged_back, awaiting_payment, failed, paid or all' using errcode = 'CMA04';
  end if;
  if p_sort is null or p_sort not in ('amount_at_risk', 'state_since', 'subscription', 'market', 'payment_state') then
    raise exception 'sort is amount_at_risk, state_since, subscription, market or payment_state' using errcode = 'CMA04';
  end if;
  if p_descending is null then
    raise exception 'descending is true or false' using errcode = 'CMA04';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. The list
-- ---------------------------------------------------------------------------------------------
-- One page of the page's base (the five payment states) under the filters and a state, sorted by a key from a fixed list (never the
-- caller's text in the statement; an amount within its currency, as every list of amounts; a row without the key last
-- in a descending sort), then by the app's id in byte order and the take's id; a page of p_limit from (p_page - 1) *
-- p_limit; the file (p_file) every row up to flash.file_max_rows. Each row: the app's id and number, store and market,
-- status, payment state with its since and overdue, the chargeback's return code, the payment instrument's type, the
-- currency, the amount at risk and the monthly amount, and the CRM contact's id with its record link (a file's rows
-- carry the id alone). Ids, codes, amounts and times only. As 216's cma.subscription_rows_of, with the take's payment
-- columns and the state in place of the measure
create or replace function cma.payment_rows_of(p_tenant_id uuid, p_market text, p_store uuid, p_proposition text, p_interval text,
                                               p_state text, p_sort text, p_descending boolean, p_page integer, p_limit integer,
                                               p_file boolean)
returns jsonb
language plpgsql stable
as $$
declare
  v_max     integer := cma.setting_of(p_tenant_id, 'flash.file_max_rows')::integer;
  v_keys    text[];
  v_order   text;
  v_limit   integer;
  v_offset  integer;
  v_res     jsonb;
begin
  perform cma.assert_payment_list(p_state, p_sort, p_descending);
  v_keys := case p_sort
    when 'amount_at_risk' then array[$k$coalesce(t.currency, '') collate "C"$k$, 'coalesce(t.amount_at_risk, -1)']
    when 'state_since' then array[$k$coalesce(t.state_since, '-infinity'::timestamptz)$k$]
    when 'subscription' then array['t.source_id collate "C"']
    when 'market' then array['t.market collate "C"']
    when 'payment_state' then array['coalesce(ps.sort_order, 99)'] end;
  -- every key in the sort's direction, then the app's id in byte order and the take's id
  v_order := (select string_agg(k || case when p_descending then ' desc' else ' asc' end, ', ' order by o)
              from unnest(v_keys || array['t.source_id collate "C"', 't.subscription_id']) with ordinality u(k, o));
  if p_file then
    v_limit := v_max; v_offset := 0;
  else
    if p_page is null or p_page < 1 or p_page > 99999 or p_limit is null or p_limit < 1 or p_limit > 200 then
      raise exception 'page is a whole number from 1 and limit from 1 to 200' using errcode = 'CMA04';
    end if;
    v_limit := p_limit; v_offset := (p_page - 1) * p_limit;
  end if;
  execute format($q$
    with t as materialized (
      select x.* from cma.subscriptions_scope_of($1, $2, $3, $4, $5) x
      where x.payment_state in ('paid', 'in_retry', 'charged_back', 'awaiting_payment', 'failed')
        and case $6 when 'at_risk' then x.amount_at_risk is not null
                    when 'all' then true
                    else x.payment_state = $6 end
    ), ps as materialized (
      select p.key, p.sort_order from cma.payment_states() p
    ), keys as materialized (
      -- the sort on the key and the ids alone (narrow rows), then the page's rows joined back by id
      select t.subscription_id, row_number() over (order by %1$s) as pos
      from t left join ps on ps.key = t.payment_state
      order by %1$s
      limit $7 offset $8
    ), page as materialized (
      select t.*, k.pos from keys k join t on t.subscription_id = k.subscription_id
    ), sm as materialized (
      select y.connection_id, y.store_connection_id, y.handle from cma.flash_subscription_stores_of($1) y
    )
    select jsonb_build_object(
      'total', (select count(*) from t),
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'subscription_id', page.subscription_id, 'source_id', page.source_id, 'number', s.source_number,
                 'store', sm.handle, 'market', page.market, 'status', page.status, 'payment_state', page.payment_state,
                 'state_since', page.state_since, 'overdue', page.overdue, 'return_code', page.chargeback_return_code,
                 'instrument', s.payment_instrument_type, 'currency', page.currency,
                 'amount_at_risk', round(page.amount_at_risk, 2), 'monthly_amount', round(page.monthly_amount, 2),
                 'contact_id', cc.crm_contact_source_id,
                 'contact_url', case when cc.crm_contact_source_id is not null and not $9
                                     then cma.record_url(cc.crm_connection_id, 'contact', cc.crm_contact_source_id) end)
               order by page.pos)
        from page
        left join cma.subscription s on s.tenant_id = $1 and s.id = page.subscription_id
        left join sm on sm.connection_id = page.connection_id
        left join cma.commerce_customer cc on cc.tenant_id = $1 and cc.connection_id = sm.store_connection_id
                                          and cc.source_id = s.customer_source_id), '[]'::jsonb))
  $q$, v_order)
  into v_res
  using p_tenant_id, p_market, p_store, p_proposition, p_interval, p_state, v_limit, v_offset, p_file;
  return v_res || jsonb_build_object('page', case when p_file then 1 else p_page end, 'page_size', v_limit, 'state', p_state,
                                     'sort', p_sort, 'descending', p_descending);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. The page in one read
-- ---------------------------------------------------------------------------------------------
-- The page's document for the filters and the month range, as of the stored take (history false and nothing from the
-- takes while there is none):
--   take          computed_at, business_date
--   settings      the page's payment states in their order (cma.payment_states), the indicative euro
--                 rates (reports.fx_eur_rates), the propositions, customers.history_months (the range's limit)
--   filters       as Customers → Subscriptions': the markets and stores, the propositions (and none), the interval groups
--   tiles         over the page's base (the five payment states): their number; per payment state its subscriptions
--                 (paid, in_retry, charged_back, awaiting_payment and failed, zero included); the overdue among Awaiting payment; the amount at risk per currency with its subscriptions (and the
--                 indicative euros only while every currency has a rate); the last complete month's base and
--                 moved_to_failed (the Failed rate; market and store filters only)
--   months        per month of the range from the floor (subscriptions.rates_start_month): the complete stores' base and
--                 moved_to_failed, null where none is complete
--   rates         per market and complete month of the range: base, moved_to_failed
--   store_starts  per store under the market and store filters: its first event's month and its rates' start month
--   rates_start_month  the floor, or null
--   cross         over the page's base: per payment state and payment instrument (unknown where the app did not
--                 expand it) the subscriptions
--   list          the list's page p_page (the first by default; cma.payment_rows_of), so a further page is the same one read
-- The rates' parts are 224's cma.subscriptions_page_of's, read the same way (so Payments' Failed rate equals
-- Subscriptions' for the same filters); 251 compares them.
create or replace function cma.payments_page_of(p_tenant_id uuid, p_market text, p_store uuid, p_proposition text, p_interval text,
                                                p_from date, p_to date, p_state text, p_sort text, p_descending boolean,
                                                p_now timestamptz, p_page integer default 1)
returns jsonb
language plpgsql stable
as $$
declare
  v_zone     text := (select t.timezone from cma.tenant t where t.id = p_tenant_id);
  v_props    text[] := cma.flash_list_of(cma.setting_of(p_tenant_id, 'subscriptions.propositions'));
  v_fx       jsonb := cma.active_fx_of(p_tenant_id);
  -- the month the rates start for every store (subscriptions.rates_start_month, 0009zl), or null (no floor), as 224's page
  v_floor    date := to_date(nullif(cma.setting_of(p_tenant_id, 'subscriptions.rates_start_month'), '') || '-01', 'YYYY-MM-DD');
  v_state    cma.subscription_take_state;
  v_doc      jsonb;
begin
  select * into v_state from cma.subscription_take_state s where s.tenant_id = p_tenant_id;
  v_doc := jsonb_build_object(
    'history', v_state.tenant_id is not null,
    'take', case when v_state.tenant_id is null then null
                 else jsonb_build_object('computed_at', v_state.computed_at, 'business_date', v_state.business_date) end,
    'time_zone', v_zone,
    'today', (p_now at time zone v_zone)::date,
    'month', date_trunc('month', p_now at time zone v_zone)::date,
    'from', p_from, 'to', p_to,
    'filter', jsonb_build_object('market', p_market, 'store', p_store, 'proposition', p_proposition, 'interval', p_interval),
    'settings', jsonb_build_object('states', (select jsonb_agg(p.key order by p.sort_order) from cma.payment_states() p
                                             where p.key in ('paid', 'in_retry', 'charged_back', 'awaiting_payment', 'failed')),
                                   'fx', case when v_fx = '{}'::jsonb then null else v_fx end,
                                   'propositions', to_jsonb(v_props),
                                   'history_months', cma.setting_of(p_tenant_id, 'customers.history_months')::integer),
    'filters', jsonb_build_object(
      'markets', (select coalesce(jsonb_agg(m.market order by (m.market = 'unknown'), mk.sort_order, m.market collate "C"), '[]'::jsonb)
                  from (select distinct x.market from cma.subscription_store_start x where x.tenant_id = p_tenant_id
                        union select distinct t.market from cma.subscription_take t where t.tenant_id = p_tenant_id) m
                  left join cma.market mk on mk.tenant_id = p_tenant_id and mk.code = m.market),
      'stores', (select coalesce(jsonb_agg(jsonb_build_object('connection_id', y.connection_id, 'handle', y.handle,
                                                             'market', coalesce(y.market, 'unknown'))
                                           order by coalesce(y.market, 'unknown') collate "C", y.handle collate "C"), '[]'::jsonb)
                 from cma.flash_subscription_stores_of(p_tenant_id) y),
      'propositions', to_jsonb(v_props || array['none']),
      'intervals', to_jsonb(array['monthly', 'quarterly', 'yearly', 'other', 'unknown'])));
  if v_state.tenant_id is null then
    return v_doc || jsonb_build_object('tiles', null, 'months', '[]'::jsonb, 'rates', '[]'::jsonb, 'store_starts', '[]'::jsonb,
                                       'rates_start_month', v_floor, 'cross', null, 'list', null);
  end if;

  -- the tiles and the cross table: one scan of the take under the filters
  with h as materialized (
    select x.* from cma.subscriptions_scope_of(p_tenant_id, p_market, p_store, p_proposition, p_interval) x
    where x.payment_state in ('paid', 'in_retry', 'charged_back', 'awaiting_payment', 'failed')
  ), inst as materialized (
    -- the payment instrument's type of the tenant's present subscriptions (the mirror's row by its key; one scan of the
    -- tenant's rows, joined by hash, as 216's mix)
    select s.id, s.payment_instrument_type from cma.subscription s
    where s.tenant_id = p_tenant_id and s.source_deleted_at is null
  ), by_state as (
    select h.payment_state as k, count(*) as n from h group by 1
  ), risk as (
    select h.currency, round(sum(h.amount_at_risk), 2) as amount, count(*) as subscriptions
    from h where h.amount_at_risk is not null and h.currency is not null
    group by h.currency
  )
  select v_doc || jsonb_build_object(
    'tiles', jsonb_build_object(
      'total', (select count(*) from h),
      'by_state', (select jsonb_agg(jsonb_build_object('key', p.key, 'subscriptions', coalesce(b.n, 0)) order by p.sort_order)
                   from cma.payment_states() p left join by_state b on b.k = p.key
                   where p.key in ('paid', 'in_retry', 'charged_back', 'awaiting_payment', 'failed')),
      'overdue', (select count(*) from h where h.payment_state = 'awaiting_payment' and h.overdue),
      'at_risk', jsonb_build_object(
        'subscriptions', (select count(*) from h where h.amount_at_risk is not null),
        'amounts', (select coalesce(jsonb_agg(jsonb_build_object('currency', r.currency, 'amount', r.amount, 'subscriptions', r.subscriptions)
                                              order by r.currency collate "C"), '[]'::jsonb) from risk r),
        'eur', case when exists (select 1 from risk)
                         and not exists (select 1 from risk r where cma.active_eur_of(r.amount, r.currency, v_fx) is null)
                    then jsonb_build_object('amount', (select round(sum(cma.active_eur_of(r.amount, r.currency, v_fx)), 2) from risk r),
                                            'as_of', v_fx ->> 'as_of') end)),
    'cross', (select coalesce(jsonb_agg(jsonb_build_object('state', z.st, 'instrument', z.ins, 'subscriptions', z.n)
                                        order by coalesce(ps.sort_order, 99), z.st collate "C", z.ins collate "C"), '[]'::jsonb)
              from (select h.payment_state as st, coalesce(i.payment_instrument_type, 'unknown') as ins, count(*) as n
                    from h left join inst i on i.id = h.subscription_id group by 1, 2) z
              left join cma.payment_states() ps on ps.key = z.st))
  into v_doc;

  -- the months, the rates, the stores' starts: the month take under the market and store filters, from the floor (224)
  with m as materialized (
    select x.connection_id, x.market, x.month, x.kind, x.subscriptions, x.complete
    from cma.subscription_month_take x
    where x.tenant_id = p_tenant_id and x.month between greatest(p_from, coalesce(v_floor, p_from)) and p_to and x.currency = ''
      and x.kind in ('start', 'moved_to_failed')
      and (p_market is null or x.market = p_market) and (p_store is null or x.connection_id = p_store)
  ), last_complete as (
    select max(x.month) as month
    from cma.subscription_month_take x
    where x.tenant_id = p_tenant_id and x.currency = '' and x.complete and x.month <= p_to and x.month >= coalesce(v_floor, x.month)
      and (p_market is null or x.market = p_market) and (p_store is null or x.connection_id = p_store)
  ), lc as (
    select l.month,
           sum(x.subscriptions) filter (where x.kind = 'start') as base,
           coalesce(sum(x.subscriptions) filter (where x.kind = 'moved_to_failed'), 0) as moved_to_failed
    from last_complete l
    join cma.subscription_month_take x on x.tenant_id = p_tenant_id and x.month = l.month and x.currency = '' and x.complete
                                       and (p_market is null or x.market = p_market) and (p_store is null or x.connection_id = p_store)
    group by l.month
  ), g as (
    select g::date as month from generate_series(p_from, p_to, interval '1 month') g
  )
  select v_doc || jsonb_build_object(
      'months', (select coalesce(jsonb_agg(jsonb_build_object(
                   'month', g.month,
                   'complete', (select jsonb_build_object('base', sum(m.subscriptions) filter (where m.kind = 'start'),
                                                          'moved_to_failed', coalesce(sum(m.subscriptions) filter (where m.kind = 'moved_to_failed'), 0))
                                from m where m.month = g.month and m.complete
                                having count(*) > 0))
                 order by g.month), '[]'::jsonb) from g),
      'rates', (select coalesce(jsonb_agg(jsonb_build_object('market', r.market, 'month', r.month, 'base', r.base,
                                                             'moved_to_failed', r.moved_to_failed)
                                          order by r.market collate "C", r.month), '[]'::jsonb)
                from (select m.market, m.month,
                             sum(m.subscriptions) filter (where m.kind = 'start') as base,
                             coalesce(sum(m.subscriptions) filter (where m.kind = 'moved_to_failed'), 0) as moved_to_failed
                      from m where m.complete group by 1, 2) r),
      'store_starts', (select coalesce(jsonb_agg(jsonb_build_object('connection_id', s.connection_id, 'handle', y.handle, 'market', s.market,
                                                                   'first_event_month', s.first_event_month,
                                                                   'rate_start_month', s.rate_start_month, 'stragglers', s.stragglers)
                                                 order by s.market collate "C", y.handle collate "C"), '[]'::jsonb)
                       from cma.subscription_store_start s
                       left join cma.flash_subscription_stores_of(p_tenant_id) y on y.connection_id = s.connection_id
                       where s.tenant_id = p_tenant_id
                         and (p_market is null or s.market = p_market) and (p_store is null or s.connection_id = p_store)),
      'rates_start_month', v_floor,
      'last_complete', (select jsonb_build_object('month', lc.month, 'base', lc.base, 'moved_to_failed', lc.moved_to_failed) from lc))
  into v_doc;
  -- the last complete month's Failed rate goes with the tiles
  v_doc := jsonb_set(v_doc, '{tiles,rates}', coalesce(v_doc -> 'last_complete', 'null'::jsonb)) - 'last_complete';

  return v_doc || jsonb_build_object('list', cma.payment_rows_of(p_tenant_id, p_market, p_store, p_proposition, p_interval,
                                                                  p_state, p_sort, p_descending, coalesce(p_page, 1), 50, false));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. The application's reads: permission, filters, set up
-- ---------------------------------------------------------------------------------------------
-- reports.view or performance.team (CMA06 else); the filters (Customers → Subscriptions' own check, CMA04); set_up false
-- and nothing more while the tenant has no subscriptions connection set up (cma.flash_source_set_up_of)
create or replace function cma.payments_page(p_market text, p_store uuid, p_proposition text, p_interval text, p_from date, p_to date,
                                             p_state text default 'at_risk', p_sort text default 'amount_at_risk',
                                             p_descending boolean default true, p_page integer default 1)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.assert_subscriptions_filter(v_tenant, p_market, p_store, p_proposition, p_interval, p_from, p_to);
  perform cma.assert_payment_list(p_state, p_sort, p_descending);
  if p_page is null or p_page < 1 or p_page > 99999 then
    raise exception 'page is a whole number from 1' using errcode = 'CMA04';
  end if;
  if not coalesce(cma.flash_source_set_up_of(v_tenant, 'subscriptions'), false) then
    return jsonb_build_object('set_up', false);
  end if;
  return jsonb_build_object('set_up', true)
         || cma.payments_page_of(v_tenant, p_market, p_store, p_proposition, p_interval, p_from, p_to, p_state, p_sort, p_descending, now(),
                                 p_page);
end
$$;

-- The list's further page, or the file's rows (p_file: every row up to flash.file_max_rows, p_page and p_limit ignored),
-- with the take's moment (computed_at: the file's as_of)
create or replace function cma.payment_rows(p_market text, p_store uuid, p_proposition text, p_interval text, p_state text,
                                            p_sort text, p_descending boolean, p_page integer, p_limit integer, p_file boolean)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_month  date := date_trunc('month', now() at time zone (select t.timezone from cma.tenant t where t.id = v_tenant))::date;
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.assert_subscriptions_filter(v_tenant, p_market, p_store, p_proposition, p_interval, v_month, v_month);
  perform cma.assert_payment_list(p_state, p_sort, p_descending);
  if not coalesce(cma.flash_source_set_up_of(v_tenant, 'subscriptions'), false) then
    return jsonb_build_object('set_up', false);
  end if;
  return jsonb_build_object('set_up', true, 'history', exists (select 1 from cma.subscription_take_state s where s.tenant_id = v_tenant),
                            'computed_at', (select s.computed_at from cma.subscription_take_state s where s.tenant_id = v_tenant),
                            'time_zone', (select t.timezone from cma.tenant t where t.id = v_tenant))
         || cma.payment_rows_of(v_tenant, p_market, p_store, p_proposition, p_interval, p_state, p_sort, p_descending,
                                coalesce(p_page, 1), coalesce(p_limit, 50), coalesce(p_file, false));
end
$$;

-- The audit row of a read that hands out subscriptions' rows (as Customers → Subscriptions', 216), written before they
-- are sent: the part (records: the list's file; months: the Failed rate by month, with its range; rows: a page of the
-- list through the API, the page's own answer included), the filters, the state and the rows; never an id of a listed
-- subscription
create or replace function cma.payment_file_record(p_part text, p_market text, p_store uuid, p_proposition text, p_interval text,
                                                   p_state text, p_rows integer, p_from date default null, p_to date default null)
returns void
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_month  date := date_trunc('month', now() at time zone (select t.timezone from cma.tenant t where t.id = v_tenant))::date;
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.assert_subscriptions_filter(v_tenant, p_market, p_store, p_proposition, p_interval, v_month, v_month);
  if p_part is null or p_part not in ('records', 'months', 'rows') then
    raise exception 'part is records, months or rows' using errcode = 'CMA04';
  end if;
  -- the list's own check of the state (the sort and direction given are its defaults), so the two never differ
  perform cma.assert_payment_list(p_state, 'amount_at_risk', true);
  if p_rows is null or p_rows < 0 then
    raise exception 'a file record names its rows' using errcode = 'CMA04';
  end if;
  if (p_from is not null or p_to is not null) and (p_part <> 'months' or p_from is null or p_to is null or p_from > p_to) then
    raise exception 'a range goes with the months part alone, from at most to' using errcode = 'CMA04';
  end if;
  insert into cma.audit_log (tenant_id, table_name, action, old_row, new_row, actor_user_id, actor_label)
  values (v_tenant, 'payment_file', 'insert', null,
          jsonb_strip_nulls(jsonb_build_object('part', p_part, 'market', p_market, 'store', p_store, 'proposition', p_proposition, 'interval', p_interval,
                                               'state', p_state, 'from', p_from, 'to', p_to, 'rows', p_rows)),
          cma.current_user_id(), cma.current_actor_label());
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. Grants and settings of the functions
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.assert_payment_list(text,text,boolean)',
    'cma.payment_rows_of(uuid,text,uuid,text,text,text,text,boolean,integer,integer,boolean)',
    'cma.payments_page_of(uuid,text,uuid,text,text,date,date,text,text,boolean,timestamptz,integer)',
    'cma.payments_page(text,uuid,text,text,date,date,text,text,boolean,integer)',
    'cma.payment_rows(text,uuid,text,text,text,text,boolean,integer,integer,boolean)',
    'cma.payment_file_record(text,text,uuid,text,text,text,integer,date,date)'] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
    -- JIT off, as the other report reads (122, section 14; 216): a read of thousands of rows otherwise pays JIT's
    -- compilation on a session's first calls
    execute format('alter function %s set jit = off', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009zy', 'Customers → Payments: cma.payments_page (reports.view or performance.team; the take''s state, the filters'' choices, the tiles per payment state with the amount at risk and the last complete month''s Failed rate, the Failed rate by month, the stores'' starts, the cross table by payment state and payment instrument and the list''s first page, from the subscription facts'' takes), cma.payment_rows (a page of the list or the file''s rows) and cma.payment_file_record (the audit row of every read that hands out rows: records, months or rows), over cma.assert_payment_list, cma.payment_rows_of and cma.payments_page_of. No function re-created, no table, view or column changed; nothing in cma_read')
on conflict (version) do nothing;

commit;
reset role;
