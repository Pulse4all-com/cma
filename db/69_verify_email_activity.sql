-- =============================================================================================
-- 69_verify_email_activity.sql: verifies addition 0008m, email activity (metadata only)
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure
-- and privileges; block B works on two throwaway tenants inside a subtransaction that is always
-- rolled back. Universal otherwise: nothing of the seed is used; adapters, inboxes, channels,
-- owners, contacts, records and emails are invented data values, and the text the raw-payload check
-- sends (a subject, a body, names and addresses) is invented too and must not be stored. Every
-- check writes one row, PASS or FAIL, and the last result lists them with the verdict, because
-- Cloud SQL Studio shows no notices. Run as your own IAM login in dev, after 68_email_activity.sql;
-- then 33, 35 and 53 again.
--   A  structure and privileges: the addition row after 0008l; the six tables with row-level
--      security, the tenant policy, the audit trigger, no delete for the application and no update
--      of a thread event, no reader on a base table; the reporting views' exact column lists, without
--      raw; no column named like subject, body, text, html, header, attachment, email address,
--      sender or recipient in the new tables and views; the four settings with their defaults; every
--      function the application's only and in the caller's rights, the category rule the owner's only
--   B  behaviour on two tenants (Europe/Amsterdam; markets NL, GB, DE in tenant one, alias uk for
--      GB): the settings' checks and the start date following intake.start_date; inbox and channel
--      refreshes keeping configuration; the stale guard on emails and threads, deletion and return;
--      idempotent thread events; the market by email.market_order, step by step, a removed
--      association, a deleted record, a later alias and unknown; rule ordering, inactive rules,
--      words normalised and nine refusals; the contact's privacy deletion; a conversation's privacy
--      deletion and a later read; tenant isolation, also against the owner's view; the Ingest user
--      unable to configure and a configuring person unable to ingest; the raw payload and the refs
--      keeping nothing personal; the connection's kind; associations of email engagements; the
--      configuration the adapter reads; where each thread's messages stand; the email poll's runs
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
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 69 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0008m;
create temp table verify_0008m (ord int, check_name text, result text, detail text);

-- The SQLSTATE a statement raises, or 'ok' (inside a subtransaction, so a refusal writes nothing)
create or replace function pg_temp.v8m_err(p_sql text)
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

-- One email as the ingest write takes it: status sent, updated when it occurred, plus p_extra
create or replace function pg_temp.v8m_email(p_kind text, p_src text, p_dir text, p_at timestamptz, p_extra jsonb default '{}')
returns jsonb
language sql immutable
as $$
  select jsonb_build_object('sourceKind', p_kind, 'sourceId', p_src, 'direction', p_dir, 'status', 'sent',
                            'occurredAt', p_at, 'updatedAt', p_at) || coalesce(p_extra, '{}'::jsonb)
$$;

-- One inbox conversation as the ingest write takes it, plus p_extra
create or replace function pg_temp.v8m_thread(p_src text, p_status text, p_created timestamptz, p_updated timestamptz,
                                              p_extra jsonb default '{}')
returns jsonb
language sql immutable
as $$
  select jsonb_build_object('sourceId', p_src, 'status', p_status, 'createdAt', p_created, 'updatedAt', p_updated)
         || coalesce(p_extra, '{}'::jsonb)
