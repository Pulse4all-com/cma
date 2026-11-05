-- Local only: two stores in a throwaway tenant, one with subscriptions (GB) and one without (NL): does Flash show the
-- empty market as zeros, not as "not set up"? Rolled back at the end.
\set ON_ERROR_STOP on
begin;
set role cma_owner;
select cma.create_tenant('verify-n05-flash', 'Verify N05 Flash', 'Europe/Amsterdam') as t \gset
insert into cma.app_user (tenant_id, email, display_name) values (:'t', 'verify-n05-admin@example.invalid', 'admin') returning id as admin \gset
insert into cma.user_role (tenant_id, user_id, role_id) select :'t', :'admin', id from cma.app_role where tenant_id = :'t' and key = 'admin';
select u.id as ing from cma.app_user_external_id x join cma.app_user u on u.tenant_id = x.tenant_id and u.id = x.user_id where x.tenant_id = :'t' and x.system = 'ingest' and x.external_id = 'ingest' \gset
insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, signing_secret_name) values (:'t', 'shopify', 'Shopify GB (test)', 'n05-gb.myshopify.com', 'commerce', 'verify-shop-signing') returning id as shop_gb \gset
insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind, signing_secret_name) values (:'t', 'shopify', 'Shopify NL (test)', 'n05-nl.myshopify.com', 'commerce', 'verify-shop-signing') returning id as shop_nl \gset
insert into cma.commerce_store (tenant_id, connection_id, handle, name, market, currency, time_zone) values (:'t', :'shop_gb', 'n05-gb', 'Verify GB', 'GB', 'GBP', 'Europe/London'), (:'t', :'shop_nl', 'n05-nl', 'Verify NL', 'NL', 'EUR', 'Europe/Amsterdam');
insert into cma.commerce_customer (tenant_id, connection_id, source_system, source_id) values (:'t', :'shop_gb', 'shopify', '9001'), (:'t', :'shop_gb', 'shopify', '9002'), (:'t', :'shop_nl', 'shopify', '9101');
-- the runbook's 15.10 (c) block, two handles
set role cma_app;
select set_config('app.tenant_id', :'t', false), set_config('app.user_id', :'admin', false), set_config('app.actor_label', 'verify:n05', false);
select cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', null, null, 10), cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR', null, null, 20);
create temp table new_juo as
select v.handle, v.cc, c.connection_id, c.key
from (values ('n05-gb', 'GB'), ('n05-nl', 'NL')) v(handle, cc)
cross join lateral cma.upsert_connection('juo', 'Juo ' || v.cc, v.handle || '.myshopify.com', null, 'ingest-juo-' || v.handle || '-key') c;
select cma.set_connection_kind(connection_id, 'subscriptions') from new_juo;
select cma.set_connection_settings(connection_id, '{"subscriptions_poll_interval_minutes": 5, "subscriptions_max_per_second": 2}'::jsonb) from new_juo;
select n.handle, n.cc, s.name,
       s.kind = 'subscriptions' and s.status = 'active' and s.external_account_id = n.handle || '.myshopify.com'
         and s.token_secret_name = 'ingest-juo-' || n.handle || '-key' and s.signing_secret_name is null as ok,
       x.handle as store_handle, x.store_connection_id is not null as store_found
