-- =============================================================================================
-- 165_verify_live_outbound.sql: verifies addition 0009h, the Live board's Outbound today and cma.inbound_now() with
-- Longest waiting always null
-- =============================================================================================
-- Universal: no seed is assumed. Block S checks the addition, the functions and the grants. Block B works on a throwaway
-- tenant inside a subtransaction that is always rolled back, so nothing stays: synthetic people (example.invalid) and
-- fixed test calls on Tuesday 6 October 2026 (Europe/Amsterdam, with a line in America/New_York, west of the tenant, a
-- line in Asia/Tokyo, east of it, and a line that does not count), read at a fixed instant (cma.outbound_today_of's p_now), so the verdict never depends on the time it
-- runs; cma.outbound_now() and cma.inbound_now(), which read now(), get three calls of the running day. Block E compares,
-- per active tenant on the database it runs in and as the application acting as the tenant's first person holding
-- monitoring.live, today's outbound figures with Reports → Calls' (cma.calls_figures_of) and cma.inbound_now() with
-- 0008zx's definition (144, kept here verbatim as a temporary function), and times the two polls. Every check writes
-- one row, PASS, FAIL or skip, and the last row is the verdict, because Cloud SQL Studio shows no notices. Run as your
-- own IAM login after 164_live_outbound.sql; then 133_verify_perf.sql and 145_verify_held_kinds_restore.sql again (they
-- read cma.inbound_now(); 145 is edited by this change). Expected verdict: "PASS | 165_verify_live_outbound: <n> PASS,
-- 0 FAIL, <k> skip" (a skip is an active tenant without a person holding monitoring.live); provoked (verify.provoke
-- true below): every check reads FAIL and the verdict "PROVOKED, NOT A PASS".
-- Edited by addition 0009j (168_live_inbound_talk.sql): cma.inbound_now()'s today holds inbound_talk_seconds, a key
-- 0008zx never had, so B7 and E1 take it out of the new answer before comparing, and B7 lists it among today's keys
-- (sixteen); 169 proves the key itself. Run after 168 there.
--   S1  the addition 0009h is recorded once, after 0009g
--   S2  cma.outbound_today_of(uuid, timestamptz) and cma.outbound_now(): SQL, stable, the caller's rights, owned by
--       cma_owner, jit off, executable by the application only; outbound_today_of's seven columns; cma.inbound_now():
--       plpgsql, stable, jsonb, the application's only, its text setting today's longest_waiting_seconds to null
--   B1  the fixed calls of 6 October: 8 attempts (an unanswered one, one in progress, one on the New York line that
--       started on 7 October in Amsterdam, one on the Tokyo line that started on 5 October in Amsterdam: both ends of
--       the window), 7 connected, 87.5, 4 conversations (not under the talk threshold, not with a tag meaning
--       not_reached, not the inbound one), 571 s of talk, 95.2 on average; the day before and the New York line's call
--       of 5 October (6 October in Amsterdam) are left out; so is the call sent on the line that does not count, which
--       the ingest write does not store (0008f), so it proves the write's rule here, not the read's
--   B2  the same as cma.calls_figures_of for that day where both define them: outbound, connected, connected_rate,
--       outbound_talk_seconds, outbound_talk_avg
--   B3  the conversations equal the count of the day's outbound calls that cma.is_conversation calls one, computed here
--       from the stored calls
--   B4  the settings move the figures as they move the report's: telephony.connected_min_seconds 5 (5 connected, 62.5,
--       570 s, 114.0), calls.conversation_min_talk_seconds 31 (3 conversations); B2 and B3 hold under each
--   B5  another day and a day without a call: 5 October counts its two calls; 1 October answers 0 attempts, no rate
--       (null, the tile's dash), 0 conversations, 0 s, no average
--   B6  cma.outbound_now(): an agent is refused (CMA06); a supervisor reads the seven keys, equal to
--       cma.outbound_today_of at now(), with the running day's calls counted (2 attempts, 1 connected, 50.0, 1
--       conversation, 40 s, 40.0)
--   B7  cma.inbound_now() on the throwaway tenant, with a call waiting: the same JSON as 0008zx's definition once
--       longest_waiting_seconds is set to null in its today; 0008zx's today holds a number there and the new one null
--       (the key is kept for one release, for main's web); the keys of today are the fifteen it had and, since 0009j,
--       inbound_talk_seconds, which the comparison takes out of the new answer
--   E1  per active tenant: cma.inbound_now() without inbound_talk_seconds the same as 0008zx's with the key set to null
--   E2  per active tenant: today's outbound figures the same as cma.calls_figures_of for the tenant's date
--   E3  per active tenant: cma.outbound_now() no slower than cma.inbound_now(): the best of verify.timing_runs runs
--       each, at most inbound's best plus verify.slack_ms. This is the brief's comparison, not the poll's budget:
--       131_time_all.sql part a holds that (the rows 'outbound now' and 'live board calls (one statement)', 20 ms)
-- Provoke: set provoke below to true; every check must then read FAIL, and the verdict says PROVOKED, NOT A PASS. The
-- comparisons are provoked by a deliberate difference, not by the switch alone: B7 and E1 then compare with 0008zx's
-- JSON with longest_waiting_seconds taken out (the new answer holds the key), B2 with the report's figures of the day
-- before.
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
select set_config('verify.timing_runs', '8', false);                 -- runs per poll in E3 (the seventh call of a session included)
select set_config('verify.slack_ms', '5', false);                    -- E3: what outbound may take above inbound's best

drop table if exists pg_temp.verify_0009h;
create temporary table verify_0009h (ord integer, check_name text, result text, detail text);
-- block E writes its rows while acting as the application
grant select, insert on pg_temp.verify_0009h to cma_app;

-- cma.inbound_now() as 0008zx (144) defined it, verbatim; the functions it calls are not changed by 164
create function pg_temp.inbound_now_0008zx()
returns jsonb
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_list   jsonb;
begin
  perform cma.assert_permission('monitoring.live');
  select coalesce(jsonb_agg(to_jsonb(m) || jsonb_build_object('record_url', cma.record_url(m.connection_id, 'call', m.source_id)) order by m.started_at, m.source_id), '[]'::jsonb)
    into v_list
  from cma.missed_callbacks_of(v_tenant) m;
  return jsonb_build_object(
    'today', (select to_jsonb(x) from cma.inbound_today_of(v_tenant) x),
    'callbacks', v_list,
    'summary', (select jsonb_build_object('listed', jsonb_array_length(v_list),
                                          'anonymous_count', cma.anonymous_missed_calls_of(v_tenant, now() - make_interval(days => s.lookback)),
                                          'lookback_days', s.lookback)
                from (select greatest(0, cma.setting_of(t.id, 'telephony.callback_lookback_days')::integer) as lookback
                      from cma.tenant t where t.id = v_tenant) s));
end
$$;

-- A check row kept as four texts, for the block whose subtransaction is rolled back (its rows must outlive it)
create or replace function pg_temp.v0009h_row(p_ord integer, p_name text, p_result text, p_detail text)
returns text[] language sql immutable as $$ select array[p_ord::text, p_name, p_result, p_detail] $$;

-- The tenant's first active person (the oldest) holding a permission, as the time scripts pick it
create or replace function pg_temp.v0009h_user(p_tenant uuid, p_perm text)
returns uuid
language sql
as $$
  select u.id from cma.app_user u
  where u.tenant_id = p_tenant and u.status = 'active' and u.kind = 'person' and cma.has_permission(u.id, p_perm)
  order by u.created_at, u.id limit 1
$$;

-- One telephony call as the ingest write takes it (as 153): answered p_ring seconds after the start (null: never), ended
-- p_talk seconds after the answer (null: not ended; for a call never answered, ended after 20 seconds unless p_open), on
-- the line p_number, an invented hash from the id and the current tag set (null: none sent)
create or replace function pg_temp.v0009h_call(p_src text, p_dir text, p_start timestamptz, p_ring integer, p_talk integer,
                                               p_number text, p_tags jsonb default null, p_open boolean default false)
returns jsonb
language sql immutable
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'sourceId', p_src, 'direction', p_dir, 'startedAt', p_start,
    'answeredAt', p_start + make_interval(secs => p_ring),
    'endedAt', case when p_open then null
                    when p_ring is null then p_start + interval '20 seconds'
                    else p_start + make_interval(secs => p_ring + p_talk) end,
    'numberRef', p_number, 'userRef', 'tu-1', 'counterpartHash', md5(p_src) || md5(p_src || 'x'), 'tags', p_tags,
    'versionAt', p_start + interval '1 hour'))
