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
-- round-trips.json proves its cost does not depend on the number of CRM connections.
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
