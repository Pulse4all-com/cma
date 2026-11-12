-- =============================================================================================
-- 178_job_reads.sql: addition 0009o, the minute jobs' reads without per-row lookups, the follow-up's change
-- detection and the data-quality back-off (the prod CPU incident of 11 and 12 November 2026)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics: markets, office hours, holidays, statuses and thresholds stay each
-- tenant's catalogs and settings. Runs unchanged in every database, after 176_active_attribution_present.sql (0009n).
-- Rerunnable, forward-only, in one transaction with a lock timeout. Run as your own IAM login: dev first, then
-- 179_verify_job_reads.sql there, then the verifies that read what this re-creates (reruns, unchanged, all still PASS):
-- 41, 69, 73, 75, 81, 95, 101, 105, 113, 117, 123, 133, 137, 149, 151, 155, 161, and 0009l to 0009n's own verifies,
-- which share cma.tenant_setting's triggers, the setting catalog and the scheduler's run rows with this change:
-- 173_verify_active_customers.sql, 175_verify_active_refresh_quiet.sql, 177_verify_active_attribution_present.sql; then
-- 131_time_all.sql part b. Prod the same, outside office hours: 178, 179, the same reruns; then 131 part b and
-- 124_time_flash.sql (Flash's tickets read cma.open_tickets_of). Numbering (Martin, 12 November 2026): written as 172
-- and 0009l, renumbered 178 and 0009o because #267 (Customers → Active) took 172 to 177 and 0009l to 0009n in prod
-- first; no function here is one 172, 174 or 176 re-creates (they re-create cma.check_tenant_setting, which this leaves
-- as 172 made it, and the Active functions), so every base below is unchanged. The web job refresh-follow-up.mjs (this PR) records
-- the new counts (computed, written); main's job runs unchanged on a database with 178 (it reads refreshed, rows, leads,
-- tickets, tasks and duration_ms as before), so the database may go first.
--
-- Why (Martin, 12 November 2026; Decision log, 12 Nov 2026): prod cma-prod-pg (1 vCPU) at 65 to 80 % since 11 November;
-- tools/perf/prod-load-breakdown.sql in prod: the data-quality computation 17,318 ms for the subscriptions tenant (4.4
-- million rows read, setting 1.6 million, tenant_setting 0.9 million, market_alias 0.8 million; 149,543 sequential scans),
-- the follow-up refresh 4,222 ms rewriting 4,607 items (9,217 rows written) every minute, cma.open_tickets_of 2,614 ms
-- for 1,499 tickets (24,713 sequential scans: office hours, records, markets). The cause: settings, market codes and
-- office hours read once per row, in functions that cannot be inlined (cma.setting_of, cma.market_code_of,
-- cma.business_seconds_of, cma.business_days_of, cma.next_business_noon_of), and an inlined CTE that ran
-- cma.business_seconds_of once per reference to its column (seven times a ticket).
--
-- What it adds
--   cma.business_calendar_of(tenant)   per market: its zone, the office hours of its schedule (its own, else '*') as
--                      three arrays, the holidays of the market and of '*'; read once per call by the functions below.
--                      sql, stable, rows 20
--   cma.business_seconds_in, cma.business_days_in, cma.next_business_noon_in
--                      cma.business_seconds_of, cma.business_days_of and cma.next_business_noon_of on a calendar row:
--                      the same answers (179 compares them on every market and many instants, holidays and both DST
--                      changes), reading no table. The _of functions stay as they are, for their other callers
--   cma.follow_up_marker              per tenant: the last computation, up to when the audit log of the follow-up's
--                      input tables was read, and the first instant a figure moves with the clock alone. Derived, not
--                      audited; row-level security as every tenant table
--   follow_up.recompute_minutes       setting (60; 1 to 1440, cma.check_data_quality_setting): the longest the
--                      follow-up job goes without computing while nothing changed
--   cma.follow_up_item_print, cma.follow_up_input_tables, cma.follow_up_next_change_of
--                      the item's fingerprint, the input tables (179 derives them from the functions' bodies and fails
--                      when one is missing) and the next clock change
-- What it changes (each answer as before but where said)
--   cma.open_tickets_of (based on 132)      the calendar once; each ticket's business seconds once (materialized)
--   cma.speed_to_lead_of (based on 40)      the two settings once (materialized; folded in, they were read per deal);
--                      the calendar once; each deal's noon and business seconds once
--   cma.open_leads_of (based on 72)         the two settings once; the calendar once; each lead's business days once
--   cma.data_quality_of (based on 160)      the market map (cma.market_codes_of, as one JSON object), the
--                      device-holding and the ended statuses read once into variables; the open tickets once for the
--                      two checks that read them. jit = off as before
--   cma.flash_findings_compute_of (based on 132)   the market map once, not cma.market_code_of per finding. jit off
--   cma.refresh_follow_up_of (based on 154) writes only the items that changed (deleted when changed or gone, inserted
--                      when changed or new; unchanged items stay); the same items and snapshot as before (179). The
--                      answer gains computed, written and unchanged; it records the marker. Verifies and readers that
--                      call it compute every time, as before
--   cma.refresh_follow_up() (based on 80)   the job's entry checks the marker first: no change in the audit log of
--                      the input tables since the last computation's start (2 minutes of overlap for a late commit), no
--                      migration committed since (counted), the next clock change not reached, the last computation younger than
--                      follow_up.recompute_minutes: then the snapshot's computed_at is set to now and nothing else is
--                      written (computed false, reason unchanged). Otherwise it computes as above
--   cma.refresh_data_quality_of (based on 132)   after a failed computation (the job's run row failed, no result stored
--                      since), the next attempt waits data_quality.refresh_minutes (reason backoff), not one minute;
--                      plan_cache_mode = force_custom_plan, as cma.refresh_follow_up()
--   cma.check_data_quality_setting() (based on 132)   also the range of follow_up.recompute_minutes; its trigger on
--                      cma.tenant_setting is unchanged, so no lock on that table
--
-- Speed at three times prod's volume (web/verify/perf-volume-fixture.sql, local, the fixture's subscriptions tenant, best of three,
-- before → after): data quality's computation 4,492 → 1,627 ms; cma.open_tickets_of 885 → 113 ms; cma.open_leads_of
-- 782 → 639 ms; cma.speed_to_lead_of over the previous month 911 → 448 ms; the follow-up refresh with nothing changed
-- (one transaction, so no clock moved) 2,171 ms and 24,764 rows written → 1,473 ms and none written. In office hours a
-- ticket's open time and a lead's waiting time move every minute, so those items are still written each minute (the
-- tasks and the closed hours are what stays); the job's skip happens outside office hours, between midnights.
-- Margins in code, not rules: the audit check's 2-minute overlap, the back-off's 10-minute look-back past
-- refresh_minutes, the 14 days the next opening is looked for (a midnight always comes first).
-- Limits of the change detection (each bounded by follow_up.recompute_minutes, 60 by default): the audit log's time is
-- when a row was written, not committed, so an input change in a transaction that commits more than 2 minutes after
-- writing it (an ingest transaction of many statements, a Studio session) is seen at the next computation at the latest;
-- a change of the tenant's zone (cma.tenant, not audited) likewise. In office hours every run computes. Equal row for row (and in order where the function
-- orders) to the previous definitions on both tenants of the fixture.
--
-- No index is added. One new table (cma.follow_up_marker) and one setting: docs/datamap/catalog.json describes the table
-- (this PR); Martin refreshes docs/datamap/schema.json from dev after 178. No lock on a busy table: the new table, the setting row (a
-- row lock on cma.setting) and functions only.
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
  if not exists (select 1 from cma.schema_migration where version = '0009n') then
    raise exception 'addition 0009n (176_active_attribution_present.sql) must run before 0009o';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The business calendar, read once per call
