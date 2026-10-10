-- =============================================================================================
-- 37_verify_commerce.sql: verifies migration 0007b, commerce
-- =============================================================================================
-- Block A checks structure and privileges; blocks B to E each work on two throwaway tenants inside
-- a subtransaction that is always rolled back. All universal: no seed is assumed. Cloud SQL Studio
-- shows no notices: a check that fails raises "FAIL …" and stops the block. The last result is the
-- verdict. Run as your own IAM login, dev and prod, after 36_commerce.sql; then
-- 33_verify_intake_core.sql and 31_verify_ingest_crm_records.sql again.
--   A  structure and privileges: tables, RLS, audit, no deletes (order lines excepted), keys,
--      functions, views without raw, the settings trigger
--   B  stores: one per connection, a unique handle, the refusals, the store in connection_config
--   C  customers: inserted, updated, stale, deleted (cleared, id kept), back after a deletion only
--      with a newer read, one customer id in two stores, the refusals
--   D  orders: lines replaced as a set, order_kind first, repeat and unknown from the prior count,
--      renewal from each of the two settings, reclassification after a settings change and on
--      demand, test and cancelled orders kept and flagged, deletion, normalisation, the refusals
--   E  permissions (configuration versus ingest), tenant isolation for every new table, no deletes
-- Provoke: set provoke below to true; every block must then stop with FAIL, and the verdict
-- (reached only when the run does not stop on errors) says PROVOKED instead of PASS.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);   -- 'true' to make every block fail

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_t       text;
  v_fn      text;
  v_n       int;
  v_cols    text;
