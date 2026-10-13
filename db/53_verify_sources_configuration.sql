-- =============================================================================================
-- 53_verify_sources_configuration.sql: verifies addition 0008e, the configuration reads for
-- sources, markets and alert rules, the connection kind and linked accounts on People
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure
-- and privileges; block B works on two throwaway tenants inside a subtransaction that is always
-- rolled back. Universal otherwise: nothing of the seed is used, adapters and systems are invented
-- data values. Every check writes one row, PASS or FAIL, and the last result lists them with the
-- verdict, because Cloud SQL Studio shows no notices. Run as your own IAM login in dev, after
-- 52_sources_configuration.sql; then 33_verify_intake_core.sql and 31_verify_ingest_crm_records.sql
-- again (unchanged).
--   A  structure and privileges: the migration row, the kind column and its check, the reader view
--      with the kind and without the key or secret names, the functions and who may execute them,
--      every existing connection with exactly one implied kind carrying it
--   B  behaviour: the kind (unset on a new connection, set, refused against held rows, refused when
--      unknown, refused for an agent); sources with kinds, held kinds, settings and catalog sizes;
--      catalogs with their configuration and the newest record id; markets with aliases, office
--      hours and holidays; alert rules of both triggers with their alerts; the linked-account
--      systems from the connections and from held ids; the linked accounts in the directory's
--      scope; people's ids by a manager for an agent, refused for a managing person, an id held by
--      another person refused, an agent refused; the other tenant sees nothing of the first; the
--      reserved names (add_person refuses a login system ending in _owner or _user, and
--      find_tenants_for_identity never matches a linked id); upsert_connection refuses an adapter
--      name with an underscore
-- Provoke: set provoke below to true; A1, B1 and B8 must then read FAIL, and the verdict says
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
select set_config('verify.provoke', 'false', false);   -- 'true' to make A1, B1 and B8 fail

-- Dev only: a verifier that writes refuses a database without the dev seed. The flag is kept for the
-- session, so every block below stops at once and the verdict says REFUSED, also where the client
-- carries on after the error
select set_config('verify.is_dev', (exists (select 1 from cma.app_user u join cma.tenant t on t.id = u.tenant_id
                                            where u.email = 'agent.two@example.com' and u.status = 'active'))::text, false) as is_dev;