-- ---------------------------------------------------------------------------------------------
-- Each market of the tenant with its zone, the office hours of its schedule (its own hours, else '*', as
-- cma.business_seconds_of chooses them) as three parallel arrays ordered by weekday and opening time, and the holidays of
-- the market and of '*': what the business-time functions read per call, read once by their callers (0009o)
create or replace function cma.business_calendar_of(p_tenant_id uuid)
returns table (market text, time_zone text, weekdays integer[], opens time[], closes time[], holidays date[])
language sql stable
rows 20
as $$
  select m.code, m.time_zone,
         coalesce(h.weekdays, '{}'::integer[]), coalesce(h.opens, '{}'::time[]), coalesce(h.closes, '{}'::time[]),
         coalesce(hd.days, '{}'::date[])
  from cma.market m
  cross join lateral (select case when exists (select 1 from cma.business_hours x where x.tenant_id = m.tenant_id and x.market = m.code)
                                  then m.code else '*' end as sched) sc
  left join lateral (select array_agg(x.weekday::integer order by x.weekday, x.opens_at) as weekdays,
                            array_agg(x.opens_at order by x.weekday, x.opens_at) as opens,
                            array_agg(x.closes_at order by x.weekday, x.opens_at) as closes
                     from cma.business_hours x
                     where x.tenant_id = m.tenant_id and x.market = sc.sched) h on true
  left join lateral (select array_agg(distinct b.day) as days
                     from cma.business_holiday b
                     where b.tenant_id = m.tenant_id and b.market in (m.code, '*')) hd on true
  where m.tenant_id = p_tenant_id
$$;

-- cma.business_seconds_of on a market's calendar row: office seconds between two instants, each day placed in the zone
-- separately, the holidays left out; 0 when p_to <= p_from; null without a zone (an unknown market) or an instant. Reads
-- no table (0009o)
create or replace function cma.business_seconds_in(p_zone text, p_weekdays integer[], p_opens time[], p_closes time[], p_holidays date[],
                                                   p_from timestamptz, p_to timestamptz)
returns integer
language sql stable
as $$
  select case when p_zone is null or p_from is null or p_to is null then null
              when p_to <= p_from then 0
              else (select coalesce(sum(greatest(0, extract(epoch from least(w.closes, p_to) - greatest(w.opens, p_from)))), 0)::integer
                    from (select (d.day + h.opens_at) at time zone p_zone as opens,
                                 (d.day + h.closes_at) at time zone p_zone as closes
                          from generate_series((p_from at time zone p_zone)::date, (p_to at time zone p_zone)::date, interval '1 day') g(ts)
                          cross join lateral (select g.ts::date as day) d
                          join unnest(p_weekdays, p_opens, p_closes) h(weekday, opens_at, closes_at) on h.weekday = extract(isodow from d.day)
                          where not (d.day = any (coalesce(p_holidays, '{}'::date[])))) w) end
$$;

-- cma.business_days_of on a market's calendar row: the working days after p_from's local date up to p_to's (a weekday
-- with office hours, no holiday); 0 when p_to is on p_from's date or earlier; null without a zone or an instant (0009o)
create or replace function cma.business_days_in(p_zone text, p_weekdays integer[], p_holidays date[], p_from timestamptz, p_to timestamptz)
returns integer
language sql stable
as $$
  select case when p_zone is null or p_from is null or p_to is null then null
              when (p_to at time zone p_zone)::date <= (p_from at time zone p_zone)::date then 0
              else (select count(*)::integer
                    from generate_series((p_from at time zone p_zone)::date + 1, (p_to at time zone p_zone)::date, interval '1 day') g(ts)
                    where exists (select 1 from unnest(p_weekdays) w where w = extract(isodow from g.ts::date))
                      and not (g.ts::date = any (coalesce(p_holidays, '{}'::date[])))) end
$$;

-- cma.next_business_noon_of on a market's calendar row: 12:00 local on the first working day after p_at's local date,
-- within 31 days; null without a zone or an instant, or without such a day. A loop that stops at the first working day,
-- as the original's; reads no table (0009o)
create or replace function cma.next_business_noon_in(p_zone text, p_weekdays integer[], p_holidays date[], p_at timestamptz)
returns timestamptz
language plpgsql stable
as $$
declare
  v_base date;
  v_day  date;
begin
  if p_zone is null or p_at is null then
    return null;
  end if;
  v_base := (p_at at time zone p_zone)::date;
  for i in 1 .. 31 loop
    v_day := v_base + i;
    if extract(isodow from v_day)::integer = any (p_weekdays) and not (v_day = any (coalesce(p_holidays, '{}'::date[]))) then
      return (v_day + time '12:00') at time zone p_zone;
    end if;
  end loop;
  return null;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. The reads: settings, market codes and office hours once per call
-- ---------------------------------------------------------------------------------------------
-- As 0008zr's (132): the same rows, columns and order; the calendar once, each ticket's business seconds once
-- based on: 132_perf.sql
create or replace function cma.open_tickets_of(p_tenant_id uuid)
returns setof cma.open_ticket_row
language sql stable
as $$
  with s as (
    select greatest(1, cma.setting_of(p_tenant_id, 'tickets.sla_minutes')::integer) as sla_default,
           least(100, greatest(0, cma.setting_of(p_tenant_id, 'tickets.sla_warning_pct')::integer)) as warn_pct
  ),
  codes as materialized (
    select * from cma.market_codes_of(p_tenant_id)
  ),
  -- 0009o: each market's zone, office hours and holidays read once per call (cma.business_calendar_of), not per ticket
  cal as materialized (
    select * from cma.business_calendar_of(p_tenant_id)
  ),
  k as (
    select r.id, r.connection_id, r.source_system, r.source_id, r.pipeline_id, coalesce(p.label, r.pipeline_id) as pipeline_label,
           r.stage_id, coalesce(st.label, r.stage_id) as stage_label, r.owner_ref, r.source_created_at,
           coalesce(p.sla_minutes, (select s.sla_default from s)) as sla, (select s.warn_pct from s) as warn_pct, coalesce(cr.code, cc.code, 'unknown') as market,
           ow.user_id as owner_user_id
    from cma.crm_record r
    left join cma.connection_pipeline p
      on p.tenant_id = r.tenant_id and p.connection_id = r.connection_id and p.record_type = r.record_type and p.source_pipeline_id = r.pipeline_id
    left join cma.connection_stage st
      on st.tenant_id = r.tenant_id and st.connection_id = r.connection_id and st.record_type = r.record_type
     and st.source_pipeline_id = r.pipeline_id and st.source_stage_id = r.stage_id
    left join codes cr on cr.value = r.market
    left join cma.crm_contact kc on kc.tenant_id = r.tenant_id and kc.connection_id = r.connection_id and kc.source_id = r.contact_source_id
    left join codes cc on cc.value = kc.country
    left join cma.app_user_external_id ow
      on ow.tenant_id = r.tenant_id and ow.system = r.source_system || '_owner' and ow.external_id = r.owner_ref
    where r.tenant_id = p_tenant_id and r.record_type = 'ticket' and r.source_deleted_at is null
      and not coalesce(r.is_closed, false) and coalesce(p.is_counted, true)
  ),
  -- 0009o: materialized, so each ticket's business seconds are computed once (inlined, the expression ran once per
  -- reference to open_s: seven times a ticket), from the calendar's arrays (cma.business_seconds_in, as cma.business_seconds_of)
  m as materialized (
    select k.*, cma.business_seconds_in(bc.time_zone, bc.weekdays, bc.opens, bc.closes, bc.holidays, k.source_created_at, now()) as open_s
    from k
    left join cal bc on bc.market = nullif(k.market, 'unknown')
  )
  select p_tenant_id, m.id, m.connection_id, m.source_id, m.pipeline_id, m.pipeline_label, m.stage_id, m.stage_label,
         m.owner_user_id, m.owner_ref, m.market, m.source_created_at,
         m.open_s, m.sla,
         case when m.open_s is null then 'no_hours'
              when m.open_s >= m.sla * 60 then 'breached'
              when m.open_s * 100 >= m.sla * 60 * m.warn_pct then 'at_risk'
              else 'ok' end,
         case when m.open_s is null then null else m.sla - floor(m.open_s / 60.0)::integer end
  from m
  order by case when m.open_s is null then 1 else 0 end, (m.sla * 60 - m.open_s), m.source_created_at, m.source_id
$$;
alter function cma.open_tickets_of(uuid) set jit = off;

