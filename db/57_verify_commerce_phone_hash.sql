-- =============================================================================================
-- 57_verify_commerce_phone_hash.sql: verifies addition 0008g, the keyed hash of the phone number on
-- commerce customers and orders
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure
-- and privileges; block B works on two throwaway tenants inside a subtransaction that is always
-- rolled back. Universal otherwise: nothing of the seed is used, adapters, customers, orders and
-- hashes are invented data values (no hash below is made from a real number). Every check writes
-- one row, PASS or FAIL, and the last result lists them with the verdict, because Cloud SQL Studio
-- shows no notices. Run as your own IAM login in dev, after 56_commerce_phone_hash.sql; then
-- 37_verify_commerce.sql, 33_verify_intake_core.sql and 31_verify_ingest_crm_records.sql again
-- (unchanged).
--   A  structure and privileges: the addition row; the two columns (text, nullable, 64 lower-case
--      hex characters) with their partial indexes; nothing else personal on the two tables (their
--      exact column lists); the reporting views without the hash; the upserts the application's
--      only, in the caller's rights
--   B  behaviour: a customer's hash stored (lower-cased) and audited as a hash; the 0007b shape
--      without a hash still taken; a read without the hash clearing it (the store withheld the
--      phone); a stale read leaving it; a plain number and other malformed hashes refused with
--      nothing written; an order's hash stored, cleared by a read without it and by a deletion,
--      order_kind and lines as in 0007b; a customer's deletion clearing its hash and its orders'
--      in that connection only; the hash meeting an earlier call's (CRM and telephony) through
--      the index; permissions and tenant isolation
-- Provoke: set provoke below to true; every check must then read FAIL, and the verdict says
-- PROVOKED instead of PASS.
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

-- Dev only: a verifier that writes refuses a database without the dev seed. The flag is kept for the
-- session, so every block below stops at once and the verdict says REFUSED, also where the client
-- carries on after the error
select set_config('verify.is_dev', (exists (select 1 from cma.app_user u join cma.tenant t on t.id = u.tenant_id
                                            where u.email = 'agent.two@example.com' and u.status = 'active'))::text, false) as is_dev;
