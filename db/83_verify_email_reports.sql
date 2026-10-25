-- =============================================================================================
-- 83_verify_email_reports.sql: verifies addition 0008t, email reports (B17c)
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure
-- and privileges; block B works on three throwaway tenants inside a subtransaction that is always
-- rolled back. Universal otherwise: nothing of the seed is used; adapters, inboxes, mailboxes,
-- channels, threads, emails, owners, contacts and deals are invented data values, and no row carries a
-- subject, a body, a name or an address the database keeps (a mailbox name with an @ is offered once,
-- to prove it is never stored). Every check writes one row, PASS or FAIL, and the last result lists
-- them with the verdict, because Cloud SQL Studio shows no notices. Run as your own IAM login in dev,
-- after 82_email_reports.sql; then 69, 73, 75 and 81 again.
--   A  structure and privileges: the addition row after 0008s; the mailbox table with row-level
--      security, the tenant policy, audit, no delete and its reader view with its exact columns; the
--      new columns with their checks and at the end of 0008m's views; no column named like a subject,
--      a body, an address, a sender or a recipient in the new table and views; the setting; every
--      function the application's only and in the caller's rights, the readers' two functions
--      definer, the owner's, pinned and the readers' only
--   B  behaviour. Tenant one (Europe/Amsterdam; NL in Amsterdam, GB in London; office hours Monday to
--      Friday 09:00 to 17:00) holds a CRM connection with three inboxes (Support NL, Sales without a
--      market, Internal not counted), two channels (email; chat, not counted) and three mailboxes
--      (Support NL; one named like an address, labelled Support GB with market GB; Old box, not
--      counted), and the week of 5 to 11 October 2026 with the week before: ten conversations (a
--      created, closed, reopened and closed again one; a reply over a weekend; a GB mailbox reply past
--      the target; an unknown market; spam; an uncounted inbox, channel and mailbox; a reopen at
--      creation; a reopen after a close made before the period) and engagements (an agent send, an
--      automation, an inbox copy each way, a bounce, a logged reply, an unlinked owner, no owner, a
--      deletion, an email near midnight in two zones). Tenant two holds a connection with the same
--      names, for isolation. Tenant three holds lead deals for not responding. Checked: the setting
--      and its refusals; the mailbox catalog, its label, counted and market surviving a refresh, an
--      address never stored, the configuration's refusals; account refs and origins kept by a later
--      read; sent, automated, bounced and failed, and the inbox copies left out; received and logged
--      replies apart, spam and uncounted inboxes, mailboxes and channels left out; openings, the reopen
--      at creation ignored, closes; the first reply in and out of business hours, an unknown market,
--      the target, a bot and a failed message not a reply, the reopen's incoming message before the
--      reopen event; time to close; the market through the mailbox and the inbox; dates and weeks in
--      the market's zone; per person with the not-linked row, never an owner id, by name, sends per
--      hour; per person refused while reports.per_person does not hold email; the previous period
--      like for like; the filters and their refusals; the figures per dimension and the received
--      series; the history start; waiting now; not responding with a connected and a short call; the
--      permissions; tenant isolation; a reader scoped to one tenant
-- Amended for addition 0008zc (24 October 2026; 83 runs in dev only): 0008zc gives a CRM call's conversation its term's
-- name (docs/definitions.md, convention 1): cma.crm_call_conversation_of in place of cma.crm_call_connected_of, which it
-- drops, and cma.email_not_responding_of reads it. A6 names the function the database holds: the new one once 0008zc
-- is recorded, the old one before it. Every other check pins what it pinned before (not responding counts a
-- conversation through the CRM call's linked telephony call, which its fixture's calls already are or are not).
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
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 83 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0008t;
create temp table verify_0008t (ord int, check_name text, result text, detail text);

-- The error code a statement raises, or 'ok'
create or replace function pg_temp.v0008t_code(p_sql text)
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

-- One email as the ingest write takes it
create or replace function pg_temp.v0008t_mail(p_kind text, p_src text, p_dir text, p_status text, p_at timestamptz, p_actor text,
                                               p_owner text, p_extra jsonb default '{}'::jsonb)
