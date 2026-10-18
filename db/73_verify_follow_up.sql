-- =============================================================================================
-- 73_verify_follow_up.sql: verifies addition 0008o, the follow-up layer
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure
-- and privileges; block B works on two throwaway tenants inside a subtransaction that is always
-- rolled back. Universal otherwise: nothing of the seed is used; adapters, refs and ids are invented
-- data values. Every check writes one row, PASS or FAIL, and the last result lists them with the
-- verdict, because Cloud SQL Studio shows no notices. Run as your own IAM login in dev, after
-- 72_follow_up.sql and 02_seed_<customer>.sql; then 41, 69 and 71 again (unchanged).
--   A  structure and privileges: the addition row after 0008n; the four settings with their defaults;
--      the SLA column on connection_pipeline with its check and reader view; the five row types and
--      the reader views' exact columns (ids, codes and counts, no name); every function the
--      application's only, in the caller's rights, the readers' functions definer and readers' only;
--      0007d's fifteen checks and 0008m's added check untouched, the three follow-up checks apart
--   B  behaviour on tenant one (Amsterdam; a market with office hours around the clock, so business
--      time is clock time) and tenant two (Kiritimati, UTC+14): the open leads not called with their
--      owner, age bucket, target and last call; the buckets at their edges and the setting changing
--      them; the settings' refusals; tickets against the default SLA at 74 %, 75 % and 100 %, the
--      minutes to breach, no business hours apart and last, closed, not counted and deleted left out;
--      the data-quality ticket checks silent before the tenant configured an SLA; the pipeline
--      override beating the default and its refusals; the ticket checks once configured; the open
--      tasks with due states, records and markets; overdue against the tenant's own midnight; the
--      summary; per person with the not-mapped row; the person's own rows isolated between people
--      and tenants, with the record links; the unlinked-call skip rule on, off, inbound, tagged and
--      connected; the permissions refused where they must be; a reader scoped to one tenant
-- Since addition 0008s (80_follow_up_snapshot.sql) the application's reads come from a snapshot the refresh
-- job computes once a minute (the first read computes it when there is none): block B refreshes it after the
-- two changes it makes before reading again (the bucket setting, the pipeline override); its checks are the same.
-- Provoke: set provoke below to true; every check must then read FAIL, and the verdict says
-- PROVOKED instead of PASS.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);   -- 'true' to make every check fail

-- Dev only: a verifier that writes refuses a database without the dev seed. The flag is kept for the
-- session, so every block below stops at once and the verdict says REFUSED
select set_config('verify.is_dev', (exists (select 1 from cma.app_user u join cma.tenant t on t.id = u.tenant_id
                                            where u.email = 'agent.two@example.com' and u.status = 'active'))::text, false) as is_dev;
do $$
begin
  if not current_setting('verify.is_dev')::boolean then
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 73 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0008o;
create temp table verify_0008o (ord int, check_name text, result text, detail text);

