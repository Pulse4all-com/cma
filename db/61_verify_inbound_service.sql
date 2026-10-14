-- =============================================================================================
-- 61_verify_inbound_service.sql: verifies addition 0008i, inbound service level and missed calls
-- not called back
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure
-- and privileges; block B works on three throwaway tenants inside a subtransaction that is always
-- rolled back. Universal otherwise: nothing of the seed is used; adapters, lines, reason codes,
-- calls and hashes are invented data values (no hash below is made from a real number). Every
-- check writes one row, PASS or FAIL, and the last result lists them with the verdict, because
-- Cloud SQL Studio shows no notices. Run as your own IAM login in dev, after 60_inbound_service.sql
-- and the 02 rerun; then 35, 41, 53 and 55 again (unchanged).
--   A  structure and privileges: the addition row; the catalog table with its key, row-level
--      security, audit, no delete for the application and its reporting view; the three settings
--      with their defaults; every function the application's only, in the caller's rights; no
--      function returns a hash, and the hash's comment names its three purposes
--   B  behaviour. Tenant one (Europe/Helsinki; lines in NL, GB and without a market) on fixed
--      dates: the service level with and without an excluded reason and a call answered at exactly
--      N seconds; average and 80th percentile time to answer and the total row; hours and dates
--      across the DST change of 25 October 2026 in each line's zone; a line without a market in
--      the tenant's zone; an unknown code with the defaults and a missing reason as unknown; a
--      deleted call never counted. Tenant two (Europe/Amsterdam) relative to now: calls waiting
--      and a lost call left out; callbacks (a caller missed twice, called back by an outbound call
--      on another connection and by an answered inbound call, an outbound call before the missed
--      call, a later missed call that calls nobody back, the lookback, a reason without a callback,
--      anonymous calls); tenant three with tenant two's hash strings, also in the owner's rights.
--      The hash in no answer; the catalog written by a configuring person only, with its refusals;
--      the permissions of the reads and tenant isolation. Last, times missed since the latest
--      callback: missed, called back, missed again later counts 1 (by outbound calls, the latest of
--      two, and by an answered inbound call)
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
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 61 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0008i;
create temp table verify_0008i (ord int, check_name text, result text, detail text);

-- One telephony call as the ingest write takes it: answered after p_answer seconds (null: never),
-- ended after p_end seconds (null: not ended), the reason, the line and the hash as given
create or replace function pg_temp.v0008i_call(p_src text, p_dir text, p_start timestamptz, p_answer numeric, p_end numeric,
                                               p_reason text, p_line text, p_hash text)
