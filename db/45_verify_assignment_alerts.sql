-- =============================================================================================
-- 45_verify_assignment_alerts.sql: verifies addition 0008a, assignment alerts and automation messages
-- =============================================================================================
-- Block A checks structure and privileges; blocks B and C work on two throwaway tenants inside a
-- subtransaction that is always rolled back. All universal: no seed is assumed. Cloud SQL Studio
-- shows no notices: a check that fails raises "FAIL …" and stops the block. The last result is the
-- verdict. Run as your own IAM login, dev and prod, after 44_assignment_alerts.sql; then
-- 43_verify_messaging.sql again (unchanged).
--   A  structure and privileges: the migration row, the trigger values, the two unique indexes, the
--      functions and who may execute them
--   B  assignment alerts: the rule and its refusals, one message to the owner's person, idempotency,
--      a reassignment, an unmapped owner, no owner, the age limit, a disabled rule, a deleted record,
--      an inactive person, the created alert of 0008 still unique, permissions
--   C  automation messages: owners, emails, named people, everyone with onlyClockedIn, the reference
--      link, the refusals, permissions, tenant isolation
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
begin
  -- A1. the addition is recorded
  if not exists (select 1 from cma.schema_migration where version = '0008a') or v_provoke then
    raise exception 'FAIL A1: addition 0008a not recorded';
  end if;
  -- A2. the trigger accepts record_assigned and nothing else
  if not exists (select 1 from pg_constraint c where c.conrelid = 'cma.message_rule'::regclass and c.contype = 'c'
                   and pg_get_constraintdef(c.oid) like '%record_created%' and pg_get_constraintdef(c.oid) like '%record_assigned%') then
    raise exception 'FAIL A2: message_rule.trigger does not accept record_assigned';
  end if;
  -- A3. one alert per record for created alerts, one per record and assignee for assignment alerts
  if not exists (select 1 from pg_indexes where schemaname = 'cma' and indexname = 'message_rule_ref_idx'
                   and indexdef like '%NOT (target ? ''assignee''%')
     or not exists (select 1 from pg_indexes where schemaname = 'cma' and indexname = 'message_rule_ref_assignee_idx'
                      and indexdef like '%(target ->> ''assignee''%' and indexdef like 'CREATE UNIQUE INDEX%') then
    raise exception 'FAIL A3: the two alert indexes are not as expected';
  end if;
  -- A4. the functions exist, executable by the application only
  foreach v_fn in array array['cma.upsert_assignment_rule(text,text,text[],text,integer)', 'cma.ingest_assignment_alerts(uuid,text,text[])',
                              'cma.ingest_send_message(uuid,text,text,text,jsonb,text,text,text)', 'cma.ingest_record_alerts(uuid,text,text[])'] loop
    if to_regprocedure(v_fn) is null then
      raise exception 'FAIL A4: function % is missing', v_fn;
    end if;
    if not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute') then
      raise exception 'FAIL A4: function % is not executable by cma_app only', v_fn;
    end if;
  end loop;
end
$$;

