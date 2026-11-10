-- =============================================================================================
-- 166_live_outbound_direct.sql: addition 0009i, the Live board's Outbound today read from cma.telephony_call directly
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics: the thresholds are the tenant's settings
-- (telephony.connected_min_seconds, calls.conversation_min_talk_seconds), the lines, markets, zones and tag meanings its
-- catalogs. Runs unchanged in every database, after 164_live_outbound.sql (0009h). Rerunnable, forward-only, in one
-- transaction with a lock timeout. Run as your own IAM login, in dev and in prod before the merge of #260: main's web
-- does not call cma.outbound_now() or cma.outbound_today_of, so nothing running reads the function this script makes
-- again. Dev: 166, then 167_verify_live_outbound_direct.sql, then 165_verify_live_outbound.sql again (it reads
-- cma.outbound_today_of: unchanged, still PASS; its B2 and B3 pin the figures to cma.calls_figures_of and
-- cma.is_conversation), then 131_time_all.sql part a. Prod: 166, 167, 131 part a. Then the merge.
-- No table, view, column or setting changes: the data map's schema does not change. No index is added: the read uses
-- telephony_call_started_idx (34) and telephony_call_tag_current_idx (34).
--
-- Why (Martin, 10 November 2026; Decision log, 10 Nov 2026, Outbound today reads cma.telephony_call directly): in prod
-- cma.outbound_now() took 28.2 ms against the poll's 20 ms (tools/perf/outbound-explain.sql, 10 November 2026): 164 read
-- cma.calls_of, which groups every current tag of the tenant whatever the window and classifies both directions, and
-- whose generic plan is nine times its custom plan (Open decisions). The direct read below took 3 to 5 ms there, with
-- the same answer.
--
-- What it changes
--   cma.outbound_today_of(p_tenant_id, p_now default now())  (based on 164): the same seven columns and the same
--                      answer: today's outbound calls read from cma.telephony_call, not through cma.calls_of: not
--                      deleted, with a start, on a counted line (a line not in the catalog counts), started within the
--                      instants the tenant's date covers in the tenant's zones and dated that date in their own line's
--                      zone (the line's market's, else the tenant's: cma.calls_of's rule, the gap docs/definitions.md
--                      lists under Day, D34); Connected by cma.is_connected and Conversation by cma.is_conversation
--                      with the tenant's two settings; a current tag whose meaning excludes a Conversation by
--                      cma.call_not_reached_of's own exists() (cma.tag_meaning_excludes_conversation), one index probe
--                      per call. sql, stable, jit off, rows 1, the application's only, as 164
--   cma.outbound_now() is not touched: it reads cma.outbound_today_of
-- Two reads now hold the calls rule for a day: cma.calls_of (Reports → Calls) and this one. 167 compares this one row
-- for row with 164's cma.calls_of version, kept there as a temporary function, and 165's B2 and B3 pin it to
-- cma.calls_figures_of and cma.is_conversation: a change to cma.calls_of's rule that this read does not follow fails
-- 165 (CLAUDE.md: a migration that re-creates cma.calls_of reruns the verifies of its callers; 165 and 167 are run with
-- them from now on).
--
-- SQLSTATEs as before.
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
  if not exists (select 1 from cma.schema_migration where version = '0009h') then
    raise exception 'addition 0009h (164_live_outbound.sql) must run before 0009i';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Outbound today, read directly
