-- =============================================================================================
-- 167_verify_live_outbound_direct.sql: verifies addition 0009i, the Live board's Outbound today read from
-- cma.telephony_call directly
-- =============================================================================================
-- Universal: no seed is assumed. Block S checks the addition, the function and its grants. Block B works on a throwaway
-- tenant inside a subtransaction that is always rolled back, so nothing stays and the script runs in dev and in prod:
-- synthetic people (example.invalid) and 165's fixed test calls of Tuesday 6 October 2026 (Europe/Amsterdam, with a
-- line in America/New_York and one in Asia/Tokyo, and the running day's calls), plus three calls for the tag rule (a tag
-- meaning incorrect_data, a tag meaning not_reached that does not count, a tag meaning not_reached that was removed).
-- Block E works on the database it runs in, per active tenant, as the application acting as the tenant's first person
-- holding monitoring.live. The comparison is with 0009h's definition (164: the read through cma.calls_of), kept here
-- verbatim as a temporary function, row for row (the function answers one row: its seven columns as one text). Every
-- check writes one row, PASS, FAIL or skip, and the last row is the verdict, because Cloud SQL Studio shows no
-- notices. Run as your own IAM login after 166_live_outbound_direct.sql, dev first, then prod; then
-- 165_verify_live_outbound.sql again in dev (it reads cma.outbound_today_of; unchanged, still PASS). Expected verdict:
-- "PASS | 167_verify_live_outbound_direct: <n> PASS, 0 FAIL, <k> skip" (a skip is an active tenant without a person
-- holding monitoring.live); provoked (verify.provoke true below): every check reads FAIL and the verdict "PROVOKED, NOT
-- A PASS".
--   S1  the addition 0009i is recorded once, after 0009h
--   S2  cma.outbound_today_of(uuid, timestamptz): SQL, stable, the caller's rights, owned by cma_owner, jit off, rows 1,
--       the seven columns of 164, executable by the application only; its text reads cma.telephony_call, calls
--       cma.is_connected, cma.is_conversation and cma.tag_meaning_excludes_conversation, and does not call cma.calls_of
--   B1  the fixed calls of 6 October: 11 attempts, 10 connected, 90.9, 5 conversations (not with a current tag meaning
--       not_reached, counted or not, nor incorrect_data; again once the tag is removed), 751 s, 83.4 on average
--   B2  the same row as 0009h's definition at five instants (6 October, the day before with its two calls, 1 October
--       without a call, 7 October, the running day) and at 6 October under two settings
--       (telephony.connected_min_seconds 5, calls.conversation_min_talk_seconds 31)
--   B3  the plan of the function's own statement, as the application, in the generic plan: cma.telephony_call is read
--       by an index with a condition on started_at, never by a sequential scan (with enable_seqscan off: the throwaway
--       tenant is too small for the planner to prefer an index otherwise; what is proven is that the bounds reach the
--       index under row-level security in a generic plan, which is where 0008zr's reads lost it, see 144)
--   E1  per active tenant: the same row as 0009h's definition for the live day (now)
--   E2  per active tenant: the plan check of B3 on the tenant's own data
--   E3  per active tenant: no slower than 0009h's definition: the best of verify.timing_runs runs each, at most 0009h's
--       best plus verify.slack_ms (the poll's 20 ms budget itself is 131 part a's row "outbound now")
-- Provoke: set provoke below to true; every check must then read FAIL, and the verdict says PROVOKED, NOT A PASS. The
-- comparisons are provoked by a deliberate difference: 0009h's side is then read a day earlier (B2, and E1 where the
-- two days differ), and the plan check then demands an index on a column no index has.
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
select set_config('verify.timing_runs', '8', false);                 -- runs per read in E3 (the seventh call of a session included)
select set_config('verify.slack_ms', '3', false);                    -- E3: what the direct read may take above 0009h's best

drop table if exists pg_temp.verify_0009i;
create temporary table verify_0009i (ord integer, check_name text, result text, detail text);
-- block E writes its rows while acting as the application
grant select, insert on pg_temp.verify_0009i to cma_app;

