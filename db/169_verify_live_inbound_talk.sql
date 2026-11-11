-- =============================================================================================
-- 169_verify_live_inbound_talk.sql: verifies addition 0009j, the Live board's Inbound today with Talk time
-- =============================================================================================
-- Universal: no seed is assumed. Block S checks the addition, the functions and the grants. Block B works on two
-- throwaway tenants inside a subtransaction that is always rolled back, so nothing stays: synthetic people
-- (example.invalid) and fixed test calls placed on the running day around the tenant's midnight (Europe/Amsterdam,
-- with a line in America/New_York, west of the tenant, and one in Asia/Tokyo, east of it), because
-- cma.inbound_today_live_of and cma.inbound_now() read now(); every call starts at most eight seconds after the tenant's
-- midnight, so the verdict does not depend on the time it runs (but in the first eight seconds of a day). Block E
-- compares, per active tenant on the database it runs in and as the application acting as the tenant's first person
-- holding monitoring.live: cma.inbound_now() with 0009h's definition (164, kept here verbatim as a temporary function;
-- the functions it calls are not changed by 168), today's inbound talk time with Reports → Calls' (cma.calls_figures_of)
-- and with Calls per agent's (cma.calls_per_person_of), each comparison in one statement, so one snapshot; then times
-- the poll against 164's. Every check writes one row, PASS, FAIL or skip, and the last row is the verdict, because
-- Cloud SQL Studio shows no notices. Run as your own IAM login after 168_live_inbound_talk.sql; then 133_verify_perf.sql,
-- 145_verify_held_kinds_restore.sql and 165_verify_live_outbound.sql again (they read cma.inbound_now(); 145 and 165 are
-- edited by this change), then 131_time_all.sql part a. Expected verdict: "PASS | 169_verify_live_inbound_talk: <n>
-- PASS, 0 FAIL, <k> skip" (a skip is an active tenant without a person holding monitoring.live, or E2 for a tenant whose
-- telephony.connected_min_seconds is above 0); provoked (verify.provoke true below): every check reads FAIL (E2's skip
-- for a threshold above 0 too; a tenant without a person holding monitoring.live stays skip, nothing runs for it) and
-- the verdict "PROVOKED, NOT A PASS".
--   S1  the addition 0009j is recorded once, after 0009i
--   S2  cma.inbound_today_live_of(uuid): SQL, stable, the caller's rights, owned by cma_owner, jit off, rows 1, its
--       fifteen columns, executable by the application only; cma.inbound_now(): plpgsql, stable, jsonb, the
--       application's only, its text reading cma.inbound_today_live_of (not cma.inbound_today_of) and setting today's
--       longest_waiting_seconds to null
--   B1  the fixed calls: the tenant's day counts 6 inbound calls (two answered on the NL line, one answered and in
--       progress, one unanswered, the New York line's answered call 5 seconds after the tenant's midnight, which is the
--       day before there, and one waiting), 4 answered, 1 unanswered, 1 waiting, 3 within 20 s, a base of 5, 60.0,
--       10.0 s on average, 13.0 s at the 80th percentile, {"unknown": 1}, 1 waiting now, 20 s and 30 min; the talk time
--       205 s, over the tenant's day as the row's other figures (Martin, 10 November 2026): the two ended NL calls
--       (45 + 100) and the New York call (60); not the Tokyo line's call 10 seconds before the tenant's midnight (70, the
--       day before in the tenant's zone), not the call in progress (no talk time yet), not the unanswered or the waiting
--       one, not the day before's (50), not the outbound one (30); a call ringing since two hours before the tenant's
--       midnight is in none of them (outside the waiting limit: B6)
--   B2  that talk time is Reports → Calls' talk time minus its outbound talk time for the date (cma.calls_figures_of:
--       245 − 30 = 215) and Calls per agent's inbound talk time (cma.calls_per_person_of's total row, 215), but for the
--       calls whose day in their line's zone differs from the tenant's day (gap D34), which the detail names: + the New
--       York call (60 s, the tenant's day, not the line's), − the Tokyo call (70 s, the line's day, not the tenant's);
--       no other difference is accepted
--   B3  telephony.connected_min_seconds 40: the outbound call (30 s) is no longer Connected; the talk time stays 205 and
--       Calls per agent's (215) with it, while the report's difference becomes 245 (it then also holds the talk time of
--       outbound calls answered under the threshold), which is why E2 compares only at 0
--   B4  cma.inbound_now(): an agent is refused (CMA06); a supervisor reads today as cma.inbound_today_live_of's row with
--       longest_waiting_seconds null, the sixteen keys (inbound_talk_seconds 205), and, without the new key, the same
--       JSON as 0009h's definition (today, callbacks and summary)
--   B5  a tenant without a call: today's date, 0 calls, no rate or average, {}, 0 waiting now and 0 s of talk time;
--       inbound_now() without the new key the same as 0009h's; acting as it, cma.inbound_today_live_of for the first
--       tenant reads no call of the first tenant (row-level security under the explicit tenant)
--   B6  waiting now in the same read: with telephony.waiting_max_minutes at 2880 (two days, so the call is inside the
--       limit at any hour of the running day), the call ringing since two hours before the tenant's midnight counts in
--       waiting now (2) and in none of the day's figures; without the new key the same JSON as 0009h's, whose second
--       read counted it
--   E1  per active tenant: cma.inbound_now() without inbound_talk_seconds the same JSON as 0009h's
--   E2  per active tenant whose telephony.connected_min_seconds is 0 (Pulse4all's value and the default): today's
--       inbound_talk_seconds is cma.calls_figures_of's talk_seconds_total minus outbound_talk_seconds for the date, but
--       for the answered inbound calls whose day in their line's zone differs from the tenant's day, named in the
--       detail (none: exactly equal); skip above 0 (B3)
--   E3  per active tenant: today's inbound_talk_seconds is cma.calls_per_person_of's total inbound_talk_seconds, but for
--       the same calls, named
--   E4  per active tenant: cma.inbound_now() no slower than 0009h's: six untimed calls of each first (so both run the
--       plans a pooled connection keeps after its fifth call), then the best of verify.timing_runs runs each,
--       alternating, at most 0009h's best plus the larger of verify.slack_ms and verify.slack_ratio of it (the brief:
--       "inbound now (one statement)" must not get slower; 168 reads the calls once where 164 read them twice).
--       131_time_all.sql part a holds the poll's budget (20 ms)
-- Provoke: set provoke below to true; every check must then read FAIL, and the verdict says PROVOKED, NOT A PASS. The
-- comparisons are provoked by a deliberate difference, not by the switch alone: B4, B5, B6 and E1 then compare with
-- 0009h's JSON with waiting_now taken out, B2, E2 and E3 with the reports' figures of the day before (E2 and E3 also
-- take the switch: a tenant without a call answers 0 on both days).
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
select set_config('verify.timing_runs', '8', false);                 -- timed runs per read in E4, after six untimed ones each
select set_config('verify.slack_ms', '0.5', false);                  -- E4: what the new poll may take above 0009h's best (measurement noise),
select set_config('verify.slack_ratio', '0.03', false);              --     or this share of 0009h's best when that is more

