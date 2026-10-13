-- =============================================================================================
-- 56_commerce_phone_hash.sql: addition 0008g, the keyed hash of the phone number on commerce
-- customers and orders
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 54_uncounted_lines.sql (0008f). Rerunnable, forward-only, in one transaction. Run as your own IAM
-- login, dev first, then prod; then 57_verify_commerce_phone_hash.sql (dev), then
-- 37_verify_commerce.sql, 33_verify_intake_core.sql and 31_verify_ingest_crm_records.sql again
-- (unchanged).
--
-- Why (README Decision log, 13 October 2026): people request information with one email address
-- and order with another, so an order is matched to earlier calls by its phone number when indirect
-- sales are measured. The number itself is never stored: the ingest service turns it into the same
-- keyed hash as a call's other party (HMAC-SHA256 with the tenant's pepper over the E.164 number,
-- the store's market as the default region; DESIGN §6.3) and drops it. Agreed by Yordi on
-- 13 October 2026.
--
-- What it does
--   columns            cma.commerce_customer.phone_hash and cma.commerce_order.phone_hash: 64
--                      lower-case hex characters or null, each with a partial index on
--                      (tenant_id, phone_hash) where it is not null, the shape and index of
--                      crm_call.counterpart_hash and telephony_call.counterpart_hash
--   customers          cma.ingest_upsert_commerce_customers() as in 0007b, plus the item key
--                      phoneHash: stored as given (trimmed, lower case), refused (CMA04) when it is
--                      not 64 hex characters, so a plain number never lands; a read without it
--                      clears the hash (the store withheld or removed the phone: the read is the
--                      current state). A deletion clears the customer's hash and the hashes of its
--                      orders in the same connection
--   orders             cma.ingest_upsert_commerce_orders() as in 0007b, plus the item key phoneHash
--                      with the same rules; a deletion clears the order's hash
--   nothing else       no other personal value is added; the reporting views of 0007b are unchanged
--                      and leave both hashes out (as they leave out counterpart_hash)
--
-- Retention: the hash follows the tenant's retention for call data (1 year, as the call hashes it
-- is compared with). No retention job exists yet for any of them (README, Open decisions); when it
-- is built it covers these two columns with the call hashes.
--
-- SQLSTATEs as before: CMA01 no acting user, CMA02 not found, CMA03 conflict, CMA04 invalid,
-- CMA06 not permitted.
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
set role cma_owner;

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0008f') then
    raise exception 'addition 0008f (54_uncounted_lines.sql) must run before 0008g';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The columns and their indexes
-- ---------------------------------------------------------------------------------------------
alter table cma.commerce_customer
  add column if not exists phone_hash text constraint commerce_customer_phone_hash_check check (phone_hash ~ '^[0-9a-f]{64}$');
alter table cma.commerce_order
  add column if not exists phone_hash text constraint commerce_order_phone_hash_check check (phone_hash ~ '^[0-9a-f]{64}$');
comment on column cma.commerce_customer.phone_hash is 'HMAC-SHA256(tenant pepper, E.164 phone number of the customer) in hex, made by the ingest service with the store''s market as the default region; never the number. For matching orders to earlier calls; kept as long as call data';
comment on column cma.commerce_order.phone_hash is 'HMAC-SHA256(tenant pepper, E.164 phone number of the order, else of its customer) in hex, made by the ingest service with the store''s market as the default region; never the number. For matching the order to earlier calls; kept as long as call data';
create index if not exists commerce_customer_phone_hash_idx on cma.commerce_customer (tenant_id, phone_hash) where phone_hash is not null;
create index if not exists commerce_order_phone_hash_idx on cma.commerce_order (tenant_id, phone_hash) where phone_hash is not null;

-- ---------------------------------------------------------------------------------------------
-- 2. Customers: 0007b's upsert, plus phoneHash
-- ---------------------------------------------------------------------------------------------
-- Upserts customers as the store answered them: [{sourceId, state, locale, ordersCount, amountSpent,
-- currency, createdAt, updatedAt, phoneHash?, deletedAt?, raw?}], at most 500. Older reads are
-- stale, and so is a read not newer than the customer's deletion. phoneHash is the keyed hash of the
-- customer's phone (64 hex characters, lower-cased here; anything else is refused); a read without
-- it clears the stored hash. A deletion keeps the id and times and clears state, locale, counts,
-- amounts, the hash, the raw payload and the hashes of the customer's orders in this connection.
-- Outcomes: inserted, updated, stale, deleted, unknown.
create or replace function cma.ingest_upsert_commerce_customers(p_connection_id uuid, p_items jsonb)
returns table (source_id text, outcome text)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant   uuid := cma.current_tenant_id();
  v_system   text;
  c          jsonb;
  v_src      text;
  v_updated  timestamptz;
  v_deleted  timestamptz;
  v_hash     text;
  v_old      cma.commerce_customer;
