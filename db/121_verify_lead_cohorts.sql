-- =============================================================================================
-- 121_verify_lead_cohorts.sql: verifies addition 0008zm, lead cohorts
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure and privileges; block B
-- works on two throwaway tenants inside a subtransaction that is always rolled back, so nothing stays. Universal
-- otherwise: nothing of the seed is used; adapters, pipelines, deals, contacts, calls, lines, orders and people are
-- invented data values, and no row carries a name of a customer, an address or a phone number. Every check writes one
-- row, PASS or FAIL, and the last row is the verdict (OK when every check passes), because Cloud SQL Studio shows no
-- notices. Run as your own IAM login in dev, after 120_lead_cohorts.sql; then 113, 95 and 41 again.
--   A  structure and privileges: the addition row after 0008zl; every function the application's only and in the caller's
--      rights, the readers' function definer, the owner's, its search path pinned with pg_temp last, the readers' only; the
--      reader view's exact columns, with no name, address, email, phone, hash or payload; the setting in the catalog; each
--      fact read from the function that owns it (nothing of the calls, orders or deals written again); nothing twice
--   B  lead cohorts, on two throwaway tenants (Europe/Amsterdam; intake from 1 June 2026; pre-window 10 minutes; markets
--      NL and GB). Tenant one holds a CRM connection with a lead pipeline (open, won and lost stages) and an order pipeline
--      still marked lead, a telephony connection with a counted line and a shop. The deals, as of Friday 30 October 2026
--      12:00 UTC: three of the ISO week of 6 July (ordered on day 2 after a conversation on day 1; attempted on day 3, a
--      conversation on day 13, ordered on day 45; lost on day 12 never attempted, its order on day 96 beyond
--      lead_to_order.max_days), one created at 00:30 on Monday 13 July in Amsterdam (Sunday in UTC) never called; two of
--      the week of 12 October (won after a conversation; attempted in the pre-window, no conversation) and a deal of the
--      order pipeline; two of the week of 26 October (a conversation; created three hours before now). Tenant two holds one
--      deal of the same source id. Checked as of the fixed instant: the population against cma.lead_deals_of, every
--      deal's facts, the first attempt and conversation against Attempts per deal's, the created deals of every range
--      against cma.lead_deals_of, the figures per cohort and age, the ordered share at the largest age against lead to
--      order, an age not reached null, the range cutting a cohort, the splits, the filters and their lists, the setting's
--      refusals, an age above lead_to_order.max_days, the parameters refused, an agent refused, another tenant seeing 0
--      rows, the reader view equal to the application's rows
-- Provoke: set provoke below to true; every check must then read FAIL, and the verdict says PROVOKED instead of OK.
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

-- Dev only: a verifier that writes refuses a database without the dev seed. The flag is kept for the session, so every
-- block below stops at once and the verdict says REFUSED, also where the client carries on after the error
select set_config('verify.is_dev', (exists (select 1 from cma.app_user u join cma.tenant t on t.id = u.tenant_id
                                            where u.email = 'agent.two@example.com' and u.status = 'active'))::text, false) as is_dev;
do $$
begin
  if not current_setting('verify.is_dev')::boolean then
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 121 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0008zm;
create temp table verify_0008zm (ord int, check_name text, result text, detail text);

-- The error code a statement raises, or 'ok'
create or replace function pg_temp.v0008zm_code(p_sql text)
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

-- One cohort row of the report as text: label[/group][*partial] created/not called yet/ordered now/median days, then per
-- age age:attempted/conversation/ordered/lost with '-' for null
create or replace function pg_temp.v0008zm_cohort(c jsonb)
returns text
language sql immutable
as $$
  select format('%s%s%s %s/%s/%s/%s %s', c ->> 'label', coalesce('/' || (c ->> 'group'), ''),
                case when (c ->> 'partial')::boolean then '*' else '' end,
                c ->> 'created', c ->> 'not_called_yet', c ->> 'ordered', coalesce(c ->> 'median_days_to_order', '-'),
                (select string_agg(format('%s:%s/%s/%s/%s', a ->> 'age', coalesce(a ->> 'attempted', '-'), coalesce(a ->> 'conversation', '-'),
                                          coalesce(a ->> 'ordered', '-'), coalesce(a ->> 'lost', '-')), ' ' order by o)
                 from jsonb_array_elements(c -> 'ages') with ordinality as x(a, o)))
$$;

