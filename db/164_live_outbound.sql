-- =============================================================================================
-- 164_live_outbound.sql: addition 0009h, the Live board's Outbound today; the inbound figure Longest waiting leaves
-- cma.inbound_now()
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics: the thresholds are the tenant's settings
-- (telephony.connected_min_seconds, calls.conversation_min_talk_seconds), the lines, markets, zones and tag meanings its
-- catalogs. Runs unchanged in every database, after 162_remove_day.sql (0009g). Rerunnable, forward-only, in one
-- transaction with a lock timeout. Run as your own IAM login: dev first, then 165_verify_live_outbound.sql there, then
-- the verifies that read cma.inbound_now() again: 133_verify_perf.sql (unchanged, still PASS: its A5 reads today,
-- callbacks and summary, never the key that left) and 145_verify_held_kinds_restore.sql, which this change edits (its
-- A10 and E6 compare cma.inbound_now() with 0008zr's definition kept inside 145; that side now has the key
-- longest_waiting_seconds taken out of today before the comparison); then the merge; then prod right after the merge:
-- 164, then 133 and 145, without 165 unless Martin wants it there (it writes nothing that stays).
-- Either order of database and web works: main's web on a database with 164 reads no longest_waiting_seconds and shows
-- "Nobody waiting" on that tile; this branch's web on a database without 164 fails the Live board's read (the function
-- cma.outbound_now() does not exist), so 164 runs in prod before or right after the merge, before the build finishes.
-- No table, view, column or setting changes: the data map's schema does not change.
--
-- Why (Martin, 10 November 2026; Decision log, 10 Nov 2026, Live board: Outbound today): the Live board showed inbound
-- only; the outbound work of the day (Attempt, Connected, Connected rate, Conversation, Talk time of docs/definitions.md)
-- joins it as a row of six tiles, tenant-wide as the inbound call tiles of 5 Nov 2026. Longest waiting is removed: no
-- usable source in Pulse4all's telephony setup.
--
-- What it adds
--   cma.outbound_today_of(p_tenant_id, p_now default now())
--                      today's outbound figures of a tenant, one row: business_date (p_now's date in the tenant's zone),
--                      attempts (the outbound calls, Attempt), connected (Connected, cma.is_connected through
--                      cma.calls_of), connected_rate (connected of attempts in percent, one decimal; null without an
--                      attempt), conversations (the outbound calls that are a Conversation, cma.is_conversation through
--                      cma.calls_of), outbound_talk_seconds (the talk time of the connected calls, 0 without one) and
--                      outbound_talk_avg (its average over the connected calls with talk time, one decimal; null
--                      without one). Today is Day: the calls whose business date in their own line's zone (the line's
--                      market's, else the tenant's) is that date, read from cma.calls_of over the instants the date covers
--                      in the tenant's zones and counted as cma.calls_figures_of (100) counts a day, so the figures
--                      equal Reports → Calls for today
--                      (outbound, connected, connected_rate, outbound_talk_seconds, outbound_talk_avg). Counted lines
--                      only (cma.calls_of), every line of the tenant. p_now is now() for the application; a verifier
--                      gives a fixed instant (as cma.calls_overview_of). The zone and the date as scalar subqueries
--                      (night N06). jit off, rows 1
--   cma.outbound_now() the Live board's read (monitoring.live, CMA06 without it): cma.outbound_today_of of the caller's
--                      tenant as JSON (business_date, attempts, connected, connected_rate, conversations,
--                      outbound_talk_seconds, outbound_talk_avg). language sql stable, jit off
-- What it changes
--   cma.inbound_now()  (based on 144): today without the key longest_waiting_seconds; callbacks and summary, and every
--                      other key of today, as before. cma.inbound_today_of and cma.inbound_today (60) are not touched:
--                      they keep the column for whoever reads them; the web no longer maps it
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
  if not exists (select 1 from cma.schema_migration where version = '0009g') then
    raise exception 'addition 0009g (162_remove_day.sql) must run before 0009h';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Outbound today
-- ---------------------------------------------------------------------------------------------
-- The same calls and the same expressions as cma.calls_figures_of (100) for the one date. That function reads a day on
-- each side of a period; this one is a poll, so it reads only the instants the date covers in the tenant's zones (w
-- below), which holds every call of the date and, for a tenant in one zone, nothing else. The date and the window as
-- scalar subqueries, never a joined one-row relation (night N06)
create or replace function cma.outbound_today_of(p_tenant_id uuid, p_now timestamptz default now())
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
alter function cma.outbound_today_of(uuid, timestamptz) set jit = off;

-- The Live board's read: the permission first, then the caller's tenant's row as JSON
create or replace function cma.outbound_now()
returns jsonb
language sql stable
as $$
  select cma.assert_permission('monitoring.live');
  select to_jsonb(x) from cma.outbound_today_of(cma.current_tenant_id(), now()) x;
$$;
alter function cma.outbound_now() set jit = off;

-- ---------------------------------------------------------------------------------------------
-- 2. Inbound now without Longest waiting
-- ---------------------------------------------------------------------------------------------
-- As 0008zx (144): the same answer, today without the key longest_waiting_seconds
-- based on: 144_held_kinds_restore.sql
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
    'today', (select to_jsonb(x) - 'longest_waiting_seconds' from cma.inbound_today_of(v_tenant) x),
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
  foreach f in array array[
    'cma.outbound_today_of(uuid,timestamptz)', 'cma.outbound_now()', 'cma.inbound_now()'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

insert into cma.schema_migration (version, description)
values ('0009h', 'Live board, Outbound today: cma.outbound_today_of(tenant, now) and cma.outbound_now() (monitoring.live) answer today''s attempts, connected, connected rate, outbound conversations and the talk time of the connected calls in all and on average, from cma.calls_of for the calls whose business date in their line''s zone is the tenant''s date, as cma.calls_figures_of counts them; cma.inbound_now() (from 144) answers today without longest_waiting_seconds, everything else as before')
on conflict (version) do nothing;

commit;
reset role;