drop table if exists pg_temp.verify_0009j;
create temporary table verify_0009j (ord integer, check_name text, result text, detail text);
-- block E writes its rows while acting as the application
grant select, insert on pg_temp.verify_0009j to cma_app;

-- cma.inbound_now() as 0009h (164) defined it, verbatim; the functions it calls are not changed by 168
create function pg_temp.inbound_now_0009h()
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
    'today', (select to_jsonb(x) || '{"longest_waiting_seconds": null}'::jsonb from cma.inbound_today_of(v_tenant) x),
    'callbacks', v_list,
    'summary', (select jsonb_build_object('listed', jsonb_array_length(v_list),
                                          'anonymous_count', cma.anonymous_missed_calls_of(v_tenant, now() - make_interval(days => s.lookback)),
                                          'lookback_days', s.lookback)
                from (select greatest(0, cma.setting_of(t.id, 'telephony.callback_lookback_days')::integer) as lookback
                      from cma.tenant t where t.id = v_tenant) s));
end
$$;

-- A check row kept as four texts, for the block whose subtransaction is rolled back (its rows must outlive it)
create or replace function pg_temp.v0009j_row(p_ord integer, p_name text, p_result text, p_detail text)
returns text[] language sql immutable as $$ select array[p_ord::text, p_name, p_result, p_detail] $$;

-- The tenant's first active person (the oldest) holding a permission, as the time scripts pick it
create or replace function pg_temp.v0009j_user(p_tenant uuid, p_perm text)
returns uuid
language sql
as $$
  select u.id from cma.app_user u
  where u.tenant_id = p_tenant and u.status = 'active' and u.kind = 'person' and cma.has_permission(u.id, p_perm)
  order by u.created_at, u.id limit 1
$$;

-- One telephony call as the ingest write takes it (as 165): answered p_ring seconds after the start (null: never), ended
-- p_talk seconds after the answer (null: not ended; for a call never answered, ended after 20 seconds unless p_open), on
-- the line p_number, an invented hash from the id
create or replace function pg_temp.v0009j_call(p_src text, p_dir text, p_start timestamptz, p_ring integer, p_talk integer,
                                               p_number text, p_open boolean default false)
returns jsonb
language sql immutable
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'sourceId', p_src, 'direction', p_dir, 'startedAt', p_start,
    'answeredAt', p_start + make_interval(secs => p_ring),
    'endedAt', case when p_open then null
                    when p_ring is null then p_start + interval '20 seconds'
                    else p_start + make_interval(secs => p_ring + p_talk) end,
    'numberRef', p_number, 'userRef', 'tu-1', 'counterpartHash', md5(p_src) || md5(p_src || 'x'),
    'versionAt', p_start + interval '1 hour'))
$$;