-- As 0007d's (40): the same rows; the settings once, the calendar once, each deal's noon and business seconds once
-- based on: 40_lead_metrics.sql
create or replace function cma.speed_to_lead_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns setof cma.speed_to_lead_row
language sql stable
as $$
  -- 0009o: materialized, so the two settings are read once per call (folded into the query, once per deal)
  with s as materialized (
    select greatest(0, cma.setting_of(p_tenant_id, 'speed_to_lead.pre_window_minutes')::integer) as pre_min,
           cma.setting_of(p_tenant_id, 'speed_to_lead.target_minutes')::integer * 60 as target_s
  ),
  -- 0009o: each market's zone, office hours and holidays read once per call, not per deal
  cal as materialized (
    select * from cma.business_calendar_of(p_tenant_id)
  ),
  d as materialized (
    select * from cma.lead_deals_of(p_tenant_id, p_from, p_to)
  ),
  c as materialized (
    select d.deal_id, lc.*
    from d cross join s
    cross join lateral cma.lead_calls_of(p_tenant_id, d.connection_id, d.record_type, d.source_id, d.contacts,
                                         d.created_at - make_interval(mins => s.pre_min)) lc
  ),
  fo as (select distinct on (c.deal_id) c.* from c where c.direction = 'outbound' order by c.deal_id, c.effective_at, c.call_id),
  fa as (select distinct on (c.deal_id) c.* from c order by c.deal_id, c.effective_at, c.call_id),
  fc as (select distinct on (c.deal_id) c.* from c where c.is_connected order by c.deal_id, c.effective_at, c.call_id),
  r as (
    select d.*, fo.call_id as fo_id, fo.call_source_id as fo_src, fo.effective_at as fo_at, fo.is_linked as fo_linked,
           fo.owner_ref as fo_owner, fo.source_system as fo_system,
           fa.effective_at as fa_at, fa.direction as fa_dir, fc.effective_at as fc_at,
           s.target_s,
           nn.noon,
           bc.time_zone as cal_zone, bc.weekdays as cal_weekdays, bc.opens as cal_opens, bc.closes as cal_closes, bc.holidays as cal_holidays
    from d
    cross join s
    left join cal bc on bc.market = nullif(d.market, 'unknown')
    -- offset 0: the noon computed once per deal (pulled up, it ran once per reference), from the calendar's arrays
    left join lateral (select cma.next_business_noon_in(bc.time_zone, bc.weekdays, bc.holidays, d.created_at) as noon offset 0) nn on true
    left join fo on fo.deal_id = d.deal_id
    left join fa on fa.deal_id = d.deal_id
    left join fc on fc.deal_id = d.deal_id
  ),
  m as (
    select r.*,
           bt.bs, bt.bs_now,
           ag.user_id as ag_user, ag.ref as ag_ref, ag.src as ag_from
    from r
    -- offset 0: each deal's business seconds computed once (pulled up, they ran once per reference), from the calendar's arrays
    left join lateral (
      select case when r.fo_at is not null
                  then cma.business_seconds_in(r.cal_zone, r.cal_weekdays, r.cal_opens, r.cal_closes, r.cal_holidays, r.created_at, r.fo_at) end as bs,
             case when r.fo_at is null
                  then cma.business_seconds_in(r.cal_zone, r.cal_weekdays, r.cal_opens, r.cal_closes, r.cal_holidays, r.created_at, now()) end as bs_now
      offset 0) bt on true
    left join lateral (
      select x.user_id, x.external_id as ref, x.src
      from (select xi.user_id, xi.external_id, 'call'::text as src, 1 as rank
            from cma.app_user_external_id xi
            where xi.tenant_id = p_tenant_id and xi.system = r.fo_system || '_owner' and xi.external_id = r.fo_owner
            union all
            select xi.user_id, xi.external_id, 'deal', 2
            from cma.app_user_external_id xi
            where xi.tenant_id = p_tenant_id and xi.system = r.source_system || '_owner' and xi.external_id = r.owner_ref) x
      order by x.rank limit 1) ag on true
  )
  select p_tenant_id, m.deal_id, m.connection_id, m.source_id, m.pipeline_id, m.pipeline_label, m.business_date,
         m.created_at, m.market, m.market_source, m.is_closed,
         case when m.fo_at is not null then 'called'
              when m.is_closed then 'not_called_closed' else 'not_called_open' end,
         m.fo_id, m.fo_src, m.fo_at, m.fo_linked, m.fa_at, m.fa_dir,
         coalesce(m.fa_dir = 'inbound', false), m.fc_at,
         m.ag_user, coalesce(m.ag_ref, case when m.fo_at is not null then m.fo_owner else m.owner_ref end),
         coalesce(m.ag_from, case when m.fo_owner is not null and m.fo_at is not null then 'call'
                                  when m.owner_ref is not null then 'deal' end),
         case when m.fo_at is not null then greatest(0, floor(extract(epoch from m.fo_at - m.created_at)))::integer end,
         m.bs, m.target_s,
         case when m.bs is not null then m.bs <= m.target_s
              when m.bs_now > m.target_s then false end,
         m.noon,
         case when m.fo_at is not null and m.noon is not null then m.fo_at < m.noon
              when m.fo_at is null and m.noon is not null and now() >= m.noon then false end,
         case when m.fo_at is null and not m.is_closed then m.bs_now end
  from m
$$;

-- As 0008o's (72): the same rows, columns and order; the settings once, the calendar once, each lead's days once
-- based on: 72_follow_up.sql
create or replace function cma.open_leads_of(p_tenant_id uuid)
returns setof cma.open_lead_row
language sql stable
as $$
  -- 0009o: materialized, so the two settings are read once per call (folded into the query, once per lead)
  with s as materialized (
    select cma.setting_of(p_tenant_id, 'leads.age_buckets_business_days') as edges,
           greatest(0, cma.setting_of(p_tenant_id, 'speed_to_lead.pre_window_minutes')::integer) as pre_min
  ),
  -- 0009o: each market's zone, office hours and holidays read once per call, not per lead
  cal as materialized (
    select * from cma.business_calendar_of(p_tenant_id)
  ),
  r as (
    select * from cma.speed_to_lead_of(p_tenant_id, null, null) x where x.status = 'not_called_open'
  )
  select p_tenant_id, r.deal_id, r.connection_id, r.deal_source_id, r.pipeline_id, r.pipeline_label,
         r.agent_user_id, r.agent_ref, r.market, r.created_at, r.waiting_business_seconds,
         a.days, b.bucket_from, b.bucket_to,
         case when r.within_target is false then true when r.waiting_business_seconds is null then null else false end,
         lc.last_at,
         case when lc.last_at is not null then floor(extract(epoch from now() - lc.last_at) / 86400)::integer end
  from r
  cross join s
  join cma.lead_deals_of(p_tenant_id, null, null) d on d.deal_id = r.deal_id
  left join cal bc on bc.market = nullif(r.market, 'unknown')
  -- offset 0: the days computed once per lead (pulled up, the call ran once per reference to a.days), from the calendar's arrays
  cross join lateral (select cma.business_days_in(bc.time_zone, bc.weekdays, bc.holidays, r.created_at, now()) as days offset 0) a
  cross join lateral cma.age_bucket_of(a.days, s.edges) b
  left join lateral (
    select max(c.effective_at) as last_at
    from cma.lead_calls_of(p_tenant_id, d.connection_id, d.record_type, d.source_id, d.contacts, d.created_at - make_interval(mins => s.pre_min)) c) lc on true
  order by r.waiting_business_seconds desc nulls last, r.created_at
$$;

-- As 0009f's (160): the same rows; the market map, the statuses and the open tickets read once
-- based on: 160_installed_base_now.sql
create or replace function cma.data_quality_of(p_tenant_id uuid)
returns table (check_key text, connection_id uuid, object_type text, object_id text, value text)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_start   timestamptz;
  -- 0009o: read once per call, not per row: the market map (every value a record, contact, line or store writes, with
  -- the code the market rule gives it, cma.market_codes_of), the device-holding and the ended statuses
  v_codes   jsonb := (select coalesce(jsonb_object_agg(c.value, c.code), '{}'::jsonb) from cma.market_codes_of(p_tenant_id) c);
  v_holding text[] := cma.flash_holding_statuses_of(p_tenant_id);
  v_ended   text[] := cma.flash_ended_statuses_of(p_tenant_id);