-- ---------------------------------------------------------------------------------------------
-- As 0009h (164): the same columns and the same answer, without cma.calls_of
-- based on: 164_live_outbound.sql
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
    select t.timezone as zone, (p_now at time zone t.timezone)::date as today,
           greatest(0, cma.setting_of(t.id, 'telephony.connected_min_seconds')::integer) as connected_min,
           greatest(0, cma.setting_of(t.id, 'calls.conversation_min_talk_seconds')::integer) as conversation_min
    from cma.tenant t where t.id = p_tenant_id
  ),
  w as (
    select min(s.today::timestamp at time zone z.zone) as from_at, max((s.today + 1)::timestamp at time zone z.zone) as to_at
    from s
    cross join lateral (select s.zone
                        union
                        select m.time_zone from cma.market m where m.tenant_id = p_tenant_id and m.time_zone is not null) z
  ),
  c as (
    -- the calls cma.calls_of (152) returns for the window, the outbound ones of the date only: the same counted-lines
    -- rule, the same zone per call (the line's market's, else the tenant's), the bounds and the settings as scalar
    -- subqueries (an index on started_at under row-level security, in a generic plan too); offset 0 keeps the set apart,
    -- so the helpers below are inlined on its columns
    select tc.connection_id, tc.source_id, tc.answered_at, tc.talk_seconds,
           (select s.connected_min from s) as connected_min, (select s.conversation_min from s) as conversation_min
    from cma.telephony_call tc
    left join cma.telephony_number n
      on n.tenant_id = tc.tenant_id and n.connection_id = tc.connection_id and n.number_ref = tc.number_ref
    left join cma.market m on m.tenant_id = tc.tenant_id and m.code = n.market
    where tc.tenant_id = p_tenant_id
      and tc.direction = 'outbound'
      and tc.source_deleted_at is null
      and tc.started_at is not null
      and coalesce(n.is_counted, true)
      and tc.started_at >= (select w.from_at from w)
      and tc.started_at < (select w.to_at from w)
      and (tc.started_at at time zone coalesce(m.time_zone, (select s.zone from s)))::date = (select s.today from s)
    offset 0
  )
  select (select s.today from s) as business_date,
         count(*)::integer as attempts,
         (count(*) filter (where k.connected))::integer as connected,
         round(100.0 * count(*) filter (where k.connected) / nullif(count(*), 0), 1) as connected_rate,
         (count(*) filter (where cma.is_conversation('outbound', c.answered_at is not null, c.talk_seconds, c.connected_min,
                                                     c.conversation_min, nr.not_reached)))::integer as conversations,
         coalesce(sum(c.talk_seconds) filter (where k.connected), 0)::bigint as outbound_talk_seconds,
         round(avg(c.talk_seconds) filter (where k.connected), 1) as outbound_talk_avg
  from c
  cross join lateral (
    select cma.is_connected('outbound', c.answered_at is not null, c.talk_seconds, c.connected_min) as connected) k
  -- cma.call_not_reached_of's own exists() (102): one probe of telephony_call_tag_current_idx per call, the meanings by
  -- cma.tag_meaning_excludes_conversation, the one place that names them
  cross join lateral (
    select exists (select 1
                   from cma.telephony_call_tag ct
                   join cma.telephony_tag tg
                     on tg.tenant_id = ct.tenant_id and tg.connection_id = ct.connection_id and tg.tag_ref = ct.tag_ref
                   where ct.tenant_id = p_tenant_id and ct.connection_id = c.connection_id and ct.call_source_id = c.source_id
                     and ct.untagged_at is null and cma.tag_meaning_excludes_conversation(tg.meaning)) as not_reached) nr
$$;
-- a create or replace drops the function's settings: jit off said again (night N06); the grants are said again below
alter function cma.outbound_today_of(uuid, timestamptz) set jit = off;

-- ---------------------------------------------------------------------------------------------
-- 2. Grants, the addition
-- ---------------------------------------------------------------------------------------------
revoke execute on function cma.outbound_today_of(uuid, timestamptz) from public;
grant execute on function cma.outbound_today_of(uuid, timestamptz) to cma_app;

insert into cma.schema_migration (version, description)
values ('0009i', 'Live board, Outbound today read directly: cma.outbound_today_of (from 164) reads today''s outbound calls from cma.telephony_call (counted lines, each call''s date in its line''s zone, Connected and Conversation by cma.is_connected and cma.is_conversation, the tag meanings by one index probe per call), not through cma.calls_of: the same columns and the same answer (167 proves it against 164''s definition), within the poll''s budget in prod')
on conflict (version) do nothing;

commit;
reset role;
