-- =============================================================================================
-- 81_verify_follow_up_snapshot.sql: verifies addition 0008s, the follow-up snapshot
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure and
-- privileges; block B works on two throwaway tenants inside a subtransaction that is always rolled back.
-- Universal otherwise: nothing of the seed is used; adapters, refs and ids are invented data values.
-- Every check writes one row, PASS or FAIL, and the last result lists them with the verdict, because
-- Cloud SQL Studio shows no notices. Run as your own IAM login in dev, after 80_follow_up_snapshot.sql;
-- then 73 and 79 again (unchanged).
--   A  structure and privileges: the addition row after 0008r; the setting with its default; the
--      permission on every scheduler role and no other; the two tables' columns, row-level security,
--      grants (the application's only), indexes and no audit trigger; the functions the application's
--      only and in the caller's rights; sync_run's job and connection checks with the refresh
--   B  behaviour on tenant one (Amsterdam, a market with office hours around the clock) and tenant two:
--      the fallback filling an empty tenant on its first read; the snapshot's counts, rows, order and
--      figures per person equal to the live functions'; filtered totals equal to filtering the live sets;
--      the rows a list shows honoured and capped, and the setting's refusals; per person absent without
--      performance.team; no row of another tenant; the refresh's tenant lock (a second refresh in another
--      session skips: verify/refresh-follow-up.mjs proves that with two sessions, which one script cannot);
--      the job's permission and its sync_run row; the person's own rows and the summary from the snapshot;
--      0008o's list reads equal to the live sets; a new task seen after the next refresh, not before
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
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 81 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0008s;
create temp table verify_0008s (ord int, check_name text, result text, detail text);

