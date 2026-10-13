-- A database at 0008e holding what 54 meets in prod: a telephony connection whose lines two and
-- three were marked not counted before 0008f, with calls, taggings and a link on them (invented data)
set role cma_owner;
do $$
declare
  v_t uuid := (select id from cma.tenant where slug = 'pulse4all-subscriptions');
  v_ing uuid; v_tel uuid; v_crm uuid; v_s timestamptz := timestamptz '2026-10-12 10:00:00+00';
begin
  select user_id into v_ing from cma.app_user_external_id where tenant_id = v_t and system = 'ingest';
  insert into cma.integration_connection (tenant_id, adapter, name, external_account_id) values (v_t, 'localtel', 'Local phones', 'company-1') returning id into v_tel;
  insert into cma.integration_connection (tenant_id, adapter, name, external_account_id) values (v_t, 'localcrm', 'Local records', 'portal-1') returning id into v_crm;
  perform set_config('role', 'cma_app', true);
  perform set_config('app.tenant_id', v_t::text, true);
  perform set_config('app.user_id', v_ing::text, true);
  perform cma.ingest_upsert_telephony_catalog(v_tel, 'number', '[{"numberRef": "line-a", "name": "Line A"}, {"numberRef": "line-b", "name": "Line B"}, {"numberRef": "line-c", "name": "Line C"}]');
  perform cma.ingest_upsert_telephony_calls(v_tel, (
    select jsonb_agg(jsonb_build_object('sourceId', 'call-' || i, 'direction', 'outbound', 'startedAt', v_s + i * interval '10 minutes',
                                        'numberRef', case when i <= 3 then 'line-a' when i <= 5 then 'line-b' else 'line-c' end,
                                        'counterpartHash', md5(i::text) || md5(i::text), 'versionAt', v_s + i * interval '10 minutes',
                                        'tags', jsonb_build_array('tag-1')))
    from generate_series(1, 9) i));
  perform cma.ingest_upsert_calls(v_crm, jsonb_build_array(jsonb_build_object('sourceId', 'crm-4', 'direction', 'outbound',
    'counterpartHash', md5('4') || md5('4'), 'occurredAt', v_s + interval '40 minutes', 'updatedAt', v_s + interval '50 minutes')));
  perform cma.link_calls(v_s - interval '1 hour');
  perform set_config('role', 'cma_owner', true);
  update cma.telephony_number set is_counted = false where connection_id = v_tel and number_ref in ('line-b', 'line-c');
end
$$;
select n.number_ref, n.is_counted, count(t.id) as calls,
       (select count(*) from cma.telephony_call_tag g where g.connection_id = n.connection_id and g.call_source_id in
          (select source_id from cma.telephony_call x where x.connection_id = n.connection_id and x.number_ref = n.number_ref)) as taggings,
       (select count(*) from cma.call_link l join cma.telephony_call x on x.id = l.telephony_call_id where x.connection_id = n.connection_id and x.number_ref = n.number_ref) as links
from cma.telephony_number n left join cma.telephony_call t on t.connection_id = n.connection_id and t.number_ref = n.number_ref
where n.connection_id = (select id from cma.integration_connection where adapter = 'localtel')
group by n.connection_id, n.number_ref, n.is_counted order by n.number_ref;
