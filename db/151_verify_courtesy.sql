-- =============================================================================================
-- 151_verify_courtesy.sql: verifies addition 0009a, Customers → Courtesy
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure and privileges; block B
-- works on two throwaway tenants inside a subtransaction that is always rolled back, so nothing stays. Universal
-- otherwise: nothing of the seed is used; adapters, contacts, calls, lines, tags, stores, orders and people are invented
-- data values, and no row carries a name of a customer, an address or a phone number. Every check writes one row, PASS
-- or FAIL, and the last row is the verdict (OK when every check passes), because Cloud SQL Studio shows no notices. Run as
-- your own IAM login in dev, after 150_courtesy.sql; then 81 and 73 again. Edited by 0009c (154_courtesy_bases.sql): the courtesy
-- state not_reached is unreachable and the follow-up summary's column courtesy_unreachable, so since 0009c it runs after 154.
--   A  structure and privileges: the addition row after 0008zz; every function the application's only and in the caller's
--      rights, the readers' function definer, the owner's, pinned, the readers' only; the five settings with their
--      defaults; the setting check's refusals and normalisation; cma.follow_up_summary()'s columns; the reader view's
--      columns, with no contact, CRM connection, name, email, phone or payload
--   B  courtesy on two throwaway tenants (Europe/Amsterdam). Tenant one: markets NL (Europe/Amsterdam) and GB
--      (Europe/London); courtesy.start_date 7 September 2026, the other settings at their defaults (first,repeat; day 10;
--      3 attempts; ages 10,14,21,30); a CRM connection with a contact record link, a telephony connection with a counted
--      line and the five tags (the meanings courtesy_completed_positive, _neutral and _negative, courtesy_attempt, not_reached), a shop per
--      market. As of Friday 6 November 2026 12:00 UTC, the brief's twelve checks:
--      B1  a First and a Repeat order count; Renewal, Unknown, test, deleted and cancelled orders do not
--      B2  an order before courtesy.start_date does not count; an unset start date gives not set up (no store: has_store
--          false), and the follow-up snapshot's count null
--      B3  an order without a linked contact counts as No contact only
--      B4  the due date is 10 calendar days from the business date; a London and an Amsterdam order at 23:30 UTC fall on
--          their own market's dates (one due, one not due yet)
--      B5  a call before the due date is not an attempt since due; a completed call before the due date still completes the order
--      B6  one completed call completes two open orders of the same contact; a later third order stays open
--      B7  three attempts since due without a Conversation give Unreachable (the third tagged not reached at 45 seconds);
--          two give Attempted; three with one Conversation (its tag's meaning courtesy_attempt) give Attempted
--      B8  positive, neutral and negative completions are split (an inbound call completes too); an untagged connected
--          call never completes
--      B9  per person sorts by name (not by count); a call whose user is linked to nobody is in the not-linked row, last
--      B10 the follow-up summary's new count equals the page's Unreachable tile
--      B11 permissions: no reports.view or performance.team gives CMA06; the per-person block is absent without
--          performance.team
--      B12 cma_read.courtesy_order holds no contact id, and equals the application's rows for its tenant
--      and besides: the page's tiles, per market, per week and the cohorts (B13); the filters, the list's order, cap,
--      link and days past due (B14); the parameters refused (B15); the other tenant seeing nothing (B16)
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
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 151 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0009a;
create temp table verify_0009a (ord int, check_name text, result text, detail text);

-- The error code a statement raises, or 'ok'
create or replace function pg_temp.v0009a_code(p_sql text)
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

-- One courtesy order as text: source id:business date (MMDD)/due date (MMDD)/state/attempts/conversation/outcome, '-' for null
create or replace function pg_temp.v0009a_order(r cma.courtesy_order_row)
returns text
language sql immutable
as $$
  select format('%s:%s/%s/%s/%s/%s/%s', r.order_source_id, to_char(r.business_date, 'MMDD'), to_char(r.due_date, 'MMDD'),
                coalesce(r.state, '-'), coalesce(r.attempts::text, '-'), coalesce(r.conversation::text, '-'), coalesce(r.outcome, '-'))
$$;

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_bad     text;
  v_fn      text;
  v_txt     text;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  -- A1. the addition is recorded, after 0008zz
  insert into verify_0009a values (1, 'A1 addition 0009a recorded, after 0008zz',
    case when exists (select 1 from cma.schema_migration where version = '0009a')
              and exists (select 1 from cma.schema_migration where version = '0008zz') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. every function of the addition the application's only and in the caller's rights; the readers' function SECURITY
  --     DEFINER, owned by cma_owner, search path pinned with pg_temp last, the readers' only
  v_bad := '';
  foreach v_fn in array array[
    'cma.courtesy_start_of(uuid)', 'cma.courtesy_kinds_of(uuid)', 'cma.courtesy_ages_of(uuid)', 'cma.courtesy_outcome_of(text)',
    'cma.courtesy_orders_of(uuid,date,date,timestamptz)', 'cma.courtesy_unreachable_of(uuid,timestamptz)',
    'cma.courtesy_state_matches(text,text)',
    'cma.courtesy_page_of(uuid,date,date,text,text,text,text,text,integer,boolean,timestamptz)',
    'cma.courtesy_page(date,date,text,text,text,text,text,integer)',
    'cma.refresh_follow_up_of(uuid,boolean)', 'cma.follow_up_summary()'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or has_function_privilege('public', v_fn, 'execute')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      v_bad := v_bad || v_fn || ' not the application''s only or not in the caller''s rights; ';
    end if;
  end loop;
  v_fn := 'cma_read.courtesy_order_rows()';
  if to_regprocedure(v_fn) is null then
    v_bad := v_bad || v_fn || ' missing; ';
  elsif not (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
        or (select pg_get_userbyid(proowner) from pg_proc where oid = to_regprocedure(v_fn)) <> 'cma_owner'
        or not coalesce((select array_to_string(proconfig, ',') from pg_proc where oid = to_regprocedure(v_fn)) like 'search_path=%pg_temp', false)
        or not has_function_privilege('cma_readonly', v_fn, 'execute') or has_function_privilege('cma_app', v_fn, 'execute')
        or has_function_privilege('public', v_fn, 'execute') then
    v_bad := v_bad || v_fn || ' not the readers'' pinned definer function; ';
  end if;
  if not has_table_privilege('cma_readonly', 'cma_read.courtesy_order', 'select') then
    v_bad := v_bad || 'cma_read.courtesy_order not readable by the readers; ';
  end if;
  insert into verify_0009a values (2, 'A2 every function the application''s only and invoker; the readers'' function definer, the owner''s, pinned, theirs only',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A3. the five settings in the catalog with their types and defaults
  select string_agg(format('%s=%s:%s', s.key, s.value_type, s.default_value), ' ' order by s.key) into v_txt
  from cma.setting s where s.key like 'courtesy.%';
  insert into verify_0009a values (3, 'A3 the five courtesy settings with their types and defaults',
    case when v_txt = 'courtesy.ages_days=text:10,14,21,30 courtesy.alert_attempts=integer:3 courtesy.due_days=integer:10 '
                      || 'courtesy.order_kinds=text:first,repeat courtesy.start_date=text:' and not v_provoke then 'PASS' else 'FAIL' end,
    coalesce(v_txt, 'null'));

  -- A4. cma.follow_up_summary() ends with the two courtesy columns; the reader view's exact columns, none of them a
  --     contact, a CRM connection, a name, an email, a phone, a hash or a payload
  select string_agg(a.attname, ',' order by a.attnum) into v_txt
  from pg_attribute a where a.attrelid = 'cma_read.courtesy_order'::regclass and a.attnum > 0 and not a.attisdropped;
  insert into verify_0009a values (4, 'A4 cma.follow_up_summary() ends with the courtesy columns; the reader view''s columns without a contact',
    case when (select array_to_string((proargnames)[array_length(proargnames, 1) - 2:], ',') from pg_proc
               where oid = to_regprocedure('cma.follow_up_summary()')) = 'computed_at,courtesy_unreachable,courtesy_alert_attempts'
              and v_txt = 'tenant_id,order_id,connection_id,order_source_id,store,market,segment,created_at,business_date,due_date,'
                          || 'has_contact,attempts,conversation,last_attempt_at,completed_at,outcome,completed_by,state'
              and v_txt !~ '(contact_source|crm_|name|email|phone|hash|raw|reached)'
              and not v_provoke then 'PASS' else 'FAIL' end,
    coalesce(v_txt, 'null'));
end
$$;

-- B. Courtesy on two throwaway tenants (rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_rows     text[] := '{}';
  v_t1 uuid; v_t2 uuid;
  v_admin1 uuid; v_analyst1 uuid; v_agent1 uuid; v_zed uuid; v_anna uuid; v_viewer1 uuid; v_ing1 uuid;
  v_admin2 uuid; v_analyst2 uuid; v_ing2 uuid;
  v_viewer_role uuid;
  v_crm uuid; v_tel uuid; v_nl uuid; v_gb uuid; v_shop2 uuid;
  v_txt text; v_txt2 text;
  v_n integer; v_m integer;
  j jsonb; j2 jsonb;
  r record;
  v_now  timestamptz := '2026-11-06 12:00:00+00';   -- Friday 6 November 2026, 13:00 in Amsterdam, 12:00 in London
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    -- tenants, people and roles (as the owner, as 0008zm's verify); a role of tenant one with reports.view alone
    v_t1 := cma.create_tenant('verify-0009a-one', 'Verify 0009a one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0009a-two', 'Verify 0009a two', 'Europe/Amsterdam');
    insert into cma.app_role (tenant_id, key, name) values (v_t1, 'verify_viewer', 'Viewer') returning id into v_viewer_role;
    insert into cma.role_permission (tenant_id, role_id, permission_key) values (v_t1, v_viewer_role, 'reports.view');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-analyst1@example.invalid', 'analyst1') returning id into v_analyst1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent1@example.invalid', 'agent1') returning id into v_agent1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-zed@example.invalid', 'Zed') returning id into v_zed;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-anna@example.invalid', 'Anna') returning id into v_anna;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-viewer1@example.invalid', 'viewer1') returning id into v_viewer1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin2') returning id into v_admin2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-analyst2@example.invalid', 'analyst2') returning id into v_analyst2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_analyst1, 'analytics'), (v_t1, v_agent1, 'agent'), (v_t1, v_zed, 'agent'),
                 (v_t1, v_anna, 'agent'), (v_t1, v_viewer1, 'verify_viewer'), (v_t2, v_admin2, 'admin'), (v_t2, v_analyst2, 'analytics')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    select x.user_id into v_ing2 from cma.app_user_external_id x where x.tenant_id = v_t2 and x.system = 'ingest';
    insert into cma.integration_connection (tenant_id, adapter, kind, name, external_account_id, settings)
    values (v_t1, 'verifycrm', 'crm', 'Verify courtesy CRM', 'portal-1', '{"record_url_contact": "https://crm.example.invalid/{account}/contact/{id}"}')
    returning id into v_crm;
    insert into cma.integration_connection (tenant_id, adapter, kind, name, external_account_id)
    values (v_t1, 'verifytel', 'telephony', 'Verify courtesy telephony', 'tel-1') returning id into v_tel;
    insert into cma.integration_connection (tenant_id, adapter, kind, name, external_account_id)
    values (v_t1, 'verifyshop', 'commerce', 'Verify courtesy shop NL', 'shop-nl.example.invalid') returning id into v_nl;
    insert into cma.integration_connection (tenant_id, adapter, kind, name, external_account_id)
    values (v_t1, 'verifyshop', 'commerce', 'Verify courtesy shop GB', 'shop-gb.example.invalid') returning id into v_gb;
    insert into cma.integration_connection (tenant_id, adapter, kind, name, external_account_id)
    values (v_t2, 'verifyshop', 'commerce', 'Verify courtesy shop two', 'shop-two.example.invalid') returning id into v_shop2;
    -- the telephony users: tu-1 is Zed's, tu-2 Anna's, tu-x nobody's
    insert into cma.app_user_external_id (tenant_id, user_id, system, external_id)
    values (v_t1, v_zed, 'verifytel_user', 'tu-1'), (v_t1, v_anna, 'verifytel_user', 'tu-2');
    perform set_config('role', 'cma_app', true);

    -- tenant one's configuration (the admin): the markets, the settings, the shops, then the catalogs (the Ingest user)
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP');
    perform cma.set_tenant_setting('crm.customer_segments', 'B2B,B2C');
    perform cma.set_tenant_setting('commerce.renewal_source_names', 'verify-subscriptions');
    perform cma.upsert_commerce_store(v_nl, 'v-nl', 'Verify NL', 'NL', 'EUR', 'Europe/Amsterdam');
    perform cma.upsert_commerce_store(v_gb, 'v-gb', 'Verify GB', 'GB', 'GBP', 'Europe/London');
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'number', '[{"numberRef": "n-1", "name": "Verify line", "digits": "+31000000001"}]');
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'tag', '[{"tagRef": "t-pos", "name": "Completed positive"}, {"tagRef": "t-neu", "name": "Completed neutral"},
      {"tagRef": "t-neg", "name": "Completed negative"}, {"tagRef": "t-att", "name": "Follow up"}, {"tagRef": "t-nr", "name": "Not reached"}]');
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_telephony_number(v_tel, 'n-1', 'NL', true);
    perform cma.set_telephony_tag_meaning(v_tel, 't-pos', 'courtesy_completed_positive');
    perform cma.set_telephony_tag_meaning(v_tel, 't-neu', 'courtesy_completed_neutral');
    perform cma.set_telephony_tag_meaning(v_tel, 't-neg', 'courtesy_completed_negative');
    perform cma.set_telephony_tag_meaning(v_tel, 't-att', 'courtesy_attempt');
    perform cma.set_telephony_tag_meaning(v_tel, 't-nr', 'not_reached');

    -- the store customers (one per contact; c-no linked to none), the orders, the links and the contacts (UTC; Amsterdam is UTC+2 and
    -- London UTC+1 until 25 October, UTC+1 and UTC after)
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_commerce_customers(v_nl, (
      select jsonb_agg(jsonb_build_object('sourceId', 'c-' || k, 'updatedAt', '2026-09-01T00:00:00Z'))
      from unnest(array['k1', 'k2', 'k3', 'kA', 'k5', 'k5b', 'k6', 'k7a', 'k7b', 'k7c', 'k8u', 'no']) k));
    perform cma.ingest_upsert_commerce_customers(v_gb, '[{"sourceId": "c-kL", "updatedAt": "2026-09-01T00:00:00Z"}]');
    perform cma.ingest_upsert_commerce_orders(v_nl, '[
      {"sourceId": "oF",      "orderName": "#1001", "customerId": "c-k1",  "createdAt": "2026-10-01T10:00:00Z", "updatedAt": "2026-10-01T10:00:00Z", "priorOrdersCount": 0},
      {"sourceId": "oR",      "orderName": "#1002", "customerId": "c-k2",  "createdAt": "2026-10-02T10:00:00Z", "updatedAt": "2026-10-02T10:00:00Z", "priorOrdersCount": 1},
      {"sourceId": "oRen",    "customerId": "c-k3", "createdAt": "2026-10-02T10:00:00Z", "updatedAt": "2026-10-02T10:00:00Z", "priorOrdersCount": 2, "sourceName": "verify-subscriptions"},
      {"sourceId": "oUnk",    "customerId": "c-k3", "createdAt": "2026-10-02T10:00:00Z", "updatedAt": "2026-10-02T10:00:00Z"},
      {"sourceId": "oTest",   "customerId": "c-k3", "createdAt": "2026-10-02T10:00:00Z", "updatedAt": "2026-10-02T10:00:00Z", "priorOrdersCount": 0, "isTest": true},
      {"sourceId": "oDel",    "customerId": "c-k3", "createdAt": "2026-10-02T10:00:00Z", "updatedAt": "2026-10-02T10:00:00Z", "priorOrdersCount": 0, "deletedAt": "2026-10-03T10:00:00Z"},
      {"sourceId": "oCan",    "customerId": "c-k3", "createdAt": "2026-10-02T10:00:00Z", "updatedAt": "2026-10-03T10:00:00Z", "priorOrdersCount": 0, "cancelledAt": "2026-10-03T10:00:00Z"},
      {"sourceId": "oBefore", "customerId": "c-k3", "createdAt": "2026-09-05T10:00:00Z", "updatedAt": "2026-09-05T10:00:00Z", "priorOrdersCount": 0},
      {"sourceId": "oNo",     "customerId": "c-no", "createdAt": "2026-10-03T10:00:00Z", "updatedAt": "2026-10-03T10:00:00Z", "priorOrdersCount": 0},
      {"sourceId": "oAms",    "customerId": "c-kA", "createdAt": "2026-10-27T23:30:00Z", "updatedAt": "2026-10-27T23:30:00Z", "priorOrdersCount": 0},
      {"sourceId": "oE",      "customerId": "c-k5", "createdAt": "2026-10-05T10:00:00Z", "updatedAt": "2026-10-05T10:00:00Z", "priorOrdersCount": 0},
      {"sourceId": "oP",      "customerId": "c-k5b", "createdAt": "2026-10-05T10:00:00Z", "updatedAt": "2026-10-05T10:00:00Z", "priorOrdersCount": 0},
      {"sourceId": "o6a",     "customerId": "c-k6", "createdAt": "2026-10-01T10:00:00Z", "updatedAt": "2026-10-01T10:00:00Z", "priorOrdersCount": 0},
      {"sourceId": "o6b",     "customerId": "c-k6", "createdAt": "2026-10-03T10:00:00Z", "updatedAt": "2026-10-03T10:00:00Z", "priorOrdersCount": 1},
      {"sourceId": "o6c",     "customerId": "c-k6", "createdAt": "2026-10-25T10:00:00Z", "updatedAt": "2026-10-25T10:00:00Z", "priorOrdersCount": 2},
      {"sourceId": "o7a",     "customerId": "c-k7a", "createdAt": "2026-10-01T10:00:00Z", "updatedAt": "2026-10-01T10:00:00Z", "priorOrdersCount": 0},
      {"sourceId": "o7b",     "customerId": "c-k7b", "createdAt": "2026-10-01T10:00:00Z", "updatedAt": "2026-10-01T10:00:00Z", "priorOrdersCount": 0},
      {"sourceId": "o7c",     "customerId": "c-k7c", "createdAt": "2026-10-01T10:00:00Z", "updatedAt": "2026-10-01T10:00:00Z", "priorOrdersCount": 0},
      {"sourceId": "o8u",     "customerId": "c-k8u", "createdAt": "2026-10-01T10:00:00Z", "updatedAt": "2026-10-01T10:00:00Z", "priorOrdersCount": 0}]');
    perform cma.ingest_upsert_commerce_orders(v_gb, '[
      {"sourceId": "oLdn", "customerId": "c-kL", "createdAt": "2026-10-27T23:30:00Z", "updatedAt": "2026-10-27T23:30:00Z", "priorOrdersCount": 0}]');
    perform cma.set_commerce_customer_contact(v_nl, 'c-' || k, v_crm, k)
    from unnest(array['k1', 'k2', 'k3', 'kA', 'k5', 'k5b', 'k6', 'k7a', 'k7b', 'k7c', 'k8u']) k;
    perform cma.set_commerce_customer_contact(v_gb, 'c-kL', v_crm, 'kL');
    -- the contacts' thin records, held because a store customer is linked to each (0008zn)
    perform cma.ingest_upsert_contacts(v_crm, (
      select jsonb_agg(jsonb_build_object('sourceId', k, 'country', 'NL', 'updatedAt', '2026-09-01T00:00:00Z'))
      from unnest(array['k1', 'k2', 'k3', 'kL', 'kA', 'k5', 'k5b', 'k6', 'k7a', 'k7b', 'k7c', 'k8u']) k));

    -- the calls: each a CRM call on its contact logged by a telephony call with the same hash, 10 seconds earlier
    --   k1  outbound 14 Oct by tu-1, 60 s, tagged completed positive: completes oF (an attempt since due too: after its due date)
    --   k2  inbound 15 Oct by tu-2, 90 s, tagged completed negative: completes oR (inbound: no attempt since due)
    --   k5  outbound 8 Oct not answered (before the due date), outbound 12 Oct by tu-x, 50 s, completed positive (before it)
    --   k5b outbound 8 Oct (before the due date) and 16 Oct, neither answered: one attempt since due
    --   k6  outbound 20 Oct by tu-1, 120 s, completed neutral: completes o6a and o6b; o6c of 25 Oct stays open
    --   k7a 12, 13 Oct not answered, 14 Oct answered 45 s tagged not reached: three attempts since due, no conversation
    --   k7b 12, 13 Oct not answered: two attempts since due
    --   k7c 12 Oct not answered, 13 Oct answered 40 s with the tag meaning courtesy_attempt (a conversation), 14 Oct not answered
    --   k8u 12 Oct answered 60 s, untagged: a conversation, never a completion
    create temp table v0009a_calls (id text, contact text, at timestamptz, dir text, talk integer, usr text, tags text[]) on commit drop;
    insert into v0009a_calls values
      ('c1',    'k1',  '2026-10-14T10:00:00Z', 'outbound', 60,   'tu-1', '{t-pos}'),
      ('c2',    'k2',  '2026-10-15T10:00:00Z', 'inbound',  90,   'tu-2', '{t-neg}'),
      ('c5pre', 'k5',  '2026-10-08T10:00:00Z', 'outbound', null, 'tu-1', '{}'),
      ('c5',    'k5',  '2026-10-12T10:00:00Z', 'outbound', 50,   'tu-x', '{t-pos}'),
      ('c5b1',  'k5b', '2026-10-08T10:00:00Z', 'outbound', null, 'tu-1', '{}'),
      ('c5b2',  'k5b', '2026-10-16T10:00:00Z', 'outbound', null, 'tu-1', '{}'),
      ('c6',    'k6',  '2026-10-20T10:00:00Z', 'outbound', 120,  'tu-1', '{t-neu}'),
      ('c7a1',  'k7a', '2026-10-12T10:00:00Z', 'outbound', null, 'tu-1', '{}'),
      ('c7a2',  'k7a', '2026-10-13T10:00:00Z', 'outbound', null, 'tu-1', '{}'),
      ('c7a3',  'k7a', '2026-10-14T10:00:00Z', 'outbound', 45,   'tu-1', '{t-nr}'),
      ('c7b1',  'k7b', '2026-10-12T10:00:00Z', 'outbound', null, 'tu-1', '{}'),
      ('c7b2',  'k7b', '2026-10-13T10:00:00Z', 'outbound', null, 'tu-1', '{}'),
      ('c7c1',  'k7c', '2026-10-12T10:00:00Z', 'outbound', null, 'tu-1', '{}'),
      ('c7c2',  'k7c', '2026-10-13T10:00:00Z', 'outbound', 40,   'tu-1', '{t-att}'),
      ('c7c3',  'k7c', '2026-10-14T10:00:00Z', 'outbound', null, 'tu-1', '{}'),
      ('c8u',   'k8u', '2026-10-12T10:00:00Z', 'outbound', 60,   'tu-1', '{}');
    perform cma.ingest_upsert_calls(v_crm, (
      select jsonb_agg(jsonb_build_object('sourceId', c.id, 'occurredAt', c.at, 'direction', c.dir, 'counterpartHash', md5(c.id) || md5(c.id || 'x'),
                                          'updatedAt', c.at))
      from v0009a_calls c));
    perform cma.ingest_upsert_associations(v_crm, (
      select jsonb_agg(jsonb_build_object('fromType', 'crm_call', 'fromId', c.id, 'toType', 'contact', 'toId', c.contact, 'removed', false,
                                          'changedAt', '2026-09-01T00:00:00Z'))
      from v0009a_calls c));
    perform cma.ingest_upsert_telephony_calls(v_tel, (
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'sourceId', 't' || c.id, 'direction', c.dir, 'startedAt', c.at - interval '10 seconds',
               'answeredAt', case when c.talk is not null then c.at end,
               'endedAt', c.at + make_interval(secs => coalesce(c.talk, 20)), 'numberRef', 'n-1', 'userRef', c.usr,
               'counterpartHash', md5(c.id) || md5(c.id || 'x'), 'versionAt', c.at + interval '1 hour', 'tags', to_jsonb(c.tags))))
      from v0009a_calls c));
    perform cma.link_calls('2026-09-01T00:00:00Z');
    -- the segments (the CRM's mapped property, as the ingest would keep them): k1 B2B, k2 B2C, every other contact none
    perform set_config('role', 'cma_owner', true);
    update cma.crm_contact set segment = case source_id when 'k1' then 'B2B' else 'B2C' end
    where tenant_id = v_t1 and source_id in ('k1', 'k2');
    perform set_config('role', 'cma_app', true);

    -- B2 (first half). Not set up: before the start date is set, no courtesy order, the page says so, the count is null
    perform set_config('app.user_id', v_analyst1::text, true);
    select count(*) into v_n from cma.courtesy_orders_of(v_t1, null, null, v_now);
    j := cma.courtesy_page_of(v_t1, date '2026-10-01', date '2026-10-31', 'week', 'week', null, null, null, 100, true, v_now);
    v_txt := format('%s rows; set_up %s; now %s; has_store %s; unreachable %s', v_n, j ->> 'set_up', coalesce(j ->> 'now', 'null'),
                    j ->> 'has_store', coalesce(cma.courtesy_unreachable_of(v_t1, v_now)::text, 'null'));
    -- tenant two: no store, no start date
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_analyst2::text, true);
    j2 := cma.courtesy_page(date '2026-10-01', date '2026-10-31');
    v_txt := v_txt || format(' | two: set_up %s, has_store %s', j2 ->> 'set_up', j2 ->> 'has_store');
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('courtesy.start_date', ' 2026-09-07 ');
    perform set_config('app.user_id', v_analyst1::text, true);

    -- B1. a First and a Repeat order count; Renewal, Unknown, test, deleted and cancelled orders do not (and the kinds the
    --     ingest gave them are those)
    select string_agg(o.order_source_id, ' ' order by o.order_source_id) into v_txt2 from cma.courtesy_orders_of(v_t1, null, null, v_now) o;
    v_rows := v_rows || array['11', 'B1 First and Repeat count; Renewal, Unknown, test, deleted and cancelled orders do not',
      case when v_txt2 = 'o6a o6b o6c o7a o7b o7c o8u oAms oE oF oLdn oNo oP oR'
                and (select string_agg(format('%s:%s', o.source_id, o.order_kind), ' ' order by o.source_id) from cma.commerce_order o
                     where o.tenant_id = v_t1 and o.source_id in ('oF', 'oR', 'oRen', 'oUnk')) = 'oF:first oR:repeat oRen:renewal oUnk:unknown'
                and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt2, 'null')];

    -- B2. an order before the start date does not count (oBefore of 5 September); unset, nothing counts and the page and the
    --     snapshot's count say not set up; a tenant without a store says so; the start date is kept trimmed
    v_rows := v_rows || array['12', 'B2 before the start date nothing counts; an unset start date gives not set up, no store has_store false',
      case when v_txt = '0 rows; set_up false; now null; has_store true; unreachable null | two: set_up false, has_store false'
                and v_txt2 not like '%oBefore%' and cma.courtesy_start_of(v_t1) = date '2026-09-07'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- every order's facts as of the fixed instant
    select string_agg(pg_temp.v0009a_order(o), ' ' order by o.order_source_id) into v_txt
    from cma.courtesy_orders_of(v_t1, null, null, v_now) o;

    -- B3. an order without a linked contact counts as No contact only: no state, no attempts since due, segment unknown; in the No
    --     contact tile and in no other count
    j := cma.courtesy_page_of(v_t1, date '2026-10-01', date '2026-10-31', 'week', 'week', null, null, null, 100, true, v_now);
    select format('%s/%s/%s/%s', o.has_contact, coalesce(o.state, '-'), coalesce(o.attempts::text, '-'), o.segment) into v_txt2
    from cma.courtesy_orders_of(v_t1, null, null, v_now) o where o.order_source_id = 'oNo';
    v_rows := v_rows || array['13', 'B3 an order without a linked contact counts as No contact only',
      case when v_txt2 = 'f/-/-/unknown' and (j -> 'now' ->> 'no_contact')::int = 1 and (j -> 'now' ->> 'orders')::int = 13
                and (j -> 'now' ->> 'not_due')::int + (j -> 'now' ->> 'due_open')::int + (j -> 'now' ->> 'completed')::int = 13
                and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s; now %s', coalesce(v_txt2, 'null'), j -> 'now')];

    -- B4. the due date is 10 calendar days from the business date; at 23:30 UTC on 27 October the London order is the
    --     27th (due the 6th: due as of now) and the Amsterdam order the 28th (due the 7th: not due yet)
    select string_agg(format('%s:%s/%s/%s/%s', o.order_source_id, o.market, to_char(o.business_date, 'MMDD'), to_char(o.due_date, 'MMDD'), o.state), ' '
                      order by o.order_source_id) into v_txt2
    from cma.courtesy_orders_of(v_t1, null, null, v_now) o where o.order_source_id in ('oLdn', 'oAms', 'oF');
    v_rows := v_rows || array['14', 'B4 due 10 calendar days after the business date; London and Amsterdam at 23:30 UTC on their own dates',
      case when v_txt2 = 'oAms:NL/1028/1107/not_due oF:NL/1001/1011/completed oLdn:GB/1027/1106/due_no_attempt'
                and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt2, 'null')];

    -- B5. a call before the due date is not an attempt since due (oP: 8 October not counted, 16 October one); a completed call
    --     before the due date still completes the order (oE: 12 October, due the 15th, no attempt since due)
    v_rows := v_rows || array['15', 'B5 a call before the due date is no attempt since due; a completed call before it still completes',
      case when v_txt like '%oE:1005/1015/completed/0/false/positive%' and v_txt like '%oP:1005/1015/attempted/1/false/-%'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B6. one completed call completes two open orders of the same contact; a later third order stays open
    select string_agg(format('%s:%s', o.order_source_id, coalesce(o.state, '-')), ' ' order by o.order_source_id),
           count(distinct o.completed_call_id) into v_txt2, v_n
    from cma.courtesy_orders_of(v_t1, null, null, v_now) o where o.order_source_id in ('o6a', 'o6b', 'o6c');
    v_rows := v_rows || array['16', 'B6 one completed call completes two open orders of a contact; a later third stays open',
      case when v_txt2 = 'o6a:completed o6b:completed o6c:due_no_attempt' and v_n = 1
                and v_txt like '%o6a:1001/1011/completed/1/true/neutral%' and v_txt like '%o6c:1025/1104/due_no_attempt/0/false/-%'
                and not v_provoke then 'PASS' else 'FAIL' end, format('%s; %s completing call', v_txt2, v_n)];

    -- B7. three attempts since due without a Conversation: Unreachable; two: Attempted; three with one Conversation (its tag's
    --     meaning courtesy_attempt): Attempted
    v_rows := v_rows || array['17', 'B7 three attempts since due without a conversation Unreachable; two Attempted; three with one conversation Attempted',
      case when v_txt like '%o7a:1001/1011/unreachable/3/false/-%' and v_txt like '%o7b:1001/1011/attempted/2/false/-%'
                and v_txt like '%o7c:1001/1011/attempted/3/true/-%'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B8. positive, neutral and negative split (an inbound call completes oR); an untagged connected call never completes
    v_rows := v_rows || array['18', 'B8 the completions split by outcome; an untagged connected call never completes',
      case when v_txt like '%oF:1001/1011/completed/1/true/positive%' and v_txt like '%oR:1002/1012/completed/0/false/negative%'
                and v_txt like '%o8u:1001/1011/attempted/1/true/-%'
                and j -> 'completed' = '{"calls": 4, "neutral": 1, "negative": 1, "positive": 2}'::jsonb
                and not v_provoke then 'PASS' else 'FAIL' end, format('%s | %s', j -> 'completed', v_txt)];

    -- B9. per person by name, never by count (Zed has two, Anna one); a call whose user is linked to nobody last
    select string_agg(format('%s:%s/%s/%s/%s', coalesce(p ->> 'name', 'none'), p ->> 'calls', p ->> 'positive', p ->> 'neutral', p ->> 'negative'), ' '
                      order by o) into v_txt2
    from jsonb_array_elements(j -> 'per_person') with ordinality as x(p, o);
    v_rows := v_rows || array['19', 'B9 per person by name, not by count; the user linked to nobody in the not-linked row, last',
      case when v_txt2 = 'Anna:1/0/0/1 Zed:2/1/1/0 none:1/1/0/0' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt2, 'null')];

    -- B10. the follow-up summary's new count equals the page's Unreachable tile (both as of now, in one transaction)
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.refresh_follow_up_of(v_t1);
    select format('%s/%s', s.courtesy_unreachable, s.courtesy_alert_attempts) into v_txt2 from cma.follow_up_summary() s;
    j2 := cma.courtesy_page(date '2026-10-01', date '2026-10-31');
    v_rows := v_rows || array['20', 'B10 the follow-up summary''s Unreachable equals the page''s tile, with the attempts since due that flag it',
      case when v_txt2 = (j2 -> 'now' ->> 'unreachable') || '/3' and (j2 -> 'now' ->> 'unreachable')::int >= 1
                and not v_provoke then 'PASS' else 'FAIL' end, format('summary %s, page %s', v_txt2, j2 -> 'now' ->> 'unreachable')];

    -- B11. permissions: an agent (neither reports.view nor performance.team) is refused (CMA06); reports.view alone gets
    --      the page without the per-person block; performance.team gets it
    perform set_config('app.user_id', v_agent1::text, true);
    v_txt2 := pg_temp.v0009a_code($q$select cma.courtesy_page(date '2026-10-01', date '2026-10-31')$q$);
    perform set_config('app.user_id', v_viewer1::text, true);
    j2 := cma.courtesy_page(date '2026-10-01', date '2026-10-31');
    v_txt2 := v_txt2 || format(' viewer per_person %s', coalesce(jsonb_typeof(j2 -> 'per_person'), 'absent'));
    perform set_config('app.user_id', v_analyst1::text, true);
    j2 := cma.courtesy_page(date '2026-10-01', date '2026-10-31');
    v_txt2 := v_txt2 || format(' analyst per_person %s', coalesce(jsonb_typeof(j2 -> 'per_person'), 'absent'));
    v_rows := v_rows || array['21', 'B11 no reports.view or performance.team CMA06; per person absent without performance.team',
      case when v_txt2 = 'CMA06 viewer per_person null analyst per_person array' and not v_provoke then 'PASS' else 'FAIL' end, v_txt2];

    -- B12. cma_read.courtesy_order holds no contact id, and as a reader of tenant one equals the application's rows
    perform set_config('role', 'cma_readonly', true);
    select count(*), string_agg(c.order_source_id || ':' || coalesce(c.state, '-'), ' ' order by c.order_source_id) into v_n, v_txt2
    from cma_read.courtesy_order c where c.tenant_id = v_t1;
    select count(*) into v_m from cma_read.courtesy_order c where c.tenant_id = v_t2;
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['22', 'B12 cma_read.courtesy_order without a contact id, equal to the application''s rows',
      case when v_n = 14 and v_m = 0
                and v_txt2 = (select string_agg(o.order_source_id || ':' || coalesce(o.state, '-'), ' ' order by o.order_source_id)
                              from cma.courtesy_orders_of(v_t1, null, null, now()) o)
                and not exists (select 1 from information_schema.columns where table_schema = 'cma_read' and table_name = 'courtesy_order'
                                and column_name in ('contact_source_id', 'crm_contact_source_id', 'crm_connection_id', 'contact_id'))
                and not v_provoke then 'PASS' else 'FAIL' end, format('%s rows; two %s; %s', v_n, v_m, v_txt2)];

    -- B13. the page's figures (October 2026, by week, cohorts by week): the tiles now; per market; per ISO week; the cohorts
    --      at 10, 14, 21 and 30 days (the week of 26 October not 10 days old yet); nothing compared before the start
    select string_agg(format('%s:%s/%s/%s/%s', m ->> 'market', m ->> 'orders', m ->> 'completed', m ->> 'unreachable', m ->> 'no_contact'), ' '
                      order by o) into v_txt2
    from jsonb_array_elements(j -> 'markets') with ordinality as x(m, o);
    select v_txt2 || ' | ' || string_agg(format('%s:%s/%s/%s', to_char((g ->> 'key')::date, 'MMDD'), g ->> 'orders', g ->> 'completed', g ->> 'unreachable'), ' '
                                         order by o) into v_txt2
    from jsonb_array_elements(j -> 'groups') with ordinality as x(g, o);
    select v_txt2 || ' | ' || string_agg(format('%s%s %s %s', c ->> 'label', case when (c ->> 'partial')::boolean then '*' else '' end, c ->> 'orders',
                                                (select string_agg(format('%s:%s', a ->> 'age', coalesce(a ->> 'completed', '-')), ',' order by ao)
                                                 from jsonb_array_elements(c -> 'ages') with ordinality as y(a, ao))), ' ' order by o) into v_txt2
    from jsonb_array_elements(j -> 'cohorts') with ordinality as x(c, o);
    v_rows := v_rows || array['23', 'B13 the tiles, per market, per week and the order cohorts with their ages',
      case when j -> 'now' = '{"orders": 13, "not_due": 1, "due_open": 7, "attempted": 4, "completed": 5, "no_contact": 1, "unreachable": 1, "due_no_attempt": 2}'::jsonb
                and v_txt2 = 'GB:1/0/0/0 NL:12/5/1/1 | 0928:8/4/1 1005:2/1/0 1012:0/0/0 1019:1/0/0 1026:2/0/0 | '
                             || '2026-W44* 2 10:-,14:-,21:-,30:- 2026-W43 1 10:0,14:-,21:-,30:- 2026-W41 2 10:1,14:1,21:1,30:1 '
                             || '2026-W40* 8 10:0,14:2,21:4,30:4'
                and j -> 'previous' = '{"calls": 0, "neutral": 0, "negative": 0, "positive": 0}'::jsonb
                and (j -> 'settings') = '{"ages": [10, 14, 21, 30], "due_days": 10, "order_kinds": ["first", "repeat"], "alert_attempts": 3}'::jsonb
                and not v_provoke then 'PASS' else 'FAIL' end, format('%s | now %s', coalesce(v_txt2, 'null'), j -> 'now')];

    -- B14. the filters run in the database: market GB, segment B2B, state unreachable, due and no_contact; the list
    --      Unreachable first, then by due date, capped at rows with the total, the contact's link, days past due for an open order
    j2 := cma.courtesy_page_of(v_t1, date '2026-10-01', date '2026-10-31', 'week', 'week', 'GB', null, null, 100, true, v_now);
    v_txt2 := format('GB %s %s;', j2 -> 'list' ->> 'total', j2 -> 'list' -> 'rows' -> 0 ->> 'order_name');
    j2 := cma.courtesy_page_of(v_t1, date '2026-10-01', date '2026-10-31', 'week', 'week', null, 'B2B', null, 100, true, v_now);
    v_txt2 := v_txt2 || format(' B2B %s %s;', j2 -> 'list' ->> 'total', j2 -> 'completed' ->> 'calls');
    j2 := cma.courtesy_page_of(v_t1, date '2026-10-01', date '2026-10-31', 'week', 'week', null, null, 'unreachable', 100, true, v_now);
    v_txt2 := v_txt2 || format(' unreachable %s %s;', j2 -> 'list' ->> 'total', j2 -> 'list' -> 'rows' -> 0 ->> 'order_name');
    j2 := cma.courtesy_page_of(v_t1, date '2026-10-01', date '2026-10-31', 'week', 'week', null, null, 'due', 100, true, v_now);
    v_txt2 := v_txt2 || format(' due %s;', j2 -> 'list' ->> 'total');
    j2 := cma.courtesy_page_of(v_t1, date '2026-10-01', date '2026-10-31', 'week', 'week', null, null, 'no_contact', 100, true, v_now);
    v_txt2 := v_txt2 || format(' no_contact %s %s;', j2 -> 'list' ->> 'total', coalesce(j2 -> 'list' -> 'rows' -> 0 ->> 'record_url', 'nolink'));
    j2 := cma.courtesy_page_of(v_t1, date '2026-10-01', date '2026-10-31', 'week', 'week', null, null, null, 3, true, v_now);
    select v_txt2 || format(' first 3 of %s: ', j2 -> 'list' ->> 'total')
           || string_agg(format('%s/%s/%s', x ->> 'order_name', x ->> 'state', coalesce(x ->> 'days_past_due', '-')), ' ' order by o)
      into v_txt2
    from jsonb_array_elements(j2 -> 'list' -> 'rows') with ordinality as y(x, o);
    v_rows := v_rows || array['24', 'B14 the filters in the database; the list''s order, cap and total, link and days past due',
      case when v_txt2 = 'GB 1 oLdn; B2B 1 1; unreachable 1 o7a; due 7; no_contact 1 nolink; first 3 of 14: o7a/unreachable/26 o6c/due_no_attempt/2 oLdn/due_no_attempt/0'
                and j -> 'list' -> 'rows' -> 0 ->> 'record_url' = 'https://crm.example.invalid/portal-1/contact/k7a'
                and j -> 'list' -> 'rows' -> 0 ->> 'store_name' = 'Verify NL'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt2];

    -- B15. the parameters refused: a period over 92 days, a period or group not known, a market, segment or state not
    --      known (CMA04); a setting out of range (CMA04)
    v_txt2 := '';
    foreach v_txt in array array[
      $q$select cma.courtesy_page(date '2026-07-01', date '2026-10-31')$q$,
      $q$select cma.courtesy_page(date '2026-10-01', date '2026-10-31', 'day')$q$,
      $q$select cma.courtesy_page(date '2026-10-01', date '2026-10-31', 'week', 'year')$q$,
      $q$select cma.courtesy_page(date '2026-10-01', date '2026-10-31', 'week', 'week', 'nl')$q$,
      $q$select cma.courtesy_page(date '2026-10-01', date '2026-10-31', 'week', 'week', null, 'B2B,B2C')$q$,
      $q$select cma.courtesy_page(date '2026-10-01', date '2026-10-31', 'week', 'week', null, null, 'open')$q$] loop
      v_txt2 := v_txt2 || pg_temp.v0009a_code(v_txt) || ' ';
    end loop;
    perform set_config('app.user_id', v_admin1::text, true);
    foreach v_txt in array array[
      $q$select cma.set_tenant_setting('courtesy.due_days', '0')$q$, $q$select cma.set_tenant_setting('courtesy.due_days', '61')$q$,
      $q$select cma.set_tenant_setting('courtesy.alert_attempts', '21')$q$, $q$select cma.set_tenant_setting('courtesy.ages_days', '10,5')$q$,
      $q$select cma.set_tenant_setting('courtesy.ages_days', '10,91')$q$, $q$select cma.set_tenant_setting('courtesy.ages_days', '1,2,3,4,5,6,7')$q$,
      $q$select cma.set_tenant_setting('courtesy.order_kinds', 'first,first')$q$, $q$select cma.set_tenant_setting('courtesy.order_kinds', 'new')$q$,
      $q$select cma.set_tenant_setting('courtesy.start_date', '7 Sep 2026')$q$] loop
      v_txt2 := v_txt2 || pg_temp.v0009a_code(v_txt) || ' ';
    end loop;
    perform cma.set_tenant_setting('courtesy.order_kinds', 'first, repeat, renewal');
    perform cma.set_tenant_setting('courtesy.ages_days', ' 7, 90 ');
    v_txt2 := v_txt2 || cma.setting_of(v_t1, 'courtesy.order_kinds') || ' ' || cma.setting_of(v_t1, 'courtesy.ages_days')
              || ' ' || (select count(*) from cma.courtesy_orders_of(v_t1, null, null, v_now));
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['25', 'B15 the parameters and the settings out of range refused (CMA04); a list kept without spaces',
      case when v_txt2 = 'CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 first,repeat,renewal 7,90 15'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt2];

    -- B16. the other tenant sees nothing of tenant one's: its page holds no order and its reads none
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    perform cma.set_tenant_setting('courtesy.start_date', '2026-09-07');
    perform set_config('app.user_id', v_analyst2::text, true);
    j2 := cma.courtesy_page(date '2026-10-01', date '2026-10-31');
    select count(*) into v_n from cma.courtesy_orders_of(v_t2, null, null, v_now);
    v_rows := v_rows || array['26', 'B16 the other tenant sees no order of tenant one',
      case when v_n = 0 and (j2 -> 'now' ->> 'orders')::int = 0 and (j2 -> 'list' ->> 'total')::int = 0 and (j2 ->> 'set_up')::boolean
                and not v_provoke then 'PASS' else 'FAIL' end, format('%s rows; page now %s', v_n, j2 -> 'now')];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then
      v_rows := v_rows || array['49', 'B ran to the end', case when not v_provoke then 'PASS' else 'FAIL' end, ''];
    when others then
      v_rows := v_rows || array['49', 'B ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0009a (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0009a values (49, 'B ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- The helpers are dropped first, so the verdict is the last thing the script prints
drop function if exists pg_temp.v0009a_code(text);
drop function if exists pg_temp.v0009a_order(cma.courtesy_order_row);

-- Verdict: one row per check, then the verdict: OK when all 21 checks pass
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0009a
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT OK'
                  when (select count(*) from verify_0009a where result = 'PASS') = 21
                       and not exists (select 1 from verify_0009a where result <> 'PASS') then 'OK'
                  else 'FAIL' end,
             format('151_verify_courtesy: %s PASS, %s FAIL', (select count(*) from verify_0009a where result = 'PASS'),
                                                            (select count(*) from verify_0009a where result <> 'PASS'))) x
order by ord;
reset role;
