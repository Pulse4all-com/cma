-- =============================================================================================
-- 234_speed_to_lead_one.sql: addition 0009zq, speed to lead in one definition and one function (brief B40a)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics: pipelines, markets, office hours, holidays, the target, the
-- pre-window, the next-day cutoff and the attempts' source stay each tenant's catalogs and settings. Runs unchanged in
-- every database, after 232_intake_call_center.sql (0009zp; #317, which took 232/233 and 0009zp first, so this change
-- is 234/235 and 0009zq). Rerunnable, forward-only, in one transaction with a lock timeout.
-- Run as your own IAM login: dev first, then 235_verify_speed_to_lead_one.sql there (normal and provoked), then the
-- verifies that read what this re-creates, each still PASS: 41, 73, 95 and 179, edited by this change (41 and 73: their
-- tenant takes attempts.source crm, so their CRM-only calls stay the attempts, and 41 pins the new status, the agent
-- and the shares; 95: Attempts per deal reads cma.speed_to_lead_of, B8, B12 and B14 pin the one function's answers;
-- 179: where 0009zq has run E2 skips, E3 and E4 compare the columns 0009zq keeps, E7 and S5 take the cutoff form), and unchanged 75, 81, 93, 99, 101, 103,
-- 121, 151, 155, 191 (its clock-at-read copy of cma.speed_to_lead_of and cma.open_leads_of still matches), 14, 33 and 225
-- (every verify that reads cma.contact_store_orders_of, directly or through its callers, is among them);
-- then 131_time_all.sql part b (its Dashboard row reads the summary's total). 95, 73 and 81 run in dev only, as before.
-- Prod the same after the merge: 234, 235, the same reruns where they run in prod.
--
-- Why (Martin, 24 November 2026; Decision log, 24 Nov 2026; docs/definitions.md, Speed to lead; Gaps D10, D26, D27,
-- D28, D29, W28; audit finding MA-003): speed to lead was computed four ways (Sales → Speed to lead from the first
-- outbound CRM call, linked or not; the Dashboard tile in the web; Attempts per deal from its own first attempt; Follow-up
-- through the first of them), so the pages could differ. The decided definition ends at the first Attempt.
--
-- What it changes
--   speed_to_lead.next_day_cutoff   new setting (time, 'HH:MM', default '12:00'; Pulse4all keeps the default): the
--                      moment on the next working day of "% called before the cutoff the next working day" (D28). A bad
--                      value is refused by cma.check_tenant_setting's time rule (CMA04), unchanged here
--   cma.speed_to_lead_row           four columns appended (every existing name kept): first_attempt_call_id (the CRM
--                      call of the first Attempt, as cma.deal_attempts_of numbers it), first_attempt_at (its start, the
--                      telephony call's), attempts_so_far (the Attempts in the window, to its end so far) and
--                      deal_owner_user_id (the deal's CRM owner mapped to a person; never part of the measure)
--   cma.next_business_noon_in       (based on 178) takes the cutoff as its last argument; the four-argument form is
--                      dropped (its only caller was cma.speed_to_lead_of)
--   cma.next_business_noon_of       (based on 40) the cutoff from the setting, read once per call; 0007's
--                      cma.next_business_noon(market, at), which calls it, follows the setting too
--   cma.speed_to_lead_of            (based on 178) one row per lead deal as before, the same deals:
--                      end (D10)    the first Attempt of the deal or its contacts, read through cma.deal_attempts_of
--                                   under the tenant's attempts.source (telephony for Pulse4all: an outbound Aircall
--                                   call linked through the call link, on a counted line), from the creation minus
--                                   speed_to_lead.pre_window_minutes to the earliest of the deal's close and its
--                                   contacts' first order (an open deal without one: now), the window of Attempts per
--                                   deal (cma.sales_deals_of's window_end; Martin, 24 Nov 2026). An attempt in the
--                                   pre-window is 0 business seconds. A CRM call without a telephony call never ends it
--                                   under telephony. first_call_* stay the first outbound CRM call (linked or not):
--                                   deprecated, kept for this release only, removed in B40b (Martin, 24 Nov 2026);
--                                   first_any_* and first_connected_at the first call and the first connected call, as
--                                   before: shown, not measured
--                      status (D27) called; not_called_open; closed_before_first_call (was not_called_closed): a deal
--                                   closed, or whose contact ordered, before its first attempt. It has within_target, before_next_noon and
--                                   waiting_business_seconds null: out of both percentages and the median. An open deal
--                                   not called is late in within_target once past the target and in before_next_noon
--                                   once the cutoff passed, as before
--                      person (D26) agent_user_id is the first attempt's telephony user mapped to a person
--                                   (<telephony>_user, as cma.calls_people_of maps it); agent_ref that user's id and
--                                   agent_from 'call'. No fallback to the deal's owner: a deal without an attempt has no
--                                   agent. deal_owner_user_id carries the owner apart
--   cma.speed_to_lead_summary       (based on 40) now (p_from, p_to, p_group, p_market text default null); the
--                      three-argument form is dropped. p_group also 'total' (always one row: the Dashboard tile's
--                      read); p_market narrows every group to the deal's market; the agent grouping puts deals without
--                      an attempt under 'no_attempt' (no label) and an attempt by a telephony user without a person
--                      under 'unknown' as before; a new last column closed_before_first_call; p80 is kept (the API
--                      returns it)
--   cma.open_leads_of               (based on 178) the not_called_open rows as before; the owner columns from
--                      deal_owner_user_id and the deal's owner (they were the agent, which for a deal not called was
--                      the deal's owner)
--   cma.attempts_per_deal_of        (based on 100) speed_to_lead_seconds and called_before_next_noon are
--                      cma.speed_to_lead_of's business_seconds and before_next_noon of the same deal (D29); its own
--                      computation of both is gone. Both windows end alike, so both reads answer the same for every
--                      deal; the two columns follow now(), not p_now
--   cma.contact_store_orders_of     (based on 94) the same rows (235 V13 against 94's definition), each contact reference
--                      probing commerce_order_customer_idx with the connections of its system (Martin, 24 Nov 2026)
--   cma.follow_up_input_tables()    (based on 178) gains crm_contact_ref and integration_connection: the open leads'
--                      window reads the contacts' store references and the store connections of each system, so a
--                      change there wakes the follow-up job (integration_connection changes on configuration only,
--                      never per sync: the job's skip outside office hours keeps working)
--   cma_read.speed_to_lead          the view gains the four columns
--
-- Speed at three times prod's volume (web/verify/perf-volume-fixture.sql, local, PostgreSQL 16 with a uuidv7() shim,
-- the fixture's subscriptions tenant, Postgres held to one CPU (taskset on the postmaster), best of seven calls in a
-- session, the seventh as well; a relative measure: prod runs it again). Before 0009zq → this script:
--   With the order rule (the window ends at the contacts' first order, read from cma.sales_deals_of) and
--   cma.contact_store_orders_of probed per store connection (Martin, 24 Nov 2026; by a literal tenant id; two rounds):
--     cma.speed_to_lead_of over the previous month           327 → 625 / 665 ms
--     cma.speed_to_lead_of unbounded                          733 → 1,021 ms
--     cma.open_leads_of (the follow-up job, every minute)     636 → 1,054 / 1,063 ms
--     cma.attempts_rows_of over the previous month          2,719 → 2,028 / 2,230 ms
--     cma.lead_to_order_of unbounded                       45,227 → 1,669 ms (it reads cma.contact_store_orders_of too)
--   Martin's bar was an index on commerce_order (tenant_id, customer_source_id), measured and dropped: 599, 925, 992 and
--   2,127 ms, within 10 %. With 94's store-order lookup (each probe walked every store's part of
--   commerce_order_customer_idx) the order rule measured 1,773, 4,556, 3,604 and 6,783 ms; with a lateral per store
--   connection (a row per reference and connection before the deals' contacts narrowed them) 866, 1,254 and 2,875 ms;
--   with the connections of each system as one array (= any in the probe), as written here, the figures above.
--   Before the order rule (the window to the close; by a tenant subquery): cma.speed_to_lead_of over the previous month
--   322 → 317 ms, unbounded 634 → 591 ms, cma.open_leads_of 598 → 750 ms (1,482 open leads not called against 1,282: the
--   CRM calls without an Aircall call no longer end them), cma.attempts_rows_of 1,351 → 1,804 ms (it reads
--   cma.speed_to_lead_of over the same range, D29). A function argument holding a subquery kept cma.deal_attempts_of
--   from being inlined (711 ms), so the source and the cutoff are columns of d, and only the deals with a linked call
--   (telephony) or an outbound CRM call (crm) are read for attempts.
--   cma.speed_to_lead_summary(previous month, 'total'), the Dashboard tile's read, as the application (cma_app with
--   parameters), before the order rule: about 500 ms on the first call of a session and on the seventh alike.
--
-- No index. No lock on a busy table: a type, functions, a view and one setting row (a row lock on cma.setting) only.
-- SQLSTATEs as before; CMA04 for a group outside day, market, agent, pipeline and total.
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
  if not exists (select 1 from cma.schema_migration where version = '0009zp') then
    raise exception 'addition 0009zp (232_intake_call_center.sql) must run before 0009zq';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. The setting
-- ---------------------------------------------------------------------------------------------
insert into cma.setting (key, value_type, allowed_values, default_value, description) values
  ('speed_to_lead.next_day_cutoff', 'time', null, '12:00',
     'The local time on the next working day of the deal''s market before which a lead deal counts as called in "% before the cutoff the next working day" of speed to lead (HH:MM; addition 0009zq)')
on conflict (key) do update
  set value_type = excluded.value_type, allowed_values = excluded.allowed_values,
      default_value = excluded.default_value, description = excluded.description;

-- ---------------------------------------------------------------------------------------------
-- 2. The row type: four columns appended, every existing one kept
-- ---------------------------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_attribute a
                 where a.attrelid = (select t.typrelid from pg_type t where t.oid = to_regtype('cma.speed_to_lead_row'))
                   and a.attname = 'first_attempt_call_id' and not a.attisdropped) then
    alter type cma.speed_to_lead_row
      add attribute first_attempt_call_id uuid,
      add attribute first_attempt_at timestamptz,
      add attribute attempts_so_far integer,
      add attribute deal_owner_user_id uuid;
  end if;
end
$$;
comment on type cma.speed_to_lead_row is
  'One lead deal as cma.speed_to_lead_of gives it (0007d, 0009zq): status called, not_called_open or closed_before_first_call; the measure from the creation to the first Attempt (first_attempt_*, attempts_so_far), the first outbound CRM call, the first call and the first connected call shown beside it; the agent (the first attempt''s telephony user) and the deal''s owner apart';

-- ---------------------------------------------------------------------------------------------
-- 3. The next working day's cutoff
-- ---------------------------------------------------------------------------------------------
drop function if exists cma.next_business_noon_in(text, integer[], date[], timestamptz);

-- cma.next_business_noon_of on a market's calendar row: p_cutoff local on the first working day after p_at's local
-- date, within 31 days; null without a zone, an instant or a cutoff, or without such a day. Reads no table (0009o; the
-- cutoff an argument since 0009zq, read once per call by the caller)
-- based on: 178_job_reads.sql
create or replace function cma.next_business_noon_in(p_zone text, p_weekdays integer[], p_holidays date[], p_at timestamptz, p_cutoff time)
returns timestamptz
language plpgsql stable
as $$
declare
  v_base date;
  v_day  date;
begin
  if p_zone is null or p_at is null or p_cutoff is null then
    return null;
  end if;
  v_base := (p_at at time zone p_zone)::date;
  for i in 1 .. 31 loop
    v_day := v_base + i;
    if extract(isodow from v_day)::integer = any (p_weekdays) and not (v_day = any (coalesce(p_holidays, '{}'::date[]))) then
      return (v_day + p_cutoff) at time zone p_zone;
    end if;
  end loop;
  return null;
end
$$;

-- speed_to_lead.next_day_cutoff local on the first working day after p_at's local date, for an explicit tenant
-- (0007's cma.next_business_noon); null for an unknown market or without a working day within 31 days. The cutoff
-- is the setting, read once per call (0009zq; 12:00 before)
-- based on: 40_lead_metrics.sql
create or replace function cma.next_business_noon_of(p_tenant_id uuid, p_market text, p_at timestamptz)
returns timestamptz
language plpgsql stable
as $$
declare
  v_zone   text;
  v_sched  text;
  v_day    date;
  v_cutoff time;
begin
  if p_tenant_id is null or p_market is null or p_at is null then
    return null;
  end if;
  select m.time_zone into v_zone from cma.market m where m.tenant_id = p_tenant_id and m.code = p_market;
  if v_zone is null then
    return null;
  end if;
  v_cutoff := cma.setting_of(p_tenant_id, 'speed_to_lead.next_day_cutoff')::time;
  v_sched := case when exists (select 1 from cma.business_hours h where h.tenant_id = p_tenant_id and h.market = p_market)
                  then p_market else '*' end;
  for i in 1 .. 31 loop
    v_day := (p_at at time zone v_zone)::date + i;
    if exists (select 1 from cma.business_hours h
               where h.tenant_id = p_tenant_id and h.market = v_sched and h.weekday = extract(isodow from v_day))
       and not exists (select 1 from cma.business_holiday b
                       where b.tenant_id = p_tenant_id and b.market in (p_market, '*') and b.day = v_day) then
      return (v_day + v_cutoff) at time zone v_zone;
    end if;
  end loop;
  return null;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3b. The store orders of a contact, probed per store connection (Martin, 24 Nov 2026)
-- ---------------------------------------------------------------------------------------------
-- As 0008z's (94): the same signature, columns, rows and filters (not a test, not cancelled, not deleted). Each commerce
-- id of a contact (crm_contact_ref) now probes commerce_order_customer_idx (tenant_id, connection_id, customer_source_id)
-- with the connections whose adapter is the reference's system, the connections an order of that system can belong to
-- (an order's source_system is its connection's adapter: cma.active_connection_adapter at the order's write, 36 and
-- 56); without the connection the probe walked every store's part of the index (1.2 s of speed to lead's previous
-- month at three times prod's volume once its window reads cma.sales_deals_of). The connections of each system are one
-- array (= any in the probe), so a reference stays one row: a lateral per connection made a row per reference and
-- connection (210,000 at that volume) before the deals' contacts narrowed them, and measured 866 ms where this form
-- measures 652 ms (234's header). No kind or status filter, so every connection of the system counts, as the earlier
-- join did; source_system = r.system is kept
-- based on: 94_attempts_for_sales.sql
create or replace function cma.contact_store_orders_of(p_tenant_id uuid)
returns table (
  connection_id        uuid,
  contact_source_id    text,
  order_id             uuid,
  order_connection_id  uuid,
  order_source_id      text,
  created_at           timestamptz,
  order_kind           text,
  currency             text,
  total_amount         numeric
)
language sql stable
as $$
  -- the tenant's connections per adapter (the order's source system)
  with sys as (
    select sc.adapter, array_agg(sc.id) as ids
    from cma.integration_connection sc
    where sc.tenant_id = p_tenant_id
    group by sc.adapter
  )
  select k.connection_id, k.source_id, co.id, co.connection_id, co.source_id, co.source_created_at, co.order_kind, co.currency,
         co.total_amount
  from cma.crm_contact k
  join cma.crm_contact_ref r on r.tenant_id = k.tenant_id and r.contact_id = k.id
  join sys on sys.adapter = r.system
  join cma.commerce_order co
    on co.tenant_id = k.tenant_id and co.connection_id = any (sys.ids) and co.customer_source_id = r.external_id
   and co.source_system = r.system
  where k.tenant_id = p_tenant_id
    and not co.is_test and co.cancelled_at is null and co.source_deleted_at is null
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Speed to lead: one function
-- ---------------------------------------------------------------------------------------------
-- One row per lead deal created in [p_from, p_to) (null: unbounded), the same deals as before (cma.lead_deals_of).
-- The end is the first Attempt (cma.deal_attempts_of under attempts.source) from the creation minus the pre-window to
-- the earliest of the close and the contacts' first order (cma.sales_deals_of's window; open without one: now); the settings, the calendar and the cutoff once per call; each deal's calls, attempts, cutoff
-- moment and business seconds once (0009zq)
-- based on: 178_job_reads.sql
create or replace function cma.speed_to_lead_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns setof cma.speed_to_lead_row
language sql stable
as $$
  -- materialized, so the settings are read once per call (folded into the query, once per deal)
  with s as materialized (
    select greatest(0, cma.setting_of(p_tenant_id, 'speed_to_lead.pre_window_minutes')::integer) as pre_min,
           cma.setting_of(p_tenant_id, 'speed_to_lead.target_minutes')::integer * 60 as target_s,
           cma.setting_of(p_tenant_id, 'speed_to_lead.next_day_cutoff')::time as cutoff,
           cma.setting_of(p_tenant_id, 'attempts.source') as source
  ),
  -- each market's zone, office hours and holidays read once per call, not per deal
  cal as materialized (
    select * from cma.business_calendar_of(p_tenant_id)
  ),
  -- the window's end of each sales deal as Attempts per deal reads it (cma.sales_deals_of: the earliest of the close,
  -- the first order of the deal's contacts and now), so both give the same answer for every deal (Martin, 24 Nov 2026)
  w as materialized (
    select sd.deal_id, sd.window_end, sd.window_end_reason
    from cma.sales_deals_of(p_tenant_id, p_from, p_to, now()) sd
  ),
  d as materialized (
    -- the attempts' source and the cutoff as columns: a function argument holding a subquery stops the planner from
    -- inlining cma.deal_attempts_of, which then ran once per deal on its own plan (twice the time). A lead deal outside
    -- the sales deals (a pipeline that is both a lead and an order pipeline) ends at its close, else now
    select ld.*, ld.created_at - make_interval(mins => s.pre_min) as not_before,
           coalesce(w.window_end, case when ld.is_closed then coalesce(cr.closed_at, now()) else now() end) as until,
           coalesce(w.window_end_reason = 'ordered', false) as ordered,
           s.source as attempts_source, s.cutoff
    from cma.lead_deals_of(p_tenant_id, p_from, p_to) ld
    cross join s
    left join w on w.deal_id = ld.deal_id
    left join cma.crm_record cr on cr.tenant_id = p_tenant_id and cr.id = ld.deal_id
  ),
  -- every call of each deal from the window's start, read once: the first outbound CRM call, the first call and the
  -- first connected call, shown beside the measure as before
  c as materialized (
    select d.deal_id, lc.*
    from d
    cross join lateral cma.lead_calls_of(p_tenant_id, d.connection_id, d.record_type, d.source_id, d.contacts, d.not_before) lc
  ),
  fo as (select distinct on (c.deal_id) c.* from c where c.direction = 'outbound' order by c.deal_id, c.effective_at, c.call_id),
  fa as (select distinct on (c.deal_id) c.* from c order by c.deal_id, c.effective_at, c.call_id),
  fc as (select distinct on (c.deal_id) c.* from c where c.is_connected order by c.deal_id, c.effective_at, c.call_id),
  -- each deal's first Attempt in its window and the attempts so far: one lateral into cma.deal_attempts_of per deal,
  -- one aggregate row each (n numbers the attempts from 1, so the first is n = 1 and the count the highest n). Only for
  -- the deals that can have one: an attempt is one of the deal's calls in c (cma.deal_attempts_of reads
  -- cma.deal_calls_of from the same start, as cma.lead_calls_of does), under telephony a linked one, under crm an
  -- outbound one; the other deals have none and are not read again (a third of the deals at three times prod's volume)
  a as materialized (
    select d.deal_id, x.*
    from d
    cross join lateral (
      select (array_agg(z.call_id) filter (where z.n = 1))[1] as call_id,
             min(z.effective_at) filter (where z.n = 1) as effective_at,
             min(z.telephony_source_system) filter (where z.n = 1) as telephony_source_system,
             min(z.telephony_user_ref) filter (where z.n = 1) as telephony_user_ref,
             coalesce(max(z.n), 0)::integer as attempts
      from cma.deal_attempts_of(p_tenant_id, d.connection_id, d.record_type, d.source_id, d.contacts, d.not_before, d.until,
                                d.attempts_source) z
      where z.is_attempt) x
    where d.deal_id in (select c.deal_id from c
                        where case when (select s.source from s) = 'crm' then c.direction = 'outbound' else c.is_linked end)
  ),
  r as (
    select d.*, fo.call_id as fo_id, fo.call_source_id as fo_src, fo.effective_at as fo_at, fo.is_linked as fo_linked,
           fa.effective_at as fa_at, fa.direction as fa_dir, fc.effective_at as fc_at,
           a.call_id as at_id, a.effective_at as at_at, a.telephony_source_system as at_system, a.telephony_user_ref as at_user,
           coalesce(a.attempts, 0) as attempts,
           (select s.target_s from s) as target_s,
           nn.noon,
           bc.time_zone as cal_zone, bc.weekdays as cal_weekdays, bc.opens as cal_opens, bc.closes as cal_closes, bc.holidays as cal_holidays
    from d
    left join cal bc on bc.market = nullif(d.market, 'unknown')
    -- offset 0: the cutoff moment computed once per deal (pulled up, it ran once per reference), from the calendar's arrays
    left join lateral (select cma.next_business_noon_in(bc.time_zone, bc.weekdays, bc.holidays, d.created_at, d.cutoff) as noon
                       offset 0) nn on true
    left join fo on fo.deal_id = d.deal_id
    left join fa on fa.deal_id = d.deal_id
    left join fc on fc.deal_id = d.deal_id
    left join a on a.deal_id = d.deal_id
  ),
  m as (
    select r.*, bt.bs, bt.bs_now, xa.user_id as ag_user, xo.user_id as owner_user
    from r
    -- offset 0: each deal's business seconds computed once (pulled up, they ran once per reference), from the calendar's
    -- arrays; an attempt in the pre-window is 0 (cma.business_seconds_in of an end before the start)
    left join lateral (
      select case when r.at_at is not null
                  then cma.business_seconds_in(r.cal_zone, r.cal_weekdays, r.cal_opens, r.cal_closes, r.cal_holidays, r.created_at, r.at_at) end as bs,
             case when r.at_at is null and not r.is_closed and not r.ordered
                  then cma.business_seconds_in(r.cal_zone, r.cal_weekdays, r.cal_opens, r.cal_closes, r.cal_holidays, r.created_at, now()) end as bs_now
      offset 0) bt on true
    -- the agent: the first attempt's telephony user mapped to a person (as cma.calls_people_of maps a call's user)
    left join cma.app_user_external_id xa
      on xa.tenant_id = p_tenant_id and xa.system = r.at_system || '_user' and xa.external_id = r.at_user
    -- the deal's owner mapped to a person, apart from the measure
    left join cma.app_user_external_id xo
      on xo.tenant_id = p_tenant_id and xo.system = r.source_system || '_owner' and xo.external_id = r.owner_ref
  )
  select p_tenant_id, m.deal_id, m.connection_id, m.source_id, m.pipeline_id, m.pipeline_label, m.business_date,
         m.created_at, m.market, m.market_source, m.is_closed,
         case when m.at_at is not null then 'called'
              when m.is_closed or m.ordered then 'closed_before_first_call' else 'not_called_open' end,
         m.fo_id, m.fo_src, m.fo_at, m.fo_linked, m.fa_at, m.fa_dir,
         coalesce(m.fa_dir = 'inbound', false), m.fc_at,
         m.ag_user, m.at_user, case when m.at_user is not null then 'call' end,
         case when m.at_at is not null then greatest(0, floor(extract(epoch from m.at_at - m.created_at)))::integer end,
         m.bs, m.target_s,
         case when m.bs is not null then m.bs <= m.target_s
              when m.bs_now > m.target_s then false end,
         m.noon,
         case when m.at_at is not null and m.noon is not null then m.at_at < m.noon
              when m.at_at is null and not m.is_closed and not m.ordered and m.noon is not null and now() >= m.noon then false end,
         m.bs_now,
         m.at_id, m.at_at, m.attempts, m.owner_user
  from m
$$;

drop function if exists cma.speed_to_lead_summary(date, date, text);

-- Grouped by day (business date), market, agent (the first attempt's person; a telephony user without a person under
-- 'unknown', a deal without an attempt under 'no_attempt'), pipeline, or 'total' (always one row: the Dashboard's
-- tile), the deals narrowed to p_market when given. Business minutes over the called deals; the percentages over the
-- deals whose outcome is known (a deal closed before its first call never is); the open deals not called and the deals
-- closed before the first call counted apart (0009zq)
-- based on: 40_lead_metrics.sql
create or replace function cma.speed_to_lead_summary(p_from date, p_to date, p_group text, p_market text default null)
returns table (
  group_key                 text,
  group_label               text,
  deals                     integer,
  called                    integer,
  median_business_minutes   numeric,
  p80_business_minutes      numeric,
  within_target_pct         numeric,
  before_next_noon_pct      numeric,
  open_not_called           integer,
  closed_before_first_call  integer
)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_tenant uuid := cma.current_tenant_id();
  v_range  record;
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  if p_group is null or p_group not in ('day', 'market', 'agent', 'pipeline', 'total') then
    raise exception 'group by day, market, agent, pipeline or total, not %', p_group using errcode = 'CMA04';
  end if;
  select * into v_range from cma.report_range(v_tenant, p_from, p_to);
  if p_group = 'total' then
    -- no grouping: one row also when there is no deal
    return query
      select 'total'::text, null::text, count(*)::integer, (count(*) filter (where r.status = 'called'))::integer,
             round((percentile_cont(0.5) within group (order by r.business_seconds))::numeric / 60, 1),
             round((percentile_cont(0.8) within group (order by r.business_seconds))::numeric / 60, 1),
             round(100.0 * count(*) filter (where r.within_target) / nullif(count(r.within_target), 0), 1),
             round(100.0 * count(*) filter (where r.before_next_noon) / nullif(count(r.before_next_noon), 0), 1),
             (count(*) filter (where r.status = 'not_called_open'))::integer,
             (count(*) filter (where r.status = 'closed_before_first_call'))::integer
      from cma.speed_to_lead_of(v_tenant, v_range.from_at, v_range.to_at) r
      where p_market is null or r.market = p_market;
    return;
  end if;
  return query
    select g.k, g.l, count(*)::integer, (count(*) filter (where r.status = 'called'))::integer,
           round((percentile_cont(0.5) within group (order by r.business_seconds))::numeric / 60, 1),
           round((percentile_cont(0.8) within group (order by r.business_seconds))::numeric / 60, 1),
           round(100.0 * count(*) filter (where r.within_target) / nullif(count(r.within_target), 0), 1),
           round(100.0 * count(*) filter (where r.before_next_noon) / nullif(count(r.before_next_noon), 0), 1),
           (count(*) filter (where r.status = 'not_called_open'))::integer,
           (count(*) filter (where r.status = 'closed_before_first_call'))::integer
    from cma.speed_to_lead_of(v_tenant, v_range.from_at, v_range.to_at) r
    left join cma.app_user u on u.tenant_id = v_tenant and u.id = r.agent_user_id
    cross join lateral (
      select case p_group when 'day' then r.business_date::text
                          when 'market' then r.market
                          when 'agent' then case when r.first_attempt_at is null then 'no_attempt'
                                                 else coalesce(r.agent_user_id::text, 'unknown') end
                          else r.connection_id::text || ':' || coalesce(r.pipeline_id, '') end as k,
             case p_group when 'day' then r.business_date::text
                          when 'market' then r.market
                          when 'agent' then case when r.first_attempt_at is null then null
                                                 else coalesce(u.display_name, 'unknown') end
                          else coalesce(r.pipeline_label, 'unknown') end as l) g
    where p_market is null or r.market = p_market
    group by g.k, g.l
    order by g.k;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 5. The readers of the one function
-- ---------------------------------------------------------------------------------------------
-- As 0009o's (178): the not_called_open rows of cma.speed_to_lead_of (since 0009zq the deals without an Attempt, so
-- more than before where CRM calls had no Aircall call), the same columns and order; the owner is the deal's owner (deal_owner_user_id and its CRM
-- reference), which is what the agent was for a deal not called until 0009zq
-- based on: 178_job_reads.sql
create or replace function cma.open_leads_of(p_tenant_id uuid)
returns setof cma.open_lead_row
language sql stable
as $$
  -- materialized, so the two settings are read once per call (folded into the query, once per lead)
  with s as materialized (
    select cma.setting_of(p_tenant_id, 'leads.age_buckets_business_days') as edges,
           greatest(0, cma.setting_of(p_tenant_id, 'speed_to_lead.pre_window_minutes')::integer) as pre_min
  ),
  -- each market's zone, office hours and holidays read once per call, not per lead
  cal as materialized (
    select * from cma.business_calendar_of(p_tenant_id)
  ),
  r as (
    select * from cma.speed_to_lead_of(p_tenant_id, null, null) x where x.status = 'not_called_open'
  )
  select p_tenant_id, r.deal_id, r.connection_id, r.deal_source_id, r.pipeline_id, r.pipeline_label,
         r.deal_owner_user_id, d.owner_ref, r.market, r.created_at, r.waiting_business_seconds,
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