begin
  select cma.setting_of(t.id, 'intake.start_date')::date::timestamp at time zone t.timezone into v_start
  from cma.tenant t where t.id = p_tenant_id;

  return query
  -- 0009o: the open tickets once (two checks read them)
  with ot as materialized (select * from cma.open_tickets_of(p_tenant_id))
  -- lead deals without any contact
  select 'deal_without_contact'::text, d.connection_id, d.record_type, d.source_id, null::text
  from cma.lead_deals_of(p_tenant_id, null, null) d
  where cardinality(d.contacts) = 0
  union all
  -- primary contacts of lead deals without country or language
  select 'deal_contact_incomplete', k.connection_id, 'contact', k.source_id, null
  from cma.crm_contact k
  where k.tenant_id = p_tenant_id and k.source_deleted_at is null
    and (k.country is null or k.language is null)
    and exists (select 1 from cma.lead_deals_of(p_tenant_id, null, null) d
                where d.connection_id = k.connection_id and d.contact_source_id = k.source_id)
  union all
  -- markets and countries written by a source that are no catalog market
  select 'market_not_in_catalog', cr.connection_id, cr.record_type, cr.source_id, cr.market
  from cma.crm_record cr
  where cr.tenant_id = p_tenant_id and cr.source_deleted_at is null and cr.source_created_at >= v_start
    and nullif(btrim(cr.market), '') is not null and (v_codes ->> cr.market) is null
  union all
  select 'market_not_in_catalog', k.connection_id, 'contact', k.source_id, k.country
  from cma.crm_contact k
  where k.tenant_id = p_tenant_id and k.source_deleted_at is null
    and nullif(btrim(k.country), '') is not null and (v_codes ->> k.country) is null
  union all
  -- CRM owners (of records since the start and of calls since the start) without a person
  select 'owner_without_person', o.connection_id, 'owner', o.owner_ref, null
  from (select cr.connection_id, cr.source_system, cr.owner_ref
        from cma.crm_record cr
        where cr.tenant_id = p_tenant_id and cr.source_deleted_at is null and cr.source_created_at >= v_start
          and cr.owner_ref is not null
        union
        select c.connection_id, c.source_system, c.owner_ref
        from cma.crm_call c
        where c.tenant_id = p_tenant_id and c.source_deleted_at is null and c.occurred_at >= v_start
          and c.owner_ref is not null) o
  where not exists (select 1 from cma.app_user_external_id x
                    where x.tenant_id = p_tenant_id and x.system = o.source_system || '_owner' and x.external_id = o.owner_ref)
  union all
  -- telephony users without a person
  select 'telephony_user_without_person', u.connection_id, 'telephony_user', u.user_ref, null
  from (select distinct tc.connection_id, tc.source_system, tc.user_ref
        from cma.telephony_call tc
        where tc.tenant_id = p_tenant_id and tc.source_deleted_at is null and tc.started_at >= v_start
          and tc.user_ref is not null) u
  where not exists (select 1 from cma.app_user_external_id x
                    where x.tenant_id = p_tenant_id and x.system = u.source_system || '_user' and x.external_id = u.user_ref)
  union all
  -- CRM calls without a current contact association
  select 'crm_call_without_contact', c.connection_id, 'crm_call', c.source_id, null
  from cma.crm_call c
  where c.tenant_id = p_tenant_id and c.source_deleted_at is null and c.occurred_at >= v_start
    and not exists (select 1 from cma.crm_association a
                    where a.tenant_id = c.tenant_id and a.connection_id = c.connection_id and a.from_type = 'crm_call'
                      and a.from_id = c.source_id and a.to_type = 'contact' and a.removed_at is null)
  union all
  -- telephony calls older than 24 hours without a current link, once the tenant has CRM calls; an
  -- outbound call not connected (no answer) and without a current tag is skipped when the connection says so
  -- (dq_unlinked_skip = outbound_unanswered_untagged, the default for a telephony connection; 0008o; 0008zc)
  select 'telephony_call_unlinked', tc.connection_id, 'telephony_call', tc.source_id, null
  from cma.telephony_call tc
  join cma.integration_connection ic on ic.tenant_id = tc.tenant_id and ic.id = tc.connection_id
  where tc.tenant_id = p_tenant_id and tc.source_deleted_at is null
    and tc.started_at >= v_start and tc.started_at < now() - interval '24 hours'
    and exists (select 1 from cma.crm_call c where c.tenant_id = p_tenant_id and c.source_deleted_at is null)
    and not exists (select 1 from cma.call_link l
                    where l.tenant_id = tc.tenant_id and l.telephony_call_id = tc.id and l.unlinked_at is null)
    and not (coalesce(ic.settings ->> 'dq_unlinked_skip', case when ic.kind = 'telephony' then 'outbound_unanswered_untagged' end) = 'outbound_unanswered_untagged'
             and tc.direction = 'outbound'
             and tc.answered_at is null
             and not exists (select 1 from cma.telephony_call_tag g
                             where g.tenant_id = tc.tenant_id and g.connection_id = tc.connection_id
                               and g.call_source_id = tc.source_id and g.untagged_at is null))
  union all
  -- commerce customers whose id no contact holds, or several contacts hold
  -- (since 0008zn the contacts per id counted once by a join, no read per customer; the same rows)
  select case when coalesce(h.contacts, 0) = 0 then 'commerce_unmatched' else 'commerce_ambiguous' end,
         cu.connection_id, 'commerce_customer', cu.source_id, null
  from cma.commerce_customer cu
  left join (select r.system, r.external_id, count(distinct r.contact_id) as contacts
             from cma.crm_contact_ref r where r.tenant_id = p_tenant_id group by 1, 2) h
    on h.system = cu.source_system and h.external_id = cu.source_id
  where cu.tenant_id = p_tenant_id and cu.source_deleted_at is null and coalesce(h.contacts, 0) <> 1
  union all
  -- contacts with both first slots of a ref system taken
  select 'contact_slots_full', k.connection_id, 'contact', k.source_id, r.system
  from cma.crm_contact k
  join cma.crm_contact_ref r on r.tenant_id = k.tenant_id and r.contact_id = k.id and r.slot in (1, 2)
  where k.tenant_id = p_tenant_id and k.source_deleted_at is null
  group by k.connection_id, k.source_id, r.system
  having count(distinct r.slot) = 2
  union all
  -- contacts whose country differs from the market of a store their commerce id belongs to
  select distinct 'contact_country_differs', k.connection_id, 'contact', k.source_id,
         (v_codes ->> k.country) || '/' || st.market
  from cma.crm_contact k
  join cma.crm_contact_ref r on r.tenant_id = k.tenant_id and r.contact_id = k.id
  join cma.commerce_customer cu
    on cu.tenant_id = r.tenant_id and cu.source_system = r.system and cu.source_id = r.external_id and cu.source_deleted_at is null
  join cma.commerce_store st on st.tenant_id = cu.tenant_id and st.connection_id = cu.connection_id
  where k.tenant_id = p_tenant_id and k.source_deleted_at is null
    and (v_codes ->> k.country) is distinct from st.market
    and nullif(btrim(k.country), '') is not null
  union all
  -- one commerce customer id in two or more stores
  select 'customer_in_two_stores', null::uuid, 'commerce_customer', cu.source_id, cu.source_system
  from cma.commerce_customer cu
  where cu.tenant_id = p_tenant_id and cu.source_deleted_at is null
  group by cu.source_system, cu.source_id
  having count(distinct cu.connection_id) > 1
  union all
  -- active pipelines no person has ever written (only the source's refresh)
  select 'pipeline_unreviewed', p.connection_id, 'pipeline', p.source_pipeline_id, p.record_type
  from cma.connection_pipeline p
  where p.tenant_id = p_tenant_id and p.status = 'active'
    and not exists (select 1 from cma.audit_log al
                    join cma.app_user u on u.tenant_id = al.tenant_id and u.id = al.actor_user_id and u.kind = 'person'
                    where al.tenant_id = p.tenant_id and al.table_name = 'connection_pipeline' and al.row_id = p.id::text)
  union all
  -- counted active forms without a market
  select 'form_without_market', f.connection_id, 'form', f.source_form_id, null
  from cma.connection_form f
  where f.tenant_id = p_tenant_id and f.status = 'active' and f.is_counted and f.market is null
  union all
  -- held contacts whose country came from a fallback slot (0008m)
  select 'contact_country_fallback', k.connection_id, 'contact', k.source_id, k.country_source::text
  from cma.crm_contact k
  where k.tenant_id = p_tenant_id and k.source_deleted_at is null and k.country_source > 1
  union all
  -- open tickets without an owner, and without a market, per pipeline, once ticket SLAs are configured (0008o)
  select 'ticket_no_owner', t.connection_id, 'ticket', t.ticket_source_id, t.pipeline_id
  from ot t
  where t.owner_ref is null and cma.follow_up_configured_of(p_tenant_id)
  union all
  select 'ticket_no_market', t.connection_id, 'ticket', t.ticket_source_id, t.pipeline_id
  from ot t
  where t.market = 'unknown' and cma.follow_up_configured_of(p_tenant_id)
  union all
  -- open tasks whose owner is not linked to a person (0008o)
  select 'crm_task_owner_unlinked', k.connection_id, 'task', k.task_source_id, k.owner_ref
  from cma.open_tasks_of(p_tenant_id) k
  where k.owner_ref is not null and k.owner_user_id is null
  union all
  -- kept form answers no option of their field accounts for, current or retired (0008p): one row per
  -- submission and field of a form the source has described, the field's name as the code
  select 'form_answer_not_in_options', fs.connection_id, 'form_submission', fs.source_id, e.key
  from cma.form_submission fs
  join cma.connection_form f
    on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
   and f.fields_refreshed_at is not null
  cross join lateral jsonb_each(fs.kept_values) e
  left join cma.connection_form_field ff
    on ff.tenant_id = fs.tenant_id and ff.connection_id = fs.connection_id and ff.source_form_id = fs.source_form_id
   and ff.name = e.key
  where fs.tenant_id = p_tenant_id and fs.kept_values <> '{}'::jsonb
    and (ff.name is null or not cma.form_choice_kind(ff.kind)
         or exists (select 1
                    from (select e.value #>> '{}' as v where jsonb_typeof(e.value) = 'string'
                          union all
                          select x from jsonb_array_elements_text(case when jsonb_typeof(e.value) = 'array' then e.value
                                                                       else '[]'::jsonb end) x) a
                    where not (a.v = any (ff.options || ff.retired_options))))
  union all
  -- review channels the source holds without a market (0008ze), with how many reviews the CMA holds of each
  select 'review_channel_unmapped', ch.connection_id, 'review_channel', ch.source_id,
         (select count(*) from cma.review r where r.tenant_id = ch.tenant_id and r.review_channel_id = ch.id)::text
  from cma.review_channel ch
  where ch.tenant_id = p_tenant_id and ch.source_deleted_at is null and ch.market is null
  union all
  -- active markets without a counted review channel, once the tenant has a reviews connection (0008ze)
  select 'market_without_review_channel', null::uuid, 'market', m.code, null::text
  from cma.market m
  where m.tenant_id = p_tenant_id and m.status = 'active' and cma.reviews_set_up_of(p_tenant_id)
    and not exists (select 1 from cma.review_channel ch
                    where ch.tenant_id = m.tenant_id and ch.market = m.code and ch.is_counted and ch.source_deleted_at is null)
  union all
  -- devices without a serial number (0008zi), of devices the register still holds
  select 'device_serial_missing', dv.connection_id, 'device', dv.source_id, null::text
  from cma.device dv
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.serial is null
  union all
  -- devices whose serial number another device of the tenant holds too (0008zi); the value is the serial
  select 'device_serial_duplicate', dv.connection_id, 'device', dv.source_id, dv.serial
  from cma.device dv
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.serial is not null
    and exists (select 1 from cma.device o
                where o.tenant_id = dv.tenant_id and o.serial = dv.serial and o.id <> dv.id and o.source_deleted_at is null)
  union all
  -- devices whose model, status or country maps to no catalog row (0008zi); the value is the register's label
  select 'device_model_unmapped', dv.connection_id, 'device', dv.source_id, dv.raw ->> 'model'
  from cma.device dv
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.model_key is null
  union all
  select 'device_status_unmapped', dv.connection_id, 'device', dv.source_id, dv.raw ->> 'status'
  from cma.device dv
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.device_status_key is null
  union all
  select 'device_market_unmapped', dv.connection_id, 'device', dv.source_id, dv.raw ->> 'country'
  from cma.device dv
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.market is null
  union all
  -- devices whose register customer reference is no id (0008zi): the reference is never stored, so no value
  select 'device_customer_ref_invalid', dv.connection_id, 'device', dv.source_id, null::text
  from cma.device dv
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.customer_ref_invalid
  union all
  -- due items of tracked devices without a due date (basis unknown, 0008zi); the value is the component kind
  select 'component_due_unknown', i.connection_id, 'device', i.source_id, i.component_key
  from cma.maintenance_items_of(p_tenant_id, cma.tenant_today_of(p_tenant_id)) i
  where i.basis = 'unknown'
  union all
  -- devices in a status in the field without a subscription reference (0008zi): the rule's one implementation, which
  -- the Installed base's list reads too (0009f)
  select 'field_device_without_subscription_ref', u.connection_id, 'device', u.source_id, null::text
  from cma.field_devices_without_subscription_ref_of(p_tenant_id) u
  union all
  -- store customers with an order linked to a CRM contact that lacks a reference of commerce.required_contact_refs in
  -- every slot (0008zn); the value the references missing, comma-separated; contact_deleted when the CRM deleted the
  -- contact the link names (fixed in the CRM: the link or the contact); contact_not_held while the CMA does not hold the
  -- contact (its references are unknown until the contact is read)
  select 'customer_required_ref_missing', cu.connection_id, 'commerce_customer', cu.source_id,
         case when k.id is null then 'contact_not_held'
              when k.source_deleted_at is not null then 'contact_deleted'
              else array_to_string(array(select x from unnest(rq.refs) x
                                         where not exists (select 1 from cma.crm_contact_ref cr
                                                           where cr.tenant_id = k.tenant_id and cr.contact_id = k.id and cr.system = x)), ',') end
  from cma.commerce_customer cu
  cross join (select cma.flash_list_of(cma.setting_of(p_tenant_id, 'commerce.required_contact_refs')) as refs offset 0) rq
  left join cma.crm_contact k
    on k.tenant_id = cu.tenant_id and k.connection_id = cu.crm_connection_id and k.source_id = cu.crm_contact_source_id
  where cu.tenant_id = p_tenant_id and cu.source_deleted_at is null and cu.crm_contact_source_id is not null
    and coalesce(cu.orders_count, 0) >= 1 and cardinality(rq.refs) > 0
    and (k.id is null or k.source_deleted_at is not null
         or exists (select 1 from unnest(rq.refs) x
                    where not exists (select 1 from cma.crm_contact_ref cr
                                      where cr.tenant_id = k.tenant_id and cr.contact_id = k.id and cr.system = x)))
  union all
  -- devices the register still holds lacking a named id of assets.required_refs (0008zn); the value the ids missing
  select 'device_required_ref_missing', dv.connection_id, 'device', dv.source_id,
         array_to_string(array(select x from unnest(rq.refs) x where not (dv.external_refs ? x)), ',')
  from cma.device dv
  cross join (select cma.flash_list_of(cma.setting_of(p_tenant_id, 'assets.required_refs')) as refs offset 0) rq
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and cardinality(rq.refs) > 0
    and exists (select 1 from unnest(rq.refs) x where not (dv.external_refs ? x))
  union all
  -- subscriptions the latest full read still returns whose customer id no customer of their store holds (0008zn)
  select 'subscription_customer_unmatched', sb.connection_id, 'subscription', sb.source_id, null::text
  from cma.subscription sb
  -- the mapping fenced (offset 0): inlined, the planner guesses its few rows wrong and probes the customers per row
  join (select x.connection_id, x.store_connection_id from cma.flash_subscription_stores_of(p_tenant_id) x offset 0) sm
    on sm.connection_id = sb.connection_id
  left join (select cu.connection_id, cu.source_id from cma.commerce_customer cu
             where cu.tenant_id = p_tenant_id and cu.source_deleted_at is null) cu
    on cu.connection_id = sm.store_connection_id and cu.source_id = sb.customer_source_id
  where sb.tenant_id = p_tenant_id and sb.source_deleted_at is null and sb.customer_source_id is not null and cu.source_id is null
  union all
  -- subscriptions in a device-holding status (flash.device_holding_statuses since 0008zt; the key keeps 0008zn's word) of
  -- a store whose market the register holds devices of, that no device of that market the register still holds names by
  -- its subscription reference, once the tenant has an asset register set up; the value the status. A market without any
  -- device in the register (one it does not cover yet) gives no finding
  select 'active_subscription_without_device', sb.connection_id, 'subscription', sb.source_id, sb.status
  from cma.subscription sb
  join (select x.connection_id, x.market from cma.flash_subscription_stores_of(p_tenant_id) x offset 0) sm on sm.connection_id = sb.connection_id
  left join (select distinct d.market, d.subscription_ref from cma.device d
             where d.tenant_id = p_tenant_id and d.source_deleted_at is null and d.subscription_ref is not null) dr
    on dr.subscription_ref = sb.source_id and dr.market = sm.market
  where sb.tenant_id = p_tenant_id and sb.source_deleted_at is null and dr.subscription_ref is null
    and sb.status = any (v_holding) and cma.assets_set_up_of(p_tenant_id)
    -- the register's markets, once (a set, never a read per subscription)
    and sm.market in (select distinct d.market from cma.device d where d.tenant_id = p_tenant_id and d.source_deleted_at is null and d.market is not null)
  union all
  -- devices in a status in the field, of a market whose store's subscriptions the CMA reads, whose subscription
  -- reference names no subscription the CMA holds of that market (0008zn)
  select 'device_subscription_ref_unknown', dv.connection_id, 'device', dv.source_id, null::text
  from cma.device dv
  join cma.device_status st on st.tenant_id = dv.tenant_id and st.key = dv.device_status_key and st.is_in_field
  -- the subscriptions the CMA holds per market of their store, once (a set joined, never a read per device)
  left join (select distinct sm.market, sb.source_id
             from cma.subscription sb
             join (select y.connection_id, y.market from cma.flash_subscription_stores_of(p_tenant_id) y offset 0) sm on sm.connection_id = sb.connection_id
             where sb.tenant_id = p_tenant_id and sb.source_deleted_at is null) held
    on held.market = dv.market and held.source_id = dv.subscription_ref
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.subscription_ref is not null
    and dv.market in (select sm.market from cma.flash_subscription_stores_of(p_tenant_id) sm)
    and held.source_id is null
  union all
  -- devices in a status in the field linked to a subscription of their market in a status of
  -- flash.ended_subscription_statuses (0008zn); the value the subscription's status (the first by status when two
  -- subscriptions of the market share the id)
  select 'field_device_on_ended_subscription', dv.connection_id, 'device', dv.source_id, sb.status
  from cma.device dv
  join cma.device_status st on st.tenant_id = dv.tenant_id and st.key = dv.device_status_key and st.is_in_field
  join (select sm.market, x.source_id, min(x.status) as status
        from cma.subscription x
        join (select y.connection_id, y.market from cma.flash_subscription_stores_of(p_tenant_id) y offset 0) sm on sm.connection_id = x.connection_id
        where x.tenant_id = p_tenant_id and x.source_deleted_at is null and x.status = any (v_ended)
        group by 1, 2) sb on sb.source_id = dv.subscription_ref and sb.market = dv.market
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.subscription_ref is not null
  union all
  -- devices in a status in the field linked to a subscription of their market whose status is neither a device-holding
  -- one nor an ended one (0008zt: for Pulse4all paused, merged and never-subscribed; an ended one is the check above, so
  -- no device is listed twice); the value the subscription's status (the device's own subscription, as the installed base
  -- links it: the first by id when two subscriptions of the market share the id)
  select 'field_device_on_non_holding_subscription', dv.connection_id, 'device', dv.source_id, sb.status
  from cma.device dv
  join cma.device_status st on st.tenant_id = dv.tenant_id and st.key = dv.device_status_key and st.is_in_field
  join (select distinct on (sm.market, x.source_id) sm.market, x.source_id, x.status
        from cma.subscription x
        join (select y.connection_id, y.market from cma.flash_subscription_stores_of(p_tenant_id) y offset 0) sm on sm.connection_id = x.connection_id
        where x.tenant_id = p_tenant_id and x.source_deleted_at is null
        order by sm.market, x.source_id, x.id) sb on sb.source_id = dv.subscription_ref and sb.market = dv.market
  where dv.tenant_id = p_tenant_id and dv.source_deleted_at is null and dv.subscription_ref is not null
    and not (sb.status = any (v_holding)) and not (sb.status = any (v_ended));

  -- parked write-backs: the outbox arrives with migration 0007c (DESIGN §4.3a); until then the check
  -- finds nothing. Only the columns every outbox row has by design are read: id, connection, status
  if to_regclass('cma.outbox_action') is not null then
    return query execute
      'select ''writeback_parked''::text, o.connection_id, ''outbox_action''::text, o.id::text, null::text
       from cma.outbox_action o
       where o.tenant_id = $1 and o.status = ''needs_review'''
      using p_tenant_id;
  end if;
end
$$;
alter function cma.data_quality_of(uuid) set jit = off;

-- As 0008zr's (132): the same rows and order; the market map once, not cma.market_code_of per finding
-- based on: 132_perf.sql
create or replace function cma.flash_findings_compute_of(p_tenant_id uuid)
returns table (check_key text, connection_id uuid, object_type text, object_id text, value text, market text, fix_in text, fix_adapter text)
language sql stable
as $$
  with f as materialized (
    select q.* from cma.data_quality_of(p_tenant_id) q
  ), mm as materialized (
    -- 0009o: the market map once per call (each value with the code the market rule gives it), not a read per finding
    select coalesce(jsonb_object_agg(x.value, x.code), '{}'::jsonb) as m from cma.market_codes_of(p_tenant_id) x
  ), c as materialized (
    select ic.id, ic.adapter, coalesce(ic.kind, (cma.connection_held_kinds_of(ic.tenant_id, ic.id))[1]) as kind, ic.status
    from cma.integration_connection ic where ic.tenant_id = p_tenant_id
  ), ka as materialized (
    select distinct on (c.kind) c.kind, c.adapter from c where c.status = 'active' and c.kind is not null order by c.kind, c.id
  ), st as materialized (
    select x.connection_id, x.market from cma.commerce_store x where x.tenant_id = p_tenant_id
  ), sm as materialized (
    select * from cma.flash_subscription_stores_of(p_tenant_id)
  )
  select f.check_key, f.connection_id, f.object_type, f.object_id, f.value,
         coalesce(case f.object_type
                    when 'commerce_customer' then st.market
                    when 'subscription' then sm.market
                    when 'market' then f.object_id
                    when 'device' then (select d.market from cma.device d
                                        where d.tenant_id = p_tenant_id and d.connection_id = f.connection_id and d.source_id = f.object_id)
                    when 'contact' then (select (select mm.m from mm) ->> k.country from cma.crm_contact k
                                         where k.tenant_id = p_tenant_id and k.connection_id = f.connection_id and k.source_id = f.object_id)
                    when 'form' then (select cf.market from cma.connection_form cf
                                      where cf.tenant_id = p_tenant_id and cf.connection_id = f.connection_id and cf.source_form_id = f.object_id)
                    when 'review_channel' then (select ch.market from cma.review_channel ch
                                                where ch.tenant_id = p_tenant_id and ch.connection_id = f.connection_id and ch.source_id = f.object_id)
                    when 'deal' then (select coalesce((select mm.m from mm) ->> r.market, (select mm.m from mm) ->> rk.country)
                                      from cma.crm_record r
                                      left join cma.crm_contact rk
                                        on rk.tenant_id = r.tenant_id and rk.connection_id = r.connection_id and rk.source_id = r.contact_source_id
                                      where r.tenant_id = p_tenant_id and r.connection_id = f.connection_id and r.record_type = 'deal'
                                        and r.source_id = f.object_id)
                    when 'ticket' then (select coalesce((select mm.m from mm) ->> r.market, (select mm.m from mm) ->> rk.country)
                                        from cma.crm_record r
                                        left join cma.crm_contact rk
                                          on rk.tenant_id = r.tenant_id and rk.connection_id = r.connection_id and rk.source_id = r.contact_source_id
                                        where r.tenant_id = p_tenant_id and r.connection_id = f.connection_id and r.record_type = 'ticket'
                                          and r.source_id = f.object_id) end, 'unknown'),
         x.fix_in,
         case when x.fix_in = 'cma' then null when c1.kind = x.fix_in then c1.adapter else ka.adapter end
  from f
  cross join lateral (select cma.data_quality_fix_in(f.check_key, f.value) as fix_in) x
  left join c c1 on c1.id = f.connection_id
  left join ka on ka.kind = x.fix_in
  left join st on f.object_type = 'commerce_customer' and st.connection_id = f.connection_id
  left join sm on f.object_type = 'subscription' and sm.connection_id = f.connection_id
$$;
alter function cma.flash_findings_compute_of(uuid) set jit = off;

-- ---------------------------------------------------------------------------------------------
-- 3. The follow-up: write only what changed; compute only when something changed
-- ---------------------------------------------------------------------------------------------
create table if not exists cma.follow_up_marker (
  tenant_id          uuid primary key default cma.current_tenant_id() references cma.tenant (id),
  computed_at        timestamptz not null,
  inputs_checked_at  timestamptz not null,
  next_change_at     timestamptz,
  migrations         integer not null default 0
);
comment on table cma.follow_up_marker is 'Per tenant, what the follow-up job checks before computing again (addition 0009o): when the figures were last computed, up to when the audit log of their input tables was read, and the first instant a figure moves with the clock alone. Derived: written by the refresh, not audited';
comment on column cma.follow_up_marker.computed_at is 'The last computation (follow_up.recompute_minutes counts from it)';
comment on column cma.follow_up_marker.inputs_checked_at is 'The input tables'' audit log was read up to this instant (the computation''s start, or the last check''s); the next check reads from 2 minutes before it (a later commit of an earlier change)';
comment on column cma.follow_up_marker.migrations is 'How many migrations cma.schema_migration held at the computation: one committed since (even one that started before it) makes the job compute';
comment on column cma.follow_up_marker.next_change_at is 'The first instant a figure changes with the clock alone (cma.follow_up_next_change_of); null: compute every run';
select cma.setup_tenant_table('cma.follow_up_marker');
-- derived and rewritten every minute, like cma.follow_up_item: not audited
drop trigger if exists audit on cma.follow_up_marker;

insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('follow_up.recompute_minutes', 'integer', null, '60',
     'The longest the follow-up job goes without computing the figures again while nothing they read has changed, in minutes (1 to 1440); the job still checks every minute')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- As 0008zr's (132), and the range of follow_up.recompute_minutes
-- based on: 132_perf.sql
create or replace function cma.check_data_quality_setting()
returns trigger
language plpgsql
as $$
begin
  if new.key = 'data_quality.refresh_minutes'
     and (case when length(new.value) > 4 then true else new.value::integer not between 1 and 1440 end) then
    raise exception 'Setting % takes a whole number of minutes from 1 to 1440', new.key using errcode = 'CMA04';
  end if;
  -- 0009o: the follow-up's longest gap between two computations when nothing changed, 1 to 1440 minutes
  if new.key = 'follow_up.recompute_minutes'
     and (case when length(new.value) > 4 then true else new.value::integer not between 1 and 1440 end) then
    raise exception 'Setting % takes a whole number of minutes from 1 to 1440', new.key using errcode = 'CMA04';
  end if;
  return new;
end
$$;

-- An item's place and content as one fingerprint: what the refresh compares to write only the items that changed (0009o)
create or replace function cma.follow_up_item_print(p_sort_key integer, p_market text, p_owner_user_id uuid, p_state text, p_row jsonb)
returns text
language sql immutable
as $$
  select md5(jsonb_build_array(p_sort_key, p_market, p_owner_user_id, p_state, p_row)::text)
$$;

-- The tables whose rows the follow-up's figures read (the open leads, tickets and tasks, the courtesy flag, the settings),
-- each audited: a change to any of them, in the audit log, makes the job compute again. 179 derives the same list from the
-- functions' bodies and fails when a later change reads a table this list lacks (0009o)
create or replace function cma.follow_up_input_tables()
returns text[]
language sql immutable
as $$
  select array['app_user_external_id', 'business_holiday', 'business_hours', 'call_link', 'commerce_customer', 'commerce_order',
               'commerce_store', 'connection_call_outcome', 'connection_pipeline', 'connection_stage', 'connection_task_status',
               'connection_task_type', 'crm_association', 'crm_call', 'crm_contact', 'crm_record', 'crm_task', 'market',
               'market_alias', 'telephony_call', 'telephony_call_tag', 'telephony_number', 'telephony_tag', 'tenant_setting']
$$;

-- The first instant at or after p_now at which a follow-up figure can change with the clock alone, its inputs unchanged
-- (0009o): p_now while any market of the tenant is in office hours (a lead's waiting and a ticket's open time grow), else
-- the next opening of any market; the next local midnight of any market, store and of the tenant (business days, a
-- task's due state, a courtesy order's due date in its market's or store's zone); a lead's next whole day since its last call. Null when none applies
create or replace function cma.follow_up_next_change_of(p_tenant_id uuid, p_now timestamptz)
returns timestamptz
language sql stable
as $$
  with cal as materialized (
    select * from cma.business_calendar_of(p_tenant_id)
  ),
  slot as (
    select (d.day + h.opens_at) at time zone c.time_zone as opens, (d.day + h.closes_at) at time zone c.time_zone as closes
    from cal c
    cross join lateral generate_series((p_now at time zone c.time_zone)::date - 1, (p_now at time zone c.time_zone)::date + 14, interval '1 day') g(ts)
    cross join lateral (select g.ts::date as day) d
    join lateral unnest(c.weekdays, c.opens, c.closes) h(weekday, opens_at, closes_at) on h.weekday = extract(isodow from d.day)
    where not (d.day = any (c.holidays))
  )
  select least(
    (select min(greatest(s.opens, p_now)) from slot s where s.closes > p_now),
    (select min(((p_now at time zone c.time_zone)::date + 1)::timestamp at time zone c.time_zone) from cal c),
    (select ((p_now at time zone t.timezone)::date + 1)::timestamp at time zone t.timezone from cma.tenant t where t.id = p_tenant_id),
    (select min(((p_now at time zone st.time_zone)::date + 1)::timestamp at time zone st.time_zone)
     from cma.commerce_store st where st.tenant_id = p_tenant_id and st.time_zone is not null),
    (select min(x.at + (floor(extract(epoch from p_now - x.at) / 86400) + 1) * interval '86400 seconds')
     from (select (i.row ->> 'last_call_at')::timestamptz as at
           from cma.follow_up_item i where i.tenant_id = p_tenant_id and i.kind = 'lead') x
     where x.at is not null and x.at <= p_now))
$$;

-- As 0009c's (154): the same items, snapshot and answer keys, and computed, written and unchanged; only the items that
-- changed written; the marker recorded
-- based on: 154_courtesy_bases.sql
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
  -- the item's kind and id, computed once per item, and the two maps are compared: two passes, never a read per item
  v_new := array(
    select row(p_tenant_id, 'lead', o.ordinality, o.deal_id, coalesce(nullif(o.market, ''), 'unknown'), o.owner_user_id,
               case when o.past_target then 'past_target' when o.past_target is false then 'within_target' else 'no_hours' end,
               to_jsonb(o) - 'tenant_id' - 'ordinality')::cma.follow_up_item
    from cma.open_leads_of(p_tenant_id) with ordinality o
    union all
    select row(p_tenant_id, 'ticket', o.ordinality, o.ticket_id, coalesce(nullif(o.market, ''), 'unknown'), o.owner_user_id, o.sla_state,
               to_jsonb(o) - 'tenant_id' - 'ordinality')::cma.follow_up_item
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

-- The job's entry: the current tenant, for the scheduler's system user. Since 0009o it first checks whether anything the
-- figures read has changed: nothing in the audit log of the input tables since the last computation's start (2 minutes
-- of overlap for a transaction that committed late: the ingest's statements stop at 15 seconds; a longer transaction, such
-- as a Studio session, is caught by follow_up.recompute_minutes), no migration committed since (counted), no figure
-- moving with the clock before the stored instant, and the last computation younger than follow_up.recompute_minutes. Then the figures stand: the
-- snapshot's computed_at says they were confirmed now and nothing else is written (reason unchanged). Otherwise it
-- computes as before, writing only the items that changed (cma.refresh_follow_up_of)
-- based on: 80_follow_up_snapshot.sql
create or replace function cma.refresh_follow_up()
returns jsonb
language plpgsql
as $$
declare
  v_tenant  uuid := cma.current_tenant_id();
  v_t0      timestamptz := clock_timestamp();
  mk        cma.follow_up_marker;
  v_leads   integer;
  v_tickets integer;
  v_tasks   integer;
begin
  perform cma.assert_permission('follow_up.refresh');
  select * into mk from cma.follow_up_marker x where x.tenant_id = v_tenant;
  if mk.tenant_id is not null
     and now() < mk.next_change_at
     and now() < mk.computed_at + make_interval(mins => cma.setting_of(v_tenant, 'follow_up.recompute_minutes')::integer)
     and exists (select 1 from cma.follow_up_snapshot s where s.tenant_id = v_tenant)
     and (select count(*)::integer from cma.schema_migration) = mk.migrations
     -- min() over the time index (audit_log_time_idx), a bounded range, never exists(): with no row, exists() may be
     -- planned on another index and read the tenant's whole history (CLAUDE.md, Performance, N06)
     and (select min(a.changed_at) from cma.audit_log a
          where a.tenant_id = v_tenant and a.changed_at > mk.inputs_checked_at - interval '2 minutes'
            and a.table_name = any (cma.follow_up_input_tables())) is null then
    if not pg_try_advisory_xact_lock(cma.follow_up_lock_key(v_tenant)) then
      return jsonb_build_object('refreshed', false, 'reason', 'running');
    end if;
    update cma.follow_up_snapshot s set computed_at = now() where s.tenant_id = v_tenant;
    update cma.follow_up_marker x set inputs_checked_at = v_t0 where x.tenant_id = v_tenant;
    select count(*) filter (where i.kind = 'lead'), count(*) filter (where i.kind = 'ticket'), count(*) filter (where i.kind = 'task')
      into v_leads, v_tickets, v_tasks
    from cma.follow_up_item i where i.tenant_id = v_tenant;
    return jsonb_build_object('refreshed', true, 'computed', false, 'reason', 'unchanged', 'leads', v_leads, 'tickets', v_tickets,
                              'tasks', v_tasks, 'rows', v_leads + v_tickets + v_tasks, 'written', 0, 'unchanged', v_leads + v_tickets + v_tasks,
                              'duration_ms', floor(extract(epoch from clock_timestamp() - v_t0) * 1000)::integer, 'computed_at', now());
  end if;
  return cma.refresh_follow_up_of(v_tenant);
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Data quality: a failed computation backs off
-- ---------------------------------------------------------------------------------------------
-- As 0008zr's (132): a computation that failed waits data_quality.refresh_minutes before the next attempt
-- based on: 132_perf.sql
create or replace function cma.refresh_data_quality_of(p_tenant_id uuid, p_wait boolean default false)
returns jsonb
language plpgsql
as $$
declare
  v_t0   timestamptz := clock_timestamp();
  v_rows integer;
  v_ms   integer;
  v_age  interval;
  v_min  integer;
begin
  if p_tenant_id is null or p_tenant_id is distinct from cma.current_tenant_id() then
    raise exception 'the data-quality result is refreshed for the current tenant only' using errcode = 'CMA06';
  end if;
  if coalesce(p_wait, false) then
    perform pg_advisory_xact_lock(cma.data_quality_lock_key(p_tenant_id));
    if exists (select 1 from cma.data_quality_snapshot s where s.tenant_id = p_tenant_id) then
      return jsonb_build_object('refreshed', false, 'reason', 'present');
    end if;
  else
    v_min := cma.setting_of(p_tenant_id, 'data_quality.refresh_minutes')::integer;
    select now() - s.computed_at into v_age from cma.data_quality_snapshot s where s.tenant_id = p_tenant_id;
    if v_age is not null and v_age < make_interval(mins => v_min) then
      return jsonb_build_object('refreshed', false, 'reason', 'fresh', 'age_seconds', floor(extract(epoch from v_age))::integer);
    end if;
    -- 0009o: a computation that failed (the job's run row failed, no result stored since it started) is tried again only
    -- once data_quality.refresh_minutes have passed since that failure, not every minute (reason backoff). The runs of
    -- the last refresh_minutes and ten more are read from the tenant's newest (sync_run_tenant_started_idx)
    -- min() over the time index, a bounded range, never exists() (CLAUDE.md, Performance, N06)
    if (select min(r.started_at) from cma.sync_run r
        where r.tenant_id = p_tenant_id and r.connection_id is null and r.job = 'refresh_data_quality' and r.status = 'failed'
          and r.started_at > now() - make_interval(mins => v_min + 10)
          and r.finished_at > now() - make_interval(mins => v_min)
          and r.started_at > coalesce(now() - v_age, '-infinity'::timestamptz)) is not null then
      return jsonb_build_object('refreshed', false, 'reason', 'backoff');
    end if;
    if not pg_try_advisory_xact_lock(cma.data_quality_lock_key(p_tenant_id)) then
      return jsonb_build_object('refreshed', false, 'reason', 'running');
    end if;
  end if;

  delete from cma.data_quality_finding f where f.tenant_id = p_tenant_id;
  insert into cma.data_quality_finding (tenant_id, ord, check_key, connection_id, object_type, object_id, value, market, fix_in, fix_adapter)
  select p_tenant_id, x.ordinality, x.check_key, x.connection_id, x.object_type, x.object_id, x.value, x.market, x.fix_in, x.fix_adapter
  from cma.flash_findings_compute_of(p_tenant_id) with ordinality x;
  get diagnostics v_rows = row_count;
  v_ms := floor(extract(epoch from clock_timestamp() - v_t0) * 1000)::integer;
  insert into cma.data_quality_snapshot (tenant_id, computed_at, duration_ms, findings)
  values (p_tenant_id, now(), v_ms, v_rows)
  on conflict (tenant_id) do update set computed_at = excluded.computed_at, duration_ms = excluded.duration_ms, findings = excluded.findings;
  return jsonb_build_object('refreshed', true, 'rows', v_rows, 'duration_ms', v_ms);
end
$$;

-- The job entries' plans custom every call: their checks read sync_run and audit_log by a bound that only a custom plan
-- turns into the time index's range; a pooled connection's generic plan (after five calls) could read the whole table
alter function cma.refresh_follow_up() set plan_cache_mode = force_custom_plan;
alter function cma.refresh_data_quality_of(uuid, boolean) set plan_cache_mode = force_custom_plan;

-- ---------------------------------------------------------------------------------------------
-- 5. Grants, the addition
-- ---------------------------------------------------------------------------------------------
-- The application's only (a create or replace keeps a function's grants; said again for those re-created)
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.business_calendar_of(uuid)', 'cma.business_seconds_in(text,integer[],time[],time[],date[],timestamptz,timestamptz)',
    'cma.business_days_in(text,integer[],date[],timestamptz,timestamptz)', 'cma.next_business_noon_in(text,integer[],date[],timestamptz)',
    'cma.open_tickets_of(uuid)', 'cma.speed_to_lead_of(uuid,timestamptz,timestamptz)', 'cma.open_leads_of(uuid)', 'cma.data_quality_of(uuid)',
    'cma.flash_findings_compute_of(uuid)', 'cma.follow_up_item_print(integer,text,uuid,text,jsonb)', 'cma.follow_up_input_tables()',
    'cma.follow_up_next_change_of(uuid,timestamptz)', 'cma.refresh_follow_up_of(uuid,boolean)', 'cma.refresh_follow_up()',
    'cma.refresh_data_quality_of(uuid,boolean)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;
revoke execute on function cma.check_data_quality_setting() from public;

insert into cma.schema_migration (version, description)
values ('0009o', 'The minute jobs'' reads without per-row lookups (the prod CPU incident of 11 and 12 November 2026): cma.business_calendar_of and cma.business_seconds_in, cma.business_days_in, cma.next_business_noon_in (the _of functions'' answers from a calendar row read once per call); cma.open_tickets_of, cma.speed_to_lead_of, cma.open_leads_of, cma.data_quality_of and cma.flash_findings_compute_of read settings, market codes, statuses and office hours once per call, to the same answers; the follow-up refresh writes only the items that changed, and its job entry cma.refresh_follow_up() computes only when an input table changed in the audit log, a migration ran, a figure moves with the clock (cma.follow_up_next_change_of) or follow_up.recompute_minutes (60) passed, recorded in cma.follow_up_marker; a failed data-quality computation waits data_quality.refresh_minutes before the next attempt (reason backoff)')
on conflict (version) do nothing;

commit;
reset role;
