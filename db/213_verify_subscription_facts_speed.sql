-- =============================================================================================
-- 213_verify_subscription_facts_speed.sql: verifies addition 0009zf, the subscription facts after their first day in
-- prod (brief B39 continued, the follow-up of Part B39c)
-- =============================================================================================
-- 212 changes no answer, so this script keeps 210's definitions of the four functions 212 re-creates (below, as
-- temporary functions, 210's text) and compares each with 212's, row for row.
--   A  reads only, on every tenant of the database, so it runs in prod too: the addition row after 0009ze and the index
--      212 expects; the functions' settings (no parallel workers on the markers, jit off on the others) and rights; each
--      part of the inputs' markers and both digests equal to 210's; the payment state of every subscription, in both
--      forms, equal to 210's. A comparison whose tables were written between its two reads is read again (three times at
--      most). Two info rows give the plans, read as the application (cma_app, row-level security on): the events'
--      marker and the payment state's latest renewal per subscription, with the index each reads and its heap fetches
--      as a share (info: a small table is read whole, whatever index exists; no count of rows is printed).
--   B  dev and local databases only, as 211: it refuses a database without the dev seed (no active
--      agent.two@example.com); its checks then read FAIL and the verdict REFUSED. On a throwaway tenant inside a
--      subtransaction that is always rolled back: 6,000 events of one write time (a product that passes bigint) and a
--      tenant without a row, each marker equal to 210's; the payment state with every invoice-renewal case (a renewal that
--      names its subscription, one resolved through the customer's one active subscription, one of a customer with two,
--      a paid and an overdue one) equal to 210's in both forms; the refresh after a change of each kind (an outcome new,
--      changed and gone; a subscription new, changed and gone): the five takes equal to what 210's refresh writes from
--      the same rows, the rows that did not change not written again, and the answer's rows and rows_written.
-- Every check writes one row, PASS or FAIL, and the last row is the verdict, because Cloud SQL Studio shows no notices.
-- Run as your own IAM login after 212_subscription_facts_speed.sql; then the verifies 212's header names. Adapters,
-- handles, ids, codes and secret names are invented data values; no row carries a name, an address, an email or a phone
-- number.
-- Provoke: set provoke below to true; every check must then read FAIL, and the verdict says PROVOKED instead. The
-- comparisons are provoked by a deliberate difference, as 133's: 210's side gets one marker's text changed, loses one
-- payment-state row, has one take row changed after its refresh, and one unchanged outcome is written again, so each
-- comparison's detail shows the difference it found.
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
-- dev or a local database only for block B: the dev seed's agent.two@example.com active, as 211
select set_config('verify.dev', (select exists (select 1 from cma.app_user u where u.email = 'agent.two@example.com' and u.status = 'active'))::text, false);

drop table if exists pg_temp.verify_0009zf;
create temp table verify_0009zf (ord int, check_name text, result text, detail text);

-- The error a statement raises as its SQLSTATE, or 'ok'
create or replace function pg_temp.v0009zf_code(p_sql text)
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

-- A plan in one line: the scans of cma.subscription_event with their index, and an index-only scan's heap fetches as a
-- share of the rows it read (a class, never the number: this output goes to records/, and a count of rows read is a
-- volume)
create or replace function pg_temp.v0009zf_plan(p_sql text)
returns text
language plpgsql
as $$
declare
  r      record;
  out    text := '';
  m      text[];
  n_read numeric := 0;
  n_heap numeric;
begin
  for r in execute 'explain (analyze, costs off, timing off, summary off) ' || p_sql loop
    if r."QUERY PLAN" ~ 'Scan .*on subscription_event' then
      m := regexp_match(r."QUERY PLAN", 'actual rows=(\d+) loops=(\d+)');
      n_read := coalesce(m[1]::numeric * m[2]::numeric, 0);
      out := out || case when out = '' then '' else '; ' end
                 || btrim(regexp_replace(regexp_replace(r."QUERY PLAN", '\s*\(actual[^)]*\)', ''), '^\s*(->)?\s*', ''));
    elsif r."QUERY PLAN" ~ 'Heap Fetches' then
      n_heap := (regexp_match(r."QUERY PLAN", 'Heap Fetches: (\d+)'))[1]::numeric;
      out := out || ', heap fetches ' || case when n_heap = 0 then 'none'
                                              when n_heap < 0.01 * n_read then 'under 1 % of the rows read'
                                              when n_heap < 0.1 * n_read then 'under 10 % of the rows read'
                                              else '10 % of the rows read or more (the table''s pages are not marked all visible: vacuum it)' end;
    end if;
  end loop;
  return coalesce(nullif(out, ''), 'no scan of subscription_event');
end
$$;

-- 210's definitions, kept as they were (210_subscription_facts.sql): the inputs' markers, the payment state in both forms
-- and the facts' refresh, which reads the kept payment state so the comparison is 210's from end to end
create or replace function pg_temp.v0009zf_markers_210(p_tenant_id uuid, p_parts text[])
returns text[]
language plpgsql
stable
set parallel_setup_cost = 0
set parallel_tuple_cost = 0
set min_parallel_table_scan_size = 0
as $$
declare
  v_part text;
  v_sql  text;
  v_out  text[] := '{}';
  v      text;
begin
  foreach v_part in array p_parts loop
    v_sql := case v_part
      when 'subscription' then
        'select concat_ws(''@'', count(*), extract(epoch from max(x.synced_at)), sum((extract(epoch from x.synced_at) * 1000000)::bigint))
         from cma.subscription x where x.tenant_id = $1'
      when 'subscription_event' then
        'select concat_ws(''@'', count(*), extract(epoch from max(x.synced_at)), sum((extract(epoch from x.synced_at) * 1000000)::bigint))
         from cma.subscription_event x where x.tenant_id = $1'
      when 'device' then
        'select concat_ws(''@'', count(*), extract(epoch from max(x.synced_at)), sum((extract(epoch from x.synced_at) * 1000000)::bigint))
         from cma.device x where x.tenant_id = $1'
      when 'commerce_customer' then
        'select concat_ws(''@'', count(*), sum(hash_record_extended(row(
              x.id, x.connection_id, x.source_system, x.source_id, x.state, x.locale, x.orders_count, x.amount_spent,
              x.amount_currency, x.source_created_at, x.source_updated_at, x.source_deleted_at, x.phone_hash,
              x.crm_connection_id, x.crm_contact_source_id, x.matched_at), 0)))
         from cma.commerce_customer x where x.tenant_id = $1'
      when 'commerce_order' then
        'select concat_ws(''@'', count(*), sum(hash_record_extended(row(
              x.id, x.connection_id, x.source_system, x.source_id, x.order_name, x.customer_source_id, x.source_created_at,
              x.processed_at, x.source_updated_at, x.cancelled_at, x.cancel_reason, x.is_test, x.currency, x.total_amount,
              x.subtotal_amount, x.tax_amount, x.discount_amount, x.refunded_amount, x.financial_status,
              x.fulfillment_status, x.source_name, x.app_ref, x.landing_host, x.landing_path, x.utm, x.referring_host,
              x.tags, x.prior_orders_count, x.prior_count_exact, x.order_kind, x.source_deleted_at, x.phone_hash), 0)))
         from cma.commerce_order x where x.tenant_id = $1'
      when 'crm_contact' then
        'select concat_ws(''@'', count(*), sum(hash_record_extended(row(
              x.id, x.connection_id, x.source_system, x.source_id, x.country, x.language, x.source_updated_at,
              x.source_deleted_at, x.currency, x.store, x.country_source, x.source_created_at, x.segment), 0)))
         from cma.crm_contact x where x.tenant_id = $1'
      when 'commerce_store' then
        'select concat_ws(''@'', count(*), sum(hash_record_extended(x, 0))) from cma.commerce_store x where x.tenant_id = $1'
      when 'device_status' then
        'select concat_ws(''@'', count(*), sum(hash_record_extended(x, 0))) from cma.device_status x where x.tenant_id = $1'
      when 'device_model' then
        'select concat_ws(''@'', count(*), sum(hash_record_extended(x, 0))) from cma.device_model x where x.tenant_id = $1'
      when 'market' then
        'select concat_ws(''@'', count(*), sum(hash_record_extended(x, 0))) from cma.market x where x.tenant_id = $1'
      when 'integration_connection' then
        'select concat_ws(''@'', count(*), sum(hash_record_extended(row(x.id, x.key, x.adapter, x.kind, x.external_account_id, x.status), 0)))
         from cma.integration_connection x where x.tenant_id = $1'
      when 'timezone' then
        'select t.timezone from cma.tenant t where t.id = $1'
      when 'billing_event' then
        'select concat_ws(''@'', count(*), extract(epoch from max(x.synced_at)), sum((extract(epoch from x.synced_at) * 1000000)::bigint))
         from cma.billing_event x where x.tenant_id = $1'
      when 'subscription_line' then
        'select concat_ws(''@'', count(*), extract(epoch from max(x.synced_at)), sum((extract(epoch from x.synced_at) * 1000000)::bigint))
         from cma.subscription_line x where x.tenant_id = $1'
      when 'subscription_product_variant' then
        'select concat_ws(''@'', count(*), extract(epoch from max(x.synced_at)), sum((extract(epoch from x.synced_at) * 1000000)::bigint))
         from cma.subscription_product_variant x where x.tenant_id = $1'
      when 'subscription_variant_mapping' then
        'select concat_ws(''@'', count(*), sum(hash_record_extended(x, 0))) from cma.subscription_variant_mapping x where x.tenant_id = $1'
      when 'subscription_change' then
        'select concat_ws(''@'', count(*), extract(epoch from max(x.observed_at)), sum((extract(epoch from x.observed_at) * 1000000)::bigint))
         from cma.subscription_change x where x.tenant_id = $1'
      end;
    if v_sql is null then
      raise exception 'Unknown input %', v_part using errcode = 'CMA04';
    end if;
    execute v_sql into v using p_tenant_id;
    v_out := v_out || v;
  end loop;
  return v_out;
