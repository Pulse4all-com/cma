-- =============================================================================================
-- 101_verify_definitions_calls.sql: verifies addition 0008zc, step 1 of docs/definitions.md
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure and privileges;
-- block B works on two throwaway tenants inside a subtransaction that is always rolled back. Universal otherwise:
-- nothing of the seed is used; adapters, lines, tags, users, deals, contacts, calls and hashes are invented data
-- values (no hash below is made from a real number). Every check writes one row, PASS or FAIL, and the last result
-- lists them with the verdict, because Cloud SQL Studio shows no notices. Run as your own IAM login in dev, after
-- 100_definitions_calls.sql; then 63, 95, 41, 75, 83, 85, 91, 93 and 99 again (91 and 99 from the Terminal).
--   A  structure and privileges: the addition row after 0008zb; the tag's meaning with its seven keys, nullable, in
--      the reader view; the settings (the Conversation threshold, the old key gone everywhere, connected from 0); every
--      function the application's only and in the caller's rights, the helpers immutable, the old names gone
--      (cma.crm_call_connected_of among them) and Email's not-responding read on cma.crm_call_conversation_of; the
--      reads use the helpers and no CRM call outcome; no column of a function or reader view still named reached
--   B  behaviour. Tenant one (Europe/Amsterdam; a CRM and a telephony connection; one NL line; tags Not Reached
--      (meaning not_reached), Not Reached off (not_reached, not counted) and Type (call_type); Anna linked to the
--      telephony user of the outbound calls, Bram to the inbound one) with thirteen telephony calls on 6 October 2026:
--        o1 outbound answered, 1 s of talk              o8 outbound, nobody answered
--        o2 outbound answered, still in progress        o9 outbound 45 s, tagged Type
--        o3 outbound 29 s, untagged                     i1 inbound answered 20 s
--        o4 outbound 30 s, untagged                     i2 inbound answered 45 s
--        o5 outbound 30 s, tagged Not Reached           i3 inbound answered 45 s, tagged Not Reached
--        o6 outbound 120 s, Not Reached since removed   i4 inbound missed
--        o7 outbound 60 s, tagged Not Reached off
--      a sales deal dW whose contact's CRM calls log o3, o4 and o5 (o5's with the outcome Connected, marked connected)
--      and one CRM call logged without a telephony call, its outcome Connected; three won order deals: dF whose contact
--      has only an unlinked CRM call with the outcome Connected, dG whose contact's CRM call logs o9, dH whose contact's
--      logs i1. Tenant two holds the same refs. Checked: connected at 1 s and while in progress; Conversation at 29 and
--      30 s, with a not_reached tag, with it removed, with it on a tag that does not count, for inbound calls; the two
--      settings moving the edges; Calls' figures (connected, its rate, conversations, talk time over the answered calls,
--      untagged over every call); tag use and tags per person without an untagged row; per person; a CRM call's
--      conversation through its link only; Attempts per deal; first orders' evidence; the data-quality skip; the
--      meaning's writes, refusals, audit and isolation; the settings' checks and the copy of the old key
-- Amended for addition 0008zd (25 October 2026; 101 runs in dev only): 0008zd adds the tag meaning incorrect_data, so
-- the meaning's check holds seven keys; 103 verifies the addition. What changes, and this check pins:
--   A2  the check holds exactly the seven keys, incorrect_data among them (was six)
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

-- Dev only: a verifier that writes refuses a database without the dev seed. The flag is kept for the session, so every
-- block below stops at once and the verdict says REFUSED, also where the client carries on after the error
select set_config('verify.is_dev', (exists (select 1 from cma.app_user u join cma.tenant t on t.id = u.tenant_id
                                            where u.email = 'agent.two@example.com' and u.status = 'active'))::text, false) as is_dev;
do $$
begin
  if not current_setting('verify.is_dev')::boolean then
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 101 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0008zc;
create temp table verify_0008zc (ord int, check_name text, result text, detail text);

-- The error code a statement raises, or 'ok'
create or replace function pg_temp.v0008zc_code(p_sql text)
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

-- One telephony call as the ingest write takes it: answered p_ring seconds after the start (null: never), ended
-- p_talk seconds after the answer (null: not ended; for a call never answered, ended after 20 seconds), the line
-- n-nl, the user, an invented hash from the id and the current tag set (null: none sent)
create or replace function pg_temp.v0008zc_call(p_src text, p_dir text, p_start timestamptz, p_ring integer, p_talk integer,
                                                p_user text, p_tags jsonb)
returns jsonb
language sql immutable
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'sourceId', p_src, 'direction', p_dir, 'startedAt', p_start,
    'answeredAt', p_start + make_interval(secs => p_ring),
    'endedAt', case when p_ring is null then p_start + interval '20 seconds'
                    else p_start + make_interval(secs => p_ring + p_talk) end,
    'numberRef', 'n-nl', 'userRef', p_user, 'counterpartHash', md5(p_src) || md5(p_src || 'x'), 'tags', p_tags,
    'versionAt', p_start + interval '1 hour'))