-- As 0008zc's (100), with the speed to lead of cma.speed_to_lead_of (0009zq, D29): one row per sales deal created in
-- [p_from, p_to) (null: unbounded), as of p_now (now() for the application; a verifier gives a fixed instant). Each
-- deal's calls are read once (cma.deal_attempts_of); speed_to_lead_seconds and called_before_next_noon are the same
-- deal's business_seconds and before_next_noon in cma.speed_to_lead_of over the same creation range (the sales deals
-- are lead deals, and both windows end at the earliest of the close, the first order and now; their clock is now(), not
-- p_now, so a verifier's fixed instant does not govern these two columns); an open deal's business days since its last
-- attempt are cma.business_days_of's
-- once per market and local date counted from, and the bucket cma.age_bucket_of's once per number of days (as 0008y);
-- the link through cma.record_url; the owner through the linked account <source>_owner
-- based on: 100_definitions_calls.sql
create or replace function cma.attempts_per_deal_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz,
                                                    p_now timestamptz default now())
returns setof cma.attempt_deal
language sql stable
as $$
  with s as materialized (
    select t.timezone as zone,
           greatest(0, cma.setting_of(t.id, 'speed_to_lead.pre_window_minutes')::integer) as pre_min,
           cma.setting_of(t.id, 'attempts.since_last_buckets_business_days') as edges,
           cma.setting_of(t.id, 'attempts.source') as source
    from cma.tenant t where t.id = p_tenant_id
  ),
  d as materialized (
    select * from cma.sales_deals_of(p_tenant_id, p_from, p_to, p_now)
  ),
  -- the speed to lead of every lead deal of the range, from the one function (0009zq)
  sl as materialized (
    select x.deal_id, x.business_seconds, x.before_next_noon
    from cma.speed_to_lead_of(p_tenant_id, p_from, p_to) x
  ),
  r as materialized (
    select d.*, a.*, xo.user_id as owner_user_id,
           -- the local date the business days of an open deal with business hours count from
           case when d.outcome = 'open' and d.market_zone is not null
                then (coalesce(a.last_at, d.created_at) at time zone d.market_zone)::date end as since_day
    from d
    cross join s
    -- the deal's calls, read once: its attempts in the window and the outbound calls logged without a telephony call
    cross join lateral (
      select (count(*) filter (where z.is_attempt))::integer as attempts,
             (count(*) filter (where z.is_attempt and z.conversation))::integer as conversations,
             (min(z.n) filter (where z.is_attempt and z.conversation))::integer as first_conversation,
             coalesce(sum(z.talk_seconds) filter (where z.is_attempt), 0)::integer as talk_total,
             coalesce(sum(z.talk_seconds) filter (where z.is_attempt and z.conversation), 0)::integer as talk_conversation,
             min(z.effective_at) filter (where z.is_attempt) as first_at,
             max(z.effective_at) filter (where z.is_attempt) as last_at,
             (count(*) filter (where z.is_attempt and not z.has_outcome))::integer as no_outcome,
             (count(*) filter (where z.without_aircall))::integer as without_aircall
      from cma.deal_attempts_of(p_tenant_id, d.connection_id, d.record_type, d.source_id, d.contacts,
                                d.created_at - make_interval(mins => s.pre_min), d.window_end, s.source) z) a
    left join cma.app_user_external_id xo
      on xo.tenant_id = p_tenant_id and xo.system = d.source_system || '_owner' and xo.external_id = d.owner_ref
  ),
  -- the business days from each market and local date to p_now (noon of the date stands for it)
  bd as materialized (
    select x.market, x.since_day,
           cma.business_days_of(p_tenant_id, x.market, (x.since_day + time '12:00') at time zone x.market_zone, p_now) as days
    from (select distinct r.market, r.market_zone, r.since_day from r where r.since_day is not null) x
  ),
  -- the bucket of each number of days
  bk as materialized (
    select x.days, b.bucket_from, b.bucket_to
    from (select distinct bd.days from bd where bd.days is not null) x
    cross join s
    cross join lateral cma.age_bucket_of(x.days, s.edges) b
  )
  select p_tenant_id, r.deal_id, r.connection_id, r.source_system, r.source_id,
         cma.record_url(r.connection_id, r.record_type, r.source_id),
         r.pipeline_id, r.pipeline_label, r.stage_id, r.stage_label, r.market, r.owner_ref, r.owner_user_id,
         r.created_at, r.business_date, date_trunc('week', r.business_date)::date, (r.created_at at time zone s.zone)::time,
         r.is_closed, r.closed_at, r.ordered_at, r.window_end_reason, r.outcome,
         r.attempts, r.conversations, r.first_conversation, r.talk_total, r.talk_conversation, r.first_at,
         -- the one function's answers: its window ends where this row's does (the close, the first order or now)
         sl.business_seconds, sl.before_next_noon,
         r.last_at, bd.days, bk.bucket_from, bk.bucket_to,
         case when bk.bucket_from is not null
              then case when bk.bucket_to is null then bk.bucket_from || '+' else bk.bucket_from || '–' || bk.bucket_to end end,
         r.no_outcome, r.without_aircall
  from r
  cross join s
  left join sl on sl.deal_id = r.deal_id
  left join bd on bd.market = r.market and bd.since_day = r.since_day
  left join bk on bk.days = bd.days
