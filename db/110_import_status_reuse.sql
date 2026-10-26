-- =============================================================================================
-- 110_import_status_reuse.sql: addition 0008zh, a later legacy import batch reuses the tenant's import status
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 108_legacy_call_outcome.sql (0008zg). Rerunnable, forward-only, in one transaction. Run as your own IAM
-- login, dev first, then prod; then 111_verify_import_status_reuse.sql, then 51_verify_legacy_time_import.sql again
-- (unchanged, still PASS). Nothing in the web reads what this changes; the import itself follows
-- docs/import/README.md (A weekly batch).
--
-- Why (Decision log, 26 October 2026; Martin): the load of 0008d refuses an inactive work status that holds
-- any effective event, and the first batch's own days are such events, so a second batch into the import status
-- (the status is retired after the first load) fails with CMA04. The week of 12 to 18 October 2026 was loaded
-- into a one-off status for that reason. One status per earlier system keeps reports on one label.
--
-- What it changes: cma.load_import_batch(), one rule, the work status guard. An inactive work status is refused
-- only when it holds effective time on a workday that no import batch wrote. The days of a loaded batch (a row in
-- cma.import_day of a batch that is not voided) do not block, and neither do the corrections made to them since:
-- cma.correct_workday() and cma.correct_time_event() write their events on the same workday with source
-- 'correction' and no batch, so the rule keys on the workday, not on import_batch_id. Time a live clock-in wrote,
-- or time in the status on a day an agent or a supervisor added, still gives CMA04: live time never lands in a
-- hidden status. The rest of the function is the 0008d text unchanged (same signature, same counts, same grants).
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
set role cma_owner;

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0008zg') then
    raise exception 'addition 0008zg (108_legacy_call_outcome.sql) must run before 0008zh';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Load: the work status guard
-- ---------------------------------------------------------------------------------------------
-- Refuses a batch not staged (CMA03); an unknown work or gap status (CMA02); a work status that is
-- not working, is the default, or is inactive with time behind it (an effective event of the tenant
-- in it on a workday that no import batch wrote; an inactive status nothing was ever booked on loads,
-- as do a reload after a void, whose events are no longer effective, and a later batch into the status
-- an earlier one wrote: time on the days of a loaded batch, the corrections made to them since
-- included, does not block); a gap status that is working or paid; a map row outside the tenant; a
-- session in the spring gap of the batch's zone; a session outside the period; a batch without
-- sessions of a mapped account (all CMA04). Per mapped account and local login date: a session
-- without a logout ends at the close time (dropped when it starts at or after it), every session is
-- clipped to the window, overlapping or touching sessions are merged; then one day from the first
-- login to the last logout: start in the work status, a status change to the gap status at every
-- logout and back to the work status at the next login, the end at the last logout, all source
-- 'import', occurred_at the local time in the batch's zone, recorded_at now. A date that already has
-- a day with effective events is skipped; the day of a withdrawn import is used again. A day under
-- one minute is dropped. Then the work status is retired (nothing to do when it is inactive already)
-- and the batch is loaded with its counts.
create or replace function cma.load_import_batch(p_key text)
returns cma.import_batch
language plpgsql
as $$
declare
  v_tenant   uuid := cma.current_tenant_id();
  v_actor    uuid;
  b          cma.import_batch;
  v_work     cma.work_status;
  v_gap      cma.work_status;
  v_ws       time;
  v_we       time;
  v_oe       time;
  v_n        integer;
  v_txt      text;
  v_end      uuid;
  w          cma.workday;
  r          record;
  c_in       integer;
  c_unmapped integer;
  c_accounts integer;
  c_open     integer;
  c_outside  integer;
  c_merged   integer := 0;
  c_days     integer := 0;
  c_events   integer := 0;
  c_rule     integer := 0;
  c_clipped  integer := 0;
  c_dropped  integer := 0;
  c_existing integer := 0;
