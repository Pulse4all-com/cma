-- =============================================================================================
-- 36_commerce.sql: migration 0007b, commerce (intake track I4)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 32_intake_core.sql (0007); it does not need 0007a. Rerunnable, forward-only. Run as your own IAM
-- login, dev first, then prod; then 37_verify_commerce.sql, then 33_verify_intake_core.sql and
-- 31_verify_ingest_crm_records.sql again (unchanged).
--
-- Specification: docs/night-2026-10-10/DESIGN.md §4.3 (README Roadmap step 6, intake track;
-- Decision log 10 October 2026).
--
-- What it adds
--   stores             cma.commerce_store: one store per connection, with its handle (the value
--                      the CRM's store field uses), name, market, currency and time zone
--   customers          cma.commerce_customer: ids, state, locale, lifetime order count and amount
--                      spent, source times; a deleted customer keeps its id and times only
--   orders             cma.commerce_order: ids, the shop's order number, the customer id, times,
--                      cancellation, test flag, amounts, statuses, the sales channel and app, the
--                      landing and referring page as host and path, UTM tags, order tags, the
--                      customer's prior order count and order_kind (first, repeat, renewal,
--                      unknown); cma.commerce_order_line: sku, product and variant ids, quantity,
--                      unit price, replaced as a set with its order
--   classification     order_kind is computed in the upsert from the two settings
--                      commerce.renewal_source_names and commerce.renewal_app_ids (0007) and the
--                      prior order count; it is recomputed for the tenant whenever either setting
--                      changes, and on demand by cma.reclassify_orders()
--   the adapter's view cma.connection_config() also answers the connection's store
--
-- Nothing personal is stored (DESIGN §2.1): no names, email addresses, phone numbers or postal
-- addresses of customers, no free-text notes. The ingest service reduces landing and referring URLs
-- to host and path (and UTM tags) before they arrive; the upserts strip a query string again.
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
set role cma_owner;

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0007') then
    raise exception 'migration 0007 (32_intake_core.sql) must run before 0007b';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Stores
-- ---------------------------------------------------------------------------------------------
-- One store per connection (a commerce connection is one shop). The handle is the tenant's own short
-- name for the store, the value its CRM store field holds; unique in the tenant.
create table if not exists cma.commerce_store (
  id             uuid primary key default uuidv7(),
  tenant_id      uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id  uuid not null,
  handle         text not null check (handle ~ '^[a-z0-9-]{1,60}$'),
  name           text not null check (length(btrim(name)) between 1 and 80),
  market         text not null check (market ~ '^[A-Z]{2}$'),
  currency       text not null check (currency ~ '^[A-Z]{3}$'),
  time_zone      text not null check (length(time_zone) between 1 and 64),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, connection_id),
  unique (tenant_id, handle),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.commerce_store is 'One commerce store per connection: handle (the CRM store field''s value), name, market, currency, time zone. Tenant configuration';
create or replace trigger set_updated_at before update on cma.commerce_store
  for each row execute function cma.set_updated_at();

