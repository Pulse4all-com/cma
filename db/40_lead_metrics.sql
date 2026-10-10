-- =============================================================================================
-- 40_lead_metrics.sql: migration 0007d, lead metrics and data quality (intake track I5)
-- =============================================================================================
-- Universal: no customer, tenant or vendor specifics. Runs unchanged in every database, after
-- 32_intake_core.sql (0007), 34_telephony.sql (0007a) and 36_commerce.sql (0007b). Rerunnable,
-- forward-only. Run as your own IAM login, dev first, then prod; then 41_verify_lead_metrics.sql,
-- then 37, 35, 33 and 31 again (unchanged).
--
-- Specification: docs/night-2026-10-10/DESIGN.md §4.4 (README KPIs section 1, Decision log
-- 10 October 2026).
--
-- What it adds
--   speed to lead      cma.speed_to_lead_rows(): one row per lead deal (counted lead pipeline, not
--                      deleted, created on or after intake.start_date) with its first outbound call
--                      on the deal or one of its contacts, the effective start (the linked telephony
--                      call's start, else the CRM call's time), elapsed and business seconds in the
--                      deal's market, within target, before the next business noon, the first call
--                      of any direction, the first connected call, whether an inbound call came
--                      first, and the agent; cma.speed_to_lead_summary() groups it by day, market,
--                      agent or pipeline
--   lead to order      cma.lead_to_order_rows(): per lead deal, the first non-test, non-cancelled
--                      order of a commerce customer whose id one of the deal's contacts holds,
--                      created after the deal within lead_to_order.max_days
--   intake per day     cma.intake_per_day(): per business date and market, form submissions, deals
--                      and tickets created and closed, calls in and out, tagged calls, new commerce
--                      customers, first and repeat orders and renewals
--   data quality       cma.data_quality(): the count of every check (DESIGN §4.4) for the Data page
--   reporting views    cma_read.speed_to_lead, lead_to_order, intake_per_day_v and one dq_* view per
--                      check, ids only, for every tenant the reader sees
--
-- The market of a deal (decision of 10 October 2026): the deal's own mapped market property first,
-- then its primary contact's country, each through the tenant's market aliases (read again here,
-- so an alias added later applies to older rows) and only when the result is a catalog market;
-- 'unknown' when neither is.
--
-- How the rows are made once: each read is a function of an explicit tenant (cma.*_of). The
-- application's functions call it for the current tenant, under row-level security, after the
-- permission check. A reporting reader cannot run a function that reads schema cma, so each
-- reporting view reads a SECURITY DEFINER function in cma_read, owned by cma_owner with a pinned
-- search path, that calls the same function for every tenant cma_read.reader_sees() lets the
-- reader see. Readers may execute those four functions and nothing else here; the application
-- may not execute them.
--
-- SQLSTATEs as before: CMA01 no acting user, CMA02 not found, CMA03 conflict, CMA04 invalid,
-- CMA06 not permitted.
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
set role cma_owner;

do $$
begin
  if not exists (select 1 from cma.schema_migration where version = '0007a') then
    raise exception 'migration 0007a (34_telephony.sql) must run before 0007d';
  end if;
  if not exists (select 1 from cma.schema_migration where version = '0007b') then
    raise exception 'migration 0007b (36_commerce.sql) must run before 0007d';
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 1. Helpers for an explicit tenant
-- ---------------------------------------------------------------------------------------------
-- A setting's effective value for a tenant: its own value, else the catalog default
create or replace function cma.setting_of(p_tenant_id uuid, p_key text)
returns text
language sql stable
as $$
  select coalesce(ts.value, s.default_value)
  from cma.setting s
  left join cma.tenant_setting ts on ts.tenant_id = p_tenant_id and ts.key = s.key
  where s.key = p_key
$$;

-- The catalog market a source value stands for (an alias, else the code itself), or null when the
-- value is empty or names no market of the tenant's catalog
create or replace function cma.market_code_of(p_tenant_id uuid, p_value text)
returns text
language sql stable
as $$
  select m.code
  from cma.market m
  where m.tenant_id = p_tenant_id
    and nullif(btrim(p_value), '') is not null
    and m.code = coalesce((select a.code from cma.market_alias a
                           where a.tenant_id = p_tenant_id and a.alias = lower(btrim(p_value))),
                          upper(btrim(p_value)))
$$;

-- A record's market: its own market, else its contact's country (the contact of the same
-- connection), each only when it is a catalog market; 'unknown' otherwise. source says which.
create or replace function cma.record_market_of(p_tenant_id uuid, p_connection_id uuid, p_market text,
                                                p_contact_source_id text, out code text, out source text)
language sql stable
as $$
  with v as (
    select cma.market_code_of(p_tenant_id, p_market) as own,
           (select cma.market_code_of(p_tenant_id, cc.country)
            from cma.crm_contact cc
            where cc.tenant_id = p_tenant_id and cc.connection_id = p_connection_id
              and cc.source_id = p_contact_source_id) as contact
  )
  select coalesce(v.own, v.contact, 'unknown'),
         case when v.own is not null then 'record' when v.contact is not null then 'contact' end
  from v
