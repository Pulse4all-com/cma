-- =============================================================================================
-- 187_verify_live_missed_first_dropped.sql: verifies addition 0009s, the reversal of addition 0009q
-- =============================================================================================
-- Blocks S check the addition, the dropped read and cma.inbound_now() (universal). Block B works on a throwaway tenant
-- inside a subtransaction that is always rolled back, so nothing stays: three invented missed callers on a counted line.
-- Block E reads every active tenant's own missed callers as a person holding monitoring.live and writes nothing. The
-- script runs alike in dev and in prod, and in a database where 0009q never ran. Every check writes one row, PASS, FAIL
-- or skip, and the last row is the verdict, because Cloud SQL Studio shows no notices:
-- "PASS | 187_verify_live_missed_first_dropped: n PASS, 0 FAIL, n skip". Run as your own IAM login after
-- 186_drop_live_missed_first.sql, dev first, then prod.
--   S1  the addition 0009s is recorded once, after 0009p; where 0009q ran, its row is still there once and 0009s is
--       recorded after it (history kept); where it never ran, the detail says so
--   S2  no function cma.inbound_now_first of any argument types, and no function or view of cma or cma_read names it
--   S3  cma.inbound_now() unchanged: plpgsql, stable, in the caller's rights, cma_owner's, without settings, jsonb, the
--       application's only, and its body character for character the body 170_live_inbound_talk.sql gave it (kept below)
--   B1  as a supervisor of a throwaway tenant: cma.inbound_now() answers today, callbacks and summary; the three callers
--       not called back, oldest first, each with its record link; listed 3. An agent is refused (CMA06); the dropped
--       read is unknown (42883)
--   E1  per active tenant, as its first active person holding monitoring.live: cma.inbound_now() answers today,
--       callbacks and summary, listed the callbacks' count
-- A tenant without a person holding monitoring.live reads skip in E (FAIL when provoked).
-- Provoke: set provoke below to true; every check must then read FAIL, and the verdict says PROVOKED, NOT A PASS. The
-- checks are provoked by a deliberate difference: S1 and S2 by the provoke itself, S3 compares with 170's body with one
-- character changed, B1 expects four callers, E1 one caller more than listed.
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

drop table if exists pg_temp.verify_0009s;
create temporary table verify_0009s (ord integer, check_name text, result text, detail text);
-- block E writes its rows while acting as the application
grant select, insert on pg_temp.verify_0009s to cma_app;

-- One telephony call as the ingest write takes it (as 183): answered p_ring seconds after the start (null: never, and
-- ended after 20 seconds), ended p_talk seconds after the answer, on the line p_number, an invented hash from the id
create or replace function pg_temp.v0009s_call(p_src text, p_dir text, p_start timestamptz, p_ring integer, p_talk integer, p_number text)
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
create or replace function pg_temp.v0009s_code(p_sql text)
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

-- The first active person of a tenant holding a permission (as 183)
create or replace function pg_temp.v0009s_user(p_tenant uuid, p_perm text)
returns uuid
language sql stable
as $$
  select u.id from cma.app_user u
  where u.tenant_id = p_tenant and u.status = 'active' and u.kind = 'person' and cma.has_permission(u.id, p_perm)
  order by u.created_at, u.id limit 1
$$;

-- ---------------------------------------------------------------------------------------------
-- S. The addition, the dropped read and cma.inbound_now()
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_fn  regprocedure := to_regprocedure('cma.inbound_now()');
  v_bad text := '';
  v_txt text;
  -- cma.inbound_now()'s body as 170_live_inbound_talk.sql gave it, character for character (the latest definition in
  -- run order; 182 and 186 leave it alone)
  v_170 text := $body$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_list   jsonb;
begin
  perform cma.assert_permission('monitoring.live');
  select coalesce(jsonb_agg(to_jsonb(m) || jsonb_build_object('record_url', cma.record_url(m.connection_id, 'call', m.source_id)) order by m.started_at, m.source_id), '[]'::jsonb)
    into v_list
  from cma.missed_callbacks_of(v_tenant) m;
  return jsonb_build_object(
    'today', (select to_jsonb(x) || '{"longest_waiting_seconds": null}'::jsonb from cma.inbound_today_live_of(v_tenant) x),
    'callbacks', v_list,
    'summary', (select jsonb_build_object('listed', jsonb_array_length(v_list),
                                          'anonymous_count', cma.anonymous_missed_calls_of(v_tenant, now() - make_interval(days => s.lookback)),
                                          'lookback_days', s.lookback)
                from (select greatest(0, cma.setting_of(t.id, 'telephony.callback_lookback_days')::integer) as lookback
                      from cma.tenant t where t.id = v_tenant) s));
