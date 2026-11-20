-- =============================================================================================
-- 211_verify_subscription_facts.sql: verifies addition 0009ze, the subscription facts (brief B39 continued, Part B39c)
-- =============================================================================================
-- Dev and local databases only, as 207: it refuses a database without the dev seed (no active agent.two@example.com):
-- block B's checks then read FAIL and the verdict REFUSED. Block A only reads; block B works on a throwaway tenant inside
-- a subtransaction that is always rolled back, so nothing stays. It writes the scenario's rows as the owner, directly,
-- sets the mapping as the tenant's administrator and refreshes the facts as its scheduler (cma_app, row-level security
-- on). Every check writes one row, PASS or FAIL, and the last row is the verdict, because Cloud SQL Studio shows no
-- notices. Run as your own IAM login after 210_subscription_facts.sql, in dev; then the verifies 210's header names.
-- Adapters, handles, ids, codes and secret names are invented data values; no row carries a name, an address, an email
-- or a phone number.
--   A  the addition row after 0009zc; the tables' row-level security, grants and audit (the mapping audited, the takes
--      not); the functions the application's, the fill a definer's; the payment state's columns (the old nine first);
--      the readers; Customers → Active's inputs digest over 174's twelve markers equal to 174's own (kept below), on the
--      dev seed's tenants
--   B  on a throwaway tenant with two stores (IE: the payment states, outcomes, device units, survival; DE: a month grid):
--      the settings' refusals; the mapping's refusals and its removal; device units (a one-time line left out, an
--      unmapped line null); every payment state and the precedence (a chargeback on the latest renewal, one before a
--      later renewal, on a purchase, an invoice placed, overdue and paid, In retry over a chargeback, Failed with its
--      return code); every renewal outcome; every movement kind on the month grid, the base at each month's start and
--      end, the churn and failed rates against a hand count, the store's first complete month; survival with migrated
--      subscriptions left out; both original start bases; the device check both ways; the unmapped variants; the take's
--      skip (fresh, unchanged); another tenant's application sees none of it; the one-time fill of purchases' orders
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
-- dev or a local database only: the dev seed's agent.two@example.com active, as 203, 205 and 207
select set_config('verify.dev', (select exists (select 1 from cma.app_user u where u.email = 'agent.two@example.com' and u.status = 'active'))::text, false);

drop table if exists pg_temp.verify_0009ze;
create temp table verify_0009ze (ord int, check_name text, result text, detail text);

-- The error a statement raises as its SQLSTATE, or 'ok'
create or replace function pg_temp.v0009ze_code(p_sql text)
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

-- 174's Customers → Active inputs digest, as 174 defined it (the rewrite in 210 must answer the same over the same parts)
create or replace function pg_temp.v0009ze_key_174(p_tenant_id uuid)
returns text
language sql stable
as $$
  select md5(concat_ws('|',
    (select concat_ws('@', count(*), extract(epoch from max(x.synced_at)), sum((extract(epoch from x.synced_at) * 1000000)::bigint))
     from cma.subscription x where x.tenant_id = p_tenant_id),
    (select concat_ws('@', count(*), extract(epoch from max(x.synced_at)), sum((extract(epoch from x.synced_at) * 1000000)::bigint))
     from cma.subscription_event x where x.tenant_id = p_tenant_id),
    (select concat_ws('@', count(*), extract(epoch from max(x.synced_at)), sum((extract(epoch from x.synced_at) * 1000000)::bigint))
     from cma.device x where x.tenant_id = p_tenant_id),
    (select concat_ws('@', count(*), sum(hash_record_extended(row(
              x.id, x.connection_id, x.source_system, x.source_id, x.state, x.locale, x.orders_count, x.amount_spent,
              x.amount_currency, x.source_created_at, x.source_updated_at, x.source_deleted_at, x.phone_hash,
              x.crm_connection_id, x.crm_contact_source_id, x.matched_at), 0)))
     from cma.commerce_customer x where x.tenant_id = p_tenant_id),
    (select concat_ws('@', count(*), sum(hash_record_extended(row(
              x.id, x.connection_id, x.source_system, x.source_id, x.order_name, x.customer_source_id, x.source_created_at,
              x.processed_at, x.source_updated_at, x.cancelled_at, x.cancel_reason, x.is_test, x.currency, x.total_amount,
              x.subtotal_amount, x.tax_amount, x.discount_amount, x.refunded_amount, x.financial_status,
              x.fulfillment_status, x.source_name, x.app_ref, x.landing_host, x.landing_path, x.utm, x.referring_host,
              x.tags, x.prior_orders_count, x.prior_count_exact, x.order_kind, x.source_deleted_at, x.phone_hash), 0)))
     from cma.commerce_order x where x.tenant_id = p_tenant_id),
    (select concat_ws('@', count(*), sum(hash_record_extended(row(
              x.id, x.connection_id, x.source_system, x.source_id, x.country, x.language, x.source_updated_at,
              x.source_deleted_at, x.currency, x.store, x.country_source, x.source_created_at, x.segment), 0)))
     from cma.crm_contact x where x.tenant_id = p_tenant_id),
    (select concat_ws('@', count(*), sum(hash_record_extended(x, 0))) from cma.commerce_store x where x.tenant_id = p_tenant_id),
    (select concat_ws('@', count(*), sum(hash_record_extended(x, 0))) from cma.device_status x where x.tenant_id = p_tenant_id),
    (select concat_ws('@', count(*), sum(hash_record_extended(x, 0))) from cma.device_model x where x.tenant_id = p_tenant_id),
    (select concat_ws('@', count(*), sum(hash_record_extended(x, 0))) from cma.market x where x.tenant_id = p_tenant_id),
    (select concat_ws('@', count(*), sum(hash_record_extended(row(x.id, x.key, x.adapter, x.kind, x.external_account_id, x.status), 0)))
     from cma.integration_connection x where x.tenant_id = p_tenant_id),
    (select t.timezone from cma.tenant t where t.id = p_tenant_id)))
$$;

-- A. Structure and privileges
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_txt     text;
  v_bad     text;