$$;

-- Outbound today at an instant, as one text: date|attempts|connected|rate|conversations|talk|average (a null is empty)
create or replace function pg_temp.v0009h_fig(p_tenant uuid, p_now timestamptz)
returns text
language sql stable
as $$
  select format('%s|%s|%s|%s|%s|%s|%s', o.business_date, o.attempts, o.connected, o.connected_rate, o.conversations,
                o.outbound_talk_seconds, o.outbound_talk_avg)
  from cma.outbound_today_of(p_tenant, p_now) o
$$;

-- The five figures Reports → Calls defines too, of outbound today at an instant and of cma.calls_figures_of's total for
-- a date: outbound|connected|rate|talk|average
create or replace function pg_temp.v0009h_shared(p_tenant uuid, p_now timestamptz)
returns text
language sql stable
as $$
  select format('%s|%s|%s|%s|%s', o.attempts, o.connected, o.connected_rate, o.outbound_talk_seconds, o.outbound_talk_avg)
  from cma.outbound_today_of(p_tenant, p_now) o
$$;
create or replace function pg_temp.v0009h_report(p_tenant uuid, p_date date)
returns text
language sql stable
as $$
  select format('%s|%s|%s|%s|%s', f.outbound, f.connected, f.connected_rate, f.outbound_talk_seconds, f.outbound_talk_avg)
  from cma.calls_figures_of(p_tenant, p_date, p_date, null, null, 'day') f
  where f.group_key is null