begin
  -- A1. the migration is recorded
  if not exists (select 1 from cma.schema_migration where version = '0007b') or v_provoke then
    raise exception 'FAIL A1: migration 0007b not recorded';
  end if;

  -- A2. four tenant tables, each with row-level security, the tenant policy and the audit trigger
  foreach v_t in array array['commerce_store', 'commerce_customer', 'commerce_order', 'commerce_order_line'] loop
    if to_regclass('cma.' || v_t) is null then
      raise exception 'FAIL A2: table cma.% is missing', v_t;
    end if;
    if not (select relrowsecurity from pg_class where oid = to_regclass('cma.' || v_t))
       or not exists (select 1 from pg_policy where polrelid = to_regclass('cma.' || v_t) and polname = 'tenant_app')
       or not exists (select 1 from pg_trigger where tgrelid = to_regclass('cma.' || v_t) and tgname = 'audit') then
      raise exception 'FAIL A2: cma.% lacks row-level security, its tenant policy or its audit trigger', v_t;
    end if;
  end loop;

  -- A3. the app inserts and updates but never deletes stores, customers or orders; order lines are
  --     a set replaced with their order
  foreach v_t in array array['commerce_store', 'commerce_customer', 'commerce_order'] loop
    if has_table_privilege('cma_app', 'cma.' || v_t, 'delete') or not has_table_privilege('cma_app', 'cma.' || v_t, 'insert')
       or not has_table_privilege('cma_app', 'cma.' || v_t, 'update') then
      raise exception 'FAIL A3: cma_app must insert into and update, and never delete from cma.%', v_t;
    end if;
  end loop;
  if not has_table_privilege('cma_app', 'cma.commerce_order_line', 'delete') then
    raise exception 'FAIL A3: cma_app must be able to replace the lines of an order';
  end if;

  -- A4. the keys: one store per connection, a handle unique in the tenant, one row per source id and
  --     connection, lines belong to an order
  select count(*) into v_n from pg_constraint c
  where c.contype in ('u', 'f', 'p')
    and ((c.conrelid = 'cma.commerce_store'::regclass and pg_get_constraintdef(c.oid) in ('UNIQUE (tenant_id, connection_id)', 'UNIQUE (tenant_id, handle)'))
      or (c.conrelid = 'cma.commerce_customer'::regclass and pg_get_constraintdef(c.oid) = 'UNIQUE (tenant_id, connection_id, source_id)')
      or (c.conrelid = 'cma.commerce_order'::regclass and pg_get_constraintdef(c.oid) = 'UNIQUE (tenant_id, connection_id, source_id)')
      or (c.conrelid = 'cma.commerce_order_line'::regclass
          and pg_get_constraintdef(c.oid) in ('PRIMARY KEY (tenant_id, connection_id, order_source_id, line_source_id)',
                                              'FOREIGN KEY (tenant_id, connection_id, order_source_id) REFERENCES commerce_order(tenant_id, connection_id, source_id)',
                                              'FOREIGN KEY (tenant_id, connection_id, order_source_id) REFERENCES cma.commerce_order(tenant_id, connection_id, source_id)')));
  if v_n <> 6 then
    raise exception 'FAIL A4: % of 6 keys on the commerce tables', v_n;
  end if;

  -- A5. the functions: the app may execute them, readers and public may not; none runs as its owner
  foreach v_fn in array array[
    'cma.upsert_commerce_store(uuid,text,text,text,text,text)', 'cma.reclassify_orders()', 'cma.connection_config(uuid)',
    'cma.ingest_upsert_commerce_customers(uuid,jsonb)', 'cma.ingest_upsert_commerce_orders(uuid,jsonb)',
    'cma.commerce_tags_ok(text[])', 'cma.commerce_renewal_lists(uuid)', 'cma.commerce_order_kind(text,text,integer,text[],text[])',
    'cma.reclassify_orders_of(uuid)', 'cma.reclassify_orders_on_setting()'
  ] loop
    if to_regprocedure(v_fn) is null then
      raise exception 'FAIL A5: % does not exist', v_fn;
    end if;
    if not has_function_privilege('cma_app', v_fn, 'execute')
       or has_function_privilege('cma_readonly', v_fn, 'execute')
       or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                  where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE') then
      raise exception 'FAIL A5: execute on % must be granted to cma_app only', v_fn;
    end if;
    if (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      raise exception 'FAIL A5: % must run with the caller''s rights', v_fn;
    end if;
  end loop;

  -- A6. reporting views: readers see each view and never the table; no raw payload in any of them;
  --     the customer view's exact columns
  foreach v_t in array array['commerce_store', 'commerce_customer', 'commerce_order', 'commerce_order_line'] loop
    if not has_table_privilege('cma_readonly', 'cma_read.' || v_t, 'select') or has_table_privilege('cma_readonly', 'cma.' || v_t, 'select') then
      raise exception 'FAIL A6: readers must see cma_read.% and not cma.%', v_t, v_t;
    end if;
  end loop;
  select string_agg(table_name || '.' || column_name, ', ') into v_cols
  from information_schema.columns
  where table_schema = 'cma_read' and table_name in ('commerce_store', 'commerce_customer', 'commerce_order', 'commerce_order_line')
    and (column_name in ('raw', 'key', 'settings') or column_name like '%secret%' or column_name like '%token%'
         or column_name like '%email%' or column_name like '%phone%' or column_name like '%name' and column_name not in ('name', 'order_name', 'source_name'));
  if v_cols is not null then
    raise exception 'FAIL A6: reporting views expose %', v_cols;
  end if;
  select string_agg(column_name, ', ' order by ordinal_position) into v_cols
  from information_schema.columns where table_schema = 'cma_read' and table_name = 'commerce_customer';
  if v_cols is distinct from 'id, tenant_id, connection_id, source_system, source_id, state, locale, orders_count, amount_spent, amount_currency, source_created_at, source_updated_at, source_deleted_at, synced_at' then
    raise exception 'FAIL A6: cma_read.commerce_customer exposes [%]', v_cols;
  end if;
  select count(*) into v_n from information_schema.columns
  where table_schema = 'cma_read' and table_name = 'commerce_order'
    and column_name in ('order_kind', 'is_test', 'prior_orders_count', 'prior_count_exact', 'tags', 'utm', 'landing_path');
  if v_n <> 7 then
    raise exception 'FAIL A6: cma_read.commerce_order lacks % of 7 columns', 7 - v_n;
  end if;

  -- A7. the renewal settings exist (0007) and a change to them reclassifies through the trigger
  if (select count(*) from cma.setting where key in ('commerce.renewal_source_names', 'commerce.renewal_app_ids') and value_type = 'text') <> 2
     or not exists (select 1 from pg_trigger where tgrelid = 'cma.tenant_setting'::regclass and tgname = 'reclassify_orders'
                    and tgfoid = 'cma.reclassify_orders_on_setting()'::regprocedure and not tgisinternal) then
    raise exception 'FAIL A7: the renewal settings or the reclassification trigger on tenant_setting are missing';
  end if;
end
$$;

-- B. Stores (throwaway tenants, rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_t1       uuid;
  v_admin    uuid;
  v_c1       uuid;
  v_c2       uuid;
  v_c3       uuid;
  v_s1       uuid;
  v_id       uuid;
  v_txt      text;
  v_cfg      jsonb;
begin
  begin
    v_t1 := cma.create_tenant('verify-0007b-one', 'Verify 0007b one', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'Verify admin') returning id into v_admin;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t1, v_admin, ar.id from cma.app_role ar where ar.tenant_id = v_t1 and ar.key = 'admin';

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    select c.connection_id into v_c1 from cma.upsert_connection('verify_shop', 'Verify shop one', 'one.example.com', null, null) c;
    select c.connection_id into v_c2 from cma.upsert_connection('verify_shop', 'Verify shop two', 'two.example.com', null, null) c;
    select c.connection_id into v_c3 from cma.upsert_connection('verify_shop', 'Verify shop three', 'three.example.com', null, null) c;
    perform cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP');
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');

    -- B1. a store per connection: created, then updated in place (same id, one row); a second
    --     connection gets its own store
    v_s1 := cma.upsert_commerce_store(v_c1, 'verify-uk', 'Verify UK', 'GB', 'GBP', 'Europe/London');
    v_id := cma.upsert_commerce_store(v_c1, 'verify-gb', ' Verify GB ', 'GB', 'GBP', 'Europe/London');
    perform cma.upsert_commerce_store(v_c2, 'verify-nl', 'Verify NL', 'NL', 'EUR', 'Europe/Amsterdam');
    select string_agg(handle || ':' || name || ':' || market || ':' || currency || ':' || time_zone, ',' order by handle) into v_txt
    from cma.commerce_store;
    if v_id <> v_s1 or v_txt is distinct from 'verify-gb:Verify GB:GB:GBP:Europe/London,verify-nl:Verify NL:NL:EUR:Europe/Amsterdam' or v_provoke then
      raise exception 'FAIL B1: stores are % (same id: %)', v_txt, v_id = v_s1;
    end if;

    -- B2. a handle is unique in the tenant: another connection cannot take it, through the function
    --     (CMA03) or directly (the key); a second store on one connection is refused by the key
    begin
      perform cma.upsert_commerce_store(v_c3, 'verify-nl', 'Verify NL again', 'NL', 'EUR', 'Europe/Amsterdam');
      raise exception 'FAIL B2: a second store took the handle verify-nl';
    exception when sqlstate 'CMA03' then null;
    end;
    begin
      insert into cma.commerce_store (connection_id, handle, name, market, currency, time_zone)
      values (v_c3, 'verify-nl', 'Verify NL again', 'NL', 'EUR', 'Europe/Amsterdam');
      raise exception 'FAIL B2: the table took a duplicate handle';
    exception when unique_violation then null;
    end;
    begin
      insert into cma.commerce_store (connection_id, handle, name, market, currency, time_zone)
      values (v_c1, 'verify-gb-2', 'Verify GB 2', 'GB', 'GBP', 'Europe/London');
      raise exception 'FAIL B2: the table took a second store on one connection';
    exception when unique_violation then null;
    end;

    -- B3. refusals: an upper-case or spaced handle, an empty name, a market not in the catalog (UK
    --     included), a lower-case currency, an unknown zone (CMA04 or CMA02), an unknown connection
    foreach v_txt in array array[
      format('select cma.upsert_commerce_store(%L, ''Verify-Shop'', ''Verify'', ''GB'', ''GBP'', ''Europe/London'')', v_c3),
      format('select cma.upsert_commerce_store(%L, ''verify shop'', ''Verify'', ''GB'', ''GBP'', ''Europe/London'')', v_c3),
      format('select cma.upsert_commerce_store(%L, ''verify-shop'', '' '', ''GB'', ''GBP'', ''Europe/London'')', v_c3),
      format('select cma.upsert_commerce_store(%L, ''verify-shop'', ''Verify'', ''GB'', ''gbp'', ''Europe/London'')', v_c3),
      format('select cma.upsert_commerce_store(%L, ''verify-shop'', ''Verify'', ''GB'', ''GBP'', ''Europe/Atlantis'')', v_c3)
    ] loop
      begin
        execute v_txt;
        raise exception 'FAIL B3: % was accepted', v_txt;
      exception when sqlstate 'CMA04' then null;
      end;
    end loop;
    foreach v_txt in array array[
      format('select cma.upsert_commerce_store(%L, ''verify-shop'', ''Verify'', ''UK'', ''GBP'', ''Europe/London'')', v_c3),
      format('select cma.upsert_commerce_store(%L, ''verify-shop'', ''Verify'', ''DE'', ''EUR'', ''Europe/Berlin'')', v_c3),
      format('select cma.upsert_commerce_store(%L, ''verify-shop'', ''Verify'', ''GB'', ''GBP'', ''Europe/London'')', gen_random_uuid())
    ] loop
      begin
        execute v_txt;
        raise exception 'FAIL B3: % was accepted', v_txt;
      exception when sqlstate 'CMA02' then null;
      end;
    end loop;
    if exists (select 1 from cma.commerce_store where connection_id = v_c3) then
      raise exception 'FAIL B3: a refused store was written';
    end if;

    -- B4. the adapter's configuration names the store; a connection without one answers null
    v_cfg := cma.connection_config(v_c1);
    if v_cfg -> 'store' is distinct from '{"handle": "verify-gb", "name": "Verify GB", "market": "GB", "currency": "GBP", "timeZone": "Europe/London"}'::jsonb
       or jsonb_typeof(cma.connection_config(v_c3) -> 'store') is distinct from 'null'
       or not (v_cfg ? 'fields' and v_cfg ? 'pipelines' and v_cfg ? 'settings') then
      raise exception 'FAIL B4: connection_config gives %', v_cfg;
    end if;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- C. Customers (throwaway tenants, rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_t1       uuid;
  v_ing1     uuid;
  v_c1       uuid;
  v_c2       uuid;
  v_id       uuid;
  v_txt      text;
  r          record;
begin
  begin
    v_t1 := cma.create_tenant('verify-0007b-one', 'Verify 0007b one', 'Europe/Amsterdam');
    select id into v_ing1 from cma.app_user where tenant_id = v_t1 and email = 'ingest@system.invalid';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t1, 'verify_shop', 'Verify shop one', 'one.example.com') returning id into v_c1;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t1, 'verify_shop', 'Verify shop two', 'two.example.com') returning id into v_c2;

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_ing1::text, true);

    -- C1. two customers inserted; amount and currency normalised, the adapter as source system
    select string_agg(u.outcome, ',' order by u.source_id) into v_txt
    from cma.ingest_upsert_commerce_customers(v_c1, '[
      {"sourceId": "1001", "state": "ENABLED", "locale": "en-GB", "ordersCount": 2, "amountSpent": "120.505", "currency": "gbp",
       "createdAt": "2026-10-01T09:00:00Z", "updatedAt": "2026-10-02T09:00:00Z", "raw": {"verified_email": true}},
      {"sourceId": "1002", "ordersCount": 0, "amountSpent": 0, "currency": "GBP", "updatedAt": "2026-10-02T09:00:00Z"}]') u;
    select * into r from cma.commerce_customer where connection_id = v_c1 and source_id = '1001';
    if v_txt is distinct from 'inserted,inserted' or r.amount_spent <> 120.51 or r.amount_currency <> 'GBP' or r.orders_count <> 2
       or r.locale <> 'en-GB' or r.source_system <> 'verify_shop' or r.source_created_at <> '2026-10-01T09:00:00Z'::timestamptz or v_provoke then
      raise exception 'FAIL C1: customers gave % and hold %, %, %', v_txt, r.amount_spent, r.amount_currency, r.orders_count;
    end if;

    -- C2. a newer read updates, an equal one too, an older one is stale and changes nothing
    select string_agg(u.outcome, ',' order by u.source_id) into v_txt
    from cma.ingest_upsert_commerce_customers(v_c1, '[
      {"sourceId": "1001", "state": "ENABLED", "locale": "nl-NL", "ordersCount": 3, "amountSpent": "150.00", "currency": "GBP",
       "updatedAt": "2026-10-03T09:00:00Z"},
      {"sourceId": "1002", "ordersCount": 1, "amountSpent": "10", "currency": "GBP", "updatedAt": "2026-10-02T09:00:00Z"}]') u;
    if v_txt is distinct from 'updated,updated' then
      raise exception 'FAIL C2: newer and equal reads gave %', v_txt;
    end if;
    select string_agg(u.outcome, ',') into v_txt
    from cma.ingest_upsert_commerce_customers(v_c1, '[{"sourceId": "1001", "ordersCount": 9, "updatedAt": "2026-10-02T12:00:00Z"}]') u;
    select * into r from cma.commerce_customer where connection_id = v_c1 and source_id = '1001';
    if v_txt is distinct from 'stale' or r.orders_count <> 3 or r.locale <> 'nl-NL' or r.source_created_at <> '2026-10-01T09:00:00Z'::timestamptz then
      raise exception 'FAIL C2: an older read gave % and left %, %', v_txt, r.orders_count, r.locale;
    end if;

    -- C3. a deletion keeps the id and times and clears state, locale, counts, amounts and raw; an
    --     unknown deletion writes nothing
    v_id := r.id;
    select string_agg(u.outcome, ',' order by u.source_id) into v_txt
    from cma.ingest_upsert_commerce_customers(v_c1, '[{"sourceId": "1001", "deletedAt": "2026-10-04T09:00:00Z"},
                                                      {"sourceId": "1999", "deletedAt": "2026-10-04T09:00:00Z"}]') u;
    select * into r from cma.commerce_customer where connection_id = v_c1 and source_id = '1001';
    if v_txt is distinct from 'deleted,unknown' or r.id <> v_id or r.source_deleted_at <> '2026-10-04T09:00:00Z'::timestamptz
       or r.state is not null or r.locale is not null or r.orders_count is not null or r.amount_spent is not null
       or r.amount_currency is not null or r.raw <> '{}'::jsonb or r.source_created_at is null
       or exists (select 1 from cma.commerce_customer where source_id = '1999') then
      raise exception 'FAIL C3: deletion gave % and left %', v_txt, row_to_json(r);
    end if;

    -- C4. after a deletion a read not newer than it is stale; a newer one brings the customer back
    select string_agg(u.outcome, ',') into v_txt
    from cma.ingest_upsert_commerce_customers(v_c1, '[{"sourceId": "1001", "ordersCount": 3, "updatedAt": "2026-10-04T09:00:00Z"}]') u;
    if v_txt is distinct from 'stale' or (select orders_count from cma.commerce_customer where id = v_id) is not null then
      raise exception 'FAIL C4: a read at the deletion time gave %', v_txt;
    end if;
    select string_agg(u.outcome, ',') into v_txt
    from cma.ingest_upsert_commerce_customers(v_c1, '[{"sourceId": "1001", "ordersCount": 4, "updatedAt": "2026-10-05T09:00:00Z"}]') u;
    if v_txt is distinct from 'updated' or (select orders_count from cma.commerce_customer where id = v_id) <> 4
       or (select source_deleted_at from cma.commerce_customer where id = v_id) is not null then
      raise exception 'FAIL C4: a newer read after the deletion gave %', v_txt;
    end if;

    -- C5. one customer id in two stores: two rows, one per connection, each with its own values
    perform cma.ingest_upsert_commerce_customers(v_c2, '[{"sourceId": "1001", "ordersCount": 1, "amountSpent": 5, "currency": "EUR",
                                                         "updatedAt": "2026-10-01T09:00:00Z"}]');
    select string_agg(c.name || '=' || cc.orders_count || coalesce(cc.amount_currency, ''), ',' order by c.name) into v_txt
    from cma.commerce_customer cc join cma.integration_connection c on c.id = cc.connection_id
    where cc.source_id = '1001';
    if v_txt is distinct from 'Verify shop one=4,Verify shop two=1EUR' then
      raise exception 'FAIL C5: customer 1001 in two stores is %', v_txt;
    end if;

    -- C6. refusals: no sourceId, a negative count, a bad time, not an array, more than 500 (CMA04);
    --     an inactive connection (CMA02)
    foreach v_txt in array array[
      '[{"ordersCount": 1}]', '[{"sourceId": "1003", "ordersCount": -1}]', '[{"sourceId": "1003", "ordersCount": "many"}]',
      '[{"sourceId": "1003", "updatedAt": "yesterday"}]', '{"sourceId": "1003"}',
      (select jsonb_agg(jsonb_build_object('sourceId', g::text))::text from generate_series(1, 501) g)
    ] loop
      begin
        perform cma.ingest_upsert_commerce_customers(v_c1, v_txt::jsonb);
        raise exception 'FAIL C6: % was accepted', left(v_txt, 60);
      exception when sqlstate 'CMA04' then null;
      end;
    end loop;
    perform set_config('role', 'cma_owner', true);
    update cma.integration_connection set status = 'inactive' where id = v_c2;
    perform set_config('role', 'cma_app', true);
    begin
      perform cma.ingest_upsert_commerce_customers(v_c2, '[{"sourceId": "1003"}]');
      raise exception 'FAIL C6: an inactive connection took a customer';
    exception when sqlstate 'CMA02' then null;
    end;
    if exists (select 1 from cma.commerce_customer where source_id = '1003') then
      raise exception 'FAIL C6: a refused customer was written';
    end if;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- D. Orders, lines and order kinds (throwaway tenants, rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_t1       uuid;
  v_admin    uuid;
  v_ing1     uuid;
  v_c1       uuid;
  v_txt      text;
  v_n        int;
  r          record;
begin
  begin
    v_t1 := cma.create_tenant('verify-0007b-one', 'Verify 0007b one', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'Verify admin') returning id into v_admin;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t1, v_admin, ar.id from cma.app_role ar where ar.tenant_id = v_t1 and ar.key = 'admin';
    select id into v_ing1 from cma.app_user where tenant_id = v_t1 and email = 'ingest@system.invalid';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t1, 'verify_shop', 'Verify shop one', 'one.example.com') returning id into v_c1;

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_ing1::text, true);

    -- D1. three orders: first (no prior order) with three lines and normalised page, UTM and tags;
    --     repeat (two prior orders); unknown (no count)
    select string_agg(u.source_id || '=' || u.outcome || ':' || u.order_kind, ',' order by u.source_id) into v_txt
    from cma.ingest_upsert_commerce_orders(v_c1, '[
      {"sourceId": "5001", "orderName": "#1001", "customerId": "1001", "createdAt": "2026-10-01T10:00:00Z",
       "processedAt": "2026-10-01T10:00:05Z", "updatedAt": "2026-10-01T10:00:00Z", "currency": "gbp", "totalAmount": "99.90",
       "subtotalAmount": 90, "taxAmount": "9.90", "discountAmount": "0", "refundedAmount": 0, "financialStatus": "PAID",
       "fulfillmentStatus": "UNFULFILLED", "sourceName": "web", "landingHost": "Shop.Example.COM",
       "landingPath": "/products/verify?ref=x#top", "referringHost": "search.example.com",
       "utm": {"source": "verify", "medium": "cpc", "gclid": "dropped", "campaign": 42},
       "tags": [" alpha ", "beta", "alpha", "", 7], "priorOrdersCount": 0, "priorCountExact": true,
       "raw": {"cancel_reason": null},
       "lines": [{"lineId": "l1", "sku": "SKU-1", "productRef": "p1", "variantRef": "v1", "quantity": 1, "unitPrice": "49.95"},
                 {"lineId": "l2", "sku": "SKU-2", "productRef": "p2", "variantRef": "v2", "quantity": 1, "unitPrice": "40.05", "currency": "EUR"},
                 {"lineId": "l3", "sku": "SKU-3", "quantity": 2, "unitPrice": 0}]},
      {"sourceId": "5002", "customerId": "1001", "createdAt": "2026-10-02T10:00:00Z", "updatedAt": "2026-10-02T10:00:00Z",
       "priorOrdersCount": 2, "sourceName": " Web "},
      {"sourceId": "5003", "createdAt": "2026-10-03T10:00:00Z", "updatedAt": "2026-10-03T10:00:00Z", "sourceName": "pos"}]') u;
    select * into r from cma.commerce_order where connection_id = v_c1 and source_id = '5001';
    if v_txt is distinct from '5001=inserted:first,5002=inserted:repeat,5003=inserted:unknown'
       or r.currency <> 'GBP' or r.total_amount <> 99.90 or r.tax_amount <> 9.90 or r.landing_host <> 'shop.example.com'
       or r.landing_path <> '/products/verify' or r.referring_host <> 'search.example.com'
       or r.utm <> '{"source": "verify", "medium": "cpc", "campaign": "42"}'::jsonb or r.tags <> array['alpha', 'beta']
       or not r.prior_count_exact or r.order_name <> '#1001' or r.source_system <> 'verify_shop' or r.is_test or v_provoke then
      raise exception 'FAIL D1: orders gave % and 5001 holds %', v_txt, row_to_json(r);
    end if;
    select string_agg(line_source_id || ':' || coalesce(sku, '∅') || ':' || quantity || ':' || coalesce(unit_price::text, '∅') || ':' || coalesce(currency, '∅'),
                      ',' order by line_source_id) into v_txt
    from cma.commerce_order_line where connection_id = v_c1 and order_source_id = '5001';
    if v_txt is distinct from 'l1:SKU-1:1:49.95:GBP,l2:SKU-2:1:40.05:EUR,l3:SKU-3:2:0.00:GBP' then
      raise exception 'FAIL D1: the lines of 5001 are %', v_txt;
    end if;

    -- D2. lines replaced as a set: l1 changed, l2 kept, l3 gone, l4 new; an update without lines
    --     keeps them; the newer read replaces the order's values
    perform cma.ingest_upsert_commerce_orders(v_c1, '[
      {"sourceId": "5001", "customerId": "1001", "createdAt": "2026-10-01T10:00:00Z", "updatedAt": "2026-10-01T11:00:00Z",
       "currency": "GBP", "totalAmount": "120", "refundedAmount": "10", "financialStatus": "PARTIALLY_REFUNDED", "sourceName": "web",
       "priorOrdersCount": 0, "priorCountExact": true,
       "lines": [{"lineId": "l1", "sku": "SKU-1", "productRef": "p1", "variantRef": "v1", "quantity": 2, "unitPrice": "49.95"},
                 {"lineId": "l2", "sku": "SKU-2", "productRef": "p2", "variantRef": "v2", "quantity": 1, "unitPrice": "40.05", "currency": "EUR"},
                 {"lineId": "l4", "sku": "SKU-4", "quantity": 1, "unitPrice": "20.10"}]}]');
    perform cma.ingest_upsert_commerce_orders(v_c1, '[
      {"sourceId": "5001", "customerId": "1001", "createdAt": "2026-10-01T10:00:00Z", "updatedAt": "2026-10-01T12:00:00Z",
       "currency": "GBP", "totalAmount": "120", "refundedAmount": "10", "financialStatus": "PARTIALLY_REFUNDED",
       "fulfillmentStatus": "FULFILLED", "sourceName": "web", "priorOrdersCount": 0, "priorCountExact": true}]');
    select string_agg(line_source_id || ':' || quantity, ',' order by line_source_id) into v_txt
    from cma.commerce_order_line where connection_id = v_c1 and order_source_id = '5001';
    select * into r from cma.commerce_order where connection_id = v_c1 and source_id = '5001';
    if v_txt is distinct from 'l1:2,l2:1,l4:1' or r.total_amount <> 120 or r.refunded_amount <> 10 or r.fulfillment_status <> 'FULFILLED'
       or r.landing_host is not null or r.tags <> '{}' or r.source_created_at <> '2026-10-01T10:00:00Z'::timestamptz then
      raise exception 'FAIL D2: lines % and order %', v_txt, row_to_json(r);
    end if;

    -- D3. an older read is stale and leaves the order and its lines alone, even when it carries lines
    select string_agg(u.outcome || ':' || u.order_kind, ',') into v_txt
    from cma.ingest_upsert_commerce_orders(v_c1, '[
      {"sourceId": "5001", "createdAt": "2026-10-01T10:00:00Z", "updatedAt": "2026-10-01T10:30:00Z", "totalAmount": "1",
       "priorOrdersCount": 5, "lines": [{"lineId": "l9", "quantity": 1}]}]') u;
    if v_txt is distinct from 'stale:first' or (select total_amount from cma.commerce_order where connection_id = v_c1 and source_id = '5001') <> 120
       or (select count(*) from cma.commerce_order_line where connection_id = v_c1 and order_source_id = '5001') <> 3 then
      raise exception 'FAIL D3: an older read gave %', v_txt;
    end if;

    -- D4. renewal from the source-name setting: setting it reclassifies the stored orders at once
    --     (5001 web and 5002 " Web " → renewal, matched without case and spaces), and new orders
    --     with that name are renewals whatever their count
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_tenant_setting('commerce.renewal_source_names', ' WEB , verify-subscriptions');
    select string_agg(source_id || ':' || order_kind, ',' order by source_id) into v_txt from cma.commerce_order where connection_id = v_c1;
    if v_txt is distinct from '5001:renewal,5002:renewal,5003:unknown' then
      raise exception 'FAIL D4: after the source-name setting the kinds are %', v_txt;
    end if;
    perform set_config('app.user_id', v_ing1::text, true);
    select string_agg(u.order_kind, ',') into v_txt
    from cma.ingest_upsert_commerce_orders(v_c1, '[{"sourceId": "5004", "createdAt": "2026-10-04T10:00:00Z", "updatedAt": "2026-10-04T10:00:00Z",
                                                   "sourceName": "verify-subscriptions", "priorOrdersCount": 0}]') u;
    if v_txt is distinct from 'renewal' then
      raise exception 'FAIL D4: a new order with a renewal source name is %', v_txt;
    end if;

    -- D5. renewal from the app-id setting, and back: resetting both settings to the default
    --     reclassifies to first, repeat and unknown
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_tenant_setting('commerce.renewal_source_names', null);
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_commerce_orders(v_c1, '[{"sourceId": "5005", "createdAt": "2026-10-05T10:00:00Z", "updatedAt": "2026-10-05T10:00:00Z",
                                                     "sourceName": "subscription_contract", "appRef": "8888", "priorOrdersCount": 3}]');
    select string_agg(source_id || ':' || order_kind, ',' order by source_id) into v_txt from cma.commerce_order where connection_id = v_c1;
    if v_txt is distinct from '5001:first,5002:repeat,5003:unknown,5004:first,5005:repeat' then
      raise exception 'FAIL D5: after resetting the source names the kinds are %', v_txt;
    end if;
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_tenant_setting('commerce.renewal_app_ids', '7777, 8888');
    if (select order_kind from cma.commerce_order where connection_id = v_c1 and source_id = '5005') <> 'renewal'
       or (select count(*) from cma.commerce_order where connection_id = v_c1 and order_kind = 'renewal') <> 1 then
      raise exception 'FAIL D5: the app-id setting did not make 5005 (alone) a renewal';
    end if;
    perform cma.set_tenant_setting('commerce.renewal_app_ids', '7777');
    if (select order_kind from cma.commerce_order where connection_id = v_c1 and source_id = '5005') <> 'repeat' then
      raise exception 'FAIL D5: changing the app ids did not reclassify 5005';
    end if;

    -- D6. reclassify_orders(): kinds out of step (written directly) are put right, and it answers the
    --     number it changed; a second run changes nothing
    update cma.commerce_order set order_kind = 'unknown' where connection_id = v_c1 and source_id in ('5001', '5002');
    v_n := cma.reclassify_orders();
    if v_n <> 2 or cma.reclassify_orders() <> 0
       or (select string_agg(order_kind, ',' order by source_id) from cma.commerce_order where source_id in ('5001', '5002')) <> 'first,repeat' then
      raise exception 'FAIL D6: reclassify_orders changed % orders', v_n;
    end if;

    -- D7. test and cancelled orders are kept and flagged; their kind is computed like any other
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_commerce_orders(v_c1, '[
      {"sourceId": "5006", "createdAt": "2026-10-06T10:00:00Z", "updatedAt": "2026-10-06T10:00:00Z", "isTest": true, "priorOrdersCount": 0},
      {"sourceId": "5007", "createdAt": "2026-10-06T11:00:00Z", "updatedAt": "2026-10-06T12:00:00Z", "cancelledAt": "2026-10-06T12:00:00Z",
       "cancelReason": "CUSTOMER", "financialStatus": "VOIDED", "priorOrdersCount": 1}]');
    select string_agg(source_id || ':' || is_test || ':' || coalesce(cancel_reason, '∅') || ':' || (cancelled_at is not null) || ':' || order_kind,
                      ',' order by source_id) into v_txt
    from cma.commerce_order where connection_id = v_c1 and source_id in ('5006', '5007');
    if v_txt is distinct from '5006:true:∅:false:first,5007:false:CUSTOMER:true:repeat' then
      raise exception 'FAIL D7: test and cancelled orders are %', v_txt;
    end if;

    -- D8. a deletion keeps ids, times, amounts, kind and lines and clears page, UTM, tags and raw; a
    --     read not newer than the deletion is stale; an unknown deletion writes nothing
    perform cma.ingest_upsert_commerce_orders(v_c1, '[
      {"sourceId": "5003", "createdAt": "2026-10-03T10:00:00Z", "updatedAt": "2026-10-03T11:00:00Z", "totalAmount": 15,
       "landingHost": "shop.example.com", "landingPath": "/", "utm": {"source": "verify"}, "tags": ["gamma"], "raw": {"x": 1},
       "lines": [{"lineId": "l1", "quantity": 1}]}]');
    select string_agg(u.outcome, ',' order by u.source_id) into v_txt
    from cma.ingest_upsert_commerce_orders(v_c1, '[{"sourceId": "5003", "deletedAt": "2026-10-03T12:00:00Z"},
                                                   {"sourceId": "5999", "deletedAt": "2026-10-03T12:00:00Z"}]') u;
    select * into r from cma.commerce_order where connection_id = v_c1 and source_id = '5003';
    if v_txt is distinct from 'deleted,unknown' or r.source_deleted_at is null or r.landing_host is not null or r.landing_path is not null
       or r.utm <> '{}'::jsonb or r.tags <> '{}' or r.raw <> '{}'::jsonb or r.total_amount <> 15 or r.order_kind <> 'unknown'
       or (select count(*) from cma.commerce_order_line where connection_id = v_c1 and order_source_id = '5003') <> 1
       or exists (select 1 from cma.commerce_order where source_id = '5999') then
      raise exception 'FAIL D8: deletion gave % and left %', v_txt, row_to_json(r);
    end if;
    select string_agg(u.outcome, ',') into v_txt
    from cma.ingest_upsert_commerce_orders(v_c1, '[{"sourceId": "5003", "createdAt": "2026-10-03T10:00:00Z", "updatedAt": "2026-10-03T12:00:00Z",
                                                   "landingHost": "shop.example.com"}]') u;
    if v_txt is distinct from 'stale' or (select landing_host from cma.commerce_order where connection_id = v_c1 and source_id = '5003') is not null then
      raise exception 'FAIL D8: a read at the deletion time gave %', v_txt;
    end if;

    -- D9. tags kept to 30 distinct of at most 60 characters; a host that is not a host is dropped
    perform cma.ingest_upsert_commerce_orders(v_c1, jsonb_build_array(jsonb_build_object(
      'sourceId', '5008', 'createdAt', '2026-10-07T10:00:00Z', 'updatedAt', '2026-10-07T10:00:00Z', 'landingHost', 'not a host/',
      'tags', (select jsonb_agg('verify-tag-' || g) from generate_series(1, 35) g) || jsonb_build_array(repeat('x', 70)))));
    select * into r from cma.commerce_order where connection_id = v_c1 and source_id = '5008';
    if cardinality(r.tags) <> 30 or r.tags[1] <> 'verify-tag-1' or r.tags[30] <> 'verify-tag-30' or r.landing_host is not null then
      raise exception 'FAIL D9: tags % and host %', cardinality(r.tags), r.landing_host;
    end if;
    perform cma.ingest_upsert_commerce_orders(v_c1, jsonb_build_array(jsonb_build_object(
      'sourceId', '5009', 'createdAt', '2026-10-07T10:00:00Z', 'tags', jsonb_build_array(repeat('y', 70)))));
    if (select tags[1] from cma.commerce_order where connection_id = v_c1 and source_id = '5009') <> repeat('y', 60) then
      raise exception 'FAIL D9: a long tag was not cut to 60 characters';
    end if;

    -- D10. refusals (CMA04), nothing written: no createdAt on a new order, a line without an id, a
    --      line twice, lines or UTM or tags of the wrong type, a negative count or quantity, an order
    --      name over 40 characters, isTest not a boolean, more than 500 orders or lines
    foreach v_txt in array array[
      '[{"sourceId": "5100"}]',
      '[{"sourceId": "5101", "createdAt": "2026-10-08T10:00:00Z", "lines": [{"sku": "x"}]}]',
      '[{"sourceId": "5102", "createdAt": "2026-10-08T10:00:00Z", "lines": [{"lineId": "a"}, {"lineId": "a"}]}]',
      '[{"sourceId": "5103", "createdAt": "2026-10-08T10:00:00Z", "lines": {"lineId": "a"}}]',
      '[{"sourceId": "5104", "createdAt": "2026-10-08T10:00:00Z", "utm": "source=x"}]',
      '[{"sourceId": "5105", "createdAt": "2026-10-08T10:00:00Z", "tags": "a, b"}]',
      '[{"sourceId": "5106", "createdAt": "2026-10-08T10:00:00Z", "priorOrdersCount": -1}]',
      '[{"sourceId": "5107", "createdAt": "2026-10-08T10:00:00Z", "lines": [{"lineId": "a", "quantity": -1}]}]',
      '[{"sourceId": "5108", "createdAt": "2026-10-08T10:00:00Z", "orderName": "' || repeat('9', 41) || '"}]',
      '[{"sourceId": "5109", "createdAt": "2026-10-08T10:00:00Z", "isTest": "perhaps"}]',
      (select jsonb_agg(jsonb_build_object('sourceId', g::text, 'createdAt', '2026-10-08T10:00:00Z'))::text from generate_series(1, 501) g),
      (select jsonb_build_array(jsonb_build_object('sourceId', '5110', 'createdAt', '2026-10-08T10:00:00Z',
                                                   'lines', jsonb_agg(jsonb_build_object('lineId', g::text))))::text
       from generate_series(1, 501) g)
    ] loop
      begin
        perform cma.ingest_upsert_commerce_orders(v_c1, v_txt::jsonb);
        raise exception 'FAIL D10: % was accepted', left(v_txt, 80);
      exception when sqlstate 'CMA04' then null;
      end;
    end loop;
    if exists (select 1 from cma.commerce_order where connection_id = v_c1 and source_id like '51%') then
      raise exception 'FAIL D10: a refused order was written';
    end if;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- E. Permissions and tenant isolation (throwaway tenants, rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_t1       uuid;
  v_t2       uuid;
  v_admin    uuid;
  v_agent    uuid;
  v_admin2   uuid;
  v_ing1     uuid;
  v_ing2     uuid;
  v_who      uuid;
  v_c1       uuid;
  v_c2       uuid;
  v_t        text;
  v_n        bigint;
  v_txt      text;
begin
  begin
    v_t1 := cma.create_tenant('verify-0007b-one', 'Verify 0007b one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0007b-two', 'Verify 0007b two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'Verify admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent@example.invalid', 'Verify agent') returning id into v_agent;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin@example.invalid', 'Verify admin two') returning id into v_admin2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin, 'admin'), (v_t1, v_agent, 'agent'), (v_t2, v_admin2, 'admin')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select id into v_ing1 from cma.app_user where tenant_id = v_t1 and email = 'ingest@system.invalid';
    select id into v_ing2 from cma.app_user where tenant_id = v_t2 and email = 'ingest@system.invalid';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t1, 'verify_shop', 'Verify shop one', 'one.example.com') returning id into v_c1;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t2, 'verify_shop', 'Verify shop two', 'two.example.com') returning id into v_c2;

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);

    -- E1. the Ingest user cannot configure; a configuring person cannot write as the ingest; an agent
    --     can do neither
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP');
    perform set_config('app.user_id', v_ing1::text, true);
    foreach v_txt in array array[
      format('select cma.upsert_commerce_store(%L, ''verify-gb'', ''Verify GB'', ''GB'', ''GBP'', ''Europe/London'')', v_c1),
      'select cma.reclassify_orders()',
      'select cma.set_tenant_setting(''commerce.renewal_app_ids'', ''1'')'
    ] loop
      begin
        execute v_txt;
        raise exception 'FAIL E1: the Ingest user ran %', v_txt;
      exception when sqlstate 'CMA06' then null;
      end;
    end loop;
    if v_provoke then
      raise exception 'FAIL E1: provoked';
    end if;
    foreach v_who in array array[v_admin, v_agent] loop
      perform set_config('app.user_id', v_who::text, true);
      foreach v_txt in array array[
        format('select cma.ingest_upsert_commerce_customers(%L, ''[]'')', v_c1),
        format('select cma.ingest_upsert_commerce_orders(%L, ''[]'')', v_c1)
      ] loop
        begin
          execute v_txt;
          raise exception 'FAIL E1: a person ran %', v_txt;
        exception when sqlstate 'CMA06' then null;
        end;
      end loop;
    end loop;
    foreach v_txt in array array[
      format('select cma.upsert_commerce_store(%L, ''verify-gb'', ''Verify GB'', ''GB'', ''GBP'', ''Europe/London'')', v_c1),
      'select cma.reclassify_orders()',
      format('select cma.connection_config(%L)', v_c1)
    ] loop
      begin
        execute v_txt;
        raise exception 'FAIL E1: an agent ran %', v_txt;
      exception when sqlstate 'CMA06' then null;
      end;
    end loop;

    -- E2. tenant one fills every new table
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.upsert_commerce_store(v_c1, 'verify-gb', 'Verify GB', 'GB', 'GBP', 'Europe/London');
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_commerce_customers(v_c1, '[{"sourceId": "1001", "updatedAt": "2026-10-01T09:00:00Z"}]');
    perform cma.ingest_upsert_commerce_orders(v_c1, '[{"sourceId": "5001", "createdAt": "2026-10-01T10:00:00Z", "sourceName": "web",
                                                     "priorOrdersCount": 0, "lines": [{"lineId": "l1", "quantity": 1}]}]');

    -- E3. tenant two sees none of it, cannot write to tenant one's connection or configure its store;
    --     it may use the same handle; its setting change leaves tenant one's orders alone
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_ing2::text, true);
    foreach v_t in array array['commerce_store', 'commerce_customer', 'commerce_order', 'commerce_order_line'] loop
      execute format('select count(*) from cma.%I', v_t) into v_n;
      if v_n <> 0 then
        raise exception 'FAIL E3: tenant two sees % row(s) of tenant one in cma.%', v_n, v_t;
      end if;
    end loop;
    foreach v_txt in array array[
      format('select cma.ingest_upsert_commerce_customers(%L, ''[]'')', v_c1),
      format('select cma.ingest_upsert_commerce_orders(%L, ''[]'')', v_c1),
      format('select cma.connection_config(%L)', v_c1)
    ] loop
      begin
        execute v_txt;
        raise exception 'FAIL E3: tenant two ran %', v_txt;
      exception when sqlstate 'CMA02' then null;
      end;
    end loop;
    perform set_config('app.user_id', v_admin2::text, true);
    perform cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP');
    begin
      perform cma.upsert_commerce_store(v_c1, 'verify-gb-2', 'Verify GB', 'GB', 'GBP', 'Europe/London');
      raise exception 'FAIL E3: tenant two configured tenant one''s store';
    exception when sqlstate 'CMA02' then null;
    end;
    perform cma.upsert_commerce_store(v_c2, 'verify-gb', 'Verify GB', 'GB', 'GBP', 'Europe/London');
    perform cma.set_tenant_setting('commerce.renewal_source_names', 'web');
    if cma.reclassify_orders() <> 0 then
      raise exception 'FAIL E3: tenant two reclassified orders it cannot see';
    end if;
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    if (select order_kind from cma.commerce_order where connection_id = v_c1 and source_id = '5001') <> 'first'
       or (select count(*) from cma.commerce_store) <> 1 then
      raise exception 'FAIL E3: tenant two''s setting or store reached tenant one';
    end if;

    -- E4. no deletes on stores, customers and orders
    foreach v_t in array array['commerce_store', 'commerce_customer', 'commerce_order'] loop
      begin
        execute format('delete from cma.%I', v_t);
        raise exception 'FAIL E4: the application deleted from cma.%', v_t;
      exception when insufficient_privilege then null;
      end;
    end loop;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- Verdict: per tenant, the stores and what has arrived so far
select t.slug as tenant,
       (select count(*) from cma.commerce_store s where s.tenant_id = t.id) as stores,
       (select count(*) from cma.commerce_customer c where c.tenant_id = t.id) as customers,
       (select count(*) from cma.commerce_order o where o.tenant_id = t.id) as orders,
       (select count(*) from cma.commerce_order_line l where l.tenant_id = t.id) as order_lines,
       case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS' else 'PASS' end as verdict
from cma.tenant t
where t.status = 'active'
order by t.slug;