-- cma.outbound_today_of as 0009h (164) defined it, verbatim: the read through cma.calls_of
create function pg_temp.outbound_today_of_0009h(p_tenant_id uuid, p_now timestamptz)
returns table (
  business_date          date,
  attempts               integer,
  connected              integer,
  connected_rate         numeric,
  conversations          integer,
  outbound_talk_seconds  bigint,
  outbound_talk_avg      numeric
)
language sql stable
rows 1
as $$
  with s as (
    select t.timezone as zone, (p_now at time zone t.timezone)::date as today
    from cma.tenant t where t.id = p_tenant_id
  ),
  -- the instants the date covers in any zone a call of the tenant can have (cma.calls_of: the line's market's, else the
  -- tenant's): from the date's first midnight to its last. A call whose business date is the date started inside its own
  -- zone's day, so inside this window; for a tenant in one zone the window is the day itself
  w as (
    select min(s.today::timestamp at time zone z.zone) as from_at, max((s.today + 1)::timestamp at time zone z.zone) as to_at
    from s
    cross join lateral (select s.zone
                        union
                        select m.time_zone from cma.market m where m.tenant_id = p_tenant_id and m.time_zone is not null) z
  )
  select (select s.today from s),
         count(*)::integer,
         (count(*) filter (where c.is_connected_outbound))::integer,
         round(100.0 * count(*) filter (where c.is_connected_outbound) / nullif(count(*), 0), 1),
         (count(*) filter (where c.is_conversation))::integer,
         coalesce(sum(c.talk_seconds) filter (where c.is_connected_outbound), 0)::bigint,
         round(avg(c.talk_seconds) filter (where c.is_connected_outbound), 1)
  from cma.calls_of(p_tenant_id, (select w.from_at from w), (select w.to_at from w), null, null) c
  where c.direction = 'outbound'
    and c.business_date = (select s.today from s)
$$;

-- A check row kept as four texts, for the block whose subtransaction is rolled back (its rows must outlive it)
create or replace function pg_temp.v0009i_row(p_ord integer, p_name text, p_result text, p_detail text)
returns text[] language sql immutable as $$ select array[p_ord::text, p_name, p_result, p_detail] $$;

-- The tenant's first active person (the oldest) holding a permission, as the time scripts pick it
create or replace function pg_temp.v0009i_user(p_tenant uuid, p_perm text)
returns uuid
language sql
as $$
  select u.id from cma.app_user u
  where u.tenant_id = p_tenant and u.status = 'active' and u.kind = 'person' and cma.has_permission(u.id, p_perm)
  order by u.created_at, u.id limit 1
$$;

-- One telephony call as the ingest write takes it (as 165): answered p_ring seconds after the start (null: never), ended
-- p_talk seconds after the answer (null: not ended; for a call never answered, ended after 20 seconds), on the line
-- p_number, an invented hash from the id and the current tag set (null: none sent)
create or replace function pg_temp.v0009i_call(p_src text, p_dir text, p_start timestamptz, p_ring integer, p_talk integer,
                                               p_number text, p_tags jsonb default null)
returns jsonb
language sql immutable
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'sourceId', p_src, 'direction', p_dir, 'startedAt', p_start,
    'answeredAt', p_start + make_interval(secs => p_ring),
    'endedAt', case when p_ring is null then p_start + interval '20 seconds'
                    else p_start + make_interval(secs => p_ring + p_talk) end,
    'numberRef', p_number, 'userRef', 'tu-1', 'counterpartHash', md5(p_src) || md5(p_src || 'x'), 'tags', p_tags,
    'versionAt', p_start + interval '1 hour'))
$$;

-- The function's row at an instant, and 0009h's, each as one text: date|attempts|connected|rate|conversations|talk|average
create or replace function pg_temp.v0009i_new(p_tenant uuid, p_now timestamptz)
returns text
language sql stable
as $$
  select format('%s|%s|%s|%s|%s|%s|%s', o.business_date, o.attempts, o.connected, o.connected_rate, o.conversations,
                o.outbound_talk_seconds, o.outbound_talk_avg)
  from cma.outbound_today_of(p_tenant, p_now) o
$$;
create or replace function pg_temp.v0009i_old(p_tenant uuid, p_now timestamptz)
returns text
language sql stable
as $$
  select format('%s|%s|%s|%s|%s|%s|%s', o.business_date, o.attempts, o.connected, o.connected_rate, o.conversations,
                o.outbound_talk_seconds, o.outbound_talk_avg)
  from pg_temp.outbound_today_of_0009h(p_tenant, p_now) o
$$;