$$;

-- Office seconds between two instants in a tenant's market (0007's cma.business_seconds, for an
-- explicit tenant): the market's own hours, else '*', holidays of the market and of '*' excluded,
-- each day placed in the zone separately; 0 when p_to <= p_from; null for an unknown market.
create or replace function cma.business_seconds_of(p_tenant_id uuid, p_market text, p_from timestamptz, p_to timestamptz)
returns integer
language plpgsql stable
as $$
declare
  v_zone   text;
  v_sched  text;
begin
  if p_tenant_id is null or p_market is null or p_from is null or p_to is null then
    return null;
  end if;
  select m.time_zone into v_zone from cma.market m where m.tenant_id = p_tenant_id and m.code = p_market;
  if v_zone is null then
    return null;
  end if;
  if p_to <= p_from then
    return 0;
  end if;
  v_sched := case when exists (select 1 from cma.business_hours h where h.tenant_id = p_tenant_id and h.market = p_market)
                  then p_market else '*' end;
  return (
    select coalesce(sum(greatest(0, extract(epoch from least(w.closes, p_to) - greatest(w.opens, p_from)))), 0)::integer
    from (
      select (d.day + h.opens_at) at time zone v_zone as opens,
             (d.day + h.closes_at) at time zone v_zone as closes
      from generate_series((p_from at time zone v_zone)::date, (p_to at time zone v_zone)::date, interval '1 day') g(ts)
      cross join lateral (select g.ts::date as day) d
      join cma.business_hours h
        on h.tenant_id = p_tenant_id and h.market = v_sched and h.weekday = extract(isodow from d.day)
      where not exists (select 1 from cma.business_holiday b
                        where b.tenant_id = p_tenant_id and b.market in (p_market, '*') and b.day = d.day)
    ) w
  );
end
$$;

-- 12:00 local on the first working day after p_at's local date, for an explicit tenant (0007's
-- cma.next_business_noon); null for an unknown market or without a working day within 31 days
create or replace function cma.next_business_noon_of(p_tenant_id uuid, p_market text, p_at timestamptz)
returns timestamptz
language plpgsql stable
as $$
declare
  v_zone   text;
  v_sched  text;
  v_day    date;
begin
  if p_tenant_id is null or p_market is null or p_at is null then
    return null;
  end if;
  select m.time_zone into v_zone from cma.market m where m.tenant_id = p_tenant_id and m.code = p_market;
  if v_zone is null then
    return null;
  end if;
  v_sched := case when exists (select 1 from cma.business_hours h where h.tenant_id = p_tenant_id and h.market = p_market)
                  then p_market else '*' end;
  for i in 1 .. 31 loop
    v_day := (p_at at time zone v_zone)::date + i;
    if exists (select 1 from cma.business_hours h
               where h.tenant_id = p_tenant_id and h.market = v_sched and h.weekday = extract(isodow from v_day))
       and not exists (select 1 from cma.business_holiday b
                       where b.tenant_id = p_tenant_id and b.market in (p_market, '*') and b.day = v_day) then
      return (v_day + time '12:00') at time zone v_zone;
    end if;
  end loop;
  return null;
end
$$;

-- 0007's two functions keep their signatures, grants and behaviour, and now share the code above
create or replace function cma.business_seconds(p_market text, p_from timestamptz, p_to timestamptz)
returns integer
language sql stable
as $$
  select cma.business_seconds_of(cma.current_tenant_id(), p_market, p_from, p_to)
$$;

create or replace function cma.next_business_noon(p_market text, p_at timestamptz)
returns timestamptz
language sql stable
as $$
  select cma.next_business_noon_of(cma.current_tenant_id(), p_market, p_at)
$$;

