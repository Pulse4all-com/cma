-- =============================================================================================
-- 43_verify_messaging.sql: verifies migration 0008, messaging core and record alerts
-- =============================================================================================
-- Block A checks structure and privileges; blocks B to E each work on two throwaway tenants inside
-- a subtransaction that is always rolled back. All universal: no seed is assumed. Cloud SQL Studio
-- shows no notices: a check that fails raises "FAIL …" and stops the block. The last result is the
-- verdict. Run as your own IAM login, dev and prod, after 42_messaging.sql; then
-- 31_verify_ingest_crm_records.sql and 33_verify_intake_core.sql again.
--   A  structure and privileges: tables, RLS, audit, no deletes, a message never updated, a
--      delivery updated in its times only, functions, views, the setting and the permissions
--   B  rules and record alerts: configuration and its refusals, the market's language at the
--      minimum level for people clocked in, the market from the contact, the fallback, a market
--      without a language skill, only_clocked_in false, the age limit, idempotency, a disabled
--      rule, pipelines, deleted and unknown records, resolution at send time, the link, the content
--   C  the caller's side: delivered once and only for the caller, since and limit, expiry, unread,
--      read and acknowledge on own rows only, times never move back, no acting user
--   D  manual messages: every target, onlyClockedIn, the refusals, the permission; the stats
--   E  permissions (ingest versus configuration versus reading) and tenant isolation, no deletes
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
  v_t       text;
  v_fn      text;
  v_cols    text;
