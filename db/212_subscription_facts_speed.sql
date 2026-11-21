-- =============================================================================================
-- 212_subscription_facts_speed.sql: addition 0009zf, the subscription facts after their first day in prod (brief B39
-- continued, the follow-up of Part B39c): the inputs' markers without parallel workers and with one piece of arithmetic
-- per write time, the payment state's invoice renewals joined to their subscription in two steps, and a facts refresh
-- that writes only the rows that changed
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 210_subscription_facts.sql (0009ze). Rerunnable, forward-only, in one transaction with a lock timeout. No table, view
-- or column changes; every answer stays what 210 gave (213 compares each function with 210's definition, row for row).
-- Brief B39b is addition 0009zg and B39d 0009zh from here on (210's header still says 0009zd, 208/209, for B39b: that
-- script has run and is not edited).
--
-- First, from the Terminal (never Studio: Studio wraps a script in a transaction, which a concurrent build refuses), on
-- cma.subscription_event, a busy table (CLAUDE.md, Performance): dev, then prod, its own statement with set role
-- cma_owner, lock_timeout '5s' and statement_timeout '10min' given as separate commands of the same session, then
-- pg_index.indisvalid checked (t; an f: drop index concurrently, then create it again). The pull request's Terminal
-- blocks give it ready to run. The script refuses to run until it exists and is valid:
--   create index concurrently if not exists subscription_event_synced_idx on cma.subscription_event (tenant_id, synced_at);
-- It holds every event's write time: the events' marker (count, latest write, sum of the writes) is read from it alone,
-- 2 MB in place of the table's 170 MB on the local volume fixture, whose events table is about one and a third times
-- prod's (the part 141.5 ms before, 16.3 ms after, Postgres held to one CPU). This reopens the choice of no new index on
-- cma.subscription_event (Decision log, 18 Nov 2026, checked in prod and kept on 20 Nov 2026; PROD_RUNBOOK 17.7: a row
-- over its budget reopens it, and the index goes in by a concurrent Terminal step in a later pull request).
--
-- A second index, built the same way, is not required by this script (Martin, 21 November 2026: the index on renewal
-- orders; Decision log, 20 Nov 2026: created only if prod confirms the slowdown):
--   create index concurrently if not exists subscription_event_renewal_order_idx
--     on cma.subscription_event (tenant_id, connection_id, subscription_source_id, cycle_index desc)
--     include (occurred_at, order_source_id, source_id) where event_type = 'renewed' and cycle_index is not null;
-- It holds each subscription's renewals by cycle, newest first, with the renewal's time and store order, so the payment
-- state's latest renewal per subscription (last_renewal) is an index-only read: no visit to the table per subscription.
-- 213's info row I2 shows whether the planner takes it for that read; what it is worth is the difference between two
-- runs of 124_time_flash.sql in prod, one after this script and one after the index. Locally, with the whole table in
-- memory, it measures no gain (the payment state of 22,680 subscriptions 395 ms with it, 391 ms without): the index
-- earns its place only by prod's difference, and is dropped again without one.
--
-- Run as your own IAM login: dev first, then 213_verify_subscription_facts_speed.sql there (normal, then provoked), then
-- the verifies that read what this script re-creates:
--   cma.inputs_markers_of (through cma.active_inputs_key_of and cma.subscription_facts_inputs_key_of, which are not made
--     again): 175_verify_active_refresh_quiet.sql, 177_verify_active_attribution_present.sql,
--     185_verify_active_device_bands.sql, 211_verify_subscription_facts.sql;
--   cma.subscription_payment_state_of (both forms): 119_verify_subscriptions.sql, 149_verify_installed_base_list.sql,
--     161_verify_installed_base_now.sql, 173_verify_active_customers.sql, 177, 211; through cma.flash_rows_of and
--     cma.flash_compute_of: 123_verify_flash.sql, 137_verify_flash_insights.sql, 139_verify_flash_totals.sql,
--     147_verify_installed_base_models.sql, 159_verify_flash_current_take.sql, 181_verify_flash_stored_cards.sql,
--     189_verify_fleet_management.sql, 193_verify_fleet_page.sql;
--   cma.subscription_facts_refresh_of: 211;
--   131_time_all.sql and 124_time_flash.sql (131 edited by this change: the facts' budget).
-- None of these verifies is edited by this change. Prod: the first index, this script and 213, then 119, 173 and 185,
-- before or after the merge of its pull request (the web reads nothing new).
--
-- Why (Martin, 21 November 2026; records/0009ze-prod-2026-11-21; Decision log, 21 Nov 2026). After 210 ran in prod:
--   the inputs' markers   cma.active_inputs_key_of took 964.9 ms against 300 (440.7 ms the day before, about 145 ms before
--                         0009za's events arrived). 210 gave every table's marker a statement of its own with the
--                         planner's parallel costs set to nothing, so each statement started parallel workers; prod's
--                         instance has one vCPU, where workers take turns on the same core (locally, Postgres held to
--                         one CPU: 210's key 446 ms against 174's 358; on four CPUs 165 against 286). And the events'
--                         marker read the whole table and did numeric arithmetic per row;
--   the payment state     its invoice renewals met every active subscription of their connection before the renewal's
--                         own subscription was known (a join on the connection alone: rows times rows; most of its
--                         3.1 s locally with 552 invoice renewals over three stores of 1,500 active subscriptions; how
--                         many invoice renewals prod holds decides its share there). It is read
--                         by Flash's subscriptions list, Customers → Active's lists and refresh and the facts' refresh;
--   the facts' refresh    10.2 s in prod, about every 15 minutes, of which about 3 s the insert into cma.renewal_outcome:
--                         every run deleted and inserted every row of every take;
--   Customers → Active    131's "active customers (set)" read 830.1 ms and "active rest (stored document)" 56.7 ms. The
--                         earlier prod records do not pin either on 210: the set read 796.0, 284.4, 530.0 and 258.1 ms
--                         between 12 and 14 November with nothing changed between the runs, and the stored rest read
--                         (cma.active_rest_stored_of, 172) reads a stored document and no payment state (26.7 to 10.8 ms
--                         then). The set's three list reads do read the payment state of their page, which this script
--                         makes cheaper where a store holds invoice renewals. Nothing else of Customers → Active is
--                         changed here: the run after this script, read row by row, decides.
--
-- What it re-creates (each from its latest definition, with its -- based on: line)
--   cma.inputs_markers_of(uuid, text[])                    210: no parallel workers (max_parallel_workers_per_gather 0 on
--                                                          the function; should the instance gain cores, a numbered
--                                                          script takes the setting off, measured there first); the
--                                                          seven markers over a write time grouped by that time first, so
--                                                          the numeric arithmetic runs once per write time, not per row.
--                                                          Each part's text is 210's
--   cma.subscription_payment_state_of(uuid)                210: the invoice renewals resolved to their subscription first
--   cma.subscription_payment_state_of(uuid, uuid[])        210: the same
--   cma.subscription_facts_refresh_of(uuid, boolean, timestamptz)   210: cma.renewal_outcome and cma.subscription_take
--                                                          computed into temporary tables and written as differences (a
--                                                          gone row deleted, a changed one updated, a new one inserted);
--                                                          the month, survival and store start takes written as before
--                                                          (a few thousand computed rows). Its answer gains rows_written
--                                                          and steps_ms
-- Not built here (the pull request sizes it): a refresh that computes only the subscriptions whose inputs changed.
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
  if not exists (select 1 from cma.schema_migration where version = '0009ze') then
    raise exception 'addition 0009ze (210_subscription_facts.sql) has not run in this database';
  end if;
  if (select count(*) from pg_index i join pg_class c on c.oid = i.indexrelid
      where c.relnamespace = 'cma'::regnamespace and i.indrelid = 'cma.subscription_event'::regclass and i.indisvalid
        and c.relname = 'subscription_event_synced_idx') <> 1 then
    raise exception 'the index subscription_event_synced_idx must exist and be valid first: create it concurrently from the Terminal (this script''s header)';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The inputs' change markers: no parallel workers, one piece of arithmetic per write time
-- ---------------------------------------------------------------------------------------------
-- As 210's: the same parts, each in a statement of its own (execute: a plan for the tenant at hand), each part's text
-- 210's own, so cma.active_inputs_key_of and cma.subscription_facts_inputs_key_of give 210's digests (213 proves it per
-- part and per digest). Two changes:
--   no parallel workers   210 set the planner's parallel costs to nothing so every statement would start workers. On one
--                         vCPU (prod) the workers share the leader's core and their start is pure cost. The function now
--                         sets max_parallel_workers_per_gather to 0: the plans are the same on every instance;
--   the write-time parts  count, latest write and the sum of the writes in microseconds (subscription, subscription_event,
--                         device, billing_event, subscription_line, subscription_product_variant; subscription_change by
--                         observed_at): the rows are grouped by their write time first and the microseconds are computed
--                         once per write time, times the rows that share it. A read writes a page of rows in one
--                         transaction, so they share one write time (now() is the transaction's): the numeric arithmetic
--                         runs per page, not per row. The product is numeric (a table written in one transaction would
--                         pass bigint), as sum(bigint) is, so the text is the same digits; coalesce(sum(n), 0) is
--                         count(*)'s 0 on an empty table. cma.subscription_event's part reads
--                         subscription_event_synced_idx alone
-- based on: 210_subscription_facts.sql
create or replace function cma.inputs_markers_of(p_tenant_id uuid, p_parts text[])
returns text[]
language plpgsql
stable
set max_parallel_workers_per_gather = 0
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
        'select concat_ws(''@'', coalesce(sum(g.n), 0), extract(epoch from max(g.at)), sum(g.n * ((extract(epoch from g.at) * 1000000)::bigint)::numeric))
         from (select x.synced_at as at, count(*)::numeric as n from cma.subscription x where x.tenant_id = $1 group by x.synced_at) g'
      when 'subscription_event' then
        'select concat_ws(''@'', coalesce(sum(g.n), 0), extract(epoch from max(g.at)), sum(g.n * ((extract(epoch from g.at) * 1000000)::bigint)::numeric))
         from (select x.synced_at as at, count(*)::numeric as n from cma.subscription_event x where x.tenant_id = $1 group by x.synced_at) g'
      when 'device' then
        'select concat_ws(''@'', coalesce(sum(g.n), 0), extract(epoch from max(g.at)), sum(g.n * ((extract(epoch from g.at) * 1000000)::bigint)::numeric))
         from (select x.synced_at as at, count(*)::numeric as n from cma.device x where x.tenant_id = $1 group by x.synced_at) g'
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
        'select concat_ws(''@'', coalesce(sum(g.n), 0), extract(epoch from max(g.at)), sum(g.n * ((extract(epoch from g.at) * 1000000)::bigint)::numeric))
         from (select x.synced_at as at, count(*)::numeric as n from cma.billing_event x where x.tenant_id = $1 group by x.synced_at) g'
      when 'subscription_line' then
        'select concat_ws(''@'', coalesce(sum(g.n), 0), extract(epoch from max(g.at)), sum(g.n * ((extract(epoch from g.at) * 1000000)::bigint)::numeric))
         from (select x.synced_at as at, count(*)::numeric as n from cma.subscription_line x where x.tenant_id = $1 group by x.synced_at) g'
      when 'subscription_product_variant' then
        'select concat_ws(''@'', coalesce(sum(g.n), 0), extract(epoch from max(g.at)), sum(g.n * ((extract(epoch from g.at) * 1000000)::bigint)::numeric))
         from (select x.synced_at as at, count(*)::numeric as n from cma.subscription_product_variant x where x.tenant_id = $1 group by x.synced_at) g'
      when 'subscription_variant_mapping' then
        'select concat_ws(''@'', count(*), sum(hash_record_extended(x, 0))) from cma.subscription_variant_mapping x where x.tenant_id = $1'
      when 'subscription_change' then
        'select concat_ws(''@'', coalesce(sum(g.n), 0), extract(epoch from max(g.at)), sum(g.n * ((extract(epoch from g.at) * 1000000)::bigint)::numeric))
         from (select x.observed_at as at, count(*)::numeric as n from cma.subscription_change x where x.tenant_id = $1 group by x.observed_at) g'
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

-- ---------------------------------------------------------------------------------------------
-- 2. The payment state: an invoice renewal's subscription first, then the join
-- ---------------------------------------------------------------------------------------------
-- As 210's, every rule and every column. One change, in both forms: 210's awaiting joined ren (the invoice renewals) to
-- sole (a customer's one active subscription) and to s (the subscriptions) in one step, with s matched on
-- coalesce(ren's subscription, sole's). The planner cannot use that expression as a join key before sole is joined, so it
-- joined ren to s on the connection alone, every renewal with every subscription of its store, and filtered after. ren_of
-- resolves each renewal's subscription first (materialized), and awaiting joins it to s on connection and source id.
-- The latest renewal per subscription (last_renewal) is unchanged: where subscription_event_renewal_order_idx exists it
-- is an index-only read (213 reads the plan). create or replace: the columns are 210's; jit off repeated (a create or replace
-- drops a function's settings)
-- based on: 210_subscription_facts.sql
create or replace function cma.subscription_payment_state_of(p_tenant_id uuid)
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
  ren_of as materialized (
    -- each invoice renewal with an invoice placed, and the subscription it belongs to: the one its events name, else the
    -- customer's one active subscription. Resolved here, before the subscriptions are joined (0009zf): joined in one step,
    -- as 210 did, the renewals met every subscription of their connection first (rows times rows)
    select r.connection_id, coalesce(r.subscription_source_id, o.source_id) as subscription_source_id, r.renewal_source_id,
           r.placed_at, r.overdue, r.paid
    from ren r
    left join sole o on o.connection_id = r.connection_id and o.customer_source_id = r.customer_source_id and r.subscription_source_id is null
    where r.placed_at is not null
  ),
  awaiting as (
    -- an active subscription's latest invoice placed for a renewal that no paid invoice of that renewal followed; overdue
    -- once an overdue invoice of that renewal came
    select distinct on (s.id) s.id, r.placed_at as occurred_at, r.overdue, r.paid
    from ren_of r
    join s on s.connection_id = r.connection_id and s.source_id = r.subscription_source_id and s.status = 'active'
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
alter function cma.subscription_payment_state_of(uuid) set jit = off;

-- The same for the given subscriptions: a list's page
-- based on: 210_subscription_facts.sql
create or replace function cma.subscription_payment_state_of(p_tenant_id uuid, p_subscription_ids uuid[])
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
  ren_of as materialized (
    -- each invoice renewal with an invoice placed, and the subscription it belongs to: the one its events name, else the
    -- customer's one active subscription. Resolved here, before the subscriptions are joined (0009zf): joined in one step,
    -- as 210 did, the renewals met every subscription of their connection first (rows times rows)
    select r.connection_id, coalesce(r.subscription_source_id, o.source_id) as subscription_source_id, r.renewal_source_id,
           r.placed_at, r.overdue, r.paid
    from ren r
    left join sole o on o.connection_id = r.connection_id and o.customer_source_id = r.customer_source_id and r.subscription_source_id is null
    where r.placed_at is not null
  ),
  awaiting as (
    -- an active subscription's latest invoice placed for a renewal that no paid invoice of that renewal followed; overdue
    -- once an overdue invoice of that renewal came
    select distinct on (s.id) s.id, r.placed_at as occurred_at, r.overdue, r.paid
    from ren_of r
    join s on s.connection_id = r.connection_id and s.source_id = r.subscription_source_id and s.status = 'active'
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
alter function cma.subscription_payment_state_of(uuid, uuid[]) set jit = off;

-- ---------------------------------------------------------------------------------------------
-- 3. The facts' refresh: the two large takes written as differences
-- ---------------------------------------------------------------------------------------------
-- As 210's: the same skips, the same order, the same computed rows. cma.renewal_outcome (a row per renewed or failed
-- cycle: the largest take) and cma.subscription_take (a row per subscription) are computed into temporary tables and
-- compared with the stored rows as text, column by column: a stored row no longer computed is deleted, one that reads
-- differently is updated, a new one is inserted, and a row that reads the same is not touched (213 proves the stored rows
-- equal the computation after a change of each kind, and that an unchanged row is not written again). 210 deleted and
-- inserted every row at every run: in prod about 3 s of the refresh's 10.2 s for cma.renewal_outcome alone, and as many
-- dead rows for autovacuum every 15 minutes. The month take, the survival cells and the stores' rate starts are computed
-- aggregates of a few thousand rows and are written as before. The answer's rows stays the takes' rows (subscriptions,
-- months, outcomes, survival cells); rows_written counts, over the same four takes, the rows this run wrote: the
-- differences of the two large ones and every row of the month and survival takes (the stores' rate starts and the device
-- units are in neither figure, as before). steps_ms gives the milliseconds of each step (the inputs' digest, the device
-- units, the outcomes, the subscriptions, the months with the stores' starts, the survival cells), so a run in prod says
-- where its time goes. jit off repeated
-- based on: 210_subscription_facts.sql
create or replace function cma.subscription_facts_refresh_of(p_tenant_id uuid, p_force boolean default false, p_now timestamptz default null)
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
  n_written  integer := 0;
  n          integer;
  v_mark     timestamptz := clock_timestamp();
  v_steps    jsonb := '{}';
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
  v_steps := v_steps || jsonb_build_object('inputs_key', round(extract(epoch from clock_timestamp() - v_mark) * 1000));
  v_mark := clock_timestamp();
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
  v_steps := v_steps || jsonb_build_object('device_units', round(extract(epoch from clock_timestamp() - v_mark) * 1000));
  v_mark := clock_timestamp();

  -- 2. renewal outcomes (C.3), first: the subscriptions' renewals are counted from them. Computed into a temporary table,
  --    then only the rows that read differently are written (0009zf): a gone renewal deleted, a changed one updated, a new
  --    one inserted. A run rewrote every row before; between two runs a handful change
  create temporary table if not exists subscription_facts_outcomes (
    connection_id uuid not null, subscription_source_id text not null, renewal_key text not null, cycle_index integer, renewal_source_id text,
    first_attempt_at timestamptz, outcome text, attempts integer, recovered_at timestamptz, days_to_recover numeric(7,1), error_code text,
    instrument_type text, payment_method_changed_before_recovery boolean,
    primary key (connection_id, subscription_source_id, renewal_key)) on commit drop;
  delete from subscription_facts_outcomes;
  insert into subscription_facts_outcomes
  select r.* from cma.renewal_outcomes_of(p_tenant_id) r;
  get diagnostics n_outcomes = row_count;
  analyze subscription_facts_outcomes;
  delete from cma.renewal_outcome x
  where x.tenant_id = p_tenant_id
    and not exists (select 1 from subscription_facts_outcomes o
                    where o.connection_id = x.connection_id and o.subscription_source_id = x.subscription_source_id and o.renewal_key = x.renewal_key);
  get diagnostics n = row_count; n_written := n_written + n;
  update cma.renewal_outcome x
  set cycle_index = o.cycle_index, renewal_source_id = o.renewal_source_id, first_attempt_at = o.first_attempt_at, outcome = o.outcome,
      attempts = o.attempts, recovered_at = o.recovered_at, days_to_recover = o.days_to_recover, error_code = o.error_code,
      instrument_type = o.instrument_type, payment_method_changed_before_recovery = o.payment_method_changed_before_recovery
  from subscription_facts_outcomes o
  where x.tenant_id = p_tenant_id and o.connection_id = x.connection_id and o.subscription_source_id = x.subscription_source_id
    and o.renewal_key = x.renewal_key
    and row(x.cycle_index, x.renewal_source_id, x.first_attempt_at, x.outcome, x.attempts, x.recovered_at, x.days_to_recover, x.error_code,
            x.instrument_type, x.payment_method_changed_before_recovery)::text
        is distinct from
        row(o.cycle_index, o.renewal_source_id, o.first_attempt_at, o.outcome, o.attempts, o.recovered_at, o.days_to_recover, o.error_code,
            o.instrument_type, o.payment_method_changed_before_recovery)::text;
  get diagnostics n = row_count; n_written := n_written + n;
  insert into cma.renewal_outcome (tenant_id, connection_id, subscription_source_id, renewal_key, cycle_index, renewal_source_id, first_attempt_at,
                                   outcome, attempts, recovered_at, days_to_recover, error_code, instrument_type,
                                   payment_method_changed_before_recovery)
  select p_tenant_id, o.connection_id, o.subscription_source_id, o.renewal_key, o.cycle_index, o.renewal_source_id, o.first_attempt_at, o.outcome,
         o.attempts, o.recovered_at, o.days_to_recover, o.error_code, o.instrument_type, o.payment_method_changed_before_recovery
  from subscription_facts_outcomes o
  where not exists (select 1 from cma.renewal_outcome x
                    where x.tenant_id = p_tenant_id and x.connection_id = o.connection_id and x.subscription_source_id = o.subscription_source_id
                      and x.renewal_key = o.renewal_key);
  get diagnostics n = row_count; n_written := n_written + n;

  v_steps := v_steps || jsonb_build_object('outcomes', round(extract(epoch from clock_timestamp() - v_mark) * 1000));
  v_mark := clock_timestamp();

  -- 3. per subscription: computed into a temporary table, then written as step 2 writes its rows (0009zf)
  create temporary table if not exists subscription_facts_take (
    subscription_id uuid primary key, connection_id uuid, source_id text, market text, status text, payment_state text, state_since timestamptz,
    overdue boolean, chargeback_return_code text, amount_at_risk numeric(14,2), currency text, monthly_amount numeric, interval_group text,
    device_units integer, propositions text[], models text[], original_start_at timestamptz, original_start_basis text, cohort_month date,
    migrated boolean, renewals integer) on commit drop;
  delete from subscription_facts_take;
  insert into subscription_facts_take (subscription_id, connection_id, source_id, market, status, payment_state, state_since, overdue,
                                       chargeback_return_code, amount_at_risk, currency, monthly_amount, interval_group, device_units,
                                       propositions, models, original_start_at, original_start_basis, cohort_month, migrated, renewals)
  with sm as materialized (
    select y.connection_id, y.store_connection_id, y.market from cma.flash_subscription_stores_of(p_tenant_id) y
  ), ps as materialized (
    select * from cma.subscription_payment_state_of(p_tenant_id)
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
  select b.id, b.connection_id, b.source_id, b.market, b.status, b.payment_state, b.state_since, b.overdue,
         b.chargeback_return_code, b.amount_at_risk, b.currency, b.monthly_amount, b.interval_group, b.device_units, b.propositions, b.models,
         b.original_start_at, b.basis, date_trunc('month', b.original_start_at at time zone v_zone)::date, b.migrated, b.renewals
  from b;
  get diagnostics n_subs = row_count;
  analyze subscription_facts_take;
  delete from cma.subscription_take x
  where x.tenant_id = p_tenant_id
    and not exists (select 1 from subscription_facts_take k where k.subscription_id = x.subscription_id);
  get diagnostics n = row_count; n_written := n_written + n;
  update cma.subscription_take x
  set connection_id = k.connection_id, source_id = k.source_id, market = k.market, status = k.status, payment_state = k.payment_state,
      state_since = k.state_since, overdue = k.overdue, chargeback_return_code = k.chargeback_return_code, amount_at_risk = k.amount_at_risk,
      currency = k.currency, monthly_amount = k.monthly_amount, interval_group = k.interval_group, device_units = k.device_units,
      propositions = k.propositions, models = k.models, original_start_at = k.original_start_at, original_start_basis = k.original_start_basis,
      cohort_month = k.cohort_month, migrated = k.migrated, renewals = k.renewals
  from subscription_facts_take k
  where x.tenant_id = p_tenant_id and k.subscription_id = x.subscription_id
    and row(x.connection_id, x.source_id, x.market, x.status, x.payment_state, x.state_since, x.overdue, x.chargeback_return_code, x.amount_at_risk,
            x.currency, x.monthly_amount, x.interval_group, x.device_units, x.propositions, x.models, x.original_start_at, x.original_start_basis,
            x.cohort_month, x.migrated, x.renewals)::text
        is distinct from
        row(k.connection_id, k.source_id, k.market, k.status, k.payment_state, k.state_since, k.overdue, k.chargeback_return_code, k.amount_at_risk,
            k.currency, k.monthly_amount, k.interval_group, k.device_units, k.propositions, k.models, k.original_start_at, k.original_start_basis,
            k.cohort_month, k.migrated, k.renewals)::text;
  get diagnostics n = row_count; n_written := n_written + n;
  insert into cma.subscription_take (tenant_id, subscription_id, connection_id, source_id, market, status, payment_state, state_since, overdue,
                                     chargeback_return_code, amount_at_risk, currency, monthly_amount, interval_group, device_units,
                                     propositions, models, original_start_at, original_start_basis, cohort_month, migrated, renewals)
  select p_tenant_id, k.subscription_id, k.connection_id, k.source_id, k.market, k.status, k.payment_state, k.state_since, k.overdue,
         k.chargeback_return_code, k.amount_at_risk, k.currency, k.monthly_amount, k.interval_group, k.device_units, k.propositions, k.models,
         k.original_start_at, k.original_start_basis, k.cohort_month, k.migrated, k.renewals
  from subscription_facts_take k
  where not exists (select 1 from cma.subscription_take x where x.tenant_id = p_tenant_id and x.subscription_id = k.subscription_id);
  get diagnostics n = row_count; n_written := n_written + n;

  v_steps := v_steps || jsonb_build_object('subscriptions', round(extract(epoch from clock_timestamp() - v_mark) * 1000));
  v_mark := clock_timestamp();

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
  v_steps := v_steps || jsonb_build_object('months', round(extract(epoch from clock_timestamp() - v_mark) * 1000));
  v_mark := clock_timestamp();

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
  v_steps := v_steps || jsonb_build_object('survival', round(extract(epoch from clock_timestamp() - v_mark) * 1000));

  -- 6. the take's row
  insert into cma.subscription_take_state as t (tenant_id, computed_at, business_date, duration_ms, inputs_key, subscriptions, amounts_from)
  values (p_tenant_id, v_now, v_today, (extract(epoch from clock_timestamp() - v_t0) * 1000)::integer, v_key, n_subs, v_amounts)
  on conflict (tenant_id) do update
    set computed_at = excluded.computed_at, business_date = excluded.business_date, duration_ms = excluded.duration_ms,
        inputs_key = excluded.inputs_key, subscriptions = excluded.subscriptions, amounts_from = excluded.amounts_from;

  return jsonb_build_object('refreshed', true, 'unchanged', false, 'device_units_written', n_units, 'subscription_rows', n_subs,
                            'month_rows', n_months, 'outcome_rows', n_outcomes, 'survival_rows', n_cells,
                            'rows', n_subs + n_months + n_outcomes + n_cells,
                            'rows_written', n_written + n_months + n_cells, 'steps_ms', v_steps,
                            'duration_ms', (extract(epoch from clock_timestamp() - v_t0) * 1000)::integer);
end
$$;
alter function cma.subscription_facts_refresh_of(uuid, boolean, timestamptz) set jit = off;

-- ---------------------------------------------------------------------------------------------
-- 4. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009zf', 'The subscription facts after their first day in prod (brief B39 continued, follow-up of Part B39c): cma.inputs_markers_of without parallel workers and with the write-time markers grouped by write time (the digests of cma.active_inputs_key_of and cma.subscription_facts_inputs_key_of unchanged); cma.subscription_payment_state_of (both forms) resolves an invoice renewal''s subscription before joining the subscriptions; cma.subscription_facts_refresh_of writes cma.renewal_outcome and cma.subscription_take as differences. Expects the index subscription_event_synced_idx, created concurrently from the Terminal. No table, view or column changes')
on conflict (version) do nothing;

commit;
reset role;
