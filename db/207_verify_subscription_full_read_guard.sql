-- =============================================================================================
-- 207_verify_subscription_full_read_guard.sql: verifies addition 0009zc, the subscriptions full read's guard counts and
-- the audit's findings (brief B39 continued, Part B39a2)
-- =============================================================================================
-- Dev and local databases only, as 205: it refuses a database without the dev seed (no active agent.two@example.com):
-- block B's checks then read FAIL and the verdict REFUSED. Block A only reads; block B works on a throwaway tenant inside
-- a subtransaction that is always rolled back, so nothing stays. It writes the scenario's rows as the owner, directly,
-- and finishes its runs as the tenant's Ingest user (cma_app). Every check writes one row, PASS or FAIL, and the last row
-- is the verdict, because Cloud SQL Studio shows no notices. Run as your own IAM login after
-- 206_subscription_full_read_guard.sql, in dev; then 205_verify_subscription_audit.sql (edited by 206) and the verifies
-- 206's header names. Adapters, handles, ids, codes and secret names are invented data values; no row carries a name, an
-- address, an email or a phone number.
--   A  the addition row after 0009zb; the audit still the owner's only, in the caller's rights, stable, jit off; the run
--      finish the application's
--   B  on a throwaway tenant with three stores: a run finishes with missing_confirmed and missing_reappeared (stored) and
--      refuses an unknown count (CMA04); a store whose subscriptions are all paused or ended has no hole in its months,
--      and the same store with one subscription that renews has one (fail); billing_link links a chargeback through a
--      purchase's store order (raw orderId) and through a store order of kind first, reports another store order of a
--      customer with a subscription apart and leaves one with no such order unlinked; after_chargeback follows those links;
--      status_chain's expected text names the pause without an event
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
-- dev or a local database only: the dev seed's agent.two@example.com active, as 203 and 205
select set_config('verify.dev', (select exists (select 1 from cma.app_user u where u.email = 'agent.two@example.com' and u.status = 'active'))::text, false);

drop table if exists pg_temp.verify_0009zc;
create temp table verify_0009zc (ord int, check_name text, result text, detail text);

-- The error a statement raises as its SQLSTATE, or 'ok'
create or replace function pg_temp.v0009zc_code(p_sql text)
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

-- A store's value or verdict of one check
create or replace function pg_temp.v0009zc_row(p_tenant uuid, p_store text, p_key text)
returns text
language sql
as $$
  select a.value || ' | ' || a.verdict from cma.subscription_audit_of(p_tenant) a where a.store = p_store and a.check_key = p_key
$$;

-- A. Structure and privileges
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_txt     text;
begin
  -- A1. the addition is recorded, after 0009zb
  insert into verify_0009zc values (1, 'A1 addition 0009zc recorded, after 0009zb',
    case when exists (select 1 from cma.schema_migration where version = '0009zc')
              and exists (select 1 from cma.schema_migration where version = '0009zb') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the audit made again keeps its rights: the owner's, in the caller's rights, stable, jit off, executable by no
  --     application, reader, BigQuery login or public; the run finish still the application's
  v_txt := (select pg_get_userbyid(p.proowner) || ':' || p.prosecdef || ':' || p.provolatile::text || ':' || coalesce(array_to_string(p.proconfig, ','), '-')
                   || ':' || has_function_privilege('cma_app', p.oid, 'execute') || ':' || has_function_privilege('cma_readonly', p.oid, 'execute')
                   || ':' || has_function_privilege('bq_reader', p.oid, 'execute') || ':' || has_function_privilege('public', p.oid, 'execute')
            from pg_proc p where p.oid = 'cma.subscription_audit_of(uuid)'::regprocedure)
           || ' | ' || has_function_privilege('cma_app', 'cma.ingest_sync_run_finish(uuid,text,jsonb,text)', 'execute');
  insert into verify_0009zc values (2, 'A2 the audit the owner''s only, security invoker, stable, jit off; the run finish the application''s',
    case when v_txt = 'cma_owner:false:s:jit=off:false:false:false:false | true' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'missing'));
end
$$;

