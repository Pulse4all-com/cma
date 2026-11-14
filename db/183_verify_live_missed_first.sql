-- =============================================================================================
-- 183_verify_live_missed_first.sql: verifies addition 0009q, the Live board's poll with the first missed callers
-- =============================================================================================
-- Blocks S check the addition and the function (universal). Block B works on two throwaway tenants inside a
-- subtransaction that is always rolled back, so nothing stays: 25 invented missed callers on a counted line. Block E
-- reads every active tenant's own missed callers as a person holding monitoring.live, writes nothing, and compares
-- cma.inbound_now_first with cma.inbound_now() in ONE statement each time, so in one snapshot and with one now(): a
-- call the ingest commits between two statements cannot make them differ (the lesson of 0009f). The script runs alike
-- in dev and in prod. Every check writes one row, PASS, FAIL or skip, and the last row is the verdict, because Cloud SQL
-- Studio shows no notices: "PASS | 183_verify_live_missed_first: n PASS, 0 FAIL, n skip". Run as your own IAM login
-- after 182_live_missed_first.sql, dev first, then prod.
--   S1  the addition 0009q is recorded once, after 0009p
--   S2  cma.inbound_now_first(integer): plpgsql, stable, in the caller's rights, cma_owner's, jsonb, the application's
--       only; cma.inbound_now() is still there (182 leaves it as 170 made it)
--   B1  an agent is refused (CMA06); a count below 0 is refused (CMA04)
--   B2  every caller (null): cma.inbound_now()'s answer without today's waiting_now and longest_waiting_seconds, plus
--       summary.shown; 25 callers listed and shown
--   B3  the first 0, 1, 20 and 30: the callbacks are the first so many of cma.inbound_now()'s, in its order, each with
--       every key of its row; listed stays 25, shown is what the answer holds; today and the rest of the summary as for
--       every caller
--   B4  a tenant without a call: no caller, listed 0, shown 0; and it sees nothing of the first tenant
--   E1  per active tenant: every caller (null) equals cma.inbound_now() without the two kept keys, plus shown
--   E2  per active tenant: the first 20 are the first 20 of cma.inbound_now()'s callbacks, listed its whole count
--   E3  per active tenant: the first 20 are read no slower than every caller (the best of verify.timing_runs each,
--       after six untimed calls each, so both run the plans a pooled connection keeps), with verify.slack_ms of noise
--       allowed; the detail gives both timings and both answers' sizes. 131_time_all.sql part a holds the poll's budget
-- A tenant without a person holding monitoring.live reads skip in E (FAIL when provoked).
-- Provoke: set provoke below to true; every check must then read FAIL, and the verdict says PROVOKED, NOT A PASS. The
-- comparisons are provoked by a deliberate difference: B2 and E1 then keep today's waiting_now in the old answer, B3 and
-- E2 compare with one caller more than asked, E3 allows a negative time.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);                 -- 'true' to make every check fail
select set_config('verify.timing_runs', '8', false);                 -- timed runs per read in E3, after six untimed ones each
select set_config('verify.slack_ms', '1.5', false);                  -- E3: what the first 20 may take above every caller's best (noise)

drop table if exists pg_temp.verify_0009q;
create temporary table verify_0009q (ord integer, check_name text, result text, detail text);
-- block E writes its rows while acting as the application
grant select, insert on pg_temp.verify_0009q to cma_app;

-- One telephony call as the ingest write takes it (as 171): answered p_ring seconds after the start (null: never, and
-- ended after 20 seconds), ended p_talk seconds after the answer, on the line p_number, an invented hash from the id
create or replace function pg_temp.v0009q_call(p_src text, p_dir text, p_start timestamptz, p_ring integer, p_talk integer, p_number text)
returns jsonb
language sql immutable
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'sourceId', p_src, 'direction', p_dir, 'startedAt', p_start,
    'answeredAt', p_start + make_interval(secs => p_ring),
    'endedAt', case when p_ring is null then p_start + interval '20 seconds' else p_start + make_interval(secs => p_ring + p_talk) end,
    'numberRef', p_number, 'userRef', 'tu-1', 'counterpartHash', md5(p_src) || md5(p_src || 'x'),
    'versionAt', p_start + interval '1 hour'))
