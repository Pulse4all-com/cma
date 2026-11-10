-- =============================================================================================
-- verify/round-trips-fixture.sql: two customer-record (CRM) connections for the round-trips budget
-- (verify/round-trips.mjs), on a LOCAL database built from db/00 to db/78 with the dev seed
-- (follow-up to the IT audit of 17 October 2026, section 5.6; 18 October 2026)
-- =============================================================================================
-- Never for dev or prod: it refuses to run unless the session sets the local switch first, and it
-- refuses a database without the dev seed. Dev's tenant already has its own CRM connection. All ids
-- and names are invented; nothing personal is written. Rerunnable: a second run finds its connections
-- and stops.
--
--   psql -h 127.0.0.1 -d cma -c "set cma.local_fixture = 'on'" -f verify/round-trips-fixture.sql
--   (or put  set cma.local_fixture = 'on';  in the same session before \i)
--
-- What it writes, in pulse4all-subscriptions: two connections with one deal pipeline each, one with
-- its kind set to crm and one whose kind follows from the rows it holds (both are customer-record
-- connections to cma.sources() and the alert rules). With two connections the alert-rules row of
-- round-trips.json proves its cost does not depend on the number of CRM connections. Since addition 0009j also the
-- admin's pledges.view (a role of its own) and a fake loan, at its end.
do $$
begin
  if coalesce(current_setting('cma.local_fixture', true), '') <> 'on' then
    raise exception 'local fixture only: run  set cma.local_fixture = ''on''  in this session first';
  end if;
  if not exists (select 1 from cma.app_user where email = 'agent.two@example.com') then
    raise exception 'the dev seed is missing: this fixture needs db/03 and db/06';
  end if;
end
$$;
set role cma_owner;

do $$
declare
  v_subs uuid; v_admin uuid; v_ing uuid; v_a uuid; v_b uuid;
begin
  select id into v_subs from cma.tenant where slug = 'pulse4all-subscriptions';
  if exists (select 1 from cma.integration_connection where tenant_id = v_subs and adapter = 'roundtripcrm') then
    raise notice 'round-trips fixture already present';
    return;
  end if;
  select id into v_admin from cma.app_user where tenant_id = v_subs and email = 'admin@example.com';
  select id into v_ing from cma.app_user where tenant_id = v_subs and email = 'ingest@system.invalid';

  insert into cma.integration_connection (tenant_id, adapter, name, external_account_id) values (v_subs, 'roundtripcrm', 'Round-trip CRM A', 'rt-portal-a') returning id into v_a;
  insert into cma.integration_connection (tenant_id, adapter, name, external_account_id) values (v_subs, 'roundtripcrm', 'Round-trip CRM B', 'rt-portal-b') returning id into v_b;

  perform set_config('role', 'cma_app', true);
  perform set_config('app.tenant_id', v_subs::text, true);
  perform set_config('app.user_id', v_ing::text, true);
  perform cma.ingest_upsert_pipelines(v_a, '[{"recordType": "deal", "pipelineId": "rt-sales-a", "label": "Round-trip sales A", "stages": [
    {"stageId": "a1", "label": "Open", "order": 1, "isClosed": false}, {"stageId": "a9", "label": "Lost", "order": 9, "isClosed": true}]}]');
  perform cma.ingest_upsert_pipelines(v_b, '[{"recordType": "deal", "pipelineId": "rt-sales-b", "label": "Round-trip sales B", "stages": [
    {"stageId": "b1", "label": "Open", "order": 1, "isClosed": false}, {"stageId": "b9", "label": "Lost", "order": 9, "isClosed": true}]}]');

  perform set_config('app.user_id', v_admin::text, true);
  perform cma.set_connection_kind(v_a, 'crm');
end
$$;

-- Addition 0009j: Assets → Pledge lists needs pledges.view, which no default role holds (D7). Locally only, the dev
-- seed's admin of pulse4all-subscriptions gets it through a role of its own (verify_pledges), so round-trips.json and
-- perf.json can read the page and its files as the admin; with 168 run, a loan (number 2, the fake label Lender A) and
-- the values of the seed's first model, so today's file has rows when the seed holds a device with the loan reference 2.
-- Rerunnable: each insert meets what it wrote before. Nothing of a real lender, customer or device.
do $$
declare
  v_subs uuid; v_admin uuid; v_role uuid; v_model text;
begin
  if to_regclass('cma.pledge_loan') is null then
    raise notice 'pledge lists not present (168 not run): no grant';
    return;
  end if;
  select id into v_subs from cma.tenant where slug = 'pulse4all-subscriptions';
  select id into v_admin from cma.app_user where tenant_id = v_subs and email = 'admin@example.com';
  insert into cma.app_role (tenant_id, key, name) values (v_subs, 'verify_pledges', 'Verify pledges')
  on conflict (tenant_id, key) do update set name = excluded.name returning id into v_role;
  insert into cma.role_permission (tenant_id, role_id, permission_key) values (v_subs, v_role, 'pledges.view') on conflict do nothing;
  insert into cma.user_role (tenant_id, user_id, role_id) values (v_subs, v_admin, v_role) on conflict do nothing;
  insert into cma.pledge_loan (tenant_id, key, number, lender_label, area_label, name_suffix, layout)
  values (v_subs, '2', 2, 'Lender A', 'UK', 'EUR', 1) on conflict (tenant_id, key) do nothing;
  select key into v_model from cma.device_model where tenant_id = v_subs order by sort_order, key limit 1;
  if v_model is not null then
    insert into cma.pledge_model_value (tenant_id, model_key, type_label, acquisition_value, depreciation_per_month, receipts)
    values (v_subs, v_model, upper(v_model), 845.00, 5.03, 120.00) on conflict (tenant_id, model_key) do nothing;
  end if;
end
$$;
