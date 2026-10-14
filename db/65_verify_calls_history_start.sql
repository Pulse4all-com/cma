-- =============================================================================================
-- 65_verify_calls_history_start.sql: verifies addition 0008k, the start of the telephony history
-- =============================================================================================
-- Dev only: the script refuses a database that does not hold the dev seed's active test person
-- (agent.two@example.com, db/03); prod never holds example.com people. Block A checks structure
-- and privileges; block B works on three throwaway tenants inside a subtransaction that is always
-- rolled back. Universal otherwise: nothing of the seed is used; adapters, lines, users and calls are
-- invented data values, and no call carries a hash or a number. Every check writes one row, PASS or
-- FAIL, and the last result lists them with the verdict, because Cloud SQL Studio shows no notices.
-- Run as your own IAM login in dev, after 64_calls_history_start.sql; then 63, 35, 41, 55 and 61
-- again.
--   A  structure and privileges: the addition row after 0008j; both functions the application's only,
--      in the caller's rights, returning a date, the read of an explicit tenant taking the tenant alone
--      (no market or line: the history start is tenant-wide)
--   B  behaviour. Tenant one (Europe/Amsterdam; lines NL, US in America/Los_Angeles, and an NL line
--      that does not count): its earliest counted call starts on 1 October 2026 at 22:30 UTC on the NL
--      line (2 October in Amsterdam), and a call on the US line starts four and a half hours later (1
--      October, 20:00 in Los Angeles), so the history starts on 1 October, in the US line's zone and
--      not the tenant's; before them a call deleted afterwards (25 September) and a call on the line
--      that does not count (20 September, written past the write; the write skips another), both left
--      out. Tenant two holds the same refs and an earlier call (1 September), for tenant isolation.
--      Tenant three has no call (null), then only calls that do not count (deleted, on a line that
--      does not count, without a start: still null), then, after two months of them, its
--      first call that counts, then lines in Kiritimati (UTC+14) and at UTC-12, whose calls a day
--      apart fall on dates in the other order. Checked: the permissions (reports.view or
--      performance.team) and the refusals; null without a call; the earliest business date in its
--      line's zone; a deleted earliest call left out (the history starting on its date before the
--      deletion); a call on a line that does not count left out (and counted once the line counts);
--      tenant isolation, also in the owner's rights; the Calls overview holding no call before the
--      history start and one on its date; the first call that counts after weeks of calls that do
--      not; a later call on an earlier date up to two days after the earliest call, past the end of
--      the seven-day window the earliest call was found in
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
    raise exception 'REFUSED: the connected database is not dev (no active agent.two@example.com); 65 runs in dev only';
  end if;
end
$$;

drop table if exists pg_temp.verify_0008k;
create temp table verify_0008k (ord int, check_name text, result text, detail text);

-- One answered telephony call as the ingest write takes it: 60 seconds of talk after 5 of ringing, on
-- the line given, without a user, a hash or tags
create or replace function pg_temp.v0008k_call(p_src text, p_dir text, p_start timestamptz, p_line text)
returns jsonb
language sql immutable
as $$
  select jsonb_build_object(
    'sourceId', p_src, 'direction', p_dir, 'startedAt', p_start,
    'answeredAt', p_start + interval '5 seconds', 'endedAt', p_start + interval '65 seconds',
    'durationSeconds', 65, 'numberRef', p_line, 'versionAt', p_start + interval '65 seconds')
