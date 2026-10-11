-- =============================================================================================
-- 41_verify_lead_metrics.sql: verifies migration 0007d, lead metrics and data quality
-- =============================================================================================
-- Block A checks structure and privileges; blocks B to F each build throwaway tenants inside a
-- subtransaction that is always rolled back. All universal: no seed is assumed. Cloud SQL Studio
-- shows no notices: a check that fails raises "FAIL …" and stops the block. The last result is the
-- verdict. Run as your own IAM login, dev and prod, after 40_lead_metrics.sql; then
-- 37_verify_commerce.sql, 35_verifytelephony.sql, 33_verify_intake_core.sql and
-- 31_verify_ingest_crm_records.sql again.
--   A  structure and privileges: the functions (the application's, the helpers, 0007's business
--      time now sharing the code), the readers' four security definer functions, the views and
--      their columns, no raw, hash or key columns, the settings
--   B  speed to lead on a constructed week (markets NL and GB, office hours, a holiday): a deal
--      called after 7 business minutes; Friday 16:55 to Monday 09:10 (15 business minutes, not
--      64 hours; before the next noon); never called, open and closed; an inbound call first; a
--      call on the deal only; a call on a second associated contact; calls before creation
--      outside and inside the pre-window; a linked telephony call moving the start; a removed
--      association; non-lead and uncounted pipelines left out; the market from the deal (through
--      an alias added later), from the contact, unknown; the agent from the call's and from the
--      deal's owner; a holiday; the summary by market, day, agent and pipeline; the 92-day bound
--   C  lead to order: first, repeat and renewal, a test order, a cancelled order and an order
--      after lead_to_order.max_days ignored, an order through ref slot 2
--   D  intake per day per market: forms (counted, without market, not counted), deals and tickets
--      created and closed, calls in and out on counted lines, tagged calls, new customers, orders
--   E  data quality: every check firing exactly once on purpose, then cleared for one
--   F  permissions (an agent refused, the supervisor without data quality, the Ingest user
--      refused, no acting user), tenant isolation for the application and for readers, the
--      readers' views equal to the application's rows, readers and the application kept to their
--      own functions
-- Provoke: set provoke below to true; every block must then stop with FAIL, and the verdict
-- (reached only when the run does not stop on errors) says PROVOKED instead of PASS.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);   -- 'true' to make every block fail

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_fn      text;
  v_t       text;
  v_n       int;
  v_cols    text;
