-- =============================================================================================
-- 205_verify_subscription_audit.sql: verifies addition 0009zb, the subscription audit and BACS direct debit (brief B39
-- continued, Part B39a2)
-- =============================================================================================
-- Dev and local databases only, as 203: it refuses a database without the dev seed (no active agent.two@example.com):
-- block B's checks then read FAIL and the verdict REFUSED. Block A only reads; block B works on two throwaway tenants
-- inside a subtransaction that is always rolled back, so nothing stays. It writes the scenario's rows as the owner,
-- directly (the audit reads the mirror, however it was filled); to put an @ in a variant's title, which the column's
-- check refuses, it drops that check inside the rolled-back block (the catalog table is locked until the block ends, a
-- moment). Every check writes one row, PASS or FAIL, and the last row is the verdict, because Cloud SQL Studio shows no
-- notices. Run as your own IAM login after 204_subscription_audit.sql, in dev; then 203_verify_subscription_lines.sql and
-- 119_verify_subscriptions.sql (204's header). Adapters, handles, ids, codes, titles and secret names are invented data
-- values, and no row carries a name, an address, an email or a phone number of a customer (the one phone number's shape
-- and the one @ are the defects the audit must find, in a catalog title and SKU, rolled back).
--   A  structure and privileges: the addition row after 0009za; the eight instrument codes (bacs_direct_debit among them,
--      a code outside them refused); the audit and its helper the owner's, in the caller's rights, executable by no
--      application, reader or public; the audit's columns
--   B  behaviour, on two throwaway tenants: the first with two stores (GB clean; NL with one defect per check), the
--      second with a store of its own defects. The clean store: every check's verdict (status_mix explain, every other
--      ok) and the value of each check whose value does not depend on today. The store with defects (an active
--      subscription without a line, a line in another currency, an amount per cycle that is not its lines' sum without a
--      discount, a line's variant not in the catalog, a month without an event, an event of a subscription not held, a
--      status chain ending in another status, a chargeback no renewal links, migrated subscriptions spread over three
--      buckets, a subscription's instrument other, an @ in a variant title and a phone number's shape in a SKU, an
--      observed change that changed nothing): each check reports its defect with the verdict designed; each defect
--      removed, every check as the clean store's. The second tenant's rows never counted in the first's audit, and its
--      own audit reports them. A second store of a market labelled with its handle; a switched-off connection left out.
--      An unknown tenant CMA02. The application refused execution (42501). bacs_direct_debit taken by both tables'
--      checks, klarna refused (23514)
-- Provoke: set provoke below to true; every check must then read FAIL, and the verdict says PROVOKED instead.
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
-- dev or a local database only: the dev seed's agent.two@example.com active, as 203
select set_config('verify.dev', (select exists (select 1 from cma.app_user u where u.email = 'agent.two@example.com' and u.status = 'active'))::text, false);

drop table if exists pg_temp.verify_0009zb;
create temp table verify_0009zb (ord int, check_name text, result text, detail text);

-- The error a statement raises as its SQLSTATE, or 'ok'
create or replace function pg_temp.v0009zb_code(p_sql text)
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

-- A store's verdicts in the audit's order, as check:verdict separated by spaces
create or replace function pg_temp.v0009zb_verdicts(p_tenant uuid, p_store text)
returns text
language sql
as $$
  select string_agg(a.check_key || ':' || a.verdict, ' ' order by a.n)
  from cma.subscription_audit_of(p_tenant) with ordinality as a(check_key, store, value, expected, verdict, n)
  where a.store = p_store
$$;

-- A store's value of one check
create or replace function pg_temp.v0009zb_value(p_tenant uuid, p_store text, p_key text)
returns text
language sql
as $$
  select a.value from cma.subscription_audit_of(p_tenant) a where a.store = p_store and a.check_key = p_key
$$;