end
$$;

create or replace function pg_temp.v0009zf_ps_210(p_tenant_id uuid)
returns table (subscription_id uuid, connection_id uuid, source_id text, customer_source_id text, status text, payment_state text,
               retry_cycle integer, retry_since timestamptz, last_attempt integer, state_since timestamptz, overdue boolean,
               chargeback_return_code text, amount_at_risk numeric, currency text)
language sql stable
rows 10000
as $$
  with s as materialized (
    select s.id, s.connection_id, s.source_id, s.customer_source_id, s.status, s.amount_per_cycle, s.currency, s.paused_at, s.canceled_at
    from cma.subscription s
    where s.tenant_id = p_tenant_id and s.source_deleted_at is null
      and s.status in ('active', 'paused', 'canceled', 'expired', 'failed')
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
  ),
  last_renewal as (
    -- each active or failed subscription's latest renewal (its highest cycle) and that renewal's store order; without a
    -- renewal, its purchase's store order (0009zc)
    select s.id, r.occurred_at, coalesce(r.order_source_id, case when r.source_id is null then p.purchase_order end) as order_source_id
    from s
    left join lateral (
      select e.source_id, e.occurred_at, e.order_source_id from cma.subscription_event e
      where e.tenant_id = p_tenant_id and e.connection_id = s.connection_id and e.subscription_source_id = s.source_id
        and e.event_type = 'renewed' and e.cycle_index is not null
      order by e.cycle_index desc limit 1) r on true
    left join lateral (
      select e.raw ->> 'orderId' as purchase_order from cma.subscription_event e
      where e.tenant_id = p_tenant_id and e.connection_id = s.connection_id and e.subscription_source_id = s.source_id
        and e.event_type = 'purchased' and (e.raw ->> 'orderId') ~ '^\d{1,30}$'
        -- only for a subscription without any renewal (conditions on the outer row: a one-time filter, no scan otherwise)
        and r.source_id is null
        and not exists (select 1 from cma.subscription_event z
                        where z.tenant_id = p_tenant_id and z.connection_id = s.connection_id and z.subscription_source_id = s.source_id
                          and z.event_type = 'renewed')
      order by e.occurred_at, e.source_id collate "C" limit 1) p on true
    where s.status in ('active', 'failed')
  ),
  last_order as (
    select l.id, l.order_source_id from last_renewal l
  ),
  charge as (
    -- the latest chargeback on that order (C.0: linked by the store order; no renewal can follow it, the renewal being
    -- the latest)
    select distinct on (o.id) o.id, b.occurred_at, b.return_code
    from last_order o
    join s on s.id = o.id
    join cma.billing_event b on b.tenant_id = p_tenant_id and b.connection_id = s.connection_id and b.kind = 'chargeback'
                            and b.order_source_id = o.order_source_id
    where o.order_source_id is not null
    order by o.id, b.occurred_at desc, b.source_id collate "C" desc
  ),
  ren as materialized (
    -- the invoice renewals of the active subscriptions' connections, one row per renewal in one pass: the subscription an
    -- event of it names, the customer, the latest invoice placed, and whether a paid or an overdue invoice of it came
    select b.connection_id, b.renewal_source_id,
           max(b.subscription_source_id) as subscription_source_id, min(b.customer_source_id) as customer_source_id,
           max(b.occurred_at) filter (where b.kind = 'invoice_placed') as placed_at,
           bool_or(b.kind = 'invoice_paid') as paid, bool_or(b.kind = 'invoice_overdue') as overdue
    from cma.billing_event b
    where b.tenant_id = p_tenant_id and b.kind in ('invoice_placed', 'invoice_paid', 'invoice_overdue') and b.renewal_source_id is not null
      and b.connection_id in (select s.connection_id from s where s.status = 'active')
    group by b.connection_id, b.renewal_source_id
  ),
  sole as (
    -- a customer's one active subscription of the connection, for a renewal whose events name no subscription
    select x.connection_id, x.customer_source_id, min(x.source_id) as source_id
    from cma.subscription x
    join (select distinct r.connection_id, r.customer_source_id from ren r
          where r.subscription_source_id is null and r.customer_source_id is not null) c
      on c.connection_id = x.connection_id and c.customer_source_id = x.customer_source_id
    where x.tenant_id = p_tenant_id and x.source_deleted_at is null and x.status = 'active'
    group by 1, 2
    having count(*) = 1
  ),
  awaiting as (
    -- an active subscription's latest invoice placed for a renewal that no paid invoice of that renewal followed; overdue
    -- once an overdue invoice of that renewal came
    select distinct on (s.id) s.id, r.placed_at as occurred_at, r.overdue, r.paid
    from ren r
    left join sole o on o.connection_id = r.connection_id and o.customer_source_id = r.customer_source_id and r.subscription_source_id is null
    join s on s.connection_id = r.connection_id and s.source_id = coalesce(r.subscription_source_id, o.source_id) and s.status = 'active'
    where r.placed_at is not null
    order by s.id, r.placed_at desc, r.renewal_source_id collate "C" desc
  ),
  since as (
    -- a failed subscription, and a paused or ended one without its own paused or canceled time: its latest event into
    -- its status
    select s.id, m.at
    from s
    cross join lateral (
      select max(e.occurred_at) as at from cma.subscription_event e
      where e.tenant_id = p_tenant_id and e.connection_id = s.connection_id and e.subscription_source_id = s.source_id
        and e.event_type in ('status_changed', 'canceled', 'paused') and e.status_to = s.status) m
    where s.status = 'failed' or (s.status = 'paused' and s.paused_at is null)
       or (s.status in ('canceled', 'expired') and s.canceled_at is null)
  )
  select s.id, s.connection_id, s.source_id, s.customer_source_id, s.status, x.state,
         d.cycle_index, d.since, d.last_attempt,
         case x.state when 'in_retry' then d.since when 'charged_back' then c.occurred_at when 'awaiting_payment' then a.occurred_at
                      when 'paused' then coalesce(s.paused_at, n.at) when 'canceled' then coalesce(s.canceled_at, n.at)
                      when 'failed' then n.at else lr.occurred_at end,
         case when x.state = 'awaiting_payment' then a.overdue end,
         case when x.state in ('charged_back', 'failed') then c.return_code end,
         case when x.state in ('in_retry', 'failed', 'charged_back') or (x.state = 'awaiting_payment' and a.overdue) then s.amount_per_cycle end,
         s.currency
  from s
  left join retry_detail d on d.connection_id = s.connection_id and d.subscription_source_id = s.source_id
  left join charge c on c.id = s.id
  left join awaiting a on a.id = s.id and not a.paid
  left join since n on n.id = s.id
  left join last_renewal lr on lr.id = s.id
  cross join lateral (
    select case when s.status = 'failed' then 'failed'
                when s.status = 'paused' then 'paused'
                when s.status in ('canceled', 'expired') then 'canceled'
                when d.subscription_source_id is not null then 'in_retry'
                when c.id is not null then 'charged_back'
                when a.id is not null then 'awaiting_payment'
                else 'paid' end as state) x
$$;
alter function pg_temp.v0009zf_ps_210(uuid) set jit = off;

create or replace function pg_temp.v0009zf_ps_210(p_tenant_id uuid, p_subscription_ids uuid[])
returns table (subscription_id uuid, connection_id uuid, source_id text, customer_source_id text, status text, payment_state text,
               retry_cycle integer, retry_since timestamptz, last_attempt integer, state_since timestamptz, overdue boolean,
               chargeback_return_code text, amount_at_risk numeric, currency text)
