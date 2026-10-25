-- =============================================================================================
-- 105_verify_reviews.sql: verifies addition 0008ze, reviews (channels, reviews, links, alerts and reports)
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure and privileges;
-- blocks B and C work on throwaway tenants inside subtransactions that are always rolled back. Universal otherwise:
-- nothing of the seed is used; adapters, channels, reviews, orders, contacts and people are invented data values, and
-- no row carries a name of a customer, an address, an email or a phone number. Every check writes one row, PASS or
-- FAIL, and the last result lists them with the verdict, because Cloud SQL Studio shows no notices. Run as your own IAM
-- login in dev, after 104_reviews.sql; then 103, 101, 99, 79, 75 and 41 again.
--   A  structure and privileges: the addition row after 0008zd; the two tables' columns, keys and checks (the link
--      rules, the filtered raw, the market's foreign key); the connection kind reviews, the trigger review_submitted
--      and max_rating; row-level security with the tenant policy, the audit trigger, no delete for the application and
--      nothing for the readers on the tables; every function the application's only and in the caller's rights, the
--      readers' functions definer, the owner's, pinned, theirs only; the reporting views' exact columns with no raw,
--      name of a person, email, phone, title or text; the two settings, the job name, the data-quality catalog; the
--      redefinitions carry what came before (0008n's held kinds, 0008zc's data quality, 0008p's checks)
--   B  behaviour, on two throwaway tenants (Europe/Amsterdam; markets NL, GB, FR, DE active). Tenant one holds a CRM
--      connection, a store connection with three orders (one whose customer is linked to contact c-1, 0008h) and a
--      reviews connection with five channels (NL, GB, FR counted; an unmapped one; one the source drops). Tenant two
--      holds a reviews connection of its own. Checked as of fixed instants: the channel catalog (a new channel unmapped
--      and not counted, a rename, a channel gone, an empty list, the configuration kept), the kind, the reviews'
--      outcomes and links (by order name, by source id, the order's customer's contact, none), the stale guard and a
--      state change, the filtered raw and the refusals, the email contact (linked, unchanged, relinked, an order's
--      review, cleared), an order that arrives later, the privacy deletion, the settings, the review rules, the report
--      (figures, previous period like for like, distribution, groups, markets, channels, link levels, invite events,
--      markets' states, the filter), its parameters and permissions, data quality, the reader views, the alerts,
--      tenant isolation, the sources' catalog, the job's run, the audit
--   C  speed: a throwaway tenant with 20,000 reviews over two years on eight channels; the page of 92 days as the
--      application (row-level security on) under verify.max_ms, the best of three
-- Provoke: set provoke below to true; every check must then read FAIL, and the verdict says PROVOKED instead of PASS.
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
select set_config('verify.max_ms', '1000', false);     -- the page of 92 days, as the application

-- Dev only: a verifier that writes refuses a database without the dev seed. The flag is kept for the session, so every
-- block below stops at once and the verdict says REFUSED, also where the client carries on after the error
select set_config('verify.is_dev', (exists (select 1 from cma.app_user u join cma.tenant t on t.id = u.tenant_id
                                            where u.email = 'agent.two@example.com' and u.status = 'active'))::text, false) as is_dev;
do $$
begin
  if not current_setting('verify.is_dev')::boolean then
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 105 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0008ze;
create temp table verify_0008ze (ord int, check_name text, result text, detail text);

-- The error code a statement raises, or 'ok'
create or replace function pg_temp.v0008ze_code(p_sql text)
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

-- The fastest of p_runs runs of a read, in milliseconds, every row fetched (as 91)
create or replace function pg_temp.v0008ze_best_ms(p_sql text, p_runs integer)
returns numeric
language plpgsql
as $$
declare
  v_t0   timestamptz;
  v_ms   numeric;
  v_best numeric;
  r      record;
begin
  for i in 1 .. p_runs loop
    v_t0 := clock_timestamp();
    for r in execute p_sql loop
      null;
    end loop;
    v_ms := round(extract(epoch from clock_timestamp() - v_t0) * 1000, 1);
    v_best := least(coalesce(v_best, v_ms), v_ms);
  end loop;
  return v_best;
end
$$;

-- A figures object as one line: reviews/average/negative/order/contact/none (- for no average)
create or replace function pg_temp.v0008ze_fig(j jsonb)
returns text
language sql
as $$
  select concat_ws('/', j ->> 'reviews', coalesce(j ->> 'average_rating', '-'), j ->> 'negative', j ->> 'linked_order',
                   j ->> 'linked_contact', j ->> 'unlinked')
$$;

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_bad     text;
  v_fn      text;
  v_t       text;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  -- A1. the addition is recorded, after 0008zd
  insert into verify_0008ze values (1, 'A1 addition 0008ze recorded, after 0008zd',
    case when exists (select 1 from cma.schema_migration where version = '0008ze')
              and exists (select 1 from cma.schema_migration where version = '0008zd') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the tables: columns with types and nullability
  v_bad := '';
  if (select string_agg(column_name || ':' || udt_name || ':' || is_nullable, ',' order by ordinal_position)
      from information_schema.columns where table_schema = 'cma' and table_name = 'review_channel')
     is distinct from 'id:uuid:NO,tenant_id:uuid:NO,connection_id:uuid:NO,source_id:text:NO,name:text:NO,locale:text:YES,market:text:YES,'
                      || 'is_counted:bool:NO,first_seen_at:timestamptz:NO,source_deleted_at:timestamptz:YES,updated_at:timestamptz:NO' then
    v_bad := v_bad || 'review_channel columns; ';
  end if;
  if (select string_agg(column_name || ':' || udt_name || ':' || is_nullable, ',' order by ordinal_position)
      from information_schema.columns where table_schema = 'cma' and table_name = 'review')
     is distinct from 'id:uuid:NO,tenant_id:uuid:NO,connection_id:uuid:NO,review_channel_id:uuid:NO,source_system:text:NO,source_id:text:NO,'
                      || 'review_type:text:NO,state:text:NO,is_published:bool:NO,rating:numeric:NO,submitted_at:timestamptz:NO,'
                      || 'source_updated_at:timestamptz:YES,has_reply:bool:NO,invite_event_type:text:YES,transaction_ref:text:YES,'
                      || 'link_level:text:NO,commerce_order_id:uuid:YES,crm_connection_id:uuid:YES,crm_contact_source_id:text:YES,'
                      || 'matched_at:timestamptz:YES,raw:jsonb:NO,synced_at:timestamptz:NO' then
    v_bad := v_bad || 'review columns; ';
  end if;
  if (select numeric_precision || ',' || numeric_scale from information_schema.columns
      where table_schema = 'cma' and table_name = 'review' and column_name = 'rating') is distinct from '3,2'
     or (select numeric_precision || ',' || numeric_scale from information_schema.columns
         where table_schema = 'cma' and table_name = 'message_rule' and column_name = 'max_rating') is distinct from '3,2' then
    v_bad := v_bad || 'rating or max_rating not numeric(3,2); ';
  end if;
  insert into verify_0008ze values (2, 'A2 the two tables'' columns, types and nullability; rating and max_rating numeric(3,2)',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A3. keys and checks: one review per connection and source id, one channel likewise; the link rules; the filtered
  --     raw; the market's foreign key; the kind reviews; the trigger review_submitted with max_rating's checks
  v_bad := '';
  if not exists (select 1 from pg_constraint where conrelid = 'cma.review'::regclass and contype = 'u'
                 and pg_get_constraintdef(oid) = 'UNIQUE (tenant_id, connection_id, source_id)')
     or not exists (select 1 from pg_constraint where conrelid = 'cma.review_channel'::regclass and contype = 'u'
                    and pg_get_constraintdef(oid) = 'UNIQUE (tenant_id, connection_id, source_id)') then
    v_bad := v_bad || 'unique keys; ';
  end if;
  if (select count(*) from pg_constraint where conrelid = 'cma.review'::regclass and contype = 'c'
      and (pg_get_constraintdef(oid) like '%link_level%' or pg_get_constraintdef(oid) like '%crm_connection_id IS NULL%')) < 5
     or not exists (select 1 from pg_constraint where conrelid = 'cma.review'::regclass and contype = 'c'
                    and pg_get_constraintdef(oid) like '%review_raw_ok(raw)%') then
    v_bad := v_bad || 'the link or raw checks; ';
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'cma.review_channel'::regclass and contype = 'f'
                 and pg_get_constraintdef(oid) like '%(tenant_id, market) REFERENCES %market(tenant_id, code)%')
     or (select count(*) from pg_constraint where conrelid = 'cma.review'::regclass and contype = 'f') <> 5 then
    v_bad := v_bad || 'foreign keys; ';
  end if;
  if (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.integration_connection'::regclass
      and conname = 'integration_connection_kind_check') not like '%''reviews''%'
     or (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.message_rule'::regclass
         and conname = 'message_rule_trigger_check') not like '%''record_created''%''record_assigned''%''review_submitted''%'
     or not exists (select 1 from pg_constraint where conrelid = 'cma.message_rule'::regclass and conname = 'message_rule_max_rating_check')
     or not exists (select 1 from pg_constraint where conrelid = 'cma.message_rule'::regclass and conname = 'message_rule_review_check') then
    v_bad := v_bad || 'kind, trigger or max_rating checks; ';
  end if;
  if not cma.review_raw_ok('{"id": "rev-1", "event": {"type": "checkout"}, "transaction": {"reference": "X-1"}}')
     or cma.review_raw_ok('{"comment": "a text"}') or cma.review_raw_ok('{"customer": {}}') or cma.review_raw_ok('{"title": "t"}')
     or cma.review_raw_ok('{"event": {"type": "checkout", "email": "x"}}') or cma.review_raw_ok('[]') then
    v_bad := v_bad || 'review_raw_ok; ';
  end if;
  insert into verify_0008ze values (3, 'A3 keys, the link rules, the filtered raw, the market''s key, the kind and the trigger',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A4. tenant-aware as every table: row-level security with the tenant policy, the audit trigger; the application may
  --     read, add and change, never delete; the readers nothing on the tables
  v_bad := '';
  foreach v_t in array array['cma.review_channel', 'cma.review'] loop
    if not (select relrowsecurity from pg_class where oid = v_t::regclass)
       or not exists (select 1 from pg_policy where polrelid = v_t::regclass and polname = 'tenant_app')
       or not exists (select 1 from pg_trigger where tgrelid = v_t::regclass and tgname = 'audit' and not tgisinternal)
       or not has_table_privilege('cma_app', v_t, 'select') or not has_table_privilege('cma_app', v_t, 'insert')
       or not has_table_privilege('cma_app', v_t, 'update') or has_table_privilege('cma_app', v_t, 'delete')
       or has_table_privilege('cma_readonly', v_t, 'select') then
      v_bad := v_bad || v_t || '; ';
    end if;
  end loop;
  insert into verify_0008ze values (4, 'A4 row-level security, the audit trigger, no delete for the application, nothing for the readers',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A5. every function the application's only and in the caller's rights; the readers' functions definer, the owner's,
  --     search path pinned with pg_temp last, the readers' only
  v_bad := '';
  foreach v_fn in array array[
    'cma.connection_held_kinds_of(uuid,uuid)', 'cma.set_connection_kind(uuid,text)', 'cma.reviews_set_up_of(uuid)',
    'cma.assert_reviews_connection(uuid)', 'cma.ingest_upsert_review_channels(uuid,jsonb)', 'cma.review_order_of(uuid,text)',
    'cma.ingest_upsert_reviews(uuid,jsonb)', 'cma.set_review_contact(uuid,text,uuid,text)', 'cma.forget_review_contact_links(uuid,text)',
    'cma.upsert_review_rule(text,text,boolean,boolean,text,text,numeric,integer)', 'cma.message_rules()',
    'cma.ingest_review_alerts(uuid,text[])', 'cma.set_review_channel(uuid,text,text,boolean)', 'cma.connection_catalogs(uuid)',
    'cma.data_quality_reviews_checks()', 'cma.data_quality_of(uuid)', 'cma.data_quality()', 'cma.reviews_of(uuid)',
    'cma.review_market_states_of(uuid)', 'cma.review_figures(bigint,numeric,bigint,bigint,bigint,bigint)', 'cma.reviews_page_of(uuid,date,date,text,text,timestamptz)',
    'cma.reviews_page(date,date,text,text)', 'cma.review_raw_ok(jsonb)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure(v_fn) and a.grantee = 0) then
      v_bad := v_bad || v_fn || '; ';
    end if;
  end loop;
  foreach v_fn in array array['cma_read.review_rows()', 'cma_read.review_market_state_rows()'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif not (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
          or (select pg_get_userbyid(proowner) from pg_proc where oid = to_regprocedure(v_fn)) <> 'cma_owner'
          or (select array_to_string(proconfig, ',') from pg_proc where oid = to_regprocedure(v_fn)) is distinct from 'search_path=pg_catalog, cma, pg_temp'
          or not has_function_privilege('cma_readonly', v_fn, 'execute') or has_function_privilege('cma_app', v_fn, 'execute')
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = to_regprocedure(v_fn) and a.grantee = 0) then
      v_bad := v_bad || v_fn || '; ';
    end if;
  end loop;
  insert into verify_0008ze values (5, 'A5 every function the application''s only and invoker; the readers'' functions definer, the owner''s, pinned, theirs only',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A6. the reporting views' exact columns, readable by the readers; no raw, name of a person, email, phone, title or text
  v_bad := '';
  if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'review')
     is distinct from 'id,tenant_id,connection_id,review_channel_id,source_system,source_id,review_type,state,is_published,rating,submitted_at,'
                      || 'source_updated_at,has_reply,invite_event_type,transaction_ref,link_level,commerce_order_id,crm_connection_id,'
                      || 'crm_contact_source_id,matched_at,synced_at' then
    v_bad := v_bad || 'review; ';
  end if;
  if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'review_channel')
     is distinct from 'id,tenant_id,connection_id,source_id,name,locale,market,is_counted,first_seen_at,source_deleted_at,updated_at' then
    v_bad := v_bad || 'review_channel; ';
  end if;
  foreach v_t in array array['reviews_per_day:business_date', 'reviews_per_week:week_start', 'reviews_per_market:market,week_start',
                             'reviews_per_channel:review_channel_id,channel_name,market,week_start'] loop
    if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
        where table_schema = 'cma_read' and table_name = split_part(v_t, ':', 1))
       is distinct from 'tenant_id,' || split_part(v_t, ':', 2) || ',reviews,average_rating,stars_1,stars_2,stars_3,stars_4,stars_5,negative,'
                        || 'linked_order,linked_contact,unlinked,previous_reviews,previous_average_rating' then
      v_bad := v_bad || split_part(v_t, ':', 1) || '; ';
    end if;
  end loop;
  if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'review_market_state') is distinct from 'tenant_id,market,name,state,channels,reviews'
     or (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
         where table_schema = 'cma_read' and table_name = 'dq_review_channel_unmapped') is distinct from 'tenant_id,connection_id,object_type,object_id,value'
     or (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
         where table_schema = 'cma_read' and table_name = 'dq_market_without_review_channel') is distinct from 'tenant_id,connection_id,object_type,object_id,value' then
    v_bad := v_bad || 'review_market_state or the dq_ views; ';
  end if;
  if exists (select 1 from information_schema.columns
             where table_schema = 'cma_read' and (table_name like 'review%' or table_name like 'dq_%review%')
               and column_name ~ '(raw|email|phone|mobile|address|title|comment|full_?name|customer)') then
    v_bad := v_bad || 'a personal, text or raw column; ';
  end if;
  foreach v_t in array array['review', 'review_channel', 'reviews_per_day', 'reviews_per_week', 'reviews_per_market', 'reviews_per_channel',
                             'review_market_state', 'dq_review_channel_unmapped', 'dq_market_without_review_channel'] loop
    if not has_table_privilege('cma_readonly', 'cma_read.' || v_t, 'select') then
      v_bad := v_bad || v_t || ' not readable; ';
    end if;
  end loop;
  insert into verify_0008ze values (6, 'A6 the reporting views'' exact columns, readable; no raw, person''s name, email, phone, title or text',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A7. the two settings (2; empty), the job name reviews_poll, the data-quality catalog (210, 220), nothing twice
  v_bad := '';
  if (select string_agg(s.key || ':' || s.value_type || ':' || s.default_value, ' ' order by s.key) from cma.setting s
      where s.key like 'reviews.%') is distinct from 'reviews.history_start_date:text: reviews.negative_max_rating:integer:2' then
    v_bad := v_bad || 'settings; ';
  end if;
  if (select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cma.sync_run'::regclass and conname = 'sync_run_job_check')
     not like '%''refresh_follow_up''%''reviews_poll''%' then
    v_bad := v_bad || 'the job name; ';
  end if;
  if (select string_agg(check_key || ':' || sort_order, ',' order by sort_order) from cma.data_quality_reviews_checks())
     is distinct from 'review_channel_unmapped:210,market_without_review_channel:220'
     or (select count(*) from cma.schema_migration where version = '0008ze') <> 1 then
    v_bad := v_bad || 'the data-quality catalog or something twice; ';
  end if;
  insert into verify_0008ze values (7, 'A7 the two settings, the job reviews_poll, the data-quality catalog, nothing twice',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A8. the redefinitions carry what came before: 0008n's held kinds (tasks, email) with reviews; 0008zc's data quality
  --     (the unlinked rule) with the two checks; 0008p's catalogs in data_quality(); message_rules() with max_rating
  v_bad := '';
  if (select prosrc from pg_proc where oid = 'cma.connection_held_kinds_of(uuid,uuid)'::regprocedure) !~ 'cma\.crm_task x'
     or (select prosrc from pg_proc where oid = 'cma.connection_held_kinds_of(uuid,uuid)'::regprocedure) !~ 'cma\.email_thread x'
     or (select prosrc from pg_proc where oid = 'cma.connection_held_kinds_of(uuid,uuid)'::regprocedure) !~ 'cma\.review_channel x' then
    v_bad := v_bad || 'held kinds; ';
  end if;
  if (select prosrc from pg_proc where oid = 'cma.data_quality_of(uuid)'::regprocedure) !~ 'outbound_unanswered_untagged'
     or (select prosrc from pg_proc where oid = 'cma.data_quality_of(uuid)'::regprocedure) !~ 'form_answer_not_in_options'
     or (select prosrc from pg_proc where oid = 'cma.data_quality_of(uuid)'::regprocedure) !~ 'market_without_review_channel'
     or (select prosrc from pg_proc where oid = 'cma.data_quality()'::regprocedure) !~ 'data_quality_forms_checks\(\)'
     or (select prosrc from pg_proc where oid = 'cma.data_quality()'::regprocedure) !~ 'data_quality_reviews_checks\(\)' then
    v_bad := v_bad || 'data quality; ';
  end if;
  if (select pg_get_function_result('cma.message_rules()'::regprocedure)) not like '%last_alert_at timestamp with time zone, max_rating numeric)' then
    v_bad := v_bad || 'message_rules; ';
  end if;
  if (select prosrc from pg_proc where oid = 'cma.connection_catalogs(uuid)'::regprocedure) !~ '''meaning'', t\.meaning'
     or (select prosrc from pg_proc where oid = 'cma.connection_catalogs(uuid)'::regprocedure) !~ '''reviewChannels''' then
    v_bad := v_bad || 'connection_catalogs; ';
  end if;
  insert into verify_0008ze values (8, 'A8 the redefinitions carry 0008n''s kinds, 0008zc''s data quality, 0008p''s checks, the tag meaning',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);
end
$$;

-- B. Behaviour on two throwaway tenants (rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_rows     text[] := '{}';
  v_t1 uuid; v_t2 uuid;
  v_admin1 uuid; v_analyst1 uuid; v_reader1 uuid; v_super1 uuid; v_agent1 uuid; v_ing1 uuid;
  v_admin2 uuid; v_analyst2 uuid; v_ing2 uuid;
  v_crm uuid; v_shop uuid; v_rev uuid; v_rev2 uuid; v_auto uuid;
  v_role uuid; v_run uuid;
  v_o1 uuid; v_o2 uuid; v_o3 uuid;
  v_txt text; v_a text; v_b text; v_c text;
  v_n integer; v_m integer;
  v_at timestamptz;
  j jsonb; k jsonb;
  v_now  timestamptz := '2026-10-14 10:00:00+00';   -- Wednesday 14 October 2026, 12:00 in Amsterdam
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    -- tenants, people and roles (as the owner)
    v_t1 := cma.create_tenant('verify-0008ze-one', 'Verify 0008ze one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008ze-two', 'Verify 0008ze two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-analyst1@example.invalid', 'analyst1') returning id into v_analyst1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-reader1@example.invalid', 'reader1') returning id into v_reader1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-super1@example.invalid', 'super1') returning id into v_super1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent1@example.invalid', 'agent1') returning id into v_agent1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin2') returning id into v_admin2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-analyst2@example.invalid', 'analyst2') returning id into v_analyst2;
    insert into cma.app_role (tenant_id, key, name) values (v_t1, 'verify_reader', 'Verify reader') returning id into v_role;
    insert into cma.role_permission (tenant_id, role_id, permission_key) values (v_t1, v_role, 'reports.view');
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_analyst1, 'analytics'), (v_t1, v_reader1, 'verify_reader'), (v_t1, v_super1, 'supervisor'),
                 (v_t1, v_agent1, 'agent'), (v_t2, v_admin2, 'admin'), (v_t2, v_analyst2, 'analytics')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    select x.user_id into v_ing2 from cma.app_user_external_id x where x.tenant_id = v_t2 and x.system = 'ingest';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifycrm', 'Verify reviews CRM', 'portal-1', 'crm') returning id into v_crm;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifyshop', 'Verify reviews shop', 'shop-1', 'commerce') returning id into v_shop;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, settings)
    values (v_t1, 'verifyreviews', 'Verify reviews', 'acc-1',
            '{"record_url_review": "https://reviews.example.invalid/{account}/reviews/{id}"}') returning id into v_rev;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifyauto', 'Verify automation', 'auto-1', 'automation') returning id into v_auto;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t2, 'verifyreviews', 'Verify reviews two', 'acc-2', 'reviews') returning id into v_rev2;
    -- the store's customers and orders (as the owner: 0007b's own upserts are not under test here); customer cu-1
    -- linked to the CRM contact c-1 (0008h), cu-2 without a link
    insert into cma.commerce_customer (tenant_id, connection_id, source_system, source_id, crm_connection_id, crm_contact_source_id, matched_at)
    values (v_t1, v_shop, 'verifyshop', 'cu-1', v_crm, 'c-1', v_now - interval '30 days'),
           (v_t1, v_shop, 'verifyshop', 'cu-2', null, null, null);
    insert into cma.commerce_order (tenant_id, connection_id, source_system, source_id, order_name, customer_source_id, source_created_at)
    values (v_t1, v_shop, 'verifyshop', 'so-1001', 'TESTNL-1001', 'cu-1', v_now - interval '20 days') returning id into v_o1;
    insert into cma.commerce_order (tenant_id, connection_id, source_system, source_id, order_name, customer_source_id, source_created_at)
    values (v_t1, v_shop, 'verifyshop', 'so-2002', 'TESTNL-2002', 'cu-2', v_now - interval '15 days') returning id into v_o2;
    perform set_config('role', 'cma_app', true);

    -- tenant one's configuration (the admin): markets
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP');
    perform cma.upsert_market('FR', 'France', 'Europe/Paris', 'fr', 'EUR');
    perform cma.upsert_market('DE', 'Germany', 'Europe/Berlin', 'de', 'EUR');

    -- B1. the channel catalog (the Ingest user): new channels without a market and not counted; a known one renamed; one
    --     gone from the list gets source_deleted_at; an empty list changes nothing; the admin's market and counted flag
    --     survive a refresh; the setter's refusals
    perform set_config('app.user_id', v_ing1::text, true);
    v_n := cma.ingest_upsert_review_channels(v_rev, '[{"channelId": "chl-nl", "name": "Shop NL", "locale": "nl_NL"},
      {"channelId": "chl-gb", "name": "Shop GB", "locale": "en_GB"}, {"channelId": "chl-x", "name": "Shop X", "locale": "not a locale"},
      {"channelId": "chl-old", "name": "Old shop", "locale": "de_DE"}]');
    v_txt := v_n || ' ' || (select string_agg(ch.source_id || ':' || coalesce(ch.market, '-') || ':' || ch.is_counted || ':' || coalesce(ch.locale, '-'), ' ' order by ch.source_id)
                            from cma.review_channel ch where ch.tenant_id = v_t1);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_review_channel(v_rev, 'chl-nl', 'NL', true);
    perform cma.set_review_channel(v_rev, 'chl-gb', 'GB', true);
    perform set_config('app.user_id', v_ing1::text, true);
    v_m := cma.ingest_upsert_review_channels(v_rev, '[{"channelId": "chl-nl", "name": "Shop NL renamed", "locale": "nl_NL"},
      {"channelId": "chl-gb", "name": "Shop GB", "locale": "en_GB"}, {"channelId": "chl-x", "name": "Shop X", "locale": null},
      {"channelId": "chl-fr", "name": "Shop FR", "locale": "fr_FR"}]');
    v_txt := v_txt || ' | ' || v_m || ' ' || cma.ingest_upsert_review_channels(v_rev, '[]') || ' '
             || (select string_agg(ch.source_id || ':' || coalesce(ch.market, '-') || ':' || ch.is_counted || ':' || (ch.source_deleted_at is not null) || ':' || ch.name,
                                   ' ' order by ch.source_id) from cma.review_channel ch where ch.tenant_id = v_t1);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_review_channel(v_rev, 'chl-fr', 'FR', true);
    v_txt := v_txt || ' | ' || pg_temp.v0008ze_code(format('select cma.set_review_channel(%L, %L, null, true)', v_rev, 'chl-none'))
             || ' ' || pg_temp.v0008ze_code(format('select cma.set_review_channel(%L, %L, %L, true)', v_rev, 'chl-x', 'XX'))
             || ' ' || pg_temp.v0008ze_code(format('select cma.set_review_channel(%L, %L, null, null)', v_rev, 'chl-x'));
    perform set_config('app.user_id', v_agent1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008ze_code(format('select cma.set_review_channel(%L, %L, null, false)', v_rev, 'chl-x'));
    v_rows := v_rows || array['11', 'B1 the channel catalog: new unmapped and not counted, renamed, gone, an empty list, the configuration kept, the refusals',
      case when v_txt = '4 chl-gb:-:false:en_GB chl-nl:-:false:nl_NL chl-old:-:false:de_DE chl-x:-:false:- | 3 0 chl-fr:-:false:false:Shop FR '
                        || 'chl-gb:GB:true:false:Shop GB chl-nl:NL:true:false:Shop NL renamed chl-old:-:false:true:Old shop chl-x:-:false:false:Shop X'
                        || ' | CMA02 CMA02 CMA04 CMA06'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B2. the kind: the reviews connection's rows make it reviews; another kind is refused (CMA03), reviews accepted; a CRM
    --     or automation connection takes no channel or review (CMA04)
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := array_to_string(cma.connection_held_kinds_of(v_t1, v_rev), ',')
             || ' ' || pg_temp.v0008ze_code(format('select cma.set_connection_kind(%L, %L)', v_rev, 'crm'))
             || ' ' || pg_temp.v0008ze_code(format('select cma.set_connection_kind(%L, %L)', v_rev, 'reviews'));
    v_txt := v_txt || ' ' || coalesce((select c.kind from cma.integration_connection c where c.id = v_rev), '-');
    perform set_config('app.user_id', v_ing1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008ze_code(format('select cma.ingest_upsert_review_channels(%L, %L)', v_crm, '[{"channelId": "chl-a", "name": "A"}]'))
             || ' ' || pg_temp.v0008ze_code(format('select * from cma.ingest_upsert_reviews(%L, %L)', v_auto, '[]'));
    v_rows := v_rows || array['12', 'B2 the kind reviews from the rows, set and kept; a CRM or automation connection takes none (CMA04)',
      case when v_txt = 'reviews CMA03 ok reviews CMA04 CMA04' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B3. reviews (the Ingest user): by order name with the order's customer's contact (order, c-1); by source id with a
    --     customer without a contact (order, none); a reference that names no order (none); no reference (none); an
    --     uncounted channel; an unpublished review; a channel the catalog lacks (unknown_channel, not stored)
    perform set_config('app.user_id', v_ing1::text, true);
    select string_agg(x.source_id || ':' || x.outcome || ':' || coalesce(x.link_level, '-') || ':' || coalesce(x.has_contact::text, '-'), ' ' order by x.source_id)
    into v_txt
    from cma.ingest_upsert_reviews(v_rev, jsonb_build_array(
      jsonb_build_object('reviewId', 'rev-1', 'channelId', 'chl-nl', 'type', 'SERVICE_REVIEW', 'state', 'APPROVED', 'isPublished', true,
                         'rating', 5, 'submittedAt', '2026-10-02T09:00:00Z', 'updatedAt', '2026-10-02T09:05:00Z', 'hasReply', true,
                         'inviteEventType', 'checkout', 'transactionRef', 'TESTNL-1001',
                         'raw', jsonb_build_object('id', 'rev-1', 'channelRef', 'chl-nl', 'event', jsonb_build_object('type', 'checkout'),
                                                   'transaction', jsonb_build_object('reference', 'TESTNL-1001'))),
      jsonb_build_object('reviewId', 'rev-2', 'channelId', 'chl-nl', 'type', 'SERVICE_REVIEW', 'state', 'APPROVED', 'isPublished', true,
                         'rating', 2, 'submittedAt', '2026-10-05T10:00:00Z', 'updatedAt', '2026-10-05T10:00:00Z',
                         'inviteEventType', 'checkout', 'transactionRef', 'so-2002'),
      jsonb_build_object('reviewId', 'rev-3', 'channelId', 'chl-gb', 'type', 'SERVICE_REVIEW', 'state', 'APPROVED', 'isPublished', true,
                         'rating', 4.5, 'submittedAt', '2026-10-14T09:00:00Z', 'updatedAt', '2026-10-14T09:00:00Z',
                         'inviteEventType', 'klaviyo-integration', 'transactionRef', '9900000000017'),
      jsonb_build_object('reviewId', 'rev-4', 'channelId', 'chl-gb', 'type', 'SERVICE_REVIEW', 'state', 'APPROVED', 'isPublished', true,
                         'rating', 1, 'submittedAt', '2026-10-13T22:30:00Z', 'updatedAt', '2026-10-13T22:30:00Z'),
      jsonb_build_object('reviewId', 'rev-5', 'channelId', 'chl-x', 'type', 'SERVICE_REVIEW', 'state', 'APPROVED', 'isPublished', true,
                         'rating', 3, 'submittedAt', '2026-10-03T10:00:00Z', 'updatedAt', '2026-10-03T10:00:00Z'),
      jsonb_build_object('reviewId', 'rev-6', 'channelId', 'chl-nl', 'type', 'SERVICE_REVIEW', 'state', 'REJECTED', 'isPublished', false,
                         'rating', 1, 'submittedAt', '2026-10-04T10:00:00Z', 'updatedAt', '2026-10-04T10:00:00Z'),
      jsonb_build_object('reviewId', 'rev-7', 'channelId', 'chl-unknown', 'type', 'SERVICE_REVIEW', 'state', 'APPROVED', 'isPublished', true,
                         'rating', 5, 'submittedAt', '2026-10-04T10:00:00Z'),
      jsonb_build_object('reviewId', 'pre-1', 'channelId', 'chl-nl', 'type', 'SERVICE_REVIEW', 'state', 'APPROVED', 'isPublished', true,
                         'rating', 4, 'submittedAt', '2026-09-20T10:00:00Z', 'inviteEventType', 'checkout'),
      jsonb_build_object('reviewId', 'pre-2', 'channelId', 'chl-gb', 'type', 'SERVICE_REVIEW', 'state', 'APPROVED', 'isPublished', true,
                         'rating', 2, 'submittedAt', '2026-09-30T09:00:00Z'),
      jsonb_build_object('reviewId', 'pre-3', 'channelId', 'chl-nl', 'type', 'SERVICE_REVIEW', 'state', 'APPROVED', 'isPublished', true,
                         'rating', 5, 'submittedAt', '2026-09-30T11:00:00Z'),
      jsonb_build_object('reviewId', 'old-1', 'channelId', 'chl-nl', 'type', 'SERVICE_REVIEW', 'state', 'APPROVED', 'isPublished', true,
                         'rating', 3, 'submittedAt', '2026-08-01T10:00:00Z'))) x;
    v_txt := v_txt || ' | ' || (select string_agg(r.source_id || ':' || coalesce(r.crm_contact_source_id, '-') || ':' || coalesce((r.commerce_order_id = v_o1)::text, '-')
                                                  || ':' || (r.matched_at is not null) || ':' || r.has_reply || ':' || r.source_system, ' ' order by r.source_id)
                                from cma.review r where r.tenant_id = v_t1 and r.source_id in ('rev-1', 'rev-2', 'rev-3'));
    v_rows := v_rows || array['13', 'B3 reviews and their links: by order name with the order''s contact, by source id, none; unknown channel not stored',
      case when v_txt = 'old-1:inserted:none:false pre-1:inserted:none:false pre-2:inserted:none:false pre-3:inserted:none:false '
                        || 'rev-1:inserted:order:true rev-2:inserted:order:false rev-3:inserted:none:false rev-4:inserted:none:false '
                        || 'rev-5:inserted:none:false rev-6:inserted:none:false rev-7:unknown_channel:-:- | '
                        || 'rev-1:c-1:true:true:true:verifyreviews rev-2:-:false:true:false:verifyreviews rev-3:-:-:false:false:verifyreviews'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B4. the stale guard and a change: an older update time is stale (nothing changes); the same review again is unchanged
    --     (no update, no audit row); a newer one with another state and unpublished is updated, its link kept
    v_n := (select count(*) from cma.audit_log a where a.tenant_id = v_t1 and a.table_name = 'review');
    select string_agg(x.outcome, ',') into v_txt from cma.ingest_upsert_reviews(v_rev, jsonb_build_array(
      jsonb_build_object('reviewId', 'rev-1', 'channelId', 'chl-nl', 'type', 'SERVICE_REVIEW', 'state', 'REJECTED', 'isPublished', false,
                         'rating', 1, 'submittedAt', '2026-10-02T09:00:00Z', 'updatedAt', '2026-10-02T09:01:00Z'))) x;
    select v_txt || ',' || string_agg(x.outcome, ',') into v_txt from cma.ingest_upsert_reviews(v_rev, jsonb_build_array(
      jsonb_build_object('reviewId', 'rev-1', 'channelId', 'chl-nl', 'type', 'SERVICE_REVIEW', 'state', 'APPROVED', 'isPublished', true,
                         'rating', 5, 'submittedAt', '2026-10-02T09:00:00Z', 'updatedAt', '2026-10-02T09:05:00Z', 'hasReply', true,
                         'inviteEventType', 'checkout', 'transactionRef', 'TESTNL-1001',
                         'raw', jsonb_build_object('id', 'rev-1', 'channelRef', 'chl-nl', 'event', jsonb_build_object('type', 'checkout'),
                                                   'transaction', jsonb_build_object('reference', 'TESTNL-1001'))))) x;
    v_txt := v_txt || ' ' || ((select count(*) from cma.audit_log a where a.tenant_id = v_t1 and a.table_name = 'review') - v_n);
    select v_txt || ' ' || string_agg(x.outcome || ':' || x.link_level, ',') into v_txt from cma.ingest_upsert_reviews(v_rev, jsonb_build_array(
      jsonb_build_object('reviewId', 'rev-6', 'channelId', 'chl-nl', 'type', 'SERVICE_REVIEW', 'state', 'VETOED', 'isPublished', false,
                         'rating', 1, 'submittedAt', '2026-10-04T10:00:00Z', 'updatedAt', '2026-10-06T10:00:00Z', 'hasReply', true))) x;
    v_txt := v_txt || ' ' || (select r.state || ':' || r.is_published || ':' || r.has_reply from cma.review r where r.tenant_id = v_t1 and r.source_id = 'rev-6');
    v_rows := v_rows || array['14', 'B4 the stale guard, an unchanged review written nowhere, a state change (vetoed, unpublished, a reply)',
      case when v_txt = 'stale,unchanged 0 updated:none VETOED:false:true' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B5. the refusals (CMA04): a raw with a text, a customer, an email in the event; a rating of 6; no submitted time; an
    --     unpublished flag that is no boolean; more than 500 items. Nothing is stored
    v_txt := pg_temp.v0008ze_code(format('select * from cma.ingest_upsert_reviews(%L, %L)', v_rev,
               '[{"reviewId": "bad-1", "channelId": "chl-nl", "type": "S", "state": "A", "isPublished": true, "rating": 3, "submittedAt": "2026-10-01T00:00:00Z", "raw": {"comment": "a text"}}]'))
             || ' ' || pg_temp.v0008ze_code(format('select * from cma.ingest_upsert_reviews(%L, %L)', v_rev,
               '[{"reviewId": "bad-2", "channelId": "chl-nl", "type": "S", "state": "A", "isPublished": true, "rating": 3, "submittedAt": "2026-10-01T00:00:00Z", "raw": {"customer": {"email": "x@example.invalid"}}}]'))
             || ' ' || pg_temp.v0008ze_code(format('select * from cma.ingest_upsert_reviews(%L, %L)', v_rev,
               '[{"reviewId": "bad-3", "channelId": "chl-nl", "type": "S", "state": "A", "isPublished": true, "rating": 3, "submittedAt": "2026-10-01T00:00:00Z", "raw": {"event": {"type": "checkout", "email": "x"}}}]'))
             || ' ' || pg_temp.v0008ze_code(format('select * from cma.ingest_upsert_reviews(%L, %L)', v_rev,
               '[{"reviewId": "bad-4", "channelId": "chl-nl", "type": "S", "state": "A", "isPublished": true, "rating": 6, "submittedAt": "2026-10-01T00:00:00Z"}]'))
             || ' ' || pg_temp.v0008ze_code(format('select * from cma.ingest_upsert_reviews(%L, %L)', v_rev,
               '[{"reviewId": "bad-5", "channelId": "chl-nl", "type": "S", "state": "A", "isPublished": true, "rating": 3}]'))
             || ' ' || pg_temp.v0008ze_code(format('select * from cma.ingest_upsert_reviews(%L, %L)', v_rev,
               '[{"reviewId": "bad-6", "channelId": "chl-nl", "type": "S", "state": "A", "isPublished": "yes", "rating": 3, "submittedAt": "2026-10-01T00:00:00Z"}]'))
             || ' ' || pg_temp.v0008ze_code(format('select * from cma.ingest_upsert_reviews(%L, %L)', v_rev,
               (select jsonb_agg(jsonb_build_object('reviewId', 'many-' || g)) from generate_series(1, 501) g)))
             || ' ' || (select count(*) from cma.review r where r.tenant_id = v_t1 and (r.source_id like 'bad-%' or r.source_id like 'many-%'));
    v_rows := v_rows || array['15', 'B5 a raw with a text, a customer or an email, a rating of 6, no time, a flag that is no boolean, 501 items: CMA04, nothing stored',
      case when v_txt = 'CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04 0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B6. the email contact (cma.set_review_contact): linked, unchanged (matched_at kept), relinked, an order's review stays
    --     the order's, an unknown review, a connection that is no CRM connection (CMA04); a re-read keeps the contact; cleared
    v_txt := cma.set_review_contact(v_rev, 'rev-4', v_crm, 'c-9');
    v_at := (select r.matched_at from cma.review r where r.tenant_id = v_t1 and r.source_id = 'rev-4');
    v_txt := v_txt || ' ' || cma.set_review_contact(v_rev, 'rev-4', v_crm, 'c-9');
    v_txt := v_txt || ' ' || ((select r.matched_at from cma.review r where r.tenant_id = v_t1 and r.source_id = 'rev-4') = v_at)
             || ' ' || cma.set_review_contact(v_rev, 'rev-4', v_crm, 'c-8')
             || ' ' || cma.set_review_contact(v_rev, 'rev-1', v_crm, 'c-7')
             || ' ' || cma.set_review_contact(v_rev, 'rev-none', v_crm, 'c-7')
             || ' ' || pg_temp.v0008ze_code(format('select cma.set_review_contact(%L, %L, %L, %L)', v_rev, 'rev-3', v_shop, 'c-7'));
    select v_txt || ' ' || string_agg(x.outcome || ':' || x.link_level || ':' || x.has_contact, ',') into v_txt
    from cma.ingest_upsert_reviews(v_rev, jsonb_build_array(
      jsonb_build_object('reviewId', 'rev-4', 'channelId', 'chl-gb', 'type', 'SERVICE_REVIEW', 'state', 'APPROVED', 'isPublished', true,
                         'rating', 1, 'submittedAt', '2026-10-13T22:30:00Z', 'updatedAt', '2026-10-13T22:30:00Z'))) x;
    v_txt := v_txt || ' ' || cma.set_review_contact(v_rev, 'rev-4', null, null) || ' ' || cma.set_review_contact(v_rev, 'rev-4', null, null)
             || ' ' || cma.set_review_contact(v_rev, 'rev-3', v_crm, 'c-3');
    v_txt := v_txt || ' ' || (select r.link_level || ':' || coalesce(r.crm_contact_source_id, '-') || ':' || (r.matched_at is not null)
                              from cma.review r where r.tenant_id = v_t1 and r.source_id = 'rev-4');
    v_rows := v_rows || array['16', 'B6 the email contact: linked, unchanged and kept, relinked, an order''s review, unknown, not a CRM (CMA04), kept by an unchanged re-read, cleared',
      case when v_txt = 'linked unchanged true relinked order unknown CMA04 unchanged:contact:true cleared unlinked linked none:-:false'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B7. an order that arrives after its review: the review read again links to it (order), its email contact kept as the
    --     contact while the order's customer has none; an ambiguous order name (two stores) links nothing
    perform set_config('role', 'cma_owner', true);
    insert into cma.commerce_order (tenant_id, connection_id, source_system, source_id, order_name, customer_source_id, source_created_at)
    values (v_t1, v_shop, 'verifyshop', '9900000000017', 'TESTUK-3003', 'cu-2', v_now - interval '12 days') returning id into v_o3;
    perform set_config('role', 'cma_app', true);
    select string_agg(x.outcome || ':' || x.link_level || ':' || x.has_contact, ',') into v_txt
    from cma.ingest_upsert_reviews(v_rev, jsonb_build_array(
      jsonb_build_object('reviewId', 'rev-3', 'channelId', 'chl-gb', 'type', 'SERVICE_REVIEW', 'state', 'APPROVED', 'isPublished', true,
                         'rating', 4.5, 'submittedAt', '2026-10-14T09:00:00Z', 'updatedAt', '2026-10-14T09:00:00Z',
                         'inviteEventType', 'klaviyo-integration', 'transactionRef', '9900000000017'))) x;
    v_txt := v_txt || ' ' || (select (r.commerce_order_id = v_o3) || ':' || r.crm_contact_source_id from cma.review r where r.tenant_id = v_t1 and r.source_id = 'rev-3');
    perform set_config('role', 'cma_owner', true);
    insert into cma.commerce_order (tenant_id, connection_id, source_system, source_id, order_name, source_created_at)
    values (v_t1, v_shop, 'verifyshop', 'so-dup-a', 'TESTDUP-1', v_now), (v_t1, v_crm, 'verifyshop', 'so-dup-b', 'TESTDUP-1', v_now);
    perform set_config('role', 'cma_app', true);
    v_txt := v_txt || ' ' || coalesce(cma.review_order_of(v_t1, 'TESTDUP-1')::text, 'none') || ' ' || (cma.review_order_of(v_t1, ' TESTNL-1001 ') = v_o1)
             || ' ' || coalesce(cma.review_order_of(v_t1, '')::text, 'none');
    -- the third review back without an order, for the report and the alerts below (its order deleted at the source)
    perform set_config('role', 'cma_owner', true);
    update cma.commerce_order set source_deleted_at = v_now where id = v_o3;
    perform set_config('role', 'cma_app', true);
    select v_txt || ' ' || string_agg(x.outcome || ':' || x.link_level || ':' || x.has_contact, ',') into v_txt
    from cma.ingest_upsert_reviews(v_rev, jsonb_build_array(
      jsonb_build_object('reviewId', 'rev-3', 'channelId', 'chl-gb', 'type', 'SERVICE_REVIEW', 'state', 'APPROVED', 'isPublished', true,
                         'rating', 4.5, 'submittedAt', '2026-10-14T09:00:00Z', 'updatedAt', '2026-10-14T09:00:00Z',
                         'inviteEventType', 'klaviyo-integration', 'transactionRef', '9900000000017'))) x;
    perform cma.set_review_contact(v_rev, 'rev-3', v_crm, 'c-3');
    v_rows := v_rows || array['17', 'B7 an order arriving later links the review, the email contact kept; an ambiguous name links nothing; a deleted order unlinks',
      case when v_txt = 'updated:order:true true:c-3 none true none updated:none:false' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B8. the CRM's privacy deletion of a contact: a review linked by email loses its link (none), one linked to an order
    --     keeps the order and loses the contact; another tenant's review is untouched
    v_txt := cma.forget_review_contact_links(v_crm, 'c-3') || ' ' || cma.forget_review_contact_links(v_crm, 'c-1');
    v_txt := v_txt || ' ' || (select string_agg(r.source_id || ':' || r.link_level || ':' || coalesce(r.crm_contact_source_id, '-') || ':' || (r.matched_at is not null),
                                          ' ' order by r.source_id)
                        from cma.review r where r.tenant_id = v_t1 and r.source_id in ('rev-1', 'rev-3'))
             || ' ' || cma.forget_review_contact_links(v_crm, 'c-404');
    -- the email contact back on the third review, for the report
    perform cma.set_review_contact(v_rev, 'rev-3', v_crm, 'c-3');
    v_rows := v_rows || array['18', 'B8 the privacy deletion: the email link gone, the order kept without the contact',
      case when v_txt = '1 1 rev-1:order:-:true rev-3:none:-:false 0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B9. the settings: the negative threshold takes 1 to 4 (0, 5 and a word refused, CMA04); the history start takes a
    --     date or nothing (a wrong date refused); the defaults 2 and empty
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := cma.setting_of(v_t1, 'reviews.negative_max_rating') || ' ' || coalesce(nullif(cma.setting_of(v_t1, 'reviews.history_start_date'), ''), 'empty')
             || ' ' || pg_temp.v0008ze_code('select cma.set_tenant_setting(''reviews.negative_max_rating'', ''0'')')
             || ' ' || pg_temp.v0008ze_code('select cma.set_tenant_setting(''reviews.negative_max_rating'', ''5'')')
             || ' ' || pg_temp.v0008ze_code('select cma.set_tenant_setting(''reviews.negative_max_rating'', ''two'')')
             || ' ' || pg_temp.v0008ze_code('select cma.set_tenant_setting(''reviews.negative_max_rating'', ''3'')')
             || ' ' || pg_temp.v0008ze_code('select cma.set_tenant_setting(''reviews.history_start_date'', ''2026-13-01'')')
             || ' ' || pg_temp.v0008ze_code('select cma.set_tenant_setting(''reviews.history_start_date'', '' 2024-01-01 '')');
    v_txt := v_txt || ' ' || cma.setting_of(v_t1, 'reviews.history_start_date')
             || ' ' || pg_temp.v0008ze_code('select cma.set_tenant_setting(''reviews.history_start_date'', '''')');
    perform cma.set_tenant_setting('reviews.negative_max_rating', '2');
    v_rows := v_rows || array['19', 'B9 the settings: the threshold 1 to 4, the history start a date or nothing',
      case when v_txt = '2 empty CMA04 CMA04 CMA04 ok CMA04 ok 2024-01-01 ok' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B10. review rules: created with a highest rating; any rating with none; message_rules() lists it; a name of another
    --      trigger's rule (CMA03), a rating of 6 (CMA04), an agent (CMA06); a created-record rule keeps no rating; an
    --      assignment rule cannot take a review rule's name, with a rating or without, nor a created-record rule's: the
    --      trigger is fixed (CMA03); every rule keeps its trigger
    perform cma.upsert_message_rule('Verify new deal', 'deal', '{}', 'leads.accept', false, false, null, 'normal', null);
    perform cma.upsert_review_rule('Negative review', 'performance.team', false, false, null, 'normal', 2, 1440);
    perform cma.upsert_review_rule('Every review', 'performance.team', false, false, null, 'normal', null, 1440);
    perform cma.upsert_review_rule('Negative review', 'performance.team', false, false, null, 'urgent', 2, 1440);
    select string_agg(r.name || ':' || r.trigger || ':' || r.record_type || ':' || coalesce(r.max_rating::text, '-') || ':' || r.urgency, ' ' order by r.name)
    into v_txt from cma.message_rules() r;
    v_txt := v_txt || ' ' || pg_temp.v0008ze_code('select cma.upsert_review_rule(''Verify new deal'', ''performance.team'', false, false, null, ''normal'', 2)')
             || ' ' || pg_temp.v0008ze_code('select cma.upsert_review_rule(''Bad'', ''performance.team'', false, false, null, ''normal'', 6)')
             || ' ' || pg_temp.v0008ze_code('select cma.upsert_assignment_rule(''Negative review'', ''deal'', ''{}'', ''normal'')')
             || ' ' || pg_temp.v0008ze_code('select cma.upsert_assignment_rule(''Every review'', ''deal'', ''{}'', ''normal'')')
             || ' ' || pg_temp.v0008ze_code('select cma.upsert_assignment_rule(''Verify new deal'', ''deal'', ''{}'', ''normal'')');
    perform set_config('app.user_id', v_agent1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008ze_code('select cma.upsert_review_rule(''Agent'', ''performance.team'', false, false, null, ''normal'', 2)');
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := v_txt || ' ' || (select string_agg(r.name || ':' || r.trigger, ' ' order by r.name) from cma.message_rules() r);
    v_rows := v_rows || array['20', 'B10 review rules with and without a highest rating, listed; another trigger''s name, a rating of 6, an agent refused; the trigger fixed',
      case when v_txt = 'Every review:review_submitted:review:-:normal Negative review:review_submitted:review:2.00:urgent Verify new deal:record_created:deal:-:normal '
                        || 'CMA03 CMA04 CMA03 CMA03 CMA03 CMA06 '
                        || 'Every review:review_submitted Negative review:review_submitted Verify new deal:record_created'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B11. the report for 1 to 14 October 2026 as of the 14th 12:00 (the analyst): the figures, the previous period like
    --      for like (17 to 30 September, the 30th cut at 12:00: pre-3 left out), the distribution by whole star (4.5 is a
    --      5), the link levels; per market and channel; the uncounted channel, the unpublished review and the old review
    --      only in the history start
    perform set_config('app.user_id', v_analyst1::text, true);
    j := cma.reviews_page_of(v_t1, '2026-10-01', '2026-10-14', null, 'day', v_now);
    v_txt := pg_temp.v0008ze_fig(j -> 'figures') || ' prev ' || pg_temp.v0008ze_fig(j -> 'previous')
             || ' ' || (j ->> 'previous_from') || '..' || (j ->> 'previous_to') || ':' || (j ->> 'previous_partial')
             || ' stars ' || (select string_agg((d ->> 'reviews') || '/' || (d ->> 'previous'), ',' order by (d ->> 'stars')::int) from jsonb_array_elements(j -> 'distribution') d)
             || ' links ' || (select string_agg((d ->> 'level') || ':' || (d ->> 'reviews') || '/' || (d ->> 'previous'), ',') from jsonb_array_elements(j -> 'link_levels') d)
             || ' start ' || (j ->> 'history_start') || ' neg ' || (j ->> 'negative_max_rating') || ' ' || (j ->> 'is_set_up');
    v_rows := v_rows || array['21', 'B11 the report''s figures, the previous period like for like, the distribution, the link levels, the history start',
      case when v_txt = '4/3.13/2/2/1/1 prev 2/3.00/1/0/0/2 2026-09-17..2026-09-30:true stars 1/0,1/1,0/0,0/1,2/0 '
                        || 'links order:2/0,contact:1/0,none:1/2 start 2026-08-01 neg 2 true'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B12. the groups (every day of the period; by week the ISO weeks from 28 September; the review of 22:30 UTC on the
    --      13th is the 14th in Amsterdam), markets (GB, NL with their previous figures), channels, invite events, the
    --      markets' states (DE no channel, FR a channel without reviews, GB and NL with reviews), the filter's markets, and
    --      the market filter
    v_txt := (select count(*) from jsonb_array_elements(j -> 'groups'))
             || ' ' || (select string_agg((g ->> 'key') || '=' || (g ->> 'reviews'), ',' order by g ->> 'key') from jsonb_array_elements(j -> 'groups') g where (g ->> 'reviews')::int > 0)
             || ' week ' || (select string_agg((g ->> 'key') || '=' || (g ->> 'reviews'), ',' order by g ->> 'key')
                             from jsonb_array_elements(cma.reviews_page_of(v_t1, '2026-10-01', '2026-10-14', null, 'week', v_now) -> 'groups') g)
             || ' markets ' || (select string_agg((m ->> 'market') || ':' || pg_temp.v0008ze_fig(m -> 'current') || '<' || pg_temp.v0008ze_fig(m -> 'previous'), ' ')
                                from jsonb_array_elements(j -> 'markets') m)
             || ' channels ' || (select string_agg((c ->> 'channel') || ':' || (c ->> 'name') || ':' || (c ->> 'market') || ':' || ((c -> 'current') ->> 'reviews'), ' ')
                                 from jsonb_array_elements(j -> 'channels') c)
             || ' events ' || (select string_agg(coalesce(e ->> 'event_type', 'none') || ':' || (e ->> 'reviews') || '/' || (e ->> 'previous'), ',') from jsonb_array_elements(j -> 'invite_events') e)
             || ' states ' || (select string_agg((s ->> 'market') || ':' || (s ->> 'state') || ':' || (s ->> 'channels'), ' ') from jsonb_array_elements(j -> 'market_states') s)
             || ' filter ' || (select string_agg(f #>> '{}', ',') from jsonb_array_elements(j -> 'filter_markets') f)
             || ' NL ' || pg_temp.v0008ze_fig(cma.reviews_page_of(v_t1, '2026-10-01', '2026-10-14', 'NL', 'day', v_now) -> 'figures')
             || ' unknown ' || pg_temp.v0008ze_fig(cma.reviews_page_of(v_t1, '2026-10-01', '2026-10-14', 'unknown', 'day', v_now) -> 'figures');
    v_rows := v_rows || array['22', 'B12 the groups by day and week, markets, channels, invite events, the markets'' states, the filter',
      case when v_txt = '14 2026-10-02=1,2026-10-05=1,2026-10-14=2 week 2026-09-28=1,2026-10-05=1,2026-10-12=2 '
                        || 'markets GB:2/2.75/1/0/1/1<1/2.00/1/0/0/1 NL:2/3.50/1/2/0/0<1/4.00/0/0/0/1 '
                        || 'channels chl-gb:Shop GB:GB:2 chl-nl:Shop NL renamed:NL:2 '
                        || 'events checkout:2/1,klaviyo-integration:1/0,none:1/1 '
                        || 'states DE:no_channel:0 FR:channel_no_reviews:1 GB:has_reviews:1 NL:has_reviews:1 filter FR,GB,NL '
                        || 'NL 2/3.50/1/2/0/0 unknown 0/-/0/0/0/0'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B13. the page's parameters and permissions: 93 days, a market of three letters, a group of month (CMA04); an agent
    --      (CMA06); the reader with reports.view, the supervisor with performance.team and the analyst read it
    v_txt := pg_temp.v0008ze_code('select cma.reviews_page(''2026-07-01'', ''2026-10-01'')')
             || ' ' || pg_temp.v0008ze_code('select cma.reviews_page(''2026-10-01'', ''2026-10-14'', ''NLD'')')
             || ' ' || pg_temp.v0008ze_code('select cma.reviews_page(''2026-10-01'', ''2026-10-14'', null, ''month'')')
             || ' ' || pg_temp.v0008ze_code('select cma.reviews_page(''2026-10-01'', ''2026-10-14'', ''unknown'', ''day'')');
    perform set_config('app.user_id', v_agent1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008ze_code('select cma.reviews_page(''2026-10-01'', ''2026-10-14'')');
    perform set_config('app.user_id', v_reader1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008ze_code('select cma.reviews_page(''2026-10-01'', ''2026-10-14'')');
    perform set_config('app.user_id', v_super1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008ze_code('select cma.reviews_page(''2026-10-01'', ''2026-10-14'')');
    v_rows := v_rows || array['23', 'B13 the page''s range, market and group (CMA04), an agent (CMA06), reports.view and performance.team read it',
      case when v_txt = 'CMA04 CMA04 CMA04 ok CMA06 ok ok' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B14. data quality: the unmapped channel with the reviews held of it (the gone one left out), DE without a counted
    --      channel; data_quality() lists both checks after 0008p's; tenant two, with a reviews connection and nothing
    --      else, lists both checks with no row for a market (it has none); the readers' dq_ views
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := (select string_agg(q.check_key || ':' || q.object_id || ':' || coalesce(q.value, '-'), ' ' order by q.check_key, q.object_id)
              from cma.data_quality_of(v_t1) q where q.check_key in ('review_channel_unmapped', 'market_without_review_channel'))
             || ' ' || (select string_agg(d.check_key || '=' || d.total, ',') from cma.data_quality() d
                        where d.check_key in ('form_answer_not_in_options', 'review_channel_unmapped', 'market_without_review_channel'));
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    v_txt := v_txt || ' two ' || (select string_agg(d.check_key || '=' || d.total, ',') from cma.data_quality() d
                                  where d.check_key in ('review_channel_unmapped', 'market_without_review_channel'));
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    v_rows := v_rows || array['24', 'B14 data quality: the unmapped channel with its reviews, the market without a channel; listed where reviews connect',
      case when v_txt = 'market_without_review_channel:DE:- review_channel_unmapped:chl-x:1 review_channel_unmapped=1,market_without_review_channel=1 '
                        || 'two review_channel_unmapped=0,market_without_review_channel=0'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B15. the reader views (as a reader, tenant one): the counted reviews per day (the 14th: two, 2.75, its previous day
    --      none), per week with the whole previous week (not like for like: 28 September's week holds three), per market and channel, the markets' states, the review without raw,
    --      the dq_ views; tenant two sees none of it
    perform set_config('role', 'cma_readonly', true);
    v_txt := (select d.reviews || '/' || d.average_rating || '/' || d.stars_1 || d.stars_2 || d.stars_3 || d.stars_4 || d.stars_5 || '/' || d.negative || '/'
                     || d.linked_order || d.linked_contact || d.unlinked || '/' || coalesce(d.previous_reviews::text, '-')
              from cma_read.reviews_per_day d where d.tenant_id = v_t1 and d.business_date = '2026-10-14')
             || ' ' || (select w.reviews || '/' || w.previous_reviews || '/' || w.previous_average_rating from cma_read.reviews_per_week w
                        where w.tenant_id = v_t1 and w.week_start = '2026-10-05')
             || ' ' || (select string_agg(m.market || '=' || m.reviews, ',' order by m.market) from cma_read.reviews_per_market m
                        where m.tenant_id = v_t1 and m.week_start = '2026-10-12')
             || ' ' || (select string_agg(c.channel_name || '=' || c.reviews, ',' order by c.channel_name) from cma_read.reviews_per_channel c
                        where c.tenant_id = v_t1 and c.week_start = '2026-09-28')
             || ' ' || (select string_agg(s.market || ':' || s.state, ',' order by s.market) from cma_read.review_market_state s where s.tenant_id = v_t1)
             || ' ' || (select count(*) from cma_read.review r where r.tenant_id = v_t1)
             || ' ' || (select count(*) from cma_read.dq_review_channel_unmapped q where q.tenant_id = v_t1)
             || '/' || (select count(*) from cma_read.dq_market_without_review_channel q where q.tenant_id = v_t1);
    perform set_config('app.tenant_id', v_t2::text, true);
    v_txt := v_txt || ' two ' || (select count(*) from cma_read.review r where r.tenant_id = v_t1)
             || '/' || (select count(*) from cma_read.reviews_per_day d where d.tenant_id = v_t1);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['25', 'B15 the reader views: per day, week, market and channel with the previous period, the states, the reviews; tenant two sees none',
      case when v_txt = '2/2.75/10001/1/011/- 1/3/4.00 GB=2 Shop GB=1,Shop NL renamed=2 DE:no_channel,FR:channel_no_reviews,GB:has_reviews,NL:has_reviews 10 1/1 two 0/0'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B16. the alerts (the Ingest user, at the database's now): a published review of 1 on a counted channel raises one
    --      message per matching rule (Negative review, Every review), a 4 only Every review's; nothing for an uncounted
    --      channel, an unpublished review or one older than the rule's age; a second call writes nothing; the body holds
    --      the market, the channel's name, the rating and the time, the link the template's; the deliveries the holders of
    --      performance.team
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_reviews(v_rev, jsonb_build_array(
      jsonb_build_object('reviewId', 'al-1', 'channelId', 'chl-nl', 'type', 'SERVICE_REVIEW', 'state', 'APPROVED', 'isPublished', true,
                         'rating', 1, 'submittedAt', to_char(now() at time zone 'UTC' - interval '10 minutes', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')),
      jsonb_build_object('reviewId', 'al-2', 'channelId', 'chl-nl', 'type', 'SERVICE_REVIEW', 'state', 'APPROVED', 'isPublished', true,
                         'rating', 4, 'submittedAt', to_char(now() at time zone 'UTC' - interval '10 minutes', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')),
      jsonb_build_object('reviewId', 'al-3', 'channelId', 'chl-x', 'type', 'SERVICE_REVIEW', 'state', 'APPROVED', 'isPublished', true,
                         'rating', 1, 'submittedAt', to_char(now() at time zone 'UTC' - interval '10 minutes', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')),
      jsonb_build_object('reviewId', 'al-4', 'channelId', 'chl-nl', 'type', 'SERVICE_REVIEW', 'state', 'PENDING', 'isPublished', false,
                         'rating', 1, 'submittedAt', to_char(now() at time zone 'UTC' - interval '10 minutes', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')),
      jsonb_build_object('reviewId', 'al-5', 'channelId', 'chl-nl', 'type', 'SERVICE_REVIEW', 'state', 'APPROVED', 'isPublished', true,
                         'rating', 1, 'submittedAt', to_char(now() at time zone 'UTC' - interval '2 days', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))));
    v_txt := cma.ingest_review_alerts(v_rev, array['al-1', 'al-2', 'al-3', 'al-4', 'al-5', 'rev-4'])
             || ' ' || cma.ingest_review_alerts(v_rev, array['al-1', 'al-2']);
    perform set_config('role', 'cma_owner', true);
    select v_txt || ' ' || string_agg(ru.name || '>' || m.ref_id, ',' order by ru.name, m.ref_id) into v_txt
    from cma.message m join cma.message_rule ru on ru.tenant_id = m.tenant_id and ru.id = m.rule_id
    where m.tenant_id = v_t1 and m.ref_type = 'review';
    select v_txt || ' ' || (m.title = 'New review') || ' ' || (m.body ~ '^NL · Shop NL renamed · rating 1 of 5 · submitted 20[0-9][0-9]-[01][0-9]-[0-3][0-9] [0-2][0-9]:[0-5][0-9]$')
           || ' ' || (m.ref_url = 'https://reviews.example.invalid/acc-1/reviews/al-1') || ' ' || m.ref_system || ' ' || m.urgency
           || ' ' || ((select count(*) from cma.message_delivery d where d.tenant_id = m.tenant_id and d.message_id = m.id)
                      = (select count(*) from cma.app_user u where u.tenant_id = v_t1 and u.status = 'active' and u.kind = 'person'
                         and cma.has_permission(u.id, 'performance.team')))
           || ' ' || (m.target ->> 'maxRating')
    into v_txt
    from cma.message m join cma.message_rule ru on ru.tenant_id = m.tenant_id and ru.id = m.rule_id and ru.name = 'Negative review'
    where m.tenant_id = v_t1 and m.ref_id = 'al-1';
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['26', 'B16 the alerts: once per rule and review, a counted channel''s published and recent reviews only; market, channel, rating, time, link',
      case when v_txt = '3 0 Every review>al-1,Every review>al-2,Negative review>al-1 true true true verifyreviews urgent true 2.00'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B17. tenant isolation: tenant two's Ingest user cannot write into tenant one's connection (CMA02) and its report
    --      holds nothing of tenant one; tenant one's channels and reviews are invisible from tenant two
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_ing2::text, true);
    v_txt := pg_temp.v0008ze_code(format('select cma.ingest_upsert_review_channels(%L, %L)', v_rev, '[{"channelId": "chl-z", "name": "Z"}]'))
             || ' ' || pg_temp.v0008ze_code(format('select * from cma.ingest_upsert_reviews(%L, %L)', v_rev, '[]'))
             || ' ' || pg_temp.v0008ze_code(format('select cma.set_review_contact(%L, %L, %L, %L)', v_rev, 'rev-1', v_crm, 'c-1'))
             || ' ' || (select count(*) from cma.review r) || '/' || (select count(*) from cma.review_channel ch);
    perform set_config('app.user_id', v_analyst2::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008ze_fig(cma.reviews_page('2026-10-01', '2026-10-14') -> 'figures');
    perform set_config('app.tenant_id', v_t1::text, true);
    v_rows := v_rows || array['27', 'B17 tenant isolation: tenant two writes nothing into tenant one''s connection and sees none of it',
      case when v_txt = 'CMA02 CMA02 CMA02 0/0 0/-/0/0/0/0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B18. Sources: the connection's catalogs list the review channels (the gone one last) with their reviews; a run of the
    --      reviews poll starts and finishes; the audit names the admin for the configuration and the Ingest user for the rows
    perform set_config('app.user_id', v_admin1::text, true);
    k := cma.connection_catalogs(v_rev);
    v_txt := (select string_agg((c ->> 'channelId') || ':' || coalesce(c ->> 'market', '-') || ':' || (c ->> 'isCounted') || ':' || (c ->> 'reviews')
                                || ':' || (c ->> 'deletedAt' is not null), ' ') from jsonb_array_elements(k -> 'reviewChannels') c);
    perform set_config('app.user_id', v_ing1::text, true);
    v_run := cma.ingest_sync_run_start(v_rev, 'reviews_poll', 'reviews', null, v_now);
    perform cma.ingest_sync_run_finish(v_run, 'succeeded', '{"fetched": 12, "upserted": 11, "skipped": 1}');
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || ' ' || (select r.job || ':' || r.status || ':' || (r.counts ->> 'fetched') from cma.sync_run r where r.id = v_run)
             || ' ' || (select count(*) from cma.audit_log a where a.tenant_id = v_t1 and a.table_name = 'review_channel' and a.action = 'update' and a.actor_user_id = v_admin1)
             || '/' || (select count(*) from cma.audit_log a where a.tenant_id = v_t1 and a.table_name = 'review' and a.action = 'insert' and a.actor_user_id = v_ing1);
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['28', 'B18 the review channels on Sources, a run of reviews_poll, the audit''s actors',
      case when v_txt = 'chl-fr:FR:true:0:false chl-gb:GB:true:3:false chl-nl:NL:true:10:false chl-x:-:false:2:false chl-old:-:false:0:true reviews_poll:succeeded:12 3/15'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['59', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008ze (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008ze values (59, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- C. Speed: 20,000 reviews over two years on eight channels (rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_max      numeric := current_setting('verify.max_ms')::numeric;
  v_rows     text[] := '{}';
  v_t uuid; v_admin uuid; v_rev uuid;
  v_ms numeric;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    v_t := cma.create_tenant('verify-0008ze-volume', 'Verify 0008ze volume', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-admin-volume@example.invalid', 'admin') returning id into v_admin;
    insert into cma.user_role (tenant_id, user_id, role_id) select v_t, v_admin, ar.id from cma.app_role ar where ar.tenant_id = v_t and ar.key = 'admin';
    insert into cma.market (tenant_id, code, name, time_zone, language_code, currency)
    select v_t, c, c, 'Europe/Amsterdam', 'en', 'EUR' from unnest(array['NL', 'GB', 'DE', 'FR', 'BE', 'IE', 'DK', 'SE']) c;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t, 'verifyreviews', 'Verify reviews volume', 'acc-v', 'reviews') returning id into v_rev;
    insert into cma.review_channel (tenant_id, connection_id, source_id, name, market, is_counted)
    select v_t, v_rev, 'chl-' || c, 'Shop ' || c, c, true from unnest(array['NL', 'GB', 'DE', 'FR', 'BE', 'IE', 'DK', 'SE']) c;
    insert into cma.review (tenant_id, connection_id, review_channel_id, source_system, source_id, review_type, state, is_published, rating,
                            submitted_at, source_updated_at, invite_event_type, link_level)
    select v_t, v_rev, (select ch.id from cma.review_channel ch where ch.tenant_id = v_t order by ch.source_id offset (g % 8) limit 1),
           'verifyreviews', 'rev-' || g, 'SERVICE_REVIEW', 'APPROVED', g % 50 <> 0, 1 + (g % 5), '2026-10-14 10:00:00+00'::timestamptz - make_interval(mins => g * 52),
           '2026-10-14 10:00:00+00'::timestamptz - make_interval(mins => g * 52), case when g % 3 = 0 then 'checkout' end, 'none'
    from generate_series(1, 20000) g;
    analyze cma.review;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    v_ms := pg_temp.v0008ze_best_ms(format('select cma.reviews_page_of(%L, %L, %L, null, %L, %L)', v_t, '2026-07-15', '2026-10-14', 'week',
                                           '2026-10-14 10:00:00+00'), 3);
    v_rows := v_rows || array['41', 'C1 the page of 92 days over 20,000 reviews, as the application, under verify.max_ms',
      case when v_ms < v_max and not v_provoke then 'PASS' else 'FAIL' end, v_ms || ' ms'];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['79', 'C the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008ze (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008ze values (79, 'C the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008ze
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED: not dev'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008ze where result = 'PASS') = 27
                       and not exists (select 1 from verify_0008ze where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('105_verify_reviews: %s PASS, %s FAIL', (select count(*) from verify_0008ze where result = 'PASS'),
                                                            (select count(*) from verify_0008ze where result <> 'PASS'))) x
order by ord;
drop function if exists pg_temp.v0008ze_code(text);
drop function if exists pg_temp.v0008ze_best_ms(text, integer);
drop function if exists pg_temp.v0008ze_fig(jsonb);
reset role;
