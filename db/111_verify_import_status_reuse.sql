-- =============================================================================================
-- 111_verify_import_status_reuse.sql: verifies addition 0008zh, a later legacy import batch reuses the tenant's import status
-- =============================================================================================
-- Universal: no seed is assumed, the accounts and people are synthetic (example.invalid), the statuses are
-- picked by flag, and every session lies in March 2026 in Europe/Amsterdam, so the verdict does not depend on
-- the day it runs. Block S checks the addition and the grants; block A works on one throwaway tenant inside a
-- subtransaction that is always rolled back. Cloud SQL Studio shows no notices: a check that fails raises
-- "FAIL …" and stops the block. The last result is the verdict, one row. Run as your own IAM login, dev first,
-- then prod (the throwaway tenant is rolled back, nothing stays), after 110_import_status_reuse.sql; then
-- 51_verify_legacy_time_import.sql again (unchanged, still PASS).
--   S  the addition 0008zh is recorded; cma.load_import_batch(text) is the application's only, an invoker function
--   A  the import status of the tenant, retired (inactive) from the start, as the import status is seeded:
--      A1 a first batch into an inactive status that has nothing booked on it loads
--      A2 a second batch into the same status, a later period, loads (CMA04 before 0008zh)
--      A3 a day of batch 1 corrected by a supervisor (an end moved; a status change written in the import
--         status itself, while it was active again), then a third batch: loads
--      A4 a status with effective time on a live clocked day, then retired: still CMA04, nothing written
--      A5 a batch that overlaps a person-day an earlier batch wrote: that day counted in days_skipped_existing,
--         not written twice
--      A6 void and reload still works: batch 1 withdrawn with the corrections made to its days, then loaded again
-- Provoke: set provoke below to true; every block must then stop with FAIL, and the verdict (reached only when
-- the run does not stop on errors) says PROVOKED instead of PASS.
-- =============================================================================================

do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;
select set_config('verify.provoke', 'false', false);   -- 'true' to make every block fail