-- The plan of the function's own statement for a tenant, as the caller, in the generic plan with sequential scans
-- switched off: null when cma.telephony_call is read by an index with a condition on p_column and by no sequential scan,
-- else what is wrong. The statement is the function's text with its two parameters as $1 and $2
create or replace function pg_temp.v0009i_plan(p_tenant uuid, p_column text)
returns text
language plpgsql
as $$
declare
  v_src  text;
  v_plan jsonb;
  v_bad  text := '';
begin
  select p.prosrc into v_src from pg_proc p where p.oid = 'cma.outbound_today_of(uuid,timestamptz)'::regprocedure;
  v_src := regexp_replace(regexp_replace(v_src, '\mp_tenant_id\M', '$1', 'g'), '\mp_now\M', '$2', 'g');
  if exists (select 1 from pg_prepared_statements where name = 'v0009i_p') then
    execute 'deallocate v0009i_p';
  end if;
  execute 'prepare v0009i_p(uuid, timestamptz) as ' || v_src;
  perform set_config('plan_cache_mode', 'force_generic_plan', true);
  perform set_config('enable_seqscan', 'off', true);
  execute format('explain (format json) execute v0009i_p(%L, now())', p_tenant) into v_plan;
  perform set_config('enable_seqscan', 'on', true);
  perform set_config('plan_cache_mode', 'auto', true);
  execute 'deallocate v0009i_p';
  -- like_regex takes a literal pattern, so the column's name is written into the path (a plain identifier)
  if not jsonb_path_exists(v_plan, format('$.** ? (@."Index Name" like_regex "^telephony_call_" && @."Index Cond" like_regex "%s")',
                                          regexp_replace(p_column, '[^a-z_]', '', 'g'))::jsonpath) then
    v_bad := v_bad || 'no index on cma.telephony_call with a condition on ' || p_column || '; ';
  end if;
  if jsonb_path_exists(v_plan, '$.** ? (@."Node Type" == "Seq Scan" && @."Relation Name" == "telephony_call")') then
    v_bad := v_bad || 'a sequential scan of cma.telephony_call; ';
  end if;
  return nullif(v_bad, '');
exception when others then
  perform set_config('enable_seqscan', 'on', true);
  perform set_config('plan_cache_mode', 'auto', true);
  if exists (select 1 from pg_prepared_statements where name = 'v0009i_p') then
    execute 'deallocate v0009i_p';
  end if;
  return 'error ' || sqlstate || ': ' || left(sqlerrm, 120);
end
$$;

-- The best of p_runs runs of a statement, in milliseconds; -1 when it raises
create or replace function pg_temp.v0009i_best_ms(p_sql text, p_runs integer)
returns numeric
language plpgsql
as $$
declare
  v_t0 timestamptz; v_ms numeric; v_best numeric;
begin
  for i in 1 .. greatest(1, p_runs) loop
    v_t0 := clock_timestamp();
    execute format('select count(*) from (%s) a', p_sql);
    v_ms := extract(epoch from clock_timestamp() - v_t0) * 1000;
    v_best := least(coalesce(v_best, v_ms), v_ms);
  end loop;
  return round(v_best, 1);
exception when others then
  return -1;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- S. Structure and privileges
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_fn  regprocedure := to_regprocedure('cma.outbound_today_of(uuid,timestamptz)');
  v_src text;
  v_bad text := '';
