-- =============================================================================================
-- 153_verify_calls_of_restore.sql: verifies addition 0009b, cma.calls_of by 0008zc's rule again
-- =============================================================================================
-- Universal: no seed is assumed. Block S checks structure and privileges; block E proves cma.calls_of answers exactly
-- what 0008zc's definition (100_definitions_calls.sql, kept here verbatim as pg_temp.old_calls_of) answers, row for
-- row over the last 92 days of every active tenant, as the application acting as the tenant's first person holding
-- reports.view (a tenant without one reads skip); block B works on a throwaway tenant inside a subtransaction that is
-- always rolled back, so nothing stays and the script runs in dev and in prod. Every check writes one row, PASS, FAIL or
-- skip, and the last row is the verdict, because Cloud SQL Studio shows no notices. Run as your own IAM login after
-- 152_calls_of_restore.sql, dev first, then prod.
--   S  S1 the addition row, after 0008zz; S2 the function's arguments, columns, language, volatility, caller's rights,
--      owner, jit off, the application's only; S3 its text: the three helpers, both settings, the current tags grouped
--      once, and neither 0008j's connected rule nor a tag read per call
--   E  per active tenant: cma.calls_of against 0008zc's definition over the last 92 days, the same rows
--   B  a throwaway tenant (Europe/Amsterdam; a telephony connection, one NL line; tags Not Reached (not_reached), Not
--      Reached off (not_reached, not counted), Type (call_type) and Incorrect Data (incorrect_data)) with 101's thirteen
--      calls of 6 October 2026 and one more:
--        o1 outbound answered, 1 s of talk              o8 outbound, nobody answered
--        o2 outbound answered, still in progress        o9 outbound 45 s, tagged Type
--        o3 outbound 29 s, untagged                     o10 outbound 60 s, tagged Incorrect Data
--        o4 outbound 30 s, untagged                     i1 inbound answered 20 s
--        o5 outbound 30 s, tagged Not Reached           i2 inbound answered 45 s
--        o6 outbound 120 s, Not Reached since removed   i3 inbound answered 45 s, tagged Not Reached
--        o7 outbound 60 s, tagged Not Reached off       i4 inbound missed
--      B1 Connected and Conversation per call as 0008zc defines them (a call under the talk threshold and a call with a
--      tag meaning not_reached or incorrect_data are not a Conversation); B2 the two settings move the edges; B3 the
--      same rows as 0008zc's definition under each setting and with the market and line filters; B4 the tags per call
-- Expected verdict, in dev and in prod: "PASS | 153_verify_calls_of_restore: <n> PASS, 0 FAIL, <k> skip" (the skips are
-- tenants without a person holding reports.view); on 0008zr alone (before 152) S1, S3, E (wherever the 92 days hold a
-- call the two rules count differently), B1, B2 and B3 read FAIL. Provoked (verify.provoke true at the top): every row reads
-- FAIL (E and B3: 0008zc's side loses its first row before the comparison, or the row says the set was empty) and the
-- verdict PROVOKED, NOT A PASS.
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

drop table if exists pg_temp.verify_0009b;
create temporary table verify_0009b (ord integer, check_name text, result text, detail text);
-- block E writes its rows while acting as the application
grant select, insert on pg_temp.verify_0009b to cma_app;

-- calls_of as 100 (0008zc) defined it, verbatim under pg_temp.old_
create function pg_temp.old_calls_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz, p_market text, p_line text)
returns table(connection_id uuid, source_system text, direction text, line_key text, line_name text, market text, zone text,
              started_at timestamptz, business_date date, week_start date, local_time time, user_ref text,
              is_answered_inbound boolean, is_connected_outbound boolean, is_conversation boolean, talk_seconds integer,
              tag_refs text[], is_tagged boolean)