begin
  perform cma.assert_permission('ingest.write');
  v_system := cma.active_connection_adapter(p_connection_id);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then
    raise exception 'customers must be an array of at most 500' using errcode = 'CMA04';
  end if;
  for c in select value from jsonb_array_elements(p_items) loop
    v_src := btrim(c ->> 'sourceId');
    if coalesce(v_src, '') = '' then
      raise exception 'every customer needs a sourceId' using errcode = 'CMA04';
    end if;
    if (c -> 'phoneHash') is not null and jsonb_typeof(c -> 'phoneHash') not in ('string', 'null') then
      raise exception 'phoneHash must be a text' using errcode = 'CMA04';
    end if;
    v_hash := nullif(lower(btrim(c ->> 'phoneHash')), '');
    v_updated := cma.json_time(c -> 'updatedAt', 'updatedAt');
    v_deleted := cma.json_time(c -> 'deletedAt', 'deletedAt');
    select * into v_old from cma.commerce_customer cc
    where cc.tenant_id = v_tenant and cc.connection_id = p_connection_id and cc.source_id = v_src
    for update;

    if v_deleted is not null then
      if v_old.id is null then
        return query select v_src, 'unknown'::text;
      else
        update cma.commerce_customer cc
           set state = null, locale = null, orders_count = null, amount_spent = null, amount_currency = null,
               phone_hash = null, raw = '{}'::jsonb, source_deleted_at = coalesce(cc.source_deleted_at, v_deleted), synced_at = now()
         where cc.tenant_id = v_tenant and cc.id = v_old.id;
        update cma.commerce_order co
           set phone_hash = null, synced_at = now()
         where co.tenant_id = v_tenant and co.connection_id = p_connection_id and co.customer_source_id = v_src
           and co.phone_hash is not null;
        return query select v_src, 'deleted'::text;
      end if;
      continue;
    end if;

    if v_old.id is not null
       and ((v_old.source_updated_at is not null and (v_updated is null or v_updated < v_old.source_updated_at))
         or (v_old.source_deleted_at is not null and (v_updated is null or v_updated <= v_old.source_deleted_at))) then
      return query select v_src, 'stale'::text;
      continue;
    end if;

    if v_old.id is null then
      insert into cma.commerce_customer (tenant_id, connection_id, source_system, source_id, state, locale, orders_count,
                                         amount_spent, amount_currency, source_created_at, source_updated_at, phone_hash, raw)
      values (v_tenant, p_connection_id, v_system, v_src, nullif(btrim(c ->> 'state'), ''), nullif(btrim(c ->> 'locale'), ''),
              (c ->> 'ordersCount')::integer, cma.json_amount(c -> 'amountSpent'), cma.json_currency(c ->> 'currency'),
              cma.json_time(c -> 'createdAt', 'createdAt'), v_updated, v_hash, coalesce(c -> 'raw', '{}'::jsonb));
      return query select v_src, 'inserted'::text;
    else
      update cma.commerce_customer cc
         set state = nullif(btrim(c ->> 'state'), ''),
             locale = nullif(btrim(c ->> 'locale'), ''),
             orders_count = (c ->> 'ordersCount')::integer,
             amount_spent = cma.json_amount(c -> 'amountSpent'),
             amount_currency = cma.json_currency(c ->> 'currency'),
             source_created_at = coalesce(cma.json_time(c -> 'createdAt', 'createdAt'), cc.source_created_at),
             source_updated_at = v_updated,
             source_deleted_at = null,
             phone_hash = v_hash,
             synced_at = now(),
             raw = coalesce(c -> 'raw', '{}'::jsonb)
       where cc.tenant_id = v_tenant and cc.id = v_old.id;
      return query select v_src, 'updated'::text;
    end if;
  end loop;
exception
  when check_violation or not_null_violation or invalid_text_representation or numeric_value_out_of_range then
    raise exception 'invalid customer: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. Orders: 0007b's upsert, plus phoneHash
