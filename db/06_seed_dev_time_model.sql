-- CMA seed: dev test data for the time model (fictional). Dev only, never run in prod.
-- Run as yourself (IAM login) after 05_time_model.sql. Safe to rerun.
--
-- Three things for the dev web app:
--   1. Login ids for the test users under system 'mock'. In dev the web app runs behind Cloud Run
--      IAM (gcloud run services proxy), not IAP, so its identity is the mock identity with
--      provider 'mock' and subject 'agent-one', 'agent-two', 'supervisor', 'manager', 'analyst',
--      'admin' (web/src/lib/auth). A mock subject
--      can therefore never match a real Google row, in dev or anywhere else. Real pulse4all.com
--      users get system 'google' with the account's numeric id, in the prod people seed.
--   2. A personal time zone for Agent Two, so the user override is exercised next to the employer
--      default (Newco: Europe/Madrid, set in 02_seed_pulse4all.sql).
--   3. A short history written through the same functions the application uses: ended days, a
--      pause, a forgotten clock-out fixed by the manager, and an open day from the day before
--      yesterday that nobody ended. Written once; rerunning skips it.
-- Guard: scripts run under a personal IAM login so the audit trail names a person. postgres is
-- for emergencies only; to use it deliberately, run first:  set cma.emergency = 'on';
do $$
begin
  if session_user = 'postgres' and coalesce(current_setting('cma.emergency', true), '') <> 'on' then
    raise exception 'Run this script under your personal IAM login, not postgres (emergency override: set cma.emergency = ''on'')';
  end if;
end
$$;
set role cma_owner;

-- 1. Mock login ids ---------------------------------------------------------------------------
do $$
declare
  v_subs uuid := (select id from cma.tenant where slug = 'pulse4all-subscriptions');
  v_inv  uuid := (select id from cma.tenant where slug = 'pulse4all-invest');
begin
  insert into cma.app_user_external_id (tenant_id, user_id, system, external_id)
  select u.tenant_id, u.id, 'mock', s.subject
  from (values
    (v_subs, 'agent.one@example.com',  'agent-one'),
    (v_subs, 'agent.two@example.com',  'agent-two'),
    (v_subs, 'supervisor@example.com', 'supervisor'),
    (v_subs, 'manager@example.com',    'manager'),
    (v_subs, 'analyst@example.com',    'analyst'),      -- analytics: no workday.own, so no clock (0003d)
    (v_subs, 'admin@example.com',      'admin'),        -- admin (0004): the Team screen's full rights
    (v_inv,  'agent.one@example.com',  'agent-one')     -- same person in two tenants: the login shows a tenant picker
  ) as s(tenant_id, email, subject)
  join cma.app_user u on u.tenant_id = s.tenant_id and u.email = s.email
  on conflict do nothing;

  -- 2. Personal time zone for one user
  update cma.app_user set timezone = 'Europe/Amsterdam'
  where tenant_id = v_subs and email = 'agent.two@example.com' and timezone is distinct from 'Europe/Amsterdam';
end
$$;

-- 3. History, written through the write path as the users themselves -------------------------
-- Days are relative to today so the My hours screen always has something in "this week".
do $$
declare
  v_subs     uuid := (select id from cma.tenant where slug = 'pulse4all-subscriptions');
  v_one      uuid := (select id from cma.app_user where tenant_id = v_subs and email = 'agent.one@example.com');
  v_two      uuid := (select id from cma.app_user where tenant_id = v_subs and email = 'agent.two@example.com');
  v_manager  uuid := (select id from cma.app_user where tenant_id = v_subs and email = 'manager@example.com');
  v_tz       text := 'Europe/Madrid';
  -- statuses from the tenant's own list (02), chosen by flag: the fixture assumes no key
  v_default  text := (select key from cma.work_status
                      where tenant_id = v_subs and is_default and status = 'active');
  v_pause    text := (select key from cma.work_status
                      where tenant_id = v_subs and not is_working and status = 'active'
                      order by sort_order limit 1);
  w          cma.workday;
begin
  if exists (select 1 from cma.workday where tenant_id = v_subs and user_id in (v_one, v_two)) then
    raise notice 'time model fixture already present, skipped';
    return;
  end if;

  perform set_config('app.tenant_id', v_subs::text, true);
  perform set_config('app.actor_label', 'seed:dev-time-model', true);

  -- Agent One, three days ago: a full day with lunch
  perform set_config('app.user_id', v_one::text, true);
  w := cma.open_workday(((current_date - 3) + time '09:00') at time zone v_tz);
  perform cma.set_status(w.id, v_pause,     ((current_date - 3) + time '13:00') at time zone v_tz);
  perform cma.set_status(w.id, v_default,   ((current_date - 3) + time '13:30') at time zone v_tz);
  perform cma.end_workday(w.id,             ((current_date - 3) + time '17:30') at time zone v_tz);

  -- Agent One, two days ago: a short day
  w := cma.open_workday(((current_date - 2) + time '09:05') at time zone v_tz);
  perform cma.end_workday(w.id,             ((current_date - 2) + time '15:00') at time zone v_tz);

  -- Agent One, yesterday: forgot to end the day; the manager corrects it with an end at 17:02
  w := cma.open_workday(((current_date - 1) + time '08:58') at time zone v_tz);
  perform set_config('app.user_id', v_manager::text, true);
  perform cma.correct_time_event(w.id, 'end', ((current_date - 1) + time '17:02') at time zone v_tz,
                                 null, null, 'Forgot to end the workday; left the office at 17:00 per team lead',
                                 v_manager);

  -- Agent Two, two days ago: forgot to end the day and nobody fixed it yet (needs_correction)
  perform set_config('app.user_id', v_two::text, true);
  w := cma.open_workday(((current_date - 2) + time '10:00') at time zone v_tz);

  -- Agent Two, yesterday: a normal day
  w := cma.open_workday(((current_date - 1) + time '09:00') at time zone v_tz);
  perform cma.end_workday(w.id,             ((current_date - 1) + time '17:00') at time zone v_tz);

  raise notice 'time model fixture written';
end
$$;