$$;

-- As 0009o's (178), with crm_contact_ref and integration_connection: since 0009zq cma.open_leads_of reads
-- cma.speed_to_lead_of, whose window reads cma.sales_deals_of and so the contacts' store references and the store
-- connections of each system (cma.contact_store_orders_of); a reference or a connection added or removed can move a
-- lead's window, so their audit rows must wake the follow-up job (179's S6 derives the list from the bodies).
-- integration_connection changes on configuration only (status, kind, settings: the set_connection_* functions), never
-- per sync, so the job's skip outside office hours keeps working
-- based on: 178_job_reads.sql
create or replace function cma.follow_up_input_tables()
returns text[]
language sql immutable
as $$
  select array['app_user_external_id', 'business_holiday', 'business_hours', 'call_link', 'commerce_customer', 'commerce_order',
               'commerce_store', 'connection_call_outcome', 'connection_pipeline', 'connection_stage', 'connection_task_status',
               'connection_task_type', 'crm_association', 'crm_call', 'crm_contact', 'crm_contact_ref', 'crm_record', 'crm_task',
               'integration_connection', 'market', 'market_alias', 'telephony_call', 'telephony_call_tag', 'telephony_number', 'telephony_tag', 'tenant_setting']
$$;

-- The readers' view: the row type's columns, the four new ones last (cma_read.speed_to_lead_rows() is a SQL function
-- whose r.* follows the type at each call; the view's column list is fixed when it is made, so it is made again)
create or replace view cma_read.speed_to_lead as
  select * from cma_read.speed_to_lead_rows();

-- ---------------------------------------------------------------------------------------------
-- 6. Grants: the application only, as 0007d's (40)
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.speed_to_lead_summary(date,date,text,text)',
    'cma.speed_to_lead_of(uuid,timestamptz,timestamptz)',
    'cma.next_business_noon_of(uuid,text,timestamptz)',
    'cma.next_business_noon_in(text,integer[],date[],timestamptz,time)',
    'cma.open_leads_of(uuid)',
    'cma.attempts_per_deal_of(uuid,timestamptz,timestamptz,timestamptz)',
    'cma.follow_up_input_tables()',
    'cma.contact_store_orders_of(uuid)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. Record the migration
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0009zq', 'Speed to lead in one function (Martin, 24 Nov 2026; brief B40a; D10, D26 to D29, W28, MA-003): cma.speed_to_lead_of ends at the first Attempt (cma.deal_attempts_of under attempts.source, from the creation minus the pre-window to the earliest of the close and the contacts'' first order, as Attempts per deal''s window; a pre-window attempt is 0), status closed_before_first_call in place of not_called_closed (closed or ordered before the first attempt; out of both percentages and the median), the agent the first attempt''s telephony user (no owner fallback), the row type gains first_attempt_call_id, first_attempt_at, attempts_so_far and deal_owner_user_id; setting speed_to_lead.next_day_cutoff (time, 12:00) in cma.next_business_noon_in (cutoff argument) and _of; cma.speed_to_lead_summary takes p_market and the group total, groups deals without an attempt under no_attempt and adds closed_before_first_call; cma.open_leads_of owns by the deal''s owner; cma.attempts_per_deal_of reads its speed to lead from cma.speed_to_lead_of; cma_read.speed_to_lead gains the four columns')
on conflict (version) do nothing;

commit;
reset role;