begin
  -- S1. the addition is recorded once, after 0009h
  insert into verify_0009i values (1, 'S1 addition 0009i recorded once, after 0009h',
    case when (select count(*) from cma.schema_migration where version = '0009i') = 1
              and exists (select 1 from cma.schema_migration where version = '0009h') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- S2. the function: its form, its rights, its text
  if v_fn is null then
    v_bad := 'cma.outbound_today_of(uuid,timestamptz) is missing; ';
  else
    if (select l.lanname || ':' || p.provolatile::text || ':' || p.prosecdef::text || ':' || pg_get_userbyid(p.proowner) || ':'
               || coalesce(array_to_string(p.proconfig, ','), '') || ':' || p.prorows::text
        from pg_proc p join pg_language l on l.oid = p.prolang where p.oid = v_fn) is distinct from 'sql:s:false:cma_owner:jit=off:1' then
      v_bad := v_bad || 'language, volatility, rights, owner, jit off or rows 1; ';
    end if;
    if pg_get_function_result(v_fn) is distinct from
       'TABLE(business_date date, attempts integer, connected integer, connected_rate numeric, conversations integer, outbound_talk_seconds bigint, outbound_talk_avg numeric)' then
      v_bad := v_bad || 'the columns: ' || pg_get_function_result(v_fn) || '; ';
    end if;
    if not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
       or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = v_fn and a.grantee = 0 and a.privilege_type = 'EXECUTE') then
      v_bad := v_bad || 'not the application''s only; ';
    end if;
    select p.prosrc into v_src from pg_proc p where p.oid = v_fn;
    if v_src !~ 'from cma\.telephony_call tc' then v_bad := v_bad || 'does not read cma.telephony_call; '; end if;
    if v_src !~ 'cma\.is_connected\(' then v_bad := v_bad || 'no cma.is_connected; '; end if;
    if v_src !~ 'cma\.is_conversation\(' then v_bad := v_bad || 'no cma.is_conversation; '; end if;
    if v_src !~ 'cma\.tag_meaning_excludes_conversation\(' then v_bad := v_bad || 'no cma.tag_meaning_excludes_conversation; '; end if;
    if v_src ~ 'cma\.calls_of\(' then v_bad := v_bad || 'still calls cma.calls_of; '; end if;
  end if;
  insert into verify_0009i values (2, 'S2 outbound_today_of: SQL, stable, invoker, cma_owner, jit off, rows 1, the seven columns, the application''s only; reads cma.telephony_call by the helpers, not cma.calls_of',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);
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
  v_txt text; v_old text; v_bad text; v_at timestamptz;
  v_d    timestamptz := timestamptz '2026-10-06 08:00:00+00';   -- Tuesday 6 October 2026, 10:00 in Amsterdam
  v_now  timestamptz := timestamptz '2026-10-06 12:00:00+00';   -- the fixed instant of the read: 14:00 that day
  v_shift interval := case when current_setting('verify.provoke')::boolean then interval '1 day' else interval '0' end;
  v_today date;
  v_t0   timestamptz;
  v_nr   jsonb := '[{"tagRef": "tg-nr", "name": "Not Reached"}]';
  v_off  jsonb := '[{"tagRef": "tg-nr-off", "name": "Not Reached off"}]';
  v_inc  jsonb := '[{"tagRef": "tg-inc", "name": "Incorrect Data"}]';