$$;

-- The SQLSTATE a statement raises, or 'no error'
create or replace function pg_temp.v0009q_code(p_sql text)
returns text
language plpgsql
as $$
begin
  execute p_sql;
  return 'no error';
exception when others then
  return sqlstate;
end
$$;

-- The first p_n elements of a JSON array, in its order (null: all of it)
create or replace function pg_temp.v0009q_first(p_list jsonb, p_n integer)
returns jsonb
language sql immutable
as $$
  select coalesce(jsonb_agg(e order by o), '[]'::jsonb) from jsonb_array_elements(p_list) with ordinality x(e, o) where p_n is null or o <= p_n
$$;

-- The first active person of a tenant holding a permission (as 171)
create or replace function pg_temp.v0009q_user(p_tenant uuid, p_perm text)
returns uuid
language sql stable
as $$
  select u.id from cma.app_user u
  where u.tenant_id = p_tenant and u.status = 'active' and u.kind = 'person' and cma.has_permission(u.id, p_perm)
  order by u.created_at, u.id limit 1
$$;

-- ---------------------------------------------------------------------------------------------
-- S. Structure and privileges
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_fn  regprocedure := to_regprocedure('cma.inbound_now_first(integer)');
  v_bad text := '';
begin
  insert into verify_0009q values (1, 'S1 addition 0009q recorded once, after 0009p',
    case when (select count(*) from cma.schema_migration where version = '0009q') = 1
              and exists (select 1 from cma.schema_migration where version = '0009p') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  if v_fn is null then
    v_bad := 'cma.inbound_now_first(integer) is missing; ';
  else
    if (select l.lanname || ':' || p.provolatile::text || ':' || p.prosecdef::text || ':' || pg_get_userbyid(p.proowner) || ':' || coalesce(array_to_string(p.proconfig, ','), '')
        from pg_proc p join pg_language l on l.oid = p.prolang where p.oid = v_fn) is distinct from 'plpgsql:s:false:cma_owner:' then
      v_bad := v_bad || 'language, volatility, rights or owner; ';
    end if;
    if pg_get_function_result(v_fn) <> 'jsonb' then v_bad := v_bad || 'its result is not jsonb; '; end if;
    if not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
       or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = v_fn and a.grantee = 0 and a.privilege_type = 'EXECUTE') then
      v_bad := v_bad || 'not the application''s only; ';
    end if;
  end if;
  if to_regprocedure('cma.inbound_now()') is null then v_bad := v_bad || 'cma.inbound_now() is gone; '; end if;
  insert into verify_0009q values (2, 'S2 cma.inbound_now_first(integer): plpgsql, stable, invoker, cma_owner, jsonb, the application''s only; cma.inbound_now() still there',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, case when v_provoke then 'provoked' else v_bad end);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- B. Two throwaway tenants, rolled back: 25 missed callers
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  rows_ text[] := '{}';
  v_t uuid; v_admin uuid; v_sup uuid; v_agent uuid; v_ing uuid; v_tel uuid; v_t2 uuid; v_admin2 uuid;
  v_txt text; v_bad text;
  j jsonb; j_old jsonb; j_all jsonb;
  v_t0 timestamptz;
  n integer;