-- ---------------------------------------------------------------------------------------------
-- Upserts orders as the store answered them, at most 500:
--   [{sourceId, orderName, customerId, createdAt, processedAt, updatedAt, cancelledAt, cancelReason,
--     isTest, currency, totalAmount, subtotalAmount, taxAmount, discountAmount, refundedAmount,
--     financialStatus, fulfillmentStatus, sourceName, appRef, landingHost, landingPath, utm,
--     referringHost, tags, priorOrdersCount, priorCountExact, phoneHash?, deletedAt?, raw?,
--     lines?: [{lineId, sku, productRef, variantRef, quantity, unitPrice, currency}]}]
-- As in 0007b, plus phoneHash: the keyed hash of the order's phone, else its customer's (64 hex
-- characters, lower-cased here; anything else is refused); a read without it clears the stored hash,
-- and a deletion clears it with the pages, UTM, tags and raw payload.
-- Outcomes: inserted, updated, stale, deleted, unknown; with the order's kind.
create or replace function cma.ingest_upsert_commerce_orders(p_connection_id uuid, p_items jsonb)
returns table (source_id text, outcome text, order_kind text)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant    uuid := cma.current_tenant_id();
  v_system    text;
  o           jsonb;
  v_src       text;
  v_created   timestamptz;
  v_updated   timestamptz;
  v_deleted   timestamptz;
  v_old       cma.commerce_order;
  v_names     text[];
  v_apps      text[];
  v_prior     integer;
  v_kind      text;
  v_currency  text;
  v_lhost     text;
  v_rhost     text;
  v_lpath     text;
  v_utm       jsonb;
  v_tags      text[];
  v_line_ids  text[];
  v_hash      text;
