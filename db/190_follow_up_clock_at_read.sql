-- =============================================================================================
-- 190_follow_up_clock_at_read.sql: addition 0009u, the follow-up's clock fields derived at read, not stored; the three
-- fields no longer make the refresh write an item every minute (option B; Martin, 16 November 2026)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics: markets, office hours, holidays, response times and targets stay each
-- tenant's catalogs and settings. Runs unchanged in every database, after 188_fleet_management.sql (0009t). Rerunnable,
-- forward-only, in one transaction with a lock timeout. Run as your own IAM login: dev first, then
-- 191_verify_follow_up_clock_at_read.sql there (normal, then provoked), then the verifies that read what this re-creates
-- (reruns): 73_verify_follow_up.sql (unchanged), 81_verify_follow_up_snapshot.sql (edited by this change: B3),
-- 151_verify_courtesy.sql and 155_verify_courtesy_bases.sql (unchanged), 179_verify_job_reads.sql (edited by this change:
-- its copy of 154's refresh stores the row as 0009u does, so E8 still compares like with like); then 131_time_all.sql part
-- a. Prod the same, in or outside office hours, BEFORE the merge of this addition's PR: its web reads Welcome's Waiting
-- for you from cma.my_follow_up_counts(), which this script adds (on a database without it Welcome's block would fail).
-- Every other read keeps its shape: main's web (bab9720) and its refresh job run unchanged on a database with 190, so
-- the database goes first. The job calls cma.refresh_follow_up() and reads the same answer keys; the page, its API, an
-- agent's own follow-up and the report lists read the same keys, now derived at the read. Checked locally for the PR
-- (main's web built and run against local copies of the volume fixture before and after 190: verify:api 358 of 358 on
-- both, every function's signature and result type the same); Martin's verify:api against dev after 190 confirms it.
--
-- Why (Martin, 16 November 2026; Decision log, 16 Nov 2026): tools/perf/follow-up-diff.sql in prod, Monday 16 November
-- 11:06 UTC, office hours: of 4,723 items 1,017 changed every minute (912 tickets, 105 leads, no task), 2,034 rows written a
-- minute, and every change a clock field only: tickets' open_business_seconds and minutes_to_breach, leads'
-- waiting_business_seconds. No sort_key, market, owner or state changed, no other key, no representation artefact. 0009o
-- (178, #274) made the refresh write only the items whose fingerprint changed; in office hours these three fields still
-- changed the fingerprint of every open ticket and lead of a market in its hours, every minute. Option B, chosen by Martin
-- over option A on this evidence: the fields are not stored at all and every read derives them.
--
-- The stable inputs (chosen from how 178 computes the three fields; already in the stored row, so nothing is added):
--   ticket   open_business_seconds = cma.business_seconds_in(the market's calendar, created_at, now()), null without a
--            calendar (market unknown or without a zone); minutes_to_breach = sla_minutes - floor(open_business_seconds /
--            60), null with it. Inputs: created_at (the instant the open time starts), market, sla_minutes (the target,
--            the pipeline's own or tickets.sla_minutes as the refresh resolved it)
--   lead     waiting_business_seconds = cma.business_seconds_in(the market's calendar, created_at, now()) (an open lead is
--            one not called and not closed, so the wait runs from its creation to now). Inputs: created_at, market
--   The row's market key (as the live functions wrote it), not the item's market column, finds the calendar, as 178 does.
-- A breach instant was considered and left: minutes_to_breach counts office minutes, so it needs the calendar at read
-- anyway, and an instant would have to reproduce 178's rounding of seconds exactly.
--
-- What it adds
--   cma.follow_up_clock_row(kind, row, seconds, warn_pct, target_s)   the row with its clock fields from its office
--            seconds since created_at (the caller's cma.business_seconds_in at now(), on the market's calendar row): a
--            ticket's open_business_seconds, minutes_to_breach and sla_state, a lead's waiting_business_seconds and
--            past_target, as cma.open_tickets_of and cma.open_leads_of (178) compute them; a task's row unchanged. One
--            expression, inlined into its caller's query; sql, stable (jsonb_build_object is stable, and an immutable
--            function over a stable call is never inlined: 136)
--   cma.my_follow_up_counts()   the caller's own leads, tickets and tasks counted, and computed_at: Welcome's Waiting for
--            you, which shows three counts, reads these instead of cma.my_follow_up's every row (65 to 78 ms against its
--            50 ms at three times prod's volume with the rows derived; the same permissions, acting user and fallback).
--            plpgsql, rows 1. The web of this addition's PR calls it, so 190 runs before that PR's merge
-- What it changes (each answer as before at the same instant, but where said)
--   cma.refresh_follow_up_of (based on 178)   stores a lead's and a ticket's row without the three fields, so neither the
--            row nor the fingerprint (cma.follow_up_item_print over the stored row, unchanged) moves with the clock alone.
--            The same items, sort_key, market, owner, state and snapshot as before; the first refresh after this rewrites
--            every lead and ticket once (their stored row loses three keys)
--   cma.follow_up_list_of (based on 80)   each row returned carries the three fields and its state words (a ticket's
--            sla_state, a lead's past_target) derived at now(): the calendar, tickets.sla_warning_pct and
--            speed_to_lead.target_minutes read once per list, never per row; the task list reads none of them (its path
--            as before). Its callers cma.follow_up_page (Reports → Follow-up and its API) and cma.my_follow_up (an agent's
--            own follow-up on /me/follow-up and its API; Welcome reads cma.my_follow_up_counts() since this addition) are
--            not re-created
--   cma.open_leads(), cma.open_tickets() (based on 80)   the same, every row (the report lists' API)
-- Not changed: the item's state column, the list filters that read it, the snapshot's counts and figures per person
-- (cma.follow_up_summary(): Welcome's Needs attention, "tickets at risk or over their response time" and "leads past the
-- target without a call", and the Live board's Follow-up now; cma.follow_up_by_owner()). They read the states the refresh
-- stores, as the minute before, and none of the three fields. What the clock alone still makes the refresh write: a
-- state that turns (a ticket's ok, at_risk, breached: at most twice in its life; a lead's within_target, past_target:
-- once); a lead's day counts (age_business_days, its bucket, last_call_days) at its market's midnight, once a day; and
-- sort_key (kept as it is: the order by time left and by waiting), whose places can cross while one market is open and
-- another closed, rewriting the items between. A returned row's own state words are derived with its fields, so a row
-- never says "at risk" next to "1 min over"; the attention filter, the order and the counts follow at the next refresh,
-- normally within a minute.
-- cma.open_tasks(), cma.open_leads_of, cma.open_tickets_of, cma.open_tasks_of, cma.follow_up_next_change_of (it reads the
-- stored last_call_at only) and cma.follow_up_item_print stay as they are.
--
-- Audit (CMA-112): cma.follow_up_item, cma.follow_up_snapshot and cma.follow_up_marker carry no audit trigger (80, 178),
-- so the item writes never reached cma.audit_log; the job's sync_run row (audited) is written as before. This change
-- removes the item writes themselves (table and WAL churn, autovacuum, the refresh's write time), not audit rows: the
-- audit log's growth is unchanged by it. 191 proves a refresh adds no audit row for the follow-up's tables.
--
-- Speed at three times prod's volume (web/verify/perf-volume-fixture.sql, local, the subscriptions tenant, 131 part a, best
-- of two, before → after; two runs after, the machine's spread about 10 ms): Reports → Follow-up with callbacks 426.3 →
-- 439.6 and 444.9 ms (budget 500); the report lists, every row, leads 137.1 → 86.6 and 80.3 ms, tickets 341.1 → 216.9 and
-- 190.1 ms (the stored row is smaller; budget 500, rows new in 131); Welcome's Waiting for you (cma.my_follow_up(), every
-- row the agent owns: 136 leads, 400 tickets, 834 tasks) 47.4 → 64.6 and 77.7 ms against 50 ms with every row's fields
-- derived; the block shows three counts, so it reads cma.my_follow_up_counts() instead: 3.4 ms (the agent page's set
-- 59.8 → 17.0 ms against 100; its seventh call in a session 2.5 ms). /me/follow-up keeps every row: 131's 'my
-- follow-up: my rows' 64.9 ms against 50, a miss this addition causes (47.4 before it), open for Martin. The seventh
-- call of a session as the first (N06): my_follow_up 70 to 82 ms, the page's follow-up part 56 to 66, open_tickets()
-- 140 to 180, open_leads() 54 to 82. The derivation is inlined into each read (a wrapper with a subquery, run per row as
-- a plan of its own, took the tickets list to 44 s), each row's office seconds computed once (offset 0), the task list's
-- path as before.
-- The refresh with only the clock moved (tools/perf/follow-up-diff.sql locally, 21 seconds in office hours): 9,764 rows as
-- 178 stored the row, 2 now (one ticket's state turned).
-- No index is added; no lock on a busy table (functions only).
--
-- SQLSTATEs as before.
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
  if not exists (select 1 from cma.schema_migration where version = '0009t') then
    raise exception 'addition 0009t (188_fleet_management.sql) must run before 0009u';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The clock fields of a stored row at an instant
-- ---------------------------------------------------------------------------------------------
-- A stored item's row with its clock fields, from its office seconds since created_at at the instant (the caller's
-- cma.business_seconds_in on the market's calendar row, null for no calendar) and the two settings the caller read once: a
-- ticket gains open_business_seconds, minutes_to_breach and sla_state as cma.open_tickets_of computes them (p_warn_pct as
-- it bounds tickets.sla_warning_pct), a lead waiting_business_seconds and past_target as cma.open_leads_of (p_target_s:
-- speed_to_lead.target_minutes in seconds); a task's row comes back as it is. One expression, no table and no FROM, so
-- the planner inlines it into the caller's query (a function with a subquery is run as a plan of its own per row: 2.6 s
-- for 3,600 tickets at three times prod's volume, against 0.1 s inlined) (0009u)
create or replace function cma.follow_up_clock_row(p_kind text, p_row jsonb, p_seconds integer, p_warn_pct integer, p_target_s integer)
returns jsonb
language sql stable
as $$
  select case p_kind
           when 'ticket' then p_row || jsonb_build_object(
             'open_business_seconds', p_seconds,
             'minutes_to_breach', case when p_seconds is null then null else (p_row ->> 'sla_minutes')::integer - floor(p_seconds / 60.0)::integer end,
             'sla_state', case when p_seconds is null then 'no_hours'
                               when p_seconds >= (p_row ->> 'sla_minutes')::integer * 60 then 'breached'
                               when p_seconds * 100 >= (p_row ->> 'sla_minutes')::integer * 60 * p_warn_pct then 'at_risk'
                               else 'ok' end)
           when 'lead' then p_row || jsonb_build_object(
             'waiting_business_seconds', p_seconds,
             'past_target', case when p_seconds > p_target_s then true when p_seconds is null then null else false end)
           else p_row end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. The refresh: the row without its clock fields
-- ---------------------------------------------------------------------------------------------
-- As 0009o's (178): the same items, snapshot, marker and answer; a lead's row without waiting_business_seconds, a ticket's
-- without open_business_seconds and minutes_to_breach (the readers derive them), so an item is written only when
-- something other than the clock changed it
-- based on: 178_job_reads.sql
create or replace function cma.refresh_follow_up_of(p_tenant_id uuid, p_wait boolean default false)
returns jsonb
language plpgsql
as $$
declare
  v_t0      timestamptz := clock_timestamp();
  v_leads   integer;
  v_tickets integer;
  v_tasks   integer;
  v_ms      integer;
  v_summary jsonb;
  v_owners  jsonb;
  v_courtesy integer;
  v_new     cma.follow_up_item[];
  v_old     jsonb;
  v_newmap  jsonb;
  v_deleted integer;
  v_written integer;
begin
  if p_tenant_id is null or p_tenant_id is distinct from cma.current_tenant_id() then
    raise exception 'the follow-up snapshot is refreshed for the current tenant only' using errcode = 'CMA06';
  end if;
  if coalesce(p_wait, false) then
    perform pg_advisory_xact_lock(cma.follow_up_lock_key(p_tenant_id));
    if exists (select 1 from cma.follow_up_snapshot s where s.tenant_id = p_tenant_id) then
      return jsonb_build_object('refreshed', false, 'reason', 'present');
    end if;
  elsif not pg_try_advisory_xact_lock(cma.follow_up_lock_key(p_tenant_id)) then
    return jsonb_build_object('refreshed', false, 'reason', 'running');
  end if;

  -- 0009o: the items computed as before (the same rows, the same order), then only what changed written: an item whose
  -- kind, id, place, market, owner, state and row are all unchanged stays as it is; one that changed or went is deleted,
  -- one that changed or is new is inserted. Each side's fingerprints (md5 of the item's place and content) are one map by
  -- the item's kind and id, computed once per item, and the two maps are compared: two passes, never a read per item.
  -- 0009u: a lead's and a ticket's row are stored without the fields that move with the clock alone (the readers derive
  -- them from created_at, market and sla_minutes, cma.follow_up_clock_row), so the fingerprint no longer moves with them
  v_new := array(
    select row(p_tenant_id, 'lead', o.ordinality, o.deal_id, coalesce(nullif(o.market, ''), 'unknown'), o.owner_user_id,
               case when o.past_target then 'past_target' when o.past_target is false then 'within_target' else 'no_hours' end,
               to_jsonb(o) - 'tenant_id' - 'ordinality' - 'waiting_business_seconds')::cma.follow_up_item
    from cma.open_leads_of(p_tenant_id) with ordinality o
    union all
    select row(p_tenant_id, 'ticket', o.ordinality, o.ticket_id, coalesce(nullif(o.market, ''), 'unknown'), o.owner_user_id, o.sla_state,
               to_jsonb(o) - 'tenant_id' - 'ordinality' - 'open_business_seconds' - 'minutes_to_breach')::cma.follow_up_item
    from cma.open_tickets_of(p_tenant_id) with ordinality o
    union all
    select row(p_tenant_id, 'task', o.ordinality, o.task_id, coalesce(nullif(o.market, ''), 'unknown'), o.owner_user_id, o.due_state,
               to_jsonb(o) - 'tenant_id' - 'ordinality')::cma.follow_up_item
    from cma.open_tasks_of(p_tenant_id) with ordinality o);
  select count(*) filter (where n.kind = 'lead'), count(*) filter (where n.kind = 'ticket'), count(*) filter (where n.kind = 'task'),
         coalesce(jsonb_object_agg(n.kind || ':' || n.item_id, cma.follow_up_item_print(n.sort_key, n.market, n.owner_user_id, n.state, n.row)), '{}'::jsonb)
    into v_leads, v_tickets, v_tasks, v_newmap
  from unnest(v_new) n;
  select coalesce(jsonb_object_agg(i.kind || ':' || i.item_id, cma.follow_up_item_print(i.sort_key, i.market, i.owner_user_id, i.state, i.row)), '{}'::jsonb)
    into v_old
  from cma.follow_up_item i where i.tenant_id = p_tenant_id;
  delete from cma.follow_up_item i
  where i.tenant_id = p_tenant_id
    and (v_newmap ->> (i.kind || ':' || i.item_id)) is distinct from (v_old ->> (i.kind || ':' || i.item_id));
  get diagnostics v_deleted = row_count;
  insert into cma.follow_up_item (tenant_id, kind, sort_key, item_id, market, owner_user_id, state, row)
  select n.tenant_id, n.kind, n.sort_key, n.item_id, n.market, n.owner_user_id, n.state, n.row
  from unnest(v_new) n
  where (v_old ->> (n.kind || ':' || n.item_id)) is distinct from (v_newmap ->> (n.kind || ':' || n.item_id));
  get diagnostics v_written = row_count;

  -- The counts and the figures per person from the items just written, as follow_up_summary_of and
  -- follow_up_by_owner_of compute them from the live sets (a person with only later tasks has a row of zeros)
  select jsonb_build_object(
           'leads_open_not_called', count(*) filter (where i.kind = 'lead'),
           'leads_past_target', count(*) filter (where i.kind = 'lead' and i.state = 'past_target'),
           'tickets_at_risk', count(*) filter (where i.kind = 'ticket' and i.state = 'at_risk'),
           'tickets_breached', count(*) filter (where i.kind = 'ticket' and i.state = 'breached'),
           'tickets_without_owner', count(*) filter (where i.kind = 'ticket' and i.row ->> 'owner_ref' is null),
           'tasks_overdue', count(*) filter (where i.kind = 'task' and i.state = 'overdue'),
           'tasks_due_today', count(*) filter (where i.kind = 'task' and i.state = 'today'),
           'tasks_unmapped_owner', count(*) filter (where i.kind = 'task' and i.row ->> 'owner_ref' is not null and i.owner_user_id is null))
    into v_summary
  from cma.follow_up_item i where i.tenant_id = p_tenant_id;
  -- the courtesy flag (0009a, renamed in 0009c): the courtesy orders Unreachable now and the attempts since due that flag one, both null while
  -- courtesy.start_date is unset, so Welcome's Needs attention reads them with the summary
  v_courtesy := cma.courtesy_unreachable_of(p_tenant_id, now());
  v_summary := v_summary || jsonb_build_object(
    'courtesy_unreachable', v_courtesy,
    'courtesy_alert_attempts', case when v_courtesy is not null then cma.setting_of(p_tenant_id, 'courtesy.alert_attempts')::integer end);
  select coalesce(jsonb_agg(jsonb_build_object(
           'owner_user_id', g.uid, 'open_leads', g.leads, 'leads_past_target', g.past, 'open_tickets', g.tickets,
           'tickets_at_risk_or_breached', g.risk, 'tasks_overdue', g.overdue, 'tasks_due_today', g.today) order by g.uid nulls last), '[]'::jsonb)
    into v_owners
  from (select i.owner_user_id as uid,
               count(*) filter (where i.kind = 'lead') as leads,
               count(*) filter (where i.kind = 'lead' and i.state = 'past_target') as past,
               count(*) filter (where i.kind = 'ticket') as tickets,
               count(*) filter (where i.kind = 'ticket' and i.state in ('at_risk', 'breached')) as risk,
               count(*) filter (where i.kind = 'task' and i.state = 'overdue') as overdue,
               count(*) filter (where i.kind = 'task' and i.state = 'today') as today
        from cma.follow_up_item i where i.tenant_id = p_tenant_id
        group by i.owner_user_id) g;

  v_ms := floor(extract(epoch from clock_timestamp() - v_t0) * 1000)::integer;
  insert into cma.follow_up_snapshot (tenant_id, computed_at, duration_ms, summary, by_owner)
  values (p_tenant_id, now(), v_ms, v_summary, v_owners)
  on conflict (tenant_id) do update
    set computed_at = excluded.computed_at, duration_ms = excluded.duration_ms, summary = excluded.summary, by_owner = excluded.by_owner;
  -- 0009o: what the job's next run checks before computing again: the inputs read up to this computation's start, and the
  -- first instant a figure moves with the clock alone (cma.follow_up_next_change_of)
  insert into cma.follow_up_marker (tenant_id, computed_at, inputs_checked_at, next_change_at, migrations)
  values (p_tenant_id, now(), v_t0, cma.follow_up_next_change_of(p_tenant_id, now()), (select count(*)::integer from cma.schema_migration))
  on conflict (tenant_id) do update
    set computed_at = excluded.computed_at, inputs_checked_at = excluded.inputs_checked_at, next_change_at = excluded.next_change_at,
        migrations = excluded.migrations;
  return jsonb_build_object('refreshed', true, 'computed', true, 'leads', v_leads, 'tickets', v_tickets, 'tasks', v_tasks,
                            'rows', v_leads + v_tickets + v_tasks, 'written', v_deleted + v_written,
                            'unchanged', v_leads + v_tickets + v_tasks - v_written, 'duration_ms', v_ms, 'computed_at', now());
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. The reads: the clock fields derived at now()
-- ---------------------------------------------------------------------------------------------
-- As 0008s's (80): the same total and rows in the same order, each lead and ticket row with its clock fields and state
-- words at now() (cma.follow_up_clock_row); the calendar and the two settings read once per list, never per row, and not
-- at all for the task list
-- based on: 80_follow_up_snapshot.sql
create or replace function cma.follow_up_list_of(p_tenant_id uuid, p_kind text, p_market text, p_owner uuid, p_unowned boolean,
                                                 p_attention boolean, p_rows integer)
returns jsonb
language sql stable
as $$
  with f as (
    select i.sort_key, i.owner_user_id, i.row
    from cma.follow_up_item i
    where i.tenant_id = p_tenant_id and i.kind = p_kind
      and (p_market is null or i.market = p_market)
      and (p_owner is null or i.owner_user_id = p_owner)
      and (not coalesce(p_unowned, false) or i.owner_user_id is null)
      and (not coalesce(p_attention, false) or cma.follow_up_attention(i.state))
  ),
  shown as (
    select f.sort_key, f.owner_user_id, f.row from f order by f.sort_key limit p_rows
  ),
  -- 0009u: each market's zone, office hours and holidays, once per list (a lead's or a ticket's; none for tasks)
  cal as materialized (
    select * from cma.business_calendar_of(p_tenant_id) where p_kind in ('lead', 'ticket')
  ),
  -- 0009u: the two settings once per list, each only for the kind that reads it
  st as materialized (
    select case when p_kind = 'ticket' then least(100, greatest(0, cma.setting_of(p_tenant_id, 'tickets.sla_warning_pct')::integer)) end as warn_pct,
           case when p_kind = 'lead' then cma.setting_of(p_tenant_id, 'speed_to_lead.target_minutes')::integer * 60 end as target_s
  ),
  -- 0009u: a lead's or a ticket's shown rows with their clock fields, each row's office seconds once (offset 0: pulled up,
  -- the call ran once per reference); a task's rows as stored, its path as before (no calendar, setting or call per row)
  d as (
    select s.sort_key, s.owner_user_id, cma.follow_up_clock_row(p_kind, s.row, bs.s, (select st.warn_pct from st), (select st.target_s from st)) as row
    from shown s
    left join cal bc on bc.market = nullif(s.row ->> 'market', 'unknown')
    left join lateral (select cma.business_seconds_in(bc.time_zone, bc.weekdays, bc.opens, bc.closes, bc.holidays,
                                                      (s.row ->> 'created_at')::timestamptz, now()) as s offset 0) bs on true
    where p_kind in ('lead', 'ticket')
    union all
    select s.sort_key, s.owner_user_id, s.row from shown s where p_kind not in ('lead', 'ticket')
  )
  select jsonb_build_object(
    'total', (select count(*) from f),
    'rows', coalesce((
      select jsonb_agg(d.row || jsonb_build_object(
               'owner_name', u.display_name,
               'record_url', cma.record_url((d.row ->> 'connection_id')::uuid,
                                            case p_kind when 'lead' then 'deal' else p_kind end,
                                            d.row ->> case p_kind when 'lead' then 'deal_source_id' when 'ticket' then 'ticket_source_id' else 'task_source_id' end))
             order by d.sort_key)
      from d
      left join cma.app_user u on u.tenant_id = p_tenant_id and u.id = d.owner_user_id), '[]'::jsonb))
$$;

-- As 0008s's (80): the same permission and rows in the same order, each with its clock fields at now()
-- based on: 80_follow_up_snapshot.sql
create or replace function cma.open_leads()
returns setof cma.open_lead_row
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_target integer;
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team', 'monitoring.live']);
  perform cma.follow_up_snapshot_of(v_tenant);
  -- 0009u: the setting and the calendar once per call
  v_target := cma.setting_of(v_tenant, 'speed_to_lead.target_minutes')::integer * 60;
  return query
    with cal as materialized (select * from cma.business_calendar_of(v_tenant))
    -- a call in from, once per row (a (record).* in the select list would run it once per column)
    select p.*
    from cma.follow_up_item i
    left join cal bc on bc.market = nullif(i.row ->> 'market', 'unknown')
    left join lateral (select cma.business_seconds_in(bc.time_zone, bc.weekdays, bc.opens, bc.closes, bc.holidays,
                                                      (i.row ->> 'created_at')::timestamptz, now()) as s offset 0) bs on true
    cross join lateral jsonb_populate_record(null::cma.open_lead_row,
      cma.follow_up_clock_row('lead', i.row, bs.s, null, v_target) || jsonb_build_object('tenant_id', i.tenant_id)) p
    where i.tenant_id = v_tenant and i.kind = 'lead' order by i.sort_key;
end
$$;

-- based on: 80_follow_up_snapshot.sql
create or replace function cma.open_tickets()
returns setof cma.open_ticket_row
language plpgsql
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_warn   integer;
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team', 'monitoring.live']);
  perform cma.follow_up_snapshot_of(v_tenant);
  -- 0009u: the setting and the calendar once per call
  v_warn := least(100, greatest(0, cma.setting_of(v_tenant, 'tickets.sla_warning_pct')::integer));
  return query
    with cal as materialized (select * from cma.business_calendar_of(v_tenant))
    -- a call in from, once per row (a (record).* in the select list would run it once per column)
    select p.*
    from cma.follow_up_item i
    left join cal bc on bc.market = nullif(i.row ->> 'market', 'unknown')
    left join lateral (select cma.business_seconds_in(bc.time_zone, bc.weekdays, bc.opens, bc.closes, bc.holidays,
                                                      (i.row ->> 'created_at')::timestamptz, now()) as s offset 0) bs on true
    cross join lateral jsonb_populate_record(null::cma.open_ticket_row,
      cma.follow_up_clock_row('ticket', i.row, bs.s, v_warn, null) || jsonb_build_object('tenant_id', i.tenant_id)) p
    where i.tenant_id = v_tenant and i.kind = 'ticket' order by i.sort_key;
end
$$;

-- The caller's own items counted per kind, plus when they were computed: what Welcome's Waiting for you shows (the
-- lengths of cma.my_follow_up's three lists), without reading or deriving a row. The same permissions, the same acting
-- user (CMA01 without one) and the same fallback (a tenant without a snapshot computes it once) as cma.my_follow_up;
-- each count one range of follow_up_item_owner_idx (tenant, kind, owner) (0009u)
create or replace function cma.my_follow_up_counts()
returns table (leads integer, tickets integer, tasks integer, computed_at timestamptz)
language plpgsql
rows 1
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_user   uuid := cma.current_user_id();
  s        cma.follow_up_snapshot;
begin
  perform cma.assert_any_permission(array['leads.accept', 'workday.own']);
  if v_user is null then
    raise exception 'no acting user' using errcode = 'CMA01';
  end if;
  s := cma.follow_up_snapshot_of(v_tenant);
  return query
    select (select count(*)::integer from cma.follow_up_item i where i.tenant_id = v_tenant and i.kind = 'lead' and i.owner_user_id = v_user),
           (select count(*)::integer from cma.follow_up_item i where i.tenant_id = v_tenant and i.kind = 'ticket' and i.owner_user_id = v_user),
           (select count(*)::integer from cma.follow_up_item i where i.tenant_id = v_tenant and i.kind = 'task' and i.owner_user_id = v_user),
           s.computed_at;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Grants, the addition
-- ---------------------------------------------------------------------------------------------
-- The application's only (a create or replace keeps a function's grants; said again for those re-created)
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.follow_up_clock_row(text,jsonb,integer,integer,integer)',
    'cma.refresh_follow_up_of(uuid,boolean)', 'cma.follow_up_list_of(uuid,text,text,uuid,boolean,boolean,integer)',
    'cma.open_leads()', 'cma.open_tickets()', 'cma.my_follow_up_counts()'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

insert into cma.schema_migration (version, description)
values ('0009u', 'The follow-up''s clock fields derived at read, not stored (option B): cma.refresh_follow_up_of stores a lead''s row without waiting_business_seconds and a ticket''s without open_business_seconds and minutes_to_breach, so those fields no longer make a write every minute (a state that turns, a lead''s day counts at midnight and a place that moves still do); cma.follow_up_clock_row derives them, with a ticket''s sla_state and a lead''s past_target, from the stored created_at, market and sla_minutes, the market''s calendar and the instant; cma.follow_up_list_of (the page, its API, an agent''s own follow-up), cma.open_leads() and cma.open_tickets() return them at now(), the calendar and settings read once per list or call; cma.my_follow_up_counts() gives Welcome''s Waiting for you its three counts without reading the rows. The item''s state, the filters and the snapshot''s counts as before')
on conflict (version) do nothing;

commit;
reset role;
