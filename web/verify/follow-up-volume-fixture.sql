-- =============================================================================================
-- verify/follow-up-volume-fixture.sql: a prod-like volume for Reports → Follow-up on a LOCAL database
-- built from db/00 with the dev seed (addition 0008s, 18 October 2026): about 100 open lead deals not
-- called, 900 open tickets and 2,000 open tasks, across four markets, no market and an unknown one, six
-- people, two owners nobody is linked to and no owner
-- =============================================================================================
-- Never for dev or prod: it refuses to run unless the session sets the local switch first, refuses a
-- database without the dev seed, and refuses a Cloud SQL instance (the role cloudsqladmin exists there).
-- Every id is invented (vd…, vt…, vk…, vc…, vo-…); nothing personal is written: ids, codes, times. Dates
-- are relative to now, so the states (past the target, at risk, breached, overdue, today) stay mixed.
-- Rerunnable: a second run finds its connection and stops.
--
--   psql -h 127.0.0.1 -d cma -c "set cma.local_fixture = 'on'" -f verify/follow-up-volume-fixture.sql
--   (or put  set cma.local_fixture = 'on';  in the same session before \i)
--
-- What it writes, in pulse4all-subscriptions: the CRM connection "Volume CRM" (kind crm) with a lead
-- pipeline and two ticket pipelines, the markets NL, GB, DE and FR with office hours Monday to Friday
-- 09:00-17:00, intake.start_date 60 days back, owners vo-1 to vo-6 linked to six of the seed's people,
-- then the deals, tickets and tasks as rows of the connection (no calls, so every lead is not called).
do $$
begin
  if coalesce(current_setting('cma.local_fixture', true), '') <> 'on' then
    raise exception 'local fixture only: run  set cma.local_fixture = ''on''  in this session first';
  end if;
  if exists (select 1 from pg_roles where rolname = 'cloudsqladmin') then
    raise exception 'this is a Cloud SQL instance (the role cloudsqladmin exists): the volume fixture is for a local database only';
  end if;
  if not exists (select 1 from cma.app_user where email = 'agent.two@example.com') then
    raise exception 'the dev seed is missing: this fixture needs db/03 and db/06';
  end if;
end
$$;
set role cma_owner;

do $$
declare
  v_subs uuid; v_admin uuid; v_ing uuid; v_crm uuid;
  d date := current_date;
  v_people text[] := array['agent.two@example.com', 'agent.one@example.com', 'supervisor@example.com', 'manager@example.com',
                           'admin@example.com', 'analyst@example.com'];
  i integer;