begin
  begin
    -- the tenant, its admin and its telephony connection (as the owner)
    v_t := cma.create_tenant('verify-0009i', 'Verify 0009i', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-admin@example.invalid', 'admin') returning id into v_admin;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, v_admin, ar.id from cma.app_role ar where ar.tenant_id = v_t and ar.key = 'admin';
    select x.user_id into v_ing from cma.app_user_external_id x where x.tenant_id = v_t and x.system = 'ingest';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t, 'verifytel', 'Verify 0009i telephony', 'tel-1', 'telephony') returning id into v_tel;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t::text, true);

    -- the catalogs from the source (the Ingest user), then the configuration (the admin): three markets in three zones,
    -- a line in each, a line that does not count, the tags' meanings, Not Reached off not counted
    perform set_config('app.user_id', v_ing::text, true);
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'number', '[{"numberRef": "n-nl", "name": "Verify NL line", "digits": "+31000000001"},
      {"numberRef": "n-us", "name": "Verify US line", "digits": "+10000000001"}, {"numberRef": "n-jp", "name": "Verify JP line", "digits": "+810000000001"},
      {"numberRef": "n-test", "name": "Verify test line", "digits": "+31000000002"}]');
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'tag', '[{"tagRef": "tg-nr", "name": "Not Reached"},
      {"tagRef": "tg-nr-off", "name": "Not Reached off"}, {"tagRef": "tg-inc", "name": "Incorrect Data"}]');
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.upsert_market('US', 'United States', 'America/New_York', 'en', 'USD');
    perform cma.upsert_market('JP', 'Japan', 'Asia/Tokyo', 'ja', 'JPY');
    perform cma.set_telephony_number(v_tel, 'n-nl', 'NL', true);
    perform cma.set_telephony_number(v_tel, 'n-us', 'US', true);
    perform cma.set_telephony_number(v_tel, 'n-jp', 'JP', true);
    perform cma.set_telephony_number(v_tel, 'n-test', 'NL', false);
    perform cma.set_telephony_tag_meaning(v_tel, 'tg-nr', 'not_reached');
    perform cma.set_telephony_tag_meaning(v_tel, 'tg-nr-off', 'not_reached');
    perform cma.set_telephony_tag_meaning(v_tel, 'tg-inc', 'incorrect_data');
    perform cma.set_telephony_tag(v_tel, 'tg-nr-off', false);

    -- 165's fixed calls (the Ingest user): five seconds of ringing, then the talk
    v_today := (now() at time zone 'Europe/Amsterdam')::date;
    v_t0 := (v_today + time '00:00:01') at time zone 'Europe/Amsterdam';
    perform set_config('app.user_id', v_ing::text, true);
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
      -- 6 October on the NL line
      pg_temp.v0009i_call('o1', 'outbound', v_d,                          5, 1,    'n-nl'),          -- connected, 1 s: no conversation
      pg_temp.v0009i_call('o2', 'outbound', v_d + interval '10 minutes', 5, null, 'n-nl'),          -- in progress: connected, no talk time yet
      pg_temp.v0009i_call('o3', 'outbound', v_d + interval '20 minutes', 5, 30,   'n-nl'),          -- a conversation at the threshold
      pg_temp.v0009i_call('o4', 'outbound', v_d + interval '30 minutes', 5, 120,  'n-nl', v_nr),    -- connected, tagged not reached
      pg_temp.v0009i_call('o5', 'outbound', v_d + interval '40 minutes', null, null, 'n-nl'),       -- an attempt, not connected
      pg_temp.v0009i_call('o6', 'outbound', v_d + interval '50 minutes', 5, 300,  'n-nl'),          -- a conversation
      -- the tag rule: incorrect data, not reached on a tag that does not count, not reached removed below
      pg_temp.v0009i_call('x1', 'outbound', v_d + interval '52 minutes', 5, 60,   'n-nl', v_inc),
      pg_temp.v0009i_call('x2', 'outbound', v_d + interval '54 minutes', 5, 60,   'n-nl', v_off),
      pg_temp.v0009i_call('x3', 'outbound', v_d + interval '56 minutes', 5, 60,   'n-nl', v_nr),
      pg_temp.v0009i_call('i1', 'inbound',  v_d + interval '60 minutes', 5, 45,   'n-nl'),          -- an inbound conversation: not outbound
      pg_temp.v0009i_call('t1', 'outbound', v_d + interval '70 minutes', 5, 60,   'n-test'),        -- a line that does not count: not stored
      -- the Tokyo line: 5 October 23:30 in Amsterdam is 6 October 06:30 there (counts for the 6th: the window's start)
      pg_temp.v0009i_call('j1', 'outbound', timestamptz '2026-10-05 21:30:00+00', 5, 60, 'n-jp'),
      -- the New York line: 7 October 01:30 in Amsterdam is 6 October 19:30 there (counts for the 6th); 6 October 03:00 in
      -- Amsterdam is 5 October 21:00 there (counts for the 5th)
      pg_temp.v0009i_call('u1', 'outbound', timestamptz '2026-10-06 23:30:00+00', 5, 60, 'n-us'),
      pg_temp.v0009i_call('u2', 'outbound', timestamptz '2026-10-06 01:00:00+00', 5, 60, 'n-us'),
      -- the day before on the NL line
      pg_temp.v0009i_call('y1', 'outbound', v_d - interval '1 day',      5, 60,   'n-nl'),
      -- the running day, for the read at now(): a conversation and an attempt not connected
      pg_temp.v0009i_call('n1', 'outbound', v_t0,                        5, 40,   'n-nl'),
      pg_temp.v0009i_call('n2', 'outbound', v_t0 + interval '1 second',  null, null, 'n-nl')));
    -- x3's Not Reached removed later: an empty tag set closes it
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
      pg_temp.v0009i_call('x3', 'outbound', v_d + interval '56 minutes', 5, 60, 'n-nl', '[]'::jsonb)
        || jsonb_build_object('versionAt', v_d + interval '5 hours')));
    perform set_config('app.user_id', v_admin::text, true);

    -- B1. the day's figures
    v_txt := pg_temp.v0009i_new(v_t, v_now);
    rows_ := rows_ || pg_temp.v0009i_row(11, 'B1 the fixed calls of 6 October: 11 attempts, 10 connected, 90.9, 5 conversations, 751 s, 83.4 on average',
      case when v_txt = '2026-10-06|11|10|90.9|5|751|83.4' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no row'));

    -- B2. the same row as 0009h's definition, at each instant and under each setting (provoked: 0009h's side a day earlier)
    v_bad := '';
    foreach v_at in array array[v_now, v_now - interval '1 day', v_now - interval '5 days', v_now + interval '1 day', now()] loop
      v_txt := pg_temp.v0009i_new(v_t, v_at);
      v_old := pg_temp.v0009i_old(v_t, v_at - v_shift);
      if v_txt is null or v_txt is distinct from v_old then
        v_bad := v_bad || format('at %s: %s against %s; ', v_at, coalesce(v_txt, 'no row'), coalesce(v_old, 'no row'));
      end if;
    end loop;
    perform cma.set_tenant_setting('telephony.connected_min_seconds', '5');
    v_txt := pg_temp.v0009i_new(v_t, v_now);
    v_old := pg_temp.v0009i_old(v_t, v_now - v_shift);
    if v_txt is distinct from v_old or v_txt is distinct from '2026-10-06|11|8|72.7|5|750|93.8' then
      v_bad := v_bad || format('connected from 5 s: %s against %s; ', coalesce(v_txt, 'no row'), coalesce(v_old, 'no row'));
    end if;
    perform cma.set_tenant_setting('telephony.connected_min_seconds', null);
    perform cma.set_tenant_setting('calls.conversation_min_talk_seconds', '31');
    v_txt := pg_temp.v0009i_new(v_t, v_now);
    v_old := pg_temp.v0009i_old(v_t, v_now - v_shift);
    if v_txt is distinct from v_old or v_txt is distinct from '2026-10-06|11|10|90.9|4|751|83.4' then
      v_bad := v_bad || format('threshold 31: %s against %s; ', coalesce(v_txt, 'no row'), coalesce(v_old, 'no row'));
    end if;
    perform cma.set_tenant_setting('calls.conversation_min_talk_seconds', null);
    rows_ := rows_ || pg_temp.v0009i_row(12, 'B2 the same row as 0009h''s definition at five instants and under both settings (connected from 5 s: 8 connected, 72.7, 750 s, 93.8; threshold 31: 4 conversations)',
      case when v_bad = '' then 'PASS' else 'FAIL' end, case when v_bad = '' then 'seven comparisons, the same' else left(v_bad, 400) end);

    -- B3. the plan: an index on started_at, no sequential scan of the calls (provoked: an index on a column none has)
    v_txt := pg_temp.v0009i_plan(v_t, case when v_provoke then 'no_such_column' else 'started_at' end);
    rows_ := rows_ || pg_temp.v0009i_row(13, 'B3 the generic plan as the application reads cma.telephony_call by an index on started_at, never sequentially',
      case when v_txt is null then 'PASS' else 'FAIL' end, coalesce(v_txt, 'an index with a condition on started_at'));

    raise exception using errcode = 'CMAOK';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      rows_ := rows_ || pg_temp.v0009i_row(99, 'B block ended early', 'FAIL', 'error ' || sqlstate || ': ' || left(sqlerrm, 160));
  end;
  perform set_config('role', 'cma_owner', true);
  perform set_config('app.tenant_id', '', true);
  perform set_config('app.user_id', '', true);
  insert into verify_0009i (ord, check_name, result, detail)
  select rows_[4 * i - 3]::integer, rows_[4 * i - 2], rows_[4 * i - 1], rows_[4 * i] from generate_series(1, cardinality(rows_) / 4) i;
  -- a block that ended early counts the checks it did not reach as FAIL
  insert into verify_0009i (ord, check_name, result, detail)
  select o, 'B' || (o - 10) || ' not reached', 'FAIL', 'the block ended before this check'
  from generate_series(11, 13) o
  where not exists (select 1 from verify_0009i v where v.ord = o);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- E. Per active tenant, on the database this runs in, as the application
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_runs  integer := current_setting('verify.timing_runs')::integer;
  v_slack numeric := current_setting('verify.slack_ms')::numeric;
  v_shift interval := case when current_setting('verify.provoke')::boolean then interval '1 day' else interval '0' end;
  t record;
  v_user uuid; v_ord integer := 100; v_a text; v_b text; v_new numeric; v_old numeric;
