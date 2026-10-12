-- =============================================================================================
-- 51_verify_legacy_time_import.sql: verifies addition 0008d, working time imported from an earlier system
-- =============================================================================================
-- Block A checks structure and privileges; blocks B and C work on throwaway tenants inside a
-- subtransaction that is always rolled back. All universal: no seed is assumed, the accounts are
-- synthetic, the statuses are picked by flag, and every session lies in March 2026 in
-- Europe/Amsterdam, so the verdict does not depend on the day it runs. Cloud SQL Studio shows no
-- notices: a check that fails raises "FAIL …" and stops the block. The last result is the verdict.
-- Run as your own IAM login, dev and prod, after 50_legacy_time_import.sql; then 07, 10, 14, 16, 27
-- and 47 again (unchanged).
--   A  structure and privileges: the migration row, the source and batch constraints on the time
--      events, the four tables with row-level security and audit, the append-only grants, the
--      staging view, the functions and who may execute them, the summary's columns, the day
--      history's batch key, the readers' views
--   B  one batch with every case, the dev window (07:00 to 22:00, close 17:00): agent and manager
--      refused, the admin allowed; two overlapping sessions; an open session before and one after
--      the close time; a session crossing the window end and one wholly after it; a login before
--      the window start; three sessions with two gaps; a sub-minute day; an account without a map
--      row; a date that already has a CMA day; an inactive person. The counts, the seconds per day,
--      the gap seconds, the events, the flags, Team hours, the export, the day history, the readers;
--      the work status retired; a second load refused; another tenant sees nothing; the void, then
--      the same days loaded again by a new batch
--   C  the refusals: an unknown status, a period that has not ended, a session in the spring gap, a
--      session outside the period, a paid or working gap status, the default as work status, an
--      inactive work status with time behind it, a map row of another tenant, a batch without mapped
--      sessions, a key in use, rows into a voided batch; and an inactive work status nothing was ever
--      booked on, as the import status is seeded, loads
-- Provoke: set provoke below to true; every block must then stop with FAIL, and the verdict
-- (reached only when the run does not stop on errors) says PROVOKED instead of PASS.
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

-- A. Structure and privileges (universal)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_fn      text;
  v_tbl     text;
  v_cols    text;
begin
  -- A1. the addition is recorded
  if not exists (select 1 from cma.schema_migration where version = '0008d') or v_provoke then
    raise exception 'FAIL A1: addition 0008d not recorded';
  end if;
  -- A2. a time event of source import names its batch, and only such an event does
  if not exists (select 1 from pg_constraint c where c.conrelid = 'cma.time_event'::regclass
                   and c.conname = 'time_event_source_check' and pg_get_constraintdef(c.oid) like '%''import''%')
     or not exists (select 1 from pg_constraint c where c.conrelid = 'cma.time_event'::regclass
                      and c.conname = 'time_event_import_needs_batch')
     or not exists (select 1 from pg_constraint c where c.conrelid = 'cma.time_event'::regclass
                      and c.conname = 'time_event_import_batch_fkey' and c.contype = 'f') then
    raise exception 'FAIL A2: the time events do not take source import with its batch';
  end if;
  -- A3. four tenant tables: row-level security, the application policy, the audit trigger; the
  --     batch never deleted, the rest append-only; the time events still append-only
  foreach v_tbl in array array['cma.import_batch', 'cma.import_session', 'cma.import_person_map', 'cma.import_day'] loop
    if to_regclass(v_tbl) is null
       or not (select c.relrowsecurity from pg_class c where c.oid = to_regclass(v_tbl))
       or not exists (select 1 from pg_policy p where p.polrelid = to_regclass(v_tbl) and p.polname = 'tenant_app')
       or not exists (select 1 from pg_trigger t where t.tgrelid = to_regclass(v_tbl) and t.tgname = 'audit')
       or has_table_privilege('cma_app', v_tbl, 'delete')
       or not has_table_privilege('cma_app', v_tbl, 'insert')
       or has_table_privilege('cma_readonly', v_tbl, 'select') then
      raise exception 'FAIL A3: % is not a tenant table with the expected rights', v_tbl;
    end if;
  end loop;
  if not has_table_privilege('cma_app', 'cma.import_batch', 'update')
     or has_table_privilege('cma_app', 'cma.import_session', 'update')
     or has_table_privilege('cma_app', 'cma.import_person_map', 'update')
     or has_table_privilege('cma_app', 'cma.import_day', 'update')
     or has_table_privilege('cma_app', 'cma.time_event', 'update')
     or has_table_privilege('cma_app', 'cma.time_event', 'delete') then
    raise exception 'FAIL A3: the import tables or the time events are not append-only for the application';
  end if;
  if not exists (select 1 from pg_trigger t where t.tgrelid = 'cma.import_session'::regclass and t.tgname = 'check_import_row')
     or not exists (select 1 from pg_trigger t where t.tgrelid = 'cma.import_person_map'::regclass and t.tgname = 'check_import_row')
     or not exists (select 1 from pg_trigger t where t.tgrelid = 'cma.import_session_staging'::regclass and t.tgname = 'stage_row')
     or not has_table_privilege('cma_app', 'cma.import_session_staging', 'insert')
     or has_table_privilege('cma_readonly', 'cma.import_session_staging', 'select') then
    raise exception 'FAIL A3: the staging path is not as expected';
  end if;
  -- A4. the functions: the application's only
  foreach v_fn in array array['cma.stage_import_batch(text,text,text,date,date,text,text,text)',
                              'cma.load_import_batch(text)', 'cma.void_import_batch(text,text)', 'cma.team_day(uuid,date)'] loop
    if to_regprocedure(v_fn) is null then
      raise exception 'FAIL A4: function % is missing', v_fn;
    end if;
    if not has_function_privilege('cma_app', v_fn, 'execute') or has_function_privilege('cma_readonly', v_fn, 'execute')
       or (select p.prosecdef from pg_proc p where p.oid = to_regprocedure(v_fn)) then
      raise exception 'FAIL A4: function % is not an invoker function for cma_app only', v_fn;
    end if;
  end loop;
  if not exists (select 1 from pg_proc p where p.oid = to_regprocedure('cma.team_day(uuid,date)')
                   and 'import_batch_key' = any (p.proargnames)) then
    raise exception 'FAIL A4: team_day does not return import_batch_key';
  end if;
  -- A5. the summary keeps its columns; the cores stay the owner's
  select string_agg(a.attname, ',' order by a.attnum) into v_cols
  from pg_attribute a where a.attrelid = 'cma.workday_summary_all'::regclass and a.attnum > 0 and not a.attisdropped;
  if v_cols <> 'workday_id,tenant_id,user_id,business_date,timezone,status,started_at,ended_at,working_seconds,productive_seconds,paid_seconds,billable_seconds,is_capped,needs_correction,has_correction,current_status_id'
     or has_table_privilege('cma_app', 'cma.workday_summary_all', 'select')
     or has_table_privilege('cma_readonly', 'cma.workday_summary_all', 'select') then
    raise exception 'FAIL A5: workday_summary_all has the columns % or the wrong readers', v_cols;
  end if;
  -- A6. readers: the batch without names, the events with their batch
  select string_agg(a.attname, ',' order by a.attnum) into v_cols
  from pg_attribute a where a.attrelid = 'cma_read.import_batch'::regclass and a.attnum > 0 and not a.attisdropped;
  if v_cols is null or v_cols ~ '(file_name|void_reason|external_person_name)'
     or not has_table_privilege('cma_readonly', 'cma_read.import_batch', 'select')
     or not exists (select 1 from pg_attribute a where a.attrelid = 'cma_read.time_event'::regclass and a.attname = 'import_batch_id')
     or to_regclass('cma_read.import_session') is not null then
    raise exception 'FAIL A6: the readers'' views are not as expected (%)', v_cols;
  end if;