begin
  begin
    -- the tenant, its people and its telephony connection (as the owner)
    v_t := cma.create_tenant('verify-0009q', 'Verify 0009q', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-admin@example.invalid', 'admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-sup@example.invalid', 'sup') returning id into v_sup;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-agent@example.invalid', 'agent') returning id into v_agent;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.user_id, ar.id
    from (values (v_admin, 'admin'), (v_sup, 'supervisor'), (v_agent, 'agent')) as x(user_id, role_key)
    join cma.app_role ar on ar.tenant_id = v_t and ar.key = x.role_key;
    select x.user_id into v_ing from cma.app_user_external_id x where x.tenant_id = v_t and x.system = 'ingest';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t, 'verifytel', 'Verify 0009q telephony', 'tel-1', 'telephony') returning id into v_tel;
    -- a second tenant without a call (B4), with its admin
    v_t2 := cma.create_tenant('verify-0009q-empty', 'Verify 0009q empty', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin') returning id into v_admin2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, v_admin2, ar.id from cma.app_role ar where ar.tenant_id = v_t2 and ar.key = 'admin';

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t::text, true);
    -- the line from the source (the Ingest user), then its market and that it counts (the admin)
    perform set_config('app.user_id', v_ing::text, true);
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'number', '[{"numberRef": "n-nl", "name": "Verify NL line", "digits": "+31000000001"}]');
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.set_telephony_number(v_tel, 'n-nl', 'NL', true);
    -- 25 callers who were not answered, a minute apart from three hours ago (each ended after 20 seconds: missed, not
    -- waiting), one caller who was answered, and one outbound call to nobody of them
    v_t0 := now() - interval '3 hours';
    perform set_config('app.user_id', v_ing::text, true);
    perform cma.ingest_upsert_telephony_calls(v_tel,
      (select jsonb_agg(pg_temp.v0009q_call('m' || lpad(g::text, 2, '0'), 'inbound', v_t0 + make_interval(mins => g), null, null, 'n-nl') order by g) from generate_series(1, 25) g)
      || jsonb_build_array(pg_temp.v0009q_call('a1', 'inbound', v_t0 + interval '40 minutes', 5, 60, 'n-nl'),
                           pg_temp.v0009q_call('o1', 'outbound', v_t0 + interval '41 minutes', 5, 30, 'n-nl')));

    -- B1. the permission and the parameter
    perform set_config('app.user_id', v_agent::text, true);
    v_txt := 'agent ' || pg_temp.v0009q_code('select cma.inbound_now_first(20)');
    perform set_config('app.user_id', v_sup::text, true);
    v_txt := v_txt || ' | below 0 ' || pg_temp.v0009q_code('select cma.inbound_now_first(-1)');
    rows_ := rows_ || array['11', 'B1 an agent is refused (CMA06); a count below 0 is refused (CMA04)',
      case when v_txt = 'agent CMA06 | below 0 CMA04' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];

    -- B2. every caller: cma.inbound_now()'s answer without the two kept keys, plus shown (one statement: one snapshot)
    select cma.inbound_now_first(null), cma.inbound_now() into j_all, j_old;
    v_bad := '';
    if (j_all #- '{summary,shown}') is distinct from (case when v_provoke then j_old #- '{today,longest_waiting_seconds}'
                                                           else j_old #- '{today,waiting_now}' #- '{today,longest_waiting_seconds}' end) then
      v_bad := v_bad || 'not cma.inbound_now()''s answer without the two kept keys; ';
    end if;
    if (j_all -> 'summary' ->> 'listed') is distinct from '25' or (j_all -> 'summary' ->> 'shown') is distinct from '25'
       or jsonb_array_length(j_all -> 'callbacks') <> 25 then
      v_bad := v_bad || format('listed %s, shown %s, %s callbacks; ', j_all -> 'summary' ->> 'listed', j_all -> 'summary' ->> 'shown', jsonb_array_length(j_all -> 'callbacks'));
    end if;
    rows_ := rows_ || array['12', 'B2 every caller (null): cma.inbound_now()''s answer without waiting_now and longest_waiting_seconds, plus shown; 25 listed and shown',
      case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end,
      case when v_bad = '' then format('25 callers; today''s keys %s', (select string_agg(k, ',' order by k collate "C") from jsonb_object_keys(j_all -> 'today') k)) else v_bad end];

    -- B3. the first 0, 1, 20 and 30
    v_bad := ''; v_txt := '';
    foreach n in array array[0, 1, 20, 30] loop
      select cma.inbound_now_first(n), cma.inbound_now() into j, j_old;
      if (j -> 'callbacks') is distinct from pg_temp.v0009q_first(j_old -> 'callbacks', case when v_provoke then n + 1 else n end) then
        v_bad := v_bad || format('the first %s are not cma.inbound_now()''s first %s; ', n, n);
      end if;
      if (j -> 'summary') is distinct from ((j_old -> 'summary') || jsonb_build_object('shown', least(n, 25))) then
        v_bad := v_bad || format('the summary of the first %s is %s; ', n, j -> 'summary');
      end if;
      if (j -> 'today') is distinct from (j_all -> 'today') then v_bad := v_bad || format('today differs for the first %s; ', n); end if;
      v_txt := v_txt || format('%s: %s shown of %s; ', n, j -> 'summary' ->> 'shown', j -> 'summary' ->> 'listed');
    end loop;
    rows_ := rows_ || array['13', 'B3 the first 0, 1, 20 and 30: cma.inbound_now()''s first so many in its order, listed stays 25, shown what the answer holds, today as for every caller',
      case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, case when v_bad = '' then v_txt else v_bad end];

    -- B4. the tenant without a call
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    j := cma.inbound_now_first(20);
    v_txt := format('%s callbacks, listed %s, shown %s', jsonb_array_length(j -> 'callbacks'), j -> 'summary' ->> 'listed', j -> 'summary' ->> 'shown');
    rows_ := rows_ || array['14', 'B4 a tenant without a call: no caller, listed 0, shown 0, nothing of the first tenant',
      case when v_txt = '0 callbacks, listed 0, shown 0' and not v_provoke then 'PASS' else 'FAIL' end, v_txt];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      rows_ := rows_ || array['19', 'B the throwaway tenants', 'FAIL', sqlstate || ': ' || sqlerrm];
  end;
  perform set_config('role', 'cma_owner', true);
  perform set_config('app.tenant_id', '', true);
  perform set_config('app.user_id', '', true);
  -- written after the rollback, so the rows stay
  for n in 0 .. (cardinality(rows_) / 4) - 1 loop
    insert into verify_0009q values (rows_[n * 4 + 1]::integer, rows_[n * 4 + 2], rows_[n * 4 + 3], rows_[n * 4 + 4]);
  end loop;
  if cardinality(rows_) < 16 and not exists (select 1 from verify_0009q where ord = 19) then
    insert into verify_0009q values (19, 'B the throwaway tenants', 'FAIL', 'the block wrote ' || cardinality(rows_) / 4 || ' of 4 rows');
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- E. Every active tenant's own missed callers, read as a person holding monitoring.live (nothing written)
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_runs  integer := current_setting('verify.timing_runs')::integer;
  v_slack numeric := current_setting('verify.slack_ms')::numeric;
  t record;
  v_user uuid;
  j jsonb; j_old jsonb;
  v_same boolean;
  v_t0 timestamptz; v_ms numeric; v_new numeric; v_old numeric;
  v_ord integer := 100;
begin
  for t in select x.id, x.slug from cma.tenant x where x.status = 'active' order by x.slug collate "C" loop
    v_ord := v_ord + 10;
    -- the tenant first: the people are read under row-level security
    perform set_config('app.tenant_id', t.id::text, true);
    perform set_config('app.user_id', '', true);
    v_user := pg_temp.v0009q_user(t.id, 'monitoring.live');
    if v_user is null then
      insert into verify_0009q values (v_ord, 'E ' || t.slug || ': the first 20 against every caller', case when v_provoke then 'FAIL' else 'skip' end,
        'no active person holds monitoring.live');
      continue;
    end if;
    perform set_config('app.tenant_id', t.id::text, true);
    perform set_config('app.user_id', v_user::text, true);
    perform set_config('role', 'cma_app', true);
    begin
      -- E1. every caller
      select cma.inbound_now_first(null), cma.inbound_now() into j, j_old;
      v_same := (j #- '{summary,shown}') is not distinct from (case when v_provoke then j_old #- '{today,longest_waiting_seconds}'
                                                                    else j_old #- '{today,waiting_now}' #- '{today,longest_waiting_seconds}' end)
                and (j -> 'summary' ->> 'shown') is not distinct from (j_old -> 'summary' ->> 'listed');
      insert into verify_0009q values (v_ord + 1, 'E1 ' || t.slug || ': every caller (null) equals cma.inbound_now() without the two kept keys, plus shown',
        case when v_same then 'PASS' else 'FAIL' end, format('%s callers listed', j_old -> 'summary' ->> 'listed'));
      -- E2. the first 20
      select cma.inbound_now_first(20), cma.inbound_now() into j, j_old;
      v_same := (j -> 'callbacks') is not distinct from pg_temp.v0009q_first(j_old -> 'callbacks', case when v_provoke then 21 else 20 end)
                and (j -> 'summary') is not distinct from ((j_old -> 'summary') || jsonb_build_object('shown', least(20, jsonb_array_length(j_old -> 'callbacks'))))
                and not (v_provoke and jsonb_array_length(j_old -> 'callbacks') <= 20);
      insert into verify_0009q values (v_ord + 2, 'E2 ' || t.slug || ': the first 20 are cma.inbound_now()''s first 20, listed its whole count',
        case when v_same then 'PASS' else 'FAIL' end,
        format('%s shown of %s listed; %s bytes against %s for every caller', j -> 'summary' ->> 'shown', j -> 'summary' ->> 'listed', length(j::text), length(j_old::text)));
      -- E3. the timing: six untimed calls of each, then the best of v_runs each, alternating
      for i in 1 .. 6 loop j := cma.inbound_now_first(20); j_old := cma.inbound_now(); end loop;
      v_new := null; v_old := null;
      for i in 1 .. v_runs loop
        v_t0 := clock_timestamp(); j := cma.inbound_now_first(20);
        v_ms := extract(epoch from clock_timestamp() - v_t0) * 1000; v_new := least(coalesce(v_new, v_ms), v_ms);
        v_t0 := clock_timestamp(); j_old := cma.inbound_now();
        v_ms := extract(epoch from clock_timestamp() - v_t0) * 1000; v_old := least(coalesce(v_old, v_ms), v_ms);
      end loop;
      insert into verify_0009q values (v_ord + 3, 'E3 ' || t.slug || ': the first 20 are read no slower than every caller',
        case when v_new <= (case when v_provoke then -1 else v_old + v_slack end) then 'PASS' else 'FAIL' end,
        format('%s ms against %s ms for every caller (best of %s each after six untimed, alternating; %s ms of noise allowed); %s bytes against %s',
               round(v_new, 2), round(v_old, 2), v_runs, v_slack, length(j::text), length(j_old::text)));
    exception when others then
      insert into verify_0009q values (v_ord + 9, 'E ' || t.slug || ': the first 20 against every caller', 'FAIL', sqlstate || ': ' || sqlerrm);
    end;
    perform set_config('role', 'cma_owner', true);
  end loop;
  perform set_config('app.tenant_id', '', true);
  perform set_config('app.user_id', '', true);
  if v_ord = 100 then
    insert into verify_0009q values (110, 'E the first 20 against every caller', case when v_provoke then 'FAIL' else 'skip' end, 'no active tenant');
  end if;
end
$$;

drop function if exists pg_temp.v0009q_user(uuid, text);
drop function if exists pg_temp.v0009q_first(jsonb, integer);
drop function if exists pg_temp.v0009q_code(text);
drop function if exists pg_temp.v0009q_call(text, text, timestamptz, integer, integer, text);

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0009q
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0009q where result = 'FAIL') then 'FAIL'
                  when not exists (select 1 from pg_temp.verify_0009q where result = 'PASS') then 'FAIL'
                  else 'PASS' end,
             format('183_verify_live_missed_first: %s PASS, %s FAIL, %s skip', (select count(*) from pg_temp.verify_0009q where result = 'PASS'),
                    (select count(*) from pg_temp.verify_0009q where result = 'FAIL'), (select count(*) from pg_temp.verify_0009q where result = 'skip'))) x
order by ord;
drop table if exists pg_temp.verify_0009q;
reset role;