-- B. Behaviour on a throwaway tenant (rolled back)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_dev     boolean := current_setting('verify.dev')::boolean;
  v_rows    text[] := '{}';
  v_t uuid; v_ing uuid;
  v_shop_p uuid; v_sub_p uuid; v_shop_f uuid; v_sub_f uuid;
  v_run1 uuid; v_run2 uuid;
  v_m0 timestamp := date_trunc('month', now() at time zone 'Europe/London') - interval '6 months';
  v_txt text;
begin
  if not v_dev then
    insert into verify_0009zc values (59, 'B a dev or local database (the dev seed''s agent.two@example.com active)', 'FAIL',
      'REFUSED: no dev seed, so this is no dev or local database; nothing ran');
    return;
  end if;
  begin
    v_t := cma.create_tenant('verify-0009zc-one', 'Verify 0009zc one', 'Europe/London');
    select x.user_id into v_ing from cma.app_user_external_id x where x.tenant_id = v_t and x.system = 'ingest' and x.external_id = 'ingest';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, signing_secret_name)
    values (v_t, 'verifyshop', 'Verify shop P', 'verify-zc-p.shop.example', 'commerce', 'verify-zc-shop-1') returning id into v_shop_p;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t, 'verifysubs', 'Verify subscriptions P', 'verify-zc-p.shop.example', 'subscriptions', 'verify-zc-key-1') returning id into v_sub_p;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, signing_secret_name)
    values (v_t, 'verifyshop', 'Verify shop F', 'verify-zc-f.shop.example', 'commerce', 'verify-zc-shop-2') returning id into v_shop_f;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, token_secret_name)
    values (v_t, 'verifysubs', 'Verify subscriptions F', 'verify-zc-f.shop.example', 'subscriptions', 'verify-zc-key-2') returning id into v_sub_f;
    insert into cma.commerce_store (tenant_id, connection_id, handle, name, market, currency, time_zone)
    values (v_t, v_shop_p, 'verify-zc-p', 'Verify store P', 'IE', 'EUR', 'Europe/London'),
           (v_t, v_shop_f, 'verify-zc-f', 'Verify store F', 'DE', 'EUR', 'Europe/London');

    -- B1. a run finishes with the guard's two counts, stored; an unknown count is refused
    insert into cma.sync_run (tenant_id, connection_id, job, stream) values (v_t, v_sub_f, 'reconcile', 'subscription') returning id into v_run1;
    insert into cma.sync_run (tenant_id, connection_id, job, stream) values (v_t, v_sub_f, 'reconcile', 'subscription') returning id into v_run2;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('app.user_id', v_ing::text, true);
    v_txt := pg_temp.v0009zc_code(format($q$select cma.ingest_sync_run_finish(%L, 'succeeded', '{"fetched": 230, "missing_now": 1, "missing_confirmed": 1, "missing_reappeared": 6}'::jsonb)$q$, v_run1))
             || ' ' || pg_temp.v0009zc_code(format($q$select cma.ingest_sync_run_finish(%L, 'succeeded', '{"missing_lost": 1}'::jsonb)$q$, v_run2));
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || ' | ' || (select r.status || ' ' || (r.counts ->> 'missing_confirmed') || ' ' || (r.counts ->> 'missing_reappeared') from cma.sync_run r where r.id = v_run1)
             || ' | ' || (select r.status from cma.sync_run r where r.id = v_run2);
    v_rows := v_rows || array['11', 'B1 a run finishes with missing_confirmed and missing_reappeared, stored; an unknown count refused (CMA04), its run left running',
      case when v_txt = 'ok CMA04 | succeeded 1 6 | running' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'none')];

    -- B2. store P: one subscription paused since month 1, one canceled in month 1; events in months 0 and 1 only. No
    --     subscription renews from month 2 on, so its months without an event are no hole (ok); with one active
    --     subscription created in month 0 they are (fail)
    insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, billing_interval,
                                  billing_interval_count, currency, source_created_at, paused_at, canceled_at)
    values (v_t, v_sub_p, 'verifysubs', 'p1', 'c1', 'paused', 'month', 1, 'EUR', (v_m0 + interval '1 day') at time zone 'Europe/London',
            (v_m0 + interval '1 month 2 days') at time zone 'Europe/London', null),
           (v_t, v_sub_p, 'verifysubs', 'p2', 'c2', 'canceled', 'month', 1, 'EUR', (v_m0 + interval '2 days') at time zone 'Europe/London',
            null, (v_m0 + interval '1 month 3 days') at time zone 'Europe/London');
    insert into cma.subscription_event (tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type, occurred_at,
                                        status_from, status_to, cycle_index, order_source_id)
    values (v_t, v_sub_p, 'verifysubs', 'pe1', 'p1', 'purchased', (v_m0 + interval '1 day') at time zone 'Europe/London', null, null, null, null),
           (v_t, v_sub_p, 'verifysubs', 'pe2', 'p2', 'purchased', (v_m0 + interval '2 days') at time zone 'Europe/London', null, null, null, null),
           (v_t, v_sub_p, 'verifysubs', 'pe3', 'p1', 'renewed', (v_m0 + interval '1 month 1 day') at time zone 'Europe/London', null, null, 2, '300001'),
           (v_t, v_sub_p, 'verifysubs', 'pe4', 'p1', 'paused', (v_m0 + interval '1 month 2 days') at time zone 'Europe/London', 'active', 'paused', null, null),
           (v_t, v_sub_p, 'verifysubs', 'pe5', 'p2', 'canceled', (v_m0 + interval '1 month 3 days') at time zone 'Europe/London', 'active', 'canceled', null, null);
    v_txt := split_part(pg_temp.v0009zc_row(v_t, 'IE', 'events_by_month'), '; ', 2) || ' ' || split_part(pg_temp.v0009zc_row(v_t, 'IE', 'events_by_month'), ' | ', 2);
    insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, billing_interval,
                                  billing_interval_count, currency, source_created_at)
    values (v_t, v_sub_p, 'verifysubs', 'p3', 'c3', 'active', 'month', 1, 'EUR', (v_m0 + interval '3 days') at time zone 'Europe/London');
    v_txt := v_txt || ' | ' || split_part(pg_temp.v0009zc_row(v_t, 'IE', 'events_by_month'), ' | ', 2)
             || ' ' || (split_part(pg_temp.v0009zc_row(v_t, 'IE', 'events_by_month'), '; ', 2) like 'no event: ' || to_char(v_m0 + interval '2 months', 'YYYY-MM') || '%')::text;
    v_rows := v_rows || array['12', 'B2 a store whose subscriptions are all paused or ended has no hole in its months (ok); one active subscription makes them holes (fail)',
      case when v_txt = 'no event: none ok | fail true' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'none')];

    -- B3. store F: s1 purchased with its store order 500001 in raw (a chargeback on it: first order, through the purchase);
    --     s2's customer's store order 500002 of kind first (first order, through the store order); s3's customer's store
    --     order 500003 of kind repeat (other store order); 500009 no order of the store (unlinked). s1 renews within 30
    --     days of its chargeback
    insert into cma.subscription (tenant_id, connection_id, source_system, source_id, customer_source_id, status, billing_interval,
                                  billing_interval_count, currency, source_created_at)
    values (v_t, v_sub_f, 'verifysubs', 'f1', 'd1', 'active', 'month', 1, 'EUR', (v_m0 + interval '1 day') at time zone 'Europe/London'),
           (v_t, v_sub_f, 'verifysubs', 'f2', 'd2', 'active', 'month', 1, 'EUR', (v_m0 + interval '2 days') at time zone 'Europe/London'),
           (v_t, v_sub_f, 'verifysubs', 'f3', 'd3', 'active', 'month', 1, 'EUR', (v_m0 + interval '3 days') at time zone 'Europe/London');
    insert into cma.subscription_event (tenant_id, connection_id, source_system, source_id, subscription_source_id, event_type, occurred_at,
                                        cycle_index, order_source_id, raw)
    values (v_t, v_sub_f, 'verifysubs', 'fe1', 'f1', 'purchased', (v_m0 + interval '1 day') at time zone 'Europe/London', null, null,
            '{"id": "fe1", "type": "subscription:purchased", "orderId": "500001"}'::jsonb),
           (v_t, v_sub_f, 'verifysubs', 'fe2', 'f1', 'renewed', (v_m0 + interval '1 month 1 day') at time zone 'Europe/London', 2, '500011', '{}'::jsonb);
    insert into cma.commerce_order (tenant_id, connection_id, source_system, source_id, customer_source_id, source_created_at, order_kind)
    values (v_t, v_shop_f, 'verifyshop', '500002', 'd2', (v_m0 + interval '2 days') at time zone 'Europe/London', 'first'),
           (v_t, v_shop_f, 'verifyshop', '500003', 'd3', (v_m0 + interval '20 days') at time zone 'Europe/London', 'repeat');
    insert into cma.billing_event (tenant_id, connection_id, source_system, source_id, kind, occurred_at, order_source_id, amount, currency)
    values (v_t, v_sub_f, 'verifysubs', 'fb1', 'chargeback', (v_m0 + interval '10 days') at time zone 'Europe/London', '500001', 30.00, 'EUR'),
           (v_t, v_sub_f, 'verifysubs', 'fb2', 'chargeback', (v_m0 + interval '10 days') at time zone 'Europe/London', '500002', 30.00, 'EUR'),
           (v_t, v_sub_f, 'verifysubs', 'fb3', 'chargeback', (v_m0 + interval '25 days') at time zone 'Europe/London', '500003', 30.00, 'EUR'),
           (v_t, v_sub_f, 'verifysubs', 'fb4', 'chargeback', (v_m0 + interval '25 days') at time zone 'Europe/London', '500009', 30.00, 'EUR');
    v_txt := pg_temp.v0009zc_row(v_t, 'DE', 'billing_link');
    v_rows := v_rows || array['13', 'B3 billing_link: a chargeback on a purchase''s store order and one on a store order of kind first are first order; another store order of a customer with a subscription apart; one without such an order unlinked (explain)',
      case when v_txt = 'chargebacks: subscription 0, renewal order 0, first order 2, other store order 1, unlinked 1; refund events: subscription 0, renewal order 0, first order 0, other store order 0, unlinked 0 | explain'
                and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'none')];

    -- B4. after_chargeback follows those links: f1 renewed within 30 days; f2 and f3 nothing (the unlinked one not counted)
    v_txt := pg_temp.v0009zc_row(v_t, 'DE', 'after_chargeback');
    v_rows := v_rows || array['14', 'B4 after_chargeback follows the first-order and store-order links: renewed 1, nothing 2',
      case when v_txt = 'renewed 1, failed renewal 0, moved to failed 0, canceled 0, expired 0, nothing 2, under 30 days 0 | ok' and not v_provoke
           then 'PASS' else 'FAIL' end, coalesce(v_txt, 'none')];

    -- B5. status_chain's expected text names what a pair is and the pause without an event
    v_txt := (select a.expected from cma.subscription_audit_of(v_t) a where a.check_key = 'status_chain' and a.store = 'DE');
    v_rows := v_rows || array['15', 'B5 status_chain''s expected text: the pair''s order and the pause that began or ended on its date without an event',
      case when v_txt like '0, or explained: a pair reads the latest status event''s status > the subscription''s; active>paused or paused>active is a pause that began or ended on its date without a paused or resumed event'
                and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'none')];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['59', 'B the block ran to the end', 'FAIL', sqlstate || ': ' || sqlerrm];
  end;
  insert into verify_0009zc (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0009zc values (59, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- The helpers are dropped first, so the verdict is the last thing the script prints
drop function if exists pg_temp.v0009zc_code(text);
drop function if exists pg_temp.v0009zc_row(uuid, text, text);

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0009zc
      union all
      select 99, 'verdict',
             case when not current_setting('verify.dev')::boolean then 'REFUSED'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0009zc where result = 'PASS') = 7
                       and not exists (select 1 from verify_0009zc where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('207_verify_subscription_full_read_guard: %s PASS, %s FAIL', (select count(*) from verify_0009zc where result = 'PASS'),
                                                                                (select count(*) from verify_0009zc where result <> 'PASS'))) x
order by ord;
reset role;
