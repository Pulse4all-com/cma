-- =============================================================================================
-- 85_verify_first_orders.sql: verifies addition 0008u, first orders: self-service or call center
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure
-- and privileges; block B works on two throwaway tenants inside a subtransaction that is always
-- rolled back. Universal otherwise: nothing of the seed is used; adapters, pipelines, stages, deals,
-- contacts, calls, emails, owners, store customers and orders are invented data values, and no row
-- carries a name, an address or a phone number (a phone exists only as an invented 64-character hash).
-- Every check writes one row, PASS or FAIL, and the last result lists them with the verdict, because
-- Cloud SQL Studio shows no notices. Run as your own IAM login in dev, after 84_first_orders.sql; then
-- 41, 69 and 83 again.
--   A  structure and privileges: the addition row after 0008t; the new columns with their checks; the
--      reader views with the new columns last and the first-orders view's exact columns; no column or
--      argument named like a name, an address, an email or a phone; the five settings with their
--      defaults; every function the application's only and in the caller's rights, the readers'
--      function definer, the owner's, pinned and the readers' only
--   B  behaviour. Tenant one (Europe/Amsterdam; NL in Amsterdam, GB in London; intake from 1 June
--      2026) holds a CRM connection (a self-serve order pipeline with a won and a lost stage, a sales
--      lead pipeline, a ticket pipeline; owners 101 Anna and 103 Bram linked, 102 not), a telephony
--      connection (user u1 is Anna) and a shop connection, and the order deals of the week of 5 to 11
--      October 2026 with the week before and two earlier ones: a first order with a lead deal and a
--      later email, one with a connected call, one with an agent's inbox message from an owner without a
--      person, one with an inbox copy, an automation and a bot only (a known contact), one with a call
--      from the order's phone number on another contact, one with an unconnected call, one whose contact
--      is exactly an hour old, one without a contact, a second order of a contact, a renewal, an order
--      the store counts as repeat, a lost deal, a lead deal exactly at the window's start and one at T,
--      and two orders on the previous Wednesday either side of 15:00. Tenant two holds a connection of
--      the same names, for isolation. Checked: the settings and their refusals; the stage outcomes
--      from the source, a person's choice kept and the refusals; the order pipeline switch; the
--      created_at slots and a contact's creation time; the kinds; the linked order (nearest within the
--      match window) and the amounts; every flag and the window's edges; the inbox copy, the automation
--      and the bot not a touch; the levels, the attribution and the credited person (the latest
--      assisted touch, through a telephony user too); the level order and the assisted set changed;
--      days from the first touch; the report per day, market and level; amounts per currency never
--      summed across; the previous period like for like; the history start and the phone tier's start;
--      the list capped with its link; per person refused while reports.per_person does not hold orders,
--      then by name with the not-linked row; the filters' refusals; the permissions; tenant isolation;
--      a reader scoped to one tenant
-- Amended for addition 0008zc (24 October 2026; 85 runs in dev only and never ran in prod): 0008zc takes a call's evidence
-- from its linked telephony call only (docs/definitions.md, R1): a conversation as Conversation defines it, an attempt for
-- every outbound call, a conversation included. o6's call c6, an unconnected CRM call without a telephony call before,
-- now logs an outbound telephony call nobody answered (tp6), so o6 keeps its attempt; B7 pins o2's outbound conversation as
-- an attempt too (010000 becomes 010010). Every other check pins what it pinned before.
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
-- session, so every block below stops at once and the verdict says REFUSED, also where the client
-- carries on after the error
select set_config('verify.is_dev', (exists (select 1 from cma.app_user u join cma.tenant t on t.id = u.tenant_id
                                            where u.email = 'agent.two@example.com' and u.status = 'active'))::text, false) as is_dev;
do $$
begin
  if not current_setting('verify.is_dev')::boolean then
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 85 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0008u;
create temp table verify_0008u (ord int, check_name text, result text, detail text);

-- The error code a statement raises, or 'ok'
create or replace function pg_temp.v0008u_code(p_sql text)
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

-- One order deal as the ingest write takes it: the self-serve pipeline, a stage, a contact (or none)
create or replace function pg_temp.v0008u_deal(p_src text, p_stage text, p_contact text, p_at timestamptz, p_market text,
                                               p_pipeline text default 'self', p_owner text default null, p_amount numeric default null)
returns jsonb
language sql immutable
as $$
  select jsonb_strip_nulls(jsonb_build_object('recordType', 'deal', 'sourceId', p_src, 'pipelineId', p_pipeline, 'stageId', p_stage,
                                              'contactId', p_contact, 'market', p_market, 'ownerRef', p_owner,
                                              'amount', p_amount, 'currency', case when p_amount is not null then 'EUR' end,
                                              'createdAt', p_at, 'updatedAt', p_at))
$$;

-- One store order of a customer
create or replace function pg_temp.v0008u_order(p_src text, p_customer text, p_at timestamptz, p_currency text, p_amount numeric,
                                                p_prior integer, p_source_name text default null, p_hash text default null)
returns jsonb
language sql immutable
as $$
  select jsonb_strip_nulls(jsonb_build_object('sourceId', p_src, 'customerId', p_customer, 'createdAt', p_at, 'updatedAt', p_at,
                                              'currency', p_currency, 'totalAmount', p_amount, 'priorOrdersCount', p_prior,
                                              'priorCountExact', true, 'sourceName', p_source_name, 'phoneHash', p_hash))
