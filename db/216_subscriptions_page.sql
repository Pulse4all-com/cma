-- =============================================================================================
-- 216_subscriptions_page.sql: addition 0009zh, Customers → Subscriptions (brief B39 continued, Part B39d): the page's
-- read, its list and file, and the Churn rate card of Customers → Active, all from the subscription facts' stored takes
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 212_subscription_facts_speed.sql (0009zf); 214/215 (0009zg, brief B39b) may run before or after it: this script
-- re-creates no function, so it touches nothing 214 does. Rerunnable, forward-only, in one transaction with a lock
-- timeout. Run as your own IAM login: dev first, then 217_verify_subscriptions_page.sql there (normal, then provoked).
-- No other verify reads what this script adds; no verify is edited. 131_time_all.sql is edited by this change (the
-- page's rows). Prod: this script and 217 before the merge of its pull request (the web that calls these functions comes
-- with the merge; main's web calls none of them).
--
-- Why (Martin, 20 and 21 November 2026, brief B39 continued, Part B39d; Decision log, 21 Nov 2026): the placeholder
-- Customers → Subscriptions becomes the page for how the subscription base moves over months, while Flash keeps the
-- stock per market and date. Martin, 21 November 2026: "The page reads stored takes only; its reads stay within the
-- report budgets on one CPU." Every figure here is read from what 210 and 212 store:
--   cma.subscription_take          per present subscription: status, payment state, monthly amount, interval group,
--                                  device units, propositions, models, original start, cohort, migrated
--   cma.subscription_month_take    per store and month: the Total subscriptions at the start and end, the movements by
--                                  kind (counts from the store's first event, amounts per currency from the first load),
--                                  complete (counts for the rates)
--   cma.subscription_store_start   per store: its first event's month and the month its rates start
--   cma.subscription_survival_take per store, start cohort, interval group and renewal number: started, eligible, survived
--   cma.subscription_take_state    when the take was computed and from when amounts are known
-- The list's page of 50 rows (and the file's rows) adds three codes the take does not carry, from the mirror's row of
-- each listed subscription by its key: the app's subscription number, the payment instrument's type and, through the
-- store customer the CMA matched (0008h), the CRM contact's id with its record link. The payment instrument mix reads
-- the instrument the same way, by key, for the subscriptions the take lists. No event is read: a read of
-- cma.subscription_event (a busy table) never runs on this page.
--
-- What the takes cannot answer yet (named in the pull request, and in docs/open-decisions.md):
--   Changes in the period (skips, billing-date moves, interval changes, line changes, merges and splits) and Who ended
--   them (churn by actor type) need a take of the events per store and month; the facts' refresh is over its budget in
--   prod (11,478 ms against 10,000 on 21 Nov 2026), so that take waits for the incremental refresh (open decision "The
--   facts refresh"). The page shows both sections as placeholders.
--   The proposition and interval filters narrow what is per subscription (the tiles, the mix, the list and, for the
--   interval, renewal survival); the month take is per store, so the movements and the rates follow the market and store
--   filters only, and the page says so.
--   The subscription app's own counts beside the tiles (B39b, addition 0009zg) have a place in the answer
--   (source_counts, null until B39b is in prod), never a zero.
--
-- What it adds (functions only; no table, view or column changes; nothing in cma_read)
--   cma.assert_subscriptions_filter   the page's filters (CMA04)
--   cma.subscriptions_scope_of        the take's rows under the filters (the base of the tiles, mix and list)
--   cma.subscription_rows_of          the list: a page of 50 (or the file's rows), a measure, a sort from a fixed list
--   cma.subscriptions_page_of         the page in one read: take state, settings, filters' choices, tiles, months,
--                                     rates, store starts, survival, mix and the list's first page
--   cma.subscriptions_page, cma.subscription_rows   reports.view or performance.team (CMA06), filters (CMA04); set_up
--                                     false while no subscriptions connection is set up
--   cma.subscription_file_record      the audit row of a file or an API read of the list, written before it is sent
--   cma.subscriptions_churn_card      Customers → Active's Churn rate card: the last complete month's Churn rate and
--                                     Failed rate of a market or of every market
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
  if not exists (select 1 from cma.schema_migration where version = '0009zf') then
    raise exception 'addition 0009zf (212_subscription_facts_speed.sql) has not run in this database';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The filters
-- ---------------------------------------------------------------------------------------------
-- market: a market code or unknown; store: a subscriptions connection of the tenant mapped to a store; proposition: a
-- code of subscriptions.propositions or none (no mapped proposition); interval: monthly, quarterly, yearly, other or
-- unknown; from and to: first days of months, from at most to, to at most the current month in the tenant's zone, and
-- the range at most customers.history_months long. Anything else CMA04
create or replace function cma.assert_subscriptions_filter(p_tenant_id uuid, p_market text, p_store uuid, p_proposition text, p_interval text,
                                                           p_from date, p_to date)
returns void
language plpgsql stable
as $$
declare
  v_month date := date_trunc('month', (now() at time zone (select t.timezone from cma.tenant t where t.id = p_tenant_id)))::date;
  v_max   integer := cma.setting_of(p_tenant_id, 'customers.history_months')::integer;
begin
  if p_market is not null and p_market !~ '^([A-Z]{2}|unknown)$' then
    raise exception 'market is a market code or unknown' using errcode = 'CMA04';
  end if;
  if p_store is not null and not exists (select 1 from cma.flash_subscription_stores_of(p_tenant_id) y where y.connection_id = p_store) then
    raise exception 'store is a subscriptions connection of the tenant' using errcode = 'CMA04';
  end if;
  if p_proposition is not null and p_proposition <> 'none'
     and not (p_proposition = any (cma.flash_list_of(cma.setting_of(p_tenant_id, 'subscriptions.propositions')))) then
    raise exception 'proposition is a code of subscriptions.propositions or none' using errcode = 'CMA04';
  end if;
  if p_interval is not null and p_interval not in ('monthly', 'quarterly', 'yearly', 'other', 'unknown') then
    raise exception 'interval is monthly, quarterly, yearly, other or unknown' using errcode = 'CMA04';
  end if;
  if p_from is null or p_to is null or p_from <> date_trunc('month', p_from)::date or p_to <> date_trunc('month', p_to)::date
     or p_from > p_to or p_to > v_month
     or (extract(year from age(p_to, p_from)) * 12 + extract(month from age(p_to, p_from)))::integer + 1 > v_max then
    raise exception 'from and to are months, from at most to, to at most this month, and at most % months', v_max using errcode = 'CMA04';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. The take under the filters
-- ---------------------------------------------------------------------------------------------
-- The take's rows the filters keep: market, store, proposition (a subscription with several propositions belongs to
-- each; none: no mapped proposition) and interval group. A plain scan of the tenant's take (its primary key leads by
-- the tenant)
create or replace function cma.subscriptions_scope_of(p_tenant_id uuid, p_market text, p_store uuid, p_proposition text, p_interval text)
returns setof cma.subscription_take
language sql stable
rows 20000
as $$
  select t.*
  from cma.subscription_take t
  where t.tenant_id = p_tenant_id
    and (p_market is null or t.market = p_market)
    and (p_store is null or t.connection_id = p_store)
    and (p_proposition is null
         or (p_proposition = 'none' and cardinality(t.propositions) = 0)
         or (p_proposition <> 'none' and p_proposition = any (t.propositions)))
    and (p_interval is null or t.interval_group = p_interval)
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. The list
-- ---------------------------------------------------------------------------------------------
-- One page of the take's subscriptions under the filters and a measure: total (a device-holding status,
-- flash.device_holding_statuses: the Total subscriptions; the default), active (flash.active_subscription_statuses),
-- failed, paused, unmapped (holding, with device units unknown: a line whose variant is not mapped) or all (every
-- present subscription). Sorted by a key from a fixed list (never the caller's text in the statement), then by the
-- app's id in byte order and the take's id; a page of p_limit from (p_page - 1) * p_limit; the file (p_file) every
-- row up to flash.file_max_rows. Each row: the app's id and number, store and market, status, payment state, interval
-- group, currency and monthly amount, device units, original start (estimated) with its basis, age in whole months,
-- propositions, the payment instrument's type, and the CRM contact's id with its record link (the store customer the
-- CMA matched, 0008h; a file's rows carry the id alone, as the file writes no link). Ids, codes, amounts and dates only
create or replace function cma.subscription_rows_of(p_tenant_id uuid, p_market text, p_store uuid, p_proposition text, p_interval text,
                                                    p_measure text, p_sort text, p_descending boolean, p_page integer, p_limit integer,
                                                    p_file boolean, p_now timestamptz)
returns jsonb
language plpgsql stable
as $$
declare
  v_zone    text := (select t.timezone from cma.tenant t where t.id = p_tenant_id);
  v_holding text[] := cma.flash_list_of(cma.setting_of(p_tenant_id, 'flash.device_holding_statuses'));
  v_active  text[] := cma.flash_list_of(cma.setting_of(p_tenant_id, 'flash.active_subscription_statuses'));
  v_max     integer := cma.setting_of(p_tenant_id, 'flash.file_max_rows')::integer;
  v_key     text;
  v_limit   integer;
  v_offset  integer;
  v_res     jsonb;
begin
  if p_measure not in ('total', 'active', 'failed', 'paused', 'unmapped', 'all') then
    raise exception 'measure is total, active, failed, paused, unmapped or all' using errcode = 'CMA04';
  end if;
  v_key := case p_sort
    when 'monthly_amount' then 'coalesce(t.monthly_amount, -1)'
    when 'subscription' then 't.source_id collate "C"'
    when 'market' then 't.market collate "C"'
    when 'status' then 't.status collate "C"'
    when 'payment_state' then 'coalesce(ps.sort_order, 99)'
    when 'interval' then 't.interval_group collate "C"'
    when 'device_units' then 'coalesce(t.device_units, -1)'
    when 'original_start' then $k$coalesce(t.original_start_at, '-infinity'::timestamptz)$k$
    else null end;
  if v_key is null then
    raise exception 'sort is monthly_amount, subscription, market, status, payment_state, interval, device_units or original_start' using errcode = 'CMA04';
  end if;
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
      where case $6 when 'total' then x.status = any ($7)
                    when 'active' then x.status = any ($8)
                    when 'failed' then x.status = 'failed'
                    when 'paused' then x.status = 'paused'
                    when 'unmapped' then x.status = any ($7) and x.device_units is null
                    else true end
    ), ps as materialized (
      select p.key, p.sort_order from cma.payment_states() p
    ), keys as materialized (
      -- the sort on the key and the ids alone (narrow rows: a sort of whole take rows spills to disk), then the page's
      -- rows joined back by id
      select t.subscription_id, row_number() over (order by %1$s %2$s, t.source_id collate "C" %2$s, t.subscription_id %2$s) as pos
      from t left join ps on ps.key = t.payment_state
      order by %1$s %2$s, t.source_id collate "C" %2$s, t.subscription_id %2$s
      limit $9 offset $10
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
                 'interval', page.interval_group, 'currency', page.currency, 'monthly_amount', round(page.monthly_amount, 2),
                 'device_units', page.device_units,
                 'original_start', (page.original_start_at at time zone $11)::date, 'original_start_basis', page.original_start_basis,
                 'age_months', case when page.original_start_at is null then null
                                    else (extract(year from age($12, page.original_start_at)) * 12
                                          + extract(month from age($12, page.original_start_at)))::integer end,
                 'propositions', to_jsonb(page.propositions), 'instrument', s.payment_instrument_type,
                 'contact_id', cc.crm_contact_source_id,
                 'contact_url', case when cc.crm_contact_source_id is not null and not $13
                                     then cma.record_url(cc.crm_connection_id, 'contact', cc.crm_contact_source_id) end)
               order by page.pos)
        from page
        join cma.subscription s on s.tenant_id = $1 and s.id = page.subscription_id
        left join sm on sm.connection_id = page.connection_id
        left join cma.commerce_customer cc on cc.tenant_id = $1 and cc.connection_id = sm.store_connection_id
                                          and cc.source_id = s.customer_source_id), '[]'::jsonb))
  $q$, v_key, case when p_descending then 'desc' else 'asc' end)
  into v_res
  using p_tenant_id, p_market, p_store, p_proposition, p_interval, p_measure, v_holding, v_active, v_limit, v_offset, v_zone, p_now, p_file;
  return v_res || jsonb_build_object('page', case when p_file then 1 else p_page end, 'page_size', v_limit, 'measure', p_measure,
                                     'sort', p_sort, 'descending', p_descending);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. The page in one read
