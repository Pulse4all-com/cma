-- =============================================================================================
-- 252_lead_cohorts_jit.sql: addition 0009zz, Lead cohorts' read without JIT compilation
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics; a function setting only. Runs unchanged in every database, after
-- 120_lead_cohorts.sql (0008zm), the only addition it needs. Rerunnable, forward-only, in one transaction with a lock
-- timeout. Run as your own IAM login: dev first, then 253_verify_lead_cohorts_jit.sql there (normal, then provoked), then
-- 121_verify_lead_cohorts.sql (dev only; still PASS, not edited). Prod the same after the merge, without 121.
--
-- Why (Martin, 26 November 2026): Reports -> Sales -> Lead cohorts shows "This page could not be loaded" in prod. The
-- request log has every navigation at dbMs 15,036 to 15,043.5 (25 and 26 November): the application's statement timeout
-- (CMA_DB_STATEMENT_TIMEOUT_MS, 15 s) cancels cma.lead_cohorts_report. The read inlines cma.lead_cohorts_of with its
-- whole tree (cma.lead_to_order_of, cma.sales_deals_of, cma.deal_attempts_of per deal, cma.contact_store_orders_of)
-- into one statement that the planner costs at about 21.8 million. Above jit_above_cost, jit_optimize_above_cost and
-- jit_inline_above_cost Postgres compiles the statement with LLVM, inlining and optimising some 490 functions, before
-- it reads a row; the compilation is CPU work, and prod has one vCPU. The answers do not depend on it.
--
-- Measured locally on web/verify/perf-volume-fixture.sql (three times prod's volume, the subscriptions tenant, the
-- page's default span of the last twelve ISO weeks, PostgreSQL 16 with a uuidv7() shim, Postgres held to one CPU with
-- taskset on the postmaster, as the application: cma_app, a prepared statement, seven calls in one session):
--   cma.lead_cohorts_report, JIT as configured     4,499 to 5,700 ms per call (the seventh 5,201 ms)
--   the same with jit off                          1,058 to 1,216 ms per call (the seventh 1,058 ms)
--   EXPLAIN ANALYZE of cma.lead_cohorts_of: JIT 487 functions, generation 19 ms, inlining 27 ms, optimisation 1,950 ms,
--   emission 1,391 ms, 3,388 ms of 4,640 ms; the reads themselves about 1.1 s
-- A set-based rewrite of the attempts (every deal joined to its CRM calls through cma.crm_association at once, in place
-- of cma.deal_attempts_of per deal) gave the same 13,792 rows, row for row, and measured 1,032 -> 932 ms with jit off:
-- not taken, the setting alone removes the timeout and keeps every definition as it is.
--
-- What it changes
--   cma.lead_cohort_rows_of(uuid, date, date, timestamptz)
--                      120's function, definition unchanged: set jit = off. It is the one statement of the page that
--                      inlines the cohorts' tree (its execute with the tenant, the bounds and the instant as literals);
--                      the setting holds for that statement and returns to the caller's value afterwards. The pattern
--                      of 134 (cma.team_hours, cma.team_now) and 178 (the jobs' reads). A later create or replace of
--                      this function drops the setting: the script that re-creates it repeats this alter.
--
-- Not touched: cma.lead_cohorts_of keeps no setting, so the execute still inlines it and plans it for the tenant and the
-- span (a set clause would stop the inlining). cma_read.lead_cohort_rows() (the readers' view, unbounded, every
-- tenant) keeps 120's settings: 121's A2 checks that its configuration ends with its search path. No table, view or
-- column changes (the data map is unchanged); no web change (the page reads cma.lead_cohorts_report as before, one
-- statement). The other report reads that call cma.deal_attempts_of per deal (cma.attempts_rows_of, Attempts per deal)
-- are not measured here.
--
-- SQLSTATEs as before: CMA01 no acting user, CMA04 invalid, CMA06 not permitted.
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
  if not exists (select 1 from cma.schema_migration where version = '0008zm') then
    raise exception 'addition 0008zm (120_lead_cohorts.sql) must run before 0009zz';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The cohorts' statement without JIT
-- ---------------------------------------------------------------------------------------------
alter function cma.lead_cohort_rows_of(uuid, date, date, timestamptz) set jit = off;

comment on function cma.lead_cohort_rows_of(uuid, date, date, timestamptz) is
  'The lead deals of the business dates [p_from, p_to] in the tenant''s zone in one pass (0008zm): cma.lead_cohorts_of with the tenant, the bounds and the instant as literals, so it is inlined and planned for this tenant and span. jit off (0009zz): the inlined tree costs above every JIT threshold, and compiling it took longer than the read (Lead cohorts timed out in prod); a create or replace drops the setting, so the script that re-creates this function repeats the alter';

insert into cma.schema_migration (version, description)
values ('0009zz', 'Lead cohorts without JIT: cma.lead_cohort_rows_of set jit = off (definition unchanged), so the cohorts'' inlined statement is no longer compiled with LLVM before it reads; the page timed out at the application''s 15 s statement timeout in prod')
on conflict (version) do nothing;

commit;
reset role;