-- One clean store's mirror, as the owner. month 0 is the store's month six months before the current one (its time
-- zone): s1 active (card, no discount, one line, purchased in month 0 and renewed on the 1st of every later month with
-- its store order; a chargeback on month 1's renewal's order, which month 2's renewal follows), s2 active (SEPA direct
-- debit, a discount, two lines summing 30.00 against an amount of 25.00; a refund and an invoice naming it), s3 paused
-- (paypal; its paused event), s4 canceled (BACS direct debit; its line canceled; its canceled event), s5 active and
-- migrated (card; cycle 3, the next billing date month 1, its customer's store order on month 0 less two months: gap 0);
-- the catalog's two variants; one observed change of s1's amount
create or replace function pg_temp.v0009zb_fill(p_tenant uuid, p_conn uuid, p_shop uuid, p_cur text, p_tz text)
returns void
language plpgsql
as $$
declare
  m0 timestamp := date_trunc('month', now() at time zone p_tz) - interval '6 months';
  at_ timestamptz;
begin
  insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, billing_interval,
                                billing_interval_count, amount_per_cycle, currency, payment_instrument_type, discount_count,
                                source_created_at, canceled_at)
  values (p_tenant, p_conn, 'verifysubs', 's1', 'c1', 'active', 'month', 1, 30.00, p_cur, 'card', 0, (m0 + interval '1 day') at time zone p_tz, null),
         (p_tenant, p_conn, 'verifysubs', 's2', 'c2', 'active', 'month', 1, 25.00, p_cur, 'sepa_direct_debit', 1, (m0 + interval '2 days') at time zone p_tz, null),
         (p_tenant, p_conn, 'verifysubs', 's3', 'c3', 'paused', 'month', 1, 30.00, p_cur, 'paypal', 0, (m0 + interval '3 days') at time zone p_tz, null),
         (p_tenant, p_conn, 'verifysubs', 's4', 'c4', 'canceled', 'month', 1, 30.00, p_cur, 'bacs_direct_debit', 0, (m0 + interval '4 days') at time zone p_tz,
          (m0 + interval '3 months 2 days') at time zone p_tz),
         (p_tenant, p_conn, 'verifysubs', 's5', 'c5', 'active', 'month', 1, 30.00, p_cur, 'card', 0, (m0 + interval '5 days') at time zone p_tz, null);
  insert into cma.subscription_line (tenant_id, connection_id, source_system, source_id, subscription_source_id, product_source_id,
                                     variant_source_id, quantity, amount_per_cycle, currency, billing_interval, billing_interval_count, canceled_at)
  values (p_tenant, p_conn, 'verifysubs', 'l1', 's1', 'p1', 'v1', 1, 30.00, p_cur, 'month', 1, null),
         (p_tenant, p_conn, 'verifysubs', 'l2', 's2', 'p1', 'v1', 1, 20.00, p_cur, 'month', 1, null),
         (p_tenant, p_conn, 'verifysubs', 'l3', 's2', 'p1', 'v2', 1, 10.00, p_cur, 'month', 1, null),
         (p_tenant, p_conn, 'verifysubs', 'l4', 's3', 'p1', 'v1', 1, 30.00, p_cur, 'month', 1, null),
         (p_tenant, p_conn, 'verifysubs', 'l5', 's4', 'p1', 'v1', 1, 30.00, p_cur, 'month', 1, (m0 + interval '3 months 2 days') at time zone p_tz),
         (p_tenant, p_conn, 'verifysubs', 'l6', 's5', 'p1', 'v1', 1, 30.00, p_cur, 'month', 1, null);
  insert into cma.subscription_product_variant (tenant_id, connection_id, source_system, product_source_id, variant_source_id,
                                                product_title, variant_title, sku, product_status)
  values (p_tenant, p_conn, 'verifysubs', 'p1', 'v1', 'Verify product', 'Verify device', 'VZB-1', 'active'),
         (p_tenant, p_conn, 'verifysubs', 'p1', 'v2', 'Verify product', 'Verify cabinet', 'VZB-2', 'active');
  insert into cma.subscription_event (tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type, occurred_at,
                                      status_from, status_to, cycle_index, billing_to_at, order_source_id)
  values (p_tenant, p_conn, 'verifysubs', 'e-p1', 's1', 'purchased', (m0 + interval '1 day') at time zone p_tz, null, null, null, null, null),
         (p_tenant, p_conn, 'verifysubs', 'e-p2', 's2', 'purchased', (m0 + interval '2 days') at time zone p_tz, null, null, null, null, null),
         (p_tenant, p_conn, 'verifysubs', 'e-p3', 's3', 'purchased', (m0 + interval '3 days') at time zone p_tz, null, null, null, null, null),
         (p_tenant, p_conn, 'verifysubs', 'e-p4', 's4', 'purchased', (m0 + interval '4 days') at time zone p_tz, null, null, null, null, null),
         (p_tenant, p_conn, 'verifysubs', 'e-m5', 's5', 'migrated', (m0 + interval '5 days') at time zone p_tz, null, null, 3,
          (m0 + interval '1 month') at time zone p_tz, null),
         (p_tenant, p_conn, 'verifysubs', 'e-c4', 's4', 'canceled', (m0 + interval '3 months 2 days') at time zone p_tz, 'active', 'canceled', null, null, null),
         (p_tenant, p_conn, 'verifysubs', 'e-z3', 's3', 'paused', (m0 + interval '4 months 3 days') at time zone p_tz, 'active', 'paused', null, null, null);
  for i in 1..6 loop
    at_ := (m0 + make_interval(months => i) + interval '30 minutes') at time zone p_tz;
    insert into cma.subscription_event (tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type, occurred_at,
                                        cycle_index, order_source_id)
    values (p_tenant, p_conn, 'verifysubs', 'e-r' || i, 's1', 'renewed', at_, i + 1, '10000' || i);
  end loop;
  insert into cma.billing_event (tenant_id, connection_id, source_system, source_id, kind, occurred_at, subscription_source_id,
                                 order_source_id, amount, currency, return_code, instrument_type)
  values (p_tenant, p_conn, 'verifysubs', 'b1', 'chargeback', (m0 + interval '1 month 5 days') at time zone p_tz, null, '100001', 30.00, p_cur, 'MD06', 'card'),
         (p_tenant, p_conn, 'verifysubs', 'b2', 'refund_created', (m0 + interval '2 months 3 days') at time zone p_tz, 's2', '200001', 10.00, p_cur, null, null),
         (p_tenant, p_conn, 'verifysubs', 'b3', 'invoice_placed', (m0 + interval '2 months 4 days') at time zone p_tz, 's2', null, 25.00, p_cur, null, null);
  insert into cma.commerce_order (tenant_id, connection_id, source_system, source_id, customer_source_id, source_created_at)
  values (p_tenant, p_shop, 'verifyshop', '900001', 'c5', (m0 - interval '2 months' + interval '12 hours') at time zone p_tz);
  insert into cma.subscription_change (tenant_id, connection_id, subscription_source_id, field, old_value, new_value, observed_at)
  values (p_tenant, p_conn, 's1', 'amount_per_cycle', '25.00', '30.00', now() - interval '1 hour');