-- ---------------------------------------------------------------------------------------------
-- The page's document for the filters and the month range, as of the stored take (history false and nothing from the
-- takes while there is none):
--   take          computed_at, business_date, amounts_from (amounts of movements are known from then)
--   settings      the holding, active and ended statuses, the device bands' and age bands' bounds, the indicative
--                 euro rates (reports.fx_eur_rates), the propositions
--   filters       the markets and stores of the take and of the stores' starts, the propositions (and none), the groups
--   tiles         Total subscriptions with its split per holding status; Paused; the Monthly recurring amount per
--                 currency over the active statuses (and the indicative euros only while every currency has a rate);
--                 the last complete month's churn and failed counts over its base (market and store filters only);
--                 Device units over the Total subscriptions with the unmapped among them; source_counts null (B39b)
--   months        per month of the range: the counts per movement kind (start, end and every kind), the amounts per
--                 currency and kind, and the complete stores' base, churned and moved_to_failed (null where none is
--                 complete)
--   rates         per market and complete month of the range: base, churned, moved_to_failed
--   store_starts  per store under the market and store filters: its first event's month and its rates' start month
--   survival      per interval group, start cohort in the range and renewal number: started, eligible, survived (summed
--                 over the stores), and the migrated subscriptions left out
--   mix           over the Total subscriptions: by proposition, model, interval group, device band, age band, payment
--                 instrument and payment state
--   list          the list's first page (cma.subscription_rows_of)
create or replace function cma.subscriptions_page_of(p_tenant_id uuid, p_market text, p_store uuid, p_proposition text, p_interval text,
                                                     p_from date, p_to date, p_measure text, p_sort text, p_descending boolean,
                                                     p_now timestamptz)
