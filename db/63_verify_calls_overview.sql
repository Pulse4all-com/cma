-- =============================================================================================
-- 63_verify_calls_overview.sql: verifies addition 0008j, calls overview and calls per agent
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure
-- and privileges; block B works on two throwaway tenants inside a subtransaction that is always
-- rolled back. Universal otherwise: nothing of the seed is used; adapters, lines, tags, users, calls
-- and hashes are invented data values (no hash below is made from a real number). Every check writes
-- one row, PASS or FAIL, and the last result lists them with the verdict, because Cloud SQL Studio
-- shows no notices. Run as your own IAM login in dev, after 62_calls_overview.sql and the 02 rerun;
-- then 35, 41, 55 and 61 again.
--   A  structure and privileges: the addition row; the setting with its type and default; every
--      function the application's only, in the caller's rights; no function returns a hash, a
--      number, digits or a call id, and the application's reads no telephony user id
--   B  behaviour. Tenant one (Europe/Amsterdam; lines NL, a second NL line, GB, and an NL line that
--      does not count; two people linked to telephony users, two users without a person; a counted
--      and an uncounted tag) over 26 October to 1 November 2026, whose previous equal period (19 to
--      25 October) crosses the DST change of 25 October: talk time without ringing and a call at
--      exactly the threshold; an uncounted line's calls never counted (skipped by the write, and one
--      written past it); the untagged rule with a counted, an uncounted and a removed tag; an
--      uncounted tag out of the tags per person but still making a call tagged; the market and line
--      filters narrowing every function alike; tag use by market; the previous period's totals and
--      the days and weeks across the DST change, each call in its line's zone; the per-person rows
--      through linked accounts (an id of another adapter does not link) and the users without a
--      person as one row with their count; the permissions (performance.team for both per-person
--      reads, reports.view enough for the overview and the tag use) and the refusals; tenant
--      isolation with tenant two's equal refs, also in the owner's rights; no hash, number, call id
--      or telephony user id in any answer; the overview per market and its computed total, a deleted
--      call never counted
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
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 63 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0008j;
create temp table verify_0008j (ord int, check_name text, result text, detail text);

-- One telephony call as the ingest write takes it: answered after p_answer seconds (null: never),
-- ended after p_end seconds (the duration, ringing included), the line, the telephony user, the hash
-- and the current tag set (null: none sent) as given
create or replace function pg_temp.v0008j_call(p_src text, p_dir text, p_start timestamptz, p_answer numeric, p_end numeric,
                                               p_line text, p_user text, p_hash text, p_tags jsonb)
returns jsonb
language sql immutable
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'sourceId', p_src, 'direction', p_dir, 'startedAt', p_start,
    'answeredAt', p_start + make_interval(secs => p_answer::double precision),
    'endedAt', p_start + make_interval(secs => p_end::double precision),
    'durationSeconds', p_end::integer, 'numberRef', p_line, 'userRef', p_user, 'counterpartHash', p_hash, 'tags', p_tags,
    'versionAt', coalesce(p_start + make_interval(secs => p_end::double precision), p_start)))