end
$body$;
begin
  -- S1
  if (select count(*) from cma.schema_migration where version = '0009s') <> 1 then
    v_bad := '0009s is not recorded once; ';
  end if;
  if not exists (select 1 from cma.schema_migration where version = '0009p') then
    v_bad := v_bad || '0009p is not recorded; ';
  end if;
  if exists (select 1 from cma.schema_migration where version = '0009q') then
    if (select count(*) from cma.schema_migration where version = '0009q') <> 1 then
      v_bad := v_bad || '0009q''s row is not there once; ';
    elsif (select applied_at from cma.schema_migration where version = '0009s') <= (select applied_at from cma.schema_migration where version = '0009q') then
      v_bad := v_bad || '0009s is not recorded after 0009q; ';
    end if;
    v_txt := '0009q ran here: its row stays, 0009s after it';
  else
    v_txt := '0009q never ran here: 0009s recorded all the same';
  end if;
  insert into verify_0009s values (1, 'S1 addition 0009s recorded once, after 0009p; 0009q''s row, where it ran, still there before it',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, case when v_provoke then 'provoked' when v_bad = '' then v_txt else v_bad end);

  -- S2
  v_bad := '';
  select coalesce(string_agg(p.oid::regprocedure::text, ', ' order by p.oid::regprocedure::text collate "C"), '') into v_txt
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where p.proname = 'inbound_now_first';
  if v_txt <> '' then v_bad := 'still there: ' || v_txt || '; '; end if;
  select coalesce(string_agg(x.name, ', ' order by x.name collate "C"), '') into v_txt
  from (select p.oid::regprocedure::text as name
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname in ('cma', 'cma_read') and p.prosrc like '%inbound\_now\_first%'
        union all
        select n.nspname || '.' || c.relname
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname in ('cma', 'cma_read') and c.relkind in ('v', 'm') and pg_get_viewdef(c.oid) like '%inbound\_now\_first%') x;
  if v_txt <> '' then v_bad := v_bad || 'named by: ' || v_txt || '; '; end if;
  insert into verify_0009s values (2, 'S2 no function cma.inbound_now_first of any argument types; no function or view of cma or cma_read names it',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, case when v_provoke then 'provoked' else v_bad end);

  -- S3
  v_bad := '';
  if v_provoke then
    v_170 := replace(v_170, 'monitoring.live', 'monitoring.live ');
  end if;
  if v_fn is null then
    v_bad := 'cma.inbound_now() is missing; ';
  else
    if (select l.lanname || ':' || p.provolatile::text || ':' || p.prosecdef::text || ':' || pg_get_userbyid(p.proowner) || ':' || coalesce(array_to_string(p.proconfig, ','), '')
        from pg_proc p join pg_language l on l.oid = p.prolang where p.oid = v_fn) is distinct from 'plpgsql:s:false:cma_owner:' then
      v_bad := v_bad || 'language, volatility, rights, owner or settings; ';
    end if;
    if pg_get_function_result(v_fn) <> 'jsonb' then v_bad := v_bad || 'its result is not jsonb; '; end if;
    if not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
       or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = v_fn and a.grantee = 0 and a.privilege_type = 'EXECUTE') then
      v_bad := v_bad || 'not the application''s only; ';
    end if;
    if (select p.prosrc from pg_proc p where p.oid = v_fn) is distinct from v_170 then
      v_bad := v_bad || 'its body is not 170''s; ';
    end if;
  end if;
  insert into verify_0009s values (3, 'S3 cma.inbound_now() unchanged: plpgsql, stable, invoker, cma_owner, jsonb, the application''s only, 170''s body',
    case when v_bad = '' then 'PASS' else 'FAIL' end,
    case when v_bad = '' then 'body md5 ' || (select md5(p.prosrc) from pg_proc p where p.oid = v_fn) else v_bad end);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- B. A throwaway tenant, rolled back: three missed callers
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  rows_ text[] := '{}';
  v_t uuid; v_sup uuid; v_agent uuid; v_ing uuid; v_tel uuid; v_admin uuid;
  v_txt text; v_bad text := '';
  j jsonb;
  v_t0 timestamptz;
  n integer;