$$;

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_fn      text;
  v_bad     text;
  v_txt     text;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  -- A1. the addition is recorded once, after 0008zb
  insert into verify_0008zc values (1, 'A1 addition 0008zc recorded once, after 0008zb',
    case when (select count(*) from cma.schema_migration where version = '0008zc') = 1
              and exists (select 1 from cma.schema_migration where version = '0008zb') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the tag's meaning: a nullable text column, a check holding exactly the seven keys (incorrect_data since 0008zd),
  --     the reader view with it last
  v_bad := '';
  if (select data_type || ':' || is_nullable from information_schema.columns
      where table_schema = 'cma' and table_name = 'telephony_tag' and column_name = 'meaning') is distinct from 'text:YES' then
    v_bad := v_bad || 'the column; ';
  end if;
  select string_agg(m[1], ',' order by m[1]) into v_txt
  from pg_constraint c
  cross join lateral regexp_matches(pg_get_constraintdef(c.oid), '''([a-z_]+)''', 'g') m
  where c.conrelid = 'cma.telephony_tag'::regclass and c.conname = 'telephony_tag_meaning_check';
  if v_txt is distinct from 'call_type,courtesy_attempt,courtesy_completed_negative,courtesy_completed_neutral,courtesy_completed_positive,incorrect_data,not_reached' then
    v_bad := v_bad || 'the keys ' || coalesce(v_txt, 'none') || '; ';
  end if;
  if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'telephony_tag')
     is distinct from 'tenant_id,connection_id,tag_ref,name,is_counted,status,refreshed_at,meaning' then
    v_bad := v_bad || 'cma_read.telephony_tag; ';
  end if;
  if has_table_privilege('cma_app', 'cma.telephony_tag', 'delete') then
    v_bad := v_bad || 'the application deletes tags; ';
  end if;
  insert into verify_0008zc values (2, 'A2 the tag''s meaning: nullable, the seven keys, in the reader view',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A3. the settings: the Conversation threshold (integer, 30), connected from 0, the reached threshold gone from the
  --     catalog, every tenant and the settings check
  v_bad := '';
  if (select value_type || ':' || default_value from cma.setting where key = 'calls.conversation_min_talk_seconds') is distinct from 'integer:30' then
    v_bad := v_bad || 'calls.conversation_min_talk_seconds; ';
  end if;
  if (select value_type || ':' || default_value from cma.setting where key = 'telephony.connected_min_seconds') is distinct from 'integer:0' then
    v_bad := v_bad || 'telephony.connected_min_seconds; ';
  end if;
  if exists (select 1 from cma.setting where key = 'attempts.reached_min_talk_seconds')
     or exists (select 1 from cma.tenant_setting where key = 'attempts.reached_min_talk_seconds') then
    v_bad := v_bad || 'the old key is still there; ';
  end if;
  if (select p.prosrc from pg_proc p where p.oid = to_regprocedure('cma.check_tenant_setting()')) ~ 'reached_min_talk_seconds'
     or (select p.prosrc from pg_proc p where p.oid = to_regprocedure('cma.check_tenant_setting()')) !~ 'calls\.conversation_min_talk_seconds' then
    v_bad := v_bad || 'the settings check; ';
  end if;
  if exists (select 1 from cma.tenant_setting where key = 'calls.conversation_min_talk_seconds' and value !~ '^[0-9]+$') then
    v_bad := v_bad || 'a tenant value; ';
  end if;
  insert into verify_0008zc values (3, 'A3 the settings: the Conversation threshold at 30, connected from 0, the reached threshold gone',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A4. every function exists, executable by the application only, in the caller's rights; the two helpers immutable
  v_bad := '';
  foreach v_fn in array array[
    'cma.set_telephony_tag_meaning(uuid,text,text)', 'cma.call_not_reached_of(uuid,uuid,text)', 'cma.connection_catalogs(uuid)',
    'cma.is_connected(text,boolean,integer,integer)', 'cma.is_conversation(text,boolean,integer,integer,integer,boolean)',
    'cma.calls_of(uuid,timestamptz,timestamptz,text,text)', 'cma.calls_figures_of(uuid,date,date,text,text,text,timestamptz)',
    'cma.calls_overview_of(uuid,date,date,text,text,text,timestamptz)', 'cma.calls_overview(date,date,text,text,text)',
    'cma.calls_tag_use_of(uuid,date,date,text,text,text)', 'cma.calls_per_person_of(uuid,date,date,text,text)',
    'cma.calls_per_person(date,date,text,text)', 'cma.calls_per_person_tags_of(uuid,date,date,text,text)',
    'cma.crm_call_conversation_of(uuid,uuid)', 'cma.email_not_responding_of(uuid,timestamptz)',
    'cma.first_orders_of(uuid,timestamptz,timestamptz)', 'cma.data_quality_of(uuid)',
    'cma.deal_calls_of(uuid,uuid,text,text,text[],timestamptz)', 'cma.lead_calls_of(uuid,uuid,text,text,text[],timestamptz)',
    'cma.deal_attempts_of(uuid,uuid,text,text,text[],timestamptz,timestamptz,text)',
    'cma.attempts_per_deal_of(uuid,timestamptz,timestamptz,timestamptz)', 'cma.attempts_rows_of(uuid,date,date,timestamptz)',
    'cma.attempts_figures_from(cma.attempt_deal[])', 'cma.attempts_outcomes_from(cma.attempt_deal[])',
    'cma.attempts_buckets_from(cma.attempt_deal[],integer)', 'cma.attempts_list_from(cma.attempt_deal[],integer)',
    'cma.attempts_settings_of(uuid)', 'cma.attempts_of_deal(uuid)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' is missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                     where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      v_bad := v_bad || v_fn || ' is not the application''s only, in the caller''s rights; ';
    end if;
  end loop;
  if (select string_agg(provolatile::text, '') from pg_proc
      where oid in (to_regprocedure('cma.is_connected(text,boolean,integer,integer)'),
                    to_regprocedure('cma.is_conversation(text,boolean,integer,integer,integer,boolean)'))) is distinct from 'ii' then
    v_bad := v_bad || 'the helpers are not immutable; ';
  end if;
  if to_regprocedure('cma.deal_attempts_of(uuid,uuid,text,text,text[],timestamptz,timestamptz,text,integer)') is not null then
    v_bad := v_bad || 'the old cma.deal_attempts_of is still there; ';
  end if;
  -- 0008t's name for a CRM call's conversation goes (convention 1: connected is no conversation), and Email reads the new one
  if to_regprocedure('cma.crm_call_connected_of(uuid,uuid)') is not null then
    v_bad := v_bad || 'cma.crm_call_connected_of is still there; ';
  end if;
  if (select p.prosrc from pg_proc p where p.oid = to_regprocedure('cma.email_not_responding_of(uuid,timestamptz)'))
     !~ 'cma\.crm_call_conversation_of\(.*k\.is_conversation' then
    v_bad := v_bad || 'cma.email_not_responding_of does not read the conversation; ';
  end if;
  insert into verify_0008zc values (4, 'A4 every function the application''s only and invoker; the helpers immutable; the old names gone',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A5. the reads use the helpers (Connected and Conversation written once), never a CRM call outcome's flag and never the
  --     reached threshold; the data-quality skip by its own rule
  v_bad := '';
  foreach v_fn in array array['cma.calls_of(uuid,timestamptz,timestamptz,text,text)', 'cma.crm_call_conversation_of(uuid,uuid)',
                               'cma.first_orders_of(uuid,timestamptz,timestamptz)', 'cma.deal_calls_of(uuid,uuid,text,text,text[],timestamptz)'] loop
    if (select p.prosrc from pg_proc p where p.oid = to_regprocedure(v_fn)) !~ 'cma\.is_conversation\('
       or (select p.prosrc from pg_proc p where p.oid = to_regprocedure(v_fn)) !~ 'cma\.call_not_reached_of\('
       or (select p.prosrc from pg_proc p where p.oid = to_regprocedure(v_fn)) ~ 'is_connected\s*,\s*false|o\.is_connected|outcome_connected' then
      v_bad := v_bad || v_fn || '; ';
    end if;
  end loop;
  if exists (select 1 from pg_proc p where p.pronamespace in ('cma'::regnamespace, 'cma_read'::regnamespace)
             and p.prosrc ~ 'attempts\.reached_min_talk_seconds' and p.proname <> 'check_tenant_setting') then
    v_bad := v_bad || 'a function reads the reached threshold; ';
  end if;
  if (select p.prosrc from pg_proc p where p.oid = to_regprocedure('cma.data_quality_of(uuid)')) ~ 'connected_min_seconds'
     or (select p.prosrc from pg_proc p where p.oid = to_regprocedure('cma.data_quality_of(uuid)')) !~ 'tc\.answered_at is null' then
    v_bad := v_bad || 'the data-quality skip; ';
  end if;
  insert into verify_0008zc values (5, 'A5 the reads use the helpers, no CRM call outcome and no reached threshold; the skip by its own rule',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A6. no output column of a function and no reader view's column is named reached (the tag meaning's not_reached aside);
  --     the reader view of attempts per deal with its exact columns
  select string_agg(distinct x, ', ') into v_txt
  from (select p.proname || '.' || a.name as x
        from pg_proc p
        cross join lateral unnest(coalesce(p.proargnames, '{}'::text[]), coalesce(p.proargmodes::text[], '{}'::text[])) as a(name, mode)
        where p.pronamespace in ('cma'::regnamespace, 'cma_read'::regnamespace) and a.mode in ('t', 'o')
          and a.name ~ '(^|_)reached' and a.name !~ 'not_reached'
        union all
        select c.table_name || '.' || c.column_name from information_schema.columns c
        where c.table_schema = 'cma_read' and c.column_name ~ '(^|_)reached' and c.column_name !~ 'not_reached'
        union all
        select 'cma.attempt_deal.' || a.attname from pg_attribute a
        where a.attrelid = (select t.typrelid from pg_type t where t.oid = to_regtype('cma.attempt_deal')) and a.attname ~ '(^|_)reached'
          and not a.attisdropped) z;
  if (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
      where table_schema = 'cma_read' and table_name = 'attempts_per_deal')
     is distinct from 'tenant_id,deal_id,connection_id,deal_source_id,pipeline_id,pipeline_label,stage_id,market,owner_user_id,created_at,business_date,is_closed,closed_at,ordered_at,window_end_reason,outcome,attempts,conversation_attempts,first_conversation_attempt,talk_seconds_total,talk_seconds_conversation,first_attempt_at,speed_to_lead_seconds,called_before_next_noon,last_attempt_at,business_days_since_last,since_last_bucket,attempts_without_outcome,logged_without_aircall' then
    v_txt := coalesce(v_txt || '; ', '') || 'cma_read.attempts_per_deal';
  end if;
  insert into verify_0008zc values (6, 'A6 no column of a function, a reader view or the row type named reached; attempts_per_deal''s columns',
    case when v_txt is null and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, ''));
end
$$;

-- B. Behaviour on two throwaway tenants (rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_rows     text[] := '{}';
  v_t1 uuid; v_t2 uuid;
  v_admin1 uuid; v_analyst1 uuid; v_agent1 uuid; v_anna uuid; v_bram uuid; v_ing1 uuid;
  v_admin2 uuid; v_ing2 uuid;
  v_crm uuid; v_tel uuid; v_tel2 uuid;
  v_dw uuid;
  v_txt text; v_detail text; v_s text;
  j jsonb;
  v_d    timestamptz := timestamptz '2026-10-06 08:00:00+00';   -- Tuesday 6 October 2026, 10:00 in Amsterdam
  v_now  timestamptz := timestamptz '2026-10-14 10:00:00+00';
  v_nr   jsonb := '[{"tagRef": "tg-nr", "name": "Not Reached"}]';
  v_off  jsonb := '[{"tagRef": "tg-nr-off", "name": "Not Reached off"}]';
  v_type jsonb := '[{"tagRef": "tg-type", "name": "Type"}]';
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    -- tenants, people and roles (as the owner)
    v_t1 := cma.create_tenant('verify-0008zc-one', 'Verify 0008zc one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008zc-two', 'Verify 0008zc two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-analyst1@example.invalid', 'analyst1') returning id into v_analyst1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent1@example.invalid', 'agent1') returning id into v_agent1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-anna@example.invalid', 'Anna Verify') returning id into v_anna;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-bram@example.invalid', 'Bram Verify') returning id into v_bram;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin2') returning id into v_admin2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_analyst1, 'analytics'), (v_t1, v_agent1, 'agent'), (v_t1, v_anna, 'agent'),
                 (v_t1, v_bram, 'agent'), (v_t2, v_admin2, 'admin')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    select x.user_id into v_ing2 from cma.app_user_external_id x where x.tenant_id = v_t2 and x.system = 'ingest';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifycrm', 'Verify definitions CRM', 'portal-1', 'crm') returning id into v_crm;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifytel', 'Verify definitions telephony', 'tel-1', 'telephony') returning id into v_tel;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t2, 'verifytel', 'Verify definitions telephony two', 'tel-2', 'telephony') returning id into v_tel2;
    perform set_config('role', 'cma_app', true);

    -- tenant one's configuration (the admin): the market, the settings, the people's telephony users
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.set_business_hours('*', d::smallint, '09:00-17:00') from generate_series(1, 5) d;
    perform cma.set_tenant_setting('intake.start_date', '2026-09-01');
    perform cma.set_user_external_id(v_anna, 'verifytel_user', 'tu-1');
    perform cma.set_user_external_id(v_bram, 'verifytel_user', 'tu-2');

    -- the catalogs from the sources (the Ingest user)
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_pipelines(v_crm, '[
      {"recordType": "deal", "pipelineId": "sales", "label": "Sales", "stages": [
         {"stageId": "s1", "label": "Open", "order": 1, "isClosed": false, "outcome": null},
         {"stageId": "sw", "label": "Won", "order": 8, "isClosed": true, "outcome": "won"}]},
      {"recordType": "deal", "pipelineId": "selfserve", "label": "Self Serve", "stages": [{"stageId": "o1", "label": "Won", "order": 1, "isClosed": true, "outcome": "won"}]}]');
    perform cma.ingest_upsert_call_outcomes(v_crm, '[{"outcomeRef": "connected", "label": "Connected"}]');
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'number', '[{"numberRef": "n-nl", "name": "Verify NL line", "digits": "+31000000001"}]');
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'tag', '[{"tagRef": "tg-nr", "name": "Not Reached"},
      {"tagRef": "tg-nr-off", "name": "Not Reached off"}, {"tagRef": "tg-type", "name": "Type"}]');

    -- their configuration (the admin): the order pipeline, the outcome Connected marked connected, the line, the meanings,
    -- Not Reached off not counted
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_pipeline_order(v_crm, 'deal', 'selfserve', true);
    perform cma.set_call_outcome(v_crm, 'connected', true);
    perform cma.set_telephony_number(v_tel, 'n-nl', 'NL', true);
    perform cma.set_telephony_tag_meaning(v_tel, 'tg-nr', 'not_reached');
    perform cma.set_telephony_tag_meaning(v_tel, 'tg-nr-off', 'not_reached');
    perform cma.set_telephony_tag_meaning(v_tel, 'tg-type', 'call_type');
    perform cma.set_telephony_tag(v_tel, 'tg-nr-off', false);

    -- the telephony calls of 6 October (the Ingest user): five seconds of ringing, then the talk
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
      pg_temp.v0008zc_call('o1', 'outbound', v_d,                           5, 1,    'tu-1', null),
      pg_temp.v0008zc_call('o2', 'outbound', v_d + interval '10 minutes',  5, null, 'tu-1', null),
      pg_temp.v0008zc_call('o3', 'outbound', v_d + interval '20 minutes',  5, 29,   'tu-1', null),
      pg_temp.v0008zc_call('o4', 'outbound', v_d + interval '30 minutes',  5, 30,   'tu-1', null),
      pg_temp.v0008zc_call('o5', 'outbound', v_d + interval '40 minutes',  5, 30,   'tu-1', v_nr),
      pg_temp.v0008zc_call('o6', 'outbound', v_d + interval '50 minutes',  5, 120,  'tu-1', v_nr),
      pg_temp.v0008zc_call('o7', 'outbound', v_d + interval '60 minutes',  5, 60,   'tu-1', v_off),
      pg_temp.v0008zc_call('o8', 'outbound', v_d + interval '70 minutes',  null, null, 'tu-1', null),
      pg_temp.v0008zc_call('o9', 'outbound', v_d + interval '80 minutes',  5, 45,   'tu-1', v_type),
      pg_temp.v0008zc_call('i1', 'inbound',  v_d + interval '90 minutes',  5, 20,   'tu-2', null),
      pg_temp.v0008zc_call('i2', 'inbound',  v_d + interval '100 minutes', 5, 45,   'tu-2', null),
      pg_temp.v0008zc_call('i3', 'inbound',  v_d + interval '110 minutes', 5, 45,   'tu-2', v_nr),
      pg_temp.v0008zc_call('i4', 'inbound',  v_d + interval '120 minutes', null, null, null, null)));
    -- o6's Not Reached removed later: an empty tag set closes it
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
      pg_temp.v0008zc_call('o6', 'outbound', v_d + interval '50 minutes', 5, 120, 'tu-1', '[]'::jsonb)
        || jsonb_build_object('versionAt', v_d + interval '5 hours')));

    -- the CRM: a sales deal dW (contact kW) and three won order deals (contacts kF, kG, kH); the CRM calls, ten seconds after
    -- the telephony calls they log, with the same hash: cw3, cw4 and cw5 log o3, o4 and o5 (cw5 with the outcome Connected),
    -- cwx is logged without a telephony call, its outcome Connected; cf1 too (dF's contact); cg1 logs o9, ch1 logs i1
    perform cma.ingest_upsert_records(v_crm, '[
      {"recordType": "deal", "sourceId": "dW", "pipelineId": "sales",     "stageId": "s1", "ownerRef": "o-1", "contactId": "kW", "market": "NL", "createdAt": "2026-10-06T07:00:00Z", "updatedAt": "2026-10-06T07:00:00Z"},
      {"recordType": "deal", "sourceId": "dF", "pipelineId": "selfserve", "stageId": "o1", "ownerRef": "o-1", "contactId": "kF", "market": "NL", "createdAt": "2026-10-09T12:00:00Z", "closedAt": "2026-10-09T12:00:00Z", "updatedAt": "2026-10-09T12:00:00Z"},
      {"recordType": "deal", "sourceId": "dG", "pipelineId": "selfserve", "stageId": "o1", "ownerRef": "o-1", "contactId": "kG", "market": "NL", "createdAt": "2026-10-09T12:00:00Z", "closedAt": "2026-10-09T12:00:00Z", "updatedAt": "2026-10-09T12:00:00Z"},
      {"recordType": "deal", "sourceId": "dH", "pipelineId": "selfserve", "stageId": "o1", "ownerRef": "o-1", "contactId": "kH", "market": "NL", "createdAt": "2026-10-09T12:00:00Z", "closedAt": "2026-10-09T12:00:00Z", "updatedAt": "2026-10-09T12:00:00Z"}]');
    perform cma.ingest_upsert_contacts(v_crm, (
      select jsonb_agg(jsonb_build_object('sourceId', k, 'country', 'NL', 'updatedAt', '2026-10-01T00:00:00Z'))
      from unnest(array['kW', 'kF', 'kG', 'kH']) k));
    perform cma.ingest_upsert_calls(v_crm, (
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('sourceId', c.id, 'occurredAt', c.at, 'direction', c.dir, 'outcomeRef', c.outcome,
                                                            'ownerRef', 'o-1', 'counterpartHash', case when c.tel is not null then md5(c.tel) || md5(c.tel || 'x') end,
                                                            'updatedAt', c.at)))
      from (values
        ('cw3', v_d + interval '20 minutes 10 seconds', 'outbound', null,        'o3'),
        ('cw4', v_d + interval '30 minutes 10 seconds', 'outbound', null,        'o4'),
        ('cw5', v_d + interval '40 minutes 10 seconds', 'outbound', 'connected', 'o5'),
        ('cwx', v_d + interval '4 hours',               'outbound', 'connected', null),
        ('cf1', v_d + interval '4 hours',               'outbound', 'connected', null),
        ('cg1', v_d + interval '80 minutes 10 seconds', 'outbound', null,        'o9'),
        ('ch1', v_d + interval '90 minutes 10 seconds', 'inbound',  null,        'i1')) c(id, at, dir, outcome, tel)));
    perform cma.ingest_upsert_associations(v_crm, (
      select jsonb_agg(jsonb_build_object('fromType', 'crm_call', 'fromId', a.c, 'toType', 'contact', 'toId', a.k, 'removed', false,
                                          'changedAt', '2026-10-01T00:00:00Z'))
      from (values ('cw3', 'kW'), ('cw4', 'kW'), ('cw5', 'kW'), ('cwx', 'kW'), ('cf1', 'kF'), ('cg1', 'kG'), ('ch1', 'kH')) a(c, k)));
    perform cma.link_calls('2026-09-01T00:00:00Z');

    -- tenant two: the same line and tag refs
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_ing2::text, true);
    perform cma.ingest_upsert_telephony_catalog(v_tel2, 'tag', '[{"tagRef": "tg-nr", "name": "Not Reached"}]');

    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);
    select r.id into v_dw from cma.crm_record r where r.tenant_id = v_t1 and r.source_id = 'dW';

    -- B1. Connected and Conversation per call (cma.calls_of): connected at 1 s and while answered and in progress, never
    --     unanswered; Conversation at 30 s not 29, not with a not_reached tag, again once it is removed, not with
    --     not_reached on a tag that does not count; inbound at 45 s not 20, not with not_reached
    select string_agg(format('%s:%s%s', x.src, case when c.is_connected_outbound then 'c' else '-' end, case when c.is_conversation then 'v' else '-' end),
                      ' ' order by x.src)
      into v_txt
    from cma.calls_of(v_t1, v_d - interval '1 day', v_d + interval '1 day', null, null) c
    join lateral (select tc.source_id as src from cma.telephony_call tc
                  where tc.tenant_id = v_t1 and tc.connection_id = c.connection_id and tc.started_at = c.started_at) x on true;
    v_rows := v_rows || array['11', 'B1 connected at 1 s and in progress; Conversation at 30 s, without not_reached (removed, or on an uncounted tag still out), inbound alike',
      case when v_txt = 'i1:-- i2:-v i3:-- i4:-- o1:c- o2:c- o3:c- o4:cv o5:c- o6:cv o7:c- o8:-- o9:cv' and not v_provoke then 'PASS' else 'FAIL' end,
      coalesce(v_txt, 'no rows')];

    -- B2. the settings move the edges: telephony.connected_min_seconds 5 leaves o1 (1 s) and o2 (no talk yet) not connected;
    --     calls.conversation_min_talk_seconds 29 makes o3 a conversation, 46 leaves only o6 (120 s)
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('telephony.connected_min_seconds', '5');
    select string_agg(format('%s/%s', connected, conversations), '') into v_detail
    from cma.calls_overview_of(v_t1, date '2026-10-06', date '2026-10-06', null, null, 'day', v_now) where period = 'current' and group_key is null;
    perform cma.set_tenant_setting('telephony.connected_min_seconds', null);
    perform cma.set_tenant_setting('calls.conversation_min_talk_seconds', '29');
    select v_detail || ' ' || string_agg(format('%s/%s', connected, conversations), '') into v_detail
    from cma.calls_overview_of(v_t1, date '2026-10-06', date '2026-10-06', null, null, 'day', v_now) where period = 'current' and group_key is null;
    perform cma.set_tenant_setting('calls.conversation_min_talk_seconds', '46');
    select v_detail || ' ' || string_agg(format('%s/%s', connected, conversations), '') into v_detail
    from cma.calls_overview_of(v_t1, date '2026-10-06', date '2026-10-06', null, null, 'day', v_now) where period = 'current' and group_key is null;
    perform cma.set_tenant_setting('calls.conversation_min_talk_seconds', null);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['12', 'B2 connected from 5 s leaves 1 s and in progress out; the Conversation threshold at 29 and 46 s',
      case when v_detail = '6/4 8/5 8/1' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_detail, 'no rows')];

    -- B3. Reports, Calls as the application reads it: 13 calls, 4 inbound, 9 outbound, 3 answered inbound, 8 connected
    --     (88.9 of the outbound), 4 conversations; talk time over the 10 answered calls with talk time (425 s, 42.5 on
    --     average; o2 has none yet); the connected calls' talk 315 s, 45.0 on average; untagged 9 of the 13 calls (o6
    --     untagged again, the missed i4 included)
    select format('%s/%s/%s/%s/%s/%s/%s/%s/%s/%s/%s/%s', calls, inbound, outbound, answered_inbound, connected, connected_rate, conversations,
                  talk_seconds_total, talk_seconds_avg, outbound_talk_seconds, outbound_talk_avg, untagged) into v_txt
    from cma.calls_overview('2026-10-05', '2026-10-11', null, null, 'week') where period = 'current' and group_key is null;
    v_rows := v_rows || array['13', 'B3 Calls: connected and its rate, conversations, talk time over the answered calls, untagged over every call',
      case when v_txt = '13/4/9/3/8/88.9/4/425/42.5/315/45.0/9' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no row')];

    -- B4. tag use and tags per person: the conversations per tag (o9's Type only; a not_reached tag is on no conversation),
    --     no untagged row; per person connected, conversations and untagged over their own calls (Anna 9 outbound, 8
    --     connected, 3 conversations, 6 untagged; Bram 3 answered, 1 conversation, 2 untagged; the missed i4 in no row)
    select string_agg(coalesce(group_key, 'all') || ':' || coalesce(tag_name, '-') || '=' || conversations, ',' order by ordinality) into v_txt
    from cma.calls_tag_use('2026-10-05', '2026-10-11', null, null, 'week') with ordinality;
    select v_txt || ' | ' || string_agg(coalesce(tag_name, '-') || '=' || conversations, ',') into v_txt
    from cma.calls_per_person_tags('2026-10-05', '2026-10-11', null, null);
    select v_txt || ' | ' || string_agg(format('%s:%s/%s/%s/%s/%s', coalesce(display_name, row_kind), answered_inbound, outbound_calls, connected,
                                               conversations, untagged), ' ' order by row_kind = 'total', display_name) into v_txt
    from cma.calls_per_person('2026-10-05', '2026-10-11', null, null);
    v_rows := v_rows || array['14', 'B4 tag use and tags per person count conversations, no untagged row; per person connected, conversations, untagged',
      case when v_txt = '2026-10-05:Type=1,all:Type=1 | Type=1 | Anna Verify:0/9/8/3/6 Bram Verify:3/0/0/1/2 total:3/9/8/4/8'
            and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no rows')];

    -- B5. a CRM call is a conversation through its linked telephony call only, at that call's start: cw4 (o4) is, cw5 (o5,
    --     not_reached) is not though its outcome is marked connected, cwx (no telephony call, outcome Connected) is not and
    --     has no time
    select string_agg(format('%s:%s/%s', c.source_id, k.is_conversation, coalesce(to_char(k.effective_at at time zone 'UTC', 'HH24:MI'), '-')), ' '
                      order by c.source_id) into v_txt
    from cma.crm_call c cross join lateral cma.crm_call_conversation_of(v_t1, c.id) k
    where c.tenant_id = v_t1 and c.source_id in ('cw4', 'cw5', 'cwx');
    v_rows := v_rows || array['15', 'B5 a CRM call is a conversation through its telephony call only; an unlinked one with an outcome marked connected is not',
      case when v_txt = 'cw4:t/08:30 cw5:f/08:40 cwx:f/-' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no rows')];

    -- B6. Attempts per deal: dW's three linked attempts, one conversation (the second), talk 89 s in all and 30 s on the
    --     conversations, two attempts without an outcome, cwx logged without a telephony call; one deal's attempts connected
    --     and conversation per attempt; the page's figures
    select format('%s/%s/%s/%s/%s/%s/%s', x.attempts, x.conversation_attempts, coalesce(x.first_conversation_attempt::text, '-'), x.talk_seconds_total,
                  x.talk_seconds_conversation, x.attempts_without_outcome, x.logged_without_aircall) into v_txt
    from cma.attempts_per_deal_of(v_t1, timestamptz '2026-10-04 22:00:00+00', timestamptz '2026-10-11 22:00:00+00', v_now) x
    where x.deal_source_id = 'dW';
    perform set_config('app.user_id', v_admin1::text, true);
    select v_txt || ' | ' || string_agg(format('%s:%s/%s/%s', a.n, a.connected, coalesce(a.talk_seconds::text, '-'), a.conversation), ' ' order by a.n)
      into v_txt from cma.attempts_of_deal(v_dw) a;
    j := cma.attempts_per_deal_page_of(v_t1, date '2026-10-05', date '2026-10-11', 'day', null, null, 'all', 'all', 100, v_now);
    v_txt := v_txt || ' | ' || format('%s/%s/%s/%s', j -> 'current' ->> 'conversation_deals', j -> 'current' ->> 'first_conversation',
                                      j -> 'current' ->> 'conversation_attempts', j -> 'current' ->> 'talk_seconds_conversation')
             || ' ' || (j -> 'settings' ->> 'conversation_min_talk_seconds');
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['16', 'B6 Attempts per deal: conversations from the telephony call, the outcome deciding nothing',
      case when v_txt = '3/1/2/89/30/2/1 | 1:t/29/f 2:t/30/t 3:t/30/f | 1/0/1/30 30' and not v_provoke then 'PASS' else 'FAIL' end,
      coalesce(v_txt, 'no rows')];

    -- B7. first orders' evidence from the linked telephony call: dF (an unlinked CRM call, outcome Connected) none; dG (o9,
    --     outbound 45 s) a conversation and an attempt; dH (i1, inbound 20 s) neither
    select string_agg(format('%s:%s/%s/%s', f.deal_source_id, f.conversation, f.attempt, f.level), ' ' order by f.deal_source_id) into v_txt
    from cma.first_orders_of(v_t1, timestamptz '2026-10-09 00:00:00+00', timestamptz '2026-10-10 00:00:00+00') f;
    v_rows := v_rows || array['17', 'B7 first orders: a conversation and an attempt from the telephony call only; an outcome and an inbound non-conversation none',
      case when v_txt = 'dF:f/f/self_service dG:t/t/conversation dH:f/f/self_service' and not v_provoke then 'PASS' else 'FAIL' end,
      coalesce(v_txt, 'no rows')];

    -- B8. the data-quality check telephony_call_unlinked skips an outbound call not connected and untagged (o8) only: o1
    --     (answered at 1 s), o2 (in progress), o6, o7 and the inbound i2, i3 and i4 without a link are listed
    select string_agg(tc.source_id, ' ' order by tc.source_id) into v_txt
    from cma.data_quality_of(v_t1) q
    join cma.telephony_call tc on tc.tenant_id = v_t1 and tc.connection_id = q.connection_id and tc.source_id = q.object_id
    where q.check_key = 'telephony_call_unlinked';
    v_rows := v_rows || array['18', 'B8 the unlinked check skips an outbound call not connected and untagged, by its own rule',
      case when v_txt = 'i2 i3 i4 o1 o2 o6 o7' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'none')];

    -- B9. the meaning: on the Sources page's catalogs; a key outside the seven and a wrong case refused, none clears it; an
    --     agent, the Ingest user and no acting user refused
    perform set_config('app.user_id', v_admin1::text, true);
    select string_agg(t ->> 'tagRef' || '=' || coalesce(t ->> 'meaning', '-'), ' ' order by t ->> 'tagRef') into v_txt
    from jsonb_array_elements(cma.connection_catalogs(v_tel) -> 'tags') t;
    v_txt := v_txt || ' | ' || pg_temp.v0008zc_code(format('select cma.set_telephony_tag_meaning(%L, %L, %L)', v_tel, 'tg-type', 'voicemail'))
             || ' ' || pg_temp.v0008zc_code(format('select cma.set_telephony_tag_meaning(%L, %L, %L)', v_tel, 'tg-type', 'Not_Reached'));
    perform cma.set_telephony_tag_meaning(v_tel, 'tg-type', null);
    v_txt := v_txt || ' ' || coalesce((select g.meaning from cma.telephony_tag g where g.connection_id = v_tel and g.tag_ref = 'tg-type'), 'none');
    perform cma.set_telephony_tag_meaning(v_tel, 'tg-type', 'call_type');
    perform set_config('app.user_id', v_agent1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008zc_code(format('select cma.set_telephony_tag_meaning(%L, %L, null)', v_tel, 'tg-nr'));
    perform set_config('app.user_id', v_ing1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008zc_code(format('select cma.set_telephony_tag_meaning(%L, %L, null)', v_tel, 'tg-nr'));
    perform set_config('app.user_id', '', true);
    v_txt := v_txt || ' ' || pg_temp.v0008zc_code(format('select cma.set_telephony_tag_meaning(%L, %L, null)', v_tel, 'tg-nr'));
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['19', 'B9 the meaning on the catalogs; an invalid key refused, none clears it; an agent, the Ingest user and no acting user refused',
      case when v_txt = 'tg-nr=not_reached tg-nr-off=not_reached tg-type=call_type | CMA04 CMA04 none CMA06 CMA06 CMA01' and not v_provoke then 'PASS' else 'FAIL' end,
      coalesce(v_txt, 'no rows')];

    -- B10. configuration only: a catalog refresh renames a tag and keeps its meaning and is_counted; a tag a call brings is
    --      added without a meaning; the audit names the admin for each meaning set
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'tag', '[{"tagRef": "tg-nr", "name": "Not Reached renamed"},
      {"tagRef": "tg-nr-off", "name": "Not Reached off"}, {"tagRef": "tg-type", "name": "Type"}]');
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
      pg_temp.v0008zc_call('o10', 'outbound', v_d + interval '1 day', 5, 40, 'tu-1', '[{"tagRef": "tg-new", "name": "New"}]'::jsonb)));
    perform set_config('role', 'cma_owner', true);
    select string_agg(g.tag_ref || '=' || g.name || '/' || coalesce(g.meaning, '-') || '/' || g.is_counted, ' ' order by g.tag_ref) into v_txt
    from cma.telephony_tag g where g.tenant_id = v_t1 and g.connection_id = v_tel;
    select v_txt || ' | ' || count(*) || ' by the admin' into v_txt
    from cma.audit_log a
    where a.tenant_id = v_t1 and a.table_name = 'telephony_tag' and a.actor_user_id = v_admin1
      and (a.new_row ->> 'meaning') is distinct from (a.old_row ->> 'meaning');
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['20', 'B10 a refresh keeps the meaning, a new tag has none; the audit names the admin',
      case when v_txt = 'tg-new=New/-/true tg-nr=Not Reached renamed/not_reached/true tg-nr-off=Not Reached off/not_reached/false tg-type=Type/call_type/true | 5 by the admin'
            and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no rows')];

    -- B11. tenant isolation: tenant two's admin can neither read nor set tenant one's meaning (CMA02 for the connection, no
    --      row seen), and tenant one's meaning stays; tenant two's own tag of the same ref has none
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    v_txt := pg_temp.v0008zc_code(format('select cma.set_telephony_tag_meaning(%L, %L, null)', v_tel, 'tg-nr'))
             || ' ' || pg_temp.v0008zc_code(format('select cma.connection_catalogs(%L)', v_tel))
             || ' ' || (select count(*) from cma.telephony_tag g where g.connection_id = v_tel)
             || ' ' || (select coalesce(string_agg(g.tag_ref || '=' || coalesce(g.meaning, '-'), ' '), 'none') from cma.telephony_tag g);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_txt := v_txt || ' | ' || (select g.meaning from cma.telephony_tag g where g.connection_id = v_tel and g.tag_ref = 'tg-nr');
    v_rows := v_rows || array['21', 'B11 another tenant can neither read nor set a tenant''s meaning',
      case when v_txt = 'CMA02 CMA02 0 tg-nr=- | not_reached' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no rows')];

    -- B12. the settings' checks: the Conversation threshold 0 to 600 only; the reached threshold unknown; and 0008zc's copy of
    --      the old key, rerun on tenant one with the old key put back for it: its value carried over, the old key gone
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := '';
    foreach v_s in array array['-1', '601', 'x', '0', '600'] loop
      v_txt := v_txt || pg_temp.v0008zc_code(format('select cma.set_tenant_setting(%L, %L)', 'calls.conversation_min_talk_seconds', v_s)) || ' ';
    end loop;
    perform cma.set_tenant_setting('calls.conversation_min_talk_seconds', null);
    v_txt := v_txt || pg_temp.v0008zc_code(format('select cma.set_tenant_setting(%L, %L)', 'attempts.reached_min_talk_seconds', '30'));
    perform set_config('role', 'cma_owner', true);
    insert into cma.setting (key, value_type, allowed_values, default_value, description)
    values ('attempts.reached_min_talk_seconds', 'integer', null, '30', 'put back for B12 only, rolled back');
    insert into cma.tenant_setting (tenant_id, key, value) values (v_t1, 'attempts.reached_min_talk_seconds', '45');
    -- 0008zc's statements, as 100 runs them
    insert into cma.tenant_setting (tenant_id, key, value)
    select ts.tenant_id, 'calls.conversation_min_talk_seconds', ts.value
    from cma.tenant_setting ts
    where ts.key = 'attempts.reached_min_talk_seconds'
    on conflict (tenant_id, key) do nothing;
    delete from cma.tenant_setting where key = 'attempts.reached_min_talk_seconds';
    delete from cma.setting where key = 'attempts.reached_min_talk_seconds';
    v_txt := v_txt || ' | ' || cma.setting_of(v_t1, 'calls.conversation_min_talk_seconds')
             || ' ' || (select count(*) from cma.tenant_setting where key = 'attempts.reached_min_talk_seconds')
             || ' ' || (select count(*) from cma.setting where key = 'attempts.reached_min_talk_seconds');
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['22', 'B12 the Conversation threshold 0 to 600; the reached threshold unknown; the old key''s value copied, the key gone',
      case when v_txt = 'CMA04 CMA04 CMA04 ok ok CMA02 | 45 0 0' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no rows')];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['39', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008zc (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008zc values (39, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008zc
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED: not dev'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008zc where result = 'PASS') = 18
                       and not exists (select 1 from verify_0008zc where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0008zc where result = 'PASS'),
                                        (select count(*) from verify_0008zc where result <> 'PASS'))) x
order by ord;
drop function if exists pg_temp.v0008zc_code(text);
drop function if exists pg_temp.v0008zc_call(text, text, timestamptz, integer, integer, text, jsonb);
reset role;