-- ---------------------------------------------------------------------------------------------
-- 2. Customers
-- ---------------------------------------------------------------------------------------------
-- Thin mirror of the store's customers: ids and counts, never a name, email, phone or address.
create table if not exists cma.commerce_customer (
  id                 uuid primary key default uuidv7(),
  tenant_id          uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id      uuid not null,
  source_system      text not null check (source_system ~ '^[a-z0-9_]+$'),
  source_id          text not null check (length(source_id) between 1 and 100),
  state              text check (length(state) <= 30),
  locale             text check (length(locale) <= 20),
  orders_count       integer check (orders_count >= 0),
  amount_spent       numeric(14,2),
  amount_currency    text check (amount_currency ~ '^[A-Z]{3}$'),
  source_created_at  timestamptz,
  source_updated_at  timestamptz,
  source_deleted_at  timestamptz,
  synced_at          timestamptz not null default now(),
  raw                jsonb not null default '{}'::jsonb,
  unique (tenant_id, id),
  unique (tenant_id, connection_id, source_id),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.commerce_customer is 'Thin mirror of a store''s customers: state, locale, lifetime order count and amount spent. No personal data; a deleted customer keeps its id and times. Owned by the store';
create index if not exists commerce_customer_created_idx on cma.commerce_customer (tenant_id, source_created_at);
create index if not exists commerce_customer_source_idx on cma.commerce_customer (tenant_id, source_id);

-- ---------------------------------------------------------------------------------------------
-- 3. Orders and their lines
-- ---------------------------------------------------------------------------------------------
-- Order tags as the store holds them: at most 30, each 1 to 60 characters
create or replace function cma.commerce_tags_ok(p_tags text[])
returns boolean
language sql immutable
as $$
  select p_tags is not null and cardinality(p_tags) <= 30
     and not exists (select 1 from unnest(p_tags) t where t is null or length(t) not between 1 and 60)
$$;
revoke execute on function cma.commerce_tags_ok(text[]) from public;

create table if not exists cma.commerce_order (
  id                  uuid primary key default uuidv7(),
  tenant_id           uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id       uuid not null,
  source_system       text not null check (source_system ~ '^[a-z0-9_]+$'),
  source_id           text not null check (length(source_id) between 1 and 100),
  order_name          text check (length(order_name) <= 40),
  customer_source_id  text check (length(customer_source_id) between 1 and 100),
  source_created_at   timestamptz not null,
  processed_at        timestamptz,
  source_updated_at   timestamptz,
  cancelled_at        timestamptz,
  cancel_reason       text check (length(cancel_reason) <= 40),
  is_test             boolean not null default false,
  currency            text check (currency ~ '^[A-Z]{3}$'),
  total_amount        numeric(14,2),
  subtotal_amount     numeric(14,2),
  tax_amount          numeric(14,2),
  discount_amount     numeric(14,2),
  refunded_amount     numeric(14,2),
  financial_status    text check (length(financial_status) <= 40),
  fulfillment_status  text check (length(fulfillment_status) <= 40),
  source_name         text check (length(source_name) <= 60),
  app_ref             text check (length(app_ref) <= 100),
  landing_host        text check (landing_host ~ '^[a-z0-9.-]{1,255}$'),
  landing_path        text check (length(landing_path) <= 1000 and landing_path !~ '[?#]'),
  utm                 jsonb not null default '{}'::jsonb check (jsonb_typeof(utm) = 'object'),
  referring_host      text check (referring_host ~ '^[a-z0-9.-]{1,255}$'),
  tags                text[] not null default '{}' check (cma.commerce_tags_ok(tags)),
  prior_orders_count  integer check (prior_orders_count >= 0),
  prior_count_exact   boolean not null default false,
  order_kind          text not null default 'unknown' check (order_kind in ('first', 'repeat', 'renewal', 'unknown')),
  source_deleted_at   timestamptz,
  synced_at           timestamptz not null default now(),
  raw                 jsonb not null default '{}'::jsonb,
  unique (tenant_id, id),
  unique (tenant_id, connection_id, source_id),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.commerce_order is 'Thin mirror of a store''s orders: ids, times, amounts, statuses, channel and app, landing and referring page as host and path, UTM, tags, the prior order count and order_kind. Test orders are kept and flagged. Owned by the store';
comment on column cma.commerce_order.prior_orders_count is 'The customer''s orders created before this one at the source, test orders excluded; null when unknown';
comment on column cma.commerce_order.order_kind is 'renewal (source name or app in the renewal settings), else first (no prior order), repeat, or unknown (no count)';
create index if not exists commerce_order_created_idx on cma.commerce_order (tenant_id, source_created_at);
create index if not exists commerce_order_customer_idx on cma.commerce_order (tenant_id, connection_id, customer_source_id);

create table if not exists cma.commerce_order_line (
  tenant_id        uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id    uuid not null,
  order_source_id  text not null,
  line_source_id   text not null check (length(line_source_id) between 1 and 100),
  sku              text check (length(sku) <= 100),
  product_ref      text check (length(product_ref) <= 100),
  variant_ref      text check (length(variant_ref) <= 100),
  quantity         integer not null default 0 check (quantity >= 0),
  unit_price       numeric(14,2),
  currency         text check (currency ~ '^[A-Z]{3}$'),
  synced_at        timestamptz not null default now(),
  primary key (tenant_id, connection_id, order_source_id, line_source_id),
  foreign key (tenant_id, connection_id, order_source_id)
    references cma.commerce_order (tenant_id, connection_id, source_id)
);
comment on table cma.commerce_order_line is 'Lines of an order: sku, product and variant ids, quantity, unit price. Replaced as a set when its order is upserted with lines';

-- ---------------------------------------------------------------------------------------------
-- 4. Row-level security, audit and privileges
-- ---------------------------------------------------------------------------------------------
select cma.setup_tenant_table('cma.commerce_store');
select cma.setup_tenant_table('cma.commerce_customer');
select cma.setup_tenant_table('cma.commerce_order');
select cma.setup_tenant_table('cma.commerce_order_line');

-- The application never deletes stores, customers or orders. Order lines are a child set replaced
-- with their order (as contact refs are with their contact), so the upsert may remove a line the
-- store no longer lists; the audit trigger keeps the removed row.
revoke delete on cma.commerce_store, cma.commerce_customer, cma.commerce_order from cma_app;

-- ---------------------------------------------------------------------------------------------
-- 5. Classification
-- ---------------------------------------------------------------------------------------------
-- The two renewal lists of a tenant from its settings (comma-separated; source names compared in
-- lower case, app ids as written). Takes the tenant explicitly, so the settings trigger also works
-- for a write made without a tenant context (a seed run as the owner).
create or replace function cma.commerce_renewal_lists(p_tenant_id uuid, out names text[], out apps text[])
language sql stable
as $$
  select coalesce((select array_agg(distinct lower(btrim(x)))
                   from unnest(string_to_array(coalesce(ts_n.value, s_n.default_value), ',')) x
                   where btrim(x) <> ''), '{}'),
         coalesce((select array_agg(distinct btrim(x))
                   from unnest(string_to_array(coalesce(ts_a.value, s_a.default_value), ',')) x
                   where btrim(x) <> ''), '{}')
  from cma.setting s_n
  cross join cma.setting s_a
  left join cma.tenant_setting ts_n on ts_n.tenant_id = p_tenant_id and ts_n.key = s_n.key
  left join cma.tenant_setting ts_a on ts_a.tenant_id = p_tenant_id and ts_a.key = s_a.key
  where s_n.key = 'commerce.renewal_source_names' and s_a.key = 'commerce.renewal_app_ids'
$$;
revoke execute on function cma.commerce_renewal_lists(uuid) from public;

-- renewal when the source name or the app is in the renewal lists; else first (no prior order),
-- repeat (prior orders), unknown (no count)
create or replace function cma.commerce_order_kind(p_source_name text, p_app_ref text, p_prior_orders integer,
                                                   p_renewal_names text[], p_renewal_apps text[])
returns text
language sql immutable
as $$
  select case
           when lower(btrim(p_source_name)) = any (coalesce(p_renewal_names, '{}'))
             or btrim(p_app_ref) = any (coalesce(p_renewal_apps, '{}')) then 'renewal'
           when p_prior_orders is null then 'unknown'
           when p_prior_orders = 0 then 'first'
           else 'repeat'
         end
$$;
revoke execute on function cma.commerce_order_kind(text, text, integer, text[], text[]) from public;

-- Recomputes order_kind for every order of one tenant; answers how many changed
create or replace function cma.reclassify_orders_of(p_tenant_id uuid)
returns integer
language plpgsql
as $$
declare
  v_names text[];
  v_apps  text[];
  v_n     integer;
begin
  select l.names, l.apps into v_names, v_apps from cma.commerce_renewal_lists(p_tenant_id) l;
  update cma.commerce_order o
     set order_kind = cma.commerce_order_kind(o.source_name, o.app_ref, o.prior_orders_count, v_names, v_apps)
   where o.tenant_id = p_tenant_id
     and o.order_kind is distinct from cma.commerce_order_kind(o.source_name, o.app_ref, o.prior_orders_count, v_names, v_apps);
  get diagnostics v_n = row_count;
  return v_n;
end
$$;
revoke execute on function cma.reclassify_orders_of(uuid) from public;

-- A change to either renewal setting (set, changed or reset to the default) reclassifies the
-- tenant's orders in the same transaction, whoever writes the setting
create or replace function cma.reclassify_orders_on_setting()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    if old.key in ('commerce.renewal_source_names', 'commerce.renewal_app_ids') then
      perform cma.reclassify_orders_of(old.tenant_id);
    end if;
  elsif new.key in ('commerce.renewal_source_names', 'commerce.renewal_app_ids') then
    perform cma.reclassify_orders_of(new.tenant_id);
  end if;
  return null;
end
$$;
revoke execute on function cma.reclassify_orders_on_setting() from public;
create or replace trigger reclassify_orders after insert or update or delete on cma.tenant_setting
  for each row execute function cma.reclassify_orders_on_setting();

-- ---------------------------------------------------------------------------------------------
-- 6. Configuration (tenant.configure)
-- ---------------------------------------------------------------------------------------------
-- Creates or updates the store of a connection (one per connection); answers its id. The handle
-- is lower case, digits and hyphens and unique in the tenant; the market must be in the catalog;
-- the zone must be one Postgres knows.
create or replace function cma.upsert_commerce_store(p_connection_id uuid, p_handle text, p_name text, p_market text,
                                                     p_currency text, p_time_zone text)
returns uuid
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_id     uuid;
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  if coalesce(p_handle, '') !~ '^[a-z0-9-]{1,60}$' then
    raise exception 'a store handle is 1 to 60 lower-case letters, digits or hyphens, got %', p_handle using errcode = 'CMA04';
  end if;
  if coalesce(btrim(p_name), '') = '' or length(btrim(p_name)) > 80 then
    raise exception 'a store name is 1 to 80 characters' using errcode = 'CMA04';
  end if;
  perform cma.assert_market(p_market, false);
  if coalesce(p_currency, '') !~ '^[A-Z]{3}$' then
    raise exception 'a currency is three upper-case letters (ISO 4217), got %', p_currency using errcode = 'CMA04';
  end if;
  if p_time_zone is null or not exists (select 1 from pg_timezone_names z where z.name = p_time_zone) then
    raise exception '% is not a time zone Postgres knows', p_time_zone using errcode = 'CMA04';
  end if;
  if exists (select 1 from cma.commerce_store s
             where s.tenant_id = v_tenant and s.handle = p_handle and s.connection_id <> p_connection_id) then
    raise exception 'the handle % belongs to another store of the current tenant', p_handle using errcode = 'CMA03';
  end if;
  insert into cma.commerce_store (tenant_id, connection_id, handle, name, market, currency, time_zone)
  values (v_tenant, p_connection_id, p_handle, btrim(p_name), p_market, p_currency, p_time_zone)
  on conflict (tenant_id, connection_id) do update
    set handle = excluded.handle, name = excluded.name, market = excluded.market,
        currency = excluded.currency, time_zone = excluded.time_zone
  returning id into v_id;
  return v_id;
end
$$;

-- Recomputes order_kind for the current tenant's orders (after a settings change the trigger does
-- this already; this is the explicit rerun). Answers how many orders changed kind.
create or replace function cma.reclassify_orders()
returns integer
language plpgsql
as $$
begin
  perform cma.assert_permission('tenant.configure');
  return cma.reclassify_orders_of(cma.current_tenant_id());
end
$$;

-- 0007's connection_config, plus the connection's store: {..., store: {handle, name, market,
-- currency, timeZone} | null}
create or replace function cma.connection_config(p_connection_id uuid)
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['ingest.write', 'tenant.configure']);
  if not exists (select 1 from cma.integration_connection c where c.tenant_id = v_tenant and c.id = p_connection_id) then
    raise exception 'no connection % in the current tenant', p_connection_id using errcode = 'CMA02';
  end if;
  return jsonb_build_object(
    'fields', coalesce((select jsonb_agg(jsonb_build_object('entity', f.entity, 'field', f.field,
                                                             'refSystem', nullif(f.ref_system, ''), 'slot', f.slot,
                                                             'property', f.source_property)
                                         order by f.entity, f.field, f.ref_system, f.slot)
                        from cma.connection_field f where f.tenant_id = v_tenant and f.connection_id = p_connection_id), '[]'::jsonb),
    'pipelines', coalesce((select jsonb_agg(jsonb_build_object('recordType', p.record_type, 'pipelineId', p.source_pipeline_id,
                                                                'label', p.label, 'isCounted', p.is_counted, 'isRouted', p.is_routed,
                                                                'isLead', p.is_lead, 'workType', s.key, 'status', p.status)
                                            order by p.record_type, p.label, p.source_pipeline_id)
                           from cma.connection_pipeline p
                           left join cma.skill s on s.tenant_id = p.tenant_id and s.id = p.work_type_skill_id
                           where p.tenant_id = v_tenant and p.connection_id = p_connection_id), '[]'::jsonb),
    'settings', (select c.settings from cma.integration_connection c where c.tenant_id = v_tenant and c.id = p_connection_id),
    'store', (select jsonb_build_object('handle', s.handle, 'name', s.name, 'market', s.market, 'currency', s.currency,
                                        'timeZone', s.time_zone)
              from cma.commerce_store s where s.tenant_id = v_tenant and s.connection_id = p_connection_id));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. The ingest write path (ingest.write)