do $$
begin
  if not current_setting('verify.is_dev')::boolean then
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 53 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0008e;
create temp table verify_0008e (ord int, check_name text, result text, detail text);

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_fn      text;
  v_bad     text := '';
  v_cols    text;
  v_n       integer;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  -- A1. the addition is recorded
  insert into verify_0008e values (1, 'A1 addition 0008e recorded',
    case when exists (select 1 from cma.schema_migration where version = '0008e') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the kind column with its check; the reader view carries it, never the key or a secret name
  select string_agg(column_name, ', ' order by ordinal_position) into v_cols
  from information_schema.columns where table_schema = 'cma_read' and table_name = 'integration_connection';
  insert into verify_0008e values (2, 'A2 kind column, check and reader view',
    case when exists (select 1 from information_schema.columns where table_schema = 'cma' and table_name = 'integration_connection' and column_name = 'kind')
              and exists (select 1 from pg_constraint where conrelid = 'cma.integration_connection'::regclass
                          and conname = 'integration_connection_kind_check'
                          and pg_get_constraintdef(oid) like '%crm%telephony%commerce%automation%')
              and v_cols like '%kind%' and v_cols not like '%key%' and v_cols not like '%secret%'
         then 'PASS' else 'FAIL' end, coalesce(v_cols, 'no view'));

  -- A3. the functions exist and are executable by the application only
  foreach v_fn in array array['cma.connection_held_kinds_of(uuid,uuid)', 'cma.set_connection_kind(uuid,text)', 'cma.sources()',
                              'cma.connection_catalogs(uuid)', 'cma.markets_all()', 'cma.business_hours_all()',
                              'cma.business_holidays_all()', 'cma.message_rules()', 'cma.linked_account_systems()',
                              'cma.linked_accounts()', 'cma.set_user_external_id(uuid,text,text)',
                              'cma.remove_user_external_id(uuid,text)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' is missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or exists (select 1 from information_schema.routine_privileges where specific_schema = 'cma' and grantee = 'PUBLIC'
                     and routine_name = split_part(split_part(v_fn, '.', 2), '(', 1)) then
      v_bad := v_bad || v_fn || ' is not the application''s only; ';
    end if;
  end loop;
  insert into verify_0008e values (3, 'A3 twelve functions, executable by cma_app only',
    case when v_bad = '' then 'PASS' else 'FAIL' end, v_bad);

  -- A4. every existing connection whose rows imply exactly one kind carries it
  select count(*) into v_n from cma.integration_connection c
  where c.kind is null and cardinality(cma.connection_held_kinds_of(c.tenant_id, c.id)) = 1;
  insert into verify_0008e values (4, 'A4 existing connections carry the kind their rows imply',
    case when v_n = 0 then 'PASS' else 'FAIL' end, format('%s connection(s) without the kind their rows imply', v_n));
end
$$;

-- B. Behaviour on two throwaway tenants (rolled back)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_rows    text[] := '{}';
  v_t1      uuid;
  v_t2      uuid;
  v_admin   uuid;
  v_mgr     uuid;
  v_mgr2    uuid;
  v_a1      uuid;
  v_a2      uuid;
  v_ing1    uuid;
  v_admin2  uuid;
  v_crm     uuid;
  v_tel     uuid;
  v_auto    uuid;
  v_rule1   uuid;
  v_rule2   uuid;
  v_txt     text;
  v_ok      boolean;
  v_detail  text;
  v_j       jsonb;
  v_n       integer;
  v_ago5    text := to_char((now() - interval '5 minutes') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"');
  v_ago60   text := to_char((now() - interval '60 minutes') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"');

begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    v_t1 := cma.create_tenant('verify-0008e-one', 'Verify 0008e one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008e-two', 'Verify 0008e two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-mgr@example.invalid', 'mgr') returning id into v_mgr;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-mgr2@example.invalid', 'mgr2') returning id into v_mgr2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-a1@example.invalid', 'a1') returning id into v_a1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-a2@example.invalid', 'a2') returning id into v_a2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin2') returning id into v_admin2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin, 'admin'), (v_t1, v_mgr, 'manager'), (v_t1, v_mgr2, 'manager'), (v_t1, v_a1, 'agent'),
                 (v_t1, v_a2, 'agent'), (v_t2, v_admin2, 'admin')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    -- an id someone already holds in a system no connection names (a retired connection's)
    insert into cma.app_user_external_id (tenant_id, user_id, system, external_id) values (v_t1, v_mgr2, 'oldcrm_owner', 'old-1');

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP', null, null, 20);
    select c.connection_id into v_crm from cma.upsert_connection('verifycrm', 'Verify customer records', 'portal-1', 'verify-signing', 'verify-token') c;
    select c.connection_id into v_tel from cma.upsert_connection('verifytel', 'Verify phones', 'company-1', null, null) c;
    select c.connection_id into v_auto from cma.upsert_connection('verifyauto', 'Verify automation', 'portal-1', null, null) c;
    perform cma.set_connection_settings(v_crm, '{"app_host": "app.example.com", "record_url_deal": "https://{app_host}/r/{account}/deal/{id}"}');

    -- B1. the kind: unset on a new connection; set; refused against held rows, unknown, for an agent
    v_ok := (select kind from cma.integration_connection where id = v_crm) is null;
    perform cma.set_form(v_crm, 'f-quote', true, null, null, null);        -- the crm connection now holds crm rows
    v_n := 0;
    begin perform cma.set_connection_kind(v_crm, 'telephony'); exception when sqlstate 'CMA03' then v_n := v_n + 1; end;
    begin perform cma.set_connection_kind(v_crm, 'phone'); exception when sqlstate 'CMA04' then v_n := v_n + 1; end;
    perform cma.set_connection_kind(v_crm, 'crm');
    perform cma.set_connection_kind(v_auto, 'automation');
    perform cma.set_connection_kind(v_tel, 'telephony');
    perform set_config('app.user_id', v_a1::text, true);
    begin perform cma.set_connection_kind(v_auto, 'crm'); exception when sqlstate 'CMA06' then v_n := v_n + 1; end;
    perform set_config('app.user_id', v_admin::text, true);
    v_ok := v_ok and v_n = 3 and (select kind from cma.integration_connection where id = v_crm) = 'crm'
            and (select kind from cma.integration_connection where id = v_auto) = 'automation';
    v_rows := v_rows || array['11', 'B1 kind: unset, set, refused against held rows, unknown or for an agent',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s of 3 refusals', v_n) || case when v_provoke then ' (provoked)' else '' end];

    -- catalogs: an outcome, a second form, lines and tags, two deals of which the newer is the sample
    perform cma.set_form(v_crm, 'f-cancel', false, null, null, null);
    perform cma.set_form(v_crm, 'f-quote', true, 'quote', 'NL', array['product']);
    perform cma.set_call_outcome(v_crm, 'o-reached', true);
    perform cma.set_call_outcome(v_crm, 'o-voicemail', false);
    perform cma.set_telephony_number(v_tel, 'line-1', 'NL', true);
    perform cma.set_telephony_tag(v_tel, 'tag-1', false);
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_pipelines(v_crm, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'pipelineId', 'p-sales', 'label', 'Sales', 'stages', jsonb_build_array(
        jsonb_build_object('stageId', 's-open', 'label', 'Open', 'order', 1, 'isClosed', false)))));
    perform cma.ingest_upsert_records(v_crm, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd-old', 'pipelineId', 'p-sales', 'stageId', 's-open', 'createdAt', v_ago60, 'updatedAt', v_ago60),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd-new', 'pipelineId', 'p-sales', 'stageId', 's-open', 'createdAt', v_ago5, 'updatedAt', v_ago5)));
    perform set_config('app.user_id', v_admin::text, true);

    -- B2. sources: the three connections with kind, held kinds, settings, secret names and catalog sizes; a manager refused
    select string_agg(format('%s:%s:%s:p%s:f%s:o%s:l%s:t%s', s.adapter, coalesce(s.kind, '-'), array_to_string(s.held_kinds, '+'),
                             s.pipelines, s.forms, s.call_outcomes, s.lines, s.tags), ' ' order by s.adapter)
    into v_detail from cma.sources() s;
    v_ok := v_detail = 'verifyauto:automation::p0:f0:o0:l0:t0 verifycrm:crm:crm:p1:f2:o2:l0:t0 verifytel:telephony:telephony:p0:f0:o0:l1:t1'
            and (select s.settings ->> 'app_host' = 'app.example.com' and s.signing_secret_name = 'verify-signing'
                 from cma.sources() s where s.connection_id = v_crm);
    perform set_config('app.user_id', v_mgr::text, true);
    begin perform cma.sources(); v_ok := false; exception when sqlstate 'CMA06' then null; end;
    perform set_config('app.user_id', v_admin::text, true);
    v_rows := v_rows || array['12', 'B2 sources with kinds, settings and catalog sizes; a manager refused',
      case when v_ok then 'PASS' else 'FAIL' end, coalesce(v_detail, 'no sources')];

    -- B3. catalogs with their configuration and the newest record id; an unknown connection refused
    v_j := cma.connection_catalogs(v_crm);
    v_ok := (select string_agg(format('%s=%s/%s/%s/%s', f ->> 'formId', f ->> 'isCounted', coalesce(f ->> 'leadSource', '-'),
                                      coalesce(f ->> 'market', '-'), f -> 'keptFields'), ' ' order by f ->> 'formId')
             from jsonb_array_elements(v_j -> 'forms') f) = 'f-cancel=false/-/-/[] f-quote=true/quote/NL/["product"]'
            and (select string_agg(format('%s=%s', o ->> 'outcomeRef', o ->> 'isConnected'), ' ' order by o ->> 'outcomeRef')
                 from jsonb_array_elements(v_j -> 'callOutcomes') o) = 'o-reached=true o-voicemail=false'
            and v_j -> 'sampleIds' ->> 'deal' = 'd-new'
            and jsonb_array_length(v_j -> 'lines') = 0;
    v_j := cma.connection_catalogs(v_tel);
    v_ok := v_ok and (v_j -> 'lines' -> 0 ->> 'lineRef') = 'line-1' and (v_j -> 'lines' -> 0 ->> 'market') = 'NL'
            and (v_j -> 'tags' -> 0 ->> 'isCounted') = 'false' and v_j -> 'sampleIds' = '{}'::jsonb;
    begin perform cma.connection_catalogs('00000000-0000-7000-8000-00000000dead'); v_ok := false; exception when sqlstate 'CMA02' then null; end;
    v_rows := v_rows || array['13', 'B3 catalogs with configuration and the newest record id',
      case when v_ok then 'PASS' else 'FAIL' end, ''];

    -- B4. markets with their aliases, office hours as text and holidays; an agent refused
    perform cma.set_market_alias('uk', 'GB');
    perform cma.set_market_alias('United Kingdom', 'GB');
    perform cma.set_business_hours('*', 1::smallint, '09:00-17:00');
    perform cma.set_business_hours('GB', 1::smallint, '09:00-12:30, 13:00-24:00');
    perform cma.set_business_holiday('NL', date '2026-12-25', 'Christmas');
    select string_agg(m.code || '[' || array_to_string(m.aliases, '|') || ']', ' ' order by m.sort_order, m.code) into v_detail from cma.markets_all() m;
    v_ok := v_detail = 'GB[uk|united kingdom] NL[]'
            and (select string_agg(h.market || h.weekday || '=' || h.hours, ' ') from cma.business_hours_all() h) = '*1=09:00-17:00 GB1=09:00-12:30,13:00-24:00'
            and (select string_agg(b.market || ':' || b.day || ':' || b.name, ' ') from cma.business_holidays_all() b) = 'NL:2026-12-25:Christmas';
    perform set_config('app.user_id', v_a1::text, true);
    begin perform cma.markets_all(); v_ok := false; exception when sqlstate 'CMA06' then null; end;
    perform set_config('app.user_id', v_admin::text, true);
    v_rows := v_rows || array['14', 'B4 markets with aliases, office hours and holidays; an agent refused',
      case when v_ok then 'PASS' else 'FAIL' end, coalesce(v_detail, 'no markets')];

    -- B5. alert rules of both triggers with their alerts in the last 30 days
    v_rule1 := cma.upsert_message_rule('New deal', 'deal', '{}', 'leads.accept', true, true, 'leads.manage', 'normal');
    v_rule2 := cma.upsert_assignment_rule('Assigned deal', 'deal', array['p-sales'], 'urgent', 30);
    perform cma.set_message_rule_enabled(v_rule1, false);
    perform cma.upsert_message_rule('New deal', 'deal', '{}', 'leads.accept', true, true, 'leads.manage', 'normal');
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_records(v_crm, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd-new', 'pipelineId', 'p-sales', 'stageId', 's-open', 'ownerRef', 'o-1', 'createdAt', v_ago5, 'updatedAt', v_ago5)));
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_user_external_id(v_a1, 'verifycrm_owner', 'o-1');
    perform set_config('app.user_id', v_ing1::text, true);
    v_n := cma.ingest_assignment_alerts(v_crm, 'deal', array['d-new']);
    perform set_config('app.user_id', v_admin::text, true);
    select string_agg(format('%s:%s:%s:%s:%s:%s:%s', r.name, r.trigger, r.urgency, r.enabled, array_to_string(r.pipeline_ids, '+'),
                             coalesce(r.max_age_minutes::text, '-'), r.alerts_30d), ' ' order by r.name)
    into v_detail from cma.message_rules() r;
    v_ok := v_n = 1 and v_detail = 'Assigned deal:record_assigned:urgent:t:p-sales:30:1 New deal:record_created:normal:f::-:0'
            and (select r.last_alert_at is not null and r.fallback_permission is null from cma.message_rules() r where r.rule_id = v_rule2)
            and (select r.last_alert_at is null and r.audience_permission = 'leads.accept' and r.fallback_permission = 'leads.manage'
                        and r.match_language and r.only_clocked_in
                 from cma.message_rules() r where r.rule_id = v_rule1);
    perform set_config('app.user_id', v_mgr::text, true);
    begin perform cma.message_rules(); v_ok := false; exception when sqlstate 'CMA06' then null; end;
    perform set_config('app.user_id', v_admin::text, true);
    v_rows := v_rows || array['15', 'B5 alert rules of both triggers with their alerts; a manager refused',
      case when v_ok then 'PASS' else 'FAIL' end, coalesce(v_detail, 'no rules')];

    -- B6. the linked-account systems: from the crm and telephony connections and from a held id
    perform set_config('app.user_id', v_mgr::text, true);
    select string_agg(format('%s:%s:%s:%s', s.system, s.role, array_to_string(s.connections, '+'), s.is_active), ' ' order by s.system)
    into v_detail from cma.linked_account_systems() s;
    v_ok := v_detail = 'oldcrm_owner:owner::f verifycrm_owner:owner:Verify customer records:t verifytel_user:user:Verify phones:t';
    perform set_config('app.user_id', v_a1::text, true);
    begin perform cma.linked_account_systems(); v_ok := false; exception when sqlstate 'CMA06' then null; end;
    v_rows := v_rows || array['16', 'B6 linked-account systems from connections and held ids; an agent refused',
      case when v_ok then 'PASS' else 'FAIL' end, coalesce(v_detail, 'no systems')];

    -- B7. the linked accounts in the directory's scope: the admin sees everyone's, a manager not a managing person's
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_user_external_id(v_mgr, 'verifycrm_owner', 'o-mgr');
    select count(*) into v_n from cma.linked_accounts();
    v_ok := v_n = 3;   -- a1's, mgr's and mgr2's
    perform set_config('app.user_id', v_mgr::text, true);
    select string_agg(x.system || '=' || x.external_id, ' ' order by x.system, x.external_id) into v_detail from cma.linked_accounts() x;
    v_ok := v_ok and v_detail = 'verifycrm_owner=o-1 verifycrm_owner=o-mgr';   -- a1's and the manager's own, not mgr2's
    v_rows := v_rows || array['17', 'B7 linked accounts in the directory''s scope',
      case when v_ok then 'PASS' else 'FAIL' end, format('admin sees %s; manager sees %s', v_n, coalesce(v_detail, 'nothing'))];

    -- B8. people's ids by the People rule: a manager links and unlinks an agent; a managing person, an id
    --     held by another person, an agent as the actor and a sign-in system are refused
    v_n := 0;
    perform cma.set_user_external_id(v_a2, 'verifytel_user', 'u-2');
    perform cma.set_user_external_id(v_a2, 'verifytel_user', 'u-3');
    v_ok := (select external_id from cma.app_user_external_id where user_id = v_a2 and system = 'verifytel_user') = 'u-3';
    begin perform cma.set_user_external_id(v_mgr2, 'verifycrm_owner', 'o-9'); exception when sqlstate 'CMA06' then v_n := v_n + 1; end;
    begin perform cma.remove_user_external_id(v_mgr2, 'oldcrm_owner'); exception when sqlstate 'CMA06' then v_n := v_n + 1; end;
    begin perform cma.set_user_external_id(v_a2, 'verifycrm_owner', 'o-1'); exception when sqlstate 'CMA03' then v_n := v_n + 1; end;
    begin perform cma.set_user_external_id(v_a2, 'google', '123'); exception when sqlstate 'CMA04' then v_n := v_n + 1; end;
    perform cma.remove_user_external_id(v_a2, 'verifytel_user');
    v_ok := v_ok and not exists (select 1 from cma.app_user_external_id where user_id = v_a2 and system = 'verifytel_user');
    perform set_config('app.user_id', v_a1::text, true);
    begin perform cma.set_user_external_id(v_a2, 'verifytel_user', 'u-4'); exception when sqlstate 'CMA06' then v_n := v_n + 1; end;
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_user_external_id(v_mgr2, 'verifycrm_owner', 'o-9');   -- the admin may
    v_ok := v_ok and v_n = 5 and exists (select 1 from cma.app_user_external_id where user_id = v_mgr2 and external_id = 'o-9');
    v_rows := v_rows || array['18', 'B8 people''s ids by the People rule',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s of 5 refusals', v_n) || case when v_provoke then ' (provoked)' else '' end];

    -- B9. the other tenant sees nothing of the first, and its connection is not found from the first
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    v_ok := not exists (select 1 from cma.sources()) and not exists (select 1 from cma.markets_all())
            and not exists (select 1 from cma.message_rules()) and not exists (select 1 from cma.linked_accounts())
            and not exists (select 1 from cma.linked_account_systems()) and not exists (select 1 from cma.business_hours_all());
    begin perform cma.connection_catalogs(v_crm); v_ok := false; exception when sqlstate 'CMA02' then null; end;
    begin perform cma.set_connection_kind(v_auto, 'crm'); v_ok := false; exception when sqlstate 'CMA02' then null; end;
    v_rows := v_rows || array['19', 'B9 the other tenant sees nothing of the first',
      case when v_ok then 'PASS' else 'FAIL' end, ''];

    -- B10. add_person refuses a login system ending in _owner or _user (a linked account's name),
    --      after the form check and before the employer is looked up
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    v_n := 0;
    v_detail := '';
    begin
      perform cma.add_person('verify-new@example.invalid', 'new', 'no-such-employer', 'agent', 'verifyx_owner', 'l-1');
    exception
      when sqlstate 'CMA04' then
        if starts_with(sqlerrm, 'a login system cannot end in _owner or _user') then v_n := v_n + 1; end if;
        v_detail := sqlerrm;
      when others then v_detail := sqlstate || ' ' || sqlerrm;
    end;
    begin
      perform cma.add_person('verify-new@example.invalid', 'new', 'no-such-employer', 'agent', 'verifyx_user', 'l-1');
    exception
      when sqlstate 'CMA04' then
        if starts_with(sqlerrm, 'a login system cannot end in _owner or _user') then v_n := v_n + 1; end if;
      when others then null;
    end;
    begin   -- a plain login system passes both login-system checks and stops at the unknown employer
      perform cma.add_person('verify-new@example.invalid', 'new', 'no-such-employer', 'agent', 'verifyx', 'l-1');
    exception
      when sqlstate 'CMA02' then v_n := v_n + 1;
      when others then null;
    end;
    v_rows := v_rows || array['20', 'B10 add_person refuses a login system ending in _owner or _user',
      case when v_n = 3 then 'PASS' else 'FAIL' end, format('%s of 3; %s', v_n, v_detail)];

    -- B11. a linked id never signs anyone in: find_tenants_for_identity does not match it, while the
    --      tenant's Ingest user is still found by its sign-in id
    perform cma.set_user_external_id(v_a2, 'verifycrm_owner', 'o1');
    select count(*) into v_n from cma.find_tenants_for_identity('verifycrm_owner', 'o1');
    v_ok := v_n = 0
            and exists (select 1 from cma.app_user_external_id where user_id = v_a2 and system = 'verifycrm_owner' and external_id = 'o1')
            and exists (select 1 from cma.find_tenants_for_identity('ingest', 'ingest') f where f.tenant_id = v_t1);
    v_rows := v_rows || array['21', 'B11 find_tenants_for_identity never matches a linked id',
      case when v_ok then 'PASS' else 'FAIL' end, format('%s row(s) for verifycrm_owner/o1', v_n)];

    -- B12. upsert_connection refuses an adapter name that is not lower-case letters and digits only
    v_ok := false;
    v_detail := 'not refused';
    begin
      perform cma.upsert_connection('verify_crm', 'Verify underscore', 'portal-9', null, null);
    exception when sqlstate 'CMA04' then
      v_ok := sqlerrm = 'an adapter name is lower-case letters and digits only';
      v_detail := sqlerrm;
    end;
    v_ok := v_ok and not exists (select 1 from cma.integration_connection where adapter = 'verify_crm');
    v_rows := v_rows || array['22', 'B12 upsert_connection refuses an adapter with an underscore',
      case when v_ok then 'PASS' else 'FAIL' end, v_detail];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['29', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008e (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008e values (29, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008e
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED: not dev'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008e where result = 'PASS') = 16
                       and not exists (select 1 from verify_0008e where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0008e where result = 'PASS'),
                                        (select count(*) from verify_0008e where result <> 'PASS'))) x
order by ord;
reset role;
