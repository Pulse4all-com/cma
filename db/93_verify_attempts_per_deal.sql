-- =============================================================================================
-- 93_verify_attempts_per_deal.sql: verifies addition 0008y, attempts per deal
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure
-- and privileges; block B works on two throwaway tenants inside a subtransaction that is always
-- rolled back. Universal otherwise: nothing of the seed is used; adapters, pipelines, deals, contacts,
-- calls, lines and owners are invented data values, and no row carries a name, an address or a phone number.
-- Every check writes one row, PASS or FAIL, and the last result lists them with the verdict, because
-- Cloud SQL Studio shows no notices. Run as your own IAM login in dev, after 92_attempts_per_deal.sql; then
-- 41, 61, 69, 73, 75, 77, 81, 83, 85, 89 and 91 again.
--   A  structure and privileges: the addition row after 0008x; every function the application's only and in the
--      caller's rights, the readers' function definer, the owner's, its search path pinned with pg_temp last, the
--      readers' only; the reader view's exact columns, with no name, address, email, phone, hash or raw; the three
--      settings in the catalog; cma.lead_deals_of reading cma.counted_deals_of within its coalesce bounds
--   B  behaviour. Tenant one (Europe/Amsterdam; intake from 1 September 2026; pre-window 10 minutes; markets NL
--      and GB with office hours Monday to Friday 09:00-17:00 and an NL holiday on Tuesday 13 October 2026) holds a
--      CRM connection with a lead pipeline (open, won, lost and a closed stage without an outcome), a counted
--      pipeline that is no lead pipeline, an order pipeline still marked lead and an uncounted one, a telephony
--      connection with two lines, owners o-1 Anna and o-2 Bram linked and o-3 not, and the deals of the week of 5 to
--      11 October 2026 and the week before with their calls: 0, 1, 3 and 7 attempts; an inbound call; a call after
--      the close; a call on a second associated contact and one whose association was removed; the pre-window
--      both ways; a linked telephony call answered and an outcome that counts as connected; the first connected
--      attempt 3; won, lost, open and unknown outcomes; a deleted deal. Tenant two has a deal of the same source id.
--      Checked as of fixed instants (the *_of reads take one): the attempts, the connected rule, the outcomes, the
--      scopes, the business days since the last attempt across a weekend and a holiday, the buckets with the
--      default top and with 8, the figures, the groups, the previous period like for like, the list's order and
--      cap, the filters, the history start, the parameter and range refusals, the permissions, per person with the
--      not-linked row and its gates, the setting refusals, the stored calls of a line, tenant isolation, the reader
--      view equal to the application's rows, and cma.lead_deals_of giving 0008q's rows (a copy of its body in pg_temp)
--      with every market as cma.record_market_of gives it (an alias, a contact's country)
-- Amended for addition 0008z (20 October 2026; 93 runs in dev only and never ran in prod): 0008z keeps 0008y's attempts as
-- its source crm (every outbound CRM call), removes the scope (only the lead pipelines count) and replaces connected by
-- reached (the outcome when the call has one, else the talk time; an answered telephony call alone no longer counts). Tenant
-- one therefore sets attempts.source to crm, and these checks pin the new figures, each for the reason named:
--   A2  the function list: 0008z's signatures (no scope; the definition and the rows without it, the in-period cut with
--       the attempted and outcome filters, the page reads with them)
--   A3  the reader view's columns: 0008z's (is_lead, connected and first_connected_attempt gone; the window, reached, talk
--       time and speed to lead in)
--   B1  d7's second attempt was connected through its answered telephony call; with the outcome No answer it is not reached
--       (7/1/2 becomes 7/0/-)
--   B4  the scope is gone: the counted pipeline that is no lead pipeline is out like the order pipeline, the uncounted one and
--       the deleted deal
--   B6  the first reached per bucket: d7 no longer in bucket 2
--   B7  the figures: reached_deals in place of connected_deals (3 becomes 2), and no counted scope
--   B8  the groups per pipeline of the lead pipelines only (no Renewals)
--   B12 the pipeline list of the lead pipelines only; the figures' reached deals
--   B13 the scope's refusal becomes the attempted filter's; the pages read without a scope
--   B14 the not-linked row's reached deals (d7: 1 becomes 0) and the total's
--   B18 tenant two's page read without a scope
--   B19 the reader view's rows: the lead deals since the intake start (fourteen, not seventeen) with 0008z's columns
-- B2, B3, B5, B9, B10, B11, B15, B16, B17 and B20 pin what they pinned before.
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
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 93 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0008y;
create temp table verify_0008y (ord int, check_name text, result text, detail text);

-- The error code a statement raises, or 'ok'
create or replace function pg_temp.v0008y_code(p_sql text)
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

-- A deal's attempts as text: source id, attempts, reached, first reached attempt (or -) (0008z: reached for connected)
create or replace function pg_temp.v0008y_deals(p_tenant uuid, p_now timestamptz)
returns text
language sql
as $$
  select string_agg(format('%s:%s/%s/%s', x.deal_source_id, x.attempts, x.reached_attempts, coalesce(x.first_reached_attempt::text, '-')),
                    ' ' order by x.deal_source_id)
  from cma.attempts_per_deal_of(p_tenant, timestamptz '2026-10-04 22:00:00+00', timestamptz '2026-10-11 22:00:00+00', p_now) x
$$;

-- The figures of a JSON object as deals/attempted/attempts/avg/median/first_reached/reached_deals/open/open_never/won/lost
create or replace function pg_temp.v0008y_fig(f jsonb)
returns text
language sql immutable
as $$
  select format('%s/%s/%s/%s/%s/%s/%s/%s/%s/%s/%s', f ->> 'deals', f ->> 'attempted', f ->> 'attempts', coalesce(f ->> 'avg_attempts', '-'),
                coalesce(f ->> 'median_attempts', '-'), f ->> 'first_reached', f ->> 'reached_deals', f ->> 'open_deals',
                f ->> 'open_never_attempted', f ->> 'won', f ->> 'lost')
$$;