returns jsonb
language sql immutable
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'sourceId', p_src, 'direction', p_dir, 'startedAt', p_start,
    'answeredAt', p_start + make_interval(secs => p_answer::double precision),
    'endedAt', p_start + make_interval(secs => p_end::double precision),
    'missedReason', p_reason, 'numberRef', p_line, 'counterpartHash', p_hash,
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
  -- A1. the addition is recorded
  insert into verify_0008i values (1, 'A1 addition 0008i recorded',
    case when exists (select 1 from cma.schema_migration where version = '0008i') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. the catalog: its columns, the key (tenant, source system, code), row-level security with the
  --     application's policy, the audit trigger, no delete for the application, the reporting view
  --     for readers and not the table
  v_bad := '';
  select string_agg(column_name, ', ' order by ordinal_position) into v_cols
  from information_schema.columns where table_schema = 'cma' and table_name = 'telephony_missed_reason';
  if v_cols is distinct from 'tenant_id, source_system, code, label, counts_in_service_level, needs_callback, updated_at' then
    v_bad := v_bad || format('columns [%s]; ', coalesce(v_cols, 'missing'));
  end if;
  if to_regclass('cma.telephony_missed_reason') is null then
    v_bad := v_bad || 'no table; ';
  else
    if not exists (select 1 from pg_constraint where conrelid = 'cma.telephony_missed_reason'::regclass and contype = 'p'
                     and pg_get_constraintdef(oid) = 'PRIMARY KEY (tenant_id, source_system, code)') then
      v_bad := v_bad || 'key; ';
    end if;
    if not (select relrowsecurity from pg_class where oid = 'cma.telephony_missed_reason'::regclass)
       or not exists (select 1 from pg_policies where schemaname = 'cma' and tablename = 'telephony_missed_reason' and policyname = 'tenant_app')
       or not exists (select 1 from pg_trigger where tgrelid = 'cma.telephony_missed_reason'::regclass and tgname = 'audit') then
      v_bad := v_bad || 'row-level security, policy or audit; ';
    end if;
    if has_table_privilege('cma_app', 'cma.telephony_missed_reason', 'delete') or not has_table_privilege('cma_app', 'cma.telephony_missed_reason', 'update') then
      v_bad := v_bad || 'the application deletes or cannot update; ';
    end if;
    if not has_table_privilege('cma_readonly', 'cma_read.telephony_missed_reason', 'select')
       or has_table_privilege('cma_readonly', 'cma.telephony_missed_reason', 'select') then
      v_bad := v_bad || 'readers must see the view and not the table; ';
    end if;
  end if;
  insert into verify_0008i values (2, 'A2 the missed-reason catalog: key, row-level security, audit, no delete, the readers'' view',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A3. the three settings with their types and universal defaults (named, since 0008j adds a fourth
  --     telephony setting, telephony.connected_min_seconds, which 63 checks)
  select string_agg(key || '=' || value_type || ':' || default_value, ', ' order by key) into v_cols
  from cma.setting where key in ('telephony.service_level_seconds', 'telephony.callback_lookback_days', 'telephony.waiting_max_minutes');
  insert into verify_0008i values (3, 'A3 the settings: service level 20 s, lookback 3 days, waiting at most 30 minutes',
    case when v_cols = 'telephony.callback_lookback_days=integer:3, telephony.service_level_seconds=integer:20, telephony.waiting_max_minutes=integer:30'
              and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_cols, 'none'));

  -- A4. every function exists, executable by the application only, in the caller's rights
  v_bad := '';
  foreach v_fn in array array[
    'cma.inbound_service(date,date,text)', 'cma.inbound_today()', 'cma.missed_callbacks()', 'cma.missed_callbacks_summary()',
    'cma.missed_reasons()', 'cma.connection_missed_reasons(uuid)', 'cma.set_telephony_missed_reason(uuid,text,text,boolean,boolean)',
    'cma.inbound_calls_of(uuid,timestamptz,timestamptz)', 'cma.inbound_service_of(uuid,date,date,text)', 'cma.inbound_today_of(uuid)',
    'cma.missed_callbacks_of(uuid)', 'cma.missed_callbacks_summary_of(uuid)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' is missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                     where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      v_bad := v_bad || v_fn || ' is not the application''s only, in the caller''s rights; ';
    end if;
  end loop;
  insert into verify_0008i values (4, 'A4 the functions are the application''s only, in the caller''s rights',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- A5. no function of the addition returns a hash, a phone or a number column, and the hash's
  --     comment names its three purposes (the call link, order matching, callback matching)
  select string_agg(p.proname || '.' || a.name, ', ') into v_cols
  from pg_proc p
  cross join lateral unnest(coalesce(p.proargnames, '{}'::text[]), coalesce(p.proargmodes::text[], '{}'::text[])) as a(name, mode)
  where p.pronamespace = 'cma'::regnamespace
    and p.proname in ('inbound_service', 'inbound_today', 'missed_callbacks', 'missed_callbacks_summary', 'missed_reasons',
                      'inbound_calls_of', 'inbound_service_of', 'inbound_today_of', 'missed_callbacks_of', 'missed_callbacks_summary_of')
    and a.mode in ('t', 'o') and (a.name like '%hash%' or a.name like '%phone%' or a.name like '%digits%' or a.name like '%number%');
  v_bad := coalesce(v_cols, '');
  if coalesce(col_description('cma.telephony_call'::regclass,
                              (select attnum from pg_attribute where attrelid = 'cma.telephony_call'::regclass and attname = 'counterpart_hash')), '')
     !~ '0007a.*0008g.*0008i' then
    v_bad := v_bad || ' the comment on counterpart_hash does not name its three purposes';
  end if;
  insert into verify_0008i values (5, 'A5 no function returns the hash; its comment names three purposes',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);
end
$$;

-- B. Behaviour on three throwaway tenants (rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_rows     text[] := '{}';
  v_t1 uuid; v_t2 uuid; v_t3 uuid;
  v_admin1 uuid; v_agent1 uuid; v_analyst1 uuid; v_ing1 uuid;
  v_admin2 uuid; v_analyst2 uuid; v_ing2 uuid;
  v_admin3 uuid; v_analyst3 uuid; v_ing3 uuid;
  v_tel1 uuid; v_crm1 uuid; v_crm1b uuid; v_tel2 uuid; v_tel2b uuid; v_tel3 uuid;
  v_txt      text;
  v_detail   text;
  v_ok       boolean;
  v_n        integer;
  v_j        jsonb;
  r          record;
  v_now      timestamptz := now();
  v_d        timestamptz := timestamptz '2026-09-15 10:00:00+00';   -- a Tuesday, CEST
  v_h        text[] := array[repeat('a1', 32), repeat('a2', 32), repeat('a3', 32), repeat('a4', 32), repeat('a5', 32),
                             repeat('a6', 32), repeat('a7', 32), repeat('a8', 32), repeat('a9', 32), repeat('b1', 32),
                             repeat('b2', 32), repeat('b3', 32)];
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    v_t1 := cma.create_tenant('verify-0008i-one', 'Verify 0008i one', 'Europe/Helsinki');
    v_t2 := cma.create_tenant('verify-0008i-two', 'Verify 0008i two', 'Europe/Amsterdam');
    v_t3 := cma.create_tenant('verify-0008i-three', 'Verify 0008i three', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent1@example.invalid', 'agent1') returning id into v_agent1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-analyst1@example.invalid', 'analyst1') returning id into v_analyst1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin2') returning id into v_admin2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-analyst2@example.invalid', 'analyst2') returning id into v_analyst2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t3, 'verify-admin3@example.invalid', 'admin3') returning id into v_admin3;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t3, 'verify-analyst3@example.invalid', 'analyst3') returning id into v_analyst3;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_agent1, 'agent'), (v_t1, v_analyst1, 'analytics'),
                 (v_t2, v_admin2, 'admin'), (v_t2, v_analyst2, 'analytics'),
                 (v_t3, v_admin3, 'admin'), (v_t3, v_analyst3, 'analytics')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    select x.user_id into v_ing2 from cma.app_user_external_id x where x.tenant_id = v_t2 and x.system = 'ingest';
    select x.user_id into v_ing3 from cma.app_user_external_id x where x.tenant_id = v_t3 and x.system = 'ingest';
    perform set_config('role', 'cma_app', true);

    -- tenant one: markets NL and GB with office hours, a telephony and a CRM connection, three lines
    -- (NL, GB, none), two reasons of its own: short_abandoned out of the service level,
    -- out_of_opening_hours out of it and without a callback
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.upsert_market('GB', 'United Kingdom', 'Europe/London', 'en', 'GBP');
    perform cma.set_business_hours('*', d::smallint, '09:00-17:00') from generate_series(1, 5) d;
    select c.connection_id into v_tel1 from cma.upsert_connection('verifytel', 'Verify phones one', 'company-1', null, null) c;
    select c.connection_id into v_crm1 from cma.upsert_connection('verifycrm', 'Verify records one', 'portal-1', null, null) c;
    perform cma.set_connection_kind(v_crm1, 'crm');
    -- a connection without a kind whose rows are a CRM's (a form)
    select c.connection_id into v_crm1b from cma.upsert_connection('verifycrm', 'Verify records one b', 'portal-1b', null, null) c;
    perform cma.set_form(v_crm1b, 'form-1', true, null, null, '{}');
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_telephony_catalog(v_tel1, 'number', '[{"numberRef": "line-nl", "name": "Verify NL line"},
      {"numberRef": "line-gb", "name": "Verify GB line"}, {"numberRef": "line-none", "name": "Verify line without market"}]'::jsonb);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_telephony_number(v_tel1, 'line-nl', 'NL', true);
    perform cma.set_telephony_number(v_tel1, 'line-gb', 'GB', true);
    perform cma.set_telephony_missed_reason(v_tel1, 'short_abandoned', 'Hung up early', false, true);
    perform cma.set_telephony_missed_reason(v_tel1, 'out_of_opening_hours', 'Outside hours', false, false);

    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_telephony_calls(v_tel1, jsonb_build_array(
      -- 15 September (NL line): answered at 10, 20 and 21 seconds; unanswered for three reasons
      pg_temp.v0008i_call('s-1', 'inbound', v_d, 10, 100, null, 'line-nl', null),
      pg_temp.v0008i_call('s-2', 'inbound', v_d + interval '1 minute', 20, 100, null, 'line-nl', null),
      pg_temp.v0008i_call('s-3', 'inbound', v_d + interval '2 minutes', 21, 100, null, 'line-nl', null),
      pg_temp.v0008i_call('s-4', 'inbound', v_d + interval '3 minutes', null, 40, 'no_available_agent', 'line-nl', null),
      pg_temp.v0008i_call('s-5', 'inbound', v_d + interval '4 minutes', null, 5, 'short_abandoned', 'line-nl', null),
      pg_temp.v0008i_call('s-6', 'inbound', v_d + interval '5 minutes', null, 30, null, 'line-nl', null),
      pg_temp.v0008i_call('s-7', 'outbound', v_d + interval '6 minutes', 5, 60, null, 'line-nl', null),
      -- 17 September: a code nobody configured, a missing and an empty reason
      pg_temp.v0008i_call('u-1', 'inbound', v_d + interval '2 days', null, 30, 'brand_new_code', 'line-gb', null),
      pg_temp.v0008i_call('u-2', 'inbound', v_d + interval '2 days 1 minute', null, 30, null, 'line-gb', null),
      pg_temp.v0008i_call('u-3', 'inbound', v_d + interval '2 days 2 minutes', null, 30, '', 'line-gb', null),
      -- 25 October, the DST change: NL at 01:30 CEST (24 Oct 23:30 UTC), 02:30 CEST and 02:30 CET;
      -- GB at 01:30 BST and 01:30 GMT
      pg_temp.v0008i_call('t-1', 'inbound', timestamptz '2026-10-24 23:30:00+00', 8, 60, null, 'line-nl', null),
      pg_temp.v0008i_call('t-2', 'inbound', timestamptz '2026-10-25 00:30:00+00', 8, 60, null, 'line-nl', null),
      pg_temp.v0008i_call('t-3', 'inbound', timestamptz '2026-10-25 01:30:00+00', 8, 60, null, 'line-nl', null),
      pg_temp.v0008i_call('t-4', 'inbound', timestamptz '2026-10-25 00:30:00+00', 8, 60, null, 'line-gb', null),
      pg_temp.v0008i_call('t-5', 'inbound', timestamptz '2026-10-25 01:30:00+00', 8, 60, null, 'line-gb', null),
      -- 21 October 21:30 UTC on the line without a market: 22 October 00:30 in Helsinki (the
      -- tenant's zone), 21 October 23:30 in Amsterdam
      pg_temp.v0008i_call('m-1', 'inbound', timestamptz '2026-10-21 21:30:00+00', null, 30, 'no_available_agent', 'line-none', null),
      -- 15 September: a call the telephony system deleted afterwards (below), never counted
      pg_temp.v0008i_call('s-8', 'inbound', v_d + interval '7 minutes', null, 30, 'no_available_agent', 'line-nl', null)));
    perform cma.ingest_upsert_telephony_calls(v_tel1, jsonb_build_array(
      jsonb_build_object('sourceId', 's-8', 'deletedAt', v_d + interval '1 day', 'versionAt', v_d + interval '1 day')));
    perform set_config('app.user_id', v_analyst1::text, true);

    -- B1. the service level: answered within 20 s (10 and exactly 20) over the calls whose reason
    --     counts (three answered, no_available_agent and the missing reason): 2 / 5; with
    --     short_abandoned counted too: 2 / 6
    select format('%s/%s/%s/%s within %s of %s = %s; reasons %s', offered, answered, unanswered, waiting, answered_within_target,
                  service_level_base, service_level_pct, unanswered_by_reason)
      into v_txt from cma.inbound_service('2026-09-15', '2026-09-15', 'day');
    v_ok := v_txt = '6/3/3/0 within 2 of 5 = 40.0; reasons {"unknown": 1, "short_abandoned": 1, "no_available_agent": 1}';
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_telephony_missed_reason(v_tel1, 'short_abandoned', 'Hung up early', true, true);
    perform set_config('app.user_id', v_analyst1::text, true);
    select format('within %s of %s = %s', answered_within_target, service_level_base, service_level_pct)
      into v_detail from cma.inbound_service('2026-09-15', '2026-09-15', 'day');
    v_ok := v_ok and v_detail = 'within 2 of 6 = 33.3';
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_telephony_missed_reason(v_tel1, 'short_abandoned', 'Hung up early', false, true);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['11', 'B1 the service level with and without an excluded reason, a call at exactly N seconds',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no row') || ' | ' || coalesce(v_detail, 'no row')];

    -- B2. average and 80th percentile time to answer over 10, 20 and 21 seconds: 17.0 and 20.6
    --     (percentile_cont); the outbound call is not offered. The total row (group null) over 15
    --     to 17 September by market: NL's six calls and GB's three, computed over every call
    select format('avg %s, p80 %s', avg_answer_seconds, p80_answer_seconds) into v_txt
    from cma.inbound_service('2026-09-15', '2026-09-15', 'line') where group_key is not null;
    select string_agg(coalesce(group_key, 'total') || ':' || offered || '/' || answered || '/' || unanswered || ' '
                      || answered_within_target || ' of ' || service_level_base || ' = ' || coalesce(service_level_pct::text, '-')
                      || ' avg ' || coalesce(avg_answer_seconds::text, '-') || ' p80 ' || coalesce(p80_answer_seconds::text, '-')
                      || ' ' || unanswered_by_reason, ' | ') into v_detail
    from cma.inbound_service('2026-09-15', '2026-09-17', 'market');
    v_ok := v_txt = 'avg 17.0, p80 20.6'
            and v_detail = 'GB:3/0/3 0 of 3 = 0.0 avg - p80 - {"unknown": 2, "brand_new_code": 1}'
                           || ' | NL:6/3/3 2 of 5 = 40.0 avg 17.0 p80 20.6 {"unknown": 1, "short_abandoned": 1, "no_available_agent": 1}'
                           || ' | total:9/3/6 2 of 8 = 25.0 avg 17.0 p80 20.6 {"unknown": 3, "brand_new_code": 1, "short_abandoned": 1, "no_available_agent": 1}';
    v_rows := v_rows || array['12', 'B2 average and 80th percentile time to answer; the total row computed over every call',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no row') || ' | ' || coalesce(v_detail, 'no rows')];

    -- B3. 25 October by hour, each call in its line's zone: NL 01:30 CEST, 02:30 CEST, 02:30 CET; GB
    --     01:30 BST, 01:30 GMT: hour 01 three calls, hour 02 two; and all five on the 25th by day
    select string_agg(group_key || '=' || offered, ',' order by group_key) into v_txt
    from cma.inbound_service('2026-10-25', '2026-10-25', 'hour');
    select string_agg(group_key || '=' || offered, ',' order by group_key) into v_detail
    from cma.inbound_service('2026-10-24', '2026-10-25', 'day');
    v_rows := v_rows || array['13', 'B3 hours and dates across the DST change of 25 October 2026, each in its line''s zone',
      case when v_txt = '01=3,02=2' and v_detail = '2026-10-25=5' and not v_provoke then 'PASS' else 'FAIL' end,
      coalesce(v_txt, 'no row') || ' | ' || coalesce(v_detail, 'no row')];

    -- B4. the line without a market: its call falls on 22 October at 00 in the tenant's zone
    --     (Helsinki), under the market unknown and the line's name
    select string_agg(group_key || '=' || offered, ',') into v_txt from cma.inbound_service('2026-10-21', '2026-10-22', 'day');
    select v_txt || ' | ' || string_agg(group_key || '=' || offered, ',') into v_txt from cma.inbound_service('2026-10-21', '2026-10-22', 'hour');
    select v_txt || ' | ' || string_agg(group_key || '=' || offered, ',') into v_txt from cma.inbound_service('2026-10-21', '2026-10-22', 'market');
    select v_txt || ' | ' || string_agg(group_label || '=' || offered, ',') into v_txt from cma.inbound_service('2026-10-21', '2026-10-22', 'line');
    v_rows := v_rows || array['14', 'B4 a line without a market: the tenant''s zone, market unknown, the line''s name',
      case when v_txt = '2026-10-22=1 | 00=1 | unknown=1 | Verify line without market=1' and not v_provoke then 'PASS' else 'FAIL' end,
      coalesce(v_txt, 'no row')];

    -- B5. a code nobody configured counts with the defaults (in the service level, its own code as
    --     label on Sources); a missing and an empty reason are unknown
    select format('%s of %s; %s', answered_within_target, service_level_base, unanswered_by_reason) into v_txt
    from cma.inbound_service('2026-09-17', '2026-09-17', 'market');
    perform set_config('app.user_id', v_admin1::text, true);
    v_j := cma.connection_missed_reasons(v_tel1);
    perform set_config('app.user_id', v_analyst1::text, true);
    select string_agg(format('%s:%s:%s:%s:%s:%s', e ->> 'code', e ->> 'label', e ->> 'countsInServiceLevel', e ->> 'needsCallback',
                             e ->> 'inCatalog', e ->> 'seenCalls'), ',') into v_detail
    from jsonb_array_elements(v_j -> 'missedReasons') e;
    v_ok := v_txt = '0 of 3; {"unknown": 2, "brand_new_code": 1}'
            and v_detail = 'brand_new_code:brand_new_code:true:true:false:1,no_available_agent:no_available_agent:true:true:false:2,'
                           'out_of_opening_hours:Outside hours:false:false:true:0,short_abandoned:Hung up early:false:true:true:1,unknown:unknown:true:true:false:3'
            and v_j ->> 'sourceSystem' = 'verifytel' and v_j ->> 'sampleCallId' = 't-5';
    v_rows := v_rows || array['15', 'B5 an unknown code counts with the defaults; a missing reason is unknown',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no row') || ' | ' || coalesce(v_detail, 'no reasons')];

    -- tenant two, relative to now: two telephony connections, one line in NL; callers by hash
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.set_business_hours('*', d::smallint, '00:00-24:00') from generate_series(1, 7) d;
    select c.connection_id into v_tel2 from cma.upsert_connection('verifytel', 'Verify phones two', 'company-2', null, null) c;
    select c.connection_id into v_tel2b from cma.upsert_connection('verifytel', 'Verify phones two b', 'company-2b', null, null) c;
    perform cma.set_telephony_number(v_tel2, 'line-nl', 'NL', true);
    perform cma.set_telephony_missed_reason(v_tel2, 'out_of_opening_hours', 'Outside hours', false, false);
    perform set_config('app.user_id', v_ing2::text, true);
    perform cma.ingest_upsert_telephony_calls(v_tel2, jsonb_build_array(
      -- waiting: 5 minutes ago, not answered, not ended; lost: 40 minutes ago, never ended
      pg_temp.v0008i_call('w-1', 'inbound', v_now - interval '5 minutes', null, null, null, 'line-nl', v_h[9]),
      pg_temp.v0008i_call('w-2', 'inbound', v_now - interval '40 minutes', null, null, null, 'line-none', v_h[10]),
      pg_temp.v0008i_call('w-3', 'inbound', v_now - interval '2 minutes', 4, null, null, 'line-nl', null),
      -- caller 1 missed twice
      pg_temp.v0008i_call('c1-a', 'inbound', v_now - interval '3 hours', null, 30, 'no_available_agent', 'line-nl', v_h[1]),
      pg_temp.v0008i_call('c1-b', 'inbound', v_now - interval '1 hour', null, 30, 'agents_did_not_answer', 'line-nl', v_h[1]),
      -- caller 2 missed, then called back on the other connection (not connected)
      pg_temp.v0008i_call('c2-a', 'inbound', v_now - interval '2 hours', null, 30, 'no_available_agent', 'line-nl', v_h[2]),
      -- caller 3 missed, then called in again and answered
      pg_temp.v0008i_call('c3-a', 'inbound', v_now - interval '2 hours', null, 30, 'no_available_agent', 'line-nl', v_h[3]),
      pg_temp.v0008i_call('c3-b', 'inbound', v_now - interval '30 minutes', 10, 200, null, 'line-nl', v_h[3]),
      -- caller 4 called by the team before, then missed
      pg_temp.v0008i_call('c4-o', 'outbound', v_now - interval '5 hours', 6, 90, null, 'line-nl', v_h[4]),
      pg_temp.v0008i_call('c4-a', 'inbound', v_now - interval '2 hours', null, 30, 'abandoned_in_ivr', 'line-nl', v_h[4]),
      -- caller 5 missed four days ago (the lookback is 3 days)
      pg_temp.v0008i_call('c5-a', 'inbound', v_now - interval '4 days', null, 30, 'no_available_agent', 'line-nl', v_h[5]),
      -- caller 6 missed outside opening hours, a reason without a callback
      pg_temp.v0008i_call('c6-a', 'inbound', v_now - interval '2 hours', null, 30, 'out_of_opening_hours', 'line-nl', v_h[6]),
      -- caller 7 missed, then missed again for a reason without a callback: a later missed call calls
      -- nobody back, so the first one is listed, missed twice
      pg_temp.v0008i_call('c7-a', 'inbound', v_now - interval '150 minutes', null, 30, 'no_available_agent', 'line-nl', v_h[7]),
      pg_temp.v0008i_call('c7-b', 'inbound', v_now - interval '20 minutes', null, 30, 'out_of_opening_hours', 'line-nl', v_h[7]),
      -- anonymous: two missed calls that need a callback, one that does not
      pg_temp.v0008i_call('an-1', 'inbound', v_now - interval '2 hours', null, 30, 'no_available_agent', 'line-nl', null),
      pg_temp.v0008i_call('an-2', 'inbound', v_now - interval '90 minutes', null, 30, null, 'line-nl', null),
      pg_temp.v0008i_call('an-3', 'inbound', v_now - interval '80 minutes', null, 30, 'out_of_opening_hours', 'line-nl', null)));
    perform cma.ingest_upsert_telephony_calls(v_tel2b, jsonb_build_array(
      pg_temp.v0008i_call('c2-o', 'outbound', v_now - interval '1 hour', null, 25, null, 'line-b', v_h[2])));

    -- tenant three: the same hash strings; an outbound call to caller 1 after caller 1's missed call
    -- in tenant two, and a missed call from caller 2, whom tenant two called back
    perform set_config('app.tenant_id', v_t3::text, true);
    perform set_config('app.user_id', v_admin3::text, true);
    select c.connection_id into v_tel3 from cma.upsert_connection('verifytel', 'Verify phones three', 'company-3', null, null) c;
    perform set_config('app.user_id', v_ing3::text, true);
    perform cma.ingest_upsert_telephony_calls(v_tel3, jsonb_build_array(
      pg_temp.v0008i_call('x-1', 'outbound', v_now - interval '10 minutes', 5, 60, null, 'line-x', v_h[1]),
      pg_temp.v0008i_call('x-2', 'inbound', v_now - interval '3 hours', null, 30, 'no_available_agent', 'line-x', v_h[2])));
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_analyst2::text, true);

    -- B6. waiting now: the call of 5 minutes ago, not the lost one of 40 minutes (past
    --     waiting_max_minutes, so unanswered as unknown); the longest wait about 300 seconds;
    --     today's figures add up
    select format('%s waiting, longest %s, N %s, max %s', waiting_now,
                  case when longest_waiting_seconds between 295 and 330 then '~300' else longest_waiting_seconds::text end,
                  service_level_seconds, waiting_max_minutes),
           offered = answered + unanswered + waiting
      into v_txt, v_ok from cma.inbound_today();
    select string_agg(source_id || ':' || is_waiting || ':' || coalesce(reason_code, '-'), ',' order by source_id) into v_detail
    from cma.inbound_calls_of(v_t2, v_now - interval '1 hour', null) where source_id like 'w-%';
    v_ok := v_ok and v_txt = '1 waiting, longest ~300, N 20, max 30' and v_detail = 'w-1:true:-,w-2:false:unknown,w-3:false:-';
    v_rows := v_rows || array['16', 'B6 waiting now; a call older than waiting_max_minutes is left out',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no row') || ' | ' || coalesce(v_detail, 'no calls')];

    -- B7. callbacks: caller 1 (missed twice) is one row with the latest call and its reason, count 2;
    --     caller 7's later missed call (no callback needed) calls nobody back, so its first call is
    --     listed, count 2; the order is oldest first: caller 7 (2.5 h), caller 4 (2 h), caller 1 (1 h),
    --     the lost call (40 min, on a line without a market: no business seconds)
    select string_agg(format('%s:%s:%s:%s', source_id, reason_code, missed_count,
                             case when waiting_business_seconds is null then 'none' when waiting_business_seconds > 0 then 'business' else 'zero' end),
                      ',' order by started_at) into v_txt
    from cma.missed_callbacks();
    v_rows := v_rows || array['17', 'B7 a caller missed twice is one row with missed_count 2; oldest first',
      case when v_txt = 'c7-a:no_available_agent:2:business,c4-a:abandoned_in_ivr:1:business,c1-b:agents_did_not_answer:2:business,w-2:unknown:1:none' and not v_provoke then 'PASS' else 'FAIL' end,
      coalesce(v_txt, 'no rows')];

    -- B8. called back: caller 2 by an outbound attempt on the other connection that never connected,
    --     caller 3 by an answered inbound call; caller 4's outbound call before the missed call does
    --     not count (caller 4 is listed above)
    select string_agg(source_id, ',') into v_txt from cma.missed_callbacks() where source_id in ('c2-a', 'c3-a', 'c4-a');
    v_rows := v_rows || array['18', 'B8 called back by an outbound attempt and by an answered inbound call; an earlier outbound call does not count',
      case when v_txt = 'c4-a' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'none listed')];

    -- B9. the lookback: caller 5 (four days ago) is out with 3 days and in with 5; caller 6's reason
    --     needs no callback
    select count(*) filter (where source_id = 'c5-a') || '/' || count(*) filter (where source_id = 'c6-a') into v_txt from cma.missed_callbacks();
    perform set_config('app.user_id', v_admin2::text, true);
    perform cma.set_tenant_setting('telephony.callback_lookback_days', '5');
    perform set_config('app.user_id', v_analyst2::text, true);
    select v_txt || ' then ' || count(*) filter (where source_id = 'c5-a') || '/' || count(*) filter (where source_id = 'c6-a') || ', lookback '
           || (select lookback_days from cma.missed_callbacks_summary())
      into v_txt from cma.missed_callbacks();
    perform set_config('app.user_id', v_admin2::text, true);
    perform cma.set_tenant_setting('telephony.callback_lookback_days', null);
    perform set_config('app.user_id', v_analyst2::text, true);
    v_rows := v_rows || array['19', 'B9 a call older than the lookback; a reason without a callback',
      case when v_txt = '0/0 then 1/0, lookback 5' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no rows')];

    -- B10. anonymous: the two missed calls without a hash that need a callback are counted and never
    --      listed; the one outside opening hours is not counted
    select format('listed %s, anonymous %s, lookback %s', listed, anonymous_count, lookback_days) into v_txt from cma.missed_callbacks_summary();
    v_ok := v_txt = 'listed 4, anonymous 2, lookback 3'
            and not exists (select 1 from cma.missed_callbacks() where source_id like 'an-%');
    v_rows := v_rows || array['20', 'B10 anonymous calls counted, not listed',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no row')];

    -- B11. tenant three's call to caller 1's hash string does not call tenant two's caller 1 back (B7
    --      lists c1-b); tenant three lists caller 2, whom only tenant two called back; the same in the
    --      owner's rights, where row-level security does not hide the other tenant's calls
    perform set_config('app.tenant_id', v_t3::text, true);
    perform set_config('app.user_id', v_analyst3::text, true);
    select string_agg(source_id, ',') into v_txt from cma.missed_callbacks();
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_analyst2::text, true);
    v_ok := v_txt = 'x-2' and exists (select 1 from cma.missed_callbacks() where source_id = 'c1-b');
    -- and in the owner's rights, where row-level security does not apply (Studio, the runbook's check)
    perform set_config('role', 'cma_owner', true);
    v_ok := v_ok and exists (select 1 from cma.missed_callbacks_of(v_t2) where source_id = 'c1-b')
            and exists (select 1 from cma.missed_callbacks_of(v_t3) where source_id = 'x-2');
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['21', 'B11 another tenant''s same hash string does not match, also in the owner''s rights',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'none in tenant three')];

    -- B12. no answer of any function holds a hash: the reads of tenant two and tenant one, as the
    --      analyst and as the admin, and the reporting view
    v_txt := '';
    v_txt := v_txt || coalesce((select string_agg(row_to_json(x)::text, '') from cma.inbound_service((v_now at time zone 'Europe/Amsterdam')::date - 5, (v_now at time zone 'Europe/Amsterdam')::date, 'line') x), '');
    v_txt := v_txt || coalesce((select string_agg(row_to_json(x)::text, '') from cma.inbound_service((v_now at time zone 'Europe/Amsterdam')::date - 5, (v_now at time zone 'Europe/Amsterdam')::date, 'day') x), '');
    v_txt := v_txt || coalesce((select string_agg(row_to_json(x)::text, '') from cma.inbound_today() x), '');
    v_txt := v_txt || coalesce((select string_agg(row_to_json(x)::text, '') from cma.missed_callbacks() x), '');
    v_txt := v_txt || coalesce((select string_agg(row_to_json(x)::text, '') from cma.missed_callbacks_summary() x), '');
    v_txt := v_txt || coalesce((select string_agg(row_to_json(x)::text, '') from cma.missed_reasons() x), '');
    v_txt := v_txt || coalesce((select string_agg(row_to_json(x)::text, '') from cma.inbound_calls_of(v_t2, null, null) x), '');
    perform set_config('app.user_id', v_admin2::text, true);
    v_txt := v_txt || cma.connection_missed_reasons(v_tel2)::text || cma.connection_missed_reasons(v_tel2b)::text;
    perform set_config('app.user_id', v_analyst2::text, true);
    select count(*) into v_n from unnest(v_h) h where strpos(v_txt, h) > 0 or strpos(v_txt, upper(h)) > 0;
    v_rows := v_rows || array['22', 'B12 the hash is in no answer',
      case when v_n = 0 and length(v_txt) > 500 and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s hash strings found in %s characters of answers', v_n, length(v_txt))];

    -- B13. the catalog: a configuring person writes it (label and both switches, read back by
    --      missed_reasons); the Ingest user and an agent cannot (CMA06); refused with nothing written:
    --      a connection of another kind, one without a kind holding a CRM's rows, an empty or a
    --      61-character code, an empty label, a missing switch (CMA04), an unknown connection (CMA02):
    --      nine refusals
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_telephony_missed_reason(v_tel1, ' agents_did_not_answer ', ' Nobody picked up ', true, false);
    select string_agg(code || ':' || label || ':' || counts_in_service_level || ':' || needs_callback, ',') into v_txt
    from cma.missed_reasons() where code = 'agents_did_not_answer';
    v_n := 0;
    perform set_config('app.user_id', v_ing1::text, true);
    begin perform cma.set_telephony_missed_reason(v_tel1, 'x', 'X', true, true); exception when sqlstate 'CMA06' then v_n := v_n + 1; end;
    perform set_config('app.user_id', v_agent1::text, true);
    begin perform cma.set_telephony_missed_reason(v_tel1, 'x', 'X', true, true); exception when sqlstate 'CMA06' then v_n := v_n + 1; end;
    perform set_config('app.user_id', v_admin1::text, true);
    begin perform cma.set_telephony_missed_reason(v_crm1, 'x', 'X', true, true); exception when sqlstate 'CMA04' then v_n := v_n + 1; end;
    begin perform cma.set_telephony_missed_reason(v_crm1b, 'x', 'X', true, true); exception when sqlstate 'CMA04' then v_n := v_n + 1; end;
    begin perform cma.set_telephony_missed_reason(v_tel1, '  ', 'X', true, true); exception when sqlstate 'CMA04' then v_n := v_n + 1; end;
    begin perform cma.set_telephony_missed_reason(v_tel1, repeat('x', 61), 'X', true, true); exception when sqlstate 'CMA04' then v_n := v_n + 1; end;
    begin perform cma.set_telephony_missed_reason(v_tel1, 'x', '', true, true); exception when sqlstate 'CMA04' then v_n := v_n + 1; end;
    begin perform cma.set_telephony_missed_reason(v_tel1, 'x', 'X', null, true); exception when sqlstate 'CMA04' then v_n := v_n + 1; end;
    begin perform cma.set_telephony_missed_reason('00000000-0000-7000-8000-00000000dead', 'x', 'X', true, true); exception when sqlstate 'CMA02' then v_n := v_n + 1; end;
    begin perform cma.connection_missed_reasons(v_tel1); exception when others then v_n := v_n - 100; end;
    v_ok := v_txt = 'agents_did_not_answer:Nobody picked up:true:false' and v_n = 9
            and not exists (select 1 from cma.telephony_missed_reason where tenant_id = v_t1 and code = 'x');
    v_rows := v_rows || array['23', 'B13 a configuring person writes the catalog; the Ingest user and an agent cannot; nine refusals',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'not written') || format(' | %s of 9 refusals', v_n)];

    -- B14. the reads' permissions: an agent reads neither the report nor the Live board's reads nor
    --      the catalog, the Ingest user neither; a group outside the four and 93 days are refused
    --      (CMA04); isolation: tenant three's admin cannot touch tenant one's connection (CMA02) and
    --      tenant three's reads hold none of tenant one's or two's calls or reasons
    v_n := 0;
    foreach v_detail in array array[v_agent1::text, v_ing1::text] loop
      perform set_config('app.user_id', v_detail, true);
      begin perform cma.inbound_service('2026-09-15', '2026-09-15', 'day'); exception when sqlstate 'CMA06' then v_n := v_n + 1; end;
      begin perform cma.inbound_today(); exception when sqlstate 'CMA06' then v_n := v_n + 1; end;
      begin perform cma.missed_callbacks(); exception when sqlstate 'CMA06' then v_n := v_n + 1; end;
      begin perform cma.missed_callbacks_summary(); exception when sqlstate 'CMA06' then v_n := v_n + 1; end;
      begin perform cma.missed_reasons(); exception when sqlstate 'CMA06' then v_n := v_n + 1; end;
      begin perform cma.connection_missed_reasons(v_tel1); exception when sqlstate 'CMA06' then v_n := v_n + 1; end;
    end loop;
    perform set_config('app.user_id', v_analyst1::text, true);
    begin perform cma.inbound_service('2026-09-15', '2026-09-15', 'week'); exception when sqlstate 'CMA04' then v_n := v_n + 1; end;
    begin perform cma.inbound_service('2026-07-01', '2026-10-01', 'day'); exception when sqlstate 'CMA04' then v_n := v_n + 1; end;
    perform set_config('app.tenant_id', v_t3::text, true);
    perform set_config('app.user_id', v_admin3::text, true);
    begin perform cma.set_telephony_missed_reason(v_tel1, 'x', 'X', true, true); exception when sqlstate 'CMA02' then v_n := v_n + 1; end;
    begin perform cma.connection_missed_reasons(v_tel1); exception when sqlstate 'CMA02' then v_n := v_n + 1; end;
    perform set_config('app.user_id', v_analyst3::text, true);
    select coalesce(sum(offered) filter (where group_key is not null), 0) || '/' || (select count(*) from cma.missed_reasons()) || '/' || (select count(*) from cma.telephony_missed_reason)
           || '/' || (select count(*) from cma.inbound_calls_of(v_t1, null, null)) || '/' || (select count(*) from cma.inbound_calls_of(v_t2, null, null))
      into v_txt from cma.inbound_service((v_now at time zone 'Europe/Amsterdam')::date - 1, (v_now at time zone 'Europe/Amsterdam')::date, 'day');
    v_ok := v_n = 16 and v_txt = '1/0/0/0/0';
    v_rows := v_rows || array['24', 'B14 the reads'' permissions and refusals; tenant isolation',
      case when v_ok and not v_provoke then 'PASS' else 'FAIL' end, format('%s of 16 refusals; tenant three offered/reasons/catalog/one/two %s', v_n, v_txt)];

    -- B15. times missed since the last callback (written last, so the checks above keep their calls):
    --      caller 11 missed two days ago and was called back, missed a day ago and was called back again
    --      an hour later (outbound calls), and missed 50 minutes ago; caller 12 missed twice a day ago,
    --      called in an hour later and was answered, and missed 45 minutes ago. Each is listed with its
    --      latest call and counts 1, not 3 (every missed call) or 2 (since the first callback): only the
    --      missed calls after the latest callback count
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_ing2::text, true);
    perform cma.ingest_upsert_telephony_calls(v_tel2, jsonb_build_array(
      pg_temp.v0008i_call('d-1', 'inbound', v_now - interval '50 hours', null, 30, 'no_available_agent', 'line-nl', v_h[11]),
      pg_temp.v0008i_call('d-2', 'outbound', v_now - interval '49 hours', null, 25, null, 'line-nl', v_h[11]),
      pg_temp.v0008i_call('d-3', 'inbound', v_now - interval '26 hours', null, 30, 'no_available_agent', 'line-nl', v_h[11]),
      pg_temp.v0008i_call('d-4', 'outbound', v_now - interval '25 hours', 7, 120, null, 'line-nl', v_h[11]),
      pg_temp.v0008i_call('d-5', 'inbound', v_now - interval '50 minutes', null, 30, 'agents_did_not_answer', 'line-nl', v_h[11]),
      pg_temp.v0008i_call('e-1', 'inbound', v_now - interval '27 hours', null, 30, 'no_available_agent', 'line-nl', v_h[12]),
      pg_temp.v0008i_call('e-2', 'inbound', v_now - interval '26 hours', null, 30, 'abandoned_in_ivr', 'line-nl', v_h[12]),
      pg_temp.v0008i_call('e-3', 'inbound', v_now - interval '25 hours', 9, 200, null, 'line-nl', v_h[12]),
      pg_temp.v0008i_call('e-4', 'inbound', v_now - interval '45 minutes', null, 30, 'no_available_agent', 'line-nl', v_h[12])));
    perform set_config('app.user_id', v_analyst2::text, true);
    select string_agg(source_id || ':' || missed_count, ',' order by started_at) into v_txt
    from cma.missed_callbacks() where source_id ~ '^[de]-';
    v_rows := v_rows || array['25', 'B15 times missed counts the missed calls since the latest callback',
      case when v_txt = 'd-5:1,e-4:1' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'none listed')];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['39', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008i (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008i values (39, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008i
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED: not dev'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008i where result = 'PASS') = 20
                       and not exists (select 1 from verify_0008i where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0008i where result = 'PASS'),
                                        (select count(*) from verify_0008i where result <> 'PASS'))) x
order by ord;
drop function if exists pg_temp.v0008i_call(text, text, timestamptz, numeric, numeric, text, text, text);
reset role;