language sql stable
rows 500   -- a list's page of subscriptions
as $$
  with s as materialized (
    select s.id, s.connection_id, s.source_id, s.customer_source_id, s.status, s.amount_per_cycle, s.currency, s.paused_at, s.canceled_at
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
  ),
  last_renewal as (
    -- each active or failed subscription's latest renewal (its highest cycle) and that renewal's store order; without a
    -- renewal, its purchase's store order (0009zc)
    select s.id, r.occurred_at, coalesce(r.order_source_id, case when r.source_id is null then p.purchase_order end) as order_source_id
    from s
    left join lateral (
      select e.source_id, e.occurred_at, e.order_source_id from cma.subscription_event e
      where e.tenant_id = p_tenant_id and e.connection_id = s.connection_id and e.subscription_source_id = s.source_id
        and e.event_type = 'renewed' and e.cycle_index is not null
      order by e.cycle_index desc limit 1) r on true
    left join lateral (
      select e.raw ->> 'orderId' as purchase_order from cma.subscription_event e
      where e.tenant_id = p_tenant_id and e.connection_id = s.connection_id and e.subscription_source_id = s.source_id
        and e.event_type = 'purchased' and (e.raw ->> 'orderId') ~ '^\d{1,30}$'
        -- only for a subscription without any renewal (conditions on the outer row: a one-time filter, no scan otherwise)
        and r.source_id is null
        and not exists (select 1 from cma.subscription_event z
                        where z.tenant_id = p_tenant_id and z.connection_id = s.connection_id and z.subscription_source_id = s.source_id
                          and z.event_type = 'renewed')
      order by e.occurred_at, e.source_id collate "C" limit 1) p on true
    where s.status in ('active', 'failed')
  ),
  last_order as (
    select l.id, l.order_source_id from last_renewal l
  ),
  charge as (
    -- the latest chargeback on that order (C.0: linked by the store order; no renewal can follow it, the renewal being
    -- the latest)
    select distinct on (o.id) o.id, b.occurred_at, b.return_code
    from last_order o
    join s on s.id = o.id
    join cma.billing_event b on b.tenant_id = p_tenant_id and b.connection_id = s.connection_id and b.kind = 'chargeback'
                            and b.order_source_id = o.order_source_id
    where o.order_source_id is not null
    order by o.id, b.occurred_at desc, b.source_id collate "C" desc
  ),
  ren as materialized (
    -- the invoice renewals of the active subscriptions' connections, one row per renewal in one pass: the subscription an
    -- event of it names, the customer, the latest invoice placed, and whether a paid or an overdue invoice of it came
    select b.connection_id, b.renewal_source_id,
           max(b.subscription_source_id) as subscription_source_id, min(b.customer_source_id) as customer_source_id,
           max(b.occurred_at) filter (where b.kind = 'invoice_placed') as placed_at,
           bool_or(b.kind = 'invoice_paid') as paid, bool_or(b.kind = 'invoice_overdue') as overdue
    from cma.billing_event b
    where b.tenant_id = p_tenant_id and b.kind in ('invoice_placed', 'invoice_paid', 'invoice_overdue') and b.renewal_source_id is not null
      and b.connection_id in (select s.connection_id from s where s.status = 'active')
    group by b.connection_id, b.renewal_source_id
  ),
  sole as (
    -- a customer's one active subscription of the connection, for a renewal whose events name no subscription
    select x.connection_id, x.customer_source_id, min(x.source_id) as source_id
    from cma.subscription x
    join (select distinct r.connection_id, r.customer_source_id from ren r
          where r.subscription_source_id is null and r.customer_source_id is not null) c
      on c.connection_id = x.connection_id and c.customer_source_id = x.customer_source_id
    where x.tenant_id = p_tenant_id and x.source_deleted_at is null and x.status = 'active'
    group by 1, 2
    having count(*) = 1
  ),
  awaiting as (
    -- an active subscription's latest invoice placed for a renewal that no paid invoice of that renewal followed; overdue
    -- once an overdue invoice of that renewal came
    select distinct on (s.id) s.id, r.placed_at as occurred_at, r.overdue, r.paid
    from ren r
    left join sole o on o.connection_id = r.connection_id and o.customer_source_id = r.customer_source_id and r.subscription_source_id is null
    join s on s.connection_id = r.connection_id and s.source_id = coalesce(r.subscription_source_id, o.source_id) and s.status = 'active'
    where r.placed_at is not null
    order by s.id, r.placed_at desc, r.renewal_source_id collate "C" desc
  ),
  since as (
    -- a failed subscription, and a paused or ended one without its own paused or canceled time: its latest event into
    -- its status
    select s.id, m.at
    from s
    cross join lateral (
      select max(e.occurred_at) as at from cma.subscription_event e
      where e.tenant_id = p_tenant_id and e.connection_id = s.connection_id and e.subscription_source_id = s.source_id
        and e.event_type in ('status_changed', 'canceled', 'paused') and e.status_to = s.status) m
    where s.status = 'failed' or (s.status = 'paused' and s.paused_at is null)
       or (s.status in ('canceled', 'expired') and s.canceled_at is null)
  )
  select s.id, s.connection_id, s.source_id, s.customer_source_id, s.status, x.state,
         d.cycle_index, d.since, d.last_attempt,
         case x.state when 'in_retry' then d.since when 'charged_back' then c.occurred_at when 'awaiting_payment' then a.occurred_at
                      when 'paused' then coalesce(s.paused_at, n.at) when 'canceled' then coalesce(s.canceled_at, n.at)
                      when 'failed' then n.at else lr.occurred_at end,
         case when x.state = 'awaiting_payment' then a.overdue end,
         case when x.state in ('charged_back', 'failed') then c.return_code end,
         case when x.state in ('in_retry', 'failed', 'charged_back') or (x.state = 'awaiting_payment' and a.overdue) then s.amount_per_cycle end,
         s.currency
  from s
  left join retry_detail d on d.connection_id = s.connection_id and d.subscription_source_id = s.source_id
  left join charge c on c.id = s.id
  left join awaiting a on a.id = s.id and not a.paid
  left join since n on n.id = s.id
  left join last_renewal lr on lr.id = s.id
  cross join lateral (
    select case when s.status = 'failed' then 'failed'
                when s.status = 'paused' then 'paused'
                when s.status in ('canceled', 'expired') then 'canceled'
                when d.subscription_source_id is not null then 'in_retry'
                when c.id is not null then 'charged_back'
                when a.id is not null then 'awaiting_payment'
                else 'paid' end as state) x
$$;
alter function pg_temp.v0009zf_ps_210(uuid, uuid[]) set jit = off;

create or replace function pg_temp.v0009zf_refresh_210(p_tenant_id uuid, p_force boolean default false, p_now timestamptz default null)
returns jsonb
language plpgsql
as $$
declare
  v_now      timestamptz := coalesce(p_now, clock_timestamp());
  v_t0       timestamptz := clock_timestamp();
  v_zone     text := (select t.timezone from cma.tenant t where t.id = p_tenant_id);
  v_today    date;
  v_month    date;
  v_every    integer := cma.setting_of(p_tenant_id, 'subscriptions.take_refresh_minutes')::integer;
  v_holding  text[] := cma.flash_list_of(cma.setting_of(p_tenant_id, 'flash.device_holding_statuses'));
  v_state    cma.subscription_take_state;
  v_found    boolean;
  v_set_up   boolean;
  v_key      text;
  v_amounts  timestamptz := (select m.applied_at from cma.schema_migration m where m.version = '0009za');
  n_units    integer := 0;
  n_subs     integer := 0;
  n_months   integer := 0;
  n_outcomes integer := 0;
  n_cells    integer := 0;