begin
  begin
    -- the tenant, its people and its telephony connection (as the owner)
    v_t := cma.create_tenant('verify-0009s', 'Verify 0009s', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-admin@example.invalid', 'admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-sup@example.invalid', 'sup') returning id into v_sup;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-agent@example.invalid', 'agent') returning id into v_agent;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.user_id, ar.id
    from (values (v_admin, 'admin'), (v_sup, 'supervisor'), (v_agent, 'agent')) as x(user_id, role_key)
    join cma.app_role ar on ar.tenant_id = v_t and ar.key = x.role_key;
    select x.user_id into v_ing from cma.app_user_external_id x where x.tenant_id = v_t and x.system = 'ingest';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t, 'verifytel', 'Verify 0009s telephony', 'tel-1', 'telephony') returning id into v_tel;

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t::text, true);
    -- the line from the source (the Ingest user), then its market and that it counts (the admin)
    perform set_config('app.user_id', v_ing::text, true);
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'number', '[{"numberRef": "n-nl", "name": "Verify NL line", "digits": "+31000000001"}]');
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.set_telephony_number(v_tel, 'n-nl', 'NL', true);
    -- three callers who were not answered, a minute apart from three hours ago (each ended after 20 seconds: missed, not
    -- waiting), a fourth who was missed and then called back, and a caller who was answered
    v_t0 := now() - interval '3 hours';
    perform set_config('app.user_id', v_ing::text, true);
    perform cma.ingest_upsert_telephony_calls(v_tel,
      jsonb_build_array(pg_temp.v0009s_call('m3', 'inbound', v_t0 + interval '3 minutes', null, null, 'n-nl'),
                        pg_temp.v0009s_call('m1', 'inbound', v_t0 + interval '1 minute', null, null, 'n-nl'),
                        pg_temp.v0009s_call('m2', 'inbound', v_t0 + interval '2 minutes', null, null, 'n-nl'),
                        pg_temp.v0009s_call('m4', 'inbound', v_t0 + interval '4 minutes', null, null, 'n-nl'),
                        pg_temp.v0009s_call('a1', 'inbound', v_t0 + interval '40 minutes', 5, 60, 'n-nl'))
      -- the callback to m4's caller: an outbound call to the same hash
      || jsonb_build_array(pg_temp.v0009s_call('m4', 'outbound', v_t0 + interval '41 minutes', 5, 30, 'n-nl')
                           || jsonb_build_object('sourceId', 'o1')));

    -- B1. the answer, the permission and the dropped read
    perform set_config('app.user_id', v_sup::text, true);
    j := cma.inbound_now();
    if (select string_agg(k, ',' order by k collate "C") from jsonb_object_keys(j) k) is distinct from 'callbacks,summary,today' then
      v_bad := v_bad || format('the keys are %s; ', (select string_agg(k, ',' order by k collate "C") from jsonb_object_keys(j) k));
    end if;
    n := case when v_provoke then 4 else 3 end;
    if jsonb_array_length(j -> 'callbacks') <> n or (j -> 'summary' ->> 'listed') is distinct from n::text then
      v_bad := v_bad || format('%s callbacks, listed %s, against %s; ', jsonb_array_length(j -> 'callbacks'), j -> 'summary' ->> 'listed', n);
    end if;
    if (select string_agg(e ->> 'source_id', ',' order by o) from jsonb_array_elements(j -> 'callbacks') with ordinality x(e, o)) is distinct from 'm1,m2,m3' then
      v_bad := v_bad || format('the callers are %s, not m1,m2,m3 oldest first; ',
                               (select string_agg(e ->> 'source_id', ',' order by o) from jsonb_array_elements(j -> 'callbacks') with ordinality x(e, o)));
    end if;
    if exists (select 1 from jsonb_array_elements(j -> 'callbacks') e where not (e ? 'record_url')) then
      v_bad := v_bad || 'a caller without its record link; ';
    end if;
    perform set_config('app.user_id', v_agent::text, true);
    v_txt := 'agent ' || pg_temp.v0009s_code('select cma.inbound_now()');
    perform set_config('app.user_id', v_sup::text, true);
    v_txt := v_txt || ' | first twenty ' || pg_temp.v0009s_code('select cma.inbound_now_first(20)');
    if v_txt <> 'agent CMA06 | first twenty 42883' then v_bad := v_bad || v_txt || '; '; end if;
    rows_ := rows_ || array['11', 'B1 cma.inbound_now() answers today, callbacks and summary: the three callers not called back, oldest first, with their record links, listed 3; an agent refused (CMA06); the dropped read unknown (42883)',
      case when v_bad = '' then 'PASS' else 'FAIL' end,
      case when v_bad = '' then format('3 callers; %s', v_txt) else v_bad end];
    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      rows_ := rows_ || array['19', 'B the throwaway tenant', 'FAIL', sqlstate || ': ' || sqlerrm];
  end;
  perform set_config('role', 'cma_owner', true);
  perform set_config('app.tenant_id', '', true);
  perform set_config('app.user_id', '', true);
  -- written after the rollback, so the rows stay
  for n in 0 .. (cardinality(rows_) / 4) - 1 loop
    insert into verify_0009s values (rows_[n * 4 + 1]::integer, rows_[n * 4 + 2], rows_[n * 4 + 3], rows_[n * 4 + 4]);
  end loop;
  if cardinality(rows_) < 4 then
    insert into verify_0009s values (19, 'B the throwaway tenant', 'FAIL', 'the block wrote no row');
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- E. Every active tenant's own missed callers, read as a person holding monitoring.live (nothing written)
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  t record;
  v_user uuid;
  j jsonb;
  v_ok boolean;
  v_ord integer := 100;