begin
  v_actor := cma.assert_permission('tenant.configure');

  select * into b from cma.import_batch x where x.tenant_id = v_tenant and x.key = p_key for update;
  if not found then
    raise exception 'import batch "%" not found in the current tenant', p_key using errcode = 'CMA02';
  end if;
  if b.status <> 'staged' then
    raise exception 'import batch "%" is %; only a staged batch loads', p_key, b.status using errcode = 'CMA03';
  end if;

  -- the two statuses
  select * into v_work from cma.work_status s where s.tenant_id = v_tenant and s.key = b.work_status_key for update;
  if not found then
    raise exception 'work status "%" does not exist in this tenant', b.work_status_key using errcode = 'CMA02';
  end if;
  if not v_work.is_working or v_work.is_default then
    raise exception 'the import''s work status must be a working status that is not the default' using errcode = 'CMA04';
  end if;
  -- time on a day an import wrote does not count, whoever wrote it: the day's own events, and the corrections
  -- made to it since (a correction is an event of source 'correction' on the same workday, not of the batch)
  if v_work.status <> 'active'
     and exists (select 1 from cma.time_event_effective e
                 where e.tenant_id = v_tenant and e.status_id = v_work.id
                   and not exists (select 1 from cma.import_day d
                                   join cma.import_batch ib on ib.tenant_id = d.tenant_id and ib.id = d.batch_id
                                   where d.tenant_id = v_tenant and d.workday_id = e.workday_id and ib.status <> 'voided')) then
    raise exception 'work status "%" is inactive and has time recorded in it on days no import wrote; the import writes a status created for it', v_work.key
      using errcode = 'CMA04';
  end if;
  select * into v_gap from cma.work_status s where s.tenant_id = v_tenant and s.key = b.gap_status_key;
  if not found then
    raise exception 'work status "%" does not exist in this tenant', b.gap_status_key using errcode = 'CMA02';
  end if;
  if v_gap.is_working or v_gap.is_paid then
    raise exception 'the gap status must be neither working nor paid' using errcode = 'CMA04';
  end if;

  -- the map stays within the tenant (the foreign key already holds it; checked again here)
  if exists (select 1 from cma.import_person_map m
             where m.tenant_id = v_tenant and m.batch_id = b.id
               and not exists (select 1 from cma.app_user u where u.tenant_id = v_tenant and u.id = m.user_id)) then
    raise exception 'a map row of batch "%" names a person outside this tenant', p_key using errcode = 'CMA04';
  end if;

  -- every session exists in the batch's zone and lies in the period
  select count(*), min(s.external_session_id) into v_n, v_txt
  from cma.import_session s
  where s.tenant_id = v_tenant and s.batch_id = b.id
    and ((s.login_local at time zone b.timezone) at time zone b.timezone <> s.login_local
         or (s.logout_local is not null and (s.logout_local at time zone b.timezone) at time zone b.timezone <> s.logout_local));
  if v_n > 0 then
    raise exception '% session(s) fall in the spring clock change gap of %, first session %', v_n, b.timezone, v_txt using errcode = 'CMA04';
  end if;
  select count(*), min(s.external_session_id) into v_n, v_txt
  from cma.import_session s
  where s.tenant_id = v_tenant and s.batch_id = b.id
    and s.login_local::date not between b.period_from and b.period_to;
  if v_n > 0 then
    raise exception '% session(s) start outside the period % to %, first session %', v_n, b.period_from, b.period_to, v_txt
      using errcode = 'CMA04';
  end if;

  -- the snapshots
  v_ws := cma.setting_of(v_tenant, 'workday.window_start')::time;
  v_we := cma.setting_of(v_tenant, 'workday.window_end')::time;
  v_oe := cma.setting_of(v_tenant, 'workday.auto_close_at')::time;

  -- what comes in and what is skipped
  select count(*),
         count(*) filter (where m.user_id is null),
         count(distinct s.external_person_id) filter (where m.user_id is null),
         count(*) filter (where m.user_id is not null and s.logout_local is null and s.login_local::time >= v_oe)
  into c_in, c_unmapped, c_accounts, c_open
  from cma.import_session s
  left join cma.import_person_map m
    on m.tenant_id = s.tenant_id and m.batch_id = s.batch_id and m.external_person_id = s.external_person_id
  where s.tenant_id = v_tenant and s.batch_id = b.id;
  if c_in = c_unmapped then
    raise exception 'import batch "%" has no session of a mapped account', p_key using errcode = 'CMA04';
  end if;

  select count(*) into c_outside
  from cma.import_session s
  join cma.import_person_map m
    on m.tenant_id = s.tenant_id and m.batch_id = s.batch_id and m.external_person_id = s.external_person_id
  where s.tenant_id = v_tenant and s.batch_id = b.id
    and (s.logout_local is not null or s.login_local::time < v_oe)
    and least(coalesce(s.logout_local, s.login_local::date + v_oe), s.login_local::date + v_we)
        <= greatest(s.login_local, s.login_local::date + v_ws);

  -- per person and local date: the merged stretches and the flags
  for r in
    with src as (
      select m.user_id, s.login_local::date as d,
             s.logout_local is null as was_open,
             s.login_local at time zone b.timezone as login_at,
             case when s.logout_local is not null then s.logout_local at time zone b.timezone
                  when s.login_local::time < v_oe then cma.business_day_time(s.login_local::date, b.timezone, v_oe)
             end as logout_at
      from cma.import_session s
      join cma.import_person_map m
        on m.tenant_id = s.tenant_id and m.batch_id = s.batch_id and m.external_person_id = s.external_person_id
      where s.tenant_id = v_tenant and s.batch_id = b.id
    ),
    bounded as (
      select x.user_id, x.d, x.was_open and x.logout_at is not null as by_rule,
             x.logout_at is not null
               and (x.login_at < cma.business_day_time(x.d, b.timezone, v_ws)
                    or x.logout_at > cma.business_day_time(x.d, b.timezone, v_we)) as clipped,
             greatest(x.login_at, cma.business_day_time(x.d, b.timezone, v_ws)) as f,
             case when x.logout_at is not null   -- least() ignores a null: a dropped session has no end
                  then least(x.logout_at, cma.business_day_time(x.d, b.timezone, v_we)) end as t
      from src x
    ),
    live as (
      select y.user_id, y.d, y.f, y.t,
             max(y.t) over (partition by y.user_id, y.d order by y.f, y.t rows between unbounded preceding and 1 preceding) as prev_t
      from bounded y
      where y.t > y.f
    ),
    islands as (
      select z.*, sum(case when z.prev_t is null or z.f > z.prev_t then 1 else 0 end)
                    over (partition by z.user_id, z.d order by z.f, z.t rows unbounded preceding) as grp
      from live z
    ),
    merged as (
      select i.user_id, i.d, i.grp, min(i.f) as f, max(i.t) as t, count(*)::integer as n
      from islands i
      group by i.user_id, i.d, i.grp
    ),
    days as (
      select g.user_id, g.d,
             array_agg(g.f order by g.f) as fs,
             array_agg(g.t order by g.f) as ts,
             sum(g.n)::integer as sessions,
             (sum(g.n) - count(*))::integer as merged,
             sum(floor(extract(epoch from (g.t - g.f))))::bigint as seconds
      from merged g
      group by g.user_id, g.d
    ),
    flags as (
      select y.user_id, y.d, bool_or(y.by_rule) as by_rule, bool_or(y.clipped) as clipped
      from bounded y
      group by y.user_id, y.d
    )
    select fl.user_id, fl.d, fl.by_rule, fl.clipped, dy.fs, dy.ts,
           coalesce(dy.sessions, 0) as sessions, coalesce(dy.merged, 0) as merged, coalesce(dy.seconds, 0) as seconds
    from flags fl
    left join days dy on dy.user_id = fl.user_id and dy.d = fl.d
    order by fl.d, fl.user_id
  loop
    if r.seconds < 60 then
      c_dropped := c_dropped + 1;
      continue;
    end if;

    -- the CMA's own days win; the day of a withdrawn import (no effective event left) is used again
    select * into w from cma.workday x
    where x.tenant_id = v_tenant and x.user_id = r.user_id and x.business_date = r.d
    for update;
    if found then
      if w.timezone <> b.timezone
         or exists (select 1 from cma.time_event_effective e where e.tenant_id = v_tenant and e.workday_id = w.id) then
        c_existing := c_existing + 1;
        continue;
      end if;
    else
      insert into cma.workday (tenant_id, user_id, business_date, timezone, status, started_at)
      values (v_tenant, r.user_id, r.d, b.timezone, 'open', r.fs[1])
      returning * into w;
    end if;

    insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, recorded_at, source, import_batch_id)
    values (v_tenant, w.id, r.user_id, 'start', v_work.id, r.fs[1], now(), 'import', b.id);
    for v_n in 2 .. cardinality(r.fs) loop
      insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, recorded_at, source, import_batch_id)
      values (v_tenant, w.id, r.user_id, 'status', v_gap.id, r.ts[v_n - 1], now(), 'import', b.id),
             (v_tenant, w.id, r.user_id, 'status', v_work.id, r.fs[v_n], now(), 'import', b.id);
    end loop;
    insert into cma.time_event (tenant_id, workday_id, user_id, kind, status_id, occurred_at, recorded_at, source, import_batch_id)
    values (v_tenant, w.id, r.user_id, 'end', null, r.ts[cardinality(r.ts)], now(), 'import', b.id)
    returning id into v_end;
    perform cma.refresh_workday(w.id);

    insert into cma.import_day (tenant_id, batch_id, workday_id, user_id, business_date, end_event_id, sessions,
                                sessions_merged, seconds, closed_by_rule, clipped)
    values (v_tenant, b.id, w.id, r.user_id, r.d, v_end, r.sessions, r.merged, r.seconds, r.by_rule, r.clipped);

    c_days    := c_days + 1;
    c_events  := c_events + 2 * cardinality(r.fs);
    c_merged  := c_merged + r.merged;
    c_rule    := c_rule + case when r.by_rule then 1 else 0 end;
    c_clipped := c_clipped + case when r.clipped then 1 else 0 end;
  end loop;

  -- nobody chooses the import's status afterwards (a no-op for a status seeded inactive)
  perform cma.retire_work_status(v_work.key);

  update cma.import_batch x
  set status = 'loaded', window_start = v_ws, window_end = v_we, open_session_end = v_oe,
      loaded_by = v_actor, loaded_at = now(),
      counts = jsonb_build_object(
        'sessions_in', c_in, 'sessions_unmapped', c_unmapped, 'accounts_skipped', c_accounts,
        'sessions_open_dropped', c_open, 'sessions_outside_window', c_outside, 'sessions_merged', c_merged,
        'days_written', c_days, 'events_written', c_events, 'days_closed_by_rule', c_rule,
        'days_clipped', c_clipped, 'days_dropped', c_dropped, 'days_skipped_existing', c_existing)
  where x.tenant_id = v_tenant and x.id = b.id
  returning * into b;
  return b;
end
$$;

do $$
begin
  execute 'revoke execute on function cma.load_import_batch(text) from public';
  execute 'grant execute on function cma.load_import_batch(text) to cma_app';
end
$$;

insert into cma.schema_migration (version, description)
values ('0008zh', 'Legacy import status reuse: cma.load_import_batch refuses an inactive work status only when it holds effective time on a workday no import batch wrote; the days of a loaded batch, with the corrections made to them since, do not block, so a later batch loads into the tenant''s import status')
on conflict (version) do nothing;

commit;
reset role;