-- ---------------------------------------------------------------------------------------------
-- Upserts customers as the store answered them: [{sourceId, state, locale, ordersCount, amountSpent,
-- currency, createdAt, updatedAt, deletedAt?, raw?}], at most 500. Older reads are stale, and so is a
-- read not newer than the customer's deletion. A deletion keeps the id and times and clears state,
-- locale, counts, amounts and the raw payload. Outcomes: inserted, updated, stale, deleted, unknown.
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
               raw = '{}'::jsonb, source_deleted_at = coalesce(cc.source_deleted_at, v_deleted), synced_at = now()
         where cc.tenant_id = v_tenant and cc.id = v_old.id;
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
                                         amount_spent, amount_currency, source_created_at, source_updated_at, raw)
      values (v_tenant, p_connection_id, v_system, v_src, nullif(btrim(c ->> 'state'), ''), nullif(btrim(c ->> 'locale'), ''),
              (c ->> 'ordersCount')::integer, cma.json_amount(c -> 'amountSpent'), cma.json_currency(c ->> 'currency'),
              cma.json_time(c -> 'createdAt', 'createdAt'), v_updated, coalesce(c -> 'raw', '{}'::jsonb));
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

-- Upserts orders as the store answered them, at most 500:
--   [{sourceId, orderName, customerId, createdAt, processedAt, updatedAt, cancelledAt, cancelReason,
--     isTest, currency, totalAmount, subtotalAmount, taxAmount, discountAmount, refundedAmount,
--     financialStatus, fulfillmentStatus, sourceName, appRef, landingHost, landingPath, utm,
--     referringHost, tags, priorOrdersCount, priorCountExact, deletedAt?, raw?,
--     lines?: [{lineId, sku, productRef, variantRef, quantity, unitPrice, currency}]}]
-- An order with lines replaces its set of lines (at most 500); without the key its lines stay.
-- order_kind is computed here (renewal lists, then the prior count). Older reads are stale, and so
-- is a read not newer than the order's deletion. A deletion keeps ids, times, amounts, kind and
-- lines, and clears the landing and referring page, UTM, tags and the raw payload. Hosts are lower-
-- cased (null when not a host), a path loses its query string, UTM keeps its five keys (each at
-- most 200 characters), tags are trimmed, de-duplicated and kept to 30 of at most 60 characters.
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
               raw = '{}'::jsonb, source_deleted_at = coalesce(co.source_deleted_at, v_deleted), synced_at = now()
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
                                      prior_count_exact, order_kind, raw)
      values (v_tenant, p_connection_id, v_system, v_src, nullif(btrim(o ->> 'orderName'), ''), nullif(btrim(o ->> 'customerId'), ''),
              v_created, cma.json_time(o -> 'processedAt', 'processedAt'), v_updated,
              cma.json_time(o -> 'cancelledAt', 'cancelledAt'), nullif(btrim(o ->> 'cancelReason'), ''),
              coalesce((o ->> 'isTest')::boolean, false), v_currency,
              cma.json_amount(o -> 'totalAmount'), cma.json_amount(o -> 'subtotalAmount'), cma.json_amount(o -> 'taxAmount'),
              cma.json_amount(o -> 'discountAmount'), cma.json_amount(o -> 'refundedAmount'),
              nullif(btrim(o ->> 'financialStatus'), ''), nullif(btrim(o ->> 'fulfillmentStatus'), ''),
              nullif(btrim(o ->> 'sourceName'), ''), nullif(btrim(o ->> 'appRef'), ''),
              v_lhost, v_lpath, v_utm, v_rhost, v_tags, v_prior, coalesce((o ->> 'priorCountExact')::boolean, false),
              v_kind, coalesce(o -> 'raw', '{}'::jsonb));
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
-- 8. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.upsert_commerce_store(uuid,text,text,text,text,text)',
    'cma.reclassify_orders()',
    'cma.connection_config(uuid)',
    'cma.ingest_upsert_commerce_customers(uuid,jsonb)',
    'cma.ingest_upsert_commerce_orders(uuid,jsonb)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
  -- helpers the functions and the settings trigger call in the caller's rights
  foreach f in array array[
    'cma.commerce_tags_ok(text[])', 'cma.commerce_renewal_lists(uuid)',
    'cma.commerce_order_kind(text,text,integer,text[],text[])', 'cma.reclassify_orders_of(uuid)',
    'cma.reclassify_orders_on_setting()'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 9. Reporting views (no raw payloads)
-- ---------------------------------------------------------------------------------------------
create or replace view cma_read.commerce_store as
  select id, tenant_id, connection_id, handle, name, market, currency, time_zone, created_at, updated_at
  from cma.commerce_store
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.commerce_customer as
  select id, tenant_id, connection_id, source_system, source_id, state, locale, orders_count, amount_spent, amount_currency,
         source_created_at, source_updated_at, source_deleted_at, synced_at
  from cma.commerce_customer
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.commerce_order as
  select id, tenant_id, connection_id, source_system, source_id, order_name, customer_source_id, source_created_at,
         processed_at, source_updated_at, cancelled_at, cancel_reason, is_test, currency, total_amount, subtotal_amount,
         tax_amount, discount_amount, refunded_amount, financial_status, fulfillment_status, source_name, app_ref,
         landing_host, landing_path, utm, referring_host, tags, prior_orders_count, prior_count_exact, order_kind,
         source_deleted_at, synced_at
  from cma.commerce_order
  where cma_read.reader_sees(tenant_id);

create or replace view cma_read.commerce_order_line as
  select tenant_id, connection_id, order_source_id, line_source_id, sku, product_ref, variant_ref, quantity, unit_price,
         currency, synced_at
  from cma.commerce_order_line
  where cma_read.reader_sees(tenant_id);

-- ---------------------------------------------------------------------------------------------
-- 10. Record the migration
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0007b', 'Commerce: stores (one per connection, unique handle), customers, orders with lines replaced as a set, order_kind (first, repeat, renewal, unknown) from the prior order count and the renewal settings, reclassified when a setting changes, the store in connection_config')
on conflict (version) do nothing;

reset role;