$$;

-- The outbound calls of a date (each call's date in its line's zone, counted lines only) that cma.is_conversation calls
-- a conversation, from the stored calls and the tenant's settings: not through cma.calls_of
create or replace function pg_temp.v0009h_conversations(p_tenant uuid, p_date date)
returns integer
language sql stable
as $$
  select count(*)::integer
  from cma.telephony_call tc
  join cma.tenant t on t.id = tc.tenant_id
  left join cma.telephony_number n on n.tenant_id = tc.tenant_id and n.connection_id = tc.connection_id and n.number_ref = tc.number_ref
  left join cma.market m on m.tenant_id = tc.tenant_id and m.code = n.market
  where tc.tenant_id = p_tenant and tc.source_deleted_at is null and tc.started_at is not null and coalesce(n.is_counted, true)
    and tc.direction = 'outbound'
    and (tc.started_at at time zone coalesce(m.time_zone, t.timezone))::date = p_date
    and cma.is_conversation(tc.direction, tc.answered_at is not null, tc.talk_seconds,
                            greatest(0, cma.setting_of(p_tenant, 'telephony.connected_min_seconds')::integer),
                            greatest(0, cma.setting_of(p_tenant, 'calls.conversation_min_talk_seconds')::integer),
                            (select x.not_reached from cma.call_not_reached_of(p_tenant, tc.connection_id, tc.source_id) x))
$$;

-- The best of p_runs runs of a statement, in milliseconds; -1 when it raises
create or replace function pg_temp.v0009h_best_ms(p_sql text, p_runs integer)
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
  v_fn  regprocedure;
  v_sig text;
  v_bad text := '';