-- The Live board's today of a tenant, as one text: date|offered|answered|unanswered|waiting|within|base|level|average|
-- p80|reasons|waiting now|seconds|minutes|talk (a null is empty)
create or replace function pg_temp.v0009j_fig(p_tenant uuid)
returns text
language sql stable
as $$
  select format('%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s', x.business_date, x.offered, x.answered, x.unanswered, x.waiting,
                x.answered_within_target, x.service_level_base, x.service_level_pct, x.avg_answer_seconds, x.p80_answer_seconds,
                x.unanswered_by_reason, x.waiting_now, x.service_level_seconds, x.waiting_max_minutes, x.inbound_talk_seconds)
  from cma.inbound_today_live_of(p_tenant) x
$$;

-- Reports → Calls' talk time minus its outbound talk time for a date (cma.calls_figures_of's total row), and its talk
-- time and outbound talk time as text
create or replace function pg_temp.v0009j_report(p_tenant uuid, p_date date)
returns text
language sql stable
as $$
  select format('%s (%s − %s)', f.talk_seconds_total - f.outbound_talk_seconds, f.talk_seconds_total, f.outbound_talk_seconds)
  from cma.calls_figures_of(p_tenant, p_date, p_date, null, null, 'day') f
  where f.group_key is null
$$;

-- Calls per agent's inbound talk time for a date (cma.calls_per_person_of's total row)
create or replace function pg_temp.v0009j_per_agent(p_tenant uuid, p_date date)
returns bigint
language sql stable
as $$
  select p.inbound_talk_seconds from cma.calls_per_person_of(p_tenant, p_date, p_date, null, null) p where p.row_kind = 'total'
$$;

-- The answered inbound calls on counted lines whose day in their line's zone (the line's market's, else the tenant's:
-- cma.calls_of's date, gap D34) differs from the tenant's day at a date: plus, the talk time of those in the tenant's day
-- and not the line's (counted by Inbound today, not by the reports for the date), minus, of those in the line's day and
-- not the tenant's (the other way round), and the calls named by id and line, + or −, for the check's detail (the first
-- ten by call id, then 'and n more')
create or replace function pg_temp.v0009j_zone_diff(p_tenant uuid, p_date date)
returns table (plus bigint, minus bigint, calls text)
language sql stable
as $$
  with c as (
    select tc.source_id, tc.number_ref, tc.talk_seconds,
           (tc.started_at at time zone t.timezone)::date = p_date as in_day,
           (tc.started_at at time zone coalesce(m.time_zone, t.timezone))::date = p_date as on_line_day
    from cma.telephony_call tc
    join cma.tenant t on t.id = tc.tenant_id
    left join cma.telephony_number n on n.tenant_id = tc.tenant_id and n.connection_id = tc.connection_id and n.number_ref = tc.number_ref
    left join cma.market m on m.tenant_id = tc.tenant_id and m.code = n.market
    where tc.tenant_id = p_tenant and tc.direction = 'inbound' and tc.source_deleted_at is null and tc.started_at is not null
      and tc.answered_at is not null and coalesce(n.is_counted, true)
      -- the bounds as scalar subqueries, so they reach telephony_call_started_idx under row-level security (night N06)
      and tc.started_at >= (select (p_date - 1)::timestamp at time zone t2.timezone from cma.tenant t2 where t2.id = p_tenant)
      and tc.started_at < (select (p_date + 2)::timestamp at time zone t2.timezone from cma.tenant t2 where t2.id = p_tenant)
  ),
  d as (
    select c.*, row_number() over (order by c.source_id) as k, count(*) over () as n
    from c where c.in_day <> c.on_line_day and c.talk_seconds is not null
  )
  select coalesce(sum(c.talk_seconds) filter (where c.in_day and not c.on_line_day), 0)::bigint,
         coalesce(sum(c.talk_seconds) filter (where c.on_line_day and not c.in_day), 0)::bigint,
         -- the first ten named, then how many more: a busy day's detail stays one readable line
         coalesce((select string_agg(format('%s %s s call %s (line %s)', case when d.in_day then '+' else '−' end, d.talk_seconds, d.source_id, coalesce(d.number_ref, 'none')),
                                     ', ' order by d.source_id)
                          || case when max(d.n) > 10 then format(' and %s more', max(d.n) - 10) else '' end
                   from d where d.k <= 10), 'none')
  from c
$$;
-- jit off: not inlined into E2's and E3's lateral call, so p_date stays a parameter and the bounds stay on the index
alter function pg_temp.v0009j_zone_diff(uuid, date) set jit = off;

-- ---------------------------------------------------------------------------------------------
-- S. Structure and privileges
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_fn  regprocedure;
  v_sig text;
  v_src text;
  v_bad text := '';
