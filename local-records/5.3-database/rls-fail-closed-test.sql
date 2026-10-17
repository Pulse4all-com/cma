\set ON_ERROR_STOP 0
select current_user;
-- 1. no context at all
select 'no context' as case, (select count(*) from cma.app_user) as app_user, (select count(*) from cma.time_event) as time_event, (select count(*) from cma.telephony_call) as telephony_call, (select count(*) from cma.audit_log) as audit_log, (select count(*) from cma.tenant_setting) as tenant_setting;
-- 2. empty string context
begin;
select set_config('app.tenant_id', '', true);
select 'empty context' as case, (select count(*) from cma.app_user) as app_user, (select count(*) from cma.time_event) as time_event, (select count(*) from cma.telephony_call) as telephony_call, (select count(*) from cma.audit_log) as audit_log;
-- a write without context must be rejected by the policy's WITH CHECK
insert into cma.organisation (tenant_id, key, name) select id, 'audit-x', 'Audit X' from cma.tenant limit 1;
rollback;
-- 3. garbage context
begin;
select set_config('app.tenant_id', 'not-a-uuid', true);
select count(*) from cma.app_user;
rollback;
-- 4. global tables readable without context (expected: yes, they are global)
select 'global tables' as case, (select count(*) from cma.tenant) as tenant, (select count(*) from cma.permission) as permission, (select count(*) from cma.setting) as setting, (select count(*) from cma.schema_migration) as schema_migration;
-- 5. views in schema cma without context
select 'views no context' as case, (select count(*) from cma.workday_summary) as workday_summary;
-- 6. cma_read as the web login (expected: no rights)
select count(*) from cma_read.app_user;
-- 7. the RLS predicate: plan shape with context set, as the web login
begin;
select set_config('app.tenant_id', (select id::text from cma.tenant where slug='pulse4all-subscriptions'), true);
explain (verbose, costs off) select count(*) from cma.time_event where user_id = '01a14ac1-8b63-7b13-b169-1683e04580f8';
explain (costs off) select * from cma.workday where user_id = '01a14ac1-8b63-7b13-b169-1683e04580f8' and business_date = current_date;
rollback;