-- The SQLSTATE a statement fails with, or ok
create or replace function pg_temp.v8s_err(p_sql text)
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
  v_bad     text;
  v_cols    text;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  -- A1. the addition is recorded, after 0008r
  insert into verify_0008s values (1, 'A1 addition 0008s recorded, after 0008r',
    case when exists (select 1 from cma.schema_migration where version = '0008s')
              and exists (select 1 from cma.schema_migration where version = '0008r') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the setting with its type and default
  select format('%s:%s:%s', s.key, s.value_type, s.default_value) into v_cols from cma.setting s where s.key = 'follow_up.list_rows';
  insert into verify_0008s values (2, 'A2 follow_up.list_rows, a whole number, 100 by default',
    case when v_cols = 'follow_up.list_rows:integer:100' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_cols, 'none'));

  -- A3. the permission, on every tenant's scheduler role and on no other role
  v_bad := '';
  if not exists (select 1 from cma.permission where key = 'follow_up.refresh') then v_bad := v_bad || 'no permission follow_up.refresh; '; end if;
  if exists (select 1 from cma.app_role r where r.key = 'scheduler'
             and not exists (select 1 from cma.role_permission p where p.tenant_id = r.tenant_id and p.role_id = r.id and p.permission_key = 'follow_up.refresh')) then
    v_bad := v_bad || 'a scheduler role lacks it; ';
  end if;
  if exists (select 1 from cma.role_permission p join cma.app_role r on r.tenant_id = p.tenant_id and r.id = p.role_id
             where p.permission_key = 'follow_up.refresh' and r.key <> 'scheduler') then
    v_bad := v_bad || 'a role other than scheduler holds it; ';
  end if;
  insert into verify_0008s values (3, 'A3 follow_up.refresh on every scheduler role, on no other',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A4. the two tables: exact columns, row-level security with the tenant policy, the application's grants
  --     only, the indexes, no audit trigger (derived, rewritten every minute)
  v_bad := '';
  foreach v_t in array array['follow_up_snapshot=tenant_id,computed_at,duration_ms,summary,by_owner',
                             'follow_up_item=tenant_id,kind,sort_key,item_id,market,owner_user_id,state,row'] loop
    select string_agg(column_name, ',' order by ordinal_position) into v_cols
    from information_schema.columns where table_schema = 'cma' and table_name = split_part(v_t, '=', 1);
    if v_cols is distinct from split_part(v_t, '=', 2) then
      v_bad := v_bad || split_part(v_t, '=', 1) || ' has ' || coalesce(v_cols, 'no columns') || '; ';
      continue;
    end if;
    if not (select relrowsecurity from pg_class where oid = ('cma.' || split_part(v_t, '=', 1))::regclass) then
      v_bad := v_bad || split_part(v_t, '=', 1) || ' without row-level security; ';
    end if;
    if not exists (select 1 from pg_policy where polrelid = ('cma.' || split_part(v_t, '=', 1))::regclass and polname = 'tenant_app') then
      v_bad := v_bad || split_part(v_t, '=', 1) || ' without the tenant policy; ';
    end if;
    if not has_table_privilege('cma_app', 'cma.' || split_part(v_t, '=', 1), 'select, insert, update, delete')
       or has_table_privilege('cma_readonly', 'cma.' || split_part(v_t, '=', 1), 'select') then
      v_bad := v_bad || split_part(v_t, '=', 1) || ' is not the application''s only; ';
    end if;
    if exists (select 1 from pg_trigger where tgrelid = ('cma.' || split_part(v_t, '=', 1))::regclass and tgname = 'audit') then
      v_bad := v_bad || split_part(v_t, '=', 1) || ' has an audit trigger; ';
    end if;
  end loop;
  foreach v_t in array array['follow_up_item_pkey', 'follow_up_item_market_idx', 'follow_up_item_owner_idx', 'follow_up_item_state_idx', 'follow_up_snapshot_pkey'] loop
    if to_regclass('cma.' || v_t) is null then v_bad := v_bad || 'no index ' || v_t || '; '; end if;
  end loop;
  insert into verify_0008s values (4, 'A4 follow_up_snapshot and follow_up_item: columns, RLS, the application''s grants, indexes, no audit trigger',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A5. every function the application's only, in the caller's rights
  v_bad := '';
  foreach v_t in array array[
    'cma.job_run_start(text)', 'cma.job_run_finish(uuid,text,jsonb,text)', 'cma.refresh_follow_up_of(uuid,boolean)', 'cma.refresh_follow_up()',
    'cma.follow_up_snapshot_of(uuid)', 'cma.follow_up_list_of(uuid,text,text,uuid,boolean,boolean,integer)', 'cma.follow_up_owners_of(uuid,jsonb)',
    'cma.follow_up_page(text,text,text,integer)', 'cma.follow_up_computed_at()', 'cma.open_leads()', 'cma.open_tickets()', 'cma.open_tasks()',
    'cma.follow_up_summary()', 'cma.follow_up_by_owner()', 'cma.my_follow_up()'] loop
    if to_regprocedure(v_t) is null then
      v_bad := v_bad || v_t || ' is missing; ';
    elsif not has_function_privilege('cma_app', v_t, 'execute') or has_function_privilege('cma_readonly', v_t, 'execute') then
      v_bad := v_bad || v_t || ' is not the application''s only; ';
    elsif (select prosecdef from pg_proc where oid = to_regprocedure(v_t)) then
      v_bad := v_bad || v_t || ' is security definer; ';
    end if;
  end loop;
  insert into verify_0008s values (5, 'A5 the functions: the application''s only, in the caller''s rights',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A6. sync_run: the refresh on the job list, without a connection like the forgotten-day close
  select string_agg(pg_get_constraintdef(oid), ' | ' order by conname) into v_cols
  from pg_constraint where conrelid = 'cma.sync_run'::regclass and conname in ('sync_run_job_check', 'sync_run_connection_check');
  insert into verify_0008s values (6, 'A6 sync_run: refresh_follow_up on the job list, without a connection',
    case when v_cols like '%refresh_follow_up%refresh_follow_up%' and v_cols like '%close_forgotten_workdays%' and not v_provoke then 'PASS' else 'FAIL' end,
    coalesce(v_cols, 'no checks'));
end
$$;

-- B. Behaviour on two throwaway tenants (rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_rows     text[] := '{}';
  v_now      timestamptz := now();
  v_t1 uuid; v_t2 uuid;
  v_admin1 uuid; v_manager1 uuid; v_watcher1 uuid; v_agent1 uuid; v_agent2 uuid; v_ing1 uuid; v_sched1 uuid;
  v_admin2 uuid; v_agent3 uuid; v_ing2 uuid; v_sched2 uuid;
  v_role uuid;
  v_crm uuid; v_crm2 uuid;
  v_today1   date;
  v_res      jsonb;
  v_res2     jsonb;
  v_txt      text;
  v_txt2     text;
  v_n        integer;
  v_m        integer;
  v_run      uuid;
  v_key      bigint;
  v_ok       boolean;
  f          record;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    v_t1 := cma.create_tenant('verify-0008s-one', 'Verify 0008s one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008s-two', 'Verify 0008s two', 'Europe/Amsterdam');
    v_today1 := (v_now at time zone 'Europe/Amsterdam')::date;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'Verify admin') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-manager1@example.invalid', 'Verify manager') returning id into v_manager1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-watcher1@example.invalid', 'Verify watcher') returning id into v_watcher1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent1@example.invalid', 'Verify agent one') returning id into v_agent1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent2@example.invalid', 'Verify agent two') returning id into v_agent2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'Verify admin two') returning id into v_admin2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-agent3@example.invalid', 'Verify agent three') returning id into v_agent3;
    -- a role of this tenant with monitoring.live alone: the lists, not the figures per person
    insert into cma.app_role (tenant_id, key, name) values (v_t1, 'verify_watcher', 'Verify watcher') returning id into v_role;
    insert into cma.role_permission (tenant_id, role_id, permission_key) values (v_t1, v_role, 'monitoring.live');
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_manager1, 'manager'), (v_t1, v_watcher1, 'verify_watcher'),
                 (v_t1, v_agent1, 'agent'), (v_t1, v_agent2, 'agent'), (v_t2, v_admin2, 'admin'), (v_t2, v_agent3, 'agent')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select id into v_ing1 from cma.app_user where tenant_id = v_t1 and email = 'ingest@system.invalid';
    select id into v_ing2 from cma.app_user where tenant_id = v_t2 and email = 'ingest@system.invalid';
    select id into v_sched1 from cma.app_user where tenant_id = v_t1 and email = 'scheduler@system.invalid';
    select id into v_sched2 from cma.app_user where tenant_id = v_t2 and email = 'scheduler@system.invalid';
    perform set_config('role', 'cma_app', true);

    -- tenant one (the admin): a market with office hours around the clock, the intake start, the lead target
    -- of an hour, two owners linked to people, a CRM connection with record links for deals, tickets and tasks
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.set_business_hours('*', d::smallint, '00:00-24:00') from generate_series(1, 7) d;
    perform cma.set_tenant_setting('intake.start_date', (v_today1 - 30)::text);
    perform cma.set_tenant_setting('speed_to_lead.target_minutes', '60');
    perform cma.set_user_external_id(v_agent1, 'verifycrm_owner', 'o-1');
    perform cma.set_user_external_id(v_agent2, 'verifycrm_owner', 'o-2');
    select c.connection_id into v_crm from cma.upsert_connection('verifycrm', 'Verify CRM one', 'portal-1', null, null) c;
    perform cma.set_connection_kind(v_crm, 'crm');
    perform cma.set_connection_settings(v_crm, '{"record_url_deal": "https://crm.example.invalid/{account}/deal/{id}", "record_url_ticket": "https://crm.example.invalid/{account}/ticket/{id}", "record_url_task": "https://crm.example.invalid/{account}/task/{id}"}'::jsonb);
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_pipelines(v_crm, '[
      {"recordType": "deal", "pipelineId": "sales", "label": "Sales", "stages": [
         {"stageId": "s1", "label": "Open", "order": 1, "isClosed": false}, {"stageId": "s9", "label": "Lost", "order": 9, "isClosed": true}]},
      {"recordType": "ticket", "pipelineId": "support", "label": "Support", "stages": [
         {"stageId": "t1", "label": "New", "order": 1, "isClosed": false}, {"stageId": "t9", "label": "Closed", "order": 9, "isClosed": true}]}]');
    -- leads: past the target (o-1, o-9 nobody, o-1), within it (o-2), without a market (no owner); tickets ok, at risk,
    -- breached twice (one without an owner) and without a market; tasks overdue twice, today, later twice, without a due time
    perform cma.ingest_upsert_records(v_crm, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd1', 'pipelineId', 'sales', 'stageId', 's1', 'ownerRef', 'o-1', 'contactId', 'c1', 'market', 'NL',
                         'createdAt', v_now - interval '3 days', 'updatedAt', v_now - interval '3 days'),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd2', 'pipelineId', 'sales', 'stageId', 's1', 'ownerRef', 'o-2', 'contactId', 'c2', 'market', 'NL',
                         'createdAt', v_now - interval '30 minutes', 'updatedAt', v_now - interval '30 minutes'),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd3', 'pipelineId', 'sales', 'stageId', 's1', 'ownerRef', 'o-9', 'contactId', 'c3', 'market', 'NL',
                         'createdAt', v_now - interval '2 days', 'updatedAt', v_now - interval '2 days'),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd4', 'pipelineId', 'sales', 'stageId', 's1', 'contactId', 'c4',
                         'createdAt', v_now - interval '1 day', 'updatedAt', v_now - interval '1 day'),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd5', 'pipelineId', 'sales', 'stageId', 's1', 'ownerRef', 'o-1', 'contactId', 'c5', 'market', 'NL',
                         'createdAt', v_now - interval '2 hours', 'updatedAt', v_now - interval '2 hours'),
      jsonb_build_object('recordType', 'ticket', 'sourceId', 'x1', 'pipelineId', 'support', 'stageId', 't1', 'ownerRef', 'o-1', 'contactId', 'c1', 'market', 'NL',
                         'createdAt', v_now - interval '60 minutes', 'updatedAt', v_now - interval '60 minutes'),
      jsonb_build_object('recordType', 'ticket', 'sourceId', 'x2', 'pipelineId', 'support', 'stageId', 't1', 'ownerRef', 'o-1', 'contactId', 'c2', 'market', 'NL',
                         'createdAt', v_now - interval '200 minutes', 'updatedAt', v_now - interval '200 minutes'),
      jsonb_build_object('recordType', 'ticket', 'sourceId', 'x3', 'pipelineId', 'support', 'stageId', 't1', 'ownerRef', 'o-2', 'contactId', 'c3', 'market', 'NL',
                         'createdAt', v_now - interval '250 minutes', 'updatedAt', v_now - interval '250 minutes'),
      jsonb_build_object('recordType', 'ticket', 'sourceId', 'x4', 'pipelineId', 'support', 'stageId', 't1', 'contactId', 'c4', 'market', 'NL',
                         'createdAt', v_now - interval '300 minutes', 'updatedAt', v_now - interval '300 minutes'),
      jsonb_build_object('recordType', 'ticket', 'sourceId', 'x5', 'pipelineId', 'support', 'stageId', 't1', 'ownerRef', 'o-2', 'contactId', 'c5',
                         'createdAt', v_now - interval '10 minutes', 'updatedAt', v_now - interval '10 minutes')));
    perform cma.ingest_upsert_tasks(v_crm, jsonb_build_array(
      jsonb_build_object('sourceId', 'k1', 'statusRef', 'NOT_STARTED', 'typeRef', 'CALL', 'ownerRef', 'o-1', 'dealId', 'd1',
                         'dueAt', ((v_today1 - 2) + time '10:00') at time zone 'Europe/Amsterdam', 'createdAt', v_now - interval '3 days', 'updatedAt', v_now - interval '3 days'),
      jsonb_build_object('sourceId', 'k2', 'statusRef', 'NOT_STARTED', 'typeRef', 'CALL', 'ownerRef', 'o-2', 'ticketId', 'x3',
                         'dueAt', (v_today1 + time '00:30') at time zone 'Europe/Amsterdam', 'createdAt', v_now - interval '2 days', 'updatedAt', v_now - interval '2 days'),
      jsonb_build_object('sourceId', 'k3', 'statusRef', 'NOT_STARTED', 'typeRef', 'CALL', 'ownerRef', 'o-9',
                         'dueAt', ((v_today1 + 1) + time '09:00') at time zone 'Europe/Amsterdam', 'createdAt', v_now - interval '2 days', 'updatedAt', v_now - interval '2 days'),
      jsonb_build_object('sourceId', 'k4', 'statusRef', 'NOT_STARTED', 'typeRef', 'EMAIL',
                         'createdAt', v_now - interval '2 days', 'updatedAt', v_now - interval '2 days'),
      jsonb_build_object('sourceId', 'k5', 'statusRef', 'NOT_STARTED', 'typeRef', 'CALL', 'ownerRef', 'o-1', 'dealId', 'd5',
                         'dueAt', ((v_today1 - 1) + time '15:00') at time zone 'Europe/Amsterdam', 'createdAt', v_now - interval '2 days', 'updatedAt', v_now - interval '2 days'),
      jsonb_build_object('sourceId', 'k6', 'statusRef', 'NOT_STARTED', 'typeRef', 'CALL', 'ownerRef', 'o-2', 'dealId', 'd2',
                         'dueAt', ((v_today1 + 3) + time '11:00') at time zone 'Europe/Amsterdam', 'createdAt', v_now - interval '1 day', 'updatedAt', v_now - interval '1 day')));

    -- tenant two: one of each, owned by its agent
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.set_business_hours('*', d::smallint, '00:00-24:00') from generate_series(1, 7) d;
    perform cma.set_tenant_setting('intake.start_date', (v_today1 - 30)::text);
    perform cma.set_user_external_id(v_agent3, 'verifycrm_owner', 'p-1');
    select c.connection_id into v_crm2 from cma.upsert_connection('verifycrm', 'Verify CRM two', 'portal-2', null, null) c;
    perform cma.set_connection_kind(v_crm2, 'crm');
    perform set_config('app.user_id', v_ing2::text, true);
    perform cma.ingest_upsert_pipelines(v_crm2, '[
      {"recordType": "deal", "pipelineId": "sales", "label": "Sales", "stages": [{"stageId": "s1", "label": "Open", "order": 1, "isClosed": false}]},
      {"recordType": "ticket", "pipelineId": "support", "label": "Support", "stages": [{"stageId": "t1", "label": "New", "order": 1, "isClosed": false}]}]');
    perform cma.ingest_upsert_records(v_crm2, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'e1', 'pipelineId', 'sales', 'stageId', 's1', 'ownerRef', 'p-1', 'market', 'NL',
                         'createdAt', v_now - interval '1 day', 'updatedAt', v_now - interval '1 day'),
      jsonb_build_object('recordType', 'ticket', 'sourceId', 'y1', 'pipelineId', 'support', 'stageId', 't1', 'ownerRef', 'p-1', 'market', 'NL',
                         'createdAt', v_now - interval '1 day', 'updatedAt', v_now - interval '1 day')));
    perform cma.ingest_upsert_tasks(v_crm2, jsonb_build_array(
      jsonb_build_object('sourceId', 'm1', 'statusRef', 'NOT_STARTED', 'typeRef', 'CALL', 'ownerRef', 'p-1',
                         'dueAt', v_now - interval '2 days', 'createdAt', v_now - interval '3 days', 'updatedAt', v_now - interval '3 days')));

    -- B1. the fallback: tenant one has no snapshot until its first read, which computes it once
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_manager1::text, true);
    select count(*)::integer into v_n from cma.follow_up_snapshot;
    v_res := cma.follow_up_page();
    select count(*)::integer into v_m from cma.follow_up_snapshot where tenant_id = v_t1;
    v_rows := v_rows || array['11', 'B1 the fallback: no snapshot before the first read, the read computes one',
      case when v_n = 0 and v_m = 1 and v_res ->> 'computed_at' is not null and (v_res -> 'leads' ->> 'total')::integer = 5 and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s snapshots before, %s after; %s leads', v_n, v_m, v_res -> 'leads' ->> 'total')];

    -- B2. the summary and the order of the ids equal to the live functions' (the same transaction, so the same now())
    select (select to_jsonb(x) - 'tenant_id' from cma.follow_up_summary_of(v_t1) x) = s.summary into v_ok from cma.follow_up_snapshot s where s.tenant_id = v_t1;
    select string_agg(i.kind || ':' || i.item_id, ',' order by i.kind, i.sort_key) into v_txt from cma.follow_up_item i where i.tenant_id = v_t1;
    select string_agg(k || ':' || id, ',' order by k, n) into v_txt2 from (
      select 'lead' as k, l.deal_id as id, l.n from cma.open_leads_of(v_t1) with ordinality l(tenant_id, deal_id, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15, c16, c17, n)
      union all select 'task', t.task_id, t.n from cma.open_tasks_of(v_t1) with ordinality t(tenant_id, task_id, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15, c16, c17, c18, n)
      union all select 'ticket', x.ticket_id, x.n from cma.open_tickets_of(v_t1) with ordinality x(tenant_id, ticket_id, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15, c16, n)) z;
    v_rows := v_rows || array['12', 'B2 the summary and every row in order equal to the live functions''',
      case when v_ok and v_txt = v_txt2 and (select count(*) from cma.follow_up_item where tenant_id = v_t1) = 16 and not v_provoke then 'PASS' else 'FAIL' end,
      format('summary equal %s; %s items', v_ok, (select count(*) from cma.follow_up_item where tenant_id = v_t1))];

    -- B3. the rows' fields equal to the live rows (both ways), and the figures per person equal to follow_up_by_owner_of
    select (select count(*) from ((select (jsonb_populate_record(null::cma.open_lead_row, i.row || jsonb_build_object('tenant_id', i.tenant_id))).*
                                   from cma.follow_up_item i where i.tenant_id = v_t1 and i.kind = 'lead'
                                   except all select * from cma.open_leads_of(v_t1))
                                  union all (select * from cma.open_leads_of(v_t1)
                                   except all select (jsonb_populate_record(null::cma.open_lead_row, i.row || jsonb_build_object('tenant_id', i.tenant_id))).*
                                   from cma.follow_up_item i where i.tenant_id = v_t1 and i.kind = 'lead')) d)
         + (select count(*) from ((select (jsonb_populate_record(null::cma.open_ticket_row, i.row || jsonb_build_object('tenant_id', i.tenant_id))).*
                                   from cma.follow_up_item i where i.tenant_id = v_t1 and i.kind = 'ticket'
                                   except all select * from cma.open_tickets_of(v_t1))
                                  union all (select * from cma.open_tickets_of(v_t1)
                                   except all select (jsonb_populate_record(null::cma.open_ticket_row, i.row || jsonb_build_object('tenant_id', i.tenant_id))).*
                                   from cma.follow_up_item i where i.tenant_id = v_t1 and i.kind = 'ticket')) d)
         + (select count(*) from ((select (jsonb_populate_record(null::cma.open_task_row, i.row || jsonb_build_object('tenant_id', i.tenant_id))).*
                                   from cma.follow_up_item i where i.tenant_id = v_t1 and i.kind = 'task'
                                   except all select * from cma.open_tasks_of(v_t1))
                                  union all (select * from cma.open_tasks_of(v_t1)
                                   except all select (jsonb_populate_record(null::cma.open_task_row, i.row || jsonb_build_object('tenant_id', i.tenant_id))).*
                                   from cma.follow_up_item i where i.tenant_id = v_t1 and i.kind = 'task')) d)
      into v_n;
    select string_agg(format('%s/%s/%s/%s/%s/%s/%s/%s', o.owner_user_id, o.display_name, o.open_leads, o.leads_past_target, o.open_tickets,
                             o.tickets_at_risk_or_breached, o.tasks_overdue, o.tasks_due_today), ',') into v_txt
    from cma.follow_up_owners_of(v_t1, (select s.by_owner from cma.follow_up_snapshot s where s.tenant_id = v_t1)) o;
    select string_agg(format('%s/%s/%s/%s/%s/%s/%s/%s', o.owner_user_id, o.display_name, o.open_leads, o.leads_past_target, o.open_tickets,
                             o.tickets_at_risk_or_breached, o.tasks_overdue, o.tasks_due_today), ',') into v_txt2
    from cma.follow_up_by_owner_of(v_t1) o;
    v_rows := v_rows || array['13', 'B3 every row''s fields and the figures per person equal to the live functions''',
      case when v_n = 0 and v_txt = v_txt2 and v_txt is not null and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s rows differ; per person %s', v_n, case when v_txt = v_txt2 then 'equal' else coalesce(v_txt, 'none') || ' | ' || coalesce(v_txt2, 'none') end)];

    -- B4. filtered totals equal to filtering the live sets: market, person, nobody, attention, and two at once
    v_txt := '';
    for f in select * from (values ('NL', null::uuid, false, false), ('unknown', null::uuid, false, false), (null, v_agent1, false, false),
                                   (null, null::uuid, true, false), (null, null::uuid, false, true), ('NL', v_agent2, false, true)) x(mk, own, unowned, att) loop
      v_res := cma.follow_up_page(f.mk, case when f.unowned then 'none' else f.own::text end, case when f.att then 'attention' end, null);
      v_n := (select count(*) from cma.open_leads_of(v_t1) l where (f.mk is null or coalesce(l.market, 'unknown') = f.mk)
                and (f.own is null or l.owner_user_id = f.own) and (not f.unowned or l.owner_user_id is null) and (not f.att or l.past_target is true))
           + 100 * (select count(*) from cma.open_tickets_of(v_t1) t where (f.mk is null or coalesce(t.market, 'unknown') = f.mk)
                and (f.own is null or t.owner_user_id = f.own) and (not f.unowned or t.owner_user_id is null) and (not f.att or t.sla_state in ('at_risk', 'breached')))
           + 10000 * (select count(*) from cma.open_tasks_of(v_t1) k where (f.mk is null or coalesce(k.market, 'unknown') = f.mk)
                and (f.own is null or k.owner_user_id = f.own) and (not f.unowned or k.owner_user_id is null) and (not f.att or k.due_state = 'overdue'));
      v_m := (v_res -> 'leads' ->> 'total')::integer + 100 * (v_res -> 'tickets' ->> 'total')::integer + 10000 * (v_res -> 'tasks' ->> 'total')::integer;
      if v_n <> v_m then v_txt := v_txt || format('%s/%s/%s/%s: live %s, page %s; ', f.mk, f.own, f.unowned, f.att, v_n, v_m); end if;
    end loop;
    v_rows := v_rows || array['14', 'B4 filtered totals equal to filtering the live sets (market, person, nobody, attention, combined)',
      case when v_txt = '' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B5. the rows a list shows: the default 100, p_rows honoured, 0 lifted to 1, 1000 capped at 500; the setting at 3
    --     read back, and its refusals (0, 501, not a number)
    v_res := cma.follow_up_page(null, null, null, 2);
    v_res2 := cma.follow_up_page(null, null, null, 0);
    v_txt := format('%s,%s:%s/%s/%s,%s:%s,%s', (cma.follow_up_page() ->> 'rows'), v_res ->> 'rows', jsonb_array_length(v_res -> 'leads' -> 'rows'),
                    jsonb_array_length(v_res -> 'tickets' -> 'rows'), jsonb_array_length(v_res -> 'tasks' -> 'rows'),
                    v_res2 ->> 'rows', jsonb_array_length(v_res2 -> 'tasks' -> 'rows'), cma.follow_up_page(null, null, null, 1000) ->> 'rows');
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt2 := pg_temp.v8s_err($q$select cma.set_tenant_setting('follow_up.list_rows', '0')$q$) || ','
           || pg_temp.v8s_err($q$select cma.set_tenant_setting('follow_up.list_rows', '501')$q$) || ','
           || pg_temp.v8s_err($q$select cma.set_tenant_setting('follow_up.list_rows', 'many')$q$) || ','
           || pg_temp.v8s_err($q$select cma.set_tenant_setting('follow_up.list_rows', '3')$q$);
    perform set_config('app.user_id', v_manager1::text, true);
    v_res := cma.follow_up_page();
    v_txt2 := v_txt2 || format(',%s:%s', v_res ->> 'rows', jsonb_array_length(v_res -> 'tasks' -> 'rows'));
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('follow_up.list_rows', null);
    perform set_config('app.user_id', v_manager1::text, true);
    v_rows := v_rows || array['15', 'B5 the rows a list shows: 100 by default, honoured, at least 1, at most 500; the setting and its refusals',
      case when v_txt = '100,2:2/2/2,1:1,500' and v_txt2 = 'CMA04,CMA04,CMA04,ok,3:3' and not v_provoke then 'PASS' else 'FAIL' end,
      v_txt || ' | ' || v_txt2];

    -- B6. per person: for performance.team (the manager: two people and the not-linked row), absent for
    --     monitoring.live alone (the watcher), whose own call is refused
    v_n := jsonb_array_length(cma.follow_up_page() -> 'by_owner');
    perform set_config('app.user_id', v_watcher1::text, true);
    v_res := cma.follow_up_page();
    v_txt := jsonb_typeof(v_res -> 'by_owner') || ',' || (v_res -> 'leads' ->> 'total') || ',' || pg_temp.v8s_err('select count(*) from cma.follow_up_by_owner()');
    perform set_config('app.user_id', v_manager1::text, true);
    v_rows := v_rows || array['16', 'B6 per person for performance.team, absent without it (monitoring.live alone)',
      case when v_n = 3 and v_txt = 'null,5,CMA06' and not v_provoke then 'PASS' else 'FAIL' end, format('%s rows for the manager; watcher %s', v_n, v_txt)];

    -- B7. no row of another tenant: tenant two's snapshot (its admin's first read) is invisible from tenant one, which
    --     cannot refresh it either; tenant one's page names none of tenant two's records
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    v_res2 := cma.follow_up_page();
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_manager1::text, true);
    v_txt := format('%s,%s,%s,%s', (select count(*) from cma.follow_up_item where tenant_id = v_t2), (select count(*) from cma.follow_up_snapshot where tenant_id = v_t2),
                    pg_temp.v8s_err(format('select cma.refresh_follow_up_of(%L::uuid)', v_t2)),
                    case when cma.follow_up_page()::text ~ '"(deal|ticket|task)_source_id": "(e1|y1|m1)"' then 'named' else 'none' end);
    v_rows := v_rows || array['17', 'B7 no row of another tenant: invisible, not refreshable, not on the page',
      case when v_txt = '0,0,CMA06,none' and (v_res2 -> 'leads' ->> 'total') = '1' and (v_res2 -> 'tasks' ->> 'total') = '1' and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s; tenant two''s own page: %s leads, %s tasks', v_txt, v_res2 -> 'leads' ->> 'total', v_res2 -> 'tasks' ->> 'total')];

    -- B8. the refresh holds its tenant's transaction-level advisory lock until the transaction ends (a second refresh
    --     in another session skips meanwhile: verify/refresh-follow-up.mjs proves it with two sessions)
    v_key := cma.follow_up_lock_key(v_t1);
    v_ok := exists (select 1 from pg_locks l where l.locktype = 'advisory' and l.pid = pg_backend_pid() and l.mode = 'ExclusiveLock'
                    and l.objsubid = 1 and ((l.classid::bigint << 32) | l.objid::bigint) = v_key);
    v_rows := v_rows || array['18', 'B8 the refresh holds its tenant''s transaction-level advisory lock',
      case when v_ok and pg_get_functiondef('cma.refresh_follow_up_of(uuid,boolean)'::regprocedure) like '%pg_try_advisory_xact_lock(cma.follow_up_lock_key(p_tenant_id))%'
                and not v_provoke then 'PASS' else 'FAIL' end,
      format('lock held %s', v_ok)];

    -- B9. the job: the scheduler user refreshes and writes its run row (start, finish once, counts); the manager may not;
    --     a job that is no scheduler job and bad counts are refused; System health lists the run
    perform set_config('app.user_id', v_sched1::text, true);
    v_run := cma.job_run_start('refresh_follow_up');
    v_res := cma.refresh_follow_up();
    perform cma.job_run_finish(v_run, 'succeeded', jsonb_build_object('rows', (v_res ->> 'rows')::integer, 'duration_ms', (v_res ->> 'duration_ms')::integer));
    v_txt := (v_res ->> 'refreshed') || ',' || (v_res ->> 'rows') || ','
          || pg_temp.v8s_err(format('select cma.job_run_finish(%L::uuid, ''succeeded'', ''{}''::jsonb)', v_run)) || ','
          || pg_temp.v8s_err('select cma.job_run_start(''reconcile'')') || ','
          || pg_temp.v8s_err(format('select cma.job_run_finish(%L::uuid, ''failed'', ''{"rows": "many"}''::jsonb)', cma.job_run_start('refresh_follow_up')));
    perform set_config('app.user_id', v_manager1::text, true);
    v_txt := v_txt || ',' || pg_temp.v8s_err('select cma.refresh_follow_up()') || ',' || pg_temp.v8s_err('select cma.job_run_start(''refresh_follow_up'')');
    perform set_config('app.user_id', v_admin1::text, true);
    select format('%s:%s:%s', case when r.last_succeeded_at is not null then 'succeeded' else 'none' end, r.runs_24h,
                  case when r.connection_id is null then 'no connection' else 'a connection' end) into v_txt2
    from cma.system_health_runs() r where r.job = 'refresh_follow_up';
    perform set_config('app.user_id', v_manager1::text, true);
    v_rows := v_rows || array['19', 'B9 the job: the scheduler refreshes and writes its run row once; refusals; System health lists it',
      case when v_txt = 'true,16,CMA03,CMA04,CMA04,CMA06,CMA06' and v_txt2 = 'succeeded:2:no connection' and not v_provoke then 'PASS' else 'FAIL' end,
      v_txt || ' | ' || coalesce(v_txt2, 'no run listed')];

    -- B10. the person's own rows from the snapshot: exactly theirs, every row, with when they were computed
    perform set_config('app.user_id', v_agent1::text, true);
    v_res := cma.my_follow_up();
    select string_agg(x ->> 'deal_source_id', ',' order by x ->> 'deal_source_id') || '|' ||
           (select string_agg(x2 ->> 'ticket_source_id', ',' order by x2 ->> 'ticket_source_id') from jsonb_array_elements(v_res -> 'tickets') x2) || '|' ||
           (select string_agg(x3 ->> 'task_source_id', ',' order by x3 ->> 'task_source_id') from jsonb_array_elements(v_res -> 'tasks') x3)
      into v_txt from jsonb_array_elements(v_res -> 'leads') x;
    select string_agg(l.deal_source_id, ',' order by l.deal_source_id) || '|' ||
           (select string_agg(t.ticket_source_id, ',' order by t.ticket_source_id) from cma.open_tickets_of(v_t1) t where t.owner_user_id = v_agent1) || '|' ||
           (select string_agg(k.task_source_id, ',' order by k.task_source_id) from cma.open_tasks_of(v_t1) k where k.owner_user_id = v_agent1)
      into v_txt2 from cma.open_leads_of(v_t1) l where l.owner_user_id = v_agent1;
    v_rows := v_rows || array['20', 'B10 the person''s own rows from the snapshot: exactly theirs, with computed_at and their links',
      case when v_txt = v_txt2 and v_txt = 'd1,d5|x1,x2|k1,k5' and (v_res ->> 'computed_at')::timestamptz = (select computed_at from cma.follow_up_snapshot where tenant_id = v_t1)
                and v_res -> 'leads' -> 0 ->> 'record_url' like 'https://crm.example.invalid/portal-1/deal/%' and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s | live %s', v_txt, v_txt2)];

    -- B11. 0008o's reads from the snapshot: the summary with computed_at, every list row equal to the live set
    perform set_config('app.user_id', v_manager1::text, true);
    select (to_jsonb(s) - 'tenant_id' - 'computed_at') = (select to_jsonb(x) - 'tenant_id' from cma.follow_up_summary_of(v_t1) x)
           and s.computed_at = (select computed_at from cma.follow_up_snapshot where tenant_id = v_t1)
      into v_ok from cma.follow_up_summary() s;
    select (select count(*) from ((select * from cma.open_leads() except all select * from cma.open_leads_of(v_t1))
                                  union all (select * from cma.open_leads_of(v_t1) except all select * from cma.open_leads())) d)
         + (select count(*) from ((select * from cma.open_tickets() except all select * from cma.open_tickets_of(v_t1))
                                  union all (select * from cma.open_tickets_of(v_t1) except all select * from cma.open_tickets())) d)
         + (select count(*) from ((select * from cma.open_tasks() except all select * from cma.open_tasks_of(v_t1))
                                  union all (select * from cma.open_tasks_of(v_t1) except all select * from cma.open_tasks())) d)
      into v_n;
    v_rows := v_rows || array['21', 'B11 0008o''s reads from the snapshot: the summary with computed_at, the lists equal to the live sets',
      case when v_ok and v_n = 0 and (select count(*) from cma.follow_up_by_owner()) = 3 and not v_provoke then 'PASS' else 'FAIL' end,
      format('summary %s; %s rows differ', v_ok, v_n)];

    -- B12. a new overdue task: not on the page before the next refresh, counted after it
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_tasks(v_crm, jsonb_build_array(
      jsonb_build_object('sourceId', 'k9', 'statusRef', 'NOT_STARTED', 'typeRef', 'CALL', 'ownerRef', 'o-1',
                         'dueAt', ((v_today1 - 3) + time '10:00') at time zone 'Europe/Amsterdam', 'createdAt', v_now - interval '4 days', 'updatedAt', v_now - interval '4 days')));
    perform set_config('app.user_id', v_manager1::text, true);
    v_res := cma.follow_up_page();
    perform set_config('app.user_id', v_sched1::text, true);
    perform cma.refresh_follow_up();
    perform set_config('app.user_id', v_manager1::text, true);
    v_res2 := cma.follow_up_page();
    v_txt := format('%s/%s -> %s/%s', v_res -> 'tasks' ->> 'total', v_res -> 'summary' ->> 'tasks_overdue', v_res2 -> 'tasks' ->> 'total', v_res2 -> 'summary' ->> 'tasks_overdue');
    v_rows := v_rows || array['22', 'B12 a new task: not on the page before the next refresh, counted after it',
      case when (v_res2 -> 'tasks' ->> 'total')::integer = (v_res -> 'tasks' ->> 'total')::integer + 1
                and (v_res2 -> 'summary' ->> 'tasks_overdue')::integer = (v_res -> 'summary' ->> 'tasks_overdue')::integer + 1 and not v_provoke then 'PASS' else 'FAIL' end,
      v_txt];

    -- B13. the page's other parts: the filter choices from every row (unknown last, the people by name, nobody), the
    --      counts before the filters, the record links, the two settings the hints name
    v_res := cma.follow_up_page('NL', null, 'attention', null);
    v_txt := format('%s|%s|%s|%s|%s|%s', v_res -> 'options' -> 'markets', (select string_agg(o ->> 'name', ',') from jsonb_array_elements(v_res -> 'options' -> 'owners') o),
                    v_res -> 'options' ->> 'has_unowned', v_res -> 'counts', v_res -> 'settings' ->> 'target_minutes',
                    case when v_res -> 'leads' -> 'rows' -> 0 ->> 'record_url' like 'https://crm.example.invalid/portal-1/deal/d%' then 'linked' else 'no link' end);
    v_rows := v_rows || array['23', 'B13 the filter choices from every row, the counts before the filters, the links and settings',
      case when v_txt = '["NL", "unknown"]|Verify agent one,Verify agent two|true|{"lead": 5, "task": 7, "ticket": 5}|60|linked' and not v_provoke then 'PASS' else 'FAIL' end,
      v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['39', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008s (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008s values (39, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008s
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED: not dev'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008s where result = 'PASS') = 19
                       and not exists (select 1 from verify_0008s where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0008s where result = 'PASS'),
                                        (select count(*) from verify_0008s where result <> 'PASS'))) x
order by ord;
drop function if exists pg_temp.v8s_err(text);
reset role;
