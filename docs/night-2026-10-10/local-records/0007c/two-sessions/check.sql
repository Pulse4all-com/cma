set role cma_owner;
select o.target_id, o.status, o.attempts
from cma.outbox_action o join cma.tenant t on t.id = o.tenant_id
where t.slug = 'verify-0007c-sessions' order by o.target_id;