$$;

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_fn      text;
  v_bad     text;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  -- A1. the addition is recorded, after 0008j
  insert into verify_0008k values (1, 'A1 addition 0008k recorded',
    case when exists (select 1 from cma.schema_migration where version = '0008k')
              and exists (select 1 from cma.schema_migration where version = '0008j') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- A2. both functions exist, executable by the application only, in the caller's rights, returning a
  --     date; the read of an explicit tenant takes the tenant alone
  v_bad := '';
  foreach v_fn in array array['cma.telephony_history_start()', 'cma.telephony_history_start_of(uuid)'] loop
    if to_regprocedure(v_fn) is null then
      v_bad := v_bad || v_fn || ' is missing; ';
    elsif not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
          or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                     where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE')
          or (select prosecdef from pg_proc where oid = to_regprocedure(v_fn)) then
      v_bad := v_bad || v_fn || ' is not the application''s only, in the caller''s rights; ';
    elsif (select prorettype from pg_proc where oid = to_regprocedure(v_fn)) <> 'date'::regtype
          or (select proretset from pg_proc where oid = to_regprocedure(v_fn)) then
      v_bad := v_bad || v_fn || ' does not return one date; ';
    end if;
  end loop;
  if (select count(*) from pg_proc where pronamespace = 'cma'::regnamespace and proname in ('telephony_history_start', 'telephony_history_start_of')) <> 2 then
    v_bad := v_bad || 'another signature exists; ';
  end if;
  insert into verify_0008k values (2, 'A2 the functions are the application''s only, in the caller''s rights, returning a date',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);
end
$$;

-- B. Behaviour on three throwaway tenants (rolled back)
do $$
declare
  v_provoke  boolean := current_setting('verify.provoke')::boolean;
  v_rows     text[] := '{}';
  v_t1 uuid; v_t2 uuid; v_t3 uuid;
  v_admin1 uuid; v_agent1 uuid; v_analyst1 uuid; v_super1 uuid; v_reader1 uuid; v_ing1 uuid;
  v_admin2 uuid; v_analyst2 uuid; v_ing2 uuid;
  v_admin3 uuid; v_analyst3 uuid; v_ing3 uuid;
  v_tel1 uuid; v_tel2 uuid; v_tel3 uuid;
  v_role     uuid;
  v_txt      text;
  v_detail   text;
  v_skip     text;
  v_n        integer;
  v_d        date;
begin
  if not current_setting('verify.is_dev')::boolean then
    return;
  end if;
  begin
    v_t1 := cma.create_tenant('verify-0008k-one', 'Verify 0008k one', 'Europe/Amsterdam');
    v_t2 := cma.create_tenant('verify-0008k-two', 'Verify 0008k two', 'Europe/Amsterdam');
    v_t3 := cma.create_tenant('verify-0008k-three', 'Verify 0008k three', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin1@example.invalid', 'admin1') returning id into v_admin1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent1@example.invalid', 'agent1') returning id into v_agent1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-analyst1@example.invalid', 'analyst1') returning id into v_analyst1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-super1@example.invalid', 'super1') returning id into v_super1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-reader1@example.invalid', 'reader1') returning id into v_reader1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin2') returning id into v_admin2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-analyst2@example.invalid', 'analyst2') returning id into v_analyst2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t3, 'verify-admin3@example.invalid', 'admin3') returning id into v_admin3;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t3, 'verify-analyst3@example.invalid', 'analyst3') returning id into v_analyst3;
    -- a role with reports.view only (no default role has it without performance.team)
    insert into cma.app_role (tenant_id, key, name) values (v_t1, 'verify_reader', 'Verify reader') returning id into v_role;
    insert into cma.role_permission (tenant_id, role_id, permission_key) values (v_t1, v_role, 'reports.view');
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin1, 'admin'), (v_t1, v_agent1, 'agent'), (v_t1, v_analyst1, 'analytics'), (v_t1, v_super1, 'supervisor'),
                 (v_t1, v_reader1, 'verify_reader'), (v_t2, v_admin2, 'admin'), (v_t2, v_analyst2, 'analytics'),
                 (v_t3, v_admin3, 'admin'), (v_t3, v_analyst3, 'analytics')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    select x.user_id into v_ing1 from cma.app_user_external_id x where x.tenant_id = v_t1 and x.system = 'ingest';
    select x.user_id into v_ing2 from cma.app_user_external_id x where x.tenant_id = v_t2 and x.system = 'ingest';
    select x.user_id into v_ing3 from cma.app_user_external_id x where x.tenant_id = v_t3 and x.system = 'ingest';
    perform set_config('role', 'cma_app', true);

    -- tenant one: markets NL and US, a telephony connection with three lines (NL, US, and an NL line
    -- that does not count)
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.upsert_market('US', 'United States', 'America/Los_Angeles', 'en', 'USD');
    select c.connection_id into v_tel1 from cma.upsert_connection('verifytel', 'Verify phones one', 'company-1', null, null) c;
    perform cma.set_connection_kind(v_tel1, 'telephony');
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_telephony_catalog(v_tel1, 'number', '[{"numberRef": "line-nl", "name": "Verify NL line"},
      {"numberRef": "line-us", "name": "Verify US line"}, {"numberRef": "line-off", "name": "Verify line not counted"}]'::jsonb);
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_telephony_number(v_tel1, 'line-nl', 'NL', true);
    perform cma.set_telephony_number(v_tel1, 'line-us', 'US', true);
    perform cma.set_telephony_number(v_tel1, 'line-off', 'NL', false);
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_telephony_calls(v_tel1, jsonb_build_array(
      -- the earliest counted call: 2 October 00:30 in Amsterdam
      pg_temp.v0008k_call('src0008k-nl', 'inbound', timestamptz '2026-10-01 22:30:00+00', 'line-nl'),
      -- four and a half hours later on the US line: 1 October 20:00 in Los Angeles
      pg_temp.v0008k_call('src0008k-us', 'outbound', timestamptz '2026-10-02 03:00:00+00', 'line-us'),
      pg_temp.v0008k_call('src0008k-later', 'inbound', timestamptz '2026-10-05 09:00:00+00', 'line-nl'),
      -- 25 September, deleted below
      pg_temp.v0008k_call('src0008k-del', 'inbound', timestamptz '2026-09-25 10:00:00+00', 'line-nl')));
    -- before the deletion the history starts on its date
    perform set_config('app.user_id', v_analyst1::text, true);
    v_d := cma.telephony_history_start();
    perform set_config('app.user_id', v_ing1::text, true);
    perform cma.ingest_upsert_telephony_calls(v_tel1, jsonb_build_array(
      jsonb_build_object('sourceId', 'src0008k-del', 'deletedAt', timestamptz '2026-09-26 10:00:00+00', 'versionAt', timestamptz '2026-09-26 10:00:00+00')));
    -- a call on the line that does not count: the write skips it
    select string_agg(o.outcome, ',') into v_skip
    from cma.ingest_upsert_telephony_calls(v_tel1, jsonb_build_array(
      pg_temp.v0008k_call('src0008k-off1', 'inbound', timestamptz '2026-09-20 09:00:00+00', 'line-off'))) o;
    -- and one written past the write (as a call stored before its line was switched off would be)
    perform set_config('role', 'cma_owner', true);
    insert into cma.telephony_call (tenant_id, connection_id, source_system, source_id, direction, started_at, answered_at, ended_at,
                                    number_ref, source_version_at)
    values (v_t1, v_tel1, 'verifytel', 'src0008k-off2', 'inbound', timestamptz '2026-09-20 10:00:00+00', timestamptz '2026-09-20 10:00:05+00',
            timestamptz '2026-09-20 10:01:05+00', 'line-off', timestamptz '2026-09-20 10:01:05+00');
    perform set_config('role', 'cma_app', true);

    -- tenant two: the same connection and line refs, its first call on 1 September
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    select c.connection_id into v_tel2 from cma.upsert_connection('verifytel', 'Verify phones two', 'company-1', null, null) c;
    perform cma.set_telephony_number(v_tel2, 'line-nl', 'NL', true);
    perform set_config('app.user_id', v_ing2::text, true);
    perform cma.ingest_upsert_telephony_calls(v_tel2, jsonb_build_array(
      pg_temp.v0008k_call('src0008k-nl', 'inbound', timestamptz '2026-09-01 08:00:00+00', 'line-nl'),
      pg_temp.v0008k_call('src0008k-us', 'outbound', timestamptz '2026-10-02 03:00:00+00', 'line-nl')));

    -- tenant three: a telephony connection, one NL line and one that does not count, no call yet
    perform set_config('app.tenant_id', v_t3::text, true);
    perform set_config('app.user_id', v_admin3::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    select c.connection_id into v_tel3 from cma.upsert_connection('verifytel', 'Verify phones three', 'company-3', null, null) c;
    perform cma.set_telephony_number(v_tel3, 'line-nl', 'NL', true);
    perform cma.set_telephony_number(v_tel3, 'line-off', 'NL', false);

    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);

    -- B1. permissions: the reader (reports.view only), the supervisor (performance.team) and the analyst
    --     read the history start; an agent and the Ingest user are refused (CMA06), and so is a read
    --     without an acting user (CMA01)
    v_txt := '';
    foreach v_detail in array array[v_reader1::text, v_super1::text, v_analyst1::text] loop
      perform set_config('app.user_id', v_detail, true);
      begin
        v_txt := v_txt || coalesce(cma.telephony_history_start()::text, 'null') || ' ';
      exception when others then v_txt := v_txt || 'refused ';
      end;
    end loop;
    v_n := 0;
    foreach v_detail in array array[v_agent1::text, v_ing1::text] loop
      perform set_config('app.user_id', v_detail, true);
      begin perform cma.telephony_history_start(); exception when sqlstate 'CMA06' then v_n := v_n + 1; end;
    end loop;
    perform set_config('app.user_id', '', true);
    begin perform cma.telephony_history_start(); exception when sqlstate 'CMA01' then v_n := v_n + 1; end;
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['11', 'B1 reports.view or performance.team reads the history start; refusals',
      case when v_txt = '2026-10-01 2026-10-01 2026-10-01 ' and v_n = 3 and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s| %s of 3 refusals', v_txt, v_n)];

    -- B2. a tenant without a call has no history start: none at all, then only a deleted call, a call
    --     on a line that does not count (written past the write) and a call without a start
    perform set_config('app.tenant_id', v_t3::text, true);
    perform set_config('app.user_id', v_analyst3::text, true);
    v_txt := coalesce(cma.telephony_history_start()::text, 'null');
    perform set_config('app.user_id', v_ing3::text, true);
    perform cma.ingest_upsert_telephony_calls(v_tel3, jsonb_build_array(
      pg_temp.v0008k_call('src0008k-t3del', 'inbound', timestamptz '2026-08-01 09:00:00+00', 'line-nl')));
    perform cma.ingest_upsert_telephony_calls(v_tel3, jsonb_build_array(
      jsonb_build_object('sourceId', 'src0008k-t3del', 'deletedAt', timestamptz '2026-08-01 10:00:00+00', 'versionAt', timestamptz '2026-08-01 10:00:00+00')));
    perform set_config('role', 'cma_owner', true);
    insert into cma.telephony_call (tenant_id, connection_id, source_system, source_id, direction, started_at, answered_at, ended_at,
                                    number_ref, source_version_at)
    values (v_t3, v_tel3, 'verifytel', 'src0008k-t3off', 'outbound', timestamptz '2026-08-10 09:00:00+00', timestamptz '2026-08-10 09:00:05+00',
            timestamptz '2026-08-10 09:01:05+00', 'line-off', timestamptz '2026-08-10 09:01:05+00'),
           (v_t3, v_tel3, 'verifytel', 'src0008k-t3nostart', 'inbound', null, null, null, 'line-nl', timestamptz '2026-08-05 09:00:00+00');
    v_n := (select count(*) from cma.telephony_call where tenant_id = v_t3);
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_analyst3::text, true);
    v_txt := v_txt || ' ' || coalesce(cma.telephony_history_start()::text, 'null') || ' ' || coalesce(cma.telephony_history_start_of(v_t3)::text, 'null')
             || format(' (%s stored)', v_n);
    v_rows := v_rows || array['12', 'B2 a tenant without a call that counts has no history start (null)',
      case when v_txt = 'null null null (3 stored)' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B3. the earliest business date in the line's zone: the US line's call is 1 October in Los Angeles,
    --     though the NL call started earlier (2 October in Amsterdam); with the US line moved to NL, both
    --     fall on 2 October in Amsterdam
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_txt := coalesce(cma.telephony_history_start()::text, 'null');
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_telephony_number(v_tel1, 'line-us', 'NL', true);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_txt := v_txt || ' | in Amsterdam ' || coalesce(cma.telephony_history_start()::text, 'null');
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_telephony_number(v_tel1, 'line-us', 'US', true);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_txt := v_txt || ' | back ' || coalesce(cma.telephony_history_start()::text, 'null');
    v_rows := v_rows || array['13', 'B3 the earliest business date in its line''s zone, not the tenant''s',
      case when v_txt = '2026-10-01 | in Amsterdam 2026-10-02 | back 2026-10-01' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B4. a deleted earliest call is left out: before its deletion the history started on its date
    v_txt := coalesce(v_d::text, 'null') || ' then ' || coalesce(cma.telephony_history_start()::text, 'null');
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || ' (deleted rows ' || (select count(*) from cma.telephony_call where tenant_id = v_t1 and source_deleted_at is not null) || ')';
    perform set_config('role', 'cma_app', true);
    v_rows := v_rows || array['14', 'B4 a deleted earliest call is left out',
      case when v_txt = '2026-09-25 then 2026-10-01 (deleted rows 1)' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B6. tenant isolation: tenant one reads its own start, not tenant two's earlier one; tenant one's read
    --     of tenant two's id finds nothing under row-level security; tenant two reads its own; in the
    --     owner's rights each tenant's read keeps to its own calls
    v_txt := coalesce(cma.telephony_history_start()::text, 'null') || '/' || coalesce(cma.telephony_history_start_of(v_t2)::text, 'null');
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_analyst2::text, true);
    v_txt := v_txt || ' | ' || coalesce(cma.telephony_history_start()::text, 'null') || '/' || coalesce(cma.telephony_history_start_of(v_t1)::text, 'null');
    perform set_config('role', 'cma_owner', true);
    v_txt := v_txt || ' | ' || coalesce(cma.telephony_history_start_of(v_t1)::text, 'null') || '/' || coalesce(cma.telephony_history_start_of(v_t2)::text, 'null');
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['16', 'B6 tenant isolation with equal refs, also in the owner''s rights',
      case when v_txt = '2026-10-01/null | 2026-09-01/null | 2026-10-01/2026-09-01' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B7. the Calls overview agrees: no call in the seven days before the history start, its own date
    --     holds the US call (the NL call is on 2 October), each date in its line's zone
    v_d := cma.telephony_history_start();
    select format('%s: before %s, on it %s', v_d,
                  (select calls from cma.calls_overview(v_d - 7, v_d - 1, null, null, 'day') where period = 'current' and group_key is null),
                  (select string_agg(group_key || '=' || calls, ',' order by group_key) from cma.calls_overview(v_d, v_d + 1, null, null, 'market')
                   where period = 'current' and group_key is not null))
      into v_txt;
    v_rows := v_rows || array['17', 'B7 the Calls overview holds no call before the history start and one on its date',
      case when v_txt = '2026-10-01: before 0, on it NL=1,US=1' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no row')];

    -- B8. after two months of calls that do not count (tenant three's of B2), its first call
    --     that does: 9 October 23:30 UTC is 10 October in Amsterdam
    perform set_config('app.tenant_id', v_t3::text, true);
    perform set_config('app.user_id', v_ing3::text, true);
    perform cma.ingest_upsert_telephony_calls(v_tel3, jsonb_build_array(
      pg_temp.v0008k_call('src0008k-t3a', 'inbound', timestamptz '2026-10-09 23:30:00+00', 'line-nl'),
      pg_temp.v0008k_call('src0008k-t3b', 'inbound', timestamptz '2026-10-12 09:00:00+00', 'line-nl')));
    perform set_config('app.user_id', v_analyst3::text, true);
    v_txt := coalesce(cma.telephony_history_start()::text, 'null');
    v_rows := v_rows || array['18', 'B8 the first call that counts after weeks of calls that do not',
      case when v_txt = '2026-10-10' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B9. a later call on an earlier date, up to two days after the earliest call and past the end of
    --     its window. Tenant three gets lines in Kiritimati (UTC+14) and at UTC-12, a call deleted
    --     afterwards on 20 September 00:00 UTC (where the seven-day window starts), its earliest call on
    --     26 September 10:30 UTC (27 September 00:30 on Kiritimati, inside that window) and one 24.5 hours
    --     later, 27 September 11:00 UTC (26 September 23:00 at UTC-12, after the window's end): the history
    --     starts on 26 September
    perform set_config('app.user_id', v_admin3::text, true);
    perform cma.upsert_market('KI', 'Verify far east', 'Pacific/Kiritimati', 'en', 'AUD');
    perform cma.upsert_market('UM', 'Verify far west', 'Etc/GMT+12', 'en', 'USD');
    perform cma.set_telephony_number(v_tel3, 'line-ki', 'KI', true);
    perform cma.set_telephony_number(v_tel3, 'line-um', 'UM', true);
    perform set_config('app.user_id', v_ing3::text, true);
    perform cma.ingest_upsert_telephony_calls(v_tel3, jsonb_build_array(
      pg_temp.v0008k_call('src0008k-t3w', 'inbound', timestamptz '2026-09-20 00:00:00+00', 'line-nl'),
      pg_temp.v0008k_call('src0008k-t3ki', 'inbound', timestamptz '2026-09-26 10:30:00+00', 'line-ki'),
      pg_temp.v0008k_call('src0008k-t3um', 'outbound', timestamptz '2026-09-27 11:00:00+00', 'line-um')));
    perform cma.ingest_upsert_telephony_calls(v_tel3, jsonb_build_array(
      jsonb_build_object('sourceId', 'src0008k-t3w', 'deletedAt', timestamptz '2026-09-20 01:00:00+00', 'versionAt', timestamptz '2026-09-20 01:00:00+00')));
    perform set_config('app.user_id', v_analyst3::text, true);
    select format('%s | KI %s, UM %s', coalesce(cma.telephony_history_start()::text, 'null'),
                  (select string_agg(group_key, ',') from cma.calls_overview('2026-09-26', '2026-09-27', 'KI', null, 'day') where period = 'current' and group_key is not null),
                  (select string_agg(group_key, ',') from cma.calls_overview('2026-09-26', '2026-09-27', 'UM', null, 'day') where period = 'current' and group_key is not null))
      into v_txt;
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_rows := v_rows || array['19', 'B9 a later call on an earlier date, past the end of the earliest call''s window',
      case when v_txt = '2026-09-26 | KI 2026-09-27, UM 2026-09-26' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no row')];

    -- B5 (last, since it makes the line count). A call on a line that does not count is left out: the
    --     write skipped off1, and off2, stored past it on 20 September, is not the start; once the line
    --     counts, it is
    perform set_config('role', 'cma_owner', true);
    v_n := (select count(*) from cma.telephony_call where tenant_id = v_t1 and number_ref = 'line-off');
    perform set_config('role', 'cma_app', true);
    v_txt := format('%s; stored %s; %s', v_skip, v_n, coalesce(cma.telephony_history_start()::text, 'null'));
    perform set_config('app.user_id', v_admin1::text, true);
    perform cma.set_telephony_number(v_tel1, 'line-off', 'NL', true);
    perform set_config('app.user_id', v_analyst1::text, true);
    v_txt := v_txt || ' | counted ' || coalesce(cma.telephony_history_start()::text, 'null');
    v_rows := v_rows || array['15', 'B5 a call on a line that does not count is left out',
      case when v_txt = 'skipped_uncounted_line; stored 1; 2026-10-01 | counted 2026-09-20' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      v_rows := v_rows || array['39', 'B the block ran to the end', 'FAIL', sqlerrm];
  end;
  insert into verify_0008k (ord, check_name, result, detail)
  select v_rows[i]::int, v_rows[i + 1], v_rows[i + 2], v_rows[i + 3]
  from generate_series(1, coalesce(array_length(v_rows, 1), 0), 4) as i;
  if cardinality(v_rows) = 0 then
    insert into verify_0008k values (39, 'B the block ran to the end', 'FAIL', 'no check ran');
  end if;
end
$$;

-- Verdict: one row per check, then the verdict
select check_name, result, detail
from (select ord, check_name, result, detail from verify_0008k
      union all
      select 99, 'verdict',
             case when not current_setting('verify.is_dev')::boolean then 'REFUSED: not dev'
                  when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when (select count(*) from verify_0008k where result = 'PASS') = 11
                       and not exists (select 1 from verify_0008k where result <> 'PASS') then 'PASS'
                  else 'FAIL' end,
             format('%s PASS, %s FAIL', (select count(*) from verify_0008k where result = 'PASS'),
                                        (select count(*) from verify_0008k where result <> 'PASS'))) x
order by ord;
drop function if exists pg_temp.v0008k_call(text, text, timestamptz, text);
reset role;
