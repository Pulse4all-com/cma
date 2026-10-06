-- CMA verify for migration 0002 (time model)
-- Run as yourself (IAM login), no SET ROLE, after 05 (and in dev 06). Run the blocks one at a time;
-- the blocks marked "expected error" end in an error on purpose. Keep the output as the release record
-- in records/0002-<env>-<date>/.
-- Blocks A, B, C, D, F, G, I and J are universal: they check structure and configuration, or create
-- throwaway users and days inside one transaction that is rolled back, so they leave nothing behind
-- (also no audit rows) and run in prod before any real person exists. Blocks E, H and K use the dev
-- fixture from 06 and are skipped in prod.

-- Guard: scripts run under a personal IAM login so the audit trail names a person. postgres is
-- for emergencies only; to use it deliberately, run first:  set cma.emergency = 'on';
do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;

-- A. Structure: tables, RLS, policies, triggers, views, privileges, functions -----------------------------
select c.relname, pg_get_userbyid(c.relowner) as owner, c.relrowsecurity as rls_on
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'cma' and c.relkind = 'r' and c.relname in ('work_status', 'workday', 'time_event')
order by 1;
-- expect: 3 rows, owner cma_owner, rls_on true

select tablename, policyname, roles, cmd
from pg_policies
where schemaname = 'cma' and tablename in ('work_status', 'workday', 'time_event')
order by 1;
-- expect: tenant_app (ALL, cma_app) on each of the three

select c.relname as table_name
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
join pg_namespace n on n.oid = c.relnamespace
where t.tgname = 'audit' and not t.tgisinternal
  and n.nspname = 'cma' and c.relname in ('work_status', 'workday', 'time_event')
order by 1;
-- expect: the three tables

select c.relname, pg_get_userbyid(c.relowner) as owner
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'cma' and c.relkind = 'v'
order by 1;
-- expect: 6 views owned by cma_owner: time_event_effective, time_interval, workday_summary and their
--         _all cores

select table_name
from information_schema.views
where table_schema = 'cma_read'
order by 1;
-- expect: 15 views: the 10 from 0001 plus time_event, time_interval, work_status, workday, workday_summary

-- naming cma.* objects needs usage on the schema, so this part runs as owner
set role cma_owner;
select has_table_privilege('cma_app', 'cma.time_event',  'insert') as app_inserts_events,     -- true
       has_table_privilege('cma_app', 'cma.time_event',  'update') as app_updates_events,     -- false
       has_table_privilege('cma_app', 'cma.time_event',  'delete') as app_deletes_events,     -- false
       has_table_privilege('cma_app', 'cma.workday',     'delete') as app_deletes_workdays,   -- false
       has_table_privilege('cma_app', 'cma.work_status', 'delete') as app_deletes_statuses,   -- false
       has_table_privilege('cma_app', 'cma.workday_summary',     'select') as app_reads_summary,      -- true
       has_table_privilege('cma_app', 'cma.workday_summary_all', 'select') as app_reads_summary_all;  -- false
reset role;

select p.proname, p.prosecdef as security_definer,
       has_function_privilege('cma_app', p.oid, 'execute') as app_may_call
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'cma'
  and p.proname in ('open_workday', 'set_status', 'end_workday', 'correct_time_event', 'refresh_workday',
                    'find_tenants_for_identity', 'user_permissions', 'has_permission',
                    'seed_default_work_statuses', 'user_timezone', 'business_date')
order by 1;
-- expect: find_tenants_for_identity is the only security_definer; app_may_call true for all except
--         seed_default_work_statuses

-- schema_migration has no reader view by design; check it as owner
set role cma_owner;
select version, description, applied_by, applied_at::date from cma.schema_migration order by 1;
reset role;
-- expect: 0001 and 0002 (and 0003 once applied), applied_by your IAM login