begin
  -- S1. the addition is recorded once, after 0009i
  insert into verify_0009j values (1, 'S1 addition 0009j recorded once, after 0009i',
    case when (select count(*) from cma.schema_migration where version = '0009j') = 1
              and exists (select 1 from cma.schema_migration where version = '0009i') and not v_provoke then 'PASS' else 'FAIL' end,
    case when v_provoke then 'provoked' else '' end);

  -- S2. the new function and cma.inbound_now()
  foreach v_sig in array array['cma.inbound_today_live_of(uuid)', 'cma.inbound_now()'] loop
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
  if to_regprocedure('cma.inbound_today_live_of(uuid)') is not null then
    if pg_get_function_result('cma.inbound_today_live_of(uuid)'::regprocedure) is distinct from
       'TABLE(business_date date, offered integer, answered integer, unanswered integer, waiting integer, answered_within_target integer, service_level_base integer, service_level_pct numeric, avg_answer_seconds numeric, p80_answer_seconds numeric, unanswered_by_reason jsonb, waiting_now integer, service_level_seconds integer, waiting_max_minutes integer, inbound_talk_seconds bigint)' then
      v_bad := v_bad || 'inbound_today_live_of''s columns: ' || pg_get_function_result('cma.inbound_today_live_of(uuid)'::regprocedure) || '; ';
    end if;
    if (select p.prorows from pg_proc p where p.oid = 'cma.inbound_today_live_of(uuid)'::regprocedure) <> 1 then
      v_bad := v_bad || 'inbound_today_live_of''s rows is not 1; ';
    end if;
  end if;
  if to_regprocedure('cma.inbound_now()') is not null then
    v_src := (select p.prosrc from pg_proc p where p.oid = 'cma.inbound_now()'::regprocedure);
    if pg_get_function_result('cma.inbound_now()'::regprocedure) <> 'jsonb'
       or v_src !~ 'to_jsonb\(x\) \|\| ''\{"longest_waiting_seconds": null\}''::jsonb from cma\.inbound_today_live_of\(v_tenant\) x'
       or v_src ~ 'cma\.inbound_today_of' then
      v_bad := v_bad || 'inbound_now''s result, or its text does not read inbound_today_live_of with longest_waiting_seconds null; ';
    end if;
  end if;
  insert into verify_0009j values (2, 'S2 inbound_today_live_of: SQL, stable, invoker, cma_owner, jit off, rows 1, fifteen columns; inbound_now reads it with the key null; the application''s only',
    case when v_bad = '' and not v_provoke then 'PASS' else 'FAIL' end, v_bad);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- B. Behaviour on throwaway tenants, rolled back
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  rows_   text[] := '{}';
  v_t uuid; v_admin uuid; v_sup uuid; v_agent uuid; v_ing uuid; v_tel uuid; v_t2 uuid; v_admin2 uuid;
  v_txt text; v_bad text; v_err text; v_rep text; v_per bigint; v_talk bigint; z record;
  j jsonb; j_old jsonb;
  v_today date;
  v_t0    timestamptz;
