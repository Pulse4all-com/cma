-- CMA verify for migration 0003 (corrections)
-- Run as yourself (IAM login), no SET ROLE, after 09. Universal: block A reads structure, block B
-- reads existing days, block C creates two throwaway users and their days inside one transaction that
-- is rolled back, so nothing stays behind (also no audit rows). Runs in dev and prod alike.
-- Keep the output as the release record in records/0003-<env>-<date>/.
--
-- Block C checks 10 refusals. Each expected refusal is caught and logged as a notice "PASS ..."
-- (Cloud SQL Studio does not show notices). A refusal that does not happen raises the error
-- "FAIL ...", and one with an unexpected code stops the block with that error: no error means all
-- 10 passed.

-- Guard: scripts run under a personal IAM login so the audit trail names a person. postgres is
-- for emergencies only; to use it deliberately, run first:  set cma.emergency = 'on';
do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;

-- A. Structure ----------------------------------------------------------------------------------------
select p.proname, p.prosecdef as security_definer,
       has_function_privilege('cma_app', p.oid, 'execute') as app_may_call
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'cma'
  and p.proname in ('assert_permission', 'correct_workday', 'team_hours', 'team_day',
                    'correct_time_event', 'refresh_workday')
order by 1;
-- expect: 6 rows, security_definer false, app_may_call true

set role cma_owner;
select version, description, applied_by, applied_at::date from cma.schema_migration order by 1;
reset role;
-- expect: 0001, 0002 and 0003, applied_by your IAM login

-- B. Existing days already meet the new rule --------------------------------------------------------
-- refresh_workday now refuses a status or end before the start; no stored day may break it
set role cma_owner;
select count(*) as events_before_start
from cma.time_event_effective_all e
join cma.workday w on w.tenant_id = e.tenant_id and w.id = e.workday_id
where e.kind in ('status', 'end') and e.occurred_at < w.started_at;
reset role;
-- expect: 0

-- C. Corrections as the application (rolled back) ------------------------------------------------------
begin;
set local role cma_owner;
-- the first tenant with a role that holds workday.team; roles are picked by permission, never by name
select set_config('app.tenant_id',
  (select tenant_id::text from cma.role_permission where permission_key = 'workday.team' order by tenant_id limit 1), true);
insert into cma.app_user (tenant_id, email, display_name)
values (cma.current_tenant_id(), 'verify.agent@example.com', 'Verify Agent'),
       (cma.current_tenant_id(), 'verify.lead@example.com',  'Verify Lead');
insert into cma.user_role (tenant_id, user_id, role_id)
select cma.current_tenant_id(),
       (select id from cma.app_user where tenant_id = cma.current_tenant_id() and email = 'verify.lead@example.com'),
       (select role_id from cma.role_permission
        where tenant_id = cma.current_tenant_id() and permission_key = 'workday.team' order by role_id limit 1)
union all
select cma.current_tenant_id(),
       (select id from cma.app_user where tenant_id = cma.current_tenant_id() and email = 'verify.agent@example.com'),
       (select rp.role_id from cma.role_permission rp
        where rp.tenant_id = cma.current_tenant_id() and rp.permission_key = 'workday.own'
          and not exists (select 1 from cma.role_permission x
                          where x.tenant_id = rp.tenant_id and x.role_id = rp.role_id and x.permission_key = 'workday.team')
        order by rp.role_id limit 1);
set local role cma_app;

-- the lead acts; the agent's day is yesterday in the agent's zone; times are ISO strings with offset
select set_config('verify.lead',  (select id::text from cma.app_user where email = 'verify.lead@example.com'),  true),
       set_config('verify.agent', (select id::text from cma.app_user where email = 'verify.agent@example.com'), true);
select set_config('app.user_id', current_setting('verify.lead'), true),
       set_config('verify.tz', cma.user_timezone(current_setting('verify.agent')::uuid), true),
       set_config('verify.default', (select key from cma.work_status where is_default and status = 'active'), true),
       set_config('verify.other', (select key from cma.work_status where not is_default and status = 'active'
                                   order by sort_order limit 1), true);
