-- CMA seed: dev test data for the time model (fictional). Dev only, never run in prod.
-- Run as yourself (IAM login) after 05_time_model.sql. Safe to rerun.
--
-- Four things for the dev web app (the fourth, work areas, since addition 0009zn):
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
--   4. Work areas on the dev tenants' statuses, chosen by rule (section 4), so dev shows Sales and Operations.
--   5. Hours markets (since addition 0009zo): one dev market mapped to another and two dev people with a Default market,
--      chosen by rule (section 5), so dev shows a mapping, a clock-in under a Default market and one without.
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

-- 4. Work areas (after addition 0009zn, 228_work_area.sql; Martin, 23 November 2026) -----------
-- So dev shows Sales green and Operations Deep Blue in every hours view. Chosen by rule, naming no tenant and no status
-- key (D1): in a tenant with two or more active working, productive statuses and no work area anywhere yet, the first in
-- its order (sort order, then key) gets sales and the second operations; a tenant with one such status (the universal
-- ladder) keeps none, so its time stays Productive. Rerun-safe: a tenant that has a work area is left as it is, so a
-- change on Configuration → Statuses survives a rerun. Dev only: it does nothing where the dev seed's test person
-- (03_seed_dev_test_data.sql) does not exist, and nothing before 228 has run.
do $$
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'cma' and table_name = 'work_status' and column_name = 'work_area') then
    raise notice 'cma.work_status.work_area does not exist yet (addition 0009zn): rerun this seed after 228_work_area.sql';
    return;
  end if;
  if not exists (select 1 from cma.app_user where email = 'agent.two@example.com' and status = 'active') then
    raise notice 'not the dev database (no dev seed person): work areas skipped';
    return;
  end if;
  perform set_config('app.actor_label', 'seed:dev-time-model', true);   -- the audit trail names the process, as section 3
  with candidate as (
    select s.id, row_number() over (partition by s.tenant_id order by s.sort_order, s.key collate "C") as n,
           count(*) over (partition by s.tenant_id) as of_n
    from cma.work_status s
    where s.status = 'active' and s.is_working and s.is_productive
      and not exists (select 1 from cma.work_status a where a.tenant_id = s.tenant_id and a.work_area is not null)
  )
  update cma.work_status s
     set work_area = case c.n when 1 then 'sales' else 'operations' end
    from candidate c
   where s.id = c.id and c.of_n >= 2 and c.n <= 2;
end
$$;

-- 5. Hours markets (after addition 0009zo, 230_hours_market.sql; Martin and Kira, 23 November 2026) ---------------
-- So dev shows a market booked under another, and a clock-in with and without a Default market. Chosen by rule, naming no
-- tenant and no market (D1): in a tenant with three or more active markets of which none maps elsewhere yet, the last in
-- its order (sort order, then code) maps to the first; Agent One gets the tenant's first active hours market as Default
-- market and Agent Two its second (when there is one); the other dev people keep none, so their clock-in takes the market
-- of their last day. Rerun-safe: a tenant that maps a market already, and a person with a Default market, are left as
-- they are, so a change on Configuration → Markets or People survives a rerun. Dev only: it does nothing where the dev
-- seed's test person does not exist, and nothing before 230 has run. The tables' triggers (230, section 6) check each write.
do $$
declare
  t record;
  v_first text;
  v_last  text;
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'cma' and table_name = 'time_event' and column_name = 'hours_market_code') then
    raise notice 'cma.time_event.hours_market_code does not exist yet (addition 0009zo): rerun this seed after 230_hours_market.sql';
    return;
  end if;
  if not exists (select 1 from cma.app_user where email = 'agent.two@example.com' and status = 'active') then
    raise notice 'not the dev database (no dev seed person): hours markets skipped';
    return;
  end if;
  perform set_config('app.actor_label', 'seed:dev-time-model', true);   -- the audit trail names the process, as section 3
  -- only the tenants of the dev seed's people (03_seed_dev_test_data.sql), never another dev tenant
  for t in select x.id from cma.tenant x
           where exists (select 1 from cma.app_user u where u.tenant_id = x.id and u.email like '%@example.com')
           order by x.id loop
    if (select count(*) from cma.market m where m.tenant_id = t.id and m.status = 'active') >= 3
       and not exists (select 1 from cma.market m where m.tenant_id = t.id and m.hours_market_code <> m.code) then
      select m.code into v_first from cma.market m where m.tenant_id = t.id and m.status = 'active'
       order by m.sort_order, m.code collate "C" limit 1;
      select m.code into v_last from cma.market m where m.tenant_id = t.id and m.status = 'active'
       order by m.sort_order desc, m.code collate "C" desc limit 1;
      -- never a market someone holds as Default market (the table's trigger would refuse it): then nothing is mapped
      if not exists (select 1 from cma.app_user u where u.tenant_id = t.id and u.default_hours_market_code = v_last) then
        update cma.market set hours_market_code = v_first where tenant_id = t.id and code = v_last;
      end if;
    end if;
    with h as (
      select m.code, row_number() over (order by m.sort_order, m.code collate "C") as n
      from cma.market m
      where m.tenant_id = t.id and m.status = 'active' and m.hours_market_code = m.code
    )
    update cma.app_user u
       set default_hours_market_code = h.code
      from h
     where u.tenant_id = t.id and u.status = 'active' and u.default_hours_market_code is null
       and ((u.email = 'agent.one@example.com' and h.n = 1) or (u.email = 'agent.two@example.com' and h.n = 2));
  end loop;
end
$$;