end
$$;

-- B. One batch with every case (universal, throwaway tenants, rolled back)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_zone    text := 'Europe/Amsterdam';
  v_t1      uuid;
  v_t2      uuid;
  v_admin   uuid;
  v_mgr     uuid;
  v_agent   uuid;
  v_p1      uuid;
  v_p2      uuid;
  v_p4      uuid;
  v_p5      uuid;
  v_admin2  uuid;
  v_gap     text;
  v_txt     text;
  v_n       bigint;
  v_ids     uuid[];
  v_ids2    uuid[];
  v_events  bigint;
  b         cma.import_batch;
  r         record;
begin
  begin
    v_t1 := cma.create_tenant('verify-0008d-import', 'Verify 0008d import', v_zone);
    v_t2 := cma.create_tenant('verify-0008d-other', 'Verify 0008d other', v_zone);
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-mgr@example.invalid', 'mgr') returning id into v_mgr;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-agent@example.invalid', 'agent') returning id into v_agent;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-p1@example.invalid', 'p1') returning id into v_p1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-p2@example.invalid', 'p2') returning id into v_p2;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-p4@example.invalid', 'p4') returning id into v_p4;
    insert into cma.app_user (tenant_id, email, display_name, status) values (v_t1, 'verify-p5@example.invalid', 'p5', 'inactive') returning id into v_p5;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-admin2@example.invalid', 'admin of two') returning id into v_admin2;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin, 'admin'), (v_t1, v_mgr, 'manager'), (v_t1, v_agent, 'agent'), (v_t1, v_p1, 'agent'),
                 (v_t1, v_p2, 'agent'), (v_t1, v_p4, 'agent'), (v_t1, v_p5, 'agent'), (v_t2, v_admin2, 'admin')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;
    -- the dev window: 07:00 to 22:00, an open session ends at 17:00
    insert into cma.tenant_setting (tenant_id, key, value)
    select v_t1, s.key, s.value
    from (values (1, 'workday.window_start', '07:00'), (2, 'workday.window_end', '22:00'), (3, 'workday.auto_close_at', '17:00')) as s(ord, key, value)
    order by s.ord;

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);

    -- a CMA day of p4 on 4 March 2026, 09:00 to 17:00, entered by the manager (Add day)
    perform set_config('app.user_id', v_mgr::text, true);
    perform cma.correct_workday(v_p4, date '2026-03-04', jsonb_build_array(
      jsonb_build_object('kind', 'start', 'statusKey', (select s.key from cma.work_status s where s.is_default), 'at', '2026-03-04T09:00:00+01:00'),
      jsonb_build_object('kind', 'end', 'at', '2026-03-04T17:00:00+01:00')), 'verify an own day');

    -- B1. agent and manager may not stage, write sessions or load; the admin stages
    foreach v_txt in array array[v_agent::text, v_mgr::text] loop
      perform set_config('app.user_id', v_txt, true);
      begin
        perform cma.stage_import_batch('verify-main', 'verify_source', 'verify.csv', date '2026-03-02', date '2026-03-06', v_zone, 'available', 'lunch');
        raise exception 'FAIL B1: % staged a batch', v_txt;
      exception when sqlstate 'CMA06' then null;
      end;
    end loop;
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.upsert_work_status('verify_import', 'Verify import', true, true, true, true, 900);
    select s.key into v_gap from cma.work_status s
    where s.status = 'active' and not s.is_working and not s.is_paid order by s.sort_order, s.key limit 1;
    b := cma.stage_import_batch('verify-main', 'verify_source', 'verify.csv', date '2026-03-02', date '2026-03-06', v_zone, 'verify_import', v_gap);
    if b.status <> 'staged' or b.window_start is not null or v_gap is null or v_provoke then
      raise exception 'FAIL B1: the admin''s stage gave %', b;
    end if;
    if (cma.stage_import_batch('verify-main', 'verify_source', 'verify.csv', date '2026-03-02', date '2026-03-06', v_zone, 'verify_import', v_gap)).id <> b.id then
      raise exception 'FAIL B1: staging again with the same values did not return the batch';
    end if;
    foreach v_txt in array array[v_agent::text, v_mgr::text] loop
      perform set_config('app.user_id', v_txt, true);
      begin
        insert into cma.import_session_staging (batch_key, external_person_id, external_person_name, external_session_id, login_local, logout_local, role)
        values ('verify-main', 'A1', 'Account one', 's00', '2026-03-02 08:00:00', '2026-03-02 09:00:00', 'Agent');
        raise exception 'FAIL B1: % wrote a session', v_txt;
      exception when sqlstate 'CMA06' then null;
      end;
      begin
        perform cma.load_import_batch('verify-main');
        raise exception 'FAIL B1: % loaded a batch', v_txt;
      exception when sqlstate 'CMA06' then null;
      end;
    end loop;

    -- the sessions, through the COPY target, and the map: A3 has no map row
    perform set_config('app.user_id', v_admin::text, true);
    insert into cma.import_session_staging (batch_key, external_person_id, external_person_name, external_session_id, login_local, logout_local, role)
    values
      ('verify-main', 'A1', 'Account one',   's01', '2026-03-02 08:00:00', '2026-03-02 12:00:00', 'Agent'),   -- two overlapping
      ('verify-main', 'A1', 'Account one',   's02', '2026-03-02 11:30:00', '2026-03-02 13:15:30', 'Agent'),
      ('verify-main', 'A1', 'Account one',   's03', '2026-03-03 09:00:00', null,                  'Agent'),   -- open before 17:00
      ('verify-main', 'A1', 'Account one',   's04', '2026-03-03 17:30:00', null,                  'Agent'),   -- open after 17:00
      ('verify-main', 'A1', 'Account one',   's05', '2026-03-04 20:00:00', '2026-03-04 23:30:00', 'Agent'),   -- across 22:00
      ('verify-main', 'A1', 'Account one',   's06', '2026-03-04 22:15:00', '2026-03-04 22:45:00', 'Agent'),   -- wholly after 22:00
      ('verify-main', 'A1', 'Account one',   's07', '2026-03-05 06:15:00', '2026-03-05 10:00:00', 'Agent'),   -- before 07:00
      ('verify-main', 'A1', 'Account one',   's08', '2026-03-06 08:00:00', '2026-03-06 10:00:00', 'Agent'),   -- three, two gaps
      ('verify-main', 'A1', 'Account one',   's09', '2026-03-06 10:15:00', '2026-03-06 12:00:00', 'Agent'),
      ('verify-main', 'A1', 'Account one',   's10', '2026-03-06 12:45:00', '2026-03-06 16:30:15', 'Agent'),
      ('verify-main', 'A2', 'Account two',   's11', '2026-03-02 09:00:00', '2026-03-02 09:00:45', 'Agent'),   -- under a minute
      ('verify-main', 'A2', 'Account two',   's12', '2026-03-03 18:00:00', null,                  'Agent'),   -- only open after 17:00
      ('verify-main', 'A3', 'Account three', 's13', '2026-03-02 09:00:00', '2026-03-02 17:00:00', 'Agent'),   -- no map row
      ('verify-main', 'A3', 'Account three', 's14', '2026-03-03 09:00:00', '2026-03-03 17:00:00', 'Agent'),
      ('verify-main', 'A4', 'Account four',  's15', '2026-03-04 08:00:00', '2026-03-04 12:00:00', 'Agent'),   -- the CMA day wins
      ('verify-main', 'A5', 'Account five',  's16', '2026-03-02 10:00:00', '2026-03-02 11:00:00', 'Agent');   -- an inactive person
    insert into cma.import_person_map (batch_id, external_person_id, user_id)
    values (b.id, 'A1', v_p1), (b.id, 'A2', v_p2), (b.id, 'A4', v_p4), (b.id, 'A5', v_p5);
    if (select count(*) from cma.import_session_staging where batch_key = 'verify-main') <> 16 then
      raise exception 'FAIL B1: % sessions staged', (select count(*) from cma.import_session_staging);
    end if;

    -- B2. the load and its counts
    select count(*) into v_events from cma.time_event;
    b := cma.load_import_batch('verify-main');
    if b.status <> 'loaded' or b.loaded_by <> v_admin or b.window_start <> time '07:00' or b.window_end <> time '22:00'
       or b.open_session_end <> time '17:00'
       or b.counts <> jsonb_build_object('sessions_in', 16, 'sessions_unmapped', 2, 'accounts_skipped', 1,
                                         'sessions_open_dropped', 2, 'sessions_outside_window', 1, 'sessions_merged', 1,
                                         'days_written', 6, 'events_written', 16, 'days_closed_by_rule', 1,
                                         'days_clipped', 2, 'days_dropped', 2, 'days_skipped_existing', 1) then
      raise exception 'FAIL B2: the load gave % with %', b.status, b.counts;
    end if;
    if (select count(*) from cma.time_event) - v_events <> 16 then
      raise exception 'FAIL B2: % events written', (select count(*) from cma.time_event) - v_events;
    end if;

    -- B3. the exact seconds per day after the rules, the gap seconds, the flags
    for r in
      select x.uid, x.d, x.secs, x.gap_secs, x.flag, s.working_seconds, s.paid_seconds, s.needs_correction, s.status, s.timezone,
             s.started_at, s.ended_at, x.first_at, x.last_at,
             (select coalesce(sum(i.seconds), 0) from cma.time_interval i join cma.work_status ws on ws.id = i.status_id
              where i.workday_id = s.workday_id and ws.key = v_gap) as gap_seen
      from (values (v_p1, date '2026-03-02', 18930, 0,    false, '08:00:00', '13:15:30'),
                   (v_p1, date '2026-03-03', 28800, 0,    true,  '09:00:00', '17:00:00'),
                   (v_p1, date '2026-03-04',  7200, 0,    true,  '20:00:00', '22:00:00'),
                   (v_p1, date '2026-03-05', 10800, 0,    true,  '07:00:00', '10:00:00'),
                   (v_p1, date '2026-03-06', 27015, 3600, false, '08:00:00', '16:30:15'),
                   (v_p5, date '2026-03-02',  3600, 0,    false, '10:00:00', '11:00:00')) as x(uid, d, secs, gap_secs, flag, first_at, last_at)
      left join cma.workday_summary s on s.user_id = x.uid and s.business_date = x.d
    loop
      if r.working_seconds is distinct from r.secs::bigint or r.paid_seconds is distinct from r.secs::bigint
         or r.gap_seen <> r.gap_secs or r.needs_correction is distinct from r.flag or r.status <> 'ended' or r.timezone <> v_zone
         or r.started_at <> ((r.d + r.first_at::time) at time zone v_zone) or r.ended_at <> ((r.d + r.last_at::time) at time zone v_zone) then
        raise exception 'FAIL B3: % on % counts % (gap %, flag %, %, % to %), expected % (gap %, flag %)',
          r.uid, r.d, r.working_seconds, r.gap_seen, r.needs_correction, r.status, r.started_at, r.ended_at, r.secs, r.gap_secs, r.flag;
      end if;
    end loop;
    -- nothing else: no day for p2 or for the account without a map row; p4's own day unchanged
    if exists (select 1 from cma.workday w where w.user_id = v_p2)
       or (select count(*) from cma.workday_summary s where s.user_id in (v_p1, v_p5)) <> 6
       or (select s.working_seconds from cma.workday_summary s where s.user_id = v_p4 and s.business_date = date '2026-03-04') <> 28800
       or exists (select 1 from cma.time_event e where e.user_id = v_p4 and e.source = 'import') then
      raise exception 'FAIL B3: a dropped, skipped or own day was touched';
    end if;

    -- B4. the events: source import with their batch, start and end in the work status, the gaps in
    --     the gap status, local times in the batch's zone, recorded now
    if exists (select 1 from cma.time_event e where e.source = 'import'
               and (e.import_batch_id <> b.id or e.recorded_at <> now() or e.reason is not null or e.approved_by is not null))
       or (select string_agg(to_char(e.occurred_at at time zone v_zone, 'HH24:MI:SS') || ' ' || e.kind || ' ' || coalesce(ws.key, '-'), ', '
                             order by e.occurred_at)
           from cma.time_event e left join cma.work_status ws on ws.id = e.status_id
           where e.user_id = v_p1 and (e.occurred_at at time zone v_zone)::date = date '2026-03-06')
          <> format('08:00:00 start verify_import, 10:00:00 status %s, 10:15:00 status verify_import, 12:00:00 status %s, 12:45:00 status verify_import, 16:30:15 end -', v_gap, v_gap) then
      raise exception 'FAIL B4: the events of 6 March read %',
        (select string_agg(to_char(e.occurred_at at time zone v_zone, 'HH24:MI:SS') || ' ' || e.kind, ', ' order by e.occurred_at)
         from cma.time_event e where e.user_id = v_p1 and (e.occurred_at at time zone v_zone)::date = date '2026-03-06');
    end if;
    -- the day history names the batch on every imported row
    if (select count(*) from cma.team_day(v_p1, date '2026-03-06') d where d.source = 'import' and d.import_batch_key = 'verify-main' and d.is_effective) <> 6
       or exists (select 1 from cma.team_day(v_p4, date '2026-03-04') d where d.import_batch_key is not null) then
      raise exception 'FAIL B4: the day history does not show the batch key';
    end if;

    -- B5. Team hours and the export show the days as normal days, entered by import
    if (select count(*) from cma.team_hours(date '2026-03-02', date '2026-03-06')) <> 7
       or (select count(*) from cma.export_status_changes(date '2026-03-02', date '2026-03-06') x where x.source = 'import') <> 10
       or (select sum(x.seconds) from cma.export_status_changes(date '2026-03-02', date '2026-03-06') x
           where x.source = 'import' and x.is_working) <> 18930 + 28800 + 7200 + 10800 + 27015 + 3600 then
      raise exception 'FAIL B5: Team hours or the export do not show the imported days';
    end if;

    -- B6. the work status is retired; a second load is refused; rows into the loaded batch too
    if (select s.status from cma.work_status s where s.key = 'verify_import') <> 'inactive' then
      raise exception 'FAIL B6: the import''s work status is still active';
    end if;
    begin
      perform cma.load_import_batch('verify-main');
      raise exception 'FAIL B6: a second load was accepted';
    exception when sqlstate 'CMA03' then null;
    end;
    begin
      insert into cma.import_session_staging (batch_key, external_person_id, external_session_id, login_local, logout_local)
      values ('verify-main', 'A1', 's99', '2026-03-02 14:00:00', '2026-03-02 15:00:00');
      raise exception 'FAIL B6: a session was added to a loaded batch';
    exception when sqlstate 'CMA03' then null;
    end;

    -- B7. a reader sees the batch without names and the events with their batch, not the sessions
    perform set_config('role', 'cma_readonly', true);
    if (select count(*) from cma_read.import_batch x where x.id = b.id and x.status = 'loaded') <> 1
       or (select count(*) from cma_read.time_event e where e.import_batch_id = b.id) <> 16
       or (select s.working_seconds from cma_read.workday_summary s where s.user_id = v_p1 and s.business_date = date '2026-03-06') <> 27015 then
      raise exception 'FAIL B7: a reader does not see the batch';
    end if;
    begin
      perform 1 from cma.import_session limit 1;
      raise exception 'FAIL B7: a reader read the sessions';
    exception when insufficient_privilege then null;
    end;
    perform set_config('role', 'cma_app', true);

    -- B8. another tenant sees nothing and cannot load the batch
    perform set_config('app.tenant_id', v_t2::text, true);
    perform set_config('app.user_id', v_admin2::text, true);
    if (select count(*) from cma.import_batch) + (select count(*) from cma.import_session) + (select count(*) from cma.import_person_map)
       + (select count(*) from cma.import_day) + (select count(*) from cma.time_event where source = 'import')
       + (select count(*) from cma.import_session_staging) <> 0 then
      raise exception 'FAIL B8: another tenant sees the import';
    end if;
    begin
      perform cma.load_import_batch('verify-main');
      raise exception 'FAIL B8: another tenant loaded the batch';
    exception when sqlstate 'CMA02' then null;
    end;
    begin
      perform cma.void_import_batch('verify-main', 'verify another tenant');
      raise exception 'FAIL B8: another tenant voided the batch';
    exception when sqlstate 'CMA02' then null;
    end;
    perform set_config('app.tenant_id', v_t1::text, true);

    -- B9. the void: the manager may not, a reason is needed; the admin's void adds a void
    --     correction per effective event, deletes nothing, and the days are gone from the summary
    perform set_config('app.user_id', v_mgr::text, true);
    begin
      perform cma.void_import_batch('verify-main', 'verify by a manager');
      raise exception 'FAIL B9: a manager voided the batch';
    exception when sqlstate 'CMA06' then null;
    end;
    perform set_config('app.user_id', v_admin::text, true);
    begin
      perform cma.void_import_batch('verify-main', 'x');
      raise exception 'FAIL B9: a void without a reason was accepted';
    exception when sqlstate 'CMA04' then null;
    end;
    select array_agg(d.workday_id order by d.business_date, d.user_id) into v_ids from cma.import_day d where d.batch_id = b.id;
    select count(*) into v_events from cma.time_event;
    b := cma.void_import_batch('verify-main', 'verify withdrawal');
    if b.status <> 'voided' or b.voided_by <> v_admin or b.void_reason <> 'verify withdrawal' or (b.counts ->> 'events_voided')::int <> 16
       or (select count(*) from cma.time_event) - v_events <> 16
       or (select count(*) from cma.time_event e where e.source = 'import' and e.import_batch_id = b.id) <> 16
       or exists (select 1 from cma.time_event_effective e where e.workday_id = any (v_ids))
       or exists (select 1 from cma.workday_summary s where s.user_id in (v_p1, v_p5))
       or (select count(*) from cma.team_hours(date '2026-03-02', date '2026-03-06')) <> 1
       or exists (select 1 from cma.export_status_changes(date '2026-03-02', date '2026-03-06') x where x.source = 'import')
       or (select count(*) from cma.team_day(v_p1, date '2026-03-02') d where d.kind = 'void' and d.reason = 'Import verify-main withdrawn: verify withdrawal') <> 2 then
      raise exception 'FAIL B9: the void gave % with %', b.status, b.counts;
    end if;
    begin
      perform cma.void_import_batch('verify-main', 'verify again');
      raise exception 'FAIL B9: a second void was accepted';
    exception when sqlstate 'CMA03' then null;
    end;

    -- B10. the same days load again from a new batch: the work status was retired by the first load
    --      and is accepted for it; the withdrawn days are used again, p4's own day still wins
    b := cma.stage_import_batch('verify-main-2', 'verify_source', 'verify.csv', date '2026-03-02', date '2026-03-06', v_zone, 'verify_import', v_gap);
    insert into cma.import_session_staging (batch_key, external_person_id, external_person_name, external_session_id, login_local, logout_local, role)
    select 'verify-main-2', s.external_person_id, s.external_person_name, s.external_session_id, s.login_local, s.logout_local, s.role
    from cma.import_session_staging s where s.batch_key = 'verify-main';
    insert into cma.import_person_map (batch_id, external_person_id, user_id)
    values (b.id, 'A1', v_p1), (b.id, 'A2', v_p2), (b.id, 'A4', v_p4), (b.id, 'A5', v_p5);
    b := cma.load_import_batch('verify-main-2');
    select array_agg(d.workday_id order by d.business_date, d.user_id) into v_ids2 from cma.import_day d where d.batch_id = b.id;
    if b.status <> 'loaded' or (b.counts ->> 'days_written')::int <> 6 or (b.counts ->> 'days_skipped_existing')::int <> 1
       or v_ids2 <> v_ids
       or (select sum(s.working_seconds) from cma.workday_summary s where s.user_id in (v_p1, v_p5)) <> 18930 + 28800 + 7200 + 10800 + 27015 + 3600
       or (select count(*) from cma.team_hours(date '2026-03-02', date '2026-03-06')) <> 7
       or (select s.status from cma.work_status s where s.key = 'verify_import') <> 'inactive' then
      raise exception 'FAIL B10: the reload gave % with %', b.status, b.counts;
    end if;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- C. The refusals (universal, throwaway tenants, rolled back)