from new_juo n
left join cma.sources() s on s.connection_id = n.connection_id and s.key = n.key
left join cma.subscription_store_connection_of(current_setting('app.tenant_id')::uuid, n.connection_id) x on true
order by n.handle;
-- rerun: the same ids come back
select count(*) as same_ids from new_juo n join cma.upsert_connection('juo', 'Juo ' || n.cc, n.handle || '.myshopify.com', null, 'ingest-juo-' || n.handle || '-key') c on c.connection_id = n.connection_id;
select connection_id as juo_gb from new_juo where cc = 'GB' \gset
-- subscriptions for GB only, as the ingest user
select set_config('app.user_id', :'ing', false);
select s.outcome, count(*) from cma.ingest_upsert_subscriptions(:'juo_gb', '[
 {"sourceId":"n05-s1","customerSourceId":"9001","status":"active","currentCycle":4,"nextBillingAt":"2026-12-15T10:00:00.000Z","billingInterval":"month","billingIntervalCount":1,"amountPerCycle":29.95,"currency":"GBP","paymentInstrumentType":"card","sourceCreatedAt":"2025-01-10T09:00:00.000Z","sourceUpdatedAt":"2026-10-20T09:00:00.000Z","raw":{"id":"n05-s1","status":"ACTIVE"}},
 {"sourceId":"n05-s2","customerSourceId":"9002","status":"paused","currentCycle":2,"billingInterval":"month","billingIntervalCount":1,"amountPerCycle":29.95,"currency":"GBP","paymentInstrumentType":"card","sourceCreatedAt":"2025-02-10T09:00:00.000Z","sourceUpdatedAt":"2026-10-20T09:00:00.000Z","raw":{"id":"n05-s2","status":"PAUSED"}},
 {"sourceId":"n05-s3","customerSourceId":"9002","status":"canceled","currentCycle":7,"billingInterval":"month","billingIntervalCount":1,"amountPerCycle":29.95,"currency":"GBP","paymentInstrumentType":"card","sourceCreatedAt":"2025-03-10T09:00:00.000Z","canceledAt":"2026-10-19T09:00:00.000Z","sourceUpdatedAt":"2026-10-20T09:00:00.000Z","raw":{"id":"n05-s3","status":"CANCELED"}}
]'::jsonb) s group by 1;
-- a succeeded run per Juo connection, so Flash has a last read (as the ingest user, through the ingest's own functions)
select cma.ingest_sync_run_finish(cma.ingest_sync_run_start(connection_id, 'subscriptions_poll', 'subscriptions', null, null), 'succeeded', '{"fetched": 0}'::jsonb) from new_juo;
select set_config('app.user_id', :'admin', false);
\echo === flash_sources_of: subscriptions set_up and last_read_at
select cma.flash_sources_of(:'t') -> 'subscriptions' as subscriptions_source, cma.flash_sources_of(:'t') -> 'commerce' as commerce_source;
\echo === flash_page: the market list and set_up per overview
select p -> 'markets' as markets, (select jsonb_agg(jsonb_build_object('key', o ->> 'key', 'set_up', o -> 'set_up', 'value', o -> 'value')) from jsonb_array_elements(p -> 'overviews') o where o ->> 'key' in ('customers', 'subscriptions', 'churn', 'payments')) as overviews
from cma.flash_page() p;
\echo === flash_page('NL'): set_up per overview for the empty market
select (select jsonb_agg(jsonb_build_object('key', o ->> 'key', 'set_up', o -> 'set_up', 'value', o -> 'value')) from jsonb_array_elements(p -> 'overviews') o where o ->> 'key' in ('customers', 'subscriptions', 'churn', 'payments')) as overviews
from cma.flash_page('NL') p;
\echo === flash_overview per overview and market: set_up, totals, rows
select o.key as overview, m.market, d -> 'set_up' as set_up, d -> 'totals' as totals, jsonb_array_length(d -> 'rows') as rows
from (values ('customers'), ('subscriptions'), ('churn'), ('payments')) o(key)
cross join (values ('GB'), ('NL'), (null)) m(market)
cross join lateral cma.flash_overview(o.key, m.market) d
order by 1, 2;
\echo === the subscriptions overview, all markets: every row
select r -> 'dims' as dims, r -> 'measures' as measures from jsonb_array_elements(cma.flash_overview('subscriptions') -> 'rows') r order by (r -> 'dims')::text;
\echo === the customers overview, all markets: the market rows
select r -> 'dims' as dims, r -> 'measures' as measures from jsonb_array_elements(cma.flash_overview('customers') -> 'rows') r order by (r -> 'dims')::text;
rollback;
