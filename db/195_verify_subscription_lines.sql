-- =============================================================================================
-- 195_verify_subscription_lines.sql: verifies addition 0009w, the subscription app read whole (brief B39 Part A)
-- =============================================================================================
-- Dev and local databases only, as 119: block Z reads every row of the four new tables of every tenant for an email
-- pattern after the flow verifier's fixtures (ingest/verify/juo-flow.mjs runs in dev and local databases only). It
-- refuses a database without the dev seed (no active agent.two@example.com): every check reads FAIL and the verdict
-- REFUSED. Block A only reads; block B works on two throwaway tenants inside a subtransaction that is always rolled back,
-- so nothing stays. Every check writes one row, PASS or FAIL, and the last row is the verdict, because Cloud SQL Studio
-- shows no notices. Run as your own IAM login after 194_subscription_lines.sql, in dev; then 119_verify_subscriptions.sql
-- and the verifies 194's header names. Adapters, handles, ids, codes, titles and secret names are invented data values,
-- and no row carries a name, an address, an email or a phone number of a customer.
--   A  structure and privileges: the addition row after 0009v; the four new tables tenant-aware (row-level security, the
--      tenant policy, the audit trigger, the tenant's foreign key), the application without delete on any, without
--      update on billing events and observed changes; the unique keys; the new columns of cma.subscription and
--      cma.subscription_event; the checks of the instrument types (seven) and event types (twenty-two); every function
--      the application's only and in the caller's rights; the reader views without raw and with the new columns; the
--      setting subscriptions.history_start_date in the catalog; the pure helpers (catalog text, instrument type)
--   B  behaviour, on two throwaway tenants, each with its Ingest user, a commerce store and a subscriptions connection
--      whose account id names that handle: the subscriptions' new fields and observed changes with the run (none on a
--      first load, none for a value stored as null, none on a rerun; the two-argument call the same answers without a
--      run); the run refused when it is no running run of the connection; the lines as a set (inserted, unchanged on a
--      rerun, a line the read no longer holds missing and back when it returns, the recurring quantity's change); the
--      catalog (inserted, missing, a missing title or SKU, the refusals of an @, a control character, 101 characters and
--      an empty set); the billing events (every kind, append-only, the refusals); the new event types and columns (a
--      renewal's order joining a chargeback's); the setting (trimmed, a date or empty, refused otherwise); the run counts;
--      row-level security across the two tenants' Ingest users; the application's update and delete refused; audit rows
--      written; no column of the new tables holding an email pattern
--   Z  every row of the four new tables of the database: no column holding an email pattern
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
-- dev or a local database only: the dev seed's agent.two@example.com active, as the ingest's flow verifiers require
select set_config('verify.dev', (select exists (select 1 from cma.app_user u where u.email = 'agent.two@example.com' and u.status = 'active'))::text, false);
-- an email address in any column of a row (its JSON text): something@something.something
select set_config('verify.email_pattern', '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', false);

drop table if exists pg_temp.verify_0009w;
create temp table verify_0009w (ord int, check_name text, result text, detail text);

-- The error a statement raises as its SQLSTATE, or 'ok'
create or replace function pg_temp.v0009w_code(p_sql text)
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

-- The scenario's subscriptions as the adapter maps them (map.mjs subscriptionItem). p_variant: base, or changed (sub-a
-- paused, its amount, interval and line count changed; sub-b's line count stated for the first time)
create or replace function pg_temp.v0009w_subs(p_variant text)
returns jsonb
language sql
as $$
  select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'sourceId', v.id, 'sourceNumber', v.num, 'customerSourceId', '9001',
           'status', case when p_variant = 'changed' and v.id = 'sub-a' then 'paused' else v.status end,
           'currentCycle', 3, 'billingInterval', case when p_variant = 'changed' and v.id = 'sub-a' then 'year' else 'month' end,
           'billingIntervalCount', 1, 'amountPerCycle', case when p_variant = 'changed' and v.id = 'sub-a' then 39.95 else 29.95 end,
           'currency', 'GBP', 'paymentInstrumentType', v.instrument, 'minCycles', v.min_cycles, 'discountCount', v.discounts,
           'lineCount', case when p_variant = 'changed' and v.id = 'sub-a' then 3 when p_variant = 'changed' and v.id = 'sub-b' then 1 else v.lines end,
           'sourceCreatedAt', '2025-05-13T09:00:00.000Z',
           'sourceUpdatedAt', case when p_variant = 'changed' then '2026-11-17T09:00:00.000Z' else '2026-11-10T09:00:00.000Z' end,
           'raw', jsonb_strip_nulls(jsonb_build_object('id', v.id, 'serial', v.num, 'status', upper(v.status), 'instrumentType', v.instrument,
                                                       'minCycles', v.min_cycles, 'discountCount', v.discounts,
                                                       'updatedAt', case when p_variant = 'changed' then '2026-11-17' else '2026-11-10' end))))
         order by v.id)
  from (values
    ('sub-a', '#2502', 'active', 'sepa_direct_debit', 12, 1, 2),
    ('sub-b', '#2503', 'active', 'ideal', null, 0, null),
    ('sub-c', '#2504', 'paused', 'card', null, 0, 1)
  ) as v(id, num, status, instrument, min_cycles, discounts, lines)
$$;

-- The scenario's lines (map.mjs lineItems). p_variant: base (sub-a: a recurring line, a canceled one, a one-time add-on;
-- sub-b: one recurring line), removed (sub-a's recurring line gone, sub-b's quantity 3)
create or replace function pg_temp.v0009w_lines(p_variant text)
returns jsonb
language sql
as $$
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'sourceId', v.id, 'subscriptionSourceId', v.sub, 'productSourceId', v.product, 'variantSourceId', v.variant,
           'quantity', case when p_variant = 'removed' and v.id = 'l-b1' then 3 else v.qty end, 'amountPerCycle', v.amount, 'currency', 'GBP',
           'billingInterval', 'month', 'billingIntervalCount', 1, 'recurringCycleLimit', v.cycle_limit, 'canceledAt', v.canceled,
           'raw', jsonb_strip_nulls(jsonb_build_object('id', v.id, 'subscriptionId', v.sub, 'variant', v.variant, 'quantity', v.qty))))
         order by v.id), '[]'::jsonb)
  from (values
    ('l-a1', 'sub-a', '71000000001', '41000000001', 1, 24.95, null, null),
    ('l-a2', 'sub-a', '71000000002', '41000000002', 2, 5, null, '2026-11-01T10:00:00.000Z'),
    ('l-a3', 'sub-a', '71000000003', '41000000003', 1, 49, 1, null),
    ('l-b1', 'sub-b', '71000000001', '41000000001', 1, 24.95, null, null)
  ) as v(id, sub, product, variant, qty, amount, cycle_limit, canceled)
  where not (p_variant = 'removed' and v.id = 'l-a1')