-- A business-date range (the tenant's zone) as instants; at most 92 days, forward
create or replace function cma.report_range(p_tenant_id uuid, p_from date, p_to date, out from_at timestamptz, out to_at timestamptz)
language plpgsql stable
as $$
declare
  v_zone text;
begin
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 91 then
    raise exception 'the range must run forward and cover at most 92 days' using errcode = 'CMA04';
  end if;
  select t.timezone into v_zone from cma.tenant t where t.id = p_tenant_id;
  from_at := p_from::timestamp at time zone v_zone;
  to_at   := (p_to + 1)::timestamp at time zone v_zone;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 2. Row types of the three reads (the functions for the application and for readers share them)
-- ---------------------------------------------------------------------------------------------
do $$
begin
  if to_regtype('cma.speed_to_lead_row') is null then
    create type cma.speed_to_lead_row as (
      tenant_id                 uuid,
      deal_id                   uuid,
      connection_id             uuid,
      deal_source_id            text,
      pipeline_id               text,
      pipeline_label            text,
      business_date             date,
      created_at                timestamptz,
      market                    text,
      market_source             text,
      is_closed                 boolean,
      status                    text,
      first_call_id             uuid,
      first_call_source_id      text,
      first_call_at             timestamptz,
      first_call_linked         boolean,
      first_any_call_at         timestamptz,
      first_any_direction       text,
      inbound_first             boolean,
      first_connected_at        timestamptz,
      agent_user_id             uuid,
      agent_ref                 text,
      agent_from                text,
      elapsed_seconds           integer,
      business_seconds          integer,
      target_seconds            integer,
      within_target             boolean,
      next_business_noon        timestamptz,
      before_next_noon          boolean,
      waiting_business_seconds  integer
    );
  end if;
  if to_regtype('cma.lead_to_order_row') is null then
    create type cma.lead_to_order_row as (
      tenant_id            uuid,
      deal_id              uuid,
      connection_id        uuid,
      deal_source_id       text,
      pipeline_id          text,
      pipeline_label       text,
      business_date        date,
      created_at           timestamptz,
      market               text,
      customers_linked     integer,
      order_id             uuid,
      order_connection_id  uuid,
      order_source_id      text,
      store_handle         text,
      order_created_at     timestamptz,
      order_kind           text,
      order_currency       text,
      order_total          numeric,
      days_to_order        numeric
    );
  end if;
  if to_regtype('cma.intake_per_day_row') is null then
    create type cma.intake_per_day_row as (
      tenant_id         uuid,
      business_date     date,
      market            text,
      form_submissions  integer,
      deals_created     integer,
      deals_closed      integer,
      tickets_created   integer,
      tickets_closed    integer,
      calls_in          integer,
      calls_out         integer,
      tagged_calls      integer,
      new_customers     integer,
      first_orders      integer,
      repeat_orders     integer,
      renewals          integer
    );
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 3. The lead population
-- ---------------------------------------------------------------------------------------------
-- Deals of counted lead pipelines (a pipeline not yet seen counts and is a lead pipeline), not
-- deleted, created on or after intake.start_date (the tenant's zone) and within [p_from, p_to)
-- when given; with the pipeline label, the business date, the market and the deal's contacts
-- (the primary contact and the contacts currently associated with the deal).
create or replace function cma.lead_deals_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns table (
  deal_id            uuid,
  connection_id      uuid,
  source_system      text,
  record_type        text,
  source_id          text,
  pipeline_id        text,
  pipeline_label     text,
  owner_ref          text,
  contact_source_id  text,
  is_closed          boolean,
  created_at         timestamptz,
  business_date      date,
  market             text,
  market_source      text,
  contacts           text[]
)
language sql stable
as $$
  with s as (
    select t.timezone as zone, cma.setting_of(t.id, 'intake.start_date')::date as start_date
    from cma.tenant t where t.id = p_tenant_id
  )
  select d.id, d.connection_id, d.source_system, d.record_type, d.source_id, d.pipeline_id,
         coalesce(p.label, d.pipeline_id), d.owner_ref, d.contact_source_id, coalesce(d.is_closed, false),
         d.source_created_at, (d.source_created_at at time zone s.zone)::date, rm.code, rm.source,
         array(select x from (select d.contact_source_id as x where d.contact_source_id is not null
                              union
                              select a.to_id from cma.crm_association a
                              where a.tenant_id = d.tenant_id and a.connection_id = d.connection_id
                                and a.from_type = d.record_type and a.from_id = d.source_id
                                and a.to_type = 'contact' and a.removed_at is null) c
               order by x)
  from cma.crm_record d
  cross join s
  left join cma.connection_pipeline p
    on p.tenant_id = d.tenant_id and p.connection_id = d.connection_id
   and p.record_type = d.record_type and p.source_pipeline_id = d.pipeline_id
  cross join lateral cma.record_market_of(d.tenant_id, d.connection_id, d.market, d.contact_source_id) rm
  where d.tenant_id = p_tenant_id
    and d.record_type = 'deal'
    and d.source_deleted_at is null
    and coalesce(p.is_counted, true) and coalesce(p.is_lead, true)
    and d.source_created_at >= (s.start_date::timestamp at time zone s.zone)
    and (p_from is null or d.source_created_at >= p_from)
    and (p_to is null or d.source_created_at < p_to)
$$;

-- ---------------------------------------------------------------------------------------------
-- 4. Speed to lead (DESIGN §4.4)
-- ---------------------------------------------------------------------------------------------
-- Calls of a deal: CRM calls of the deal's connection, not deleted, currently associated with the
-- deal or one of its contacts, whose effective start (the linked telephony call's start while the
-- link is current and the telephony call not deleted, else the CRM call's time) is at or after the
-- deal's creation minus speed_to_lead.pre_window_minutes. Connected: the outcome counts as
-- connected, or the linked telephony call was answered.
create or replace function cma.lead_calls_of(p_tenant_id uuid, p_connection_id uuid, p_record_type text,
                                             p_source_id text, p_contacts text[], p_not_before timestamptz)
returns table (
  call_id         uuid,
  call_source_id  text,
  source_system   text,
  direction       text,
  owner_ref       text,
  effective_at    timestamptz,
  is_linked       boolean,
  is_connected    boolean
)
language sql stable
as $$
  select c.id, c.source_id, c.source_system, c.direction, c.owner_ref,
         coalesce(tc.started_at, c.occurred_at), tc.started_at is not null,
         coalesce(o.is_connected, false) or tc.answered_at is not null
  from cma.crm_call c
  left join cma.call_link l
    on l.tenant_id = c.tenant_id and l.crm_call_id = c.id and l.unlinked_at is null
  left join cma.telephony_call tc
    on tc.tenant_id = l.tenant_id and tc.id = l.telephony_call_id and tc.source_deleted_at is null
  left join cma.connection_call_outcome o
    on o.tenant_id = c.tenant_id and o.connection_id = c.connection_id and o.outcome_ref = c.outcome_ref
  where c.tenant_id = p_tenant_id
    and c.connection_id = p_connection_id
    and c.source_deleted_at is null
    and coalesce(tc.started_at, c.occurred_at) >= p_not_before
    and exists (select 1 from cma.crm_association a
                where a.tenant_id = c.tenant_id and a.connection_id = c.connection_id
                  and a.from_type = 'crm_call' and a.from_id = c.source_id and a.removed_at is null
                  and ((a.to_type = p_record_type and a.to_id = p_source_id)
                       or (a.to_type = 'contact' and a.to_id = any (p_contacts))))
$$;

-- One row per lead deal created in [p_from, p_to) (null: unbounded). status: called (an outbound
-- call), not_called_open, not_called_closed. Measures run from the deal's creation to the first
-- outbound call's effective start; a call in the pre-window counts as 0. Business time needs a
-- catalog market: with market 'unknown' the business measures are null. within_target and
-- before_next_noon are null while a deal is not called and could still make it, false once it
-- cannot. The agent is the first outbound call's owner mapped through app_user_external_id
-- (system '<the call's source system>_owner'), else the deal's owner the same way.
create or replace function cma.speed_to_lead_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns setof cma.speed_to_lead_row
language sql stable
as $$
  with s as (
    select greatest(0, cma.setting_of(p_tenant_id, 'speed_to_lead.pre_window_minutes')::integer) as pre_min,
           cma.setting_of(p_tenant_id, 'speed_to_lead.target_minutes')::integer * 60 as target_s
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
           cma.next_business_noon_of(p_tenant_id, nullif(d.market, 'unknown'), d.created_at) as noon
    from d
    cross join s
    left join fo on fo.deal_id = d.deal_id
    left join fa on fa.deal_id = d.deal_id
    left join fc on fc.deal_id = d.deal_id
  ),
  m as (
    select r.*,
           case when r.fo_at is not null
                then cma.business_seconds_of(p_tenant_id, nullif(r.market, 'unknown'), r.created_at, r.fo_at) end as bs,
           case when r.fo_at is null
                then cma.business_seconds_of(p_tenant_id, nullif(r.market, 'unknown'), r.created_at, now()) end as bs_now,
           ag.user_id as ag_user, ag.ref as ag_ref, ag.src as ag_from
    from r
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

-- ---------------------------------------------------------------------------------------------
-- 5. Lead to order
-- ---------------------------------------------------------------------------------------------
-- Per lead deal: the commerce customers its contacts point to (crm_contact_ref, any slot, the
-- ref system equal to the order's source system) and the first of their orders that is not a test,
-- not cancelled and not deleted, created at or after the deal and within lead_to_order.max_days.
create or replace function cma.lead_to_order_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns setof cma.lead_to_order_row
language sql stable
as $$
  with s as (
    select cma.setting_of(p_tenant_id, 'lead_to_order.max_days')::integer as max_days
  ),
  refs as (
    select d.deal_id, r.system, r.external_id
    from cma.lead_deals_of(p_tenant_id, p_from, p_to) d
    join cma.crm_contact k
      on k.tenant_id = p_tenant_id and k.connection_id = d.connection_id and k.source_id = any (d.contacts)
    join cma.crm_contact_ref r on r.tenant_id = k.tenant_id and r.contact_id = k.id
    group by 1, 2, 3
  )
  select p_tenant_id, d.deal_id, d.connection_id, d.source_id, d.pipeline_id, d.pipeline_label, d.business_date,
         d.created_at, d.market,
         (select count(*) from refs where refs.deal_id = d.deal_id)::integer,
         o.id, o.connection_id, o.source_id, o.handle, o.source_created_at, o.order_kind, o.currency, o.total_amount,
         case when o.id is not null then round(extract(epoch from o.source_created_at - d.created_at) / 86400, 2) end
  from cma.lead_deals_of(p_tenant_id, p_from, p_to) d
  cross join s
  left join lateral (
    select co.id, co.connection_id, co.source_id, st.handle, co.source_created_at, co.order_kind, co.currency, co.total_amount
    from refs
    join cma.commerce_order co
      on co.tenant_id = p_tenant_id and co.source_system = refs.system and co.customer_source_id = refs.external_id
    left join cma.commerce_store st on st.tenant_id = co.tenant_id and st.connection_id = co.connection_id
    where refs.deal_id = d.deal_id
      and not co.is_test and co.cancelled_at is null and co.source_deleted_at is null
      and co.source_created_at >= d.created_at
      and co.source_created_at <= d.created_at + make_interval(days => s.max_days)
    order by co.source_created_at, co.id
    limit 1) o on true
$$;

-- ---------------------------------------------------------------------------------------------
-- 6. Intake per day
-- ---------------------------------------------------------------------------------------------
-- Per business date (the tenant's zone) and market, from intake.start_date and within [p_from,
-- p_to) when given. Markets: a form's configured market; a record's market as for speed to lead;
-- a telephony call's line market; a commerce customer's or order's store market; each 'unknown'
-- when it is not a catalog market. Counted forms, pipelines, lines and tags only (one not yet seen
-- counts); deleted rows, test orders and cancelled orders left out. Tagged calls: calls carrying
-- a counted tag now.
create or replace function cma.intake_per_day_of(p_tenant_id uuid, p_from timestamptz, p_to timestamptz)
returns setof cma.intake_per_day_row
language sql stable
as $$
  with s as (
    select t.timezone as zone,
           greatest(coalesce(p_from, '-infinity'::timestamptz),
                    cma.setting_of(t.id, 'intake.start_date')::date::timestamp at time zone t.timezone) as from_at,
           coalesce(p_to, 'infinity'::timestamptz) as to_at
    from cma.tenant t where t.id = p_tenant_id
  ),
  e as (
    select fs.submitted_at as at, coalesce(cma.market_code_of(p_tenant_id, f.market), 'unknown') as market, 'form' as metric
    from cma.form_submission fs
    join cma.connection_form f
      on f.tenant_id = fs.tenant_id and f.connection_id = fs.connection_id and f.source_form_id = fs.source_form_id
    cross join s
    where fs.tenant_id = p_tenant_id and f.is_counted and fs.submitted_at >= s.from_at and fs.submitted_at < s.to_at
    union all
    select x.at, rm.code, x.metric
    from (select cr.*, cr.source_created_at as at, cr.record_type || '_created' as metric
          from cma.crm_record cr
          union all
          select cr.*, cr.closed_at, cr.record_type || '_closed'
          from cma.crm_record cr where cr.is_closed and cr.closed_at is not null) x
    left join cma.connection_pipeline p
      on p.tenant_id = x.tenant_id and p.connection_id = x.connection_id
     and p.record_type = x.record_type and p.source_pipeline_id = x.pipeline_id
    cross join s
    cross join lateral cma.record_market_of(x.tenant_id, x.connection_id, x.market, x.contact_source_id) rm
    where x.tenant_id = p_tenant_id and x.record_type in ('deal', 'ticket') and x.source_deleted_at is null
      and coalesce(p.is_counted, true) and x.at >= s.from_at and x.at < s.to_at
    union all
    select tc.started_at, coalesce(cma.market_code_of(p_tenant_id, n.market), 'unknown'), m.metric
    from cma.telephony_call tc
    left join cma.telephony_number n
      on n.tenant_id = tc.tenant_id and n.connection_id = tc.connection_id and n.number_ref = tc.number_ref
    cross join s
    cross join lateral (
      select case tc.direction when 'inbound' then 'call_in' else 'call_out' end as metric
      union all
      select 'call_tagged'
      where exists (select 1 from cma.telephony_call_tag ct
                    left join cma.telephony_tag tg
                      on tg.tenant_id = ct.tenant_id and tg.connection_id = ct.connection_id and tg.tag_ref = ct.tag_ref
                    where ct.tenant_id = tc.tenant_id and ct.connection_id = tc.connection_id
                      and ct.call_source_id = tc.source_id and ct.untagged_at is null and coalesce(tg.is_counted, true))) m
    where tc.tenant_id = p_tenant_id and tc.source_deleted_at is null and coalesce(n.is_counted, true)
      and tc.started_at >= s.from_at and tc.started_at < s.to_at
    union all
    select cu.source_created_at, coalesce(cma.market_code_of(p_tenant_id, st.market), 'unknown'), 'customer'
    from cma.commerce_customer cu
    left join cma.commerce_store st on st.tenant_id = cu.tenant_id and st.connection_id = cu.connection_id
    cross join s
    where cu.tenant_id = p_tenant_id and cu.source_deleted_at is null
      and cu.source_created_at >= s.from_at and cu.source_created_at < s.to_at
    union all
    select co.source_created_at, coalesce(cma.market_code_of(p_tenant_id, st.market), 'unknown'), 'order_' || co.order_kind
    from cma.commerce_order co
    left join cma.commerce_store st on st.tenant_id = co.tenant_id and st.connection_id = co.connection_id
    cross join s
    where co.tenant_id = p_tenant_id and co.source_deleted_at is null and not co.is_test and co.cancelled_at is null
      and co.source_created_at >= s.from_at and co.source_created_at < s.to_at
  )
  select p_tenant_id, (e.at at time zone s.zone)::date, e.market,
         (count(*) filter (where e.metric = 'form'))::integer,
         (count(*) filter (where e.metric = 'deal_created'))::integer,
         (count(*) filter (where e.metric = 'deal_closed'))::integer,
         (count(*) filter (where e.metric = 'ticket_created'))::integer,
         (count(*) filter (where e.metric = 'ticket_closed'))::integer,
         (count(*) filter (where e.metric = 'call_in'))::integer,
         (count(*) filter (where e.metric = 'call_out'))::integer,
         (count(*) filter (where e.metric = 'call_tagged'))::integer,
         (count(*) filter (where e.metric = 'customer'))::integer,
         (count(*) filter (where e.metric = 'order_first'))::integer,
         (count(*) filter (where e.metric = 'order_repeat'))::integer,
         (count(*) filter (where e.metric = 'order_renewal'))::integer
  from e cross join s
  group by 2, 3
$$;

-- ---------------------------------------------------------------------------------------------
-- 7. Data quality (DESIGN §4.4, the Data first list made measurable)
-- ---------------------------------------------------------------------------------------------
-- The checks, in the order the Data page shows them. Each finding names an object by id only;
-- value holds a code where the check is about one (a market as written, a ref system, a record
-- type), never personal data.
create or replace function cma.data_quality_checks()
returns table (check_key text, sort_order integer, description text)
language sql immutable
as $$
  values
    ('deal_without_contact',          10, 'Lead deals without any contact'),
    ('deal_contact_incomplete',       20, 'Primary contacts of lead deals without country or language'),
    ('market_not_in_catalog',         30, 'Markets or countries written by a source that are not in the market catalog'),
    ('owner_without_person',          40, 'CRM owners without a CMA person'),
    ('telephony_user_without_person', 50, 'Telephony users without a CMA person'),
    ('crm_call_without_contact',      60, 'CRM calls without a contact association'),
    ('telephony_call_unlinked',       70, 'Telephony calls without a link to a CRM call after 24 hours (once both sources run)'),
    ('commerce_unmatched',            80, 'Commerce customers whose id no CRM contact holds'),
    ('commerce_ambiguous',            90, 'Commerce customers whose id several CRM contacts hold'),
    ('writeback_parked',             100, 'CRM write-backs parked for review (from migration 0007c)'),
    ('contact_slots_full',           110, 'Contacts whose first two ref slots of a system are both taken'),
    ('contact_country_differs',      120, 'Contacts whose country differs from the market of a store their commerce id belongs to'),
    ('customer_in_two_stores',       130, 'Commerce customer ids present in more than one store'),
    ('pipeline_unreviewed',          140, 'Pipelines seen but never reviewed by a person (counted by default)'),
    ('form_without_market',          150, 'Counted forms without a market')
$$;

create or replace function cma.data_quality_of(p_tenant_id uuid)
returns table (check_key text, connection_id uuid, object_type text, object_id text, value text)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_start timestamptz;
begin
  select cma.setting_of(t.id, 'intake.start_date')::date::timestamp at time zone t.timezone into v_start
  from cma.tenant t where t.id = p_tenant_id;

  return query
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
    and nullif(btrim(cr.market), '') is not null and cma.market_code_of(p_tenant_id, cr.market) is null
  union all
  select 'market_not_in_catalog', k.connection_id, 'contact', k.source_id, k.country
  from cma.crm_contact k
  where k.tenant_id = p_tenant_id and k.source_deleted_at is null
    and nullif(btrim(k.country), '') is not null and cma.market_code_of(p_tenant_id, k.country) is null
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
  -- telephony calls older than 24 hours without a current link, once the tenant has CRM calls
  select 'telephony_call_unlinked', tc.connection_id, 'telephony_call', tc.source_id, null
  from cma.telephony_call tc
  where tc.tenant_id = p_tenant_id and tc.source_deleted_at is null
    and tc.started_at >= v_start and tc.started_at < now() - interval '24 hours'
    and exists (select 1 from cma.crm_call c where c.tenant_id = p_tenant_id and c.source_deleted_at is null)
    and not exists (select 1 from cma.call_link l
                    where l.tenant_id = tc.tenant_id and l.telephony_call_id = tc.id and l.unlinked_at is null)
  union all
  -- commerce customers whose id no contact holds, or several contacts hold
  select case when h.contacts = 0 then 'commerce_unmatched' else 'commerce_ambiguous' end,
         cu.connection_id, 'commerce_customer', cu.source_id, null
  from cma.commerce_customer cu
  cross join lateral (select count(distinct r.contact_id) as contacts
                      from cma.crm_contact_ref r
                      where r.tenant_id = cu.tenant_id and r.system = cu.source_system and r.external_id = cu.source_id) h
  where cu.tenant_id = p_tenant_id and cu.source_deleted_at is null and h.contacts <> 1
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
         cma.market_code_of(p_tenant_id, k.country) || '/' || st.market
  from cma.crm_contact k
  join cma.crm_contact_ref r on r.tenant_id = k.tenant_id and r.contact_id = k.id
  join cma.commerce_customer cu
    on cu.tenant_id = r.tenant_id and cu.source_system = r.system and cu.source_id = r.external_id and cu.source_deleted_at is null
  join cma.commerce_store st on st.tenant_id = cu.tenant_id and st.connection_id = cu.connection_id
  where k.tenant_id = p_tenant_id and k.source_deleted_at is null
    and cma.market_code_of(p_tenant_id, k.country) is distinct from st.market
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
  where f.tenant_id = p_tenant_id and f.status = 'active' and f.is_counted and f.market is null;

  -- parked write-backs: the outbox arrives with migration 0007c; until then the check finds nothing
  if to_regclass('cma.outbox_action') is not null then
    return query execute
      'select ''writeback_parked''::text, o.connection_id, o.target_type::text, o.target_id::text, o.action::text
       from cma.outbox_action o
       where o.tenant_id = $1 and o.status = ''needs_review'''
      using p_tenant_id;
  end if;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 8. The application's reads (permission checked, current tenant, row-level security)
-- ---------------------------------------------------------------------------------------------
create or replace function cma.speed_to_lead_rows(p_from date, p_to date)
returns setof cma.speed_to_lead_row
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_range  record;
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  select * into v_range from cma.report_range(v_tenant, p_from, p_to);
  return query
    select * from cma.speed_to_lead_of(v_tenant, v_range.from_at, v_range.to_at) r
    order by r.created_at, r.deal_source_id;
end
$$;

-- Grouped by day (business date), market, agent (the mapped person; unmapped calls under
-- 'unknown') or pipeline. Business minutes over called deals; percentages over the deals whose
-- outcome is known (null while nothing is known).
create or replace function cma.speed_to_lead_summary(p_from date, p_to date, p_group text)
returns table (
  group_key                text,
  group_label              text,
  deals                    integer,
  called                   integer,
  median_business_minutes  numeric,
  p80_business_minutes     numeric,
  within_target_pct        numeric,
  before_next_noon_pct     numeric,
  open_not_called          integer
)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_tenant uuid := cma.current_tenant_id();
  v_range  record;
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  if p_group is null or p_group not in ('day', 'market', 'agent', 'pipeline') then
    raise exception 'group by day, market, agent or pipeline, not %', p_group using errcode = 'CMA04';
  end if;
  select * into v_range from cma.report_range(v_tenant, p_from, p_to);
  return query
    select g.k, g.l, count(*)::integer, (count(*) filter (where r.status = 'called'))::integer,
           round((percentile_cont(0.5) within group (order by r.business_seconds))::numeric / 60, 1),
           round((percentile_cont(0.8) within group (order by r.business_seconds))::numeric / 60, 1),
           round(100.0 * count(*) filter (where r.within_target) / nullif(count(r.within_target), 0), 1),
           round(100.0 * count(*) filter (where r.before_next_noon) / nullif(count(r.before_next_noon), 0), 1),
           (count(*) filter (where r.status = 'not_called_open'))::integer
    from cma.speed_to_lead_of(v_tenant, v_range.from_at, v_range.to_at) r
    left join cma.app_user u on u.tenant_id = v_tenant and u.id = r.agent_user_id
    cross join lateral (
      select case p_group when 'day' then r.business_date::text
                          when 'market' then r.market
                          when 'agent' then coalesce(r.agent_user_id::text, 'unknown')
                          else r.connection_id::text || ':' || coalesce(r.pipeline_id, '') end as k,
             case p_group when 'day' then r.business_date::text
                          when 'market' then r.market
                          when 'agent' then coalesce(u.display_name, 'unknown')
                          else coalesce(r.pipeline_label, 'unknown') end as l) g
    group by g.k, g.l
    order by g.k;
end
$$;

create or replace function cma.lead_to_order_rows(p_from date, p_to date)
returns setof cma.lead_to_order_row
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_range  record;
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  select * into v_range from cma.report_range(v_tenant, p_from, p_to);
  return query
    select * from cma.lead_to_order_of(v_tenant, v_range.from_at, v_range.to_at) r
    order by r.created_at, r.deal_source_id;
end
$$;

create or replace function cma.intake_per_day(p_from date, p_to date)
returns setof cma.intake_per_day_row
language plpgsql stable
as $$
declare
  v_tenant uuid := cma.current_tenant_id();
  v_range  record;
begin
  perform cma.assert_any_permission(array['reports.view', 'performance.team']);
  select * into v_range from cma.report_range(v_tenant, p_from, p_to);
  return query
    select * from cma.intake_per_day_of(v_tenant, v_range.from_at, v_range.to_at) r
    order by r.business_date, r.market;
end
$$;

-- Every check with its current total (0 when nothing is found; null for a check whose source is
-- not installed yet, the outbox before 0007c)
create or replace function cma.data_quality()
returns table (check_key text, description text, total integer)
language plpgsql stable
as $$
#variable_conflict use_column
declare
  v_tenant uuid := cma.current_tenant_id();
begin
  perform cma.assert_any_permission(array['reports.view', 'tenant.configure']);
  return query
    with q as materialized (select f.check_key from cma.data_quality_of(v_tenant) f)
    select c.check_key, c.description,
           case when c.check_key = 'writeback_parked' and to_regclass('cma.outbox_action') is null then null
                else (select count(*) from q where q.check_key = c.check_key)::integer end
    from cma.data_quality_checks() c
    order by c.sort_order;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 9. Grants: the application only
-- ---------------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'cma.speed_to_lead_rows(date,date)',
    'cma.speed_to_lead_summary(date,date,text)',
    'cma.lead_to_order_rows(date,date)',
    'cma.intake_per_day(date,date)',
    'cma.data_quality()',
    -- helpers the functions above call in the caller's rights (row-level security keeps them to
    -- the current tenant whatever tenant they are given)
    'cma.setting_of(uuid,text)',
    'cma.market_code_of(uuid,text)',
    'cma.record_market_of(uuid,uuid,text,text)',
    'cma.business_seconds_of(uuid,text,timestamptz,timestamptz)',
    'cma.next_business_noon_of(uuid,text,timestamptz)',
    'cma.report_range(uuid,date,date)',
    'cma.lead_deals_of(uuid,timestamptz,timestamptz)',
    'cma.lead_calls_of(uuid,uuid,text,text,text[],timestamptz)',
    'cma.speed_to_lead_of(uuid,timestamptz,timestamptz)',
    'cma.lead_to_order_of(uuid,timestamptz,timestamptz)',
    'cma.intake_per_day_of(uuid,timestamptz,timestamptz)',
    'cma.data_quality_checks()',
    'cma.data_quality_of(uuid)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_app', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 10. Reporting: the readers' functions and views (every tenant the reader sees)
-- ---------------------------------------------------------------------------------------------
-- SECURITY DEFINER, owned by cma_owner, search path pinned; the tenant filter is the views' own
-- (cma_read.reader_sees). Readers may execute these; the application and public may not.
create or replace function cma_read.speed_to_lead_rows()
returns setof cma.speed_to_lead_row
language sql stable security definer
set search_path = pg_catalog, cma
as $$
  select r.* from cma.tenant t
  cross join lateral cma.speed_to_lead_of(t.id, null, null) r
  where cma_read.reader_sees(t.id)
$$;

create or replace function cma_read.lead_to_order_rows()
returns setof cma.lead_to_order_row
language sql stable security definer
set search_path = pg_catalog, cma
as $$
  select r.* from cma.tenant t
  cross join lateral cma.lead_to_order_of(t.id, null, null) r
  where cma_read.reader_sees(t.id)
$$;

create or replace function cma_read.intake_per_day_rows()
returns setof cma.intake_per_day_row
language sql stable security definer
set search_path = pg_catalog, cma
as $$
  select r.* from cma.tenant t
  cross join lateral cma.intake_per_day_of(t.id, null, null) r
  where cma_read.reader_sees(t.id)
$$;

create or replace function cma_read.data_quality_rows()
returns table (tenant_id uuid, check_key text, connection_id uuid, object_type text, object_id text, value text)
language sql stable security definer
set search_path = pg_catalog, cma
as $$
  select t.id, q.check_key, q.connection_id, q.object_type, q.object_id, q.value
  from cma.tenant t
  cross join lateral cma.data_quality_of(t.id) q
  where cma_read.reader_sees(t.id)
$$;

do $$
declare
  f text;
begin
  foreach f in array array[
    'cma_read.speed_to_lead_rows()', 'cma_read.lead_to_order_rows()',
    'cma_read.intake_per_day_rows()', 'cma_read.data_quality_rows()'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to cma_readonly', f);
  end loop;
end
$$;

create or replace view cma_read.speed_to_lead as
  select * from cma_read.speed_to_lead_rows();

create or replace view cma_read.lead_to_order as
  select * from cma_read.lead_to_order_rows();

create or replace view cma_read.intake_per_day_v as
  select * from cma_read.intake_per_day_rows();

-- One view per check, ids only
do $$
declare
  c record;
begin
  for c in select check_key from cma.data_quality_checks() loop
    execute format(
      'create or replace view cma_read.%I as
         select tenant_id, connection_id, object_type, object_id, value
         from cma_read.data_quality_rows() where check_key = %L', 'dq_' || c.check_key, c.check_key);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------------------------
-- 11. Record the migration
-- ---------------------------------------------------------------------------------------------
insert into cma.schema_migration (version, description)
values ('0007d', 'Lead metrics and data quality: speed to lead with its summary, lead to order, intake per day, the data-quality checks, their reporting views')
on conflict (version) do nothing;

reset role;