returns jsonb
language plpgsql stable
as $$
declare
  v_zone     text := (select t.timezone from cma.tenant t where t.id = p_tenant_id);
  v_holding  text[] := cma.flash_list_of(cma.setting_of(p_tenant_id, 'flash.device_holding_statuses'));
  v_active   text[] := cma.flash_list_of(cma.setting_of(p_tenant_id, 'flash.active_subscription_statuses'));
  v_ended    text[] := cma.flash_list_of(cma.setting_of(p_tenant_id, 'flash.ended_subscription_statuses'));
  v_dbounds  integer[] := cma.flash_bounds_of(cma.setting_of(p_tenant_id, 'flash.device_bands'));
  v_abounds  integer[] := cma.flash_bounds_of(cma.setting_of(p_tenant_id, 'flash.subscription_age_months'));
  v_props    text[] := cma.flash_list_of(cma.setting_of(p_tenant_id, 'subscriptions.propositions'));
  v_fx       jsonb := cma.active_fx_of(p_tenant_id);
  v_state    cma.subscription_take_state;
  v_doc      jsonb;
begin
  select * into v_state from cma.subscription_take_state s where s.tenant_id = p_tenant_id;
  v_doc := jsonb_build_object(
    'history', v_state.tenant_id is not null,
    'take', case when v_state.tenant_id is null then null
                 else jsonb_build_object('computed_at', v_state.computed_at, 'business_date', v_state.business_date,
                                         'amounts_from', v_state.amounts_from) end,
    'time_zone', v_zone,
    'today', (p_now at time zone v_zone)::date,
    'month', date_trunc('month', p_now at time zone v_zone)::date,
    'from', p_from, 'to', p_to,
    'filter', jsonb_build_object('market', p_market, 'store', p_store, 'proposition', p_proposition, 'interval', p_interval),
    'settings', jsonb_build_object('holding', to_jsonb(v_holding), 'active', to_jsonb(v_active), 'ended', to_jsonb(v_ended),
                                   'device_bands', to_jsonb(cma.flash_count_bands_of(v_dbounds)),
                                   'age_bands', to_jsonb(cma.flash_age_bands_of(v_abounds)),
                                   'fx', case when v_fx = '{}'::jsonb then null else v_fx end,
                                   'propositions', to_jsonb(v_props)),
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
                                       'survival', null, 'mix', null, 'list', null);
  end if;

  -- the tiles and the mix: one scan of the take under the filters
  with t as materialized (
    select x.* from cma.subscriptions_scope_of(p_tenant_id, p_market, p_store, p_proposition, p_interval) x
  ), h as materialized (
    select t.* from t where t.status = any (v_holding)
  ), inst as materialized (
    -- the payment instrument's type of the tenant's present subscriptions (the mirror's row by its key; one scan of the
    -- tenant's rows, joined by hash: a lookup per subscription costs more at this size)
    select s.id, s.payment_instrument_type from cma.subscription s
    where s.tenant_id = p_tenant_id and s.source_deleted_at is null
  ), ages as (
    -- the whole months since the original start, grouped first: the band is then named once per distinct age
    select case when h.original_start_at is null then null
                else (extract(year from age(p_now, h.original_start_at)) * 12 + extract(month from age(p_now, h.original_start_at)))::integer end as months,
           count(*) as n
    from h group by 1
  ), amt as (
    select t.currency, round(sum(t.monthly_amount), 2) as amount, count(*) as subscriptions
    from t where t.status = any (v_active) and t.currency is not null and t.monthly_amount is not null
    group by t.currency
  )
  select v_doc || jsonb_build_object(
    'tiles', jsonb_build_object(
      'total', jsonb_build_object('value', (select count(*) from h),
                                  'by_status', (select coalesce(jsonb_object_agg(u.s, (select count(*) from h where h.status = u.s)), '{}'::jsonb)
                                                from unnest(v_holding) u(s))),
      'paused', (select count(*) from t where t.status = 'paused'),
      'amounts', (select coalesce(jsonb_agg(jsonb_build_object('currency', a.currency, 'amount', a.amount, 'subscriptions', a.subscriptions)
                                            order by a.currency collate "C"), '[]'::jsonb) from amt a),
      'eur', case when exists (select 1 from amt)
                       and not exists (select 1 from amt a where cma.active_eur_of(a.amount, a.currency, v_fx) is null)
                  then jsonb_build_object('amount', (select round(sum(cma.active_eur_of(a.amount, a.currency, v_fx)), 2) from amt a),
                                          'as_of', v_fx ->> 'as_of') end,
      'devices', jsonb_build_object('units', (select coalesce(sum(h.device_units), 0) from h),
                                    'unmapped', (select count(*) from h where h.device_units is null)),
      'source_counts', null),
    'mix', jsonb_build_object(
      'proposition', (select coalesce(jsonb_agg(jsonb_build_object('key', z.k, 'subscriptions', z.n) order by z.n desc, z.k collate "C"), '[]'::jsonb)
                      from (select coalesce(p.p, 'none') as k, count(*) as n
                            from h left join lateral unnest(nullif(h.propositions, '{}')) p(p) on true group by 1) z),
      'model', (select coalesce(jsonb_agg(jsonb_build_object('key', z.k, 'label', md.name, 'subscriptions', z.n)
                                          order by z.n desc, z.k collate "C"), '[]'::jsonb)
                from (select coalesce(m.m, 'none') as k, count(*) as n
                      from h left join lateral unnest(nullif(h.models, '{}')) m(m) on true group by 1) z
                left join cma.device_model md on md.tenant_id = p_tenant_id and md.key = z.k),
      'interval', (select coalesce(jsonb_agg(jsonb_build_object('key', z.k, 'subscriptions', z.n)
                                             order by array_position(array['monthly', 'quarterly', 'yearly', 'other', 'unknown'], z.k)), '[]'::jsonb)
                   from (select h.interval_group as k, count(*) as n from h group by 1) z),
      'device_band', (select coalesce(jsonb_agg(jsonb_build_object('key', z.k, 'subscriptions', z.n)
                                                order by coalesce(array_position(cma.flash_count_bands_of(v_dbounds), z.k), 99)), '[]'::jsonb)
                      from (select coalesce(cma.flash_count_band_of(d.units, v_dbounds), 'unmapped') as k, sum(d.n) as n
                            from (select h.device_units as units, count(*) as n from h group by 1) d group by 1) z),
      'age_band', (select coalesce(jsonb_agg(jsonb_build_object('key', z.k, 'subscriptions', z.n)
                                             order by coalesce(array_position(cma.flash_age_bands_of(v_abounds), z.k), 99)), '[]'::jsonb)
                   from (select case when a.months is null then 'unknown' else cma.flash_age_band_of(a.months, v_abounds) end as k, sum(a.n) as n
                         from ages a group by 1) z),
      'instrument', (select coalesce(jsonb_agg(jsonb_build_object('key', z.k, 'subscriptions', z.n) order by z.n desc, z.k collate "C"), '[]'::jsonb)
                     from (select coalesce(i.payment_instrument_type, 'unknown') as k, count(*) as n
                           from h left join inst i on i.id = h.subscription_id group by 1) z),
      'payment_state', (select coalesce(jsonb_agg(jsonb_build_object('key', z.k, 'subscriptions', z.n)
                                                  order by coalesce(ps.sort_order, 99), z.k collate "C"), '[]'::jsonb)
                        from (select coalesce(h.payment_state, 'unknown') as k, count(*) as n from h group by 1) z
                        left join cma.payment_states() ps on ps.key = z.k)),
    'migrated_left_out', (select count(*) from t where t.migrated))
  into v_doc;

  -- the months, the rates, the stores' starts: the month take under the market and store filters
  with m as materialized (
    select x.connection_id, x.market, x.month, x.kind, x.currency, x.subscriptions, x.amount, x.complete
    from cma.subscription_month_take x
    where x.tenant_id = p_tenant_id and x.month between p_from and p_to
      and (p_market is null or x.market = p_market) and (p_store is null or x.connection_id = p_store)
  ), last_complete as (
    select max(x.month) as month
    from cma.subscription_month_take x
    where x.tenant_id = p_tenant_id and x.currency = '' and x.complete and x.month <= p_to
      and (p_market is null or x.market = p_market) and (p_store is null or x.connection_id = p_store)
  ), lc as (
    select l.month,
           sum(x.subscriptions) filter (where x.kind = 'start') as base,
           coalesce(sum(x.subscriptions) filter (where x.kind = 'churned'), 0) as churned,
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
                   'counts', (select jsonb_object_agg(k.kind, k.n) from (select m.kind, sum(m.subscriptions) as n from m
                                                                         where m.month = g.month and m.currency = '' group by m.kind) k),
                   'amounts', (select jsonb_object_agg(c.currency, c.kinds) from (
                                 select a.currency, jsonb_object_agg(a.kind, a.amount) as kinds
                                 from (select m.currency, m.kind, sum(m.amount) as amount from m
                                       where m.month = g.month and m.currency <> '' and m.amount is not null group by 1, 2) a
                                 group by a.currency) c),
                   'complete', (select jsonb_build_object('base', sum(m.subscriptions) filter (where m.kind = 'start'),
                                                          'churned', coalesce(sum(m.subscriptions) filter (where m.kind = 'churned'), 0),
                                                          'moved_to_failed', coalesce(sum(m.subscriptions) filter (where m.kind = 'moved_to_failed'), 0))
                                from m where m.month = g.month and m.currency = '' and m.complete
                                having count(*) > 0))
                 order by g.month), '[]'::jsonb) from g),
      'rates', (select coalesce(jsonb_agg(jsonb_build_object('market', r.market, 'month', r.month, 'base', r.base, 'churned', r.churned,
                                                             'moved_to_failed', r.moved_to_failed)
                                          order by r.market collate "C", r.month), '[]'::jsonb)
                from (select m.market, m.month,
                             sum(m.subscriptions) filter (where m.kind = 'start') as base,
                             coalesce(sum(m.subscriptions) filter (where m.kind = 'churned'), 0) as churned,
                             coalesce(sum(m.subscriptions) filter (where m.kind = 'moved_to_failed'), 0) as moved_to_failed
                      from m where m.currency = '' and m.complete group by 1, 2) r),
      'store_starts', (select coalesce(jsonb_agg(jsonb_build_object('connection_id', s.connection_id, 'handle', y.handle, 'market', s.market,
                                                                   'first_event_month', s.first_event_month,
                                                                   'rate_start_month', s.rate_start_month, 'stragglers', s.stragglers)
                                                 order by s.market collate "C", y.handle collate "C"), '[]'::jsonb)
                       from cma.subscription_store_start s
                       left join cma.flash_subscription_stores_of(p_tenant_id) y on y.connection_id = s.connection_id
                       where s.tenant_id = p_tenant_id
                         and (p_market is null or s.market = p_market) and (p_store is null or s.connection_id = p_store)),
      'last_complete', (select jsonb_build_object('month', lc.month, 'base', lc.base, 'churned', lc.churned,
                                                  'moved_to_failed', lc.moved_to_failed) from lc))
  into v_doc;
  -- the last complete month's rates go with the tiles
  v_doc := jsonb_set(v_doc, '{tiles,rates}', coalesce(v_doc -> 'last_complete', 'null'::jsonb)) - 'last_complete';

  -- renewal survival: the take of cells under the market, store and interval filters, cohorts in the range
  select v_doc || jsonb_build_object('survival', jsonb_build_object(
    'groups', coalesce((
      select jsonb_agg(jsonb_build_object('interval', gr.interval_group, 'cohorts', gr.cohorts) order by array_position(array['monthly', 'quarterly', 'yearly', 'other', 'unknown'], gr.interval_group))
      from (select c.interval_group,
                   jsonb_agg(jsonb_build_object('cohort', c.cohort_month, 'started', c.started, 'cells', c.cells) order by c.cohort_month) as cohorts
            from (select v.interval_group, v.cohort_month, max(v.started) filter (where v.renewal_number = 1) as started,
                         jsonb_agg(jsonb_build_object('renewal', v.renewal_number, 'eligible', v.eligible, 'survived', v.survived) order by v.renewal_number) as cells
                  from (select x.interval_group, x.cohort_month, x.renewal_number,
                               sum(x.started) as started, sum(x.eligible) as eligible, sum(x.survived) as survived
                        from cma.subscription_survival_take x
                        where x.tenant_id = p_tenant_id and x.cohort_month between p_from and p_to
                          and (p_market is null or x.market = p_market) and (p_store is null or x.connection_id = p_store)
                          and (p_interval is null or x.interval_group = p_interval)
                        group by 1, 2, 3) v
                  where v.eligible > 0 or v.renewal_number = 1
                  group by 1, 2) c
            group by c.interval_group) gr), '[]'::jsonb)))
  into v_doc;
  v_doc := jsonb_set(v_doc, '{survival,migrated_left_out}', v_doc -> 'migrated_left_out') - 'migrated_left_out';

  return v_doc || jsonb_build_object('list', cma.subscription_rows_of(p_tenant_id, p_market, p_store, p_proposition, p_interval,
                                                                       p_measure, p_sort, p_descending, 1, 50, false, p_now));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. The application's reads: permission, filters, set up
