set role cma_owner;
select n.number_ref, n.is_counted, count(t.id) as calls from cma.telephony_number n
left join cma.telephony_call t on t.connection_id = n.connection_id and t.number_ref = n.number_ref
where n.connection_id = (select id from cma.integration_connection where adapter = 'localtel') group by n.number_ref, n.is_counted order by 1;
select count(*) as crm_calls_kept from cma.crm_call where source_id = 'crm-4';
select a.table_name, a.action, count(*) as rows, string_agg(distinct (select string_agg(k, ',' order by k) from jsonb_object_keys(a.old_row) k), ' | ') as old_row_keys,
       bool_and(a.new_row is null) as no_new_row, string_agg(distinct a.actor_login, ',') as actor_login, string_agg(distinct a.actor_db_role, ',') as actor_role
from cma.audit_log a where a.action = 'delete' and a.table_name in ('telephony_call', 'telephony_call_tag', 'call_link')
group by a.table_name, a.action order by 1;
