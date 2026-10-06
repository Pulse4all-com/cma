-- =============================================================================================
-- 08_fixture_api_verify_dev.sql  ·  DEV ONLY  ·  fixture for web/verify/api.mjs
-- =============================================================================================
-- Closes every forgotten clock-out of Agent Two: each open workday before today in that day's
-- zone, the one seeded by 06_seed_dev_time_model.sql and the ones the verifier leaves behind
-- (it logs Agent Two in and keeps that day open). Each gets a correction at 17:00 in its zone,
-- or one minute after its start when it started later: made by the test supervisor, approved by
-- the test manager (four eyes, both hold workday.team).
--
-- Runs through the real write path: as cma_app, tenant and acting user set for the transaction,
-- cma.correct_time_event(). Nothing is written as the owner.
--
-- Safe to rerun: days that are no longer open are left alone.
-- Refuses to run where no mock identities exist, so it can never touch prod.
--
-- Run in Cloud SQL Studio on cma-dev-pg, database cma, as yourself (IAM). Expected output: a
-- notice "fixture: corrected <date> ..." per closed day, or "fixture: nothing open; last
-- corrected <date>".
-- Replaced by the verifier closing its own days once corrections have an API route.
-- =============================================================================================

set role cma_app;

do $$
declare
  v_tenant uuid;
  v_sup    uuid;
  v_mgr    uuid;
  v_agent  uuid;
  w        cma.workday;
  v_end    timestamptz;
  v_count  int := 0;
begin
  -- Dev guard: mock identities exist only in the dev seed
  select tenant_id into v_tenant from cma.find_tenants_for_identity('mock', 'supervisor');
  if v_tenant is null then
    raise exception 'dev fixture: no mock identity "supervisor" here; this script is for dev only';
  end if;
  perform set_config('app.tenant_id', v_tenant::text, true);

  select user_id into strict v_sup   from cma.app_user_external_id where system = 'mock' and external_id = 'supervisor';
  select user_id into strict v_mgr   from cma.app_user_external_id where system = 'mock' and external_id = 'manager';
  select user_id into strict v_agent from cma.app_user_external_id where system = 'mock' and external_id = 'agent-two';

  -- The acting user is the supervisor making the corrections
  perform set_config('app.user_id', v_sup::text, true);

  -- Every day of Agent Two that was never ended, before today in that day's zone
  for w in
    select * from cma.workday
     where user_id = v_agent
       and status = 'open'
       and business_date < cma.business_date(now(), timezone)
     order by business_date
  loop
    v_end := greatest((w.business_date + time '17:00') at time zone w.timezone,
                      w.started_at + interval '1 minute');
    perform cma.correct_time_event(
      w.id, 'end', v_end, null, null,
      'Forgot to clock out; end confirmed with the agent (dev fixture for verify/api.mjs)',
      v_mgr);
    select * into w from cma.workday where id = w.id;
    raise notice 'fixture: corrected % for Agent Two, now % from % to % (%)',
      w.business_date, w.status, w.started_at at time zone w.timezone, w.ended_at at time zone w.timezone, w.timezone;
    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    select wd.* into w from cma.workday wd
     where wd.user_id = v_agent
       and exists (select 1 from cma.time_event e where e.workday_id = wd.id and e.source = 'correction')
     order by wd.business_date desc limit 1;
    if found then
      raise notice 'fixture: nothing open; last corrected % (ended %)', w.business_date, w.ended_at at time zone w.timezone;
      return;
    end if;
    raise exception 'dev fixture: Agent Two has no open past workday and no correction; rerun 06_seed_dev_time_model.sql';
  end if;
end
$$;

reset role;
