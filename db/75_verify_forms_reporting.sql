-- =============================================================================================
-- 75_verify_forms_reporting.sql: verifies addition 0008p, forms reporting
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure
-- and privileges; block B works on two throwaway tenants inside a subtransaction that is always
-- rolled back. Universal otherwise: nothing of the seed is used; adapters, forms, fields, options,
-- answers, contacts and submissions are invented data values, and no submission carries a name or an
-- address the database keeps. Every check writes one row, PASS or FAIL, and the last result lists them
-- with the verdict, because Cloud SQL Studio shows no notices. Run as your own IAM login in dev, after
-- 74_forms_reporting.sql; then 33, 41, 53, 69, 71 and 73 again.
--   A  structure and privileges: the addition row after 0008o; the two tables with row-level security,
--      the tenant policy, audit, no delete and a reader view each with its exact columns; the forms'
--      new columns with their default, checks and foreign key; the submissions' mark and its update
--      privilege; 0007's views with the new columns at the end; every function the application's
--      only, in the caller's rights, set_form's signature unchanged, no read returning a submission or
--      contact id; the data-quality lists (0007d's fifteen, 0008m's and 0008o's unchanged, the forms
--      list with its one check) and its reader view
--   B  behaviour. Tenant one (Europe/Amsterdam; markets NL, GB in Europe/London and DE; aliases for
--      united kingdom and netherlands; four categories) holds a CRM connection whose catalog brings four
--      forms: a Contact form (an email field, a radio are_you_already_a_customer, a message), a
--      Cancellation form (a dropdown cancellation_reason, a dropdown country_dropdown, an iban field),
--      a General support form (multiple checkboxes hs_ticket_category, a single checkbox) and a form
--      the source does not describe (0007's rule). Tenant two holds nothing of it, for isolation.
--      Checked: a form found by the catalog is counted and polled, its fields kept with kinds and
--      options; polled apart from counted; kept fields choice fields of a described form, names of one
--      not described; the refusals of the configuration; answers kept only within the options, never
--      free text or a bank field; a stored submission's empty answers filled once, never after a
--      privacy deletion; a support form polled and not counted changing no intake or lead-metrics
--      read; the lead rule on Intake's form count; the market of a submission by each step; business
--      dates in the market's zone, days and weeks; the previous period like for like; the answers per
--      field and value; the filters and their refusals; the history start; the field catalog's second
--      refresh (an option retired and back, a field archived) with the data-quality check finding a
--      value kept before the form was described; the permissions; tenant isolation; a run's counts
--      taking dropped
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
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 75 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0008p;
create temp table verify_0008p (ord int, check_name text, result text, detail text);

-- One submission as the ingest write takes it
create or replace function pg_temp.v0008p_sub(p_src text, p_form text, p_at timestamptz, p_kept jsonb, p_contact text default null)
returns jsonb
language sql immutable
as $$
  select jsonb_build_object('sourceId', p_src, 'formId', p_form, 'submittedAt', p_at, 'keptValues', p_kept)
         || case when p_contact is null then jsonb_build_object('contactResolution', 'not_found')
                 else jsonb_build_object('contactId', p_contact) end
$$;

-- The error code a statement raises, or 'ok'
create or replace function pg_temp.v0008p_code(p_sql text)
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
  v_bad     text;
  v_t       text;
  v_fn      text;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  -- A1. the addition is recorded, after 0008o
  insert into verify_0008p values (1, 'A1 addition 0008p recorded, after 0008o',
    case when exists (select 1 from cma.schema_migration where version = '0008p')
              and exists (select 1 from cma.schema_migration where version = '0008o') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the two tables: row-level security, the tenant policy, audit, never deleted by the application;
  --     a reader view each with its exact columns, readers seeing the view and never the table
  v_bad := '';
  foreach v_t in array array['form_category', 'connection_form_field'] loop
    if to_regclass('cma.' || v_t) is null then
      v_bad := v_bad || v_t || ' missing; ';
      continue;
    end if;
    if not (select relrowsecurity from pg_class where oid = to_regclass('cma.' || v_t))
       or not exists (select 1 from pg_policy where polrelid = to_regclass('cma.' || v_t) and polname = 'tenant_app')
       or not exists (select 1 from pg_trigger where tgrelid = to_regclass('cma.' || v_t) and tgname = 'audit') then
      v_bad := v_bad || v_t || ' lacks row-level security, its policy or audit; ';
    end if;
    if has_table_privilege('cma_app', 'cma.' || v_t, 'delete') or not has_table_privilege('cma_app', 'cma.' || v_t, 'insert') then
      v_bad := v_bad || 'the application deletes from or cannot insert into ' || v_t || '; ';
    end if;
    if not has_table_privilege('cma_readonly', 'cma_read.' || v_t, 'select') or has_table_privilege('cma_readonly', 'cma.' || v_t, 'select') then
      v_bad := v_bad || 'readers do not see cma_read.' || v_t || ' alone; ';
    end if;
  end loop;
  if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'form_category')
     is distinct from 'id,tenant_id,code,name,sort_order,status,created_at,updated_at' then
    v_bad := v_bad || 'cma_read.form_category columns; ';
  end if;
  if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'connection_form_field')
     is distinct from 'tenant_id,connection_id,source_form_id,name,kind,options,retired_options,sort_order,status,refreshed_at,updated_at' then
    v_bad := v_bad || 'cma_read.connection_form_field columns; ';
  end if;
  insert into verify_0008p values (2, 'A2 two tenant tables with row-level security, audit, no delete and reader views',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A3. the forms' new columns: is_polled not null, default true, and a counted form polled (a check);
  --     the category's foreign key; the market field and lead condition checks; the submissions' mark
  --     with its update privilege and the answers' check; 0007's views with the new columns at the end
  v_bad := '';
  if (select is_nullable || ':' || column_default from information_schema.columns
      where table_schema = 'cma' and table_name = 'connection_form' and column_name = 'is_polled') is distinct from 'NO:true' then
    v_bad := v_bad || 'is_polled not null default true; ';
  end if;
  foreach v_t in array array['connection_form_polled_check', 'connection_form_category_fkey', 'connection_form_market_field_check',
                             'connection_form_lead_condition_check'] loop
    if not exists (select 1 from pg_constraint where conrelid = 'cma.connection_form'::regclass and conname = v_t) then
      v_bad := v_bad || v_t || ' missing; ';
    end if;
  end loop;
  if not exists (select 1 from pg_constraint where conrelid = 'cma.form_submission'::regclass and conname = 'form_submission_kept_values_check')
     or not has_column_privilege('cma_app', 'cma.form_submission', 'kept_cleared_at', 'update')
     or has_column_privilege('cma_app', 'cma.form_submission', 'source_form_id', 'update') then
    v_bad := v_bad || 'form_submission mark, check or privileges; ';
  end if;
  if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'connection_form')
     is distinct from 'tenant_id,connection_id,source_form_id,name,is_counted,lead_source,market,kept_fields,status,refreshed_at,is_polled,category,market_field,lead_condition,fields_refreshed_at' then
    v_bad := v_bad || 'cma_read.connection_form columns; ';
  end if;
  if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'form_submission')
     is distinct from 'id,tenant_id,connection_id,source_id,source_form_id,submitted_at,page_host,page_path,utm,contact_source_id,contact_resolution,kept_values,synced_at,kept_cleared_at' then
    v_bad := v_bad || 'cma_read.form_submission columns; ';
  end if;
  insert into verify_0008p values (3, 'A3 forms polled apart from counted, category, market field, lead rule, the submissions'' mark',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A4. every function the application's only, in the caller's rights; set_form's signature as 0007's;
  --     no read returns a submission id or a contact id
  v_bad := '';
  foreach v_fn in array array[
    'cma.set_form(uuid,text,boolean,text,text,text[])', 'cma.set_form_reporting(uuid,text,boolean,text,text)',
    'cma.set_form_market_field(uuid,text,text)', 'cma.set_form_lead_condition(uuid,text,text,text[])',
    'cma.set_form_category(text,text,integer)', 'cma.set_form_category_status(text,text)', 'cma.form_categories()',
    'cma.connection_catalogs(uuid)', 'cma.ingest_upsert_forms(uuid,jsonb)', 'cma.ingest_upsert_form_submissions(uuid,jsonb)',
    'cma.ingest_contact_forget(uuid,text)', 'cma.intake_per_day_of(uuid,timestamptz,timestamptz)',
    'cma.form_submissions_of(uuid,timestamptz,timestamptz)', 'cma.forms_figures_of(uuid,date,date,text,text,text,text,timestamptz)',
    'cma.forms_previous_of(uuid,date,date,timestamptz)', 'cma.forms_report_of(uuid,date,date,text,text,text,text,timestamptz)',
    'cma.forms_answers_of(uuid,date,date,text,text,text,text,text,timestamptz)', 'cma.forms_history_start_of(uuid)',
    'cma.forms_filters_check(text,text,text,text,text)', 'cma.forms_report(date,date,text,text,text,text)',
    'cma.forms_answers(date,date,text,text,text,text,text)', 'cma.forms_history_start()',
    'cma.data_quality_of(uuid)', 'cma.data_quality()', 'cma.data_quality_forms_checks()',
    'cma.form_choice_kind(text)', 'cma.form_options_ok(text[])', 'cma.form_kept_values_ok(jsonb)', 'cma.form_lead_condition_ok(jsonb)',
    'cma.form_answer_of(text,text[],jsonb)', 'cma.form_kept_values_of(uuid,uuid,text,jsonb)', 'cma.form_is_lead(jsonb,jsonb)',
    'cma.form_submission_market_of(uuid,uuid,text,text,jsonb,text)', 'cma.form_kept_fields_check(uuid,text,text[])'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' is missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                     where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      v_bad := v_bad || v_fn || ' is not the application''s only, in the caller''s rights; ';
    end if;
  end loop;
  if (select count(*) from pg_proc where pronamespace = 'cma'::regnamespace and proname = 'set_form') <> 1 then
    v_bad := v_bad || 'set_form has another signature; ';
  end if;
  if exists (select 1 from pg_proc p, unnest(p.proargnames) n
             where p.pronamespace = 'cma'::regnamespace
               and p.proname in ('forms_report', 'forms_answers', 'forms_report_of', 'forms_answers_of', 'forms_figures_of', 'form_submissions_of')
               and (n in ('source_id', 'contact_source_id', 'submission_id', 'contact_id') or (n like '%email%' and n <> 'no_email'))) then
    v_bad := v_bad || 'a read returns a submission or contact id; ';
  end if;
  insert into verify_0008p values (4, 'A4 functions the application''s only, in the caller''s rights; no submission or contact id read',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A5. data quality: 0007d's fifteen checks, 0008m's and 0008o's lists unchanged, the forms list with its
  --     one check, data_quality() reading it, and its reader view with the dq_ columns
  v_bad := '';
  if (select count(*) from cma.data_quality_checks()) <> 15 then v_bad := v_bad || 'data_quality_checks is not fifteen; '; end if;
  if (select string_agg(check_key, ',') from cma.data_quality_added_checks()) is distinct from 'contact_country_fallback' then
    v_bad := v_bad || 'data_quality_added_checks changed; ';
  end if;
  if (select string_agg(check_key, ',' order by sort_order) from cma.data_quality_follow_up_checks())
     is distinct from 'ticket_no_owner,ticket_no_market,crm_task_owner_unlinked' then
    v_bad := v_bad || 'data_quality_follow_up_checks changed; ';
  end if;
  if (select string_agg(check_key || ':' || sort_order, ',') from cma.data_quality_forms_checks()) is distinct from 'form_answer_not_in_options:200' then
    v_bad := v_bad || 'data_quality_forms_checks; ';
  end if;
  if pg_get_functiondef('cma.data_quality()'::regprocedure) not like '%data_quality_forms_checks%' then
    v_bad := v_bad || 'data_quality() does not read the forms checks; ';
  end if;
  if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'dq_form_answer_not_in_options')
     is distinct from 'tenant_id,connection_id,object_type,object_id,value'
     or not has_table_privilege('cma_readonly', 'cma_read.dq_form_answer_not_in_options', 'select') then
    v_bad := v_bad || 'dq_form_answer_not_in_options; ';
  end if;
  insert into verify_0008p values (5, 'A5 data quality: earlier lists unchanged, the forms check apart with its view',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);
end
$$;

-- B. Behaviour on two throwaway tenants (rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_rows     text[] := '{}';
  v_t1 uuid; v_t2 uuid;
  v_admin1 uuid; v_agent1 uuid; v_analyst1 uuid; v_reader1 uuid; v_ing1 uuid;
  v_admin2 uuid; v_analyst2 uuid; v_ing2 uuid;
  v_crm uuid; v_crm2 uuid;
  v_role uuid;
  v_txt text; v_txt2 text; v_detail text;
  v_ok boolean;
  v_n integer;
  v_j jsonb;
  v_d date;
  v_before text; v_after text;
  v_now_running timestamptz := timestamptz '2026-10-07 14:30:00+00';   -- Wednesday 7 October, 16:30 in Amsterdam
  v_now_after   timestamptz := timestamptz '2026-10-20 09:00:00+00';
  v_now_before  timestamptz := timestamptz '2026-10-01 09:00:00+00';
  v_yes text := 'Yes, I''m an existing Customer';
  v_no  text := 'No, I''m not a customer yet';
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    v_t1 := cma.create_tenant('verify-0008p-one', 'Verify 0008p one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008p-two', 'Verify 0008p two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent1@example.invalid', 'agent1') returning id into v_agent1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-analyst1@example.invalid', 'analyst1') returning id into v_analyst1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-reader1@example.invalid', 'reader1') returning id into v_reader1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin2') returning id into v_admin2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-analyst2@example.invalid', 'analyst2') returning id into v_analyst2;
    -- a role with reports.view only (no default role has it without performance.team)
    insert into cma.app_role (tenant_id, key, name) values (v_t1, 'verify_reader', 'Verify reader') returning id into v_role;
    insert into cma.role_permission (tenant_id, role_id, permission_key) values (v_t1, v_role, 'reports.view');
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_agent1, 'agent'), (v_t1, v_analyst1, 'analytics'), (v_t1, v_reader1, 'verify_reader'),
                 (v_t2, v_admin2, 'admin'), (v_t2, v_analyst2, 'analytics')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    select x.user_id into v_ing2 from cma.app_user_external_id x where x.tenant_id = v_t2 and x.system = 'ingest';
    perform set_config('role', 'cma_app', true);

    -- tenant one: markets, aliases, the intake start, categories and a CRM connection
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP');
    perform cma.upsert_market('DE', 'Germany', 'Europe/Berlin', 'de', 'EUR');
    perform cma.set_market_alias('united kingdom', 'GB');
    perform cma.set_market_alias('netherlands', 'NL');
    perform cma.set_tenant_setting('intake.start_date', '2026-09-01');
    perform cma.set_form_category('contact', 'Contact', 10);
    perform cma.set_form_category('cancellation', 'Cancellation', 20);
    perform cma.set_form_category('support', 'Support', 30);
    perform cma.set_form_category('old', 'Old', 40);
    select c.connection_id into v_crm from cma.upsert_connection('verifycrm', 'Verify forms', 'portal-1', null, null) c;
    -- tenant two: a connection of its own
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    select c.connection_id into v_crm2 from cma.upsert_connection('verifycrm', 'Verify forms two', 'portal-2', null, null) c;

    -- B1. the catalog: four forms found, counted and polled (0007's default); the fields of the three the
    --     source describes, with kinds and options (duplicates once, none for a field that is no choice);
    --     the fourth not described
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_ing1::text, true);
    v_n := cma.ingest_upsert_forms(v_crm, jsonb_build_array(
      jsonb_build_object('formId', 'f-contact', 'name', 'NL Contact', 'fields', jsonb_build_array(
        jsonb_build_object('name', 'email', 'kind', 'other'),
        jsonb_build_object('name', 'are_you_already_a_customer', 'kind', 'radio', 'options', jsonb_build_array(v_yes, v_no, v_yes)),
        jsonb_build_object('name', 'message', 'kind', 'other', 'options', jsonb_build_array('ignored')))),
      jsonb_build_object('formId', 'f-cancel', 'name', 'Cancellation', 'fields', jsonb_build_array(
        jsonb_build_object('name', 'cancellation_reason', 'kind', 'dropdown', 'options', jsonb_build_array('Moving', 'Price', 'Other')),
        jsonb_build_object('name', 'country_dropdown', 'kind', 'dropdown', 'options', jsonb_build_array('United Kingdom', 'Netherlands', 'Atlantis')),
        jsonb_build_object('name', 'iban', 'kind', 'other'))),
      jsonb_build_object('formId', 'f-support', 'name', 'General support', 'fields', jsonb_build_array(
        jsonb_build_object('name', 'hs_ticket_category', 'kind', 'multiple_checkboxes', 'options', jsonb_build_array('Billing', 'Device', 'Delivery')),
        jsonb_build_object('name', 'consent', 'kind', 'single_checkbox', 'options', jsonb_build_array('true', 'false')))),
      jsonb_build_object('formId', 'f-legacy', 'name', 'Legacy form')));
    perform set_config('role', 'cma_owner', true);
    select string_agg(format('%s:%s/%s/%s', f.source_form_id, f.is_counted::text, f.is_polled::text, (f.fields_refreshed_at is not null)::text), ' '
                      order by f.source_form_id) into v_txt
    from cma.connection_form f where f.tenant_id = v_t1;
    select string_agg(format('%s.%s=%s%s', ff.source_form_id, ff.name, ff.kind, coalesce(':' || array_to_string(ff.options, '|'), '')), ' '
                      order by ff.source_form_id, ff.sort_order) into v_txt2
    from cma.connection_form_field ff where ff.tenant_id = v_t1;
    perform set_config('role', 'cma_app', true);
    v_detail := v_n || ' | ' || v_txt || ' | ' || v_txt2;
    v_rows := v_rows || array['11', 'B1 the catalog: found forms counted and polled, fields with kinds and options',
      case when v_n = 4
            and v_txt = 'f-cancel:true/true/true f-contact:true/true/true f-legacy:true/true/false f-support:true/true/true'
            and v_txt2 = 'f-cancel.cancellation_reason=dropdown:Moving|Price|Other f-cancel.country_dropdown=dropdown:United Kingdom|Netherlands|Atlantis f-cancel.iban=other: f-contact.email=other: f-contact.are_you_already_a_customer=radio:' || v_yes || '|' || v_no
                         || ' f-contact.message=other: f-support.hs_ticket_category=multiple_checkboxes:Billing|Device|Delivery f-support.consent=single_checkbox:true|false'
            and not v_provoke then 'PASS' else 'FAIL' end, v_detail];

    -- B2. polled apart from counted: not counted keeps polled; set_form_reporting switches polled off; a
    --     counted form cannot be switched off (CMA03), and the table refuses it on any path
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_form(v_crm, 'f-cancel', false, null, null, array['cancellation_reason', 'country_dropdown']);
    v_txt := (select format('%s/%s', is_counted::text, is_polled::text) from cma.connection_form where connection_id = v_crm and source_form_id = 'f-cancel');
    perform cma.set_form_reporting(v_crm, 'f-cancel', false, 'cancellation', null);
    v_txt := v_txt || ' ' || (select format('%s/%s/%s', is_counted::text, is_polled::text, category) from cma.connection_form where connection_id = v_crm and source_form_id = 'f-cancel');
    perform cma.set_form(v_crm, 'f-new', false, null, null, null);
    v_txt := v_txt || ' new:' || (select format('%s/%s', is_counted::text, is_polled::text) from cma.connection_form where connection_id = v_crm and source_form_id = 'f-new');
    perform cma.set_form(v_crm, 'f-new', true, null, null, null);
    v_txt := v_txt || ' ' || (select format('%s/%s', is_counted::text, is_polled::text) from cma.connection_form where connection_id = v_crm and source_form_id = 'f-new');
    v_txt := v_txt || ' ' || pg_temp.v0008p_code(format('select cma.set_form_reporting(%L, ''f-new'', false, null, null)', v_crm));
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || ' ' || pg_temp.v0008p_code(format('update cma.connection_form set is_polled = false where connection_id = %L and source_form_id = ''f-new''', v_crm));
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['12', 'B2 polled apart from counted; a counted form always polled',
      case when v_txt = 'false/true false/false/cancellation new:false/false true/true CMA03 23514' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B3. kept fields: of a described form only its choice fields (a text field CMA04); of a form not
    --     described the names (0007's rule); a field the market field uses stays kept (CMA03)
    v_txt := pg_temp.v0008p_code(format('select cma.set_form(%L, ''f-contact'', true, ''contact'', ''NL'', array[''email'', ''are_you_already_a_customer''])', v_crm));
    v_txt := v_txt || ' ' || pg_temp.v0008p_code(format('select cma.set_form(%L, ''f-contact'', true, ''contact'', ''NL'', array[''are_you_already_a_customer''])', v_crm));
    v_txt := v_txt || ' ' || pg_temp.v0008p_code(format('select cma.set_form(%L, ''f-legacy'', false, null, null, array[''product'', ''notes''])', v_crm));
    perform cma.set_form_market_field(v_crm, 'f-cancel', 'country_dropdown');
    v_txt := v_txt || ' ' || pg_temp.v0008p_code(format('select cma.set_form(%L, ''f-cancel'', false, null, null, array[''cancellation_reason''])', v_crm));
    perform cma.set_form(v_crm, 'f-support', false, null, null, array['hs_ticket_category']);
    perform cma.set_form_reporting(v_crm, 'f-support', true, 'support', null);
    perform cma.set_form_reporting(v_crm, 'f-contact', true, 'contact', 'NL');
    v_txt := v_txt || ' ' || (select string_agg(format('%s=%s', source_form_id, array_to_string(kept_fields, '|')), ' ' order by source_form_id)
                              from cma.connection_form where connection_id = v_crm and source_form_id in ('f-contact', 'f-legacy', 'f-cancel'));
    v_rows := v_rows || array['13', 'B3 kept fields: choice fields of a described form, names of one not described',
      case when v_txt = 'CMA04 ok ok CMA03 f-cancel=cancellation_reason|country_dropdown f-contact=are_you_already_a_customer f-legacy=notes|product'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B4. refusals: an unknown category or market CMA02, a switched-off category for a form without it
    --     CMA04 (kept on a form that has it), another tenant's connection CMA02, the Ingest user and an
    --     agent CMA06; category codes and names CMA04, an unknown category's status CMA02, a status CMA04
    perform cma.set_form_reporting(v_crm, 'f-legacy', false, 'old', null);
    perform cma.set_form_category_status('old', 'inactive');
    v_txt := pg_temp.v0008p_code(format('select cma.set_form_reporting(%L, ''f-legacy'', true, ''nothing'', null)', v_crm))
      || ' ' || pg_temp.v0008p_code(format('select cma.set_form_reporting(%L, ''f-legacy'', true, ''old'', ''FR'')', v_crm))
      || ' ' || pg_temp.v0008p_code(format('select cma.set_form_reporting(%L, ''f-support'', true, ''old'', null)', v_crm))
      || ' ' || pg_temp.v0008p_code(format('select cma.set_form_reporting(%L, ''f-legacy'', true, ''old'', null)', v_crm))
      || ' ' || pg_temp.v0008p_code('select cma.set_form_category(''none'', ''None'', 1)')
      || ' ' || pg_temp.v0008p_code('select cma.set_form_category(''Bad Code'', ''Bad'', 1)')
      || ' ' || pg_temp.v0008p_code('select cma.set_form_category(''empty'', ''  '', 1)')
      || ' ' || pg_temp.v0008p_code('select cma.set_form_category_status(''nothing'', ''active'')')
      || ' ' || pg_temp.v0008p_code('select cma.set_form_category_status(''old'', ''gone'')');
    perform set_config('app.user_id', v_ing1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008p_code(format('select cma.set_form_reporting(%L, ''f-legacy'', true, null, null)', v_crm));
    perform set_config('app.user_id', v_agent1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008p_code(format('select cma.set_form_reporting(%L, ''f-legacy'', true, null, null)', v_crm))
      || ' ' || pg_temp.v0008p_code('select cma.set_form_category(''agentcat'', ''Agent'', 1)');
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008p_code(format('select cma.set_form_reporting(%L, ''f-legacy'', true, null, null)', v_crm));
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    v_rows := v_rows || array['14', 'B4 refusals of the reporting and the categories',
      case when v_txt = 'CMA02 CMA02 CMA04 ok CMA04 CMA04 CMA04 CMA02 CMA04 CMA06 CMA06 CMA06 CMA02' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];
    perform cma.set_form_reporting(v_crm, 'f-legacy', false, null, null);

    -- B5. the market field and the lead condition: a field not kept CMA04, multiple checkboxes as market
    --     field CMA04, a value that is no option CMA04, an unknown form CMA02; set and cleared
    v_txt := pg_temp.v0008p_code(format('select cma.set_form_market_field(%L, ''f-cancel'', ''iban'')', v_crm))
      || ' ' || pg_temp.v0008p_code(format('select cma.set_form_market_field(%L, ''f-support'', ''hs_ticket_category'')', v_crm))
      || ' ' || pg_temp.v0008p_code(format('select cma.set_form_lead_condition(%L, ''f-contact'', ''are_you_already_a_customer'', array[''Maybe''])', v_crm))
      || ' ' || pg_temp.v0008p_code(format('select cma.set_form_lead_condition(%L, ''f-contact'', ''email'', array[''x''])', v_crm))
      || ' ' || pg_temp.v0008p_code(format('select cma.set_form_lead_condition(%L, ''f-none'', ''x'', array[''x''])', v_crm))
      || ' ' || pg_temp.v0008p_code(format('select cma.set_form_market_field(%L, ''f-none'', null)', v_crm));
    perform cma.set_form_lead_condition(v_crm, 'f-contact', 'are_you_already_a_customer', array[v_no, v_no]);
    v_txt := v_txt || ' ' || (select lead_condition::text from cma.connection_form where connection_id = v_crm and source_form_id = 'f-contact');
    perform cma.set_form_lead_condition(v_crm, 'f-contact', null, null);
    v_txt := v_txt || ' ' || coalesce((select lead_condition::text from cma.connection_form where connection_id = v_crm and source_form_id = 'f-contact'), 'cleared');
    v_rows := v_rows || array['15', 'B5 market field and lead condition: refusals, set and cleared',
      case when v_txt = 'CMA04 CMA04 CMA04 CMA04 CMA02 CMA02 {"field": "are_you_already_a_customer", "values": ["' || v_no || '"]} cleared'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B6. answers kept only within the options: a radio and dropdowns, multiple checkboxes sorted and each
    --     once; a value no option accounts for dropped (the answer alone); free text, an email and a bank
    --     field never kept; a form not described keeps its kept fields by name (0007), an empty one left out
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_form_submissions(v_crm, jsonb_build_array(
      pg_temp.v0008p_sub('s-c1', 'f-contact', timestamptz '2026-10-05 09:00:00+00',
                         jsonb_build_object('are_you_already_a_customer', v_no, 'email', 'someone@example.com', 'message', 'free text')),
      pg_temp.v0008p_sub('s-c2', 'f-contact', timestamptz '2026-10-06 10:00:00+00', jsonb_build_object('are_you_already_a_customer', v_yes)),
      pg_temp.v0008p_sub('s-c3', 'f-contact', timestamptz '2026-10-07 14:00:00+00', '{}'::jsonb),
      pg_temp.v0008p_sub('s-c4', 'f-contact', timestamptz '2026-09-28 09:00:00+00', jsonb_build_object('are_you_already_a_customer', v_no)),
      pg_temp.v0008p_sub('s-c5', 'f-contact', timestamptz '2026-09-30 13:00:00+00', jsonb_build_object('are_you_already_a_customer', v_no)),
      pg_temp.v0008p_sub('s-c6', 'f-contact', timestamptz '2026-09-30 16:00:00+00', jsonb_build_object('are_you_already_a_customer', v_yes)),
      pg_temp.v0008p_sub('s-c7', 'f-contact', timestamptz '2026-10-01 22:30:00+00', jsonb_build_object('are_you_already_a_customer', 'Perhaps')),
      pg_temp.v0008p_sub('s-c8', 'f-contact', timestamptz '2026-09-20 22:10:00+00', jsonb_build_object('are_you_already_a_customer', v_no)),
      pg_temp.v0008p_sub('s-t1', 'f-support', timestamptz '2026-10-05 10:00:00+00',
                         jsonb_build_object('hs_ticket_category', jsonb_build_array('Device', 'Billing', 'Device'), 'consent', 'true')),
      pg_temp.v0008p_sub('s-t2', 'f-support', timestamptz '2026-10-06 10:00:00+00', jsonb_build_object('hs_ticket_category', jsonb_build_array('Device'))),
      pg_temp.v0008p_sub('s-t3', 'f-support', timestamptz '2026-10-06 11:00:00+00',
                         jsonb_build_object('hs_ticket_category', jsonb_build_array('Device', 'Unknown'))),
      pg_temp.v0008p_sub('s-l1', 'f-legacy', timestamptz '2026-10-02 10:00:00+00',
                         jsonb_build_object('product', 'aed plus', 'notes', '', 'email', 'someone@example.com'))));
    select string_agg(source_id || '=' || kept_values::text, ' ' order by source_id) into v_txt
    from cma.form_submission where connection_id = v_crm and source_id in ('s-c1', 's-c3', 's-c7', 's-l1', 's-t1', 's-t2', 's-t3');
    v_rows := v_rows || array['16', 'B6 answers kept within the options only; free text and bank fields never',
      case when v_txt = 's-c1={"are_you_already_a_customer": "' || v_no || '"} s-c3={} s-c7={} s-l1={"product": "aed plus"} s-t1={"hs_ticket_category": ["Billing", "Device"]} s-t2={"hs_ticket_category": ["Device"]} s-t3={}'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B7. a stored submission's empty answers are filled once (filled), never overwritten (known); a
    --     privacy deletion clears and marks the contact's submissions (its answer as 0008n's), and a
    --     later read fills nothing
    select string_agg(u.outcome, ',' order by u.source_id) into v_txt
    from cma.ingest_upsert_form_submissions(v_crm, jsonb_build_array(
      pg_temp.v0008p_sub('s-f1', 'f-support', timestamptz '2026-10-05 11:00:00+00', '{}'::jsonb),
      pg_temp.v0008p_sub('s-f2', 'f-support', timestamptz '2026-10-05 12:00:00+00', '{}'::jsonb, 'c-forget'),
      pg_temp.v0008p_sub('s-f3', 'f-support', timestamptz '2026-10-05 12:30:00+00', jsonb_build_object('hs_ticket_category', jsonb_build_array('Billing')), 'c-forget'))) u;
    select v_txt || ' ' || string_agg(u.outcome, ',' order by u.source_id) into v_txt
    from cma.ingest_upsert_form_submissions(v_crm, jsonb_build_array(
      pg_temp.v0008p_sub('s-f1', 'f-support', timestamptz '2026-10-05 11:00:00+00', jsonb_build_object('hs_ticket_category', jsonb_build_array('Delivery'))))) u;
    select v_txt || ' ' || string_agg(u.outcome, ',' order by u.source_id) into v_txt
    from cma.ingest_upsert_form_submissions(v_crm, jsonb_build_array(
      pg_temp.v0008p_sub('s-f1', 'f-support', timestamptz '2026-10-05 11:00:00+00', jsonb_build_object('hs_ticket_category', jsonb_build_array('Billing'))))) u;
    v_txt := v_txt || ' ' || cma.ingest_contact_forget(v_crm, 'c-forget')::text;
    select v_txt || ' ' || string_agg(u.outcome, ',' order by u.source_id) into v_txt
    from cma.ingest_upsert_form_submissions(v_crm, jsonb_build_array(
      pg_temp.v0008p_sub('s-f2', 'f-support', timestamptz '2026-10-05 12:00:00+00', jsonb_build_object('hs_ticket_category', jsonb_build_array('Device')), 'c-forget'),
      pg_temp.v0008p_sub('s-f3', 'f-support', timestamptz '2026-10-05 12:30:00+00', jsonb_build_object('hs_ticket_category', jsonb_build_array('Device')), 'c-forget'))) u;
    select v_txt || ' ' || string_agg(source_id || '=' || kept_values::text || '/' || (kept_cleared_at is not null)::text, ' ' order by source_id) into v_txt
    from cma.form_submission where connection_id = v_crm and source_id in ('s-f1', 's-f2', 's-f3');
    v_rows := v_rows || array['17', 'B7 empty answers filled once, never overwritten, never after a privacy deletion',
      case when v_txt = 'inserted,inserted,inserted filled known {"refs": 0, "calls": 0, "contacts": 0, "submissions": 1} known,known '
                        || 's-f1={"hs_ticket_category": ["Delivery"]}/false s-f2={}/true s-f3={}/true'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B8. a support form polled and not counted changes no intake or lead-metrics read: intake per day,
    --     speed to lead, lead to order and data quality alike before it is polled and after its
    --     submissions arrive
    perform set_config('app.user_id', v_analyst1::text, true);
    select coalesce((select string_agg(r::text, ';' order by r.business_date, r.market)
                     from cma.intake_per_day_of(v_t1, timestamptz '2026-09-01 00:00+00', timestamptz '2026-11-01 00:00+00') r), '-')
           || '|' || coalesce((select string_agg(r::text, ';' order by r::text) from cma.speed_to_lead_of(v_t1, timestamptz '2026-09-01 00:00+00', timestamptz '2026-11-01 00:00+00') r), '-')
           || '|' || coalesce((select string_agg(r::text, ';' order by r::text) from cma.lead_to_order_of(v_t1, timestamptz '2026-09-01 00:00+00', timestamptz '2026-11-01 00:00+00') r), '-')
           || '|' || coalesce((select string_agg(q.check_key || ':' || coalesce(q.total::text, '-'), ',') from cma.data_quality() q), '-')
      into v_before;
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_form_reporting(v_crm, 'f-cancel', true, 'cancellation', null);
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_form_submissions(v_crm, jsonb_build_array(
      pg_temp.v0008p_sub('s-x1', 'f-cancel', timestamptz '2026-10-01 22:30:00+00',
                         jsonb_build_object('cancellation_reason', 'Moving', 'country_dropdown', 'United Kingdom')),
      pg_temp.v0008p_sub('s-x2', 'f-cancel', timestamptz '2026-10-05 12:00:00+00',
                         jsonb_build_object('cancellation_reason', 'Price', 'country_dropdown', 'Atlantis'), 'c-de'),
      pg_temp.v0008p_sub('s-x3', 'f-cancel', timestamptz '2026-10-05 13:00:00+00',
                         jsonb_build_object('cancellation_reason', 'Price', 'country_dropdown', 'Atlantis')),
      pg_temp.v0008p_sub('s-x4', 'f-cancel', timestamptz '2026-10-06 13:00:00+00',
                         jsonb_build_object('cancellation_reason', 'I want out', 'iban', 'NL91TEST0000000000', 'country_dropdown', 'Netherlands')),
      pg_temp.v0008p_sub('s-x5', 'f-cancel', timestamptz '2026-09-20 22:30:00+00',
                         jsonb_build_object('cancellation_reason', 'Other', 'country_dropdown', 'United Kingdom'))));
    perform set_config('app.user_id', v_analyst1::text, true);
    select coalesce((select string_agg(r::text, ';' order by r.business_date, r.market)
                     from cma.intake_per_day_of(v_t1, timestamptz '2026-09-01 00:00+00', timestamptz '2026-11-01 00:00+00') r), '-')
           || '|' || coalesce((select string_agg(r::text, ';' order by r::text) from cma.speed_to_lead_of(v_t1, timestamptz '2026-09-01 00:00+00', timestamptz '2026-11-01 00:00+00') r), '-')
           || '|' || coalesce((select string_agg(r::text, ';' order by r::text) from cma.lead_to_order_of(v_t1, timestamptz '2026-09-01 00:00+00', timestamptz '2026-11-01 00:00+00') r), '-')
           || '|' || coalesce((select string_agg(q.check_key || ':' || coalesce(q.total::text, '-'), ',') from cma.data_quality() q), '-')
      into v_after;
    v_txt := (select count(*) from cma.form_submission where connection_id = v_crm and source_form_id = 'f-cancel')::text;
    v_rows := v_rows || array['18', 'B8 a support form polled and not counted changes no intake or lead-metrics read',
      case when v_before = v_after and v_txt = '5' and v_before like '%2026-10-05,NL,1,%' and not v_provoke then 'PASS' else 'FAIL' end,
      v_txt || ' stored; ' || case when v_before = v_after then 'alike' else 'differ: ' || left(v_before, 120) || ' / ' || left(v_after, 120) end];

    -- B9. the lead rule: Intake's form count for 5 to 7 October takes the three Contact submissions
    --     (No, Yes, no answer); with the condition "No" only one; the Forms report still three; cleared, three
    perform set_config('app.user_id', v_analyst1::text, true);
    v_txt := (select sum(r.form_submissions)::text from cma.intake_per_day_of(v_t1, timestamptz '2026-10-04 22:00+00', timestamptz '2026-10-07 22:00+00') r);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_form_lead_condition(v_crm, 'f-contact', 'are_you_already_a_customer', array[v_no]);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_txt := v_txt || ' ' || (select sum(r.form_submissions)::text from cma.intake_per_day_of(v_t1, timestamptz '2026-10-04 22:00+00', timestamptz '2026-10-07 22:00+00') r)
      || ' ' || (select sum(f.submissions)::text from cma.forms_report_of(v_t1, date '2026-10-05', date '2026-10-07', 'day', null, null,
                                                                          v_crm::text || ':f-contact', v_now_after) f
                 where f.period = 'current' and f.group_key is null);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_form_lead_condition(v_crm, 'f-contact', null, null);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_txt := v_txt || ' ' || (select sum(r.form_submissions)::text from cma.intake_per_day_of(v_t1, timestamptz '2026-10-04 22:00+00', timestamptz '2026-10-07 22:00+00') r);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_form_lead_condition(v_crm, 'f-contact', 'are_you_already_a_customer', array[v_no]);
    v_rows := v_rows || array['19', 'B9 the lead rule: an existing customer and a missing answer are no lead',
      case when v_txt = '3 1 3 3' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B10. the market of a submission: the form's (NL), the market field's answer through an alias (GB),
    --      the contact's country when the answer names no market (DE), unknown; the step that gave it
    perform set_config('role', 'cma_owner', true);
    insert into cma.crm_contact (tenant_id, connection_id, source_system, source_id, country, country_source)
    values (v_t1, v_crm, 'verifycrm', 'c-de', 'Germany', 1);
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_market_alias('germany', 'DE');
    perform set_config('app.user_id', v_analyst1::text, true);
    select string_agg(format('%s=%s/%s', r.form_id || '@' || to_char(r.submitted_at at time zone 'UTC', 'MMDD-HH24MI'), r.market, coalesce(r.market_source, '-')), ' '
                      order by r.form_id, r.submitted_at) into v_txt
    from cma.form_submissions_of(v_t1, timestamptz '2026-10-01 00:00+00', timestamptz '2026-10-07 00:00+00') r
    where r.form_id in ('f-cancel', 'f-contact');
    v_rows := v_rows || array['20', 'B10 the market of a submission: form, market field through an alias, contact, unknown',
      case when v_txt = 'f-cancel@1001-2230=GB/answer f-cancel@1005-1200=DE/contact f-cancel@1005-1300=unknown/- f-cancel@1006-1300=NL/answer '
                        || 'f-contact@1001-2230=NL/form f-contact@1005-0900=NL/form f-contact@1006-1000=NL/form'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B11. business dates in the market's zone (22:30 UTC on 1 October is 1 October in London and 2 October
    --      in Amsterdam), per day and per ISO week, with the resolution split
    select string_agg(format('%s:%s:%s=%s', f.group_key, f.form_id, f.market, f.submissions), ' ' order by f.group_key, f.form_id) into v_txt
    from cma.forms_report_of(v_t1, date '2026-10-01', date '2026-10-02', 'day', null, null, null, v_now_after) f
    where f.period = 'current' and f.group_key is not null;
    select v_txt || ' | ' || string_agg(format('%s:%s=%s/%s/%s', f.group_key, f.form_id, f.submissions, f.resolved, f.not_found), ' '
                                        order by f.group_key, f.form_id, f.market)
      into v_txt
    from cma.forms_report_of(v_t1, date '2026-10-05', date '2026-10-11', 'week', null, null, null, v_now_after) f
    where f.period = 'current' and f.group_key is not null and f.market in ('NL', 'DE');
    v_rows := v_rows || array['21', 'B11 business dates in the market''s zone, days and ISO weeks, the resolution split',
      case when v_txt = '2026-10-01:f-cancel:GB=1 2026-10-02:f-contact:NL=1 2026-10-02:f-legacy:unknown=1 | 2026-10-05:f-cancel=1/1/0 2026-10-05:f-cancel=1/0/1 2026-10-05:f-contact=3/0/3'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B12. the previous period, like for like: 5 to 11 October seen on Wednesday 7 October at 16:30
    --      compares with 28 to 30 September up to 16:30 (the 18:00 submission left out); seen after it
    --      ended, with the whole of 28 September to 4 October; seen before it started, with nothing
    select string_agg(format('%s:%s', x.k, x.n), ' ' order by x.k) into v_txt
    from (select 'running' as k, coalesce(sum(f.submissions), 0) as n
          from cma.forms_report_of(v_t1, date '2026-10-05', date '2026-10-11', 'day', 'NL', null, v_crm::text || ':f-contact', v_now_running) f
          where f.period = 'previous'
          union all
          select 'ended', coalesce(sum(f.submissions), 0)
          from cma.forms_report_of(v_t1, date '2026-10-05', date '2026-10-11', 'day', 'NL', null, v_crm::text || ':f-contact', v_now_after) f
          where f.period = 'previous'
          union all
          select 'future', coalesce(sum(f.submissions), 0)
          from cma.forms_report_of(v_t1, date '2026-10-05', date '2026-10-11', 'day', 'NL', null, v_crm::text || ':f-contact', v_now_before) f
          where f.period = 'previous'
          union all
          select 'current', coalesce(sum(f.submissions), 0)
          from cma.forms_report_of(v_t1, date '2026-10-05', date '2026-10-11', 'day', 'NL', null, v_crm::text || ':f-contact', v_now_running) f
          where f.period = 'current' and f.group_key is null) x;
    v_rows := v_rows || array['22', 'B12 the previous period like for like (running, ended, not started)',
      case when v_txt = 'current:3 ended:4 future:0 running:2' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B13. the answers per form, field and value, a multiple-checkboxes answer under each value, with the
    --      previous period; the field and value filters
    select string_agg(format('%s:%s.%s=%s', a.period, a.form_id, a.field || '/' || a.value, a.submissions), ' '
                      order by a.period, a.form_id, a.field, a.value) into v_txt
    from cma.forms_answers_of(v_t1, date '2026-10-05', date '2026-10-11', null, null, null, null, null, v_now_after) a
    where a.form_id in ('f-support', 'f-contact');
    select v_txt || ' | ' || string_agg(format('%s=%s', a.value, a.submissions), ' ' order by a.value) into v_txt
    from cma.forms_answers_of(v_t1, date '2026-10-05', date '2026-10-11', null, null, null, 'hs_ticket_category', 'Device', v_now_after) a;
    v_rows := v_rows || array['23', 'B13 answers per field and value with the previous period; field and value filters',
      case when v_txt = 'current:f-contact.are_you_already_a_customer/' || v_no || '=1 current:f-contact.are_you_already_a_customer/' || v_yes || '=1 '
                        || 'current:f-support.hs_ticket_category/Billing=1 current:f-support.hs_ticket_category/Delivery=1 current:f-support.hs_ticket_category/Device=2 '
                        || 'previous:f-contact.are_you_already_a_customer/' || v_no || '=2 previous:f-contact.are_you_already_a_customer/' || v_yes || '=1 | Device=2'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B14. the filters: a market, a category, 'none' for forms without one, a form; and their refusals
    --      through the application's read (CMA04): a market written uk, a malformed form, a group by
    --      month, 93 days
    select string_agg(format('%s=%s', x.k, x.n), ' ' order by x.k) into v_txt
    from (select 'market-unknown' as k, sum(f.submissions) as n
          from cma.forms_report_of(v_t1, date '2026-10-01', date '2026-10-11', 'day', 'unknown', null, null, v_now_after) f
          where f.period = 'current' and f.group_key is null
          union all
          select 'category-support', sum(f.submissions)
          from cma.forms_report_of(v_t1, date '2026-10-01', date '2026-10-11', 'day', null, 'support', null, v_now_after) f
          where f.period = 'current' and f.group_key is null
          union all
          select 'category-none', sum(f.submissions)
          from cma.forms_report_of(v_t1, date '2026-10-01', date '2026-10-11', 'day', null, 'none', null, v_now_after) f
          where f.period = 'current' and f.group_key is null
          union all
          select 'form-cancel', sum(f.submissions)
          from cma.forms_report_of(v_t1, date '2026-10-01', date '2026-10-11', 'day', null, null, v_crm::text || ':f-cancel', v_now_after) f
          where f.period = 'current' and f.group_key is null) x;
    v_txt := v_txt || ' ' || pg_temp.v0008p_code('select cma.forms_report(date ''2026-10-01'', date ''2026-10-11'', ''day'', ''uk'', null, null)')
      || ' ' || pg_temp.v0008p_code('select cma.forms_report(date ''2026-10-01'', date ''2026-10-11'', ''day'', null, null, ''f-cancel'')')
      || ' ' || pg_temp.v0008p_code('select cma.forms_report(date ''2026-10-01'', date ''2026-10-11'', ''month'', null, null, null)')
      || ' ' || pg_temp.v0008p_code('select cma.forms_report(date ''2026-07-01'', date ''2026-10-01'', ''day'', null, null, null)')
      || ' ' || pg_temp.v0008p_code('select cma.forms_answers(date ''2026-10-01'', date ''2026-10-11'', null, null, null, ''bad field'', null)');
    v_rows := v_rows || array['24', 'B14 filters by market, category, none and form; malformed filters refused',
      case when v_txt = 'category-none=1 category-support=6 form-cancel=4 market-unknown=8 CMA04 CMA04 CMA04 CMA04 CMA04' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B15. the history start: the earliest business date in its submission's zone (the GB cancellation at
    --      22:30 UTC on 20 September, 23:30 in London, is earlier than the NL contact at 22:10 UTC, already
    --      21 September in Amsterdam); tenant two has none (null)
    v_txt := cma.forms_history_start()::text;
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_analyst2::text, true);
    v_txt := v_txt || ' ' || coalesce(cma.forms_history_start()::text, 'null');
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['25', 'B15 the history start: earliest business date in its zone; none without submissions',
      case when v_txt = '2026-09-20 null' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B16. the catalog's second refresh: an option the source drops is retired and returns, a field it drops
    --      is archived, a form it describes for the first time is described; the data-quality check is
    --      listed at 0, then finds the value kept under 0007's rule before the form was described, with
    --      its reader view
    v_txt := coalesce((select q.total::text from cma.data_quality() q where q.check_key = 'form_answer_not_in_options'), 'not listed');
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_forms(v_crm, jsonb_build_array(
      jsonb_build_object('formId', 'f-contact', 'name', 'NL Contact', 'fields', jsonb_build_array(
        jsonb_build_object('name', 'are_you_already_a_customer', 'kind', 'radio', 'options', jsonb_build_array(v_no)))),
      jsonb_build_object('formId', 'f-cancel', 'name', 'Cancellation'),
      jsonb_build_object('formId', 'f-support', 'name', 'General support'),
      jsonb_build_object('formId', 'f-legacy', 'name', 'Legacy form', 'fields', jsonb_build_array(
        jsonb_build_object('name', 'product', 'kind', 'dropdown', 'options', jsonb_build_array('aed'))))));
    v_txt := v_txt || ' ' || (select format('%s/%s', array_to_string(options, '|'), array_to_string(retired_options, '|'))
                              from cma.connection_form_field where connection_id = v_crm and source_form_id = 'f-contact' and name = 'are_you_already_a_customer');
    perform cma.ingest_upsert_forms(v_crm, jsonb_build_array(
      jsonb_build_object('formId', 'f-contact', 'name', 'NL Contact', 'fields', jsonb_build_array(
        jsonb_build_object('name', 'are_you_already_a_customer', 'kind', 'radio', 'options', jsonb_build_array(v_yes, v_no)))),
      jsonb_build_object('formId', 'f-cancel', 'name', 'Cancellation'),
      jsonb_build_object('formId', 'f-support', 'name', 'General support'),
      jsonb_build_object('formId', 'f-legacy', 'name', 'Legacy form', 'fields', jsonb_build_array(
        jsonb_build_object('name', 'product', 'kind', 'dropdown', 'options', jsonb_build_array('aed'))))));
    v_txt := v_txt || ' ' || (select format('%s/%s', cardinality(options), cardinality(retired_options))
                              from cma.connection_form_field where connection_id = v_crm and source_form_id = 'f-contact' and name = 'are_you_already_a_customer')
      || ' ' || (select string_agg(name || ':' || status, ',' order by name) from cma.connection_form_field where connection_id = v_crm and source_form_id = 'f-contact')
      || ' ' || (select count(*) from cma.connection_form_field where connection_id = v_crm and source_form_id = 'f-cancel' and status = 'active')::text
      || ' ' || (select (fields_refreshed_at is not null)::text from cma.connection_form where connection_id = v_crm and source_form_id = 'f-legacy');
    perform set_config('app.user_id', v_analyst1::text, true);
    v_txt := v_txt || ' ' || coalesce((select q.total::text from cma.data_quality() q where q.check_key = 'form_answer_not_in_options'), 'not listed')
      || ' ' || coalesce((select string_agg(q.object_id || '/' || q.value, ',') from cma.data_quality_of(v_t1) q where q.check_key = 'form_answer_not_in_options'), '-');
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || ' ' || coalesce((select string_agg(object_id, ',') from cma_read.dq_form_answer_not_in_options where tenant_id = v_t1), '-');
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['26', 'B16 second refresh: an option retired and back, a field archived; the check finds a value kept before',
      case when v_txt = '0 ' || v_no || '/' || v_yes || ' 2/0 are_you_already_a_customer:active,email:archived,message:archived 3 true 1 s-l1/product s-l1'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B17. the permissions: the report, the answers and the history start for reports.view and for
    --      performance.team; an agent and the Ingest user refused (CMA06); the categories for a reader;
    --      the catalogs' new keys for the configuring person
    v_txt := '';
    foreach v_detail in array array[v_reader1::text, v_analyst1::text, v_agent1::text, v_ing1::text] loop
      perform set_config('app.user_id', v_detail, true);
      v_txt := v_txt || ' ' || pg_temp.v0008p_code('select cma.forms_report(date ''2026-10-01'', date ''2026-10-11'', ''week'', null, null, null)')
        || '/' || pg_temp.v0008p_code('select cma.forms_answers(date ''2026-10-01'', date ''2026-10-11'', null, null, null, null, null)')
        || '/' || pg_temp.v0008p_code('select cma.forms_history_start()')
        || '/' || pg_temp.v0008p_code('select cma.form_categories()');
    end loop;
    perform set_config('app.user_id', v_reader1::text, true);
    v_txt := v_txt || ' ' || (select string_agg(c.code || ':' || c.status || ':' || c.forms, ',' order by c.sort_order) from cma.form_categories() c);
    perform set_config('app.user_id', v_admin1::text, true);
    v_j := (select f from jsonb_array_elements(cma.connection_catalogs(v_crm) -> 'forms') f where f ->> 'formId' = 'f-cancel');
    v_txt := v_txt || ' ' || format('%s/%s/%s/%s/%s', v_j ->> 'isPolled', v_j ->> 'category', v_j ->> 'marketField',
                                    jsonb_array_length(v_j -> 'fields'), (v_j -> 'fields' -> 1 -> 'options') ->> 0);
    v_rows := v_rows || array['27', 'B17 permissions: reports.view or performance.team read; agent and Ingest user refused',
      case when v_txt = ' ok/ok/ok/ok ok/ok/ok/ok CMA06/CMA06/CMA06/CMA06 CMA06/CMA06/CMA06/CMA06 contact:active:1,cancellation:active:1,support:active:1,old:inactive:0 true/cancellation/country_dropdown/3/United Kingdom'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B18. tenant isolation: tenant two sees no form, field, category or submission of tenant one, gets no
    --      report or answer rows for tenant one even when it names it, and cannot configure its forms
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_analyst2::text, true);
    v_txt := (select count(*) from cma.connection_form)::text || '/' || (select count(*) from cma.connection_form_field)::text
      || '/' || (select count(*) from cma.form_category)::text || '/' || (select count(*) from cma.form_submission)::text
      || ' ' || (select count(*) from cma.forms_report_of(v_t1, date '2026-10-01', date '2026-10-11', 'day', null, null, null, v_now_after))::text
      || '/' || (select count(*) from cma.forms_answers_of(v_t1, date '2026-10-01', date '2026-10-11', null, null, null, null, null, v_now_after))::text
      || '/' || coalesce(cma.forms_history_start_of(v_t1)::text, 'null');
    perform set_config('app.user_id', v_admin2::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008p_code(format('select cma.set_form(%L, ''f-contact'', false, null, null, null)', v_crm))
      || ' ' || pg_temp.v0008p_code(format('select cma.set_form_market_field(%L, ''f-cancel'', null)', v_crm));
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    v_rows := v_rows || array['28', 'B18 tenant isolation for the tables, the reads and the configuration',
      case when v_txt = '0/0/0/0 0/0/null CMA02 CMA02' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B19. a run's counts take dropped (the answers the forms poll left out); any other unknown key still CMA04
    perform set_config('app.user_id', v_ing1::text, true);
    v_txt := pg_temp.v0008p_code(format('select cma.ingest_sync_run_finish(cma.ingest_sync_run_start(%L, ''forms_poll'', ''forms'', null, null), ''succeeded'', ''{"fetched": 3, "upserted": 2, "dropped": 1}'')', v_crm))
      || ' ' || pg_temp.v0008p_code(format('select cma.ingest_sync_run_finish(cma.ingest_sync_run_start(%L, ''forms_poll'', ''forms'', null, null), ''succeeded'', ''{"fetched": 3, "kept": 1}'')', v_crm));
    -- a statement of its own: in the expression above the read would run before the two writes
    v_txt := v_txt || ' ' || coalesce((select string_agg(r.counts::text, ',') from cma.sync_run r where r.connection_id = v_crm and r.counts ? 'dropped'), 'none');
    v_rows := v_rows || array['29', 'B19 a run''s counts take dropped; another key is refused',
      case when v_txt = 'ok CMA04 {"dropped": 1, "fetched": 3, "upserted": 2}' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['39', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008p (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008p values (39, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008p
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED: not dev'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008p where result = 'PASS') = 24
                       and not exists (select 1 from verify_0008p where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0008p where result = 'PASS'),
                                        (select count(*) from verify_0008p where result <> 'PASS'))) x
order by ord;
drop function if exists pg_temp.v0008p_sub(text, text, timestamptz, jsonb, text);
drop function if exists pg_temp.v0008p_code(text);
reset role;