$$;

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_fn      text;
  v_bad     text;
  v_cols    text;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  -- A1. the addition is recorded, after 0008i
  insert into verify_0008j values (1, 'A1 addition 0008j recorded',
    case when exists (select 1 from cma.schema_migration where version = '0008j')
              and exists (select 1 from cma.schema_migration where version = '0008i') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the setting with its type and universal default
  select string_agg(key || '=' || value_type || ':' || default_value, ', ') into v_cols
  from cma.setting where key = 'telephony.connected_min_seconds';
  insert into verify_0008j values (2, 'A2 the setting: connected from 10 seconds of talk time',
    case when v_cols = 'telephony.connected_min_seconds=integer:10' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_cols, 'none'));

  -- A3. every function exists, executable by the application only, in the caller's rights
  v_bad := '';
  foreach v_fn in array array[
    'cma.calls_overview(date,date,text,text,text)', 'cma.calls_tag_use(date,date,text,text,text)',
    'cma.calls_per_person(date,date,text,text)', 'cma.calls_per_person_tags(date,date,text,text)', 'cma.calls_filters_check(text,text)',
    'cma.calls_of(uuid,timestamptz,timestamptz,text,text)', 'cma.calls_figures_of(uuid,date,date,text,text,text)',
    'cma.calls_overview_of(uuid,date,date,text,text,text)', 'cma.calls_tag_use_of(uuid,date,date,text,text,text)',
    'cma.calls_people_of(uuid,date,date,text,text)', 'cma.calls_per_person_of(uuid,date,date,text,text)',
    'cma.calls_per_person_tags_of(uuid,date,date,text,text)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' is missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                     where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      v_bad := v_bad || v_fn || ' is not the application''s only, in the caller''s rights; ';
    end if;
  end loop;
  insert into verify_0008j values (3, 'A3 the functions are the application''s only, in the caller''s rights',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A4. no function of the addition returns a hash, a phone, digits, a number or a call id column,
  --     and the application's four reads return no telephony user id
  select string_agg(p.proname || '.' || a.name, ', ') into v_cols
  from pg_proc p
  cross join lateral unnest(coalesce(p.proargnames, '{}'::text[]), coalesce(p.proargmodes::text[], '{}'::text[])) as a(name, mode)
  where p.pronamespace = 'cma'::regnamespace
    and p.proname in ('calls_overview', 'calls_tag_use', 'calls_per_person', 'calls_per_person_tags', 'calls_of', 'calls_figures_of',
                      'calls_overview_of', 'calls_tag_use_of', 'calls_people_of', 'calls_per_person_of', 'calls_per_person_tags_of')
    and a.mode in ('t', 'o')
    and (a.name like '%hash%' or a.name like '%phone%' or a.name like '%digits%' or a.name like '%number%'
         or a.name in ('call_id', 'source_id', 'id')
         or (a.name like '%user_ref%' and p.proname in ('calls_overview', 'calls_tag_use', 'calls_per_person', 'calls_per_person_tags')));
  insert into verify_0008j values (4, 'A4 no function returns a hash, number or call id; the reads no telephony user id',
    case when v_cols is null and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_cols, ''));
end
$$;

-- B. Behaviour on two throwaway tenants (rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_rows     text[] := '{}';
  v_t1 uuid; v_t2 uuid;
  v_admin1 uuid; v_agent1 uuid; v_analyst1 uuid; v_super1 uuid; v_reader1 uuid; v_ing1 uuid;
  v_anna uuid; v_bram uuid; v_cas uuid;
  v_admin2 uuid; v_analyst2 uuid; v_ing2 uuid; v_dora uuid;
  v_tel1 uuid; v_tel2 uuid;
  v_role uuid;
  v_nl text; v_nl2 text; v_gb text; v_off text;
  v_txt      text;
  v_detail   text;
  v_s        text;
  v_skip     text;
  v_ok       boolean;
  v_n        integer;
  v_f        text[];
  v_i        integer;
  v_d        timestamptz := timestamptz '2026-10-26 00:00:00+00';
  v_h        text[] := array[repeat('c1', 32), repeat('c2', 32), repeat('c3', 32), repeat('c4', 32), repeat('c5', 32), repeat('c6', 32)];
  v_sale     jsonb := '[{"tagRef": "tg-sale", "name": "Sale"}]';
  v_info     jsonb := '[{"tagRef": "tg-info", "name": "Info"}]';
  v_test     jsonb := '[{"tagRef": "tg-test", "name": "Test"}]';
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    v_t1 := cma.create_tenant('verify-0008j-one', 'Verify 0008j one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008j-two', 'Verify 0008j two', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent1@example.invalid', 'agent1') returning id into v_agent1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-analyst1@example.invalid', 'analyst1') returning id into v_analyst1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-super1@example.invalid', 'super1') returning id into v_super1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-reader1@example.invalid', 'reader1') returning id into v_reader1;
    -- the people the calls belong to, created out of name order, so the order by name is the only one that fits
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-bram@example.invalid', 'Bram Verify') returning id into v_bram;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-cas@example.invalid', 'Cas Verify') returning id into v_cas;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-anna@example.invalid', 'Anna Verify') returning id into v_anna;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin2') returning id into v_admin2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-analyst2@example.invalid', 'analyst2') returning id into v_analyst2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-dora@example.invalid', 'Dora Verify') returning id into v_dora;
    -- a role with reports.view only (no default role has it without performance.team)
    insert into cma.app_role (tenant_id, key, name) values (v_t1, 'verify_reader', 'Verify reader') returning id into v_role;
    insert into cma.role_permission (tenant_id, role_id, permission_key) values (v_t1, v_role, 'reports.view');
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_agent1, 'agent'), (v_t1, v_analyst1, 'analytics'), (v_t1, v_super1, 'supervisor'),
                 (v_t1, v_reader1, 'verify_reader'), (v_t1, v_anna, 'agent'), (v_t1, v_bram, 'agent'), (v_t1, v_cas, 'agent'),
                 (v_t2, v_admin2, 'admin'), (v_t2, v_analyst2, 'analytics'), (v_t2, v_dora, 'agent')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    select x.user_id into v_ing2 from cma.app_user_external_id x where x.tenant_id = v_t2 and x.system = 'ingest';
    perform set_config('role', 'cma_app', true);

    -- tenant one: markets NL and GB, a telephony connection with four lines (NL, a second NL, GB, and
    -- an NL line that does not count), people linked to telephony users tel-user-1 (Anna) and
    -- tel-user-2 (Bram); Cas holds tel-user-4 of another adapter only; tel-user-3 and tel-user-4 of
    -- this adapter have no person
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP');
    select c.connection_id into v_tel1 from cma.upsert_connection('verifytel', 'Verify phones one', 'company-1', null, null) c;
    perform cma.set_connection_kind(v_tel1, 'telephony');
    v_nl := v_tel1::text || ':line-nl'; v_nl2 := v_tel1::text || ':line-nl2'; v_gb := v_tel1::text || ':line-gb'; v_off := v_tel1::text || ':line-off';
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_telephony_catalog(v_tel1, 'number', '[{"numberRef": "line-nl", "name": "Verify NL line", "digits": "+31 20 555 0101"},
      {"numberRef": "line-nl2", "name": "Verify NL line two", "digits": "+31 20 555 0102"},
      {"numberRef": "line-gb", "name": "Verify GB line", "digits": "+44 20 7946 0103"},
      {"numberRef": "line-off", "name": "Verify line not counted", "digits": "+31 20 555 0104"}]'::jsonb);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_telephony_number(v_tel1, 'line-nl', 'NL', true);
    perform cma.set_telephony_number(v_tel1, 'line-nl2', 'NL', true);
    perform cma.set_telephony_number(v_tel1, 'line-gb', 'GB', true);
    perform cma.set_telephony_number(v_tel1, 'line-off', 'NL', false);
    perform cma.set_user_external_id(v_anna, 'verifytel_user', 'tel-user-1');
    perform cma.set_user_external_id(v_bram, 'verifytel_user', 'tel-user-2');
    perform cma.set_user_external_id(v_cas, 'othertel_user', 'tel-user-4');

    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_telephony_calls(v_tel1, jsonb_build_array(
      -- the period, 26 October to 1 November (CET in NL, GMT in GB)
      -- 26 Oct 00:30 CET on the NL line (25 Oct 23:30 UTC): first written tagged Sale, the tag removed below
      pg_temp.v0008j_call('src0008j-c0', 'inbound', v_d - interval '30 minutes', 6, 66, 'line-nl', 'tel-user-1', v_h[1], v_sale),
      -- outbound: 10 seconds of talk after 15 of ringing (exactly the threshold), and 9 after 20
      pg_temp.v0008j_call('src0008j-o1', 'outbound', v_d + interval '8 hours', 15, 25, 'line-nl', 'tel-user-1', v_h[2], v_sale),
      pg_temp.v0008j_call('src0008j-o2', 'outbound', v_d + interval '8 hours 10 minutes', 20, 29, 'line-nl', 'tel-user-1', v_h[2], v_sale),
      -- 300 seconds of talk after 12 of ringing, tagged only with a tag that does not count
      pg_temp.v0008j_call('src0008j-i1', 'inbound', v_d + interval '1 day 15 hours', 12, 312, 'line-nl', 'tel-user-1', v_h[3], v_test),
      -- an outbound call nobody answered
      pg_temp.v0008j_call('src0008j-o3', 'outbound', v_d + interval '1 day 9 hours', null, 30, 'line-nl', 'tel-user-2', v_h[4], null),
      -- GB: an untagged inbound conversation; an outbound one with a counted and an uncounted tag
      pg_temp.v0008j_call('src0008j-i2', 'inbound', v_d + interval '2 days 10 hours', 8, 68, 'line-gb', 'tel-user-2', v_h[5], null),
      pg_temp.v0008j_call('src0008j-o4', 'outbound', v_d + interval '2 days 16 hours 30 minutes', 5, 125, 'line-gb', 'tel-user-2', v_h[6],
                          '[{"tagRef": "tg-info", "name": "Info"}, {"tagRef": "tg-test", "name": "Test"}]'::jsonb),
      -- a missed inbound call without a user; the second NL line with two counted tags
      pg_temp.v0008j_call('src0008j-i3', 'inbound', v_d + interval '3 days 8 hours', null, 30, 'line-nl', null, v_h[1], null),
      pg_temp.v0008j_call('src0008j-i5', 'inbound', v_d + interval '3 days 10 hours', 4, 34, 'line-nl2', 'tel-user-2', v_h[2],
                          '[{"tagRef": "tg-sale", "name": "Sale"}, {"tagRef": "tg-info", "name": "Info"}]'::jsonb),
      -- telephony users without a person: tel-user-3 inbound, tel-user-4 outbound at 1 Nov 23:30 GMT
      pg_temp.v0008j_call('src0008j-i4', 'inbound', v_d + interval '4 days 12 hours', 5, 95, 'line-nl', 'tel-user-3', v_h[3], v_sale),
      pg_temp.v0008j_call('src0008j-o5', 'outbound', v_d + interval '6 days 23 hours 30 minutes', 3, 43, 'line-gb', 'tel-user-4', v_h[4], null),
      -- and tel-user-4's second call, an outbound call nobody answered on 31 October 10:00 GMT
      pg_temp.v0008j_call('src0008j-o6', 'outbound', v_d + interval '5 days 10 hours', null, 25, 'line-gb', 'tel-user-4', v_h[5], null),
      -- the same instant on the NL line is 2 November 00:30 CET: after the period
      pg_temp.v0008j_call('src0008j-x1', 'inbound', v_d + interval '6 days 23 hours 30 minutes', 5, 65, 'line-nl', 'tel-user-1', v_h[5], null),
      -- the previous period, 19 to 25 October: 25 Oct 02:30 CEST and 02:30 CET (NL), 23:30 CET (NL),
      -- 23:30 GMT (GB); 19 Oct 00:30 CEST (NL); and 18 Oct 23:30 CEST (NL), before it
      pg_temp.v0008j_call('src0008j-p1', 'inbound', timestamptz '2026-10-25 00:30:00+00', 5, 65, 'line-nl', 'tel-user-1', null, null),
      pg_temp.v0008j_call('src0008j-p2', 'inbound', timestamptz '2026-10-25 01:30:00+00', 5, 35, 'line-nl', 'tel-user-1', null, null),
      pg_temp.v0008j_call('src0008j-p3', 'outbound', timestamptz '2026-10-25 22:30:00+00', 4, 24, 'line-nl', 'tel-user-2', null, null),
      pg_temp.v0008j_call('src0008j-p6', 'inbound', timestamptz '2026-10-25 23:30:00+00', 5, 15, 'line-gb', 'tel-user-2', null, null),
      pg_temp.v0008j_call('src0008j-p4', 'outbound', timestamptz '2026-10-18 22:30:00+00', null, 20, 'line-nl', 'tel-user-2', null, null),
      pg_temp.v0008j_call('src0008j-p5', 'inbound', timestamptz '2026-10-18 21:30:00+00', 5, 65, 'line-nl', 'tel-user-1', null, null),
      -- a conversation the telephony system deleted afterwards (below): never counted
      pg_temp.v0008j_call('src0008j-d1', 'inbound', v_d + interval '1 day 13 hours', 5, 65, 'line-nl', 'tel-user-1', null, v_sale)));
    perform cma.ingest_upsert_telephony_calls(v_tel1, jsonb_build_array(
      jsonb_build_object('sourceId', 'src0008j-d1', 'deletedAt', v_d + interval '2 days', 'versionAt', v_d + interval '2 days')));
    -- the Sale tag removed from c0: an empty tag set closes it
    perform cma.ingest_upsert_telephony_calls(v_tel1, jsonb_build_array(
      pg_temp.v0008j_call('src0008j-c0', 'inbound', v_d - interval '30 minutes', 6, 66, 'line-nl', 'tel-user-1', v_h[1], '[]'::jsonb)
        || jsonb_build_object('versionAt', v_d + interval '1 hour')));
    -- a call on the line that does not count: the write skips it
    select string_agg(o.outcome, ',') into v_skip
    from cma.ingest_upsert_telephony_calls(v_tel1, jsonb_build_array(
      pg_temp.v0008j_call('src0008j-off1', 'inbound', v_d + interval '1 day 10 hours', 5, 65, 'line-off', 'tel-user-1', null, v_sale))) o;
    -- and one written past the write (as a call stored before its line was switched off would be)
    perform set_config('role', 'cma_owner', true);
    insert into cma.telephony_call (tenant_id, connection_id, source_system, source_id, direction, started_at, answered_at, ended_at,
                                    user_ref, number_ref, source_version_at)
    values (v_t1, v_tel1, 'verifytel', 'src0008j-off2', 'outbound', v_d + interval '1 day 11 hours', v_d + interval '1 day 11 hours 5 seconds',
            v_d + interval '1 day 11 hours 55 seconds', 'tel-user-1', 'line-off', v_d + interval '1 day 11 hours 55 seconds');
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_telephony_tag(v_tel1, 'tg-test', false);

    -- tenant two: the same line, user and tag refs; tel-user-1 is Dora here
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    select c.connection_id into v_tel2 from cma.upsert_connection('verifytel', 'Verify phones two', 'company-2', null, null) c;
    perform cma.set_telephony_number(v_tel2, 'line-nl', 'NL', true);
    perform cma.set_user_external_id(v_dora, 'verifytel_user', 'tel-user-1');
    perform set_config('app.user_id', v_ing2::text, true);
    perform cma.ingest_upsert_telephony_calls(v_tel2, jsonb_build_array(
      pg_temp.v0008j_call('src0008j-t2a', 'inbound', v_d + interval '9 hours', 5, 65, 'line-nl', 'tel-user-1', v_h[1], v_sale),
      pg_temp.v0008j_call('src0008j-t2b', 'outbound', v_d + interval '10 hours', 5, 15, 'line-nl', 'tel-user-1', v_h[2], null)));

    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);

    -- B1. talk time runs from the answer to the end (i1: 300 seconds, not its 312 of duration): the
    --     conversations' talk is 710 seconds where their durations add up to 768; a call at exactly the
    --     threshold is connected: 3 connected at 10 seconds, 4 at 9 (o2 joins), 2 at 11 (o1 leaves)
    select format('talk %s avg %s; connected %s', talk_seconds_total, talk_seconds_avg, connected_outbound) into v_txt
    from cma.calls_overview('2026-10-26', '2026-11-01', null, null, 'day') where period = 'current' and group_key is null;
    v_detail := '';
    foreach v_s in array array['9', '11'] loop
      perform set_config('app.user_id', v_admin1::text, true);
      perform cma.set_tenant_setting('telephony.connected_min_seconds', v_s);
      perform set_config('app.user_id', v_analyst1::text, true);
      select v_detail || case when v_detail = '' then '' else '/' end || connected_outbound into v_detail
      from cma.calls_overview('2026-10-26', '2026-11-01', null, null, 'day') where period = 'current' and group_key is null;
    end loop;
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_tenant_setting('telephony.connected_min_seconds', null);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['11', 'B1 talk time excludes ringing; a call at exactly the threshold is connected',
      case when v_txt = 'talk 710 avg 88.8; connected 3' and v_detail = '4/2' and not v_provoke then 'PASS' else 'FAIL' end,
      coalesce(v_txt, 'no row') || ' | at 9/11: ' || coalesce(v_detail, 'none')];

    -- B2. the line that does not count: the write skipped off1, and off2, stored past it, is in no
    --     answer: the line as a filter finds nothing, and Anna's calls do not hold it
    select v_skip || '; stored ' || (select count(*) from cma.calls_of(v_t1, null, null, null, null) where line_key = v_off)
           || '; filtered ' || calls || '/' || conversations into v_txt
    from cma.calls_overview('2026-10-26', '2026-11-01', null, v_off, 'day') where period = 'current' and group_key is null;
    perform set_config('role', 'cma_owner', true);
    v_n := (select count(*) from cma.telephony_call where tenant_id = v_t1 and number_ref = 'line-off');
    perform set_config('role', 'cma_app', true);
    select v_txt || format('; in the table %s; Anna out %s', v_n, outbound_calls) into v_txt
    from cma.calls_per_person('2026-10-26', '2026-11-01', null, null) where user_id = v_anna;
    v_rows := v_rows || array['12', 'B2 a call on a line that does not count is never counted',
      case when v_txt = 'skipped_uncounted_line; stored 0; filtered 0/0; in the table 1; Anna out 2' and not v_provoke then 'PASS' else 'FAIL' end,
      coalesce(v_txt, 'no row')];

    -- B3. untagged is a conversation without a current tag of any kind: c0 (its tag removed), i2 and o5;
    --     i1, tagged only with a tag that does not count, is tagged; o4 carries both kinds
    select format('untagged %s of %s', untagged_conversations, conversations) into v_txt
    from cma.calls_overview('2026-10-26', '2026-11-01', null, null, 'day') where period = 'current' and group_key is null;
    select v_txt || ' | ' || string_agg(group_key || '=' || untagged_conversations, ',' order by group_key) into v_txt
    from cma.calls_overview('2026-10-26', '2026-11-01', null, null, 'day') where period = 'current' and group_key is not null;
    v_rows := v_rows || array['13', 'B3 the untagged rule: any current tag counts, counted or not; a removed tag does not',
      case when v_txt = 'untagged 3 of 8 | 2026-10-26=1,2026-10-27=0,2026-10-28=1,2026-10-29=0,2026-10-30=0,2026-10-31=0,2026-11-01=1' and not v_provoke then 'PASS' else 'FAIL' end,
      coalesce(v_txt, 'no row')];

    -- B4. the tag that does not count (Test) is in the tag use, marked, and in none of the tags per
    --     person; Anna's i1, tagged with Test only, is not among her untagged conversations either
    select string_agg(coalesce(tag_name, '-') || '=' || conversations || case when is_counted = false then '(not counted)' else '' end, ',' order by ordinality)
      into v_txt from cma.calls_tag_use('2026-10-26', '2026-11-01', null, null, 'day') with ordinality where group_key is null;
    select string_agg(case row_kind when 'person' then (select display_name from cma.app_user where id = t.user_id) else row_kind end
                      || ':' || coalesce(tag_name, '-') || '=' || conversations, ',' order by ordinality) into v_detail
    from cma.calls_per_person_tags('2026-10-26', '2026-11-01', null, null) with ordinality t;
    v_rows := v_rows || array['14', 'B4 a tag that does not count is left out of the tags per person and still makes a call tagged',
      case when v_txt = 'Sale=3,Info=2,Test=2(not counted),-=3'
                and v_detail = 'Anna Verify:Sale=1,Anna Verify:-=1,Bram Verify:Info=2,Bram Verify:Sale=1,Bram Verify:-=1,not_linked:Sale=1,not_linked:-=1'
                and not v_provoke then 'PASS' else 'FAIL' end,
      coalesce(v_txt, 'no rows') || ' | ' || coalesce(v_detail, 'no rows')];

    -- B5. the filters narrow every function alike: per filter, the overview's calls, conversations and
    --     untagged; the per-person total's conversations and untagged and the sum of its rows; the tag
    --     use's untagged; the tags per person's untagged. No filter, GB, NL, the NL line, the second NL
    --     line, NL with the GB line (nothing)
    v_txt := '';
    v_f := array[null, null, 'GB', null, 'NL', null, 'NL', v_nl, null, v_nl2, 'NL', v_gb];
    for v_i in 1 .. 6 loop
      select v_txt || case when v_i > 1 then ' | ' else '' end
             || (select o.calls || '/' || o.conversations || '/' || o.untagged_conversations
                 from cma.calls_overview('2026-10-26', '2026-11-01', v_f[2 * v_i - 1], v_f[2 * v_i], 'market') o
                 where o.period = 'current' and o.group_key is null)
             || ' ' || (select max(p.conversations) filter (where p.row_kind = 'total') || '/' || max(p.untagged_conversations) filter (where p.row_kind = 'total')
                               || '/' || coalesce(sum(p.conversations) filter (where p.row_kind <> 'total'), 0)
                        from cma.calls_per_person('2026-10-26', '2026-11-01', v_f[2 * v_i - 1], v_f[2 * v_i]) p)
             || ' ' || (select coalesce(sum(t.conversations), 0) from cma.calls_tag_use('2026-10-26', '2026-11-01', v_f[2 * v_i - 1], v_f[2 * v_i], 'line') t
                        where t.group_key is null and t.tag_key is null)
             || ' ' || (select coalesce(sum(t.conversations), 0) from cma.calls_per_person_tags('2026-10-26', '2026-11-01', v_f[2 * v_i - 1], v_f[2 * v_i]) t
                        where t.tag_key is null)
        into v_txt;
    end loop;
    v_rows := v_rows || array['15', 'B5 the market and line filters narrow every function alike',
      case when v_txt = '12/8/3 8/3/8 3 3 | 4/3/2 3/2/3 2 2 | 8/5/1 5/1/5 1 1 | 7/4/1 4/1/4 1 1 | 1/1/0 1/0/1 0 0 | 0/0/0 0/0/0 0 0'
                and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no rows')];

    -- B6. tag use by market: per market the conversations per tag, the most used first, then untagged;
    --     then the whole period
    select string_agg(coalesce(group_key, 'all') || ':' || coalesce(tag_name, '-') || '=' || conversations, ',' order by ordinality) into v_txt
    from cma.calls_tag_use('2026-10-26', '2026-11-01', null, null, 'market') with ordinality;
    v_rows := v_rows || array['16', 'B6 tag use grouped by market, then the whole period',
      case when v_txt = 'GB:Info=1,GB:Test=1,GB:-=2,NL:Sale=3,NL:Info=1,NL:Test=1,NL:-=1,all:Sale=3,all:Info=2,all:Test=2,all:-=3'
                and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no rows')];

    -- B7. the previous equal period (19 to 25 October, across the DST change): p1 and p2 at 02:30 CEST
    --     and CET, p3 at 23:30 CET, p6 at 23:30 GMT on 25 October, p4 on 19 October; not p5 (18
    --     October in Amsterdam) nor c0 (26 October 00:30 CET). By day and by ISO week over both weeks,
    --     each call in its line's zone; the previous period of those 14 days holds p5 only
    select format('%s/%s/%s %s/%s %s %s %s %s %s', calls, inbound, outbound, answered_inbound, connected_outbound, connected_pct,
                  conversations, talk_seconds_total, talk_seconds_avg, untagged_conversations) into v_txt
    from cma.calls_overview('2026-10-26', '2026-11-01', null, null, 'day') where period = 'previous';
    select v_txt || ' | ' || string_agg(group_key || '=' || calls, ',' order by group_key) into v_txt
    from cma.calls_overview('2026-10-19', '2026-11-01', null, null, 'day') where period = 'current' and group_key is not null;
    select v_txt || ' | ' || string_agg(coalesce(group_key, period) || '=' || calls, ',' order by ordinality) into v_txt
    from cma.calls_overview('2026-10-19', '2026-11-01', null, null, 'week') with ordinality;
    v_rows := v_rows || array['17', 'B7 the previous period''s totals, days and weeks across the DST change, each call in its line''s zone',
      case when v_txt = '5/3/2 3/1 50.0 4 120 30.0 4 | 2026-10-19=1,2026-10-25=4,2026-10-26=3,2026-10-27=2,2026-10-28=2,2026-10-29=2,2026-10-30=1,2026-10-31=1,2026-11-01=1'
                        || ' | 2026-10-19=5,2026-10-26=12,current=17,previous=1'
                and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no row')];

    -- B8. per person through the linked accounts, by name: Anna (tel-user-1), Bram (tel-user-2); the
    --     users without a person (tel-user-3, and tel-user-4 with two calls, whose id Cas holds for
    --     another adapter only) as one row with their count, each user once; the total. Then tel-user-3 linked to Cas: Cas gets a row of her
    --     own and one user is left without a person
    select string_agg(row_kind || ':' || coalesce(display_name, '-') || coalesce('(' || unlinked_users || ')', '')
                      || format(' in %s %s %s out %s/%s %s %s conv %s untagged %s %s-%s', answered_inbound, inbound_talk_seconds,
                                coalesce(inbound_talk_avg::text, '-'), outbound_calls, connected_outbound, outbound_talk_seconds,
                                coalesce(outbound_talk_avg::text, '-'), conversations, untagged_conversations,
                                to_char(first_call_time, 'HH24:MI'), to_char(last_call_time, 'HH24:MI')), ' | ' order by ordinality) into v_txt
    from cma.calls_per_person('2026-10-26', '2026-11-01', null, null) with ordinality;
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_user_external_id(v_cas, 'verifytel_user', 'tel-user-3');
    perform set_config('app.user_id', v_analyst1::text, true);
    select string_agg(row_kind || ':' || coalesce(display_name, '-') || coalesce('(' || unlinked_users || ')', '') || ' conv ' || conversations, ' | ' order by ordinality)
      into v_detail from cma.calls_per_person('2026-10-26', '2026-11-01', null, null) with ordinality;
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.remove_user_external_id(v_cas, 'verifytel_user');
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['18', 'B8 the per-person rows through linked accounts, by name; the users without a person as one counted row',
      case when v_txt = 'person:Anna Verify in 2 360 180.0 out 2/1 10 10.0 conv 3 untagged 1 00:30-16:00'
                        || ' | person:Bram Verify in 2 90 45.0 out 2/1 120 120.0 conv 3 untagged 1 10:00-16:30'
                        || ' | not_linked:-(2) in 1 90 90.0 out 2/1 40 40.0 conv 2 untagged 1 10:00-23:30'
                        || ' | total:- in 5 540 108.0 out 6/3 170 56.7 conv 8 untagged 3 00:30-23:30'
                and v_detail = 'person:Anna Verify conv 3 | person:Bram Verify conv 3 | person:Cas Verify conv 1 | not_linked:-(1) conv 1 | total:- conv 8'
                and not v_provoke then 'PASS' else 'FAIL' end,
      coalesce(v_txt, 'no rows') || ' || ' || coalesce(v_detail, 'no rows')];

    -- B9. permissions: the reader (reports.view only) reads the overview and the tag use and neither
    --     per-person read; the supervisor (performance.team only) reads all four; an agent and the Ingest
    --     user none (CMA06). Refused as invalid (CMA04): a group outside the four (twice), 93 days (twice),
    --     a market that is no code (twice), a line that is no connection:line key (twice)
    v_n := 0;
    perform set_config('app.user_id', v_reader1::text, true);
    begin perform cma.calls_overview('2026-10-26', '2026-11-01', null, null, 'week'); exception when others then v_n := v_n - 100; end;
    begin perform cma.calls_tag_use('2026-10-26', '2026-11-01', null, null, 'week'); exception when others then v_n := v_n - 100; end;
    begin perform cma.calls_per_person('2026-10-26', '2026-11-01', null, null); exception when sqlstate 'CMA06' then v_n := v_n + 1; end;
    begin perform cma.calls_per_person_tags('2026-10-26', '2026-11-01', null, null); exception when sqlstate 'CMA06' then v_n := v_n + 1; end;
    perform set_config('app.user_id', v_super1::text, true);
    begin
      select count(*) into v_i from cma.calls_per_person('2026-10-26', '2026-11-01', null, null);
      v_i := v_i + (select count(*) from cma.calls_per_person_tags('2026-10-26', '2026-11-01', null, null))
                 + (select count(*) from cma.calls_overview('2026-10-26', '2026-11-01', null, null, 'line'))
                 + (select count(*) from cma.calls_tag_use('2026-10-26', '2026-11-01', null, null, 'line'));
    exception when others then v_i := -1;
    end;
    foreach v_detail in array array[v_agent1::text, v_ing1::text] loop
      perform set_config('app.user_id', v_detail, true);
      begin perform cma.calls_overview('2026-10-26', '2026-11-01', null, null, 'day'); exception when sqlstate 'CMA06' then v_n := v_n + 1; end;
      begin perform cma.calls_tag_use('2026-10-26', '2026-11-01', null, null, 'day'); exception when sqlstate 'CMA06' then v_n := v_n + 1; end;
      begin perform cma.calls_per_person('2026-10-26', '2026-11-01', null, null); exception when sqlstate 'CMA06' then v_n := v_n + 1; end;
      begin perform cma.calls_per_person_tags('2026-10-26', '2026-11-01', null, null); exception when sqlstate 'CMA06' then v_n := v_n + 1; end;
    end loop;
    perform set_config('app.user_id', v_analyst1::text, true);
    begin perform cma.calls_overview('2026-10-26', '2026-11-01', null, null, 'hour'); exception when sqlstate 'CMA04' then v_n := v_n + 1; end;
    begin perform cma.calls_tag_use('2026-10-26', '2026-11-01', null, null, null); exception when sqlstate 'CMA04' then v_n := v_n + 1; end;
    begin perform cma.calls_overview('2026-07-01', '2026-10-01', null, null, 'day'); exception when sqlstate 'CMA04' then v_n := v_n + 1; end;
    begin perform cma.calls_per_person('2026-07-01', '2026-10-01', null, null); exception when sqlstate 'CMA04' then v_n := v_n + 1; end;
    begin perform cma.calls_overview('2026-10-26', '2026-11-01', 'Netherlands', null, 'day'); exception when sqlstate 'CMA04' then v_n := v_n + 1; end;
    begin perform cma.calls_per_person('2026-10-26', '2026-11-01', 'nl', null); exception when sqlstate 'CMA04' then v_n := v_n + 1; end;
    begin perform cma.calls_tag_use('2026-10-26', '2026-11-01', null, 'line-nl', 'day'); exception when sqlstate 'CMA04' then v_n := v_n + 1; end;
    begin perform cma.calls_per_person_tags('2026-10-26', '2026-11-01', null, 'x'); exception when sqlstate 'CMA04' then v_n := v_n + 1; end;
    v_rows := v_rows || array['19', 'B9 performance.team for both per-person reads, reports.view enough for the overview and the tag use; refusals',
      case when v_n = 18 and v_i = 4 + 7 + 5 + 12 and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s of 18 refusals; the supervisor read %s rows of 28', v_n, v_i)];

    -- B10. tenant isolation: tenant one's reads hold none of tenant two's calls or people, and tenant
    --      two's reads none of tenant one's, with the same line, user and tag refs; tenant one's reads
    --      of tenant two's id find nothing under row-level security; in the owner's rights each tenant's
    --      reads keep to their own calls and linked accounts
    select (select calls from cma.calls_overview('2026-10-26', '2026-11-01', null, null, 'day') where period = 'current' and group_key is null)
           || '/' || (select count(*) from cma.calls_per_person('2026-10-26', '2026-11-01', null, null) where display_name = 'Dora Verify')
           || '/' || (select count(*) from cma.calls_of(v_t2, null, null, null, null))
           || '/' || (select count(*) from cma.calls_per_person_of(v_t2, '2026-10-26', '2026-11-01', null, null) where row_kind = 'person')
      into v_txt;
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_analyst2::text, true);
    select v_txt || ' | ' || (select calls || '/' || conversations from cma.calls_overview('2026-10-26', '2026-11-01', null, null, 'day')
                              where period = 'current' and group_key is null)
           || '/' || (select string_agg(coalesce(display_name, row_kind), ',' order by ordinality) from cma.calls_per_person('2026-10-26', '2026-11-01', null, null) with ordinality)
           || '/' || (select string_agg(coalesce(tag_name, '-') || '=' || conversations, ',' order by ordinality)
                      from cma.calls_tag_use('2026-10-26', '2026-11-01', null, null, 'day') with ordinality where group_key is null)
           || '/' || (select count(*) from cma.calls_of(v_t1, null, null, null, null))
      into v_txt;
    perform set_config('role', 'cma_owner', true);
    select v_txt || ' | ' || (select string_agg(coalesce(display_name, row_kind), ',' order by ordinality)
                              from cma.calls_per_person_of(v_t1, '2026-10-26', '2026-11-01', null, null) with ordinality)
           || ' / ' || (select string_agg(coalesce(display_name, row_kind), ',' order by ordinality)
                        from cma.calls_per_person_of(v_t2, '2026-10-26', '2026-11-01', null, null) with ordinality)
      into v_txt;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['20', 'B10 tenant isolation with equal refs, also in the owner''s rights',
      case when v_txt = '12/0/0/0 | 2/2/Dora Verify,total/Sale=1,-=1/0 | Anna Verify,Bram Verify,not_linked,total / Dora Verify,total'
                and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no rows')];

    -- B11. no answer holds a hash, a line's digits, a call id (the CMA's or the telephony system's) or,
    --      in the application's reads, a telephony user id: every grouping and the per-person reads with
    --      and without filters, and the reads of an explicit tenant
    v_txt := '';
    foreach v_detail in array array['day', 'week', 'market', 'line'] loop
      v_txt := v_txt || coalesce((select string_agg(row_to_json(x)::text, '') from cma.calls_overview('2026-10-19', '2026-11-01', null, null, v_detail) x), '')
                     || coalesce((select string_agg(row_to_json(x)::text, '') from cma.calls_tag_use('2026-10-19', '2026-11-01', null, null, v_detail) x), '');
    end loop;
    v_txt := v_txt || coalesce((select string_agg(row_to_json(x)::text, '') from cma.calls_per_person('2026-10-19', '2026-11-01', null, null) x), '')
                   || coalesce((select string_agg(row_to_json(x)::text, '') from cma.calls_per_person_tags('2026-10-19', '2026-11-01', null, null) x), '')
                   || coalesce((select string_agg(row_to_json(x)::text, '') from cma.calls_per_person('2026-10-26', '2026-11-01', 'GB', null) x), '')
                   || coalesce((select string_agg(row_to_json(x)::text, '') from cma.calls_per_person_tags('2026-10-26', '2026-11-01', null, v_nl2) x), '');
    select count(*) into v_n from unnest(array['tel-user-']) u where strpos(v_txt, u) > 0;
    v_txt := v_txt || coalesce((select string_agg(row_to_json(x)::text, '') from cma.calls_of(v_t1, null, null, null, null) x), '')
                   || coalesce((select string_agg(row_to_json(x)::text, '') from cma.calls_people_of(v_t1, '2026-10-19', '2026-11-01', null, null) x), '');
    perform set_config('role', 'cma_owner', true);
    select v_n + count(*) into v_n
    from (select h from unnest(v_h) h
          union all select id::text from cma.telephony_call where tenant_id = v_t1
          union all select source_id from cma.telephony_call where tenant_id = v_t1
          union all select digits from cma.telephony_number where tenant_id = v_t1
          union all select substr(digits, 2) from cma.telephony_number where tenant_id = v_t1) s(h)
    where strpos(v_txt, s.h) > 0 or strpos(v_txt, upper(s.h)) > 0;
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['21', 'B11 no hash, number, call id or telephony user id in any answer',
      case when v_n = 0 and length(v_txt) > 2000 and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s found in %s characters of answers', v_n, length(v_txt))];

    -- B12. the overview per market and its total, computed over every call (not summed): calls, inbound,
    --      outbound, answered inbound, connected outbound and its share, conversations, their talk time
    --      and its average, the connected outbound calls' talk time and its average, untagged; then the
    --      previous period. The deleted call d1 is in none of them
    select string_agg(coalesce(group_key, period) || format(':%s/%s/%s %s/%s %s %s %s %s out %s %s %s', calls, inbound, outbound, answered_inbound,
                      connected_outbound, coalesce(connected_pct::text, '-'), conversations, talk_seconds_total,
                      coalesce(talk_seconds_avg::text, '-'), outbound_talk_seconds, coalesce(outbound_talk_avg::text, '-'),
                      untagged_conversations), ' | ' order by ordinality) into v_txt
    from cma.calls_overview('2026-10-26', '2026-11-01', null, null, 'market') with ordinality;
    v_rows := v_rows || array['22', 'B12 the overview per market, the computed total and the previous period',
      case when v_txt = 'GB:4/1/3 1/2 66.7 3 220 73.3 out 160 80.0 2 | NL:8/5/3 4/1 33.3 5 490 98.0 out 10 10.0 1'
                        || ' | current:12/6/6 5/3 50.0 8 710 88.8 out 170 56.7 3 | previous:5/3/2 3/1 50.0 4 120 30.0 out 20 20.0 4'
                and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no rows')];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['39', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008j (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008j values (39, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008j
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED: not dev'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008j where result = 'PASS') = 16
                       and not exists (select 1 from verify_0008j where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0008j where result = 'PASS'),
                                        (select count(*) from verify_0008j where result <> 'PASS'))) x
order by ord;
drop function if exists pg_temp.v0008j_call(text, text, timestamptz, numeric, numeric, text, text, text, jsonb);
reset role;