-- A report's cohorts (or its split rows) as text, newest first, separated by ' | '
create or replace function pg_temp.v0008zm_cohorts(j jsonb, p_key text)
returns text
language sql immutable
as $$
  select coalesce(string_agg(pg_temp.v0008zm_cohort(c), ' | ' order by o), '')
  from jsonb_array_elements(j -> p_key) with ordinality as x(c, o)
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
  -- A1. the addition is recorded, after 0008zl
  insert into verify_0008zm values (1, 'A1 addition 0008zm recorded, after 0008zl',
    case when exists (select 1 from cma.schema_migration where version = '0008zm')
              and exists (select 1 from cma.schema_migration where version = '0008zl') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. every function of the addition the application's only and in the caller's rights; the readers' function SECURITY
  --     DEFINER, owned by cma_owner, search path pinned with pg_temp last, the readers' only
  v_bad := '';
  foreach v_fn in array array[
    'cma.lead_cohorts_of(uuid,timestamptz,timestamptz,timestamptz)', 'cma.lead_cohort_rows_of(uuid,date,date,timestamptz)',
    'cma.lead_cohort_ages_of(uuid)', 'cma.lead_cohorts_choices_check(text,text)',
    'cma.lead_cohort_figures_from(cma.lead_cohort_deal[],integer[],integer,timestamptz)',
    'cma.lead_cohorts_from(cma.lead_cohort_deal[],text,text,integer[],integer,date,date,timestamptz)',
    'cma.lead_cohort_filter_lists_from(cma.lead_cohort_deal[])',
    'cma.lead_cohorts_report_of(uuid,date,date,text,text,text,text,text,timestamptz)',
    'cma.lead_cohorts_report(date,date,text,text,text,text,text)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or has_function_privilege('public', v_fn, 'execute')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      v_bad := v_bad || v_fn || ' not the application''s only or not in the caller''s rights; ';
    end if;
  end loop;
  v_fn := 'cma_read.lead_cohort_rows()';
  if to_regprocedure(v_fn) is null then
    v_bad := v_bad || v_fn || ' missing; ';
  elsif not (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
        or (select pg_get_userbyid(proowner) from pg_proc where oid = to_regprocedure(v_fn)) <> 'cma_owner'
        or not coalesce((select array_to_string(proconfig, ',') from pg_proc where oid = to_regprocedure(v_fn)) like 'search_path=%pg_temp', false)
        or not has_function_privilege('cma_readonly', v_fn, 'execute') or has_function_privilege('cma_app', v_fn, 'execute')
        or has_function_privilege('public', v_fn, 'execute') then
    v_bad := v_bad || v_fn || ' not the readers'' pinned definer function; ';
  end if;
  insert into verify_0008zm values (2, 'A2 every function the application''s only and invoker; the readers'' function definer, the owner''s, pinned, theirs only',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A3. the reader view's exact columns, readable by the readers only, none named like a name, an address, an email, a phone,
  --     a number, a hash, a reference or a payload
  v_bad := '';
  if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'lead_cohorts')
     is distinct from 'tenant_id,deal_id,connection_id,deal_source_id,pipeline_id,pipeline_label,market,source_channel,created_at,business_date,'
                      'week_start,month_start,age_days,attempts,first_attempt_at,first_conversation_at,outcome,lost_at,order_created_at,'
                      'days_to_order,not_called_yet'
     or not has_table_privilege('cma_readonly', 'cma_read.lead_cohorts', 'select')
     or has_table_privilege('cma_app', 'cma_read.lead_cohorts', 'select') then
    v_bad := 'cma_read.lead_cohorts; ';
  end if;
  select v_bad || coalesce(string_agg(column_name, ', '), '') into v_bad
  from information_schema.columns
  where table_schema = 'cma_read' and table_name = 'lead_cohorts'
    and column_name ~* '(name|address|email|phone|number|_hash$|^raw$|_ref$)';
  insert into verify_0008zm values (3, 'A3 the reader view with its exact columns, the readers'' only; no name, address, email, phone, hash or payload',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A4. the setting in the catalog with its type and default
  select string_agg(format('%s:%s:%s:%s', s.key, s.value_type, s.default_value, coalesce(array_to_string(s.allowed_values, '|'), '-')), ' ' order by s.key)
    into v_bad
  from cma.setting s where s.key like 'cohorts.%';
  insert into verify_0008zm values (4, 'A4 the setting cohorts.lead_ages_days in the catalog',
    case when v_bad = 'cohorts.lead_ages_days:text:1,7,30,60,90:-' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_bad, 'none'));

  -- A5. each fact from the function that owns it: the population and the order from cma.lead_to_order_of, the outcome and the
  --     window from cma.sales_deals_of, the attempts from cma.deal_attempts_of; no call, order or deal table read again; the
  --     report over the deals read once; the filters' checks reused
  v_bad := '';
  foreach v_fn in array array[
    'cma.lead_cohorts_of(uuid,timestamptz,timestamptz,timestamptz)|cma\.lead_to_order_of\(',
    'cma.lead_cohorts_of(uuid,timestamptz,timestamptz,timestamptz)|cma\.sales_deals_of\(',
    'cma.lead_cohorts_of(uuid,timestamptz,timestamptz,timestamptz)|cma\.deal_attempts_of\(',
    'cma.lead_cohort_rows_of(uuid,date,date,timestamptz)|cma\.lead_cohorts_of\(',
    'cma.lead_cohorts_report_of(uuid,date,date,text,text,text,text,text,timestamptz)|cma\.lead_cohort_rows_of\(',
    'cma.lead_cohorts_report(date,date,text,text,text,text,text)|cma\.funnel_filters_check\(',
    'cma.lead_cohorts_report(date,date,text,text,text,text,text)|cma\.report_range\(',
    'cma.lead_cohorts_report(date,date,text,text,text,text,text)|cma\.assert_any_permission\(',
    'cma_read.lead_cohort_rows()|cma\.lead_cohorts_of\('] loop
    if (select p.prosrc from pg_proc p where p.oid = to_regprocedure(split_part(v_fn, '|', 1))) !~ split_part(v_fn, '|', 2) then
      v_bad := v_bad || split_part(v_fn, '|', 1) || ' does not read ' || split_part(v_fn, '|', 2) || '; ';
    end if;
  end loop;
  if (select p.prosrc from pg_proc p where p.oid = to_regprocedure('cma.lead_cohorts_of(uuid,timestamptz,timestamptz,timestamptz)'))
     ~ 'cma\.(crm_call|telephony_call|commerce_order|crm_association|connection_stage|counted_deals_of|lead_deals_of)\M' then
    v_bad := v_bad || 'a rule written again; ';
  end if;
  insert into verify_0008zm values (5, 'A5 every fact read from the function that owns it; nothing written again',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A6. nothing twice: one 0008zm row, the setting once, the row type's 21 fields, the check trigger's two branches
  v_bad := '';
  if (select count(*) from cma.schema_migration where version = '0008zm') <> 1
     or (select count(*) from cma.setting where key = 'cohorts.lead_ages_days') <> 1
     or (select count(*) from pg_attribute a where a.attrelid = (select t.typrelid from pg_type t where t.oid = to_regtype('cma.lead_cohort_deal'))
         and a.attnum > 0 and not a.attisdropped) <> 21
     or (select p.prosrc from pg_proc p where p.oid = to_regprocedure('cma.check_tenant_setting()')) !~ 'cohorts\.lead_ages_days'
     or (select p.prosrc from pg_proc p where p.oid = to_regprocedure('cma.check_tenant_setting()')) !~ 'assets\.bundle_window_days' then
    v_bad := 'something is there twice, in another shape, or the setting''s check lost a branch';
  end if;
  insert into verify_0008zm values (6, 'A6 nothing twice: one addition row, the setting once, the row type''s 21 fields, the check with 0008zi''s branches and the new',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);
end
$$;

-- B. Lead cohorts on two throwaway tenants (rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_rows     text[] := '{}';
  v_t1 uuid; v_t2 uuid;
  v_admin1 uuid; v_analyst1 uuid; v_agent1 uuid; v_ing1 uuid;
  v_admin2 uuid; v_analyst2 uuid; v_ing2 uuid;
  v_crm uuid; v_tel uuid; v_shop uuid; v_crm2 uuid;
  v_txt text; v_app text; v_view text; v_sales text;
  j jsonb;
  r record;
  v_now  timestamptz := '2026-10-30 12:00:00+00';   -- Friday 30 October 2026, 13:00 in Amsterdam
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    -- tenants, people and roles (as the owner, as 0008z's verify)
    v_t1 := cma.create_tenant('verify-0008zm-one', 'Verify 0008zm one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008zm-two', 'Verify 0008zm two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-analyst1@example.invalid', 'analyst1') returning id into v_analyst1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent1@example.invalid', 'agent1') returning id into v_agent1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin2') returning id into v_admin2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-analyst2@example.invalid', 'analyst2') returning id into v_analyst2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_analyst1, 'analytics'), (v_t1, v_agent1, 'agent'),
                 (v_t2, v_admin2, 'admin'), (v_t2, v_analyst2, 'analytics')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    select x.user_id into v_ing2 from cma.app_user_external_id x where x.tenant_id = v_t2 and x.system = 'ingest';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t1, 'verifycrm', 'Verify cohorts CRM', 'portal-1') returning id into v_crm;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t1, 'verifytel', 'Verify cohorts telephony', 'tel-1') returning id into v_tel;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t1, 'verifyshop', 'Verify cohorts shop', 'shop-1.example.invalid') returning id into v_shop;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t2, 'verifycrm', 'Verify cohorts CRM two', 'portal-2') returning id into v_crm2;
    perform set_config('role', 'cma_app', true);

    -- tenant one's configuration (the admin): the markets, the settings, the shop
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP');
    perform cma.set_tenant_setting('intake.start_date', '2026-06-01');
    perform cma.set_tenant_setting('speed_to_lead.pre_window_minutes', '10');
    perform cma.upsert_commerce_store(v_shop, 'verify-nl', 'Verify NL', 'NL', 'EUR', 'Europe/Amsterdam');

    -- the catalogs from the sources (the Ingest user)
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_pipelines(v_crm, '[
      {"recordType": "deal", "pipelineId": "sales", "label": "Sales", "stages": [
         {"stageId": "s1", "label": "Open", "order": 1, "isClosed": false, "outcome": null},
         {"stageId": "sw", "label": "Won", "order": 8, "isClosed": true, "outcome": "won"},
         {"stageId": "sl", "label": "Lost", "order": 9, "isClosed": true, "outcome": "lost"}]},
      {"recordType": "deal", "pipelineId": "selfserve", "label": "Self Serve", "stages": [{"stageId": "o1", "label": "Won", "order": 1, "isClosed": true, "outcome": "won"}]}]');
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'number', '[{"numberRef": "n-nl", "name": "Verify NL line", "digits": "+31000000001"}]');

    -- their configuration (the admin): selfserve an order pipeline, still marked lead (as every pipeline is by default)
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_pipeline_order(v_crm, 'deal', 'selfserve', true);
    perform cma.set_telephony_number(v_tel, 'n-nl', 'NL', true);

    -- the deals (UTC; Amsterdam is UTC+2 until 25 October, UTC+1 after)
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_records(v_crm, '[
      {"recordType": "deal", "sourceId": "dA1",  "pipelineId": "sales",     "stageId": "s1", "contactId": "kA1", "market": "NL", "sourceChannel": "Facebook", "createdAt": "2026-07-06T08:00:00Z", "updatedAt": "2026-07-06T08:00:00Z"},
      {"recordType": "deal", "sourceId": "dA2",  "pipelineId": "sales",     "stageId": "s1", "contactId": "kA2", "market": "NL", "sourceChannel": "Google",   "createdAt": "2026-07-07T08:00:00Z", "updatedAt": "2026-07-07T08:00:00Z"},
      {"recordType": "deal", "sourceId": "dA3",  "pipelineId": "sales",     "stageId": "sl", "contactId": "kA3", "market": "GB", "sourceChannel": "Facebook", "createdAt": "2026-07-08T08:00:00Z", "closedAt": "2026-07-20T08:00:00Z", "updatedAt": "2026-07-20T08:00:00Z"},
      {"recordType": "deal", "sourceId": "dA4",  "pipelineId": "sales",     "stageId": "s1", "contactId": "kA4", "market": "GB",                             "createdAt": "2026-07-12T22:30:00Z", "updatedAt": "2026-07-12T22:30:00Z"},
      {"recordType": "deal", "sourceId": "dB1",  "pipelineId": "sales",     "stageId": "sw", "contactId": "kB1", "market": "NL", "sourceChannel": "Facebook", "createdAt": "2026-10-12T08:00:00Z", "closedAt": "2026-10-14T08:00:00Z", "updatedAt": "2026-10-14T08:00:00Z"},
      {"recordType": "deal", "sourceId": "dB2",  "pipelineId": "sales",     "stageId": "s1", "contactId": "kB2", "market": "NL", "sourceChannel": "Google",   "createdAt": "2026-10-16T10:00:00Z", "updatedAt": "2026-10-16T10:00:00Z"},
      {"recordType": "deal", "sourceId": "dOrd", "pipelineId": "selfserve", "stageId": "o1", "contactId": "kOrd", "market": "NL",                            "createdAt": "2026-10-13T09:00:00Z", "closedAt": "2026-10-13T09:00:00Z", "updatedAt": "2026-10-13T09:00:00Z"},
      {"recordType": "deal", "sourceId": "dC1",  "pipelineId": "sales",     "stageId": "s1", "contactId": "kC1", "market": "NL", "sourceChannel": "Facebook", "createdAt": "2026-10-29T08:00:00Z", "updatedAt": "2026-10-29T08:00:00Z"},
      {"recordType": "deal", "sourceId": "dC2",  "pipelineId": "sales",     "stageId": "s1", "contactId": "kC2", "market": "GB", "sourceChannel": "Facebook", "createdAt": "2026-10-30T09:00:00Z", "updatedAt": "2026-10-30T09:00:00Z"}]');
    perform cma.ingest_upsert_contacts(v_crm, (
      select jsonb_agg(jsonb_build_object('sourceId', k, 'country', 'NL', 'updatedAt', '2026-06-01T00:00:00Z'))
      from unnest(array['kA4', 'kB1', 'kB2', 'kOrd', 'kC1', 'kC2']) k)
      || '[{"sourceId": "kA1", "country": "NL", "refs": {"verifyshop": ["c-A1"]}, "updatedAt": "2026-06-01T00:00:00Z"},
           {"sourceId": "kA2", "country": "NL", "refs": {"verifyshop": ["c-A2"]}, "updatedAt": "2026-06-01T00:00:00Z"},
           {"sourceId": "kA3", "country": "GB", "refs": {"verifyshop": ["c-A3"]}, "updatedAt": "2026-06-01T00:00:00Z"}]'::jsonb);
    -- the CRM calls, each on its deal's contact, logged by a telephony call with the same hash
    perform cma.ingest_upsert_calls(v_crm, (
      select jsonb_agg(jsonb_build_object('sourceId', c.id, 'occurredAt', c.at, 'direction', 'outbound', 'counterpartHash', md5(c.id) || md5(c.id || 'x'),
                                          'updatedAt', c.at))
      from (values ('cA1', '2026-07-06T09:00:00Z'), ('cA2a', '2026-07-09T09:00:00Z'), ('cA2b', '2026-07-20T09:00:00Z'),
                   ('cB1', '2026-10-12T08:05:00Z'), ('cB2', '2026-10-16T09:55:00Z'), ('cOrd', '2026-10-13T09:30:00Z'),
                   ('cC1', '2026-10-29T08:30:00Z')) c(id, at)));
    perform cma.ingest_upsert_associations(v_crm, (
      select jsonb_agg(jsonb_build_object('fromType', 'crm_call', 'fromId', a.c, 'toType', 'contact', 'toId', a.k, 'removed', false,
                                          'changedAt', '2026-06-01T00:00:00Z'))
      from (values ('cA1', 'kA1'), ('cA2a', 'kA2'), ('cA2b', 'kA2'), ('cB1', 'kB1'), ('cB2', 'kB2'), ('cOrd', 'kOrd'), ('cC1', 'kC1')) a(c, k)));
    -- the telephony calls that logged them, 10 seconds earlier: answered with that much talk time, or not answered; a
    -- conversation from 30 seconds (calls.conversation_min_talk_seconds' default)
    perform cma.ingest_upsert_telephony_calls(v_tel, (
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'sourceId', 't' || t.c, 'direction', 'outbound', 'startedAt', t.started - interval '10 seconds',
               'answeredAt', case when t.talk is not null then t.started end,
               'endedAt', t.started + make_interval(secs => coalesce(t.talk, 20)), 'numberRef', 'n-nl', 'userRef', 'tu-1',
               'counterpartHash', md5(t.c) || md5(t.c || 'x'), 'versionAt', t.started + interval '1 hour')))
      from (values
        ('cA1',  timestamptz '2026-07-06T09:00:00Z', 60),
        ('cA2a', timestamptz '2026-07-09T09:00:00Z', null),
        ('cA2b', timestamptz '2026-07-20T09:00:00Z', 45),
        ('cB1',  timestamptz '2026-10-12T08:05:00Z', 40),
        ('cB2',  timestamptz '2026-10-16T09:55:00Z', null),
        ('cOrd', timestamptz '2026-10-13T09:30:00Z', 60),
        ('cC1',  timestamptz '2026-10-29T08:30:00Z', 35)) t(c, started, talk)));
    perform cma.link_calls('2026-06-01T00:00:00Z');
    -- the store's customers and orders: dA1's on day 2, dA2's on day 45, dA3's on day 96 (beyond lead_to_order.max_days)
    perform cma.ingest_upsert_commerce_customers(v_shop, '[{"sourceId": "c-A1", "updatedAt": "2026-06-01T00:00:00Z"},
      {"sourceId": "c-A2", "updatedAt": "2026-06-01T00:00:00Z"}, {"sourceId": "c-A3", "updatedAt": "2026-06-01T00:00:00Z"}]');
    perform cma.ingest_upsert_commerce_orders(v_shop, '[
      {"sourceId": "oA1", "customerId": "c-A1", "createdAt": "2026-07-08T10:00:00Z", "updatedAt": "2026-07-08T10:00:00Z", "priorOrdersCount": 0},
      {"sourceId": "oA2", "customerId": "c-A2", "createdAt": "2026-08-21T08:00:00Z", "updatedAt": "2026-08-21T08:00:00Z", "priorOrdersCount": 0},
      {"sourceId": "oA3", "customerId": "c-A3", "createdAt": "2026-10-12T08:00:00Z", "updatedAt": "2026-10-12T08:00:00Z", "priorOrdersCount": 0}]');

    -- tenant two: a deal of the same source id and creation as tenant one's dB1, never called
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    perform cma.set_tenant_setting('intake.start_date', '2026-06-01');
    perform set_config('app.user_id', v_ing2::text, true);
    perform cma.ingest_upsert_records(v_crm2, '[{"recordType": "deal", "sourceId": "dB1", "pipelineId": "sales", "contactId": "kB1", "createdAt": "2026-10-12T08:00:00Z", "updatedAt": "2026-10-12T08:00:00Z"}]');
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);

    -- B1. the population is cma.lead_deals_of's, the order pipeline's deal (still marked lead) included
    select string_agg(x.deal_source_id, ' ' order by x.deal_source_id) into v_txt from cma.lead_cohorts_of(v_t1, null, null, v_now) x;
    select v_txt || ' = ' || string_agg(d.source_id, ' ' order by d.source_id) into v_txt from cma.lead_deals_of(v_t1, null, null) d;
    v_rows := v_rows || array['11', 'B1 the population is cma.lead_deals_of''s, a deal of an order pipeline still marked lead included',
      case when v_txt = 'dA1 dA2 dA3 dA4 dB1 dB2 dC1 dC2 dOrd = dA1 dA2 dA3 dA4 dB1 dB2 dC1 dC2 dOrd' and not v_provoke then 'PASS' else 'FAIL' end,
      coalesce(v_txt, 'null')];

    -- B2. every deal's facts: the ISO week and month in the tenant's zone (dA4 is Monday 13 July in Amsterdam), the age in
    --     whole days, the attempts, the first attempt (dB2's in the pre-window) and conversation (UTC), the outcome, the day
    --     lost, the days to order (dA3's order beyond 90 days none), not called yet; the order pipeline's deal without attempts
    select string_agg(format('%s:%s/%s/%s/%s/%s/%s/%s/%s/%s/%s/%s', x.deal_source_id, to_char(x.week_start, 'MMDD'), to_char(x.month_start, 'MMDD'),
                             x.age_days, coalesce(x.attempts::text, '-'),
                             coalesce(to_char(x.first_attempt_at at time zone 'UTC', 'DD HH24:MI:SS'), '-'),
                             coalesce(to_char(x.first_conversation_at at time zone 'UTC', 'DD HH24:MI:SS'), '-'), coalesce(x.outcome, '-'),
                             coalesce(to_char(x.lost_at at time zone 'UTC', 'MMDD'), '-'), coalesce(x.days_to_order::text, '-'),
                             coalesce(x.source_channel, '-'), x.not_called_yet), ' ' order by x.deal_source_id)
      into v_txt
    from cma.lead_cohorts_of(v_t1, null, null, v_now) x;
    v_rows := v_rows || array['12', 'B2 every deal''s period keys in the tenant''s zone, age, attempts, first attempt and conversation, outcome, loss, order and not called yet',
      case when v_txt = 'dA1:0706/0701/116/1/06 08:59:50/06 08:59:50/ordered/-/2.08/Facebook/f '
                        || 'dA2:0706/0701/115/2/09 08:59:50/20 08:59:50/ordered/-/45.00/Google/f '
                        || 'dA3:0706/0701/114/0/-/-/lost/0720/-/Facebook/f '
                        || 'dA4:0713/0701/109/0/-/-/open/-/-/-/t '
                        || 'dB1:1012/1001/18/1/12 08:04:50/12 08:04:50/won/-/-/Facebook/f '
                        || 'dB2:1012/1001/14/1/16 09:54:50/-/open/-/-/Google/f '
                        || 'dC1:1026/1001/1/1/29 08:29:50/29 08:29:50/open/-/-/Facebook/f '
                        || 'dC2:1026/1001/0/0/-/-/open/-/-/Facebook/t '
                        || 'dOrd:1012/1001/17/-/-/-/-/-/-/-/f'
            and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    -- B3. the pages never disagree: every sales deal's attempts and first attempt are Attempts per deal's, and it has a
    --     conversation exactly when Attempts per deal names a first conversation
    select count(*) || ' of ' || (select count(*) from cma.attempts_per_deal_of(v_t1, null, null, v_now)) into v_txt
    from cma.lead_cohorts_of(v_t1, null, null, v_now) x
    join cma.attempts_per_deal_of(v_t1, null, null, v_now) p on p.deal_id = x.deal_id
    where x.attempts = p.attempts and x.first_attempt_at is not distinct from p.first_attempt_at
      and (x.first_conversation_at is not null) = (p.first_conversation_attempt is not null) and x.outcome = p.outcome;
    v_rows := v_rows || array['13', 'B3 attempts, first attempt, conversation and outcome equal Attempts per deal''s for every sales deal',
      case when v_txt = '8 of 8' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    -- B4. per range, period and split the created deals of the cohorts (and of the split rows) add up to cma.lead_deals_of's
    --     count of the range: July, October, a range that cuts a week, a range without deals
    v_txt := '';
    for r in select * from (values (date '2026-07-01', date '2026-07-31'), (date '2026-10-01', date '2026-10-30'),
                                   (date '2026-10-14', date '2026-10-30'), (date '2026-08-01', date '2026-08-31')) as g(f, t) loop
      select v_txt || format('%s:%s', to_char(r.f, 'MMDD'),
                             (select count(*) from cma.lead_deals_of(v_t1, r.f::timestamp at time zone 'Europe/Amsterdam',
                                                                     (r.t + 1)::timestamp at time zone 'Europe/Amsterdam'))) into v_txt;
      for j in select cma.lead_cohorts_report_of(v_t1, r.f, r.t, p.p, null, null, null, s.s, v_now)
               from (values (1, 'week'), (2, 'month')) p(o, p) cross join (values (1, 'none'), (2, 'market'), (3, 'source')) s(o, s)
               order by p.o, s.o loop
        v_txt := v_txt || '/' || (select coalesce(sum((c ->> 'created')::int), 0) from jsonb_array_elements(j -> 'cohorts') c)
                 || case when j ->> 'split' <> 'none' then '+' || (select coalesce(sum((c ->> 'created')::int), 0) from jsonb_array_elements(j -> 'rows') c) else '' end;
      end loop;
      v_txt := v_txt || ' ';
    end loop;
    v_rows := v_rows || array['14', 'B4 per range, period and split the created deals add up to cma.lead_deals_of''s count of the range',
      case when v_txt = '0701:4/4/4+4/4+4/4/4+4/4+4 1001:5/5/5+5/5+5/5/5+5/5+5 1014:3/3/3+3/3+3/3/3+3/3+3 0801:0/0/0+0/0+0/0/0+0/0+0 '
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B5. the figures per ISO week, newest first: July's week of the 6th at every age (attempted, conversation, ordered, lost),
    --     its not called yet, ordered now and median days to order; the week of the 13th; October's weeks mature at 1 and 7
    --     only, the current week at none
    j := cma.lead_cohorts_report_of(v_t1, date '2026-07-01', date '2026-07-31', 'week', null, null, null, 'none', v_now);
    v_txt := pg_temp.v0008zm_cohorts(j, 'cohorts');
    j := cma.lead_cohorts_report_of(v_t1, date '2026-10-01', date '2026-10-30', 'week', null, null, null, 'none', v_now);
    v_txt := v_txt || ' || ' || pg_temp.v0008zm_cohorts(j, 'cohorts');
    v_rows := v_rows || array['15', 'B5 the figures per week and age, newest first',
      case when v_txt = '2026-W29 1/1/0/- 1:0/0/0/0 7:0/0/0/0 30:0/0/0/0 60:0/0/0/0 90:0/0/0/0 | '
                        || '2026-W28 3/0/2/23.5 1:1/1/0/0 7:2/1/1/0 30:2/2/1/1 60:2/2/2/1 90:2/2/2/1 || '
                        || '2026-W44* 2/1/0/- 1:-/-/-/- 7:-/-/-/- 30:-/-/-/- 60:-/-/-/- 90:-/-/-/- | '
                        || '2026-W42 3/0/0/- 1:2/1/0/0 7:2/1/0/0 30:-/-/-/- 60:-/-/-/- 90:-/-/-/-'
            and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    -- B6. the ordered share at the largest age equals lead to order's share ordered within that age: 90 days (July by month,
    --     every deal 90 days old) and, with the ages 1,7,30, 30 days (dA2's order on day 45 out of both)
    j := cma.lead_cohorts_report_of(v_t1, date '2026-07-01', date '2026-07-31', 'month', null, null, null, 'none', v_now);
    select format('%s/%s=%s/%s', j -> 'cohorts' -> 0 -> 'ages' -> -1 ->> 'ordered', j -> 'cohorts' -> 0 ->> 'created',
                  count(*) filter (where l.order_created_at <= l.created_at + interval '90 days'), count(*))
      into v_txt
    from cma.lead_to_order_of(v_t1, timestamptz '2026-06-30 22:00:00+00', timestamptz '2026-07-31 22:00:00+00') l;
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('cohorts.lead_ages_days', '1,7,30');
    perform set_config('app.user_id', v_analyst1::text, true);
    j := cma.lead_cohorts_report_of(v_t1, date '2026-07-01', date '2026-07-31', 'month', null, null, null, 'none', v_now);
    select v_txt || format(' %s/%s=%s/%s', j -> 'cohorts' -> 0 -> 'ages' -> -1 ->> 'ordered', j -> 'cohorts' -> 0 ->> 'created',
                           count(*) filter (where l.order_created_at <= l.created_at + interval '30 days'), count(*))
      into v_txt
    from cma.lead_to_order_of(v_t1, timestamptz '2026-06-30 22:00:00+00', timestamptz '2026-07-31 22:00:00+00') l;
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('cohorts.lead_ages_days', null);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['16', 'B6 the ordered share at the largest age equals lead to order''s share ordered within that age',
      case when v_txt = '2/4=2/4 1/4=1/4' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    -- B7. an age the cohort has not reached: null figures and mature false (October by month: dC2 is three hours old; the
    --     week of 12 October from 30 days, its youngest deal 14 days old); an age it has reached counted, 0 where nothing
    --     happened (that week's orders at 1 and 7 days)
    j := cma.lead_cohorts_report_of(v_t1, date '2026-10-01', date '2026-10-30', 'month', null, null, null, 'none', v_now);
    v_txt := (select string_agg(format('%s:%s:%s', a ->> 'age', a ->> 'mature', coalesce(a ->> 'attempted', 'null')), ' ')
              from jsonb_array_elements(j -> 'cohorts' -> 0 -> 'ages') a);
    j := cma.lead_cohorts_report_of(v_t1, date '2026-10-01', date '2026-10-30', 'week', null, null, null, 'none', v_now);
    v_txt := v_txt || ' | ' || (select string_agg(format('%s:%s:%s', a ->> 'age', a ->> 'mature', coalesce(a ->> 'ordered', 'null')), ' ')
                                from jsonb_array_elements(j -> 'cohorts' -> 1 -> 'ages') a);
    v_rows := v_rows || array['17', 'B7 an age the cohort has not reached is null, one it has reached is counted',
      case when v_txt = '1:false:null 7:false:null 30:false:null 60:false:null 90:false:null | 1:true:0 7:true:0 30:false:null 60:false:null 90:false:null'
            and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    -- B8. a range that cuts a cohort: the week of 12 October from the 14th holds dB2 only and is partial, the current week
    --     runs past the range's end and is partial too; the keys, the periods' first and last days, the history start and the ages
    j := cma.lead_cohorts_report_of(v_t1, date '2026-10-14', date '2026-10-30', 'week', null, null, null, 'none', v_now);
    v_txt := (select string_agg(format('%s:%s..%s:%s:%s', c ->> 'key', c ->> 'start', c ->> 'end', c ->> 'partial', c ->> 'created'), ' ')
              from jsonb_array_elements(j -> 'cohorts') c)
             || ' ' || (j ->> 'history_start') || ' ' || (j ->> 'ages') || ' ' || (j ->> 'lead_to_order_days') || ' ' || (j ->> 'period');
    j := cma.lead_cohorts_report_of(v_t1, date '2026-07-01', date '2026-07-31', 'month', null, null, null, 'none', v_now);
    v_txt := v_txt || ' | ' || (select string_agg(format('%s:%s..%s:%s', c ->> 'label', c ->> 'start', c ->> 'end', c ->> 'partial'), ' ')
                                from jsonb_array_elements(j -> 'cohorts') c);
    v_rows := v_rows || array['18', 'B8 a range that cuts a cohort marks it partial and counts its deals in the range only',
      case when v_txt = '2026-10-26:2026-10-26..2026-11-01:true:2 2026-10-12:2026-10-12..2026-10-18:true:1 2026-06-01 [1, 7, 30, 60, 90] 90 week'
                        || ' | 2026-07:2026-07-01..2026-07-31:false'
            and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    -- B9. the splits: per market (unknown last) and per source channel (none last) within each week, the cohorts unsplit
    j := cma.lead_cohorts_report_of(v_t1, date '2026-07-01', date '2026-07-31', 'week', null, null, null, 'market', v_now);
    v_txt := pg_temp.v0008zm_cohorts(j, 'rows') || ' # ' || jsonb_array_length(j -> 'cohorts');
    j := cma.lead_cohorts_report_of(v_t1, date '2026-07-01', date '2026-07-31', 'week', null, null, null, 'source', v_now);
    v_txt := v_txt || ' || ' || (select string_agg(format('%s/%s:%s', c ->> 'label', coalesce(c ->> 'group', 'none'), c ->> 'created'), ' ')
                                 from jsonb_array_elements(j -> 'rows') c);
    v_rows := v_rows || array['19', 'B9 the splits per market and per source channel within each cohort',
      case when v_txt = '2026-W29/GB 1/1/0/- 1:0/0/0/0 7:0/0/0/0 30:0/0/0/0 60:0/0/0/0 90:0/0/0/0 | '
                        || '2026-W28/GB 1/0/0/- 1:0/0/0/0 7:0/0/0/0 30:0/0/0/1 60:0/0/0/1 90:0/0/0/1 | '
                        || '2026-W28/NL 2/0/2/23.5 1:1/1/0/0 7:2/1/1/0 30:2/2/1/0 60:2/2/2/0 90:2/2/2/0 # 2'
                        || ' || 2026-W29/none:1 2026-W28/Facebook:2 2026-W28/Google:1'
            and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    -- B10. the filters (market, source channel, pipeline) narrow the deals; the filter lists come from the deals without them
    v_txt := '';
    for j in select cma.lead_cohorts_report_of(v_t1, f.f, f.t, 'month', f.p, f.m, f.s, 'none', v_now)
             from (values (date '2026-07-01', date '2026-07-31', null, 'NL', null), (date '2026-07-01', date '2026-07-31', null, null, 'Facebook'),
                          (date '2026-10-01', date '2026-10-30', v_crm::text || ':sales', null, null),
                          (date '2026-10-01', date '2026-10-30', null, 'unknown', null)) as f(f, t, p, m, s) loop
      v_txt := v_txt || coalesce((j -> 'cohorts' -> 0 ->> 'created'), '0') || ' ';
    end loop;
    v_txt := v_txt || (j ->> 'markets') || ' ' || (select string_agg(p ->> 'label', ',') from jsonb_array_elements(j -> 'pipelines') p)
             || ' ' || (j ->> 'source_channels');
    v_rows := v_rows || array['20', 'B10 the market, source channel and pipeline filters, and the filter lists of the deals without them',
      case when v_txt = '2 2 4 0 ["GB", "NL"] Sales,Self Serve ["Facebook", "Google"]' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    -- B11. the setting: spaces dropped; refused (CMA04) out of order, empty, seven ages, not a number and above
    --      lead_to_order.max_days; lead_to_order.max_days refused below the largest age, accepted at it
    perform set_config('app.user_id', v_admin1::text, true);
    select value into v_txt from cma.set_tenant_setting('cohorts.lead_ages_days', ' 1, 7 ,30 ');
    v_txt := v_txt || ' ' || pg_temp.v0008zm_code('select cma.set_tenant_setting(''cohorts.lead_ages_days'', ''7,1'')')
             || ' ' || pg_temp.v0008zm_code('select cma.set_tenant_setting(''cohorts.lead_ages_days'', '''')')
             || ' ' || pg_temp.v0008zm_code('select cma.set_tenant_setting(''cohorts.lead_ages_days'', ''1,2,3,4,5,6,7'')')
             || ' ' || pg_temp.v0008zm_code('select cma.set_tenant_setting(''cohorts.lead_ages_days'', ''1,a'')')
             || ' ' || pg_temp.v0008zm_code('select cma.set_tenant_setting(''cohorts.lead_ages_days'', ''1,7,91'')')
             || ' ' || pg_temp.v0008zm_code('select cma.set_tenant_setting(''cohorts.lead_ages_days'', ''1,7,90'')')
             || ' ' || pg_temp.v0008zm_code('select cma.set_tenant_setting(''lead_to_order.max_days'', ''89'')')
             || ' ' || pg_temp.v0008zm_code('select cma.set_tenant_setting(''lead_to_order.max_days'', ''90'')');
    -- a statement of its own: the one above sees the writes made before it started, not those of the calls within it
    select v_txt || ' ' || s.value into v_txt from cma.tenant_settings() s where s.key = 'cohorts.lead_ages_days';
    perform cma.set_tenant_setting('cohorts.lead_ages_days', null);
    perform cma.set_tenant_setting('lead_to_order.max_days', null);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['21', 'B11 the setting''s spaces dropped and its refusals; lead_to_order.max_days no lower than the largest age',
      case when v_txt = '1,7,30 CMA04 CMA04 CMA04 CMA04 CMA04 ok CMA04 ok 1,7,90' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    -- B12. an age above lead_to_order.max_days (after lead_to_order.max_days is reset below it, which no check sees): the age
    --      is reached and counted, its ordered figure null
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('lead_to_order.max_days', '100');
    perform cma.set_tenant_setting('cohorts.lead_ages_days', '1,7,100');
    perform cma.set_tenant_setting('lead_to_order.max_days', null);
    perform set_config('app.user_id', v_analyst1::text, true);
    j := cma.lead_cohorts_report_of(v_t1, date '2026-07-01', date '2026-07-31', 'month', null, null, null, 'none', v_now);
    v_txt := pg_temp.v0008zm_cohorts(j, 'cohorts') || ' ' || (j ->> 'lead_to_order_days');
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('cohorts.lead_ages_days', null);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['22', 'B12 an age above lead_to_order.max_days is counted without its ordered figure',
      case when v_txt = '2026-07 4/1/2/23.5 1:1/1/0/0 7:2/1/1/0 100:2/2/-/1 90' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    -- B13. the parameters refused (CMA04): a period, a split, either left out, more than 92 days, a backward range, a market,
    --      a pipeline and a source channel out of form; the defaults accepted
    v_txt := pg_temp.v0008zm_code('select cma.lead_cohorts_report(''2026-10-01'', ''2026-10-30'', ''day'')')
             || ' ' || pg_temp.v0008zm_code('select cma.lead_cohorts_report(''2026-10-01'', ''2026-10-30'', ''week'', null, null, ''owner'')')
             || ' ' || pg_temp.v0008zm_code('select cma.lead_cohorts_report(''2026-10-01'', ''2026-10-30'', null)')
             || ' ' || pg_temp.v0008zm_code('select cma.lead_cohorts_report(''2026-10-01'', ''2026-10-30'', ''week'', null, null, null)')
             || ' ' || pg_temp.v0008zm_code('select cma.lead_cohorts_report(''2026-07-01'', ''2026-10-30'', ''month'')')
             || ' ' || pg_temp.v0008zm_code('select cma.lead_cohorts_report(''2026-10-30'', ''2026-10-01'', ''week'')')
             || ' ' || pg_temp.v0008zm_code('select cma.lead_cohorts_report(''2026-10-01'', ''2026-10-30'', ''week'', ''Netherlands'')')
             || ' ' || pg_temp.v0008zm_code('select cma.lead_cohorts_report(''2026-10-01'', ''2026-10-30'', ''week'', null, null, ''none'', ''sales'')')
             || ' ' || pg_temp.v0008zm_code('select cma.lead_cohorts_report(''2026-10-01'', ''2026-10-30'', ''week'', null, repeat(''x'', 101))')
             || ' ' || pg_temp.v0008zm_code('select cma.lead_cohorts_report(''2026-10-01'', ''2026-10-30'')')
             || ' ' || pg_temp.v0008zm_code(format('select cma.lead_cohorts_report(''2026-08-01'', ''2026-10-30'', ''month'', ''GB'', ''Facebook'', ''source'', %L)',
                                                   v_crm::text || ':sales'));
    v_rows := v_rows || array['23', 'B13 the parameters refused out of form; the defaults and a full set accepted',
      case when v_txt = 'CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 ok ok' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B14. who may read: an agent refused (CMA06), no acting user refused (CMA01); the analyst (reports.view) and the admin read
    perform set_config('app.user_id', v_agent1::text, true);
    v_txt := pg_temp.v0008zm_code('select cma.lead_cohorts_report(''2026-10-01'', ''2026-10-30'')');
    perform set_config('app.user_id', '', true);
    v_txt := v_txt || ' ' || pg_temp.v0008zm_code('select cma.lead_cohorts_report(''2026-10-01'', ''2026-10-30'')');
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008zm_code('select cma.lead_cohorts_report(''2026-10-01'', ''2026-10-30'')');
    perform set_config('app.user_id', v_analyst1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008zm_code('select cma.lead_cohorts_report(''2026-10-01'', ''2026-10-30'')');
    v_rows := v_rows || array['24', 'B14 an agent refused, no acting user refused; the analyst and the admin read',
      case when v_txt = 'CMA06 CMA01 ok ok' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B15. another tenant sees 0 rows: tenant two's analyst reads none of tenant one's deals (by tenant one's id, under
    --      row-level security) and its own report holds its one deal, never called
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_analyst2::text, true);
    select format('%s %s', (select count(*) from cma.lead_cohorts_of(v_t1, null, null, v_now)),
                  (select count(*) from cma.lead_cohorts_of(v_t2, null, null, v_now))) into v_txt;
    j := cma.lead_cohorts_report('2026-10-01', '2026-10-30');
    v_txt := v_txt || ' ' || (select string_agg(format('%s:%s/%s', c ->> 'label', c ->> 'created', c ->> 'not_called_yet'), ' ')
                              from jsonb_array_elements(j -> 'cohorts') c) || ' ' || (j ->> 'markets');
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['25', 'B15 another tenant sees 0 rows of tenant one, and its own deal only',
      case when v_txt = '0 1 2026-W42:1/1 ["unknown"]' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    -- B16. the reader view: scoped to tenant one, the application's rows since the intake start, column by column; scoped to
    --      tenant two none of tenant one's
    select string_agg(concat_ws('|', x.deal_id, x.connection_id, x.deal_source_id, x.pipeline_id, x.pipeline_label, x.market, x.source_channel,
                                x.created_at, x.business_date, x.week_start, x.month_start, x.age_days, x.attempts, x.first_attempt_at,
                                x.first_conversation_at, x.outcome, x.lost_at, x.order_created_at, x.days_to_order, x.not_called_yet), ';' order by x.deal_id)
      into v_app
    from cma.lead_cohorts_of(v_t1, null, null, now()) x;
    perform set_config('role', 'cma_readonly', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    select string_agg(concat_ws('|', x.deal_id, x.connection_id, x.deal_source_id, x.pipeline_id, x.pipeline_label, x.market, x.source_channel,
                                x.created_at, x.business_date, x.week_start, x.month_start, x.age_days, x.attempts, x.first_attempt_at,
                                x.first_conversation_at, x.outcome, x.lost_at, x.order_created_at, x.days_to_order, x.not_called_yet), ';' order by x.deal_id)
      into v_view
    from cma_read.lead_cohorts x where x.tenant_id = v_t1;
    select format('%s %s', (select count(*) from cma_read.lead_cohorts where tenant_id = v_t1), (v_view = v_app)::text) into v_txt;
    perform set_config('app.tenant_id', v_t2::text, true);
    select v_txt || format(' %s', (select count(*) from cma_read.lead_cohorts where tenant_id = v_t1)) into v_txt;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    v_rows := v_rows || array['26', 'B16 the reader view equals the application''s rows for its tenant and shows no other tenant''s',
      case when v_txt = '9 true 0' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['49', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008zm (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008zm values (49, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- The helpers are dropped first, so the verdict is the last thing the script prints
drop function if exists pg_temp.v0008zm_code(text);
drop function if exists pg_temp.v0008zm_cohorts(jsonb, text);
drop function if exists pg_temp.v0008zm_cohort(jsonb);

-- Verdict: one row per check, then the verdict: OK when all 22 checks pass
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008zm
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT OK'
                  when (select count(*) from verify_0008zm where result = 'PASS') = 22
                       and not exists (select 1 from verify_0008zm where result <> 'PASS') then 'OK'
                  else 'FAIL' end,
             format('121_verify_lead_cohorts: %s PASS, %s FAIL', (select count(*) from verify_0008zm where result = 'PASS'),
                                                                (select count(*) from verify_0008zm where result <> 'PASS'))) x
order by ord;
reset role;