end
$$;

-- A. Structure and privileges
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_txt     text;
begin
  -- A1. the addition is recorded, after 0009za
  insert into verify_0009zb values (1, 'A1 addition 0009zb recorded, after 0009za',
    case when exists (select 1 from cma.schema_migration where version = '0009zb')
              and exists (select 1 from cma.schema_migration where version = '0009za') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the eight instrument codes: bacs_direct_debit taken; a code outside them, an empty one and null not
  v_txt := (select string_agg(x, ' ' order by x collate "C") from unnest(array['card', 'paypal', 'sepa_direct_debit', 'bacs_direct_debit',
             'ideal', 'bancontact', 'invoice', 'other', 'klarna', 'bacs', '']) x where cma.payment_instrument_type_ok(x))
           || ' | null ' || coalesce(cma.payment_instrument_type_ok(null)::text, 'null');
  insert into verify_0009zb values (2, 'A2 eight instrument codes, bacs_direct_debit among them; klarna, bacs and an empty code refused',
    case when v_txt = 'bacs_direct_debit bancontact card ideal invoice other paypal sepa_direct_debit | null null' and not v_provoke then 'PASS' else 'FAIL' end, v_txt);

  -- A3. the audit and its helper: the owner's, in the caller's rights, executable by the owner only
  v_txt := (select string_agg(p.proname || ':' || pg_get_userbyid(p.proowner) || ':' || p.prosecdef
                              || ':' || has_function_privilege('cma_app', p.oid, 'execute')
                              || ':' || has_function_privilege('cma_readonly', p.oid, 'execute')
                              || ':' || has_function_privilege('public', p.oid, 'execute'), ' ' order by p.proname collate "C")
            from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'cma' and p.proname in ('subscription_audit_of', 'subscription_audit_stores_of'));
  insert into verify_0009zb values (3, 'A3 the audit and its helper the owner''s, security invoker, no execute for the application, readers or public',
    case when v_txt = 'subscription_audit_of:cma_owner:false:false:false:false subscription_audit_stores_of:cma_owner:false:false:false:false'
              and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'missing'));

  -- A4. the audit's columns, in order
  v_txt := pg_get_function_result('cma.subscription_audit_of(uuid)'::regprocedure);
  insert into verify_0009zb values (4, 'A4 the audit answers check_key, store, value, expected, verdict',
    case when v_txt = 'TABLE(check_key text, store text, value text, expected text, verdict text)' and not v_provoke then 'PASS' else 'FAIL' end, v_txt);
end
$$;

