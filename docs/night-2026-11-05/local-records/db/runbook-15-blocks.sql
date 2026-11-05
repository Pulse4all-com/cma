\set ON_ERROR_STOP off
\echo ===== block 2
set role cma_owner;
with t as (select id from cma.tenant where slug = :'slug'),
j as (select c.id, c.name from cma.integration_connection c where c.tenant_id = (select id from t) and c.adapter = 'juo' and c.status = 'active')
select j.name, r.job, r.stream, r.status, r.error, r.counts, r.started_at, r.finished_at
from j join cma.sync_run r on r.tenant_id = (select id from t) and r.connection_id = j.id
where r.job = 'backfill' and r.started_at > now() - interval '12 hours'
order by j.name, r.started_at;
with t as (select id from cma.tenant where slug = :'slug'),
j as (select c.id, c.name from cma.integration_connection c where c.tenant_id = (select id from t) and c.adapter = 'juo' and c.status = 'active')
select j.name, s.status, count(*) as subscriptions, count(*) filter (where s.customer_source_id is null) as without_customer,
       count(*) filter (where s.payment_instrument_type is null) as instrument_unknown
from j join cma.subscription s on s.tenant_id = (select id from t) and s.connection_id = j.id and s.source_deleted_at is null
group by 1, 2 order by 1, 2;
with t as (select id from cma.tenant where slug = :'slug'),
j as (select c.id, c.name from cma.integration_connection c where c.tenant_id = (select id from t) and c.adapter = 'juo' and c.status = 'active')
select j.name, e.event_type, count(*) as events, min(e.occurred_at)::date as first, max(e.occurred_at)::date as last
from j join cma.subscription_event e on e.tenant_id = (select id from t) and e.connection_id = j.id
group by 1, 2 order by 1, 2;
with t as (select id from cma.tenant where slug = :'slug'),
j as (select c.id, c.name from cma.integration_connection c where c.tenant_id = (select id from t) and c.adapter = 'juo' and c.status = 'active')
select j.name, p.payment_state, count(*) as subscriptions
from cma.subscription_payment_state_of((select id from t)) p join j on j.id = p.connection_id
group by 1, 2 order by 1, 2;
with t as (select id from cma.tenant where slug = :'slug')
select count(*) filter (where to_jsonb(s)::text ~ '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}') as subscriptions_with_an_email,
       (select count(*) from cma.subscription_event e where e.tenant_id = (select id from t)
          and to_jsonb(e)::text ~ '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}') as events_with_an_email
from cma.subscription s where s.tenant_id = (select id from t);
reset role;
\echo ===== block 3
set role cma_owner;
with t as (select id from cma.tenant where slug = :'slug'),
j as (select c.id, c.name from cma.integration_connection c where c.tenant_id = (select id from t) and c.adapter = 'juo' and c.status = 'active')
select j.name, r.status, r.error, r.counts ->> 'fetched' as fetched, r.counts ->> 'events_new' as events_new, r.counts ->> 'updated' as updated,
       r.counts ->> 'inserted' as inserted, r.started_at
from j join cma.sync_run r on r.tenant_id = (select id from t) and r.connection_id = j.id
where r.job = 'subscriptions_poll' and r.started_at > now() - interval '15 minutes'
order by j.name, r.started_at;
reset role;
\echo ===== block 4
set role cma_owner;
select s.handle, s.market, count(cu.id) as customers_held,
       count(cu.id) filter (where cu.orders_count >= 1) as with_an_order,
       count(cu.id) filter (where cu.crm_contact_source_id is not null) as linked_to_a_contact,
       min(cu.source_created_at)::date as oldest_created
from cma.commerce_store s
join cma.tenant t on t.id = s.tenant_id and t.slug = :'slug'
left join cma.commerce_customer cu on cu.tenant_id = s.tenant_id and cu.connection_id = s.connection_id and cu.source_deleted_at is null
group by s.handle, s.market order by s.handle;
reset role;
\echo ===== block 5
set role cma_owner;
with t as (select id from cma.tenant where slug = :'slug')
select coalesce(s.handle, split_part(c.external_account_id, '.', 1)) as store, s.market, sb.status, count(*) as subscriptions,
       count(cu.id) as customer_held, min(sb.source_created_at)::date as oldest_created
from cma.subscription sb
join cma.integration_connection c on c.tenant_id = sb.tenant_id and c.id = sb.connection_id
left join cma.commerce_store s on s.tenant_id = sb.tenant_id and s.handle = split_part(c.external_account_id, '.', 1)
left join cma.commerce_customer cu on cu.tenant_id = sb.tenant_id and cu.connection_id = s.connection_id
     and cu.source_id = sb.customer_source_id and cu.source_deleted_at is null
where sb.tenant_id = (select id from t) and sb.source_deleted_at is null
group by 1, 2, 3 order by 1, 3;
with t as (select id from cma.tenant where slug = :'slug')
select s.handle, s.market from cma.commerce_store s
where s.tenant_id = (select id from t)
  and not exists (select 1 from cma.integration_connection c
                  where c.tenant_id = s.tenant_id and c.adapter = 'juo' and c.status = 'active'
                    and split_part(c.external_account_id, '.', 1) = s.handle)
order by 1;
with t as (select id from cma.tenant where slug = :'slug')
select s.market, count(distinct cu.id) as customers_held,
       count(distinct cu.id) filter (where exists (select 1 from cma.subscription sb
                                                   where sb.tenant_id = cu.tenant_id and sb.customer_source_id = cu.source_id and sb.source_deleted_at is null
                                                     and sb.status = any (cma.flash_active_statuses_of((select id from t))))) as with_an_active_subscription
from cma.commerce_store s
left join cma.commerce_customer cu on cu.tenant_id = s.tenant_id and cu.connection_id = s.connection_id and cu.source_deleted_at is null
where s.tenant_id = (select id from t)
group by 1 order by 1;
with t as (select id from cma.tenant where slug = :'slug')
select cma.flash_ended_statuses_of((select id from t)) as churn_ended_statuses, cma.flash_active_statuses_of((select id from t)) as active_statuses;
with t as (select id from cma.tenant where slug = :'slug')
select s.market, count(*) filter (where o.source_created_at >= now() - interval '30 days') as orders_30d,
       count(*) filter (where o.source_created_at >= now() - interval '30 days' and o.order_kind = 'renewal') as renewals_30d
from cma.commerce_store s
join cma.commerce_order o on o.tenant_id = s.tenant_id and o.connection_id = s.connection_id and o.source_deleted_at is null
where s.tenant_id = (select id from t)
group by 1 order by 1;
reset role;
