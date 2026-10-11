-- One worker: claims with :lim and holds its transaction open :hold seconds
\set QUIET on
begin;
set local role cma_app;
set local statement_timeout = '2s';   -- a claim that waits on a lock would fail here
select set_config('app.tenant_id', (select id::text from cma.tenant where slug = 'verify-0007c-sessions'), true) \g /dev/null
select set_config('app.user_id', (select u.id::text from cma.app_user u join cma.tenant t on t.id = u.tenant_id
                                  where t.slug = 'verify-0007c-sessions' and u.email = 'ingest@system.invalid'), true) \g /dev/null
\set QUIET off
select clock_timestamp() as started_at \gset
select :'name' as worker, array_agg(c.target_id order by c.target_id) as claimed, count(*) as n,
       round(extract(epoch from clock_timestamp() - :'started_at'::timestamptz)::numeric, 2) as seconds
from cma.outbox_claim((select id from cma.integration_connection where external_account_id = '1000009'), :lim) c;
set local statement_timeout = 0;
select pg_sleep(:hold) \g /dev/null
commit;