-- B. Behaviour on two throwaway tenants (rolled back)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_dev     boolean := current_setting('verify.dev')::boolean;
  v_rows    text[] := '{}';
  v_t1 uuid; v_t2 uuid;
  v_shop_gb uuid; v_shop_nl uuid; v_shop_gb2 uuid; v_shop_t2 uuid;
  v_sub_gb uuid; v_sub_nl uuid; v_sub_gb2 uuid; v_sub_t2 uuid;
  v_ing1 uuid;
  v_m0 timestamp;
  v_hole cma.subscription_event;
  v_clean text := 'status_mix:explain no_lines:ok lines_histogram:ok line_currency:ok amount_vs_lines:ok variant_missing:ok events_by_month:ok orphan_events:ok status_chain:ok billing_kinds:ok billing_link:ok after_chargeback:ok migration_cycles:ok instruments:ok privacy:ok changes:ok';
  v_txt text; v_exp text; v_before text;
begin
  if not v_dev then
    insert into verify_0009zb values (59, 'B a dev or local database (the dev seed''s agent.two@example.com active)', 'FAIL',
      'REFUSED: no dev seed, so this is no dev or local database; nothing ran');
    return;
  end if;
  begin
    v_t1 := cma.create_tenant('verify-0009zb-one', 'Verify 0009zb one', 'Europe/London');
    v_t2 := cma.create_tenant('verify-0009zb-two', 'Verify 0009zb two', 'Europe/London');
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest' and x.external_id = 'ingest';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, signing_secret_name)
    values (v_t1, 'verifyshop', 'Verify shop GB', 'verify-zb-gb.shop.example', 'commerce', 'verify-zb-shop-1') returning id into v_shop_gb;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, signing_secret_name)
    values (v_t1, 'verifyshop', 'Verify shop NL', 'verify-zb-nl.shop.example', 'commerce', 'verify-zb-shop-2') returning id into v_shop_nl;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t1, 'verifysubs', 'Verify subscriptions GB', 'verify-zb-gb.shop.example', 'subscriptions', 'verify-zb-key-1') returning id into v_sub_gb;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t1, 'verifysubs', 'Verify subscriptions NL', 'verify-zb-nl.shop.example', 'subscriptions', 'verify-zb-key-2') returning id into v_sub_nl;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, signing_secret_name)
    values (v_t2, 'verifyshop', 'Verify shop two', 'verify-zb-two.shop.example', 'commerce', 'verify-zb-shop-3') returning id into v_shop_t2;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t2, 'verifysubs', 'Verify subscriptions two', 'verify-zb-two.shop.example', 'subscriptions', 'verify-zb-key-3') returning id into v_sub_t2;
    insert into cma.commerce_store (tenant_id, connection_id, handle, name, market, currency, time_zone)
    values (v_t1, v_shop_gb, 'verify-zb-gb', 'Verify store GB', 'GB', 'GBP', 'Europe/London'),
           (v_t1, v_shop_nl, 'verify-zb-nl', 'Verify store NL', 'NL', 'EUR', 'Europe/Amsterdam'),
           (v_t2, v_shop_t2, 'verify-zb-two', 'Verify store two', 'GB', 'GBP', 'Europe/London');
    perform pg_temp.v0009zb_fill(v_t1, v_sub_gb, v_shop_gb, 'GBP', 'Europe/London');
    perform pg_temp.v0009zb_fill(v_t1, v_sub_nl, v_shop_nl, 'EUR', 'Europe/Amsterdam');
    perform pg_temp.v0009zb_fill(v_t2, v_sub_t2, v_shop_t2, 'GBP', 'Europe/London');
    v_m0 := date_trunc('month', now() at time zone 'Europe/Amsterdam') - interval '6 months';

    -- B1. the clean store: every check in order, status_mix explain and every other ok
    v_txt := pg_temp.v0009zb_verdicts(v_t1, 'GB');
    v_rows := v_rows || array['11', 'B1 a clean store: the sixteen checks in order, status_mix explain (compared by hand), every other ok',
      case when v_txt = v_clean and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'none')];

    -- B2. the clean store's values (those that do not depend on today)
    v_txt := concat_ws(' | ', pg_temp.v0009zb_value(v_t1, 'GB', 'status_mix'), pg_temp.v0009zb_value(v_t1, 'GB', 'no_lines'),
                       pg_temp.v0009zb_value(v_t1, 'GB', 'lines_histogram'), pg_temp.v0009zb_value(v_t1, 'GB', 'line_currency'),
                       pg_temp.v0009zb_value(v_t1, 'GB', 'amount_vs_lines'), pg_temp.v0009zb_value(v_t1, 'GB', 'variant_missing'),
                       pg_temp.v0009zb_value(v_t1, 'GB', 'orphan_events'), pg_temp.v0009zb_value(v_t1, 'GB', 'status_chain'),
                       pg_temp.v0009zb_value(v_t1, 'GB', 'billing_kinds'), pg_temp.v0009zb_value(v_t1, 'GB', 'billing_link'),
                       pg_temp.v0009zb_value(v_t1, 'GB', 'after_chargeback'), pg_temp.v0009zb_value(v_t1, 'GB', 'migration_cycles'),
                       pg_temp.v0009zb_value(v_t1, 'GB', 'instruments'), pg_temp.v0009zb_value(v_t1, 'GB', 'privacy'),
                       pg_temp.v0009zb_value(v_t1, 'GB', 'changes'));
    v_exp := 'active 3, canceled 1, paused 1; missing 0 | 0 | 1: 2, 2: 1, 3: 0, 4 to 5: 0, 6+: 0 | 0'
             || ' | no discount 0 of 3; with a discount 1 of 1; discounts not stated 0 of 0'
             || ' | no variant 0; not in the catalog 0; removed from the catalog 0'
             || ' | events 0 (subscriptions 0); lines 0; billing events 0 | broken 0 (none); no status event 3'
             || ' | chargeback 1, invoice_placed 1, refund_created 1'
             || ' | chargebacks: subscription 0, order 1, unlinked 0; refunds: subscription 1, order 0, unlinked 0'
             || ' | renewed 1, retry failed 0, failed 0, canceled 0, expired 0, nothing 0, under 30 days 0'
             || ' | migrated 1; below -35: 0, -35 to -1: 0, 0 to 35: 1, above 35: 0; no store order 0; no cycle, date or interval 0'
             || ' | subscriptions: bacs_direct_debit 1, card 2, paypal 1, sepa_direct_debit 1; billing events: card 1; instrument_unknown of the latest read: no read'
             || ' | subscription 0, subscription_event 0, subscription_line 0, subscription_product_variant 0, billing_event 0, subscription_change 0; catalog text over 100 characters 0'
             || ' | amount_per_cycle 1; without a change 0';
    v_rows := v_rows || array['12', 'B2 the clean store''s values: statuses, lines, amounts, variants, orphans, the status chain, billing kinds and links, after the chargeback, migration buckets, instruments (bacs_direct_debit), privacy, changes',
      case when v_txt = v_exp and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B3. events_by_month of the clean store: its months from month 0 to the current one, each with events, no hole, no
    --     month without a renewal
    v_txt := pg_temp.v0009zb_value(v_t1, 'GB', 'events_by_month');
    v_rows := v_rows || array['13', 'B3 events by month from the store''s first month to the current one: seven months, no hole, no month without a renewal',
      case when v_txt like 'from ' || to_char(date_trunc('month', now() at time zone 'Europe/London') - interval '6 months', 'YYYY-MM') || ': %'
                and v_txt like '%; no event: none; no renewal: none'
                and array_length(regexp_split_to_array(split_part(split_part(v_txt, ': ', 2), ';', 1), ', '), 1) = 7
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- the defects, one per check, in NL
    insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, currency, source_created_at)
    values (v_t1, v_sub_nl, 'verifysubs', 's6', 'c6', 'active', 'EUR', (v_m0 + interval '10 days') at time zone 'Europe/Amsterdam');      -- no_lines
    update cma.subscription_line set currency = 'GBP' where tenant_id = v_t1 and connection_id = v_sub_nl and source_id = 'l4';            -- line_currency
    update cma.subscription set amount_per_cycle = 31.00 where tenant_id = v_t1 and connection_id = v_sub_nl and source_id = 's1';      -- amount_vs_lines
    update cma.subscription_line set variant_source_id = 'v9' where tenant_id = v_t1 and connection_id = v_sub_nl and source_id = 'l6'; -- variant_missing
    delete from cma.subscription_event where tenant_id = v_t1 and connection_id = v_sub_nl and source_id = 'e-r5'                         -- events_by_month
    returning * into v_hole;
    insert into cma.subscription_event (tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type, occurred_at)
    values (v_t1, v_sub_nl, 'verifysubs', 'e-ghost', 's-ghost', 'purchased', (v_m0 + interval '2 days') at time zone 'Europe/Amsterdam');   -- orphan_events
    insert into cma.subscription_event (tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type, occurred_at, status_from, status_to)
    values (v_t1, v_sub_nl, 'verifysubs', 'e-u3', 's3', 'resumed', (v_m0 + interval '4 months 10 days') at time zone 'Europe/Amsterdam', 'paused', 'active'); -- status_chain
    insert into cma.billing_event (tenant_id, connection_id, source_system, source_id, kind, occurred_at, order_source_id, amount, currency)
    values (v_t1, v_sub_nl, 'verifysubs', 'b9', 'chargeback', (v_m0 + interval '3 months') at time zone 'Europe/Amsterdam', '999999', 30.00, 'EUR'); -- billing_link
    insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, billing_interval, billing_interval_count, currency, source_created_at)
    values (v_t1, v_sub_nl, 'verifysubs', 's7', 'c7', 'canceled', 'month', 1, 'EUR', (v_m0 + interval '5 days') at time zone 'Europe/Amsterdam'),
           (v_t1, v_sub_nl, 'verifysubs', 's8', 'c8', 'canceled', 'month', 1, 'EUR', (v_m0 + interval '5 days') at time zone 'Europe/Amsterdam'); -- migration_cycles
    insert into cma.subscription_event (tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type, occurred_at, cycle_index, billing_to_at)
    values (v_t1, v_sub_nl, 'verifysubs', 'e-m7', 's7', 'migrated', (v_m0 + interval '5 days') at time zone 'Europe/Amsterdam', 3, (v_m0 + interval '1 month') at time zone 'Europe/Amsterdam'),
           (v_t1, v_sub_nl, 'verifysubs', 'e-m8', 's8', 'migrated', (v_m0 + interval '5 days') at time zone 'Europe/Amsterdam', 3, (v_m0 + interval '1 month') at time zone 'Europe/Amsterdam');
    insert into cma.commerce_order (tenant_id, connection_id, source_system, source_id, customer_source_id, source_created_at)
    values (v_t1, v_shop_nl, 'verifyshop', '900007', 'c7', (v_m0 - interval '2 months' - interval '60 days' + interval '12 hours') at time zone 'Europe/Amsterdam'),
           (v_t1, v_shop_nl, 'verifyshop', '900008', 'c8', (v_m0 - interval '2 months' + interval '60 days' + interval '12 hours') at time zone 'Europe/Amsterdam');
    -- (s8's order, month 0 less two months plus 60 days, lies just before its created date, month 0 + 5 days, so it counts)
    update cma.subscription set payment_instrument_type = 'other' where tenant_id = v_t1 and connection_id = v_sub_nl and source_id = 's2'; -- instruments
    alter table cma.subscription_product_variant drop constraint subscription_product_variant_variant_title_check;
    update cma.subscription_product_variant set variant_title = 'Verify device for someone@example.invalid'
    where tenant_id = v_t1 and connection_id = v_sub_nl and variant_source_id = 'v1';                                                    -- privacy (an @)
    update cma.subscription_product_variant set sku = 'VZB 0612345678'
    where tenant_id = v_t1 and connection_id = v_sub_nl and variant_source_id = 'v2';                                                    -- privacy (a phone's shape)
    insert into cma.subscription_change (tenant_id, connection_id, subscription_source_id, field, old_value, new_value, observed_at)
    values (v_t1, v_sub_nl, 's1', 'status', 'active', 'active', now() - interval '30 minutes');                                          -- changes
    -- the second tenant's own defects: an active subscription without a line, an instrument other
    insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, currency, payment_instrument_type, source_created_at)
    values (v_t2, v_sub_t2, 'verifysubs', 's6', 'c6', 'active', 'GBP', 'other', now() - interval '10 days');

    -- B4. each defect reported, with the verdict designed
    v_txt := pg_temp.v0009zb_verdicts(v_t1, 'NL');
    v_exp := 'status_mix:explain no_lines:fail lines_histogram:ok line_currency:fail amount_vs_lines:fail variant_missing:fail events_by_month:fail orphan_events:explain status_chain:explain billing_kinds:ok billing_link:explain after_chargeback:ok migration_cycles:explain instruments:fail privacy:fail changes:fail';
    v_rows := v_rows || array['14', 'B4 a store with one defect per check: each reported (fail where the CMA is likely the cause, explain where the source may be), the shape-only checks ok',
      case when v_txt = v_exp and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'none')];

    -- B5. the defects' values
    v_txt := concat_ws(' | ', pg_temp.v0009zb_value(v_t1, 'NL', 'no_lines'), pg_temp.v0009zb_value(v_t1, 'NL', 'line_currency'),
                       pg_temp.v0009zb_value(v_t1, 'NL', 'amount_vs_lines'), pg_temp.v0009zb_value(v_t1, 'NL', 'variant_missing'),
                       split_part(pg_temp.v0009zb_value(v_t1, 'NL', 'events_by_month'), '; ', 2),
                       pg_temp.v0009zb_value(v_t1, 'NL', 'orphan_events'), pg_temp.v0009zb_value(v_t1, 'NL', 'status_chain'),
                       pg_temp.v0009zb_value(v_t1, 'NL', 'billing_link'), pg_temp.v0009zb_value(v_t1, 'NL', 'migration_cycles'),
                       split_part(pg_temp.v0009zb_value(v_t1, 'NL', 'instruments'), '; ', 1), pg_temp.v0009zb_value(v_t1, 'NL', 'privacy'),
                       pg_temp.v0009zb_value(v_t1, 'NL', 'changes'));
    v_exp := '1 | 1 | no discount 1 of 3; with a discount 1 of 1; discounts not stated 0 of 0 | no variant 0; not in the catalog 1; removed from the catalog 0'
             || ' | no event: ' || to_char(v_m0 + interval '5 months', 'YYYY-MM')
             || ' | events 1 (subscriptions 1); lines 0; billing events 0 | broken 1 (active>paused 1); no status event 6'
             || ' | chargebacks: subscription 0, order 1, unlinked 1; refunds: subscription 1, order 0, unlinked 0'
             || ' | migrated 3; below -35: 1, -35 to -1: 0, 0 to 35: 1, above 35: 1; no store order 0; no cycle, date or interval 0'
             || ' | subscriptions: bacs_direct_debit 1, card 2, none 3, other 1, paypal 1'
             || ' | subscription 0, subscription_event 0, subscription_line 0, subscription_product_variant 2, billing_event 0, subscription_change 0; catalog text over 100 characters 0'
             || ' | amount_per_cycle 1, status 1; without a change 1';
    v_rows := v_rows || array['15', 'B5 the defects'' values: the subscription without a line, the line in GBP, the amount, the variant, the month, the orphan, active after paused, the unlinked chargeback, three buckets, other, the @ and the phone, the change that changed nothing',
      case when v_txt = v_exp and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B6. the second tenant's defects never in the first's audit (two stores, GB still clean); its own audit reports them
    v_txt := (select count(*) from cma.subscription_audit_of(v_t1) a)::text || ' ' || pg_temp.v0009zb_verdicts(v_t1, 'GB')
             || ' | ' || (select string_agg(distinct a.store collate "C", ',' order by a.store collate "C") from cma.subscription_audit_of(v_t1) a)
             || ' | ' || pg_temp.v0009zb_value(v_t2, 'GB', 'no_lines') || ' ' || (select a.verdict from cma.subscription_audit_of(v_t2) a where a.check_key = 'instruments');
    v_rows := v_rows || array['16', 'B6 tenants apart: the first''s audit 32 rows over its two stores, GB still clean; the second''s audit its own defects',
      case when v_txt = '32 ' || v_clean || ' | GB,NL | 1 fail' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B7. each defect removed: every check as the clean store's
    delete from cma.subscription where tenant_id = v_t1 and connection_id = v_sub_nl and source_id in ('s6', 's7', 's8');
    update cma.subscription_line set currency = 'EUR' where tenant_id = v_t1 and connection_id = v_sub_nl and source_id = 'l4';
    update cma.subscription set amount_per_cycle = 30.00 where tenant_id = v_t1 and connection_id = v_sub_nl and source_id = 's1';
    update cma.subscription_line set variant_source_id = 'v1' where tenant_id = v_t1 and connection_id = v_sub_nl and source_id = 'l6';
    insert into cma.subscription_event select v_hole.*;
    delete from cma.subscription_event where tenant_id = v_t1 and connection_id = v_sub_nl and source_id in ('e-ghost', 'e-u3', 'e-m7', 'e-m8');
    delete from cma.billing_event where tenant_id = v_t1 and connection_id = v_sub_nl and source_id = 'b9';
    delete from cma.commerce_order where tenant_id = v_t1 and connection_id = v_shop_nl and source_id in ('900007', '900008');
    update cma.subscription set payment_instrument_type = 'sepa_direct_debit' where tenant_id = v_t1 and connection_id = v_sub_nl and source_id = 's2';
    update cma.subscription_product_variant set variant_title = 'Verify device' where tenant_id = v_t1 and connection_id = v_sub_nl and variant_source_id = 'v1';
    update cma.subscription_product_variant set sku = 'VZB-2' where tenant_id = v_t1 and connection_id = v_sub_nl and variant_source_id = 'v2';
    delete from cma.subscription_change where tenant_id = v_t1 and connection_id = v_sub_nl and field = 'status';
    v_txt := pg_temp.v0009zb_verdicts(v_t1, 'NL');
    v_rows := v_rows || array['17', 'B7 each defect removed: every check of that store as the clean store''s',
      case when v_txt = v_clean and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'none')];

    -- B8. a second store of a market labelled with its handle; switched off, it is left out and the market's label returns
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, signing_secret_name)
    values (v_t1, 'verifyshop', 'Verify shop GB two', 'verify-zb-gb2.shop.example', 'commerce', 'verify-zb-shop-4') returning id into v_shop_gb2;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t1, 'verifysubs', 'Verify subscriptions GB two', 'verify-zb-gb2.shop.example', 'subscriptions', 'verify-zb-key-4') returning id into v_sub_gb2;
    insert into cma.commerce_store (tenant_id, connection_id, handle, name, market, currency, time_zone)
    values (v_t1, v_shop_gb2, 'verify-zb-gb2', 'Verify store GB two', 'GB', 'GBP', 'Europe/London');
    v_txt := (select string_agg(distinct a.store collate "C", ',' order by a.store collate "C") from cma.subscription_audit_of(v_t1) a);
    update cma.integration_connection set status = 'inactive' where tenant_id = v_t1 and id = v_sub_gb2;
    v_txt := v_txt || ' | ' || (select string_agg(distinct a.store collate "C", ',' order by a.store collate "C") from cma.subscription_audit_of(v_t1) a);
    v_rows := v_rows || array['18', 'B8 two stores of a market labelled market and handle; a switched-off connection left out (a placeholder store)',
      case when v_txt = 'GB verify-zb-gb,GB verify-zb-gb2,NL | GB,NL' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'none')];

    -- B9. an unknown tenant CMA02; the application refused execution
    v_txt := pg_temp.v0009zb_code(format('select * from cma.subscription_audit_of(%L)', '00000000-0000-0000-0000-000000000000'));
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_ing1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0009zb_code(format('select * from cma.subscription_audit_of(%L)', v_t1))
             || ' ' || pg_temp.v0009zb_code(format('select * from cma.subscription_audit_stores_of(%L)', v_t1));
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['19', 'B9 an unknown tenant CMA02; the application may not execute the audit or its helper (42501)',
      case when v_txt = 'CMA02 42501 42501' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B10. both tables' checks take bacs_direct_debit and refuse klarna
    v_txt := pg_temp.v0009zb_code(format($q$update cma.subscription set payment_instrument_type = 'bacs_direct_debit' where tenant_id = %L and connection_id = %L and source_id = 's1'$q$, v_t1, v_sub_gb))
             || ' ' || pg_temp.v0009zb_code(format($q$insert into cma.billing_event (tenant_id, connection_id, source_system, source_id, kind, occurred_at, instrument_type) values (%L, %L, 'verifysubs', 'b-bacs', 'refund_created', now(), 'bacs_direct_debit')$q$, v_t1, v_sub_gb))
             || ' ' || pg_temp.v0009zb_code(format($q$update cma.subscription set payment_instrument_type = 'klarna' where tenant_id = %L and connection_id = %L and source_id = 's1'$q$, v_t1, v_sub_gb))
             || ' ' || pg_temp.v0009zb_code(format($q$insert into cma.billing_event (tenant_id, connection_id, source_system, source_id, kind, occurred_at, instrument_type) values (%L, %L, 'verifysubs', 'b-klarna', 'refund_created', now(), 'klarna')$q$, v_t1, v_sub_gb));
    v_rows := v_rows || array['20', 'B10 cma.subscription and cma.billing_event take bacs_direct_debit and refuse klarna (23514)',
      case when v_txt = 'ok ok 23514 23514' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['59', 'B the block ran to the end', 'FAIL', sqlstate || ': ' || sqlerrm];
  end;
  insert into verify_0009zb (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0009zb values (59, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- The helpers are dropped first, so the verdict is the last thing the script prints
drop function if exists pg_temp.v0009zb_code(text);
drop function if exists pg_temp.v0009zb_verdicts(uuid, text);
drop function if exists pg_temp.v0009zb_value(uuid, text, text);
drop function if exists pg_temp.v0009zb_fill(uuid, uuid, uuid, text, text);

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0009zb
      union all
      select 99, 'verdict',
             case when not current_setting('verify.dev')::boolean then 'REFUSED'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0009zb where result = 'PASS') = 14
                       and not exists (select 1 from verify_0009zb where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('205_verify_subscription_audit: %s PASS, %s FAIL', (select count(*) from verify_0009zb where result = 'PASS'),
                                                                      (select count(*) from verify_0009zb where result <> 'PASS'))) x
order by ord;
reset role;