-- 0008q's cma.lead_deals_of, copied as it was before 0008y, so B20 can prove the shared population gives its rows
create or replace function pg_temp.v0008y_lead_deals_0008q(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns table(deal_id uuid, connection_id uuid, source_system text, record_type text, source_id text, pipeline_id text,
              pipeline_label text, owner_ref text, contact_source_id text, is_closed boolean, created_at timestamptz,
              business_date date, market text, market_source text, contacts text[])
language sql stable
as $$
  with s as (
    select t.timezone as zone, cma.setting_of(t.id, 'intake.start_date')::date as start_date
    from cma.tenant t where t.id = p_tenant_id
  )
  select d.id, d.connection_id, d.source_system, d.record_type, d.source_id, d.pipeline_id,
         coalesce(p.label, d.pipeline_id), d.owner_ref, d.contact_source_id, coalesce(d.is_closed, false),
         d.source_created_at, (d.source_created_at at time zone s.zone)::date, rm.code, rm.source,
         array(select x from (select d.contact_source_id as x where d.contact_source_id is not null
                              union
                              select a.to_id from cma.crm_association a
                              where a.tenant_id = d.tenant_id and a.connection_id = d.connection_id
                                and a.from_type = d.record_type and a.from_id = d.source_id
                                and a.to_type = 'contact' and a.removed_at is null) c
               order by x)
  from cma.crm_record d
  cross join s
  left join cma.connection_pipeline p
    on p.tenant_id = d.tenant_id and p.connection_id = d.connection_id
   and p.record_type = d.record_type and p.source_pipeline_id = d.pipeline_id
  cross join lateral cma.record_market_of(d.tenant_id, d.connection_id, d.market, d.contact_source_id) rm
  where d.tenant_id = p_tenant_id
    and d.record_type = 'deal'
    and d.source_deleted_at is null
    and coalesce(p.is_counted, true) and coalesce(p.is_lead, true)
    and d.source_created_at >= (s.start_date::timestamp at time zone s.zone)
    and d.source_created_at >= coalesce(p_from, '-infinity'::timestamptz)
    and d.source_created_at < coalesce(p_to, 'infinity'::timestamptz)
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
  -- A1. the addition is recorded, after 0008x
  insert into verify_0008y values (1, 'A1 addition 0008y recorded, after 0008x',
    case when exists (select 1 from cma.schema_migration where version = '0008y')
              and exists (select 1 from cma.schema_migration where version = '0008x') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. every function of the addition the application's only and in the caller's rights; the readers' function
  --     SECURITY DEFINER, owned by cma_owner, search path pinned with pg_temp last, the readers' only
  v_bad := '';
  foreach v_fn in array array[
    'cma.is_bucket_list(text,integer)', 'cma.is_per_person_list(text)', 'cma.counted_deals_of(uuid,timestamptz,timestamptz)',
    'cma.lead_deals_of(uuid,timestamptz,timestamptz)',
    'cma.attempts_per_deal_of(uuid,timestamptz,timestamptz,timestamptz)', 'cma.attempts_filters_check(text,text)',
    'cma.attempts_rows_of(uuid,date,date,timestamptz)', 'cma.attempts_in_period(cma.attempt_deal[],date,date,text,text,text,text,timestamptz,text)',
    'cma.attempts_figures_from(cma.attempt_deal[])', 'cma.attempts_buckets_from(cma.attempt_deal[],integer)',
    'cma.attempts_since_last_from(cma.attempt_deal[],text)', 'cma.attempts_groups_from(cma.attempt_deal[],text)',
    'cma.attempts_list_from(cma.attempt_deal[],integer)', 'cma.attempts_filter_lists_from(cma.attempt_deal[])',
    'cma.attempts_history_start_of(uuid)', 'cma.attempts_settings_of(uuid)',
    'cma.attempts_per_deal_page_of(uuid,date,date,text,text,text,text,text,integer,timestamptz)',
    'cma.attempts_per_person_of(uuid,date,date,text,text,text,text,timestamptz)', 'cma.attempts_params_check(uuid,date,date,text,text,text,text)',
    'cma.attempts_per_deal_page(date,date,text,text,text,text,text,integer)', 'cma.attempts_per_person_page(date,date,text,text,text,text)',
    'cma.telephony_number_stored_calls(uuid,text)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or has_function_privilege('public', v_fn, 'execute')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      v_bad := v_bad || v_fn || ' not the application''s only or not in the caller''s rights; ';
    end if;
  end loop;
  v_fn := 'cma_read.attempts_per_deal_rows()';
  if to_regprocedure(v_fn) is null then
    v_bad := v_bad || v_fn || ' missing; ';
  elsif not (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
        or (select pg_get_userbyid(proowner) from pg_proc where oid = to_regprocedure(v_fn)) <> 'cma_owner'
        or not coalesce((select array_to_string(proconfig, ',') from pg_proc where oid = to_regprocedure(v_fn)) like 'search_path=%pg_temp', false)
        or not has_function_privilege('cma_readonly', v_fn, 'execute') or has_function_privilege('cma_app', v_fn, 'execute')
        or has_function_privilege('public', v_fn, 'execute') then
    v_bad := v_bad || v_fn || ' not the readers'' pinned definer function; ';
  end if;
  insert into verify_0008y values (2, 'A2 every function the application''s only and invoker; the readers'' function definer, the owner''s, pinned, theirs only',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A3. the reader view's exact columns, readable by the readers, none named like a name, an address, an email, a
  --     phone, a hash or a payload
  v_bad := '';
  if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'attempts_per_deal')
     is distinct from 'tenant_id,deal_id,connection_id,deal_source_id,pipeline_id,pipeline_label,stage_id,market,owner_user_id,created_at,'
                      'business_date,is_closed,closed_at,ordered_at,window_end_reason,outcome,attempts,reached_attempts,first_reached_attempt,'
                      'talk_seconds_total,talk_seconds_reached,first_attempt_at,speed_to_lead_seconds,called_before_next_noon,last_attempt_at,'
                      'business_days_since_last,since_last_bucket,attempts_without_outcome,logged_without_aircall'
     or not has_table_privilege('cma_readonly', 'cma_read.attempts_per_deal', 'select') then
    v_bad := 'cma_read.attempts_per_deal; ';
  end if;
  select v_bad || coalesce(string_agg(column_name, ', '), '') into v_bad
  from information_schema.columns
  where table_schema = 'cma_read' and table_name = 'attempts_per_deal'
    and column_name ~* '(name|address|email|phone|number|_hash$|^raw$|_ref$)';
  insert into verify_0008y values (3, 'A3 the reader view with its exact columns; no name, address, email, phone, hash or payload',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A4. the settings in the catalog with their types and defaults; reports.per_person names attempts
  select string_agg(format('%s:%s:%s', s.key, s.value_type, s.default_value), ' ' order by s.key) into v_bad
  from cma.setting s where s.key in ('attempts.max_bucket', 'attempts.since_last_buckets_business_days', 'reports.per_person');
  v_bad := v_bad || case when (select s.description from cma.setting s where s.key = 'reports.per_person') like '%attempts%' then ' names attempts' else ' no attempts' end;
  insert into verify_0008y values (4, 'A4 the two settings and reports.per_person in the catalog',
    case when v_bad = 'attempts.max_bucket:integer:5 attempts.since_last_buckets_business_days:text:1,2,5 reports.per_person:text: names attempts'
          and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A5. the lead population is written once: cma.lead_deals_of reads cma.counted_deals_of, its period bound with
  --     coalesce (0008q's rule, 77's A7)
  v_bad := '';
  if (select p.prosrc from pg_proc p where p.oid = to_regprocedure('cma.lead_deals_of(uuid,timestamptz,timestamptz)')) !~ 'cma\.counted_deals_of\(' then
    v_bad := v_bad || 'lead_deals_of does not read counted_deals_of; ';
  end if;
  if exists (select 1 from pg_proc p where p.oid = to_regprocedure('cma.lead_deals_of(uuid,timestamptz,timestamptz)')
             and (p.prosrc ~ 'p_from is null or' or p.prosrc !~ 'coalesce\(p_from, ''-infinity''::timestamptz\)'
                  or p.prosrc !~ 'coalesce\(p_to, ''infinity''::timestamptz\)')) then
    v_bad := v_bad || 'lead_deals_of''s period not bound with coalesce; ';
  end if;
  if (select p.prosrc from pg_proc p where p.oid = to_regprocedure('cma.counted_deals_of(uuid,timestamptz,timestamptz)'))
     !~ 'coalesce\(p_from, ''-infinity''::timestamptz\)' then
    v_bad := v_bad || 'counted_deals_of''s period not bound with coalesce; ';
  end if;
  insert into verify_0008y values (5, 'A5 cma.lead_deals_of reads cma.counted_deals_of within coalesce bounds',
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
  v_crm uuid; v_tel uuid; v_crm2 uuid;
  v_role uuid;
  v_txt text; v_detail text; v_app text; v_view text;
  j jsonb;
  v_h7  text := repeat('b7', 32);
  v_now     timestamptz := '2026-10-14 10:00:00+00';   -- Wednesday 14 October 2026, 12:00 in Amsterdam
  v_running timestamptz := '2026-10-09 07:30:00+00';   -- Friday 9 October, 09:30 in Amsterdam
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    -- tenants, people and roles (as the owner, as 0008w's verify)
    v_t1 := cma.create_tenant('verify-0008y-one', 'Verify 0008y one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008y-two', 'Verify 0008y two', 'Europe/Amsterdam');
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
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, settings)
    values (v_t1, 'verifycrm', 'Verify attempts CRM', 'portal-1', '{"record_url_deal": "https://crm.example.invalid/{account}/deal/{id}"}')
    returning id into v_crm;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t1, 'verifytel', 'Verify attempts telephony', 'tel-1') returning id into v_tel;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id)
    values (v_t2, 'verifycrm', 'Verify attempts CRM two', 'portal-2') returning id into v_crm2;
    perform set_config('role', 'cma_app', true);

    -- tenant one's configuration (the admin): markets, office hours, the NL holiday, the settings, the owners
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP');
    perform cma.set_business_hours('*', d::smallint, '09:00-17:00') from generate_series(1, 5) d;
    perform cma.set_business_holiday('NL', date '2026-10-13', 'Verify holiday');
    perform cma.set_market_alias('holland', 'NL');
    perform cma.set_market_alias('united kingdom', 'GB');
    perform cma.set_tenant_setting('intake.start_date', '2026-09-01');
    perform cma.set_tenant_setting('speed_to_lead.pre_window_minutes', '10');
    perform cma.set_tenant_setting('reports.per_person', 'attempts');
    -- 0008y's attempts are 0008z's source crm: every outbound CRM call
    perform cma.set_tenant_setting('attempts.source', 'crm');
    perform cma.set_user_external_id(v_anna, 'verifycrm_owner', 'o-1');
    perform cma.set_user_external_id(v_bram, 'verifycrm_owner', 'o-2');

    -- the catalogs from the sources (the Ingest user)
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_pipelines(v_crm, '[
      {"recordType": "deal", "pipelineId": "sales", "label": "Sales", "stages": [
         {"stageId": "s1", "label": "Open", "order": 1, "isClosed": false, "outcome": null},
         {"stageId": "sw", "label": "Won", "order": 8, "isClosed": true, "outcome": "won"},
         {"stageId": "sl", "label": "Lost", "order": 9, "isClosed": true, "outcome": "lost"},
         {"stageId": "sx", "label": "Closed", "order": 10, "isClosed": true, "outcome": null}]},
      {"recordType": "deal", "pipelineId": "renew", "label": "Renewals", "stages": [{"stageId": "r1", "label": "Open", "order": 1, "isClosed": false}]},
      {"recordType": "deal", "pipelineId": "orders", "label": "Orders", "stages": [{"stageId": "o1", "label": "Won", "order": 1, "isClosed": true, "outcome": "won"}]},
      {"recordType": "deal", "pipelineId": "test", "label": "Test", "stages": [{"stageId": "x1", "label": "Open", "order": 1, "isClosed": false}]}]');
    perform cma.ingest_upsert_call_outcomes(v_crm, '[{"outcomeRef": "connected", "label": "Connected"}, {"outcomeRef": "no_answer", "label": "No answer"}]');
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'number', '[{"numberRef": "n-nl", "name": "Verify NL line", "digits": "+31000000001"},
      {"numberRef": "n-gb", "name": "Verify GB line", "digits": "+44000000001"}]');

    -- their configuration (the admin): renew counts but is no lead pipeline, orders is an order pipeline (still
    -- marked lead, as every pipeline is by default), test does not count
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_pipeline_lead(v_crm, 'deal', 'renew', false);
    perform cma.set_pipeline_order(v_crm, 'deal', 'orders', true);
    perform cma.set_connection_pipeline(v_crm, 'deal', 'test', false, false, null);
    perform cma.set_call_outcome(v_crm, 'connected', true);
    perform cma.set_telephony_number(v_tel, 'n-nl', 'NL', true);
    perform cma.set_telephony_number(v_tel, 'n-gb', 'GB', true);

    -- the deals (UTC; Amsterdam is UTC+2, London UTC+1 until 25 October)
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_records(v_crm, '[
      {"recordType": "deal", "sourceId": "d0",    "pipelineId": "sales",  "stageId": "s1", "ownerRef": "o-1", "contactId": "k0",    "market": "NL", "createdAt": "2026-10-05T08:00:00Z", "updatedAt": "2026-10-05T08:00:00Z"},
      {"recordType": "deal", "sourceId": "d1",    "pipelineId": "sales",  "stageId": "s1", "ownerRef": "o-1", "contactId": "k1",    "market": "NL", "createdAt": "2026-10-05T09:00:00Z", "updatedAt": "2026-10-05T09:00:00Z"},
      {"recordType": "deal", "sourceId": "d3",    "pipelineId": "sales",  "stageId": "sw", "ownerRef": "o-2", "contactId": "k3",    "market": "NL", "createdAt": "2026-10-06T08:00:00Z", "closedAt": "2026-10-08T12:00:00Z", "updatedAt": "2026-10-08T12:00:00Z"},
      {"recordType": "deal", "sourceId": "d7",    "pipelineId": "sales",  "stageId": "sl", "ownerRef": "o-3", "contactId": "k7",    "market": "NL", "createdAt": "2026-10-06T09:00:00Z", "closedAt": "2026-10-09T15:00:00Z", "updatedAt": "2026-10-09T15:00:00Z"},
      {"recordType": "deal", "sourceId": "dIn",   "pipelineId": "sales",  "stageId": "s1",                    "contactId": "kin",   "market": "NL", "createdAt": "2026-10-07T08:00:00Z", "updatedAt": "2026-10-07T08:00:00Z"},
      {"recordType": "deal", "sourceId": "dK2",   "pipelineId": "sales",  "stageId": "s1", "ownerRef": "o-1", "contactId": "ka",    "market": "NL", "createdAt": "2026-10-07T09:00:00Z", "updatedAt": "2026-10-07T09:00:00Z"},
      {"recordType": "deal", "sourceId": "dPre",  "pipelineId": "sales",  "stageId": "s1", "ownerRef": "o-2", "contactId": "kpre",  "market": "NL", "createdAt": "2026-10-08T08:00:00Z", "updatedAt": "2026-10-08T08:00:00Z"},
      {"recordType": "deal", "sourceId": "dUnk",  "pipelineId": "sales",  "stageId": "sx",                    "contactId": "kunk",  "market": "NL", "createdAt": "2026-10-08T10:00:00Z", "closedAt": "2026-10-08T11:00:00Z", "updatedAt": "2026-10-08T11:00:00Z"},
      {"recordType": "deal", "sourceId": "dGB",   "pipelineId": "sales",  "stageId": "s1", "ownerRef": "o-2", "contactId": "kgb",   "market": "GB", "createdAt": "2026-10-09T08:00:00Z", "updatedAt": "2026-10-09T08:00:00Z"},
      {"recordType": "deal", "sourceId": "dFri",  "pipelineId": "sales",  "stageId": "s1", "ownerRef": "o-3", "contactId": "kfri",  "market": "NL", "createdAt": "2026-10-09T08:30:00Z", "updatedAt": "2026-10-09T08:30:00Z"},
      {"recordType": "deal", "sourceId": "dX",    "pipelineId": "sales",  "stageId": "s1",                    "contactId": "kx",                    "createdAt": "2026-10-09T09:00:00Z", "updatedAt": "2026-10-09T09:00:00Z"},
      {"recordType": "deal", "sourceId": "dRen",  "pipelineId": "renew",  "stageId": "r1", "ownerRef": "o-1", "contactId": "kr",    "market": "NL", "createdAt": "2026-10-09T09:15:00Z", "updatedAt": "2026-10-09T09:15:00Z"},
      {"recordType": "deal", "sourceId": "dOrd",  "pipelineId": "orders", "stageId": "o1", "ownerRef": "o-1", "contactId": "kord",  "market": "NL", "createdAt": "2026-10-09T10:00:00Z", "closedAt": "2026-10-09T10:00:00Z", "updatedAt": "2026-10-09T10:00:00Z"},
      {"recordType": "deal", "sourceId": "dTest", "pipelineId": "test",   "stageId": "x1", "ownerRef": "o-1", "contactId": "kt",    "market": "NL", "createdAt": "2026-10-07T12:00:00Z", "updatedAt": "2026-10-07T12:00:00Z"},
      {"recordType": "deal", "sourceId": "dDel",  "pipelineId": "sales",  "stageId": "s1", "ownerRef": "o-1", "contactId": "kdel",  "market": "NL", "createdAt": "2026-10-07T13:00:00Z", "updatedAt": "2026-10-07T13:00:00Z"},
      {"recordType": "deal", "sourceId": "dP1",   "pipelineId": "sales",  "stageId": "s1", "ownerRef": "o-1", "contactId": "kp1",   "market": "NL", "createdAt": "2026-10-01T08:00:00Z", "updatedAt": "2026-10-01T08:00:00Z"},
      {"recordType": "deal", "sourceId": "dP2",   "pipelineId": "sales",  "stageId": "s1", "ownerRef": "o-1", "contactId": "kp2",   "market": "NL", "createdAt": "2026-10-02T06:00:00Z", "updatedAt": "2026-10-02T06:00:00Z"},
      {"recordType": "deal", "sourceId": "dP3",   "pipelineId": "sales",  "stageId": "s1", "ownerRef": "o-1", "contactId": "kp3",   "market": "NL", "createdAt": "2026-10-02T09:00:00Z", "updatedAt": "2026-10-02T09:00:00Z"},
      {"recordType": "deal", "sourceId": "dAl",   "pipelineId": "renew",  "stageId": "r1",                    "contactId": "kp1",   "market": "Holland", "createdAt": "2026-09-15T09:00:00Z", "updatedAt": "2026-09-15T09:00:00Z"},
      {"recordType": "deal", "sourceId": "dCo",   "pipelineId": "renew",  "stageId": "r1",                    "contactId": "kco",                   "createdAt": "2026-09-15T10:00:00Z", "updatedAt": "2026-09-15T10:00:00Z"}]');
    perform cma.ingest_upsert_records(v_crm, '[{"recordType": "deal", "sourceId": "dDel", "deletedAt": "2026-10-07T14:00:00Z"}]');
    perform cma.ingest_upsert_contacts(v_crm, (
      select jsonb_agg(jsonb_build_object('sourceId', k, 'country', 'NL', 'updatedAt', '2026-10-01T00:00:00Z'))
      from unnest(array['k0', 'k1', 'k3', 'k7', 'kin', 'ka', 'kb', 'kpre', 'kunk', 'kfri', 'kr', 'kord', 'kt', 'kdel', 'kp1', 'kp2', 'kp3']) k)
      || '[{"sourceId": "kgb", "country": "GB", "updatedAt": "2026-10-01T00:00:00Z"}, {"sourceId": "kx", "updatedAt": "2026-10-01T00:00:00Z"},
           {"sourceId": "kco", "country": "United Kingdom", "updatedAt": "2026-10-01T00:00:00Z"}]'::jsonb);
    -- the calls: d1 one; d3 three (the third connected by its outcome) and one after the close; d7 seven (the second
    -- connected through its linked telephony call); dIn an inbound one; dK2 one on its second contact and one whose
    -- association was removed; dPre one 5 and one 15 minutes before the creation; dGB one connected; dFri one; dX
    -- two; dRen, dOrd, dTest and dDel one each; the week before dP1 two and dP3 one
    perform cma.ingest_upsert_calls(v_crm, (
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('sourceId', c.id, 'occurredAt', c.at, 'direction', c.dir, 'outcomeRef', c.outcome,
                                                            'counterpartHash', c.hash, 'updatedAt', c.at)))
      from (values
        ('c1a',  '2026-10-05T09:30:00Z', 'outbound', 'no_answer', null),
        ('c3a',  '2026-10-06T09:00:00Z', 'outbound', 'no_answer', null),
        ('c3b',  '2026-10-06T10:00:00Z', 'outbound', 'no_answer', null),
        ('c3c',  '2026-10-06T11:00:00Z', 'outbound', 'connected', null),
        ('c3d',  '2026-10-08T13:00:00Z', 'outbound', 'connected', null),
        ('c7a',  '2026-10-06T10:00:00Z', 'outbound', 'no_answer', null),
        ('c7b',  '2026-10-06T11:00:00Z', 'outbound', 'no_answer', v_h7),
        ('c7c',  '2026-10-07T09:00:00Z', 'outbound', 'no_answer', null),
        ('c7d',  '2026-10-07T10:00:00Z', 'outbound', 'no_answer', null),
        ('c7e',  '2026-10-07T11:00:00Z', 'outbound', 'no_answer', null),
        ('c7f',  '2026-10-08T09:00:00Z', 'outbound', 'no_answer', null),
        ('c7g',  '2026-10-09T09:00:00Z', 'outbound', 'no_answer', null),
        ('cin',  '2026-10-07T09:00:00Z', 'inbound',  'connected', null),
        ('ckb',  '2026-10-07T10:00:00Z', 'outbound', 'no_answer', null),
        ('cka',  '2026-10-07T11:00:00Z', 'outbound', 'no_answer', null),
        ('cpr0', '2026-10-08T07:45:00Z', 'outbound', 'no_answer', null),
        ('cpr1', '2026-10-08T07:55:00Z', 'outbound', 'no_answer', null),
        ('cgb',  '2026-10-09T08:30:00Z', 'outbound', 'connected', null),
        ('cfri', '2026-10-09T09:00:00Z', 'outbound', 'no_answer', null),
        ('cx1',  '2026-10-09T10:00:00Z', 'outbound', 'no_answer', null),
        ('cx2',  '2026-10-09T11:00:00Z', 'outbound', 'no_answer', null),
        ('cren', '2026-10-09T09:30:00Z', 'outbound', 'no_answer', null),
        ('cord', '2026-10-09T09:55:00Z', 'outbound', 'no_answer', null),
        ('ctst', '2026-10-07T12:30:00Z', 'outbound', 'no_answer', null),
        ('cdel', '2026-10-07T13:30:00Z', 'outbound', 'no_answer', null),
        ('cp1a', '2026-10-01T09:00:00Z', 'outbound', 'no_answer', null),
        ('cp1b', '2026-10-01T10:00:00Z', 'outbound', 'no_answer', null),
        ('cp3',  '2026-10-02T10:00:00Z', 'outbound', 'no_answer', null)) c(id, at, dir, outcome, hash)));
    perform cma.ingest_upsert_associations(v_crm, (
      select jsonb_agg(jsonb_build_object('fromType', a.ft, 'fromId', a.fi, 'toType', a.tt, 'toId', a.ti, 'removed', false,
                                          'changedAt', '2026-10-01T00:00:00Z'))
      from (values
        ('crm_call', 'c1a', 'contact', 'k1'), ('crm_call', 'c3a', 'contact', 'k3'), ('crm_call', 'c3b', 'contact', 'k3'),
        ('crm_call', 'c3c', 'deal', 'd3'), ('crm_call', 'c3d', 'contact', 'k3'),
        ('crm_call', 'c7a', 'contact', 'k7'), ('crm_call', 'c7b', 'contact', 'k7'), ('crm_call', 'c7c', 'contact', 'k7'),
        ('crm_call', 'c7d', 'contact', 'k7'), ('crm_call', 'c7e', 'contact', 'k7'), ('crm_call', 'c7f', 'contact', 'k7'),
        ('crm_call', 'c7g', 'deal', 'd7'), ('crm_call', 'cin', 'contact', 'kin'),
        ('deal', 'dK2', 'contact', 'kb'), ('crm_call', 'ckb', 'contact', 'kb'), ('crm_call', 'cka', 'contact', 'ka'),
        ('crm_call', 'cpr0', 'contact', 'kpre'), ('crm_call', 'cpr1', 'contact', 'kpre'), ('crm_call', 'cgb', 'contact', 'kgb'),
        ('crm_call', 'cfri', 'contact', 'kfri'), ('crm_call', 'cx1', 'contact', 'kx'), ('crm_call', 'cx2', 'contact', 'kx'),
        ('crm_call', 'cren', 'contact', 'kr'), ('crm_call', 'cord', 'contact', 'kord'), ('crm_call', 'ctst', 'contact', 'kt'),
        ('crm_call', 'cdel', 'contact', 'kdel'), ('crm_call', 'cp1a', 'contact', 'kp1'), ('crm_call', 'cp1b', 'contact', 'kp1'),
        ('crm_call', 'cp3', 'contact', 'kp3')) a(ft, fi, tt, ti)));
    perform cma.ingest_upsert_associations(v_crm, '[{"fromType": "crm_call", "fromId": "cka", "toType": "contact", "toId": "ka", "removed": true, "changedAt": "2026-10-07T12:00:00Z"}]');
    -- the telephony calls: t7b, answered, logged by c7b (the same hash, 30 seconds apart); an inbound call on the NL line
    perform cma.ingest_upsert_telephony_calls(v_tel, (
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('sourceId', t.id, 'direction', t.dir, 'startedAt', t.started, 'answeredAt', t.answered,
                                                            'endedAt', t.ended, 'numberRef', t.line, 'counterpartHash', t.hash, 'versionAt', t.ended)))
      from (values
        ('t7b', 'outbound', '2026-10-06T10:59:30Z', '2026-10-06T10:59:40Z', '2026-10-06T11:03:00Z', 'n-nl', v_h7),
        ('t-x', 'inbound',  '2026-10-05T12:00:00Z', '2026-10-05T12:00:10Z', '2026-10-05T12:04:00Z', 'n-nl', null)) t(id, dir, started, answered, ended, line, hash)));
    perform cma.link_calls('2026-09-01T00:00:00Z');

    -- tenant two: a deal of the same source id, never attempted
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    perform cma.set_tenant_setting('intake.start_date', '2026-09-01');
    perform set_config('app.user_id', v_ing2::text, true);
    perform cma.ingest_upsert_records(v_crm2, '[{"recordType": "deal", "sourceId": "d1", "pipelineId": "sales", "contactId": "k1", "createdAt": "2026-10-05T09:00:00Z", "updatedAt": "2026-10-05T09:00:00Z"}]');
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);

    -- B1. 0, 1, 3 and 7 attempts; the first reached attempt 3 (an outcome that counts as connected); d7's second, answered
    --     on the telephony line but with the outcome No answer, not reached (0008z); an inbound call none; a call after the
    --     close not counted (d3 stays at 3)
    select pg_temp.v0008y_deals(v_t1, v_now) into v_txt;
    v_rows := v_rows || array['11', 'B1 attempts per deal: outbound calls up to the close, reached, the first reached attempt',
      case when v_txt = 'd0:0/0/- d1:1/0/- d3:3/1/3 d7:7/0/- dFri:1/0/- dGB:1/1/1 dIn:0/0/- dK2:1/0/- dPre:1/0/- dUnk:0/0/- dX:2/0/-'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B2. a call on a second associated contact counts, a removed association not; the pre-window both ways (5 minutes
    --     before the creation in, 15 out); the linked telephony call's start is the attempt's (d7's second at 10:59:30)
    select string_agg(format('%s:%s>%s', x.deal_source_id, to_char(x.first_attempt_at at time zone 'UTC', 'DD HH24:MI'),
                             to_char(x.last_attempt_at at time zone 'UTC', 'DD HH24:MI')), ' ' order by x.deal_source_id) into v_txt
    from cma.attempts_per_deal_of(v_t1, timestamptz '2026-10-04 22:00:00+00', timestamptz '2026-10-11 22:00:00+00', v_now) x
    where x.deal_source_id in ('dK2', 'dPre', 'd3', 'd7');
    v_rows := v_rows || array['12', 'B2 a second contact''s call in, a removed association out, the pre-window both ways, the call after the close out',
      case when v_txt = 'd3:06 09:00>06 11:00 d7:06 10:00>09 09:00 dK2:07 10:00>07 10:00 dPre:08 07:55>08 07:55' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B3. the outcomes: won and lost by the stage, open, unknown for a closed stage without one
    select string_agg(format('%s:%s', x.deal_source_id, x.outcome), ' ' order by x.deal_source_id) into v_txt
    from cma.attempts_per_deal_of(v_t1, timestamptz '2026-10-04 22:00:00+00', timestamptz '2026-10-11 22:00:00+00', v_now) x
    where x.deal_source_id in ('d0', 'd3', 'd7', 'dUnk');
    v_rows := v_rows || array['13', 'B3 the outcomes won, lost, open and unknown',
      case when v_txt = 'd0:open d3:won d7:lost dUnk:unknown' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B4. no scope (0008z): only the lead pipelines; the pipeline that counts but is no lead pipeline (dRen, dAl, dCo), the order
    --     pipeline (marked lead), the uncounted pipeline and the deleted deal are out, since the intake start
    select string_agg(x.deal_source_id, ' ' order by x.deal_source_id) into v_txt from cma.attempts_per_deal_of(v_t1, null, null, v_now) x;
    v_rows := v_rows || array['14', 'B4 only the lead pipelines: dRen, the order pipeline, the uncounted one and the deleted deal out',
      case when v_txt = 'd0 d1 d3 d7 dFri dGB dIn dK2 dP1 dP2 dP3 dPre dUnk dX'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B5. the business days since the last attempt (or the creation) of the open deals on Wednesday 14 October: across
    --     the weekend and the NL holiday of Tuesday 13 (dFri NL 2, dGB GB 3, from the same Friday), never attempted from
    --     the creation (d0 6, dIn 4), an unknown market none; closed deals none; the buckets of '1,2,5'
    select string_agg(format('%s:%s:%s', x.deal_source_id, coalesce(x.business_days_since_last::text, '-'), coalesce(x.since_last_bucket, '-')),
                      ' ' order by x.deal_source_id) into v_txt
    from cma.attempts_per_deal_of(v_t1, timestamptz '2026-10-04 22:00:00+00', timestamptz '2026-10-11 22:00:00+00', v_now) x;
    v_rows := v_rows || array['15', 'B5 business days since the last attempt across a weekend and a holiday, never attempted, unknown market none',
      case when v_txt = 'd0:6:5+ d1:6:5+ d3:-:- d7:-:- dFri:2:1–2 dGB:3:2–5 dIn:4:2–5 dK2:4:2–5 dPre:3:2–5 dUnk:-:- dX:-:-'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B6. the page's buckets with the default top (5+: d7's seven there), the first connected attempt and won and lost
    --     per bucket; with attempts.max_bucket 8, d7 in 7 and the top 8+
    j := cma.attempts_per_deal_page_of(v_t1, date '2026-10-05', date '2026-10-11', 'day', null, null, 'all', 'all', 100, v_now);
    select string_agg(format('%s:%s/%s/%s/%s', b ->> 'label', b ->> 'deals', b ->> 'first_reached', b ->> 'won', b ->> 'lost'), ' ' order by (b ->> 'bucket')::int)
      into v_txt from jsonb_array_elements(j -> 'buckets') b;
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('attempts.max_bucket', '8');
    perform set_config('app.user_id', v_analyst1::text, true);
    j := cma.attempts_per_deal_page_of(v_t1, date '2026-10-05', date '2026-10-11', 'day', null, null, 'all', 'all', 100, v_now);
    select v_txt || ' | ' || string_agg(format('%s:%s', b ->> 'label', b ->> 'deals'), ' ' order by (b ->> 'bucket')::int)
      into v_txt from jsonb_array_elements(j -> 'buckets') b;
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('attempts.max_bucket', '5');
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['16', 'B6 the buckets 0 to 5+ (7 attempts in 5+) with first reached, won and lost; with max_bucket 8, 7 in 7',
      case when v_txt = '0:3/0/0/0 1:5/1/0/0 2:1/0/0/0 3:1/1/1/0 4:0/0/0/0 5+:1/0/0/1 | 0:3 1:5 2:1 3:1 4:0 5:0 6:0 7:1 8+:0'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B7. the figures of the period: deals, attempted, attempts, average and median per deal, reached on the first
    --     attempt, any reached, open, open never attempted, won, lost (0008z: no counted scope)
    j := cma.attempts_per_deal_page_of(v_t1, date '2026-10-05', date '2026-10-11', 'day', null, null, 'all', 'all', 100, v_now);
    v_txt := pg_temp.v0008y_fig(j -> 'current');
    v_rows := v_rows || array['17', 'B7 the period''s figures',
      case when v_txt = '11/8/17/1.55/1.0/1/2/8/2/1/1' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B8. the groups: per day, per market (unknown its own), per pipeline (counted: Renewals and Sales by label)
    select string_agg(format('%s=%s/%s', g ->> 'key', g ->> 'deals', g ->> 'attempts'), ' ') into v_txt from jsonb_array_elements(j -> 'groups') g;
    select v_txt || ' | ' || string_agg(format('%s=%s/%s', g ->> 'key', g ->> 'deals', g ->> 'attempts'), ' ') into v_txt
    from jsonb_array_elements(cma.attempts_per_deal_page_of(v_t1, date '2026-10-05', date '2026-10-11', 'market', null, null, 'all', 'all', 100, v_now) -> 'groups') g;
    select v_txt || ' | ' || string_agg(format('%s=%s/%s', g ->> 'label', g ->> 'deals', g ->> 'attempts'), ' ') into v_txt
    from jsonb_array_elements(cma.attempts_per_deal_page_of(v_t1, date '2026-10-05', date '2026-10-11', 'pipeline', null, null, 'all', 'all', 100, v_now) -> 'groups') g;
    v_rows := v_rows || array['18', 'B8 the figures per day, market and pipeline (the lead pipelines only)',
      case when v_txt = '2026-10-05=2/1 2026-10-06=2/10 2026-10-07=2/1 2026-10-08=2/1 2026-10-09=3/4 | GB=1/1 NL=9/14 unknown=1/2 | Sales=11/17'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B9. the previous period like for like: after the period the whole week before (dP1, dP2, dP3); while it runs
    --     (Friday 09:30) the same elapsed dates, Friday 2 October up to 09:30 (dP3 at 11:00 out)
    v_txt := pg_temp.v0008y_fig(j -> 'previous') || ' ' ||
             pg_temp.v0008y_fig(cma.attempts_per_deal_page_of(v_t1, date '2026-10-05', date '2026-10-11', 'day', null, null, 'all', 'all', 100, v_running) -> 'previous');
    v_rows := v_rows || array['19', 'B9 the previous period like for like: in full after the period, up to the time of day while it runs',
      case when v_txt = '3/2/3/1.00/1.0/0/0/3/1/0/0 2/1/2/1.00/1.0/0/0/2/1/0/0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B10. the open deals by the business days since their last attempt, every bucket listed, the unknown market apart
    select string_agg(format('%s:%s', b ->> 'label', b ->> 'deals'), ' ' order by (b ->> 'from')::int) || ' no_hours:' || (j -> 'since_last' ->> 'no_hours')
      into v_txt from jsonb_array_elements(j -> 'since_last' -> 'buckets') b;
    v_rows := v_rows || array['20', 'B10 the open deals by time since the last attempt, the unknown market apart',
      case when v_txt = '0–1:0 1–2:1 2–5:4 5+:2 no_hours:1' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B11. the list: open first, the longest since the last attempt first (then the earlier last attempt or creation),
    --      the unknown market after them, then closed, the newest close first; capped with the total; links and ids
    select string_agg(r ->> 'deal_source_id', ' ' order by o) into v_txt from jsonb_array_elements(j -> 'list' -> 'rows') with ordinality as x(r, o);
    select v_txt || ' | ' || string_agg(r ->> 'deal_source_id', ' ' order by o) || ' of ' || (jj -> 'list' ->> 'total')
           || ' ' || ((jj -> 'list' -> 'rows' -> 0 ->> 'record_url') = 'https://crm.example.invalid/portal-1/deal/d0')::text
      into v_txt
    from (select cma.attempts_per_deal_page_of(v_t1, date '2026-10-05', date '2026-10-11', 'day', null, null, 'all', 'all', 4, v_now) as jj) p
    cross join lateral jsonb_array_elements(p.jj -> 'list' -> 'rows') with ordinality as x(r, o)
    group by p.jj;
    v_rows := v_rows || array['21', 'B11 the list''s order, its cap and total, the record link',
      case when v_txt = 'd0 d1 dIn dK2 dPre dGB dFri dX d7 d3 dUnk | d0 d1 dIn dK2 of 11 true' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B12. the filters narrow every figure; the filter lists come from the period without them; the history start (the
    --      later of the intake start and the earliest stored CRM call's date) and the settings
    j := cma.attempts_per_deal_page_of(v_t1, date '2026-10-05', date '2026-10-11', 'day', 'GB', null, 'all', 'all', 100, v_now);
    v_txt := pg_temp.v0008y_fig(j -> 'current') || ' ' || (j ->> 'markets') || ' '
             || (select string_agg(p ->> 'label', ',') from jsonb_array_elements(j -> 'pipelines') p) || ' '
             || pg_temp.v0008y_fig(cma.attempts_per_deal_page_of(v_t1, date '2026-10-05', date '2026-10-11', 'day', null, v_crm::text || ':sales',
                                                                 'all', 'all', 100, v_now) -> 'current')
             || ' ' || (j ->> 'history_start') || ' ' || (j -> 'settings' ->> 'max_bucket') || '/' || (j -> 'settings' ->> 'since_last_buckets')
             || '/' || (j -> 'settings' ->> 'pre_window_minutes') || '/' || (j -> 'settings' ->> 'list_rows');
    v_rows := v_rows || array['22', 'B12 the market and pipeline filters, the filter lists (lead pipelines only), the history start and the settings',
      case when v_txt = '1/1/1/1.00/1.0/1/1/1/0/0/0 ["GB", "NL", "unknown"] Sales 11/8/17/1.55/1.0/1/2/8/2/1/1 2026-10-01 5/1,2,5/10/100'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B13. the parameters and the range: more than 92 days, a group, a scope, a market and a pipeline outside the
    --      catalog refused; the page for reports.view and performance.team, not for an agent or the Ingest user; no
    --      acting user CMA01
    perform set_config('app.user_id', v_reader1::text, true);
    v_txt := pg_temp.v0008y_code('select cma.attempts_per_deal_page(date ''2026-01-01'', date ''2026-10-11'', ''day'', null, null)') || ' '
      || pg_temp.v0008y_code('select cma.attempts_per_deal_page(date ''2026-10-05'', date ''2026-10-11'', ''owner'', null, null)') || ' '
      || pg_temp.v0008y_code('select cma.attempts_per_deal_page(date ''2026-10-05'', date ''2026-10-11'', ''day'', null, null, ''every'')') || ' '
      || pg_temp.v0008y_code('select cma.attempts_per_deal_page(date ''2026-10-05'', date ''2026-10-11'', ''day'', ''nl'', null)') || ' '
      || pg_temp.v0008y_code('select cma.attempts_per_deal_page(date ''2026-10-05'', date ''2026-10-11'', ''day'', null, ''sales'')') || ' ';
    foreach v_detail in array array[v_reader1::text, v_super1::text, v_analyst1::text, v_agent1::text, v_ing1::text] loop
      perform set_config('app.user_id', v_detail, true);
      v_txt := v_txt || pg_temp.v0008y_code('select cma.attempts_per_deal_page(date ''2026-10-05'', date ''2026-10-11'', ''week'', null, null)') || '/'
        || pg_temp.v0008y_code(format('select cma.attempts_per_deal_page(date ''2026-10-05'', date ''2026-10-11'', ''pipeline'', ''unknown'', %L, ''all'', ''all'', 5)',
                                      v_crm::text || ':sales')) || ' ';
    end loop;
    perform set_config('app.user_id', '', true);
    v_txt := v_txt || pg_temp.v0008y_code('select cma.attempts_per_deal_page(date ''2026-10-05'', date ''2026-10-11'', ''day'', null, null)');
    v_rows := v_rows || array['23', 'B13 the 92-day bound and the parameters refused (the attempted filter in the scope''s place); the page for reports.view or performance.team only',
      case when v_txt = 'CMA04 CMA04 CMA04 CMA04 CMA04 ok/ok ok/ok ok/ok CMA06/CMA06 CMA06/CMA06 CMA01' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B14. per person by name, never ranked, the deals each owns: Anna (d0, d1, dK2), Bram (d3, dPre, dGB), the deals of
    --      o-3 and of no owner as one not-linked row with one owner id, the total
    perform set_config('app.user_id', v_super1::text, true);
    j := cma.attempts_per_person_of(v_t1, date '2026-10-05', date '2026-10-11', null, null, 'all', 'all', v_now);
    select string_agg(format('%s:%s', p ->> 'display_name', pg_temp.v0008y_fig(p)), ' ' order by o) into v_txt
    from jsonb_array_elements(j -> 'rows') with ordinality as x(p, o);
    v_txt := v_txt || format(' not_linked(%s):%s total:%s', j -> 'not_linked' ->> 'unlinked_owners', pg_temp.v0008y_fig(j -> 'not_linked'),
                             pg_temp.v0008y_fig(j -> 'total'));
    v_rows := v_rows || array['24', 'B14 per person by name with the not-linked row and the total',
      case when v_txt = 'Anna Verify:3/2/2/0.67/1.0/0/0/3/1/0/0 Bram Verify:3/3/5/1.67/1.0/1/2/2/0/1/0 '
                        || 'not_linked(1):5/3/10/2.00/1.0/0/0/3/1/0/1 total:11/8/17/1.55/1.0/1/2/8/2/1/1'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B15. per person's gates: for performance.team while reports.per_person holds attempts; refused (CMA06) once it
    --      does not, and for the agent and for reports.view alone
    v_txt := pg_temp.v0008y_code('select cma.attempts_per_person_page(date ''2026-10-05'', date ''2026-10-11'', null, null)');
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('reports.per_person', 'email,orders');
    perform set_config('app.user_id', v_super1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008y_code('select cma.attempts_per_person_page(date ''2026-10-05'', date ''2026-10-11'', null, null)');
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('reports.per_person', 'attempts');
    foreach v_detail in array array[v_agent1::text, v_reader1::text] loop
      perform set_config('app.user_id', v_detail, true);
      v_txt := v_txt || ' ' || pg_temp.v0008y_code('select cma.attempts_per_person_page(date ''2026-10-05'', date ''2026-10-11'', null, null)');
    end loop;
    v_rows := v_rows || array['25', 'B15 per person needs performance.team and attempts in reports.per_person',
      case when v_txt = 'ok CMA06 CMA06 CMA06' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B16. the settings refuse what the catalog does not take, and normalise the spaces of the buckets
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := '';
    foreach v_detail in array array['attempts.max_bucket=1', 'attempts.max_bucket=21', 'attempts.max_bucket=x', 'attempts.max_bucket=20',
                                    'attempts.since_last_buckets_business_days=0,1', 'attempts.since_last_buckets_business_days=2,1',
                                    'attempts.since_last_buckets_business_days=1,2,3,4,5,6,7', 'attempts.since_last_buckets_business_days=1,2,3,4,5,6',
                                    'reports.per_person=attempts,attempts', 'reports.per_person=calls', 'reports.per_person=email,orders,attempts'] loop
      v_txt := v_txt || pg_temp.v0008y_code(format('select cma.set_tenant_setting(%L, %L)', split_part(v_detail, '=', 1), substr(v_detail, strpos(v_detail, '=') + 1))) || ' ';
    end loop;
    perform cma.set_tenant_setting('attempts.since_last_buckets_business_days', ' 1, 2 ,5');
    v_txt := v_txt || cma.setting_of(v_t1, 'attempts.since_last_buckets_business_days');
    perform cma.set_tenant_setting('attempts.max_bucket', '5');
    perform cma.set_tenant_setting('reports.per_person', 'attempts');
    v_rows := v_rows || array['26', 'B16 the settings'' refusals and the buckets'' spaces',
      case when v_txt = 'CMA04 CMA04 CMA04 ok CMA04 CMA04 CMA04 ok CMA04 CMA04 ok 1,2,5' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B17. the stored calls a line holds and the first one's start; none on a line without calls; an unknown line
    --      CMA02; refused without tenant.configure
    select format('%s/%s', s.stored_calls, to_char(s.first_started_at at time zone 'UTC', 'YYYY-MM-DD HH24:MI')) into v_txt
    from cma.telephony_number_stored_calls(v_tel, 'n-nl') s;
    select v_txt || format(' %s/%s', s.stored_calls, coalesce(s.first_started_at::text, '-')) into v_txt from cma.telephony_number_stored_calls(v_tel, 'n-gb') s;
    v_txt := v_txt || ' ' || pg_temp.v0008y_code(format('select cma.telephony_number_stored_calls(%L, ''n-zz'')', v_tel));
    perform set_config('app.user_id', v_analyst1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008y_code(format('select cma.telephony_number_stored_calls(%L, ''n-nl'')', v_tel));
    v_rows := v_rows || array['27', 'B17 the stored calls of a line and the first one''s start, for tenant.configure only',
      case when v_txt = '2/2026-10-05 12:00 0/- CMA02 CMA06' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B18. tenant isolation: tenant two's page holds its own deal only (none of tenant one's calls), and it cannot read
    --      tenant one's line
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_analyst2::text, true);
    j := cma.attempts_per_deal_page(date '2026-10-05', date '2026-10-11', 'day', null, null);
    v_txt := pg_temp.v0008y_fig(j -> 'current') || ' ' || (j -> 'list' -> 'rows' -> 0 ->> 'deal_source_id');
    perform set_config('app.user_id', v_admin2::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008y_code(format('select cma.telephony_number_stored_calls(%L, ''n-nl'')', v_tel));
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['28', 'B18 tenant isolation for the pages and the line count',
      case when v_txt = '1/0/0/0.00/0.0/0/0/1/1/0/0 d1 CMA02' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    -- B19. the reader view: scoped to tenant one, the application's rows of the lead pipelines since the intake start
    --      (the week's eleven and the three before; 0008z's columns), column by column; scoped to tenant two none of tenant one's
    select string_agg(concat_ws('|', r.deal_id, r.connection_id, r.deal_source_id, r.pipeline_id, r.pipeline_label, r.stage_id, r.market, r.owner_user_id,
                                r.created_at, r.business_date, r.is_closed, r.closed_at, r.ordered_at, r.window_end_reason, r.outcome, r.attempts,
                                r.reached_attempts, r.first_reached_attempt, r.talk_seconds_total, r.talk_seconds_reached, r.first_attempt_at,
                                r.speed_to_lead_seconds, r.called_before_next_noon, r.last_attempt_at, r.business_days_since_last, r.since_last_bucket,
                                r.attempts_without_outcome, r.logged_without_aircall), ';' order by r.deal_id) into v_app
    from cma.attempts_per_deal_of(v_t1, null, null) r;
    perform set_config('role', 'cma_readonly', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    select string_agg(concat_ws('|', r.deal_id, r.connection_id, r.deal_source_id, r.pipeline_id, r.pipeline_label, r.stage_id, r.market, r.owner_user_id,
                                r.created_at, r.business_date, r.is_closed, r.closed_at, r.ordered_at, r.window_end_reason, r.outcome, r.attempts,
                                r.reached_attempts, r.first_reached_attempt, r.talk_seconds_total, r.talk_seconds_reached, r.first_attempt_at,
                                r.speed_to_lead_seconds, r.called_before_next_noon, r.last_attempt_at, r.business_days_since_last, r.since_last_bucket,
                                r.attempts_without_outcome, r.logged_without_aircall), ';' order by r.deal_id) into v_view
    from cma_read.attempts_per_deal r where r.tenant_id = v_t1;
    select format('%s %s', (select count(*) from cma_read.attempts_per_deal where tenant_id = v_t1), (v_view = v_app)::text) into v_txt;
    perform set_config('app.tenant_id', v_t2::text, true);
    select v_txt || format(' %s', (select count(*) from cma_read.attempts_per_deal where tenant_id = v_t1)) into v_txt;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    v_rows := v_rows || array['29', 'B19 the reader view equals the application''s rows for its tenant and shows no other tenant''s',
      case when v_txt = '14 true 0' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    -- B20. the population written once: cma.lead_deals_of gives 0008q's rows (0 apart, both ways), and every deal's
    --      market is cma.record_market_of's (an alias, a contact's country, unknown)
    select format('%s/%s', (select count(*) from (select * from cma.lead_deals_of(v_t1, null, null)
                                                  except select * from pg_temp.v0008y_lead_deals_0008q(v_t1, null, null)) x),
                           (select count(*) from (select * from pg_temp.v0008y_lead_deals_0008q(v_t1, null, null)
                                                  except select * from cma.lead_deals_of(v_t1, null, null)) x))
           || format(' %s ', (select count(*) from cma.counted_deals_of(v_t1, null, null) c
                              cross join lateral cma.record_market_of(v_t1, c.connection_id,
                                (select r.market from cma.crm_record r where r.id = c.deal_id), c.contact_source_id) rm
                              where (c.market, c.market_source) is distinct from (rm.code, rm.source)))
           || (select string_agg(format('%s:%s/%s', c.source_id, c.market, coalesce(c.market_source, '-')), ' ' order by c.source_id)
               from cma.counted_deals_of(v_t1, null, null) c where c.source_id in ('dAl', 'dCo', 'dX', 'd0'))
      into v_txt;
    v_rows := v_rows || array['30', 'B20 cma.lead_deals_of gives 0008q''s rows; every market as cma.record_market_of gives it',
      case when v_txt = '0/0 0 d0:NL/record dAl:NL/record dCo:GB/contact dX:unknown/-' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'null')];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['39', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008y (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008y values (39, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008y
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED: not dev'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008y where result = 'PASS') = 25
                       and not exists (select 1 from verify_0008y where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0008y where result = 'PASS'),
                                        (select count(*) from verify_0008y where result <> 'PASS'))) x
order by ord;
drop function if exists pg_temp.v0008y_code(text);
drop function if exists pg_temp.v0008y_deals(uuid, timestamptz);
drop function if exists pg_temp.v0008y_fig(jsonb);
drop function if exists pg_temp.v0008y_lead_deals_0008q(uuid, timestamptz, timestamptz);