do $$
declare
  v_provoke boolean := current_setting('verify.provoke')::boolean;
  v_zone    text := 'Europe/Amsterdam';
  v_t1      uuid;
  v_t2      uuid;
  v_admin   uuid;
  v_p1      uuid;
  v_other   uuid;
  v_gap     text;
  v_paid    text;
  v_txt     text;
  v_code    text;
  b         cma.import_batch;
  r         record;
begin
  begin
    v_t1 := cma.create_tenant('verify-0008d-refusals', 'Verify 0008d refusals', v_zone);
    v_t2 := cma.create_tenant('verify-0008d-refusals-two', 'Verify 0008d refusals two', v_zone);
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-admin@example.invalid', 'admin') returning id into v_admin;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t1, 'verify-p1@example.invalid', 'p1') returning id into v_p1;
    insert into cma.app_user (tenant_id, email, display_name) values (v_t2, 'verify-other@example.invalid', 'other') returning id into v_other;
    insert into cma.user_role (tenant_id, user_id, role_id)
    select ar.tenant_id, x.uid, ar.id
    from (values (v_t1, v_admin, 'admin'), (v_t1, v_p1, 'agent'), (v_t2, v_other, 'agent')) as x(tid, uid, role_key)
    join cma.app_role ar on ar.tenant_id = x.tid and ar.key = x.role_key;

    perform set_config('role', 'cma_app', true);
    perform set_config('app.tenant_id', v_t1::text, true);
    perform set_config('app.user_id', v_admin::text, true);
    perform cma.upsert_work_status('verify_import', 'Verify import', true, true, true, true, 900);
    perform cma.upsert_work_status('verify_old', 'Verify old', true, true, true, true, 910);
    perform cma.retire_work_status('verify_old');
    select s.key into v_gap from cma.work_status s
    where s.status = 'active' and not s.is_working and not s.is_paid order by s.sort_order, s.key limit 1;
    select s.key into v_paid from cma.work_status s
    where s.status = 'active' and not s.is_working and s.is_paid order by s.sort_order, s.key limit 1;
    if v_gap is null or v_paid is null or v_provoke then
      raise exception 'FAIL C1: the throwaway tenant has no unpaid (%) or paid (%) pause status', v_gap, v_paid;
    end if;

    -- C1. stage: an unknown status; a period that has not ended; a malformed key
    for r in
      select * from (values
        ('CMA02', format('select cma.stage_import_batch(''verify-x'', ''verify_source'', ''f.csv'', date ''2026-03-02'', date ''2026-03-06'', %L, ''no_such_status'', %L)', v_zone, v_gap)),
        ('CMA04', format('select cma.stage_import_batch(''verify-x'', ''verify_source'', ''f.csv'', date ''2026-03-02'', %L::date, %L, ''verify_import'', %L)',
                         (now() at time zone v_zone)::date, v_zone, v_gap)),
        ('CMA04', format('select cma.stage_import_batch(''Verify X'', ''verify_source'', ''f.csv'', date ''2026-03-02'', date ''2026-03-06'', %L, ''verify_import'', %L)', v_zone, v_gap)),
        ('CMA04', format('select cma.stage_import_batch(''verify-x'', ''verify_source'', ''f.csv'', date ''2026-03-02'', date ''2026-03-06'', ''Mars/Olympus'', ''verify_import'', %L)', v_gap))
      ) as x(code, stmt)
    loop
      begin
        execute r.stmt;
        raise exception 'FAIL C1: accepted: %', r.stmt;
      exception when others then
        get stacked diagnostics v_code = returned_sqlstate, v_txt = message_text;
        if v_code <> r.code then
          raise exception 'FAIL C1: % gave % (%), expected %', r.stmt, v_code, v_txt, r.code;
        end if;
      end;
    end loop;

    -- C2. load refusals, each on its own staged batch with one session of a mapped account; the
    --     batch stays staged after a refusal
    for r in
      select * from (values
        ('verify-gap',     'verify_import', v_gap,           '2026-03-29 02:30:00'::timestamp, '2026-03-29 09:00:00'::timestamp, 'spring'),
        ('verify-gap-out', 'verify_import', v_gap,           '2026-03-28 21:00:00'::timestamp, '2026-03-29 02:15:00'::timestamp, 'spring'),
        ('verify-period',  'verify_import', v_gap,           '2026-03-31 09:00:00'::timestamp, '2026-03-31 17:00:00'::timestamp, 'outside the period'),
        ('verify-paid',    'verify_import', v_paid,          '2026-03-02 09:00:00'::timestamp, '2026-03-02 17:00:00'::timestamp, 'neither working nor paid'),
        ('verify-working', 'verify_import', 'verify_import', '2026-03-02 09:00:00'::timestamp, '2026-03-02 17:00:00'::timestamp, 'neither working nor paid'),
        ('verify-default', (select s.key from cma.work_status s where s.is_default), v_gap,
                                                             '2026-03-02 09:00:00'::timestamp, '2026-03-02 17:00:00'::timestamp, 'not the default')
      ) as x(batch_key, work_key, gap_key, login_at, logout_at, says)
    loop
      b := cma.stage_import_batch(r.batch_key, 'verify_source', 'f.csv', date '2026-03-01', date '2026-03-30', v_zone, r.work_key, r.gap_key);
      insert into cma.import_session_staging (batch_key, external_person_id, external_session_id, login_local, logout_local)
      values (r.batch_key, 'A1', 's1', r.login_at, r.logout_at);
      insert into cma.import_person_map (batch_id, external_person_id, user_id) values (b.id, 'A1', v_p1);
      begin
        perform cma.load_import_batch(r.batch_key);
        raise exception 'FAIL C2: batch % was loaded', r.batch_key;
      exception when sqlstate 'CMA04' then
        get stacked diagnostics v_txt = message_text;
        if position(r.says in v_txt) = 0 then
          raise exception 'FAIL C2: batch % was refused with [%]', r.batch_key, v_txt;
        end if;
      end;
      if (select x.status from cma.import_batch x where x.id = b.id) <> 'staged' or exists (select 1 from cma.workday) then
        raise exception 'FAIL C2: the refused batch % left something behind', r.batch_key;
      end if;
    end loop;

    -- C2b. the work status may be inactive while nothing was ever booked on it (the import status is
    --      seeded inactive, so it is never offered); an inactive status with time behind it is refused
    perform cma.upsert_work_status('verify_used', 'Verify used', true, true, true, true, 920);
    perform cma.correct_workday(v_p1, date '2026-03-10', jsonb_build_array(
      jsonb_build_object('kind', 'start', 'statusKey', 'verify_used', 'at', '2026-03-10T09:00:00+01:00'),
      jsonb_build_object('kind', 'end', 'at', '2026-03-10T17:00:00+01:00')), 'verify time in a status');
    perform cma.retire_work_status('verify_used');
    b := cma.stage_import_batch('verify-used', 'verify_source', 'f.csv', date '2026-03-01', date '2026-03-30', v_zone, 'verify_used', v_gap);
    insert into cma.import_session_staging (batch_key, external_person_id, external_session_id, login_local, logout_local)
    values ('verify-used', 'A1', 's1', '2026-03-02 09:00:00', '2026-03-02 17:00:00');
    insert into cma.import_person_map (batch_id, external_person_id, user_id) values (b.id, 'A1', v_p1);
    begin
      perform cma.load_import_batch('verify-used');
      raise exception 'FAIL C2b: an inactive status with time behind it was loaded';
    exception when sqlstate 'CMA04' then
      get stacked diagnostics v_txt = message_text;
      if position('inactive and has time recorded' in v_txt) = 0 then
        raise exception 'FAIL C2b: the inactive status with time was refused with [%]', v_txt;
      end if;
    end;
    if (select x.status from cma.import_batch x where x.id = b.id) <> 'staged' or (select count(*) from cma.workday) <> 1 then
      raise exception 'FAIL C2b: the refused batch left something behind';
    end if;
    b := cma.stage_import_batch('verify-unused', 'verify_source', 'f.csv', date '2026-03-01', date '2026-03-30', v_zone, 'verify_old', v_gap);
    insert into cma.import_session_staging (batch_key, external_person_id, external_session_id, login_local, logout_local)
    values ('verify-unused', 'A1', 's1', '2026-03-03 09:00:00', '2026-03-03 17:00:00');
    insert into cma.import_person_map (batch_id, external_person_id, user_id) values (b.id, 'A1', v_p1);
    b := cma.load_import_batch('verify-unused');
    if b.status <> 'loaded' or (b.counts ->> 'days_written')::int <> 1
       or (select s.working_seconds from cma.workday_summary s where s.user_id = v_p1 and s.business_date = date '2026-03-03') <> 28800
       or (select s.status from cma.work_status s where s.key = 'verify_old') <> 'inactive' then
      raise exception 'FAIL C2b: the inactive status nothing was booked on gave % with %', b.status, b.counts;
    end if;

    -- C3. a map row of another tenant's person; a batch without sessions of a mapped account
    b := cma.stage_import_batch('verify-unmapped', 'verify_source', 'f.csv', date '2026-03-01', date '2026-03-30', v_zone, 'verify_import', v_gap);
    insert into cma.import_session_staging (batch_key, external_person_id, external_session_id, login_local, logout_local)
    values ('verify-unmapped', 'A1', 's1', '2026-03-02 09:00:00', '2026-03-02 17:00:00');
    begin
      insert into cma.import_person_map (batch_id, external_person_id, user_id) values (b.id, 'A1', v_other);
      raise exception 'FAIL C3: a map row to another tenant''s person was accepted';
    exception when sqlstate 'CMA04' or foreign_key_violation then null;
    end;
    begin
      perform cma.load_import_batch('verify-unmapped');
      raise exception 'FAIL C3: a batch without mapped sessions was loaded';
    exception when sqlstate 'CMA04' then null;
    end;

    -- C4. a key in use with other values; an unknown batch; a void of an unknown batch
    begin
      perform cma.stage_import_batch('verify-unmapped', 'verify_source', 'other.csv', date '2026-03-01', date '2026-03-30', v_zone, 'verify_import', v_gap);
      raise exception 'FAIL C4: a key in use was staged again with other values';
    exception when sqlstate 'CMA03' then null;
    end;
    begin
      perform cma.load_import_batch('verify-none');
      raise exception 'FAIL C4: an unknown batch was loaded';
    exception when sqlstate 'CMA02' then null;
    end;
    begin
      insert into cma.import_session_staging (batch_key, external_person_id, external_session_id, login_local, logout_local)
      values ('verify-none', 'A1', 's1', '2026-03-02 09:00:00', '2026-03-02 17:00:00');
      raise exception 'FAIL C4: a session for an unknown batch was accepted';
    exception when sqlstate 'CMA02' then null;
    end;
    -- a staged batch is withdrawn without writing anything; its rows then stay as they are
    b := cma.void_import_batch('verify-unmapped', 'verify a staged void');
    if b.status <> 'voided' or b.counts is not null then
      raise exception 'FAIL C4: the void of a staged batch gave % with %', b.status, b.counts;
    end if;
    begin
      insert into cma.import_session_staging (batch_key, external_person_id, external_session_id, login_local, logout_local)
      values ('verify-unmapped', 'A1', 's2', '2026-03-03 09:00:00', '2026-03-03 17:00:00');
      raise exception 'FAIL C4: a session was added to a voided batch';
    exception when sqlstate 'CMA03' then null;
    end;

    raise exception using errcode = 'CMAOK', message = 'rollback';
  exception when sqlstate 'CMAOK' then null;
  end;
end
$$;

-- Verdict: per tenant, the batches by status and the imported days the summary counts
select t.slug as tenant,
       (select count(*) from cma.import_batch b where b.tenant_id = t.id and b.status = 'staged') as staged,
       (select count(*) from cma.import_batch b where b.tenant_id = t.id and b.status = 'loaded') as loaded,
       (select count(*) from cma.import_batch b where b.tenant_id = t.id and b.status = 'voided') as voided,
       (select count(distinct e.workday_id) from cma.time_event_effective_all e where e.tenant_id = t.id and e.source = 'import') as imported_days,
       case when current_setting('verify.provoke')::boolean then 'PROVOKED, NOT A PASS' else 'PASS' end as verdict
from cma.tenant t
where t.status = 'active'
order by t.slug;
