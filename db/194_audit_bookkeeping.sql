-- =============================================================================================
-- 194_audit_bookkeeping.sql: addition 0009w, prod's slowdown part 1: statements measured, the bookkeeping no longer
-- audited, audit_log's statistics kept fresh
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after 192_fleet_page.sql (0009v).
-- Rerunnable, forward-only, in one transaction with a lock timeout. Run as your own IAM login: dev first, then
-- 195_verify_audit_bookkeeping.sql there (normal, then provoked), the verifies below, then prod the same way before the
-- merge of its pull request, outside office hours (the ANALYZE of audit_log reads up to 30,000 of its pages, and sections 3
-- and 4 take an ACCESS EXCLUSIVE lock on connection_form, connection_form_field, connection_stage, sync_cursor, ingest_event
-- and sync_run for the rest of the transaction: a reader of those tables, the follow-up job among them, waits for the
-- commit, at most the 5 s lock timeout per table).
-- No function is re-created and no table, view or column changes; main's web and the ingest run unchanged on it.
-- Verifies this change edits, to run again (dev; prod where they already run there):
--   31_verify_ingest_crm_records.sql   its structure check no longer asks an audit trigger on ingest_event once 0009w is
--                                      recorded
--   33_verify_intake_core.sql          the same for sync_cursor and sync_run
--   77_verify_audit_hardening.sql      B5: an ingest event's audit images carry no payload, and since 0009w there are none
--   179_verify_job_reads.sql           S6: every input table of the follow-up is audited on insert, update and delete by
--                                      enabled triggers running cma.audit_row() (connection_stage's update by audit_change),
--                                      no longer only by a trigger named audit
-- A verify that reads the triggers kept and runs unchanged: 75_verify_forms_reporting.sql (connection_form_field keeps a
-- trigger named audit). Run it again in dev. Local fixture edited: web/verify/perf-volume-fixture.sql no longer disables
-- and enables the audit trigger of ingest_event and sync_run, which have none.
--
-- Why (Martin, 17 November 2026; Decision log, 17 Nov 2026; evidence records/perf-prod-2026-11-16/prod-slowdown-diagnosis.txt,
-- #289): audit_log is 10 GB, 89 % of the database, and grows by about 200,000 rows (260 MB) a day. Most of them record the
-- system's own work, not a change anyone would look up: sync_cursor 70,000 a day, ingest_event 54,000, sync_run 27,000
-- (and 11,500 for the second tenant), connection_form_field 12,700, connection_form 2,800, connection_stage 1,500. The
-- planner's estimate for every day of audit_log since 14 November is 1 row: its last analyze was 91 hours old, 9.3 % of
-- the rows modified, under autovacuum's 10 % trigger, which on a table of 7.7 million rows waits for 770,000. And the
-- statements behind the full scans cannot be named: pg_stat_statements is loaded (pg_stat_statements.track = top) but the
-- extension was never created in the database.
--
-- What it does
--   1. pg_stat_statements      create extension if not exists, in schema public (the database's search_path starts with
--                              cma, cma_owner's schema, where it would otherwise land), under your own login (Cloud SQL
--                              lets cloudsqlsuperuser create it), and grant pg_read_all_stats to cma_owner, the role the diagnosis tool
--                              (tools/perf/prod-slowdown-diagnosis.sql, section 5) switches to, so it reads every login's
--                              statement texts, not <insufficient privilege>. Each in its own subtransaction: where the
--                              login may not, the script says so in a NOTICE and goes on; the pull request's Studio step
--                              as postgres does it instead (as 00_roles.sql, the one other step that needs postgres)
--   2. audit_log's statistics  autovacuum_analyze_scale_factor 0 and autovacuum_analyze_threshold 40,000: autoanalyze after
--                              about 40,000 changed rows, whatever the table's size (about every two days at the
--                              estimated 20,000 audit rows a day after section 4);
--                              autovacuum_vacuum_insert_scale_factor 0 and autovacuum_vacuum_insert_threshold 40,000:
--                              insert vacuum at the same pace, so the visibility map stays current. One ANALYZE now
--   3. configuration caches    connection_form, connection_form_field and connection_stage hold what a person sets
--                              (counted, polled, lead source, market, category, kept fields, a stage's outcome and its
--                              read times) next to what the source's refresh writes: audited as before for an insert,
--                              a delete and every update that changes anything, but no longer for an update that only
--                              moves the refresh's own times (refreshed_at, fields_refreshed_at, updated_at). Two
--                              triggers: audit (after insert or delete, as cma.setup_tenant_table makes it) and
--                              audit_change (after update, when the row without those times differs). A column added
--                              later is audited by default (the times are named, not the rest)
--   4. bookkeeping             no audit trigger on sync_cursor, sync_run and ingest_event: rows of the system's own work
--                              (where a stream stands, each job's run, each event received and its processing), kept
--                              in the tables themselves. The ingest (ingest.write) and the scheduler write them; the one
--                              person's path is a device file load (cma.load_device_snapshot, tenant.configure, 114),
--                              whose sync_run row keeps the person in started_by and cannot be changed once finished
--                              (cma.check_sync_run, 32), and whose devices stay audited. The application may delete
--                              none of the three (32, 30). As data_quality_snapshot,
--                              flash_current_take and follow_up_item before them. Existing audit rows stay (their
--                              retention is CMA-112)
--
-- Re-running cma.setup_tenant_table() on one of these six tables puts its old trigger audit back (insert, update and
-- delete): next to audit_change on section 3's, every update audited twice; on section 4's, the bookkeeping audited again.
-- A later migration that calls it there repeats this script's section 3 or 4 for that table.
--
-- SQLSTATEs: none new.
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

-- ---------------------------------------------------------------------------------------------
-- 1. pg_stat_statements, under your own login (before set role: cma_owner may create no extension)
-- ---------------------------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_stat_statements') then
    raise notice 'pg_stat_statements: installed already';
  else
    begin
      create extension if not exists pg_stat_statements with schema public;
      raise notice 'pg_stat_statements: created';
    exception when insufficient_privilege or feature_not_supported or object_not_in_prerequisite_state then
      raise notice 'pg_stat_statements: this login may not create it (%: %); the pull request''s Studio step as postgres does', sqlstate, sqlerrm;
    end;
  end if;
  if pg_has_role('cma_owner', 'pg_read_all_stats', 'member') then
    raise notice 'pg_read_all_stats: cma_owner holds it already';
  else
    begin
      grant pg_read_all_stats to cma_owner;
      raise notice 'pg_read_all_stats: granted to cma_owner';
    exception when insufficient_privilege or invalid_grant_operation then
      raise notice 'pg_read_all_stats: this login may not grant it (%: %); the pull request''s Studio step as postgres does', sqlstate, sqlerrm;
    end;
  end if;
end
$$;

set role cma_owner;

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0009v') then
    raise exception 'addition 0009v (192_fleet_page.sql) has not run in this database';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. audit_log's statistics: autoanalyze and insert vacuum after about 40,000 rows, then one analyze now
-- ---------------------------------------------------------------------------------------------
-- A storage parameter takes SHARE UPDATE EXCLUSIVE: the triggers' inserts go on; only another vacuum, analyze or
-- schema change of audit_log waits
alter table cma.audit_log set (autovacuum_analyze_scale_factor = 0, autovacuum_analyze_threshold = 40000,
                               autovacuum_vacuum_insert_scale_factor = 0, autovacuum_vacuum_insert_threshold = 40000);
-- A sample of 30,000 rows (default_statistics_target 100): at most 30,000 of its pages read, whatever its size
analyze cma.audit_log;

-- ---------------------------------------------------------------------------------------------
-- 3. The configuration caches: every real change audited, the refresh's own times not
-- ---------------------------------------------------------------------------------------------
drop trigger if exists audit on cma.connection_form;
create trigger audit after insert or delete on cma.connection_form
  for each row execute function cma.audit_row();
drop trigger if exists audit_change on cma.connection_form;
create trigger audit_change after update on cma.connection_form
  for each row
  when ((to_jsonb(old) - array['refreshed_at', 'fields_refreshed_at', 'updated_at']) is distinct from
        (to_jsonb(new) - array['refreshed_at', 'fields_refreshed_at', 'updated_at']))
  execute function cma.audit_row();
comment on trigger audit_change on cma.connection_form is
  'Audits an update that changes anything but the refresh''s times refreshed_at, fields_refreshed_at and updated_at (0009w); inserts and deletes: trigger audit';

drop trigger if exists audit on cma.connection_form_field;
create trigger audit after insert or delete on cma.connection_form_field
  for each row execute function cma.audit_row();
drop trigger if exists audit_change on cma.connection_form_field;
create trigger audit_change after update on cma.connection_form_field
  for each row
  when ((to_jsonb(old) - array['refreshed_at', 'updated_at']) is distinct from (to_jsonb(new) - array['refreshed_at', 'updated_at']))
  execute function cma.audit_row();
comment on trigger audit_change on cma.connection_form_field is
  'Audits an update that changes anything but the refresh''s times refreshed_at and updated_at (0009w); inserts and deletes: trigger audit';

drop trigger if exists audit on cma.connection_stage;
create trigger audit after insert or delete on cma.connection_stage
  for each row execute function cma.audit_row();
drop trigger if exists audit_change on cma.connection_stage;
create trigger audit_change after update on cma.connection_stage
  for each row
  when ((to_jsonb(old) - 'refreshed_at') is distinct from (to_jsonb(new) - 'refreshed_at'))
  execute function cma.audit_row();
comment on trigger audit_change on cma.connection_stage is
  'Audits an update that changes anything but the refresh''s time refreshed_at (0009w); inserts and deletes: trigger audit';

-- ---------------------------------------------------------------------------------------------
-- 4. The bookkeeping: no audit trigger. Last, before the addition's row and the commit: dropping a trigger takes an
--    ACCESS EXCLUSIVE lock on the table, held until the commit (CLAUDE.md, Performance; 132, section 10)
-- ---------------------------------------------------------------------------------------------
drop trigger if exists audit on cma.sync_cursor;
drop trigger if exists audit on cma.ingest_event;
drop trigger if exists audit on cma.sync_run;

-- ---------------------------------------------------------------------------------------------
-- 5. Record the addition
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009w', 'Prod''s slowdown part 1 (Martin, 17 November 2026): pg_stat_statements created and pg_read_all_stats granted to cma_owner where the login may (else the Studio step as postgres); audit_log autoanalyzed and insert-vacuumed after about 40,000 rows (scale factors 0, thresholds 40,000) and analyzed once; connection_form, connection_form_field and connection_stage audited on insert, delete and every update but one that moves only the refresh''s times (trigger audit_change); no audit trigger on sync_cursor, sync_run and ingest_event (Yordi''s agreement of 17 November 2026). No function re-created; no table, view or column changed')
on conflict (version) do nothing;

commit;
reset role;
