-- =============================================================================================
-- 118_subscriptions.sql: addition 0008zl, a subscription app's subscriptions and their events, mirrored read-only
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after 116_asset_sync_load.sql
-- (0008zk). Rerunnable, forward-only, in one transaction. Run as your own IAM login: dev first, then
-- 119_verify_subscriptions.sql (dev and local only, as 117), then 115_verify_asset_sync.sql and 105_verify_reviews.sql
-- again (the connection's kinds, settings and run counts they read are made again here); then prod, with 115 and 105.
-- The web and the ingest of main read nothing this adds; the ingest of this change needs it (the job
-- subscriptions_poll, the run's counts, the upserts), so in prod the script runs before that ingest is deployed.
--
-- Why (Decision log, 28 October 2026): the tenant's subscription app (for Pulse4all the app on its commerce stores)
-- owns the subscriptions and their events; the ingest reads them directly, per store, and Postgres mirrors them read
-- only, so the CMA can report churn (KPI 4) and each subscription's payment state. Polling only: the app sends no
-- webhook for a failed renewal. One connection per store, its account id the store's own account (<handle>.<domain>),
-- matched to the tenant's commerce store of that handle, whose connection's customers the subscriptions' customer ids
-- join. Nothing personal is stored: no name, email, phone, address, payment details, free-text message or free-text
-- reason; a reason enters only as a code (the adapter keeps a fixed list), raw holds a fixed set of keys and no value
-- with an @.
--
-- What it adds
--   connection kind    integration_connection.kind gains subscriptions: the connection holds subscriptions and their
--                      events. cma.connection_held_kinds_of() and cma.set_connection_kind() know it;
--                      cma.assert_subscriptions_connection() guards the ingest's calls
--   the store link     cma.subscription_store_connection_of(tenant, connection): the commerce store whose handle is
--                      the connection's account id up to its first dot, and that store's connection (no new link
--                      column); cma.ingest_subscription_store(connection) answers it to the ingest, which fails a run
--                      without one (store_not_configured); the upserts refuse such a connection (CMA04)
--   subscriptions      cma.subscription: one row per subscription and connection (the source's id), the customer's id
--                      at the store, the source's status (active, paused, canceled, expired, failed, merged,
--                      never-subscribed), the current cycle, the next billing time, the billing interval and its
--                      count, the amount per cycle and its currency, the payment instrument's type (card, paypal or
--                      other; nothing else of it), created, paused, canceled and updated at the source, missing from
--                      the latest full read (source_deleted_at), synced_at and a filtered raw (checked keys, no @)
--   events             cma.subscription_event: one row per event of a subscription and connection (the source's id),
--                      its type in the CMA's words (renewed, renew_failed, canceled, paused, resumed, reactivated,
--                      status_changed; the adapter maps the source's types, so no vendor's type word lives here), when
--                      it occurred, the actor's type (staff, customer, system, bulk, api) and a staff actor's id only,
--                      the cycle, the attempt, the error code, the reason code, the status before and after, and a
--                      filtered raw. Append-only: the application inserts, never updates or deletes
--   ingest             cma.ingest_upsert_subscriptions(connection, items): at most 500, a stale guard on the source's
--                      update time, answering per subscription its outcome (inserted, updated, unchanged, stale) and
--                      whether its customer is among the store's customers; cma.ingest_upsert_subscription_events
--                      (connection, items): at most 500, an event already held unchanged; the final step of a full read
--                      cma.ingest_mark_subscriptions_missing(connection, ids, from, before) in slices, as 0008zk's
--                      devices, by the partial index subscription_present_source_c_idx
--   payment state      cma.subscription_payment_state_of(tenant): per present subscription its payment state, from the
--                      two tables only: failed (status failed), paused (status paused), canceled (status canceled or
--                      expired), in_retry (status active and a failed renewal of a cycle with no renewal of that cycle
--                      or a later one), paid (status active otherwise); merged and never-subscribed are left out.
--                      Awaiting payment (a renewal by draft order not paid yet) is not built: Pending in the
--                      definitions, an Open decision
--   settings           cma.set_connection_settings() checks a subscriptions connection's juo_poll_interval_minutes (a
--                      whole number from 1 to 60) and juo_max_per_second (1 to 10) when present (CMA04)
--   runs               sync_run.job gains subscriptions_poll; cma.ingest_sync_run_finish() takes events_new,
--                      customers_unmatched and reason_dropped among the counts
--   readers            cma_read.subscription and cma_read.subscription_event (no raw), cma_read.subscription_payment_state
--
-- Everything is SECURITY INVOKER and executable by the application only, with its permission checked inside; the
-- cma_read function is SECURITY DEFINER, owned by cma_owner, search path pinned, executable by readers only.
-- SQLSTATEs as before: CMA01 no acting user, CMA02 not found, CMA03 conflict, CMA04 invalid, CMA06 not permitted.
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
  if not exists (select 1 from cma.schema_migration where version = '0008zk') then
    raise exception 'addition 0008zk (116_asset_sync_load.sql) must run before 0008zl';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The connection's kind: subscriptions
-- ---------------------------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_constraint c where c.conrelid = 'cma.integration_connection'::regclass
             and c.conname = 'integration_connection_kind_check' and pg_get_constraintdef(c.oid) not like '%subscriptions%') then
    alter table cma.integration_connection drop constraint integration_connection_kind_check;
  end if;
  if not exists (select 1 from pg_constraint c where c.conrelid = 'cma.integration_connection'::regclass
                 and c.conname = 'integration_connection_kind_check') then
    alter table cma.integration_connection add constraint integration_connection_kind_check
      check (kind in ('crm', 'telephony', 'commerce', 'automation', 'reviews', 'assets', 'subscriptions'));
  end if;
end
$$;
comment on column cma.integration_connection.kind is
  'The kind of source in the data model''s terms (crm, telephony, commerce, automation, reviews, assets, subscriptions), never a vendor; null until set (0008e; reviews 0008ze; assets 0008zi; subscriptions 0008zl)';