begin
  select id into v_subs from cma.tenant where slug = 'pulse4all-subscriptions';
  if exists (select 1 from cma.integration_connection where tenant_id = v_subs and adapter = 'volumecrm') then
    raise notice 'follow-up volume fixture already present';
    return;
  end if;
  select id into v_admin from cma.app_user where tenant_id = v_subs and email = 'admin@example.com';
  select id into v_ing from cma.app_user where tenant_id = v_subs and email = 'ingest@system.invalid';
  insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
  values (v_subs, 'volumecrm', 'Volume CRM', 'vol-portal') returning id into v_crm;

  -- ---- configuration, through the functions, as the admin and the ingest user ---------------------
  perform set_config('role', 'cma_app', true);
  perform set_config('app.tenant_id', v_subs::text, true);
  perform set_config('app.user_id', v_admin::text, true);
  perform cma.upsert_market(m.code, m.name, m.zone, m.lang, m.cur)
  from (values ('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR'), ('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP'),
               ('DE', 'Germany', 'Europe/Berlin', 'de', 'EUR'), ('FR', 'France', 'Europe/Paris', 'fr', 'EUR')) m(code, name, zone, lang, cur)
  where not exists (select 1 from cma.market x where x.tenant_id = v_subs and x.code = m.code);
  if not exists (select 1 from cma.business_hours h where h.tenant_id = v_subs) then
    perform cma.set_business_hours('*', w::smallint, '09:00-17:00') from generate_series(1, 5) w;
  end if;
  perform cma.set_tenant_setting('intake.start_date', (d - 60)::text);
  for i in 1 .. array_length(v_people, 1) loop
    perform cma.set_user_external_id(u.id, 'volumecrm_owner', 'vo-' || i)
    from cma.app_user u where u.tenant_id = v_subs and u.email = v_people[i];
  end loop;
  perform set_config('app.user_id', v_ing::text, true);
  perform cma.ingest_upsert_pipelines(v_crm, '[
    {"recordType": "deal", "pipelineId": "vol-sales", "label": "Volume sales", "stages": [
       {"stageId": "vs1", "label": "New", "order": 1, "isClosed": false}, {"stageId": "vs9", "label": "Lost", "order": 9, "isClosed": true}]},
    {"recordType": "ticket", "pipelineId": "vol-support", "label": "Volume support", "stages": [
       {"stageId": "vt1", "label": "New", "order": 1, "isClosed": false}, {"stageId": "vt2", "label": "Waiting", "order": 2, "isClosed": false},
       {"stageId": "vt9", "label": "Closed", "order": 9, "isClosed": true}]},
    {"recordType": "ticket", "pipelineId": "vol-billing", "label": "Volume billing", "stages": [
       {"stageId": "vb1", "label": "New", "order": 1, "isClosed": false}, {"stageId": "vb9", "label": "Closed", "order": 9, "isClosed": true}]}]');
  perform set_config('app.user_id', v_admin::text, true);
  perform cma.set_connection_kind(v_crm, 'crm');
  perform cma.set_connection_settings(v_crm, '{"record_url_deal": "https://example.com/volume/{account}/deal/{id}", "record_url_ticket": "https://example.com/volume/{account}/ticket/{id}", "record_url_task": "https://example.com/volume/{account}/task/{id}"}');

  -- ---- the rows, written directly as the owner (a local fixture; the ingest path's checks are not the point) --
  perform set_config('role', 'cma_owner', true);
  -- owner: vo-1 to vo-6 linked, vo-7 and vo-8 linked to nobody, every ninth without an owner;
  -- market: four markets, no market, and a code that is no market (unknown)
  insert into cma.crm_record (tenant_id, connection_id, source_system, record_type, source_id, pipeline_id, stage_id, owner_ref,
                              contact_source_id, market, is_closed, source_created_at, source_updated_at)
  select v_subs, v_crm, 'volumecrm', 'deal', 'vd' || g, 'vol-sales', 'vs1',
         case when g % 9 = 0 then null else 'vo-' || (1 + g % 8) end,
         'vc' || g, (array['NL', 'GB', 'DE', 'FR', null, 'XX'])[1 + g % 6], false,
         now() - make_interval(mins => (g * 271) % (60 * 24 * 20)), now() - make_interval(mins => (g * 271) % (60 * 24 * 20))
  from generate_series(1, 100) g;

  insert into cma.crm_record (tenant_id, connection_id, source_system, record_type, source_id, pipeline_id, stage_id, owner_ref,
                              contact_source_id, market, is_closed, source_created_at, source_updated_at)
  select v_subs, v_crm, 'volumecrm', 'ticket', 'vt' || g, case when g % 3 = 0 then 'vol-billing' else 'vol-support' end,
         case when g % 3 = 0 then 'vb1' when g % 2 = 0 then 'vt2' else 'vt1' end,
         case when g % 9 = 0 then null else 'vo-' || (1 + g % 8) end,
         'vc' || (1000 + g), (array['NL', 'GB', 'DE', 'FR', null, 'XX'])[1 + g % 6], false,
         now() - make_interval(mins => (g * 113) % (60 * 24 * 14)), now() - make_interval(mins => (g * 113) % (60 * 24 * 14))
  from generate_series(1, 900) g;

  -- tasks: due from 30 days back to 30 days ahead (every tenth without a due time), on a deal or a ticket
  insert into cma.crm_task (tenant_id, connection_id, source_system, source_id, owner_ref, status_ref, type_ref, priority_ref, due_at,
                            deal_source_id, ticket_source_id, contact_source_id, source_created_at, source_updated_at)
  select v_subs, v_crm, 'volumecrm', 'vk' || g,
         case when g % 9 = 0 then null else 'vo-' || (1 + g % 8) end,
         (array['NOT_STARTED', 'IN_PROGRESS', 'WAITING'])[1 + g % 3], (array['CALL', 'EMAIL', 'TODO'])[1 + g % 3],
         (array['HIGH', 'MEDIUM', 'LOW', null])[1 + g % 4],
         case when g % 10 = 0 then null else now() + make_interval(mins => (g * 433) % (60 * 24 * 60) - 60 * 24 * 30) end,
         case when g % 2 = 0 then 'vd' || (1 + g % 100) end, case when g % 2 = 1 then 'vt' || (1 + g % 900) end,
         'vc' || (1 + g % 100), now() - make_interval(days => 1 + g % 40), now() - make_interval(days => g % 40)
  from generate_series(1, 2000) g;
end
$$;
reset role;
