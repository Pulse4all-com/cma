-- CMA-037 item 2 test, as the real ingest login (member of cma_app), tenant context set, NO app.user_id, rolled back
\set ON_ERROR_STOP 0
select current_user, session_user;
begin;
select set_config('app.tenant_id', (select id::text from cma.tenant where slug = 'audit-0008q-throwaway'), true) as tenant_set,
       set_config('app.user_id', '', true) as user_id_empty,
       set_config('app.actor_label', 'ingest-api:audit', true) as actor;
select count(*) as calls_before, count(*) filter (where source_deleted_at is null) as live_before from cma.telephony_call;
select count(*) as taggings_before from cma.telephony_call_tag;
select has_table_privilege(current_user, 'cma.telephony_call', 'delete') as ingest_may_delete_calls,
       has_table_privilege(current_user, 'cma.telephony_number', 'update') as ingest_may_update_lines,
       has_column_privilege(current_user, 'cma.telephony_number', 'is_counted', 'update') as ingest_may_update_is_counted;
update cma.telephony_number set is_counted = false where number_ref = 'line-1';
select count(*) as calls_after from cma.telephony_call;
select count(*) as taggings_after from cma.telephony_call_tag;
select table_name, action, actor_login, actor_db_role, coalesce(actor_user_id::text, '(none)') as actor_user_id, actor_label, count(*)
from cma.audit_log where table_name in ('telephony_call','telephony_call_tag','telephony_number') and action = 'delete' or (table_name = 'telephony_number' and action = 'update')
group by 1,2,3,4,5,6 order by 1,2;
rollback;
