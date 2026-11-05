-- =============================================================================================
-- verify/hours-volume-fixture.sql: workdays and time events at volume, for timing the hours reads (N06d,
-- 6 November 2026): Team hours, My hours, the Welcome counts, the day editor. Local only, on the pattern of
-- verify/perf-volume-fixture.sql: refuses any database where cloudsqladmin exists and any without the dev seed;
-- invented days only; rerunnable (a second run finds its first day and stops).
--
--   psql -h 127.0.0.1 -d cma -v ON_ERROR_STOP=1 -c "set cma.local_fixture = 'on'" -c "set cma.perf_multiplier = '3'" -f verify/hours-volume-fixture.sql
--
-- What it writes, for every active person of pulse4all-subscriptions (the dev seed's 8): one ended workday per
-- business day (Monday to Friday) for the last 84 × m business days, each with 12 effective events (a start, ten
-- status changes through the tenant's active statuses, an end) and, every twentieth day, a correction that
-- supersedes the day's end (so the effective view's anti-join has rows to exclude). At m = 3: 8 people × 252 days
-- × 12 events = about 24,000 events and 2,000 workdays; N06d's records were taken at m = 6 (about 30,000 events, 2,500
-- workdays). Prod (census of 5 November 2026) holds under 10,000 time events, so either is at least three times prod's
-- volume as the brief asks. Times in the tenant's zone, source
-- 'user', recorded when they occurred; the audit trigger is off while loading, as the perf fixture does.
set role cma_owner;
do $$
begin
  if coalesce(current_setting('cma.local_fixture', true), '') <> 'on' then
    raise exception 'local fixture only: run  set cma.local_fixture = ''on''  in this session first';
  end if;
  if exists (select 1 from pg_roles where rolname = 'cloudsqladmin') then
    raise exception 'this is a Cloud SQL instance (the role cloudsqladmin exists): the volume fixture is for a local database only';
  end if;
  if not exists (select 1 from cma.app_user where email = 'agent.two@example.com') then
    raise exception 'the dev seed is missing: this fixture needs db/03 and db/06';
  end if;
end
$$;

do $$
declare
  m numeric := coalesce(nullif(current_setting('cma.perf_multiplier', true), ''), '3')::numeric;
  v_subs uuid; v_manager uuid; v_first date; v_zone text := 'Europe/Amsterdam';
  v_statuses uuid[]; v_breaks uuid[];
  u record; d date; w uuid; e uuid; i integer; at timestamptz; st uuid;
  n_days integer := 0; n_events integer := 0;
  t0 timestamptz := clock_timestamp();
begin
  select id into v_subs from cma.tenant where slug = 'pulse4all-subscriptions';
  select id into v_manager from cma.app_user where tenant_id = v_subs and email = 'manager@example.com';
  v_first := current_date - (84 * m)::integer;
  if exists (select 1 from cma.workday x where x.tenant_id = v_subs and x.business_date = v_first and x.timezone = v_zone
             and x.started_at = (v_first::text || ' 08:30')::timestamp at time zone v_zone) then
    raise notice 'hours volume fixture already written (a workday of % exists): nothing to do', v_first;
    return;
  end if;
  select array_agg(id order by sort_order) into v_statuses from cma.work_status where tenant_id = v_subs and status = 'active' and is_working;
  select array_agg(id order by sort_order) into v_breaks from cma.work_status where tenant_id = v_subs and status = 'active' and not is_working;
  alter table cma.workday disable trigger audit;
  alter table cma.time_event disable trigger audit;
  for u in select id from cma.app_user where tenant_id = v_subs and kind = 'person' and status = 'active' order by created_at loop
    d := v_first;
    while d < current_date loop
      if extract(isodow from d) <= 5 and not exists (select 1 from cma.workday x where x.tenant_id = v_subs and x.user_id = u.id and x.business_date = d) then
        w := uuidv7();
        at := (d::text || ' 08:30')::timestamp at time zone v_zone + (n_days % 7) * interval '3 minutes';
        insert into cma.workday (id, tenant_id, user_id, business_date, timezone, status, started_at, ended_at)
        values (w, v_subs, u.id, d, v_zone, 'ended', at, at + interval '8 hours 30 minutes');
        insert into cma.time_event (id, tenant_id, workday_id, user_id, kind, status_id, occurred_at, recorded_at, source)
        values (uuidv7(), v_subs, w, u.id, 'start', v_statuses[1], at, at, 'user');
        for i in 1..10 loop
          at := at + interval '46 minutes';
          st := case when i in (3, 7) then v_breaks[1 + (i % array_length(v_breaks, 1))] else v_statuses[1 + (i % array_length(v_statuses, 1))] end;
          insert into cma.time_event (id, tenant_id, workday_id, user_id, kind, status_id, occurred_at, recorded_at, source)
          values (uuidv7(), v_subs, w, u.id, 'status', st, at, at, 'user');
        end loop;
        e := uuidv7();
        at := at + interval '50 minutes';
        insert into cma.time_event (id, tenant_id, workday_id, user_id, kind, occurred_at, recorded_at, source)
        values (e, v_subs, w, u.id, 'end', at, at, 'user');
        n_events := n_events + 12;
        if n_days % 20 = 0 then
          -- a correction that moves the end a quarter of an hour later: the original end is no longer effective
          insert into cma.time_event (id, tenant_id, workday_id, user_id, kind, occurred_at, recorded_at, source, supersedes_event_id, reason, approved_by)
          values (uuidv7(), v_subs, w, u.id, 'end', at + interval '15 minutes', at + interval '1 day', 'correction', e, 'forgot to clock out', v_manager);
          update cma.workday set ended_at = at + interval '15 minutes' where id = w;
          n_events := n_events + 1;
        end if;
        n_days := n_days + 1;
      end if;
      d := d + 1;
    end loop;
  end loop;
  alter table cma.workday enable trigger audit;
  alter table cma.time_event enable trigger audit;
  raise notice 'hours volume fixture written in % s: % workdays, % events', round(extract(epoch from clock_timestamp() - t0)), n_days, n_events;
end
$$;
reset role;