$$;

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_bad     text;
  v_fn      text;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  -- A1. the addition is recorded, after 0008t
  insert into verify_0008u values (1, 'A1 addition 0008u recorded, after 0008t',
    case when exists (select 1 from cma.schema_migration where version = '0008u')
              and exists (select 1 from cma.schema_migration where version = '0008t') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the new columns with their checks: is_order (deal pipelines only), outcome and its source, the
  --     contact's creation time, created_at among the contact fields with slots from 2
  v_bad := '';
  if (select data_type || ':' || is_nullable || ':' || column_default from information_schema.columns
      where table_schema = 'cma' and table_name = 'connection_pipeline' and column_name = 'is_order') is distinct from 'boolean:NO:false' then
    v_bad := v_bad || 'connection_pipeline.is_order; ';
  end if;
  if (select string_agg(column_name || ':' || data_type, ',' order by column_name) from information_schema.columns
      where table_schema = 'cma' and table_name = 'connection_stage' and column_name in ('outcome', 'outcome_source'))
     is distinct from 'outcome:text,outcome_source:text'
     or not exists (select 1 from pg_constraint where conname = 'connection_stage_outcome_check' and pg_get_constraintdef(oid) like '%won%lost%person%')
     or not exists (select 1 from pg_constraint where conname = 'connection_pipeline_is_order_check' and pg_get_constraintdef(oid) like '%deal%') then
    v_bad := v_bad || 'stage outcome or the order pipeline''s checks; ';
  end if;
  if (select data_type from information_schema.columns where table_schema = 'cma' and table_name = 'crm_contact'
      and column_name = 'source_created_at') is distinct from 'timestamp with time zone' then
    v_bad := v_bad || 'crm_contact.source_created_at; ';
  end if;
  if pg_get_constraintdef((select oid from pg_constraint where conrelid = 'cma.connection_field'::regclass and conname = 'connection_field_slot_check'))
       not like '%created_at%'
     or pg_get_constraintdef((select oid from pg_constraint where conrelid = 'cma.connection_field'::regclass and conname = 'connection_field_entity_field_check'))
       not like '%created_at%' then
    v_bad := v_bad || 'created_at is not among the contact fields with slots; ';
  end if;
  insert into verify_0008u values (2, 'A2 the order pipeline, the stage outcome, the contact''s creation time and their checks',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A3. the reader views: the new columns last, the earlier ones as they were; the first-orders view's
  --     exact columns
  v_bad := '';
  if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'crm_contact')
     is distinct from 'id,tenant_id,connection_id,source_system,source_id,country,language,source_updated_at,source_deleted_at,synced_at,currency,store,country_source,source_created_at' then
    v_bad := v_bad || 'cma_read.crm_contact; ';
  end if;
  if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'connection_pipeline') !~ ',refreshed_at,is_lead,is_order$'
     or (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
         where table_schema = 'cma_read' and table_name = 'connection_stage') !~ ',is_closed,status,refreshed_at,outcome,outcome_source$' then
    v_bad := v_bad || 'cma_read.connection_pipeline or connection_stage; ';
  end if;
  if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'first_orders')
     is distinct from 'tenant_id,connection_id,deal_source_id,created_at,business_date,market,kind,level,attribution,lead_deal,conversation,email,phone_match,attempt,known_contact,phone_hashed,has_order,currency,amount,days_from_first_touch,credited_user_id'
     or not has_table_privilege('cma_readonly', 'cma_read.first_orders', 'select') then
    v_bad := v_bad || 'cma_read.first_orders; ';
  end if;
  insert into verify_0008u values (3, 'A3 the reader views with the new columns last and the first-orders view',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A4. no column or argument named like a person's or a customer's name, an address, an email or a phone
  --     number (a phone exists as phone_hashed, a yes or no; display_name is a staff member's, as in 0008t)
  select string_agg(table_name || '.' || column_name, ', ') into v_bad
  from information_schema.columns
  where table_schema = 'cma_read' and table_name = 'first_orders'
    and column_name ~* '(^name$|first_name|last_name|contact_name|customer_name|address|phone_number|^phone$|number|_hash$)';
  select coalesce(v_bad || ', ', '') || coalesce(string_agg(p.proname || '.' || a, ', '), '') into v_bad
  from pg_proc p
  cross join lateral unnest(p.proargnames) a
  where p.pronamespace = 'cma'::regnamespace and p.proname like 'first\_orders%'
    and a ~* '(^name$|first_name|last_name|contact_name|customer_name|address|phone_number|^phone$|_hash$)';
  insert into verify_0008u values (4, 'A4 no name, address, email address or phone number in the view and the reads',
    case when coalesce(v_bad, '') = '' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_bad, ''));

  -- A5. the five settings with their defaults
  select string_agg(key || '=' || value_type || ':' || default_value, ' ' order by key) into v_bad
  from cma.setting where key like 'attribution.%';
  insert into verify_0008u values (5, 'A5 the five attribution settings with their defaults',
    case when v_bad = 'attribution.assisted_levels=text:lead_deal,conversation,email,phone_match attribution.known_contact_minutes=integer:60 '
                      || 'attribution.level_order=text:lead_deal,conversation,email,phone_match,attempt,known_contact '
                      || 'attribution.order_match_minutes=integer:1440 attribution.window_days=integer:90'
              and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_bad, 'missing'));

  -- A6. every function of the addition the application's only and in the caller's rights; the readers'
  --     function SECURITY DEFINER, owned by cma_owner, search path pinned, the readers' only
  v_bad := '';
  foreach v_fn in array array[
    'cma.is_attribution_levels(text,boolean)', 'cma.set_pipeline_order(uuid,text,text,boolean)',
    'cma.set_stage_outcome(uuid,text,text,text,text)', 'cma.ingest_upsert_pipelines(uuid,jsonb)', 'cma.connection_config(uuid)',
    'cma.set_connection_field(uuid,text,text,text,text,smallint)', 'cma.ingest_upsert_contacts(uuid,jsonb)',
    'cma.first_orders_of(uuid,timestamptz,timestamptz)', 'cma.first_orders_figures_of(uuid,date,date,text,text,text[],timestamptz)',
    'cma.first_orders_report_of(uuid,date,date,text,text,text,timestamptz)', 'cma.first_orders_amounts_of(uuid,date,date,text,text)',
    'cma.first_orders_per_person_of(uuid,date,date,text,text)', 'cma.first_orders_history_start_of(uuid)',
    'cma.first_orders_connected_of(uuid)', 'cma.first_orders_filters_check(text,text)', 'cma.first_orders_report(date,date,text,text,text)',
    'cma.first_orders_amounts(date,date,text,text)', 'cma.first_orders_list(date,date,text,text,integer)',
    'cma.first_orders_per_person(date,date,text,text)', 'cma.first_orders_history_start()'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or has_function_privilege('public', v_fn, 'execute')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      v_bad := v_bad || v_fn || ' not the application''s only or not in the caller''s rights; ';
    end if;
  end loop;
  v_fn := 'cma_read.first_orders_rows()';
  if to_regprocedure(v_fn) is null then
    v_bad := v_bad || v_fn || ' missing; ';
  elsif not (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
        or (select pg_get_userbyid(proowner) from pg_proc where oid = to_regprocedure(v_fn)) <> 'cma_owner'
        or not coalesce((select array_to_string(proconfig, ',') from pg_proc where oid = to_regprocedure(v_fn)) like 'search_path=%pg_temp', false)
        or not has_function_privilege('cma_readonly', v_fn, 'execute') or has_function_privilege('cma_app', v_fn, 'execute')
        or has_function_privilege('public', v_fn, 'execute') then
    v_bad := v_bad || v_fn || ' not the readers'' pinned definer function; ';
  end if;
  insert into verify_0008u values (6, 'A6 every function the application''s only and invoker; the readers'' function definer, pinned, theirs only',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);
end
$$;

-- B. Behaviour on two throwaway tenants (rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_rows     text[] := '{}';
  v_t1 uuid; v_t2 uuid;
  v_admin1 uuid; v_analyst1 uuid; v_reader1 uuid; v_super1 uuid; v_agent1 uuid; v_anna uuid; v_bram uuid; v_ing1 uuid;
  v_admin2 uuid; v_analyst2 uuid; v_ing2 uuid;
  v_crm uuid; v_tel uuid; v_shop uuid; v_crm2 uuid;
  v_role uuid;
  v_txt text; v_txt2 text; v_detail text;
  v_n integer;
  v_j jsonb;
  h2 text := repeat('2', 64);   -- the other party of o2's call
  h5 text := repeat('5', 64);   -- o5's order phone
  h6 text := repeat('6', 64);   -- the other party of o6's call
  -- the week of Monday 5 October 2026 (CEST, UTC+2; BST, UTC+1); T of each order deal
  t1  timestamptz := '2026-10-05 10:00:00+00';
  t2  timestamptz := '2026-10-06 09:00:00+00';
  t3  timestamptz := '2026-10-07 12:00:00+00';
  t4  timestamptz := '2026-10-08 12:00:00+00';
  t5  timestamptz := '2026-10-08 14:00:00+00';
  t6  timestamptz := '2026-10-09 09:00:00+00';
  t7  timestamptz := '2026-10-09 15:00:00+00';
  t8  timestamptz := '2026-10-10 10:00:00+00';
  t9  timestamptz := '2026-10-10 12:00:00+00';
  t10 timestamptz := '2026-10-11 09:00:00+00';
  t11 timestamptz := '2026-10-11 10:00:00+00';
  t12 timestamptz := '2026-10-07 10:00:00+00';
  t13 timestamptz := '2026-10-06 15:00:00+00';
  t14 timestamptz := '2026-10-07 15:00:00+00';
  t16 timestamptz := '2026-09-30 10:00:00+00';   -- Wednesday 30 September, 12:00 in Amsterdam
  t18 timestamptz := '2026-09-30 16:00:00+00';   -- 18:00 in Amsterdam
  t17 timestamptz := '2026-07-01 10:00:00+00';   -- the earliest order deal
  v_after   timestamptz := '2026-10-20 09:00:00+00';   -- the period has ended
  v_running timestamptz := '2026-10-07 13:00:00+00';   -- Wednesday 7 October, 15:00 in Amsterdam
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    -- tenants, people and roles (as the owner, as 0008t's verify)
    v_t1 := cma.create_tenant('verify-0008u-one', 'Verify 0008u one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008u-two', 'Verify 0008u two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-analyst1@example.invalid', 'analyst1') returning id into v_analyst1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-reader1@example.invalid', 'reader1') returning id into v_reader1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-super1@example.invalid', 'super1') returning id into v_super1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent1@example.invalid', 'agent1') returning id into v_agent1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-anna@example.invalid', 'Anna Verify') returning id into v_anna;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-bram@example.invalid', 'Bram Verify') returning id into v_bram;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin2') returning id into v_admin2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-analyst2@example.invalid', 'analyst2') returning id into v_analyst2;
    insert into cma.app_role (tenant_id, key, name) values (v_t1, 'verify_reader', 'Verify reader') returning id into v_role;
    insert into cma.role_permission (tenant_id, role_id, permission_key) values (v_t1, v_role, 'reports.view');
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_analyst1, 'analytics'), (v_t1, v_reader1, 'verify_reader'), (v_t1, v_super1, 'supervisor'),
                 (v_t1, v_agent1, 'agent'), (v_t1, v_anna, 'agent'), (v_t1, v_bram, 'agent'),
                 (v_t2, v_admin2, 'admin'), (v_t2, v_analyst2, 'analytics')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    select x.user_id into v_ing2 from cma.app_user_external_id x where x.tenant_id = v_t2 and x.system = 'ingest';
    perform set_config('role', 'cma_app', true);

    -- tenant one's configuration (the admin): markets, the intake start, the renewal source name, the
    -- owners (101 Anna, 103 Bram; 102 nobody) and the telephony user u1 (Anna); the three connections
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP');
    perform cma.set_tenant_setting('intake.start_date', '2026-06-01');
    perform cma.set_tenant_setting('commerce.renewal_source_names', 'verify_renewal');
    perform cma.set_user_external_id(v_anna, 'verifycrm_owner', '101');
    perform cma.set_user_external_id(v_bram, 'verifycrm_owner', '103');
    perform cma.set_user_external_id(v_anna, 'verifytel_user', 'u1');
    select c.connection_id into v_crm from cma.upsert_connection('verifycrm', 'Verify orders one', 'portal-1', null, null) c;
    perform cma.set_connection_kind(v_crm, 'crm');
    perform cma.set_connection_settings(v_crm, jsonb_build_object(
      'email_inbox_copy_origins', 'CONVERSATIONS', 'email_automated_origins', 'AUTOMATION_PLATFORM',
      'record_url_deal', 'https://crm.example.invalid/{account}/deal/{id}'));
    select c.connection_id into v_tel from cma.upsert_connection('verifytel', 'Verify phones one', 'company-1', null, null) c;
    perform cma.set_connection_kind(v_tel, 'telephony');
    select c.connection_id into v_shop from cma.upsert_connection('verifyshop', 'Verify shop one', 'shop-1', null, null) c;
    perform cma.set_connection_kind(v_shop, 'commerce');
    perform cma.upsert_commerce_store(v_shop, 'verify-nl', 'Verify NL', 'NL', 'EUR', 'Europe/Amsterdam');

    -- B1. the settings: the defaults through setting_of; two accepted changes; eleven refusals
    v_txt := cma.setting_of(v_t1, 'attribution.window_days') || '/' || cma.setting_of(v_t1, 'attribution.known_contact_minutes')
      || '/' || cma.setting_of(v_t1, 'attribution.order_match_minutes');
    foreach v_detail in array array[
      'attribution.window_days=0', 'attribution.window_days=366', 'attribution.window_days=x',
      'attribution.level_order=lead_deal,lead_deal', 'attribution.level_order=calls', 'attribution.level_order=',
      'attribution.level_order=email, lead_deal', 'attribution.assisted_levels=self_service', 'attribution.known_contact_minutes=10081',
      'attribution.order_match_minutes=0', 'attribution.level_order=Email'] loop
      v_txt := v_txt || ' ' || pg_temp.v0008u_code(format('select cma.set_tenant_setting(%L, %L)', split_part(v_detail, '=', 1), split_part(v_detail, '=', 2)));
    end loop;
    v_txt := v_txt || ' ' || pg_temp.v0008u_code('select cma.set_tenant_setting(''attribution.assisted_levels'', '''')')
      || ' ' || pg_temp.v0008u_code('select cma.set_tenant_setting(''attribution.level_order'', ''email,lead_deal'')');
    perform cma.set_tenant_setting('attribution.assisted_levels', null);
    perform cma.set_tenant_setting('attribution.level_order', null);
    v_txt := v_txt || ' ' || cma.setting_of(v_t1, 'attribution.level_order');
    v_rows := v_rows || array['11', 'B1 the settings: defaults, two accepted, eleven refusals, reset to the default',
      case when v_txt = '90/60/1440 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 ok ok lead_deal,conversation,email,phone_match,attempt,known_contact'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- the pipelines (the Ingest user): self-serve (won, lost), sales (open, won), a ticket pipeline
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_pipelines(v_crm, '[
      {"recordType": "deal", "pipelineId": "self", "label": "Self serve", "stages": [
        {"stageId": "won", "label": "Won", "order": 1, "isClosed": true, "outcome": "won"},
        {"stageId": "lost", "label": "Lost", "order": 2, "isClosed": true, "outcome": "lost"}]},
      {"recordType": "deal", "pipelineId": "sales", "label": "Sales", "stages": [
        {"stageId": "s1", "label": "Open", "order": 1, "isClosed": false, "outcome": null},
        {"stageId": "sw", "label": "Won", "order": 9, "isClosed": true, "outcome": "won"}]},
      {"recordType": "ticket", "pipelineId": "tp", "label": "Support", "stages": [
        {"stageId": "t1", "label": "New", "order": 1, "isClosed": false}]}]');

    -- B2. the stage outcomes and the order pipeline: from the source; a person's none on sales' won kept
    --     by a later read that gives won; a read without the key keeping the stored outcome; the refusals
    --     (a ticket stage, another value, an unknown stage, a ticket pipeline as order pipeline, the
    --     agent); the configuration shows both
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_stage_outcome(v_crm, 'deal', 'sales', 'sw', 'none');
    perform cma.set_pipeline_order(v_crm, 'deal', 'self', true);
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_pipelines(v_crm, '[
      {"recordType": "deal", "pipelineId": "self", "label": "Self serve", "stages": [
        {"stageId": "won", "label": "Won", "order": 1, "isClosed": true},
        {"stageId": "lost", "label": "Lost", "order": 2, "isClosed": true, "outcome": "lost"}]},
      {"recordType": "deal", "pipelineId": "sales", "label": "Sales", "stages": [
        {"stageId": "s1", "label": "Open", "order": 1, "isClosed": false, "outcome": null},
        {"stageId": "sw", "label": "Won", "order": 9, "isClosed": true, "outcome": "won"}]}]');
    select string_agg(format('%s/%s=%s:%s', source_pipeline_id, source_stage_id, coalesce(outcome, '-'), coalesce(outcome_source, '-')), ' '
                      order by source_pipeline_id, source_stage_id) into v_txt
    from cma.connection_stage where tenant_id = v_t1 and connection_id = v_crm;
    v_txt := v_txt || ' ' || pg_temp.v0008u_code(format('select cma.ingest_upsert_pipelines(%L, %L)', v_crm,
      '[{"recordType": "deal", "pipelineId": "self", "stages": [{"stageId": "won", "isClosed": true, "outcome": "maybe"}]}]'));
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008u_code(format('select cma.set_stage_outcome(%L, ''ticket'', ''tp'', ''t1'', ''won'')', v_crm))
      || ' ' || pg_temp.v0008u_code(format('select cma.set_stage_outcome(%L, ''deal'', ''self'', ''won'', ''maybe'')', v_crm))
      || ' ' || pg_temp.v0008u_code(format('select cma.set_stage_outcome(%L, ''deal'', ''self'', ''nope'', ''won'')', v_crm))
      || ' ' || pg_temp.v0008u_code(format('select cma.set_pipeline_order(%L, ''ticket'', ''tp'', true)', v_crm));
    perform set_config('app.user_id', v_agent1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008u_code(format('select cma.set_pipeline_order(%L, ''deal'', ''sales'', true)', v_crm));
    perform set_config('app.user_id', v_admin1::text, true);
    select v_txt || ' ' || string_agg(format('%s:%s:%s', p ->> 'pipelineId', p ->> 'isOrder', jsonb_array_length(p -> 'stages')), ' ')
    into v_txt from jsonb_array_elements(cma.connection_config(v_crm) -> 'pipelines') p;
    v_rows := v_rows || array['12', 'B2 stage outcomes from the source, a person''s kept, a read without the key kept; the order pipeline; refusals',
      case when v_txt = 'sales/s1=-:- sales/sw=-:person self/lost=lost:source self/won=won:source tp/t1=-:- CMA04 CMA04 CMA04 CMA02 CMA04 CMA06 '
                        || 'sales:false:2 self:true:2 tp:false:1'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B3. created_at slots: slot 1 refused (the object's own time), slot 3 before 2 refused, 2 and 3 taken,
    --     a property twice refused, 2 not removable while 3 maps, then 3 and 2 removed
    v_txt := pg_temp.v0008u_code(format('select cma.set_connection_field(%L, ''contact'', ''created_at'', null, ''prop_a'', 1::smallint)', v_crm))
      || ' ' || pg_temp.v0008u_code(format('select cma.set_connection_field(%L, ''contact'', ''created_at'', null, ''prop_b'', 3::smallint)', v_crm))
      || ' ' || pg_temp.v0008u_code(format('select cma.set_connection_field(%L, ''contact'', ''created_at'', null, ''prop_a'', 2::smallint)', v_crm))
      || ' ' || pg_temp.v0008u_code(format('select cma.set_connection_field(%L, ''contact'', ''created_at'', null, ''Prop_A'', 3::smallint)', v_crm))
      || ' ' || pg_temp.v0008u_code(format('select cma.set_connection_field(%L, ''contact'', ''created_at'', null, ''prop_b'', 3::smallint)', v_crm))
      || ' ' || pg_temp.v0008u_code(format('select cma.set_connection_field(%L, ''contact'', ''created_at'', null, '''', 2::smallint)', v_crm))
      || ' ' || pg_temp.v0008u_code(format('select cma.set_connection_field(%L, ''deal'', ''created_at'', null, ''prop_c'', 1::smallint)', v_crm));
    select v_txt || ' ' || string_agg(f ->> 'property' || '@' || (f ->> 'slot'), ',' order by (f ->> 'slot')::int) into v_txt
    from jsonb_array_elements(cma.connection_config(v_crm) -> 'fields') f where f ->> 'field' = 'created_at';
    v_txt := v_txt || ' ' || pg_temp.v0008u_code(format('select cma.set_connection_field(%L, ''contact'', ''created_at'', null, '''', 3::smallint)', v_crm))
      || ' ' || pg_temp.v0008u_code(format('select cma.set_connection_field(%L, ''contact'', ''created_at'', null, '''', 2::smallint)', v_crm));
    v_rows := v_rows || array['13', 'B3 the created_at slots: from 2, contiguous, one property each, removed from the end',
      case when v_txt = 'CMA04 CMA04 ok CMA03 ok CMA04 CMA04 prop_a@2,prop_b@3 ok ok' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- the deals (the Ingest user): the order deals o1 to o18 and the lead deals; o12 lost
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_records(v_crm, jsonb_build_array(
      pg_temp.v0008u_deal('o1', 'won', 'k1', t1, 'NL'), pg_temp.v0008u_deal('o2', 'won', 'k2', t2, 'GB'),
      pg_temp.v0008u_deal('o3', 'won', 'k3', t3, 'NL', 'self', null, 70), pg_temp.v0008u_deal('o4', 'won', 'k4', t4, 'NL'),
      pg_temp.v0008u_deal('o5', 'won', 'k5', t5, 'NL'), pg_temp.v0008u_deal('o6', 'won', 'k6', t6, 'NL'),
      pg_temp.v0008u_deal('o7', 'won', 'k7', t7, 'NL'), pg_temp.v0008u_deal('o8', 'won', null, t8, 'NL', 'self', null, 25),
      pg_temp.v0008u_deal('o9', 'won', 'k1', t9, 'NL'), pg_temp.v0008u_deal('o10', 'won', 'k10', t10, 'NL'),
      pg_temp.v0008u_deal('o11', 'won', 'k11', t11, 'NL'), pg_temp.v0008u_deal('o12', 'lost', 'k12', t12, 'NL'),
      pg_temp.v0008u_deal('o13', 'won', 'k13', t13, 'NL'), pg_temp.v0008u_deal('o14', 'won', 'k14', t14, 'NL'),
      pg_temp.v0008u_deal('o16', 'won', 'k16', t16, 'NL'), pg_temp.v0008u_deal('o18', 'won', 'k18', t18, 'NL'),
      pg_temp.v0008u_deal('o17', 'won', 'k17', t17, 'NL'),
      -- lead deals: k1's three days before (owner 101), k13's exactly at the window's start (101), k14's at
      -- its T and a second before its window
      pg_temp.v0008u_deal('l1', 's1', 'k1', '2026-10-02 08:00:00+00', 'NL', 'sales', '101'),
      pg_temp.v0008u_deal('l13', 's1', 'k13', t13 - interval '90 days', 'NL', 'sales', '101'),
      pg_temp.v0008u_deal('l14', 's1', 'k14', t14, 'NL', 'sales', '101'),
      pg_temp.v0008u_deal('l14b', 's1', 'k14', t14 - interval '90 days' - interval '1 second', 'NL', 'sales', '101')));
    -- contacts after the deals (a contact is held while something points to it): k1 and k4 long known,
    -- k7 exactly an hour before its order, the others half an hour or a minute; k9 checks createdAts
    perform cma.ingest_upsert_contacts(v_crm, jsonb_build_array(
      jsonb_build_object('sourceId', 'k1', 'country', 'NL', 'createdAt', '2026-01-01T00:00:00Z', 'updatedAt', '2026-10-01T00:00:00Z'),
      jsonb_build_object('sourceId', 'k2', 'country', 'GB', 'createdAt', '2026-10-06T08:30:00Z', 'updatedAt', '2026-10-06T08:30:00Z'),
      jsonb_build_object('sourceId', 'k3', 'country', 'NL', 'createdAt', '2026-10-07T11:30:00Z', 'updatedAt', '2026-10-07T11:30:00Z'),
      jsonb_build_object('sourceId', 'k4', 'country', 'NL', 'createdAts', jsonb_build_array('2026-10-01T00:00:00Z', '2025-12-01T00:00:00Z', null),
                         'updatedAt', '2026-10-01T00:00:00Z'),
      jsonb_build_object('sourceId', 'k5', 'country', 'NL', 'createdAt', '2026-10-08T13:30:00Z', 'updatedAt', '2026-10-08T13:30:00Z'),
      jsonb_build_object('sourceId', 'k6', 'country', 'NL', 'createdAt', '2026-10-09T08:30:00Z', 'updatedAt', '2026-10-09T08:30:00Z'),
      jsonb_build_object('sourceId', 'k7', 'country', 'NL', 'createdAt', '2026-10-09T14:00:00Z', 'updatedAt', '2026-10-09T14:00:00Z'),
      jsonb_build_object('sourceId', 'k13', 'country', 'NL', 'createdAt', '2026-10-06T14:30:00Z', 'updatedAt', '2026-10-06T14:30:00Z'),
      jsonb_build_object('sourceId', 'k14', 'country', 'NL', 'createdAt', '2026-10-07T14:59:00Z', 'updatedAt', '2026-10-07T14:59:00Z')));

    -- B4. a contact's creation time: the earliest of the slots (k4: 1 December 2025 of the second slot); a
    --     read without one keeps it; createdAt and createdAts together refused
    perform cma.ingest_upsert_contacts(v_crm, '[{"sourceId": "k4", "country": "NL", "updatedAt": "2026-10-02T00:00:00Z"}]');
    select to_char(source_created_at at time zone 'UTC', 'YYYY-MM-DD') into v_txt from cma.crm_contact where tenant_id = v_t1 and source_id = 'k4';
    v_txt := v_txt || ' ' || pg_temp.v0008u_code(format('select * from cma.ingest_upsert_contacts(%L, %L)', v_crm,
      '[{"sourceId": "k4", "createdAt": "2026-01-01T00:00:00Z", "createdAts": [], "updatedAt": "2026-10-03T00:00:00Z"}]'))
      || ' ' || pg_temp.v0008u_code(format('select * from cma.ingest_upsert_contacts(%L, %L)', v_crm,
      '[{"sourceId": "k4", "createdAt": "yesterday", "updatedAt": "2026-10-03T00:00:00Z"}]'));
    v_rows := v_rows || array['14', 'B4 a contact''s creation time: the earliest slot; kept by a read without it; the refusals',
      case when v_txt = '2025-12-01 CMA04 CMA04' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- calls: o2's contact k2 connected (a linked outbound telephony call of a minute, owner 103); o6's k6
    -- an unconnected call (101; since 0008zc logging an outbound telephony call nobody answered); a CRM call
    -- from o5's order phone on another contact (101, 28 September), a telephony call from it (u1, 7 October)
    perform cma.ingest_upsert_calls(v_crm, jsonb_build_array(
      jsonb_build_object('sourceId', 'c2', 'occurredAt', '2026-10-01T08:00:00Z', 'direction', 'outbound', 'ownerRef', '103', 'counterpartHash', h2,
                         'updatedAt', '2026-10-01T08:00:00Z'),
      jsonb_build_object('sourceId', 'c6', 'occurredAt', '2026-10-08T09:00:00Z', 'direction', 'outbound', 'ownerRef', '101', 'counterpartHash', h6,
                         'updatedAt', '2026-10-08T09:00:00Z'),
      jsonb_build_object('sourceId', 'c5', 'occurredAt', '2026-09-28T10:00:00Z', 'direction', 'inbound', 'ownerRef', '101', 'counterpartHash', h5,
                         'updatedAt', '2026-09-28T10:00:00Z')));
    perform cma.ingest_upsert_associations(v_crm, jsonb_build_array(
      jsonb_build_object('fromType', 'crm_call', 'fromId', 'c2', 'toType', 'contact', 'toId', 'k2', 'removed', false, 'changedAt', '2026-10-01T08:00:00Z'),
      jsonb_build_object('fromType', 'crm_call', 'fromId', 'c6', 'toType', 'contact', 'toId', 'k6', 'removed', false, 'changedAt', '2026-10-08T09:00:00Z'),
      jsonb_build_object('fromType', 'crm_call', 'fromId', 'c5', 'toType', 'contact', 'toId', 'k99', 'removed', false, 'changedAt', '2026-09-28T10:00:00Z')));
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
      jsonb_build_object('sourceId', 'tp2', 'direction', 'outbound', 'status', 'done', 'startedAt', '2026-10-01T08:00:10Z', 'answeredAt', '2026-10-01T08:00:20Z',
                         'endedAt', '2026-10-01T08:01:20Z', 'counterpartHash', h2, 'versionAt', '2026-10-01T08:01:20Z'),
      jsonb_build_object('sourceId', 'tp6', 'direction', 'outbound', 'status', 'done', 'startedAt', '2026-10-08T08:59:50Z',
                         'endedAt', '2026-10-08T09:00:10Z', 'counterpartHash', h6, 'versionAt', '2026-10-08T09:00:10Z'),
      jsonb_build_object('sourceId', 'tp5', 'direction', 'inbound', 'status', 'done', 'startedAt', '2026-10-07T10:00:00Z', 'answeredAt', '2026-10-07T10:00:10Z',
                         'endedAt', '2026-10-07T10:03:00Z', 'counterpartHash', h5, 'userRef', 'u1', 'versionAt', '2026-10-07T10:03:00Z')));
    v_n := cma.link_calls(timestamptz '2026-09-01 00:00+00');

    -- emails: an engagement to k1 by 103 the day before o1 (after the lead deal); an inbox message to k3 by
    -- 102 the day before o3; to k4 an inbox copy, an automation and a bot's inbox message; to k13 one a
    -- second before its window and one at its T
    perform cma.ingest_upsert_threads(v_crm, jsonb_build_array(
      jsonb_build_object('sourceId', 'th3', 'inboxId', 'ib1', 'status', 'open', 'contactId', 'k3', 'createdAt', '2026-10-06T11:00:00Z', 'updatedAt', '2026-10-06T12:00:00Z'),
      jsonb_build_object('sourceId', 'th4', 'inboxId', 'ib1', 'status', 'open', 'contactId', 'k4', 'createdAt', '2026-10-07T11:00:00Z', 'updatedAt', '2026-10-07T12:00:00Z')));
    perform cma.ingest_upsert_emails(v_crm, jsonb_build_array(
      jsonb_build_object('sourceKind', 'crm_email', 'sourceId', 'e1', 'direction', 'out', 'status', 'sent', 'occurredAt', '2026-10-04T09:00:00Z',
                         'actorKind', 'agent', 'ownerRef', '103', 'contactId', 'k1', 'origin', 'CRM_UI', 'createdAt', '2026-10-04T09:00:00Z', 'updatedAt', '2026-10-04T09:00:00Z'),
      jsonb_build_object('sourceKind', 'inbox_message', 'sourceId', 'm3', 'threadId', 'th3', 'inboxId', 'ib1', 'direction', 'out', 'status', 'sent',
                         'occurredAt', '2026-10-06T12:00:00Z', 'actorKind', 'agent', 'ownerRef', '102', 'createdAt', '2026-10-06T12:00:00Z', 'updatedAt', '2026-10-06T12:00:00Z'),
      jsonb_build_object('sourceKind', 'crm_email', 'sourceId', 'e4a', 'direction', 'out', 'status', 'sent', 'occurredAt', '2026-10-07T09:00:00Z',
                         'actorKind', 'agent', 'ownerRef', '101', 'contactId', 'k4', 'origin', 'CONVERSATIONS', 'createdAt', '2026-10-07T09:00:00Z', 'updatedAt', '2026-10-07T09:00:00Z'),
      jsonb_build_object('sourceKind', 'crm_email', 'sourceId', 'e4b', 'direction', 'out', 'status', 'sent', 'occurredAt', '2026-10-07T09:30:00Z',
                         'actorKind', 'system', 'contactId', 'k4', 'origin', 'AUTOMATION_PLATFORM', 'createdAt', '2026-10-07T09:30:00Z', 'updatedAt', '2026-10-07T09:30:00Z'),
      jsonb_build_object('sourceKind', 'inbox_message', 'sourceId', 'm4', 'threadId', 'th4', 'inboxId', 'ib1', 'direction', 'out', 'status', 'sent',
                         'occurredAt', '2026-10-07T12:00:00Z', 'actorKind', 'bot', 'createdAt', '2026-10-07T12:00:00Z', 'updatedAt', '2026-10-07T12:00:00Z'),
      jsonb_build_object('sourceKind', 'crm_email', 'sourceId', 'e13a', 'direction', 'out', 'status', 'sent', 'occurredAt', t13 - interval '90 days' - interval '1 second',
                         'actorKind', 'agent', 'ownerRef', '103', 'contactId', 'k13', 'origin', 'CRM_UI', 'createdAt', '2026-07-08T00:00:00Z', 'updatedAt', '2026-07-08T00:00:00Z'),
      jsonb_build_object('sourceKind', 'crm_email', 'sourceId', 'e13b', 'direction', 'out', 'status', 'sent', 'occurredAt', t13,
                         'actorKind', 'agent', 'ownerRef', '103', 'contactId', 'k13', 'origin', 'CRM_UI', 'createdAt', t13, 'updatedAt', t13)));

    -- the store: customers matched to their contacts (cu5's phone hash on its order), the orders: k1's
    -- nearest (10 minutes after T, EUR 100) against one 20 hours after and one two days before; GBP for
    -- k2; k4's without a phone hash; k1's second; a renewal; one the store counts as repeat
    perform cma.ingest_upsert_commerce_customers(v_shop, (select jsonb_agg(jsonb_build_object('sourceId', 'cu' || n, 'updatedAt', '2026-10-01T00:00:00Z'))
                                                          from unnest(array['1', '2', '4', '5', '10', '11']) n));
    perform cma.set_commerce_customer_contact(v_shop, 'cu' || n, v_crm, 'k' || n) from unnest(array['1', '2', '4', '5', '10', '11']) n;
    perform cma.ingest_upsert_commerce_orders(v_shop, jsonb_build_array(
      pg_temp.v0008u_order('or1a', 'cu1', t1 + interval '10 minutes', 'EUR', 100, 0),
      pg_temp.v0008u_order('or1b', 'cu1', t1 + interval '20 hours', 'EUR', 999, 1),
      pg_temp.v0008u_order('or1c', 'cu1', t1 - interval '2 days', 'EUR', 5, 0),
      pg_temp.v0008u_order('or2', 'cu2', t2 + interval '5 minutes', 'GBP', 50, 0),
      pg_temp.v0008u_order('or4', 'cu4', t4 + interval '1 minute', 'EUR', 40, 0),
      pg_temp.v0008u_order('or5', 'cu5', t5 + interval '2 minutes', 'EUR', 30, 0, null, h5),
      pg_temp.v0008u_order('or9', 'cu1', t9 + interval '1 minute', 'EUR', 20, 1),
      pg_temp.v0008u_order('or10', 'cu10', t10 + interval '1 minute', 'EUR', 15, 3, 'verify_renewal'),
      pg_temp.v0008u_order('or11', 'cu11', t11 + interval '1 minute', 'EUR', 60, 2)));

    perform set_config('app.user_id', v_analyst1::text, true);

    -- B5. the kinds of the week's order deals: first, no_contact (o8), repeat (o9, k1's second), renewal
    --     (o10), not_first (o11, the store's repeat); o12 (lost) not an order deal
    select string_agg(x.deal_source_id || ':' || x.kind, ' ' order by x.created_at) into v_txt
    from cma.first_orders_of(v_t1, timestamptz '2026-10-05 00:00+02', timestamptz '2026-10-12 00:00+02') x;
    v_rows := v_rows || array['15', 'B5 the kinds: first, no contact, repeat, renewal, not first; a lost deal no order',
      case when v_txt = 'o1:first o2:first o13:first o3:first o14:first o4:first o5:first o6:first o7:first o8:no_contact o9:repeat o10:renewal o11:not_first'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B6. the linked order, nearest within the match window, and the amount: or1a for o1 (not 20 hours
    --     later, not two days before); GBP for o2; o3 the deal's own EUR 70 without an order; o8 none
    select string_agg(format('%s:%s:%s:%s', x.deal_source_id, coalesce(x.order_source_id, '-'), coalesce(x.currency, '-'), coalesce(x.amount::text, '-')), ' '
                      order by x.deal_source_id) into v_txt
    from cma.first_orders_of(v_t1, timestamptz '2026-10-05 00:00+02', timestamptz '2026-10-12 00:00+02') x
    where x.deal_source_id in ('o1', 'o2', 'o3', 'o8', 'o9');
    v_rows := v_rows || array['16', 'B6 the linked order: the nearest within the match window; its amount, else the deal''s',
      case when v_txt = 'o1:or1a:EUR:100.00 o2:or2:GBP:50.00 o3:-:EUR:70.00 o8:-:EUR:25.00 o9:or9:EUR:20.00' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B7. the evidence of each first order (lead_deal, conversation, email, phone_match, attempt,
    --     known_contact as 1 or 0): o2's outbound conversation an attempt too (0008zc: every outbound call is
    --     one); o4's inbox copy, automation and bot no email; o5's call on another contact a phone match; o7
    --     known at exactly an hour; o13 a lead deal at the window's start, not the email a second before it or the
    --     one at T; o14 nothing (a lead deal at T, one a second early)
    select string_agg(format('%s:%s%s%s%s%s%s', x.deal_source_id, x.lead_deal::int, x.conversation::int, x.email::int, x.phone_match::int,
                             x.attempt::int, x.known_contact::int), ' ' order by x.deal_source_id) into v_txt
    from cma.first_orders_of(v_t1, timestamptz '2026-10-05 00:00+02', timestamptz '2026-10-12 00:00+02') x where x.kind = 'first';
    v_rows := v_rows || array['17', 'B7 every flag at its edges; an inbox copy, an automation and a bot no touch',
      case when v_txt = 'o1:101001 o13:100000 o14:000000 o2:010010 o3:001000 o4:000001 o5:000100 o6:000010 o7:000001' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B8. the level, the attribution and the credited person (the latest assisted touch): o1 lead_deal via
    --     the call center, credited to Bram's later email; o2 Bram's call; o3 an owner without a person; o5
    --     Anna through the telephony user (the later of the two phone calls); o13 Anna's lead deal; o4 and
    --     o7 known contacts, o6 an attempt and o14 nothing: self-service, nobody credited
    select string_agg(format('%s:%s:%s:%s', x.deal_source_id, x.level, x.attribution,
                             case when x.credited_user_id = v_anna then 'Anna' when x.credited_user_id = v_bram then 'Bram'
                                  when x.credited_owner_ref is not null then 'not linked' else '-' end), ' ' order by x.deal_source_id) into v_txt
    from cma.first_orders_of(v_t1, timestamptz '2026-10-05 00:00+02', timestamptz '2026-10-12 00:00+02') x where x.kind = 'first';
    v_rows := v_rows || array['18', 'B8 the level, the attribution and the credited person, through a telephony user too',
      case when v_txt = 'o1:lead_deal:call_center:Bram o13:lead_deal:call_center:Anna o14:self_service:self_service:- o2:conversation:call_center:Bram '
                        || 'o3:email:call_center:not linked o4:known_contact:self_service:- o5:phone_match:call_center:Anna o6:attempt:self_service:- '
                        || 'o7:known_contact:self_service:-'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B9. days from the first touch: o1 from its lead deal (3 days 2 hours), o2 from the linked telephony
    --     call's start, o5 from the CRM call on 28 September, o13 exactly 90 days; none without a touch
    select string_agg(format('%s:%s', x.deal_source_id, coalesce(x.days_from_first_touch::text, '-')), ' ' order by x.deal_source_id) into v_txt
    from cma.first_orders_of(v_t1, timestamptz '2026-10-05 00:00+02', timestamptz '2026-10-12 00:00+02') x where x.kind = 'first';
    v_rows := v_rows || array['19', 'B9 days from the first touch',
      case when v_txt = 'o1:3.08 o13:90.00 o14:- o2:5.04 o3:1.00 o4:- o5:10.17 o6:1.00 o7:-' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B10. the level order and the assisted set are configuration: email first makes o1 an email order;
    --      lead deals alone assisted leave o2, o3 and o5 self-service
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('attribution.level_order', 'email,lead_deal,conversation,phone_match,attempt,known_contact');
    perform cma.set_tenant_setting('attribution.assisted_levels', 'lead_deal');
    select string_agg(format('%s:%s:%s', x.deal_source_id, x.level, x.attribution), ' ' order by x.deal_source_id) into v_txt
    from cma.first_orders_of(v_t1, timestamptz '2026-10-05 00:00+02', timestamptz '2026-10-12 00:00+02') x
    where x.deal_source_id in ('o1', 'o2', 'o3', 'o5', 'o13');
    perform cma.set_tenant_setting('attribution.level_order', null);
    perform cma.set_tenant_setting('attribution.assisted_levels', null);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['20', 'B10 the level order and the assisted set changed',
      case when v_txt = 'o1:email:self_service o13:lead_deal:call_center o2:conversation:self_service o3:email:self_service o5:phone_match:self_service'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B11. the report (the period has ended): the total (9 first orders: 5 via the call center, 4
    --      self-service; a repeat, a renewal, a not-first, a no-contact; median days), per level and per
    --      market; GB holds o2 alone; a level filter keeps that level's first orders and nothing counted apart
    select string_agg(format('%s/%s=%s:%s/%s:%s/%s/%s/%s:%s', r.dimension, coalesce(r.group_key, '*'), r.first_orders, r.call_center, r.self_service,
                             r.repeats, r.renewals, r.not_first, r.no_contact, coalesce(r.days_median::text, '-')), ' ' order by r.dimension, r.group_key) into v_txt
    from cma.first_orders_report_of(v_t1, date '2026-10-05', date '2026-10-11', 'day', null, null, v_after) r
    where r.period = 'current' and r.dimension in ('total', 'level', 'market');
    select v_txt || ' | ' || string_agg(format('%s=%s/%s', coalesce(r.group_key, '*'), r.first_orders, r.repeats), ' ') into v_txt
    from cma.first_orders_report(date '2026-10-05', date '2026-10-11', 'day', null, 'lead_deal') r
    where r.period = 'current' and r.dimension = 'total';
    v_rows := v_rows || array['21', 'B11 the report: the total, per level and per market; a level filter',
      case when v_txt = 'level/attempt=1:0/1:0/0/0/0:1.0 level/conversation=1:1/0:0/0/0/0:5.0 level/email=1:1/0:0/0/0/0:1.0 '
                        || 'level/known_contact=2:0/2:0/0/0/0:- level/lead_deal=2:2/0:0/0/0/0:46.5 level/phone_match=1:1/0:0/0/0/0:10.2 '
                        || 'level/self_service=1:0/1:0/0/0/0:- market/GB=1:1/0:0/0/0/0:5.0 market/NL=8:4/4:1/1/1/1:3.1 '
                        || 'total/*=9:5/4:1/1/1/1:4.1 | *=2/0'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B12. amounts per currency, never summed across: EUR (o1 100, o3 70, o4 40, o5 30; the call-center
    --      part 200) and GBP (o2 50); the first orders without a currency apart
    select string_agg(format('%s/%s/%s=%s:%s:%s:%s', a.dimension, coalesce(a.group_key, '*'), a.currency, a.orders, coalesce(a.amount::text, '-'),
                             a.call_center_amount, a.self_service_amount), ' ' order by a.dimension, a.group_key, a.currency) into v_txt
    from cma.first_orders_amounts(date '2026-10-05', date '2026-10-11', null, null) a;
    v_rows := v_rows || array['22', 'B12 amounts per currency, never summed across',
      case when v_txt = 'market/GB/GBP=1:50.00:50.00:0 market/NL/EUR=4:240.00:200.00:40.00 market/NL/none=4:-:0:0 '
                        || 'total/*/EUR=4:240.00:200.00:40.00 total/*/GBP=1:50.00:50.00:0 total/*/none=4:-:0:0'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B13. the previous period like for like: on Wednesday 7 October at 15:00 the previous span is 28 to
    --      30 September up to 15:00 on the 30th (o16 at 12:00, not o18 at 18:00); once the week has ended,
    --      the whole previous week (both)
    select string_agg(r.first_orders::text, '/') into v_txt
    from cma.first_orders_report_of(v_t1, date '2026-10-05', date '2026-10-11', 'day', null, null, v_running) r
    where r.period = 'previous';
    select v_txt || ' ' || string_agg(r.first_orders::text, '/') into v_txt
    from cma.first_orders_report_of(v_t1, date '2026-10-05', date '2026-10-11', 'day', null, null, v_after) r
    where r.period = 'previous';
    v_rows := v_rows || array['23', 'B13 the previous period like for like: up to the time of day while the period runs, whole after',
      case when v_txt = '1 2' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B14. the history start: intake (1 June) plus the 90-day window, later than the earliest order deal
    --      (1 July); the phone tier from the earliest order with a phone hash (8 October); a connected
    --      tenant; tenant two none and not connected
    select format('%s/%s/%s', h.history_start, h.phone_start, h.connected) into v_txt from cma.first_orders_history_start() h;
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_analyst2::text, true);
    select v_txt || ' ' || format('%s/%s/%s', coalesce(h.history_start::text, '-'), coalesce(h.phone_start::text, '-'), h.connected) into v_txt
    from cma.first_orders_history_start() h;
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['24', 'B14 the history start and the phone tier''s start; none without an order pipeline',
      case when v_txt = '2026-08-30/2026-10-08/t -/-/f' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B15. the list: the first orders newest first, capped at two with the total of nine and the link;
    --      a level filter
    select string_agg(format('%s:%s:%s:%s', l.deal_source_id, l.level, l.total_rows, coalesce(l.record_url, '-')), ' ') into v_txt
    from cma.first_orders_list(date '2026-10-05', date '2026-10-11', null, null, 2) l;
    select v_txt || ' | ' || string_agg(l.deal_source_id, ' ') into v_txt
    from cma.first_orders_list(date '2026-10-05', date '2026-10-11', null, 'known_contact') l;
    v_rows := v_rows || array['25', 'B15 the list: newest first, capped, with the total and the link; a level filter',
      case when v_txt = 'o7:known_contact:9:https://crm.example.invalid/portal-1/deal/o7 o6:attempt:9:https://crm.example.invalid/portal-1/deal/o6 | o7 o4'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B16. per person: refused while reports.per_person does not hold orders (email alone, too); then by
    --      name, never ranked: Anna (o5, o13), Bram (o1, o2), one owner id without a person (o3), the total
    v_txt := pg_temp.v0008u_code('select * from cma.first_orders_per_person(date ''2026-10-05'', date ''2026-10-11'', null, null)');
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('reports.per_person', 'email');
    perform set_config('app.user_id', v_analyst1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008u_code('select * from cma.first_orders_per_person(date ''2026-10-05'', date ''2026-10-11'', null, null)');
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('reports.per_person', 'orders');
    perform set_config('app.user_id', v_analyst1::text, true);
    select v_txt || ' ' || string_agg(format('%s:%s:%s/%s/%s/%s:%s', coalesce(p.display_name, p.row_kind || coalesce('(' || p.unlinked_owners || ')', '')),
                                             p.orders, p.lead_deal, p.conversation, p.email, p.phone_match, coalesce(p.days_median::text, '-')), ' ') into v_txt
    from cma.first_orders_per_person(date '2026-10-05', date '2026-10-11', null, null) p;
    v_rows := v_rows || array['26', 'B16 per person: refused while switched off; by name, the not-linked row, the total',
      case when v_txt = 'CMA06 CMA06 Anna Verify:2:1/0/0/1:50.1 Bram Verify:2:1/1/0/0:4.1 not_linked(1):1:0/0/1/0:1.0 total:5:2/1/1/1:5.0'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B17. the filters and the group: a lower-case market, an unknown level, a group by month and a range
    --      longer than 92 days refused; unknown as a market taken
    v_txt := pg_temp.v0008u_code('select * from cma.first_orders_report(date ''2026-10-05'', date ''2026-10-11'', ''day'', ''nl'', null)')
      || ' ' || pg_temp.v0008u_code('select * from cma.first_orders_report(date ''2026-10-05'', date ''2026-10-11'', ''day'', null, ''phone'')')
      || ' ' || pg_temp.v0008u_code('select * from cma.first_orders_report(date ''2026-10-05'', date ''2026-10-11'', ''month'', null, null)')
      || ' ' || pg_temp.v0008u_code('select * from cma.first_orders_list(date ''2026-01-01'', date ''2026-10-11'', null, null)')
      || ' ' || pg_temp.v0008u_code('select * from cma.first_orders_amounts(date ''2026-10-05'', date ''2026-10-11'', ''unknown'', ''self_service'')');
    v_rows := v_rows || array['27', 'B17 the filters, the group and the range refused; unknown and self_service taken',
      case when v_txt = 'CMA04 CMA04 CMA04 CMA04 ok' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B18. the permissions: the reads for reports.view (the reader) and performance.team (the supervisor);
    --      the agent and the Ingest user refused; no acting user CMA01
    v_txt := '';
    foreach v_detail in array array[v_reader1::text, v_super1::text, v_agent1::text, v_ing1::text] loop
      perform set_config('app.user_id', v_detail, true);
      v_txt := v_txt || pg_temp.v0008u_code('select * from cma.first_orders_report(date ''2026-10-05'', date ''2026-10-11'', ''week'', null, null)')
        || '/' || pg_temp.v0008u_code('select * from cma.first_orders_amounts(date ''2026-10-05'', date ''2026-10-11'', null, null)')
        || '/' || pg_temp.v0008u_code('select * from cma.first_orders_list(date ''2026-10-05'', date ''2026-10-11'', null, null)')
        || '/' || pg_temp.v0008u_code('select * from cma.first_orders_history_start()') || ' ';
    end loop;
    perform set_config('app.user_id', '', true);
    v_txt := v_txt || pg_temp.v0008u_code('select * from cma.first_orders_report(date ''2026-10-05'', date ''2026-10-11'', ''week'', null, null)');
    v_rows := v_rows || array['28', 'B18 the permissions: reports.view or performance.team; an agent and the Ingest user refused',
      case when v_txt = 'ok/ok/ok/ok ok/ok/ok/ok CMA06/CMA06/CMA06/CMA06 CMA06/CMA06/CMA06/CMA06 CMA01' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B19. tenant isolation: tenant two (a connection of the same adapter and names) sees no order deals,
    --      and cannot mark tenant one's pipeline or stage
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    select c.connection_id into v_crm2 from cma.upsert_connection('verifycrm', 'Verify orders two', 'portal-2', null, null) c;
    perform cma.set_connection_kind(v_crm2, 'crm');
    v_txt := pg_temp.v0008u_code(format('select cma.set_pipeline_order(%L, ''deal'', ''self'', false)', v_crm))
      || ' ' || pg_temp.v0008u_code(format('select cma.set_stage_outcome(%L, ''deal'', ''self'', ''won'', ''none'')', v_crm));
    perform set_config('app.user_id', v_analyst2::text, true);
    select v_txt || ' ' || format('%s/%s/%s', (select r.first_orders + r.repeats + r.no_contact from cma.first_orders_report(date '2026-10-05', date '2026-10-11', 'day', null, null) r
                                              where r.period = 'current' and r.dimension = 'total'),
                                  (select count(*) from cma.first_orders_list(date '2026-10-05', date '2026-10-11', null, null)),
                                  (select count(*) from cma.connection_pipeline where is_order)) into v_txt;
    v_rows := v_rows || array['29', 'B19 tenant isolation for the configuration and the reads',
      case when v_txt = 'CMA02 CMA02 0/0/0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B20. a reader scoped to tenant one sees its order deals since the history start (the twelve of the
    --      period and o16 and o18; not o17 before it) and the order pipeline; scoped to tenant two, none
    perform set_config('role', 'cma_readonly', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    select format('%s/%s/%s', (select count(*) from cma_read.first_orders where tenant_id = v_t1),
                  (select count(*) from cma_read.first_orders where tenant_id = v_t1 and kind = 'first' and attribution = 'call_center'),
                  (select count(*) from cma_read.connection_pipeline where tenant_id = v_t1 and is_order)) into v_txt;
    perform set_config('app.tenant_id', v_t2::text, true);
    select v_txt || format(' %s/%s', (select count(*) from cma_read.first_orders where tenant_id = v_t1),
                           (select count(*) from cma_read.connection_stage where tenant_id = v_t1)) into v_txt;
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['30', 'B20 a reader scoped to one tenant sees its own rows only',
      case when v_txt = '15/5/1 0/0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['39', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008u (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008u values (39, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008u
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED: not dev'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008u where result = 'PASS') = 26
                       and not exists (select 1 from verify_0008u where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0008u where result = 'PASS'),
                                        (select count(*) from verify_0008u where result <> 'PASS'))) x
order by ord;
drop function if exists pg_temp.v0008u_code(text);
drop function if exists pg_temp.v0008u_deal(text, text, text, timestamptz, text, text, text, numeric);
drop function if exists pg_temp.v0008u_order(text, text, timestamptz, text, numeric, integer, text, text);
reset role;
