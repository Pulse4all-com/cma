-- =============================================================================================
-- 103_verify_tag_meaning_incorrect_data.sql: verifies addition 0008zd, the tag meaning incorrect data
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure and privileges;
-- block B works on two throwaway tenants inside a subtransaction that is always rolled back. Universal otherwise:
-- nothing of the seed is used; adapters, lines, tags, users, deals, contacts, calls and hashes are invented data
-- values (no hash below is made from a real number). Every check writes one row, PASS or FAIL, and the last result
-- lists them with the verdict, because Cloud SQL Studio shows no notices. Run as your own IAM login in dev, after
-- 102_tag_meaning_incorrect_data.sql; then 101 again.
--   A  structure and privileges: the addition row after 0008zc; the meaning's check with its seven keys, the setter and
--      the setting's description naming incorrect_data; the meanings that exclude a call from Conversation written once
--      (cma.tag_meaning_excludes_conversation, read by cma.call_not_reached_of, no other function naming a meaning key
--      but the setter); every function the application's only and in the caller's rights, nothing renamed
--   B  behaviour. Tenant one (Europe/Amsterdam; a CRM and a telephony connection; one NL line; tags Wrong Number
--      (meaning incorrect_data), Incorrect Data off (incorrect_data, not counted), Not Reached (not_reached) and Type
--      (call_type); Anna linked to the telephony user of the outbound calls, Bram to the inbound one) with twelve
--      telephony calls on 6 October 2026, five seconds of ringing, then the talk:
--        o1 outbound 45 s, tagged Wrong Number          o7 outbound, nobody answered, tagged Wrong Number
--        o2 outbound 45 s, untagged                     o8 outbound 45 s, tagged Type and Wrong Number
--        o3 outbound 45 s, tagged Not Reached           o9 outbound 60 s, tagged Wrong Number
--        o4 outbound 45 s, tagged Incorrect Data off    i1 inbound answered 45 s, tagged Wrong Number
--        o5 outbound 45 s, tagged Type                  i2 inbound answered 45 s, untagged
--        o6 outbound 10 s, tagged Wrong Number          i3 inbound answered 45 s, tagged Not Reached
--      a sales deal dW whose contact's CRM calls log o1 and o2, and a won order deal dG whose contact's CRM call logs
--      o9. Tenant two holds the same tag ref. Checked: Connected unaffected and Conversation excluded by a current tag
--      meaning incorrect data (on a tag that does not count too, next to another tag too, inbound alike) and by not
--      reached as before; Calls' figures, per person and tag use; a CRM call's conversation and Attempts per deal; first
--      orders' evidence; the same call a conversation once its tag is removed; the meaning's writes and refusals, one
--      meaning per tag, the audit and tenant isolation
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
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 103 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0008zd;
create temp table verify_0008zd (ord int, check_name text, result text, detail text);