language sql stable
as $$
  with s as (
    select t.timezone as tenant_zone,
           greatest(0, cma.setting_of(t.id, 'telephony.connected_min_seconds')::integer) as connected_min,
           greatest(0, cma.setting_of(t.id, 'calls.conversation_min_talk_seconds')::integer) as conversation_min
    from cma.tenant t where t.id = p_tenant_id
  ),
  c as (
    select tc.connection_id, tc.source_system, tc.direction, tc.source_id, tc.started_at, tc.answered_at, tc.talk_seconds,
           tc.user_ref, tc.connection_id::text || ':' || coalesce(tc.number_ref, '') as lk,
           coalesce(n.name, tc.number_ref) as ln, coalesce(m.code, 'unknown') as mk, coalesce(m.time_zone, s.tenant_zone) as z,
           s.connected_min, s.conversation_min
    from cma.telephony_call tc
    cross join s
    left join cma.telephony_number n
      on n.tenant_id = tc.tenant_id and n.connection_id = tc.connection_id and n.number_ref = tc.number_ref
    left join cma.market m on m.tenant_id = tc.tenant_id and m.code = n.market
    where tc.tenant_id = p_tenant_id
      and tc.source_deleted_at is null
      and tc.started_at is not null
      and coalesce(n.is_counted, true)
      and tc.started_at >= coalesce(p_from, '-infinity'::timestamptz)
      and tc.started_at < coalesce(p_to, 'infinity'::timestamptz)
  )
  select c.connection_id, c.source_system, c.direction, c.lk, c.ln, c.mk, c.z, c.started_at,
         (c.started_at at time zone c.z)::date,
         date_trunc('week', (c.started_at at time zone c.z)::date::timestamp)::date,
         (c.started_at at time zone c.z)::time,
         c.user_ref,
         k.answered_in, k.connected_out,
         cma.is_conversation(c.direction, c.answered_at is not null, c.talk_seconds, c.connected_min, c.conversation_min, nr.not_reached),
         c.talk_seconds,
         coalesce(tg.refs, '{}'::text[]), tg.refs is not null
  from c
  cross join lateral (
    select c.direction = 'inbound' and c.answered_at is not null as answered_in,
           cma.is_connected(c.direction, c.answered_at is not null, c.talk_seconds, c.connected_min) as connected_out) k
  cross join lateral cma.call_not_reached_of(p_tenant_id, c.connection_id, c.source_id) nr
  left join lateral (
    select array_agg(ct.tag_ref order by ct.tag_ref) as refs
    from cma.telephony_call_tag ct
    where ct.tenant_id = p_tenant_id and ct.connection_id = c.connection_id and ct.call_source_id = c.source_id
      and ct.untagged_at is null) tg on true
  where (p_market is null or c.mk = p_market)
    and (p_line is null or c.lk = p_line)
$$;

-- Two set-returning calls compared as multisets: null when they answer the same rows, else what differs; in provoke mode
-- the old side loses its first row, so the comparison must fail
create or replace function pg_temp.v0009b_diff(p_new text, p_old text)
returns text
language plpgsql
as $$
declare
  v_old text := p_old;
  v_n_new bigint; v_n_old bigint; v_only_new bigint; v_only_old bigint;
begin
  if current_setting('verify.provoke')::boolean then
    v_old := format('select * from (%s) z offset 1', p_old);
  end if;
  execute format('select count(*) from (%s) a', p_new) into v_n_new;
  execute format('select count(*) from (%s) a', v_old) into v_n_old;
  if current_setting('verify.provoke')::boolean and v_n_new = 0 then
    return 'provoked, but the set is empty: nothing to differ (FAIL by the switch)';
  end if;
  execute format('select count(*) from ((%s) except all (%s)) a', p_new, v_old) into v_only_new;
  execute format('select count(*) from ((%s) except all (%s)) a', v_old, p_new) into v_only_old;
  if v_only_new = 0 and v_only_old = 0 then
    return null;
  end if;
  return format('%s rows now against %s by 0008zc: %s only now, %s only by 0008zc', v_n_new, v_n_old, v_only_new, v_only_old);
end
$$;

-- A check row kept as four texts, for the block whose subtransaction is rolled back (its rows must outlive it)
create or replace function pg_temp.v0009b_row(p_ord integer, p_name text, p_result text, p_detail text)
returns text[] language sql immutable as $$ select array[p_ord::text, p_name, p_result, p_detail] $$;