-- B. Assignment alerts (universal, throwaway tenants, rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_t1       uuid;
  v_t2       uuid;
  v_admin    uuid;
  v_a1       uuid;
  v_a2       uuid;
  v_a3       uuid;
  v_ing1     uuid;
  v_c1       uuid;
  v_rule     uuid;
  v_rule2    uuid;
  v_n        int;
  v_txt      text;
  v_m        cma.message;
  v_ago5     text := to_char((now() - interval '5 minutes') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"');
  v_ago120   text := to_char((now() - interval '120 minutes') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"');
  v_now      text := to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"');
begin
  begin
    v_t1 := cma.create_tenant('verify-0008a-one', 'Verify 0008a one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008a-two', 'Verify 0008a two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-a1@example.invalid', 'a1') returning id into v_a1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-a2@example.invalid', 'a2') returning id into v_a2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-a3@example.invalid', 'a3') returning id into v_a3;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t1, x.uid, ar.id
    from (values (v_admin, 'admin'), (v_a1, 'agent'), (v_a2, 'agent'), (v_a3, 'agent')) as x(uid, role_key)
    join cma.app_role ar on ar.tenant_id = v_t1 and ar.key = x.role_key;
    -- the owners of the source map to a1, a2 and a3 (system '<adapter>_owner'); a3 is inactive
    insert into cma.app_user_external_id (tenant_id, user_id, system, external_id) values
      (v_t1, v_a1, 'verify_owner', 'o1'), (v_t1, v_a2, 'verify_owner', 'o2'), (v_t1, v_a3, 'verify_owner', 'o3');
    update cma.app_user set status = 'inactive' where id = v_a3;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    select c.connection_id into v_c1 from cma.upsert_connection('verify', 'Verify CRM', 'verify-portal-1', null, null) c;
    perform cma.set_connection_settings(v_c1, '{"app_host": "app.example.com", "record_url_deal": "https://{app_host}/records/{account}/deal/{id}"}');
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_pipelines(v_c1, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'pipelineId', 'p-sales', 'label', 'Sales', 'stages', jsonb_build_array(
        jsonb_build_object('stageId', 's-open', 'label', 'Open', 'order', 1, 'isClosed', false)))));
    perform set_config('app.user_id', v_admin::text, true);

    -- B1. the rule: created and updated by name, the refusals, an agent and the Ingest user cannot configure
    v_rule := cma.upsert_assignment_rule('Assigned deal', 'deal', '{}'::text[], 'urgent');
    v_rule2 := cma.upsert_assignment_rule(' Assigned deal ', 'deal', array[' p-sales', ''], 'normal');
    if v_rule2 <> v_rule or (select count(*) from cma.message_rule) <> 1
       or (select trigger from cma.message_rule where id = v_rule) <> 'record_assigned'
       or (select urgency from cma.message_rule where id = v_rule) <> 'normal'
       or (select pipeline_ids from cma.message_rule where id = v_rule) <> array['p-sales'] or v_provoke then
      raise exception 'FAIL B1: the assignment rule was not created and updated by name';
    end if;
    v_rule := cma.upsert_assignment_rule('Assigned deal', 'deal', '{}'::text[], 'normal');
    foreach v_txt in array array[
      'select cma.upsert_assignment_rule(''x'', ''contact'', ''{}'', ''normal'')',
      'select cma.upsert_assignment_rule('''', ''deal'', ''{}'', ''normal'')',
      'select cma.upsert_assignment_rule(''x'', ''deal'', ''{}'', ''loud'')',
      'select cma.upsert_assignment_rule(''x'', ''deal'', ''{}'', ''normal'', 0)'
    ] loop
      begin
        execute v_txt;
        raise exception 'FAIL B1: % was accepted', v_txt;
      exception when sqlstate 'CMA04' then null;
      end;
    end loop;
    foreach v_txt in array array[v_a1::text, v_ing1::text] loop
      perform set_config('app.user_id', v_txt, true);
      begin
        perform cma.upsert_assignment_rule('x', 'deal', '{}', 'normal');
        raise exception 'FAIL B1: % configured an assignment rule', v_txt;
      exception when sqlstate 'CMA06' then null;
      end;
    end loop;

    -- B2. records: d1 owned by o1 (a1), d2 by an unmapped owner, d3 without an owner, d4 old, d5 owned by o3 (inactive)
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_records(v_c1, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd1', 'pipelineId', 'p-sales', 'stageId', 's-open', 'market', 'NL', 'ownerRef', 'o1', 'createdAt', v_ago5, 'updatedAt', v_ago5),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd2', 'pipelineId', 'p-sales', 'stageId', 's-open', 'market', 'NL', 'ownerRef', 'o9', 'createdAt', v_ago5, 'updatedAt', v_ago5),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd3', 'pipelineId', 'p-sales', 'stageId', 's-open', 'market', 'NL', 'createdAt', v_ago5, 'updatedAt', v_ago5),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd4', 'pipelineId', 'p-sales', 'stageId', 's-open', 'market', 'NL', 'ownerRef', 'o1', 'createdAt', v_ago120, 'updatedAt', v_ago120),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd5', 'pipelineId', 'p-sales', 'stageId', 's-open', 'market', 'NL', 'ownerRef', 'o3', 'createdAt', v_ago5, 'updatedAt', v_ago5)));
    v_n := cma.ingest_assignment_alerts(v_c1, 'deal', array['d1', 'd2', 'd3', 'd4', 'd5']);
    select * into v_m from cma.message where ref_id = 'd1';
    if v_n <> 1 or (select count(*) from cma.message) <> 1
       or v_m.kind <> 'alert' or v_m.rule_id <> v_rule or v_m.title <> 'New deal assigned to you'
       or v_m.body not like 'NL · Sales · assigned __:__' or v_m.target ->> 'assignee' <> 'o1'
       or v_m.ref_url <> 'https://app.example.com/records/verify-portal-1/deal/d1'
       or (select array_agg(d.user_id) from cma.message_delivery d where d.message_id = v_m.id) <> array[v_a1] then
      raise exception 'FAIL B2: the assignment alert: % message(s), title %, assignee %, url %', v_n, v_m.title, v_m.target ->> 'assignee', v_m.ref_url;
    end if;

    -- B3. the same call again writes nothing
    if cma.ingest_assignment_alerts(v_c1, 'deal', array['d1', 'd2', 'd3', 'd4', 'd5']) <> 0 or (select count(*) from cma.message) <> 1 then
      raise exception 'FAIL B3: a retry wrote a second assignment alert';
    end if;

    -- B4. a reassignment alerts the new owner; back to the first owner alerts nothing new (once per record and owner)
    perform cma.ingest_upsert_records(v_c1, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd1', 'pipelineId', 'p-sales', 'stageId', 's-open', 'market', 'NL', 'ownerRef', 'o2', 'createdAt', v_ago5, 'updatedAt', v_now)));
    v_n := cma.ingest_assignment_alerts(v_c1, 'deal', array['d1']);
    if v_n <> 1 or (select count(*) from cma.message where ref_id = 'd1') <> 2
       or not exists (select 1 from cma.message m join cma.message_delivery d on d.message_id = m.id
                      where m.ref_id = 'd1' and m.target ->> 'assignee' = 'o2' and d.user_id = v_a2) then
      raise exception 'FAIL B4: the reassignment did not alert the new owner (%)', v_n;
    end if;
    perform cma.ingest_upsert_records(v_c1, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd1', 'pipelineId', 'p-sales', 'stageId', 's-open', 'market', 'NL', 'ownerRef', 'o1', 'createdAt', v_ago5, 'updatedAt', v_now)));
    if cma.ingest_assignment_alerts(v_c1, 'deal', array['d1']) <> 0 then
      raise exception 'FAIL B4: assigning back to the first owner alerted again';
    end if;

    -- B5. a disabled rule and a deleted record alert nothing
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_message_rule_enabled(v_rule, false);
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_records(v_c1, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd6', 'pipelineId', 'p-sales', 'stageId', 's-open', 'market', 'NL', 'ownerRef', 'o2', 'createdAt', v_ago5, 'updatedAt', v_ago5)));
    if cma.ingest_assignment_alerts(v_c1, 'deal', array['d6']) <> 0 then
      raise exception 'FAIL B5: a disabled rule alerted';
    end if;
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_message_rule_enabled(v_rule, true);
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_records(v_c1, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd6', 'deletedAt', v_now)));
    if cma.ingest_assignment_alerts(v_c1, 'deal', array['d6']) <> 0 then
      raise exception 'FAIL B5: a deleted record alerted';
    end if;

    -- B6. the created alert of 0008 is still one per record with the narrower index
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.upsert_message_rule('New deal', 'deal', '{}'::text[], 'leads.accept', false, false, null, 'normal');
    perform set_config('app.user_id', v_ing1::text, true);
    v_n := cma.ingest_record_alerts(v_c1, 'deal', array['d1']);
    if v_n <> 1 or cma.ingest_record_alerts(v_c1, 'deal', array['d1']) <> 0
       or (select count(*) from cma.message where ref_id = 'd1') <> 3 then
      raise exception 'FAIL B6: the created alert is no longer unique per record (first call %, messages for d1 %)', v_n, (select count(*) from cma.message where ref_id = 'd1');
    end if;

    -- B7. an agent cannot raise alerts; a bad type or too many ids are refused
    perform set_config('app.user_id', v_a1::text, true);
    begin
      perform cma.ingest_assignment_alerts(v_c1, 'deal', array['d1']);
      raise exception 'FAIL B7: an agent raised assignment alerts';
    exception when sqlstate 'CMA06' then null;
    end;
    perform set_config('app.user_id', v_ing1::text, true);
    begin
      perform cma.ingest_assignment_alerts(v_c1, 'Deal', array['d1']);
      raise exception 'FAIL B7: a bad record type was accepted';
    exception when sqlstate 'CMA04' then null;
    end;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- C. Automation messages (universal, throwaway tenants, rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_t1       uuid;
  v_t2       uuid;
  v_admin    uuid;
  v_a1       uuid;
  v_a2       uuid;
  v_ing1     uuid;
  v_c1       uuid;
  v_r        record;
  v_txt      text;
  v_m        cma.message;
begin
  begin
    v_t1 := cma.create_tenant('verify-0008a-one', 'Verify 0008a one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008a-two', 'Verify 0008a two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-a1@example.invalid', 'a1') returning id into v_a1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-a2@example.invalid', 'a2') returning id into v_a2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t1, x.uid, ar.id
    from (values (v_admin, 'admin'), (v_a1, 'agent'), (v_a2, 'agent')) as x(uid, role_key)
    join cma.app_role ar on ar.tenant_id = v_t1 and ar.key = x.role_key;
    insert into cma.app_user_external_id (tenant_id, user_id, system, external_id) values (v_t1, v_a1, 'verify_owner', 'o1');
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    select c.connection_id into v_c1 from cma.upsert_connection('automation', 'Verify automation', 'verify-portal-1', null, null) c;
    perform cma.set_connection_settings(v_c1, '{"app_host": "app.example.com", "record_url_deal": "https://{app_host}/records/{account}/deal/{id}"}');
    -- a1 is clocked in, a2 is not
    perform set_config('app.user_id', v_a1::text, true);
    perform cma.open_workday(now() - interval '1 minute');

    -- C1. to the people behind CRM owner ids: the unmapped id is simply nobody
    perform set_config('app.user_id', v_ing1::text, true);
    select * into v_r from cma.ingest_send_message(v_c1, ' Lead for you ', 'Call within 5 minutes.', 'urgent',
      '{"owners": {"system": "verify", "ids": ["o1", "o9"]}}'::jsonb, 'verify', 'deal', 'd1');
    select * into v_m from cma.message where id = v_r.message_id;
    if v_r.recipients <> 1 or v_m.kind <> 'announcement' or v_m.urgency <> 'urgent' or v_m.title <> 'Lead for you'
       or v_m.sender_user_id <> v_ing1 or v_m.ref_system <> 'verify' or v_m.ref_type <> 'deal' or v_m.ref_id <> 'd1'
       or v_m.ref_url <> 'https://app.example.com/records/verify-portal-1/deal/d1'
       or (select array_agg(d.user_id) from cma.message_delivery d where d.message_id = v_m.id) <> array[v_a1] or v_provoke then
      raise exception 'FAIL C1: the message to an owner: % recipient(s), title %, url %', v_r.recipients, v_m.title, v_m.ref_url;
    end if;

    -- C2. to work emails, case-insensitive; to named people; to everyone clocked in
    select * into v_r from cma.ingest_send_message(v_c1, 'By email', '', 'normal', '{"emails": ["VERIFY-a2@example.invalid"]}'::jsonb);
    if v_r.recipients <> 1 or (select array_agg(d.user_id) from cma.message_delivery d where d.message_id = v_r.message_id) <> array[v_a2] then
      raise exception 'FAIL C2: the message by email reached % recipient(s)', v_r.recipients;
    end if;
    select * into v_r from cma.ingest_send_message(v_c1, 'By id', '', 'normal', jsonb_build_object('users', jsonb_build_array(v_a1, v_a2)));
    if v_r.recipients <> 2 then
      raise exception 'FAIL C2: the message by id reached % recipient(s)', v_r.recipients;
    end if;
    select * into v_r from cma.ingest_send_message(v_c1, 'Clocked in', '', 'normal', '{"everyone": true, "onlyClockedIn": true}'::jsonb);
    if v_r.recipients <> 1 or (select array_agg(d.user_id) from cma.message_delivery d where d.message_id = v_r.message_id) <> array[v_a1] then
      raise exception 'FAIL C2: everyone clocked in reached % recipient(s)', v_r.recipients;
    end if;

    -- C3. the refusals
    foreach v_txt in array array[
      'select * from cma.ingest_send_message(''' || v_c1 || ''', ''x'', '''', ''normal'', ''{"everyone": true, "emails": ["a@example.invalid"]}'')',
      'select * from cma.ingest_send_message(''' || v_c1 || ''', ''x'', '''', ''normal'', ''{"owners": {"system": "verify", "ids": ["o9"]}}'')',
      'select * from cma.ingest_send_message(''' || v_c1 || ''', ''x'', '''', ''normal'', ''{"emails": ["not-an-address"]}'')',
      'select * from cma.ingest_send_message(''' || v_c1 || ''', ''x'', '''', ''normal'', ''{"owners": {"ids": ["o1"]}}'')',
      'select * from cma.ingest_send_message(''' || v_c1 || ''', ''x'', '''', ''normal'', ''{"everyone": true}'', ''verify'', ''deal'', null)',
      'select * from cma.ingest_send_message(''' || v_c1 || ''', '''', '''', ''normal'', ''{"everyone": true}'')',
      'select * from cma.ingest_send_message(''' || v_c1 || ''', ''x'', '''', ''loud'', ''{"everyone": true}'')'
    ] loop
      begin
        execute v_txt;
        raise exception 'FAIL C3: % was accepted', v_txt;
      exception when sqlstate 'CMA04' then null;
      end;
    end loop;
    begin
      perform cma.ingest_send_message(v_c1, 'x', '', 'normal', jsonb_build_object('users', jsonb_build_array(gen_random_uuid())));
      raise exception 'FAIL C3: an unknown person was accepted';
    exception when sqlstate 'CMA02' then null;
    end;

    -- C4. the admin (no ingest.write) and an agent cannot send through the ingest path
    foreach v_txt in array array[v_admin::text, v_a1::text] loop
      perform set_config('app.user_id', v_txt, true);
      begin
        perform cma.ingest_send_message(v_c1, 'x', '', 'normal', '{"everyone": true}'::jsonb);
        raise exception 'FAIL C4: % sent through the ingest path', v_txt;
      exception when sqlstate 'CMA06' then null;
      end;
    end loop;

    -- C5. tenant two sees none of it
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', (select x.user_id from cma.app_user_external_id x where x.tenant_id = v_t2 and x.system = 'ingest')::text, true);
    if (select count(*) from cma.message) <> 0 or (select count(*) from cma.message_delivery) <> 0 then
      raise exception 'FAIL C5: tenant two sees tenant one''s messages';
    end if;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- Verdict: per tenant, the rules by trigger and the alerts so far
select t.slug as tenant,
       (select count(*) from cma.message_rule r where r.tenant_id = t.id and r.trigger = 'record_created') as created_rules,
       (select count(*) from cma.message_rule r where r.tenant_id = t.id and r.trigger = 'record_assigned') as assignment_rules,
       (select count(*) from cma.message m where m.tenant_id = t.id and m.kind = 'alert') as alerts,
       (select count(*) from cma.message m where m.tenant_id = t.id and m.target ? 'assignee') as assignment_alerts,
       case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS' else 'PASS' end as verdict
from cma.tenant t
where t.status = 'active'
order by t.slug;