begin
  -- S1. the addition is recorded once, after 0009g
  insert into verify_0009h values (1, 'S1 addition 0009h recorded once, after 0009g',
    case when (select count(*) from cma.schema_migration where version = '0009h') = 1
              and exists (select 1 from cma.schema_migration where version = '0009g') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- S2. the two new functions and cma.inbound_now()
  foreach v_sig in array array['cma.outbound_today_of(uuid,timestamptz)', 'cma.outbound_now()', 'cma.inbound_now()'] loop
    v_fn := to_regprocedure(v_sig);
    if v_fn is null then
      v_bad := v_bad || v_sig || ' is missing; ';
      continue;
    end if;
    if (select l.lanname || ':' || p.provolatile::text || ':' || p.prosecdef::text || ':' || pg_get_userbyid(p.proowner) || ':' || coalesce(array_to_string(p.proconfig, ','), '')
        from pg_proc p join pg_language l on l.oid = p.prolang where p.oid = v_fn)
       is distinct from (case when v_sig = 'cma.inbound_now()' then 'plpgsql:s:false:cma_owner:' else 'sql:s:false:cma_owner:jit=off' end) then
      v_bad := v_bad || v_sig || ': language, volatility, rights, owner or jit; ';
    end if;
    if not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
       or exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = v_fn and a.grantee = 0 and a.privilege_type = 'EXECUTE') then
      v_bad := v_bad || v_sig || ': not the application''s only; ';
    end if;
  end loop;
  if to_regprocedure('cma.outbound_today_of(uuid,timestamptz)') is not null
     and pg_get_function_result('cma.outbound_today_of(uuid,timestamptz)'::regprocedure) is distinct from
         'TABLE(business_date date, attempts integer, connected integer, connected_rate numeric, conversations integer, outbound_talk_seconds bigint, outbound_talk_avg numeric)' then
    v_bad := v_bad || 'outbound_today_of''s columns: ' || pg_get_function_result('cma.outbound_today_of(uuid,timestamptz)'::regprocedure) || '; ';
  end if;
  if to_regprocedure('cma.outbound_now()') is not null and pg_get_function_result('cma.outbound_now()'::regprocedure) <> 'jsonb' then
    v_bad := v_bad || 'outbound_now''s result; ';
  end if;
  if to_regprocedure('cma.inbound_now()') is not null
     and (pg_get_function_result('cma.inbound_now()'::regprocedure) <> 'jsonb'
          or (select p.prosrc from pg_proc p where p.oid = 'cma.inbound_now()'::regprocedure) !~ 'to_jsonb\(x\) \|\| ''\{"longest_waiting_seconds": null\}''::jsonb') then
    v_bad := v_bad || 'inbound_now''s result, or its text does not set longest_waiting_seconds to null; ';
  end if;
  insert into verify_0009h values (2, 'S2 outbound_today_of and outbound_now: SQL, stable, invoker, cma_owner, jit off; inbound_now with the key null; the application''s only',
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
  v_t uuid; v_admin uuid; v_sup uuid; v_agent uuid; v_ing uuid; v_tel uuid;
  v_txt text; v_bad text; v_err text;
  j jsonb; j_old jsonb;
  v_d    timestamptz := timestamptz '2026-10-06 08:00:00+00';   -- Tuesday 6 October 2026, 10:00 in Amsterdam
  v_now  timestamptz := timestamptz '2026-10-06 12:00:00+00';   -- the fixed instant of the read: 14:00 that day
  v_day  date := date '2026-10-06';
  v_today date;
  v_t0   timestamptz;
  v_nr   jsonb := '[{"tagRef": "tg-nr", "name": "Not Reached"}]';
begin
  begin
    -- the tenant, its people and its telephony connection (as the owner)
    v_t := cma.create_tenant('verify-0009h', 'Verify 0009h', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-admin@example.invalid', 'admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-sup@example.invalid', 'sup') returning id into v_sup;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-agent@example.invalid', 'agent') returning id into v_agent;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.user_id, ar.id
    from (values (v_admin, 'admin'), (v_sup, 'supervisor'), (v_agent, 'agent')) as x(user_id, role_key)
    join cma.app_role ar on ar.tenant_id = v_t and ar.key = x.role_key;
    select x.user_id into v_ing from cma.app_user_external_id x where x.tenant_id = v_t and x.system = 'ingest';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t, 'verifytel', 'Verify 0009h telephony', 'tel-1', 'telephony') returning id into v_tel;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t::text, true);

    -- the catalogs from the source (the Ingest user), then the configuration (the admin): two markets in two zones, a
    -- line in each, a line that does not count, the tag's meaning
    perform set_config('app.user_id', v_ing::text, true);
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'number', '[{"numberRef": "n-nl", "name": "Verify NL line", "digits": "+31000000001"},
      {"numberRef": "n-us", "name": "Verify US line", "digits": "+10000000001"}, {"numberRef": "n-jp", "name": "Verify JP line", "digits": "+810000000001"}, {"numberRef": "n-test", "name": "Verify test line", "digits": "+31000000002"}]');
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'tag', '[{"tagRef": "tg-nr", "name": "Not Reached"}]');
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.upsert_market('US', 'United States', 'America/New_York', 'en', 'USD');
    perform cma.set_telephony_number(v_tel, 'n-nl', 'NL', true);
    perform cma.set_telephony_number(v_tel, 'n-us', 'US', true);
    perform cma.upsert_market('JP', 'Japan', 'Asia/Tokyo', 'ja', 'JPY');
    perform cma.set_telephony_number(v_tel, 'n-jp', 'JP', true);
    perform cma.set_telephony_number(v_tel, 'n-test', 'NL', false);
    perform cma.set_telephony_tag_meaning(v_tel, 'tg-nr', 'not_reached');

    -- the fixed calls (the Ingest user): five seconds of ringing, then the talk
    v_today := (now() at time zone 'Europe/Amsterdam')::date;
    v_t0 := (v_today + time '00:00:01') at time zone 'Europe/Amsterdam';
    perform set_config('app.user_id', v_ing::text, true);
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
      -- 6 October on the NL line
      pg_temp.v0009h_call('o1', 'outbound', v_d,                          5, 1,    'n-nl'),          -- connected, 1 s: no conversation
      pg_temp.v0009h_call('o2', 'outbound', v_d + interval '10 minutes', 5, null, 'n-nl'),          -- in progress: connected, no talk time yet
      pg_temp.v0009h_call('o3', 'outbound', v_d + interval '20 minutes', 5, 30,   'n-nl'),          -- a conversation at the threshold
      pg_temp.v0009h_call('o4', 'outbound', v_d + interval '30 minutes', 5, 120,  'n-nl', v_nr),    -- connected, tagged not reached
      pg_temp.v0009h_call('o5', 'outbound', v_d + interval '40 minutes', null, null, 'n-nl'),       -- an attempt, not connected
      pg_temp.v0009h_call('o6', 'outbound', v_d + interval '50 minutes', 5, 300,  'n-nl'),          -- a conversation
      pg_temp.v0009h_call('i1', 'inbound',  v_d + interval '60 minutes', 5, 45,   'n-nl'),          -- an inbound conversation: not outbound
      pg_temp.v0009h_call('t1', 'outbound', v_d + interval '70 minutes', 5, 60,   'n-test'),        -- a line that does not count: not stored
      -- the Tokyo line: 5 October 23:30 in Amsterdam is 6 October 06:30 there (counts for the 6th: the window's start)
      pg_temp.v0009h_call('j1', 'outbound', timestamptz '2026-10-05 21:30:00+00', 5, 60, 'n-jp'),
      -- the New York line: 7 October 01:30 in Amsterdam is 6 October 19:30 there (counts for the 6th); 6 October 03:00 in
      -- Amsterdam is 5 October 21:00 there (counts for the 5th)
      pg_temp.v0009h_call('u1', 'outbound', timestamptz '2026-10-06 23:30:00+00', 5, 60, 'n-us'),
      pg_temp.v0009h_call('u2', 'outbound', timestamptz '2026-10-06 01:00:00+00', 5, 60, 'n-us'),
      -- the day before on the NL line
      pg_temp.v0009h_call('y1', 'outbound', v_d - interval '1 day',      5, 60,   'n-nl'),
      -- the running day, for the reads at now(): a conversation, an attempt not connected, an inbound call still waiting
      pg_temp.v0009h_call('n1', 'outbound', v_t0,                        5, 40,   'n-nl'),
      pg_temp.v0009h_call('n2', 'outbound', v_t0 + interval '1 second',  null, null, 'n-nl'),
      pg_temp.v0009h_call('w1', 'inbound',  now() - interval '1 minute', null, null, 'n-nl', null, true)));
    perform set_config('app.user_id', v_admin::text, true);

    -- B1. the day's figures
    v_txt := pg_temp.v0009h_fig(v_t, v_now);
    rows_ := rows_ || pg_temp.v0009h_row(11, 'B1 the fixed calls of 6 October: 8 attempts, 7 connected, 87.5, 4 conversations, 571 s, 95.2 on average',
      case when v_txt = '2026-10-06|8|7|87.5|4|571|95.2' and not v_provoke then 'PASS' else 'FAIL' end, coalesce(v_txt, 'no row'));

    -- B2. the same as Reports → Calls where both define them
    v_txt := pg_temp.v0009h_shared(v_t, v_now);
    rows_ := rows_ || pg_temp.v0009h_row(12, 'B2 outbound, connected, connected rate and outbound talk the same as cma.calls_figures_of for the day',
      case when v_txt is not null and v_txt = pg_temp.v0009h_report(v_t, case when v_provoke then v_day - 1 else v_day end) then 'PASS' else 'FAIL' end,
      format('%s against %s', coalesce(v_txt, 'no row'), coalesce(pg_temp.v0009h_report(v_t, case when v_provoke then v_day - 1 else v_day end), 'no row')));

    -- B3. the conversations are the outbound calls cma.is_conversation calls one
    select o.conversations::text into v_txt from cma.outbound_today_of(v_t, v_now) o;
    rows_ := rows_ || pg_temp.v0009h_row(13, 'B3 the conversations equal the count of the day''s outbound calls that are a Conversation by cma.is_conversation',
      case when v_txt = '4' and v_txt = pg_temp.v0009h_conversations(v_t, v_day)::text and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s against %s', coalesce(v_txt, 'no row'), pg_temp.v0009h_conversations(v_t, v_day)));

    -- B4. the settings move the figures, and B2 and B3 hold under each
    v_bad := '';
    perform cma.set_tenant_setting('telephony.connected_min_seconds', '5');
    v_txt := pg_temp.v0009h_fig(v_t, v_now);
    if v_txt is distinct from '2026-10-06|8|5|62.5|4|570|114.0' then v_bad := v_bad || 'connected from 5 s: ' || coalesce(v_txt, 'no row') || '; '; end if;
    if pg_temp.v0009h_shared(v_t, v_now) is distinct from pg_temp.v0009h_report(v_t, v_day) then v_bad := v_bad || 'connected from 5 s: not the report''s; '; end if;
    if (select o.conversations from cma.outbound_today_of(v_t, v_now) o) is distinct from pg_temp.v0009h_conversations(v_t, v_day) then
      v_bad := v_bad || 'connected from 5 s: not is_conversation''s count; ';
    end if;
    perform cma.set_tenant_setting('telephony.connected_min_seconds', null);
    perform cma.set_tenant_setting('calls.conversation_min_talk_seconds', '31');
    v_txt := pg_temp.v0009h_fig(v_t, v_now);
    if v_txt is distinct from '2026-10-06|8|7|87.5|3|571|95.2' then v_bad := v_bad || 'threshold 31: ' || coalesce(v_txt, 'no row') || '; '; end if;
    if pg_temp.v0009h_shared(v_t, v_now) is distinct from pg_temp.v0009h_report(v_t, v_day) then v_bad := v_bad || 'threshold 31: not the report''s; '; end if;
    if (select o.conversations from cma.outbound_today_of(v_t, v_now) o) is distinct from pg_temp.v0009h_conversations(v_t, v_day) then
      v_bad := v_bad || 'threshold 31: not is_conversation''s count; ';
    end if;
    perform cma.set_tenant_setting('calls.conversation_min_talk_seconds', null);
    rows_ := rows_ || pg_temp.v0009h_row(14, 'B4 connected from 5 s: 5 connected, 62.5, 570 s, 114.0; the Conversation threshold at 31 s: 3; the report''s and is_conversation''s under each',
      case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

    -- B5. another day, and a day without a call
    v_bad := '';
    v_txt := pg_temp.v0009h_fig(v_t, v_now - interval '1 day');
    if v_txt is distinct from '2026-10-05|2|2|100.0|2|120|60.0' then v_bad := v_bad || '5 October: ' || coalesce(v_txt, 'no row') || '; '; end if;
    if pg_temp.v0009h_shared(v_t, v_now - interval '1 day') is distinct from pg_temp.v0009h_report(v_t, v_day - 1) then v_bad := v_bad || '5 October: not the report''s; '; end if;
    v_txt := pg_temp.v0009h_fig(v_t, v_now - interval '5 days');
    if v_txt is distinct from '2026-10-01|0|0||0|0|' then v_bad := v_bad || '1 October: ' || coalesce(v_txt, 'no row') || '; '; end if;
    if pg_temp.v0009h_shared(v_t, v_now - interval '5 days') is distinct from pg_temp.v0009h_report(v_t, v_day - 5) then v_bad := v_bad || '1 October: not the report''s; '; end if;
    rows_ := rows_ || pg_temp.v0009h_row(15, 'B5 5 October counts its two calls; a day without a call: 0 attempts, no rate, 0 conversations, 0 s, no average',
      case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);

    -- B6. cma.outbound_now(): the permission, the keys, the running day
    v_bad := '';
    perform set_config('app.user_id', v_agent::text, true);
    v_err := 'no error';
    begin
      perform cma.outbound_now();
    exception when others then
      v_err := sqlstate;
    end;
    if v_err <> 'CMA06' then v_bad := v_bad || 'an agent got ' || v_err || '; '; end if;
    perform set_config('app.user_id', v_sup::text, true);
    j := cma.outbound_now();
    if (select array_agg(k order by k collate "C") from jsonb_object_keys(j) k) is distinct from
       array['attempts', 'business_date', 'connected', 'connected_rate', 'conversations', 'outbound_talk_avg', 'outbound_talk_seconds'] then
      v_bad := v_bad || 'the keys: ' || (select string_agg(k, ',' order by k) from jsonb_object_keys(j) k) || '; ';
    end if;
    if j is distinct from (select to_jsonb(o) from cma.outbound_today_of(v_t, now()) o) then v_bad := v_bad || 'not outbound_today_of at now(); '; end if;
    v_txt := format('%s|%s|%s|%s|%s|%s|%s', j ->> 'business_date', j ->> 'attempts', j ->> 'connected', j ->> 'connected_rate', j ->> 'conversations',
                    j ->> 'outbound_talk_seconds', j ->> 'outbound_talk_avg');
    if v_txt is distinct from format('%s|2|1|50.0|1|40|40.0', v_today) then v_bad := v_bad || 'the running day: ' || v_txt || '; '; end if;
    rows_ := rows_ || pg_temp.v0009h_row(16, 'B6 outbound_now(): an agent refused (CMA06); a supervisor reads the seven keys, outbound_today_of at now(), the running day''s calls',
      case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, case when v_bad = '' then v_txt else v_bad end);

    -- B7. cma.inbound_now(): 0008zx's answer with the one key null
    v_bad := '';
    j := cma.inbound_now();
    j_old := pg_temp.inbound_now_0008zx();
    -- provoked: the key taken out of 0008zx's answer, which the comparison must then report (the new answer holds it)
    if (j #- '{today,inbound_talk_seconds}') is distinct from (case when v_provoke then j_old #- '{today,longest_waiting_seconds}' else jsonb_set(j_old, '{today,longest_waiting_seconds}', 'null') end) then v_bad := v_bad || 'not 0008zx''s JSON with the key null; '; end if;
    if (j -> 'today' -> 'longest_waiting_seconds') is distinct from 'null'::jsonb then v_bad := v_bad || 'today''s longest_waiting_seconds is not a null key; '; end if;
    if jsonb_typeof(j_old -> 'today' -> 'longest_waiting_seconds') is distinct from 'number' then v_bad := v_bad || '0008zx''s today holds no longest wait: nothing proven; '; end if;
    if (select array_agg(k order by k collate "C") from jsonb_object_keys(j -> 'today') k) is distinct from
       array['answered', 'answered_within_target', 'avg_answer_seconds', 'business_date', 'inbound_talk_seconds', 'longest_waiting_seconds', 'offered', 'p80_answer_seconds',
             'service_level_base', 'service_level_pct', 'service_level_seconds', 'unanswered', 'unanswered_by_reason', 'waiting', 'waiting_max_minutes', 'waiting_now'] then
      v_bad := v_bad || 'today''s keys: ' || (select string_agg(k, ',' order by k) from jsonb_object_keys(j -> 'today') k) || '; ';
    end if;
    if (j -> 'today' ->> 'waiting_now') is distinct from '1' then v_bad := v_bad || 'waiting now is ' || coalesce(j -> 'today' ->> 'waiting_now', 'null') || '; '; end if;
    rows_ := rows_ || pg_temp.v0009h_row(17, 'B7 inbound_now(): 0008zx''s JSON with longest_waiting_seconds null; the sixteen keys of today (inbound_talk_seconds since 0009j), one call waiting',
      case when v_bad = '' then 'PASS' else 'FAIL' end, v_bad);

    raise exception using errcode = 'CMAOK';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      rows_ := rows_ || pg_temp.v0009h_row(99, 'B block ended early', 'FAIL', 'error ' || sqlstate || ': ' || left(sqlerrm, 160));
  end;
  perform set_config('role', 'cma_owner', true);
  perform set_config('app.tenant_id', '', true);
  perform set_config('app.user_id', '', true);
  insert into verify_0009h (ord, check_name, result, detail)
  select rows_[4 * i - 3]::integer, rows_[4 * i - 2], rows_[4 * i - 1], rows_[4 * i] from generate_series(1, cardinality(rows_) / 4) i;
  -- a block that ended early counts the checks it did not reach as FAIL
  insert into verify_0009h (ord, check_name, result, detail)
  select o, 'B' || (o - 10) || ' not reached', 'FAIL', 'the block ended before this check'
  from generate_series(11, 17) o
  where not exists (select 1 from verify_0009h v where v.ord = o);
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
  t record;
  v_user uuid; v_ord integer := 100; v_a text; v_b text; v_in numeric; v_out numeric; v_same boolean;
begin
  for t in select x.id, x.slug from cma.tenant x where x.status = 'active' order by x.slug collate "C" loop
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.tenant_id', t.id::text, true);
    perform set_config('app.user_id', '', true);
    v_user := pg_temp.v0009h_user(t.id, 'monitoring.live');
    if v_user is null then
      v_ord := v_ord + 1;
      insert into verify_0009h values (v_ord, 'E1-E3 ' || t.slug, 'skip', 'no active person holds monitoring.live: nothing compared or timed');
      continue;
    end if;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_user::text, true);

    -- E1. inbound now: 0008zx's answer with the key null
    v_ord := v_ord + 1;
    begin
      -- provoked: the key taken out of 0008zx's answer, which the comparison must then report (the new answer holds it)
      select (cma.inbound_now() #- '{today,inbound_talk_seconds}') is not distinct from (case when v_provoke then pg_temp.inbound_now_0008zx() #- '{today,longest_waiting_seconds}'
                                                          else jsonb_set(pg_temp.inbound_now_0008zx(), '{today,longest_waiting_seconds}', 'null') end) into v_same;
      insert into verify_0009h values (v_ord, 'E1 inbound_now() without inbound_talk_seconds: the same JSON as 0008zx''s with longest_waiting_seconds null (' || t.slug || ')',
        case when v_same then 'PASS' else 'FAIL' end, case when v_same then 'the same today, callbacks and summary' else 'the JSON differs' end);
    exception when others then
      insert into verify_0009h values (v_ord, 'E1 inbound_now() (' || t.slug || ')', 'FAIL', 'error ' || sqlstate || ': ' || left(sqlerrm, 120));
    end;

    -- E2. outbound today: Reports → Calls' figures for the tenant's date
    v_ord := v_ord + 1;
    begin
      v_a := pg_temp.v0009h_shared(t.id, now());
      v_b := pg_temp.v0009h_report(t.id, cma.tenant_today_of(t.id));
      insert into verify_0009h values (v_ord, 'E2 outbound today: outbound, connected, connected rate and outbound talk as cma.calls_figures_of for today (' || t.slug || ')',
        case when v_a is not null and v_a = v_b and not v_provoke then 'PASS' else 'FAIL' end,
        format('%s against %s (outbound|connected|rate|talk|average)', coalesce(v_a, 'no row'), coalesce(v_b, 'no row')));
    exception when others then
      insert into verify_0009h values (v_ord, 'E2 outbound today (' || t.slug || ')', 'FAIL', 'error ' || sqlstate || ': ' || left(sqlerrm, 120));
    end;

    -- E3. the new poll no slower than the inbound one
    v_ord := v_ord + 1;
    v_in := pg_temp.v0009h_best_ms('select cma.inbound_now()', v_runs);
    v_out := pg_temp.v0009h_best_ms('select cma.outbound_now()', v_runs);
    insert into verify_0009h values (v_ord, 'E3 outbound_now() no slower than inbound_now(), as the application (' || t.slug || ')',
      case when v_in >= 0 and v_out >= 0 and v_out <= v_in + v_slack and not v_provoke then 'PASS' else 'FAIL' end,
      case when v_in < 0 or v_out < 0 then 'a read raised an error'
           else format('outbound %s ms against inbound %s ms (best of %s each, %s ms of slack)', v_out, v_in, v_runs, v_slack) end);
  end loop;
  perform set_config('role', 'cma_owner', true);
end
$$;

drop function if exists pg_temp.v0009h_best_ms(text, integer);
drop function if exists pg_temp.v0009h_conversations(uuid, date);
drop function if exists pg_temp.v0009h_report(uuid, date);
drop function if exists pg_temp.v0009h_shared(uuid, timestamptz);
drop function if exists pg_temp.v0009h_fig(uuid, timestamptz);
drop function if exists pg_temp.v0009h_call(text, text, timestamptz, integer, integer, text, jsonb, boolean);
drop function if exists pg_temp.v0009h_user(uuid, text);
drop function if exists pg_temp.v0009h_row(integer, text, text, text);
drop function if exists pg_temp.inbound_now_0008zx();

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0009h
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0009h where result = 'FAIL') then 'FAIL'
                  when not exists (select 1 from pg_temp.verify_0009h where result = 'PASS') then 'FAIL'
                  else 'PASS' end,
             format('165_verify_live_outbound: %s PASS, %s FAIL, %s skip', (select count(*) from pg_temp.verify_0009h where result = 'PASS'),
                    (select count(*) from pg_temp.verify_0009h where result = 'FAIL'), (select count(*) from pg_temp.verify_0009h where result = 'skip'))) x
order by ord;
drop table if exists pg_temp.verify_0009h;
reset role;
