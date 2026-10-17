-- CMA-037 item 2 test, setup: a throwaway tenant in cma_perf (a throwaway database), committed, as the owner
set role cma_owner;
do $$
declare v_t uuid; v_admin uuid; v_ing uuid; v_tel uuid; v_s timestamptz := timestamptz '2026-10-12 10:00:00+00';
begin
  v_t := cma.create_tenant('audit-0008q-throwaway', 'Audit 0008q throwaway', 'Europe/Amsterdam');
  insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'audit-admin@example.invalid', 'audit admin') returning id into v_admin;
  insert into cma.user_role (tenant_id, user_id, role_id) select ar.tenant_id, v_admin, ar.id from cma.app_role ar where ar.tenant_id = v_t and ar.key = 'admin';
  select x.user_id into v_ing from cma.app_user_external_id x where x.tenant_id = v_t and x.system = 'ingest';
  perform set_config('role', 'cma_app', true);
  perform set_config('app.tenant_id', v_t::text, true);
  perform set_config('app.user_id', v_admin::text, true);
  select c.connection_id into v_tel from cma.upsert_connection('audittel', 'Audit phones', 'company-x', null, null) c;
  perform cma.set_telephony_number(v_tel, 'line-1', null, true);
  perform set_config('app.user_id', v_ing::text, true);
  perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
    jsonb_build_object('sourceId', 'q-1', 'direction', 'outbound', 'startedAt', v_s, 'numberRef', 'line-1', 'counterpartHash', repeat('b1', 32), 'versionAt', v_s, 'tags', jsonb_build_array('tag-a')),
    jsonb_build_object('sourceId', 'q-2', 'direction', 'inbound',  'startedAt', v_s + interval '5 minutes', 'numberRef', 'line-1', 'counterpartHash', repeat('b2', 32), 'versionAt', v_s),
    jsonb_build_object('sourceId', 'q-3', 'direction', 'outbound', 'startedAt', v_s + interval '9 minutes', 'numberRef', 'line-1', 'counterpartHash', repeat('b3', 32), 'versionAt', v_s)));
  raise notice 'tenant %, connection %, calls stored %', v_t, v_tel, (select count(*) from cma.telephony_call where tenant_id = v_t);
end $$;