-- The error code a statement raises, or 'ok'
create or replace function pg_temp.v0008zd_code(p_sql text)
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
-- p_talk seconds after the answer (for a call never answered, ended after 20 seconds), the line n-nl, the user, an
-- invented hash from the id and the current tag set (null: none sent)
create or replace function pg_temp.v0008zd_call(p_src text, p_dir text, p_start timestamptz, p_ring integer, p_talk integer,
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
  -- A1. the addition is recorded once, after 0008zc
  insert into verify_0008zd values (1, 'A1 addition 0008zd recorded once, after 0008zc',
    case when (select count(*) from cma.schema_migration where version = '0008zd') = 1
              and exists (select 1 from cma.schema_migration where version = '0008zc') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the meaning: still a nullable text column, its check holding exactly the seven keys; the setter and the
  --     Conversation threshold's description name incorrect data
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
  if (select p.prosrc from pg_proc p where p.oid = to_regprocedure('cma.set_telephony_tag_meaning(uuid,text,text)')) !~ '''incorrect_data''' then
    v_bad := v_bad || 'the setter; ';
  end if;
  if (select description from cma.setting where key = 'calls.conversation_min_talk_seconds') !~ 'not reached or incorrect data' then
    v_bad := v_bad || 'the setting''s description; ';
  end if;
  insert into verify_0008zd values (2, 'A2 the meaning''s check holds the seven keys; the setter and the setting name incorrect data',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A3. the meanings that exclude a call from Conversation are written once: the helper answers true for not_reached and
  --     incorrect_data only (never null), cma.call_not_reached_of reads it and names no key, and no other function of cma
  --     or cma_read names a meaning key but the setter
  v_bad := '';
  select string_agg(case when cma.tag_meaning_excludes_conversation(k) then 't' when not cma.tag_meaning_excludes_conversation(k) then 'f'
                         else 'n' end, '' order by o) into v_txt
  from unnest(array['not_reached', 'incorrect_data', 'call_type', 'courtesy_attempt', 'courtesy_completed_positive',
                    'courtesy_completed_neutral', 'courtesy_completed_negative', 'Incorrect_Data', null]) with ordinality as x(k, o);
  if v_txt is distinct from 'ttfffffff' then
    v_bad := v_bad || 'the helper answers ' || coalesce(v_txt, 'nothing') || '; ';
  end if;
  if (select p.prosrc from pg_proc p where p.oid = to_regprocedure('cma.call_not_reached_of(uuid,uuid,text)')) !~ 'cma\.tag_meaning_excludes_conversation\(tg\.meaning\)'
     or (select p.prosrc from pg_proc p where p.oid = to_regprocedure('cma.call_not_reached_of(uuid,uuid,text)')) ~ '''[a-z_]+''' then
    v_bad := v_bad || 'cma.call_not_reached_of does not read the helper alone; ';
  end if;
  select string_agg(p.proname, ',' order by p.proname) into v_txt
  from pg_proc p
  where p.pronamespace in ('cma'::regnamespace, 'cma_read'::regnamespace) and p.prosrc ~ '''(not_reached|incorrect_data)''';
  if v_txt is distinct from 'set_telephony_tag_meaning,tag_meaning_excludes_conversation' then
    v_bad := v_bad || 'functions naming a meaning key: ' || coalesce(v_txt, 'none') || '; ';
  end if;
  insert into verify_0008zd values (3, 'A3 the meanings excluding a call from Conversation written once, read by cma.call_not_reached_of',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A4. the three functions exist, executable by the application only, in the caller's rights; the helper immutable;
  --     nothing renamed: cma.call_not_reached_of answers not_reached and cma.is_conversation takes p_not_reached
  v_bad := '';
  foreach v_fn in array array['cma.set_telephony_tag_meaning(uuid,text,text)', 'cma.tag_meaning_excludes_conversation(text)',
                               'cma.call_not_reached_of(uuid,uuid,text)', 'cma.is_conversation(text,boolean,integer,integer,integer,boolean)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' is missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                     where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      v_bad := v_bad || v_fn || ' is not the application''s only, in the caller''s rights; ';
    end if;
  end loop;
  if (select provolatile from pg_proc where oid = to_regprocedure('cma.tag_meaning_excludes_conversation(text)')) is distinct from 'i' then
    v_bad := v_bad || 'the helper is not immutable; ';
  end if;
  if pg_get_function_result(to_regprocedure('cma.call_not_reached_of(uuid,uuid,text)')) is distinct from 'TABLE(not_reached boolean)'
     or not ((select proargnames from pg_proc where oid = to_regprocedure('cma.is_conversation(text,boolean,integer,integer,integer,boolean)'))
             @> array['p_not_reached']) then
    v_bad := v_bad || 'a name changed; ';
  end if;
  insert into verify_0008zd values (4, 'A4 the functions the application''s only and invoker; the helper immutable; nothing renamed',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);
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
  v_txt text;
  v_d    timestamptz := timestamptz '2026-10-06 08:00:00+00';   -- Tuesday 6 October 2026, 10:00 in Amsterdam
  v_now  timestamptz := timestamptz '2026-10-14 10:00:00+00';
  v_wn   jsonb := '[{"tagRef": "tg-wrong", "name": "Wrong Number"}]';
  v_off  jsonb := '[{"tagRef": "tg-wrong-off", "name": "Incorrect Data off"}]';
  v_nr   jsonb := '[{"tagRef": "tg-nr", "name": "Not Reached"}]';
  v_type jsonb := '[{"tagRef": "tg-type", "name": "Type"}]';
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    -- tenants, people and roles (as the owner)
    v_t1 := cma.create_tenant('verify-0008zd-one', 'Verify 0008zd one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008zd-two', 'Verify 0008zd two', 'Europe/Amsterdam');
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
    values (v_t1, 'verifycrm', 'Verify incorrect data CRM', 'portal-1', 'crm') returning id into v_crm;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t1, 'verifytel', 'Verify incorrect data telephony', 'tel-1', 'telephony') returning id into v_tel;
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t2, 'verifytel', 'Verify incorrect data telephony two', 'tel-2', 'telephony') returning id into v_tel2;
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
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'number', '[{"numberRef": "n-nl", "name": "Verify NL line", "digits": "+31000000001"}]');
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'tag', '[{"tagRef": "tg-wrong", "name": "Wrong Number"},
      {"tagRef": "tg-wrong-off", "name": "Incorrect Data off"}, {"tagRef": "tg-nr", "name": "Not Reached"}, {"tagRef": "tg-type", "name": "Type"}]');

    -- their configuration (the admin): the order pipeline, the line, the meanings, Incorrect Data off not counted
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_pipeline_order(v_crm, 'deal', 'selfserve', true);
    perform cma.set_telephony_number(v_tel, 'n-nl', 'NL', true);
    perform cma.set_telephony_tag_meaning(v_tel, 'tg-wrong', 'incorrect_data');
    perform cma.set_telephony_tag_meaning(v_tel, 'tg-wrong-off', 'incorrect_data');
    perform cma.set_telephony_tag_meaning(v_tel, 'tg-nr', 'not_reached');
    perform cma.set_telephony_tag_meaning(v_tel, 'tg-type', 'call_type');
    perform cma.set_telephony_tag(v_tel, 'tg-wrong-off', false);

    -- the telephony calls of 6 October (the Ingest user)
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
      pg_temp.v0008zd_call('o1', 'outbound', v_d,                           5, 45,   'tu-1', v_wn),
      pg_temp.v0008zd_call('o2', 'outbound', v_d + interval '10 minutes',  5, 45,   'tu-1', null),
      pg_temp.v0008zd_call('o3', 'outbound', v_d + interval '20 minutes',  5, 45,   'tu-1', v_nr),
      pg_temp.v0008zd_call('o4', 'outbound', v_d + interval '30 minutes',  5, 45,   'tu-1', v_off),
      pg_temp.v0008zd_call('o5', 'outbound', v_d + interval '40 minutes',  5, 45,   'tu-1', v_type),
      pg_temp.v0008zd_call('o6', 'outbound', v_d + interval '50 minutes',  5, 10,   'tu-1', v_wn),
      pg_temp.v0008zd_call('o7', 'outbound', v_d + interval '60 minutes',  null, null, 'tu-1', v_wn),
      pg_temp.v0008zd_call('o8', 'outbound', v_d + interval '70 minutes',  5, 45,   'tu-1', v_type || v_wn),
      pg_temp.v0008zd_call('o9', 'outbound', v_d + interval '80 minutes',  5, 60,   'tu-1', v_wn),
      pg_temp.v0008zd_call('i1', 'inbound',  v_d + interval '90 minutes',  5, 45,   'tu-2', v_wn),
      pg_temp.v0008zd_call('i2', 'inbound',  v_d + interval '100 minutes', 5, 45,   'tu-2', null),
      pg_temp.v0008zd_call('i3', 'inbound',  v_d + interval '110 minutes', 5, 45,   'tu-2', v_nr)));

    -- the CRM: a sales deal dW (contact kW) and a won order deal dG (contact kG); the CRM calls, ten seconds after the
    -- telephony calls they log, with the same hash: cw1 logs o1, cw2 logs o2, cg1 logs o9
    perform cma.ingest_upsert_records(v_crm, '[
      {"recordType": "deal", "sourceId": "dW", "pipelineId": "sales",     "stageId": "s1", "ownerRef": "o-1", "contactId": "kW", "market": "NL", "createdAt": "2026-10-06T07:00:00Z", "updatedAt": "2026-10-06T07:00:00Z"},
      {"recordType": "deal", "sourceId": "dG", "pipelineId": "selfserve", "stageId": "o1", "ownerRef": "o-1", "contactId": "kG", "market": "NL", "createdAt": "2026-10-09T12:00:00Z", "closedAt": "2026-10-09T12:00:00Z", "updatedAt": "2026-10-09T12:00:00Z"}]');
    perform cma.ingest_upsert_contacts(v_crm, (
      select jsonb_agg(jsonb_build_object('sourceId', k, 'country', 'NL', 'updatedAt', '2026-10-01T00:00:00Z'))
      from unnest(array['kW', 'kG']) k));
    perform cma.ingest_upsert_calls(v_crm, (
      select jsonb_agg(jsonb_build_object('sourceId', c.id, 'occurredAt', c.at, 'direction', 'outbound', 'ownerRef', 'o-1',
                                          'counterpartHash', md5(c.tel) || md5(c.tel || 'x'), 'updatedAt', c.at))
      from (values
        ('cw1', v_d + interval '10 seconds',            'o1'),
        ('cw2', v_d + interval '10 minutes 10 seconds', 'o2'),
        ('cg1', v_d + interval '80 minutes 10 seconds', 'o9')) c(id, at, tel)));
    perform cma.ingest_upsert_associations(v_crm, (
      select jsonb_agg(jsonb_build_object('fromType', 'crm_call', 'fromId', a.c, 'toType', 'contact', 'toId', a.k, 'removed', false,
                                          'changedAt', '2026-10-01T00:00:00Z'))
      from (values ('cw1', 'kW'), ('cw2', 'kW'), ('cg1', 'kG')) a(c, k)));
    perform cma.link_calls('2026-09-01T00:00:00Z');

    -- tenant two: the same tag ref
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_ing2::text, true);
    perform cma.ingest_upsert_telephony_catalog(v_tel2, 'tag', '[{"tagRef": "tg-wrong", "name": "Wrong Number"}]');

    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);
    select r.id into v_dw from cma.crm_record r where r.tenant_id = v_t1 and r.source_id = 'dW';

    -- B1. Connected and Conversation per call (cma.calls_of): a current tag meaning incorrect data leaves a call connected
    --     and no conversation, at 45 s outbound (o1), on a tag that does not count (o4), next to another tag (o8), inbound
    --     (i1); connected at 10 s (o6) and not connected unanswered (o7) as before; not reached as before (o3, i3); the
    --     untagged and the Type-tagged calls conversations
    select string_agg(format('%s:%s%s', x.src, case when c.is_connected_outbound then 'c' else '-' end, case when c.is_conversation then 'v' else '-' end),
                      ' ' order by x.src)
      into v_txt
    from cma.calls_of(v_t1, v_d - interval '1 day', v_d + interval '1 day', null, null) c
    join lateral (select tc.source_id as src from cma.telephony_call tc
                  where tc.tenant_id = v_t1 and tc.connection_id = c.connection_id and tc.started_at = c.started_at) x on true;
    v_rows := v_rows || array['11', 'B1 incorrect data: connected, no conversation (uncounted tag, next to another tag, inbound alike); not reached as before',
      case when v_txt = 'i1:-- i2:-v i3:-- o1:c- o2:cv o3:c- o4:c- o5:cv o6:c- o7:-- o8:c- o9:c-' and not v_provoke then 'PASS' else 'FAIL' end,
      coalesce(v_txt, 'no rows')];

    -- B2. Reports, Calls as the application reads it: 12 calls, 3 inbound, 9 outbound, 3 answered inbound, 8 connected
    --     (88.9 of the outbound), 3 conversations (o2, o5, i2), 2 untagged; tag use counts o5's Type only (o8 is no
    --     conversation); per person Anna 9 outbound, 8 connected, 2 conversations, 1 untagged; Bram 3 answered, 1, 1
    select format('%s/%s/%s/%s/%s/%s/%s/%s', calls, inbound, outbound, answered_inbound, connected, connected_rate, conversations, untagged)
      into v_txt
    from cma.calls_overview('2026-10-05', '2026-10-11', null, null, 'week') where period = 'current' and group_key is null;
    select v_txt || ' | ' || coalesce(string_agg(coalesce(group_key, 'all') || ':' || coalesce(tag_name, '-') || '=' || conversations, ',' order by ordinality), 'none')
      into v_txt
    from cma.calls_tag_use('2026-10-05', '2026-10-11', null, null, 'week') with ordinality;
    select v_txt || ' | ' || string_agg(format('%s:%s/%s/%s/%s/%s', coalesce(display_name, row_kind), answered_inbound, outbound_calls, connected,
                                               conversations, untagged), ' ' order by row_kind = 'total', display_name) into v_txt
    from cma.calls_per_person('2026-10-05', '2026-10-11', null, null);
    v_rows := v_rows || array['12', 'B2 Calls, tag use and per person count no conversation with a tag meaning incorrect data',
      case when v_txt = '12/3/9/3/8/88.9/3/2 | 2026-10-05:Type=1,all:Type=1 | Anna Verify:0/9/8/2/1 Bram Verify:3/0/0/1/1 total:3/9/8/3/2'
            and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no rows')];

    -- B3. a CRM call through its linked telephony call: cw1 (o1, incorrect data) no conversation, cw2 (o2) one; Attempts
    --     per deal: dW's two attempts, one conversation (the second), talk 90 s in all and 45 s on the conversations; one
    --     deal's attempts connected and conversation per attempt
    select string_agg(format('%s:%s', c.source_id, k.is_conversation), ' ' order by c.source_id) into v_txt
    from cma.crm_call c cross join lateral cma.crm_call_conversation_of(v_t1, c.id) k
    where c.tenant_id = v_t1 and c.source_id in ('cw1', 'cw2');
    select v_txt || ' | ' || format('%s/%s/%s/%s/%s', x.attempts, x.conversation_attempts, coalesce(x.first_conversation_attempt::text, '-'),
                                    x.talk_seconds_total, x.talk_seconds_conversation) into v_txt
    from cma.attempts_per_deal_of(v_t1, timestamptz '2026-10-04 22:00:00+00', timestamptz '2026-10-11 22:00:00+00', v_now) x
    where x.deal_source_id = 'dW';
    perform set_config('app.user_id', v_admin1::text, true);
    select v_txt || ' | ' || string_agg(format('%s:%s/%s/%s', a.n, a.connected, coalesce(a.talk_seconds::text, '-'), a.conversation), ' ' order by a.n)
      into v_txt from cma.attempts_of_deal(v_dw) a;
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['13', 'B3 a CRM call and Attempts per deal: no conversation through a telephony call tagged incorrect data',
      case when v_txt = 'cw1:f cw2:t | 2/1/2/90/45 | 1:t/45/f 2:t/45/t' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no rows')];

    -- B4. first orders' evidence: dG's contact was called (o9, outbound 60 s) on a call tagged incorrect data, so an attempt
    --     and no conversation
    select string_agg(format('%s:%s/%s/%s', f.deal_source_id, f.conversation, f.attempt, f.level), ' ' order by f.deal_source_id) into v_txt
    from cma.first_orders_of(v_t1, timestamptz '2026-10-09 00:00:00+00', timestamptz '2026-10-10 00:00:00+00') f;
    v_rows := v_rows || array['14', 'B4 first orders: a call tagged incorrect data is an attempt, no conversation',
      case when v_txt = 'dG:f/t/attempt' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no rows')];

    -- B5. the same call once its tag is removed (an empty tag set closes it): o1 a conversation, and so cw1 and dW's first
    --     attempt; i1 too
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
      pg_temp.v0008zd_call('o1', 'outbound', v_d, 5, 45, 'tu-1', '[]'::jsonb) || jsonb_build_object('versionAt', v_d + interval '5 hours'),
      pg_temp.v0008zd_call('i1', 'inbound', v_d + interval '90 minutes', 5, 45, 'tu-2', '[]'::jsonb) || jsonb_build_object('versionAt', v_d + interval '5 hours')));
    perform set_config('app.user_id', v_analyst1::text, true);
    select string_agg(format('%s:%s%s', x.src, case when c.is_connected_outbound then 'c' else '-' end, case when c.is_conversation then 'v' else '-' end),
                      ' ' order by x.src)
      into v_txt
    from cma.calls_of(v_t1, v_d - interval '1 day', v_d + interval '1 day', null, null) c
    join lateral (select tc.source_id as src from cma.telephony_call tc
                  where tc.tenant_id = v_t1 and tc.connection_id = c.connection_id and tc.started_at = c.started_at) x on true
    where x.src in ('o1', 'i1');
    select v_txt || ' | ' || string_agg(format('%s:%s', c.source_id, k.is_conversation), ' ' order by c.source_id) into v_txt
    from cma.crm_call c cross join lateral cma.crm_call_conversation_of(v_t1, c.id) k
    where c.tenant_id = v_t1 and c.source_id = 'cw1';
    select v_txt || ' | ' || format('%s/%s', x.conversation_attempts, coalesce(x.first_conversation_attempt::text, '-')) into v_txt
    from cma.attempts_per_deal_of(v_t1, timestamptz '2026-10-04 22:00:00+00', timestamptz '2026-10-11 22:00:00+00', v_now) x
    where x.deal_source_id = 'dW';
    v_rows := v_rows || array['15', 'B5 the same call is a conversation once its incorrect-data tag is removed',
      case when v_txt = 'i1:-v o1:cv | cw1:t | 2/1' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no rows')];

    -- B6. the writes: the setter accepts incorrect_data and it replaces the tag's meaning (one per tag); the Sources page's
    --     catalogs give it; an unknown key, a wrong case and an empty one refused (CMA04); the check accepts it written
    --     directly and refuses an unknown key (23514); an agent, the Ingest user and no acting user refused
    perform set_config('app.user_id', v_admin1::text, true);
    v_txt := pg_temp.v0008zd_code(format('select cma.set_telephony_tag_meaning(%L, %L, %L)', v_tel, 'tg-type', 'incorrect_data'));
    v_txt := v_txt || ' ' || (select g.meaning from cma.telephony_tag g where g.connection_id = v_tel and g.tag_ref = 'tg-type');
    select v_txt || ' ' || string_agg(t ->> 'tagRef' || '=' || coalesce(t ->> 'meaning', '-'), ' ' order by t ->> 'tagRef') into v_txt
    from jsonb_array_elements(cma.connection_catalogs(v_tel) -> 'tags') t;
    v_txt := v_txt || ' | ' || pg_temp.v0008zd_code(format('select cma.set_telephony_tag_meaning(%L, %L, %L)', v_tel, 'tg-type', 'wrong_number'))
             || ' ' || pg_temp.v0008zd_code(format('select cma.set_telephony_tag_meaning(%L, %L, %L)', v_tel, 'tg-type', 'Incorrect_Data'))
             || ' ' || pg_temp.v0008zd_code(format('select cma.set_telephony_tag_meaning(%L, %L, %L)', v_tel, 'tg-type', ''));
    perform cma.set_telephony_tag_meaning(v_tel, 'tg-type', 'call_type');
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || ' | ' || pg_temp.v0008zd_code(format('update cma.telephony_tag set meaning = %L where connection_id = %L and tag_ref = %L', 'incorrect_data', v_tel, 'tg-nr'));
    v_txt := v_txt || ' ' || (select g.meaning from cma.telephony_tag g where g.connection_id = v_tel and g.tag_ref = 'tg-nr');
    v_txt := v_txt || ' ' || pg_temp.v0008zd_code(format('update cma.telephony_tag set meaning = %L where connection_id = %L and tag_ref = %L', 'wrong_number', v_tel, 'tg-nr'));
    update cma.telephony_tag set meaning = 'not_reached' where connection_id = v_tel and tag_ref = 'tg-nr';
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_agent1::text, true);
    v_txt := v_txt || ' | ' || pg_temp.v0008zd_code(format('select cma.set_telephony_tag_meaning(%L, %L, %L)', v_tel, 'tg-type', 'incorrect_data'));
    perform set_config('app.user_id', v_ing1::text, true);
    v_txt := v_txt || ' ' || pg_temp.v0008zd_code(format('select cma.set_telephony_tag_meaning(%L, %L, %L)', v_tel, 'tg-type', 'incorrect_data'));
    perform set_config('app.user_id', '', true);
    v_txt := v_txt || ' ' || pg_temp.v0008zd_code(format('select cma.set_telephony_tag_meaning(%L, %L, %L)', v_tel, 'tg-type', 'incorrect_data'));
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['16', 'B6 the setter and the check accept incorrect_data, one meaning per tag; an unknown key refused by both; others refused',
      case when v_txt = 'ok incorrect_data tg-nr=not_reached tg-type=incorrect_data tg-wrong=incorrect_data tg-wrong-off=incorrect_data | CMA04 CMA04 CMA04 | ok incorrect_data 23514 | CMA06 CMA06 CMA01'
            and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no rows')];

    -- B7. the audit names the admin for each incorrect-data meaning set: Wrong Number and Incorrect Data off, Type through
    --     the setter in B6 and Not Reached written directly there; and a catalog refresh keeps the meaning
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'tag', '[{"tagRef": "tg-wrong", "name": "Wrong Number renamed"},
      {"tagRef": "tg-wrong-off", "name": "Incorrect Data off"}, {"tagRef": "tg-nr", "name": "Not Reached"}, {"tagRef": "tg-type", "name": "Type"}]');
    perform set_config('role', 'cma_owner', true);
    select count(*) || ' by the admin' into v_txt
    from cma.audit_log a
    where a.tenant_id = v_t1 and a.table_name = 'telephony_tag' and a.actor_user_id = v_admin1
      and a.new_row ->> 'meaning' = 'incorrect_data' and (a.old_row ->> 'meaning') is distinct from 'incorrect_data';
    select v_txt || ' | ' || g.name || '/' || g.meaning into v_txt
    from cma.telephony_tag g where g.tenant_id = v_t1 and g.connection_id = v_tel and g.tag_ref = 'tg-wrong';
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['17', 'B7 the audit names the admin for each incorrect-data meaning; a catalog refresh keeps it',
      case when v_txt = '4 by the admin | Wrong Number renamed/incorrect_data' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no rows')];

    -- B8. tenant isolation: tenant two's admin can neither read nor set tenant one's meaning (CMA02 for the connection, no
    --     row seen) and sets its own tag of the same ref; tenant one's meaning stays
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    v_txt := pg_temp.v0008zd_code(format('select cma.set_telephony_tag_meaning(%L, %L, null)', v_tel, 'tg-wrong'))
             || ' ' || pg_temp.v0008zd_code(format('select cma.connection_catalogs(%L)', v_tel))
             || ' ' || (select count(*) from cma.telephony_tag g where g.connection_id = v_tel)
             || ' ' || (select coalesce(string_agg(g.tag_ref || '=' || coalesce(g.meaning, '-'), ' '), 'none') from cma.telephony_tag g);
    perform cma.set_telephony_tag_meaning(v_tel2, 'tg-wrong', 'not_reached');
    v_txt := v_txt || ' ' || (select coalesce(string_agg(g.tag_ref || '=' || coalesce(g.meaning, '-'), ' '), 'none') from cma.telephony_tag g);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_txt := v_txt || ' | ' || (select g.meaning from cma.telephony_tag g where g.connection_id = v_tel and g.tag_ref = 'tg-wrong');
    v_rows := v_rows || array['18', 'B8 another tenant can neither read nor set a tenant''s meaning',
      case when v_txt = 'CMA02 CMA02 0 tg-wrong=- tg-wrong=not_reached | incorrect_data' and not v_provoke then 'PASS' else 'FAIL' end,
      coalesce(v_txt, 'no rows')];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['39', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008zd (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008zd values (39, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008zd
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED: not dev'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008zd where result = 'PASS') = 12
                       and not exists (select 1 from verify_0008zd where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0008zd where result = 'PASS'),
                                        (select count(*) from verify_0008zd where result <> 'PASS'))) x
order by ord;
drop function if exists pg_temp.v0008zd_code(text);
drop function if exists pg_temp.v0008zd_call(text, text, timestamptz, integer, integer, text, jsonb);
reset role;