returns jsonb
language sql immutable
as $$
  select jsonb_strip_nulls(jsonb_build_object('sourceKind', p_kind, 'sourceId', p_src, 'direction', p_dir, 'status', p_status,
                                              'occurredAt', p_at, 'actorKind', p_actor, 'ownerRef', p_owner, 'createdAt', p_at,
                                              'updatedAt', p_at)) || p_extra
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
  -- A1. the addition is recorded, after 0008s
  insert into verify_0008t values (1, 'A1 addition 0008t recorded, after 0008s',
    case when exists (select 1 from cma.schema_migration where version = '0008t')
              and exists (select 1 from cma.schema_migration where version = '0008s') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the mailbox table: row-level security, the tenant policy, audit, never deleted by the
  --     application; its reader view with its exact columns, readers seeing the view and never the table
  v_bad := '';
  if to_regclass('cma.connection_inbox_account') is null then
    v_bad := 'cma.connection_inbox_account missing; ';
  else
    if not (select relrowsecurity from pg_class where oid = to_regclass('cma.connection_inbox_account'))
       or not exists (select 1 from pg_policy where polrelid = to_regclass('cma.connection_inbox_account') and polname = 'tenant_app')
       or not exists (select 1 from pg_trigger where tgrelid = to_regclass('cma.connection_inbox_account') and tgname = 'audit') then
      v_bad := v_bad || 'no row-level security, policy or audit; ';
    end if;
    if has_table_privilege('cma_app', 'cma.connection_inbox_account', 'delete')
       or not has_table_privilege('cma_app', 'cma.connection_inbox_account', 'insert') then
      v_bad := v_bad || 'the application deletes from or cannot insert into it; ';
    end if;
    if not has_table_privilege('cma_readonly', 'cma_read.connection_inbox_account', 'select')
       or has_table_privilege('cma_readonly', 'cma.connection_inbox_account', 'select') then
      v_bad := v_bad || 'readers do not see cma_read.connection_inbox_account alone; ';
    end if;
  end if;
  if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'connection_inbox_account')
     is distinct from 'tenant_id,connection_id,source_account_id,name,label,inbox_source_id,channel_source_id,is_counted,market,status,refreshed_at,updated_at' then
    v_bad := v_bad || 'cma_read.connection_inbox_account columns; ';
  end if;
  insert into verify_0008t values (2, 'A2 the mailbox table with row-level security, audit, no delete and its reader view',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A3. the new columns with their checks (a ref refuses an @ and white space, the origin is a code) and
  --     at the end of 0008m's views; the two reader views of ids and ages
  v_bad := '';
  if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'email_message')
     !~ ',synced_at,account_ref,origin$' then
    v_bad := v_bad || 'cma_read.email_message does not end with account_ref, origin; ';
  end if;
  if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'email_thread')
     !~ ',synced_at,account_ref$' then
    v_bad := v_bad || 'cma_read.email_thread does not end with account_ref; ';
  end if;
  if not exists (select 1 from pg_constraint where conname = 'email_message_account_ref_check' and pg_get_constraintdef(oid) like '%@%')
     or not exists (select 1 from pg_constraint where conname = 'email_thread_account_ref_check' and pg_get_constraintdef(oid) like '%@%')
     or not exists (select 1 from pg_constraint where conname = 'email_message_origin_check' and pg_get_constraintdef(oid) like '%A-Za-z0-9_.:-%') then
    v_bad := v_bad || 'a check is missing; ';
  end if;
  if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'email_waiting')
     is distinct from 'tenant_id,connection_id,thread_source_id,inbox_key,account_key,market,waiting_since,waited_seconds,waited_business_seconds'
     or (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
         where table_schema = 'cma_read' and table_name = 'email_not_responding')
     is distinct from 'tenant_id,connection_id,deal_source_id,market,last_email_at,days_since' then
    v_bad := v_bad || 'the reader views email_waiting or email_not_responding; ';
  end if;
  insert into verify_0008t values (3, 'A3 account refs and origin with their checks, at the end of the views; the two reader views',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A4. no column named like content or a person's address in the new table and views, and no read
  --     returning one
  select string_agg(table_schema || '.' || table_name || '.' || column_name, ', ') into v_bad
  from information_schema.columns
  where table_schema in ('cma', 'cma_read')
    and table_name in ('connection_inbox_account', 'email_waiting', 'email_not_responding')
    and column_name ~* '(subject|body|text|html|header|attach|email_address|^email$|address|sender|recipient|phone|contact)';
  select coalesce(v_bad || ', ', '') || coalesce(string_agg(p.proname || '.' || a, ', '), '') into v_bad
  from pg_proc p
  cross join lateral unnest(p.proargnames) a
  where p.pronamespace = 'cma'::regnamespace and p.proname like 'email\_%' and p.proname not in ('email_market_of', 'email_category_of',
        'email_raw', 'email_words', 'email_words_ok', 'email_words_match', 'email_start_date_of')
    and a ~* '(subject|body|html|header|attach|address|sender|recipient|phone|contact)';
  insert into verify_0008t values (4, 'A4 no subject, body, address, sender, recipient or contact column in the new table, views and reads',
    case when coalesce(v_bad, '') = '' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_bad, ''));

  -- A5. the setting: text, empty by default
  select string_agg(key || '=' || value_type || ':' || default_value, ' ') into v_bad from cma.setting where key = 'reports.per_person';
  insert into verify_0008t values (5, 'A5 the setting reports.per_person, text, empty by default',
    case when v_bad = 'reports.per_person=text:' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_bad, 'missing'));

  -- A6. every function of the addition the application's only and in the caller's rights; the readers'
  --     two functions SECURITY DEFINER, owned by cma_owner, search path pinned, the readers' only
  v_bad := '';
  foreach v_fn in array array[
    'cma.ingest_upsert_inbox_accounts(uuid,jsonb)', 'cma.ingest_upsert_threads(uuid,jsonb)', 'cma.ingest_upsert_emails(uuid,jsonb)',
    'cma.set_inbox_account(uuid,text,text,boolean,text)', 'cma.connection_config(uuid)', 'cma.email_market_of(uuid,uuid,text,text)',
    'cma.email_of(uuid,timestamptz,timestamptz)', 'cma.email_threads_counted_of(uuid,uuid[])',
    'cma.email_openings_of(uuid,timestamptz,timestamptz)', 'cma.email_closes_of(uuid,timestamptz,timestamptz)',
    'cma.email_figures_of(uuid,date,date,text,text,text,text[],timestamptz)',
    'cma.email_overview_of(uuid,date,date,text,text,text,text,timestamptz)', 'cma.email_by_dimension_of(uuid,date,date,text,text,text)',
    'cma.email_received_series_of(uuid,date,date,text,text,text,text,text)', 'cma.email_per_person_of(uuid,date,date,text,text,text)',
    'cma.email_waiting_of(uuid,timestamptz)', 'cma.email_not_responding_of(uuid,timestamptz)', 'cma.email_history_start_of(uuid)',
    'cma.email_overview(date,date,text,text,text,text)', 'cma.email_by_dimension(date,date,text,text,text)',
    'cma.email_received_series(date,date,text,text,text,text,text)', 'cma.email_per_person(date,date,text,text,text)',
    'cma.email_waiting(text,text,text,integer)', 'cma.email_not_responding(text,integer)', 'cma.email_history_start()',
    'cma.email_filters_check(text,text,text)', 'cma.per_person_on(uuid,text)', 'cma.assert_per_person(text)',
    'cma.is_per_person_list(text)', 'cma.setting_codes(jsonb,text)',
    case when exists (select 1 from cma.schema_migration m where m.version = '0008zc') then 'cma.crm_call_conversation_of(uuid,uuid)'
         else 'cma.crm_call_connected_of(uuid,uuid)' end] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or has_function_privilege('public', v_fn, 'execute')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      v_bad := v_bad || v_fn || ' not the application''s only or not in the caller''s rights; ';
    end if;
  end loop;
  foreach v_fn in array array['cma_read.email_waiting_rows()', 'cma_read.email_not_responding_rows()'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' missing; ';
    elsif not (select prosecdef from pg_proc where oid = to_regprocedure(v_fn))
          or (select pg_get_userbyid(proowner) from pg_proc where oid = to_regprocedure(v_fn)) <> 'cma_owner'
          or not coalesce((select array_to_string(proconfig, ',') from pg_proc where oid = to_regprocedure(v_fn)) like 'search_path=%pg_temp', false)
          or not has_function_privilege('cma_readonly', v_fn, 'execute') or has_function_privilege('cma_app', v_fn, 'execute')
          or has_function_privilege('public', v_fn, 'execute') then
      v_bad := v_bad || v_fn || ' not the readers'' pinned definer function; ';
    end if;
  end loop;
  insert into verify_0008t values (6, 'A6 every function the application''s only and invoker; the readers'' two definer, pinned, theirs only',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);
end
$$;

-- B. Behaviour on three throwaway tenants (rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_rows     text[] := '{}';
  v_t1 uuid; v_t2 uuid; v_t3 uuid;
  v_admin1 uuid; v_analyst1 uuid; v_reader1 uuid; v_super1 uuid; v_agent1 uuid; v_anna uuid; v_bram uuid; v_ing1 uuid;
  v_admin2 uuid; v_analyst2 uuid; v_ing2 uuid;
  v_admin3 uuid; v_analyst3 uuid; v_ing3 uuid; v_owner3 uuid;
  v_crm uuid; v_crm2 uuid; v_crm3 uuid; v_tel3 uuid;
  v_role uuid;
  v_txt text; v_txt2 text; v_detail text;
  v_n integer;
  v_j jsonb;
  -- the week of Monday 5 October 2026 (CEST, UTC+2; BST, UTC+1)
  v_after   timestamptz := timestamptz '2026-10-20 09:00:00+00';   -- the period has ended
  v_running timestamptz := timestamptz '2026-10-07 14:30:00+00';   -- Wednesday 7 October, 16:30 in Amsterdam
  v_before  timestamptz := timestamptz '2026-10-01 09:00:00+00';   -- before the period starts
  v_now     timestamptz := timestamptz '2026-10-12 10:00:00+00';   -- Monday 12 October, 12:00 in Amsterdam
  ib text := '{"inboxId": "ib1", "channelId": "ch1"}';
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    v_t1 := cma.create_tenant('verify-0008t-one', 'Verify 0008t one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008t-two', 'Verify 0008t two', 'Europe/Amsterdam');
    v_t3 := cma.create_tenant('verify-0008t-three', 'Verify 0008t three', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-analyst1@example.invalid', 'analyst1') returning id into v_analyst1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-reader1@example.invalid', 'reader1') returning id into v_reader1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-super1@example.invalid', 'super1') returning id into v_super1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent1@example.invalid', 'agent1') returning id into v_agent1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-anna@example.invalid', 'Anna Verify') returning id into v_anna;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-bram@example.invalid', 'Bram Verify') returning id into v_bram;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin2') returning id into v_admin2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-analyst2@example.invalid', 'analyst2') returning id into v_analyst2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t3, 'verify-admin3@example.invalid', 'admin3') returning id into v_admin3;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t3, 'verify-analyst3@example.invalid', 'analyst3') returning id into v_analyst3;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t3, 'verify-owner3@example.invalid', 'Owner three') returning id into v_owner3;
    -- a role with reports.view only (no default role has it without performance.team)
    insert into cma.app_role (tenant_id, key, name) values (v_t1, 'verify_reader', 'Verify reader') returning id into v_role;
    insert into cma.role_permission (tenant_id, role_id, permission_key) values (v_t1, v_role, 'reports.view');
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_analyst1, 'analytics'), (v_t1, v_reader1, 'verify_reader'), (v_t1, v_super1, 'supervisor'),
                 (v_t1, v_agent1, 'agent'), (v_t1, v_anna, 'agent'), (v_t1, v_bram, 'agent'),
                 (v_t2, v_admin2, 'admin'), (v_t2, v_analyst2, 'analytics'),
                 (v_t3, v_admin3, 'admin'), (v_t3, v_analyst3, 'analytics'), (v_t3, v_owner3, 'agent')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    select x.user_id into v_ing2 from cma.app_user_external_id x where x.tenant_id = v_t2 and x.system = 'ingest';
    select x.user_id into v_ing3 from cma.app_user_external_id x where x.tenant_id = v_t3 and x.system = 'ingest';
    perform set_config('role', 'cma_app', true);

    -- tenant one's configuration (the admin): markets, office hours Monday to Friday 09:00 to 17:00, the
    -- intake start, the owners (101 Anna, 103 Bram; 102 nobody), a CRM connection whose settings name the
    -- inbox-copy and automated origins and the thread and deal links
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP');
    perform cma.set_business_hours('*', d::smallint, '09:00-17:00') from generate_series(1, 5) d;
    perform cma.set_tenant_setting('intake.start_date', '2026-09-01');
    perform cma.set_user_external_id(v_anna, 'verifycrm_owner', '101');
    perform cma.set_user_external_id(v_bram, 'verifycrm_owner', '103');
    select c.connection_id into v_crm from cma.upsert_connection('verifycrm', 'Verify email one', 'portal-1', null, null) c;
    perform cma.set_connection_kind(v_crm, 'crm');
    perform cma.set_connection_settings(v_crm, jsonb_build_object(
      'email_inbox_copy_origins', 'CONVERSATIONS', 'email_automated_origins', 'Automation_Platform, BATCH',
      'record_url_thread', 'https://crm.example.invalid/{account}/thread/{id}', 'record_url_deal', 'https://crm.example.invalid/{account}/deal/{id}'));

    -- B1. the setting: off by default; email, orders and both in either order; five refusals. Each read
    --     a statement of its own: in one expression with the write the read would not see it
    v_txt := cma.per_person_on(v_t1, 'email')::text;
    v_txt := v_txt || ' ' || pg_temp.v0008t_code('select cma.set_tenant_setting(''reports.per_person'', ''email'')');
    v_txt := v_txt || ' ' || cma.per_person_on(v_t1, 'email')::text || '/' || cma.per_person_on(v_t1, 'orders')::text;
    v_txt := v_txt || ' ' || pg_temp.v0008t_code('select cma.set_tenant_setting(''reports.per_person'', ''orders,email'')');
    v_txt := v_txt || ' ' || cma.per_person_on(v_t1, 'email')::text || '/' || cma.per_person_on(v_t1, 'orders')::text;
    v_txt := v_txt || ' ' || pg_temp.v0008t_code('select cma.set_tenant_setting(''reports.per_person'', ''Email'')')
      || ' ' || pg_temp.v0008t_code('select cma.set_tenant_setting(''reports.per_person'', ''email,email'')')
      || ' ' || pg_temp.v0008t_code('select cma.set_tenant_setting(''reports.per_person'', ''email, orders'')')
      || ' ' || pg_temp.v0008t_code('select cma.set_tenant_setting(''reports.per_person'', ''calls'')')
      || ' ' || pg_temp.v0008t_code('select cma.set_tenant_setting(''reports.per_person'', ''email,orders,email'')');
    v_txt := v_txt || ' ' || pg_temp.v0008t_code('select cma.set_tenant_setting(''reports.per_person'', '''')');
    v_txt := v_txt || ' ' || cma.per_person_on(v_t1, 'email')::text;
    v_rows := v_rows || array['11', 'B1 reports.per_person: off by default, email and orders, five refusals',
      case when v_txt = 'false ok true/false ok true/true CMA04 CMA04 CMA04 CMA04 CMA04 ok false' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- the catalogs (the Ingest user): three inboxes, two channels, four mailboxes
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_inboxes(v_crm, '[{"inboxId": "ib1", "name": "Support"}, {"inboxId": "ib2", "name": "Sales"}, {"inboxId": "ib3", "name": "Internal"}]');
    perform cma.ingest_upsert_inbox_channels(v_crm, '[{"channelId": "ch1", "name": "Email", "kind": "email"}, {"channelId": "ch2", "name": "Chat", "kind": "chat"}]');
    v_n := cma.ingest_upsert_inbox_accounts(v_crm, '[
      {"accountId": "ac1", "name": "Support NL", "inboxId": "ib1", "channelId": "ch1"},
      {"accountId": "ac2", "name": "support-gb@example.invalid", "inboxId": "ib1", "channelId": "ch1"},
      {"accountId": "ac3", "name": "Old box", "inboxId": "ib1", "channelId": "ch1"},
      {"accountId": "ac9", "name": "Gone", "inboxId": "ib2", "channelId": "ch1"}]');
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_inbox(v_crm, 'ib1', true, 'NL', null, null);
    perform cma.set_inbox(v_crm, 'ib3', false, null, null, null);
    perform cma.set_inbox_account(v_crm, 'ac2', 'Support GB', true, 'GB');
    perform cma.set_inbox_account(v_crm, 'ac3', null, false, null);
    perform cma.set_inbox_account(v_crm, 'ac7', 'Not seen yet', true, null);

    -- B2. the mailbox catalog: an address-like name stored as the id; a second refresh renames, archives
    --     a mailbox missing from it, and keeps the label, counted and market; an account not yet seen
    --     added with its id as name; the configuration's refusals; no @ anywhere, nor in the audit
    perform set_config('app.user_id', v_ing1::text, true);
    v_txt := v_n::text || ' ' || cma.ingest_upsert_inbox_accounts(v_crm, '[
      {"accountId": "ac1", "name": "Support NL mailbox", "inboxId": "ib1", "channelId": "ch1"},
      {"accountId": "ac2", "name": "support-gb2@example.invalid", "inboxId": "ib1", "channelId": "ch1"},
      {"accountId": "ac3", "name": "Old box", "inboxId": "ib1", "channelId": "ch1"}]')::text;
    perform set_config('role', 'cma_owner', true);
    select string_agg(format('%s:%s/%s/%s/%s/%s', a.source_account_id, a.name, coalesce(a.label, '-'), a.is_counted, coalesce(a.market, '-'), a.status), ' '
                      order by a.source_account_id) into v_txt2
    from cma.connection_inbox_account a where a.tenant_id = v_t1;
    v_txt := v_txt || ' | ' || v_txt2 || ' | at-signs '
      || ((select count(*) from cma.connection_inbox_account a where a.tenant_id = v_t1 and (strpos(a.name, '@') > 0 or strpos(coalesce(a.label, ''), '@') > 0))
          + (select count(*) from cma.audit_log l where l.tenant_id = v_t1 and l.table_name = 'connection_inbox_account'
               and (strpos(coalesce(l.old_row::text, ''), 'example.invalid') > 0 or strpos(coalesce(l.new_row::text, ''), 'example.invalid') > 0)))::text;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := v_txt || ' | ' || pg_temp.v0008t_code(format('select cma.set_inbox_account(%L, ''ac1'', ''a@b'', true, null)', v_crm))
      || ' ' || pg_temp.v0008t_code(format('select cma.set_inbox_account(%L, ''ac1'', %L, true, null)', v_crm, repeat('x', 81)))
      || ' ' || pg_temp.v0008t_code(format('select cma.set_inbox_account(%L, ''ac1'', null, true, ''XX'')', v_crm))
      || ' ' || pg_temp.v0008t_code(format('select cma.set_inbox_account(%L, ''ac1'', null, null, null)', v_crm))
      || ' ' || pg_temp.v0008t_code(format('select cma.set_inbox_account(%L, ''a c'', null, true, null)', v_crm));
    perform set_config('app.user_id', v_ing1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008t_code(format('select cma.set_inbox_account(%L, ''ac1'', null, true, null)', v_crm))
      || ' ' || pg_temp.v0008t_code(format('select cma.ingest_upsert_inbox_accounts(%L, ''[{"name": "no id"}]'')', v_crm));
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008t_code(format('select cma.ingest_upsert_inbox_accounts(%L, ''[]'')', v_crm));
    v_rows := v_rows || array['12', 'B2 mailboxes: no address stored, label, counted and market kept, archived, refusals',
      case when v_txt = '4 3 | ac1:Support NL mailbox/-/t/-/active ac2:ac2/Support GB/t/GB/active ac3:Old box/-/f/-/active ac7:ac7/Not seen yet/t/-/archived ac9:Gone/-/t/-/archived | at-signs 0 | CMA04 CMA04 CMA02 CMA04 CMA04 CMA06 CMA04 CMA06'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- tenant one's conversations, emails and contacts (the Ingest user). Times in UTC; Amsterdam is
    -- UTC+2, London UTC+1. Contacts: k-nl (NL), k-gb (GB), written after the emails (a contact is held
    -- while something points to it)
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_threads(v_crm, jsonb_build_array(
      -- th-a: created Monday 10:00, closed 11:00, reopened Tuesday 10:00 after a message at 09:59:59 (and a
      -- second reopen event at 10:10, no opening), closed 11:00
      jsonb_build_object('sourceId', 'th-a', 'inboxId', 'ib1', 'channelId', 'ch1', 'accountId', 'ac1', 'status', 'closed', 'contactId', 'k-nl',
                         'category', 'billing', 'createdAt', '2026-10-05T08:00:00Z', 'closedAt', '2026-10-06T09:00:00Z', 'updatedAt', '2026-10-06T09:00:00Z'),
      -- th-b: created Friday 16:50, a bot and a failed agent message, the reply on Monday 12 October 09:20
      jsonb_build_object('sourceId', 'th-b', 'inboxId', 'ib1', 'channelId', 'ch1', 'accountId', 'ac1', 'status', 'open', 'contactId', 'k-nl',
                         'createdAt', '2026-10-09T14:50:00Z', 'updatedAt', '2026-10-12T07:20:00Z'),
      -- th-c: on the GB mailbox, no contact; the reply five hours later
      jsonb_build_object('sourceId', 'th-c', 'inboxId', 'ib1', 'channelId', 'ch1', 'accountId', 'ac2', 'status', 'open',
                         'createdAt', '2026-10-07T10:00:00Z', 'updatedAt', '2026-10-07T15:00:00Z'),
      -- th-d: Sales (no market), no contact: an unknown market; an incoming message after the reply
      jsonb_build_object('sourceId', 'th-d', 'inboxId', 'ib2', 'channelId', 'ch1', 'status', 'open',
                         'createdAt', '2026-10-08T09:00:00Z', 'updatedAt', '2026-10-08T10:00:00Z'),
      -- th-e spam; th-f the uncounted inbox; th-g the uncounted chat channel; th-h the uncounted mailbox
      jsonb_build_object('sourceId', 'th-e', 'inboxId', 'ib1', 'channelId', 'ch1', 'accountId', 'ac1', 'status', 'open', 'isSpam', true,
                         'createdAt', '2026-10-06T09:00:00Z', 'updatedAt', '2026-10-06T09:00:00Z'),
      jsonb_build_object('sourceId', 'th-f', 'inboxId', 'ib3', 'channelId', 'ch1', 'status', 'open',
                         'createdAt', '2026-10-06T10:00:00Z', 'updatedAt', '2026-10-06T10:00:00Z'),
      jsonb_build_object('sourceId', 'th-g', 'inboxId', 'ib1', 'channelId', 'ch2', 'status', 'open',
                         'createdAt', '2026-10-06T11:00:00Z', 'updatedAt', '2026-10-06T11:00:00Z'),
      jsonb_build_object('sourceId', 'th-h', 'inboxId', 'ib1', 'channelId', 'ch1', 'accountId', 'ac3', 'status', 'open',
                         'createdAt', '2026-10-06T12:00:00Z', 'updatedAt', '2026-10-06T12:00:00Z'),
      -- th-i: a reopen at its creation and another without a close; no reply; no contact, no mailbox (the inbox's NL);
      -- a second incoming message on Monday 12 October, after the period
      jsonb_build_object('sourceId', 'th-i', 'inboxId', 'ib1', 'channelId', 'ch1', 'status', 'open',
                         'createdAt', '2026-10-07T08:00:00Z', 'updatedAt', '2026-10-07T09:00:00Z'),
      -- th-j: created and closed on Friday 2 October, reopened Monday 08:00 and closed 09:00 by the system
      jsonb_build_object('sourceId', 'th-j', 'inboxId', 'ib1', 'channelId', 'ch1', 'accountId', 'ac1', 'status', 'closed', 'contactId', 'k-nl',
                         'createdAt', '2026-10-02T08:00:00Z', 'closedAt', '2026-10-05T07:00:00Z', 'updatedAt', '2026-10-05T07:00:00Z'),
      -- th-y: the week before, on the NL inbox with a GB contact: the market order decides
      jsonb_build_object('sourceId', 'th-y', 'inboxId', 'ib1', 'channelId', 'ch1', 'status', 'closed', 'contactId', 'k-gb',
                         'createdAt', '2026-10-02T10:00:00Z', 'closedAt', '2026-10-02T11:00:00Z', 'updatedAt', '2026-10-02T11:00:00Z'),
      -- th-k: an uncounted inbox's conversation on 25 September (before the history starts)
      jsonb_build_object('sourceId', 'th-k', 'inboxId', 'ib3', 'channelId', 'ch1', 'status', 'closed',
                         'createdAt', '2026-09-25T08:00:00Z', 'closedAt', '2026-09-25T09:00:00Z', 'updatedAt', '2026-09-25T09:00:00Z')));
    perform cma.ingest_upsert_emails(v_crm, jsonb_build_array(
      pg_temp.v0008t_mail('inbox_message', 'm-a1', 'in', 'other', '2026-10-05T08:00:00Z', 'customer', null, jsonb_build_object('threadId', 'th-a', 'accountId', 'ac1', 'contactId', 'k-nl') || ib::jsonb),
      pg_temp.v0008t_mail('inbox_message', 'm-a2', 'out', 'sent', '2026-10-05T08:30:00Z', 'agent', '101', jsonb_build_object('threadId', 'th-a', 'accountId', 'ac1', 'contactId', 'k-nl') || ib::jsonb),
      pg_temp.v0008t_mail('inbox_message', 'm-a3', 'in', 'other', '2026-10-06T07:59:59Z', 'customer', null, jsonb_build_object('threadId', 'th-a', 'accountId', 'ac1', 'contactId', 'k-nl') || ib::jsonb),
      pg_temp.v0008t_mail('inbox_message', 'm-a4', 'out', 'sent', '2026-10-06T08:20:00Z', 'agent', '102', jsonb_build_object('threadId', 'th-a', 'accountId', 'ac1', 'contactId', 'k-nl') || ib::jsonb),
      pg_temp.v0008t_mail('inbox_message', 'm-b1', 'in', 'other', '2026-10-09T14:50:00Z', 'customer', null, jsonb_build_object('threadId', 'th-b', 'accountId', 'ac1', 'contactId', 'k-nl') || ib::jsonb),
      pg_temp.v0008t_mail('inbox_message', 'm-b2', 'out', 'sent', '2026-10-09T14:51:00Z', 'bot', null, jsonb_build_object('threadId', 'th-b', 'accountId', 'ac1', 'contactId', 'k-nl') || ib::jsonb),
      pg_temp.v0008t_mail('inbox_message', 'm-b3', 'out', 'failed', '2026-10-09T15:00:00Z', 'agent', '101', jsonb_build_object('threadId', 'th-b', 'accountId', 'ac1', 'contactId', 'k-nl') || ib::jsonb),
      pg_temp.v0008t_mail('inbox_message', 'm-b4', 'out', 'sent', '2026-10-12T07:20:00Z', 'agent', '101', jsonb_build_object('threadId', 'th-b', 'accountId', 'ac1', 'contactId', 'k-nl') || ib::jsonb),
      pg_temp.v0008t_mail('inbox_message', 'm-c1', 'in', 'other', '2026-10-07T10:00:00Z', 'customer', null, jsonb_build_object('threadId', 'th-c', 'accountId', 'ac2') || ib::jsonb),
      pg_temp.v0008t_mail('inbox_message', 'm-c2', 'out', 'sent', '2026-10-07T15:00:00Z', 'agent', '101', jsonb_build_object('threadId', 'th-c', 'accountId', 'ac2') || ib::jsonb),
      pg_temp.v0008t_mail('inbox_message', 'm-d1', 'in', 'other', '2026-10-08T09:00:00Z', 'customer', null, '{"threadId": "th-d", "inboxId": "ib2", "channelId": "ch1"}'),
      pg_temp.v0008t_mail('inbox_message', 'm-d2', 'out', 'sent', '2026-10-08T09:10:00Z', 'agent', '103', '{"threadId": "th-d", "inboxId": "ib2", "channelId": "ch1"}'),
      pg_temp.v0008t_mail('inbox_message', 'm-d3', 'forwarded', 'other', '2026-10-08T10:00:00Z', 'customer', null, '{"threadId": "th-d", "inboxId": "ib2", "channelId": "ch1"}'),
      pg_temp.v0008t_mail('inbox_message', 'm-e1', 'in', 'other', '2026-10-06T09:00:00Z', 'customer', null, jsonb_build_object('threadId', 'th-e', 'accountId', 'ac1') || ib::jsonb),
      pg_temp.v0008t_mail('inbox_message', 'm-f1', 'in', 'other', '2026-10-06T10:00:00Z', 'customer', null, '{"threadId": "th-f", "inboxId": "ib3", "channelId": "ch1"}'),
      pg_temp.v0008t_mail('inbox_message', 'm-g1', 'in', 'other', '2026-10-06T11:00:00Z', 'customer', null, '{"threadId": "th-g", "inboxId": "ib1", "channelId": "ch2"}'),
      pg_temp.v0008t_mail('inbox_message', 'm-h1', 'in', 'other', '2026-10-06T12:00:00Z', 'customer', null, jsonb_build_object('threadId', 'th-h', 'accountId', 'ac3') || ib::jsonb),
      pg_temp.v0008t_mail('inbox_message', 'm-i1', 'in', 'other', '2026-10-07T08:00:00Z', 'customer', null, '{"threadId": "th-i"}'::jsonb || ib::jsonb),
      pg_temp.v0008t_mail('inbox_message', 'm-i2', 'in', 'other', '2026-10-12T08:00:00Z', 'customer', null, '{"threadId": "th-i"}'::jsonb || ib::jsonb),
      pg_temp.v0008t_mail('inbox_message', 'm-k1', 'in', 'other', '2026-09-25T08:00:00Z', 'customer', null, '{"threadId": "th-k", "inboxId": "ib3", "channelId": "ch1"}'),
      pg_temp.v0008t_mail('inbox_message', 'm-y1', 'in', 'other', '2026-10-02T10:00:00Z', 'customer', null, '{"threadId": "th-y", "contactId": "k-gb"}'::jsonb || ib::jsonb),
      -- th-j's first message, stored without a mailbox of its own (as before 0008t): it counts under th-j's
      pg_temp.v0008t_mail('inbox_message', 'm-j0', 'in', 'other', '2026-10-02T08:00:00Z', 'customer', null, '{"threadId": "th-j", "contactId": "k-nl"}'::jsonb || ib::jsonb)));
    perform cma.ingest_upsert_thread_events(v_crm, '[
      {"sourceId": "e-a1", "threadId": "th-a", "kind": "closed", "occurredAt": "2026-10-05T09:00:00Z", "actorKind": "agent", "ownerRef": "101"},
      {"sourceId": "e-a2", "threadId": "th-a", "kind": "reopened", "occurredAt": "2026-10-06T08:00:00Z", "actorKind": "system"},
      {"sourceId": "e-a2b", "threadId": "th-a", "kind": "reopened", "occurredAt": "2026-10-06T08:10:00Z", "actorKind": "system"},
      {"sourceId": "e-a3", "threadId": "th-a", "kind": "closed", "occurredAt": "2026-10-06T09:00:00Z", "actorKind": "agent", "ownerRef": "102"},
      {"sourceId": "e-i1", "threadId": "th-i", "kind": "reopened", "occurredAt": "2026-10-07T08:00:01Z", "actorKind": "system"},
      {"sourceId": "e-i2", "threadId": "th-i", "kind": "reopened", "occurredAt": "2026-10-07T09:00:00Z", "actorKind": "system"},
      {"sourceId": "e-j1", "threadId": "th-j", "kind": "closed", "occurredAt": "2026-10-02T09:00:00Z", "actorKind": "agent", "ownerRef": "101"},
      {"sourceId": "e-j2", "threadId": "th-j", "kind": "reopened", "occurredAt": "2026-10-05T06:00:00Z", "actorKind": "system"},
      {"sourceId": "e-j3", "threadId": "th-j", "kind": "closed", "occurredAt": "2026-10-05T07:00:00Z", "actorKind": "system"},
      {"sourceId": "e-e1", "threadId": "th-e", "kind": "closed", "occurredAt": "2026-10-06T09:30:00Z", "actorKind": "agent", "ownerRef": "101"},
      {"sourceId": "e-k1", "threadId": "th-k", "kind": "closed", "occurredAt": "2026-09-25T09:00:00Z", "actorKind": "agent", "ownerRef": "101"}]');
    -- engagements: an agent send, an automation, an inbox copy each way, a bounce, a logged reply, an
    -- unlinked owner, no owner, a deletion, Saturday, near midnight in two zones; and the week before
    perform cma.ingest_upsert_emails(v_crm, jsonb_build_array(
      pg_temp.v0008t_mail('crm_email', 'ce1', 'out', 'sent', '2026-10-05T12:00:00Z', 'agent', '101', '{"contactId": "k-nl", "origin": "CRM_UI", "category": "billing"}'),
      pg_temp.v0008t_mail('crm_email', 'ce2', 'out', 'sent', '2026-10-05T13:00:00Z', 'system', null, '{"contactId": "k-nl", "origin": "AUTOMATION_PLATFORM"}'),
      pg_temp.v0008t_mail('crm_email', 'ce3', 'out', 'sent', '2026-10-05T13:30:00Z', 'agent', '101', '{"contactId": "k-nl", "origin": "CONVERSATIONS"}'),
      pg_temp.v0008t_mail('crm_email', 'ce4', 'out', 'bounced', '2026-10-05T14:00:00Z', 'agent', '101', '{"contactId": "k-nl", "origin": "CRM_UI"}'),
      pg_temp.v0008t_mail('crm_email', 'ce5', 'in', 'other', '2026-10-06T10:00:00Z', 'customer', null, '{"contactId": "k-nl", "origin": "EMAIL_INTEGRATION"}'),
      pg_temp.v0008t_mail('crm_email', 'ce6', 'out', 'sent', '2026-10-06T11:00:00Z', 'agent', '102', '{"contactId": "k-nl", "origin": "CRM_UI"}'),
      pg_temp.v0008t_mail('crm_email', 'ce7', 'out', 'sent', '2026-10-06T12:00:00Z', 'unknown', null, '{"contactId": "k-nl"}'),
      pg_temp.v0008t_mail('crm_email', 'ce8', 'out', 'sent', '2026-10-06T13:00:00Z', 'agent', '101', '{"contactId": "k-nl", "origin": "CRM_UI"}'),
      pg_temp.v0008t_mail('crm_email', 'ce9', 'in', 'other', '2026-10-06T14:00:00Z', 'customer', null, '{"contactId": "k-nl", "origin": "CONVERSATIONS"}'),
      pg_temp.v0008t_mail('crm_email', 'ce10', 'out', 'sent', '2026-10-10T10:00:00Z', 'agent', '101', '{"contactId": "k-nl", "origin": "CRM_UI"}'),
      pg_temp.v0008t_mail('crm_email', 'ce11', 'out', 'sent', '2026-10-04T22:30:00Z', 'agent', '101', '{"contactId": "k-gb", "origin": "CRM_UI"}'),
      pg_temp.v0008t_mail('crm_email', 'ce12', 'out', 'sent', '2026-10-04T22:30:00Z', 'agent', '101', '{"contactId": "k-nl", "origin": "CRM_UI"}'),
      pg_temp.v0008t_mail('crm_email', 'ce13', 'out', 'sent', '2026-09-30T14:00:00Z', 'agent', '101', '{"contactId": "k-nl", "origin": "CRM_UI"}'),
      pg_temp.v0008t_mail('crm_email', 'ce14', 'out', 'sent', '2026-09-30T15:00:00Z', 'agent', '101', '{"contactId": "k-nl", "origin": "CRM_UI"}'),
      pg_temp.v0008t_mail('crm_email', 'ce15', 'out', 'sent', '2026-10-01T08:00:00Z', 'agent', '101', '{"contactId": "k-nl", "origin": "CRM_UI"}'),
      pg_temp.v0008t_mail('crm_email', 'ce16', 'out', 'sent', '2026-09-20T08:00:00Z', 'agent', '101', '{"contactId": "k-nl", "origin": "CONVERSATIONS"}'),
      pg_temp.v0008t_mail('crm_email', 'ce17', 'out', 'sent', '2026-09-19T08:00:00Z', 'agent', '101', '{"contactId": "k-nl", "origin": "CRM_UI"}'),
      -- the week before: an engagement whose contact comes from its association (GB), one whose market
      -- comes from its deal (GB)
      pg_temp.v0008t_mail('crm_email', 'ce18', 'out', 'sent', '2026-10-02T08:00:00Z', 'agent', '101', '{"origin": "CRM_UI"}'),
      pg_temp.v0008t_mail('crm_email', 'ce19', 'out', 'sent', '2026-10-02T09:00:00Z', 'agent', '101', '{"origin": "CRM_UI"}')));
    perform cma.ingest_upsert_records(v_crm, '[{"recordType": "deal", "sourceId": "d-x", "pipelineId": "p-x", "stageId": "s1", "market": "GB",
                                                "createdAt": "2026-10-01T08:00:00Z", "updatedAt": "2026-10-01T08:00:00Z"}]');
    perform cma.ingest_upsert_associations(v_crm, '[
      {"fromType": "crm_email", "fromId": "ce18", "toType": "contact", "toId": "k-gb", "removed": false, "changedAt": "2026-10-02T08:00:00Z"},
      {"fromType": "crm_email", "fromId": "ce19", "toType": "deal", "toId": "d-x", "removed": false, "changedAt": "2026-10-02T09:00:00Z"}]');
    perform cma.ingest_upsert_emails(v_crm, jsonb_build_array(
      jsonb_build_object('sourceKind', 'crm_email', 'sourceId', 'ce8', 'deletedAt', '2026-10-06T13:05:00Z'),
      jsonb_build_object('sourceKind', 'crm_email', 'sourceId', 'ce17', 'deletedAt', '2026-09-19T08:05:00Z')));
    perform cma.ingest_upsert_contacts(v_crm, '[{"sourceId": "k-nl", "country": "NL", "updatedAt": "2026-09-01T00:00:00Z"},
                                                {"sourceId": "k-gb", "country": "GB", "updatedAt": "2026-09-01T00:00:00Z"}]');

    -- B3. account refs and origins: stored, kept by a later read without them, an @ or a space refused;
    --     the engagements' origin the code as given
    perform cma.ingest_upsert_emails(v_crm, jsonb_build_array(
      pg_temp.v0008t_mail('inbox_message', 'm-a1', 'in', 'other', '2026-10-05T08:00:00Z', 'customer', null, '{"threadId": "th-a", "updatedAt": "2026-10-05T08:00:01Z"}'),
      pg_temp.v0008t_mail('crm_email', 'ce1', 'out', 'sent', '2026-10-05T12:00:00Z', 'agent', '101', '{"updatedAt": "2026-10-05T12:00:01Z"}')));
    perform cma.ingest_upsert_threads(v_crm, jsonb_build_array(
      jsonb_build_object('sourceId', 'th-c', 'status', 'open', 'createdAt', '2026-10-07T10:00:00Z', 'updatedAt', '2026-10-07T15:00:01Z')));
    perform set_config('role', 'cma_owner', true);
    select string_agg(format('%s:%s/%s', em.source_id, coalesce(em.account_ref, '-'), coalesce(em.origin, '-')), ' ' order by em.source_id) into v_txt
    from cma.email_message em where em.tenant_id = v_t1 and em.source_id in ('m-a1', 'ce1', 'ce2', 'ce7');
    select v_txt || ' ' || string_agg(format('%s:%s', th.source_id, coalesce(th.account_ref, '-')), ' ' order by th.source_id) into v_txt
    from cma.email_thread th where th.tenant_id = v_t1 and th.source_id in ('th-c', 'th-d');
    perform set_config('role', 'cma_app', true);
    v_txt := v_txt || ' ' || pg_temp.v0008t_code(format('select cma.ingest_upsert_emails(%L, %L)', v_crm,
               jsonb_build_array(pg_temp.v0008t_mail('inbox_message', 'm-x1', 'in', 'other', '2026-10-05T08:00:00Z', 'customer', null, '{"threadId": "th-a", "accountId": "a@b"}'))))
      || ' ' || pg_temp.v0008t_code(format('select cma.ingest_upsert_emails(%L, %L)', v_crm,
               jsonb_build_array(pg_temp.v0008t_mail('crm_email', 'ce-x', 'out', 'sent', '2026-10-05T08:00:00Z', 'agent', '101', '{"origin": "CRM UI"}'))))
      || ' ' || pg_temp.v0008t_code(format('select cma.ingest_upsert_threads(%L, %L)', v_crm,
               '[{"sourceId": "th-x", "status": "open", "accountId": "a b", "createdAt": "2026-10-05T08:00:00Z", "updatedAt": "2026-10-05T08:00:00Z"}]'));
    -- a message stored without a mailbox counts under its conversation's (m-j0 under th-j's ac1)
    select v_txt || ' ' || coalesce(string_agg(coalesce(e.account_name, '-'), ','), 'none') into v_txt
    from cma.email_of(v_t1, timestamptz '2026-10-02 08:00+00', timestamptz '2026-10-02 08:00:01+00') e where e.source_kind = 'inbox_message';
    v_rows := v_rows || array['13', 'B3 account refs and origins kept by a later read; an @, a space and a bad origin refused; the thread''s mailbox for a message without one',
      case when v_txt = 'ce1:-/CRM_UI ce2:-/AUTOMATION_PLATFORM ce7:-/- m-a1:ac1/- th-c:ac2 th-d:- CMA04 CMA04 CMA04 Support NL mailbox' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B4. the period's emails as the report counts them (5 to 11 October, ended): received 7 (spam, an
    --     uncounted inbox, channel and mailbox left out), one logged reply (its inbox copy left out),
    --     agent sends 9, automated 2 (an automated origin in another case and spacing, a bot), bounced and
    --     failed 2; the inbox copy and the deletion nowhere
    perform set_config('app.user_id', v_analyst1::text, true);
    select format('received %s logged %s agent %s automated %s bounced %s', r.received, r.logged_replies, r.sent_agent, r.sent_automated, r.bounced_failed)
    into v_txt
    from cma.email_overview_of(v_t1, date '2026-10-05', date '2026-10-11', 'day', null, null, null, v_after) r
    where r.period = 'current' and r.group_key is null;
    v_rows := v_rows || array['14', 'B4 received, logged replies, agent sends, automated, bounced and failed; copies, spam and uncounted left out',
      case when v_txt = 'received 7 logged 1 agent 9 automated 2 bounced 2' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B5. openings and closes: seven openings (four creations, the reopen after a close, th-j's reopen
    --     after Friday's close; th-i's reopens without a close are none), three closes; spam and the
    --     uncounted ones neither
    select format('opened %s closed %s', r.threads_opened, r.threads_closed) into v_txt
    from cma.email_overview_of(v_t1, date '2026-10-05', date '2026-10-11', 'day', null, null, null, v_after) r
    where r.period = 'current' and r.group_key is null;
    select v_txt || ' | ' || string_agg(format('%s:%s@%s', o.thread_source_id, o.opening_kind, to_char(o.opened_at at time zone 'UTC', 'DD HH24:MI')), ' '
                                        order by o.opened_at)
    into v_txt
    from cma.email_openings_of(v_t1, timestamptz '2026-10-04 22:00+00', timestamptz '2026-10-11 22:00+00') o;
    v_rows := v_rows || array['15', 'B5 openings: creations and reopens after a close, a reopen at creation none; closes',
      case when v_txt = 'opened 7 closed 3 | th-j:reopened@05 06:00 th-a:created@05 08:00 th-a:reopened@06 08:00 th-i:created@07 08:00 th-c:created@07 10:00 th-d:created@08 09:00 th-b:created@09 14:50'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B6. the first reply: in business hours (1800 s both ways), the reopen's message one second before
    --     the reopen event (1201 s), over a weekend (232200 s elapsed, 1800 business), past the target in
    --     London (18000 s), an unknown market (600 s, no business hours); a bot and a failed message are
    --     no reply; none for th-i and th-j. The medians and the target over the period
    select string_agg(format('%s/%s:%s/%s/%s/%s', o.thread_source_id, o.opening_kind, coalesce(o.reply_seconds::text, '-'),
                             coalesce(o.reply_business_seconds::text, '-'), coalesce(o.reply_within_target::text, '-'), coalesce(o.reply_owner_ref, '-')), ' '
                      order by o.opened_at)
    into v_txt
    from cma.email_openings_of(v_t1, timestamptz '2026-10-04 22:00+00', timestamptz '2026-10-11 22:00+00') o;
    select v_txt || format(' | replied %s median %s business %s within %s of %s no hours %s', r.replied, r.reply_median_seconds,
                           r.reply_median_business_seconds, r.within_target, r.target_known, r.no_hours)
    into v_txt
    from cma.email_overview_of(v_t1, date '2026-10-05', date '2026-10-11', 'day', null, null, null, v_after) r
    where r.period = 'current' and r.group_key is null;
    v_rows := v_rows || array['16', 'B6 the first reply in and out of business hours, an unknown market, the target, no bot or failed reply',
      case when v_txt = 'th-j/reopened:-/-/-/- th-a/created:1800/1800/true/101 th-a/reopened:1201/1201/true/102 th-i/created:-/-/-/- th-c/created:18000/18000/false/101 th-d/created:600/-/-/103 th-b/created:232200/1800/true/101'
                         || ' | replied 5 median 1800.0 business 1800.0 within 3 of 4 no hours 1'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B7. time to close: th-a's two openings an hour each, th-j's reopen an hour before office time (0
    --     business seconds); the medians
    select string_agg(format('%s/%s:%s/%s', o.thread_source_id, o.opening_kind, coalesce(o.close_seconds::text, '-'),
                             coalesce(o.close_business_seconds::text, '-')), ' ' order by o.opened_at) into v_txt
    from cma.email_openings_of(v_t1, timestamptz '2026-10-04 22:00+00', timestamptz '2026-10-11 22:00+00') o
    where o.closed_at is not null;
    select v_txt || format(' | median %s business %s', r.close_median_seconds, r.close_median_business_seconds) into v_txt
    from cma.email_overview_of(v_t1, date '2026-10-05', date '2026-10-11', 'day', null, null, null, v_after) r
    where r.period = 'current' and r.group_key is null;
    v_rows := v_rows || array['17', 'B7 time to close per opening, elapsed and in business time, and the medians',
      case when v_txt = 'th-j/reopened:3600/0 th-a/created:3600/3600 th-a/reopened:3600/3600 | median 3600.0 business 3600.0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B8. the market: through the GB mailbox before the NL inbox (th-c), the inbox when there is no
    --     mailbox or contact (th-i), unknown (th-d), the GB contact before the NL inbox (th-y); and the dates in each market's zone: ce11 (GB) and
    --     ce12 (NL) at 22:30 UTC on Sunday 4 October fall on the 4th in London and the 5th in Amsterdam,
    --     in different ISO weeks
    select string_agg(format('%s:%s', x.thread_source_id, x.market), ' ' order by x.thread_source_id) into v_txt
    from (select distinct e.thread_source_id, e.market from cma.email_of(v_t1, timestamptz '2026-10-07 00:00+00', timestamptz '2026-10-09 00:00+00') e
          where e.thread_source_id in ('th-c', 'th-d', 'th-i')
          union
          select distinct e.thread_source_id, e.market from cma.email_of(v_t1, timestamptz '2026-10-02 00:00+00', timestamptz '2026-10-03 00:00+00') e
          where e.thread_source_id = 'th-y') x;
    select v_txt || ' | ' || string_agg(format('%s/%s/%s', e.market, e.business_date, e.week_start), ' ' order by e.market) into v_txt
    from cma.email_of(v_t1, timestamptz '2026-10-04 22:30+00', timestamptz '2026-10-04 22:31+00') e;
    -- and the chain the reads compute inline equals cma.email_market_of on every counted email and
    -- conversation of tenant one (matched on what the reads return; the two engagements at 22:30 share
    -- every key, so the markets are compared as a multiset)
    select count(*) into v_n from (
      (select e.connection_id, coalesce(e.thread_source_id, '-'), e.occurred_at, e.direction, e.status, e.actor_kind, coalesce(e.owner_ref, '-'), e.market
       from cma.email_of(v_t1, timestamptz '2026-01-01 00:00+00', timestamptz '2027-01-01 00:00+00') e
       except all
       select em.connection_id, coalesce(em.thread_source_id, '-'), em.occurred_at, em.direction, em.status, em.actor_kind, coalesce(em.owner_ref, '-'),
              (cma.email_market_of(v_t1, em.connection_id, em.source_kind, em.source_id)).code
       from cma.email_message em where em.tenant_id = v_t1)
      union all
      (select th.connection_id, th.source_id, null::timestamptz, null::text, null::text, null::text, null::text, th.market
       from cma.email_threads_counted_of(v_t1, (select array_agg(x.id) from cma.email_thread x where x.tenant_id = v_t1)) th
       except all
       select x.connection_id, x.source_id, null::timestamptz, null::text, null::text, null::text, null::text, (cma.email_market_of(v_t1, x.connection_id, 'inbox_thread', x.source_id)).code
       from cma.email_thread x where x.tenant_id = v_t1)) d;
    v_txt := v_txt || ' | differing ' || v_n;
    v_rows := v_rows || array['18', 'B8 the market through the mailbox, then the inbox; dates and weeks in the market''s zone; the inline chain as email_market_of',
      case when v_txt = 'th-c:GB th-d:unknown th-i:NL th-y:GB | GB/2026-10-04/2026-09-28 NL/2026-10-05/2026-10-05 | differing 0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B9. per person (switched on): Anna (101) five sends at 00, 10, 12, 14 and 16 o'clock, three
    --     replies, one close; Bram (103) one send and reply without business hours; not linked: 102's two
    --     sends, reply and close and the send without an owner, counted as one owner; the total. By name,
    --     the not-linked row last, never an owner id
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('reports.per_person', 'email');
    perform set_config('app.user_id', v_analyst1::text, true);
    select string_agg(format('%s:%s/%s/%s/%s/%s/%s/%s/%s/%s/%s', p.row_kind, coalesce(p.display_name, '-'), coalesce(p.unlinked_owners::text, '-'),
                             p.sent, p.replies, p.threads_closed, coalesce(p.reply_median_seconds::text, '-'),
                             coalesce(p.reply_median_business_seconds::text, '-'), p.within_target, p.target_known,
                             (select string_agg(h::text, ',') from generate_subscripts(p.sent_by_hour, 1) h where p.sent_by_hour[h] > 0)), ' ')
    into v_txt
    from cma.email_per_person(date '2026-10-05', date '2026-10-11', null, null, null) p;
    v_rows := v_rows || array['19', 'B9 per person through the linked accounts, the not-linked row last, sends per hour',
      case when v_txt = 'person:Anna Verify/-/5/3/1/18000.0/1800.0/2/3/1,11,13,15,17 person:Bram Verify/-/1/1/0/600.0/-/0/0/12 not_linked:-/1/3/1/1/1201.0/1201.0/1/1/11,14,15 total:-/-/9/5/2/1800.0/1800.0/3/4/1,11,12,13,14,15,17'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B10. per person refused while reports.per_person does not hold email (orders alone, empty), and
    --      without performance.team (the reader); allowed for the supervisor
    v_txt := pg_temp.v0008t_code('select * from cma.email_per_person(date ''2026-10-05'', date ''2026-10-11'', null, null, null)');
    perform set_config('app.user_id', v_reader1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008t_code('select * from cma.email_per_person(date ''2026-10-05'', date ''2026-10-11'', null, null, null)');
    perform set_config('app.user_id', v_super1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008t_code('select * from cma.email_per_person(date ''2026-10-05'', date ''2026-10-11'', null, null, null)');
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('reports.per_person', 'orders');
    perform set_config('app.user_id', v_analyst1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008t_code('select * from cma.email_per_person(date ''2026-10-05'', date ''2026-10-11'', null, null, null)');
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('reports.per_person', '');
    perform set_config('app.user_id', v_analyst1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008t_code('select * from cma.email_per_person(date ''2026-10-05'', date ''2026-10-11'', null, null, null)');
    v_rows := v_rows || array['20', 'B10 per person refused while the setting does not hold email, and without performance.team',
      case when v_txt = 'ok CMA06 ok CMA06 CMA06' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B11. the previous period like for like: seen on Wednesday 7 October 16:30 it is 28 to 30 September,
    --      the 30th up to 16:30 (ce13 at 16:00 in, ce14 at 17:00 out); once ended, 28 September to 4
    --      October whole (ce11 on the 4th in London, ce13, ce14, ce15, ce18, ce19; th-j's and th-y's
    --      creations, th-j's close); before the period starts, nothing
    select string_agg(format('%s', r.sent_agent), '') into v_txt
    from cma.email_overview_of(v_t1, date '2026-10-05', date '2026-10-11', 'day', null, null, null, v_running) r where r.period = 'previous';
    select v_txt || ' ' || string_agg(format('%s/%s/%s', r.sent_agent, r.threads_opened, r.threads_closed), '') into v_txt
    from cma.email_overview_of(v_t1, date '2026-10-05', date '2026-10-11', 'day', null, null, null, v_after) r where r.period = 'previous';
    select v_txt || ' ' || string_agg(format('%s/%s', r.sent_agent, r.threads_opened), '') into v_txt
    from cma.email_overview_of(v_t1, date '2026-10-05', date '2026-10-11', 'day', null, null, null, v_before) r where r.period = 'previous';
    select v_txt || ' ' || count(*) into v_txt
    from cma.email_overview_of(v_t1, date '2026-10-05', date '2026-10-11', 'week', null, null, null, v_after) r where r.period = 'current';
    v_rows := v_rows || array['21', 'B11 the previous period like for like: running, ended, not started',
      case when v_txt = '1 6/2/1 0/0 2' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B12. the filters narrow everything alike: GB (th-c's mailbox), the Support inbox (engagements left
    --      out), the GB mailbox; and their refusals and the period's bound
    select string_agg(format('%s:%s/%s/%s/%s', x.f, r.received, r.sent_agent, r.threads_opened, r.logged_replies), ' ' order by x.f) into v_txt
    from (values ('a-market', 'GB', null::text, null::text), ('b-inbox', null, v_crm::text || ':ib1', null),
                 ('c-account', null, null, v_crm::text || ':ac2')) as x(f, m, i, a)
    cross join lateral cma.email_overview(date '2026-10-05', date '2026-10-11', 'day', x.m, x.i, x.a) r
    where r.period = 'current' and r.group_key is null;
    v_txt := v_txt || ' ' || pg_temp.v0008t_code('select * from cma.email_overview(date ''2026-10-05'', date ''2026-10-11'', ''day'', ''nl'', null, null)')
      || ' ' || pg_temp.v0008t_code('select * from cma.email_overview(date ''2026-10-05'', date ''2026-10-11'', ''day'', null, ''ib1'', null)')
      || ' ' || pg_temp.v0008t_code('select * from cma.email_overview(date ''2026-10-05'', date ''2026-10-11'', ''hour'', null, null, null)')
      || ' ' || pg_temp.v0008t_code('select * from cma.email_overview(date ''2026-07-01'', date ''2026-10-11'', ''day'', null, null, null)')
      || ' ' || pg_temp.v0008t_code('select * from cma.email_received_series(date ''2026-10-05'', date ''2026-10-11'', ''day'', ''channel'', null, null, null)')
      || ' ' || pg_temp.v0008t_code(format('select * from cma.email_waiting(null, null, %L)', v_crm::text || ':a@b'));
    v_rows := v_rows || array['22', 'B12 the market, inbox and mailbox filters; their refusals and the 92 days',
      case when v_txt = 'a-market:1/1/1/0 b-inbox:5/3/6/0 c-account:1/1/1/0 CMA04 CMA04 CMA04 CMA04 CMA04 CMA04' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B13. per inbox, mailbox and category in one pass, and received per day and inbox
    select string_agg(format('%s=%s:%s/%s/%s/%s', r.dimension, coalesce(r.group_label, r.group_key), r.received, r.sent_agent, r.replied,
                             coalesce(r.reply_median_business_seconds::text, '-')), ' ') into v_txt
    from cma.email_by_dimension(date '2026-10-05', date '2026-10-11', null, null, null) r
    where r.dimension in ('inbox', 'account') or (r.dimension = 'category' and r.group_key = 'billing');
    select v_txt || ' | ' || string_agg(format('%s/%s/%s', r.group_key, coalesce(r.series_label, r.series_key), r.received), ' ') into v_txt
    from cma.email_received_series(date '2026-10-05', date '2026-10-11', 'day', 'account', null, null, null) r;
    v_rows := v_rows || array['23', 'B13 the figures per inbox, mailbox and category; received per day and mailbox',
      case when v_txt = 'inbox=Sales:2/1/1/- inbox=Support:5/3/4/1800.0 inbox=none:0/5/0/- account=Support GB:1/1/1/18000.0 account=Support NL mailbox:3/2/3/1800.0 account=none:3/6/1/- category=billing:0/1/2/1500.5'
                         || ' | 2026-10-05/Support NL mailbox/1 2026-10-06/Support NL mailbox/1 2026-10-07/Support GB/1 2026-10-07/none/1 2026-10-08/none/2 2026-10-09/Support NL mailbox/1'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B20. the report page's one read equals the overview (by day, the total, the previous total), the
    --      figures per inbox, mailbox, category and market, and the received series per inbox and mailbox
    select count(*) into v_n from (
      (select r.period, case when r.group_key is null then 'total' else 'day' end, r.group_key, r.received, r.sent_agent, r.threads_opened,
              r.reply_median_business_seconds, r.within_target
       from cma.email_overview(date '2026-10-05', date '2026-10-11', 'day', null, null, null) r
       union all
       select 'current', r.dimension, r.group_key, r.received, r.sent_agent, r.threads_opened, r.reply_median_business_seconds, r.within_target
       from cma.email_by_dimension(date '2026-10-05', date '2026-10-11', null, null, null) r
       union all
       select 'current', 'day_' || x.split, r.group_key || '|' || r.series_key, r.received, null, null, null, null
       from (values ('inbox'), ('account')) x(split)
       cross join lateral cma.email_received_series(date '2026-10-05', date '2026-10-11', 'day', x.split, null, null, null) r)
      except all
      select p.period, p.dimension, p.group_key, p.received,
             case when p.dimension like 'day\_%' then null else p.sent_agent end,
             case when p.dimension like 'day\_%' then null else p.threads_opened end,
             case when p.dimension like 'day\_%' then null else p.reply_median_business_seconds end,
             case when p.dimension like 'day\_%' then null else p.within_target end
      from cma.email_report(date '2026-10-05', date '2026-10-11', 'day', null, null, null) p
      where p.dimension not like 'day\_%' or p.received > 0) d;
    select v_n || ' ' || count(*) into v_txt from cma.email_report(date '2026-10-05', date '2026-10-11', 'day', null, null, null);
    v_txt := v_txt || ' ' || pg_temp.v0008t_code('select * from cma.email_report(date ''2026-10-05'', date ''2026-10-11'', ''market'', null, null, null)');
    v_rows := v_rows || array['30', 'B20 the report page''s one read equals the overview, the figures per dimension and the received series',
      case when v_txt ~ '^0 [0-9]+ CMA04$' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B14. the history start: 30 September (ce13), not the inbox copy of the 20th, the uncounted inbox's
    --      message of the 25th or the deletion of the 19th; none for a tenant without email
    v_txt := coalesce(cma.email_history_start()::text, 'none');
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_analyst2::text, true);
    v_txt := v_txt || ' ' || coalesce(cma.email_history_start()::text, 'none');
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['24', 'B14 the history start: the earliest counted email; none without email',
      case when v_txt = '2026-09-30 none' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B15. waiting now (Monday 12 October 12:00 in Amsterdam): th-i since Wednesday 10:00, its first
    --      incoming message after the last agent message, not Monday's (93600 business seconds), th-d since Thursday's forwarded message (no business hours); not th-b or th-c (an
    --      agent last), spam or the uncounted ones; one row with its total of two and the link; NL alone
    select string_agg(format('%s:%s/%s/%s', w.thread_source_id, to_char(w.waiting_since at time zone 'UTC', 'DD HH24:MI'), w.waited_seconds,
                             coalesce(w.waited_business_seconds::text, '-')), ' ') into v_txt
    from cma.email_waiting_of(v_t1, v_now) w;
    select v_txt || ' | ' || string_agg(format('%s %s %s', w.thread_source_id, w.total_rows, coalesce(w.record_url, '-')), ' ') into v_txt
    from cma.email_waiting(null, null, null, 1) w;
    select v_txt || ' | ' || string_agg(w.thread_source_id, ' ') into v_txt from cma.email_waiting('unknown', null, null) w;
    v_rows := v_rows || array['25', 'B15 waiting now: since the first incoming after the last agent message, business seconds, capped',
      case when v_txt like 'th-i:07 08:00/%/93600 th-d:08 10:00/%/- | th-i 2 https://crm.example.invalid/portal-1/thread/th-i | th-d' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- tenant three: lead deals for not responding (the admin, then the Ingest user)
    perform set_config('app.tenant_id', v_t3::text, true);
    perform set_config('app.user_id', v_admin3::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.set_tenant_setting('intake.start_date', '2026-09-01');
    perform cma.set_user_external_id(v_owner3, 'verifycrm_owner', '301');
    select c.connection_id into v_crm3 from cma.upsert_connection('verifycrm', 'Verify email three', 'portal-3', null, null) c;
    perform cma.set_connection_kind(v_crm3, 'crm');
    perform cma.set_connection_settings(v_crm3, jsonb_build_object('email_inbox_copy_origins', 'CONVERSATIONS', 'email_automated_origins', 'AUTOMATION_PLATFORM',
                                                                   'record_url_deal', 'https://crm.example.invalid/{account}/deal/{id}'));
    select c.connection_id into v_tel3 from cma.upsert_connection('verifytel', 'Verify phones three', 'company-3', null, null) c;
    perform cma.set_connection_kind(v_tel3, 'telephony');
    perform set_config('app.user_id', v_ing3::text, true);
    perform cma.ingest_upsert_pipelines(v_crm3, '[{"recordType": "deal", "pipelineId": "sales", "label": "Sales", "stages": [
       {"stageId": "s1", "label": "Open", "order": 1, "isClosed": false}, {"stageId": "s9", "label": "Won", "order": 9, "isClosed": true}]}]');
    perform cma.ingest_upsert_records(v_crm3, (select jsonb_agg(jsonb_build_object('recordType', 'deal', 'sourceId', 'dl' || n, 'pipelineId', 'sales',
                                                                       'stageId', case when n = 8 then 's9' else 's1' end, 'ownerRef', case when n = 1 then '301' end,
                                                                       'contactId', 'k-r' || n, 'market', 'NL',
                                                                       'createdAt', '2026-10-01T08:00:00Z', 'updatedAt', '2026-10-01T08:00:00Z'))
                                               from generate_series(1, 9) n));
    perform cma.ingest_upsert_threads(v_crm3, '[{"sourceId": "th-r9", "inboxId": "ib1", "status": "open", "contactId": "k-r9",
                                                "createdAt": "2026-10-05T10:00:00Z", "updatedAt": "2026-10-05T10:00:00Z"}]');
    perform cma.ingest_upsert_emails(v_crm3, jsonb_build_array(
      pg_temp.v0008t_mail('crm_email', 'r1', 'out', 'sent', '2026-10-05T08:00:00Z', 'agent', '301', '{"contactId": "k-r1", "origin": "CRM_UI"}'),
      pg_temp.v0008t_mail('crm_email', 'r2', 'out', 'sent', '2026-10-05T08:00:00Z', 'agent', '301', '{"contactId": "k-r2", "origin": "CRM_UI"}'),
      pg_temp.v0008t_mail('crm_email', 'r2b', 'in', 'other', '2026-10-06T08:00:00Z', 'customer', null, '{"contactId": "k-r2"}'),
      pg_temp.v0008t_mail('crm_email', 'r3', 'out', 'sent', '2026-10-05T08:00:00Z', 'agent', '301', '{"contactId": "k-r3", "origin": "CRM_UI"}'),
      pg_temp.v0008t_mail('crm_email', 'r4', 'out', 'sent', '2026-10-05T09:00:00Z', 'agent', '301', '{"contactId": "k-r4", "origin": "CRM_UI"}'),
      pg_temp.v0008t_mail('crm_email', 'r5', 'out', 'sent', now() - interval '3 days', 'agent', '301', '{"contactId": "k-r5", "origin": "CRM_UI"}'),
      pg_temp.v0008t_mail('crm_email', 'r6', 'out', 'sent', '2026-10-05T08:00:00Z', 'system', null, '{"contactId": "k-r6", "origin": "AUTOMATION_PLATFORM"}'),
      pg_temp.v0008t_mail('crm_email', 'r7', 'out', 'sent', '2026-10-05T08:00:00Z', 'agent', '301', '{"contactId": "k-r7", "origin": "CONVERSATIONS"}'),
      pg_temp.v0008t_mail('crm_email', 'r8', 'out', 'sent', '2026-10-05T08:00:00Z', 'agent', '301', '{"contactId": "k-r8", "origin": "CRM_UI"}'),
      pg_temp.v0008t_mail('inbox_message', 'r9', 'out', 'sent', '2026-10-05T10:00:00Z', 'agent', '301', '{"threadId": "th-r9", "inboxId": "ib1", "contactId": "k-r9"}')));
    -- calls: dl3's contact connected for a minute (a linked outbound telephony call), dl4's for 5 seconds
    perform cma.ingest_upsert_calls(v_crm3, jsonb_build_array(
      jsonb_build_object('sourceId', 'cc3', 'occurredAt', '2026-10-06T08:00:00Z', 'direction', 'outbound', 'counterpartHash', repeat('3', 64), 'updatedAt', '2026-10-06T08:00:00Z'),
      jsonb_build_object('sourceId', 'cc4', 'occurredAt', '2026-10-06T08:00:00Z', 'direction', 'outbound', 'counterpartHash', repeat('4', 64), 'updatedAt', '2026-10-06T08:00:00Z')));
    perform cma.ingest_upsert_associations(v_crm3, jsonb_build_array(
      jsonb_build_object('fromType', 'crm_call', 'fromId', 'cc3', 'toType', 'contact', 'toId', 'k-r3', 'removed', false, 'changedAt', '2026-10-06T08:00:00Z'),
      jsonb_build_object('fromType', 'crm_call', 'fromId', 'cc4', 'toType', 'contact', 'toId', 'k-r4', 'removed', false, 'changedAt', '2026-10-06T08:00:00Z')));
    perform cma.ingest_upsert_telephony_calls(v_tel3, jsonb_build_array(
      jsonb_build_object('sourceId', 'tp3', 'direction', 'outbound', 'status', 'done', 'startedAt', '2026-10-06T08:00:10Z', 'answeredAt', '2026-10-06T08:00:20Z',
                         'endedAt', '2026-10-06T08:01:20Z', 'counterpartHash', repeat('3', 64), 'versionAt', '2026-10-06T08:01:20Z'),
      jsonb_build_object('sourceId', 'tp4', 'direction', 'outbound', 'status', 'done', 'startedAt', '2026-10-06T08:00:10Z', 'answeredAt', '2026-10-06T08:00:20Z',
                         'endedAt', '2026-10-06T08:00:25Z', 'counterpartHash', repeat('4', 64), 'versionAt', '2026-10-06T08:00:25Z')));
    v_n := cma.link_calls(timestamptz '2026-10-01 00:00+00');

    -- B16. not responding (Monday 12 October 12:00, five days): dl1 (owner linked), dl4 (a 5-second call
    --      is no conversation), dl9 (an agent's inbox message); not dl2 (answered), dl3 (connected call),
    --      dl5 (three days before now), dl6 (an automation), dl7 (an inbox copy), dl8 (closed); with its link and
    --      the total, capped at two
    perform set_config('app.user_id', v_analyst3::text, true);
    select v_n || ' | ' || string_agg(format('%s:%s', r.deal_source_id, r.days_since), ' ') into v_txt
    from cma.email_not_responding_of(v_t3, v_now) r;
    select v_txt || ' | ' || string_agg(format('%s %s %s %s', r.deal_source_id, coalesce((r.owner_user_id = v_owner3)::text, '-'), r.total_rows, coalesce(r.record_url, '-')), ' ')
    into v_txt from cma.email_not_responding(null, 2) r;
    v_rows := v_rows || array['26', 'B16 not responding: no incoming email or connected call since the agent''s email, five days',
      case when v_txt like '2 | dl1:% dl4:% dl9:% | dl1 true 3 https://crm.example.invalid/portal-3/deal/dl1 dl4 - 3 https://crm.example.invalid/portal-3/deal/dl4'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B17. the permissions: the reads for reports.view (the reader) and performance.team (the supervisor);
    --      the agent and the Ingest user refused; no acting user CMA01
    perform set_config('app.tenant_id', v_t1::text, true);
    v_txt := '';
    foreach v_detail in array array[v_reader1::text, v_super1::text, v_agent1::text, v_ing1::text] loop
      perform set_config('app.user_id', v_detail, true);
      v_txt := v_txt || pg_temp.v0008t_code('select * from cma.email_overview(date ''2026-10-05'', date ''2026-10-11'', ''day'', null, null, null)')
        || '/' || pg_temp.v0008t_code('select * from cma.email_by_dimension(date ''2026-10-05'', date ''2026-10-11'', null, null, null)')
        || '/' || pg_temp.v0008t_code('select * from cma.email_received_series(date ''2026-10-05'', date ''2026-10-11'', ''day'', ''inbox'', null, null, null)')
        || '/' || pg_temp.v0008t_code('select * from cma.email_waiting(null, null, null)')
        || '/' || pg_temp.v0008t_code('select * from cma.email_not_responding(null)')
        || '/' || pg_temp.v0008t_code('select cma.email_history_start()') || ' ';
    end loop;
    perform set_config('app.user_id', '', true);
    v_txt := v_txt || pg_temp.v0008t_code('select * from cma.email_overview(date ''2026-10-05'', date ''2026-10-11'', ''day'', null, null, null)');
    v_rows := v_rows || array['27', 'B17 the permissions: reports.view or performance.team; an agent and the Ingest user refused',
      case when v_txt = 'ok/ok/ok/ok/ok/ok ok/ok/ok/ok/ok/ok CMA06/CMA06/CMA06/CMA06/CMA06/CMA06 CMA06/CMA06/CMA06/CMA06/CMA06/CMA06 CMA01'
            and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B18. tenant isolation: tenant two (a connection of the same adapter and names) sees none of tenant
    --      one's mailboxes, emails, openings or waiting rows, and cannot configure tenant one's connection
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    select c.connection_id into v_crm2 from cma.upsert_connection('verifycrm', 'Verify email two', 'portal-2', null, null) c;
    perform cma.set_connection_kind(v_crm2, 'crm');
    perform set_config('app.user_id', v_analyst2::text, true);
    select format('%s/%s/%s/%s/%s', (select count(*) from cma.connection_inbox_account),
                  (select r.received + r.sent_agent + r.threads_opened from cma.email_overview(date '2026-10-05', date '2026-10-11', 'day', null, null, null) r
                   where r.period = 'current' and r.group_key is null),
                  (select count(*) from cma.email_waiting(null, null, null)), (select count(*) from cma.email_not_responding(null)),
                  (select count(*) from cma.email_of(v_t1, timestamptz '2026-09-01 00:00+00', timestamptz '2026-11-01 00:00+00'))) into v_txt;
    perform set_config('app.user_id', v_admin2::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008t_code(format('select cma.set_inbox_account(%L, ''ac1'', null, true, null)', v_crm));
    perform set_config('app.user_id', v_ing2::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008t_code(format('select cma.ingest_upsert_inbox_accounts(%L, ''[]'')', v_crm));
    v_rows := v_rows || array['28', 'B18 tenant isolation for the mailboxes, the reads and the configuration',
      case when v_txt = '0/0/0/0/0 CMA02 CMA02' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B19. a reader scoped to tenant three sees its three not-responding deals and none of tenant one's
    --      waiting rows or mailboxes; scoped to tenant one, its two waiting rows and five mailboxes
    perform set_config('role', 'cma_readonly', true);
    perform set_config('app.tenant_id', v_t3::text, true);
    select format('%s/%s/%s', (select count(*) from cma_read.email_not_responding where tenant_id = v_t3),
                  (select count(*) from cma_read.email_waiting where tenant_id = v_t1),
                  (select count(*) from cma_read.connection_inbox_account where tenant_id = v_t1)) into v_txt;
    perform set_config('app.tenant_id', v_t1::text, true);
    select v_txt || format(' %s/%s', (select count(*) from cma_read.email_waiting where tenant_id = v_t1 and waiting_since <= now()),
                           (select count(*) from cma_read.connection_inbox_account where tenant_id = v_t1)) into v_txt;
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['29', 'B19 a reader scoped to one tenant sees its own rows only',
      case when v_txt = '3/0/0 2/5' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['39', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008t (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008t values (39, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008t
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED: not dev'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008t where result = 'PASS') = 26
                       and not exists (select 1 from verify_0008t where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0008t where result = 'PASS'),
                                        (select count(*) from verify_0008t where result <> 'PASS'))) x
order by ord;
drop function if exists pg_temp.v0008t_code(text);
drop function if exists pg_temp.v0008t_mail(text, text, text, text, timestamptz, text, text, jsonb);
reset role;