-- S. The addition and the grants (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_fn      text := 'cma.load_import_batch(text)';
begin
  if not exists (select 1 from cma.schema_migration where version = '0008zh') or v_provoke then
    raise exception 'FAIL S1: addition 0008zh not recorded';
  end if;
  if to_regprocedure(v_fn) is null
     or not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
     or (select p.prosecdef from pg_proc p where p.oid = to_regprocedure(v_fn))
     or pg_get_functiondef(to_regprocedure(v_fn)) not like '%on days no import wrote%' then
    raise exception 'FAIL S1: % is not the 0008zh invoker function for cma_app only', v_fn;
  end if;
end
$$;

-- A. The cases (universal, one throwaway tenant, rolled back)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_zone    text := 'Europe/Amsterdam';
  v_t1      uuid;
  v_admin   uuid;
  v_sup     uuid;
  v_p1      uuid;
  v_p2      uuid;
  v_live    uuid;
  v_gap     text;
  v_txt     text;
  v_end     uuid;
  v_n       bigint;
  v_events  bigint;
  v_ids     uuid[];
  v_ids2    uuid[];
  w         cma.workday;
  b         cma.import_batch;
begin
  begin
    v_t1 := cma.create_tenant('verify-0008zh-reuse', 'Verify 0008zh reuse', v_zone);
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-sup@example.invalid', 'supervisor') returning id into v_sup;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-p1@example.invalid', 'p1') returning id into v_p1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-p2@example.invalid', 'p2') returning id into v_p2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-live@example.invalid', 'live') returning id into v_live;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin, 'admin'), (v_t1, v_sup, 'manager'), (v_t1, v_p1, 'agent'),
                 (v_t1, v_p2, 'agent'), (v_t1, v_live, 'agent')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    -- the dev window: 07:00 to 22:00, an open session ends at 17:00
    insert into cma.tenant_setting (tenant_id, key, value)
    select v_t1, s.key, s.value
    from (values (1, 'workday.window_start', '07:00'), (2, 'workday.window_end', '22:00'), (3, 'workday.auto_close_at', '17:00')) as s(ord, key, value)
    order by s.ord;

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin::text, true);

    -- the import status as it is seeded: working, inactive from the start, nothing booked on it
    perform cma.upsert_work_status('verify_import', 'Verify import', true, true, true, true, 900);
    perform cma.retire_work_status('verify_import');
    select s.key into v_gap from cma.work_status s
    where s.status = 'active' and not s.is_working and not s.is_paid order by s.sort_order, s.key limit 1;
    if v_gap is null
       or (select s.status from cma.work_status s where s.key = 'verify_import') <> 'inactive'
       or exists (select 1 from cma.time_event_effective e join cma.work_status s on s.id = e.status_id where s.key = 'verify_import') then
      raise exception 'FAIL A1: the throwaway tenant has no unpaid pause status (%) or a used import status', v_gap;
    end if;

    -- A1. a first batch into an inactive status with nothing booked on it loads: p1 on 2 March (clean) and on
    --     3 March (open, closed at 17:00 by rule), p2 on 2 March
    b := cma.stage_import_batch('verify-w1', 'verify_source', 'verify.csv', date '2026-03-02', date '2026-03-06', v_zone, 'verify_import', v_gap);
    insert into cma.import_session_staging (batch_key, external_person_id, external_session_id, login_local, logout_local)
    values ('verify-w1', 'A1', 's01', '2026-03-02 09:00:00', '2026-03-02 17:00:00'),
           ('verify-w1', 'A1', 's02', '2026-03-03 09:00:00', null),
           ('verify-w1', 'A2', 's03', '2026-03-02 10:00:00', '2026-03-02 12:00:00');
    insert into cma.import_person_map (batch_id, external_person_id, user_id) values (b.id, 'A1', v_p1), (b.id, 'A2', v_p2);
    b := cma.load_import_batch('verify-w1');
    if b.status <> 'loaded' or (b.counts ->> 'days_written')::int <> 3 or (b.counts ->> 'days_skipped_existing')::int <> 0
       or (b.counts ->> 'days_closed_by_rule')::int <> 1
       or (select sum(s.working_seconds) from cma.workday_summary s where s.user_id in (v_p1, v_p2)) <> 28800 + 28800 + 7200
       or (select s.status from cma.work_status s where s.key = 'verify_import') <> 'inactive'
       or v_provoke then
      raise exception 'FAIL A1: the first batch gave % with %', b.status, b.counts;
    end if;
    select array_agg(d.workday_id order by d.business_date, d.user_id) into v_ids from cma.import_day d where d.batch_id = b.id;

    -- A2. a second batch into the same, now used and inactive, status loads: p1 on 9 and 10 March, p2 on 9 March
    b := cma.stage_import_batch('verify-w2', 'verify_source', 'verify.csv', date '2026-03-09', date '2026-03-13', v_zone, 'verify_import', v_gap);
    insert into cma.import_session_staging (batch_key, external_person_id, external_session_id, login_local, logout_local)
    values ('verify-w2', 'A1', 's04', '2026-03-09 09:00:00', '2026-03-09 12:00:00'),
           ('verify-w2', 'A1', 's05', '2026-03-10 09:00:00', '2026-03-10 10:00:00'),
           ('verify-w2', 'A2', 's06', '2026-03-09 13:00:00', '2026-03-09 14:00:00');
    insert into cma.import_person_map (batch_id, external_person_id, user_id) values (b.id, 'A1', v_p1), (b.id, 'A2', v_p2);
    b := cma.load_import_batch('verify-w2');
    if b.status <> 'loaded' or (b.counts ->> 'days_written')::int <> 3 or (b.counts ->> 'events_written')::int <> 6
       or (select sum(s.working_seconds) from cma.workday_summary s where s.user_id in (v_p1, v_p2) and s.business_date >= date '2026-03-09')
          <> 10800 + 3600 + 3600
       or (select s.status from cma.work_status s where s.key = 'verify_import') <> 'inactive' then
      raise exception 'FAIL A2: the second batch gave % with %', b.status, b.counts;
    end if;

    -- A3. the supervisor corrects days of batch 1 since: the end of p1's 3 March moved to 16:30 (the usual
    --     correction of a day closed by rule), and, while the import status was active again, a status
    --     change in the import status on p1's 2 March. Corrections are events of source 'correction' on the
    --     imported workday, not of the batch; the status is retired again. Then a third batch loads
    perform cma.upsert_work_status('verify_import', 'Verify import', true, true, true, true, 900);
    perform set_config('app.user_id', v_sup::text, true);
    select e.id into v_end from cma.time_event_effective e
    join cma.workday d on d.id = e.workday_id and d.tenant_id = e.tenant_id
    where e.kind = 'end' and d.user_id = v_p1 and d.business_date = date '2026-03-03';
    perform cma.correct_workday(v_p1, date '2026-03-03', jsonb_build_array(
      jsonb_build_object('kind', 'end', 'supersedes', v_end, 'at', '2026-03-03T16:30:00+01:00')), 'verify an end moved');
    perform cma.correct_workday(v_p1, date '2026-03-02', jsonb_build_array(
      jsonb_build_object('kind', 'status', 'statusKey', 'verify_import', 'at', '2026-03-02T13:00:00+01:00')), 'verify a status change in the import status');
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.retire_work_status('verify_import');
    if (select count(*) from cma.time_event_effective e join cma.work_status s on s.id = e.status_id
        where s.key = 'verify_import' and e.source = 'correction') <> 1
       or (select count(*) from cma.time_event_effective e join cma.workday d on d.id = e.workday_id and d.tenant_id = e.tenant_id
           where d.user_id = v_p1 and d.business_date = date '2026-03-03' and e.source = 'correction' and e.kind = 'end') <> 1
       or (select s.working_seconds from cma.workday_summary s where s.user_id = v_p1 and s.business_date = date '2026-03-03') <> 27000
       or (select s.status from cma.work_status s where s.key = 'verify_import') <> 'inactive' then
      raise exception 'FAIL A3: the corrections of the imported days are not as expected';
    end if;
    b := cma.stage_import_batch('verify-w3', 'verify_source', 'verify.csv', date '2026-03-16', date '2026-03-20', v_zone, 'verify_import', v_gap);
    insert into cma.import_session_staging (batch_key, external_person_id, external_session_id, login_local, logout_local)
    values ('verify-w3', 'A1', 's07', '2026-03-16 08:00:00', '2026-03-16 12:00:00'),
           ('verify-w3', 'A2', 's08', '2026-03-16 08:00:00', '2026-03-16 09:30:00');
    insert into cma.import_person_map (batch_id, external_person_id, user_id) values (b.id, 'A1', v_p1), (b.id, 'A2', v_p2);
    b := cma.load_import_batch('verify-w3');
    if b.status <> 'loaded' or (b.counts ->> 'days_written')::int <> 2 or (b.counts ->> 'days_skipped_existing')::int <> 0
       or (select sum(s.working_seconds) from cma.workday_summary s where s.user_id in (v_p1, v_p2) and s.business_date = date '2026-03-16')
          <> 14400 + 5400
       or (select s.status from cma.work_status s where s.key = 'verify_import') <> 'inactive' then
      raise exception 'FAIL A3: the batch after the corrections gave % with %', b.status, b.counts;
    end if;

    -- A4. live time still blocks: an agent clocks in on 24 March and moves to a status of the tenant (a
    --     working status that is not the default), ends the day; the status is then retired; a batch into it
    --     is refused (CMA04), stays staged and leaves nothing behind
    perform cma.upsert_work_status('verify_live', 'Verify live', true, true, true, true, 910);
    perform set_config('app.user_id', v_live::text, true);
    w := cma.open_workday(timestamptz '2026-03-24T09:00:00+01:00');
    perform cma.set_status(w.id, 'verify_live', timestamptz '2026-03-24T11:00:00+01:00');
    perform cma.end_workday(w.id, timestamptz '2026-03-24T17:00:00+01:00');
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.retire_work_status('verify_live');
    b := cma.stage_import_batch('verify-live', 'verify_source', 'verify.csv', date '2026-03-23', date '2026-03-27', v_zone, 'verify_live', v_gap);
    insert into cma.import_session_staging (batch_key, external_person_id, external_session_id, login_local, logout_local)
    values ('verify-live', 'A1', 's09', '2026-03-27 09:00:00', '2026-03-27 17:00:00');
    insert into cma.import_person_map (batch_id, external_person_id, user_id) values (b.id, 'A1', v_p1);
    select count(*) into v_events from cma.time_event;
    begin
      perform cma.load_import_batch('verify-live');
      raise exception 'FAIL A4: an inactive status with live time behind it was loaded';
    exception when sqlstate 'CMA04' then
      get stacked diagnostics v_txt = message_text;
      if position('inactive and has time recorded' in v_txt) = 0 then
        raise exception 'FAIL A4: the status with live time was refused with [%]', v_txt;
      end if;
    end;
    if (select x.status from cma.import_batch x where x.id = b.id) <> 'staged'
       or (select count(*) from cma.time_event) <> v_events
       or exists (select 1 from cma.workday d where d.user_id = v_p1 and d.business_date = date '2026-03-27') then
      raise exception 'FAIL A4: the refused batch left something behind';
    end if;

    -- A5. a batch that overlaps a person-day batch 1 wrote (p1, 3 March, corrected since): the day counts in
    --     days_skipped_existing and is not written twice; the new days of p2 (4 March) and p1 (5 March) load
    select count(*) into v_events from cma.time_event e join cma.workday d on d.id = e.workday_id and d.tenant_id = e.tenant_id
    where d.user_id = v_p1 and d.business_date = date '2026-03-03';
    b := cma.stage_import_batch('verify-w4', 'verify_source', 'verify.csv', date '2026-03-02', date '2026-03-06', v_zone, 'verify_import', v_gap);
    insert into cma.import_session_staging (batch_key, external_person_id, external_session_id, login_local, logout_local)
    values ('verify-w4', 'A1', 's10', '2026-03-03 09:00:00', '2026-03-03 10:00:00'),
           ('verify-w4', 'A2', 's11', '2026-03-04 09:00:00', '2026-03-04 10:00:00'),
           ('verify-w4', 'A1', 's12', '2026-03-05 09:00:00', '2026-03-05 10:00:00');
    insert into cma.import_person_map (batch_id, external_person_id, user_id) values (b.id, 'A1', v_p1), (b.id, 'A2', v_p2);
    b := cma.load_import_batch('verify-w4');
    if b.status <> 'loaded' or (b.counts ->> 'days_written')::int <> 2 or (b.counts ->> 'days_skipped_existing')::int <> 1
       or (select count(*) from cma.time_event e join cma.workday d on d.id = e.workday_id and d.tenant_id = e.tenant_id
           where d.user_id = v_p1 and d.business_date = date '2026-03-03') <> v_events
       or (select count(*) from cma.import_day d where d.user_id = v_p1 and d.business_date = date '2026-03-03') <> 1
       or (select s.working_seconds from cma.workday_summary s where s.user_id = v_p1 and s.business_date = date '2026-03-03') <> 27000
       or (select s.status from cma.work_status s where s.key = 'verify_import') <> 'inactive' then
      raise exception 'FAIL A5: the overlapping batch gave % with %', b.status, b.counts;
    end if;

    -- A6. void and reload: batch 1 is withdrawn with the corrections made to its days, then its sessions load
    --     again from a new batch into the same status; the withdrawn days are used again
    b := cma.void_import_batch('verify-w1', 'verify withdrawal');
    if b.status <> 'voided'
       or exists (select 1 from cma.time_event_effective e where e.workday_id = any (v_ids))
       or exists (select 1 from cma.workday_summary s where s.user_id = v_p2 and s.business_date = date '2026-03-02') then
      raise exception 'FAIL A6: the void gave % with %', b.status, b.counts;
    end if;
    b := cma.stage_import_batch('verify-w1-2', 'verify_source', 'verify.csv', date '2026-03-02', date '2026-03-06', v_zone, 'verify_import', v_gap);
    insert into cma.import_session_staging (batch_key, external_person_id, external_session_id, login_local, logout_local)
    select 'verify-w1-2', s.external_person_id, s.external_session_id, s.login_local, s.logout_local
    from cma.import_session_staging s where s.batch_key = 'verify-w1';
    insert into cma.import_person_map (batch_id, external_person_id, user_id) values (b.id, 'A1', v_p1), (b.id, 'A2', v_p2);
    b := cma.load_import_batch('verify-w1-2');
    select array_agg(d.workday_id order by d.business_date, d.user_id) into v_ids2 from cma.import_day d where d.batch_id = b.id;
    if b.status <> 'loaded' or (b.counts ->> 'days_written')::int <> 3 or (b.counts ->> 'days_skipped_existing')::int <> 0
       or v_ids2 <> v_ids
       or (select sum(s.working_seconds) from cma.workday_summary s where s.business_date = date '2026-03-02' and s.user_id in (v_p1, v_p2)) <> 28800 + 7200
       or (select s.working_seconds from cma.workday_summary s where s.user_id = v_p1 and s.business_date = date '2026-03-03') <> 28800
       or (select s.status from cma.work_status s where s.key = 'verify_import') <> 'inactive' then
      raise exception 'FAIL A6: the reload gave % with %', b.status, b.counts;
    end if;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- Verdict: one row
select case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS' else 'PASS' end as verdict;
