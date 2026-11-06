-- =============================================================================================
-- 152_calls_of_restore.sql: addition 0009b, cma.calls_of counts Connected and Conversation by 0008zc's rule again
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after 148_installed_base_list.sql
-- (0008zz). It does not depend on 150_courtesy.sql (0009a): either can run first. Rerunnable, forward-only, in one
-- transaction with a lock timeout. Run as your own IAM login: dev first (this script, then 153_verify_calls_of_restore.sql,
-- then the verifies that read cma.calls_of again: 101_verify_definitions_calls.sql, 103_verify_tag_meaning_incorrect_data.sql,
-- 63_verify_calls_overview.sql, 65_verify_calls_history_start.sql, 77_verify_audit_hardening.sql (those five in dev only)
-- and 133_verify_perf.sql as edited by this change), then prod in the same order without the five dev-only verifies,
-- then 131_time_all.sql parts b and c in prod (the Calls and Calls per agent reads over the previous month and 92 days,
-- against the 500 ms report budget: 0008zr's figures were taken on the cheaper, wrong rule).
-- No table, view, column or setting changes, no seed need run again, and nothing stored needs computing again: every
-- reader of cma.calls_of computes when read. The web and the ingest of main run unchanged on it (the function keeps its
-- name, arguments and columns).
--
-- Why (Decision log, 6 November 2026): 132_perf.sql (0008zr) made cma.calls_of again from the definition of
-- 76_audit_hardening.sql (0008q), not from the latest one before it, 100_definitions_calls.sql's (0008zc). Since 0008zr
-- ran (dev and prod, 6 November 2026) a call is connected when outbound with telephony.connected_min_seconds of talk (0
-- since 0008zc, so every outbound call with any talk time, answered or not), and every answered inbound or connected
-- outbound call is a conversation, whatever its talk time and its tags: the rule 0008zc retired (docs/definitions.md,
-- Connected and Conversation). Reports → Calls and Calls per agent (the overview, tag use, per person, tags per person,
-- their CSV files and /api/v1/reports/calls*) counted Connected, its rate, Conversations and the tag use's
-- conversations by it. 133_verify_perf.sql compared the rewrite with 76's definition too, so the two agreed; verify 101
-- (A5, B1 to B4) and 103 (B1, B2) found it. 0008zx (144) restored cma.connection_held_kinds_of for the same cause.
--
-- The sweep (every function 132 creates, against the latest definition before it in run order, any file name):
--   logic lost       cma.calls_of (base 100, rebuilt from 76): restored here
--                    cma.connection_held_kinds_of (base 118, rebuilt from 70): restored by 0008zx (144), complete
--   perf-only        cma.system_health_runs (78), cma.missed_callbacks_of (60), cma.inbound_calls_of (76),
--                    cma.intake_per_day_of (74), cma.open_tickets_of (72), cma.open_tasks_of (72): the same answers;
--                    the last three with the market and owner lookups as joins on unique keys
--                    cma.data_quality, cma.data_quality_rows, cma.flash_findings_of (122): read the stored findings, which
--                    cma.flash_findings_compute_of computes as 122's cma.flash_findings_of did (its text under a new name)
--   the same, and    cma.ensure_scheduler_user, cma.job_permission_of, cma.job_run_start (122): the job refresh_data_quality
--   one addition     and its permission added, nothing else changed
--   new in 132       cma.inbound_now (60's three reads in one), cma.market_codes_of, cma.check_data_quality_setting,
--                    cma.data_quality_lock_key, cma.refresh_data_quality_of, cma.refresh_data_quality,
--                    cma.data_quality_snapshot_of, cma.data_quality_computed_at
--   144's versions   cma.connection_held_kinds_of (118's six kinds, 0008zr's form), cma.inbound_calls_of,
--                    cma.missed_callbacks_of, cma.inbound_now (0008zr's answers, 145 proves it): complete
--   later            cma.data_quality was made again by 136 (0008zt) from 132's definition: complete
--
-- What it changes: cma.calls_of(tenant, from, to, market, line) as 0008zc defined it (Connected by cma.is_connected,
-- Conversation by cma.is_conversation, both fed telephony.connected_min_seconds and calls.conversation_min_talk_seconds,
-- and a current tag that keeps a call from being a conversation by cma.call_not_reached_of, which 0008zd extended to
-- incorrect_data), in 0008zr's form: the tenant's current tags grouped per call once and joined, the tenant's zone and
-- settings as scalar subqueries. Two choices for speed, each giving 0008zc's answer (153 compares it with 100's text,
-- kept inside it, row for row):
--   - the call set is kept apart (offset 0): pulled up into the outer query, the settings' scalar subqueries arrived at
--     cma.is_connected as arguments still unplanned, and a helper whose argument is one is not inlined, so the helper
--     ran as a function call twice per call (990 ms against 610 for 30 days at three times prod's volume)
--   - cma.call_not_reached_of is asked only for a call with a current tag (a call without one carries none that keeps it
--     from being a conversation, the helper's own rule): 520 ms against 610 for 30 days, 880 against 1,100 for 92 days,
--     with a tag on a tenth of the calls (web/verify/perf-volume-fixture.sql); 0008zr's wrong rule took 440 and 710
-- Measured locally on PostgreSQL 16, as the application, eight calls per session, three times prod's volume
-- (web/verify/perf-volume-fixture.sql, 99,000 calls in 30 days, 198,000 in 92). The plan setting jit off is repeated:
-- a create or replace drops a function's settings (CLAUDE.md, Performance).
-- SQLSTATEs: none raised but the guards'.
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
  if not exists (select 1 from cma.schema_migration where version = '0008zz') then
    raise exception 'addition 0008zz (148_installed_base_list.sql) must run before 0009b';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The calls of Reports → Calls and Calls per agent, by 0008zc's rule
-- ---------------------------------------------------------------------------------------------
-- 0008zr's (132) definition, the latest before this one, with 0008zc's (100) rule put back: the same rows and columns;
-- Connected and Conversation by the helpers, the thresholds from the tenant's settings. 0008zr's form kept: the current
-- tags grouped per call once and joined; the zone and the settings as scalar subqueries. Added for speed: the call set
-- kept apart (offset 0) so the helpers are inlined; the not-reached helper asked for a call with a current tag only
-- based on: 132_perf.sql
create or replace function cma.calls_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz, p_market text, p_line text)
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
    -- the tenant's zone and settings as scalar subqueries (evaluated once), never a joined relation: planned with
    -- parameters, a joined one-row relation ends up as the inner side of a loop run once per call (night N06); offset 0
    -- keeps this set apart, so the outer query reads the thresholds as columns and inlines the helpers
    select tc.connection_id, tc.source_system, tc.direction, tc.source_id, tc.started_at, tc.answered_at, tc.talk_seconds,
           tc.user_ref, tc.connection_id::text || ':' || coalesce(tc.number_ref, '') as lk,
           coalesce(n.name, tc.number_ref) as ln, coalesce(m.code, 'unknown') as mk, coalesce(m.time_zone, (select s.tenant_zone from s)) as z,
           (select s.connected_min from s) as connected_min, (select s.conversation_min from s) as conversation_min
    from cma.telephony_call tc
    left join cma.telephony_number n
      on n.tenant_id = tc.tenant_id and n.connection_id = tc.connection_id and n.number_ref = tc.number_ref
    left join cma.market m on m.tenant_id = tc.tenant_id and m.code = n.market
    where tc.tenant_id = p_tenant_id
      and tc.source_deleted_at is null
      and tc.started_at is not null
      and coalesce(n.is_counted, true)
      and tc.started_at >= coalesce(p_from, '-infinity'::timestamptz)
      and tc.started_at < coalesce(p_to, 'infinity'::timestamptz)
    offset 0
  ),
  tg as (
    select ct.connection_id, ct.call_source_id, array_agg(ct.tag_ref order by ct.tag_ref) as refs
    from cma.telephony_call_tag ct
    where ct.tenant_id = p_tenant_id and ct.untagged_at is null
    group by ct.connection_id, ct.call_source_id
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
  left join tg on tg.connection_id = c.connection_id and tg.call_source_id = c.source_id
  -- a call without a current tag carries none that keeps it from being a conversation
  cross join lateral (
    select case when tg.refs is null then false
                else (select x.not_reached from cma.call_not_reached_of(p_tenant_id, c.connection_id, c.source_id) x) end as not_reached) nr
  where (p_market is null or c.mk = p_market)
    and (p_line is null or c.lk = p_line)
$$;
alter function cma.calls_of(uuid, timestamptz, timestamptz, text, text) set jit = off;

-- ---------------------------------------------------------------------------------------------
-- 2. Grants, the addition
-- ---------------------------------------------------------------------------------------------
-- The application's only, as before (a create or replace keeps a function's grants; said again here)
revoke execute on function cma.calls_of(uuid, timestamptz, timestamptz, text, text) from public;
grant execute on function cma.calls_of(uuid, timestamptz, timestamptz, text, text) to cma_app;

insert into cma.schema_migration (version, description)
values ('0009b', 'cma.calls_of counts Connected and Conversation by 0008zc''s rule again (cma.is_connected, cma.is_conversation, cma.call_not_reached_of with telephony.connected_min_seconds and calls.conversation_min_talk_seconds), which 0008zr had rebuilt from 0008q''s definition and lost, in 0008zr''s form (the current tags grouped per call once and joined); the same name, arguments and columns; 153 proves it against 0008zc''s definition')
on conflict (version) do nothing;

commit;
reset role;