begin
  begin
    -- the tenant, its people and its telephony connection (as the owner)
    v_t := cma.create_tenant('verify-0009j', 'Verify 0009j', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-admin@example.invalid', 'admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-sup@example.invalid', 'sup') returning id into v_sup;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t, 'verify-agent@example.invalid', 'agent') returning id into v_agent;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.user_id, ar.id
    from (values (v_admin, 'admin'), (v_sup, 'supervisor'), (v_agent, 'agent')) as x(user_id, role_key)
    join cma.app_role ar on ar.tenant_id = v_t and ar.key = x.role_key;
    select x.user_id into v_ing from cma.app_user_external_id x where x.tenant_id = v_t and x.system = 'ingest';
    insert into cma.integration_connection (tenant_id, adapter, name, external_account_id, kind)
    values (v_t, 'verifytel', 'Verify 0009j telephony', 'tel-1', 'telephony') returning id into v_tel;
    -- a second tenant without a call (B5), with its admin
    v_t2 := cma.create_tenant('verify-0009j-empty', 'Verify 0009j empty', 'Europe/Amsterdam');
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin') returning id into v_admin2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, v_admin2, ar.id from cma.app_role ar where ar.tenant_id = v_t2 and ar.key = 'admin';

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t::text, true);

    -- the catalogs from the source (the Ingest user), then the configuration (the admin): three markets in three zones,
    -- a line in each
    perform set_config('app.user_id', v_ing::text, true);
    perform cma.ingest_upsert_telephony_catalog(v_tel, 'number', '[{"numberRef": "n-nl", "name": "Verify NL line", "digits": "+31000000001"},
      {"numberRef": "n-us", "name": "Verify US line", "digits": "+10000000001"}, {"numberRef": "n-jp", "name": "Verify JP line", "digits": "+810000000001"}]');
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.upsert_market('NL', 'Netherlands', 'Europe/Amsterdam', 'nl', 'EUR');
    perform cma.upsert_market('US', 'United States', 'America/New_York', 'en', 'USD');
    perform cma.upsert_market('JP', 'Japan', 'Asia/Tokyo', 'ja', 'JPY');
    perform cma.set_telephony_number(v_tel, 'n-nl', 'NL', true);
    perform cma.set_telephony_number(v_tel, 'n-us', 'US', true);
    perform cma.set_telephony_number(v_tel, 'n-jp', 'JP', true);

    -- the fixed calls (the Ingest user), around the tenant's midnight of the running day
    v_today := (now() at time zone 'Europe/Amsterdam')::date;
    v_t0 := v_today::timestamp at time zone 'Europe/Amsterdam';
    perform set_config('app.user_id', v_ing::text, true);
    perform cma.ingest_upsert_telephony_calls(v_tel, jsonb_build_array(
      pg_temp.v0009j_call('i1', 'inbound',  v_t0 + interval '1 second',  5,    45,   'n-nl'),       -- answered in 5 s, 45 s of talk
      pg_temp.v0009j_call('i2', 'inbound',  v_t0 + interval '2 seconds', 25,   100,  'n-nl'),       -- answered in 25 s (over 20), 100 s
      pg_temp.v0009j_call('i3', 'inbound',  v_t0 + interval '3 seconds', 5,    null, 'n-nl'),       -- answered, in progress: no talk time yet
      pg_temp.v0009j_call('i4', 'inbound',  v_t0 + interval '4 seconds', null, null, 'n-nl'),       -- unanswered (no reason: unknown)
      -- the New York line: 5 seconds after the tenant's midnight is 18:00 the day before there
      pg_temp.v0009j_call('u1', 'inbound',  v_t0 + interval '5 seconds', 5,    60,   'n-us'),
      -- the Tokyo line: 10 seconds before the tenant's midnight is 07:59:50 (winter) on the date there
      pg_temp.v0009j_call('j1', 'inbound',  v_t0 - interval '10 seconds', 5,   70,   'n-jp'),
      pg_temp.v0009j_call('o1', 'outbound', v_t0 + interval '6 seconds', 5,    30,   'n-nl'),       -- connected outbound, 30 s
      pg_temp.v0009j_call('o2', 'outbound', v_t0 + interval '7 seconds', null, null, 'n-nl'),       -- outbound, not connected
      pg_temp.v0009j_call('y1', 'inbound',  v_t0 - interval '23 hours',  5,    50,   'n-nl'),       -- the day before
      pg_temp.v0009j_call('w0', 'inbound',  v_t0 - interval '2 hours',   null, null, 'n-nl', true),  -- ringing since the evening before (B6)
      pg_temp.v0009j_call('w1', 'inbound',  greatest(v_t0 + interval '8 seconds', now() - interval '1 minute'), null, null, 'n-nl', true)));  -- waiting
    perform set_config('app.user_id', v_admin::text, true);

    -- B1. the day's figures and its talk time
    v_txt := pg_temp.v0009j_fig(v_t);
    rows_ := rows_ || pg_temp.v0009j_row(11, 'B1 the tenant''s day: 6 calls, 4 answered, 1 unanswered, 1 waiting, 3 within 20 s of 5, 60.0, 10.0 s, 13.0 s, 1 waiting now; talk time 205 s (the tenant''s day)',
      case when v_txt = format('%s|6|4|1|1|3|5|60.0|10.0|13.0|{"unknown": 1}|1|20|30|205', v_today) and not v_provoke then 'PASS' else 'FAIL' end,
      coalesce(v_txt, 'no row'));

    -- B2. the same as Reports → Calls' talk time minus its outbound talk time, and as Calls per agent's inbound talk time
    select x.inbound_talk_seconds into v_talk from cma.inbound_today_live_of(v_t) x;
    v_rep := pg_temp.v0009j_report(v_t, case when v_provoke then v_today - 1 else v_today end);
    v_per := pg_temp.v0009j_per_agent(v_t, case when v_provoke then v_today - 1 else v_today end);
    select * into z from pg_temp.v0009j_zone_diff(v_t, v_today);
    rows_ := rows_ || pg_temp.v0009j_row(12, 'B2 the talk time is Reports → Calls'' talk time minus its outbound talk time (245 − 30) and Calls per agent''s, but for the calls on another day in their line''s zone (+60 New York, −70 Tokyo), named',
      case when v_talk is not null and v_rep = '215 (245 − 30)' and v_per = 215 and z.plus = 60 and z.minus = 70
                and v_talk = split_part(v_rep, ' ', 1)::bigint + z.plus - z.minus and v_talk = v_per + z.plus - z.minus then 'PASS' else 'FAIL' end,
      format('%s against the report''s %s and Calls per agent''s %s; on another day in their line''s zone: %s', coalesce(v_talk::text, 'no row'),
             coalesce(v_rep, 'no row'), coalesce(v_per::text, 'no row'), z.calls));

    -- B3. the Connected threshold moves the report's difference, not the talk time
    perform cma.set_tenant_setting('telephony.connected_min_seconds', '40');
    select x.inbound_talk_seconds into v_talk from cma.inbound_today_live_of(v_t) x;
    v_rep := pg_temp.v0009j_report(v_t, v_today);
    v_per := pg_temp.v0009j_per_agent(v_t, v_today);
    perform cma.set_tenant_setting('telephony.connected_min_seconds', null);
    rows_ := rows_ || pg_temp.v0009j_row(13, 'B3 Connected from 40 s: the talk time stays 205 and Calls per agent''s (215) with it; the report''s difference becomes 245 (245 − 0)',
      case when v_talk = 205 and v_per = 215 and v_rep = '245 (245 − 0)' and not v_provoke then 'PASS' else 'FAIL' end,
      format('%s; Calls per agent %s; the report %s', coalesce(v_talk::text, 'no row'), coalesce(v_per::text, 'no row'), coalesce(v_rep, 'no row')));

    -- B4. cma.inbound_now(): the permission, the row, the keys, 0009h's answer
    v_bad := '';
    perform set_config('app.user_id', v_agent::text, true);
    v_err := 'no error';
    begin
      perform cma.inbound_now();
    exception when others then
      v_err := sqlstate;
    end;
    if v_err <> 'CMA06' then v_bad := v_bad || 'an agent got ' || v_err || '; '; end if;
    perform set_config('app.user_id', v_sup::text, true);
    j := cma.inbound_now();
    j_old := pg_temp.inbound_now_0009h();
    if (j -> 'today') is distinct from (select to_jsonb(x) || '{"longest_waiting_seconds": null}'::jsonb from cma.inbound_today_live_of(v_t) x) then
      v_bad := v_bad || 'today is not inbound_today_live_of''s row with the key null; ';
    end if;
    if (select array_agg(k order by k collate "C") from jsonb_object_keys(j -> 'today') k) is distinct from
       array['answered', 'answered_within_target', 'avg_answer_seconds', 'business_date', 'inbound_talk_seconds', 'longest_waiting_seconds', 'offered',
             'p80_answer_seconds', 'service_level_base', 'service_level_pct', 'service_level_seconds', 'unanswered', 'unanswered_by_reason', 'waiting',
             'waiting_max_minutes', 'waiting_now'] then
      v_bad := v_bad || 'today''s keys: ' || (select string_agg(k, ',' order by k) from jsonb_object_keys(j -> 'today') k) || '; ';
    end if;
    if (j -> 'today' ->> 'inbound_talk_seconds') is distinct from '205' then v_bad := v_bad || 'the talk time is ' || coalesce(j -> 'today' ->> 'inbound_talk_seconds', 'null') || '; '; end if;
    if (j -> 'today' -> 'longest_waiting_seconds') is distinct from 'null'::jsonb then v_bad := v_bad || 'longest_waiting_seconds is not a null key; '; end if;
    -- provoked: waiting_now taken out of 0009h's answer, which the comparison must then report
    if (j #- '{today,inbound_talk_seconds}') is distinct from (case when v_provoke then j_old #- '{today,waiting_now}' else j_old end) then
      v_bad := v_bad || 'without the new key, not 0009h''s JSON; ';
    end if;
    if jsonb_array_length(j -> 'callbacks') < 1 then v_bad := v_bad || 'no missed caller listed: callbacks not compared on a row; '; end if;
    rows_ := rows_ || pg_temp.v0009j_row(14, 'B4 inbound_now(): an agent refused (CMA06); a supervisor reads inbound_today_live_of''s row, the sixteen keys, 205 s, and 0009h''s JSON without the new key',
      case when v_bad = '' then 'PASS' else 'FAIL' end, v_bad);

    -- B5. a tenant without a call
    v_bad := '';
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    v_txt := pg_temp.v0009j_fig(v_t2);
    if v_txt is distinct from format('%s|0|0|0|0|0|0||||{}|0|20|30|0', v_today) then v_bad := v_bad || 'the row: ' || coalesce(v_txt, 'no row') || '; '; end if;
    j := cma.inbound_now();
    if (j #- '{today,inbound_talk_seconds}') is distinct from (case when v_provoke then pg_temp.inbound_now_0009h() #- '{today,waiting_now}' else pg_temp.inbound_now_0009h() end) then
      v_bad := v_bad || 'without the new key, not 0009h''s JSON; ';
    end if;
    -- acting as the second tenant, the first tenant's calls stay out of reach (row-level security under the explicit
    -- tenant): its row reads as a day without a call
    v_txt := pg_temp.v0009j_fig(v_t);
    if v_txt is distinct from format('%s|0|0|0|0|0|0||||{}|0|20|30|0', v_today) then v_bad := v_bad || 'the first tenant read as the second: ' || coalesce(v_txt, 'no row') || '; '; end if;
    rows_ := rows_ || pg_temp.v0009j_row(15, 'B5 a tenant without a call: today''s date, 0 calls, no rate or average, {}, 0 waiting now, 0 s; 0009h''s JSON without the new key; the first tenant''s calls out of its reach',
      case when v_bad = '' then 'PASS' else 'FAIL' end, case when v_bad = '' then v_txt else v_bad end);

    -- B6. waiting now in the same read: a call ringing since before the tenant's midnight, inside the waiting limit
    v_bad := '';
    perform set_config('app.tenant_id', v_t::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_tenant_setting('telephony.waiting_max_minutes', '2880');
    v_txt := pg_temp.v0009j_fig(v_t);
    if v_txt is distinct from format('%s|6|4|1|1|3|5|60.0|10.0|13.0|{"unknown": 1}|2|20|2880|205', v_today) then v_bad := v_bad || 'the row: ' || coalesce(v_txt, 'no row') || '; '; end if;
    perform set_config('app.user_id', v_sup::text, true);
    j := cma.inbound_now();
    if (j #- '{today,inbound_talk_seconds}') is distinct from (case when v_provoke then pg_temp.inbound_now_0009h() #- '{today,waiting_now}' else pg_temp.inbound_now_0009h() end) then
      v_bad := v_bad || 'without the new key, not 0009h''s JSON; ';
    end if;
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.set_tenant_setting('telephony.waiting_max_minutes', null);
    rows_ := rows_ || pg_temp.v0009j_row(16, 'B6 the waiting limit at 2880 minutes: the call ringing since the evening before counts in waiting now (2), not in the day''s figures; 0009h''s JSON without the new key',
      case when v_bad = '' then 'PASS' else 'FAIL' end, case when v_bad = '' then v_txt else v_bad end);

    raise exception using errcode = 'CMAOK';
  exception
    when sqlstate 'CMAOK' then null;
    when others then
      rows_ := rows_ || pg_temp.v0009j_row(99, 'B block ended early', 'FAIL', 'error ' || sqlstate || ': ' || left(sqlerrm, 160));
  end;
  perform set_config('role', 'cma_owner', true);
  perform set_config('app.tenant_id', '', true);
  perform set_config('app.user_id', '', true);
  insert into verify_0009j (ord, check_name, result, detail)
  select rows_[4 * i - 3]::integer, rows_[4 * i - 2], rows_[4 * i - 1], rows_[4 * i] from generate_series(1, cardinality(rows_) / 4) i;
  -- a block that ended early counts the checks it did not reach as FAIL
  insert into verify_0009j (ord, check_name, result, detail)
  select o, 'B' || (o - 10) || ' not reached', 'FAIL', 'the block ended before this check'
  from generate_series(11, 16) o
  where not exists (select 1 from verify_0009j v where v.ord = o);
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
  v_ratio numeric := current_setting('verify.slack_ratio')::numeric;
  t record;
  v_user uuid; v_ord integer := 100; v_same boolean; v_talk bigint; v_ref text; v_per bigint; v_date date; v_min integer;
  v_plus bigint; v_minus bigint; v_calls text;
  v_t0 timestamptz; v_ms numeric; v_new numeric; v_old numeric; v_err boolean;
begin
  for t in select x.id, x.slug from cma.tenant x where x.status = 'active' order by x.slug collate "C" loop
    perform set_config('role', 'cma_owner', true);
    perform set_config('app.tenant_id', t.id::text, true);
    perform set_config('app.user_id', '', true);
    v_user := pg_temp.v0009j_user(t.id, 'monitoring.live');
    v_min := greatest(0, cma.setting_of(t.id, 'telephony.connected_min_seconds')::integer);
    if v_user is null then
      v_ord := v_ord + 1;
      insert into verify_0009j values (v_ord, 'E1-E4 ' || t.slug, 'skip', 'no active person holds monitoring.live: nothing compared or timed');
      continue;
    end if;
    perform set_config('role', 'cma_app', true);
    perform set_config('app.user_id', v_user::text, true);

    -- E1. inbound now without the new key: 0009h's answer (one statement)
    v_ord := v_ord + 1;
    begin
      -- provoked: waiting_now taken out of 0009h's answer, which the comparison must then report
      select (cma.inbound_now() #- '{today,inbound_talk_seconds}') is not distinct from
             (case when v_provoke then pg_temp.inbound_now_0009h() #- '{today,waiting_now}' else pg_temp.inbound_now_0009h() end) into v_same;
      insert into verify_0009j values (v_ord, 'E1 inbound_now() without inbound_talk_seconds: the same JSON as 0009h''s (' || t.slug || ')',
        case when v_same then 'PASS' else 'FAIL' end, case when v_same then 'the same today, callbacks and summary' else 'the JSON differs' end);
    exception when others then
      insert into verify_0009j values (v_ord, 'E1 inbound_now() (' || t.slug || ')', 'FAIL', 'error ' || sqlstate || ': ' || left(sqlerrm, 120));
    end;

    -- E2 and E3. today's inbound talk time against Reports → Calls and Calls per agent for the board's date, each in
    -- the statement that reads the board (one snapshot, so a call arriving meanwhile changes both sides)
    v_ord := v_ord + 1;
    begin
      select (q.j -> 'today' ->> 'inbound_talk_seconds')::bigint, (q.j -> 'today' ->> 'business_date')::date,
             pg_temp.v0009j_report(t.id, (q.j -> 'today' ->> 'business_date')::date - case when v_provoke then 1 else 0 end),
             z.plus, z.minus, z.calls
        into v_talk, v_date, v_ref, v_plus, v_minus, v_calls
      from (select cma.inbound_now() as j offset 0) q
      cross join lateral pg_temp.v0009j_zone_diff(t.id, (q.j -> 'today' ->> 'business_date')::date) z;  -- offset 0: the board read once, not once per reference
      if v_min > 0 then
        insert into verify_0009j values (v_ord, 'E2 today''s inbound talk time against Reports → Calls (' || t.slug || ')',
          case when v_provoke then 'FAIL' else 'skip' end,
          format('telephony.connected_min_seconds is %s: the report''s difference also holds outbound calls answered under it (B3); E3 compares', v_min));
      else
        insert into verify_0009j values (v_ord, 'E2 today''s inbound talk time is Reports → Calls'' talk time minus its outbound talk time but for calls on another day in their line''s zone (' || t.slug || ')',
          case when v_talk is not null and v_ref is not null and v_talk = split_part(v_ref, ' ', 1)::bigint + v_plus - v_minus and not v_provoke then 'PASS' else 'FAIL' end,
          format('%s s on %s against the report''s %s; on another day in their line''s zone: %s', coalesce(v_talk::text, 'no value'), v_date, coalesce(v_ref, 'no row'), v_calls));
      end if;
    exception when others then
      insert into verify_0009j values (v_ord, 'E2 today''s inbound talk time (' || t.slug || ')', 'FAIL', 'error ' || sqlstate || ': ' || left(sqlerrm, 120));
    end;
    v_ord := v_ord + 1;
    begin
      select (q.j -> 'today' ->> 'inbound_talk_seconds')::bigint, (q.j -> 'today' ->> 'business_date')::date,
             pg_temp.v0009j_per_agent(t.id, (q.j -> 'today' ->> 'business_date')::date - case when v_provoke then 1 else 0 end),
             z.plus, z.minus, z.calls
        into v_talk, v_date, v_per, v_plus, v_minus, v_calls
      from (select cma.inbound_now() as j offset 0) q
      cross join lateral pg_temp.v0009j_zone_diff(t.id, (q.j -> 'today' ->> 'business_date')::date) z;
      insert into verify_0009j values (v_ord, 'E3 today''s inbound talk time is Calls per agent''s inbound talk time but for calls on another day in their line''s zone (' || t.slug || ')',
        case when v_talk is not null and v_per is not null and v_talk = v_per + v_plus - v_minus and not v_provoke then 'PASS' else 'FAIL' end,
        format('%s s on %s against %s s; on another day in their line''s zone: %s', coalesce(v_talk::text, 'no value'), v_date, coalesce(v_per::text, 'no row'), v_calls));
    exception when others then
      insert into verify_0009j values (v_ord, 'E3 today''s inbound talk time (' || t.slug || ')', 'FAIL', 'error ' || sqlstate || ': ' || left(sqlerrm, 120));
    end;

    -- E4. the poll no slower than 0009h's: alternating runs, the best of each
    v_ord := v_ord + 1;
    v_new := null; v_old := null; v_err := false;
    begin
      -- past the fifth call on this connection, both sides on the plans a pooled connection keeps
      for i in 1 .. 6 loop
        perform cma.inbound_now();
        perform pg_temp.inbound_now_0009h();
      end loop;
      for i in 1 .. greatest(1, v_runs) loop
        v_t0 := clock_timestamp();
        perform cma.inbound_now();
        v_ms := extract(epoch from clock_timestamp() - v_t0) * 1000;
        v_new := least(coalesce(v_new, v_ms), v_ms);
        v_t0 := clock_timestamp();
        perform pg_temp.inbound_now_0009h();
        v_ms := extract(epoch from clock_timestamp() - v_t0) * 1000;
        v_old := least(coalesce(v_old, v_ms), v_ms);
      end loop;
    exception when others then
      v_err := true;
    end;
    insert into verify_0009j values (v_ord, 'E4 inbound_now() no slower than 0009h''s, as the application (' || t.slug || ')',
      case when not v_err and round(v_new, 2) <= round(v_old, 2) + greatest(v_slack, v_ratio * v_old) and not v_provoke then 'PASS' else 'FAIL' end,
      case when v_err then 'a read raised an error'
           else format('%s ms against 0009h''s %s ms (best of %s each after six untimed, alternating, %s ms of slack)', round(v_new, 2), round(v_old, 2), v_runs,
                       round(greatest(v_slack, v_ratio * v_old), 2)) end);
  end loop;
  perform set_config('role', 'cma_owner', true);
end
$$;

drop function if exists pg_temp.v0009j_zone_diff(uuid, date);
drop function if exists pg_temp.v0009j_per_agent(uuid, date);
drop function if exists pg_temp.v0009j_report(uuid, date);
drop function if exists pg_temp.v0009j_fig(uuid);
drop function if exists pg_temp.v0009j_call(text, text, timestamptz, integer, integer, text, boolean);
drop function if exists pg_temp.v0009j_user(uuid, text);
drop function if exists pg_temp.v0009j_row(integer, text, text, text);
drop function if exists pg_temp.inbound_now_0009h();

select check_name, result, detail
from (select ord, check_name, result, detail from pg_temp.verify_0009j
      union all
      select 1000000, 'verdict',
             case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS'
                  when exists (select 1 from pg_temp.verify_0009j where result = 'FAIL') then 'FAIL'
                  when not exists (select 1 from pg_temp.verify_0009j where result = 'PASS') then 'FAIL'
                  else 'PASS' end,
             format('169_verify_live_inbound_talk: %s PASS, %s FAIL, %s skip', (select count(*) from pg_temp.verify_0009j where result = 'PASS'),
                    (select count(*) from pg_temp.verify_0009j where result = 'FAIL'), (select count(*) from pg_temp.verify_0009j where result = 'skip'))) x
order by ord;
drop table if exists pg_temp.verify_0009j;
reset role;