begin
  perform cma.assert_permission('ingest.write');
  v_system := cma.active_connection_adapter(p_connection_id);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then
    raise exception 'orders must be an array of at most 500' using errcode = 'CMA04';
  end if;
  select l.names, l.apps into v_names, v_apps from cma.commerce_renewal_lists(v_tenant) l;
  for o in select value from jsonb_array_elements(p_items) loop
    v_src := btrim(o ->> 'sourceId');
    if coalesce(v_src, '') = '' then
      raise exception 'every order needs a sourceId' using errcode = 'CMA04';
    end if;
    if (o -> 'lines') is not null and jsonb_typeof(o -> 'lines') <> 'array' then
      raise exception 'lines must be an array' using errcode = 'CMA04';
    end if;
    if jsonb_typeof(o -> 'lines') = 'array' and jsonb_array_length(o -> 'lines') > 500 then
      raise exception 'an order holds at most 500 lines' using errcode = 'CMA04';
    end if;
    if (o -> 'utm') is not null and jsonb_typeof(o -> 'utm') not in ('object', 'null') then
      raise exception 'utm must be an object' using errcode = 'CMA04';
    end if;
    if (o -> 'tags') is not null and jsonb_typeof(o -> 'tags') not in ('array', 'null') then
      raise exception 'tags must be an array' using errcode = 'CMA04';
    end if;
    if (o -> 'phoneHash') is not null and jsonb_typeof(o -> 'phoneHash') not in ('string', 'null') then
      raise exception 'phoneHash must be a text' using errcode = 'CMA04';
    end if;
    v_hash := nullif(lower(btrim(o ->> 'phoneHash')), '');
    v_updated := cma.json_time(o -> 'updatedAt', 'updatedAt');
    v_deleted := cma.json_time(o -> 'deletedAt', 'deletedAt');
    select * into v_old from cma.commerce_order co
    where co.tenant_id = v_tenant and co.connection_id = p_connection_id and co.source_id = v_src
    for update;

    if v_deleted is not null then
      if v_old.id is null then
        return query select v_src, 'unknown'::text, null::text;
      else
        update cma.commerce_order co
           set landing_host = null, landing_path = null, referring_host = null, utm = '{}'::jsonb, tags = '{}',
               phone_hash = null, raw = '{}'::jsonb, source_deleted_at = coalesce(co.source_deleted_at, v_deleted), synced_at = now()
         where co.tenant_id = v_tenant and co.id = v_old.id;
        return query select v_src, 'deleted'::text, v_old.order_kind;
      end if;
      continue;
    end if;

    if v_old.id is not null
       and ((v_old.source_updated_at is not null and (v_updated is null or v_updated < v_old.source_updated_at))
         or (v_old.source_deleted_at is not null and (v_updated is null or v_updated <= v_old.source_deleted_at))) then
      return query select v_src, 'stale'::text, v_old.order_kind;
      continue;
    end if;

    v_created := coalesce(cma.json_time(o -> 'createdAt', 'createdAt'), v_old.source_created_at);
    if v_created is null then
      raise exception 'order % needs a createdAt', v_src using errcode = 'CMA04';
    end if;
    v_prior := (o ->> 'priorOrdersCount')::integer;
    v_kind := cma.commerce_order_kind(nullif(btrim(o ->> 'sourceName'), ''), nullif(btrim(o ->> 'appRef'), ''), v_prior,
                                      v_names, v_apps);
    v_currency := cma.json_currency(o ->> 'currency');
    v_lhost := lower(nullif(btrim(o ->> 'landingHost'), ''));
    if v_lhost !~ '^[a-z0-9.-]{1,255}$' then
      v_lhost := null;
    end if;
    v_rhost := lower(nullif(btrim(o ->> 'referringHost'), ''));
    if v_rhost !~ '^[a-z0-9.-]{1,255}$' then
      v_rhost := null;
    end if;
    v_lpath := left(nullif(split_part(split_part(btrim(o ->> 'landingPath'), '?', 1), '#', 1), ''), 1000);
    v_utm := coalesce((select jsonb_object_agg(e.key, left(e.value #>> '{}', 200))
                       from jsonb_each(case when jsonb_typeof(o -> 'utm') = 'object' then o -> 'utm' else '{}'::jsonb end) e
                       where e.key in ('source', 'medium', 'campaign', 'term', 'content')
                         and jsonb_typeof(e.value) in ('string', 'number')), '{}'::jsonb);
    select coalesce(array_agg(t.tag order by t.first_at), '{}') into v_tags
    from (select left(btrim(e.value #>> '{}'), 60) as tag, min(e.ord) as first_at
          from jsonb_array_elements(case when jsonb_typeof(o -> 'tags') = 'array' then o -> 'tags' else '[]'::jsonb end)
               with ordinality e(value, ord)
          where jsonb_typeof(e.value) = 'string' and btrim(e.value #>> '{}') <> ''
          group by 1
          order by 2
          limit 30) t;

    if v_old.id is null then
      insert into cma.commerce_order (tenant_id, connection_id, source_system, source_id, order_name, customer_source_id,
                                      source_created_at, processed_at, source_updated_at, cancelled_at, cancel_reason,
                                      is_test, currency, total_amount, subtotal_amount, tax_amount, discount_amount,
                                      refunded_amount, financial_status, fulfillment_status, source_name, app_ref,
                                      landing_host, landing_path, utm, referring_host, tags, prior_orders_count,
                                      prior_count_exact, order_kind, phone_hash, raw)
      values (v_tenant, p_connection_id, v_system, v_src, nullif(btrim(o ->> 'orderName'), ''), nullif(btrim(o ->> 'customerId'), ''),
              v_created, cma.json_time(o -> 'processedAt', 'processedAt'), v_updated,
              cma.json_time(o -> 'cancelledAt', 'cancelledAt'), nullif(btrim(o ->> 'cancelReason'), ''),
              coalesce((o ->> 'isTest')::boolean, false), v_currency,
              cma.json_amount(o -> 'totalAmount'), cma.json_amount(o -> 'subtotalAmount'), cma.json_amount(o -> 'taxAmount'),
              cma.json_amount(o -> 'discountAmount'), cma.json_amount(o -> 'refundedAmount'),
              nullif(btrim(o ->> 'financialStatus'), ''), nullif(btrim(o ->> 'fulfillmentStatus'), ''),
              nullif(btrim(o ->> 'sourceName'), ''), nullif(btrim(o ->> 'appRef'), ''),
              v_lhost, v_lpath, v_utm, v_rhost, v_tags, v_prior, coalesce((o ->> 'priorCountExact')::boolean, false),
              v_kind, v_hash, coalesce(o -> 'raw', '{}'::jsonb));
    else
      update cma.commerce_order co
         set order_name = nullif(btrim(o ->> 'orderName'), ''),
             customer_source_id = nullif(btrim(o ->> 'customerId'), ''),
             source_created_at = v_created,
             processed_at = cma.json_time(o -> 'processedAt', 'processedAt'),
             source_updated_at = v_updated,
             cancelled_at = cma.json_time(o -> 'cancelledAt', 'cancelledAt'),
             cancel_reason = nullif(btrim(o ->> 'cancelReason'), ''),
             is_test = coalesce((o ->> 'isTest')::boolean, false),
             currency = v_currency,
             total_amount = cma.json_amount(o -> 'totalAmount'),
             subtotal_amount = cma.json_amount(o -> 'subtotalAmount'),
             tax_amount = cma.json_amount(o -> 'taxAmount'),
             discount_amount = cma.json_amount(o -> 'discountAmount'),
             refunded_amount = cma.json_amount(o -> 'refundedAmount'),
             financial_status = nullif(btrim(o ->> 'financialStatus'), ''),
             fulfillment_status = nullif(btrim(o ->> 'fulfillmentStatus'), ''),
             source_name = nullif(btrim(o ->> 'sourceName'), ''),
             app_ref = nullif(btrim(o ->> 'appRef'), ''),
             landing_host = v_lhost,
             landing_path = v_lpath,
             utm = v_utm,
             referring_host = v_rhost,
             tags = v_tags,
             prior_orders_count = v_prior,
             prior_count_exact = coalesce((o ->> 'priorCountExact')::boolean, false),
             order_kind = v_kind,
             phone_hash = v_hash,
             source_deleted_at = null,
             synced_at = now(),
             raw = coalesce(o -> 'raw', '{}'::jsonb)
       where co.tenant_id = v_tenant and co.id = v_old.id;
    end if;

    -- the lines, replaced as a set when the order carries them
    if jsonb_typeof(o -> 'lines') = 'array' then
      if exists (select 1 from jsonb_array_elements(o -> 'lines') l
                 where jsonb_typeof(l) <> 'object' or coalesce(btrim(l ->> 'lineId'), '') = '') then
        raise exception 'every line of order % needs a lineId', v_src using errcode = 'CMA04';
      end if;
      select coalesce(array_agg(distinct btrim(l ->> 'lineId')), '{}') into v_line_ids from jsonb_array_elements(o -> 'lines') l;
      if cardinality(v_line_ids) <> jsonb_array_length(o -> 'lines') then
        raise exception 'order % lists a line twice', v_src using errcode = 'CMA04';
      end if;
      delete from cma.commerce_order_line ol
      where ol.tenant_id = v_tenant and ol.connection_id = p_connection_id and ol.order_source_id = v_src
        and not (ol.line_source_id = any (v_line_ids));
      insert into cma.commerce_order_line as ol (tenant_id, connection_id, order_source_id, line_source_id, sku, product_ref,
                                                 variant_ref, quantity, unit_price, currency)
      select v_tenant, p_connection_id, v_src, btrim(l ->> 'lineId'), nullif(btrim(l ->> 'sku'), ''),
             nullif(btrim(l ->> 'productRef'), ''), nullif(btrim(l ->> 'variantRef'), ''),
             coalesce((l ->> 'quantity')::integer, 0), cma.json_amount(l -> 'unitPrice'),
             coalesce(cma.json_currency(l ->> 'currency'), v_currency)
      from jsonb_array_elements(o -> 'lines') l
      on conflict (tenant_id, connection_id, order_source_id, line_source_id) do update
        set sku = excluded.sku, product_ref = excluded.product_ref, variant_ref = excluded.variant_ref,
            quantity = excluded.quantity, unit_price = excluded.unit_price, currency = excluded.currency, synced_at = now()
        where (ol.sku, ol.product_ref, ol.variant_ref, ol.quantity, ol.unit_price, ol.currency)
              is distinct from (excluded.sku, excluded.product_ref, excluded.variant_ref, excluded.quantity,
                                excluded.unit_price, excluded.currency);
    end if;
    return query select v_src, case when v_old.id is null then 'inserted' else 'updated' end, v_kind;
  end loop;
exception
  when check_violation or not_null_violation or invalid_text_representation or numeric_value_out_of_range then
    raise exception 'invalid order: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Grants: the application only, as in 0007b
-- ---------------------------------------------------------------------------------------------
revoke execute on function cma.ingest_upsert_commerce_customers(uuid, jsonb) from public;
grant execute on function cma.ingest_upsert_commerce_customers(uuid, jsonb) to cma_app;
revoke execute on function cma.ingest_upsert_commerce_orders(uuid, jsonb) from public;
grant execute on function cma.ingest_upsert_commerce_orders(uuid, jsonb) to cma_app;

-- ---------------------------------------------------------------------------------------------
-- 5. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008g', 'Commerce phone hash: the keyed hash of the phone number on commerce customers and orders (the call hash''s shape and pepper), accepted by the two upserts as phoneHash, cleared by a read without it and by a deletion; never the number')
on conflict (version) do nothing;

commit;
reset role;