-- ---------------------------------------------------------------------------------------------
-- 2. Runs: the poll's job and its counts
-- ---------------------------------------------------------------------------------------------
alter table cma.sync_run drop constraint if exists sync_run_job_check;
alter table cma.sync_run add constraint sync_run_job_check
  check (job in ('backfill', 'reconcile', 'forms_poll', 'subscriptions_check', 'link_calls', 'email_poll', 'close_forgotten_workdays',
                 'refresh_follow_up', 'reviews_poll', 'legacy_call_import', 'assets_import', 'assets_poll', 'subscriptions_poll')) not valid;
alter table cma.sync_run validate constraint sync_run_job_check;

-- As 0008zk (116) left it, plus a subscriptions read's counts: events_new (events stored for the first time),
-- customers_unmatched (subscriptions whose customer the store's customers do not hold) and reason_dropped (a reason the
-- adapter left out: free text, or a code outside its list)
create or replace function cma.ingest_sync_run_finish(p_run_id uuid, p_status text, p_counts jsonb, p_error text default null)
returns void
language plpgsql
as $$
declare
  v_status text;
begin
  perform cma.assert_permission('ingest.write');
  if p_status not in ('succeeded', 'failed') then
    raise exception 'status must be succeeded or failed' using errcode = 'CMA04';
  end if;
  if p_counts is not null and (jsonb_typeof(p_counts) <> 'object'
     or exists (select 1 from jsonb_each(p_counts) e
                where e.key not in ('fetched', 'upserted', 'stale', 'skipped', 'failed', 'dropped', 'ref_dropped',
                                    'rows', 'inserted', 'updated', 'unchanged', 'missing_now', 'components_replaced', 'components_closed',
                                    'unmapped_model', 'unmapped_status', 'unmapped_market', 'customer_ref_invalid', 'refs_dropped',
                                    'stage_ms', 'map_ms', 'upsert_ms', 'components_ms', 'missing_ms', 'cleanup_ms', 'chunk_max_ms', 'slice_max_ms',
                                    'chunk_size_min', 'chunk_halvings', 'events_new', 'customers_unmatched', 'reason_dropped')
                   or jsonb_typeof(e.value) <> 'number' or (e.value #>> '{}') !~ '^\d+$')) then
    raise exception 'counts are whole numbers for fetched, upserted, stale, skipped, failed, dropped and ref_dropped, a device load''s counts and its phase times, and a subscriptions read''s counts'
      using errcode = 'CMA04';
  end if;
  select r.status into v_status from cma.sync_run r where r.tenant_id = cma.current_tenant_id() and r.id = p_run_id for update;
  if v_status is null then
    raise exception 'no sync run % in the current tenant', p_run_id using errcode = 'CMA02';
  end if;
  if v_status <> 'running' then
    raise exception 'sync run % is already finished', p_run_id using errcode = 'CMA03';
  end if;
  update cma.sync_run r
     set status = p_status, finished_at = now(), counts = coalesce(p_counts, '{}'::jsonb), error = left(nullif(btrim(p_error), ''), 200)
   where r.tenant_id = cma.current_tenant_id() and r.id = p_run_id;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. Subscriptions and their events
-- ---------------------------------------------------------------------------------------------
-- An id as the subscription app writes one (its own ids, a store's customer id, a staff id): a letter or a digit, then
-- letters, digits, _ . : -, at most 100; never a space or an @
create or replace function cma.subscription_id_ok(p_value text)
returns boolean
language sql immutable
as $$
  select p_value ~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,99}$'
$$;

-- A filtered raw: an object of at most 2 kB whose keys are among p_keys and whose values are text (at most 200
-- characters, never holding an @), numbers, true or false, or null; never a nested object or a list
create or replace function cma.subscription_raw_ok(p_raw jsonb, p_keys text[])
returns boolean
language sql immutable
as $$
  select p_raw is not null and jsonb_typeof(p_raw) = 'object' and length(p_raw::text) <= 2048
     and not exists (select 1 from jsonb_each(p_raw) e
                     where not (e.key = any (p_keys))
                        or jsonb_typeof(e.value) not in ('string', 'number', 'boolean', 'null')
                        or (jsonb_typeof(e.value) = 'string'
                            and (length(e.value #>> '{}') > 200 or strpos(e.value #>> '{}', '@') > 0)))
$$;
revoke execute on function cma.subscription_id_ok(text), cma.subscription_raw_ok(jsonb, text[]) from public;
grant execute on function cma.subscription_id_ok(text), cma.subscription_raw_ok(jsonb, text[]) to cma_app;

create table if not exists cma.subscription (
  id                       uuid primary key default uuidv7(),
  tenant_id                uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id            uuid not null,
  source_system            text not null check (source_system ~ '^[a-z0-9_]+$'),
  source_id                text not null check (cma.subscription_id_ok(source_id)),
  customer_source_id       text check (cma.subscription_id_ok(customer_source_id)),
  status                   text not null check (status in ('active', 'paused', 'canceled', 'expired', 'failed', 'merged', 'never-subscribed')),
  current_cycle            integer check (current_cycle >= 0),
  next_billing_at          timestamptz,
  billing_interval         text check (billing_interval in ('day', 'week', 'month', 'year')),
  billing_interval_count   integer check (billing_interval_count between 1 and 1000),
  amount_per_cycle         numeric(14,2) check (amount_per_cycle >= 0),
  currency                 text check (currency ~ '^[A-Z]{3}$'),
  payment_instrument_type  text check (payment_instrument_type in ('card', 'paypal', 'other')),
  source_created_at        timestamptz,
  paused_at                timestamptz,
  canceled_at              timestamptz,
  source_updated_at        timestamptz,
  source_deleted_at        timestamptz,
  first_seen_at            timestamptz not null default now(),
  synced_at                timestamptz not null default now(),
  raw                      jsonb not null default '{}'::jsonb
                           check (cma.subscription_raw_ok(raw, array['id', 'status', 'customer', 'currentCycle', 'nextBillingDate',
                                                                     'billingInterval', 'billingIntervalCount', 'amountPerCycle',
                                                                     'currencyCode', 'instrumentType', 'createdAt', 'updatedAt',
                                                                     'canceledAt', 'pausedAt'])),
  unique (tenant_id, id),
  unique (tenant_id, connection_id, source_id),
  check (paused_at is null or status = 'paused'),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.subscription is 'A subscription app''s subscriptions per connection (one connection per store): the store customer''s id, the source''s status, cycle, next billing, interval, amount per cycle, the payment instrument''s type, times. No name, email, phone, address or payment details. Owned by the subscription app (0008zl)';
comment on column cma.subscription.customer_source_id is 'The customer''s id at the store (the store connection''s cma.commerce_customer.source_id); an id, never a name or an email';
comment on column cma.subscription.status is 'The subscription app''s status as it states it: active, paused, canceled, expired, failed, merged or never-subscribed';
comment on column cma.subscription.amount_per_cycle is 'The sum of the subscription''s current items'' total prices per billing cycle as the source states them, in currency';
comment on column cma.subscription.payment_instrument_type is 'The type of the payment method''s instrument only: card, paypal or other (null when unknown); nothing else of the payment method';
comment on column cma.subscription.paused_at is 'When the current pause began (the source''s time, else the latest pause event); null unless the status is paused';
comment on column cma.subscription.source_deleted_at is 'When the latest full read of the connection no longer returned the subscription; null while it is returned';
comment on column cma.subscription.raw is 'The subscription''s mapped values under the source''s names only (checked keys, scalar values, never an @)';
create index if not exists subscription_customer_idx on cma.subscription (tenant_id, connection_id, customer_source_id)
  where customer_source_id is not null;
create index if not exists subscription_status_idx on cma.subscription (tenant_id, status);
-- The final step's range index: a connection's present subscriptions by source id in byte order (as 0008zk's devices)
create index if not exists subscription_present_source_c_idx on cma.subscription (tenant_id, connection_id, (source_id collate "C"))
  where source_deleted_at is null;

create table if not exists cma.subscription_event (
  id                      uuid primary key default uuidv7(),
  tenant_id               uuid not null default cma.current_tenant_id() references cma.tenant (id),
  connection_id           uuid not null,
  source_system           text not null check (source_system ~ '^[a-z0-9_]+$'),
  source_id               text not null check (cma.subscription_id_ok(source_id)),
  subscription_source_id  text not null check (cma.subscription_id_ok(subscription_source_id)),
  event_type              text not null check (event_type in ('renewed', 'renew_failed', 'canceled', 'paused', 'resumed', 'reactivated',
                                                              'status_changed')),
  occurred_at             timestamptz not null,
  actor_type              text check (actor_type in ('staff', 'customer', 'system', 'bulk', 'api')),
  actor_source_id         text check (cma.subscription_id_ok(actor_source_id)),
  cycle_index             integer check (cycle_index >= 0),
  attempt                 integer check (attempt between 1 and 1000),
  error_code              text check (error_code ~ '^[A-Za-z][A-Za-z0-9_]{0,59}$'),
  reason_code             text check (reason_code ~ '^[a-z0-9]+([_-][a-z0-9]+)*$' and length(reason_code) <= 60),
  status_from             text check (status_from in ('active', 'paused', 'canceled', 'expired', 'failed', 'merged', 'never-subscribed')),
  status_to               text check (status_to in ('active', 'paused', 'canceled', 'expired', 'failed', 'merged', 'never-subscribed')),
  synced_at               timestamptz not null default now(),
  raw                     jsonb not null default '{}'::jsonb
                          check (cma.subscription_raw_ok(raw, array['id', 'type', 'occurredAt', 'subscriptionId', 'customerId', 'actorType',
                                                                    'actorId', 'cycleIndex', 'attempt', 'errorCode', 'reason',
                                                                    'previousStatus', 'status', 'orderId'])),
  unique (tenant_id, id),
  unique (tenant_id, connection_id, source_id),
  check (actor_source_id is null or actor_type = 'staff'),
  check (event_type <> 'status_changed' or status_to is not null),
  foreign key (tenant_id, connection_id) references cma.integration_connection (tenant_id, id)
);
comment on table cma.subscription_event is 'A subscription app''s events of its subscriptions per connection, in the CMA''s words: renewed, renew_failed, canceled, paused, resumed, reactivated, status_changed. Codes, counts and times only; a staff actor''s id, never a name; no free-text message or reason. Append-only. Owned by the subscription app (0008zl)';
comment on column cma.subscription_event.event_type is 'The event in the CMA''s words; the adapter maps the source''s types (docs/ingest/README.md, the adapter''s section)';
comment on column cma.subscription_event.cycle_index is 'The billing cycle the event is about, as the source counts them (a renewal''s or a failed renewal''s)';
comment on column cma.subscription_event.reason_code is 'A reason as a code from the adapter''s fixed list; free text is never stored (the run counts it as reason_dropped)';
comment on column cma.subscription_event.raw is 'The event''s mapped values under the source''s names only (checked keys, scalar values, never an @)';
create index if not exists subscription_event_subscription_idx
  on cma.subscription_event (tenant_id, connection_id, subscription_source_id, event_type, cycle_index);
create index if not exists subscription_event_occurred_idx on cma.subscription_event (tenant_id, occurred_at);

select cma.setup_tenant_table('cma.subscription');
select cma.setup_tenant_table('cma.subscription_event');

-- The application never deletes a subscription (a missing one gets source_deleted_at), and never changes or deletes an
-- event: the ingest inserts events only
revoke delete on cma.subscription from cma_app;
revoke update, delete on cma.subscription_event from cma_app;

-- ---------------------------------------------------------------------------------------------
-- 4. The kinds, the connection and its store
-- ---------------------------------------------------------------------------------------------
-- As 0008zj (114), plus subscriptions when it holds subscriptions or their events
create or replace function cma.connection_held_kinds_of(p_tenant_id uuid, p_connection_id uuid)
returns text[]
language sql stable
as $$
  select array_remove(array[
    case when exists (select 1 from cma.crm_record x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.crm_contact x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.crm_call x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_pipeline x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_form x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_call_outcome x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_field x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id
                        and x.entity not in ('device', 'device_component'))
           or exists (select 1 from cma.writeback_field x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_inbox x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_inbox_channel x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_email_rule x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.email_message x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.email_thread x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.crm_task x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_task_status x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_task_type x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
         then 'crm' end,
    case when exists (select 1 from cma.telephony_call x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.telephony_tag x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.telephony_number x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
         then 'telephony' end,
    case when exists (select 1 from cma.commerce_store x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.commerce_customer x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.commerce_order x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
         then 'commerce' end,
    case when exists (select 1 from cma.review_channel x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.review x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
         then 'reviews' end,
    case when exists (select 1 from cma.device x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.connection_field x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id
                        and x.entity in ('device', 'device_component'))
         then 'assets' end,
    case when exists (select 1 from cma.subscription x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
           or exists (select 1 from cma.subscription_event x where x.tenant_id = p_tenant_id and x.connection_id = p_connection_id)
         then 'subscriptions' end], null)
$$;

-- As 0008zi (112), with subscriptions among the kinds
create or replace function cma.set_connection_kind(p_connection_id uuid, p_kind text)
returns void
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_held   text[];
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  if coalesce(p_kind, '') not in ('crm', 'telephony', 'commerce', 'automation', 'reviews', 'assets', 'subscriptions') then
    raise exception 'kind must be crm, telephony, commerce, automation, reviews, assets or subscriptions' using errcode = 'CMA04';
  end if;
  v_held := cma.connection_held_kinds_of(v_tenant, p_connection_id);
  if cardinality(v_held) > 0 and not (p_kind = any (v_held)) then
    raise exception 'the connection holds % data; its kind cannot be %', array_to_string(v_held, ' and '), p_kind
      using errcode = 'CMA03';
  end if;
  update cma.integration_connection c set kind = p_kind
  where c.tenant_id = v_tenant and c.id = p_connection_id and c.kind is distinct from p_kind;
end
$$;

-- A connection the subscriptions may land in: its kind is subscriptions, or not set yet while it holds no other kind's
-- rows; CMA04 otherwise
create or replace function cma.assert_subscriptions_connection(p_connection_id uuid)
returns void
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_kind   text;
begin
  select c.kind into v_kind from cma.integration_connection c where c.tenant_id = v_tenant and c.id = p_connection_id;
  if (v_kind is not null and v_kind <> 'subscriptions')
     or (v_kind is null and not (cma.connection_held_kinds_of(v_tenant, p_connection_id) <@ array['subscriptions'])) then
    raise exception 'connection % is not a subscriptions connection', p_connection_id using errcode = 'CMA04';
  end if;
end
$$;

-- The commerce store of a subscriptions connection: the tenant's store whose handle is the connection's account id up to
-- its first dot, lower case (the account id names the store's own account, <handle>.<domain>), with that store's
-- connection, whose customers the subscriptions' customer ids join. No row without such a store
create or replace function cma.subscription_store_connection_of(p_tenant_id uuid, p_connection_id uuid)
returns table (store_id uuid, handle text, store_connection_id uuid)
language sql stable
as $$
  select s.id, s.handle, s.connection_id
  from cma.integration_connection c
  join cma.commerce_store s on s.tenant_id = c.tenant_id and s.handle = lower(split_part(btrim(c.external_account_id), '.', 1))
  where c.tenant_id = p_tenant_id and c.id = p_connection_id
$$;

-- The checks every ingest call of a subscriptions connection makes (ingest.write): an active connection of kind
-- subscriptions with a token secret name (the ingest reads it with that key), and its store configured (CMA04
-- store_not_configured otherwise). Answers the connection's adapter and its store's connection
create or replace function cma.subscriptions_ingest_target(p_connection_id uuid, out adapter text, out store_connection_id uuid)
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_permission('ingest.write');
  adapter := cma.active_connection_adapter(p_connection_id);
  perform cma.assert_subscriptions_connection(p_connection_id);
  if (select c.token_secret_name from cma.integration_connection c where c.tenant_id = v_tenant and c.id = p_connection_id) is null then
    raise exception 'connection % has no token secret name: the ingest does not read it', p_connection_id using errcode = 'CMA04';
  end if;
  select x.store_connection_id into store_connection_id from cma.subscription_store_connection_of(v_tenant, p_connection_id) x;
  if store_connection_id is null then
    raise exception 'store_not_configured: no commerce store of the tenant has the handle of connection %''s account id', p_connection_id
      using errcode = 'CMA04';
  end if;
end
$$;

-- The store of a subscriptions connection, for the ingest before it reads anything (ingest.write; the connection active
-- and of kind subscriptions): { handle, storeConnectionId }, or null without one (the adapter fails the run
-- store_not_configured)
create or replace function cma.ingest_subscription_store(p_connection_id uuid)
returns jsonb
language plpgsql stable
as $$
declare
  v_store record;
begin
  perform cma.assert_permission('ingest.write');
  perform cma.active_connection_adapter(p_connection_id);
  perform cma.assert_subscriptions_connection(p_connection_id);
  select * into v_store from cma.subscription_store_connection_of(cma.current_tenant_id(), p_connection_id);
  if v_store.store_connection_id is null then
    return null;
  end if;
  return jsonb_build_object('handle', v_store.handle, 'storeConnectionId', v_store.store_connection_id);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. The ingest's writes
-- ---------------------------------------------------------------------------------------------
-- A whole number from JSON, or null when absent or null; CMA04 for anything else
create or replace function cma.subscription_json_int(p_value jsonb, p_what text)
returns integer
language plpgsql immutable
as $$
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    return null;
  end if;
  if jsonb_typeof(p_value) <> 'number' or (p_value #>> '{}') !~ '^\d{1,9}$' then
    raise exception '% must be a whole number, got %', p_what, left(p_value::text, 40) using errcode = 'CMA04';
  end if;
  return (p_value #>> '{}')::integer;
end
$$;

-- Subscriptions of a connection: [{sourceId, customerSourceId, status, currentCycle, nextBillingAt, billingInterval,
-- billingIntervalCount, amountPerCycle, currency, paymentInstrumentType, sourceCreatedAt, pausedAt, canceledAt,
-- sourceUpdatedAt, raw}], at most 500, each id once. A subscription whose source update time is older than the stored
-- one is stale and left as it is. A new one is inserted; a known one is updated when anything differs (and comes back
-- when it was missing), else unchanged. paused_at: the source's pausedAt, else the latest paused event's time, else the
-- stored one, while the status is paused; null otherwise. Answers per subscription its outcome (inserted, updated,
-- unchanged, stale) and whether its customer is among the customers of the connection's store (null without a
-- customer id). CMA04 for an item out of its form, a connection without its store (store_not_configured) or one the
-- ingest does not read
create or replace function cma.ingest_upsert_subscriptions(p_connection_id uuid, p_items jsonb)
returns table (source_id text, outcome text, customer_matched boolean)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant   uuid := cma.current_tenant_id();
  v_target   record;
  i          jsonb;
  v_id       text;
  v_customer text;
  v_status   text;
  v_cycle    integer;
  v_next     timestamptz;
  v_interval text;
  v_count    integer;
  v_amount   numeric;
  v_currency text;
  v_instr    text;
  v_created  timestamptz;
  v_paused   timestamptz;
  v_canceled timestamptz;
  v_upd      timestamptz;
  v_raw      jsonb;
  v_old      cma.subscription;
begin
  select * into v_target from cma.subscriptions_ingest_target(p_connection_id);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500
     or exists (select 1 from jsonb_array_elements(p_items) x where jsonb_typeof(x) <> 'object') then
    raise exception 'items must be an array of at most 500 subscriptions' using errcode = 'CMA04';
  end if;
  if (select count(*) <> count(distinct x ->> 'sourceId') from jsonb_array_elements(p_items) x) then
    raise exception 'a subscription appears twice among the items' using errcode = 'CMA04';
  end if;
  for i in select x from jsonb_array_elements(p_items) x loop
    v_id := i ->> 'sourceId';
    if not coalesce(cma.subscription_id_ok(v_id), false) then
      raise exception 'a subscription needs an id (a letter or a digit, then letters, digits, _ . : -, at most 100)' using errcode = 'CMA04';
    end if;
    v_customer := nullif(i ->> 'customerSourceId', '');
    v_status := i ->> 'status';
    v_interval := i ->> 'billingInterval';
    v_currency := i ->> 'currency';
    v_instr := i ->> 'paymentInstrumentType';
    if (v_customer is not null and not cma.subscription_id_ok(v_customer))
       or coalesce(v_status, '') not in ('active', 'paused', 'canceled', 'expired', 'failed', 'merged', 'never-subscribed')
       or (v_interval is not null and v_interval not in ('day', 'week', 'month', 'year'))
       or (v_currency is not null and v_currency !~ '^[A-Z]{3}$')
       or (v_instr is not null and v_instr not in ('card', 'paypal', 'other'))
       or (i ? 'amountPerCycle' and jsonb_typeof(i -> 'amountPerCycle') not in ('number', 'null'))
       or (i ? 'raw' and jsonb_typeof(i -> 'raw') <> 'object') then
      raise exception 'subscription %: a customer id, a status of the seven, an interval of day, week, month or year, a currency code, an instrument of card, paypal or other, a number for the amount and an object for raw', v_id
        using errcode = 'CMA04';
    end if;
    v_cycle := cma.subscription_json_int(i -> 'currentCycle', 'currentCycle');
    v_count := cma.subscription_json_int(i -> 'billingIntervalCount', 'billingIntervalCount');
    v_amount := round((i ->> 'amountPerCycle')::numeric, 2);
    v_next := cma.json_time(i -> 'nextBillingAt', 'nextBillingAt');
    v_created := cma.json_time(i -> 'sourceCreatedAt', 'sourceCreatedAt');
    v_paused := cma.json_time(i -> 'pausedAt', 'pausedAt');
    v_canceled := cma.json_time(i -> 'canceledAt', 'canceledAt');
    v_upd := cma.json_time(i -> 'sourceUpdatedAt', 'sourceUpdatedAt');
    v_raw := coalesce(i -> 'raw', '{}'::jsonb);

    v_old := null;
    select * into v_old from cma.subscription s
    where s.tenant_id = v_tenant and s.connection_id = p_connection_id and s.source_id = v_id
    for update;
    if v_old.id is not null and v_upd is not null and v_old.source_updated_at is not null and v_upd < v_old.source_updated_at then
      source_id := v_id; outcome := 'stale';
      customer_matched := case when v_old.customer_source_id is not null then exists (
        select 1 from cma.commerce_customer cu
        where cu.tenant_id = v_tenant and cu.connection_id = v_target.store_connection_id and cu.source_id = v_old.customer_source_id) end;
      return next;
      continue;
    end if;

    -- when the current pause began: the source's time, else the latest pause event, else the stored time
    v_paused := case when v_status = 'paused' then coalesce(
                  v_paused,
                  (select max(e.occurred_at) from cma.subscription_event e
                   where e.tenant_id = v_tenant and e.connection_id = p_connection_id and e.subscription_source_id = v_id
                     and e.status_to = 'paused'),
                  case when v_old.status = 'paused' then v_old.paused_at end) end;

    if v_old.id is null then
      insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, current_cycle,
                                    next_billing_at, billing_interval, billing_interval_count, amount_per_cycle, currency,
                                    payment_instrument_type, source_created_at, paused_at, canceled_at, source_updated_at, raw)
      values (v_tenant, p_connection_id, v_target.adapter, v_id, v_customer, v_status, v_cycle, v_next, v_interval, v_count, v_amount,
              v_currency, v_instr, v_created, v_paused, v_canceled, v_upd, v_raw);
      outcome := 'inserted';
    elsif (v_old.customer_source_id, v_old.status, v_old.current_cycle, v_old.next_billing_at, v_old.billing_interval,
           v_old.billing_interval_count, v_old.amount_per_cycle, v_old.currency, v_old.payment_instrument_type, v_old.source_created_at,
           v_old.paused_at, v_old.canceled_at, v_old.source_updated_at, v_old.raw, v_old.source_deleted_at)
          is distinct from
          (v_customer, v_status, v_cycle, v_next, v_interval, v_count, v_amount, v_currency, v_instr, v_created, v_paused, v_canceled,
           v_upd, v_raw, null::timestamptz) then
      update cma.subscription s
         set customer_source_id = v_customer, status = v_status, current_cycle = v_cycle, next_billing_at = v_next,
             billing_interval = v_interval, billing_interval_count = v_count, amount_per_cycle = v_amount, currency = v_currency,
             payment_instrument_type = v_instr, source_created_at = v_created, paused_at = v_paused, canceled_at = v_canceled,
             source_updated_at = v_upd, raw = v_raw, source_deleted_at = null, synced_at = now()
       where s.tenant_id = v_tenant and s.id = v_old.id;
      outcome := 'updated';
    else
      outcome := 'unchanged';
    end if;
    source_id := v_id;
    customer_matched := case when v_customer is not null then exists (
      select 1 from cma.commerce_customer cu
      where cu.tenant_id = v_tenant and cu.connection_id = v_target.store_connection_id and cu.source_id = v_customer) end;
    return next;
  end loop;
exception when check_violation or not_null_violation or invalid_text_representation or numeric_value_out_of_range then
  raise exception 'invalid subscription: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- Events of a connection's subscriptions: [{sourceId, subscriptionSourceId, eventType, occurredAt, actorType,
-- actorSourceId, cycleIndex, attempt, errorCode, reasonCode, statusFrom, statusTo, raw}], at most 500, each id once.
-- Append-only: a new event is inserted, one already held is left as it is (unchanged). The subscription need not be held
-- yet (the poll reads the subscriptions its events touched afterwards). Answers per event its outcome (inserted,
-- unchanged). CMA04 for an item out of its form, a connection without its store or one the ingest does not read
create or replace function cma.ingest_upsert_subscription_events(p_connection_id uuid, p_items jsonb)
returns table (source_id text, outcome text)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant uuid := cma.current_tenant_id();
  v_target record;
  i        jsonb;
  v_id     text;
  v_sub    text;
  v_type   text;
  v_actor  text;
  v_actid  text;
  v_n      integer;
begin
  select * into v_target from cma.subscriptions_ingest_target(p_connection_id);
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500
     or exists (select 1 from jsonb_array_elements(p_items) x where jsonb_typeof(x) <> 'object') then
    raise exception 'items must be an array of at most 500 events' using errcode = 'CMA04';
  end if;
  if (select count(*) <> count(distinct x ->> 'sourceId') from jsonb_array_elements(p_items) x) then
    raise exception 'an event appears twice among the items' using errcode = 'CMA04';
  end if;
  for i in select x from jsonb_array_elements(p_items) x loop
    v_id := i ->> 'sourceId';
    v_sub := i ->> 'subscriptionSourceId';
    v_type := i ->> 'eventType';
    v_actor := i ->> 'actorType';
    v_actid := nullif(i ->> 'actorSourceId', '');
    if not coalesce(cma.subscription_id_ok(v_id), false) or not coalesce(cma.subscription_id_ok(v_sub), false) then
      raise exception 'an event needs its id and its subscription''s id' using errcode = 'CMA04';
    end if;
    if coalesce(v_type, '') not in ('renewed', 'renew_failed', 'canceled', 'paused', 'resumed', 'reactivated', 'status_changed')
       or (v_actor is not null and v_actor not in ('staff', 'customer', 'system', 'bulk', 'api'))
       or (v_actid is not null and v_actor is distinct from 'staff')
       or (i ? 'raw' and jsonb_typeof(i -> 'raw') <> 'object') then
      raise exception 'event %: a type of the seven, an actor type of staff, customer, system, bulk or api, an actor id for staff only and an object for raw', v_id
        using errcode = 'CMA04';
    end if;
    insert into cma.subscription_event (tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type,
                                        occurred_at, actor_type, actor_source_id, cycle_index, attempt, error_code, reason_code,
                                        status_from, status_to, raw)
    values (v_tenant, p_connection_id, v_target.adapter, v_id, v_sub, v_type, cma.json_time(i -> 'occurredAt', 'occurredAt'), v_actor,
            v_actid, cma.subscription_json_int(i -> 'cycleIndex', 'cycleIndex'), cma.subscription_json_int(i -> 'attempt', 'attempt'),
            nullif(i ->> 'errorCode', ''), nullif(i ->> 'reasonCode', ''), nullif(i ->> 'statusFrom', ''), nullif(i ->> 'statusTo', ''),
            coalesce(i -> 'raw', '{}'::jsonb))
    on conflict (tenant_id, connection_id, source_id) do nothing;
    get diagnostics v_n = row_count;
    source_id := v_id;
    outcome := case when v_n = 1 then 'inserted' else 'unchanged' end;
    return next;
  end loop;
exception when check_violation or not_null_violation or invalid_text_representation or numeric_value_out_of_range then
  raise exception 'invalid subscription event: %', sqlerrm using errcode = 'CMA04';
end
$$;

-- A full read's final step, one slice at a time (ingest.write), as 0008zk's devices: the run's subscription ids, sorted
-- by their bytes (collation "C"), cut into slices of at most 5,000; each slice one call and one transaction with its ids
-- and its range (p_from its first id, null for the first slice; p_before the next slice's first id, null for the last).
-- The connection's present subscriptions in that range whose id is not among the slice's ids get source_deleted_at, by
-- the range index. CMA04 without an id, with more than 5,000, with one that is no id, with bounds out of order or an id
-- outside the range: nothing is marked. A run that reads nothing (empty_snapshot) or fails before this step marks
-- nothing. Answers { missing_now, missing_ms }
create or replace function cma.ingest_mark_subscriptions_missing(p_connection_id uuid, p_source_ids text[], p_from text, p_before text)
returns jsonb
language plpgsql
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_t       timestamptz;
  v_missing integer;
begin
  perform cma.subscriptions_ingest_target(p_connection_id);
  if coalesce(cardinality(p_source_ids), 0) not between 1 and 5000 then
    raise exception 'a slice holds 1 to 5,000 subscription ids of the run' using errcode = 'CMA04';
  end if;
  if exists (select 1 from unnest(p_source_ids) x where not coalesce(cma.subscription_id_ok(x), false)) then
    raise exception 'a slice''s subscription ids are ids (a null or one that is no id among them)' using errcode = 'CMA04';
  end if;
  if (p_from is not null and not cma.subscription_id_ok(p_from)) or (p_before is not null and not cma.subscription_id_ok(p_before))
     or p_from >= p_before collate "C" then
    raise exception 'a slice''s bounds are subscription ids, its first before the next slice''s first' using errcode = 'CMA04';
  end if;
  if exists (select 1 from unnest(p_source_ids) x where x < p_from collate "C" or x >= p_before collate "C") then
    raise exception 'a subscription id lies outside its slice (from % before %): nothing is marked', coalesce(p_from, 'the start'),
      coalesce(p_before, 'the end') using errcode = 'CMA04';
  end if;
  v_t := clock_timestamp();
  update cma.subscription s set source_deleted_at = now(), synced_at = now()
  where s.tenant_id = v_tenant and s.connection_id = p_connection_id and s.source_deleted_at is null
    and (s.source_id collate "C") >= coalesce(p_from, '')
    and (p_before is null or (s.source_id collate "C") < p_before)
    and s.source_id not in (select x from unnest(p_source_ids) x);
  get diagnostics v_missing = row_count;
  return jsonb_build_object('missing_now', v_missing, 'missing_ms', round(extract(epoch from clock_timestamp() - v_t) * 1000));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. The payment state
-- ---------------------------------------------------------------------------------------------
-- Per subscription of the tenant that its latest full read still returned, its payment state, from the two tables only:
--   failed     status failed
--   paused     status paused
--   canceled   status canceled or expired
--   in_retry   status active and a failed renewal (renew_failed) of a cycle that no renewal (renewed) of that cycle or a
--              later one follows; where either event lacks its cycle, a renewal after the failure
--   paid       status active otherwise
-- merged and never-subscribed are left out. Awaiting payment (a renewal by draft order not paid yet) is not built
-- (Pending, an Open decision). retry_cycle and retry_since: the open failed renewal's cycle and its first failure (in_retry
-- only); last_attempt: its highest attempt. Under row-level security a caller sees its own tenant's only
create or replace function cma.subscription_payment_state_of(p_tenant_id uuid)
returns table (subscription_id uuid, connection_id uuid, source_id text, customer_source_id text, status text, payment_state text,
               retry_cycle integer, retry_since timestamptz, last_attempt integer)
language sql stable
as $$
  with s as (
    select s.id, s.connection_id, s.source_id, s.customer_source_id, s.status
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
  )
  select s.id, s.connection_id, s.source_id, s.customer_source_id, s.status,
         case when s.status = 'failed' then 'failed'
              when s.status = 'paused' then 'paused'
              when s.status in ('canceled', 'expired') then 'canceled'
              when d.subscription_source_id is not null then 'in_retry'
              else 'paid' end,
         d.cycle_index, d.since, d.last_attempt
  from s
  left join retry_detail d on d.connection_id = s.connection_id and d.subscription_source_id = s.source_id
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. Settings: a subscriptions connection's own
-- ---------------------------------------------------------------------------------------------
-- The first of a subscriptions connection's settings that is out of its form, or null: juo_poll_interval_minutes a whole
-- number from 1 to 60, juo_max_per_second one from 1 to 10 (a number or its digits as text). Both optional: the adapter
-- takes its defaults (5 minutes, 2 a second)
create or replace function cma.subscriptions_settings_problem(p_settings jsonb)
returns text
language sql immutable
as $$
  select case
    when p_settings ? 'juo_poll_interval_minutes'
         and not (jsonb_typeof(p_settings -> 'juo_poll_interval_minutes') in ('number', 'string')
                  and case when (p_settings ->> 'juo_poll_interval_minutes') ~ '^\d{1,2}$'
                           then (p_settings ->> 'juo_poll_interval_minutes')::integer between 1 and 60 else false end)
      then 'juo_poll_interval_minutes'
    when p_settings ? 'juo_max_per_second'
         and not (jsonb_typeof(p_settings -> 'juo_max_per_second') in ('number', 'string')
                  and case when (p_settings ->> 'juo_max_per_second') ~ '^\d{1,2}$'
                           then (p_settings ->> 'juo_max_per_second')::integer between 1 and 10 else false end)
      then 'juo_max_per_second'
  end
$$;

-- As 0008zk (116) left it, plus a subscriptions connection's own settings checked (a connection of kind subscriptions, or
-- one holding subscriptions or their events)
create or replace function cma.set_connection_settings(p_connection_id uuid, p_settings jsonb)
returns void
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_kind   text;
  v_held   text[];
  v_bad    text;
begin
  perform cma.assert_permission('tenant.configure');
  perform cma.assert_connection(p_connection_id);
  if not cma.connection_settings_ok(coalesce(p_settings, '{}'::jsonb)) then
    raise exception 'settings must be a flat object of at most 4 kB, keys lower case, no key containing secret, token, password or key'
      using errcode = 'CMA04';
  end if;
  select c.kind into v_kind from cma.integration_connection c where c.tenant_id = v_tenant and c.id = p_connection_id;
  v_held := case when v_kind is null then cma.connection_held_kinds_of(v_tenant, p_connection_id) else '{}'::text[] end;
  if v_kind = 'assets' or (v_kind is null and 'assets' = any (v_held)) then
    if coalesce(p_settings, '{}'::jsonb) ? 'view_id' then
      raise exception 'an asset register is read whole: view_id is no setting of it (a view''s filter would make the devices outside it look missing)'
        using errcode = 'CMA04';
    end if;
    v_bad := cma.assets_settings_problem(coalesce(p_settings, '{}'::jsonb));
    if v_bad is not null then
      raise exception 'the setting % is out of its form: table_id is an id, date_format is dmy, mdy or iso, assets_poll_interval_minutes a whole number from 1 to 1440, assets_load_chunk one from 100 to 5,000', v_bad
        using errcode = 'CMA04';
    end if;
  end if;
  if v_kind = 'subscriptions' or (v_kind is null and 'subscriptions' = any (v_held)) then
    v_bad := cma.subscriptions_settings_problem(coalesce(p_settings, '{}'::jsonb));
    if v_bad is not null then
      raise exception 'the setting % is out of its form: juo_poll_interval_minutes is a whole number from 1 to 60, juo_max_per_second one from 1 to 10', v_bad
        using errcode = 'CMA04';
    end if;
  end if;
  update cma.integration_connection c set settings = coalesce(p_settings, '{}'::jsonb)
  where c.tenant_id = v_tenant and c.id = p_connection_id;
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
    'cma.ingest_sync_run_finish(uuid,text,jsonb,text)',
    'cma.connection_held_kinds_of(uuid,uuid)',
    'cma.set_connection_kind(uuid,text)',
    'cma.assert_subscriptions_connection(uuid)',
    'cma.subscription_store_connection_of(uuid,uuid)',
    'cma.subscriptions_ingest_target(uuid)',
    'cma.ingest_subscription_store(uuid)',
    'cma.subscription_json_int(jsonb,text)',
    'cma.ingest_upsert_subscriptions(uuid,jsonb)',
    'cma.ingest_upsert_subscription_events(uuid,jsonb)',
    'cma.ingest_mark_subscriptions_missing(uuid,text[],text,text)',
    'cma.subscription_payment_state_of(uuid)',
    'cma.subscriptions_settings_problem(jsonb)',
    'cma.set_connection_settings(uuid,jsonb)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 9. Reporting views
-- ---------------------------------------------------------------------------------------------
-- Every column but raw: ids, the status, cycle, billing, amount, the instrument's type and times
create or replace view cma_read.subscription as
  select id, tenant_id, connection_id, source_system, source_id, customer_source_id, status, current_cycle, next_billing_at,
         billing_interval, billing_interval_count, amount_per_cycle, currency, payment_instrument_type, source_created_at, paused_at,
         canceled_at, source_updated_at, source_deleted_at, first_seen_at, synced_at
  from cma.subscription
  where cma_read.reader_sees(tenant_id);

-- Every column but raw: ids, the type, the time, the actor's type (and a staff actor's id), cycle, attempt, codes, statuses
create or replace view cma_read.subscription_event as
  select id, tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type, occurred_at, actor_type,
         actor_source_id, cycle_index, attempt, error_code, reason_code, status_from, status_to, synced_at
  from cma.subscription_event
  where cma_read.reader_sees(tenant_id);

-- The payment state of every subscription of every tenant the reader sees (cma.subscription_payment_state_of): SECURITY
-- DEFINER in cma_read, owned by cma_owner, search path pinned, executable by readers only. Ids, states and times only
create or replace function cma_read.subscription_payment_state_rows()
returns table (tenant_id uuid, subscription_id uuid, connection_id uuid, source_id text, customer_source_id text, status text,
               payment_state text, retry_cycle integer, retry_since timestamptz, last_attempt integer)
language sql stable security definer
set search_path = pg_catalog, cma, pg_temp
as $$
  select t.id, p.subscription_id, p.connection_id, p.source_id, p.customer_source_id, p.status, p.payment_state, p.retry_cycle,
         p.retry_since, p.last_attempt
  from cma.tenant t
  cross join lateral cma.subscription_payment_state_of(t.id) p
  where cma_read.reader_sees(t.id)
$$;
revoke execute on function cma_read.subscription_payment_state_rows() from public;
grant execute on function cma_read.subscription_payment_state_rows() to cma_readonly;

create or replace view cma_read.subscription_payment_state as
  select * from cma_read.subscription_payment_state_rows();

-- ---------------------------------------------------------------------------------------------
-- 10. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0008zl', 'Subscriptions: a subscription app''s subscriptions and their events mirrored read-only, one connection per store (connection kind subscriptions; the store matched by the handle in the account id, cma.subscription_store_connection_of, no new link column). cma.subscription (the source''s status of seven, cycle, next billing, interval, amount per cycle, the instrument''s type, times, source_deleted_at, a checked raw) and cma.subscription_event (renewed, renew_failed, canceled, paused, resumed, reactivated, status_changed; actor type, a staff actor''s id only, cycle, attempt, error and reason codes, statuses; append-only); cma.ingest_subscription_store, cma.ingest_upsert_subscriptions (stale guard; the customer matched among the store''s customers), cma.ingest_upsert_subscription_events, cma.ingest_mark_subscriptions_missing in slices; cma.subscription_payment_state_of (failed, paused, canceled, in_retry, paid; awaiting payment not built); the settings juo_poll_interval_minutes and juo_max_per_second checked; sync_run job subscriptions_poll and the counts events_new, customers_unmatched, reason_dropped; cma_read.subscription, subscription_event, subscription_payment_state')
on conflict (version) do nothing;

commit;
reset role;