do $$
begin
  if not current_setting('verify.is_dev')::boolean then
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 57 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0008g;
create temp table verify_0008g (ord int, check_name text, result text, detail text);

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_t       text;
  v_fn      text;
  v_bad     text;
  v_detail  text;
  v_cols    text;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  -- A1. the addition is recorded
  insert into verify_0008g values (1, 'A1 addition 0008g recorded',
    case when exists (select 1 from cma.schema_migration where version = '0008g') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. per table: phone_hash text and nullable, its check 64 lower-case hex characters, a partial
  --     index on (tenant_id, phone_hash) where it is not null
  v_bad := '';
  foreach v_t in array array['commerce_customer', 'commerce_order'] loop
    select format('%s/%s', data_type, is_nullable) into v_detail
    from information_schema.columns where table_schema = 'cma' and table_name = v_t and column_name = 'phone_hash';
    if v_detail is distinct from 'text/YES' then
      v_bad := v_bad || format('cma.%s.phone_hash is %s; ', v_t, coalesce(v_detail, 'missing'));
    end if;
    if not exists (select 1 from pg_constraint
                   where conrelid = ('cma.' || v_t)::regclass and contype = 'c'
                     and pg_get_constraintdef(oid) = 'CHECK ((phone_hash ~ ''^[0-9a-f]{64}$''::text))') then
      v_bad := v_bad || format('cma.%s.phone_hash lacks its check; ', v_t);
    end if;
    if not exists (select 1 from pg_indexes
                   where schemaname = 'cma' and tablename = v_t and indexname = v_t || '_phone_hash_idx'
                     and indexdef like '%(tenant_id, phone_hash) WHERE (phone_hash IS NOT NULL)') then
      v_bad := v_bad || format('cma.%s lacks its partial phone_hash index; ', v_t);
    end if;
  end loop;
  insert into verify_0008g values (2, 'A2 the two columns, their check and their partial indexes',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A3. nothing else personal: the two tables hold exactly 0007b's columns plus phone_hash
  v_bad := '';
  select string_agg(column_name, ', ' order by ordinal_position) into v_cols
  from information_schema.columns where table_schema = 'cma' and table_name = 'commerce_customer';
  if v_cols is distinct from 'id, tenant_id, connection_id, source_system, source_id, state, locale, orders_count, amount_spent, amount_currency, source_created_at, source_updated_at, source_deleted_at, synced_at, raw, phone_hash' then
    v_bad := v_bad || format('commerce_customer [%s]; ', v_cols);
  end if;
  select string_agg(column_name, ', ' order by ordinal_position) into v_cols
  from information_schema.columns where table_schema = 'cma' and table_name = 'commerce_order';
  if v_cols is distinct from 'id, tenant_id, connection_id, source_system, source_id, order_name, customer_source_id, source_created_at, processed_at, source_updated_at, cancelled_at, cancel_reason, is_test, currency, total_amount, subtotal_amount, tax_amount, discount_amount, refunded_amount, financial_status, fulfillment_status, source_name, app_ref, landing_host, landing_path, utm, referring_host, tags, prior_orders_count, prior_count_exact, order_kind, source_deleted_at, synced_at, raw, phone_hash' then
    v_bad := v_bad || format('commerce_order [%s]; ', v_cols);
  end if;
  insert into verify_0008g values (3, 'A3 nothing else personal: the tables hold 0007b''s columns plus phone_hash',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A4. the reporting views leave the hash out (and any phone or email column); readers see the views,
  --     never the tables
  select string_agg(table_name || '.' || column_name, ', ') into v_cols
  from information_schema.columns
  where table_schema = 'cma_read' and table_name in ('commerce_customer', 'commerce_order', 'commerce_order_line', 'commerce_store')
    and (column_name like '%hash%' or column_name like '%phone%' or column_name like '%email%');
  v_bad := coalesce(v_cols, '');
  foreach v_t in array array['commerce_customer', 'commerce_order'] loop
    if not has_table_privilege('cma_readonly', 'cma_read.' || v_t, 'select') or has_table_privilege('cma_readonly', 'cma.' || v_t, 'select') then
      v_bad := v_bad || format(' readers must see cma_read.%s and not cma.%s;', v_t, v_t);
    end if;
  end loop;
  insert into verify_0008g values (4, 'A4 the reporting views leave the hash out',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A5. the two upserts: same signatures, executable by the application only, in the caller's rights
  v_bad := '';
  foreach v_fn in array array['cma.ingest_upsert_commerce_customers(uuid,jsonb)', 'cma.ingest_upsert_commerce_orders(uuid,jsonb)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' is missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                     where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      v_bad := v_bad || v_fn || ' is not the application''s only, in the caller''s rights; ';
    end if;
  end loop;
  insert into verify_0008g values (5, 'A5 the upserts are the application''s only, in the caller''s rights',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);
end
$$;

-- B. Behaviour on two throwaway tenants (rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_rows     text[] := '{}';
  v_t1       uuid;
  v_t2       uuid;
  v_admin    uuid;
  v_agent    uuid;
  v_admin2   uuid;
  v_ing1     uuid;
  v_ing2     uuid;
  v_shop     uuid;
  v_shop2    uuid;
  v_shopx    uuid;
  v_crm      uuid;
  v_tel      uuid;
  v_txt      text;
  v_detail   text;
  v_ok       boolean;
  v_n        integer;
  v_plan     text;
  v_s        timestamptz := timestamptz '2026-10-12 10:00:00+00';
  v_h1       text := repeat('c1', 32);
  v_h2       text := repeat('c2', 32);
  v_h3       text := repeat('d3', 32);
  v_h4       text := repeat('e4', 32);
  v_h5       text := repeat('f5', 32);
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    v_t1 := cma.create_tenant('verify-0008g-one', 'Verify 0008g one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008g-two', 'Verify 0008g two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent@example.invalid', 'agent') returning id into v_agent;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin2') returning id into v_admin2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin, 'admin'), (v_t1, v_agent, 'agent'), (v_t2, v_admin2, 'admin')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    select x.user_id into v_ing2 from cma.app_user_external_id x where x.tenant_id = v_t2 and x.system = 'ingest';

    -- tenant one: two shops, a CRM and a telephony connection; tenant two: a shop of its own
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    select c.connection_id into v_shop from cma.upsert_connection('verifyshop', 'Verify shop one', 'one.example.com', null, null) c;
    select c.connection_id into v_shop2 from cma.upsert_connection('verifyshop', 'Verify shop two', 'two.example.com', null, null) c;
    select c.connection_id into v_crm from cma.upsert_connection('verifycrm', 'Verify customer records', 'portal-1', null, null) c;
    select c.connection_id into v_tel from cma.upsert_connection('verifytel', 'Verify phones', 'company-1', null, null) c;
    perform cma.set_tenant_setting('commerce.renewal_source_names', 'verify renewals');
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    select c.connection_id into v_shopx from cma.upsert_connection('verifyshop', 'Verify shop one', 'one.example.com', null, null) c;
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_ing1::text, true);

    -- B1. a customer's hash stored, lower-cased; the 0007b shape without a hash still taken (null);
    --     the audit row holds the hash and no phone key
    select string_agg(u.source_id || ':' || u.outcome, ',' order by u.n) into v_txt
    from cma.ingest_upsert_commerce_customers(v_shop, jsonb_build_array(
           jsonb_build_object('sourceId', 'cu-1', 'createdAt', v_s, 'updatedAt', v_s, 'ordersCount', 1, 'phoneHash', upper(v_h1)),
           jsonb_build_object('sourceId', 'cu-2', 'createdAt', v_s, 'updatedAt', v_s, 'ordersCount', 0)))
         with ordinality u(source_id, outcome, n);
    v_ok := v_txt = 'cu-1:inserted,cu-2:inserted'
            and (select phone_hash from cma.commerce_customer where connection_id = v_shop and source_id = 'cu-1') = v_h1
            and (select phone_hash from cma.commerce_customer where connection_id = v_shop and source_id = 'cu-2') is null
            and exists (select 1 from cma.audit_log a where a.tenant_id = v_t1 and a.table_name = 'commerce_customer' and a.action = 'insert'
                          and a.new_row ->> 'source_id' = 'cu-1' and a.new_row ->> 'phone_hash' = v_h1 and not a.new_row ? 'phone');
    v_rows := v_rows || array['11', 'B1 a customer''s hash stored lower-cased; the 0007b shape still taken',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no outcome')];

    -- B2. a newer read without the hash clears it (the store withheld or removed the phone); an older
    --     read carrying a hash is stale and leaves the stored value; a newer read sets it again
    perform cma.ingest_upsert_commerce_customers(v_shop, jsonb_build_array(
      jsonb_build_object('sourceId', 'cu-1', 'updatedAt', v_s + interval '1 hour', 'ordersCount', 1)));
    v_ok := (select phone_hash from cma.commerce_customer where connection_id = v_shop and source_id = 'cu-1') is null;
    select string_agg(u.outcome, ',') into v_txt
    from cma.ingest_upsert_commerce_customers(v_shop, jsonb_build_array(
           jsonb_build_object('sourceId', 'cu-1', 'updatedAt', v_s + interval '30 minutes', 'phoneHash', v_h2))) u;
    v_ok := v_ok and v_txt = 'stale'
            and (select phone_hash from cma.commerce_customer where connection_id = v_shop and source_id = 'cu-1') is null;
    perform cma.ingest_upsert_commerce_customers(v_shop, jsonb_build_array(
      jsonb_build_object('sourceId', 'cu-1', 'updatedAt', v_s + interval '2 hours', 'phoneHash', v_h1, 'ordersCount', 2)));
    v_ok := v_ok and (select phone_hash from cma.commerce_customer where connection_id = v_shop and source_id = 'cu-1') = v_h1;
    v_rows := v_rows || array['12', 'B2 a read without the hash clears it; a stale read leaves it; a newer read sets it',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no outcome')];

    -- B3. refusals (CMA04, nothing written): a plain number, 63 characters, a letter beyond f, a JSON
    --     number, for customers and for orders
    v_n := 0;
    foreach v_txt in array array['+44 20 0000 0001', left(v_h3, 63), 'g' || left(v_h3, 63)] loop
      begin
        perform cma.ingest_upsert_commerce_customers(v_shop, jsonb_build_array(
          jsonb_build_object('sourceId', 'cu-bad', 'updatedAt', v_s, 'phoneHash', v_txt)));
      exception when sqlstate 'CMA04' then v_n := v_n + 1;
      end;
      begin
        perform cma.ingest_upsert_commerce_orders(v_shop, jsonb_build_array(
          jsonb_build_object('sourceId', 'or-bad', 'createdAt', v_s, 'updatedAt', v_s, 'phoneHash', v_txt)));
      exception when sqlstate 'CMA04' then v_n := v_n + 1;
      end;
    end loop;
    begin
      perform cma.ingest_upsert_commerce_customers(v_shop, '[{"sourceId": "cu-bad", "updatedAt": "2026-10-12T10:00:00Z", "phoneHash": 442000000001}]'::jsonb);
    exception when sqlstate 'CMA04' then v_n := v_n + 1;
    end;
    begin
      perform cma.ingest_upsert_commerce_orders(v_shop, '[{"sourceId": "or-bad", "createdAt": "2026-10-12T10:00:00Z", "phoneHash": 442000000001}]'::jsonb);
    exception when sqlstate 'CMA04' then v_n := v_n + 1;
    end;
    v_ok := v_n = 8
            and not exists (select 1 from cma.commerce_customer where tenant_id = v_t1 and source_id = 'cu-bad')
            and not exists (select 1 from cma.commerce_order where tenant_id = v_t1 and source_id = 'or-bad')
            and not exists (select 1 from cma.audit_log a where a.tenant_id = v_t1 and a.table_name in ('commerce_customer', 'commerce_order')
                              and (a.new_row::text like '%+44 20 0000 0001%' or a.new_row::text like '%442000000001%'));
    v_rows := v_rows || array['13', 'B3 a plain number and malformed hashes refused, nothing written',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, format('%s of 8 refusals', v_n)];

    -- B4. orders: a first, a repeat and a renewal with their hashes and lines; a read without the
    --     hash clears it and keeps kind and lines; a deletion clears it and keeps ids, times and kind
    select string_agg(u.source_id || ':' || u.outcome || ':' || u.order_kind, ',' order by u.n) into v_txt
    from cma.ingest_upsert_commerce_orders(v_shop, jsonb_build_array(
           jsonb_build_object('sourceId', 'or-1', 'customerId', 'cu-1', 'createdAt', v_s, 'updatedAt', v_s, 'priorOrdersCount', 0,
                              'phoneHash', v_h1, 'lines', jsonb_build_array(jsonb_build_object('lineId', 'l-1', 'quantity', 1))),
           jsonb_build_object('sourceId', 'or-2', 'customerId', 'cu-1', 'createdAt', v_s + interval '1 day', 'updatedAt', v_s + interval '1 day',
                              'priorOrdersCount', 1, 'phoneHash', v_h3),
           jsonb_build_object('sourceId', 'or-3', 'customerId', 'cu-2', 'createdAt', v_s, 'updatedAt', v_s, 'priorOrdersCount', 4,
                              'sourceName', 'Verify Renewals', 'phoneHash', v_h4)))
         with ordinality u(source_id, outcome, order_kind, n);
    v_ok := v_txt = 'or-1:inserted:first,or-2:inserted:repeat,or-3:inserted:renewal'
            and (select string_agg(source_id || '=' || left(phone_hash, 2), ',' order by source_id) from cma.commerce_order
                 where connection_id = v_shop) = 'or-1=c1,or-2=d3,or-3=e4';
    perform cma.ingest_upsert_commerce_orders(v_shop, jsonb_build_array(
      jsonb_build_object('sourceId', 'or-1', 'customerId', 'cu-1', 'createdAt', v_s, 'updatedAt', v_s + interval '1 hour', 'priorOrdersCount', 0)));
    v_ok := v_ok and exists (select 1 from cma.commerce_order where connection_id = v_shop and source_id = 'or-1'
                               and phone_hash is null and order_kind = 'first')
            and exists (select 1 from cma.commerce_order_line where connection_id = v_shop and order_source_id = 'or-1' and line_source_id = 'l-1');
    select string_agg(u.outcome || ':' || u.order_kind, ',') into v_detail
    from cma.ingest_upsert_commerce_orders(v_shop, jsonb_build_array(
           jsonb_build_object('sourceId', 'or-3', 'deletedAt', v_s + interval '2 hours'))) u;
    v_ok := v_ok and v_detail = 'deleted:renewal'
            and exists (select 1 from cma.commerce_order where connection_id = v_shop and source_id = 'or-3'
                          and phone_hash is null and source_deleted_at is not null and total_amount is null and order_kind = 'renewal');
    v_rows := v_rows || array['14', 'B4 orders: hash stored, cleared by a read without it and by a deletion; kinds and lines as in 0007b',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no outcome') || ' | ' || coalesce(v_detail, 'no outcome')];

    -- B5. a customer's deletion clears its hash and its orders' in that connection; the same
    --     customer id's order in the second shop and another customer's order keep theirs
    perform cma.ingest_upsert_commerce_orders(v_shop2, jsonb_build_array(
      jsonb_build_object('sourceId', 'or-9', 'customerId', 'cu-1', 'createdAt', v_s, 'updatedAt', v_s, 'priorOrdersCount', 0, 'phoneHash', v_h5)));
    perform cma.ingest_upsert_commerce_orders(v_shop, jsonb_build_array(
      jsonb_build_object('sourceId', 'or-4', 'customerId', 'cu-2', 'createdAt', v_s, 'updatedAt', v_s, 'priorOrdersCount', 0, 'phoneHash', v_h4)));
    select string_agg(u.outcome, ',') into v_txt
    from cma.ingest_upsert_commerce_customers(v_shop, jsonb_build_array(
           jsonb_build_object('sourceId', 'cu-1', 'deletedAt', v_s + interval '3 hours'))) u;
    v_ok := v_txt = 'deleted'
            and (select phone_hash from cma.commerce_customer where connection_id = v_shop and source_id = 'cu-1') is null
            and (select phone_hash from cma.commerce_order where connection_id = v_shop and source_id = 'or-2') is null
            and (select phone_hash from cma.commerce_order where connection_id = v_shop2 and source_id = 'or-9') = v_h5
            and (select phone_hash from cma.commerce_order where connection_id = v_shop and source_id = 'or-4') = v_h4;
    v_rows := v_rows || array['15', 'B5 a customer''s deletion clears its hash and its orders'' in that connection only',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no outcome')];

    -- B6. what the hash is for: an order's hash meets an earlier CRM call's and telephony call's
    --     counterpart_hash; the lookup by hash can use the partial index
    perform cma.ingest_upsert_calls(v_crm, jsonb_build_array(jsonb_build_object(
      'sourceId', 'k-1', 'occurredAt', v_s - interval '2 days', 'direction', 'inbound', 'counterpartHash', v_h4,
      'createdAt', v_s - interval '2 days', 'updatedAt', v_s - interval '2 days')));
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(jsonb_build_object(
      'sourceId', 't-1', 'direction', 'inbound', 'startedAt', v_s - interval '2 days', 'counterpartHash', v_h4,
      'versionAt', v_s - interval '2 days')));
    select string_agg(o.source_id || '<' || k.source_id || '/' || t.source_id, ',' order by o.source_id) into v_txt
    from cma.commerce_order o
    join cma.crm_call k on k.tenant_id = o.tenant_id and k.counterpart_hash = o.phone_hash and k.occurred_at < o.source_created_at
    join cma.telephony_call t on t.tenant_id = o.tenant_id and t.counterpart_hash = o.phone_hash and t.started_at < o.source_created_at
    where o.tenant_id = v_t1;
    set local enable_seqscan = off;
    execute format('explain (format json) select id from cma.commerce_order where tenant_id = %L and phone_hash = %L', v_t1, v_h4) into v_plan;
    v_detail := v_plan;
    execute format('explain (format json) select id from cma.commerce_customer where tenant_id = %L and phone_hash = %L', v_t1, v_h1) into v_plan;
    set local enable_seqscan = on;
    v_ok := v_txt = 'or-4<k-1/t-1' and v_detail like '%commerce_order_phone_hash_idx%' and v_plan like '%commerce_customer_phone_hash_idx%';
    v_rows := v_rows || array['16', 'B6 an order''s hash meets an earlier call''s, the lookup by hash uses the index',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no match') || ' | ' || coalesce(substring(v_detail from '"Index Name": "([a-z_]+)"'), 'no index') || ', ' || coalesce(substring(v_plan from '"Index Name": "([a-z_]+)"'), 'no index')];

    -- B7. permissions: an agent and a configuring person cannot write a hash (CMA06); tenant two's
    --     Ingest user cannot write into tenant one's shop (CMA02) and sees none of its hashes
    v_n := 0;
    perform set_config('app.user_id', v_agent::text, true);
    begin
      perform cma.ingest_upsert_commerce_customers(v_shop, jsonb_build_array(jsonb_build_object('sourceId', 'cu-7', 'updatedAt', v_s, 'phoneHash', v_h2)));
    exception when sqlstate 'CMA06' then v_n := v_n + 1;
    end;
    perform set_config('app.user_id', v_admin::text, true);
    begin
      perform cma.ingest_upsert_commerce_orders(v_shop, jsonb_build_array(jsonb_build_object('sourceId', 'or-7', 'createdAt', v_s, 'phoneHash', v_h2)));
    exception when sqlstate 'CMA06' then v_n := v_n + 1;
    end;
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_ing2::text, true);
    begin
      perform cma.ingest_upsert_commerce_customers(v_shop, jsonb_build_array(jsonb_build_object('sourceId', 'cu-7', 'updatedAt', v_s, 'phoneHash', v_h2)));
    exception when sqlstate 'CMA02' then v_n := v_n + 1;
    end;
    perform cma.ingest_upsert_commerce_customers(v_shopx, jsonb_build_array(
      jsonb_build_object('sourceId', 'cu-1', 'updatedAt', v_s, 'phoneHash', v_h2)));
    v_ok := v_n = 3
            and (select count(*) from cma.commerce_customer where phone_hash is not null) = 1
            and (select count(*) from cma.commerce_order where phone_hash is not null) = 0
            and (select phone_hash from cma.commerce_customer where connection_id = v_shopx and source_id = 'cu-1') = v_h2;
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_ing1::text, true);
    v_ok := v_ok and not exists (select 1 from cma.commerce_customer where tenant_id = v_t1 and source_id = 'cu-7')
            and (select count(*) from cma.commerce_customer where phone_hash = v_h2) = 0;
    v_rows := v_rows || array['17', 'B7 permissions and tenant isolation',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, format('%s of 3 refusals', v_n)];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['39', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008g (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008g values (39, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008g
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED: not dev'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008g where result = 'PASS') = 12
                       and not exists (select 1 from verify_0008g where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0008g where result = 'PASS'),
                                        (select count(*) from verify_0008g where result <> 'PASS'))) x
order by ord;
reset role;
