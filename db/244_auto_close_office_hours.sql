-- =============================================================================================
-- 244_auto_close_office_hours.sql: addition 0009zv, a forgotten workday closed at the end of the Default market's office
-- hours when no shift is published
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics: whether a tenant uses the office hours is the tenant setting
-- workday.auto_close_office_hours, off by default, so a tenant that sets nothing closes forgotten days exactly as before
-- (Decision log, 12 October 2026: defaults keep today's behaviour); Pulse4all Subscriptions' value (true) is seed data in
-- 02. Runs unchanged in every database, after 242_speed_to_lead_cockpit.sql (0009zu); it needs nothing of 240 (0009zt),
-- so in prod 244 runs before 240 while #321 waits. Rerunnable, forward-only, in one transaction with a lock timeout.
-- Run as your own IAM login: dev first, then 245_verify_auto_close_office_hours.sql there (normal, then provoked), then
-- 02_seed_pulse4all.sql again (Pulse4all Subscriptions' value), then the verifies that read cma.close_forgotten_workdays,
-- each still PASS and none edited: 27 (configuration: the scheduler's permission and a tenant without settings), 47
-- (the window and the close: throwaway tenants without the setting, so shift, default, last event and window end as
-- before) and 127 (split shifts: A8, a later session closed at its own start). Prod the same after the merge.
--
-- Why (Martin, 24 November 2026): the sweep closes a forgotten day at the person's published planned shift end, else at
-- workday.auto_close_at (Pulse4all 17:00). An agent who works a market's office hours without a published shift is
-- closed at 17:00 even when that market's office closes at 18:30. Between the two steps comes the end of the office hours
-- of the person's Default market on that weekday.
--
-- What it adds and changes
--   setting            workday.auto_close_office_hours (boolean, default false): whether the sweep closes a forgotten day
--                      without a published shift at the end of the office hours of the person's Default market
--   cma.office_hours_end_in(zone, weekdays, closes, holidays, date)
--                      new, reads no table: on a market's row of cma.business_calendar_of (178), the end of the last
--                      office-hours range of the date's weekday, placed on the date in the market's zone; null without a
--                      zone or a date, on a weekday without ranges (closed) and on a holiday of the market or of '*'
--                      (the calendar's holidays: no office hours that day, as Speed to lead's business time counts them)
--   cma.close_forgotten_workdays(integer)
--                      46's sweep (based on 46), signature and result unchanged; end_rule gains 'office_hours'. The close
--                      time, in order: (1) the published planned shift end for the business date ('shift', unchanged);
--                      (2) when the tenant's workday.auto_close_office_hours is true, the end of the Default market's
--                      office hours that day ('office_hours'), skipped without error when the person has no Default
--                      market, when it is no longer an active hours market (cma.is_hours_market, 230), or when the
--                      market has no office hours that day; (3) workday.auto_close_at ('default', unchanged). Then, as
--                      before: never after the window end, never before the day's last effective event ('last_event'),
--                      which keeps 0008zp's rule for a later session (an open later session that started after the
--                      result is ended at its own start). The Default market is read at sweep time. The office hours
--                      are the one definition Speed to lead's business time reads (cma.business_calendar_of: the
--                      market's own ranges when it has any, else the '*' row, in the market's zone; read once per run,
--                      only when the setting is on); no second reader of cma.business_hours. Everything else word for
--                      word: the system end under the Scheduler user, the person's message, the digest, the review flag
--
-- Not touched: the speed-to-lead functions, cma.business_calendar_of, cma.job_gate_of and the minute jobs. No table, view
-- or column changes (the data map is unchanged). The web reads no end_rule (jobs/close-forgotten-workdays.mjs takes
-- workday_id, user_id, business_date and ended_at), so its log line is unchanged.
--
-- SQLSTATEs as before: CMA01 no acting user, CMA02 not found, CMA03 conflict, CMA04 invalid, CMA05 tenant configuration
-- missing, CMA06 not permitted.
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
  if not exists (select 1 from cma.schema_migration where version = '0009zu') then
    raise exception 'addition 0009zu (242_speed_to_lead_cockpit.sql) must run before 0009zv';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The setting
-- ---------------------------------------------------------------------------------------------
-- A boolean: cma.check_tenant_setting() takes true or false for it without a branch of its own
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('workday.auto_close_office_hours', 'boolean', null, 'false',
     'Whether the scheduler ends a forgotten day without a published shift at the end of the office hours of the person''s Default market that day, before falling back to workday.auto_close_at')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- ---------------------------------------------------------------------------------------------
-- 2. The end of a market's office hours on a date
-- ---------------------------------------------------------------------------------------------
-- On a market's calendar row (cma.business_calendar_of): the end of the last range of the date's weekday, in the market's
-- zone. The ranges of one day never overlap (cma.check_business_hours), so the latest closing time is the last range's
-- end; 24:00 is the next midnight. Null without a zone or a date, on a weekday without ranges and on a holiday. Reads no
-- table (0009zv)
create or replace function cma.office_hours_end_in(p_zone text, p_weekdays integer[], p_closes time[], p_holidays date[], p_date date)
returns timestamptz
language sql stable
as $$
  select case when p_zone is null or p_date is null or p_date = any (coalesce(p_holidays, '{}'::date[])) then null
              else (select (p_date + max(h.closes_at)) at time zone p_zone
                    from unnest(p_weekdays, p_closes) h(weekday, closes_at)
                    where h.weekday = extract(isodow from p_date)) end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. The forgotten-day close
-- ---------------------------------------------------------------------------------------------
-- Ends every open workday of the current tenant whose window ended more than the grace ago (the parameter, else
-- workday.auto_close_grace_minutes). The end is the person's published planned shift end for that date (the latest
-- publication's entry, when it is a shift); else, when workday.auto_close_office_hours is true, the end of the office
-- hours of the person's Default market that day (an active hours market with office hours that day); else
-- workday.auto_close_at; never later than the window end and never earlier than the day's last effective event;
-- end_rule says which: 'shift', 'office_hours', 'default' or 'last_event'. Source 'system', the scheduler as acting user
-- and sender, actor label 'scheduler'. Then one message per closed day to that person and one digest per run to the
-- holders of workday.auto_close_notify_permission, both without names. The day stays needs_correction (0005a).
-- Idempotent: a second run closes and sends nothing.
-- based on: 46_workday_window.sql
create or replace function cma.close_forgotten_workdays(p_grace_minutes integer default null)
returns table (workday_id uuid, user_id uuid, business_date date, ended_at timestamptz, end_rule text)
language plpgsql
as $$
#variable_conflict use_column
declare
  v_tenant    uuid := cma.current_tenant_id();
  v_actor     uuid;
  v_grace     integer;
  v_close_at  time;
  v_office    boolean;
  v_perm      text;
  v_end       timestamptz;
  v_rule      text;
  v_msg       uuid;
  v_n         integer := 0;
  v_first     date;
  v_last      date;
  v_users     uuid[];
  w           record;
begin
  v_actor := cma.assert_permission('workday.close_forgotten');
  if cma.current_actor_label() is null then
    perform set_config('app.actor_label', 'scheduler', true);
  end if;
  v_grace := coalesce(p_grace_minutes, cma.setting_of(v_tenant, 'workday.auto_close_grace_minutes')::integer, 120);
  if v_grace < 0 then
    raise exception 'grace is 0 minutes or more' using errcode = 'CMA04';
  end if;
  v_close_at := cma.setting_of(v_tenant, 'workday.auto_close_at')::time;
  v_office   := coalesce(cma.setting_of(v_tenant, 'workday.auto_close_office_hours')::boolean, false);

  for w in
    -- the tenant's active hours markets with their office hours, read once per run and only when the setting is on
    with cal as materialized (
      select c.market, c.time_zone, c.weekdays, c.closes, c.holidays
      from cma.business_calendar_of(v_tenant) c
      where v_office and cma.is_hours_market(c.market)
    )
    select d.id, d.user_id, d.business_date, d.timezone,
           cma.business_day_end(d.business_date, d.timezone) as day_end,
           (select max(e.occurred_at) from cma.time_event_effective e
            where e.tenant_id = d.tenant_id and e.workday_id = d.id) as last_at,
           (select case when r.kind = 'shift' then cma.business_day_time(d.business_date, d.timezone, r.end_time) end
            from cma.roster_published_entry r
            where r.user_id = d.user_id and r.business_date = d.business_date
            order by r.published_at desc
            limit 1) as shift_end,
           -- the Default market as it stands now, at sweep time
           (select cma.office_hours_end_in(c.time_zone, c.weekdays, c.closes, c.holidays, d.business_date)
            from cma.app_user u
            join cal c on c.market = u.default_hours_market_code
            where u.tenant_id = d.tenant_id and u.id = d.user_id) as office_end
    from cma.workday d
    where d.tenant_id = v_tenant and d.status = 'open'
      and cma.business_day_end(d.business_date, d.timezone) + make_interval(mins => v_grace) <= now()
    order by d.business_date, d.user_id
    for update of d
  loop
    v_end  := least(coalesce(w.shift_end, w.office_end, cma.business_day_time(w.business_date, w.timezone, v_close_at)), w.day_end);
    v_rule := case when w.shift_end is not null then 'shift' when w.office_end is not null then 'office_hours' else 'default' end;
    if w.last_at > v_end then
      v_end  := w.last_at;
      v_rule := 'last_event';
    end if;
    insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, source)
    values (v_tenant, w.id, w.user_id, 'end', null, v_end, 'system');
    perform cma.refresh_workday(w.id);

    -- the person's notice: the date and the time in the day's own zone, no names
    insert into cma.message (tenant_id, kind, urgency, title, body, target, sender_user_id)
    values (v_tenant, 'announcement', 'normal', 'Workday closed automatically',
            format('Your workday of %s was closed automatically at %s because you did not log out. Your supervisor will review it.',
                   to_char(w.business_date, 'Dy DD Mon'), to_char(v_end at time zone w.timezone, 'HH24:MI')),
            jsonb_build_object('users', jsonb_build_array(w.user_id)), v_actor)
    returning id into v_msg;
    perform cma.deliver_message(v_msg, array[w.user_id]);

    v_n     := v_n + 1;
    v_first := least(v_first, w.business_date);
    v_last  := greatest(v_last, w.business_date);
    workday_id := w.id; user_id := w.user_id; business_date := w.business_date; ended_at := v_end; end_rule := v_rule;
    return next;
  end loop;

  -- management's digest: one per run, counts and dates only
  if v_n > 0 then
    v_perm := cma.setting_of(v_tenant, 'workday.auto_close_notify_permission');
    select coalesce(array_agg(u.id order by u.id), '{}') into v_users
    from cma.app_user u
    where u.tenant_id = v_tenant and u.status = 'active' and u.kind = 'person'
      and cma.has_permission(u.id, v_perm);
    insert into cma.message (tenant_id, kind, urgency, title, body, target, sender_user_id)
    values (v_tenant, 'announcement', 'normal', 'Workdays closed automatically',
            format('%s workday(s) of %s were closed automatically. Review them on Team hours.', v_n,
                   case when v_first = v_last then to_char(v_first, 'Dy DD Mon')
                        else to_char(v_first, 'Dy DD Mon') || ' to ' || to_char(v_last, 'Dy DD Mon') end),
            jsonb_build_object('permission', v_perm), v_actor)
    returning id into v_msg;
    perform cma.deliver_message(v_msg, v_users);
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Grants: the application only (a create or replace keeps a function's grants; said again for the one re-created)
-- ---------------------------------------------------------------------------------------------
revoke execute on function cma.office_hours_end_in(text, integer[], time[], date[], date),
  cma.close_forgotten_workdays(integer) from public;
grant execute on function cma.office_hours_end_in(text, integer[], time[], date[], date),
  cma.close_forgotten_workdays(integer) to cma_app;

insert into cma.schema_migration (version, description)
values ('0009zv', 'Forgotten workdays without a published shift closed at the end of the office hours of the person''s Default market that day (setting workday.auto_close_office_hours, default false), before workday.auto_close_at; never after the window end, never before the last event; end_rule office_hours')
on conflict (version) do nothing;

commit;
reset role;
