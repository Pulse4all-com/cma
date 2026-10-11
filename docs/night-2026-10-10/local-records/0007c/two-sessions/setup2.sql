-- two more pending actions
begin;
set local role cma_app;
select set_config('app.tenant_id', (select id::text from cma.tenant where slug = 'verify-0007c-sessions'), true) \g /dev/null
select set_config('app.user_id', (select u.id::text from cma.app_user u join cma.tenant t on t.id = u.tenant_id
                                  where t.slug = 'verify-0007c-sessions' and u.email = 'ingest@system.invalid'), true) \g /dev/null
select cma.enqueue_contact_writeback((select id from cma.integration_connection where external_account_id = '1000009'), '900000' || n, '{"country": "NL"}', null) is not null as enqueued
from generate_series(5, 6) n;
commit;