begin
  -- A1. the addition is recorded, after 0009zc
  insert into verify_0009ze values (1, 'A1 addition 0009ze recorded, after 0009zc',
    case when exists (select 1 from cma.schema_migration where version = '0009ze')
              and exists (select 1 from cma.schema_migration where version = '0009zc') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the six tables: row-level security on, the application's grants; the mapping audited, the takes not
  select string_agg(c.relname || ':' || c.relrowsecurity || c.relforcerowsecurity
                    || ':' || has_table_privilege('cma_app', c.oid, 'select') || has_table_privilege('cma_app', c.oid, 'insert')
                    || ':' || exists (select 1 from pg_trigger g where g.tgrelid = c.oid and g.tgname = 'audit'), ' ' order by c.relname collate "C")
  into v_txt
  from pg_class c join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'cma'
  where c.relname in ('subscription_variant_mapping', 'subscription_take_state', 'subscription_take', 'subscription_month_take', 'renewal_outcome',
                      'subscription_survival_take');
  insert into verify_0009ze values (2, 'A2 the six tables: row-level security on, the application''s grants; the mapping audited, the takes not',
    case when v_txt = 'renewal_outcome:truefalse:truetrue:false subscription_month_take:truefalse:truetrue:false subscription_survival_take:truefalse:truetrue:false subscription_take:truefalse:truetrue:false subscription_take_state:truefalse:truetrue:false subscription_variant_mapping:truefalse:truetrue:true'
              and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'missing'));

  -- A3. every new function the application's, none public's; the fill a definer's with a pinned search path; the
  --     payment state's reader the readers' only
  select string_agg(f, ', ') into v_bad
  from unnest(array['cma.payment_states()', 'cma.subscription_payment_state_of(uuid)', 'cma.subscription_payment_state_of(uuid,uuid[])',
    'cma.set_subscription_variant_mapping(uuid,text,text,text,integer,text)', 'cma.subscription_variants_of(uuid,uuid)',
    'cma.subscription_variants(uuid)', 'cma.subscription_device_units_of(uuid)', 'cma.inputs_markers_of(uuid,text[])',
    'cma.subscription_interval_group_of(text,integer)', 'cma.subscription_amount_at(uuid,uuid,text,timestamptz,numeric,text,text,integer)',
    'cma.subscription_moves_of(uuid,timestamptz)', 'cma.renewal_outcomes_of(uuid)', 'cma.subscription_facts_inputs_key_of(uuid,date)',
    'cma.subscription_facts_refresh_of(uuid,boolean,timestamptz)', 'cma.subscription_facts_refresh()',
    'cma.ingest_fill_purchase_orders(uuid,jsonb)']) f
  where to_regprocedure(f) is null or not has_function_privilege('cma_app', f, 'execute') or has_function_privilege('public', f, 'execute');
  v_txt := (select p.prosecdef || ':' || coalesce(array_to_string(p.proconfig, ','), '-') from pg_proc p
            where p.oid = 'cma.ingest_fill_purchase_orders(uuid,jsonb)'::regprocedure)
           || ' | ' || has_function_privilege('cma_readonly', 'cma_read.subscription_payment_state_rows()', 'execute')
           || has_function_privilege('cma_app', 'cma_read.subscription_payment_state_rows()', 'execute');
  insert into verify_0009ze values (3, 'A3 the functions the application''s and no one else''s; the fill a definer''s, search path pinned; the reader the readers''',
    case when v_bad is null and v_txt = 'true:search_path=pg_catalog, cma, pg_temp | truefalse' and not v_provoke then 'PASS' else 'FAIL' end,
    coalesce('not the application''s only: ' || v_bad || '; ', '') || coalesce(v_txt, 'missing'));

  -- A4. the payment state's columns: 118's nine first, then the five of 0009ze; the readers with their columns
  v_txt := (select string_agg(a, ',' order by o) from unnest(
              (select p.proargnames from pg_proc p where p.oid = 'cma.subscription_payment_state_of(uuid)'::regprocedure)) with ordinality x(a, o)
            where o > 1)
           || ' | ' || (select string_agg(c.relname, ',' order by c.relname collate "C") from pg_class c join pg_namespace n on n.oid = c.relnamespace
                        where n.nspname = 'cma_read' and c.relname in ('subscription_take', 'subscription_month_take', 'subscription_churn_month',
                              'renewal_outcome', 'subscription_survival', 'subscription_payment_state', 'dq_subscription_variant_unmapped',
                              'dq_subscription_device_units_mismatch'));
  insert into verify_0009ze values (4, 'A4 the payment state''s columns (the old nine first) and the eight readers',
    case when v_txt = 'subscription_id,connection_id,source_id,customer_source_id,status,payment_state,retry_cycle,retry_since,last_attempt,state_since,overdue,chargeback_return_code,amount_at_risk,currency | dq_subscription_device_units_mismatch,dq_subscription_variant_unmapped,renewal_outcome,subscription_churn_month,subscription_month_take,subscription_payment_state,subscription_survival,subscription_take'
              and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'missing'));

  -- A5. Customers → Active's digest: over 174's twelve markers 210's parts give 174's own digest, for every tenant; the
  --     digest itself is the thirteen parts' (with the billing events)
  select string_agg(t.slug || ':' || (md5(array_to_string((cma.inputs_markers_of(t.id, array['subscription', 'subscription_event', 'device',
                      'commerce_customer', 'commerce_order', 'crm_contact', 'commerce_store', 'device_status', 'device_model', 'market',
                      'integration_connection', 'timezone'])), '|')) = pg_temp.v0009ze_key_174(t.id))::text
                    || ':' || (cma.active_inputs_key_of(t.id) = md5(array_to_string(cma.inputs_markers_of(t.id, array['subscription',
                      'subscription_event', 'device', 'commerce_customer', 'commerce_order', 'crm_contact', 'commerce_store', 'device_status',
                      'device_model', 'market', 'integration_connection', 'timezone', 'billing_event']), '|')))::text, ' ' order by t.slug collate "C")
  into v_txt from cma.tenant t;
  insert into verify_0009ze values (5, 'A5 Customers → Active''s digest: 174''s twelve markers give 174''s digest, every tenant; the digest adds the billing events',
    case when v_txt is not null and v_txt not like '%false%' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no tenant'));
  v_txt := pg_temp.v0009ze_code('select cma.inputs_markers_of(gen_random_uuid(), array[''orders''])');
  insert into verify_0009ze values (6, 'A6 an unknown input is refused (CMA04)',
    case when v_txt = 'CMA04' and not v_provoke then 'PASS' else 'FAIL' end, v_txt);
end
$$;

-- B. Behaviour on a throwaway tenant (rolled back)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_dev     boolean := current_setting('verify.dev')::boolean;
  v_rows    text[] := '{}';
  v_t uuid; v_adm uuid; v_agent uuid; v_sch uuid; v_ing uuid; v_other uuid; v_oing uuid;
  v_shop_a uuid; v_sub_a uuid; v_shop_b uuid; v_sub_b uuid; v_assets uuid;
  v_m0 timestamp := date_trunc('month', now() at time zone 'Europe/London') - interval '6 months';
  v_mon date := (date_trunc('month', now() at time zone 'Europe/London') - interval '6 months')::date;
  v_txt text; v_j jsonb; v_j2 jsonb; v_key1 text; v_key2 text;
begin
  if not v_dev then
    insert into verify_0009ze values (59, 'B a dev or local database (the dev seed''s agent.two@example.com active)', 'FAIL',
      'REFUSED: no dev seed, so this is no dev or local database; nothing ran');
    return;
  end if;
  begin
    v_t := cma.create_tenant('verify-0009ze', 'Verify 0009ze', 'Europe/London');
    perform set_config('app.tenant_id', v_t::text, true);
    select x.user_id into v_ing from cma.app_user_external_id x where x.tenant_id = v_t and x.system = 'ingest' and x.external_id = 'ingest';
    select u.id into v_sch from cma.app_user u where u.tenant_id = v_t and u.kind = 'system' and u.email = 'scheduler@system.invalid';
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify.ze.admin@example.invalid', 'Verify admin') returning id into v_adm;
    insert into cma.user_role (tenant_id, user_id, role_id) select v_t, v_adm, r.id from cma.app_role r where r.tenant_id = v_t and r.key = 'admin';
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify.ze.agent@example.invalid', 'Verify agent') returning id into v_agent;
    insert into cma.user_role (tenant_id, user_id, role_id) select v_t, v_agent, r.id from cma.app_role r where r.tenant_id = v_t and r.key = 'agent';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, signing_secret_name)
    values (v_t, 'verifyshop', 'Verify shop A', 'verify-ze-a.shop.example', 'commerce', 'verify-ze-shop-1') returning id into v_shop_a;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t, 'verifysubs', 'Verify subscriptions A', 'verify-ze-a.shop.example', 'subscriptions', 'verify-ze-key-1') returning id into v_sub_a;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, signing_secret_name)
    values (v_t, 'verifyshop', 'Verify shop B', 'verify-ze-b.shop.example', 'commerce', 'verify-ze-shop-2') returning id into v_shop_b;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t, 'verifysubs', 'Verify subscriptions B', 'verify-ze-b.shop.example', 'subscriptions', 'verify-ze-key-2') returning id into v_sub_b;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t, 'verifyassets', 'Verify assets', 'verify-ze-assets', 'assets', 'verify-ze-key-3') returning id into v_assets;
    insert into cma.commerce_store (tenant_id, connection_id, handle, name, market, currency, time_zone)
    values (v_t, v_shop_a, 'verify-ze-a', 'Verify store A', 'IE', 'EUR', 'Europe/London'),
           (v_t, v_shop_b, 'verify-ze-b', 'Verify store B', 'DE', 'EUR', 'Europe/London');
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency)
    values (v_t, 'IE', 'Verify IE', 'Europe/London', 'en', 'EUR'), (v_t, 'DE', 'Verify DE', 'Europe/London', 'de', 'EUR') on conflict do nothing;
    insert into cma.device_model (tenant_id, key, name) values (v_t, 'vzm', 'Verify model');
    insert into cma.device_status (tenant_id, key, name, is_in_field) values (v_t, 'vz_field', 'Verify in the field', true);

    -- B1. the settings: propositions of codes only, the refresh age from 1 to 1440 minutes
    v_txt := pg_temp.v0009ze_code(format('insert into cma.tenant_setting (tenant_id, key, value) values (%L, ''subscriptions.propositions'', ''p1,P2'')', v_t))
             || ' ' || pg_temp.v0009ze_code(format('insert into cma.tenant_setting (tenant_id, key, value) values (%L, ''subscriptions.take_refresh_minutes'', ''0'')', v_t))
             || ' ' || pg_temp.v0009ze_code(format('insert into cma.tenant_setting (tenant_id, key, value) values (%L, ''subscriptions.propositions'', ''p1,p2'')', v_t));
    v_rows := v_rows || array['11', 'B1 subscriptions.propositions takes codes only and take_refresh_minutes 1 to 1440 (CMA04); p1,p2 stored',
      case when v_txt = 'CMA04 CMA04 ok' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- the IE store's subscriptions (all created in month 0, monthly, 30 EUR): a1 to a9 as the checks below describe, a10
    -- migrated
    insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, billing_interval,
                                  billing_interval_count, amount_per_cycle, currency, source_created_at, source_updated_at)
    select v_t, v_sub_a, 'verifysubs', 'a' || n, 'c' || n, case when n = 8 then 'failed' else 'active' end, 'month', 1, 30, 'EUR',
           (v_m0 + interval '1 day') at time zone 'Europe/London', (v_m0 + interval '1 day') at time zone 'Europe/London'
    from generate_series(1, 10) n;
    insert into cma.subscription_event (tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type, occurred_at,
                                        cycle_index, attempt, error_code, status_from, status_to, order_source_id, raw)
    values
      (v_t, v_sub_a, 'verifysubs', 'pa3', 'a3', 'purchased', (v_m0 + interval '1 day') at time zone 'Europe/London', null, null, null, null, null, null, '{"orderId": "9003"}'),
      (v_t, v_sub_a, 'verifysubs', 'pa1', 'a1', 'purchased', (v_m0 + interval '1 day') at time zone 'Europe/London', null, null, null, null, null, null, '{}'),
      (v_t, v_sub_a, 'verifysubs', 'ma10', 'a10', 'migrated', (v_m0 + interval '1 day') at time zone 'Europe/London', 1, null, null, null, null, null, '{}'),
      (v_t, v_sub_a, 'verifysubs', 'ra1-1', 'a1', 'renewed', (v_m0 + interval '1 month 1 day') at time zone 'Europe/London', 1, null, null, null, null, '1001', '{}'),
      (v_t, v_sub_a, 'verifysubs', 'ra1-2', 'a1', 'renewed', (v_m0 + interval '2 months 1 day') at time zone 'Europe/London', 2, null, null, null, null, '1002', '{}'),
      (v_t, v_sub_a, 'verifysubs', 'ra2-1', 'a2', 'renewed', (v_m0 + interval '1 month 2 days') at time zone 'Europe/London', 1, null, null, null, null, '1101', '{}'),
      (v_t, v_sub_a, 'verifysubs', 'ra2-2', 'a2', 'renewed', (v_m0 + interval '2 months 2 days') at time zone 'Europe/London', 2, null, null, null, null, '1102', '{}'),
      (v_t, v_sub_a, 'verifysubs', 'ra7-1', 'a7', 'renewed', (v_m0 + interval '1 month 1 day') at time zone 'Europe/London', 1, null, null, null, null, '1701', '{}'),
      (v_t, v_sub_a, 'verifysubs', 'ra7-2', 'a7', 'renewed', (v_m0 + interval '2 months 1 day') at time zone 'Europe/London', 2, null, null, null, null, '1702', '{}'),
      (v_t, v_sub_a, 'verifysubs', 'fa7-3', 'a7', 'renew_failed', (v_m0 + interval '3 months 1 day') at time zone 'Europe/London', 3, 1, 'CARD_DECLINED', null, null, null, '{}'),
      (v_t, v_sub_a, 'verifysubs', 'ra8-1', 'a8', 'renewed', (v_m0 + interval '1 month 1 day') at time zone 'Europe/London', 1, null, null, null, null, '1801', '{}'),
      (v_t, v_sub_a, 'verifysubs', 'sa8', 'a8', 'status_changed', (v_m0 + interval '1 month 24 days') at time zone 'Europe/London', null, null, null, 'active', 'failed', null, '{}'),
      (v_t, v_sub_a, 'verifysubs', 'fa9-1', 'a9', 'renew_failed', (v_m0 + interval '1 month') at time zone 'Europe/London', 1, 1, 'INSUFFICIENT_FUNDS', null, null, null, '{}'),
      (v_t, v_sub_a, 'verifysubs', 'pm9', 'a9', 'payment_method_changed', (v_m0 + interval '1 month 1 day') at time zone 'Europe/London', null, null, null, null, null, null, '{}'),
      (v_t, v_sub_a, 'verifysubs', 'ra9-1', 'a9', 'renewed', (v_m0 + interval '1 month 3 days') at time zone 'Europe/London', 1, null, null, null, null, '1901', '{}'),
      (v_t, v_sub_a, 'verifysubs', 'fa9-2', 'a9', 'renew_failed', (v_m0 + interval '2 months') at time zone 'Europe/London', 2, 1, 'INSUFFICIENT_FUNDS', null, null, null, '{}'),
      (v_t, v_sub_a, 'verifysubs', 'ra9-2', 'a9', 'renewed', (v_m0 + interval '2 months 1 day') at time zone 'Europe/London', 2, null, null, null, null, '1902', '{}'),
      (v_t, v_sub_a, 'verifysubs', 'fa9-3', 'a9', 'renew_failed', (v_m0 + interval '3 months') at time zone 'Europe/London', 3, 1, 'INSUFFICIENT_FUNDS', null, null, null, '{}'),
      (v_t, v_sub_a, 'verifysubs', 'ra9-3', 'a9', 'renewed', (v_m0 + interval '3 months 1 day') at time zone 'Europe/London', 3, null, null, null, null, '1903', '{}');
    insert into cma.billing_event (tenant_id, connection_id, source_system, source_id, kind, occurred_at, subscription_source_id, customer_source_id,
                                   order_source_id, renewal_source_id, return_code)
    values
      (v_t, v_sub_a, 'verifysubs', 'cb1', 'chargeback', (v_m0 + interval '2 months 9 days') at time zone 'Europe/London', null, null, '1002', null, 'MD06'),
      (v_t, v_sub_a, 'verifysubs', 'cb2', 'chargeback', (v_m0 + interval '1 month 19 days') at time zone 'Europe/London', null, null, '1101', null, 'MD06'),
      (v_t, v_sub_a, 'verifysubs', 'cb3', 'chargeback', (v_m0 + interval '0 months 9 days') at time zone 'Europe/London', null, null, '9003', null, 'MD01'),
      (v_t, v_sub_a, 'verifysubs', 'cb7', 'chargeback', (v_m0 + interval '2 months 9 days') at time zone 'Europe/London', null, null, '1702', null, 'MD06'),
      (v_t, v_sub_a, 'verifysubs', 'cb8', 'chargeback', (v_m0 + interval '1 month 9 days') at time zone 'Europe/London', null, null, '1801', null, 'AM04'),
      (v_t, v_sub_a, 'verifysubs', 'ip4', 'invoice_placed', (v_m0 + interval '2 months 4 days') at time zone 'Europe/London', null, 'c4', null, 'r4', null),
      (v_t, v_sub_a, 'verifysubs', 'ip5', 'invoice_placed', (v_m0 + interval '2 months 4 days') at time zone 'Europe/London', 'a5', 'c5', null, 'r5', null),
      (v_t, v_sub_a, 'verifysubs', 'io5', 'invoice_overdue', (v_m0 + interval '2 months 20 days') at time zone 'Europe/London', null, 'c5', null, 'r5', null),
      (v_t, v_sub_a, 'verifysubs', 'ip6', 'invoice_placed', (v_m0 + interval '2 months 4 days') at time zone 'Europe/London', 'a6', 'c6', null, 'r6', null),
      (v_t, v_sub_a, 'verifysubs', 'pd6', 'invoice_paid', (v_m0 + interval '2 months 8 days') at time zone 'Europe/London', null, 'c6', null, 'r6', null);
    -- lines: a1 two device units (2 of a device variant), an accessory and a one-time line left unmapped; a2 one device;
    -- a3 an unmapped variant; a4 and a6 one device each
    insert into cma.subscription_product_variant (tenant_id, connection_id, source_system, product_source_id, variant_source_id, product_title, variant_title, sku)
    values (v_t, v_sub_a, 'verifysubs', 'pr1', 'vdev', 'Verify plan', 'Monthly', 'VZ-1'), (v_t, v_sub_a, 'verifysubs', 'pr2', 'vacc', 'Verify pads', 'Set', 'VZ-2'),
           (v_t, v_sub_a, 'verifysubs', 'pr3', 'vonce', 'Verify fee', 'Once', 'VZ-3'), (v_t, v_sub_a, 'verifysubs', 'pr4', 'vunm', 'Verify other', 'Monthly', 'VZ-4');
    insert into cma.subscription_line (tenant_id, connection_id, source_system, source_id, subscription_source_id, variant_source_id, quantity,
                                       amount_per_cycle, currency, billing_interval, billing_interval_count, recurring_cycle_limit)
    values (v_t, v_sub_a, 'verifysubs', 'l1', 'a1', 'vdev', 2, 20, 'EUR', 'month', 1, null),
           (v_t, v_sub_a, 'verifysubs', 'l2', 'a1', 'vacc', 1, 10, 'EUR', 'month', 1, null),
           (v_t, v_sub_a, 'verifysubs', 'l3', 'a1', 'vonce', 1, 0, 'EUR', 'month', 1, 1),
           (v_t, v_sub_a, 'verifysubs', 'l4', 'a2', 'vdev', 1, 30, 'EUR', 'month', 1, null),
           (v_t, v_sub_a, 'verifysubs', 'l5', 'a3', 'vunm', 1, 30, 'EUR', 'month', 1, null),
           (v_t, v_sub_a, 'verifysubs', 'l6', 'a4', 'vdev', 1, 30, 'EUR', 'month', 1, null),
           (v_t, v_sub_a, 'verifysubs', 'l7', 'a6', 'vdev', 1, 30, 'EUR', 'month', 1, null);
    -- devices in the field: one on a1 (two paid: more_paid), two on a2 (one paid: more_placed), one on a6 (equal)
    insert into cma.device (tenant_id, connection_id, source_system, source_id, model_key, market, device_status_key, subscription_ref)
    values (v_t, v_assets, 'verifyassets', 'd1', 'vzm', 'IE', 'vz_field', 'a1'), (v_t, v_assets, 'verifyassets', 'd2', 'vzm', 'IE', 'vz_field', 'a2'),
           (v_t, v_assets, 'verifyassets', 'd3', 'vzm', 'IE', 'vz_field', 'a2'), (v_t, v_assets, 'verifyassets', 'd4', 'vzm', 'IE', 'vz_field', 'a6');
    -- a1's customer ordered in the store the day before its subscription (first order); a2's ordered after it
    insert into cma.commerce_order (tenant_id, connection_id, source_system, source_id, customer_source_id, source_created_at)
    values (v_t, v_shop_a, 'verifyshop', '5001', 'c1', v_m0 at time zone 'Europe/London'),
           (v_t, v_shop_a, 'verifyshop', '5002', 'c2', (v_m0 + interval '3 days') at time zone 'Europe/London');

    -- the DE store's month grid: its first event on day 15 of month 1, so month 1 is not complete and month 2 is its first
    -- complete month. b1 churns in month 3, b2 moves to failed in month 3, b3 pauses and resumes in month 2, b4 (migrated)
    -- churns in month 4, b5 starts and churns in month 2 and is reactivated in month 3, b6 stays
    insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, billing_interval,
                                  billing_interval_count, amount_per_cycle, currency, source_created_at, source_updated_at, canceled_at)
    values (v_t, v_sub_b, 'verifysubs', 'b1', 'd1', 'canceled', 'month', 1, 30, 'EUR', (v_m0 + interval '1 month 14 days') at time zone 'Europe/London', (v_m0 + interval '3 months 4 days') at time zone 'Europe/London', (v_m0 + interval '3 months 4 days') at time zone 'Europe/London'),
           (v_t, v_sub_b, 'verifysubs', 'b2', 'd2', 'failed', 'month', 1, 30, 'EUR', (v_m0 + interval '1 month 15 days') at time zone 'Europe/London', (v_m0 + interval '3 months 5 days') at time zone 'Europe/London', null),
           (v_t, v_sub_b, 'verifysubs', 'b3', 'd3', 'active', 'month', 1, 30, 'EUR', (v_m0 + interval '1 month 16 days') at time zone 'Europe/London', (v_m0 + interval '2 months 19 days') at time zone 'Europe/London', null),
           (v_t, v_sub_b, 'verifysubs', 'b4', 'd4', 'canceled', 'month', 1, 30, 'EUR', (v_m0 + interval '1 month 14 days') at time zone 'Europe/London', (v_m0 + interval '4 months') at time zone 'Europe/London', (v_m0 + interval '4 months') at time zone 'Europe/London'),
           (v_t, v_sub_b, 'verifysubs', 'b5', 'd5', 'active', 'month', 1, 30, 'EUR', (v_m0 + interval '2 months 2 days') at time zone 'Europe/London', (v_m0 + interval '3 months') at time zone 'Europe/London', null),
           (v_t, v_sub_b, 'verifysubs', 'b6', 'd6', 'active', 'month', 1, 30, 'EUR', (v_m0 + interval '1 month 19 days') at time zone 'Europe/London', (v_m0 + interval '1 month 19 days') at time zone 'Europe/London', null);
    insert into cma.subscription_event (tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type, occurred_at, status_from, status_to)
    values (v_t, v_sub_b, 'verifysubs', 'pb1', 'b1', 'purchased', (v_m0 + interval '1 month 14 days') at time zone 'Europe/London', null, null),
           (v_t, v_sub_b, 'verifysubs', 'xb1', 'b1', 'canceled', (v_m0 + interval '3 months 4 days') at time zone 'Europe/London', 'active', 'canceled'),
           (v_t, v_sub_b, 'verifysubs', 'pb2', 'b2', 'purchased', (v_m0 + interval '1 month 15 days') at time zone 'Europe/London', null, null),
           (v_t, v_sub_b, 'verifysubs', 'sb2', 'b2', 'status_changed', (v_m0 + interval '3 months 5 days') at time zone 'Europe/London', 'active', 'failed'),
           (v_t, v_sub_b, 'verifysubs', 'pb3', 'b3', 'purchased', (v_m0 + interval '1 month 16 days') at time zone 'Europe/London', null, null),
           (v_t, v_sub_b, 'verifysubs', 'zb3', 'b3', 'paused', (v_m0 + interval '2 months') at time zone 'Europe/London', 'active', 'paused'),
           (v_t, v_sub_b, 'verifysubs', 'ub3', 'b3', 'resumed', (v_m0 + interval '2 months 19 days') at time zone 'Europe/London', 'paused', 'active'),
           (v_t, v_sub_b, 'verifysubs', 'mb4', 'b4', 'migrated', (v_m0 + interval '1 month 14 days') at time zone 'Europe/London', null, null),
           (v_t, v_sub_b, 'verifysubs', 'xb4', 'b4', 'canceled', (v_m0 + interval '4 months') at time zone 'Europe/London', 'active', 'canceled'),
           (v_t, v_sub_b, 'verifysubs', 'pb5', 'b5', 'purchased', (v_m0 + interval '2 months 2 days') at time zone 'Europe/London', null, null),
           (v_t, v_sub_b, 'verifysubs', 'xb5', 'b5', 'canceled', (v_m0 + interval '2 months 9 days') at time zone 'Europe/London', 'active', 'canceled'),
           (v_t, v_sub_b, 'verifysubs', 'rb5', 'b5', 'reactivated', (v_m0 + interval '3 months') at time zone 'Europe/London', 'canceled', 'active'),
           (v_t, v_sub_b, 'verifysubs', 'pb6', 'b6', 'purchased', (v_m0 + interval '1 month 19 days') at time zone 'Europe/London', null, null);

    -- B2. the mapping, as the tenant's administrator: refusals, then vdev (device, vzm, 1 per unit, p1) and vacc (accessory,
    --     p2); a removal; another user without tenant.configure refused
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_adm::text, true);
    v_txt := pg_temp.v0009ze_code(format('select cma.set_subscription_variant_mapping(%L, ''nope'', ''device'', ''vzm'')', v_sub_a))
      || ' ' || pg_temp.v0009ze_code(format('select cma.set_subscription_variant_mapping(%L, ''vdev'', ''device'', null)', v_sub_a))
      || ' ' || pg_temp.v0009ze_code(format('select cma.set_subscription_variant_mapping(%L, ''vdev'', ''device'', ''nomodel'')', v_sub_a))
      || ' ' || pg_temp.v0009ze_code(format('select cma.set_subscription_variant_mapping(%L, ''vacc'', ''accessory'', null, 2)', v_sub_a))
      || ' ' || pg_temp.v0009ze_code(format('select cma.set_subscription_variant_mapping(%L, ''vacc'', ''accessory'', null, null, ''p9'')', v_sub_a))
      || ' ' || pg_temp.v0009ze_code(format('select cma.set_subscription_variant_mapping(%L, ''vacc'', ''gadget'')', v_sub_a))
      || ' ' || pg_temp.v0009ze_code(format('select cma.set_subscription_variant_mapping(%L, ''vdev'', ''device'', ''vzm'', null, ''p1'')', v_sub_a))
      || ' ' || pg_temp.v0009ze_code(format('select cma.set_subscription_variant_mapping(%L, ''vacc'', ''accessory'', null, null, ''p2'')', v_sub_a))
      || ' ' || pg_temp.v0009ze_code(format('select cma.set_subscription_variant_mapping(%L, ''vunm'', ''service'')', v_sub_a))
      || ' ' || pg_temp.v0009ze_code(format('select cma.set_subscription_variant_mapping(%L, ''vunm'', null)', v_sub_a));
    perform set_config('app.user_id', v_agent::text, true);
    v_txt := v_txt || ' | ' || pg_temp.v0009ze_code(format('select cma.set_subscription_variant_mapping(%L, ''vunm'', ''service'')', v_sub_a))
             || ' ' || pg_temp.v0009ze_code(format('select cma.subscription_variants(%L)', v_sub_a));
    perform set_config('app.user_id', v_adm::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0009ze_code(format('select cma.subscription_variants(%L)', v_shop_a));
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || ' | ' || (select string_agg(m.variant_source_id || ':' || m.line_kind || ':' || coalesce(m.model_key, '-') || ':' || m.devices_per_unit
                                                  || ':' || coalesce(m.proposition, '-') || ':' || (m.updated_by = v_adm), ' ' order by m.variant_source_id collate "C")
                                from cma.subscription_variant_mapping m where m.tenant_id = v_t);
    v_rows := v_rows || array['12', 'B2 the mapping refuses an unknown variant (CMA02), a device without a model or with an unknown one, units on an accessory, an unknown proposition and kind (CMA04); an agent may neither set nor list (CMA06); a connection that is not a subscriptions connection is not found (CMA02); a null kind removes',
      case when v_txt = 'CMA02 CMA04 CMA04 CMA04 CMA04 CMA04 ok ok ok ok | CMA06 CMA06 CMA02 | vacc:accessory:-:0:p2:true vdev:device:vzm:1:p1:true'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- the facts, refreshed as the scheduler
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_sch::text, true);
    v_j := cma.subscription_facts_refresh();
    perform set_config('role', 'cma_owner', true);

    -- B3. device units: a1 2 (the one-time line left out), a2 1, a3 null (an unmapped line), a5 0 (no line); propositions and models
    v_txt := (select string_agg(t.source_id || ':' || coalesce(t.device_units::text, 'null') || ':' || array_to_string(t.propositions, '+')
                                || ':' || array_to_string(t.models, '+'), ' ' order by t.source_id collate "C")
              from cma.subscription_take t where t.tenant_id = v_t and t.source_id in ('a1', 'a2', 'a3', 'a5'))
             || ' | ' || (select string_agg(s.source_id || ':' || coalesce(s.device_units::text, 'null'), ' ' order by s.source_id collate "C")
                          from cma.subscription s where s.tenant_id = v_t and s.source_id in ('a1', 'a3'));
    v_rows := v_rows || array['13', 'B3 device units over recurring lines (a one-time line left out), null with an unmapped line, 0 without a line; written to the mirror',
      case when v_txt = 'a1:2:p1+p2:vzm a2:1:p1:vzm a3:null:: a5:0:: | a1:2 a3:null' and not v_provoke then 'PASS' else 'FAIL' end,
      coalesce(v_txt, 'none') || ' | ' || coalesce(v_j::text, '')];

    -- B4. the payment states and their precedence
    v_txt := (select string_agg(t.source_id || ':' || t.payment_state || ':' || coalesce(t.chargeback_return_code, '-') || ':'
                                || coalesce(t.overdue::text, '-') || ':' || coalesce(t.amount_at_risk::text, '-'), ' ' order by t.source_id collate "C")
              from cma.subscription_take t where t.tenant_id = v_t and t.connection_id = v_sub_a and t.source_id <> 'a10');
    v_rows := v_rows || array['14', 'B4 payment states: charged back on the latest renewal and on a purchase, paid after a later renewal, awaiting payment (by the customer''s one subscription) and overdue, paid invoice, In retry over a chargeback, Failed with its return code',
      case when v_txt = 'a1:charged_back:MD06:-:30.00 a2:paid:-:-:- a3:charged_back:MD01:-:30.00 a4:awaiting_payment:-:false:- a5:awaiting_payment:-:true:30.00 a6:paid:-:-:- a7:in_retry:-:-:30.00 a8:failed:AM04:-:30.00 a9:paid:-:-:-'
                and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'none')];

    -- B5. since: Charged back the chargeback's time, Awaiting payment the invoice's, Failed the move to failed, In retry
    --     the first open failure, Paid the latest renewal
    v_txt := (select string_agg(t.source_id || ':' || coalesce(to_char(t.state_since at time zone 'Europe/London', 'MM-DD'), '-'), ' ' order by t.source_id collate "C")
              from cma.subscription_take t where t.tenant_id = v_t and t.source_id in ('a1', 'a4', 'a7', 'a8', 'a9'));
    v_rows := v_rows || array['15', 'B5 state_since per state',
      case when v_txt = format('a1:%s a4:%s a7:%s a8:%s a9:%s',
                               to_char(v_m0 + interval '2 months 9 days', 'MM-DD'), to_char(v_m0 + interval '2 months 4 days', 'MM-DD'),
                               to_char(v_m0 + interval '3 months 1 day', 'MM-DD'), to_char(v_m0 + interval '1 month 24 days', 'MM-DD'),
                               to_char(v_m0 + interval '3 months 1 day', 'MM-DD'))
                and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'none')];

    -- B6. renewal outcomes
    v_txt := (select string_agg(r.subscription_source_id || '/' || r.renewal_key || ':' || r.outcome || ':' || r.attempts || ':'
                                || coalesce(r.days_to_recover::text, '-') || ':' || coalesce(r.error_code, '-') || ':'
                                || coalesce(r.payment_method_changed_before_recovery::text, '-'), ' ' order by r.subscription_source_id collate "C", r.renewal_key collate "C")
              from cma.renewal_outcome r where r.tenant_id = v_t and r.subscription_source_id in ('a2', 'a4', 'a6', 'a7', 'a9'));
    v_rows := v_rows || array['16', 'B6 renewal outcomes: paid at the first attempt, charged back, recovered (days, the first error, a payment method changed), not recovered, invoice paid and open',
      case when v_txt = 'a2/cycle:1:charged_back:1:-:-:- a2/cycle:2:paid_first_attempt:1:-:-:- a4/invoice:r4:invoice_open:1:-:-:- a6/invoice:r6:invoice_paid:1:-:-:- a7/cycle:1:paid_first_attempt:1:-:-:- a7/cycle:2:charged_back:1:-:-:- a7/cycle:3:not_recovered:1:-:CARD_DECLINED:- a9/cycle:1:recovered:2:3.0:INSUFFICIENT_FUNDS:true a9/cycle:2:recovered:2:1.0:INSUFFICIENT_FUNDS:false a9/cycle:3:recovered:2:1.0:INSUFFICIENT_FUNDS:false'
                and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'none')];

    -- B7. the DE store's month grid: the base at each month's start and end and every movement kind (counts)
    v_txt := (select string_agg(((m.month - v_mon) / 28)::text || m.kind || m.subscriptions || case when m.complete then '*' else '' end, ' '
                                order by m.month, m.kind collate "C")
              from cma.subscription_month_take m where m.tenant_id = v_t and m.connection_id = v_sub_b and m.currency = '' and m.month < (v_mon + interval '5 months')::date);
    v_rows := v_rows || array['17', 'B7 the DE store''s months: Total subscriptions at start and end and the movements (new, migrated, paused, resumed, churned, moved_to_failed, reactivated); * a complete month, from the store''s first complete one',
      case when v_txt = '1end5 1migrated1 1new4 1start0 2churned1* 2end5* 2new1* 2paused1* 2resumed1* 2start5* 3churned1* 3end4* 3moved_to_failed1* 3reactivated1* 3start5* 4churned1* 4end3* 4start4*'
                and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'none')];

    -- B8. the rates against a hand count: month 2 churn 1 of 5, failed 0; month 3 churn 1 of 5, failed 1 of 5; month 4
    --     churn 1 of 4; month 1 (not complete) left out
    v_txt := (select string_agg(((c.month - v_mon) / 28)::text || ':' || c.base || ':' || c.churn_rate || ':' || c.failed_rate, ' ' order by c.month)
              from cma_read.subscription_churn_month c where c.tenant_id = v_t and c.market = 'DE' and c.month < (v_mon + interval '5 months')::date);
    v_rows := v_rows || array['18', 'B8 Churn rate and Failed rate per market and complete month against a hand count (the reader''s view)',
      case when v_txt = '2:5:0.2000:0.0000 3:5:0.2000:0.2000 4:4:0.2500:0.0000' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'none')];

    -- B9. survival: the IE cohort of month 0, monthly: 9 started (a10 migrated, left out), all eligible for renewals 1 and
    --     2; 5 survived to renewal 1, 4 to renewal 2, 1 to renewal 3
    v_txt := (select string_agg(v.renewal_number || ':' || v.started || ':' || v.eligible || ':' || v.survived, ' ' order by v.renewal_number)
              from cma.subscription_survival_take v where v.tenant_id = v_t and v.connection_id = v_sub_a and v.cohort_month = v_mon
                and v.interval_group = 'monthly' and v.renewal_number <= 3)
             || ' | ' || (select string_agg(t.source_id || ':' || t.migrated || ':' || t.renewals, ' ' order by t.source_id collate "C")
                          from cma.subscription_take t where t.tenant_id = v_t and t.source_id in ('a1', 'a9', 'a10'));
    v_rows := v_rows || array['19', 'B9 renewal survival: started, eligible and survived per renewal number, migrated subscriptions left out',
      case when v_txt = '1:9:9:5 2:9:9:4 3:9:9:1 | a1:false:2 a10:true:0 a9:false:3' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'none')];

    -- B10. original start: a1 from its customer's first store order (before the app's created date), a2 created (its order
    --      came after), cohort the month of the start
    v_txt := (select string_agg(t.source_id || ':' || t.original_start_basis || ':' || to_char(t.original_start_at at time zone 'Europe/London', 'MM-DD')
                                || ':' || (t.cohort_month = v_mon), ' ' order by t.source_id collate "C")
              from cma.subscription_take t where t.tenant_id = v_t and t.source_id in ('a1', 'a2'));
    v_rows := v_rows || array['20', 'B10 original start: first_order before the created date, else created; the cohort its month',
      case when v_txt = format('a1:first_order:%s:true a2:created:%s:true', to_char(v_m0, 'MM-DD'), to_char(v_m0 + interval '1 day', 'MM-DD'))
                and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'none')];

    -- B11. data quality: a1 more_paid, a2 more_placed, a6 equal (none), a4 without a device (not this check's); the unmapped
    --      variants vonce and vunm with their active lines; fixed in assets and cma
    v_txt := (select string_agg(q.check_key || ':' || q.object_id || ':' || q.value || ':' || cma.data_quality_fix_in(q.check_key, q.value), ' '
                                order by q.check_key collate "C", q.object_id collate "C")
              from cma.data_quality_of(v_t) q
              where q.check_key in ('subscription_device_units_mismatch', 'subscription_variant_unmapped'));
    v_rows := v_rows || array['21', 'B11 data quality: device units against devices placed both ways (none without a device), the unmapped variants, where each is fixed',
      case when v_txt = 'subscription_device_units_mismatch:a1:more_paid:assets subscription_device_units_mismatch:a2:more_placed:assets subscription_variant_unmapped:vonce:1:cma subscription_variant_unmapped:vunm:1:cma'
                and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'none')];

    -- B12. the take's skip: within subscriptions.take_refresh_minutes fresh; after it, with nothing changed, unchanged; a
    --      new event computes again
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_sch::text, true);
    v_j := cma.subscription_facts_refresh_of(v_t, false, now());
    v_j2 := cma.subscription_facts_refresh_of(v_t, false, now() + interval '16 minutes');
    v_txt := coalesce(v_j ->> 'reason', 'refreshed') || ' ' || coalesce((v_j2 ->> 'unchanged'), 'none');
    perform set_config('role', 'cma_owner', true);
    insert into cma.subscription_event (tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type, occurred_at, cycle_index, order_source_id)
    values (v_t, v_sub_b, 'verifysubs', 'rb6-1', 'b6', 'renewed', now() - interval '1 hour', 1, '6001');
    perform set_config('role', 'cma_app', true);
    v_j2 := cma.subscription_facts_refresh_of(v_t, false, now() + interval '32 minutes');
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || ' ' || coalesce((v_j2 ->> 'unchanged'), 'none');
    v_rows := v_rows || array['22', 'B12 the take''s skip: fresh within its minutes, unchanged after them with the same inputs, computed again after a new event',
      case when v_txt = 'fresh true false' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B13. another tenant's application sees none of the takes or the mapping
    select t.id into v_other from cma.tenant t where t.slug = 'pulse4all-subscriptions';
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_other::text, true);
    v_txt := (select count(*) from cma.subscription_take where tenant_id = v_t)::text || ' ' || (select count(*) from cma.subscription_month_take where tenant_id = v_t)
             || ' ' || (select count(*) from cma.renewal_outcome where tenant_id = v_t) || ' ' || (select count(*) from cma.subscription_variant_mapping where tenant_id = v_t);
    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('role', 'cma_owner', true);
    v_rows := v_rows || array['23', 'B13 another tenant''s application sees none of the takes or the mapping (row-level security)',
      case when v_txt = '0 0 0 0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B14. the one-time fill as the ingest: a purchase without an order gains it, one with an order keeps its own, an
    --      event that is not a purchase is left; bad items refused
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_ing::text, true);
    v_txt := (select cma.ingest_fill_purchase_orders(v_sub_a, '[{"sourceId": "pa1", "orderSourceId": "9001"}, {"sourceId": "pa3", "orderSourceId": "7777"}, {"sourceId": "ra1-1", "orderSourceId": "7778"}]'::jsonb))::text
             || ' ' || pg_temp.v0009ze_code(format($q$select cma.ingest_fill_purchase_orders(%L, '[{"sourceId": "pa1", "orderSourceId": "x1"}]'::jsonb)$q$, v_sub_a));
    -- another tenant's ingest cannot fill this tenant's purchases: the connection is not its own (CMA02), nothing changes
    perform set_config('role', 'cma_owner', true);
    update cma.subscription_event set raw = raw - 'orderId' where tenant_id = v_t and source_id = 'pa1';
    select x.user_id into v_oing from cma.app_user_external_id x where x.tenant_id = v_other and x.system = 'ingest' and x.external_id = 'ingest';
    perform set_config('app.tenant_id', v_other::text, true);
    perform set_config('app.user_id', v_oing::text, true);
    perform set_config('role', 'cma_app', true);
    v_txt := v_txt || ' ' || pg_temp.v0009ze_code(format($q$select cma.ingest_fill_purchase_orders(%L, '[{"sourceId": "pa1", "orderSourceId": "9001"}]'::jsonb)$q$, v_sub_a));
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.tenant_id', v_t::text, true);
    v_txt := v_txt || ' | ' || (select string_agg(e.source_id || ':' || coalesce(e.raw ->> 'orderId', '-'), ' ' order by e.source_id collate "C")
                                from cma.subscription_event e where e.tenant_id = v_t and e.source_id in ('pa1', 'pa3', 'ra1-1'));
    v_rows := v_rows || array['24', 'B14 the one-time fill: a purchase without an order gains it, one with an order and a renewal are left; bad items refused (CMA04); another tenant''s ingest fills nothing of it (CMA02)',
      case when v_txt = '1 CMA04 CMA02 | pa1:- pa3:9003 ra1-1:-' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['59', 'B the block ran to the end', 'FAIL', sqlstate || ': ' || sqlerrm];
  end;
  insert into verify_0009ze (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0009ze values (59, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- The helpers are dropped first, so the verdict is the last thing the script prints
drop function if exists pg_temp.v0009ze_code(text);
drop function if exists pg_temp.v0009ze_key_174(uuid);

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0009ze
      union all
      select 99, 'verdict',
             case when not current_setting('verify.dev')::boolean then 'REFUSED'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0009ze where result = 'PASS') = 20
                       and not exists (select 1 from verify_0009ze where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('211_verify_subscription_facts: %s PASS, %s FAIL', (select count(*) from verify_0009ze where result = 'PASS'),
                                                                       (select count(*) from verify_0009ze where result <> 'PASS'))) x
order by ord;
reset role;
