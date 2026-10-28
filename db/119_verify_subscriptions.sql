-- =============================================================================================
-- 119_verify_subscriptions.sql: verifies addition 0008zl, a subscription app's subscriptions and their events
-- =============================================================================================
-- Dev and local databases only, as 117 (Decision log, 28 October 2026): block Z reads every subscription and event row
-- of every tenant for an email pattern after the flow verifier's fixtures (ingest/verify/juo-flow.mjs runs in dev and
-- local databases only). It refuses a database without the dev seed (no active agent.two@example.com, as the ingest's
-- flow verifiers refuse one): every check reads FAIL and the verdict REFUSED. Blocks A and Z only read; block B works on
-- throwaway tenants inside a subtransaction that is always rolled back, so nothing stays (as 115). Every check writes
-- one row, PASS or FAIL, and the last row is the verdict, because Cloud SQL Studio shows no notices. Run as your own IAM
-- login after 118_subscriptions.sql, in dev; then 115_verify_asset_sync.sql, 105_verify_reviews.sql,
-- 107_verify_review_reference_guard.sql and 53_verify_sources_configuration.sql again. Adapters,
-- handles, ids, codes, people and secret names are invented data values, and no row carries a name, an address, an
-- email or a phone number of a customer.
--   A  structure and privileges: the addition row after 0008zk; both tables tenant-aware (row-level security, the
--      tenant policy, the audit trigger), the application without delete on either and without update on the events;
--      the unique keys; the job subscriptions_poll and the kind subscriptions; every function the application's only and
--      in the caller's rights, the reader function the readers' only and the owner's; the reader views without raw; the
--      settings by form (pure)
--   B  behaviour, on two throwaway tenants, each with its Ingest user, a commerce store (its handle, its connection and
--      two of its customers) and a subscriptions connection whose account id names that handle; tenant one also holds a
--      subscriptions connection whose handle has no store, one without a token secret name, and a CRM connection.
--      Checked: the upserts as the Ingest user (outcomes, the customers matched, a rerun unchanged, a stale and a changed
--      subscription, paused_at from the pause event); the events append-only; the payment state for each case (failed,
--      paused, canceled for canceled and expired, in_retry, paid, paid again after a renewal of the failed cycle, merged
--      and never-subscribed left out); row-level security across the two tenants' Ingest users and in the reader views;
--      the refusals (store_not_configured, no token secret name, a CRM connection, a person, items out of form, an @ in
--      raw, the events' update and delete, a subscription's delete); the final step in slices; the settings; the run's
--      counts; audit rows written for both tables; the kinds; no column of either table holding an email pattern
--   Z  every subscription and event row of the database: no column holding an email pattern
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

drop table if exists pg_temp.verify_0008zl;
create temp table verify_0008zl (ord int, check_name text, result text, detail text);

-- The error code a statement raises, or 'ok'
create or replace function pg_temp.v0008zl_code(p_sql text)
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

-- The error a statement raises as code: message (the message cut at its first colon), or 'ok'
create or replace function pg_temp.v0008zl_error(p_sql text)
returns text
language plpgsql
as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate || ': ' || split_part(sqlerrm, ':', 1);
end
$$;

-- The scenario's subscriptions as the adapter maps them (map.mjs subscriptionItem): every case of the payment state.
-- p_variant: base, or changed (sub-paid's next billing moved, its update time later), or stale (sub-paid's update time
-- earlier, its cycle changed)
create or replace function pg_temp.v0008zl_subs(p_variant text)
returns jsonb
language sql
as $$
  select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'sourceId', v.id, 'customerSourceId', v.customer, 'status', v.status, 'currentCycle', v.cycle,
           'nextBillingAt', case when p_variant = 'changed' and v.id = 'sub-paid' then '2026-12-15T10:00:00.000Z' else v.next end,
           'billingInterval', 'month', 'billingIntervalCount', 1, 'amountPerCycle', 29.95, 'currency', 'GBP',
           'paymentInstrumentType', v.instrument, 'sourceCreatedAt', '2025-01-10T09:00:00.000Z', 'canceledAt', v.canceled,
           'sourceUpdatedAt', case when v.id <> 'sub-paid' then '2026-10-20T09:00:00.000Z'
                                   when p_variant = 'changed' then '2026-10-27T09:00:00.000Z'
                                   when p_variant = 'stale' then '2026-10-01T09:00:00.000Z'
                                   else '2026-10-20T09:00:00.000Z' end,
           'raw', jsonb_strip_nulls(jsonb_build_object('id', v.id, 'status', upper(v.status), 'customer', v.customer,
                                                       'currentCycle', case when p_variant = 'stale' and v.id = 'sub-paid' then 99 else v.cycle end,
                                                       'currencyCode', 'GBP', 'instrumentType', v.instrument)))) order by v.id)
  from (values
    ('sub-paid', '9001', 'active', 4, '2026-11-15T10:00:00.000Z', 'card', null),
    ('sub-retry', '9002', 'active', 6, '2026-10-25T10:00:00.000Z', 'paypal', null),
    ('sub-renewed', '9999', 'active', 3, '2026-11-20T10:00:00.000Z', 'other', null),
    ('sub-failed', null, 'failed', 2, null, 'card', '2026-10-21T09:00:00.000Z'),
    ('sub-paused', '9001', 'paused', 5, null, 'card', null),
    ('sub-canceled', '9002', 'canceled', 7, null, 'card', '2026-10-19T09:00:00.000Z'),
    ('sub-expired', '9001', 'expired', 12, null, null, null),
    ('sub-merged', '9001', 'merged', 1, null, null, null),
    ('sub-never', '9002', 'never-subscribed', 0, null, null, null)
  ) as v(id, customer, status, cycle, next, instrument, canceled)
