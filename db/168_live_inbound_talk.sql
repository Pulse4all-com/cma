-- =============================================================================================
-- 168_live_inbound_talk.sql: addition 0009j, the Live board's Inbound today with Talk time
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics: the thresholds are the tenant's settings
-- (telephony.service_level_seconds, telephony.waiting_max_minutes), the lines, markets, zones and missed reasons its
-- catalogs. Runs unchanged in every database, after 166_live_outbound_direct.sql (0009i). Rerunnable, forward-only, in
-- one transaction with a lock timeout. Run as your own IAM login: dev first, then 169_verify_live_inbound_talk.sql
-- there, then the verifies that read cma.inbound_now() again: 133_verify_perf.sql (unchanged, still PASS: its A5 reads
-- today, callbacks and summary, of today only offered), 145_verify_held_kinds_restore.sql and
-- 165_verify_live_outbound.sql, which this change edits (145's A10 and E6, 165's B7 and E1 compare cma.inbound_now()
-- with an earlier definition's JSON; they now take the new key out of the new answer before comparing, which changes
-- nothing on a database without 168, so both read the same before and after it); then 131_time_all.sql part a,
-- unchanged: the web's statements are the same, and its rows 'inbound now (one statement)' (prod 15.7 ms on 10 November
-- 2026, before 168) and 'live board calls (one statement)' time the read below inside them; 169's E4 holds the new poll
-- to 164's time. Prod the same, before the merge: 168, 169,
-- 133, 145, 165, 131 part a; then the merge.
-- Release order (Martin, 10 November 2026; as #260): the database first. cma.inbound_now() keeps waiting_now and
-- longest_waiting_seconds (always null, since 164) in today exactly as now, so main's web runs unchanged on a database
-- with 168: it ignores the new key and its Waiting now tile reads waiting_now as before. This branch's web reads
-- inbound_talk_seconds and no longer reads waiting_now or longest_waiting_seconds; on a database without 168 its Talk
-- time tile would read a missing key, which is why 168 runs in prod before the merge. The two kept keys leave in the
-- migration that brings the combined Live read under 20 ms (Open decisions).
-- No table, view, column or setting changes: the data map's schema does not change. No index is added: the read uses
-- telephony_call_started_idx (34) through cma.inbound_calls_of, and the primary key of cma.telephony_call.
--
-- Why (Martin, 10 November 2026; Decision log, 10 Nov 2026, Live board, Inbound today: Waiting now replaced by Talk
-- time): the telephony gives no usable live queue data, so the inbound tile Waiting now gives way to Talk time
-- (docs/definitions.md), in the column of Outbound today's Talk time.
--
-- What it adds
--   cma.inbound_today_live_of(p_tenant_id)
--                      the Live board's today of a tenant, one row: the fourteen columns cma.inbound_today_of (60)
--                      answers but longest_waiting_seconds, with the same values, and inbound_talk_seconds: the total
--                      Talk time of today's answered inbound calls on counted lines (0 without one), over the same calls
--                      as every other figure of the row: the calls started in the tenant's day (its zone's midnight to
--                      the next, Day; Martin, 10 November 2026). So it is Reports → Calls' talk time minus its outbound
--                      talk time for the date but for the calls whose day in their line's zone differs from the
--                      tenant's day (the line-zone date of cma.calls_of, gap D34 of docs/definitions.md): an answered
--                      call on a line west of the tenant (a line in London for a tenant in Amsterdam) between the
--                      tenant's midnight and the line's counts here today and in the report on the day before; one on a
--                      line east of it before the tenant's midnight counts in the report's date and here the day before.
--                      169 names such calls when they explain a difference. waiting_now counts as before (the calls
--                      waiting now, also before midnight), in the same read
--                      One pass: cma.inbound_calls_of once, from the earlier of the tenant's midnight and the waiting
--                      limit (now() less telephony.waiting_max_minutes), with no end; 60 read the calls twice, the day
--                      and then the calls waiting now, and this reads the calls those two read. Each call is marked in
--                      or out of the tenant's day; waiting_now counts every call read that is waiting (is_waiting holds
--                      the limit); the talk time of an answered call of the day is read by the primary key of
--                      cma.telephony_call (cma.inbound_calls_of does not return it), only for those calls (an
--                      aggregate's filter is evaluated before its argument), no second scan of the day. sql, stable,
--                      jit off, rows 1, the application's only
-- What it changes
--   cma.inbound_now()  (based on 164): today from cma.inbound_today_live_of instead of cma.inbound_today_of, so it gains
--                      the key inbound_talk_seconds; longest_waiting_seconds still always null, waiting_now as before;
--                      callbacks and summary, and every other key of today, as before (169 proves it against 164's
--                      definition). cma.inbound_today_of and cma.inbound_today (60) are not touched
--
-- SQLSTATEs as before: CMA01 no acting user, CMA06 not permitted.
--
-- Guard: scripts run under a personal IAM login so the audit trail names a person. postgres is
-- for emergencies only; to use it deliberately, run first:  set cma.emergency = 'on';
do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;

begin;
set local lock_timeout = '5s';
set role cma_owner;

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0009i') then
    raise exception 'addition 0009i (166_live_outbound_direct.sql) must run before 0009j';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Inbound today for the Live board, with Talk time
-- ---------------------------------------------------------------------------------------------
-- The expressions of cma.inbound_today_of (60) and the talk time over the calls of the tenant's day (in_day below), the
-- calls waiting now over every call read (inbound_calls_of's is_waiting holds the waiting limit itself, as 60's second
-- read used it). w: the tenant's day, and where the one read starts: the earlier of the tenant's midnight and the
-- waiting limit, with no end, so it holds both (no row when the tenant is not found, so nothing is read, as 60 answers no
-- row then); the calls are read once, laterally from w's one row, as 60 reads them from s
create or replace function cma.inbound_today_live_of(p_tenant_id uuid)
returns table (
  business_date            date,
  offered                  integer,
  answered                 integer,
  unanswered               integer,
  waiting                  integer,
  answered_within_target   integer,
  service_level_base       integer,
  service_level_pct        numeric,
  avg_answer_seconds       numeric,
  p80_answer_seconds       numeric,
  unanswered_by_reason     jsonb,
  waiting_now              integer,
  service_level_seconds    integer,
  waiting_max_minutes      integer,
  inbound_talk_seconds     bigint
)
language sql stable
rows 1
as $$
  with s as (
    select t.timezone as zone, (now() at time zone t.timezone)::date as today,
           greatest(0, cma.setting_of(t.id, 'telephony.service_level_seconds')::integer) as sl,
           greatest(0, cma.setting_of(t.id, 'telephony.waiting_max_minutes')::integer) as waiting_max
    from cma.tenant t where t.id = p_tenant_id
  ),
  w as (
    select s.today::timestamp at time zone s.zone as day_from, (s.today + 1)::timestamp at time zone s.zone as day_to,
           least(s.today::timestamp at time zone s.zone, now() - make_interval(mins => s.waiting_max)) as from_at
    from s
  ),
  c as (
    select x.*, (x.started_at >= w.day_from and x.started_at < w.day_to) as in_day
    from w
    cross join lateral cma.inbound_calls_of(p_tenant_id, w.from_at, null) x
  )
  select (select s.today from s),
         (count(*) filter (where c.in_day))::integer,
         (count(*) filter (where c.in_day and c.is_answered))::integer,
         (count(*) filter (where c.in_day and not c.is_answered and not c.is_waiting))::integer,
         (count(*) filter (where c.in_day and c.is_waiting))::integer,
         (count(*) filter (where c.in_day and c.is_answered and c.answer_seconds <= (select s.sl from s)))::integer,
         (count(*) filter (where c.in_day and c.in_service_level))::integer,
         round(100.0 * count(*) filter (where c.in_day and c.is_answered and c.answer_seconds <= (select s.sl from s))
               / nullif(count(*) filter (where c.in_day and c.in_service_level), 0), 1),
         round(avg(c.answer_seconds) filter (where c.in_day), 1),
         round((percentile_cont(0.8) within group (order by c.answer_seconds) filter (where c.in_day))::numeric, 1),
         coalesce((select jsonb_object_agg(u.code, u.n)
                   from (select r as code, count(*)::integer as n
                         from unnest(array_agg(c.reason_code) filter (where c.in_day and c.reason_code is not null)) r
                         group by r) u), '{}'::jsonb),
         -- waiting now: the calls waiting, also before midnight, as 60 counts them (is_waiting starts at the limit)
         (count(*) filter (where c.is_waiting))::integer,
         (select s.sl from s),
         (select s.waiting_max from s),
         -- Talk time (docs/definitions.md): of the answered calls of the tenant's day, as the row's other figures; one
         -- primary-key probe per such call, evaluated only for the rows the filter keeps
         coalesce(sum((select tc.talk_seconds from cma.telephony_call tc where tc.tenant_id = p_tenant_id and tc.id = c.call_id))
                  filter (where c.in_day and c.is_answered), 0)::bigint
  from c
  having (select s.today from s) is not null
$$;
-- jit off (night N06), as cma.inbound_calls_of and cma.outbound_today_of
alter function cma.inbound_today_live_of(uuid) set jit = off;

-- ---------------------------------------------------------------------------------------------
-- 2. Inbound now with today's Talk time
-- ---------------------------------------------------------------------------------------------
-- As 0009h (164): the same answer, today read from cma.inbound_today_live_of, so it holds inbound_talk_seconds too;
-- longest_waiting_seconds still always null and waiting_now as before (both kept until the migration Open decisions
-- names)
-- based on: 164_live_outbound.sql
create or replace function cma.inbound_now()
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
    'today', (select to_jsonb(x) || '{"longest_waiting_seconds": null}'::jsonb from cma.inbound_today_live_of(v_tenant) x),
    'callbacks', v_list,
    'summary', (select jsonb_build_object('listed', jsonb_array_length(v_list),
                                          'anonymous_count', cma.anonymous_missed_calls_of(v_tenant, now() - make_interval(days => s.lookback)),
                                          'lookback_days', s.lookback)
                from (select greatest(0, cma.setting_of(t.id, 'telephony.callback_lookback_days')::integer) as lookback
                      from cma.tenant t where t.id = v_tenant) s));
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. Grants, the addition
-- ---------------------------------------------------------------------------------------------
-- The application's only (a create or replace keeps a function's grants; said again for cma.inbound_now())
do $$
declare
  f text;
begin
  foreach f in array array['cma.inbound_today_live_of(uuid)', 'cma.inbound_now()'] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

insert into cma.schema_migration (version, description)
values ('0009j', 'Live board, Inbound today with Talk time: cma.inbound_today_live_of(tenant) answers cma.inbound_today_of''s figures of the tenant''s day (but longest_waiting_seconds) and inbound_talk_seconds, the talk time of the answered inbound calls on counted lines of the tenant''s day, as the row''s other figures (Reports → Calls'' talk time minus its outbound talk time but for calls whose line-zone day differs, gap D34), in one read of cma.inbound_calls_of; cma.inbound_now() (from 164) reads it, so today gains inbound_talk_seconds; waiting_now and longest_waiting_seconds (null) kept as they are for one release; everything else as before')
on conflict (version) do nothing;

commit;
reset role;