-- The SQLSTATE a statement fails with, or ok
create or replace function pg_temp.v8o_err(p_sql text)
returns text
language plpgsql
as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end
$$;

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_t       text;
  v_fn      text;
  v_bad     text;
  v_cols    text;
  v_want    text;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  -- A1. the addition is recorded, after 0008n
  insert into verify_0008o values (1, 'A1 addition 0008o recorded, after 0008n',
    case when exists (select 1 from cma.schema_migration where version = '0008o')
              and exists (select 1 from cma.schema_migration where version = '0008n') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the four settings with their types and defaults
  select string_agg(format('%s:%s:%s', s.key, s.value_type, s.default_value), ' ' order by s.key) into v_cols
  from cma.setting s where s.key in ('tickets.sla_minutes', 'tickets.sla_warning_pct', 'leads.age_buckets_business_days', 'tasks.callback_window_minutes');
  v_want := 'leads.age_buckets_business_days:text:1,2,5 tasks.callback_window_minutes:integer:240 tickets.sla_minutes:integer:240 tickets.sla_warning_pct:integer:75';
  insert into verify_0008o values (2, 'A2 the four settings with their types and defaults',
    case when v_cols = v_want and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_cols, 'none'));

  -- A3. the SLA per pipeline: a nullable integer with its check, and the reader view (readers only)
  v_bad := '';
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'cma' and table_name = 'connection_pipeline' and column_name = 'sla_minutes'
                   and data_type = 'integer' and is_nullable = 'YES') then
    v_bad := v_bad || 'connection_pipeline.sla_minutes is not a nullable integer; ';
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'cma.connection_pipeline'::regclass and conname = 'connection_pipeline_sla_minutes_check') then
    v_bad := v_bad || 'no check on sla_minutes; ';
  end if;
  select string_agg(column_name, ',' order by ordinal_position) into v_cols
  from information_schema.columns where table_schema = 'cma_read' and table_name = 'connection_pipeline_sla';
  if v_cols is distinct from 'tenant_id,connection_id,record_type,source_pipeline_id,sla_minutes' then
    v_bad := v_bad || 'connection_pipeline_sla has ' || coalesce(v_cols, 'no columns') || '; ';
  end if;
  if to_regclass('cma_read.connection_pipeline_sla') is not null
     and (not has_table_privilege('cma_readonly', 'cma_read.connection_pipeline_sla', 'select')
          or has_table_privilege('cma_app', 'cma_read.connection_pipeline_sla', 'select')) then
    v_bad := v_bad || 'connection_pipeline_sla is not the readers'' only; ';
  end if;
  insert into verify_0008o values (3, 'A3 connection_pipeline.sla_minutes nullable with its check; the reader view, readers only',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A4. the five row types; the reader views' exact columns (ids, codes and counts; per person without
  --     the name); each the readers' only
  v_bad := '';
  foreach v_t in array array['open_lead_row', 'open_ticket_row', 'open_task_row', 'follow_up_summary_row', 'follow_up_owner_row'] loop
    if to_regtype('cma.' || v_t) is null then v_bad := v_bad || 'the type ' || v_t || ' is missing; '; end if;
  end loop;
  foreach v_t in array array[
    'open_lead=tenant_id,deal_id,connection_id,deal_source_id,pipeline_id,pipeline_label,owner_user_id,owner_ref,market,created_at,waiting_business_seconds,age_business_days,bucket_from,bucket_to,past_target,last_call_at,last_call_days',
    'open_ticket=tenant_id,ticket_id,connection_id,ticket_source_id,pipeline_id,pipeline_label,stage_id,stage_label,owner_user_id,owner_ref,market,created_at,open_business_seconds,sla_minutes,sla_state,minutes_to_breach',
    'open_task=tenant_id,task_id,connection_id,task_source_id,type_ref,type_label,is_callback,priority_ref,status_ref,status_label,owner_user_id,owner_ref,market,due_at,due_state,record_type,record_source_id,created_at',
    'follow_up_summary=tenant_id,leads_open_not_called,leads_past_target,tickets_at_risk,tickets_breached,tickets_without_owner,tasks_overdue,tasks_due_today,tasks_unmapped_owner',
    'follow_up_by_owner=tenant_id,owner_user_id,open_leads,leads_past_target,open_tickets,tickets_at_risk_or_breached,tasks_overdue,tasks_due_today',
    'dq_ticket_no_owner=tenant_id,connection_id,object_type,object_id,value',
    'dq_ticket_no_market=tenant_id,connection_id,object_type,object_id,value',
    'dq_crm_task_owner_unlinked=tenant_id,connection_id,object_type,object_id,value'] loop
    v_want := split_part(v_t, '=', 2);
    select string_agg(column_name, ',' order by ordinal_position) into v_cols
    from information_schema.columns where table_schema = 'cma_read' and table_name = split_part(v_t, '=', 1);
    if v_cols is distinct from v_want then
      v_bad := v_bad || split_part(v_t, '=', 1) || ' has ' || coalesce(v_cols, 'no columns') || '; ';
    elsif not has_table_privilege('cma_readonly', 'cma_read.' || split_part(v_t, '=', 1), 'select')
          or has_table_privilege('cma_app', 'cma_read.' || split_part(v_t, '=', 1), 'select') then
      v_bad := v_bad || split_part(v_t, '=', 1) || ' is not the readers'' only; ';
    end if;
  end loop;
  insert into verify_0008o values (4, 'A4 the five row types; the nine reader views'' exact columns, readers only, no name',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A5. every function the application's only and in the caller's rights; the readers' functions
  --     definer and the readers' only
  v_bad := '';
  foreach v_fn in array array[
    'cma.set_pipeline_sla(uuid,text,text,integer)',
    'cma.open_leads()', 'cma.open_tickets()', 'cma.open_tasks()', 'cma.follow_up_summary()', 'cma.follow_up_by_owner()', 'cma.my_follow_up()',
    'cma.open_leads_of(uuid)', 'cma.open_tickets_of(uuid)', 'cma.open_tasks_of(uuid)',
    'cma.follow_up_summary_of(uuid)', 'cma.follow_up_by_owner_of(uuid)', 'cma.my_follow_up_of(uuid,uuid)',
    'cma.owner_user_of(uuid,text,text)', 'cma.business_days_of(uuid,text,timestamptz,timestamptz)', 'cma.age_bucket_of(integer,text)',
    'cma.task_market_of(uuid,uuid,text,text,text)', 'cma.follow_up_configured_of(uuid)', 'cma.is_bucket_list(text)',
    'cma.data_quality_follow_up_checks()', 'cma.data_quality_of(uuid)', 'cma.data_quality()'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' is missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                     where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      v_bad := v_bad || v_fn || ' is not the application''s only, in the caller''s rights; ';
    end if;
  end loop;
  foreach v_fn in array array['cma_read.open_leads_rows()', 'cma_read.open_tickets_rows()', 'cma_read.open_tasks_rows()',
                              'cma_read.follow_up_summary_rows()', 'cma_read.follow_up_by_owner_rows()'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' is missing; ';
    elsif not has_function_privilege('cma_readonly', v_fn, 'execute') or has_function_privilege('cma_app', v_fn, 'execute')
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                     where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE')
          or not (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      v_bad := v_bad || v_fn || ' is not a definer function for readers only; ';
    end if;
  end loop;
  insert into verify_0008o values (5, 'A5 the functions the application''s only, in the caller''s rights; the readers'' functions definer, readers only',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A6. the check lists: 0007d's fifteen untouched, 0008m's added check alone (69 pins it), the three
  --     follow-up checks apart in order; data_quality() reads them; the settings trigger names the four
  v_bad := '';
  if (select count(*) from cma.data_quality_checks()) <> 15 then v_bad := v_bad || 'data_quality_checks is not fifteen rows; '; end if;
  if (select string_agg(check_key, ',') from cma.data_quality_added_checks()) is distinct from 'contact_country_fallback' then
    v_bad := v_bad || '0008m''s added check changed; ';
  end if;
  if (select string_agg(check_key || ':' || sort_order, ',' order by sort_order) from cma.data_quality_follow_up_checks())
     is distinct from 'ticket_no_owner:170,ticket_no_market:180,crm_task_owner_unlinked:190' then
    v_bad := v_bad || 'the follow-up checks are not the three in order; ';
  end if;
  if to_regprocedure('cma.data_quality()') is null or pg_get_functiondef(to_regprocedure('cma.data_quality()')) not like '%data_quality_follow_up_checks%' then
    v_bad := v_bad || 'data_quality() does not read the follow-up checks; ';
  end if;
  if pg_get_functiondef(to_regprocedure('cma.check_tenant_setting()')) !~ 'tickets\.sla_minutes.*tickets\.sla_warning_pct.*leads\.age_buckets_business_days.*tasks\.callback_window_minutes' then
    v_bad := v_bad || 'check_tenant_setting does not name the four settings; ';
  end if;
  insert into verify_0008o values (6, 'A6 the check lists: fifteen, 0008m''s one alone, the three follow-up checks apart; the settings trigger',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);
end
$$;

-- B. Behaviour on two throwaway tenants (rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_rows     text[] := '{}';
  v_now      timestamptz := now();
  v_t1 uuid; v_t2 uuid;
  v_admin1 uuid; v_manager1 uuid; v_analyst1 uuid; v_watcher1 uuid; v_agent1 uuid; v_agent2 uuid; v_ing1 uuid;
  v_admin2 uuid; v_agent3 uuid; v_ing2 uuid;
  v_role uuid;
  v_crm uuid; v_tel uuid; v_crm2 uuid;
  v_today1   date;
  v_today2   date;
  v_m1       timestamptz;
  v_txt      text;
  v_txt2     text;
  v_detail   text;
  v_n        integer;
  v_m        integer;
  v_res      jsonb;
  r          record;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    v_t1 := cma.create_tenant('verify-0008o-one', 'Verify 0008o one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008o-two', 'Verify 0008o two', 'Pacific/Kiritimati');
    v_today1 := (v_now at time zone 'Europe/Amsterdam')::date;
    v_today2 := (v_now at time zone 'Pacific/Kiritimati')::date;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'Verify admin') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-manager1@example.invalid', 'Verify manager') returning id into v_manager1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-analyst1@example.invalid', 'Verify analyst') returning id into v_analyst1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-watcher1@example.invalid', 'Verify watcher') returning id into v_watcher1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent1@example.invalid', 'Verify agent one') returning id into v_agent1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent2@example.invalid', 'Verify agent two') returning id into v_agent2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'Verify admin two') returning id into v_admin2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-agent3@example.invalid', 'Verify agent three') returning id into v_agent3;
    -- a role of this tenant with monitoring.live alone (no seed role has it without performance.team)
    insert into cma.app_role (tenant_id, key, name) values (v_t1, 'verify_watcher', 'Verify watcher') returning id into v_role;
    insert into cma.role_permission (tenant_id, role_id, permission_key) values (v_t1, v_role, 'monitoring.live');
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_manager1, 'manager'), (v_t1, v_analyst1, 'analytics'), (v_t1, v_watcher1, 'verify_watcher'),
                 (v_t1, v_agent1, 'agent'), (v_t1, v_agent2, 'agent'), (v_t2, v_admin2, 'admin'), (v_t2, v_agent3, 'agent')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select id into v_ing1 from cma.app_user where tenant_id = v_t1 and email = 'ingest@system.invalid';
    select id into v_ing2 from cma.app_user where tenant_id = v_t2 and email = 'ingest@system.invalid';
    perform set_config('role', 'cma_app', true);

    -- tenant one's configuration (the admin): a market with office hours around the clock every day, the
    -- intake start, the lead target of an hour, the owners, a CRM connection with record links for deals
    -- and tasks (none for tickets), a telephony connection
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.set_business_hours('*', d::smallint, '00:00-24:00') from generate_series(1, 7) d;
    perform cma.set_tenant_setting('intake.start_date', '2026-09-01');
    perform cma.set_tenant_setting('speed_to_lead.target_minutes', '60');
    perform cma.set_user_external_id(v_agent1, 'verifycrm_owner', 'o-1');
    perform cma.set_user_external_id(v_agent2, 'verifycrm_owner', 'o-2');
    select c.connection_id into v_crm from cma.upsert_connection('verifycrm', 'Verify CRM one', 'portal-1', null, null) c;
    perform cma.set_connection_kind(v_crm, 'crm');
    perform cma.set_connection_settings(v_crm, '{"record_url_deal": "https://crm.example.invalid/{account}/deal/{id}", "record_url_task": "https://crm.example.invalid/{account}/task/{id}"}'::jsonb);
    select c.connection_id into v_tel from cma.upsert_connection('verifytel', 'Verify phones one', 'company-1', null, null) c;
    perform cma.set_connection_kind(v_tel, 'telephony');

    -- the catalogs (the Ingest user), then their configuration (the admin): renewals are no lead
    -- pipeline, the spam ticket pipeline does not count, a done task status, an uncounted task type
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_pipelines(v_crm, '[
      {"recordType": "deal", "pipelineId": "sales", "label": "Sales", "stages": [
         {"stageId": "s1", "label": "Open", "order": 1, "isClosed": false}, {"stageId": "s9", "label": "Lost", "order": 9, "isClosed": true}]},
      {"recordType": "deal", "pipelineId": "renew", "label": "Renewals", "stages": [{"stageId": "r1", "label": "Open", "order": 1, "isClosed": false}]},
      {"recordType": "ticket", "pipelineId": "support", "label": "Support", "stages": [
         {"stageId": "t1", "label": "New", "order": 1, "isClosed": false}, {"stageId": "t9", "label": "Closed", "order": 9, "isClosed": true}]},
      {"recordType": "ticket", "pipelineId": "billing", "label": "Billing", "stages": [{"stageId": "b1", "label": "New", "order": 1, "isClosed": false}]},
      {"recordType": "ticket", "pipelineId": "spam", "label": "Spam", "stages": [{"stageId": "z1", "label": "New", "order": 1, "isClosed": false}]}]');
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'number', '[{"numberRef": "n-1", "name": "Verify line", "digits": "+31000000001"}]');
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'tag', '[{"tagRef": "tg1", "name": "Verify tag"}]');
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_pipeline_lead(v_crm, 'deal', 'renew', false);
    perform cma.set_connection_pipeline(v_crm, 'ticket', 'spam', false, false, null);
    perform cma.set_telephony_number(v_tel, 'n-1', 'NL', true);

    -- the records (the Ingest user). Deals: d1 three days old (agent one), d2 half an hour old (agent
    -- two), d3 two days old with an owner nobody maps to, d4 a day old without owner or market, d5
    -- called, d6 a renewal. Tickets of Support at 74 %, 75 %, 100 % and 125 % of the default SLA (x4
    -- without owner), x5 in Billing at 90 minutes, x6 without a market, x7 closed, x8 in Spam, x9
    -- deleted. Contacts k4 and k6 have no country.
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_records(v_crm, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd1', 'pipelineId', 'sales', 'stageId', 's1', 'ownerRef', 'o-1', 'contactId', 'k1', 'market', 'NL',
                         'createdAt', v_now - interval '3 days', 'updatedAt', v_now - interval '3 days'),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd2', 'pipelineId', 'sales', 'stageId', 's1', 'ownerRef', 'o-2', 'contactId', 'k2', 'market', 'NL',
                         'createdAt', v_now - interval '30 minutes', 'updatedAt', v_now - interval '30 minutes'),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd3', 'pipelineId', 'sales', 'stageId', 's1', 'ownerRef', 'o-9', 'contactId', 'k3', 'market', 'NL',
                         'createdAt', v_now - interval '2 days', 'updatedAt', v_now - interval '2 days'),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd4', 'pipelineId', 'sales', 'stageId', 's1', 'contactId', 'k4',
                         'createdAt', v_now - interval '1 day', 'updatedAt', v_now - interval '1 day'),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd5', 'pipelineId', 'sales', 'stageId', 's1', 'ownerRef', 'o-1', 'contactId', 'k5', 'market', 'NL',
                         'createdAt', v_now - interval '2 hours', 'updatedAt', v_now - interval '2 hours'),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd6', 'pipelineId', 'renew', 'stageId', 'r1', 'ownerRef', 'o-1', 'contactId', 'k1', 'market', 'NL',
                         'createdAt', v_now - interval '2 days', 'updatedAt', v_now - interval '2 days'),
      jsonb_build_object('recordType', 'ticket', 'sourceId', 'x1', 'pipelineId', 'support', 'stageId', 't1', 'ownerRef', 'o-1', 'contactId', 'k1', 'market', 'NL',
                         'createdAt', v_now - interval '177 minutes 36 seconds', 'updatedAt', v_now - interval '177 minutes'),
      jsonb_build_object('recordType', 'ticket', 'sourceId', 'x2', 'pipelineId', 'support', 'stageId', 't1', 'ownerRef', 'o-1', 'contactId', 'k2', 'market', 'NL',
                         'createdAt', v_now - interval '180 minutes', 'updatedAt', v_now - interval '180 minutes'),
      jsonb_build_object('recordType', 'ticket', 'sourceId', 'x3', 'pipelineId', 'support', 'stageId', 't1', 'ownerRef', 'o-2', 'contactId', 'k3', 'market', 'NL',
                         'createdAt', v_now - interval '240 minutes', 'updatedAt', v_now - interval '240 minutes'),
      jsonb_build_object('recordType', 'ticket', 'sourceId', 'x4', 'pipelineId', 'support', 'stageId', 't1', 'contactId', 'k1', 'market', 'NL',
                         'createdAt', v_now - interval '300 minutes', 'updatedAt', v_now - interval '300 minutes'),
      jsonb_build_object('recordType', 'ticket', 'sourceId', 'x5', 'pipelineId', 'billing', 'stageId', 'b1', 'ownerRef', 'o-2', 'contactId', 'k2', 'market', 'NL',
                         'createdAt', v_now - interval '90 minutes', 'updatedAt', v_now - interval '90 minutes'),
      jsonb_build_object('recordType', 'ticket', 'sourceId', 'x6', 'pipelineId', 'support', 'stageId', 't1', 'ownerRef', 'o-1', 'contactId', 'k6',
                         'createdAt', v_now - interval '10 minutes', 'updatedAt', v_now - interval '10 minutes'),
      jsonb_build_object('recordType', 'ticket', 'sourceId', 'x7', 'pipelineId', 'support', 'stageId', 't9', 'ownerRef', 'o-1', 'contactId', 'k1', 'market', 'NL',
                         'closedAt', v_now - interval '1 day', 'createdAt', v_now - interval '2 days', 'updatedAt', v_now - interval '1 day'),
      jsonb_build_object('recordType', 'ticket', 'sourceId', 'x8', 'pipelineId', 'spam', 'stageId', 'z1', 'ownerRef', 'o-1', 'contactId', 'k1', 'market', 'NL',
                         'createdAt', v_now - interval '2 days', 'updatedAt', v_now - interval '2 days'),
      jsonb_build_object('recordType', 'ticket', 'sourceId', 'x9', 'pipelineId', 'support', 'stageId', 't1', 'ownerRef', 'o-1', 'contactId', 'k1', 'market', 'NL',
                         'createdAt', v_now - interval '2 days', 'updatedAt', v_now - interval '2 days')));
    perform cma.ingest_upsert_records(v_crm, jsonb_build_array(
      jsonb_build_object('recordType', 'ticket', 'sourceId', 'x9', 'deletedAt', v_now - interval '1 day')));
    perform cma.ingest_upsert_contacts(v_crm, jsonb_build_array(
      jsonb_build_object('sourceId', 'k1', 'country', 'NL', 'language', 'nl', 'updatedAt', v_now - interval '3 days'),
      jsonb_build_object('sourceId', 'k2', 'country', 'NL', 'language', 'nl', 'updatedAt', v_now - interval '3 days'),
      jsonb_build_object('sourceId', 'k3', 'country', 'NL', 'language', 'nl', 'updatedAt', v_now - interval '3 days'),
      jsonb_build_object('sourceId', 'k4', 'language', 'nl', 'updatedAt', v_now - interval '3 days'),
      jsonb_build_object('sourceId', 'k5', 'country', 'NL', 'language', 'nl', 'updatedAt', v_now - interval '3 days'),
      jsonb_build_object('sourceId', 'k6', 'language', 'nl', 'updatedAt', v_now - interval '3 days')));
    -- CRM calls: an inbound call to d1's contact a day ago (d1 stays not called, it is its last call), an
    -- outbound call to d5's contact (d5 is called)
    perform cma.ingest_upsert_calls(v_crm, jsonb_build_array(
      jsonb_build_object('sourceId', 'c-in', 'occurredAt', v_now - interval '1 day', 'direction', 'inbound', 'updatedAt', v_now - interval '1 day'),
      jsonb_build_object('sourceId', 'c5', 'occurredAt', v_now - interval '1 hour', 'direction', 'outbound', 'ownerRef', 'o-1', 'updatedAt', v_now - interval '1 hour')));
    perform cma.ingest_upsert_associations(v_crm, jsonb_build_array(
      jsonb_build_object('fromType', 'crm_call', 'fromId', 'c-in', 'toType', 'contact', 'toId', 'k1', 'removed', false, 'changedAt', v_now - interval '1 day'),
      jsonb_build_object('fromType', 'crm_call', 'fromId', 'c5', 'toType', 'contact', 'toId', 'k5', 'removed', false, 'changedAt', v_now - interval '1 hour')));
    -- tasks: k1 due yesterday 23:30 Amsterdam (agent one, on d1), k2 due today 00:30 (agent two, on x3),
    -- k3 due tomorrow with an owner nobody maps to, k4 without owner or due time, k5 completed, k6 of
    -- an uncounted type, k7 deleted
    perform cma.ingest_upsert_tasks(v_crm, jsonb_build_array(
      jsonb_build_object('sourceId', 'k1', 'statusRef', 'NOT_STARTED', 'typeRef', 'CALL', 'ownerRef', 'o-1', 'dealId', 'd1', 'contactId', 'k1', 'priorityRef', 'HIGH',
                         'dueAt', ((v_today1 - 1) + time '23:30') at time zone 'Europe/Amsterdam', 'createdAt', v_now - interval '2 days', 'updatedAt', v_now - interval '2 days'),
      jsonb_build_object('sourceId', 'k2', 'statusRef', 'NOT_STARTED', 'typeRef', 'CALL', 'ownerRef', 'o-2', 'ticketId', 'x3',
                         'dueAt', (v_today1 + time '00:30') at time zone 'Europe/Amsterdam', 'createdAt', v_now - interval '2 days', 'updatedAt', v_now - interval '2 days'),
      jsonb_build_object('sourceId', 'k3', 'statusRef', 'NOT_STARTED', 'typeRef', 'CALL', 'ownerRef', 'o-9',
                         'dueAt', ((v_today1 + 1) + time '09:00') at time zone 'Europe/Amsterdam', 'createdAt', v_now - interval '2 days', 'updatedAt', v_now - interval '2 days'),
      jsonb_build_object('sourceId', 'k4', 'statusRef', 'NOT_STARTED', 'typeRef', 'CALL',
                         'createdAt', v_now - interval '2 days', 'updatedAt', v_now - interval '2 days'),
      jsonb_build_object('sourceId', 'k5', 'statusRef', 'COMPLETED', 'typeRef', 'CALL', 'ownerRef', 'o-1', 'completedAt', v_now - interval '1 day',
                         'dueAt', v_now - interval '1 day', 'createdAt', v_now - interval '2 days', 'updatedAt', v_now - interval '1 day'),
      jsonb_build_object('sourceId', 'k6', 'statusRef', 'NOT_STARTED', 'typeRef', 'INTERNAL', 'ownerRef', 'o-1',
                         'dueAt', v_now - interval '1 day', 'createdAt', v_now - interval '2 days', 'updatedAt', v_now - interval '2 days'),
      jsonb_build_object('sourceId', 'k7', 'statusRef', 'NOT_STARTED', 'typeRef', 'CALL', 'ownerRef', 'o-1',
                         'dueAt', v_now - interval '1 day', 'createdAt', v_now - interval '2 days', 'updatedAt', v_now - interval '2 days')));
    perform cma.ingest_upsert_tasks(v_crm, jsonb_build_array(jsonb_build_object('sourceId', 'k7', 'deletedAt', v_now - interval '1 day')));
    -- telephony calls two days ago, none linked: p1 outbound never answered and untagged, p2 the same
    -- but tagged, p3 inbound missed, p4 outbound connected for two minutes
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
      jsonb_build_object('sourceId', 'p1', 'direction', 'outbound', 'status', 'done', 'numberRef', 'n-1', 'startedAt', v_now - interval '2 days',
                         'endedAt', v_now - interval '2 days' + interval '20 seconds', 'versionAt', v_now - interval '2 days'),
      jsonb_build_object('sourceId', 'p2', 'direction', 'outbound', 'status', 'done', 'numberRef', 'n-1', 'startedAt', v_now - interval '2 days',
                         'endedAt', v_now - interval '2 days' + interval '20 seconds', 'versionAt', v_now - interval '2 days', 'tags', jsonb_build_array('tg1')),
      jsonb_build_object('sourceId', 'p3', 'direction', 'inbound', 'status', 'missed', 'missedReason', 'no_answer', 'numberRef', 'n-1', 'startedAt', v_now - interval '2 days',
                         'endedAt', v_now - interval '2 days' + interval '40 seconds', 'versionAt', v_now - interval '2 days'),
      jsonb_build_object('sourceId', 'p4', 'direction', 'outbound', 'status', 'done', 'numberRef', 'n-1', 'startedAt', v_now - interval '2 days',
                         'answeredAt', v_now - interval '2 days' + interval '10 seconds', 'endedAt', v_now - interval '2 days' + interval '130 seconds',
                         'versionAt', v_now - interval '2 days')));
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_task_status(v_crm, 'COMPLETED', 'Done', true);
    perform cma.set_task_type(v_crm, 'INTERNAL', 'Internal', false, false);

    -- tenant two: its own CRM connection, agent three mapped to the same owner id string as tenant
    -- one's agent one, three tasks around its own midnight (Kiritimati, UTC+14)
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    perform cma.set_user_external_id(v_agent3, 'verifycrm_owner', 'o-1');
    select c.connection_id into v_crm2 from cma.upsert_connection('verifycrm', 'Verify CRM two', 'portal-2', null, null) c;
    perform cma.set_connection_kind(v_crm2, 'crm');
    perform set_config('app.user_id', v_ing2::text, true);
    v_m1 := (v_today2 + time '00:30') at time zone 'Pacific/Kiritimati';
    perform cma.ingest_upsert_tasks(v_crm2, jsonb_build_array(
      jsonb_build_object('sourceId', 'm1', 'statusRef', 'NOT_STARTED', 'typeRef', 'CALL', 'ownerRef', 'o-1',
                         'dueAt', v_m1, 'createdAt', v_now - interval '1 day', 'updatedAt', v_now - interval '1 day'),
      jsonb_build_object('sourceId', 'm2', 'statusRef', 'NOT_STARTED', 'typeRef', 'CALL', 'ownerRef', 'o-1',
                         'dueAt', ((v_today2 - 1) + time '23:30') at time zone 'Pacific/Kiritimati', 'createdAt', v_now - interval '1 day', 'updatedAt', v_now - interval '1 day'),
      jsonb_build_object('sourceId', 'm3', 'statusRef', 'NOT_STARTED', 'typeRef', 'CALL', 'ownerRef', 'o-1',
                         'dueAt', ((v_today2 + 1) + time '00:30') at time zone 'Pacific/Kiritimati', 'createdAt', v_now - interval '1 day', 'updatedAt', v_now - interval '1 day')));

    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_manager1::text, true);

    -- B1. the open leads not called: d1, d3, d2, d4 in that order (the longest wait first, no business
    --     time last); owners mapped (d1 agent one, d2 agent two), d3's owner kept as not mapped, d4 none;
    --     the ages 3, 2, 0 and null business days in the buckets 2–5, 1–2, 0–1 and none; past the hour's
    --     target for d1 and d3, not yet for d2, unknown for d4; d1's last call the inbound call a day
    --     ago; d5 (called) and d6 (no lead pipeline) absent
    select string_agg(l.deal_source_id, ',' order by ord) into v_txt
    from (select l.*, row_number() over () as ord from cma.open_leads() l) l;
    select string_agg(format('%s:%s:%s:%s:%s-%s:%s:%s', l.deal_source_id,
                             case when l.owner_user_id = v_agent1 then 'agent1' when l.owner_user_id = v_agent2 then 'agent2' else coalesce(l.owner_ref, '-') end,
                             l.market, coalesce(l.age_business_days::text, 'null'), coalesce(l.bucket_from::text, 'null'), coalesce(l.bucket_to::text, 'null'),
                             coalesce(l.past_target::text, 'null'), coalesce(l.last_call_days::text, 'null')), ' ' order by l.deal_source_id) into v_detail
    from cma.open_leads() l;
    v_rows := v_rows || array['11', 'B1 the open leads not called: order, owners, ages, buckets, past the target, the last call',
      case when v_txt = 'd1,d3,d2,d4'
                and v_detail = 'd1:agent1:NL:3:2-5:true:1 d2:agent2:NL:0:0-1:false:null d3:o-9:NL:2:1-2:true:null d4:-:unknown:null:null-null:null:null'
                and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s | %s', v_txt, v_detail)];

    -- B2. the buckets at their edges against 1,2,5 (0 and 1 in the first, 2 in the second, 3 and 5 in the
    --     third, 6 in the open last one, null stays null); the setting 2,4 moves d1 to 2–4 and d3 to 0–2
    select string_agg(format('%s:%s-%s', d, coalesce(b.bucket_from::text, 'null'), coalesce(b.bucket_to::text, 'null')), ' ' order by d nulls first) into v_txt
    from unnest(array[null, 0, 1, 2, 3, 5, 6]::integer[]) d cross join lateral cma.age_bucket_of(d, '1,2,5') b;
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('leads.age_buckets_business_days', '2,4');
    perform set_config('app.user_id', v_manager1::text, true);
    perform cma.refresh_follow_up_of(v_t1);   -- since 0008s the reads come from the snapshot: refreshed after a change
    select string_agg(format('%s:%s-%s', l.deal_source_id, l.bucket_from, l.bucket_to), ' ' order by l.deal_source_id) into v_txt2
    from cma.open_leads() l where l.deal_source_id in ('d1', 'd3');
    v_rows := v_rows || array['12', 'B2 the buckets at their edges; the setting moves the leads',
      case when v_txt = ':null-null 0:0-1 1:0-1 2:1-2 3:2-5 5:2-5 6:5-null' and v_txt2 = 'd1:2-4 d3:0-2' and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s | %s', v_txt, v_txt2)];

    -- B3. the settings' refusals (CMA04): an SLA of 0, 100001 or a word; a warning share of 0 or 101;
    --     buckets out of order, six of them, from 0; a callback window of -1 or 10081. Accepted: buckets
    --     with spaces stored without them, a callback window of 0
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := pg_temp.v8o_err('select cma.set_tenant_setting(''tickets.sla_minutes'', ''0'')')
      || ',' || pg_temp.v8o_err('select cma.set_tenant_setting(''tickets.sla_minutes'', ''100001'')')
      || ',' || pg_temp.v8o_err('select cma.set_tenant_setting(''tickets.sla_minutes'', ''four'')')
      || ',' || pg_temp.v8o_err('select cma.set_tenant_setting(''tickets.sla_warning_pct'', ''0'')')
      || ',' || pg_temp.v8o_err('select cma.set_tenant_setting(''tickets.sla_warning_pct'', ''101'')')
      || ',' || pg_temp.v8o_err('select cma.set_tenant_setting(''leads.age_buckets_business_days'', ''2,1'')')
      || ',' || pg_temp.v8o_err('select cma.set_tenant_setting(''leads.age_buckets_business_days'', ''1,2,3,4,5,6'')')
      || ',' || pg_temp.v8o_err('select cma.set_tenant_setting(''leads.age_buckets_business_days'', ''0,1'')')
      || ',' || pg_temp.v8o_err('select cma.set_tenant_setting(''tasks.callback_window_minutes'', ''-1'')')
      || ',' || pg_temp.v8o_err('select cma.set_tenant_setting(''tasks.callback_window_minutes'', ''10081'')');
    perform cma.set_tenant_setting('leads.age_buckets_business_days', '1, 2, 5');
    perform cma.set_tenant_setting('tasks.callback_window_minutes', '0');
    select format('%s/%s', cma.setting_of(v_t1, 'leads.age_buckets_business_days'), cma.setting_of(v_t1, 'tasks.callback_window_minutes')) into v_txt2;
    perform set_config('app.user_id', v_manager1::text, true);
    v_rows := v_rows || array['13', 'B3 ten settings refused; buckets with spaces stored without them; a callback window of 0',
      case when v_txt = 'CMA04,CMA04,CMA04,CMA04,CMA04,CMA04,CMA04,CMA04,CMA04,CMA04' and v_txt2 = '1,2,5/0' and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s | %s', v_txt, v_txt2)];

    -- B4. tickets against the default SLA of 240 minutes with the warning at 75 %: x1 at 74 % ok (63
    --     minutes to breach), x2 at 75 % at risk (60), x3 at 100 % breached (0), x4 at 125 % breached
    --     (-60) and without owner, x5 in Billing at 90 minutes ok under the default, x6 without a market
    --     no_hours with no minutes, last; sorted by the minutes to breach; x7 closed, x8 not counted and
    --     x9 deleted absent; the stage and pipeline labels
    select string_agg(format('%s:%s:%s:%s', t.ticket_source_id, t.sla_state, coalesce(t.minutes_to_breach::text, 'null'), t.sla_minutes), ' ' order by ord) into v_txt
    from (select t.*, row_number() over () as ord from cma.open_tickets() t) t;
    select format('%s %s %s %s', t.pipeline_label, t.stage_label, coalesce(t.owner_ref, '-'), t.market) into v_txt2
    from cma.open_tickets() t where t.ticket_source_id = 'x4';
    v_rows := v_rows || array['14', 'B4 tickets against the default SLA at 74, 75, 100 and 125 %; no business hours apart and last; closed, not counted and deleted absent',
      case when v_txt = 'x4:breached:-60:240 x3:breached:0:240 x2:at_risk:60:240 x1:ok:63:240 x5:ok:150:240 x6:no_hours:null:240'
                and v_txt2 = 'Support New - NL' and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s | x4: %s', v_txt, v_txt2)];

    -- B5. before the tenant configured an SLA, the ticket checks are silent: no ticket_no_owner or
    --     ticket_no_market finding, and data_quality() lists neither; the task check is listed (the
    --     tenant holds tasks) with k3's owner unlinked
    select count(*)::integer into v_n from cma.data_quality_of(v_t1) f where f.check_key in ('ticket_no_owner', 'ticket_no_market');
    select string_agg(format('%s:%s', q.check_key, coalesce(q.total::text, 'null')), ' ' order by q.check_key) into v_txt
    from cma.data_quality() q where q.check_key in ('ticket_no_owner', 'ticket_no_market', 'crm_task_owner_unlinked', 'contact_country_fallback');
    select count(*)::integer into v_m from cma.data_quality();
    v_rows := v_rows || array['15', 'B5 the ticket checks silent before an SLA is configured; the task check listed with one finding',
      case when v_n = 0 and v_txt = 'crm_task_owner_unlinked:1' and v_m = 16 and cma.follow_up_configured_of(v_t1) is false and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s ticket findings | %s | %s rows', v_n, v_txt, v_m)];

    -- B6. the pipeline override: Billing at 60 minutes makes x5 breached (-30), second in the order; the
    --     reader view shows it; refusals: an agent (CMA06), an unknown pipeline (CMA02), 0 and 100001
    --     (CMA04)
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_pipeline_sla(v_crm, 'ticket', 'billing', 60);
    perform set_config('app.user_id', v_manager1::text, true);
    perform cma.refresh_follow_up_of(v_t1);   -- since 0008s the reads come from the snapshot: refreshed after a change
    select string_agg(format('%s:%s:%s:%s', t.ticket_source_id, t.sla_state, coalesce(t.minutes_to_breach::text, 'null'), t.sla_minutes), ' ' order by ord) into v_txt
    from (select t.*, row_number() over () as ord from cma.open_tickets() t) t;
    perform set_config('app.user_id', v_agent1::text, true);
    v_txt2 := pg_temp.v8o_err(format('select cma.set_pipeline_sla(%L, %L, %L, 30)', v_crm, 'ticket', 'support'));
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt2 := v_txt2 || ',' || pg_temp.v8o_err(format('select cma.set_pipeline_sla(%L, %L, %L, 30)', v_crm, 'ticket', 'nowhere'))
      || ',' || pg_temp.v8o_err(format('select cma.set_pipeline_sla(%L, %L, %L, 0)', v_crm, 'ticket', 'support'))
      || ',' || pg_temp.v8o_err(format('select cma.set_pipeline_sla(%L, %L, %L, 100001)', v_crm, 'ticket', 'support'));
    perform set_config('role', 'cma_readonly', true);
    select string_agg(format('%s:%s', p.source_pipeline_id, coalesce(p.sla_minutes::text, 'null')), ' ' order by p.source_pipeline_id) into v_detail
    from cma_read.connection_pipeline_sla p where p.tenant_id = v_t1 and p.record_type = 'ticket';
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_manager1::text, true);
    v_rows := v_rows || array['16', 'B6 the pipeline override beats the default; the reader view; four refusals',
      case when v_txt = 'x4:breached:-60:240 x5:breached:-30:60 x3:breached:0:240 x2:at_risk:60:240 x1:ok:63:240 x6:no_hours:null:240'
                and v_txt2 = 'CMA06,CMA02,CMA04,CMA04' and v_detail = 'billing:60 spam:null support:null' and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s | %s | %s', v_txt, v_txt2, v_detail)];

    -- B7. once configured (the pipeline's SLA): ticket_no_owner finds x4, ticket_no_market finds x6, each
    --     with the pipeline as value; data_quality() lists both with the task check; the dq_ reader
    --     views show them to a reader of this tenant, ids only
    select string_agg(format('%s:%s:%s', f.check_key, f.object_id, f.value), ' ' order by f.check_key, f.object_id) into v_txt
    from cma.data_quality_of(v_t1) f where f.check_key in ('ticket_no_owner', 'ticket_no_market', 'crm_task_owner_unlinked');
    select string_agg(format('%s:%s', q.check_key, coalesce(q.total::text, 'null')), ' ' order by q.check_key) into v_txt2
    from cma.data_quality() q where q.check_key in ('ticket_no_owner', 'ticket_no_market', 'crm_task_owner_unlinked');
    select count(*)::integer into v_m from cma.data_quality();
    perform set_config('role', 'cma_readonly', true);
    select format('%s %s %s', (select string_agg(object_id, ',') from cma_read.dq_ticket_no_owner where tenant_id = v_t1),
                              (select string_agg(object_id, ',') from cma_read.dq_ticket_no_market where tenant_id = v_t1),
                              (select string_agg(object_id || '=' || value, ',') from cma_read.dq_crm_task_owner_unlinked where tenant_id = v_t1)) into v_detail;
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['17', 'B7 the ticket checks once configured: x4 without owner, x6 without market; listed; the dq_ views',
      case when v_txt = 'crm_task_owner_unlinked:k3:o-9 ticket_no_market:x6:support ticket_no_owner:x4:support'
                and v_txt2 = 'crm_task_owner_unlinked:1 ticket_no_market:1 ticket_no_owner:1' and v_m = 18
                and v_detail = 'x4 x6 k3=o-9' and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s | %s | %s rows | readers %s', v_txt, v_txt2, v_m, v_detail)];

    -- B8. the open tasks: k1 overdue (on deal d1, market NL through the deal, agent one, the type and
    --     status labels), k2 today (on ticket x3, agent two), k3 later (owner not mapped), k4 none (no
    --     owner, no due time, no record); in due order; k5 done, k6 uncounted and k7 deleted absent
    select string_agg(format('%s:%s:%s:%s:%s:%s:%s', k.task_source_id, k.due_state,
                             case when k.owner_user_id = v_agent1 then 'agent1' when k.owner_user_id = v_agent2 then 'agent2' else coalesce(k.owner_ref, '-') end,
                             coalesce(k.record_type || '/' || k.record_source_id, '-'), coalesce(k.market, '-'), k.type_label, k.status_label), ' ' order by ord) into v_txt
    from (select k.*, row_number() over () as ord from cma.open_tasks() k) k;
    v_rows := v_rows || array['18', 'B8 the open tasks: due states, records, markets, labels; done, uncounted and deleted absent',
      case when v_txt = 'k1:overdue:agent1:deal/d1:NL:CALL:NOT_STARTED k2:today:agent2:ticket/x3:NL:CALL:NOT_STARTED k3:later:o-9:-:-:CALL:NOT_STARTED k4:none:-:-:-:CALL:NOT_STARTED'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B9. overdue against the tenant's own midnight: in Kiritimati (UTC+14) m1, due at 00:30 today
    --     there, is today although its UTC date is yesterday; m2 at 23:30 yesterday is overdue; m3
    --     tomorrow is later
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    select string_agg(format('%s:%s', k.task_source_id, k.due_state), ' ' order by k.task_source_id) into v_txt from cma.open_tasks() k;
    v_txt2 := format('m1 due %s UTC, the tenant''s date %s', (v_m1 at time zone 'UTC')::date, v_today2);
    v_rows := v_rows || array['19', 'B9 overdue against the tenant''s midnight (Kiritimati): 00:30 today is today though yesterday in UTC',
      case when v_txt = 'm1:today m2:overdue m3:later' and (v_m1 at time zone 'UTC')::date = v_today2 - 1 and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s | %s', v_txt, v_txt2)];
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_manager1::text, true);

    -- B10. the summary: 4 leads not called, 2 past the target, 1 ticket at risk, 3 breached, 1 without
    --      owner, 1 task overdue, 1 due today, 1 with an owner nobody maps to
    select format('%s,%s,%s,%s,%s,%s,%s,%s', s.leads_open_not_called, s.leads_past_target, s.tickets_at_risk, s.tickets_breached,
                  s.tickets_without_owner, s.tasks_overdue, s.tasks_due_today, s.tasks_unmapped_owner) into v_txt
    from cma.follow_up_summary() s;
    v_rows := v_rows || array['20', 'B10 the summary counts',
      case when v_txt = '4,2,1,3,1,1,1,1' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B11. per person: agent one (1 lead past the target; 3 tickets, 1 at risk or breached; 1 task
    --      overdue), agent two (1 lead; 2 tickets, both breached; 1 task today), then the not-mapped
    --      row (2 leads, 1 past the target; 1 ticket breached; no task due); nothing for the manager
    select string_agg(format('%s:%s,%s,%s,%s,%s,%s', coalesce(o.display_name, '-'), o.open_leads, o.leads_past_target, o.open_tickets,
                             o.tickets_at_risk_or_breached, o.tasks_overdue, o.tasks_due_today), ' ' order by ord) into v_txt
    from (select o.*, row_number() over () as ord from cma.follow_up_by_owner() o) o;
    v_rows := v_rows || array['21', 'B11 per person, the not-mapped row last',
      case when v_txt = 'Verify agent one:1,1,3,1,1,0 Verify agent two:1,0,2,2,0,1 -:2,1,1,1,0,0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B12. the person's own rows: agent one gets d1, x2 x1 x6 (the minutes to breach first, no hours
    --      last) and k1 with the deal's and the task's links and no ticket link (no template); agent two
    --      d2, x5 x3, k2; agent three in tenant two, mapped to the same owner id string, gets its three
    --      tasks only and nothing of tenant one
    perform set_config('app.user_id', v_agent1::text, true);
    v_res := cma.my_follow_up();
    select format('%s | %s | %s | %s %s %s',
                  (select string_agg(x ->> 'deal_source_id', ',') from jsonb_array_elements(v_res -> 'leads') x),
                  (select string_agg(x ->> 'ticket_source_id', ',') from jsonb_array_elements(v_res -> 'tickets') x),
                  (select string_agg(x ->> 'task_source_id', ',') from jsonb_array_elements(v_res -> 'tasks') x),
                  v_res -> 'leads' -> 0 ->> 'record_url', coalesce(v_res -> 'tickets' -> 0 ->> 'record_url', 'null'), v_res -> 'tasks' -> 0 ->> 'record_url') into v_txt;
    perform set_config('app.user_id', v_agent2::text, true);
    v_res := cma.my_follow_up();
    select format('%s | %s | %s',
                  (select string_agg(x ->> 'deal_source_id', ',') from jsonb_array_elements(v_res -> 'leads') x),
                  (select string_agg(x ->> 'ticket_source_id', ',') from jsonb_array_elements(v_res -> 'tickets') x),
                  (select string_agg(x ->> 'task_source_id', ',') from jsonb_array_elements(v_res -> 'tasks') x)) into v_txt2;
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_agent3::text, true);
    v_res := cma.my_follow_up();
    select format('%s | %s | %s',
                  coalesce((select string_agg(x ->> 'deal_source_id', ',') from jsonb_array_elements(v_res -> 'leads') x), '-'),
                  coalesce((select string_agg(x ->> 'ticket_source_id', ',') from jsonb_array_elements(v_res -> 'tickets') x), '-'),
                  (select string_agg(x ->> 'task_source_id', ',') from jsonb_array_elements(v_res -> 'tasks') x)) into v_detail;
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_manager1::text, true);
    v_rows := v_rows || array['22', 'B12 the person''s own rows with the record links; two people apart; two tenants apart',
      case when v_txt = 'd1 | x2,x1,x6 | k1 | https://crm.example.invalid/portal-1/deal/d1 null https://crm.example.invalid/portal-1/task/k1'
                and v_txt2 = 'd2 | x5,x3 | k2' and v_detail = '- | - | m2,m1,m3' and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s || %s || %s', v_txt, v_txt2, v_detail)];

    -- B13. the unlinked-call skip rule: by default (a telephony connection) p1, outbound never answered
    --      and untagged, is skipped while p2 (tagged), p3 (inbound) and p4 (connected) are found; the
    --      connection setting none finds all four; set back by name, three again
    select string_agg(f.object_id, ',' order by f.object_id) into v_txt from cma.data_quality_of(v_t1) f where f.check_key = 'telephony_call_unlinked';
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_connection_settings(v_tel, '{"dq_unlinked_skip": "none"}'::jsonb);
    select string_agg(f.object_id, ',' order by f.object_id) into v_txt2 from cma.data_quality_of(v_t1) f where f.check_key = 'telephony_call_unlinked';
    perform cma.set_connection_settings(v_tel, '{"dq_unlinked_skip": "outbound_unanswered_untagged"}'::jsonb);
    select string_agg(f.object_id, ',' order by f.object_id) into v_detail from cma.data_quality_of(v_t1) f where f.check_key = 'telephony_call_unlinked';
    perform set_config('app.user_id', v_manager1::text, true);
    v_rows := v_rows || array['23', 'B13 the unlinked-call skip rule: on by default for telephony, off by setting, inbound, tagged and connected kept',
      case when v_txt = 'p2,p3,p4' and v_txt2 = 'p1,p2,p3,p4' and v_detail = 'p2,p3,p4' and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s | %s | %s', v_txt, v_txt2, v_detail)];

    -- B14. permissions: an agent is refused the five team reads (CMA06) and gets their own; the analyst
    --      (reports.view, no leads.accept or workday.own) gets the summary and is refused their own; a
    --      role with monitoring.live alone gets the open leads and the summary and is refused per
    --      person; the Ingest user is refused the open leads
    perform set_config('app.user_id', v_agent1::text, true);
    v_txt := pg_temp.v8o_err('select count(*) from cma.open_leads()')
      || ',' || pg_temp.v8o_err('select count(*) from cma.open_tickets()')
      || ',' || pg_temp.v8o_err('select count(*) from cma.open_tasks()')
      || ',' || pg_temp.v8o_err('select count(*) from cma.follow_up_summary()')
      || ',' || pg_temp.v8o_err('select count(*) from cma.follow_up_by_owner()')
      || ',' || pg_temp.v8o_err('select cma.my_follow_up()');
    perform set_config('app.user_id', v_analyst1::text, true);
    v_txt2 := pg_temp.v8o_err('select count(*) from cma.follow_up_summary()') || ',' || pg_temp.v8o_err('select cma.my_follow_up()');
    perform set_config('app.user_id', v_watcher1::text, true);
    v_txt2 := v_txt2 || ',' || pg_temp.v8o_err('select count(*) from cma.open_leads()')
      || ',' || pg_temp.v8o_err('select count(*) from cma.follow_up_summary()')
      || ',' || pg_temp.v8o_err('select count(*) from cma.follow_up_by_owner()');
    perform set_config('app.user_id', v_ing1::text, true);
    v_txt2 := v_txt2 || ',' || pg_temp.v8o_err('select count(*) from cma.open_leads()');
    perform set_config('app.user_id', v_manager1::text, true);
    v_rows := v_rows || array['24', 'B14 permissions: the agent, the analyst, monitoring.live alone, the Ingest user',
      case when v_txt = 'CMA06,CMA06,CMA06,CMA06,CMA06,ok' and v_txt2 = 'ok,CMA06,ok,ok,CMA06,CMA06' and not v_provoke then 'PASS' else 'FAIL' end,
      format('agent %s | %s', v_txt, v_txt2)];

    -- B15. a reader scoped to tenant two sees its three open tasks and its summary row, and nothing of
    --      tenant one
    perform set_config('role', 'cma_readonly', true);
    perform set_config('app.tenant_id', v_t2::text, true);
    select count(*)::integer into v_n from cma_read.open_task where tenant_id = v_t1;
    select count(*)::integer into v_m from cma_read.open_task where tenant_id = v_t2;
    select format('%s summary rows of two, %s of one, %s leads of one', (select count(*) from cma_read.follow_up_summary where tenant_id = v_t2),
                  (select count(*) from cma_read.follow_up_summary where tenant_id = v_t1), (select count(*) from cma_read.open_lead where tenant_id = v_t1)) into v_txt;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    v_rows := v_rows || array['25', 'B15 a reader scoped to tenant two sees its own rows and none of tenant one',
      case when v_n = 0 and v_m = 3 and v_txt = '1 summary rows of two, 0 of one, 0 leads of one' and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s tasks of one, %s of two; %s', v_n, v_m, v_txt)];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['39', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008o (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008o values (39, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008o
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED: not dev'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008o where result = 'PASS') = 21
                       and not exists (select 1 from verify_0008o where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0008o where result = 'PASS'),
                                        (select count(*) from verify_0008o where result <> 'PASS'))) x
order by ord;
drop function if exists pg_temp.v8o_err(text);
reset role;