-- ---------------------------------------------------------------------------------------------
-- reports.view or performance.team (CMA06 else); the filters (CMA04); set_up false and nothing more while the tenant
-- has no subscriptions connection set up (cma.flash_source_set_up_of)
create or replace function cma.subscriptions_page(p_market text, p_store uuid, p_proposition text, p_interval text, p_from date, p_to date,
                                                  p_measure text default 'total', p_sort text default 'monthly_amount',
                                                  p_descending boolean default true)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  perform cma.assert_subscriptions_filter(v_tenant, p_market, p_store, p_proposition, p_interval, p_from, p_to);
  if not coalesce(cma.flash_source_set_up_of(v_tenant, 'subscriptions'), false) then
    return jsonb_build_object('set_up', false);
  end if;
  return jsonb_build_object('set_up', true)
         || cma.subscriptions_page_of(v_tenant, p_market, p_store, p_proposition, p_interval, p_from, p_to, p_measure, p_sort, p_descending, now());
end
$$;

-- The list's further page, or the file's rows (p_file: every row up to flash.file_max_rows, p_page and p_limit ignored),
-- with the take's moment (computed_at: the file's as_of)
create or replace function cma.subscription_rows(p_market text, p_store uuid, p_proposition text, p_interval text, p_measure text,
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
  if not coalesce(cma.flash_source_set_up_of(v_tenant, 'subscriptions'), false) then
    return jsonb_build_object('set_up', false);
  end if;
  return jsonb_build_object('set_up', true, 'history', exists (select 1 from cma.subscription_take_state s where s.tenant_id = v_tenant),
                            'computed_at', (select s.computed_at from cma.subscription_take_state s where s.tenant_id = v_tenant),
                            'time_zone', (select t.timezone from cma.tenant t where t.id = v_tenant))
         || cma.subscription_rows_of(v_tenant, p_market, p_store, p_proposition, p_interval, p_measure, p_sort, p_descending,
                                     coalesce(p_page, 1), coalesce(p_limit, 50), coalesce(p_file, false), now());
end
$$;

-- The audit row of a read that hands out subscriptions' rows (as Customers → Active's, 172), written before they are
-- sent: the part (records: the list's file; months: the movements and rates by month, with their range; rows: a page of
-- the list through the API, the page's own answer included), the filters, the measure and the rows; never an id of a
-- listed subscription
create or replace function cma.subscription_file_record(p_part text, p_market text, p_store uuid, p_proposition text, p_interval text,
                                                        p_measure text, p_rows integer, p_from date default null, p_to date default null)
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
  if p_measure is null or p_measure not in ('total', 'active', 'failed', 'paused', 'unmapped', 'all') then
    raise exception 'measure is total, active, failed, paused, unmapped or all' using errcode = 'CMA04';
  end if;
  if p_rows is null or p_rows < 0 then
    raise exception 'a file record names its rows' using errcode = 'CMA04';
  end if;
  insert into cma.audit_log (tenant_id, table_name, action, old_row, new_row, actor_user_id, actor_label)
  values (v_tenant, 'subscription_file', 'insert', null,
          jsonb_strip_nulls(jsonb_build_object('part', p_part, 'market', p_market, 'store', p_store, 'proposition', p_proposition, 'interval', p_interval,
                                               'measure', p_measure, 'from', p_from, 'to', p_to, 'rows', p_rows)),
          cma.current_user_id(), cma.current_actor_label());
end
$$;

-- Customers → Active's Churn rate card (D.4): the last complete month's base, churned and moved_to_failed of a market
-- (or of every market), from the month take's complete rows; null while there is no take or no complete month
create or replace function cma.subscriptions_churn_card(p_market text)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_res    jsonb;
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  if p_market is not null and p_market !~ '^([A-Z]{2}|unknown)$' then
    raise exception 'market is a market code or unknown' using errcode = 'CMA04';
  end if;
  with l as (
    select max(x.month) as month from cma.subscription_month_take x
    where x.tenant_id = v_tenant and x.currency = '' and x.complete and (p_market is null or x.market = p_market)
  )
  select jsonb_build_object('month', l.month,
                            'base', sum(x.subscriptions) filter (where x.kind = 'start'),
                            'churned', coalesce(sum(x.subscriptions) filter (where x.kind = 'churned'), 0),
                            'moved_to_failed', coalesce(sum(x.subscriptions) filter (where x.kind = 'moved_to_failed'), 0))
  into v_res
  from l
  join cma.subscription_month_take x on x.tenant_id = v_tenant and x.month = l.month and x.currency = '' and x.complete
                                     and (p_market is null or x.market = p_market)
  group by l.month;
  return v_res;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. Grants and settings of the functions
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.assert_subscriptions_filter(uuid,text,uuid,text,text,date,date)',
    'cma.subscriptions_scope_of(uuid,text,uuid,text,text)',
    'cma.subscription_rows_of(uuid,text,uuid,text,text,text,text,boolean,integer,integer,boolean,timestamptz)',
    'cma.subscriptions_page_of(uuid,text,uuid,text,text,date,date,text,text,boolean,timestamptz)',
    'cma.subscriptions_page(text,uuid,text,text,date,date,text,text,boolean)',
    'cma.subscription_rows(text,uuid,text,text,text,text,boolean,integer,integer,boolean)',
    'cma.subscription_file_record(text,text,uuid,text,text,text,integer,date,date)',
    'cma.subscriptions_churn_card(text)'] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
    -- JIT off, as the other report reads (122, section 14): a read of thousands of rows otherwise pays JIT's compilation
    -- on a session's first calls
    execute format('alter function %s set jit = off', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009zh', 'Customers → Subscriptions (brief B39 continued, Part B39d): cma.subscriptions_page (reports.view or performance.team; the take''s state, the filters'' choices, the tiles, the movements and rates per month, the stores'' starts, renewal survival, the mix and the list''s first page, from the subscription facts'' takes), cma.subscription_rows (a page of the list or the file''s rows), cma.subscription_file_record (the audit row of every read that hands out rows: records, months or rows) and cma.subscriptions_churn_card (Customers → Active''s Churn rate card), over cma.assert_subscriptions_filter, cma.subscriptions_scope_of, cma.subscription_rows_of and cma.subscriptions_page_of. No function re-created, no table, view or column changed; nothing in cma_read')
on conflict (version) do nothing;

commit;
reset role;