begin
  for t in select x.id, x.slug from cma.tenant x where x.status = 'active' order by x.slug collate "C" loop
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.tenant_id', t.id::text, true);
    perform set_config('app.user_id', '', true);
    v_user := pg_temp.v0009i_user(t.id, 'monitoring.live');
    if v_user is null then
      v_ord := v_ord + 1;
      insert into verify_0009i values (v_ord, 'E1-E3 ' || t.slug, 'skip', 'no active person holds monitoring.live: nothing compared or timed');
      continue;
    end if;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_user::text, true);

    -- E1. the live day: the same row as 0009h's definition (provoked: 0009h's side a day earlier, and the switch, since a
    --     tenant without outbound calls answers the same zeros on both days but for the date)
    v_ord := v_ord + 1;
    begin
      v_a := pg_temp.v0009i_new(t.id, now());
      v_b := pg_temp.v0009i_old(t.id, now() - v_shift);
      insert into verify_0009i values (v_ord, 'E1 outbound today: the same row as 0009h''s definition for the live day (' || t.slug || ')',
        case when v_a is not null and v_a = v_b and not v_provoke then 'PASS' else 'FAIL' end,
        case when v_a = v_b then 'the same seven figures' else 'the rows differ (date|attempts|connected|rate|conversations|talk|average)' end);
    exception when others then
      insert into verify_0009i values (v_ord, 'E1 outbound today (' || t.slug || ')', 'FAIL', 'error ' || sqlstate || ': ' || left(sqlerrm, 120));
    end;

    -- E3 before E2 (the plan check changes planner settings and puts them back): no slower than 0009h's definition
    v_old := pg_temp.v0009i_best_ms(format('select * from pg_temp.outbound_today_of_0009h(%L, now())', t.id), v_runs);
    v_new := pg_temp.v0009i_best_ms(format('select * from cma.outbound_today_of(%L, now())', t.id), v_runs);

    -- E2. the plan on the tenant's own data
    v_ord := v_ord + 1;
    v_a := pg_temp.v0009i_plan(t.id, case when v_provoke then 'no_such_column' else 'started_at' end);
    insert into verify_0009i values (v_ord, 'E2 the generic plan as the application reads cma.telephony_call by an index on started_at, never sequentially (' || t.slug || ')',
      case when v_a is null then 'PASS' else 'FAIL' end, coalesce(v_a, 'an index with a condition on started_at'));

    v_ord := v_ord + 1;
    insert into verify_0009i values (v_ord, 'E3 no slower than 0009h''s definition, as the application (' || t.slug || ')',
      case when v_old >= 0 and v_new >= 0 and v_new <= v_old + v_slack and not v_provoke then 'PASS' else 'FAIL' end,
      case when v_old < 0 or v_new < 0 then 'a read raised an error'
           else format('direct %s ms against through cma.calls_of %s ms (best of %s each, %s ms of slack)', v_new, v_old, v_runs, v_slack) end);
  end loop;
  perform set_config('role', 'cma_owner', true);
end
$$;

drop function if exists pg_temp.v0009i_best_ms(text, integer);
drop function if exists pg_temp.v0009i_plan(uuid, text);
drop function if exists pg_temp.v0009i_old(uuid, timestamptz);
drop function if exists pg_temp.v0009i_new(uuid, timestamptz);
drop function if exists pg_temp.v0009i_call(text, text, timestamptz, integer, integer, text, jsonb);
drop function if exists pg_temp.v0009i_user(uuid, text);
drop function if exists pg_temp.v0009i_row(integer, text, text, text);
drop function if exists pg_temp.outbound_today_of_0009h(uuid, timestamptz);

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0009i
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0009i where result = 'FAIL') then 'FAIL'
                  when not exists (select 1 from pg_temp.verify_0009i where result = 'PASS') then 'FAIL'
                  else 'PASS' end,
             format('167_verify_live_outbound_direct: %s PASS, %s FAIL, %s skip', (select count(*) from pg_temp.verify_0009i where result = 'PASS'),
                    (select count(*) from pg_temp.verify_0009i where result = 'FAIL'), (select count(*) from pg_temp.verify_0009i where result = 'skip'))) x
order by ord;
drop table if exists pg_temp.verify_0009i;
reset role;