$$;

-- The scenario's billing events (map.mjs billingEventItem): one of each kind
create or replace function pg_temp.v0009w_billing()
returns jsonb
language sql
as $$
  select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'sourceId', v.id, 'kind', v.kind, 'occurredAt', v.at, 'subscriptionSourceId', v.sub, 'customerSourceId', '9001',
           'orderSourceId', v.ord, 'renewalSourceId', v.renewal, 'ownerSourceId', v.owner, 'amount', 24.95, 'currency', 'GBP',
           'returnCode', v.code, 'instrumentType', v.instrument, 'attempt', v.attempt, 'errorCode', v.err, 'partial', v.partial,
           'raw', jsonb_strip_nulls(jsonb_build_object('id', v.id, 'orderId', v.ord, 'reasonCode', v.code, 'amount', 24.95)))) order by v.id)
  from (values
    ('be-01', 'chargeback', '2026-11-11T13:06:00.000Z', null, '6100000001', null, 'cb-1', 'MD01', 'sepa_direct_debit', null, null, null::boolean),
    ('be-02', 'chargeback', '2026-11-12T13:06:00.000Z', null, '6100000002', null, 'cb-2', 'fraudulent', 'card', null, null, null),
    ('be-03', 'refund_created', '2026-11-13T10:00:00.000Z', null, '6100000003', null, 'rf-1', null, null, null, null, false),
    ('be-04', 'refund_completed', '2026-11-13T11:00:00.000Z', null, '6100000003', null, 'rf-1', null, null, null, null, false),
    ('be-05', 'refund_failed', '2026-11-13T12:00:00.000Z', null, '6100000004', null, 'rf-2', null, null, null, null, true),
    ('be-06', 'invoice_placed', '2026-11-11T19:00:00.000Z', 'sub-b', null, 'rn-1', 'inv-1', null, null, null, null, null),
    ('be-07', 'invoice_paid', '2026-11-12T19:00:00.000Z', 'sub-b', null, null, 'inv-1', null, null, null, null, null),
    ('be-08', 'invoice_overdue', '2026-11-14T19:00:00.000Z', 'sub-c', null, null, 'inv-2', null, null, null, null, null),
    ('be-09', 'invoice_payment_failed', '2026-11-15T16:45:00.000Z', 'sub-c', null, null, 'inv-2', null, null, 3, 'INSUFFICIENT_FUNDS', null),
    ('be-10', 'order_placement_failed', '2026-11-15T17:00:00.000Z', 'sub-c', null, null, 'ord-3', null, null, null, null, null),
    ('be-11', 'order_draft_created', '2026-11-15T18:00:00.000Z', 'sub-c', null, null, 'ord-4', null, null, null, null, null)
  ) as v(id, kind, at, sub, ord, renewal, owner, code, instrument, attempt, err, partial)
$$;

-- The scenario's events of the new types (map.mjs eventItem), and a renewal with its order
create or replace function pg_temp.v0009w_events()
returns jsonb
language sql
as $$
  select jsonb_agg(jsonb_strip_nulls(v.item || jsonb_build_object('sourceId', v.id, 'subscriptionSourceId', 'sub-a', 'occurredAt', v.at,
                                                                  'actorType', 'system', 'raw', jsonb_build_object('id', v.id))) order by v.id)
  from (values
    ('ne-01', '2026-10-01T09:00:00.000Z', '{"eventType": "renewed", "cycleIndex": 2, "orderSourceId": "6100000001"}'::jsonb),
    ('ne-02', '2025-05-13T09:00:00.000Z', '{"eventType": "migrated", "cycleIndex": 3, "billingToAt": "2025-06-01T00:00:00.000Z"}'),
    ('ne-03', '2026-11-01T09:00:00.000Z', '{"eventType": "billing_date_moved", "billingFromAt": "2026-11-05T00:00:00.000Z", "billingToAt": "2026-11-20T00:00:00.000Z", "causeCode": "requested", "operationSourceId": "op-1"}'),
    ('ne-04', '2026-11-02T09:00:00.000Z', '{"eventType": "skipped", "billingFromAt": "2026-11-20T00:00:00.000Z", "billingToAt": "2026-12-20T00:00:00.000Z"}'),
    ('ne-05', '2026-11-03T09:00:00.000Z', '{"eventType": "interval_changed", "intervalFrom": "month", "intervalCountFrom": 1, "intervalTo": "year", "intervalCountTo": 1}'),
    ('ne-06', '2026-11-04T09:00:00.000Z', '{"eventType": "lines_changed", "linesAdded": 2, "linesRemoved": 1, "linesUpdated": 0, "operationSourceId": "op-2"}'),
    ('ne-07', '2026-11-04T09:00:00.000Z', '{"eventType": "lines_changed", "linesAdded": 1, "operationSourceId": "op-2"}'),
    ('ne-08', '2026-11-05T09:00:00.000Z', '{"eventType": "discount_changed", "causeCode": "code_applied"}'),
    ('ne-09', '2026-11-06T09:00:00.000Z', '{"eventType": "merged_to", "relatedSubscriptionSourceId": "sub-b"}'),
    ('ne-10', '2026-11-07T09:00:00.000Z', '{"eventType": "update_failed", "errorCode": "INVALID_VARIANT"}'),
    ('ne-11', '2026-11-08T09:00:00.000Z', '{"eventType": "renewal_notice"}'),
    ('ne-12', '2026-11-09T09:00:00.000Z', '{"eventType": "payment_method_changed"}'),
    ('ne-13', '2025-05-01T09:00:00.000Z', '{"eventType": "purchased"}'),
    ('ne-14', '2025-05-01T09:00:00.000Z', '{"eventType": "created"}'),
    ('ne-15', '2026-11-10T09:00:00.000Z', '{"eventType": "split_from", "relatedSubscriptionSourceId": "sub-c"}')
  ) as v(id, at, item)
$$;

-- A. Structure and privileges
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_bad     text;
  v_fn      text;
  v_t       text;
