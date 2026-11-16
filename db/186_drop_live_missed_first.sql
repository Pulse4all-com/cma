-- =============================================================================================
-- 186_drop_live_missed_first.sql: addition 0009s, reverses addition 0009q (cma.inbound_now_first dropped)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after 184_active_device_bands.sql
-- (0009r; the brief named this script 185 and its verify 186; 184 and 185 were taken by addition 0009r, so they are 186
-- and 187). Rerunnable,
-- forward-only, in one transaction with a lock timeout. Run as your own IAM login: dev first, then
-- 187_verify_live_missed_first_dropped.sql there (normal, then provoked), then prod the same way. No function is
-- re-created and no table, view, column or index changes, so no other verify is run again: cma.inbound_now() stays
-- exactly as 170_live_inbound_talk.sql left it (133, 145, 165, 171 and 187 read it and are not touched). 183 reads the
-- dropped function: after this script it reads FAIL (42883) and is never run again; 187 takes its place. The web of main never
-- called cma.inbound_now_first (#270 was closed unmerged), so nothing the app runs changes, before or after the merge.
--
-- Why (Martin, 16 November 2026; Decision log): addition 0009q (182_live_missed_first.sql, #270) added
-- cma.inbound_now_first(first), so the Live board's poll would read the oldest twenty missed callers and their count
-- instead of every caller. It ran in dev and prod on 14 November 2026 (records/0009q-dev-2026-11-14,
-- records/0009q-prod-2026-11-14), but the web that calls it was never merged. tools/perf/live-poll-breakdown.sql in prod
-- on Monday 16 November 2026 at 08:48 UTC, office hours, with the Live board in use (20 callers listed, 30 distinct in
-- the 3-day lookback), read medians, planned at each call, of 4.8 ms for main's board poll (L1), 4.0 ms for
-- cma.inbound_now() (I4), 4.3 ms for cma.inbound_now_first(20) (N1) and 4.9 ms for every caller (N2), Team now as the
-- page reads it 8.6 ms (T2), cma.roster_today() 3.9 ms (R1): every poll well under its 20 ms, and the first twenty
-- gain nothing at today's list length (9,976 against 10,016 characters). Martin closed #270 unmerged and reverses 0009q.
--
-- What it does
--   drop   cma.inbound_now_first(integer), where it exists (with it its grant to cma_app)
--   record addition 0009s; 0009q's own row stays, as the history of what ran. On a database where 0009q never ran the
--          drop does nothing and 0009s is recorded all the same, so every database ends at the same place
-- What it leaves: cma.inbound_now(), exactly as it is, the Live board's read.
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
  if not exists (select 1 from cma.schema_migration where version = '0009r') then
    raise exception 'addition 0009r (184_active_device_bands.sql) has not run in this database';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The first missed callers' read, gone
-- ---------------------------------------------------------------------------------------------
drop function if exists cma.inbound_now_first(integer);

-- ---------------------------------------------------------------------------------------------
-- 2. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009s', 'Reverses addition 0009q: cma.inbound_now_first(integer) dropped, #270 closed unmerged; the Live board keeps reading cma.inbound_now(), unchanged. Measured in prod on 16 November 2026, 08:48 UTC, office hours (tools/perf/live-poll-breakdown.sql): 20 callers listed, medians of 4.8 ms for the board''s poll, 4.0 ms for cma.inbound_now() and 4.3 ms for the first twenty, 9,976 against 10,016 characters: nothing gained at today''s list length. 0009q''s row stays as the record of what ran')
on conflict (version) do nothing;

commit;
reset role;