$$;

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_t       text;
  v_fn      text;
  v_bad     text;
  v_cols    text;
  v_want    text;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  -- A1. the addition is recorded, after 0008l
  insert into verify_0008m values (1, 'A1 addition 0008m recorded, after 0008l',
    case when exists (select 1 from cma.schema_migration where version = '0008m')
              and exists (select 1 from cma.schema_migration where version = '0008l') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the six tables: row-level security with the tenant policy and the audit trigger; the
  --     application inserts and updates, never deletes, and never updates a thread event; readers have
  --     no rights on a base table and read its view in cma_read
  v_bad := '';
  foreach v_t in array array['connection_inbox', 'connection_inbox_channel', 'connection_email_rule', 'email_thread',
                             'email_message', 'email_thread_event'] loop
    if to_regclass('cma.' || v_t) is null then
      v_bad := v_bad || v_t || ' is missing; ';
      continue;
    end if;
    if not (select relrowsecurity from pg_class where oid = ('cma.' || v_t)::regclass) then v_bad := v_bad || v_t || ' has no row-level security; '; end if;
    if not exists (select 1 from pg_policies where schemaname = 'cma' and tablename = v_t and policyname = 'tenant_app') then v_bad := v_bad || v_t || ' has no tenant policy; '; end if;
    if not exists (select 1 from pg_trigger where tgrelid = ('cma.' || v_t)::regclass and tgname = 'audit') then v_bad := v_bad || v_t || ' has no audit trigger; '; end if;
    if not has_table_privilege('cma_app', 'cma.' || v_t, 'insert') then v_bad := v_bad || 'the application cannot insert into ' || v_t || '; '; end if;
    if has_table_privilege('cma_app', 'cma.' || v_t, 'delete') then v_bad := v_bad || 'the application may delete from ' || v_t || '; '; end if;
    if has_table_privilege('cma_app', 'cma.' || v_t, 'update') <> (v_t <> 'email_thread_event') then
      v_bad := v_bad || v_t || ' has the wrong update right for the application; ';
    end if;
    if has_table_privilege('cma_readonly', 'cma.' || v_t, 'select') then v_bad := v_bad || 'readers read the base table ' || v_t || '; '; end if;
    if to_regclass('cma_read.' || v_t) is null then v_bad := v_bad || v_t || ' has no reader view; '; end if;
  end loop;
  insert into verify_0008m values (2, 'A2 the six tables: RLS, tenant policy, audit, no delete, events insert-only, a reader view each',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A3. the reporting views' exact column lists: every column of the table but raw
  v_bad := '';
  foreach v_t in array array[
    'connection_inbox=tenant_id,connection_id,source_inbox_id,name,is_counted,market,work_type_skill_id,channel_id,status,refreshed_at,updated_at',
    'connection_inbox_channel=tenant_id,connection_id,source_channel_id,name,kind,channel_id,is_counted,status,refreshed_at,updated_at',
    'connection_email_rule=id,tenant_id,connection_id,applies_to,words,exclude_words,category,sort_order,status,created_at,updated_at',
    'email_thread=id,tenant_id,connection_id,source_system,source_id,inbox_source_id,channel_source_id,status,source_created_at,closed_at,owner_ref,contact_source_id,ticket_source_id,is_spam,is_archived,category,latest_received_at,latest_sent_at,source_updated_at,forgotten_at,synced_at',
    'email_message=id,tenant_id,connection_id,source_system,source_kind,source_id,thread_source_id,inbox_source_id,channel_source_id,direction,status,occurred_at,actor_kind,owner_ref,category,contact_source_id,source_created_at,source_updated_at,source_deleted_at,synced_at',
    'email_thread_event=id,tenant_id,connection_id,source_id,thread_source_id,kind,occurred_at,actor_kind,owner_ref,to_actor_kind,to_owner_ref,from_inbox_source_id,to_inbox_source_id,synced_at'] loop
    v_want := split_part(v_t, '=', 2);
    select string_agg(column_name, ',' order by ordinal_position) into v_cols
    from information_schema.columns where table_schema = 'cma_read' and table_name = split_part(v_t, '=', 1);
    if v_cols is distinct from v_want then
      v_bad := v_bad || split_part(v_t, '=', 1) || ' has ' || coalesce(v_cols, 'no columns') || '; ';
    end if;
    -- the table holds exactly the view's columns plus raw (none for the catalogs, rules and events)
    select string_agg(column_name, ',' order by ordinal_position) into v_cols
    from information_schema.columns where table_schema = 'cma' and table_name = split_part(v_t, '=', 1);
    if split_part(v_t, '=', 1) in ('email_thread', 'email_message') then
      v_want := v_want || ',raw';
    end if;
    if v_cols is distinct from v_want then
      v_bad := v_bad || 'the table ' || split_part(v_t, '=', 1) || ' has ' || coalesce(v_cols, 'no columns') || '; ';
    end if;
  end loop;
  insert into verify_0008m values (3, 'A3 the reporting views'' exact columns: every column but raw',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A4. no column named like content or a person's address anywhere in the new tables and views
  select string_agg(table_schema || '.' || table_name || '.' || column_name, ', ') into v_bad
  from information_schema.columns
  where table_schema in ('cma', 'cma_read')
    and table_name in ('connection_inbox', 'connection_inbox_channel', 'connection_email_rule', 'email_thread', 'email_message',
                       'email_thread_event')
    and column_name ~* '(subject|body|text|html|header|attach|email_address|^email$|address|sender|recipient)';
  insert into verify_0008m values (4, 'A4 no subject, body, text, address, sender or recipient column in the new tables and views',
    case when v_bad is null and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_bad, ''));

  -- A5. the four settings in the catalog with their defaults
  select string_agg(key || '=' || value_type || ':' || default_value, ' ' order by key) into v_bad
  from cma.setting where key like 'email.%';
  insert into verify_0008m values (5, 'A5 the settings email.start_date, reply_target_minutes, no_response_days, market_order',
    case when v_bad = 'email.market_order=text:record,inbox,contact email.no_response_days=integer:5 email.reply_target_minutes=integer:240 email.start_date=text:'
              and not v_provoke then 'PASS' else 'FAIL' end,
    coalesce(v_bad, 'missing'));

  -- A6. every function the application's only and in the caller's rights; the category rule the
  --     owner's only (so it is never called with a real subject)
  v_bad := '';
  foreach v_fn in array array[
    'cma.ingest_upsert_inboxes(uuid,jsonb)', 'cma.ingest_upsert_inbox_channels(uuid,jsonb)', 'cma.ingest_upsert_threads(uuid,jsonb)',
    'cma.ingest_upsert_emails(uuid,jsonb)', 'cma.ingest_upsert_thread_events(uuid,jsonb)', 'cma.ingest_thread_marks(uuid,text[])',
    'cma.ingest_upsert_associations(uuid,jsonb)', 'cma.set_inbox(uuid,text,boolean,text,text,text)',
    'cma.set_inbox_channel(uuid,text,text,boolean)', 'cma.set_email_rule(uuid,uuid,text,text[],text[],text,integer)',
    'cma.set_email_rule_status(uuid,text)', 'cma.connection_config(uuid)', 'cma.ingest_contact_forget(uuid,text)',
    'cma.ingest_thread_forget(uuid,text)', 'cma.email_start_date_of(uuid)', 'cma.email_market_of(uuid,uuid,text,text)',
    'cma.connection_held_kinds_of(uuid,uuid)', 'cma.assert_email_connection(uuid,boolean)', 'cma.email_raw(jsonb)',
    'cma.email_words(text[])', 'cma.email_words_ok(text[])', 'cma.email_words_match(text,text[],text[])',
    'cma.is_email_market_order(text)', 'cma.json_flag(jsonb,text)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' is missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                     where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      v_bad := v_bad || v_fn || ' is not the application''s only, in the caller''s rights; ';
    end if;
  end loop;
  v_fn := 'cma.email_category_of(uuid,uuid,text,text)';
  if to_regprocedure(v_fn) is null then
    v_bad := v_bad || v_fn || ' is missing; ';
  elsif has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
        or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
    v_bad := v_bad || v_fn || ' is not the owner''s only; ';
  end if;
  insert into verify_0008m values (6, 'A6 the functions the application''s only, in the caller''s rights; the category rule the owner''s only',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);
end
$$;

-- B. Behaviour on two throwaway tenants (rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_rows     text[] := '{}';
  v_t1 uuid; v_t2 uuid;
  v_admin1 uuid; v_agent1 uuid; v_ing1 uuid; v_admin2 uuid; v_ing2 uuid;
  v_c1 uuid; v_c2 uuid; v_tel1 uuid; v_x1 uuid;
  v_r0 uuid; v_r1 uuid; v_r2 uuid; v_r3 uuid;
  v_run      uuid;
  v_txt      text;
  v_txt2     text;
  v_detail   text;
  v_n        integer;
  v_m        integer;
  v_res      jsonb;
  v_res2     jsonb;
  rr         record;
  k          text;
  t0 timestamptz := timestamptz '2026-10-05 10:00:00+00';
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    v_t1 := cma.create_tenant('verify-0008m-one', 'Verify 0008m one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008m-two', 'Verify 0008m two', 'Europe/Amsterdam');
    insert into cma.channel (tenant_id, key, name, is_synchronous)
    values (v_t1, 'email', 'Email', false), (v_t1, 'phone', 'Phone', true), (v_t2, 'email', 'Email', false);
    insert into cma.skill (tenant_id, dimension, key, name) values (v_t1, 'work_type', 'verify-sales', 'Verify sales');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent1@example.invalid', 'agent1') returning id into v_agent1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin2') returning id into v_admin2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_agent1, 'agent'), (v_t2, v_admin2, 'admin')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    select x.user_id into v_ing2 from cma.app_user_external_id x where x.tenant_id = v_t2 and x.system = 'ingest';
    perform set_config('role', 'cma_app', true);

    -- tenant one: markets NL, GB and DE with the alias uk; a CRM connection, a telephony connection and
    -- one without a kind or rows
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP');
    perform cma.upsert_market('DE', 'Germany', 'Europe/Berlin', 'de', 'EUR');
    perform cma.set_market_alias('uk', 'GB');
    select c.connection_id into v_c1 from cma.upsert_connection('verifycrm', 'Verify CRM one', 'portal-1', null, null) c;
    perform cma.set_connection_kind(v_c1, 'crm');
    select c.connection_id into v_tel1 from cma.upsert_connection('verifytel', 'Verify phones one', 'company-1', null, null) c;
    perform cma.set_connection_kind(v_tel1, 'telephony');
    select c.connection_id into v_x1 from cma.upsert_connection('verifyother', 'Verify other one', 'account-1', null, null) c;

    -- tenant two: the same refs on its own CRM connection
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    select c.connection_id into v_c2 from cma.upsert_connection('verifycrm', 'Verify CRM two', 'portal-1', null, null) c;
    perform cma.set_connection_kind(v_c2, 'crm');

    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);

    -- B1. the settings: the start date follows intake.start_date while empty; the market order written
    --     in lower case without spaces; ten values refused
    v_txt := cma.email_start_date_of(v_t1)::text;
    perform cma.set_tenant_setting('intake.start_date', '2026-09-15');
    v_txt := v_txt || ' ' || cma.email_start_date_of(v_t1)::text;
    perform cma.set_tenant_setting('email.start_date', ' 2026-08-01 ');
    v_txt := v_txt || ' ' || cma.email_start_date_of(v_t1)::text;
    perform cma.set_tenant_setting('email.start_date', '');
    v_txt := v_txt || ' ' || cma.email_start_date_of(v_t1)::text;
    perform cma.set_tenant_setting('email.market_order', ' Inbox , RECORD ');
    v_txt := v_txt || ' ' || (select value from cma.tenant_setting where tenant_id = v_t1 and key = 'email.market_order');
    v_n := 0;
    foreach v_detail in array array['email.market_order=record,record', 'email.market_order=deal', 'email.market_order=',
                                    'email.start_date=2026-13-01', 'email.start_date=1 Oct', 'email.reply_target_minutes=0',
                                    'email.reply_target_minutes=10081', 'email.reply_target_minutes=x', 'email.no_response_days=0',
                                    'email.no_response_days=91'] loop
      if pg_temp.v8m_err(format('select cma.set_tenant_setting(%L, %L)', split_part(v_detail, '=', 1), split_part(v_detail, '=', 2))) = 'CMA04' then
        v_n := v_n + 1;
      end if;
    end loop;
    perform cma.set_tenant_setting('email.market_order', null);
    perform cma.set_tenant_setting('intake.start_date', null);
    v_rows := v_rows || array['11', 'B1 the settings: the start date, the market order, ten refusals',
      case when v_txt = '2026-10-01 2026-09-15 2026-08-01 2026-09-15 inbox,record' and v_n = 10 and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s | %s of 10 refused', v_txt, v_n)];

    -- B2. an inbox and channel refresh keeps the configuration: names follow the source, an inbox or a
    --     channel missing from the source is archived, a new inbox counts in the email channel, a new
    --     channel takes the channel of its kind and counts only as email; four refusals of set_inbox
    perform set_config('app.user_id', v_ing1::text, true);
    v_n := cma.ingest_upsert_inboxes(v_c1, '[{"inboxId": "in-1", "name": "Verify inbox one"}, {"inboxId": "in-2", "name": "Verify inbox two"}]');
    perform cma.ingest_upsert_inbox_channels(v_c1, '[{"channelId": "ch-1", "name": "Verify email", "kind": "email"},
      {"channelId": "ch-2", "name": "Verify chat", "kind": "chat"}, {"channelId": "ch-3", "name": "Verify forms"}]');
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_inbox(v_c1, 'in-1', false, 'NL', 'verify-sales', 'phone');
    perform cma.set_inbox_channel(v_c1, 'ch-2', 'phone', true);
    perform set_config('app.user_id', v_ing1::text, true);
    v_m := cma.ingest_upsert_inboxes(v_c1, '[{"inboxId": "in-1", "name": "Verify inbox one renamed"}, {"inboxId": "in-3", "name": "Verify inbox three"}]');
    perform cma.ingest_upsert_inbox_channels(v_c1, '[{"channelId": "ch-1", "name": "Verify email", "kind": "email"},
      {"channelId": "ch-2", "name": "Verify chat renamed", "kind": "chat"}]');
    select string_agg(format('%s:%s:%s:%s:%s:%s:%s', b.source_inbox_id, b.name, b.is_counted, coalesce(b.market, '-'), coalesce(s.key, '-'),
                             coalesce(ch.key, '-'), b.status), ' ' order by b.source_inbox_id) into v_txt
    from cma.connection_inbox b
    left join cma.skill s on s.tenant_id = b.tenant_id and s.id = b.work_type_skill_id
    left join cma.channel ch on ch.tenant_id = b.tenant_id and ch.id = b.channel_id
    where b.connection_id = v_c1;
    select string_agg(format('%s:%s:%s:%s:%s:%s', k2.source_channel_id, k2.name, k2.kind, coalesce(ch.key, '-'), k2.is_counted, k2.status), ' '
                      order by k2.source_channel_id) into v_txt2
    from cma.connection_inbox_channel k2
    left join cma.channel ch on ch.tenant_id = k2.tenant_id and ch.id = k2.channel_id
    where k2.connection_id = v_c1;
    perform set_config('app.user_id', v_admin1::text, true);
    v_detail := pg_temp.v8m_err(format('select cma.set_inbox(%L, %L, true, %L, null, null)', v_c1, 'in-3', 'FR'))
             || ',' || pg_temp.v8m_err(format('select cma.set_inbox(%L, %L, true, null, %L, null)', v_c1, 'in-3', 'verify-none'))
             || ',' || pg_temp.v8m_err(format('select cma.set_inbox(%L, %L, true, null, null, %L)', v_c1, 'in-3', 'verify-none'))
             || ',' || pg_temp.v8m_err(format('select cma.set_inbox(%L, %L, null, null, null, null)', v_c1, 'in-3'));
    v_rows := v_rows || array['12', 'B2 an inbox and channel refresh keeps the configuration; four refusals',
      case when v_n = 2 and v_m = 2
                and v_txt = 'in-1:Verify inbox one renamed:f:NL:verify-sales:phone:active in-2:Verify inbox two:t:-:-:email:archived in-3:Verify inbox three:t:-:-:email:active'
                and v_txt2 = 'ch-1:Verify email:email:email:t:active ch-2:Verify chat renamed:chat:phone:t:active ch-3:Verify forms:other:-:f:archived'
                and v_detail = 'CMA02,CMA02,CMA02,CMA04' and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s %s | %s | %s | %s', v_n, v_m, v_txt, v_txt2, v_detail)];

    -- B3. the stale guard on the source's updated time: an email inserted, an older read stale, a
    --     newer read updated, a deletion keeping ids and metadata, a deletion of an unknown email, a
    --     newer read bringing it back; a thread inserted, stale, closed (the source's close time kept by
    --     a later read without one) and reopened
    perform set_config('app.user_id', v_ing1::text, true);
    v_txt := '';
    for rr in select * from (values
        (1, pg_temp.v8m_email('crm_email', 'e-1', 'out', t0, jsonb_build_object('actorKind', 'agent', 'ownerRef', 'own-1', 'updatedAt', t0 + interval '5 minutes', 'raw', '{"n": 1}'::jsonb))),
        (2, pg_temp.v8m_email('crm_email', 'e-1', 'out', t0, jsonb_build_object('status', 'bounced', 'updatedAt', t0 + interval '1 minute'))),
        (3, pg_temp.v8m_email('crm_email', 'e-1', 'out', t0, jsonb_build_object('status', 'bounced', 'actorKind', 'agent', 'ownerRef', 'own-1', 'updatedAt', t0 + interval '10 minutes', 'raw', '{"n": 2}'::jsonb))),
        (4, jsonb_build_object('sourceKind', 'crm_email', 'sourceId', 'e-1', 'deletedAt', t0 + interval '1 hour')),
        (5, jsonb_build_object('sourceKind', 'crm_email', 'sourceId', 'e-none', 'deletedAt', t0 + interval '1 hour'))) x(ord, item)
      order by ord loop
      select v_txt || string_agg(o.outcome, ',') || ',' into v_txt from cma.ingest_upsert_emails(v_c1, jsonb_build_array(rr.item)) o;
      if rr.ord = 2 then
        v_txt := v_txt || (select status from cma.email_message where connection_id = v_c1 and source_id = 'e-1') || ',';
      end if;
    end loop;
    select v_txt || format('%s:%s:%s:%s,', status, owner_ref, raw, source_deleted_at is not null) into v_txt
    from cma.email_message where connection_id = v_c1 and source_id = 'e-1';
    select v_txt || string_agg(o.outcome, ',') into v_txt
    from cma.ingest_upsert_emails(v_c1, jsonb_build_array(pg_temp.v8m_email('crm_email', 'e-1', 'out', t0,
           jsonb_build_object('status', 'bounced', 'actorKind', 'agent', 'ownerRef', 'own-1', 'updatedAt', t0 + interval '2 hours')))) o;
    select v_txt || format(',%s', source_deleted_at is null) into v_txt from cma.email_message where connection_id = v_c1 and source_id = 'e-1';
    v_txt2 := '';
    for rr in select * from (values
        (1, pg_temp.v8m_thread('th-1', 'open', t0 - interval '1 hour', t0 - interval '30 minutes',
              '{"inboxId": "in-1", "channelId": "ch-1", "ticketId": "t-1", "contactId": "c-1", "ownerRef": "own-1"}'::jsonb)),
        (2, pg_temp.v8m_thread('th-1', 'closed', t0 - interval '1 hour', t0 - interval '50 minutes',
              '{"inboxId": "in-1", "ticketId": "t-1", "contactId": "c-1"}'::jsonb)),
        (3, pg_temp.v8m_thread('th-1', 'closed', t0 - interval '1 hour', t0,
              jsonb_build_object('inboxId', 'in-1', 'ticketId', 't-1', 'contactId', 'c-1', 'closedAt', t0 - interval '5 minutes'))),
        (4, pg_temp.v8m_thread('th-1', 'closed', t0 - interval '1 hour', t0 + interval '30 minutes',
              '{"inboxId": "in-1", "ticketId": "t-1", "contactId": "c-1"}'::jsonb)),
        (5, pg_temp.v8m_thread('th-1', 'open', t0 - interval '1 hour', t0 + interval '1 hour',
              '{"inboxId": "in-1", "ticketId": "t-1", "contactId": "c-1", "ownerRef": "own-2"}'::jsonb))) x(ord, item)
      order by ord loop
      select v_txt2 || string_agg(o.outcome, ',') into v_txt2 from cma.ingest_upsert_threads(v_c1, jsonb_build_array(rr.item)) o;
      select v_txt2 || format(':%s:%s ', status, coalesce(to_char(closed_at at time zone 'UTC', 'HH24:MI'), '-')) into v_txt2
      from cma.email_thread where connection_id = v_c1 and source_id = 'th-1';
    end loop;
    v_rows := v_rows || array['13', 'B3 the stale guard on emails and threads; deletion and return',
      case when v_txt = 'inserted,stale,sent,updated,deleted,unknown,bounced:own-1:{}:t,updated,t'
                and v_txt2 = 'inserted:open:- stale:open:- updated:closed:09:55 updated:closed:09:55 updated:open:- '
                and not v_provoke then 'PASS' else 'FAIL' end,
      v_txt || ' | ' || v_txt2];

    -- B4. thread events are written once per source message: three inserted, the same three again
    --     known and unchanged (a changed payload included), an unassignment by an AI agent allowed;
    --     three refusals
    v_txt := '';
    select string_agg(o.outcome, ',') into v_txt
    from cma.ingest_upsert_thread_events(v_c1, jsonb_build_array(
      jsonb_build_object('sourceId', 'ev-1', 'threadId', 'th-1', 'kind', 'assigned', 'occurredAt', t0 - interval '55 minutes',
                         'actorKind', 'agent', 'ownerRef', 'own-1', 'toActorKind', 'agent', 'toOwnerRef', 'own-2'),
      jsonb_build_object('sourceId', 'ev-2', 'threadId', 'th-1', 'kind', 'closed', 'occurredAt', t0 - interval '5 minutes',
                         'actorKind', 'agent', 'ownerRef', 'own-2'),
      jsonb_build_object('sourceId', 'ev-3', 'threadId', 'th-1', 'kind', 'moved_inbox', 'occurredAt', t0 - interval '40 minutes',
                         'actorKind', 'system', 'fromInboxId', 'in-3', 'toInboxId', 'in-1'))) o;
    select v_txt || ' ' || string_agg(o.outcome, ',') into v_txt
    from cma.ingest_upsert_thread_events(v_c1, jsonb_build_array(
      jsonb_build_object('sourceId', 'ev-1', 'threadId', 'th-1', 'kind', 'assigned', 'occurredAt', t0 - interval '55 minutes',
                         'actorKind', 'agent', 'ownerRef', 'own-1', 'toActorKind', 'agent', 'toOwnerRef', 'own-9'),
      jsonb_build_object('sourceId', 'ev-2', 'threadId', 'th-1', 'kind', 'closed', 'occurredAt', t0 - interval '5 minutes',
                         'actorKind', 'agent', 'ownerRef', 'own-2'),
      jsonb_build_object('sourceId', 'ev-3', 'threadId', 'th-1', 'kind', 'moved_inbox', 'occurredAt', t0 - interval '40 minutes',
                         'actorKind', 'system', 'fromInboxId', 'in-3', 'toInboxId', 'in-1'),
      jsonb_build_object('sourceId', 'ev-4', 'threadId', 'th-1', 'kind', 'assigned', 'occurredAt', t0 + interval '50 minutes',
                         'actorKind', 'ai'))) o;
    select v_txt || format(' %s %s %s', count(*), max(to_owner_ref) filter (where source_id = 'ev-1'),
                           string_agg(actor_kind || '>' || coalesce(to_actor_kind, '-'), ',' order by source_id)) into v_txt
    from cma.email_thread_event where connection_id = v_c1;
    v_detail := pg_temp.v8m_err(format('select cma.ingest_upsert_thread_events(%L, %L)', v_c1,
                  jsonb_build_array(jsonb_build_object('sourceId', 'ev-x1', 'threadId', 'th-1', 'kind', 'closed', 'occurredAt', t0,
                                                       'actorKind', 'agent', 'toActorKind', 'agent', 'toOwnerRef', 'own-2'))))
             || ',' || pg_temp.v8m_err(format('select cma.ingest_upsert_thread_events(%L, %L)', v_c1,
                  jsonb_build_array(jsonb_build_object('sourceId', 'ev-x2', 'threadId', 'th-1', 'kind', 'closed', 'occurredAt', t0,
                                                       'actorKind', 'customer', 'ownerRef', 'own-2'))))
             || ',' || pg_temp.v8m_err(format('select cma.ingest_upsert_thread_events(%L, %L)', v_c1,
                  jsonb_build_array(jsonb_build_object('sourceId', 'ev-x3', 'threadId', 'th-1', 'kind', 'merged', 'occurredAt', t0))));
    v_rows := v_rows || array['14', 'B4 thread events idempotent on the source message id; three refusals',
      case when v_txt = 'inserted,inserted,inserted known,known,known,inserted 4 own-2 agent>agent,agent>-,system>-,ai>-'
                and v_detail = 'CMA04,CMA04,CMA04'
                and not v_provoke then 'PASS' else 'FAIL' end,
      v_txt || ' | ' || v_detail];

    -- B5. the market by email.market_order: records (ticket before deal), inbox, contact, unknown; the
    --     order changed; a removed association; a deleted record; an alias added later
    perform cma.ingest_upsert_records(v_c1, jsonb_build_array(
      jsonb_build_object('recordType', 'ticket', 'sourceId', 't-1', 'market', 'de', 'createdAt', t0 - interval '1 day', 'updatedAt', t0 - interval '1 day'),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd-1', 'market', 'NL', 'contactId', 'c-1', 'createdAt', t0 - interval '1 day', 'updatedAt', t0 - interval '1 day'),
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd-2', 'contactId', 'c-2', 'createdAt', t0 - interval '1 day', 'updatedAt', t0 - interval '1 day')));
    perform cma.ingest_upsert_contacts(v_c1, jsonb_build_array(
      jsonb_build_object('sourceId', 'c-1', 'country', 'uk', 'updatedAt', t0 - interval '1 day'),
      jsonb_build_object('sourceId', 'c-2', 'country', 'nederland', 'updatedAt', t0 - interval '1 day')));
    perform cma.ingest_upsert_threads(v_c1, jsonb_build_array(
      pg_temp.v8m_thread('th-2', 'open', t0, t0, '{"inboxId": "in-3", "contactId": "c-2"}'::jsonb)));
    perform cma.ingest_upsert_emails(v_c1, jsonb_build_array(
      pg_temp.v8m_email('crm_email', 'e-m1', 'out', t0, '{"actorKind": "agent", "ownerRef": "own-1"}'::jsonb),
      pg_temp.v8m_email('inbox_message', 'm-1', 'in', t0 - interval '50 minutes', '{"threadId": "th-1", "inboxId": "in-1", "channelId": "ch-1", "actorKind": "customer"}'::jsonb),
      pg_temp.v8m_email('crm_email', 'e-m2', 'in', t0, '{"actorKind": "customer"}'::jsonb),
      pg_temp.v8m_email('inbox_message', 'm-2', 'in', t0, '{"threadId": "th-2", "actorKind": "customer"}'::jsonb)));
    perform cma.ingest_upsert_associations(v_c1, jsonb_build_array(
      jsonb_build_object('fromType', 'ticket', 'fromId', 't-1', 'toType', 'crm_email', 'toId', 'e-m1', 'removed', false, 'changedAt', t0),
      jsonb_build_object('fromType', 'crm_email', 'fromId', 'e-m1', 'toType', 'deal', 'toId', 'd-1', 'removed', false, 'changedAt', t0),
      jsonb_build_object('fromType', 'contact', 'fromId', 'c-1', 'toType', 'crm_email', 'toId', 'e-m1', 'removed', false, 'changedAt', t0)));
    v_txt := '';
    foreach v_detail in array array['crm_email:e-m1', 'inbox_message:m-1', 'crm_email:e-m2', 'inbox_message:m-2'] loop
      select v_txt || format('%s=%s/%s ', split_part(v_detail, ':', 2), m.code, coalesce(m.source, '-')) into v_txt
      from cma.email_market_of(v_t1, v_c1, split_part(v_detail, ':', 1), split_part(v_detail, ':', 2)) m;
    end loop;
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('email.market_order', 'inbox,record,contact');
    select v_txt || format('| m-1=%s/%s ', m.code, m.source) into v_txt from cma.email_market_of(v_t1, v_c1, 'inbox_message', 'm-1') m;
    select v_txt || format('e-m1=%s/%s ', m.code, m.source) into v_txt from cma.email_market_of(v_t1, v_c1, 'crm_email', 'e-m1') m;
    select v_txt || format('th-1=%s/%s ', m.code, m.source) into v_txt from cma.email_market_of(v_t1, v_c1, 'inbox_thread', 'th-1') m;
    perform cma.set_tenant_setting('email.market_order', 'contact,inbox,record');
    select v_txt || format('| m-1=%s/%s ', m.code, m.source) into v_txt from cma.email_market_of(v_t1, v_c1, 'inbox_message', 'm-1') m;
    select v_txt || format('e-m1=%s/%s ', m.code, m.source) into v_txt from cma.email_market_of(v_t1, v_c1, 'crm_email', 'e-m1') m;
    perform cma.set_tenant_setting('email.market_order', null);
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_associations(v_c1, jsonb_build_array(
      jsonb_build_object('fromType', 'crm_email', 'fromId', 'e-m1', 'toType', 'ticket', 'toId', 't-1', 'removed', true, 'changedAt', t0 + interval '1 minute')));
    select v_txt || format('| e-m1=%s/%s ', m.code, m.source) into v_txt from cma.email_market_of(v_t1, v_c1, 'crm_email', 'e-m1') m;
    perform cma.ingest_upsert_records(v_c1, jsonb_build_array(
      jsonb_build_object('recordType', 'deal', 'sourceId', 'd-1', 'deletedAt', t0 + interval '2 minutes')));
    select v_txt || format('e-m1=%s/%s ', m.code, m.source) into v_txt from cma.email_market_of(v_t1, v_c1, 'crm_email', 'e-m1') m;
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_market_alias('nederland', 'NL');
    select v_txt || format('| m-2=%s/%s', m.code, m.source) into v_txt from cma.email_market_of(v_t1, v_c1, 'inbox_message', 'm-2') m;
    v_rows := v_rows || array['15', 'B5 the market by email.market_order, step by step, at query time',
      case when v_txt = 'e-m1=DE/record m-1=DE/record e-m2=unknown/- m-2=unknown/- | m-1=NL/inbox e-m1=DE/record th-1=NL/inbox | m-1=GB/contact e-m1=GB/contact | e-m1=NL/record e-m1=GB/contact | m-2=NL/contact'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B6. rule ordering: the first active rule by its order whose words the value of its kind contains
    --     and no exclude word; a rule moved down; an inactive rule skipped until switched on; words
    --     normalised; nine refusals
    v_r1 := cma.set_email_rule(v_c1, null, 'subject', array['Invoice'], null, 'billing', 20);
    v_r2 := cma.set_email_rule(v_c1, null, 'sender_domain', array['example.org'], null, 'system_mail', 10);
    v_r3 := cma.set_email_rule(v_c1, null, 'subject', array['factuur', ' INVOICE ', 'invoice', ''], array['Reminder'], 'billing_nl', 30);
    v_r0 := cma.set_email_rule(v_c1, null, 'subject', array['e'], null, 'catch_all', 1);
    perform cma.set_email_rule_status(v_r0, 'inactive');
    perform set_config('role', 'cma_owner', true);
    select string_agg(coalesce(cma.email_category_of(v_t1, v_c1, x.d, x.s), '-'), ' ' order by x.ord) into v_txt
    from (values (1, 'mail.example.org', 'Invoice 12'), (2, 'customer.test', 'Your INVOICE is ready'), (3, 'customer.test', 'Factuur 7'),
                 (4, 'customer.test', 'Factuur reminder'), (5, null, null)) x(ord, d, s);
    perform set_config('role', 'cma_app', true);
    perform cma.set_email_rule(v_c1, v_r2, 'sender_domain', array['example.org'], null, 'system_mail', 40);
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || ' | ' || coalesce(cma.email_category_of(v_t1, v_c1, 'mail.example.org', 'Invoice 12'), '-');
    perform set_config('role', 'cma_app', true);
    perform cma.set_email_rule_status(v_r0, 'active');
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || ' | ' || coalesce(cma.email_category_of(v_t1, v_c1, 'mail.example.org', 'Invoice 12'), '-');
    perform set_config('role', 'cma_app', true);
    select v_txt || format(' | %s %s', words, exclude_words) into v_txt from cma.connection_email_rule where id = v_r3;
    select v_txt || ' | ' || string_agg(r ->> 'category', ',' order by ord) into v_txt
    from jsonb_array_elements(cma.connection_config(v_c1) -> 'emailRules') with ordinality as e(r, ord);
    v_n := 0;
    foreach v_detail in array array[
      format('select cma.set_email_rule(%L, null, %L, %L, null, %L, 1)', v_c1, 'subject', array[' ', ''], 'x'),
      format('select cma.set_email_rule(%L, null, %L, %L, null, %L, 1)', v_c1, 'subject', (select array_agg('w' || g) from generate_series(1, 21) g), 'x'),
      format('select cma.set_email_rule(%L, null, %L, %L, null, %L, 1)', v_c1, 'subject', array['a,b'], 'x'),
      format('select cma.set_email_rule(%L, null, %L, %L, null, %L, 1)', v_c1, 'subject', array['a'], 'Bad-Category'),
      format('select cma.set_email_rule(%L, null, %L, %L, null, %L, 1)', v_c1, 'body', array['a'], 'x'),
      format('select cma.set_email_rule_status(%L, %L)', v_r1, 'deleted')] loop
      if pg_temp.v8m_err(v_detail) = 'CMA04' then v_n := v_n + 1; end if;
    end loop;
    foreach v_detail in array array[
      format('select cma.set_email_rule(%L, %L, %L, %L, null, %L, 1)', v_c1, gen_random_uuid(), 'subject', array['a'], 'x'),
      format('select cma.set_email_rule(%L, %L, %L, %L, null, %L, 1)', v_x1, v_r1, 'subject', array['a'], 'x'),
      format('select cma.set_email_rule_status(%L, %L)', gen_random_uuid(), 'active')] loop
      if pg_temp.v8m_err(v_detail) = 'CMA02' then v_n := v_n + 1; end if;
    end loop;
    v_rows := v_rows || array['16', 'B6 rule ordering, an inactive rule, words normalised; nine refusals',
      case when v_txt = 'system_mail billing billing_nl - - | billing | catch_all | {factuur,invoice} {reminder} | catch_all,billing,billing_nl,system_mail'
                and v_n = 9 and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s | %s of 9 refused', v_txt, v_n)];

    -- B7. the contact's privacy deletion clears the contact on its emails and threads and nothing else;
    --     the answer keeps its earlier shape when no email holds the contact
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_threads(v_c1, jsonb_build_array(
      pg_temp.v8m_thread('th-f1', 'open', t0, t0, '{"inboxId": "in-1", "contactId": "c-9"}'::jsonb)));
    perform cma.ingest_upsert_emails(v_c1, jsonb_build_array(
      pg_temp.v8m_email('crm_email', 'e-f1', 'out', t0, '{"contactId": "c-9"}'::jsonb),
      pg_temp.v8m_email('inbox_message', 'm-f1', 'in', t0, '{"threadId": "th-f1", "contactId": "c-9"}'::jsonb)));
    v_res := cma.ingest_contact_forget(v_c1, 'c-9');
    v_res2 := cma.ingest_contact_forget(v_c1, 'c-none');
    select format('%s %s %s', (select count(*) from cma.email_message where connection_id = v_c1 and contact_source_id = 'c-9'),
                  (select count(*) from cma.email_thread where connection_id = v_c1 and contact_source_id = 'c-9'),
                  (select contact_source_id from cma.email_thread where connection_id = v_c1 and source_id = 'th-1')) into v_txt;
    v_rows := v_rows || array['17', 'B7 the contact''s privacy deletion clears it on emails and threads',
      case when v_res = '{"contacts": 0, "refs": 0, "calls": 0, "submissions": 0, "emails": 2, "threads": 1}'::jsonb
                and v_res2 = '{"contacts": 0, "refs": 0, "calls": 0, "submissions": 0}'::jsonb and v_txt = '0 0 c-1'
                and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s %s %s', v_res, v_res2, v_txt)];

    -- B8. a conversation's privacy deletion: the thread and its inbox messages lose contact, ticket and
    --     raw payload and keep ids, times and status; an engagement with the same thread ref is left; a
    --     later read of the thread changes nothing; a later message is stored without contact or raw
    perform cma.ingest_upsert_threads(v_c1, jsonb_build_array(
      pg_temp.v8m_thread('th-f2', 'closed', t0 - interval '2 hours', t0,
                         jsonb_build_object('inboxId', 'in-1', 'contactId', 'c-5', 'ticketId', 't-5', 'closedAt', t0, 'raw', '{"n": 1}'::jsonb))));
    perform cma.ingest_upsert_emails(v_c1, jsonb_build_array(
      pg_temp.v8m_email('inbox_message', 'm-f2a', 'in', t0 - interval '2 hours', '{"threadId": "th-f2", "contactId": "c-5", "raw": {"n": 1}}'::jsonb),
      pg_temp.v8m_email('inbox_message', 'm-f2b', 'out', t0 - interval '1 hour', '{"threadId": "th-f2", "actorKind": "agent", "ownerRef": "own-1"}'::jsonb),
      pg_temp.v8m_email('crm_email', 'e-f2', 'out', t0, '{"threadId": "th-f2", "contactId": "c-5", "raw": {"n": 2}}'::jsonb)));
    v_res := cma.ingest_thread_forget(v_c1, 'th-f2');
    select format('%s:%s:%s:%s:%s:%s', coalesce(contact_source_id, '-'), coalesce(ticket_source_id, '-'), raw, status,
                  to_char(source_created_at at time zone 'UTC', 'HH24:MI'), forgotten_at is not null) into v_txt
    from cma.email_thread where connection_id = v_c1 and source_id = 'th-f2';
    select v_txt || ' ' || string_agg(format('%s:%s:%s:%s', source_id, coalesce(contact_source_id, '-'), raw, actor_kind), ' ' order by source_id)
    into v_txt from cma.email_message where connection_id = v_c1 and source_id in ('m-f2a', 'm-f2b', 'e-f2');
    select v_txt || ' ' || string_agg(o.outcome, ',') into v_txt
    from cma.ingest_upsert_threads(v_c1, jsonb_build_array(
      pg_temp.v8m_thread('th-f2', 'open', t0 - interval '2 hours', t0 + interval '1 hour', '{"contactId": "c-5", "ticketId": "t-5"}'::jsonb))) o;
    perform cma.ingest_upsert_emails(v_c1, jsonb_build_array(
      pg_temp.v8m_email('inbox_message', 'm-f2c', 'in', t0 + interval '1 hour', '{"threadId": "th-f2", "contactId": "c-5", "raw": {"n": 3}}'::jsonb)));
    select v_txt || format(' %s %s %s:%s', (select status from cma.email_thread where connection_id = v_c1 and source_id = 'th-f2'),
                           (select coalesce(contact_source_id, '-') from cma.email_thread where connection_id = v_c1 and source_id = 'th-f2'),
                           coalesce(contact_source_id, '-'), raw) into v_txt
    from cma.email_message where connection_id = v_c1 and source_id = 'm-f2c';
    v_rows := v_rows || array['18', 'B8 a conversation''s privacy deletion keeps ids and times; later reads take nothing back',
      case when v_res = '{"threads": 1, "messages": 1}'::jsonb
                and v_txt = '-:-:{}:closed:08:00:t e-f2:c-5:{"n": 2}:unknown m-f2a:-:{}:unknown m-f2b:-:{}:agent forgotten closed - -:{}'
                and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s %s', v_res, v_txt)];

    -- B9. tenant isolation: tenant two holds the same refs; each tenant reads and writes its own only,
    --     and the owner, without row-level security, sees both
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_ing2::text, true);
    perform cma.ingest_upsert_inboxes(v_c2, '[{"inboxId": "in-1", "name": "Verify inbox of tenant two"}]');
    perform cma.ingest_upsert_threads(v_c2, jsonb_build_array(pg_temp.v8m_thread('th-1', 'open', t0, t0, '{"inboxId": "in-1"}'::jsonb)));
    perform cma.ingest_upsert_emails(v_c2, jsonb_build_array(pg_temp.v8m_email('crm_email', 'e-1', 'out', t0, '{}'::jsonb)));
    perform cma.ingest_upsert_thread_events(v_c2, jsonb_build_array(
      jsonb_build_object('sourceId', 'ev-1', 'threadId', 'th-1', 'kind', 'closed', 'occurredAt', t0)));
    perform set_config('app.user_id', v_admin2::text, true);
    perform cma.set_email_rule(v_c2, null, 'subject', array['invoice'], null, 'billing', 1);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_ing1::text, true);
    v_txt := format('%s %s %s %s %s %s', (select count(*) from cma.email_message where source_id = 'e-1'),
                    (select status from cma.email_message where source_id = 'e-1'),
                    (select count(*) from cma.email_thread where source_id = 'th-1'),
                    (select count(*) from cma.email_thread_event where source_id = 'ev-1'),
                    (select count(*) from cma.connection_inbox where source_inbox_id = 'in-1'),
                    (select count(*) from cma.connection_email_rule where connection_id = v_c2));
    select v_txt || format(' %s', m.code) into v_txt from cma.email_market_of(v_t2, v_c2, 'crm_email', 'e-1') m;
    v_txt := v_txt || ' ' || pg_temp.v8m_err(format('select cma.connection_config(%L)', v_c2))
                   || ' ' || pg_temp.v8m_err(format('select cma.ingest_upsert_emails(%L, %L)', v_c2,
                                                     jsonb_build_array(pg_temp.v8m_email('crm_email', 'e-x', 'out', t0))));
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || format(' | %s %s', (select count(*) from cma.email_message where source_id = 'e-1' and tenant_id in (v_t1, v_t2)),
                             (select count(*) from cma.email_thread where source_id = 'th-1' and tenant_id in (v_t1, v_t2)));
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['19', 'B9 tenant isolation with equal refs, also against the owner''s view',
      case when v_txt = '1 bounced 1 1 1 0 unknown CMA02 CMA02 | 2 2' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B10. the Ingest user cannot configure, a configuring person cannot ingest, an agent can do
    --      neither, a write without an acting user is refused; connection_config for the Ingest user and
    --      a configuring person only
    v_txt := '';
    perform set_config('app.user_id', v_ing1::text, true);
    foreach v_detail in array array[
      format('select cma.set_inbox(%L, %L, true, null, null, null)', v_c1, 'in-1'),
      format('select cma.set_inbox_channel(%L, %L, null, true)', v_c1, 'ch-1'),
      format('select cma.set_email_rule(%L, null, %L, %L, null, %L, 1)', v_c1, 'subject', array['a'], 'x'),
      format('select cma.set_email_rule_status(%L, %L)', v_r1, 'inactive')] loop
      v_txt := v_txt || pg_temp.v8m_err(v_detail) || ' ';
    end loop;
    v_txt := v_txt || '| ';
    perform set_config('app.user_id', v_admin1::text, true);
    foreach v_detail in array array[
      format('select cma.ingest_upsert_inboxes(%L, %L)', v_c1, '[]'),
      format('select cma.ingest_upsert_inbox_channels(%L, %L)', v_c1, '[]'),
      format('select cma.ingest_upsert_emails(%L, %L)', v_c1, '[]'),
      format('select cma.ingest_upsert_threads(%L, %L)', v_c1, '[]'),
      format('select cma.ingest_upsert_thread_events(%L, %L)', v_c1, '[]'),
      format('select cma.ingest_thread_marks(%L, %L)', v_c1, array['th-1']),
      format('select cma.ingest_thread_forget(%L, %L)', v_c1, 'th-1')] loop
      v_txt := v_txt || pg_temp.v8m_err(v_detail) || ' ';
    end loop;
    v_txt := v_txt || '| ';
    perform set_config('app.user_id', v_agent1::text, true);
    v_txt := v_txt || pg_temp.v8m_err(format('select cma.set_inbox(%L, %L, true, null, null, null)', v_c1, 'in-1')) || ' '
                   || pg_temp.v8m_err(format('select cma.ingest_upsert_emails(%L, %L)', v_c1, '[]')) || ' '
                   || pg_temp.v8m_err(format('select cma.connection_config(%L)', v_c1)) || ' | ';
    perform set_config('app.user_id', '', true);
    v_txt := v_txt || pg_temp.v8m_err(format('select cma.ingest_upsert_emails(%L, %L)', v_c1, '[]')) || ' | ';
    perform set_config('app.user_id', v_ing1::text, true);
    v_txt := v_txt || pg_temp.v8m_err(format('select cma.connection_config(%L)', v_c1)) || ' ';
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := v_txt || pg_temp.v8m_err(format('select cma.connection_config(%L)', v_c1));
    v_rows := v_rows || array['20', 'B10 the Ingest user cannot configure, a configuring person cannot ingest; agents and no user refused',
      case when v_txt = 'CMA06 CMA06 CMA06 CMA06 | CMA06 CMA06 CMA06 CMA06 CMA06 CMA06 CMA06 | CMA06 CMA06 CMA06 | CMA01 | ok ok'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B11. nothing personal is stored: the raw payload keeps flat non-personal keys (a subject, a body,
    --      names, addresses, headers, attachments and a phone-like string dropped); an owner ref with an
    --      @, an owner ref for a customer, a contact id with a space, an assignee with an @ and a
    --      thread's owner with an @ refused; a refused batch writes nothing; no stored row of the new
    --      tables holds the invented text
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_emails(v_c1, jsonb_build_array(pg_temp.v8m_email('crm_email', 'e-r1', 'out', t0, jsonb_build_object(
      'actorKind', 'agent', 'ownerRef', 'own-1', 'raw', jsonb_build_object(
        'hs_email_subject', 'Verify subject Hello there', 'hs_email_text', 'Verify body text', 'hs_email_html', '<p>Verify body</p>',
        'hs_email_from_email', 'verify.ann@example.com', 'hs_email_to_email', 'verify.bob@example.com',
        'hs_email_from_firstname', 'Verifyann', 'hs_email_headers', '{"From": "x"}', 'hs_attachment_ids', '1;2',
        'hs_email_status', 'SENT', 'hs_email_direction', 'EMAIL', 'hs_email_thread_id', 'th-x', 'weird', 'verify.carl@example.com',
        'phonelike', '+31 6 1234 5678', 'nested', jsonb_build_object('a', 1), 'n', 3)))));
    select raw into v_res from cma.email_message where connection_id = v_c1 and source_id = 'e-r1';
    select count(*) into v_n from cma.email_message where connection_id = v_c1;
    v_detail := pg_temp.v8m_err(format('select cma.ingest_upsert_emails(%L, %L)', v_c1, jsonb_build_array(
                  pg_temp.v8m_email('crm_email', 'e-r2', 'out', t0, '{"actorKind": "agent", "ownerRef": "own-1"}'::jsonb),
                  pg_temp.v8m_email('crm_email', 'e-r3', 'out', t0, '{"actorKind": "agent", "ownerRef": "E-verify.dan@example.com"}'::jsonb))))
      || ',' || pg_temp.v8m_err(format('select cma.ingest_upsert_emails(%L, %L)', v_c1, jsonb_build_array(
                  pg_temp.v8m_email('inbox_message', 'm-r4', 'in', t0, '{"threadId": "th-1", "actorKind": "customer", "ownerRef": "V-1234"}'::jsonb))))
      || ',' || pg_temp.v8m_err(format('select cma.ingest_upsert_emails(%L, %L)', v_c1, jsonb_build_array(
                  pg_temp.v8m_email('crm_email', 'e-r5', 'in', t0, '{"contactId": "verify eve"}'::jsonb))))
      || ',' || pg_temp.v8m_err(format('select cma.ingest_upsert_thread_events(%L, %L)', v_c1, jsonb_build_array(
                  jsonb_build_object('sourceId', 'ev-r6', 'threadId', 'th-1', 'kind', 'assigned', 'occurredAt', t0,
                                     'toActorKind', 'agent', 'toOwnerRef', 'verify.fay@example.com'))))
      || ',' || pg_temp.v8m_err(format('select cma.ingest_upsert_threads(%L, %L)', v_c1, jsonb_build_array(
                  pg_temp.v8m_thread('th-r7', 'open', t0, t0, '{"ownerRef": "verify.gus@example.com"}'::jsonb))));
    select v_n || ' ' || count(*) into v_txt from cma.email_message where connection_id = v_c1;
    perform set_config('role', 'cma_owner', true);
    select count(*) into v_m
    from (select to_jsonb(x)::text as j from cma.email_message x where tenant_id = v_t1
          union all select to_jsonb(x)::text from cma.email_thread x where tenant_id = v_t1
          union all select to_jsonb(x)::text from cma.email_thread_event x where tenant_id = v_t1
          union all select new_row::text from cma.audit_log where tenant_id = v_t1
                      and table_name in ('email_message', 'email_thread', 'email_thread_event')) r
    where r.j ~* '(verify subject|verify body|example\.com|verifyann|1234 5678)';
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['21', 'B11 nothing personal stored: the raw payload filtered, refs with @ or spaces refused, nothing written',
      case when v_res = '{"n": 3, "hs_email_status": "SENT", "hs_email_direction": "EMAIL", "hs_email_thread_id": "th-x"}'::jsonb
                and v_detail = 'CMA04,CMA04,CMA04,CMA04,CMA04' and split_part(v_txt, ' ', 1) = split_part(v_txt, ' ', 2) and v_m = 0
                and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s | %s | %s | %s rows with the text', v_res, v_detail, v_txt, v_m)];

    -- B12. the connection's kind: a telephony connection takes no email activity and no inbox
    --      configuration; email rows make an unset connection crm, which then cannot become telephony
    v_txt := pg_temp.v8m_err(format('select cma.ingest_upsert_emails(%L, %L)', v_tel1, jsonb_build_array(pg_temp.v8m_email('crm_email', 'e-t1', 'out', t0))));
    v_txt := v_txt || ' ' || cma.connection_held_kinds_of(v_t1, v_x1)::text;
    perform cma.ingest_upsert_inboxes(v_x1, '[{"inboxId": "in-x", "name": "Verify inbox of the other connection"}]');
    v_txt := v_txt || ' ' || cma.connection_held_kinds_of(v_t1, v_x1)::text;
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v8m_err(format('select cma.set_connection_kind(%L, %L)', v_x1, 'telephony'))
                   || ' ' || pg_temp.v8m_err(format('select cma.set_connection_kind(%L, %L)', v_x1, 'crm'))
                   || ' ' || pg_temp.v8m_err(format('select cma.set_inbox(%L, %L, true, null, null, null)', v_tel1, 'in-t'));
    v_rows := v_rows || array['22', 'B12 email activity belongs to a CRM connection; email rows make a connection crm',
      case when v_txt = 'CMA04 {} {crm} CMA03 ok CMA04' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B13. associations of email engagements are stored as the activity's side in either direction; an
    --      email to a call or to another email refused; a call to a deal still taken
    perform set_config('app.user_id', v_ing1::text, true);
    select string_agg(format('%s>%s:%s', from_type, to_type, case when removed_at is null then 'on' else 'off' end), ' ' order by to_type)
    into v_txt from cma.crm_association where connection_id = v_c1 and from_id = 'e-m1';
    v_txt := v_txt || ' ' || pg_temp.v8m_err(format('select cma.ingest_upsert_associations(%L, %L)', v_c1, jsonb_build_array(
               jsonb_build_object('fromType', 'crm_call', 'fromId', 'k-1', 'toType', 'crm_email', 'toId', 'e-m1', 'removed', false, 'changedAt', t0))))
      || ' ' || pg_temp.v8m_err(format('select cma.ingest_upsert_associations(%L, %L)', v_c1, jsonb_build_array(
               jsonb_build_object('fromType', 'crm_email', 'fromId', 'e-m1', 'toType', 'crm_email', 'toId', 'e-m2', 'removed', false, 'changedAt', t0))))
      || ' ' || pg_temp.v8m_err(format('select cma.ingest_upsert_associations(%L, %L)', v_c1, jsonb_build_array(
               jsonb_build_object('fromType', 'deal', 'fromId', 'd-2', 'toType', 'crm_call', 'toId', 'k-1', 'removed', false, 'changedAt', t0))));
    select v_txt || ' ' || count(*) into v_txt from cma.crm_association where connection_id = v_c1 and from_type = 'crm_call' and to_type = 'deal';
    v_rows := v_rows || array['23', 'B13 email engagements'' associations stored as calls'' are; two refusals',
      case when v_txt = 'crm_email>contact:on crm_email>deal:on crm_email>ticket:off CMA04 CMA04 ok 1' and not v_provoke then 'PASS' else 'FAIL' end,
      v_txt];

    -- B14. the configuration the adapter reads: inboxes and source channels with their configuration,
    --      for the Ingest user as for a configuring person
    perform set_config('app.user_id', v_ing1::text, true);
    v_res := cma.connection_config(v_c1);
    select string_agg(format('%s:%s:%s:%s:%s', b ->> 'inboxId', b ->> 'isCounted', coalesce(b ->> 'market', '-'), coalesce(b ->> 'workType', '-'),
                             coalesce(b ->> 'channel', '-')), ' ' order by b ->> 'inboxId') into v_txt
    from jsonb_array_elements(v_res -> 'inboxes') b;
    select v_txt || ' | ' || string_agg(format('%s:%s:%s:%s', c ->> 'channelId', c ->> 'kind', coalesce(c ->> 'channel', '-'), c ->> 'isCounted'), ' '
                                        order by c ->> 'channelId') into v_txt
    from jsonb_array_elements(v_res -> 'inboxChannels') c;
    v_txt := v_txt || ' | ' || jsonb_array_length(v_res -> 'emailRules') || ' '
             || ((v_res ? 'fields') and (v_res ? 'pipelines') and (v_res ? 'settings') and (v_res ? 'store') and (v_res ? 'writeback'))::text;
    v_rows := v_rows || array['24', 'B14 connection_config gives the inboxes, the source channels and the rules',
      case when v_txt = 'in-1:false:NL:verify-sales:phone in-2:true:-:-:email in-3:true:-:-:email | ch-1:email:email:true ch-2:chat:phone:true ch-3:other:-:false | 4 true'
                and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B15. where each thread's stored messages stand: the latest inbox message or event and their
    --      counts; a thread the CMA does not hold gives no row; more than 500 ids refused
    select string_agg(format('%s:%s:%s:%s:%s', thread_source_id, to_char(last_at at time zone 'UTC', 'HH24:MI'), messages, events, is_forgotten),
                      ' ' order by thread_source_id) into v_txt
    from cma.ingest_thread_marks(v_c1, array['th-1', 'th-2', 'th-f2', 'th-none']);
    v_txt := v_txt || ' ' || pg_temp.v8m_err(format('select cma.ingest_thread_marks(%L, %L)', v_c1,
                                                     (select array_agg('th-' || g) from generate_series(1, 501) g)));
    v_rows := v_rows || array['25', 'B15 where each thread''s messages stand',
      case when v_txt = 'th-1:10:50:1:4:f th-2:10:00:1:0:f th-f2:11:00:3:0:t CMA04' and not v_provoke then 'PASS' else 'FAIL' end,
      v_txt];

    -- B16. the email poll's runs: a run with the job email_poll started and finished; another job refused
    v_run := cma.ingest_sync_run_start(v_c1, 'email_poll', 'email:threads', t0, t0 + interval '1 minute');
    perform cma.ingest_sync_run_finish(v_run, 'succeeded', '{"fetched": 3, "upserted": 2, "stale": 1}'::jsonb);
    select format('%s %s %s', job, status, counts) into v_txt from cma.sync_run where id = v_run;
    v_txt := v_txt || ' ' || pg_temp.v8m_err(format('select cma.ingest_sync_run_start(%L, %L, null, null, null)', v_c1, 'email_everything'));
    v_rows := v_rows || array['26', 'B16 the email poll''s runs (job email_poll)',
      case when v_txt = 'email_poll succeeded {"stale": 1, "fetched": 3, "upserted": 2} CMA04' and not v_provoke then 'PASS' else 'FAIL' end,
      v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['39', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008m (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008m values (39, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008m
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED: not dev'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008m where result = 'PASS') = 22
                       and not exists (select 1 from verify_0008m where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0008m where result = 'PASS'),
                                        (select count(*) from verify_0008m where result <> 'PASS'))) x
order by ord;
drop function if exists pg_temp.v8m_err(text), pg_temp.v8m_email(text, text, text, timestamptz, jsonb),
                        pg_temp.v8m_thread(text, text, timestamptz, timestamptz, jsonb);
reset role;
