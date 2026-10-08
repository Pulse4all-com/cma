-- CMA seed: dev test data for the roster (fictional). Dev only, never run in prod.
-- Run as yourself (IAM login) after 23_roster.sql (0005), 02_seed_pulse4all.sql (the teams) and
-- 03_seed_dev_test_data.sql (the memberships). Safe to rerun: written once, a rerun skips it.
--
-- Written through the same functions the planner uses, as the test manager (roster.manage), so the
-- audit rows name a person and every rule of 0005 applies (today and ahead only, one entry per
-- person per date). Relative to the current week, so the planner, My schedule and the Live board
-- always have something to show:
--   this week, Team NL (Agent One, the supervisor): shifts from today to Friday, published, then one
--     cell changed afterwards, so the planner shows "changed since publish" and the agent keeps
--     seeing the published time
--   this week, Team Nordics (Agent Two): shifts from today to Thursday, leave on Friday, published
--   next week, Team NL: a draft with shifts for both and a day off, not published, so My schedule
--     says the week is not published yet
-- On a Saturday or Sunday the current week gets only the weekend cells it can still write.
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

do $$
declare
  v_subs    uuid := (select id from cma.tenant where slug = 'pulse4all-subscriptions');
  v_manager uuid := (select id from cma.app_user where tenant_id = v_subs and email = 'manager@example.com');
  v_one     uuid := (select id from cma.app_user where tenant_id = v_subs and email = 'agent.one@example.com');
  v_two     uuid := (select id from cma.app_user where tenant_id = v_subs and email = 'agent.two@example.com');
  v_super   uuid := (select id from cma.app_user where tenant_id = v_subs and email = 'supervisor@example.com');
  v_week    date;
  v_next    date;
  v_today   date;
  d         date;
  n         integer := 0;
begin
  if to_regclass('cma.roster_entry') is null then
    raise notice 'roster fixture skipped: migration 0005 (23_roster.sql) has not run';
    return;
  end if;
  if v_manager is null or v_one is null or v_two is null or v_super is null then
    raise notice 'roster fixture skipped: the dev people are missing (03_seed_dev_test_data.sql)';
    return;
  end if;
  if not exists (select 1 from cma.team_member m join cma.team t on t.tenant_id = m.tenant_id and t.id = m.team_id
                 where m.tenant_id = v_subs and m.user_id = v_one and t.key = 'nl' and m.valid_to is null) then
    raise notice 'roster fixture skipped: the dev memberships are missing (rerun 03_seed_dev_test_data.sql)';
    return;
  end if;
  if exists (select 1 from cma.roster_week where tenant_id = v_subs) then
    raise notice 'roster fixture already present, skipped';
    return;
  end if;

  perform set_config('app.tenant_id', v_subs::text, true);
  perform set_config('app.user_id', v_manager::text, true);
  perform set_config('app.actor_label', 'seed:dev-roster', true);

  -- Today in the planner's own zone decides which cells of this week can still be written
  v_today := cma.business_date(now(), cma.user_timezone(v_manager));
  v_week  := cma.week_start(v_today);
  v_next  := v_week + 7;

  -- This week, Team NL: Agent One and the supervisor, weekdays from today
  for d in select v_week + i from generate_series(0, 4) as i loop
    if d >= v_today then
      perform cma.roster_set_entry(v_week, 'nl', v_one,   d, 'shift', '09:00', '17:30', null, null);
      perform cma.roster_set_entry(v_week, 'nl', v_super, d, 'shift', '08:30', '17:00', null, null);
      n := n + 2;
    end if;
  end loop;
  perform cma.roster_publish(v_week, 'nl');
  -- One change after the publish: Agent One's last writable weekday ends early, unpublished
  for d in select v_week + i from generate_series(4, 0, -1) as i loop
    if d >= v_today then
      perform cma.roster_set_entry(v_week, 'nl', v_one, d, 'shift', '09:00', '15:00', null, 'Dentist, agreed with Arno');
      exit;
    end if;
  end loop;

  -- This week, Team Nordics: Agent Two, Monday to Thursday on shift, Friday on leave
  for d in select v_week + i from generate_series(0, 3) as i loop
    if d >= v_today then
      perform cma.roster_set_entry(v_week, 'nordics', v_two, d, 'shift', '10:00', '18:00', null, null);
      n := n + 1;
    end if;
  end loop;
  if v_week + 4 >= v_today then
    perform cma.roster_set_entry(v_week, 'nordics', v_two, v_week + 4, 'absence', null, null, 'leave', null);
  end if;
  perform cma.roster_publish(v_week, 'nordics');

  -- Next week, Team NL: a draft, not published
  for d in select v_next + i from generate_series(0, 4) as i loop
    perform cma.roster_set_entry(v_next, 'nl', v_one, d, 'shift', '09:00', '17:30', null, null);
  end loop;
  perform cma.roster_set_entry(v_next, 'nl', v_super, v_next,     'shift', '08:30', '17:00', null, null);
  perform cma.roster_set_entry(v_next, 'nl', v_super, v_next + 1, 'shift', '08:30', '17:00', null, null);
  perform cma.roster_set_entry(v_next, 'nl', v_super, v_next + 2, 'absence', null, null, 'off', null);
  perform cma.roster_set_entry(v_next, 'nl', v_super, v_next + 3, 'shift', '12:00', '20:00', null, null);
  perform cma.roster_set_entry(v_next, 'nl', v_super, v_next + 4, 'shift', '12:00', '20:00', null, null);

  raise notice 'roster fixture written (% cells this week, next week as a draft)', n;
end
$$;