begin
  -- A1. the migration is recorded
  if not exists (select 1 from cma.schema_migration where version = '0008') or v_provoke then
    raise exception 'FAIL A1: migration 0008 not recorded';
  end if;

  -- A2. three tenant tables, each with row-level security, the tenant policy and the audit trigger
  foreach v_t in array array['message_rule', 'message', 'message_delivery'] loop
    if to_regclass('cma.' || v_t) is null then
      raise exception 'FAIL A2: table cma.% is missing', v_t;
    end if;
    if not (select relrowsecurity from pg_class where oid = to_regclass('cma.' || v_t))
       or not exists (select 1 from pg_policy where polrelid = to_regclass('cma.' || v_t) and polname = 'tenant_app')
       or not exists (select 1 from pg_trigger where tgrelid = to_regclass('cma.' || v_t) and tgname = 'audit') then
      raise exception 'FAIL A2: cma.% lacks row-level security, its tenant policy or its audit trigger', v_t;
    end if;
  end loop;

  -- A3. the app inserts but never deletes; a message is never updated; a delivery only in its three
  --     times; a rule is updated (disabled), not deleted
  foreach v_t in array array['message_rule', 'message', 'message_delivery'] loop
    if has_table_privilege('cma_app', 'cma.' || v_t, 'delete') or not has_table_privilege('cma_app', 'cma.' || v_t, 'insert') then
      raise exception 'FAIL A3: cma_app must insert into and never delete from cma.%', v_t;
    end if;
  end loop;
  if has_table_privilege('cma_app', 'cma.message', 'update')
     or exists (select 1 from information_schema.column_privileges
                where table_schema = 'cma' and table_name = 'message' and grantee = 'cma_app' and privilege_type = 'UPDATE')
     or has_table_privilege('cma_app', 'cma.message_delivery', 'update')
     or has_column_privilege('cma_app', 'cma.message_delivery', 'message_id', 'update')
     or has_column_privilege('cma_app', 'cma.message_delivery', 'user_id', 'update')
     or not has_column_privilege('cma_app', 'cma.message_delivery', 'delivered_at', 'update')
     or not has_column_privilege('cma_app', 'cma.message_delivery', 'read_at', 'update')
     or not has_column_privilege('cma_app', 'cma.message_delivery', 'acknowledged_at', 'update')
     or not has_table_privilege('cma_app', 'cma.message_rule', 'update') then
    raise exception 'FAIL A3: a message must be immutable, a delivery updatable in its times only, a rule updatable';
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'cma.message_delivery'::regclass and tgname = 'check_times_once')
     or not exists (select 1 from pg_indexes where schemaname = 'cma' and indexname = 'message_rule_ref_idx'
                    and indexdef like '%UNIQUE%' and indexdef like '%rule_id IS NOT NULL%') then
    raise exception 'FAIL A3: the delivery trigger or the one-alert-per-rule-and-record index is missing';
  end if;

  -- A4. the functions: the app may execute them, readers and public may not; none runs as its owner
  foreach v_fn in array array[
    'cma.upsert_message_rule(text,text,text[],text,boolean,boolean,text,text,integer)',
    'cma.set_message_rule_enabled(uuid,boolean)', 'cma.ingest_record_alerts(uuid,text,text[])',
    'cma.send_message(text,text,text,jsonb)', 'cma.my_messages(timestamptz,integer)', 'cma.my_unread_count()',
    'cma.mark_messages_read(uuid[])', 'cma.acknowledge_message(uuid)', 'cma.message_stats(date,date)',
    'cma.assert_acting_person()', 'cma.is_clocked_in(uuid)', 'cma.has_skill(uuid,text,text,smallint)',
    'cma.record_url(uuid,text,text)', 'cma.deliver_message(uuid,uuid[])'
  ] loop
    if to_regprocedure(v_fn) is null then
      raise exception 'FAIL A4: % does not exist', v_fn;
    end if;
    if not has_function_privilege('cma_app', v_fn, 'execute')
       or has_function_privilege('cma_readonly', v_fn, 'execute')
       or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                  where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE') then
      raise exception 'FAIL A4: execute on % must be granted to cma_app only', v_fn;
    end if;
    if (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      raise exception 'FAIL A4: % must run with the caller''s rights', v_fn;
    end if;
  end loop;

  -- A5. reporting views: readers see each view and never the table, with the columns listed
  foreach v_t in array array['message_rule', 'message', 'message_delivery'] loop
    if not has_table_privilege('cma_readonly', 'cma_read.' || v_t, 'select') or has_table_privilege('cma_readonly', 'cma.' || v_t, 'select') then
      raise exception 'FAIL A5: readers must see cma_read.% and not cma.%', v_t, v_t;
    end if;
  end loop;
  select string_agg(table_name || ':' || cols, ' | ' order by table_name) into v_cols
  from (select table_name, string_agg(column_name, ',' order by ordinal_position) as cols
        from information_schema.columns
        where table_schema = 'cma_read' and table_name in ('message_rule', 'message', 'message_delivery')
        group by table_name) x;
  if v_cols is distinct from
     'message:id,tenant_id,kind,urgency,title,body,ref_system,ref_type,ref_id,ref_url,rule_id,target,sender_user_id,created_at,expires_at'
     || ' | message_delivery:tenant_id,message_id,user_id,created_at,delivered_at,read_at,acknowledged_at'
     || ' | message_rule:id,tenant_id,name,trigger,record_type,pipeline_ids,audience_permission,match_language,only_clocked_in,fallback_permission,urgency,enabled,max_age_minutes,created_at,updated_at' then
    raise exception 'FAIL A5: the reporting views expose [%]', v_cols;
  end if;

  -- A6. the age setting (0007) and the permissions the rules and functions name
  if not exists (select 1 from cma.setting where key = 'alerts.max_age_minutes' and value_type = 'integer' and default_value = '60')
     or (select count(*) from cma.permission where key in ('messages.send', 'leads.accept', 'leads.manage', 'performance.team', 'tenant.configure', 'ingest.write')) <> 6 then
    raise exception 'FAIL A6: the setting alerts.max_age_minutes or a permission is missing';
  end if;
end
$$;

-- B. Rules and record alerts (throwaway tenants, rolled back)
--    Tenant one (zone Europe/Amsterdam): markets NL (Dutch at level 2 or more), DE (German, any
--    level) and GB (no language skill). Agents: a1 Dutch 3 clocked in, a2 Dutch 1 clocked in, a3
--    Dutch 4 clocked in and out again, a4 German 4 clocked in, a5 Dutch 4 clocked in but inactive; the admin
--    and the manager hold leads.manage, the supervisor leads.accept, none of them clocked in.
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_t1       uuid;
  v_t2       uuid;
  v_admin    uuid;
  v_a1       uuid;
  v_a2       uuid;
  v_a3       uuid;
  v_a4       uuid;
  v_a5       uuid;
  v_sup      uuid;
  v_mgr      uuid;
  v_ing1     uuid;
  v_c1       uuid;
  v_rule1    uuid;
  v_rule2    uuid;
  v_rule3    uuid;
  v_n        int;
  v_txt      text;
  v_m        cma.message;
  v_ago5     text := to_char((now() - interval '5 minutes') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"');
  v_ago120   text := to_char((now() - interval '120 minutes') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"');
  v_ids501   text[];
begin
  begin
    v_t1 := cma.create_tenant('verify-0008-one', 'Verify 0008 one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008-two', 'Verify 0008 two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-a1@example.invalid', 'a1') returning id into v_a1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-a2@example.invalid', 'a2') returning id into v_a2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-a3@example.invalid', 'a3') returning id into v_a3;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-a4@example.invalid', 'a4') returning id into v_a4;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-a5@example.invalid', 'a5') returning id into v_a5;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-sup@example.invalid', 'sup') returning id into v_sup;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-mgr@example.invalid', 'mgr') returning id into v_mgr;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t1, x.uid, ar.id
    from (values (v_admin, 'admin'), (v_a1, 'agent'), (v_a2, 'agent'), (v_a3, 'agent'), (v_a4, 'agent'), (v_a5, 'agent'),
                 (v_sup, 'supervisor'), (v_mgr, 'manager')) as x(uid, role_key)
    join cma.app_role ar on ar.tenant_id = v_t1 and ar.key = x.role_key;
    insert into cma.skill (tenant_id, dimension, key, name) values
      (v_t1, 'language', 'verify-dutch', 'Verify Dutch'), (v_t1, 'language', 'verify-german', 'Verify German');
    insert into cma.user_skill (tenant_id, user_id, skill_id, level)
    select v_t1, x.uid, s.id, x.lvl
    from (values (v_a1, 'verify-dutch', 3), (v_a2, 'verify-dutch', 1), (v_a3, 'verify-dutch', 4),
                 (v_a4, 'verify-german', 4), (v_a5, 'verify-dutch', 4)) as x(uid, skill_key, lvl)
    join cma.skill s on s.tenant_id = v_t1 and s.key = x.skill_key;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    foreach v_txt in array array[v_a1::text, v_a2::text, v_a3::text, v_a4::text, v_a5::text] loop
      perform set_config('app.user_id', v_txt, true);
      perform cma.open_workday(now() - interval '1 minute');
    end loop;
    -- a3 clocked out again: an ended day is not clocked in
    perform set_config('app.user_id', v_a3::text, true);
    perform cma.end_workday((select w.id from cma.workday w where w.user_id = v_a3), now());
    perform set_config('role', 'cma_owner', true);
    update cma.app_user set status = 'inactive' where id = v_a5;
    perform set_config('role', 'cma_app', true);

    perform set_config('app.user_id', v_admin::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR', 'verify-dutch', 2::smallint);
    perform cma.upsert_market('DE', 'Germany', 'Europe/Berlin', 'de', 'EUR', 'verify-german');
    perform cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP');
    select c.connection_id into v_c1 from cma.upsert_connection('verify', 'Verify CRM', 'verify-portal-1', null, null) c;
    perform cma.set_connection_settings(v_c1, '{"app_host": "app.example.com", "record_url_deal": "https://{app_host}/records/{account}/deal/{id}"}');
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_pipelines(v_c1, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'pipelineId', 'p-sales', 'label', 'Sales', 'stages', jsonb_build_array(
        jsonb_build_object('stageId', 's-open', 'label', 'Open', 'order', 1, 'isClosed', false))),
      jsonb_build_object('recordType', 'deal', 'pipelineId', 'p-test', 'label', 'Test', 'stages', jsonb_build_array(
        jsonb_build_object('stageId', 's-open', 'label', 'Open', 'order', 1, 'isClosed', false)))));
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_connection_pipeline(v_c1, 'deal', 'p-test', false, false, null);

    -- B1. rules: created and updated by name, pipelines trimmed and deduplicated; the refusals; an
    --     agent and the Ingest user cannot configure
    v_rule1 := cma.upsert_message_rule('New deal', 'deal', '{}'::text[], 'leads.accept', true, true, 'leads.manage', 'urgent');
    v_rule3 := cma.upsert_message_rule(' New deal ', 'deal', '{}'::text[], 'leads.accept', true, true, 'leads.manage', 'normal');
    if v_rule3 <> v_rule1
       or (select count(*) from cma.message_rule) <> 1
       or (select urgency from cma.message_rule where id = v_rule1) <> 'normal'
       or (select enabled from cma.message_rule where id = v_rule1) is not true or v_provoke then
      raise exception 'FAIL B1: the rule was not created and updated by name';
    end if;
    v_rule2 := cma.upsert_message_rule('Dutch speakers', 'deal', array[' p-sales', 'p-sales', ''], 'leads.accept', true, false, 'leads.manage', 'normal');
    if (select pipeline_ids from cma.message_rule where id = v_rule2) <> array['p-sales'] then
      raise exception 'FAIL B1: pipeline ids were kept as %', (select pipeline_ids from cma.message_rule where id = v_rule2);
    end if;
    perform cma.set_message_rule_enabled(v_rule2, false);
    foreach v_txt in array array[
      'select cma.upsert_message_rule(''x'', ''contact'', ''{}'', ''leads.accept'', true, true, null, ''normal'')',
      'select cma.upsert_message_rule('''', ''deal'', ''{}'', ''leads.accept'', true, true, null, ''normal'')',
      'select cma.upsert_message_rule(''x'', ''deal'', ''{}'', ''leads.accept'', true, true, null, ''loud'')',
      'select cma.upsert_message_rule(''x'', ''deal'', ''{}'', ''leads.accept'', null, true, null, ''normal'')',
      'select cma.upsert_message_rule(''x'', ''deal'', ''{}'', ''leads.accept'', true, true, null, ''normal'', 0)'
    ] loop
      begin
        execute v_txt;
        raise exception 'FAIL B1: % was accepted', v_txt;
      exception when sqlstate 'CMA04' then null;
      end;
    end loop;
    begin
      perform cma.upsert_message_rule('x', 'deal', '{}', 'no.such', true, true, null, 'normal');
      raise exception 'FAIL B1: an unknown audience permission was accepted';
    exception when sqlstate 'CMA02' then null;
    end;
    begin
      perform cma.set_message_rule_enabled(gen_random_uuid(), true);
      raise exception 'FAIL B1: an unknown rule was enabled';
    exception when sqlstate 'CMA02' then null;
    end;
    foreach v_txt in array array[v_a1::text, v_ing1::text] loop
      perform set_config('app.user_id', v_txt, true);
      begin
        perform cma.upsert_message_rule('x', 'deal', '{}', 'leads.accept', true, true, null, 'normal');
        raise exception 'FAIL B1: % configured a rule', v_txt;
      exception when sqlstate 'CMA06' then null;
      end;
      begin
        perform cma.set_message_rule_enabled(v_rule1, false);
        raise exception 'FAIL B1: % disabled a rule', v_txt;
      exception when sqlstate 'CMA06' then null;
      end;
    end loop;

    -- B2. an NL deal created five minutes ago: the agents clocked in with Dutch at level 2 or more
    --     (a1 only: a2's level is too low, a3 has clocked out, a4 speaks German, a5 is inactive);
    --     content of references only; the link from the connection's template
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_records(v_c1, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd1', 'pipelineId', 'p-sales', 'stageId', 's-open', 'market', 'NL', 'createdAt', v_ago5),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd2', 'pipelineId', 'p-sales', 'stageId', 's-open', 'contactId', 'c2', 'createdAt', v_ago5),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd3', 'pipelineId', 'p-sales', 'stageId', 's-open', 'market', 'Atlantis', 'createdAt', v_ago5),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd4', 'pipelineId', 'p-sales', 'stageId', 's-open', 'market', 'GB', 'createdAt', v_ago5),
      jsonb_build_object('recordType', 'ticket', 'sourceId', 't1', 'market', 'NL', 'createdAt', v_ago5)));
    perform cma.ingest_upsert_contacts(v_c1, '[{"sourceId": "c2", "country": "de"}]');
    v_n := cma.ingest_record_alerts(v_c1, 'deal', array['d1']);
    select string_agg(u.display_name, ',' order by u.display_name) into v_txt
    from cma.message m join cma.message_delivery d on d.tenant_id = m.tenant_id and d.message_id = m.id
    join cma.app_user u on u.tenant_id = d.tenant_id and u.id = d.user_id
    where m.ref_id = 'd1' and m.rule_id = v_rule1;
    if v_n <> 1 or v_txt is distinct from 'a1' then
      raise exception 'FAIL B2: % message(s), recipients [%] instead of 1 and [a1]', v_n, v_txt;
    end if;
    select * into v_m from cma.message where ref_id = 'd1' and rule_id = v_rule1;
    if v_m.kind <> 'alert' or v_m.urgency <> 'normal' or v_m.title <> 'New deal'
       or v_m.body <> 'NL · Sales · created ' || to_char((now() - interval '5 minutes') at time zone 'Europe/Amsterdam', 'HH24:MI')
       or v_m.ref_system <> 'verify' or v_m.ref_type <> 'deal'
       or v_m.ref_url is distinct from 'https://app.example.com/records/verify-portal-1/deal/d1'
       or v_m.sender_user_id <> v_ing1 or v_m.expires_at is not null
       or v_m.target <> jsonb_build_object('rule', 'New deal', 'permission', 'leads.accept', 'market', 'NL',
                                           'matchLanguage', true, 'onlyClockedIn', true, 'fallback', false) then
      raise exception 'FAIL B2: the alert reads % / % / % / %', v_m.title, v_m.body, v_m.ref_url, v_m.target;
    end if;
    if exists (select 1 from cma.message_delivery where delivered_at is not null or read_at is not null or acknowledged_at is not null) then
      raise exception 'FAIL B2: a new delivery carries a time';
    end if;

    -- B3. idempotent: the same call again writes nothing
    v_n := cma.ingest_record_alerts(v_c1, 'deal', array['d1', 'd1']);
    if v_n <> 0 or (select count(*) from cma.message) <> 1 or (select count(*) from cma.message_delivery) <> 1 then
      raise exception 'FAIL B3: a second call wrote % message(s)', v_n;
    end if;

    -- B4. a deal without a market takes its contact's country (DE, any German level): a4
    -- B5. a market outside the catalog matches nobody on language: the fallback, leads.manage
    --     holders (admin and manager), whether clocked in or not
    -- B6. a market without a language skill (GB): every clocked-in, active holder of leads.accept
    v_n := cma.ingest_record_alerts(v_c1, 'deal', array['d2', 'd3', 'd4']);
    select string_agg(m.ref_id || '=' || x.names, ' ' order by m.ref_id) into v_txt
    from cma.message m
    cross join lateral (select string_agg(u.display_name, ',' order by u.display_name) as names
                        from cma.message_delivery d join cma.app_user u on u.tenant_id = d.tenant_id and u.id = d.user_id
                        where d.tenant_id = m.tenant_id and d.message_id = m.id) x
    where m.ref_id in ('d2', 'd3', 'd4');
    if v_n <> 3 or v_txt is distinct from 'd2=a4 d3=admin,mgr d4=a1,a2,a4' then
      raise exception 'FAIL B4: % message(s), recipients %', v_n, v_txt;
    end if;
    if (select target ->> 'fallback' from cma.message where ref_id = 'd3') <> 'true'
       or (select target ->> 'market' from cma.message where ref_id = 'd2') <> 'DE'
       or (select body from cma.message where ref_id = 'd3') not like 'Atlantis · Sales · created %' then
      raise exception 'FAIL B5: the fallback or the market is not recorded on the alert';
    end if;
    -- a rule of another type without a fallback: written, nobody receives it
    perform set_config('app.user_id', v_admin::text, true);
    v_rule3 := cma.upsert_message_rule('New ticket', 'ticket', '{}'::text[], 'leads.accept', true, true, null, 'urgent');
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_records(v_c1, '[{"recordType": "ticket", "sourceId": "t2", "market": "Atlantis"}]'::jsonb
      || jsonb_build_array(jsonb_build_object('recordType', 'ticket', 'sourceId', 't3', 'market', 'Atlantis', 'createdAt', v_ago5)));
    v_n := cma.ingest_record_alerts(v_c1, 'ticket', array['t3']);
    select * into v_m from cma.message where ref_id = 't3';
    if v_n <> 1 or v_m.rule_id <> v_rule3 or v_m.urgency <> 'urgent' or v_m.title <> 'New ticket' or v_m.ref_url is not null
       or exists (select 1 from cma.message_delivery where message_id = v_m.id) then
      raise exception 'FAIL B5: the ticket alert without a fallback: % message(s), rule %, url %', v_n, v_m.rule_id, v_m.ref_url;
    end if;

    -- B7. only_clocked_in false (rule two, enabled now, pipeline p-sales): a1 and a3 (Dutch 2+),
    --     beside rule one's a1
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_message_rule_enabled(v_rule2, true);
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_records(v_c1, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd6', 'pipelineId', 'p-sales', 'stageId', 's-open', 'market', 'nl', 'createdAt', v_ago5)));
    v_n := cma.ingest_record_alerts(v_c1, 'deal', array['d6']);
    select string_agg(r.name || '=' || x.names, ' ' order by r.name) into v_txt
    from cma.message m join cma.message_rule r on r.tenant_id = m.tenant_id and r.id = m.rule_id
    cross join lateral (select string_agg(u.display_name, ',' order by u.display_name) as names
                        from cma.message_delivery d join cma.app_user u on u.tenant_id = d.tenant_id and u.id = d.user_id
                        where d.tenant_id = m.tenant_id and d.message_id = m.id) x
    where m.ref_id = 'd6';
    if v_n <> 2 or v_txt is distinct from 'Dutch speakers=a1,a3 New deal=a1' then
      raise exception 'FAIL B7: % message(s), %', v_n, v_txt;
    end if;

    -- B8. the age limit: a deal created two hours ago raises nothing under the default 60 minutes;
    --     with the rule's own limit of 300 minutes, rule one alerts and rule two (default) does not
    perform cma.ingest_upsert_records(v_c1, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd7', 'pipelineId', 'p-sales', 'stageId', 's-open', 'market', 'NL', 'createdAt', v_ago120)));
    v_n := cma.ingest_record_alerts(v_c1, 'deal', array['d7']);
    if v_n <> 0 or exists (select 1 from cma.message where ref_id = 'd7') then
      raise exception 'FAIL B8: an old record raised an alert';
    end if;
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.upsert_message_rule('New deal', 'deal', '{}'::text[], 'leads.accept', true, true, 'leads.manage', 'normal', 300);
    perform set_config('app.user_id', v_ing1::text, true);
    v_n := cma.ingest_record_alerts(v_c1, 'deal', array['d7']);
    if v_n <> 1
       or (select rule_id from cma.message where ref_id = 'd7') <> v_rule1 then
      raise exception 'FAIL B8: the rule''s own age limit was not applied';
    end if;
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.upsert_message_rule('New deal', 'deal', '{}'::text[], 'leads.accept', true, true, 'leads.manage', 'normal', null);

    -- B9. disabled rules raise nothing
    perform cma.set_message_rule_enabled(v_rule1, false);
    perform cma.set_message_rule_enabled(v_rule2, false);
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_records(v_c1, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd8', 'pipelineId', 'p-sales', 'stageId', 's-open', 'market', 'NL', 'createdAt', v_ago5)));
    if cma.ingest_record_alerts(v_c1, 'deal', array['d8']) <> 0 then
      raise exception 'FAIL B9: a disabled rule raised an alert';
    end if;
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_message_rule_enabled(v_rule1, true);
    perform cma.set_message_rule_enabled(v_rule2, true);

    -- B10. pipelines: a pipeline that is not counted raises nothing (rule one: all counted; rule
    --      two: p-sales only); a pipeline not seen yet counts for rule one only
    -- B11. a deleted record and an unknown id raise nothing
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_records(v_c1, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd9', 'pipelineId', 'p-test', 'stageId', 's-open', 'market', 'NL', 'createdAt', v_ago5),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd10', 'pipelineId', 'p-new', 'market', 'NL', 'createdAt', v_ago5),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd11', 'pipelineId', 'p-sales', 'stageId', 's-open', 'market', 'NL', 'createdAt', v_ago5)));
    perform cma.ingest_upsert_records(v_c1, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd11', 'deletedAt', v_ago5)));
    v_n := cma.ingest_record_alerts(v_c1, 'deal', array['d9', 'd10', 'd11', 'no-such-deal']);
    select string_agg(m.ref_id || ':' || r.name || ':' || m.body, ' ' order by m.ref_id) into v_txt
    from cma.message m join cma.message_rule r on r.tenant_id = m.tenant_id and r.id = m.rule_id
    where m.ref_id in ('d9', 'd10', 'd11', 'no-such-deal');
    if v_n <> 1 or v_txt not like 'd10:New deal:NL · p-new · created %' then
      raise exception 'FAIL B10: % message(s): %', v_n, v_txt;
    end if;

    -- B12. recipients are resolved when the alert is written: a2 reaches Dutch level 3 afterwards;
    --      d1's alert keeps its one recipient, a new deal reaches a1 and a2
    perform set_config('role', 'cma_owner', true);
    update cma.user_skill set valid_to = now() where user_id = v_a2 and valid_to is null;
    insert into cma.user_skill (tenant_id, user_id, skill_id, level)
    select v_t1, v_a2, s.id, 3 from cma.skill s where s.tenant_id = v_t1 and s.key = 'verify-dutch';
    perform set_config('role', 'cma_app', true);
    perform cma.ingest_upsert_records(v_c1, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd12', 'pipelineId', 'p-sales', 'stageId', 's-open', 'market', 'NL', 'createdAt', v_ago5)));
    perform cma.ingest_record_alerts(v_c1, 'deal', array['d1', 'd12']);
    select string_agg(m.ref_id || '=' || x.names, ' ' order by m.ref_id) into v_txt
    from cma.message m
    cross join lateral (select string_agg(u.display_name, ',' order by u.display_name) as names
                        from cma.message_delivery d join cma.app_user u on u.tenant_id = d.tenant_id and u.id = d.user_id
                        where d.tenant_id = m.tenant_id and d.message_id = m.id) x
    where m.ref_id in ('d1', 'd12') and m.rule_id = v_rule1;
    if v_txt is distinct from 'd1=a1 d12=a1,a2' then
      raise exception 'FAIL B12: recipients after the skill change: %', v_txt;
    end if;
    -- rule two now also alerts for d1 (it was disabled at the time): one per rule and record
    if (select count(*) from cma.message where ref_id = 'd1') <> 2 then
      raise exception 'FAIL B12: d1 does not carry one alert per rule';
    end if;

    -- B13. the link: none without a template for the type, none for a template that is not https
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_connection_settings(v_c1, '{"app_host": "app.example.com", "record_url_deal": "http://{app_host}/deal/{id}"}');
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_records(v_c1, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd13', 'pipelineId', 'p-sales', 'stageId', 's-open', 'market', 'NL', 'createdAt', v_ago5)));
    perform cma.ingest_record_alerts(v_c1, 'deal', array['d13']);
    if exists (select 1 from cma.message where ref_id = 'd13' and ref_url is not null)
       or cma.record_url(v_c1, 'deal', 'd 13') is not null or cma.record_url(v_c1, 'ticket', 't3') is not null then
      raise exception 'FAIL B13: a link was built from an http template, an unsafe id or no template';
    end if;

    -- B14. permissions and bounds: a configuring person cannot raise alerts; an unknown connection;
    --      more than 500 ids
    select array_agg('x' || g) into v_ids501 from generate_series(1, 501) g;
    begin
      perform cma.ingest_record_alerts(gen_random_uuid(), 'deal', array['d1']);
      raise exception 'FAIL B14: an unknown connection was accepted';
    exception when sqlstate 'CMA02' then null;
    end;
    begin
      perform cma.ingest_record_alerts(v_c1, 'deal', v_ids501);
      raise exception 'FAIL B14: 501 ids were accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    perform set_config('app.user_id', v_admin::text, true);
    begin
      perform cma.ingest_record_alerts(v_c1, 'deal', array['d1']);
      raise exception 'FAIL B14: a configuring person raised alerts';
    exception when sqlstate 'CMA06' then null;
    end;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- C. The caller's side (throwaway tenants, rolled back)
--    A supervisor sends m1 to a1 and a2 and m2 (urgent) to a1, m3 and m4 to a3; an expired m0 sits
--    in a1's deliveries.
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_t1       uuid;
  v_sup      uuid;
  v_a1       uuid;
  v_a2       uuid;
  v_a3       uuid;
  v_a4       uuid;
  v_ing1     uuid;
  v_m0       uuid;
  v_m1       uuid;
  v_m2       uuid;
  v_m3       uuid;
  v_m4       uuid;
  v_n        int;
  v_audit    int;
  v_txt      text;
begin
  begin
    v_t1 := cma.create_tenant('verify-0008-one', 'Verify 0008 one', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-sup@example.invalid', 'sup') returning id into v_sup;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-a1@example.invalid', 'a1') returning id into v_a1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-a2@example.invalid', 'a2') returning id into v_a2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-a3@example.invalid', 'a3') returning id into v_a3;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-a4@example.invalid', 'a4') returning id into v_a4;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t1, x.uid, ar.id
    from (values (v_sup, 'supervisor'), (v_a1, 'agent'), (v_a2, 'agent'), (v_a3, 'agent'), (v_a4, 'agent')) as x(uid, role_key)
    join cma.app_role ar on ar.tenant_id = v_t1 and ar.key = x.role_key;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    insert into cma.message (tenant_id, kind, title, created_at, expires_at)
    values (v_t1, 'announcement', 'Expired', now() - interval '2 hours', now() - interval '1 hour') returning id into v_m0;
    insert into cma.message_delivery (tenant_id, message_id, user_id) values (v_t1, v_m0, v_a1);

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_sup::text, true);
    v_m1 := cma.send_message('One', 'For a1 and a2', 'normal', jsonb_build_object('users', jsonb_build_array(v_a1, v_a2)));
    v_m2 := cma.send_message('Two', '', 'urgent', jsonb_build_object('users', jsonb_build_array(v_a1)));
    v_m3 := cma.send_message('Three', '', 'normal', jsonb_build_object('users', jsonb_build_array(v_a3)));
    v_m4 := cma.send_message('Four', '', 'normal', jsonb_build_object('users', jsonb_build_array(v_a3)));

    -- C1. a1's poll: m2 then m1 (newest first), the expired m0 left out; both delivered now; a2's
    --     delivery of m1 untouched
    perform set_config('app.user_id', v_a1::text, true);
    select string_agg(x.title || ':' || (x.delivered_at is not null), ',') into v_txt from cma.my_messages() x;
    if v_txt is distinct from 'Two:true,One:true' or v_provoke then
      raise exception 'FAIL C1: a1''s poll returned [%]', v_txt;
    end if;
    if (select delivered_at from cma.message_delivery where message_id = v_m1 and user_id = v_a2) is not null
       or (select delivered_at from cma.message_delivery where message_id = v_m0 and user_id = v_a1) is not null then
      raise exception 'FAIL C1: the poll set delivered_at on another person''s or an expired delivery';
    end if;

    -- C2. a second poll changes no delivery (no audit row)
    select count(*) into v_audit from cma.audit_log where table_name = 'message_delivery';
    perform cma.my_messages();
    if (select count(*) from cma.audit_log where table_name = 'message_delivery') <> v_audit then
      raise exception 'FAIL C2: a second poll changed a delivery';
    end if;

    -- C3. since: nothing after now, both after a minute ago; the limit: a3 asks for one and only that
    --     one (the newest, m4) is delivered; a limit of 0 is refused
    if (select count(*) from cma.my_messages(now())) <> 0 or (select count(*) from cma.my_messages(now() - interval '1 minute')) <> 2 then
      raise exception 'FAIL C3: since is not applied';
    end if;
    begin
      perform cma.my_messages(null, 0);
      raise exception 'FAIL C3: a limit of 0 was accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    perform set_config('app.user_id', v_a3::text, true);
    select string_agg(x.title, ',') into v_txt from cma.my_messages(null, 1) x;
    if v_txt is distinct from 'Four'
       or (select delivered_at from cma.message_delivery where message_id = v_m3 and user_id = v_a3) is not null then
      raise exception 'FAIL C3: a limit of one returned [%] or delivered more', v_txt;
    end if;

    -- C4. unread and read: a1 has two unread (m0 expired is not counted); marking m1 and a3's m3
    --     reads one; again reads none; a2's copy of m1 stays unread
    perform set_config('app.user_id', v_a1::text, true);
    if cma.my_unread_count() <> 2 then
      raise exception 'FAIL C4: a1 has % unread instead of 2', cma.my_unread_count();
    end if;
    v_n := cma.mark_messages_read(array[v_m1, v_m3]);
    if v_n <> 1 or cma.my_unread_count() <> 1 or cma.mark_messages_read(array[v_m1]) <> 0
       or (select read_at from cma.message_delivery where message_id = v_m1 and user_id = v_a2) is not null
       or (select read_at from cma.message_delivery where message_id = v_m3 and user_id = v_a3) is not null then
      raise exception 'FAIL C4: marking read changed % row(s) or another person''s', v_n;
    end if;

    -- C5. acknowledge: m2 acknowledged and read; again changes nothing; a3's m3 is not a1's (CMA02);
    --     a2 acknowledges m1 before any poll: delivered, read and acknowledged together
    perform cma.acknowledge_message(v_m2);
    if (select acknowledged_at is null or read_at is null from cma.message_delivery where message_id = v_m2 and user_id = v_a1) then
      raise exception 'FAIL C5: the acknowledgement did not set acknowledged_at and read_at';
    end if;
    select count(*) into v_audit from cma.audit_log where table_name = 'message_delivery';
    perform cma.acknowledge_message(v_m2);
    if (select count(*) from cma.audit_log where table_name = 'message_delivery') <> v_audit then
      raise exception 'FAIL C5: a second acknowledgement changed the delivery';
    end if;
    begin
      perform cma.acknowledge_message(v_m3);
      raise exception 'FAIL C5: a1 acknowledged a3''s message';
    exception when sqlstate 'CMA02' then null;
    end;
    perform set_config('app.user_id', v_a2::text, true);
    perform cma.acknowledge_message(v_m1);
    if (select delivered_at is null or read_at is null or acknowledged_at is null
        from cma.message_delivery where message_id = v_m1 and user_id = v_a2) then
      raise exception 'FAIL C5: acknowledging before a poll left a time empty';
    end if;

    -- C6. times never move back or change once set, whoever writes; recipient and message never
    --     change; a message is never updated
    foreach v_txt in array array[
      format('update cma.message_delivery set read_at = null where message_id = %L and user_id = %L', v_m1, v_a1),
      format('update cma.message_delivery set delivered_at = now() - interval ''1 day'' where message_id = %L and user_id = %L', v_m1, v_a1),
      format('update cma.message_delivery set acknowledged_at = now() + interval ''1 minute'' where message_id = %L and user_id = %L', v_m2, v_a1)
    ] loop
      begin
        execute v_txt;
        raise exception 'FAIL C6: % was accepted', v_txt;
      exception when sqlstate 'CMA04' then null;
      end;
    end loop;
    foreach v_txt in array array[
      format('update cma.message_delivery set user_id = %L where message_id = %L and user_id = %L', v_a4, v_m1, v_a1),
      format('update cma.message set title = ''Changed'' where id = %L', v_m1)
    ] loop
      begin
        execute v_txt;
        raise exception 'FAIL C6: % was accepted', v_txt;
      exception when insufficient_privilege then null;
      end;
    end loop;

    -- C7. no acting user, the Ingest user and an inactive person read nothing
    perform set_config('app.user_id', '', true);
    begin
      perform cma.my_messages();
      raise exception 'FAIL C7: a poll without an acting user was accepted';
    exception when sqlstate 'CMA01' then null;
    end;
    perform set_config('app.user_id', v_ing1::text, true);
    begin
      perform cma.my_unread_count();
      raise exception 'FAIL C7: the Ingest user read messages';
    exception when sqlstate 'CMA01' then null;
    end;
    perform set_config('role', 'cma_owner', true);
    update cma.app_user set status = 'inactive' where id = v_a4;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_a4::text, true);
    begin
      perform cma.mark_messages_read(array[v_m1]);
      raise exception 'FAIL C7: an inactive person marked messages read';
    exception when sqlstate 'CMA01' then null;
    end;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- D. Manual messages and stats (throwaway tenants, rolled back)
--    Tenant one: a1 (team verify-nl, Dutch 3, clocked in), a2 (Dutch 1, clocked in, left team
--    verify-nl yesterday), a3 (team verify-nl, Dutch 4), a4 inactive, the supervisor and an analyst.
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_t1       uuid;
  v_t2       uuid;
  v_sup      uuid;
  v_a1       uuid;
  v_a2       uuid;
  v_a3       uuid;
  v_a4       uuid;
  v_analyst  uuid;
  v_other    uuid;
  v_team     uuid;
  v_m        uuid;
  v_msg      cma.message;
  v_txt      text;
  v_target   jsonb;
  v_stats    record;
begin
  begin
    v_t1 := cma.create_tenant('verify-0008-one', 'Verify 0008 one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008-two', 'Verify 0008 two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-sup@example.invalid', 'sup') returning id into v_sup;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-a1@example.invalid', 'a1') returning id into v_a1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-a2@example.invalid', 'a2') returning id into v_a2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-a3@example.invalid', 'a3') returning id into v_a3;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-a4@example.invalid', 'a4') returning id into v_a4;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-analyst@example.invalid', 'analyst') returning id into v_analyst;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-other@example.invalid', 'other') returning id into v_other;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select v_t1, x.uid, ar.id
    from (values (v_sup, 'supervisor'), (v_a1, 'agent'), (v_a2, 'agent'), (v_a3, 'agent'), (v_a4, 'agent'),
                 (v_analyst, 'analytics')) as x(uid, role_key)
    join cma.app_role ar on ar.tenant_id = v_t1 and ar.key = x.role_key;
    insert into cma.team (tenant_id, key, name, valid_from) values (v_t1, 'verify-nl', 'Verify NL', now() - interval '3 days') returning id into v_team;
    insert into cma.team_member (tenant_id, user_id, team_id, valid_from, valid_to) values
      (v_t1, v_a1, v_team, now() - interval '3 days', null),
      (v_t1, v_a3, v_team, now() - interval '3 days', null),
      (v_t1, v_a2, v_team, now() - interval '3 days', now() - interval '1 day');
    insert into cma.skill (tenant_id, dimension, key, name) values (v_t1, 'language', 'verify-dutch', 'Verify Dutch');
    insert into cma.user_skill (tenant_id, user_id, skill_id, level)
    select v_t1, x.uid, s.id, x.lvl
    from (values (v_a1, 3), (v_a2, 1), (v_a3, 4), (v_a4, 4)) as x(uid, lvl)
    join cma.skill s on s.tenant_id = v_t1 and s.key = 'verify-dutch';
    update cma.app_user set status = 'inactive' where id = v_a4;

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    foreach v_txt in array array[v_a1::text, v_a2::text] loop
      perform set_config('app.user_id', v_txt, true);
      perform cma.open_workday(now());
    end loop;

    -- D1. an agent cannot send
    perform set_config('app.user_id', v_a1::text, true);
    begin
      perform cma.send_message('Hello', '', 'normal', '{"everyone": true}');
      raise exception 'FAIL D1: an agent sent a message';
    exception when sqlstate 'CMA06' then null;
    end;
    if (select count(*) from cma.message) <> 0 or v_provoke then
      raise exception 'FAIL D1: the refused send left % message(s)', (select count(*) from cma.message);
    end if;

    -- D2 to D6. every target, resolved to active people now
    perform set_config('app.user_id', v_sup::text, true);
    for v_target, v_txt in
      select t::jsonb, e from (values
        ('{"everyone": true}', 'a1,a2,a3,analyst,sup'),
        ('{"teams": ["verify-nl"]}', 'a1,a3'),
        ('{"language": {"skill": "verify-dutch", "minLevel": 3}}', 'a1,a3'),
        ('{"language": {"skill": "verify-dutch", "minLevel": null}}', 'a1,a2,a3'),
        ('{"language": {"skill": "verify-dutch"}}', 'a1,a2,a3'),
        ('{"users": ["' || v_a2 || '", "' || v_a2 || '"]}', 'a2'),
        ('{"everyone": true, "onlyClockedIn": true}', 'a1,a2'),
        ('{"teams": ["verify-nl"], "onlyClockedIn": true}', 'a1'),
        ('{"everyone": true, "onlyClockedIn": false}', 'a1,a2,a3,analyst,sup')) as x(t, e)
    loop
      v_m := cma.send_message('Target', 'A test', 'normal', v_target);
      if (select string_agg(u.display_name, ',' order by u.display_name)
          from cma.message_delivery d join cma.app_user u on u.tenant_id = d.tenant_id and u.id = d.user_id
          where d.message_id = v_m) is distinct from v_txt then
        raise exception 'FAIL D2: target % reached [%] instead of [%]', v_target,
          (select string_agg(u.display_name, ',' order by u.display_name)
           from cma.message_delivery d join cma.app_user u on u.tenant_id = d.tenant_id and u.id = d.user_id
           where d.message_id = v_m), v_txt;
      end if;
    end loop;

    -- D7. the refusals: unknown team, skill, foreign or inactive person (CMA02); two groups, an
    --     unknown key, empty title, long body, bad urgency, everyone false, nobody reached (CMA04)
    foreach v_txt in array array[
      'select cma.send_message(''x'', '''', ''normal'', ''{"teams": ["no-such-team"]}'')',
      'select cma.send_message(''x'', '''', ''normal'', ''{"language": {"skill": "no-such"}}'')',
      format('select cma.send_message(''x'', '''', ''normal'', ''{"users": ["%s"]}'')', v_other),
      format('select cma.send_message(''x'', '''', ''normal'', ''{"users": ["%s"]}'')', v_a4)
    ] loop
      begin
        execute v_txt;
        raise exception 'FAIL D7: % was accepted', v_txt;
      exception when sqlstate 'CMA02' then null;
      end;
    end loop;
    foreach v_txt in array array[
      'select cma.send_message(''x'', '''', ''normal'', ''{"everyone": true, "teams": ["verify-nl"]}'')',
      'select cma.send_message(''x'', '''', ''normal'', ''{"everybody": true}'')',
      'select cma.send_message(''x'', '''', ''normal'', ''{}'')',
      'select cma.send_message('' '', '''', ''normal'', ''{"everyone": true}'')',
      'select cma.send_message(''x'', repeat(''b'', 501), ''normal'', ''{"everyone": true}'')',
      'select cma.send_message(''x'', '''', ''loud'', ''{"everyone": true}'')',
      'select cma.send_message(''x'', '''', ''normal'', ''{"everyone": false}'')',
      'select cma.send_message(''x'', '''', ''normal'', ''{"everyone": true, "onlyClockedIn": "yes"}'')',
      'select cma.send_message(''x'', '''', ''normal'', ''{"language": {"skill": "verify-dutch", "minLevel": 12}}'')',
      'select cma.send_message(''x'', '''', ''normal'', ''{"users": ["not-a-uuid"]}'')',
      format('select cma.send_message(''x'', '''', ''normal'', ''{"users": ["%s"], "onlyClockedIn": true}'')', v_a3)
    ] loop
      begin
        execute v_txt;
        raise exception 'FAIL D7: % was accepted', v_txt;
      exception when sqlstate 'CMA04' then null;
      end;
    end loop;

    -- D8. an announcement: the sender, no rule, no reference, the target as asked, its urgency
    v_m := cma.send_message(' Team meeting ', 'At 15:00 in the usual room', 'urgent', '{"teams": ["verify-nl"]}');
    select * into v_msg from cma.message where id = v_m;
    if v_msg.kind <> 'announcement' or v_msg.sender_user_id <> v_sup or v_msg.rule_id is not null or v_msg.ref_id is not null
       or v_msg.ref_url is not null or v_msg.title <> 'Team meeting' or v_msg.urgency <> 'urgent'
       or v_msg.target <> '{"teams": ["verify-nl"]}'::jsonb then
      raise exception 'FAIL D8: the announcement reads %', to_jsonb(v_msg);
    end if;

    -- D9. stats: a1 polls, reads and acknowledges the announcement, a3 only polls; the supervisor and
    --     the analyst read the stats, an agent cannot; the range is bounded
    perform set_config('app.user_id', v_a1::text, true);
    perform cma.my_messages();
    perform cma.acknowledge_message(v_m);
    perform set_config('app.user_id', v_a3::text, true);
    perform cma.my_messages();
    perform set_config('app.user_id', v_sup::text, true);
    select * into v_stats from cma.message_stats(current_date - 1, current_date + 1) s where s.message_id = v_m;
    if v_stats.recipients <> 2 or v_stats.delivered <> 2 or v_stats.read <> 1 or v_stats.acknowledged <> 1
       or v_stats.median_seconds_to_read <> 0 or v_stats.kind <> 'announcement' or v_stats.sender_user_id <> v_sup then
      raise exception 'FAIL D9: stats %', to_jsonb(v_stats);
    end if;
    if (select count(*) from cma.message_stats(current_date - 1, current_date + 1)) <> 10 then
      raise exception 'FAIL D9: % messages in the stats instead of 10', (select count(*) from cma.message_stats(current_date - 1, current_date + 1));
    end if;
    perform set_config('app.user_id', v_analyst::text, true);
    perform cma.message_stats(current_date, current_date);
    begin
      perform cma.message_stats(current_date - 92, current_date);
      raise exception 'FAIL D9: 93 days were accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    begin
      perform cma.message_stats(current_date, current_date - 1);
      raise exception 'FAIL D9: a reversed range was accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    perform set_config('app.user_id', v_a1::text, true);
    begin
      perform cma.message_stats(current_date, current_date);
      raise exception 'FAIL D9: an agent read the stats';
    exception when sqlstate 'CMA06' then null;
    end;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- E. Permissions and tenant isolation (throwaway tenants, rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_t1       uuid;
  v_t2       uuid;
  v_admin    uuid;
  v_agent    uuid;
  v_sup      uuid;
  v_ing1     uuid;
  v_admin2   uuid;
  v_agent2   uuid;
  v_sup2     uuid;
  v_ing2     uuid;
  v_c1       uuid;
  v_rule     uuid;
  v_m        uuid;
  v_n        int;
  v_t        text;
  v_txt      text;
  v_ago5     text := to_char((now() - interval '5 minutes') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"');
begin
  begin
    v_t1 := cma.create_tenant('verify-0008-one', 'Verify 0008 one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008-two', 'Verify 0008 two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent@example.invalid', 'agent') returning id into v_agent;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-sup@example.invalid', 'sup') returning id into v_sup;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin@example.invalid', 'admin two') returning id into v_admin2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-agent@example.invalid', 'agent two') returning id into v_agent2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-sup@example.invalid', 'sup two') returning id into v_sup2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select x.tid, x.uid, ar.id
    from (values (v_t1, v_admin, 'admin'), (v_t1, v_agent, 'agent'), (v_t1, v_sup, 'supervisor'),
                 (v_t2, v_admin2, 'admin'), (v_t2, v_agent2, 'agent'), (v_t2, v_sup2, 'supervisor')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    select x.user_id into v_ing2 from cma.app_user_external_id x where x.tenant_id = v_t2 and x.system = 'ingest';

    -- tenant one: a market without a language skill, a rule, a deal, its alert to the agent
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_agent::text, true);
    perform cma.open_workday(now());
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP');
    select c.connection_id into v_c1 from cma.upsert_connection('verify', 'Verify CRM', 'verify-portal-1', null, null) c;
    v_rule := cma.upsert_message_rule('New deal', 'deal', '{}'::text[], 'leads.accept', true, true, 'leads.manage', 'normal');
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_records(v_c1, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd1', 'market', 'GB', 'createdAt', v_ago5)));
    perform cma.ingest_record_alerts(v_c1, 'deal', array['d1']);
    select id into v_m from cma.message where ref_id = 'd1';
    if v_m is null or (select count(*) from cma.message_delivery where message_id = v_m and user_id = v_agent) <> 1 or v_provoke then
      raise exception 'FAIL E1: the alert for tenant one''s agent is missing';
    end if;

    -- E1. the Ingest user cannot configure, send or read; a configuring person cannot raise alerts
    foreach v_txt in array array[
      'select cma.upsert_message_rule(''x'', ''deal'', ''{}'', ''leads.accept'', true, true, null, ''normal'')',
      format('select cma.set_message_rule_enabled(%L, false)', v_rule),
      'select cma.send_message(''x'', '''', ''normal'', ''{"everyone": true}'')',
      'select cma.message_stats(current_date, current_date)'
    ] loop
      begin
        execute v_txt;
        raise exception 'FAIL E1: the Ingest user ran %', v_txt;
      exception when sqlstate 'CMA06' then null;
      end;
    end loop;
    begin
      perform cma.my_messages();
      raise exception 'FAIL E1: the Ingest user read messages';
    exception when sqlstate 'CMA01' then null;
    end;
    perform set_config('app.user_id', v_admin::text, true);
    begin
      perform cma.ingest_record_alerts(v_c1, 'deal', array['d1']);
      raise exception 'FAIL E1: a configuring person raised alerts';
    exception when sqlstate 'CMA06' then null;
    end;

    -- E2. tenant two sees nothing of tenant one and cannot act on it
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_agent2::text, true);
    foreach v_t in array array['message_rule', 'message', 'message_delivery'] loop
      execute format('select count(*) from cma.%I', v_t) into v_n;
      if v_n <> 0 then
        raise exception 'FAIL E2: tenant two sees % row(s) of tenant one in cma.%', v_n, v_t;
      end if;
    end loop;
    if (select count(*) from cma.my_messages()) <> 0 or cma.my_unread_count() <> 0 or cma.mark_messages_read(array[v_m]) <> 0 then
      raise exception 'FAIL E2: tenant two''s agent reached tenant one''s message';
    end if;
    begin
      perform cma.acknowledge_message(v_m);
      raise exception 'FAIL E2: tenant two acknowledged tenant one''s message';
    exception when sqlstate 'CMA02' then null;
    end;
    perform set_config('app.user_id', v_agent::text, true);
    begin
      perform cma.my_messages();
      raise exception 'FAIL E2: tenant one''s agent read in tenant two';
    exception when sqlstate 'CMA01' then null;
    end;
    perform set_config('app.user_id', v_ing2::text, true);
    begin
      perform cma.ingest_record_alerts(v_c1, 'deal', array['d1']);
      raise exception 'FAIL E2: tenant two raised alerts on tenant one''s connection';
    exception when sqlstate 'CMA02' then null;
    end;
    perform set_config('app.user_id', v_admin2::text, true);
    begin
      perform cma.set_message_rule_enabled(v_rule, false);
      raise exception 'FAIL E2: tenant two disabled tenant one''s rule';
    exception when sqlstate 'CMA02' then null;
    end;
    perform set_config('app.user_id', v_sup2::text, true);
    begin
      perform cma.send_message('x', '', 'normal', jsonb_build_object('users', jsonb_build_array(v_agent)));
      raise exception 'FAIL E2: tenant two sent to tenant one''s agent';
    exception when sqlstate 'CMA02' then null;
    end;
    if (select string_agg(x.message_id::text, ',') from cma.message_stats(current_date - 1, current_date + 1) x) is not null then
      raise exception 'FAIL E2: tenant two''s stats show tenant one''s messages';
    end if;

    -- E3. no deletes, whoever asks
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    foreach v_t in array array['message_delivery', 'message', 'message_rule'] loop
      begin
        execute format('delete from cma.%I', v_t);
        raise exception 'FAIL E3: the application deleted from cma.%', v_t;
      exception when insufficient_privilege then null;
      end;
    end loop;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- Verdict: per tenant, the rules and what has been sent so far
select t.slug as tenant,
       (select count(*) from cma.message_rule r where r.tenant_id = t.id) as rules,
       (select count(*) from cma.message_rule r where r.tenant_id = t.id and r.enabled) as rules_enabled,
       (select count(*) from cma.message m where m.tenant_id = t.id) as messages,
       (select count(*) from cma.message_delivery d where d.tenant_id = t.id) as deliveries,
       (select count(*) from cma.message_delivery d where d.tenant_id = t.id and d.read_at is null) as unread,
       case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS' else 'PASS' end as verdict
from cma.tenant t
where t.status = 'active'
order by t.slug;