begin
  -- A1. the addition is recorded, after 0009v
  insert into verify_0009w values (1, 'A1 addition 0009w recorded, after 0009v',
    case when exists (select 1 from cma.schema_migration where version = '0009w')
              and exists (select 1 from cma.schema_migration where version = '0009v') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the four tables tenant-aware: row-level security on, the tenant policy, the audit trigger, a foreign key to the
  --     tenant; the application selects and inserts all, deletes none, updates lines and variants only; readers never
  --     read a base table
  v_bad := '';
  foreach v_t in array array['subscription_line', 'subscription_product_variant', 'billing_event', 'subscription_change'] loop
    if to_regclass('cma.' || v_t) is null then
      v_bad := v_bad || v_t || ' missing; ';
      continue;
    end if;
    if not (select relrowsecurity from pg_class where oid = ('cma.' || v_t)::regclass)
       or not exists (select 1 from pg_policy where polrelid = ('cma.' || v_t)::regclass and polname = 'tenant_app')
       or not exists (select 1 from pg_trigger where tgrelid = ('cma.' || v_t)::regclass and tgname = 'audit' and not tgisinternal)
       or not exists (select 1 from pg_constraint where conrelid = ('cma.' || v_t)::regclass and contype = 'f' and confrelid = 'cma.tenant'::regclass)
       or not has_table_privilege('cma_app', 'cma.' || v_t, 'select') or not has_table_privilege('cma_app', 'cma.' || v_t, 'insert')
       or has_table_privilege('cma_app', 'cma.' || v_t, 'delete') or has_table_privilege('cma_readonly', 'cma.' || v_t, 'select')
       or has_table_privilege('cma_app', 'cma.' || v_t, 'update') <> (v_t in ('subscription_line', 'subscription_product_variant')) then
      v_bad := v_bad || v_t || '; ';
    end if;
  end loop;
  insert into verify_0009w values (2, 'A2 the four tables tenant-aware (RLS, policy, audit, tenant key); no delete by the application, no update of a billing event or an observed change',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A3. the unique keys: (tenant_id, id) on all four; the source's key per connection on lines and billing events, the
  --     variant per connection on the catalog
  v_bad := '';
  foreach v_t in array array['subscription_line', 'subscription_product_variant', 'billing_event', 'subscription_change'] loop
    if not exists (select 1 from pg_constraint where conrelid = to_regclass('cma.' || v_t) and contype = 'u' and pg_get_constraintdef(oid) = 'UNIQUE (tenant_id, id)')
       or (v_t in ('subscription_line', 'billing_event') and not exists (select 1 from pg_constraint where conrelid = to_regclass('cma.' || v_t)
             and contype = 'u' and pg_get_constraintdef(oid) = 'UNIQUE (tenant_id, connection_id, source_id)'))
       or (v_t = 'subscription_product_variant' and not exists (select 1 from pg_constraint where conrelid = to_regclass('cma.' || v_t)
             and contype = 'u' and pg_get_constraintdef(oid) = 'UNIQUE (tenant_id, connection_id, variant_source_id)')) then
      v_bad := v_bad || v_t || '; ';
    end if;
  end loop;
  insert into verify_0009w values (3, 'A3 the unique keys of the four tables',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A4. the new columns of cma.subscription and cma.subscription_event; the seven instrument types and twenty-two event
  --     types in their checks
  select string_agg(c, ' ' order by c collate "C") into v_bad
  from (select x as c from unnest(array['source_number', 'min_cycles', 'max_cycles', 'discount_count', 'line_count', 'device_units']) x
        where not exists (select 1 from information_schema.columns where table_schema = 'cma' and table_name = 'subscription' and column_name = x)
        union all
        select x from unnest(array['billing_from_at', 'billing_to_at', 'cause_code', 'interval_from', 'interval_count_from', 'interval_to',
                                   'interval_count_to', 'lines_added', 'lines_removed', 'lines_updated', 'related_subscription_source_id',
                                   'operation_source_id', 'order_source_id']) x
        where not exists (select 1 from information_schema.columns where table_schema = 'cma' and table_name = 'subscription_event' and column_name = x)) m;
  v_bad := coalesce(v_bad, '');
  if (select array_agg(x order by x collate "C") from unnest(array['card', 'paypal', 'sepa_direct_debit', 'ideal', 'bancontact', 'invoice', 'other', 'klarna', '']) x
      where cma.payment_instrument_type_ok(x)) is distinct from array['bancontact', 'card', 'ideal', 'invoice', 'other', 'paypal', 'sepa_direct_debit'] then
    v_bad := v_bad || ' instruments';
  end if;
  if (select count(*) from unnest(array['renewed', 'renew_failed', 'canceled', 'paused', 'resumed', 'reactivated', 'status_changed', 'purchased',
                                       'created', 'migrated', 'skipped', 'billing_date_moved', 'interval_changed', 'lines_changed',
                                       'payment_method_changed', 'discount_changed', 'merged_to', 'merged_from', 'split_to', 'split_from',
                                       'renewal_notice', 'update_failed']) x
      where (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.subscription_event'::regclass
               and conname = 'subscription_event_event_type_check') like '%''' || x || '''%') <> 22 then
    v_bad := v_bad || ' event types';
  end if;
  insert into verify_0009w values (4, 'A4 the new columns of subscription and subscription_event; seven instrument types; twenty-two event types',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A5. every function the application's only and in the caller's rights
  v_bad := '';
  foreach v_fn in array array[
    'cma.ingest_sync_run_finish(uuid,text,jsonb,text)', 'cma.ingest_upsert_subscriptions(uuid,jsonb,uuid)', 'cma.ingest_upsert_subscriptions(uuid,jsonb)',
    'cma.ingest_upsert_subscription_lines(uuid,text[],jsonb,uuid)', 'cma.ingest_upsert_subscription_products(uuid,jsonb)',
    'cma.ingest_upsert_billing_events(uuid,jsonb)', 'cma.ingest_upsert_subscription_events(uuid,jsonb)', 'cma.catalog_text_ok(text)',
    'cma.payment_instrument_type_ok(text)', 'cma.assert_running_run(uuid,uuid)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure(v_fn) and a.grantee = 0) then
      v_bad := v_bad || v_fn || '; ';
    end if;
  end loop;
  insert into verify_0009w values (5, 'A5 every function the application''s only and invoker (the two-argument upsert of subscriptions kept)',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A6. the reader views: the four new ones without raw, readable by readers; the new columns at the end of subscription
  --     and subscription_event
  v_bad := '';
  foreach v_t in array array['subscription_line', 'subscription_product_variant', 'billing_event', 'subscription_change'] loop
    if to_regclass('cma_read.' || v_t) is null or not has_table_privilege('cma_readonly', 'cma_read.' || v_t, 'select') then
      v_bad := v_bad || v_t || '; ';
    end if;
  end loop;
  if exists (select 1 from information_schema.columns where table_schema = 'cma_read' and column_name = 'raw'
               and table_name in ('subscription_line', 'subscription_product_variant', 'billing_event', 'subscription_change', 'subscription',
                                  'subscription_event')) then
    v_bad := v_bad || 'raw; ';
  end if;
  if (select string_agg(column_name, ' ' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'subscription' and ordinal_position > 21)
     is distinct from 'source_number min_cycles max_cycles discount_count line_count device_units' then
    v_bad := v_bad || 'subscription columns; ';
  end if;
  if (select string_agg(column_name, ' ' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'subscription_event' and ordinal_position > 17)
     is distinct from 'billing_from_at billing_to_at cause_code interval_from interval_count_from interval_to interval_count_to lines_added lines_removed lines_updated related_subscription_source_id operation_source_id order_source_id' then
    v_bad := v_bad || 'event columns; ';
  end if;
  insert into verify_0009w values (6, 'A6 the reader views (no raw), readable by readers; the new columns at the end of subscription and subscription_event',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A7. the setting in the catalog: text, empty by default
  v_bad := (select s.key || ':' || s.value_type || ':' || coalesce(nullif(s.default_value, ''), 'empty') from cma.setting s
            where s.key = 'subscriptions.history_start_date');
  insert into verify_0009w values (7, 'A7 the setting subscriptions.history_start_date: text, empty by default',
    case when v_bad = 'subscriptions.history_start_date:text:empty' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_bad, 'missing'));

  -- A8. the pure helpers: catalog text 1 to 100 characters without an @ or a control character (null for null); the
  --     instrument types
  v_bad := concat_ws(' ', cma.catalog_text_ok('Plan A'), cma.catalog_text_ok(repeat('x', 100)), cma.catalog_text_ok(repeat('x', 101)),
                     cma.catalog_text_ok(''), cma.catalog_text_ok('a@b'), cma.catalog_text_ok('tab' || chr(9) || 'x'),
                     cma.catalog_text_ok('bell' || chr(7)), coalesce(cma.catalog_text_ok(null)::text, 'null'),
                     cma.payment_instrument_type_ok('sepa_direct_debit'), cma.payment_instrument_type_ok('SepaDirectDebit'));
  insert into verify_0009w values (8, 'A8 catalog text and instrument types by form',
    case when v_bad = 't t f f f f f null t f' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);
end
$$;

-- B. Behaviour on two throwaway tenants (rolled back)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_dev     boolean := current_setting('verify.dev')::boolean;
  v_email   text := current_setting('verify.email_pattern');
  v_rows    text[] := '{}';
  v_t1 uuid; v_t2 uuid;
  v_admin1 uuid; v_ing1 uuid; v_ing2 uuid;
  v_shop1 uuid; v_shop2 uuid; v_sub1 uuid; v_sub2 uuid;
  v_run uuid; v_run2 uuid; v_done uuid;
  v_txt text;
  j jsonb;
begin
  if not v_dev then
    insert into verify_0009w values (59, 'B a dev or local database (the dev seed''s agent.two@example.com active)', 'FAIL',
      'REFUSED: no dev seed, so this is no dev or local database; nothing ran');
    return;
  end if;
  begin
    -- tenants (each with its Ingest user), an admin and connections (as the owner); each tenant's store with a customer
    v_t1 := cma.create_tenant('verify-0009w-one', 'Verify 0009w one', 'Europe/London');
    v_t2 := cma.create_tenant('verify-0009w-two', 'Verify 0009w two', 'Europe/London');
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest' and x.external_id = 'ingest';
    select x.user_id into v_ing2 from cma.app_user_external_id x where x.tenant_id = v_t2 and x.system = 'ingest' and x.external_id = 'ingest';
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, v_admin1, ar.id from cma.app_role ar where ar.tenant_id = v_t1 and ar.key = 'admin';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, signing_secret_name)
    values (v_t1, 'verifyshop', 'Verify shop one', 'verify-store-1.shop.example', 'commerce', 'verify-shop-signing-1') returning id into v_shop1;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t1, 'verifysubs', 'Verify subscriptions one', 'verify-store-1.shop.example', 'subscriptions', 'verify-subs-key-1') returning id into v_sub1;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, signing_secret_name)
    values (v_t2, 'verifyshop', 'Verify shop two', 'verify-store-2.shop.example', 'commerce', 'verify-shop-signing-2') returning id into v_shop2;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t2, 'verifysubs', 'Verify subscriptions two', 'verify-store-2.shop.example', 'subscriptions', 'verify-subs-key-2') returning id into v_sub2;
    insert into cma.commerce_store (tenant_id, connection_id, handle, name, market, currency, time_zone)
    values (v_t1, v_shop1, 'verify-store-1', 'Verify store one', 'GB', 'GBP', 'Europe/London'),
           (v_t2, v_shop2, 'verify-store-2', 'Verify store two', 'GB', 'GBP', 'Europe/London');
    insert into cma.commerce_customer (tenant_id, connection_id, source_system, source_id)
    values (v_t1, v_shop1, 'verifyshop', '9001'), (v_t2, v_shop2, 'verifyshop', '9001');
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_ing1::text, true);
    v_run := cma.ingest_sync_run_start(v_sub1, 'reconcile', 'subscription', null, null);

    -- B1. the subscriptions' new fields with a run: inserted; the number, cycle bounds, discounts, lines, instrument
    --     stored; device units null; no change observed on a first load; a rerun unchanged and observing nothing
    v_txt := (select string_agg(s.source_id || ':' || s.outcome || ':' || s.changes_observed, ' ' order by s.source_id collate "C")
              from cma.ingest_upsert_subscriptions(v_sub1, pg_temp.v0009w_subs('base'), v_run) s);
    -- (each read its own statement: a statement does not see what a function called in it wrote)
    v_txt := v_txt || ' | ' || (select string_agg(concat_ws(':', s.source_id, s.source_number, s.payment_instrument_type, coalesce(s.min_cycles::text, '-'),
                                                       coalesce(s.max_cycles::text, '-'), s.discount_count, coalesce(s.line_count::text, '-'),
                                                       coalesce(s.device_units::text, '-')), ' ' order by s.source_id collate "C")
                          from cma.subscription s where s.connection_id = v_sub1);
    v_txt := v_txt || ' | ' || (select string_agg(s.outcome || ':' || s.changes_observed, ' ' order by s.source_id collate "C")
                                from cma.ingest_upsert_subscriptions(v_sub1, pg_temp.v0009w_subs('base'), v_run) s);
    v_txt := v_txt || ' | ' || (select count(*) from cma.subscription_change c where c.connection_id = v_sub1);
    v_rows := v_rows || array['11', 'B1 the subscriptions'' new fields with a run: inserted, stored, device units null, no change on a first load or a rerun',
      case when v_txt = 'sub-a:inserted:0 sub-b:inserted:0 sub-c:inserted:0 | sub-a:#2502:sepa_direct_debit:12:-:1:2:- '
                        || 'sub-b:#2503:ideal:-:-:0:-:- sub-c:#2504:card:-:-:0:1:- | unchanged:0 unchanged:0 unchanged:0 | 0'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B2. observed changes: sub-a's status, amount, interval and line count (one row each, with the run); sub-b's line
    --     count stated for the first time (a start, no row); then the two-argument call puts them back: the same
    --     outcomes, five changes without a run (sub-a's four, and sub-b's line count no longer stated: 1 to none)
    v_txt := (select string_agg(s.source_id || ':' || s.outcome || ':' || s.changes_observed, ' ' order by s.source_id collate "C")
              from cma.ingest_upsert_subscriptions(v_sub1, pg_temp.v0009w_subs('changed'), v_run) s);
    v_txt := v_txt || ' | ' || (select string_agg(c.subscription_source_id || ':' || c.field || ':' || c.old_value || '>' || coalesce(c.new_value, '-')
                                            || ':' || (c.run_id = v_run)::text, ' ' order by c.subscription_source_id collate "C", c.field collate "C")
                          from cma.subscription_change c where c.connection_id = v_sub1);
    v_txt := v_txt || ' | ' || (select string_agg(s.source_id || ':' || s.outcome, ' ' order by s.source_id collate "C")
                                from cma.ingest_upsert_subscriptions(v_sub1,
                                  (select jsonb_agg(x || '{"sourceUpdatedAt": "2026-11-18T09:00:00.000Z"}'::jsonb) from jsonb_array_elements(pg_temp.v0009w_subs('base')) x)) s);
    v_txt := v_txt || ' ' || (select count(*) from cma.subscription_change c where c.connection_id = v_sub1 and c.run_id is null);
    v_rows := v_rows || array['12', 'B2 observed changes: one row per field with the run; a value stored as null a start; the two-argument call the same without a run',
      case when v_txt = 'sub-a:updated:4 sub-b:updated:0 sub-c:updated:0 | sub-a:amount_per_cycle:29.95>39.95:true '
                        || 'sub-a:billing_interval:month>year:true sub-a:line_count:2>3:true sub-a:status:active>paused:true | '
                        || 'sub-a:updated sub-b:updated sub-c:updated 5'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B3. the run refused when it is no running run of the connection: another connection's, a finished one, none held
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_ing2::text, true);
    v_run2 := cma.ingest_sync_run_start(v_sub2, 'reconcile', 'subscription', null, null);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_ing1::text, true);
    v_done := cma.ingest_sync_run_start(v_sub1, 'backfill', 'subscription', null, null);
    perform cma.ingest_sync_run_finish(v_done, 'succeeded', '{"fetched": 1}');
    v_txt := concat_ws(' ',
      pg_temp.v0009w_code(format('select * from cma.ingest_upsert_subscriptions(%L, %L::jsonb, %L)', v_sub1, pg_temp.v0009w_subs('base'), v_run2)),
      pg_temp.v0009w_code(format('select * from cma.ingest_upsert_subscriptions(%L, %L::jsonb, %L)', v_sub1, pg_temp.v0009w_subs('base'), v_done)),
      pg_temp.v0009w_code(format('select * from cma.ingest_upsert_subscriptions(%L, %L::jsonb, %L)', v_sub1, pg_temp.v0009w_subs('base'), gen_random_uuid())),
      pg_temp.v0009w_code(format('select cma.ingest_upsert_subscription_lines(%L, array[''sub-a''], ''[]''::jsonb, %L)', v_sub1, v_done)));
    v_rows := v_rows || array['13', 'B3 a run that is no running run of the connection refused (another tenant''s, a finished one, an unknown id)',
      case when v_txt = 'CMA04 CMA04 CMA04 CMA04' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B4. the lines as a set: inserted with no change (nothing held before); a rerun unchanged; a line the read no longer
    --     holds missing, another's quantity changed, each subscription's recurring quantity observed; back when it returns
    j := cma.ingest_upsert_subscription_lines(v_sub1, array['sub-a', 'sub-b'], pg_temp.v0009w_lines('base'), v_run);
    v_txt := j::text;
    j := cma.ingest_upsert_subscription_lines(v_sub1, array['sub-a', 'sub-b'], pg_temp.v0009w_lines('base'), v_run);
    v_txt := v_txt || ' | ' || j::text;
    j := cma.ingest_upsert_subscription_lines(v_sub1, array['sub-a', 'sub-b'], pg_temp.v0009w_lines('removed'), v_run);
    v_txt := v_txt || ' | ' || j::text;
    v_txt := v_txt || ' ' || (select string_agg(c.subscription_source_id || ':' || c.old_value || '>' || c.new_value, ' '
                                                                     order by c.subscription_source_id collate "C")
                                                   from cma.subscription_change c where c.connection_id = v_sub1 and c.field = 'recurring_quantity')
             || ' ' || (select l.source_deleted_at is not null from cma.subscription_line l where l.connection_id = v_sub1 and l.source_id = 'l-a1');
    j := cma.ingest_upsert_subscription_lines(v_sub1, array['sub-a', 'sub-b'], pg_temp.v0009w_lines('base'), v_run);
    v_txt := v_txt || ' | ' || j::text;
    v_txt := v_txt || ' ' || (select count(*) from cma.subscription_line l where l.connection_id = v_sub1 and l.source_deleted_at is null)
             || ' ' || (select count(*) from cma.subscription_change c where c.connection_id = v_sub1 and c.field = 'recurring_quantity');
    v_rows := v_rows || array['14', 'B4 the lines as a set: inserted, a rerun unchanged, a line gone missing and back, the recurring quantity observed',
      case when v_txt = '{"updated": 0, "inserted": 4, "unchanged": 0, "missing_now": 0, "changes_observed": 0} | '
                        || '{"updated": 0, "inserted": 0, "unchanged": 4, "missing_now": 0, "changes_observed": 0} | '
                        || '{"updated": 1, "inserted": 0, "unchanged": 2, "missing_now": 1, "changes_observed": 2} sub-a:1>0 sub-b:1>3 true | '
                        || '{"updated": 2, "inserted": 0, "unchanged": 2, "missing_now": 0, "changes_observed": 2} 4 4'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B5. the lines refused: a line of a subscription not named, 501 subscriptions, a line twice, a negative quantity, an
    --     @ in raw
    v_txt := concat_ws(' ',
      pg_temp.v0009w_code(format('select cma.ingest_upsert_subscription_lines(%L, array[''sub-a''], %L::jsonb, null)', v_sub1, pg_temp.v0009w_lines('base'))),
      pg_temp.v0009w_code(format('select cma.ingest_upsert_subscription_lines(%L, (select array_agg(''s-'' || g) from generate_series(1, 501) g), ''[]''::jsonb, null)', v_sub1)),
      pg_temp.v0009w_code(format('select cma.ingest_upsert_subscription_lines(%L, array[''sub-a''], ''[{"sourceId": "l-x", "subscriptionSourceId": "sub-a"}, {"sourceId": "l-x", "subscriptionSourceId": "sub-a"}]''::jsonb, null)', v_sub1)),
      pg_temp.v0009w_code(format('select cma.ingest_upsert_subscription_lines(%L, array[''sub-a''], ''[{"sourceId": "l-x", "subscriptionSourceId": "sub-a", "quantity": -1}]''::jsonb, null)', v_sub1)),
      pg_temp.v0009w_code(format('select cma.ingest_upsert_subscription_lines(%L, array[''sub-a''], ''[{"sourceId": "l-x", "subscriptionSourceId": "sub-a", "raw": {"id": "x@example.invalid"}}]''::jsonb, null)', v_sub1)));
    v_rows := v_rows || array['15', 'B5 the lines refused: a subscription not named, 501 subscriptions, a line twice, a negative quantity, an @ in raw',
      case when v_txt = 'CMA04 CMA04 CMA04 CMA04 CMA04' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B6. the catalog: a full set inserted (a variant without a title or SKU too); a smaller set marks the rest missing;
    --     the refusals of an @, a control character, 101 characters, an empty set and a variant twice
    j := cma.ingest_upsert_subscription_products(v_sub1, '[{"productSourceId": "71000000001", "variantSourceId": "41000000001", "productTitle": "Plan A", "variantTitle": "Monthly", "sku": "PLAN-A-M", "productStatus": "active"},
                                                         {"productSourceId": "71000000002", "variantSourceId": "41000000002", "productTitle": "Accessory"},
                                                         {"productSourceId": "71000000003", "variantSourceId": "41000000003", "productTitle": "Install", "sku": "INSTALL-1", "productStatus": "draft"}]');
    v_txt := j::text;
    j := cma.ingest_upsert_subscription_products(v_sub1, '[{"productSourceId": "71000000001", "variantSourceId": "41000000001", "productTitle": "Plan A", "variantTitle": "Monthly", "sku": "PLAN-A-M", "productStatus": "active"},
                                                         {"productSourceId": "71000000002", "variantSourceId": "41000000002", "productTitle": "Accessory, renamed"}]');
    v_txt := v_txt || ' | ' || j::text;
    v_txt := v_txt || ' ' || (select string_agg(v.variant_source_id || ':' || coalesce(v.sku, '-') || ':' || (v.source_deleted_at is null)::text, ' '
                                                                     order by v.variant_source_id collate "C")
                                                   from cma.subscription_product_variant v where v.connection_id = v_sub1);
    v_txt := v_txt || ' | ' || concat_ws(' ',
      pg_temp.v0009w_code(format('select cma.ingest_upsert_subscription_products(%L, ''[{"productSourceId": "1", "variantSourceId": "2", "variantTitle": "Call x@example.invalid"}]'')', v_sub1)),
      pg_temp.v0009w_code(format('select cma.ingest_upsert_subscription_products(%L, %L::jsonb)', v_sub1,
        jsonb_build_array(jsonb_build_object('productSourceId', '1', 'variantSourceId', '2', 'sku', 'A' || chr(7) || 'B')))),
      pg_temp.v0009w_code(format('select cma.ingest_upsert_subscription_products(%L, %L::jsonb)', v_sub1,
        jsonb_build_array(jsonb_build_object('productSourceId', '1', 'variantSourceId', '2', 'productTitle', repeat('x', 101))))),
      pg_temp.v0009w_code(format('select cma.ingest_upsert_subscription_products(%L, ''[]'')', v_sub1)),
      pg_temp.v0009w_code(format('select cma.ingest_upsert_subscription_products(%L, ''[{"productSourceId": "1", "variantSourceId": "2"}, {"productSourceId": "1", "variantSourceId": "2"}]'')', v_sub1)));
    v_rows := v_rows || array['16', 'B6 the catalog: inserted, a smaller set marks the rest missing; an @, a control character, 101 characters, an empty set, a variant twice refused',
      case when v_txt = '{"updated": 0, "inserted": 3, "unchanged": 0, "missing_now": 0} | {"updated": 1, "inserted": 0, "unchanged": 1, "missing_now": 1} '
                        || '41000000001:PLAN-A-M:true 41000000002:-:true 41000000003:INSTALL-1:false | CMA04 CMA04 CMA04 CMA04 CMA04'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B7. the billing events: every kind inserted, a rerun unchanged; a chargeback without a subscription joins its
    --     renewal by the store's order
    perform cma.ingest_upsert_subscription_events(v_sub1, pg_temp.v0009w_events());
    v_txt := (select string_agg(x.outcome || ':' || x.n, ' ' order by x.outcome) from (select b.outcome, count(*) as n
              from cma.ingest_upsert_billing_events(v_sub1, pg_temp.v0009w_billing()) b group by 1) x);
    v_txt := v_txt || ' ' || (select string_agg(x.outcome || ':' || x.n, ' ' order by x.outcome) from (select b.outcome, count(*) as n
                              from cma.ingest_upsert_billing_events(v_sub1, pg_temp.v0009w_billing()) b group by 1) x);
    v_txt := v_txt || ' | ' || (select string_agg(distinct b.kind, ' ' order by b.kind) from cma.billing_event b where b.connection_id = v_sub1)
             || ' | ' || (select string_agg(b.return_code || ':' || b.instrument_type || ':' || coalesce(e.subscription_source_id, '-'), ' ' order by b.source_id collate "C")
                          from cma.billing_event b
                          left join cma.subscription_event e on e.tenant_id = b.tenant_id and e.connection_id = b.connection_id and e.event_type = 'renewed'
                                                            and e.order_source_id = b.order_source_id
                          where b.connection_id = v_sub1 and b.kind = 'chargeback');
    v_rows := v_rows || array['17', 'B7 the billing events: every kind inserted, a rerun unchanged, a chargeback joined to its renewal by the store''s order',
      case when v_txt = 'inserted:11 unchanged:11 | chargeback invoice_overdue invoice_paid invoice_payment_failed invoice_placed order_draft_created '
                        || 'order_placement_failed refund_completed refund_created refund_failed | MD01:sepa_direct_debit:sub-a fraudulent:card:-'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B8. the billing events refused: an unknown kind, a return code on a refund, a return code out of its form, an
    --     instrument outside the seven, an order id that is no digits, partial on an invoice, an @ in raw, no time
    v_txt := concat_ws(' ',
      pg_temp.v0009w_code(format('select * from cma.ingest_upsert_billing_events(%L, ''[{"sourceId": "bx", "kind": "dispute", "occurredAt": "2026-11-11T10:00:00.000Z"}]'')', v_sub1)),
      pg_temp.v0009w_code(format('select * from cma.ingest_upsert_billing_events(%L, ''[{"sourceId": "bx", "kind": "refund_created", "occurredAt": "2026-11-11T10:00:00.000Z", "returnCode": "MD01"}]'')', v_sub1)),
      pg_temp.v0009w_code(format('select * from cma.ingest_upsert_billing_events(%L, ''[{"sourceId": "bx", "kind": "chargeback", "occurredAt": "2026-11-11T10:00:00.000Z", "returnCode": "No Mandate"}]'')', v_sub1)),
      pg_temp.v0009w_code(format('select * from cma.ingest_upsert_billing_events(%L, ''[{"sourceId": "bx", "kind": "chargeback", "occurredAt": "2026-11-11T10:00:00.000Z", "instrumentType": "klarna"}]'')', v_sub1)),
      pg_temp.v0009w_code(format('select * from cma.ingest_upsert_billing_events(%L, ''[{"sourceId": "bx", "kind": "chargeback", "occurredAt": "2026-11-11T10:00:00.000Z", "orderSourceId": "gid-1"}]'')', v_sub1)),
      pg_temp.v0009w_code(format('select * from cma.ingest_upsert_billing_events(%L, ''[{"sourceId": "bx", "kind": "invoice_paid", "occurredAt": "2026-11-11T10:00:00.000Z", "partial": true}]'')', v_sub1)),
      pg_temp.v0009w_code(format('select * from cma.ingest_upsert_billing_events(%L, ''[{"sourceId": "bx", "kind": "chargeback", "occurredAt": "2026-11-11T10:00:00.000Z", "raw": {"id": "x@example.invalid"}}]'')', v_sub1)),
      pg_temp.v0009w_code(format('select * from cma.ingest_upsert_billing_events(%L, ''[{"sourceId": "bx", "kind": "chargeback"}]'')', v_sub1)));
    v_rows := v_rows || array['18', 'B8 the billing events refused: an unknown kind, a refund''s return code, a code out of form, an instrument outside the seven, a non-digit order, partial on an invoice, an @, no time',
      case when v_txt = 'CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B9. the new event types and their columns stored; the refusals: a cause on another type, an interval on another
    --     type, a related subscription on another type, an order on a non-renewal, a type outside the twenty-two
    v_txt := (select string_agg(e.event_type || ':' || concat_ws(',', e.cycle_index, to_char(e.billing_from_at at time zone 'UTC', 'MM-DD'),
                                                               to_char(e.billing_to_at at time zone 'UTC', 'MM-DD'), e.cause_code, e.interval_from,
                                                               e.interval_count_from, e.interval_to, e.interval_count_to, e.lines_added, e.lines_removed,
                                                               e.lines_updated, e.related_subscription_source_id, e.operation_source_id, e.order_source_id,
                                                               e.error_code), ' ' order by e.source_id collate "C")
              from cma.subscription_event e where e.connection_id = v_sub1 and e.source_id like 'ne-%')
             || ' | ' || concat_ws(' ',
      pg_temp.v0009w_code(format('select * from cma.ingest_upsert_subscription_events(%L, ''[{"sourceId": "nx", "subscriptionSourceId": "sub-a", "eventType": "skipped", "occurredAt": "2026-11-11T10:00:00.000Z", "causeCode": "requested"}]'')', v_sub1)),
      pg_temp.v0009w_code(format('select * from cma.ingest_upsert_subscription_events(%L, ''[{"sourceId": "nx", "subscriptionSourceId": "sub-a", "eventType": "renewed", "occurredAt": "2026-11-11T10:00:00.000Z", "intervalTo": "year"}]'')', v_sub1)),
      pg_temp.v0009w_code(format('select * from cma.ingest_upsert_subscription_events(%L, ''[{"sourceId": "nx", "subscriptionSourceId": "sub-a", "eventType": "paused", "occurredAt": "2026-11-11T10:00:00.000Z", "relatedSubscriptionSourceId": "sub-b"}]'')', v_sub1)),
      pg_temp.v0009w_code(format('select * from cma.ingest_upsert_subscription_events(%L, ''[{"sourceId": "nx", "subscriptionSourceId": "sub-a", "eventType": "purchased", "occurredAt": "2026-11-11T10:00:00.000Z", "orderSourceId": "6100000009"}]'')', v_sub1)),
      pg_temp.v0009w_code(format('select * from cma.ingest_upsert_subscription_events(%L, ''[{"sourceId": "nx", "subscriptionSourceId": "sub-a", "eventType": "customer_logged_in", "occurredAt": "2026-11-11T10:00:00.000Z"}]'')', v_sub1)),
      pg_temp.v0009w_code(format('select * from cma.ingest_upsert_subscription_events(%L, ''[{"sourceId": "nx", "subscriptionSourceId": "sub-a", "eventType": "billing_date_moved", "occurredAt": "2026-11-11T10:00:00.000Z", "causeCode": "code_applied"}]'')', v_sub1)));
    v_rows := v_rows || array['19', 'B9 the new event types and their columns stored; a cause, an interval, a related subscription or an order on another type refused, a type outside the list refused',
      case when v_txt = 'renewed:2,6100000001 migrated:3,06-01 billing_date_moved:11-05,11-20,requested,op-1 skipped:11-20,12-20 '
                        || 'interval_changed:month,1,year,1 lines_changed:2,1,0,op-2 lines_changed:1,op-2 discount_changed:code_applied '
                        || 'merged_to:sub-b update_failed:INVALID_VARIANT renewal_notice: payment_method_changed: purchased: created: split_from:sub-c'
                        || ' | CMA04 CMA04 CMA04 CMA04 CMA04 CMA04'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B10. the setting as the tenant's admin: trimmed, a date or empty; anything else refused
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('subscriptions.history_start_date', ' 2025-05-01 ');
    v_txt := cma.setting_of(v_t1, 'subscriptions.history_start_date');
    perform cma.set_tenant_setting('subscriptions.history_start_date', '');
    v_txt := v_txt || ' ' || coalesce(nullif(cma.setting_of(v_t1, 'subscriptions.history_start_date'), ''), 'empty') || ' ' || concat_ws(' ',
      pg_temp.v0009w_code('select cma.set_tenant_setting(''subscriptions.history_start_date'', ''2025-13-01'')'),
      pg_temp.v0009w_code('select cma.set_tenant_setting(''subscriptions.history_start_date'', ''01-05-2025'')'),
      pg_temp.v0009w_code('select cma.set_tenant_setting(''subscriptions.history_start_date'', ''all'')'));
    perform set_config('app.user_id', v_ing1::text, true);
    v_rows := v_rows || array['20', 'B10 the setting: trimmed, a date or empty; another form refused',
      case when v_txt = '2025-05-01 empty CMA04 CMA04 CMA04' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B11. the run's new counts accepted; an unknown count refused
    v_txt := concat_ws(' ',
      pg_temp.v0009w_code(format('select cma.ingest_sync_run_finish(%L, ''succeeded'', ''{"lines_new": 4, "lines_missing": 1, "variants_new": 3, "billing_events_new": 11, "changes_observed": 8, "instrument_unknown": 0, "duplicate_skipped": 1, "return_code_dropped": 0, "catalog_text_dropped": 2}'')', v_run)));
    v_txt := concat_ws(' ', v_txt, (select r.status || ':' || (r.counts ->> 'billing_events_new') from cma.sync_run r where r.id = v_run),
      pg_temp.v0009w_code(format('select cma.ingest_sync_run_finish(%L, ''succeeded'', ''{"lines_deleted": 1}'')',
                                 cma.ingest_sync_run_start(v_sub1, 'reconcile', 'subscription_product', null, null))));
    v_rows := v_rows || array['21', 'B11 the run''s new counts accepted; an unknown count refused',
      case when v_txt = 'ok succeeded:11 CMA04' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B12. row-level security: tenant two's Ingest user sees none of tenant one's rows, and cannot write into its
    --      connection; its own lines land in its own tenant
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_ing2::text, true);
    v_txt := concat_ws(' ', (select count(*) from cma.subscription_line), (select count(*) from cma.subscription_product_variant),
                       (select count(*) from cma.billing_event), (select count(*) from cma.subscription_change),
                       pg_temp.v0009w_code(format('select cma.ingest_upsert_subscription_lines(%L, array[''sub-a''], ''[]''::jsonb, null)', v_sub1)));
    perform cma.ingest_upsert_subscriptions(v_sub2, pg_temp.v0009w_subs('base'), v_run2);
    j := cma.ingest_upsert_subscription_lines(v_sub2, array['sub-a', 'sub-b'], pg_temp.v0009w_lines('base'), v_run2);
    v_txt := v_txt || ' ' || (j ->> 'inserted') || ' ' || (select count(*) from cma.subscription_line);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_ing1::text, true);
    v_txt := v_txt || ' ' || (select count(*) from cma.subscription_line);
    v_rows := v_rows || array['22', 'B12 row-level security: tenant two sees none of tenant one''s rows and cannot write into its connection; its own lines its own',
      case when v_txt like '0 0 0 0 CMA0_ 4 4 4' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B13. the application's update and delete refused where the design says so
    v_txt := concat_ws(' ',
      pg_temp.v0009w_code(format('update cma.billing_event set amount = 1 where connection_id = %L', v_sub1)),
      pg_temp.v0009w_code(format('delete from cma.billing_event where connection_id = %L', v_sub1)),
      pg_temp.v0009w_code(format('update cma.subscription_change set new_value = ''x'' where connection_id = %L', v_sub1)),
      pg_temp.v0009w_code(format('delete from cma.subscription_change where connection_id = %L', v_sub1)),
      pg_temp.v0009w_code(format('delete from cma.subscription_line where connection_id = %L', v_sub1)),
      pg_temp.v0009w_code(format('delete from cma.subscription_product_variant where connection_id = %L', v_sub1)));
    v_rows := v_rows || array['23', 'B13 the application cannot change or delete a billing event or an observed change, nor delete a line or a variant',
      case when v_txt = '42501 42501 42501 42501 42501 42501' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B14. audit rows for the four tables, the inserts by the Ingest user
    perform set_config('role', 'cma_owner', true);
    v_txt := (select string_agg(x.t || ':' || x.n, ' ' order by x.t collate "C")
              from (select a.table_name as t, count(*) as n from cma.audit_log a
                    where a.tenant_id = v_t1 and a.table_name in ('subscription_line', 'subscription_product_variant', 'billing_event', 'subscription_change')
                      and a.action = 'insert' and a.actor_user_id = v_ing1
                    group by 1) x);
    v_rows := v_rows || array['24', 'B14 audit rows for the four tables, the inserts by the Ingest user',
      case when v_txt = 'billing_event:11 subscription_change:13 subscription_line:4 subscription_product_variant:3' and not v_provoke then 'PASS' else 'FAIL' end,
      coalesce(v_txt, 'none')];

    -- B15. no column of the four tables holding an email pattern after the fixtures
    v_txt := concat_ws(' ', (select count(*) from cma.subscription_line x where x.tenant_id in (v_t1, v_t2) and to_jsonb(x)::text ~ v_email),
                       (select count(*) from cma.subscription_product_variant x where x.tenant_id in (v_t1, v_t2) and to_jsonb(x)::text ~ v_email),
                       (select count(*) from cma.billing_event x where x.tenant_id in (v_t1, v_t2) and to_jsonb(x)::text ~ v_email),
                       (select count(*) from cma.subscription_change x where x.tenant_id in (v_t1, v_t2) and to_jsonb(x)::text ~ v_email));
    v_rows := v_rows || array['25', 'B15 no column of the four tables holding an email pattern after the fixtures',
      case when v_txt = '0 0 0 0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['59', 'B the block ran to the end', 'FAIL', sqlstate || ': ' || sqlerrm];
  end;
  insert into verify_0009w (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0009w values (59, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Z. Every row of the four new tables of the database (dev or local: the flow verifier's fixtures and anything the jobs
--    wrote): no column holding an email pattern. Counts only
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_dev     boolean := current_setting('verify.dev')::boolean;
  v_email   text := current_setting('verify.email_pattern');
  v_txt     text;
begin
  if not v_dev then
    insert into verify_0009w values (61, 'Z1 a dev or local database (the dev seed''s agent.two@example.com active)', 'FAIL',
      'REFUSED: no dev seed, so this is no dev or local database; nothing read');
    return;
  end if;
  v_txt := (select count(*) from cma.subscription_line x where to_jsonb(x)::text ~ v_email) || ' of ' || (select count(*) from cma.subscription_line)
           || ' lines, ' || (select count(*) from cma.subscription_product_variant x where to_jsonb(x)::text ~ v_email) || ' of '
           || (select count(*) from cma.subscription_product_variant) || ' variants, '
           || (select count(*) from cma.billing_event x where to_jsonb(x)::text ~ v_email) || ' of ' || (select count(*) from cma.billing_event)
           || ' billing events, ' || (select count(*) from cma.subscription_change x where to_jsonb(x)::text ~ v_email) || ' of '
           || (select count(*) from cma.subscription_change) || ' changes';
  insert into verify_0009w values (61, 'Z1 every row of the four new tables of the database: no column holding an email pattern',
    case when v_txt like '0 of % lines, 0 of % variants, 0 of % billing events, 0 of % changes' and not v_provoke then 'PASS' else 'FAIL' end, v_txt);
end
$$;

-- The helpers are dropped first, so the verdict is the last thing the script prints
drop function if exists pg_temp.v0009w_code(text);
drop function if exists pg_temp.v0009w_subs(text);
drop function if exists pg_temp.v0009w_lines(text);
drop function if exists pg_temp.v0009w_billing();
drop function if exists pg_temp.v0009w_events();

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0009w
      union all
      select 99, 'verdict',
             case when not current_setting('verify.dev')::boolean then 'REFUSED'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0009w where result = 'PASS') = 24
                       and not exists (select 1 from verify_0009w where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('195_verify_subscription_lines: %s PASS, %s FAIL', (select count(*) from verify_0009w where result = 'PASS'),
                                                                     (select count(*) from verify_0009w where result <> 'PASS'))) x
order by ord;
reset role;