begin
  for t in select x.id, x.slug from cma.tenant x where x.status = 'active' order by x.slug collate "C" loop
    v_ord := v_ord + 10;
    -- the tenant first: the people are read under row-level security
    perform set_config('app.tenant_id', t.id::text, true);
    perform set_config('app.user_id', '', true);
    v_user := pg_temp.v0009s_user(t.id, 'monitoring.live');
    if v_user is null then
      insert into verify_0009s values (v_ord, 'E1 ' || t.slug || ': cma.inbound_now() answers', case when v_provoke then 'FAIL' else 'skip' end,
        'no active person holds monitoring.live');
      continue;
    end if;
    perform set_config('app.user_id', v_user::text, true);
    perform set_config('role', 'cma_app', true);
    begin
      j := cma.inbound_now();
      v_ok := (select string_agg(k, ',' order by k collate "C") from jsonb_object_keys(j) k) = 'callbacks,summary,today'
              and jsonb_typeof(j -> 'callbacks') = 'array'
              and (j -> 'summary' ->> 'listed') = (jsonb_array_length(j -> 'callbacks') + case when v_provoke then 1 else 0 end)::text;
      insert into verify_0009s values (v_ord + 1, 'E1 ' || t.slug || ': cma.inbound_now() answers today, callbacks and summary, listed the callbacks'' count',
        case when v_ok then 'PASS' else 'FAIL' end, format('%s callers listed', j -> 'summary' ->> 'listed'));
    exception when others then
      insert into verify_0009s values (v_ord + 9, 'E1 ' || t.slug || ': cma.inbound_now() answers', 'FAIL', sqlstate || ': ' || sqlerrm);
    end;
    perform set_config('role', 'cma_owner', true);
  end loop;
  perform set_config('app.tenant_id', '', true);
  perform set_config('app.user_id', '', true);
  if v_ord = 100 then
    insert into verify_0009s values (110, 'E1 cma.inbound_now() answers', case when v_provoke then 'FAIL' else 'skip' end, 'no active tenant');
  end if;
end
$$;

drop function if exists pg_temp.v0009s_user(uuid, text);
drop function if exists pg_temp.v0009s_code(text);
drop function if exists pg_temp.v0009s_call(text, text, timestamptz, integer, integer, text);

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0009s
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0009s where result = 'FAIL') then 'FAIL'
                  when not exists (select 1 from pg_temp.verify_0009s where result = 'PASS') then 'FAIL'
                  else 'PASS' end,
             format('187_verify_live_missed_first_dropped: %s PASS, %s FAIL, %s skip', (select count(*) from pg_temp.verify_0009s where result = 'PASS'),
                    (select count(*) from pg_temp.verify_0009s where result = 'FAIL'), (select count(*) from pg_temp.verify_0009s where result = 'skip'))) x
order by ord;
drop table if exists pg_temp.verify_0009s;
reset role;