-- B. Configuration as a reader: status ladder per tenant, time zones ------------------------------------
select t.slug, s.key, s.is_working, s.is_productive, s.is_paid, s.is_billable, s.is_default
from cma_read.work_status s
join cma_read.tenant t on t.id = s.tenant_id
order by t.slug, s.sort_order;
-- expect: 5 rows per tenant: available (all true, default), training, meeting (working, paid,
--         billable, not productive), break (paid, billable, not working), lunch (nothing)

select t.slug, o.key, o.timezone
from cma_read.organisation o
join cma_read.tenant t on t.id = o.tenant_id
order by 1, 2;
-- expect: newco Europe/Madrid (from 02); the others NULL (tenant default Europe/Amsterdam)

-- C. As the application: open, end, "ended stays ended" ---------------------------------------- expected error
begin;
set local role cma_owner;
-- two throwaway agents in the Subscriptions tenant; gone at rollback
select set_config('app.tenant_id', (select id::text from cma.tenant where slug = 'pulse4all-subscriptions'), true);
insert into cma.app_user (tenant_id, email, display_name)
values (cma.current_tenant_id(), 'verify.one@example.com', 'Verify One'),
       (cma.current_tenant_id(), 'verify.two@example.com', 'Verify Two');
insert into cma.user_role (tenant_id, user_id, role_id)
select u.tenant_id, u.id, r.id from cma.app_user u
join cma.app_role r on r.tenant_id = u.tenant_id and r.key = 'agent'
where u.email in ('verify.one@example.com', 'verify.two@example.com');
set local role cma_app;
select set_config('app.user_id', (select id::text from cma.app_user where email = 'verify.one@example.com'), true);
select (cma.open_workday()).status;                              -- expect: open
select status, started_at = ended_at as zero_length
from cma.end_workday((cma.open_workday()).id);                   -- expect: ended, true (now() is fixed inside one
                                                                 --         transaction; the app uses one per call)
select (cma.open_workday()).status;                              -- expect: ended (same day, stays ended)
select cma.end_workday((cma.open_workday()).id);
-- expected error: workday ... is already ended; resuming is a correction  (SQLSTATE CMA03)
rollback;

-- D. The write functions are bound to the acting user ----------------------------------------- expected error
begin;
set local role cma_owner;
-- two throwaway agents in the Subscriptions tenant; gone at rollback
select set_config('app.tenant_id', (select id::text from cma.tenant where slug = 'pulse4all-subscriptions'), true);
insert into cma.app_user (tenant_id, email, display_name)
values (cma.current_tenant_id(), 'verify.one@example.com', 'Verify One'),
       (cma.current_tenant_id(), 'verify.two@example.com', 'Verify Two');
insert into cma.user_role (tenant_id, user_id, role_id)
select u.tenant_id, u.id, r.id from cma.app_user u
join cma.app_role r on r.tenant_id = u.tenant_id and r.key = 'agent'
where u.email in ('verify.one@example.com', 'verify.two@example.com');
set local role cma_app;
select set_config('app.user_id', (select id::text from cma.app_user where email = 'verify.one@example.com'), true);
select (cma.open_workday()).status;                              -- expect: open
-- switch to the second agent and try to end the first one's day
select set_config('app.user_id', (select id::text from cma.app_user where email = 'verify.two@example.com'), true);
select cma.end_workday((select w.id from cma.workday w
                        join cma.app_user u on u.tenant_id = w.tenant_id and u.id = w.user_id
                        where u.email = 'verify.one@example.com' and w.business_date = cma.business_date(now(), w.timezone)));
-- expected error: a user can only end their own workday  (SQLSTATE CMA02)
rollback;

-- E. (dev) The fixture through the application's eyes: hours per day, flags -------------------------------
begin;
set local role cma_app;
select set_config('app.tenant_id', (select id::text from cma.tenant where slug = 'pulse4all-subscriptions'), true);
select u.email, s.business_date, s.status,
       round(s.working_seconds / 3600.0, 2) as working_h,
       round(s.paid_seconds    / 3600.0, 2) as paid_h,
       s.is_capped, s.needs_correction, s.has_correction