$$;

-- The scenario's events as the adapter maps them (map.mjs eventItem)
create or replace function pg_temp.v0008zl_events()
returns jsonb
language sql
as $$
  select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'sourceId', v.id, 'subscriptionSourceId', v.sub, 'eventType', v.type, 'occurredAt', v.at, 'actorType', v.actor,
           'actorSourceId', v.actor_id, 'cycleIndex', v.cycle, 'attempt', v.attempt, 'errorCode', v.error_code,
           'reasonCode', v.reason, 'statusFrom', v.status_from, 'statusTo', v.status_to,
           'raw', jsonb_strip_nulls(jsonb_build_object('id', v.id, 'subscriptionId', v.sub, 'occurredAt', v.at, 'actorType', v.actor,
                                                       'cycleIndex', v.cycle, 'attempt', v.attempt, 'errorCode', v.error_code,
                                                       'reason', v.reason)))) order by v.id)
  from (values
    ('ev-01', 'sub-retry', 'renewed', '2026-09-25T10:00:00.000Z', 'system', null, 5, null, null, null, null, null),
    ('ev-02', 'sub-retry', 'renew_failed', '2026-10-25T10:00:00.000Z', 'system', null, 6, 1, 'CARD_DECLINED', 'billing-attempt-failed', null, null),
    ('ev-03', 'sub-retry', 'renew_failed', '2026-10-26T10:00:00.000Z', 'system', null, 6, 2, 'INSUFFICIENT_FUNDS', 'billing-attempt-failed', null, null),
    ('ev-04', 'sub-renewed', 'renew_failed', '2026-10-18T10:00:00.000Z', 'system', null, 3, 1, 'PROCESSING_ERROR', null, null, null),
    ('ev-05', 'sub-renewed', 'renewed', '2026-10-20T10:00:00.000Z', 'system', null, 3, null, null, null, null, null),
    ('ev-06', 'sub-paid', 'renew_failed', '2026-08-15T10:00:00.000Z', 'system', null, 2, 1, 'EXPIRED_CARD', null, null, null),
    ('ev-07', 'sub-paid', 'renewed', '2026-10-15T10:00:00.000Z', 'system', null, 4, null, null, null, null, null),
    ('ev-08', 'sub-paused', 'paused', '2026-10-12T08:30:00.000Z', 'staff', 'staff-71', null, null, null, null, 'active', 'paused'),
    ('ev-09', 'sub-canceled', 'canceled', '2026-10-19T09:00:00.000Z', 'customer', null, null, null, null, null, 'active', 'canceled'),
    ('ev-10', 'sub-failed', 'status_changed', '2026-10-21T09:00:00.000Z', 'system', null, null, null, null, null, 'active', 'failed'),
    ('ev-11', 'sub-elsewhere', 'resumed', '2026-10-22T09:00:00.000Z', 'bulk', null, null, null, null, null, 'paused', 'active')
  ) as v(id, sub, type, at, actor, actor_id, cycle, attempt, error_code, reason, status_from, status_to)
$$;

-- A. Structure and privileges
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_bad     text;
  v_fn      text;
  v_t       text;