select set_config('verify.day', (cma.business_date(now(), current_setting('verify.tz')) - 1)::text, true);
select set_config('verify.at' || h, to_jsonb((current_setting('verify.day')::date + (h || ':00')::time)
                                             at time zone current_setting('verify.tz')) #>> '{}', true)
from unnest(array['08', '09', '11', '12', '17']) h;

-- C1. Add day: a day for a date without one, start and end in one edit
select (cma.correct_workday(
          current_setting('verify.agent')::uuid, current_setting('verify.day')::date,
          jsonb_build_array(
            jsonb_build_object('kind', 'start', 'statusKey', current_setting('verify.default'), 'at', current_setting('verify.at09')),
            jsonb_build_object('kind', 'end', 'at', current_setting('verify.at17'))),
          'Forgot to clock in; hours confirmed with the agent')).status;
-- expect: ended
-- read the result in its own statement: a query sees the data as it was when it started
select status, round(working_seconds / 3600.0, 2) as working_h, has_correction
from cma.workday_summary
where user_id = current_setting('verify.agent')::uuid and business_date = current_setting('verify.day')::date;
-- expect: ended, 8.00 (when the default status counts as working), true

-- C2. A status at 12:00, then one edit that passes through an invalid state: the end moves to 11:00
--     first (before the 12:00 status, invalid alone), then the 12:00 status is voided
select (cma.correct_workday(current_setting('verify.agent')::uuid, current_setting('verify.day')::date,
          jsonb_build_array(jsonb_build_object('kind', 'status', 'statusKey', current_setting('verify.other'),
                                               'at', current_setting('verify.at12'))),
          'Lunch was not recorded')).status;
-- expect: ended
select (cma.correct_workday(
          current_setting('verify.agent')::uuid, current_setting('verify.day')::date,
          jsonb_build_array(
            jsonb_build_object('kind', 'end', 'at', current_setting('verify.at11'),
                               'supersedes', (select id from cma.time_event_effective
                                              where user_id = current_setting('verify.agent')::uuid and kind = 'end')),
            jsonb_build_object('kind', 'void',
                               'supersedes', (select id from cma.time_event_effective
                                              where user_id = current_setting('verify.agent')::uuid and kind = 'status'))),
          'Left at 11:00; no lunch taken')).status;
-- expect: ended
select status, ended_at = current_setting('verify.at11')::timestamptz as ends_at_11,
       round(working_seconds / 3600.0, 2) as working_h
from cma.workday_summary
where user_id = current_setting('verify.agent')::uuid and business_date = current_setting('verify.day')::date;
-- expect: ended, true, 2.00 (when the default status counts as working)

-- C3. The day editor sees every row; superseded and voided rows stay, with approver
select kind, status_key, source, is_effective, approved_by_name, reason is not null as has_reason
from cma.team_day(current_setting('verify.agent')::uuid, current_setting('verify.day')::date);
-- expect: 5 rows in time order: start effective; end (11:00) effective; status (12:00) not effective;
--         end (17:00) not effective; void (timed now) not effective. All source correction, approver
--         Verify Lead, with a reason

select display_name, status, round(working_seconds / 3600.0, 2) as working_h, needs_correction, has_correction
from cma.team_hours(current_setting('verify.day')::date, current_setting('verify.day')::date,
                    current_setting('verify.agent')::uuid);
-- expect: Verify Agent, ended, 2.00, false, true

-- C4. Refusals: expect 10 notices "PASS"
do $$ begin
  perform cma.correct_workday(current_setting('verify.lead')::uuid, current_setting('verify.day')::date,
    jsonb_build_array(jsonb_build_object('kind', 'start', 'statusKey', current_setting('verify.default'),
                                         'at', current_setting('verify.at09'))), 'Own day');
  raise exception 'FAIL  own day: accepted';
exception when sqlstate 'CMA06' then raise notice 'PASS  nobody corrects their own day (CMA06)';
end $$;

do $$ begin
  perform cma.correct_workday(current_setting('verify.agent')::uuid, current_setting('verify.day')::date - 1,
    jsonb_build_array(jsonb_build_object('kind', 'start', 'statusKey', current_setting('verify.default'),
                                         'at', current_setting('verify.at09')::timestamptz - interval '1 day'),
                      jsonb_build_object('kind', 'status', 'statusKey', current_setting('verify.other'),
                                         'at', current_setting('verify.at08')::timestamptz - interval '1 day')),
    'Status before the start');
  raise exception 'FAIL  status before the start: accepted';
exception when sqlstate 'CMA04' then raise notice 'PASS  a status before the start is refused (CMA04)';
end $$;

do $$ begin
  perform cma.correct_workday(current_setting('verify.agent')::uuid, current_setting('verify.day')::date - 1,
    jsonb_build_array(jsonb_build_object('kind', 'start', 'statusKey', current_setting('verify.default'),
                                         'at', current_setting('verify.at09'))),   -- yesterday's 09:00, not the day before
    'Outside the day');
  raise exception 'FAIL  time outside the day: accepted';
exception when sqlstate 'CMA04' then raise notice 'PASS  a time outside the corrected day is refused (CMA04)';
end $$;

do $$ begin
  perform cma.correct_workday(current_setting('verify.agent')::uuid, current_setting('verify.day')::date - 1,
    jsonb_build_array(jsonb_build_object('kind', 'start', 'statusKey', current_setting('verify.default'),
                                         'at', (current_setting('verify.day')::date - 1)::text || 'T09:00:00')),
    'No offset');
  raise exception 'FAIL  time without offset: accepted';
exception when sqlstate 'CMA04' then raise notice 'PASS  a time without offset is refused (CMA04)';
end $$;

do $$ begin
  perform cma.correct_workday(current_setting('verify.agent')::uuid, current_setting('verify.day')::date + 2,
    jsonb_build_array(jsonb_build_object('kind', 'start', 'statusKey', current_setting('verify.default'),
                                         'at', current_setting('verify.at09')::timestamptz + interval '2 days')),
    'Tomorrow');
  raise exception 'FAIL  future date: accepted';
exception when sqlstate 'CMA04' then raise notice 'PASS  a future date is refused (CMA04)';
end $$;

do $$ begin
  perform cma.correct_workday(current_setting('verify.agent')::uuid, current_setting('verify.day')::date - 1,
    jsonb_build_array(jsonb_build_object('kind', 'end', 'at', current_setting('verify.at17')::timestamptz - interval '1 day')),
    'No start');
  raise exception 'FAIL  new day without a start: accepted';
exception when sqlstate 'CMA04' then raise notice 'PASS  a new day must begin with its start (CMA04)';
end $$;

do $$ begin
  perform cma.correct_workday(current_setting('verify.agent')::uuid, current_setting('verify.day')::date,
    jsonb_build_array(jsonb_build_object('kind', 'status', 'statusKey', current_setting('verify.default'),
                                         'at', current_setting('verify.at09'))), '  ');
  raise exception 'FAIL  empty reason: accepted';
exception when sqlstate 'CMA04' then raise notice 'PASS  a correction needs a reason (CMA04)';
end $$;

do $$ begin
  perform cma.correct_workday('00000000-0000-7000-8000-00000000dead', current_setting('verify.day')::date,
    jsonb_build_array(jsonb_build_object('kind', 'start', 'statusKey', current_setting('verify.default'),
                                         'at', current_setting('verify.at09'))), 'Unknown person');
  raise exception 'FAIL  unknown user: accepted';
exception when sqlstate 'CMA02' then raise notice 'PASS  an unknown user is not found (CMA02)';
end $$;

do $$ begin
  perform cma.correct_time_event(
    (select id from cma.workday where user_id = current_setting('verify.agent')::uuid),
    'status', current_setting('verify.at12')::timestamptz, current_setting('verify.default'), null,
    'Someone else approves', current_setting('verify.agent')::uuid);
  raise exception 'FAIL  approver other than the acting user: accepted';
exception when sqlstate 'CMA04' then raise notice 'PASS  the approver is the person making the correction (CMA04)';
end $$;

do $$ begin
  perform set_config('app.user_id', current_setting('verify.agent'), true);
  perform cma.team_hours(current_setting('verify.day')::date, current_setting('verify.day')::date);
  raise exception 'FAIL  agent reads team hours: accepted';
exception when sqlstate 'CMA06' then raise notice 'PASS  team hours need workday.team (CMA06)';
end $$;

rollback;   -- the throwaway users and their days are discarded
