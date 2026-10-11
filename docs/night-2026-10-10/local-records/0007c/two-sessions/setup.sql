-- Two-session claim test, setup (committed in a throwaway local database only)
set role cma_owner;
select set_config('verify.t', cma.create_tenant('verify-0007c-sessions', 'Verify 0007c sessions', 'Europe/Amsterdam')::text, false) \g /dev/null
insert into cma.app_user (tenant_id, email, display_name)
values (current_setting('verify.t')::uuid, 'verify-admin@example.invalid', 'Verify admin');
insert into cma.user_role (tenant_id, user_id, role_id)
select u.tenant_id, u.id, ar.id from cma.app_user u join cma.app_role ar on ar.tenant_id = u.tenant_id and ar.key = 'admin'
where u.tenant_id = current_setting('verify.t')::uuid and u.email = 'verify-admin@example.invalid';
insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
values (current_setting('verify.t')::uuid, 'verify_crm', 'Verify CRM sessions', '1000009');
begin;
set local role cma_app;
select set_config('app.tenant_id', current_setting('verify.t'), true) \g /dev/null
select set_config('app.user_id', (select id::text from cma.app_user where tenant_id = current_setting('verify.t')::uuid and email = 'verify-admin@example.invalid'), true) \g /dev/null
select cma.set_writeback_field((select id from cma.integration_connection where external_account_id = '1000009'), 'country', 'verify_country', 'if_empty', true) \g /dev/null
select set_config('app.user_id', (select id::text from cma.app_user where tenant_id = current_setting('verify.t')::uuid and email = 'ingest@system.invalid'), true) \g /dev/null
select cma.enqueue_contact_writeback((select id from cma.integration_connection where external_account_id = '1000009'), '900000' || n, '{"country": "GB"}', null) is not null as enqueued
from generate_series(1, 4) n;
commit;