begin
  -- A1. the addition is recorded, after 0008zk
  insert into verify_0008zl values (1, 'A1 addition 0008zl recorded, after 0008zk',
    case when exists (select 1 from cma.schema_migration where version = '0008zl')
              and exists (select 1 from cma.schema_migration where version = '0008zk') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. both tables tenant-aware: row-level security on, the tenant policy, the audit trigger, a foreign key to the
  --     tenant; the application selects and inserts both, updates subscriptions only, deletes neither
  v_bad := '';
  foreach v_t in array array['subscription', 'subscription_event'] loop
    if not (select relrowsecurity from pg_class where oid = ('cma.' || v_t)::regclass)
       or not exists (select 1 from pg_policy where polrelid = ('cma.' || v_t)::regclass and polname = 'tenant_app')
       or not exists (select 1 from pg_trigger where tgrelid = ('cma.' || v_t)::regclass and tgname = 'audit' and not tgisinternal)
       or not exists (select 1 from pg_constraint where conrelid = ('cma.' || v_t)::regclass and contype = 'f'
                        and confrelid = 'cma.tenant'::regclass)
       or not has_table_privilege('cma_app', 'cma.' || v_t, 'select') or not has_table_privilege('cma_app', 'cma.' || v_t, 'insert')
       or has_table_privilege('cma_app', 'cma.' || v_t, 'delete') or has_table_privilege('cma_readonly', 'cma.' || v_t, 'select') then
      v_bad := v_bad || v_t || '; ';
    end if;
  end loop;
  if not has_table_privilege('cma_app', 'cma.subscription', 'update') or has_table_privilege('cma_app', 'cma.subscription_event', 'update') then
    v_bad := v_bad || 'update; ';
  end if;
  insert into verify_0008zl values (2, 'A2 both tables tenant-aware (RLS, policy, audit); no delete by the application, no update of an event',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A3. the unique keys: (tenant_id, connection_id, source_id) on both; (tenant_id, id) on both
  v_bad := '';
  foreach v_t in array array['subscription', 'subscription_event'] loop
    if not exists (select 1 from pg_constraint where conrelid = ('cma.' || v_t)::regclass and contype = 'u'
                     and pg_get_constraintdef(oid) = 'UNIQUE (tenant_id, connection_id, source_id)')
       or not exists (select 1 from pg_constraint where conrelid = ('cma.' || v_t)::regclass and contype = 'u'
                        and pg_get_constraintdef(oid) = 'UNIQUE (tenant_id, id)') then
      v_bad := v_bad || v_t || '; ';
    end if;
  end loop;
  insert into verify_0008zl values (3, 'A3 the unique keys (tenant_id, connection_id, source_id) and (tenant_id, id) on both tables',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A4. the job subscriptions_poll beside the earlier ones; the kind subscriptions beside the earlier ones
  v_bad := '';
  if (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.sync_run'::regclass and conname = 'sync_run_job_check')
     not like '%''reviews_poll''%''assets_poll''%''subscriptions_poll''%' then
    v_bad := v_bad || 'job; ';
  end if;
  if (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.integration_connection'::regclass and conname = 'integration_connection_kind_check')
     not like '%''reviews''%''assets''%''subscriptions''%' then
    v_bad := v_bad || 'kind; ';
  end if;
  insert into verify_0008zl values (4, 'A4 the job subscriptions_poll and the connection kind subscriptions',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A5. every function the application's only and in the caller's rights; the reader function the readers' only, the
  --     owner's rights, its search path pinned
  v_bad := '';
  foreach v_fn in array array[
    'cma.ingest_sync_run_finish(uuid,text,jsonb,text)', 'cma.connection_held_kinds_of(uuid,uuid)', 'cma.set_connection_kind(uuid,text)',
    'cma.assert_subscriptions_connection(uuid)', 'cma.subscription_store_connection_of(uuid,uuid)', 'cma.subscriptions_ingest_target(uuid)',
    'cma.ingest_subscription_store(uuid)', 'cma.subscription_json_int(jsonb,text)', 'cma.ingest_upsert_subscriptions(uuid,jsonb)',
    'cma.ingest_upsert_subscription_events(uuid,jsonb)', 'cma.ingest_mark_subscriptions_missing(uuid,text[],text,text)',
    'cma.subscription_payment_state_of(uuid)', 'cma.subscriptions_settings_problem(jsonb)', 'cma.set_connection_settings(uuid,jsonb)',
    'cma.subscription_id_ok(text)', 'cma.subscription_raw_ok(jsonb,text[])'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure(v_fn) and a.grantee = 0) then
      v_bad := v_bad || v_fn || '; ';
    end if;
  end loop;
  v_fn := 'cma_read.subscription_payment_state_rows()';
  if to_regprocedure(v_fn) is null or not has_function_privilege('cma_readonly', v_fn, 'execute')
     or has_function_privilege('cma_app', v_fn, 'execute')
     or not (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
     or not exists (select 1 from pg_proc p where p.oid = to_regprocedure(v_fn) and 'search_path=pg_catalog, cma, pg_temp' = any (p.proconfig))
     or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure(v_fn) and a.grantee = 0) then
    v_bad := v_bad || v_fn || '; ';
  end if;
  insert into verify_0008zl values (5, 'A5 every function the application''s only and invoker; the reader function the readers'' only, definer, pinned',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A6. the reader views: subscription and subscription_event without raw, subscription_payment_state; readable by readers
  v_bad := '';
  foreach v_t in array array['subscription', 'subscription_event', 'subscription_payment_state'] loop
    if to_regclass('cma_read.' || v_t) is null or not has_table_privilege('cma_readonly', 'cma_read.' || v_t, 'select') then
      v_bad := v_bad || v_t || '; ';
    end if;
  end loop;
  if exists (select 1 from information_schema.columns where table_schema = 'cma_read'
               and table_name in ('subscription', 'subscription_event', 'subscription_payment_state') and column_name = 'raw') then
    v_bad := v_bad || 'raw; ';
  end if;
  insert into verify_0008zl values (6, 'A6 the reader views (no raw), readable by readers',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A7. the settings by form: each key's first fault named, the rest accepted
  v_bad := concat_ws(' ',
    coalesce(cma.subscriptions_settings_problem('{}'), 'ok'),
    coalesce(cma.subscriptions_settings_problem('{"juo_poll_interval_minutes": 5, "juo_max_per_second": 2}'), 'ok'),
    coalesce(cma.subscriptions_settings_problem('{"juo_poll_interval_minutes": "60", "juo_max_per_second": "10"}'), 'ok'),
    coalesce(cma.subscriptions_settings_problem('{"juo_poll_interval_minutes": 1, "juo_max_per_second": 1}'), 'ok'),
    coalesce(cma.subscriptions_settings_problem('{"juo_poll_interval_minutes": 0}'), 'ok'),
    coalesce(cma.subscriptions_settings_problem('{"juo_poll_interval_minutes": 61}'), 'ok'),
    coalesce(cma.subscriptions_settings_problem('{"juo_poll_interval_minutes": "5m"}'), 'ok'),
    coalesce(cma.subscriptions_settings_problem('{"juo_poll_interval_minutes": 7.5}'), 'ok'),
    coalesce(cma.subscriptions_settings_problem('{"juo_max_per_second": 0}'), 'ok'),
    coalesce(cma.subscriptions_settings_problem('{"juo_max_per_second": 11}'), 'ok'),
    coalesce(cma.subscriptions_settings_problem('{"juo_max_per_second": true}'), 'ok'),
    coalesce(cma.subscriptions_settings_problem('{"example_setting": 99}'), 'ok'));
  insert into verify_0008zl values (7, 'A7 the settings by form: the poll interval from 1 to 60, the pace from 1 to 10',
    case when v_bad = 'ok ok ok ok juo_poll_interval_minutes juo_poll_interval_minutes juo_poll_interval_minutes juo_poll_interval_minutes '
                      || 'juo_max_per_second juo_max_per_second juo_max_per_second ok'
              and not v_provoke then 'PASS' else 'FAIL' end, v_bad);
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
  v_shop1 uuid; v_shop2 uuid; v_sub1 uuid; v_sub2 uuid; v_nostore uuid; v_nokey uuid; v_crm uuid;
  v_run uuid;
  v_txt text;
  j jsonb;
begin
  if not v_dev then
    insert into verify_0008zl values (59, 'B a dev or local database (the dev seed''s agent.two@example.com active)', 'FAIL',
      'REFUSED: no dev seed, so this is no dev or local database; nothing ran');
    return;
  end if;
  begin
    -- tenants (each with its Ingest user), a person and connections (as the owner); each tenant's store with two customers
    v_t1 := cma.create_tenant('verify-0008zl-one', 'Verify 0008zl one', 'Europe/London');
    v_t2 := cma.create_tenant('verify-0008zl-two', 'Verify 0008zl two', 'Europe/London');
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest' and x.external_id = 'ingest';
    select x.user_id into v_ing2 from cma.app_user_external_id x where x.tenant_id = v_t2 and x.system = 'ingest' and x.external_id = 'ingest';
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, v_admin1, ar.id from cma.app_role ar where ar.tenant_id = v_t1 and ar.key = 'admin';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, signing_secret_name)
    values (v_t1, 'verifyshop', 'Verify shop one', 'verify-store-1.shop.example', 'commerce', 'verify-shop-signing-1') returning id into v_shop1;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t1, 'verifysubs', 'Verify subscriptions one', 'verify-store-1.shop.example', 'subscriptions', 'verify-subs-key-1') returning id into v_sub1;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t1, 'verifysubs', 'Verify subscriptions without a store', 'verify-nostore.shop.example', 'subscriptions', 'verify-subs-key-3')
    returning id into v_nostore;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifysubsb', 'Verify subscriptions without a key', 'verify-store-1.shop.example', 'subscriptions') returning id into v_nokey;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t1, 'verifycrm', 'Verify CRM', 'portal-1', 'crm', 'verify-crm-token-1') returning id into v_crm;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, signing_secret_name)
    values (v_t2, 'verifyshop', 'Verify shop two', 'verify-store-2.shop.example', 'commerce', 'verify-shop-signing-2') returning id into v_shop2;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t2, 'verifysubs', 'Verify subscriptions two', 'verify-store-2.shop.example', 'subscriptions', 'verify-subs-key-2') returning id into v_sub2;
    insert into cma.commerce_store (tenant_id, connection_id, handle, name, market, currency, time_zone)
    values (v_t1, v_shop1, 'verify-store-1', 'Verify store one', 'GB', 'GBP', 'Europe/London'),
           (v_t2, v_shop2, 'verify-store-2', 'Verify store two', 'GB', 'GBP', 'Europe/London');
    insert into cma.commerce_customer (tenant_id, connection_id, source_system, source_id)
    values (v_t1, v_shop1, 'verifyshop', '9001'), (v_t1, v_shop1, 'verifyshop', '9002'),
           (v_t2, v_shop2, 'verifyshop', '9001'), (v_t2, v_shop2, 'verifyshop', '9002');
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_ing1::text, true);

    -- B1. the store of each connection as the ingest asks for it: the handle's store and its connection; none for a
    --     connection whose handle has no store
    j := cma.ingest_subscription_store(v_sub1);
    v_txt := (j ->> 'handle') || ' ' || ((j ->> 'storeConnectionId')::uuid = v_shop1)::text || ' '
             || coalesce(cma.ingest_subscription_store(v_nostore)::text, 'null');
    v_rows := v_rows || array['11', 'B1 the store of a connection by the handle in its account id; none without a store',
      case when v_txt = 'verify-store-1 true null' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B2. events first (as the poll writes them), then the subscriptions: every one inserted; the customers matched among
    --     the store's (9999 is none of them; sub-failed has none); a rerun of both unchanged; paused_at from the pause
    --     event; an event of a subscription not held yet stored
    select string_agg(x.outcome || ':' || x.n, ' ' order by x.outcome) into v_txt
    from (select e.outcome, count(*) as n from cma.ingest_upsert_subscription_events(v_sub1, pg_temp.v0008zl_events()) e group by 1) x;
    v_txt := v_txt || ' | ' || (select string_agg(s.source_id || ':' || s.outcome || ':' || coalesce(s.customer_matched::text, '-'), ' ' order by s.source_id)
                                from cma.ingest_upsert_subscriptions(v_sub1, pg_temp.v0008zl_subs('base')) s);
    v_txt := v_txt || ' | ' || (select string_agg(x.outcome || ':' || x.n, ' ' order by x.outcome)
                                from (select e.outcome, count(*) as n from cma.ingest_upsert_subscription_events(v_sub1, pg_temp.v0008zl_events()) e group by 1) x)
             || ' ' || (select string_agg(x.outcome || ':' || x.n, ' ' order by x.outcome)
                        from (select s.outcome, count(*) as n from cma.ingest_upsert_subscriptions(v_sub1, pg_temp.v0008zl_subs('base')) s group by 1) x)
             || ' | ' || (select to_char(s.paused_at at time zone 'UTC', 'YYYY-MM-DD HH24:MI') from cma.subscription s where s.connection_id = v_sub1 and s.source_id = 'sub-paused')
             || ' ' || (select count(*) from cma.subscription s where s.connection_id = v_sub1 and s.paused_at is not null);
    v_rows := v_rows || array['12', 'B2 the upserts as the Ingest user: inserted, the customers matched, a rerun unchanged, paused_at from the pause event',
      case when v_txt = 'inserted:11 | sub-canceled:inserted:true sub-expired:inserted:true sub-failed:inserted:- sub-merged:inserted:true '
                        || 'sub-never:inserted:true sub-paid:inserted:true sub-paused:inserted:true sub-renewed:inserted:false '
                        || 'sub-retry:inserted:true | unchanged:11 unchanged:9 | 2026-10-12 08:30 1'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B3. the stale guard: an older update time leaves the subscription as it is; a later one with a change updates it
    v_txt := (select s.outcome from cma.ingest_upsert_subscriptions(v_sub1, pg_temp.v0008zl_subs('stale')) s where s.source_id = 'sub-paid')
             || ' ' || (select (s.raw ->> 'currentCycle') from cma.subscription s where s.connection_id = v_sub1 and s.source_id = 'sub-paid')
             || ' ' || (select s.outcome from cma.ingest_upsert_subscriptions(v_sub1, pg_temp.v0008zl_subs('changed')) s where s.source_id = 'sub-paid');
    v_txt := v_txt || ' ' || (select (s.next_billing_at at time zone 'UTC')::date::text from cma.subscription s where s.connection_id = v_sub1 and s.source_id = 'sub-paid');
    v_rows := v_rows || array['13', 'B3 a stale subscription left as it is; a later change updated',
      case when v_txt = 'stale 4 updated 2026-12-15' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B4. the payment state of each case: failed, paused, canceled (canceled and expired), in_retry (cycle 6, its first
    --     failure, its second attempt), paid, paid again after the failed cycle was renewed, paid after a failure that a
    --     later cycle's renewal follows; merged and never-subscribed left out
    v_txt := (select string_agg(p.source_id || ':' || p.payment_state || coalesce(':' || p.retry_cycle || '/' || (p.retry_since at time zone 'UTC')::date || '/' || p.last_attempt, ''),
                                ' ' order by p.source_id)
              from cma.subscription_payment_state_of(v_t1) p);
    v_rows := v_rows || array['14', 'B4 the payment state of each case: failed, paused, canceled, in_retry, paid, paid after a renewal; merged and never-subscribed left out',
      case when v_txt = 'sub-canceled:canceled sub-expired:canceled sub-failed:failed sub-paid:paid sub-paused:paused sub-renewed:paid '
                        || 'sub-retry:in_retry:6/2026-10-25/2'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B5. a renewal of the failed cycle brings sub-retry back to paid; a later failure of the next cycle puts it in retry
    --     again; a subscription the latest full read no longer returned has no payment state
    perform cma.ingest_upsert_subscription_events(v_sub1, '[{"sourceId": "ev-20", "subscriptionSourceId": "sub-retry", "eventType": "renewed",
      "occurredAt": "2026-10-27T10:00:00.000Z", "actorType": "system", "cycleIndex": 6, "raw": {"id": "ev-20"}}]');
    v_txt := (select p.payment_state from cma.subscription_payment_state_of(v_t1) p where p.source_id = 'sub-retry');
    perform cma.ingest_upsert_subscription_events(v_sub1, '[{"sourceId": "ev-21", "subscriptionSourceId": "sub-retry", "eventType": "renew_failed",
      "occurredAt": "2026-11-25T10:00:00.000Z", "actorType": "system", "cycleIndex": 7, "attempt": 1, "errorCode": "CARD_DECLINED", "raw": {"id": "ev-21"}}]');
    v_txt := v_txt || ' ' || (select p.payment_state || ':' || p.retry_cycle from cma.subscription_payment_state_of(v_t1) p where p.source_id = 'sub-retry');
    update cma.subscription s set source_deleted_at = now() where s.connection_id = v_sub1 and s.source_id = 'sub-expired';
    v_txt := v_txt || ' ' || (select count(*) from cma.subscription_payment_state_of(v_t1) p where p.source_id = 'sub-expired');
    update cma.subscription s set source_deleted_at = null where s.connection_id = v_sub1 and s.source_id = 'sub-expired';
    v_rows := v_rows || array['15', 'B5 the failed cycle renewed: paid; the next cycle failed: in_retry again; a missing subscription has no state',
      case when v_txt = 'paid in_retry:7 0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B6. the events append-only: the application updates or deletes none (42501), deletes no subscription (42501); the
    --     same event sent again with other values is left as it was
    v_txt := pg_temp.v0008zl_code(format('update cma.subscription_event set attempt = 9 where connection_id = %L', v_sub1))
             || ' ' || pg_temp.v0008zl_code(format('delete from cma.subscription_event where connection_id = %L', v_sub1))
             || ' ' || pg_temp.v0008zl_code(format('delete from cma.subscription where connection_id = %L', v_sub1))
             || ' ' || (select e.outcome from cma.ingest_upsert_subscription_events(v_sub1, '[{"sourceId": "ev-02", "subscriptionSourceId": "sub-retry",
                          "eventType": "renewed", "occurredAt": "2026-10-25T10:00:00.000Z", "cycleIndex": 6, "raw": {"id": "ev-02"}}]') e)
             || ' ' || (select e.event_type || '/' || e.attempt from cma.subscription_event e where e.connection_id = v_sub1 and e.source_id = 'ev-02');
    v_rows := v_rows || array['16', 'B6 events append-only: no update or delete by the application, no subscription deleted; an event sent again unchanged',
      case when v_txt = '42501 42501 42501 unchanged renew_failed/1' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B7. row-level security: tenant two's Ingest user writes its own connection, never tenant one's (CMA02), and sees
    --     none of tenant one's rows; tenant one's sees none of tenant two's; the reader views show the reader's tenant only
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_ing2::text, true);
    v_txt := (select string_agg(s.outcome, ',') from cma.ingest_upsert_subscriptions(v_sub2,
               '[{"sourceId": "sub-two", "customerSourceId": "9001", "status": "active", "raw": {"id": "sub-two"}}]') s)
             || ' ' || pg_temp.v0008zl_code(format('select cma.ingest_upsert_subscriptions(%L, %L)', v_sub1,
                                                   '[{"sourceId": "sub-x", "status": "active"}]'))
             || ' ' || pg_temp.v0008zl_code(format('select cma.ingest_subscription_store(%L)', v_sub1));
    v_txt := v_txt || ' ' || (select count(*) from cma.subscription) || '/' || (select count(*) from cma.subscription_event)
             || ' ' || (select count(*) from cma.subscription_payment_state_of(v_t1));
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_ing1::text, true);
    v_txt := v_txt || ' ' || (select count(*) from cma.subscription where connection_id = v_sub2)
             || ' ' || (select count(*) from cma.subscription);
    perform set_config('role', 'cma_readonly', true);
    v_txt := v_txt || ' | ' || (select count(*) from cma_read.subscription) || '/' || (select count(*) from cma_read.subscription_event)
             || '/' || (select count(*) from cma_read.subscription_payment_state)
             || ' ' || (select count(*) from cma_read.subscription where tenant_id = v_t2);
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['17', 'B7 row-level security: each Ingest user writes and sees its own tenant only; the reader views the reader''s tenant',
      case when v_txt = 'inserted CMA02 CMA02 1/0 0 0 9 | 9/13/7 0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B8. the refusals: a connection whose handle has no store (store_not_configured), one without a token secret name
    --     and a CRM connection (CMA04); a person writes nothing (CMA06)
    v_txt := pg_temp.v0008zl_error(format('select cma.ingest_upsert_subscriptions(%L, %L)', v_nostore, '[]'))
             || ' | ' || pg_temp.v0008zl_code(format('select cma.ingest_upsert_subscription_events(%L, %L)', v_nostore, '[]'))
             || ' ' || pg_temp.v0008zl_code(format('select cma.ingest_upsert_subscriptions(%L, %L)', v_nokey, '[]'))
             || ' ' || pg_temp.v0008zl_code(format('select cma.ingest_upsert_subscriptions(%L, %L)', v_crm, '[]'))
             || ' ' || pg_temp.v0008zl_code(format('select cma.ingest_mark_subscriptions_missing(%L, array[''sub-paid''], null, null)', v_nostore));
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008zl_code(format('select cma.ingest_upsert_subscriptions(%L, %L)', v_sub1, '[]'))
             || ' ' || pg_temp.v0008zl_code(format('select cma.ingest_subscription_store(%L)', v_sub1));
    perform set_config('app.user_id', v_ing1::text, true);
    v_rows := v_rows || array['18', 'B8 refused: no store (store_not_configured), no token secret name, a CRM connection; a person writes nothing',
      case when v_txt = 'CMA04: store_not_configured | CMA04 CMA04 CMA04 CMA04 CMA06 CMA06' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B9. items out of their form, refused (CMA04): a status outside the seven, an actor id of no staff, a raw key outside
    --     the list, an @ in raw, a free-text reason, an id twice, an id with a space, more than 500
    v_txt := concat_ws(' ',
      pg_temp.v0008zl_code(format('select cma.ingest_upsert_subscriptions(%L, %L)', v_sub1, '[{"sourceId": "sub-z", "status": "cancelled"}]')),
      pg_temp.v0008zl_code(format('select cma.ingest_upsert_subscription_events(%L, %L)', v_sub1,
        '[{"sourceId": "ev-z", "subscriptionSourceId": "sub-z", "eventType": "paused", "occurredAt": "2026-10-01T00:00:00Z", "actorType": "customer", "actorSourceId": "c-1"}]')),
      pg_temp.v0008zl_code(format('select cma.ingest_upsert_subscriptions(%L, %L)', v_sub1,
        '[{"sourceId": "sub-z", "status": "active", "raw": {"id": "sub-z", "deliveryAddress": "x"}}]')),
      pg_temp.v0008zl_code(format('select cma.ingest_upsert_subscriptions(%L, %L)', v_sub1,
        '[{"sourceId": "sub-z", "status": "active", "raw": {"id": "sub-z", "customer": "someone@example.invalid"}}]')),
      pg_temp.v0008zl_code(format('select cma.ingest_upsert_subscription_events(%L, %L)', v_sub1,
        '[{"sourceId": "ev-z", "subscriptionSourceId": "sub-z", "eventType": "canceled", "occurredAt": "2026-10-01T00:00:00Z", "reasonCode": "Too expensive for me"}]')),
      pg_temp.v0008zl_code(format('select cma.ingest_upsert_subscriptions(%L, %L)', v_sub1,
        '[{"sourceId": "sub-z", "status": "active"}, {"sourceId": "sub-z", "status": "paused"}]')),
      pg_temp.v0008zl_code(format('select cma.ingest_upsert_subscriptions(%L, %L)', v_sub1, '[{"sourceId": "sub z", "status": "active"}]')),
      pg_temp.v0008zl_code(format('select cma.ingest_upsert_subscriptions(%L, %L)', v_sub1,
        (select jsonb_agg(jsonb_build_object('sourceId', 'sub-n' || g, 'status', 'active')) from generate_series(1, 501) g))),
      (select count(*) from cma.subscription where source_id ~ '^sub-(z|n[0-9]+)$')::text);
    v_rows := v_rows || array['19', 'B9 items out of form refused: a status, an actor id of no staff, a raw key, an @, a free-text reason, twice, a space, 501',
      case when v_txt = 'CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B10. the final step in slices: of the nine, a full read returned seven (sub-merged and sub-never not); two slices
    --      mark the two missing; a slice with an id outside its range or bounds out of order marks nothing (CMA04); the
    --      next full read brings them back
    j := cma.ingest_mark_subscriptions_missing(v_sub1, array['sub-canceled', 'sub-expired', 'sub-failed', 'sub-paid'], null, 'sub-paused');
    v_txt := (j ->> 'missing_now');
    j := cma.ingest_mark_subscriptions_missing(v_sub1, array['sub-paused', 'sub-renewed', 'sub-retry'], 'sub-paused', null);
    v_txt := v_txt || ' ' || (j ->> 'missing_now')
             || ' ' || (select string_agg(s.source_id, ',' order by s.source_id) from cma.subscription s
                        where s.connection_id = v_sub1 and s.source_deleted_at is not null)
             || ' ' || pg_temp.v0008zl_code(format('select cma.ingest_mark_subscriptions_missing(%L, array[''sub-retry''], null, ''sub-paused'')', v_sub1))
             || ' ' || pg_temp.v0008zl_code(format('select cma.ingest_mark_subscriptions_missing(%L, array[''sub-retry''], ''sub-z'', ''sub-a'')', v_sub1))
             || ' ' || pg_temp.v0008zl_code(format('select cma.ingest_mark_subscriptions_missing(%L, array[]::text[], null, null)', v_sub1))
             || ' ' || pg_temp.v0008zl_code(format('select cma.ingest_mark_subscriptions_missing(%L, array[''a@b''], null, null)', v_sub1));
    v_txt := v_txt || ' ' || (select string_agg(s.outcome, ',' order by s.source_id) from cma.ingest_upsert_subscriptions(v_sub1, pg_temp.v0008zl_subs('changed')) s
                              where s.source_id in ('sub-merged', 'sub-never'));
    v_txt := v_txt || ' ' || (select count(*) from cma.subscription s where s.connection_id = v_sub1 and s.source_deleted_at is not null);
    v_rows := v_rows || array['20', 'B10 the final step in slices marks what the full read did not return; out of range refused; the next read brings them back',
      case when v_txt = '2 0 sub-merged,sub-never CMA04 CMA04 CMA04 CMA04 updated,updated 0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B11. the settings on the subscriptions connection (tenant.configure): in range kept, out of range refused (CMA04);
    --      on another kind's connection the keys are not checked
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := pg_temp.v0008zl_code(format('select cma.set_connection_settings(%L, %L)', v_sub1, '{"juo_poll_interval_minutes": 5, "juo_max_per_second": 2}'))
             || ' ' || pg_temp.v0008zl_code(format('select cma.set_connection_settings(%L, %L)', v_sub1, '{"juo_poll_interval_minutes": 61}'))
             || ' ' || pg_temp.v0008zl_code(format('select cma.set_connection_settings(%L, %L)', v_sub1, '{"juo_max_per_second": 11}'))
             || ' ' || pg_temp.v0008zl_code(format('select cma.set_connection_settings(%L, %L)', v_crm, '{"juo_max_per_second": 11}'));
    v_txt := v_txt || ' ' || (select c.settings::text from cma.integration_connection c where c.id = v_sub1);
    v_rows := v_rows || array['21', 'B11 the settings: the poll interval from 1 to 60 and the pace from 1 to 10 on a subscriptions connection',
      case when v_txt = 'ok CMA04 CMA04 ok {"juo_max_per_second": 2, "juo_poll_interval_minutes": 5}' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B12. the kinds: a connection holding subscriptions is of kind subscriptions only (CMA03 for another kind); its held
    --      kinds are subscriptions
    v_txt := pg_temp.v0008zl_code(format('select cma.set_connection_kind(%L, ''commerce'')', v_sub1))
             || ' ' || array_to_string(cma.connection_held_kinds_of(v_t1, v_sub1), ',')
             || ' ' || pg_temp.v0008zl_code(format('select cma.set_connection_kind(%L, ''subscriptions'')', v_sub1));
    perform set_config('app.user_id', v_ing1::text, true);
    v_rows := v_rows || array['22', 'B12 the kinds: a connection holding subscriptions is of kind subscriptions only',
      case when v_txt = 'CMA03 subscriptions ok' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B13. the run's counts: the poll's run (job subscriptions_poll) takes events_new, customers_unmatched and
    --      reason_dropped; another key is refused (CMA04)
    v_run := cma.ingest_sync_run_start(v_sub1, 'subscriptions_poll', 'subscriptions', null, now());
    v_txt := pg_temp.v0008zl_code(format('select cma.ingest_sync_run_finish(%L, ''succeeded'', %L)', v_run,
               '{"fetched": 20, "inserted": 9, "updated": 0, "unchanged": 0, "missing_now": 0, "events_new": 11, "customers_unmatched": 1, "reason_dropped": 2, "upserted": 9, "skipped": 0}'));
    v_txt := v_txt || ' ' || (select r.job || '/' || r.stream || '/' || r.status || '/' || (r.counts ->> 'events_new') || '/' || (r.counts ->> 'customers_unmatched')
                               || '/' || (r.counts ->> 'reason_dropped') from cma.sync_run r where r.id = v_run);
    v_run := cma.ingest_sync_run_start(v_sub1, 'subscriptions_poll', 'subscriptions', null, now());
    v_txt := v_txt || ' ' || pg_temp.v0008zl_code(format('select cma.ingest_sync_run_finish(%L, ''succeeded'', %L)', v_run, '{"events_old": 1}'));
    v_rows := v_rows || array['23', 'B13 the run: job subscriptions_poll with events_new, customers_unmatched and reason_dropped; another key refused',
      case when v_txt = 'ok subscriptions_poll/subscriptions/succeeded/11/1/2 CMA04' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B14. audit rows written for both tables, naming the Ingest user: inserts of every subscription and event, the
    --      updates of B3 and B10 (as the owner, who reads the audit log)
    perform set_config('role', 'cma_owner', true);
    v_txt := (select string_agg(a.table_name || ':' || a.action || ':' || a.n, ' ' order by a.table_name, a.action)
              from (select a.table_name, a.action, count(*) as n from cma.audit_log a
                    where a.tenant_id = v_t1 and a.table_name in ('subscription', 'subscription_event') group by 1, 2) a)
             || ' ' || (select string_agg(distinct (a.actor_user_id = v_ing1)::text, ',') from cma.audit_log a
                        where a.tenant_id = v_t1 and a.table_name in ('subscription', 'subscription_event') and a.action = 'insert');
    v_rows := v_rows || array['24', 'B14 audit rows for both tables: every insert and update, the inserts by the Ingest user',
      case when v_txt like 'subscription:insert:9 subscription:update:% subscription_event:insert:13 true'
                and v_txt not like '%subscription_event:update%' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B15. no column of either table holding an email pattern after the fixtures: every row's JSON, both tenants, and the
    --      audit rows of both tables
    v_txt := (select count(*) from cma.subscription s where s.tenant_id in (v_t1, v_t2) and to_jsonb(s)::text ~ v_email)
             || ' ' || (select count(*) from cma.subscription_event e where e.tenant_id in (v_t1, v_t2) and to_jsonb(e)::text ~ v_email)
             || ' ' || (select count(*) from cma.audit_log a where a.tenant_id in (v_t1, v_t2) and a.table_name in ('subscription', 'subscription_event')
                          and (coalesce(a.new_row::text, '') || coalesce(a.old_row::text, '')) ~ v_email)
             || ' ' || (select count(*) from cma.subscription s where s.tenant_id in (v_t1, v_t2))
             || '/' || (select count(*) from cma.subscription_event e where e.tenant_id in (v_t1, v_t2));
    v_rows := v_rows || array['25', 'B15 no column of either table, and no audit row of theirs, holding an email pattern after the fixtures',
      case when v_txt = '0 0 0 10/13' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['59', 'B the block ran to the end', 'FAIL', sqlstate || ': ' || sqlerrm];
  end;
  insert into verify_0008zl (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008zl values (59, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Z. Every subscription and event row of the database (dev or local: the flow verifier's fixtures and anything the poll
--    wrote): no column holding an email pattern. Counts only
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_dev     boolean := current_setting('verify.dev')::boolean;
  v_email   text := current_setting('verify.email_pattern');
  v_txt     text;
begin
  if not v_dev then
    insert into verify_0008zl values (61, 'Z1 a dev or local database (the dev seed''s agent.two@example.com active)', 'FAIL',
      'REFUSED: no dev seed, so this is no dev or local database; nothing read');
    return;
  end if;
  v_txt := (select count(*) from cma.subscription s where to_jsonb(s)::text ~ v_email) || ' of ' || (select count(*) from cma.subscription)
           || ' subscriptions, ' || (select count(*) from cma.subscription_event e where to_jsonb(e)::text ~ v_email) || ' of '
           || (select count(*) from cma.subscription_event) || ' events';
  insert into verify_0008zl values (61, 'Z1 every subscription and event row of the database: no column holding an email pattern',
    case when v_txt like '0 of % subscriptions, 0 of % events' and not v_provoke then 'PASS' else 'FAIL' end, v_txt);
end
$$;

-- The helpers are dropped first, so the verdict is the last thing the script prints
drop function if exists pg_temp.v0008zl_code(text);
drop function if exists pg_temp.v0008zl_error(text);
drop function if exists pg_temp.v0008zl_subs(text);
drop function if exists pg_temp.v0008zl_events();

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008zl
      union all
      select 99, 'verdict',
             case when not current_setting('verify.dev')::boolean then 'REFUSED'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008zl where result = 'PASS') = 23
                       and not exists (select 1 from verify_0008zl where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('119_verify_subscriptions: %s PASS, %s FAIL', (select count(*) from verify_0008zl where result = 'PASS'),
                                                                 (select count(*) from verify_0008zl where result <> 'PASS'))) x
order by ord;
reset role;