-- The tenant's first active person (the oldest) holding a permission, as the time scripts pick it
create or replace function pg_temp.v0009b_user(p_tenant uuid, p_perm text)
returns uuid
language sql
as $$
  select u.id from cma.app_user u
  where u.tenant_id = p_tenant and u.status = 'active' and u.kind = 'person' and cma.has_permission(u.id, p_perm)
  order by u.created_at, u.id limit 1
$$;

-- One telephony call as the ingest write takes it (as 101): answered p_ring seconds after the start (null: never), ended
-- p_talk seconds after the answer (null: not ended; for a call never answered, ended after 20 seconds), the line n-nl,
-- the user, an invented hash from the id and the current tag set (null: none sent)
create or replace function pg_temp.v0009b_call(p_src text, p_dir text, p_start timestamptz, p_ring integer, p_talk integer,
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

-- ---------------------------------------------------------------------------------------------
-- S. Structure and privileges
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_fn  regprocedure := to_regprocedure('cma.calls_of(uuid,timestamptz,timestamptz,text,text)');
  v_src text;
  v_bad text;
begin
  -- S1. the addition is recorded once, with 0008zz (its prerequisite)
  insert into verify_0009b values (1, 'S1 addition 0009b recorded once, after 0008zz',
    case when (select count(*) from cma.schema_migration where version = '0009b') = 1
              and exists (select 1 from cma.schema_migration where version = '0008zz') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- S2. the same arguments and columns (the web runs unchanged), SQL, stable, in the caller's rights, owned by cma_owner,
  --     jit off, executable by the application only
  v_bad := '';
  if v_fn is null then
    v_bad := 'cma.calls_of(uuid,timestamptz,timestamptz,text,text) is missing; ';
  else
    if pg_get_function_identity_arguments(v_fn) is distinct from
       'p_tenant_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_market text, p_line text' then
      v_bad := v_bad || 'the arguments; ';
    end if;
    if pg_get_function_result(v_fn) is distinct from
       'TABLE(connection_id uuid, source_system text, direction text, line_key text, line_name text, market text, zone text, started_at timestamp with time zone, business_date date, week_start date, local_time time without time zone, user_ref text, is_answered_inbound boolean, is_connected_outbound boolean, is_conversation boolean, talk_seconds integer, tag_refs text[], is_tagged boolean)' then
      v_bad := v_bad || 'the columns: ' || coalesce(pg_get_function_result(v_fn), 'none') || '; ';
    end if;
    if (select l.lanname || ':' || p.provolatile::text || ':' || p.prosecdef::text || ':' || pg_get_userbyid(p.proowner) || ':' || coalesce(array_to_string(p.proconfig, ','), '')
        from pg_proc p join pg_language l on l.oid = p.prolang where p.oid = v_fn) is distinct from 'sql:s:false:cma_owner:jit=off' then
      v_bad := v_bad || 'language, volatility, rights, owner or jit off; ';
    end if;
    if not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
       or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = v_fn and a.grantee = 0 and a.privilege_type = 'EXECUTE') then
      v_bad := v_bad || 'not the application''s only; ';
    end if;
  end if;
  insert into verify_0009b values (2, 'S2 the same arguments and columns; SQL, stable, invoker, cma_owner, jit off, the application''s only',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

  -- S3. the text: the three helpers and both settings (0008zc's rule), the current tags grouped once (0008zr's form);
  --     neither 0008j's connected rule (outbound at the setting's talk time, every answered or connected call a
  --     conversation) nor the tags read per call
  v_bad := '';
  select p.prosrc into v_src from pg_proc p where p.oid = v_fn;
  if coalesce(v_src, '') !~ 'cma\.is_connected\(' then v_bad := v_bad || 'no cma.is_connected; '; end if;
  if coalesce(v_src, '') !~ 'cma\.is_conversation\(' then v_bad := v_bad || 'no cma.is_conversation; '; end if;
  if coalesce(v_src, '') !~ 'cma\.call_not_reached_of\(' then v_bad := v_bad || 'no cma.call_not_reached_of; '; end if;
  if coalesce(v_src, '') !~ 'telephony\.connected_min_seconds' or coalesce(v_src, '') !~ 'calls\.conversation_min_talk_seconds' then
    v_bad := v_bad || 'a setting is not read; ';
  end if;
  if coalesce(v_src, '') !~ 'group by ct\.connection_id, ct\.call_source_id' then v_bad := v_bad || 'the tags are not grouped once; '; end if;
  if coalesce(v_src, '') ~ 'talk_seconds >= c\.connected_min|answered_in or k\.connected_out' then v_bad := v_bad || '0008j''s connected rule; '; end if;
  if coalesce(v_src, '') ~ 'left join lateral \(\s*select array_agg' then v_bad := v_bad || 'the tags read per call; '; end if;
  insert into verify_0009b values (3, 'S3 the helpers and both settings, the tags grouped once; no 0008j rule, no tag read per call',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- E. The same rows as 0008zc's definition, per active tenant, over the last 92 days
-- ---------------------------------------------------------------------------------------------
do $$
declare
  t record;
  v_user uuid; v_diff text; v_detail text; v_ord integer := 100; v_from date;
begin
  for t in select x.id, x.slug from cma.tenant x where x.status = 'active' order by x.slug collate "C" loop
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.tenant_id', t.id::text, true);
    perform set_config('app.user_id', '', true);
    v_user := pg_temp.v0009b_user(t.id, 'reports.view');
    v_ord := v_ord + 1;
    if v_user is null then
      insert into verify_0009b values (v_ord, 'E ' || t.slug, 'skip', 'no active person holds reports.view: nothing compared');
      continue;
    end if;
    v_from := cma.tenant_today_of(t.id) - 91;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_user::text, true);
    begin
      v_diff := pg_temp.v0009b_diff(format('select * from cma.calls_of(%L, %L::date::timestamptz, null, null, null)', t.id, v_from),
                                    format('select * from pg_temp.old_calls_of(%L, %L::date::timestamptz, null, null, null)', t.id, v_from));
      select format('%s call(s), %s connected, %s conversation(s), the same', count(*), count(*) filter (where c.is_connected_outbound),
                    count(*) filter (where c.is_conversation))
        into v_detail
      from cma.calls_of(t.id, v_from::timestamptz, null, null, null) c;
      insert into verify_0009b values (v_ord, 'E cma.calls_of against 0008zc''s definition, the last 92 days (' || t.slug || ')',
        case when v_diff is null then 'PASS' else 'FAIL' end, coalesce(v_diff, v_detail));
    exception when others then
      insert into verify_0009b values (v_ord, 'E cma.calls_of against 0008zc''s definition, the last 92 days (' || t.slug || ')', 'FAIL',
        'error ' || sqlstate || ': ' || left(sqlerrm, 120));
    end;
  end loop;
  perform set_config('role', 'cma_owner', true);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- B. Behaviour on a throwaway tenant, rolled back
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  rows_   text[] := '{}';
  v_t uuid; v_admin uuid; v_ing uuid; v_tel uuid;
  v_txt text; v_detail text; v_diff text; v_bad text;
  v_from timestamptz; v_to timestamptz;
  v_d    timestamptz := timestamptz '2026-10-06 08:00:00+00';   -- Tuesday 6 October 2026, 10:00 in Amsterdam
  v_nr   jsonb := '[{"tagRef": "tg-nr", "name": "Not Reached"}]';
  v_off  jsonb := '[{"tagRef": "tg-nr-off", "name": "Not Reached off"}]';
  v_type jsonb := '[{"tagRef": "tg-type", "name": "Type"}]';
  v_inc  jsonb := '[{"tagRef": "tg-inc", "name": "Incorrect Data"}]';
  -- the calls of the day, per setting: connected (c) and conversation (v), in source-id order
  v_flags constant text := $q$
    select string_agg(x.src || ':' || case when c.is_connected_outbound then 'c' else '-' end
                             || case when c.is_conversation then 'v' else '-' end, ' ' order by x.src collate "C")
    from cma.calls_of(%L, %L, %L, null, null) c
    join lateral (select tc.source_id as src from cma.telephony_call tc
                  where tc.tenant_id = %L and tc.connection_id = c.connection_id and tc.started_at = c.started_at) x on true$q$;
begin
  v_from := v_d - interval '1 day';
  v_to := v_d + interval '1 day';
  begin
    -- the tenant, its admin and its telephony connection (as the owner)
    v_t := cma.create_tenant('verify-0009b', 'Verify 0009b', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-admin@example.invalid', 'admin') returning id into v_admin;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, v_admin, ar.id from cma.app_role ar where ar.tenant_id = v_t and ar.key = 'admin';
    select x.user_id into v_ing from cma.app_user_external_id x where x.tenant_id = v_t and x.system = 'ingest';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t, 'verifytel', 'Verify 0009b telephony', 'tel-1', 'telephony') returning id into v_tel;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t::text, true);

    -- the catalogs from the source (the Ingest user), then the configuration (the admin): the market, the line, the
    -- meanings, Not Reached off not counted
    perform set_config('app.user_id', v_ing::text, true);
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'number', '[{"numberRef": "n-nl", "name": "Verify NL line", "digits": "+31000000001"}]');
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'tag', '[{"tagRef": "tg-nr", "name": "Not Reached"},
      {"tagRef": "tg-nr-off", "name": "Not Reached off"}, {"tagRef": "tg-type", "name": "Type"}, {"tagRef": "tg-inc", "name": "Incorrect Data"}]');
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.set_telephony_number(v_tel, 'n-nl', 'NL', true);
    perform cma.set_telephony_tag_meaning(v_tel, 'tg-nr', 'not_reached');
    perform cma.set_telephony_tag_meaning(v_tel, 'tg-nr-off', 'not_reached');
    perform cma.set_telephony_tag_meaning(v_tel, 'tg-type', 'call_type');
    perform cma.set_telephony_tag_meaning(v_tel, 'tg-inc', 'incorrect_data');
    perform cma.set_telephony_tag(v_tel, 'tg-nr-off', false);

    -- the calls of 6 October (the Ingest user): five seconds of ringing, then the talk
    perform set_config('app.user_id', v_ing::text, true);
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
      pg_temp.v0009b_call('o1',  'outbound', v_d,                           5, 1,    'tu-1', null),
      pg_temp.v0009b_call('o2',  'outbound', v_d + interval '10 minutes',  5, null, 'tu-1', null),
      pg_temp.v0009b_call('o3',  'outbound', v_d + interval '20 minutes',  5, 29,   'tu-1', null),
      pg_temp.v0009b_call('o4',  'outbound', v_d + interval '30 minutes',  5, 30,   'tu-1', null),
      pg_temp.v0009b_call('o5',  'outbound', v_d + interval '40 minutes',  5, 30,   'tu-1', v_nr),
      pg_temp.v0009b_call('o6',  'outbound', v_d + interval '50 minutes',  5, 120,  'tu-1', v_nr),
      pg_temp.v0009b_call('o7',  'outbound', v_d + interval '60 minutes',  5, 60,   'tu-1', v_off),
      pg_temp.v0009b_call('o8',  'outbound', v_d + interval '70 minutes',  null, null, 'tu-1', null),
      pg_temp.v0009b_call('o9',  'outbound', v_d + interval '80 minutes',  5, 45,   'tu-1', v_type),
      pg_temp.v0009b_call('o10', 'outbound', v_d + interval '85 minutes',  5, 60,   'tu-1', v_inc),
      pg_temp.v0009b_call('i1',  'inbound',  v_d + interval '90 minutes',  5, 20,   'tu-2', null),
      pg_temp.v0009b_call('i2',  'inbound',  v_d + interval '100 minutes', 5, 45,   'tu-2', null),
      pg_temp.v0009b_call('i3',  'inbound',  v_d + interval '110 minutes', 5, 45,   'tu-2', v_nr),
      pg_temp.v0009b_call('i4',  'inbound',  v_d + interval '120 minutes', null, null, null, null)));
    -- o6's Not Reached removed later: an empty tag set closes it
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
      pg_temp.v0009b_call('o6', 'outbound', v_d + interval '50 minutes', 5, 120, 'tu-1', '[]'::jsonb)
        || jsonb_build_object('versionAt', v_d + interval '5 hours')));
    perform set_config('app.user_id', v_admin::text, true);

    -- B1. Connected and Conversation per call, as 0008zc defines them: connected when outbound and answered, at 1 s and
    --     while in progress, never unanswered; a Conversation at 30 s of talk, not at 29 (o3) or 20 (i1), not with a
    --     current tag meaning not_reached (o5, i3; also on a tag that does not count, o7) or incorrect_data (o10), again
    --     once the tag is removed (o6); inbound answered at 45 s (i2)
    execute format(v_flags, v_t, v_from, v_to, v_t) into v_txt;
    rows_ := rows_ || pg_temp.v0009b_row(11, 'B1 Connected and Conversation per call; under the talk threshold, not_reached and incorrect_data are no Conversation',
      case when v_txt = 'i1:-- i2:-v i3:-- i4:-- o1:c- o10:c- o2:c- o3:c- o4:cv o5:c- o6:cv o7:c- o8:-- o9:cv' and not v_provoke then 'PASS' else 'FAIL' end,
      coalesce(v_txt, 'no rows'));

    -- B2. the settings move the edges: telephony.connected_min_seconds 5 leaves o1 (1 s) and o2 (no talk yet) not
    --     connected; calls.conversation_min_talk_seconds 29 makes o3 a conversation, 46 leaves o6 (120 s) only
    perform cma.set_tenant_setting('telephony.connected_min_seconds', '5');
    execute format(v_flags, v_t, v_from, v_to, v_t) into v_detail;
    v_bad := case when v_detail = 'i1:-- i2:-v i3:-- i4:-- o1:-- o10:c- o2:-- o3:c- o4:cv o5:c- o6:cv o7:c- o8:-- o9:cv' then '' else 'connected from 5 s: ' || coalesce(v_detail, 'no rows') || '; ' end;
    perform cma.set_tenant_setting('telephony.connected_min_seconds', null);
    perform cma.set_tenant_setting('calls.conversation_min_talk_seconds', '29');
    execute format(v_flags, v_t, v_from, v_to, v_t) into v_detail;
    v_bad := v_bad || case when v_detail = 'i1:-- i2:-v i3:-- i4:-- o1:c- o10:c- o2:c- o3:cv o4:cv o5:c- o6:cv o7:c- o8:-- o9:cv' then '' else 'threshold 29: ' || coalesce(v_detail, 'no rows') || '; ' end;
    perform cma.set_tenant_setting('calls.conversation_min_talk_seconds', '46');
    execute format(v_flags, v_t, v_from, v_to, v_t) into v_detail;
    v_bad := v_bad || case when v_detail = 'i1:-- i2:-- i3:-- i4:-- o1:c- o10:c- o2:c- o3:c- o4:c- o5:c- o6:cv o7:c- o8:-- o9:c-' then '' else 'threshold 46: ' || coalesce(v_detail, 'no rows') || '; ' end;
    perform cma.set_tenant_setting('calls.conversation_min_talk_seconds', null);
    rows_ := rows_ || pg_temp.v0009b_row(12, 'B2 connected from 5 s leaves 1 s and in progress out; the Conversation threshold at 29 and 46 s',
      case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, case when v_bad = '' then 'connected 7, 9, 9; conversations 4, 5, 1' else v_bad end);

    -- B3. the same rows as 0008zc's definition: under each setting above, and with the market and the line filters
    v_bad := '';
    perform cma.set_tenant_setting('telephony.connected_min_seconds', '5');
    v_diff := pg_temp.v0009b_diff(format('select * from cma.calls_of(%L, %L, %L, null, null)', v_t, v_from, v_to),
                                  format('select * from pg_temp.old_calls_of(%L, %L, %L, null, null)', v_t, v_from, v_to));
    v_bad := v_bad || coalesce('connected from 5 s: ' || v_diff || '; ', '');
    perform cma.set_tenant_setting('telephony.connected_min_seconds', null);
    foreach v_txt in array array['29', '46', null] loop
      perform cma.set_tenant_setting('calls.conversation_min_talk_seconds', v_txt);
      v_diff := pg_temp.v0009b_diff(format('select * from cma.calls_of(%L, %L, %L, null, null)', v_t, v_from, v_to),
                                    format('select * from pg_temp.old_calls_of(%L, %L, %L, null, null)', v_t, v_from, v_to));
      v_bad := v_bad || coalesce('threshold ' || coalesce(v_txt, 'default') || ': ' || v_diff || '; ', '');
    end loop;
    v_diff := pg_temp.v0009b_diff(format('select * from cma.calls_of(%L, null, null, %L, %L)', v_t, 'NL', v_tel::text || ':n-nl'),
                                  format('select * from pg_temp.old_calls_of(%L, null, null, %L, %L)', v_t, 'NL', v_tel::text || ':n-nl'));
    v_bad := v_bad || coalesce('market and line: ' || v_diff || '; ', '');
    if (select count(*) from cma.calls_of(v_t, null, null, 'DE', null)) <> 0 then
      v_bad := v_bad || 'another market holds calls; ';
    end if;
    rows_ := rows_ || pg_temp.v0009b_row(13, 'B3 the same rows as 0008zc''s definition under each setting, with the market and line filters',
      case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, case when v_bad = '' then 'five comparisons, 14 rows each, the same' else v_bad end);

    -- B4. the tags per call: the current tags, sorted; o6 untagged once its tag is removed
    select string_agg(format('%s:%s', x.src, array_to_string(c.tag_refs, ',')), ' ' order by x.src collate "C") into v_txt
    from cma.calls_of(v_t, v_from, v_to, null, null) c
    join lateral (select tc.source_id as src from cma.telephony_call tc
                  where tc.tenant_id = v_t and tc.connection_id = c.connection_id and tc.started_at = c.started_at) x on true
    where c.is_tagged;
    rows_ := rows_ || pg_temp.v0009b_row(14, 'B4 the current tags per call; a removed tag no longer counts',
      case when v_txt = 'i3:tg-nr o10:tg-inc o5:tg-nr o7:tg-nr-off o9:tg-type' and not v_provoke then 'PASS' else 'FAIL' end,
      coalesce(v_txt, 'no rows'));

    raise exception using errcode = 'CMAOK';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      rows_ := rows_ || pg_temp.v0009b_row(199, 'B block ended early', 'FAIL', 'error ' || sqlstate || ': ' || left(sqlerrm, 160));
  end;
  perform set_config('role', 'cma_owner', true);
  insert into verify_0009b (ord, check_name, result, detail)
  select rows_[4 * i - 3]::integer, rows_[4 * i - 2], rows_[4 * i - 1], rows_[4 * i] from generate_series(1, cardinality(rows_) / 4) i;
end
$$;

drop function if exists pg_temp.v0009b_diff(text, text);
drop function if exists pg_temp.v0009b_row(integer, text, text, text);
drop function if exists pg_temp.v0009b_user(uuid, text);
drop function if exists pg_temp.v0009b_call(text, text, timestamptz, integer, integer, text, jsonb);
drop function if exists pg_temp.old_calls_of;

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0009b
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0009b where result = 'FAIL') then 'FAIL'
                  when not exists (select 1 from pg_temp.verify_0009b where result = 'PASS') then 'FAIL'
                  else 'PASS' end,
             format('153_verify_calls_of_restore: %s PASS, %s FAIL, %s skip', (select count(*) from pg_temp.verify_0009b where result = 'PASS'),
                    (select count(*) from pg_temp.verify_0009b where result = 'FAIL'), (select count(*) from pg_temp.verify_0009b where result = 'skip'))) x
order by ord;
drop table if exists pg_temp.verify_0009b;
reset role;