begin
  if p_tenant_id is distinct from cma.current_tenant_id() then
    raise exception 'a take is refreshed for the current tenant only' using errcode = 'CMA04';
  end if;
  select * into v_state from cma.subscription_take_state t where t.tenant_id = p_tenant_id;
  v_found := found;
  select coalesce(cma.flash_source_set_up_of(p_tenant_id, 'subscriptions'), false) into v_set_up;
  if not v_set_up then
    if v_found then
      if not pg_try_advisory_xact_lock(cma.subscription_facts_lock_key(p_tenant_id)) then
        return jsonb_build_object('refreshed', false, 'reason', 'running');
      end if;
      delete from cma.subscription_survival_take x where x.tenant_id = p_tenant_id;
      delete from cma.renewal_outcome x where x.tenant_id = p_tenant_id;
      delete from cma.subscription_month_take x where x.tenant_id = p_tenant_id;
      delete from cma.subscription_store_start x where x.tenant_id = p_tenant_id;
      delete from cma.subscription_take x where x.tenant_id = p_tenant_id;
      delete from cma.subscription_take_state x where x.tenant_id = p_tenant_id;
    end if;
    return jsonb_build_object('refreshed', false, 'reason', 'not_set_up');
  end if;
  if not p_force and v_found and v_now - v_state.computed_at < make_interval(mins => v_every) then
    return jsonb_build_object('refreshed', false, 'reason', 'fresh');
  end if;
  if not pg_try_advisory_xact_lock(cma.subscription_facts_lock_key(p_tenant_id)) then
    return jsonb_build_object('refreshed', false, 'reason', 'running');
  end if;
  select * into v_state from cma.subscription_take_state t where t.tenant_id = p_tenant_id;
  v_found := found;
  v_today := (v_now at time zone v_zone)::date;
  v_month := date_trunc('month', v_today)::date;
  v_key := cma.subscription_facts_inputs_key_of(p_tenant_id, v_today);
  if not p_force and v_found and v_state.inputs_key = v_key then
    update cma.subscription_take_state t
    set computed_at = v_now, duration_ms = (extract(epoch from clock_timestamp() - v_t0) * 1000)::integer
    where t.tenant_id = p_tenant_id;
    return jsonb_build_object('refreshed', true, 'unchanged', true, 'rows', 0,
                              'duration_ms', (extract(epoch from clock_timestamp() - v_t0) * 1000)::integer);
  end if;

  -- 1. device units (C.1): computed once, written to the mirror where they read differently (step 3 reads them from here)
  create temporary table if not exists subscription_facts_units (subscription_id uuid primary key, device_units integer, propositions text[],
                                                                  models text[]) on commit drop;
  delete from subscription_facts_units;
  insert into subscription_facts_units select * from cma.subscription_device_units_of(p_tenant_id);
  update cma.subscription x
  set device_units = u.device_units
  from subscription_facts_units u
  where x.tenant_id = p_tenant_id and x.id = u.subscription_id and x.device_units is distinct from u.device_units;
  get diagnostics n_units = row_count;

  -- 2. renewal outcomes (C.3), first: the subscriptions' renewals are counted from them
  delete from cma.renewal_outcome x where x.tenant_id = p_tenant_id;
  insert into cma.renewal_outcome (tenant_id, connection_id, subscription_source_id, renewal_key, cycle_index, renewal_source_id, first_attempt_at,
                                   outcome, attempts, recovered_at, days_to_recover, error_code, instrument_type,
                                   payment_method_changed_before_recovery)
  select p_tenant_id, r.* from cma.renewal_outcomes_of(p_tenant_id) r;
  get diagnostics n_outcomes = row_count;

  -- 3. per subscription
  delete from cma.subscription_take x where x.tenant_id = p_tenant_id;
  insert into cma.subscription_take (tenant_id, subscription_id, connection_id, source_id, market, status, payment_state, state_since, overdue,
                                     chargeback_return_code, amount_at_risk, currency, monthly_amount, interval_group, device_units,
                                     propositions, models, original_start_at, original_start_basis, cohort_month, migrated, renewals)
  with sm as materialized (
    select y.connection_id, y.store_connection_id, y.market from cma.flash_subscription_stores_of(p_tenant_id) y
  ), ps as materialized (
    select * from pg_temp.v0009zf_ps_210(p_tenant_id)
  ), du as materialized (
    select * from subscription_facts_units
  ), mig as materialized (
    select distinct e.connection_id, e.subscription_source_id
    from cma.subscription_event e
    where e.tenant_id = p_tenant_id and e.event_type = 'migrated'
  ), ren as materialized (
    -- the cycles renewed (step 2's outcomes that renewed)
    select r.connection_id, r.subscription_source_id, count(*) as renewals
    from cma.renewal_outcome r
    where r.tenant_id = p_tenant_id and r.cycle_index is not null and r.outcome in ('paid_first_attempt', 'recovered', 'charged_back')
    group by 1, 2
  ), fo as materialized (
    -- the store customer's earliest store order (not a test, not deleted), per store and customer
    select o.connection_id, o.customer_source_id, min(o.source_created_at) as first_at
    from cma.commerce_order o
    where o.tenant_id = p_tenant_id and o.is_test is not true and o.source_deleted_at is null and o.customer_source_id is not null
      and o.connection_id in (select sm.store_connection_id from sm)
    group by 1, 2
  ), b as (
    select x.id, x.connection_id, x.source_id, coalesce(sm.market, 'unknown') as market, x.status, ps.payment_state, ps.state_since, ps.overdue,
           ps.chargeback_return_code, ps.amount_at_risk, x.currency,
           x.amount_per_cycle * cma.active_month_factor_of(x.billing_interval, x.billing_interval_count) as monthly_amount,
           cma.subscription_interval_group_of(x.billing_interval, x.billing_interval_count) as interval_group,
           du.device_units, coalesce(du.propositions, '{}') as propositions, coalesce(du.models, '{}') as models,
           case when fo.first_at <= x.source_created_at then fo.first_at else x.source_created_at end as original_start_at,
           case when fo.first_at <= x.source_created_at then 'first_order' when x.source_created_at is not null then 'created' end as basis,
           mig.subscription_source_id is not null as migrated, coalesce(ren.renewals, 0)::integer as renewals
    from cma.subscription x
    left join sm on sm.connection_id = x.connection_id
    left join ps on ps.subscription_id = x.id
    left join du on du.subscription_id = x.id
    left join mig on mig.connection_id = x.connection_id and mig.subscription_source_id = x.source_id
    left join ren on ren.connection_id = x.connection_id and ren.subscription_source_id = x.source_id
    left join fo on fo.connection_id = sm.store_connection_id and fo.customer_source_id = x.customer_source_id
    where x.tenant_id = p_tenant_id and x.source_deleted_at is null
  )
  select p_tenant_id, b.id, b.connection_id, b.source_id, b.market, b.status, b.payment_state, b.state_since, b.overdue,
         b.chargeback_return_code, b.amount_at_risk, b.currency, b.monthly_amount, b.interval_group, b.device_units, b.propositions, b.models,
         b.original_start_at, b.basis, date_trunc('month', b.original_start_at at time zone v_zone)::date, b.migrated, b.renewals
  from b;
  get diagnostics n_subs = row_count;

  -- 4a. when each store's rates start (C.5)
  delete from cma.subscription_store_start x where x.tenant_id = p_tenant_id;
  insert into cma.subscription_store_start (tenant_id, connection_id, market, first_event_month, migration_months, last_migration_month,
                                            straggler_months, stragglers, rate_start_month)
  select p_tenant_id, r.connection_id, coalesce(sm.market, 'unknown'), r.first_event_month, r.migration_months, r.last_migration_month,
         r.straggler_months, r.stragglers, r.rate_start_month
  from cma.subscription_rate_start_of(p_tenant_id, v_now) r
  left join (select y.connection_id, y.market from cma.flash_subscription_stores_of(p_tenant_id) y) sm on sm.connection_id = r.connection_id;

  -- 4. per store and month (C.4, C.5): the status moves, the base at each month's start and end, the observed amount
  --    changes; months from the store's first event to the current one
  delete from cma.subscription_month_take x where x.tenant_id = p_tenant_id;
  insert into cma.subscription_month_take (tenant_id, connection_id, market, month, kind, currency, subscriptions, amount, complete)
  with sm as materialized (
    select y.connection_id, y.market from cma.flash_subscription_stores_of(p_tenant_id) y
  ), mv as materialized (
    select * from cma.subscription_moves_of(p_tenant_id, v_now)
  ), first_ev as materialized (
    -- the store's first event's month and the month its rates start (step 4a)
    select x.connection_id, x.first_event_month as first_month, x.rate_start_month as first_complete
    from cma.subscription_store_start x
    where x.tenant_id = p_tenant_id
  ), months as materialized (
    select f.connection_id, g::date as month, f.first_complete
    from first_ev f
    cross join lateral generate_series(f.first_month, v_month, interval '1 month') g
  ), spans as materialized (
    -- each subscription's status from each move to the next
    select m.subscription_id, m.connection_id, m.status_to as status, m.at as from_at,
           lead(m.at) over (partition by m.subscription_id order by m.at, m.kind nulls first) as to_at
    from mv m
  ), x as materialized (
    select s.id, s.connection_id, s.source_id, s.amount_per_cycle, s.currency, s.billing_interval, s.billing_interval_count
    from cma.subscription s where s.tenant_id = p_tenant_id and s.source_deleted_at is null
  ), lc as materialized (
    -- each subscription's latest observed change of its amount, interval or currency: before it the amount is taken back
    -- through the changes (cma.subscription_amount_at), after it (or without one) it is the stored one
    select c.connection_id, c.subscription_source_id, max(c.observed_at) as last_at
    from cma.subscription_change c
    where c.tenant_id = p_tenant_id and c.field in ('amount_per_cycle', 'billing_interval', 'billing_interval_count', 'currency')
    group by 1, 2
  ), af as materialized (
    -- amounts are known from each connection's first load on (rule 12): the later of the observed changes' start (0009za)
    -- and the first time the CMA held a subscription of the connection
    select s.connection_id, greatest(v_amounts, min(s.first_seen_at)) as amounts_from
    from cma.subscription s where s.tenant_id = p_tenant_id
    group by 1
  ), bounds as materialized (
    select mo.connection_id, mo.month, k.kind, k.boundary
    from months mo
    cross join lateral (values ('start', (mo.month::timestamp at time zone v_zone)),
                               ('end', least(((mo.month + interval '1 month')::timestamp at time zone v_zone), v_now))) k(kind, boundary)
  ), base_counts as (
    -- the Total subscriptions (a device-holding status) at each month's start and end: a running sum per store over the
    -- spans in such a status, +1 where one begins, -1 where it ends, read at each boundary before the changes at its
    -- moment (the status just before it: a move at the very start of a month is that month's movement)
    select r.connection_id, r.month, r.kind, r.n
    from (
      select z.connection_id, z.month, z.kind,
             sum(z.d) over (partition by z.connection_id order by z.at, z.kind nulls last rows between unbounded preceding and current row) as n
      from (
        select sp.connection_id, sp.from_at as at, 1 as d, null::text as kind, null::date as month
        from spans sp where sp.status = any (v_holding)
        union all
        select sp.connection_id, sp.to_at, -1, null, null
        from spans sp where sp.status = any (v_holding) and sp.to_at is not null
        union all
        select b.connection_id, b.boundary, 0, b.kind, b.month from bounds b
      ) z
    ) r
    where r.kind is not null
  ), base as (
    -- the members of the Total subscriptions at the boundaries from the first load on, for their monthly amounts
    select b.connection_id, b.month, b.kind, sp.subscription_id, b.boundary
    from bounds b
    join spans sp on sp.connection_id = b.connection_id and sp.from_at < b.boundary and (sp.to_at is null or sp.to_at >= b.boundary)
                 and sp.status = any (v_holding)
    join af on af.connection_id = b.connection_id
    where v_amounts is not null and b.boundary >= af.amounts_from
  ), moved as (
    select m.connection_id, (date_trunc('month', m.at at time zone v_zone))::date as month, m.kind, m.subscription_id,
           case when m.kind in ('new', 'migrated', 'reactivated', 'resumed') then m.at else m.at - interval '1 microsecond' end as boundary
    from mv m
    where m.kind is not null
  ), amounted as (
    -- the observed changes of amount or interval (C.4): expansion or contraction where the monthly amount rose or fell
    -- in one currency, without a status move observed in the same read
    select c.connection_id, x.id as subscription_id, c.observed_at
    from cma.subscription_change c
    join x on x.connection_id = c.connection_id and x.source_id = c.subscription_source_id
    where c.tenant_id = p_tenant_id and c.field in ('amount_per_cycle', 'billing_interval', 'billing_interval_count') and c.observed_at <= v_now
      and not exists (select 1 from cma.subscription_change z
                      where z.tenant_id = p_tenant_id and z.connection_id = c.connection_id and z.subscription_source_id = c.subscription_source_id
                        and z.field = 'status' and z.observed_at = c.observed_at)
    group by 1, 2, 3
  ), changed as (
    select a.connection_id, (date_trunc('month', a.observed_at at time zone v_zone))::date as month,
           case when after.monthly_amount > before.monthly_amount then 'expansion' else 'contraction' end as kind,
           a.subscription_id, after.currency, abs(after.monthly_amount - before.monthly_amount) as amount
    from amounted a
    join x on x.id = a.subscription_id
    cross join lateral cma.subscription_amount_at(p_tenant_id, a.connection_id, x.source_id, a.observed_at - interval '1 microsecond',
                                                  x.amount_per_cycle, x.currency, x.billing_interval, x.billing_interval_count) before
    cross join lateral cma.subscription_amount_at(p_tenant_id, a.connection_id, x.source_id, a.observed_at,
                                                  x.amount_per_cycle, x.currency, x.billing_interval, x.billing_interval_count) after
    where before.currency = after.currency and before.monthly_amount is distinct from after.monthly_amount
      and before.monthly_amount is not null and after.monthly_amount is not null
  ), counted as (
    select b.connection_id, b.month, b.kind, b.subscription_id, b.boundary from base b
    union all
    select m.connection_id, m.month, m.kind, m.subscription_id, m.boundary from moved m
  ), valued as (
    select c.connection_id, c.month, c.kind, c.subscription_id,
           case when l.last_at > c.boundary then am.currency else x.currency end as currency,
           case when l.last_at > c.boundary then am.monthly_amount
                else x.amount_per_cycle * cma.active_month_factor_of(x.billing_interval, x.billing_interval_count) end as monthly_amount
    from counted c
    join x on x.id = c.subscription_id
    left join lc l on l.connection_id = x.connection_id and l.subscription_source_id = x.source_id
    left join lateral (select y.* from cma.subscription_amount_at(p_tenant_id, c.connection_id, x.source_id, c.boundary,
                                                                  x.amount_per_cycle, x.currency, x.billing_interval, x.billing_interval_count) y
                       where l.last_at > c.boundary) am on true
    join af on af.connection_id = c.connection_id
    where v_amounts is not null and c.boundary >= af.amounts_from
    union all
    select ch.connection_id, ch.month, ch.kind, ch.subscription_id, ch.currency, ch.amount from changed ch
  ), rows_ as (
    select bc.connection_id, bc.month, bc.kind, ''::text as currency, bc.n::integer as n, null::numeric as amount
    from base_counts bc
    union all
    select m.connection_id, m.month, m.kind, '', count(*)::integer, null from moved m group by 1, 2, 3
    union all
    select ch.connection_id, ch.month, ch.kind, '', count(*)::integer, null from changed ch group by 1, 2, 3
    union all
    select v.connection_id, v.month, v.kind, v.currency, count(*)::integer, round(sum(v.monthly_amount), 2)
    from valued v where v.currency is not null and v.monthly_amount is not null
    group by 1, 2, 3, 4
  )
  select p_tenant_id, r.connection_id, coalesce(sm.market, 'unknown'), r.month, r.kind, r.currency, r.n, r.amount,
         r.month < v_month and r.month >= f.first_complete
  from rows_ r
  join first_ev f on f.connection_id = r.connection_id
  left join sm on sm.connection_id = r.connection_id
  where r.month >= f.first_month and r.month <= v_month;
  get diagnostics n_months = row_count;

  -- 5. renewal survival (C.6): subscriptions purchased in the app (not migrated) by start cohort and interval group; the
  --    start is the subscription's own in the app (its created date), never the estimated original start, whose first
  --    store order may be another subscription's of the same customer
  delete from cma.subscription_survival_take x where x.tenant_id = p_tenant_id;
  insert into cma.subscription_survival_take (tenant_id, connection_id, market, cohort_month, interval_group, renewal_number, started, eligible, survived)
  select p_tenant_id, t.connection_id, t.market, date_trunc('month', s.source_created_at at time zone v_zone)::date, t.interval_group, n.n, count(*)::integer,
         count(*) filter (where s.source_created_at + make_interval(
                                   months => case s.billing_interval when 'month' then s.billing_interval_count * n.n
                                                                     when 'year' then 12 * s.billing_interval_count * n.n else 0 end,
                                   days => case s.billing_interval when 'day' then s.billing_interval_count * n.n
                                                                   when 'week' then 7 * s.billing_interval_count * n.n else 0 end) <= v_now)::integer,
         count(*) filter (where t.renewals >= n.n)::integer
  from cma.subscription_take t
  join cma.subscription s on s.tenant_id = t.tenant_id and s.id = t.subscription_id
  cross join generate_series(1, 24) n(n)
  where t.tenant_id = p_tenant_id and not t.migrated and s.source_created_at is not null and s.billing_interval is not null
    and s.billing_interval_count is not null
  group by t.connection_id, t.market, date_trunc('month', s.source_created_at at time zone v_zone)::date, t.interval_group, n.n;
  get diagnostics n_cells = row_count;

  -- 6. the take's row
  insert into cma.subscription_take_state as t (tenant_id, computed_at, business_date, duration_ms, inputs_key, subscriptions, amounts_from)
  values (p_tenant_id, v_now, v_today, (extract(epoch from clock_timestamp() - v_t0) * 1000)::integer, v_key, n_subs, v_amounts)
  on conflict (tenant_id) do update
    set computed_at = excluded.computed_at, business_date = excluded.business_date, duration_ms = excluded.duration_ms,
        inputs_key = excluded.inputs_key, subscriptions = excluded.subscriptions, amounts_from = excluded.amounts_from;

  return jsonb_build_object('refreshed', true, 'unchanged', false, 'device_units_written', n_units, 'subscription_rows', n_subs,
                            'month_rows', n_months, 'outcome_rows', n_outcomes, 'survival_rows', n_cells,
                            'rows', n_subs + n_months + n_outcomes + n_cells,
                            'duration_ms', (extract(epoch from clock_timestamp() - v_t0) * 1000)::integer);
end
$$;
alter function pg_temp.v0009zf_refresh_210(uuid, boolean, timestamptz) set jit = off;

-- A. Structure, rights and equality on the database's own data (reads only)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_parts   text[] := array['subscription', 'subscription_event', 'device', 'commerce_customer', 'commerce_order', 'crm_contact', 'commerce_store',
                            'device_status', 'device_model', 'market', 'integration_connection', 'timezone', 'billing_event', 'subscription_line',
                            'subscription_product_variant', 'subscription_variant_mapping', 'subscription_change'];
  v_active  text[] := array['subscription', 'subscription_event', 'device', 'commerce_customer', 'commerce_order', 'crm_contact', 'commerce_store',
                            'device_status', 'device_model', 'market', 'integration_connection', 'timezone', 'billing_event'];
  v_facts   text[] := array['subscription', 'subscription_event', 'commerce_order', 'commerce_store', 'device_model', 'market', 'integration_connection',
                            'timezone', 'billing_event', 'subscription_line', 'subscription_product_variant', 'subscription_variant_mapping',
                            'subscription_change'];
  t         record;
  v_txt     text;
  v_new     text[];
  v_old     text[];
  v_bad     text;
  v_today   date;
  n_diff    bigint;
  n_subs    bigint;
  i         integer;
begin
  -- A1. the addition is recorded, after 0009ze; the index 212 expects is there and valid
  v_txt := (select string_agg(m.version, ',' order by m.version collate "C") from cma.schema_migration m where m.version in ('0009ze', '0009zf'))
           || ' | ' || coalesce((select string_agg(c.relname || ':' || i2.indisvalid || ':' || substring(pg_get_indexdef(i2.indexrelid) from 'USING .*$'), ' ' order by c.relname collate "C")
                                 from pg_index i2 join pg_class c on c.oid = i2.indexrelid
                                 where i2.indrelid = 'cma.subscription_event'::regclass and c.relname = 'subscription_event_synced_idx'), 'no index');
  insert into verify_0009zf values (1, 'A1 addition 0009zf recorded, after 0009ze; the index subscription_event_synced_idx valid, on the tenant and the write time',
    case when v_txt = '0009ze,0009zf | subscription_event_synced_idx:true:USING btree (tenant_id, synced_at)' and not v_provoke then 'PASS' else 'FAIL' end, v_txt);

  -- A2. the settings of the four functions and their rights: the application's and no one else's
  select string_agg(p.proname || '(' || p.pronargs || '):' || coalesce(array_to_string(p.proconfig, ','), '-')
                    || ':' || has_function_privilege('cma_app', p.oid, 'execute') || '/' || has_function_privilege('cma_readonly', p.oid, 'execute')
                    || '/' || has_function_privilege('public', p.oid, 'execute') || ':' || p.prosecdef, ' ' order by p.proname collate "C", p.pronargs)
  into v_txt
  from pg_proc p
  where p.pronamespace = 'cma'::regnamespace
    and p.proname in ('inputs_markers_of', 'subscription_payment_state_of', 'subscription_facts_refresh_of');
  insert into verify_0009zf values (2, 'A2 no parallel workers on the markers and no parallel costs left, jit off on the payment state and the refresh; the application''s and no one else''s, the caller''s rights',
    case when v_txt = 'inputs_markers_of(2):max_parallel_workers_per_gather=0:true/false/false:false subscription_facts_refresh_of(3):jit=off:true/false/false:false subscription_payment_state_of(1):jit=off:true/false/false:false subscription_payment_state_of(2):jit=off:true/false/false:false'
              and not v_provoke then 'PASS' else 'FAIL' end, v_txt);

  -- A3. the inputs' markers: each part's text 210's, and both digests, on every tenant (read again when a table was
  --     written between the reads)
  v_txt := ''; v_bad := '';
  for t in select x.id, x.slug, x.timezone from cma.tenant x order by x.slug collate "C" loop
    perform set_config('app.tenant_id', t.id::text, true);
    v_today := (now() at time zone t.timezone)::date;
    for i in 1 .. 3 loop
      v_new := cma.inputs_markers_of(t.id, v_parts);
      v_old := pg_temp.v0009zf_markers_210(t.id, v_parts);
      if v_provoke then v_old[2] := v_old[2] || 'x'; end if;   -- provoked: 210's events marker reads differently
      exit when v_new = v_old;
    end loop;
    n_diff := (select count(*) from generate_series(1, cardinality(v_parts)) g where v_new[g] is distinct from v_old[g]);
    if n_diff > 0 then
      v_bad := v_bad || ' ' || t.slug || ':' || (select string_agg(v_parts[g], ',') from generate_series(1, cardinality(v_parts)) g where v_new[g] is distinct from v_old[g]);
    end if;
    for i in 1 .. 3 loop
      n_diff := (cma.active_inputs_key_of(t.id) is distinct from md5(array_to_string(pg_temp.v0009zf_markers_210(t.id, v_active), '|')
                                                                     || case when v_provoke then 'x' else '' end))::integer
              + (cma.subscription_facts_inputs_key_of(t.id, v_today) is distinct from md5(concat_ws('|',
                   array_to_string(pg_temp.v0009zf_markers_210(t.id, v_facts), '|'),
                   cma.setting_of(t.id, 'flash.ended_subscription_statuses'), cma.setting_of(t.id, 'flash.device_holding_statuses'),
                   cma.setting_of(t.id, 'subscriptions.propositions'), cma.setting_of(t.id, 'subscriptions.migration_bulk_min_pct'),
                   v_today::text)))::integer;
      exit when n_diff = 0;
    end loop;
    if n_diff > 0 then v_bad := v_bad || ' ' || t.slug || ':digests'; end if;
    v_txt := v_txt || case when v_txt = '' then '' else ' ' end || t.slug || ':' || cardinality(v_parts) || ' parts, 2 digests';
  end loop;
  perform set_config('app.tenant_id', '', true);
  insert into verify_0009zf values (3, 'A3 the inputs'' markers: each of the seventeen parts 210''s text, Customers → Active''s digest and the facts'' digest 210''s, every tenant',
    case when v_bad = '' and v_txt <> '' and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_bad = '' then 'equal: ' || v_txt else 'differing:' || v_bad end);

  -- A4. the payment state equals 210's row for row, every tenant: every subscription, and a list's page (the first 500
  --     by id, and every seventh subscription)
  v_txt := ''; v_bad := '';
  for t in select x.id, x.slug from cma.tenant x order by x.slug collate "C" loop
    perform set_config('app.tenant_id', t.id::text, true);
    for i in 1 .. 3 loop
      select count(*) filter (where a.t is distinct from b.t), count(*) into n_diff, n_subs
      from (select n.subscription_id, n::text as t from cma.subscription_payment_state_of(t.id) n) a
      full join (select o.subscription_id, o::text as t from pg_temp.v0009zf_ps_210(t.id) o
                 offset case when v_provoke then 1 else 0 end) b using (subscription_id);   -- provoked: 210's side loses a row
      exit when n_diff = 0;
    end loop;
    v_txt := v_txt || case when v_txt = '' then '' else ' ' end || t.slug || ':' || n_diff;
    if n_diff > 0 then v_bad := v_bad || ' ' || t.slug || ':all'; end if;
    for i in 1 .. 3 loop
      select count(*) filter (where a.t is distinct from b.t) into n_diff
      from (select n.subscription_id, n::text as t
            from cma.subscription_payment_state_of(t.id, array(select x.id from cma.subscription x where x.tenant_id = t.id order by x.id limit 500)) n) a
      full join (select o.subscription_id, o::text as t
                 from pg_temp.v0009zf_ps_210(t.id, array(select x.id from cma.subscription x where x.tenant_id = t.id order by x.id limit 500)) o
                 offset case when v_provoke then 1 else 0 end) b
        using (subscription_id);
      exit when n_diff = 0;
    end loop;
    v_txt := v_txt || '/' || n_diff;
    if n_diff > 0 then v_bad := v_bad || ' ' || t.slug || ':page'; end if;
    for i in 1 .. 3 loop
      select count(*) filter (where a.t is distinct from b.t) into n_diff
      from (select n.subscription_id, n::text as t
            from cma.subscription_payment_state_of(t.id, array(select q.id from (select x.id, row_number() over (order by x.id) as rn
                                                                                   from cma.subscription x where x.tenant_id = t.id) q
                                                               where q.rn % 7 = 0 limit 2000)) n) a
      full join (select o.subscription_id, o::text as t
                 from pg_temp.v0009zf_ps_210(t.id, array(select q.id from (select x.id, row_number() over (order by x.id) as rn
                                                                            from cma.subscription x where x.tenant_id = t.id) q
                                                        where q.rn % 7 = 0 limit 2000)) o
                 offset case when v_provoke then 1 else 0 end) b
        using (subscription_id);
      exit when n_diff = 0;
    end loop;
    v_txt := v_txt || '/' || n_diff || case when n_subs > 0 then '/subscriptions' else '/none' end;
    if n_diff > 0 then v_bad := v_bad || ' ' || t.slug || ':spread'; end if;
  end loop;
  perform set_config('app.tenant_id', '', true);
  insert into verify_0009zf values (4, 'A4 the payment state equals 210''s row for row, every tenant: every subscription, the first 500 by id and every seventh (differing/differing/differing)',
    case when v_bad = '' and v_txt <> '' and not v_provoke then 'PASS' else 'FAIL' end, v_txt);

  -- A5. an unknown input is still refused (CMA04)
  v_txt := pg_temp.v0009zf_code('select cma.inputs_markers_of(gen_random_uuid(), array[''orders''])');
  insert into verify_0009zf values (5, 'A5 an unknown input is refused (CMA04)',
    case when v_txt = 'CMA04' and not v_provoke then 'PASS' else 'FAIL' end, v_txt);

  -- I1, I2. the plans, for information, on the tenant with the most events: the events' marker, and the latest renewal
  --         per subscription (the payment state's last_renewal)
  select e.tenant_id into t from cma.subscription_event e group by e.tenant_id order by count(*) desc, e.tenant_id limit 1;
  if t.tenant_id is null then
    insert into verify_0009zf values (6, 'I1 the plan of the events'' marker', 'info', 'no tenant holds an event');
    insert into verify_0009zf values (7, 'I2 the plan of the latest renewal per subscription', 'info', 'no tenant holds an event');
  else
    v_txt := current_setting('max_parallel_workers_per_gather');
    perform set_config('max_parallel_workers_per_gather', '0', true);   -- as the function sets it
    perform set_config('app.tenant_id', t.tenant_id::text, true);
    perform set_config('role', 'cma_app', true);                         -- the application's plans: row-level security on
    v_bad := pg_temp.v0009zf_plan(format('select x.synced_at as at, count(*)::numeric as n from cma.subscription_event x where x.tenant_id = %L group by x.synced_at', t.tenant_id));
    perform set_config('role', 'cma_owner', true);
    insert into verify_0009zf values (6, 'I1 the plan of the events'' marker, as the application (subscription_event_synced_idx, index only, where the table is large enough)', 'info', v_bad);
    perform set_config('role', 'cma_app', true);
    v_bad := pg_temp.v0009zf_plan(format(
        'with s as materialized (
           select s.id, s.connection_id, s.source_id, s.status from cma.subscription s
           where s.tenant_id = %1$L and s.source_deleted_at is null and s.status in (''active'', ''paused'', ''canceled'', ''expired'', ''failed''))
         select s.id, r.occurred_at, r.order_source_id from s
         left join lateral (select e.source_id, e.occurred_at, e.order_source_id from cma.subscription_event e
                            where e.tenant_id = %1$L and e.connection_id = s.connection_id and e.subscription_source_id = s.source_id
                              and e.event_type = ''renewed'' and e.cycle_index is not null
                            order by e.cycle_index desc limit 1) r on true
         where s.status in (''active'', ''failed'')', t.tenant_id));
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.tenant_id', '', true);
    insert into verify_0009zf values (7, 'I2 the plan of the payment state''s latest renewal per subscription, as the application (subscription_event_renewal_order_idx, index only, where that index exists)', 'info',
      coalesce((select 'the index exists, valid ' || i2.indisvalid from pg_index i2 join pg_class c on c.oid = i2.indexrelid
                where i2.indrelid = 'cma.subscription_event'::regclass and c.relname = 'subscription_event_renewal_order_idx'), 'the index does not exist')
      || ': ' || v_bad);
    perform set_config('max_parallel_workers_per_gather', v_txt, true);
  end if;
end
$$;

-- B. Behaviour on a throwaway tenant (rolled back)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_dev     boolean := current_setting('verify.dev')::boolean;
  v_rows    text[] := '{}';
  v_parts   text[] := array['subscription', 'subscription_event', 'device', 'commerce_customer', 'commerce_order', 'crm_contact', 'commerce_store',
                            'device_status', 'device_model', 'market', 'integration_connection', 'timezone', 'billing_event', 'subscription_line',
                            'subscription_product_variant', 'subscription_variant_mapping', 'subscription_change'];
  v_t uuid; v_e uuid; v_sch uuid; v_shop uuid; v_sub uuid;
  v_m0 timestamp := date_trunc('month', now() at time zone 'Europe/London') - interval '6 months';
  v_now timestamptz := now();
  v_txt text; v_j jsonb; v_j2 jsonb; v_d212 text; v_d210 text;
  n_o_same bigint; n_o_moved bigint; n_o_new bigint; n_o_changed bigint; n_o_gone bigint;
  n_s_same bigint; n_s_moved bigint; n_s_new bigint; n_s_changed bigint; n_s_gone bigint;
begin
  if not v_dev then
    insert into verify_0009zf values (59, 'B a dev or local database (the dev seed''s agent.two@example.com active)', 'FAIL',
      'REFUSED: no dev seed, so this is no dev or local database; nothing ran');
    return;
  end if;
  begin
    v_t := cma.create_tenant('verify-0009zf', 'Verify 0009zf', 'Europe/London');
    v_e := cma.create_tenant('verify-0009zf-empty', 'Verify 0009zf empty', 'Europe/London');
    perform set_config('app.tenant_id', v_t::text, true);
    select u.id into v_sch from cma.app_user u where u.tenant_id = v_t and u.kind = 'system' and u.email = 'scheduler@system.invalid';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, signing_secret_name)
    values (v_t, 'verifyshop', 'Verify shop', 'verify-zf.shop.example', 'commerce', 'verify-zf-shop-1') returning id into v_shop;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t, 'verifysubs', 'Verify subscriptions', 'verify-zf.shop.example', 'subscriptions', 'verify-zf-key-1') returning id into v_sub;
    insert into cma.commerce_store (tenant_id, connection_id, handle, name, market, currency, time_zone)
    values (v_t, v_shop, 'verify-zf', 'Verify store', 'IE', 'EUR', 'Europe/London');
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency)
    values (v_t, 'IE', 'Verify IE', 'Europe/London', 'en', 'EUR') on conflict do nothing;

    -- nine subscriptions (a tenth comes with the changes below): s7 and s8 share a customer; s9 holds 6,000 renewals, all written at one time
    insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, billing_interval,
                                  billing_interval_count, amount_per_cycle, currency, source_created_at, source_updated_at)
    select v_t, v_sub, 'verifysubs', 's' || n, 'c' || least(n, 7) || case when n = 9 then 'x' else '' end, 'active', 'month', 1, 30, 'EUR',
           (v_m0 + interval '1 day') at time zone 'Europe/London', (v_m0 + interval '1 day') at time zone 'Europe/London'
    from generate_series(1, 9) n;
    insert into cma.subscription_event (tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type, occurred_at,
                                        cycle_index, attempt, error_code, order_source_id, raw, synced_at)
    values
      (v_t, v_sub, 'verifysubs', 'r1-1', 's1', 'renewed', (v_m0 + interval '1 month 1 day') at time zone 'Europe/London', 1, null, null, '1001', '{}', v_now - interval '3 hours'),
      (v_t, v_sub, 'verifysubs', 'r1-2', 's1', 'renewed', (v_m0 + interval '2 months 1 day') at time zone 'Europe/London', 2, null, null, '1002', '{}', v_now - interval '2 hours'),
      (v_t, v_sub, 'verifysubs', 'f2-1', 's2', 'renew_failed', (v_m0 + interval '1 month 1 day') at time zone 'Europe/London', 1, 1, 'INSUFFICIENT_FUNDS', null, '{}', v_now - interval '2 hours'),
      (v_t, v_sub, 'verifysubs', 'r2-1', 's2', 'renewed', (v_m0 + interval '1 month 4 days') at time zone 'Europe/London', 1, null, null, '2001', '{}', v_now - interval '1 hour'),
      (v_t, v_sub, 'verifysubs', 'f3-1', 's3', 'renew_failed', (v_m0 + interval '1 month 1 day') at time zone 'Europe/London', 1, 1, 'CARD_DECLINED', null, '{}', v_now - interval '1 hour'),
      (v_t, v_sub, 'verifysubs', 'p4', 's4', 'purchased', (v_m0 + interval '1 day') at time zone 'Europe/London', null, null, null, null, '{"orderId": "9004"}', v_now - interval '1 hour');
    insert into cma.subscription_event (tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type, occurred_at,
                                        cycle_index, order_source_id)
    select v_t, v_sub, 'verifysubs', 'r9-' || n, 's9', 'renewed', (v_m0 at time zone 'Europe/London') + make_interval(mins => n), n, (500000 + n)::text
    from generate_series(1, 6000) n;
    insert into cma.billing_event (tenant_id, connection_id, source_system, source_id, kind, occurred_at, subscription_source_id, customer_source_id,
                                   order_source_id, renewal_source_id, return_code)
    values
      (v_t, v_sub, 'verifysubs', 'cb4', 'chargeback', (v_m0 + interval '9 days') at time zone 'Europe/London', null, null, '9004', null, 'MD06'),
      (v_t, v_sub, 'verifysubs', 'ip5a', 'invoice_placed', (v_m0 + interval '1 month 4 days') at time zone 'Europe/London', 's5', 'c5', null, 'ra', null),
      (v_t, v_sub, 'verifysubs', 'ipd5a', 'invoice_paid', (v_m0 + interval '1 month 6 days') at time zone 'Europe/London', 's5', 'c5', null, 'ra', null),
      (v_t, v_sub, 'verifysubs', 'ip5b', 'invoice_placed', (v_m0 + interval '2 months 4 days') at time zone 'Europe/London', null, 'c5', null, 'rb', null),
      (v_t, v_sub, 'verifysubs', 'io5b', 'invoice_overdue', (v_m0 + interval '2 months 20 days') at time zone 'Europe/London', null, 'c5', null, 'rb', null),
      (v_t, v_sub, 'verifysubs', 'ip6', 'invoice_placed', (v_m0 + interval '2 months 4 days') at time zone 'Europe/London', 's6', 'c6', null, 'rc', null),
      (v_t, v_sub, 'verifysubs', 'ipd6', 'invoice_paid', (v_m0 + interval '2 months 5 days') at time zone 'Europe/London', 's6', 'c6', null, 'rc', null),
      (v_t, v_sub, 'verifysubs', 'ip7', 'invoice_placed', (v_m0 + interval '2 months 4 days') at time zone 'Europe/London', null, 'c7', null, 'rd', null);

    -- B1. the markers on rows of one write time (6,000 events: times its microseconds the product passes bigint) and on a
    --     tenant without a row: each part 210's text
    v_txt := (select count(*) from generate_series(1, cardinality(v_parts)) g
              where (cma.inputs_markers_of(v_t, v_parts))[g]
                    is distinct from (pg_temp.v0009zf_markers_210(v_t, v_parts))[g] || case when v_provoke and g = 2 then 'x' else '' end)::text
             || ' ' || (select count(*) from generate_series(1, cardinality(v_parts)) g
                        where (cma.inputs_markers_of(v_e, v_parts))[g] is distinct from (pg_temp.v0009zf_markers_210(v_e, v_parts))[g])::text
             || ' | events ' || split_part((cma.inputs_markers_of(v_t, array['subscription_event']))[1], '@', 1)
             || ', one write time holds ' || (select max(q.n) from (select count(*) as n from cma.subscription_event e where e.tenant_id = v_t group by e.synced_at) q)
             || ', write times ' || (select count(distinct e.synced_at) from cma.subscription_event e where e.tenant_id = v_t)
             || ' | the empty tenant''s events ' || (cma.inputs_markers_of(v_e, array['subscription_event']))[1]
             || ', changes ' || (cma.inputs_markers_of(v_e, array['subscription_change']))[1];
    v_rows := v_rows || array['11', 'B1 the markers of 6,000 rows of one write time and of a tenant without a row: every part 210''s text (parts differing: the tenant, the empty tenant)',
      case when v_txt = '0 0 | events 6006, one write time holds 6000, write times 4 | the empty tenant''s events 0, changes 0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B2. the payment state with every invoice-renewal case, both forms, against 210's and against the states by hand:
    --     s3 In retry, s4 Charged back, s5 Awaiting payment and overdue through its customer's one subscription (its
    --     renewal rb names none), s6 paid (its invoice paid), s7 and s8 paid (their customer holds two: rd resolves to none)
    v_txt := (select count(*) filter (where a.t is distinct from b.t)
              from (select n.subscription_id, n::text as t from cma.subscription_payment_state_of(v_t) n) a
              full join (select o.subscription_id, o::text as t from pg_temp.v0009zf_ps_210(v_t) o
                         offset case when v_provoke then 1 else 0 end) b using (subscription_id))::text
             || '/' || (select count(*) filter (where a.t is distinct from b.t)
                        from (select n.subscription_id, n::text as t
                              from cma.subscription_payment_state_of(v_t, array(select x.id from cma.subscription x where x.tenant_id = v_t and x.source_id <> 's1')) n) a
                        full join (select o.subscription_id, o::text as t
                                   from pg_temp.v0009zf_ps_210(v_t, array(select x.id from cma.subscription x where x.tenant_id = v_t and x.source_id <> 's1')) o) b
                          using (subscription_id))::text
             || ' | ' || (select string_agg(p.source_id || ':' || p.payment_state || case when p.overdue then '(overdue)' else '' end, ' ' order by p.source_id collate "C")
                          from cma.subscription_payment_state_of(v_t) p);
    v_rows := v_rows || array['12', 'B2 the payment state with a renewal that names its subscription, one resolved through the customer''s one subscription, one of a customer with two, a paid and an overdue one: 210''s row for row in both forms (differing/differing), and the states',
      case when v_txt = '0/0 | s1:paid s2:paid s3:in_retry s4:charged_back s5:awaiting_payment(overdue) s6:paid s7:paid s8:paid s9:paid'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- the facts, refreshed as the scheduler; then where each stored row sits
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_sch::text, true);
    v_j := cma.subscription_facts_refresh_of(v_t, true, v_now);
    perform set_config('role', 'cma_owner', true);
    create temporary table v0009zf_before on commit drop as
      select 'o'::text as take, x.connection_id::text || '/' || x.subscription_source_id || '/' || x.renewal_key as key, x.ctid as at, (x.*)::text as row
      from cma.renewal_outcome x where x.tenant_id = v_t
      union all
      select 's', x.subscription_id::text, x.ctid, (x.*)::text from cma.subscription_take x where x.tenant_id = v_t;

    -- a change of each kind. Outcomes (6,007 at the first run: 6,004 cycles and the invoice renewals ra, rb and rc): new
    -- (s1's third renewal; the invoice renewal rd, now resolved), changed (s3's failed cycle renewed: not_recovered to
    -- recovered), gone (s9's last renewal no longer held). Subscriptions: new (s10),
    -- changed (s1 and s9 by their renewals, s3 back to paid, s6 paused, s7 awaiting payment now that it is its customer's
    -- one subscription), gone (s8 no longer present)
    insert into cma.subscription_event (tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type, occurred_at,
                                        cycle_index, order_source_id)
    values (v_t, v_sub, 'verifysubs', 'r1-3', 's1', 'renewed', (v_m0 + interval '3 months 1 day') at time zone 'Europe/London', 3, '1003'),
           (v_t, v_sub, 'verifysubs', 'r3-1', 's3', 'renewed', (v_m0 + interval '1 month 5 days') at time zone 'Europe/London', 1, '3001');
    delete from cma.subscription_event e where e.tenant_id = v_t and e.source_id = 'r9-6000';
    update cma.subscription s set status = 'paused', paused_at = v_now - interval '1 day' where s.tenant_id = v_t and s.source_id = 's6';
    update cma.subscription s set source_deleted_at = v_now where s.tenant_id = v_t and s.source_id = 's8';
    insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, billing_interval,
                                  billing_interval_count, amount_per_cycle, currency, source_created_at, source_updated_at)
    values (v_t, v_sub, 'verifysubs', 's10', 'c10', 'active', 'month', 1, 45, 'EUR', v_now - interval '2 days', v_now - interval '2 days');

    perform set_config('role', 'cma_app', true);
    v_j2 := cma.subscription_facts_refresh_of(v_t, true, v_now);
    perform set_config('role', 'cma_owner', true);
    if v_provoke then   -- provoked: an outcome that did not change is written again, as 210's refresh wrote every row
      update cma.renewal_outcome x set attempts = x.attempts where x.tenant_id = v_t and x.subscription_source_id = 's2';
    end if;
    select count(*) filter (where b.take = 'o' and a.key is not null and a.row = b.row and a.at = b.at),
           count(*) filter (where b.take = 'o' and a.key is not null and a.row = b.row and a.at <> b.at),
           count(*) filter (where a.take = 'o' and b.key is null),
           count(*) filter (where b.take = 'o' and a.key is not null and a.row <> b.row),
           count(*) filter (where b.take = 'o' and a.key is null),
           count(*) filter (where b.take = 's' and a.key is not null and a.row = b.row and a.at = b.at),
           count(*) filter (where b.take = 's' and a.key is not null and a.row = b.row and a.at <> b.at),
           count(*) filter (where a.take = 's' and b.key is null),
           count(*) filter (where b.take = 's' and a.key is not null and a.row <> b.row),
           count(*) filter (where b.take = 's' and a.key is null)
    into n_o_same, n_o_moved, n_o_new, n_o_changed, n_o_gone, n_s_same, n_s_moved, n_s_new, n_s_changed, n_s_gone
    from v0009zf_before b
    full join (select 'o'::text as take, x.connection_id::text || '/' || x.subscription_source_id || '/' || x.renewal_key as key, x.ctid as at, (x.*)::text as row
               from cma.renewal_outcome x where x.tenant_id = v_t
               union all
               select 's', x.subscription_id::text, x.ctid, (x.*)::text from cma.subscription_take x where x.tenant_id = v_t) a
      on a.take = b.take and a.key = b.key;

    -- the five takes as 212's refresh left them, then as 210's refresh writes them from the same rows at the same moment
    v_d212 := (select md5(coalesce(string_agg((x.*)::text, '|' order by (x.*)::text collate "C"), '')) from cma.renewal_outcome x where x.tenant_id = v_t)
              || ' ' || (select md5(coalesce(string_agg((x.*)::text, '|' order by (x.*)::text collate "C"), '')) from cma.subscription_take x where x.tenant_id = v_t)
              || ' ' || (select md5(coalesce(string_agg((x.*)::text, '|' order by (x.*)::text collate "C"), '')) from cma.subscription_month_take x where x.tenant_id = v_t)
              || ' ' || (select md5(coalesce(string_agg((x.*)::text, '|' order by (x.*)::text collate "C"), '')) from cma.subscription_survival_take x where x.tenant_id = v_t)
              || ' ' || (select md5(coalesce(string_agg((x.*)::text, '|' order by (x.*)::text collate "C"), '')) from cma.subscription_store_start x where x.tenant_id = v_t)
              || ' ' || (select md5(coalesce(string_agg(concat_ws('/', x.computed_at, x.business_date, x.inputs_key, x.subscriptions, x.amounts_from), '|'), '')) from cma.subscription_take_state x where x.tenant_id = v_t);
    v_txt := (select count(*) from cma.renewal_outcome x where x.tenant_id = v_t) || ' outcomes, ' || (select count(*) from cma.subscription_take x where x.tenant_id = v_t)
             || ' subscriptions, ' || (select count(*) from cma.subscription_month_take x where x.tenant_id = v_t) || ' month rows, '
             || (select count(*) from cma.subscription_survival_take x where x.tenant_id = v_t) || ' cells, '
             || (select count(*) from cma.subscription_store_start x where x.tenant_id = v_t) || ' store';
    perform set_config('role', 'cma_app', true);
    perform pg_temp.v0009zf_refresh_210(v_t, true, v_now);
    perform set_config('role', 'cma_owner', true);
    if v_provoke then   -- provoked: one row of 210's take reads differently
      update cma.subscription_take x set renewals = x.renewals + 1 where x.tenant_id = v_t and x.source_id = 's1';
    end if;
    v_d210 := (select md5(coalesce(string_agg((x.*)::text, '|' order by (x.*)::text collate "C"), '')) from cma.renewal_outcome x where x.tenant_id = v_t)
              || ' ' || (select md5(coalesce(string_agg((x.*)::text, '|' order by (x.*)::text collate "C"), '')) from cma.subscription_take x where x.tenant_id = v_t)
              || ' ' || (select md5(coalesce(string_agg((x.*)::text, '|' order by (x.*)::text collate "C"), '')) from cma.subscription_month_take x where x.tenant_id = v_t)
              || ' ' || (select md5(coalesce(string_agg((x.*)::text, '|' order by (x.*)::text collate "C"), '')) from cma.subscription_survival_take x where x.tenant_id = v_t)
              || ' ' || (select md5(coalesce(string_agg((x.*)::text, '|' order by (x.*)::text collate "C"), '')) from cma.subscription_store_start x where x.tenant_id = v_t)
              || ' ' || (select md5(coalesce(string_agg(concat_ws('/', x.computed_at, x.business_date, x.inputs_key, x.subscriptions, x.amounts_from), '|'), '')) from cma.subscription_take_state x where x.tenant_id = v_t);
    v_rows := v_rows || array['13', 'B3 after a change of each kind the five takes and the take''s own row are what 210''s refresh writes from the same rows (outcomes, subscriptions, months, survival cells, store starts; the moment, the business date, the inputs'' digest)',
      case when v_d212 = v_d210 and v_txt ~ '^6008 outcomes, 9 subscriptions, [1-9][0-9]* month rows, [1-9][0-9]* cells, 1 store$'
                and not v_provoke then 'PASS' else 'FAIL' end,
      case when v_d212 = v_d210 then 'equal: ' else 'differing: ' end || v_txt];

    -- B4. the rows that did not change were not written again (they sit where they sat), and the others were
    v_txt := format('outcomes: %s untouched, %s written though unchanged, %s new, %s changed, %s gone | subscriptions: %s untouched, %s written though unchanged, %s new, %s changed, %s gone',
                    n_o_same, n_o_moved, n_o_new, n_o_changed, n_o_gone, n_s_same, n_s_moved, n_s_new, n_s_changed, n_s_gone);
    v_rows := v_rows || array['14', 'B4 the refresh writes the differences only: an unchanged outcome and an unchanged subscription stay where they sat; a new, a changed and a gone one of each are written',
      case when v_txt = 'outcomes: 6005 untouched, 0 written though unchanged, 2 new, 1 changed, 1 gone | subscriptions: 3 untouched, 0 written though unchanged, 1 new, 5 changed, 1 gone'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B5. the answer: rows the takes' rows as before, rows_written what this run wrote (the differences, and the month and
    --     survival takes, written whole as before)
    v_txt := format('first: rows %s = %s, written %s | second: rows %s = %s, written %s = %s',
                    v_j ->> 'rows', (v_j ->> 'subscription_rows')::int + (v_j ->> 'month_rows')::int + (v_j ->> 'outcome_rows')::int + (v_j ->> 'survival_rows')::int,
                    (v_j ->> 'rows_written' = v_j ->> 'rows')::text,
                    v_j2 ->> 'rows', (v_j2 ->> 'subscription_rows')::int + (v_j2 ->> 'month_rows')::int + (v_j2 ->> 'outcome_rows')::int + (v_j2 ->> 'survival_rows')::int,
                    v_j2 ->> 'rows_written',
                    (n_o_new + n_o_changed + n_o_gone + n_s_new + n_s_changed + n_s_gone + (v_j2 ->> 'month_rows')::int + (v_j2 ->> 'survival_rows')::int)::text);
    v_rows := v_rows || array['15', 'B5 the answer: rows the takes'' rows, rows_written every row at the first run and the differences plus the month and survival takes at the second; the six steps'' milliseconds',
      case when (v_j ->> 'rows')::int = (v_j ->> 'subscription_rows')::int + (v_j ->> 'month_rows')::int + (v_j ->> 'outcome_rows')::int + (v_j ->> 'survival_rows')::int
                and v_j ->> 'rows_written' = v_j ->> 'rows' and (v_j ->> 'outcome_rows')::int = 6007 and (v_j ->> 'subscription_rows')::int = 9
                and (v_j2 ->> 'rows')::int = (v_j2 ->> 'subscription_rows')::int + (v_j2 ->> 'month_rows')::int + (v_j2 ->> 'outcome_rows')::int + (v_j2 ->> 'survival_rows')::int
                and (v_j2 ->> 'outcome_rows')::int = 6008 and (v_j2 ->> 'subscription_rows')::int = 9
                and (v_j2 ->> 'rows_written')::int = n_o_new + n_o_changed + n_o_gone + n_s_new + n_s_changed + n_s_gone + (v_j2 ->> 'month_rows')::int + (v_j2 ->> 'survival_rows')::int
                and v_j ? 'steps_ms' and (select count(*) from jsonb_object_keys(v_j2 -> 'steps_ms')) = 6
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['59', 'B the block ran to the end', 'FAIL', sqlstate || ': ' || sqlerrm];
  end;
  insert into verify_0009zf (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0009zf values (59, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- The helpers are dropped first, so the verdict is the last thing the script prints
drop function if exists pg_temp.v0009zf_code(text);
drop function if exists pg_temp.v0009zf_plan(text);
drop function if exists pg_temp.v0009zf_markers_210(uuid, text[]);
drop function if exists pg_temp.v0009zf_ps_210(uuid);
drop function if exists pg_temp.v0009zf_ps_210(uuid, uuid[]);
drop function if exists pg_temp.v0009zf_refresh_210(uuid, boolean, timestamptz);

-- Verdict: one row per check, then the verdict (the info rows count for neither)
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0009zf
      union all
      select 99, 'verdict',
             case when not current_setting('verify.dev')::boolean then 'REFUSED'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0009zf where result = 'PASS') = 10
                       and not exists (select 1 from verify_0009zf where result not in ('PASS', 'info')) then 'PASS'
                  else 'FAIL' end,
             format('213_verify_subscription_facts_speed: %s PASS, %s FAIL, %s info', (select count(*) from verify_0009zf where result = 'PASS'),
                    (select count(*) from verify_0009zf where result not in ('PASS', 'info')), (select count(*) from verify_0009zf where result = 'info'))) x
order by ord;
reset role;