from cma.workday_summary s
join cma.app_user u on u.tenant_id = s.tenant_id and u.id = s.user_id
order by u.email, s.business_date;
-- expect: agent.one: day-3 ended 8.00 working and 8.00 paid (the 30 min lunch counts for neither),
--         day-2 ended 5.92, day-1 ended 8.07 with has_correction true (the manager's end at 17:02);
--         agent.two: day-2 OPEN, is_capped true, needs_correction true, 14.00 working (10:00 to
--         midnight Madrid, capped), day-1 ended 8.00
rollback;

-- F. Tenant isolation through the views, and the core views stay closed ---------------------------------
begin;
set local role cma_app;
select count(*) as no_tenant_set from cma.workday_summary;       -- expect: 0 (fail closed)
select set_config('app.tenant_id', (select id::text from cma.tenant where slug = 'pulse4all-invest'), true);
select count(*) as invest_days from cma.workday_summary;         -- expect: 0 (the fixture is all Subscriptions)
select set_config('app.tenant_id', (select id::text from cma.tenant where slug = 'pulse4all-subscriptions'), true);
select count(*) as subs_days from cma.workday_summary;           -- expect: dev 5, prod 0
rollback;
select count(*) as reader_sees_all from cma_read.workday_summary;   -- as yourself: dev 5, prod 0
begin;
set local role cma_app;
select set_config('app.tenant_id', (select id::text from cma.tenant where slug = 'pulse4all-subscriptions'), true);
select count(*) from cma.workday_summary_all;
-- expected error: permission denied for view workday_summary_all (the unfiltered core is owner-only)
rollback;

-- G. Facts are append-only for the application ------------------------------------------------ expected error
begin;
set local role cma_app;
select set_config('app.tenant_id', (select id::text from cma.tenant where slug = 'pulse4all-subscriptions'), true);
update cma.time_event set occurred_at = now();
-- expected error: permission denied for table time_event
rollback;
begin;
set local role cma_app;
select set_config('app.tenant_id', (select id::text from cma.tenant where slug = 'pulse4all-subscriptions'), true);
delete from cma.time_event;
-- expected error: permission denied for table time_event
rollback;

-- H. (dev) A correction: new row with reason and approver, the original stays ----------------------------
begin;
set local role cma_app;
select set_config('app.tenant_id', (select id::text from cma.tenant where slug = 'pulse4all-subscriptions'), true);
select set_config('app.user_id', (select id::text from cma.app_user where email = 'manager@example.com'), true);
-- Agent Two's forgotten day from two days ago: the manager ends it at 18:00 Madrid
select (cma.correct_time_event(
          w.id, 'end', ((w.business_date) + time '18:00') at time zone w.timezone,
          null, null, 'Forgot to end the workday', cma.current_user_id())).kind
from cma.workday w
join cma.app_user u on u.tenant_id = w.tenant_id and u.id = w.user_id
where u.email = 'agent.two@example.com' and w.status = 'open';                 -- expect: end
select s.business_date, s.status, round(s.working_seconds / 3600.0, 2) as working_h, s.needs_correction, s.has_correction
from cma.workday_summary s
join cma.app_user u on u.tenant_id = s.tenant_id and u.id = s.user_id
where u.email = 'agent.two@example.com' order by 1;                              -- expect: day-2 ended 8.00 false true
-- the audit trail names the manager as actor and the correction row carries the approver
select e.kind, e.source, e.reason is not null as has_reason, e.approved_by = cma.current_user_id() as approved_by_manager,
       a.actor_user_id = cma.current_user_id() as actor_is_manager, a.actor_db_role
from cma.time_event e
join cma.audit_log a on a.table_name = 'time_event' and a.row_id = e.id::text and a.action = 'insert'
where e.source = 'correction'
  and e.user_id = (select id from cma.app_user where email = 'agent.two@example.com');
-- expect: end, correction, true, true, true, cma_app
rollback;   -- the correction is discarded; the fixture keeps its open day for the web app

-- I. A correction without the right to correct ------------------------------------------------- expected error
begin;
set local role cma_owner;
-- two throwaway agents in the Subscriptions tenant; gone at rollback
select set_config('app.tenant_id', (select id::text from cma.tenant where slug = 'pulse4all-subscriptions'), true);
insert into cma.app_user (tenant_id, email, display_name)
values (cma.current_tenant_id(), 'verify.one@example.com', 'Verify One'),
       (cma.current_tenant_id(), 'verify.two@example.com', 'Verify Two');
insert into cma.user_role (tenant_id, user_id, role_id)
select u.tenant_id, u.id, r.id from cma.app_user u
join cma.app_role r on r.tenant_id = u.tenant_id and r.key = 'agent'
where u.email in ('verify.one@example.com', 'verify.two@example.com');
set local role cma_app;
select set_config('app.user_id', (select id::text from cma.app_user where email = 'verify.one@example.com'), true);
-- an agent (no workday.team) tries to end their own day through a correction
select cma.has_permission(cma.current_user_id(), 'workday.team') as agent_may_correct;   -- expect: false
select cma.correct_time_event((cma.open_workday()).id, 'end', now(), null, null, 'I forgot', cma.current_user_id());
-- expected error: user ... may not correct time (needs workday.team)  (SQLSTATE CMA04)
--   after migration 0003: user ... lacks permission workday.team  (SQLSTATE CMA06)
rollback;

-- J. A correction row needs reason and approver, even for the owner ---------------------------- expected error
begin;
set local role cma_owner;
-- two throwaway agents in the Subscriptions tenant; gone at rollback
select set_config('app.tenant_id', (select id::text from cma.tenant where slug = 'pulse4all-subscriptions'), true);
insert into cma.app_user (tenant_id, email, display_name)
values (cma.current_tenant_id(), 'verify.one@example.com', 'Verify One'),
       (cma.current_tenant_id(), 'verify.two@example.com', 'Verify Two');
insert into cma.user_role (tenant_id, user_id, role_id)
select u.tenant_id, u.id, r.id from cma.app_user u
join cma.app_role r on r.tenant_id = u.tenant_id and r.key = 'agent'
where u.email in ('verify.one@example.com', 'verify.two@example.com');
set local role cma_app;
select set_config('app.user_id', (select id::text from cma.app_user where email = 'verify.one@example.com'), true);
select (cma.open_workday()).status;                              -- expect: open
set local role cma_owner;                                        -- the owner bypasses RLS, not the constraints
insert into cma.time_event (tenant_id, workday_id, user_id, kind, occurred_at, source)
select w.tenant_id, w.id, w.user_id, 'end', now(), 'correction'
from cma.workday w join cma.app_user u on u.tenant_id = w.tenant_id and u.id = w.user_id
where u.email = 'verify.one@example.com';
-- expected error: new row for relation "time_event" violates check constraint
--                 "time_event_correction_needs_reason_and_approver"
rollback;

-- K. (dev) Login lookup before a tenant is known ----------------------------------------------------------
begin;
set local role cma_app;
-- no app.tenant_id set on purpose: this is what the login calls first
select t.slug
from cma.find_tenants_for_identity('mock', 'agent-one') f
join cma.tenant t on t.id = f.tenant_id
order by 1;
-- expect: pulse4all-invest, pulse4all-subscriptions (same person in two tenants: the picker case)
select count(*) as unknown_subject from cma.find_tenants_for_identity('mock', 'nobody');   -- expect: 0
select count(*) as wrong_system    from cma.find_tenants_for_identity('google', 'agent-one'); -- expect: 0
rollback;