begin
  -- A1. the migration is recorded
  if not exists (select 1 from cma.schema_migration where version = '0007d') or v_provoke then
    raise exception 'FAIL A1: migration 0007d not recorded';
  end if;

  -- A2. the application's functions and their helpers: cma_app may execute them, readers and
  --     public may not; none runs as its owner (0007's business time functions included)
  foreach v_fn in array array[
    'cma.speed_to_lead_rows(date,date)', 'cma.speed_to_lead_summary(date,date,text)',
    'cma.lead_to_order_rows(date,date)', 'cma.intake_per_day(date,date)', 'cma.data_quality()',
    'cma.setting_of(uuid,text)', 'cma.market_code_of(uuid,text)', 'cma.record_market_of(uuid,uuid,text,text)',
    'cma.business_seconds_of(uuid,text,timestamptz,timestamptz)', 'cma.next_business_noon_of(uuid,text,timestamptz)',
    'cma.report_range(uuid,date,date)', 'cma.lead_deals_of(uuid,timestamptz,timestamptz)',
    'cma.lead_calls_of(uuid,uuid,text,text,text[],timestamptz)', 'cma.speed_to_lead_of(uuid,timestamptz,timestamptz)',
    'cma.lead_to_order_of(uuid,timestamptz,timestamptz)', 'cma.intake_per_day_of(uuid,timestamptz,timestamptz)',
    'cma.data_quality_checks()', 'cma.data_quality_of(uuid)',
    'cma.business_seconds(text,timestamptz,timestamptz)', 'cma.next_business_noon(text,timestamptz)'
  ] loop
    if to_regprocedure(v_fn) is null then
      raise exception 'FAIL A2: % does not exist', v_fn;
    end if;
    if not has_function_privilege('cma_app', v_fn, 'execute')
       or has_function_privilege('cma_readonly', v_fn, 'execute')
       or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                  where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE') then
      raise exception 'FAIL A2: execute on % must be granted to cma_app only', v_fn;
    end if;
    if (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      raise exception 'FAIL A2: % must run with the caller''s rights', v_fn;
    end if;
  end loop;

  -- A3. the readers' functions: security definer owned by cma_owner with a pinned search path
  --     (pg_temp last); readers may execute them, the application and public may not
  foreach v_fn in array array[
    'cma_read.speed_to_lead_rows()', 'cma_read.lead_to_order_rows()',
    'cma_read.intake_per_day_rows()', 'cma_read.data_quality_rows()'
  ] loop
    if to_regprocedure(v_fn) is null then
      raise exception 'FAIL A3: % does not exist', v_fn;
    end if;
    if not (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
       or (select pg_get_userbyid(proowner) from pg_proc where oid = to_regprocedure(v_fn)) <> 'cma_owner'
       or (select array_to_string(proconfig, ',') from pg_proc where oid = to_regprocedure(v_fn)) is distinct from 'search_path=pg_catalog, cma, pg_temp' then
      raise exception 'FAIL A3: % must be security definer, owned by cma_owner, with a pinned search path', v_fn;
    end if;
    if not has_function_privilege('cma_readonly', v_fn, 'execute')
       or has_function_privilege('cma_app', v_fn, 'execute')
       or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                  where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE') then
      raise exception 'FAIL A3: execute on % must be granted to cma_readonly only', v_fn;
    end if;
  end loop;

  -- A4. the views: readers see each one, the application none; one dq_ view per check
  select count(*) into v_n from cma.data_quality_checks();
  if v_n <> 15 then
    raise exception 'FAIL A4: % data-quality checks instead of 15', v_n;
  end if;
  foreach v_t in array array['speed_to_lead', 'lead_to_order', 'intake_per_day_v']
                       || array(select 'dq_' || check_key from cma.data_quality_checks()) loop
    if to_regclass('cma_read.' || v_t) is null then
      raise exception 'FAIL A4: view cma_read.% is missing', v_t;
    end if;
    if not has_table_privilege('cma_readonly', 'cma_read.' || v_t, 'select')
       or has_table_privilege('cma_app', 'cma_read.' || v_t, 'select') then
      raise exception 'FAIL A4: readers and only readers must see cma_read.%', v_t;
    end if;
  end loop;

  -- A5. columns: no raw payload, hash, key, email, phone or name of a person in any of them; the
  --     dq views carry ids only; the speed-to-lead view carries the measures
  select string_agg(table_name || '.' || column_name, ', ') into v_cols
  from information_schema.columns
  where table_schema = 'cma_read'
    and (table_name in ('speed_to_lead', 'lead_to_order', 'intake_per_day_v') or table_name like 'dq\_%')
    and (column_name in ('raw', 'key', 'settings', 'counterpart_hash', 'kept_values') or column_name like '%secret%'
         or column_name like '%token%' or column_name like '%email%' or column_name like '%phone%'
         or column_name like '%name%');
  if v_cols is not null then
    raise exception 'FAIL A5: reporting views expose %', v_cols;
  end if;
  select count(distinct string_agg) into v_n from (
    select string_agg(column_name, ', ' order by ordinal_position)
    from information_schema.columns where table_schema = 'cma_read' and table_name like 'dq\_%'
    group by table_name) x;
  if v_n <> 1 or (select string_agg(column_name, ', ' order by ordinal_position) from information_schema.columns
                  where table_schema = 'cma_read' and table_name = 'dq_deal_without_contact')
                 is distinct from 'tenant_id, connection_id, object_type, object_id, value' then
    raise exception 'FAIL A5: the dq views must all carry tenant_id, connection_id, object_type, object_id, value';
  end if;
  select count(*) into v_n from information_schema.columns
  where table_schema = 'cma_read' and table_name = 'speed_to_lead'
    and column_name in ('tenant_id', 'deal_id', 'market', 'status', 'first_call_at', 'business_seconds', 'within_target',
                        'before_next_noon', 'inbound_first', 'first_connected_at', 'agent_user_id', 'elapsed_seconds');
  if v_n <> 12 then
    raise exception 'FAIL A5: cma_read.speed_to_lead lacks % of 12 columns', 12 - v_n;
  end if;

  -- A6. the settings the reads use exist (0007)
  if (select count(*) from cma.setting where key in ('intake.start_date', 'speed_to_lead.pre_window_minutes',
        'speed_to_lead.target_minutes', 'lead_to_order.max_days', 'commerce.renewal_source_names')) <> 5 then
    raise exception 'FAIL A6: a setting of 0007 is missing';
  end if;
end
$$;

-- The constructed week, shared by blocks B, C, D and F. Created in this session only (pg_temp),
-- called inside each block's rolled-back subtransaction, dropped at the end. All ids are invented.
create or replace function pg_temp.verify_0007d_fixture()
returns jsonb
language plpgsql
as $$
declare
  v_t1 uuid; v_t2 uuid;
  v_admin uuid; v_manager uuid; v_super uuid; v_agent1 uuid; v_agent2 uuid; v_ing uuid; v_admin2 uuid; v_ing2 uuid;
  v_crm uuid; v_tel uuid; v_shopa uuid; v_shopb uuid; v_crm2 uuid;
  v_h10 text := repeat('a1', 32);
begin
  v_t1 := cma.create_tenant('verify-0007d-one', 'Verify 0007d one', 'Europe/Amsterdam');
  v_t2 := cma.create_tenant('verify-0007d-two', 'Verify 0007d two', 'Europe/Amsterdam');
  insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'Verify admin') returning id into v_admin;
  insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-manager@example.invalid', 'Verify manager') returning id into v_manager;
  insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-super@example.invalid', 'Verify supervisor') returning id into v_super;
  insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent1@example.invalid', 'Verify agent one') returning id into v_agent1;
  insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent2@example.invalid', 'Verify agent two') returning id into v_agent2;
  insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin@example.invalid', 'Verify admin two') returning id into v_admin2;
  insert into cma.user_role (tenant_id, user_id, role_id)
  select ar.tenant_id, x.uid, ar.id
  from (values (v_t1, v_admin, 'admin'), (v_t1, v_manager, 'manager'), (v_t1, v_super, 'supervisor'),
               (v_t1, v_agent1, 'agent'), (v_t1, v_agent2, 'agent'), (v_t2, v_admin2, 'admin')) as x(tid, uid, role_key)
  join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
  select id into v_ing from cma.app_user where tenant_id = v_t1 and email = 'ingest@system.invalid';
  select id into v_ing2 from cma.app_user where tenant_id = v_t2 and email = 'ingest@system.invalid';
  insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
  values (v_t1, 'verifycrm', 'Verify CRM', 'portal-1') returning id into v_crm;
  insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
  values (v_t1, 'verifytel', 'Verify telephony', 'tel-1') returning id into v_tel;
  insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
  values (v_t1, 'verifyshop', 'Verify shop NL', 'a.example.com') returning id into v_shopa;
  insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
  values (v_t1, 'verifyshop', 'Verify shop GB', 'b.example.com') returning id into v_shopb;
  insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
  values (v_t2, 'verifycrm', 'Verify CRM two', 'portal-2') returning id into v_crm2;

  perform set_config('role', 'cma_app', true);
  perform set_config('app.tenant_id', v_t1::text, true);

  -- configuration (the admin): markets, an alias, office hours Mon-Fri 09:00-17:00, a holiday in
  -- NL on Wednesday 16 September, the settings, the owners, the stores
  perform set_config('app.user_id', v_admin::text, true);
  perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
  perform cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP');
  perform cma.set_market_alias('united kingdom', 'GB');
  perform cma.set_business_hours('*', d::smallint, '09:00-17:00') from generate_series(1, 5) d;
  perform cma.set_business_holiday('NL', date '2026-09-16', 'Verify holiday');
  perform cma.set_tenant_setting('intake.start_date', '2026-09-01');
  perform cma.set_tenant_setting('speed_to_lead.pre_window_minutes', '10');
  perform cma.set_tenant_setting('commerce.renewal_source_names', 'subscription_contract');
  perform cma.set_user_external_id(v_agent1, 'verifycrm_owner', 'o-1');
  perform cma.set_user_external_id(v_agent2, 'verifycrm_owner', 'o-2');
  perform cma.upsert_commerce_store(v_shopa, 'verify-nl', 'Verify NL', 'NL', 'EUR', 'Europe/Amsterdam');
  perform cma.upsert_commerce_store(v_shopb, 'verify-gb', 'Verify GB', 'GB', 'GBP', 'Europe/London');

  -- catalogs from the sources (the Ingest user)
  perform set_config('app.user_id', v_ing::text, true);
  perform cma.ingest_upsert_pipelines(v_crm, '[
    {"recordType": "deal", "pipelineId": "sales", "label": "Sales", "stages": [
       {"stageId": "s1", "label": "Open", "order": 1, "isClosed": false}, {"stageId": "s9", "label": "Lost", "order": 9, "isClosed": true}]},
    {"recordType": "deal", "pipelineId": "renew", "label": "Renewals", "stages": [{"stageId": "r1", "label": "Open", "order": 1, "isClosed": false}]},
    {"recordType": "deal", "pipelineId": "test", "label": "Test", "stages": [{"stageId": "x1", "label": "Open", "order": 1, "isClosed": false}]},
    {"recordType": "ticket", "pipelineId": "support", "label": "Support", "stages": [
       {"stageId": "t1", "label": "New", "order": 1, "isClosed": false}, {"stageId": "t9", "label": "Closed", "order": 9, "isClosed": true}]}]');
  perform cma.ingest_upsert_call_outcomes(v_crm, '[{"outcomeRef": "connected", "label": "Connected"}, {"outcomeRef": "no_answer", "label": "No answer"}]');
  perform cma.ingest_upsert_telephony_catalog(v_tel, 'number', '[{"numberRef": "n-nl", "name": "Verify NL line", "digits": "+31000000001"},
    {"numberRef": "n-gb", "name": "Verify GB line", "digits": "+44000000001"}, {"numberRef": "n-off", "name": "Verify test line", "digits": "+31000000009"}]');
  perform cma.ingest_upsert_telephony_catalog(v_tel, 'tag', '[{"tagRef": "tg1", "name": "Verify sale"}, {"tagRef": "tg2", "name": "Verify internal"}]');
  perform cma.ingest_upsert_forms(v_crm, '[{"formId": "f1", "name": "Verify form NL"}, {"formId": "f2", "name": "Verify form open"}, {"formId": "f3", "name": "Verify form test"}]');

  -- their configuration (the admin)
  perform set_config('app.user_id', v_admin::text, true);
  perform cma.set_pipeline_lead(v_crm, 'deal', 'renew', false);
  perform cma.set_connection_pipeline(v_crm, 'deal', 'test', false, false, null);
  perform cma.set_call_outcome(v_crm, 'connected', true);
  perform cma.set_telephony_number(v_tel, 'n-nl', 'NL', true);
  perform cma.set_telephony_number(v_tel, 'n-gb', 'GB', true);
  perform cma.set_telephony_number(v_tel, 'n-off', 'NL', false);
  perform cma.set_telephony_tag(v_tel, 'tg2', false);
  perform cma.set_form(v_crm, 'f1', true, 'Verify', 'NL', '{}');
  perform cma.set_form(v_crm, 'f3', false, null, 'NL', '{}');

  -- the week (UTC; Amsterdam is UTC+2, London UTC+1)
  perform set_config('app.user_id', v_ing::text, true);
  perform cma.ingest_upsert_records(v_crm, '[
    {"recordType": "deal", "sourceId": "d1",  "pipelineId": "sales", "stageId": "s1", "ownerRef": "o-1", "contactId": "k1",  "market": "NL",   "createdAt": "2026-09-15T08:00:00Z", "updatedAt": "2026-09-15T08:00:00Z"},
    {"recordType": "deal", "sourceId": "d2",  "pipelineId": "sales", "stageId": "s1", "ownerRef": "o-1", "contactId": "k2",  "market": "NL",   "createdAt": "2026-09-18T14:55:00Z", "updatedAt": "2026-09-18T14:55:00Z"},
    {"recordType": "deal", "sourceId": "d3",  "pipelineId": "sales", "stageId": "s1", "ownerRef": "o-2", "contactId": "k3",  "market": "NL",   "createdAt": "2026-09-15T09:00:00Z", "updatedAt": "2026-09-15T09:00:00Z"},
    {"recordType": "deal", "sourceId": "d4",  "pipelineId": "sales", "stageId": "s9", "closedAt": "2026-09-15T12:00:00Z", "contactId": "k4", "market": "NL", "createdAt": "2026-09-15T09:30:00Z", "updatedAt": "2026-09-15T12:00:00Z"},
    {"recordType": "deal", "sourceId": "d5",  "pipelineId": "sales", "stageId": "s1", "contactId": "k5",  "market": "NL",   "createdAt": "2026-09-17T07:30:00Z", "updatedAt": "2026-09-17T07:30:00Z"},
    {"recordType": "deal", "sourceId": "d6",  "pipelineId": "sales", "stageId": "s1", "contactId": "k6",  "market": "Holland", "createdAt": "2026-09-17T08:00:00Z", "updatedAt": "2026-09-17T08:00:00Z"},
    {"recordType": "deal", "sourceId": "d7",  "pipelineId": "sales", "stageId": "s1", "contactId": "k7a", "market": "NL",   "createdAt": "2026-09-17T08:00:00Z", "updatedAt": "2026-09-17T08:00:00Z"},
    {"recordType": "deal", "sourceId": "d8",  "pipelineId": "sales", "stageId": "s1", "contactId": "k8",  "market": "NL",   "createdAt": "2026-09-17T11:00:00Z", "updatedAt": "2026-09-17T11:00:00Z"},
    {"recordType": "deal", "sourceId": "d9",  "pipelineId": "sales", "stageId": "s1", "contactId": "k9",  "market": "NL",   "createdAt": "2026-09-17T12:00:00Z", "updatedAt": "2026-09-17T12:00:00Z"},
    {"recordType": "deal", "sourceId": "d10", "pipelineId": "sales", "stageId": "s1", "contactId": "k10", "market": "NL",   "createdAt": "2026-09-17T13:00:00Z", "updatedAt": "2026-09-17T13:00:00Z"},
    {"recordType": "deal", "sourceId": "d11", "pipelineId": "sales", "stageId": "s1", "contactId": "k11", "market": "NL",   "createdAt": "2026-09-18T08:00:00Z", "updatedAt": "2026-09-18T08:00:00Z"},
    {"recordType": "deal", "sourceId": "d12a", "pipelineId": "renew", "stageId": "r1", "contactId": "k12", "market": "NL",  "createdAt": "2026-09-15T08:00:00Z", "updatedAt": "2026-09-15T08:00:00Z"},
    {"recordType": "deal", "sourceId": "d12b", "pipelineId": "test",  "stageId": "x1", "contactId": "k12", "market": "NL",  "createdAt": "2026-09-15T08:00:00Z", "updatedAt": "2026-09-15T08:00:00Z"},
    {"recordType": "deal", "sourceId": "d13", "pipelineId": "sales", "stageId": "s1", "contactId": "k13", "createdAt": "2026-09-15T08:00:00Z", "updatedAt": "2026-09-15T08:00:00Z"},
    {"recordType": "deal", "sourceId": "d14", "pipelineId": "sales", "stageId": "s1", "contactId": "k14", "createdAt": "2026-09-15T08:00:00Z", "updatedAt": "2026-09-15T08:00:00Z"},
    {"recordType": "deal", "sourceId": "d16", "pipelineId": "sales", "stageId": "s1", "contactId": "k16", "market": "NL",   "createdAt": "2026-09-15T14:30:00Z", "updatedAt": "2026-09-15T14:30:00Z"},
    {"recordType": "deal", "sourceId": "dold", "pipelineId": "sales", "stageId": "s1", "contactId": "k1", "market": "NL",   "createdAt": "2026-08-20T08:00:00Z", "updatedAt": "2026-08-20T08:00:00Z"},
    {"recordType": "deal", "sourceId": "ddel", "pipelineId": "sales", "stageId": "s1", "contactId": "k1", "market": "NL",   "createdAt": "2026-09-15T08:00:00Z", "updatedAt": "2026-09-15T08:00:00Z"},
    {"recordType": "ticket", "sourceId": "tk1", "pipelineId": "support", "stageId": "t9", "closedAt": "2026-09-15T11:00:00Z", "market": "NL", "createdAt": "2026-09-15T10:00:00Z", "updatedAt": "2026-09-15T11:00:00Z"}]');
  perform cma.ingest_upsert_records(v_crm, '[{"recordType": "deal", "sourceId": "ddel", "deletedAt": "2026-09-15T09:00:00Z"}]');
  perform cma.ingest_upsert_contacts(v_crm, '[
    {"sourceId": "k1",  "country": "NL", "language": "nl", "refs": {"verifyshop": ["c-101"]}, "updatedAt": "2026-09-15T08:00:00Z"},
    {"sourceId": "k2",  "country": "NL", "language": "nl", "refs": {"verifyshop": ["c-201", "c-202"]}, "updatedAt": "2026-09-15T08:00:00Z"},
    {"sourceId": "k3",  "country": "NL", "language": "nl", "refs": {"verifyshop": ["c-301"]}, "updatedAt": "2026-09-15T08:00:00Z"},
    {"sourceId": "k4",  "country": "NL", "language": "nl", "updatedAt": "2026-09-15T08:00:00Z"},
    {"sourceId": "k5",  "country": "NL", "language": "nl", "refs": {"verifyshop": ["c-501"]}, "updatedAt": "2026-09-15T08:00:00Z"},
    {"sourceId": "k13", "country": "United Kingdom", "language": "en", "updatedAt": "2026-09-15T08:00:00Z"},
    {"sourceId": "k14", "language": "en", "updatedAt": "2026-09-15T08:00:00Z"}]');
  perform cma.ingest_upsert_calls(v_crm, (
    select jsonb_agg(jsonb_build_object('sourceId', c.id, 'occurredAt', c.at, 'direction', c.dir, 'outcomeRef', c.outcome,
                                        'ownerRef', c.owner, 'counterpartHash', c.hash, 'updatedAt', c.at))
    from (values
      ('c1',   '2026-09-15T08:07:00Z', 'outbound', 'connected', 'o-1', null),
      ('c2',   '2026-09-21T07:10:00Z', 'outbound', 'no_answer', 'o-9', null),
      ('c5a',  '2026-09-17T07:40:00Z', 'inbound',  'connected', null,  null),
      ('c5b',  '2026-09-17T08:00:00Z', 'outbound', 'no_answer', null,  null),
      ('c6',   '2026-09-17T08:20:00Z', 'outbound', null,        null,  null),
      ('c7',   '2026-09-17T08:30:00Z', 'outbound', null,        null,  null),
      ('c8',   '2026-09-17T10:45:00Z', 'outbound', null,        null,  null),
      ('c9',   '2026-09-17T11:55:00Z', 'outbound', null,        null,  null),
      ('c10',  '2026-09-17T13:40:00Z', 'outbound', 'no_answer', null,  v_h10),
      ('c11a', '2026-09-18T08:05:00Z', 'outbound', null,        null,  null),
      ('c11b', '2026-09-18T08:50:00Z', 'outbound', null,        null,  null),
      ('c13',  '2026-09-15T08:30:00Z', 'outbound', null,        null,  null),
      ('c14',  '2026-09-15T08:10:00Z', 'outbound', null,        null,  null),
      ('c16',  '2026-09-17T07:30:00Z', 'outbound', null,        null,  null)) c(id, at, dir, outcome, owner, hash)));
  perform cma.ingest_upsert_associations(v_crm, (
    select jsonb_agg(jsonb_build_object('fromType', a.ft, 'fromId', a.fi, 'toType', a.tt, 'toId', a.ti, 'removed', a.rm, 'changedAt', a.at))
    from (values
      ('crm_call', 'c1',  'contact', 'k1',  false, '2026-09-15T08:08:00Z'),
      ('crm_call', 'c2',  'contact', 'k2',  false, '2026-09-21T07:11:00Z'),
      ('crm_call', 'c5a', 'contact', 'k5',  false, '2026-09-17T07:41:00Z'),
      ('crm_call', 'c5b', 'contact', 'k5',  false, '2026-09-17T08:01:00Z'),
      ('crm_call', 'c6',  'deal',    'd6',  false, '2026-09-17T08:21:00Z'),
      ('deal',     'd7',  'contact', 'k7b', false, '2026-09-17T08:00:00Z'),
      ('crm_call', 'c7',  'contact', 'k7b', false, '2026-09-17T08:31:00Z'),
      ('crm_call', 'c8',  'contact', 'k8',  false, '2026-09-17T10:46:00Z'),
      ('crm_call', 'c9',  'contact', 'k9',  false, '2026-09-17T11:56:00Z'),
      ('crm_call', 'c10', 'contact', 'k10', false, '2026-09-17T13:41:00Z'),
      ('crm_call', 'c11a','contact', 'k11', false, '2026-09-18T08:06:00Z'),
      ('crm_call', 'c11b','contact', 'k11', false, '2026-09-18T08:51:00Z'),
      ('crm_call', 'c13', 'contact', 'k13', false, '2026-09-15T08:31:00Z'),
      ('crm_call', 'c14', 'contact', 'k14', false, '2026-09-15T08:11:00Z'),
      ('crm_call', 'c16', 'contact', 'k16', false, '2026-09-17T07:31:00Z')) a(ft, fi, tt, ti, rm, at)));
  perform cma.ingest_upsert_associations(v_crm, '[{"fromType": "crm_call", "fromId": "c11a", "toType": "contact", "toId": "k11", "removed": true, "changedAt": "2026-09-18T09:00:00Z"}]');
  perform cma.ingest_upsert_telephony_calls(v_tel, (
    select jsonb_agg(jsonb_build_object('sourceId', t.id, 'direction', t.dir, 'startedAt', t.started, 'answeredAt', t.answered,
                                        'endedAt', t.ended, 'numberRef', t.line, 'counterpartHash', t.hash, 'versionAt', t.ended,
                                        'tags', t.tags))
    from (values
      ('t10',   'outbound', '2026-09-17T13:38:30Z', '2026-09-17T13:38:50Z', '2026-09-17T13:45:00Z', 'n-nl',  v_h10, '[]'::jsonb),
      ('t-in1', 'inbound',  '2026-09-15T09:00:00Z', '2026-09-15T09:00:10Z', '2026-09-15T09:05:00Z', 'n-nl',  null, '["tg1"]'::jsonb),
      ('t-out1','outbound', '2026-09-15T10:00:00Z', null,                   '2026-09-15T10:01:00Z', 'n-nl',  null, '[]'::jsonb),
      ('t-gb1', 'inbound',  '2026-09-15T11:00:00Z', '2026-09-15T11:00:10Z', '2026-09-15T11:04:00Z', 'n-gb',  null, '["tg2"]'::jsonb),
      ('t-x',   'inbound',  '2026-09-15T12:00:00Z', null,                   '2026-09-15T12:01:00Z', 'n-off', null, '[]'::jsonb)
    ) t(id, dir, started, answered, ended, line, hash, tags)));
  perform cma.link_calls('2026-09-01T00:00:00Z');
  perform cma.ingest_upsert_commerce_customers(v_shopa, '[
    {"sourceId": "c-101", "createdAt": "2026-09-15T12:00:00Z", "updatedAt": "2026-09-15T12:00:00Z"},
    {"sourceId": "c-301", "createdAt": "2026-08-01T12:00:00Z", "updatedAt": "2026-08-01T12:00:00Z"},
    {"sourceId": "c-501", "createdAt": "2026-08-01T12:00:00Z", "updatedAt": "2026-08-01T12:00:00Z"}]');
  perform cma.ingest_upsert_commerce_customers(v_shopb, '[{"sourceId": "c-202", "createdAt": "2026-09-15T12:00:00Z", "updatedAt": "2026-09-15T12:00:00Z"}]');
  perform cma.ingest_upsert_commerce_orders(v_shopa, '[
    {"sourceId": "o-t",   "customerId": "c-101", "createdAt": "2026-09-16T10:00:00Z", "updatedAt": "2026-09-16T10:00:00Z", "isTest": true, "priorOrdersCount": 0},
    {"sourceId": "o-101", "customerId": "c-101", "createdAt": "2026-09-20T10:00:00Z", "updatedAt": "2026-09-20T10:00:00Z", "priorOrdersCount": 0, "currency": "EUR", "totalAmount": "100.00"},
    {"sourceId": "o-302", "customerId": "c-301", "createdAt": "2026-09-16T10:00:00Z", "updatedAt": "2026-09-16T11:00:00Z", "cancelledAt": "2026-09-16T11:00:00Z", "priorOrdersCount": 0},
    {"sourceId": "o-301", "customerId": "c-301", "createdAt": "2026-12-20T10:00:00Z", "updatedAt": "2026-12-20T10:00:00Z", "priorOrdersCount": 0},
    {"sourceId": "o-501", "customerId": "c-501", "createdAt": "2026-09-18T09:00:00Z", "updatedAt": "2026-09-18T09:00:00Z", "priorOrdersCount": 2, "sourceName": "subscription_contract"}]');
  perform cma.ingest_upsert_commerce_orders(v_shopb, '[
    {"sourceId": "o-202", "customerId": "c-202", "createdAt": "2026-09-25T10:00:00Z", "updatedAt": "2026-09-25T10:00:00Z", "priorOrdersCount": 3, "currency": "GBP", "totalAmount": "80.00"}]');
  perform cma.ingest_upsert_form_submissions(v_crm, '[
    {"sourceId": "s1", "formId": "f1", "submittedAt": "2026-09-15T08:00:00Z"},
    {"sourceId": "s2", "formId": "f1", "submittedAt": "2026-09-15T09:00:00Z"},
    {"sourceId": "s3", "formId": "f2", "submittedAt": "2026-09-15T09:30:00Z"},
    {"sourceId": "s4", "formId": "f3", "submittedAt": "2026-09-15T10:00:00Z"}]');

  -- an alias added after the deal arrived: the reads normalise again
  perform set_config('app.user_id', v_admin::text, true);
  perform cma.set_market_alias('holland', 'NL');

  perform set_config('role', 'cma_owner', true);
  perform set_config('app.tenant_id', '', true);
  perform set_config('app.user_id', '', true);
  return jsonb_build_object('t1', v_t1, 't2', v_t2, 'admin', v_admin, 'manager', v_manager, 'super', v_super,
                            'agent1', v_agent1, 'agent2', v_agent2, 'ingest', v_ing, 'admin2', v_admin2, 'ingest2', v_ing2,
                            'crm', v_crm, 'tel', v_tel, 'shopa', v_shopa, 'shopb', v_shopb, 'crm2', v_crm2);
end
$$;

-- B. Speed to lead (throwaway tenants, rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  f          jsonb;
  v_txt      text;
  v_n        int;
  r          record;
begin
  begin
    f := pg_temp.verify_0007d_fixture();
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', f ->> 't1', true);
    perform set_config('app.user_id', f ->> 'manager', true);

    -- B1. the population and the core measures per deal: lead pipelines only (renewals and the
    --     uncounted test pipeline out), deleted and pre-start deals out; status, business seconds,
    --     within target (60 business minutes) and before the next business noon
    select string_agg(x.deal_source_id || ':' || x.status || ':' || coalesce(x.business_seconds::text, '-') || ':'
                      || coalesce(x.within_target::text, '-') || ':' || coalesce(x.before_next_noon::text, '-'), ' ' order by x.deal_source_id)
      into v_txt
    from cma.speed_to_lead_rows('2026-09-14', '2026-09-21') x;
    if v_txt is distinct from
       'd1:called:420:true:true d10:called:2310:true:true d11:called:3000:true:true d13:called:1800:true:true '
       'd14:called:-:-:- d16:called:3600:true:true d2:called:900:true:true d3:not_called_open:-:false:false '
       'd4:not_called_closed:-:false:false d5:called:1800:true:true d6:called:1200:true:true d7:called:1800:true:true '
       'd8:not_called_open:-:false:false d9:called:0:true:true' or v_provoke then
      raise exception 'FAIL B1: speed to lead rows are %', v_txt;
    end if;

    -- B2. Friday 16:55 to Monday 09:10: 64 h 15 min elapsed, 15 business minutes, before Monday's
    --     noon; the call's owner has no person, so the agent is the deal's owner's person
    select * into r from cma.speed_to_lead_rows('2026-09-14', '2026-09-21') x where x.deal_source_id = 'd2';
    if r.elapsed_seconds <> 231300 or r.business_seconds <> 900 or r.next_business_noon <> '2026-09-21T10:00:00Z'
       or r.agent_user_id is distinct from (f ->> 'agent1')::uuid or r.agent_from <> 'deal' or r.agent_ref <> 'o-1' then
      raise exception 'FAIL B2: d2 gives elapsed %, business %, noon %, agent % from %', r.elapsed_seconds, r.business_seconds,
        r.next_business_noon, r.agent_user_id, r.agent_from;
    end if;

    -- B3. 7 business minutes, the agent through the call's owner, the connected outcome; across the
    --     NL holiday (16:30 Tuesday to 09:30 Thursday is 60 business minutes, and the next noon is
    --     Thursday's)
    select * into r from cma.speed_to_lead_rows('2026-09-14', '2026-09-21') x where x.deal_source_id = 'd1';
    if r.elapsed_seconds <> 420 or r.agent_user_id is distinct from (f ->> 'agent1')::uuid or r.agent_from <> 'call'
       or r.first_connected_at <> '2026-09-15T08:07:00Z' or r.market <> 'NL' or r.market_source <> 'record'
       or r.first_call_source_id <> 'c1' or r.first_call_linked then
      raise exception 'FAIL B3: d1 gives elapsed %, agent % from %, connected at %', r.elapsed_seconds, r.agent_user_id, r.agent_from, r.first_connected_at;
    end if;
    select * into r from cma.speed_to_lead_rows('2026-09-14', '2026-09-21') x where x.deal_source_id = 'd16';
    if r.next_business_noon <> '2026-09-17T10:00:00Z' or r.business_seconds <> 3600 then
      raise exception 'FAIL B3: across the holiday d16 gives % business seconds and noon %', r.business_seconds, r.next_business_noon;
    end if;

    -- B4. never called: open (still waiting, the deal owner's person as agent) and closed (not waiting)
    select * into r from cma.speed_to_lead_rows('2026-09-14', '2026-09-21') x where x.deal_source_id = 'd3';
    if r.first_call_at is not null or r.waiting_business_seconds is null or r.waiting_business_seconds <= 3600
       or r.agent_user_id is distinct from (f ->> 'agent2')::uuid or r.agent_from <> 'deal' then
      raise exception 'FAIL B4: d3 gives first call %, waiting %, agent % from %', r.first_call_at, r.waiting_business_seconds, r.agent_user_id, r.agent_from;
    end if;
    select * into r from cma.speed_to_lead_rows('2026-09-14', '2026-09-21') x where x.deal_source_id = 'd4';
    if r.waiting_business_seconds is not null or not r.is_closed or r.agent_user_id is not null then
      raise exception 'FAIL B4: d4 gives waiting %, closed %', r.waiting_business_seconds, r.is_closed;
    end if;

    -- B5. an inbound call first: reported, connected first, the outbound call measured
    select * into r from cma.speed_to_lead_rows('2026-09-14', '2026-09-21') x where x.deal_source_id = 'd5';
    if not r.inbound_first or r.first_any_direction <> 'inbound' or r.first_any_call_at <> '2026-09-17T07:40:00Z'
       or r.first_connected_at <> '2026-09-17T07:40:00Z' or r.first_call_source_id <> 'c5b' then
      raise exception 'FAIL B5: d5 gives inbound first %, first any % at %, connected %', r.inbound_first, r.first_any_direction,
        r.first_any_call_at, r.first_connected_at;
    end if;
    if (select count(*) from cma.speed_to_lead_rows('2026-09-14', '2026-09-21') x where x.inbound_first) <> 1 then
      raise exception 'FAIL B5: more than one deal had an inbound call first';
    end if;

    -- B6. a call on the deal only counts; a call on a second associated contact counts; the deal's
    --     market as written ('Holland') counts through the alias added after it arrived
    select * into r from cma.speed_to_lead_rows('2026-09-14', '2026-09-21') x where x.deal_source_id = 'd6';
    if r.first_call_source_id is distinct from 'c6' or r.market <> 'NL' or r.market_source <> 'record' then
      raise exception 'FAIL B6: d6 gives call %, market % from %', r.first_call_source_id, r.market, r.market_source;
    end if;
    if (select x.first_call_source_id from cma.speed_to_lead_rows('2026-09-14', '2026-09-21') x where x.deal_source_id = 'd7') is distinct from 'c7' then
      raise exception 'FAIL B6: the call on d7''s second contact did not count';
    end if;

    -- B7. the pre-window (10 minutes): a call 15 minutes before creation does not count, one 5 minutes
    --     before does and measures 0
    select * into r from cma.speed_to_lead_rows('2026-09-14', '2026-09-21') x where x.deal_source_id = 'd9';
    if r.first_call_source_id is distinct from 'c9' or r.elapsed_seconds <> 0 or r.business_seconds <> 0 then
      raise exception 'FAIL B7: d9 gives call %, elapsed %', r.first_call_source_id, r.elapsed_seconds;
    end if;
    if (select x.first_any_call_at from cma.speed_to_lead_rows('2026-09-14', '2026-09-21') x where x.deal_source_id = 'd8') is not null then
      raise exception 'FAIL B7: d8 counted a call outside the pre-window';
    end if;

    -- B8. the linked telephony call moves the start 90 seconds earlier and was answered (connected,
    --     although the CRM outcome is not)
    select * into r from cma.speed_to_lead_rows('2026-09-14', '2026-09-21') x where x.deal_source_id = 'd10';
    if not r.first_call_linked or r.first_call_at <> '2026-09-17T13:38:30Z' or r.first_connected_at <> '2026-09-17T13:38:30Z' then
      raise exception 'FAIL B8: d10 gives linked %, start %, connected %', r.first_call_linked, r.first_call_at, r.first_connected_at;
    end if;

    -- B9. a removed association no longer counts (d11 measures from its second call)
    if (select x.first_call_source_id from cma.speed_to_lead_rows('2026-09-14', '2026-09-21') x where x.deal_source_id = 'd11') is distinct from 'c11b' then
      raise exception 'FAIL B9: d11 still counts the call whose association was removed';
    end if;

    -- B10. market from the contact (written 'United Kingdom', business time in London), unknown when
    --      neither has one (no business measures)
    select * into r from cma.speed_to_lead_rows('2026-09-14', '2026-09-21') x where x.deal_source_id = 'd13';
    if r.market <> 'GB' or r.market_source <> 'contact' or r.business_seconds <> 1800 or r.next_business_noon <> '2026-09-16T11:00:00Z' then
      raise exception 'FAIL B10: d13 gives market % from %, business %, noon %', r.market, r.market_source, r.business_seconds, r.next_business_noon;
    end if;
    select * into r from cma.speed_to_lead_rows('2026-09-14', '2026-09-21') x where x.deal_source_id = 'd14';
    if r.market <> 'unknown' or r.market_source is not null or r.business_seconds is not null or r.elapsed_seconds <> 600 then
      raise exception 'FAIL B10: d14 gives market % from %, business %', r.market, r.market_source, r.business_seconds;
    end if;

    -- B11. the summary by market: deals, called, median and p80 business minutes, the two
    --      percentages over known outcomes, open not called
    select string_agg(concat_ws(':', s.group_key, s.group_label, s.deals, s.called, s.median_business_minutes, s.p80_business_minutes,
                                coalesce(s.within_target_pct::text, '-'), coalesce(s.before_next_noon_pct::text, '-'), s.open_not_called), ' '
                      order by s.group_key) into v_txt
    from cma.speed_to_lead_summary('2026-09-14', '2026-09-21', 'market') s;
    if v_txt is distinct from 'GB:GB:1:1:30.0:30.0:100.0:100.0:0 NL:NL:12:9:30.0:43.1:75.0:75.0:2 unknown:unknown:1:1:-:-:0' then
      raise exception 'FAIL B11: the summary by market is %', v_txt;
    end if;

    -- B12. by day, agent and pipeline; an unknown grouping is refused
    if (select s.deals from cma.speed_to_lead_summary('2026-09-14', '2026-09-21', 'day') s where s.group_key = '2026-09-15') <> 6
       or (select s.deals || ':' || s.called || ':' || s.group_label from cma.speed_to_lead_summary('2026-09-14', '2026-09-21', 'agent') s
           where s.group_key = f ->> 'agent1') is distinct from '2:2:Verify agent one'
       or (select string_agg(s.group_label || ':' || s.deals, ',') from cma.speed_to_lead_summary('2026-09-14', '2026-09-21', 'pipeline') s)
          is distinct from 'Sales:14' then
      raise exception 'FAIL B12: the summary by day, agent or pipeline is wrong';
    end if;
    begin
      perform cma.speed_to_lead_summary('2026-09-14', '2026-09-21', 'owner');
      raise exception 'FAIL B12: an unknown grouping was accepted';
    exception when sqlstate 'CMA04' then null;
    end;

    -- B13. the 92-day bound: 92 days pass, 93 days, a reversed and an open range are refused
    perform cma.speed_to_lead_rows('2026-07-01', '2026-09-30');
    foreach v_txt in array array[
      'select cma.speed_to_lead_rows(''2026-06-30'', ''2026-09-30'')',
      'select cma.speed_to_lead_rows(''2026-09-30'', ''2026-09-01'')',
      'select cma.speed_to_lead_rows(null, ''2026-09-01'')',
      'select cma.speed_to_lead_summary(''2026-06-30'', ''2026-09-30'', ''day'')',
      'select cma.lead_to_order_rows(''2026-06-30'', ''2026-09-30'')',
      'select cma.intake_per_day(''2026-06-30'', ''2026-09-30'')'
    ] loop
      begin
        execute v_txt;
        raise exception 'FAIL B13: % was accepted', v_txt;
      exception when sqlstate 'CMA04' then null;
      end;
    end loop;

    -- B14. 0007's business time functions give the same answers through the shared code
    if cma.business_seconds('NL', '2026-09-18T14:55:00Z', '2026-09-21T07:10:00Z') <> 900
       or cma.business_seconds('NL', '2026-09-15T14:30:00Z', '2026-09-17T07:30:00Z') <> 3600
       or cma.next_business_noon('NL', '2026-09-15T14:30:00Z') <> '2026-09-17T10:00:00Z'
       or cma.business_seconds('XX', '2026-09-15T14:30:00Z', '2026-09-17T07:30:00Z') is not null then
      raise exception 'FAIL B14: cma.business_seconds or cma.next_business_noon changed behaviour';
    end if;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- C. Lead to order (throwaway tenants, rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  f          jsonb;
  v_txt      text;
begin
  begin
    f := pg_temp.verify_0007d_fixture();
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', f ->> 't1', true);
    perform set_config('app.user_id', f ->> 'manager', true);

    -- C1. first (slot 1, a test order before it ignored), repeat (through ref slot 2, another store),
    --     renewal (the source name in the setting); d3's cancelled order and its order after 90 days
    --     ignored; a deal whose contact holds no commerce id
    select string_agg(x.deal_source_id || ':' || x.customers_linked || ':' || coalesce(x.order_source_id, '-') || ':'
                      || coalesce(x.order_kind, '-') || ':' || coalesce(x.store_handle, '-') || ':' || coalesce(x.days_to_order::text, '-'),
                      ' ' order by x.deal_source_id) into v_txt
    from cma.lead_to_order_rows('2026-09-14', '2026-09-21') x
    where x.deal_source_id in ('d1', 'd2', 'd3', 'd4', 'd5');
    if v_txt is distinct from 'd1:1:o-101:first:verify-nl:5.08 d2:2:o-202:repeat:verify-gb:6.80 d3:1:-:-:-:- d4:0:-:-:-:- d5:1:o-501:renewal:verify-nl:1.06'
       or v_provoke then
      raise exception 'FAIL C1: lead to order rows are %', v_txt;
    end if;

    -- C2. one row per lead deal, the same population as speed to lead
    if (select count(*) from cma.lead_to_order_rows('2026-09-14', '2026-09-21')) <> 14
       or (select count(*) from cma.lead_to_order_rows('2026-09-14', '2026-09-21') where order_id is not null) <> 3 then
      raise exception 'FAIL C2: lead to order has the wrong number of rows or orders';
    end if;

    -- C3. a longer window (lead_to_order.max_days 120) takes in d3's later order
    perform set_config('app.user_id', f ->> 'admin', true);
    perform cma.set_tenant_setting('lead_to_order.max_days', '120');
    if (select x.order_source_id from cma.lead_to_order_rows('2026-09-14', '2026-09-21') x where x.deal_source_id = 'd3') is distinct from 'o-301' then
      raise exception 'FAIL C3: max_days 120 did not take in the order after 96 days';
    end if;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- D. Intake per day (throwaway tenants, rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  f          jsonb;
  v_txt      text;
begin
  begin
    f := pg_temp.verify_0007d_fixture();
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', f ->> 't1', true);
    perform set_config('app.user_id', f ->> 'super', true);

    -- D1. Tuesday 15 September per market: counted forms (one without a market), deals of counted
    --     pipelines (the renewal pipeline counts, the test pipeline and the deleted deal do not),
    --     closed deals and tickets, calls on counted lines in and out, calls with a counted tag, new
    --     commerce customers by store market
    select string_agg(concat_ws(':', x.market, x.form_submissions, x.deals_created, x.deals_closed, x.tickets_created, x.tickets_closed,
                                x.calls_in, x.calls_out, x.tagged_calls, x.new_customers, x.first_orders, x.repeat_orders, x.renewals),
                      ' ' order by x.market) into v_txt
    from cma.intake_per_day('2026-09-15', '2026-09-15') x;
    if v_txt is distinct from 'GB:0:1:0:0:0:1:0:0:1:0:0:0 NL:2:5:1:1:1:1:1:1:1:0:0:0 unknown:1:1:0:0:0:0:0:0:0:0:0:0' or v_provoke then
      raise exception 'FAIL D1: intake on 15 September is %', v_txt;
    end if;

    -- D2. orders by kind on their own dates (test and cancelled orders left out)
    select string_agg(x.business_date || ':' || x.market || ':' || x.first_orders || ':' || x.repeat_orders || ':' || x.renewals, ' '
                      order by x.business_date) into v_txt
    from cma.intake_per_day('2026-09-14', '2026-09-30') x
    where x.first_orders + x.repeat_orders + x.renewals > 0;
    if v_txt is distinct from '2026-09-18:NL:0:0:1 2026-09-20:NL:1:0:0 2026-09-25:GB:0:1:0' then
      raise exception 'FAIL D2: orders by day are %', v_txt;
    end if;

    -- D3. the whole range adds up: 15 counted deals (14 lead deals and the renewal), two calls out
    if (select sum(x.deals_created) from cma.intake_per_day('2026-09-14', '2026-09-30') x) <> 15
       or (select sum(x.calls_out) from cma.intake_per_day('2026-09-14', '2026-09-30') x) <> 2 then
      raise exception 'FAIL D3: the range has % deals and % calls out',
        (select sum(x.deals_created) from cma.intake_per_day('2026-09-14', '2026-09-30') x),
        (select sum(x.calls_out) from cma.intake_per_day('2026-09-14', '2026-09-30') x);
    end if;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- E. Data quality: every check once (throwaway tenant, rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_t        uuid;
  v_admin    uuid;
  v_ing      uuid;
  v_agent    uuid;
  v_crm      uuid;
  v_tel      uuid;
  v_shopa    uuid;
  v_shopb    uuid;
  v_txt      text;
  v_want     text;
  v_n        int;
begin
  begin
    v_t := cma.create_tenant('verify-0007d-dq', 'Verify 0007d data quality', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-admin@example.invalid', 'Verify admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-agent@example.invalid', 'Verify agent') returning id into v_agent;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t, x.uid, ar.id from (values (v_admin, 'admin'), (v_agent, 'agent')) x(uid, role_key)
    join cma.app_role ar on ar.tenant_id = v_t and ar.key = x.role_key;
    select id into v_ing from cma.app_user where tenant_id = v_t and email = 'ingest@system.invalid';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id) values (v_t, 'verifycrm', 'Verify CRM', 'portal-9') returning id into v_crm;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id) values (v_t, 'verifytel', 'Verify telephony', 'tel-9') returning id into v_tel;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id) values (v_t, 'verifyshop', 'Verify shop NL', 'a9.example.com') returning id into v_shopa;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id) values (v_t, 'verifyshop', 'Verify shop GB', 'b9.example.com') returning id into v_shopb;

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP');
    perform cma.set_tenant_setting('intake.start_date', '2026-09-01');
    perform cma.upsert_commerce_store(v_shopa, 'verify-nl', 'Verify NL', 'NL', 'EUR', 'Europe/Amsterdam');
    perform cma.upsert_commerce_store(v_shopb, 'verify-gb', 'Verify GB', 'GB', 'GBP', 'Europe/London');

    perform set_config('app.user_id', v_ing::text, true);
    perform cma.ingest_upsert_pipelines(v_crm, '[
      {"recordType": "deal", "pipelineId": "sales", "label": "Sales", "stages": [{"stageId": "s1", "label": "Open", "order": 1, "isClosed": false}]},
      {"recordType": "ticket", "pipelineId": "support", "label": "Support", "stages": [{"stageId": "t1", "label": "New", "order": 1, "isClosed": false}]}]');
    perform cma.ingest_upsert_forms(v_crm, '[{"formId": "f1", "name": "Verify form"}]');
    -- deals: dx without contact; dy's contact lacks a language and dy's owner has no person; dz's
    -- contact writes a country outside the catalog; da and db hold one commerce id together; dc's
    -- contact fills both ref slots; dd's contact (GB) holds the id of a customer of the NL store; a
    -- ticket's contact holds the id of a customer present in both stores
    perform cma.ingest_upsert_records(v_crm, '[
      {"recordType": "deal", "sourceId": "dx", "pipelineId": "sales", "stageId": "s1", "market": "NL", "createdAt": "2026-09-15T08:00:00Z", "updatedAt": "2026-09-15T08:00:00Z"},
      {"recordType": "deal", "sourceId": "dy", "pipelineId": "sales", "stageId": "s1", "ownerRef": "o-x", "contactId": "ky", "createdAt": "2026-09-15T08:00:00Z", "updatedAt": "2026-09-15T08:00:00Z"},
      {"recordType": "deal", "sourceId": "dz", "pipelineId": "sales", "stageId": "s1", "contactId": "kz", "createdAt": "2026-09-15T08:00:00Z", "updatedAt": "2026-09-15T08:00:00Z"},
      {"recordType": "deal", "sourceId": "da", "pipelineId": "sales", "stageId": "s1", "contactId": "ka", "createdAt": "2026-09-15T08:00:00Z", "updatedAt": "2026-09-15T08:00:00Z"},
      {"recordType": "deal", "sourceId": "db", "pipelineId": "sales", "stageId": "s1", "contactId": "kb", "createdAt": "2026-09-15T08:00:00Z", "updatedAt": "2026-09-15T08:00:00Z"},
      {"recordType": "deal", "sourceId": "dc", "pipelineId": "sales", "stageId": "s1", "contactId": "kc", "createdAt": "2026-09-15T08:00:00Z", "updatedAt": "2026-09-15T08:00:00Z"},
      {"recordType": "deal", "sourceId": "dd", "pipelineId": "sales", "stageId": "s1", "contactId": "kd", "createdAt": "2026-09-15T08:00:00Z", "updatedAt": "2026-09-15T08:00:00Z"},
      {"recordType": "ticket", "sourceId": "te", "pipelineId": "support", "stageId": "t1", "contactId": "ke", "createdAt": "2026-09-15T08:00:00Z", "updatedAt": "2026-09-15T08:00:00Z"}]');
    perform cma.ingest_upsert_contacts(v_crm, '[
      {"sourceId": "ky", "country": "NL", "updatedAt": "2026-09-15T08:00:00Z"},
      {"sourceId": "kz", "country": "Atlantis", "language": "en", "updatedAt": "2026-09-15T08:00:00Z"},
      {"sourceId": "ka", "country": "NL", "language": "nl", "refs": {"verifyshop": "cu-2"}, "updatedAt": "2026-09-15T08:00:00Z"},
      {"sourceId": "kb", "country": "NL", "language": "nl", "refs": {"verifyshop": "cu-2"}, "updatedAt": "2026-09-15T08:00:00Z"},
      {"sourceId": "kc", "country": "NL", "language": "nl", "refs": {"verifyshop": ["cu-3", "cu-4"]}, "updatedAt": "2026-09-15T08:00:00Z"},
      {"sourceId": "kd", "country": "GB", "language": "en", "refs": {"verifyshop": "cu-5"}, "updatedAt": "2026-09-15T08:00:00Z"},
      {"sourceId": "ke", "refs": {"verifyshop": "cu-6"}, "updatedAt": "2026-09-15T08:00:00Z"}]');
    -- a CRM call without a contact; a telephony call by an unmapped user (recent, so not yet
    -- unlinked); an older telephony call never linked
    perform cma.ingest_upsert_calls(v_crm, '[{"sourceId": "c1", "occurredAt": "2026-09-15T09:00:00Z", "direction": "outbound", "updatedAt": "2026-09-15T09:00:00Z"}]');
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
      jsonb_build_object('sourceId', 't1', 'direction', 'outbound', 'userRef', 'u-x', 'startedAt', now() - interval '1 hour', 'versionAt', now() - interval '1 hour'),
      jsonb_build_object('sourceId', 't2', 'direction', 'inbound', 'startedAt', '2026-09-20T09:00:00Z', 'versionAt', '2026-09-20T09:05:00Z')));
    -- customers: cu-1 nobody holds; cu-2 two contacts hold; cu-5 in the NL store; cu-6 in both stores
    perform cma.ingest_upsert_commerce_customers(v_shopa, '[{"sourceId": "cu-1", "updatedAt": "2026-09-15T08:00:00Z"},
      {"sourceId": "cu-2", "updatedAt": "2026-09-15T08:00:00Z"}, {"sourceId": "cu-5", "updatedAt": "2026-09-15T08:00:00Z"},
      {"sourceId": "cu-6", "updatedAt": "2026-09-15T08:00:00Z"}]');
    perform cma.ingest_upsert_commerce_customers(v_shopb, '[{"sourceId": "cu-6", "updatedAt": "2026-09-15T08:00:00Z"}]');
    -- the admin reviews the sales pipeline; support stays as the source made it; the form has no market
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_pipeline_lead(v_crm, 'deal', 'sales', true);

    -- E1. every check once; the parked write-backs unknown until the outbox exists (0007c)
    select string_agg(q.check_key || ':' || coalesce(q.total::text, '-'), ' ') into v_txt from cma.data_quality() q;
    v_want := 'deal_without_contact:1 deal_contact_incomplete:1 market_not_in_catalog:1 owner_without_person:1 '
              'telephony_user_without_person:1 crm_call_without_contact:1 telephony_call_unlinked:1 commerce_unmatched:1 '
              'commerce_ambiguous:1 writeback_parked:' || (case when to_regclass('cma.outbox_action') is null then '-' else '0' end)
              || ' contact_slots_full:1 contact_country_differs:1 customer_in_two_stores:1 pipeline_unreviewed:1 form_without_market:1';
    if v_txt is distinct from v_want or v_provoke then
      raise exception 'FAIL E1: data quality gives %', v_txt;
    end if;

    -- E2. the findings name the objects by id (and a code where the check is about one)
    select string_agg(concat_ws(':', q.check_key, q.object_type, q.object_id, q.value), ' ' order by q.check_key) into v_txt
    from cma.data_quality_of(v_t) q;
    if v_txt is distinct from
       'commerce_ambiguous:commerce_customer:cu-2 commerce_unmatched:commerce_customer:cu-1 '
       'contact_country_differs:contact:kd:GB/NL contact_slots_full:contact:kc:verifyshop crm_call_without_contact:crm_call:c1 '
       'customer_in_two_stores:commerce_customer:cu-6:verifyshop deal_contact_incomplete:contact:ky deal_without_contact:deal:dx '
       'form_without_market:form:f1 market_not_in_catalog:contact:kz:Atlantis owner_without_person:owner:o-x '
       'pipeline_unreviewed:pipeline:support:ticket telephony_call_unlinked:telephony_call:t2 telephony_user_without_person:telephony_user:u-x' then
      raise exception 'FAIL E2: the findings are %', v_txt;
    end if;

    -- E3. a fix clears its check: the owner gets a person, the form a market
    perform cma.set_user_external_id(v_agent, 'verifycrm_owner', 'o-x');
    perform cma.set_form(v_crm, 'f1', true, null, 'NL', '{}');
    if (select q.total from cma.data_quality() q where q.check_key = 'owner_without_person') <> 0
       or (select q.total from cma.data_quality() q where q.check_key = 'form_without_market') <> 0 then
      raise exception 'FAIL E3: a fixed finding is still counted';
    end if;

    -- E4. readers see the same findings through the dq views, ids only
    perform set_config('role', 'cma_readonly', true);
    select count(*) into v_n from cma_read.dq_market_not_in_catalog where tenant_id = v_t and object_id = 'kz' and value = 'Atlantis';
    if v_n <> 1 or (select count(*) from cma_read.dq_commerce_unmatched where tenant_id = v_t) <> 1
       or (select count(*) from cma_read.dq_owner_without_person where tenant_id = v_t) <> 0 then
      raise exception 'FAIL E4: the dq views disagree with the application';
    end if;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- F. Permissions, isolation and the readers' views (throwaway tenants, rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  f          jsonb;
  v_txt      text;
  v_who      text;
  v_a        text;
  v_b        text;
  v_n        bigint;
begin
  begin
    f := pg_temp.verify_0007d_fixture();
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', f ->> 't1', true);

    -- F1. an agent (no reports.view, no performance.team) and the Ingest user are refused every read;
    --     the supervisor (performance.team) reads the reports but not data quality
    foreach v_who in array array['agent1', 'ingest'] loop
      perform set_config('app.user_id', f ->> v_who, true);
      foreach v_txt in array array[
        'select cma.speed_to_lead_rows(''2026-09-14'', ''2026-09-21'')',
        'select cma.speed_to_lead_summary(''2026-09-14'', ''2026-09-21'', ''market'')',
        'select cma.lead_to_order_rows(''2026-09-14'', ''2026-09-21'')',
        'select cma.intake_per_day(''2026-09-14'', ''2026-09-21'')',
        'select cma.data_quality()'
      ] loop
        begin
          execute v_txt;
          raise exception 'FAIL F1: % ran %', v_who, v_txt;
        exception when sqlstate 'CMA06' then null;
        end;
      end loop;
    end loop;
    if v_provoke then
      raise exception 'FAIL F1: provoked';
    end if;
    perform set_config('app.user_id', f ->> 'super', true);
    perform cma.speed_to_lead_rows('2026-09-14', '2026-09-21');
    perform cma.intake_per_day('2026-09-14', '2026-09-21');
    begin
      perform cma.data_quality();
      raise exception 'FAIL F1: the supervisor read data quality';
    exception when sqlstate 'CMA06' then null;
    end;
    perform set_config('app.user_id', f ->> 'admin', true);
    perform cma.data_quality();
    perform set_config('app.user_id', '', true);
    begin
      perform cma.speed_to_lead_rows('2026-09-14', '2026-09-21');
      raise exception 'FAIL F1: a read ran without an acting user';
    exception when sqlstate 'CMA01' then null;
    end;

    -- F2. tenant two sees nothing of tenant one, also when it hands tenant one's id to the shared
    --     functions (row-level security)
    perform set_config('app.tenant_id', f ->> 't2', true);
    perform set_config('app.user_id', f ->> 'admin2', true);
    if exists (select 1 from cma.speed_to_lead_rows('2026-09-14', '2026-09-21'))
       or exists (select 1 from cma.lead_to_order_rows('2026-09-14', '2026-09-21'))
       or exists (select 1 from cma.intake_per_day('2026-09-14', '2026-09-21'))
       or exists (select 1 from cma.data_quality() q where q.total > 0)
       or exists (select 1 from cma.speed_to_lead_of((f ->> 't1')::uuid, null, null))
       or exists (select 1 from cma.intake_per_day_of((f ->> 't1')::uuid, null, null))
       or exists (select 1 from cma.data_quality_of((f ->> 't1')::uuid)) then
      raise exception 'FAIL F2: tenant two sees tenant one''s lead metrics';
    end if;

    -- F3. the application cannot reach the readers' functions or views
    foreach v_txt in array array['select cma_read.speed_to_lead_rows()', 'select count(*) from cma_read.speed_to_lead',
                                 'select cma_read.data_quality_rows()'] loop
      begin
        execute v_txt;
        raise exception 'FAIL F3: the application ran %', v_txt;
      exception when insufficient_privilege then null;
      end;
    end loop;

    -- F4. a reader limited to tenant one sees exactly the application's rows (the views have no end
    --     date: the intake comparison stops where the application's range does); limited to tenant two,
    --     none of them; readers cannot run the application's functions
    perform set_config('app.tenant_id', f ->> 't1', true);
    perform set_config('app.user_id', f ->> 'manager', true);
    select md5(string_agg(x::text, '|' order by x.deal_id)) into v_a from cma.speed_to_lead_rows('2026-09-01', '2026-09-30') x;
    select md5(string_agg(x::text, '|' order by x.business_date, x.market)) into v_b from cma.intake_per_day('2026-09-01', '2026-09-30') x;
    perform set_config('role', 'cma_readonly', true);
    if (select md5(string_agg(x::text, '|' order by x.deal_id)) from cma_read.speed_to_lead x) is distinct from v_a
       or (select md5(string_agg(x::text, '|' order by x.business_date, x.market)) from cma_read.intake_per_day_v x
           where x.business_date <= '2026-09-30') is distinct from v_b
       or (select count(*) from cma_read.lead_to_order) <> 14 then
      raise exception 'FAIL F4: the readers'' views differ from the application''s rows';
    end if;
    perform set_config('app.tenant_id', f ->> 't2', true);
    select (select count(*) from cma_read.speed_to_lead) + (select count(*) from cma_read.lead_to_order)
         + (select count(*) from cma_read.intake_per_day_v) + (select count(*) from cma_read.dq_pipeline_unreviewed) into v_n;
    if v_n <> 0 then
      raise exception 'FAIL F4: a reader limited to tenant two sees % rows of tenant one', v_n;
    end if;
    begin
      perform cma.speed_to_lead_of((f ->> 't1')::uuid, null, null);
      raise exception 'FAIL F4: a reader ran an application function';
    exception when insufficient_privilege then null;
    end;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

drop function if exists pg_temp.verify_0007d_fixture();

-- Verdict: per tenant, the lead deals and the open data-quality findings so far
select t.slug as tenant,
       (select count(*) from cma.speed_to_lead_of(t.id, null, null)) as lead_deals,
       (select count(*) from cma.speed_to_lead_of(t.id, null, null) r where r.status = 'called') as called,
       (select count(*) from cma.data_quality_of(t.id)) as dq_findings,
       case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS' else 'PASS' end as verdict
from cma.tenant t
where t.status = 'active'
order by t.slug;
